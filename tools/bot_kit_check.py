"""Task 26: team-mode bots spawn with a kit and don't loot their base. Offline, from the real source.

Runs in lupa, on bot_loot_sim's mocked world (its real BotService loot slices):
  - the real GameModes.BotLoadout + RollLoadout, ModeTeams' green gun roll (cut from ModeTeams.lua),
    GameMode.lua's BotService.SpawnLoadout hook and BotService's spawn kit handler, with the real
    granters and their caps (giveBotHeal, giveBotDefense, giveBotRocket, giveBotThrowable);
  - the real gear-up block cut out of updateBot, BotService.FindBaseLoot, BotService.Loot.bestConsumable
    and BotService.Loot.pickLoot, round a mocked team base.

Checks:
  kit        ROLLS kits: every roll is exactly 1 Uncommon gun, 2 explosives (one kind), 2 defenses (one
             kind), 2 heals and 1 movement item, each count within its item's ItemData stack, every
             id a bot can use, and the bot ends up CARRYING that (what the granters kept, not the list)
  base       a fresh kitted bot of every archetype, on the pad of a stocked base, targets nothing:
             the gear phase over 35 s of thinks, FindBaseLoot (chests-first and not), bestConsumable
             and pickLoot. The same bot without a kit does target base loot (the harness can see it)
  restock    a kitted bot that has used a Bandage goes home for a heal in a lull, and not in a fight
  field      a kitted bot away from home still picks up a heal it's short of (field loot unchanged)

    python tools/bot_kit_check.py .            the checks
    python tools/bot_kit_check.py . --plant    the planted faults; every one must be caught

Not measured: pathing, how long a bot takes to reach the middle (tools/bot_kit_probe.lua in Studio),
or how any of it looks.
"""

import importlib.util
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("bot_kit_check: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bot_loot_sim", os.path.join(HERE, "bot_loot_sim.py"))
sim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sim)

ROLLS = 10000
BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
GAMEMODE = "ServerScriptService/Modules/GameMode.lua"
MODETEAMS = "ServerScriptService/Modules/ModeTeams.lua"
GAMEMODES = "ReplicatedStorage/Shared/GameModes.lua"


