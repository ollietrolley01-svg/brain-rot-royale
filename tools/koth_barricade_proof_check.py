"""Proof of OLIVER_LIST #114, "popup barricade in the team-mode kit; two objectives on KOTH", without Studio.

    python3 tools/koth_barricade_proof_check.py [repo]              the checks, then every planted fault
    python3 tools/koth_barricade_proof_check.py [repo] --no-plants  the checks only

Needs `pip install lupa`. Two halves, each running the shipped modules in lupa:

(a) THE KIT (tools/koth_barricade_kit_world.lua, on tools/destruct_mocks.lua and the world of
    tools/defense_anywhere_check.py). A spawned player's whole chain: GameModes.RollLoadout ->
    ModeTeams.GrantLoadout (cut out of ModeTeams.lua) -> the REAL WeaponService inventory -> Equip and
    StartUse (the click) -> DefenseService's throw -> the structure stands -> the damage hook CombatService
    calls -> it collapses and is cleared. Then the REAL ModeKingOfTheHill builds its two objectives and a kit
    barricade is thrown at each centre (must refuse and hand the kit back) and onto each ring (must build).
    Held to: every life carries exactly one pop-up structure kind, 2 of it capped by its stack, tagged
    issued; every kind comes up; every use builds one and spends one; a spent stack throws nothing; each
    structure has its health and owner, solid parts, survives a hit short of its health and collapses
    past it; the objective centre refuses on both paths (a player's throw and a bot's Deploy).
    BotService is read from source: every structure the kit can roll is one a bot counts as its defense.

(b) THE OBJECTIVES (tools/koth_barricade_capture_world.lua). The REAL GameMode match driver (its 0.25 s
    tick and once-a-second score), ModeKingOfTheHill, and the shipped numbers in GameModes, ObjectiveZone
    and MatchConfig. Held to: two objectives on the battleground's two points; standing alone captures
    within one tick; an objective stays yours when you leave and scores 1 a second with nobody on it; the
    other side alone takes it back; both sides on it is Contested and changes nothing; dead and downed
    bodies hold nothing; the ring's edge is where ObjectiveZone draws it; one objective scores 10 in 10 s
    and two score 20; the score target finishes the match once, exactly on target, at 250 s (one) or
    125 s (both), with nothing scored after; with no captures the time limit ends it at 480 s; a bot's
    kit (GameMode's SpawnLoadout) carries one pop-up structure. Also printed: where the open-arena fallback
    (no battleground) puts the two objectives, over seeds and arena sizes.

Planted faults (each must be caught; each aimed at something the code must keep for good): the defense
pool dropped from the kit; a click that spends the kit and throws nothing; a structure that never
collapses; the objective-centre rule gone; KOTH no longer marking its rings for placement; a bot no
longer counting the Pop-up Bunker; only one objective built; an objective lost when its holder steps off;
a contest that hands the objective over; scoring every tick instead of every second; only objective A
scoring; the score target ignored; dead bodies capturing.

What this cannot show: how any of it looks (the pop-up, the rings, the beams, the A/B markers -- that is a
Studio render), a real bullet's ray finding the wall (the damage enters at CombatService's hook), real
Roblox physics and terrain voxels, and real players or bots walking onto the objectives.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("koth_barricade_proof_check: needs lupa (pip install lupa)")

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from car_placement_luau import luau_to_lua  # noqa: E402

SHARED = "ReplicatedStorage/Shared/"
MODULES = "ServerScriptService/Modules/"
KIT_FILES = {
    # The defense world's own modules (tools/defense_anywhere_check.py FILES).
    "DefensePlacement": SHARED + "DefensePlacement.lua",
    "ItemData": SHARED + "ItemData.lua",
    "ItemModels": SHARED + "ItemModels.lua",
    "ZFight": SHARED + "ZFight.lua",
    "SafeValue": SHARED + "SafeValue.lua",
    "DefenseService": MODULES + "DefenseService.lua",
    "DefensePreview": "StarterPlayerScripts/DefensePreview.lua",
    # This chain's.
    "WeaponServiceReal": MODULES + "WeaponService.lua",
    "GameModes": SHARED + "GameModes.lua",
    "Rarity": SHARED + "Rarity.lua",
    "CosmeticData": SHARED + "CosmeticData.lua",
    "WeaponData": SHARED + "WeaponData.lua",
    "ArsenalExpansion": SHARED + "ArsenalExpansion.lua",
    "CreativeArsenal": SHARED + "CreativeArsenal.lua",
    "CreativeRounds": SHARED + "CreativeRounds.lua",
    "Ballistics": SHARED + "Ballistics.lua",
    "WorkshopArsenal": SHARED + "WorkshopArsenal.lua",
    "MatchConfig": SHARED + "MatchConfig.lua",
    "ObjectiveZone": SHARED + "ObjectiveZone.lua",
    "ModeKingOfTheHill": MODULES + "ModeKingOfTheHill.lua",
}
CAPTURE_FILES = {
    "GameModes": SHARED + "GameModes.lua",
    "Rarity": SHARED + "Rarity.lua",
    "ObjectiveZone": SHARED + "ObjectiveZone.lua",
    "MatchConfig": SHARED + "MatchConfig.lua",
    "ModeKingOfTheHill": MODULES + "ModeKingOfTheHill.lua",
    "GameMode": MODULES + "GameMode.lua",
}
BOTSERVICE = MODULES + "BotService.lua"
MODETEAMS = MODULES + "ModeTeams.lua"

# The battleground's two objective points as TeamBattleground builds them (A on the keep's floor, B at the
# pit's fountain; printed by tools/team_battleground_modeteams_check.py, which proves KOTH takes them).
BATTLEGROUND = [(37.0, 10.8, -21.0), (-47.0, 10.3, 5.0)]
STRUCTURES = ("RotBarricade", "PopupBunker", "BrainrotFortress")

# (label, which half, file, old, new): each must be caught.
PLANTS = [
    ("the defense pool dropped from the kit", "kit", SHARED + "GameModes.lua",
     '"BrainrotFortress" }, kinds = 1, count = 2 }', '"BrainrotFortress" }, kinds = 0, count = 2 }'),
    ("a click on the kit spends it and throws nothing", "kit", MODULES + "WeaponService.lua",
     "return WeaponService.DefenseEffect(player, item.id, aimPoint) == true", "return true"),
    ("a structure never collapses", "kit", MODULES + "DefenseService.lua",
     "\tif entry.health <= 0 then\n\t\tcollapse(model)", "\tif entry.health < -1e9 then\n\t\tcollapse(model)"),
    ("the objective-centre rule gone", "kit", SHARED + "DefensePlacement.lua",
     "DefensePlacement.ObjectiveCentreShare = 0.35", "DefensePlacement.ObjectiveCentreShare = 0"),
    ("KOTH stops marking its rings for placement", "kit", MODULES + "ModeKingOfTheHill.lua",
     'folder:SetAttribute("HillRadius", radius())', 'folder:SetAttribute("HillRadiusUnread", radius())'),
    ("a bot no longer counts the Pop-up Bunker", "bots", BOTSERVICE,
     'elseif id == "RotBarricade" or id == "PopupBunker" or id == "BrainrotFortress" then',
     'elseif id == "RotBarricade" or id == "BrainrotFortress" then'),
    ("only objective A is built", "capture", MODULES + "ModeKingOfTheHill.lua",
     "for index, point in ipairs(battleground.objectives) do",
     "for index, point in ipairs({ battleground.objectives[1] }) do"),
    ("an objective is lost when its holder steps off", "capture", MODULES + "ModeKingOfTheHill.lua",
     "\t\tif alone then\n\t\t\tobjective.owner = alone\n\t\tend", "\t\tobjective.owner = alone"),
    ("a contest hands the objective to team 1", "capture", MODULES + "ModeKingOfTheHill.lua",
     'return nil, "Contested"', 'return 1, "Contested"'),
    ("scoring every tick instead of every second", "capture", MODULES + "GameMode.lua",
     "if accumulated >= 1 then\n\t\t\t\t\taccumulated -= 1",
     "if accumulated >= 0.25 then\n\t\t\t\t\taccumulated -= 0.25"),
    ("only objective A scores", "capture", MODULES + "ModeKingOfTheHill.lua",
     "\t\t\ttable.insert(scoring, objective.owner)", "\t\t\tif index == 1 then table.insert(scoring, objective.owner) end"),
    ("the score target ignored", "capture", MODULES + "GameMode.lua",
     "if scores[team] >= (current.scoreTarget or math.huge) then", "if scores[team] >= math.huge then"),
    ("dead bodies capture", "capture", MODULES + "ModeKingOfTheHill.lua",
     "if humanoid and root and humanoid.Health > 0 then", "if humanoid and root then"),
]


def read(repo, rel, plant=None):
    with open(os.path.join(repo, rel), encoding="utf-8") as f:
        text = f.read()
    if plant and plant[2] == rel:
        if text.count(plant[3]) != 1:
            raise SystemExit("planted fault did not apply (%s): text found %d times" % (plant[0], text.count(plant[3])))
        text = text.replace(plant[3], plant[4], 1)
    return text


def grant_source(repo, plant=None):
    text = read(repo, MODETEAMS, plant)
    start = text.index("function ModeTeams.GrantLoadout(player)")
    end = text.index("\nend\n", start) + 5
    return luau_to_lua(text[start:end])


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)]


def run_kit(repo, plant=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {name: luau_to_lua(read(repo, rel, plant)) for name, rel in KIT_FILES.items()}
    sources["GrantLoadout"] = grant_source(repo, plant)
    table = lua.table_from(sources)
    with open(os.path.join(TOOLS, "defense_anywhere_world.lua"), encoding="utf-8") as f:
        world = lua.execute(f.read(), mock, table)
    with open(os.path.join(TOOLS, "koth_barricade_kit_world.lua"), encoding="utf-8") as f:
        kit = lua.execute(f.read(), mock, world, table)
    problems = lua_list(kit.problems)
    # A warning from the chain (a failed held-gun refresh is the stubbed gun model, not the kit) is shown.
    warns = [w for w in lua_list(kit.warns) if "held gun refresh" not in w]
    problems += ["[warn] " + w for w in warns]
    return dict(kit.counts), problems, lua_list(kit.lines), dict(kit.byKind)


def run_capture(repo, plant=None, fallback=False):
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = {name: luau_to_lua(read(repo, rel, plant)) for name, rel in CAPTURE_FILES.items()}
    with open(os.path.join(TOOLS, "koth_barricade_capture_world.lua"), encoding="utf-8") as f:
        world = lua.execute(f.read(), lua.table_from(sources))
    points = lua.table_from([world.vec(*p) for p in BATTLEGROUND])
    out = world.runScenes(points)
    result = (dict(out.counts), lua_list(out.problems), lua_list(out.lines))
    if not fallback:
        return result
    spread = []
    for arena in (600, 700, 875):
        gaps = [dict(g) for g in lua_list(world.fallback(arena, 20, None))]
        spread.append((arena, gaps))
    return result + (spread,)


def run_bots(repo, plant=None):
    """BotService read from source: the ids its SpawnLoadout branch counts as a defense, and its cap."""
    text = read(repo, BOTSERVICE, plant)
    problems, lines = [], []
    match = re.search(r'elseif ((?:id == "\w+"(?: or )?)+) then\s*\n\s*-- A bot\'s defense is one generic pop-up', text)
    counted = set(re.findall(r'id == "(\w+)"', match.group(1))) if match else set()
    gm = read(repo, SHARED + "GameModes.lua")
    pool = re.search(r'\{ ids = \{ ((?:"\w+",? ?)+)\}, kinds = (\d+), count = (\d+) \}', gm[gm.index('"RotBarricade"') - 20:])
    pool_ids = set(re.findall(r'"(\w+)"', pool.group(1))) if pool else set()
    cap = re.search(r"^local BOT_MAX_DEFENSES = (\d+)", text, re.M)
    cap = int(cap.group(1)) if cap else 0
    count = int(pool.group(3)) if pool else 0
    missing = pool_ids - counted
    if not match or missing:
        problems.append("[bots] structures the kit rolls that a bot does not count as a defense: %s" % sorted(missing or pool_ids))
    if cap < count:
        problems.append("[bots] BOT_MAX_DEFENSES %d is below the kit's %d" % (cap, count))
    placed = re.findall(r'DefenseService\.Deploy\(bot, bot\.character, "(\w+)"', text)
    lines.append("bots (source): kit pool %s x%d; BotService counts %s as defenses (cap %d); a bot builds %s"
                 % (sorted(pool_ids), count, sorted(counted), cap, sorted(set(placed))))
    return problems, lines


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = args[0] if args else os.path.dirname(TOOLS)
    failures = 0

    counts, problems, lines, by_kind = run_kit(repo)
    print("(a) the kit: GrantLoadout -> WeaponService -> throw -> structure -> damage")
    for line in lines:
        print("   " + line)
    print("   counts: %s" % ", ".join("%s %s" % kv for kv in sorted(counts.items())))
    bot_problems, bot_lines = run_bots(repo)
    for line in bot_lines:
        print("   " + line)
    problems += bot_problems

    ccounts, cproblems, clines, spread = run_capture(repo, fallback=True)
    print("(b) the objectives: GameMode + ModeKingOfTheHill, shipped numbers")
    for line in clines:
        print("   " + line)
    for arena, gaps in spread:
        two = sum(1 for g in gaps if g["count"] == 2)
        small = [g["gap"] for g in gaps if g["count"] == 2]
        print("   open-arena fallback, arena %d: %d of %d seeds build 2; gap min %.0f max %.0f; %d under SITE_GAP 220"
              % (arena, two, len(gaps), min(small or [0]), max(small or [0]), sum(1 for g in small if g < 220)))
        if two != len(gaps):
            cproblems.append("[two] open-arena fallback, arena %d: %d of %d seeds built two objectives" % (arena, two, len(gaps)))
    print("   counts: %d capture checks" % ccounts["checks"])
    problems += cproblems

    for p in problems:
        print("FAIL " + p)
    failures += len(problems)
    print("koth_barricade_proof_check: %s (%d failures)" % ("OK" if not problems else "FAILED", len(problems)))

    if "--no-plants" not in sys.argv:
        caught = 0
        for plant in PLANTS:
            label, half = plant[0], plant[1]
            try:
                if half == "kit":
                    found = run_kit(repo, plant)[1]
                elif half == "bots":
                    found = run_bots(repo, plant)[0]
                else:
                    found = run_capture(repo, plant)[1]
            except SystemExit:
                raise
            except Exception as err:  # the harness breaking is not a catch
                print("  CRASHED  %s: %s" % (label, str(err).splitlines()[0]))
                continue
            if found:
                caught += 1
                print("  CAUGHT   %s  (%s)" % (label, found[0].splitlines()[0][:150]))
            else:
                print("  MISSED   %s" % label)
        print("koth_barricade_proof_check plants: %d of %d caught" % (caught, len(PLANTS)))
        if caught != len(PLANTS):
            failures += 1
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
