-- The world under tools/foundation_check.py: a whole map built by the REAL MapGenerator.Build
-- under LuaJIT (lupa), on a voxel terrain that behaves the way the map code was measured to
-- behave in Studio. Loaded AFTER tools/destruct_mocks.lua (its Vector3 / CFrame / Instance tree),
-- with that file's `mock` passed in; this adds what a map build needs on top:
--
--   Terrain   a real 4-stud voxel grid (LuaJIT FFI arrays: occupancy + material per voxel) with
--             ReadVoxels / WriteVoxels / Fill{Block,Cylinder,Ball,Wedge} / ReplaceMaterial / Clear.
--             The contracts it follows are the MEASURED ones in COORDINATION.md "Measured lessons":
--               * a column's ground is its top solid voxel's bottom + occupancy * 4 + SurfaceLift (2),
--                 the formula every writer in MapTerrain uses (columnGround);
--               * WriteVoxels is continuous (fractional occupancy lands where it is written);
--               * Fill* writes whole voxels: a voxel more than half inside the shape (along its own
--                 vertical centre line) becomes full, so "fill to 2.08 -> ground 6.00" and "fill to
--                 -1.00 -> ground 2.00"; a voxel touched but at most half inside keeps its occupancy
--                 and only takes the material (a repaint, which is how the towns' pavement paint
--                 behaves in the game);
--               * water sits at its fill top (the river reads -1.00 exactly), and is not ground.
--   Raycast   straight-down rays against the terrain (IgnoreWater honoured), answering from the
--             rendered surface: column tops blended bilinearly between column centres, which is
--             how smooth terrain draws a surface through neighbouring columns. Every ray the map
--             code casts is straight down; any other ray errors, so nothing silently misses.
--   math.noise  Ken Perlin's improved noise, so the relief has real slopes to put things on.
--             (Roblox's own math.noise is not published; the SHAPE of the ground is realistic, but
--             a seed here is not the same map as that seed in Studio.)
--   Region3, BulkMoveTo, WorldPivot, a require() over the real module files.

local mock = ...
local ffi = require("ffi")

table.unpack = table.unpack or unpack
-- Luau's table.clone keeps the metatable (a cloned palette's Color3s stay Color3s).
table.clone = function(t)
	local copy = {}
	for k, v in pairs(t) do
		copy[k] = v
	end
	return setmetatable(copy, getmetatable(t))
end
do
	local new = Color3.new
	Color3.new = function(r, g, b) return new(r or 0, g or 0, b or 0) end
end
table.pack = table.pack or function(...) return { n = select("#", ...), ... } end
table.create = table.create or function(n, v)
	local t = {}
	if v ~= nil then
		for i = 1, n do
			t[i] = v
		end
	end
	return t
end
string.format = (function(format)
	-- Luau's %d accepts a float; so does LuaJIT, but only if it is integral in 5.3+. Harmless here.
	return format
end)(string.format)

-- Vector2, whole (destruct_mocks has only a constructor) ----------------------------------------
do
	local V2 = {}
	local function v2(x, y) return setmetatable({ X = x or 0, Y = y or 0, __type = "Vector2" }, V2) end
	V2.__index = function(v, key)
		if key == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y) end
		if key == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y); return v2(v.X / m, v.Y / m) end
		return V2[key]
	end
	V2.__add = function(a, b) return v2(a.X + b.X, a.Y + b.Y) end
	V2.__sub = function(a, b) return v2(a.X - b.X, a.Y - b.Y) end
	V2.__unm = function(a) return v2(-a.X, -a.Y) end
	V2.__mul = function(a, b)
		if type(a) == "number" then return v2(a * b.X, a * b.Y) end
		if type(b) == "number" then return v2(a.X * b, a.Y * b) end
		return v2(a.X * b.X, a.Y * b.Y)
	end
	V2.__div = function(a, b) return v2(a.X / b, a.Y / b) end
	V2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
	function V2.Dot(a, b) return a.X * b.X + a.Y * b.Y end
	function V2.Cross(a, b) return a.X * b.Y - a.Y * b.X end
	function V2.Lerp(a, b, t) return a + (b - a) * t end
	Vector2 = { new = v2, zero = v2(0, 0), one = v2(1, 1), xAxis = v2(1, 0), yAxis = v2(0, 1) }
