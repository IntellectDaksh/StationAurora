--!strict
-- Story data: every objective, dream and ending as plain tables (PRD §4, §5).
-- Server and client both read this; nothing here has side effects.

export type ObjectiveDef = {
	id: string,
	tag: string?, -- CollectionService tag on the station geometry (nil for clientAction)
	part: string?, -- child part that carries the prompt (defaults to PrimaryPart)
	text: string, -- HUD line
	action: string, -- ProximityPrompt ActionText
	hold: number, -- ProximityPrompt HoldDuration
	handler: string, -- ModuleScript in ServerScriptService.ObjectiveHandlers
	repairCost: number?, -- Repair Units consumed on completion
	minigame: string?, -- client minigame kind opened by the prompt (see GameStateManager header)
	minigameParams: { [string]: any }?,
	minTime: number?, -- anti-skip: seconds the minigame must stay open before success counts
	clientAction: boolean?, -- tutorial step the client reports (no prompt)
	reach: number?, -- completes within this many studs of the tagged part (no prompt)
	beatOnActivate: string?, -- Beats id
	beatOnComplete: string?, -- Beats id
	hint: string?, -- short "how" line for the HUD tracker
	object: string?,
	optional: boolean?, -- never holds the day; HUD text carries the "(Optional) " prefix
	group: string?, -- either/or: completing one member settles (and hides) the rest
	external: boolean?, -- no prompt: completed by another system (EVA event, data pads)
	pod: boolean?, -- R_Sleep only: prompt lives on the SleepPod, built by GameStateManager -- ProximityPrompt ObjectText (applied client-side by Minigames)
}

export type DreamEvent = {
	id: string,
	index: number,
	name: string,
	location: string,
	triggerTitle: string, -- DreamLayer cutscene headline
	triggerCue: string, -- PlayCue fired on DreamLayer entry
	objectives: { string }, -- ObjectiveDef ids, all required
	followUp: { string }?, -- objectives unlocked once `objectives` are done
	resultIfClean: string,
	scare: string?, -- ScareDirector id, played in EventTrigger after objectives
	resourcePreset: { [string]: number }, -- applied on dream entry (deterministic)
	oxygenDrain: number, -- per second while in Objectives
	canFail: boolean,
	nextState: string,
}

local Objectives: { [string]: ObjectiveDef } = {}
local function def(d: ObjectiveDef)
	Objectives[d.id] = d
end

local KEYPAD_CODE = "2417" -- comms auth code: shown in the Transmit minigame and on the comms screen

-- Tutorial (first minutes of Reality). clientAction steps are reported by the client.
def({ id = "T_Move", text = "Get out of bed and stretch your legs", action = "", hold = 0, handler = "Tutorial", clientAction = true, hint = "WASD / left stick to move" })
def({ id = "T_Flashlight", text = "Grab your torch", action = "", hold = 0, handler = "Tutorial", clientAction = true, hint = "Press F to switch on your torch", beatOnActivate = "Reality_Wake", beatOnComplete = "Torch_On" })
def({ id = "T_Journal", text = "Check today's checklist", action = "", hold = 0, handler = "Tutorial", clientAction = true, hint = "Press Tab to open the checklist" })

def({ id = "T_FindGenerator", tag = "Objective_Generator", part = "GeneratorPanel", text = "Find the backup generator", action = "", hold = 0, handler = "Tutorial", reach = 14, hint = "Follow the glowing floor markers", beatOnActivate = "Gen_Find" })
def({ id = "R_Generator", tag = "Objective_Generator", part = "GeneratorPanel", text = "Restart the backup generator", action = "Start generator", hold = 0, handler = "Generator", minigame = "Generator", minTime = 3, hint = "Hold E at the generator panel", beatOnComplete = "Gen_Online" })

-- Reality layer (tutorial for every mechanic the dreams reuse)
def({ id = "R_LSReadout", tag = "Task_LifeSupportReadout", part = "ConsoleScreen", text = "Calibrate the life-support readout", action = "Calibrate", object = "Life support", hold = 0, handler = "RealityTasks",
	minigame = "Breaker", minTime = 2, minigameParams = { label = "LS", length = 3 }, hint = "Repeat the scrubber relay sequence" , beatOnComplete = "T_LS_Done" })
