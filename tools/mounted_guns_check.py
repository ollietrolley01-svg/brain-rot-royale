"""Mountable guns check (Oliver, 2026-09-24: "add mountable guns around the battleground and map", "put the
mountable guns in strategic locations", "make sure the mountable guns have good animations, models, sights,
and gameplay use", and "the team bases and battleground must never appear in battle royale").

Everything runs the REAL Lua under lupa -- MountedGunModels' PURE layout, MountedGunData's specs, MountedGuns'
PURE lifecycle and MountedGunPlacement's PURE scorer -- and holds:

  MODEL (per kind, tools/mounted_guns_geom.py poses it the way the Motor6Ds do)
    M1  grounded: the base's lowest point is the floor (y 0), nothing of it below
    M2  nothing floating: every part touches the rest, through its group, back to the anchored base
    M3  the swinging gun never passes through the tripod, pedestal, yoke or sandbags anywhere in its arc
        (yaw across the whole arc, pitch from its lowest to its highest; trunnion pins excepted: they are
        the axis), and the yaw group never through the base
    M4  the sight line is clear: from GunnerSight along the bore and from GunnerEye (the hip view, which
        rides the pitch pivot) through the shield's window, nothing but the sight's own parts in the way
    M5  the arms reach: each grip within the first-person arm's reach of its shoulder (Viewmodel's SHOULDER,
        UPPER + FOREARM) at the hip and aimed, and not closer than a bent elbow allows
    M6  the shield covers the gunner from the front only: straight-ahead rays at the gunner's head and chest
        meet a Shield part; from the side and the back they do not
    M7  the mount contract: pivots, muzzle on the pitch pivot's YZ plane, every marker present
  BALANCE (MountedGunData, VehicleArmor, WeaponData via vehicle_ttk_check's own loader)
    B1  TTK against a player (100, and 200 with a full shield), every round landing, belt heat counted
    B2  TTK against the average car, a bike and each armoured car
    B3  bands: the HMG never out-damages a Rare rifle at close range (it is area denial, not a juggernaut);
        it does kill a car inside 20 s; the cannon kills a car inside 10 s; either gun needs more than one
        second to kill a shielded player; the gun itself breaks to 3-5 rockets and to 3-8 s of a rifle from
        the side, and the shield multiplies that at least 3x
    B4  the arcs are limited (never all the way round) and the traverse slower than a player's run seen from
        close in, so a flanker can get round it
    B5  effective range (where one round in three lands on a body) and time to overheat, reported
  PLACEMENT (MountedGunPlacement.Score on synthetic worlds)
    P1  a good overwatch spot passes, with a field of fire, cover and a flank route
    P2  PLANTED bad spots are rejected: a pit, a wall-facing spot, a spot with no flank route, a spot in a
        spawn, a spot over a drop point, a spot in the lobby, a spot off the floor (no walkable floor)
    P3  the chooser is deterministic for a seed, keeps its minimum spacing and its count band
  LIFECYCLE (MountedGuns' PURE lifecycle with a fake world)
    L1  a BR match builds map guns only; a team match builds a gun at every tagged GunEmplacement and no map
        guns; a BR match after a team match has no arena gun; no gun survives into the next match
    L2  every dismount path clears the seat and the player's InVehicle/VehicleRole: leave (jump), death,
        break, round end, the gun destroyed with its gunner on it
    L3  the remote budgets: the fire remote is VehicleWeapons' (RateLimit Fire), the mount prompt has its
        own per-player cooldown, and the check fails if either is taken out (planted)

    python tools/mounted_guns_check.py [repo]            the checks
    python tools/mounted_guns_check.py [repo] --plant    also the planted faults, each of which must fail
"""

import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import mounted_guns_geom as geom  # noqa: E402

KINDS = ("hmg", "cannon")
# Viewmodel.lua's first-person arm: shoulders in view space, bone lengths.
SHOULDER = {1: [0.72, -0.78, 0.3], -1: [-0.7, -0.8, 0.25]}
ARM = 1.12 + 1.0
SHOULDER_TRAVEL = 1.3
SIGHT_NAMES = ("Sight", "Ring", "Aperture", "FrontPost", "Ladder", "RangeBar", "ApertureSlide")


def fail(problems, text):
    problems.append(text)


# ---------------------------------------------------------------------------------------------------
# MODEL
# ---------------------------------------------------------------------------------------------------

