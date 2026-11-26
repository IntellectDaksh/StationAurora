--!strict
-- StoryProps: crew data pads, easter eggs and the nights' small anomalies.
-- Everything lives in Workspace["Aurora Story Props"], built at server start next to the
-- StoryProp_* anchors when the world has them, otherwise next to existing station objects.
-- Never owns state: story flags go through session:SetFlag, objectives through session:Complete,
-- words through the Dialogue cue. No UI labels; nothing here may say what the nights are.
-- ponytail: props are shared world objects, so this assumes one operator per server (single-player).
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")
local ScareDirector = require(script.Parent.Parent.ScareDirector)

local V = Vector3.new
local StoryProps = {}

local folder = workspace:FindFirstChild("Aurora Story Props")
if not folder then
	folder = Instance.new("Folder")
	folder.Name = "Aurora Story Props"
	folder.Parent = workspace
end

local getSession: (Player) -> any = function(_p: Player)
	return nil
end

local function timeScale(): number
	local s = RunService:IsStudio() and workspace:GetAttribute("AuroraQATimeScale")
	return if type(s) == "number" and s > 0 then s else 1
end

local function pivotOf(tag: string): Vector3?
	local inst = CollectionService:GetTagged(tag)[1]
	if not inst then
		return nil
	end
	local ok, cf = pcall(function()
		return (inst :: any):GetPivot()
	end)
	return if ok then (cf :: CFrame).Position else nil
end

local ray = RaycastParams.new()
ray.FilterType = Enum.RaycastFilterType.Exclude
-- First solid, visible surface under a point (skips zone volumes, glass, the props themselves).
local function onSurface(p: Vector3, extra: Instance?): Vector3
	local ignore: { Instance } = { folder }
	if extra then
		table.insert(ignore, extra)
	end
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(ignore, pl.Character)
		end
	end
	for _ = 1, 8 do
		ray.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(p + V(0, 3, 0), V(0, -16, 0), ray)
		if not hit then
			return p
		end
		if hit.Instance.Transparency < 0.9 and hit.Instance.CanCollide then
			return hit.Position
		end
		table.insert(ignore, hit.Instance)
	end
	return p
end

-- World Builder anchor first; else an existing tagged object + offset; else a fixed point.
local function spot(anchor: string, fallbackTag: string, offset: Vector3, fallback: Vector3): Vector3
	local a = anchor ~= "" and pivotOf(anchor)
	if a then
		return onSurface(a + offset * 0.4) -- nudge: two props can share one anchor (pad + photo)
	end
	return onSurface((pivotOf(fallbackTag) or fallback) + offset)
end

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = parent or folder
	return p
end

local function prompt(parent: Instance, action: string, object: string, hold: number?): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = action
	pp.ObjectText = object
	pp.HoldDuration = hold or 0.3
	pp.MaxActivationDistance = 8
	pp.RequiresLineOfSight = false
	pp.Parent = parent
	return pp
end

local function usable(self: any): boolean
	return self ~= nil and self.alive and not self.paused and (self.state == "Reality" or self.state == "Objectives")
end

local function say(self: any, lines: { { any } })
	local name = self.save.settings.operatorName
	local out = {}
	for _, l in lines do
		table.insert(out, { speaker = string.format(l[1], name), text = string.format(l[2], name), hold = l[3] or 3.4 })
	end
	ScareDirector.Fire(self, "Dialogue", { lines = out })
end

