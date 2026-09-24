"""Repro for critic finding C8 (tools/critic_findings.md): DefensePlacement's "team base vehicle yard"
refusal takes `yard:GetBoundingBox()` of the compound's VehicleYard model. That model has no
PrimaryPart and its WorldPivot is never set, so Roblox returns a box aligned to the WORLD axes, while
the compound is built turned to face the arena centre. At any yaw that is not a multiple of 90 degrees the
refused box is the world AABB of a turned yard, and it swallows most of the base.

Builds the real TeamBaseRuins.Layout (tools/team_base_ruins_check.py's Build) at several yaws and
measures, over a 1-stud grid of the compound's own footprint (92 x 84), the share a defense centred there
is refused by that box (point-in-box, the same margin DefensePlacement adds: 2 * LaneMargin), against the
share an oriented box (the yard in the compound's own frame) would refuse. Also counts how many of the
compound's pads, chest spots and loot spots fall inside.

    python3 tools/critic_yard_nobuild_repro.py [repo] [--plant]    exit 1 while any yaw refuses more than a box square to the compound would.
The fix (TeamBaseRuins gives the yard a PrimaryPart square to the compound) makes it pass; removing
it is the planted fault.
"""
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import team_base_ruins_check as T  # noqa: E402

YAWS = (0, 20, 30, 45, 60, 90)


def lane_margin(repo):
    text = (Path(repo) / "ReplicatedStorage/Shared/DefensePlacement.lua").read_text()
    return float(re.search(r"DefensePlacement\.LaneMargin = ([\d.]+)", text).group(1))


PLANT = ("yard.PrimaryPart = line", "local _ = line")


def measure(repo, src):
    half_margin = lane_margin(repo)  # the size grows by 2 * LaneMargin, so each side by LaneMargin
    bad = False
    for deg in YAWS:
        yaw = math.radians(deg)
        b = T.Build(src)
        _, model, info = b.layout(0, 0, 0, yaw, (200, 60, 60), 1)
        parts = b.dump(model)
        yard = [p for p in parts if p["path"].split("/")[0] == "VehicleYard"]
        c, s = math.cos(yaw), math.sin(yaw)

        def to_local(x, z):
            # CFrame.Angles(0, yaw, 0): local x axis (c, 0, -s), local z axis (s, 0, c)
            return x * c - z * s, x * s + z * c

        # What Roblox's Model:GetBoundingBox gives: turned with the PrimaryPart when the model has one,
        # on the world axes when it has none.
        yard_model = model.FindFirstChild(model, "VehicleYard")
        primary = yard_model.PrimaryPart
        turned = primary is not None
        wlo = [min(T.aabb(p)[0][i] for p in yard) - half_margin for i in (0, 2)]
        whi = [max(T.aabb(p)[1][i] for p in yard) + half_margin for i in (0, 2)]
        # The yard in its own frame: its parts' boxes turned back by the yaw.
        loc = []
        for p in yard:
            centre, axes, h = T.obb(p)
            for sx in (-1, 1):
                for sy in (-1, 1):
                    for sz in (-1, 1):
                        x = centre[0] + sx * h[0] * axes[0][0] + sy * h[1] * axes[1][0] + sz * h[2] * axes[2][0]
                        z = centre[2] + sx * h[0] * axes[0][2] + sy * h[1] * axes[1][2] + sz * h[2] * axes[2][2]
                        loc.append(to_local(x, z))
        llo = [min(v[i] for v in loc) - half_margin for i in (0, 1)]
        lhi = [max(v[i] for v in loc) + half_margin for i in (0, 1)]
        world_in = own_in = total = 0
        for i in range(-46, 47):
            for j in range(-42, 43):
                # a point of the compound's footprint, in world space
                x, z = i * c + j * s, -i * s + j * c
                total += 1
                lx, lz = to_local(x, z)
                inside_own = llo[0] <= lx <= lhi[0] and llo[1] <= lz <= lhi[1]
                if inside_own:
                    own_in += 1
                if (inside_own if turned else (wlo[0] <= x <= whi[0] and wlo[1] <= z <= whi[1])):
                    world_in += 1
        spots = 0
        spot_total = 0
        for key in ("pads", "chestSpots", "lootSpots"):
            for cf in b.cfs(info[key]):
                spot_total += 1
                lx, lz = to_local(cf[0], cf[2])
                if (llo[0] <= lx <= lhi[0] and llo[1] <= lz <= lhi[1]) if turned else (wlo[0] <= cf[0] <= whi[0] and wlo[1] <= cf[2] <= whi[1]):
                    spots += 1
        share_w, share_o = world_in / total, own_in / total
        print("yaw %3d: VehicleYard %s; refused %.0f%% of the base (a box square to the compound: %.0f%%); %d of %d pads/chests/loot spots inside"
              % (deg, "has a PrimaryPart" if turned else "has NO PrimaryPart (world-aligned box)", 100 * share_w, 100 * share_o, spots, spot_total))
        if share_w > share_o + 0.01:
            bad = True
    return bad


def main():
    repo = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = T.sources(repo)
    bad = measure(repo, src)
    if "--plant" in sys.argv:
        planted = dict(src)
        if PLANT[0] not in src["ruins"]:
            print("plant: ANCHOR MISSING")
            sys.exit(1)
        planted["ruins"] = src["ruins"].replace(PLANT[0], PLANT[1], 1)
        print("-- planted: the yard without a PrimaryPart")
        caught = measure(repo, planted)
        print("plant (yard box on the world axes): %s" % ("caught" if caught else "MISSED"))
        bad = bad or not caught
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
