-- HUDController: every player-facing UI for Station Aurora, built from code (one source of truth).
-- Renders StateChanged / StationState_Changed / PlayCue (Keypad, Toast, NoRepairUnits, Dialogue,
-- Cinematic, CinematicEnd), sends RequestAction / RequestChoice / RequestObjectiveComplete, gates
-- AuroraPrompt visibility, draws custom ProximityPrompts + objective waypoints, and drives the
-- main-menu camera drift.
--
-- Design system (shared with ReplicatedFirst.LoadingScreen, keep in sync):
--   type   GothamSSm; sizes 12 caption / 14 small / 16 body / 20 title / 32 card / 44 display
--          RobotoMono for numbers only
--   color  near-black surfaces, off-white text, ONE accent (cyan 90,200,255) for interactive and
--          active items; red only for critical (O2 < 30, signal lost, wrong code)
--   shape  radius 6 on every surface, keycap and control; 1px hairlines; no heavy chrome
--   motion 0.25-0.6s Quint out fades/slides; stagger 0.06s

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local SoundService = game:GetService("SoundService")
local StarterGui = game:GetService("StarterGui")
local ProximityPromptService = game:GetService("ProximityPromptService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local StateChanged = Remotes:WaitForChild("StateChanged")
local StationChanged = Remotes:WaitForChild("StationState_Changed")
local PlayCue = Remotes:WaitForChild("PlayCue")
local RequestAction = Remotes:WaitForChild("RequestAction")
local RequestChoice = Remotes:WaitForChild("RequestChoice")
local RequestObjectiveComplete = Remotes:WaitForChild("RequestObjectiveComplete")
local Modules = ReplicatedStorage:WaitForChild("Modules")
local States = require(Modules:WaitForChild("GameStateEnum"))
local okDefs, DreamEvents = pcall(require, Modules:WaitForChild("DreamEvents"))
local ObjectiveDefs: { [string]: any } = if okDefs and type(DreamEvents) == "table" and type(DreamEvents.Objectives) == "table"
	then DreamEvents.Objectives
	else {}

----------------------------------------------------------------------------
-- Tokens
----------------------------------------------------------------------------
local C = {
	bg = Color3.fromRGB(7, 9, 12),
	surface = Color3.fromRGB(14, 17, 22),
	line = Color3.fromRGB(255, 255, 255),
	accent = Color3.fromRGB(90, 200, 255),
	amber = Color3.fromRGB(255, 176, 92),
	red = Color3.fromRGB(255, 92, 92),
	text = Color3.fromRGB(236, 240, 244),
	dim = Color3.fromRGB(150, 160, 172),
	faint = Color3.fromRGB(88, 98, 110),
	black = Color3.fromRGB(0, 0, 0),
}
local FAM = "rbxasset://fonts/families/GothamSSm.json"
local LIGHT = Font.new(FAM, Enum.FontWeight.Light)
local BODY = Font.new(FAM, Enum.FontWeight.Regular)
local MED = Font.new(FAM, Enum.FontWeight.Medium)
local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Regular)
local R = 6
local EASE = TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out)

local HUD_STATES = { Reality = true, Objectives = true, DreamLayer = true }
local PROMPT_STATES = { Reality = true, Objectives = true }
local ROMAN = { "I", "II", "III", "IV", "V", "VI" }

----------------------------------------------------------------------------
-- Builders
----------------------------------------------------------------------------
local function new(class: string, props: { [string]: any }?, children: { Instance }?)
	local inst = Instance.new(class)
	local parent = nil
	for k, v in props or {} do
		if k == "Parent" then
			parent = v
		else
			(inst :: any)[k] = v
		end
	end
	for _, c in children or {} do
		c.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function corner(r: number?)
	return new("UICorner", { CornerRadius = UDim.new(0, r or R) })
end

local function stroke(color: Color3?, t: number?)
	return new("UIStroke", {
		Color = color or C.line,
		Thickness = 1,
		Transparency = t or 0.85,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function pad(y: number, x: number?)
	local px = UDim.new(0, x or y)
	return new("UIPadding", { PaddingTop = UDim.new(0, y), PaddingBottom = UDim.new(0, y), PaddingLeft = px, PaddingRight = px })
end

local function list(gap: number, horizontal: boolean?, align: Enum.HorizontalAlignment?)
	return new("UIListLayout", {
		Padding = UDim.new(0, gap),
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		HorizontalAlignment = align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
		SortOrder = Enum.SortOrder.LayoutOrder,
	})
end

local function label(props: { [string]: any })
	local base = {
		BackgroundTransparency = 1,
		FontFace = BODY,
		TextSize = 16,
		TextColor3 = C.text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}
	for k, v in props do
		base[k] = v
	end
	return new("TextLabel", base)
end

-- Fixed-size single-line label (numbers, captions).
local function tag(text: string, size: number, props: { [string]: any }?)
	local base = {
		Text = text,
		FontFace = MED,
		TextSize = size,
		TextColor3 = C.dim,
		TextWrapped = false,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
	}
	for k, v in props or {} do
		base[k] = v
	end
	return label(base)
end

-- Wide tracking: Roblox text has no letter-spacing, so spaced caps stand in for it.
local function track(s: string, gap: string?): string
	local out = {}
	for _, cp in utf8.codes(string.upper(s)) do
		table.insert(out, utf8.char(cp))
	end
	return table.concat(out, gap or " ")
end

local scales: { UIScale } = {}
local function scaled(frame: GuiObject)
	table.insert(scales, new("UIScale", { Parent = frame }) :: UIScale)
	return frame
end

local function screen(name: string, order: number, enabled: boolean?)
	local old = playerGui:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	return new("ScreenGui", {
		Name = name,
		DisplayOrder = order,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = enabled == true,
		Parent = playerGui,
	}) :: ScreenGui
end

local function backdrop(parent: Instance, t: number)
	return new("Frame", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.bg,
		BackgroundTransparency = t,
		BorderSizePixel = 0,
		Active = true,
		Parent = parent,
	})
end

local function hair(parent: Instance, props: { [string]: any }?)
	local base = { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.line, BackgroundTransparency = 0.88, BorderSizePixel = 0, Parent = parent }
	for k, v in props or {} do
		base[k] = v
	end
	return new("Frame", base)
end

local function tween(obj: Instance, props: { [string]: any }, t: number?, style: Enum.EasingStyle?)
	local tw = TweenService:Create(obj, if t or style then TweenInfo.new(t or 0.35, style or Enum.EasingStyle.Quint, Enum.EasingDirection.Out) else EASE, props)
	tw:Play()
	return tw
end
local fade = function(obj: Instance, t: number, props: { [string]: any })
	return tween(obj, props, t)
end

local function inputMode(): string
	local t = UserInputService:GetLastInputType()
	if string.find(t.Name, "Gamepad") then
		return "pad"
	elseif t == Enum.UserInputType.Touch then
		return "touch"
	end
	return "kb"
end
local function isGamepad(): boolean
	return inputMode() == "pad"
end
local function focus(obj: GuiObject?)
	if obj and isGamepad() then
		GuiService.SelectedObject = obj
	end
end

-- Text-style button: label + accent underline that sweeps in on hover / gamepad focus.
-- "Disabled" attribute greys it out and blocks Activated.
local function textButton(text: string, size: number?, props: { [string]: any }?)
	local b = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Selectable = true,
		Size = UDim2.fromOffset(0, (size or 20) + 22),
		AutomaticSize = Enum.AutomaticSize.X,
		Modal = true,
	}) :: TextButton
	local t = tag(text, size or 20, {
		Name = "Label",
		FontFace = if (size or 20) >= 28 then LIGHT else BODY,
		TextColor3 = C.text,
		TextTransparency = 0.25,
		Position = UDim2.fromOffset(0, 4),
		Parent = b,
	})
	local line = new("Frame", {
		Name = "Underline",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(0, 0, 0, 1),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
		Parent = b,
	})
	for k, v in props or {} do
		(b :: any)[k] = v
	end
	local hovered = false
	local function paint()
		local dis = b:GetAttribute("Disabled") == true
		tween(t, { TextTransparency = if dis then 0.7 elseif hovered then 0 else 0.25 }, 0.2)
		tween(line, { Size = UDim2.new(if hovered and not dis then 1 else 0, 0, 0, 1) }, 0.35)
	end
	local function setHover(v: boolean)
		hovered = v
		paint()
	end
	b.MouseEnter:Connect(function()
		setHover(true)
	end)
	b.MouseLeave:Connect(function()
		setHover(false)
	end)
	b.SelectionGained:Connect(function()
		setHover(true)
	end)
	b.SelectionLost:Connect(function()
		setHover(false)
	end)
	b:GetAttributeChangedSignal("Disabled"):Connect(paint)
	b.SelectionImageObject = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }) :: GuiObject
	return b, t
end

-- Boxed control (keypad keys, volume steps, segmented options).
local function boxButton(text: string, props: { [string]: any }?)
	local b = new("TextButton", {
		Text = text,
		FontFace = MED,
		TextSize = 16,
		TextColor3 = C.text,
		AutoButtonColor = false,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.1,
		Selectable = true,
		Size = UDim2.fromOffset(40, 40),
		Modal = true,
	}, { corner() }) :: TextButton
	local s = stroke(C.line, 0.88)
	s.Parent = b
	for k, v in props or {} do
		(b :: any)[k] = v
	end
	local hovered = false
	local function paint()
		local dis = b:GetAttribute("Disabled") == true
		local on = b:GetAttribute("On") == true
		b.TextTransparency = if dis then 0.65 else 0
		tween(s, { Color = if (hovered or on) and not dis then C.accent else C.line, Transparency = if on then 0.2 elseif hovered then 0.35 else 0.88 }, 0.15)
		b.TextColor3 = if on then C.accent else C.text
	end
	for sig, v in { [b.MouseEnter] = true, [b.MouseLeave] = false, [b.SelectionGained] = true, [b.SelectionLost] = false } do
		sig:Connect(function()
			hovered = v
			paint()
		end)
	end
	b:GetAttributeChangedSignal("Disabled"):Connect(paint)
	b:GetAttributeChangedSignal("On"):Connect(paint)
	b.MouseButton1Down:Connect(function()
		if not b:GetAttribute("Disabled") then
			b.BackgroundColor3 = C.bg
			tween(b, { BackgroundColor3 = C.surface }, 0.25)
		end
	end)
	b.SelectionImageObject = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }) :: GuiObject
	return b
end

local function onClick(b: GuiButton, fn: () -> ())
	b.Activated:Connect(function()
		if not b:GetAttribute("Disabled") then
			fn()
		end
	end)
end

local function setDisabled(b: GuiButton, v: boolean)
	b:SetAttribute("Disabled", v)
	b.Selectable = not v
end

local function send(action: string, data: any?)
	RequestAction:FireServer(action, data)
end

-- Keycap: the one glyph for "press this" everywhere (prompts, hint cards, intro skip).
local PAD_NAMES = {
	ButtonA = "A", ButtonB = "B", ButtonX = "X", ButtonY = "Y", ButtonL1 = "LB", ButtonR1 = "RB",
	ButtonL2 = "LT", ButtonR2 = "RT", ButtonSelect = "View", ButtonStart = "Menu", Thumbstick1 = "LS", Thumbstick2 = "RS",
}
local KEY_TO_PAD = { E = "X", Space = "A", Enter = "A", F = "Y", Tab = "View", Shift = "LT", W = "LS", A = "LS", S = "LS", D = "LS" }
local function keycap(text: string, parent: Instance?, size: number?)
	local h = size or 26
	return new("TextLabel", {
		Name = "Keycap",
		Text = text,
		FontFace = MED,
		TextSize = math.floor(h * 0.5),
		TextColor3 = C.text,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.05,
		Size = UDim2.fromOffset(h, h),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = parent,
	}, { corner(), stroke(C.line, 0.7), new("UIPadding", { PaddingLeft = UDim.new(0, 7), PaddingRight = UDim.new(0, 7) }) })
end

----------------------------------------------------------------------------
-- Client state
----------------------------------------------------------------------------
local curState = ""
local curPayload: { [string]: any } = {}
local paused = false
local cinematic = false
local activeIds: { [string]: boolean } = {}
local objOrder: { string } = {}
local station: { [string]: number } = {}
local subtitlesOn = true
local textSpeed = 1 -- 0.6 slow / 1 normal / 1.6 fast (typewriter multiplier)

----------------------------------------------------------------------------
-- Core GUI + volume
----------------------------------------------------------------------------
for _, t in { Enum.CoreGuiType.PlayerList, Enum.CoreGuiType.Backpack } do
	pcall(StarterGui.SetCoreGuiEnabled, StarterGui, t, false)
end

-- ponytail: master volume = one client SoundGroup adopting every *ungrouped* Sound; sounds another
-- agent already put in its own SoundGroup keep that group (nest it under AuroraMaster to include it).
local master = SoundService:FindFirstChild("AuroraMaster")
if not (master and master:IsA("SoundGroup")) then
	master = new("SoundGroup", { Name = "AuroraMaster", Volume = 1, Parent = SoundService })
end
local function adopt(s: Instance)
	if s:IsA("Sound") and (s.SoundGroup == nil or s.SoundGroup == master) then
		-- route into the mixer bus (AuroraMaster.Master.Music / SFX) when one exists, so the
		-- Music / Effects sliders reach it; otherwise straight under master
		local bus = (master :: Instance):FindFirstChild(if string.sub(s.Name, 1, 5) == "Music" then "Music" else "SFX", true)
		s.SoundGroup = (if bus and bus:IsA("SoundGroup") then bus else master) :: SoundGroup
	end
end
for _, root in { workspace, SoundService, ReplicatedStorage, playerGui } do
	for _, d in root:GetDescendants() do
		adopt(d)
	end
	root.DescendantAdded:Connect(adopt)
end
local volume = 1
local function applyVolume(v: number)
	volume = math.clamp(math.floor(v * 10 + 0.5) / 10, 0, 1)
	local g = master :: SoundGroup
	g.Volume = volume
end

----------------------------------------------------------------------------
-- Cinematic signal (CameraEffects / Cinematics fire it; created here if they have not yet)
----------------------------------------------------------------------------
local signals = ReplicatedStorage:FindFirstChild("AuroraClientSignals")
if not signals then
	signals = new("Folder", { Name = "AuroraClientSignals", Parent = ReplicatedStorage })
end
local cinSignal = signals:FindFirstChild("CinematicActive")
if not (cinSignal and cinSignal:IsA("BindableEvent")) then
	cinSignal = new("BindableEvent", { Name = "CinematicActive", Parent = signals })
end


----------------------------------------------------------------------------
-- Toasts (DisplayOrder 20)
----------------------------------------------------------------------------
local toast
do -- scoped: keeps top-level locals under Luau's 200-register limit
local toastGui = screen("Toasts", 20, true)
local toastList = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 72),
	Size = UDim2.fromOffset(640, 200),
	Parent = toastGui,
}, { list(8, false, Enum.HorizontalAlignment.Center) }))
local toastSeq = 0

