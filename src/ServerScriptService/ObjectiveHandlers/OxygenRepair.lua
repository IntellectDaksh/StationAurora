--!strict
-- Dream 4: three O2 valves on LifeSupportUnit. Visuals are always rendered from
-- session.completed, so re-activation (fresh run or Continue) is idempotent.
local CollectionService = game:GetService("CollectionService")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local TAG = "Objective_LifeSupport"
local IDS = { "D4_Valve1", "D4_Valve2", "D4_Valve3" }
local WORDS = { "one", "two", "three" }
local REST_CF = "AuroraRestCFrame"
local DEFAULT_ATTR = "AuroraDefaultText"
local CLOSED = Color3.fromRGB(210, 50, 50)
local OPEN = Color3.fromRGB(50, 210, 100)
local TURN = CFrame.Angles(math.rad(90), 0, 0) -- cylinder axis is local X: spins in place
local O2_STEP = 12

local function unit(): Instance?
	return CollectionService:GetTagged(TAG)[1]
end

local function setScreen(text: string)
	local inst = unit()
	if not inst then
		return
	end
	for _, t in inst:GetDescendants() do
		if t.Name == "StatusText" and t:IsA("TextLabel") then
			if t:GetAttribute(DEFAULT_ATTR) == nil then
				t:SetAttribute(DEFAULT_ATTR, t.Text)
			end
			t.Text = text
		end
	end
end

local function setValve(i: number, open: boolean)
	local inst = unit()
	local valve = inst and inst:FindFirstChild("Valve" .. i, true)
	if not (valve and valve:IsA("BasePart")) then
		return
	end
	local rest = valve:GetAttribute(REST_CF)
	if typeof(rest) ~= "CFrame" then
		rest = valve.CFrame
		valve:SetAttribute(REST_CF, rest)
	end
	valve.CFrame = if open then (rest :: CFrame) * TURN else rest :: CFrame
	valve.Color = if open then OPEN else CLOSED
end

local function doneCount(session: any): number
	local n = 0
	for _, id in IDS do
		if session.completed[id] then
			n += 1
		end
	end
	return n
end

local OxygenRepair = {}

function OxygenRepair.onActivated(session: any, _def: any)
	for i, id in IDS do
		setValve(i, session.completed[id] == true)
	end
	local n = doneCount(session)
	setScreen(if n == 0 then "O2 CRITICAL // VALVES CLOSED" else string.format("O2 CRITICAL // %d/3 VALVES OPEN", n))
end

function OxygenRepair.onTriggered(session: any, def: any, _prompt: ProximityPrompt?): boolean
	local i = table.find(IDS, def.id)
	if not i then
		return false
	end
	-- Out of Repair Units: let Complete refuse it (fires NoRepairUnits) without turning the valve.
	if session.station:Get("RepairUnits") < (def.repairCost or 0) then
		return true
	end
	setValve(i, true)
	session.station:Add("Oxygen", O2_STEP)
	session.station:Push(true)
	local n = doneCount(session) + 1 -- this one isn't marked completed until we return
	setScreen(if n >= #IDS then "O2 FLOW RESTORING..." else string.format("O2 CRITICAL // %d/3 VALVES OPEN", n))
	ScareDirector.Fire(session, "Toast", { text = "Valve " .. WORDS[i] .. " open." })
	return true
end

return OxygenRepair
