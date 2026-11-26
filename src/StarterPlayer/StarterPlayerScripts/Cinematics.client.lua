-- Cinematics: client camera director for Station Aurora.
-- Contract: PlayCue("Cinematic", {id, duration, skippable}) starts, PlayCue("CinematicEnd", {id, skipped}) ends.
-- Also ends on StateChanged MainMenu/GameOver/Restart. Timeline freezes on StateChanged "Pause".
-- Fires AuroraClientSignals.CinematicActive(on, id) (HUD hides, CameraEffects drops shake/sway).
-- Lighting per state is CameraEffects' job; a shot's `light` (CameraEffects preset key, false = release)
-- holds a readable look while it plays (AuroraClientSignals.CinematicPreset); released on finish.
-- Shot times are authored against Modules.Cinematics durations (warns on mismatch).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local Registry = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Cinematics"))
local FX = ReplicatedStorage:WaitForChild("AuroraFX", 10)

----------------------------------------------------------------------------
-- Signals
----------------------------------------------------------------------------
local signals = ReplicatedStorage:FindFirstChild("AuroraClientSignals")
if not signals then
	signals = Instance.new("Folder")
	signals.Name = "AuroraClientSignals"
	signals.Parent = ReplicatedStorage
end
local function ev(name)
	local e = signals:FindFirstChild(name)
	if not e then
		e = Instance.new("BindableEvent")
		e.Name = name
		e.Parent = signals
	end
	return e
end
local CinematicActive = ev("CinematicActive")
local CinematicFixtures = ev("CinematicFixtures")
local CinematicPreset = ev("CinematicPreset")

----------------------------------------------------------------------------
-- Audio (templates in AuroraFX.Sounds / StationAudio, routed to Master.SFX). Missing = silent.
----------------------------------------------------------------------------
local function sfxGroup()
	local master = SoundService:FindFirstChild("Master", true)
	return master and (master:FindFirstChild("SFX") or master) or nil
end
local liveSounds = {}
local function sound(name, props, fadeAfter)
	local folder = FX and FX:FindFirstChild("Sounds")
	local t = (folder and folder:FindFirstChild(name))
		or (ReplicatedStorage:FindFirstChild("StationAudio") and ReplicatedStorage.StationAudio:FindFirstChild(name))
	if not (t and t:IsA("Sound")) then
		return nil
	end
	local s = t:Clone()
	s.Looped = false
	s.SoundGroup = sfxGroup()
	for k, v in props or {} do
		s[k] = v
	end
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	table.insert(liveSounds, s)
	if fadeAfter then
		task.delay(fadeAfter, function()
			if s.Parent then
				TweenService:Create(s, TweenInfo.new(0.8), { Volume = 0 }):Play()
				task.delay(0.85, s.Destroy, s)
			end
		end)
	end
	return s
end
local function stopSounds()
	for _, s in liveSounds do
		if s.Parent then
			TweenService:Create(s, TweenInfo.new(0.6), { Volume = 0 }):Play()
			task.delay(0.65, s.Destroy, s)
		end
	end
	table.clear(liveSounds)
end

----------------------------------------------------------------------------
-- GUI: letterbox, black, captions, title card, hold-to-skip
----------------------------------------------------------------------------
local FONT = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Light)
local FONT_MED = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local ACCENT = Color3.fromRGB(255, 176, 92)

local ui
local function getUi()
	if ui and ui.gui.Parent then
		return ui
	end
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("CinematicGui")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CinematicGui"
	gui.DisplayOrder = 90
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local function frame(name, pos, size, anchor)
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = anchor or Vector2.zero
		f.Position = pos
		f.Size = size
		f.BackgroundColor3 = Color3.new()
		f.BorderSizePixel = 0
		f.Parent = gui
		return f
	end
	local black = frame("Black", UDim2.new(), UDim2.fromScale(1, 1))
	black.ZIndex = 5
	black.BackgroundTransparency = 1
	local white = frame("White", UDim2.new(), UDim2.fromScale(1, 1))
	white.BackgroundColor3 = Color3.new(1, 1, 1)
	white.ZIndex = 5
	white.BackgroundTransparency = 1
	local top = frame("Top", UDim2.new(), UDim2.fromScale(1, 0))
	local bottom = frame("Bottom", UDim2.fromScale(0, 1), UDim2.fromScale(1, 0), Vector2.new(0, 1))
	top.ZIndex, bottom.ZIndex = 4, 4

	local function label(name, font, size, pos, anchor)
		local l = Instance.new("TextLabel")
		l.Name = name
		l.BackgroundTransparency = 1
		l.FontFace = font
		l.TextSize = size
		l.TextColor3 = Color3.fromRGB(225, 230, 236)
		l.TextTransparency = 1
		l.AnchorPoint = anchor
		l.Position = pos
		l.Size = UDim2.new(0.9, 0, 0, size + 10)
		l.ZIndex = 6
		l.Parent = gui
		return l
	end
	local caption = label("Caption", FONT, 20, UDim2.new(0.5, 0, 0.87, 0), Vector2.new(0.5, 1))
	-- two wrapped lines max, outlined: long AURA lines used to clip off both edges
	caption.Size = UDim2.new(0.72, 0, 0, 100)
	caption.TextWrapped = true
	caption.TextYAlignment = Enum.TextYAlignment.Bottom
	caption.TextStrokeTransparency = 1
	caption.TextStrokeColor3 = Color3.new()
	caption.TextSize = 24
	caption.LineHeight = 1.15
	caption.RichText = true
	local title = label("Title", FONT, 44, UDim2.new(0.5, 0, 0.47, 0), Vector2.new(0.5, 0.5))
	title.TextColor3 = Color3.fromRGB(240, 242, 245)
	local sub = label("Sub", FONT_MED, 14, UDim2.new(0.5, 0, 0.47, 46), Vector2.new(0.5, 0.5))
	sub.TextColor3 = ACCENT
	local rule = Instance.new("Frame")
	rule.Name = "Rule"
	rule.AnchorPoint = Vector2.new(0.5, 0.5)
	rule.Position = UDim2.new(0.5, 0, 0.47, 28)
	rule.Size = UDim2.fromOffset(0, 1)
	rule.BackgroundColor3 = ACCENT
	rule.BorderSizePixel = 0
	rule.ZIndex = 6
	rule.Parent = gui
	caption.RichText = true
	for _, l in { caption, title, sub } do
		local c = Instance.new("UITextSizeConstraint")
		c.MaxTextSize = l.TextSize
		c.Parent = l
		l.TextScaled = true
	end

	local skip = label("Skip", FONT_MED, 13, UDim2.new(1, -28, 1, -22), Vector2.new(1, 1))
	skip.Size = UDim2.fromOffset(180, 20)
	skip.TextXAlignment = Enum.TextXAlignment.Right
	skip.TextColor3 = Color3.fromRGB(170, 176, 184)
	local bar = Instance.new("Frame")
	bar.Name = "SkipBar"
	bar.AnchorPoint = Vector2.new(1, 1)
	bar.Position = UDim2.new(1, -28, 1, -16)
	bar.Size = UDim2.fromOffset(0, 2)
	bar.BackgroundColor3 = ACCENT
	bar.BorderSizePixel = 0
	bar.ZIndex = 6
	bar.Parent = gui

	gui.Parent = pg
	ui = { gui = gui, black = black, white = white, top = top, bottom = bottom, caption = caption, title = title, sub = sub, rule = rule, skip = skip, bar = bar }
	return ui
end

local function tw(inst, t, props, style)
	local x = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Sine), props)
	x:Play()
	return x
end

local function letterbox(on, t, height)
	local u = getUi()
	local h = if on then (height or 0.11) else 0
	tw(u.top, t, { Size = UDim2.fromScale(1, h) })
	tw(u.bottom, t, { Size = UDim2.fromScale(1, h) })
end

local function black(alpha, t)
	tw(getUi().black, t or 0.01, { BackgroundTransparency = 1 - alpha })
end

-- Quick bright flash (explosion); fades back down on its own.
local function whiteFlash(peak, upT, downT)
	local w = getUi().white
	tw(w, upT or 0.05, { BackgroundTransparency = 1 - (peak or 1) })
	task.delay(upT or 0.05, function()
		if w.Parent then
			tw(w, downT or 0.6, { BackgroundTransparency = 1 })
		end
	end)
end

