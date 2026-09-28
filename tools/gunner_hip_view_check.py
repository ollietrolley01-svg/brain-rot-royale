"""The gunner's own gun stays out of the hip view (Jacob, 2026-09-25: "the gunners gun obscures your view
when not in ads"), without Studio.

Builds every armed vehicle with the REAL ReplicatedStorage/Shared/VehicleModels.lua under lupa (the mock and
the builder from tools/vehicle_models_axis_check.py), reads the turret's GunnerEye marker, and places the hip
camera the way StarterPlayerScripts/GunnerView.lua's Update does: at the eye (on TurretYaw, or on
TurretPitch for a mount that carries it there), turned with the yaw and tipped with the barrel, or, for a
lobbing mortar, tipped toward where its bomb comes down (GunnerView clamps that to -40..12 degrees).
Yaw does not matter to the turret's own parts (they turn with the eye), so each mount is swept over its
whole pitch arc (VehicleWeaponData.ByModel, 1 degree steps). A lobbing view is held from 6 degrees below
level to 12 above (a bomb landing on ground level with the car, or up to about 20 studs below it at the
mortar's shortest range, 218 studs); steeper than that -- a target far down a slope, or a bomb that hits
something right beside the car -- is reported, not held: lifting the eye further takes the grips out of
the arms' reach (H3).

Invariants, each aimed at something the mounts must refuse forever:
  H1  the crosshair's neighbourhood is clear: rays from the eye across 10 degrees either side of the
      middle of the view and from 4 below it to 8 above it (a 11 x 7 grid) meet none of the turret's
      own visible parts (everything welded to TurretYaw or TurretPitch; a sight's glass at 0.8 or more
      transparent is see-through). Parts are held to their bounding boxes, which only over-reports.
  H2  the aim is clear: the ray from the eye to the point 200 studs down the barrel from the muzzle,
      where the server's shot goes and GunnerView's ring is drawn at range, meets none of them.
  H3  the hands still reach: at every pitch each grip (GripR / GripL) is within the viewmodel arm's
      reach of its shoulder seen from the hip eye (Viewmodel's SHOULDER, (UPPER + FOREARM) x
      REACH_COMFORT + SHOULDER_TRAVEL), so a raised eye cannot leave the arms stretched off the gun.
Reported, not held: how much of the lower half of the view the gun fills at rest (it should still show).

Planted faults travel the real pipeline (VehicleModels' source edited and rebuilt):
  - the Rotster's eye back down in its receiver (where it was before this check): H1 and H2 go red
  - a plate across the Ranger's launcher, over its bore line in front of the eye: H1 goes red
  - the scout car's eye lifted far over the gun: H3 goes red
    python3 tools/gunner_hip_view_check.py [repo]        -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vehicle_models_axis_check as ax  # noqa: E402

MARKERS = r"""function(vm, id)
    local m = vm.Build(id, nil, { scheme = 1 })
    local out = {}
    for _, p in ipairs(m:GetChildren()) do
        if p.Name == "TurretYaw" or p.Name == "TurretPitch" then
            for _, a in ipairs(p:GetChildren()) do
                if a.ClassName == "Attachment" then
                    local c = a.CFrame
                    table.insert(out, { p.Name, a.Name, c.p.X, c.p.Y, c.p.Z })
                end
            end
        end
    end
    return out
end"""

DXS = range(-10, 11, 2)
DYS = range(-4, 9, 2)
SEE_THROUGH = 0.8
AIM_RANGE = 200
LOB_HELD = (-6, 12)


def viewmodel_reach(repo):
    """{side: shoulder (view space)}, the most a hand can be from its shoulder."""
    text = (Path(repo) / "StarterPlayerScripts/Viewmodel.lua").read_text(encoding="utf-8")
    num = r"(-?[\d.]+)"
    m = re.search(rf"local SHOULDER = \{{ \[1\] = V\({num}, {num}, {num}\), \[-1\] = V\({num}, {num}, {num}\) \}}", text)
    shoulder = {1: [float(m.group(i)) for i in (1, 2, 3)], -1: [float(m.group(i)) for i in (4, 5, 6)]}
    upper, forearm = map(float, re.search(rf"local UPPER, FOREARM = {num}, {num}", text).groups())
    comfort = float(re.search(rf"local REACH_COMFORT = {num}", text).group(1))
    travel = float(re.search(rf"local SHOULDER_TRAVEL = {num}", text).group(1))
    return shoulder, (upper + forearm) * comfort + travel


def world(part, local):
    return ax.add(part["pos"], [sum(part["cols"][k][i] * local[k] for k in range(3)) for i in range(3)])


def ray_box(origin, direction, part, far):
    """Distance along the ray to the part's box, or None."""
    h = ax.half_sizes(part)
    if part["shape"] == "Cylinder":
        h = [part["size"][0] / 2, h[1], h[2]]
    rel = ax.sub(origin, part["pos"])
    lo, hi = 0.0, far
    for k in range(3):
        o, d = ax.dot(rel, part["cols"][k]), ax.dot(direction, part["cols"][k])
        if abs(d) < 1e-9:
            if abs(o) > h[k]:
                return None
            continue
        t1, t2 = (-h[k] - o) / d, (h[k] - o) / d
        lo, hi = max(lo, min(t1, t2)), min(hi, max(t1, t2))
        if lo > hi:
            return None
    return lo


