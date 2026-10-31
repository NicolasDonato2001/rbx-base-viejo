--!strict
-- Creacion y guardado de remotes.
--
-- El servidor crea todos los remotes a partir de RemoteSchema; el cliente
-- nunca crea uno. Cada handler registrado aca pasa, en orden, por: rate limit
-- -> validacion de tipos y rangos -> el handler del sistema. Un nombre que no
-- este en el schema no se puede registrar ni disparar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Guard = require(Shared.Util.Guard)
local RemoteSchema = require(Shared.RemoteSchema)

local remotes: { [string]: Instance } = {}
local buckets: { [Player]: { [string]: { tokens: number, last: number } } } = {}

local RemoteService = {}

-- Token bucket por jugador y por remote. Un exploiter dispara miles de veces
-- por segundo; esto corta el dano y la carga del servidor.
local function allow(player: Player, name: string, perSecond: number, burst: number): boolean
	-- Un remote en vuelo puede llegar despues de PlayerRemoving. Sin este
	-- chequeo, allow() recrearia el bucket con una referencia fuerte al Player
	-- que ya nadie limpia: un leak por sesion en servidores de larga vida.
	if not player:IsDescendantOf(Players) then
		return false
	end
	local now = os.clock()
	local playerBuckets = buckets[player]
	if not playerBuckets then
		playerBuckets = {}
		buckets[player] = playerBuckets
	end
	local bucket = playerBuckets[name]
	if not bucket then
		bucket = { tokens = burst, last = now }
		playerBuckets[name] = bucket
	end
	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.last) * perSecond)
	bucket.last = now
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

function RemoteService.init()
	local folder = Instance.new("Folder")
	folder.Name = "Remotes"

	for name, spec in RemoteSchema do
		local remote: Instance
		if spec.kind == "Event" then
			remote = Instance.new("RemoteEvent")
		else
			remote = Instance.new("RemoteFunction")
		end
		remote.Name = name
		remote.Parent = folder
		remotes[name] = remote
	end

	folder.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player)
		buckets[player] = nil
	end)
end

-- Registra el handler de un remote ClientToServer.
-- El handler solo corre si los argumentos ya pasaron validacion, asi que puede
-- asumir sus tipos. Devolver nil en un Function equivale a rechazar.
function RemoteService.handle(name: string, handler: (player: Player, ...any) -> ...any)
	local spec = RemoteSchema[name]
	if spec == nil then
		error(`[RemoteService] "{name}" no esta declarado en RemoteSchema`)
	end
	if spec.direction ~= "ClientToServer" then
		error(`[RemoteService] "{name}" es ServerToClient, no acepta handler`)
	end

	local remote = remotes[name]
	if remote == nil then
		error(`[RemoteService] init() no corrio todavia`)
	end

	local params = spec.params or {}
	local rate = spec.rate or { perSecond = 5, burst = 10 }

	local function gate(player: Player, ...): (boolean, { unknown })
		if not allow(player, name, rate.perSecond, rate.burst) then
			return false, {}
		end
		local args = table.pack(...)
		if not Guard.check(params, args :: any, args.n) then
			return false, {}
		end
		return true, args :: any
	end

	if spec.kind == "Event" then
		(remote :: RemoteEvent).OnServerEvent:Connect(function(player, ...)
			local ok, args = gate(player, ...)
			if not ok then
				return
			end
			handler(player, table.unpack(args :: any, 1, (args :: any).n))
		end)
	else
		(remote :: RemoteFunction).OnServerInvoke = function(player, ...)
			local ok, args = gate(player, ...)
			if not ok then
				return nil
			end
			return handler(player, table.unpack(args :: any, 1, (args :: any).n))
		end
	end
end

function RemoteService.fire(player: Player, name: string, ...: any)
	local spec = RemoteSchema[name]
	if spec == nil or spec.direction ~= "ServerToClient" or spec.kind ~= "Event" then
		error(`[RemoteService] "{name}" no es un evento ServerToClient`)
	end
	local remote = remotes[name] :: RemoteEvent
	remote:FireClient(player, ...)
end

function RemoteService.fireAll(name: string, ...: any)
	local spec = RemoteSchema[name]
	if spec == nil or spec.direction ~= "ServerToClient" or spec.kind ~= "Event" then
		error(`[RemoteService] "{name}" no es un evento ServerToClient`)
	end
	local remote = remotes[name] :: RemoteEvent
	remote:FireAllClients(...)
end

return RemoteService
