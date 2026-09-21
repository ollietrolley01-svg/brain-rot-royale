-- Probe for tools/runtest.ps1: the crouch accuracy bonus.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/crouch_accuracy_probe.lua
--
-- Crouched and barely moving, a shot goes out with spread x0.75 and the camera kicks x0.85, faded
-- in over CombatService.Steady.Fade. What's measured is what's fired: CombatService.SpreadFor is
-- the call Fire itself makes, and SteadyRecoil is what the shooter's client scales its kick by.
--
-- Four states:
--   standing               no bonus
--   crouched, still        the full bonus once the fade is through
--   crouched, moving fast  no bonus (crouch-walking runs at 45% of base speed, over the threshold)
--   crouched then stood    nothing on the very next shot, no trailing grace
-- Then aiming, to show the two scales multiply rather than either being counted twice; and two tap
-- rounds. In the real round, crouching for the instant of a shot must pay almost nothing. In the
-- planted round the fade is removed, where the same tap MUST pay in full — without that, the tap
-- test would pass on a build where the fade did nothing at all.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local CombatService = require(modules:WaitForChild("CombatService"))
local MatchService = require(modules:WaitForChild("MatchService"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local function out(fmt, ...)
	print("[AUDIT crouch] " .. string.format(fmt, ...))
end

local failures = {}
local function check(name, ok, detail)
	if not ok then
		table.insert(failures, name)
	end
	out("%s %s%s", ok and "PASS" or "FAIL", name, detail and (" - " .. detail) or "")
end

-- The line Bootstrap runs: MatchService requires CombatService, so the crouch state is handed over
-- rather than required back.
CombatService.IsCrouching = MatchService.IsCrouching

-- A stand-in combatant. A bot token is a table with a character, which is all of this reads.
local stage = Instance.new("Folder")
stage.Name = "CrouchProbeStage"
stage.Parent = workspace

local character = Instance.new("Model")
character.Name = "CrouchProbeDummy"
local humanoid = Instance.new("Humanoid")
humanoid.Parent = character
local root = Instance.new("Part")
root.Name = "HumanoidRootPart"
root.Size = Vector3.new(2, 2, 1)
root.CFrame = CFrame.new(0, 200, 0)
root.Anchored = false
root.CanCollide = false
root.Parent = character
character.PrimaryPart = root
character.Parent = stage

local token = { isBot = true, character = character, name = "CrouchProbe" }

-- Sorted, so the run is repeatable rather than whichever key pairs() happens to hand back first.
local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)
local def = nil
for _, id in ipairs(ids) do
	local candidate = WeaponData.Get(id)
	if candidate and (candidate.spread or 0) > 0 and not candidate.projectile then
		def = candidate
		break
	end
end
if not def then
	out("no weapon with a spread to measure with; nothing to do")
	stage:Destroy()
	pcall(flush)
	return
end
local BASE = def.spread
local THRESHOLD = MatchConfig.BaseWalkSpeed * CombatService.Steady.MoveFraction
out("weapon %s, spread %.2f; still under %.1f studs/s, crouch-walk is %.1f",
	def.id or "?", BASE, THRESHOLD, MatchConfig.BaseWalkSpeed * 0.45)

local function setCrouched(value)
	local ok, err = pcall(MatchService.SetCrouching, token, value)
	if not ok then
		out("MatchService.SetCrouching(%s) errored: %s", tostring(value), tostring(err))
		return false
	end
	return MatchService.IsCrouching(token) == value
end

local function setSpeed(speed)
	root.AssemblyLinearVelocity = Vector3.new(speed, 0, 0)
	return Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
end

local function sample()
	return CombatService.SteadyFactor(token), CombatService.SpreadFor(token, def), CombatService.SteadyRecoil(token)
end

local function near(a, b)
	return math.abs(a - b) < 0.02
end

CombatService.WatchCrouch(character)

-- The velocity has to stick for the "moving" state to mean anything: nothing simulates in edit
-- mode, so it should read back exactly, but say so rather than quietly passing if it doesn't.
local readBack = setSpeed(12)
if readBack < 11 then
	out("INCONCLUSIVE: velocity set to 12 reads back as %.2f, so the moving state can't be measured", readBack)
	stage:Destroy()
	pcall(flush)
	return
end
setSpeed(0)

-- 1. Standing.
setCrouched(false)
local factor, spread, recoil = sample()
check("standing: no bonus", factor == 0 and near(spread, BASE) and near(recoil, 1),
	string.format("factor %.2f, spread %.2f of %.2f, recoil %.2f", factor, spread, BASE, recoil))

-- 2. Crouched and still, fade through.
if not setCrouched(true) then
	out("INCONCLUSIVE: the dummy wouldn't crouch (MatchService.IsCrouching stayed false)")
	stage:Destroy()
	pcall(flush)
	return
end
task.wait(CombatService.Steady.Fade * 2)
factor, spread, recoil = sample()
check("crouched and still: full bonus", near(factor, 1) and near(spread, BASE * 0.75) and near(recoil, 0.85),
	string.format("factor %.2f, spread %.2f (want %.2f), recoil %.2f", factor, spread, BASE * 0.75, recoil))

-- 3. Aiming as well: the two scales multiply, neither counted twice.
CombatService.SetAiming(token, true)
local adsCrouched = select(2, sample())
CombatService.SetAiming(token, false)
setCrouched(false)
CombatService.SetAiming(token, true)
local adsStanding = select(2, sample())
CombatService.SetAiming(token, false)
check("aiming and crouching multiply once", adsStanding > 0 and near(adsCrouched, adsStanding * 0.75),
	string.format("aimed standing %.3f, aimed crouched %.3f (want %.3f)", adsStanding, adsCrouched, adsStanding * 0.75))

-- 4. Crouched but moving faster than the threshold: it fades back out.
setCrouched(true)
setSpeed(0)
task.wait(CombatService.Steady.Fade * 2)
setSpeed(12)
task.wait(CombatService.Steady.Fade * 2)
factor, spread, recoil = sample()
check("crouched but moving: no bonus", factor == 0 and near(spread, BASE) and near(recoil, 1),
	string.format("factor %.2f at %.1f studs/s", factor, 12))

-- 5. Crouched, steady, then standing up: gone on the very next shot.
setSpeed(0)
task.wait(CombatService.Steady.Fade * 2)
local before = CombatService.SteadyFactor(token)
setCrouched(false)
factor, spread, recoil = sample()
check("standing up ends it at once", near(before, 1) and factor == 0 and near(spread, BASE) and near(recoil, 1),
	string.format("was %.2f, now %.2f with no wait", before, factor))

-- 6. Tapping the crouch for one shot. Real fade, then the planted round with no fade at all.
local function tapFactor()
	setCrouched(false)
	task.wait(0.1)
	setSpeed(0)
	setCrouched(true)
	task.wait() -- one frame: the crouch and the shot in the same instant
	local value = CombatService.SteadyFactor(token)
	setCrouched(false)
	return value
end

local realTap = tapFactor()
local fade = CombatService.Steady.Fade
CombatService.Steady.Fade = 1e-6
local plantedTap = tapFactor()
CombatService.Steady.Fade = fade

check("tapping the crouch pays nothing", realTap < 0.3, string.format("factor %.2f one frame in", realTap))
check("self-test: with the fade removed the tap pays out", plantedTap > 0.9,
	string.format("factor %.2f (if this fails the tap test above proves nothing)", plantedTap))

-- And the real fade still pays in full when it's held.
setCrouched(true)
setSpeed(0)
task.wait(CombatService.Steady.Fade * 2)
check("holding the crouch pays in full", near(CombatService.SteadyFactor(token), 1),
	string.format("factor %.2f", CombatService.SteadyFactor(token)))
setCrouched(false)

out("RESULT %s (%d of 8 checks failed%s)", #failures == 0 and "PASS" or "FAIL", #failures,
	#failures > 0 and (": " .. table.concat(failures, ", ")) or "")

stage:Destroy()
pcall(flush)