----------------------------------------------------------------------------
-- Crew logs: six data pads. Characters first, then the dates that don't add up.
----------------------------------------------------------------------------
local LOGS = {
	{ anchor = "StoryProp_Galley", tag = "Task_StatusLog", off = V(4, 0, 3), lines = {
		{ "OKAFOR", "Mission day 212. Shuttle leaves 06:00 for the Kestrel transfer. Back in two days.", 3.8 },
		{ "OKAFOR", "%s has the station. Keep the basil alive. Don't let AURA pick the music.", 3.8 },
	} },
	{ anchor = "StoryProp_Gym", tag = "Objective_PowerGrid", off = V(4, 0, -3), lines = {
		{ "REYES", "Rerouted the O2 lines again. Same fault, same valve, third time this week.", 3.6 },
		{ "REYES", "AURA logged today as day 212. Yesterday was day 212 too. I told it to stop.", 3.8 },
		{ "REYES", "It said someone has to remember what day it is.", 3.2 },
	} },
	{ anchor = "StoryProp_MedBay", tag = "Task_Hydroponics", off = V(4, 0, 3), lines = {
		{ "LINDQVIST", "Cryo check, pod one. Vitals stable. Frost on the seal, which is normal.", 3.8 },
		{ "LINDQVIST", "REM activity very high. Whoever's in there is having a busy night.", 3.6 },
	} },
	{ anchor = "StoryProp_Cupola", tag = "Objective_Comms", off = V(-4, 0, 3), lines = {
		{ "MERCER", "Relay pinged the shuttle. Clean handshake. They made it.", 3.4 },
		{ "MERCER", "Relay also says it's been 1,096 days since we left. Relay is wrong.", 3.8 },
		{ "MERCER", "Right?", 2.2 },
	} },
	{ anchor = "StoryProp_Photo", tag = "Objective_Observatory", off = V(3, 0, 3), lines = {
		{ "TANAKA", "Something off the west window again. No transponder, no running lights.", 3.6 },
		{ "TANAKA", "It was there yesterday. I checked the archive. It was there last year.", 3.8 },
	} },
	{ anchor = "", tag = "SleepPod", off = V(3, 0, 4), lines = {
		{ "%s", "Mission day 212. Mission day 212. Mission day 212.", 3.4 },
		{ "%s", "I keep writing it down so I don't forget. The pad says this is entry 1,096.", 4 },
	} },
}

local function logsRead(self: any): number
	local n = 0
	for i = 1, #LOGS do
		if self:Flag("Log" .. i) then
			n += 1
		end
	end
	return n
end