def({ id = "R_StatusLog", tag = "Task_StatusLog", part = "ConsoleScreen", text = "File the morning status report", action = "File report", object = "Status log", hold = 0, handler = "RealityTasks",
	minigame = "LogReport", minTime = 3, minigameParams = {}, hint = "Match the live O2, power and hull readings" , beatOnComplete = "T_Log_Done" })
def({ id = "R_Hydroponics", tag = "Task_Hydroponics", part = "WaterValve", text = "Water the hydroponics rack", action = "Water plants", object = "Hydroponics", hold = 0, handler = "RealityTasks",
	minigame = "WaterGauge", minTime = 3, minigameParams = { trays = 3 }, hint = "Hold to fill, release in the green" })
def({ id = "R_TaskBoard", tag = "Task_TaskBoard", part = "ConsoleScreen", text = "Review the task board", action = "Review tasks", object = "Task board", hold = 0, handler = "RealityTasks",
	minigame = "TaskBoard", minTime = 3, minigameParams = {}, hint = "Acknowledge every line" , beatOnComplete = "T_Board_Done" })
def({ id = "R_Distress", tag = "Objective_Comms", part = "BtnMain", text = "Send a distress signal from comms", action = "Open transmitter", object = "Comms", hold = 0, handler = "DistressSignal",
	minigame = "Transmit", minTime = 4, minigameParams = { code = KEYPAD_CODE }, hint = "Tune to the carrier, then enter the auth code" })
def({ id = "R_CheckReply1", tag = "Objective_Comms", part = "ConsoleScreen", text = "Check comms for a reply", action = "Check for reply", object = "Comms", hold = 0.5, handler = "DistressSignal" })
def({ id = "R_CheckReply2", tag = "Objective_Comms", part = "ConsoleScreen", text = "Check comms again", action = "Check again", object = "Comms", hold = 0.5, handler = "DistressSignal" })

-- Dream 1
def({ id = "D1_Windows", tag = "Objective_Windows", text = "Check the observation windows", action = "Check windows", object = "Observation window", hold = 0.3, handler = "RadarCheck" })
def({ id = "D1_Radar", tag = "Objective_Radar", part = "ConsoleScreen", text = "Run a radar sweep", action = "Run sweep", object = "Radar", hold = 0, handler = "RadarCheck",
	minigame = "RadarSweep", minTime = 5, minigameParams = { blips = 4 }, hint = "Tag each contact while the sweep lights it" })
def({ id = "D1_Quarters", tag = "Zone_Quarters", part = "WakePoint", text = "Go back to your quarters", action = "Lie down", object = "Bunk", hold = 0, handler = "RadarCheck" })
-- Dream 2
def({ id = "D2_Observatory", tag = "Objective_Observatory", part = "Eyepiece", text = "Identify the ship from the observatory", action = "Look through scope", object = "Telescope", hold = 0, handler = "ObservatoryCheck",
	minigame = "Telescope", minTime = 4, minigameParams = { target = "ForeignShip" }, hint = "Sweep the scope, lock the ship" })
-- Dream 3 (breakers: repeat the relay sequence; longer each time)
def({ id = "D3_Breaker1", tag = "Objective_PowerGrid", part = "Breaker1", text = "Reset breaker A", action = "Reset breaker", object = "Breaker A", hold = 0, handler = "PowerGridRepair", repairCost = 1,
	minigame = "Breaker", minTime = 3, minigameParams = { label = "A", length = 3 }, hint = "Repeat the relay sequence" })
def({ id = "D3_Breaker2", tag = "Objective_PowerGrid", part = "Breaker2", text = "Reset breaker B", action = "Reset breaker", object = "Breaker B", hold = 0, handler = "PowerGridRepair", repairCost = 1,
	minigame = "Breaker", minTime = 3, minigameParams = { label = "B", length = 4 }, hint = "Repeat the relay sequence" })
