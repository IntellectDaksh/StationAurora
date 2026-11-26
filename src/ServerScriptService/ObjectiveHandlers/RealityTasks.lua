--!strict
-- Reality morning checklist: mundane, lived-in feedback. Each task is a client minigame;
-- success lands in onTriggered (GameStateManager falls back to it without a prompt).
local CollectionService = game:GetService("CollectionService")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local DEFAULT_ATTR = "AuroraDefaultText"
local REST_COLOR = "AuroraRestColor"

local Lines: { [string]: { screen: string?, toast: string } } = {
	R_LSReadout = { screen = "O2 98.1% // SCRUBBERS NOMINAL", toast = "Readouts normal. Same as yesterday." },
	R_StatusLog = { screen = "STATUS LOG 212 FILED\nNOTHING TO REPORT", toast = "Day 212 logged. Nothing to report. Again." },
	R_Hydroponics = { toast = "Plants watered. The basil's coming back." },
	R_TaskBoard = {
		screen = "DAY 212 TASKS\n- READOUTS\n- STATUS LOG\n- WATER RACK\n- CALL HOME: PENDING",
		toast = "Same list as always.",
	},
	-- R_Recycler's tagged model may have no ConsoleScreen/StatusText yet (built by
	-- another agent); setScreen/statusLabels already no-op gracefully if absent.
	R_Recycler = { screen = "RECYCLER ONLINE // FLOW NOMINAL", toast = "Water recycler back online." },
}

-- Screen text while the minigame is open (diegetic "someone is working here").
local Busy: { [string]: string } = {
	R_LSReadout = "CALIBRATING SENSORS...",
	R_StatusLog = "STATUS LOG 212 // ENTRY OPEN",
	R_TaskBoard = "REVIEWING DAY 212...",
	R_Recycler = "RECALIBRATING RECYCLER...",
}

local function statusLabels(tag: string): { TextLabel }
	local list = {}
	local inst = CollectionService:GetTagged(tag)[1]
	if inst then
		for _, d in inst:GetDescendants() do
			if d.Name == "StatusText" and d:IsA("TextLabel") then
				table.insert(list, d)
			end
		end
	end
	return list
end

local function setScreen(tag: string, text: string?)
	for _, t in statusLabels(tag) do
		if t:GetAttribute(DEFAULT_ATTR) == nil then
			t:SetAttribute(DEFAULT_ATTR, t.Text)
		end
		local default = t:GetAttribute(DEFAULT_ATTR)
		t.Text = text or (if type(default) == "string" then default else t.Text)
	end
end

local function soils(): { BasePart }
	local list = {}
	local rack = CollectionService:GetTagged("Task_Hydroponics")[1]
	if rack then
		for _, d in rack:GetDescendants() do
			if d:IsA("BasePart") and string.sub(d.Name, 1, 4) == "Soil" then
				if d:GetAttribute(REST_COLOR) == nil then
					d:SetAttribute(REST_COLOR, d.Color)
				end
				table.insert(list, d)
			end
		end
	end
	return list
end

local function setWatered(watered: boolean)
	for _, soil in soils() do
		local rest = soil:GetAttribute(REST_COLOR)
		if typeof(rest) == "Color3" then
			soil.Color = if watered then rest:Lerp(Color3.new(0, 0, 0), 0.45) else rest
		end
	end
end

local RealityTasks = {}

function RealityTasks.onActivated(_session: any, def: any)
	-- Idempotent reset so a fresh run / Continue never shows yesterday's result.
	if def.id == "R_Hydroponics" then
		setWatered(false)
	elseif Lines[def.id] and Lines[def.id].screen then
		setScreen(def.tag, nil)
	end
end

function RealityTasks.onMinigameOpen(_session: any, def: any)
	if Busy[def.id] then
		setScreen(def.tag, Busy[def.id])
	end
end

function RealityTasks.onTriggered(session: any, def: any, _prompt: ProximityPrompt?): boolean
	local line = Lines[def.id]
	if def.id == "R_Hydroponics" then
		setWatered(true)
	end
	if line then
		if def.id == "R_StatusLog" then
			local st = session.station
			setScreen(def.tag, string.format("STATUS LOG 212 FILED\nO2 %d%%  PWR %d%%  HULL %d%%\nNOTHING TO REPORT",
				math.floor(st:Get("Oxygen") + 0.5), math.floor(st:Get("Power") + 0.5), math.floor(st:Get("HullIntegrity") + 0.5)))
		elseif line.screen then
			setScreen(def.tag, line.screen)
		end
		ScareDirector.Fire(session, "Toast", { text = line.toast })
	end
	return true
end

return RealityTasks
