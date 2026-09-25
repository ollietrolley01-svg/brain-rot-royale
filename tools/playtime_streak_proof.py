"""Independent check of the playtime awards (#76) and the daily streak prize (#77), without Studio.

Runs the REAL code in a Lua interpreter (lupa), with only what it calls out to mocked:
  - ServerScriptService/Modules/PlaytimeService.lua, whole
  - ServerScriptService/Modules/BattlePassService.lua, whole (ClaimDaily and applyReward)
  - ReplicatedStorage/Shared/ProgressionData.lua's Playtime block, BattlePassData.lua and DailySpinData.lua, whole
  - CrateData.Crates (cut from CrateData.lua), so a streak crate must name a crate that exists
  - Monetization.EarnCoins and RewardService.AddCoins / AwardBonusCoins, cut verbatim from their files
  - StateSync's three nextDailyIndex lines, cut verbatim, so the day the menu promises is the real one

It is a second, separate check next to tools/playtime_check.py, not a replacement. The difference that
matters: playtime_check's #77 check recomputes the day formula in Python and never runs ClaimDaily,
so it cannot fail when ClaimDaily changes. Every #77 check here runs ClaimDaily.

    python tools/playtime_streak_proof.py .           checks, then measured facts
    python tools/playtime_streak_proof.py . --plant   every planted fault must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("playtime_streak_proof: needs lupa (pip install lupa)")


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def luau_to_lua(source):
    # x += y / x -= y -> plain Lua (the only Luau-only syntax these files use)
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def cut_function(text, header):
    """A top-level function, from its header to the `end` at column 0 that closes it."""
    start = text.index(header)
    end = text.index("\nend\n", start) + len("\nend\n")
    return text[start:end]


def sources(root):
    shared = ("ReplicatedStorage", "Shared")
    modules = ("ServerScriptService", "Modules")
    progression = read(root, *shared, "ProgressionData.lua")
    start = progression.index("ProgressionData.Playtime = {")
    playtime_block = "local ProgressionData = {}\n" + progression[start:progression.index("return ProgressionData", start)] \
        + "return ProgressionData\n"

    crate = read(root, *shared, "CrateData.lua")
    crate_block = "local CrateData = {}\n" + crate[crate.index("CrateData.Crates = {"):crate.index("\n}\n", crate.index("CrateData.Crates = {")) + 3] \
        + "\nfunction CrateData.Get(tier) return CrateData.Crates[tier] end\nreturn CrateData\n"

    state = read(root, *modules, "StateSync.lua")
    s = state.index("\tlocal streakLive = ")
    e = state.index("\n", state.index("\tlocal nextDailyIndex = ", s))
    next_index = "return function(data, StateSync, BattlePassData)\n" + state[s:e] + "\n\treturn nextDailyIndex\nend\n"

    monetization = read(root, *modules, "Monetization.lua")
    reward = read(root, *modules, "RewardService.lua")
    return {
        "ProgressionData": playtime_block,
        "BattlePassData": read(root, *shared, "BattlePassData.lua"),
        "DailySpinData": luau_to_lua(read(root, *shared, "DailySpinData.lua")),
        "CrateData": crate_block,
        "PlaytimeService": luau_to_lua(read(root, *modules, "PlaytimeService.lua")),
        "BattlePassService": luau_to_lua(read(root, *modules, "BattlePassService.lua")),
        "EarnCoins": luau_to_lua(cut_function(monetization, "function Monetization.EarnCoins(")),
        "RewardFns": cut_function(reward, "function RewardService.AddCoins(")
                     + cut_function(reward, "function RewardService.AwardBonusCoins("),
        "NextIndex": next_index,
    }


HARNESS = r"""
local SRC = ...
local function load_src(name) return assert(load(SRC[name], "=" .. name))() end

-- Roblox stand-ins -------------------------------------------------------------------------------
math.clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }
local Vec = {}
Vec.__index = Vec
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }, Vec) end
Vec.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end

