--!strict
-- Cinematic registry. The server reads ONLY `duration` (it holds the state that long,
-- pause-aware) and `skippable`. The client Cinematics script owns everything else
-- (shots, captions, letterbox) and may add any fields it needs per entry.
-- Hook points the director calls (missing id = skipped silently):
--   Opening        Intro state, before Reality (skippable)
--   Drift          end of Reality, before the Sleep fade into Dream 1
--   Dream1..Dream4 DreamLayer, played together with that dream's trigger cue
--   Choice         EventTrigger, right before the Dream/Reality prompt
--   Ending_Dream / Ending_Reality   Ending state, before the ending lines
--   GameOver       GameOver state entry (no CinematicEnd is sent: the client ends it at `duration`)
-- Shots/captions live in StarterPlayerScripts.Cinematics and are authored to these durations;
-- change a duration here and retime that cinematic's shot list to match (it warns on mismatch).

export type Cinematic = {
	duration: number,
	skippable: boolean?,
	[string]: any,
}

local Cinematics: { [string]: Cinematic } = {
	Opening = { duration = 41, skippable = true }, -- lit exterior + title, calm night hall/pods, power failure on camera, red pulse -> player (AURA subtitles)
	Meltdown = { duration = 12 }, -- Day 1 timer ran out: reactor overload, station explodes
	Refill = { duration = 2.5 }, -- client-only: O2 tank refill close-up
	PowerOn = { duration = 12, skippable = true }, -- generator starts, station comes back section by section
	Drift = { duration = 14, skippable = true }, -- station exterior, crane down onto the player
	Dream1 = { duration = 13, skippable = true }, -- (Klaxon) low handheld on player, push-in on the NAV/radar console
	Dream2 = { duration = 12 }, -- (ShipArrives) dark gallery swept by the ship's lights, push to the west window, silhouette across Earth
	Dream3 = { duration = 12, skippable = true }, -- (DeadStation) gallery lights die, over-shoulder into the dark
	Dream4 = { duration = 12, skippable = true }, -- (AllAlarms) three shaky cuts: gallery, console, player
	Choice = { duration = 6 }, -- abstract void: two lights drifting together
	-- Endings: Choice x contact (DishFixed or Transmitted). _Silent = no contact was ever made.
	Ending_Dream = { duration = 20 }, -- warm galley, crew laughing, your empty seat; pull out to the frost-sealed pod
	Ending_Dream_Silent = { duration = 16 }, -- cold galley, crew only as fading reflections; frost-sealed pod
	Ending_Reality = { duration = 20 }, -- Kestrel docks, crew float in through the airlock, Okafor nods, Earth
	Ending_Reality_Silent = { duration = 16 }, -- a ship passes without slowing; five faces in the glass, then one
	ChoiceTransmit = { duration = 6 }, -- day 214: answer sent, beam to the ship
	ChoiceSilent = { duration = 6 }, -- day 214: comms breaker pulled
	DishFixed = { duration = 6 }, -- EVA dish repair: dish aligned, carrier found
	GameOver = { duration = 4, selfEnd = true },
	Day2Contact = { duration = 14, skippable = true }, -- Day 2 wake: station against real stars, a distant light moving off the west window
	Respawn = { duration = 4 }, -- every death: black, heartbeat, DEATHS: N + rotating line, then back to the day checkpoint
	DayEnd = { duration = 7.5 }, -- HUD-only (no camera shots): fade, DAY N COMPLETE + autosave ring, DAY N+1 card
}

return Cinematics