end

-- Perlin improved noise ----------------------------------------------------------------------
do
	local p = {}
	local perm = { 151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142, 8, 99, 37, 240,
		21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117, 35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87,
		174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230,
		220, 105, 92, 41, 55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200,
		196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38, 147, 118, 126, 255,
		82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153,
		101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34,
		242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84,
		204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156,
		180 }
	for i = 0, 255 do
		p[i] = perm[i + 1]
		p[i + 256] = perm[i + 1]
	end
	local function fade(t) return t * t * t * (t * (t * 6 - 15) + 10) end
	local function lerp(t, a, b) return a + t * (b - a) end
	local function grad(hash, x, y, z)
		local h = hash % 16
		local u = h < 8 and x or y
		local v = h < 4 and y or ((h == 12 or h == 14) and x or z)
		return ((h % 2) == 0 and u or -u) + ((math.floor(h / 2) % 2) == 0 and v or -v)
	end
	math.noise = function(x, y, z)
		x, y, z = x or 0, y or 0, z or 0
		local X, Y, Z = math.floor(x) % 256, math.floor(y) % 256, math.floor(z) % 256
		x, y, z = x - math.floor(x), y - math.floor(y), z - math.floor(z)
		local u, v, w = fade(x), fade(y), fade(z)
		local A = p[X] + Y
		local AA, AB = p[A] + Z, p[A + 1] + Z
		local B = p[X + 1] + Y
		local BA, BB = p[B] + Z, p[B + 1] + Z
		local n = lerp(w, lerp(v, lerp(u, grad(p[AA], x, y, z), grad(p[BA], x - 1, y, z)),
			lerp(u, grad(p[AB], x, y - 1, z), grad(p[BB], x - 1, y - 1, z))),
			lerp(v, lerp(u, grad(p[AA + 1], x, y, z - 1), grad(p[BA + 1], x - 1, y, z - 1)),
				lerp(u, grad(p[AB + 1], x, y - 1, z - 1), grad(p[BB + 1], x - 1, y - 1, z - 1))))
		-- Roblox documents math.noise as roughly -0.5..0.5 in practice; improved noise spans about
		-- twice that, so it is halved to keep MapTerrain's amplitudes meaning what they say.
		return n * 0.5
	end
end

-- Voxel terrain -------------------------------------------------------------------------------
local VOX = 4
local LIFT = 2
local IX0, NX = -440, 880 -- x from -1760 to 1760
local IZ0, NZ = -440, 880
local IY0, NY = -26, 80 -- y from -104 to 216
local N = NX * NZ * NY
local occ = ffi.new("float[?]", N)
local mat = ffi.new("uint8_t[?]", N)

local MATERIALS, CODE = { [0] = Enum.Material.Air, [1] = Enum.Material.Water }, {}
CODE[Enum.Material.Air] = 0
CODE[Enum.Material.Water] = 1
local function code(material)
	local c = CODE[material]
	if not c then
		c = #MATERIALS + 1
		MATERIALS[c] = material
		CODE[material] = c
	end
	return c
end
local AIR, WATER = 0, 1

local function index(ix, iy, iz)
	return ((ix - IX0) * NZ + (iz - IZ0)) * NY + (iy - IY0)
end
local function inside(ix, iy, iz)
	return ix >= IX0 and ix < IX0 + NX and iz >= IZ0 and iz < IZ0 + NZ and iy >= IY0 and iy < IY0 + NY
end

local T = {}
mock.terrain = T
T.VOX, T.LIFT = VOX, LIFT

function T.clear()
	ffi.fill(occ, ffi.sizeof("float") * N, 0)
	ffi.fill(mat, N, 0)
end