local added, removing, playerList, loops = {}, {}, {}, {}
local function signal(list) return { Connect = function(_, fn) table.insert(list, fn) end } end
local Players = { PlayerAdded = signal(added), PlayerRemoving = signal(removing), GetPlayers = function() return playerList end }
local function child(name) return { Name = name, WaitForChild = function(_, n) return child(n) end } end
game = { GetService = function(_, name) if name == "Players" then return Players end return child(name) end }
script = { Parent = child("Modules") }
task = { spawn = function(fn) table.insert(loops, coroutine.create(fn)) end, wait = function() coroutine.yield() end }
warn = function(...) error(table.concat({ ... }, " ")) end

-- The world the real code reads ------------------------------------------------------------------
local W = { today = 20000, profiles = {}, notes = {}, crates = {}, owns = {} }

local PlayerData = { Get = function(player) return W.profiles[player] end }
local GamepassConfig = { Passes = { CoinBoost = { multiplier = 2 } } }
local Monetization = {
    Owns = function(player, key) return W.owns[key] == true end,
    GetPasses = function() return {} end,
    TempRemaining = function() return nil end,
}
local StateSync = {
    CurrentDay = function() return W.today end,
    Push = function() end,
    Notify = function(player, message) table.insert(W.notes, message) end,
}
local CrateData = load_src("CrateData")
local CrateService = {
    Give = function(player, tier, amount)
        local data = PlayerData.Get(player)
        if not data or not CrateData.Get(tier) then return false end
        table.insert(W.crates, tier)
        data.Crates[tier] = (data.Crates[tier] or 0) + (amount or 1)
        return true
    end,
}
local RewardService = {}
local stubs = {
    PlayerData = PlayerData, GamepassConfig = GamepassConfig, Monetization = Monetization, StateSync = StateSync,
    CrateService = CrateService, RewardService = RewardService, CrateData = CrateData,
    BrainrotData = {}, CosmeticData = { Get = function() return nil end, OfKind = function() return {} end },
    Rarity = { Roll = function() return "Common" end },
}
local loaded = {}
require = function(inst)
    local name = inst.Name
    if stubs[name] then return stubs[name] end
    if not loaded[name] then loaded[name] = load_src(name) end
    return loaded[name]
end
-- The real EarnCoins / AddCoins / AwardBonusCoins, verbatim, with these upvalues in scope.
assert(load("local PlayerData, GamepassConfig = ...\nlocal Monetization = select(3, ...)\n" .. SRC.EarnCoins,
    "=EarnCoins"))(PlayerData, GamepassConfig, Monetization)
assert(load("local StateSync, Monetization = ...\nlocal RewardService = select(3, ...)\n" .. SRC.RewardFns,
    "=RewardService"))(StateSync, Monetization, RewardService)

local ProgressionData = require(child("ProgressionData"))
local BattlePassData = require(child("BattlePassData"))
local BattlePassService = require(child("BattlePassService"))
local PlaytimeService = require(child("PlaytimeService"))
local nextIndex = assert(load(SRC.NextIndex, "=StateSync.nextDailyIndex"))()

local function profile()
    -- The fields of PlayerData.defaultData that ClaimDaily and EarnCoins touch, at their defaults.
    return { SahurCoins = 0, Daily = { lastClaimDay = 0, streak = 0 }, Crates = {}, FreeCrates = {},
             Cosmetics = { owned = {} }, Brainrots = {}, TempPasses = {}, Pass = { xp = 0 } }
end

local api = { W = W }
function api.cfg() return ProgressionData.Playtime end
function api.rewards() return BattlePassData.DailyRewards end

-- #76 --------------------------------------------------------------------------------------------
-- A player's `path(step)` gives their root position at each check (a {x,y,z} list), or nil for no
-- living character. `loaded == false` means no profile yet.
function api.join(name, path, loaded)
    local p = { Name = name, Parent = true, step = 0, path = path, paid = {} }
    if loaded ~= false then W.profiles[p] = profile() end
    table.insert(playerList, p)
    for _, fn in ipairs(added) do fn(p) end
    return p
