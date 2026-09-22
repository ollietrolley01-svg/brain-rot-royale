-- The big shapes of the ground, beyond hills: a river with crossings, flat-topped plateaus with
-- a ramp up, patches of other ground, snow on the high ground, and each map's clouds.
--
--   River      one winding river right across the map, kept out of every town. It cuts through
--              whatever hills stand in its way (a gorge on Rot Ridge), has sandy shelves along
--              both banks, and can be swum — slowly. Every road across it gets a stone bridge;
--              elsewhere there are a couple of plank footbridges and a line of stepping stones,
--              so crossings are chokepoints, not walls.
--   Plateaus   mesas: flat tops 20–34 studs up with sheer sides and one ramp. A chest and loot
--              on top, so the high ground is worth the climb and worth watching.
--   Patches    ground of a second and third kind laid into the base material — groves, mud,
--              salt flats, parking lots, parks, basalt — so a map isn't one texture edge to edge,
--              and snow above the tree line on the highland map.
--   Clouds     a cloud layer per map (thin and high on the coast, low and grey at dawn on the
--              ridge).
--
-- Everything here claims what it uses in MapSpace, so towns, landmarks, eggs, lakes and scenery
-- keep off it. Plateaus go down before the hills (so hills keep off them) and the river after
-- (so it carves through them).

local MapDecor = require(script.Parent:WaitForChild("MapDecor"))
local RoadNetwork = require(script.Parent:WaitForChild("RoadNetwork"))
local ZiplineService = require(script.Parent:WaitForChild("ZiplineService"))

local MapTerrain = {}

-- Roblox draws a smooth-terrain surface this far ABOVE the top of a block fill (a block filled
-- to y = 0 reads as ground at y = 2; measured, and exact for any top height). Cylinder fills
-- round up to the voxel grid as well, and water sits at its fill top. So every solid fill here
-- aims its top this far under the surface it wants, and anything whose real top matters (a
-- plateau) reads the ground back after filling rather than trusting the number.
MapTerrain.SurfaceLift = 2

local RIVER_WIDTH = 34
local RIVER_STEP = 60
local RIVER_TRIES = 60

-- The river's cross-section (Oliver, 2026-09-22 16:12: "fix riverbanks and their steep cliffs and
-- untextured beaches"). It used to be a vertical box cut 180 studs tall, so wherever the rolling
-- ground stood higher than the water the bank was a sheer wall, and the "shore" was a 2-stud strip of
-- Sandstone/Slate/Mud painted under the surface where it mostly never showed. Now every column near
-- the river is written to a profile of its distance from the centre line: a sandy bed, a shelving
-- shore through the waterline, a proper sand beach, then a bank that climbs back to the natural
-- ground at a walkable grade -- gentle first, never steeper than 45 degrees.
-- Surface heights (the rendered ground), not fills: the write subtracts SurfaceLift like every other.
local RIVER_BED = -6 -- the bed's surface; MapDecor's bridge piers go down to -9
local RIVER_WATER_TOP = -1 -- the water's fill top, as before
local RIVER_SHORE_IN = RIVER_WIDTH / 2 - 8 -- flat bed out to here
local RIVER_SHORE_OUT = RIVER_WIDTH / 2 + 2 -- the shore shelves up to 0 here (waterline ~16 out)
local RIVER_BEACH_OUT = RIVER_WIDTH / 2 + 14 -- sand beach out to here, rising to BEACH_TOP
local RIVER_BEACH_TOP = 1.5
local RIVER_BANK_GENTLE = 20 -- studs of gentle bank past the beach...
local RIVER_BANK_GENTLE_GRADE = 0.55 -- ...at this grade (about 29 degrees)
local RIVER_BANK_GRADE = 1 -- then no steeper than 45 degrees, however high the ground
local RIVER_REACH = RIVER_BEACH_OUT + RIVER_BANK_GENTLE + 130 -- far enough to meet the highest ground
local RIVER_BEACH = Enum.Material.Sand
local RIVER_TOP = 148 -- above the tallest ground on a map (measured ceiling ~127)

local function flatDistance(ax, az, bx, bz)
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

--------------------------------------------------------------------------------
-- Plateaus
--------------------------------------------------------------------------------

local RAMP_ANGLE = math.rad(28)

-- Flat-topped cylinders of ground with one ramp cut down to the plain and a zipline off the far
-- rim. Returns the list of { X, Z, radius, height, rampYaw } placed, and registers a chest and
-- loot on each top. `parent` holds the zipline parts.
-- Where the plateaus go, claimed, before any ground is written, so the river can be planned round
-- them and the roads' bridges known before the ground under the roads is shaped. Plateaus (below)
-- fills them.
function MapTerrain.PlanPlateaus(preset, radius, centers, townSpread, space)
	local placed = {}
	local count = math.clamp(math.floor(radius / 420), 1, 3)
	for _ = 1, count do
		for _ = 1, 30 do
			local angle = math.random() * math.pi * 2
			local distance = (0.3 + math.random() * 0.45) * radius
			local x, z = math.cos(angle) * distance, math.sin(angle) * distance
			local size = math.random(55, 85)
			local height = math.random(22, 34)
			local rampLength = height / math.tan(RAMP_ANGLE)

			local clear = space:IsFree(x, z, size + rampLength + 24)
			for _, center in ipairs(centers) do
				if clear and flatDistance(center.X, center.Z, x, z) < townSpread + 90 + size then
					clear = false
				end
			end
			for _, other in ipairs(placed) do
				if clear and flatDistance(other.X, other.Z, x, z) < size + other.radius + 200 then
					clear = false
				end
			end

			if clear then
				local rampYaw = math.random() * math.pi * 2
				local out = Vector3.new(math.cos(rampYaw), 0, math.sin(rampYaw))
				space:AddCircle(x, z, size + 10)
				space:AddStrip(Vector3.new(x, 0, z) + out * (size - 4), Vector3.new(x, 0, z) + out * (size - 4 + rampLength + 10), 12)
				table.insert(placed, { X = x, Z = z, radius = size, height = height, rampYaw = rampYaw, out = out })
				break
			end
		end
	end
	return placed
end

-- Fills the plateaus `placed` by PlanPlateaus (planning them first if not given), then dresses
-- each to its real top. Returns the list of { X, Z, radius, height, rampYaw } placed.
function MapTerrain.Plateaus(terrain, parent, preset, radius, centers, townSpread, space, chestSpots, lootSpots, groundHeightAt, placed)
	placed = placed or MapTerrain.PlanPlateaus(preset, radius, centers, townSpread, space)
	for _, plateau in ipairs(placed) do
		-- Filled to `height` less the surface lift; what the top actually reads as is measured below
		-- once the voxels have settled, and everything on it goes to that.
		terrain:FillCylinder(CFrame.new(plateau.X, (plateau.height - MapTerrain.SurfaceLift) / 2, plateau.Z), plateau.height - MapTerrain.SurfaceLift,
			plateau.radius, preset.terrainMaterial)
		-- A low ring of the map's own rock round the foot, so the sides read as cliff.
		terrain:FillCylinder(CFrame.new(plateau.X, -3, plateau.Z), 4, plateau.radius + 5, Enum.Material.Rock)
		task.wait()
	end

	-- Let the voxels settle so the ground can be read back, then dress each plateau to its real
	-- top: the ramp, the loot and the zipline.
	if #placed > 0 then
		task.wait(0.5)
	end
	for _, plateau in ipairs(placed) do
		local x, z, size, out, rampYaw = plateau.X, plateau.Z, plateau.radius, plateau.out, plateau.rampYaw
		local height = groundHeightAt(x, z)
		plateau.height = height
		local rampLength = height / math.tan(RAMP_ANGLE)

		-- The ramp: a tilted slab from the rim down to the ground, wide enough to walk two
		-- abreast. Its top end sits just inside the rim so there's no lip; the fill's top sits the
		-- surface lift under the line it should walk on.
		local top = Vector3.new(x, height, z) + out * (size - 4)
		local footFlat = top + out * rampLength
		local foot = Vector3.new(footFlat.X, groundHeightAt(footFlat.X, footFlat.Z), footFlat.Z)
		local mid = top:Lerp(foot, 0.5)
		local slab = CFrame.lookAt(mid, foot)
		terrain:FillBlock(slab * CFrame.new(0, -(MapTerrain.SurfaceLift + 2), 0), Vector3.new(16, 4, (foot - top).Magnitude + 6), Enum.Material.Cobblestone)

		-- A chest in the middle of the top, guns near the rim, an item by the ramp head.
		table.insert(chestSpots, CFrame.new(x, height, z) * CFrame.Angles(0, math.random() * math.pi * 2, 0))
		for index = 1, 3 do
			local spotAngle = rampYaw + index * math.pi / 2
			table.insert(lootSpots.weapon, Vector3.new(x + math.cos(spotAngle) * (size - 12), height, z + math.sin(spotAngle) * (size - 12)))
		end
		table.insert(lootSpots.item, Vector3.new(top.X, height, top.Z) - out * 10)

		-- A zipline from the rim opposite the ramp down to the plain.
		local away = -out
		local rim = Vector3.new(x, height, z) + away * (size - 3)
		for _, reach in ipairs({ 110, 90, 130 }) do
			local lx, lz = rim.X + away.X * reach, rim.Z + away.Z * reach
			if space:IsFree(lx, lz, 5) then
				local ground = groundHeightAt(lx, lz)
				if ground < height - 12 then
					local landing = Vector3.new(lx, ground, lz)
					if ZiplineService.Create(parent, landing, landing, rim + Vector3.new(0, 2.6, 0)) then
						space:AddCircle(lx, lz, 5)
						-- The river's graded banks leave this ground alone (MapTerrain.River).
						plateau.landing = landing
						-- A rail post at the rim so the handle has something to hang from.
						local post = Instance.new("Part")
						post.Size = Vector3.new(0.8, 3, 0.8)
						post.CFrame = CFrame.new(rim + Vector3.new(0, 1.5, 0))
						post.Color = Color3.fromRGB(58, 60, 68)
						post.Material = Enum.Material.Metal
						post.Anchored = true
						post.Parent = parent
						break
					end
				end
			end
		end
		task.wait()
	end
	return placed
