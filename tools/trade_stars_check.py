"""Check: a trade can never leave a merged brainrot's stars on a profile with no copy of it.

Stars live on the profile, not the copy, so a profile with Stars[name] > 0 and no copy of `name`
hands full stars to the next copy that arrives from anywhere. TradeService.Offer refuses to offer the
last copy of a merged brainrot, but only against the collection as it was at offer time: offer the
spare, sell the other copy, then confirm, and the offered spare was the last copy.

Runs the real ServerScriptService/Modules/TradeService.lua and RewardService.lua under lupa, with
Roblox services, PlayerData, StateSync and every other module stubbed. Scenarios:

  - A has 2 copies of a 1-star brainrot and offers the spare. While the trade is open A tries each of
    SELL 1, SELL ALL of the rarity and SELL DUPLICATES. Each must be refused (a trade is open), and
    the trade must then go through with A keeping one copy.
  - The same offer, but the other copy leaves the collection by some other path before the confirm.
    The trade must be cancelled rather than move the last copy.
  - Control: A has 3 copies, offers 1, both confirm; the trade goes through.

INVARIANT after every scenario: no profile has Stars[name] > 0 with zero copies of name.

PLANTED FAULTS (permanent): the execute() re-check removed, and each Sell* IsTrading gate removed.
Each must turn the check red.

Run: python3 tools/trade_stars_check.py   (exit 0 = clean pass and every fault caught)
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("trade_stars_check: needs lupa (pip install lupa)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULES = os.path.join(ROOT, "ServerScriptService", "Modules")


def luau_to_lua(source):
    # x += y  ->  x = x + y,  x -= y  ->  x = x - (y)   (the only Luau-only syntax these files use)
    source = re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + \3", source, flags=re.M)
    return re.sub(r"^(\s*)([\w.\[\]]+) -= (.+)$", r"\1\2 = \2 - (\3)", source, flags=re.M)


def read(name):
    with open(os.path.join(MODULES, name + ".lua"), encoding="utf-8") as f:
        return f.read()


HARNESS = r"""
local tradeSrc, rewardSrc = ...

local profiles = {}
local function child(name)
    return { Name = name, WaitForChild = function(_, n) return child(n) end }
end
local signal = { Connect = function() end }
game = { GetService = function(_, name)
    if name == "Players" then return { PlayerRemoving = signal, PlayerAdded = signal } end
    return child(name)
end }
script = { Parent = child("Modules") }
warn = function(...) error(table.concat({ ... }, " ")) end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end end
table.clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end

local stubs = {
    BrainrotData = {
        Get = function(name) return { rarity = "Rare", coinValue = 10 } end,
        StarText = function(n) return n .. " star" end,
        ClampStars = function(n) return n or 0 end,
    },
    Remotes = { Event = function() return { FireClient = function() end } end },
    PlayerData = {
        Get = function(p) return profiles[p] end,
        HasStore = function() return false end,
        CanSave = function() return true end,
        Save = function() return true end,
    },
    StateSync = { Notify = function(p, msg) p.lastNotice = msg end, Push = function() end },
    Monetization = { EarnCoins = function(_, amount) return amount end },
}
-- Anything else RewardService pulls in at load is a table of no-ops.
local noop = setmetatable({}, { __index = function() return function() end end })
require = function(inst)
    return stubs[inst.Name] or noop
end

local TradeService = load(tradeSrc, "TradeService")()
local RewardService = load(rewardSrc, "RewardService")()
RewardService.IsTrading = TradeService.InSession

