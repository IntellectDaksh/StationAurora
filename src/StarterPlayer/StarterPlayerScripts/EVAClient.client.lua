-- EVA client: prompt gating, suit-up cinematic, zero-g flight, helmet O2 HUD. Server: ServerScriptService.EVA
local Players=game:GetService("Players")
local RunService=game:GetService("RunService")
local UIS=game:GetService("UserInputService")
local TweenService=game:GetService("TweenService")
local Debris=game:GetService("Debris")
local player=Players.LocalPlayer
local F=workspace:WaitForChild("Aurora EVA")
local Remote=F:WaitForChild("EVARemote")
local Remotes=game.ReplicatedStorage:WaitForChild("Remotes")
local audio=game.ReplicatedStorage:FindFirstChild("StationAudio")
local function findSound(pat) if not audio then return end for _,s in audio:GetDescendants() do if s:IsA("Sound") and s.Name:lower():find(pat) then return s end end end
local beepSnd,breathSnd=findSound("beep"),findSound("breath")

local state="Reality" -- ponytail: assume free-roam until the first StateChanged arrives
local function freeState() return state=="Reality" or state=="Objectives" end
local function inEVA() return player:GetAttribute("EVAActive")==true end
local function suited() return player:GetAttribute("EVASuit")==true end

-- prompt gating (local Enabled only; server re-validates)
local rackP=F:WaitForChild("SuitRack"):WaitForChild("RackPrompt")
local P={
	suit=rackP:WaitForChild("SuitUpPrompt"), remove=rackP:WaitForChild("RemovePrompt"),
	cycle=F:WaitForChild("InnerDoorPanel"):WaitForChild("CyclePrompt"), reenter=F:WaitForChild("HatchPanel"):WaitForChild("ReenterPrompt"),
	duck=F:WaitForChild("RubberDuck"):WaitForChild("DuckBody"):WaitForChild("DuckPrompt"),
	enter=F:WaitForChild("BayEntryPanel"):WaitForChild("EnterPrompt"), ret=F:WaitForChild("BayReturnPanel"):WaitForChild("ReturnPrompt"),
}
local dish=F:WaitForChild("EVA_Dish")
local boltP={} for i=1,3 do boltP[i]=dish:WaitForChild("Bolt"..i):WaitForChild("BoltPrompt") end
local boltsDone={}
local duckDone=false
local function refresh()
	local free=freeState()
	P.suit.Enabled=free and not suited()
	P.remove.Enabled=free and suited() and not inEVA()
	P.cycle.Enabled=free and suited() and not inEVA()
	P.reenter.Enabled=inEVA()
	P.enter.Enabled=free
	P.ret.Enabled=free and not inEVA()
	P.duck.Enabled=inEVA() and not duckDone
	for i=1,3 do boltP[i].Enabled=inEVA() and not boltsDone[i] end
end

-- helmet HUD
local gui=Instance.new("ScreenGui") gui.Name="EVAHud" gui.ResetOnSpawn=false gui.IgnoreGuiInset=true gui.Enabled=false gui.Parent=player:WaitForChild("PlayerGui")
local tint=Instance.new("Frame") tint.Size=UDim2.fromScale(1,1) tint.BackgroundColor3=Color3.fromRGB(255,190,60) tint.BackgroundTransparency=1 tint.BorderSizePixel=0 tint.Parent=gui
local box=Instance.new("Frame") box.AnchorPoint=Vector2.new(1,0) box.Position=UDim2.new(1,-24,0,70) box.Size=UDim2.fromOffset(190,54) box.BackgroundColor3=Color3.fromRGB(10,14,20) box.BackgroundTransparency=0.35 box.Parent=gui
Instance.new("UICorner",box).CornerRadius=UDim.new(0,8)
local st=Instance.new("UIStroke") st.Color=Color3.fromRGB(120,220,255) st.Transparency=0.4 st.Parent=box
local label=Instance.new("TextLabel") label.Size=UDim2.new(1,0,1,-8) label.BackgroundTransparency=1 label.Font=Enum.Font.Code label.TextSize=16 label.TextColor3=Color3.fromRGB(150,230,255) label.Text="SUIT OK" label.Parent=box
local barBg=Instance.new("Frame") barBg.Position=UDim2.new(0,10,1,-12) barBg.Size=UDim2.new(1,-20,0,4) barBg.BackgroundColor3=Color3.fromRGB(40,50,60) barBg.BorderSizePixel=0 barBg.Parent=box
local bar=Instance.new("Frame") bar.Size=UDim2.fromScale(1,1) bar.BackgroundColor3=Color3.fromRGB(120,220,255) bar.BorderSizePixel=0 bar.Parent=barBg

