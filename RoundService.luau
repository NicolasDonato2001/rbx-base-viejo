--!strict
-- Loop de rondas generico: intermedio -> ronda -> intermedio.
--
-- Apagado por defecto (Config.ROUNDS_ENABLED). Sirve para arena, obby con
-- tiempo, battle royale o cualquier genero con partidas; un tycoon o un
-- sandbox lo dejan en false y no paga nada.
--
-- No sabe nada de mapas, spawns ni puntaje: expone los eventos y que cada
-- juego engancharse ahi.

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Config = require(Shared.Config)

local RemoteService = require(script.Parent.RemoteService)

export type Phase = "Waiting" | "Intermission" | "Active"

local phase: Phase = "Waiting"
local endsAt = 0
local roundNumber = 0

local onRoundStart: { (roundNumber: number) -> () } = {}
local onRoundEnd: { (roundNumber: number) -> () } = {}

local RoundService = {}

local function broadcast()
	RemoteService.fireAll("RoundChanged", {
		phase = phase,
		endsAt = endsAt,
		roundNumber = roundNumber,
	})
end

local function setPhase(nextPhase: Phase, duration: number)
	phase = nextPhase
	-- Reloj del servidor, no os.time(): el cliente compara contra su propio
	-- reloj y os.time() no esta sincronizado entre ambos.
	endsAt = if duration > 0 then workspace:GetServerTimeNow() + duration else 0
	broadcast()
end

function RoundService.getPhase(): Phase
	return phase
end

function RoundService.getRoundNumber(): number
	return roundNumber
end

function RoundService.onStart(callback: (roundNumber: number) -> ())
	table.insert(onRoundStart, callback)
end

function RoundService.onEnd(callback: (roundNumber: number) -> ())
	table.insert(onRoundEnd, callback)
end

local function snapshot()
	return {
		phase = phase,
		endsAt = endsAt,
		roundNumber = roundNumber,
	}
end

function RoundService.init()
	-- El cliente pide el estado cuando esta listo. Depender solo del push de
	-- PlayerAdded pierde el estado si el cliente todavia no conecto su
	-- OnClientEvent, y el proximo cambio de fase puede tardar una ronda entera.
	RemoteService.handle("GetRoundState", function()
		return snapshot()
	end)

	Players.PlayerAdded:Connect(function(player)
		RemoteService.fire(player, "RoundChanged", snapshot())
	end)
end

function RoundService.start()
	if not Config.ROUNDS_ENABLED then
		return
	end

	task.spawn(function()
		while true do
			-- Esperar jugadores suficientes.
			while #Players:GetPlayers() < Config.MIN_PLAYERS_TO_START do
				if phase ~= "Waiting" then
					setPhase("Waiting", 0)
				end
				task.wait(1)
			end

			setPhase("Intermission", Config.INTERMISSION_SECONDS)
			task.wait(Config.INTERMISSION_SECONDS)

			-- Pueden haberse ido mientras esperabamos.
			if #Players:GetPlayers() < Config.MIN_PLAYERS_TO_START then
				continue
			end

			roundNumber += 1
			setPhase("Active", Config.ROUND_SECONDS)
			for _, callback in onRoundStart do
				task.spawn(callback, roundNumber)
			end

			task.wait(Config.ROUND_SECONDS)

			for _, callback in onRoundEnd do
				task.spawn(callback, roundNumber)
			end
		end
	end)
end

return RoundService
