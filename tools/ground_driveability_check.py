"""Is the open ground smooth enough to drive on? (Oliver 09-24: "make the ground more smooth so that
vehicles can drive more smoothly"), measured on whole maps built by the REAL MapGenerator.Build.

    python tools/ground_driveability_check.py                every map in MapData.Order x SEEDS
    python tools/ground_driveability_check.py --quick        two maps x one seed
    python tools/ground_driveability_check.py --plant        the planted faults, each required to fail
    python tools/ground_driveability_check.py --map RotRidge --seed 2

The world is tools/car_placement_map.py's (its mocks, stand-ins and module wiring), with one change:
MapTerrain runs whole and for real -- Relief's voxel write, Plateaus, Hills, RestoreRoadGround,
FlattenPad, the river, PaintPatches -- into VOXELS below, a 4-stud column model of the terrain: per
column the top of the solid fill, the material on top and the water level. FillBall, FillBlock
(oriented), FillCylinder, WriteVoxels, ReadVoxels, ReplaceMaterial and Clear act on it; the harness's
raycasts read it back (fill top + MapTerrain.SurfaceLift, as columnGround does), so everything that
stands on the ground is placed on this ground.

What is measured: the surface at every column centre (a 4-stud grid) inside the map's radius, along
every grid line in X and in Z, leaving out what is not driving ground by design: water, the river's
channel and banks, the ground under the bridges (where a road's ground stands over the terrain),
the plateaus and their ramps, the craters and their pools.

  step        |h1 - h0| between neighbouring samples 4 studs apart: max and 95th percentile
  kink        |h0 - 2 h1 + h2| over three samples (8 studs): the change of slope a wheel feels.
              Reported as max and 99th percentile, and as the share of kinks over BUMP studs
  rough       the share of open ground topped by a rough or stepped material. RoadNetwork's measured
              table (tools/road_terrain_probe.lua) has Rock drawing its surface up to 1.1 off its
              voxels, Basalt 0.7, Ice 0.6, Slate and CrackedLava 0.4, and Pavement / Concrete /
              Cobblestone / Brick / WoodPlanks snapping it to a grid: a washboard under the wheels
              with no change to the voxels at all. The kink figures include it: each rough column is
              displaced by its material's measured amplitude (a fixed hash of the column, so the
              numbers are repeatable).

Planted faults (--plant) re-add each source of bumpiness the smoothing took out; each must fail.
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import car_placement_map as cpm  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402
from lupa import LuaRuntime  # noqa: E402

SEEDS = (1, 2, 3)

# Thresholds. A kink of BUMP studs over 8 is a change of slope of 1/4 across two 4-stud steps: a
# jolt at driving speed. Before the smoothing (2026-09-24) every map failed: 1-4.4% of kinks over
# BUMP (42-45% on Rot Ridge, all Rock), p99 1.05-3.65, worst 12-32 studs. After: see the report.
BUMP = 1.0
LIMITS = {
    "bump_pct": 0.5,      # % of kinks over BUMP studs
    "kink_p99": 0.8,      # studs over 8
    "kink_max": 5.0,      # studs over 8: the single worst kink on open ground
    "step_p95": 2.2,      # studs over 4: a grade of 0.55, the hills' own limit
    "rough_pct": 0.5,     # % of open ground topped by a rough material
}

VOXELS = r"""
local mock = ...

-- Gradient (improved Perlin) noise in place of the harness's value noise: Roblox's math.noise is
-- Perlin, and the value noise's smoothstep lattice has kinks of its own that the real one doesn't.
do
	local perm = {}
	local state = 1234567
	local p = {}
	for i = 0, 255 do p[i] = i end
	for i = 255, 1, -1 do
		state = (state * 1103515245 + 12345) % 2147483648
		local j = state % (i + 1)
		p[i], p[j] = p[j], p[i]
	end
	for i = 0, 511 do perm[i] = p[i % 256] end
	local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
	local function lerp(t, a, b) return a + t * (b - a) end
	local function grad(hash, x, y, z)
		local h = hash % 16
		local u = h < 8 and x or y
		local v = h < 4 and y or ((h == 12 or h == 14) and x or z)
		return ((h % 2 == 0) and u or -u) + ((math.floor(h / 2) % 2 == 0) and v or -v)
	end
	math.noise = function(x, y, z)
		y, z = y or 0, z or 0
		local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
		local X, Y, Z = fx % 256, fy % 256, fz % 256
		x, y, z = x - fx, y - fy, z - fz
		local u, v, w = fade(x), fade(y), fade(z)
		local A, B = perm[X] + Y, perm[X + 1] + Y
		local AA, AB, BA, BB = perm[A] + Z, perm[A + 1] + Z, perm[B] + Z, perm[B + 1] + Z
		return 0.5 * lerp(w, lerp(v, lerp(u, grad(perm[AA], x, y, z), grad(perm[BA], x - 1, y, z)),
			lerp(u, grad(perm[AB], x, y - 1, z), grad(perm[BB], x - 1, y - 1, z))),
			lerp(v, lerp(u, grad(perm[AA + 1], x, y, z - 1), grad(perm[BA + 1], x - 1, y, z - 1)),
				lerp(u, grad(perm[AB + 1], x, y - 1, z - 1), grad(perm[BB + 1], x - 1, y - 1, z - 1))))
	end
