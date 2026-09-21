-- Measures the admin fly module's mechanics in isolation (Oliver's #52, the "fly" power).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/admin_fly_probe.lua
--
-- AdminHud.client.lua decides WHEN to call AdminFly.Start()/.Stop() -- six teardown paths (the
-- AdminFly attribute going false, death, respawn, the character being removed, the match ending,
-- this HUD being destroyed), verified by reading that file: every one of those six calls .Stop(),
-- and .Start() always calls .Stop() on itself first, so a respawn while still flagged can't leak the
-- old pair either. This probe measures what AdminFly.lua itself DOES when called: does Start() leave
-- exactly one BodyVelocity + one BodyGyro and PlatformStand true, does Stop() leave none and
-- PlatformStand false, is it idempotent, and does Start() on a new body clean up the old one.
--
-- No synthetic input: the runtest plugin sandbox refuses VirtualInputManager (RobloxScript capability
-- error), so this drives the Start()/Stop() state machine directly rather than through WASD/Space --
-- the same way the module's real caller drives it, just without a human's keys. "Holding Space
-- actually rises" needs Oliver's own eyes; this proves everything that can be read off an Instance.
--
-- Every section runs in its OWN pcall with the measurement read off the instance FIRST and asserted
-- on its own line, so one bad section can't hide another's numbers or abort the run early.
--
-- PERMANENT PLANTED FAULT: AdminFly._DebugSkipPlatformStandReset, a debug seam that ships false, is
-- set true here to reproduce "one teardown line deleted" and must be caught (PlatformStand stays
-- true after Stop()); then restored and re-proven clean, the same restore-and-reprove shape as
-- admin_probe.lua's FAULT 2.

local StarterPlayer = game:GetService("StarterPlayer")
local AdminFly = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("AdminFly"))

local failures = 0
local samples = 0
local function out(fmt, ...)
	print("[BRR_Probe] " .. string.format(fmt, ...))
end
local function check(ok, fmt, ...)
	samples += 1
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
end
-- A section that errors still shows up as one counted failure, and the rest of the run continues.
local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		out("FAIL  section %s threw: %s", name, tostring(err))
	end
end

local function dummyCharacter(name)
	local model = Instance.new("Model")
	model.Name = name
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Parent = model
	return model, humanoid, root
end

local charA, humA, rootA = dummyCharacter("A")
local charB, humB, rootB = dummyCharacter("B")
local charC, humC = dummyCharacter("C")
local charD = Instance.new("Model") -- no Humanoid, no HumanoidRootPart

section("initial state", function()
	local active = AdminFly.IsActive()
	check(active == false, "starts inactive")
end)

section("Start on a fresh body", function()
	local started = AdminFly.Start(charA)
	check(started == true, "Start returns true on a valid character")
	local active = AdminFly.IsActive()
	check(active == true, "IsActive after Start")
	local platformStand = humA.PlatformStand
	check(platformStand == true, "PlatformStand true while flying")
	local velocity = rootA:FindFirstChild("BRR_AdminFlyVelocity")
	check(velocity ~= nil, "BodyVelocity created on the root")
	local gyro = rootA:FindFirstChild("BRR_AdminFlyGyro")
	check(gyro ~= nil, "BodyGyro created on the root")
end)

section("Stop leaves nothing", function()
	AdminFly.Stop()
	local active = AdminFly.IsActive()
	check(active == false, "IsActive false after Stop")
	local platformStand = humA.PlatformStand
	check(platformStand == false, "PlatformStand restored false after Stop")
	local velocity = rootA:FindFirstChild("BRR_AdminFlyVelocity")
	check(velocity == nil, "no leftover BodyVelocity after Stop")
	local gyro = rootA:FindFirstChild("BRR_AdminFlyGyro")
	check(gyro == nil, "no leftover BodyGyro after Stop")
end)

section("Stop is idempotent", function()
	local ok = pcall(AdminFly.Stop)
	check(ok, "Stop on an already-stopped fly does not error")
end)

section("respawn: Start on a new body cleans up the old one", function()
	AdminFly.Start(charA)
	AdminFly.Start(charB) -- no explicit Stop in between, exactly what onCharacterAdded relies on
	local oldPlatformStand = humA.PlatformStand
	check(oldPlatformStand == false, "old body's PlatformStand cleared when Start() moves on")
	local oldVelocity = rootA:FindFirstChild("BRR_AdminFlyVelocity")
	check(oldVelocity == nil, "old body has no leftover BodyVelocity")
	local oldGyro = rootA:FindFirstChild("BRR_AdminFlyGyro")
	check(oldGyro == nil, "old body has no leftover BodyGyro")
	local newPlatformStand = humB.PlatformStand
	check(newPlatformStand == true, "new body is the one actually flying")
	local newVelocity = rootB:FindFirstChild("BRR_AdminFlyVelocity")
	check(newVelocity ~= nil, "new body has its own BodyVelocity")
	AdminFly.Stop()
end)

section("refuses bad bodies", function()
	humC.Health = 0
	local startedDead = AdminFly.Start(charC)
	check(startedDead == false, "Start refuses a body at 0 health")
	local startedNil = AdminFly.Start(nil)
	check(startedNil == false, "Start refuses a nil character")
	local startedEmpty = AdminFly.Start(charD)
	check(startedEmpty == false, "Start refuses a character with no Humanoid/root")
end)

section("FAULT: PlatformStand reset deleted from Stop()", function()
	AdminFly.Start(charA)
	AdminFly._DebugSkipPlatformStandReset = true
	AdminFly.Stop()
	local platformStand = humA.PlatformStand
	check(platformStand == true,
		"FAULT: with the reset skipped, Stop() leaves the humanoid stuck flying -- caught")
	AdminFly._DebugSkipPlatformStandReset = false
	humA.PlatformStand = false -- clean up the fault's own leftover before the real re-check
end)

section("restore: the real path is clean again", function()
	AdminFly.Start(charA)
	AdminFly.Stop()
	local platformStand = humA.PlatformStand
	check(platformStand == false, "PlatformStand false with the debug seam off")
	local velocity = rootA:FindFirstChild("BRR_AdminFlyVelocity")
	check(velocity == nil, "no leftover BodyVelocity with the debug seam off")
end)

for _, model in ipairs({ charA, charB, charC, charD }) do
	model:Destroy()
end

out("done: %d failures, %d checks", failures, samples)
