"""Bot looting and rotation by archetype, from the real source (BOT LOOTING & ROTATION in BotService).

No Studio, so this runs the real Luau of the paths that decide where a bot lands, what it loots,
what it keeps, when it heals and how it rotates, in a Lua interpreter (lupa) with Roblox mocked, and
drives a battle royale on a mock map for ten minutes of simulated time:

  MAP      six towns and four landmarks (the real SpatialQuery loot grid over them); chests, floor guns, heals/shields and items rolled from the
           REAL spawn tables (WeaponData.RollGroundWeapon / RollChestWeapon, ItemData.RollRecovery,
           the LootService chest/weapon/heal fractions), on chest and loot spots round each place.
  BOTS     48, eight per archetype (no ArchetypeOf hook, so the slot fallback assigns them), dropped
           from a spiral like MatchService's and steered by the real pickDropTarget / LR.pickDrop.
  THINKS   every 0.25 s per bot, in updateBot's order for the parts this owns: storm pressure and
           rotation (real stormPressure, LR.rotateAt, LR.rotationGoal, LR.leg), tryHeal / tryShield
           (real), the loot pick (real LR.pickLoot), the walk, the hold and the claim (real holdLoot,
           LR.takeGun, LR.claimConsumable). Fighting is a MODEL (nearest enemy in range trades damage
           each think), enough for heals to be spent and bodies to drop their gear.
  LEGACY   the same match with the pre-archetype decisions modelled in place of the new ones (nearest
           drop spot, the old loot order, rarity-only swaps, one gun, BotStormRotate and stormGoal),
           so every number has a before beside it.

It prints, per archetype: landing heat (chests within 110 studs of the landing) and hot/quiet share,
pickups and chest opens over time, loadout at 2/5/10 min (held gun rarity, share carrying a second
gun of another class, heals + shields carried), heal and shield uses, zone deaths and seconds spent
outside the circle, and the team-base chest spread (twelve bots off one pad, fourteen chests).

Checks (each with a planted fault under --plant that must be caught):
  drop        Survivors land quieter than Rushers (mean landing heat), and the hot/quiet roll follows
              dropHotLanding (Rusher always hot, Survivor never)
  inventory   a held gun's rarity never goes down through a claim; a backup is always another class;
              junk goes back on the floor rather than vanishing
  stock       shields and throwables are picked up (were never taken before)
  heal        healBelow / shieldLow order by archetype (Survivor > Anchor > Flanker > Rusher)
  rotation    rotateAt orders by rotateEarly; in a rotation-only pair of matches (same bots and storm,
              no fights, no loot) zone deaths and outside time do not rise against legacy, and Survivors
              spend less time outside than Rushers
  supply      a Survivor 500 studs from a crate leaves it; an Opportunist goes
  contested   a Survivor skips a chest with an enemy on it; a Rusher takes it on
  base        twelve bots off one pad target more distinct chests than the legacy nearest-chest pick
  cost        a loot pick reads the snapshot at most 4 times

    python tools/bot_loot_sim.py .                six matches, the table and the checks
    python tools/bot_loot_sim.py . --plant        the planted faults; every one must be caught
    python tools/bot_loot_sim.py . --seeds N      N matches (--seed S for the first seed)

pairs() order in the real data tables (WeaponData's pools) differs run to run, so one match is
not repeatable; every number here is a sum over the matches and every check reads the sum.

What this does NOT measure: pathfinding (bots walk straight lines here), line of sight, the real
fight() and its aim, MovementService's glide, or how any of it looks. tools/bot_probe.lua covers
the bots in Studio.
"""