function toast(text: any, critical: boolean?)
	if type(text) ~= "string" or text == "" then
		return
	end
	toastSeq += 1
	local items = {}
	for _, c in toastList:GetChildren() do
		if c:IsA("CanvasGroup") then
			table.insert(items, c)
		end
	end
	table.sort(items, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	for i = 1, #items - 2 do
		items[i]:Destroy()
	end
	local g = new("CanvasGroup", {
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.08,
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		GroupTransparency = 1,
		LayoutOrder = toastSeq,
		Parent = toastList,
	}, { corner(), stroke(if critical then C.red else C.line, if critical then 0.4 else 0.85), pad(0, 16), list(10, true) }) :: CanvasGroup
	new("Frame", { Size = UDim2.fromOffset(6, 6), BackgroundColor3 = if critical then C.red else C.accent, BorderSizePixel = 0, Parent = g }, { corner(3) })
	tag(text, 14, { TextColor3 = C.text, FontFace = BODY, LayoutOrder = 2, Parent = g })
	tween(g, { GroupTransparency = 0 }, 0.3)
	task.delay(3.2, function()
		if g.Parent then
			tween(g, { GroupTransparency = 1 }, 0.5).Completed:Connect(function()
				g:Destroy()
			end)
		end
	end)
end

end

----------------------------------------------------------------------------
-- Subtitles, hint cards, chapter cards (DisplayOrder 60: readable above the FX fade at 50)
----------------------------------------------------------------------------
local subGui = screen("Subtitles", 60, true)
local subBox = scaled(new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -64),
	Size = UDim2.fromOffset(0, 0),
	AutomaticSize = Enum.AutomaticSize.XY,
	BackgroundColor3 = C.black,
	BackgroundTransparency = 0.45,
	GroupTransparency = 1,
	Parent = subGui,
}, {
	corner(10),
	new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.18, 0), NumberSequenceKeypoint.new(0.82, 0), NumberSequenceKeypoint.new(1, 1) }) }),
	pad(12, 56),
	list(6, false, Enum.HorizontalAlignment.Center),
	new("UISizeConstraint", { MaxSize = Vector2.new(900, 400) }),
}))
local subSpeaker = tag("", 13, { FontFace = MED, TextColor3 = C.amber, LayoutOrder = 1, Parent = subBox })
local subText = label({
	FontFace = BODY,
	TextSize = 24,
	TextColor3 = C.text,
	TextStrokeColor3 = C.black,
	TextStrokeTransparency = 0.55,
	LineHeight = 1.15,
	TextXAlignment = Enum.TextXAlignment.Center,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.new(),
	LayoutOrder = 2,
	Parent = subBox,
})
new("UISizeConstraint", { MaxSize = Vector2.new(780, 400), Parent = subText })
-- cinematic captions own the bottom strip: lift the subtitle box above them while one runs
cinSignal.Event:Connect(function(on)
	subBox.Position = if on then UDim2.new(0.5, 0, 0.74, 0) else UDim2.new(0.5, 0, 1, -64)
end)

local subQueue: { { speaker: string?, text: string, hold: number } } = {}
local subRunning = false
local lastSub, lastSubAt = "", 0

local function runSubs()
	if subRunning then
		return
	end
	subRunning = true
	task.spawn(function()
		while #subQueue > 0 do
			local line = table.remove(subQueue, 1) :: any
			subSpeaker.Text = if line.speaker and line.speaker ~= "" then track(line.speaker) else ""
			subSpeaker.Visible = subSpeaker.Text ~= ""
			subText.Text = line.text
			subText.MaxVisibleGraphemes = 0
			tween(subBox, { GroupTransparency = 0 }, 0.25)
			local n = utf8.len(line.text) or #line.text
			local cps = 45 * textSpeed
			local t = 0
			while t * cps < n do
				t += task.wait()
				subText.MaxVisibleGraphemes = math.floor(t * cps)
			end
			subText.MaxVisibleGraphemes = -1
			task.wait(math.max(1.2, (line.hold or 3) - n / cps))
			if #subQueue == 0 then
				tween(subBox, { GroupTransparency = 1 }, 0.5)
				task.wait(0.5)
			end
		end
		subRunning = false
	end)
end

local function queueLine(speaker: string?, text: any, hold: number?, force: boolean?)
	if type(text) ~= "string" or text == "" then
		return
	end
	if not subtitlesOn and not force then
		return
	end
	if text == lastSub and os.clock() - lastSubAt < 20 then
		return -- same line re-sent by the next state (e.g. result then Scare beat)
	end
	lastSub, lastSubAt = text, os.clock()
	-- backlog guard: a burst of beats used to stack up and play seconds late over the next scene
	while #subQueue >= 6 do
		table.remove(subQueue, 1)
	end
	table.insert(subQueue, { speaker = speaker, text = text, hold = hold or 4 })
	runSubs()
end
local function subtitle(text: any)
	queueLine(nil, text, 4.5, true) -- system narration (results, drift lines) shows even with subtitles off
end
-- Background voices: old crew-channel recordings leak through comms while you're awake;
-- at night the same voices come back wrong. Static burst under each line.
do -- scoped: keeps top-level locals under Luau's 200-register limit
	local AWAKE = {
		{ "REYES", "Valve three again. Logging it so nobody blames me next rotation." },
		{ "TANAKA", "Anyone else hear knocking in the washroom pipes? Just me? Great." },
		{ "OKAFOR", "Galley rota's on the board. Yes, %s, you too." },
		{ "MERCER", "Tape seven's mine. Don't record over it." },
		{ "LINDQVIST", "Shuttle window opens oh-six-hundred. Pack light." },
		{ "OKAFOR", "If the scrubbers whine, kick the panel. Gently." },
		{ "REYES", "Something on long-range again. Probably ice. Probably." },
	}
	local NIGHT = {
		{ "OKAFOR", "...%s? Why are you still awake..." },
		{ "REYES", "...valve three... valve three... valve three..." },
		{ "TANAKA", "...it's right outside the window. Don't look at it..." },
		{ "MERCER", "...we never left. Check the shuttle bay..." },
	}
	local mode = "off"
	StateChanged.OnClientEvent:Connect(function(state, p)
		p = if type(p) == "table" then p else {}
		local d = tonumber(p.dream) or 0
		mode = if state == "Reality" then "awake" elseif state == "Objectives" and d >= 1 and d <= 4 then "night" else "off"
	end)
	task.spawn(function()
		local lastIdx = 0
		while true do
			task.wait(math.random(55, 95))
			if mode ~= "off" and #subQueue == 0 then
				local pool = if mode == "night" then NIGHT else AWAKE
				local i = math.random(1, #pool)
				if i == lastIdx then
					i = i % #pool + 1
				end
				lastIdx = i
				local fx = ReplicatedStorage:FindFirstChild("AuroraFX")
				local st = fx and fx:FindFirstChild("Sounds") and fx.Sounds:FindFirstChild("Static")
				if st and st:IsA("Sound") then
					local c = st:Clone()
					c.Looped, c.Volume = false, 0.25
					c.Parent = workspace.CurrentCamera
					c:Play()
					task.delay(1.2, c.Destroy, c)
				end
				local name = player:GetAttribute("AuroraOperator") or "Operator"
				queueLine("CREW CH. " .. (if mode == "night" then "??" else "4") .. " · " .. pool[i][1], string.format(pool[i][2], tostring(name)), 4)
			end
		end
	end)
end

-- Hint card: non-blocking, bottom-left, keycaps swap with input type.
local hintCard = scaled(new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -150),
	Size = UDim2.fromOffset(0, 44),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = C.surface,
	BackgroundTransparency = 0.08,
	GroupTransparency = 1,
	Visible = false,
	Parent = subGui,
}, { corner(), stroke(C.line, 0.85), pad(0, 10), list(8, true) }))
local hintKeys = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 1, Parent = hintCard }, { list(4, true) })
local hintText = tag("", 14, { FontFace = BODY, TextColor3 = C.text, LayoutOrder = 2, Parent = hintCard })
local hintGen = 0
local hintData: any = nil

local function paintHint()
	for _, c in hintKeys:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	if not hintData then
		return
	end
	local mode = inputMode()
	local seen = {}
	if mode ~= "touch" and type(hintData.keys) == "table" then
		for i, k in hintData.keys do
			local name = if mode == "pad" then (KEY_TO_PAD[k] or k) else k
			if not seen[name] then
				seen[name] = true
				keycap(name, hintKeys).LayoutOrder = i
			end
		end
	end
	hintKeys.Visible = #hintKeys:GetChildren() > 1
end

local function showHint(h: any)
	if type(h) ~= "table" or type(h.text) ~= "string" then
		return
	end
	hintGen += 1
	local gen = hintGen
	hintData = h
	hintText.Text = h.text
	paintHint()
	hintCard.Visible = true
	tween(hintCard, { GroupTransparency = 0 }, 0.35)
	task.delay(7, function()
		if gen == hintGen then
			tween(hintCard, { GroupTransparency = 1 }, 0.6).Completed:Connect(function()
				if gen == hintGen then
					hintCard.Visible = false
					hintData = nil
				end
			end)
		end
	end)
end

local showChapter, hideChapter
do -- scoped: keeps top-level locals under Luau's 200-register limit
-- Chapter card: "DREAM I" / "System Anomaly" with a short accent rule.
local chapter = scaled(new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.42),
	Size = UDim2.fromOffset(800, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	GroupTransparency = 1,
	Visible = false,
	Parent = subGui,
}, { list(14, false, Enum.HorizontalAlignment.Center) }))
local chapterKicker = tag("", 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 1, Parent = chapter })
local chapterTitle = tag("", 44, { FontFace = LIGHT, TextColor3 = C.text, LayoutOrder = 2, Parent = chapter })
local chapterRule = new("Frame", { Size = UDim2.fromOffset(0, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0, LayoutOrder = 3, Parent = chapter })
local chapterGen = 0

function showChapter(kicker: string, title: any, alert: boolean?)
	if type(title) ~= "string" or title == "" then
		return
	end
	chapterGen += 1
	local gen = chapterGen
	chapterKicker.Text = track(kicker)
	chapterKicker.TextColor3 = if alert then C.red else C.dim
	chapterTitle.Text = title
	chapterRule.BackgroundColor3 = if alert then C.red else C.accent
	chapterRule.Size = UDim2.fromOffset(0, 1)
	chapter.Position = UDim2.fromScale(0.5, 0.44)
	chapter.Visible = true
	tween(chapter, { GroupTransparency = 0, Position = UDim2.fromScale(0.5, 0.42) }, 0.9)
	tween(chapterRule, { Size = UDim2.fromOffset(48, 1) }, 1.2)
	task.delay(3.6, function()
		if gen ~= chapterGen then
			return
		end
		tween(chapter, { GroupTransparency = 1 }, 0.9).Completed:Connect(function()
			if gen == chapterGen then
				chapter.Visible = false
			end
		end)
	end)
end
function hideChapter()
	chapterGen += 1
	chapter.Visible = false
end

end

----------------------------------------------------------------------------
-- ObjectiveHUD (DisplayOrder 10)
----------------------------------------------------------------------------
local hudGui = screen("ObjectiveHUD", 10)
-- soft corner scrims keep white text legible on bright rooms without drawing panels
for _, spec in { { Vector2.new(0, 0), 0 }, { Vector2.new(0, 1), 1 } } do
	new("Frame", {
		AnchorPoint = spec[1],
		Position = UDim2.fromScale(spec[1].X, spec[1].Y),
		Size = UDim2.fromOffset(560, 300),
		BackgroundColor3 = C.black,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Parent = hudGui,
	}, {
		new("UIGradient", {
			Rotation = if spec[2] == 0 then 35 else -35,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.55, 0.85), NumberSequenceKeypoint.new(1, 1) }),
		}),
	})
end

local tracker = scaled(new("Frame", {
	BackgroundTransparency = 1,
	Position = UDim2.fromOffset(28, 72), -- clear of the Roblox top bar
	Size = UDim2.fromOffset(340, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = hudGui,
}, { list(6) }))
local chapterLine = tag("", 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 1, Parent = tracker })
local trackerTitle = tag("", 20, { FontFace = MED, TextColor3 = C.text, LayoutOrder = 2, Parent = tracker })
local locationLine = tag("", 12, { FontFace = BODY, TextColor3 = C.faint, LayoutOrder = 3, Visible = false, Parent = tracker })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 6), LayoutOrder = 5, Parent = tracker })
local objList = new("Frame", {
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	LayoutOrder = 6,
	Parent = tracker,
}, { list(10) })

do -- scoped: keeps top-level locals under Luau's 200-register limit
-- Day-1 task timer: LocalPlayer attribute AuroraTaskTimer (seconds remaining, nil = not running).
local timerLine = tag("", 14, { FontFace = MONO, TextColor3 = C.dim, LayoutOrder = 4, Visible = false, Parent = tracker })
local function paintTaskTimer()
	local t = player:GetAttribute("AuroraTaskTimer")
	if type(t) ~= "number" then
		timerLine.Visible = false
		return
	end
	local secs = math.max(0, math.floor(t))
	timerLine.Visible = true
	timerLine.Text = string.format("TIME LEFT \xC2\xB7 %d:%02d", secs // 60, secs % 60)
	if secs < 30 then
		local a = 0.5 + 0.5 * math.sin(os.clock() * 6)
		timerLine.TextColor3 = C.red
		timerLine.TextTransparency = 0.35 * a
	elseif secs < 90 then
		timerLine.TextColor3 = C.amber
		timerLine.TextTransparency = 0
	else
		timerLine.TextColor3 = C.dim
		timerLine.TextTransparency = 0
	end
end
player:GetAttributeChangedSignal("AuroraTaskTimer"):Connect(paintTaskTimer)
RunService.Heartbeat:Connect(function()
	if type(player:GetAttribute("AuroraTaskTimer")) == "number" then
		paintTaskTimer()
	end
end)
paintTaskTimer()
end

type Row = { frame: Frame, ring: Frame, fill: Frame, text: TextLabel, hint: TextLabel, dist: TextLabel, strike: Frame, done: boolean, active: boolean }
local rows: { [string]: Row } = {}

local function makeRow(id: string): Row
	local f = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = objList }) :: Frame
	local ring = new("Frame", { Position = UDim2.fromOffset(0, 4), Size = UDim2.fromOffset(12, 12), BackgroundTransparency = 1, Parent = f }, { corner(6), stroke(C.dim, 0.3) }) :: Frame
	local fill = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0, 0),
		BackgroundColor3 = C.accent,
		BorderSizePixel = 0,
		Parent = ring,
	}, { corner(6) }) :: Frame
	local body = new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 0),
		Size = UDim2.new(1, -24, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = f,
	}, { list(3) })
	local top = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
	local text = label({ TextSize = 16, Size = UDim2.new(1, -56, 0, 0), Parent = top }) :: TextLabel
	local dist = tag("", 12, {
		FontFace = MONO,
		TextColor3 = C.dim,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 3),
		Parent = top,
	}) :: TextLabel
	local strike = new("Frame", { Position = UDim2.new(0, 0, 0, 10), Size = UDim2.new(0, 0, 0, 1), BackgroundColor3 = C.dim, BorderSizePixel = 0, Parent = top }) :: Frame
	local hint = label({ TextSize = 14, FontFace = BODY, TextColor3 = C.dim, Visible = false, LayoutOrder = 2, Parent = body }) :: TextLabel
	local row = { frame = f, ring = ring, fill = fill, text = text, hint = hint, dist = dist, strike = strike, done = false, active = false }
	rows[id] = row
	return row
