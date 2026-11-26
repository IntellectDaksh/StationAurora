-- PowerDoors: locks/unlocks + auto-slide PowerDoor models based on workspace attribute "AuroraPower"
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TRIGGER_RADIUS = 10
local OPEN_INFO = TweenInfo.new(0.5, Enum.EasingStyle.Quint, Enum.EasingDirection.Out, 0, false, 0.08)
local CLOSE_INFO = TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.InOut, 0, false, 0.15)
local GLOW_OPEN = Color3.fromRGB(90, 200, 255)
local GLOW_CLOSED = Color3.fromRGB(25, 55, 70)

local whooshSound = ReplicatedStorage:FindFirstChild("StationAudio") and ReplicatedStorage.StationAudio:FindFirstChild("SFX Door Whoosh")

local doorStates = {} -- [model] = {open=bool, leftClosedCF, rightClosedCF, leftOpenCF, rightOpenCF, tweening=bool}

local function playWhoosh(atCFrame)
	if not whooshSound then return end
	local snd = whooshSound:Clone()
	snd.Parent = workspace
	local part = Instance.new("Part")
	part.Transparency = 1
	part.CanCollide = false
	part.Anchored = true
	part.Size = Vector3.new(1,1,1)
	part.CFrame = atCFrame
	part.Parent = workspace
	snd.Parent = part
	snd:Play()
	snd.Ended:Connect(function()
		part:Destroy()
	end)
	task.delay(5, function()
		if part and part.Parent then part:Destroy() end
	end)
end

local function setupDoor(model)
	local doorLeft = model:FindFirstChild("DoorLeft")
	local doorRight = model:FindFirstChild("DoorRight")
	local lockLight = model:FindFirstChild("LockLight")
	if not doorLeft or not doorRight then return end

	-- slide each panel its full width (+margin) so the doorway is completely clear
	local openOffset = model:GetAttribute("OpenOffset") or (doorLeft.Size.X + 0.15)
	doorLeft.Anchored = true
	doorRight.Anchored = true

	local state = {
		model = model,
		doorLeft = doorLeft,
		doorRight = doorRight,
		lockLight = lockLight,
		closedLeftCF = doorLeft.CFrame,
		closedRightCF = doorRight.CFrame,
		openLeftCF = doorLeft.CFrame * CFrame.new(-openOffset, 0, 0),
		openRightCF = doorRight.CFrame * CFrame.new(openOffset, 0, 0),
		glow = model:FindFirstChild("Glow"),
		center = (doorLeft.Position + doorRight.Position) / 2,
		isOpen = false,
		tweens = {},
	}
	doorStates[model] = state

	if lockLight then
		lockLight.Color = Color3.fromRGB(220,30,30)
	end
	if state.glow then state.glow.Color = GLOW_CLOSED end
end

local function tweenDoor(state, open)
	if state.isOpen == open then return end
	state.isOpen = open
	-- cancel any in-flight tween so a quick reversal never leaves panels half-open
	for _, t in ipairs(state.tweens) do t:Cancel() end

	local info = open and OPEN_INFO or CLOSE_INFO
	local targetLeft = open and state.openLeftCF or state.closedLeftCF
	local targetRight = open and state.openRightCF or state.closedRightCF

	-- collision off immediately when opening; back on only once fully shut
	if open then
		state.doorLeft.CanCollide = false
		state.doorRight.CanCollide = false
	end

	playWhoosh(CFrame.new(state.center))

	local tweenLeft = TweenService:Create(state.doorLeft, info, {CFrame = targetLeft})
	local tweenRight = TweenService:Create(state.doorRight, info, {CFrame = targetRight})
	state.tweens = {tweenLeft, tweenRight}
	if state.glow then
		local g = TweenService:Create(state.glow, info, {Color = open and GLOW_OPEN or GLOW_CLOSED})
		table.insert(state.tweens, g)
		g:Play()
	end
	tweenLeft:Play()
	tweenRight:Play()
	tweenLeft.Completed:Once(function(status)
		if status == Enum.PlaybackState.Completed and not state.isOpen then
			state.doorLeft.CanCollide = true
			state.doorRight.CanCollide = true
		end
	end)
end

local function applyLockVisual(state, powered)
	if not state.lockLight then return end
	state.lockLight.Color = powered and Color3.fromRGB(40,220,80) or Color3.fromRGB(220,30,30)
end

local function refreshPowerState()
	local powered = workspace:GetAttribute("AuroraPower") == true
	for _, state in pairs(doorStates) do
		applyLockVisual(state, powered)
		if not powered and state.isOpen then
			tweenDoor(state, false)
		end
	end
end

for _, model in ipairs(CollectionService:GetTagged("PowerDoor")) do
	setupDoor(model)
end

CollectionService:GetInstanceAddedSignal("PowerDoor"):Connect(setupDoor)

workspace:GetAttributeChangedSignal("AuroraPower"):Connect(refreshPowerState)
refreshPowerState()

-- proximity loop: only meaningful once powered
local HEARTBEAT_INTERVAL = 0.2
local accum = 0
game:GetService("RunService").Heartbeat:Connect(function(dt)
	accum += dt
	if accum < HEARTBEAT_INTERVAL then return end
	accum = 0

	local powered = workspace:GetAttribute("AuroraPower") == true
	if not powered then return end

	local characters = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			local hrp = plr.Character:FindFirstChild("HumanoidRootPart")
			if hrp then table.insert(characters, hrp) end
		end
	end
	if #characters == 0 then return end

	for _, state in pairs(doorStates) do
		local doorPos = state.center
		local nearby = false
		for _, hrp in ipairs(characters) do
			if (hrp.Position - doorPos).Magnitude <= TRIGGER_RADIUS then
				nearby = true
				break
			end
		end
		-- StuckOpen: set by GameStateManager world persistence (a door jammed during a night stays jammed)
		tweenDoor(state, nearby or state.model:GetAttribute("StuckOpen") == true)
	end
end)
