"""Behaviour check: a burst of shots and shield hits sends ONE loadout snapshot a frame, without Studio.

    python3 tools/weapon_push_check.py .            the checks
    python3 tools/weapon_push_check.py . --plant    the planted faults; every one must be caught

WeaponService.ConsumeAmmo (every shot) and AbsorbDamage (every hit on a shield) each used to call
WeaponService.Push, which builds and sends the WHOLE loadout: an SMG into a shielded player was several
full snapshots a frame. They now ask WeaponService.PushSoon, which coalesces to one Push at the end of
the frame (task.defer, like StateSync.Push). Runs the REAL PushSoon, ConsumeAmmo and AbsorbDamage, cut
from the source, in lupa with Push counted and task.defer queued by hand:

  * twelve shots and six shield hits in one frame: no Push until the frame ends, then exactly one;
  * the next frame's shot gets its own;
  * a Push that went out in the frame (an equip, a pickup) satisfies the waiting one: no second send;
  * Clear (the player left) drops a waiting one, and so does a player no longer in the game.

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("weapon_push_check: needs lupa (pip install lupa)")

SERVICE = "ServerScriptService/Modules/WeaponService.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def cut(src, head):
    a = src.index(head)
    b = src.index("\nend\n", a) + 5
    return src[a:b]


def block(src):
    parts = [
        "local pushQueued = {}\n",
        cut(src, "function WeaponService.PushSoon("),
        # ConsumeAmmo tells the AFK rule a round went (findings C2); nothing listens here.
        cut(src, "function WeaponService.NoteActivity("),
        cut(src, "function WeaponService.ConsumeAmmo("),
        cut(src, "function WeaponService.AbsorbDamage("),
        # Clear, with the loadout and shield bookkeeping it also does.
        cut(src, "function WeaponService.Clear("),
    ]
    if "local pushQueued = {}\n" not in src:
        raise SystemExit("weapon_push_check: WeaponService has no pushQueued table any more; update the harness")
    # Declared above every function that names it (Clear sits above Push): below, Clear would read a nil global.
    if src.index("local pushQueued = {}\n") > src.index("function WeaponService.Clear("):
        raise ValueError("pushQueued is declared below WeaponService.Clear, which uses it")
    # Push is mocked, but it must clear the queue flag the way the real one does, so read that line.
    first = cut(src, "function WeaponService.Push(").split("\n")[1].strip()
    return luau_to_lua("\n".join(parts)), first


HARNESS = r"""
local src, pushFirstLine = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local deferred = {}
local sends = 0
local slot = { kind = "weapon", mag = 30 }
local loadout = { shield = 100, slots = { slot }, equipped = 1 }
local env = setmetatable({
    task = { defer = function(fn) table.insert(deferred, fn) end },
    loadouts = {},
    lastInstantAt = {},
    syncShield = function() end,
    WeaponService = {},
}, { __index = _G })
env.WeaponService.GetEquipped = function(p) return {}, env.loadouts[p] and slot or nil end
local chunk = assert(load(src .. "\nreturn pushQueued", "WeaponService", "t", env))
local pushQueued = chunk()
-- The real Push's first statement (it clears the queue flag), then a counted send.
local clearFlag = assert(load("local pushQueued, player = ...\n" .. pushFirstLine))
env.WeaponService.Push = function(p) clearFlag(pushQueued, p); sends = sends + 1 end
local function endFrame()
    local list = deferred
    deferred = {}
    for _, fn in ipairs(list) do fn() end
end
local WS = env.WeaponService
local player = { Name = "P", Parent = true }
env.loadouts[player] = loadout

for _ = 1, 12 do WS.ConsumeAmmo(player) end
for _ = 1, 6 do WS.AbsorbDamage(player, 5) end
check(sends == 0, "nothing is sent mid-frame: " .. sends)
check(#deferred == 1, "one end-of-frame send is queued for the whole burst, not one per call: " .. #deferred)
check(slot.mag == 18 and loadout.shield == 70, string.format("the state still changes at once (mag %d, shield %d)", slot.mag, loadout.shield))
endFrame()
check(sends == 1, "twelve shots and six shield hits in one frame send one snapshot: " .. sends)
WS.ConsumeAmmo(player)
endFrame()
check(sends == 2, "the next frame's shot gets its own: " .. sends)
WS.ConsumeAmmo(player)
WS.Push(player) -- an equip or a pickup in the same frame
endFrame()
check(sends == 3, "a Push that went out this frame covers the waiting one: " .. sends)
WS.ConsumeAmmo(player)
WS.Clear(player)
endFrame()
check(sends == 3, "a player who left is sent nothing: " .. sends)
env.loadouts[player] = loadout
WS.ConsumeAmmo(player)
player.Parent = nil
endFrame()
check(sends == 3, "...nor one who is no longer in the game: " .. sends)
player.Parent = true
WS.ConsumeAmmo(player)
endFrame()
check(sends == 4, "and a later shot is sent again (the flag was not left set): " .. sends)
return out
"""


def run(src):
    try:
        code, first = block(src)
        lua = LuaRuntime(unpack_returned_tuples=True)
        rows = lua.execute(HARNESS, code, first)
        return [(bool(r["ok"]), r["line"]) for r in rows.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % exc)]


PLANTS = [
    ("a shot pushes the whole loadout at once again",
     "\tslot.mag -= 1\n\tWeaponService.PushSoon(player)", "\tslot.mag -= 1\n\tWeaponService.Push(player)"),
    ("a shield hit pushes the whole loadout at once again",
     "\tsyncShield(player, loadout.shield)\n\tWeaponService.PushSoon(player)\n\treturn amount - absorbed",
     "\tsyncShield(player, loadout.shield)\n\tWeaponService.Push(player)\n\treturn amount - absorbed"),
    ("no coalescing (a defer per call)", "\tif pushQueued[player] then\n\t\treturn\n\tend\n\tpushQueued[player] = true\n",
     "\tpushQueued[player] = true\n"),
    ("the flag never cleared after a send", "\t\tpushQueued[player] = nil\n\tend)", "\tend)"),
    ("Clear leaves a waiting push", "\tloadouts[player] = nil\n\tpushQueued[player] = nil\n", "\tloadouts[player] = nil\n"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = open(os.path.join(root, SERVICE), encoding="utf-8").read()
    if "--plant" in sys.argv:
        caught = 0
        for label, old, new in PLANTS:
            if src.count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            failed = [line for ok, line in run(src.replace(old, new)) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"weapon_push_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = run(src)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"weapon_push_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