end

--------------------------------------------------------------------------------
-- Base relief
--------------------------------------------------------------------------------

-- The ground under everything else. The map used to be a dead-flat slab with hills dropped onto
-- it, so anywhere a hill hadn't landed read as a billiard table -- which was most of it, and no
-- number of extra hills fixed that. This lays a continuous height field over the whole map
-- instead: three octaves of Perlin noise written straight into the voxels as fractional
-- occupancy, so the surface comes out smooth rather than stepped. Hills, ridges and craters
-- still go on top, and now sit ON this ground rather than on a plane.
--
-- Two things shape the field. It is biased upward so it almost never dips below y = 0, because
-- the river, its bridges and the lakes all carve to fixed heights near zero and ground below
-- them would leave water hanging in mid-air. And it fades to exactly zero over every town, so
-- streets and buildings still meet flat ground; towns end up sitting in shallow basins, which is
-- where towns tend to be anyway.
--
-- SurfaceLift applies here exactly as it does to every other fill, and assuming otherwise cost a
-- whole build. The reasoning that failed was that a linear occupancy ramp through the transition
-- voxel puts the isosurface exactly on the target, so no correction is wanted. It doesn't, because
-- there isn't always a transition voxel: over a town the target is 0, which falls precisely on a
-- voxel boundary, so the column is solid to the boundary and empty above it -- a hard cut, which
-- is the very case the 2-stud lift describes. Town ground came out at 2 instead of 0 and the
-- harness found 67 buried parts, mostly building steps sitting under their own ground.

local RELIEF_FLOOR = -8 -- bottom of the band of voxels this writes; solid slab continues below
local RELIEF_CEILING = 64 -- top of the band; the field is clamped just under it
local RELIEF_TILE = 128 -- written in tiles this wide so no single call is enormous

MapTerrain.ReliefSeed = 0

-- Wavelengths and amplitudes, and the first pass got both wrong. Perlin noise almost never
-- reaches its own extremes -- a single octave typically lands within about a fifth of its range --
-- so a 560-stud wavelength at nominal amplitude 22 produced real swells of roughly nine studs
-- over five hundred. That is a two percent grade. It is genuinely rolling ground and it is also
-- completely invisible from anywhere you actually stand, which is why the maps still read flat
-- after the relief pass went in. Shorter wavelengths and far more amplitude are the fix, not more
-- hills on top.
local function reliefRaw(x, z, seed)
	-- math.noise returns roughly -0.5..0.5, so each octave is doubled to land in -1..1.
	local broad = math.noise(x / 300, z / 300, seed) * 2
	local mid = math.noise(x / 150, z / 150, seed + 17) * 2
	local fine = math.noise(x / 65, z / 65, seed + 41) * 2
	return broad * 30 + mid * 10 + fine * 4
end

-- The relief height at a point, town fade included. Anything laying ground-level geometry after
-- Relief has run should add this rather than assuming y = 0. Returns 0 before Relief runs.
function MapTerrain.ReliefAt(x, z)
	local at = MapTerrain._reliefAt
	return at and at(x, z) or 0
end

-- `roads`, when given, is the planned RoadNetwork (and `roadCrossings` where the planned river crosses
-- it, from RoadCrossings): its heights are worked out here from the natural ground, and the ground
-- is then shaped to it -- dead flat across every road and its shoulders at
-- the road's own height, blending back into the natural ground either side -- in the same voxel
-- write, painted asphalt under the carriageway and gravel along the shoulders.
function MapTerrain.Relief(terrain, preset, radius, centers, townSpread, roads, roadCrossings)
	local seed = math.random() * 512
	MapTerrain.ReliefSeed = seed
	local material = preset.terrainMaterial

	-- Flat out to `inner` from a town centre, full relief from `outer`, smoothstepped between.
	local inner = townSpread + 40
	local outer = townSpread + 180

	local function heightAt(x, z)
		local factor = 1
		for _, center in ipairs(centers) do
			local distance = flatDistance(center.X, center.Z, x, z)
			if distance <= inner then
				return 0
			elseif distance < outer then
				local t = (distance - inner) / (outer - inner)
				factor = math.min(factor, t * t * (3 - 2 * t))
			end
		end
		if factor <= 0 then
			return 0
		end
		-- Biased up so the low ground sits near zero rather than below it. The river, its bridges
		-- and the lakes all carve to fixed heights around zero, and ground below them would leave
		-- water hanging in mid-air.
		local height = reliefRaw(x, z, seed) + 14
		if height < 0 then
			-- A soft floor rather than a hard one: shallow hollows instead of a wide dead flat.
			height *= 0.12
		end
		return math.min(height, RELIEF_CEILING - 4) * factor
	end

	MapTerrain.ResetPads(roads, material)

	-- The ground everything is actually written to: the natural field, shaped under the roads.
	local shapedAt = heightAt
	if roads then
		roads:ComputeHeights(heightAt, preset, roadCrossings)
		shapedAt = function(x, z)
			local natural = heightAt(x, z)
			local height, override = roads:GroundAt(x, z, natural)
			if height then
				return height, override
			end
			return natural, nil
		end
	end
	MapTerrain._reliefAt = function(x, z)
		return (shapedAt(x, z))
	end

	local span = RELIEF_TILE / 4
	local sizeY = (RELIEF_CEILING - RELIEF_FLOOR) / 4
	local reach = radius * 1.16
	local first = -math.ceil(reach / RELIEF_TILE) * RELIEF_TILE
	local written = 0

	local x0 = first
	while x0 < reach do
		local z0 = first
		while z0 < reach do
			-- The playable area is a circle; skip the corners of the square nobody reaches.
			if flatDistance(0, 0, x0 + RELIEF_TILE / 2, z0 + RELIEF_TILE / 2) <= reach + RELIEF_TILE then
				local materials, occupancies = {}, {}
				for ix = 1, span do
					local worldX = x0 + (ix - 0.5) * 4
					local targets, columnMaterials = {}, {}
					for iz = 1, span do
						-- Aimed the surface lift under the height wanted, like every other fill.
						local height, override = shapedAt(worldX, z0 + (iz - 0.5) * 4)
						targets[iz] = height - MapTerrain.SurfaceLift
						columnMaterials[iz] = override or material
					end
					local columnMaterial, columnOccupancy = {}, {}
					for iy = 1, sizeY do
						local bottom = RELIEF_FLOOR + (iy - 1) * 4
						local rowMaterial, rowOccupancy = {}, {}
						for iz = 1, span do
							local occupancy = (targets[iz] - bottom) / 4
							occupancy = occupancy < 0 and 0 or (occupancy > 1 and 1 or occupancy)
							rowMaterial[iz] = occupancy > 0 and columnMaterials[iz] or Enum.Material.Air
							rowOccupancy[iz] = occupancy
						end
						columnMaterial[iy] = rowMaterial
						columnOccupancy[iy] = rowOccupancy
					end
					materials[ix] = columnMaterial
					occupancies[ix] = columnOccupancy
				end
				local region = Region3.new(Vector3.new(x0, RELIEF_FLOOR, z0), Vector3.new(x0 + RELIEF_TILE, RELIEF_CEILING, z0 + RELIEF_TILE))
				terrain:WriteVoxels(region, 4, materials, occupancies)
				written += 1
				if written % 6 == 0 then
					task.wait()
				end
			end
			z0 += RELIEF_TILE
		end
		x0 += RELIEF_TILE
	end
	return written
