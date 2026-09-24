-- Bot archetypes A/B in Studio (Oliver, 2026-09-24: bots with "different strategies in fighting and
-- looting", that "react differently depending on the gun they have").
--
-- Run with: runtest.ps1 -Probe tools/bot_archetype_probe.lua -WaitSeconds 360
--
-- The Studio half of tools/bot_archetype_sim.py: the same scenarios on the real map, real pathfinding,
-- real physics, so the numbers the sim predicts can be read off a live server. Everything prints as
-- [BRR_BotArch] lines. Aim is never dialled (BotAccuracy*, BotDamageScale, BotBurstRest stay).
--
--   DUELS     each archetype (rifle) against a Rusher (rifle), 70 studs apart, one pair a pad:
--             distance fought at, share of thinks in cover / hidden, first shot, who won
--   CLASSES   a Rusher with each gun class against a tough anchored dummy at 90 studs: the distance
--             it settles at (shotgun ~7, SMG ~8, rifle ~33, DMR ~70, sniper ~100), rounds a second
--   FLANK     Flanker vs Rusher vs a tough dummy: the largest angle worked round it in 20 s
--   THIRD     two tough Rushers fighting, an Opportunist / a Rusher watching from 60 studs: first shot
--   AVOID     a Survivor / a Rusher 85 studs from a passive dummy: shots fired
--   FLEE      an unarmed Survivor / Rusher under fire, with a wall and a smoke: walls and smokes used
--
-- Read against the sim's "after" table. Differences to expect: real routes (the sim walks straight
-- lines), the real map's cover, and the timed first shot (the sim's think loop has none). What the
-- sim cannot judge and this can: does it LOOK like six different players? Watch a DUEL pad.

local TRIALS = 2
local ROUND_SECONDS = 30

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_BotArch] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)
say("run mode: IsRunning %s", tostring(RunService:IsRunning()))

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end

local MapGenerator = mod("MapGenerator")
local LootService = mod("LootService")
local CombatService = mod("CombatService")
mod("DestructibleService")
local BotService = mod("BotService")
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))

if not BotService.AssignArchetype then
	say("FAIL this build has no BotService.AssignArchetype: the archetype foundation is not in the tree")
	return
end

--------------------------------------------------------------------------------
-- Shot and hit ledger (as tools/bot_aggression_ab.lua)
--------------------------------------------------------------------------------

local shotsBy, hitsBy, firstShotAt, distanceSum = {}, {}, {}, {}
local realBroadcast = CombatService.BroadcastShot
CombatService.BroadcastShot = function(shooter, origin, endPoints, rarity)
	if shooter and shooter.isBot and #endPoints == 1 then
		shotsBy[shooter] = (shotsBy[shooter] or 0) + 1
		firstShotAt[shooter] = firstShotAt[shooter] or tick()
		local targetRoot = shooter.target and shooter.target.character and shooter.target.character:FindFirstChild("HumanoidRootPart")
		local root = shooter.character and shooter.character:FindFirstChild("HumanoidRootPart")
		if targetRoot and root then
			distanceSum[shooter] = (distanceSum[shooter] or 0) + (targetRoot.Position - root.Position).Magnitude
		end
	end
	return realBroadcast(shooter, origin, endPoints, rarity)
end
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	local dealt = realDeal(attacker, victim, amount, weaponId, headshot)
	if attacker and (dealt or 0) > 0 then
		hitsBy[attacker] = (hitsBy[attacker] or 0) + 1
	end
	return dealt
end

--------------------------------------------------------------------------------
-- Helpers (as tools/bot_probe.lua)
--------------------------------------------------------------------------------

local function rootOf(bot)
	return bot and bot.character and bot.character:FindFirstChild("HumanoidRootPart")
end

local function alive(bot)
	return bot and bot.humanoid and bot.humanoid.Health > 0 and bot.character and bot.character.Parent ~= nil
end