end
local terrain = workspace.Terrain
local CELL = 4
local H, M, W, T = {}, {}, {}, {}
VOX = { H = H, M = M, W = W, T = T, tag = "other", craters = {}, lakes = {}, inHills = false }
local function key(ix, iz) return (ix + 20000) * 40000 + (iz + 20000) end
local NONE = -1e9
local AIR, WATER = Enum.Material.Air, Enum.Material.Water
local function get(ix, iz) return H[key(ix, iz)] or NONE end

local function solidSpan(ix, iz, lo, hi, material)
	-- The terrain as a height field of its top surface: fill raises it, air cuts it where it spans it.
	local k = key(ix, iz)
	local h = H[k] or NONE
	if material == AIR then
		if hi >= h and lo < h then H[k] = lo end
		if W[k] and W[k] > lo then W[k] = nil end
	elseif material == WATER then
		if hi >= h and lo < h then H[k] = lo end
		W[k] = math.max(W[k] or NONE, hi)
	else
		if hi > h then H[k] = hi; M[k] = material end
		if W[k] and W[k] <= hi then W[k] = nil end
	end
	if math.abs((H[k] or NONE) - h) > 0.05 then T[k] = VOX.tag end
end

local function columns(x0, z0, x1, z1, fn)
	for ix = math.floor(x0 / CELL), math.ceil(x1 / CELL) - 1 do
		for iz = math.floor(z0 / CELL), math.ceil(z1 / CELL) - 1 do
			fn(ix, iz, (ix + 0.5) * CELL, (iz + 0.5) * CELL)
		end
	end
end

terrain.FillBall = function(_, center, radius, material)
	if VOX.inHills and material == AIR then
		table.insert(VOX.craters, { x = center.X, z = center.Z, r = radius })
	end
	columns(center.X - radius, center.Z - radius, center.X + radius, center.Z + radius, function(ix, iz, x, z)
		local d2 = (x - center.X) ^ 2 + (z - center.Z) ^ 2
		if d2 < radius * radius then
			local s = math.sqrt(radius * radius - d2)
			solidSpan(ix, iz, center.Y - s, center.Y + s, material)
		end
	end)
end

terrain.FillCylinder = function(_, cframe, height, radius, material)
	if material == WATER then
		table.insert(VOX.lakes, { x = cframe.X, z = cframe.Z, r = radius })
	end
	local p = cframe.Position
	columns(p.X - radius, p.Z - radius, p.X + radius, p.Z + radius, function(ix, iz, x, z)
		if (x - p.X) ^ 2 + (z - p.Z) ^ 2 < radius * radius then
			solidSpan(ix, iz, p.Y - height / 2, p.Y + height / 2, material)
		end
	end)
end

terrain.FillBlock = function(_, cframe, size, material)
	local half = size / 2
	local reach = half.Magnitude
	local p = cframe.Position
	local up = cframe:VectorToObjectSpace(Vector3.new(0, 1, 0))
	local hs = { half.X, half.Y, half.Z }
	local ds = { up.X, up.Y, up.Z }
	columns(p.X - reach, p.Z - reach, p.X + reach, p.Z + reach, function(ix, iz, x, z)
		local o = cframe:PointToObjectSpace(Vector3.new(x, 0, z))
		local os_ = { o.X, o.Y, o.Z }
		local tmin, tmax = -math.huge, math.huge
		for a = 1, 3 do
			if math.abs(ds[a]) < 1e-9 then
				if math.abs(os_[a]) > hs[a] then return end
			else
				local t1, t2 = (-hs[a] - os_[a]) / ds[a], (hs[a] - os_[a]) / ds[a]
				if t1 > t2 then t1, t2 = t2, t1 end
				tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
			end
		end
		if tmin < tmax then
			solidSpan(ix, iz, tmin, tmax, material)
		end
	end)