-- Ground at one column: top solid voxel -> surface; and the water surface above it, if any.
function T.column(ix, iz)
	if ix < IX0 or ix >= IX0 + NX or iz < IZ0 or iz >= IZ0 + NZ then
		return nil, nil
	end
	local base = ((ix - IX0) * NZ + (iz - IZ0)) * NY
	local water = nil
	for j = NY - 1, 0, -1 do
		local m = mat[base + j]
		local o = occ[base + j]
		if o > 0 and m ~= AIR then
			local bottom = (j + IY0) * VOX
			if m == WATER then
				water = water or (bottom + o * VOX)
			else
				local solid = bottom + o * VOX + LIFT
				if water and water <= solid then
					water = nil
				end
				return solid, water, MATERIALS[m]
			end
		end
	end
	return nil, water
end

local function colCoord(x)
	-- Column centres are at 4i + 2.
	local f = (x - VOX / 2) / VOX
	local i = math.floor(f)
	return i, f - i
end

-- The rendered surface at (x, z): solid ground and water surface, blended between column centres.
function T.surface(x, z, ignoreWater)
	local i, fx = colCoord(x)
	local k, fz = colCoord(z)
	local s00, w00, m00 = T.column(i, k)
	local s10, w10 = T.column(i + 1, k)
	local s01, w01 = T.column(i, k + 1)
	local s11, w11 = T.column(i + 1, k + 1)
	if not (s00 and s10 and s01 and s11) then
		-- Off the edge of the world: the nearest column, if it has ground.
		local ni, nk = math.floor(x / VOX), math.floor(z / VOX)
		local s, w, m = T.column(ni, nk)
		if not s then
			return nil
		end
		if not ignoreWater and w then
			return w, Enum.Material.Water
		end
		return s, m
	end
	local solid = (s00 * (1 - fx) + s10 * fx) * (1 - fz) + (s01 * (1 - fx) + s11 * fx) * fz
	-- The material under the point: its own column's.
	local ni, nk = math.floor(x / VOX), math.floor(z / VOX)
	local ms, mw, mm = T.column(ni, nk)
	if not ignoreWater and mw then
		return mw, Enum.Material.Water, solid
	end
	return solid, mm or m00, solid
end

function T.get(ix, iy, iz)
	if not inside(ix, iy, iz) then
		return AIR, 0
	end
	local n = index(ix, iy, iz)
	return mat[n], occ[n]
end

-- Fill a shape: `span(x, z)` gives the shape's vertical extent along the column's centre line,
-- or nil. Voxels more than half covered become full; less-covered ones take the material only.
local function fillShape(minX, maxX, minZ, maxZ, minY, maxY, span, material)
	local c = code(material)
	for ix = math.floor(minX / VOX), math.ceil(maxX / VOX) - 1 do
		local x = ix * VOX + VOX / 2
		for iz = math.floor(minZ / VOX), math.ceil(maxZ / VOX) - 1 do
			local z = iz * VOX + VOX / 2
			local lo, hi = span(x, z)
			if lo and hi > lo and ix >= IX0 and ix < IX0 + NX and iz >= IZ0 and iz < IZ0 + NZ then
				local base = ((ix - IX0) * NZ + (iz - IZ0)) * NY
				for iy = math.max(IY0, math.floor(lo / VOX)), math.min(IY0 + NY - 1, math.ceil(hi / VOX) - 1) do
					local bottom = iy * VOX
					local cover = (math.min(hi, bottom + VOX) - math.max(lo, bottom)) / VOX
					if cover > 0 then
						local n = base + (iy - IY0)
						if c == AIR then
							if cover > 0.5 then
								occ[n], mat[n] = 0, AIR
							end
						elseif c == WATER then
							if mat[n] == AIR or mat[n] == WATER or cover > 0.5 then
								-- Water sits at its fill top.
								local top = math.min(hi, bottom + VOX)
								occ[n], mat[n] = math.max(0, (top - bottom) / VOX), WATER
								if mat[n] == WATER and occ[n] <= 0 then
									mat[n] = AIR
								end
							end
						else
							if cover > 0.5 then
								occ[n], mat[n] = 1, c
							elseif occ[n] > 0 and mat[n] ~= WATER then
								mat[n] = c
							end
						end
					end
				end
			end
		end
	end
end