def({ id = "D3_Breaker3", tag = "Objective_PowerGrid", part = "Breaker3", text = "Reset breaker C", action = "Reset breaker", object = "Breaker C", hold = 0, handler = "PowerGridRepair", repairCost = 1,
	minigame = "Breaker", minTime = 3, minigameParams = { label = "C", length = 5 }, hint = "Repeat the relay sequence" })
-- Dream 4 (valves: turn fast, keep pressure out of the red)
def({ id = "D4_Valve1", tag = "Objective_LifeSupport", part = "Valve1", text = "Open O2 valve 1", action = "Turn valve", object = "O2 valve 1", hold = 0, handler = "OxygenRepair", repairCost = 1,
	minigame = "Valve", minTime = 3, minigameParams = { label = "1", turns = 2 }, hint = "Turn the valve, keep pressure out of the red" })
def({ id = "D4_Valve2", tag = "Objective_LifeSupport", part = "Valve2", text = "Open O2 valve 2", action = "Turn valve", object = "O2 valve 2", hold = 0, handler = "OxygenRepair", repairCost = 1,
	minigame = "Valve", minTime = 3, minigameParams = { label = "2", turns = 2.5 }, hint = "Turn the valve, keep pressure out of the red" })
def({ id = "D4_Valve3", tag = "Objective_LifeSupport", part = "Valve3", text = "Open O2 valve 3", action = "Turn valve", object = "O2 valve 3", hold = 0, handler = "OxygenRepair", repairCost = 1,
	minigame = "Valve", minTime = 3, minigameParams = { label = "3", turns = 3 }, hint = "Turn the valve, keep pressure out of the red" })

def({ id = "R_Recycler", tag = "Task_Recycler", part = "RecyclerPanel", text = "Fix the water recycler in the washroom", action = "Repair recycler", hold = 0, handler = "RealityTasks", minigame = "Valve", minTime = 2, minigameParams = { label = "H2O", turns = 1.5 }, hint = "Washroom. Turn the recycler valve, keep pressure out of the red" , beatOnComplete = "T_Recycler_Done" })
-- pod = true: no auto prompt; GameStateManager builds one always-visible prompt on the SleepPod
-- (tag SleepPod, part Bed) so pressing it early can say "Finish today's tasks first".
def({ id = "R_Sleep", pod = true, text = "Go to sleep in your pod", action = "Sleep", hold = 0.4, handler = "RealityTasks", hint = "Your pod is in the crew quarters. Hold E to sleep" })

local Reality = {
	oxygenDrain = 0.225, taskTimeLimit = 300, -- Day 1: 5 min for the daily tasks or the reactor melts down -- per second after the generator: a full tank lasts ~3.5 min; refill at O2Refill stations
	sleep = { "R_Sleep" }, -- reused every day (cleared before each night) -- only after every daily task + the distress call
	-- v2 opening: blackout during standby cycle -> torch -> find + restore backup generator (Power 0 -> 100)
	tutorial = { "T_Flashlight", "T_FindGenerator", "R_Generator" }, -- strict order, first run only
	tasks = { "R_LSReadout", "R_StatusLog", "R_TaskBoard", "R_Recycler" }, -- any order
	distress = { "R_Distress", "R_CheckReply1", "R_CheckReply2" }, -- strict order, unlocked after tasks
	keypadCode = KEYPAD_CODE, -- shown on the comms screen and in the Transmit minigame
}

-- Day 2: the ship is outside
def({ id = "R_Telescope", tag = "Objective_Observatory", text = "Find the contact from the observatory", action = "Use telescope", object = "Observatory scope", hold = 0, handler = "RealityTasks",
	minigame = "Telescope", minTime = 4, minigameParams = { target = "ForeignShip" }, hint = "Sweep the scope, lock the ship", beatOnComplete = "Scope_Lock" })
def({ id = "R_PipeRoute2", tag = "Task_Recycler", part = "RecyclerPanel", text = "Reroute recycler coolant", action = "Reroute pipes", object = "Water recycler", hold = 0, handler = "RealityTasks",
	minigame = "PipeRoute", minTime = 2, minigameParams = { size = 3 }, hint = "Washroom. Connect inlet to outlet" , beatOnComplete = "T_Pipe2_Done" })
