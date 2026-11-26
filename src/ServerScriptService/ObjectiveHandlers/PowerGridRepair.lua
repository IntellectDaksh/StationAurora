--!strict
-- Dream 3: three breakers on PowerGridPanel. Visuals are always rendered from
-- session.completed, so re-activation (fresh run or Continue) is idempotent.
local CollectionService = game:GetService("CollectionService")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local TAG = "Objective_PowerGrid"
local IDS = { "D3_Breaker1", "D3_Breaker2", "D3_Breaker3" }
local LETTERS = { "A", "B", "C" }
local REST_CF = "AuroraRestCFrame"
local DEFAULT_ATTR = "AuroraDefaultText"
local LAMP_ON = Color3.fromRGB(60, 255, 120)
local LAMP_TRIPPED = Color3.fromRGB(255, 45, 45)
local TRIP_ANGLE = CFrame.Angles(math.rad(-40), 0, 0) -- lever thrown down
local POWER_STEP = 33

local function panel(): Instance?
	return CollectionService:GetTagged(TAG)[1]
end

local function setScreen(text: string)
	local inst = panel()
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

local function setBreaker(i: number, on: boolean)
	local inst = panel()
	if not inst then
		return
	end
	local breaker = inst:FindFirstChild("Breaker" .. i, true)
	if breaker and breaker:IsA("BasePart") then
		local rest = breaker:GetAttribute(REST_CF)
		if typeof(rest) ~= "CFrame" then
			rest = breaker.CFrame
			breaker:SetAttribute(REST_CF, rest)
		end
		breaker.CFrame = if on then rest :: CFrame else (rest :: CFrame) * TRIP_ANGLE
	end
	local lamp = inst:FindFirstChild("Lamp" .. i, true)
	if lamp and lamp:IsA("BasePart") then
		lamp.Material = Enum.Material.Neon
		lamp.Color = if on then LAMP_ON else LAMP_TRIPPED
	end
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

local PowerGridRepair = {}

function PowerGridRepair.onActivated(session: any, _def: any)
	for i, id in IDS do
		setBreaker(i, session.completed[id] == true)
	end
	local n = doneCount(session)
	setScreen(if n == 0 then "MAIN BUS OFFLINE" else string.format("MAIN BUS OFFLINE // %d/3 RESET", n))
end

function PowerGridRepair.onTriggered(session: any, def: any, _prompt: ProximityPrompt?): boolean
	local i = table.find(IDS, def.id)
	if not i then
		return false
	end
	-- Out of Repair Units: let Complete refuse it (fires NoRepairUnits) without flipping visuals.
	if session.station:Get("RepairUnits") < (def.repairCost or 0) then
		return true
	end
	setBreaker(i, true)
	local n = doneCount(session) + 1 -- this one isn't marked completed until we return
	if n >= #IDS then
		session.station:Set("Power", 100)
		setScreen("MAIN BUS RESTORED")
		ScareDirector.Fire(session, "Toast", { text = "Main bus is back. Lights on." })
	else
		session.station:Add("Power", POWER_STEP)
		setScreen(string.format("BREAKER %s RESET // %d/3", LETTERS[i], n))
		ScareDirector.Fire(session, "Toast", { text = "Breaker " .. LETTERS[i] .. " reset." })
	end
	session.station:Push(true)
	return true
end

return PowerGridRepair
