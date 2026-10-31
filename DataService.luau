--!strict
-- Persistencia de perfiles de jugador.
--
-- Reglas que este modulo implementa y que el resto del codigo da por hechas:
--   * Toda llamada al DataStore va con pcall + retry y backoff exponencial.
--   * Read-modify-write siempre por UpdateAsync, nunca GetAsync + SetAsync.
--   * Una sola SESION posee el perfil a la vez. El lock guarda un sessionId
--     unico por carga, no solo el JobId: dos sesiones del mismo jugador en el
--     mismo servidor (salir y volver a entrar) son dos duenos distintos.
--   * Las escrituras de un mismo jugador se serializan en el proceso. Sin
--     esto, un autosave en vuelo puede aterrizar despues del save de salida y
--     pisar datos nuevos con datos viejos, ademas de reinstalar un lock que
--     ya nadie va a liberar.
--   * Se guarda en tres momentos: autosave, salida del jugador y BindToClose.
--   * Un perfil se valida como serializable ANTES de escribirlo. Un Instance o
--     un NaN que se cuele rompe todos los saves de ese jugador para siempre.
--   * Si la carga falla, el jugador se expulsa. Dejarlo jugar con un perfil
--     default hace que el proximo save le pise los datos reales.
--
-- El gameplay nunca toca el DataStore: lee y escribe la tabla en memoria que
-- devuelve DataService.get().

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local TableKit = require(Shared.Util.TableKit)
local Types = require(Shared.Types)

type Profile = Types.Profile

local CURRENT_VERSION = 1

local DEFAULT_PROFILE: Profile = {
	version = CURRENT_VERSION,
	coins = Config.STARTING_COINS,
	gems = Config.STARTING_GEMS,
	inventory = {},
	stats = {},
	settings = {
		music = true,
		sfx = true,
	},
}

-- Cada migracion lleva el perfil de la version N a N+1. Nunca borrar un campo
-- sin migracion: durante un rolling update corren servidores viejos y nuevos
-- al mismo tiempo contra los mismos datos.
-- La version 0 es "dato guardado antes de que existiera el versionado".
local MIGRATIONS: { [number]: (any) -> any } = {
	[0] = function(data)
		return data
	end,
}

local store = DataStoreService:GetDataStore(Config.DATASTORE_NAME, Config.DATASTORE_SCOPE)

local profiles: { [Player]: Profile } = {}
local sessionIds: { [number]: string } = {} -- UserId -> sessionId de la carga actual
local saveInFlight: { [number]: boolean } = {} -- UserId -> hay una escritura corriendo
local nextSaveAt: { [Player]: number } = {}
local readyCallbacks: { (player: Player, profile: Profile) -> () } = {}

local DataService = {}

local function keyFor(userId: number): string
	return `Player_{userId}`
end

local function migrate(data: any): any
	-- Dato viejo sin version: tratarlo como v0 en vez de comparar nil < number,
	-- que tira y deja al jugador sin poder entrar nunca mas.
	if typeof(data.version) ~= "number" then
		data.version = 0
	end
	while data.version < CURRENT_VERSION do
		local step = MIGRATIONS[data.version]
		if not step then
			error(`falta migracion desde la version {data.version}`)
		end
		data = step(data)
		data.version += 1
	end
	return data
end

local function withRetry<T>(attempts: number, fn: () -> T): (boolean, T?)
	local delaySeconds = 1
	for attempt = 1, attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result
		end
		warn(`[DataService] intento {attempt}/{attempts} fallo: {result}`)
		if attempt < attempts then
			task.wait(delaySeconds)
			delaySeconds = math.min(delaySeconds * 2, 16)
		end
	end
	return false, nil
end

-- El lock pertenece a una sesion, no a un servidor.
local function isLockedByOtherSession(stored: any, sessionId: string): boolean
	if stored == nil or stored.lock == nil then
		return false
	end
	if stored.lock.sessionId == sessionId then
		return false
	end
	local age = os.time() - (stored.lock.timestamp or 0)
	-- Un lock viejo pertenece a una sesion que murio: se puede tomar.
	return age < Config.LOCK_STALE_AFTER