end
function api.leave(p)
    for _, fn in ipairs(removing) do fn(p) end
    p.Parent = nil
    for i, q in ipairs(playerList) do if q == p then table.remove(playerList, i) break end end
end
function api.start()
    PlaytimeService.Start()
    for _, co in ipairs(loops) do assert(coroutine.resume(co)) end
end
function api.run(samples)
    for _ = 1, samples do
        for _, p in ipairs(playerList) do
            p.step = p.step + 1
            local at = p.path(p.step)
            if at == nil then
                p.Character = nil
            else
                local root = { Position = vec(at[0], at[1], at[2]) }  -- a Python list, indexed from 0
                local hum = { Health = 100 }
                p.Character = {
                    FindFirstChildOfClass = function(_, c) if c == "Humanoid" then return hum end end,
                    FindFirstChild = function(_, c) if c == "HumanoidRootPart" then return root end end,
                }
            end
            p.before = W.profiles[p] and W.profiles[p].SahurCoins or 0
        end
        for _, co in ipairs(loops) do
            local ok, err = coroutine.resume(co)
            if not ok then error(err) end
        end
        for _, p in ipairs(playerList) do
            local now = W.profiles[p] and W.profiles[p].SahurCoins or 0
            if now ~= p.before then table.insert(p.paid, now - p.before) end
        end
    end
end
function api.paid(p) return p.paid end
function api.load(p) W.profiles[p] = profile() end
-- How many players the service still holds (its `sessions` upvalue, found by name).
function api.held()
    for i = 1, 60 do
        local name, value = debug.getupvalue(PlaytimeService.Start, i)
        if name == nil then break end
        if name == "sessions" then
            local n = 0
            for _ in pairs(value) do n = n + 1 end
            return n
        end
    end
    error("PlaytimeService.Start has no `sessions` upvalue")
end

-- #77 --------------------------------------------------------------------------------------------
local claimer = { Name = "claimer", Parent = true }
function api.newClaimer() W.profiles[claimer] = profile() end
function api.setDay(d) W.today = d end
-- One real ClaimDaily with the wheel forced onto its first segment. Returns ok, message, the coins and
-- crates it paid, the day index the menu promised just before, and the streak after.
function api.claim(randomValue)
    local data = W.profiles[claimer]
    local promised = nextIndex(data, StateSync, BattlePassData)
    local coins0, crates0 = data.SahurCoins, #W.crates
    local realRandom = math.random
    math.random = function(...) if select("#", ...) == 0 then return randomValue or 0.1 end return realRandom(...) end
    local ok, message, segment = BattlePassService.ClaimDaily(claimer)
    math.random = realRandom
    local crates = {}
    for i = crates0 + 1, #W.crates do table.insert(crates, W.crates[i]) end
    return ok, message, data.SahurCoins - coins0, crates, promised, data.Daily.streak, segment
end
function api.spinCoins(streak)
    local DailySpinData = require(child("DailySpinData"))
    local seg = DailySpinData.Segments[1]
    assert(seg.kind == "Coins", "the wheel's first segment is no longer coins; pick another forced segment")
    return math.floor(seg.amount * DailySpinData.StreakMultiplier(streak))
end
function api.claimerKeys()
    local out = {}
    local function walk(t, prefix)
        for k, v in pairs(t) do
            local path = prefix .. tostring(k)
            if type(v) == "table" then walk(v, path .. ".") else table.insert(out, path) end
        end
    end
    walk(W.profiles[claimer], "")
    table.sort(out)
    return table.concat(out, " ")
