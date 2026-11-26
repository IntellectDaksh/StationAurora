--!nonstrict
-- Minigames: client side of objective minigames (contract: GameStateManager header).
-- PlayCue("Minigame", {objectiveId, kind, params}) opens one; the result goes back via
-- RequestObjectiveComplete(id, {success = bool, ...}). Every kind is finishable with
--   keyboard: WASD / arrows + Space / Enter (digits for codes), Esc closes
--   gamepad:  left stick / D-pad (+ LB / RB) + A, B closes
--   mouse / touch: on-screen buttons and drags
-- Closing (Esc / B / X button, pause, state change) sends nothing; the player re-uses the prompt.
-- Also applies DreamEvents `object` to each AuroraPrompt's ObjectText (server leaves it blank).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local CollectionService = game:GetService("CollectionService")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayCue = Remotes:WaitForChild("PlayCue")
local StateChanged = Remotes:WaitForChild("StateChanged")
local RequestObjectiveComplete = Remotes:WaitForChild("RequestObjectiveComplete")
local DreamEvents = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("DreamEvents"))
local StationAudio = ReplicatedStorage:WaitForChild("StationAudio", 10)
local FX = ReplicatedStorage:WaitForChild("AuroraFX", 10)
local FXSounds = FX and FX:FindFirstChild("Sounds")

local C = {
	bg = Color3.fromRGB(8, 12, 16),
	panel = Color3.fromRGB(12, 18, 24),
	well = Color3.fromRGB(4, 7, 10),
	bgHi = Color3.fromRGB(18, 30, 40),
	sel = Color3.fromRGB(28, 70, 96),
	cyan = Color3.fromRGB(90, 200, 255),
	amber = Color3.fromRGB(255, 170, 60),
	red = Color3.fromRGB(255, 70, 70),
	redDim = Color3.fromRGB(90, 22, 22),
	green = Color3.fromRGB(80, 230, 140),
	water = Color3.fromRGB(60, 150, 230),
	text = Color3.fromRGB(222, 236, 245),
	dim = Color3.fromRGB(120, 142, 158),
	off = Color3.fromRGB(22, 17, 10),
}
local MONO = Enum.Font.Code
local HEAD = Enum.Font.GothamMedium
local LEFT, CENTER = Enum.TextXAlignment.Left, Enum.TextXAlignment.Center
local BEEP = "SFX Button Beep"
local LATENCY_PAD = 0.35 -- server measures minTime from its own clock; send a little late
local PLAY_STATES = { Reality = true, Objectives = true }

----------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------
local function new(class: string, props: { [string]: any })
	local o = Instance.new(class)
	local parent = props.Parent
	props.Parent = nil
	for k, v in props do
		(o :: any)[k] = v
	end
	if parent then
		o.Parent = parent
	end
	return o
end

local function corner(o: Instance, r: UDim?)
	new("UICorner", { CornerRadius = r or UDim.new(0, 4), Parent = o })
end

local function round(o: Instance)
	new("UICorner", { CornerRadius = UDim.new(0.5, 0), Parent = o })
end

local function stroke(o: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return new("UIStroke", {
		Color = color or C.cyan,
		Thickness = thickness or 1,
		Transparency = transparency or 0.35,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = o,
	})
end

local function label(parent, text, x, y, w, h, size, color, font, align)
	return new("TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		TextSize = size or 14,
		TextColor3 = color or C.text,
		Font = font or MONO,
		TextXAlignment = align or LEFT,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = true,
		Parent = parent,
	})
end

-- Buttons grow to a 44px minimum around their own centre (touch targets); logic owns colours/stroke,
-- so hover only lifts BackgroundTransparency.
local function button(parent, text, x, y, w, h, size)
	if h < 44 then
		y, h = y - (44 - h) / 2, 44
	end
	if w < 44 then
		x, w = x - (44 - w) / 2, 44
	end
	local b = new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = C.bgHi,
		BackgroundTransparency = 0.15,
		Text = text,
		TextSize = size or 16,
		TextColor3 = C.text,
		Font = HEAD,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.fromOffset(w, h),
		Parent = parent,
	})
	corner(b, UDim.new(0, 6))
	stroke(b, C.cyan, 1, 0.5)
	b.MouseEnter:Connect(function()
		b.BackgroundTransparency = 0
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundTransparency = 0.15
	end)
	return b
end

-- Invisible button over an area: reliable pointer capture for drags.
local function hitArea(parent)
	return new("TextButton", {
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
		Parent = parent,
	})
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

local function findSound(name: string): Sound?
	local s = (StationAudio and StationAudio:FindFirstChild(name)) or (FXSounds and FXSounds:FindFirstChild(name))
	return if s and s:IsA("Sound") then s else nil
end

-- Raw screen position (IgnoreGuiInset space) of a pointer input.
local function screenPos(input: InputObject): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(input.Position.X, input.Position.Y) + inset
end

local function missionDay(): string
	local d = tonumber(player:GetAttribute("MissionDay")) or 212
	return string.format("MISSION DAY %d", d)
end

local function liveStat(name: string): number
	local folder = player:FindFirstChild("StationState")
	local nv = folder and folder:FindFirstChild(name)
	return if nv and nv:IsA("NumberValue") then nv.Value else 100
end

----------------------------------------------------------------------------
-- Shell UI
----------------------------------------------------------------------------
local gui = new("ScreenGui", {
	Name = "MinigameGui",
	DisplayOrder = 95,
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})
local shade = new("Frame", {
	Name = "Shade",
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 0.45,
	Size = UDim2.fromScale(1, 1),
	Active = true,
	Visible = false,
	Parent = gui,
})
local panel = new("Frame", {
	Name = "Panel",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(600, 400),
	BackgroundColor3 = C.bg,
	BackgroundTransparency = 0.04,
	Parent = shade,
})
corner(panel, UDim.new(0, 6))
local panelStroke = stroke(panel, C.cyan, 1, 0.2)
-- header accent tick (the design language's one cyan mark)
new("Frame", { BackgroundColor3 = C.cyan, BorderSizePixel = 0, Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(28, 2), Parent = panel })
local uiScale = new("UIScale", { Parent = panel })
-- Modal frees the mouse if the camera ever locks it (shift-lock / first person).
new("TextButton", { Modal = true, BackgroundTransparency = 1, Text = "", Size = UDim2.fromOffset(0, 0), Parent = panel })
-- Header: kind as a small cyan kicker, objective as the title, status chip, 44px close.
local title = label(panel, "", 20, 10, 360, 14, 11, C.cyan, HEAD)
local subtitle = label(panel, "", 20, 25, 380, 22, 17, C.text, HEAD)
subtitle.TextTruncate = Enum.TextTruncate.AtEnd
subtitle.TextWrapped = false
local closeBtn = button(panel, "X", 536, 4, 44, 44, 15)
closeBtn.BackgroundTransparency = 1
closeBtn.TextColor3 = C.dim
new("Frame", { BackgroundColor3 = Color3.new(1, 1, 1), BackgroundTransparency = 0.88, BorderSizePixel = 0, Position = UDim2.fromOffset(20, 52), Size = UDim2.fromOffset(560, 1), Parent = panel })
local chip = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromOffset(528, 26), Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, BackgroundColor3 = C.well, Parent = panel })
round(chip)
local chipStroke = stroke(chip, C.cyan, 1, 0.6)
new("UIPadding", { PaddingLeft = UDim.new(0, 18), PaddingRight = UDim.new(0, 10), Parent = chip })
local chipDot = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, -10, 0.5, 0), Size = UDim2.fromOffset(5, 5), BackgroundColor3 = C.cyan, BorderSizePixel = 0, Parent = chip })
round(chipDot)
local chipText = new("TextLabel", { BackgroundTransparency = 1, Text = "LIVE", Font = HEAD, TextSize = 10, TextColor3 = C.cyan, Size = UDim2.fromScale(0, 1), AutomaticSize = Enum.AutomaticSize.X, Parent = chip })
TweenService:Create(chipDot, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.8 }):Play()
-- chip mirrors the result colour finish() already paints on the panel stroke (no logic hook needed)
panelStroke:GetPropertyChangedSignal("Color"):Connect(function()
	local c = panelStroke.Color
	chipText.Text = if c == C.green then "COMPLETE" elseif c == C.red then "FAILED" else "LIVE"
	chipText.TextColor3, chipDot.BackgroundColor3, chipStroke.Color = c, c, c
end)
local body = new("Frame", { Name = "Body", BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 58), Size = UDim2.fromOffset(560, 260), Parent = panel })
local status = label(panel, "", 20, 322, 560, 24, 15, C.text, HEAD, CENTER)
local hint = label(panel, "", 20, 352, 560, 36, 13, C.dim, Enum.Font.Gotham, CENTER)

local function updateScale()
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	uiScale.Scale = math.clamp(math.min((vp.X - 24) / 600, (vp.Y - 24) / 400), 0.45, 1.35)
end
local vpConn
local function hookCamera()
	if vpConn then
		vpConn:Disconnect()
	end
	local cam = workspace.CurrentCamera
	if cam then
		vpConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
end
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
hookCamera()

local function inputKind(): string
	local t = UserInputService:GetLastInputType()
	if t == Enum.UserInputType.Touch then
		return "touch"
	elseif string.find(t.Name, "Gamepad") then
		return "pad"
	end
	return "kb"
end

----------------------------------------------------------------------------
-- Session
----------------------------------------------------------------------------
local cur = nil -- open minigame session
local curState = nil
local objectiveDone: { [string]: boolean } = {}
local shakeMag = 0
local stick = Vector2.zero
local stickDir: Vector2? = nil
local held: { [Enum.KeyCode]: Vector2 } = {}
local repeatDir: Vector2? = nil
local repeatAt = 0
local controls = nil

local function sfx(name: string, volume: number?, pitch: number?)
	local src = findSound(name)
	if not src then
		return nil
	end
	local s = src:Clone()
	s.Looped = false
	s.Volume = volume or 0.4
	s.PlaybackSpeed = pitch or 1
	s.Parent = gui
	s:Play()
	Debris:AddItem(s, 8)
	return s
end

local function refreshHint()
	local h = cur and cur.hints
	hint.Text = if h then (h[inputKind()] or h.kb or "") else ""
end
UserInputService.LastInputTypeChanged:Connect(refreshHint)

local function getControls()
	if controls == nil then
		local ok, res = pcall(function()
			local ps = player:WaitForChild("PlayerScripts", 5)
			local pm = ps and ps:WaitForChild("PlayerModule", 5)
			return pm and require(pm):GetControls()
		end)
		controls = if ok and res then res else false
	end
	return controls or nil
end

local function lockPlayer(on: boolean)
	local ctl = getControls()
	if ctl then
		pcall(function()
			if on then
				ctl:Disable()
			else
				ctl:Enable()
			end
		end)
	end
	player:SetAttribute("MinigameOpen", on)
	pcall(function()
		ProximityPromptService.Enabled = not on
	end)
	if on then
		GuiService.SelectedObject = nil
	end
end

local ACTION = "AuroraMinigame"
local close -- forward

local function doClose()
	local c = cur
	if not c then
		return
	end
	cur = nil
	for _, conn in c.conns do
		conn:Disconnect()
	end
	ContextActionService:UnbindAction(ACTION)
	held, stick, stickDir, repeatDir = {}, Vector2.zero, nil, nil
	body:ClearAllChildren()
	-- exit: quick fade + drop, then hide (skipped if another minigame opened meanwhile)
	TweenService:Create(shade, TweenInfo.new(0.16), { BackgroundTransparency = 1 }):Play()
	TweenService:Create(uiScale, TweenInfo.new(0.16, Enum.EasingStyle.Quint, Enum.EasingDirection.In), { Scale = uiScale.Scale * 0.96 }):Play()
	task.delay(0.16, function()
		if not cur then
			shade.Visible = false
			updateScale()
		end
	end)
	shakeMag = 0
	panel.Position = UDim2.fromScale(0.5, 0.5)
	lockPlayer(false)
end
close = doClose

local function finish(c, success: boolean, extra: { [string]: any }?)
	if c.done or cur ~= c then
		return
	end
	c.done = true
	panelStroke.Color = if success then C.green else C.red
	panelStroke.Transparency = 0
	if success then
		if status.TextColor3 ~= C.green then
			status.Text = "COMPLETE"
			status.TextColor3 = C.green
		end
		sfx(BEEP, 0.35, 1.5)
		task.delay(0.12, sfx, BEEP, 0.35, 2)
	else
		if status.TextColor3 ~= C.red then
			status.Text = "FAILED"
			status.TextColor3 = C.red
		end
		shakeMag = math.max(shakeMag, 10)
		sfx("LowStinger", 0.3, 1.2)
	end
	local hold = 0.9
	if success then
		hold = math.max(hold, c.minTime + LATENCY_PAD - (os.clock() - c.openedAt))
	end
	task.delay(hold, function()
		if cur ~= c then
			return -- closed meanwhile (pause / state change): nothing is sent
		end
		local data = extra or {}
		data.success = success
		RequestObjectiveComplete:FireServer(c.id, data)
		close()
	end)
end

local function makeApi(c)
	local api = {}
	function api.conn(x)
		table.insert(c.conns, x)
		return x
	end
	function api.alive(): boolean
		return cur == c and not c.done
	end
	function api.after(t: number, fn)
		task.delay(t, function()
			if cur == c then
				fn()
			end
		end)
	end
	function api.status(text: string, color: Color3?)
		if cur == c then
			status.Text = text
			status.TextColor3 = color or C.text
		end
	end
	function api.hints(h)
		c.hints = h
		refreshHint()
	end
	function api.title(t: string)
		title.Text = t
	end
	api.sfx = sfx
	function api.loop(name: string, volume: number, pitch: number?): Sound
		local src = findSound(name)
		local s = if src then src:Clone() else Instance.new("Sound")
		s.Looped = true
		s.Volume = volume
		s.PlaybackSpeed = pitch or 1
		s.Parent = body -- destroyed with the minigame
		s:Play()
		return s
	end
	function api.shake(m: number)
		shakeMag = math.max(shakeMag, m)
	end
	function api.finish(success: boolean, extra)
		finish(c, success, extra)
	end
	function api.stick(): Vector2
		return stick
	end
	function api.scale(): number
		return uiScale.Scale
	end
	-- Pointer drag (mouse or one touch) that started on `obj`.
	function api.drag(obj: GuiObject, onStart, onMove, onEnd)
		local active: InputObject? = nil
		local function isMouse(i: InputObject)
			return i.UserInputType == Enum.UserInputType.MouseButton1
		end
		api.conn(obj.InputBegan:Connect(function(input)
			if not api.alive() or active then
				return
			end
			if isMouse(input) or input.UserInputType == Enum.UserInputType.Touch then
				active = input
				if onStart then
					onStart(screenPos(input))
				end
			end
		end))
		api.conn(UserInputService.InputChanged:Connect(function(input)
			if not active or not api.alive() then
				return
			end
			if (isMouse(active) and input.UserInputType == Enum.UserInputType.MouseMovement) or input == active then
				if onMove then
					onMove(screenPos(input))
				end
			end
		end))
		api.conn(UserInputService.InputEnded:Connect(function(input)
			if active and (input == active or (isMouse(active) and isMouse(input))) then
				active = nil
				if onEnd then
					onEnd()
				end
			end
		end))
	end
	-- Press-and-hold on a button (mouse or touch).
	function api.hold(obj: GuiObject, onDown, onUp)
		api.drag(obj, function()
			onDown()
		end, nil, onUp)
	end
	return api
