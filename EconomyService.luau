--!strict
-- Moneda e inventario, autoritativo en el servidor.
--
-- El catalogo y los precios viven aca. El cliente manda un id de item y una
-- cantidad; todo lo demas lo decide el servidor. Cambiar esto por un precio
-- que venga del cliente es el exploit mas comun que existe.

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)

local DataService = require(script.Parent.DataService)
local RemoteService = require(script.Parent.RemoteService)

type Currency = Types.Currency
type ItemDefinition = Types.ItemDefinition
type PublicState = Types.PublicState

-- Catalogo del servidor. Nunca se replica tal cual; el cliente recibe solo lo
-- que necesita mostrar.
local CATALOG: { [string]: ItemDefinition } = {
	starter_pickaxe = { id = "starter_pickaxe", price = 50, currency = "Coins", maxStack = 1 },
	speed_boost = { id = "speed_boost", price = 120, currency = "Coins", maxStack = 10 },
}

local FIELD_BY_CURRENCY: { [Currency]: string } = {
	Coins = "coins",
	Gems = "gems",
}

local EconomyService = {}

-- Una cantidad valida para moneda o inventario. Un NaN o un infinito que entre
-- al perfil lo vuelve no serializable y rompe TODOS los saves de ese jugador,
-- asi que se rechaza en el borde de estas funciones y no solo en el remote:
-- otros sistemas del servidor tambien las llaman.
local function isSafeAmount(value: number, allowNegative: boolean): boolean
	if typeof(value) ~= "number" then
		return false
	end
	if value ~= value then -- NaN
		return false
	end
	if value == math.huge or value == -math.huge then
		return false
	end
	if value ~= math.floor(value) then
		return false
	end
	if not allowNegative and value < 1 then
		return false
	end
	return true
end

local function publicState(profile: Types.Profile): PublicState
	return {
		coins = profile.coins,
		gems = profile.gems,
		-- Copia: devolver la tabla viva dejaria que un consumidor del "estado
		-- publico" mute el perfil persistido.
		inventory = table.clone(profile.inventory),
		settings = table.clone(profile.settings),
	}
end

local function push(player: Player)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	RemoteService.fire(player, "StateChanged", publicState(profile))
end

--[[ API para otros sistemas ]]

function EconomyService.getBalance(player: Player, currency: Currency): number
	local profile = DataService.get(player)
	if profile == nil then
		return 0
	end
	return (profile :: any)[FIELD_BY_CURRENCY[currency]] or 0
end

-- Suma (o resta, con delta negativo) moneda. Devuelve false si no alcanza, sin
-- aplicar nada: una transaccion parcial es peor que una rechazada.
function EconomyService.addCurrency(player: Player, currency: Currency, delta: number): boolean
	local profile = DataService.get(player)
	if profile == nil then
		return false
	end
	if not isSafeAmount(delta, true) then
		warn(`[EconomyService] delta invalido para {player.Name}: {delta}`)
		return false
	end
	local balances = profile :: any
	local field = FIELD_BY_CURRENCY[currency]
	local current = balances[field] or 0
	local nextValue = current + delta
	if nextValue < 0 or nextValue > Config.MAX_CURRENCY then
		return false
	end
	balances[field] = nextValue
	push(player)
	return true
end

function EconomyService.grantItem(player: Player, itemId: string, quantity: number): boolean
	local profile = DataService.get(player)
	local item = CATALOG[itemId]
	if profile == nil or item == nil then
		return false
	end
	-- Sin allowNegative: grantItem(-3) dejaria inventario negativo, que es el
	-- germen de "moneda de la nada" en cuanto exista un camino de venta.
	if not isSafeAmount(quantity, false) then
		warn(`[EconomyService] cantidad invalida para {player.Name}: {quantity}`)
		return false
	end
	local owned = profile.inventory[itemId] or 0
	if owned + quantity > item.maxStack then
		return false
	end
	profile.inventory[itemId] = owned + quantity
	push(player)
	return true
end

function EconomyService.getCatalog(): { [string]: ItemDefinition }
	return CATALOG
end

--[[ Handlers ]]

-- Los argumentos ya pasaron rate limit y validacion de tipos en RemoteService,
-- asi que aca solo quedan los chequeos de dominio.
local function onPurchase(player: Player, itemId: string, quantity: number)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local item = CATALOG[itemId]
	if item == nil then
		return
	end

	local owned = profile.inventory[itemId] or 0
	if owned + quantity > item.maxStack then
		return
	end

	local cost = item.price * quantity -- precio del catalogo del servidor
	local balances = profile :: any
	local field = FIELD_BY_CURRENCY[item.currency]
	if (balances[field] or 0) < cost then
		return
	end

	balances[field] -= cost
	profile.inventory[itemId] = owned + quantity
	push(player)
end

local function onSetSetting(player: Player, name: string, value: boolean)
	local profile = DataService.get(player)
	if profile == nil then
		return
	end
	local settings = profile.settings :: any
	settings[name] = value
	-- Sin este push el cliente nunca recupera lo que eligio al reconectar.
	push(player)
end

local function onGetState(player: Player): PublicState?
	local profile = DataService.get(player)
	if profile == nil then
		return nil
	end
	return publicState(profile)
end

function EconomyService.init()
	-- Si se agrega una moneda a Types.Currency y se olvida el mapa, field
	-- queda nil y el primer uso tira "table index is nil" en produccion.
	for _, currency in { "Coins", "Gems" } :: { Currency } do
		assert(FIELD_BY_CURRENCY[currency], `falta FIELD_BY_CURRENCY para {currency}`)
	end

	RemoteService.handle("Purchase", onPurchase)
	RemoteService.handle("SetSetting", onSetSetting)
	RemoteService.handle("GetState", onGetState)
end

function EconomyService.start()
	DataService.onReady(function(player)
		push(player)
	end)
end

return EconomyService