def({ id = "R_StatusLog2", tag = "Task_StatusLog", part = "ConsoleScreen", text = "Log the unknown contact", action = "File report", object = "Status log", hold = 0, handler = "RealityTasks",
	minigame = "LogReport", minTime = 3, minigameParams = {}, hint = "File today's report" })
def({ id = "R_CheckReply3", tag = "Objective_Comms", part = "ConsoleScreen", text = "Hail the ship on comms", action = "Hail", object = "Comms", hold = 0.3, handler = "RealityTasks", beatOnComplete = "Hail_NoAnswer" })
-- Day 3: things drift
def({ id = "R_CargoSort3", tag = "Task_Hydroponics", text = "Sort the supply crates", action = "Sort crates", object = "Supply crates", hold = 0, handler = "RealityTasks",
	minigame = "CargoSort", minTime = 3, minigameParams = { crates = 6 }, hint = "Match crates to their bays" })
def({ id = "R_Calibrate3", tag = "Task_LifeSupportReadout", part = "ConsoleScreen", text = "Recalibrate hull sensors", action = "Calibrate", object = "Hull sensors", hold = 0, handler = "RealityTasks",
	minigame = "Calibrate", minTime = 3, minigameParams = { labels = { "HULL STRAIN", "RADIATION", "PROXIMITY" } }, hint = "Set all three needles in green" , beatOnComplete = "T_Cal3_Done" })
def({ id = "R_Hydro3", tag = "Task_Hydroponics", part = "WaterValve", text = "Water the hydroponics rack", action = "Water plants", object = "Hydroponics", hold = 0, handler = "RealityTasks",
	minigame = "WaterGauge", minTime = 3, minigameParams = {}, hint = "Stop the gauge in the band" })
def({ id = "R_CheckReply4", tag = "Objective_Comms", part = "ConsoleScreen", text = "Listen to the comms channel", action = "Listen", object = "Comms", hold = 0.3, handler = "RealityTasks", beatOnComplete = "Comms_Voice" })
-- Day 4: last day before the choice
def({ id = "R_PipeRoute4", tag = "Objective_LifeSupport", part = "ConsoleScreen", text = "Reroute O2 lines", action = "Reroute pipes", object = "Life support", hold = 0, handler = "RealityTasks",
	minigame = "PipeRoute", minTime = 2, minigameParams = { size = 3 }, hint = "Connect inlet to outlet" , beatOnComplete = "T_Pipe4_Done" })
def({ id = "R_Calibrate4", tag = "Task_Recycler", part = "RecyclerPanel", text = "Calibrate the water recycler", action = "Calibrate", object = "Water recycler", hold = 0, handler = "RealityTasks",
	minigame = "Valve", minTime = 2, minigameParams = { label = "H2O", turns = 2 }, hint = "Washroom. Turn the valve, keep pressure out of the red" , beatOnComplete = "T_Cal4_Done" })
def({ id = "R_TaskBoard4", tag = "Task_TaskBoard", part = "ConsoleScreen", text = "Review the task board", action = "Review tasks", object = "Task board", hold = 0, handler = "RealityTasks",
	minigame = "TaskBoard", minTime = 3, minigameParams = {}, hint = "Acknowledge every line" , beatOnComplete = "T_Board4_Done" })
def({ id = "R_Transmit4", tag = "Objective_Comms", part = "BtnMain", text = "Answer the ship", action = "Open transmitter", object = "Comms", hold = 0, handler = "RealityTasks", group = "Answer",
	minigame = "Transmit", minTime = 4, minigameParams = { code = KEYPAD_CODE }, hint = "Tune carrier, then enter auth code", beatOnComplete = "Ship_Answer" })
-- ...or don't. Pulling the comms breaker is the other half of the same choice.
def({ id = "R_CommsBreaker", tag = "Objective_PowerGrid", part = "Cabinet", text = "Or stay silent: pull the comms breaker", action = "Pull comms breaker", object = "Power grid", hold = 0.5, handler = "RealityTasks", group = "Answer",
	hint = "Power grid, lower deck. Hold E", beatOnComplete = "Ship_Silent" })