end

local function paintRow(row: Row, done: boolean, active: boolean, animate: boolean)
	local ringStroke = row.ring:FindFirstChildOfClass("UIStroke") :: UIStroke
	if done then
		ringStroke.Color = C.accent
		ringStroke.Transparency = 0.2
		row.hint.Visible = false
		row.dist.Text = ""
		if animate then
			row.fill.Size = UDim2.fromScale(0, 0)
			tween(row.fill, { Size = UDim2.fromScale(1, 1) }, 0.45, Enum.EasingStyle.Back)
			row.text.TextColor3 = C.text
			tween(row.text, { TextTransparency = 0.55 }, 0.8)
			task.delay(0.25, function()
				local w = math.min(row.text.TextBounds.X, row.text.AbsoluteSize.X)
				tween(row.strike, { Size = UDim2.new(0, w, 0, 1) }, 0.5)
			end)
		else
			row.fill.Size = UDim2.fromScale(1, 1)
			row.text.TextTransparency = 0.55
			task.defer(function()
				row.strike.Size = UDim2.new(0, math.min(row.text.TextBounds.X, row.text.AbsoluteSize.X), 0, 1)
			end)
		end
		row.text.TextColor3 = C.dim
	else
		row.fill.Size = UDim2.fromScale(0, 0)
		row.strike.Size = UDim2.new(0, 0, 0, 1)
		ringStroke.Color = if active then C.accent else C.faint
		ringStroke.Transparency = if active then 0 else 0.2
		row.text.TextColor3 = if active then C.text else C.dim
		row.text.TextTransparency = if active then 0 else 0.35
		row.hint.Visible = active and row.hint.Text ~= ""
	end
end

local function renderObjectives(objs: any)
	local seen = {}
	objOrder = {}
	if type(objs) == "table" then
		for i, o in objs do
			if type(o) ~= "table" or type(o.id) ~= "string" then
				continue
			end
			local id = o.id
			seen[id] = true
			table.insert(objOrder, id)
			local existed = rows[id] ~= nil
			local row = rows[id] or makeRow(id)
			row.frame.LayoutOrder = i
			row.text.Text = tostring(o.text or id)
			local def = ObjectiveDefs[id]
			row.hint.Text = if def and type(def.hint) == "string" then def.hint else ""
			local done, active = o.done == true, o.active == true and o.done ~= true
			if existed and done == row.done and active == row.active then
				continue
			end
			paintRow(row, done, active, existed and done and not row.done)
			row.done, row.active = done, active
		end
	end
	for id, row in rows do
		if not seen[id] then
			row.frame:Destroy()
			rows[id] = nil
		end
	end
	objList.Visible = next(seen) ~= nil
end

-- Status cluster, bottom-left: O2 leads, the rest reads as one quiet line.
local status = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 28, 1, -28),
	Size = UDim2.fromOffset(300, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = hudGui,
}, { list(8) }))
local o2Row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 34), LayoutOrder = 1, Parent = status })
tag("O2", 12, { FontFace = MED, TextColor3 = C.dim, Position = UDim2.fromOffset(0, 14), Parent = o2Row })
local o2Val = tag("--", 32, { FontFace = LIGHT, TextColor3 = C.text, Position = UDim2.fromOffset(26, -2), Parent = o2Row })
local o2Pct = tag("%", 14, { FontFace = BODY, TextColor3 = C.dim, Parent = o2Row })
local o2Track = new("Frame", { Size = UDim2.new(0, 220, 0, 2), BackgroundColor3 = C.line, BackgroundTransparency = 0.85, BorderSizePixel = 0, LayoutOrder = 2, Parent = status }, { corner(1) })
local o2Fill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = o2Track }, { corner(1) })
local o2Hint = tag("", 12, { FontFace = BODY, TextColor3 = C.accent, LayoutOrder = 3, Visible = false, Parent = status })
local healthRow = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 4, Visible = false, Parent = status })
tag("HP", 12, { FontFace = MED, TextColor3 = C.dim, Position = UDim2.fromOffset(0, 2), Parent = healthRow })
local healthTrack = new("Frame", { Position = UDim2.fromOffset(26, 6), Size = UDim2.fromOffset(160, 3), BackgroundColor3 = C.line, BackgroundTransparency = 0.85, BorderSizePixel = 0, Parent = healthRow }, { corner(1) })
local healthFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = healthTrack }, { corner(1) })
local statRow = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 5, Parent = status }, { list(16, true) })
local statVals: { [string]: TextLabel } = {}
for i, spec in { { "Power", "PWR" }, { "HullIntegrity", "HULL" }, { "CrewSafety", "SAFE" }, { "RepairUnits", "RU" }, { "MissionTime", "T+" } } do
	local cell = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = i, Parent = statRow }, { list(5, true) })
	tag(spec[2], 12, { FontFace = MED, TextColor3 = C.faint, LayoutOrder = 1, Parent = cell })
	statVals[spec[1]] = tag("--", 13, { FontFace = MONO, TextColor3 = C.dim, LayoutOrder = 2, Parent = cell }) :: TextLabel
end

local function paintStation()
	local o = station.Oxygen
	if type(o) == "number" then
		o = math.clamp(o, 0, 100)
		o2Val.Text = tostring(math.floor(o + 0.5))
		o2Pct.Position = UDim2.fromOffset(26 + o2Val.TextBounds.X + 3, 12)
		o2Fill.Size = UDim2.fromScale(o / 100, 1)
		local crit = o < 30
		o2Val.TextColor3 = if crit then C.red else C.text
		o2Fill.BackgroundColor3 = if crit then C.red else C.text
	end
	for key, lbl in statVals do
		local v = station[key]
		if type(v) ~= "number" then
			continue
		end
		if key == "MissionTime" then
			local t = math.max(0, math.floor(v))
			lbl.Text = string.format("%02d:%02d", t // 60, t % 60)
		elseif key == "RepairUnits" then
			lbl.Text = string.format("%02d", math.floor(v))
			lbl.TextColor3 = if v <= 0 then C.red else C.dim
		else
			lbl.Text = tostring(math.floor(math.clamp(v, 0, 100) + 0.5))
			lbl.TextColor3 = if v < 30 then C.red elseif v < 50 then C.text else C.dim
		end
	end
end

do -- scoped: keeps top-level locals under Luau's 200-register limit
-- Damage vignette: 4 edge gradients, normally invisible, pulsed red on any AuroraHealth drop.
local vignette = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 0, Parent = hudGui })
local function edgePanel(anchor: Vector2, pos: UDim2, size: UDim2, rotation: number)
	return new("Frame", {
		AnchorPoint = anchor,
		Position = pos,
		Size = size,
		BackgroundColor3 = C.red,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = vignette,
	}, {
		new("UIGradient", { Rotation = rotation, Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }) }),
	})
end
local vignettePanels = {
	edgePanel(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.new(1, 0, 0.22, 0), 90),
	edgePanel(Vector2.new(0, 1), UDim2.fromScale(0, 1), UDim2.new(1, 0, 0.22, 0), -90),
	edgePanel(Vector2.new(0, 0), UDim2.fromScale(0, 0), UDim2.new(0.14, 0, 1, 0), 0),
	edgePanel(Vector2.new(1, 0), UDim2.fromScale(1, 0), UDim2.new(0.14, 0, 1, 0), 180),
}
local function pulseVignette()
	for _, p in vignettePanels do
		p.BackgroundTransparency = 0.4
		tween(p, { BackgroundTransparency = 1 }, 0.5)
	end
end

-- Health bar, status cluster: LocalPlayer attribute AuroraHealth (0-100, nil = 100).
local prevHealth: number? = nil
local function paintHealth()
	local hp = player:GetAttribute("AuroraHealth")
	local h = if type(hp) == "number" then math.clamp(hp, 0, 100) else 100
	healthRow.Visible = h < 100
	healthFill.Size = UDim2.fromScale(h / 100, 1)
	local crit = h < 30
	healthFill.BackgroundColor3 = if crit then C.red else C.text
	if prevHealth and h < prevHealth then
		pulseVignette()
	end
	prevHealth = h
end
player:GetAttributeChangedSignal("AuroraHealth"):Connect(paintHealth)
paintHealth()
end

do -- scoped: keeps top-level locals under Luau's 200-register limit
-- Torch + stamina, bottom-right.
local gear = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -28, 1, -28),
	Size = UDim2.fromOffset(180, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = hudGui,
}, { list(10, false, Enum.HorizontalAlignment.Right) }))
local torchRow = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 2, Parent = gear }, { list(8, true) })
-- torch glyph: lamp head + body, two rounded blocks (reads at 12px, no icon asset needed)
local torchIcon = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 10), LayoutOrder = 1, Parent = torchRow })
local torchHead = new("Frame", { Position = UDim2.fromOffset(12, 0), Size = UDim2.fromOffset(6, 10), BackgroundColor3 = C.dim, BorderSizePixel = 0, Parent = torchIcon }, { corner(2) })
local torchBody = new("Frame", { Position = UDim2.fromOffset(0, 3), Size = UDim2.fromOffset(12, 4), BackgroundColor3 = C.dim, BorderSizePixel = 0, Parent = torchIcon }, { corner(2) })
local torchLabel = tag("TORCH", 12, { FontFace = MED, TextColor3 = C.faint, LayoutOrder = 2, Parent = torchRow })
-- Death counter: subtle, hidden until the first death (player attribute AuroraDeaths, persisted server-side).
local deathsLabel = tag("", 12, { FontFace = MED, TextColor3 = C.faint, LayoutOrder = 3, Parent = gear })
local function paintDeaths()
	local n = tonumber(player:GetAttribute("AuroraDeaths")) or 0
	deathsLabel.Text = "DEATHS " .. n
	deathsLabel.Visible = n > 0
end
player:GetAttributeChangedSignal("AuroraDeaths"):Connect(paintDeaths)
paintDeaths()
local battTrack = new("Frame", { Size = UDim2.fromOffset(56, 4), BackgroundColor3 = C.line, BackgroundTransparency = 0.85, BorderSizePixel = 0, LayoutOrder = 3, Parent = torchRow }, { corner(2) })
local battFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.dim, BorderSizePixel = 0, Parent = battTrack }, { corner(2) })
local staminaRow = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 1, Visible = false, Parent = gear }, { list(8, true) })
tag("STAMINA", 12, { FontFace = MED, TextColor3 = C.faint, LayoutOrder = 1, Parent = staminaRow })
local stamTrack = new("Frame", { Size = UDim2.fromOffset(82, 4), BackgroundColor3 = C.line, BackgroundTransparency = 0.85, BorderSizePixel = 0, LayoutOrder = 2, Parent = staminaRow }, { corner(2) })
local stamFill = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = stamTrack }, { corner(2) })

local function paintGear()
	local on = player:GetAttribute("TorchOn") == true
	local batt = player:GetAttribute("TorchBattery")
	local b = if type(batt) == "number" then math.clamp(if batt > 1 then batt / 100 else batt, 0, 1) else 1
	local col = if on then C.accent else C.dim
	torchHead.BackgroundColor3, torchBody.BackgroundColor3 = col, col
	torchLabel.TextColor3 = if on then C.text else C.faint
	battFill.Size = UDim2.fromScale(b, 1)
	battFill.BackgroundColor3 = if b < 0.2 then C.red elseif on then C.accent else C.dim
	local s = player:GetAttribute("Stamina")
	local st = if type(s) == "number" then math.clamp(if s > 1 then s / 100 else s, 0, 1) else 1
	staminaRow.Visible = st < 0.999
	stamFill.Size = UDim2.fromScale(st, 1)
end
for _, a in { "TorchOn", "TorchBattery", "Stamina" } do
	player:GetAttributeChangedSignal(a):Connect(paintGear)
end
paintGear()

end

----------------------------------------------------------------------------
-- Waypoints (DisplayOrder 9, under the tracker)
----------------------------------------------------------------------------
local wpGui = screen("Waypoints", 9, true)
do -- scoped: keeps top-level locals under Luau's 200-register limit
local markers: { [string]: { root: Frame, pin: Frame, arrow: Frame, text: TextLabel, dist: TextLabel } } = {}

local function worldPos(inst: Instance?): Vector3?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

local function promptFor(id: string): ProximityPrompt?
	for _, p in CollectionService:GetTagged("AuroraPrompt") do
		if p:IsA("ProximityPrompt") and p:GetAttribute("ObjectiveId") == id and p:IsDescendantOf(workspace) then
			return p
		end
	end
	return nil
end

local function targetFor(id: string): Vector3?
	local p = promptFor(id)
	if p then
		return worldPos(p.Parent)
	end
	local def = ObjectiveDefs[id]
	if not def or type(def.tag) ~= "string" then
		return nil
	end
	local fallback: Instance? = nil
	for _, inst in CollectionService:GetTagged(def.tag) do
		if not inst:IsDescendantOf(workspace) then
			continue
		end
		fallback = fallback or inst
		if type(def.part) == "string" then
			if inst.Name == def.part then
				return worldPos(inst)
			end
			local sub = inst:FindFirstChild(def.part, true)
			if sub then
				return worldPos(sub)
			end
		end
	end
	return worldPos(fallback)
end

