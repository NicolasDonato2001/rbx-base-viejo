--!strict
-- Valores de balance. OJO: esto se replica al cliente, asi que no va nada
-- secreto aca, y el servidor nunca confia en un valor que el cliente reporte
-- de este archivo.

return table.freeze({
	-- Persistencia
	DATASTORE_NAME = "PlayerProfiles",
	DATASTORE_SCOPE = "v1",
	AUTOSAVE_INTERVAL = 60,
	-- Un lock mas viejo que esto se considera huerfano (servidor caido).
	LOCK_STALE_AFTER = 180,
	LOAD_ATTEMPTS = 5,
	SAVE_ATTEMPTS = 3,
	-- Margen antes de que Roblox mate el servidor en BindToClose.
	SHUTDOWN_BUDGET = 25,

	-- Economia
	STARTING_COINS = 0,
	STARTING_GEMS = 0,
	MAX_CURRENCY = 1e12,

	-- Rondas (dejar en false si el genero no usa rondas)
	ROUNDS_ENABLED = false,
	INTERMISSION_SECONDS = 15,
	ROUND_SECONDS = 180,
	MIN_PLAYERS_TO_START = 2,
})
