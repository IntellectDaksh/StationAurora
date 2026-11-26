-- CameraEffects: client-side atmosphere for Station Aurora (lighting presets, cues, overlay, shake).
-- Everything here is local to this player: Lighting/fixture edits made on the client never replicate,
-- and every change is tweened from values snapshotted at startup so MainMenu restores the originals.
-- Contract: Remotes.PlayCue (cue, params) and Remotes.StateChanged (state, payload). Cues that end
-- on black (Sleep, ShadowFigure, Flare, JumpScare, PassOut) leave the overlay at alpha 1; Wake fades in.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local player = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FX = ReplicatedStorage:WaitForChild("AuroraFX", 10)
local SoundsFolder = FX and FX:FindFirstChild("Sounds")
local StationAudio = ReplicatedStorage:FindFirstChild("StationAudio")

----------------------------------------------------------------------------
-- Tween helper: one live tween per instance, cancelled when a new one starts
----------------------------------------------------------------------------
local liveTweens = setmetatable({}, { __mode = "k" })

local function tween(inst, t, props, style, dir)
	if not inst then
		return nil
	end
	local prev = liveTweens[inst]
	if prev then
		prev:Cancel()
		liveTweens[inst] = nil
	end
	if t <= 0 then
		for k, v in props do
			inst[k] = v
		end
		return nil
	end
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	liveTweens[inst] = tw
	tw:Play()
	return tw
end

----------------------------------------------------------------------------
-- Audio: Ambient/SFX groups under SoundService.Master, which nests under the HUD's
-- SoundService.AuroraMaster (settings volume slider) once that exists.
----------------------------------------------------------------------------
local master = SoundService:FindFirstChild("Master") or SoundService:FindFirstChild("Master", true)
if not master then
	master = Instance.new("SoundGroup")
	master.Name = "Master"
	master.Parent = SoundService
end
local function adoptAuroraMaster(g)
	if g.Name == "AuroraMaster" and g:IsA("SoundGroup") and g ~= master then
		master.Parent = g
	end
end
local existing = SoundService:FindFirstChild("AuroraMaster")
if existing then
	adoptAuroraMaster(existing)
end
SoundService.ChildAdded:Connect(adoptAuroraMaster)

local function soundGroup(name)
	local g = master:FindFirstChild(name)
	if not g then
		g = Instance.new("SoundGroup")
		g.Name = name
		g.Parent = master
	end
	return g
end
local AmbientGroup = soundGroup("Ambient")
local SfxGroup = soundGroup("SFX")
local MusicGroup = soundGroup("Music")
MusicGroup.Volume = 0.35

local function template(name)
	local t = SoundsFolder and SoundsFolder:FindFirstChild(name)
	if not t and StationAudio then
		t = StationAudio:FindFirstChild(name)
	end
	return (t and t:IsA("Sound")) and t or nil
end

local function fadeOutDestroy(s, t)
	if not s or not s.Parent then
		return
	end
	tween(s, t, { Volume = 0 })
	task.delay(t + 0.05, function()
		s:Destroy()
	end)
end

-- Missing template = silent, never an error.
local function oneShot(name, props, maxTime)
	local t = template(name)
	if not t then
		return nil
	end
	local s = t:Clone()
	s.Looped = false
	s.SoundGroup = SfxGroup
	if props then
		for k, v in props do
			s[k] = v
		end
	end
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	if maxTime then
		task.delay(maxTime, fadeOutDestroy, s, 0.3)
	end
	task.delay(math.max(maxTime or 0, 20), function()
		if s.Parent then
			s:Destroy()
		end
	end)
	return s
end

-- Named loop slots (ambient, alarm, heart, rumble, static). volume is a multiplier of the template volume.
local loops = {}
local function setLoop(slot, name, volume, fade)
	fade = fade or 1
	local cur = loops[slot]
	if cur and name and cur.name == name and cur.sound.Parent then
		tween(cur.sound, fade, { Volume = cur.base * (volume or 1) })
		return cur.sound
	end
	if cur then
		loops[slot] = nil
		fadeOutDestroy(cur.sound, fade)
	end
	if not name then
		return nil
	end
	local t = template(name)
	if not t then
		return nil
	end
	local s = t:Clone()
	s.Looped = true
	s.SoundGroup = if slot == "ambient" then AmbientGroup else SfxGroup
	s.Volume = 0
	s.Parent = SoundService
	s:Play()
	tween(s, fade, { Volume = t.Volume * (volume or 1) })
	loops[slot] = { name = name, sound = s, base = t.Volume }
	return s
end

local function duck(on)
	tween(AmbientGroup, 0.6, { Volume = if on then 0.2 else 1 })
	tween(SfxGroup, 0.6, { Volume = if on then 0.4 else 1 })
end

-- Dialogue lines duck the music bed a little more than the standard duck (its own Volume
-- property, layered under whatever `duck` is doing for the ambient/SFX groups).
local function duckMusic(on)
	do return end -- MusicDirector ducks music
	tween(MusicGroup, 0.6, { Volume = if on then 0.14 else 0.35 })
end

-- Per-state music bed, routed through Master.Music (~0.35). 2-3s crossfade between states.
local MUSIC_FOR = {
	Menu = "Music_Menu", Reality = "Music_Reality", Blackout = "Music_Blackout",
	D1 = "Music_Dream", D2 = "Music_Dream", D3pre = "Music_Dream", D3 = "Music_Dream",
	D4pre = "Music_Dream", D4 = "Music_D4",
	Void = false, -- near-silence at the Dream/Reality choice
	GameOver = "Music_Blackout", EndDream = "Music_End", EndReality = "Music_End",
}
local musicName, musicSound
local function setMusic(key)
	do return end -- MusicDirector owns music now
	local name = MUSIC_FOR[key]
	if name == musicName then
		return
	end
	musicName = name
	if musicSound then
		local old = musicSound
		musicSound = nil
		fadeOutDestroy(old, 2.5)
	end
	if not name then
		return
	end
	local t = template(name)
	if not t then
		return
	end
	local s = t:Clone()
	s.Looped = true
	s.SoundGroup = MusicGroup
	s.Volume = 0
	s.Parent = SoundService
	s:Play()
	tween(s, 3, { Volume = t.Volume })
	musicSound = s
end

