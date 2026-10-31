--!strict
-- Punto de entrada del servidor.
--
-- Bootstrap en dos fases y en orden explicito: primero init() de todos los
-- sistemas (crear remotes, conectar eventos), despues start() (loops y
-- trabajo que puede ceder). El orden es explicito y no un recorrido de
-- carpeta porque RemoteService tiene que crear los remotes antes de que
-- cualquier otro sistema registre un handler.

local Systems = script:WaitForChild("Systems")

local BOOT_ORDER = {
	"RemoteService",
	"DataService",
	"EconomyService",
	"RoundService",
}

local loaded = {}

for _, name in BOOT_ORDER do
	local module = Systems:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		error(`[boot] falta el sistema "{name}" en Systems`)
	end
	table.insert(loaded, { name = name, system = require(module) :: any })
end

-- pcall por sistema: sin esto, un init() que tira corta el arranque y los
-- sistemaes siguientes nunca corren, en silencio.
for _, entry in loaded do
	if typeof(entry.system.init) == "function" then
		local ok, err = pcall(entry.system.init)
		if not ok then
			warn(`[boot] init() de "{entry.name}" fallo: {err}`)
		end
	end
end

for _, entry in loaded do
	if typeof(entry.system.start) == "function" then
		task.spawn(function()
			local ok, err = pcall(entry.system.start)
			if not ok then
				warn(`[boot] start() de "{entry.name}" fallo: {err}`)
			end
		end)
	end
end

print(`[rbx-base] servidor arriba con {#loaded} sistemas`)
