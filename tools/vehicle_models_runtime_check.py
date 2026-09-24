"""Runtime attachment audit for VehicleModels: does anything float once the vehicle MOVES?

tools/vehicle_models_axis_check.py looks at a vehicle as built, standing still. In the game it does
not stand still: the chassis drives off, VehicleDynamics.AnimateWheels spins, steers and bobs the
wheels through their hubs' Motor6D.Transform (and a bike's fork, slider and swingarm pivots), the
steering wheel turns with the front wheels, and VehicleWeaponClient swings the turret on its yaw and
pitch joints. A part welded to the wrong assembly, or not welded at all, looks fine at rest and
comes away the moment any of that happens -- which is what "floating parts" looks like.

So this builds the REAL module (lupa, the same mock as the axis check, real ZFight pass), reads the
joint graph Build made -- every WeldConstraint's Part0 and every Motor6D's Part0 and C0 -- and then
poses the model the way Roblox would, joint by joint:
    Motor6D:        Part1 = Part0 * C0 * Transform          (C1 is identity in Build)
    WeldConstraint: Part1 = Part0 * (Part0 at build)^-1 * (Part1 at build)
with the Transforms VehicleDynamics.AnimateWheels / VehicleWeaponClient set (the formulas are copied
here from those files, with their line numbers; handling limits are read from VehicleDynamics).

Poses: the chassis moved and turned; full lock both ways with the suspension fully compressed and
fully extended; wheels spun a quarter turn; the turret over its whole arc (VehicleWeaponData).

Invariants:
  1. Every part is joined, through welds and motors, to the Chassis (else it falls off / stays put).
  2. In every pose, every visible part is in a touching group (within 0.06) that is either the body
     (the group holding the Chassis-welded parts) or a car wheel (a group with a Tyre in it: a car
     wheel turns free in its arch). A bike wheel must touch its fork or swingarm. Anything else is
     a floating part, reported with the pose it first floats in.
  3. BuildStatic (parked cars): the same, with every part anchored where it was built.

Planted faults travel the real pipeline (edited source, rebuilt):
    python3 tools/vehicle_models_runtime_check.py [repo]    -> exit 0 when clean
"""

import math
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import vehicle_models_axis_check as ax  # noqa: E402

TOUCH = 0.06

DUMP = r"""
function(vm, id, how)
	local m
	if how == "static" then m = vm.BuildStatic(id, nil, CFrame.identity, { scheme = 1 })
	else m = vm.Build(id, nil, { scheme = 1 }) end
	local out = {}
	for _, p in ipairs(m:GetChildren()) do
		if p.ClassName == "Part" or p.ClassName == "WedgePart" then
			local c, s = p.CFrame, p.Size
			local joint, kind, c0 = "", "", nil
			for _, k in ipairs(p:GetChildren()) do
				if k.ClassName == "WeldConstraint" then joint, kind = k.Part0.Name, "weld" end
				if k.ClassName == "Motor6D" then joint, kind, c0 = k.Part0.Name, "motor", k.C0 end
			end
			local row = { p.Name, p.ClassName, tostring(p.Shape), s.X, s.Y, s.Z,
				c.p.X, c.p.Y, c.p.Z, c.r.X, c.r.Y, c.r.Z, c.u.X, c.u.Y, c.u.Z, c.b.X, c.b.Y, c.b.Z,
				p.Transparency or 0, joint, kind,
				tostring(p:GetAttribute("Pivot") or ""), p:GetAttribute("Radius") or 0,
				p:GetAttribute("Steer") == true, p:GetAttribute("Ratio") or 7, p.Anchored == true,
				p:GetAttribute("RingRadius") or 0 }
			table.insert(out, row)
		end
	end
	return out
end
"""


# -- frames: (R, p) with R's columns the part's X, Y, Z ------------------------------------------
def frame(p):
    # Roblox keeps a CFrame orthonormal; the mock's fromMatrix takes a 4-figure "down" as given.
    u, _, vt = np.linalg.svd(np.array(p["cols"]).T)
    return u @ vt, np.array(p["pos"])


