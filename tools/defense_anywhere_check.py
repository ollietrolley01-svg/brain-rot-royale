"""Place defenses anywhere (OLIVER_LIST #128, Oliver 09-24), proved without Studio.

    python3 tools/defense_anywhere_check.py [repo] [--only NAME] [--no-plants]   -> exit 0 when clean

Runs the REAL ReplicatedStorage/Shared/DefensePlacement.lua, ServerScriptService/Modules/DefenseService.lua
and StarterPlayerScripts/DefensePreview.lua (with the real ItemData, ItemModels, ZFight and SafeValue)
over a mock world (tools/defense_anywhere_world.lua on tools/destruct_mocks.lua): exact raycasts against
rotated parts and a heightfield terrain with water, and GetPartBoundsInBox answering with bounding
boxes the way Roblox does.

Every scene is run for all three structures, twice: deployed straight onto the spot (DefenseService.Deploy,
the path a bot takes, after DefenseService.CheckSite -- which must agree), and thrown by a player
(WeaponService.DefenseEffect -> the real throw, time advanced until it lands) with DefensePreview's ghost
drawn first from the same throw.

  REASONABLE (must build): flat; terrain slopes of 10-60 degrees across, along and diagonal to the
  structure; uneven ground; a flat roof; 3 studs from a roof's edge; part-built roofs sloped 20 and 35;
  rubble and a loose piece; a crate; thrown at a building's wall; into a corner; shallow water; a lake's
  edge; a 20-stud cliff's edge; straight into a doorway; on an objective's ring away from its centre.
  PROTECTED (must refuse, for the right reason): a player, a bot, a vehicle in the way; a spawn pad; a
  team base's spawn bunker; an objective's centre; a team base's vehicle lane; a covered passage it
  would shut; the lobby; off the map; deep water; a NoBuild tag. And the cap: a fourth knocks the oldest
  down, with a notice.

Measured on everything built, from the geometry alone (the world file never asks DefensePlacement):
  reach   every post and ladder stands on the ground under it (bottom within 0.05 above, 3 below);
  float   every point along the base's edges rests (<= 1 stud of air) or has a post within 3.6
          studs, or is over nothing within 42 (an overhang), and overhangs are at most half;
  pen     no structure part more than 0.45 into the terrain, nor into any anchored part;
  body    no part inside a player, bot or vehicle;
  door    the doorway scene's opening, and a body's width either side of it, is left clear;
  preview every built part and footing has a ghost part of the same size in the same place, and the
          ghost says "builds" exactly when the throw builds.
Planted faults (each must be caught; they are aimed at invariants, not at today's bugs): the old water
refusal back; the old "too steep" refusal back; a deck on a slope with no posts (floating); the body
check gone (a barricade inside a player); the base sunk a stud into the ground; the spawn rule gone;
the preview drawing its footings a hair off the build.

What this cannot show: how it looks (tools/defense_anywhere_gallery.lua is the render), real Roblox
terrain voxels (a heightfield stands in, so the smoothing of a voxel slope is not modelled), and
physics (the kit no longer uses any for a structure).
"""

import os
import sys
import time

from lupa import LuaRuntime

TOOLS = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, TOOLS)
from car_placement_luau import luau_to_lua  # noqa: E402

FILES = {
    "DefensePlacement": "ReplicatedStorage/Shared/DefensePlacement.lua",
    "ItemData": "ReplicatedStorage/Shared/ItemData.lua",
    "ItemModels": "ReplicatedStorage/Shared/ItemModels.lua",
    "ZFight": "ReplicatedStorage/Shared/ZFight.lua",
    "SafeValue": "ReplicatedStorage/Shared/SafeValue.lua",
    "DefenseService": "ServerScriptService/Modules/DefenseService.lua",
    "DefensePreview": "StarterPlayerScripts/DefensePreview.lua",
}