end

local function acquireSaveSlot(userId: number)
	while saveInFlight[userId] do
		task.wait(0.05)
	end
	saveInFlight[userId] = true
end

local function releaseSaveSlot(userId: number)
	saveInFlight[userId] = nil
end

-- Un solo intento de claim. Devuelve "ok" | "locked" | "error".
local function tryClaim(userId: number, sessionId: string): ("ok" | "locked" | "error", Profile?)
	local blocked = false
	local ok, result = pcall(function()
		blocked = false
		return store:UpdateAsync(keyFor(userId), function(stored)
			if isLockedByOtherSession(stored, sessionId) then
				blocked = true
				return nil -- aborta la escritura, no toca nada
			end
			local profile = stored or TableKit.deepCopy(DEFAULT_PROFILE)
			profile = migrate(profile)
			TableKit.reconcile(profile, DEFAULT_PROFILE)
			-- El dato que vuelve del DataStore no es confiable por venir de
			-- ahi: una migracion a medias o un bug viejo pudo dejar un campo
			-- con el tipo equivocado.
			TableKit.coerceTypes(profile, DEFAULT_PROFILE, function(fieldPath)
				warn(`[DataService] {userId}: campo {fieldPath} con tipo invalido, reseteado`)
			end)
			profile.lock = {
				sessionId = sessionId,
				jobId = game.JobId,
				timestamp = os.time(),
			}
			return profile
		end)
	end)

	if blocked then
		return "locked", nil
	end
	if not ok then
		warn(`[DataService] claim fallo para {userId}: {result}`)
		return "error", nil
	end
	if result == nil then
		return "error", nil
	end
	return "ok", result :: Profile
end

-- Reclama el lock y devuelve el perfil. "locked" se reintenta con espera: la
-- causa mas comun es una migracion de servidor donde el servidor viejo
-- todavia esta liberando el lock. Kickear al primer intento echaria a todos
-- los jugadores en cada apagado.
local function claimProfile(userId: number): ("ok" | "locked" | "error", Profile?, string?)
	-- Esperar las escrituras en vuelo de una sesion anterior del mismo
	-- jugador, asi su release aterriza antes de que leamos.
	local waitUntil = os.clock() + 10
	while saveInFlight[userId] and os.clock() < waitUntil do
		task.wait(0.1)
	end

	local sessionId = `{game.JobId}:{HttpService:GenerateGUID(false)}`
	local delaySeconds = 1

	for attempt = 1, Config.LOAD_ATTEMPTS do
		local status, profile = tryClaim(userId, sessionId)
		if status == "ok" then
			return "ok", profile, sessionId
		end
		if attempt < Config.LOAD_ATTEMPTS then
			task.wait(delaySeconds)
			delaySeconds = math.min(delaySeconds * 2, 8)
		else
			return status, nil, nil
		end
	end
	return "error", nil, nil
end

local function writeProfile(player: Player, release: boolean): boolean
	local userId = player.UserId
	acquireSaveSlot(userId)

	-- Leer el perfil DESPUES de tomar el slot: asi se toma el estado mas
	-- nuevo, y un autosave encolado detras de un release ve profiles[player]
	-- ya en nil y no escribe nada.
	local profile = profiles[player]
	local sessionId = sessionIds[userId]
	if profile == nil or sessionId == nil then
		releaseSaveSlot(userId)
		return false
	end

	local snapshot = TableKit.deepCopy(profile)
	local serializable, problem = TableKit.isSerializable(snapshot)
	if not serializable then
		releaseSaveSlot(userId)
		warn(`[DataService] perfil de {player.Name} no es serializable ({problem}); no se guarda`)
		return false
	end

	local aborted = false
	local ok = withRetry(Config.SAVE_ATTEMPTS, function()
		aborted = false
		return store:UpdateAsync(keyFor(userId), function(stored)
			-- Si otra sesion ya tomo el lock, nuestros datos son viejos.
			if isLockedByOtherSession(stored, sessionId) then
				aborted = true
				return nil
			end
			if release then
				snapshot.lock = nil
			else
				snapshot.lock = {
					sessionId = sessionId,
					jobId = game.JobId,
					timestamp = os.time(),
				}
			end
			return snapshot
		end)
	end)

	releaseSaveSlot(userId)

	-- Un transform que devuelve nil cancela la escritura SIN error, asi que
	-- pcall dice exito. Sin este chequeo, writeProfile reportaria que guardo
	-- cuando en realidad no escribio nada.
	if aborted then
		warn(`[DataService] save de {player.Name} abortado: otra sesion tiene el lock`)
		return false
	end
	if not ok then
		warn(`[DataService] no se pudo guardar {player.Name}`)
		return false
	end
	return true
