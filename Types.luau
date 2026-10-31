--!strict
-- Tipos compartidos entre cliente y servidor.
-- Todo lo que cruza la frontera (payloads de remotes, schema del perfil) se
-- declara aca para que ambos lados coincidan.

export type Currency = "Coins" | "Gems"

-- Schema persistido. Cambiarlo obliga a sumar una migracion en DataService.
export type Profile = {
	version: number,
	coins: number,
	gems: number,
	inventory: { [string]: number },
	stats: { [string]: number },
	settings: {
		music: boolean,
		sfx: boolean,
	},
	-- Metadata de sesion. No es dato de juego; lo administra DataService.
	-- sessionId es unico por carga: dos sesiones del mismo jugador en el mismo
	-- servidor son duenos distintos del perfil.
	lock: {
		sessionId: string,
		jobId: string,
		timestamp: number,
	}?,
}

-- Lo que el servidor replica al cliente. Deliberadamente NO es el perfil
-- completo: el cliente no necesita ver lock ni version.
export type PublicState = {
	coins: number,
	gems: number,
	inventory: { [string]: number },
	settings: {
		music: boolean,
		sfx: boolean,
	},
}

export type Validator = (value: unknown) -> boolean

export type RemoteKind = "Event" | "Function"

export type RemoteDirection = "ClientToServer" | "ServerToClient"

export type RemoteSpec = {
	kind: RemoteKind,
	direction: RemoteDirection,
	-- Validadores posicionales de los argumentos, despues de `player`.
	-- Solo aplica a ClientToServer; lo que sale del servidor no se valida.
	params: { Validator }?,
	-- Presupuesto por jugador. Sin esto el remote queda sin rate limit.
	rate: {
		perSecond: number,
		burst: number,
	}?,
}

export type ItemDefinition = {
	id: string,
	price: number,
	currency: Currency,
	maxStack: number,
}

return nil