----------------------------------------------------------------------------
-- Overlay: FXOverlay ScreenGui (fade, flash, vignette). Recreated if something removes it.
----------------------------------------------------------------------------
local overlay
local function getOverlay()
	if overlay and overlay.gui.Parent then
		return overlay
	end
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("FXOverlay")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "FXOverlay"
	gui.DisplayOrder = 50
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local function frame(name, color, z)
		local f = Instance.new("Frame")
		f.Name = name
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = color
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.Active = false
		f.ZIndex = z
		f.Parent = gui
		return f
	end

	-- Vignette: four black edge bands with gradients, grown inward to narrow vision.
	local vig = frame("Vignette", Color3.new(), 1)
	local edges = {}
	for _, e in {
		{ "Top", Vector2.new(0, 0), 90, false },
		{ "Bottom", Vector2.new(0, 1), -90, false },
		{ "Left", Vector2.new(0, 0), 0, true },
		{ "Right", Vector2.new(1, 0), 180, true },
	} do
		local f = Instance.new("Frame")
		f.Name = e[1]
		f.AnchorPoint = e[2]
		f.Position = UDim2.fromScale(e[2].X, e[2].Y)
		f.Size = if e[4] then UDim2.fromScale(0, 1) else UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.new()
		f.BorderSizePixel = 0
		f.Active = false
		local g = Instance.new("UIGradient")
		g.Rotation = e[3]
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(0.45, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		f.Parent = vig
		edges[e[1]] = { frame = f, vertical = e[4] }
	end

	overlay = {
		gui = gui,
		flash = frame("Flash", Color3.new(1, 1, 1), 2),
		fade = frame("Fade", Color3.new(), 3),
		edges = edges,
	}
	gui.Parent = pg
	return overlay
end

-- alpha 1 = full black
local function setFade(alpha, t, style)
	tween(getOverlay().fade, t or 0, { BackgroundTransparency = 1 - alpha }, style or Enum.EasingStyle.Sine)
end

local function setFlash(alpha, t, style)
	tween(getOverlay().flash, t or 0, { BackgroundTransparency = 1 - alpha }, style or Enum.EasingStyle.Quad, Enum.EasingDirection.In)
end

-- amount 0..0.5 of the screen covered from each edge
local function setVignette(amount, t)
	for _, e in getOverlay().edges do
		local size = if e.vertical then UDim2.fromScale(amount, 1) else UDim2.fromScale(1, amount)
		tween(e.frame, t or 0, { Size = size }, Enum.EasingStyle.Sine)
	end
end

----------------------------------------------------------------------------
-- Client-only world objects (ship, figure, window lights) live in one local folder
----------------------------------------------------------------------------
local function fxFolder()
	local f = workspace:FindFirstChild("AuroraFX_Client")
	if not f then
		f = Instance.new("Folder")
		f.Name = "AuroraFX_Client"
		f.Parent = workspace
	end
	return f
end

local gradeCC = Lighting:FindFirstChild("FX_Grade") or Instance.new("ColorCorrectionEffect")
gradeCC.Name = "FX_Grade"
gradeCC.Parent = Lighting
local spikeCC = Lighting:FindFirstChild("FX_Spike") or Instance.new("ColorCorrectionEffect")
spikeCC.Name = "FX_Spike"
spikeCC.Parent = Lighting
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
-- Dream signature layer (stacks on the preset grade). Reality = all zero: crisp, neutral, still.
local dreamCC = Lighting:FindFirstChild("FX_Dream") or Instance.new("ColorCorrectionEffect")
dreamCC.Name = "FX_Dream"
dreamCC.Parent = Lighting
local dof = Lighting:FindFirstChildOfClass("DepthOfFieldEffect") or Instance.new("DepthOfFieldEffect")
dof.Parent = Lighting
local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
local BLOOM0 = if bloom then { Intensity = bloom.Intensity, Threshold = bloom.Threshold, Size = bloom.Size } else nil
local DREAM_TINT = Color3.fromRGB(200, 214, 255):Lerp(Color3.fromRGB(214, 196, 255), 0.4) -- teal-violet, slightly wrong
local dreamLevel = 0
local function setDream(k, t)
	k = math.clamp(k or 0, 0, 1)
	dreamLevel = k
	local ti = TweenInfo.new(t or 1.5, Enum.EasingStyle.Sine)
	game:GetService("TweenService"):Create(dreamCC, ti, {
		TintColor = Color3.new(1, 1, 1):Lerp(DREAM_TINT, k), Saturation = -0.22 * k, Contrast = -0.06 * k, Brightness = 0.015 * k,
	}):Play()
	if k > 0 then
		dof.Enabled = true
		dof.FocusDistance, dof.NearIntensity = 6, 0
	end
	game:GetService("TweenService"):Create(dof, ti, {
		FarIntensity = 0.12 + 0.33 * k, InFocusRadius = 40 - 22 * k,
	}):Play()
	if k == 0 then
		task.delay(t or 1.5, function()
			if dreamLevel == 0 then
				dof.Enabled = false
			end
		end)
	end
	if bloom and BLOOM0 then
		game:GetService("TweenService"):Create(bloom, ti, {
			Intensity = BLOOM0.Intensity + 0.7 * k, Threshold = BLOOM0.Threshold - 0.55 * k, Size = BLOOM0.Size + 16 * k,
		}):Play()
	end
end

-- Originals, snapshotted before anything is touched.
local BASE = {
	Ambient = Lighting.Ambient,
	OutdoorAmbient = Lighting.OutdoorAmbient,
	Brightness = Lighting.Brightness,
	ExposureCompensation = Lighting.ExposureCompensation,
	ClockTime = Lighting.ClockTime,
	EnvironmentDiffuseScale = Lighting.EnvironmentDiffuseScale,
	EnvironmentSpecularScale = Lighting.EnvironmentSpecularScale,
	fog = if atmosphere then atmosphere.Density else 0,
	fogColor = if atmosphere then atmosphere.Color else Color3.new(1, 1, 1),
}

----------------------------------------------------------------------------
-- Station fixtures (tag Station_Light: Panel part with RoomLight + AlertLight)
----------------------------------------------------------------------------
local FIXTURE = {
	on = { enabled = true, mult = 1 },
	warm = { enabled = true, mult = 1.05, color = Color3.fromRGB(255, 212, 165), panel = Color3.fromRGB(255, 226, 190) },
	cold = { enabled = true, mult = 0.85, color = Color3.fromRGB(175, 205, 255) },
	clinical = { enabled = true, mult = 0.95, color = Color3.fromRGB(214, 230, 255), panel = Color3.fromRGB(225, 238, 255) },
	dim = { enabled = true, mult = 0.35 },
	bright = { enabled = true, mult = 2.6, color = Color3.new(1, 1, 1), panel = Color3.new(1, 1, 1) },
	gold = { enabled = true, mult = 1.25, color = Color3.fromRGB(255, 196, 120), panel = Color3.fromRGB(255, 214, 150) },
	frost = { enabled = true, mult = 0.6, color = Color3.fromRGB(150, 200, 255), panel = Color3.fromRGB(190, 225, 255) },
	off = { enabled = false },
}
local OFF_PANEL = Color3.fromRGB(28, 30, 34)

-- Strong keys on purpose: Instance proxies in a weak table can be collected and re-snapshotted
-- mid-effect (dimmed/off/alert-on values become the new "original"). Panels are static map parts.
local fixtureOrig = {}
local fixtureMode = "on"

-- Per-room tint for the functional ("warm") look. Rooms come from a fixture's "Room" attribute
-- (RoomLight-tagged fixtures) or, for legacy Station_Light panels, the nearest room anchor.
local ROOM_TINT = {
	Quarters = { Color3.fromRGB(255, 205, 160), 0.85 },
	Generator = { Color3.fromRGB(255, 190, 130), 1 },
	LifeSupport = { Color3.fromRGB(205, 228, 255), 1.1 },
	PowerGrid = { Color3.fromRGB(200, 222, 255), 1.1 },
	Observatory = { Color3.fromRGB(120, 150, 230), 0.45 },
	Hydroponics = { Color3.fromRGB(190, 140, 255), 0.9 },
	Comms = { Color3.fromRGB(255, 225, 190), 0.95 },
	Radar = { Color3.fromRGB(215, 235, 255), 0.9 },
	Operations = { Color3.fromRGB(255, 218, 175), 1 },
}
-- Room anchors: tags the map already has. ponytail: nearest-anchor guess, the Room attribute wins when set.
local ROOM_ANCHOR_TAGS = {
	Zone_Quarters = "Quarters", Objective_LifeSupport = "LifeSupport", Objective_PowerGrid = "PowerGrid",
	Objective_Observatory = "Observatory", Task_Hydroponics = "Hydroponics", Objective_Comms = "Comms",
	Objective_Radar = "Radar", Task_TaskBoard = "Operations", Objective_Generator = "Generator",
}
local function roomAnchors()
	local list = {}
	local function add(inst, room)
		local ok, pos = pcall(function()
			return inst:GetPivot().Position
		end)
		if ok and type(room) == "string" then
			table.insert(list, { room = room, pos = pos })
		end
	end
	for tag, room in ROOM_ANCHOR_TAGS do
		for _, inst in CollectionService:GetTagged(tag) do
			add(inst, room)
		end
	end
	for _, inst in CollectionService:GetTagged("RoomLight") do
		add(inst, inst:GetAttribute("Room"))
	end
	return list
end
local function nearestRoom(pos, maxDist)
	local best, bestD = nil, maxDist or 60
	for _, a in roomAnchors() do
		local d = (a.pos - pos).Magnitude
		if d < bestD then
			best, bestD = a.room, d
		end
	end
	return best
end

local function allFixtures()
	local list = CollectionService:GetTagged("Station_Light")
	for _, f in CollectionService:GetTagged("RoomLight") do
		table.insert(list, f)
	end
	return list
end

local function remember(panel)
	local o = fixtureOrig[panel]
	if o then
		return o
	end
	local part = if panel:IsA("BasePart") then panel else panel:FindFirstChildWhichIsA("BasePart", true)
	if not part then
		return nil
	end
	local room = panel:FindFirstChild("RoomLight", true)
	if not (room and room:IsA("Light")) then
		room = panel:FindFirstChildWhichIsA("Light", true)
	end
	local alert = panel:FindFirstChild("AlertLight", true)
	if alert == room then
		alert = nil
	end
	o = {
		part = part,
		color = part.Color,
		material = part.Material,
		room = room and room:IsA("Light") and room or nil,
		alert = alert and alert:IsA("Light") and alert or nil,
		roomName = panel:GetAttribute("Room") or nearestRoom(part.Position, 60),
	}
	if o.room then
		o.roomEnabled, o.roomBright, o.roomColor = o.room.Enabled, o.room.Brightness, o.room.Color
		if not o.roomEnabled or o.roomBright <= 0 then
			o.roomEnabled, o.roomBright = true, math.max(o.roomBright, 1) -- fixtures authored dark still light up
		end
	end
	if o.alert then
		o.alertEnabled, o.alertBright, o.alertColor = o.alert.Enabled, o.alert.Brightness, o.alert.Color
	end
	fixtureOrig[panel] = o
	return o
end

local function applyFixture(panel, mode)
	local o = remember(panel)
	local spec = FIXTURE[mode] or FIXTURE.on
	if not o then
		return
	end
	local part = o.part
	if spec.enabled then
		local tint = mode == "warm" and ROOM_TINT[o.roomName]
		part.Material = o.material
		part.Color = if tint then tint[1]:Lerp(Color3.new(1, 1, 1), 0.35) else (spec.panel or o.color)
		if o.room then
			o.room.Enabled = o.roomEnabled
			o.room.Brightness = o.roomBright * spec.mult * (if tint then tint[2] else 1)
			o.room.Color = if tint then tint[1] else (spec.color or o.roomColor)
		end
	else
		part.Material = Enum.Material.SmoothPlastic
		part.Color = OFF_PANEL
		if o.room then
			o.room.Enabled = false
		end
	end
end

local function setFixtures(mode)
	fixtureMode = mode
	for _, panel in allFixtures() do
		applyFixture(panel, mode)
	end
end

local function setAlerts(on)
	for _, panel in allFixtures() do
		local o = remember(panel)
		if o and o.alert then
			o.alert.Enabled = on
		end
	end
end

local function resetAlerts()
	for _, panel in allFixtures() do
		local o = remember(panel)
		if o and o.alert then
			tween(o.alert, 0, { Enabled = o.alertEnabled, Brightness = o.alertBright, Color = o.alertColor })
		end
	end
end

-- Streamed-in / later-placed fixtures pick up whatever mode is current.
for _, tag in { "Station_Light", "RoomLight" } do
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(panel)
		task.defer(applyFixture, panel, fixtureMode) -- defer: let its lights replicate first
	end)
