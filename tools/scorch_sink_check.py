"""A ground scorch reaches the floor of the crater its own blast digs, and no further.

    python3 tools/scorch_sink_check.py .            the check; exit 1 on any failure
    python3 tools/scorch_sink_check.py . --plant    also plants each fault and shows the check catches it

A blast's scorch (StarterPlayerScripts/ExplosiveFx.lua) is nine patches cast down onto the surface
the blast hit. On terrain the server then digs a crater (DestructibleService.CraterAt), and the
patches are laid again a few times (SCORCH_RELAY) so they follow the ground down into it. A patch
casts from a stud above the blast's plane to SCORCH_SINK below it; one that finds nothing is hidden.
So SCORCH_SINK must reach the deepest floor ONE blast can dig under the plane it hit (the plane is the
ground as it was before that blast, so a 24-deep bowl dug by six blasts needs only one blast's worth),
and nothing past it: a patch hanging over a drop deeper than any crater would land on whatever is down
there (a gorge floor, a river bed through the water, a road in a notch).

Two halves, each the real source under lupa:
  server  DestructibleService.CraterAt (tools/destruct_mocks.lua, as tools/destruct_map_check.py runs
          it) on a smooth heightfield: flat ground at 8 heights across a voxel row, eight blasts on one
          spot (the bowl bottoms out at DIG_DEPTH), blasts on the wall of that bowl and of a one-blast
          crater, and hillsides of 15-45 degrees at 4 heights and 3 places across a 4-stud cell. For
          every blast source that digs (SOURCES), 58 scenarios. Measures each crater's apex under the blast's own
          surface point, and how far the ring fills leave the floor under the apex (a row whose middle
          is at or over the apex is cleared whole, and the voxel pass only lowers: up to half a row).
  client  ExplosiveFx.Explosion drawn on the ground as it was, the crater dug under it a moment later
          (the design cone, lowered by the measured row rounding plus BASALT_ROUGH, the char's raycast
          roughness), and the relays run out. Every patch must be drawn and lie on the ground.

  E  every patch of every realistic blast's scorch lies on the floor of the crater it dug
     plants: SCORCH_SINK set 0.5 under the measured need; craters dug deeper (DEEPEN 0.8 -> 1.2)
  F  a ground blast a stud from the edge of a drop deeper than any crater leaves nothing on the level
     below (the drop is the deepest need plus DROP_PAST)
     plant: SCORCH_SINK = 25 (the 09-25 handoff's number)

What it can't show: how the scorch looks on real smooth terrain (the mesh rounds the voxel stairs this
takes at their worst), or the engine's own raycast against Basalt. Both need a render on Oliver's
machine (tools/crater_scorch_gallery.lua shows the bowl; a blast drawn over it shows the scorch).
"""

import math
import os
import re
import sys


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import destruct_map_check as dmc  # noqa: E402  (its World runs DestructibleService on the mocks)

ROOT = dmc.ROOT
FX = os.path.join(ROOT, "StarterPlayerScripts", "ExplosiveFx.lua")
FX_SINK = re.compile(r"local SCORCH_SINK, SCORCH_LIP = ([\d.]+), ([\d.]+)")

# Basalt (the crater's char, DestructibleService CHAR) raycasts off its voxels by up to this: measured
# in Studio by tools/road_terrain_probe.lua as +-0.7 (RoadNetwork.lua), recorded as +-0.8 in Landmarks.lua.
BASALT_ROUGH = 0.8
# F's drop is this much deeper than the deepest crater floor measured in E.
DROP_PAST = 2