def mul(a, b):
    return a[0] @ b[0], a[0] @ b[1] + a[1]


def inv(a):
    return a[0].T, -a[0].T @ a[1]


def angles(x, y, z):
    """CFrame.Angles(x, y, z) = Rx * Ry * Rz."""
    cx, sx, cy, sy, cz, sz = math.cos(x), math.sin(x), math.cos(y), math.sin(y), math.cos(z), math.sin(z)
    rx = np.array([[1, 0, 0], [0, cx, -sx], [0, sx, cx]])
    ry = np.array([[cy, 0, sy], [0, 1, 0], [-sy, 0, cy]])
    rz = np.array([[cz, -sz, 0], [sz, cz, 0], [0, 0, 1]])
    return rx @ ry @ rz, np.zeros(3)


def translate(x, y, z):
    return np.eye(3), np.array([x, y, z], dtype=float)


IDENT = (np.eye(3), np.zeros(3))


def handling_of(source):
    """{modelId: {travelUp, travelDown, steerLow}} from VehicleDynamics' source."""
    out = {}
    for m in re.finditer(r"\n\t(\w+) = \{(.*?)\n\t\}", source, re.S):
        body = m.group(2)
        vals = {k: re.search(rf"\b{k} = ([\d.]+)", body) for k in ("travelUp", "travelDown", "steerLow")}
        if all(vals.values()):
            out[m.group(1)] = {k: float(v.group(1)) for k, v in vals.items()}
    return out


class Model:
    def __init__(self, rt, lua_dump, model_id, how):
        rows = lua_dump(rt.vm, model_id, how)
        self.parts = []
        for i in range(1, len(rows) + 1):
            r = rows[i]
            v = [r[j] for j in range(1, 28)]
            p = {"name": v[0], "cls": v[1], "shape": v[2].split(".")[-1], "size": list(v[3:6]), "pos": list(v[6:9]),
                 "cols": (list(v[9:12]), list(v[12:15]), list(v[15:18])), "transparency": v[18],
                 "joint": v[19], "kind": v[20], "pivot": v[21], "radius": v[22], "steer": v[23], "ratio": v[24],
                 "anchored": v[25], "ring": v[26]}
            p["rest"] = frame(p)
            self.parts.append(p)
        self.by = {p["name"]: p for p in self.parts}
        self.chassis = self.by.get("Chassis")

    def pose(self, chassis_frame, transforms):
        """World frame of every part: chassis placed at chassis_frame, joint Transforms by part name."""
        out = {}

        def solve(p, depth=0):
            name = p["name"]
            if name in out:
                return out[name]
            if p is self.chassis:
                out[name] = chassis_frame
            elif p["anchored"] or not p["joint"] or p["joint"] not in self.by or depth > 50:
                out[name] = p["rest"]  # not joined to anything: it stays where it was put
            else:
                parent = self.by[p["joint"]]
                pf = solve(parent, depth + 1)
                rel = mul(inv(parent["rest"]), p["rest"])  # C0 for a motor, the weld offset for a weld
                if p["kind"] == "motor":
                    rel = mul(rel, transforms.get(name, IDENT))
                out[name] = mul(pf, rel)
            return out[name]

        for p in self.parts:
            solve(p)
        return out


def posed_part(p, f):
    R, t = f
    return dict(p, pos=list(t), cols=(list(R[:, 0]), list(R[:, 1]), list(R[:, 2])))