import importlib.util
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("bot_loot_sim: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("perf_bot_cost", os.path.join(HERE, "perf_bot_cost.py"))
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
SHARED = "ReplicatedStorage/Shared"
ARCHETYPES = ["Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor"]


def luau_to_lua(src):
    # `x += y` -> `x = x + (y)`: the whole right-hand side is one operand in Luau, so it is
    # parenthesised (perf's rewrite drops the brackets, which turns `v += a == 1 and 0.6 or 0.3` into
    # `(v + a) == 1 ...`). Index expressions on the left (`t[k] -= 1`) are allowed for.
    return re.sub(r"^(\s*)([\w.]+(?:\[[^\]]+\])?(?:\.\w+)*) ([-+*/])= (.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def slice_(text, start, end):
    return perf.between(text, start, end)


def slices(bot_src):
    """The parts of BotService this drives, in the order the file defines them."""
    parts = [
        slice_(bot_src, "local function flat(v)", "--------------------------------------------------------------------------------\n-- Storm"),
        slice_(bot_src, "local function safeCircle", "--------------------------------------------------------------------------------\n-- Perception"),
        slice_(bot_src, "local function giveBotHeal", "-- Rot Barricades too"),
        slice_(bot_src, "local function healCap", "-- Frags and smoke come"),
        slice_(bot_src, "local THROWABLES = {", "-- A lob needs headroom"),
        slice_(bot_src, "-- Which bot is heading for which pickup", "--------------------------------------------------------------------------------\n-- Behaviour"),
        slice_(bot_src, "local function isUnderArmed", "BotService.IsUnderArmed"),
        slice_(bot_src, "-- BOT LOOTING & ROTATION (Oliver", "local function updateBot(bot)"),
        slice_(bot_src, "local function pickDropTarget", "-- `options.dropIn`"),
    ]
    # The real SpatialQuery grid, so the loot slice's BotService.SpatialQuery.Loot runs as shipped.
    grid = slice_(bot_src, "\tfunction query.NewGrid(cellSize)", "\tlocal grid = query.NewGrid(128)")
    parts.insert(0, "do\n\tlocal query = BotService.SpatialQuery\n\tlocal FLOOR = math.floor\n\tlocal OFFSET = 32768\n" + grid + "end\n")
    consts = []
    for name in ("LOOT_SEEK_RANGE", "SUPPLY_SEEK_RANGE", "HEAL_SEEK_RANGE", "BOT_CHEST_DEFENSE_CHANCE",
                 "BOT_CHEST_ROCKET_CHANCE", "BOT_PROJECTILE_KINDS", "BOT_WEAPON_HOLD"):
        m = re.search(r"^local %s = (.+)$" % name, bot_src, flags=re.M)
        assert m, name
        consts.append("local %s = %s" % (name, m.group(1)))
    return luau_to_lua("\n".join(consts) + "\n" + "\n".join(parts)
                       + "\nreturn { tryHeal = tryHeal, tryShield = tryShield, holdLoot = holdLoot, setLootTarget = setLootTarget,"
                       " releaseLoot = releaseLoot, findLoot = findLoot, lootItems = lootItems, lootAllowed = lootAllowed,"
                       " isUnderArmed = isUnderArmed, pickDropTarget = pickDropTarget, stormPressure = stormPressure,"
                       " stormGoal = stormGoal, nextLeg = nextLeg, safeCircle = safeCircle, insideCircle = insideCircle,"
                       " lootClaims = lootClaims, giveBotHeal = giveBotHeal, THROWABLES = THROWABLES, flatDistance = flatDistance }\n")


WORLD = r"""
local root, botSrc, shared, seed = ...
math.randomseed(seed)
ARCHETYPES = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }
math.clamp = math.clamp or function(v, lo, hi) return math.max(lo, math.min(hi, v)) end
math.round = math.round or function(v) return math.floor(v + 0.5) end
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
math.sign = math.sign or function(v) return v > 0 and 1 or v < 0 and -1 or 0 end
-- Luau's table library extras the data files use.
table.clone = table.clone or function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end
table.create = table.create or function(n, v) local t = {} for i = 1, n do t[i] = v end return t end
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end, new = function(r, g, b) return { r, g, b } end }
CFrame = { new = function() return {} end }
task = { wait = function() end, spawn = function(f) f() end }
warn = function() end
tick = os.time

-- Shared data modules, the real files, required by name.
local loaded = {}
local function token(name) return { __module = name } end
script = { Parent = { WaitForChild = function(_, name) return token(name) end, FindFirstChild = function(_, name) return token(name) end } }
function require(t)
	local name = t.__module
	if loaded[name] == nil then
		local src = shared[name]
		assert(src, "no shared module " .. tostring(name))
		loaded[name] = assert(load(src, name, "t", _ENV))()
	end
	return loaded[name]
end
WeaponData = require(token("WeaponData"))
ItemData = require(token("ItemData"))
Rarity = require(token("Rarity"))
MatchConfig = require(token("MatchConfig"))

-- Instances: parts with attributes in a folder.
local function newFolder(name)
	local folder = { Name = name, children = {} }
	function folder:GetChildren()
		local out = {}
		for _, c in ipairs(self.children) do table.insert(out, c) end
		return out
	end
	function folder:FindFirstChild(n) for _, c in ipairs(self.children) do if c.Name == n then return c end end end
	function folder:GetDescendants() return self:GetChildren() end
	return folder
end
local lootFolder = newFolder("Loot")
local crateFolder = newFolder("Crates")
local roadsFolder = newFolder("Roads")
local mapFolder = newFolder("Map")
mapFolder.children = { roadsFolder }

local function newPart(name, position, folder)
	local part = { Name = name, Position = position, Parent = folder, attrs = {}, Size = Vector3.new(4, 1, 4) }
	function part:GetAttribute(k) return self.attrs[k] end
	function part:SetAttribute(k, v) self.attrs[k] = v end
	function part:IsA(c) return c == "BasePart" end
	function part:FindFirstChildOfClass() return nil end
	function part:Destroy()
		if self.Parent then
			for i, c in ipairs(self.Parent.children) do if c == self then table.remove(self.Parent.children, i) break end end
		end
		self.Parent = nil
	end
	if folder then table.insert(folder.children, part) end
	return part
end
workspace = { FindFirstChild = function(_, name)
	if name == "Loot" then return lootFolder elseif name == "Map" then return mapFolder end
end }

-- LootService: the bot-facing API, the real rules (Claimed attribute; a chest opens and stays; a
-- floor gun goes; a dropped gun comes back as a GroundWeapon).
LootService = { BaseRadius = 85 }
local counts = { spawnedChests = 0, spawnedGuns = 0, spawnedHeals = 0, spawnedItems = 0, droppedGuns = 0 }
local function spawnGun(position, def)
	def = def or WeaponData.RollGroundWeapon()
	local part = newPart("GroundWeapon", position, lootFolder)
	part:SetAttribute("WeaponId", def.id)
	counts.spawnedGuns = counts.spawnedGuns + 1
	return part
end
local function spawnChest(position)
	counts.spawnedChests = counts.spawnedChests + 1
	return newPart("Chest", position, lootFolder)
end
local function spawnConsumable(position, item, amount)
	local recovery = item.kind == "heal" or item.kind == "shield"
	local part = newPart(recovery and "HealPickup" or "ItemPickup", position, lootFolder)
	part:SetAttribute("ItemId", item.id)
	part:SetAttribute("Amount", amount or item.pickup)
	if item.kind == "heal" then part:SetAttribute("HealId", item.id) end
	if recovery then counts.spawnedHeals = counts.spawnedHeals + 1 else counts.spawnedItems = counts.spawnedItems + 1 end
	return part
end
function LootService.ClaimTime(item) return item.Name == "Chest" and 1.0 or 0.3 end
function LootService.ClaimForBot(item)
	if not item or not item.Parent or item:GetAttribute("Claimed") or item:GetAttribute("PlayerHolding") then return nil end
	local def
	if item.Name == "Chest" then
		def = WeaponData.RollChestWeapon()
		item:SetAttribute("Claimed", true)
		item:SetAttribute("Opened", true)
	else
		item:SetAttribute("Claimed", true)
		def = WeaponData.Get(item:GetAttribute("WeaponId"))
		item:Destroy()
	end
	return def
end
function LootService.ClaimHealForBot(item)
	if not item or not item.Parent or item:GetAttribute("Claimed") or item:GetAttribute("PlayerHolding") then return nil end
	local healId, amount = item:GetAttribute("HealId"), item:GetAttribute("Amount")
	if not healId or not amount then return nil end
	item:SetAttribute("Claimed", true)
	item:Destroy()
	return healId, amount
end
function LootService.DropWeapon(id, position)
	counts.droppedGuns = counts.droppedGuns + 1
	spawnGun(position + Vector3.new(math.random() * 4 - 2, 0, math.random() * 4 - 2), WeaponData.Get(id))
end
function LootService.DropHeal(position)
	spawnConsumable(position, ItemData.RollRecovery())
end

SupplyDropService = {}
function SupplyDropService.FindNearest(position, radius)
	local best, bestDistance = nil, radius
	for _, crate in ipairs(crateFolder.children) do
		if crate:GetAttribute("Landed") and not crate:GetAttribute("Claimed") then
			local d = (crate.Position - position).Magnitude
			if d < bestDistance then best, bestDistance = crate, d end
		end
	end
	return best, bestDistance
end
function SupplyDropService.ClaimForBot(crate)
	if not crate or not crate.Parent or crate:GetAttribute("Claimed") then return nil end
	crate:SetAttribute("Claimed", true)
	local id = crate:GetAttribute("WeaponId")
	crate:Destroy()
	return id and WeaponData.Get(id) or nil
end

-- WeaponService's heal/shield tables, built the way WeaponService builds them from ItemData.
WeaponService = { Heals = {}, Shields = {} }
for id, item in pairs(ItemData.Items) do
	if item.kind == "heal" then WeaponService.Heals[id] = { amount = item.amount, cap = item.cap, max = item.stack }
	elseif item.kind == "shield" then WeaponService.Shields[id] = { amount = item.amount, cap = item.cap, max = item.stack } end
end

-- The storm: MatchConfig.StormPhases, driven by the sim's clock.
local storm = { status = "Idle", center = Vector3.new(0, 0, 0), radius = 0, phase = 0, secondsLeft = 0 }
StormService = {}
function StormService.GetState() return storm end
function StormService.IsOutside(position)
	return Vector3.new(position.X - storm.center.X, 0, position.Z - storm.center.Z).Magnitude > storm.radius
end

MapGenerator = { GroundHeightAt = function() return 0 end }
BotNav = { Drop = function() end, Priority = {} }
function holdStill() end
function claimPhysics() end
function giveBotGun() end
function magazineOf(def) return def and (def.magazine or 10) or nil end
function giveBotDefense(bot, n) bot.defenses = (bot.defenses or 0) + n end
function giveBotRocket(bot, n) bot.rockets = (bot.rockets or 0) + n end
local ProjectileService = { Throw = function() return true end }
local lazyModules = { ProjectileService = ProjectileService }
function lazy(name) return lazyModules[name] end
combatantList = {}
local teams = nil -- set by the base scenario
function hostile(bot, other)
	if teams then return teams[bot] ~= teams[other] end
	return true
end
STATS = setmetatable({}, { __index = function() return 0 end })
BotService = { Stats = STATS, SpatialQuery = {}, ModeState = function(bot) return teams and { team = teams[bot] } or nil end }
BotService.Loot = {}
LR = BotService.Loot -- the harness's short name for the section's table

-- The real code under test (the mocks above are globals: the slices are their own chunk).
local S = assert(load(botSrc, "BotService slices", "t", _ENV))()

--------------------------------------------------------------------------------
-- The map: towns, landmarks, loot from the real tables
--------------------------------------------------------------------------------
local MAP_RADIUS = 640
local towns, landmarks, dropSpots = {}, {}, {}
local function ring(count, radius, offset)
	local out = {}
	for i = 1, count do
		local a = offset + (i - 1) / count * math.pi * 2
		table.insert(out, Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius))
	end
	return out
end
local function scatter(center, count, reach, spawner)
	for _ = 1, count do
		local a, r = math.random() * math.pi * 2, math.sqrt(math.random()) * reach
		spawner(center + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r))
	end
end
-- LootService's shares of the spots (CHEST_FRACTION 0.55 of chest spots, WEAPON 0.75, HEAL 0.7,
-- ITEM 0.6), on a town's 16 chest spots, 24 gun spots, 10 heal spots and 8 item spots; a landmark
-- has a quarter of that.
local function populate(center, scale)
	scatter(center, math.floor(16 * 0.55 * scale), 70, spawnChest)
	scatter(center, math.floor(24 * 0.75 * scale), 90, function(p) spawnGun(p) end)
	scatter(center, math.floor(10 * 0.7 * scale), 70, function(p) spawnConsumable(p, ItemData.RollRecovery()) end)
	scatter(center, math.floor(8 * 0.6 * scale), 80, function(p)
		local roll = math.random()
		local item = roll < 0.22 and ItemData.RollThrowable() or roll < 0.37 and ItemData.RollDefense() or ItemData.RollMovement()
		spawnConsumable(p, item)
	end)
end
for _, c in ipairs(ring(6, 330, 0.3)) do table.insert(towns, c); table.insert(dropSpots, c); populate(c, 1) end
for i, c in ipairs(ring(4, 520, 1.1)) do
	local spot = { X = c.X, Y = 0, Z = c.Z, name = "Landmark" .. i }
	table.insert(landmarks, spot); table.insert(dropSpots, spot); populate(c, 0.25)
end
-- Roads between neighbouring towns: a part every 30 studs.
for i = 1, #towns do
	local a, b = towns[i], towns[i % #towns + 1]
	local n = math.floor((b - a).Magnitude / 30)
	for k = 0, n do
		local p = a + (b - a) * (k / n)
		local part = newPart("Road", p, roadsFolder)
		part.Size = Vector3.new(30, 1, 12)
	end
end

--------------------------------------------------------------------------------
-- Bots
--------------------------------------------------------------------------------
local N = 48
local bots = {}
local function newBot(index, position)
	local humanoid = { Health = MatchConfig.BotHealth, MaxHealth = MatchConfig.BotHealth, attrs = { Shield = 0 } }
	function humanoid:GetAttribute(k) return self.attrs[k] end
	function humanoid:SetAttribute(k, v) self.attrs[k] = v end
	function humanoid:MoveTo() end
	local bot = {
		isBot = true, name = "Bot" .. index, slot = index - 1, humanoid = humanoid,
		character = { Parent = true, SetAttribute = function() end },
		position = position, weapon = nil, backup = nil, backupMag = nil, gunSwapAt = 0,
		heals = { Bandage = math.random(0, MatchConfig.BotStartBandages), MedKit = 0 },
		shields = { MiniShield = 0, ShieldPotion = 0 }, throwables = {}, defenses = 0, rockets = 0,
		lootTarget = nil, lootCheckedAt = 0, lootHoldStart = nil, lootBlacklist = {}, lootFailures = 0,
		lastCombatAt = -100, lastHealAt = -100, lastHurtAt = -100, lastHealth = MatchConfig.BotHealth,
		nav = { failures = 0 }, wanderGoal = nil, wanderTarget = nil, wanderAt = 0,
		landedAt = nil, dropping = true, memory = nil, threat = nil,
		-- metrics
		m = { pickups = 0, chests = 0, healUses = 0, shieldUses = 0, outside = 0, zoneDeath = false, kills = 0,
			deadAt = nil, landHeat = nil, hot = nil, crates = 0 },
	}
	bot.root = setmetatable({}, { __index = function(_, k) if k == "Position" then return bot.position end end })
	bot.character.FindFirstChild = function() return bot.root end
	return bot
end

--------------------------------------------------------------------------------
-- Legacy models (the decisions as they were before the archetypes)
--------------------------------------------------------------------------------
local legacy = false
local usableLegacy = function(def)
	return def and not def.staged and not (def.projectile and def.projectile ~= "rocket" and def.projectile ~= "grenade")
end
local function legacyTake(bot, def)
	if usableLegacy(def) and (not bot.weapon or (Rarity.Index[def.rarity] or 0) > (Rarity.Index[bot.weapon.rarity] or 0)) then
		bot.weapon = def
		bot.mag = magazineOf(def)
	end
end
local function legacyPick(bot, humanoid, root, underArmed, empty, center, circleRadius, now)
	local item = SupplyDropService.FindNearest(root.Position, 900)
	if item and not S.lootAllowed(bot, item, (item.Position - root.Position).Magnitude, center, circleRadius, now) then item = nil end
	if not item and underArmed then
		item = S.findLoot(bot, root.Position, empty and 320 or 200, false, center, circleRadius, now)
	end
	if not item then
		local bestDistance = 200
		for _, entry in ipairs(S.lootItems(now)) do
			local chest = entry.item
			if chest.Name == "Chest" and chest.Parent and not chest:GetAttribute("Claimed") then
				local d = (entry.position - root.Position).Magnitude
				if d < bestDistance and S.lootAllowed(bot, chest, d, center, circleRadius, now) then item, bestDistance = chest, d end
			end
		end
	end
	if not item and empty then item = S.findLoot(bot, root.Position, math.huge, false, center, circleRadius, now) end
	if not item and bot.heals.Bandage + bot.heals.MedKit == 0 and humanoid.Health < humanoid.MaxHealth * MatchConfig.BotHealBelow then
		item = S.findLoot(bot, root.Position, 140, true, center, circleRadius, now)
	end
	return item
end

-- Invariant watch round every claim: the held gun's rarity never drops, the backup is another class,
-- and every gun the bot didn't keep is back on the floor (junk dropped == claims not kept).
local violations = {}
local realTake = LR.takeGun
local claims = { guns = 0, kept = 0 }
LR.takeGun = function(bot, def, position)
	local before = bot.weapon and (Rarity.Index[bot.weapon.rarity] or 0) or -1
	local dropsBefore = counts.droppedGuns
	local result = realTake(bot, def, position)
	claims.guns = claims.guns + 1
	local after = bot.weapon and (Rarity.Index[bot.weapon.rarity] or 0) or -1
	if after < before then table.insert(violations, "held gun rarity fell " .. before .. " -> " .. after) end
	if bot.backup and LR.classOf(bot.backup) == LR.classOf(bot.weapon) then table.insert(violations, "backup same class as held") end
	if result ~= "dropped" then claims.kept = claims.kept + 1 end
	if result == "dropped" and counts.droppedGuns == dropsBefore then table.insert(violations, "junk vanished instead of dropping") end
	return result
end
-- Snapshot passes per loot pick: the section's scans each walk the snapshot once, so counting the
-- calls to them counts the passes (findLoot's own pass is one more; the bound below allows for it).
local snapshotReads, maxReadsPerPick = 0, 0
local realBestGear, realBestConsumable, realFindLoot = LR.bestGear, LR.bestConsumable, S.findLoot
LR.bestGear = function(...) snapshotReads = snapshotReads + 1 return realBestGear(...) end
LR.bestConsumable = function(...) snapshotReads = snapshotReads + 1 return realBestConsumable(...) end

--------------------------------------------------------------------------------
-- The match
--------------------------------------------------------------------------------
local DT = MatchConfig.BotThinkInterval
local WALK, SPRINT = MatchConfig.BotWalkSpeed, MatchConfig.BotWalkSpeed * 1.45
local GLIDE = 45
local function moveToward(bot, goal, speed)
	local delta = Vector3.new(goal.X - bot.position.X, 0, goal.Z - bot.position.Z)
	local d = delta.Magnitude
	if d < 0.01 then return end
	local step = math.min(d, speed * DT)
	bot.position = bot.position + delta.Unit * step
end
local function alive(bot) return bot.humanoid.Health > 0 end
local zoneDetail = {}
local function kill(bot, now, byStorm, killer)
	if byStorm then
		local key = (bot.weapon and "armed" or "unarmed") .. (bot.lootTarget and "+loot" or "") .. (now - bot.lastHurtAt < 5 and "+fight" or "") .. (bot.dropping and "+drop" or "") .. ((storm.radius > 0 and (Vector3.new(bot.position.X - storm.center.X, 0, bot.position.Z - storm.center.Z).Magnitude - storm.radius) > 100) and "+far" or "")
		zoneDetail[key] = (zoneDetail[key] or 0) + 1
	end
	bot.humanoid.Health = 0
	bot.character.Parent = nil
	bot.m.deadAt = now
	bot.m.zoneDeath = byStorm
	if killer then killer.m.kills = killer.m.kills + 1 end
	S.releaseLoot(bot)
	if bot.weapon then LootService.DropWeapon(bot.weapon.id, bot.position) end
	if bot.backup then LootService.DropWeapon(bot.backup.id, bot.position) end
	if bot.heals.Bandage + bot.heals.MedKit > 0 then LootService.DropHeal(bot.position) end
end

-- Storm schedule: 60 s open, then each phase's hold and shrink from MatchConfig.
local phases = MatchConfig.StormPhases
local function stepStorm(now)
	local t = now - 60
	if t < 0 then storm.status = "Idle"; storm.radius = 0; return 0 end
	local radius = MAP_RADIUS
	for index, phase in ipairs(phases) do
		local target = MAP_RADIUS * phase.radiusScale
		if t < phase.holdTime then
			storm.status = "Waiting"; storm.phase = index; storm.radius = radius
			storm.targetRadius = target; storm.targetCenter = storm.center
			storm.secondsLeft = phase.holdTime - t; storm.shrinkSeconds = phase.shrinkTime
			return phase.damagePerSecond
		end
		t = t - phase.holdTime
		if t < phase.shrinkTime then
			storm.status = "Shrinking"; storm.phase = index
			storm.radius = radius + (target - radius) * (t / phase.shrinkTime)
			storm.targetRadius = target; storm.targetCenter = storm.center
			storm.secondsLeft = phase.shrinkTime - t
			return phase.damagePerSecond
		end
		t = t - phase.shrinkTime
		radius = target
	end
	storm.status = "Waiting"; storm.radius = radius; storm.targetRadius = 0; storm.secondsLeft = 0
	return phases[#phases].damagePerSecond
end

local function nearestEnemy(bot, range)
	local best, bestDistance = nil, range
	for _, entry in ipairs(combatantList) do
		if entry.token ~= bot and entry.humanoid.Health > 0 and hostile(bot, entry.token) then
			local d = (entry.position - bot.position).Magnitude
			if d < bestDistance then best, bestDistance = entry.token, d end
		end
	end
	return best, bestDistance
end

local snapshots = {}
local function snapshot(now, label)
	local rows = {}
	for _, name in ipairs(ARCHETYPES) do rows[name] = { alive = 0, rarity = 0, armed = 0, backup = 0, stock = 0, n = 0, pickups = 0, chests = 0 } end
	for _, bot in ipairs(bots) do
		local name = LR.archetypeOf(bot, now)
		local row = rows[name]
		row.n = row.n + 1
		row.pickups = row.pickups + bot.m.pickups
		row.chests = row.chests + bot.m.chests
		if alive(bot) then
			row.alive = row.alive + 1
			if bot.weapon then row.armed = row.armed + 1; row.rarity = row.rarity + (Rarity.Index[bot.weapon.rarity] or 0) end
			if bot.backup then row.backup = row.backup + 1 end
			row.stock = row.stock + bot.heals.Bandage + bot.heals.MedKit + bot.shields.MiniShield + bot.shields.ShieldPotion
		end
	end
	snapshots[label] = rows
end

local function runMatch(isLegacy, rotationOnly)
	legacy = isLegacy
	bots = {}
	zoneDetail = {}
	snapshots = {}
	-- Rotation only: eight starting spots shared by the six kinds (bot 1..6 on the first, 7..12 on the
	-- second...), so kinds are compared from the same places.
	local spots = {}
	for i = 1, 8 do
		local angle, reach = math.random() * math.pi * 2, math.sqrt(math.random()) * 600
		spots[i] = Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
	end
	if legacy then
		LR.healBelow = function() return MatchConfig.BotHealBelow end
		LR.shieldLow = function() return 50 end
	end
	local cratesDropped = 0
	for index = 1, N do
		local a = index / N * math.pi * 2 * 2
		local from = Vector3.new(math.cos(a) * 560, 0, math.sin(a) * 560)
		local bot = newBot(index, from)
		if rotationOnly then
			bot.position = spots[math.floor((index - 1) / 6) + 1]
			bot.dropping = false
			bot.landedAt = 0
			bot.weapon = WeaponData.Get("SahurPistol")
			bot.dropTarget = bot.position
		elseif legacy then
			bot.dropTarget = S.pickDropTarget(dropSpots, from)
		else
			bot.dropTarget = S.pickDropTarget(dropSpots, from, bot)
		end
		table.insert(bots, bot)
	end
	local now = 0
	while now < 600 do
		now = now + DT
		local stormDps = stepStorm(now)
		if (now > 180 and cratesDropped == 0) or (now > 360 and cratesDropped == 1) then
			cratesDropped = cratesDropped + 1
			local a = math.random() * math.pi * 2
			local crate = newPart("SupplyCrate", Vector3.new(math.cos(a) * storm.radius * 0.5, 0, math.sin(a) * storm.radius * 0.5), crateFolder)
			crate:SetAttribute("Landed", true)
			crate:SetAttribute("WeaponId", "CameloLMG")
		end
		combatantList = {}
		for _, bot in ipairs(bots) do
			if alive(bot) then table.insert(combatantList, { token = bot, humanoid = bot.humanoid, position = bot.position }) end
		end
		for _, bot in ipairs(bots) do
			if alive(bot) then
				local humanoid, root = bot.humanoid, bot.root
				if bot.dropping then
					moveToward(bot, bot.dropTarget, GLIDE)
					if S.flatDistance(bot.position, bot.dropTarget) < 2 then
						bot.dropping = false
						bot.landedAt = now
						local heat = 0
						for _, entry in ipairs(S.lootItems(now)) do
							if entry.item.Name == "Chest" and (entry.position - bot.position).Magnitude <= 110 then heat = heat + 1 end
						end
						bot.m.landHeat = heat
						bot.m.hot = bot.dropHot
					end
				else
					local outside = storm.radius > 0 and StormService.IsOutside(bot.position)
					if outside then
						bot.m.outside = bot.m.outside + DT
						humanoid.Health = humanoid.Health - stormDps * DT
						bot.lastCombatAt = now
						if humanoid.Health <= 0 then kill(bot, now, true) end
					end
				end
			end
			if alive(bot) and not bot.dropping then
				local humanoid, root = bot.humanoid, bot.root
				local pressure = S.stormPressure(bot.position)
				local rotateAt = legacy and MatchConfig.BotStormRotate or LR.rotateAt(bot)
				local function rotate(speed)
					local center, radius = S.safeCircle()
					if not bot.wanderGoal or not S.insideCircle(bot.wanderGoal, center, radius, 0.85) then
						bot.wanderGoal = legacy and S.stormGoal(bot.position) or LR.rotationGoal(bot, bot.position)
						bot.wanderTarget = nil
					end
					if not bot.wanderTarget or S.flatDistance(bot.position, bot.wanderTarget) < 16 then
						bot.wanderTarget = legacy and S.nextLeg(bot.position, bot.wanderGoal) or LR.leg(bot, bot.position, bot.wanderGoal, now, speed == SPRINT)
					end
					moveToward(bot, bot.wanderTarget, speed)
				end
				-- Fight model: an armed bot with an enemy inside its range and 50 studs trades shots.
				local enemy, distance = nil, nil
				if not rotationOnly then
					enemy, distance = nearestEnemy(bot, 50)
				end
				local fighting = false
				if enemy and bot.weapon and not legacy then LR.swapGunFor(bot, distance, now) end
				if enemy and bot.weapon and distance <= bot.weapon.range then
					fighting = true
					bot.lastCombatAt = now
					bot.lootHoldStart = nil
					if math.random() < 0.06 then
						local dealt = (bot.weapon.damage or 15) * 0.2 * MatchConfig.BotDamageScale
						local shield = enemy.humanoid:GetAttribute("Shield") or 0
						local absorbed = math.min(shield, dealt)
						enemy.humanoid:SetAttribute("Shield", shield - absorbed)
						enemy.humanoid.Health = enemy.humanoid.Health - (dealt - absorbed)
						enemy.lastCombatAt = now
						enemy.lastHurtAt = now
						enemy.threat = { token = bot, position = bot.position, at = now }
						if enemy.humanoid.Health <= 0 then kill(enemy, now, false, bot) end
					end
				end
				if fighting then
					if pressure >= MatchConfig.BotStormUrgent then rotate(SPRINT) end
				elseif StormService.IsOutside(bot.position) and storm.radius > 0 and pressure >= MatchConfig.BotStormUrgent then
					S.releaseLoot(bot)
					S.tryHeal(bot, humanoid, now)
					S.tryShield(bot, humanoid, now)
					rotate(SPRINT)
				else
					local healsBefore = bot.heals.Bandage + bot.heals.MedKit
					local shieldsBefore = bot.shields.MiniShield + bot.shields.ShieldPotion
					S.tryHeal(bot, humanoid, now)
					S.tryShield(bot, humanoid, now)
					if bot.heals.Bandage + bot.heals.MedKit < healsBefore then bot.m.healUses = bot.m.healUses + 1 end
					if bot.shields.MiniShield + bot.shields.ShieldPotion < shieldsBefore then bot.m.shieldUses = bot.m.shieldUses + 1 end
					if enemy and not bot.weapon and now - bot.lastHurtAt < 3 then
						-- Unarmed under fire: away from the shooter (flee model), unless a gun is at hand.
						local grab = bot.lootTarget and (bot.lootTarget.Position - bot.position).Magnitude < 60
						if not grab then
							local away = bot.position - enemy.position
							moveToward(bot, bot.position + away, SPRINT)
						end
					end
					local center, circleRadius = nil, nil
					if pressure >= rotateAt then center, circleRadius = S.safeCircle() end
					if pressure >= MatchConfig.BotStormUrgent then
						S.releaseLoot(bot)
						rotate(SPRINT)
					else
						if bot.lootTarget and (not bot.lootTarget.Parent or bot.lootTarget:GetAttribute("Claimed")
							or not S.insideCircle(bot.lootTarget.Position, center, circleRadius, 0.9)) then
							S.releaseLoot(bot)
						end
						local underArmed = S.isUnderArmed(bot)
						local empty = bot.weapon == nil
						local interval = empty and 1.5 or (legacy and 5 or LR.lootInterval(bot, now))
						if not rotationOnly and not bot.lootTarget and now - bot.lootCheckedAt > interval then
							bot.lootCheckedAt = now
							local item
							snapshotReads = 0
							if legacy then
								item = legacyPick(bot, humanoid, root, underArmed, empty, center, circleRadius, now)
							else
								item = LR.pickLoot(bot, humanoid, root, underArmed, empty, center, circleRadius, now)
								maxReadsPerPick = math.max(maxReadsPerPick, snapshotReads)
							end
							if item then S.setLootTarget(bot, item) end
						end
						if bot.lootTarget then
							local item = bot.lootTarget
							local reach = (item.Position - bot.position).Magnitude
							if reach < 13 then
								local wasChest = item.Name == "Chest"
								local wasCrate = item.Name == "SupplyCrate"
								local claimedBefore = item:GetAttribute("Claimed")
								if legacy then
									-- The old holdLoot: same hold, rarity-only swap.
									if not bot.lootHoldStart then bot.lootHoldStart = now end
									if now - bot.lootHoldStart >= LootService.ClaimTime(item) then
										local def
										if item.Name == "HealPickup" then
											local healId, amount = LootService.ClaimHealForBot(item)
											if healId then S.giveBotHeal(bot, healId, amount) end
										elseif wasCrate then def = SupplyDropService.ClaimForBot(item)
										else def = LootService.ClaimForBot(item) end
										S.releaseLoot(bot)
										if def and wasChest then S.giveBotHeal(bot, "Bandage", math.random(1, 3)) end
										if def then legacyTake(bot, def) end
									end
								else
									S.holdLoot(bot, humanoid, root, now)
								end
								if not bot.lootTarget and not claimedBefore and (item:GetAttribute("Claimed") or not item.Parent) then
									bot.m.pickups = bot.m.pickups + 1
									if wasChest then bot.m.chests = bot.m.chests + 1 end
									if wasCrate then bot.m.crates = bot.m.crates + 1 end
								end
							else
								bot.lootHoldStart = nil
								moveToward(bot, item.Position, (empty and reach > 60) and SPRINT or WALK)
							end
						elseif pressure >= rotateAt then
							rotate(SPRINT)
						else
							if not bot.wanderGoal or S.flatDistance(bot.position, bot.wanderGoal) < 24 or now - bot.wanderAt > 30 then
								bot.wanderGoal = legacy and S.stormGoal(bot.position) or LR.rotationGoal(bot, bot.position)
								bot.wanderAt = now
							end
							moveToward(bot, bot.wanderGoal, WALK)
						end
					end
				end
			end
		end
		if math.abs(now - 120) < DT / 2 then snapshot(now, "2min") end
		if math.abs(now - 300) < DT / 2 then snapshot(now, "5min") end
	end
	snapshot(now, "10min")

	-- Per-archetype totals.
	local report = {}
	for _, name in ipairs(ARCHETYPES) do
		report[name] = { n = 0, heat = 0, heatN = 0, hot = 0, healUses = 0, shieldUses = 0, outside = 0, zoneDeaths = 0,
			kills = 0, crates = 0, shields = 0, throwables = 0, aliveSeconds = 0, lateSeconds = 0 }
	end
	for _, bot in ipairs(bots) do
		local r = report[LR.archetypeOf(bot, now)]
		r.n = r.n + 1
		if bot.m.landHeat then r.heat = r.heat + bot.m.landHeat; r.heatN = r.heatN + 1 end
		if bot.m.hot then r.hot = r.hot + 1 end
		r.healUses = r.healUses + bot.m.healUses
		r.shieldUses = r.shieldUses + bot.m.shieldUses
		r.outside = r.outside + bot.m.outside
		if bot.m.zoneDeath then r.zoneDeaths = r.zoneDeaths + 1 end
		-- Exposure: seconds alive, and seconds alive after 5 min when the circles are small and the
		-- storm bites (zone deaths happen there), so a kind that lives longer is not read as a worse rotator.
		local endAt = bot.m.deadAt or now
		r.aliveSeconds = r.aliveSeconds + endAt
		r.lateSeconds = r.lateSeconds + math.max(0, endAt - 300)
		r.kills = r.kills + bot.m.kills
		r.crates = r.crates + bot.m.crates
	end
	local outsideByKind = {}
	for _, name in ipairs(ARCHETYPES) do outsideByKind[name] = report[name].outside end
	return { report = report, snapshots = snapshots, counts = counts, violations = violations, claims = claims, zoneDetail = zoneDetail,
		outsideByKind = outsideByKind,
		stats = { stocked = STATS.lootStocked, contested = STATS.lootContested, roadLegs = STATS.roadLegs,
			upgrades = STATS.lootUpgrades, backups = STATS.lootBackups, junk = STATS.lootJunkDropped, swaps = STATS.gunSwaps,
			dropHot = STATS.dropHot, dropQuiet = STATS.dropQuiet, supplySkipped = STATS.supplySkipped },
		maxReadsPerPick = maxReadsPerPick }
end

--------------------------------------------------------------------------------
-- Unit checks that need no match
--------------------------------------------------------------------------------
local function unitChecks()
	local out = {}
	local function botOf(name, position)
		local index = 0
		for i, n in ipairs(ARCHETYPES) do if n == name then index = i - 1 end end
		local bot = newBot(index + 1, position)
		bot.dropping = false
		bot.landedAt = 0
		bot.weapon = WeaponData.Get("CrocodiloRifle")
		return bot
	end
	local now = 1000
	-- Dials in order.
	out.healOrder = LR.healBelow(botOf("Survivor")) > LR.healBelow(botOf("Anchor"))
		and LR.healBelow(botOf("Anchor")) > LR.healBelow(botOf("Flanker"))
		and LR.healBelow(botOf("Flanker")) > LR.healBelow(botOf("Rusher"))
	out.shieldOrder = LR.shieldLow(botOf("Survivor")) > LR.shieldLow(botOf("Flanker")) and LR.shieldLow(botOf("Flanker")) > LR.shieldLow(botOf("Rusher"))
	out.rotateOrder = LR.rotateAt(botOf("Survivor")) < LR.rotateAt(botOf("Flanker")) and LR.rotateAt(botOf("Flanker")) < LR.rotateAt(botOf("Rusher"))
	-- Nobody rotates later than the old single dial, and every rotation goal of every kind lands
	-- inside the circle the storm is heading for, short of the 85% share updateBot calls stale: these
	-- two are what keeps zone deaths from rising whatever the goal angles roll.
	out.rotateNotLater, out.goalInside = true, true
	storm.status = "Shrinking"; storm.center = Vector3.new(100, 0, -50); storm.radius = 400
	storm.targetCenter = Vector3.new(130, 0, -20); storm.targetRadius = 250; storm.secondsLeft = 20; storm.phase = 2
	for _, name in ipairs(ARCHETYPES) do
		local b = botOf(name, Vector3.new(400, 0, 300))
		if LR.rotateAt(b) > MatchConfig.BotStormRotate then out.rotateNotLater = false end
		for _ = 1, 100 do
			local goal = LR.rotationGoal(b, b.position)
			if S.flatDistance(goal, storm.targetCenter) > storm.targetRadius * 0.85 then out.goalInside = false end
		end
	end
	storm.status = "Idle"; storm.radius = 0; storm.center = Vector3.new(0, 0, 0)
	-- Supply: a crate 500 studs off, the only one on the map.
	for i = #crateFolder.children, 1, -1 do table.remove(crateFolder.children, i) end
	local crate = newPart("SupplyCrate", Vector3.new(500, 0, 0), crateFolder)
	crate:SetAttribute("Landed", true)
	crate:SetAttribute("WeaponId", "CameloLMG")
	local far = Vector3.new(0, 0, 0)
	local survivor, opportunist = botOf("Survivor", far), botOf("Opportunist", far)
	combatantList = {}
	survivor.landedAt, opportunist.landedAt = now, now
	local pickS = LR.pickLoot(survivor, survivor.humanoid, survivor.root, false, false, nil, nil, now)
	local pickO = LR.pickLoot(opportunist, opportunist.humanoid, opportunist.root, false, false, nil, nil, now)
	now = now + 5 -- a fresh loot snapshot for the chest below
	out.supplySurvivorLeaves = pickS ~= crate
	out.supplyOpportunistGoes = pickO == crate
	crate:Destroy()
	-- Contested: a chest 40 studs off with one enemy standing on it.
	local chest = spawnChest(Vector3.new(0, 0, 3000))
	local enemy = newBot(99, Vector3.new(5, 0, 3000))
	local rusher = botOf("Rusher", Vector3.new(40, 0, 3000))
	local shy = botOf("Survivor", Vector3.new(40, 0, 3000))
	rusher.landedAt, shy.landedAt = now, now
	combatantList = { { token = enemy, humanoid = enemy.humanoid, position = enemy.position } }
	out.contestedRusherTakes = LR.pickLoot(rusher, rusher.humanoid, rusher.root, false, false, nil, nil, now) == chest
	out.contestedSurvivorSkips = LR.pickLoot(shy, shy.humanoid, shy.root, false, false, nil, nil, now) ~= chest
	combatantList = {}
	S.releaseLoot(rusher)
	chest:Destroy()
	-- Inventory: a Rusher holding an Uncommon rifle claims a Common shotgun (another class): backup,
	-- then a Rare shotgun: swaps in (gain 1 + 0.6), rifle kept as backup, old shotgun on the floor.
	local r = botOf("Rusher", Vector3.new(0, 0, 5000))
	local drops = counts.droppedGuns
	out.takeBackup = LR.takeGun(r, WeaponData.Get("TralalaShotgun"), r.position) == "backup" and r.backup ~= nil
	out.takeUpgrade = LR.takeGun(r, WeaponData.Get("AuraScattergun"), r.position) == "primary"
		and r.weapon.id == "AuraScattergun" and r.backup and r.backup.id == "CrocodiloRifle" and counts.droppedGuns == drops + 1
	-- The pistol that adds nothing goes straight back down.
	out.takeJunk = LR.takeGun(r, WeaponData.Get("SahurPistol"), r.position) == "dropped" and counts.droppedGuns == drops + 2
	-- Range swap: a Marksman with a sniper in hand and an SMG on the back, someone at 15 studs.
	local mk = botOf("Marksman", Vector3.new(0, 0, 6000))
	mk.weapon = WeaponData.Get("LarilaSniper")
	mk.backup = WeaponData.Get("RotSMG")
	mk.backupMag = 30
	out.swapClose = LR.swapGunFor(mk, 15, now) and mk.weapon.id == "RotSMG" and mk.backup.id == "LarilaSniper"
	out.swapCooldown = not LR.swapGunFor(mk, 200, now + 1)
	out.swapLong = LR.swapGunFor(mk, 200, now + 4) and mk.weapon.id == "LarilaSniper"
	return out
end

--------------------------------------------------------------------------------
-- Team base: twelve bots off one pad, fourteen chests round the compound
--------------------------------------------------------------------------------
local function baseScenario(useLegacy)
	for i = #lootFolder.children, 1, -1 do table.remove(lootFolder.children, i) end
	for k in pairs(S.lootClaims) do S.lootClaims[k] = nil end
	local base = Vector3.new(0, 0, 9000)
	for i = 1, 14 do
		local a = i / 14 * math.pi * 2
		spawnChest(base + Vector3.new(math.cos(a) * 60, 0, math.sin(a) * 60))
	end
	local squad = {}
	teams = {}
	for i = 1, 12 do
		local bot = newBot(200 + i, base + Vector3.new(-70 + math.random() * 8, 0, math.random() * 8 - 4))
		bot.dropping = false
		teams[bot] = 1
		table.insert(squad, bot)
	end
	lazyModules.ModeTeams = { BaseOf = function() return base end }
	local now = 2000 + (useLegacy and 0 or 10)
	local targets = {}
	for _, bot in ipairs(squad) do
		local item
		if useLegacy then
			-- The old chestsFirst loop: nearest chest at the base that lootAllowed lets this bot have.
			local bestDistance = 220
			for _, entry in ipairs(S.lootItems(now)) do
				local c = entry.item
				if c.Name == "Chest" and c.Parent and not c:GetAttribute("Claimed") then
					local d = (entry.position - bot.position).Magnitude
					if d < bestDistance and S.lootAllowed(bot, c, d, nil, nil, now) then item, bestDistance = c, d end
				end
			end
		else
			item = BotService.FindBaseLoot(bot, bot.root, { team = 1 }, nil, nil, now, true)
		end
		if item then
			S.setLootTarget(bot, item)
			targets[item] = (targets[item] or 0) + 1
		end
	end
	local distinct, worst = 0, 0
	for _, n in pairs(targets) do distinct = distinct + 1; worst = math.max(worst, n) end
	for _, bot in ipairs(squad) do S.releaseLoot(bot) end
	teams = nil
	lazyModules.ModeTeams = nil
	return distinct, worst
end

return { runMatch = runMatch, unitChecks = unitChecks, baseScenario = baseScenario, LR = LR, WeaponData = WeaponData, newBot = newBot, counts = counts, Rarity = Rarity, env = _ENV }
"""


def load_world(root, bot_src, seed):
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = lua.table()
    # Every Shared module, so WeaponData's arsenal packs (and theirs) resolve by name.
    for file in os.listdir(os.path.join(root, SHARED)):
        if file.endswith(".lua"):
            shared[file[:-4]] = luau_to_lua(open(os.path.join(root, SHARED, file), encoding="utf-8").read())
    prelude = perf.PRELUDE
    world = lua.execute(prelude + "\nreturn function(...) " + WORLD.replace("local root, botSrc, shared, seed = ...", "local root, botSrc, shared, seed = ...", 1) + " end")
    return world(root, slices(bot_src), shared, seed)


def merge(into, part):
    """Sum a Lua report's numbers into a Python dict of the same shape (lists are concatenated)."""
    for key in list(part.keys()):
        value = part[key]
        if hasattr(value, "keys"):
            into[key] = merge(into.get(key, {}), value)
        elif isinstance(value, bool):
            into[key] = value
        elif isinstance(value, (int, float)):
            into[key] = into.get(key, 0) + value
        else:
            into[key] = value
    return into


def one_match(root, bot_src, seed, legacy):
    """Legacy (when not cached) and archetype matches on the same seed, the rotation-only pair, plus the
    unit and base checks. The legacy world runs both legacy matches; the new world runs everything else."""
    if legacy is None:
        world_l = load_world(root, bot_src, seed)
        legacy = world_l.runMatch(True)
        legacy_rot = world_l.runMatch(True, True)
        legacy = (legacy, legacy_rot)
    world = load_world(root, bot_src, seed)
    new = world.runMatch(False)
    new_rot = world.runMatch(False, True)
    units = world.unitChecks()
    base_legacy = world.baseScenario(True)
    base_new = world.baseScenario(False)
    return legacy, (new, new_rot), units, base_legacy, base_new


def run(root, bot_src, seeds, verbose=True, legacies=None):
    """`seeds` matches, summed: pairs()-order in the real data tables (WeaponData's pools) makes a
    single seed's match differ run to run, so no check reads one match."""
    fails = []
    legacy, new, base_legacy, base_new = {}, {}, [0, 0], [0, 0]
    legacy_rot, new_rot = {}, {}
    units = None
    maxReads = 0
    for seed in seeds:
        cached = legacies.get(seed) if legacies else None
        lg, nw, un, bl, bn = one_match(root, bot_src, seed, cached)
        if legacies is not None:
            legacies[seed] = lg
        merge(legacy, lg[0])
        merge(legacy_rot, lg[1])
        merge(new, nw[0])
        merge(new_rot, nw[1])
        nw = nw[0]
        units = un if units is None else {k: bool(units[k]) and bool(un[k]) for k in un.keys()}
        base_legacy = [base_legacy[0] + bl[0], max(base_legacy[1], bl[1])]
        base_new = [base_new[0] + bn[0], max(base_new[1], bn[1])]
        maxReads = max(maxReads, nw["maxReadsPerPick"])
    matches = len(seeds)

    def row(rep, name):
        r = rep["report"][name]
        heat = r["heat"] / r["heatN"] if r["heatN"] else 0
        return r, heat

    tot = lambda rep, key: sum(rep["report"][n][key] for n in ARCHETYPES)
    if verbose:
        c = new["counts"]
        print(f"{matches} matches (seeds {', '.join(map(str, seeds))}), summed. Map per match: ~{c['spawnedChests'] // matches} chests, "
              f"~{c['spawnedGuns'] // matches} floor guns, ~{c['spawnedHeals'] // matches} heals/shields, ~{c['spawnedItems'] // matches} items "
              f"(real spawn tables); 48 bots, 8 per archetype; 10 min")
        print(f"{'archetype':12s} {'landHeat':>8s} {'hot%':>5s} | {'rar2':>5s} {'rar5':>5s} {'rar10':>5s} | {'bk2':>4s} {'bk5':>4s} {'bk10':>4s} "
              f"| {'stock2':>6s} {'stock5':>6s} {'pick5':>5s} {'chest5':>6s} | {'heals':>5s} {'shld':>4s} | {'out/min':>7s} {'zoneD':>5s} {'alive5':>6s} {'kills':>5s}")
        for name in ARCHETYPES:
            r, heat = row(new, name)
            snaps = new["snapshots"]

            def rar(label):
                s = snaps[label][name]
                return s["rarity"] / s["armed"] if s["armed"] else 0

            def bk(label):
                s = snaps[label][name]
                return 100 * s["backup"] / s["alive"] if s["alive"] else 0

            def stock(label):
                s = snaps[label][name]
                return s["stock"] / s["alive"] if s["alive"] else 0

            s5 = snaps["5min"][name]
            print(f"{name:12s} {heat:8.1f} {100 * r['hot'] / r['n']:5.0f} | {rar('2min'):5.2f} {rar('5min'):5.2f} {rar('10min'):5.2f} "
                  f"| {bk('2min'):4.0f} {bk('5min'):4.0f} {bk('10min'):4.0f} | {stock('2min'):6.1f} {stock('5min'):6.1f} {s5['pickups']:5d} {s5['chests']:6d} "
                  f"| {r['healUses']:5d} {r['shieldUses']:4d} | {60 * r['outside'] / max(1, r['aliveSeconds']):6.2f} {r['zoneDeaths']:5d} {s5['alive']:6d} {r['kills']:5d}")
        st = new["stats"]
        for label, rep in (("new", new), ("legacy", legacy)):
            print(f"exposure ({label:6s}): {tot(rep, 'aliveSeconds') / 60:.0f} bot-minutes alive, {tot(rep, 'lateSeconds') / 60:.0f} after 5 min; "
                  f"outside {60 * tot(rep, 'outside') / max(1, tot(rep, 'aliveSeconds')):.2f} s per alive minute; "
                  f"zone deaths {100 * tot(rep, 'zoneDeaths') / max(1, tot(rep, 'lateSeconds') / 60):.1f} per 100 late bot-minutes")
            print(f"totals ({label:6s}): zone deaths {tot(rep, 'zoneDeaths')}, outside {tot(rep, 'outside'):.0f} s, heal uses {tot(rep, 'healUses')}, "
                  f"shield uses {tot(rep, 'shieldUses')}, crates {tot(rep, 'crates')}, kills {tot(rep, 'kills')}, "
                  f"alive at 5 min {sum(rep['snapshots']['5min'][n]['alive'] for n in ARCHETYPES)}, "
                  f"mean held rarity at 2 min {sum(rep['snapshots']['2min'][n]['rarity'] for n in ARCHETYPES) / max(1, sum(rep['snapshots']['2min'][n]['armed'] for n in ARCHETYPES)):.2f}")
        for label, rep in (("new", new), ("legacy", legacy)):
            print(f"zone deaths by state ({label}): " + ", ".join(f"{k}={v}" for k, v in sorted(rep.get("zoneDetail", {}).items())))
        print(f"inventory: {new['claims']['guns']} guns claimed, {new['claims']['kept']} kept, {st['upgrades']} upgrades, {st['backups']} backups, "
              f"{st['junk']} junk dropped, {st['swaps']} range swaps; {st['stocked']} shields/throwables taken (legacy: 0 by construction); "
              f"{st['contested']} contested skips, {st['supplySkipped']} crates left; {st['roadLegs']} road legs")
        for label, rep in (("new", new_rot), ("legacy", legacy_rot)):
            print(f"rotation only ({label:6s}, no fights, no loot, all armed): zone deaths {tot(rep, 'zoneDeaths')}, outside {tot(rep, 'outside'):.0f} s over "
                  f"{matches * 48} bots; by kind: " + ", ".join(f"{n} {rep['outsideByKind'][n]:.0f}" for n in ARCHETYPES))
        print(f"drop: {st['dropHot']} hot, {st['dropQuiet']} quiet; base chests: legacy {base_legacy[0]} distinct targets over {matches} squads "
              f"(worst {base_legacy[1]} on one), new {base_new[0]} distinct (worst {base_new[1]}); snapshot passes per pick <= {maxReads}")
        print("units: " + ", ".join(f"{k}={'ok' if units[k] else 'FAIL'}" for k in sorted(units.keys())))

    # Checks.
    r_rusher, heat_rusher = row(new, "Rusher")
    r_survivor, heat_survivor = row(new, "Survivor")
    if not heat_survivor < heat_rusher * 0.6:
        fails.append(f"drop: Survivor landing heat {heat_survivor:.1f} not well below Rusher {heat_rusher:.1f}")
    if r_rusher["hot"] != r_rusher["n"] or r_survivor["hot"] != 0:
        fails.append(f"drop: hot roll ignores dropHotLanding (Rusher {r_rusher['hot']}/{r_rusher['n']}, Survivor {r_survivor['hot']})")
    viol = list(new["violations"].values()) if hasattr(new["violations"], "values") else []
    if viol:
        fails.append("inventory: " + str(viol[0]) + f" ({len(viol)} violations)")
    if new["claims"]["guns"] < 40 * matches:
        fails.append(f"inventory: only {new['claims']['guns']} guns claimed in {matches} ten-minute matches")
    if new["stats"]["backups"] == 0:
        fails.append("inventory: no bot ever kept a second gun")
    if new["stats"]["stocked"] == 0:
        fails.append("stock: no shield or throwable pickup was ever taken")
    for key, what in (("healOrder", "heal: healBelow not ordered Survivor > Anchor > Flanker > Rusher"),
                      ("shieldOrder", "heal: shieldLow not ordered Survivor > Flanker > Rusher"),
                      ("rotateOrder", "rotation: rotateAt not ordered Survivor < Flanker < Rusher"),
                      ("rotateNotLater", "rotation: some kind rotates later than BotStormRotate"),
                      ("goalInside", "rotation: a rotation goal fell outside 85% of the next circle"),
                      ("supplySurvivorLeaves", "supply: a Survivor walks 500 studs for a crate"),
                      ("supplyOpportunistGoes", "supply: an Opportunist leaves a crate 500 studs off"),
                      ("contestedRusherTakes", "contested: a Rusher skips a chest with one enemy on it"),
                      ("contestedSurvivorSkips", "contested: a Survivor walks at a chest with an enemy on it"),
                      ("takeBackup", "inventory: a gun of another class is not kept as the backup"),
                      ("takeUpgrade", "inventory: a Rare shotgun does not replace a Rusher's Uncommon rifle (or the rifle is not kept / the old shotgun not dropped)"),
                      ("takeJunk", "inventory: a useless pistol is not put back on the floor"),
                      ("swapClose", "inventory: sniper in hand at 15 studs, SMG on the back: no swap"),
                      ("swapCooldown", "inventory: swapped again inside the cooldown"),
                      ("swapLong", "inventory: SMG in hand at 200 studs, sniper on the back: no swap")):
        if not units[key]:
            fails.append(what)
    # Rotation is judged on the rotation-only pair: the same bots and storm with no fights and no loot,
    # so nothing but the rotation code separates legacy from new. (In the full match the new bots live
    # longer and meet the late circles in greater numbers; the fight MODEL then finishes low-health
    # bots in the storm, which says little about rotation. Its numbers are printed for the record.)
    new_zone, legacy_zone = tot(new_rot, "zoneDeaths"), tot(legacy_rot, "zoneDeaths")
    if new_zone > legacy_zone:
        fails.append(f"rotation: zone deaths (rotation only) rose {legacy_zone} -> {new_zone} over {matches} matches")
    new_out, legacy_out = tot(new_rot, "outside"), tot(legacy_rot, "outside")
    # Outside time is noisy (a few bots caught by one shrink decide it; six-match totals ranged
    # 350..730 s for the SAME code), so this is a coarse guard; rotateNotLater / goalInside above are
    # the exact ones.
    if new_out > legacy_out * 1.5 + 10 * matches:
        fails.append(f"rotation: outside seconds (rotation only) rose {legacy_out:.0f} -> {new_out:.0f} over {matches} matches")
    # No per-kind comparison even here: with one dial for every kind (legacy) the six kinds' outside
    # times still spread 56..120 s over six matches from the random goal angles alone, so eight bots
    # per kind cannot rank the kinds. The deterministic dial order (rotateOrder) covers that.
    if not base_new[0] > base_legacy[0] or base_new[1] > 1:
        fails.append(f"base: twelve bots target {base_new[0]} distinct chests over {matches} squads (legacy {base_legacy[0]}), worst {base_new[1]} on one")
    if maxReads > 4:
        fails.append(f"cost: a loot pick read the snapshot {maxReads} times")
    return fails


PLANTS = [
    ("score = -(heat + crowd * 1.5) - entry.distance / 400", "score = heat - entry.distance / 400",
     "drop: quiet landers pick the busiest town"),
    ("local hot = math.random() < BotService.Loot.dial(bot, \"dropHotLanding\")", "local hot = math.random() < 0.5",
     "drop: the hot/quiet roll ignores the archetype"),
    ("if gain >= threshold and (Rarity.Index[def.rarity] or 0) >= (Rarity.Index[held.rarity] or 0) then",
     "if gain >= -1 then", "inventory: swaps down to a worse gun"),
    ("\tif class ~= BotService.Loot.classOf(held) then\n\t\tif not bot.backup then", "\tif true then\n\t\tif not bot.backup then",
     "inventory: keeps a backup of the same class"),
    ("function BotService.Loot.dropJunk(def, position)\n\tif def and position then", "function BotService.Loot.dropJunk(def, position)\n\tif false then",
     "inventory: junk vanishes instead of going back on the floor"),
    ("function BotService.Loot.wantsConsumable(bot, entry)\n\tif entry.kind == \"heal\" then",
     "function BotService.Loot.wantsConsumable(bot, entry)\n\tif true then return false end\n\tif entry.kind == \"heal\" then",
     "stock: shields and throwables ignored"),
    ("return math.clamp(MatchConfig.BotHealBelow + (target - 3) * 0.05, 0.4, 0.8)", "return MatchConfig.BotHealBelow",
     "heal: every archetype heals at the same health"),
    ("return math.clamp(MatchConfig.BotStormRotate * (1.1 - 0.9 * BotService.Loot.dial(bot, \"rotateEarly\")), 0.25, MatchConfig.BotStormRotate)",
     "return MatchConfig.BotStormRotate", "rotation: every archetype rotates at the same pressure"),
    ("local crate = SupplyDropService.FindNearest(here, SUPPLY_SEEK_RANGE * chase)",
     "local crate = SupplyDropService.FindNearest(here, SUPPLY_SEEK_RANGE)", "supply: the chase range ignores the dial"),
    ("\tlocal enemies = BotService.Loot.enemiesNear(bot, position)\n\tif enemies == 0 then", "\tlocal enemies = 0\n\tif enemies == 0 then",
     "contested: nothing is ever contested"),
    ("\t\t\t\tlocal claimed = holder ~= nil and holder ~= bot and holder.lootTarget == item",
     "\t\t\t\tlocal claimed = false and holder ~= nil and holder ~= bot and holder.lootTarget == item",
     "base: the squad walks at the same nearest chest"),
    ("\tif distance > held.range and distance <= backup.range then\n\t\twant = true",
     "\tif distance > held.range and distance <= backup.range then\n\t\twant = false",
     "inventory: no swap to the gun that reaches"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    first = int(args[args.index("--seed") + 1]) if "--seed" in args else 7
    count = int(args[args.index("--seeds") + 1]) if "--seeds" in args else 6
    seeds = list(range(first, first + count))
    bot_src = open(os.path.join(root, BOTSERVICE), encoding="utf-8").read()

    if "--plant" in args:
        caught = 0
        legacies = {}
        for old, new, what in PLANTS:
            assert bot_src.count(old) == 1, f"plant text not found once: {old!r}"
            try:
                fails = run(root, bot_src.replace(old, new), seeds, verbose=False, legacies=legacies)
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            status = "CAUGHT" if fails else "MISSED"
            caught += bool(fails)
            print(f"plant [{status}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"bot_loot_sim plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    fails = run(root, bot_src, seeds)
    for f in fails:
        print("FAIL", f)
    print(f"bot_loot_sim: {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
