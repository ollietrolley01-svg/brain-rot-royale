"""#117 "lobby trial guns change every pickup", end to end: does taking a second podium gun add it to your
hotbar and keep the first, in every state that matters, and do range guns stay out of matches and saves?

Runs the game's REAL modules whole in lupa (tools/trial_guns_proof_world.lua): RangeService, WeaponService,
WeaponData with its three arsenal packs, ItemData, MatchConfig, Rarity, SafeValue. The range itself is the
real block of LobbyService's buildArena (RangeService.SetArea and the podium loop that builds the three
prompts and connects their Triggered handlers), cut from the file and run; a take is that prompt's handler
firing for a player standing on the podium. A lobby death goes through MatchService's real
OnCharacterAdded lobby branch (its Died handler, LoadCharacter, PlaceInLobby), cut from the file. The range's
0.4 s poll is the module's own loop, resumed by hand. The client is the last LoadoutChanged and RangeState
it was sent, which is what HudClient and CombatClient keep.

The invariants (each has a planted fault aimed at it, see PLANTS):
  I1  a take adds the podium's gun to the next free slot and never removes or changes a different gun
      while a slot is free; the gun just taken is in hand;
  I2  a take of a gun already held never adds a second copy (in hand or not, twice in one frame, after a
      slot swap); it is put in hand and topped up, and a retake mid-reload ends the reload;
  I3  range guns never reach a match: a match loadout holds none, the range never clears or writes into
      it, the range closes on everyone when a match starts, and a take is refused while one runs;
  I4  walking off the terrace, or dying and respawning in the lobby, hands every range gun back;
  I5  the client's hotbar, held slot and range mode, and the gun on the character, match the server
      after every take, retake, walk-off, respawn and match start;
  I6  every podium hands out the gun its label shows, every take, every day of the rotation, and no
      spot on the terrace is in reach of two podium prompts;
  I7  saved data is only ever read.
Things it measures but does not fail on are printed as FINDING lines (reports/trial-guns-proof.md).

    python tools/trial_guns_proof_check.py [root]            the checks
    python tools/trial_guns_proof_check.py [root] --plant    the planted faults; every one must be caught

Not covered: Roblox's own ProximityPrompt choice when a player is near two prompts (the geometry says it
never is), network order and timing between the two snapshots a take sends, and anything drawn on screen.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("trial_guns_proof_check: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))


# ---------------------------------------------------------------------------------------------- Luau
# The converter is tools/roadkill_proof_check.py's (branch task/prove-roadkill), which took it from
# tools/explosive_dispatch_check.py: compound assignment, and `continue` as a goto to the loop's end.

def _strip(line, state):
    out, i, n = [], 0, len(line)
    while i < n:
        if state:
            j = line.find(state, i)
            if j < 0:
                return "".join(out), state
            i, state = j + len(state), None
            continue
        if line.startswith("--", i):
            m = re.match(r"--\[(=*)\[", line[i:])
            if not m:
                break
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            continue
        m = re.match(r"\[(=*)\[", line[i:])
        if m:
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            out.append('""')
            continue
        c = line[i]
        if c in "\"'`":
            j = i + 1
            while j < n and line[j] != c:
                j += 2 if line[j] == "\\" else 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), state


def luau_to_lua(src):
    src = re.sub(r"^(\s*)([\w.\[\]\"':()]+) ([+\-*/%^]|\.\.)= (.+?)(\s*--.*)?$",
                 lambda m: "%s%s = %s %s (%s)%s" % (m.group(1), m.group(2), m.group(2), m.group(3), m.group(4), m.group(5) or ""),
                 src, flags=re.M)
    stack, state, pending, count, out = [], None, 0, 0, []
    for line in src.split("\n"):
        code, state = _strip(line, state)
        new, closes = line, []
        for t in re.findall(r"[A-Za-z_]\w*", code):
            if t == "function" or t == "if":
                stack.append([t, None])
            elif t in ("while", "for"):
                stack.append(["loop", None])
                pending += 1
            elif t == "do":
                if pending:
                    pending -= 1
                else:
                    stack.append(["do", None])
            elif t == "repeat":
                stack.append(["repeat", None])
            elif t == "continue":
                loop = next(e for e in reversed(stack) if e[0] in ("loop", "repeat"))
                if loop[1] is None:
                    count += 1
                    loop[1] = "continue_%d" % count
                new = re.sub(r"\bcontinue\b", "goto " + loop[1], new, count=1)
            elif t in ("end", "until"):
                e = stack.pop()
                if e[1]:
                    closes.append(e[1])
        for label in closes:
            new = re.sub(r"\bend\b", "::%s:: end" % label, new, count=1)
        out.append(new)
    if stack:
        raise SyntaxError("unbalanced blocks")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------- tree

SERVER = ("ServerScriptService", "Modules")
SHARED = ("ReplicatedStorage", "Shared")
FILES = {
    "RangeService": SERVER, "WeaponService": SERVER, "LobbyService": SERVER, "MatchService": SERVER,
    "PlayerData": SERVER,
    "WeaponData": SHARED, "ArsenalExpansion": SHARED, "CreativeArsenal": SHARED, "WorkshopArsenal": SHARED,
    "ItemData": SHARED, "MatchConfig": SHARED, "Rarity": SHARED, "SafeValue": SHARED,
}
# Loaded whole into the world; LobbyService and MatchService are only cut from.
WHOLE = ["RangeService", "WeaponService", "WeaponData", "ArsenalExpansion", "CreativeArsenal",
         "WorkshopArsenal", "ItemData", "MatchConfig", "Rarity", "SafeValue"]


class Tree:
    """The game's text, read from `root`, with in-memory replacements (the planted faults)."""

    def __init__(self, root, swaps=None):
        self.root, self.swaps = root, swaps or {}

    def text(self, name):
        text = open(os.path.join(self.root, *FILES[name], name + ".lua"), encoding="utf-8").read()
        for before, after in self.swaps.get(name, []):
            if text.count(before) != 1:
                sys.exit("trial_guns_proof_check: plant anchor missing or not unique in %s: %r" % (name, before[:80]))
            text = text.replace(before, after, 1)
        return text


