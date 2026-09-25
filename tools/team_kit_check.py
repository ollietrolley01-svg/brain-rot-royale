"""Behaviour check for the team-mode spawn kit, without Studio: #114 a (a popup defense) and Oliver's
2026-09-25 kit -- 2 of each of 2 random explosives, 2 smoke bombs, 2 of 1 random portable defense, full
shield.

Runs the real ReplicatedStorage/Shared/GameModes.lua and ItemData.lua and the real
ModeTeams.GrantLoadout (cut out of ServerScriptService/Modules/ModeTeams.lua) in lupa, with
WeaponService mocked as an eight-slot inventory that stacks the way WeaponService.GiveConsumable
does. Measures what a spawned player is actually CARRYING, not what the list says.

    python tools/team_kit_check.py .            the checks
    python tools/team_kit_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("team_kit_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    # x += y / x -= y  ->  x = x + y / x = x - y   (the only Luau-only syntax these files use)
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+-])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def grant_source(root):
    text = read(root, "ServerScriptService", "Modules", "ModeTeams.lua")
    start = text.index("function ModeTeams.GrantLoadout(player)")
    end = text.index("\nend\n", start) + 5
    return luau_to_lua(text[start:end])


HARNESS = r"""
local sources = ...
Color3 = { fromRGB = function(r, g, b) return { r, g, b } end }
local shared = {}
local function load(name)
    if shared[name] == nil then
        shared[name] = assert(load_chunk(sources[name], name))()
    end
    return shared[name]
end
function require(object) return load(object.name) end
local folder = { WaitForChild = function(_, name) return { name = name } end }
game = { GetService = function() return { WaitForChild = function() return folder end } end }

local GameModes = load("GameModes")
local ItemData = load("ItemData")
local SLOTS = 8
local slots = {}
shield = 0
local WeaponService = {
    Reset = function() for i = 1, SLOTS do slots[i] = nil end end,
    GiveWeapon = function(_, id)
        for i = 1, SLOTS do if not slots[i] then slots[i] = { kind = "weapon", id = id, count = 1 } return end end
    end,
    GiveConsumable = function(_, id, amount)
        local item = ItemData.Get(id)
        local left = amount
        for i = 1, SLOTS do
            local s = slots[i]
            if left > 0 and s and s.kind == "item" and s.id == id and s.count < item.stack then
                local add = math.min(left, item.stack - s.count)
                s.count = s.count + add
                left = left - add
            end
        end
        while left > 0 do
            local index
            for i = 1, SLOTS do if not slots[i] then index = i break end end
            if not index then break end
            local add = math.min(left, item.stack)
            slots[index] = { kind = "item", id = id, count = add }
            left = left - add
        end
        return amount - left
    end,
    Get = function() return { slots = slots } end,
    SetShield = function(_, value) shield = math.min(value, 100) end,
}
local ModeTeams = { RollGreenWeapon = function() return "GreenGun" end }
local env = setmetatable({ ModeTeams = ModeTeams, WeaponService = WeaponService, GameModes = GameModes,
    ItemData = ItemData }, { __index = _G })
assert(load_chunk(sources.Grant, "GrantLoadout", "t", env))()
local lives = {}
math.randomseed(7)
for life = 1, 60 do
    shield = 0
    local weapon, stacks = ModeTeams.GrantLoadout({})
    local out = { weapon = weapon, stacks = stacks, used = 0, slotsUsed = GameModes.Loadout.slotsUsed, carried = {},
        shield = shield }
    for i = 1, SLOTS do
        local s = slots[i]
        if s then
            out.used = out.used + 1
            local item = ItemData.Get(s.id)
            table.insert(out.carried, { id = s.id, count = s.count, kind = item and item.kind or s.kind,
                issued = s.issued == true, stack = item and item.stack or 0 })
        end
    end
    lives[life] = out
end
local pools = {}
for i, pool in ipairs(GameModes.Loadout.pools) do
    pools[i] = { ids = pool.ids, kinds = pool.kinds, count = pool.count }