local function spawnBot(cframe, archetype)
	local bot = BotService.Spawn(1, function()
		return cframe
	end, function() end)[1]
	if bot and archetype then
		BotService.AssignArchetype(bot, archetype)
	end
	return bot
end

local function spawnDummy(cframe, tough)
	local bot = spawnBot(cframe, "Anchor")
	local root = rootOf(bot)
	if root then
		root.Anchored = true
	end
	if tough then
		bot.humanoid.MaxHealth = 100000
		bot.humanoid.Health = 100000
	end
	return bot
end

local function arm(bot, weaponId)
	bot.weapon = WeaponData.Get(weaponId)
	bot.loadoutWeapon = true
end

local arena = nil
local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Concrete
	if not arena then
		arena = Instance.new("Model")
		arena.Name = "BRR_BotArchArena"
		arena.Parent = workspace:WaitForChild("Map")
	end
	part.Parent = arena
	return part
end

local ARENA_Y, ARENA_X, PAD_SPACING = 1600, 3400, 700
local padIndex = 0
local function pad()
	padIndex += 1
	local c = Vector3.new(ARENA_X + padIndex * PAD_SPACING, ARENA_Y, 3400)
	block("Pad" .. padIndex, Vector3.new(260, 2, 260), CFrame.new(c - Vector3.new(0, 1, 0)))
	-- The duel map's cover, as the sim lays it out.
	for _, w in ipairs({ { -14, 22, 6, 1.5 }, { 14, 22, 6, 1.5 }, { -14, 58, 6, 1.5 }, { 14, 58, 6, 1.5 }, { 0, 40, 4, 4 }, { -26, 40, 1.5, 8 }, { 26, 40, 1.5, 8 } }) do
		block("Cover", Vector3.new(w[3], 5, w[4]), CFrame.new(c + Vector3.new(w[1], 2.5, w[2] - 40)))
	end
	return c
end
local function facing(c, offset, toward)
	local at = c + offset + Vector3.new(0, 3.2, 0)
	return CFrame.lookAt(at, c + toward + Vector3.new(0, 3.2, 0))
end

local function mean(list)
	if #list == 0 then
		return nil
	end
	local sum = 0
	for _, v in ipairs(list) do
		sum += v
	end
	return sum / #list
end
local function fmt(v, unit)
	return v and string.format("%.2f%s", v, unit or "") or "none"
end
local function bearing(from, to)
	local d = to.Position - from.Position
	return math.atan2(d.Z, d.X)
end

--------------------------------------------------------------------------------
-- Map
--------------------------------------------------------------------------------

say("building map SahurSprings")
local info = MapGenerator.Build("SahurSprings")
LootService.Populate(info)
task.wait(4)
CombatService.SetEnabled(true)

--------------------------------------------------------------------------------
-- The rounds
--------------------------------------------------------------------------------

local ARCHES = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }
local CLASSES = { { "shotgun", "TralalaShotgun" }, { "smg", "RotSMG" }, { "rifle", "CrocodiloRifle" }, { "dmr", "GrassToucherDMR" }, { "sniper", "LarilaSniper" }, { "lmg", "CameloLMG" } }

local duels, classes, flanks, thirds, avoids, flees = {}, {}, {}, {}, {}, {}

for _, arch in ipairs(ARCHES) do
	for _ = 1, TRIALS do
		local c = pad()
		local a = spawnBot(facing(c, Vector3.new(0, 0, -35), Vector3.new(0, 0, 35)), arch)
		local b = spawnBot(facing(c, Vector3.new(0, 0, 35), Vector3.new(0, 0, -35)), "Rusher")
		arm(a, "CrocodiloRifle")
		arm(b, "CrocodiloRifle")
		table.insert(duels, { arch = arch, a = a, b = b, fight = 0, cover = 0, hide = 0 })
	end
