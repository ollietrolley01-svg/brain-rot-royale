-- What a shotgun ACTUALLY does at range, measured rather than assumed.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/shotgun_range_probe.lua -WaitSeconds 420
--
-- Oliver: "just make the shotguns more balanced ig but not weak." Every damage argument on this
-- project so far has been about `damage x pellets` -- a FULL pellet hit -- and that number only
-- happens at point-blank range. Pellets go out in a cone, so the count that lands falls off with
-- distance, and THAT is the game's real falloff curve. Nobody has ever measured it, so nobody knows
-- whether these guns are strong at 30 studs or already harmless there.
--
-- So: fire each shotgun at a real R15 body at 5, 10, 20, 30 and 50 studs, hundreds of times, and
-- count the pellets that land. The cone is the game's own -- `applySpread`'s uniform tilt in
-- [0, spread] about a uniform spin, copied exactly (a uniform tilt is NOT a uniform disc: it packs
-- pellets toward the middle, and a probe that used a uniform disc would report a weaker gun than the
-- one Oliver is shooting) -- and the spread is `CombatService.SpreadFor`'s: the weapon's own, x0.34
-- aimed, x0.75 crouched and steady.
--
-- The target is a real R15 rig, hit with a real raycast, because a box stand-in cannot tell you how
-- often a pellet slips between an arm and the chest.
--
-- PLANTED FAULTS, every run: a gun with no spread must land every pellet at every range (if it does
-- not, the aim or the target is wrong and every other number here is noise); and with the body taken
-- out of the world, nothing may land (if something still does, the probe is counting the scenery).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local CombatService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("CombatService"))

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local RANGES = { 5, 10, 20, 30, 50 }
local TRIALS = 300
local ORIGIN = Vector3.new(0, 4000, 0)
-- Where a player's eye is, and where a player aims: the middle of the chest.
local EYE = Vector3.new(0, 1.5, 0)

-- The game's own cone, copied line for line from CombatService.applySpread so the two cannot drift.
local function applySpread(direction, spreadDegrees)
	if spreadDegrees <= 0 then
		return direction
	end
	local spin = math.random() * math.pi * 2
	local tilt = math.random() * math.rad(spreadDegrees)
	local base = CFrame.lookAt(Vector3.zero, direction)
	return (base * CFrame.Angles(0, 0, spin) * CFrame.Angles(tilt, 0, 0)).LookVector
end

--------------------------------------------------------------------------------
-- The target
--------------------------------------------------------------------------------

local stage = Instance.new("Folder")
stage.Name = "BRR_ShotgunRange"
stage.Parent = workspace

local function makeDummy()
	local ok, model = pcall(function()
		local description = Instance.new("HumanoidDescription")
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if not ok or not model then
		return nil, tostring(model)
	end
	-- Hats and hair are not hitboxes anyone should be scoring against.
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("Accessory") then
			child:Destroy()
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model.Parent = stage
	return model
end

local dummy, err = makeDummy()
if not dummy then
	out("NO R15 RIG could be built here (%s) -- nothing below would be a measurement", tostring(err))
	out("done")
	return {}
end

local bodyParts = 0
for _, d in ipairs(dummy:GetDescendants()) do
	if d:IsA("BasePart") then
		bodyParts += 1
	end
end
local torso = dummy:FindFirstChild("UpperTorso") or dummy:FindFirstChild("Torso")
local head = dummy:FindFirstChild("Head")
out("target: a real R15 body, %d parts, torso %s, head %s", bodyParts,
	torso and string.format("%.2f x %.2f x %.2f", torso.Size.X, torso.Size.Y, torso.Size.Z) or "MISSING",
	head and string.format("%.2f x %.2f x %.2f", head.Size.X, head.Size.Y, head.Size.Z) or "MISSING")

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { dummy }
params.IgnoreWater = true

-- Puts the body `distance` studs away, standing on nothing in particular, facing the shooter.
local function standAt(distance)
	dummy:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 0, -distance)) * CFrame.Angles(0, math.pi, 0))
end

--------------------------------------------------------------------------------
-- One gun at one range
--------------------------------------------------------------------------------

-- Fires `trials` shots and returns the mean, the worst and the best pellet count that landed, plus
-- how often nothing landed at all and how many landed on the head.
local function volley(def, spread, aimAt, trials)
	local origin = ORIGIN + EYE
	local total, worst, best, misses, heads = 0, math.huge, 0, 0, 0
	local pellets = def.pellets or 1
	local reach = (def.range or 200)
	for _ = 1, trials do
		local unit = (aimAt - origin).Unit
		local landed, headHits = 0, 0
		for _ = 1, pellets do
			local direction = applySpread(unit, spread)
			local result = workspace:Raycast(origin, direction * reach, params)
			if result then
				landed += 1
				if result.Instance.Name == "Head" then
					headHits += 1
				end
			end
		end
		total += landed
		heads += headHits
		worst = math.min(worst, landed)
		best = math.max(best, landed)
		if landed == 0 then
			misses += 1
		end
	end
	return {
		mean = total / trials,
		worst = worst == math.huge and 0 or worst,
		best = best,
		misses = misses,
		heads = heads / trials,
		trials = trials,
		pellets = pellets,
	}