local function marker(id: string)
	local m = markers[id]
	if m then
		return m
	end
	local root = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(160, 64), BackgroundTransparency = 1, Parent = wpGui }) :: Frame
	local pin = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		Rotation = 45,
		BackgroundColor3 = C.accent,
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
		Parent = root,
	}, { corner(2) }) :: Frame
	-- off-screen arrow: rotated container holding a short tick that points toward the target
	local arrow = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(44, 44), BackgroundTransparency = 1, Visible = false, Parent = root }) :: Frame
	new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -4, 0.5, 0), Size = UDim2.fromOffset(8, 8), Rotation = 45, BackgroundTransparency = 1, Parent = arrow }, {
		new("Frame", { Size = UDim2.new(1, 0, 0, 2), BackgroundColor3 = C.accent, BorderSizePixel = 0 }),
		new("Frame", { Position = UDim2.new(1, -2, 0, 0), Size = UDim2.new(0, 2, 1, 0), BackgroundColor3 = C.accent, BorderSizePixel = 0 }),
	})
	local text = tag("", 12, {
		FontFace = MED,
		TextColor3 = C.text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 12),
		TextStrokeTransparency = 0.7,
		Parent = root,
	}) :: TextLabel
	local dist = tag("", 12, {
		FontFace = MONO,
		TextColor3 = C.dim,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, 28),
		TextStrokeTransparency = 0.7,
		Parent = root,
	}) :: TextLabel
	m = { root = root, pin = pin, arrow = arrow, text = text, dist = dist }
	markers[id] = m
	return m
end

local function minigameOpen(): boolean
	local mg = playerGui:FindFirstChild("MinigameGui")
	if not (mg and mg:IsA("ScreenGui") and mg.Enabled) then
		return false
	end
	for _, c in mg:GetChildren() do
		if c:IsA("Frame") and c.Visible then
			return true
		end
	end
	return false
end

local lastDistAt = 0
RunService.RenderStepped:Connect(function()
	local cam = workspace.CurrentCamera
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local show = hudGui.Enabled and not paused and not cinematic and PROMPT_STATES[curState] == true and not minigameOpen()
	wpGui.Enabled = show
	-- O2 < 30 pulses (only while the HUD is up)
	local o = station.Oxygen
	if hudGui.Enabled and type(o) == "number" and o < 30 then
		local a = 0.5 + 0.5 * math.sin(os.clock() * 6)
		o2Val.TextTransparency = 0.35 * a
		o2Fill.BackgroundTransparency = 0.5 * a
	elseif o2Val.TextTransparency ~= 0 then
		o2Val.TextTransparency, o2Fill.BackgroundTransparency = 0, 0
	end
	-- O2 refill hint: point to the nearest O2Refill station once O2 drops under 30
	if hudGui.Enabled and type(o) == "number" and o < 30 and root then
		local bestPart, bestD = nil, math.huge
		for _, inst in CollectionService:GetTagged("O2Refill") do
			if not inst:IsDescendantOf(workspace) then
				continue
			end
			local part = (inst:IsA("Model") and inst.PrimaryPart) or inst:FindFirstChild("RefillPanel", true)
			if part and part:IsA("BasePart") then
				local d = (part.Position - root.Position).Magnitude
				if d < bestD then
					bestPart, bestD = part, d
				end
			end
		end
		if bestPart then
			o2Hint.Visible = true
			o2Hint.Text = string.format("\xE2\x86\x92 O2 STATION %d m", math.floor(bestD + 0.5))
		else
			o2Hint.Visible = false
		end
	else
		o2Hint.Visible = false
	end
	local updDist = os.clock() - lastDistAt > 0.2
	if updDist then
		lastDistAt = os.clock()
	end
	local live = {}
	if cam and root and (show or (hudGui.Enabled and updDist)) then
		local vp = cam.ViewportSize
		for id in activeIds do
			local pos = targetFor(id)
			local row = rows[id]
			if not pos then
				if row then
					row.dist.Text = ""
				end
				continue
			end
			local d = (pos - root.Position).Magnitude
			local dText = string.format("%d m", math.floor(d + 0.5))
			if row and updDist then
				row.dist.Text = dText
			end
			if not show then
				continue
			end
			live[id] = true
			local m = marker(id)
			m.root.Visible = true
			local sp, onScreen = cam:WorldToViewportPoint(pos + Vector3.new(0, 1.5, 0))
			local def = ObjectiveDefs[id]
			m.text.Text = string.upper(if def and type(def.object) == "string" and def.object ~= "" then def.object elseif row then row.text.Text else id)
			m.dist.Text = dText
			local near = d < 6
			local inset = 56
			if onScreen and sp.Z > 0 and sp.X > inset and sp.X < vp.X - inset and sp.Y > inset and sp.Y < vp.Y - inset then
				m.root.Position = UDim2.fromOffset(sp.X, sp.Y)
				m.arrow.Visible = false
				m.pin.Visible = true
				m.text.Visible = not near
				m.dist.Visible = not near
				m.pin.BackgroundTransparency = if near then 0.7 else 0.1
			else
				local c = vp / 2
				local dir = Vector2.new(sp.X, sp.Y) - c
				if sp.Z < 0 then
					dir = -dir
				end
				if dir.Magnitude < 1 then
					dir = Vector2.new(0, 1)
				end
				local half = c - Vector2.new(inset, inset)
				local s = math.min(half.X / math.max(math.abs(dir.X), 1e-3), half.Y / math.max(math.abs(dir.Y), 1e-3))
				local p = c + dir * s
				m.root.Position = UDim2.fromOffset(p.X, p.Y)
				m.arrow.Visible = true
				m.arrow.Rotation = math.deg(math.atan2(dir.Y, dir.X))
				m.pin.Visible = true
				m.pin.BackgroundTransparency = 0.1
				m.text.Visible = true
				m.dist.Visible = true
			end
		end
	end
	for id, m in markers do
		if not live[id] then
			m.root.Visible = false
		end
	end
end)

end

----------------------------------------------------------------------------
-- Custom proximity prompts (one BillboardGui per shown prompt)
----------------------------------------------------------------------------
local promptFolder = playerGui:FindFirstChild("AuroraPrompts") or new("Folder", { Name = "AuroraPrompts", Parent = playerGui })
promptFolder:ClearAllChildren()

local function customize(p: Instance)
	if p:IsA("ProximityPrompt") then
		p.Style = Enum.ProximityPromptStyle.Custom
	end
end
for _, d in workspace:GetDescendants() do
	customize(d)
end
workspace.DescendantAdded:Connect(customize)

local function promptKey(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string?
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		return PAD_NAMES[prompt.GamepadKeyCode.Name] or prompt.GamepadKeyCode.Name
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		return nil
	end
	local n = prompt.KeyboardKeyCode.Name
	return if n == "Return" then "Enter" else n
end

ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		return
	end
	local adornee = prompt.Parent
	if not (adornee and (adornee:IsA("BasePart") or adornee:IsA("Attachment") or adornee:IsA("Model"))) then
		return
	end
	local bb = new("BillboardGui", {
		Name = "Prompt",
		Adornee = adornee,
		AlwaysOnTop = true,
		Size = UDim2.fromOffset(320, 60),
		SizeOffset = Vector2.new(0.5, 0), -- sits to the right of the object; keycap is the anchor
		StudsOffset = Vector3.new(0, prompt.UIOffset.Y / 40, 0),
		ResetOnSpawn = false,
		Active = true,
		Enabled = not cinematic,
		Parent = promptFolder,
	}) :: BillboardGui
	local g = new("CanvasGroup", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, GroupTransparency = 1, Parent = bb }) :: CanvasGroup
	local key = promptKey(prompt, inputType)
	local cap = new("TextButton", {
		Text = key or "",
		FontFace = MED,
		TextSize = 16,
		TextColor3 = C.text,
		AutoButtonColor = false,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.05,
		Position = UDim2.fromOffset(0, 9),
		Size = UDim2.fromOffset(42, 42),
		ClipsDescendants = true,
		Parent = g,
	}, { corner(), stroke(C.line, 0.6) }) :: TextButton
	if not key then -- touch: a filled disc reads as "tap here"
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(12, 12), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = cap }, { corner(6) })
	end
	local holdFill = new("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0),
		BackgroundColor3 = C.accent,
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		ZIndex = 0,
		Parent = cap,
	})
	local textCol = new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(54, 0),
		Size = UDim2.new(1, -54, 1, 0),
		Parent = g,
	}, { list(2) })
	;(textCol:FindFirstChildOfClass("UIListLayout") :: UIListLayout).VerticalAlignment = Enum.VerticalAlignment.Center
	if prompt.ObjectText ~= "" then
		tag(string.upper(prompt.ObjectText), 12, { FontFace = MED, TextColor3 = C.dim, TextStrokeTransparency = 0.8, LayoutOrder = 1, Parent = textCol })
	end
	local verb = if prompt.HoldDuration > 0 and key then "Hold  " .. prompt.ActionText else prompt.ActionText
	tag(verb, 18, { FontFace = MED, TextColor3 = C.text, TextStrokeTransparency = 0.8, LayoutOrder = 2, Parent = textCol })

	local conns = {}
	local holdTween: Tween? = nil
	table.insert(conns, prompt.PromptButtonHoldBegan:Connect(function()
		holdFill.Size = UDim2.fromScale(1, 0)
		holdTween = TweenService:Create(holdFill, TweenInfo.new(prompt.HoldDuration, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, 1) })
		;(holdTween :: Tween):Play()
	end))
	table.insert(conns, prompt.PromptButtonHoldEnded:Connect(function()
		if holdTween then
			holdTween:Cancel()
		end
		tween(holdFill, { Size = UDim2.fromScale(1, 0) }, 0.2)
	end))
	table.insert(conns, prompt.Triggered:Connect(function()
		holdFill.Size = UDim2.fromScale(1, 1)
		holdFill.BackgroundTransparency = 0.2
		tween(holdFill, { BackgroundTransparency = 0.55, Size = UDim2.fromScale(1, 0) }, 0.4)
	end))
	-- touch / click: drive the prompt directly
	table.insert(conns, cap.InputBegan:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			prompt:InputHoldBegin()
		end
	end))
	table.insert(conns, cap.InputEnded:Connect(function(input)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			prompt:InputHoldEnd()
		end
	end))
	tween(g, { GroupTransparency = 0 }, 0.25)

	local hidden
	hidden = prompt.PromptHidden:Connect(function()
		hidden:Disconnect()
		for _, c in conns do
			c:Disconnect()
		end
		tween(g, { GroupTransparency = 1 }, 0.2).Completed:Connect(function()
			bb:Destroy()
		end)
	end)
end)

----------------------------------------------------------------------------
-- Main menu + settings (DisplayOrder 100)
----------------------------------------------------------------------------
local menuGui = screen("MainMenu", 100)
local menuShade = backdrop(menuGui, 0)
menuShade.Active = false
new("UIGradient", {
	Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(0.5, 0.55),
		NumberSequenceKeypoint.new(1, 0.85),
	}),
	Parent = menuShade,
})
local menuCol = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 1),
	Position = UDim2.new(0, 88, 1, -96),
	Size = UDim2.fromOffset(520, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = menuGui,
}, { list(0) }))
local menuItems: { GuiObject } = {}
local function menuItem(obj: GuiObject, order: number, gapBelow: number?)
	obj.LayoutOrder = order
	obj.Parent = menuCol
	table.insert(menuItems, obj)
	if gapBelow then
		new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, gapBelow), LayoutOrder = order + 1, Parent = menuCol })
	end
	return obj
end
local function staggerIn(items: { GuiObject }, dy: number?)
	for i, o in items do
		local tl = if o:IsA("TextLabel") then o else o:FindFirstChild("Label") :: TextLabel?
		if tl then
			local target = if o:IsA("TextButton") then (if o:GetAttribute("Disabled") then 0.7 else 0.25) else 0
			tl.TextTransparency = 1
			local p0 = tl:GetAttribute("P0") or tl.Position
			tl:SetAttribute("P0", p0)
			tl.Position = p0 + UDim2.fromOffset(0, dy or 8)
			task.delay(0.15 + i * 0.07, function()
				tween(tl, { TextTransparency = target, Position = p0 }, 0.7)
			end)
		end
	end
end

-- Nav glue: every menu/pause/settings control goes through bind() so keyboard Enter and the
-- arrow-key walker (end of the Pause section) can drive it; debounced against double fire.
navFns, stepFns = {}, {}
-- hand focus back after closing an overlay: keyboard users mid-navigation keep a visible selection
function refocus(target: GuiObject?)
	if target and GuiService.SelectedObject and not isGamepad() then
		GuiService.SelectedObject = target
	else
		focus(target)
	end
end
function bind(b: GuiButton, fn: () -> ())
	local last = 0
	local function run()
		if b:GetAttribute("Disabled") or os.clock() - last < 0.25 then
			return
		end
		last = os.clock()
		fn()
	end
	navFns[b] = run
	b.Activated:Connect(run)
end

-- Confirm dialog (own ScreenGui, DisplayOrder 110: above menu and pause). Default focus = Cancel.
do
	confirmGui = screen("AuroraConfirm", 110)
	local shade = backdrop(confirmGui, 0.35)
	confirmBox = scaled(new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(460, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.02,
		Parent = shade,
	}, { corner(), stroke(C.line, 0.84), pad(28, 32), list(10) }))
	new("Frame", { Size = UDim2.fromOffset(28, 2), BackgroundColor3 = C.accent, BorderSizePixel = 0, LayoutOrder = 0, Parent = confirmBox })
	local cTitle = tag("", 20, { FontFace = BODY, TextColor3 = C.text, LayoutOrder = 1, Parent = confirmBox })
	local cBody = label({ TextSize = 14, TextColor3 = C.dim, LayoutOrder = 2, Parent = confirmBox })
	new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 14), LayoutOrder = 3, Parent = confirmBox })
	local row = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 4, Parent = confirmBox }, { list(32, true) })
	local yes = textButton("Confirm", 18, { LayoutOrder = 1, Parent = row })
	local no = textButton("Cancel", 18, { LayoutOrder = 2, Parent = row })
	local onYes, back
	function confirmClose()
		if not confirmGui.Enabled then
			return
		end
		confirmGui.Enabled = false
		refocus(back)
	end
	function confirmAsk(title: string, body: string, yesText: string, fn: () -> (), returnTo: GuiObject?)
		cTitle.Text, cBody.Text = title, body
		;(yes:FindFirstChild("Label") :: TextLabel).Text = yesText
		onYes, back = fn, returnTo
		confirmGui.Enabled = true
		shade.BackgroundTransparency = 1
		tween(shade, { BackgroundTransparency = 0.35 }, 0.3)
		confirmBox.Position = UDim2.new(0.5, 0, 0.5, 12)
		tween(confirmBox, { Position = UDim2.fromScale(0.5, 0.5) }, 0.45)
		if inputMode() ~= "touch" then
			GuiService.SelectedObject = no -- safe default for Enter / A
		end
	end
	bind(yes, function()
		local f = onYes
		back = nil
		confirmClose()
		if f then
			f()
		end
	end)
	bind(no, confirmClose)
end

