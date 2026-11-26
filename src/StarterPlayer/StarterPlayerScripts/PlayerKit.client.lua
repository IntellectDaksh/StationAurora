--!strict
-- PlayerKit: torch (F / ButtonY / touch, battery-limited, flickers in dreams 2-3) and
-- sprint (LeftShift / L3, only when server WalkSpeed is the standby 16). Respawn-safe:
-- both re-attach to the new character; state (battery, stamina, on/off) lives on the
-- Player instance so it survives respawns untouched.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateChanged = Remotes:WaitForChild("StateChanged")
local RequestObjectiveComplete = Remotes:WaitForChild("RequestObjectiveComplete")
local torchTaskActive = false -- T_Flashlight is a clientAction objective: we report it
local StationAudio = ReplicatedStorage:WaitForChild("StationAudio", 10)

local WALK_SPEED = 16
local SPRINT_SPEED = 24
local PLAY_STATES = { Reality = true, Objectives = true }

local BATTERY_DRAIN_PER_SEC = 0.01 / 8 -- ~1% every 8s while the torch is on (slow, not frustrating in the opening)
local BATTERY_RECHARGE_PER_SEC = 0.01 / 9 -- slower recharge while off
local STAMINA_DRAIN_PER_SEC = 1 / 6 -- empties in 6s of sprinting
local STAMINA_RECHARGE_PER_SEC = 1 / 4

local curState: string? = nil
local curDream = 0
local torchOn = false
local battery = 1
local stamina = 1
local sprinting = false
local torchLight: SpotLight? = nil
local torchFillLight: PointLight? = nil
local flickerSeed = math.random() * 1000

player:SetAttribute("TorchOn", false)
player:SetAttribute("TorchBattery", 1)
player:SetAttribute("Stamina", 1)

local function findBeep(): Sound?
	local s = StationAudio and StationAudio:FindFirstChild("SFX Button Beep")
	return if s and s:IsA("Sound") then s else nil
end

local function click()
	local src = findBeep()
	if not src then
		return
	end
	local s = src:Clone()
	s.Looped = false
	s.Volume = 0.3
	s.PlaybackSpeed = 0.75 -- low pitch
	s.Parent = player:WaitForChild("PlayerGui")
	s:Play()
	game:GetService("Debris"):AddItem(s, 4)
end

local function humanoid(): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

----------------------------------------------------------------------------
-- Torch
----------------------------------------------------------------------------
local function attachTorch(char: Model)
	local head = char:WaitForChild("Head", 5)
	if not head or not head:IsA("BasePart") then
		return
	end
	local old = head:FindFirstChild("AuroraTorch")
	if old then
		old:Destroy()
	end
	local light = Instance.new("SpotLight")
	light.Name = "AuroraTorch"
	light.Color = Color3.fromRGB(255, 224, 180)
	light.Range = 95
	light.Angle = 70
	light.Brightness = 5
	light.Face = Enum.NormalId.Front
	light.Enabled = torchOn and battery > 0
	light.Parent = head
	torchLight = light

	local oldFill = head:FindFirstChild("AuroraTorchFill")
	if oldFill then
		oldFill:Destroy()
	end
	local fill = Instance.new("PointLight")
	fill.Name = "AuroraTorchFill"
	fill.Color = Color3.fromRGB(255, 224, 180)
	fill.Range = 10
	fill.Brightness = 0.4
	fill.Enabled = torchOn and battery > 0
	fill.Parent = head
	torchFillLight = fill
end

local function setTorch(on: boolean)
	if on and battery <= 0 then
		on = false
	end
	if on == torchOn then
		return
	end
	torchOn = on
	player:SetAttribute("TorchOn", torchOn)
	click()
	if torchOn and torchTaskActive then
		RequestObjectiveComplete:FireServer("T_Flashlight")
	end
	if torchLight then
		torchLight.Enabled = torchOn
	end
	if torchFillLight then
		torchFillLight.Enabled = torchOn
	end
end

local function toggleTorch(_name: string, state: Enum.UserInputState)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	if player:GetAttribute("MinigameOpen") == true then
		return Enum.ContextActionResult.Pass
	end
	setTorch(not torchOn)
	return Enum.ContextActionResult.Sink
end

