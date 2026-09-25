"""Vehicle time-to-kill bands (Oliver, 2026-09-24: "make the cars have a balanced health pool that
doesn't make them glass cannons but doesn't make them juggernauts either").

Runs the REAL ReplicatedStorage/Shared/VehicleArmor.lua and VehicleWeaponData.lua under lupa, reads
every gun in WeaponData and its add-on packs with weapon_stats.py's brace-matched parser, the round
specs out of Ballistics.lua (lupa again, with a Vector3 stub), and MatchConfig.CombatDamageScale, then
works out what each vehicle faces and holds the bands VehicleArmor's header sets:

  EVERY TIME-TO-KILL BAND BELOW IS x1.25 of the 09-24 one (Oliver, 2026-09-25: "increase ttk of players and
  vehicles 25%", done as MatchConfig.CombatDamageScale 0.92 -> 0.736; hit counts rounded outward)
  CAR     one Rare rifle (Bananini Burst) at mid range, every shot landing, reloads counted, kills
          it in 10-15 s; a rocket (the Cappuccina's, a direct hit) kills it in 3-4
  BIKE    dies quicker than any car to the same rifle (under 7.5 s), and to 1-3 rockets
  ARMOUR  2-2.5x the average car's health; 40-50% off bullets; nothing off explosives; 6-8 rockets;
          its cabin protects the driver and passengers, never the gunner
  GUNS    very powerful (Oliver, 2026-09-25: "make sure the mounted guns on the ground and the cars are
          very powerful"): every turret kills a car inside 10 s of its own fire, a driver's gun inside 15 s
  CRASH   a crash takes the same share of health it always did (armour takes less)

Planted faults travel the same pipeline: VehicleArmor's SOURCE is edited and everything recomputed.
    python tools/vehicle_ttk_check.py [repo]           the table and the bands
    python tools/vehicle_ttk_check.py [repo] --plant   also the planted faults
"""

import math
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

sys.path.insert(0, str(Path(__file__).resolve().parent))
import weapon_stats  # noqa: E402

TIERS = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]
REFERENCE_RIFLE = "BananiniBurst"
REFERENCE_ROCKET = "CappuccinaLauncher"
CARS = ("Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan")
BIKES = ("BananiniScoot", "PatapimScrambler", "BrrStreetfighter")
ARMOURED = ("TartarugaScout", "CameloCarrier")

STUB = r"""
local V3 = {}
V3.__index = V3
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end }
Vector3.yAxis, Vector3.zAxis, Vector3.xAxis, Vector3.zero = Vector3.new(0, 1, 0), Vector3.new(0, 0, 1), Vector3.new(1, 0, 0), Vector3.new()
math.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
Color3 = { fromRGB = function() return {} end, new = function() return {} end }
CFrame = { new = function() return {} end, Angles = function() return {} end }
"""


def luau(src):
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


def load(repo, armour_src=None):
    shared = Path(repo) / "ReplicatedStorage/Shared"
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(STUB)
    armour = lua.execute(luau(armour_src or (shared / "VehicleArmor.lua").read_text(encoding="utf-8")))
    data = lua.execute(luau((shared / "VehicleWeaponData.lua").read_text(encoding="utf-8")))
    ballistics = lua.execute(luau((shared / "Ballistics.lua").read_text(encoding="utf-8")))
    scale = float(re.search(r"MatchConfig\.CombatDamageScale = ([\d.]+)", (shared / "MatchConfig.lua").read_text()).group(1))
    guns = {}
    for name in weapon_stats.FILES:
        path = Path(repo) / name
        if not path.exists():
            continue
        for gid, body in weapon_stats.entries(path.read_text(encoding="utf-8")).items():
            n = lambda k, d=None: weapon_stats.number(body, k, d)  # noqa: E731
            if n("damage") is None or n("fireRate") is None or n("magSize") is None:
                continue
            guns[gid] = {
                "tier": weapon_stats.text(body, "rarity", "?"), "style": weapon_stats.text(body, "style", "?"),
                "damage": n("damage"), "pellets": int(n("pellets", 1)), "rate": n("fireRate"),
                "mag": n("magSize"), "reload": n("reloadTime", 2.0),
                "projectile": weapon_stats.text(body, "projectile"), "staged": "staged = true" in body,
            }
    return lua, armour, data, ballistics, scale, guns


def firing_dps(g, scale):
    return g["damage"] * g["pellets"] * g["rate"] * scale


def sustained_dps(g, scale):
    per_mag = g["damage"] * g["pellets"] * g["mag"] * scale
    return per_mag / (g["mag"] / g["rate"] + g["reload"])