def cut(text, head, tail="\nend\n"):
    a = text.index(head)
    return text[a:text.index(tail, a) + len(tail)]


def between(text, head, stop):
    a = text.index(head)
    return text[a:text.index(stop, a)]


def number(pattern, text):
    m = re.search(pattern, text, re.M)
    if not m:
        sys.exit("trial_guns_proof_check: can't find %r" % pattern)
    return [float(g) for g in m.groups()]


def cuts(tree):
    lobby = tree.text("LobbyService")
    arena = between(lobby, "local function buildArena(", "\nend\n")
    range_block = (
        between(arena, '\tlocal RangeService = require(script.Parent:WaitForChild("RangeService"))', "\n\n")
        + "\n" + between(arena, "\t-- Three Legendary guns on lit pedestals, turning.\n", "\tlocal arenaAnchor = "))
    cx, _, cz = number(r"local center = base \+ Vector3\.new\(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", arena)
    (radius,) = number(r"local terraceRadius = ([\d.]+)", arena)
    (height,) = number(r"^local ARENA_HEIGHT = ([\d.]+)", lobby)
    sx, sy, sz = number(r"^LobbyService\.SpawnOffset = Vector3\.new\(([-\d.]+), ([-\d.]+), ([-\d.]+)\)", lobby)
    (half,) = number(r"^LobbyService\.SpawnHalfWidth = ([\d.]+)", lobby)
    ms = tree.text("MatchService")
    return {
        "range": luau_to_lua(range_block),
        "lobbyCFrame": luau_to_lua(cut(ms, "local function lobbyCFrame()")),
        "placeInLobby": luau_to_lua(cut(ms, "function MatchService.PlaceInLobby(")),
        "onCharacterAdded": luau_to_lua(cut(ms, "function MatchService.OnCharacterAdded(")),
        "centerX": cx, "centerZ": cz, "terraceRadius": radius, "arenaHeight": height,
        "spawnX": sx, "spawnY": sy, "spawnZ": sz, "spawnHalfWidth": half,
    }


def run(root, swaps=None):
    tree = Tree(root, swaps)
    try:
        lua = LuaRuntime(unpack_returned_tuples=True)
        sources = lua.table_from({name: luau_to_lua(tree.text(name)) for name in WHOLE})
        c = lua.table_from(cuts(tree))
        world = open(os.path.join(HERE, "trial_guns_proof_world.lua"), encoding="utf-8").read()
        rows, findings, counts = lua.execute(world, sources, c)
        return ([(bool(r["ok"]), r["line"]) for r in rows.values()], list(findings.values()),
                {k: v for k, v in counts.items()})
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])], [], {}


