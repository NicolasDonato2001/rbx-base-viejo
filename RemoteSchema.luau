--!strict
-- Declaracion central de todos los remotes del juego.
--
-- Un solo lugar donde viven el nombre, la direccion, la validacion y el rate
-- limit de cada remote. El servidor los crea desde aca (el cliente nunca crea
-- remotes) y RemoteService rechaza cualquier handler para un nombre que no
-- figure en este archivo.

local Guard = require(script.Parent.Util.Guard)
local Types = require(script.Parent.Types)

type RemoteSpec = Types.RemoteSpec

local schema: { [string]: RemoteSpec } = {
	-- El cliente pide el estado publico al entrar.
	GetState = {
		kind = "Function",
		direction = "ClientToServer",
		params = {},
		rate = { perSecond = 1, burst = 3 },
	},

	-- El servidor empuja el estado publico cuando cambia.
	StateChanged = {
		kind = "Event",
		direction = "ServerToClient",
	},

	-- Compra. El precio lo decide el catalogo del servidor, nunca el cliente.
	Purchase = {
		kind = "Event",
		direction = "ClientToServer",
		params = { Guard.boundedString(64), Guard.integer(1, 100) },
		rate = { perSecond = 3, burst = 5 },
	},

	-- Preferencias locales del jugador. Se persisten pero no afectan balance.
	SetSetting = {
		kind = "Event",
		direction = "ClientToServer",
		params = { Guard.oneOf({ "music", "sfx" }), Guard.boolean },
		rate = { perSecond = 2, burst = 6 },
	},

	-- Estado de la ronda, si el genero las usa.
	RoundChanged = {
		kind = "Event",
		direction = "ServerToClient",
	},

	GetRoundState = {
		kind = "Function",
		direction = "ClientToServer",
		params = {},
		rate = { perSecond = 1, burst = 3 },
	},
}

return table.freeze(schema)