local captionToken = 0
local function caption(text, hold)
	captionToken += 1
	local my = captionToken
	local l = getUi().caption
	l.Text = text
	tw(l, 0.6, { TextTransparency = 0.02, TextStrokeTransparency = 0.55 })
	task.delay(hold or 2.8, function()
		if my == captionToken then
			tw(l, 0.8, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end)
end

-- AURA narration subtitle; with subtitles off only the short scene caption shows.
local operatorName = "Operator"
local function esc(s)
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end
local function say(line, short, hold)
	if player:GetAttribute("AuroraSubtitles") == false then
		if short then
			caption(short, hold)
		end
		return
	end
	caption('<font color="#FFB05C" size="15" weight="medium">A U R A</font>\n' .. esc(line), hold)
end

local function tracked(s)
	return (s:gsub("(.)", "%1 "):gsub(" $", ""))
end

local function titleCard(text, subText, hold)
	local u = getUi()
	u.title.Text = tracked(text)
	u.sub.Text = tracked(subText)
	tw(u.title, 1.6, { TextTransparency = 0 })
	tw(u.rule, 1.8, { Size = UDim2.fromOffset(120, 1) }, Enum.EasingStyle.Quint)
	task.delay(0.7, function()
		tw(u.sub, 1.2, { TextTransparency = 0.1 })
	end)
	task.delay(hold, function()
		tw(u.title, 1.2, { TextTransparency = 1 })
		tw(u.sub, 1, { TextTransparency = 1 })
		tw(u.rule, 1, { Size = UDim2.fromOffset(0, 1) })
	end)
end

local function clearText()
	captionToken += 1
	local u = getUi()
	for _, l in { u.caption, u.title, u.sub, u.skip } do
		tw(l, 0.4, { TextTransparency = 1, TextStrokeTransparency = 1 })
	end
	tw(u.rule, 0.4, { Size = UDim2.fromOffset(0, 1) })
	u.bar.Size = UDim2.fromOffset(0, 2)
end

----------------------------------------------------------------------------
-- Camera math
----------------------------------------------------------------------------
local function catmull(p0, p1, p2, p3, t)
	local t2, t3 = t * t, t * t * t
	return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

-- Point along a Catmull-Rom spline through pts (endpoints padded), u in [0,1].
local function spline(pts, u)
	local n = #pts
	if n == 1 then
		return pts[1]
	end
	local seg = math.clamp(u, 0, 1) * (n - 1)
	local i = math.min(math.floor(seg) + 1, n - 1)
	local t = seg - (i - 1)
	local p0 = pts[i - 1] or (2 * pts[i] - pts[i + 1])
	local p3 = pts[i + 2] or (2 * pts[i + 1] - pts[i])
	return catmull(p0, pts[i], pts[i + 1], p3, t)
end

local function smooth(u)
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local function root()
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end
-- Player-relative helpers: resolved when the shot starts, so a moving target doesn't wobble the path.
local function rel(offset)
	return function()
		local r = root()
		return if r then (r.CFrame * CFrame.new(offset)).Position else offset
	end
end
local function tagPos(tag, offset)
	return function()
		local x = CollectionService:GetTagged(tag)[1]
		local ok, p = pcall(function()
			return x:GetPivot().Position
		end)
		return (if ok then p else Vector3.zero) + offset
	end
end
-- Nearest tagged instance to the player (Refill: pick whichever O2 station is closest).
local function nearestTagged(tag)
	local r = root()
	local best, bestD
	for _, inst in CollectionService:GetTagged(tag) do
		local ok, cf = pcall(function()
			return inst:GetPivot()
		end)
		if ok then
			local d = if r then (cf.Position - r.Position).Magnitude else 0
			if not bestD or d < bestD then
				bestD, best = d, inst
			end
		end
	end
	return best
end
local function nearestPanelCF()
	local m = nearestTagged("O2Refill")
	local ok, cf = pcall(function()
		return m:GetPivot()
	end)
	return if ok then cf else CFrame.new()
end
local function panelRel(offset)
	return function()
		return (nearestPanelCF() * CFrame.new(offset)).Position
	end
end

local clientFolder = function()
	return workspace:FindFirstChild("AuroraFX_Client")
end

local function rayParams()
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	local ex = { player.Character }
	if clientFolder() then
		table.insert(ex, clientFolder())
	end
	p.FilterDescendantsInstances = ex
	return p
end

----------------------------------------------------------------------------
-- Shot lists. Shot: {t0, t1, pos = {...}, look = {...} | fn, fov = {a, b}, noise, roll, safe, grade}
-- pos/look entries are Vector3 or functions (resolved at shot start). Events: {at, fn}.
----------------------------------------------------------------------------
local V = Vector3.new
local PODS = V(-57.5, 29.6, -17)
local STATION = V(-90, 15, -85)
local RADAR = tagPos("Objective_Radar", V(0, 2, 0))
local LIFE = tagPos("Objective_LifeSupport", V(0, 1, 0))
-- Generator may be moved by another agent: resolve its pivot fresh each call, shots are
-- offsets relative to that pivot (GeneratorPanel) rather than fixed world points.
local function genCF()
	local m = CollectionService:GetTagged("Objective_Generator")[1]
	local ok, cf = pcall(function()
		return m:GetPivot()
	end)
	return if ok then cf else CFrame.new()
end
local function genRel(offset)
	return function()
		return (genCF() * CFrame.new(offset)).Position
	end
end
local shipPos = function()
	local f = clientFolder()
	local s = f and (f:FindFirstChild("ForeignShip") or f:FindFirstChild("Kestrel"))
	return if s then s:GetPivot().Position else nil
end

local GRADES = {
	space = { TintColor = Color3.fromRGB(215, 228, 255), Saturation = -0.1, Contrast = 0.12, Brightness = 0 },
	red = { TintColor = Color3.fromRGB(255, 205, 200), Saturation = -0.25, Contrast = 0.15, Brightness = -0.02 },
	cold = { TintColor = Color3.fromRGB(205, 220, 255), Saturation = -0.35, Contrast = 0.1, Brightness = 0 },
	void = { TintColor = Color3.fromRGB(200, 205, 230), Saturation = -0.5, Contrast = 0.2, Brightness = 0 },
	dawn = { TintColor = Color3.fromRGB(255, 222, 190), Saturation = 0.1, Contrast = 0.08, Brightness = 0.03 },
	frost = { TintColor = Color3.fromRGB(195, 222, 255), Saturation = -0.55, Contrast = 0.1, Brightness = 0.02 },
	-- visual grammar: clinical = reality (neutral, crisp); dream = teal-violet, washed, soft
	clinical = { TintColor = Color3.fromRGB(240, 246, 255), Saturation = -0.08, Contrast = 0.14, Brightness = 0.01 },
	dream = { TintColor = Color3.fromRGB(205, 205, 255), Saturation = -0.3, Contrast = -0.04, Brightness = 0.02 },
	death = { TintColor = Color3.fromRGB(255, 170, 170), Saturation = -0.7, Contrast = 0.2, Brightness = -0.05 },
}

local props = {} -- per-cinematic client models, destroyed on finish
local function spawnProp(name, cf)
	local t = FX and FX:FindFirstChild(name)
	if not t then
		return nil
	end
	local m = t:Clone()
	m:PivotTo(cf)
	local folder = clientFolder()
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "AuroraFX_Client"
		folder.Parent = workspace
	end
	m.Parent = folder
	table.insert(props, m)
	return m
end

local function orb(color, pos)
	local p = Instance.new("Part")
	p.Shape = Enum.PartType.Ball
	p.Size = V(2.2, 2.2, 2.2)
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Position = pos
	local l = Instance.new("PointLight")
	l.Color, l.Range, l.Brightness = color, 24, 3
	l.Parent = p
	p.Parent = workspace
	table.insert(props, p)
	return p
end

local function fxPart(pos)
	local p = Instance.new("Part")
	p.Size = V(0.3, 0.3, 0.3)
	p.Transparency = 1
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.Position = pos
	p.Parent = workspace
	table.insert(props, p)
	return p
end

-- Shorting panel: spark bursts + orange flashes.
local function sparks(pos, bursts)
	local p = fxPart(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 240, 200), Color3.fromRGB(255, 140, 40))
	pe.LightEmission = 1
	pe.Size = NumberSequence.new(0.35, 0)
	pe.Lifetime = NumberRange.new(0.3, 0.8)
	pe.Speed = NumberRange.new(14, 28)
	pe.SpreadAngle = Vector2.new(70, 70)
	pe.Acceleration = V(0, -50, 0)
	pe.Drag = 1.5
	pe.EmissionDirection = Enum.NormalId.Bottom
	pe.Rate = 0
	pe.Parent = p
	local l = Instance.new("PointLight")
	l.Color, l.Range, l.Brightness = Color3.fromRGB(255, 170, 80), 22, 0
	l.Parent = p
	sound("Clunk", { PlaybackSpeed = 1.6, Volume = 0.5 })
	for _ = 1, bursts or 5 do
		if not p.Parent then
			return
		end
		pe:Emit(math.random(18, 34))
		l.Brightness = 6
		task.wait(0.07)
		l.Brightness = 0
		task.wait(0.12 + math.random() * 0.45)
	end
end

-- O2 refill: gas burst (white vapour) + a brief green glow standing in for the gauge light.
local function vapor(pos)
	local p = fxPart(pos)
	local pe = Instance.new("ParticleEmitter")
	pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 255, 255))
	pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1.3) })
	pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) })
	pe.Lifetime = NumberRange.new(0.5, 0.9)
	pe.Speed = NumberRange.new(2, 4)
	pe.SpreadAngle = Vector2.new(25, 25)
	pe.Rate = 0
	pe.Parent = p
	pe:Emit(14)
end
local function greenGlow(pos)
	local p = fxPart(pos)
	local l = Instance.new("PointLight")
	l.Color, l.Range, l.Brightness = Color3.fromRGB(90, 255, 130), 8, 0
	l.Parent = p
	tw(l, 0.15, { Brightness = 5 })
	task.delay(0.5, function()
		if l.Parent then
			tw(l, 0.4, { Brightness = 0 })
		end
	end)
end