end

--------------------------------------------------------------------------------
-- Hills, ridges, craters and dunes
--------------------------------------------------------------------------------

-- The rolling ground between the towns. Rather than one kind of hill everywhere: round hills of
-- many sizes; long ridges (a row of overlapping domes along a line, so they read as one hill
-- with a spine); craters — a bowl scooped out of the ground with a raised rim and a pool at the
-- bottom; and on sand, low broad dunes in drifts. Tall hills get a rock cap so the high ground
-- reads as high ground. Everything keeps off the towns, the roads and whatever is already
-- claimed (plateaus), and away from the very middle where the last circle lands.
function MapTerrain.Hills(terrain, preset, radius, centers, townSpread, space)
	local material = preset.terrainMaterial
	local sand = material == Enum.Material.Sand
	-- Many more attempts than there used to be, and most of them small. Relief made of a handful
	-- of big hills spread over a kilometre reads as flat everywhere you actually fight.
	local count = math.floor(radius / 14)
	local placed = 0

	-- `margin` is how far a feature has to stay off a town. Ridges and craters keep well clear;
	-- low mounds only have to miss the buildings themselves, which is what lets the ground
	-- between and around towns roll instead of running dead flat.
	local function clearAt(x, z, reach, margin)
		if not space:IsFree(x, z, reach + 15) then
			return false
		end
		for _, center in ipairs(centers) do
			if flatDistance(center.X, center.Z, x, z) < townSpread + (margin or 70) + reach then
				return false
			end
		end
		return true
	end

	for index = 1, count do
		local angle = math.random() * math.pi * 2
		local distance = (0.25 + math.sqrt(math.random()) * 0.7) * radius
		local x, z = math.cos(angle) * distance, math.sin(angle) * distance
		local roll = math.random()
		-- Everything here sits ON the base relief rather than on a plane at zero, so every height
		-- below is measured from the ground actually under that spot.
		local base = MapTerrain.ReliefAt(x, z)

		if roll < 0.09 then
			-- A crater: a bowl of air, a rim of small domes, a pool in the bottom.
			local bowl = math.random(26, 44)
			if clearAt(x, z, bowl + 12) then
				terrain:FillBall(Vector3.new(x, base + bowl * 0.55, z), bowl, Enum.Material.Air)
				for rim = 0, 7 do
					local a = rim / 8 * math.pi * 2
					local rx, rz = x + math.cos(a) * bowl * 0.95, z + math.sin(a) * bowl * 0.95
					terrain:FillBall(Vector3.new(rx, MapTerrain.ReliefAt(rx, rz) - bowl * 0.05, rz), bowl * 0.38,
						sand and Enum.Material.Sandstone or Enum.Material.Rock)
				end
				terrain:FillCylinder(CFrame.new(x, base - bowl * 0.45 + 1.5, z), 3, bowl * 0.45, Enum.Material.Water)
				space:AddCircle(x, z, bowl + 8)
				placed += 1
			end
		elseif roll < 0.24 then
			-- A ridge: five domes along a line, the middle ones tallest.
			local length = math.random(120, 260)
			local yaw = math.random() * math.pi
			local dx, dz = math.cos(yaw), math.sin(yaw)
			local width = math.random(60, 100)
			local height = math.random(16, 44)
			if clearAt(x, z, length / 2 + width * 0.6) then
				for step = -2, 2 do
					local along = step * length / 5
					local rise = height * (1 - (step / 3) ^ 2)
					local sx, sz = x + dx * along, z + dz * along
					terrain:FillBall(Vector3.new(sx, MapTerrain.ReliefAt(sx, sz) + rise - width * 0.62, sz), width, material)
				end
				if height >= 30 then
					local top = base + height
					local region = Region3.new(Vector3.new(x - length, top - 10, z - length), Vector3.new(x + length, top + 20, z + length)):ExpandToGrid(4)
					terrain:ReplaceMaterial(region, 4, material, sand and Enum.Material.Sandstone or Enum.Material.Rock)
				end
				placed += 1
			end
		elseif sand and roll < 0.40 then
			-- Dunes: three low, broad domes in a drift.
			local size = math.random(80, 150)
			if clearAt(x, z, size + 40) then
				for step = 0, 2 do
					local a = angle + step * 0.5
					local sx, sz = x + math.cos(a) * size * 0.5, z + math.sin(a) * size * 0.5
					terrain:FillBall(Vector3.new(sx, MapTerrain.ReliefAt(sx, sz) + 8 - size * 0.62, sz), size, material)
				end
				placed += 1
			end
		elseif roll < 0.78 then
			-- A knot of low mounds: the bread and butter of the relief. Low enough to run over and
			-- shoot across, small enough to sit near a town without swallowing it. A ball of
			-- radius `size` buried so its top is `peak` above the ground leaves a shallow cap;
			-- `spread` is how wide that cap comes out, which is what has to be clear.
			local mounds = math.random(2, 4)
			for step = 0, mounds - 1 do
				local a = angle + step * (1.3 + math.random() * 0.9)
				local away = math.random(20, 46)
				local size = math.random(34, 72)
				local peak = math.random(5, 16)
				local mx, mz = x + math.cos(a) * away, z + math.sin(a) * away
				local spread = math.sqrt(math.max(1, 2 * size * peak - peak * peak))
				if clearAt(mx, mz, spread, 18) then
					terrain:FillBall(Vector3.new(mx, MapTerrain.ReliefAt(mx, mz) + peak - size, mz), size, material)
					placed += 1
				end
			end
		else
			-- A round hill; the tall ones get a rock cap.
			local size = math.random(60, 170)
			local height = math.random(10, 42)
			if clearAt(x, z, size) then
				terrain:FillBall(Vector3.new(x, base + height - size * 0.62, z), size, material)
				if height >= 30 then
					local top = base + height
					local region = Region3.new(Vector3.new(x - size, top - 8, z - size), Vector3.new(x + size, top + 20, z + size)):ExpandToGrid(4)
					terrain:ReplaceMaterial(region, 4, material, sand and Enum.Material.Sandstone or Enum.Material.Rock)
				end
				placed += 1
			end
		end

		-- Each fill is a sizeable voxel write; spread them out so match start doesn't stall.
		if index % 4 == 0 then
			task.wait()
		end
	end
	return placed
end

--------------------------------------------------------------------------------
-- The ground under the roads, put back
--------------------------------------------------------------------------------

-- The relief pass shapes the ground under every road, but the hills, ridges and craters go on
-- after it, and a hill's sphere of ground is widest at its lowest point: where a road runs through
-- a cutting below a mound's base, the mound can fill part of the cutting back in, pushing terrain
-- up through the road. So once they're all down, the flat corridor under every road is written
-- again, exactly as the relief pass shaped it: dead flat at the road's own ground height across the
-- carriageway and shoulders, air above it, asphalt and gravel painted on. The river is carved
-- afterwards, so it still cuts its gorge under the bridges.
--
-- It runs a second time once everything else that writes terrain is down (landmark sites are
-- levelled as squares whose corners reach past the circle they keep clear, and the same goes for
-- anything added later), with `aroundBridges` set so the gorge under every bridge is left alone:
-- the ground BRIDGE_CLEARANCE along the road past each end of the bridge, which covers the river's
-- channel and banks right across the corridor even where the river crosses at a slant. A column
-- holding water is never touched.
--
-- The corridor includes the flat ground past the shoulders, and all of it is painted again as
-- GroundAt names it: patches and rock caps laid over it since may be materials that don't lie flat
-- (rough rock, or pavement and concrete, which snap the surface to a grid; see
-- RoadNetwork.SmoothMaterials).
local BRIDGE_CLEARANCE = 40

