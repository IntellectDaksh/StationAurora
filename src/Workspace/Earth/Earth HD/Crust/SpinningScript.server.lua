--[[

This is a script that makes an anchored brick rotate!
Just resize the brick to your desired size!
This script was made by Tkdriverx
Free for anyone to use!

]]
while true do --Infinite loop
task.wait(0.1) -- ponytail: throttled 30Hz->10Hz, angle scaled to match (perf: big mesh CFrame write is expensive per-frame)
script.Parent.CFrame = script.Parent.CFrame * CFrame.fromEulerAnglesXYZ(0, math.pi/300, 0) --Rotates the brick. Change the numbers for how fast/slow the brick rotates.
--(continued from last line) The higher, the slower. The lower, the faster. Change the 0's to "math.pi/number." Make sure the number ISN'T 0!
end --Ends the "while true do"