# Every blast that reaches DestructibleService.DamageInRadius, as (name, client look, client radius,
# server reach, server wall damage). Projectiles pass reach = radius * WALL_REACH (0.5) and their
# wallDamage (ProjectileService:442); barrels pass their full radius and baseDamage * 1.2
# (HazardService:401). `look` is the kind ExplosiveFx draws (ProjectileClient BLAST_LOOK); None for a
# blast drawn with no scorch (a silly theme, or not drawn by ExplosiveFx), which still digs.
# `radius` is the blast's full radius (what the client is sent); reach and damage are what
# DamageInRadius gets. Last, one blast per look at CRATER_MAX (any blast big enough to hit the clamp,
# including one not written yet): the deepest a single blast can dig, whatever the weapon list says.
SOURCES = [
    ("Tralala Thumper (Ballistics:131, WeaponData:474)", "grenade", 11, 5.5, 110),
    ("CookedCoconut (Ballistics:139)", "frag", 13, 6.5, 120),
    ("ClingyCrumpet (Ballistics:155, sticky)", "frag", 12, 6, 130),
    ("Explosive Barrel (HazardService:81)", "grenade", 15, 15, 78 * 1.2),
    ("Rot Mine (HazardService:91)", "grenade", 10, 10, 95 * 1.2),
    ("Ranger Rocket Pod (VehicleWeaponData:79)", "rocket", 16, 8, 150),
    ("Sahur Van Mortar (VehicleWeaponData:105)", "grenade", 18, 9, 110),
    ("Camelo Grenade Launcher (VehicleWeaponData:149)", "grenade", 11, 5.5, 110),
    ("Boomba Grenade Cannon (MountedGunData:70)", "grenade", 13, 6.5, 110),
    ("Cappuccina Launcher (coffee theme)", None, 14, 7, 150),
    ("Tamburo Tung Tung (party theme)", None, 7, 3.5, 40),
    ("Toaster Mortar (toast theme)", None, 10, 5, 80),
    ("Golden Sahur Cannon (gold theme)", None, 5, 2.5, 60),
    ("any blast at CRATER_MAX, rocket look", "rocket", 18, 100, 0),
    ("any blast at CRATER_MAX, grenade look", "grenade", 18, 100, 0),
    ("any blast at CRATER_MAX, frag look", "frag", 18, 100, 0),
]


SERVER_LUA = r"""
local DS, mock, base, blasts = ...
-- The ground: `base(x, z)` as the map built it, lowered by every crater's design cone.
local FLOOR_RADIUS, WALL_RUN = mock.floorRadius, DS.WallRun
local cones = {}
local function height(x, z)
    local y = base(x, z)
    for _, c in ipairs(cones) do
        local d = math.sqrt((x - c.x) ^ 2 + (z - c.z) ^ 2)
        y = math.min(y, c.apex + math.max(0, d - FLOOR_RADIUS) / WALL_RUN)
    end
    return y
end
mock.raycast = function(origin, direction)
    if direction.Y < 0 then
        local y = height(origin.X, origin.Z)
        if origin.Y >= y and origin.Y + direction.Y <= y then
            return { Instance = workspace.Terrain, Position = Vector3.new(origin.X, y, origin.Z), Material = Enum.Material.Grass, Normal = Vector3.new(0, 1, 0) }
        end
    elseif direction.Y > 0 then
        local bottom = base(origin.X, origin.Z) - 72
        if origin.Y <= bottom and origin.Y + direction.Y >= bottom then
            return { Instance = workspace.Terrain, Position = Vector3.new(origin.X, bottom, origin.Z), Material = Enum.Material.Grass, Normal = Vector3.new(0, -1, 0) }
        end
    end
    return nil
end
local map = workspace:FindFirstChild("Map")
if not map then
    map = Instance.new("Folder"); map.Name = "Map"; map.Parent = workspace
end
local out = {}
for _, b in ipairs(blasts) do
    mock.advance(1.2)
    local y = height(b.x, b.z)
    local before = #mock.fills
    local ok, why = DS.CraterAt(Vector3.new(b.x, y + 0.5, b.z), b.reach, b.amount, map)
    local row = { x = b.x, z = b.z, y = y, dug = ok == true, why = tostring(why) }
    if ok then
        local cell = 4
        local original = DS.OriginalSurface(math.floor(b.x / cell), math.floor(b.z / cell), y)
        local apex = original - why
        -- The ring fills this crater made: the lowest row it cleared under the middle.
        local stairs = math.huge
        for i = before + 1, #mock.fills do
            local f = mock.fills[i]
            local c, r, half = f[1], f[2], (f[4] or 0) / 2
            if (b.x - c.X) ^ 2 + (b.z - c.Z) ^ 2 < r * r then stairs = math.min(stairs, c.Y - half) end
        end
        row.apex, row.rounding = apex, math.max(0, apex - stairs)
        table.insert(cones, { x = b.x, z = b.z, apex = apex })
    end
    table.insert(out, row)
end
return out
"""


def dig(faults, base_src, blasts):
    """Runs the real CraterAt for `blasts` [(x, z, reach, amount)] in order on ground `base_src` (a Lua
    function body of x, z). Returns one row per blast: surface y before it, dug, apex, rounding."""
    world = dmc.World()
    ds = world.load(dmc.SERVICE, faults, name="DestructibleService")
    src = dmc.read(dmc.SERVICE, faults)
    world.mock.floorRadius = float(re.search(r"local FLOOR_RADIUS, WALL_RUN, STEP_UP = ([\d.]+)", src).group(1))
    base = world.lua.eval("function(x, z) " + base_src + " end")
    table = world.lua.table_from([world.lua.table_from({"x": x, "z": z, "reach": r, "amount": a}) for x, z, r, a in blasts])
    rows = world.run(SERVER_LUA, ds, world.mock, base, table)
    return [dict(row.items()) for row in rows.values()]


