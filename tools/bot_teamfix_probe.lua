-- Probe for five bots-tab fixes (COORDINATION.md, 2026-09-22): the under-armed/loadout-weapon
-- loot loop, replacement-bot slot fan-out, BotNav's path-queue cap, the burst-arm first-shot
-- latency, and BotService's HILL_RADIUS being sourced from Shared/GameModes instead of copied.
--
-- No map or loot is built: everything here runs on a bare platform far outside the void, spawned
-- directly through BotService/BotNav's own public API, the same technique tools/bot_probe.lua's
-- S25 uses to fake a team mode (BotService.ModeState / .IsHostile / .SpawnLoadout are the real
-- seams GameMode.lua drives in a live match, so nothing about ModeTeams or GameMode itself is
-- touched or assumed).
--
-- Run with:
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/bot_teamfix_probe.lua -WaitSeconds 300

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_BotFix] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end

local CombatService = mod("CombatService")
mod("DestructibleService") -- wires the glass hooks CombatService expects, as Bootstrap does
local BotService = mod("BotService")
local BotNav = mod("BotNav")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local GameModes = require(Shared:WaitForChild("GameModes"))
local Rarity = require(Shared:WaitForChild("Rarity"))

CombatService.SetEnabled(true)

-- One shared BotService.ModeState hook for every test that needs mode state (only test 5 does);
-- bots not listed here get nil, same as the battle royale.
--
-- SAVED AND RESTORED AT THE END, deliberately. BotService.ModeState's default is a real function
-- (it reads ModeTeams / ModeKingOfTheHill), not nil, and a local plugin's require() gives one
-- BotService per Studio session: an override left in place, or "restored" to nil, stays for every
-- probe that runs after this one in the same process. Restoring nil cost the bot tab a full run
-- (4,937 think crashes, every bot dead). Don't simplify this back to a bare assignment.
local realModeState = BotService.ModeState
local realIsHostile = BotService.IsHostile
local modeStateOf = {}
BotService.ModeState = function(bot)
	return modeStateOf[bot]
end