end

----------------------------------------------------------------------------
-- Minigame kinds. Each builder(body 560x260, params, api) returns a table with optional
-- dir(v, fromStick) / confirm(down, keyCode) / digit(n) / back() / update(dt, axis),
-- and repeatDirs = true for menu-like navigation.
----------------------------------------------------------------------------
local Games = {}

-- R_LSReadout: match a live reference waveform with amplitude + frequency sliders.
Games.Calibrate = function(body, params, api)
	api.title("LIFE SUPPORT // SENSOR CALIBRATION")
	api.hints({
		kb = "W / S pick slider   A / D adjust   Esc close",
		pad = "Up / down pick slider   Left / right adjust   B close",
		touch = "Drag both sliders until the traces overlap",
	})
	api.status("Match your trace to the reference waveform", C.dim)
	local PTS, SW, SH = 64, 520, 150
	local scope = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(20, 0), Size = UDim2.fromOffset(SW, SH), ClipsDescendants = true, Parent = body })
	corner(scope)
	stroke(scope, C.cyan, 1, 0.6)
	new("Frame", { BackgroundColor3 = C.cyan, BackgroundTransparency = 0.85, BorderSizePixel = 0, Position = UDim2.new(0, 0, 0.5, 0), Size = UDim2.new(1, 0, 0, 1), Parent = scope })
	local refDots, myDots = {}, {}
	for i = 1, PTS do
		refDots[i] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.dim, BackgroundTransparency = 0.35, BorderSizePixel = 0, Size = UDim2.fromOffset(3, 3), Parent = scope })
		myDots[i] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 4), ZIndex = 2, Parent = scope })
		round(myDots[i])
	end
	local target = { 0.25 + math.random() * 0.65, 0.2 + math.random() * 0.7 }
	local val = {}
	for i = 1, 2 do
		repeat
			val[i] = math.random()
		until math.abs(val[i] - target[i]) > 0.3
	end
	local sel, t, lockT, locked = 1, 0, 0, false
	local sliders = {}
	for i, name in { "AMPLITUDE", "FREQUENCY" } do
		local y = 160 + (i - 1) * 34
		local lbl = label(body, name, 20, y, 110, 24, 13, C.dim)
		local track = new("Frame", { BackgroundColor3 = C.panel, Position = UDim2.fromOffset(130, y + 8), Size = UDim2.fromOffset(340, 8), Parent = body })
		corner(track)
		local st = stroke(track, C.cyan, 1, 0.7)
		local knob = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.text, Position = UDim2.fromScale(val[i], 0.5), Size = UDim2.fromOffset(16, 16), ZIndex = 3, Parent = track })
		round(knob)
		local readout = label(body, "", 480, y, 60, 24, 13, C.text, MONO)
		sliders[i] = { lbl = lbl, knob = knob, st = st, readout = readout }
		local function setFrom(pos: Vector2)
			sel = i
			val[i] = math.clamp((pos.X - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		end
		api.drag(hitArea(track), setFrom, setFrom)
	end
	local lockBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(20, 234), Size = UDim2.fromOffset(520, 4), Parent = body })
	corner(lockBack)
	local lockFill = new("Frame", { BackgroundColor3 = C.green, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = lockBack })
	corner(lockFill)
	local function wave(dots, amp, freq, phase)
		local cyc = 1 + freq * 4
		for i, dot in dots do
			local x = (i - 1) / (PTS - 1)
			dot.Position = UDim2.fromOffset(x * SW, SH / 2 - amp * (SH * 0.42) * math.sin(2 * math.pi * cyc * x + phase))
		end
	end
	local g = {}
	function g.dir(d: Vector2)
		if d.Y ~= 0 then
			sel = 3 - sel
			api.sfx(BEEP, 0.12, 1.2)
		end
	end
	function g.confirm(down: boolean)
		if down then
			sel = 3 - sel
		end
	end
	function g.update(dt: number, axis: Vector2)
		if locked then
			return
		end
		t += dt
		val[sel] = math.clamp(val[sel] + axis.X * 0.3 * dt, 0, 1)
		local A = math.clamp(target[1] + math.noise(t * 0.25, 3.1) * 0.08, 0.1, 1)
		local F = math.clamp(target[2] + math.noise(t * 0.25, 7.7) * 0.08, 0, 1)
		local err = math.max(math.abs(val[1] - A), math.abs(val[2] - F))
		local ok = err < 0.045
		wave(refDots, A, F, t * 2.2)
		wave(myDots, val[1], val[2], t * 2.2)
		for i, sl in sliders do
			sl.knob.Position = UDim2.fromScale(val[i], 0.5)
			sl.st.Transparency = if i == sel then 0 else 0.7
			sl.lbl.TextColor3 = if i == sel then C.cyan else C.dim
			sl.readout.Text = string.format("%03d", math.floor(val[i] * 999))
		end
		for _, dot in myDots do
			dot.BackgroundColor3 = if ok then C.green else C.cyan
		end
		lockT = if ok then lockT + dt / 1.5 else math.max(0, lockT - dt)
		lockFill.Size = UDim2.fromScale(math.clamp(lockT, 0, 1), 1)
		if lockT >= 1 then
			locked = true
			api.status("SENSORS CALIBRATED // SCRUBBERS NOMINAL", C.green)
			api.finish(true)
		end
	end
	return g
end

-- R_StatusLog: pick the entries that match the live (glitchy) sensor feed.
Games.LogReport = function(body, params, api)
	api.title("STATUS LOG // " .. missionDay())
	api.hints({
		kb = "W / S  line     A / D  pick     Enter  confirm     Esc  close",
		pad = "Up / down  line     Left / right  pick     A  confirm     B  close",
		touch = "Tap the readings that match the live feed, then File report",
	})
	api.status("File the readings below exactly as shown", C.dim)
	-- Snapshot once at open: O2 drifts every tick, so grading against a fresh read
	-- later would always disagree with the options generated from the open-time
	-- value. Grade and display against this frozen snapshot instead.
	local ROWS = {
		{ key = "Oxygen", name = "O2", label = "OXYGEN %" },
		{ key = "Power", name = "POWER", label = "POWER %" },
		{ key = "HullIntegrity", name = "HULL", label = "HULL %" },
	}
	local snapshot = {}
	for _, d in ROWS do
		snapshot[d.key] = math.floor(liveStat(d.key) + 0.5)
	end
	local function live(key: string): number
		return snapshot[key]
	end
	local TOLERANCE = 2
	local feed = label(body, "", 0, 0, 560, 28, 16, C.cyan, MONO, CENTER)
	feed.BackgroundTransparency = 0
	feed.BackgroundColor3 = C.well
	corner(feed)
	stroke(feed, C.cyan, 1, 0.6)
	feed.Text = string.format("READINGS TO FILE     O2 %d     POWER %d     HULL %d", snapshot.Oxygen, snapshot.Power, snapshot.HullIntegrity)
	local rows = {}
	local focus = 1
	local mistakes = 0
	local render, file
	for r, def in ROWS do
		local y = 42 + (r - 1) * 50
		local lab = label(body, def.label, 10, y, 130, 40, 15, C.text)
		local correct = live(def.key)
		local vals = { correct }
		for _, o in shuffle({ -9, -6, -4, -3, 3, 4, 6, 9 }) do
			if #vals >= 3 then
				break
			end
			local v = math.clamp(correct + o, 0, 100)
			if not table.find(vals, v) then
				table.insert(vals, v)
			end
		end
		shuffle(vals)
		local row = { def = def, vals = vals, btns = {}, choice = nil, cursor = 1, label = lab, bad = false }
		for j, v in vals do
			local b = button(body, tostring(v), 150 + (j - 1) * 130, y, 116, 40, 18)
			row.btns[j] = b
			b.Activated:Connect(function()
				if not api.alive() then
					return
				end
				focus, row.choice, row.cursor, row.bad = r, j, j, false
				api.sfx(BEEP, 0.18, 1.3)
				render()
			end)
		end
		rows[r] = row
	end
	local fileBtn = button(body, "FILE REPORT", 150, 200, 376, 44, 18)
	fileBtn.Activated:Connect(function()
		if api.alive() then
			focus = 4
			file()
		end
	end)
	function render()
		for r, row in rows do
			for j, b in row.btns do
				local chosen = row.choice == j
				b.BackgroundColor3 = if chosen and row.bad then C.redDim elseif chosen then C.sel else C.bgHi
				local s = b:FindFirstChildOfClass("UIStroke")
				local cursorHere = focus == r and row.cursor == j
				s.Transparency = if cursorHere then 0 else 0.6
				s.Color = if cursorHere then C.text else C.cyan
			end
			row.label.TextColor3 = if row.bad then C.red elseif focus == r then C.cyan else C.text
		end
		local fs = fileBtn:FindFirstChildOfClass("UIStroke")
		fs.Transparency = if focus == 4 then 0 else 0.5
		fs.Color = if focus == 4 then C.text else C.cyan
	end
	function file()
		for _, row in rows do
			if not row.choice then
				api.status("SELECT A READING FOR EVERY LINE", C.amber)
				api.shake(3)
				api.sfx(BEEP, 0.2, 0.7)
				return
			end
		end
		local wrong = {}
		for _, row in rows do
			row.bad = math.abs(row.vals[row.choice] - live(row.def.key)) > TOLERANCE
			if row.bad then
				table.insert(wrong, row.def.name)
			end
		end
		render()
		if #wrong == 0 then
			api.status("REPORT FILED // NOTHING TO REPORT", C.green)
			api.finish(true)
			return
		end
		mistakes += 1
		api.shake(6)
		api.sfx(BEEP, 0.3, 0.6)
		if mistakes >= 3 then
			api.status("LOG REJECTED", C.red)
			api.finish(false)
			return
		end
		api.status(string.format("MISMATCH: %s  (%d tries left)", table.concat(wrong, ", "), 3 - mistakes), C.red)
	end
	render()

	local g = { repeatDirs = true }
	function g.dir(d: Vector2)
		if d.Y ~= 0 then
			focus = math.clamp(focus - d.Y, 1, 4)
		elseif d.X ~= 0 and focus <= 3 then
			local row = rows[focus]
			row.cursor = (row.cursor - 1 + d.X) % 3 + 1
			row.choice, row.bad = row.cursor, false
		end
		api.sfx(BEEP, 0.1, 1.2)
		render()
	end
	function g.confirm(down: boolean)
		if not down then
			return
		end
		if focus == 4 then
			file()
		else
			local row = rows[focus]
			row.choice = row.choice or row.cursor
			row.bad = false
			focus += 1
			api.sfx(BEEP, 0.15, 1.3)
			render()
		end
	end
	return g
end

-- R_Hydroponics: hold to pour, release inside the green band. Overfill flushes the tray.
Games.WaterGauge = function(body, params, api)
	api.title("HYDROPONICS // IRRIGATION")
	api.hints({
		kb = "Hold E to pour, release in the green     Esc  close",
		pad = "Hold A to pour, release in the green     B  close",
		touch = "Hold POUR, release in the green",
	})
	api.status("Fill each tray into the green band", C.dim)
	local trays = math.clamp(math.floor(tonumber(params.trays) or 3), 1, 5)
	local SIZES = { 0.16, 0.13, 0.11, 0.1, 0.1 }
	local tank = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(60, 10), Size = UDim2.fromOffset(96, 230), ClipsDescendants = true, Parent = body })
	corner(tank)
	stroke(tank, C.cyan, 1, 0.4)
	local fill = new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), BackgroundColor3 = C.water, BorderSizePixel = 0, Parent = tank })
	local zone = new("Frame", { BackgroundColor3 = C.green, BackgroundTransparency = 0.72, BorderSizePixel = 0, ZIndex = 2, Parent = tank })
	local zTop = new("Frame", { BackgroundColor3 = C.green, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), ZIndex = 3, Parent = tank })
	local zBot = new("Frame", { BackgroundColor3 = C.green, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2), ZIndex = 3, Parent = tank })
	local trayLabel = label(body, "", 200, 6, 340, 26, 20, C.text, HEAD)
	local levelLabel = label(body, "", 200, 36, 340, 20, 14, C.dim)
	local icons = {}
	for i = 1, trays do
		local ic = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(200 + (i - 1) * 60, 68), Size = UDim2.fromOffset(50, 24), Parent = body })
		corner(ic)
		icons[i] = { frame = ic, stroke = stroke(ic, C.cyan, 1, 0.6) }
	end
	local pour = button(body, "HOLD TO POUR", 200, 130, 340, 90, 20)
	local hiss = api.loop("Static", 0, 0.5)
	local tray, level, pouring, pourT, draining, lo, hi = 1, 0, false, 0, false, 0, 0
	local function newZone()
		local size = SIZES[tray] or 0.1
		lo = 0.5 + math.random() * (0.88 - 0.5 - size)
		hi = lo + size
		zone.Position = UDim2.fromScale(0, 1 - hi)
		zone.Size = UDim2.fromScale(1, size)
		zTop.Position = UDim2.new(0, 0, 1 - hi, -1)
		zBot.Position = UDim2.new(0, 0, 1 - lo, -1)
		trayLabel.Text = string.format("TRAY %d / %d", tray, trays)
		for i, ic in icons do
			ic.stroke.Transparency = if i == tray then 0 else 0.6
		end
	end
	newZone()
	local function overflow()
		pouring, pourT, draining = false, 0, true
		icons[tray].frame.BackgroundColor3 = C.redDim
		api.status("OVERFLOW // TRAY FLUSHED, TRY AGAIN", C.red)
		api.shake(6)
		api.sfx("LowStinger", 0.2, 1.4)
	end
	local function release()
		if not pouring then
			return
		end
		pouring, pourT = false, 0
		if level >= lo and level <= hi then
			icons[tray].frame.BackgroundColor3 = C.green
			api.sfx(BEEP, 0.3, 1.5)
			if tray >= trays then
				api.status("RACK WATERED // THE BASIL'S COMING BACK", C.green)
				api.finish(true)
				return
			end
			api.status(string.format("TRAY %d WATERED", tray), C.green)
			tray += 1
			level = 0
			newZone()
		elseif level > hi then
			overflow()
		else
			api.status("NOT ENOUGH // KEEP POURING", C.amber)
		end
	end
	local g = {}
	function g.confirm(down: boolean)
		if down then
			if not draining and not pouring then
				pouring, pourT = true, 0
				icons[tray].frame.BackgroundColor3 = C.well
			end
		else
			release()
		end
	end
	api.hold(pour, function()
		g.confirm(true)
	end, function()
		if api.alive() then
			g.confirm(false)
		end
	end)
	function g.update(dt: number)
		if draining then
			level -= 0.9 * dt
			if level <= 0 then
				level, draining = 0, false
				api.status("Hold to pour again", C.dim)
			end
		elseif pouring and api.alive() then
			pourT += dt
			level += math.min(0.16 + pourT * 0.38, 0.75) * dt
			if level >= 1 then
				level = 1
				overflow()
			end
		else
			level = math.max(0, level - 0.03 * dt)
		end
		local inZone = level >= lo and level <= hi
		fill.Size = UDim2.fromScale(1, level)
		fill.BackgroundColor3 = if inZone then C.green elseif level > hi then C.amber else C.water
		zone.BackgroundTransparency = if inZone then 0.45 else 0.72
		hiss.Volume = if pouring then 0.1 else 0
		pour.BackgroundColor3 = if pouring then C.sel else C.bgHi
		levelLabel.Text = string.format("LEVEL %d%%     TARGET %d-%d%%", math.floor(level * 100), math.floor(lo * 100), math.floor(hi * 100))
	end
	return g