CLIENT_LUA = r"""
local mock, FLOOR_RADIUS, WALL_RUN = ...
local fx = mock.fx
-- The ground the client sees: `base` lowered by the craters in `cones`, each its design cone dropped
-- by `c.drop` (0 for the craters already there; the row rounding and Basalt's roughness for the new one).
local world = { base = function() return 0 end, cones = {} }
mock.world = world
local function h(x, z)
    local y = world.base(x, z)
    for _, c in ipairs(world.cones) do
        local d = math.sqrt((x - c.x) ^ 2 + (z - c.z) ^ 2)
        y = math.min(y, c.apex - c.drop + math.max(0, d - FLOOR_RADIUS) / WALL_RUN)
    end
    return y
end
mock.height = h
local function normalAt(x, z)
    local e = 0.05
    local gx, gz = (h(x + e, z) - h(x - e, z)) / (2 * e), (h(x, z + e) - h(x, z - e)) / (2 * e)
    return Vector3.new(-gx, 1, -gz).Unit
end
mock.normalAt = normalAt
-- A ray against that ground, marched 0.05 at a time and bisected to the surface. Like the engine, a ray
-- that starts inside the ground doesn't see it until it has come out and gone back in.
mock.raycast = function(origin, direction)
    local len = direction.Magnitude
    local ox, oy, oz = origin.X, origin.Y, origin.Z
    local dx, dy, dz = direction.X / len, direction.Y / len, direction.Z / len
    local inside = oy <= h(ox, oz)
    local t = 0
    while t < len do
        local nt = math.min(t + 0.05, len)
        local below = oy + dy * nt <= h(ox + dx * nt, oz + dz * nt)
        if below and not inside then
            local a, b = t, nt
            for _ = 1, 24 do
                local m = (a + b) / 2
                if oy + dy * m <= h(ox + dx * m, oz + dz * m) then b = m else a = m end
            end
            local px, pz = ox + dx * b, oz + dz * b
            return { Instance = workspace.Terrain, Position = Vector3.new(px, oy + dy * b, pz), Normal = normalAt(px, pz), Material = Enum.Material.Basalt }
        end
        inside = below
        t = nt
    end
    return nil
end
function workspace.Raycast(_, origin, direction, params) return mock.raycast(origin, direction, params) end

-- One blast at `p` (on the ground as it is), its crater `cone` dug 0.1 s later, the relays run out.
-- Returns the patches drawn, how many there are in all, the deepest one under the blast's plane
-- (along its normal) and the worst gap between a drawn patch and the ground under it.
return function(p, kind, radius, cone)
    fx.Paused = true
    fx.Clear()
    local n = normalAt(p.X, p.Z)
    fx.Explosion(p, n, kind, radius)
    fx.Advance(0.1)
    if cone then table.insert(world.cones, cone) end
    for _ = 1, 60 do fx.Advance(0.1) end
    local drawn, total, deepest, gap = 0, 0, 0, 0
    for _, c in ipairs(fx.Folder():GetChildren()) do
        if c.Name == "Scorch" or c.Name == "ScorchEdge" then
            total = total + 1
            if c.Transparency < 0.99 then
                drawn = drawn + 1
                local at = c.Position
                deepest = math.max(deepest, (p - at):Dot(n))
                gap = math.max(gap, math.abs(at.Y - h(at.X, at.Z)))
            end
        end
    end
    return drawn, total, deepest, gap
end
"""


def load_client(fx_faults=()):
    import scorch_check
    scorch_check.ROOT = scorch_check.Path(ROOT)
    src = open(FX, encoding="utf-8").read()
    for old, new in fx_faults:
        if old not in src:
            raise SystemExit("planted fault did not apply (text not found): %r" % old[:80])
        src = src.replace(old, new, 1)
    lua, mock = scorch_check.load_fx(src)
    return lua, mock, src