-- Several unrelated test clusters share one platform. Left on the default (nil -> hostile, per
-- BotService's own fail-open contract), every cluster would see and fight every other one within
-- BotVisionRange (260 studs) and confound every measurement below. Explicit allowlist instead:
-- peaceful unless a pair is named, which only test 3's shooter/target is.
local hostilePairs = {}
BotService.IsHostile = function(a, b)
	local row = hostilePairs[a]
	return row ~= nil and row[b] == true
end
local function setHostile(a, b)
	hostilePairs[a] = hostilePairs[a] or {}
	hostilePairs[a][b] = true
	hostilePairs[b] = hostilePairs[b] or {}
	hostilePairs[b][a] = true
end

--------------------------------------------------------------------------------
-- A bare platform, far outside the map, so nothing here depends on MapGenerator/LootService.
--------------------------------------------------------------------------------

local ARENA = Vector3.new(0, 4500, 0)
local platform = Instance.new("Part")
platform.Name = "BRR_BotFixPlatform"
platform.Anchored = true
platform.Size = Vector3.new(2200, 4, 900)
platform.CFrame = CFrame.new(ARENA - Vector3.new(0, 2, 0))
platform.Material = Enum.Material.Concrete
platform.TopSurface = Enum.SurfaceType.Smooth
platform.Parent = workspace

local function standAt(offset)
	return CFrame.new(ARENA + offset + Vector3.new(0, 3.2, 0))
end

local function rootOf(bot)
	return bot and bot.character and bot.character:FindFirstChild("HumanoidRootPart")
end
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end
local function posOf(bot)
	local root = rootOf(bot)
	return root and root.Position or nil
end
local function spawnBot(cframe)
	local list = BotService.Spawn(1, function()
		return cframe
	end, function() end)
	return list[1]
end

task.wait(1)

--------------------------------------------------------------------------------
-- Test 1: isUnderArmed treats a loadout weapon as sufficient regardless of rarity.
--------------------------------------------------------------------------------

local greenGun = nil
for _, def in pairs(WeaponData.Weapons) do
	if def.rarity == GameModes.GreenRarity and not def.staged then
		greenGun = def
		break
	end
end

local t1 = { ok = true, lines = {} }
local function t1check(label, condition)
	table.insert(t1.lines, string.format("%s %s", condition and "PASS" or "FAIL", label))
	if not condition then
		t1.ok = false
	end
end

t1check(string.format("found a %s weapon in WeaponData (GameModes.GreenRarity)", GameModes.GreenRarity), greenGun ~= nil)

if greenGun and BotService.IsUnderArmed then
	t1check(GameModes.GreenRarity .. " is below the old Rare floor (structural: proves the bug existed)",
		(Rarity.Index[greenGun.rarity] or 0) < (Rarity.Index.Rare or 3))

	local loadoutBot = spawnBot(standAt(Vector3.new(-900, 0, 0)))
	loadoutBot.weapon = greenGun
	loadoutBot.loadoutWeapon = false
	t1check(GameModes.GreenRarity .. " weapon WITHOUT the loadout flag reads under-armed (old behaviour, still true when the flag is off)",
		BotService.IsUnderArmed(loadoutBot) == true)
	loadoutBot.loadoutWeapon = true
	t1check(GameModes.GreenRarity .. " weapon WITH loadoutWeapon=true reads sufficient (the fix)",
		BotService.IsUnderArmed(loadoutBot) == false)

	local rareGun = nil
	for _, def in pairs(WeaponData.Weapons) do
		if def.rarity == "Rare" and not def.staged then
			rareGun = def
			break
		end
	end
	if rareGun then
		local rareBot = spawnBot(standAt(Vector3.new(-900, 0, 20)))
		rareBot.weapon = rareGun
		rareBot.loadoutWeapon = false
		t1check("a genuinely Rare pickup (no loadout flag) still reads sufficient (unrelated to the fix, control)",
			BotService.IsUnderArmed(rareBot) == false)
	end

	local emptyBot = spawnBot(standAt(Vector3.new(-900, 0, 40)))
	t1check("an empty-handed bot still reads under-armed (BR must keep looting)",
		BotService.IsUnderArmed(emptyBot) == true)

	-- End to end through the real spawn path: BotService.SpawnLoadout is the exact seam GameMode.lua
	-- wires (BotService.lua:426 in GameMode.lua). A bot spawned through it should carry
	-- loadoutWeapon = true without the probe touching the field itself.
	BotService.SpawnLoadout = function()
		return greenGun.id, {}
	end
	local realLoadoutBot = spawnBot(standAt(Vector3.new(-900, 0, 60)))
	BotService.SpawnLoadout = nil
	t1check("a bot spawned through the real SpawnLoadout hook gets loadoutWeapon = true",
		realLoadoutBot.loadoutWeapon == true)
	t1check("...and its weapon is the " .. GameModes.GreenRarity .. " gun SpawnLoadout granted",
		realLoadoutBot.weapon ~= nil and realLoadoutBot.weapon.id == greenGun.id)
	if realLoadoutBot.weapon then
		t1check("...and IsUnderArmed reads it as sufficient end to end",
			BotService.IsUnderArmed(realLoadoutBot) == false)
	end
else
	t1check("BotService.IsUnderArmed exists (probe needs the exposed hook)", false)
end

--------------------------------------------------------------------------------
-- Test 2: replacement-bot slots are unique across repeated single-bot Spawn(1, ...) calls,
-- exactly how GameMode.lua's spawnReplacementBot calls it (BotService.lua was `slot = index`,
-- always 1 for a batch of one).
--------------------------------------------------------------------------------

local t2Slots = {}
for i = 1, 6 do
	local bot = spawnBot(standAt(Vector3.new(-700, 0, i * 15)))
	table.insert(t2Slots, bot.slot)
end
local t2Unique = {}
local t2Duplicate = false
for _, slot in ipairs(t2Slots) do
	if t2Unique[slot] then
		t2Duplicate = true
	end
	t2Unique[slot] = true
