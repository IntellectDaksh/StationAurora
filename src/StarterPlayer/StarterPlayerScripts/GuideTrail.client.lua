--!strict
-- GuideTrail: breadcrumb path to the current reach/panel objective (T_FindGenerator, R_Generator)
-- so the player can find the generator without hunting. Client-only cosmetic parts; nothing here
-- touches server state. Press G to preview the trail to whatever objective is active (8s).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local PathfindingService = game:GetService("PathfindingService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateChanged = Remotes:WaitForChild("StateChanged")
local DreamEvents = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("DreamEvents"))
local ObjectiveDefs = DreamEvents.Objectives

-- ids we actively guide toward without being asked (blackout opener: can't find the generator)
local AUTO_GUIDE_IDS = { T_FindGenerator = true, R_Generator = true }
do -- Day 1 checklist spans two decks on a timer: first-time players need the trail there too
	local ok, defs = pcall(require, game:GetService("ReplicatedStorage"):WaitForChild("Modules"):WaitForChild("DreamEvents"))
	if ok and type(defs) == "table" and type(defs.Reality) == "table" then
		for _, id in defs.Reality.tasks or {} do
			AUTO_GUIDE_IDS[id] = true
		end
	end
end

local TRAIL_COLOR = Color3.fromRGB(90, 200, 255)
local SPACING = 4
local RECOMPUTE_INTERVAL = 3
local STRAY_DIST = 12
local PREVIEW_DURATION = 8

local folder = Instance.new("Folder")
folder.Name = "GuideTrailParts"
folder.Parent = workspace

local state: string? = nil
local objectives: { [string]: { done: boolean, active: boolean } } = {}
local activeId: string? = nil -- objective currently being guided (auto or G-preview)
local previewUntil = 0

local chevrons: { BasePart } = {}
local beaconLight: PointLight? = nil
local beaconPart: BasePart? = nil
local lastComputedFrom: Vector3? = nil
local lastRecompute = 0
local toastShown = false

local function humanoidRoot(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return root and root:IsA("BasePart") and root or nil
end

local function clearTrail()
	for _, p in chevrons do
		p:Destroy()
	end
	table.clear(chevrons)
	if beaconPart then
		beaconPart:Destroy()
		beaconPart = nil
		beaconLight = nil
	end
	lastComputedFrom = nil
end

local function worldPos(inst: Instance?): Vector3?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

-- Resolve target at runtime via CollectionService (another agent may still be moving the model).
local function targetFor(id: string): (Vector3?, BasePart?)
	local def = ObjectiveDefs[id]
	if not def or type(def.tag) ~= "string" then
		return nil, nil
	end
	for _, inst in CollectionService:GetTagged(def.tag) do
		if not inst:IsDescendantOf(workspace) then
			continue
		end
		if type(def.part) == "string" then
			local sub = inst.Name == def.part and inst or inst:FindFirstChild(def.part, true)
			if sub then
				local p = worldPos(sub)
				if p then
					return p, sub:IsA("BasePart") and sub or nil
				end
			end
		end
		local p = worldPos(inst)
		if p then
			return p, inst:IsA("BasePart") and inst or nil
		end
	end
	return nil, nil
end

local function makeChevron(pos: Vector3, order: number): BasePart
	local part = Instance.new("Part")
	part.Name = "GuideChevron"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = TRAIL_COLOR
	part.Transparency = 0.3
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.15, 1.2, 1.2)
	part.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
	part:SetAttribute("PulseOrder", order)
	part.Parent = folder
	return part
end

local function makeBeacon(pos: Vector3)
	local part = Instance.new("Part")
	part.Name = "GuideBeacon"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, 1)
	part.Position = pos + Vector3.new(0, 2, 0)
	part.Parent = folder
	local light = Instance.new("PointLight")
	light.Color = TRAIL_COLOR
	light.Range = 20
	light.Brightness = 2
	light.Parent = part
	beaconPart = part
	beaconLight = light
end

local function toast(text: string)
	if toastShown then
		return
	end
	toastShown = true
	pcall(function()
		StarterGui:SetCore("SendNotification", { Title = "AURA", Text = text, Duration = 4 })
	end)
