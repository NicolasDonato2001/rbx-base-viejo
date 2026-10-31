--!strict
-- Acceso a remotes desde el cliente.
--
-- Centraliza los WaitForChild y valida contra el schema, asi un typo en el
-- nombre de un remote falla al arrancar en vez de silenciosamente nunca
-- disparar. El cliente nunca crea remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RemoteSchema = require(Shared.RemoteSchema)
local Types = require(Shared.Types)

local folder: Folder? = nil
local cache: { [string]: Instance } = {}

local NetController = {}

-- Resuelve un remote exigiendo tipo y direccion. Un send() sobre un
-- RemoteFunction, o un on() sobre un remote ClientToServer, fallan aca en vez
-- de reventar con "FireServer is not a valid member" o de no disparar nunca.
local function get(name: string, kind: Types.RemoteKind, direction: Types.RemoteDirection): Instance
	local spec = RemoteSchema[name]
	if spec == nil then
		error(`[NetController] "{name}" no esta en RemoteSchema`)
	end
	if spec.kind ~= kind then
		error(`[NetController] "{name}" es {spec.kind}, no {kind}`)
	end
	if spec.direction ~= direction then
		error(`[NetController] "{name}" es {spec.direction}, no {direction}`)
	end

	local remote = cache[name]
	if remote == nil then
		local remotesFolder = folder
		if remotesFolder == nil then
			error("[NetController] init() no corrio todavia")
		end
		-- Con timeout: si el servidor fallo al arrancar, el cliente avisa en
		-- vez de quedarse colgado para siempre.
		local found = remotesFolder:WaitForChild(name, 10)
		if found == nil then
			error(`[NetController] el remote "{name}" nunca aparecio`)
		end
		remote = found
		cache[name] = remote
	end
	return remote
end

-- Pedido sin respuesta al servidor.
function NetController.send(name: string, ...: any)
	local remote = get(name, "Event", "ClientToServer") :: RemoteEvent
	remote:FireServer(...)
end

-- Pedido con respuesta. Bloquea; usar solo en carga inicial, no por frame.
function NetController.request(name: string, ...: any): any
	local remote = get(name, "Function", "ClientToServer") :: RemoteFunction
	return remote:InvokeServer(...)
end

-- Escucha un evento que empuja el servidor.
function NetController.on(name: string, callback: (...any) -> ()): RBXScriptConnection
	local remote = get(name, "Event", "ServerToClient") :: RemoteEvent
	return remote.OnClientEvent:Connect(callback)
end

function NetController.init()
	local found = ReplicatedStorage:WaitForChild("Remotes", 15)
	if found == nil then
		error("[NetController] el servidor nunca creo la carpeta Remotes")
	end
	folder = found :: Folder
end

return NetController
