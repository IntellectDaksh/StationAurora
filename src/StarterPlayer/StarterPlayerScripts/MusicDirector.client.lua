-- MusicDirector: the only music system. Picks a score per game moment, 3s crossfades,
-- ducks under Dialogue and scare cues. Player music volume is applied by HUDController on
-- SoundService.Master.Music (AuroraBase * pref), so tracks here only set their own mix level.
local RS = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Remotes = RS:WaitForChild("Remotes")

local master = SoundService:FindFirstChild("Master") or Instance.new("SoundGroup")
master.Name = "Master"; master.Parent = SoundService
local group = master:FindFirstChild("Music") or Instance.new("SoundGroup")
group.Name = "Music"; group.Parent = master

-- verified in play mode (TimeLength > 0)
local TRACKS = {
	menu      = { 1846999611, 0.5 }, -- Unearthly
	intro     = { 1846999566, 0.6 },  -- Looming Dangers
	blackout  = { 1843736075, 0.6 },  -- Tension Repeat Drones 11
	calm      = { 1846999601, 0.3 }, -- Sombre Clouds
	tasks     = { 1843735981, 0.35 }, -- Tension Repeat Drones 9
	distress  = { 1838457617, 0.5 },  -- Clair De Lune
	dream1    = { 1846999567, 0.6 },  -- Creepy Night
	dream2    = { 1843736138, 0.55 }, -- Tension Repeat Drones 12
	dream3    = { 1843736197, 0.5 }, -- Slow Motion
	dream4    = { 1843736221, 0.55 }, -- Narrow Escape
	choice    = { 1848028342, 0.5 },  -- Nocturne Op.9
	endDream  = { 9125603134, 0.6 },  -- Heavenly Presence choral
	endReal   = { 1838457617, 0.55 }, -- Clair De Lune
	gameover  = { 1843736088, 0.6 },  -- Tension Repeat Drones 10
}

local sounds = {}
local function get(key)
	if sounds[key] then return sounds[key] end
	local t = TRACKS[key]
	local s = Instance.new("Sound")
	s.Name = "Music_" .. key
	s.SoundId = "rbxassetid://" .. t[1]
	s.Looped = true
	s.Volume = 0
	s.SoundGroup = group
	s.Parent = SoundService
	sounds[key] = s
	return s
end

local current, duck = nil, 1
local function level(key) return TRACKS[key][2] * duck end

local function play(key)
	if key == current then return end
	local old = current and sounds[current]
	current = key
	if old then
		local tw = TweenService:Create(old, TweenInfo.new(3), { Volume = 0 })
		tw.Completed:Connect(function() if sounds[current] ~= old then old:Pause() end end)
		tw:Play()
	end
	if key then
		local s = get(key)
		if not s.IsPlaying then s.TimePosition = 0; s:Play() end
		TweenService:Create(s, TweenInfo.new(3), { Volume = level(key) }):Play()
	end
end

local duckToken = 0
local function duckFor(mult, seconds)
	duckToken += 1
	local my = duckToken
	duck = mult
	if current then TweenService:Create(sounds[current], TweenInfo.new(0.5), { Volume = level(current) }):Play() end
	task.delay(seconds, function()
		if my ~= duckToken then return end
		duck = 1
		if current then TweenService:Create(sounds[current], TweenInfo.new(1.5), { Volume = level(current) }):Play() end
	end)
end

local power, dream, state, payload = 1, nil, nil, {}

local function pick()
	local p = payload
	if state == "MainMenu" then return "menu"
	elseif state == "Intro" then return "intro"
	elseif state == "DreamLayer" or (state == "Objectives" and dream) then
		return "dream" .. math.clamp(tonumber(dream) or 1, 1, 4)
	elseif state == "Objectives" then return "tasks"
	elseif state == "Reality" then
		if power <= 0 then return "blackout" end
		if type(p.title) == "string" and p.title:find("Contact") then return "distress" end
		if p.objectives then return "tasks" end
		return "calm"
	elseif state == "EventTrigger" then
		local b = p.beat
		if b == "Drift" then return "distress"
		elseif b == "Meltdown" then return "dream4"
		elseif b == "Choice" then return "choice"
		elseif b == "Contact" then return "intro"
		elseif b == "Respawn" then return "gameover"
		elseif b == "Scare" then return current
		end
		return "calm"
	elseif state == "Choice" then return "choice"
	elseif state == "Ending" then
		return (tostring(p.variant or ""):find("Dream")) and "endDream" or "endReal"
	elseif state == "GameOver" then return "gameover"
	elseif state == "Pause" then return current
	end
	return nil -- Restart: silence
end

Remotes:WaitForChild("StateChanged").OnClientEvent:Connect(function(s, p)
	p = type(p) == "table" and p or {}
	if s == "DreamLayer" then dream = p.dream or dream
	elseif s == "Reality" or s == "MainMenu" or (s == "EventTrigger" and (p.beat == "Wake" or p.beat == "DayEnd")) then dream = nil end
	if s == "Pause" then duckFor(0.5, 1e9) elseif state == "Pause" then duckFor(1, 0) end
	state, payload = s, p
	play(pick())
end)

local ssc = Remotes:FindFirstChild("StationState_Changed")
if ssc then
	ssc.OnClientEvent:Connect(function(a, b)
		local v
		if type(a) == "table" then v = a.Power or a.power elseif a == "Power" then v = b end
		if type(v) == "number" then
			power = v
			if state == "Reality" then play(pick()) end
		end
	end)
end

Remotes:WaitForChild("PlayCue").OnClientEvent:Connect(function(cue, params)
	cue = tostring(cue)
	params = type(params) == "table" and params or {}
	if cue == "Dialogue" then
		local total = 0
		for _, l in (type(params.lines) == "table" and params.lines or {}) do total += tonumber(l.hold) or 3 end
		if total > 0 then duckFor(0.6, total) end
	elseif cue:find("Scare") or cue:find("Chase") or cue:find("Jump") or cue:find("Stinger") then
		duckFor(0.25, 3.5)
	end
end)