end

-- R_TaskBoard: the day's jobs type in; acknowledge each line. The last one is wrong.
Games.TaskBoard = function(body, params, api)
	api.title("TASK BOARD // " .. missionDay())
	api.hints({
		kb = "E / Enter  acknowledge     Esc  close",
		pad = "A  acknowledge     B  close",
		touch = "Tap ACK on each line",
	})
	api.status("Acknowledge each line", C.dim)
	local ITEMS = {
		{ time = "0600", text = "LIFE-SUPPORT READOUT", id = "R_LSReadout" },
		{ time = "0630", text = "MORNING STATUS LOG", id = "R_StatusLog" },
		{ time = "0700", text = "HYDROPONICS RACK", id = "R_Hydroponics" },
		{ time = "0800", text = "CREW CHECK-IN", fixed = "5 AWAY" },
		{ time = "0900", text = "CALL HOME", fixed = "PENDING", creepy = true },
	}
	local rows = {}
	local idx = 1
	local busy = false
	local ack
	for i, it in ITEMS do
		local fr = new("Frame", { BackgroundColor3 = C.panel, Position = UDim2.fromOffset(0, (i - 1) * 50), Size = UDim2.fromOffset(560, 44), Parent = body })
		corner(fr)
		local st = stroke(fr, C.cyan, 1, 0.85)
		label(fr, it.time, 12, 0, 60, 44, 15, C.dim)
		local tx = label(fr, "", 76, 0, 290, 44, 16, C.text)
		local sl = label(fr, "", 370, 0, 90, 44, 14, C.dim)
		local b = button(fr, "ACK", 466, 7, 84, 30, 14)
		b.Visible = false
		b.Activated:Connect(function()
			if api.alive() and idx == i then
				ack()
			end
		end)
		local status_, color = it.fixed, C.amber
		if it.id then
			local done = objectiveDone[it.id] == true
			status_, color = if done then "DONE" else "OPEN", if done then C.green else C.amber
		end
		rows[i] = { it = it, frame = fr, stroke = st, tx = tx, sl = sl, ack = b, typed = 0, statusText = status_, statusColor = color }
	end
	function ack()
		local row = rows[idx]
		if not row or busy then
			return
		end
		if row.typed < #row.it.text then
			row.typed = #row.it.text -- skip the typewriter
			return
		end
		row.ack.Text = "OK"
		row.ack.BackgroundColor3 = C.sel
		row.ack.TextColor3 = C.green
		api.sfx(BEEP, 0.25, 1.3)
		if row.it.creepy then
			busy = true
			row.tx.Text = "CALL HOME // LAST REPLY 1,096 DAYS AGO"
			row.tx.TextColor3 = C.red
			api.sfx("Static", 0.3, 1)
			api.shake(4)
			api.after(0.7, function()
				row.tx.Text = row.it.text
				row.tx.TextColor3 = C.text
				api.status("Same list as always.", C.green)
				api.finish(true)
			end)
			return
		end
		idx += 1
		if idx > #rows then
			api.finish(true)
		end
	end
	local t = 0
	local g = {}
	function g.confirm(down: boolean)
		if down then
			ack()
		end
	end
	function g.update(dt: number)
		t += dt
		for i, row in rows do
			local current = i == idx and not busy
			row.stroke.Transparency = if i == idx then 0.1 else 0.85
			row.frame.BackgroundTransparency = if i <= idx then 0 else 0.6
			if i == idx and row.typed < #row.it.text then
				row.typed = math.min(#row.it.text, row.typed + dt * 40)
			end
			if i <= idx and not (row.it.creepy and busy) then
				local n = math.floor(row.typed)
				local typing = n < #row.it.text
				row.tx.Text = string.sub(row.it.text, 1, n) .. (if typing and (t * 4) % 1 < 0.5 then "_" else "")
				row.sl.Text = if typing then "" else row.statusText
				row.sl.TextColor3 = row.statusColor
				if row.it.creepy and not typing then
					row.sl.TextTransparency = if (t * 1.5) % 1 < 0.5 then 0 else 0.6
				end
				row.ack.Visible = not typing
				row.ack.Active = current
			end
		end
	end
	return g
end

-- R_Distress: tune the dial until your wave matches the carrier, then enter the auth code.
Games.Transmit = function(body, params, api)
	api.title("COMMS // DISTRESS TRANSMITTER")
	local code = if type(params.code) == "string" then params.code else nil
	local phase = 1
	local HINT1 = {
		kb = "A / D  tune     Esc  close",
		pad = "Left stick / D-pad  tune     B  close",
		touch = "Drag the dial or hold < >  to tune",
	}
	local HINT2 = {
		kb = "Type the code     Enter  send     Backspace  delete",
		pad = "D-pad  move     A  press     B  close",
		touch = "Tap the code, then SEND",
	}
	api.hints(HINT1)
	api.status("Tune until your signal lines up with the carrier", C.dim)

	-- phase 1: tuning
	local p1 = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(560, 260), Parent = body })
	local osc = new("Frame", { BackgroundColor3 = C.well, Size = UDim2.fromOffset(560, 130), ClipsDescendants = true, Parent = p1 })
	corner(osc)
	stroke(osc, C.cyan, 1, 0.5)
	new("Frame", { BackgroundColor3 = C.cyan, BackgroundTransparency = 0.85, BorderSizePixel = 0, Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(1, 0, 0, 1), Parent = osc })
	label(osc, "CARRIER", 8, 4, 100, 14, 11, C.cyan)
	label(osc, "YOU", 8, 18, 100, 14, 11, C.amber)
	local N = 48
	local tDots, mDots = {}, {}
	for i = 1, N do
		tDots[i] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BackgroundTransparency = 0.45, BorderSizePixel = 0, Size = UDim2.fromOffset(4, 4), Parent = osc })
		mDots[i] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.amber, BorderSizePixel = 0, Size = UDim2.fromOffset(5, 5), ZIndex = 2, Parent = osc })
	end
	local freqLabel = label(p1, "", 0, 138, 290, 24, 16, C.text)
	label(p1, "SIGNAL", 300, 138, 60, 24, 12, C.dim)
	local sigBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(360, 146), Size = UDim2.fromOffset(200, 8), Parent = p1 })
	corner(sigBack)
	local sigFill = new("Frame", { BackgroundColor3 = C.amber, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = sigBack })
	corner(sigFill)
	local leftB = button(p1, "<", 0, 172, 58, 52, 22)
	local rightB = button(p1, ">", 502, 172, 58, 52, 22)
	local dial = new("Frame", { BackgroundColor3 = C.panel, Position = UDim2.fromOffset(68, 172), Size = UDim2.fromOffset(424, 52), ClipsDescendants = true, Parent = p1 })
	corner(dial)
	stroke(dial, C.cyan, 1, 0.5)
	label(dial, "DRAG TO TUNE", 0, 0, 424, 52, 11, C.dim, MONO, CENTER).TextTransparency = 0.4
	local ticks = {}
	for i = 1, 32 do
		ticks[i] = new("Frame", { AnchorPoint = Vector2.new(0.5, 1), BackgroundColor3 = C.cyan, BackgroundTransparency = if i % 4 == 0 then 0.2 else 0.6, BorderSizePixel = 0, Size = UDim2.fromOffset(2, if i % 4 == 0 then 22 else 12), Parent = dial })
	end
	new("Frame", { AnchorPoint = Vector2.new(0.5, 0), BackgroundColor3 = C.amber, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 2, 1, 0), ZIndex = 3, Parent = dial })
	label(p1, "CARRIER LOCK", 0, 234, 110, 20, 12, C.dim)
	local lockBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(110, 240), Size = UDim2.fromOffset(450, 8), Parent = p1 })
	corner(lockBack)
	local lockFill = new("Frame", { BackgroundColor3 = C.green, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = lockBack })
	corner(lockFill)

	local target = 2.2 + math.random() * 2.6
	local f = math.clamp(target + (if math.random() < 0.5 then -1 else 1) * (1.2 + math.random() * 0.6), 1, 6)
	local push, lockT, t = 0, 0, 0
	local static = api.loop("Static", 0.2, 1)
	api.hold(leftB, function()
		push = -1
	end, function()
		push = 0
	end)
	api.hold(rightB, function()
		push = 1
	end, function()
		push = 0
	end)
	local lastX: number? = nil
	api.drag(hitArea(dial), function(pos)
		lastX = pos.X
	end, function(pos)
		if lastX and phase == 1 then
			f = math.clamp(f + (pos.X - lastX) / api.scale() * 0.004, 1, 6)
			lastX = pos.X
		end
	end, function()
		lastX = nil
	end)

	-- phase 2: auth code keypad
	local p2 = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(560, 260), Visible = false, Parent = body })
	label(p2, "AUTH CODE REQUIRED", 0, 0, 260, 20, 13, C.dim)
	label(p2, if code then ("CODE  " .. code) else "CODE ON THE COMMS SCREEN", 0, 22, 260, 40, if code then 28 else 15, C.amber)
	label(p2, "ENTRY", 0, 84, 260, 18, 13, C.dim)
	local entryLbl = label(p2, "", 0, 104, 260, 56, 36, C.text)
	label(p2, "Also shown on the comms screen", 0, 170, 260, 18, 12, C.dim)
	local KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "DEL", "0", "SEND" }
	local kbtn = {}
	local sel = 1
	local entry = ""
	local mistakes = 0
	local press
	for i, k in KEYS do
		local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
		local b = button(p2, k, 290 + col * 90, row * 64, 80, 56, if #k > 1 then 15 else 22)
		kbtn[i] = b
		b.Activated:Connect(function()
			if api.alive() and phase == 2 then
				sel = i
				press(k)
			end
		end)
	end
	local function renderPad()
		local shown = {}
		for i = 1, 4 do
			shown[i] = string.sub(entry, i, i)
			if shown[i] == "" then
				shown[i] = "_"
			end
		end
		entryLbl.Text = table.concat(shown, " ")
		for i, b in kbtn do
			local s = b:FindFirstChildOfClass("UIStroke")
			s.Transparency = if i == sel then 0 else 0.5
			s.Color = if i == sel then C.text else C.cyan
		end
	end
	local function submit()
		if #entry < 4 then
			api.status("ENTER ALL 4 DIGITS", C.amber)
			api.shake(3)
			api.sfx(BEEP, 0.2, 0.7)
			return
		end
		if code and entry ~= code then
			mistakes += 1
			entry = ""
			renderPad()
			api.shake(7)
			api.sfx(BEEP, 0.3, 0.5)
			if mistakes >= 3 then
				api.status("AUTH LOCKOUT", C.red)
				api.finish(false)
			else
				api.status(string.format("AUTH REJECTED  (%d tries left)", 3 - mistakes), C.red)
			end
			return
		end
		api.status("DISTRESS SIGNAL SENT", C.green)
		api.sfx("Static", 0.25, 1.3)
		api.finish(true, { code = entry })
	end
	function press(k: string)
		if k == "SEND" then
			submit()
			return
		elseif k == "DEL" then
			entry = string.sub(entry, 1, -2)
		elseif #entry < 4 then
			entry ..= k
		end
		api.sfx(BEEP, 0.2, 1 + (tonumber(k) or 0) * 0.06)
		renderPad()
	end
	local function toPhase2()
		phase = 2
		f = target
		static:Stop()
		api.sfx(BEEP, 0.35, 1.7)
		api.status("CARRIER LOCKED // ENTER AUTH CODE", C.green)
		p1.Visible = false
		p2.Visible = true
		api.hints(HINT2)
		renderPad()
	end

	local g = { repeatDirs = true }
	function g.dir(d: Vector2)
		if phase ~= 2 then
			return
		end
		local col, row = (sel - 1) % 3, math.floor((sel - 1) / 3)
		col = math.clamp(col + d.X, 0, 2)
		row = math.clamp(row - d.Y, 0, 3)
		sel = row * 3 + col + 1
		api.sfx(BEEP, 0.08, 1.2)
		renderPad()
	end
	function g.confirm(down: boolean, key: Enum.KeyCode?)
		if not down or phase ~= 2 then
			return
		end
		if key == Enum.KeyCode.Return or key == Enum.KeyCode.KeypadEnter then
			submit()
		else
			press(KEYS[sel])
		end
	end
	function g.digit(n: number)
		if phase == 2 then
			press(tostring(n))
		end
	end
	function g.back()
		if phase == 2 then
			press("DEL")
		end
	end
	function g.update(dt: number, axis: Vector2)
		if phase ~= 1 then
			return
		end
		t += dt
		if api.alive() then
			f = math.clamp(f + (push + axis.X) * 0.7 * dt, 1, 6)
		end
		local d = math.abs(f - target)
		local matched = d < 0.07
		for i = 1, N do
			local x = (i - 1) / (N - 1)
			local jitter = (math.random() - 0.5) * math.min(d, 1) * 0.14
			tDots[i].Position = UDim2.fromScale(x, 0.5 - math.sin(x * target * math.pi * 2 + t * 2.4) * 0.32)
			mDots[i].Position = UDim2.fromScale(x, 0.5 - math.sin(x * f * math.pi * 2 + t * 2.4) * 0.32 + jitter)
			mDots[i].BackgroundColor3 = if matched then C.green else C.amber
		end
		for i, tk in ticks do
			tk.Position = UDim2.fromOffset((i * 16 - f * 90) % 512 - 44, 52)
		end
		local strength = math.clamp(1 - d / 2, 0, 1)
		sigFill.Size = UDim2.fromScale(strength, 1)
		sigFill.BackgroundColor3 = if matched then C.green elseif strength > 0.8 then C.cyan else C.amber
		static.Volume = 0.03 + 0.22 * math.clamp(d / 1.5, 0, 1)
		freqLabel.Text = string.format("FREQ  %.3f MHz", 121.5 + f * 3.137)
		lockT = if matched then lockT + dt else math.max(0, lockT - dt)
		lockFill.Size = UDim2.fromScale(math.clamp(lockT / 0.8, 0, 1), 1)
		if lockT >= 0.8 and api.alive() then
			toPhase2()
		end
	end
	return g
end

-- D1_Radar: tag each contact while the sweep lights it. The last one comes closer, then isn't there.
Games.RadarSweep = function(body, params, api)
	api.title("LONG-RANGE RADAR // SWEEP")
	api.hints({
		kb = "A / D  select contact     E  tag     Esc  close",
		pad = "Left / right  select     A  tag     B  close",
		touch = "Tap each contact while the sweep lights it",
	})
	api.status("Tag every contact while the sweep lights it", C.dim)
	local PERIOD, FADE = 2.2, 1.5
	local scr = new("Frame", { BackgroundColor3 = Color3.fromRGB(3, 12, 10), Position = UDim2.fromOffset(10, 8), Size = UDim2.fromOffset(240, 240), Parent = body })
	round(scr)
	stroke(scr, C.green, 1, 0.3)
	for _, s in { 0.33, 0.66 } do
		local ring = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(s, s), Parent = scr })
		round(ring)
		stroke(ring, C.green, 1, 0.8)
	end
	new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.green, BackgroundTransparency = 0.85, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0, 1), Parent = scr })
	new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.green, BackgroundTransparency = 0.85, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0, 1, 1, 0), Parent = scr })
	local sweeps = {}
	for k = 0, 4 do
		local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0, 2), Parent = scr })
		new("Frame", { BackgroundColor3 = C.green, BackgroundTransparency = 0.1 + k * 0.2, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0), Size = UDim2.fromScale(0.5, 1), Parent = holder })
		sweeps[k + 1] = holder
	end
	label(body, "CONTACTS", 280, 0, 200, 18, 13, C.dim)
	local n = math.clamp(math.floor(tonumber(params.blips) or 4), 2, 6)
	local NAMES = shuffle({ "DEBRIS", "ICE FRAGMENT", "SAT-7 // DEFUNCT", "HULL PANEL", "MICROMETEOROID" })
	local blips = {}
	local sel = 1
	local ending = false
	local identify
	local base = math.random() * 360
	for i = 1, n do
		local ghost = i == n
		local btn = new("TextButton", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Text = "", Size = UDim2.fromOffset(40, 40), ZIndex = 3, Parent = scr })
		local sz = if ghost then 14 else 10
		local dot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.green, BackgroundTransparency = 1, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(sz, sz), ZIndex = 3, Parent = btn })
		round(dot)
		local entry = label(body, string.format("C%d   UNIDENTIFIED", i), 280, 24 + (i - 1) * 34, 280, 28, 15, C.dim)
		blips[i] = {
			ang = (base + (i - 1) * (360 / n) + math.random(-15, 15)) % 360,
			dist = if ghost then 0.9 else 0.35 + math.random() * 0.45,
			ghost = ghost,
			btn = btn,
			dot = dot,
			entry = entry,
			name = NAMES[i] or "DEBRIS",
			since = 99,
			done = false,
		}
		btn.Activated:Connect(function()
			if api.alive() and not ending then
				sel = i
				identify(i)
			end
		end)
	end
	local cursor = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Size = UDim2.fromOffset(28, 28), ZIndex = 4, Parent = scr })
	stroke(cursor, C.text, 1, 0)

	local function lit(b): number
		return math.max(0, 1 - b.since / FADE)
	end
	local function selectNext(step: number)
		for k = 1, n do
			local j = (sel - 1 + step * k) % n + 1
			if not blips[j].done then
				sel = j
				return
			end
		end
	end
	local function allDone(): boolean
		for _, b in blips do
			if not b.done then
				return false
			end
		end
		return true
	end
	function identify(i: number)
		local b = blips[i]
		if not b or b.done then
			return
		end
		if lit(b) < 0.2 then
			api.status("NO RETURN // WAIT FOR THE SWEEP", C.amber)
			api.sfx(BEEP, 0.18, 0.7)
			return
		end
		b.done = true
		if b.ghost then
			b.entry.Text = string.format("C%d   ------   NO RETURN", i)
			b.entry.TextColor3 = C.red
			api.sfx("Static", 0.4, 1)
			api.sfx("LowStinger", 0.3, 0.9)
			api.shake(7)
			api.status("CONTACT LOST", C.red)
		else
			b.entry.Text = string.format("C%d   %s   %.1f km", i, b.name, b.dist * 1.4)
			b.entry.TextColor3 = C.cyan
			api.sfx(BEEP, 0.28, 1.4)
			api.status(string.format("C%d TAGGED: %s", i, b.name), C.cyan)
		end
		selectNext(1)
		if allDone() then
			ending = true
			api.after(1.1, function()
				for _, x in blips do
					x.btn.Visible = false
					x.entry.Text = ""
				end
				blips[1].entry.Text = "NO CONTACTS"
				blips[1].entry.TextColor3 = C.dim
				api.sfx("Static", 0.2, 0.8)
				api.status("SWEEP COMPLETE // NO CONTACTS", C.green)
				api.finish(true)
			end)
		end
	end
	local t = 0
	local g = {}
	function g.dir(d: Vector2)
		if not ending and d.X ~= 0 then
			selectNext(d.X)
			api.sfx(BEEP, 0.08, 1.2)
		end
	end
	function g.confirm(down: boolean)
		if down and not ending then
			identify(sel)
		end
	end
	function g.update(dt: number)
		t += dt
		local a = (t / PERIOD * 360) % 360
		for k, h in sweeps do
			h.Rotation = a - (k - 1) * 4
		end
		for i, b in blips do
			local since = ((a - b.ang) % 360) / 360 * PERIOD
			if since < b.since and b.ghost and not b.done then
				b.dist = math.max(0.3, b.dist - 0.07) -- it is getting closer every pass
				b.entry.Text = string.format("C%d   UNKNOWN   %.1f km", i, b.dist * 1.4)
				b.entry.TextColor3 = C.amber
			end
			b.since = since
			local rad = math.rad(b.ang)
			b.btn.Position = UDim2.fromScale(0.5 + math.cos(rad) * b.dist * 0.5, 0.5 + math.sin(rad) * b.dist * 0.5)
			if b.done then
				b.dot.BackgroundTransparency = if b.ghost then 1 else 0.3
				b.dot.BackgroundColor3 = C.cyan
			else
				b.dot.BackgroundTransparency = 1 - lit(b)
				b.dot.BackgroundColor3 = C.green
			end
		end
		local s = blips[sel]
		cursor.Visible = s ~= nil and not s.done and not ending
		if s then
			cursor.Position = s.btn.Position
		end
	end
	return g
