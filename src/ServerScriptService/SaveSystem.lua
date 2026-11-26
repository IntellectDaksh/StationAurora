--!strict
-- DataStore checkpoint, one key per UserId (PRD §6).
-- Writes are coalesced: Mark() on every state transition, a background loop flushes
-- at most once per WRITE_GAP seconds per player (DataStore allows ~1 write / 6s / key),
-- plus a forced flush on PlayerRemoving and BindToClose.
-- If DataStores are unavailable (Studio without API access) it degrades to memory-only
-- and warns once, so the game still runs; progress just won't survive a server restart.

local DataStoreService = game:GetService("DataStoreService")

local STORE_NAME = "StationAurora_v1"
local WRITE_GAP = 7
local RETRIES = 3

export type SaveData = {
	v: number,
	currentState: string?,
	currentDream: number,
	day: number, -- story day the checkpoint resumes on (1..4)
	checkpoint: string?, -- "Reality" | "Dream" | "Choice" | nil (no run in progress)
	completed: { string },
	resourceSnapshot: { [string]: number }?,
	deaths: number, -- run death counter (player attribute AuroraDeaths)
	world: { [string]: boolean }, -- night consequences that persist into later days (GameStateManager.WORLD)
	flags: { [string]: boolean }, -- story choices + finds (Transmitted, Silent, DishFixed, Knocked, Complied, Log1..6, AllLogs, DuckFound...)
	settings: { operatorName: string, volume: number, [string]: any }, -- + EXTRA_SETTINGS keys
}

local SaveSystem = {}

-- Optional player settings beyond name/volume: key -> {kind, a, b}. Anything else is dropped.
local EXTRA_SETTINGS: { [string]: { any } } = {
	music = { "num", 0, 1 },
	sfx = { "num", 0, 1 },
	fov = { "int", 60, 90 },
	sens = { "num", 0.2, 2 },
	subs = { "bool" },
	subtitles = { "bool" },
	shake = { "bool" },
	autosave = { "bool" },
	textSpeed = { "enum", { 0.6, 1, 1.6 } },
}

-- Validated value for one extra setting, or nil if the key/value is not acceptable.
function SaveSystem.CleanSetting(key: any, v: any): any
	local spec = type(key) == "string" and EXTRA_SETTINGS[key]
	if not spec then
		return nil
	end
	if spec[1] == "bool" then
		return if type(v) == "boolean" then v else nil
	end
	if type(v) ~= "number" or v ~= v then
		return nil
	end
	if spec[1] == "enum" then
		local best, bestD = nil, math.huge
		for _, o in spec[2] do
			if math.abs(o - v) < bestD then
				best, bestD = o, math.abs(o - v)
			end
		end
		return best
	end
	local c = math.clamp(v, spec[2], spec[3])
	return if spec[1] == "int" then math.floor(c + 0.5) else c
end

local store: DataStore? = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[SaveSystem] DataStore unavailable, memory-only saves:", result)
	end
end

local cache: { [number]: SaveData } = {}
local dirty: { [number]: boolean } = {}
local lastWrite: { [number]: number } = {}
local warnedWrite = false

function SaveSystem.Blank(settings: any?): SaveData
	return {
		v = 1,
		currentState = nil,
		currentDream = 0,
		day = 1,
		checkpoint = nil,
		completed = {},
		resourceSnapshot = nil,
		deaths = 0,
		world = {},
		flags = {},
		settings = settings or { operatorName = "Sam Ortega", volume = 1 },
	}
end

