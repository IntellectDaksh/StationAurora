--!strict
-- R_Generator: backup generator restart. Priming shows on the console; success brings
-- Power back to 100, lights the status lamp, spins the flywheel, and hands off to
-- ScareDirector "PowerRestored" for the lighting agent to render the cut-in.
local CollectionService = game:GetService("CollectionService")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local DEFAULT_ATTR = "AuroraDefaultText"

local function generatorModel(): Instance?
	local inst = CollectionService:GetTagged("Objective_Generator")[1]
	return inst
end

local function setScreen(model: Instance?, text: string?)
	if not model then
		return
	end
	local t = model:FindFirstChild("ConsoleScreen", true)
	t = t and t:FindFirstChild("StatusText")
	if not t or not t:IsA("TextLabel") then
		return
	end
	if t:GetAttribute(DEFAULT_ATTR) == nil then
		t:SetAttribute(DEFAULT_ATTR, t.Text)
	end
	local default = t:GetAttribute(DEFAULT_ATTR)
	t.Text = text or (if type(default) == "string" then default else t.Text)
end

-- Non-yielding spin: the handler contract forbids yielding, so the loop lives in its own thread.
local function spinFlywheel(model: Instance)
	local wheel = model:FindFirstChild("Flywheel", true)
	if not wheel or not wheel:IsA("BasePart") then
		return
	end
	task.spawn(function()
		local spinTime = 0
		while spinTime < 2.5 and wheel.Parent do
			local dt = task.wait(1 / 30)
			spinTime += dt
			local speed = math.min(1, spinTime / 0.6) * 720 -- deg/sec, ramps up then holds
			wheel.CFrame = wheel.CFrame * CFrame.Angles(0, 0, math.rad(speed * dt))
		end
	end)
end

local Generator = {}

function Generator.onMinigameOpen(_session: any, def: any)
	if def.id ~= "R_Generator" then
		return
	end
	setScreen(generatorModel(), "PRIMING...")
end

local function start(session: any): boolean
	local model = generatorModel()
	session.station:Set("Power", 100)
	session.station:Push(true)
	if model then
		local lamp = model:FindFirstChild("StatusLamp", true)
		if lamp and lamp:IsA("BasePart") then
			lamp.Color = Color3.fromRGB(80, 230, 140)
			local light = lamp:FindFirstChildOfClass("PointLight") or lamp:FindFirstChildOfClass("SurfaceLight")
			if light then
				light.Color = Color3.fromRGB(80, 230, 140)
				light.Enabled = true
			end
		end
		spinFlywheel(model)
		setScreen(model, "BACKUP POWER ONLINE")
	else
		warn("[Generator] Objective_Generator geometry missing, applied Power only")
	end
	ScareDirector.Fire(session, "PowerRestored", {})
	ScareDirector.Fire(session, "Toast", { text = "Backup power online." })
	return true
end

function Generator.onTriggered(session: any, def: any, _prompt: ProximityPrompt?): boolean
	if def.id ~= "R_Generator" then
		return true
	end
	return start(session)
end

function Generator.onClientComplete(session: any, def: any, _data: any): boolean
	if def.id ~= "R_Generator" then
		return false
	end
	return start(session)
end

return Generator
