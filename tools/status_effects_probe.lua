-- Do the creative guns' status effects actually do what StatusEffects says?
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/status_effects_probe.lua -WaitSeconds 120
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- Two stand-in bot combatants (a Humanoid and a root, registered with Combatants as bot tokens) far from
-- the map. Each check drives StatusEffects' own OnDamage listener the way CombatService would after a
-- hit, then measures the result on the victim:
--   knockback  the root's velocity points away from the shooter, at the gun's speed across
--   bleed      health falls by exactly the gun's bleed damage over its duration and then stops -- which
--              also proves a tick's own DealDamage doesn't restart the bleed (the re-entry guard)
--   chill      WalkSpeed drops by the slow per stack, the hit past the last stack freezes to 0, and a
--              hit inside the freeze immunity does not freeze again
--   self hit   a combatant's own damage applies nothing
--   death      a killing hit, or a death a tick finds, clears the effects and the slow, so the next
--              character walks at full speed
--   combat off a running bleed stops when the match ends

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ServerScriptService:WaitForChild("Modules")
local Combatants = require(Modules:WaitForChild("Combatants"))
local CombatService = require(Modules:WaitForChild("CombatService"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local StatusEffects = require(Modules:WaitForChild("StatusEffects"))
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))

local passed, failed = 0, 0
local function check(name, ok, detail)
	if ok then
		passed += 1
	else
		failed += 1
	end
	print(string.format("[BRR_Status] %-44s %s  %s", name, ok and "PASS" or "FAIL", detail or ""))
end

local folder = Instance.new("Folder")
folder.Name = "BRR_StatusProbe"
folder.Parent = workspace

-- A body for `token` (a fresh one each call, so a respawn can be staged). The root is anchored: loose,
-- it would fall past the kill height and be destroyed partway through the run. An anchored part still
-- holds the velocity a launch writes to it, which is what the knockback check reads.
local function body(token, position)
	local model = Instance.new("Model")
	model.Name = token.name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position)
	root.Anchored = true
	root.CanCollide = false
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = folder
	if token.character then
		Combatants.Unregister(token.character)
		token.character:Destroy()
	end
	token.character = model
	Combatants.Register(model, token)
	return humanoid, root
end

local function dummy(name, position)
	local token = { isBot = true, name = name }
	local humanoid, root = body(token, position)
	return token, humanoid, root
end

-- Combat is off outside a match (and in edit mode), and damage over time doesn't tick while it is off;
-- that rule is checked last, with combat switched back off.
local wasEnabled = CombatService.IsEnabled()
CombatService.SetEnabled(true)

local shooter = dummy("StatusShooter", Vector3.new(0, 6000, 0))
local victim, humanoid, root = dummy("StatusVictim", Vector3.new(0, 6000, -20))

-- Knockback: Boombox Bassline.
do
	local speed = WeaponData.Get("BoomboxBassline").knockback
	root.AssemblyLinearVelocity = Vector3.zero
	StatusEffects.OnDamage(shooter, victim, 10, "BoomboxBassline", false, false)
	local v = root.AssemblyLinearVelocity
	local across = Vector3.new(v.X, 0, v.Z)
	local away = Vector3.new(0, 0, -1)
	check("knockback pushes away at the gun's speed", across.Magnitude > 0 and math.abs(across.Magnitude - speed) < 0.5 and across.Unit:Dot(away) > 0.99,
		string.format("speed %.1f (want %d), direction dot %.2f", across.Magnitude, speed, across.Magnitude > 0 and across.Unit:Dot(away) or 0))
	root.AssemblyLinearVelocity = Vector3.zero
end

-- Self hit: nothing.
do
	root.AssemblyLinearVelocity = Vector3.zero
	StatusEffects.OnDamage(victim, victim, 10, "BoomboxBassline", false, false)
	check("a combatant's own hit applies nothing", root.AssemblyLinearVelocity.Magnitude < 1e-3, "")
end

-- Bleed: Pizza Cutter Crossbow, 12 over 3 seconds.
do
	local spec = WeaponData.Get("PizzaCutterCrossbow").bleed
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	StatusEffects.OnDamage(shooter, victim, 10, "PizzaCutterCrossbow", false, false)
	local dots = StatusEffects.Get(victim)
	check("bleed starts", dots ~= nil and dots.bleed ~= nil, "")
	task.wait(spec.duration + 1.2)
	local lost = 100 - humanoid.Health
	local after = StatusEffects.Get(victim)
	check("bleed deals its damage, then stops", math.abs(lost - spec.damage) < 0.6 and (after == nil or after.bleed == nil),
		string.format("lost %.1f (want %d), still bleeding: %s", lost, spec.damage, tostring(after ~= nil and after.bleed ~= nil)))
	task.wait(1.2)
	check("a tick doesn't restart the bleed", math.abs((100 - humanoid.Health) - spec.damage) < 0.6,
		string.format("lost %.1f a second later (want %d)", 100 - humanoid.Health, spec.damage))
