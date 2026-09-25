#!/usr/bin/env python3
"""#84 / #109 audit: re-runs tools/vehicle_stability_sim.py with the game's own numbers.

vehicle_stability_sim.py is left untouched; this imports it and changes only its inputs:

  models   every car in VehicleModels.lua (kind = "car"), read from the source: wheel radius, half
           track, axle Z, the Chassis hull's size, centre and density. The stock sim hard-codes four
           cars, all at density 1.3, and puts the chassis centre at Z = 0 (the SahurVan's is at 0.4).
  modes    the stock four, plus 144/240 and 240/240: a fast screen whose every frame gets a physics
           step, which is what a Roblox staff post says the engine does (DevForum "Introducing the
           Maximum Framerate Setting", 2024-05-30). The stock 144/60 mode is kept: it stands for an
           assembly that adaptive timestepping has dropped to 60 Hz.
  ground   "--ground built" swaps the stock road for one laid the way RoadNetwork lays it: slab tops
           meeting exactly (no 0.01 step, no 0.05 gap), stop lines 1.2 long, and the bridge deck under
           the asphalt (MapDecor.Bridge), so the asphalt runs across it without a step.

Two planted faults run every time, each on every model:
  damper-sign   the stock sim's own plant (the damper pushes the wrong way). Aimed at an invariant.
  damper-diff   the damper reverted to frame-to-frame ray length, the pre-3f1d7b6 code, with the
                rest of the fix left in. Aimed at the OLD BUG: it shows whether the sim can tell
                the fix from its absence, and it expires if the damper is ever rewritten again.

  gravity  "--gravity 0.5" runs under MatchEvents' low-gravity event (workspace.Gravity x 0.5).

Usage:  python3 tools/car_bounce_audit_sim.py [--source PATH] [--ground stock|built] [--gravity X] [--verbose]
Needs lupa (pip install lupa). Exit 0 when the source passes and the sign plant is caught on every car.
"""
import argparse
import importlib.util
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODELS_SRC = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleModels.lua")

spec = importlib.util.spec_from_file_location("vss", os.path.join(ROOT, "tools", "vehicle_stability_sim.py"))
vss = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vss)

NUM = r"(-?[\d.]+)"


def read_cars(path):
    """Every Models entry, and the geometry of each kind = "car" one. Returns (entries, cars, skipped)."""
    text = open(path, encoding="utf-8").read()
    starts = [(m.start(), m.group(1)) for m in re.finditer(r"^VehicleModels\.Models\.(\w+) = \{", text, re.M)]
    cars, skipped = {}, []
    for index, (at, name) in enumerate(starts):
        end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
        block = text[at:end]
        if not re.search(r'kind = "car"', block):
            skipped.append(name)
            continue
        r = re.search(rf"local r, tw, track = {NUM}, {NUM}, {NUM}", block)
        z = re.search(rf"local fz, rz = {NUM}, {NUM}", block)
        hull = re.search(rf'b:hull\("Chassis", V\({NUM}, {NUM}, {NUM}\), V\({NUM}, {NUM}, {NUM}\), {NUM}\)', block)
        if not (r and z and hull):
            skipped.append(name + " (unparsed)")
            continue
        sx, sy, sz, cx, cy, cz, density = map(float, hull.groups())
        cars[name] = dict(r=float(r.group(1)), track=float(r.group(3)), fz=float(z.group(1)), rz=float(z.group(2)),
                          size=(sx, sy, sz), cy=cy, cz=cz, cx=cx, density=density)
    return len(starts), cars, skipped


def to_sim(car):
    # The sim puts the chassis at Z = 0; a hub's mount is its offset from the chassis centre.
    return dict(r=car["r"], track=car["track"], fz=car["fz"] - car["cz"], rz=car["rz"] - car["cz"],
                size=car["size"], cy=car["cy"])


def use_densities(cars):
    """Make the sim's chassis mass volume * the model's own density instead of * 1.3."""
    old = "chassis.AssemblyMass = g.sx * g.sy * g.sz * 1.3"
    assert old in vss.SIM, "vehicle_stability_sim.py's mass line changed: update this audit"
    vss.SIM = vss.SIM.replace(old, "chassis.AssemblyMass = g.sx * g.sy * g.sz * (DENSITY[modelId] or 1.3)")
    table = ", ".join(f"{name} = {car['density']}" for name, car in cars.items())
    vss.PRELUDE += f"\nDENSITY = {{ {table} }}\n"