-- Interval of t where |a + b t| <= h (b may be 0).
local function slab(a, b, h, lo, hi)
	if math.abs(b) < 1e-9 then
		if math.abs(a) > h then
			return nil
		end
		return lo, hi
	end
	local t1, t2 = (-h - a) / b, (h - a) / b
	if t1 > t2 then
		t1, t2 = t2, t1
	end
	lo, hi = math.max(lo, t1), math.min(hi, t2)
	if lo >= hi then
		return nil
	end
	return lo, hi
end

local function boxReach(cf, size)
	local r, u, b = cf.r, cf.u, cf.b
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local ex = math.abs(r.X) * hx + math.abs(u.X) * hy + math.abs(b.X) * hz
	local ey = math.abs(r.Y) * hx + math.abs(u.Y) * hy + math.abs(b.Y) * hz
	local ez = math.abs(r.Z) * hx + math.abs(u.Z) * hy + math.abs(b.Z) * hz
	local p = cf.p
	return p.X - ex, p.X + ex, p.Z - ez, p.Z + ez, p.Y - ey, p.Y + ey
end

function T.fillBlock(cf, size, material)
	local r, u, b, p = cf.r, cf.u, cf.b, cf.p
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local x0, x1, z0, z1, y0, y1 = boxReach(cf, size)
	fillShape(x0, x1, z0, z1, y0, y1, function(x, z)
		-- local coordinate along each axis: dot(axis, (x, t, z) - p) = a + b t
		local dx, dz = x - p.X, z - p.Z
		local lo, hi = y0 - 1, y1 + 1
		lo, hi = slab(r.X * dx + r.Z * dz - r.Y * p.Y, r.Y, hx, lo, hi)
		if not lo then return nil end
		lo, hi = slab(u.X * dx + u.Z * dz - u.Y * p.Y, u.Y, hy, lo, hi)
		if not lo then return nil end
		lo, hi = slab(b.X * dx + b.Z * dz - b.Y * p.Y, b.Y, hz, lo, hi)
		return lo, hi
	end, material)
end

function T.fillCylinder(cf, height, radius, material)
	local r, u, b, p = cf.r, cf.u, cf.b, cf.p
	local x0, x1, z0, z1, y0, y1 = boxReach(cf, Vector3.new(radius * 2, height, radius * 2))
	fillShape(x0, x1, z0, z1, y0, y1, function(x, z)
		local dx, dz = x - p.X, z - p.Z
		local lo, hi = slab(u.X * dx + u.Z * dz - u.Y * p.Y, u.Y, height / 2, y0 - 1, y1 + 1)
		if not lo then return nil end
		-- radial: (ar + br t)^2 + (ab + bb t)^2 <= radius^2
		local ar, br = r.X * dx + r.Z * dz - r.Y * p.Y, r.Y
		local ab, bb = b.X * dx + b.Z * dz - b.Y * p.Y, b.Y
		local A = br * br + bb * bb
		local B = 2 * (ar * br + ab * bb)
		local C = ar * ar + ab * ab - radius * radius
		if A < 1e-9 then
			if C > 0 then return nil end
			return lo, hi
		end
		local disc = B * B - 4 * A * C
		if disc < 0 then return nil end
		local s = math.sqrt(disc)
		local t1, t2 = (-B - s) / (2 * A), (-B + s) / (2 * A)
		lo, hi = math.max(lo, t1), math.min(hi, t2)
		if lo >= hi then return nil end
		return lo, hi
	end, material)
end

function T.fillBall(centre, radius, material)
	fillShape(centre.X - radius, centre.X + radius, centre.Z - radius, centre.Z + radius, centre.Y - radius, centre.Y + radius,
		function(x, z)
			local d2 = radius * radius - (x - centre.X) ^ 2 - (z - centre.Z) ^ 2
			if d2 <= 0 then return nil end
			local h = math.sqrt(d2)
			return centre.Y - h, centre.Y + h
		end, material)
end

