--!strict
-- The 11 game states (PRD §3). GameStateManager is the only writer; everyone else reads.

local States = {
	MainMenu = "MainMenu",
	Intro = "Intro",
	Reality = "Reality",
	EventTrigger = "EventTrigger",
	DreamLayer = "DreamLayer",
	Objectives = "Objectives",
	Choice = "Choice",
	Ending = "Ending",
	Restart = "Restart",
	Pause = "Pause",
	GameOver = "GameOver",
}

-- States Pause may interrupt. Menu/Choice/Ending/GameOver are already "stopped".
local Pausable = {
	[States.Intro] = true,
	[States.Reality] = true,
	[States.EventTrigger] = true,
	[States.DreamLayer] = true,
	[States.Objectives] = true,
}

-- States where resources tick (oxygen drain, mission clock).
local Ticking = {
	[States.Reality] = true,
	[States.DreamLayer] = true,
	[States.Objectives] = true,
}

-- States where the character may walk. Everything else is a cutscene or a menu.
local FreeMovement = {
	[States.Reality] = true,
	[States.Objectives] = true,
}

return table.freeze({
	States = table.freeze(States),
	Pausable = table.freeze(Pausable),
	Ticking = table.freeze(Ticking),
	FreeMovement = table.freeze(FreeMovement),
})