end
return api
"""


def build(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(HARNESS, lua.table_from(src))


def walk(stride=10.0):
    """A root that moves `stride` studs every check."""
    return lambda step: [stride * step, 0, 0]


def pattern(active_every, of, skip_first=False):
    """Moves 10 studs on `active_every` of every `of` checks, stands still otherwise. With skip_first,
    the first check of each block stands still, so every block counts exactly `active_every` moves
    (a stretch's first check compares with the previous stretch's last, or with nothing)."""
    lo = 1 if skip_first else 0
    def path(step):
        moves = sum(1 for s in range(1, step + 1) if lo <= (s - 1) % of < lo + active_every)
        return [10.0 * moves, 0, 0]
    return path


def playtime_checks(src):
    """#76 invariants and measured facts. Returns (checks, facts); each is (name, ok|None, detail)."""
    api = build(src)
    cfg = api.cfg()
    per = cfg.IntervalSeconds // cfg.SampleSeconds
    checks, facts = [], []

    # Boundary: exactly MinActiveSamples-1 moving checks in each stretch never pays; exactly Min does.
    # Pattern repeats every stretch; +1 because the first check of a visit has nothing to compare to.
    under = api.join("under", pattern(cfg.MinActiveSamples - 1, per, skip_first=True))
    at_min = api.join("atmin", pattern(cfg.MinActiveSamples, per, skip_first=True))
    runner = api.join("runner", walk())
    macro = api.join("macro", lambda s: [cfg.MoveStuds * (s % 2), 0, 0])        # 4 studs back and forth
    shy = api.join("shy", lambda s: [(cfg.MoveStuds - 0.1) * (s % 2), 0, 0])    # 3.9 studs back and forth
    rider = api.join("rider", lambda s: [0, 0, 60.0 * s])                          # seated, carried 60 studs
    third = api.join("third", pattern(1, 3))                                        # 1 check in 3 moves
    halfway = api.join("half", pattern(1, 2))                                       # 1 check in 2 moves
    diver = api.join("diver", lambda s: [10.0 * s, 0, 0] if (s - 1) // per != 3 else None)  # dead for stretch 4
    nosave = api.join("nosave", walk(), False)
    api.start()
    api.run(per * 2)
    api.load(nosave)   # the profile arrives at 20 minutes
    api.run(per * 10)  # two hours in all

    paid = {p.Name: list(api.paid(p).values()) for p in (under, at_min, runner, macro, shy, rider, third, halfway, diver, nosave)}
    checks.append(("a stretch one check short of MinActiveSamples pays nothing",
                   paid["under"] == [],
                   f"{cfg.MinActiveSamples - 1} of {per} every stretch -> {len(paid['under'])} awards in 12 stretches"))
    checks.append(("a stretch with exactly MinActiveSamples pays",
                   len(paid["atmin"]) == 12 and paid["atmin"][0] == 50,
                   f"{cfg.MinActiveSamples} of {per} -> {len(paid['atmin'])} awards in 12 stretches"))
    capped = paid["runner"]
    checks.append(("never more than one award per IntervalSeconds, never above CapCoins",
                   len(capped) == 12 and max(capped) == cfg.CapCoins and sum(capped) == 675 + 1200,
                   f"{len(capped)} awards in 2 h: {capped}, total {sum(capped)}"))
    checks.append(("a player moving in 1 check of 3 is never paid", paid["third"] == [], f"{paid['third']}"))

    # Leaks: 300 visits that join and leave mid-stretch leave nothing behind.
    held_before = api.held()
    for i in range(300):
        p = api.join(f"visitor{i}", walk())
        api.run(1 + i % per)
        api.leave(p)
    checks.append(("a player who leaves is dropped", api.held() == held_before,
                   f"held {held_before} before 300 join/leave visits, {api.held()} after"))

    # Rejoin: the ladder and the part-done stretch both start over.
    api2 = build(src)
    api2.start()
    first = api2.join("hopper", walk())
    api2.run(per * 7 + per - 1)     # 7 awards, then 19 of 20 checks of the 8th stretch
    before_leave = list(api2.paid(first).values())
    api2.leave(first)
    again = api2.join("hopper", walk())  # Roblox hands a rejoining player a new Player object
    api2.run(per)
    facts.append(("a rejoin restarts the ladder and loses the part-done stretch", None,
                  f"visit 1 paid {before_leave} then left 1 check before its 8th award (200); "
                  f"visit 2's first award after {per} checks: {list(api2.paid(again).values())}"))
    facts.append(("walking into a wall / standing still", None, "position does not change, so 0 (playtime_check 'statue')"))
    facts.append(("a macro moving exactly MoveStuds back and forth", None, f"{sum(paid['macro'])} coins in 2 h"))
    facts.append(("the same macro at MoveStuds - 0.1", None, f"{sum(paid['shy'])} coins in 2 h"))
    facts.append(("seated, carried 60 studs a check (vehicle, moving platform)", None, f"{sum(paid['rider'])} coins in 2 h"))
    facts.append(("moving in 1 check of 2", None, f"{sum(paid['half'])} coins in 2 h"))
    facts.append(("dead for the whole 4th stretch, then playing again", None,
                  f"{paid['diver']} (the dead stretch pays nothing; the ladder does not reset)"))
    facts.append(("no profile for the first 20 minutes", None,
                  f"{paid['nosave']}: the first coins landed are {paid['nosave'][0] if paid['nosave'] else None}, "
                  f"not 50; the ladder climbed while nothing could be paid"))
    return checks, facts


def streak_checks(src):
    api = build(src)
    rewards = [dict(r.items()) for r in api.rewards().values()]
    cycle = len(rewards)
    checks = []

    # Walk 2 cycles + 1 day, one claim a UTC day.
    api.newClaimer()
    keys_before = api.claimerKeys()
    day = 20000
    got, promised_ok, detail = [], True, []
    for n in range(1, 2 * cycle + 2):
        api.setDay(day + n)
        ok, message, coins, crates, promised, streak, _ = api.claim()
        entry = rewards[(n - 1) % cycle]
        bonus_coins = coins - api.spinCoins(streak)
        want_coins = entry["amount"] if entry["kind"] == "Coins" else 0
        want_crates = [entry["crate"]] if entry["kind"] == "Crate" else []
        good = ok and streak == n and bonus_coins == want_coins and list(crates.values()) == want_crates
        got.append(good)
        promised_ok = promised_ok and promised == (n - 1) % cycle + 1
        detail.append(f"d{n}:" + (f"+{bonus_coins}" if bonus_coins else "") + "".join(crates.values()))
    checks.append(("day N of an unbroken streak pays table entry (N-1)%7+1 on top of the wheel",
                   all(got), " ".join(detail)))
    checks.append(("the day the menu promises (StateSync nextIndex) is the day ClaimDaily pays",
                   promised_ok, f"{2 * cycle + 1} claims compared"))

    # Same day twice, and a clock that reads a day earlier: refused, nothing paid.
    ok2, msg2, coins2, crates2, *_ = api.claim()
    api.setDay(day + 2 * cycle)
    ok3, msg3, coins3, crates3, *_ = api.claim()
    checks.append(("a second claim on the same UTC day, or an earlier one, pays nothing",
                   not ok2 and coins2 == 0 and len(crates2) == 0 and not ok3 and coins3 == 0 and len(crates3) == 0,
                   f"same day: {ok2} '{msg2}' {coins2} coins; day before: {ok3} {coins3} coins"))

    # A missed day: back to day 1, and the menu said so before the claim.
    api.setDay(day + 2 * cycle + 1 + 2)
    ok4, _, coins4, crates4, promised4, streak4, _ = api.claim()
    checks.append(("a missed day restarts the streak at day 1 and pays entry 1",
                   ok4 and streak4 == 1 and promised4 == 1 and coins4 - api.spinCoins(1) == rewards[0].get("amount", 0),
                   f"streak {streak4}, menu promised day {promised4}, bonus {coins4 - api.spinCoins(1)}"))

    # Every entry: a kind applyReward pays, well-formed, and a crate CrateData knows.
    kinds = {"Coins", "Crate", "Cosmetic"}
    bad = [r for r in rewards if r["kind"] not in kinds
           or (r["kind"] == "Coins" and not (isinstance(r.get("amount"), int) and r["amount"] > 0))]
    checks.append(("every DailyRewards entry is well-formed and pays (types, amounts, crates)",
                   not bad and all(got[:cycle]),
                   f"{cycle} entries examined; ill-formed: {bad or 'none'}; each paid on its day: {all(got[:cycle])}"))

    # Additive: a brand-new profile gains no field it did not already have (except crate counts it won).
    keys_after = api.claimerKeys()
    new = sorted(set(keys_after.split()) - set(keys_before.split()))
    unexpected = [k for k in new if not re.match(r"^(Free)?Crates\.\w+$", k)]
    checks.append(("a claim writes no field a default profile lacks (crate counts aside)",
                   not unexpected, f"new paths: {new}"))
    return checks


PLANTS = [
    # (label, file key, old, new)
    ("#77 the streak day shifted by one", "BattlePassService",
     "local dayIndex = (data.Daily.streak - 1) % BattlePassData.DailyCycle + 1",
     "local dayIndex = data.Daily.streak % BattlePassData.DailyCycle + 1"),
    ("#77 the streak prize never paid", "BattlePassService",
     "local streakPrize = applyReward(player, data, BattlePassData.DailyRewards[dayIndex])",
     "local streakPrize = \"nothing\""),
    ("#77 the claim day never recorded", "BattlePassService",
     "\tdata.Daily.lastClaimDay = today\n", "\n"),
    ("#77 a missed day keeps the streak", "BattlePassService",
     "\telse\n\t\tdata.Daily.streak = 1\n", "\telse\n\t\tdata.Daily.streak = data.Daily.streak + 1\n"),
    ("#77 a streak crate names no crate", "BattlePassData",
     '\t{ kind = "Crate", crate = "Uncommon" },\n\t{ kind = "Coins", amount = 1500 },',
     '\t{ kind = "Crate", crate = "Uncomon" },\n\t{ kind = "Coins", amount = 1500 },'),
    ("#76 an award one check short of the threshold", "PlaytimeService",
     "local earned = session.active >= CONFIG.MinActiveSamples",
     "local earned = session.active + 1 >= CONFIG.MinActiveSamples"),
    ("#76 awards twice as often", "PlaytimeService",
     "math.floor(CONFIG.IntervalSeconds / CONFIG.SampleSeconds)",
     "math.floor(CONFIG.IntervalSeconds / CONFIG.SampleSeconds / 2)"),
    ("#76 a player who leaves is kept", "PlaytimeService",
     "\t\tsessions[player] = nil\n", "\n"),
]


def all_checks(src):
    pt, facts = playtime_checks(src)
    return pt + streak_checks(src), facts


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = sources(root)
    if "--plant" in sys.argv:
        caught = 0
        for label, key, old, new in PLANTS:
            if src[key].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(src, **{key: src[key].replace(old, new)})
            try:
                checks, _ = all_checks(planted)
                failed = [name for name, ok, _ in checks if not ok]
            except Exception as err:  # a plant that crashes the run is caught too, but say so
                failed = [f"run raised {type(err).__name__}: {str(err).splitlines()[0][:80]}"]
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"playtime/streak planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    checks, facts = all_checks(src)
    for name, ok, detail in checks:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    print("  measured facts (no pass/fail; for the report):")
    for name, _, detail in facts:
        print(f"    - {name}: {detail}")
    bad = sum(1 for _, ok, _ in checks if not ok)
    print(f"playtime/streak proof: {len(checks)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