-- suit-up cinematic (~6s)
local cinematic=false
local function playSuitUp()
	local char=player.Character local hrp=char and char:FindFirstChild("HumanoidRootPart") if not hrp or cinematic then return end
	cinematic=true
	local cam=workspace.CurrentCamera
	cam.CameraType=Enum.CameraType.Scriptable
	local f=char:WaitForChild("EVASuitParts",3)
	local welds={}
	for _,n in {"SuitHelmet","SuitVisor"} do local part=f and f:WaitForChild(n,3) local w=part and part:FindFirstChild("SuitWeld") if w then welds[w]=w.C0 w.C0=w.C0+Vector3.new(0,3,0) end end
	local b=breathSnd and breathSnd:Clone() if b then b.Looped=true b.Parent=gui b:Play() end
	gui.Enabled=true box.BackgroundTransparency=1 label.TextTransparency=1 st.Transparency=1 bar.BackgroundTransparency=1 barBg.BackgroundTransparency=1
	local t0=os.clock()
	local conn=RunService.RenderStepped:Connect(function()
		if not hrp.Parent then return end
		local t=os.clock()-t0
		local a=t/6*math.pi*1.5 local c=hrp.Position+Vector3.new(0,1.5,0)
		local rad=10-6*math.min(t/6,1)
		cam.CFrame=CFrame.lookAt(c+Vector3.new(math.cos(a)*rad,1.5+math.sin(t)*0.5,math.sin(a)*rad),c)
	end)
	task.wait(2)
	for w,c0 in welds do if w.Parent then TweenService:Create(w,TweenInfo.new(2,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),{C0=c0}):Play() end end
	task.wait(2)
	for _,o in {{box,{BackgroundTransparency=0.35}},{label,{TextTransparency=0}},{st,{Transparency=0.4}},{tint,{BackgroundTransparency=0.94}},{bar,{BackgroundTransparency=0}},{barBg,{BackgroundTransparency=0}}} do TweenService:Create(o[1],TweenInfo.new(1.5),o[2]):Play() end
	task.wait(2)
	conn:Disconnect()
	if b then b:Destroy() end
	cam.CameraType=Enum.CameraType.Custom
	cinematic=false
end

-- zero-g flight: PlatformStand + LinearVelocity (cancels gravity), eased toward input for inertia
local flight
local function stopFlight()
	if not flight then return end
	flight.lv:Destroy() flight.att:Destroy()
	local h=flight.hum if h.Parent and h.Health>0 then h.PlatformStand=false h:ChangeState(Enum.HumanoidStateType.GettingUp) end
	flight=nil
end
local function startFlight()
	local char=player.Character local hrp=char and char:FindFirstChild("HumanoidRootPart") local hum=char and char:FindFirstChildOfClass("Humanoid")
	if not hrp or not hum or flight then return end
	local att=Instance.new("Attachment") att.Name="EVAFlightAtt" att.Parent=hrp
	local lv=Instance.new("LinearVelocity") lv.Name="EVAFlight" lv.Attachment0=att lv.MaxForce=1e5 lv.RelativeTo=Enum.ActuatorRelativeTo.World lv.VectorVelocity=Vector3.zero lv.Parent=hrp
	hum.PlatformStand=true
	flight={lv=lv,att=att,hum=hum,hrp=hrp,vel=Vector3.new(4,1,0)} -- small push out of the hatch