# (label, module, old, new, the problem tags that must appear)
PLANTS = [
    ("the old water refusal back", "DefensePlacement",
     "\tif hit.Material == Enum.Material.Water then\n\t\tcol.surface",
     "\tif hit.Material == Enum.Material.Water then\n\t\tdo return { x = x, z = z } end\n\t\tcol.surface",
     {"accept"}),
    ("the old 'too steep' refusal back", "DefensePlacement",
     "\tlevel -= DefensePlacement.Embed\n",
     "\tlevel -= DefensePlacement.Embed\n\tif level - ref > 7 then return nil, \"Too steep to build there.\", \"ground\" end\n",
     {"accept"}),
    ("a floating deck on a slope (no posts)", "DefensePlacement",
     "if gap > DefensePlacement.PostMin and gap <= DefensePlacement.MaxStilt then",
     "if false then",
     {"float"}),
    ("a barricade inside a player (body check gone)", "DefensePlacement",
     "\t\t\tif DefensePlacement.BoxesOverlap(part.CFrame, part.Size, roomCF, roomSize) then\n\t\t\t\treturn \"body\"",
     "\t\t\tif false then\n\t\t\t\treturn \"body\"",
     {"refuse"}),
    ("the base sunk a stud into the ground", "DefensePlacement",
     "DefensePlacement.Embed = 0.15", "DefensePlacement.Embed = 1.15",
     {"pen"}),
    ("the spawn rule gone", "DefensePlacement",
     "\t\tif part:IsA(\"SpawnLocation\") then\n\t\t\treturn R.spawn",
     "\t\tif false then\n\t\t\treturn R.spawn",
     {"refuse"}),
    ("the preview's footings drawn a hair off the build", "DefensePreview",
     "\t\tpart.CFrame = footing.cframe\n",
     "\t\tpart.CFrame = footing.cframe + Vector3.new(0, 0.05, 0)\n",
     {"preview"}),
]


def run(repo, plant=None, only=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name, rel in FILES.items():
        with open(os.path.join(repo, rel), encoding="utf-8") as f:
            src = f.read()
        if plant and plant[1] == name:
            if plant[2] not in src:
                raise SystemExit("planted fault did not apply (%s): text not found" % plant[0])
            src = src.replace(plant[2], plant[3], 1)
        sources[name] = luau_to_lua(src)
    with open(os.path.join(TOOLS, "defense_anywhere_world.lua"), encoding="utf-8") as f:
        world = lua.execute(f.read(), mock, lua.table_from(sources))
    counts = world.runAll(only)
    problems = [world.problems[i] for i in range(1, len(world.problems) + 1)]
    lines = [world.lines[i] for i in range(1, len(world.lines) + 1)]
    return dict(counts), problems, lines


def main():
    args = [a for a in sys.argv[1:]]
    only = None
    if "--only" in args:
        only = args[args.index("--only") + 1]
        del args[args.index("--only"):args.index("--only") + 2]
    plants = "--no-plants" not in args
    args = [a for a in args if not a.startswith("--")]
    repo = args[0] if args else os.path.dirname(TOOLS)

    started = time.time()
    counts, problems, lines = run(repo, only=only)
    for line in lines:
        print("  " + line)
    print("defense anywhere: %d scene x structure runs, %d built, %d refused as they must; %d throws, "
          "%d ghost-vs-build compared; %d footing parts; %d rays; %.1fs"
          % (counts["scenes"], counts["built"], counts["refused"], counts["throws"], counts["previewChecked"],
             counts["posts"], counts["rays"], time.time() - started))
    for p in problems:
        print("  PROBLEM " + p)
    failed = bool(problems)

    if plants and not only:
        for plant in PLANTS:
            _, found, _ = run(repo, plant=plant)
            tags = {p[1:p.index("]")] for p in found}
            caught = bool(tags & plant[4])
            print("self-test planted %s: %s (%d problem(s): %s)" % (
                plant[0], "caught" if caught else "MISSED", len(found), ", ".join(sorted(tags)) or "none"))
            if not caught:
                failed = True
    print("defense anywhere: %s" % ("FAIL" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