end

local function buildStraightLine(from: Vector3, to: Vector3)
	local dist = (to - from).Magnitude
	local steps = math.max(1, math.floor(dist / SPACING))
	for i = 1, steps do
		local pos = from:Lerp(to, i / steps)
		table.insert(chevrons, makeChevron(pos, i))
	end
end

local function buildFromWaypoints(waypoints: { PathWaypoint })
	for i, wp in waypoints do
		if i % 1 == 0 then
			table.insert(chevrons, makeChevron(wp.Position, i))
		end
	end
end

local function computeTrail(from: Vector3, to: Vector3)
	for _, p in chevrons do
		p:Destroy()
	end
	table.clear(chevrons)
	lastComputedFrom = from
	lastRecompute = os.clock()

	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
	})
	local ok = pcall(function()
		path:ComputeAsync(from, to)
	end)
	if ok and path.Status == Enum.PathStatus.Success then
		buildFromWaypoints(path:GetWaypoints())
	else
		buildStraightLine(from, to)
		toast("Can't chart a clean path -- follow the line as best you can.")
	end
end

local function stopGuiding()
	activeId = nil
	clearTrail()
end

local function isAutoActive(): string?
	for id in AUTO_GUIDE_IDS do
		local o = objectives[id]
		if o and o.active and not o.done then
			return id
		end
	end
	return nil
end

StateChanged.OnClientEvent:Connect(function(newState: any, payload: any)
	state = newState
	table.clear(objectives)
	if type(payload) == "table" and type(payload.objectives) == "table" then
		for _, o in payload.objectives do
			if type(o) == "table" and type(o.id) == "string" then
				objectives[o.id] = { done = o.done == true, active = o.active == true }
			end
		end
	end
	if state ~= "Reality" and state ~= "Objectives" then
		stopGuiding()
		return
	end
	local auto = isAutoActive()
	if not auto and activeId and AUTO_GUIDE_IDS[activeId] then
		-- our auto objective completed/left -> drop the trail
		stopGuiding()
	elseif auto and auto ~= activeId then
		activeId = auto
		clearTrail()
		toastShown = false
	end
end)

-- G: preview trail to whatever objective is currently active, even outside the auto list.
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.G then
		return
	end
	if activeId then
		return -- already guiding
	end
	for id, o in objectives do
		if o.active and not o.done and ObjectiveDefs[id] and ObjectiveDefs[id].tag then
			activeId = id
			previewUntil = os.clock() + PREVIEW_DURATION
			clearTrail()
			toastShown = false
			break
		end
	end
end)

RunService.Heartbeat:Connect(function()
	if not activeId then
		return
	end
	-- preview guides (G press on non-auto objectives) expire after PREVIEW_DURATION
	if not AUTO_GUIDE_IDS[activeId] and previewUntil > 0 and os.clock() > previewUntil then
		stopGuiding()
		return
	end
	local root = humanoidRoot()
	if not root then
		return
	end
	local target, targetPart = targetFor(activeId)
	if not target then
		return
	end
	if not beaconPart then
		makeBeacon(target)
	elseif targetPart then
		beaconPart.Position = target + Vector3.new(0, 2, 0)
	end
	if beaconLight then
		beaconLight.Brightness = 1.5 + math.sin(os.clock() * 2) * 0.6
	end

	local strayed = lastComputedFrom and (root.Position - lastComputedFrom).Magnitude > STRAY_DIST
	local stale = os.clock() - lastRecompute > RECOMPUTE_INTERVAL
	if not lastComputedFrom or strayed or stale then
		computeTrail(root.Position, target)
	end

	-- gentle sequential pulse toward the goal
	local t = os.clock() * 3
	for _, p in chevrons do
		local order = p:GetAttribute("PulseOrder") or 0
		local wave = (math.sin(t - order * 0.6) + 1) / 2
		p.Transparency = 0.55 - wave * 0.35
	end
end)

player.CharacterAdded:Connect(function()
	lastComputedFrom = nil
end)
