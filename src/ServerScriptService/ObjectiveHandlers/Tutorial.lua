--!strict
-- Tutorial: T_Flashlight (clientAction) and T_FindGenerator (reach) complete via
-- Session:Complete directly, never through onTriggered. This handler exists to satisfy
-- the contract explicitly and as a hook point for future tutorial beats.
local Tutorial = {}

function Tutorial.onTriggered(_session: any, _def: any, _prompt: ProximityPrompt?): boolean
	return true
end

return Tutorial