# ---------------------------------------------------------------------------------------------- static
# What the world does not run, counted from the source: every path that could hand out, replace or clear
# a gun, and what the client assumes.

def lua_files(root, top):
    for dirpath, _, names in os.walk(os.path.join(root, top)):
        for n in names:
            if n.endswith(".lua"):
                yield os.path.join(dirpath, n)


def static(root):
    out = []
    server = list(lua_files(root, "ServerScriptService"))
    client = list(lua_files(root, "StarterPlayerScripts"))

    def calls(pattern, files, skip=()):
        hits = []
        for path in files:
            if os.path.basename(path) in skip:
                continue
            for i, line in enumerate(open(path, encoding="utf-8"), 1):
                if re.search(pattern, line) and not line.lstrip().startswith("--"):
                    hits.append("%s:%d" % (os.path.relpath(path, root), i))
        return hits

    give = calls(r"RangeService\.Give\(", server, skip=("RangeService.lua",))
    out.append((len(give) == 1 and "LobbyService.lua" in give[0],
                "static: RangeService.Give has one caller, the podium prompt (%s)" % ", ".join(give)))
    giveweapon = calls(r"WeaponService\.GiveWeapon\(", server, skip=("WeaponService.lua",))
    out.append((True, "static: WeaponService.GiveWeapon callers: %d (%s)" % (len(giveweapon), ", ".join(giveweapon))))
    reset = calls(r"WeaponService\.Reset\(", server, skip=("WeaponService.lua",))
    out.append((True, "static: WeaponService.Reset callers: %d (%s)" % (len(reset), ", ".join(reset))))
    ms = open(os.path.join(root, *SERVER, "MatchService.lua"), encoding="utf-8").read()
    start = cut(ms, "local function startMatch()")
    ok = start.find("WeaponService.Reset(player)") != -1 and start.find("WeaponService.Reset(player)") < start.find("CombatService.SetEnabled(true)")
    out.append((ok, "static: startMatch gives every joining player a new loadout (WeaponService.Reset) before it turns combat on"))
    drop = open(os.path.join(root, "ServerScriptService", "Bootstrap.server.lua"), encoding="utf-8").read()
    ok = re.search(r'Remotes\.Event\("DropSlot"\)\.OnServerEvent:Connect\(function\(player, slotIndex\)\n\tif not RateLimit\.Take\(player, "DropSlot"\) or not MatchService\.IsPlaying\(player\) then', drop)
    out.append((bool(ok), "static: a hotbar slot can only be dropped on the floor mid-match (DropSlot is gated on IsPlaying), so no range gun can be dropped in the lobby"))
    pd = open(os.path.join(root, *SERVER, "PlayerData.lua"), encoding="utf-8").read()
    words = [w for w in ("loadout", "Loadout", "slots", "WeaponService", "RangeService") if w in pd]
    out.append((not words, "static: PlayerData.lua never names a loadout, slots, WeaponService or RangeService%s" % (" (it names %s)" % words if words else "")))
    slot1 = calls(r"slots\[1\]", client)
    held = calls(r"loadout\.equipped\s*=[^=]", client)
    out.append((not slot1 and not held, "static: no client script reads slots[1] as the gun in hand or sets its own held slot "
                "(%d files read; slots[1]: %d, equipped writes: %d)" % (len(client), len(slot1), len(held))))
    return out


# ---------------------------------------------------------------------------------------------- plants
# Each one breaks an invariant the code must keep forever; the check must fail with it in.

