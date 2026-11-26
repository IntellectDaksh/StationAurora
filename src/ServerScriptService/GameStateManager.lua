--!strict
-- GameStateManager: the single owner of every player's game state (PRD §3, §6).
-- One Session per player runs a director coroutine through the story:
--   MainMenu -> Intro -> for day 1..4: [Reality tasks -> sleep -> Dream <day> (EventTrigger ->
--   DreamLayer -> Objectives) -> DayEnd (autosave, checkpoint "Day" = start of next day)]
--   -> Choice -> Ending -> Restart -> MainMenu
-- Every payload carries day / dayTime / dayTitle / dayLog (DreamEvents.Days) for the HUD badge.
-- Pause overlays any pausable state; GameOver interrupts Objectives on failure.
--
-- Contract for ObjectiveHandlers (ServerScriptService.ObjectiveHandlers.<def.handler>):
--   handler.onTriggered(session, def, prompt): boolean        -- prompt fired; true = objective done
--   handler.onClientComplete(session, def, data): boolean     -- optional, RequestObjectiveComplete
--   handler.onActivated(session, def)                         -- optional, objective became active
--   handler.onMinigameOpen(session, def)                      -- optional, minigame objective's prompt fired
--   Handlers must NOT yield and must NOT change state; blocking cues belong to the director.
--
-- ObjectiveDef extras (see DreamEvents):
--   minigame = "<Kind>", minigameParams = {...}, minTime = n
--       Prompt opens PlayCue("Minigame", {objectiveId, kind, params}); the client plays it and sends
--       RequestObjectiveComplete(id, {success = true, ...}). Server checks the minigame was opened
--       and minTime elapsed, then asks handler.onClientComplete (if any) else handler.onTriggered.
--   clientAction = true   no prompt; completes when the client reports it (tutorial key presses).
--   reach = radius        no prompt; completes when the character is within radius of the tagged part.
--   beatOnActivate / beatOnComplete = "<Beats id>"   non-blocking dialogue/hint.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local Modules = (ReplicatedStorage :: any).Modules
local Remotes = (ReplicatedStorage :: any).Remotes
local Enum_ = require(Modules.GameStateEnum)
local DreamEvents = require(Modules.DreamEvents)
local StationState = require(Modules.StationState)
local SaveSystem = require(ServerScriptService.SaveSystem)
local ScareDirector = require(ServerScriptService.ScareDirector)
local Beats = require(Modules.Beats)
local Cinematics = require(Modules.Cinematics)
local StoryProps = require(ServerScriptService.ObjectiveHandlers.StoryProps)

local S = Enum_.States
local Objectives = DreamEvents.Objectives

-- dream id -> the story day whose night runs it (DreamEvents.Days[n].dreams)
local dreamDay: { [number]: number } = {}
for n, d in DreamEvents.Days do
	for _, id in d.dreams do
		dreamDay[id] = n
	end
end

-- Night consequences that persist into later days exactly as if real (brief §2).
-- Set when a night's anomaly finishes, saved in save.world, re-applied on Continue. Never narrated.
-- ponytail: world is shared, so this assumes one operator per server (the game is single-player).
local WORLD_FX_TAG = "AuroraWorldFX"
local function tagged(tag: string): BasePart?
	local inst = CollectionService:GetTagged(tag)[1]
	if not inst then
		return nil
	end
	return if inst:IsA("BasePart") then inst else (inst:IsA("Model") and (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true))) or nil
end
local function fx(parent: Instance?, class: string, props: { [string]: any })
	if not parent then
		return
	end
	local i = Instance.new(class)
	for k, v in props do
		(i :: any)[k] = v
	end
	CollectionService:AddTag(i, WORLD_FX_TAG)
	i.Parent = parent
end
local WORLD: { [string]: () -> () } = {
	-- after the scope night: the observatory scope is left powered, its eyepiece still lit
	ScopeLeftOn = function()
		fx(tagged("Objective_Observatory"), "PointLight", { Color = Color3.fromRGB(90, 200, 255), Range = 10, Brightness = 1.5 })
	end,
	-- after the blackout night: grid panel scorched and sparking, nearest door jammed open
	GridScorched = function()
		local grid = tagged("Objective_PowerGrid")
		fx(grid, "Sparkles", { SparkleColor = Color3.fromRGB(255, 170, 60) })
		fx(grid, "Smoke", { Color = Color3.fromRGB(40, 40, 40), Opacity = 0.15, RiseVelocity = 1, Size = 1 })
		fx(grid, "PointLight", { Color = Color3.fromRGB(255, 80, 40), Range = 8, Brightness = 1 })
	end,
	DoorJammed = function()
		local grid = tagged("Objective_PowerGrid")
		local best, bestD = nil, math.huge
		for _, door in CollectionService:GetTagged("PowerDoor") do
			if door:IsA("Model") and grid then
				local d = (door:GetPivot().Position - grid.Position).Magnitude
				if d < bestD then
					best, bestD = door, d
				end
			end
		end
		if best then
			best:SetAttribute("StuckOpen", true)
		end
	end,
}
-- which flags each night leaves behind
local NIGHT_FLAGS: { [number]: { string } } = { [2] = { "ScopeLeftOn" }, [3] = { "GridScorched", "DoorJammed" } }

local function clearWorld()
	for _, i in CollectionService:GetTagged(WORLD_FX_TAG) do
		i:Destroy()
	end
	for _, door in CollectionService:GetTagged("PowerDoor") do
		door:SetAttribute("StuckOpen", nil)
	end
end

local WALK_SPEED = 16
local JUMP_HEIGHT = 7.2
local REMOTE_GAP = 0.15
local PROMPT_DISTANCE = 10

-- Sentinel errors used to unwind the director cleanly.
local ENDED = table.freeze({ reason = "ENDED" }) -- player left
local ABORT = table.freeze({ reason = "ABORT" }) -- quit to menu from pause
local FAILED = table.freeze({ reason = "FAILED" }) -- fail condition hit

local GameStateManager = {}
local sessions: { [Player]: any } = {}
local starting: { [Player]: boolean } = {}

-- QA only: in Studio, workspace attribute AuroraQATimeScale (e.g. 10) fast-forwards every wait.
local function timeScale(): number
	if RunService:IsStudio() then
		local s = workspace:GetAttribute("AuroraQATimeScale")
		if type(s) == "number" and s > 0 then
			return s
		end
	end
	return 1
end

----------------------------------------------------------------------------
-- Session
----------------------------------------------------------------------------
local Session = {}
Session.__index = Session

