--!strict
-- Comms: Transmit minigame (tune carrier + auth code) -> reply checks. The Static cue
-- after each reply check is played by the director, not here.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)
local DreamEvents = require((ReplicatedStorage :: any).Modules.DreamEvents)

local DEFAULT_ATTR = "AuroraDefaultText"
local CODE: string = DreamEvents.Reality.keypadCode

local function setScreen(tag: string, text: string?)
	local inst = CollectionService:GetTagged(tag)[1]
	if not inst then
		return
	end
	for _, t in inst:GetDescendants() do
		if t.Name == "StatusText" and t:IsA("TextLabel") then
			if t:GetAttribute(DEFAULT_ATTR) == nil then
				t:SetAttribute(DEFAULT_ATTR, t.Text)
			end
			local default = t:GetAttribute(DEFAULT_ATTR)
			t.Text = text or (if type(default) == "string" then default else t.Text)
		end
	end
end

local DistressSignal = {}

function DistressSignal.onActivated(_session: any, def: any)
	if def.id == "R_Distress" then
		setScreen(def.tag, nil)
	end
end

-- Transmit minigame opened: the auth code is readable on the comms screen too.
function DistressSignal.onMinigameOpen(_session: any, def: any)
	if def.id == "R_Distress" then
		setScreen(def.tag, "TRANSMIT AUTH CODE: " .. CODE)
	end
end

function DistressSignal.onTriggered(_session: any, def: any, _prompt: ProximityPrompt?): boolean
	if def.id == "R_Distress" then
		return false -- only the Transmit minigame (onClientComplete) can send the signal
	elseif def.id == "R_CheckReply1" then
		setScreen(def.tag, "NO RESPONSE")
		return true
	elseif def.id == "R_CheckReply2" then
		setScreen(def.tag, "NO RESPONSE // CHANNEL EMPTY")
		return true
	end
	return true
end

function DistressSignal.onClientComplete(session: any, def: any, data: any): boolean
	if def.id ~= "R_Distress" or type(data) ~= "table" then
		return false
	end
	if tostring(data.code) ~= CODE then
		ScareDirector.Fire(session, "Toast", { text = "Auth rejected. Wrong code." })
		return false
	end
	setScreen(def.tag, "DISTRESS SIGNAL SENT // AWAITING REPLY")
	ScareDirector.Fire(session, "Toast", { text = "Signal's out. Now I wait." })
	return true
end

return DistressSignal
