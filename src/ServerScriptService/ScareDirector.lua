--!strict
-- ScareDirector: server-side timing for every cue. The visuals (lighting tweens, the
-- silhouette rig, camera shake, stingers) run on the client in CameraEffects/Atmosphere,
-- because Lighting changes made client-side stay local to that player — which is what a
-- single-player horror beat wants. The server only decides WHEN and waits the duration,
-- so pause-aware timing and "never double-fire" live in one place.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayCue = (ReplicatedStorage :: any).Remotes.PlayCue :: RemoteEvent

-- Seconds the server holds the state while the client plays the cue.
local Durations: { [string]: number } = {
	Sleep = 3, -- slow fade to black, drifting off
	Wake = 2.5, -- fade in from black at the quarters
	Klaxon = 4,
	ShipArrives = 5,
	DeadStation = 4,
	AllAlarms = 4,
	ShadowFigure = 3.2,
	Flare = 4,
	JumpScare = 2.5,
	PassOut = 4,
	Static = 3.5, -- comms static, no reply
	Ending = 0, -- ending sequence is timed by GameStateManager line by line
}

local ScareDirector = {}
ScareDirector.Durations = Durations

-- Fires the cue and blocks (pause-aware, via session wait) for its duration.
function ScareDirector.Play(session: any, cue: string, params: { [string]: any }?)
	local duration = Durations[cue]
	if duration == nil then
		warn("[ScareDirector] unknown cue", cue)
		duration = 1
	end
	session.firedCues[cue] = (session.firedCues[cue] or 0) + 1
	PlayCue:FireClient(session.player, cue, params or {})
	if duration > 0 then
		session:Wait(duration)
	end
end

-- Fire-and-forget (no wait). For ambient beats that overlap gameplay.
function ScareDirector.Fire(session: any, cue: string, params: { [string]: any }?)
	PlayCue:FireClient(session.player, cue, params or {})
end

return ScareDirector