-- Wordmark: tracked display caps. A cyan ghost slips a few px on a slow irregular cadence and a
-- scanline sweeps it after each slip: the "weak signal" motif, rare enough to stay calm.
menuItem(tag(track("Deep-field relay  ·  Sector 7", " "), 12, { FontFace = MED, TextColor3 = C.accent }), 0, 18)
local wordmark = menuItem(tag(track("Station Aurora", " "), 52, { FontFace = LIGHT, TextColor3 = C.text }), 1, 14)
menuItem(tag("Keep the station breathing.", 16, { FontFace = BODY, TextColor3 = C.dim }), 3, 52)
local btnStart = textButton("New mission", 22)
local btnContinue = textButton("Continue", 22)
local btnSettings = textButton("Settings", 22)
local btnCredits = textButton("Credits", 22)
menuItem(btnStart, 10, 4)
menuItem(btnContinue, 12, 4)
menuItem(btnSettings, 14, 4)
menuItem(btnCredits, 16)
do
	local ghost = tag(wordmark.Text, 52, { FontFace = LIGHT, TextColor3 = C.accent, TextTransparency = 1, Parent = wordmark })
	local scan = new("Frame", { Size = UDim2.new(1, 0, 0, 1), BackgroundColor3 = C.accent, BackgroundTransparency = 1, BorderSizePixel = 0, Parent = wordmark })
	task.spawn(function()
		while true do
			task.wait(3.5 + math.random() * 4.5)
			if menuGui.Enabled then
				for _ = 1, math.random(2, 4) do
					ghost.Position = UDim2.fromOffset(math.random(-5, 5), math.random(-1, 1))
					ghost.TextTransparency = 0.5
					wordmark.TextTransparency = 0.15
					task.wait(0.04 + math.random() * 0.05)
				end
				ghost.TextTransparency, ghost.Position, wordmark.TextTransparency = 1, UDim2.new(), 0
				scan.Position, scan.BackgroundTransparency = UDim2.new(), 0.45
				tween(scan, { Position = UDim2.fromScale(0, 1), BackgroundTransparency = 1 }, 0.9, Enum.EasingStyle.Sine)
			end
		end
	end)
end

-- Mission status card, bottom-right. CanvasGroup so the whole card can fade in as one.
do
	local card = new("CanvasGroup", {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -88, 1, -96),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = menuGui,
	}, { pad(1) })
	scaled(card)
	local inner = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.3,
		Parent = card,
	}, { corner(), stroke(C.line, 0.88), pad(20, 22), list(12) })
	tag(track("Mission status", " "), 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 1, Parent = inner })
	hair(inner, { LayoutOrder = 2 })
	local function row(name: string, order: number, x: number?)
		local r = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 18), LayoutOrder = order, Parent = inner })
		tag(name, 14, { FontFace = BODY, TextColor3 = C.dim, Position = UDim2.fromOffset(x or 0, 0), Parent = r })
		return tag("", 14, { FontFace = MED, TextColor3 = C.text, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Parent = r }), r
	end
	local day = row("Mission day", 3)
	local op = row("Operator", 4)
	local crew, crewRow = row("Crew", 5, 14)
	crew.TextColor3 = C.accent
	local dot = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.fromOffset(6, 6), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = crewRow }, { corner(3) })
	TweenService:Create(dot, TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.85 }):Play()
	crew.Text = "1 / 6 AWAKE"
	menuStatus = { card = card, day = day, op = op, crew = crew }
end

-- Credits: full-screen overlay inside the menu.
do
	creditsFrame = backdrop(menuGui, 0.03)
	creditsFrame.Visible, creditsFrame.ZIndex = false, 5
	local col = scaled(new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = creditsFrame,
	}, { list(10, false, Enum.HorizontalAlignment.Center) }))
	local items = {}
	local function add(o: GuiObject)
		o.LayoutOrder = #items + 1
		o.Parent = col
		table.insert(items, o)
		return o
	end
	local function gap(h: number)
		new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, h), LayoutOrder = #items + 1, Parent = col })
	end
	add(tag(track("Credits", " "), 12, { FontFace = MED, TextColor3 = C.accent }))
	add(tag(track("Station Aurora", " "), 32, { FontFace = LIGHT, TextColor3 = C.text }))
	gap(6)
	add(tag("A Uideas production", 20, { FontFace = BODY, TextColor3 = C.text }))
	gap(18)
	add(tag("Direction, design and code  —  Uideas", 14, { FontFace = BODY, TextColor3 = C.dim }))
	add(tag("Sound, light and station systems  —  Uideas", 14, { FontFace = BODY, TextColor3 = C.dim }))
	add(tag("Built in Roblox Studio", 14, { FontFace = BODY, TextColor3 = C.dim }))
	gap(18)
	add(tag("Thanks for keeping the lights on.", 14, { FontFace = BODY, TextColor3 = C.faint }))
	gap(28)
	local back = add(textButton("Back", 18))
	function openCredits(v: boolean, silent: boolean?)
		creditsFrame.Visible = v
		if v then
			creditsFrame.BackgroundTransparency = 1
			tween(creditsFrame, { BackgroundTransparency = 0.03 }, 0.5)
			staggerIn(items, 6)
			if inputMode() ~= "touch" then
				GuiService.SelectedObject = back -- Enter / A closes it straight away
			end
		elseif not silent then
			refocus(btnCredits)
		end
	end
	bind(back, function()
		openCredits(false)
	end)
end

local sheet, nameBox, speedBtns, openSettings, applyLocalPrefs, paintSettings
local settingsOpen, savedVolume, menuBusy = false, 1, false
do -- scoped: keeps top-level locals under Luau's 200-register limit
-- Session prefs beyond what the server stores (mirrored to LocalPlayer attributes for other scripts).
prefs = { music = 1, sfx = 1, fov = 70, sens = 1, shake = true }
local function mixGroups(music: number, sfxV: number)
	for _, g in (master :: Instance):GetDescendants() do
		if g:IsA("SoundGroup") then
			local v = if g.Name == "Music" then music elseif g.Name == "SFX" or g.Name == "Ambient" then sfxV else nil
			if v then
				local base = g:GetAttribute("AuroraBase")
				if type(base) ~= "number" then
					base = g.Volume
					g:SetAttribute("AuroraBase", base)
				end
				g.Volume = base * v
			end
		end
	end
end
function applyFov(v: number?)
	local cam = workspace.CurrentCamera
	if cam and not cinematic and (HUD_STATES[curState] or paused) then
		cam.FieldOfView = v or prefs.fov
	end
end
function applyPrefs(pr: { [string]: any })
	for k, v in pr do
		prefs[k] = v
	end
	for _, root in { workspace, SoundService, ReplicatedStorage, playerGui } do
		for _, d in root:GetDescendants() do
			adopt(d) -- re-route into buses that may have been built after we first saw the sound
		end
	end
	mixGroups(prefs.music, prefs.sfx)
	UserInputService.MouseDeltaSensitivity = prefs.sens
	player:SetAttribute("AuroraNoShake", not prefs.shake)
	player:SetAttribute("AuroraFOV", prefs.fov)
	player:SetAttribute("AuroraMusic", prefs.music)
	player:SetAttribute("AuroraSFX", prefs.sfx)
	player:SetAttribute("AuroraSens", prefs.sens)
	applyFov()
end

-- Settings: side sheet sliding in from the right (menu and pause share it; it re-parents).
sheet = new("Frame", {
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, 440, 0, 0),
	Size = UDim2.new(0, 440, 1, 0),
	BackgroundColor3 = C.bg,
	BackgroundTransparency = 0,
	BorderSizePixel = 0,
	Visible = false,
	Active = true,
	ZIndex = 6,
	Parent = menuGui,
})
hair(sheet, { Size = UDim2.new(0, 1, 1, 0) })
local sheetBody = (new("ScrollingFrame", {
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Position = UDim2.fromOffset(40, 56),
	Size = UDim2.new(1, -56, 1, -80),
	CanvasSize = UDim2.new(),
	AutomaticCanvasSize = Enum.AutomaticSize.Y,
	ScrollBarThickness = 2,
	ScrollBarImageColor3 = C.accent,
	ScrollingDirection = Enum.ScrollingDirection.Y,
	Selectable = false,
	Parent = sheet,
}, { list(8), new("UIPadding", { PaddingRight = UDim.new(0, 20), PaddingBottom = UDim.new(0, 24) }) }))
local function field(name: string, order: number)
	new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 12), LayoutOrder = order, Parent = sheetBody })
	tag(track(name, " "), 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = order + 1, Parent = sheetBody })
end
tag("Settings", 32, { FontFace = LIGHT, TextColor3 = C.text, LayoutOrder = 1, Parent = sheetBody })
tag("Changes preview live. Save to keep them.", 12, { FontFace = BODY, TextColor3 = C.faint, LayoutOrder = 2, Parent = sheetBody })

field("Operator", 10)
nameBox = new("TextBox", {
	Text = "Sam Ortega",
	PlaceholderText = "Sam Ortega",
	ClearTextOnFocus = false,
	FontFace = BODY,
	TextSize = 18,
	TextColor3 = C.text,
	PlaceholderColor3 = C.faint,
	TextXAlignment = Enum.TextXAlignment.Left,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 44),
	LayoutOrder = 12,
	Parent = sheetBody,
}) :: TextBox
local nameLine = hair(nameBox, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), BackgroundTransparency = 0.75 })
nameBox.Focused:Connect(function()
	nameLine.BackgroundColor3, nameLine.BackgroundTransparency = C.accent, 0
end)
nameBox.FocusLost:Connect(function()
	nameLine.BackgroundColor3, nameLine.BackgroundTransparency = C.line, 0.75
end)
nameBox:GetPropertyChangedSignal("Text"):Connect(function()
	if #nameBox.Text > 24 then
		nameBox.Text = string.sub(nameBox.Text, 1, 24)
	end
end)

local P = { volume = 1, music = 1, sfx = 1, fov = 70, sens = 1, subs = true, shake = true, speed = 1, autosave = true }
local sliders, segs = {}, {}
local drag -- { set, track }
local function slider(key: string, title: string, order: number, lo: number, hi: number, step: number, fmt: (number) -> string, live: ((number) -> ())?)
	field(title, order)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order + 2, Parent = sheetBody })
	local down = boxButton("-", { Size = UDim2.fromOffset(44, 44), Parent = row })
	local up = boxButton("+", { Size = UDim2.fromOffset(44, 44), AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Parent = row })
	local trk = new("TextButton", { Text = "", AutoButtonColor = false, Selectable = false, Position = UDim2.new(0, 58, 0.5, -14), Size = UDim2.new(1, -178, 0, 28), BackgroundTransparency = 1, Parent = row })
	local line = hair(trk, { Position = UDim2.new(0, 0, 0.5, -1), Size = UDim2.new(1, 0, 0, 2), BackgroundTransparency = 0.8 })
	local fill = new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = line })
	local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(10, 10), BackgroundColor3 = C.accent, BorderSizePixel = 0, Parent = line }, { corner(5) })
	local txt = tag("", 14, { FontFace = MONO, TextColor3 = C.text, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -56, 0.5, 0), Parent = row })
	local s = {}
	function s.paint()
		local a = (P[key] - lo) / (hi - lo)
		fill.Size = UDim2.fromScale(a, 1)
		knob.Position = UDim2.fromScale(a, 0.5)
		txt.Text = fmt(P[key])
	end
	function s.set(v: number)
		P[key] = math.clamp(lo + math.floor((v - lo) / step + 0.5) * step, lo, hi)
		s.paint()
		if live then
			live(P[key])
		end
	end
	bind(down, function()
		s.set(P[key] - step)
	end)
	bind(up, function()
		s.set(P[key] + step)
	end)
	local function nudge(d: number)
		s.set(P[key] + d * step)
	end
	stepFns[down], stepFns[up] = nudge, nudge
	trk.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			drag = { s, trk, lo, hi }
			s.set(lo + (input.Position.X - trk.AbsolutePosition.X) / math.max(trk.AbsoluteSize.X, 1) * (hi - lo))
		end
	end)
	sliders[key] = s
end
local function pct(v: number)
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end
slider("volume", "Master volume", 20, 0, 1, 0.1, pct, applyVolume)
slider("music", "Music", 30, 0, 1, 0.1, pct, function(v)
	mixGroups(v, P.sfx)
end)
slider("sfx", "Effects", 40, 0, 1, 0.1, pct, function(v)
	mixGroups(P.music, v)
end)
slider("fov", "Field of view", 50, 60, 90, 1, function(v)
	return string.format("%d°", v)
end, applyFov)
slider("sens", "Mouse sensitivity", 60, 0.2, 2, 0.1, function(v)
	return string.format("%.1fx", v)
end)
UserInputService.InputChanged:Connect(function(input)
	if drag and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
		local s, trk, lo, hi = drag[1], drag[2], drag[3], drag[4]
		s.set(lo + (input.Position.X - trk.AbsolutePosition.X) / math.max(trk.AbsoluteSize.X, 1) * (hi - lo))
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
		drag = nil
	end
end)

local function seg(title: string, order: number, key: string, opts: { { any } })
	field(title, order)
	local row = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 44), LayoutOrder = order + 2, Parent = sheetBody }, { list(8, true) })
	local btns = {}
	for i, o in opts do
		local b = boxButton(o[1], { Size = UDim2.fromOffset(92, 44), LayoutOrder = i, Parent = row })
		btns[o[2]] = b
		bind(b, function()
			P[key] = o[2]
			paintSettings()
		end)
	end
	segs[key] = btns
end
seg("Subtitles", 70, "subs", { { "On", true }, { "Off", false } })
seg("Camera shake", 80, "shake", { { "On", true }, { "Off", false } })
seg("Autosave checkpoints", 85, "autosave", { { "On", true }, { "Off", false } })
seg("Text speed", 90, "speed", { { "Slow", 0.6 }, { "Normal", 1 }, { "Fast", 1.6 } })
speedBtns = segs.speed

new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 28), LayoutOrder = 100, Parent = sheetBody })
local sheetActions = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 101, Parent = sheetBody }, { list(32, true) })
local btnSave = textButton("Save", 18, { LayoutOrder = 1, Parent = sheetActions })
local btnBack = textButton("Cancel", 18, { LayoutOrder = 2, Parent = sheetActions })

function paintSettings()
	for _, s in sliders do
		s.paint()
	end
	for key, btns in segs do
		for v, b in btns do
			b:SetAttribute("On", P[key] == v)
		end
	end
end

local returnTo: GuiObject? = nil
function openSettings(open: boolean, fromPause: boolean?, from: GuiObject?)
	settingsOpen = open
	if open then
		returnTo = from or btnSettings
		sheet.Parent = if fromPause then playerGui:FindFirstChild("PauseMenu") or menuGui else menuGui
		P.volume, P.subs, P.speed = volume, subtitlesOn, textSpeed
		P.music, P.sfx, P.fov, P.sens, P.shake = prefs.music, prefs.sfx, prefs.fov, prefs.sens, prefs.shake
		paintSettings()
		sheet.Visible = true
		sheetBody.CanvasPosition = Vector2.zero
		tween(sheet, { Position = UDim2.new(1, 0, 0, 0) }, 0.5)
		focus(btnSave)
	else
		drag = nil
		tween(sheet, { Position = UDim2.new(1, 440, 0, 0) }, 0.4).Completed:Connect(function()
			if not settingsOpen then
				sheet.Visible = false
			end
		end)
		refocus(returnTo)
	end
