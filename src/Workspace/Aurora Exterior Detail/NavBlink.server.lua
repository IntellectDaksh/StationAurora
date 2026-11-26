-- Blinks exterior nav lights (parts with a "Blink" period attribute).
local parts={} for _,p in script.Parent:GetDescendants() do if p:IsA("BasePart") and p:GetAttribute("Blink") then table.insert(parts,p) end end
while true do
	local t=os.clock()
	for _,p in parts do
		local on=(t % p:GetAttribute("Blink")) < 0.25
		p.Transparency=on and 0 or 0.85
		local l=p:FindFirstChildOfClass("PointLight") if l then l.Enabled=on end
	end
	task.wait(0.1)
end