end
say("test 2 slots from six single-bot Spawn(1,...) calls: %s", table.concat((function()
	local strs = {}
	for _, s in ipairs(t2Slots) do
		table.insert(strs, tostring(s))
	end
	return strs
end)(), ", "))

--------------------------------------------------------------------------------
-- Test 3: burst-arm first-shot latency. An armed, anchored bot facing a stationary dummy should
-- fire close to MatchConfig.BotReactionTime after acquiring it, not a full BotBurstRest later.
--------------------------------------------------------------------------------

local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local realBroadcast = CombatService.BroadcastShot

local t3Shooter = spawnBot(CFrame.lookAt(ARENA + Vector3.new(-500, 3.2, 0), ARENA + Vector3.new(-500, 3.2, 50)))
rootOf(t3Shooter).Anchored = true
t3Shooter.weapon = WeaponData.Get("CrocodiloRifle")
local t3Target = spawnBot(CFrame.new(ARENA + Vector3.new(-500, 3.2, 50)))
rootOf(t3Target).Anchored = true
setHostile(t3Shooter, t3Target)

local t3ShotsBy = {}
CombatService.BroadcastShot = function(shooter, origin, endPoints, rarity)
	if shooter == t3Shooter and not t3ShotsBy[shooter] then
		t3ShotsBy[shooter] = os.clock()
	end
	return realBroadcast(shooter, origin, endPoints, rarity)
end

--------------------------------------------------------------------------------
-- Test 4: BotNav path-queue throughput at a realistic roster size (MatchConfig.BotFillTarget = 50).
--------------------------------------------------------------------------------

local t4Bots = {}
for i = 1, 30 do
	local bot = spawnBot(standAt(Vector3.new(200 + (i % 6) * 14, 0, math.floor(i / 6) * 14 - 40)))
	table.insert(t4Bots, bot)
end
local t4Goal = ARENA + Vector3.new(200, 0, 400)