def read(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def between(text, start, end, what):
    i = text.find(start)
    assert i >= 0, "bot_kit_check: can't find the start of " + what
    j = text.find(end, i + len(start))
    assert j >= 0, "bot_kit_check: can't find the end of " + what
    return text[i:j]


def kit_source(bot, gamemode, modeteams):
    """The spawn half: granters, the gun roll, GameMode's hook and the spawn kit handler."""
    consts = []
    for name in ("BOT_MAX_DEFENSES", "BOT_ROCKET_MAX"):
        m = re.search(r"^local %s = (.+)$" % name, bot, flags=re.M)
        assert m, name
        consts.append("local %s = %s" % (name, m.group(1)))
    granters = "\n".join([
        between(bot, "local function giveBotHeal", "-- Same lull and cooldown", "giveBotHeal"),
        between(bot, "local function giveBotDefense", "-- Rot Rockets, from supply", "giveBotDefense"),
        between(bot, "local function giveBotRocket", "local function tryRocket", "giveBotRocket"),
        between(bot, "local THROWABLES = {", "-- A lob needs headroom", "THROWABLES"),
    ])
    pool = between(modeteams, "local greenPool = {}", "\n----", "the green gun pool")
    hook = between(gamemode, "BotService.SpawnLoadout = function(_, humanoid)", "\n\tend\n", "GameMode's SpawnLoadout") + "\n\tend\n"
    hook = hook.replace("BotService.SpawnLoadout = function", "BotService.SpawnLoadout = function", 1)
    handler = between(bot, "\t\t\tif BotService.SpawnLoadout then", "\n\t\t\tend\n", "the spawn kit handler") + "\n\t\t\tend\n"
    # What a new bot carries before its kit: the constructor's own `heals = {...}` (a random starting
    # Bandage in the BR), so a kit that stacks on top of it shows up as extra heals.
    start = re.search(r"^\s*heals = (\{ Bandage = .+\}),\s*$", between(bot, "\t\t\tlocal bot = {", "\n\t\t\t}\n", "the bot constructor"), flags=re.M)
    assert start, "bot_kit_check: the constructor's starting heals moved"
    return sim.luau_to_lua("\n".join([
        "local ModeTeams = {}",
        "\n".join(consts),
        granters,
        pool,
        hook,
        "local function startHeals() return " + start.group(1) + " end",
        "local function spawnKit(bot, humanoid, character)",
        "\tbot.heals = startHeals()",
        handler,
        "end",
        "return { spawnKit = spawnKit, THROWABLES = THROWABLES, ModeTeams = ModeTeams }",
    ]))


def gear_source(bot):
    block = between(bot, "\tlocal gearState = BotService.ModeState(bot)", "\n\tif not bot.lootTarget and now - bot.lootCheckedAt >", "the gear-up block")
    return sim.luau_to_lua("local setLootTarget = ...\nreturn function(bot, root, now, center, circleRadius)\n" + block + "\nend\n")


CHECK = r"""
local S, kitSrc, gearSrc, ROLLS = ...
local env = _ENV
-- GameModes reaches Rarity through game:GetService("ReplicatedStorage").Shared.
game = { GetService = function() return { WaitForChild = function() return { WaitForChild = function(_, n) return { __module = n } end } end } end }
GameModes = require({ __module = "GameModes" })
local K = assert(load(kitSrc, "kit", "t", env))()
local gear = assert(load(gearSrc, "gear", "t", env))(S.setLootTarget)
ModeTeams = K.ModeTeams
local out = { fails = {}, counts = {} }
local function fail(msg) if #out.fails < 12 then table.insert(out.fails, msg) end out.nfail = (out.nfail or 0) + 1 end

local function freshBot(index, position)
	local bot = newBotFn(index, position)
	bot.heals = { Bandage = 0, MedKit = 0 }
	bot.shields = { MiniShield = 0, ShieldPotion = 0 }
	bot.throwables, bot.defenses, bot.rockets = {}, 0, 0
	bot.dropping, bot.loadoutWeapon = false, false
	return bot
end

-- Explosives are the throwables that blow up; a defense is what the kit handler hands to giveBotDefense.
local explosive = {}
for _, spec in pairs(K.THROWABLES) do if spec.blast > 0 then explosive[spec.itemId] = true end end
local botDefense = { RotBarricade = true, PopupBunker = true, BrainrotFortress = true }

--------------------------------------------------------------------------------
-- kit: ROLLS real rolls through the real hook and handler
--------------------------------------------------------------------------------
local lastList
local realRoll = GameModes.RollLoadout
GameModes.RollLoadout = function(...) lastList = realRoll(...) return lastList end
local seen = {}
for roll = 1, ROLLS do
	local bot = freshBot(roll, Vector3.new(0, 0, 0))
	lastList = nil
	K.spawnKit(bot, bot.humanoid, bot.character)
	local byKind = { explosive = 0, defense = 0, heal = 0, movement = 0, other = 0 }
	for _, entry in ipairs(lastList or {}) do
		local item = ItemData.Get(entry.id)
		seen[entry.id] = (seen[entry.id] or 0) + 1
		if not item then
			byKind.other = byKind.other + entry.count
		else
			if entry.count > item.stack then fail(("roll %d: %d %s over its stack of %d"):format(roll, entry.count, entry.id, item.stack)) end
			local kind = explosive[entry.id] and "explosive" or (botDefense[entry.id] and "defense")
				or (item.kind == "heal" and "heal") or (item.kind == "movement" and "movement") or "other"
			byKind[kind] = byKind[kind] + entry.count
		end
	end
	local carried = {
		gun = (bot.weapon and bot.loadoutWeapon and bot.weapon.rarity == GameModes.GreenRarity) and 1 or 0,
		explosive = 0, defense = bot.defenses, heal = S.LR.healCount(bot), movement = bot.rockets,
	}
	for id, n in pairs(bot.throwables) do if explosive[id] then carried.explosive = carried.explosive + n end end
	if bot.weapon then seen[bot.weapon.id] = (seen[bot.weapon.id] or 0) + 1 end
	local want = { gun = 1, explosive = 2, defense = 2, heal = 2, movement = 1 }
	for kind, n in pairs(want) do
		if kind ~= "gun" and byKind[kind] ~= n then fail(("roll %d: the list has %d %s, not %d"):format(roll, byKind[kind], kind, n)) end
		if carried[kind] ~= n then fail(("roll %d: the bot carries %d %s, not %d"):format(roll, carried[kind], kind, n)) end
	end
	if byKind.other > 0 then fail(("roll %d: %d item(s) outside the five kinds"):format(roll, byKind.other)) end
	if bot.kitHeals ~= 2 then fail(("roll %d: kitHeals is %s"):format(roll, tostring(bot.kitHeals))) end
	if bot.humanoid:GetAttribute("Shield") ~= MatchConfig.MaxShield then fail(("roll %d: shield %s"):format(roll, tostring(bot.humanoid:GetAttribute("Shield")))) end
end
out.seen = seen
GameModes.RollLoadout = realRoll

--------------------------------------------------------------------------------
-- base: a stocked team base, every archetype spawning on its pad
--------------------------------------------------------------------------------
local folder = workspace:FindFirstChild("Loot")
local base = Vector3.new(0, 0, 9000)
local function part(name, position, attrs)
	local p = { Name = name, Position = position, Parent = folder, attrs = attrs or {}, Size = Vector3.new(4, 1, 4) }
	function p:GetAttribute(k) return self.attrs[k] end
	function p:SetAttribute(k, v) self.attrs[k] = v end
	function p:IsA(c) return c == "BasePart" end
	function p:FindFirstChildOfClass() return nil end
	function p:Destroy() self.Parent = nil end
	table.insert(folder.children, p)
	return p
end
local function ring(count, radius, make)
	for i = 1, count do
		local a = i / count * math.pi * 2
		make(base + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius))
	end
end
local better
for _, def in pairs(WeaponData.Weapons) do
	if def.rarity == "Rare" and not def.staged and not def.projectile then better = better or def.id end
end
local function stockBase()
	for i = #folder.children, 1, -1 do folder.children[i] = nil end
	for k in pairs(S.lootClaims) do S.lootClaims[k] = nil end
	ring(14, 60, function(p) part("Chest", p) end)
	ring(6, 40, function(p) part("GroundWeapon", p, { WeaponId = better }) end)
	ring(4, 30, function(p) part("HealPickup", p, { HealId = "Bandage", ItemId = "Bandage", Amount = 2 }) end)
	ring(2, 35, function(p) part("HealPickup", p, { ItemId = "MiniShield", Amount = 2 }) end)
	ring(3, 45, function(p) part("ItemPickup", p, { ItemId = "CookedCoconut", Amount = 2 }) end)
	return #folder.children
end
out.counts.baseItems = stockBase()
local realLazy = lazy
lazy = function(name) if name == "ModeTeams" then return { BaseOf = function() return base end } end return realLazy(name) end
BotService.ModeState = function(bot) return bot.team and { team = bot.team } or nil end

local clock = 50000
local function tick_(step) clock = clock + (step or 1000) SIM_NOW = clock return clock end

-- Everything a spawn-time think can aim at home, path by path: the gear phase, FindBaseLoot and
-- bestConsumable, and pickLoot, which runs the last two. Returns { path = item or nil }.
local PATHS = { "gear phase", "FindBaseLoot", "bestConsumable", "pickLoot" }
local function baseTargets(bot)
	local hits = {}
	stockBase()
	local now = tick_()
	bot.lootTarget, bot.gearCharacter, bot.lootCheckedAt = nil, nil, 0
	-- The gear phase over 36 s of 0.6 s looks (it runs up to BotBaseGearSeconds).
	for step = 0, 60 do
		local t = now + step * 0.6
		SIM_NOW = t
		gear(bot, bot.root, t, nil, nil)
		out.counts.gearThinks = (out.counts.gearThinks or 0) + 1
		-- In the phase at all is a hit, target or not: gearUntil also keeps a bot off mounted guns and
		-- car seats (BotGunner's `busy`, Vehicles' seat pick).
		if bot.gearUntil and not hits["gear phase"] then hits["gear phase"] = { Name = "(gear-up phase entered)" } end
		if bot.lootTarget then hits["gear phase"] = bot.lootTarget S.releaseLoot(bot) break end
	end
	now = tick_()
	hits.FindBaseLoot = BotService.FindBaseLoot(bot, bot.root, { team = 1 }, nil, nil, now, true)
		or BotService.FindBaseLoot(bot, bot.root, { team = 1 }, nil, nil, now, false)
	hits.bestConsumable = S.LR.bestConsumable(bot, bot.root.Position, S.LR.STOCK_RANGE, nil, nil, now)
	hits.pickLoot = S.LR.pickLoot(bot, bot.humanoid, bot.root, S.isUnderArmed(bot), bot.weapon == nil, nil, nil, now)
	return hits
end

local pad = base + Vector3.new(-70, 0, 0)
local kitted, unkitted = 0, 0
out.control = {}
for slot = 0, 5 do
	local bot = freshBot(300 + slot, pad)
	bot.slot, bot.team, bot.lastCombatAt = slot, 1, -1000
	K.spawnKit(bot, bot.humanoid, bot.character)
	kitted = kitted + 1
	for path, item in pairs(baseTargets(bot)) do
		fail(("fresh kitted bot (slot %d) targeted a base %s via %s"):format(slot, item.Name, path))
	end
	-- The control: the same bot without the kit flag (today's rule) must be seen targeting base loot on
	-- every path, or that path's "targets nothing" above proves nothing.
	bot.kitHeals = nil
	unkitted = unkitted + 1
	local control = baseTargets(bot)
	for _, path in ipairs(PATHS) do
		if control[path] then
			out.control[path] = (out.control[path] or 0) + 1
		else
			fail(("control: an unkitted bot (slot %d) found no base loot via %s; that path is blind"):format(slot, path))
		end
	end
end
out.counts.kittedBots, out.counts.controlBots = kitted, unkitted

--------------------------------------------------------------------------------
-- restock: a used Bandage, in a lull and in a fight
--------------------------------------------------------------------------------
out.restock = {}
for slot = 0, 5 do
	stockBase()
	local bot = freshBot(400 + slot, pad)
	bot.slot, bot.team = slot, 1
	K.spawnKit(bot, bot.humanoid, bot.character)
	bot.heals.Bandage = bot.heals.Bandage - 1
	local now = tick_()
	bot.lastCombatAt = now - 20
	local lull = S.LR.pickLoot(bot, bot.humanoid, bot.root, S.isUnderArmed(bot), false, nil, nil, now)
	if not (lull and lull.Name == "HealPickup" and lull:GetAttribute("HealId")) then
		fail(("restock: slot %d, one Bandage used, in a lull, targeted %s, not a base heal"):format(slot, lull and lull.Name or "nothing"))
	end
	now = tick_()
	bot.lastCombatAt = now - 2
	local fight = S.LR.pickLoot(bot, bot.humanoid, bot.root, S.isUnderArmed(bot), false, nil, nil, now)
	if fight then fail(("restock: slot %d went home for a %s 2 s after a fight"):format(slot, fight.Name)) end
	out.restock[slot + 1] = (lull and 1 or 0)
end

--------------------------------------------------------------------------------
-- field: loot away from home is unchanged
--------------------------------------------------------------------------------
stockBase()
local field = base + Vector3.new(600, 0, 0)
part("HealPickup", field + Vector3.new(30, 0, 0), { HealId = "Bandage", ItemId = "Bandage", Amount = 2 })
local fieldTaken, fieldWanted = 0, 0
for slot = 0, 5 do
	local bot = freshBot(500 + slot, field)
	bot.slot, bot.team, bot.lastCombatAt = slot, 1, -1000
	K.spawnKit(bot, bot.humanoid, bot.character)
	if S.LR.healCount(bot) < S.LR.dial(bot, "healStockTarget") then
		fieldWanted = fieldWanted + 1
		local item = S.LR.bestConsumable(bot, bot.root.Position, S.LR.STOCK_RANGE, nil, nil, tick_())
		if item and item.Name == "HealPickup" then fieldTaken = fieldTaken + 1 end
	end
end
out.counts.fieldWanted, out.counts.fieldTaken = fieldWanted, fieldTaken
if fieldWanted == 0 or fieldTaken ~= fieldWanted then fail(("field: %d of %d short kitted bots took a heal 30 studs away, away from home"):format(fieldTaken, fieldWanted)) end

lazy = realLazy
return out
"""


def run(root, sources):
    """sources: the four files' text (planted faults edit these). Returns (failures, report)."""
    lua = LuaRuntime(unpack_returned_tuples=True)
    shared = lua.table()
    for file in os.listdir(os.path.join(root, sim.SHARED)):
        if file.endswith(".lua"):
            shared[file[:-4]] = sim.luau_to_lua(read(root, os.path.join(sim.SHARED, file)))
    shared["GameModes"] = sim.luau_to_lua(sources[GAMEMODES])
    anchor = "return { runMatch = runMatch,"
    assert anchor in sim.WORLD, "bot_kit_check: bot_loot_sim's WORLD return moved"
    world_src = sim.WORLD.replace(anchor, "return { S = S, newBot = newBot, runMatch = runMatch,", 1)
    world = lua.execute(sim.perf.PRELUDE + "\nreturn function(...) " + world_src + " end")(root, sim.slices(sources[BOTSERVICE]), shared, 7)
    world.env.newBotFn = world.newBot
    S = world.S
    S.LR = world.LR
    check = lua.execute("return function(env, src, ...) return assert(load(src, 'check', 't', env))(...) end")
    out = check(world.env, CHECK, S, kit_source(sources[BOTSERVICE], sources[GAMEMODE], sources[MODETEAMS]),
                gear_source(sources[BOTSERVICE]), ROLLS)
    fails = [out.fails[i] for i in range(1, len(out.fails) + 1)]
    return (out.nfail or 0), fails, out


# Each aimed at an invariant the kit or the no-base-loot rule must hold forever, not at today's bug.
PLANTS = [
    ("an explosive count of 3", GAMEMODES, '{ "CookedCoconut", "ClingyCrumpet" }, kinds = 1, count = 2',
     '{ "CookedCoconut", "ClingyCrumpet" }, kinds = 1, count = 3'),
    ("a Rot Mine (no bot thrower) in the explosive pool", GAMEMODES, '{ "CookedCoconut", "ClingyCrumpet" }',
     '{ "CookedCoconut", "ClingyCrumpet", "RotMine" }'),
    ("the Brainrot Fortress (stacks to 1) in the defense pool", GAMEMODES, '{ "RotBarricade", "PopupBunker" }',
     '{ "RotBarricade", "PopupBunker", "BrainrotFortress" }'),
    ("a Launch Pad (no bot use) in the movement pool", GAMEMODES, '{ "RotRocket" }', '{ "RotRocket", "LaunchPad" }'),
    ("two movement items", GAMEMODES, '{ ids = { "RotRocket" }, kinds = 1, count = 1 }', '{ ids = { "RotRocket" }, kinds = 1, count = 2 }'),
    ("3 Bandages", GAMEMODES, '{ id = "Bandage", count = 2 },\n\t},\n\tpools = {\n\t\t{ ids = { "CookedCoconut"',
     '{ id = "Bandage", count = 3 },\n\t},\n\tpools = {\n\t\t{ ids = { "CookedCoconut"'),
    ("bots handed the players' kit", GAMEMODE, "GameModes.RollLoadout(nil, GameModes.BotLoadout)", "GameModes.RollLoadout()"),
    ("no gun in the bot kit", GAMEMODE, "return ModeTeams.RollGreenWeapon(), GameModes.RollLoadout", "return nil, GameModes.RollLoadout"),
    ("the gear phase back on for kitted bots", BOTSERVICE, "bot.gearUntil = not bot.kitHeals and now + (MatchConfig.BotBaseGearSeconds or 30) or nil",
     "bot.gearUntil = now + (MatchConfig.BotBaseGearSeconds or 30)"),
    ("base chests wanted by a kitted bot", BOTSERVICE, "wanted = not kitted", "wanted = true"),
    ("base guns wanted by a kitted bot", BOTSERVICE, "\t\t\t\telseif not kitted then\n", "\t\t\t\telse\n"),
    ("bestConsumable taking from home", BOTSERVICE, "\t\t\t\tand not (home and flatDistance(entry.position, home) <= homeRadius)\n", ""),
    ("the kit flag never set", BOTSERVICE, [("\t\t\t\t\tbot.kitHeals = 0\n", ""),
                                            ("\t\t\t\t\t\t\t\tbot.kitHeals = BotService.Loot.healCount(bot)\n", "")]),
    ("the kit stacked on the BR's random starting Bandage", BOTSERVICE, "\t\t\t\t\tbot.heals.Bandage, bot.heals.MedKit = 0, 0\n", ""),
    ("the heal restock gone", BOTSERVICE, "wantHeals = (bot.heals.Bandage + bot.heals.MedKit) < bot.kitHeals", "wantHeals = false"),
    ("a restock at a full kit", BOTSERVICE, "wantHeals = (bot.heals.Bandage + bot.heals.MedKit) < bot.kitHeals",
     "wantHeals = (bot.heals.Bandage + bot.heals.MedKit) <= bot.kitHeals"),
]


def main():
    args = sys.argv[1:]
    root = next((a for a in args if not a.startswith("-")), ".")
    sources = {path: read(root, path) for path in (BOTSERVICE, GAMEMODE, MODETEAMS, GAMEMODES)}
    if "--plant" in args:
        caught = 0
        for plant in PLANTS:
            name, path = plant[0], plant[1]
            pairs = plant[2] if len(plant) == 3 else [(plant[2], plant[3])]
            planted = dict(sources)
            for old, new in pairs:
                assert planted[path].count(old) == 1, "bot_kit_check: plant anchor not unique/found: " + name
                planted[path] = planted[path].replace(old, new, 1)
            try:
                nfail, fails, _ = run(root, planted)
                note = fails[0] if fails else ""
            except Exception as err:  # a plant that breaks the harness counts as caught, and says so
                nfail, note = 1, "harness error: " + str(err).splitlines()[0]
            ok = nfail > 0
            caught += ok
            print("  %s  %s%s" % ("CAUGHT" if ok else "MISSED", name, ("  (" + note + ")") if ok else ""))
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)

    nfail, fails, out = run(root, sources)
    seen = out.seen
    counts = out.counts
    ids = sorted(seen.keys(), key=str)
    print("kit: %d rolls through GameMode's hook and BotService's spawn handler" % ROLLS)
    print("  ids drawn (times): " + ", ".join("%s %d" % (i, seen[i]) for i in ids))
    print("base: %d base items (14 chests, 6 Rare guns, 4 Bandages, 2 shields, 3 Cooked Coconuts); %d fresh kitted bots,"
          " %d gear-phase thinks examined; %d unkitted control bots" % (counts.baseItems, counts.kittedBots,
                                                                       counts.gearThinks or 0, counts.controlBots))
    print("  unkitted control bots that targeted base loot, per path: " + ", ".join(
        "%s %d/%d" % (p, out.control[p] or 0, counts.controlBots) for p in ("gear phase", "FindBaseLoot", "bestConsumable", "pickLoot")))
    print("restock: %d of 6 kitted bots one Bandage down went home for a heal in a lull" % sum(out.restock[i] for i in range(1, 7)))
    print("field: %d of %d short kitted bots away from home took a heal" % (counts.fieldTaken, counts.fieldWanted))
    for f in fails:
        print("  FAIL " + f)
    if nfail:
        print("bot_kit_check: %d failure(s)" % nfail)
        sys.exit(1)
    print("bot_kit_check: OK (kit shape %d/%d rolls, no base target from a fresh kitted bot on any path)" % (ROLLS, ROLLS))


if __name__ == "__main__":
    main()
