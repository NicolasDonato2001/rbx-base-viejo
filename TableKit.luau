--!strict
-- Utilidades de tablas sin dependencias.

local TableKit = {}

local MAX_DEPTH = 16

local function copy<T>(source: T, seen: { [any]: any }): T
	if typeof(source) ~= "table" then
		return source
	end
	local existing = seen[source :: any]
	if existing ~= nil then
		return existing
	end
	local result = {}
	seen[source :: any] = result
	for key, value in source :: any do
		result[key] = copy(value, seen)
	end
	return result :: any
end

-- Copia profunda. Necesaria para los perfiles por defecto: compartir la
-- referencia de una tabla default corrompe los datos entre jugadores.
-- Tolera ciclos (devuelve la misma copia para la misma tabla).
function TableKit.deepCopy<T>(source: T): T
	return copy(source, {})
end

-- Suma las claves que falten desde `defaults`, sin tocar las existentes.
-- Muta `target` in place y ademas lo devuelve por comodidad.
function TableKit.reconcile<T>(target: { [any]: any }, defaults: T): T
	for key, value in defaults :: any do
		if target[key] == nil then
			target[key] = TableKit.deepCopy(value)
		elseif typeof(value) == "table" and typeof(target[key]) == "table" then
			TableKit.reconcile(target[key], value)
		end
	end
	return target :: any
end

-- Resetea al default todo campo cuyo tipo no coincida con el esperado.
-- `reconcile` solo rellena claves faltantes: un `coins` guardado como string
-- por un bug viejo sobrevive intacto y revienta en el primer `coins + delta`.
function TableKit.coerceTypes<T>(
	target: { [any]: any },
	defaults: T,
	onFix: ((path: string) -> ())?,
	path: string?
): T
	local prefix = path or "profile"
	for key, expected in defaults :: any do
		local current = target[key]
		local expectedKind = typeof(expected)
		if typeof(current) ~= expectedKind then
			target[key] = TableKit.deepCopy(expected)
			if onFix then
				onFix(`{prefix}.{tostring(key)}`)
			end
		elseif expectedKind == "table" then
			TableKit.coerceTypes(current, expected, onFix, `{prefix}.{tostring(key)}`)
		end
	end
	return target :: any
end

local function checkValue(value: any, path: string, depth: number): (boolean, string?)
	if depth > MAX_DEPTH then
		return false, `{path}: anidamiento mayor a {MAX_DEPTH} niveles`
	end

	local kind = typeof(value)
	if kind == "string" or kind == "boolean" then
		return true, nil
	end
	if kind == "number" then
		if value ~= value then
			return false, `{path}: NaN`
		end
		if value == math.huge or value == -math.huge then
			return false, `{path}: infinito`
		end
		return true, nil
	end
	if kind ~= "table" then
		-- Instance, CFrame, Vector3, function, userdata...
		return false, `{path}: tipo {kind} no es serializable`
	end

	local arrayKeys = 0
	local hashKeys = 0
	for key, child in value do
		local keyKind = typeof(key)
		if keyKind == "number" then
			if key ~= key or key ~= math.floor(key) or key < 1 then
				return false, `{path}: clave numerica invalida`
			end
			arrayKeys += 1
		elseif keyKind == "string" then
			hashKeys += 1
		else
			return false, `{path}: clave de tipo {keyKind}`
		end

		local ok, problem = checkValue(child, `{path}.{tostring(key)}`, depth + 1)
		if not ok then
			return false, problem
		end
	end

	-- Roblox rechaza tablas con parte de array y parte de diccionario.
	if arrayKeys > 0 and hashKeys > 0 then
		return false, `{path}: mezcla claves de array y de diccionario`
	end
	-- Un array con huecos se trunca en el primer nil al serializar a JSON.
	if arrayKeys > 0 and #value ~= arrayKeys then
		return false, `{path}: el array tiene huecos`
	end

	return true, nil
end

-- Verifica que una tabla se pueda guardar en un DataStore. Sin este chequeo,
-- un Instance o un NaN que se cuele en el perfil hace fallar todos los saves
-- de ese jugador para siempre, y solo se nota por un warn.
function TableKit.isSerializable(value: any): (boolean, string?)
	return checkValue(value, "root", 0)
end

return TableKit