def scenarios(reach, amount):
    """(label, ground, blasts): blasts [(x, z, reach, amount)] run in order on one map."""
    out = []
    same = [(1.3, 2.7, reach, amount)] * 8
    # Flat ground at eight heights across a voxel row (the rounding depends on where the apex falls),
    # the same spot until the bowl bottoms out.
    for k in range(8):
        out.append(("flat y%.1f, one spot x8" % (k * 0.5), "return %r" % (k * 0.5), same))
    # The wall of a bottomed-out bowl, and of a one-blast crater.
    wall = [(1.3 + d * math.cos(a), 2.7 + d * math.sin(a), reach, amount)
            for d, a in ((4, 0), (8, 1.6), (14, 3.1), (20, 4.7), (30, 0.8), (45, 2.4))]
    out.append(("bowl wall d4-45", "return 0", same + wall))
    small = [(1.3 + d * math.cos(a), 2.7 + d * math.sin(a), reach, amount) for d, a in ((3, 0), (6, 2.1), (9, 4.2))]
    out.append(("one-crater wall d3-9", "return 0", same[:1] + small))
    # Hillsides, the blast at three places across a 4-stud cell (CraterAt reads the ground as built at
    # the cell's middle), twice on the spot.
    # Up to 45 degrees: the steepest MapTerrain lets a river bank get, and the grade a player walks.
    for deg in (15, 27, 35, 45):
        for x in (0.1, 2.0, 3.9):
            for lift in (0, 1, 2, 3):
                spot = (40 + x, 2.7, reach, amount)
                out.append(("hill %d deg, x %.1f in cell, +%d" % (deg, x, lift),
                            "return %r * x + %d" % (math.tan(math.radians(deg)), lift), [spot, spot]))
    return out


def measure(dig_faults=(), fx_faults=(), with_need=False, quiet=False):
    """E over every source and scenario: (failures, deepest need, rows per source). The need is
    measured in a second ExplosiveFx whose sink can't be the limit (200), when `with_need`."""
    lua, mock, src = load_client(fx_faults)
    world = dmc.World()
    ds = world.load(dmc.SERVICE, dig_faults, name="DestructibleService")
    floor_radius = float(re.search(r"local FLOOR_RADIUS, WALL_RUN, STEP_UP = ([\d.]+)", dmc.read(dmc.SERVICE, dig_faults)).group(1))
    clients = [(lua, mock, lua.execute(CLIENT_LUA, mock, floor_radius, ds.WallRun))]
    if with_need:
        here = FX_SINK.search(src)
        lua2, mock2, _ = load_client(list(fx_faults) + [(here.group(0), "local SCORCH_SINK, SCORCH_LIP = 200, " + here.group(2))])
        clients.append((lua2, mock2, lua2.execute(CLIENT_LUA, mock2, floor_radius, ds.WallRun)))
    fails, need, report = [], 0.0, []
    for name, look, radius, reach, amount in SOURCES:
        size = ds.CraterSize(reach, amount)
        worst, blasts, dug, rounding, drawn_all = 0.0, 0, 0, 0.0, True
        for label, ground, seq in scenarios(reach, amount):
            rows = dig(dig_faults, ground, seq)
            if look is None:
                for row in rows:
                    if row["dug"]:
                        dug += 1
                        worst = max(worst, row["y"] - row["apex"] + row["rounding"] + BASALT_ROUGH)
                        rounding = max(rounding, row["rounding"])
                continue
            for lua_, mock_, _ in clients:
                mock_.world.base = lua_.eval("function(x, z) " + ground + " end")
                mock_.world.cones = lua_.table_from([])
            for row in rows:
                blasts += 1
                if row["dug"]:
                    dug += 1
                    rounding = max(rounding, row["rounding"])
                for index, (lua_, mock_, blast) in enumerate(clients):
                    cone = None
                    if row["dug"]:
                        cone = lua_.table_from({"x": row["x"], "z": row["z"], "apex": row["apex"], "drop": row["rounding"] + BASALT_ROUGH})
                    drawn, total, deepest, gap = blast(lua_.eval("Vector3.new")(row["x"], row["y"], row["z"]), look, radius, cone)
                    if index == 1:
                        worst = max(worst, deepest)
                    elif drawn < total or gap > 0.3:
                        drawn_all = False
                        fails.append("E %s, %s: %d of %d patches drawn, worst gap %.2f (crater %s)"
                                     % (name, label, drawn, total, gap, "%.2f under" % (row["y"] - row["apex"]) if row["dug"] else row["why"]))
                    if cone is not None:
                        cone["drop"] = 0
        if look is not None:
            need = max(need, worst)
        report.append((name, look, size, dug, blasts, rounding, worst, drawn_all))
    if not quiet:
        print("  source                                              look     crater  dug  blasts  rounding  deepest patch")
        for name, look, size, dug, blasts, rounding, worst, drawn_all in report:
            print("  %-50s  %-7s  %5.2f  %4d  %6s  %7.2f  %8.2f%s" % (name, look or "(none)", size, dug,
                  ("%d" % blasts) if look else "-", rounding, worst, "" if look else "  (no scorch drawn; floor depth)"))
    return fails, need, report