end
function settingsCancel()
	applyVolume(savedVolume) -- discard unsaved previews
	mixGroups(prefs.music, prefs.sfx)
	applyFov()
	openSettings(false)
end

local function startNew()
	menuBusy = true
	send("Start")
end
bind(btnStart, function()
	if menuBusy then
		return
	end
	if menuHasSave then
		confirmAsk(
			"Start a new mission?",
			"Your saved mission" .. (if menuSaveDay then " (Day " .. menuSaveDay .. ")" else "") .. " will be overwritten. This can't be undone.",
			"Overwrite",
			startNew,
			btnStart
		)
	else
		startNew()
	end
end)
bind(btnContinue, function()
	if not menuBusy then
		menuBusy = true
		send("Continue")
	end
end)
bind(btnSettings, function()
	if settingsOpen then
		settingsCancel()
	else
		openSettings(true, false, btnSettings)
	end
end)
bind(btnCredits, function()
	openCredits(true)
end)

function applyLocalPrefs(subs: boolean, speed: number)
	subtitlesOn, textSpeed = subs, speed
	player:SetAttribute("AuroraSubtitles", subs) -- other client scripts can read it
end
bind(btnSave, function()
	local name = string.match(nameBox.Text, "^%s*(.-)%s*$") or ""
	if name == "" then
		name = "Sam Ortega"
		nameBox.Text = name
	end
	applyVolume(P.volume)
	savedVolume = volume
	applyLocalPrefs(P.subs, P.speed)
	applyPrefs({ music = P.music, sfx = P.sfx, fov = P.fov, sens = P.sens, shake = P.shake })
	player:SetAttribute("AuroraOperator", name)
	menuStatus.op.Text = name
	send("SaveSettings", {
		operatorName = name,
		volume = volume,
		music = P.music,
		sfx = P.sfx,
		fov = P.fov,
		sens = P.sens,
		subs = P.subs,
		shake = P.shake,
		autosave = P.autosave,
		subtitles = subtitlesOn, -- legacy keys, kept for the current server
		textSpeed = textSpeed,
	})
	toast("Settings saved")
	openSettings(false)
end)
bind(btnBack, settingsCancel)

end

----------------------------------------------------------------------------
-- Narrative: Intro / Ending / Restart (DisplayOrder 100)
----------------------------------------------------------------------------
local narrGui = screen("Narrative", 100)
local narrShade = backdrop(narrGui, 0)
local narrText = scaled(label({
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.new(0.6, 0, 0, 0),
	TextXAlignment = Enum.TextXAlignment.Center,
	FontFace = LIGHT,
	TextSize = 26,
	TextTransparency = 1,
	Parent = narrGui,
})) :: TextLabel
local narrEnding = scaled(new("CanvasGroup", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(800, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	GroupTransparency = 1,
	Parent = narrGui,
}, { list(14, false, Enum.HorizontalAlignment.Center) })) :: CanvasGroup
tag(track("Ending"), 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 1, Parent = narrEnding })
local narrEndTitle = tag("", 44, { FontFace = LIGHT, TextColor3 = C.text, LayoutOrder = 2, Parent = narrEnding })
new("Frame", { Size = UDim2.fromOffset(48, 1), BackgroundColor3 = C.accent, BorderSizePixel = 0, LayoutOrder = 3, Parent = narrEnding })

-- Skip affordance: keycap + word, bottom-right, visible during the intro (cinematic or text).
local skipGui = screen("IntroSkip", 102)
local skipRow = scaled(new("TextButton", {
	Text = "",
	AutoButtonColor = false,
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(1, 1),
	Position = UDim2.new(1, -36, 1, -36),
	Size = UDim2.fromOffset(0, 30),
	AutomaticSize = Enum.AutomaticSize.X,
	Parent = skipGui,
}, { list(10, true) }))
local skipCapHolder = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 1, Parent = skipRow })
tag("Skip", 14, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 2, Parent = skipRow })
local function paintSkip()
	skipCapHolder:ClearAllChildren()
	local mode = inputMode()
	if mode ~= "touch" then
		keycap(if mode == "pad" then "A" else "E", skipCapHolder)
	end
end

local skipSent = false
local function skipIntro()
	-- cinematic intros use Cinematics' hold-to-skip; a tap (e.g. the key that pressed Start) must not skip them
	if curState == "Intro" and not paused and not skipSent and not cinematic and (curPayload :: any).cinematic == nil then
		skipSent = true
		send("SkipIntro")
	end
end
onClick(skipRow :: any, skipIntro)

local narrGen = 0
local function narrWait(seconds: number, gen: number): boolean
	local elapsed = 0
	while elapsed < seconds do
		local dt = task.wait()
		if gen ~= narrGen then
			return false
		end
		if not paused then
			elapsed += dt
		end
	end
	return true
end

local function playNarrative(lines: any, lineSeconds: any, finalTitle: string?)
	narrGen += 1
	local gen = narrGen
	narrText.TextTransparency = 1
	narrEnding.GroupTransparency = 1
	local secs = if type(lineSeconds) == "number" and lineSeconds > 1 then lineSeconds else 3
	task.spawn(function()
		for _, line in (if type(lines) == "table" then lines else {}) do
			if gen ~= narrGen then
				return
			end
			narrText.Text = tostring(line)
			fade(narrText, 0.8, { TextTransparency = 0 })
			if not narrWait(secs - 0.8, gen) then
				return
			end
			fade(narrText, 0.6, { TextTransparency = 1 })
			if not narrWait(0.7, gen) then
				return
			end
		end
		if finalTitle and gen == narrGen then
			narrEndTitle.Text = finalTitle
			fade(narrEnding, 1.4, { GroupTransparency = 0 })
		end
	end)
end

local function showStatic(text: string)
	narrGen += 1
	narrEnding.GroupTransparency = 1
	narrText.Text = text
	narrText.TextTransparency = 1
	fade(narrText, 0.4, { TextTransparency = 0 })
end

----------------------------------------------------------------------------
-- Choice (DisplayOrder 100)
----------------------------------------------------------------------------
local choiceGui, choiceQ, btnDream, btnReality
do -- scoped: keeps top-level locals under Luau's 200-register limit
choiceGui = screen("ChoicePrompt", 100)
backdrop(choiceGui, 0)
local choiceCol = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(760, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = choiceGui,
}, { list(56, false, Enum.HorizontalAlignment.Center) }))
choiceQ = tag("Are you awake?", 16, { FontFace = BODY, TextColor3 = C.dim, LayoutOrder = 1, Parent = choiceCol })
local choiceRow = new("Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.new(), LayoutOrder = 2, Parent = choiceCol }, { list(120, true) })
local dreamLbl, realityLbl
	btnDream, dreamLbl = textButton(track("Dream", " "), 44, { LayoutOrder = 1, Parent = choiceRow })
btnReality, realityLbl = textButton(track("Reality", " "), 44, { LayoutOrder = 2, Parent = choiceRow })
-- hovering one word quiets the other
for _, pair in { { btnDream, realityLbl }, { btnReality, dreamLbl } } do
	local b, other = pair[1], pair[2]
	local function quiet(v: boolean)
		if not b:GetAttribute("Disabled") then
			tween(other, { TextTransparency = if v then 0.75 else 0.25 }, 0.3)
		end
	end
	b.MouseEnter:Connect(function()
		quiet(true)
	end)
	b.MouseLeave:Connect(function()
		quiet(false)
	end)
	b.SelectionGained:Connect(function()
		quiet(true)
	end)
	b.SelectionLost:Connect(function()
		quiet(false)
	end)
end
local function choose(which: string)
	setDisabled(btnDream, true)
	setDisabled(btnReality, true)
	RequestChoice:FireServer(which)
end
onClick(btnDream, function()
	choose("Dream")
end)
onClick(btnReality, function()
	choose("Reality")
end)

end

----------------------------------------------------------------------------
-- Game over (DisplayOrder 100)
----------------------------------------------------------------------------
local goGui, goReason, btnRestart
do -- scoped: keeps top-level locals under Luau's 200-register limit
goGui = screen("GameOver", 100)
backdrop(goGui, 0.06)
local goCol = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(640, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = goGui,
}, { list(16, false, Enum.HorizontalAlignment.Center) }))
tag(track("Signal lost"), 12, { FontFace = MED, TextColor3 = C.red, LayoutOrder = 1, Parent = goCol })
goReason = tag("", 32, { FontFace = LIGHT, TextColor3 = C.text, LayoutOrder = 2, Parent = goCol })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 24), LayoutOrder = 3, Parent = goCol })
btnRestart = textButton("Restart from checkpoint", 18, { LayoutOrder = 4, Parent = goCol })
onClick(btnRestart, function()
	setDisabled(btnRestart, true)
	send("Restart")
end)

end

----------------------------------------------------------------------------
-- Keypad fallback (DisplayOrder 100)
----------------------------------------------------------------------------
local kpOpen, kpEntry, kpLen, kpObjective, kpChecking = false, "", 4, "R_Distress", false
local paintKeypad, kpPress, closeKeypad, openKeypad
do -- scoped: keeps top-level locals under Luau's 200-register limit
local keypadGui = screen("Keypad", 100)
backdrop(keypadGui, 0.45).Active = false
local kp = scaled(new("Frame", {
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(300, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundColor3 = C.bg,
	BackgroundTransparency = 0.04,
	Parent = keypadGui,
}, { corner(), stroke(C.line, 0.85), pad(24), list(12, false, Enum.HorizontalAlignment.Center) }))
tag(track("Transmit auth"), 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = 1, Parent = kp })
tag("Code is on the comms screen", 14, { FontFace = BODY, TextColor3 = C.faint, LayoutOrder = 2, Parent = kp })
local kpDisplay = new("TextLabel", {
	FontFace = MONO,
	TextSize = 28,
	TextColor3 = C.text,
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 0, 0, 52),
	LayoutOrder = 3,
	Parent = kp,
}) :: TextLabel
hair(kpDisplay, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1) })
local kpGrid = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 4 * 48 + 3 * 8), LayoutOrder = 4, Parent = kp }, {
	new("UIGridLayout", { CellSize = UDim2.new(1 / 3, -6, 0, 48), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
})
local btnCancel = textButton("Cancel", 16, { LayoutOrder = 5, Parent = kp })

function paintKeypad()
	if kpChecking then
		kpDisplay.Text = "Checking"
		return
	end
	local cells = {}
	for i = 1, kpLen do
		cells[i] = if i <= #kpEntry then string.sub(kpEntry, i, i) else "_"
	end
	kpDisplay.Text = table.concat(cells, "  ")
end
function kpPress(key: string)
	if not kpOpen then
		return
	end
	if key == "CLR" then
		kpChecking = false
		kpEntry = ""
	elseif key == "OK" then
		if #kpEntry == 0 or kpChecking then
			return
		end
		kpChecking = true
		RequestObjectiveComplete:FireServer(kpObjective, { code = kpEntry })
		kpEntry = ""
	elseif not kpChecking and #kpEntry < kpLen then
		kpEntry ..= key
	end
	paintKeypad()
end
local firstKey: GuiObject? = nil
for i, key in { "1", "2", "3", "4", "5", "6", "7", "8", "9", "CLR", "0", "OK" } do
	local b = boxButton(if key == "OK" then "Enter" elseif key == "CLR" then "Clear" else key, {
		FontFace = if #key > 1 then MED else MONO,
		TextSize = if #key > 1 then 14 else 20,
		LayoutOrder = i,
		Parent = kpGrid,
	})
	if key == "OK" then
		b.TextColor3 = C.accent
	end
	firstKey = firstKey or b
	onClick(b, function()
		kpPress(key)
	end)
end

function closeKeypad()
	kpOpen, kpChecking, kpEntry = false, false, ""
	keypadGui.Enabled = false
end
function openKeypad(params: any)
	params = if type(params) == "table" then params else {}
	kpObjective = if type(params.objectiveId) == "string" then params.objectiveId else "R_Distress"
	kpLen = if type(params.code) == "string" and #params.code > 0 then math.min(#params.code, 8) else 4
	local reopened = kpOpen
	kpOpen, kpChecking, kpEntry = true, false, ""
	keypadGui.Enabled = true
	paintKeypad()
	if not reopened then
		focus(firstKey)
	end
end
onClick(btnCancel, closeKeypad)

end

----------------------------------------------------------------------------
-- Pause (DisplayOrder 101 so it sits over an open keypad; always enabled for the pause button)
----------------------------------------------------------------------------
local pauseGui = screen("PauseMenu", 101, true)
local btnPauseIcon = new("TextButton", {
	Text = "",
	AutoButtonColor = false,
	BackgroundColor3 = C.surface,
	BackgroundTransparency = 0.3,
	AnchorPoint = Vector2.new(1, 0),
	Position = UDim2.new(1, -24, 0, 72),
	Size = UDim2.fromOffset(40, 40),
	Visible = false,
	Parent = pauseGui,
}, { corner(), stroke(C.line, 0.85) }) :: TextButton
for _, x in { 14, 22 } do
	new("Frame", { Position = UDim2.fromOffset(x, 13), Size = UDim2.fromOffset(3, 14), BackgroundColor3 = C.text, BorderSizePixel = 0, Parent = btnPauseIcon }, { corner(1) })
end
scaled(btnPauseIcon)
local pauseShade = backdrop(pauseGui, 0.3)
pauseShade.Visible = false
new("UIGradient", {
	Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.6, 0.5), NumberSequenceKeypoint.new(1, 0.7) }),
	Parent = pauseShade,
})
local pauseCol = scaled(new("Frame", {
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0, 0.5),
	Position = UDim2.new(0, 88, 0.5, 0),
	Size = UDim2.fromOffset(420, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	Parent = pauseShade,
}, { list(6) }))
tag("Paused", 44, { FontFace = LIGHT, TextColor3 = C.text, LayoutOrder = 1, Parent = pauseCol })
tag("Station clock holding.", 14, { FontFace = BODY, TextColor3 = C.dim, LayoutOrder = 2, Parent = pauseCol })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 36), LayoutOrder = 3, Parent = pauseCol })
local btnResume = textButton("Resume", 22, { LayoutOrder = 4, Parent = pauseCol })
pauseBtns = {
	settings = textButton("Settings", 22, { LayoutOrder = 5, Parent = pauseCol }),
	log = textButton("Mission log", 22, { LayoutOrder = 6, Parent = pauseCol }),
}
local btnQuit = textButton("Quit to menu", 22, { LayoutOrder = 7, Parent = pauseCol })
new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 20), LayoutOrder = 8, Parent = pauseCol })
tag("Progress is kept at your last checkpoint.", 14, { FontFace = BODY, TextColor3 = C.faint, LayoutOrder = 9, Parent = pauseCol })