end

-- Chill: Snow Globe Singularity.
do
	local spec = WeaponData.Get("SnowGlobeSingularity").chill
	humanoid.Health = 100
	-- Let MatchService compose the victim's base speed first (clearing an unused key re-applies it), so the
	-- slowed speeds are compared with the speed applySpeed itself uses, not Humanoid's default 16.
	MatchService.SetStatusSpeed(victim, "probeBase", 1, 0)
	local base = humanoid.WalkSpeed
	local speeds = {}
	for hit = 1, spec.stacks do
		StatusEffects.OnDamage(shooter, victim, 10, "SnowGlobeSingularity", false, false)
		speeds[hit] = humanoid.WalkSpeed
	end
	local ok = base > 0
	for hit = 1, spec.stacks do
		local want = base * math.max(0.05, 1 - spec.slow * hit)
		ok = ok and math.abs(speeds[hit] - want) < 0.05
	end
	check("each chill stack slows by its share", ok,
		string.format("base %.2f -> %s", base, table.concat((function()
			local out = {}
			for _, speed in ipairs(speeds) do
				table.insert(out, string.format("%.2f", speed))
			end
			return out
		end)(), ", ")))
	StatusEffects.OnDamage(shooter, victim, 10, "SnowGlobeSingularity", false, false)
	check("the hit past the last stack freezes", humanoid.WalkSpeed < 0.01, string.format("WalkSpeed %.2f (want 0)", humanoid.WalkSpeed))
	task.wait(spec.freeze + 0.2)
	for _ = 1, spec.stacks + 1 do
		StatusEffects.OnDamage(shooter, victim, 10, "SnowGlobeSingularity", false, false)
	end
	check("no refreeze inside the immunity", humanoid.WalkSpeed > 0.01, string.format("WalkSpeed %.2f (want above 0)", humanoid.WalkSpeed))
end

-- Death: everything on a combatant goes with them, the slow MatchService holds included. It is keyed by
-- token, so a leftover would meet the next character; each case stages that respawn and reads its speed.
-- Both ways a death is noticed: the killing hit itself, and a later tick (the storm, a fall).
do
	local fallen = { isBot = true, name = "StatusFallen" }
	local spot = Vector3.new(0, 6000, 20)
	local fallenHumanoid = body(fallen, spot)
	MatchService.SetStatusSpeed(fallen, "probeBase", 1, 0)
	local base = fallenHumanoid.WalkSpeed
	local function respawnSpeed()
		local humanoid = body(fallen, spot)
		MatchService.SetStatusSpeed(fallen, "probeBase", 1, 0)
		return humanoid.WalkSpeed
	end

	StatusEffects.OnDamage(shooter, fallen, 10, "SnowGlobeSingularity", false, false)
	StatusEffects.OnDamage(shooter, fallen, 10, "PizzaCutterCrossbow", false, false)
	local slowed = fallenHumanoid.WalkSpeed
	fallenHumanoid.Health = 0
	StatusEffects.OnDamage(shooter, fallen, 10, "SnowGlobeSingularity", false, false)
	local dots, chill = StatusEffects.Get(fallen)
	local speed = respawnSpeed()
	check("a killing hit clears everything", slowed < base - 0.01 and dots == nil and chill == nil and math.abs(speed - base) < 0.05,
		string.format("slowed %.2f, left: bleed %s chill %s, next character %.2f (want %.2f)", slowed, tostring(dots ~= nil), tostring(chill ~= nil), speed, base))

	fallenHumanoid = fallen.character:FindFirstChildOfClass("Humanoid")
	StatusEffects.OnDamage(shooter, fallen, 10, "SnowGlobeSingularity", false, false)
	slowed = fallenHumanoid.WalkSpeed
	fallenHumanoid.Health = 0
	-- Well inside the chill's duration, so only the clearing can bring the speed back.
	task.wait(0.8)
	dots, chill = StatusEffects.Get(fallen)
	speed = respawnSpeed()
	check("a death found by a tick clears everything", slowed < base - 0.01 and chill == nil and math.abs(speed - base) < 0.05,
		string.format("slowed %.2f, chill left %s, next character %.2f (want %.2f)", slowed, tostring(chill ~= nil), speed, base))
	Combatants.Unregister(fallen.character)
end

-- Combat switched off (the match ended): a running bleed stops.
do
	humanoid.Health = 100
	StatusEffects.OnDamage(shooter, victim, 10, "PizzaCutterCrossbow", false, false)
	CombatService.SetEnabled(false)
	task.wait(2)
	check("no damage over time once combat is off", humanoid.Health >= 100 - 0.01 and StatusEffects.Get(victim) == nil,
		string.format("health %.1f (want 100)", humanoid.Health))
end
CombatService.SetEnabled(wasEnabled)

Combatants.Unregister(shooter.character)
Combatants.Unregister(victim.character)
folder:Destroy()
print(string.format("[BRR_Status] passed %d, failed %d", passed, failed))
print("[BRR_Status] done")