def ttk(health, g, scale, class_scale):
    """Seconds of one gun's fire, reloads counted, to take `health` (every shot lands)."""
    per_shot = g["damage"] * g["pellets"] * scale * class_scale
    shots = math.ceil(health / per_shot)
    mags = (shots - 1) // int(g["mag"])
    return (shots - 1) / g["rate"] + mags * g["reload"], shots / g["mag"]


def measure(repo, armour_src=None, verbose=True):
    lua, armour, data, ballistics, scale, guns = load(repo, armour_src)
    problems = []
    health = {m: armour.HealthOf(m, "bike" if m in BIKES else "car") for m in CARS + BIKES + ARMOURED}
    rifle = guns[REFERENCE_RIFLE]
    rocket_gun = guns[REFERENCE_ROCKET]
    rocket_round = ballistics.Rounds[rocket_gun["projectile"]]
    rocket_hit = (rocket_gun["damage"] + rocket_round.impactBonus) * scale  # a direct hit, before the class

    def rockets(model):
        return math.ceil(health[model] / (rocket_hit * armour.Scale(model, "explosive")))

    rows = []
    for model in CARS + BIKES + ARMOURED:
        seconds, mags = ttk(health[model], rifle, scale, armour.Scale(model, "bullet"))
        rows.append((model, health[model], seconds, mags, rockets(model)))
    car_mean = sum(health[m] for m in CARS) / len(CARS)
    if verbose:
        print(f"CombatDamageScale {scale}; reference rifle {REFERENCE_RIFLE} ({rifle['tier']} {rifle['style']}): "
              f"{firing_dps(rifle, scale):.1f}/s firing, {sustained_dps(rifle, scale):.1f}/s with reloads; "
              f"reference rocket {REFERENCE_ROCKET}: {rocket_hit:.1f} a direct hit before the explosive class "
              f"(x{armour.Classes.explosive})")
        print(f"{'vehicle':18} {'health':>6} {'rifle s':>8} {'mags':>5} {'rockets':>7}")
        for model, h, seconds, mags, n in rows:
            print(f"{model:18} {h:6.0f} {seconds:8.1f} {mags:5.2f} {n:7d}")
    # CAR
    for model, h, seconds, mags, n in rows:
        if model in CARS:
            if not 10 <= seconds <= 15:
                problems.append(f"CAR {model}: {seconds:.1f} s of the Rare rifle, not 10-15")
            if not 3 <= n <= 4:
                problems.append(f"CAR {model}: {n} rockets, not 3-4")
            if armour.Protects(model, "DriverSeat"):
                problems.append(f"CAR {model}: its driver is behind armour (a car's glass lets shots through)")
    fastest_car = min(r[2] for r in rows if r[0] in CARS)
    for model, h, seconds, mags, n in rows:
        if model in BIKES:
            if not (seconds < fastest_car and seconds < 7.5):
                problems.append(f"BIKE {model}: {seconds:.1f} s of the rifle (a bike must go quicker than any car, and inside 7.5)")
            if not 1 <= n <= 3:
                problems.append(f"BIKE {model}: {n} rockets, not 1-3")
    for model, h, seconds, mags, n in rows:
        if model in ARMOURED:
            ratio = h / car_mean
            resist = 1 - armour.Scale(model, "bullet") / armour.Classes.bullet
            if not 2.0 <= ratio <= 2.5:
                problems.append(f"ARMOUR {model}: {ratio:.2f}x the average car's health, not 2-2.5")
            if not 0.4 - 1e-9 <= resist <= 0.5 + 1e-9:
                problems.append(f"ARMOUR {model}: {resist:.0%} off bullets, not 40-50%")
            if abs(armour.Scale(model, "explosive") - armour.Classes.explosive) > 1e-9:
                problems.append(f"ARMOUR {model}: armour takes something off explosives (they are the counter)")
            if not 6 <= n <= 8:
                problems.append(f"ARMOUR {model}: {n} rockets, not 6-8")
            if not armour.Protects(model, "DriverSeat") or not armour.Protects(model, "PassengerSeat1"):
                problems.append(f"ARMOUR {model}: its cabin does not protect the driver and passengers")
            if armour.Protects(model, "GunnerSeat"):
                problems.append(f"ARMOUR {model}: its gunner is behind armour (the gunner stands in the open)")
            if verbose:
                print(f"  {model}: {ratio:.2f}x a car, {resist:.0%} off bullets, cabin blast share {armour.CabinBlast}")
    # CRASH
    for model in CARS + BIKES:
        kind = "bike" if model in BIKES else "car"
        share = armour.CollisionScale(model, kind) / health[model]
        if abs(share - 1 / armour.CrashBasis[kind]) > 1e-9:
            problems.append(f"CRASH {model}: a crash takes {share * armour.CrashBasis[kind]:.2f}x the share of health it did")
    for model in ARMOURED:
        if armour.CollisionScale(model, "car") / health[model] >= 1 / armour.CrashBasis["car"]:
            problems.append(f"CRASH {model}: armour takes crashes no better than a car")
    # GUNS: the vehicles' own weapons against the average car.
    weapons = {}
    for table, mount in (("ByModel", "turret"), ("DriverByModel", "driver")):
        for model, key in data[table].items():
            weapons[(model, mount)] = data.Weapons[key]
    if verbose:
        print("vehicle weapons against the average car (%d health):" % car_mean)
    for (model, mount), spec in sorted(weapons.items()):
        if spec.kind == "round":
            per = (spec.damage + ballistics.Rounds[spec.projectile].impactBonus) * scale * armour.Classes.explosive
        else:
            per = spec.damage * (spec.pellets or 1) * scale * armour.Classes[spec.damageClass or "bullet"]
        shots = math.ceil(car_mean / per)
        # Its own fire: the magazine, then (after rechargeDelay) `recharge` a second.
        mag, seconds, left = spec.magazine, 0.0, shots
        seconds = min(left, mag) / spec.fireRate
        left -= min(left, mag)
        if left > 0:
            seconds += spec.rechargeDelay + left / min(spec.recharge, spec.fireRate)
        if verbose:
            print(f"  {model:16} {mount:6} {spec.id:26} {per:6.1f} a hit, {shots:3d} hits, {seconds:5.1f} s")
        if mount == "turret" and seconds > 10:
            problems.append(f"GUNS {model} turret: {seconds:.1f} s to kill a car on its own (band: under 10, very powerful)")
        if mount == "driver" and seconds > 15:
            problems.append(f"GUNS {model} driver's gun: {seconds:.1f} s to kill a car (band: under 15, very powerful)")
    if verbose:
        print("hand guns by class and tier (not staged), per second firing / with reloads, after the damage scale:")
        table = {}
        for g in guns.values():
            if g["staged"] or g["projectile"]:
                continue
            table.setdefault((g["style"], g["tier"]), []).append(g)
        for (style, tier), group in sorted(table.items(), key=lambda kv: (kv[0][0], TIERS.index(kv[0][1]) if kv[0][1] in TIERS else 9)):
            f = sum(firing_dps(g, scale) for g in group) / len(group)
            s = sum(sustained_dps(g, scale) for g in group) / len(group)
            car_s = car_mean / s
            print(f"  {style:12} {tier:10} {len(group):2d} guns  {f:6.1f} / {s:6.1f}   a car in {car_s:5.1f} s")
    return problems