PLANTS = [
    ("I1: a take starts a fresh loadout every time (the pre-e666c61 behaviour)", "RangeService",
     "if ours and WeaponService.Get(player) == ours then", "if false then"),
    ("I1: a pickup fills the slot in hand even with free slots (WeaponService.GiveWeapon)", "WeaponService",
     "local index = firstEmptySlot(loadout)\n\tif index then\n\t\tlocal wasEmptyHanded",
     "local index = loadout.equipped or firstEmptySlot(loadout)\n\tif index then\n\t\tlocal wasEmptyHanded"),
    ("I1: the gun just taken is not put in hand", "RangeService",
     "\t\t\t\tWeaponService.Equip(player, index)\n\t\t\t\theld = true", "\t\t\t\theld = true"),
    ("I2: no look for a gun already held (a repeat take adds a copy)", "RangeService",
     "if slot and slot.kind == \"weapon\" and slot.id == weaponId then\n\t\t\t\t-- The same gun again",
     "if false then\n\t\t\t\t-- The same gun again"),
    ("I2: a retake of the gun in hand leaves its reload running (the S8 finding before pc/range-reload-fix)", "RangeService",
     "\t\t\t\tWeaponService.CancelReload(player)\n", ""),
    ("I3/I4: the range writes into a loadout it did not make (identity check gone)", "RangeService",
     "if ours and WeaponService.Get(player) == ours then", "if ours then"),
    ("I3: the poll ignores a match starting", "RangeService",
     "\t\t\telseif CombatService.IsEnabled() then\n\t\t\t\tstop(player)", "\t\t\telseif false then\n\t\t\t\tstop(player)"),
    ("I3: the range hands guns out while a match runs", "RangeService",
     "\tif CombatService.IsEnabled() then\n\t\treturn false, \"The range is closed", "\tif false then\n\t\treturn false, \"The range is closed"),
    ("I4: walking off keeps the guns (stop never clears)", "RangeService",
     "\t\tWeaponService.Clear(player)\n\t\t-- Clearing the loadout", "\t\t-- Clearing the loadout"),
    ("I4: walking off leaves the gun welded in hand", "RangeService",
     "\t\tif held then\n\t\t\theld:Destroy()\n\t\tend\n\t\tWeaponService.Push(player)",
     "\t\tWeaponService.Push(player)"),
    ("I4: a lobby respawn keeps the old loadout (PlaceInLobby never clears)", "MatchService",
     "\tcharacter:PivotTo(lobbyCFrame())\n\tWeaponService.Clear(player)\n", "\tcharacter:PivotTo(lobbyCFrame())\n"),
    ("I5: a retake tops up without telling the client", "RangeService",
     "\t\t\t\tWeaponService.Equip(player, index)\n\t\t\t\tWeaponService.Push(player)\n",
     "\t\t\t\tWeaponService.Equip(player, index)\n"),
    ("I5: switching the held slot doesn't tell the client (WeaponService.Equip)", "WeaponService",
     "\tselectSlot(player, loadout, slotIndex)\n\tWeaponService.Push(player)\nend",
     "\tselectSlot(player, loadout, slotIndex)\nend"),
    ("I6: a podium hands out a different gun from the one it shows", "LobbyService",
     "RangeService.Give(player, entry.id)", "RangeService.Give(player, legendaries[1].id)"),
    ("I6: podium prompts reach 12 studs again (two in reach at once)", "LobbyService",
     "prompt.MaxActivationDistance = 8\n\t\t\tprompt.RequiresLineOfSight = false\n\t\t\tprompt.Parent = pedestal",
     "prompt.MaxActivationDistance = 12\n\t\t\tprompt.RequiresLineOfSight = false\n\t\t\tprompt.Parent = pedestal"),
    ("I7: the inventory writes to saved data", "WeaponService",
     "\tlocal data = PlayerData.Get(player)\n\tlocal skinId", "\tlocal data = PlayerData.Get(player)\n\tPlayerData.Save(player)\n\tlocal skinId"),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    if "--plant" in sys.argv:
        caught = 0
        for label, name, before, after in PLANTS:
            rows, _, _ = run(root, {name: [(before, after)]})
            failed = [line for ok, line in rows if not ok]
            caught += bool(failed)
            print("  %s: %s%s" % ("CAUGHT" if failed else "MISSED", label, (" -> " + failed[0][:150]) if failed else ""))
        print("trial_guns_proof_check planted faults: %d/%d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)

    rows, findings, counts = run(root)
    rows = rows + static(root)
    for ok, line in rows:
        print("  %s %s" % ("ok  " if ok else "FAIL", line))
    for line in findings:
        print("  FINDING " + line)
    if counts:
        print("  examined: %d weapons, %d eligible Legendaries, %d podiums (%s), %d days of the rotation, "
              "%d terrace spots (reach %s), %d podium takes in all, %d sync moments; pushes per take: %s"
              % (counts["weapons"], counts["eligible"], counts["podiums"], counts["podiumGuns"], counts["S0 days"],
                 counts["spots"], counts["reach"], counts["takes"] + counts["S0 takes"], counts["syncChecks"], counts["pushes"]))
    bad = sum(1 for ok, _ in rows if not ok)
    print("trial_guns_proof_check: %d checks, %d failed" % (len(rows), bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