----------------------------------------------------------------------------
-- Sprint (client-set WalkSpeed on the owned character; only while the server has it at
-- the standby 16, so it never fights Pause/cutscene locks which set it to 0).
----------------------------------------------------------------------------
local function applySprint(on: boolean)
	local hum = humanoid()
	if not hum then
		return
	end
	if on then
		if not sprinting and hum.WalkSpeed == WALK_SPEED and stamina > 0 then
			sprinting = true
			hum.WalkSpeed = SPRINT_SPEED
		end
	else
		if sprinting then
			sprinting = false
			if hum.WalkSpeed == SPRINT_SPEED then
				hum.WalkSpeed = WALK_SPEED
			end
		end
	end
end

local function sprintAction(_name: string, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		applySprint(true)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		applySprint(false)
	end
	return Enum.ContextActionResult.Pass -- never eats movement input
end

----------------------------------------------------------------------------
-- Bindings
----------------------------------------------------------------------------
ContextActionService:BindActionAtPriority("AuroraTorch", toggleTorch, true, Enum.ContextActionPriority.Default.Value,
	Enum.KeyCode.F, Enum.KeyCode.ButtonY)
ContextActionService:SetTitle("AuroraTorch", "Torch")
-- Auto-on at spawn: controller users shouldn't hunt for F in the dark.
task.defer(setTorch, true)
ContextActionService:BindAction("AuroraSprint", sprintAction, false, Enum.KeyCode.LeftShift, Enum.KeyCode.ButtonL3)

----------------------------------------------------------------------------
-- Respawn / state
----------------------------------------------------------------------------
local function onCharacterAdded(char: Model)
	attachTorch(char)
	-- respawn always lands with the torch off and full battery unaffected; only the light needs re-linking
	if torchLight then
		torchLight.Enabled = torchOn and battery > 0
	end
	if torchFillLight then
		torchFillLight.Enabled = torchOn and battery > 0
	end
end
player.CharacterAdded:Connect(onCharacterAdded)
if player.Character then
	onCharacterAdded(player.Character)
end

StateChanged.OnClientEvent:Connect(function(state: any, payload: any)
	curState = state
	if type(payload) == "table" then
		curDream = tonumber(payload.dream) or curDream
		local was = torchTaskActive
		torchTaskActive = false
		if type(payload.objectives) == "table" then
			for _, o in payload.objectives do
				if type(o) == "table" and o.id == "T_Flashlight" and o.active == true and o.done ~= true then
					torchTaskActive = true
				end
			end
		end
		-- torch already on when the step appears: count it
		if torchTaskActive and not was and torchOn then
			RequestObjectiveComplete:FireServer("T_Flashlight")
		end
	end
	if not PLAY_STATES[curState] then
		applySprint(false)
	end
end)

----------------------------------------------------------------------------
-- Tick: battery, stamina, dream flicker
----------------------------------------------------------------------------
RunService.Heartbeat:Connect(function(dt: number)
	-- battery
	if torchOn then
		battery = math.clamp(battery - BATTERY_DRAIN_PER_SEC * dt, 0, 1)
		if battery <= 0 then
			setTorch(false) -- dies; toggling back on requires it to recharge first
		end
	else
		battery = math.clamp(battery + BATTERY_RECHARGE_PER_SEC * dt, 0, 1)
	end
	player:SetAttribute("TorchBattery", battery)

	-- stamina
	if sprinting then
		stamina = math.clamp(stamina - STAMINA_DRAIN_PER_SEC * dt, 0, 1)
		if stamina <= 0 then
			applySprint(false)
		end
	else
		stamina = math.clamp(stamina + STAMINA_RECHARGE_PER_SEC * dt, 0, 1)
	end
	player:SetAttribute("Stamina", stamina)

	-- torch flicker: dreams 2 and 3 only, and while battery is critical
	if torchLight and torchOn then
		local flicker = (curDream == 2 or curDream == 3)
		if flicker then
			local t = os.clock() + flickerSeed
			local n = math.noise(t * 6, flickerSeed)
			torchLight.Enabled = n > -0.55
			torchLight.Brightness = 2.4 + n * 1.2
		elseif battery < 0.15 then
			torchLight.Enabled = math.random() > 0.08
			torchLight.Brightness = 3
		else
			torchLight.Enabled = true
			torchLight.Brightness = 3
		end
	end
end)
