-- LoadingScreen (ReplicatedFirst): replaces the Roblox loader with the Aurora identity.
-- Same type system as HUDController: GothamSSm Light/Medium, one cyan accent, 1px hairlines.
-- Fades out once the game is loaded, key assets are preloaded and HUDController has built its menu.

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ContentProvider = game:GetService("ContentProvider")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ACCENT = Color3.fromRGB(90, 200, 255)
local TEXT = Color3.fromRGB(236, 240, 244)
local DIM = Color3.fromRGB(150, 160, 172)
local BG = Color3.fromRGB(7, 9, 12)
local FAM = "rbxasset://fonts/families/GothamSSm.json"

local gui = Instance.new("ScreenGui")
gui.Name = "AuroraLoading"
gui.IgnoreGuiInset = true
gui.DisplayOrder = 1000
gui.ResetOnSpawn = false
gui.Parent = playerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

local root = Instance.new("CanvasGroup")
root.Size = UDim2.fromScale(1, 1)
root.BackgroundColor3 = BG
root.BorderSizePixel = 0
root.Parent = gui

local function text(t: string, size: number, weight: Enum.FontWeight, color: Color3, y: number)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.new(0.5, 0, 0.5, y)
	l.Size = UDim2.fromOffset(800, size + 8)
	l.FontFace = Font.new(FAM, weight)
	l.TextSize = size
	l.TextColor3 = color
	l.Text = t
	l.TextTransparency = 1
	l.Parent = root
	return l
end

local mark = text("A   U   R   O   R   A", 40, Enum.FontWeight.Light, TEXT, -24)
local status = text("Establishing link", 14, Enum.FontWeight.Regular, DIM, 58)

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.new(0.5, 0, 0.5, 28)
track.Size = UDim2.fromOffset(240, 1)
track.BackgroundColor3 = TEXT
track.BackgroundTransparency = 0.88
track.BorderSizePixel = 0
track.Parent = root
local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = ACCENT
fill.BorderSizePixel = 0
fill.Parent = track

local function tw(o: Instance, t: number, props: { [string]: any })
	local x = TweenService:Create(o, TweenInfo.new(t, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), props)
	x:Play()
	return x
end
local function progress(p: number)
	tw(fill, 0.6, { Size = UDim2.fromScale(math.clamp(p, 0, 1), 1) })
end

tw(mark, 1.4, { TextTransparency = 0 })
task.delay(0.4, function()
	tw(status, 1, { TextTransparency = 0 })
end)
local t0 = os.clock()

-- quiet ellipsis on the status line while we wait
local dots = 0
local base = "Establishing link"
task.spawn(function()
	while gui.Parent do
		dots = (dots + 1) % 4
		status.Text = base .. string.rep(".", dots)
		task.wait(0.45)
	end
end)

if not game:IsLoaded() then
	game.Loaded:Wait()
end
progress(0.35)

base = "Syncing station systems"
local assets = {}
for _, root in { workspace, game:GetService("SoundService"), game:GetService("ReplicatedStorage") } do
	for _, d in root:GetDescendants() do
		if d:IsA("Sound") or d:IsA("Decal") or d:IsA("Texture") or d:IsA("MeshPart") or d:IsA("ImageLabel") or d:IsA("SurfaceAppearance") then
			table.insert(assets, d)
		end
	end
end
local total = #assets
if total > 0 then
	-- ponytail: one PreloadAsync over everything; per-asset callback drives the bar. Cap by a timeout so a
	-- bad asset id never strands the player on this screen.
	local loaded = 0
	local done = false
	task.spawn(function()
		pcall(ContentProvider.PreloadAsync, ContentProvider, assets, function()
			loaded += 1
			progress(0.35 + 0.55 * loaded / total)
		end)
		done = true
	end)
	local deadline = os.clock() + 15
	while not done and os.clock() < deadline do
		task.wait(0.1)
	end
end
progress(0.9)

-- Real readiness: lighting, character, and the station streamed in around spawn + quarters.
-- One shared deadline; if it trips we warn and dismiss anyway so nobody is stranded.
base = "Pressurising station"
do
	local CollectionService = game:GetService("CollectionService")
	local Lighting = game:GetService("Lighting")
	local READY_TIMEOUT = 45
	local readyDeadline = os.clock() + READY_TIMEOUT
	local QUARTERS_FALLBACK = Vector3.new(-43, 28.8, -5.2)
	local function timedOut(what: string)
		if os.clock() > readyDeadline then
			warn("[LoadingScreen] readiness timeout waiting for " .. what .. "; dismissing anyway")
			return true
		end
		return false
	end

	-- lighting effects replicated
	for _, n in { "Atmosphere", "Sky", "Bloom" } do
		while not Lighting:FindFirstChild(n) and not timedOut("Lighting." .. n) do
			task.wait(0.1)
		end
	end

	-- character (the server may spawn late; poll instead of blocking forever on CharacterAdded)
	while not (player.Character and player.Character:FindFirstChild("HumanoidRootPart")) and not timedOut("character") do
		task.wait(0.1)
	end
	progress(0.94)

	-- stream in around spawn and the quarters wake point
	if workspace.StreamingEnabled then
		local spots = {}
		local spawnLoc = workspace:FindFirstChild("SpawnLocation")
		table.insert(spots, if spawnLoc and spawnLoc:IsA("BasePart") then spawnLoc.Position else Vector3.new(-50, 28.5, -10))
		local q = CollectionService:GetTagged("Zone_Quarters")[1]
		table.insert(spots, if q and q:IsA("PVInstance") then q:GetPivot().Position else QUARTERS_FALLBACK)
		local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			table.insert(spots, hrp.Position)
		end
		for _, pos in spots do
			if os.clock() > readyDeadline then
				break
			end
			local ok, err = pcall(player.RequestStreamAroundAsync, player, pos, math.max(1, readyDeadline - os.clock()))
			if not ok then
				warn("[LoadingScreen] RequestStreamAroundAsync failed: " .. tostring(err))
			end
		end
	end
	progress(0.97)

	-- station lights near spawn exist (tagged parts replicate once their area streams in)
	local function lightsNear(): boolean
		local origin = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		local o = if origin then origin.Position else Vector3.new(-50, 28.5, -10)
		for _, tag in { "RoomLight", "Station_Light" } do
			for _, p in CollectionService:GetTagged(tag) do
				if p:IsA("BasePart") and (p.Position - o).Magnitude < 200 then
					return true
				end
			end
		end
		return false
	end
	while not lightsNear() and not timedOut("station lights") do
		task.wait(0.2)
	end
end
progress(0.98)

-- wait for HUDController's menu (or any first state screen) so there is no flash of the world
base = "Waking operator"
local deadline = os.clock() + 10
while os.clock() < deadline do
	local menu = playerGui:FindFirstChild("MainMenu")
	if menu and menu:IsA("ScreenGui") and menu.Enabled then
		break
	end
	local ok = false
	for _, n in { "Narrative", "ObjectiveHUD", "ChoicePrompt", "GameOver" } do
		local g = playerGui:FindFirstChild(n)
		if g and g:IsA("ScreenGui") and g.Enabled then
			ok = true
		end
	end
	if ok then
		break
	end
	task.wait(0.1)
end
progress(1)
task.wait(math.max(0, 2.2 - (os.clock() - t0)))
task.wait(0.5)
tw(root, 1.2, { GroupTransparency = 1 }).Completed:Wait()
gui:Destroy()