-- Guards against hand-edited or older-schema records.
local function sanitize(raw: any): SaveData
	local blank = SaveSystem.Blank()
	if type(raw) ~= "table" then
		return blank
	end
	local s = raw.settings
	if type(s) == "table" then
		if type(s.operatorName) == "string" and #s.operatorName > 0 then
			blank.settings.operatorName = string.sub(s.operatorName, 1, 24)
		end
		if type(s.volume) == "number" then
			blank.settings.volume = math.clamp(s.volume, 0, 1)
		end
		for key in EXTRA_SETTINGS do
			local v = SaveSystem.CleanSetting(key, s[key])
			if v ~= nil then
				(blank.settings :: any)[key] = v
			end
		end
	end
	if raw.checkpoint == "Reality" or raw.checkpoint == "Day" or raw.checkpoint == "Dream" or raw.checkpoint == "Choice" then
		blank.checkpoint = raw.checkpoint
		blank.day = if type(raw.day) == "number" then math.clamp(math.floor(raw.day), 1, 3) else 1
		blank.deaths = if type(raw.deaths) == "number" then math.clamp(math.floor(raw.deaths), 0, 1e6) else 0
		blank.currentState = if type(raw.currentState) == "string" then raw.currentState else nil
		blank.currentDream = if type(raw.currentDream) == "number" then math.clamp(math.floor(raw.currentDream), 0, 4) else 0
		blank.resourceSnapshot = if type(raw.resourceSnapshot) == "table" then raw.resourceSnapshot else nil
		for _, field in { "world", "flags" } do
			if type(raw[field]) == "table" then
				for k, v in raw[field] do
					if type(k) == "string" and #k <= 32 and v == true then
						blank[field][k] = true
					end
				end
			end
		end
		if type(raw.completed) == "table" then
			for _, id in raw.completed do
				if type(id) == "string" then
					table.insert(blank.completed, id)
				end
			end
		end
	end
	return blank
end

local function withRetry<T>(fn: () -> T): (boolean, T | string)
	local lastErr: any
	for attempt = 1, RETRIES do
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		if string.find(tostring(res), "Studio access to APIs", 1, true) then
			break -- permanent in this session, retrying won't help
		end
		task.wait(attempt)
	end
	return false, tostring(lastErr)
end

function SaveSystem.Load(player: Player): SaveData
	local uid = player.UserId
	if cache[uid] then
		return cache[uid]
	end
	local data = SaveSystem.Blank()
	if store then
		local ok, res = withRetry(function()
			return (store :: DataStore):GetAsync("u_" .. uid)
		end)
		if ok then
			data = sanitize(res)
		elseif string.find(tostring(res), "Studio access to APIs", 1, true) then
			-- Studio with API access off: go memory-only instead of retrying every write.
			warn("[SaveSystem] Studio API access disabled; saves are memory-only this session. Enable it in Game Settings > Security to test persistence.")
			store = nil
		else
			warn("[SaveSystem] load failed for", uid, res)
		end
	end
	cache[uid] = data
	return data
end

function SaveSystem.Get(player: Player): SaveData
	return cache[player.UserId] or SaveSystem.Load(player)
end

-- Swaps in a fresh record (new run / restart) and schedules a write.
function SaveSystem.Replace(player: Player, data: SaveData): SaveData
	cache[player.UserId] = data
	dirty[player.UserId] = true
	return data
end

function SaveSystem.Mark(player: Player)
	dirty[player.UserId] = true
end

-- Returns true when the record is safe (written, or memory-only session where the cache is the save).
function SaveSystem.Flush(player: Player): boolean
	local uid = player.UserId
	local data = cache[uid]
	if not data or not store then
		dirty[uid] = nil
		return data ~= nil
	end
	dirty[uid] = nil
	lastWrite[uid] = os.clock()
	local ok, err = withRetry(function()
		return (store :: DataStore):SetAsync("u_" .. uid, data, { uid })
	end)
	if not ok then
		dirty[uid] = true -- retry on the next loop pass
		if not warnedWrite then
			warnedWrite = true
			warn("[SaveSystem] write failed (will keep retrying):", err)
		end
	end
	return ok
end

function SaveSystem.Forget(player: Player)
	cache[player.UserId] = nil
	dirty[player.UserId] = nil
	lastWrite[player.UserId] = nil
end

task.spawn(function()
	while true do
		task.wait(1)
		for uid in dirty do
			if os.clock() - (lastWrite[uid] or 0) >= WRITE_GAP then
				local player = game:GetService("Players"):GetPlayerByUserId(uid)
				if player then
					task.spawn(SaveSystem.Flush, player)
				else
					dirty[uid] = nil
				end
			end
		end
	end
end)

return SaveSystem