def wheel_transforms(model, handling, steer_deg, offset, spin):
    """VehicleDynamics.AnimateWheels (VehicleDynamics.lua:955-1007), for one steer angle / bob / spin."""
    T = {}
    chassis_rest = model.chassis["rest"]
    for hub in model.parts:
        if not hub["radius"]:
            continue
        steer = -math.radians(steer_deg) if hub["steer"] else 0.0
        mount = mul(inv(chassis_rest), hub["rest"])[1]
        steer_j = slider_j = swing_j = None
        slider_up, swing_arm = 1.0, 1.0
        above = model.by.get(hub["joint"])
        while above is not None and above is not model.chassis:
            rest = mul(inv(chassis_rest), above["rest"])
            if above["pivot"] == "Steer":
                steer_j = above["name"]
            elif above["pivot"] == "Slider":
                slider_j = above["name"]
                slider_up = max(0.3, rest[0][1, 1])
            elif above["pivot"] == "Swing":
                swing_j = above["name"]
                arm = mul(inv(rest), (np.eye(3), mount))[1][2]
                swing_arm = arm if abs(arm) > 0.2 else 1.0
            above = model.by.get(above["joint"])
        hub_t = angles(spin, 0, 0)
        if steer_j:
            T[steer_j] = angles(0, steer, 0)
        else:
            hub_t = mul(angles(0, steer, 0), hub_t)
        if slider_j:
            T[slider_j] = translate(0, offset / slider_up, 0)
        elif swing_j:
            T[swing_j] = angles(-math.asin(max(-0.9, min(0.9, offset / swing_arm))), 0, 0)
        else:
            hub_t = mul(translate(0, offset, 0), hub_t)
        T[hub["name"]] = hub_t
    for p in model.parts:
        if p["pivot"] == "SteerWheel":
            T[p["name"]] = angles(0, 0, -math.radians(steer_deg) * p["ratio"])
    return T


def contacts(parts):
    """Every touching pair (i, j), i < j, among `parts` (within TOUCH)."""
    n = len(parts)
    ext = [ax.world_extent(p) for p in parts]
    order = sorted(range(n), key=lambda i: ext[i][0][0])
    found = set()
    for a_i, i in enumerate(order):
        lo_i, hi_i = ext[i]
        for j in order[a_i + 1:]:
            lo_j, hi_j = ext[j]
            if lo_j[0] > hi_i[0] + TOUCH:
                break
            if all(lo_j[k] <= hi_i[k] + TOUCH and lo_i[k] <= hi_j[k] + TOUCH for k in (1, 2)):
                if ax.overlaps(parts[i], parts[j], TOUCH):
                    found.add((min(i, j), max(i, j)))
    return found


def groups(n, pairs):
    """Touching groups (lists of indices) from contact pairs."""
    parent = list(range(n))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    for i, j in pairs:
        parent[find(i)] = find(j)
    out = {}
    for i in range(n):
        out.setdefault(find(i), []).append(i)
    return list(out.values())


def assembly_root(model, p):
    """The pivot a part moves with: its first ancestor with a Motor6D (or Chassis)."""
    seen = 0
    while p is not None and p is not model.chassis and seen < 50:
        if p["kind"] == "motor":
            return p["name"]
        p = model.by.get(p["joint"])
        seen += 1
    return "Chassis"


def ancestors(model, root):
    """The pivots `root` hangs from, itself included, down to Chassis."""
    chain = [root]
    while root != "Chassis":
        pivot = model.by.get(root)
        root = assembly_root(model, model.by.get(pivot["joint"])) if pivot and pivot["joint"] else "Chassis"
        chain.append(root)
    return chain


def floating(model, shown, pairs, bike):
    """Touching groups not in the body's group or (on a car) a wheel's, as sorted name lists."""
    bad = []
    for g in groups(len(shown), pairs):
        names = [shown[i]["name"] for i in g]
        roots = {assembly_root(model, shown[i]) for i in g}
        if "Chassis" in roots:
            continue
        if not bike and any("_Tyre" in n for n in names):
            continue
        bad.append(sorted(names))
    return bad