PLANTS = [
    ("cars made juggernauts (health doubled)", "Rotster = { health = 1500 },", "Rotster = { health = 3000 },", "CAR Rotster"),
    ("cars made glass cannons", "SahurVan = { health = 1650 },", "SahurVan = { health = 500 },", "CAR SahurVan"),
    ("explosives no longer the counter", "explosive = 6.5,", "explosive = 1,", "rockets"),
    ("armour shrugs off rockets too", 'resist = { bullet = 0.45, heavy = 0.25 }', 'resist = { bullet = 0.45, heavy = 0.25, explosive = 0.5 }', "ARMOUR TartarugaScout"),
    ("armour no better than a car against bullets", 'resist = { bullet = 0.5, heavy = 0.3 }', 'resist = { heavy = 0.3 }', "off bullets"),
    ("the gunner hidden behind armour", 'seatName ~= "GunnerSeat"', "true", "gunner is behind armour"),
    ("a bike tougher than a car", "BrrStreetfighter = { health = 600 },", "BrrStreetfighter = { health = 1500 },", "BIKE BrrStreetfighter"),
]


def main(argv):
    repo = argv[1] if len(argv) > 1 and not argv[1].startswith("--") else "."
    problems = measure(repo)
    for p in problems:
        print("PROBLEM " + p)
    failed = bool(problems)
    if "--plant" in argv:
        source = (Path(repo) / "ReplicatedStorage/Shared/VehicleArmor.lua").read_text(encoding="utf-8")
        caught = 0
        for label, old, new, tag in PLANTS:
            if source.count(old) != 1:
                print(f"plant [{label}]: PLANT ANCHOR MISSING")
                failed = True
                continue
            found = [p for p in measure(repo, source.replace(old, new), verbose=False) if tag in p]
            print(f"plant [{label}]: {'CAUGHT -- ' + found[0] if found else 'MISSED'}")
            caught += bool(found)
        print(f"vehicle_ttk_check planted faults: {caught}/{len(PLANTS)} caught")
        failed |= caught < len(PLANTS)
    print(f"vehicle_ttk_check: {len(problems)} problems")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
