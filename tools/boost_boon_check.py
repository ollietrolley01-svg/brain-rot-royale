"""Behaviour check for the match-start boosts and the companion health boon, without Studio.

    python3 tools/boost_boon_check.py .            the checks
    python3 tools/boost_boon_check.py . --plant    the planted faults; every one must be caught

Runs the real source in lupa, with the rest of the game mocked:

  plan     GamepassConfig.PlanBoosts (the REAL module): a one-match boost is spent only when it beats
           what the player already has, and the bigger of pass and boost applies. A pass owner still
           gets the Pro Bundle's Pro boosts (2x health beats the pass's +50, 1.5x speed beats its +4)
           and keeps a regular boost that would add nothing. GamepassConfig.Outclassed hides a
           one-match product a permanent pass makes useless, not one a day-long Daily Spin pass does,
           and MenuClient's product list asks it.
  spawn    MatchService's applyBoosts / reapplyBoosts, cut from the source: they spend what the plan
           says, and add back the max health a companion's boon already put on the body.
  boon     CompanionBoons (the REAL module): the grant is tracked on the Humanoid it went on, so the
           same companion re-applied to the same body changes nothing, a respawn's new body gets it,
           and Clear takes it off the body that had it.
  trade    CompanionService (the REAL module, in tools/companion_ability_check.py's world): a completed
           trade (RefreshAll) sends home only the companion that left its owner's collection, and
           leaves everyone else's -- and their boon -- alone; re-equipping the same companion keeps
           the boon on (no Clear).

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("boost_boon_check: needs lupa (pip install lupa)")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import companion_ability_check as cac  # noqa: E402

GAMEPASS = "ReplicatedStorage/Shared/GamepassConfig.lua"
MATCH = "ServerScriptService/Modules/MatchService.lua"
MENU = "StarterPlayerScripts/MenuClient.client.lua"
BOONS = "ServerScriptService/Modules/CompanionBoons.lua"
SAFE = "ReplicatedStorage/Shared/SafeValue.lua"
SERVICE = "ServerScriptService/Modules/CompanionService.lua"
DATA = "ReplicatedStorage/Shared/BrainrotData.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()


def spawn_block(match_src):
    """applyBoosts and reapplyBoosts, from `local grantedBoosts` to the end of reapplyBoosts."""
    a = match_src.index("local grantedBoosts = {}")
    b = match_src.index("local function reapplyBoosts(")
    b = match_src.index("\nend\n", b) + 5
    return match_src[a:b]


HARNESS = r"""
local gamepassSrc, spawnSrc, boonsSrc, safeSrc = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
Color3 = { fromRGB = function() return {} end }
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end end

local GP = assert(load(gamepassSrc, "GamepassConfig"))()

-- ---------------------------------------------------------------- plan
local function plan(owns, stock)
    return GP.PlanBoosts(owns, stock, 100, 18)
end
local function spent(p) return table.concat(p.spend, ",") end
local p = plan({}, { HealthPro = 1, Health = 1, SpeedPro = 1, Speed = 1 })
check(p.health == 100 and p.scale == 1.5 and p.speed == 0 and spent(p) == "HealthPro,SpeedPro",
    "no pass, every boost in stock: the Pro pair is spent (health " .. p.health .. ", x" .. p.scale .. ", spent " .. spent(p) .. ")")
p = plan({ ExtraHealth = true, ExtraSpeed = true }, { HealthPro = 2, SpeedPro = 2 })
check(p.health == 100 and p.scale == 1.5 and p.speed == 0 and spent(p) == "HealthPro,SpeedPro",
    "both passes and the Pro pair: the Pro boosts beat the passes and are spent (health " .. p.health .. ", speed +" .. p.speed .. " x" .. p.scale .. ", spent " .. spent(p) .. ")")
p = plan({ ExtraHealth = true, ExtraSpeed = true }, { Health = 3, Speed = 3 })
check(p.health == GP.PassHealth and p.speed == GP.PassSpeed and p.scale == 1 and #p.spend == 0,
    "both passes and the regular pair: nothing is spent, the passes apply (spent '" .. spent(p) .. "')")
