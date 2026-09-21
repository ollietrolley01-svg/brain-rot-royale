-- Footprint bookkeeping for map generation. Roads, streets, buildings, lakes, easter eggs, street
-- furniture and scenery each claim the ground they stand on, and everything placed afterwards
-- checks first — so nothing gets built through anything else.
--
-- Claims are circles, rotated rectangles, or strips either side of a line (roads and streets).
-- Queries are circles. A coarse grid keeps checks cheap with thousands of claims on a big map.

local MapSpace = {}
MapSpace.__index = MapSpace

local CELL = 48

function MapSpace.new()
	return setmetatable({ grid = {} }, MapSpace)
end

-- Unique for any cell within ±32768 cells, far beyond any map.
local function cellKey(cx, cz)
	return cx * 65536 + cz
end

function MapSpace:_insert(entry, minX, minZ, maxX, maxZ)
	for cx = math.floor(minX / CELL), math.floor(maxX / CELL) do
		for cz = math.floor(minZ / CELL), math.floor(maxZ / CELL) do
			local key = cellKey(cx, cz)
			local bucket = self.grid[key]
			if not bucket then
				bucket = {}
				self.grid[key] = bucket
			end
			table.insert(bucket, entry)
		end
	end
	return entry
end

function MapSpace:AddCircle(x, z, radius)
	return self:_insert({ kind = "circle", x = x, z = z, r = radius }, x - radius, z - radius, x + radius, z + radius)
end

-- `yaw` turns the rectangle the same way CFrame.Angles(0, yaw, 0) would: `halfX` runs along its
-- local X and `halfZ` along its local Z.
function MapSpace:AddRect(x, z, halfX, halfZ, yaw)
	local c, s = math.cos(yaw or 0), math.sin(yaw or 0)
	local extentX = math.abs(c) * halfX + math.abs(s) * halfZ
	local extentZ = math.abs(s) * halfX + math.abs(c) * halfZ
	return self:_insert({ kind = "rect", x = x, z = z, hx = halfX, hz = halfZ, c = c, s = s },
		x - extentX, z - extentZ, x + extentX, z + extentZ)
end

-- `halfWidth` either side of the line from `a` to `b` (Vector3s; Y is ignored).
function MapSpace:AddStrip(a, b, halfWidth)
	return self:_insert({ kind = "strip", ax = a.X, az = a.Z, bx = b.X, bz = b.Z, w = halfWidth },
		math.min(a.X, b.X) - halfWidth, math.min(a.Z, b.Z) - halfWidth,
		math.max(a.X, b.X) + halfWidth, math.max(a.Z, b.Z) + halfWidth)
end

local function overlaps(entry, x, z, radius)
	if entry.kind == "circle" then
		local dx, dz = x - entry.x, z - entry.z
		local reach = radius + entry.r
		return dx * dx + dz * dz < reach * reach
	elseif entry.kind == "rect" then
		-- Into the rectangle's own axes, then the distance to its nearest edge.
		local dx, dz = x - entry.x, z - entry.z
		local localX = dx * entry.c - dz * entry.s
		local localZ = dx * entry.s + dz * entry.c
		local outX = math.max(math.abs(localX) - entry.hx, 0)
		local outZ = math.max(math.abs(localZ) - entry.hz, 0)
		return outX * outX + outZ * outZ < radius * radius
	end
	local abX, abZ = entry.bx - entry.ax, entry.bz - entry.az
	local lengthSq = abX * abX + abZ * abZ
	local t = lengthSq > 0 and math.clamp(((x - entry.ax) * abX + (z - entry.az) * abZ) / lengthSq, 0, 1) or 0
	local px, pz = entry.ax + abX * t - x, entry.az + abZ * t - z
	local reach = radius + entry.w
	return px * px + pz * pz < reach * reach
end

-- Whether a circle of `radius` at (x, z) is clear of every claim. `ignore` skips one claim — a
-- car parked on its own street, a bench beside its own kerb.
function MapSpace:IsFree(x, z, radius, ignore)
	radius = math.max(radius, 0.05)
	for cx = math.floor((x - radius) / CELL), math.floor((x + radius) / CELL) do
		for cz = math.floor((z - radius) / CELL), math.floor((z + radius) / CELL) do
			local bucket = self.grid[cellKey(cx, cz)]
			if bucket then
				for _, entry in ipairs(bucket) do
					if entry ~= ignore and overlaps(entry, x, z, radius) then
						return false
					end
				end
			end
		end
	end
	return true
end

return MapSpace
