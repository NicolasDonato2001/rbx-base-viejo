--!strict
-- Validadores de argumentos de remotes.
--
-- Todo argumento que llega de un cliente es hostil hasta que se valida. Estos
-- helpers cubren los agujeros que mas se explotan: NaN pasa `typeof(x) ==
-- "number"`, math.huge pasa cualquier comparacion de tipo, y las tablas que
-- llegan por un remote pueden venir con claves mezcladas o huecos.

local Types = require(script.Parent.Parent.Types)

type Validator = Types.Validator

local Guard = {}

local function isFiniteNumber(value: unknown): boolean
	if typeof(value) ~= "number" then
		return false
	end
	local n = value :: number
	-- NaN nunca es igual a si mismo.
	if n ~= n then
		return false
	end
	return n > -math.huge and n < math.huge
end

function Guard.string(value: unknown): boolean
	return typeof(value) == "string"
end

-- String acotado. Sin tope de largo un cliente puede mandar megabytes.
function Guard.boundedString(maxLength: number): Validator
	return function(value: unknown): boolean
		return typeof(value) == "string" and #(value :: string) <= maxLength
	end
end

function Guard.boolean(value: unknown): boolean
	return typeof(value) == "boolean"
end

function Guard.number(min: number, max: number): Validator
	return function(value: unknown): boolean
		if not isFiniteNumber(value) then
			return false
		end
		local n = value :: number
		return n >= min and n <= max
	end
end

function Guard.integer(min: number, max: number): Validator
	return function(value: unknown): boolean
		if not isFiniteNumber(value) then
			return false
		end
		local n = value :: number
		return n == math.floor(n) and n >= min and n <= max
	end
end

-- Acepta solo uno de un conjunto cerrado de strings.
function Guard.oneOf(allowed: { string }): Validator
	local set: { [string]: true } = {}
	for _, item in allowed do
		set[item] = true
	end
	return function(value: unknown): boolean
		return typeof(value) == "string" and set[value :: string] == true
	end
end

-- Instancia de una clase concreta que todavia esta en el DataModel. Un cliente
-- puede mandar cualquier instancia que vea, incluida una ya destruida.
function Guard.instanceOf(className: string): Validator
	return function(value: unknown): boolean
		if typeof(value) ~= "Instance" then
			return false
		end
		local inst = value :: Instance
		return inst:IsA(className) and inst:IsDescendantOf(game)
	end
end

function Guard.optional(inner: Validator): Validator
	return function(value: unknown): boolean
		return value == nil or inner(value)
	end
end

-- Aplica una lista de validadores posicionales. Falla si sobran argumentos:
-- un handler que ignora extras es un handler que no sabe que recibio.
function Guard.check(params: { Validator }, args: { unknown }, count: number): boolean
	if count > #params then
		return false
	end
	for index, validator in params do
		if not validator(args[index]) then
			return false
		end
	end
	return true
end

return Guard