end

--[[ API publica ]]

function DataService.get(player: Player): Profile?
	return profiles[player]
end

function DataService.isReady(player: Player): boolean
	return profiles[player] ~= nil
end

-- Se llama por cada perfil que termina de cargar, incluidos los que ya
-- cargaron antes de registrar el callback.
function DataService.onReady(callback: (player: Player, profile: Profile) -> ())
	table.insert(readyCallbacks, callback)
	for player, profile in profiles do
		task.spawn(callback, player, profile)
	end
end

-- Devuelve false si la escritura no llego al DataStore. No asumir exito.
function DataService.save(player: Player): boolean
	return writeProfile(player, false)
end

--[[ Ciclo de vida ]]

local function releaseSession(player: Player)
	nextSaveAt[player] = nil
	if profiles[player] == nil then
		return
	end
	local saved = writeProfile(player, true)
	if not saved then
		warn(`[DataService] la sesion de {player.Name} se cierra sin guardar`)
	end
	profiles[player] = nil
	sessionIds[player.UserId] = nil
end

local function onPlayerAdded(player: Player)
	local status, profile, sessionId = claimProfile(player.UserId)

	if not player:IsDescendantOf(Players) then
		-- Se fue durante la carga. Liberamos el lock que acabamos de tomar.
		if status == "ok" and profile and sessionId then
			profiles[player] = profile
			sessionIds[player.UserId] = sessionId
			releaseSession(player)
		end
		return
	end

	if status == "locked" then
		player:Kick("Tus datos todavia se estan guardando. Reconectate en unos segundos.")
		return
	end
	if status == "error" or profile == nil or sessionId == nil then
		player:Kick("No pudimos cargar tus datos. Reconectate, no se perdio nada.")
		return
	end

	profiles[player] = profile
	sessionIds[player.UserId] = sessionId
	-- Offset por UserId: 50 jugadores no guardan todos en el mismo tick.
	nextSaveAt[player] = os.clock()
		+ Config.AUTOSAVE_INTERVAL
		+ (player.UserId % Config.AUTOSAVE_INTERVAL)

	for _, callback in readyCallbacks do
		task.spawn(callback, player, profile)
	end
end

function DataService.init()
	Players.PlayerAdded:Connect(function(player)
		task.spawn(onPlayerAdded, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		task.spawn(releaseSession, player)
	end)

	-- Jugadores que entraron antes de que corriera este connect.
	for _, player in Players:GetPlayers() do
		if profiles[player] == nil then
			task.spawn(onPlayerAdded, player)
		end
	end

	game:BindToClose(function()
		-- PlayerRemoving tambien dispara en el apagado. El slot por jugador
		-- serializa las dos escrituras, asi que gana la mas nueva en vez de la
		-- que tenga suerte.
		local pending = 0
		for player in profiles do
			pending += 1
			task.spawn(function()
				releaseSession(player)
				pending -= 1
			end)
		end

		if RunService:IsStudio() then
			-- Sin tope, cortar un playtest tarda los 25 segundos completos.
			local studioDeadline = os.clock() + 3
			while pending > 0 and os.clock() < studioDeadline do
				task.wait(0.1)
			end
			return
		end

		local deadline = os.clock() + Config.SHUTDOWN_BUDGET
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function DataService.start()
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for player, dueAt in nextSaveAt do
				if now >= dueAt then
					nextSaveAt[player] = now + Config.AUTOSAVE_INTERVAL
					task.spawn(writeProfile, player, false)
				end
			end
		end
	end)
end

return DataService