end
for _, class in ipairs(CLASSES) do
	local c = pad()
	local bot = spawnBot(facing(c, Vector3.new(0, 0, -45), Vector3.new(0, 0, 45)), "Rusher")
	arm(bot, class[2])
	local dummy = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, 45)), true)
	table.insert(classes, { class = class[1], bot = bot, dummy = dummy })
end
for _, arch in ipairs({ "Flanker", "Rusher" }) do
	local c = pad()
	local bot = spawnBot(facing(c, Vector3.new(0, 0, -25), Vector3.new(0, 0, 25)), arch)
	arm(bot, "CrocodiloRifle")
	local dummy = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, 25)), true)
	table.insert(flanks, { arch = arch, bot = bot, dummy = dummy, first = nil, max = 0 })
end
for _, arch in ipairs({ "Opportunist", "Rusher" }) do
	local c = pad()
	local a = spawnBot(facing(c, Vector3.new(-14, 0, 30), Vector3.new(14, 0, 30)), "Rusher")
	local b = spawnBot(facing(c, Vector3.new(14, 0, 30), Vector3.new(-14, 0, 30)), "Rusher")
	arm(a, "CrocodiloRifle")
	arm(b, "CrocodiloRifle")
	for _, t in ipairs({ a, b }) do
		t.humanoid.MaxHealth = 300
		t.humanoid.Health = 300
	end
	table.insert(thirds, { arch = arch, c = c, a = a, b = b, observer = nil })
end
for _, arch in ipairs({ "Survivor", "Rusher" }) do
	local c = pad()
	local bot = spawnBot(facing(c, Vector3.new(0, 0, -42), Vector3.new(0, 0, 43)), arch)
	arm(bot, "CrocodiloRifle")
	local dummy = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, 43)), true)
	table.insert(avoids, { arch = arch, bot = bot, dummy = dummy })
end
for _, arch in ipairs({ "Survivor", "Rusher" }) do
	local c = pad()
	local bot = spawnBot(facing(c, Vector3.new(0, 0, -20), Vector3.new(0, 0, 20)), arch)
	bot.defenses = 1
	bot.throwables.LowkeyLatte = 1
	local shooter = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, 20)), true)
	arm(shooter, "SahurPistol")
	table.insert(flees, { arch = arch, bot = bot, shooter = shooter, walls = 0, smokes = 0 })
end

task.wait(2)
local statsBefore = {}
for k, v in pairs(BotService.Stats) do
	statsBefore[k] = v
end
BotService.Start()
local start = tick()

-- Watch, four times a second.
while tick() - start < ROUND_SECONDS do
	task.wait(0.25)
	local elapsed = tick() - start
	for _, d in ipairs(duels) do
		if alive(d.a) and d.a.branch == "fight" then
			d.fight += 1
			local state = d.a.fightState or "engage"
			if (d.a.coverUntil and os.clock() < d.a.coverUntil) or state == "cover" or state == "peekShoot" or state == "thirdParty" then
				d.cover += 1
			end
			if state == "peekHide" then
				d.hide += 1
			end
		end
	end
	for _, f in ipairs(flanks) do
		local root, target = rootOf(f.bot), rootOf(f.dummy)
		if root and target and f.bot.branch == "fight" then
			local angle = bearing(target, root)
			f.first = f.first or angle
			local diff = math.abs(angle - f.first)
			if diff > math.pi then
				diff = math.pi * 2 - diff
			end
			f.max = math.max(f.max, math.deg(diff))
		end
	end
	for _, t in ipairs(thirds) do
		if not t.observer and elapsed >= 1.5 then
			t.observer = spawnBot(facing(t.c, Vector3.new(0, 0, -30), Vector3.new(0, 0, 30)), t.arch)
			arm(t.observer, "CrocodiloRifle")
			t.arrivedAt = tick()
		end
	end
	for _, f in ipairs(flees) do
		-- The dummy plinks its target every second (damage only), as the sim's shooter does.
		if alive(f.bot) and alive(f.shooter) and elapsed >= (f.nextShot or 0) then
			f.nextShot = elapsed + 1
			CombatService.DealDamage(f.shooter, f.bot, 6, "SahurPistol", false)
		end
		local walls = 0
		for model in pairs(f.bot.ownStructures or {}) do
			if model.Parent then
				walls += 1
			end
		end
		f.walls = math.max(f.walls, walls)
	end
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

