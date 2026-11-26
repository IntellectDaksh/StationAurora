--!strict
-- GravityControl: spawn console (F-key) and upper-deck manual lever (E) both toggle station gravity 100% <-> 10%.

local map = workspace:FindFirstChild("Space Ship Map")
local systems = map and map:FindFirstChild("Station Systems")
local consolesF = systems and systems:FindFirstChild("Consoles")
if not consolesF then return end

-- Spawn console (F-key prompt)
local console = consolesF:FindFirstChild("StationConsole_Gravity")
local button = console and console:FindFirstChild("GravityButton")
local prompt = button and button:FindFirstChild("GravityPrompt")

-- Upper-deck manual lever (E prompt on the handle)
local lever = consolesF:FindFirstChild("GravityLever")
local leverHandle = lever and lever:FindFirstChild("LeverHandle")
local leverKnob = lever and lever:FindFirstChild("LeverKnob")
local leverPrompt = leverHandle and leverHandle:FindFirstChild("LeverPrompt")
local labelPart = lever and lever:FindFirstChild("SwitchLabel")
local labelGui = labelPart and labelPart:FindFirstChildOfClass("SurfaceGui")
local labelText = labelGui and labelGui:FindFirstChild("Label")

local screen = console and console:FindFirstChild("ConsoleHead")
local gui = screen and screen:FindFirstChildOfClass("SurfaceGui")
local statusText = gui and gui:FindFirstChild("StatusText")

local audio = game.ReplicatedStorage:FindFirstChild("StationAudio")

local FULL_GRAVITY = 196.2 -- Roblox default
local LOW_GRAVITY = FULL_GRAVITY / 40 -- 2.5%: near zero-G, players float and drift dramatically
local TRANSITION_TIME = 1.5 -- seconds to ease between levels so it feels natural

local gravityLow = false
local transitioning = false

-- Anchor lever parts and remember their rest pose so we can animate the pull.
local handleBase: CFrame? = nil
local knobBase: CFrame? = nil
if leverHandle and leverHandle:IsA("BasePart") then
	leverHandle.Anchored = true
	handleBase = leverHandle.CFrame
end
if leverKnob and leverKnob:IsA("BasePart") then
	leverKnob.Anchored = true
	knobBase = leverKnob.CFrame
end

local function playSound(templateName, parent)
	if not audio then return end
	local t = audio:FindFirstChild(templateName)
	if not t then return end
	local s = t:Clone()
	s.Parent = parent or workspace
	s:Play()
	s.Ended:Once(function() s:Destroy() end)
	task.delay(10, function()
		if s.Parent then s:Destroy() end
	end)
end

local function setStatus(text, color)
	if statusText and statusText:IsA("TextLabel") then
		statusText.Text = text
		statusText.TextColor3 = color or Color3.fromRGB(90, 220, 255)
	end
	if labelText and labelText:IsA("TextLabel") then
		labelText.Text = text
		labelText.TextColor3 = color or Color3.fromRGB(90, 220, 255)
	end
end

local function easeGravity(target)
	local start = workspace.Gravity
	local elapsed = 0
	local step = 0.05
	while elapsed < TRANSITION_TIME do
		local alpha = math.sin((elapsed / TRANSITION_TIME) * math.pi / 2) -- smooth ease-out
		workspace.Gravity = start + (target - start) * alpha
		task.wait(step)
		elapsed += step
	end
	workspace.Gravity = target
end

-- Swings the physical lever to its pulled pose (low gravity) or back to rest.
local function swingLever(low)
	if not (leverHandle and leverHandle:IsA("BasePart") and handleBase) then return end
	local targetCF = handleBase
	if low then
		-- Rotate around the bottom of the handle so it swings like a real lever.
		local pivotOffset = CFrame.new(0, -leverHandle.Size.Y / 2, 0)
		targetCF = handleBase * pivotOffset * CFrame.Angles(math.rad(-55), 0, 0) * pivotOffset:Inverse()
	end
	local knobTarget = nil
	if leverKnob and leverKnob:IsA("BasePart") and knobBase then
		knobTarget = knobBase * handleBase:Inverse() * targetCF
	end
	task.spawn(function()
		for _ = 1, 12 do
			leverHandle.CFrame = leverHandle.CFrame:Lerp(targetCF, 0.35)
			if leverKnob and knobTarget then
				leverKnob.CFrame = leverKnob.CFrame:Lerp(knobTarget, 0.35)
			end
			task.wait(0.03)
		end
		leverHandle.CFrame = targetCF
		if leverKnob and knobTarget then
			leverKnob.CFrame = knobTarget
		end
	end)
end

local function setGravity(low)
	if transitioning then return end
	transitioning = true

	gravityLow = low
	playSound("SFX Button Beep", button or leverHandle)

	if gravityLow then
		setStatus("GRAVITY: 2.5% // ZERO-G", Color3.fromRGB(120, 200, 255))
		if button then button.Color = Color3.fromRGB(255, 170, 60) end
	else
		setStatus("GRAVITY: 100% // NORMAL")
		if button then button.Color = Color3.fromRGB(90, 200, 255) end
	end

	swingLever(gravityLow)
	easeGravity(gravityLow and LOW_GRAVITY or FULL_GRAVITY)

	-- light visual pulse on the console button so the change is obvious
	if button and button:IsA("BasePart") then
		for _ = 1, 3 do
			button.Transparency = 0.4
			task.wait(0.12)
			button.Transparency = 0
			task.wait(0.12)
		end
	end
	transitioning = false
end

-- F-key console at spawn
if prompt and prompt:IsA("ProximityPrompt") then
	prompt.Triggered:Connect(function()
		setGravity(not gravityLow)
	end)
end

-- Manual lever on the upper deck
if leverPrompt and leverPrompt:IsA("ProximityPrompt") then
	leverPrompt.Triggered:Connect(function()
		setGravity(not gravityLow)
	end)
end

setStatus("GRAVITY: 100% // NORMAL")

return "Gravity control online"