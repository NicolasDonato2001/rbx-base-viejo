--!strict
-- Espejo local del estado publico del jugador.
--
-- El cliente nunca decide este estado: lo pide una vez al entrar y despues
-- escucha los push del servidor. La UI lee de aca, nunca del servidor
-- directamente, y se entera de los cambios por subscribe().

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Types = require(Shared.Types)

local NetController = require(script.Parent.NetController)

type PublicState = Types.PublicState

local state: PublicState = {
	coins = 0,
	gems = 0,
	inventory = {},
	settings = { music = true, sfx = true },
}

-- Cuenta de pushes recibidos. La respuesta de GetState solo se aplica si no
-- llego ningun push mientras la invocacion estaba en vuelo; si no, pisaria un
-- estado mas nuevo con uno mas viejo.
local pushCount = 0
local listeners: { (state: PublicState) -> () } = {}

local StateController = {}

local function emit()
	for _, listener in listeners do
		task.spawn(listener, state)
	end
end

function StateController.get(): PublicState
	return state
end

-- Devuelve una funcion para desuscribirse. El callback se llama una vez de
-- entrada con el estado actual, asi la UI no necesita un caso especial para
-- "todavia no llego nada".
function StateController.subscribe(listener: (state: PublicState) -> ()): () -> ()
	table.insert(listeners, listener)
	task.spawn(listener, state)
	return function()
		local index = table.find(listeners, listener)
		if index then
			table.remove(listeners, index)
		end
	end
end

function StateController.init()
	NetController.on("StateChanged", function(nextState: PublicState)
		pushCount += 1
		state = nextState
		emit()
	end)
end

function StateController.start()
	-- El servidor devuelve nil mientras el perfil todavia carga, asi que se
	-- reintenta con backoff en vez de dejar la UI en cero hasta el proximo
	-- push espontaneo.
	local delaySeconds = 0.5
	for _ = 1, 6 do
		local pushesBefore = pushCount
		local initial = NetController.request("GetState")
		if pushCount > pushesBefore then
			return -- llego un push mas nuevo mientras esperabamos
		end
		if initial ~= nil then
			state = initial
			emit()
			return
		end
		task.wait(delaySeconds)
		delaySeconds = math.min(delaySeconds * 2, 4)
	end
	warn("[StateController] el servidor nunca devolvio estado")
end

return StateController