-- Red emergency strobes: real lights (the preset's own pulse is deliberately faint).
local function strobes(points, range)
	local lights = {}
	for _, pos in points do
		local l = Instance.new("PointLight")
		l.Color, l.Range, l.Brightness, l.Shadows = Color3.fromRGB(255, 35, 25), range or 45, 0, true
		l.Parent = fxPart(pos)
		table.insert(lights, l)
	end
	task.spawn(function()
		while lights[1].Parent and lights[1].Parent.Parent do
			for _, l in lights do
				tw(l, 0.2, { Brightness = 1.5 })
			end
			task.wait(0.5)
			for _, l in lights do
				tw(l, 0.8, { Brightness = 0.15 })
			end
			task.wait(1.1)
		end
	end)
end

local VOID = V(0, 900, 0)
local KESTREL_DOCK = CFrame.new(46, 20, -85) * CFrame.Angles(0, math.rad(90), 0)

local DEFS = {}

-- Opening (41s): tells the setup. Exterior (lit) -> calm standby night -> the failure on camera ->
-- darkness, red pulse on the operator's pod, hand over into the real Blackout preset.
local HALL_CAM = V(-28, 33, -47)
DEFS.Opening = {
	shots = {
		-- 1. exterior: sunlit hull, Earth behind
		{
			t0 = 0, t1 = 5.5, grade = "space", light = "CinSpace", lightT = 0.01, noise = 0.008,
			pos = { V(95, 85, -330), V(60, 70, -300) }, look = { STATION + V(20, 5, 0), STATION }, fov = { 44, 42 },
		},
		{
			t0 = 5.5, t1 = 12, grade = "space", noise = 0.01,
			pos = { V(60, 70, -300), V(-40, 58, -300), V(-150, 50, -290), V(-200, 45, -270) },
			look = { STATION, V(-88, 20, -87) }, fov = { 42, 40 },
		},
		-- 2. interior, normal night: main hall dolly, then the crew pod row
		{
			t0 = 12, t1 = 17, grade = "dawn", light = "CinNight", lightT = 0.01, noise = 0.012, safe = true,
			pos = { V(-24, 32, -48), V(-34, 29, -58), V(-46, 26, -66) }, look = { V(-110, 16, -110), V(-118, 18, -100) }, fov = { 60, 54 },
		},
		{
			t0 = 17, t1 = 21.5, grade = "dawn", noise = 0.012, safe = true,
			pos = { V(-4, 33.5, -11), V(-10, 33.2, -10.5), V(-16, 33, -10) }, look = { V(-50, 29.5, -2), V(-52, 29.5, -1) }, fov = { 58, 52 },
		},
		-- 3. the failure, seen from the hall
		{
			t0 = 21.5, t1 = 29.5, grade = "red", noise = 0.03, safe = true,
			pos = { HALL_CAM, HALL_CAM + V(-5, -1.5, -5) }, look = { V(-100, 20, -105), V(-95, 18, -100) }, fov = { 56, 48 },
		},
		-- 4. darkness: red pulse finds the operator's pod, push to the player
		{
			t0 = 29.5, t1 = 35.5, grade = "red", light = "CinDark", lightT = 0.01, noise = 0.03, safe = true,
			pos = { V(-14, 33, -10), V(-28, 32.5, -9), V(-38, 32, -8) }, look = { V(-50, 30, -1), V(-52, 29.5, 0) }, fov = { 52, 42 },
		},
		{
			t0 = 35.5, t1 = 41, grade = "red", noise = 0.025, safe = true,
			pos = { rel(V(3, 3, 10)), rel(V(1.2, 2.8, 7.5)), rel(V(0, 3, 9)) }, look = { rel(V(0, 1.6, 0)), rel(V(0, 1.5, -6)) }, fov = { 46, 70 },
		},
	},
	events = {
		{ 0, function() black(1, 0.01) letterbox(true, 0.01) end },
		{ 0.2, function() black(0, 2.2) sound("Hum", { Volume = 0.3 }, 10) end },
		{ 1.4, function() say("Station Aurora. Low orbit research platform.", "station aurora · low orbit", 3.6) end },
		{ 6, function() titleCard("STATION AURORA", "ONE OPERATOR. SIX PODS.", 4.2) end },
		{ 8.4, function() say("Crew of six. Mission day 212.", "crew of six · mission day 212", 3) end },
		{ 11.5, function() black(1, 0.45) end },
		{ 12.05, function() black(0, 0.9) end },
		{ 12.8, function() say("Standby cycle. The crew sleeps. Systems nominal.", "standby cycle · systems nominal", 4.2) end },
		{ 17.8, function() sound("Breath", { Volume = 0.2, PlaybackSpeed = 0.8 }) end },
		-- failure beats
		{ 21.6, function() CinematicFixtures:Fire("dim") sound("Creak", { PlaybackSpeed = 0.5, Volume = 0.35 }, 4) end },
		{ 21.85, function() CinematicFixtures:Fire("warm") end },
		{ 22.1, function() CinematicFixtures:Fire("dim") end },
		{ 22.25, function() CinematicFixtures:Fire("warm") end },
		{ 22.5, function() say("02:14. Main power failure.", "02:14 · main power failure", 3.2) end },
		{ 22.9, function() sparks(V(-70, 40.5, -80), 6) end },
		{ 23.5, function() sound("PowerDown", { PlaybackSpeed = 0.6, Volume = 0.8 }) CinematicFixtures:Fire("cascade", HALL_CAM, 2.6) end },
		{ 25.3, function() sparks(V(-52, 38, -62), 4) end },
		{ 26.2, function()
			CinematicPreset:Fire("CinFail", 0.6)
			strobes({ V(-60, 40, -70), V(-100, 40, -100), V(-45, 40, -110) }, 55)
			sound("SFX Siren Alarm", { PlaybackSpeed = 0.6, Volume = 0.18 }, 3)
		end },
		{ 26.6, function() say("Life support on reserve.", "life support: reserve", 2.8) end },
		{ 29.1, function() black(1, 0.4) end },
		{ 29.6, function()
			black(0, 1.2)
			strobes({ V(-48, 33.5, -4), V(-30, 34, -6) }, 22)
			sound("Drone", { Volume = 0.3 }, 10)
		end },
		{ 30.6, function() say(("%s. You're the only one awake."):format(operatorName), "one operator · awake", 3.8) end },
		{ 33, function() sound("Heartbeat", { Volume = 0.35 }, 3) end },
		{ 35.8, function() say("Find the backup generator. Use your torch.", "find the backup generator", 4) end },
		{ 38.2, function() CinematicPreset:Fire(nil, 1.6) sound("Breath", { Volume = 0.5 }) end }, -- hand over to the real Blackout
		{ 39.2, function() letterbox(false, 1.8) end },
	},
}

DEFS.Drift = {
	shots = {
		{ t0 = 0, t1 = 4, grade = "space", light = "CinSpace", lightT = 0.3, pos = { V(-210, 140, -430), V(-170, 120, -380) }, look = { STATION }, fov = { 40, 36 }, noise = 0.006 },
		{ t0 = 4, t1 = 7.5, grade = "clinical", pos = { V(-90, 85, -260), V(-86, 72, -215) }, look = { STATION, STATION + V(0, 10, 0) }, fov = { 38, 32 }, noise = 0.008 },
		-- world-space over the pod: player lies rotated in it, so root-relative offsets would swing sideways
		{ t0 = 7.5, t1 = 14, grade = "dream", light = false, lightT = 0.4, safe = true, noise = 0.015, pos = { V(-43, 40, -2.5), V(-43, 36, -5), V(-43, 34, -6.5) }, look = { V(-43, 29.8, -9.3) }, fov = { 60, 44 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.6) sound("Drone", { Volume = 0.2 }, 13) end },
		{ 1, function() caption("lights down. pod sealing.", 2.6) end },
		{ 7.2, function() black(1, 0.25) end },
		{ 7.55, function() black(0, 0.8) sound("Breath", { Volume = 0.35 }) end },
		{ 10.2, function() sound("Breath", { Volume = 0.3, PlaybackSpeed = 0.85 }) end },
		{ 12.4, function() black(1, 1.5) end }, -- ends on black; server's Sleep fade holds it through CinematicEnd
	},
}

DEFS.Dream1 = {
	shots = {
		{ t0 = 0, t1 = 3.5, grade = "dream", light = "CinSpace", lightT = 0.3, noise = 0.012, roll = 0.04, pos = { V(60, 90, -270), V(30, 78, -235) }, look = { STATION }, fov = { 42, 38 } },
		{ t0 = 3.5, t1 = 7.5, light = false, safe = true, noise = 0.1, grade = "dream", pos = { rel(V(2.5, -0.5, -5)), rel(V(2, -0.3, -4)) }, look = { rel(V(0, 1.6, 0)) }, fov = { 55, 50 } },
		{ t0 = 7.5, t1 = 13, safe = true, noise = 0.05, grade = "dream", pos = { function() return RADAR() + V(9, 4, 9) end, function() return RADAR() + V(4.5, 2.2, 4.5) end }, look = { RADAR }, fov = { 55, 40 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.4) sound("Hum", { PlaybackSpeed = 0.5, Volume = 0.3 }, 12) end },
		{ 3.3, function() black(1, 0.15) end }, { 3.55, function() black(0, 0.5) end },
		{ 5.5, function() sound("Breath", { Volume = 0.4 }) end },
		{ 7.3, function() black(1, 0.1) end }, { 7.55, function() black(0, 0.4) end },
	},
}

local WEST = V(-300, 40, -40)
DEFS.Dream3 = {
	shots = {
		{ t0 = 0, t1 = 3.5, grade = "dream", light = "CinNight", lightT = 0.3, noise = 0.012, roll = 0.06, pos = { V(-230, 70, -280), V(-200, 60, -250) }, look = { STATION }, fov = { 40, 36 } },
		{ t0 = 3.5, t1 = 8, light = "D3pre", safe = true, noise = 0.05, grade = "dream", pos = { rel(V(2.2, 2.2, 5)), rel(V(1.6, 1.9, 3.2)) }, look = { rel(V(0, 1.4, -20)) }, fov = { 60, 48 } },
		{ t0 = 8, t1 = 12, light = false, safe = true, noise = 0.04, grade = "dream", pos = { V(-138, 34, -64), V(-143, 34, -62) }, look = { V(-176, 33, -50) }, fov = { 58, 46 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.4) sound("Hum", { PlaybackSpeed = 0.5, Volume = 0.3 }, 11) end },
		{ 3.3, function() black(1, 0.15) end }, { 3.55, function() black(0, 0.5) end },
		{ 5.5, function() sound("Breath", { Volume = 0.55 }) end },
		{ 7.8, function() black(1, 0.15) end }, { 8.1, function() black(0, 0.6) end },
	},
}

DEFS.Dream4 = {
	shots = {
		{ t0 = 0, t1 = 3.5, grade = "dream", light = "CinNight", lightT = 0.3, noise = 0.03, roll = 0.1, pos = { V(-160, 45, -300), V(-140, 40, -260) }, look = { STATION }, fov = { 40, 46 } },
		{ t0 = 3.5, t1 = 6, light = false, safe = true, noise = 0.25, grade = "red", pos = { function() return LIFE() + V(10, 8, -12) end }, look = { LIFE }, fov = { 65, 60 } },
		{ t0 = 6, t1 = 8.5, safe = true, noise = 0.3, grade = "red", pos = { function() return LIFE() + V(4, 2, -4) end }, look = { LIFE }, fov = { 50, 44 } },
		{ t0 = 8.5, t1 = 12, safe = true, noise = 0.35, grade = "red", pos = { rel(V(0, 1.6, -4.5)), rel(V(0, 1.6, -3.5)) }, look = { rel(V(0, 1.5, 0)) }, fov = { 55, 64 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.2) sound("Hum", { PlaybackSpeed = 0.45, Volume = 0.35 }, 4) end },
		{ 3.4, function() black(1, 0.08) end }, { 3.5, function() black(0, 0.15) end },
		{ 9, function() sound("Breath", { Volume = 0.6, PlaybackSpeed = 1.2 }) end },
	},
}

DEFS.Choice = {
	shots = {
		{ t0 = 0, t1 = 6, grade = "void", light = "CinVoid", noise = 0.01, pos = { VOID + V(0, 1, 26), VOID + V(0, 0.5, 16) }, look = { VOID }, fov = { 45, 38 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 0.8)
			black(1, 0.01)
			black(0, 1.6)
			local a = orb(Color3.fromRGB(130, 170, 255), VOID + V(-9, 0, 0))
			local b = orb(Color3.fromRGB(255, 190, 120), VOID + V(9, 0, 0))
			tw(a, 5.6, { Position = VOID + V(-1.4, 0.3, 0) }, Enum.EasingStyle.Sine)
			tw(b, 5.6, { Position = VOID + V(1.4, -0.3, 0) }, Enum.EasingStyle.Sine)
		end },
		{ 1.2, function() sound("Drone", { Volume = 0.3, PlaybackSpeed = 0.8 }, 4.5) end },
		{ 3, function() caption("which one woke up?", 2.6) end },
	},
}

-- Backup generator restarts: close on the panel/flywheel, pull back and pan the hall as
-- CameraEffects cuts the lights on section by section, settle behind the player.
DEFS.PowerOn = {
	shots = {
		{ t0 = 0, t1 = 3, grade = "space", light = "CinNight", lightT = 0.3, noise = 0.005, pos = { V(-180, 70, -320), V(-150, 62, -290) }, look = { STATION }, fov = { 40, 36 } },
		{ t0 = 3, t1 = 5.6, safe = true, noise = 0.03, pos = { genRel(V(3.2, 2.4, 4.2)), genRel(V(2.4, 2.1, 3)) }, look = { genRel(V(0, 1.4, 0)) }, fov = { 42, 36 } },
		{ t0 = 5.6, t1 = 8, safe = true, noise = 0.02, pos = { genRel(V(1, 5, 8)), genRel(V(-6, 6, 14)) }, look = { genRel(V(0, 1, 0)), rel(V(0, 2, 6)) }, fov = { 46, 58 } },
		{ t0 = 8, t1 = 12, safe = true, noise = 0.015, pos = { rel(V(0, 3.4, 7)), rel(V(0, 3, 5)) }, look = { rel(V(0, 1.6, -4)) }, fov = { 55, 68 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.4) sound("Drone", { Volume = 0.2 }, 3) end },
		{ 2.8, function() black(1, 0.15) end }, { 3.05, function() black(0, 0.4) end },
		{ 9.2, function() sound("Clunk", { PlaybackSpeed = 0.6, Volume = 0.6 }) end },
		{ 3, function()
			sound("PowerDown", { PlaybackSpeed = 0.45, Volume = 0.55 }, 3)
			-- panel glow so the close-up reads before the station lights return
			local l = Instance.new("PointLight")
			l.Color, l.Range, l.Brightness = Color3.fromRGB(255, 180, 110), 18, 2
			l.Parent = fxPart(genRel(V(1.5, 3, 3))())
		end },
		{ 4.1, function() sound("Clunk", { PlaybackSpeed = 0.75, Volume = 0.7 }) end },
		{ 4.9, function() sound("Clunk", { PlaybackSpeed = 0.8, Volume = 0.65 }) end },
		{ 5.7, function() sound("Clunk", { PlaybackSpeed = 0.85, Volume = 0.6 }) end },
		{ 6.5, function() sound("Clunk", { PlaybackSpeed = 0.9, Volume = 0.55 }) end },
		{ 11.4, function() letterbox(false, 0.6) end },
	},
}

DEFS.GameOver = {
	shots = {
		{ t0 = 0, t1 = 4, grade = "death", light = "CinFail", noise = 0.02, roll = 0.2, pos = { rel(V(0, 6, 0.2)), rel(V(0, 22, 0.2)) }, look = { rel(V(0, 0, 0)) }, fov = { 60, 50 } },
	},
	events = { { 0, function() letterbox(true, 0.8) end }, { 2.6, function() black(1, 1.3) end } },
}

-- O2 refill (2.5s, not skippable, client-only): server fires the cue right after refilling and
-- never sends CinematicEnd -- close on whichever station's gauge is nearest the player.
DEFS.Refill = {
	selfEnd = true,
	shots = {
		{
			t0 = 0, t1 = 1.5, safe = true, noise = 0.01,
			pos = { panelRel(V(1.3, 1.6, 3.2)), panelRel(V(0.55, 0.95, 1.3)) },
			look = { panelRel(V(0.5, 0.8, 0.22)) }, fov = { 42, 26 },
		},
		{
			t0 = 1.5, t1 = 2.5, safe = true, noise = 0.01,
			pos = { rel(V(0.4, 2.6, 4)), rel(V(0, 2.2, 3)) }, look = { rel(V(0, 1.5, -2)) }, fov = { 40, 62 },
		},
	},
	events = {
		{ 0, function()
			letterbox(true, 0.12, 0.035)
			sound("AirVent", { Volume = 0.4, PlaybackSpeed = 1.3 }, 1.1)
		end },
		{ 0.1, function() vapor(panelRel(V(0.5, 1, 0.4))()) end },
		{ 0.25, function()
			greenGlow(panelRel(V(-0.6, 1.2, 0.35))())
			sound("Clunk", { PlaybackSpeed = 1.25, Volume = 0.5 })
		end },
	},
}

-- Day 1 timer ran out (12s, server holds, not skippable): alarms and the failure on camera, then a
-- cut outside as the reactor takes the station apart. AURA signs off with the operator's name.
DEFS.Meltdown = {
	shots = {
		{ t0 = 0, t1 = 2.2, safe = true, grade = "red", light = "CinFail", lightT = 0.2, noise = 0.02,
			pos = { rel(V(0, 3.5, 3)), rel(V(0.3, 3, 2.4)) }, look = { rel(V(0, 1.5, -3)) }, fov = { 50, 46 } },
		{ t0 = 2.2, t1 = 4.6, safe = true, grade = "red", noise = 0.07,
			pos = { rel(V(0, 2.6, 2)), rel(V(-0.4, 2.3, 1.6)) }, look = { rel(V(0, 1.5, -2)) }, fov = { 46, 54 } },
		{ t0 = 4.6, t1 = 6.3, grade = "red", noise = 0.01,
			pos = { V(70, 60, -280), V(25, 50, -150) }, look = { STATION, STATION + V(10, 8, 0) }, fov = { 40, 32 } },
		{ t0 = 6.3, t1 = 10, grade = "red", noise = 0.045,
			pos = { V(25, 50, -150), V(10, 42, -110) }, look = { STATION + V(10, 8, 0), STATION + V(15, 15, 5) }, fov = { 32, 62 } },
		{ t0 = 10, t1 = 12, grade = "red", noise = 0.02,
			pos = { V(10, 42, -110), V(-10, 38, -90) }, look = { STATION, STATION + V(-25, -15, 15) }, fov = { 62, 66 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 0.5)
			say("Reactor coolant failure. Containment lost.", "reactor coolant failure \226\128\162 containment lost", 3.4)
			sound("SFX Siren Alarm", { PlaybackSpeed = 0.65, Volume = 0.22 }, 4)
		end },
		{ 0.15, function()
			local r = root()
			local base = if r then r.Position else STATION
			strobes({ base + V(6, 3, 6), base + V(-6, 3, -6) }, 30)
		end },
		{ 1, function()
			local r = root()
			sparks((if r then r.Position else STATION) + V(2, 2, -2), 4)
		end },
		{ 2.4, function() sound("Rumble", { Volume = 0.35 }, 2) end },
		{ 3.5, function() say(("I'm sorry, %s."):format(operatorName), "i'm sorry, operator", 3) end },
		{ 4.5, function() black(1, 0.35) end },
		{ 4.9, function()
			black(0, 0.9)
			sound("Drone", { Volume = 0.3 }, 5)
		end },
		{ 6.3, function()
			whiteFlash(1, 0.04, 1.1)
			sound("LowStinger", { PlaybackSpeed = 0.55, Volume = 0.9 })
			local ball = orb(Color3.fromRGB(255, 150, 70), STATION)
			ball.Size = V(2, 2, 2)
			tw(ball, 3.2, { Size = V(65, 65, 65) }, Enum.EasingStyle.Quad)
			local pl = ball:FindFirstChildOfClass("PointLight")
			if pl then
				pl.Range, pl.Brightness = 150, 9
				tw(pl, 3.6, { Brightness = 0.4 }, Enum.EasingStyle.Quad)
			end
			local debris = fxPart(STATION)
			local pe = Instance.new("ParticleEmitter")
			pe.Texture = "rbxasset://textures/particles/smoke_main.dds"
			pe.Color = ColorSequence.new(Color3.fromRGB(100, 100, 100), Color3.fromRGB(25, 25, 25))
			pe.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(0.5, 10), NumberSequenceKeypoint.new(1, 18) })
			pe.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
			pe.Lifetime = NumberRange.new(3, 5)
			pe.Speed = NumberRange.new(15, 40)
			pe.SpreadAngle = Vector2.new(180, 180)
			pe.Rate = 0
			pe.Parent = debris
			pe:Emit(36)
			for i = 1, 3 do
				local chunk = Instance.new("Part")
				chunk.Size = V(3 + i, 2 + i * 0.6, 2 + i * 0.4)
				chunk.Material = Enum.Material.Metal
				chunk.Color = Color3.fromRGB(60, 62, 68)
				chunk.Anchored, chunk.CanCollide, chunk.CanQuery, chunk.CanTouch = true, false, false, false
				chunk.Position = STATION + V(i * 2 - 3, i, -i)
				chunk.Parent = workspace
				table.insert(props, chunk)
				tw(chunk, 5, { Position = chunk.Position + V((i - 2) * 22, i * 6, -i * 14), Orientation = Vector3.new(20 * i, 40 * i, 10 * i) }, Enum.EasingStyle.Linear)
			end
		end },
		{ 11, function() black(1, 1.1) end },
	},
}