local function regionBounds(region)
	local c, s = region.CFrame.Position, region.Size
	local x0, y0, z0 = c.X - s.X / 2, c.Y - s.Y / 2, c.Z - s.Z / 2
	return math.floor(x0 / VOX + 0.5), math.floor(y0 / VOX + 0.5), math.floor(z0 / VOX + 0.5),
		math.floor(s.X / VOX + 0.5), math.floor(s.Y / VOX + 0.5), math.floor(s.Z / VOX + 0.5)
end

T.reads, T.writes = 0, 0
function T.readVoxels(region)
	T.reads = T.reads + 1
	local ix0, iy0, iz0, nx, ny, nz = regionBounds(region)
	local materials, occupancies = {}, {}
	for a = 1, nx do
		local mx, ox = {}, {}
		for b = 1, ny do
			local my, oy = {}, {}
			for c = 1, nz do
				local ix, iy, iz = ix0 + a - 1, iy0 + b - 1, iz0 + c - 1
				if inside(ix, iy, iz) then
					local n = index(ix, iy, iz)
					my[c], oy[c] = MATERIALS[mat[n]], occ[n]
				elseif iy < IY0 and ix >= IX0 and ix < IX0 + NX and iz >= IZ0 and iz < IZ0 + NZ then
					-- Below the modelled band: whatever the lowest voxel is (the deep slab).
					local n = index(ix, IY0, iz)
					my[c], oy[c] = MATERIALS[mat[n]], occ[n]
				else
					my[c], oy[c] = Enum.Material.Air, 0
				end
			end
			mx[b], ox[b] = my, oy
		end
		materials[a], occupancies[a] = mx, ox
	end
	materials.Size = Vector3.new(nx, ny, nz)
	occupancies.Size = materials.Size
	return materials, occupancies
end

function T.writeVoxels(region, materials, occupancies)
	T.writes = T.writes + 1
	local ix0, iy0, iz0, nx, ny, nz = regionBounds(region)
	for a = 1, nx do
		for b = 1, ny do
			for c = 1, nz do
				local ix, iy, iz = ix0 + a - 1, iy0 + b - 1, iz0 + c - 1
				if inside(ix, iy, iz) then
					local n = index(ix, iy, iz)
					local m = materials[a][b][c]
					local o = occupancies[a][b][c]
					if m == Enum.Material.Air or o <= 0 then
						occ[n], mat[n] = 0, AIR
					else
						occ[n], mat[n] = math.min(1, o), code(m)
					end
				end
			end
		end
	end
end

function T.replaceMaterial(region, from, to)
	local ix0, iy0, iz0, nx, ny, nz = regionBounds(region)
	local cf, ct = code(from), code(to)
	for a = 0, nx - 1 do
		for c = 0, nz - 1 do
			for b = 0, ny - 1 do
				local ix, iy, iz = ix0 + a, iy0 + b, iz0 + c
				if inside(ix, iy, iz) then
					local n = index(ix, iy, iz)
					if mat[n] == cf then
						mat[n] = ct
					end
				end
			end
		end
	end
end

-- Region3 --------------------------------------------------------------------------------------
local R3 = {}
R3.__index = R3
function R3.ExpandToGrid(region, res)
	local c, s = region.CFrame.Position, region.Size
	local lo = Vector3.new(math.floor((c.X - s.X / 2) / res) * res, math.floor((c.Y - s.Y / 2) / res) * res, math.floor((c.Z - s.Z / 2) / res) * res)
	local hi = Vector3.new(math.ceil((c.X + s.X / 2) / res) * res, math.ceil((c.Y + s.Y / 2) / res) * res, math.ceil((c.Z + s.Z / 2) / res) * res)
	return Region3.new(lo, hi)
end
Region3 = { new = function(lo, hi)
	return setmetatable({ CFrame = CFrame.new((lo + hi) / 2), Size = hi - lo, __type = "Region3" }, R3)
end }