function Session.new(player: Player)
	return setmetatable({
		player = player,
		state = S.MainMenu,
		payload = {},
		paused = false,
		alive = true,
		abort = false,
		failed = false,
		failReason = nil :: string?,
		dream = 0,
		day = 1,
		canFail = false,
		oxygenDrain = 0.02,
		active = {} :: { [string]: boolean },
		completed = {} :: { [string]: boolean },
		objectiveList = {} :: { string },
		flags = {} :: { [string]: any },
		firedCues = {} :: { [string]: number },
		menuChoice = nil :: string?,
		choice = nil :: string?,
		skipIntro = false,
		minigames = {} :: { [string]: number }, -- objective id -> os.clock() opened
		appliedWorld = {} :: { [string]: boolean },
		lastRemote = {} :: { [string]: number },
		station = StationState.new(player),
		save = SaveSystem.Load(player),
	}, Session)
end

function Session:Check()
	if not self.alive then
		error(ENDED, 0)
	end
	if self.abort then
		error(ABORT, 0)
	end
	if self.failed then
		error(FAILED, 0)
	end
end

-- Pause-aware wait: only unpaused time counts. Optional early-out predicate.
function Session:Wait(seconds: number, until_: (() -> boolean)?)
	local elapsed = 0
	self:Check()
	while elapsed < seconds do
		local dt = task.wait(0.05)
		self:Check()
		if until_ and until_() then
			return
		end
		if not self.paused then
			elapsed += dt * timeScale()
		end
	end
end

function Session:WaitUntil(pred: () -> boolean)
	while true do
		self:Check()
		if pred() then
			return
		end
		task.wait(0.05)
	end
end

-- Companion dialogue / tutorial hint. Blocking holds the director for the lines' total hold.
-- id may be a list: the beats' lines play back to back (story-flag variants append lines).
function Session:Beat(id: any, blocking: boolean?)
	local ids = if type(id) == "table" then id else { id }
	local lines = {}
	local total = 0
	local hint = nil
	for _, bid in ids do
		local beat = type(bid) == "string" and Beats[bid]
		if beat then
			hint = hint or beat.hint
			for _, l in beat.lines or {} do
				table.insert(lines, { speaker = l.speaker, text = string.format(l.text, self.save.settings.operatorName), hold = l.hold })
				total += l.hold
			end
		end
	end
	if #lines == 0 and not hint then
		return
	end
	ScareDirector.Fire(self, "Dialogue", { id = ids[1], lines = lines, hint = hint })
	if blocking and total > 0 then
		self:Wait(total)
	end
end

-- Camera cinematic, rendered by the client; the server holds for its duration.
function Session:Cinematic(id: string, minDuration: number?): boolean
	local c = Cinematics[id]
	if not c then
		if minDuration then
			self:Wait(minDuration)
		end
		return false
	end
	self.skipIntro = false
	local started = os.clock()
	ScareDirector.Fire(self, "Cinematic", { id = id, duration = c.duration, skippable = c.skippable == true })
	self:Wait(math.max(c.duration, minDuration or 0), function()
		-- 3s grace: the keypress that pressed Start must never skip the opening
		if os.clock() - started < 3 then
			self.skipIntro = false
			return false
		end
		return c.skippable == true and self.skipIntro
	end)
	ScareDirector.Fire(self, "CinematicEnd", { id = id, skipped = self.skipIntro })
	self.skipIntro = false
	return true
end

function Session:Humanoid(): Humanoid?
	local char = self.player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

function Session:ApplyMovement()
	local hum = self:Humanoid()
	if not hum then
		return
	end
	local free = Enum_.FreeMovement[self.state] and not self.paused
	hum.WalkSpeed = if free then WALK_SPEED else 0
	hum.UseJumpPower = false
	hum.JumpHeight = if free then JUMP_HEIGHT else 0
end

function Session:TeleportToQuarters()
	local char = self.player.Character
	local zone = CollectionService:GetTagged("Zone_Quarters")[1]
	local point = zone and (zone:IsA("Model") and zone.PrimaryPart or zone)
	-- Every wake/respawn routes through here: always release the pod pose first.
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = false
		root.AssemblyLinearVelocity = Vector3.zero
	end
	local hum = self:Humanoid()
	if hum then
		hum.PlatformStand = false
	end
	if char and point and point:IsA("BasePart") then
		char:PivotTo(point.CFrame * CFrame.new(0, 3, 0))
	end
end