function MapTerrain.RestoreRoadGround(terrain, roads, aroundBridges)
	if not roads or not roads.edges then
		return 0
	end
	local corridor = roads:CorridorHalfWidth()
	local CHUNK = 128
	local written = 0

	-- One box of columns, each written to whatever GroundAt says the road wants there.
	local function writeBox(minCorner, maxCorner)
		local region = Region3.new(minCorner, maxCorner):ExpandToGrid(4)
		local size = region.Size / 4
		local origin = region.CFrame.Position - region.Size / 2
		local materials, occupancies = terrain:ReadVoxels(region, 4)
		for ix = 1, size.X do
			local x = origin.X + (ix - 0.5) * 4
			for iz = 1, size.Z do
				local z = origin.Z + (iz - 0.5) * 4
				if roads:WithinCorridor(x, z) and not (aroundBridges and roads:NearBridge(x, z, BRIDGE_CLEARANCE)) then
					local height, material = roads:GroundAt(x, z, 0)
					local wet = false
					for iy = 1, size.Y do
						if materials[ix][iy][iz] == Enum.Material.Water then
							wet = true
							break
						end
					end
					if height and not wet then
						for iy = 1, size.Y do
							local bottom = origin.Y + (iy - 1) * 4
							local occupancy = math.clamp((height - MapTerrain.SurfaceLift - bottom) / 4, 0, 1)
							occupancies[ix][iy][iz] = occupancy
							materials[ix][iy][iz] = occupancy > 0 and material or Enum.Material.Air
						end
					end
				end
			end
		end
		terrain:WriteVoxels(region, 4, materials, occupancies)
		written += 1
		if written % 4 == 0 then
			task.wait()
		end
	end

	-- The curves, chord by chord: a curve is level, so one box round each chord is enough.
	for _, curve in ipairs(roads:Curves()) do
		local height = curve.node.height
		for _, chord in ipairs(curve.chords) do
			writeBox(Vector3.new(math.min(chord.from.X, chord.to.X) - corridor, height - 12, math.min(chord.from.Z, chord.to.Z) - corridor),
				Vector3.new(math.max(chord.from.X, chord.to.X) + corridor, height + 140, math.max(chord.from.Z, chord.to.Z) + corridor))
		end
	end

	for _, edge in ipairs(roads.edges) do
		-- Past a junction's end of the edge as far as the corridor is wide, so the box's corners are
		-- covered too; never past a town's street end, where the town lays its own ground.
		local extendA = edge.a.kind == "mouth" and 0 or corridor
		local extendB = edge.b.kind == "mouth" and 0 or corridor
		local along = -extendA
		while along < edge.length + extendB do
			local stop = math.min(along + CHUNK, edge.length + extendB)
			local p0, p1 = edge.from + edge.dir * along, edge.from + edge.dir * stop
			-- Sampled between the chunk's ends, clamped onto the edge. Clamping matters: the last
			-- chunk of an edge covers only the overhang past its junction, so it starts beyond the
			-- edge's end -- and a loop from a start past its stop never runs, leaving low and high
			-- infinite, Region3 with its minimum above its maximum, and Roblox warning "Region has to
			-- be aligned to the grid" while that stretch of road kept whatever the relief left there.
			local from, to = math.clamp(along, 0, edge.length), math.clamp(stop, 0, edge.length)
			local low, high = math.huge, -math.huge
			for s = from, to, 4 do
				local h = roads.EdgeHeight(edge, s)
				low, high = math.min(low, h), math.max(high, h)
			end
			for _, s in ipairs({ from, to }) do
				local h = roads.EdgeHeight(edge, s)
				low, high = math.min(low, h), math.max(high, h)
			end
			local lateral = Vector3.new(math.abs(edge.dir.Z), 0, math.abs(edge.dir.X)) * corridor
			local minCorner = Vector3.new(math.min(p0.X, p1.X), low - 12, math.min(p0.Z, p1.Z)) - lateral
			local maxCorner = Vector3.new(math.max(p0.X, p1.X), high + 140, math.max(p0.Z, p1.Z)) + lateral
			writeBox(minCorner, maxCorner)
			along = stop
		end
	end
	return written
end


--------------------------------------------------------------------------------
-- Flat pads under structures
--------------------------------------------------------------------------------

-- A structure wants flat ground under the whole of itself. Left to the natural relief, a building
-- on a slope stands on its highest corner with daylight under the other three, which is what
-- "floating on ledges" looks like from inside the game.
--
--   MapTerrain.FlattenPad(site, size, options) -> height | nil, reason
--
-- Levels the ground under a footprint: dead flat at one height across it and `margin` studs round
-- it, cut where the ground stands higher, filled SOLID down to the natural ground where it falls
-- away (never a shelf with a hollow under it), then graded back into the ground beyond over a short
-- smoothstepped slope.
--
--   site     CFrame at the footprint's centre; only its yaw is used. Its Y is the height wanted
--            unless options.height says otherwise.
--   size     Vector3: X across the site's X, Z across its Z (Y ignored). For a round pad, X is the
--            diameter.
--   options  shape    "rect" (default) or "round".
--            height   a number, or "mid" (halfway between the lowest and highest ground under the
--                     footprint), "mean", "low", "high". Default: site.Y.
--            margin   flat ground beyond the footprint. Default 3. Keep it inside your own claim.
--            blend    width of the graded edge beyond that. Default: twice the height it makes up,
--                     between 6 and 24.
--            retain   true: no graded edge, the flat stops dead (build the retaining wall yourself).
--            maxCut   refuse if the ground stands more than this above the pad.
--            maxFill  refuse if it falls more than this below.
--            material paint for the flat top; must be a smooth material (see RoadNetwork.SmoothMaterials:
--                     rough and stepped ones move the rendered surface by up to a stud with no change
--                     to the voxels at all). Default: the ground's own where that is smooth.
--            space    a MapSpace, and `ignore` an entry in it: the graded edge then leaves alone any
--                     ground that something else has claimed, except your own claim.
--
-- Returns the pad's height, or nil and a reason: "road" (the footprint reaches a road's flat
-- corridor -- roads always win), "pad" (it overlaps an earlier pad at a different height -- the
-- first pad wins), "cut"/"fill" (past maxCut/maxFill), "material", "nothing" (no ground there at all).
--
-- THE CONTRACT FOR CALLERS. A refusal is loud in a probe and quiet in play: this warns nothing
-- itself. On nil, try your next candidate site, or nudge the footprint and retry; if nothing is
-- left, skip the structure and `warn` once with the reason. NEVER build a structure un-padded.
-- Build at the height RETURNED, not the one you asked for.
--
-- Order: the first pad registered wins, so MapGenerator calls owners in a fixed order. Nothing here
-- consumes math.random, and it never yields: one voxel read and one voxel write per pad.
--
-- MapTerrain.PadCost(site, size, options) -> low, high, mean: the ground under the footprint and
-- margin, read from the voxels rather than by raycast (so a rough material's drawn surface can't
-- make a flat site look bumpy), without writing anything. For ranking candidate sites.
-- MapTerrain.PadAt(x, z) -> height | nil: the height of a registered pad's flat there.
-- MapTerrain.PadNear(x, z, margin) -> boolean: the same, including each pad's graded skirt and
-- `margin` beyond it -- for anything that should keep off a made site, like scattered grass.
-- MapTerrain.RewritePads(terrain): writes every registered pad's flat again. Cheap insurance against
-- anything that wrote terrain afterwards, and it makes "was the pad actually written?" answerable.

local PAD_MARGIN = 3
local PAD_BLEND_MIN, PAD_BLEND_MAX = 6, 24
local PAD_CELL = 4

MapTerrain.Pads = {}

-- Called once per build, from Relief, with the planned roads and the map's own ground material.
function MapTerrain.ResetPads(roads, groundMaterial)
	MapTerrain.Pads = {}
	MapTerrain._padRoads = roads
	MapTerrain._padGround = RoadNetwork.SmoothMaterials[groundMaterial] and groundMaterial or Enum.Material.Ground
end

-- How far outside the footprint (x, z) is, in studs; 0 or less means inside it.
local function padShape(site, size, options)
	local _, yaw = site:ToOrientation()
	local frame = CFrame.new(site.Position.X, 0, site.Position.Z) * CFrame.Angles(0, yaw, 0)
	local halfX, halfZ = size.X / 2, size.Z / 2
	if options.shape == "round" then
		return function(x, z)
			local p = frame:PointToObjectSpace(Vector3.new(x, 0, z))
			return math.sqrt(p.X * p.X + p.Z * p.Z) - halfX
		end, halfX
	end
	return function(x, z)
		local p = frame:PointToObjectSpace(Vector3.new(x, 0, z))
		return math.max(math.abs(p.X) - halfX, math.abs(p.Z) - halfZ)
	end, math.sqrt(halfX * halfX + halfZ * halfZ)
end

-- A column's ground height from its own voxels: the top solid one's occupancy read back through the
-- same formula every writer here uses. Water is not ground.
local function columnGround(materials, occupancies, ix, iz, sizeY, originY)
	for iy = sizeY, 1, -1 do
		local occupancy = occupancies[ix][iy][iz]
		local material = materials[ix][iy][iz]
		if occupancy > 0 and material ~= Enum.Material.Air and material ~= Enum.Material.Water then
			return originY + (iy - 1) * PAD_CELL + occupancy * PAD_CELL + MapTerrain.SurfaceLift, material
		end
	end
	return nil
end

local function padRegion(site, reach)
	local p = site.Position
	return Region3.new(Vector3.new(p.X - reach, RELIEF_FLOOR - 8, p.Z - reach),
		Vector3.new(p.X + reach, RELIEF_CEILING + 140, p.Z + reach)):ExpandToGrid(PAD_CELL)
end