def audit(rt, dump, handling, arcs, model_id, verbose=True, driver_arcs=None):
    faults = []
    bike = rt.vm.Models[model_id].kind == "bike"
    for how in ("drive", "static"):
        model = Model(rt, dump, model_id, how)
        label = f"{model_id}[{how}]"
        # 1. Joined to the chassis.
        for p in model.parts:
            if p is model.chassis:
                continue
            q, hops = p, 0
            while q is not None and q is not model.chassis and hops < 50:
                q = None if (q["anchored"] or not q["joint"]) else model.by.get(q["joint"])
                hops += 1
            if q is not model.chassis and not (how == "static" and p["anchored"]):
                faults.append(f"{label}/{p['name']}: not joined to the Chassis (it would fall off / stay behind)")
            if how == "static" and not p["anchored"]:
                faults.append(f"{label}/{p['name']}: parked car part not anchored")
        # 2. Poses.
        poses = [("rest", model.chassis["rest"], {})]
        if how == "drive":
            h = handling[model_id]
            moved = mul(translate(40, 3, -25), mul(angles(0.1, 0.8, -0.05), model.chassis["rest"]))
            poses.append(("driven off, turned and tilted", moved, {}))
            for steer in (h["steerLow"], -h["steerLow"]):
                for offset, what in ((h["travelUp"], "compressed"), (-h["travelDown"], "extended")):
                    poses.append((f"steer {steer:+.0f} deg, suspension {what}", model.chassis["rest"],
                                  wheel_transforms(model, h, steer, offset, math.pi / 2)))
            # Both weapons through their arcs: the turret (30-degree steps) and the driver's gun (10).
            for names, table, step, what in ((("TurretYaw", "TurretPitch"), arcs, 30, "turret"),
                                             (("DriverGunYaw", "DriverGunPitch"), driver_arcs or {}, 10, "driver gun")):
                if names[0] in model.by and model_id in table:
                    yaw_limit, pmin, pmax, guard = table[model_id]
                    for yaw in range(-int(yaw_limit), int(yaw_limit) + 1, step):
                        low = max(pmin, guard[1]) if guard and abs(yaw) < guard[0] else pmin
                        for pitch in (low, (low + pmax) / 2, pmax):
                            poses.append((f"{what} yaw {yaw}, pitch {pitch:g}", model.chassis["rest"],
                                          {names[0]: angles(0, math.radians(yaw), 0), names[1]: angles(math.radians(pitch), 0, 0)}))
        shown = [p for p in model.parts if p["transparency"] < 1]
        roots = [assembly_root(model, p) for p in shown]
        chains = {r: ancestors(model, r) for r in set(roots)}
        rest_pairs = contacts(shown)
        # (b) Each part rests on something that moves with it: a part of its own assembly or of one it
        # hangs from. One held up only by an assembly that moves on its own (a caliper on the body
        # touching nothing but the fork leg and the disc) is left behind when that one moves.
        held = {}
        for i, j in rest_pairs:
            for x, y in ((i, j), (j, i)):
                held.setdefault(x, set()).add(roots[y])
        # (A wheel it carries counts: a caliper on a swingarm resting on the disc keeps resting on it
        # however the wheel spins, since the disc is round about the axle.)
        carried = {r: {h for h, c in chains.items() if model.by[h]["radius"] and len(c) > 1 and c[1] == r} for r in chains}
        for i, p in enumerate(shown):
            if i in held and not (held[i] & (set(chains[roots[i]]) | carried[roots[i]])):
                faults.append(f"{label}/{p['name']}: rests only on parts that move independently of it ({', '.join(sorted(held[i]))})")
        # (d) Each turning joint turns about an axle that is really there: its axis line (1.5 studs
        # either way of the pivot) runs through a part of its own assembly and a part of the one it
        # hangs from. A pivot built off to one side swings its assembly round thin air -- a steering
        # wheel orbiting its column -- which no contact at rest shows. Sliders only translate, and a
        # car's wheel hub has nothing of the body on its axle (the wheel turns free in its arch).
        # A ring bearing (a pivot with RingRadius: the Rotster's hatch ring, the armoured cars' gun rings)
        # has nothing on its axis -- a gunner stands there -- so it is its ring that must be really there:
        # the circle of that radius round the axis, in the pivot's own XZ plane, is tested instead.
        if how == "drive":
            for pivot in model.parts:
                if pivot["kind"] != "motor":
                    continue
                axis = 0 if pivot["radius"] else {"Steer": 1, "Swing": 0, "SteerWheel": 2, "TurretYaw": 1, "TurretPitch": 0}.get(pivot["pivot"])
                if axis is None:
                    continue
                R, origin = pivot["rest"]
                if pivot["ring"]:
                    ring = pivot["ring"]
                    line = [list(origin + (R[:, 0] * math.cos(a) + R[:, 2] * math.sin(a)) * ring)
                            for a in (k * math.pi / 24 for k in range(48))]
                else:
                    line = [list(origin + R[:, axis] * (t / 20)) for t in range(-30, 31)]
                own = [q for q in shown if assembly_root(model, q) == pivot["name"]]
                parent_root = assembly_root(model, model.by[pivot["joint"]])
                up = [q for q in shown if assembly_root(model, q) == parent_root]
                if own and not any(ax.point_distance(q, x) <= TOUCH for q in own for x in line):
                    faults.append(f"{label}/{pivot['name']}: turns about an axis clear of its own parts (they swing round thin air)")
                if not (pivot["radius"] and not bike) and not any(ax.point_distance(q, x) <= TOUCH for q in up for x in line):
                    faults.append(f"{label}/{pivot['name']}: turns about an axis clear of {parent_root}'s parts (nothing there to turn on)")
        # (c) Each moving assembly that touches what carries it at rest still touches it in every pose.
        joins = {}
        for i, j in rest_pairs:
            for x, y in ((i, j), (j, i)):
                if roots[x] != "Chassis" and roots[y] != roots[x] and roots[y] in chains[roots[x]]:
                    joins.setdefault(roots[x], set()).add((min(i, j), max(i, j)))
        seen = set()
        for what, chassis_frame, T in poses:
            frames = model.pose(chassis_frame, T)
            if what.startswith("driven off"):
                # Rigid: every joined part keeps its place relative to the chassis.
                back = mul(model.chassis["rest"], inv(chassis_frame))
                for p in model.parts:
                    f = mul(back, frames[p["name"]])
                    if np.abs(f[1] - p["rest"][1]).max() > 1e-4:
                        faults.append(f"{label}/{p['name']}: left behind when the chassis moves")
                continue
            posed = [posed_part(p, frames[p["name"]]) for p in shown]
            pairs = rest_pairs if not T else contacts(posed)
            for assembly, needed in joins.items():
                # A ring bearing is carried all round: any of its segments on what carries it will do,
                # not the very pairs that touched at rest (turned 180 degrees, every one has moved on).
                if model.by[assembly]["ring"] and any(
                        (roots[i] == assembly and roots[j] in chains[assembly]) or (roots[j] == assembly and roots[i] in chains[assembly])
                        for i, j in pairs):
                    continue
                if not (needed & pairs) and ("join", assembly) not in seen:
                    seen.add(("join", assembly))
                    faults.append(f"{label}/{assembly}: comes away from what carries it at {what} "
                                  f"(rest contacts {', '.join(sorted({shown[i]['name'] + '/' + shown[j]['name'] for i, j in needed})[:3])} all lost)")
            for names in floating(model, shown, pairs, bike):
                key = tuple(names)
                if key in seen:
                    continue
                seen.add(key)
                faults.append(f"{label}/{', '.join(names[:6])}{' ...' if len(names) > 6 else ''}: floating ({len(names)} parts) at {what}")
        if verbose:
            print(f"{label}: {len(model.parts)} parts, {len(poses)} poses")
    return faults