end

-- D2_Observatory: pan a dark starfield to the ship's lights; centre it and it is gone.
Games.Scope = function(body, params, api)
	api.title("OBSERVATORY // DEEP FIELD")
	api.hints({
		kb = "WASD / arrows  pan     Esc  close",
		pad = "Left stick  pan     B  close",
		touch = "Drag the sky to pan the scope",
	})
	api.status("Find the ship. Centre it and hold steady.", C.dim)
	local VW, VH, WW, WH = 560, 206, 1500, 900
	local view = new("Frame", { BackgroundColor3 = Color3.fromRGB(2, 3, 6), Size = UDim2.fromOffset(VW, VH), ClipsDescendants = true, Parent = body })
	corner(view)
	stroke(view, C.cyan, 1, 0.5)
	local sky = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(WW, WH), Parent = view })
	local twinkle = {}
	for i = 1, 170 do
		local s = if math.random() < 0.12 then 3 else math.random(1, 2)
		local st = new("Frame", {
			BackgroundColor3 = Color3.fromRGB(200 + math.random(0, 55), 215 + math.random(0, 40), 255),
			BackgroundTransparency = 0.1 + math.random() * 0.6,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(math.random(0, WW), math.random(0, WH)),
			Size = UDim2.fromOffset(s, s),
			Parent = sky,
		})
		if i % 6 == 0 then
			table.insert(twinkle, { f = st, base = st.BackgroundTransparency, ph = math.random() * 6 })
		end
	end
	local cx, cy = math.random(VW / 2 + 40, WW - VW / 2 - 40), math.random(VH / 2 + 40, WH - VH / 2 - 40)
	local tx, ty
	repeat
		tx, ty = math.random(150, WW - 150), math.random(120, WH - 120)
	until (Vector2.new(tx, ty) - Vector2.new(cx, cy)).Magnitude >= 500
	local ship = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromOffset(tx, ty), Size = UDim2.fromOffset(40, 20), Parent = sky })
	local hull = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(26, 30, 38), BackgroundTransparency = 0.25, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(34, 7), Parent = ship })
	corner(hull, UDim.new(0.5, 0))
	local lights = {}
	for k, o in { Vector2.new(-15, 3), Vector2.new(0, -4), Vector2.new(15, 3) } do
		lights[k] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = if k == 2 then C.red else C.amber, BorderSizePixel = 0, Position = UDim2.new(0.5, o.X, 0.5, o.Y), Size = UDim2.fromOffset(3, 3), Parent = ship })
	end
	local ret = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(56, 56), ZIndex = 3, Parent = view })
	round(ret)
	local retStroke = stroke(ret, C.cyan, 1, 0.3)
	for _, o in { UDim2.new(0.5, -40, 0.5, 0), UDim2.new(0.5, 40, 0.5, 0) } do
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BackgroundTransparency = 0.4, BorderSizePixel = 0, Position = o, Size = UDim2.fromOffset(16, 1), ZIndex = 3, Parent = view })
	end
	for _, o in { UDim2.new(0.5, 0, 0.5, -40), UDim2.new(0.5, 0, 0.5, 40) } do
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BackgroundTransparency = 0.4, BorderSizePixel = 0, Position = o, Size = UDim2.fromOffset(1, 16), ZIndex = 3, Parent = view })
	end
	local coord = label(body, "", 0, 212, 310, 22, 14, C.text)
	label(body, "SIGNAL", 320, 212, 60, 22, 12, C.dim)
	local sigBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(380, 219), Size = UDim2.fromOffset(180, 8), Parent = body })
	corner(sigBack)
	local sigFill = new("Frame", { BackgroundColor3 = C.amber, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = sigBack })
	corner(sigFill)
	local lockBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(0, 244), Size = UDim2.fromOffset(560, 6), Parent = body })
	corner(lockBack)
	local lockFill = new("Frame", { BackgroundColor3 = C.green, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = lockBack })
	corner(lockFill)

	local gone, goneT, lockT, pingT, t = false, 0, 0, 0, 0
	local last: Vector2? = nil
	api.drag(hitArea(view), function(p)
		last = p
	end, function(p)
		if last and not gone then
			local d = (p - last) / api.scale()
			cx -= d.X
			cy -= d.Y
			last = p
		end
	end, function()
		last = nil
	end)
	local function vanish()
		gone = true
		api.sfx("Static", 0.45, 1)
		api.sfx("LowStinger", 0.35, 0.8)
		api.shake(6)
		api.status("SIGNAL LOST // THERE'S NOTHING THERE", C.red)
		api.after(1.4, function()
			api.finish(true)
		end)
	end
	local g = {}
	function g.update(dt: number, axis: Vector2)
		t += dt
		if not gone and api.alive() then
			cx += axis.X * 380 * dt + math.noise(t * 0.4, 7.3) * 16 * dt
			cy -= axis.Y * 380 * dt - math.noise(t * 0.4, 19.1) * 16 * dt
		end
		cx = math.clamp(cx, VW / 2, WW - VW / 2)
		cy = math.clamp(cy, VH / 2, WH - VH / 2)
		sky.Position = UDim2.fromOffset(VW / 2 - cx, VH / 2 - cy)
		for _, s in twinkle do
			s.f.BackgroundTransparency = math.clamp(s.base + math.sin(t * 3 + s.ph) * 0.25, 0, 1)
		end
		if gone then
			goneT += dt
			ship.Visible = goneT < 0.35 and (goneT * 20) % 2 < 1 -- stutter, then nothing
			sigFill.Size = UDim2.fromScale(0, 1)
			coord.Text = "NO TARGET"
			coord.TextColor3 = C.red
			return
		end
		for k, l in lights do
			l.BackgroundTransparency = 0.15 + 0.6 * (0.5 + 0.5 * math.sin(t * 4 + k * 1.7))
		end
		local dist = (Vector2.new(tx, ty) - Vector2.new(cx, cy)).Magnitude
		local strength = math.clamp(1 - dist / 650, 0, 1)
		sigFill.Size = UDim2.fromScale(strength, 1)
		sigFill.BackgroundColor3 = if strength > 0.9 then C.green elseif strength > 0.5 then C.cyan else C.amber
		pingT -= dt
		if pingT <= 0 then
			pingT = 1.3 - strength * 1.1
			api.sfx(BEEP, 0.05 + strength * 0.12, 0.8 + strength * 0.8)
		end
		coord.Text = string.format("RA %02dh %02dm    DEC %+03d", math.floor(cx / 62) % 24, math.floor(cx) % 60, math.floor(45 - cy / 10))
		local centred = dist < 26
		retStroke.Color = if centred then C.green else C.cyan
		lockT = if centred then lockT + dt else math.max(0, lockT - dt * 1.5)
		lockFill.Size = UDim2.fromScale(math.clamp(lockT, 0, 1), 1)
		if lockT >= 1 and api.alive() then
			vanish()
		end
	end
	return g