-- Mission log card, right side: today's log lines + objectives from the last StateChanged payload.
do
	logPanel = scaled(new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -88, 0.5, 0),
		Size = UDim2.fromOffset(440, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.surface,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = pauseShade,
	}, { corner(), stroke(C.line, 0.88), pad(24, 28), list(10) }))
	local kicker = tag("", 12, { FontFace = MED, TextColor3 = C.accent, LayoutOrder = 1, Parent = logPanel })
	local title = tag("", 20, { FontFace = BODY, TextColor3 = C.text, LayoutOrder = 2, Parent = logPanel })
	hair(logPanel, { LayoutOrder = 3 })
	local body = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = logPanel }, { list(8) })
	function paintLog()
		for _, c in body:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local p = curPayload
		kicker.Text = track("Mission day " .. tostring(p.missionDay or "—"), " ")
		title.Text = tostring(p.dayTitle or "Mission log")
		local n = 0
		local function sub(text: string)
			n += 1
			new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(1, 6), LayoutOrder = n, Parent = body })
			n += 1
			tag(track(text, " "), 12, { FontFace = MED, TextColor3 = C.dim, LayoutOrder = n, Parent = body })
		end
		local function line(text: any, color: Color3, box: boolean?)
			n += 1
			local r = new("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = n, Parent = body })
			if box ~= nil then
				new("Frame", { Position = UDim2.fromOffset(0, 5), Size = UDim2.fromOffset(8, 8), BackgroundColor3 = C.accent, BackgroundTransparency = if box then 0 else 1, BorderSizePixel = 0, Parent = r }, { corner(2), stroke(if box then C.accent else C.line, if box then 0 else 0.55) })
			end
			label({ Text = tostring(text), TextSize = 14, TextColor3 = color, Position = UDim2.fromOffset(if box ~= nil then 20 else 0, 0), Size = UDim2.new(1, if box ~= nil then -20 else 0, 0, 0), Parent = r })
		end
		if type(p.dayLog) == "table" and #p.dayLog > 0 then
			sub("Log")
			for _, l in p.dayLog do
				line(if type(l) == "table" then l.text else l, C.dim)
			end
		end
		if type(lastObjectives) == "table" and #lastObjectives > 0 then
			sub("Objectives")
			for _, o in lastObjectives do
				if type(o) == "table" then
					line(o.text or o.id, if o.done then C.faint elseif o.active then C.text else C.dim, o.done == true)
				end
			end
		end
		if n == 0 then
			line("No entries yet.", C.faint)
		end
	end
end

local function requestPause()
	if not paused and States.Pausable[curState] then
		send("Pause")
	end
end
local function togglePause()
	if paused then
		send("Resume")
	else
		requestPause()
	end
end
onClick(btnPauseIcon, requestPause)
bind(btnResume, function()
	send("Resume")
end)
bind(pauseBtns.settings, function()
	logPanel.Visible = false
	openSettings(true, true, pauseBtns.settings)
end)
bind(pauseBtns.log, function()
	logPanel.Visible = not logPanel.Visible
	if logPanel.Visible then
		paintLog()
		logPanel.Position = UDim2.new(1, -64, 0.5, 0)
		tween(logPanel, { Position = UDim2.new(1, -88, 0.5, 0) }, 0.5)
	end
end)
bind(btnQuit, function()
	confirmAsk("Quit to menu?", "Progress since your last checkpoint will be lost.", "Quit", function()
		send("QuitToMenu")
	end, btnQuit)
end)

-- Keyboard walker for menu / pause / settings / credits / confirm (gamepad uses engine selection).
do
	local function shown(o: Instance?): boolean
		while o and o:IsA("GuiObject") do
			if not o.Visible then
				return false
			end
			o = o.Parent
		end
		return not (o and o:IsA("LayerCollector")) or (o :: LayerCollector).Enabled
	end
	local function navRoot(): Instance?
		if confirmGui.Enabled then
			return confirmBox
		elseif settingsOpen then
			return sheet
		elseif menuGui.Enabled then
			return if creditsFrame.Visible then creditsFrame else menuGui
		elseif paused then
			return pauseCol
		end
		return nil
	end
	local function navBack()
		if confirmGui.Enabled then
			confirmClose()
		elseif settingsOpen then
			settingsCancel()
		elseif menuGui.Enabled and creditsFrame.Visible then
			openCredits(false)
		elseif paused and logPanel.Visible then
			logPanel.Visible = false
		elseif paused then
			send("Resume")
		end
	end
	local K = Enum.KeyCode
	UserInputService.InputBegan:Connect(function(input: InputObject, gp: boolean)
		local root = navRoot()
		if UserInputService:GetFocusedTextBox() or not root then
			return
		end
		local k = input.KeyCode
		if k == K.ButtonB or k == K.Backspace then
			navBack()
			return
		end
		if gp or isGamepad() then
			return
		end
		local sel = GuiService.SelectedObject
		if sel and not (sel:IsDescendantOf(root) and shown(sel)) then
			sel = nil
		end
		local dir = if k == K.Up or k == K.W then -1 elseif k == K.Down or k == K.S then 1 else nil
		local side = if k == K.Left or k == K.A then -1 elseif k == K.Right or k == K.D then 1 else nil
		if side and sel and stepFns[sel] then
			stepFns[sel](side)
		elseif dir or side then
			local items = {}
			for _, d in root:GetDescendants() do
				if navFns[d] and (d :: GuiButton).Selectable and shown(d) then
					table.insert(items, d)
				end
			end
			table.sort(items, function(a, b)
				local ay, by = a.AbsolutePosition.Y, b.AbsolutePosition.Y
				if math.abs(ay - by) > 4 then
					return ay < by
				end
				return a.AbsolutePosition.X < b.AbsolutePosition.X
			end)
			local d = (dir or side) :: number
			local i = sel and table.find(items, sel)
			local nxt = items[if i then math.clamp(i + d, 1, #items) elseif d > 0 then 1 else #items]
			if nxt then
				GuiService.SelectedObject = nxt
			end
		elseif (k == K.Return or k == K.KeypadEnter or k == K.Space or k == K.E) and sel and navFns[sel] then
			navFns[sel]()
		end
	end)
end

----------------------------------------------------------------------------
-- Scaling
----------------------------------------------------------------------------
do -- scoped: keeps top-level locals under Luau's 200-register limit
local vpConn: RBXScriptConnection? = nil
local function updateScale()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.6, 1.3)
	for _, u in scales do
		u.Scale = s
	end
end
local function hookCamera()
	if vpConn then
		vpConn:Disconnect()
		vpConn = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		vpConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
hookCamera()

end

----------------------------------------------------------------------------
-- Main-menu camera: slow drift along the hull windows (starfield on the right, dark hall left)
----------------------------------------------------------------------------
local startMenuCam, stopMenuCam
do -- scoped: keeps top-level locals under Luau's 200-register limit
local MENU_FROM, MENU_TO = Vector3.new(-7, 18.2, -77), Vector3.new(-6, 18.8, -83)
local MENU_LOOK_FROM, MENU_LOOK_TO = Vector3.new(14, 17.5, -96), Vector3.new(14, 18.5, -102)
local MENU_PERIOD = 40 -- seconds for one drift out and back
local menuCamOn = false
function startMenuCam()
	if menuCamOn then
		return
	end
	menuCamOn = true
	local t0 = os.clock()
	RunService:BindToRenderStep("AuroraMenuCam", Enum.RenderPriority.Camera.Value + 1, function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		cam.CameraType = Enum.CameraType.Scriptable -- re-asserted each frame; spawns reset it
		local a = 0.5 - 0.5 * math.cos((os.clock() - t0) / MENU_PERIOD * math.pi * 2)
		local pos = MENU_FROM:Lerp(MENU_TO, a)
		cam.CFrame = CFrame.lookAt(pos, MENU_LOOK_FROM:Lerp(MENU_LOOK_TO, a)) * CFrame.Angles(0, 0, math.rad(math.sin(os.clock() * 0.2) * 0.4))
		cam.FieldOfView = 55
	end)
end
function stopMenuCam()
	if not menuCamOn then
		return
	end
	menuCamOn = false
	RunService:UnbindFromRenderStep("AuroraMenuCam")
	local cam = workspace.CurrentCamera
	if cam then
		cam.CameraType = Enum.CameraType.Custom
		cam.FieldOfView = 70
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			cam.CameraSubject = hum
		end
	end
end

end

----------------------------------------------------------------------------
-- Prompt gating: only prompts for active objectives, only in Reality/Objectives, never paused
----------------------------------------------------------------------------
local function applyPrompt(p: Instance)
	if not p:IsA("ProximityPrompt") then
		return
	end
	local id = p:GetAttribute("ObjectiveId")
	p.Enabled = not paused and PROMPT_STATES[curState] == true and type(id) == "string" and activeIds[id] == true
end
local function refreshPrompts()
	for _, p in CollectionService:GetTagged("AuroraPrompt") do
		applyPrompt(p)
	end
end
CollectionService:GetInstanceAddedSignal("AuroraPrompt"):Connect(applyPrompt)

----------------------------------------------------------------------------
-- Cinematic visibility
----------------------------------------------------------------------------
local function applyChrome()
	local hudOn = HUD_STATES[curState] == true and not cinematic
	hudGui.Enabled = hudOn
	for _, bb in promptFolder:GetChildren() do
		if bb:IsA("BillboardGui") then
			bb.Enabled = not cinematic
		end
	end
	btnPauseIcon.Visible = not paused and not cinematic and States.Pausable[curState] == true
	applyFov()
end
local function setCinematic(on: boolean)
	if cinematic == on then
		return
	end
	cinematic = on
	applyChrome()
	if on then
		skipGui.Enabled = false -- the cinematic draws its own hold-to-skip hint
	end
end
;(cinSignal :: BindableEvent).Event:Connect(function(on: any)
	setCinematic(on == true)
end)

----------------------------------------------------------------------------
-- State rendering
----------------------------------------------------------------------------
local lastResult: any = nil
local function chapterFor(state: string, p: { [string]: any }): string
	local d = tonumber(p.dream) or 0
	if state == "Reality" or d == 0 then
		return track(string.format("Mission day %d", tonumber(p.missionDay) or 212), " ") .. "   ·   " .. string.upper(if type(p.dayTitle) == "string" then p.dayTitle else "Standby cycle")
	end
	local name = if type(p.dreamName) == "string" then p.dreamName elseif type(p.title) == "string" then p.title else ""
	return string.upper(name) -- never label the layer (brief §2)
end

local function render(state: string, p: { [string]: any }, entering: boolean, prevState: string)
	-- menu
	if state == "MainMenu" then
		startMenuCam()
		menuBusy = false
		local hasSave = p.hasSave == true
		menuHasSave = hasSave
		menuSaveDay = if hasSave and tonumber(p.missionDay) then string.format("%02d", p.missionDay) else nil
		menuStatus.day.Text = menuSaveDay or "—"
		setDisabled(btnContinue, not hasSave)
		lastObjectives = nil
		local s = p.settings
		if type(s) == "table" then
			if type(s.operatorName) == "string" and s.operatorName ~= "" then
				nameBox.Text = s.operatorName
			end
			if type(s.volume) == "number" and s.volume == s.volume then
				applyVolume(s.volume)
				savedVolume = volume
			end
			local pr = {}
			for _, k in { "music", "sfx", "fov", "sens" } do
				if type(s[k]) == "number" and s[k] == s[k] then
					pr[k] = s[k]
				end
			end
			if type(s.shake) == "boolean" then
				pr.shake = s.shake
			end
			if type(s.autosave) == "boolean" then
				P.autosave = s.autosave
			end
			applyPrefs(pr)
			if type(s.subs) == "boolean" then
				s.subtitles = s.subs
			end
			applyLocalPrefs(if type(s.subtitles) == "boolean" then s.subtitles else subtitlesOn, if type(s.textSpeed) == "number" and speedBtns[s.textSpeed] then s.textSpeed else textSpeed)
		end
		if entering and not menuGui.Enabled then
			menuGui.Enabled = true
			openCredits(false, true)
			confirmClose()
			local card = menuStatus.card
			card.GroupTransparency = 1
			card.Position = UDim2.new(1, -64, 1, -96)
			task.delay(0.5, function()
				tween(card, { GroupTransparency = 0, Position = UDim2.new(1, -88, 1, -96) }, 0.9)
			end)
			settingsOpen = false
			sheet.Visible = false
			sheet.Position = UDim2.new(1, 420, 0, 0)
			staggerIn(menuItems)
			task.delay(0.6, function()
				focus(if hasSave then btnContinue else btnStart)
			end)
		end
		menuStatus.op.Text = nameBox.Text
		lastSub, lastResult = "", nil
	else
		stopMenuCam()
		menuGui.Enabled = false
	end

	-- HUD
	if HUD_STATES[state] then
		chapterLine.Text = chapterFor(state, p)
		local title = if state == "Reality" then p.title else (p.dreamName or p.title)
		trackerTitle.Text = tostring(title or "Station status")
		locationLine.Text = if type(p.location) == "string" then string.upper(p.location) else ""
		locationLine.Visible = locationLine.Text ~= ""
		renderObjectives(p.objectives)
		paintStation()
	end
	if state == "Reality" and entering and prevState ~= "Reality" and (p.tutorial == true or p.dayStart == true) then
		showChapter(string.format("Mission day %d", tonumber(p.missionDay) or 212), if type(p.dayTitle) == "string" then p.dayTitle else "Standby cycle")
	elseif state == "DreamLayer" and entering then
		lastResult = nil
		showChapter("Alert", p.title, true)
	elseif not HUD_STATES[state] and state ~= "EventTrigger" then
		hideChapter()
	end

	-- event beats and objective results
	if state == "EventTrigger" and entering then
		if p.beat == "Wake" and type(p.dreamName) == "string" then
			local d = tonumber(p.dream) or 0
			showChapter("", p.dreamName)
		else
			subtitle(p.text or p.result)
		end
	elseif state == "Objectives" and p.result ~= lastResult then
		lastResult = p.result
		subtitle(p.result)
	end

	-- narrative: an intro/ending with a camera cinematic shows no text panel; ending lines arrive in a later Refresh
	local narr = state == "Restart" or ((state == "Intro" or state == "Ending") and (p.cinematic == nil or type(p.lines) == "table"))
	narrGui.Enabled = narr
	narrShade.BackgroundTransparency = if state == "Ending" then 0.45 else 0 -- let the ending's lighting show through
	skipGui.Enabled = state == "Intro" and p.cinematic == nil and not cinematic
	if state == "Intro" then
		paintSkip()
	end
	if entering then
		if state == "Intro" then
			skipSent = false
			if type(p.lines) == "table" then
				playNarrative(p.lines, p.lineSeconds, nil)
			end
		elseif state == "Ending" then
			if type(p.lines) == "table" then
				local lines = table.clone(p.lines)
				table.insert(lines, "Deaths: " .. (tonumber(player:GetAttribute("AuroraDeaths")) or 0))
				playNarrative(lines, p.lineSeconds, tostring(p.title or p.ending or ""))
			end
		elseif state == "Restart" then
			showStatic("Resetting")
		end
	end
	if not narr then
		narrGen += 1
	end

	-- choice
	choiceGui.Enabled = state == "Choice"
	if state == "Choice" and entering then
		setDisabled(btnDream, false)
		setDisabled(btnReality, false)
		staggerIn({ choiceQ, btnDream, btnReality }, 12)
		task.delay(0.5, function()
			focus(btnDream)
		end)
	end

	-- game over
	goGui.Enabled = state == "GameOver"
	if state == "GameOver" and entering then
		goReason.Text = tostring(p.reason or "Crew safety lost")
		setDisabled(btnRestart, false)
		focus(btnRestart)
	end

	-- keypad closes when its objective is done or we leave the playable states
	if kpOpen then
		if not PROMPT_STATES[state] then
			closeKeypad()
		elseif type(p.objectives) == "table" then
			for _, o in p.objectives do
				if type(o) == "table" and o.id == kpObjective and (o.done or not o.active) then
					closeKeypad()
					break
				end
			end
		end
	end
	applyChrome()
end

local function setPaused(v: boolean)
	paused = v
	pauseShade.Visible = v
	btnPauseIcon.Visible = not v and not cinematic and States.Pausable[curState] == true
	if v then
		staggerIn({ btnResume, pauseBtns.settings, pauseBtns.log, btnQuit }, 6)
		focus(btnResume)
	else
		logPanel.Visible = false
		confirmClose()
		if settingsOpen and sheet.Parent ~= menuGui then
			settingsCancel()
		end
	end
	if not v and GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(pauseShade) then
		GuiService.SelectedObject = nil
	end
end

StateChanged.OnClientEvent:Connect(function(state: any, payload: any)
	if type(state) ~= "string" then
		return
	end
	local p = if type(payload) == "table" then payload else {}
	if state == "Pause" then
		setPaused(true)
		refreshPrompts()
		return
	end
	-- Reality/Objectives are re-sent on every objective update; other states only on entry or resume.
	local entering = not p.resumed and (state ~= curState or not PROMPT_STATES[state])
	local prev = curState
	curState, curPayload = state, p
	if type(p.objectives) == "table" then
		lastObjectives = p.objectives
	end
	activeIds = {}
	if PROMPT_STATES[state] and type(p.objectives) == "table" then
		for _, o in p.objectives do
			if type(o) == "table" and type(o.id) == "string" and o.active == true and o.done ~= true then
				activeIds[o.id] = true
			end
		end
	end
	if state == "MainMenu" or state == "GameOver" or state == "Choice" then
		cinematic = false -- a cinematic never outlives these screens
	end
	setPaused(false)
	local ok, err = pcall(render, state, p, entering, prev)
	if not ok then
		warn("[HUDController] render", state, err)
	end
	local sel = GuiService.SelectedObject
	local selGui = sel and sel:FindFirstAncestorWhichIsA("ScreenGui")
	if sel and (not selGui or not selGui.Enabled) then
		GuiService.SelectedObject = nil
	end
	refreshPrompts()
end)

StationChanged.OnClientEvent:Connect(function(snap: any)
	if type(snap) ~= "table" then
		return
	end
	for k, v in snap do
		if type(v) == "number" then
			station[k] = v
		end
	end
	paintStation()
end)

PlayCue.OnClientEvent:Connect(function(cue: any, params: any)
	if cue == "Keypad" then
		openKeypad(params)
	elseif cue == "Toast" then
		local text = type(params) == "table" and params.text
		toast(text, text == "Wrong code.")
	elseif cue == "NoRepairUnits" then
		toast("No repair units left", true)
	elseif cue == "Dialogue" and type(params) == "table" then
		if type(params.lines) == "table" then
			if #params.lines > 0 then
				table.clear(subQueue) -- newest beat wins; older backlog would play over the next scene
			end
			for _, l in params.lines do
				if type(l) == "table" then
					queueLine(if type(l.speaker) == "string" then l.speaker else nil, l.text, tonumber(l.hold))
				end
			end
		end
		showHint(params.hint)
	elseif cue == "Sleep" or cue == "DayEnd" then
		table.clear(subQueue) -- a phase boundary: never let last night's lines run into the morning
	elseif cue == "Cinematic" then
		setCinematic(true)
	elseif cue == "CinematicEnd" then
		setCinematic(false)
	end
end)

UserInputService.LastInputTypeChanged:Connect(function()
	if hintCard.Visible then
		paintHint()
	end
	if skipGui.Enabled then
		paintSkip()
	end
end)

----------------------------------------------------------------------------
-- Input: P / gamepad Start pause, Space/Enter/A skip, keypad digits
----------------------------------------------------------------------------
local DIGITS = {
	[Enum.KeyCode.Zero] = "0", [Enum.KeyCode.One] = "1", [Enum.KeyCode.Two] = "2", [Enum.KeyCode.Three] = "3",
	[Enum.KeyCode.Four] = "4", [Enum.KeyCode.Five] = "5", [Enum.KeyCode.Six] = "6", [Enum.KeyCode.Seven] = "7",
	[Enum.KeyCode.Eight] = "8", [Enum.KeyCode.Nine] = "9",
	[Enum.KeyCode.KeypadZero] = "0", [Enum.KeyCode.KeypadOne] = "1", [Enum.KeyCode.KeypadTwo] = "2",
	[Enum.KeyCode.KeypadThree] = "3", [Enum.KeyCode.KeypadFour] = "4", [Enum.KeyCode.KeypadFive] = "5",
	[Enum.KeyCode.KeypadSix] = "6", [Enum.KeyCode.KeypadSeven] = "7", [Enum.KeyCode.KeypadEight] = "8",
	[Enum.KeyCode.KeypadNine] = "9",
}

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	local k = input.KeyCode
	if k == Enum.KeyCode.ButtonStart then
		togglePause()
		return
	end
	if curState == "Intro" and k == Enum.KeyCode.ButtonA then
		skipIntro()
		return
	end
	if gameProcessed then
		return
	end
	if k == Enum.KeyCode.P then
		togglePause()
	elseif curState == "Intro" and (k == Enum.KeyCode.Space or k == Enum.KeyCode.E or k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter) then
		skipIntro()
	elseif kpOpen and not paused then
		if DIGITS[k] then
			kpPress(DIGITS[k])
		elseif k == Enum.KeyCode.Backspace then
			kpEntry = string.sub(kpEntry, 1, -2)
			paintKeypad()
		elseif k == Enum.KeyCode.Return or k == Enum.KeyCode.KeypadEnter then
			kpPress("OK")
		end
	end
end)

paintStation()
paintSettings()

-- Day badge (top-left) + objective log, and the end-of-day cinematic overlay.
-- own function scope: top-level chunk is at the 200-local register limit
;(function()
	local ACC = Color3.fromRGB(90, 200, 255)
	local dayGui = screen("AuroraDay", 5, false)
	-- top-centre clock only: the tracker owns top-left, and the day's log lives in Pause > Mission log
	local badge = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 20), Size = UDim2.fromOffset(300, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, Parent = dayGui }, { list(4, false, Enum.HorizontalAlignment.Center) })
	local dayText = new("TextLabel", { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, FontFace = MONO, TextSize = 13, TextColor3 = ACC, TextTransparency = 0.2, TextXAlignment = Enum.TextXAlignment.Center, Text = "MISSION DAY 212 · 06:40", LayoutOrder = 0, Parent = badge })
	local logLines = {}
	for i = 1, 3 do
		logLines[i] = new("TextLabel", { Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1, FontFace = BODY, TextSize = 12, TextWrapped = true, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Visible = false, LayoutOrder = i, Parent = badge })
	end
	local curDay, baseMin, t0 = 1, 400, os.clock()
	local function hhmm()
		local m = (baseMin + math.floor(os.clock() - t0)) % 1440 -- 1 game-minute per real second
		return string.format("%02d:%02d", m // 60, m % 60)
	end
	local SHOW = { Reality = true, Objectives = true, DreamLayer = true, EventTrigger = true }
	-- Dream vs waking must read at a glance: cold desaturated grade + NIGHT CYCLE badge + entry card.
	local dreamCC = new("ColorCorrectionEffect", { Name = "AuroraDreamGrade", Enabled = true, Parent = game:GetService("Lighting") })
	local nightCard = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.3), Size = UDim2.new(1, -40, 0, 70), BackgroundTransparency = 1, FontFace = LIGHT, TextSize = 34, TextColor3 = Color3.fromRGB(190, 180, 255), TextTransparency = 1, TextStrokeTransparency = 1, RichText = true, Parent = dayGui })
	local inDream = false
	StateChanged.OnClientEvent:Connect(function(state, p)
		p = if type(p) == "table" then p else {}
		local d = tonumber(p.dream) or 0
		local nowDream = d >= 1 and d <= 4 and state ~= "Ending" and state ~= "MainMenu"
		if nowDream ~= inDream then
			inDream = nowDream
			tween(dreamCC, if nowDream then { Saturation = -0.05, Contrast = 0, TintColor = Color3.fromRGB(246, 244, 255) } else { Saturation = 0, Contrast = 0, TintColor = Color3.new(1, 1, 1) }, 2)
			dayText.TextColor3 = if nowDream then Color3.fromRGB(190, 180, 255) else ACC
			if nowDream then
				nightCard.Text = string.format("NIGHT CYCLE<br/><font size=\"16\">%s</font>", if d == 4 then "you are not awake" else "this isn't the station you fell asleep in")
				tween(nightCard, { TextTransparency = 0, TextStrokeTransparency = 0.5 }, 1.2)
				task.delay(4, function()
					tween(nightCard, { TextTransparency = 1, TextStrokeTransparency = 1 }, 1.5)
				end)
			end
		end
		if type(p.day) == "number" and (p.day ~= curDay or p.dayStart == true or state == "Intro") then
			local h, m = string.match(tostring(p.dayTime or "06:40"), "(%d+):(%d+)")
			curDay, baseMin, t0 = p.day, (tonumber(h) or 6) * 60 + (tonumber(m) or 40), os.clock()
		end
		if type(p.dayLog) == "table" then
			for i = 1, 3 do
				logLines[i].Text = if type(p.dayLog[i]) == "string" then "· " .. p.dayLog[i] else ""
			end
		end
		dayGui.Enabled = SHOW[state] == true -- same readout day and night: hiding it at night would tell the player something
	end)
	task.spawn(function()
		while true do
			local md = tonumber(player:GetAttribute("MissionDay")) or 211 + curDay
			dayText.Text = if inDream then string.format("NIGHT CYCLE · DAY %d · %s", md, if math.random() < 0.25 then "--:--" else "03:1" .. math.random(0, 9)) else string.format("MISSION DAY %d · %s", md, hhmm())
			task.wait(1)
		end
	end)

	-- End-of-day overlay: fade, summary, saving ring, next-day card, fade out (~7.5 s).
	local endGui = screen("AuroraDayEnd", 60, false)
	local shade = new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 1, Parent = endGui })
	local function big(y, size, font, color)
		return new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y), Size = UDim2.new(1, -40, 0, size + 8), BackgroundTransparency = 1, FontFace = font, TextSize = size, TextColor3 = color, TextTransparency = 1, Text = "", Parent = shade })
	end
	local head = big(0.42, 40, LIGHT, C.text)
	local sub = big(0.5, 15, MONO, C.dim)
	local ring = new("ImageLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(1, -120, 1, -60), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1, Image = "rbxasset://textures/loading/robloxTiltRed.png", ImageColor3 = ACC, ImageTransparency = 1, Parent = shade }, { corner(11), stroke(ACC, 2) })
	local saveText = new("TextLabel", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(1, -100, 1, -60), Size = UDim2.fromOffset(160, 20), BackgroundTransparency = 1, FontFace = MONO, TextSize = 13, TextColor3 = C.dim, TextXAlignment = Enum.TextXAlignment.Left, TextTransparency = 1, Text = "", Parent = shade })
	local ringStroke = ring:FindFirstChildOfClass("UIStroke")
	if ringStroke then
		new("UIGradient", { Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.6, 0.9), NumberSequenceKeypoint.new(1, 1) }), Parent = ringStroke })
	end
	local spinning, saved, runId = false, false, 0
	local function show(o, on, t)
		tween(o, { TextTransparency = if on then 0 else 1 }, t or 0.4)
	end
	local function play(p)
		runId += 1
		local id = runId
		saved = false
		endGui.Enabled = true
		tween(shade, { BackgroundTransparency = 0 }, 0.8)
		task.wait(0.9)
		head.Text = string.format("MISSION DAY %d COMPLETE", tonumber(p.missionDay) or 212)
		local sm = {}
		for _, s in (if type(p.summary) == "table" then p.summary else {}) do
			if type(s) == "string" and s ~= "" then table.insert(sm, s) end
		end
		sub.Text = table.concat(sm, "   ·   ")
		show(head, true) show(sub, true)
		saveText.Text = "Saving…" saveText.TextColor3 = C.dim
		show(saveText, true)
		ring.ImageTransparency = 1
		if ringStroke then ringStroke.Transparency = 0.2 end
		spinning = true
		task.spawn(function()
			while spinning and id == runId do
				ring.Rotation = (ring.Rotation + 12) % 360
				task.wait()
			end
		end)
		task.wait(2.6)
		if id ~= runId then return end
		show(head, false) show(sub, false)
		task.wait(0.5)
		head.Text = string.format("MISSION DAY %d", tonumber(p.nextMissionDay) or 213)
		sub.Text = string.upper(tostring(p.nextTitle or "")) .. "   ·   STATION TIME " .. tostring(p.nextTime or "06:40")
		show(head, true) show(sub, true)
		task.wait(2.3)
		if id ~= runId then return end
		spinning = false
		show(head, false) show(sub, false) show(saveText, false)
		if ringStroke then ringStroke.Transparency = 1 end
		tween(shade, { BackgroundTransparency = 1 }, 0.8)
		task.wait(0.85)
		if id == runId then endGui.Enabled = false end
	end
	PlayCue.OnClientEvent:Connect(function(cue, params)
		local p = if type(params) == "table" then params else {}
		if cue == "DayEnd" then
			task.spawn(play, p)
		elseif cue == "DaySaved" then
			saved = true
			spinning = false
			saveText.Text = if p.ok == false then "Save failed — will retry" else "Progress saved"
			saveText.TextColor3 = if p.ok == false then C.amber else ACC
		end
	end)
end)()