function MapTerrain.PadCost(site, size, options)
	options = options or {}
	local outside, reach = padShape(site, size, options)
	local margin = options.margin or PAD_MARGIN
	local region = padRegion(site, reach + margin + PAD_CELL)
	local materials, occupancies = workspace.Terrain:ReadVoxels(region, PAD_CELL)
	local origin = region.CFrame.Position - region.Size / 2
	local count = region.Size / PAD_CELL
	local low, high, total, samples = math.huge, -math.huge, 0, 0
	for ix = 1, count.X do
		local x = origin.X + (ix - 0.5) * PAD_CELL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * PAD_CELL
			if outside(x, z) <= margin then
				local ground = columnGround(materials, occupancies, ix, iz, count.Y, origin.Y)
				if ground then
					low, high, total, samples = math.min(low, ground), math.max(high, ground), total + ground, samples + 1
				end
			end
		end
	end
	if samples == 0 then
		return nil
	end
	return low, high, total / samples
end

function MapTerrain.PadAt(x, z)
	for _, pad in ipairs(MapTerrain.Pads) do
		if pad.outside(x, z) <= pad.margin then
			return pad.height
		end
	end
	return nil
end

function MapTerrain.PadNear(x, z, margin)
	margin = margin or 0
	for _, pad in ipairs(MapTerrain.Pads) do
		if pad.outside(x, z) <= pad.margin + pad.blend + margin then
			return true
		end
	end
	return false
end

function MapTerrain.FlattenPad(site, size, options)
	options = options or {}
	local margin = options.margin or PAD_MARGIN
	if options.material and not RoadNetwork.SmoothMaterials[options.material] then
		return nil, "material"
	end
	local outside, reach = padShape(site, size, options)
	local blendRoom = options.retain and 0 or PAD_BLEND_MAX
	local region = padRegion(site, reach + margin + blendRoom + PAD_CELL)
	local terrain = workspace.Terrain
	local materials, occupancies = terrain:ReadVoxels(region, PAD_CELL)
	local origin = region.CFrame.Position - region.Size / 2
	local count = region.Size / PAD_CELL
	local roads = MapTerrain._padRoads

	local ground, groundMaterial = {}, {}
	local low, high, total, samples = math.huge, -math.huge, 0, 0
	for ix = 1, count.X do
		ground[ix], groundMaterial[ix] = {}, {}
		local x = origin.X + (ix - 0.5) * PAD_CELL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * PAD_CELL
			local height, material = columnGround(materials, occupancies, ix, iz, count.Y, origin.Y)
			ground[ix][iz], groundMaterial[ix][iz] = height, material
			if outside(x, z) <= margin then
				if roads and roads:WithinCorridor(x, z) then
					return nil, "road"
				end
				if height then
					low, high, total, samples = math.min(low, height), math.max(high, height), total + height, samples + 1
				end
			end
		end
	end
	if samples == 0 then
		return nil, "nothing"
	end

	local height = options.height
	if height == nil then
		height = site.Position.Y
	elseif height == "mid" then
		height = (low + high) / 2
	elseif height == "mean" then
		height = total / samples
	elseif height == "low" then
		height = low
	elseif height == "high" then
		height = high
	end
	if options.maxCut and high - height > options.maxCut then
		return nil, "cut"
	end
	if options.maxFill and height - low > options.maxFill then
		return nil, "fill"
	end
	-- An earlier pad's flat wins, so two pads never argue over one column.
	for ix = 1, count.X do
		local x = origin.X + (ix - 0.5) * PAD_CELL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * PAD_CELL
			if outside(x, z) <= margin then
				local other = MapTerrain.PadAt(x, z)
				if other and math.abs(other - height) > 0.05 then
					return nil, "pad"
				end
			end
		end
	end

	local space, ignore = options.space, options.ignore
	local painted = options.material
	for ix = 1, count.X do
		local x = origin.X + (ix - 0.5) * PAD_CELL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * PAD_CELL
			-- Two voxels beyond the margin, because a column is 4 studs wide and its centre decides
			-- which side of the edge it is on, and because smooth terrain draws its surface through the
			-- neighbouring columns as well as the one underfoot. One voxel left the pad's own edge
			-- sagging toward the ground beyond it (0.46 studs measured); a half-height step there made
			-- it worse, not better. Flat means flat, then the graded edge starts. Same 8 studs the
			-- roads hold past their shoulders, for the same reason.
			local distance = outside(x, z) - margin - 2 * PAD_CELL
			local current = ground[ix][iz]
			local target, paint = nil, nil
			if distance <= 0 then
				target = height
				local own = groundMaterial[ix][iz]
				paint = painted or (own and RoadNetwork.SmoothMaterials[own] and own) or MapTerrain._padGround or Enum.Material.Ground

			elseif current and not options.retain then
				local blend = math.clamp(math.abs(current - height) * 2, PAD_BLEND_MIN, PAD_BLEND_MAX)
				local clear = not (roads and roads:WithinCorridor(x, z)) and not MapTerrain.PadAt(x, z)
					and not (space and not space:IsFree(x, z, 0.01, ignore))
				if distance < blend and clear then
					local t = distance / blend
					target = height + (current - height) * (t * t * (3 - 2 * t))
				end
			end
			if target then
				for iy = 1, count.Y do
					local bottom = origin.Y + (iy - 1) * PAD_CELL
					local occupancy = math.clamp((target - MapTerrain.SurfaceLift - bottom) / PAD_CELL, 0, 1)
					local was = materials[ix][iy][iz]
					if was ~= Enum.Material.Water then
						occupancies[ix][iy][iz] = occupancy
						if occupancy <= 0 then
							materials[ix][iy][iz] = Enum.Material.Air
						elseif paint then
							materials[ix][iy][iz] = paint
						elseif was == Enum.Material.Air then
							materials[ix][iy][iz] = groundMaterial[ix][iz] or MapTerrain._padGround or Enum.Material.Ground
						end
					end
				end
			end
		end
	end
	terrain:WriteVoxels(region, PAD_CELL, materials, occupancies)

	-- What the ground ACTUALLY has now, read back from the voxels rather than assumed: a caller that
	-- builds at the height it asked for inherits any error this didn't notice, and the whole point of
	-- a pad is that the floor is where the structure thinks it is.
	local check = padRegion(site, PAD_CELL)
	local gotMaterials, gotOccupancies = terrain:ReadVoxels(check, PAD_CELL)
	local gotOrigin = check.CFrame.Position - check.Size / 2
	local achieved = columnGround(gotMaterials, gotOccupancies, 1, 1, (check.Size / PAD_CELL).Y, gotOrigin.Y)
	if achieved and math.abs(achieved - height) > 0.05 then
		height = achieved
	end

	local blend = options.retain and 0 or PAD_BLEND_MAX
	table.insert(MapTerrain.Pads, { outside = outside, margin = margin, blend = blend, height = height,
		site = site, size = size, material = painted, shape = options.shape })
	return height
end

-- Every registered pad's flat, written again. Anything that wrote terrain after a pad was made --
-- a lake, a landmark's own carving, a later prop -- is undone over the pad itself, and the count
-- returned says how many were re-asserted.
function MapTerrain.RewritePads(terrain)
	-- Over a copy, and with the registry restored afterwards: FlattenPad appends to MapTerrain.Pads
	-- when it succeeds, so walking the live list while writing into it never ends. That hung Studio
	-- for 280 seconds with no error the first time this ran.
	local pads = table.clone(MapTerrain.Pads)
	local written = 0
	for _, pad in ipairs(pads) do
		local height = MapTerrain.FlattenPad(pad.site, pad.size,
			{ shape = pad.shape, margin = pad.margin, material = pad.material, retain = true, height = pad.height })
		if height then
			written += 1
		end
	end
	MapTerrain.Pads = pads
	return written
end

-- Material, and only material: the occupancy of every voxel is copied through untouched, so this
-- cannot move ground under anything. Fill* would: it writes occupancy as well, and on ground lower
-- than the fill it fills rather than paints. Skips road corridors and made pads.
function MapTerrain.PaintPatch(site, size, material, options)
	options = options or {}
	if not RoadNetwork.SmoothMaterials[material] and not options.allowRough then
		return 0
	end
	local outside, reach = padShape(site, size, options)
	local region = padRegion(site, reach + PAD_CELL)
	local terrain = workspace.Terrain
	local materials, occupancies = terrain:ReadVoxels(region, PAD_CELL)
	local origin = region.CFrame.Position - region.Size / 2
	local count = region.Size / PAD_CELL
	local roads = MapTerrain._padRoads
	local from = options.from
	local painted = 0
	for ix = 1, count.X do
		local x = origin.X + (ix - 0.5) * PAD_CELL
		for iz = 1, count.Z do
			local z = origin.Z + (iz - 0.5) * PAD_CELL
			if outside(x, z) <= 0 and not (roads and roads:GroundAt(x, z, 0)) and not MapTerrain.PadAt(x, z) then
				local touched = false
				for iy = 1, count.Y do
					local was = materials[ix][iy][iz]
					if occupancies[ix][iy][iz] > 0 and was ~= Enum.Material.Air and was ~= Enum.Material.Water
						and (not from or was == from) then
						materials[ix][iy][iz] = material
						touched = true
					end
				end
				if touched then
					painted += 1
				end
			end
		end
	end
	terrain:WriteVoxels(region, PAD_CELL, materials, occupancies)
	return painted