end

-- Telescope: full-screen deep-field scope. Find the drifting contact, zoom, hold it 3s.
Games.Telescope = function(body, params, api)
	api.title("OBSERVATORY // DEEP FIELD SCOPE")
	api.hints({
		kb = "WASD / drag  pan    Q / E / scroll  zoom    Esc close",
		pad = "Left stick  pan    Hold A  zoom    B close",
		touch = "Drag to pan    + / -  zoom",
	})
	api.status("Scope view active", C.dim)
	local RMONO = Enum.Font.RobotoMono
	local SPAN_AZ, SPAN_EL, MAXZ, SHIP_DEG = 80, 38, 8, 1.6
	-- Above MinigameGui (95): otherwise the shade + panel sit on top of the fullscreen scope.
	local sg = new("ScreenGui", { Name = "AuroraScope", IgnoreGuiInset = true, ResetOnSpawn = false, DisplayOrder = 96, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })
	-- ponytail: fake connection so close() destroys the fullscreen layer with the rest
	api.conn({ Disconnect = function() sg:Destroy() end })
	local root = new("Frame", { BackgroundColor3 = Color3.fromRGB(1, 2, 4), BorderSizePixel = 0, Size = UDim2.fromScale(1, 1), Parent = sg })
	local sky = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true, Parent = root })
	local stars = {}
	for i = 1, 170 do
		local sz = if math.random() < 0.1 then 3 else math.random(1, 2)
		stars[i] = {
			f = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(200 + math.random(0, 55), 215 + math.random(0, 40), 255), BackgroundTransparency = math.random() * 0.5, BorderSizePixel = 0, Parent = sky }),
			az = (math.random() * 2 - 1) * (SPAN_AZ + 30),
			el = (math.random() * 2 - 1) * (SPAN_EL + 20),
			s = sz,
		}
		round(stars[i].f)
	end
	local earth = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(8, 22, 38), BorderSizePixel = 0, ZIndex = 2, Parent = sky })
	round(earth)
	stroke(earth, Color3.fromRGB(90, 170, 255), 3, 0.35)
	local tgt = { az = (if math.random() < 0.5 then -1 else 1) * (25 + math.random() * 40), el = (math.random() * 2 - 1) * 22, vaz = (math.random() - 0.5) * 0.9, vel = (math.random() - 0.5) * 0.5 }
	local dot = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(255, 170, 60), BorderSizePixel = 0, Size = UDim2.fromOffset(5, 5), ZIndex = 3, Parent = sky })
	round(dot)
	local dotRing = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(14, 14), ZIndex = 3, Parent = dot })
	round(dotRing)
	local dotStroke = stroke(dotRing, Color3.fromRGB(255, 170, 60), 1, 0.4)
	local ship = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, ZIndex = 3, Visible = false, Parent = sky })
	local src = FX and FX:FindFirstChild("ForeignShip")
	local vp
	if src then
		local okV = pcall(function()
			local m = src:Clone()
			if m:IsA("BasePart") then
				local mm = Instance.new("Model")
				m.Parent = mm
				m = mm
			end
			for _, dd in m:GetDescendants() do
				if dd:IsA("BaseScript") or dd:IsA("Sound") then
					dd:Destroy()
				end
			end
			vp = new("ViewportFrame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Ambient = Color3.fromRGB(14, 18, 24), LightColor = Color3.fromRGB(50, 70, 90), LightDirection = Vector3.new(-1, -0.3, -0.4), ZIndex = 3, Parent = ship })
			local cf, size = (m :: Model):GetBoundingBox()
			local cam = Instance.new("Camera")
			cam.FieldOfView = 30
			local dist = size.Magnitude * 1.9
			cam.CFrame = CFrame.lookAt(cf.Position + (cf.RightVector * 0.85 + cf.UpVector * 0.3 + cf.LookVector * 0.35).Unit * dist, cf.Position)
			cam.Parent = vp
			vp.CurrentCamera = cam
			m.Parent = vp
		end)
		if not okV and vp then
			vp:Destroy()
			vp = nil
		end
	end
	if not vp then
		-- fallback silhouette: dark hull, swept fins, faint rim
		local hull = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(6, 8, 11), BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.9, 0.22), ZIndex = 3, Parent = ship })
		corner(hull, UDim.new(0.5, 0))
		stroke(hull, Color3.fromRGB(40, 60, 72), 1, 0.3)
		for _, sgn in { -1, 1 } do
			local fin = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = Color3.fromRGB(5, 7, 9), BorderSizePixel = 0, Position = UDim2.fromScale(0.62, 0.5 + sgn * 0.2), Rotation = sgn * 28, Size = UDim2.fromScale(0.42, 0.08), ZIndex = 2, Parent = ship })
			stroke(fin, Color3.fromRGB(40, 60, 72), 1, 0.5)
		end
	end
	-- vignette: huge black stroke around a circular aperture
	local aperture = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.92, 0.92), SizeConstraint = Enum.SizeConstraint.RelativeYY, ZIndex = 10, Parent = root })
	round(aperture)
	stroke(aperture, Color3.new(0, 0, 0), 2400, 0)
	local rim = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.92, 0.92), SizeConstraint = Enum.SizeConstraint.RelativeYY, ZIndex = 11, Parent = root })
	round(rim)
	stroke(rim, C.cyan, 1.5, 0.55)
	local function line(x, y, w, h)
		return new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BackgroundTransparency = 0.45, BorderSizePixel = 0, Position = UDim2.new(0.5, x, 0.5, y), Size = UDim2.fromOffset(w, h), ZIndex = 12, Parent = root })
	end
	line(-46, 0, 60, 1)
	line(46, 0, 60, 1)
	line(0, -46, 1, 60)
	line(0, 46, 1, 60)
	local lockRing = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(56, 56), ZIndex = 12, Parent = root })
	round(lockRing)
	local lockStroke = stroke(lockRing, C.cyan, 1, 0.5)
	local function ro(text, x, y, ax, size, col)
		return new("TextLabel", { AnchorPoint = Vector2.new(ax, 0.5), BackgroundTransparency = 1, Position = UDim2.new(0.5, x, 0.5, y), Size = UDim2.fromOffset(260, 20), Font = RMONO, TextSize = size or 14, TextColor3 = col or C.text, TextXAlignment = if ax == 0 then LEFT elseif ax == 1 then Enum.TextXAlignment.Right else CENTER, Text = text, ZIndex = 13, Parent = root })
	end
	ro("AURORA DEEP FIELD  //  SCOPE 2", 0, -250, 0.5, 13, C.dim)
	local azL = ro("", -230, 190, 0, 14)
	local elL = ro("", -230, 210, 0, 14)
	local zmL = ro("", -230, 230, 0, 14)
	local sgL = ro("", 230, 190, 1, 14)
	local lkL = ro("", 230, 230, 1, 14, C.dim)
	local sigBack = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), BackgroundColor3 = C.bgHi, BorderSizePixel = 0, Position = UDim2.new(0.5, 230, 0.5, 210), Size = UDim2.fromOffset(160, 8), ZIndex = 13, Parent = root })
	corner(sigBack)
	local sigFill = new("Frame", { BackgroundColor3 = C.cyan, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 14, Parent = sigBack })
	corner(sigFill)
	-- step guide: FIND -> ZOOM -> HOLD, active step lit
	local steps = {}
	for i, t in { "1  FIND THE SIGNAL", "2  ZOOM IN  (E / scroll)", "3  HOLD IT IN THE RING" } do
		steps[i] = ro(t, (i - 2) * 220, -220, 0.5, 14, C.dim)
	end
	local sigCap = ro("SIGNAL", 230, 172, 1, 12, C.dim)
	-- off-target pointer: an arrow on the aperture edge that points at the contact
	local pointer = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Size = UDim2.fromOffset(40, 40), Font = HEAD, TextSize = 30, TextColor3 = Color3.fromRGB(255, 170, 60), Text = "▲", ZIndex = 13, Parent = root })
	local holdBack = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.bgHi, BorderSizePixel = 0, Position = UDim2.new(0.5, 0, 0.5, 44), Size = UDim2.fromOffset(80, 4), ZIndex = 13, Visible = false, Parent = root })
	corner(holdBack)
	local holdFill = new("Frame", { BackgroundColor3 = C.cyan, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), ZIndex = 14, Parent = holdBack })
	corner(holdFill)
	local contact = ro("CONTACT CONFIRMED", 0, 120, 0.5, 26, C.cyan)
	contact.Font = HEAD
	contact.Size = UDim2.fromOffset(500, 36)
	contact.Visible = false

	local camAz, camEl, zoom, zoomDir, hold, frozen = 0, 0, 1, 0, 0, false
	local last: Vector2? = nil
	local function ppd()
		return math.max(1, sky.AbsoluteSize.Y) / (60 / zoom)
	end
	local function setZoom(z)
		zoom = math.clamp(z, 1, MAXZ)
	end
	local area = hitArea(root)
	local xb = button(root, "X", 0, 0, 44, 44, 18)
	xb.AnchorPoint = Vector2.new(1, 0)
	xb.Position = UDim2.new(1, -24, 0, 24)
	xb.ZIndex = 25
	xb.Activated:Connect(function()
		if api.alive() then
			close() -- same as Esc / B: nothing sent, prompt stays usable
		end
	end)
	api.drag(area, function(pos)
		last = pos
	end, function(pos)
		if last and not frozen then
			local d = pos - last
			camAz = math.clamp(camAz - d.X / ppd(), -SPAN_AZ, SPAN_AZ)
			camEl = math.clamp(camEl + d.Y / ppd(), -SPAN_EL, SPAN_EL)
		end
		last = pos
	end, function()
		last = nil
	end)
	api.conn(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseWheel and not frozen then
			setZoom(zoom * (1 + 0.15 * input.Position.Z))
		end
	end))
	for i, sym in { "+", "-" } do
		local b = button(root, sym, 0, 0, 44, 44, 20)
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -24, 0.5, (i - 1.5) * 56)
		b.ZIndex = 25
		b.Visible = UserInputService.TouchEnabled
		api.hold(b, function()
			zoomDir = if sym == "+" then 1 else -1
		end, function()
			zoomDir = 0
		end)
	end

	local g = {}
	function g.confirm(down: boolean)
		zoomDir = if not down then 0 elseif zoom >= MAXZ - 0.05 then -1 else 1
	end
	function g.update(dt: number, axis: Vector2)
		if frozen then
			return
		end
		local pan = 26 / zoom
		camAz = math.clamp(camAz + axis.X * pan * dt, -SPAN_AZ, SPAN_AZ)
		camEl = math.clamp(camEl + axis.Y * pan * dt, -SPAN_EL, SPAN_EL)
		local zin = zoomDir
		if UserInputService:IsKeyDown(Enum.KeyCode.E) then
			zin = 1
		elseif UserInputService:IsKeyDown(Enum.KeyCode.Q) then
			zin = -1
		end
		setZoom(zoom * (1 + zin * 1.4 * dt))
		local drift = if zoom >= 4 then 0.3 else 1 -- contact nearly holds still once you're zoomed on it
		tgt.az += (tgt.vaz * dt + math.noise(os.clock() * 0.3, 1.7) * 0.25 * dt) * drift
		tgt.el += tgt.vel * dt * drift
		if math.abs(tgt.az) > SPAN_AZ * 0.85 then
			tgt.vaz = -math.sign(tgt.az) * math.abs(tgt.vaz)
		end
		if math.abs(tgt.el) > SPAN_EL * 0.7 then
			tgt.vel = -math.sign(tgt.el) * math.abs(tgt.vel)
		end
		local k = ppd()
		local W, H = sky.AbsoluteSize.X, sky.AbsoluteSize.Y
		local function proj(az, el)
			return W / 2 + (az - camAz) * k, H / 2 - (el - camEl) * k
		end
		local grow = math.min(1 + zoom * 0.12, 2)
		for _, st in stars do
			local x, y = proj(st.az, st.el)
			local vis = x > -4 and x < W + 4 and y > -4 and y < H + 4
			st.f.Visible = vis
			if vis then
				st.f.Position = UDim2.fromOffset(x, y)
				st.f.Size = UDim2.fromOffset(st.s * grow, st.s * grow)
			end
		end
		local ex, ey = proj(0, -100)
		earth.Position = UDim2.fromOffset(ex, ey)
		earth.Size = UDim2.fromOffset(130 * k, 130 * k)
		local tx, ty = proj(tgt.az, tgt.el)
		local dist = math.sqrt((tgt.az - camAz) ^ 2 + (tgt.el - camEl) ^ 2)
		local fov = 60 / zoom
		local resolve = math.clamp((zoom - 4) / 2, 0, 1)
		dot.Position = UDim2.fromOffset(tx, ty)
		dot.BackgroundTransparency = 0.45 + resolve * 0.55 + math.noise(os.clock() * 3, 9) * 0.2
		ship.Visible = resolve > 0
		ship.Position = UDim2.fromOffset(tx, ty)
		ship.Size = UDim2.fromOffset(SHIP_DEG * k, SHIP_DEG * k * 0.6)
		if vp then
			vp.ImageTransparency = 1 - resolve
		end
		local signal = math.clamp(1 - dist / 70, 0, 1) ^ 1.3 * (0.6 + 0.4 * zoom / MAXZ)
		signal = math.clamp(signal + (math.random() - 0.5) * 0.04, 0, 1)
		local onTarget = zoom >= 4 and dist < math.max(fov * 0.2, 1.2)
		hold = if onTarget then hold + dt else math.max(0, hold - dt * 0.75)
		local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
		dotStroke.Transparency = 0.2 + pulse * 0.6
		dotRing.Size = UDim2.fromOffset(10 + pulse * 10, 10 + pulse * 10)
		-- edge pointer while the contact is outside the view
		local cx, cy = W / 2, H / 2
		local off = Vector2.new(tx - cx, ty - cy)
		local radius = H * 0.42
		pointer.Visible = off.Magnitude > radius * 0.9
		if pointer.Visible then
			local u = off.Unit
			pointer.Position = UDim2.fromOffset(cx + u.X * radius * 0.9, cy + u.Y * radius * 0.9)
			pointer.Rotation = math.deg(math.atan2(u.Y, u.X)) + 90
		end
		local stage = if onTarget then 3 elseif dist < fov * 0.5 then 2 else 1
		for i, l in steps do
			l.TextColor3 = if i == stage then C.cyan elseif i < stage then C.text else C.dim
		end
		holdBack.Visible = hold > 0
		holdFill.Size = UDim2.fromScale(math.clamp(hold / 2.5, 0, 1), 1)
		sigFill.Size = UDim2.fromScale(signal, 1)
		lockStroke.Transparency = if onTarget then 0 else 0.5
		lockStroke.Thickness = if onTarget then 2 else 1
		azL.Text = string.format("AZ    %+07.2f°", camAz)
		elL.Text = string.format("EL    %+07.2f°", camEl)
		zmL.Text = string.format("ZOOM  %4.1fx", zoom)
		sgL.Text = string.format("SIGNAL  %3d%%", math.floor(signal * 100))
		lkL.Text = if onTarget then string.format("TRACKING  %.1fs", 2.5 - math.min(2.5, hold)) elseif zoom < 4 and signal > 0.5 then "INCREASE ZOOM" elseif signal > 0.5 then "CENTER IT IN THE RING" else "FOLLOW THE ARROW"
		lkL.TextColor3 = if onTarget then C.cyan else C.dim
		if hold >= 2.5 then
			frozen = true
			pointer.Visible = false
			holdBack.Visible = false
			contact.Visible = true
			lkL.Text = "TARGET HELD"
			api.sfx(BEEP, 0.4, 0.8)
			api.status("CONTACT CONFIRMED", C.cyan)
			api.after(1.2, function()
				api.finish(true, { contact = true })
			end)
		end
	end
	return g