p = plan({}, { Health = 1, Speed = 1 })
check(p.health == 50 and p.speed == 4 and spent(p) == "Health,Speed", "no pass, the regular pair: both spent (" .. spent(p) .. ")")
p = plan({ ExtraHealth = true }, {})
check(p.health == GP.PassHealth and #p.spend == 0, "a pass and no stock: the pass alone")
p = plan({}, nil)
check(p.health == 0 and p.speed == 0 and p.scale == 1 and #p.spend == 0, "no profile stock: nothing")

local once = GP.Products.BoostHealthOnce
check(GP.Outclassed(once, { ExtraHealth = true }, {}) == true, "the one-match health boost is hidden from an Iron Sahur owner")
check(GP.Outclassed(once, { ExtraHealth = true }, { ExtraHealth = 3600 }) == false, "...but not from someone with the pass for a day off the spin")
check(GP.Outclassed(once, { ExtraSpeed = true }, {}) == false, "...and not from a Rot Runner owner")
check(GP.Outclassed(GP.Products.BoostSpeedOnce, { ExtraSpeed = true }, {}) == true, "the one-match speed boost is hidden from a Rot Runner owner")
check(GP.Outclassed(GP.Products.ProBundle, { ExtraHealth = true, ExtraSpeed = true }, {}) == false, "the Pro Bundle is never hidden")
check(GP.Outclassed(once, nil, nil) == false, "no profile yet: nothing hidden")

-- ---------------------------------------------------------------- spawn
local owns, boonOn, stock = {}, {}, nil
local pushed = 0
local env = setmetatable({
    GamepassConfig = GP,
    MatchConfig = { StartHealth = 100, BaseWalkSpeed = 18 },
    PlayerData = { Get = function() return stock and { Consumables = stock } or nil end },
    Monetization = { Owns = function(_, key) return owns[key] == true end },
    StateSync = { Push = function() pushed = pushed + 1 end },
    CompanionService = { BoonHealth = function(_, humanoid) return boonOn[humanoid] or 0 end },
    baseSpeeds = {},
    currentEvent = nil,
}, { __index = _G })
local fns = assert(load(spawnSrc .. "\nreturn applyBoosts, reapplyBoosts", "MatchService.spawn", "t", env))
local applyBoosts, reapplyBoosts = fns()
local player = {}
owns = { ExtraHealth = true }
stock = { Health = 1, Speed = 0, HealthPro = 1, SpeedPro = 0 }
local h = { MaxHealth = 100, Health = 100 }
applyBoosts(player, h)
check(stock.HealthPro == 0 and stock.Health == 1 and h.MaxHealth == 200,
    string.format("Iron Sahur owner with a Pro Health boost: it is spent (%d left) and they start on %d, the regular one kept (%d)", stock.HealthPro, h.MaxHealth, stock.Health))
stock = { Health = 1, Speed = 0, HealthPro = 0, SpeedPro = 0 }
h = { MaxHealth = 100, Health = 100 }
applyBoosts(player, h)
check(stock.Health == 1 and h.MaxHealth == 150, string.format("...and next match only the pass: %d max, the regular boost kept (%d)", h.MaxHealth, stock.Health))
-- The companion's boon landed on this body first (+15): the spawn boosts keep it.
owns = {}
stock = { Health = 0, Speed = 0, HealthPro = 0, SpeedPro = 0 }
h = { MaxHealth = 115, Health = 100 }
boonOn[h] = 15
applyBoosts(player, h)
check(h.MaxHealth == 115 and h.Health == 115, string.format("a boon applied before the spawn boosts survives them: %d/%d (want 115/115)", h.Health, h.MaxHealth))
local h2 = { MaxHealth = 115, Health = 115 }
boonOn[h2] = 15
reapplyBoosts(player, h2)
check(h2.MaxHealth == 115, "...and a respawn body's re-applied boosts keep it too: " .. h2.MaxHealth)

-- ---------------------------------------------------------------- boon
local Safe = assert(load(safeSrc, "SafeValue"))()
local statusSpeeds, jumps = {}, {}
local mods = {
    BrainrotData = {}, SafeValue = Safe,
    MovementService = { SetJumpFactor = function(hum, key, f) jumps[hum] = f end },
    CombatService = {}, Combatants = {},
    MatchService = { SetStatusSpeed = function(token, key, f) statusSpeeds[token] = f end },
}
local function node(name) return { Name = name, WaitForChild = function(_, n) return node(n) end } end
local boonEnv = setmetatable({
    game = { GetService = function(_, n) return node(n) end },
    require = function(m) return assert(mods[m.Name], "no mock for " .. tostring(m.Name)) end,
    typeof = function(x) return type(x) == "table" and "Instance" or type(x) end,
}, { __index = _G })
local Boons = assert(load(boonsSrc, "CompanionBoons", "t", boonEnv))()
local function body()
    local hum = { MaxHealth = 100, Health = 100 }
    return { FindFirstChildOfClass = function() return hum end }, hum
end
local owner = { SetAttribute = function() end, IsA = function() return true end }
local def = { name = "Tank", boon = { health = 15 } }
local c1, hum1 = body()
owner.Character = c1
Boons.Apply(owner, def)
check(hum1.MaxHealth == 115 and hum1.Health == 100, string.format("the boon raises max health only: %d/%d", hum1.Health, hum1.MaxHealth))
hum1.Health = 90
Boons.Apply(owner, def)
check(hum1.MaxHealth == 115 and hum1.Health == 90, string.format("the same companion re-applied to the same body changes nothing: %d/%d", hum1.Health, hum1.MaxHealth))
check(Boons.GrantedHealth(owner, hum1) == 15, "GrantedHealth names the body's grant: " .. tostring(Boons.GrantedHealth(owner, hum1)))
local c2, hum2 = body()
owner.Character = c2
Boons.Apply(owner, def)
check(hum2.MaxHealth == 115 and hum2.Health == 100, string.format("a respawn's new body is granted the boon: %d/%d", hum2.Health, hum2.MaxHealth))
check(hum1.MaxHealth == 100, "...and it came off the old body, not twice off the new one: old max " .. hum1.MaxHealth)
check(Boons.GrantedHealth(owner, hum1) == 0, "the old body has no grant any more")
Boons.Clear(owner)
check(hum2.MaxHealth == 100 and hum2.Health == 100, string.format("Clear takes it off the body that had it: %d/%d", hum2.Health, hum2.MaxHealth))
-- Clear after a respawn it never saw: the grant stays with the old body, the new one is untouched.
Boons.Apply(owner, def)
local c3, hum3 = body()
owner.Character = c3
Boons.Clear(owner)
check(hum3.MaxHealth == 100 and hum3.Health == 100, string.format("Clear after a respawn leaves the new body alone: %d/%d", hum3.Health, hum3.MaxHealth))
return out
"""

TRADE = r"""
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local mods = _G.mods
local clears, applies = {}, {}
mods.CompanionBoons.Clear = function(p) clears[p.Name] = (clears[p.Name] or 0) + 1 end
mods.CompanionBoons.Apply = function(p) applies[p.Name] = (applies[p.Name] or 0) + 1 end
local first, second = BrainrotData.Types[1].name, BrainrotData.Types[2].name
local giver = makeCombatant("Giver", true, 0)
giver.data = { Companion = first, Brainrots = { first }, CompanionXp = {}, Stars = {} }
local taker = makeCombatant("Taker", true, 60)
taker.data = { Companion = nil, Brainrots = {}, CompanionXp = {}, Stars = {} }
local bystander = makeCombatant("Bystander", true, 120)
bystander.data = { Companion = second, Brainrots = { second }, CompanionXp = {}, Stars = {} }
CS.Refresh(giver)
CS.Refresh(bystander)
check(CS.ModelOf(giver) ~= nil and CS.ModelOf(bystander) ~= nil, "both companions are out before the trade")
for k in pairs(clears) do clears[k] = nil end
for k in pairs(applies) do applies[k] = nil end
-- The trade: the giver's companion goes to the taker.
table.remove(giver.data.Brainrots, 1)
table.insert(taker.data.Brainrots, first)
CS.RefreshAll()
check(CS.ModelOf(giver) == nil and (clears.Giver or 0) == 1, string.format("the traded-away companion goes home and its boon comes off (clears %d)", clears.Giver or 0))
check(clears.Bystander == nil and applies.Bystander == nil,
    string.format("a bystander's companion is not touched by someone else's trade (clears %d, applies %d)", clears.Bystander or 0, applies.Bystander or 0))
check(CS.ModelOf(bystander) ~= nil, "...and is still out")
-- Re-equipping the same companion: respawned, but the boon stays on (no Clear), Apply's guard keeps it.
CS.Refresh(bystander)
check(clears.Bystander == nil and applies.Bystander == 1,
    string.format("re-equipping the same companion keeps the boon on: clears %d, applies %d", clears.Bystander or 0, applies.Bystander or 0))
bystander.data.Companion = first
table.insert(bystander.data.Brainrots, first)
CS.Refresh(bystander)
check((clears.Bystander or 0) == 1, "swapping to a different companion clears the old boon: clears " .. tostring(clears.Bystander or 0))
return out
"""


def run(sources):
    rows = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        result = lua.execute(HARNESS, luau_to_lua(sources[GAMEPASS]), luau_to_lua(spawn_block(sources[MATCH])),
                             luau_to_lua(sources[BOONS]), luau_to_lua(sources[SAFE]))
        rows += [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        rows.append((False, "plan/spawn/boon harness crashed: %s" % exc))
    menu = sources[MENU]
    rows.append(("GamepassConfig.Outclassed(product, profile and profile.ownedPasses, profile and profile.tempPasses)" in menu,
                 "MenuClient's product list hides what GamepassConfig.Outclassed says a pass makes useless"))
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        lua.execute(cac.PRELUDE)
        lua.execute("function _run(h, a, b) return load(h, 'harness')(a, b) end")
        harness = cac.SERVICE_HARNESS.replace("local mods = {}\n", "local mods = {}\n_G.mods = mods\n", 1)
        assert "_G.mods = mods" in harness, "companion_ability_check's world changed shape"
        lua.globals()._run(harness, luau_to_lua(sources[DATA]), luau_to_lua(sources[SERVICE]))
        result = lua.execute(TRADE)
        rows += [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:
        rows.append((False, "trade harness crashed: %s" % exc))
    return rows


def plant(sources, rel, old, new):
    assert sources[rel].count(old) == 1, (rel, old)
    planted = dict(sources)
    planted[rel] = sources[rel].replace(old, new)
    return planted


PLANTS = [
    ("a Pro Health boost is never spent by a pass owner (the old rule)", GAMEPASS,
     "and startHealth > plan.health then", "and plan.health == 0 then"),
    ("a Pro Speed boost is never spent by a pass owner (the old rule)", GAMEPASS,
     "and baseSpeed * 1.5 > current then", "and plan.speed == 0 then"),
    ("a regular boost spent on top of an equal pass", GAMEPASS,
     "and GamepassConfig.PassHealth > plan.health then", "then"),
    ("a day-long spin pass hides the product for good", GAMEPASS,
     " and not (temp and temp[pass])", ""),
    ("the shop sells a boost the pass makes useless", MENU,
     "\n\t\t\tand not GamepassConfig.Outclassed(product, profile and profile.ownedPasses, profile and profile.tempPasses) then",
     " then"),
    ("the spawn boosts wipe a boon applied first", MATCH,
     "humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth + CompanionService.BoonHealth(player, humanoid)\n\thumanoid.Health = humanoid.MaxHealth\n\n",
     "humanoid.MaxHealth = MatchConfig.StartHealth + bonusHealth\n\thumanoid.Health = humanoid.MaxHealth\n\n"),
    ("Clear takes the grant off whatever body the player has now", BOONS,
     "\tlocal humanoid = state.humanoid\n\tif humanoid then", "\tlocal humanoid = humanoidOf(player)\n\tif humanoid then"),
    ("Apply's guard ignores the body (a respawn keeps no boon)", BOONS,
     "if existing and existing.def == def and existing.humanoid == humanoid then", "if existing and existing.def == def then"),
    ("every trade respawns every companion on the server", SERVICE,
     "\t\tif data and not table.find(data.Brainrots, entry.def.name) then\n\t\t\tCompanionService.Refresh(player)\n\t\tend",
     "\t\tCompanionService.Refresh(player)"),
    ("spawnFor always clears the boon (re-equip costs HP)", SERVICE,
     "despawn(player, character ~= nil and owned and not fallen[player] and current ~= nil and current.def == def)",
     "despawn(player)"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: read(root, rel) for rel in (GAMEPASS, MATCH, MENU, BOONS, SAFE, SERVICE, DATA)}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            failed = [line for ok, line in run(plant(sources, rel, old, new)) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"boost_boon_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = run(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"boost_boon_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
