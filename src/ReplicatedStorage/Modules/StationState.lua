--!strict
-- Station resource model (PRD §4). One instance per player, server-owned.
-- Six NumberValues live under player.StationState (so they also replicate natively);
-- every change is batched and pushed over Remotes.StationState_Changed at most 5x/s.
-- Clients only read `Names`, `Limits` and the remote payload.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = { "Power", "Oxygen", "HullIntegrity", "RepairUnits", "MissionTime", "CrewSafety" }

local Defaults = {
	Power = 100,
	Oxygen = 98,
	HullIntegrity = 100,
	RepairUnits = 12, -- 6 are needed for a clean run; refilled only at Restart
	MissionTime = 1500, -- seconds
}

local Limits = {
	Power = 100,
	Oxygen = 100,
	HullIntegrity = 100,
	RepairUnits = 12,
	MissionTime = 1500,
	CrewSafety = 100,
}

local CREW_SAFETY_FLOOR = 10
local PUSH_INTERVAL = 0.2

export type Snapshot = { [string]: number }

local StationState = {}
StationState.__index = StationState
StationState.Names = Names
StationState.Limits = Limits
StationState.CrewSafetyFloor = CREW_SAFETY_FLOOR

local function crewSafety(v: Snapshot): number
	-- Derived, never set directly. Oxygen dominates; mission clock only nags.
	local clock = math.min(100, v.MissionTime / 12)
	return math.clamp(0.4 * v.Oxygen + 0.25 * v.Power + 0.25 * v.HullIntegrity + 0.1 * clock, 0, 100)
end

function StationState.new(player: Player)
	assert(RunService:IsServer(), "StationState.new is server-only")
	local folder = player:FindFirstChild("StationState")
	if folder then
		folder:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "StationState"

	local self = setmetatable({
		player = player,
		folder = folder,
		values = {} :: { [string]: NumberValue },
		dirty = false,
		lastPush = 0,
		remote = (ReplicatedStorage :: any).Remotes.StationState_Changed :: RemoteEvent,
	}, StationState)

	for _, name in Names do
		local nv = Instance.new("NumberValue")
		nv.Name = name
		nv.Value = Defaults[name] or 0
		nv.Parent = folder
		self.values[name] = nv
	end
	folder.Parent = player
	self:_recompute()
	self:Push(true)
	return self
end

function StationState:Get(name: string): number
	return self.values[name].Value
end

function StationState:Set(name: string, value: number)
	assert(name ~= "CrewSafety", "CrewSafety is derived")
	local nv = self.values[name]
	assert(nv, "unknown resource " .. name)
	value = math.clamp(value, 0, Limits[name])
	if nv.Value ~= value then
		nv.Value = value
		self:_recompute()
		self.dirty = true
	end
end

function StationState:Add(name: string, delta: number)
	self:Set(name, self:Get(name) + delta)
end

function StationState:Snapshot(): Snapshot
	local s = {}
	for name, nv in self.values do
		s[name] = nv.Value
	end
	return s
end

-- Restores a saved snapshot; unknown or corrupt fields fall back to defaults.
function StationState:Load(snapshot: Snapshot?)
	for _, name in Names do
		if name ~= "CrewSafety" then
			local v = snapshot and snapshot[name]
			self:Set(name, if typeof(v) == "number" and v == v then v else Defaults[name])
		end
	end
	self:Push(true)
end

function StationState:Reset()
	self:Load(nil)
end

function StationState:ApplyPreset(preset: { [string]: number })
	for name, v in preset do
		self:Set(name, v)
	end
	self:Push(true)
end

-- Called by GameStateManager once per heartbeat while the state ticks and is not paused.
function StationState:Tick(dt: number, oxygenDrain: number)
	self:Add("Oxygen", -oxygenDrain * dt)
	self:Add("MissionTime", -dt)
	self:Push(false)
end

function StationState:IsCritical(): boolean
	return self:Get("Oxygen") <= 0 or self:Get("CrewSafety") < CREW_SAFETY_FLOOR
end

function StationState:Push(force: boolean)
	local now = os.clock()
	if not force and (not self.dirty or now - self.lastPush < PUSH_INTERVAL) then
		return
	end
	self.dirty = false
	self.lastPush = now
	if self.player.Parent then
		self.remote:FireClient(self.player, self:Snapshot())
	end
end

function StationState:_recompute()
	local v = {}
	for name, nv in self.values do
		v[name] = nv.Value
	end
	self.values.CrewSafety.Value = crewSafety(v)
end

function StationState:Destroy()
	self.folder:Destroy()
end

return StationState
