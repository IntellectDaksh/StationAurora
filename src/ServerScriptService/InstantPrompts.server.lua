-- Accessibility: every ProximityPrompt fires on a single E press, no hold.
-- Overrides hold times set in GameStateManager, StoryProps and objective defs.
local function instant(p)
	if p:IsA("ProximityPrompt") then
		p.HoldDuration = 0
		p:GetPropertyChangedSignal("HoldDuration"):Connect(function()
			if p.HoldDuration ~= 0 then p.HoldDuration = 0 end
		end)
	end
end
for _, d in ipairs(workspace:GetDescendants()) do instant(d) end
workspace.DescendantAdded:Connect(instant)
