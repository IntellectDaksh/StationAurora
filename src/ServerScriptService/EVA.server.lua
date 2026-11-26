-- EVA system (server). Geometry: Workspace["Aurora EVA"]. Contract: ServerStorage.AuroraEVAEvent:Fire(player, kind)
-- kind: "EVAStart" | "EVAEnd" | "DishFixed" | "DuckFound". Player attrs: EVASuit, EVAActive, EVAO2End (server time), EVAReeling, DishFixed.
local Players=game:GetService("Players")
local F=workspace:WaitForChild("Aurora EVA")
local SS=game:GetService("ServerStorage")
local Event=SS:FindFirstChild("AuroraEVAEvent") or Instance.new("BindableEvent")
Event.Name="AuroraEVAEvent" Event.Parent=SS
local Remote=F:WaitForChild("EVARemote")
local O2_SECONDS=90
local TETHER=60

local inner,hatch,lamp=F.InnerDoor,F.OuterHatch,F.AirlockLight
local fog=F.FogEmitter:FindFirstChildOfClass("ParticleEmitter")
local anchorAtt=F.TetherAnchor.TetherAttach
local audio=game.ReplicatedStorage:FindFirstChild("StationAudio")
local hiss=audio and audio:FindFirstChild("SFX Door Whoosh",true)

local sessions={} -- [player]={rope,att,token}
local bolts={} -- [player]={[i]=true}
local ducks={}
local airlockBusy=false

local function root(p) local c=p.Character return c and c:FindFirstChild("HumanoidRootPart") end
local function tp(p,name) local r=root(p) if r then r.AssemblyLinearVelocity=Vector3.zero r.CFrame=CFrame.new(F[name].Position)*CFrame.Angles(0,math.rad(-90),0) end end
local function setDoor(part,open) part.Transparency=open and 1 or 0 part.CanCollide=not open end
local function sfx() if hiss and hiss:IsA("Sound") then local s=hiss:Clone() s.Parent=F.FogEmitter s:Play() game:GetService("Debris"):AddItem(s,5) end end

local WHITE=Color3.fromRGB(235,235,230)
local function weldPart(char,boneName,name,size,offset,color,mat,props)
	local bone=char:FindFirstChild(boneName) if not bone then return end
	local p=Instance.new("Part") p.Name=name p.Size=size p.Color=color or WHITE p.Material=mat or Enum.Material.Fabric
	p.CanCollide=false p.CanQuery=false p.CanTouch=false p.Massless=true p.CFrame=bone.CFrame*offset
	for k,v in props or {} do p[k]=v end
	local w=Instance.new("Weld") w.Name="SuitWeld" w.Part0=bone w.Part1=p w.C0=offset w.Parent=p
	p.Parent=char:FindFirstChild("EVASuitParts") return p end
local function addSuit(p)
	local c=p.Character if not c or c:FindFirstChild("EVASuitParts") then return end
	local f=Instance.new("Folder") f.Name="EVASuitParts" f.Parent=c
	local torso=c:FindFirstChild("UpperTorso") and "UpperTorso" or "Torso"
	weldPart(c,torso,"SuitTorso",Vector3.new(2.3,2.2,1.4),CFrame.new())
	weldPart(c,torso,"SuitBackpack",Vector3.new(1.8,2.2,0.8),CFrame.new(0,0,1.05),Color3.fromRGB(190,190,195),Enum.Material.Metal)
	weldPart(c,torso,"SuitStripe",Vector3.new(2.35,0.3,1.45),CFrame.new(0,0.5,0),Color3.fromRGB(220,90,30),Enum.Material.SmoothPlastic)
	weldPart(c,"Head","SuitHelmet",Vector3.new(2.1,2.1,2.1),CFrame.new(0,0.1,0),WHITE,Enum.Material.SmoothPlastic,{Shape=Enum.PartType.Ball,Transparency=0.05})
	weldPart(c,"Head","SuitVisor",Vector3.new(1.5,1,0.3),CFrame.new(0,0.1,-0.95),Color3.fromRGB(255,190,60),Enum.Material.Glass,{Transparency=0.35,Reflectance=0.4})
	p:SetAttribute("EVASuit",true)
end
local function removeSuit(p)
	local c=p.Character local f=c and c:FindFirstChild("EVASuitParts") if f then f:Destroy() end
	p:SetAttribute("EVASuit",false)
end

local function endEVA(p,how) -- how: "reenter"|"abort"|"dead"
	local s=sessions[p] if not s then return end
	sessions[p]=nil
	if s.rope then s.rope:Destroy() end if s.att then s.att:Destroy() end
	p:SetAttribute("EVAActive",false) p:SetAttribute("EVAO2End",nil) p:SetAttribute("EVAReeling",nil)
	Event:Fire(p,"EVAEnd")
	if how=="reenter" then
		tp(p,"ChamberSpot")
		Remote:FireClient(p,"Repressurize")
		task.delay(3,function() if p.Parent and not sessions[p] then tp(p,"BayEntry") end end)
	elseif how=="abort" then tp(p,"BayEntry") end