def use_built_road():
    """Swap the stock road course for one laid the way RoadNetwork.buildSurface and MapDecor lay it."""
    stock = vss.courses

    def courses(lua):
        set_ground, T, grounds = stock(lua)
        P = lua.globals().PARTS
        road = [T(-200, -40, 0, 0, P.grass)]
        s = -40.0
        # Slab tops meet exactly (RoadNetwork:22, :1785-1790: the stagger is in width and depth only).
        # Stop lines: s0 + 1 .. s0 + 2.2, MarkRaise 0.07 proud (RoadNetwork:1859).
        for a, b in ((s, 40), (40, 41.2), (41.2, 88), (88, 89.2), (89.2, 120)):
            top = 0.47 if b - a < 2 else 0.4
            road.append(T(a, b, top, top, P.line if top > 0.4 else P.road))
        s = 120
        # Bridge: the asphalt runs straight across; the collidable deck's top is the road ground
        # (MapDecor.Bridge: deck centre at -lift - 0.6, 1.2 thick), so a wheel sees asphalt at 0.4.
        road.append(T(s, s + 100, 0.4, 0.4, P.road))
        s += 100
        road.append(T(s, s + 80, 0, 0, P.grass))
        s += 80
        road.append(T(s, s + 400, 0.4, 0.4, P.road))
        grounds = dict(grounds)
        grounds["road"] = road
        return set_ground, T, grounds

    vss.courses = courses


PLANT_DIFF = [
    ("		local extension, hit = contact(rig, wheel, frame, castUp, bodyForward, travel)\n		if hit then",
     "		local extension, hit = contact(rig, wheel, frame, castUp, bodyForward, travel)\n"
     "		local previous = wheel.compression\n		if hit then"),
    ("local compressionSpeed = clamp(-closing:Dot(normal) / math.max(normal:Dot(castUp), WALL_DOT), -16, 16)",
     "local compressionSpeed = clamp((wheel.compression - previous) / dt, -16, 16)"),
]


def plant(text, pairs, label):
    for before, after in pairs:
        if before not in text:
            print(f"PLANT {label} could not be applied ({before[:60]!r}... not in source)")
            return None
        text = text.replace(before, after, 1)
    return text


def caught_on(problems):
    return sorted({p.split()[0] for p in problems if " road " in p or " edge" in p})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=vss.SOURCE)
    parser.add_argument("--ground", choices=("stock", "built"), default="stock")
    parser.add_argument("--gravity", type=float, default=1.0, help="share of the normal 196.2")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    if args.gravity != 1.0:
        old = "workspace = { Gravity = 196.2 }"
        assert old in vss.PRELUDE, "vehicle_stability_sim.py's gravity line changed: update this audit"
        vss.PRELUDE = vss.PRELUDE.replace(old, f"workspace = {{ Gravity = {196.2 * args.gravity} }}")

    entries, cars, skipped = read_cars(MODELS_SRC)
    print(f"VehicleModels.lua: {entries} model entries examined, {len(cars)} cars read, not cars or unread: {', '.join(skipped)}")
    for name, car in cars.items():
        stock = vss.MODELS.get(name)
        mine = to_sim(car)
        if stock is None:
            print(f"  {name}: NOT IN the stock sim (density {car['density']})")
            continue
        diffs = [f"{k} {stock[k]} -> {mine[k]}" for k in mine if stock[k] != mine[k]]
        if car["density"] != 1.3:
            diffs.append(f"density 1.3 -> {car['density']}")
        print(f"  {name}: {'matches the stock sim' if not diffs else '; '.join(diffs)}")

    text = open(args.source, encoding="utf-8").read()
    # An older VehicleDynamics has no Handling for cars added since; those are left out and named.
    missing = [name for name in cars if not re.search(rf"^\s*{name} = \{{", text, re.M)]
    for name in missing:
        print(f"  {name}: no Handling entry in this source, left out")
        del cars[name]
    vss.MODELS = {name: to_sim(car) for name, car in cars.items()}
    use_densities(cars)
    vss.MODES = vss.MODES + [(144, 0, 240), (240, 0, 240)]
    if args.ground == "built":
        use_built_road()

    print(f"source: {args.source}   ground: {args.ground}   gravity x{args.gravity}   modes: {vss.MODES}")
    results = vss.measure(text, args.verbose)
    print(vss.table(results))
    problems, examined = vss.judge(results)
    for p in problems:
        print("PROBLEM", p)
    print(f"{examined} runs examined ({len(cars)} cars), {len(problems)} problems")

    ok = not problems
    sign = plant(text, vss.PLANT, "damper-sign")
    if sign is None:
        ok = False
    else:
        hit = caught_on(vss.judge(vss.measure(sign, modes=[vss.MODES[0]]))[0])
        print(f"planted fault damper-sign (invariant): caught on {len(hit)}/{len(cars)} cars at 60/240")
        ok = ok and len(hit) == len(cars)
    diff = plant(text, PLANT_DIFF, "damper-diff")
    if diff is not None:
        diff_problems = vss.judge(vss.measure(diff))[0]
        hit = caught_on(diff_problems)
        modes = sorted({p.split()[2].rstrip(":") for p in diff_problems if " road " in p or " edge" in p})
        print(f"planted fault damper-diff (old bug): caught on {len(hit)}/{len(cars)} cars "
              f"({', '.join(hit) or 'none'}), in modes {', '.join(modes) or 'none'}, {len(diff_problems)} problems")
        if args.verbose:
            for p in diff_problems:
                print("  diff:", p)
    print("OK" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