local function readLog(self: any, i: number)
	local log = LOGS[i]
	if not (log and usable(self)) then
		return
	end
	say(self, log.lines)
	local key = "Log" .. i
	if not self:Flag(key) then
		self:SetFlag(key)
		local n = logsRead(self)
		ScareDirector.Fire(self, "Toast", { text = string.format("Data pad %d of %d", n, #LOGS) })
		if n == #LOGS then
			self:SetFlag("AllLogs")
			self:Complete("O_Logs")
		end
	end
end
StoryProps.ReadLog = readLog -- QA hook

local function buildLogs()
	for i, log in LOGS do
		local pos = spot(log.anchor, log.tag, log.off, V(-40, 20, -40))
		local pad = part("DataPad" .. i, V(1.1, 0.12, 0.8), CFrame.new(pos + V(0, 0.06, 0)) * CFrame.Angles(0, math.rad(i * 37), math.rad(6)), Color3.fromRGB(30, 34, 40))
		local screen = part("Screen", V(0.9, 0.02, 0.6), pad.CFrame * CFrame.new(0, 0.07, 0), Color3.fromRGB(90, 200, 255), Enum.Material.Neon, pad)
		local light = Instance.new("PointLight")
		light.Color, light.Range, light.Brightness = screen.Color, 5, 0.8
		light.Parent = screen
		prompt(pad, "Read log", "Data pad").Triggered:Connect(function(player)
			readLog(getSession(player), i)
		end)
	end
end

----------------------------------------------------------------------------
-- Easter eggs
----------------------------------------------------------------------------
-- Tally panel by the pod: 100 old marks nobody remembers making, plus one fresh mark per mission day.
local tallyNew: TextLabel? = nil
local function buildTally()
	local base = pivotOf("SleepPod") or V(-43, 29, -9)
	local pos = onSurface(base + V(-5, 0, 3)) + V(0, 2.6, 0)
	local panel = part("TallyPanel", V(3.4, 2.4, 0.15), CFrame.lookAt(pos, V(base.X, pos.Y, base.Z)), Color3.fromRGB(64, 66, 72), Enum.Material.DiamondPlate)
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.CanvasSize = Vector2.new(340, 240)
	g.LightInfluence = 0.7
	g.Parent = panel
	local old = Instance.new("TextLabel")
	old.BackgroundTransparency = 1
	old.Size = UDim2.new(1, -16, 0.72, 0)
	old.Position = UDim2.fromOffset(8, 6)
	old.TextWrapped = true
	old.Font = Enum.Font.PermanentMarker
	old.TextSize = 20
	old.TextColor3 = Color3.fromRGB(160, 160, 150)
	old.TextTransparency = 0.45
	old.TextXAlignment = Enum.TextXAlignment.Left
	old.Text = string.rep("IIII/ ", 20)
	old.Parent = g
	local new = old:Clone()
	new.Size = UDim2.new(1, -16, 0.24, 0)
	new.Position = UDim2.new(0, 8, 0.74, 0)
	new.TextColor3 = Color3.fromRGB(235, 235, 225)
	new.TextTransparency = 0.05
	new.TextSize = 26
	new.Text = ""
	new.Parent = g
	tallyNew = new
end

-- Mug: steps somewhere new every night. Uses the World Builder's StoryProp_Mug when it exists.
local mug: PVInstance? = nil
local mugHome: CFrame = CFrame.identity
local mugLift = 0.5
local MUG_STEPS = { [0] = V(0, 0, 0), V(2.4, 0, -1), V(-2.6, 0, 1.8), V(1, 0, 3.4), V(-1.4, 0, -3) }
local function moveMug(k: number)
	if not (mug and mug.Parent) then
		return
	end
	local off = MUG_STEPS[k % 5] or Vector3.zero
	local p = onSurface(mugHome.Position + off, mug)
	mug:PivotTo(mugHome.Rotation * CFrame.Angles(0, k * 1.3, 0) + p + V(0, mugLift, 0))
end
local function buildMug()
	local tagged = CollectionService:GetTagged("StoryProp_Mug")[1]
	if tagged and tagged:IsA("PVInstance") then
		mug = tagged
		mugHome = tagged:GetPivot()
		mugLift = mugHome.Position.Y - onSurface(mugHome.Position, tagged).Y
	else
		local p = spot("StoryProp_Galley", "Task_StatusLog", V(3, 0, -3), V(-40, 20, -40))
		local m = part("Mug", V(0.7, 0.6, 0.6), CFrame.new(p + V(0, 0.35, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(200, 60, 50), Enum.Material.Plastic)
		m.Shape = Enum.PartType.Cylinder
		part("Handle", V(0.35, 0.12, 0.3), m.CFrame * CFrame.new(0, 0, 0.36), m.Color, Enum.Material.Plastic, m)
		mug = m
		mugHome = m.CFrame
		mugLift = 0.35
	end
end

-- Crew photo: six smiling faces. On the last night they lose their features and all wear your name.
local photoFaces: { { face: Frame, feat: TextLabel, cap: TextLabel, name: string } } = {}
local function buildPhoto()
	local p = spot("StoryProp_Photo", "Task_TaskBoard", V(3, 0, -3), V(-40, 20, -40))
	local frame = part("CrewPhoto", V(2.6, 1.7, 0.1), CFrame.new(p + V(0, 0.95, 0)) * CFrame.Angles(math.rad(-12), math.rad(25), 0), Color3.fromRGB(40, 32, 26), Enum.Material.Wood)
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Front
	g.CanvasSize = Vector2.new(390, 255)
	g.LightInfluence = 0.8
	g.Parent = frame
	local bg = Instance.new("Frame")
	bg.Size = UDim2.new(1, -20, 1, -20)
	bg.Position = UDim2.fromOffset(10, 10)
	bg.BackgroundColor3 = Color3.fromRGB(38, 44, 62)
	bg.Parent = g
	local crew = { { "OKAFOR", Color3.fromRGB(92, 62, 45) }, { "REYES", Color3.fromRGB(176, 128, 96) }, { "LINDQVIST", Color3.fromRGB(240, 205, 180) },
		{ "MERCER", Color3.fromRGB(210, 160, 125) }, { "TANAKA", Color3.fromRGB(226, 190, 150) }, { "", Color3.fromRGB(200, 170, 140) } }
	for i, c in crew do
		local x = (i - 1) % 3
		local y = (i - 1) // 3
		local face = Instance.new("Frame")
		face.Size = UDim2.fromOffset(62, 62)
		face.Position = UDim2.fromOffset(40 + x * 110, 16 + y * 112)
		face.BackgroundColor3 = c[2]
		face.Parent = bg
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = face
		local feat = Instance.new("TextLabel")
		feat.BackgroundTransparency = 1
		feat.Size = UDim2.fromScale(1, 1)
		feat.Font = Enum.Font.GothamBold
		feat.TextSize = 20
		feat.TextColor3 = Color3.fromRGB(20, 20, 20)
		feat.Parent = face
		local cap = Instance.new("TextLabel")
		cap.BackgroundTransparency = 1
		cap.Size = UDim2.fromOffset(110, 18)
		cap.Position = UDim2.fromOffset(-24, 66)
		cap.Font = Enum.Font.Gotham
		cap.TextSize = 12
		cap.TextColor3 = Color3.fromRGB(230, 230, 230)
		cap.Parent = face
		table.insert(photoFaces, { face = face, feat = feat, cap = cap, name = c[1] })
	end
end
local function setPhoto(wrong: boolean, operatorName: string)
	for _, f in photoFaces do
		f.feat.Text = if wrong then "" else "• •\n‿"
		f.cap.Text = if wrong then string.upper(operatorName) else (if f.name == "" then string.upper(operatorName) else f.name)
	end
end

-- Cassette hidden in a galley locker. Only plays if a music Sound exists in the place.
local function musicTemplate(): Sound?
	for _, root in { ReplicatedStorage:FindFirstChild("StationAudio"), ReplicatedStorage:FindFirstChild("AuroraFX") } do
		if root then
			for _, s in root:GetDescendants() do
				if s:IsA("Sound") and string.find(string.lower(s.Name), "music") and not string.find(s.Name, "Dream") and not string.find(s.Name, "D4") then
					return s
				end
			end
		end
	end
	return nil
end
local function buildCassette()
	local template = musicTemplate()
	if not template then
		return -- no music asset: the egg is simply absent
	end
	local galley = pivotOf("StoryProp_Galley") or V(-39, 20, -39)
	local best, bestD = nil, math.huge
	for _, m in workspace:GetDescendants() do
		if m.Name == "Lockers" and m:IsA("Model") then
			local d = (m:GetPivot().Position - galley).Magnitude
			if d < bestD then
				best, bestD = m, d
			end
		end
	end
	local at = if best then best:GetPivot().Position else galley + V(3, 1, 3)
	local tape = part("Cassette", V(0.7, 0.14, 0.45), CFrame.new(at), Color3.fromRGB(25, 25, 28))
	part("Label", V(0.5, 0.02, 0.25), tape.CFrame * CFrame.new(0, 0.08, 0), Color3.fromRGB(230, 200, 120), Enum.Material.SmoothPlastic, tape)
	local music = template:Clone()
	music.Name = "TapeMusic"
	music.Looped = false
	music.Volume = 0.45
	music.RollOffMaxDistance = 45
	music.Parent = tape
	local pp = prompt(tape, "Play tape", "Locker", 0.5)
	local quipped = false
	pp.Triggered:Connect(function(player)
		local self = getSession(player)
		if not usable(self) then
			return
		end
		if music.IsPlaying then
			music:Stop()
			pp.ActionText = "Play tape"
			return
		end
		music.TimePosition = 0
		music:Play()
		pp.ActionText = "Stop tape"
		if not quipped then
			quipped = true
			self:SetFlag("Tape")
			say(self, { { "AURA", "Mercer's tape. She played it every mission day. It's worn thin in one spot.", 3.8 } })
		end
	end)
	music.Ended:Connect(function()
		pp.ActionText = "Play tape"
	end)
end

----------------------------------------------------------------------------
-- EVA (the EVA module fires ServerStorage.AuroraEVAEvent(player, "DishFixed"|"EVAStart"|"EVAEnd"|"DuckFound"))
----------------------------------------------------------------------------
local function hookEVA()
	local ev = ServerStorage:FindFirstChild("AuroraEVAEvent")
	if not ev then
		ev = Instance.new("BindableEvent")
		ev.Name = "AuroraEVAEvent"
		ev.Parent = ServerStorage
	end
	(ev :: BindableEvent).Event:Connect(function(player: any, what: any)
		local p = if typeof(player) == "Instance" and player:IsA("Player") then player else Players:GetPlayers()[1]
		local self = p and getSession(p)
		if not (self and self.alive) then
			return
		end
		if what == "DishFixed" then
			if not self:Flag("DishFixed") then
				self:SetFlag("DishFixed")
				self:Beat("Dish_Fixed")
			end
			self:Complete("O_Dish")
		elseif what == "EVAStart" then
			self:SetFlag("EVA")
		elseif what == "DuckFound" then
			if not self:Flag("DuckFound") then
				self:SetFlag("DuckFound")
				self:Beat("Duck_Found")
			end
		end
	end)
end

----------------------------------------------------------------------------
-- Night mini-anomalies: between objectives, random order, never labelled.
-- Visual/audio side is CameraEffects' "Mini" cue; words go through Dialogue.
----------------------------------------------------------------------------
local OWN_VOICE = {
	"AURA, who else is awake?",
	"I'm still in the pod. I'm still in the pod.",
	"Okafor? Is that you?",
	"What day is it. Really.",
}
local function mini(self: any, kind: string)
	if kind == "Whisper" then
		say(self, { { "COMMS", "...%s... don't... wake...", 3 } })
		ScareDirector.Fire(self, "Mini", { kind = kind, pos = pivotOf("Objective_Comms") })
	elseif kind == "OwnVoice" then
		say(self, { { "%s", OWN_VOICE[math.random(#OWN_VOICE)], 3.2 } })
	elseif kind == "Moved" then
		moveMug(math.random(1, 4))
		ScareDirector.Fire(self, "Mini", { kind = kind, pos = mug and mug:GetPivot().Position })
	else
		ScareDirector.Fire(self, "Mini", { kind = kind, pos = if kind == "Knock" then pivotOf("Task_Recycler") else nil })
	end
end

local function nightLoop(self: any, d: number, token: {})
	local pool = { "Footsteps", "Whisper", "Silhouette", "LightChase", "OwnVoice", "Moved" }
	if self:Flag("Knocked") then
		table.insert(pool, "Knock")
		table.insert(pool, "Knock")
	end
	for i = #pool, 2, -1 do
		local j = math.random(i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local i, t, nextMini, nextKnock = 0, 0, 8 + math.random() * 8, 0
	while self.alive and self.miniToken == token and self.dream == d do
		task.wait(0.5)
		if self.paused or self.state ~= "Objectives" then
			continue
		end
		t += 0.5 * timeScale()
		if self.active.D3_Knock and t >= nextKnock then
			nextKnock = t + 6
			ScareDirector.Fire(self, "Mini", { kind = "Knock", pos = pivotOf("Task_Recycler") })
		end
		if t >= nextMini then
			nextMini = t + 15 + math.random() * 12
			i += 1
			mini(self, pool[(i - 1) % #pool + 1])
		end
	end
end

----------------------------------------------------------------------------
-- Director hooks (non-yielding)
----------------------------------------------------------------------------
function StoryProps.OnDay(self: any, n: number)
	self.miniToken = nil
	if tallyNew then
		tallyNew.Text = string.rep("I", n)
	end
	moveMug(({ 0, 2, 3 })[n] or n)
	setPhoto(false, self.save.settings.operatorName)
	-- optional objectives already satisfied on an earlier day / before a rejoin
	if self:Flag("DishFixed") then
		self.completed.O_Dish = true
	end
	if self:Flag("AllLogs") then
		self.completed.O_Logs = true
	end
end

function StoryProps.OnNight(self: any, d: number)
	if d == 4 then -- last night: the photo goes wrong
		setPhoto(true, self.save.settings.operatorName)
	end
	local token = {}
	self.miniToken = token
	task.spawn(nightLoop, self, d, token)
end

function StoryProps.Init(getter: (Player) -> any)
	getSession = getter
	for _, build in { buildLogs, buildTally, buildMug, buildPhoto, buildCassette, hookEVA } do
		local ok, err = pcall(build)
		if not ok then
			warn("[StoryProps] build failed:", err)
		end
	end
	setPhoto(false, "")
end

return StoryProps