end

-- Emergency strobes (blackout): AlertLights breathe red on a slow cycle while room lights are dead.
local emergencyThread
local function setEmergency(on)
	if on == (emergencyThread ~= nil) then
		return
	end
	if emergencyThread then
		task.cancel(emergencyThread)
		emergencyThread = nil
		resetAlerts()
	end
	if on then
		-- Rare, faint, short: a pulse every ~6-8s, barely brighter than off, gone in under a second.
		-- The torch has to carry the room; this is a heartbeat, not a light source.
		emergencyThread = task.spawn(function()
			while true do
				task.wait(6 + math.random() * 2)
				for _, panel in allFixtures() do
					local o = remember(panel)
					if o and o.alert then
						o.alert.Enabled = true
						o.alert.Color = Color3.fromRGB(255, 40, 30)
						tween(o.alert, 0.25, { Brightness = math.max(o.alertBright, 1) * 0.5 }, Enum.EasingStyle.Sine)
					end
				end
				task.wait(0.35)
				for _, panel in allFixtures() do
					local o = remember(panel)
					if o and o.alert then
						tween(o.alert, 0.55, { Brightness = 0.02 }, Enum.EasingStyle.Sine)
					end
				end
			end
		end)
	end
end

local alarmThread, pulseThread

local function stopPulse()
	if pulseThread then
		task.cancel(pulseThread)
		pulseThread = nil
		if not alarmThread then
			resetAlerts()
		end
	end
end

-- Short red pulse (Klaxon). Skipped while the full alarm owns the AlertLights.
local function pulseAlerts(duration)
	stopPulse()
	if alarmThread then
		return
	end
	pulseThread = task.spawn(function()
		local t0, on = os.clock(), false
		while os.clock() - t0 < duration do
			on = not on
			setAlerts(on)
			task.wait(0.5)
		end
		pulseThread = nil
		resetAlerts()
	end)
end

local function setAlarm(on)
	if on == (alarmThread ~= nil) then
		return
	end
	if alarmThread then
		task.cancel(alarmThread)
		alarmThread = nil
	end
	if on then
		stopPulse()
		setLoop("alarm", "SFX Siren Alarm", 1.3, 0.3)
		alarmThread = task.spawn(function()
			local phase, n = false, 0
			while true do
				phase = not phase
				n += 1
				setAlerts(phase)
				if n % 4 == 0 then
					oneShot("SFX Button Beep", { PlaybackSpeed = 1.4, Volume = 0.35 })
				end
				task.wait(0.35)
			end
		end)
	else
		setLoop("alarm", nil, nil, 0.5)
		resetAlerts()
	end
end

-- Brief blackout flicker; returns false if the cue was superseded.
local function flicker(alive, times)
	for _ = 1, times do
		setFixtures("off")
		task.wait(0.05 + math.random() * 0.1)
		if not alive() then
			return false
		end
		setFixtures("dim")
		task.wait(0.08 + math.random() * 0.18)
		if not alive() then
			return false
		end
	end
	return true
end

----------------------------------------------------------------------------
-- Window / skylight light (moonlight in Dream 2, dawn/earth-light in the endings)
----------------------------------------------------------------------------
local WINDOW_LIGHTS = {
	{ Vector3.new(-171, 36, -40), Vector3.new(1, -0.35, 0) },
	{ Vector3.new(-171, 36, -100), Vector3.new(1, -0.35, 0) },
	{ Vector3.new(-171, 36, -160), Vector3.new(1, -0.35, 0) },
	{ Vector3.new(-60, 43, -120), Vector3.new(0.15, -1, 0) },
	{ Vector3.new(-60, 43, -60), Vector3.new(0.15, -1, 0) },
	{ Vector3.new(-30, 43, -90), Vector3.new(0.15, -1, 0) },
}
local windowLights = {}

local function setWindowLight(color, t)
	if not color and #windowLights == 0 then
		return
	end
	if #windowLights == 0 or not windowLights[1].Parent or not windowLights[1].Parent.Parent then
		table.clear(windowLights)
		for _, w in WINDOW_LIGHTS do
			local p = Instance.new("Part")
			p.Name = "FX_WindowLight"
			p.Size = Vector3.new(1, 1, 1)
			p.Transparency = 1
			p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
			p.CFrame = CFrame.lookAt(w[1], w[1] + w[2])
			local s = Instance.new("SpotLight")
			s.Face = Enum.NormalId.Front
			s.Range = 60
			s.Angle = 75
			s.Shadows = true
			s.Brightness = 0
			s.Parent = p
			p.Parent = fxFolder()
			table.insert(windowLights, s)
		end
	end
	for _, s in windowLights do
		if color then
			tween(s, t, { Brightness = 1.6, Color = color })
		else
			tween(s, t, { Brightness = 0 })
		end
	end
end

----------------------------------------------------------------------------
-- Flashlight (Dream 3), respawn-safe
----------------------------------------------------------------------------
local flashlightOn = false
local flashlight

local function setFlashlight(on)
	flashlightOn = on
	if flashlight then
		flashlight:Destroy()
		flashlight = nil
	end
	if not on then
		return
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if not head then
		return
	end
	flashlight = Instance.new("SpotLight")
	flashlight.Name = "FX_Flashlight"
	flashlight.Face = Enum.NormalId.Front
	flashlight.Range = 45
	flashlight.Angle = 50
	flashlight.Brightness = 2.2
	flashlight.Color = Color3.fromRGB(255, 244, 220)
	flashlight.Shadows = true
	flashlight.Parent = head
end

player.CharacterAdded:Connect(function(char)
	flashlight = nil -- old one died with the old character
	if flashlightOn then
		char:WaitForChild("Head", 5)
		if flashlightOn then
			setFlashlight(true)
		end
	end
end)

----------------------------------------------------------------------------
-- Reality ambience: distant console chirps and vent sighs
----------------------------------------------------------------------------
local ticksThread
local function setTicks(on)
	if on == (ticksThread ~= nil) then
		return
	end
	if ticksThread then
		task.cancel(ticksThread)
		ticksThread = nil
	end
	if on then
		ticksThread = task.spawn(function()
			while true do
				task.wait(8 + math.random() * 10)
				if math.random() < 0.6 then
					oneShot("SFX Button Beep", { PlaybackSpeed = 0.55 + math.random() * 0.2, Volume = 0.06 })
				else
					oneShot("SFX Door Whoosh", { PlaybackSpeed = 0.5, Volume = 0.05 }, 3)
				end
			end
		end)
	end
end

----------------------------------------------------------------------------
-- Low O2 (<25): faint breathing loop + slow vignette pulse. Cleared by O2Refilled or Oxygen >= 25.
----------------------------------------------------------------------------
local lowO2Thread
local function setLowO2(on)
	if on == (lowO2Thread ~= nil) then
		return
	end
	if lowO2Thread then
		task.cancel(lowO2Thread)
		lowO2Thread = nil
		setVignette(0, 1.5)
	end
	if on then
		lowO2Thread = task.spawn(function()
			while true do
				oneShot("Breath", { PlaybackSpeed = 1.25 + math.random() * 0.15, Volume = 0.32 })
				setVignette(0.16, 1)
				task.wait(1.6)
				setVignette(0.06, 1.4)
				task.wait(2.2 + math.random() * 1.4)
			end
		end)
	end
end

----------------------------------------------------------------------------
-- Camera: shake + dizziness sway (FOV breathing + roll). No BlurEffect (BlurGuard kills it).
----------------------------------------------------------------------------
local shakeMag, shakeDecay = 0, 4
local swayOn, swayAmt = false, 0
-- While the Cinematics script owns the camera (AuroraClientSignals.CinematicActive), shake and
-- FOV sway stand down entirely; cinematics add their own handheld noise and restore FOV 70.
local cinematicOwned = false
local baseFov, fovTouched = 70, false
local lastApplied, lastOffset -- lets us undo our own offset if nothing else rewrote the camera