-- Optional (story choices / finds). external = completed by another system, no prompt.
def({ id = "O_Dish", external = true, optional = true, text = "(Optional) Repair the comms dish outside", action = "", hold = 0, handler = "RealityTasks", hint = "Suit up at the airlock. Someone might hear us." })
def({ id = "O_Logs", external = true, optional = true, text = "(Optional) Find the crew's data pads", action = "", hold = 0, handler = "RealityTasks", hint = "Six pads. Look where the crew lived." })
-- Night choice (after the breakers): AURA wants you back in the pod; something knocks in the washroom.
def({ id = "D3_Pod", tag = "SleepPod", part = "Bed", reach = 7, leaveFirst = true, group = "Knock", text = "Go back to your pod", action = "", hold = 0, handler = "RealityTasks", beatOnComplete = "Knock_Comply", hint = "AURA is asking nicely." })
def({ id = "D3_Knock", tag = "Task_Recycler", part = "RecyclerPanel", reach = 9, group = "Knock", optional = true, text = "(Optional) Find the knocking", action = "", hold = 0, handler = "RealityTasks", beatOnComplete = "Knock_Found", hint = "It's coming from the washroom." })

-- Story days. Day N = reality tasks, sleep, then Dream N that night; waking is Day N+1.
-- Day 1 runs Reality.tutorial/tasks/distress; later days run `tasks` (any order).
-- intro = Beats id played at day start; log = objective-log lines under the HUD day badge.
-- v3 arc (brief §3): three mission days. `dreams` = the night's anomaly sequence (internal ids only;
-- never shown). The player only ever sees MISSION DAY <MissionDayStart + day - 1>.
local MissionDayStart = 212
local Days = {
	{ day = 1, time = "06:40", title = "Standby cycle", intro = "Day1_Intro", dreams = { 1, 2 },
		log = { "Station went dark in the standby cycle.", "Five crew are off-station. The shuttle missed check-in.", "Restore power, run the checklist, call for help." } },
	{ day = 2, time = "06:40", title = "Contact", intro = "Day2_Intro", dreams = { 3 },
		tasks = { "R_Telescope", "R_PipeRoute2", "R_CheckReply3", "R_CheckReply4", "O_Dish", "O_Logs" },
		log = { "Distress call still unanswered. The ship from last night is still off the west window.", "Overnight faults are still logged. Nothing was reset.", "Identify the contact, hail it, keep the station running." } },
	{ day = 3, time = "06:40", title = "Threshold", intro = "Day4_Intro", dreams = { 4 },
		tasks = { "R_Calibrate3", "R_PipeRoute4", "R_Calibrate4", "R_TaskBoard4", "R_Transmit4", "R_CommsBreaker", "O_Logs" },
		log = { "Grid damage from last night is still in the log.", "The ship is broadcasting on the crew channel.", "Answer it. Or pull the plug and stay quiet." } },
}

local Dreams: { DreamEvent } = {
	{
		id = "D1", index = 1, name = "System Anomaly", location = "Windows & Radar Scanner",
		triggerTitle = "SYSTEM ANOMALY DETECTED", triggerCue = "Klaxon",
		objectives = { "D1_Windows", "D1_Radar" }, followUp = { "D1_Quarters" },
		resultIfClean = "No anomaly found.", scare = "ShadowFigure",
		resourcePreset = { Power = 100, Oxygen = 97, HullIntegrity = 100 },
		oxygenDrain = 0.02, canFail = false, nextState = "Blackout -> Dream 2",
	},
	{
		id = "D2", index = 2, name = "The Foreign Ship", location = "Observatory",
		triggerTitle = "ALL LIGHTS OFFLINE", triggerCue = "ShipArrives",
		objectives = { "D2_Observatory" },
		resultIfClean = "Ship locked. It isn't moving. Neither are you.", scare = "Flare",
		resourcePreset = { Power = 15, Oxygen = 95, HullIntegrity = 100 },
		oxygenDrain = 0.02, canFail = false, nextState = "Flare -> Dream 3",
	},
	{
		id = "D3", index = 3, name = "Power Down", location = "Power grid",
		triggerTitle = "MAIN BUS OFFLINE", triggerCue = "DeadStation",
		objectives = { "D3_Breaker1", "D3_Breaker2", "D3_Breaker3" }, followUp = { "D3_Pod", "D3_Knock" },
		resultIfClean = "Power restored.", scare = "JumpScare",
		resourcePreset = { Power = 0, Oxygen = 90, HullIntegrity = 75 },
		oxygenDrain = 0.05, canFail = false, nextState = "Jump-scare -> Dream 4",
	},
	{
		id = "D4", index = 4, name = "Cascading Failure", location = "Life support",
		triggerTitle = "O2 CRITICAL // MULTIPLE FAULTS", triggerCue = "AllAlarms",
		objectives = { "D4_Valve1", "D4_Valve2", "D4_Valve3" },
		resultIfClean = "O2 flow restored.", scare = "PassOut",
		resourcePreset = { Power = 60, Oxygen = 60, HullIntegrity = 70 },
		oxygenDrain = 0.4, canFail = true, nextState = "Pass out -> Choice",
	},
}