end

local function bounds(region)
	local lo = region.CFrame.Position - region.Size / 2
	return lo, lo + region.Size
end

terrain.Clear = function()
	for k in pairs(H) do H[k] = nil end
	for k in pairs(M) do M[k] = nil end
	for k in pairs(W) do W[k] = nil end
end

terrain.ReplaceMaterial = function(_, region, _, from, to)
	local lo, hi = bounds(region)
	columns(lo.X, lo.Z, hi.X, hi.Z, function(ix, iz)
		local k = key(ix, iz)
		local h = H[k]
		if h and M[k] == from and h >= lo.Y and h <= hi.Y + CELL then M[k] = to end
	end)
end

terrain.WriteVoxels = function(_, region, res, materials, occupancies)
	local lo, hi = bounds(region)
	local nx, ny, nz = math.floor(region.Size.X / res + 0.5), math.floor(region.Size.Y / res + 0.5), math.floor(region.Size.Z / res + 0.5)
	for i = 1, nx do
		local mx, ox = materials[i], occupancies[i]
		for j = 1, nz do
			local ix, iz = math.floor(lo.X / CELL) + i - 1, math.floor(lo.Z / CELL) + j - 1
			local k = key(ix, iz)
			local top, topMaterial, water = nil, nil, nil
			for iy = ny, 1, -1 do
				local m, occ = mx[iy][j], ox[iy][j]
				if occ > 0 and m ~= AIR then
					local s = lo.Y + (iy - 1) * res + occ * res
					if m == WATER then
						water = water or s
					else
						top, topMaterial = s, m
						break
					end
				end
			end
			local h = H[k] or NONE
			local was = h
			if top then
				if top >= hi.Y - 1e-6 then
					if top > h then H[k] = top end
					M[k] = (h > hi.Y) and M[k] or topMaterial
				elseif h <= hi.Y then
					H[k], M[k] = top, topMaterial
				end
			elseif h > lo.Y and h <= hi.Y then
				H[k] = lo.Y
			end
			if math.abs((H[k] or NONE) - was) > 0.05 then T[k] = VOX.tag end
			if water then
				W[k] = water
			elseif W[k] and W[k] >= lo.Y and W[k] <= hi.Y then
				W[k] = nil
			end
		end
	end
end

terrain.ReadVoxels = function(_, region, res)
	local lo, hi = bounds(region)
	local nx, ny, nz = math.floor(region.Size.X / res + 0.5), math.floor(region.Size.Y / res + 0.5), math.floor(region.Size.Z / res + 0.5)
	local materials, occupancies = {}, {}
	for i = 1, nx do
		local mi, oi = {}, {}
		for iy = 1, ny do mi[iy] = {}; oi[iy] = {} end
		for j = 1, nz do
			local ix, iz = math.floor(lo.X / CELL) + i - 1, math.floor(lo.Z / CELL) + j - 1
			local k = key(ix, iz)
			local h, m, w = H[k] or NONE, M[k] or Enum.Material.Ground, W[k]
			for iy = 1, ny do
				local b = lo.Y + (iy - 1) * res
				local occ = (h - b) / res
				if occ > 0 then
					mi[iy][j], oi[iy][j] = m, math.min(1, occ)
				elseif w and w > b then
					mi[iy][j], oi[iy][j] = WATER, math.min(1, (w - b) / res)
				else
					mi[iy][j], oi[iy][j] = AIR, 0
				end
			end
		end
		materials[i], occupancies[i] = mi, oi
	end
	materials.Size = Vector3.new(nx, ny, nz)
	occupancies.Size = materials.Size
	return materials, occupancies
end

-- The ground the harness's raycasts hit: the column surfaces drawn between their centres.
local function lift()
	local MapTerrain = mock.modules.MapTerrain
	return MapTerrain and MapTerrain.SurfaceLift or 2