local function shake(mag, decay)
	shakeMag = math.max(shakeMag, mag)
	shakeDecay = decay or 4
end

local function setSway(on)
	swayOn = on
end

RunService:BindToRenderStep("AuroraFX", Enum.RenderPriority.Camera.Value + 1, function(dt)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	if cinematicOwned then
		lastApplied, lastOffset = nil, nil
		fovTouched = false
		return
	end
	local now = os.clock()
	swayAmt += (math.max(if swayOn then 1 else 0, dreamLevel * 0.45) - swayAmt) * math.min(1, dt * 1.2)
	if swayAmt < 0.001 then
		swayAmt = 0
	end
	if shakeMag > 0 then
		shakeMag *= math.exp(-shakeDecay * dt)
		if shakeMag < 0.01 then
			shakeMag = 0
		end
	end

	local base = cam.CFrame
	if lastApplied and base == lastApplied then
		base = lastApplied * lastOffset:Inverse() -- camera is static (scriptable); don't accumulate
	end

	if shakeMag == 0 and swayAmt == 0 then
		if lastApplied then
			cam.CFrame = base
			lastApplied, lastOffset = nil, nil
		end
		if fovTouched then
			cam.FieldOfView = baseFov
			fovTouched = false
		end
		return
	end

	local m = shakeMag
	local off = CFrame.new(
		math.noise(now * 22, 0.1) * m * 0.25,
		math.noise(now * 22, 3.7) * m * 0.25,
		0
	) * CFrame.Angles(
		math.noise(now * 18, 7.3) * m * 0.035 + math.sin(now * 0.45) * 0.015 * swayAmt,
		math.noise(now * 18, 9.1) * m * 0.035,
		math.noise(now * 18, 5.5) * m * 0.02 + math.sin(now * 0.7) * 0.04 * swayAmt
	)
	local applied = base * off
	cam.CFrame = applied
	lastApplied, lastOffset = applied, off

	if swayAmt > 0 then
		if not fovTouched then
			baseFov = cam.FieldOfView
			fovTouched = true
		end
		cam.FieldOfView = baseFov + math.sin(now * 0.9) * 4 * swayAmt
	elseif fovTouched then
		cam.FieldOfView = baseFov
		fovTouched = false
	end
end)

----------------------------------------------------------------------------
-- Ship + silhouette
----------------------------------------------------------------------------
local shipModel, shipThread

local function removeShip()
	if shipThread then
		task.cancel(shipThread)
		shipThread = nil
	end
	if shipModel then
		shipModel:Destroy()
		shipModel = nil
	end
end

-- Eases from -> to over `time`, then keeps a slow idle drift until removed.
local function showShip(from, to, time)
	removeShip()
	local tpl = FX and FX:FindFirstChild("ForeignShip")
	if not tpl then
		return nil
	end
	local m = tpl:Clone()
	m:PivotTo(from)
	m.Parent = fxFolder()
	shipModel = m
	shipThread = task.spawn(function()
		local t0 = os.clock()
		while m.Parent do
			local now = os.clock()
			local a = math.clamp((now - t0) / time, 0, 1)
			local e = 1 - (1 - a) ^ 3
			local drift = CFrame.new(0, math.sin(now * 0.2) * 1.5, math.sin(now * 0.07) * 6)
			m:PivotTo(from:Lerp(to, e) * drift)
			task.wait()
		end
	end)
	return m
end

local transient = {} -- figures etc. destroyed by clearTransient

local function spawnFigure(feet)
	local tpl = FX and FX:FindFirstChild("ShadowFigure")
	if not tpl then
		return nil
	end
	local f = tpl:Clone()
	f:ScaleTo(0.7) -- template is ~10 studs tall; 0.7 reads as a person, not a wall
	f:PivotTo(feet)
	-- the rig is pure black and vanishes in the dark: rim it in red and give it eyes
	local hl = Instance.new("Highlight")
	hl.FillColor, hl.FillTransparency = Color3.new(0, 0, 0), 0.15
	hl.OutlineColor, hl.OutlineTransparency = Color3.fromRGB(200, 20, 20), 0
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = f
	local head = f:FindFirstChild("Head", true)
	if head and head:IsA("BasePart") then
		local eyes = Instance.new("PointLight")
		eyes.Color, eyes.Range, eyes.Brightness = Color3.fromRGB(255, 30, 30), 8, 3
		eyes.Parent = head
	end
	f.Parent = fxFolder()
	table.insert(transient, f)
	return f
end

local function rayParams()
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = { fxFolder(), player.Character }
	return p
end

-- A point near the edge of the view, pulled in front of any wall, standing on the floor.
local function edgeOfFrustum()
	local cam = workspace.CurrentCamera
	local cf = cam.CFrame
	local vp = cam.ViewportSize
	local halfV = math.rad(cam.FieldOfView / 2)
	local halfH = math.atan(math.tan(halfV) * (vp.X / math.max(vp.Y, 1)))
	local side = if math.random() < 0.5 then 1 else -1
	local flatLook = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if flatLook.Magnitude < 0.1 then
		flatLook = Vector3.new(0, 0, -1)
	end
	local dir = (CFrame.Angles(0, -side * halfH * 0.8, 0) * flatLook.Unit)
	local params = rayParams()
	local dist = 22
	local hit = workspace:Raycast(cf.Position, dir * dist, params)
	if hit then
		dist = math.max(3, hit.Distance - 1.5)
	end
	local p = cf.Position + dir * dist
	local floor = workspace:Raycast(p + Vector3.new(0, 2, 0), Vector3.new(0, -30, 0), params)
	local y = if floor then floor.Position.Y else p.Y - 5
	local feet = Vector3.new(p.X, y, p.Z)
	return CFrame.lookAt(feet, Vector3.new(cf.Position.X, y, cf.Position.Z))
end

----------------------------------------------------------------------------
-- Presets
----------------------------------------------------------------------------
local function preset(t)
	return {
		lighting = {
			Ambient = t.ambient or BASE.Ambient,
			OutdoorAmbient = t.outdoor or BASE.OutdoorAmbient,
			Brightness = t.brightness or BASE.Brightness,
			ExposureCompensation = t.exposure or BASE.ExposureCompensation,
			ClockTime = t.clockTime or BASE.ClockTime,
			EnvironmentDiffuseScale = t.envDiffuse or BASE.EnvironmentDiffuseScale,
			EnvironmentSpecularScale = t.envSpecular or BASE.EnvironmentSpecularScale,
		},
		cc = {
			Brightness = t.ccB or 0,
			Contrast = t.ccC or 0,
			Saturation = t.ccS or 0,
			TintColor = t.tint or Color3.new(1, 1, 1),
		},
		atmo = { Density = t.fog or BASE.fog, Color = t.fogColor or BASE.fogColor },
		fixtures = t.fixtures or "on",
		window = t.window,
		loop = t.loop,
		loopVol = t.loopVol or 1,
		alarm = t.alarm == true,
		sway = t.sway == true,
		flashlight = t.flashlight == true,
		ticks = t.ticks == true,
		ship = t.ship == true,
		emergency = t.emergency == true,
		flickers = t.flickers == true,
		creaks = t.creaks == true,
		roomAmb = t.roomAmb == true,
		sweep = t.sweep == true, -- blackout raw-light/neon sweep
		dream = t.dream or 0, -- dream signature 0..1 (violet-teal grade, soft far blur, halo bloom, breathing FOV)
	}
end