def run(sources, only=None, verbose=True):
    rt = ax.Runtime(sources)
    dump = rt.lua.eval(DUMP)
    handling = handling_of(sources["VehicleDynamics"])
    arcs = ax.weapon_arcs(sources["VehicleWeaponData"])
    driver_arcs = ax.weapon_arcs(sources["VehicleWeaponData"], "DriverByModel")
    assert arcs and driver_arcs, "no weapon arcs read from VehicleWeaponData"
    faults = []
    for model_id in rt.ids:
        if only and model_id != only:
            continue
        found = audit(rt, dump, handling, arcs, model_id, verbose, driver_arcs)
        if verbose:
            for f in found:
                print("  FAULT " + f)
            print(f"{model_id}: {len(found)} faults")
        faults += found
    return faults


def load(repo):
    sources = ax.load_sources(repo)
    sources["VehicleDynamics"] = (Path(repo) / "ReplicatedStorage/Shared/VehicleDynamics.lua").read_text()
    return sources


def main(repo="."):
    sources = load(repo)
    failed = bool(run(sources))
    VM = "VehicleModels"
    plants = [
        ("a part left without a weld", "Rotster",
         "\t\tif part ~= b.chassis and not b.jointed[part] then",
         "\t\tif part ~= b.chassis and not b.jointed[part] and part.Name ~= \"Spoiler\" then", "Spoiler: not joined"),
        ("a fork caliper welded to the body, not the slider", "BrrStreetfighter",
         'b:box("Caliper" .. n', 'b:box("Caliper" .. n', "Caliper"),
        ("mortar lip on the yaw joint, not the pitch", "SahurVan",
         'b:tube("MortarLip", at + V(0, 0, -1.8), at + V(0, 0, -2.1), 0.84, "stripe")',
         'b:tube("MortarLip", at + V(0, 0, -1.8), at + V(0, 0, -2.1), 0.84, "stripe", yaw)', "MortarLip"),
        ("fork uppers back to 1.45 (the legs part with the wheel hanging)", "PatapimScrambler",
         'b:tube("ForkUpper" .. n, P(-0.42, s * 0.36), P(2.0, s * 0.36), 0.3, "gold")',
         'b:tube("ForkUpper" .. n, P(-0.42, s * 0.36), P(1.45, s * 0.36), 0.3, "gold")', "suspension extended"),
        ("the roof gun lifted off its pintle (floating over the ring)", "Rotster",
         'muzzleZ, frames = machineGun(b, "Gun", pitchAt, 1, {})', 'muzzleZ, frames = machineGun(b, "Gun", pitchAt + V(0, 0.6, 0), 1, {})', "Gun"),
        ("the Ranger's launcher lifted off its pins (floating over the yoke)", "CrocodiloRanger",
         '\t\tlocal function P(x, y, z)\n\t\t\treturn pitchAt + V(x, y, z)\n\t\tend\n\t\ttrunnion(b, "TurretTrunnion", pitchAt, 2.28, 0.2)',
         '\t\tlocal function P(x, y, z)\n\t\t\treturn pitchAt + V(x, y + 0.9, z)\n\t\tend\n\t\ttrunnion(b, "TurretTrunnion", pitchAt, 2.28, 0.2)', "Pod"),
        ("the Ranger's bonnet gun lifted out of its cowl (the ball in the air over it)", "CrocodiloRanger",
         'local at = V(base.X, base.Y + 0.36, frontZ + 0.08)', 'local at = V(base.X, base.Y + 1.0, frontZ + 0.08)',
         "DriverGun"),
        ("steering wheel pivot off the column", "TralalaGT",
         'local frame = CFrame.lookAt(center, center - column)\n\tlocal pivot = self:pivot(name, frame,',
         'local frame = CFrame.lookAt(center, center - column)\n\tlocal pivot = self:pivot(name, frame * CF(0, 0.6, 0),', "SteeringWheel"),
    ]
    for label, model_id, old, new, tag in plants:
        src = sources[VM]
        assert src.count(old) >= 1, f"plant anchor missing: {old!r}"
        if label.startswith("a fork caliper"):
            # Built outside the slider's with(): re-anchor it to the chassis after the fact.
            new_src = src.replace("\tlocal zfight = ZFight.Fix({ model }, { all = true })",
                "\tfor part in pairs(b.anchors) do if string.find(part.Name, \"^Caliper[LR]$\") then b.anchors[part] = false end end\n\tlocal zfight = ZFight.Fix({ model }, { all = true })", 1)
        else:
            new_src = src.replace(old, new, 1)
        assert new_src != src
        faults = run(dict(sources, **{VM: new_src}), only=model_id, verbose=False)
        caught = [f for f in faults if tag in f]
        print(f"plant [{label}] on {model_id}: {'CAUGHT -- ' + caught[0] if caught else 'MISSED'}")
        failed |= not caught
    print("vehicle_models_runtime_check: " + ("FAIL" if failed else "OK"))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