end

--------------------------------------------------------------------------------
-- River
--------------------------------------------------------------------------------

-- 2D segment intersection: the point where a–b crosses c–d, or nil.
local function crossing(a, b, c, d)
	local r = Vector2.new(b.X - a.X, b.Z - a.Z)
	local s = Vector2.new(d.X - c.X, d.Z - c.Z)
	local denominator = r.X * s.Y - r.Y * s.X
	if math.abs(denominator) < 1e-6 then
		return nil
	end
	local qp = Vector2.new(c.X - a.X, c.Z - a.Z)
	local t = (qp.X * s.Y - qp.Y * s.X) / denominator
	local u = (qp.X * r.Y - qp.Y * r.X) / denominator
	if t < 0 or t > 1 or u < 0 or u > 1 then
		return nil
	end
	return Vector3.new(a.X + r.X * t, 0, a.Z + r.Y * t), t
end

-- Whether a river through these points would run alongside a road for a stretch (a mess of
-- bridges), rather than just crossing it. `roads` are straight road pieces { from, to }.
local function alongsideRoad(points, roads)
	for _, road in ipairs(roads) do
		local near = 0
		local ab = Vector2.new(road.to.X - road.from.X, road.to.Z - road.from.Z)
		local lengthSq = ab:Dot(ab)
		for _, point in ipairs(points) do
			local ap = Vector2.new(point.X - road.from.X, point.Z - road.from.Z)
			local tt = lengthSq > 0 and math.clamp(ap:Dot(ab) / lengthSq, 0, 1) or 0
			local closest = Vector2.new(road.from.X, road.from.Z) + ab * tt
			if (Vector2.new(point.X, point.Z) - closest).Magnitude < 30 then
				near += 1
			end
		end
		if near > 2 then
			return true
		end
	end
	return false
end