-- Day 2 morning (9s): real stars, the station small against them, a light moving where nothing should be.
local DRIFT_LIGHT_A, DRIFT_LIGHT_B = V(-620, 90, -260), V(-560, 70, 140)
DEFS.Day2Contact = {
	shots = {
		-- waking: pull up out of the pod, clinical white (inverse of Drift)
		{ t0 = 0, t1 = 3.5, grade = "clinical", safe = true, noise = 0.004, pos = { V(-43, 34, -6.5), V(-43, 40, -2.5) }, look = { V(-43, 29.8, -9.3) }, fov = { 44, 60 } },
		{ t0 = 3.5, t1 = 8, grade = "space", light = "CinSpace", lightT = 0.3, noise = 0.006, pos = { V(-30, 75, -340), V(-120, 62, -310) }, look = { STATION, STATION + V(-40, 0, 0) }, fov = { 48, 42 } },
		{
			t0 = 8, t1 = 14, grade = "clinical", light = false, lightT = 0.4, safe = true, noise = 0.02,
			pos = { V(-150, 34, -52), V(-158, 34.5, -46) },
			look = function(u)
				return V(-400, 60, -120):Lerp(V(-420, 65, -20), smooth(u))
			end,
			fov = { 55, 30 },
		},
	},
	events = {
		{ 0, function() letterbox(true, 0.5) sound("Breath", { Volume = 0.4, PlaybackSpeed = 1.1 }) end },
		{ 0.8, function() caption("06:40. orbit stable.", 2.4) end },
		{ 3.3, function() black(1, 0.15) end },
		{ 3.5, function()
			black(0, 0.5)
			sound("Drone", { Volume = 0.25 }, 10)
			local light = orb(Color3.fromRGB(255, 226, 180), DRIFT_LIGHT_A)
			light.Size = V(5, 5, 5)
			local pl = light:FindFirstChildOfClass("PointLight")
			if pl then
				pl.Range, pl.Brightness = 60, 2
			end
			tw(light, 10.5, { Position = DRIFT_LIGHT_B }, Enum.EasingStyle.Linear)
		end },
		{ 7.7, function() black(1, 0.25) end },
		{ 8, function() black(0, 0.6) end },
		{ 9, function() caption("something out there is moving.", 3) end },
		{ 13.4, function() black(1, 0.5) end },
	},
}

