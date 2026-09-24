"""Behaviour check for the team-mode spawn kit (#114 a: the popup barricade), without Studio.

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
}
local ModeTeams = { RollGreenWeapon = function() return "GreenGun" end }
local env = setmetatable({ ModeTeams = ModeTeams, WeaponService = WeaponService, GameModes = GameModes,
    ItemData = ItemData }, { __index = _G })
assert(load_chunk(sources.Grant, "GrantLoadout", "t", env))()
local weapon, stacks = ModeTeams.GrantLoadout({})
local out = { weapon = weapon, stacks = stacks, used = 0, slotsUsed = GameModes.Loadout.slotsUsed, carried = {} }
for i = 1, SLOTS do
    local s = slots[i]
    if s then
        out.used = out.used + 1
        local item = ItemData.Get(s.id)
        table.insert(out.carried, { id = s.id, count = s.count, kind = item and item.kind or s.kind,
            issued = s.issued == true })
    end
end
return out
"""


def run(sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.globals().load_chunk = lua.eval("load")
    table = lua.table_from({k: v for k, v in sources.items() if isinstance(v, str)})
    out = lua.execute(HARNESS, table)
    carried = [dict(c) for c in out["carried"].values()]
    return out, carried


def checks(sources):
    out, carried = run(sources)
    defenses = [c for c in carried if c["kind"] == "defense"]
    barricades = [c for c in carried if c["id"] == "RotBarricade"]
    results = [
        ("the kit carries a Rot Barricade", len(barricades) == 1 and barricades[0]["count"] >= 1,
         f"{barricades}"),
        ("the barricade is a usable defense (ItemData kind 'defense')", len(defenses) >= 1,
         f"defense slots: {defenses}"),
        ("every listed kit item landed (none silently skipped)",
         out["stacks"] == len(sources["_listed"]), f"{out['stacks']} stacks of {len(sources['_listed'])} listed"),
        ("slotsUsed matches what was carried", out["used"] == out["slotsUsed"],
         f"carried {out['used']} slots, GameModes says {out['slotsUsed']}"),
        ("room left to loot (at least 2 of 8 slots free)", out["used"] <= 6, f"{out['used']} of 8 used"),
        ("the whole kit is tagged issued (so a death does not drop it)", all(c["issued"] for c in carried),
         f"{[c['id'] for c in carried if not c['issued']]} untagged"),
    ]
    return results, carried


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
    items = read(root, "ReplicatedStorage", "Shared", "ItemData.lua")
    yield "barricade dropped from the kit", sources_for(root, gamemodes=gm.replace('\t\t{ id = "RotBarricade", count = 1 },\n', ""))
    yield "barricade id typo (ItemData.Get nil, skipped)", sources_for(root, gamemodes=gm.replace('id = "RotBarricade"', 'id = "RotBarricde"'))
    yield "kit overfills the bag so the barricade is truncated", sources_for(root, gamemodes=gm.replace(
        '\t\t{ id = "Bandage", count = 3 },', '\t\t{ id = "Bandage", count = 3 },\n' + '\t\t{ id = "MedKit", count = 1 },\n' * 3))
    yield "barricade no longer a defense item", sources_for(root, itemdata=items.replace(
        'name = "Rot Barricade",\n\t\tkind = "defense"', 'name = "Rot Barricade",\n\t\tkind = "heal"'))
    yield "GrantLoadout stops tagging the kit issued", sources_for(root, grant=grant_source(root).replace("slot.issued = true", "slot.issued = false"))


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
