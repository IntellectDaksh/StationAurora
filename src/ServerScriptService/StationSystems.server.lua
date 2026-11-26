--!strict
-- StationSystems: wires console buttons, lighting, alerts, and the holo table.
local RunService = game:GetService("RunService")

local map = workspace:FindFirstChild("Space Ship Map")
local systems = map and map:FindFirstChild("Station Systems")
if not systems then return end
local consolesF = systems:FindFirstChild("Consoles")
local fixturesF = systems:FindFirstChild("Light Fixtures")
local holoF = systems:FindFirstChild("Holo Table")
local hw = map and map:FindFirstChild("Hull Windows")
local audio = game.ReplicatedStorage:FindFirstChild("StationAudio")

local CYAN = Color3.fromRGB(90, 200, 255)
local ORANGE = Color3.fromRGB(255, 140, 40)
local DIM = Color3.fromRGB(120, 130, 140)

local lightsOn = true
local engineMode = false
local alertActive = false

local NAV_LINES = {
	"COURSE: KAPPA-9 // ETA 4H",
	"ORBIT: STABLE",
	"DOCKING CLAMPS: GREEN",
	"O2 LEVEL: 98.4%",
	"HULL INTEGRITY: 100%",
	"SOLAR ARRAY: 87% OUTPUT",
	"GRAVITY RING: NOMINAL",
	"TRAJECTORY LOCKED",
}
local DIAG_LINES = {
	"RUNNING DIAGNOSTIC...",
	"COOLANT FLOW: OK",
	"REACTOR TEMP: 312K",
	"PRESSURE: 101.2 kPa",
	"COMMS ARRAY: ONLINE",
	"AI CORE: ACTIVE",
}

local function playSound(templateName, parent)
	if not audio then return end
	local t = audio:FindFirstChild(templateName)
	if not t then return end
	local s = t:Clone()
	s.Parent = parent
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	task.delay(15, function()
		if s.Parent then s:Destroy() end
	end)
end

local function setStatus(button, text)
	local model = button:FindFirstAncestorOfClass("Model")
	local screen = model and model:FindFirstChild("ConsoleScreen")
	local gui = screen and screen:FindFirstChildOfClass("SurfaceGui")
	local status = gui and gui:FindFirstChild("StatusText", true)
	if status and status:IsA("TextLabel") then
		status.Text = text
	end
end

local function getFixtures()
	local list = {}
	if fixturesF then
		for _, fm in ipairs(fixturesF:GetChildren()) do
			local panel = fm:FindFirstChild("Panel")
			if panel then table.insert(list, panel) end
		end
	end
	return list
end

local function doLights(button)
	lightsOn = not lightsOn
	for _, panel in ipairs(getFixtures()) do
		local pl = panel:FindFirstChild("RoomLight")
		if pl then pl.Enabled = lightsOn end
		if lightsOn then
			panel.Color = Color3.fromRGB(210, 235, 255)
		else
			panel.Color = DIM
		end
	end
	setStatus(button, lightsOn and "LIGHTS: ON" or "LIGHTS: OFF")
end

local function doEngines(button)
	engineMode = not engineMode
	if hw then
		for _, p in ipairs(hw:GetChildren()) do
			if p:IsA("BasePart") and (p.Name == "HullStripAbove" or p.Name == "HullStripBelow") then
				p.Color = engineMode and ORANGE or CYAN
			end
		end
	end
	local props = systems:FindFirstChild("Interior Props")
	if props then
		for _, p in ipairs(props:GetChildren()) do
			if p:IsA("BasePart") and p.Name == "FloorStrip" then
				p.Color = engineMode and ORANGE or CYAN
			end
		end
	end
	playSound("SFX Door Whoosh", button)
	setStatus(button, engineMode and "THRUST MODE: ENGAGED" or "THRUST MODE: STANDBY")
end

local function doAlert(button)
	if alertActive then
		setStatus(button, "ALERT ALREADY ACTIVE")
		return
	end
	alertActive = true
	playSound("SFX Siren Alarm", button)
	setStatus(button, "!! RED ALERT !!")
	task.spawn(function()
		local fixtures = getFixtures()
		for _ = 1, 24 do
			for _, panel in ipairs(fixtures) do
				local al = panel:FindFirstChild("AlertLight")
				if al then al.Enabled = not al.Enabled end
			end
			task.wait(0.25)
		end
		for _, panel in ipairs(fixtures) do
			local al = panel:FindFirstChild("AlertLight")
			if al then al.Enabled = false end
		end
		alertActive = false
		setStatus(button, "ALL SYSTEMS NOMINAL")
	end)
end

-- Consoles tagged for the story (Objective_*/Task_*) belong to GameStateManager; leave them alone.
local function isStoryConsole(button): boolean
	local model = button:FindFirstAncestorOfClass("Model")
	if not model then return false end
	for _, tag in model:GetTags() do
		if string.find(tag, "^Objective_") or string.find(tag, "^Task_") then return true end
	end
	return false
end

local function onButtonClicked(button)
	local action = button:GetAttribute("Action")
	if not action or isStoryConsole(button) then return end
	-- lights/alert toggles would fight the per-state atmosphere (client D4 strobe); story owns lighting now
	if action == "lights" or action == "alert" then return end
	playSound("SFX Button Beep", button)
	if action == "nav" then
		setStatus(button, NAV_LINES[math.random(#NAV_LINES)])
	elseif action == "diagnostic" then
		setStatus(button, DIAG_LINES[math.random(#DIAG_LINES)])
	elseif action == "lights" then
		doLights(button)
	elseif action == "engines" then
		doEngines(button)
	elseif action == "alert" then
		doAlert(button)
	end
end

local function hookDetector(cd)
	if cd.Parent and cd.Parent:IsA("BasePart") then
		cd.MouseClick:Connect(function()
			onButtonClicked(cd.Parent)
		end)
	end
end

if consolesF then
	for _, d in ipairs(consolesF:GetDescendants()) do
		if d:IsA("ClickDetector") then hookDetector(d) end
	end
	consolesF.DescendantAdded:Connect(function(d)
		if d:IsA("ClickDetector") then hookDetector(d) end
	end)
end

-- holo table animation
if holoF then
	local table = holoF:FindFirstChild("HoloTable")
	local planet = table and table:FindFirstChild("Planet")
	local ring = table and table:FindFirstChild("Ring")
	if planet then
		task.spawn(function()
			local spin = CFrame.Angles(0, 0.03, 0)
			while planet.Parent do
				planet.CFrame = planet.CFrame * spin
			if ring then
				ring.Transparency = 0.7 + 0.3 * math.sin(os.clock() * 2)
			end
			task.wait(0.05)
		end
		end)
	end
end