-- Sleep: lay the character on its back along the pod bed, anchored (controls already locked by state).
function Session:LieInPod()
	local char = self.player.Character
	local pod = CollectionService:GetTagged("SleepPod")[1]
	local bed = pod and pod:FindFirstChild("Bed", true)
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (bed and bed:IsA("BasePart") and root and root:IsA("BasePart")) then
		return
	end
	local hum = self:Humanoid()
	if hum then
		hum.PlatformStand = true
	end
	-- head toward the pillow (bed's -X end), face up; root sits ~1 stud above the mattress
	local top = bed.CFrame * CFrame.new(0, bed.Size.Y / 2 + 1, 0)
	local along = -bed.CFrame.RightVector -- pillow sits at the bed's -X end
	root.Anchored = true
	char:PivotTo(CFrame.fromMatrix(top.Position, bed.CFrame.UpVector:Cross(along), along))
end

-- Story choices (save.flags): persist with the run, wiped by a new run / restart.
function Session:SetFlag(name: string)
	self.save.flags = self.save.flags or {}
	if not self.save.flags[name] then
		self.save.flags[name] = true
		SaveSystem.Mark(self.player)
	end
end

function Session:Flag(name: string): boolean
	return (self.save.flags or {})[name] == true
end

-- An either/or group (def.group) is settled once any member is completed.
function Session:GroupDone(group: string): boolean
	for _, id in self.objectiveList do
		if Objectives[id].group == group and self.completed[id] then
			return true
		end
	end
	return false
end

function Session:ObjectivePayload()
	local list = {}
	for _, id in self.objectiveList do
		local def = Objectives[id]
		if def.group and not self.completed[id] and self:GroupDone(def.group) then
			continue -- the road not taken drops off the list
		end
		table.insert(list, {
			optional = def.optional == true,
			id = id,
			text = def.text,
			done = self.completed[id] == true,
			active = self.active[id] == true,
		})
	end
	return list
end

-- The only place a player's state changes.
function Session:SetState(state: string, payload: { [string]: any }?)
	self:Check()
	self.state = state
	self.payload = payload or {}
	self.payload.dream = self.payload.dream or self.dream
	self.payload.operatorName = self.save.settings.operatorName
	local dayDef = DreamEvents.Days[self.day]
	if dayDef then
		local missionDay = DreamEvents.MissionDayStart + self.day - 1
		self.player:SetAttribute("MissionDay", missionDay)
		self.payload.missionDay = missionDay
		self.payload.day = self.day
		self.payload.dayTime = dayDef.time
		self.payload.dayTitle = dayDef.title
		self.payload.dayLog = dayDef.log
	end
	if state == S.Reality or state == S.Objectives then
		self.payload.objectives = self:ObjectivePayload()
	end
	self.save.currentState = state
	SaveSystem.Mark(self.player)
	self:ApplyMovement()
	Remotes.StateChanged:FireClient(self.player, state, self.payload)
end

-- Re-sends the current state (objective list changed, or resuming from pause).
function Session:Refresh(extra: { [string]: any }?)
	if self.state == S.Reality or self.state == S.Objectives then
		self.payload.objectives = self:ObjectivePayload()
	end
	local p = table.clone(self.payload)
	if extra then
		for k, v in extra do
			p[k] = v
		end
	end
	Remotes.StateChanged:FireClient(self.player, self.state, p)
end

-- Applies (and saves) one persistent world consequence.
function Session:SetWorld(flag: string)
	self.save.world = self.save.world or {}
	if not self.save.world[flag] then
		self.save.world[flag] = true
		SaveSystem.Mark(self.player)
	end
	if WORLD[flag] and not self.appliedWorld[flag] then
		self.appliedWorld[flag] = true
		WORLD[flag]()
	end
end

function Session:ResetWorld(keep: boolean)
	clearWorld()
	self.appliedWorld = {}
	if keep then
		for flag in self.save.world or {} do
			self:SetWorld(flag)
		end
	end
end

function Session:Checkpoint(kind: string?, dream: number, day: number?)
	self.save.day = day or self.day
	local completed = {}
	for id in self.completed do
		table.insert(completed, id)
	end
	self.save.checkpoint = kind
	self.save.currentDream = dream
	self.save.completed = completed
	self.save.resourceSnapshot = self.station:Snapshot()
	if self.save.settings.autosave ~= false then
		SaveSystem.Mark(self.player)
	end
end

----------------------------------------------------------------------------
-- Objectives
----------------------------------------------------------------------------
-- Choice consequences fired when an objective completes (flag + short cinematic, non-blocking).
local ON_COMPLETE: { [string]: { flag: string?, cinematic: string? } } = {
	R_Transmit4 = { flag = "Transmitted", cinematic = "ChoiceTransmit" },
	R_CommsBreaker = { flag = "Silent", cinematic = "ChoiceSilent" },
	O_Dish = { flag = "DishFixed", cinematic = "DishFixed" },
	D3_Knock = { flag = "Knocked" },
	D3_Pod = { flag = "Complied" },
}

local handlerCache: { [string]: any } = {}
local DEFAULT_HANDLER = {
	onTriggered = function()
		return true
	end,
}

local function getHandler(name: string)
	local cached = handlerCache[name]
	if cached then
		return cached
	end
	local mod = ServerScriptService.ObjectiveHandlers:FindFirstChild(name)
	local handler = DEFAULT_HANDLER
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and type(res) == "table" then
			handler = res
		else
			warn("[GameStateManager] handler failed to load:", name, res)
		end
	end
	handlerCache[name] = handler
	return handler
end

function Session:Complete(id: string): boolean
	if not self.active[id] or self.completed[id] then
		return false
	end
	local def = Objectives[id]
	local cost = def.repairCost or 0
	if cost > 0 then
		if self.station:Get("RepairUnits") < cost then
			ScareDirector.Fire(self, "NoRepairUnits")
			return false
		end
		self.station:Add("RepairUnits", -cost)
		self.station:Push(true)
	end
	self.active[id] = nil
	self.completed[id] = true
	self.minigames[id] = nil
	if def.group then
		for other in table.clone(self.active) do
			if Objectives[other].group == def.group then
				self.active[other] = nil
			end
		end
	end
	local hook = ON_COMPLETE[id]
	if hook then
		if hook.flag then
			self:SetFlag(hook.flag)
		end
		if hook.cinematic then
			local cin = hook.cinematic
			task.spawn(function()
				pcall(self.Cinematic, self, cin) -- unwinds quietly on quit/leave
			end)
		end
	end
	if def.beatOnComplete then
		self:Beat(def.beatOnComplete)
	end
	if self.state == S.Reality then
		-- keep the current checkpoint kind (Day 1 = nil, never resumable); per-task progress survives a rejoin
		self:Checkpoint(self.save.checkpoint, self.save.currentDream)
	end
	self:Refresh()
	return true
end

function Session:Activate(ids: { string })
	for _, id in ids do
		if not self.completed[id] and not self.active[id] then
			self.active[id] = true
			if Objectives[id].beatOnActivate then
				self:Beat(Objectives[id].beatOnActivate)
			end
			local h = getHandler(Objectives[id].handler)
			if h.onActivated then
				local ok, err = pcall(h.onActivated, self, Objectives[id])
				if not ok then
					warn("[GameStateManager] onActivated", id, err)
				end
			end
		end
	end
end

-- Optional objectives never hold the day; an either/or group needs just one member.
local function allDone(self, ids: { string }): boolean
	local groups = {}
	for _, id in ids do
		local g = Objectives[id].group
		if g and self.completed[id] then
			groups[g] = true
		end
	end
	for _, id in ids do
		local def = Objectives[id]
		if not self.completed[id] and not def.optional and not (def.group and groups[def.group]) then
			return false
		end
	end
	return true
end

-- Parallel: every id active at once, any order.
function Session:RunObjectives(state: string, ids: { string }, payload: { [string]: any })
	self.objectiveList = ids
	self.active = {}
	self:Activate(ids)
	self:SetState(state, payload)
	self:WaitUntil(function()
		return allDone(self, ids)
	end)
end

-- Sequential: one id active at a time, list shows all.
function Session:RunSequence(state: string, ids: { string }, payload: { [string]: any }, after: ((string) -> ())?)
	self.objectiveList = ids
	self.active = {}
	self:SetState(state, payload)
	for _, id in ids do
		if not self.completed[id] then
			self:Activate({ id })
			self:Refresh()
			self:WaitUntil(function()
				return self.completed[id] == true
			end)
			if after then
				after(id)
			end
		end
	end
end

----------------------------------------------------------------------------
-- Story phases
----------------------------------------------------------------------------
local function phaseIntro(self)
	self.skipIntro = false
	self:TeleportToQuarters()
	self:SetState(S.Intro, { cinematic = "Opening" })
	if not self:Cinematic("Opening") then
		-- fallback: text intro if no cinematic is registered
		local lines = {}
		for _, l in DreamEvents.Intro do
			table.insert(lines, (string.format(l, self.save.settings.operatorName)))
		end
		self:Refresh({ lines = lines, lineSeconds = 3 })
		self:Wait(#lines * 3 + 1.5, function()
			return self.skipIntro
		end)
	end
end

local function phaseReality(self, resumed: boolean)
	self.dream = 0
	self.canFail = false
	self.oxygenDrain = 0.02
	if resumed then
		self:TeleportToQuarters()
		self.station:Set("Oxygen", 100) -- retry after suffocating starts with a full tank
	end
	self:Checkpoint("Day", 0, 1) -- Day 1 is resumable; per-task progress rides on completed
	StoryProps.OnDay(self, 1)
	if resumed then
		self:Beat("Day1_Intro") -- fresh runs get this from the Opening cinematic
	end
	local tutorial = DreamEvents.Reality.tutorial or {}
	if not self.completed.R_Generator then
		self.station:ApplyPreset({ Power = 0 }) -- standby-cycle blackout; generator restores it
	end
	if not allDone(self, tutorial) then
		self:Beat("Reality_Wake")
		self:RunSequence(S.Reality, tutorial, { title = "Wake up", tutorial = true }, function(id)
			if id == "R_Generator" then
				-- power-on moment: short cinematic of the station coming back
				self:SetState(S.EventTrigger, { beat = "PowerOn", cinematic = "PowerOn" })
				self:Cinematic("PowerOn", 3)
			end
		end)
	end
	-- from here oxygen drains for real; refill stations (tag O2Refill) top it up, 0 = GameOver
	self.oxygenDrain = DreamEvents.Reality.oxygenDrain or 0.02
	self.canFail = true
	if not allDone(self, DreamEvents.Reality.tasks) then
		self:Beat("Reality_Tasks")
	end
	self.taskTimer = DreamEvents.Reality.taskTimeLimit
	self.player:SetAttribute("AuroraHealth", 100)
	self:RunObjectives(S.Reality, DreamEvents.Reality.tasks, { title = "Morning checklist", timer = self.taskTimer })
	self.taskTimer = nil
	self.player:SetAttribute("AuroraTaskTimer", nil)
	self:Beat("Reality_Distress")
	self:RunSequence(S.Reality, DreamEvents.Reality.distress, { title = "Contact the crew" }, function(id)
		if id == "R_CheckReply1" or id == "R_CheckReply2" then
			ScareDirector.Play(self, "Static", { attempt = if id == "R_CheckReply1" then 1 else 2 })
		end
	end)
end

-- Days 2..4: wake in quarters, AURA intro, that day's tasks in any order.
local function phaseDayTasks(self, n: number)
	local def = DreamEvents.Days[n]
	self.dream = 0
	self.canFail = false
	self:TeleportToQuarters()
	-- Night damage carries over (brief §2): Power/Hull stay where the night left them.
	-- Only the personal tank is topped to a survivable floor; O2 stations do the rest.
	self.station:Set("Oxygen", math.max(self.station:Get("Oxygen"), 60))
	-- reserve cells take the grid back to a working floor by morning: never a dark daytime station
	self.station:Set("Power", math.max(self.station:Get("Power"), 70))
	self.station:Push(true)
	self.player:SetAttribute("AuroraHealth", 100)
	StoryProps.OnDay(self, n)
	if n == 2 and not self.completed.R_Telescope then
		self:SetState(S.EventTrigger, { beat = "Contact", cinematic = "Day2Contact" })
		self:Cinematic("Day2Contact")
	end
	-- last day: AURA remembers what you did last night / what you fixed
	if n == #DreamEvents.Days then
		self:Beat({
			def.intro,
			if self:Flag("Knocked") then "Day4_Knocked" elseif self:Flag("Complied") then "Day4_Complied" else nil,
			if self:Flag("DishFixed") then "Day4_Dish" else nil,
		})
		-- new beat mid-shift: the galley intercom plays the crew (fires once two tasks are done)
		task.spawn(function()
			while self.alive and self.day == n and self.dream == 0 do
				local done = 0
				for _, id in def.tasks or {} do
					if self.completed[id] then
						done += 1
					end
				end
				if done >= 2 and self.state == S.Reality and not self.paused then
					self:Beat("Day214_Intercom")
					ScareDirector.Fire(self, "Mini", { kind = "LightChase" })
					return
				end
				task.wait(1)
			end
		end)
	else
		self:Beat(def.intro)
	end
	self.oxygenDrain = DreamEvents.Reality.oxygenDrain or 0.02
	self.canFail = true
	self:RunObjectives(S.Reality, def.tasks or {}, { title = def.title, dayStart = true })
end

-- Sleep prompt only works once the day's tasks are done (the pod says so otherwise).
local function phaseSleep(self, n: number)
	self.completed.R_Sleep = nil -- same objective every night
	self:Beat(if n == 1 then "Reality_Sleep" else "Day_Sleep")
	self:RunObjectives(S.Reality, DreamEvents.Reality.sleep, { title = "End of shift" })
	self.canFail = false
	self.active = {}
	self:LieInPod()
	self:SetState(S.EventTrigger, { beat = "Drift", text = if n == 1 then "No reply. You go back to work and wait." else "Lights down. The ship is still out there." })
	if n == 1 then
		self:Beat("Reality_NoReply", true)
	end
	-- Start the Sleep fade under the Drift's last shot so CinematicEnd lands on black
	-- (no flash of the pod between the cinematic and the dream).
	local drift = Cinematics.Drift
	if drift then
		task.delay(math.max(0, drift.duration - (ScareDirector.Durations.Sleep or 3)), function()
			if self.alive then
				ScareDirector.Fire(self, "Sleep")
			end
		end)
		self:Cinematic("Drift")
		self:Wait(0.5)
	else
		ScareDirector.Play(self, "Sleep")
	end
end

-- End of day N: summary, real autosave (checkpoint = start of day N+1), next day's title card.
local function phaseDayEnd(self, n: number)
	local nextDay = n + 1
	local nextDef = DreamEvents.Days[nextDay]
	local def = DreamEvents.Days[n]
	self:Checkpoint("Day", 0, nextDay)
	local tasks = if n == 1 then #DreamEvents.Reality.tasks + #DreamEvents.Reality.distress else #(def.tasks or {})
	self:SetState(S.EventTrigger, { beat = "DayEnd" })
	ScareDirector.Fire(self, "DayEnd", {
		day = n,
		nextDay = nextDay,
		nextTime = nextDef and nextDef.time or "06:40",
		nextTitle = nextDef and nextDef.title or "",
		missionDay = DreamEvents.MissionDayStart + n - 1,
		nextMissionDay = DreamEvents.MissionDayStart + nextDay - 1,
		summary = { string.format("%d tasks completed", tasks), "Shift log saved." },
	})
	task.spawn(function()
		task.wait(2.2)
		local ok = SaveSystem.Flush(self.player)
		if self.alive then
			ScareDirector.Fire(self, "DaySaved", { ok = ok })
		end
	end)
	self:Cinematic("DayEnd", 7.5)
	self.day = nextDay
end

local function phaseDream(self, d: number, lastOfNight: boolean)
	local ev = DreamEvents.Dreams[d]
	self.dream = d
	self.canFail = false
	self.station:ApplyPreset(ev.resourcePreset)
	self.oxygenDrain = ev.oxygenDrain
	self:Checkpoint("Dream", d)
	StoryProps.OnNight(self, d)

	-- Event Trigger: wake in the quarters
	self:SetState(S.EventTrigger, { beat = "Wake" })
	self:TeleportToQuarters()
	ScareDirector.Play(self, "Wake", { dream = d })
	self:Beat("Dream" .. d .. "_Wake")

	-- Dream Layer: the trigger cue, with its camera cinematic running alongside
	self:SetState(S.DreamLayer, { title = ev.triggerTitle, cinematic = "Dream" .. d })
	if Cinematics["Dream" .. d] then
		ScareDirector.Fire(self, ev.triggerCue, { dream = d })
		self:Cinematic("Dream" .. d, ScareDirector.Durations[ev.triggerCue])
	else
		ScareDirector.Play(self, ev.triggerCue, { dream = d })
	end

	-- Objectives
	self.canFail = ev.canFail
	self:Beat({
		"Dream" .. d .. "_Start",
		if d == 4 and self:Flag("Silent") then "Dream4_Silent" elseif d == 4 and self:Flag("Transmitted") then "Dream4_Answered" else nil,
	})
	self:RunObjectives(S.Objectives, ev.objectives, { title = ev.triggerTitle, location = ev.location })
	self:Beat("Dream" .. d .. "_Clean")
	if ev.followUp then
		self:RunObjectives(S.Objectives, ev.followUp, { title = ev.triggerTitle, result = ev.resultIfClean })
	end
	self.canFail = false
	for _, flag in NIGHT_FLAGS[d] or {} do
		self:SetWorld(flag)
	end

	-- Mark the anomaly done BEFORE its scare, so a rejoin never replays the scare (TC14).
	if d >= #DreamEvents.Dreams then
		self:Checkpoint("Choice", d)
	elseif lastOfNight then
		self:Checkpoint("Day", 0, self.day + 1)
	else
		self:Checkpoint("Dream", d + 1)
	end
	self:SetState(S.EventTrigger, { beat = "Scare", result = ev.resultIfClean })
	if ev.scare then
		ScareDirector.Play(self, ev.scare, { dream = d })
	end
end

local function phaseChoice(self)
	self.dream = 5
	self:Checkpoint("Choice", 4)
	self.choice = nil
	if Cinematics.Choice then
		self:SetState(S.EventTrigger, { beat = "Choice", cinematic = "Choice" })
		self:Cinematic("Choice")
	end
	self:SetState(S.Choice, {})
	self:Beat("Choice")
	self:WaitUntil(function()
		return self.choice ~= nil
	end)
end

-- 4 endings: Choice (Dream / Reality) x contact made (dish fixed or answered the ship).
-- Night choice and the six crew logs add a line each.
local function phaseEnding(self)
	local contact = self:Flag("DishFixed") or self:Flag("Transmitted")
	local key = (self.choice :: string) .. (if contact then "" else "_Silent")
	local ending = DreamEvents.Endings[key]
	local lines = table.clone(ending.lines)
	local extra = DreamEvents.EndingExtras
	if self:Flag("Knocked") then
		table.insert(lines, #lines, extra.Knocked)
	elseif self:Flag("Complied") then
		table.insert(lines, #lines, extra.Complied)
	end
	if self:Flag("AllLogs") then
		table.insert(lines, extra.AllLogs)
	end
	-- pin the character for the whole ending: no falls, no deaths, no auto-respawn mid-cutscene
	local char = self.player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = self:Humanoid()
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end
	if hum then
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
		hum.Health = hum.MaxHealth
	end
	self:SetState(S.Ending, { ending = ending.id, variant = key, title = ending.title, cinematic = "Ending_" .. key })
	ScareDirector.Fire(self, "Ending", { ending = ending.id, variant = key })
	self:Cinematic("Ending_" .. key)
	self:Refresh({ lines = lines, lineSeconds = 4 })
	self.payload.lines = lines
	self.payload.lineSeconds = 4
	self:Wait(#lines * 4 + 5)
end

local function phaseRestart(self)
	-- Run is over: wipe progress, keep settings, refill Repair Units.
	self.save = SaveSystem.Replace(self.player, SaveSystem.Blank(self.save.settings))
	self.completed = {}
	self.active = {}
	self.station:Reset()
	local hum = self:Humanoid()
	if hum then
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
	end
	self:ResetWorld(false)
	self:SetState(S.Restart, {})
	self:Wait(2)
end

local function phaseGameOver(self)
	self.active = {}
	self.menuChoice = nil
	self.taskTimer = nil
	self.player:SetAttribute("AuroraTaskTimer", nil)
	if self.failReason == "Meltdown" then
		self:SetState(S.EventTrigger, { beat = "Meltdown", cinematic = "Meltdown" })
		self:Cinematic("Meltdown", 10)
		self.failReason = "Reactor meltdown. The station is gone."
	end
	-- Death: count it (persisted), short respawn beat, then straight back into this day's
	-- checkpoint (phaseMenuAndRun sees autoResume and skips the menu).
	local deaths = (self.save.deaths or 0) + 1
	self.save.deaths = deaths
	self.player:SetAttribute("AuroraDeaths", deaths)
	SaveSystem.Mark(self.player)
	self:SetState(S.EventTrigger, { beat = "Respawn", reason = self.failReason or "Crew safety lost", deaths = deaths, cinematic = "Respawn" })
	local hum = self:Humanoid()
	if not hum or hum.Health <= 0 then
		self.player:LoadCharacter()
	end
	self:Cinematic("Respawn", 4)
	self.autoResume = true
end

local function phaseMenuAndRun(self)
	self.active = {}
	self.objectiveList = {}
	self.dream = 0
	self.menuChoice = nil
	self.player:SetAttribute("AuroraDeaths", self.save.deaths or 0)
	local autoResume = self.autoResume == true
	self.autoResume = nil
	if autoResume then
		self.menuChoice = "Continue" -- respawn after death: no menu trip
	else
		self:SetState(S.MainMenu, { hasSave = self.save.checkpoint ~= nil, settings = self.save.settings })
		self:WaitUntil(function()
			return self.menuChoice == "Start" or (self.menuChoice == "Continue" and self.save.checkpoint ~= nil)
		end)
	end

	local startDay = 1
	local entry = "Intro" -- Intro | Day (resume at start of startDay) | Dream (resume that night) | Choice
	if self.menuChoice == "Continue" then
		local cp = self.save.checkpoint
		self.completed = {}
		for _, id in self.save.completed do
			self.completed[id] = true
		end
		self.station:Load(self.save.resourceSnapshot)
		if cp == "Reality" then
			entry = "Day" -- legacy save
		elseif cp == "Day" then
			entry = "Day"
			startDay = math.clamp(self.save.day or 1, 1, #DreamEvents.Days)
		elseif cp == "Dream" then
			entry = "Dream"
			startDay = dreamDay[math.clamp(self.save.currentDream, 1, #DreamEvents.Dreams)] or 1
		elseif cp == nil then
			-- only reachable via autoResume (Day 1 death: never checkpointed; progress kept in completed)
			entry = "Day"
			startDay = math.clamp(self.save.day or 1, 1, #DreamEvents.Days)
		else
			entry = "Choice"
		end
	else
		self.save = SaveSystem.Replace(self.player, SaveSystem.Blank(self.save.settings))
		self.completed = {}
		self.station:Reset()
	end
	-- Studio-only chapter jump for testing: Workspace attribute AuroraStartAt = Day1..Day3 | Dream2..Dream4 | Choice
	local jump = game:GetService("RunService"):IsStudio() and workspace:GetAttribute("AuroraStartAt")
	if type(jump) == "string" and self.menuChoice == "Start" then
		local kind, n = jump:match("^(%a+)(%d*)$")
		n = tonumber(n)
		if kind == "Day" and n then
			entry, startDay = "Day", math.clamp(n, 1, #DreamEvents.Days)
		elseif kind == "Dream" and n and dreamDay[n] then
			entry, startDay = "Dream", dreamDay[n]
			self.save.currentDream = n
		elseif kind == "Choice" then
			entry = "Choice"
		end
	end
	self:ResetWorld(self.menuChoice == "Continue")
	self.menuChoice = nil
	self.day = startDay

	if entry == "Intro" then
		phaseIntro(self)
	end
	if entry ~= "Choice" then
		for n = startDay, #DreamEvents.Days do
			self.day = n
			if not (entry == "Dream" and n == startDay) then
				if n == 1 then
					phaseReality(self, entry ~= "Intro")
				else
					phaseDayTasks(self, n)
				end
				phaseSleep(self, n)
			end
			local dreams = DreamEvents.Days[n].dreams
			for i, d in dreams do
				-- resuming mid-night: skip anomalies already finished
				if not (entry == "Dream" and n == startDay and d < self.save.currentDream) then
					phaseDream(self, d, i == #dreams)
				end
			end
			if n < #DreamEvents.Days then
				phaseDayEnd(self, n)
			end
		end
	end
	phaseChoice(self)
	phaseEnding(self)
	phaseRestart(self)
end

local function traceback(err: any)
	if type(err) == "table" then
		return err
	end
	return debug.traceback(tostring(err), 2)
end

local function director(self)
	local nextPhase = phaseMenuAndRun
	while self.alive do
		local ok, err = xpcall(nextPhase, traceback, self)
		local wasFailed = err == FAILED
		self.failed = false
		self.abort = false
		self.paused = false
		self.canFail = false
		if ok then
			nextPhase = phaseMenuAndRun
		elseif err == ENDED then
			return
		elseif wasFailed then
			nextPhase = phaseGameOver
		elseif err == ABORT then
			nextPhase = phaseMenuAndRun
		else
			warn("[GameStateManager] director error, returning to menu:\n" .. tostring(err))
			nextPhase = phaseMenuAndRun
			task.wait(1)
		end
	end
end

----------------------------------------------------------------------------
-- Prompts (one per objective, on the tagged station geometry)
----------------------------------------------------------------------------
local partCache: { [string]: BasePart } = {}
local function findPromptPart(def): BasePart?
	local cached = partCache[def.id]
	if cached and cached.Parent then
		return cached
	end
	if not def.tag then
		return nil
	end
	for _, inst in CollectionService:GetTagged(def.tag) do
		local found: BasePart? = nil
		if def.part then
			local p = inst:FindFirstChild(def.part, true)
			if p and p:IsA("BasePart") then
				found = p
			end
		end
		if not found then
			if inst:IsA("BasePart") then
				found = inst
			elseif inst:IsA("Model") and inst.PrimaryPart then
				found = inst.PrimaryPart
			end
		end
		if found then
			partCache[def.id] = found
			return found
		end
	end
	return nil
end

local function onPromptTriggered(prompt: ProximityPrompt, player: Player)
	local id = prompt:GetAttribute("ObjectiveId")
	local self = sessions[player]
	if type(id) ~= "string" or not self or self.paused or not self.active[id] then
		return
	end
	if self.state ~= S.Reality and self.state ~= S.Objectives then
		return
	end
	local def = Objectives[id]
	if def.minigame then
		self.minigames[id] = os.clock()
		local h = getHandler(def.handler)
		if h.onMinigameOpen then
			local ok, err = pcall(h.onMinigameOpen, self, def)
			if not ok then
				warn("[GameStateManager] onMinigameOpen", id, err)
			end
		end
		ScareDirector.Fire(self, "Minigame", { objectiveId = id, kind = def.minigame, params = def.minigameParams or {} })
		return
	end
	local ok, done = pcall(getHandler(def.handler).onTriggered, self, def, prompt)
	if not ok then
		warn("[GameStateManager] onTriggered", id, done)
	elseif done then
		self:Complete(id)
	end
end

-- Oxygen refill stations: any model/part tagged O2Refill. Reality only (Dream 4's crisis must not be skippable).
local function buildRefills()
	for _, inst in CollectionService:GetTagged("O2Refill") do
		local part = if inst:IsA("BasePart") then inst else (inst:IsA("Model") and (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)))
		if not part then
			continue
		end
		local p = Instance.new("ProximityPrompt")
		p.Name = "AuroraRefill"
		p.ActionText = "Refill oxygen"
		p.ObjectText = "O2 station"
		p.HoldDuration = 0.5
		p.MaxActivationDistance = PROMPT_DISTANCE
		p.RequiresLineOfSight = false
		p.Triggered:Connect(function(player)
			local self = sessions[player]
			if not self or self.paused or self.dream ~= 0 or (self.state ~= S.Reality and self.state ~= S.Objectives) then
				return
			end
			self.station:Set("Oxygen", 100)
			self.station:Push(true)
			ScareDirector.Fire(self, "Toast", { text = "Oxygen tank refilled." })
			ScareDirector.Fire(self, "O2Refilled", {})
			ScareDirector.Fire(self, "Cinematic", { id = "Refill", duration = 2.5, skippable = false })
			-- client-only cinematic: send the end cue so the HUD comes back
			task.delay(2.6, function()
				if self.alive then
					ScareDirector.Fire(self, "CinematicEnd", { id = "Refill" })
				end
			end)
		end)
		p.Parent = part
	end
end

-- Sleep pod (tag SleepPod, part Bed): one always-visible prompt; early use explains why not yet.
local function buildPod()
	local pod = CollectionService:GetTagged("SleepPod")[1]
	local bed = pod and pod:FindFirstChild("Bed", true)
	if not (bed and bed:IsA("BasePart")) then
		warn("[GameStateManager] no SleepPod/Bed; R_Sleep cannot complete")
		return
	end
	local old = bed:FindFirstChild("AuroraSleep")
	if old then
		old:Destroy()
	end
	local p = Instance.new("ProximityPrompt")
	p.Name = "AuroraSleep"
	p.ActionText = "Sleep"
	p.ObjectText = "Sleep pod"
	p.HoldDuration = Objectives.R_Sleep.hold
	p.MaxActivationDistance = PROMPT_DISTANCE
	p.RequiresLineOfSight = false
	p.KeyboardKeyCode = Enum.KeyCode.E
	p.Triggered:Connect(function(player)
		local self = sessions[player]
		if not self or self.paused or self.dream ~= 0 or self.state ~= S.Reality then
			return
		end
		if self.active.R_Sleep then
			self:Complete("R_Sleep")
		else
			ScareDirector.Fire(self, "Toast", { text = "Finish today's tasks first." })
		end
	end)
	p.Parent = bed
end

local function buildPrompts()
	buildRefills()
	buildPod()
	for id, def in Objectives do
		if def.clientAction or def.reach or def.pod or def.external then
			continue -- no prompt: completed by client report / proximity
		end
		local part = findPromptPart(def)
		if not part then
			warn("[GameStateManager] no geometry for objective", id, "tag", def.tag)
			continue
		end
		local name = "AuroraPrompt_" .. id
		local old = part:FindFirstChild(name)
		if old then
			old:Destroy()
		end
		local p = Instance.new("ProximityPrompt")
		p.Name = name
		p.ActionText = def.action
		p.ObjectText = ""
		p.HoldDuration = def.hold
		p.MaxActivationDistance = PROMPT_DISTANCE
		p.RequiresLineOfSight = false
		p.KeyboardKeyCode = Enum.KeyCode.E
		p.Style = Enum.ProximityPromptStyle.Default
		-- Enabled server-side; each client hides every prompt that isn't active for it.
		p.Enabled = true
		p:SetAttribute("ObjectiveId", id)
		CollectionService:AddTag(p, "AuroraPrompt")
		p.Triggered:Connect(function(player)
			onPromptTriggered(p, player)
		end)
		p.Parent = part
	end
end

----------------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------------
local function gate(self, key: string): boolean
	local now = os.clock()
	if now - (self.lastRemote[key] or 0) < REMOTE_GAP then
		return false
	end
	self.lastRemote[key] = now
	return true
end

local function onAction(player: Player, action: any, data: any)
	local self = sessions[player]
	if not self or type(action) ~= "string" or not gate(self, "action") then
		return
	end
	if action == "Start" or action == "Continue" then
		if self.state == S.MainMenu then
			self.menuChoice = action
		end
	elseif action == "SkipIntro" or action == "SkipCinematic" then
		self.skipIntro = true -- only honoured by skippable cinematics / the text intro
	elseif action == "Pause" then
		if Enum_.Pausable[self.state] and not self.paused then
			self.paused = true
			self:ApplyMovement()
			Remotes.StateChanged:FireClient(player, S.Pause, { resume = self.state, dream = self.dream })
		end
	elseif action == "Resume" then
		if self.paused then
			self.paused = false
			self:ApplyMovement()
			self:Refresh({ resumed = true })
		end
	elseif action == "QuitToMenu" then
		if self.paused then
			self.abort = true -- director unwinds on its next wait; checkpoint already saved
		end
	elseif action == "Restart" then
		if self.state == S.GameOver then
			self.menuChoice = "Restart"
		end
	elseif action == "SaveSettings" then
		if type(data) == "table" then
			local s = self.save.settings
			if type(data.operatorName) == "string" then
				local name = string.gsub(string.sub(data.operatorName, 1, 24), "[^%w%s%-%.']", "")
				name = string.match(name, "^%s*(.-)%s*$") or ""
				if #name > 0 then
					s.operatorName = name
				end
			end
			if type(data.volume) == "number" and data.volume == data.volume then
				s.volume = math.clamp(data.volume, 0, 1)
			end
			for key, v in data do
				local clean = SaveSystem.CleanSetting(key, v)
				if clean ~= nil then
					s[key] = clean
				end
			end
			SaveSystem.Mark(player)
			if self.state == S.MainMenu then
				self:Refresh({ settings = s })
			end
		end
	end
end

local function onChoice(player: Player, choice: any)
	local self = sessions[player]
	if not self or not gate(self, "choice") then
		return
	end
	if self.state == S.Choice and self.choice == nil and (choice == "Dream" or choice == "Reality") then
		self.choice = choice
	end
end

local function onObjectiveComplete(player: Player, id: any, data: any)
	local self = sessions[player]
	if not self or type(id) ~= "string" or not gate(self, "objective") then
		return
	end
	local def = Objectives[id]
	if not def or self.paused or not self.active[id] then
		return
	end
	local h = getHandler(def.handler)
	if def.clientAction then
		self:Complete(id)
		return
	end
	if def.minigame then
		local opened = self.minigames[id]
		if not opened or type(data) ~= "table" or os.clock() - opened < (def.minTime or 0.5) then
			return
		end
		if data.success ~= true then
			self.minigames[id] = nil -- failed attempt: prompt must be used again
			ScareDirector.Fire(self, "Toast", { text = "Try again." })
			return
		end
		local fn = h.onClientComplete or h.onTriggered
		local ok, done = pcall(fn, self, def, data)
		if not ok then
			warn("[GameStateManager] minigame complete", id, done)
		elseif done then
			self:Complete(id)
		end
		return
	end
	if not h.onClientComplete then
		return -- this objective can only be completed by its prompt
	end
	local ok, done = pcall(h.onClientComplete, self, def, data)
	if not ok then
		warn("[GameStateManager] onClientComplete", id, done)
	elseif done then
		self:Complete(id)
	end
end

----------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------
local function onPlayerAdded(player: Player)
	if sessions[player] or starting[player] then
		return
	end
	starting[player] = true
	local self = Session.new(player) -- yields on the DataStore read
	starting[player] = nil
	if not player.Parent then
		self.station:Destroy()
		SaveSystem.Forget(player)
		return
	end
	sessions[player] = self
	local function onCharacter(char: Model)
		task.defer(function()
			self:ApplyMovement()
		end)
		-- Any real humanoid death mid-run counts as a failure -> respawn beat + checkpoint.
		local hum = char:WaitForChild("Humanoid", 10)
		if hum and hum:IsA("Humanoid") then
			hum.Died:Connect(function()
				if self.alive and not self.failed and (self.state == S.Reality or self.state == S.Objectives) then
					self.failReason = "You died"
					self.failed = true
				end
			end)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	task.spawn(director, self)
end

local function onPlayerRemoving(player: Player)
	local self = sessions[player]
	if not self then
		return
	end
	sessions[player] = nil
	self.alive = false
	SaveSystem.Flush(player)
	SaveSystem.Forget(player)
end

local function tick(dt: number)
	for _, self in sessions do
		if self.alive and not self.paused and Enum_.Ticking[self.state] then
			self.station:Tick(dt, self.oxygenDrain)
			if self.state == S.Reality or self.state == S.Objectives then
				local char = self.player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					for id in self.active do
						local def = Objectives[id]
						local part = def.reach and findPromptPart(def)
						local dist = part and (part.Position - root.Position).Magnitude
						-- leaveFirst: standing there when it activates doesn't count; walk away, then come back
						if dist and def.leaveFirst and not self.flags["left_" .. id] then
							if dist > def.reach * 2 then
								self.flags["left_" .. id] = true
							end
							dist = nil
						end
						if dist and dist <= def.reach then
							task.defer(function()
								self:Complete(id)
							end)
						end
					end
				end
			end
			local o2 = self.station:Get("Oxygen")
			if self.dream == 0 and self.canFail then
				if o2 < 25 and not self.flags.o2Warned then
					self.flags.o2Warned = true
					self:Beat("O2_Low")
				elseif o2 > 50 then
					self.flags.o2Warned = nil
				end
			end
			-- Day 1 task deadline (pause-aware): runs only while the timer is armed
			if self.taskTimer and self.state == S.Reality then
				self.taskTimer -= dt
				self.player:SetAttribute("AuroraTaskTimer", math.max(0, self.taskTimer))
				if self.taskTimer <= 0 and not self.failed then
					self.taskTimer = nil
					self.failReason = "Meltdown"
					self.failed = true
				end
			end
			-- health: suffocation drains it at 0 O2, a live tank slowly restores it
			if self.dream == 0 and self.canFail then
				local hp = self.player:GetAttribute("AuroraHealth") or 100
				hp = if o2 <= 0 then hp - 8 * dt else math.min(100, hp + 2 * dt)
				self.player:SetAttribute("AuroraHealth", math.max(0, hp))
				if hp <= 0 and not self.failed then
					self.failReason = "You suffocated"
					self.failed = true
				end
			end
			if self.canFail and self.state == S.Objectives and not self.failed and self.station:IsCritical() then
				self.failReason = if self.station:Get("Oxygen") <= 0 then "Oxygen depleted" else "Crew safety critical"
				self.failed = true
			end
		end
	end
end

function GameStateManager.Init()
	-- owner feedback: nothing should trap the player at spawn; doors always operate
	workspace:SetAttribute("AuroraPower", true)
	buildPrompts()
	Remotes.RequestAction.OnServerEvent:Connect(onAction)
	Remotes.RequestChoice.OnServerEvent:Connect(onChoice)
	Remotes.RequestObjectiveComplete.OnServerEvent:Connect(onObjectiveComplete)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayerAdded, p)
	end
	RunService.Heartbeat:Connect(tick)
	StoryProps.Init(function(p: Player)
		return sessions[p]
	end)
	if RunService:IsStudio() then
		-- QA hook (Studio only): ServerStorage.AuroraQA:Invoke(cmd, ...) drives the first
		-- player's session without replaying the story (PRD §4: tasks triggerable directly).
		local qa = Instance.new("BindableFunction")
		qa.Name = "AuroraQA"
		qa.OnInvoke = function(cmd: string, a: any, b: any)
			local player = Players:GetPlayers()[1]
			local self = player and sessions[player]
			if not self then
				return "no session"
			end
			if cmd == "action" then
				onAction(player, a, b)
				self.lastRemote.action = 0
			elseif cmd == "complete" then
				if a == "*" then
					for id in table.clone(self.active) do
						self:Complete(id)
					end
				else
					self:Complete(a)
				end
			elseif cmd == "trigger" then
				local def = Objectives[a]
				local part = def and findPromptPart(def)
				local prompt = part and part:FindFirstChild("AuroraPrompt_" .. a)
				if prompt then
					onPromptTriggered(prompt, player)
				end
			elseif cmd == "client" then
				onObjectiveComplete(player, a, b)
				self.lastRemote.objective = 0
			elseif cmd == "choice" then
				onChoice(player, a)
			elseif cmd == "set" then
				self.station:Set(a, b)
			elseif cmd == "log" then
				StoryProps.ReadLog(self, a)
			elseif cmd == "flags" then
				local f = {}
				for k in self.save.flags or {} do
					table.insert(f, k)
				end
				table.sort(f)
				return table.concat(f, ",")
			end
			local active = {}
			for id in self.active do
				table.insert(active, id)
			end
			table.sort(active)
			return string.format(
				"state=%s paused=%s dream=%d day=%d/save%d checkpoint=%s/%d active=[%s] O2=%.1f Pwr=%.0f RU=%d CS=%.0f cues=%s",
				self.state, tostring(self.paused), self.dream, self.day, self.save.day or 0, tostring(self.save.checkpoint), self.save.currentDream,
				table.concat(active, ","), self.station:Get("Oxygen"), self.station:Get("Power"),
				self.station:Get("RepairUnits"), self.station:Get("CrewSafety"),
				(function()
					local c = {}
					for k, v in self.firedCues do
						table.insert(c, k .. "x" .. v)
					end
					table.sort(c)
					return table.concat(c, ",")
				end)()
			)
		end
		qa.Parent = game:GetService("ServerStorage")
	end
	game:BindToClose(function()
		for _, p in Players:GetPlayers() do
			SaveSystem.Flush(p)
		end
	end)
end

-- Debug/QA hook: lets a QA build jump a session to any objective without replaying.
function GameStateManager.GetSession(player: Player)
	return sessions[player]
end

return GameStateManager