end

local function startEVA(p)
	local r=root(p) if not r or sessions[p] then return end
	tp(p,"HatchOut")
	local att=Instance.new("Attachment") att.Name="EVATetherAtt" att.Parent=r
	local rope=Instance.new("RopeConstraint") rope.Name="EVATether" rope.Attachment0=anchorAtt rope.Attachment1=att
	rope.Length=TETHER rope.Visible=true rope.Thickness=0.15 rope.Color=BrickColor.new("Bright yellow") rope.Parent=F.TetherAnchor
	local token={} sessions[p]={rope=rope,att=att,token=token}
	p:SetAttribute("EVAO2End",workspace:GetServerTimeNow()+O2_SECONDS)
	p:SetAttribute("EVAActive",true)
	Event:Fire(p,"EVAStart")
	task.spawn(function()
		while sessions[p] and sessions[p].token==token do
			if workspace:GetServerTimeNow()>=(p:GetAttribute("EVAO2End") or 0) then
				p:SetAttribute("EVAReeling",true) -- client flies toward the hatch
				task.wait(3)
				if sessions[p] and sessions[p].token==token then endEVA(p,"reenter") end
				return
			end
			task.wait(0.25)
		end
	end)
end

F.BayEntryPanel.EnterPrompt.Triggered:Connect(function(p) tp(p,"BayEntry") end)
F.BayReturnPanel.ReturnPrompt.Triggered:Connect(function(p) if not sessions[p] then tp(p,"StationReturn") end end)
local rackPart=F.SuitRack.RackPrompt
rackPart.SuitUpPrompt.Triggered:Connect(function(p)
	if p:GetAttribute("EVASuit") then return end
	addSuit(p) Remote:FireClient(p,"SuitUp")
end)
rackPart.RemovePrompt.Triggered:Connect(function(p) if not sessions[p] then removeSuit(p) end end)

F.InnerDoorPanel.CyclePrompt.Triggered:Connect(function(p)
	if airlockBusy or sessions[p] or not p:GetAttribute("EVASuit") then return end
	airlockBusy=true -- ponytail: one shared airlock, one cycle at a time
	tp(p,"ChamberSpot") setDoor(inner,false)
	lamp.Color=Color3.fromRGB(255,40,30) lamp.PointLight.Color=lamp.Color
	fog.Enabled=true sfx() Remote:FireClient(p,"Depressurize")
	task.wait(3)
	fog.Enabled=false setDoor(hatch,true)
	if p.Parent and p:GetAttribute("EVASuit") then startEVA(p) end
	task.wait(1.5)
	setDoor(hatch,false) setDoor(inner,true)
	lamp.Color=Color3.fromRGB(230,230,240) lamp.PointLight.Color=lamp.Color
	airlockBusy=false
end)
F.HatchPanel.ReenterPrompt.Triggered:Connect(function(p) if sessions[p] then endEVA(p,"reenter") end end)

for i=1,3 do
	F.EVA_Dish["Bolt"..i].BoltPrompt.Triggered:Connect(function(p)
		if not sessions[p] then return end
		bolts[p]=bolts[p] or {}
		if bolts[p][i] then return end
		bolts[p][i]=true
		Remote:FireClient(p,"Bolt",i)
		if bolts[p][1] and bolts[p][2] and bolts[p][3] and not p:GetAttribute("DishFixed") then
			p:SetAttribute("DishFixed",true) Event:Fire(p,"DishFixed")
		end
	end)
end
F.RubberDuck.DuckBody.DuckPrompt.Triggered:Connect(function(p)
	if not sessions[p] or ducks[p] then return end
	ducks[p]=true Remote:FireClient(p,"Duck") Event:Fire(p,"DuckFound")
end)

-- client reports state left Reality/Objectives
Remote.OnServerEvent:Connect(function(p,msg) if msg=="Abort" then endEVA(p,"abort") end end)

local function onChar(p,c)
	p:SetAttribute("EVASuit",false)
	local h=c:WaitForChild("Humanoid",10)
	if h then h.Died:Connect(function() endEVA(p,"dead") end) end
end
local function onPlayer(p)
	p.CharacterAdded:Connect(function(c) onChar(p,c) end)
	p.CharacterRemoving:Connect(function() endEVA(p,"dead") end)
	if p.Character then task.spawn(onChar,p,p.Character) end
end
Players.PlayerAdded:Connect(onPlayer)
for _,p in Players:GetPlayers() do onPlayer(p) end
Players.PlayerRemoving:Connect(function(p) endEVA(p,"dead") bolts[p]=nil ducks[p]=nil end)