end

local function shotsToKill(perShot, health)
	if perShot <= 0 then
		return 99
	end
	return math.ceil(health / perShot)
end

--------------------------------------------------------------------------------
-- Planted faults
--------------------------------------------------------------------------------

local plantedRun, plantedCaught = 0, 0
local function planted(name, caught, detail)
	plantedRun += 1
	if caught then
		plantedCaught += 1
	end
	out("planted fault %-40s %s%s", name, caught and "CAUGHT" or "MISSED -- THESE NUMBERS PROVE NOTHING",
		detail and (" (" .. detail .. ")") or "")
end

do
	local perfect = { pellets = 8, range = 200 }
	standAt(20)
	local aim = torso.Position
	local tight = volley(perfect, 0, aim, 40)
	planted("a gun with no spread lands every pellet", tight.mean >= 8 - 1e-6,
		string.format("%.2f of 8 pellets at 20 studs, worst %d", tight.mean, tight.worst))

	dummy.Parent = nil
	local empty = volley(perfect, 0, aim, 40)
	dummy.Parent = stage
	planted("with the body gone, nothing lands", empty.mean == 0,
		string.format("%.2f pellets landed on an empty world", empty.mean))
end

--------------------------------------------------------------------------------
-- Every shotgun, every range
--------------------------------------------------------------------------------

local shotguns = {}
for id, def in pairs(WeaponData.Weapons) do
	if (def.pellets or 1) > 1 then
		table.insert(shotguns, id)
	end
end
table.sort(shotguns)

out("--- %d multi-pellet guns x %d ranges x %d trials, chest aim ---", #shotguns, #RANGES, TRIALS)
out("%-22s %-5s %s", "gun", "range", "HIP: mean/worst pellets, damage, shots to kill 100 | ADS: the same")

for _, id in ipairs(shotguns) do
	local def = WeaponData.Get(id)
	local hipSpread = def.spread or 0
	local adsSpread = hipSpread * 0.34
	local lines = {}
	for _, distance in ipairs(RANGES) do
		standAt(distance)
		local aim = torso.Position
		local beyond = distance > (def.range or 200)
		local hip = volley(def, hipSpread, aim, TRIALS)
		local ads = volley(def, adsSpread, aim, TRIALS)
		local hipDamage = hip.mean * def.damage
		local adsDamage = ads.mean * def.damage
		out("%-22s %3d   HIP %4.1f/%d of %d  %5.1f dmg  %2d shots%s | ADS %4.1f/%d  %5.1f dmg  %2d shots%s%s",
			id, distance, hip.mean, hip.worst, hip.pellets, hipDamage, shotsToKill(hipDamage, 100),
			hip.misses > 0 and string.format(" (%d%% whiff)", math.floor(hip.misses / hip.trials * 100 + 0.5)) or "",
			ads.mean, ads.worst, adsDamage, shotsToKill(adsDamage, 100),
			ads.misses > 0 and string.format(" (%d%% whiff)", math.floor(ads.misses / ads.trials * 100 + 0.5)) or "",
			beyond and "  [PAST ITS RANGE: every pellet does nothing]" or "")
		table.insert(lines, string.format("%d:%.1f", distance, hip.mean))
	end
	out("%-22s damage %.1f x %d pellets, spread %.1f deg, range %d, fire rate %.2f/s, mag %d | mean pellets %s",
		id, def.damage, def.pellets, def.spread, def.range, def.fireRate, def.magSize, table.concat(lines, " "))
	task.wait()
end

-- Head aim, at the two ranges where a head hit is a real option, so the "one shot to the head"
-- question has a measured answer rather than a theoretical one.
out("--- head aim: how much of a full-pellet head hit actually happens ---")
for _, id in ipairs(shotguns) do
	local def = WeaponData.Get(id)
	local parts = {}
	for _, distance in ipairs({ 5, 10, 20 }) do
		standAt(distance)
		local shot = volley(def, def.spread or 0, head.Position, TRIALS)
		local damage = (shot.mean - shot.heads) * def.damage + shot.heads * def.damage * (def.headshotMultiplier or 1)
		table.insert(parts, string.format("%d studs: %.1f pellets (%.1f on the head) = %.0f dmg, %d shots",
			distance, shot.mean, shot.heads, damage, shotsToKill(damage, 100)))
	end
	out("%-22s %s", id, table.concat(parts, " | "))
	task.wait()
end

out("planted faults: %d of %d caught (want %d of %d)", plantedCaught, plantedRun, plantedRun, plantedRun)
stage:Destroy()
out("done")
return {}