end

-- PipeRoute: rotate tiles until coolant flows from inlet to outlet. params.size = grid n.
Games.PipeRoute = function(body, params, api)
	api.title("COOLANT // PIPE ROUTING")
	api.hints({
		kb = "WASD move   E / Enter rotate   Esc close",
		pad = "D-pad move   A rotate   B close",
		touch = "Tap a tile to rotate it",
	})
	api.status("Rotate tiles to connect IN to OUT", C.dim)
	local n = math.clamp(math.floor(tonumber(params.size) or 5), 3, 7)
	local cs = math.floor(math.min(240 / n, 52))
	local ox, oy = math.floor((560 - cs * n) / 2), math.floor((250 - cs * n) / 2)
	local N, E, S, W = 1, 2, 4, 8
	local function has(m, b)
		return math.floor(m / b) % 2 == 1
	end
	local function rot(m)
		return (m * 2) % 16 + (if m >= 8 then 1 else 0)
	end
	local mask = {}
	for c = 1, n do
		mask[c] = {}
	end
	local startRow = math.random(1, n)
	local row = startRow
	for c = 1, n do
		local t = math.random(1, n)
		local step = if t >= row then 1 else -1
		local r0 = row
		for r = row, t, step do
			local m = 0
			if r == r0 then m += W end
			if r == t then m += E end
			if r ~= r0 then m += if step == 1 then N else S end
			if r ~= t then m += if step == 1 then S else N end
			mask[c][r] = m
		end
		row = t
	end
	local endRow = row
	local DECOY = { N + S, N + E, N + E + S, N + E }
	local tiles = {}
	local function flow()
		local seen = {}
		local q = {}
		if has(tiles[1][startRow].m, W) then
			q[1] = { 1, startRow }
			seen[1 * 100 + startRow] = true
		end
		local DIRS = { { N, 0, -1, S }, { E, 1, 0, W }, { S, 0, 1, N }, { W, -1, 0, E } }
		while #q > 0 do
			local p = table.remove(q)
			local m = tiles[p[1]][p[2]].m
			for _, dd in DIRS do
				local c2, r2 = p[1] + dd[2], p[2] + dd[3]
				if has(m, dd[1]) and tiles[c2] and tiles[c2][r2] and not seen[c2 * 100 + r2] and has(tiles[c2][r2].m, dd[4]) then
					seen[c2 * 100 + r2] = true
					table.insert(q, { c2, r2 })
				end
			end
		end
		return seen, seen[n * 100 + endRow] == true and has(tiles[n][endRow].m, E)
	end
	local sc, sr, solved = 1, startRow, false
	local function paint()
		local seen = flow()
		for c = 1, n do
			for r = 1, n do
				local tl = tiles[c][r]
				local col = if solved then C.green elseif seen[c * 100 + r] then C.cyan else C.dim
				for b, arm in tl.arms do
					arm.Visible = has(tl.m, b)
					arm.BackgroundColor3 = col
				end
				tl.hub.BackgroundColor3 = col
				tl.st.Transparency = if c == sc and r == sr and not solved then 0 else 0.8
			end
		end
	end
	local function rotate(c, r)
		if solved or not api.alive() then
			return
		end
		sc, sr = c, r
		local tl = tiles[c][r]
		tl.m = rot(tl.m)
		api.sfx(BEEP, 0.12, 1 + math.random() * 0.2)
		local _, done = flow()
		if done then
			solved = true
			api.status("FLOW RESTORED // LOOP PRESSURISED", C.green)
			api.finish(true)
		end
		paint()
	end
	local aw = math.max(4, math.floor(cs * 0.16))
	for c = 1, n do
		tiles[c] = {}
		for r = 1, n do
			local m = mask[c][r] or DECOY[math.random(1, #DECOY)]
			for _ = 1, math.random(0, 3) do
				m = rot(m)
			end
			local bt = new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = C.well, Position = UDim2.fromOffset(ox + (c - 1) * cs + 2, oy + (r - 1) * cs + 2), Size = UDim2.fromOffset(cs - 4, cs - 4), Parent = body })
			corner(bt)
			local st = stroke(bt, C.cyan, 1, 0.8)
			local arms = {
				[N] = new("Frame", { AnchorPoint = Vector2.new(0.5, 0), BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, aw, 0.5, 0), Parent = bt }),
				[S] = new("Frame", { AnchorPoint = Vector2.new(0.5, 1), BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 1), Size = UDim2.new(0, aw, 0.5, 0), Parent = bt }),
				[E] = new("Frame", { AnchorPoint = Vector2.new(1, 0.5), BorderSizePixel = 0, Position = UDim2.fromScale(1, 0.5), Size = UDim2.new(0.5, 0, 0, aw), Parent = bt }),
				[W] = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), BorderSizePixel = 0, Position = UDim2.fromScale(0, 0.5), Size = UDim2.new(0.5, 0, 0, aw), Parent = bt }),
			}
			local hub = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(aw + 4, aw + 4), Parent = bt })
			round(hub)
			tiles[c][r] = { m = m, arms = arms, hub = hub, st = st }
			api.conn(bt.Activated:Connect(function()
				rotate(c, r)
			end))
		end
	end
	-- never start solved
	while select(2, flow()) do
		tiles[1][startRow].m = rot(tiles[1][startRow].m)
	end
	label(body, "IN", ox - 30, oy + (startRow - 1) * cs, 26, cs, 12, C.cyan, MONO, CENTER)
	label(body, "OUT", ox + n * cs + 2, oy + (endRow - 1) * cs, 34, cs, 12, C.cyan, MONO, CENTER)
	paint()
	local g = { repeatDirs = true }
	function g.dir(d: Vector2)
		sc = math.clamp(sc + d.X, 1, n)
		sr = math.clamp(sr - d.Y, 1, n)
		paint()
	end
	function g.confirm(down: boolean)
		if down then
			rotate(sc, sr)
		end
	end
	return g
end

-- CargoSort: drag each crate onto the bay that stores it. Three misloads fail.
Games.CargoSort = function(body, params, api)
	api.title("CARGO BAY // MANIFEST SORT")
	api.hints({
		kb = "A / D pick crate   W / S pick bay   Enter load   Esc close",
		pad = "Left / right crate   Up / down bay   A load   B close",
		touch = "Drag each crate onto its bay",
	})
	api.status("Load every crate into the right bay", C.dim)
	local BAYS = { "ATMOSPHERICS", "MEDICAL", "PROPELLANT" }
	local POOL = {
		{ "OXYGEN CANISTER", 1 }, { "NITROGEN TANK", 1 }, { "CO2 SCRUB PACK", 1 },
		{ "MORPHINE KIT", 2 }, { "SUTURE PACK", 2 }, { "BLOOD PLASMA", 2 },
		{ "HYDRAZINE CELL", 3 }, { "XENON CELL", 3 }, { "OXIDISER DRUM", 3 },
	}
	shuffle(POOL)
	local bays, crates = {}, {}
	for j, name in BAYS do
		local f = new("Frame", { BackgroundColor3 = C.panel, Position = UDim2.fromOffset(8 + (j - 1) * 184, 128), Size = UDim2.fromOffset(176, 118), Parent = body })
		corner(f, UDim.new(0, 8))
		bays[j] = { f = f, st = stroke(f, C.cyan, 1, 0.75), n = 0 }
		label(f, name, 0, 4, 176, 18, 12, C.dim, MONO, CENTER)
	end
	local strikes, placed, selC, selB, busy = 0, 0, 1, 1, false
	local function home(i)
		return UDim2.fromOffset(8 + (i - 1) * 92, 20)
	end
	local function drop(i, j)
		local cr = crates[i]
		if not cr or cr.done or not api.alive() then
			return
		end
		if j == cr.bay then
			cr.done = true
			placed += 1
			local b = bays[j]
			b.n += 1
			cr.b.ZIndex = 2
			cr.b.Parent = b.f
			cr.b.Size = UDim2.fromOffset(78, 26)
			cr.b.Position = UDim2.fromOffset(6 + ((b.n - 1) % 2) * 86, 26 + math.floor((b.n - 1) / 2) * 30)
			cr.st.Color = C.green
			api.sfx(BEEP, 0.2, 1.5)
			if placed == #crates then
				api.status("MANIFEST RECONCILED", C.green)
				api.finish(true)
			end
		else
			cr.b.Position = home(i)
			cr.b.ZIndex = 2
			if j then
				strikes += 1
				api.shake(6)
				api.sfx(BEEP, 0.3, 0.6)
				api.status(string.format("Wrong bay. %s does not go in %s  (%d/3)", cr.name, BAYS[j], strikes), C.red)
				if strikes >= 3 then
					api.finish(false)
				end
			end
		end
	end
	for i = 1, 6 do
		local item = POOL[i]
		local b = new("TextButton", { AutoButtonColor = false, Text = "", BackgroundColor3 = C.bgHi, Position = home(i), Size = UDim2.fromOffset(84, 60), ZIndex = 2, Parent = body })
		corner(b)
		local st = stroke(b, C.cyan, 1, 0.6)
		local l = label(b, item[1], 4, 0, 76, 60, 11, C.text, MONO, CENTER)
		l.Size = UDim2.new(1, -8, 1, 0)
		l.ZIndex = 3
		crates[i] = { b = b, st = st, name = item[1], bay = item[2], done = false }
		local off = Vector2.zero
		api.drag(b, function(pos)
			if crates[i].done then
				return
			end
			selC = i
			busy = true
			off = pos - b.AbsolutePosition
			b.ZIndex = 8
		end, function(pos)
			if crates[i].done then
				return
			end
			local p = (pos - off - body.AbsolutePosition) / api.scale()
			b.Position = UDim2.fromOffset(p.X, p.Y)
		end, function()
			busy = false
			if crates[i].done then
				return
			end
			local ctr = b.AbsolutePosition + b.AbsoluteSize / 2
			local hit = nil
			for j, bay in bays do
				local p, s = bay.f.AbsolutePosition, bay.f.AbsoluteSize
				if ctr.X >= p.X and ctr.X <= p.X + s.X and ctr.Y >= p.Y and ctr.Y <= p.Y + s.Y then
					hit = j
				end
			end
			drop(i, hit)
		end)
	end
	local function refresh()
		for i, cr in crates do
			if not cr.done then
				cr.st.Transparency = if i == selC then 0 else 0.6
			end
		end
		for j, bay in bays do
			bay.st.Transparency = if j == selB then 0.1 else 0.75
		end
	end
	local function nextCrate(step)
		for _ = 1, #crates do
			selC = (selC - 1 + step) % #crates + 1
			if not crates[selC].done then
				return
			end
		end
	end
	refresh()
	local g = {}
	function g.dir(d: Vector2)
		if d.X ~= 0 then
			nextCrate(d.X)
		elseif d.Y ~= 0 then
			selB = (selB - 1 - d.Y) % 3 + 1
		end
		api.sfx(BEEP, 0.1, 1.2)
		refresh()
	end
	function g.confirm(down: boolean)
		if down and not busy and crates[selC] and not crates[selC].done then
			drop(selC, selB)
			if placed < #crates then
				nextCrate(1)
			end
			refresh()
		end
	end
	function g.update()
		if not busy then
			refresh()
		end
	end
	return g
end