local api = {}
function api.player(name, copies, stars)
    local p = { Name = name, DisplayName = name, UserId = #name, Parent = true }
    local list = {}
    for i = 1, copies do list[i] = "Tung" end
    for i = 1, 3 do table.insert(list, "Filler" .. i) end
    profiles[p] = { Brainrots = list, Stars = { Tung = stars } }
    return p
end
function api.open(a, b)
    assert(TradeService.Request(a, b))
    assert(TradeService.Respond(b, true))
end
api.Trade = TradeService
api.Reward = RewardService
function api.count(p, name)
    local n = 0
    for _, x in ipairs(profiles[p].Brainrots) do if x == name then n = n + 1 end end
    return n
end
function api.drop(p, name)
    local list = profiles[p].Brainrots
    table.remove(list, table.find(list, name))
end
-- Every name with stars and no copy, on this profile.
function api.stranded(p)
    local out = {}
    for name, stars in pairs(profiles[p].Stars) do
        if stars > 0 and api.count(p, name) == 0 then table.insert(out, name) end
    end
    return table.concat(out, ",")
end
return api
"""


def scenarios(trade_src, reward_src):
    """Returns (violations, notes)."""
    violations, notes = [], []

    def fresh():
        lua = LuaRuntime(unpack_returned_tuples=True)
        return lua.execute(HARNESS, trade_src, reward_src)

    def invariant(api, label, *players):
        for p in players:
            s = api.stranded(p)
            if s:
                violations.append(f"{label}: {p.Name} has stars on {s} with no copy left")

    sells = {
        "SELL 1": lambda api, a: api.Reward.SellBrainrot(a, "Tung"),
        "SELL ALL Rare": lambda api, a: api.Reward.SellAllOfRarity(a, "Rare"),
        "SELL DUPLICATES": lambda api, a: api.Reward.SellDuplicates(a),
    }
    for label, sell in sells.items():
        api = fresh()
        a, b = api.player("A", 2, 1), api.player("B", 0, 0)
        api.open(a, b)
        ok, msg = api.Trade.Offer(a, "Tung", True)
        if not ok:
            violations.append(f"{label}: offering the spare was refused ({msg})")
            continue
        sold, msg = sell(api, a)[:2]
        notes.append(f"{label} mid-trade: {'SOLD' if sold else 'refused'} ({msg})")
        if sold:
            violations.append(f"{label}: sold while a trade was open ({msg})")
        api.Trade.Confirm(a, True)
        api.Trade.Confirm(b, True)
        invariant(api, label, a, b)
        if not sold and (api.count(a, "Tung") != 1 or api.count(b, "Tung") != 1):
            violations.append(f"{label}: the trade didn't go through after the refused sale "
                              f"(A {api.count(a, 'Tung')}, B {api.count(b, 'Tung')}; {a.lastNotice})")

    api = fresh()
    a, b = api.player("A", 2, 1), api.player("B", 0, 0)
    api.open(a, b)
    api.Trade.Offer(a, "Tung", True)
    api.drop(a, "Tung")  # the other copy leaves by some path that doesn't go through a sale
    api.Trade.Confirm(a, True)
    api.Trade.Confirm(b, True)
    notes.append(f"copy gone before confirm: A {api.count(a, 'Tung')}, B {api.count(b, 'Tung')} ({a.lastNotice})")
    invariant(api, "copy gone before confirm", a, b)
    if api.Trade.InSession(a):
        violations.append("copy gone before confirm: the session was left open")

    api = fresh()
    a, b = api.player("A", 3, 1), api.player("B", 0, 0)
    api.open(a, b)
    api.Trade.Offer(a, "Tung", True)
    api.Trade.Confirm(a, True)
    api.Trade.Confirm(b, True)
    if api.count(a, "Tung") != 2 or api.count(b, "Tung") != 1:
        violations.append(f"control: a spare-only trade didn't go through ({a.lastNotice})")
    invariant(api, "control", a, b)
    return violations, notes


MUTANTS = {
    "execute() re-check removed": ("TradeService",
        "local merged, stars = strandsStars(side[2], side[3])", "local merged, stars = nil, 0"),
}
for fn in ("SellBrainrot(player, name)", "SellAllOfRarity(player, rarity)", "SellDuplicates(player)"):
    MUTANTS[f"{fn.split('(')[0]} ungated while trading"] = ("RewardService", fn, fn)


def ungate(source, head):
    """Drops the IsTrading refusal from the one function whose signature is `head`."""
    start = source.index("function RewardService." + head)
    gate = "\tif RewardService.IsTrading(player) then\n\t\treturn false, TRADING_MESSAGE\n\tend\n"
    at = source.index(gate, start)
    if source.find("\nend\n", start) < at:
        raise ValueError("gate not inside " + head)
    return source[:at] + source[at + len(gate):]


def main():
    trade_src, reward_src = luau_to_lua(read("TradeService")), luau_to_lua(read("RewardService"))
    ok = True
    violations, notes = scenarios(trade_src, reward_src)
    for n in notes:
        print("  " + n)
    print(f"clean: {len(violations)} violations")
    for v in violations:
        print("  " + v)
    ok = not violations
    for label, (target, old, new) in MUTANTS.items():
        try:
            if target == "TradeService":
                if old not in trade_src:
                    raise ValueError("pattern not found")
                bad, _ = scenarios(trade_src.replace(old, new, 1), reward_src)
            else:
                bad, _ = scenarios(trade_src, ungate(reward_src, old))
        except ValueError as e:
            print(f"FAIL: planted fault '{label}' could not be applied ({e}; update the mutant)")
            ok = False
            continue
        caught = len(bad) > 0
        print(f"planted fault '{label}': {'CAUGHT' if caught else 'MISSED'}"
              + (f", first: {bad[0]}" if bad else ""))
        ok = ok and caught
    print("trade_stars_check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