def ledge(sink_need, fx_faults=()):
    """F: a ground blast (crater refused) a stud from the edge of a drop DROP_PAST deeper than any crater
    floor. Returns (failures, patches on the lower level, patches drawn up top)."""
    lua, mock, src = load_client(fx_faults)
    blast = lua.execute(CLIENT_LUA, mock, 2.5, 2)
    drop = sink_need + DROP_PAST
    mock.world.base = lua.eval("function(x, z) if x < 0 then return 0 end return -%r end" % drop)
    V = lua.eval("Vector3.new")
    fails, below, up = [], 0, 0
    for look in ("rocket", "grenade", "frag"):
        lua.execute("local fx = ...; fx.Clear()", mock.fx)
        fx = mock.fx
        fx.Paused = True
        fx.Explosion(V(-1, 0, 0), V(0, 1, 0), look, 18)
        for _ in range(60):
            fx.Advance(0.1)
        for part in fx.Folder().GetChildren(fx.Folder()).values():
            if part.Name in ("Scorch", "ScorchEdge") and part.Transparency < 0.99:
                if part.Position.Y < -drop + 0.5:
                    below += 1
                else:
                    up += 1
    if below:
        fails.append("F %d patches landed on the level %.1f below the ledge (deeper than any crater)" % (below, drop))
    if up < 9:
        fails.append("F only %d patches drawn on the ledge itself" % up)
    return fails, below, up, drop


def main():
    plant = "--plant" in sys.argv
    src = open(FX, encoding="utf-8").read()
    sink, lip = (float(v) for v in FX_SINK.search(src).groups())
    print("scorch_sink_check: SCORCH_SINK %.1f, SCORCH_LIP %.1f; BASALT_ROUGH %.1f" % (sink, lip, BASALT_ROUGH))
    fails, need, report = measure(with_need=True)
    print("  deepest patch under its blast's plane, over %d sources that draw a scorch: %.2f (sink %.1f, margin %.2f)" % (
        sum(1 for s in SOURCES if s[1]), need, sink, sink - need))
    examined = sum(r[4] for r in report)
    ok_e = not fails
    print("  %s  E every patch of every scorch lies on its own crater's floor (%d blasts, %d scenarios per source)"
          % ("ok  " if ok_e else "FAIL", examined, len(scenarios(1, 1))))
    for f in fails[:8]:
        print("        " + f)
    if len(fails) > 8:
        print("        ... and %d more" % (len(fails) - 8))
    ffails, below, up, drop = ledge(need)
    ok_f = not ffails
    print("  %s  F a ledge %.1f deep (the deepest floor + %d): %d patches below, %d up top"
          % ("ok  " if ok_f else "FAIL", drop, DROP_PAST, below, up))
    for f in ffails:
        print("        " + f)
    bad = (0 if ok_e else 1) + (0 if ok_f else 1)
    if plant:
        here = FX_SINK.search(src).group(0)
        plants = [
            ("SCORCH_SINK 0.5 under the need", "E", lambda: measure(fx_faults=[(here, "local SCORCH_SINK, SCORCH_LIP = %r, %s" % (round(need - 0.5, 2), lip))], quiet=True)[0]),
            ("craters dug deeper (DEEPEN 0.8 -> 1.2)", "E", lambda: measure(dig_faults=[("local DEEPEN = 0.8", "local DEEPEN = 1.2")], quiet=True)[0]),
            ("SCORCH_SINK = 25 (the handoff's number)", "F", lambda: ledge(need, fx_faults=[(here, "local SCORCH_SINK, SCORCH_LIP = 25, %s" % lip)])[0]),
        ]
        hits = 0
        for label, tag, run in plants:
            got = run()
            caught = any(f.startswith(tag + " ") for f in got)
            hits += 1 if caught else 0
            print("  planted %s: %s (%d failures, first: %s)" % (label, "CAUGHT" if caught else "MISSED", len(got), got[0] if got else "none"))
        print("  planted faults caught: %d of %d" % (hits, len(plants)))
        bad += len(plants) - hits
    print("scorch_sink_check:", "OK" if bad == 0 else "%d problem(s)" % bad)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