-- CFrame extras the map code uses.
do
	local C = getmetatable(CFrame.new())
	local function orientation(c)
		local rx = math.asin(math.max(-1, math.min(1, -c.b.Y)))
		local ry = math.atan2(c.b.X, c.b.Z)
		local rz = math.atan2(c.r.Y, c.u.Y)
		return rx, ry, rz
	end
	C.ToOrientation = orientation
	C.ToEulerAnglesYXZ = orientation
	function C.Lerp(a, b, t)
		-- Positions interpolate; rotation snaps at the halfway point (nothing here lerps rotations).
		local p = a.p + (b.p - a.p) * t
		local src = t < 0.5 and a or b
		return CFrame.fromMatrix(p, src.r, src.u, src.b)
	end
	CFrame.fromOrientation = function(rx, ry, rz)
		return CFrame.Angles(0, ry, 0) * CFrame.Angles(rx, 0, 0) * CFrame.Angles(0, 0, rz)
	end
	CFrame.fromEulerAnglesYXZ = CFrame.fromOrientation
end

-- Instance events: a signal per instance per event name, made on first touch.
do
	local I = getmetatable(workspace)
	local EVENTS = { Triggered = true, Touched = true, TouchEnded = true, PromptShown = true, PromptHidden = true,
		ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true, AncestryChanged = true,
		Changed = true, TriggerEnded = true, MouseClick = true, OnServerEvent = true, OnClientEvent = true, Event = true }
	local base = I.__index
	I.__index = function(inst, key)
		if EVENTS[key] then
			local signals = rawget(inst, "__signals")
			if not signals then
				signals = {}
				rawset(inst, "__signals", signals)
			end
			signals[key] = signals[key] or mock.signal()
			return signals[key]
		end
		return base(inst, key)
	end
	function I.GetPivot(inst)
		local pivot = rawget(inst, "__props").WorldPivot
		if pivot then return pivot end
		if inst:IsA("BasePart") then return inst.CFrame end
		local primary = rawget(inst, "__props").PrimaryPart
		if primary then return primary.CFrame end
		local cf = inst:GetBoundingBox()
		return cf
	end
	function I.GetFullName(inst)
		local names, node = {}, inst
		while node and node ~= workspace do
			table.insert(names, 1, node.Name)
			node = node.Parent
		end
		return (node == workspace and "Workspace." or "") .. table.concat(names, ".")
	end
	function I.PivotTo(inst, cf)
		if inst:IsA("BasePart") then
			inst.CFrame = cf
			return
		end
		local from = inst:GetPivot()
		local move = cf * from:Inverse()
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				d.CFrame = move * d.CFrame
			end
		end
		rawget(inst, "__props").WorldPivot = cf
	end
	-- World-axis box round every part, rotation included (destruct_mocks' ignores rotation).
	function I.GetBoundingBox(model)
		local lx, ly, lz, hx, hy, hz = math.huge, math.huge, math.huge, -math.huge, -math.huge, -math.huge
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				local cf, s = d.CFrame, d.Size
				local r, u, b, p = cf.r, cf.u, cf.b, cf.p
				local ex = math.abs(r.X) * s.X / 2 + math.abs(u.X) * s.Y / 2 + math.abs(b.X) * s.Z / 2
				local ey = math.abs(r.Y) * s.X / 2 + math.abs(u.Y) * s.Y / 2 + math.abs(b.Y) * s.Z / 2
				local ez = math.abs(r.Z) * s.X / 2 + math.abs(u.Z) * s.Y / 2 + math.abs(b.Z) * s.Z / 2
				lx, hx = math.min(lx, p.X - ex), math.max(hx, p.X + ex)
				ly, hy = math.min(ly, p.Y - ey), math.max(hy, p.Y + ey)
				lz, hz = math.min(lz, p.Z - ez), math.max(hz, p.Z + ez)
			end
		end
		if lx == math.huge then return CFrame.new(), Vector3.new(0, 0, 0) end
		return CFrame.new((lx + hx) / 2, (ly + hy) / 2, (lz + hz) / 2), Vector3.new(hx - lx, hy - ly, hz - lz)
	end
end

-- A Part's Shape is Block unless set, as in Roblox (destruct_mocks leaves it nil).
do
	local new = Instance.new
	Instance.new = function(className, parent)
		local inst = new(className, parent)
		if className == "Part" then
			rawget(inst, "__props").Shape = Enum.PartType.Block
		end
		return inst
	end
end

-- Wire the Terrain instance.
local terrain = workspace.Terrain
function terrain.FillBlock(_, cf, size, material) T.fillBlock(cf, size, material) end
function terrain.FillCylinder(_, cf, height, radius, material) T.fillCylinder(cf, height, radius, material) end
function terrain.FillBall(_, centre, radius, material) T.fillBall(centre, radius, material) end
function terrain.FillWedge(_, cf, size, material) T.fillBlock(cf, size, material) end
function terrain.ReadVoxels(_, region) return T.readVoxels(region) end
function terrain.WriteVoxels(_, region, _, materials, occupancies) T.writeVoxels(region, materials, occupancies) end
function terrain.ReplaceMaterial(_, region, _, from, to) T.replaceMaterial(region, from, to) end
function terrain.Clear() T.clear() end
terrain.WaterWaveSize, terrain.WaterWaveSpeed = 0, 0

-- Straight-down rays against the terrain.
T.rays = 0
mock.raycast = function(origin, direction, params)
	T.rays = T.rays + 1
	if math.abs(direction.X) > 1e-6 or math.abs(direction.Z) > 1e-6 or direction.Y >= 0 then
		error("foundation mocks: only straight-down terrain rays are modelled", 2)
	end
	local list = params and params.FilterDescendantsInstances or {}
	local wantsTerrain = false
	for _, item in ipairs(list) do
		if item == workspace.Terrain then
			wantsTerrain = true
		end
	end
	if params and params.FilterType == Enum.RaycastFilterType.Exclude then
		wantsTerrain = true
		for _, item in ipairs(list) do
			if item == workspace.Terrain then
				wantsTerrain = false
			end
		end
	end
	if not wantsTerrain then
		return nil
	end
	local y, material = T.surface(origin.X, origin.Z, params and params.IgnoreWater)
	if not y or y > origin.Y or y < origin.Y + direction.Y then
		return nil
	end
	return { Position = Vector3.new(origin.X, y, origin.Z), Material = material, Instance = workspace.Terrain,
		Normal = Vector3.new(0, 1, 0), Distance = origin.Y - y }
end

-- Parts whose world box meets a turned box (by the parts' world-axis boxes: a candidate test, as in
-- Roblox, where bounds are bounds).
function workspace.GetPartBoundsInBox(_, cf, size, params)
	local out = {}
	local r, u, b, p = cf.r, cf.u, cf.b, cf.p
	local ex = math.abs(r.X) * size.X / 2 + math.abs(u.X) * size.Y / 2 + math.abs(b.X) * size.Z / 2
	local ey = math.abs(r.Y) * size.X / 2 + math.abs(u.Y) * size.Y / 2 + math.abs(b.Y) * size.Z / 2
	local ez = math.abs(r.Z) * size.X / 2 + math.abs(u.Z) * size.Y / 2 + math.abs(b.Z) * size.Z / 2
	for _, root in ipairs(params and params.FilterDescendantsInstances or { workspace }) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("BasePart") and d.CanQuery ~= false then
				local cf2, s = d.CFrame, d.Size
				local fx = math.abs(cf2.r.X) * s.X / 2 + math.abs(cf2.u.X) * s.Y / 2 + math.abs(cf2.b.X) * s.Z / 2
				local fy = math.abs(cf2.r.Y) * s.X / 2 + math.abs(cf2.u.Y) * s.Y / 2 + math.abs(cf2.b.Y) * s.Z / 2
				local fz = math.abs(cf2.r.Z) * s.X / 2 + math.abs(cf2.u.Z) * s.Y / 2 + math.abs(cf2.b.Z) * s.Z / 2
				local q = cf2.p
				if math.abs(q.X - p.X) <= ex + fx and math.abs(q.Y - p.Y) <= ey + fy and math.abs(q.Z - p.Z) <= ez + fz then
					table.insert(out, d)
				end
			end
		end
	end
	return out
end

function workspace.BulkMoveTo(_, parts, cframes)
	for i, part in ipairs(parts) do
		part.CFrame = cframes[i]
	end
end

return T
