"""Rot Vendor per-match caps (findings C5, Oliver chose option a): 2 heals and 1 shield per player per match.

    python3 tools/vendor_cap_check.py .            the checks
    python3 tools/vendor_cap_check.py . --plant    the planted faults; every one must be caught

The REAL VendorService.lua (and the real ItemData.lua it reads kinds from) runs in lupa with the
services it touches mocked. What a player can buy, one match:

  heals     the Med Kit button sells twice, then refuses with a message naming the cap, and charges
            nothing for the refusal
  shield    the Shield Potion button sells once, then refuses the same way
  ammo      the ammo refill is not capped
  fair      a purchase that could not be delivered (no room) does not use up the cap; one player's
            purchases do not count against another's
  match     VendorService.ResetMatch gives everyone their caps back, MatchService's startMatch calls it,
            and a player who leaves is let go of
  prompt    each capped button's prompt says "N a match"

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("vendor_cap_check: needs lupa (pip install lupa)")

VENDOR = "ServerScriptService/Modules/VendorService.lua"
ITEMS = "ReplicatedStorage/Shared/ItemData.lua"
MATCH = "ServerScriptService/Modules/MatchService.lua"
FILES = (VENDOR, ITEMS, MATCH)
# Oliver's decision, not the config's: the check pins the numbers he chose.
HEALS, SHIELDS = 2, 1


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


HARNESS = r"""
local vendorSrc, itemSrc, heals, shields = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end, new = function(r, g, b) return { r, g, b } end }
Vector3 = { new = function(x, y, z) return { x, y, z } end }
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
local items = assert(load(itemSrc, "ItemData", "t", setmetatable({}, { __index = _G })))()
local function node(name) return { Name = name, WaitForChild = function(_, n) return node(n) end } end
local removing, wallets, noRoom = {}, {}, {}
local function wallet(p) wallets[p] = wallets[p] or { SahurCoins = 100000 }; return wallets[p] end
local mocks = {
    ItemData = items,
    ZFight = { Fix = function() end },
    Combatants = { IsAlive = function() return true end },
    CombatService = { IsEnabled = function() return true end },
    DestructibleService = { OnPartBroken = function() end },
    PlayerData = { Get = wallet },
    QuestService = { Progress = function() end },
    StateSync = { Push = function() end, Notify = function() end },
    WeaponService = {
        GiveConsumable = function(p, _, n) if noRoom[p] then return 0 end return n end,
        GiveAmmo = function() return true end,
    },
}
local env = setmetatable({
    game = { GetService = function(_, name)
        if name == "Players" then return { PlayerRemoving = { Connect = function(_, fn) table.insert(removing, fn) end } } end
        return node(name)
    end },
    script = { Parent = node("Modules") },
    require = function(m) return mocks[m.Name] or error("no mock for " .. tostring(m.Name)) end,
}, { __index = _G })
local Vendor = assert(load(vendorSrc, "VendorService", "t", env))()

local byId = {}
for _, p in ipairs(Vendor.Products) do byId[p.id] = p end
local function times(p, id, n)
    local okCount, last = 0, nil
    for _ = 1, n do local ok, msg = Vendor.Buy(p, byId[id]); if ok then okCount = okCount + 1 end; last = msg end
    return okCount, last
end

local a, b = { Name = "A" }, { Name = "B" }
local before = wallet(a).SahurCoins
local sold, msg = times(a, "MedKit", heals + 2)
check(sold == heals, string.format("a player buys %d Med Kits a match, no more (%d sold of %d tried)", heals, sold, heals + 2))
check(type(msg) == "string" and msg:find(tostring(heals), 1, true) and msg:lower():find("heal") and msg:lower():find("match"),
    "...and the refusal says the cap: " .. tostring(msg))
check(before - wallet(a).SahurCoins == heals * byId.MedKit.price,
    string.format("...and only the sold ones are charged (%d charged)", before - wallet(a).SahurCoins))
sold, msg = times(a, "ShieldPotion", shields + 2)
check(sold == shields, string.format("a player buys %d Shield Potion a match, no more (%d sold)", shields, sold))
check(type(msg) == "string" and msg:lower():find("shield") and msg:find(tostring(shields), 1, true), "...refused with the cap named: " .. tostring(msg))
sold = times(a, "Ammo", 6)
check(sold == 6, "ammo refills are not capped (" .. sold .. " of 6)")
sold = times(b, "MedKit", heals)
check(sold == heals, "another player's cap is their own (" .. sold .. " sold to B)")
noRoom[b] = true
local full = times(b, "ShieldPotion", 1)
noRoom[b] = nil
sold = times(b, "ShieldPotion", 1)
check(full == 0 and sold == 1, "a potion that did not fit does not use up the cap")
Vendor.ResetMatch()
sold = times(a, "MedKit", heals)
local soldShield = times(a, "ShieldPotion", shields)
check(sold == heals and soldShield == shields, "the next match (ResetMatch) gives the caps back")
check(#removing == 1, "the module lets go of leavers (one PlayerRemoving hook, " .. #removing .. " found)")
return out
"""


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        result = lua.execute(code, *args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def between(src, start, stop):
    a = src.index(start)
    return src[a:src.index(stop, a)]


def all_rows(sources):
    rows = run_lua(HARNESS, luau_to_lua(sources[VENDOR]), luau_to_lua(sources[ITEMS]), HEALS, SHIELDS)
    vendor = sources[VENDOR]
    try:
        start = between(sources[MATCH], "local function startMatch()", "\nend\n")
        rows.append(("VendorService.ResetMatch()" in start, "MatchService's startMatch resets the vendor caps"))
        leave = between(vendor, "Players.PlayerRemoving:Connect(function(player)", "end)")
        rows.append(("boughtThisMatch[player] = nil" in leave, "a player who leaves is let go of"))
        prompt = between(vendor, "prompt.ObjectText = ", "prompt.GamepadKeyCode")
        rows.append(("a match" in prompt and "VendorService.MatchCaps[capKind]" in prompt, "a capped button's prompt says how many a match"))
    except ValueError as exc:
        rows.append((False, "source shape changed: %s" % exc))
    return rows


PLANTS = [
    ("no cap (the old vendor)", VENDOR, "if capKind and (bought[capKind] or 0) >= VendorService.MatchCaps[capKind] then",
     "if false then"),
    ("the cap counted before delivery", VENDOR, "\tlocal bought = boughtThisMatch[player] or {}\n",
     "\tlocal bought = boughtThisMatch[player] or {}\n\tif capKind then bought[capKind] = (bought[capKind] or 0) + 1; boughtThisMatch[player] = bought end\n"),
    ("shared across players", VENDOR, "\tlocal bought = boughtThisMatch[player] or {}\n", "\tlocal bought = boughtThisMatch.all or {}\n"),
    ("never reset", VENDOR, "\ttable.clear(boughtThisMatch)\n", ""),
    ("startMatch forgets to reset", MATCH, "\tVendorService.ResetMatch()\n", ""),
    ("three heals", VENDOR, "VendorService.MatchCaps = { heal = 2, shield = 1 }", "VendorService.MatchCaps = { heal = 3, shield = 1 }"),
    ("a refusal that doesn't say why", VENDOR,
     'return false, string.format("Sold out for you — the vendors sell each player %d %s a match.",\n\t\t\tcap, CAP_NAMES[capKind][cap == 1 and 1 or 2])',
     'return false, "Out of order."'),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: open(os.path.join(root, rel), encoding="utf-8").read() for rel in FILES}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in all_rows(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"vendor_cap_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"vendor_cap_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