--------------------------------------------------------------------------------
-- Test 5: HILL_RADIUS is read from Shared/GameModes, not a second hardcoded copy. Fake a KOTH
-- "holding" bot (state.holder == state.team) so modeObjective returns hill + ring and the bot
-- settles on the ring and holds; its distance from the hill centre should converge on
-- GameModes.Modes.KingOfTheHill.hillRadius * 0.55 (BotService's HILL_SPREAD), which only holds if
-- BotService's ring radius really is GameModes' number and not an independent copy that happens to
-- agree with it today.
--------------------------------------------------------------------------------

local t5HillCenter = ARENA + Vector3.new(900, 0, 0)
local t5Bot = spawnBot(standAt(Vector3.new(900, 0, -60)))
modeStateOf[t5Bot] = { team = 1, hill = t5HillCenter, occupancy = { 1, 0 }, holder = 1, arena = t5HillCenter }
local t5ExpectedRadius = (GameModes.Modes.KingOfTheHill and GameModes.Modes.KingOfTheHill.hillRadius or 28) * 0.55

--------------------------------------------------------------------------------
-- Run: start thinking, drive test 4's burst, sample for 30s.
--------------------------------------------------------------------------------

BotService.Start()
local runStart = os.clock()

for _, bot in ipairs(t4Bots) do
	BotNav.Request(bot, t4Goal, BotNav.Priority.Wander)
end
local t4RequestedAt = os.clock()
local t4StatsBefore = table.clone(BotNav.Stats)

local t4AllServedAt = nil
local t3AcquiredAt = nil

for _ = 1, 220 do -- ~33s at 0.15s steps
	task.wait(0.15)

	if not t3AcquiredAt and t3Shooter.acquiredAt and t3Shooter.acquiredAt > 0 then
		t3AcquiredAt = t3Shooter.acquiredAt
	end

	if not t4AllServedAt then
		local pending = 0
		for _, bot in ipairs(t4Bots) do
			if BotNav.IsPending(bot) then
				pending += 1
			end
		end
		if pending == 0 then
			t4AllServedAt = os.clock()
		end
	end
end

local t4StatsAfter = table.clone(BotNav.Stats)
local elapsed = os.clock() - runStart

local t5Pos = posOf(t5Bot)
local t5Distance = t5Pos and flat(t5Pos - t5HillCenter).Magnitude or nil

--------------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------------

say("================ RESULTS (ran %.0fs) ================", elapsed)

say("-- Test 1: under-armed / loadout weapon --")
for _, line in ipairs(t1.lines) do
	say("  %s", line)
end
say("  test 1 overall: %s", t1.ok and "PASS" or "FAIL")

say("-- Test 2: replacement-bot slot fan-out --")
say("  %s (want: 6 distinct values)", t2Duplicate and "FAIL: duplicate slot seen" or "PASS: all six slots distinct")

say("-- Test 3: burst-arm first-shot latency --")
if t3AcquiredAt and t3ShotsBy[t3Shooter] then
	local latency = t3ShotsBy[t3Shooter] - t3AcquiredAt
	say("  acquired at +%.2fs, first shot at +%.2fs -> latency %.2fs (configured BotReactionTime %.2fs, old bug measured ~1.25s)",
		t3AcquiredAt - runStart, t3ShotsBy[t3Shooter] - runStart, latency, MatchConfig.BotReactionTime)
	say("  %s (want latency within ~0.3s of BotReactionTime, well under the old ~1.25s)",
		latency < MatchConfig.BotReactionTime + 0.35 and "PASS" or "FAIL")
else
	say("  FAIL: never acquired a target or never fired (acquiredAt=%s, shot=%s)",
		tostring(t3AcquiredAt), tostring(t3ShotsBy[t3Shooter]))
end

say("-- Test 4: BotNav path-queue throughput (MAX_CONCURRENT_PATHS, 30 bots, 1 burst) --")
local function delta(key)
	return (t4StatsAfter[key] or 0) - (t4StatsBefore[key] or 0)
end
say("  requested %d paths at once; queuePeak %d; queueWaitMax %.2fs; %d ok, %d failed; avg compute %.0f ms",
	delta("pathRequests"), t4StatsAfter.queuePeak or -1, t4StatsAfter.queueWaitMax or -1,
	delta("pathOk"), delta("pathFail"),
	1000 * delta("pathTime") / math.max(1, delta("pathOk") + delta("pathFail")))
if t4AllServedAt then
	say("  all 30 requests cleared (computed or superseded) %.2fs after the burst was issued",
		t4AllServedAt - t4RequestedAt)
else
	say("  requests STILL pending after the full sample window (%.0fs)", elapsed)
end

say("-- Test 5: HILL_RADIUS sourced from GameModes --")
say("  GameModes.Modes.KingOfTheHill.hillRadius = %s, expected ring distance (x HILL_SPREAD 0.55) = %.1f studs",
	tostring(GameModes.Modes.KingOfTheHill and GameModes.Modes.KingOfTheHill.hillRadius), t5ExpectedRadius)
if t5Distance then
	say("  bot settled %.1f studs from hill centre (branch=%s)", t5Distance, tostring(t5Bot.branch))
	-- modeObjective's "hold" branch stops as soon as the bot is within 6 studs of the ring point,
	-- not exactly on it, so the tolerance here is that 6 plus a little slack for the sample timing.
	say("  %s (want within ~8 studs of %.1f)",
		math.abs(t5Distance - t5ExpectedRadius) < 8 and "PASS" or "FAIL", t5ExpectedRadius)
else
	say("  FAIL: bot has no position (never spawned or died)")
end

-- Put the seams back to what they WERE (see the note where they are overridden above).
BotService.ModeState = realModeState
BotService.IsHostile = realIsHostile

-- The harness keeps the last 5,000 output lines. More than that (an error storm, say) evicts the
-- earliest results, and their absence reads as "not printed". Say so on the last line instead.
if type(lines) == "table" and #lines >= 4990 then
	say("LOG TRUNCATED: %d lines kept of more than that, earliest results evicted -- results VOID, fix the spam and re-run", #lines)
end

say("================ END RESULTS ================")
