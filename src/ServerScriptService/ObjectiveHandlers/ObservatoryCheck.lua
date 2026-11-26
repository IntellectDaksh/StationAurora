--!strict
-- Dream 2: Telescope minigame locks the ship (director plays Flare after).
local ScareDirector = require(game:GetService("ServerScriptService").ScareDirector)

local ObservatoryCheck = {}

function ObservatoryCheck.onTriggered(session: any, _def: any, _prompt: ProximityPrompt?): boolean
	ScareDirector.Fire(session, "Toast", { text = "Locked. It's closer than yesterday. And it's dark." })
	return true
end

return ObservatoryCheck