end
function GROUND(x, z)
	local fx, fz = x / CELL - 0.5, z / CELL - 0.5
	local ix, iz = math.floor(fx), math.floor(fz)
	local tx, tz = fx - ix, fz - iz
	local a, b = get(ix, iz), get(ix + 1, iz)
	local c, d = get(ix, iz + 1), get(ix + 1, iz + 1)
	local h = (a * (1 - tx) + b * tx) * (1 - tz) + (c * (1 - tx) + d * tx) * tz
	if h < -1e6 then return 0 end
	return h + lift()
end
"""

# After the modules exist: note what Hills carves and let the rest run.
HOOKS = r"""
local MapTerrain = require("MapTerrain")
for _, name in ipairs({ "Relief", "Plateaus", "Hills", "RestoreRoadGround", "FlattenPad", "RewritePads", "River",
	"PaintPatch", "PaintPatches" }) do
	local inner = MapTerrain[name]
	MapTerrain[name] = function(...)
		local was = VOX.tag
		VOX.tag = name
		VOX.inHills = name == "Hills"
		local result = table.pack(pcall(inner, ...))
		VOX.tag = was
		VOX.inHills = false
		if not result[1] then error(result[2], 0) end
		return table.unpack(result, 2, result.n)
	end
end
"""

# Sampling, in Lua (the columns live there). Rough materials: RoadNetwork's measured amplitudes.
SAMPLE = r"""
local result, BUMP = ...
local MapTerrain = require("MapTerrain")
local CELL = 4
local H, M, W = VOX.H, VOX.M, VOX.W
local radius = result.radius
local river = result.river
local lift = MapTerrain.SurfaceLift or 2
local ROUGH = { Rock = 1.1, Basalt = 0.7, Ice = 0.6, Slate = 0.4, CrackedLava = 0.4 }
local SNAP = { Pavement = 1, Concrete = 2, Cobblestone = 0.5, Brick = 4, WoodPlanks = 4 }
local function hash(ix, iz)
	local h = ((ix * 73856093) ~ (iz * 19349663)) % 1000003
	return (h / 1000003) * 2 - 1
end
local masks = {}
for _, p in ipairs(result.plateaus or {}) do
	table.insert(masks, { x = p.X, z = p.Z, r = p.radius + 80 })
end
for _, c in ipairs(VOX.craters) do table.insert(masks, { x = c.x, z = c.z, r = c.r * 1.45 }) end
for _, l in ipairs(VOX.lakes) do table.insert(masks, { x = l.x, z = l.z, r = l.r + 12 }) end
local function key(ix, iz) return (ix + 20000) * 40000 + (iz + 20000) end
local n = math.ceil(radius / CELL)
local surf, roughCount, openCount = {}, 0, 0
local roughBy = {}
for ix = -n, n do
	for iz = -n, n do
		local x, z = (ix + 0.5) * CELL, (iz + 0.5) * CELL
		if x * x + z * z <= radius * radius then
			local k = key(ix, iz)
			local h = H[k]
			local ok = h ~= nil and not (W[k] and W[k] >= h - 0.01)
			if ok and river and MapTerrain.InRiver(river, x, z, 12) then ok = false end
			-- Under a bridge: the road's ground stands over the terrain there (the gorge the river
			-- keeps clear under the deck); wheels are on the deck, not down here.
			local roads = MapTerrain._padRoads
			if ok and roads then
				local road = roads:GroundAt(x, z, h + lift)
				if road and road - (h + lift) > 1 then ok = false end
			end
			if ok then
				for _, m in ipairs(masks) do
					if (x - m.x) ^ 2 + (z - m.z) ^ 2 < m.r * m.r then ok = false; break end
				end
			end
			if ok then
				local y = h + lift
				local name = M[k] and M[k].Name or "Ground"
				openCount = openCount + 1
				if ROUGH[name] then
					y = y + ROUGH[name] * hash(ix, iz)
				elseif SNAP[name] then
					local s = SNAP[name]
					y = math.floor(y / s + 0.5) * s
				end
				if ROUGH[name] or SNAP[name] then
					roughCount = roughCount + 1
					roughBy[name] = (roughBy[name] or 0) + 1
				end
				surf[k] = y
			end
		end
	end