-- Respawn (4s): black, heartbeat, death count, one line. Rotates by AuroraDeaths.
local RESPAWN_LINES = {
	"Life doesn't hand out second chances. You got one. Don't waste it.",
	"The station kept your seat warm. Get up.",
	"Air's back in the tank. Nobody else is coming. Move.",
	"You remember dying. That's worse than it sounds.",
}
DEFS.Respawn = {
	shots = { { t0 = 0, t1 = 4, pos = { V(-43, 40, -2) }, look = { V(-43, 29, -9) }, fov = { 60, 60 } } },
	events = {
		{ 0, function()
			black(1, 0.01)
			letterbox(true, 0.01)
			sound("Heartbeat", { Volume = 0.6 }, 4)
		end },
		{ 0.3, function()
			local n = tonumber(player:GetAttribute("AuroraDeaths")) or 1
			titleCard(("DEATHS: %d"):format(n), RESPAWN_LINES[(n - 1) % #RESPAWN_LINES + 1], 2.9)
		end },
	},
}

----------------------------------------------------------------------------
-- Crew (story v4): part-built figures, client-only, destroyed with the cinematic like any prop.
----------------------------------------------------------------------------
local EARTH = V(-90, 55, 430)
local CREW = {
	{ "OKAFOR", Color3.fromRGB(226, 120, 44), Color3.fromRGB(92, 62, 45) },
	{ "REYES", Color3.fromRGB(58, 132, 222), Color3.fromRGB(176, 128, 96) },
	{ "LINDQVIST", Color3.fromRGB(232, 232, 238), Color3.fromRGB(240, 205, 180) },
	{ "MERCER", Color3.fromRGB(86, 170, 96), Color3.fromRGB(210, 160, 125) },
	{ "TANAKA", Color3.fromRGB(196, 64, 76), Color3.fromRGB(226, 190, 150) },
}

local function crewFolder()
	local f = clientFolder()
	if not f then
		f = Instance.new("Folder")
		f.Name = "AuroraFX_Client"
		f.Parent = workspace
	end
	return f
end

local function block(parent, size, cf, color, material, ghost)
	local p = Instance.new("Part")
	p.Size, p.CFrame, p.Color = size, cf, color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
	p.CastShadow = not ghost
	p.Transparency = ghost or 0
	p.Parent = parent
	return p
end

-- First visible solid surface under p (zone volumes and glass skipped).
local function floorAt(p)
	local params = rayParams()
	local ignore = params.FilterDescendantsInstances
	for _ = 1, 8 do
		params.FilterDescendantsInstances = ignore
		local hit = workspace:Raycast(p + V(0, 4, 0), V(0, -30, 0), params)
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

-- cf: feet on the floor, facing LookVector. ghost = transparency (reflections). Returns model, head.
local function crew(i, cf, ghost, seated)
	local c = CREW[i]
	local m = Instance.new("Model")
	m.Name = "Crew_" .. c[1]
	local suit, dark = c[2], c[2]:Lerp(Color3.new(0, 0, 0), 0.35)
	local ty = if seated then 3 else 3.2
	if seated then
		block(m, V(1.8, 0.8, 1.8), cf * CFrame.new(0, 1.9, -0.6), dark, nil, ghost)
		block(m, V(1.8, 1.6, 0.8), cf * CFrame.new(0, 0.8, -1.3), dark, nil, ghost)
	else
		block(m, V(0.85, 2.2, 0.9), cf * CFrame.new(-0.47, 1.1, 0), dark, nil, ghost)
		block(m, V(0.85, 2.2, 0.9), cf * CFrame.new(0.47, 1.1, 0), dark, nil, ghost)
	end
	local torso = block(m, V(2, 2, 1.1), cf * CFrame.new(0, ty, 0), suit, nil, ghost)
	block(m, V(0.7, 1.9, 0.8), cf * CFrame.new(-1.35, ty, 0), suit, nil, ghost)
	block(m, V(0.7, 1.9, 0.8), cf * CFrame.new(1.35, ty, 0), suit, nil, ghost)
	block(m, V(1.2, 0.3, 0.1), cf * CFrame.new(0, ty + 0.5, -0.58), Color3.new(1, 1, 1), nil, ghost)
	local head = block(m, V(1.25, 1.25, 1.25), cf * CFrame.new(0, ty + 1.7, 0), c[3], nil, ghost)
	head.Shape = Enum.PartType.Ball
	m.PrimaryPart = torso
	if not ghost then
		local b = Instance.new("BillboardGui")
		b.Size = UDim2.fromOffset(120, 18)
		b.StudsOffset = V(0, 1.1, 0)
		b.MaxDistance = 35
		b.LightInfluence = 0
		local t = Instance.new("TextLabel")
		t.BackgroundTransparency = 1
		t.Size = UDim2.fromScale(1, 1)
		t.Font = Enum.Font.GothamMedium
		t.TextSize = 12
		t.TextColor3 = Color3.new(1, 1, 1)
		t.TextTransparency = 0.3
		t.Text = c[1]
		t.Parent = b
		b.Parent = head
	end
	m.Parent = crewFolder()
	table.insert(props, m)
	return m, head
end

-- Heads bob out of phase: people laughing at a table.
local function laugh(heads)
	local base = {}
	for i, h in heads do
		base[i] = h.CFrame
	end
	task.spawn(function()
		local t0 = os.clock()
		while heads[1] and heads[1].Parent do
			local t = os.clock() - t0
			for i, h in heads do
				local burst = math.max(0, math.sin(t * 0.8 + i * 1.7))
				h.CFrame = base[i] * CFrame.new(0, math.abs(math.sin(t * 9 + i)) * 0.14 * burst, 0) * CFrame.Angles(-0.12 * burst, 0, 0)
			end
			task.wait()
		end
	end)
end

local function galley()
	local a = CollectionService:GetTagged("StoryProp_Galley")[1]
	local props_ = workspace:FindFirstChild("Aurora Props")
	local zones = props_ and props_:FindFirstChild("MainDeckZones")
	local z = a or (zones and zones:FindFirstChild("Galley"))
	local ok, p = pcall(function()
		return z:GetPivot().Position
	end)
	return floorAt(if ok then p else V(-39, 20, -38.7))
end

local function airlock()
	for _, tag in { "StoryProp_Airlock", "EVA_Airlock", "Airlock" } do
		local a = CollectionService:GetTagged(tag)[1]
		if a then
			local ok, p = pcall(function()
				return a:GetPivot().Position
			end)
			if ok then
				return floorAt(p)
			end
		end
	end
	return floorAt(V(-6, 18, -90)) -- EVA bay entry, east wall
end

-- Table, six chairs, warm lamp. ghost: crew only as reflections. Returns heads.
local function galleyScene(G, ghost, warm)
	local f = crewFolder()
	local m = Instance.new("Model")
	m.Name = "GalleyScene"
	m.Parent = f
	table.insert(props, m)
	block(m, V(7, 0.35, 3.6), CFrame.new(G + V(0, 2.9, 0)), Color3.fromRGB(150, 150, 156), Enum.Material.Metal)
	block(m, V(0.5, 2.8, 0.5), CFrame.new(G + V(0, 1.4, 0)), Color3.fromRGB(90, 90, 96), Enum.Material.Metal)
	local seats = {
		CFrame.lookAt(G + V(-1.8, 0, -3), G + V(-1.8, 0, 0)),
		CFrame.lookAt(G + V(1.8, 0, -3), G + V(1.8, 0, 0)),
		CFrame.lookAt(G + V(-1.8, 0, 3), G + V(-1.8, 0, 0)),
		CFrame.lookAt(G + V(1.8, 0, 3), G + V(1.8, 0, 0)),
		CFrame.lookAt(G + V(4.6, 0, 0), G),
		CFrame.lookAt(G + V(-4.6, 0, 0), G), -- yours, always empty
	}
	for _, s in seats do
		block(m, V(1.9, 0.3, 1.9), s * CFrame.new(0, 1.7, 0.1), Color3.fromRGB(70, 74, 84))
		block(m, V(1.9, 2, 0.3), s * CFrame.new(0, 2.8, 1), Color3.fromRGB(70, 74, 84))
	end
	-- a mug in front of the empty seat, still steaming
	local mug = block(m, V(0.6, 0.7, 0.6), CFrame.new(G + V(-2.6, 3.4, 0)), Color3.fromRGB(200, 60, 50), Enum.Material.Plastic)
	if warm then
		local steam = Instance.new("Smoke")
		steam.Color, steam.Opacity, steam.RiseVelocity, steam.Size = Color3.new(1, 1, 1), 0.08, 1.5, 0.3
		steam.Parent = mug
	end
	local lamp = block(m, V(1, 0.3, 1), CFrame.new(G + V(0, 8, 0)), if warm then Color3.fromRGB(255, 200, 140) else Color3.fromRGB(120, 140, 170), Enum.Material.Neon)
	local l = Instance.new("PointLight")
	l.Color = lamp.Color
	l.Range, l.Brightness, l.Shadows = 22, if warm then 2.2 else 0.6, true
	l.Parent = lamp
	local heads = {}
	for i = 1, 5 do
		local _, h = crew(i, seats[i], ghost, true)
		table.insert(heads, h)
	end
	return heads
end

local function frostPod()
	local p = block(crewFolder(), V(9, 4.5, 11), CFrame.new(PODS + V(0, 0.6, 0)), Color3.fromRGB(215, 235, 255), Enum.Material.Ice, 0.55)
	table.insert(props, p)
	tw(p, 5, { Transparency = 0.25 })
end

local function fadeGhosts(t)
	for _, m in (clientFolder() or crewFolder()):GetChildren() do
		if string.sub(m.Name, 1, 5) == "Crew_" then
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") then
					tw(p, t, { Transparency = 1 })
				end
			end
		end
	end
end

----------------------------------------------------------------------------
-- Endings: Choice (Dream / Reality) x contact (made / never made)
----------------------------------------------------------------------------
local G_CAM = function(o)
	return function()
		return galley() + o
	end
end

-- Warm galley, crew laughing, your seat empty; pull out to the frost-sealed pod.
DEFS.Ending_Dream = {
	shots = {
		{ t0 = 0, t1 = 9, grade = "dawn", noise = 0.01, pos = { G_CAM(V(9, 6.5, 8)), G_CAM(V(6.5, 5.5, 5.5)) }, look = { G_CAM(V(0, 3.4, 0)) }, fov = { 50, 44 } },
		{ t0 = 9, t1 = 13.5, grade = "dawn", noise = 0.008, pos = { G_CAM(V(-8, 5.5, 2)), G_CAM(V(-6.5, 4.8, 1)) }, look = { G_CAM(V(-3.5, 3.2, 0)) }, fov = { 40, 33 } },
		{ t0 = 13.5, t1 = 20, grade = "frost", noise = 0.01, pos = { PODS + V(3, 2, 7), PODS + V(7, 5, 15) }, look = { PODS }, fov = { 38, 52 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 1)
			laugh(galleyScene(galley(), nil, true))
			sound("Hum", { Volume = 0.25 }, 9)
		end },
		{ 1.5, function() caption("someone is humming in the galley.", 3) end },
		{ 5.2, function() caption("okafor burned the toast again.", 3) end },
		{ 8.7, function() black(1, 0.3) end },
		{ 9.1, function() black(0, 0.7) end },
		{ 9.8, function() caption("they saved you a seat.", 3) end },
		{ 13.1, function() black(1, 0.3) end },
		{ 13.6, function()
			frostPod()
			CinematicFixtures:Fire("dim")
			black(0, 1.5)
		end },
		{ 15.5, function() caption("frost has sealed the pod.", 3) end },
		{ 18, function() CinematicFixtures:Fire("off") sound("PowerDown", { PlaybackSpeed = 0.5, Volume = 0.5 }) end },
		{ 19.8, function() CinematicFixtures:Fire(nil) end },
	},
}

-- Nobody answered: the galley is cold, the crew only exists as reflections, then not at all.
DEFS.Ending_Dream_Silent = {
	shots = {
		{ t0 = 0, t1 = 8.5, grade = "cold", noise = 0.012, pos = { G_CAM(V(8, 6, 7)), G_CAM(V(6, 5.4, 5)) }, look = { G_CAM(V(0, 3.2, 0)) }, fov = { 48, 42 } },
		{ t0 = 8.5, t1 = 16, grade = "frost", noise = 0.01, pos = { PODS + V(2.5, 1.8, 6), PODS + V(9, 7, 18) }, look = { PODS }, fov = { 36, 55 }, roll = 0.05 },
	},
	events = {
		{ 0, function()
			letterbox(true, 1)
			galleyScene(galley(), 0.82, false)
			CinematicFixtures:Fire("dim")
			sound("Drone", { Volume = 0.2 }, 8)
		end },
		{ 1.5, function() caption("the chairs are pulled out. nobody is in them.", 3.2) end },
		{ 4.6, function() fadeGhosts(2.5) end },
		{ 5.2, function() caption("you never called. they never came.", 3) end },
		{ 8.2, function() black(1, 0.3) end },
		{ 8.6, function()
			frostPod()
			CinematicFixtures:Fire("off")
			black(0, 1.5)
		end },
		{ 11, function() caption("frost has sealed the pod.", 3) end },
		{ 15.8, function() CinematicFixtures:Fire(nil) end },
	},
}

local function dockKestrel(t)
	local k = spawnProp("Kestrel", CFrame.new(420, 70, -30) * CFrame.Angles(0, math.rad(90), 0))
	if k then
		local from = k:GetPivot()
		task.spawn(function()
			local t0 = os.clock()
			while k.Parent do
				local a = math.clamp((os.clock() - t0) / t, 0, 1)
				k:PivotTo(from:Lerp(KESTREL_DOCK, 1 - (1 - a) ^ 3))
				task.wait()
			end
		end)
	end
end

-- Kestrel docks; the crew float in through the airlock; Okafor nods; Earth in the window.
DEFS.Ending_Reality = {
	shots = {
		{ t0 = 0, t1 = 7, grade = "dawn", noise = 0.01, pos = { V(-30, 60, -215), V(0, 52, -195) }, look = function()
			return shipPos() or KESTREL_DOCK.Position
		end, fov = { 48, 40 } },
		{ t0 = 7, t1 = 14, grade = "dawn", noise = 0.012, pos = { function() return airlock() + V(-16, 4.5, 5) end, function() return airlock() + V(-14, 4, 3.5) end },
			look = { function() return airlock() + V(0, 3.5, 0) end }, fov = { 55, 48 } },
		{ t0 = 14, t1 = 20, grade = "dawn", noise = 0.006, pos = { STATION + V(-20, 20, 150), STATION + V(-18, 26, 175) }, look = { EARTH }, fov = { 50, 44 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 1)
			dockKestrel(6.5)
		end },
		{ 1.5, function() caption("contact: relief vessel kestrel.", 3) end },
		{ 5.8, function() sound("Clunk", { PlaybackSpeed = 0.5, Volume = 0.8 }) end },
		{ 6.8, function() black(1, 0.2) end },
		{ 7.1, function()
			black(0, 0.6)
			local A = airlock()
			for i = 1, 5 do
				local fromCF = CFrame.lookAt(A + V(4 + i * 1.6, 1.5 + (i % 2), (i % 3 - 1) * 2), A + V(-20, 2, 0)) * CFrame.Angles(0.25, 0, 0.15 * (i % 2 * 2 - 1))
				local toCF = CFrame.lookAt(A + V(-2 - i * 1.5, 0.6 + (i % 2) * 0.5, (i % 3 - 1) * 2.2), A + V(-20, 2, 0))
				local m = crew(i, fromCF)
				task.spawn(function()
					local t0 = os.clock()
					local a = 0
					while m.Parent and a < 1 do
						a = math.clamp((os.clock() - t0) / 4.5, 0, 1)
						m:PivotTo(fromCF:Lerp(toCF, 1 - (1 - a) ^ 2) * CFrame.new(0, math.sin(a * math.pi * 3 + i) * 0.25 * (1 - a), 0))
						task.wait()
					end
				end)
			end
		end },
		{ 8, function() caption("the hatch opens. they float in one by one.", 3) end },
		{ 12, function()
			local ok_ = crewFolder():FindFirstChild("Crew_OKAFOR")
			if ok_ then -- nod: the whole figure dips, then rises (the float loop stopped at 4.5s)
				task.spawn(function()
					for _ = 1, 2 do
						local cf = ok_:GetPivot()
						ok_:PivotTo(cf * CFrame.Angles(-0.18, 0, 0))
						task.wait(0.35)
						ok_:PivotTo(cf)
						task.wait(0.3)
					end
				end)
			end
			caption("okafor doesn't say anything. he just nods.", 2.4)
		end },
		{ 13.8, function() black(1, 0.2) end },
		{ 14.1, function() black(0, 1) end },
		{ 15, function() caption("earth, in the window. closer than it's been in a long time.", 4) end },
	},
}

-- Nobody knew you were here: the ship passes without slowing; the crew is only in the glass.
DEFS.Ending_Reality_Silent = {
	shots = {
		{ t0 = 0, t1 = 8, grade = "cold", noise = 0.01, pos = { V(-20, 45, -230), V(-40, 40, -215) }, look = function()
			return shipPos() or STATION
		end, fov = { 46, 40 } },
		{ t0 = 8, t1 = 16, grade = "cold", noise = 0.014, pos = { tagPos("Objective_Windows", V(-9, 3.5, 3)), tagPos("Objective_Windows", V(-6, 3.2, 1.5)) },
			look = { tagPos("Objective_Windows", V(2, 3, -1)) }, fov = { 50, 40 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 1)
			local k = spawnProp("Kestrel", CFrame.new(420, 90, -60) * CFrame.Angles(0, math.rad(90), 0))
			if k then
				local from = k:GetPivot()
				local to = CFrame.new(-560, 110, -320) * CFrame.Angles(0, math.rad(90), 0)
				task.spawn(function()
					local t0 = os.clock()
					while k.Parent do
						k:PivotTo(from:Lerp(to, math.clamp((os.clock() - t0) / 14, 0, 1)))
						task.wait()
					end
				end)
			end
			sound("Drone", { Volume = 0.2 }, 8)
		end },
		{ 1.8, function() caption("a ship crosses the window. it doesn't slow down.", 3.4) end },
		{ 5.5, function() caption("contact: none.", 2.2) end },
		{ 7.8, function() black(1, 0.2) end },
		{ 8.1, function()
			black(0, 0.8)
			local w = tagPos("Objective_Windows", V(0, 0, 0))()
			local floor = floorAt(w + V(-3, 0, 0))
			for i = 1, 5 do
				crew(i, CFrame.lookAt(floor + V(-1.5, 0, (i - 3) * 1.8), floor + V(-9, 0, (i - 3) * 1.8)), 0.8)
			end
		end },
		{ 9, function() caption("in the glass: five faces behind you.", 3) end },
		{ 12.2, function() fadeGhosts(1.6) end },
		{ 13.2, function() caption("then only yours.", 2.6) end },
	},
}

----------------------------------------------------------------------------
-- Choice cinematics (Day 214 answer / silence, dish repair)
----------------------------------------------------------------------------
local COMMS = tagPos("Objective_Comms", V(0, 1.5, 0))
local GRID = tagPos("Objective_PowerGrid", V(0, 1.5, 0))
local function dishPos()
	for _, tag in { "EVA_Dish", "CommsDish", "Dish" } do
		local d = CollectionService:GetTagged(tag)[1]
		if d then
			local ok, p = pcall(function()
				return d:GetPivot().Position
			end)
			if ok then
				return p
			end
		end
	end
	return V(46, 25, -108) -- EVA dish
end

DEFS.ChoiceTransmit = {
	shots = {
		{ t0 = 0, t1 = 3, safe = true, noise = 0.02, pos = { function() return COMMS() + V(4, 2.5, 5) end, function() return COMMS() + V(2.2, 1.6, 3) end }, look = { COMMS }, fov = { 45, 36 } },
		{ t0 = 3, t1 = 6, grade = "space", noise = 0.01, pos = { STATION + V(-90, 40, -140), STATION + V(-110, 44, -120) }, look = function()
			return shipPos() or WEST
		end, fov = { 50, 42 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 0.4)
			greenGlow(COMMS())
			sound("Static", { Volume = 0.35 }, 3)
		end },
		{ 0.6, function() caption("transmitting on the crew channel.", 2.4) end },
		{ 3, function()
			local from, to = STATION + V(-20, 10, 0), shipPos() or WEST
			local beam = block(crewFolder(), V(0.6, 0.6, (to - from).Magnitude), CFrame.lookAt((from + to) / 2, to), Color3.fromRGB(120, 255, 170), Enum.Material.Neon, 0.3)
			table.insert(props, beam)
			tw(beam, 2.5, { Transparency = 1 })
		end },
		{ 3.6, function() caption("the ship turns toward you.", 2.2) end },
	},
}

DEFS.ChoiceSilent = {
	shots = {
		{ t0 = 0, t1 = 6, safe = true, noise = 0.025, pos = { function() return GRID() + V(4, 2.5, 5) end, function() return GRID() + V(2.4, 1.8, 3.2) end }, look = { GRID }, fov = { 46, 34 } },
	},
	events = {
		{ 0, function() letterbox(true, 0.4) end },
		{ 1.1, function()
			sound("Clunk", { PlaybackSpeed = 0.7, Volume = 0.8 })
			sparks(GRID(), 2)
			CinematicFixtures:Fire("dim")
		end },
		{ 1.6, function() caption("comms breaker: open.", 2) end },
		{ 3.8, function() caption("the channel goes quiet. almost.", 2) end },
		{ 5.8, function() CinematicFixtures:Fire(nil) end },
	},
}

DEFS.DishFixed = {
	shots = {
		{ t0 = 0, t1 = 6, grade = "space", light = "CinSpace", lightT = 0.2, noise = 0.008, pos = { function() return dishPos() + V(40, 25, -45) end, function() return dishPos() + V(28, 18, -32) end },
			look = { dishPos }, fov = { 44, 36 } },
	},
	events = {
		{ 0, function()
			letterbox(true, 0.4)
			greenGlow(dishPos())
			sound("Hum", { Volume = 0.3 }, 5)
		end },
		{ 1, function() caption("dish aligned.", 2) end },
		{ 3.4, function() caption("carrier acquired. faint. real.", 2.4) end },
	},
}

----------------------------------------------------------------------------
-- Ship arrival (night 1, second anomaly): slow reveal, its lights sweep the interior, AURA goes
-- quiet, shake builds, and the silhouette slides across Earth.
----------------------------------------------------------------------------
DEFS.Dream2 = {
	shots = {
		{ t0 = 0, t1 = 4.5, safe = true, noise = 0.02, grade = "cold", pos = { V(-138, 34, -64), V(-143, 34, -62) }, look = { V(-176, 33, -50), V(-176, 34, -52) }, fov = { 60, 56 } },
		{
			t0 = 4.5, t1 = 8.5, safe = true, noise = 0.05, grade = "cold",
			pos = { V(-148, 34, -60), V(-157, 34, -57), V(-164, 34.5, -55) },
			look = function(u)
				local s = shipPos()
				local target = if s and s.X > -520 then s else WEST
				return V(-250, 38, -40):Lerp(target, smooth(u * 1.4))
			end,
			fov = { 55, 32 },
		},
		{
			t0 = 8.5, t1 = 12, grade = "space", noise = 0.09, roll = 0.12,
			pos = {
				function()
					local s = shipPos() or WEST
					return s + (s - EARTH).Unit * 170 + V(0, 12, 0)
				end,
				function()
					local s = shipPos() or WEST
					return s + (s - EARTH).Unit * 120 + V(0, 8, 0)
				end,
			},
			look = function()
				return EARTH
			end,
			fov = { 40, 34 },
		},
	},
	events = {
		{ 0, function()
			letterbox(true, 0.6)
			sound("Drone", { Volume = 0.25 }, 12)
			-- two searchlights outside the west windows, sweeping the dark gallery
			for i, o in { V(-190, 38, -62), V(-190, 32, -40) } do
				local rig = fxPart(o)
				local s = Instance.new("SpotLight")
				s.Color, s.Range, s.Angle, s.Brightness, s.Shadows = Color3.fromRGB(200, 225, 255), 60, 22, 7, true
				s.Face = Enum.NormalId.Front
				s.Parent = rig
				task.spawn(function()
					local t0 = os.clock()
					while rig.Parent do
						local t = os.clock() - t0
						local target = V(-130, 32 + math.sin(t * 0.7 + i) * 3, -50 + math.sin(t * 0.55 + i * 2) * 26)
						rig.CFrame = CFrame.lookAt(o, target)
						task.wait()
					end
				end)
			end
		end },
		{ 1.2, function() caption("light, moving across the walls.", 2.6) end },
		{ 4, function() sound("Rumble", { Volume = 0.25 }, 3) end },
		{ 5.2, function() caption("aura?", 1.6) end },
		{ 7, function() caption("aura is not answering.", 2) end },
		{ 8.5, function() sound("Rumble", { Volume = 0.5, PlaybackSpeed = 0.8 }, 3.5) end },
		{ 9.6, function() caption("it's between you and earth.", 2.2) end },
	},
}

for id, def in DEFS do
	table.sort(def.events, function(a, b) return a[1] < b[1] end)
	local last = def.shots[#def.shots].t1
	local reg = Registry[id]
	if reg and math.abs(reg.duration - last) > 0.05 then
		warn(("[Cinematics] %s shots end at %.2fs but registry duration is %.2fs"):format(id, last, reg.duration))
	end
end

----------------------------------------------------------------------------
-- Player
----------------------------------------------------------------------------
local grade -- ColorCorrection that exists only while a cinematic runs
local cur -- { id, def, t, dur, skippable, paused, shotIdx, resolved, nextEvent, selfEnd, started }
local renderBound = false

local function resolve(list)
	if type(list) == "function" then
		return list
	end
	local out = {}
	for i, p in list do
		out[i] = if type(p) == "function" then p() else p
	end
	return out
end

local function finish(skipped)
	if not cur then
		return
	end
	local id = cur.id
	cur = nil
	if renderBound then
		RunService:UnbindFromRenderStep("AuroraCinematic")
		renderBound = false
	end
	for _, p in props do
		p:Destroy()
	end
	table.clear(props)
	stopSounds()
	clearText()
	letterbox(false, 0.6)
	black(0, if skipped then 0.5 else 0.8)
	if grade then
		local g = grade
		grade = nil
		tw(g, 0.8, { TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0 })
		task.delay(0.85, g.Destroy, g)
	end
	CinematicFixtures:Fire(nil)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Custom
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
	cam.FieldOfView = 70
	getUi().gui.Enabled = true -- keep bars animating out; the gui is harmless when empty
	CinematicActive:Fire(false, id)
end

local function step(dt)
	local c = cur
	if not c then
		return
	end
	if not c.paused then
		c.t += dt
	end
	local t = c.t
	-- events
	while c.nextEvent <= #c.def.events and c.def.events[c.nextEvent][1] <= t do
		local fn = c.def.events[c.nextEvent][2]
		c.nextEvent += 1
		task.spawn(function()
			local ok, err = pcall(fn)
			if not ok then
				warn("[Cinematics] event failed:", c.id, err)
			end
		end)
	end
	-- shot (hold the last frame past the end until the server's CinematicEnd)
	local shots = c.def.shots
	local idx = #shots
	for i, s in shots do
		if t < s.t1 then
			idx = i
			break
		end
	end
	local s = shots[idx]
	if c.shotIdx ~= idx then
		c.shotIdx = idx
		c.pos = resolve(s.pos)
		c.look = resolve(s.look)
		if grade and s.grade and GRADES[s.grade] then
			tw(grade, 0.6, GRADES[s.grade])
		end
		if s.light ~= nil then
			CinematicPreset:Fire(s.light or nil, s.lightT)
		end
	end
	local u = smooth((t - s.t0) / math.max(s.t1 - s.t0, 0.01))
	local pos = spline(c.pos, u)
	local look = if type(c.look) == "function" then c.look(u) else spline(c.look, u)
	if s.safe then
		local d = pos - look
		if d.Magnitude > 0.5 then
			local hit = workspace:Raycast(look, d, rayParams())
			if hit then
				pos = hit.Position - d.Unit * 0.8
			end
		end
	end
	local now = os.clock()
	local n = s.noise or 0
	local cf = CFrame.lookAt(pos, look)
		* CFrame.Angles(
			math.noise(now * 0.9, 1.3) * n,
			math.noise(now * 0.8, 4.1) * n,
			math.noise(now * 0.5, 7.7) * n * 0.5 + (s.roll or 0) * u
		)
	local cam = workspace.CurrentCamera
	cam.CameraType = Enum.CameraType.Scriptable
	cam.CFrame = cf
	cam.FieldOfView = s.fov[1] + (s.fov[2] - s.fov[1]) * u
	-- GameOver has no CinematicEnd: end it ourselves
	if c.selfEnd and t >= c.dur then
		finish(false)
	elseif t >= c.dur + 8 then
		finish(false) -- ponytail: safety net if CinematicEnd never arrives
	end
end

local function start(params)
	local id = params.id
	local def = DEFS[id]
	if not def then
		return
	end
	finish(true)
	local reg = Registry[id] or {}
	cur = {
		id = id,
		def = def,
		t = 0,
		dur = tonumber(params.duration) or reg.duration or def.shots[#def.shots].t1,
		skippable = params.skippable == true,
		selfEnd = reg.selfEnd == true or def.selfEnd == true, -- Refill: server never sends CinematicEnd
		paused = false,
		nextEvent = 1,
	}
	local u = getUi()
	u.gui.Enabled = true
	u.skip.Text = if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "hold to skip" else "press E to skip"
	tw(u.skip, 0.6, { TextTransparency = if cur.skippable then 0.35 else 1 })
	grade = Instance.new("ColorCorrectionEffect")
	grade.Name = "CIN_Grade"
	grade.Parent = Lighting
	CinematicActive:Fire(true, id)
	RunService:BindToRenderStep("AuroraCinematic", Enum.RenderPriority.Camera.Value + 2, step)
	renderBound = true
end

----------------------------------------------------------------------------
-- Hold to skip (Space / Enter / gamepad A / touch hold)
----------------------------------------------------------------------------
local HOLD = 0.9
local holding = {}
local holdStart
local sentSkip = false
local function anyHeld()
	return next(holding) ~= nil
end
local function press(key)
	if not (cur and cur.skippable) then
		return
	end
	holding[key] = true
	holdStart = holdStart or os.clock()
end
local function release(key)
	holding[key] = nil
	if not anyHeld() then
		holdStart = nil
		if ui then
			tw(ui.bar, 0.2, { Size = UDim2.fromOffset(0, 2) })
		end
	end
end
local SKIP_KEYS = { [Enum.KeyCode.Space] = true, [Enum.KeyCode.E] = true, [Enum.KeyCode.Return] = true, [Enum.KeyCode.ButtonA] = true }
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.E then
		-- Arduino console can't hold: one E tap skips.
		if cur and cur.skippable and not cur.paused and not sentSkip then
			sentSkip = true
			Remotes.RequestAction:FireServer("SkipCinematic")
			task.delay(1, function()
				sentSkip = false
			end)
		end
	elseif SKIP_KEYS[input.KeyCode] then
		press(input.KeyCode)
	elseif input.UserInputType == Enum.UserInputType.Touch then
		press(input)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if SKIP_KEYS[input.KeyCode] then
		release(input.KeyCode)
	elseif input.UserInputType == Enum.UserInputType.Touch then
		release(input)
	end
end)
RunService.Heartbeat:Connect(function()
	if not (holdStart and cur and cur.skippable and not cur.paused) then
		return
	end
	local a = math.clamp((os.clock() - holdStart) / HOLD, 0, 1)
	getUi().bar.Size = UDim2.fromOffset(180 * a, 2)
	if a >= 1 and not sentSkip then
		sentSkip = true
		Remotes.RequestAction:FireServer("SkipCinematic")
		task.delay(1, function()
			sentSkip = false
		end)
		table.clear(holding)
		holdStart = nil
	end
end)

----------------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------------
Remotes:WaitForChild("PlayCue").OnClientEvent:Connect(function(cue, params)
	params = if type(params) == "table" then params else {}
	if cue == "Cinematic" then
		start(params)
	elseif cue == "CinematicEnd" then
		if cur and (params.id == nil or params.id == cur.id) then
			finish(params.skipped == true)
		end
	end
end)

local ENDERS = { MainMenu = true, GameOver = true, Restart = true }
Remotes:WaitForChild("StateChanged").OnClientEvent:Connect(function(state, payload)
	payload = if type(payload) == "table" then payload else {}
	if type(payload.operatorName) == "string" and payload.operatorName ~= "" then
		operatorName = payload.operatorName
	end
	if not cur then
		return
	end
	if state == "Pause" then
		cur.paused = true
		return
	end
	cur.paused = false -- resumed (payload.resumed) or any real state change
	if ENDERS[state] and not (state == "GameOver" and cur.id == "GameOver") then
		finish(true)
	end
end)

player.CharacterAdded:Connect(function()
	if cur and cur.id ~= "GameOver" then
		cur.shotIdx = nil -- re-resolve player-relative points on respawn
	end
end)
