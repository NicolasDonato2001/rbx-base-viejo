--!strict
-- Punto de entrada del cliente. Mismo bootstrap en dos fases y en orden
-- explicito que el servidor: NetController tiene que resolver la carpeta de
-- remotes antes de que otro controlador la use.

local Controllers = script:WaitForChild("Controllers")

local BOOT_ORDER = {
	"NetController",
	"StateController",
}

local loaded = {}

for _, name in BOOT_ORDER do
	local module = Controllers:FindFirstChild(name)
	if module == nil or not module:IsA("ModuleScript") then
		error(`[boot] falta el controlador "{name}" en Controllers`)
	end
	table.insert(loaded, { name = name, controller = require(module) :: any })
end

-- pcall por controlador: sin esto, un init() que tira corta el arranque y los
-- controladores siguientes nunca corren, en silencio.
for _, entry in loaded do
	if typeof(entry.controller.init) == "function" then
		local ok, err = pcall(entry.controller.init)
		if not ok then
			warn(`[boot] init() de "{entry.name}" fallo: {err}`)
		end
	end
end

for _, entry in loaded do
	if typeof(entry.controller.start) == "function" then
		task.spawn(function()
			local ok, err = pcall(entry.controller.start)
			if not ok then
				warn(`[boot] start() de "{entry.name}" fallo: {err}`)
			end
		end)
	end
end

print(`[rbx-base] cliente arriba con {#loaded} controladores`)