class Mount:
    def __init__(self, parts, markers, arc):
        by = {p["name"]: p for p in parts}
        self.yaw, self.pitch, self.muzzle = by["TurretYaw"], by["TurretPitch"], by.get("TurretMuzzle")
        self.markers = markers
        self.own = [p for p in ax.visible(parts) if p["anchor"] in ("TurretYaw", "TurretPitch")]
        self.solid = [p for p in self.own if p["transparency"] < SEE_THROUGH]
        self.arc = arc
        self.lobs = arc[1] >= 0  # VehicleWeaponData: only the mortar can't fire below level

    def pose(self, pitch):
        """(eye, look, up, right, posed solid parts, posed marker positions, muzzle) at barrel pitch (degrees)."""
        a = math.radians(pitch)
        up, right, pivot = self.yaw["cols"][1], self.pitch["cols"][0], self.pitch["pos"]

        def tip(point):
            return ax.add(pivot, ax.rotate(ax.sub(point, pivot), right, a))
        points = {}
        for name, (on, local) in self.markers.items():
            base = self.pitch if on == "TurretPitch" else self.yaw
            points[name] = tip(world(base, local)) if on == "TurretPitch" else world(base, local)
        parts = [p if p["anchor"] == "TurretYaw" else ax.posed(p, pivot, right, a) for p in self.solid]
        muzzle = tip(self.muzzle["pos"]) if self.muzzle else None
        return points, parts, muzzle, up, right

    def blocking(self, origin, direction, parts, far=40):
        best = None
        for q in parts:
            d = ray_box(origin, direction, q, far)
            if d is not None and (best is None or d < best[0]):
                best = (d, q["name"])
        return best


def view_pitches(mount):
    lo, hi = mount.arc[1], mount.arc[2]
    barrel = [lo + i for i in range(int(hi - lo) + 1)]
    if not mount.lobs:
        return [(p, p) for p in barrel]
    # A lobbing view looks where the bomb lands, whatever the barrel's pitch: held over LOB_HELD.
    return [(p, v) for p in barrel[::5] + [hi] for v in range(LOB_HELD[0], LOB_HELD[1] + 1, 2)]


def lob_steep(mount):
    """Worst crosshair rays blocked (of the grid) at each view pitch below LOB_HELD: reported only."""
    out = []
    for v in range(-40, LOB_HELD[0], 6):
        worst = 0
        for barrel in range(int(mount.arc[1]), int(mount.arc[2]) + 1, 10):
            points, parts, _, up, right = mount.pose(barrel)
            look = ax.rotate([-c for c in mount.yaw["cols"][2]], right, math.radians(v))
            worst = max(worst, sum(1 for dx in DXS for dy in DYS if mount.blocking(
                points["GunnerEye"], ax.rotate(ax.rotate(look, right, math.radians(dy)), up, math.radians(dx)), parts)))
        out.append(f"{v}:{worst}")
    return " ".join(out)