def model_checks(repo, source=None, verbose=True):
    problems = []
    cover = {}
    lua, pure = geom.load(repo, source)
    for kind in KINDS:
        lay = geom.attach(geom.layout(pure, kind))
        parts = lay["parts"]
        spec = weapon_of(repo, kind)
        # M7 the contract
        for name in ("TurretYaw", "TurretPitch"):
            if name not in lay["pivots"]:
                fail(problems, f"M7 {kind}: no {name} pivot")
        for name in ("GunnerEye", "GunnerSight", "GripR", "GripL", "ReloadHand"):
            if name not in lay["markers"]:
                fail(problems, f"M7 {kind}: no {name} marker")
        if abs(lay["muzzle"][0]) > 1e-6 or abs(lay["pivots"]["TurretPitch"]["pos"][0]) > 1e-6:
            fail(problems, f"M7 {kind}: the muzzle or pitch pivot is off the yaw axis's YZ plane")
        # M1 grounded
        lows = []
        for p in parts:
            if p["group"] != "base":
                continue
            c, axes, half = geom.obb(p)
            low = c[1] - sum(half[i] * abs(axes[i][1]) for i in range(3))
            lows.append((low, p["name"]))
        low, lowName = min(lows)
        if abs(low) > 0.02:
            fail(problems, f"M1 {kind}: the base's lowest point is {low:.3f} ({lowName}), not the floor")
        # M2 connected
        boxes = [geom.obb(p, grow=0.03) for p in parts]
        root = next(i for i, p in enumerate(parts) if p["name"] in ("BasePlate", "BaseSkid"))
        seen, todo = {root}, [root]
        while todo:
            i = todo.pop()
            for j in range(len(parts)):
                if j not in seen and geom.obb_overlap(boxes[i], boxes[j]):
                    seen.add(j)
                    todo.append(j)
        floating = [parts[j]["name"] for j in range(len(parts)) if j not in seen]
        if floating:
            fail(problems, f"M2 {kind}: {len(floating)} parts touch nothing that holds them: {', '.join(floating[:8])}")
        # M3 no crossing
        yaws = [-spec["yawLimit"], -spec["yawLimit"] / 2, 0, spec["yawLimit"] / 2, spec["yawLimit"]]
        pitches = [spec["pitchMin"], spec["pitchMin"] / 2, 0, spec["pitchMax"] / 2, spec["pitchMax"]]
        fixed = [p for p in parts if p["group"] == "base"]
        yawed = [p for p in parts if p["group"] == "yaw"]
        moving = [p for p in parts if p["group"] in geom.RIDES_PITCH]
        hits = set()
        for yaw in yaws:
            for p in yawed:
                pb = geom.obb(p, yaw, 0)
                for f in fixed:
                    if geom.obb_overlap(pb, geom.obb(f), 0.01):
                        hits.add((p["name"], f["name"], f"yaw {yaw:g}"))
            for pitch in pitches:
                for m in moving:
                    mb = geom.obb(m, yaw, pitch)
                    for f in fixed + yawed:
                        if "Trunnion" in m["name"] or "Trunnion" in f["name"]:
                            continue
                        fb = geom.obb(f, yaw if f["group"] == "yaw" else 0, 0)
                        if geom.obb_overlap(mb, fb, 0.01):
                            hits.add((m["name"], f["name"], f"yaw {yaw:g} pitch {pitch:g}"))
        for a, b, where in sorted(hits)[:12]:
            fail(problems, f"M3 {kind}: {a} passes through {b} at {where}")
        # M4 sight lines
        for marker in ("GunnerSight", "GunnerEye"):
            info = lay["markers"][marker]
            group = "pitch" if info["on"] == "TurretPitch" else "yaw"
            for pitch in pitches:
                origin = geom.pose_point(lay, group, info["pos"], 0, pitch)
                direction = geom.mv(geom.rx(pitch), [0, 0, -1])
                for p in parts:
                    if any(s in p["name"] for s in SIGHT_NAMES):
                        continue
                    d = geom.ray_box(origin, direction, geom.obb(p, 0, pitch), 12)
                    if d is not None:
                        fail(problems, f"M4 {kind}: the view from {marker} at pitch {pitch:g} meets {p['name']} {d:.2f} out")
                        break
        # M5 reach, in the frame of the eye (hip) and the sight (aimed), both of which ride the pitch pivot
        for view in ("GunnerEye", "GunnerSight"):
            eye = lay["markers"][view]["pos"]
            for side, grip in ((1, "GripR"), (-1, "GripL")):
                g = lay["markers"][grip]["pos"]
                shoulder = geom.add(eye, SHOULDER[side])
                d = geom.norm(geom.sub(g, shoulder))
                if d > ARM * 0.97 + SHOULDER_TRAVEL or d < 0.55:
                    fail(problems, f"M5 {kind}: {grip} is {d:.2f} from the shoulder seen from {view} (reach {ARM:.2f})")
                elif verbose:
                    pass
        # M6 the shield covers the front, not the sides or back: rays from 30 studs off at points across
        # the gunner's silhouette (head, shoulders, chest, belly), level
        eye = lay["markers"]["GunnerEye"]["pos"]
        shields = [p for p in parts if p["shield"]]
        points = [[x, eye[1] + dy, eye[2] + 0.2] for x in (-0.7, -0.35, 0.0, 0.35, 0.7) for dy in (0.1, -0.45, -0.9, -1.4)]
        # From the front everything but the sight slit (the gunner's eyes look through it) is covered.
        for bearing, lo, hi in ((0, 0.65, 1.01), (90, -0.01, 0.1), (-90, -0.01, 0.1), (180, -0.01, 0.1)):
            toward = geom.mv(geom.ry(bearing), [0, 0, 1])  # the shot's way: from the front it travels +Z
            stopped = 0
            for target in points:
                shooter = geom.sub(target, [toward[0] * 30, toward[1] * 30, toward[2] * 30])
                if any(geom.ray_box(shooter, toward, geom.obb(s), 30) is not None for s in shields):
                    stopped += 1
            share = stopped / len(points)
            if not (lo <= share <= hi):
                fail(problems, f"M6 {kind}: from bearing {bearing} the shield stops {share:.0%} of shots at the gunner "
                               f"(wanted {lo:.0%}-{min(hi, 1):.0%})")
            cover[(kind, bearing)] = share
        if verbose:
            print(f"  {kind:7} {len(parts)} parts, {len(set(p['look'] for p in parts)) if 'look' in parts[0] else '?'} looks; "
                  f"base low {low:.3f}; connected {len(seen)}/{len(parts)}; crossings {len(hits)}")
    return problems


def weapon_of(repo, kind):
    data = load_data(repo)
    k = data.Kinds[kind]
    w = data.Weapons[k.weapon]
    return {key: w[key] for key in ("yawLimit", "pitchMin", "pitchMax", "slew")}


_DATA = {}


def load_data(repo, source=None):
    key = (str(repo), source)
    if key not in _DATA:
        from lupa import LuaRuntime
        lua = LuaRuntime(unpack_returned_tuples=True)
        text = source or (Path(repo) / "ReplicatedStorage/Shared/MountedGunData.lua").read_text(encoding="utf-8")
        _DATA[key] = lua.execute(text)
    return _DATA[key]