-- D3_Breaker: memorise the relay sequence in the dark, repeat it. Three faults trip the breaker.
Games.Breaker = function(body, params, api)
	local lab = tostring(params.label or "A")
	api.title("POWER GRID // BREAKER " .. lab)
	api.hints({
		kb = "Watch, then repeat with W A S D / arrows (or 1-4)     Esc  close",
		pad = "Watch, then repeat with the D-pad / stick     B  close",
		touch = "Watch the relays, then tap them in the same order",
	})
	local L = math.clamp(math.floor(tonumber(params.length) or 4), 2, 8)
	local dark = new("Frame", { BackgroundColor3 = Color3.fromRGB(3, 4, 6), Size = UDim2.fromOffset(560, 260), Parent = body })
	corner(dark)
	local CX, CY = 400, 130
	local OFFS = { Vector2.new(0, -84), Vector2.new(90, 0), Vector2.new(0, 84), Vector2.new(-90, 0) }
	local KEYNAME = { "W / 1", "D / 2", "S / 3", "A / 4" }
	local PITCH = { 1.3, 1.1, 0.8, 0.95 }
	local relays, tok = {}, {}
	local press
	for i, o in OFFS do
		local b = new("TextButton", {
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(CX + o.X, CY + o.Y),
			Size = UDim2.fromOffset(76, 70),
			BackgroundColor3 = C.off,
			Text = KEYNAME[i],
			TextColor3 = C.dim,
			TextSize = 13,
			Font = MONO,
			Parent = dark,
		})
		corner(b)
		stroke(b, C.amber, 1, 0.6)
		relays[i], tok[i] = b, 0
		b.Activated:Connect(function()
			if api.alive() then
				press(i)
			end
		end)
	end
	label(dark, "BREAKER " .. lab, 20, 14, 240, 32, 24, C.text, HEAD)
	label(dark, "RELAY SEQUENCE", 20, 56, 240, 16, 12, C.dim)
	local pips = {}
	for i = 1, L do
		local p = new("Frame", { BackgroundColor3 = C.off, Position = UDim2.fromOffset(20 + (i - 1) * 24, 78), Size = UDim2.fromOffset(16, 16), Parent = dark })
		corner(p)
		stroke(p, C.amber, 1, 0.6)
		pips[i] = p
	end
	local faults = label(dark, "FAULTS 0 / 3", 20, 108, 240, 18, 14, C.dim)
	local phaseLbl = label(dark, "", 20, 146, 240, 28, 20, C.amber, HEAD)
	api.loop("Hum", 0.12, 0.7)
	local seq = {}
	for i = 1, L do
		local v
		repeat
			v = math.random(1, 4)
		until v ~= seq[i - 1]
		seq[i] = v
	end
	local phase, pos, strikes = "busy", 0, 0
	local function setRelay(i: number, col: Color3, dur: number?)
		tok[i] += 1
		local my = tok[i]
		local b = relays[i]
		b.BackgroundColor3 = col
		b.TextColor3 = C.bg
		if dur then
			task.delay(dur, function()
				if tok[i] == my and b.Parent then
					b.BackgroundColor3 = C.off
					b.TextColor3 = C.dim
				end
			end)
		end
	end
	local function playSeq()
		phase, pos = "watch", 0
		phaseLbl.Text = "WATCH"
		phaseLbl.TextColor3 = C.amber
		for _, p in pips do
			p.BackgroundColor3 = C.off
		end
		api.status("Memorise the relay sequence", C.amber)
		task.spawn(function()
			task.wait(0.7)
			for _, i in seq do
				if not api.alive() then
					return
				end
				setRelay(i, C.amber, 0.38)
				api.sfx(BEEP, 0.3, PITCH[i])
				task.wait(0.58)
			end
			if api.alive() then
				phase = "input"
				phaseLbl.Text = "REPEAT"
				phaseLbl.TextColor3 = C.cyan
				api.status("Repeat the sequence", C.cyan)
			end
		end)
	end
	function press(i: number)
		if phase ~= "input" then
			return
		end
		api.sfx(BEEP, 0.3, PITCH[i])
		if seq[pos + 1] == i then
			pos += 1
			setRelay(i, C.amber, 0.2)
			pips[pos].BackgroundColor3 = C.green
			if pos >= L then
				phase = "busy"
				for k = 1, 4 do
					setRelay(k, C.green)
				end
				phaseLbl.Text = "ENGAGED"
				phaseLbl.TextColor3 = C.green
				api.status("BREAKER " .. lab .. " ENGAGED", C.green)
				api.finish(true)
			end
			return
		end
		strikes += 1
		phase = "busy"
		for k = 1, 4 do
			setRelay(k, C.red, 0.5)
		end
		api.sfx("PowerDown", 0.35, 1.3)
		api.shake(9)
		faults.Text = string.format("FAULTS %d / 3", strikes)
		faults.TextColor3 = C.red
		if strikes >= 3 then
			phaseLbl.Text = "TRIPPED"
			phaseLbl.TextColor3 = C.red
			api.status("BREAKER TRIPPED", C.red)
			api.finish(false)
			return
		end
		api.status("FAULT // SEQUENCE RESTARTING", C.red)
		api.after(1.1, playSeq)
	end
	local g = {}
	function g.dir(d: Vector2)
		press(if d.Y > 0 then 1 elseif d.X > 0 then 2 elseif d.Y < 0 then 3 else 4)
	end
	function g.digit(n: number)
		if n >= 1 and n <= 4 then
			press(n)
		end
	end
	function g.update()
		-- failing mains: the panel light stutters
		dark.BackgroundTransparency = if math.random() < 0.03 then 0.35 else 0
	end
	playSeq()
	return g
end

-- D4_Valve: crank fast enough to matter, slow enough to keep pressure out of the red.
Games.Valve = function(body, params, api)
	local lab = tostring(params.label or "1")
	api.title("LIFE SUPPORT // O2 VALVE " .. lab)
	api.hints({
		kb = "Alternate A / D (or arrows) to crank. Too fast = overpressure     Esc  close",
		pad = "Rotate the left stick clockwise, or alternate LB / RB     B  close",
		touch = "Drag around the wheel clockwise. Keep pressure out of the red",
	})
	api.status("Open the valve. Watch the pressure.", C.dim)
	local need = math.clamp(tonumber(params.turns) or 2.5, 0.5, 6) * 360
	local wheelBox = new("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(20, 6), Size = UDim2.fromOffset(220, 220), Parent = body })
	local rim = new("Frame", { BackgroundColor3 = C.panel, Size = UDim2.fromScale(1, 1), Parent = wheelBox })
	round(rim)
	local rimStroke = stroke(rim, C.red, 6, 0.1)
	local spokes = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundTransparency = 1, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1, 1), Parent = wheelBox })
	for k = 0, 2 do
		new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.amber, BackgroundTransparency = 0.25, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(0.9, 0, 0, 10), Rotation = k * 60, Parent = spokes })
	end
	local grip = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.text, BorderSizePixel = 0, Position = UDim2.fromScale(0.5, 0.07), Size = UDim2.fromOffset(18, 18), Parent = spokes })
	round(grip)
	local hub = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.bgHi, Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(46, 46), Parent = wheelBox })
	round(hub)
	stroke(hub, C.cyan, 1, 0.4)
	local hit = hitArea(wheelBox)
	label(body, "TURN CLOCKWISE", 20, 232, 220, 20, 12, C.dim, MONO, CENTER)

	label(body, "PRESSURE", 262, 0, 80, 16, 11, C.dim)
	local pBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(272, 20), Size = UDim2.fromOffset(44, 210), ClipsDescendants = true, Parent = body })
	corner(pBack)
	stroke(pBack, C.cyan, 1, 0.5)
	local redZone = new("Frame", { BackgroundColor3 = C.red, BackgroundTransparency = 0.7, BorderSizePixel = 0, Size = UDim2.fromScale(1, 0.2), ZIndex = 2, Parent = pBack })
	local pFill = new("Frame", { AnchorPoint = Vector2.new(0, 1), BackgroundColor3 = C.green, BorderSizePixel = 0, Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), Parent = pBack })

	label(body, "VALVE " .. lab, 340, 0, 220, 30, 22, C.text, HEAD)
	label(body, "FLOW", 340, 40, 60, 16, 12, C.dim)
	local flowBack = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(340, 60), Size = UDim2.fromOffset(220, 12), Parent = body })
	corner(flowBack)
	local flowFill = new("Frame", { BackgroundColor3 = C.cyan, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = flowBack })
	corner(flowFill)
	local flowLbl = label(body, "0%", 340, 76, 220, 20, 14, C.text)
	local o2Lbl = label(body, "", 340, 110, 220, 24, 16, C.red)
	local warnLbl = label(body, "", 340, 150, 220, 40, 20, C.red, HEAD)

	local angle, shown, progress, pressure, over, jamUntil, t = 0, 0, 0, 0, 0, 0, 0
	local turns = 0
	local lastSide = 0
	local lastDrag: number? = nil
	local lastStick: number? = nil
	api.loop("Heartbeat", 0.25, 1)
	local function turn(deg: number)
		if not api.alive() or os.clock() < jamUntil or deg <= 0 then
			return
		end
		deg = math.min(deg, 60)
		angle += deg
		progress += deg
		pressure = math.min(1.05, pressure + deg * 0.0011)
		local nt = math.floor(progress / 360)
		if nt > turns then
			turns = nt
			api.sfx(BEEP, 0.3, 0.55)
			api.shake(2)
		end
		if progress >= need then
			progress = need
			api.status("VALVE " .. lab .. " OPEN // O2 FLOWING", C.green)
			api.finish(true)
		end
	end
	local function angleAt(p: Vector2): number
		local c = rim.AbsolutePosition + rim.AbsoluteSize / 2
		return math.deg(math.atan2(p.Y - c.Y, p.X - c.X))
	end
	local function wrap(d: number): number
		return (d + 180) % 360 - 180
	end
	api.drag(hit, function(p)
		lastDrag = angleAt(p)
	end, function(p)
		if lastDrag then
			local a = angleAt(p)
			turn(wrap(a - lastDrag))
			lastDrag = a
		end
	end, function()
		lastDrag = nil
	end)
	local g = {}
	function g.dir(d: Vector2, fromStick: boolean?)
		if fromStick or d.X == 0 then
			return
		end
		if d.X ~= lastSide then
			lastSide = d.X
			turn(40)
			api.sfx(BEEP, 0.1, 0.45)
		else
			api.sfx(BEEP, 0.06, 0.35)
		end
	end
	function g.update(dt: number)
		t += dt
		local s = api.stick()
		if s.Magnitude > 0.6 then
			local a = math.deg(math.atan2(-s.Y, s.X))
			if lastStick then
				turn(wrap(a - lastStick))
			end
			lastStick = a
		else
			lastStick = nil
		end
		pressure = math.max(0, pressure - 0.3 * dt)
		if pressure >= 0.8 then
			over += dt
			warnLbl.Text = if (t * 6) % 2 < 1 then "EASE OFF" else ""
		else
			over = math.max(0, over - dt)
			warnLbl.Text = ""
		end
		if over > 0.7 and api.alive() then
			-- overpressure: the valve kicks back and costs progress
			over, pressure = 0, 0.55
			progress = math.max(0, progress - 90)
			angle -= 90
			jamUntil = os.clock() + 0.6
			api.shake(10)
			api.sfx("LowStinger", 0.3, 1.1)
			api.status("OVERPRESSURE // VALVE SLIPPED", C.red)
		end
		shown += (angle - shown) * math.min(1, dt * 14)
		spokes.Rotation = shown
		local frac = progress / need
		rimStroke.Color = C.red:Lerp(C.green, frac)
		pFill.Size = UDim2.fromScale(1, math.clamp(pressure, 0, 1))
		pFill.BackgroundColor3 = if pressure >= 0.8 then C.red elseif pressure >= 0.6 then C.amber else C.green
		redZone.BackgroundTransparency = if pressure >= 0.8 then 0.35 else 0.7
		flowFill.Size = UDim2.fromScale(frac, 1)
		flowLbl.Text = string.format("%d%%", math.floor(frac * 100))
		o2Lbl.Text = string.format("CABIN O2  %d%%", math.floor(liveStat("Oxygen")))
	end
	return g
end