-- Occasional single-fixture flicker (Dream 1 unease). Restores to the current mode.
local flickerThread
local function setFlickers(on)
	if on == (flickerThread ~= nil) then
		return
	end
	if flickerThread then
		task.cancel(flickerThread)
		flickerThread = nil
	end
	if on then
		flickerThread = task.spawn(function()
			while true do
				task.wait(4 + math.random() * 7)
				local list = allFixtures()
				local panel = list[math.random(1, math.max(#list, 1))]
				if panel then
					for _ = 1, math.random(2, 4) do
						applyFixture(panel, "off")
						task.wait(0.04 + math.random() * 0.08)
						applyFixture(panel, fixtureMode)
						task.wait(0.05 + math.random() * 0.15)
					end
				end
			end
		end)
	end
end

-- Dark-station bed: hull creaks and the operator's own breathing, sparse.
local creakThread
local function setCreaks(on)
	if on == (creakThread ~= nil) then
		return
	end
	if creakThread then
		task.cancel(creakThread)
		creakThread = nil
	end
	if on then
		creakThread = task.spawn(function()
			while true do
				task.wait(6 + math.random() * 8)
				if math.random() < 0.55 then
					oneShot("Creak", { PlaybackSpeed = 0.35 + math.random() * 0.2, Volume = 0.18 }, 5)
				else
					oneShot("Breath", { PlaybackSpeed = 0.9 + math.random() * 0.1, Volume = 0.22 })
				end
			end
		end)
	end
end

-- Per-room ambience loop, picked from the nearest room anchor to the character.
local ROOM_AMB = {
	Hydroponics = { "Drip", 0.8, 0.55 },
	Generator = { "MachineRoom", 1, 0.8 },
	PowerGrid = { "MachineRoom", 0.7, 1 },
	LifeSupport = { "AirVent", 1, 1 },
	Operations = { "AirVent", 0.5, 0.9 },
}
local roomAmbThread
local function setRoomAmb(on)
	if on == (roomAmbThread ~= nil) then
		return
	end
	if roomAmbThread then
		task.cancel(roomAmbThread)
		roomAmbThread = nil
		setLoop("room", nil, nil, 1.5)
	end
	if on then
		roomAmbThread = task.spawn(function()
			local cur
			while true do
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				local spec = root and ROOM_AMB[nearestRoom(root.Position, 45) or ""]
				if spec ~= cur then
					cur = spec
					local s = setLoop("room", spec and spec[1], spec and spec[2], 2)
					if s and spec then
						s.PlaybackSpeed = spec[3]
					end
				end
				task.wait(1)
			end
		end)
	end
end

----------------------------------------------------------------------------
-- Blackout raw-light + neon sweep: anything NOT on the tagged Station_Light/RoomLight
-- fixture system (stray PointLight/SpotLight/SurfaceLight, glowing Neon parts) under the
-- two map root folders. Swept once on entering/leaving Blackout, not per-frame.
-- Strong keys: same reasoning as fixtureOrig, these are static map instances.
----------------------------------------------------------------------------
local RAW_LIGHT_ROOTS = { "Space Ship Map", "Aurora Props" }
local rawLightOrig = {}
local neonOrig = {}
local rawSwept = false

local function trackedLightSet()
	local set = {}
	for _, panel in allFixtures() do
		local o = remember(panel)
		if o then
			if o.room then
				set[o.room] = true
			end
			if o.alert then
				set[o.alert] = true
			end
		end
	end
	return set
end

local function sweepBlackout(on)
	if on == rawSwept then
		return
	end
	rawSwept = on
	if on then
		local skip = trackedLightSet()
		for _, rootName in RAW_LIGHT_ROOTS do
			local root = workspace:FindFirstChild(rootName)
			if root then
				for _, inst in root:GetDescendants() do
					if (inst:IsA("PointLight") or inst:IsA("SpotLight") or inst:IsA("SurfaceLight")) and not skip[inst] then
						if rawLightOrig[inst] == nil then
							rawLightOrig[inst] = { enabled = inst.Enabled }
						end
						inst.Enabled = false
					elseif inst:IsA("BasePart") and inst.Material == Enum.Material.Neon then
						if neonOrig[inst] == nil then
							neonOrig[inst] = { material = inst.Material, color = inst.Color }
						end
						inst.Material = Enum.Material.SmoothPlastic
						inst.Color = inst.Color:Lerp(Color3.new(0, 0, 0), 0.75)
					end
				end
			end
		end
	else
		for inst, o in rawLightOrig do
			if inst.Parent then
				inst.Enabled = o.enabled
			end
		end
		table.clear(rawLightOrig)
		for inst, o in neonOrig do
			if inst.Parent then
				inst.Material = o.material
				inst.Color = o.color
			end
		end
		table.clear(neonOrig)
	end
end

local rgb = Color3.fromRGB
local PRESETS = {
	Menu = preset({ loop = "Hum", loopVol = 0.5 }),
	Reality = preset({
		ambient = rgb(24, 27, 32), outdoor = rgb(18, 22, 30), exposure = 0.05, ccC = 0.14, ccS = -0.1, tint = rgb(240, 246, 255),
		fixtures = "clinical", loop = "Hum", loopVol = 0.45, ticks = true, roomAmb = true, creaks = true,
	}),
	-- Standby-cycle blackout: room lights dead, red emergency strobes, the torch is the main light.
	-- True black: near-zero ambient/brightness/exposure/env scales, night clock, heavy dark fog
	-- so nothing reads by sky or residual GI. Only the rare, faint emergency pulse breaks it.
	Blackout = preset({
		ambient = rgb(0, 0, 0), outdoor = rgb(0, 0, 0), brightness = 0, exposure = -1.6, clockTime = 0,
		envDiffuse = 0, envSpecular = 0,
		ccC = 0.1, ccS = -0.35, tint = rgb(255, 215, 210), fog = 0.55, fogColor = rgb(3, 1, 1),
		fixtures = "off", loop = "Drone", loopVol = 0.35, emergency = true, creaks = true, sweep = true,
	}),
	-- Cinematic-only looks (AuroraClientSignals.CinematicPreset): the camera must read, whatever the state preset.
	CinSpace = preset({
		ambient = rgb(70, 74, 84), outdoor = rgb(120, 126, 140), brightness = 3, exposure = 0.25, clockTime = 14.5,
		ccC = 0.08, tint = rgb(230, 238, 255), fog = 0, fixtures = "on", loop = "Hum", loopVol = 0.25,
	}),
	CinNight = preset({
		ambient = rgb(16, 20, 28), outdoor = rgb(14, 18, 26), exposure = 0, ccC = 0.08, ccS = -0.15, tint = rgb(220, 232, 255),
		fixtures = "cold", loop = "Hum", loopVol = 0.7,
	}),
	CinFail = preset({
		ambient = rgb(34, 10, 10), outdoor = rgb(20, 6, 6), brightness = 0, exposure = -0.2, ccC = 0.12, ccS = -0.2,
		tint = rgb(255, 205, 200), fog = 0.2, fogColor = rgb(20, 4, 4), fixtures = "off", loop = "Drone", loopVol = 0.5, sweep = true,
	}),
	CinDark = preset({
		ambient = rgb(20, 6, 6), outdoor = rgb(10, 3, 3), brightness = 0, exposure = -0.5, clockTime = 0, ccC = 0.12, ccS = -0.3,
		tint = rgb(255, 210, 205), fog = 0.3, fogColor = rgb(8, 2, 2), fixtures = "off", loop = "Drone", loopVol = 0.4, sweep = true,
	}),
	CinVoid = preset({
		ambient = rgb(10, 10, 16), outdoor = rgb(0, 0, 0), brightness = 0, exposure = -0.3, ccS = -0.6,
		fog = 0.9, fogColor = rgb(0, 0, 0), fixtures = "off", loop = "Drone", loopVol = 0.35,
	}),
	D1 = preset({
		ambient = rgb(40, 44, 52), exposure = 0, ccC = 0.04, ccS = -0.08, tint = rgb(240, 244, 255),
		fog = 0.15, fogColor = rgb(150, 170, 200), fixtures = "cold", loop = "Drone", loopVol = 0.5, flickers = true, dream = 0.35,
	}),
	D2 = preset({
		ambient = rgb(28, 32, 46), outdoor = rgb(60, 80, 130), brightness = 1, exposure = -0.15,
		ccS = -0.1, tint = rgb(225, 232, 255), fog = 0.12, fogColor = rgb(60, 80, 130),
		fixtures = "dim", window = rgb(120, 150, 255), loop = "Drone", loopVol = 0.8, ship = true, dream = 0.5,
	}),
	D3pre = preset({
		ambient = rgb(32, 34, 40), outdoor = rgb(50, 54, 64), brightness = 1, exposure = -0.1,
		ccS = -0.1, tint = rgb(238, 242, 255), fixtures = "dim", loop = "Drone", loopVol = 0.6, dream = 0.55,
	}),
	D3 = preset({
		ambient = rgb(22, 22, 28), outdoor = rgb(20, 20, 26), brightness = 0.5, exposure = -0.4,
		ccB = 0, ccS = -0.15, fog = 0.2, fogColor = rgb(0, 0, 0),
		fixtures = "off", loop = "Drone", loopVol = 1, flashlight = true, creaks = true, dream = 0.7,
	}),
	D4pre = preset({
		ambient = rgb(20, 20, 24), exposure = 0, ccS = -0.2, tint = rgb(235, 240, 255),
		fixtures = "on", loop = "Hum", loopVol = 0.6, dream = 0.8,
	}),
	D4 = preset({
		ambient = rgb(50, 26, 26), outdoor = rgb(80, 40, 40), exposure = 0, ccC = 0.06, ccS = 0,
		tint = rgb(255, 228, 228), fixtures = "dim", loop = "Drone", loopVol = 0.5, alarm = true, sway = true, dream = 1,
	}),
	Void = preset({
		ambient = rgb(0, 0, 0), outdoor = rgb(0, 0, 0), brightness = 0, exposure = -3, ccB = -0.2, ccS = -1,
		fog = 0.9, fogColor = rgb(0, 0, 0), fixtures = "off", loop = "Drone", loopVol = 0.35,
	}),
	GameOver = preset({
		ambient = rgb(20, 0, 0), outdoor = rgb(10, 0, 0), brightness = 0.2, exposure = -1.5, ccS = -0.6,
		tint = rgb(255, 190, 190), fixtures = "off", loop = "Drone", loopVol = 0.4,
	}),
	EndDream = preset({
		ambient = rgb(70, 50, 25), outdoor = rgb(140, 110, 60), exposure = 0.4, ccB = 0.05, ccS = 0.1,
		tint = rgb(255, 225, 170), fixtures = "gold", window = rgb(255, 200, 130), loop = "Hum", loopVol = 0.3,
	}),
	EndFrost = preset({
		ambient = rgb(30, 45, 70), outdoor = rgb(120, 160, 210), exposure = 0.2, ccB = 0.08, ccS = -0.6,
		tint = rgb(190, 220, 255), fog = 0.6, fogColor = rgb(200, 225, 255), fixtures = "frost",
		window = rgb(170, 210, 255), loop = "Drone", loopVol = 0.3,
	}),
	EndReality = preset({
		ambient = rgb(60, 60, 64), outdoor = rgb(170, 180, 200), brightness = 3, exposure = 0.3, ccC = 0.05,
		tint = rgb(240, 245, 255), fixtures = "on", window = rgb(255, 245, 230), loop = "Hum", loopVol = 0.5,
	}),
}

local presetKey = nil
-- While a cinematic holds a look (cinKey), state/power requests are only remembered (wantedKey)
-- and applied when the cinematic releases it.
local wantedKey, cinKey = nil, nil

local function applyPreset(key, t, fromCinematic)
	if not fromCinematic then
		wantedKey = key
		if cinKey then
			return
		end
	end
	if key == presetKey then
		return
	end
	local p = PRESETS[key]
	if not p then
		return
	end
	local wasDream = dreamLevel > 0
	presetKey = key
	t = t or 1.5
	if wasDream and p.dream == 0 and (key == "Reality" or key == "Blackout") then
		-- waking ritual: hard exposure snap back to clinical white, then settle
		setDream(0, 0.25)
		setFlash(0.85, 0)
		setFlash(0, 1.1)
		tween(spikeCC, 0, { Brightness = 0.25, Contrast = 0.2 })
		tween(spikeCC, 1.2, { Brightness = 0, Contrast = 0 })
		t = math.min(t, 0.3)
	else
		setDream(p.dream, t)
	end
	tween(Lighting, t, p.lighting, Enum.EasingStyle.Sine)
	tween(gradeCC, t, p.cc, Enum.EasingStyle.Sine)
	if atmosphere and atmosphere.Parent then
		tween(atmosphere, t, p.atmo, Enum.EasingStyle.Sine)
	end
	setFixtures(p.fixtures)
	setWindowLight(p.window, t)
	setLoop("ambient", p.loop, p.loopVol, t)
	setAlarm(p.alarm)
	setSway(p.sway)
	setFlashlight(p.flashlight)
	setTicks(p.ticks)
	setEmergency(p.emergency)
	setFlickers(p.flickers)
	setCreaks(p.creaks)
	setRoomAmb(p.roomAmb)
	sweepBlackout(p.sweep)
	setMusic(key)
	if not p.ship then
		removeShip()
	end
end

local power = 100 -- Remotes.StationState_Changed snapshot.Power
local function realityLook()
	return if power < 1 then "Blackout" else "Reality"
end

local function presetFor(state, payload, dream)
	if state == "MainMenu" then
		return "Menu"
	elseif state == "Intro" then
		return "Blackout"
	elseif state == "Reality" then
		return realityLook()
	elseif state == "Choice" or state == "Restart" then
		return "Void"
	elseif state == "GameOver" then
		return "GameOver"
	elseif state == "Ending" then
		return if payload.ending == "Reality" then "EndReality" else "EndDream"
	end
	-- EventTrigger / DreamLayer / Objectives
	if dream <= 0 then
		return realityLook()
	elseif dream >= 5 then
		return "Void"
	elseif dream == 1 then
		return "D1"
	end
	local settled = state == "Objectives" or (state == "EventTrigger" and payload.beat == "Scare")
	if settled then
		return "D" .. dream
	end
	-- Wake + DreamLayer: the look before the trigger cue changes it
	return if dream == 2 then "D1" elseif dream == 3 then "D3pre" else "D4pre"
end

----------------------------------------------------------------------------
-- Cues
----------------------------------------------------------------------------
local cueToken = 0
local activeCue = nil

local function cancelCues()
	cueToken += 1
	activeCue = nil
end

local function clearTransient()
	for _, f in transient do
		f:Destroy()
	end
	table.clear(transient)
	setFlash(0, 0.25)
	tween(spikeCC, 0.4, { Brightness = 0, Contrast = 0 })
	stopPulse()
	setLoop("heart", nil, nil, 0.6)
	setLoop("rumble", nil, nil, 0.6)
	setLoop("static", nil, nil, 0.3)
end

local SHIP_WINDOW = CFrame.new(-300, 40, -40)
local SHIP_ABOVE = CFrame.new(-110, 125, -60) * CFrame.Angles(0, math.rad(90), 0)

local CUES = {}

function CUES.Sleep(alive)
	clearTransient()
	presetKey = nil -- next state re-applies its full look under the black
	setLoop("ambient", nil, nil, 2.8)
	setVignette(0.35, 2.6)
	oneShot("Breath", { Volume = 0.35, PlaybackSpeed = 0.85 })
	game:GetService("TweenService"):Create(dof, TweenInfo.new(2.4), { FarIntensity = 0.6, InFocusRadius = 6 }):Play()
	dof.Enabled = true
	setFade(1, 2.6)
end

function CUES.Wake(alive)
	clearTransient()
	setFade(1, 0)
	setVignette(0.45, 0)
	oneShot("Breath", { Volume = 0.5 })
	oneShot("Hum", { PlaybackSpeed = 0.5, Volume = 0.45 }, 5)
	local fl = getOverlay().flash
	fl.BackgroundColor3 = Color3.fromRGB(150, 120, 255)
	task.delay(0.6, function()
		setFlash(0.22, 0.6)
		task.wait(0.7)
		setFlash(0, 2.4)
		task.wait(2.5)
		fl.BackgroundColor3 = Color3.new(1, 1, 1)
	end)
	setLoop("heart", "Heartbeat", 0.8, 0.2)
	task.wait(0.3)
	-- Fade in even if the trigger cue already superseded us: none of those set their own fade,
	-- and bailing here would leave the dream stuck on black.
	setFade(0, 2)
	setVignette(0, 2.2)
	if not alive() then
		setLoop("heart", nil, nil, 1)
		return
	end
	task.wait(1.4)
	if not alive() then
		return
	end
	setLoop("heart", nil, nil, 1)
end

function CUES.Klaxon(alive)
	clearTransient()
	applyPreset("D1", 0.8)
	oneShot("SFX Siren Alarm", { Looped = true, Volume = 0.8 }, 4)
	pulseAlerts(4)
	shake(0.25, 1.5)
	flicker(alive, 2)
	if alive() and presetKey == "D1" then
		setFixtures("cold")
	end
end

function CUES.ShipArrives(alive)
	clearTransient()
	if not flicker(alive, 3) then
		return
	end
	oneShot("PowerDown", { Volume = 0.9 })
	applyPreset("D2", 1.2)
	shake(0.3, 1)
	task.wait(0.8)
	if not alive() then
		return
	end
	showShip(CFrame.new(-430, 52, -10), SHIP_WINDOW, 9)
	setLoop("rumble", "Rumble", 0.5, 1.5)
	task.wait(3)
	if not alive() then
		return
	end
	setLoop("rumble", nil, nil, 2)
end

function CUES.DeadStation(alive)
	clearTransient()
	oneShot("PowerDown", { PlaybackSpeed = 0.7, Volume = 0.9 })
	if not flicker(alive, 2) then
		return
	end
	applyPreset("D3", 0.4)
	shake(0.2, 2)
end

function CUES.AllAlarms(alive)
	clearTransient()
	applyPreset("D4", 0.6)
	shake(0.35, 1)
end

function CUES.ShadowFigure(alive)
	clearTransient()
	presetKey = nil
	setFixtures("dim")
	task.wait(0.4)
	if not alive() then
		return
	end
	local ok, feet = pcall(edgeOfFrustum)
	local fig = ok and spawnFigure(feet) or nil
	oneShot("LowStinger", { Volume = 0.9 }, 3)
	-- hold long enough to actually register, then flicker out with the lights
	task.wait(1.1)
	setFixtures("off")
	task.wait(0.12)
	setFixtures("dim")
	task.wait(0.1)
	if fig then
		fig:Destroy()
	end
	if not alive() then
		return
	end
	task.wait(0.25)
	if not alive() then
		return
	end
	setFixtures("off")
	setLoop("ambient", nil, nil, 1.2)
	setFade(1, 1)
end

function CUES.Flare(alive)
	clearTransient()
	presetKey = nil
	removeShip()
	local ship = showShip(SHIP_ABOVE * CFrame.new(0, 40, 0), SHIP_ABOVE, 2)
	setLoop("rumble", "Rumble", 1, 0.5)
	local eye = ship and ship:FindFirstChild("Eye")
	local flareLight = eye and eye:FindFirstChild("FlareLight")
	if eye then
		tween(eye, 3, { Color = Color3.new(1, 1, 1) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	if flareLight then
		tween(flareLight, 3, { Brightness = 40 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	end
	if ship then
		for _, p in ship:GetChildren() do
			if p.Name == "RunLight" and p:IsA("BasePart") then
				tween(p, 2.5, { Color = Color3.new(1, 1, 1) })
			end
		end
	end
	tween(spikeCC, 3.2, { Brightness = 0.8, Contrast = 0.3 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	setFlash(1, 3.2)
	local t0 = os.clock()
	while os.clock() - t0 < 3.3 do
		shake(0.2 + (os.clock() - t0) * 0.35, 0.5)
		task.wait(0.1)
		if not alive() then
			removeShip()
			return
		end
	end
	-- cut to black
	setFade(1, 0)
	setFlash(0, 0)
	tween(spikeCC, 0, { Brightness = 0, Contrast = 0 })
	setLoop("rumble", nil, nil, 0.15)
	setLoop("ambient", nil, nil, 0.15)
	shakeMag = 0
	removeShip()
end

function CUES.JumpScare(alive)
	clearTransient()
	presetKey = nil
	setFlashlight(false)
	setFixtures("bright")
	tween(spikeCC, 0, { Brightness = 0.12, Contrast = 0.2 })
	oneShot("PowerDown", { PlaybackSpeed = 1.6, Volume = 0.5 })
	task.wait(0.35)
	if not alive() then
		return
	end
	local cam = workspace.CurrentCamera
	local cf = cam.CFrame
	local flat = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	flat = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	-- 3 studs ahead, pulled in front of any wall so it can't spawn inside geometry
	local dist = 3
	local hit = workspace:Raycast(cf.Position, flat * dist, rayParams())
	if hit then
		dist = math.max(1.5, hit.Distance - 1)
	end
	local feet = cf.Position + flat * dist - Vector3.new(0, 6.2, 0) -- head (scaled rig) at eye level
	local fig = spawnFigure(CFrame.lookAt(feet, feet - flat))
	oneShot("Stinger", { Volume = 1 }, 3)
	shake(1.2, 5)
	task.wait(0.7)
	if fig then
		fig:Destroy()
	end
	setFade(1, 0)
	tween(spikeCC, 0, { Brightness = 0, Contrast = 0 })
	setLoop("ambient", nil, nil, 0.1)
end

function CUES.PassOut(alive)
	clearTransient()
	setAlarm(false)
	setSway(false)
	local heart = setLoop("heart", "Heartbeat", 1, 0)
	if heart then
		heart.PlaybackSpeed = 1.25
		tween(heart, 3.6, { PlaybackSpeed = 0.55 }, Enum.EasingStyle.Sine)
	end
	setLoop("ambient", nil, nil, 3)
	setVignette(0.5, 3)
	task.wait(1.5)
	if not alive() then
		return
	end
	setFade(1, 2.2)
	task.wait(2.3)
	presetKey = nil
	if not alive() then
		return
	end
	setLoop("heart", nil, nil, 0.4)
end

-- Companion dialogue: duck the music bed for the sum of the lines' hold, HUD renders the text.
function CUES.Dialogue(alive, params)
	local lines = type(params.lines) == "table" and params.lines or {}
	local total = 0
	for _, l in lines do
		total += tonumber(l.hold) or 3
	end
	if total <= 0 then
		return
	end
	duckMusic(true)
	task.wait(total)
	if alive() then
		duckMusic(false)
	else
		duckMusic(false) -- superseded cue: still restore, nothing else will
	end
end

-- Gauge chime + hiss on refill; also clears the low-O2 bed.
function CUES.O2Refilled(alive)
	setLowO2(false)
	oneShot("SFX Door Whoosh", { PlaybackSpeed = 1.6, Volume = 0.3 }, 2)
	oneShot("SFX Button Beep", { PlaybackSpeed = 1.8, Volume = 0.4 })
end

function CUES.Static(alive)
	clearTransient()
	local s = setLoop("static", "Static", 1, 0)
	if s then
		local base = s.Volume
		local t0 = os.clock()
		while os.clock() - t0 < 3 do
			s.Volume = base * (0.35 + math.random() * 0.65)
			task.wait(0.08)
			if not alive() then
				return
			end
		end
		setLoop("static", nil, nil, 0.3)
	else
		-- ponytail: fallback when the static asset is unavailable; pitched-down beeps read as a dead channel
		for _ = 1, 8 do
			oneShot("SFX Button Beep", { PlaybackSpeed = 0.45 + math.random() * 0.2, Volume = 0.3 })
			task.wait(0.35)
			if not alive() then
				return
			end
		end
	end
end

function CUES.Ending(alive, params)
	clearTransient()
	setFade(0, 1.5)
	if params.ending == "Reality" then
		applyPreset("EndReality", 3)
	else
		applyPreset("EndDream", 2)
		-- warm memory for the first lines, then the frost line lands (~line 4 of 5 at 4s each)
		task.wait(12)
		if alive() and (presetKey == "EndDream") then
			applyPreset("EndFrost", 6)
		end
	end
end

-- Backup generator start: the station comes back section by section, nearest first.
function CUES.PowerRestored(alive)
	clearTransient()
	power = math.max(power, 1)
	presetKey = "Reality" -- claim the look so a StateChanged mid-sequence doesn't jump it
	local p = PRESETS.Reality
	setCreaks(false)
	oneShot("PowerDown", { PlaybackSpeed = 0.45, Volume = 0.5 }, 3) -- low spin-up groan
	shake(0.18, 1.5)
	task.wait(1.1)
	if not alive() then
		presetKey = nil
		return
	end
	setEmergency(false)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	local origin = if root then root.Position else Vector3.zero
	local list = allFixtures()
	local dist = {}
	for _, f in list do
		local o = remember(f)
		dist[f] = if o then (o.part.Position - origin).Magnitude else math.huge
	end
	table.sort(list, function(a, b)
		return dist[a] < dist[b]
	end)
	fixtureMode = "warm"
	local sections = math.min(5, math.max(#list, 1))
	local per = math.ceil(#list / sections)
	for s = 1, sections do
		for i = (s - 1) * per + 1, math.min(s * per, #list) do
			applyFixture(list[i], "warm")
		end
		oneShot("Clunk", { PlaybackSpeed = 0.7 + math.random() * 0.25, Volume = 0.75 - s * 0.08 })
		if s == 1 then
			tween(Lighting, 4, p.lighting, Enum.EasingStyle.Sine)
			tween(gradeCC, 4, p.cc, Enum.EasingStyle.Sine)
			if atmosphere and atmosphere.Parent then
				tween(atmosphere, 4, p.atmo, Enum.EasingStyle.Sine)
			end
			setLoop("ambient", "Hum", 1, 3)
		end
		task.wait(0.5 + s * 0.08)
		if not alive() then
			setFixtures("warm")
			break
		end
	end
	setFixtures("warm")
	setTicks(true)
	setRoomAmb(true)
end

local function runCue(name, params)
	local fn = CUES[name]
	if not fn then
		return -- Keypad / Toast / NoRepairUnits belong to the HUD
	end
	cueToken += 1
	local my = cueToken
	activeCue = my
	local function alive()
		return my == cueToken
	end
	task.spawn(function()
		local ok, err = pcall(fn, alive, if type(params) == "table" then params else {})
		if not ok then
			warn("[CameraEffects] cue", name, "failed:", err)
		end
		if activeCue == my then
			activeCue = nil
		end
	end)
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local CLEAR_OVERLAY = { MainMenu = true, Intro = true, Choice = true, Ending = true, GameOver = true, Restart = true }
local lastState, lastPayload = nil, {}

local function onState(state, payload)
	if type(state) ~= "string" then
		return
	end
	payload = if type(payload) == "table" then payload else {}
	if state == "Pause" then
		duck(true)
		return
	end
	duck(false)
	local changed = state ~= lastState
	local beatChanged = changed or payload.beat ~= lastPayload.beat
	lastState, lastPayload = state, payload
	if CLEAR_OVERLAY[state] and changed then
		if state ~= "Ending" then
			cancelCues()
		end
		clearTransient()
		removeShip()
		shakeMag = 0
		setFade(0, if state == "MainMenu" then 1 else 1.5)
		setVignette(0, 0.8)
	end
	-- New day (or a daytime cinematic): the night's last scare (Flare/ShadowFigure) ends on black and
	-- can still be running. Kill it and fade in, or the morning (and its cinematic) stays black.
	if (tonumber(payload.dream) or 0) == 0
		and ((changed and state == "Reality") or (beatChanged and state == "EventTrigger" and type(payload.cinematic) == "string")) then
		cancelCues()
		clearTransient()
		removeShip()
		shakeMag = 0
		setFade(0, 1.5)
		setVignette(0, 1)
	end
	applyPreset(presetFor(state, payload, tonumber(payload.dream) or 0))
	-- Safety net: never leave a playable state stuck on black if a Wake was missed.
	if (state == "Reality" or state == "Objectives") and not activeCue then
		local fade = getOverlay().fade
		if fade.BackgroundTransparency < 0.99 then
			setFade(0, 1)
			setVignette(0, 1)
		end
	end
end

----------------------------------------------------------------------------
-- Cinematics integration (client BindableEvents under ReplicatedStorage.AuroraClientSignals)
--   CinematicActive(on, id)   camera ownership: suspend shake/sway while on
--   CinematicFixtures(mode?)  cinematic lighting beats: a FIXTURE mode, or nil = back to the preset
----------------------------------------------------------------------------
do
	local f = ReplicatedStorage:FindFirstChild("AuroraClientSignals")
	if not f then
		f = Instance.new("Folder")
		f.Name = "AuroraClientSignals"
		f.Parent = ReplicatedStorage
	end
	local function ev(name)
		local e = f:FindFirstChild(name)
		if not e then
			e = Instance.new("BindableEvent")
			e.Name = name
			e.Parent = f
		end
		return e
	end
	local function setCinPreset(key, t)
		if type(key) == "string" and PRESETS[key] then
			cinKey = key
			applyPreset(key, t or 0.8, true)
		elseif cinKey then
			cinKey = nil
			if wantedKey then
				applyPreset(wantedKey, t or 1.2, true)
			end
		end
	end
	ev("CinematicPreset").Event:Connect(setCinPreset)
	ev("CinematicActive").Event:Connect(function(on)
		cinematicOwned = on == true
		if cinematicOwned then
			shakeMag = 0
		else
			setCinPreset(nil) -- a cinematic never keeps its look past its end
		end
	end)
	ev("CinematicFixtures").Event:Connect(function(mode, origin, span)
		if mode == "cascade" then
			-- lights die one by one, farthest from origin first, over `span` seconds
			local list = allFixtures()
			local o = typeof(origin) == "Vector3" and origin or Vector3.zero
			local d = {}
			for _, f in list do
				local r = remember(f)
				d[f] = if r then (r.part.Position - o).Magnitude else 0
			end
			table.sort(list, function(a, b)
				return d[a] > d[b]
			end)
			local gap = (tonumber(span) or 2.5) / math.max(#list, 1)
			for _, f in list do
				applyFixture(f, "off")
				oneShot("Clunk", { PlaybackSpeed = 0.6 + math.random() * 0.3, Volume = 0.35 })
				task.wait(gap)
			end
			fixtureMode = "off"
		elseif type(mode) == "string" and FIXTURE[mode] then
			setFixtures(mode)
		else
			local p = presetKey and PRESETS[presetKey]
			setFixtures(if p then p.fixtures else "on")
		end
	end)
end

-- Power drives the Reality look (blackout <-> functional). A rise waits briefly for the
-- PowerRestored cue so the section-by-section cut-in isn't pre-empted by a plain crossfade.
Remotes:WaitForChild("StationState_Changed").OnClientEvent:Connect(function(snap)
	if type(snap) == "table" then
		local o2 = tonumber(snap.Oxygen)
		if o2 then
			setLowO2(o2 < 25)
		end
	end
	local v = type(snap) == "table" and tonumber(snap.Power)
	if not v then
		return
	end
	local was = power
	power = v
	if not lastState or lastState == "Pause" then
		return
	end
	local function reapply()
		local key = presetFor(lastState, lastPayload, tonumber(lastPayload.dream) or 0)
		if key ~= presetKey and (key == "Blackout" or presetKey == "Blackout") then
			applyPreset(key)
		end
	end
	if was < 1 and v >= 1 then
		task.delay(1.5, reapply)
	elseif v < 1 then
		reapply()
	end
end)

getOverlay()
Remotes:WaitForChild("StateChanged").OnClientEvent:Connect(onState)
Remotes:WaitForChild("PlayCue").OnClientEvent:Connect(runCue)

----------------------------------------------------------------------------
-- Night mini-anomalies (server: ObjectiveHandlers.StoryProps fires PlayCue "Mini").
-- Own connection, outside runCue, so they never cancel a running cue. Cosmetic; fail silent.
----------------------------------------------------------------------------
do
	local Debris = game:GetService("Debris")
	local FXF = game:GetService("ReplicatedStorage"):FindFirstChild("AuroraFX")
	local lp = game:GetService("Players").LocalPlayer

	local function rootPos()
		local r = lp.Character and lp.Character:FindFirstChild("HumanoidRootPart")
		return r and r.Position
	end

	local function emitter(pos, life)
		local p = Instance.new("Part")
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.Transparency = true, false, false, false, 1
		p.Size = Vector3.one
		p.Position = pos
		p.Parent = workspace
		Debris:AddItem(p, life or 8)
		return p
	end

	local function at(pos, name, props)
		local src = FXF and FXF:FindFirstChild("Sounds") and FXF.Sounds:FindFirstChild(name)
		if not (src and src:IsA("Sound")) then
			return nil
		end
		local s = src:Clone()
		s.Looped = false
		s.RollOffMaxDistance = 80
		for k, v in props or {} do
			s[k] = v
		end
		s.Parent = emitter(pos)
		s:Play()
		return s
	end

	local MINI = {}
	-- someone walking across the ceiling, over your head
	function MINI.Footsteps()
		local r = rootPos()
		if not r then
			return
		end
		local dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
		local e = emitter(r + Vector3.new(0, 9, 0) - dir * 14, 6)
		local s = Instance.new("Sound")
		s.SoundId = "rbxasset://sounds/action_footsteps_plastic.mp3"
		s.Volume, s.PlaybackSpeed, s.RollOffMaxDistance, s.Looped = 0.9, 0.8, 60, true
		s.Parent = e
		s:Play()
		game:GetService("TweenService"):Create(e, TweenInfo.new(3.2, Enum.EasingStyle.Linear), { Position = r + Vector3.new(0, 9, 0) + dir * 14 }):Play()
		task.delay(3.2, function()
			s:Stop()
		end)
	end
	function MINI.Knock(p)
		local r = rootPos()
		local pos = typeof(p.pos) == "Vector3" and p.pos or (r and r + Vector3.new(8, 2, 0))
		if not pos then
			return
		end
		for i = 1, 3 do
			at(pos, "Clunk", { PlaybackSpeed = 1.5 + i * 0.03, Volume = 0.9 })
			task.wait(0.38)
		end
	end
	function MINI.Moved(p)
		if typeof(p.pos) == "Vector3" then
			at(p.pos, "Creak", { Volume = 0.8 })
		end
	end
	function MINI.Whisper(p)
		if typeof(p.pos) == "Vector3" then
			at(p.pos, "Static", { Volume = 0.35, PlaybackSpeed = 0.7 })
		end
	end
	-- a figure behind the nearest window glass, facing you, gone before you're sure
	function MINI.Silhouette()
		local r = rootPos()
		local fig = FXF and FXF:FindFirstChild("ShadowFigure")
		if not (r and fig) then
			return
		end
		local best, bestD
		for _, g in workspace:GetDescendants() do
			if g:IsA("BasePart") and g.Material == Enum.Material.Glass then
				local d = (g.Position - r).Magnitude
				if d > 8 and d < 70 and (not bestD or d < bestD) then
					best, bestD = g, d
				end
			end
		end
		if not best then
			return
		end
		local out = best.Position - r
		out = Vector3.new(out.X, 0, out.Z).Unit
		local pos = best.Position + out * 5
		local m = fig:Clone()
		m:PivotTo(CFrame.lookAt(pos, Vector3.new(r.X, pos.Y, r.Z)))
		m.Parent = workspace
		at(pos, "LowStinger", { Volume = 0.4 })
		task.wait(1.1)
		m:Destroy()
	end
	-- lights die in a line, from far down the corridor to right above you
	function MINI.LightChase()
		local r = rootPos()
		if not r then
			return
		end
		local lights = {}
		for _, l in workspace:GetDescendants() do
			if l:IsA("Light") and l.Enabled and l.Parent and l.Parent:IsA("BasePart") then
				local d = (l.Parent.Position - r).Magnitude
				if d < 70 then
					table.insert(lights, { l = l, d = d })
				end
			end
		end
		table.sort(lights, function(a, b)
			return a.d > b.d
		end)
		local n = math.min(#lights, 14)
		for i = #lights - n + 1, #lights do
			local l = lights[i].l
			l.Enabled = false
			task.delay(0.35, function()
				l.Enabled = true
			end)
			task.wait(0.09)
		end
		if n > 0 then
			at(r + Vector3.new(0, 6, 0), "Clunk", { PlaybackSpeed = 0.6, Volume = 0.6 })
		end
	end

	Remotes:WaitForChild("PlayCue").OnClientEvent:Connect(function(cue, params)
		local fn = cue == "Mini" and type(params) == "table" and MINI[params.kind]
		if fn then
			task.spawn(function()
				local ok, err = pcall(fn, params)
				if not ok then
					warn("[CameraEffects] mini", params.kind, err)
				end
			end)
		end
	end)
end