local stats = BotService.Stats
local function delta(key)
	return (stats[key] or 0) - (statsBefore[key] or 0)
end

say("DUELS vs a Rusher (rifles), %d s: archetype  distance / cover share / hidden share / first shot / won", ROUND_SECONDS)
for _, arch in ipairs(ARCHES) do
	local dist, cover, hide, first, won, n = {}, 0, 0, {}, 0, 0
	for _, d in ipairs(duels) do
		if d.arch == arch then
			n += 1
			local shots = shotsBy[d.a] or 0
			if shots > 0 then
				table.insert(dist, (distanceSum[d.a] or 0) / shots)
			end
			cover += d.cover
			hide += d.hide
			if firstShotAt[d.a] then
				table.insert(first, firstShotAt[d.a] - start)
			end
			if alive(d.a) and not alive(d.b) then
				won += 1
			end
		end
	end
	local fight = 0
	for _, d in ipairs(duels) do
		if d.arch == arch then
			fight += d.fight
		end
	end
	say("  %-12s %s studs  cover %.2f  hide %.2f  first shot %s  won %d/%d", arch, fmt(mean(dist), ""), cover / math.max(1, fight),
		hide / math.max(1, fight), fmt(mean(first), " s"), won, n)
end
say("CLASSES (Rusher) vs an anchored tough dummy 90 studs off: distance settled at / rounds a second / hits per shot")
for _, c in ipairs(classes) do
	local shots = shotsBy[c.bot] or 0
	say("  %-9s %s studs  %.2f rounds/s  hits/shot %s", c.class, shots > 0 and fmt((distanceSum[c.bot] or 0) / shots, "") or "none",
		shots / ROUND_SECONDS, shots > 0 and fmt((hitsBy[c.bot] or 0) / shots, "") or "none")
end
for _, f in ipairs(flanks) do
	say("FLANK %s: worked %.0f degrees round the target", f.arch, f.max)
end
for _, t in ipairs(thirds) do
	local first = t.observer and firstShotAt[t.observer]
	say("THIRD %s: first shot %s after arriving (held back %d thinks in total this run)", t.arch,
		first and fmt(first - t.arrivedAt, " s") or "never", delta("thirdPartyHolds"))
end
for _, a in ipairs(avoids) do
	say("AVOID %s: %d shots at a passive target 85 studs off", a.arch, shotsBy[a.bot] or 0)
end
for _, f in ipairs(flees) do
	say("FLEE %s: walls standing %d, health %.0f", f.arch, f.walls, f.bot.humanoid.Health)
end
say("STATS this run: peeks %d, repositions %d, flank moves %d, focus fire %d, third-party holds %d, avoided %d, stickies %d, "
	.. "walls fortify %d block %d cross %d pushed %d, refused for a teammate: walls %d frags %d",
	delta("peeks"), delta("repositions"), delta("flankMoves"), delta("focusFire"), delta("thirdPartyHolds"), delta("avoided"),
	delta("throwsSticky"), delta("buildsFortify"), delta("buildsBlock"), delta("buildsCross"), delta("buildsPushed"),
	delta("buildsRefusedFriendly"), delta("throwsRefusedFriendly"))
say("archetypes dealt: %s", (function()
	local counts = {}
	for _, bot in ipairs(BotService.GetAll()) do
		local a = BotService.ArchetypeOf(bot)
		counts[a.name] = (counts[a.name] or 0) + 1
	end
	local parts = {}
	for name, n in pairs(counts) do
		table.insert(parts, name .. " " .. n)
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end)())

BotService.Clear()
if arena then
	arena:Destroy()
end
say("done")