end
return lives, pools
"""


def run(sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().load_chunk = lua.eval("load")
    table = lua.table_from({k: v for k, v in sources.items() if isinstance(v, str)})
    lives, pools = lua.execute(HARNESS, table)
    out = []
    for life in lives.values():
        d = dict(life)
        d["carried"] = [dict(c) for c in life["carried"].values()]
        out.append(d)
    pools = [{"ids": list(p["ids"].values()), "kinds": p["kinds"], "count": p["count"]} for p in pools.values()]
    return out, pools


EXPLOSIVES = {"CookedCoconut", "ClingyCrumpet", "RotMine"}
DEFENSES = {"RotBarricade", "PopupBunker", "BrainrotFortress"}


def checks(sources):
    lives, pools = run(sources)
    bad = {k: [] for k in ("smoke", "explosives", "defenses", "counts", "landed", "slots", "room", "issued", "shield")}
    seen = {"explosives": set(), "defenses": set()}
    for n, life in enumerate(lives):
        carried = life["carried"]
        ids = {}
        for c in carried:
            ids[c["id"]] = ids.get(c["id"], 0) + c["count"]
        if ids.get("LowkeyLatte", 0) != 2:
            bad["smoke"].append(f"life {n}: {ids.get('LowkeyLatte', 0)} smoke")
        for key, group, want in (("explosives", EXPLOSIVES, 2), ("defenses", DEFENSES, 1)):
            kinds = [i for i in ids if i in group]
            seen[key].update(kinds)
            if len(kinds) != want:
                bad[key].append(f"life {n}: {kinds}")
        for c in carried:
            if c["id"] in EXPLOSIVES | DEFENSES and c["count"] != min(2, c["stack"]):
                bad["counts"].append(f"life {n}: {c['id']} x{c['count']}")
        if life["stacks"] != len(sources["_listed"]) + sum(p["kinds"] for p in pools):
            bad["landed"].append(f"life {n}: {life['stacks']} stacks")
        if life["used"] != life["slotsUsed"]:
            bad["slots"].append(f"life {n}: carried {life['used']}, GameModes says {life['slotsUsed']}")
        if life["used"] > 6:
            bad["room"].append(f"life {n}: {life['used']} of 8")
        if not all(c["issued"] for c in carried):
            bad["issued"].append(f"life {n}")
        if life["shield"] < 100:
            bad["shield"].append(f"life {n}: shield {life['shield']}")
    first = lambda k: bad[k][0] if bad[k] else "all 60 lives"
    results = [
        ("2 smoke bombs every life", not bad["smoke"], first("smoke")),
        ("exactly 2 different explosive kinds every life", not bad["explosives"], first("explosives")),
        ("exactly 1 portable defense kind every life", not bad["defenses"], first("defenses")),
        ("2 of each rolled kind (capped by its stack)", not bad["counts"], first("counts")),
        ("every explosive kind comes up over 60 lives (really random)", seen["explosives"] == EXPLOSIVES,
         f"seen {sorted(seen['explosives'])}"),
        ("every defense kind comes up over 60 lives (really random)", seen["defenses"] == DEFENSES,
         f"seen {sorted(seen['defenses'])}"),
        ("every kit item landed (none silently skipped)", not bad["landed"], first("landed")),
        ("slotsUsed matches what was carried", not bad["slots"], first("slots")),
        ("room left to loot (at least 2 of 8 slots free)", not bad["room"], first("room")),
        ("the whole kit is tagged issued (so a death does not drop it)", not bad["issued"], first("issued")),
        ("spawns with full shield", not bad["shield"], first("shield")),
    ]
    return results, lives[0]["carried"]


def listed(gamemodes_src):
    block = gamemodes_src[gamemodes_src.index("GameModes.Loadout = {"):]
    block = block[:block.index("\n}") + 2]
    return re.findall(r'\{ id = "(\w+)"', block)


def sources_for(root, gamemodes=None, itemdata=None, grant=None):
    src = {
        "GameModes": luau_to_lua(gamemodes or read(root, "ReplicatedStorage", "Shared", "GameModes.lua")),
        "ItemData": luau_to_lua(itemdata or read(root, "ReplicatedStorage", "Shared", "ItemData.lua")),
        "Rarity": luau_to_lua(read(root, "ReplicatedStorage", "Shared", "Rarity.lua")),
        "Grant": grant or grant_source(root),
    }
    src["_listed"] = listed(src["GameModes"])
    return src


def plants(root):
    gm = read(root, "ReplicatedStorage", "Shared", "GameModes.lua")
    grant = grant_source(root)
    yield "smoke dropped to 1", sources_for(root, gamemodes=gm.replace('{ id = "LowkeyLatte", count = 2 }', '{ id = "LowkeyLatte", count = 1 }'))
    yield "one explosive kind instead of two", sources_for(root, gamemodes=gm.replace(
        '"RotMine" }, kinds = 2', '"RotMine" }, kinds = 1'))
    yield "defense pool loses a kind (never rolled)", sources_for(root, gamemodes=gm.replace(
        '"RotBarricade", "PopupBunker", "BrainrotFortress" }', '"RotBarricade", "PopupBunker" }'))
    yield "two defense kinds instead of one", sources_for(root, gamemodes=gm.replace(
        '"BrainrotFortress" }, kinds = 1', '"BrainrotFortress" }, kinds = 2'))
    yield "roll can repeat the same kind", sources_for(root, gamemodes=gm.replace(
        "local id = table.remove(left, random(#left))", "local id = left[random(#left)]"))
    yield "defense id typo (ItemData.Get nil, skipped)", sources_for(root, gamemodes=gm.replace('"PopupBunker"', '"PopupBunkr"'))
    yield "no full shield", sources_for(root, grant=grant.replace("WeaponService.SetShield(player, math.huge)", "WeaponService.SetShield(player, 0)"))
    yield "GrantLoadout stops tagging the kit issued", sources_for(root, grant=grant.replace("slot.issued = true", "slot.issued = false"))
    yield "kit overfills the bag", sources_for(root, gamemodes=gm.replace(
        '{ id = "Bandage", count = 3 },', '{ id = "Bandage", count = 3 },\n\t\t{ id = "MedKit", count = 1 },'))


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    clean = sources_for(root)
    if "--plant" in sys.argv:
        caught = total = 0
        for label, src in plants(root):
            total += 1
            if all(src[k] == clean[k] for k in ("GameModes", "ItemData", "Grant")):
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            try:
                results, _ = checks(src)
                failed = [name for name, ok, _ in results if not ok]
            except Exception as err:  # a crash is the harness breaking, not a catch
                print(f"  CRASHED: {label}: {str(err).splitlines()[0]}")
                continue
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"team kit plants: {caught} of {total} caught")
        sys.exit(0 if caught == total else 1)
    results, carried = checks(clean)
    print("  carried: " + ", ".join(f"{c['id']} x{c['count']} ({c['kind']})" for c in carried))
    bad = 0
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
        bad += 0 if ok else 1
    print(f"team kit check: {len(results)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