-- R_Generator: 3-step backup generator start (prime pump, flip switches in order, time the lever).
Games.Generator = function(body, params, api)
	api.title("BACKUP GENERATOR // START SEQUENCE")
	api.status("Hold to prime the fuel pump", C.dim)
	api.hints({
		kb = "Hold E to prime     Esc  close",
		pad = "Hold A to prime     B  close",
		touch = "Hold PRIME",
	})
	local step = 1 -- 1 prime, 2 switches, 3 lever
	local g = {}

	-- Step 1: hold-to-fill pump, same shape as WaterGauge's pour.
	local primeBar = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(140, 20), Size = UDim2.fromOffset(280, 40), Parent = body })
	corner(primeBar)
	stroke(primeBar, C.cyan, 1, 0.4)
	local primeFill = new("Frame", { BackgroundColor3 = C.amber, BorderSizePixel = 0, Size = UDim2.fromScale(0, 1), Parent = primeBar })
	corner(primeFill)
	local primeBtn = button(body, "HOLD TO PRIME", 180, 90, 200, 70, 18)
	local primeLbl = label(body, "FUEL PUMP", 140, 4, 280, 16, 12, C.dim, MONO, CENTER)
	local primeLevel, priming, primed = 0, false, false

	-- Step 2: flip 3 switches in the shown order.
	local ORDER = shuffle({ 1, 2, 3 })
	local orderIdx = 1
	local swSel = 1
	local switchLbl = label(body, "", 20, 4, 520, 20, 15, C.text, HEAD, CENTER)
	switchLbl.Visible = false
	local switches = {}
	for i = 1, 3 do
		local sw = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(60 + (i - 1) * 160, 40), Size = UDim2.fromOffset(120, 160), Visible = false, Parent = body })
		corner(sw)
		local swStroke = stroke(sw, C.cyan, 1, 0.5)
		label(sw, "SW " .. i, 0, 8, 120, 18, 13, C.dim, MONO, CENTER)
		local lever = new("Frame", { BackgroundColor3 = C.red, BorderSizePixel = 0, Position = UDim2.fromOffset(45, 30), Size = UDim2.fromOffset(30, 60), Parent = sw })
		corner(lever)
		local btn = button(sw, "FLIP", 20, 100, 80, 40, 14)
		btn.Activated:Connect(function()
			if step == 2 and api.alive() then
				g.digit(i)
			end
		end)
		switches[i] = { frame = sw, stroke = swStroke, lever = lever, btn = btn, flipped = false }
	end

	-- Step 3: timed lever pull, marker sweeps a bar, hit the green zone.
	local leverBar = new("Frame", { BackgroundColor3 = C.well, Position = UDim2.fromOffset(30, 60), Size = UDim2.fromOffset(500, 30), Visible = false, Parent = body })
	corner(leverBar)
	stroke(leverBar, C.cyan, 1, 0.4)
	local leverZone = new("Frame", { BackgroundColor3 = C.green, BackgroundTransparency = 0.7, BorderSizePixel = 0, Parent = leverBar })
	local leverMarker = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = C.cyan, BorderSizePixel = 0, Size = UDim2.fromOffset(6, 30), Position = UDim2.fromScale(0, 0.5), Parent = leverBar })
	local leverBtn = button(body, "PULL LEVER", 180, 120, 200, 60, 18)
	leverBtn.Visible = false
	local leverLbl = label(body, "START LEVER // TIME THE PULL", 30, 30, 500, 20, 13, C.dim, MONO, CENTER)
	leverLbl.Visible = false
	local leverX, leverDir, leverLo, leverHi = 0, 1, 0, 0
	local function newLeverZone()
		local size = 0.16
		leverLo = math.random() * (1 - size)
		leverHi = leverLo + size
		leverZone.Position = UDim2.fromScale(leverLo, 0)
		leverZone.Size = UDim2.fromScale(size, 1)
	end

	local function beginPrime()
		primeBtn.Visible, primeBar.Visible, primeLbl.Visible = false, false, false
		switchLbl.Visible = true
		switchLbl.Text = "FLIP ORDER: " .. table.concat(ORDER, " \226\134\146 ")
		for _, sw in switches do
			sw.frame.Visible = true
		end
		api.status("Flip the switches in the order shown", C.dim)
		api.hints({
			kb = "1 / 2 / 3  flip switch     Esc  close",
			pad = "D-pad left/right + A  flip switch     B  close",
			touch = "Tap FLIP on each switch in order",
		})
		step = 2
	end

	local function beginLever()
		for _, sw in switches do
			sw.frame.Visible = false
		end
		switchLbl.Visible = false
		leverBar.Visible, leverBtn.Visible, leverLbl.Visible = true, true, true
		newLeverZone()
		api.status("Pull the lever when the marker is in the green", C.dim)
		api.hints({
			kb = "E  pull lever     Esc  close",
			pad = "A  pull lever     B  close",
			touch = "Tap PULL LEVER in the green",
		})
		step = 3
		leverBtn.Activated:Connect(function()
			if step == 3 and api.alive() then
				g.confirm(true)
			end
		end)
	end

	api.hold(primeBtn, function()
		if step == 1 then
			priming = true
		end
	end, function()
		if api.alive() then
			priming = false
		end
	end)

	function g.confirm(down: boolean)
		if step == 1 then
			if down then
				priming = true
			else
				priming = false
			end
		elseif step == 2 and down then
			g.digit(swSel) -- gamepad: D-pad picks, A flips
		elseif step == 3 and down then
			local hit = leverX >= leverLo and leverX <= leverHi
			if hit then
				api.sfx(BEEP, 0.35, 1.5)
				api.status("START SEQUENCE COMPLETE", C.green)
				api.finish(true)
			else
				api.shake(5)
				api.sfx("LowStinger", 0.2, 1.3)
				api.status("MISSED // TRY AGAIN", C.red)
			end
		end
	end

	function g.dir(d: Vector2)
		if step == 2 and d.X ~= 0 then
			swSel = math.clamp(swSel + d.X, 1, 3)
			api.sfx(BEEP, 0.08, 1.2)
		end
	end

	function g.digit(n: number)
		if step ~= 2 then
			return
		end
		local sw = switches[n]
		if not sw or sw.flipped then
			return
		end
		if ORDER[orderIdx] ~= n then
			api.shake(4)
			api.sfx("LowStinger", 0.2, 1.3)
			api.status("WRONG ORDER // TRY AGAIN", C.red)
			return
		end
		sw.flipped = true
		sw.lever.BackgroundColor3 = C.green
		sw.stroke.Color = C.green
		api.sfx(BEEP, 0.25, 1.4)
		orderIdx += 1
		if orderIdx > #ORDER then
			api.after(0.25, beginLever)
		end
	end

	function g.update(dt: number)
		if step == 1 then
			if priming then
				primeLevel = math.min(1, primeLevel + dt / 2.2)
			else
				primeLevel = math.max(0, primeLevel - dt / 1.4)
			end
			primeFill.Size = UDim2.fromScale(primeLevel, 1)
			primeBtn.BackgroundColor3 = if priming then C.sel else C.bgHi
			if primeLevel >= 1 and not primed then
				primed = true
				api.status("Pump primed", C.green)
				api.after(0.2, beginPrime)
			end
		elseif step == 3 then
			leverX += leverDir * dt * 0.6
			if leverX >= 1 then
				leverX, leverDir = 1, -1
			elseif leverX <= 0 then
				leverX, leverDir = 0, 1
			end
			leverMarker.Position = UDim2.fromScale(leverX, 0.5)
		end
		if step == 2 then
			for i, sw in switches do
				local s = sw.btn:FindFirstChildOfClass("UIStroke")
				if s then
					s.Color = if i == swSel then C.text else C.cyan
					s.Transparency = if i == swSel then 0 else 0.5
				end
			end
		end
	end

	return g
end

local TITLES_OBJECT = {} -- ObjectiveId -> ObjectText, from DreamEvents
for id, def in DreamEvents.Objectives do
	if def.object then
		TITLES_OBJECT[id] = def.object
	end
end

----------------------------------------------------------------------------
-- Input (bound only while a minigame is open, above every other binding)
----------------------------------------------------------------------------
local K = Enum.KeyCode
local DIRS = {
	[K.W] = Vector2.new(0, 1), [K.Up] = Vector2.new(0, 1), [K.DPadUp] = Vector2.new(0, 1),
	[K.S] = Vector2.new(0, -1), [K.Down] = Vector2.new(0, -1), [K.DPadDown] = Vector2.new(0, -1),
	[K.A] = Vector2.new(-1, 0), [K.Left] = Vector2.new(-1, 0), [K.DPadLeft] = Vector2.new(-1, 0), [K.ButtonL1] = Vector2.new(-1, 0),
	[K.D] = Vector2.new(1, 0), [K.Right] = Vector2.new(1, 0), [K.DPadRight] = Vector2.new(1, 0), [K.ButtonR1] = Vector2.new(1, 0),
}
local CONFIRM = { [K.Space] = true, [K.E] = true, [K.Return] = true, [K.KeypadEnter] = true, [K.ButtonA] = true }
local DIGITS = {
	[K.Zero] = 0, [K.One] = 1, [K.Two] = 2, [K.Three] = 3, [K.Four] = 4, [K.Five] = 5, [K.Six] = 6, [K.Seven] = 7, [K.Eight] = 8, [K.Nine] = 9,
	[K.KeypadZero] = 0, [K.KeypadOne] = 1, [K.KeypadTwo] = 2, [K.KeypadThree] = 3, [K.KeypadFour] = 4,
	[K.KeypadFive] = 5, [K.KeypadSix] = 6, [K.KeypadSeven] = 7, [K.KeypadEight] = 8, [K.KeypadNine] = 9,
}
local BOUND = { K.Thumbstick1, K.ButtonB, K.Backspace }
for k in DIRS do
	table.insert(BOUND, k)
end
for k in CONFIRM do
	table.insert(BOUND, k)
end
for k in DIGITS do
	table.insert(BOUND, k)
end

local function cancel()
	if cur and not cur.done then
		close() -- silent: nothing is sent, the prompt stays usable
	end
end

local function fireDir(d: Vector2, fromStick: boolean?)
	local g = cur and not cur.done and cur.game
	if g and g.dir then
		g.dir(d, fromStick)
	end
end

local eLatch = false
local latchMode = false
local HOLD_KINDS = { WaterGauge = true, Generator = true, Telescope = true }
local function onAction(_name: string, state: Enum.UserInputState, input: InputObject)
	if not cur then
		return Enum.ContextActionResult.Pass
	end
	local k = input.KeyCode
	local began = state == Enum.UserInputState.Begin
	local ended = state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel
	local g = if cur.done then nil else cur.game
	if k == K.Thumbstick1 then
		local p = Vector2.new(input.Position.X, input.Position.Y)
		stick = if p.Magnitude < 0.2 or ended then Vector2.zero else p
		local d: Vector2? = stickDir
		if stick.Magnitude > 0.65 then
			d = if math.abs(stick.X) > math.abs(stick.Y) then Vector2.new(math.sign(stick.X), 0) else Vector2.new(0, math.sign(stick.Y))
		elseif stick.Magnitude < 0.35 then
			d = nil
		end
		if d ~= stickDir then
			stickDir = d
			if d then
				fireDir(d, true)
				repeatDir, repeatAt = d, os.clock() + 0.38
			elseif repeatDir then
				repeatDir = nil
			end
		end
	elseif DIRS[k] then
		if began then
			held[k] = DIRS[k]
			fireDir(DIRS[k], false)
			repeatDir, repeatAt = DIRS[k], os.clock() + 0.38
		elseif ended then
			held[k] = nil
			if repeatDir == DIRS[k] then
				repeatDir = nil
			end
		end
	elseif k == K.ButtonB then
		if began then
			cancel()
		end
	elseif CONFIRM[k] then
		if g and g.confirm and k == K.E then
			-- Arduino console can't report a held button: E taps latch hold on/off.
			if began and latchMode then
				eLatch = not eLatch
				g.confirm(eLatch, k)
			elseif began then
				g.confirm(true, k)
				g.confirm(false, k)
			end
		elseif g and g.confirm and (began or ended) then
			g.confirm(began, k)
		end
	elseif DIGITS[k] then
		if began and g and g.digit then
			g.digit(DIGITS[k])
		end
	elseif k == K.Backspace then
		if began and g and g.back then
			g.back()
		end
	end
	return Enum.ContextActionResult.Sink
end

-- Esc is reserved by the Roblox menu for CAS, so watch it directly.
UserInputService.InputBegan:Connect(function(input)
	if input.KeyCode == K.Escape then
		cancel()
	end
end)
closeBtn.Activated:Connect(cancel)

----------------------------------------------------------------------------
-- Open / loop
----------------------------------------------------------------------------
local function open(id: string, kind: string, params: { [string]: any })
	eLatch = false
	latchMode = HOLD_KINDS[kind] == true
	local builder = Games[kind]
	if not builder then
		warn("[Minigames] unknown kind", kind)
		return
	end
	if cur and cur.id == id and not cur.done then
		return -- already playing it
	end
	close()
	local def = DreamEvents.Objectives[id]
	local c = {
		id = id,
		kind = kind,
		conns = {},
		openedAt = os.clock(),
		minTime = (def and def.minTime) or 0.5,
		done = false,
		hints = nil,
		game = nil,
	}
	cur = c
	-- "R_LSReadout" -> "LS READOUT"
	title.Text = string.upper((string.gsub(string.gsub(kind, "^%u%d?_", ""), "(%l)(%u)", "%1 %2")))
	subtitle.Text = if def then tostring(def.text) else ""
	status.Text = ""
	status.TextColor3 = C.text
	panelStroke.Color = C.cyan
	panelStroke.Transparency = 0.6
	local api = makeApi(c)
	local ok, g = pcall(builder, body, if type(params) == "table" then params else {}, api)
	if not ok or type(g) ~= "table" then
		warn("[Minigames] failed to build", kind, g)
		close()
		return
	end
	c.game = g
	lockPlayer(true)
	ContextActionService:BindActionAtPriority(ACTION, onAction, false, Enum.ContextActionPriority.High.Value + 100, table.unpack(BOUND))
	shade.Visible = true
	updateScale()
	panel.Position = UDim2.new(0.5, 0, 0.5, 18)
	shade.BackgroundTransparency = 1
	TweenService:Create(shade, TweenInfo.new(0.2), { BackgroundTransparency = 0.45 }):Play()
	local popY = 18
	sfx(BEEP, 0.25, 1.1)
	table.insert(c.conns, RunService.RenderStepped:Connect(function(dt)
		if cur ~= c then
			return
		end
		-- held keys + analog stick -> axis (x right, y up)
		local axis = stick
		for _, v in held do
			axis += v
		end
		if axis.Magnitude > 1 then
			axis = axis.Unit
		end
		if repeatDir and g.repeatDirs and os.clock() >= repeatAt then
			repeatAt = os.clock() + 0.09
			fireDir(repeatDir, stickDir ~= nil)
		end
		local okU, err = pcall(g.update or function() end, dt, if c.done then Vector2.zero else axis)
		if not okU then
			warn("[Minigames] update error", kind, err)
			close()
			return
		end
		popY = popY * math.max(0, 1 - dt * 14)
		shakeMag = shakeMag * math.exp(-dt * 9)
		if shakeMag < 0.2 then
			shakeMag = 0
		end
		panel.Position = UDim2.new(0.5, (math.random() - 0.5) * 2 * shakeMag, 0.5, popY + (math.random() - 0.5) * 2 * shakeMag)
	end))
end

PlayCue.OnClientEvent:Connect(function(cue: any, p: any)
	if cue ~= "Minigame" or type(p) ~= "table" or type(p.objectiveId) ~= "string" or type(p.kind) ~= "string" then
		return
	end
	if curState ~= nil and not PLAY_STATES[curState] then
		return
	end
	open(p.objectiveId, p.kind, p.params)
end)

StateChanged.OnClientEvent:Connect(function(state: any, payload: any)
	curState = state
	if type(payload) == "table" and type(payload.objectives) == "table" then
		for _, o in payload.objectives do
			if type(o) == "table" and type(o.id) == "string" then
				objectiveDone[o.id] = o.done == true
			end
		end
	end
	if not cur then
		return
	end
	if not PLAY_STATES[state] then
		close() -- Pause, cutscenes, game over... the prompt is re-used afterwards
		return
	end
	if type(payload) == "table" and type(payload.objectives) == "table" then
		for _, o in payload.objectives do
			if type(o) == "table" and o.id == cur.id and (o.done or not o.active) then
				close()
				return
			end
		end
	end
end)

-- Readable prompts: "Calibrate / Life support" instead of a bare verb.
local function applyObject(p: Instance)
	if not p:IsA("ProximityPrompt") then
		return
	end
	local id = p:GetAttribute("ObjectiveId")
	local text = type(id) == "string" and TITLES_OBJECT[id]
	if text then
		p.ObjectText = text
	end
end
for _, p in CollectionService:GetTagged("AuroraPrompt") do
	applyObject(p)
end
CollectionService:GetInstanceAddedSignal("AuroraPrompt"):Connect(applyObject)
