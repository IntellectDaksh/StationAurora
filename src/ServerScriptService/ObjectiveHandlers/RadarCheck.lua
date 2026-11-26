--!strict
-- Dream 1: windows, radar sweep, back to quarters (director plays ShadowFigure after).
local CollectionService = game:GetService("CollectionService")
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local DEFAULT_ATTR = "AuroraDefaultText"

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

local RadarCheck = {}

function RadarCheck.onActivated(_session: any, def: any)
	if def.id == "D1_Radar" then
		setScreen(def.tag, "ANOMALY FLAGGED // SWEEP REQUIRED")
	end
end

function RadarCheck.onMinigameOpen(_session: any, def: any)
	if def.id == "D1_Radar" then
		setScreen(def.tag, "SWEEP IN PROGRESS...")
	end
end

function RadarCheck.onTriggered(session: any, def: any, _prompt: ProximityPrompt?): boolean
	if def.id == "D1_Windows" then
		ScareDirector.Fire(session, "Toast", { text = "A glint past the array. Gone before you can focus." })
	elseif def.id == "D1_Radar" then
		setScreen(def.tag, "SWEEP COMPLETE // NO CONTACTS")
		ScareDirector.Fire(session, "Toast", { text = "Radar's clean. It was there. Then it wasn't." })
	end
	return true
end

return RadarCheck