end
local steps, kinks = {}, {}
local worstKink, worstAt = 0, ""
local byTag = {}
for ix = -n, n do
	for iz = -n, n do
		local a = surf[key(ix, iz)]
		if a then
			for _, d in ipairs({ { 1, 0 }, { 0, 1 } }) do
				local b = surf[key(ix + d[1], iz + d[2])]
				if b then
					table.insert(steps, math.abs(b - a))
					local c = surf[key(ix + 2 * d[1], iz + 2 * d[2])]
					if c then
						local k2 = math.abs(a - 2 * b + c)
						table.insert(kinks, k2)
						if k2 > BUMP then
							local t = VOX.T[key(ix + d[1], iz + d[2])] or "?"
							byTag[t] = (byTag[t] or 0) + 1
						end
						if k2 > worstKink then
							worstKink = k2
							worstAt = string.format("(%d, %d) %s", math.floor((ix + d[1] + 0.5) * CELL), math.floor((iz + d[2] + 0.5) * CELL),
								tostring(M[key(ix + d[1], iz + d[2])] and M[key(ix + d[1], iz + d[2])].Name))
						end
					end
				end
			end
		end
	end
end
local parts = {}
for name, count in pairs(roughBy) do table.insert(parts, name .. "=" .. count) end
table.sort(parts)
local tags = {}
for name, count in pairs(byTag) do table.insert(tags, name .. "=" .. count) end
table.sort(tags)
return table.concat(steps, ","), table.concat(kinks, ","), openCount, roughCount, worstAt, table.concat(parts, " "), table.concat(tags, " ")
"""


def build(map_id, seed, faults=None):
    faults = faults or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(cpm.TOOLS, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name in cpm.REAL_MODULES + cpm.REAL_SHARED:
        src = cpm.apply(cpm.source_of(name), faults.get(name), name)
        if name == "MapDecor":
            src = cpm.apply(src, cpm.DECOR_PROBE, name)
        sources[name] = luau_to_lua(src)
    lua.globals().VEHICLE_SOURCE = luau_to_lua(cpm.vehicle_source(faults.get("VehicleService")))
    standins = lua.execute(cpm.STANDINS)
    lua.execute(cpm.WORLD, mock, lua.table_from(sources), standins)
    lua.execute(VOXELS, mock)
    lua.execute("math.randomseed(...)", seed)
    lua.execute(HOOKS)
    result = lua.eval("function(mapId) return require('MapGenerator').Build(mapId) end")(map_id)
    steps, kinks, open_count, rough_count, worst_at, rough_by, by_tag = lua.execute(SAMPLE, result, BUMP)
    steps = sorted(float(v) for v in steps.split(",") if v)
    kinks = sorted(float(v) for v in kinks.split(",") if v)
    r = measure(steps, kinks, open_count, rough_count, worst_at, rough_by)
    r["bumps_by"] = by_tag
    return r


def pct(values, q):
    if not values:
        return 0.0
    return values[min(len(values) - 1, int(q * len(values)))]


def measure(steps, kinks, open_count, rough_count, worst_at, rough_by):
    over = sum(1 for k in kinks if k > BUMP)
    return {
        "samples": open_count,
        "segments": len(steps),
        "step_max": steps[-1] if steps else 0.0,
        "step_p95": pct(steps, 0.95),
        "kink_max": kinks[-1] if kinks else 0.0,
        "kink_p99": pct(kinks, 0.99),
        "bump_pct": 100.0 * over / max(1, len(kinks)),
        "rough_pct": 100.0 * rough_count / max(1, open_count),
        "worst_at": worst_at,
        "rough_by": rough_by,
    }


def faults_of(r):
    return [k for k, limit in LIMITS.items() if r[k] > limit]


def run_one(args):
    map_id, seed, faults = args
    return map_id, seed, build(map_id, seed, faults)


def run_many(jobs):
    if len(jobs) == 1 or os.environ.get("GROUND_SERIAL"):
        return [run_one(j) for j in jobs]
    import multiprocessing
    with multiprocessing.Pool(min(len(jobs), max(1, (os.cpu_count() or 2)))) as pool:
        return pool.map(run_one, jobs)


def line(map_id, seed, r):
    return ("%-14s seed %d  %6d samples  step max %5.2f p95 %4.2f | kink max %5.2f p99 %4.2f | bumps >%.1f: %5.2f%% |"
            " rough %5.2f%% %s| worst kink at %s  %s" % (
                map_id, seed, r["samples"], r["step_max"], r["step_p95"], r["kink_max"], r["kink_p99"], BUMP,
                r["bump_pct"], r["rough_pct"], ("(" + r["rough_by"] + ") ") if r["rough_by"] else "", r["worst_at"] + ("  bumps by writer: " + r["bumps_by"] if r["bumps_by"] else ""),
                ("FAIL " + ",".join(faults_of(r))) if faults_of(r) else "ok"))


# Planted faults: each re-adds one source of high-frequency bumpiness.
PLANTS = [
    ("a 12-stud octave back in the relief", "bump_pct",
     {"MapTerrain": [("\tlocal fine = math.noise(x / 65, z / 65, seed + 41) * 2\n",
                      "\tlocal fine = math.noise(x / 65, z / 65, seed + 41) * 2 + math.noise(x / 12, z / 12, seed + 91) * 1.5\n")]}),
    ("per-voxel jitter in the relief write", "bump_pct",
     {"MapTerrain": [("rowTargets[iz] = height - MapTerrain.SurfaceLift\n",
                      "rowTargets[iz] = height - MapTerrain.SurfaceLift + (math.random() - 0.5) * 1.6\n")]}),
    ("hills back to the old voxel balls' caps", "kink_max",
     {"MapTerrain": [("local HILL_MAX_SLOPE = 0.55\nlocal HILL_MAX_BEND = 0.012\n",
                      "local HILL_MAX_SLOPE = 3\nlocal HILL_MAX_BEND = 1\n"),
                     ("\t\t\theight += shape.height * 0.5 * (1 + math.cos(math.pi * math.sqrt(t2)))\n",
                      "\t\t\tlocal a = shape.along\n\t\t\tlocal rs = (a * a + shape.height ^ 2) / (2 * shape.height)\n"
                      "\t\t\theight += math.sqrt(rs * rs - t2 * a * a) - (rs - shape.height)\n")]}),
    ("the river's bank turning its grade at a line", "kink_max",
     {"MapTerrain": [("local RIVER_BANK_EASE = 16 ", "local RIVER_BANK_EASE = 0.01 "),
                     ("local RIVER_BANK_ROUND = 24 ", "local RIVER_BANK_ROUND = 0 ")]}),
    ("the ground painted Rock", "rough_pct",
     {"MapTerrain": [("\tlocal material = preset.terrainMaterial\n\n\t-- Flat out to `inner`",
                      "\tlocal material = Enum.Material.Rock\n\n\t-- Flat out to `inner`")]}),
]
PLANT_RUNS = [("TralalaTown", 1), ("SahurSprings", 1)]


def main(argv):
    if "--plant" in argv:
        # Every plant must still apply to today's source; checked here, because a SystemExit in a
        # pool worker hangs the pool.
        for _, _, faults in PLANTS:
            for module, pairs in faults.items():
                cpm.apply(cpm.source_of(module), pairs, module)
        clean = run_many([(m, s, None) for m, s in PLANT_RUNS])
        for m, s, r in clean:
            print("clean  " + line(m, s, r))
        jobs = [(m, s, faults) for _, _, faults in PLANTS for m, s in PLANT_RUNS]
        results = run_many(jobs)
        missed = 0
        for k, (name, rule, _) in enumerate(PLANTS):
            got = results[k * len(PLANT_RUNS):(k + 1) * len(PLANT_RUNS)]
            caught = all(rule in faults_of(r) for _, _, r in got)
            missed += 0 if caught else 1
            print("  plant %-44s %-10s %s (%s)" % (name, rule, "CAUGHT" if caught else "MISSED",
                                                  ", ".join("%.2f" % r[rule] for _, _, r in got)))
        print("planted faults caught: %d of %d" % (len(PLANTS) - missed, len(PLANTS)))
        clean_bad = sum(len(faults_of(r)) for _, _, r in clean)
        return 1 if missed or clean_bad else 0
    maps = cpm.map_ids()
    seeds = SEEDS
    if "--quick" in argv:
        maps, seeds = ["TralalaTown", "RotRidge"], (1,)
    if "--map" in argv:
        maps = [argv[argv.index("--map") + 1]]
    if "--seed" in argv:
        seeds = (int(argv[argv.index("--seed") + 1]),)
    results = run_many([(m, s, None) for m in maps for s in seeds])
    failed = 0
    for m, s, r in results:
        print(line(m, s, r))
        failed += 1 if faults_of(r) else 0
    print("limits: " + ", ".join("%s <= %s" % kv for kv in LIMITS.items()) + "; bump = kink over %.1f studs per 8" % BUMP)
    print("maps failing: %d of %d" % (failed, len(results)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