local Intro = {
	"STATION AURORA",
	"Mission day 212. Orbit stable.",
	"Crew rotation: 6 aboard.",
	"Crew awake: 1.",
	"%s. Morning checklist.",
}

-- Choice x contact (DishFixed or Transmitted). id = the choice (HUD styling); key = cinematic suffix.
local Endings = {
	Dream = {
		id = "Dream",
		title = "THE LONG SLEEP",
		lines = {
			"You close your eyes. The alarms stop asking.",
			"The galley smells like burnt toast. Okafor swears it's on purpose.",
			"Reyes saved your seat. Mercer's tape hisses into the first song.",
			"Far below, a dish turns toward you. It found you. You didn't wake up.",
			"Frost creeps over the pod glass, slow as breathing.",
			"Station Aurora. Silent for 3 years. One heartbeat aboard.",
		},
	},
	Dream_Silent = {
		id = "Dream",
		title = "THE LONG SLEEP",
		lines = {
			"You close your eyes. No one is calling. You made sure of that.",
			"The galley is warm. Every chair is empty, and pushed in.",
			"You still see their faces. Only ever in the glass.",
			"Frost creeps over the pod glass, slow as breathing.",
			"Station Aurora. Silent for 3 years. It will stay that way.",
		},
	},
	Reality = {
		id = "Reality",
		title = "WAKING HOURS",
		lines = {
			"You don't go back to sleep. Your hand stays on the valve.",
			"The O2 needle climbs. Slowly. For real this time.",
			"Static breaks: \"Aurora, this is relief vessel Kestrel. We hear you.\"",
			"The hatch cycles open. Okafor. Reyes. Lindqvist. Mercer. Tanaka.",
			"Nobody speaks. Okafor just puts a hand on your shoulder.",
			"The ship was never a dream. It came back for you.",
		},
	},
	Reality_Silent = {
		id = "Reality",
		title = "WAKING HOURS",
		lines = {
			"You don't go back to sleep. Your hand stays on the valve.",
			"The O2 needle climbs. There's no one to tell.",
			"A ship slides past the west window. It doesn't slow down.",
			"You never answered. To them, Aurora is just debris.",
			"In the glass, five faces stand behind you. Then it's only yours.",
		},
	},
}

-- Appended by GameStateManager.phaseEnding from save flags.
local EndingExtras = {
	Knocked = "The knocking stopped the night you went to look.",
	Complied = "AURA thanks you for staying in the pod. It always will.",
	AllLogs = "Log 1,096, unsigned: \"If you found all six, you already know what day it is.\"",
}

return table.freeze({
	Objectives = table.freeze(Objectives),
	Reality = table.freeze(Reality),
	Dreams = table.freeze(Dreams),
	Days = table.freeze(Days),
	MissionDayStart = MissionDayStart,
	Intro = table.freeze(Intro),
	Endings = table.freeze(Endings),
	EndingExtras = table.freeze(EndingExtras),
	DefaultOperatorName = "Sam Ortega",
})