def audit(mount, label, reach, verbose):
    faults = []
    shoulder, most = reach
    worst_arm, cells, blocked_cells, lower = 0.0, 0, 0, None
    first = {}
    for barrel, look_pitch in view_pitches(mount):
        points, parts, muzzle, up, right = mount.pose(barrel)
        eye = points["GunnerEye"]
        look0 = [-c for c in mount.yaw["cols"][2]]
        look = ax.rotate(look0, right, math.radians(look_pitch))
        vup = ax.rotate(up, right, math.radians(look_pitch))
        for dx in DXS:
            for dy in DYS:
                d = ax.rotate(ax.rotate(look, right, math.radians(dy)), up, math.radians(dx))
                cells += 1
                hit = mount.blocking(eye, d, parts)
                if hit:
                    blocked_cells += 1
                    first.setdefault(("H1", hit[1]), (barrel, look_pitch, dx, dy, hit[0]))
        if muzzle is not None:
            bore = ax.norm(ax.rotate(look0, right, math.radians(barrel)))
            target = ax.add(muzzle, ax.mul(bore, AIM_RANGE))
            hit = mount.blocking(eye, ax.norm(ax.sub(target, eye)), parts)
            if hit:
                first.setdefault(("H2", hit[1]), (barrel, look_pitch, 0, 0, hit[0]))
        for side, grip in ((1, "GripR"), (-1, "GripL")):
            s = shoulder[side]
            at = ax.add(eye, ax.add(ax.add(ax.mul(right, s[0]), ax.mul(vup, s[1])), ax.mul(look, -s[2])))
            dist = ax.length(ax.sub(points[grip], at))
            worst_arm = max(worst_arm, dist)
            if dist > most:
                first.setdefault(("H3", grip), (barrel, look_pitch, 0, 0, dist))
        if lower is None and barrel >= (mount.arc[1] if mount.lobs else 0):
            seen = sum(1 for dx in range(-20, 21, 4) for dy in range(-30, -4, 3)
                       if mount.blocking(eye, ax.rotate(ax.rotate(look, right, math.radians(dy)), up, math.radians(dx)), parts))
            lower = (seen, 11 * 9)
    for (inv, name), (barrel, look_pitch, dx, dy, d) in sorted(first.items()):
        if inv == "H1":
            faults.append(f"H1 {label}: {name} is in the hip view {d:.2f} out (barrel pitch {barrel:g}, view pitch {look_pitch:g}, "
                          f"{dx:+d}/{dy:+d} degrees off the middle)")
        elif inv == "H2":
            faults.append(f"H2 {label}: {name} is across the aim line {d:.2f} out (barrel pitch {barrel:g})")
        else:
            faults.append(f"H3 {label}: {name} is {d:.2f} from its shoulder at barrel pitch {barrel:g} (reach {most:.2f})")
    if verbose:
        print(f"  {label:16} {len(mount.own)} own parts ({len(mount.solid)} solid), pitch {mount.arc[1]:g}..{mount.arc[2]:g}"
              f"{' (lobbing view)' if mount.lobs else ''}: {blocked_cells}/{cells} crosshair rays blocked; "
              f"gun in the lower view {lower[0]}/{lower[1]} rays; hands at most {worst_arm:.2f} from the shoulder (reach {most:.2f})")
        if mount.lobs:
            print(f"  {'':16} steeper lobbing views, not held (view pitch: worst rays of {len(DXS) * len(DYS)}): {lob_steep(mount)}")
    return faults


def run(sources, reach, only=None, verbose=True):
    rt = ax.Runtime(sources)
    dump = rt.lua.eval(MARKERS)
    arcs = ax.weapon_arcs(sources["VehicleWeaponData"])
    faults, examined = [], 0
    for model_id in sorted(rt.mounts):
        if only and model_id != only:
            continue
        rows = dump(rt.vm, model_id)
        markers = {rows[i][2]: (rows[i][1], [rows[i][3], rows[i][4], rows[i][5]]) for i in range(1, len(rows) + 1)}
        if model_id not in arcs or "GunnerEye" not in markers:
            faults.append(f"{model_id}: armed but no turret arc or no GunnerEye")
            continue
        examined += 1
        faults += audit(Mount(rt.build(model_id, "drive"), markers, arcs[model_id]), model_id, reach, verbose)
    if verbose:
        print(f"{examined} armed vehicles examined")
    return faults


def main(repo="."):
    sources = ax.load_sources(repo)
    reach = viewmodel_reach(repo)
    faults = run(sources, reach)
    for f in faults:
        print("  FAULT " + f)
    failed = bool(faults)

    VM = "VehicleModels"
    plants = [
        ("the Rotster's eye back down in its receiver", "Rotster",
         "GunnerEye = { yaw, CF(yawAt + V(0, 2.33, 0.25)) },", "GunnerEye = { yaw, CF(yawAt + V(0, 1.13, 0.25)) },", ("H1", "H2")),
        ("a plate across the Ranger's launcher in front of the eye", "CrocodiloRanger",
         '\t\ttrunnion(b, "TurretTrunnion", pitchAt, 2.28, 0.2)',
         '\t\ttrunnion(b, "TurretTrunnion", pitchAt, 2.28, 0.2)\n\t\tb:box("PodPlantPlate", V(2, 1, 0.1), pitchAt + V(0, 1.05, -0.8), "trim")', ("H1",)),
        ("the scout car's eye lifted far over its gun", "TartarugaScout",
         "GunnerEye = { yaw, CF(yawAt + V(0, 2.52, 0.45)) },", "GunnerEye = { yaw, CF(yawAt + V(0, 5.0, 0.45)) },", ("H3",)),
    ]
    for label, model_id, old, new, tags in plants:
        src = sources[VM]
        assert src.count(old) == 1, f"plant anchor missing or ambiguous: {old!r}"
        found = run(dict(sources, **{VM: src.replace(old, new)}), reach, only=model_id, verbose=False)
        missed = [t for t in tags if not any(f.startswith(t) for f in found)]
        caught = [f for f in found if f.startswith(tags[0])]
        print(f"plant [{label}] on {model_id}: " + ("MISSED " + ", ".join(missed) if missed else "CAUGHT -- " + caught[0]))
        failed |= bool(missed)
    print("gunner_hip_view_check: " + ("FAIL" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