-- Tries for a river path: a chord across the map, off-centre, with a slow wiggle, that keeps
-- clear of every town's streets (buildings dodge the river on their own through MapSpace), every
-- plateau, and never runs alongside a road. A path right across the map is best; failing that,
-- the longest run in from the edge that fits, which then ends in a pond. Returns the points and
-- whether it ends in a pond.
-- Whether the river passes too close to a junction, bend or town street end (whose level approaches
-- leave no room for a bridge), or would end in a pond on top of a road.
local function crowdsRoads(points, endsInPond, network)
	if not network then
		return false
	end
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local abX, abZ = b.X - a.X, b.Z - a.Z
		local lengthSq = abX * abX + abZ * abZ
		for _, node in ipairs(network.nodes) do
			-- A junction and a town's street end both need their level approach clear of a bridge,
			-- and room for the road to climb to the bridge's height.
			local margin = 110
			local p = node.position
			local t = lengthSq > 0 and math.clamp(((p.X - a.X) * abX + (p.Z - a.Z) * abZ) / lengthSq, 0, 1) or 0
			if flatDistance(a.X + abX * t, a.Z + abZ * t, p.X, p.Z) < RIVER_WIDTH / 2 + margin then
				return true
			end
		end
	end
	if endsInPond and #points > 0 then
		local last = points[#points]
		for _, edge in ipairs(network.edges) do
			local ab = Vector2.new(edge.to.X - edge.from.X, edge.to.Z - edge.from.Z)
			local lengthSq = ab:Dot(ab)
			local ap = Vector2.new(last.X - edge.from.X, last.Z - edge.from.Z)
			local tt = lengthSq > 0 and math.clamp(ap:Dot(ab) / lengthSq, 0, 1) or 0
			if (Vector2.new(last.X, last.Z) - (Vector2.new(edge.from.X, edge.from.Z) + ab * tt)).Magnitude < RIVER_WIDTH * 1.6 + 70 then
				return true
			end
		end
	end
	return false
end

local function riverPath(radius, centers, townSpread, plateaus, network)
	local roads = network and network.edges or {}
	local keepOut = townSpread + 20
	local best, bestCount = nil, 7
	for _ = 1, RIVER_TRIES do
		local alpha = math.random() * math.pi * 2
		local direction = Vector3.new(math.cos(alpha), 0, math.sin(alpha))
		local normal = Vector3.new(-direction.Z, 0, direction.X)
		local offset = (0.25 + math.random() * 0.3) * radius * (math.random() < 0.5 and -1 or 1)
		local amplitude = 30 + math.random() * 45
		local cycles = 2 + math.random() * 2
		local phase, phase2 = math.random() * 6.28, math.random() * 6.28

		local points = {}
		local blocked = false
		local t = -1.18
		while t <= 1.18 and not blocked do
			local along = t * radius
			local lateral = offset + amplitude * math.sin(t * cycles + phase) + amplitude * 0.4 * math.sin(t * cycles * 2.7 + phase2)
			local point = direction * along + normal * lateral
			for _, center in ipairs(centers) do
				if flatDistance(center.X, center.Z, point.X, point.Z) < keepOut then
					blocked = true
				end
			end
			for _, plateau in ipairs(plateaus) do
				if flatDistance(plateau.X, plateau.Z, point.X, point.Z) < plateau.radius + RIVER_WIDTH / 2 + 60 then
					blocked = true
				end
			end
			if not blocked then
				table.insert(points, point)
			end
			t += RIVER_STEP / radius
		end

		if not alongsideRoad(points, roads) then
			if not blocked and not crowdsRoads(points, false, network) then
				return points, false
			end
			-- As a pond it loses its last couple of points (see River), so check it that way.
			local trimmed = table.clone(points)
			for _ = 1, 2 do
				if #trimmed > 9 then
					table.remove(trimmed)
				end
			end
			if #points > bestCount and not crowdsRoads(trimmed, true, network) then
				best, bestCount = points, #points
			end
		end
	end
	return best, best ~= nil
end

-- The river's course, planned before any ground is written: { points, pond } or nil when no path
-- fits (a very cramped map). Planning it this early is what lets the roads know where their bridges
-- are while their heights are still being worked out, so every bridge sits on a straight stretch of
-- road. `plateaus` from PlanPlateaus, `roads` the RoadNetwork.
function MapTerrain.PlanRiver(radius, centers, townSpread, plateaus, roads)
	local points, endsInPond = riverPath(radius, centers, townSpread, plateaus, roads)
	if not points then
		return nil
	end
	-- A river that can't get right across spreads into a pond where it stops -- a little short of
	-- what stopped it, so the pond doesn't reach the town's streets.
	if endsInPond then
		for _ = 1, 2 do
			if #points > 9 then
				table.remove(points)
			end
		end
	end
	return { points = points, pond = endsInPond }
end

-- Where a river through `points` crosses the roads: a list of { edge, point, span }, the span being
-- the length of bridge the crossing needs (longer the more obliquely the road meets the water).
-- Roads are all straight axis-aligned pieces, and a winding river can cross one piece more than
-- once, so every crossing is listed; the road merges crossings close together into one bridge.
function MapTerrain.RoadCrossings(points, roads)
	local list = {}
	for _, edge in ipairs(roads and roads.edges or {}) do
		local delta = Vector3.new(edge.to.X - edge.from.X, 0, edge.to.Z - edge.from.Z)
		if delta.Magnitude > 1 then
			local roadDirection = delta.Unit
			for index = 1, #points - 1 do
				local point = crossing(edge.from, edge.to, points[index], points[index + 1])
				if point then
					local riverDirection = (points[index + 1] - points[index]).Unit
					local sine = math.abs(roadDirection.X * riverDirection.Z - roadDirection.Z * riverDirection.X)
					table.insert(list, { edge = edge, point = point, span = math.min(120, (RIVER_WIDTH + 24) / math.max(sine, 0.5)) })
				end
			end
		end
	end
	return list
end

-- Carves the river `plan` (from PlanRiver, planned here if not given) and puts in its crossings.
-- Returns { points, width, bridges, roadCrossings, pond } or nil when there's no river. `roads` is
-- the RoadNetwork, which builds its own bridges (RoadNetwork:Build); footbridges and stepping
-- stones go in here, away from them.
function MapTerrain.River(terrain, parent, preset, radius, centers, townSpread, plateaus, roads, space, lootSpots, groundHeightAt, plan)
	plan = plan or MapTerrain.PlanRiver(radius, centers, townSpread, plateaus, roads)
	if not plan then
		return nil
	end
	local points, endsInPond = plan.points, plan.pond

	local width = RIVER_WIDTH
	local lift = MapTerrain.SurfaceLift
	local pondRadius = width * 1.6
	local last = points[#points]

	local function smooth(t)
		return t * t * (3 - 2 * t)
	end
	-- The ground's surface height wanted at distance `d` from the centre line.
	local function profile(d)
		if d <= RIVER_SHORE_IN then
			return RIVER_BED
		elseif d <= RIVER_SHORE_OUT then
			return RIVER_BED * (1 - smooth((d - RIVER_SHORE_IN) / (RIVER_SHORE_OUT - RIVER_SHORE_IN)))
		elseif d <= RIVER_BEACH_OUT then
			return RIVER_BEACH_TOP * smooth((d - RIVER_SHORE_OUT) / (RIVER_BEACH_OUT - RIVER_SHORE_OUT))
		end
		local e = d - RIVER_BEACH_OUT
		if e <= RIVER_BANK_GENTLE then
			return RIVER_BEACH_TOP + e * RIVER_BANK_GENTLE_GRADE
		end
		return RIVER_BEACH_TOP + RIVER_BANK_GENTLE * RIVER_BANK_GENTLE_GRADE + (e - RIVER_BANK_GENTLE) * RIVER_BANK_GRADE
	end

	-- What must not be dug out from under it: the road decks' approaches (a road keeps its own ground,
	-- and its verges blend down into the valley instead of standing on a cut), each plateau with its ramp,
	-- and the zipline landings off them. Anything built after this (towns, landmarks, props, lamps)
	-- reads the ground as it is left.
	local deckEdges, corridor = {}, 0
	if roads and roads.edges then
		corridor = roads:CorridorHalfWidth()
		for _, edge in ipairs(roads.edges) do
			if edge.bridges and #edge.bridges > 0 then
				table.insert(deckEdges, edge)
			end
		end
	end
	-- "under" inside a bridge deck's corridor, "beside" in the open valley next to it, or nil.
	local function nearDeck(x, z)
		for _, edge in ipairs(deckEdges) do
			local dx, dz = x - edge.from.X, z - edge.from.Z
			local along = dx * edge.dir.X + dz * edge.dir.Z
			local lateral = math.abs(dx * edge.dir.Z - dz * edge.dir.X)
			if lateral <= corridor + 60 then
				for _, span in ipairs(edge.bridges) do
					if along >= span.s0 - 1 and along <= span.s1 + 1 then
						return lateral <= corridor and "under" or "beside"
					end
				end
			end
		end
		return nil
	end
	local keepOut = {}
	for _, plateau in ipairs(plateaus or {}) do
		local rampLength = (plateau.height or 34) / math.tan(RAMP_ANGLE)
		table.insert(keepOut, { X = plateau.X, Z = plateau.Z, radius = plateau.radius + rampLength + 16 })
		if plateau.landing then
			table.insert(keepOut, { X = plateau.landing.X, Z = plateau.landing.Z, radius = 10 })
		end
	end
	local function keptOut(x, z)
		for _, circle in ipairs(keepOut) do
			if flatDistance(circle.X, circle.Z, x, z) < circle.radius then
				return true
			end
		end
		return false
	end

	-- Distance from the river's centre line (the pond, where it ends in one, widens it).
	local segments = {}
	for index = 1, #points - 1 do
		table.insert(segments, { a = points[index], b = points[index + 1] })
	end
	local function distanceTo(x, z, list)
		local best = math.huge
		for _, segment in ipairs(list) do
			local a, b = segment.a, segment.b
			local abX, abZ = b.X - a.X, b.Z - a.Z
			local lengthSq = abX * abX + abZ * abZ
			local t = lengthSq > 0 and math.clamp(((x - a.X) * abX + (z - a.Z) * abZ) / lengthSq, 0, 1) or 0
			local distance = flatDistance(a.X + abX * t, a.Z + abZ * t, x, z)
			if distance < best then
				best = distance
			end
		end
		if endsInPond then
			best = math.min(best, flatDistance(last.X, last.Z, x, z) - (pondRadius - width / 2))
		end
		return best
	end

	-- Written in 128-stud tiles, each only where the river reaches it.
	local TILE = 128
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	for _, point in ipairs(points) do
		minX, maxX = math.min(minX, point.X), math.max(maxX, point.X)
		minZ, maxZ = math.min(minZ, point.Z), math.max(maxZ, point.Z)
	end
	local pad = RIVER_REACH + pondRadius
	local x0 = math.floor((minX - pad) / TILE) * TILE
	local written = 0
	while x0 < maxX + pad do
		local z0 = math.floor((minZ - pad) / TILE) * TILE
		while z0 < maxZ + pad do
			local cx, cz = x0 + TILE / 2, z0 + TILE / 2
			local near = {}
			for _, segment in ipairs(segments) do
				if distanceTo(cx, cz, { segment }) < RIVER_REACH + TILE * 0.71 then
					table.insert(near, segment)
				end
			end
			local pondNear = endsInPond and flatDistance(last.X, last.Z, cx, cz) < RIVER_REACH + pondRadius + TILE * 0.71
			if #near > 0 or pondNear then
				local region = Region3.new(Vector3.new(x0, RIVER_BED - lift - 12, z0), Vector3.new(x0 + TILE, RIVER_TOP, z0 + TILE)):ExpandToGrid(4)
				local materials, occupancies = terrain:ReadVoxels(region, 4)
				local origin = region.CFrame.Position - region.Size / 2
				local count = region.Size / 4
				local changed = false
				for ix = 1, count.X do
					local x = origin.X + (ix - 0.5) * 4
					for iz = 1, count.Z do
						local z = origin.Z + (iz - 0.5) * 4
						local d = distanceTo(x, z, near)
						if d <= RIVER_REACH then
							-- The ground here now: its top solid voxel, read back as a surface height.
							local ground = nil
							for iy = count.Y, 1, -1 do
								local was = materials[ix][iy][iz]
								if occupancies[ix][iy][iz] > 0 and was ~= Enum.Material.Air and was ~= Enum.Material.Water then
									ground = origin.Y + (iy - 1) * 4 + occupancies[ix][iy][iz] * 4 + lift
									break
								end
							end
							ground = ground or (origin.Y + lift)
							local want = profile(d)
							local target, beach = nil, d <= RIVER_BEACH_OUT
							if d <= RIVER_SHORE_OUT then
								target = want
							elseif beach then
								-- Never above the profile, never down at the waterline where the land was lower.
								target = math.min(want, math.max(ground, 0.3))
							elseif not keptOut(x, z) then
								target = math.min(ground, want)
							end
							if target then
								local deck = nearDeck(x, z)
								if deck == "under" then
									-- Under a road bridge: the channel, kept clear of the deck's underside.
									local road = roads:GroundAt(x, z, target)
									if road then
										target = math.min(target, road - 2.4)
									end
								elseif deck == nil and roads then
									-- A road's own ground stays; its verge blends into the valley.
									local road = roads:GroundAt(x, z, target)
									if road then
										target, beach = road, false
									end
								end
							end
							local water = target and target < RIVER_WATER_TOP + lift and d <= RIVER_SHORE_OUT + 4
							if target and (math.abs(target - ground) > 0.05 or water or beach) then
								changed = true
								local fill = target - lift
								for iy = 1, count.Y do
									local bottom = origin.Y + (iy - 1) * 4
									local solid = math.clamp((fill - bottom) / 4, 0, 1)
									local was = materials[ix][iy][iz]
									if solid >= 0.5 or (solid > 0 and not (water and bottom < RIVER_WATER_TOP)) then
										occupancies[ix][iy][iz] = solid
										-- New ground, and the top of a beach, are sand; a cut bank keeps its own ground.
										if was == Enum.Material.Air or was == Enum.Material.Water or (beach and bottom + 8 > fill) then
											materials[ix][iy][iz] = beach and RIVER_BEACH or (was ~= Enum.Material.Air and was ~= Enum.Material.Water and was or preset.terrainMaterial)
										end
									elseif water and bottom < RIVER_WATER_TOP then
										materials[ix][iy][iz] = Enum.Material.Water
										occupancies[ix][iy][iz] = math.clamp((RIVER_WATER_TOP - bottom) / 4, 0, 1)
									else
										materials[ix][iy][iz] = Enum.Material.Air
										occupancies[ix][iy][iz] = 0
									end
								end
							end
						end
					end
				end
				if changed then
					terrain:WriteVoxels(region, 4, materials, occupancies)
				end
				written += 1
				if written % 3 == 0 then
					task.wait()
				end
			end
			z0 += TILE
		end
		x0 += TILE
	end

	if endsInPond then
		space:AddCircle(last.X, last.Z, pondRadius + 8)
	end
	for index = 1, #points - 1 do
		space:AddStrip(points[index], points[index + 1], width / 2 + 8)
	end

	-- Where the river runs through a hill, a crossing's ends would be inside the cliff: cut a
	-- notch through whatever stands over the crossing's footprint (the ground under it stays).
	local function notch(point, direction, span, halfWidth)
		-- Tall enough to clear the ground itself, not just the tallest hill standing on it. The
		-- old 80 studs assumed hills sat on a plane at zero; with the relief pass underneath them
		-- a map measures about 127 at its ceiling, so a crossing cut through high ground came out
		-- as a tunnel. Long enough past the crossing's ends that the smoothed cliff face can't
		-- lean over them.
		-- Its floor sits 2.5 over the river's datum, above the sand beach (RIVER_BEACH_TOP), so on the
		-- graded banks it cuts nothing and only a hill standing right at the water is notched.
		terrain:FillBlock(CFrame.lookAt(point + Vector3.new(0, 102.5, 0), point + Vector3.new(0, 102.5, 0) + direction),
			Vector3.new(halfWidth * 2, 200, span + 16), Enum.Material.Air)
	end

	-- Where the roads cross. The road lays its own surface right across and builds the bridge under
	-- it at its own height (RoadNetwork:Build), so on high ground a bridge spans a gorge rather than
	-- the road dropping into it -- which is why nothing is notched out for these. A movement item
	-- waits near one end of each.
	local bridges, roadCrossings = {}, MapTerrain.RoadCrossings(points, roads)
	for _, cross in ipairs(roadCrossings) do
		table.insert(bridges, cross.point)
		local spot = cross.point + cross.edge.dir * (cross.span / 2 - 6)
		local top = cross.edge.topAt and cross.edge.topAt(spot) or 0
		table.insert(lootSpots.item, Vector3.new(spot.X, top + 0.6, spot.Z))
	end

	-- Two footbridges and a line of stepping stones, spread along the river away from the roads.
	local function farFromBridges(point, margin)
		for _, bridge in ipairs(bridges) do
			if flatDistance(bridge.X, bridge.Z, point.X, point.Z) < margin then
				return false
			end
		end
		return true
	end
	local crossings = { "footbridge", "footbridge", "stones" }
	for _, kind in ipairs(crossings) do
		for _ = 1, 12 do
			local index = math.random(2, #points - 2)
			local point = points[index]:Lerp(points[index + 1], 0.5)
			if flatDistance(0, 0, point.X, point.Z) < radius * 0.95 and farFromBridges(point, 160) then
				local across = (points[index + 1] - points[index]).Unit
				across = Vector3.new(-across.Z, 0, across.X)
				if kind == "stones" then
					notch(point, across, width + 8, 8)
					MapDecor.SteppingStones(parent, point, across, width + 8)
				else
					notch(point, across, width + 14, 8)
					MapDecor.Footbridge(parent, point, across, width + 14)
					table.insert(lootSpots.item, point + Vector3.new(0, 1.6, 0))
				end
				table.insert(bridges, point)
				break
			end
		end
	end

	-- Guns along the banks every so often, on whichever side has room.
	for index = 2, #points - 1, 2 do
		local point = points[index]
		if flatDistance(0, 0, point.X, point.Z) < radius * 0.95 then
			local along = (points[index + 1] - points[index - 1]).Unit
			local side = Vector3.new(-along.Z, 0, along.X) * (math.random() < 0.5 and 1 or -1)
			local spot = point + side * (width / 2 + 12)
			if space:IsFree(spot.X, spot.Z, 3) then
				space:AddCircle(spot.X, spot.Z, 3)
				table.insert(lootSpots.weapon, Vector3.new(spot.X, groundHeightAt(spot.X, spot.Z), spot.Z))
			end
		end
	end

	return { points = points, width = width, bridges = bridges, roadCrossings = roadCrossings, pond = endsInPond }
end

-- Whether a point is in the river (its channel or shelf), for anything that walks the map
-- afterwards and shouldn't stand in the water.
function MapTerrain.InRiver(river, x, z, margin)
	if not river then
		return false
	end
	local reach = river.width / 2 + (margin or 6)
	local points = river.points
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local abX, abZ = b.X - a.X, b.Z - a.Z
		local lengthSq = abX * abX + abZ * abZ
		local t = lengthSq > 0 and math.clamp(((x - a.X) * abX + (z - a.Z) * abZ) / lengthSq, 0, 1) or 0
		if flatDistance(a.X + abX * t, a.Z + abZ * t, x, z) < reach then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Patches and snow
--------------------------------------------------------------------------------

-- Patches of other ground per map: { material, count, size } — `size` is the side of the
-- patch, which is laid as three overlapping boxes so it isn't a neat square.
MapTerrain.Patches = {
	SahurSprings = {
		{ Enum.Material.LeafyGrass, 4, 190 },
		{ Enum.Material.Mud, 2, 110 },
		{ Enum.Material.Ground, 2, 130 },
	},
	TralalaTown = {
		{ Enum.Material.Asphalt, 3, 110 },
		{ Enum.Material.Grass, 3, 150 },
		{ Enum.Material.Concrete, 2, 100 },
	},
	BombardiroBay = {
		{ Enum.Material.Salt, 2, 170 },
		{ Enum.Material.Sandstone, 3, 130 },
		{ Enum.Material.Grass, 2, 120 },
	},
	RotRidge = {
		{ Enum.Material.Basalt, 3, 140 },
		{ Enum.Material.Slate, 3, 120 },
		{ Enum.Material.Ground, 2, 130 },
	},
	PatapimPlains = {
		{ Enum.Material.Ground, 3, 150 },
		{ Enum.Material.Mud, 2, 110 },
		{ Enum.Material.Grass, 3, 170 },
	},
}

-- Above this height the highland map is snow.
MapTerrain.SnowLine = { RotRidge = 24 }

local function replaceBox(terrain, x, z, size, from, to)
	local half = size / 2
	local region = Region3.new(Vector3.new(x - half, -16, z - half), Vector3.new(x + half, 70, z + half)):ExpandToGrid(4)
	terrain:ReplaceMaterial(region, 4, from, to)
end

function MapTerrain.PaintPatches(terrain, preset, radius, centers, townSpread)
	local base = preset.terrainMaterial
	local list = MapTerrain.Patches[preset.id] or {}
	for _, entry in ipairs(list) do
		local material, count, size = entry[1], entry[2], entry[3]
		for _ = 1, count do
			for _ = 1, 12 do
				local angle = math.random() * math.pi * 2
				local distance = math.sqrt(math.random()) * radius * 0.9
				local x, z = math.cos(angle) * distance, math.sin(angle) * distance
				local clear = true
				for _, center in ipairs(centers) do
					if flatDistance(center.X, center.Z, x, z) < townSpread + size / 2 then
						clear = false
						break
					end
				end
				if clear then
					replaceBox(terrain, x, z, size, base, material)
					for _ = 1, 2 do
						local dx, dz = (math.random() - 0.5) * size * 0.8, (math.random() - 0.5) * size * 0.8
						replaceBox(terrain, x + dx, z + dz, size * 0.7, base, material)
					end
					break
				end
			end
		end
		task.wait()
	end

	local snowLine = MapTerrain.SnowLine[preset.id]
	if snowLine then
		local extent = radius * 1.2
		local region = Region3.new(Vector3.new(-extent, snowLine, -extent), Vector3.new(extent, 90, extent)):ExpandToGrid(4)
		terrain:ReplaceMaterial(region, 4, base, Enum.Material.Snow)
		terrain:ReplaceMaterial(region, 4, Enum.Material.Basalt, Enum.Material.Snow)
		terrain:ReplaceMaterial(region, 4, Enum.Material.Slate, Enum.Material.Snow)
	end
end

--------------------------------------------------------------------------------
-- Clouds
--------------------------------------------------------------------------------

MapTerrain.Clouds = {
	SahurSprings = { cover = 0.42, density = 0.35, color = Color3.fromRGB(252, 252, 255) },
	TralalaTown = { cover = 0.55, density = 0.5, color = Color3.fromRGB(255, 226, 200) },
	BombardiroBay = { cover = 0.18, density = 0.2, color = Color3.fromRGB(255, 255, 255) },
	RotRidge = { cover = 0.78, density = 0.7, color = Color3.fromRGB(190, 200, 215) },
	PatapimPlains = { cover = 0.5, density = 0.4, color = Color3.fromRGB(255, 240, 220) },
}

function MapTerrain.SetClouds(terrain, mapId)
	local existing = terrain:FindFirstChildOfClass("Clouds")
	local settings = mapId and MapTerrain.Clouds[mapId]
	if not settings then
		if existing then
			existing:Destroy()
		end
		return
	end
	local clouds = existing or Instance.new("Clouds")
	clouds.Cover = settings.cover
	clouds.Density = settings.density
	clouds.Color = settings.color
	clouds.Enabled = true
	clouds.Parent = terrain
end

return MapTerrain