end
local SPEED,ACCEL=14,1.2 -- studs/s; ACCEL lower = floatier
local anchorPos=F:WaitForChild("TetherAnchor"):WaitForChild("TetherAttach").WorldPosition
local hatchPos=F:WaitForChild("HatchOut").Position
RunService.Heartbeat:Connect(function(dt)
	if not flight then return end
	local hrp=flight.hrp if not hrp.Parent then stopFlight() return end
	local cam=workspace.CurrentCamera.CFrame
	local want
	if player:GetAttribute("EVAReeling") then
		local d=hatchPos-hrp.Position want=d.Magnitude>1 and d.Unit*22 or Vector3.zero
	else
		local m=Vector3.zero
		if UIS:GetFocusedTextBox()==nil then
			if UIS:IsKeyDown(Enum.KeyCode.W) then m+=cam.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.S) then m-=cam.LookVector end
			if UIS:IsKeyDown(Enum.KeyCode.D) then m+=cam.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.A) then m-=cam.RightVector end
			if UIS:IsKeyDown(Enum.KeyCode.Space) or UIS:IsKeyDown(Enum.KeyCode.E) then m+=Vector3.yAxis end
			if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then m-=Vector3.yAxis end
		end
		want=(m.Magnitude>0 and m.Unit or m)*SPEED
	end
	flight.vel=flight.vel:Lerp(want,math.min(1,ACCEL*dt))
	local off=hrp.Position-anchorPos -- hard tether: kill outward velocity at the limit (rope also enforces 60)
	if off.Magnitude>57 then local n=off.Unit local out=flight.vel:Dot(n) if out>0 then flight.vel-=n*out end end
	flight.lv.VectorVelocity=flight.vel
	hrp.AssemblyAngularVelocity=Vector3.zero
end)

-- O2 readout
local lastBeep=0
RunService.RenderStepped:Connect(function()
	local o2End=player:GetAttribute("EVAO2End")
	if not o2End then return end
	local left=math.max(0,o2End-workspace:GetServerTimeNow())
	bar.Size=UDim2.fromScale(left/90,1)
	local warn=left<=20
	bar.BackgroundColor3=warn and Color3.fromRGB(255,70,50) or Color3.fromRGB(120,220,255)
	label.TextColor3=bar.BackgroundColor3
	label.Text=player:GetAttribute("EVAReeling") and "O2 OUT - REELING IN" or string.format("O2  %02ds%s",math.ceil(left),warn and "  LOW" or "")
	if warn and left>0 and os.clock()-lastBeep>1 then lastBeep=os.clock() if beepSnd then local s=beepSnd:Clone() s.Parent=gui s:Play() Debris:AddItem(s,2) end end
end)

local function onAttr()
	if inEVA() then startFlight() else stopFlight() end
	if not cinematic then gui.Enabled=suited() end
	if not suited() then tint.BackgroundTransparency=1 end
	if not inEVA() then bar.Size=UDim2.fromScale(1,1) bar.BackgroundColor3=Color3.fromRGB(120,220,255) label.TextColor3=bar.BackgroundColor3 if not cinematic then label.Text="SUIT OK" end end
	refresh()
end
for _,a in {"EVAActive","EVASuit","EVAReeling"} do player:GetAttributeChangedSignal(a):Connect(onAttr) end
player.CharacterAdded:Connect(function() stopFlight() task.defer(onAttr) end)

Remotes:WaitForChild("StateChanged").OnClientEvent:Connect(function(s)
	if typeof(s)~="string" then return end
	state=s
	if inEVA() and not freeState() then Remote:FireServer("Abort") end
	refresh()
end)

Remote.OnClientEvent:Connect(function(kind,arg)
	if kind=="SuitUp" then task.spawn(playSuitUp)
	elseif kind=="Depressurize" then label.Text="DEPRESSURIZING..."
	elseif kind=="Repressurize" then label.Text="REPRESSURIZING..." task.delay(3,function() if not inEVA() and suited() then label.Text="SUIT OK" end end)
	elseif kind=="Bolt" then boltsDone[arg]=true local b=dish:FindFirstChild("Bolt"..tostring(arg)) if b then b.Color=Color3.fromRGB(80,220,110) end refresh()
	elseif kind=="Duck" then duckDone=true for _,p in F.RubberDuck:GetChildren() do if p:IsA("BasePart") then p.Transparency=1 end end refresh() end
end)
refresh()
