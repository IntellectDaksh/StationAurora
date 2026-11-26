-- BlurGuard: keeps the view crisp by disabling any BlurEffect injected at runtime
-- (e.g. by the Freecam tool or other plugins) for the whole session.

local Lighting = game:GetService("Lighting")

local function killBlur(inst)
	if inst:IsA("BlurEffect") then
		inst.Enabled = false
		inst.Size = 0
	end
end

-- kill any blur that already exists
for _, e in ipairs(Lighting:GetChildren()) do
	killBlur(e)
end

-- and keep killing them as they appear
Lighting.ChildAdded:Connect(killBlur)

-- also check the camera, some tools parent effects there
local cam = workspace.CurrentCamera
if cam then
	for _, e in ipairs(cam:GetChildren()) do
			killBlur(e)
	end
	cam.ChildAdded:Connect(killBlur)
end

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	local newCam = workspace.CurrentCamera
	if newCam then
		for _, e in ipairs(newCam:GetChildren()) do
			killBlur(e)
		end
		newCam.ChildAdded:Connect(killBlur)
	end
end)