def luau(src):
    """Luau's compound assignments as plain Lua, for lupa (vehicle_ttk_check's own rewrite)."""
    return re.sub(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", src, flags=re.M)


PRELUDE = """
math.clamp = function(v, a, b) return math.max(a, math.min(b, v)) end
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
"""


def pure_block(text, name):
    m = re.search(r"-- PURE BEGIN\n(.*?)-- PURE END", text, re.S)
    if not m:
        raise SystemExit(f"{name} has no PURE block")
    return m.group(1)


# ---------------------------------------------------------------------------------------------------
# BALANCE
# ---------------------------------------------------------------------------------------------------

def belt_time(spec, shots):
    """Seconds of a mount's own fire to put `shots` rounds out, from a full belt: its fire rate, its
    overheat (VehicleWeaponData.Ready) and its recharge (AmmoAt) as the server runs them."""
    mag, rate = spec["magazine"], spec["fireRate"]
    ammo, hot, t, last, fired = float(mag), False, 0.0, None, 0
    dt = 1.0 / 240
    next_at = 0.0
    while fired < shots:
        # AmmoAt
        if last is not None:
            idle = t - last - spec["rechargeDelay"]
            cur = min(mag, ammo + max(0.0, idle) * spec["recharge"]) if idle > 0 else ammo
        else:
            cur = ammo
        ready = cur >= 1 and not (hot and spec.get("overheat") and cur < mag * spec["overheat"])
        if cur < 1:
            hot = spec.get("overheat") is not None
        elif hot and not (spec.get("overheat") and cur < mag * spec["overheat"]):
            hot = False
        if ready and t >= next_at:
            ammo, last = cur - 1, t
            hot = spec.get("overheat") is not None and ammo < 1
            fired += 1
            next_at = t + 1.0 / rate
            if fired == shots:
                return t
        t += dt
        if t > 600:
            return math.inf
    return t


def balance_checks(repo, data_source=None, verbose=True):
    problems = []
    import vehicle_ttk_check as vt
    lua, armour, vdata, ballistics, scale, guns = vt.load(repo)
    data = load_data(repo, data_source)
    health = {m: armour.HealthOf(m, "bike" if m in vt.BIKES else "car") for m in vt.CARS + vt.BIKES + vt.ARMOURED}
    car = sum(health[m] for m in vt.CARS) / len(vt.CARS)
    rifle = guns[vt.REFERENCE_RIFLE]
    rifle_dps = vt.firing_dps(rifle, scale)
    rocket = guns[vt.REFERENCE_ROCKET]
    sprint = 18 * 1.45
    mt = (Path(repo) / "ReplicatedStorage/Shared/MatchConfig.lua").read_text(encoding="utf-8")
    m1, m2 = re.search(r"BaseWalkSpeed = ([\d.]+)", mt), re.search(r"SprintMultiplier = ([\d.]+)", mt)
    if m1 and m2:
        sprint = float(m1.group(1)) * float(m2.group(1))
    classes = {k: float(data.Classes[k]) for k in ("bullet", "heavy", "explosive")}
    shield_scale = float(data.ShieldScale)
    rows = {}
    for kind in KINDS:
        k = data.Kinds[kind]
        w = data.Weapons[k.weapon]
        spec = {key: w[key] for key in ("magazine", "fireRate", "recharge", "rechargeDelay", "yawLimit", "slew", "damage")}
        spec["overheat"] = w.overheat
        spec["spread"] = w.spread or 0
        is_round = w.kind == "round"
        bonus = float(ballistics.Rounds[w.projectile].impactBonus) if is_round else 0.0
        per_player = (w.damage + bonus) * scale
        vclass = "explosive" if is_round else (w.damageClass or "bullet")

        def per_vehicle(model):
            return (w.damage + bonus) * scale * armour.Scale(model, vclass)

        out = {}
        for label, hp in (("player", 100), ("shielded", 200)):
            n = math.ceil(hp / per_player)
            out[label] = (n, belt_time(spec, n))
        mean_car_hit = (w.damage + bonus) * scale * armour.Scale(vt.CARS[0], vclass)
        n = math.ceil(car / mean_car_hit)
        out["car"] = (n, belt_time(spec, n))
        for model in vt.BIKES[:1] + vt.ARMOURED:
            n = math.ceil(health[model] / per_vehicle(model))
            out[model] = (n, belt_time(spec, n))
        dps = w.damage * w.fireRate * scale
        # The gun itself: a rocket's blast, a rifle from the side and through the shield.
        rocket_hit = rocket["damage"] * scale * classes["explosive"]
        rockets = math.ceil(k.health / rocket_hit)
        rifle_side = k.health / (rifle_dps * classes["bullet"])
        rifle_shield = k.health / (rifle_dps * classes["bullet"] * shield_scale)
        eff = (1.0 / math.tan(math.radians(spec["spread"]) / 3)) if spec["spread"] > 0 else math.inf
        overheat_after = spec["magazine"] / spec["fireRate"]
        cool = (spec["rechargeDelay"] + spec["magazine"] * (spec["overheat"] or (1 / spec["magazine"])) / spec["recharge"])
        flank_rate = math.degrees(sprint / 12.0)
        rows[kind] = dict(out=out, dps=dps, rockets=rockets, rifle_side=rifle_side, rifle_shield=rifle_shield, eff=eff,
                          overheat_after=overheat_after, cool=cool, flank_rate=flank_rate, spec=spec, is_round=is_round)
        # B3 bands
        if not is_round and dps >= rifle_dps:
            fail(problems, f"B3 {kind}: {dps:.0f} damage a second at close range is a Rare rifle's ({rifle_dps:.0f}) or more")
        if out["shielded"][1] <= 1.0:
            fail(problems, f"B3 {kind}: kills a shielded player in {out['shielded'][1]:.2f} s (a juggernaut)")
        limit = 10 if is_round else 20
        if out["car"][1] > limit:
            fail(problems, f"B3 {kind}: takes {out['car'][1]:.1f} s to kill the average car (band: under {limit})")
        if not (3 <= rockets <= 5):
            fail(problems, f"B3 {kind}: breaks to {rockets} rockets (band 3-5)")
        if not (3 <= rifle_side <= 8):
            fail(problems, f"B3 {kind}: breaks to {rifle_side:.1f} s of a Rare rifle from the side (band 3-8)")
        if rifle_shield < 3 * rifle_side:
            fail(problems, f"B3 {kind}: the shield only makes it {rifle_shield / rifle_side:.1f}x as hard to break")
        # B4 arcs and traverse
        if spec["yawLimit"] >= 180:
            fail(problems, f"B4 {kind}: turns all the way round (no flank)")
        if spec["slew"] >= flank_rate:
            fail(problems, f"B4 {kind}: traverses {spec['slew']} deg/s, faster than a sprinter crossing 12 studs off "
                           f"({flank_rate:.0f} deg/s)")
    if verbose:
        print(f"  reference: Rare rifle {rifle_dps:.0f}/s firing; average car {car:.0f}; sprint {sprint:.1f} studs/s; "
              f"damage scale {scale}")
        for kind, r in rows.items():
            o = r["out"]
            print(f"  {kind:7} {r['dps']:.0f}/s; player {o['player'][0]} hits {o['player'][1]:.2f}s, shielded "
                  f"{o['shielded'][0]} {o['shielded'][1]:.2f}s; car {o['car'][0]} {o['car'][1]:.1f}s; "
                  + "; ".join(f"{m} {o[m][0]} {o[m][1]:.1f}s" for m in vt.BIKES[:1] + vt.ARMOURED))
            print(f"          breaks to {r['rockets']} rockets / {r['rifle_side']:.1f}s rifle side / {r['rifle_shield']:.1f}s "
                  f"through the shield; effective range {r['eff']:.0f}; overheats after {r['overheat_after']:.1f}s, "
                  f"back in {r['cool']:.1f}s; arc +-{r['spec']['yawLimit']}, slew {r['spec']['slew']} vs flank "
                  f"{r['flank_rate']:.0f} deg/s")
    return problems, rows


# ---------------------------------------------------------------------------------------------------
# PLACEMENT
# ---------------------------------------------------------------------------------------------------

WORLD = r"""
-- A synthetic map: flat ground at 0 with a hill (a plateau and its slopes), a pit, a lake, a mesa with sheer
-- sides, a wall, crates dotted about, and a lobby far above. Rays march in 1.5-stud steps.
local W = { boxes = {}, grid = {} }
local CELL = 20
local function box(cx, cy, cz, sx, sy, sz)
    local b = { cx, cy, cz, sx / 2, sy / 2, sz / 2 }
    table.insert(W.boxes, b)
    for gx = math.floor((cx - sx / 2) / CELL), math.floor((cx + sx / 2) / CELL) do
        for gz = math.floor((cz - sz / 2) / CELL), math.floor((cz + sz / 2) / CELL) do
            local key = gx * 100000 + gz
            W.grid[key] = W.grid[key] or {}
            table.insert(W.grid[key], b)
        end
    end
end
local EMPTY = {}
local function near(x, z) return W.grid[math.floor(x / CELL) * 100000 + math.floor(z / CELL)] or EMPTY end
function W.height(x, z)
    local h = 0
    local dh = math.sqrt((x - 200) ^ 2 + z ^ 2)
    if dh < 40 then h = 12 elseif dh < 80 then h = 12 * (80 - dh) / 40 end
    local dp = math.sqrt((x + 200) ^ 2 + z ^ 2)
    if dp < 18 then h = -8 elseif dp < 26 then h = -8 * (26 - dp) / 8 end
    if math.abs(x) < 16 and math.abs(z - 200) < 16 then h = 22 end   -- the mesa: sheer on every side
    return h
end
function W.water(x, z) return math.sqrt(x ^ 2 + (z + 330) ^ 2) < 30 end
box(0, 5, -200, 40, 10, 2)            -- a wall just north of (0, -194)
box(207, 13.5, 0, 2, 3, 2)            -- a boulder behind the hilltop
box(0, 23.5, 212, 4, 3, 1)            -- a parapet on the mesa (cover there, so only its flank fails)
box(-200, 1.5, 36, 3, 3, 3)
box(-120, 5, -120, 16, 10, 16)        -- a house: its roof is a floor nobody can climb to
for gx = -540, 540, 24 do for gz = -540, 540, 24 do
    if math.sqrt(gx * gx + gz * gz) < 560 and math.abs(gx) > 60 then box(gx + 7, 1.25, gz + 5, 2.5, 2.5, 2.5) end
end end
local function inBox(x, y, z)
    for _, b in ipairs(near(x, z)) do
        if math.abs(x - b[1]) <= b[4] and math.abs(y - b[2]) <= b[5] and math.abs(z - b[3]) <= b[6] then return true end
    end
    return false
end
local world = {}
function world.floor(x, z)
    if W.water(x, z) then return 0, 1, false end
    local top = W.height(x, z)
    for _, b in ipairs(near(x, z)) do
        if math.abs(x - b[1]) <= b[4] and math.abs(z - b[3]) <= b[6] and b[2] + b[5] > top then top = b[2] + b[5] end
    end
    local e = 0.5
    local nx, nz = W.height(x - e, z) - W.height(x + e, z), W.height(x, z - e) - W.height(x, z + e)
    local ny = 1 / math.sqrt(nx * nx + nz * nz + 1)
    return top, ny, true
end
function world.cast(a, b)
    local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    local step = 1.5
    local n = math.floor(len / step)
    for i = 1, n do
        local t = i * step / len
        local x, y, z = a[1] + dx * t, a[2] + dy * t, a[3] + dz * t
        if y < W.height(x, z) or inBox(x, y, z) then return i * step end
    end
    return nil
end
function world.boxFree(x, y, z, sx, sy, sz)
    for _, b in ipairs(W.boxes) do
        if math.abs(x - b[1]) < b[4] + sx / 2 and math.abs(y - b[2]) < b[5] + sy / 2 and math.abs(z - b[3]) < b[6] + sz / 2 then
            return false
        end
    end
    return true
end
function world.onRoad(x, z) return math.abs(z - 120) < 12 and math.abs(x) < 500 end
function world.reachable(x, z, y) return y <= W.height(x, z) + 4 end
local ctx = {
    radius = 600, lobby = { 0, 500, 0 },
    spawns = { { 420, 0, -60 } },
    drops = { { 300, 0, 300 }, { -300, 0, 300 }, { 60, 0, -380 } },
    pois = {},
    landmarks = { { 300, 0, -300 }, { -300, 0, -300 }, { 0, 0, 380 }, { 420, 0, 150 }, { -420, 0, 120 }, { 200, 0, 0 } },
    junctions = { { 0, 0, 120 }, { -250, 0, 120 }, { 250, 0, 120 } },
    towns = {}, bridgeEnds = {}, roadRuns = { { { -450, 0, 120 }, { 450, 0, 120 } } },
}
for x = -450, 450, 75 do table.insert(ctx.pois, { x, 0, 120, kind = "road", weight = 1 }) end
table.insert(ctx.pois, { 110, 0, 0, kind = "bridge", weight = 3 })
table.insert(ctx.pois, { 140, 0, -60, kind = "junction", weight = 1.5 })
for _, l in ipairs(ctx.landmarks) do table.insert(ctx.pois, { l[1], 0, l[3], kind = "landmark", weight = 2 }) end
return world, ctx
"""

# The planted bad spots: (label, x, z, facing or None for the best facing, the rejection wanted)
PLANTED_SPOTS = [
    ("a pit", -200, 0, None, "pit"),
    ("a wall-facing spot", 0, -194, 0, "blocked field of fire"),
    ("a spot with no flank route (a sheer mesa)", 0, 200, 90, "no flank route"),
    ("a spot in a spawn", 420, -40, None, "spawn"),
    ("a spot overlooking a drop point", 60, -270, 0, "overlooks a drop point"),
    ("a spot on the water", 0, -330, None, "no floor"),
    ("a spot on a road", 100, 120, None, "road"),
    ("a spot on a rooftop", -120, -120, None, "unreachable floor"),
]


def tup(result, n):
    """A Lua call's results as an n-tuple (lupa hands back a lone value bare)."""
    if not isinstance(result, tuple):
        result = (result,)
    return tuple(result) + (None,) * (n - len(result))


def placement_checks(repo, source=None, verbose=True):
    from lupa import LuaRuntime
    problems = []
    text = source or (Path(repo) / "ServerScriptService/Modules/MountedGunPlacement.lua").read_text(encoding="utf-8")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    pure = lua.execute(luau(pure_block(text, "MountedGunPlacement.lua")) + "\nreturn Pure\n")
    world, ctx = lua.execute(WORLD)
    P = pure.Params
    # P1 the good spot: the hilltop, over the road and the bridge
    survey, why = tup(pure.Survey(world, ctx, 200, 0, P), 2)
    if not survey:
        fail(problems, f"P1 the hilltop overwatch was rejected: {why}")
    else:
        ok, score, facing, details = tup(pure.Best(world, survey, P), 4)
        if not ok:
            fail(problems, f"P1 the hilltop overwatch has no usable facing: {details}")
        else:
            if details.coverage < 3 or details.rise < 5 or details.routes < 1 or details.covered < 1:
                fail(problems, f"P1 the hilltop scored poorly: coverage {details.coverage}, rise {details.rise:.1f}, "
                               f"routes {details.routes}, cover {details.covered}")
            if verbose:
                print(f"  good spot (hilltop): score {score:.1f} facing {facing:g}, rise {details.rise:.1f}, "
                      f"coverage {details.coverage}, median sightline {details.median:.0f}, cover {details.covered}, "
                      f"flank routes {details.routes}")
    # P2 planted bad spots
    caught = 0
    for label, x, z, facing, want in PLANTED_SPOTS:
        survey, why = tup(pure.Survey(world, ctx, x, z, P), 2)
        got = why
        if survey:
            if facing is None:
                ok, _, _, details = tup(pure.Best(world, survey, P), 4)
                got = None if ok else details
            else:
                ok, _, why2, _ = tup(pure.Score(world, survey, facing, P), 4)
                got = None if ok else why2
        if got != want:
            fail(problems, f"P2 {label}: wanted '{want}', got '{got or 'accepted'}'")
        else:
            caught += 1
    # the lobby: a point by the lobby position
    survey, why = tup(pure.Survey(world, lua.eval("function(c) return c end")(ctx), 0, 0, P) if False else (None, None), 2)
    lobby_ctx = lua.eval("function(ctx) local c = {} for k, v in pairs(ctx) do c[k] = v end c.lobby = { 205, 12, 5 } return c end")(ctx)
    survey, why = tup(pure.Survey(world, lobby_ctx, 200, 0, P), 2)
    if why != "lobby":
        fail(problems, f"P2 a spot in the lobby: wanted 'lobby', got '{why or 'accepted'}'")
    else:
        caught += 1
    if verbose:
        print(f"  planted bad spots rejected for the right reason: {caught}/{len(PLANTED_SPOTS) + 1}")
    # P3 the chooser
    chosen_a, rejected, considered = tup(pure.Choose(world, ctx, 12345, P), 3)
    chosen_b = tup(pure.Choose(world, ctx, 12345, P), 3)[0]
    spots_a = [(round(c[1], 2), round(c[3], 2), c.facing, c.kind) for c in chosen_a.values()]
    spots_b = [(round(c[1], 2), round(c[3], 2), c.facing, c.kind) for c in chosen_b.values()]
    if spots_a != spots_b:
        fail(problems, "P3 the same seed chose different spots")
    for i, a in enumerate(spots_a):
        for b in spots_a[i + 1:]:
            if math.hypot(a[0] - b[0], a[1] - b[1]) < P.Spacing - 1e-6:
                fail(problems, f"P3 two guns {math.hypot(a[0] - b[0], a[1] - b[1]):.0f} apart (spacing {P.Spacing})")
    if len(spots_a) > P.Count.max:
        fail(problems, f"P3 {len(spots_a)} guns, over the most ({P.Count.max})")
    cannons = sum(1 for s in spots_a if s[3] == "cannon")
    if spots_a and not (len(spots_a) // 3 == cannons):
        fail(problems, f"P3 {cannons} cannons of {len(spots_a)}")
    tally = ", ".join(f"{k} {v}" for k, v in sorted(dict(rejected).items()))
    if verbose:
        print(f"  synthetic map: {len(spots_a)} guns ({cannons} cannons) from {considered} candidates; rejected: {tally}")
    if len(spots_a) < 6:
        fail(problems, f"P3 only {len(spots_a)} guns chosen on the synthetic map")
    return problems


# ---------------------------------------------------------------------------------------------------
# LIFECYCLE
# ---------------------------------------------------------------------------------------------------

LIFE_ENV = r"""
local Life, data = ...
local log = { built = {}, destroyed = {}, released = {} }
local clock = 0
local nextId = 0
local riders = {}
local env = {}
function env.build(kind, cframe, source, matchId)
    nextId = nextId + 1
    local gun = { id = nextId, kind = kind, source = source, matchId = matchId, alive = true }
    table.insert(log.built, gun)
    return gun
end
function env.destroy(gun) gun.alive = false; table.insert(log.destroyed, gun) end
function env.release(gun, reason)
    local r = riders[gun]
    if r then r.InVehicle = nil; r.VehicleRole = nil; r.seated = nil; riders[gun] = nil end
    table.insert(log.released, { gun = gun, reason = reason })
end
local spots = {}
function env.emplacements() return spots end
function env.frameOf(spot) return spot.frame end
function env.kindOf(spot) return spot.Kind end
function env.choose(mapInfo) return mapInfo.spots end
function env.now() return clock end
local life = Life.new(env, data)
local api = {}
function api.life() return life end
function api.log() return log end
function api.setSpots(list) spots = list end
function api.advance(s) clock = clock + s end
function api.seat(gun, name) local r = { name = name, InVehicle = true, VehicleRole = "Gunner", seated = gun } riders[gun] = r return r end
function api.alive()
    local n, arena, map = 0, 0, 0
    for _, e in ipairs(life.guns) do if e.gun.alive then n = n + 1 if e.source == "arena" then arena = arena + 1 else map = map + 1 end end end
    local stray = 0
    for _, g in ipairs(log.built) do if g.alive then stray = stray + 1 end end
    return n, arena, map, stray
end
return api
"""


def lifecycle_checks(repo, source=None, verbose=True):
    from lupa import LuaRuntime
    problems = []
    text = source or (Path(repo) / "ServerScriptService/Modules/MountedGuns.lua").read_text(encoding="utf-8")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    Life = lua.execute(luau(pure_block(text, "MountedGuns.lua")) + "\nreturn Life\n")
    data = lua.execute((Path(repo) / "ReplicatedStorage/Shared/MountedGunData.lua").read_text(encoding="utf-8"))
    api = lua.execute(LIFE_ENV, Life, data)
    t = lua.table
    life = api.life()
    arena_spots = t(*[t(frame=i, Kind=("cannon" if i == 2 else None)) for i in range(1, 11)])
    br_map = t(spots=t(t(kind="hmg", cframe=1), t(kind="cannon", cframe=2), t(kind="hmg", cframe=3)))

    # 1. A battle royale, with a stray tagged emplacement lying about: map guns only.
    api.setSpots(t(t(frame=99)))
    life.start(life, False, br_map)
    n, arena, mp, stray = api.alive()
    if arena != 0 or mp != 3:
        fail(problems, f"L1 BR #1: {arena} arena guns and {mp} map guns (wanted 0 and 3)")
    if life.atEmplacement(life, t(frame=100)) is not None:
        fail(problems, "L1 BR #1: a GunEmplacement appearing mid-match got a gun")
    rider = api.seat(life.guns[1].gun, "p1")
    life.finish(life)
    n, arena, mp, stray = api.alive()
    if stray:
        fail(problems, f"L1 BR #1 ended with {stray} guns still standing")
    if rider.InVehicle or rider.VehicleRole or rider.seated:
        fail(problems, "L2 round end left a gunner seated or flagged InVehicle")

    # 2. A team match: a gun at every emplacement, none of the map's.
    api.setSpots(arena_spots)
    life.start(life, True, br_map)
    n, arena, mp, stray = api.alive()
    if arena != 10 or mp != 0:
        fail(problems, f"L1 team: {arena} arena guns and {mp} map guns (wanted 10 and 0)")
    late = life.atEmplacement(life, t(frame=11))
    if late is None:
        fail(problems, "L1 team: a GunEmplacement placed after the start got no gun")
    kinds = [e.kind for e in life.guns.values()]
    if "cannon" not in kinds or "hmg" not in kinds:
        fail(problems, f"L1 team: the arena's kinds are {sorted(set(kinds))}")
    # a gun breaks with a gunner on it: thrown off, rebuilt after RebuildDelay
    entry = life.guns[1]
    rider = api.seat(entry.gun, "p2")
    life.broken(life, entry)
    if rider.seated or rider.InVehicle:
        fail(problems, "L2 a broken gun kept its gunner")
    api.advance(float(data.RebuildDelay) - 1)
    life.tick(life)
    if life.guns[1].gun.id != entry.gun.id:
        fail(problems, "L1 a broken gun was rebuilt before RebuildDelay")
    api.advance(2)
    life.tick(life)
    if life.guns[1].gun.id == entry.gun.id or entry.gun.alive:
        fail(problems, "L1 a broken gun was not replaced after RebuildDelay")
    rider = api.seat(life.guns[2].gun, "p3")
    life.finish(life)
    n, arena, mp, stray = api.alive()
    if stray:
        fail(problems, f"L1 the team match ended with {stray} guns standing")
    if rider.seated or rider.InVehicle:
        fail(problems, "L2 the team match's round end left a gunner on")

    # 3. A battle royale after the team match: the arena's tagged parts are still about (planted leak).
    api.setSpots(arena_spots)
    life.start(life, False, br_map)
    n, arena, mp, stray = api.alive()
    if arena != 0:
        fail(problems, f"L1 BR #2 after a team match has {arena} arena guns")
    for i in range(1, 4):
        life.atEmplacement(life, arena_spots[i])
    n, arena, mp, stray = api.alive()
    if arena != 0:
        fail(problems, f"L1 BR #2: tagged emplacements appearing mid-match built {arena} arena guns")
    # A new match started without the old one ending (a server that skipped OnMatchEnd): nothing leaks.
    life.start(life, False, br_map)
    n, arena, mp, stray = api.alive()
    if stray != 3:
        fail(problems, f"L1 a match started over a live one left {stray - 3} guns from the last")
    life.finish(life)
    reasons = sorted(set(r.reason for r in api.log().released.values()))
    if verbose:
        print(f"  BR -> team -> BR: guns built {len(api.log().built)}, destroyed {len(api.log().destroyed)}; "
              f"release reasons seen {reasons}")
    # L2 the runtime's own dismount paths, read off MountedGuns.lua
    for pattern, what in (
        (r'release\(model, rider\.humanoid and rider\.humanoid\.Health <= 0 and "death" or "leave"\)', "the seat letting go (jump)"),
        (r'Died:Connect\(function\(\)\s*if riders\[model\] == entry then\s*release\(model, "death"\)', "death"),
        (r'release\(model, "destroyed"\)', "the gun destroyed"),
        (r'life:broken\(entry\)', "the gun breaking"),
        (r'SetAttribute\("InVehicle", nil\)\s*player:SetAttribute\("VehicleRole", nil\)', "clearing the rider's flags"),
    ):
        if not re.search(pattern, text):
            fail(problems, f"L2 MountedGuns.lua lost its dismount path for {what}")
    return problems


def remote_checks(repo, weapons_source=None, guns_source=None):
    problems = []
    vw = weapons_source or (Path(repo) / "ServerScriptService/Modules/VehicleWeapons.lua").read_text(encoding="utf-8")
    mg = guns_source or (Path(repo) / "ServerScriptService/Modules/MountedGuns.lua").read_text(encoding="utf-8")
    if not re.search(r'VehicleWeaponFire"\)\.OnServerEvent:Connect\(function\(player, aimPoint\)(?:(?!end\)).)*?RateLimit\.Take\(player, "Fire"\)', vw, re.S):
        fail(problems, "L3 the mount fire remote (VehicleWeaponFire) is not held to RateLimit Fire")
    if not re.search(r'VehicleWeaponAim"\)\.OnServerEvent(?:(?!end\)\n).)*?bucket\.tokens < 1', vw, re.S):
        fail(problems, "L3 the mount aim remote lost its token bucket")
    m = re.search(r"local function tryMount\(player, model\)(.*?)\nend\n", mg, re.S)
    if not m or not re.search(r"MountCooldown", m.group(1).split("seat:Sit")[0]):
        fail(problems, "L3 the mount prompt has no per-player cooldown before it sits anyone")
    if m and not re.search(r"MountReach", m.group(1)):
        fail(problems, "L3 the mount prompt does not check the player is near the seat")
    if not re.search(r'VehicleWeaponReload"\)\.OnServerEvent:Connect\(function\(player\)\s*if not RateLimit\.Take\(player, "Reload"\)', vw):
        fail(problems, "L3 the belt-change remote (VehicleWeaponReload) is not held to RateLimit Reload")
    if 'OnServerEvent' in mg:
        fail(problems, "L3 MountedGuns listens to a remote of its own (the prompt is the only way on)")
    return problems


# ---------------------------------------------------------------------------------------------------
# ROTATION (Oliver 09-24: "the mounted guns rotation needs to be made smoother")
# ---------------------------------------------------------------------------------------------------

def follow_fn(repo, source=None):
    from lupa import LuaRuntime
    text = source or (Path(repo) / "StarterPlayerScripts/GunnerView.lua").read_text(encoding="utf-8")
    m = re.search(r"(Pure\.FollowOmega = .*?\nfunction Pure\.follow\(.*?\n)end\n", text, re.S)
    if not m:
        raise SystemExit("GunnerView.lua has no Pure.follow")
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    return lua.execute("local Pure = {}\n" + luau(m.group(1)) + "end\nreturn Pure.follow")


def sweep(follow, spec, fps, targets, seconds, omega=None):
    """Angles per frame following `targets(t)` at `fps` for `seconds`."""
    dt = 1.0 / fps
    value, vel, out = 0.0, 0.0, []
    for i in range(int(seconds * fps)):
        t = i * dt
        want = max(-spec["yawLimit"], min(spec["yawLimit"], targets(t)))
        value, vel = follow(value, vel, want, dt, spec["slew"], spec["slewAccel"], False, omega)
        out.append((t + dt, want, value, vel))
    return out


MAX_OVERSHOOT = 0.25  # degrees past the wanted angle (or the arc's limit) at any frame


def rotation_checks(repo, source=None, verbose=True):
    problems = []
    follow = follow_fn(repo, source)
    data = load_data(repo)
    for kind in KINDS:
        w = data.Weapons[data.Kinds[kind].weapon]
        spec = {"slew": w.slew, "slewAccel": w.slewAccel or w.slew * 6, "yawLimit": w.yawLimit}
        max_step = spec["slew"] / 60 + 0.01

        # A fast mouse flick to the arc's edge and back, and a hard sweep, at 60 fps.
        def flick(t):
            return 200 if t < 1.2 else (-200 if t < 2.6 else 10)
        frames = sweep(follow, spec, 60, flick, 4.0)
        steps = [abs(frames[i][2] - frames[i - 1][2]) for i in range(1, len(frames))]
        worst_step = max(steps)
        accel = max(abs(frames[i][3] - frames[i - 1][3]) * 60 for i in range(1, len(frames)))
        overshoot = 0.0
        for (_, want, value, _), prev in zip(frames[1:], frames[:-1]):
            if want >= prev[2]:
                overshoot = max(overshoot, value - want)
            else:
                overshoot = max(overshoot, want - value)
        beyond = max(abs(f[2]) - spec["yawLimit"] for f in frames)
        if worst_step > max_step:
            fail(problems, f"R1 {kind}: the gun jumps {worst_step:.2f} deg in a frame at 60 fps (at most {max_step:.2f})")
        if overshoot > MAX_OVERSHOOT or beyond > MAX_OVERSHOOT:
            fail(problems, f"R2 {kind}: overshoots by {max(overshoot, beyond):.2f} deg (at most {MAX_OVERSHOOT})")
        if accel > spec["slewAccel"] * 1.05:
            fail(problems, f"R3 {kind}: accelerates at {accel:.0f} deg/s^2 (at most {spec['slewAccel']})")
        settled = frames[-1][2]
        if abs(settled - 10) > 0.05:
            fail(problems, f"R4 {kind}: has not settled on its aim after a second and a half ({settled:.2f} vs 10)")
        # Frame-rate independence: 30, 60 and 144 fps agree.
        at = {fps: next(v for (tt, _, v, _) in sweep(follow, spec, fps, flick, 0.51) if tt >= 0.5) for fps in (30, 60, 144)}
        spreadfps = max(at.values()) - min(at.values())
        if spreadfps > 1.5:
            fail(problems, f"R5 {kind}: at 0.5 s the gun stands {spreadfps:.2f} deg apart between 30 and 144 fps")
        # Someone else's gun from the 10 Hz aim attribute (VehicleWeaponClient's follow, omega 10): no steps.
        def replicated(t):
            return math.floor(t * 10) / 10 * 90  # a target stepping at 10 Hz, 90 deg/s
        others = sweep(follow, {**spec, "slew": min(240, spec["slew"] * 1.25)}, 60, replicated, 1.0, 10)
        other_step = max(abs(others[i][2] - others[i - 1][2]) for i in range(1, len(others)))
        if other_step > min(240, spec["slew"] * 1.25) / 60 + 0.01:
            fail(problems, f"R6 {kind}: others see the gun jump {other_step:.2f} deg in a frame")
        if verbose:
            print(f"  {kind:7} 60 fps flick: worst step {worst_step:.2f} deg/frame (cap {max_step:.2f}), overshoot "
                  f"{max(overshoot, beyond):.3f} deg, peak accel {accel:.0f} deg/s^2; 30/60/144 fps agree to "
                  f"{spreadfps:.2f} deg; others' 10 Hz view worst step {other_step:.2f}")
    return problems


# ---------------------------------------------------------------------------------------------------
# PHONE AND PAD (Oliver 09-24: "make sure the whole game is phone and xbox compatible")
# ---------------------------------------------------------------------------------------------------

# Screens: (label, width, height, touch, left/right safe inset). The Roblox jump button: 70 px at (w-95,
# h-90) on a small screen (shorter side under 500), 120 px at (w-170, h-210) otherwise.
DEVICES = [("phone 667x375", 667, 375, True, 0), ("phone notch 812x375", 812, 375, True, 44),
           ("phone 896x414", 896, 414, True, 44), ("tablet 1024x768", 1024, 768, True, 0),
           ("xbox 1920x1080", 1920, 1080, False, 0)]
BUTTON = 70  # a ContextActionService touch button
PAD_KEYS = {"fire": "ButtonR2", "aim": "ButtonL2", "reload": "ButtonX", "leave": "ButtonB"}


def udim2(text):
    m = re.search(r"UDim2\.new\(\s*([-\d.]+),\s*([-\d.]+),\s*([-\d.]+),\s*([-\d.]+)\s*\)", text)
    return tuple(float(g) for g in m.groups()) if m else None


def input_checks(repo, client_source=None, weapon_source=None, verbose=True):
    problems = []
    mc = client_source or (Path(repo) / "StarterPlayerScripts/MountedGunClient.client.lua").read_text(encoding="utf-8")
    vc = weapon_source or (Path(repo) / "StarterPlayerScripts/VehicleWeaponClient.client.lua").read_text(encoding="utf-8")
    turret = re.search(r'elseif want == "turret" then(.*?)\n\tend', vc, re.S)
    turret = turret.group(1) if turret else ""
    fire = re.search(r'BindAction\("BRR_VehicleFire"[^\n]*', turret)
    aim = re.search(r'BindAction\("BRR_GunnerAim"[^\n]*', turret)
    reload = re.search(r"reload = \{[^\n]*\n[^\n]*keys = \{([^}]*)\}", mc)
    leave = re.search(r"leave = \{[^\n]*\n[^\n]*keys = \{([^}]*)\}", mc)
    found = {"fire": fire and fire.group(0), "aim": aim and aim.group(0), "reload": reload and reload.group(1),
             "leave": leave and leave.group(1)}
    for what, key in PAD_KEYS.items():
        if not found[what] or key not in found[what]:
            fail(problems, f"I1 the gunner's {what} is not on the pad's {key}")
    for what in ("fire", "aim"):
        if found[what] and ", true," not in found[what]:
            fail(problems, f"I1 the gunner's {what} has no touch button")
    if mc.count("BindActionAtPriority(GUNNER_BUTTONS.") != 2 or mc.count(", true, Enum.ContextActionPriority") < 2:
        fail(problems, "I1 RELOAD / LEAVE are not both bound with a touch button")
    # Touch buttons: FIRE and AIM (VehicleWeaponClient), RELOAD and LEAVE (MountedGunClient).
    buttons = {}
    for name, src, pat in (("FIRE", vc, r'SetPosition\("BRR_VehicleFire", [^\n]*?(UDim2\.new\([^)]*\))'),
                           ("AIM", vc, r'SetPosition\("BRR_GunnerAim", (UDim2\.new\([^)]*\))'),
                           ("RELOAD", mc, r'reload = \{[^\n]*position = (UDim2\.new\([^)]*\))'),
                           ("LEAVE", mc, r'leave = \{[^\n]*position = (UDim2\.new\([^)]*\))')):
        m = re.search(pat, src)
        if not m:
            fail(problems, f"I2 no touch position for {name}")
        else:
            buttons[name] = udim2(m.group(1))
    panel = udim2(re.search(r"TOUCH_PANEL = \{[^\n]*position = (UDim2\.new\([^)]*\))", mc).group(1)) \
        if re.search(r"TOUCH_PANEL = \{[^\n]*position = (UDim2\.new\([^)]*\))", mc) else None
    sizes = [int(s) for s in re.findall(r"TextSize = (\d+)", mc)]
    if not sizes or min(sizes) < 12:
        fail(problems, f"I3 the gunner's HUD text is {min(sizes) if sizes else '?'} px (at least 12 on a phone)")
    for label, w, h, touch, inset in DEVICES:
        if not touch:
            continue
        # The touch controls live inside the safe area: lay them out on its width, then shift by the inset.
        full = w
        w = w - 2 * inset
        rects = {}
        for name, u in buttons.items():
            x, y = u[0] * w + u[1], u[2] * h + u[3]
            rects[name] = (x, y, x + BUTTON, y + BUTTON)
        small = min(w, h) < 500
        jump = 70 if small else 120
        rects["JUMP"] = (w - (95 if small else 170), h - (90 if small else 210)) + ()
        rects["JUMP"] = (rects["JUMP"][0], rects["JUMP"][1], rects["JUMP"][0] + jump, rects["JUMP"][1] + jump)
        if panel:
            px = panel[0] * w + panel[1] - 120
            py = panel[2] * h + panel[3] + 36  # below the top bar (the inset is not ignored on a phone)
            rects["HUD"] = (px, py, px + 240, py + 46)
        rects = {k: (r[0] + inset, r[1], r[2] + inset, r[3]) for k, r in rects.items()}
        names = sorted(rects)
        for i, a in enumerate(names):
            ra = rects[a]
            if ra[0] < inset or ra[2] > full - inset or ra[1] < 36 or ra[3] > h:
                fail(problems, f"I2 {label}: {a} is off the safe area {tuple(round(v) for v in ra)}")
            for b in names[i + 1:]:
                rb = rects[b]
                if ra[0] < rb[2] and rb[0] < ra[2] and ra[1] < rb[3] and rb[1] < ra[3]:
                    fail(problems, f"I2 {label}: {a} overlaps {b}")
    if verbose:
        print(f"  pad: {', '.join(f'{k} {v}' for k, v in PAD_KEYS.items())}; touch buttons {sorted(buttons)} + jump + HUD "
              f"on {sum(1 for d in DEVICES if d[3])} touch screens; HUD text {min(sizes) if sizes else '?'}+ px")
    return problems


# ---------------------------------------------------------------------------------------------------
# PLANTED FAULTS
# ---------------------------------------------------------------------------------------------------

def planted(repo):
    root = Path(repo)
    models = (root / "ReplicatedStorage/Shared/MountedGunModels.lua").read_text(encoding="utf-8")
    placement = (root / "ServerScriptService/Modules/MountedGunPlacement.lua").read_text(encoding="utf-8")
    guns = (root / "ServerScriptService/Modules/MountedGuns.lua").read_text(encoding="utf-8")
    weapons = (root / "ServerScriptService/Modules/VehicleWeapons.lua").read_text(encoding="utf-8")
    gunner = (root / "StarterPlayerScripts/GunnerView.lua").read_text(encoding="utf-8")
    data = (root / "ReplicatedStorage/Shared/MountedGunData.lua").read_text(encoding="utf-8")

    def model_src(a, b):
        assert a in models, a
        return geom.pure_source(repo).replace(a, b) if a in geom.pure_source(repo) else None

    faults = [
        ("the tripod sunk into the floor", lambda: model_checks(repo, model_src(
            'L.add("BasePlate", "Cylinder", { 0.25, 2.6, 2.6 }, { 0, 0.125, 0 }',
            'L.add("BasePlate", "Cylinder", { 0.25, 2.6, 2.6 }, { 0, -0.3, 0 }'), verbose=False), "M1"),
        ("the shield hung in the air", lambda: model_checks(repo, model_src(
            "local t = 0.1\n\tlocal half = width / 2", "local t = 0.1\n\tz = z - 3\n\tlocal half = width / 2"), verbose=False), "M2"),
        ("the ammo can through the yoke", lambda: model_checks(repo, model_src(
            'L.box("AmmoCan", { 0.4, 0.5, 0.72 }, { -0.74,', 'L.box("AmmoCan", { 0.4, 0.5, 0.72 }, { -0.4,'), verbose=False), "M3"),
        ("the sight window closed", lambda: model_checks(repo, model_src(
            'L.box("ShieldBar", { port * 2, winBottom - portTop, t }',
            'L.box("ShieldPane", { win[1] * 2, win[2] * 2, t }, { 0, sight, z }, "shield", o)\n\tL.box("ShieldBar", { port * 2, winBottom - portTop, t }'),
            verbose=False), "M4"),
        ("the grips out of reach", lambda: model_checks(repo, model_src(
            "local zGrip = zBack + 0.3", "local zGrip = zBack - 2.4"), verbose=False), "M5"),
        ("a shield all the way round", lambda: model_checks(repo, model_src(
            "local front = z - t / 2 - 0.035",
            'L.box("ShieldBack", { width, top - bottom, t }, { 0, (top + bottom) / 2, 3.2 }, "shield", o)\n\tlocal front = z - t / 2 - 0.035'),
            verbose=False), "M6"),
        ("an HMG that out-damages a rifle", lambda: balance_checks(repo, data.replace("fireRate = 8,", "fireRate = 20,"), verbose=False)[0], "B3"),
        ("a gun that turns all the way round", lambda: balance_checks(repo, data.replace("yawLimit = 60,", "yawLimit = 180,"), verbose=False)[0], "B4"),
        ("the pit check taken out", lambda: placement_checks(repo, placement.replace('return nil, "pit"', 'rise = rise'), verbose=False), "P2"),
        ("the flank check taken out", lambda: placement_checks(repo, placement.replace('if routes == 0 then', 'if routes < 0 then'), verbose=False), "P2"),
        ("the field-of-fire check taken out", lambda: placement_checks(repo, placement.replace("if median < P.FireMinClear then", "if false then"), verbose=False), "P2"),
        ("guns from the last match left standing", lambda: lifecycle_checks(repo, guns.replace(
            'function Life:start(teams, mapInfo)\n\tself:clear("round end")', 'function Life:start(teams, mapInfo)'), verbose=False), "L1"),
        ("an arena gun in the battle royale", lambda: lifecycle_checks(repo, guns.replace(
            "if not self.live or not self.teams or self.bySpot[spot] then", "if not self.live or self.bySpot[spot] then"), verbose=False), "L1"),
        ("a broken gun keeping its gunner", lambda: lifecycle_checks(repo, guns.replace(
            '\tentry.broken = true\n\tself.env.release(entry.gun, "break")', '\tentry.broken = true'), verbose=False), "L2"),
        ("the fire remote's rate limit taken out", lambda: remote_checks(repo, weapons_source=weapons.replace(
            'if not RateLimit.Take(player, "Fire") then\n\t\t\treturn\n\t\tend\n', '')), "L3"),
        ("the mount cooldown taken out", lambda: remote_checks(repo, guns_source=re.sub(
            r"\tif mountedAt\[player\] and now - mountedAt\[player\] < MountedGunData\.MountCooldown then\n\t\treturn false, \"cooldown\"\n\tend\n",
            "", guns)), "L3"),
        ("a snapping turret", lambda: rotation_checks(repo, gunner.replace(
            "\tlocal left = math.min(dt, 0.1)\n", "\tdo return target, 0 end\n\tlocal left = math.min(dt, 0.1)\n", 1), verbose=False), "R1"),
    ]
    client = (root / "StarterPlayerScripts/MountedGunClient.client.lua").read_text(encoding="utf-8")
    faults += [
        ("RELOAD's touch button on top of FIRE", lambda: input_checks(repo, client.replace(
            'title = "RELOAD", position = UDim2.new(1, -250, 1, -280)', 'title = "RELOAD", position = UDim2.new(1, -100, 1, -270)'),
            verbose=False), "I2"),
        ("the leave button off the pad's B", lambda: input_checks(repo, client.replace(
            "keys = { Enum.KeyCode.ButtonB }", "keys = { Enum.KeyCode.ButtonY }"), verbose=False), "I1"),
        ("phone HUD text shrunk to 10 px", lambda: input_checks(repo, client.replace(
            "info.TextSize = 12", "info.TextSize = 10"), verbose=False), "I3"),
        ("the belt-change remote's rate limit taken out", lambda: remote_checks(repo, weapons_source=weapons.replace(
            'if not RateLimit.Take(player, "Reload") then', 'if false then')), "L3"),
    ]
    ok = True
    for label, run, code in faults:
        try:
            got = run()
        except AssertionError as e:
            print(f"  PLANT '{label}': the plant no longer applies ({e})")
            ok = False
            continue
        hit = [p for p in got if p.startswith(code)]
        print(f"  PLANT {'caught' if hit else 'MISSED'} ({code}): {label}" + (f" -- {hit[0]}" if hit else ""))
        ok = ok and bool(hit)
    return ok


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    repo = Path(args[0] if args else ".")
    problems = []
    print("MODEL")
    problems += model_checks(repo)
    print("BALANCE")
    problems += balance_checks(repo)[0]
    print("PLACEMENT")
    problems += placement_checks(repo)
    print("LIFECYCLE")
    problems += lifecycle_checks(repo)
    problems += remote_checks(repo)
    print("ROTATION")
    problems += rotation_checks(repo)
    print("PHONE AND PAD")
    problems += input_checks(repo)
    for p in problems:
        print("  FAIL " + p)
    status = 0 if not problems else 1
    if "--plant" in sys.argv:
        print("PLANTED FAULTS")
        if not planted(repo):
            status = 1
    print(f"mounted_guns_check: {len(problems)} problem(s)")
    return status


if __name__ == "__main__":
    sys.exit(main())
