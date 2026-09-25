-- Town buildings: walls with real window openings, floors with a stairwell, stairs, roofs,
-- furnished interiors, facades, doorway and rooftop decor, and the crate or barrels out back.
-- MapGenerator's buildTown decides where each building goes and calls RollPlan, BuildBuilding
-- and BuildCrate; everything about what a building IS lives here. (Split out of MapGenerator and
-- MapDecor on 2026-09-16, moved verbatim, so buildings and the town/road layout can be worked on
-- independently. A fixed-seed build of whole maps produced identical parts before and after.)
--
-- Walls are built as bands (sill / window piers / lintel) rather than one slab, so windows
-- are genuine holes you can see and shoot through. Floors above the ground are built as two
-- segments leaving a stairwell gap, so buildings are actually enterable and climbable —
-- which is what makes holding one worth anything in a battle royale.

local HazardService = require(script.Parent:WaitForChild("HazardService"))
local MapDecor = require(script.Parent:WaitForChild("MapDecor"))
local MapSpace = require(script.Parent:WaitForChild("MapSpace"))

local MapBuildings = {}

local FLOOR_HEIGHT = 15
local WALL_THICKNESS = 1.4
local SILL_HEIGHT = 3.5
local WINDOW_TOP = 8.5
local WINDOW_WIDTH = 5
local DOOR_WIDTH = 8
local STAIR_WIDTH = 8
local STAIR_RUN = 15
local STAIR_STEPS = 10
-- Clear floor at the foot of a flight, between the back wall and the first step. Without it the
-- bottom step sits against the wall with nowhere to stand, so the only way on is a sideways hop
-- part-way up. The well above the stairs grows by the same amount, so the top of the flight still
-- comes out level with the floor edge.
local STAIR_LANDING = 3
-- Clear floor past the top step before anything may stand in the way: no partition wall and no
-- furniture, so you can step off a flight and turn.
local STAIR_EXIT = 5
-- The pitch of a house's roof. The chimney and the top floor's ceiling light are fixed to the roof
-- boards, so they work from the same angle.
local ROOF_PITCH = math.rad(28)
local ROOF_THICKNESS = 1
-- How far an interior partition stops short of the side walls (see buildBuilding).
local PARTITION_WALL_GAP = 0.02
-- How far a building's base carries on below grade. The plinth, the door step and threshold and a
-- loading dock are solid down to here, so where the ground at the edge of a lot sits a little low
-- (terrain voxels wobble up to half a stud at a hard edge) it shows foundation, not a gap.
local FOUNDATION_DEPTH = 2.5
-- The first steps of a flight stand on the floor as solid blocks; above them the treads run on over
-- the stairwell with a sloped soffit underneath. The floor above covers the solid part (that's the
-- landing at the foot of the next flight up), so the well is open only over the treads.
local STAIR_SOLID_STEPS = 4
local SOFFIT_THICKNESS = 1.2
-- The balustrade along the open side of a stairwell: tall enough to stop a fall, low enough to
-- shoot over, with a handrail cap.
local RAIL_HEIGHT = 3.2
local RAIL_THICKNESS = 0.3
local HANDRAIL_OVERHANG = 0.1

-- What the parts being built right now are called (Wall, Floor, Sill…), so the build check's
-- clipping and z-fight reports name the piece rather than saying "Part". Builders set it.
local currentName = "Part"

local function makePart(parent, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = currentName
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Each building draws from its own generator, seeded by a single math.random when buildBuilding
-- starts. So a change inside one building (another stair, a wall moved) never reshuffles every
-- building built after it; RollPlan and BuildCrate still use math.random, as the town layout does.
local rng = Random.new()

-- math.random's calling convention: no arguments for [0, 1), two for an integer in [m, n].
local function random(m, n)
	if m == nil then
		return rng:NextNumber()
	end
	return rng:NextInteger(m, n)
end

local function pick(list)
	return list[random(1, #list)]
end

-- Trim is decoration: it never collides or stops a bullet, so it can't snag movement or get in
-- the way of a shot through a window.
local function trim(parent, size, cframe, color, material)
	local part = makePart(parent, size, cframe, color, material)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

-- Where buildWall puts the windows in a wall `length` long and `height` tall: each one's centre, as
-- an offset from the wall's middle. The furniture layout reads the same list, so it always knows
-- where the openings are.
local function windowOffsets(length, height)
	local windows = {}
	if height <= WINDOW_TOP + 1 then
		return windows
	end
	local bays = math.max(1, math.floor(length / 13))
	local pierWidth = (length - bays * WINDOW_WIDTH) / (bays + 1)
	for index = 1, bays do
		table.insert(windows, -length / 2 + index * pierWidth + (index - 1) * WINDOW_WIDTH + WINDOW_WIDTH / 2)
	end
	return windows
end

--------------------------------------------------------------------------------
-- Doorway and rooftop decor
--------------------------------------------------------------------------------

-- These were MapDecor.Building and its helpers. They keep MapDecor's own part factory (an optional
-- shape, SmoothPlastic by default) and its separate name, so every part comes out as it did there.
local decorName = "Part"
-- The rooftop unit being built, when it can be shot apart (#56): its parts are tagged
-- `Destructible = "RoofProp:B<n>"`, one pool for DestructibleService.
local decorGroup = nil
local decorSerial = 0

local function roofProp(build)
	return function(...)
		decorSerial += 1
		decorGroup = "RoofProp:B" .. decorSerial
		local results = table.pack(pcall(build, ...))
		decorGroup = nil
		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end
end

local function decorPart(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	part.Name = decorName
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if decorGroup then
		part:SetAttribute("Destructible", decorGroup)
	end
	part.Parent = parent
	return part
end

local function clutter(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

-- Upright cylinder standing on `position`. Cylinder parts run along X, hence the quarter turn.
local function column(parent, height, diameter, position, color, material)
	return decorPart(parent, Vector3.new(height, diameter, diameter),
		CFrame.new(position + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		color, material, Enum.PartType.Cylinder)
end

local AWNING_COLORS = {
	Color3.fromRGB(196, 60, 60), Color3.fromRGB(60, 120, 180), Color3.fromRGB(70, 150, 96),
	Color3.fromRGB(230, 170, 60), Color3.fromRGB(150, 80, 160),
}

local function acUnit(parent, base)
	decorPart(parent, Vector3.new(6, 3.6, 5), CFrame.new(base + Vector3.new(0, 1.8, 0)), Color3.fromRGB(176, 180, 186), Enum.Material.Metal)
	clutter(decorPart(parent, Vector3.new(0.4, 3.6, 3.6), CFrame.new(base + Vector3.new(0, 3.8, 0)) * CFrame.Angles(0, 0, math.pi / 2),
		Color3.fromRGB(60, 62, 68), Enum.Material.DiamondPlate, Enum.PartType.Cylinder))
end
acUnit = roofProp(acUnit)

local function waterTank(parent, base)
	for _, x in ipairs({ -2.2, 2.2 }) do
		for _, z in ipairs({ -2.2, 2.2 }) do
			decorPart(parent, Vector3.new(0.6, 5, 0.6), CFrame.new(base + Vector3.new(x, 2.5, z)), Color3.fromRGB(90, 70, 52), Enum.Material.Wood)
		end
	end
	column(parent, 6, 6.4, base + Vector3.new(0, 5, 0), Color3.fromRGB(130, 96, 66), Enum.Material.WoodPlanks)
	column(parent, 1, 4.4, base + Vector3.new(0, 11, 0), Color3.fromRGB(80, 80, 86), Enum.Material.Metal)
end
waterTank = roofProp(waterTank)

local function antenna(parent, base)
	column(parent, 10, 0.3, base, Color3.fromRGB(150, 150, 156), Enum.Material.Metal)
	for index, width in ipairs({ 4, 3, 2 }) do
		clutter(decorPart(parent, Vector3.new(width, 0.2, 0.2), CFrame.new(base + Vector3.new(0, 5 + index * 1.6, 0)),
			Color3.fromRGB(150, 150, 156), Enum.Material.Metal))
	end
end
antenna = roofProp(antenna)

-- Doorway trim and an awning over the ground-floor door (always centred on the -Z wall), a
-- chimney on pitched roofs, and rooftop clutter on flat ones. The roof clutter stays out of the
-- middle, where a rooftop chest spawns.
local function decorateBuilding(model, origin, archetype, width, depth, topY, wallColor, doorWidth)
	local frontZ = origin.Z - depth / 2
	local trim = wallColor:Lerp(Color3.new(0, 0, 0), 0.4)

	for _, side in ipairs({ -1, 1 }) do
		decorPart(model, Vector3.new(0.8, 10, 0.6), CFrame.new(origin.X + side * (doorWidth / 2 + 0.4), origin.Y + 5.5, frontZ - 1),
			trim, Enum.Material.Wood)
	end
	decorPart(model, Vector3.new(doorWidth + 1.6, 0.8, 0.6), CFrame.new(origin.X, origin.Y + 10.9, frontZ - 1), trim, Enum.Material.Wood)

	if random() < 0.7 then
		decorPart(model, Vector3.new(doorWidth + 5, 0.5, 5),
			CFrame.new(origin.X, origin.Y + 12, frontZ - 2.8) * CFrame.Angles(math.rad(-14), 0, 0),
			pick(AWNING_COLORS), Enum.Material.Fabric)
	end

	if archetype == "house" then
		if random() < 0.75 then
			-- On the ridge, a quarter of the way in from one gable. Only there can a flat-bottomed stack
			-- start inside the roof boards all the way round: anywhere down a slope the roof falls away
			-- across the stack's width faster than the boards are thick, so its base would either show
			-- in the attic on the uphill side or stand clear of the roof on the downhill side. It rises
			-- a fixed height above the ridge, so small houses and big ones get the same-looking stack.
			local x = origin.X + (random() < 0.5 and -1 or 1) * width * 0.26
			local z = origin.Z
			local ridgeY = topY + math.tan(ROOF_PITCH) * depth / 2
			local bottom = ridgeY - ROOF_THICKNESS / 2 / math.cos(ROOF_PITCH) + 0.03
			local top = ridgeY + 4.4
			decorName = "Chimney"
			decorPart(model, Vector3.new(4, top - bottom, 4), CFrame.new(x, (top + bottom) / 2, z), Color3.fromRGB(140, 82, 66), Enum.Material.Brick)
			decorName = "ChimneyCap"
			decorPart(model, Vector3.new(5, 0.8, 5), CFrame.new(x, top + 0.4, z), Color3.fromRGB(90, 86, 84), Enum.Material.Concrete)
			decorName = "Part"
		end
		return
	end

	local corners = {
		Vector3.new(-width * 0.28, 0, -depth * 0.28),
		Vector3.new(width * 0.28, 0, depth * 0.28),
		Vector3.new(width * 0.28, 0, -depth * 0.28),
	}
	for index = 1, random(1, 2) do
		local base = Vector3.new(origin.X + corners[index].X, topY + 0.5, origin.Z + corners[index].Z)
		if random() < 0.55 then
			acUnit(model, base)
		else
			waterTank(model, base)
		end
	end
	if random() < 0.5 then
		antenna(model, Vector3.new(origin.X - width * 0.28, topY + 0.5, origin.Z + depth * 0.28))
	end
end

--------------------------------------------------------------------------------
-- Walls
--------------------------------------------------------------------------------

-- Builds one wall as horizontal bands with window gaps punched through the middle band.
-- `axis` is "x" (wall runs along X) or "z". `doorGap` cuts a full-height opening centre.
-- Returns each window's centre as an offset along the wall, for the facade detail.
local function buildWall(parent, axis, cx, cz, length, baseY, height, mat, color, doorGap, withWindows)
	currentName = "Wall"
	local function slab(offset, segLength, y, segHeight)
		if segLength <= 0.5 or segHeight <= 0.5 then
			return
		end
		local size = axis == "x"
			and Vector3.new(segLength, segHeight, WALL_THICKNESS)
			or Vector3.new(WALL_THICKNESS, segHeight, segLength)
		local position = axis == "x"
			and Vector3.new(cx + offset, y + segHeight / 2, cz)
			or Vector3.new(cx, y + segHeight / 2, cz + offset)
		makePart(parent, size, CFrame.new(position), color, mat)
	end

	local half = length / 2
	local lintelY = math.min(WINDOW_TOP, height)
	local windows = {}

	if doorGap then
		-- Bottom and middle bands split around a full-height doorway.
		local side = (length - DOOR_WIDTH) / 2
		slab(-half + side / 2, side, baseY, lintelY)
		slab(half - side / 2, side, baseY, lintelY)
	elseif withWindows and height > WINDOW_TOP + 1 then
		local bays = math.max(1, math.floor(length / 13))
		local pierWidth = (length - bays * WINDOW_WIDTH) / (bays + 1)

		slab(0, length, baseY, SILL_HEIGHT)

		local cursor = -half
		for index = 1, bays + 1 do
			slab(cursor + pierWidth / 2, pierWidth, baseY + SILL_HEIGHT, lintelY - SILL_HEIGHT)
			cursor += pierWidth + WINDOW_WIDTH
		end
		windows = windowOffsets(length, height)
	else
		slab(0, length, baseY, lintelY)
	end

	if height > lintelY then
		slab(0, length, baseY + lintelY, height - lintelY)
	end

	currentName = "Part"
	return windows
end

--------------------------------------------------------------------------------
-- Stairs
--------------------------------------------------------------------------------

-- One flight, from the floor at `baseY` up to the next one, climbing toward +Z from (originX, originZ)
-- at the foot. The first STAIR_SOLID_STEPS are solid blocks down to the floor; the rest are treads
-- over the stairwell, with the flight below them underneath.
local function buildStairs(parent, originX, originZ, baseY, mat, color)
	local rise = FLOOR_HEIGHT / STAIR_STEPS
	local run = STAIR_RUN / STAIR_STEPS

	currentName = "Stair"
	for step = 1, STAIR_STEPS do
		local z = originZ + run * (step - 0.5)
		if step <= STAIR_SOLID_STEPS then
			makePart(parent, Vector3.new(STAIR_WIDTH, rise * step, run), CFrame.new(originX, baseY + rise * step / 2, z), color, mat)
		else
			makePart(parent, Vector3.new(STAIR_WIDTH, rise, run), CFrame.new(originX, baseY + rise * (step - 0.5), z), color, mat)
		end
	end

	-- The soffit: a sloped board under the treads, so the flight reads as one built piece from below
	-- instead of a row of floating slabs. Its top face runs along the line through every tread's
	-- front-bottom and back-top corners, so above that line it's inside the treads and below it's
	-- the smooth underside. It starts one step back, inside the last solid block, and ends inside
	-- the edge of the floor above, so neither end shows a seam. It's a little narrower than the
	-- flight so its sides never share a plane with the treads' sides.
	local startStep = STAIR_SOLID_STEPS - 1
	local topStart = Vector3.new(originX, baseY + rise * startStep, originZ + run * startStep)
	local topEnd = Vector3.new(originX, baseY + FLOOR_HEIGHT, originZ + STAIR_RUN)
	local along = topEnd - topStart
	local up = Vector3.new(0, along.Z, -along.Y).Unit
	currentName = "StairSoffit"
	makePart(parent, Vector3.new(STAIR_WIDTH - 0.3, SOFFIT_THICKNESS, along.Magnitude),
		CFrame.fromMatrix((topStart + topEnd) / 2 - up * (SOFFIT_THICKNESS / 2), Vector3.xAxis, up), color, mat)
	currentName = "Part"
end

-- A floor slab, fitted inside the walls. Above the ground floor of a building with stairs it leaves
-- the stairwell in the -X/-Z corner, laid out along Z from the front wall:
--
--   landing  over the flight below's solid steps, and the foot of the flight going up from here
--   well     open over the flight below's treads, exactly as wide as the flight
--   main     from the top step of the flight below to the back wall, flush with that step
--
-- and beside all three, a side slab flush with the flight's open side, which is how you walk from
-- the top of one flight round to the foot of the next. A balustrade with a handrail runs along the
-- well's open side, and across its front too on the top floor, where no flight covers that edge.
local function buildFloorWithWell(parent, origin, width, depth, y, mat, color, leaveWell, trimColor, topFloor)
	local halfW, halfD = width / 2, depth / 2
	currentName = "Floor"
	-- The slab fits inside the walls (which are centred on the building's edges) rather than
	-- running out through them: a slab that reaches into a wall puts its top in the same plane
	-- as the wall top below it, and the two flicker along every floor line.
	local inset = WALL_THICKNESS / 2

	if not leaveWell then
		makePart(parent, Vector3.new(width - 2 * inset, 1, depth - 2 * inset), CFrame.new(origin.X, y, origin.Z), color, mat)
		currentName = "Part"
		return
	end

	-- Offsets from the building's -X and -Z edges (the flight's foot is at 1 + STAIR_LANDING).
	local flightX1 = 1 + STAIR_WIDTH
	local wellZ0 = 1 + STAIR_LANDING + STAIR_RUN * STAIR_SOLID_STEPS / STAIR_STEPS
	local wellZ1 = 1 + STAIR_LANDING + STAIR_RUN
	local left, front = origin.X - halfW, origin.Z - halfD

	local mainLength = depth - wellZ1 - inset
	makePart(parent,
		Vector3.new(width - 2 * inset, 1, mainLength),
		CFrame.new(origin.X, y, front + wellZ1 + mainLength / 2),
		color, mat)
	local sideWidth = width - flightX1 - inset
	local sideLength = wellZ1 - inset
	makePart(parent,
		Vector3.new(sideWidth, 1, sideLength),
		CFrame.new(left + flightX1 + sideWidth / 2, y, front + inset + sideLength / 2),
		color, mat)
	local landingWidth = flightX1 - inset
	local landingLength = wellZ0 - inset
	makePart(parent,
		Vector3.new(landingWidth, 1, landingLength),
		CFrame.new(left + inset + landingWidth / 2, y, front + inset + landingLength / 2),
		color, mat)

	-- A header beam under the slab edge at the top of the well, the way a real stairwell is framed.
	-- It also covers the top of the flight's soffit, which is thicker than the slab is deep.
	currentName = "StairHeader"
	makePart(parent,
		Vector3.new(flightX1 - inset, 0.8, 1),
		CFrame.new(left + inset + (flightX1 - inset) / 2, y - 0.5 - 0.4, front + wellZ1 + 0.5),
		color, mat)

	-- The balustrade stands on the side slab's edge (and, on the top floor, the landing's), and the
	-- handrail caps sit on top of it. The two runs meet at the corner without overlapping: the
	-- side run starts where the front run ends, for the walls and for the caps alike, so no two
	-- tops share a patch of the same plane.
	local floorTop = y + 0.5
	local capY = floorTop + RAIL_HEIGHT + 0.125
	local capWidth = RAIL_THICKNESS + 2 * HANDRAIL_OVERHANG
	local sideRailZ0 = wellZ0
	local sideCapZ0 = topFloor and wellZ0 - RAIL_THICKNESS - HANDRAIL_OVERHANG or wellZ0
	if topFloor then
		local frontLength = flightX1 + RAIL_THICKNESS - inset
		currentName = "Railing"
		makePart(parent, Vector3.new(frontLength, RAIL_HEIGHT, RAIL_THICKNESS),
			CFrame.new(left + inset + frontLength / 2, floorTop + RAIL_HEIGHT / 2, front + wellZ0 - RAIL_THICKNESS / 2),
			color, mat)
		currentName = "Handrail"
		local capLength = flightX1 - HANDRAIL_OVERHANG - inset
		trim(parent, Vector3.new(capLength, 0.25, capWidth),
			CFrame.new(left + inset + capLength / 2, capY, front + wellZ0 - RAIL_THICKNESS / 2),
			trimColor, Enum.Material.Wood)
	end
	currentName = "Railing"
	makePart(parent, Vector3.new(RAIL_THICKNESS, RAIL_HEIGHT, wellZ1 - sideRailZ0),
		CFrame.new(left + flightX1 + RAIL_THICKNESS / 2, floorTop + RAIL_HEIGHT / 2, front + (sideRailZ0 + wellZ1) / 2),
		color, mat)
	currentName = "Handrail"
	trim(parent, Vector3.new(capWidth, 0.25, wellZ1 - sideCapZ0),
		CFrame.new(left + flightX1 + RAIL_THICKNESS / 2, capY, front + (sideCapZ0 + wellZ1) / 2),
		trimColor, Enum.Material.Wood)
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- Roofs
--------------------------------------------------------------------------------

local function buildPitchedRoof(parent, origin, width, depth, y, mat, color)
	local pitch = ROOF_PITCH
	local slope = (depth / 2) / math.cos(pitch)

	currentName = "Roof"
	for _, dir in ipairs({ 1, -1 }) do
		local part = makePart(parent,
			Vector3.new(width + 3, ROOF_THICKNESS, slope),
			CFrame.new(origin.X, y + math.tan(pitch) * (depth / 4), origin.Z + dir * depth / 4)
				* CFrame.Angles(dir * pitch, 0, 0),
			color, mat)
		part.TopSurface = Enum.SurfaceType.Smooth
	end

	-- Gable ends: a triangle of wall under each end of the roof, built from two wedges back to
	-- back. (A plain block here stuck up past the slopes at every corner of the roof.) A wedge is
	-- full height on its local +Z side, so each is turned to put that side at the ridge.
	local rise = math.tan(pitch) * depth / 2
	for _, dir in ipairs({ 1, -1 }) do
		for _, halfSide in ipairs({ 1, -1 }) do
			local wedge = Instance.new("WedgePart")
			wedge.Name = "Gable"
			wedge.Size = Vector3.new(1, rise, depth / 2)
			wedge.CFrame = CFrame.new(origin.X + dir * width / 2, y + rise / 2, origin.Z + halfSide * depth / 4)
				* CFrame.Angles(0, halfSide == 1 and math.pi or 0, 0)
			wedge.Color = color
			wedge.Material = mat
			wedge.Anchored = true
			wedge.TopSurface = Enum.SurfaceType.Smooth
			wedge.BottomSurface = Enum.SurfaceType.Smooth
			wedge.Parent = parent
		end
	end

	-- A ridge cap along the top, and a diamond vent in each gable.
	currentName = "RidgeCap"
	makePart(parent, Vector3.new(width + 3.4, 0.5, 1.1),
		CFrame.new(origin.X, y + math.tan(pitch) * depth / 2 + 0.15, origin.Z), color:Lerp(Color3.new(0, 0, 0), 0.25), mat)
	currentName = "GableVent"
	for _, dir in ipairs({ 1, -1 }) do
		trim(parent, Vector3.new(0.3, 1.4, 1.4),
			CFrame.new(origin.X + dir * (width / 2 + 0.55), y + math.tan(pitch) * depth / 4, origin.Z) * CFrame.Angles(math.pi / 4, 0, 0),
			Color3.fromRGB(40, 40, 46), Enum.Material.Metal)
	end
	currentName = "Part"
end

-- A frame on the underside of a pitched roof, directly under (x, z): on the lower face of whichever
-- slope covers that point, with that slope's axes (its Y points out of the roof). Things fixed to
-- the roof boards from inside are placed from this.
local function roofUnderside(origin, depth, topY, x, z)
	local side = z >= origin.Z and 1 or -1
	local centreZ = origin.Z + side * depth / 4
	local slab = CFrame.new(origin.X, topY + math.tan(ROOF_PITCH) * depth / 4, centreZ) * CFrame.Angles(side * ROOF_PITCH, 0, 0)
	local along = (z - centreZ + side * ROOF_THICKNESS / 2 * math.sin(ROOF_PITCH)) / math.cos(ROOF_PITCH)
	return slab * CFrame.new(x - origin.X, -ROOF_THICKNESS / 2, along)
end

local function buildFlatRoof(parent, origin, width, depth, y, mat, color)
	-- The slab sits a hair higher than the walls' and pilasters' tops, which end inside it,
	-- so its top is the only face in that plane.
	currentName = "Roof"
	makePart(parent, Vector3.new(width + 2, 1, depth + 2), CFrame.new(origin.X, y + 0.06, origin.Z), color, mat)

	-- Parapet, so rooftops are usable cover.
	local h = 4
	currentName = "Parapet"
	makePart(parent, Vector3.new(width + 2, h, 1), CFrame.new(origin.X, y + h / 2, origin.Z + depth / 2), color, mat)
	makePart(parent, Vector3.new(width + 2, h, 1), CFrame.new(origin.X, y + h / 2, origin.Z - depth / 2), color, mat)
	makePart(parent, Vector3.new(1, h, depth + 2), CFrame.new(origin.X + width / 2, y + h / 2, origin.Z), color, mat)
	makePart(parent, Vector3.new(1, h, depth + 2), CFrame.new(origin.X - width / 2, y + h / 2, origin.Z), color, mat)

	-- Coping along the top of the parapet: solid, so standing on the edge feels right.
	local coping = color:Lerp(Color3.new(1, 1, 1), 0.2)
	currentName = "Coping"
	for _, dir in ipairs({ 1, -1 }) do
		makePart(parent, Vector3.new(width + 2.6, 0.3, 1.5), CFrame.new(origin.X, y + h + 0.15, origin.Z + dir * depth / 2), coping, Enum.Material.Concrete)
		makePart(parent, Vector3.new(1.5, 0.3, depth + 2.6), CFrame.new(origin.X + dir * width / 2, y + h + 0.15, origin.Z), coping, Enum.Material.Concrete)
	end
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- Interior cover
--------------------------------------------------------------------------------

-- How much floor each stockroom piece (towers and warehouses) needs, as a radius.
local FURNITURE_RADIUS = {
	crates = 5.3, barrel = 3.7, table = 6.4, shelf = 4.8,
}
local RUG_COLORS = {
	Color3.fromRGB(150, 50, 60), Color3.fromRGB(50, 80, 140), Color3.fromRGB(190, 150, 70), Color3.fromRGB(70, 120, 90),
}
-- The clear space a crate stack leaves under the ceiling.
local CRATE_HEADROOM = 1.5

-- A tower or warehouse floor keeps the plain stockroom set it always had.
local GENERIC_KINDS = { { "crates", 0.4 }, { "barrel", 0.22 }, { "table", 0.2 }, { "shelf", 0.18 } }
local ART_COLORS = {
	Color3.fromRGB(210, 190, 150), Color3.fromRGB(90, 120, 150), Color3.fromRGB(150, 90, 90), Color3.fromRGB(120, 140, 110),
}

-- The floor kept clear inside every opening. In front of each window: its width plus VAULT_MARGIN
-- either side, VAULT_DEPTH into the room -- a vault lands there, and nothing standing in it hides the
-- window (Oliver, 2026-09-24: "walls being placed in front of windows"). Inside the entry: the door's
-- width plus DOOR_MARGIN either side (past the door-frame jambs), DOOR_LANE deep.
local VAULT_MARGIN = 0.6
local VAULT_DEPTH = 4.5
local DOOR_MARGIN = 1.2
local DOOR_LANE = 7
-- The gap between a wall-standing piece's back and the wall's face, clear of the skirting.
local WALL_GAP = 0.35
-- Freestanding pieces keep this much floor round them, so there is always a way past.
local WALKWAY = 1.2

-- Cumulative pick from a { {kind, weight}, ... } pool.
local function rollKind(pool)
	local roll, total = random(), 0
	for _, entry in ipairs(pool) do
		total += entry[2]
		if roll < total then
			return entry[1]
		end
	end
	return pool[#pool][1]
end

-- Which of the four lived-in purposes (or nil, for a tower/warehouse floor) this floor of a house
-- gets. Ground floor is the sociable half of the house; upper floors sleep and wash.
local function roomPurpose(archetype, floor)
	if archetype ~= "house" then
		return nil
	end
	if floor == 0 then
		local roll = random()
		return (roll < 0.42 and "kitchen") or (roll < 0.8 and "living") or "bathroom"
	end
	return random() < 0.85 and "bedroom" or "bathroom"
end

-- A clear spot on this floor, claimed. `fixedZ` pins it to one row (against the back wall).
local function freeSpot(room, origin, reachX, reachZ, radius, fixedZ)
	for _ = 1, 12 do
		local x = origin.X + (random() * 2 - 1) * reachX
		local z = fixedZ or origin.Z + (random() * 2 - 1) * reachZ
		if room:IsFree(x, z, radius) then
			room:AddCircle(x, z, radius)
			return x, z
		end
	end
	return nil
end

-- Whether an axis-aligned footprint is clear in the floor's MapSpace, which only answers circles:
-- a grid of small circles covering it, none reaching more than a fifth of a stud past its edge.
local function rectFree(room, x, z, halfX, halfZ)
	local nx, nz = math.max(1, math.ceil(halfX * 2 / 0.8)), math.max(1, math.ceil(halfZ * 2 / 0.8))
	local cellX, cellZ = halfX * 2 / nx, halfZ * 2 / nz
	local radius = math.sqrt(cellX * cellX + cellZ * cellZ) / 2
	for i = 1, nx do
		for k = 1, nz do
			if not room:IsFree(x - halfX + (i - 0.5) * cellX, z - halfZ + (k - 0.5) * cellZ, radius) then
				return false
			end
		end
	end
	return true
end

-- The four walls' inner faces, in buildBuilding's order: front (the door), back, left, right.
-- `at(along, out)` is the floor point `out` studs into the room from the face and `along` studs
-- along it -- the same offsets buildWall gives its windows. `yaw` turns a piece built facing +Z so
-- its back is to the wall; `reach` is how far the face runs either side of its middle.
local function wallFaces(origin, halfW, halfD)
	local face = WALL_THICKNESS / 2
	return {
		{ yaw = 0, reach = halfW - face, alongX = true,
			at = function(a, d) return origin.X + a, origin.Z - halfD + face + d end },
		{ yaw = math.pi, reach = halfW - face, alongX = true,
			at = function(a, d) return origin.X + a, origin.Z + halfD - face - d end },
		{ yaw = math.pi / 2, reach = halfD - face, alongX = false,
			at = function(a, d) return origin.X - halfW + face + d, origin.Z + a end },
		{ yaw = -math.pi / 2, reach = halfD - face, alongX = false,
			at = function(a, d) return origin.X + halfW - face - d, origin.Z + a end },
	}
end

-- Claims the floor a player needs inside every opening, before anything else on the floor is placed:
-- each window's vault lane (`wallWindows[i]` is buildWall's list for wall i), and on the ground floor
-- the lane inside the door. Loot, partitions and furniture all fit round these.
local function claimOpenings(room, origin, halfW, halfD, wallWindows, isGround)
	local faces = wallFaces(origin, halfW, halfD)
	local halfAlong = WINDOW_WIDTH / 2 + VAULT_MARGIN
	for index, face in ipairs(faces) do
		for _, offset in ipairs(wallWindows[index] or {}) do
			local x, z = face.at(offset, VAULT_DEPTH / 2)
			if face.alongX then
				room:AddRect(x, z, halfAlong, VAULT_DEPTH / 2)
			else
				room:AddRect(x, z, VAULT_DEPTH / 2, halfAlong)
			end
		end
	end
	if isGround then
		local x, z = faces[1].at(0, DOOR_LANE / 2)
		room:AddRect(x, z, DOOR_WIDTH / 2 + DOOR_MARGIN, DOOR_LANE / 2)
	end
end

-- Where an interior partition meets the side walls, as studs behind the building's middle: the roll,
-- or the nearest whole stud to it (within 2..limit) where the partition butts onto solid wall between
-- two windows instead of standing across one. nil when no such spot exists.
local function partitionZ(rolled, limit, sideWindows)
	local clear = WINDOW_WIDTH / 2 + WALL_THICKNESS / 2 + 0.4
	for step = 0, limit do
		for _, candidate in ipairs({ rolled + step, rolled - step }) do
			if candidate >= 2 and candidate <= limit then
				local fits = true
				for _, offset in ipairs(sideWindows) do
					if math.abs(candidate - offset) < clear then
						fits = false
						break
					end
				end
				if fits then
					return candidate
				end
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- House furnishing
--------------------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Interior styles: one per house, so the rooms of a house belong together and the houses of a town
-- differ. `wood` is the joinery, `dark` its trim, `fabric` the soft furnishings, `top` worktops and
-- tops, `white` the appliances and bathroom ware, `metal` the hobs and handles.
local INTERIOR_STYLES = {
	cosy = { wood = rgb(158, 112, 72), dark = rgb(104, 74, 50), woodMat = Enum.Material.Wood, top = rgb(232, 222, 200),
		white = rgb(238, 234, 226), metal = rgb(66, 66, 70), accent = rgb(226, 170, 80),
		fabric = { rgb(190, 104, 80), rgb(222, 196, 150), rgb(116, 140, 96) } },
	modern = { wood = rgb(216, 216, 220), dark = rgb(56, 58, 64), woodMat = Enum.Material.SmoothPlastic, top = rgb(40, 42, 48),
		white = rgb(246, 246, 248), metal = rgb(28, 28, 32), accent = rgb(36, 168, 178),
		fabric = { rgb(84, 92, 108), rgb(196, 200, 208), rgb(36, 116, 128) } },
	pastel = { wood = rgb(238, 226, 214), dark = rgb(196, 160, 186), woodMat = Enum.Material.SmoothPlastic, top = rgb(250, 246, 240),
		white = rgb(250, 250, 250), metal = rgb(150, 186, 210), accent = rgb(255, 206, 110),
		fabric = { rgb(248, 170, 196), rgb(160, 222, 204), rgb(196, 176, 240) } },
	rustic = { wood = rgb(124, 84, 52), dark = rgb(78, 52, 34), woodMat = Enum.Material.WoodPlanks, top = rgb(176, 156, 128),
		white = rgb(226, 220, 204), metal = rgb(48, 44, 40), accent = rgb(186, 116, 48),
		fabric = { rgb(150, 50, 44), rgb(68, 96, 60), rgb(202, 172, 120) } },
	retro = { wood = rgb(176, 114, 62), dark = rgb(104, 66, 38), woodMat = Enum.Material.Wood, top = rgb(240, 218, 166),
		white = rgb(244, 236, 214), metal = rgb(176, 178, 168), accent = rgb(56, 150, 140),
		fabric = { rgb(232, 128, 40), rgb(218, 178, 46), rgb(120, 78, 48) } },
	grunge = { wood = rgb(112, 102, 90), dark = rgb(68, 62, 56), woodMat = Enum.Material.WoodPlanks, top = rgb(150, 146, 136),
		white = rgb(200, 196, 184), metal = rgb(80, 76, 70), accent = rgb(168, 138, 58),
		fabric = { rgb(100, 110, 88), rgb(128, 98, 78), rgb(88, 90, 100) } },
}
local STYLE_ORDER = { "cosy", "modern", "pastel", "rustic", "retro", "grunge" }
-- Which styles a town's palette (TownKinds.Palettes, by name) leans to. Towns without a palette
-- take DEFAULT_STYLE_WEIGHTS.
local STYLE_WEIGHTS = {
	pastel = { pastel = 3, retro = 1 }, candy = { pastel = 2, retro = 2 },
	upscale = { modern = 3, cosy = 1 }, corporate = { modern = 1 }, civic = { modern = 2, cosy = 1 },
	farm = { rustic = 3, cosy = 1 }, village = { rustic = 2, cosy = 2 }, oasis = { cosy = 2, retro = 1 },
	ruin = { grunge = 1 }, industrial = { grunge = 2, rustic = 1 }, rail = { rustic = 2, grunge = 1 },
	construction = { grunge = 2, modern = 1 }, oldTown = { cosy = 2, rustic = 1, retro = 1 },
	harbour = { cosy = 2, rustic = 2 }, sport = { modern = 2, retro = 1 }, uniform = { modern = 1, cosy = 1 },
	plain = { cosy = 1, modern = 1 },
}
local DEFAULT_STYLE_WEIGHTS = { cosy = 2, modern = 2, pastel = 1, rustic = 1, retro = 1 }

-- One roll: this house's interior style, leaning to its town's palette.
local function interiorStyle(palette)
	local weights = (palette and STYLE_WEIGHTS[palette.name]) or DEFAULT_STYLE_WEIGHTS
	local total = 0
	for _, name in ipairs(STYLE_ORDER) do
		total += weights[name] or 0
	end
	local roll, seen = random() * total, 0
	for _, name in ipairs(STYLE_ORDER) do
		seen += weights[name] or 0
		if roll < seen then
			return INTERIOR_STYLES[name]
		end
	end
	return INTERIOR_STYLES.cosy
end

-- The furniture. Each piece is built facing +Z with its back at -depth/2 and its footprint centred on
-- the origin, standing on y = 0 (the floor's top face): `len` along the wall, `depth` out from it.
-- `k.solid` parts collide and stop shots -- cover, and what DestructibleService breaks; `k.deco`
-- parts are trim that goes with them. `k.wall` is the wall's face, for things hung on it. A piece
-- with `wall = false` stands free in the room. `beside` names pieces tried next to it, on its wall.
-- A bed `width` wide (3.3 studs of it are the pillow's).
local function buildBed(k, s, width)
	k.solid(Vector3.new(width, 1.1, 7.8), 0, 0.55, 0.2, s.wood, s.woodMat)
	k.solid(Vector3.new(width - 0.4, 0.8, 7.4), 0, 1.5, 0.3, s.white, Enum.Material.Fabric)
	k.solid(Vector3.new(width, 3.6, 0.4), 0, 1.8, -3.9, s.dark, s.woodMat)
	k.deco(Vector3.new(width - 0.3, 0.2, 4.6), 0, 2.0, 1.75, k.fabric, Enum.Material.Fabric)
	k.deco(Vector3.new(width - 1.4, 0.5, 1.4), 0, 2.15, -2.8, s.white:Lerp(s.accent, 0.25), Enum.Material.Fabric)
end

local PIECES = {
	counter = { len = 5.6, depth = 2.6, beside = { "stove" }, build = function(k, s)
		k.solid(Vector3.new(5.6, 3.1, 2.6), 0, 1.55, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(5.8, 0.25, 2.75), 0, 3.225, 0.075, s.top, Enum.Material.Marble)
		k.deco(Vector3.new(1.9, 0.1, 1.4), 1.4, 3.4, 0.15, s.metal, Enum.Material.Metal)
		k.deco(Vector3.new(5.2, 2.2, 1.2), 0, 6.9, k.wall + 0.62, s.wood, s.woodMat)
	end },
	stove = { len = 3, depth = 2.6, build = function(k, s)
		k.solid(Vector3.new(3, 3.1, 2.6), 0, 1.55, 0, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(2.6, 0.12, 2.2), 0, 3.16, 0, rgb(28, 28, 30), Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(2.3, 1.5, 0.1), 0, 1.5, 1.35, rgb(40, 42, 46), Enum.Material.Glass)
		k.deco(Vector3.new(2.8, 1, 1.6), 0, 7, k.wall + 0.82, s.metal, Enum.Material.Metal)
	end },
	fridge = { len = 3.2, depth = 2.8, build = function(k, s)
		k.solid(Vector3.new(3.2, 7.2, 2.8), 0, 3.6, 0, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(0.2, 2.2, 0.2), 1.2, 4.6, 1.5, s.metal, Enum.Material.Metal)
		k.deco(Vector3.new(3.1, 0.08, 0.06), 0, 4.9, 1.43, s.metal, Enum.Material.Metal)
	end },
	pantry = { len = 3.6, depth = 2.2, build = function(k, s)
		k.solid(Vector3.new(3.6, 7.8, 2.2), 0, 3.9, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(0.08, 7.2, 0.06), 0, 3.9, 1.13, s.dark, Enum.Material.Wood)
	end },
	diningTable = { len = 6, depth = 7.4, wall = false, build = function(k, s)
		k.solid(Vector3.new(6, 0.35, 3.8), 0, 3.025, 0, s.wood, s.woodMat)
		for _, x in ipairs({ -2.3, 2.3 }) do
			k.solid(Vector3.new(0.5, 2.85, 3), x, 1.425, 0, s.dark, s.woodMat)
		end
		for _, side in ipairs({ -1, 1 }) do
			k.deco(Vector3.new(1.8, 0.3, 1.6), side * 1.2, 1.85, side * 2.8, s.dark, s.woodMat)
			k.deco(Vector3.new(1.8, 2.2, 0.25), side * 1.2, 3.1, side * 3.55, s.dark, s.woodMat)
		end
	end },
	sofa = { len = 6, depth = 3, build = function(k, s)
		local cover = k.fabric
		k.solid(Vector3.new(5.2, 1.5, 2.6), 0, 0.75, 0.2, cover, Enum.Material.Fabric)
		k.solid(Vector3.new(6, 3.2, 0.8), 0, 1.6, -1.1, cover, Enum.Material.Fabric)
		for _, x in ipairs({ -2.8, 2.8 }) do
			k.solid(Vector3.new(0.4, 2.2, 2.1), x, 1.1, 0.4, cover, Enum.Material.Fabric)
		end
		k.deco(Vector3.new(5, 0.4, 2.1), 0, 1.7, 0.35, cover:Lerp(rgb(255, 255, 255), 0.18), Enum.Material.Fabric)
		k.deco(Vector3.new(3.6, 2.2, 0.12), 0, 5.8, k.wall + 0.07, s.accent, Enum.Material.SmoothPlastic)
	end },
	tvUnit = { len = 5.4, depth = 1.8, build = function(k, s)
		k.solid(Vector3.new(5.4, 1.8, 1.8), 0, 0.9, 0, s.dark, s.woodMat)
		k.deco(Vector3.new(4.4, 2.6, 0.25), 0, 3.1, -0.4, rgb(22, 22, 26), Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(4.1, 2.3, 0.05), 0, 3.1, -0.25, rgb(40, 60, 90), Enum.Material.Glass)
	end },
	bookcase = { len = 4.6, depth = 1.6, build = function(k, s)
		k.solid(Vector3.new(4.6, 8, 1.6), 0, 4, 0, s.wood, s.woodMat)
		for index, y in ipairs({ 1.9, 4.3, 6.7 }) do
			k.deco(Vector3.new(4.1, 1.3, 0.1), 0, y, 0.84, s.fabric[(index - 1) % #s.fabric + 1], Enum.Material.SmoothPlastic)
		end
	end },
	armchair = { len = 3.4, depth = 3.1, build = function(k, s)
		k.solid(Vector3.new(3.4, 1.5, 2.5), 0, 0.75, 0.3, k.fabric, Enum.Material.Fabric)
		k.solid(Vector3.new(3.4, 3, 0.6), 0, 1.5, -1.25, k.fabric, Enum.Material.Fabric)
	end },
	coffeeTable = { len = 4, depth = 2.4, wall = false, build = function(k, s)
		k.solid(Vector3.new(4, 0.3, 2.4), 0, 1.5, 0, s.wood, s.woodMat)
		k.solid(Vector3.new(3.4, 1.35, 1.8), 0, 0.675, 0, s.dark, s.woodMat)
	end },
	bed = { len = 5.6, depth = 8.2, beside = { "nightstand", "nightstand" }, fallback = "singleBed", build = function(k, s)
		buildBed(k, s, 5.6)
	end },
	-- Where no pier between two windows is wide enough for a double.
	singleBed = { len = 3.8, depth = 8.2, beside = { "nightstand" }, build = function(k, s)
		buildBed(k, s, 3.8)
	end },
	nightstand = { len = 1.6, depth = 1.8, build = function(k, s)
		k.solid(Vector3.new(1.6, 2.2, 1.8), 0, 1.1, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(0.5, 1, 0.5), 0, 2.7, 0, s.metal, Enum.Material.Metal)
		k.lamp(k.deco(Vector3.new(1.2, 0.9, 1.2), 0, 3.65, 0, rgb(255, 236, 196), Enum.Material.Neon))
	end },
	floorLamp = { len = 1.4, depth = 1.4, build = function(k, s)
		k.solid(Vector3.new(1.2, 0.2, 1.2), 0, 0.1, 0, s.metal, Enum.Material.Metal)
		k.solid(Vector3.new(0.25, 5, 0.25), 0, 2.7, 0, s.metal, Enum.Material.Metal)
		k.lamp(k.deco(Vector3.new(1.4, 1.2, 1.4), 0, 5.8, 0, rgb(255, 232, 186), Enum.Material.Neon))
	end },
	plant = { len = 1.8, depth = 1.8, build = function(k, s)
		k.solid(Vector3.new(1.4, 1.6, 1.4), 0, 0.8, 0, rgb(176, 96, 64), Enum.Material.Slate)
		k.deco(Vector3.new(1.8, 2.2, 1.8), 0, 2.7, 0, rgb(62, 128, 60), Enum.Material.Grass)
	end },
	wardrobe = { len = 4.4, depth = 2.4, build = function(k, s)
		k.solid(Vector3.new(4.4, 8.2, 2.4), 0, 4.1, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(0.08, 7.6, 0.06), 0, 4.1, 1.23, s.dark, Enum.Material.Wood)
		k.deco(Vector3.new(1, 0.15, 0.12), 0, 4.4, 1.26, s.metal, Enum.Material.Metal)
	end },
	desk = { len = 4.6, depth = 3.6, build = function(k, s)
		k.solid(Vector3.new(4.6, 0.3, 2.2), 0, 2.85, -0.7, s.wood, s.woodMat)
		for _, x in ipairs({ -2.1, 2.1 }) do
			k.solid(Vector3.new(0.3, 2.7, 2), x, 1.35, -0.7, s.dark, s.woodMat)
		end
		k.deco(Vector3.new(1.7, 0.3, 1.6), 0, 1.8, 0.9, k.fabric, Enum.Material.Fabric)
		k.deco(Vector3.new(1.7, 2, 0.25), 0, 2.9, 1.65, k.fabric, Enum.Material.Fabric)
	end },
	dresser = { len = 3.8, depth = 1.8, build = function(k, s)
		k.solid(Vector3.new(3.8, 3, 1.8), 0, 1.5, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(3.5, 0.08, 0.06), 0, 1.5, 0.93, s.dark, Enum.Material.Wood)
		k.deco(Vector3.new(2.6, 2.8, 0.12), 0, 5, k.wall + 0.07, rgb(196, 216, 226), Enum.Material.Glass)
	end },
	toilet = { len = 2, depth = 2.9, build = function(k, s)
		k.solid(Vector3.new(1.8, 3, 0.8), 0, 1.5, -1.05, s.white, Enum.Material.SmoothPlastic)
		k.solid(Vector3.new(1.5, 1.4, 2), 0, 0.7, 0.35, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(1.6, 0.12, 1.9), 0, 1.46, 0.4, s.accent, Enum.Material.SmoothPlastic)
	end },
	vanity = { len = 3.2, depth = 1.9, build = function(k, s)
		k.solid(Vector3.new(3.2, 2.8, 1.9), 0, 1.4, 0, s.wood, s.woodMat)
		k.deco(Vector3.new(1.8, 0.15, 1.2), 0, 2.875, 0.1, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(2.4, 2.6, 0.1), 0, 5.2, k.wall + 0.06, rgb(196, 216, 226), Enum.Material.Glass)
	end },
	bathtub = { len = 5.6, depth = 3, build = function(k, s)
		k.solid(Vector3.new(5.6, 2, 3), 0, 1, 0, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(5, 0.08, 2.4), 0, 2.04, 0, rgb(150, 200, 230), Enum.Material.Glass)
	end },
	washer = { len = 2.8, depth = 2.6, build = function(k, s)
		k.solid(Vector3.new(2.8, 3, 2.6), 0, 1.5, 0, s.white, Enum.Material.SmoothPlastic)
		k.deco(Vector3.new(1.7, 1.7, 0.08), 0, 1.4, 1.34, rgb(60, 70, 84), Enum.Material.Glass)
	end },
}
-- What each purpose's room holds: every `core` piece it can fit, a shuffled handful of `extra`
-- ones, and one `centre` piece standing free in the middle.
local ROOM_SETS = {
	kitchen = { core = { "counter", "fridge" }, extra = { "counter", "pantry", "plant", "bookcase" }, centre = "diningTable" },
	living = { core = { "sofa", "tvUnit" }, extra = { "armchair", "bookcase", "armchair", "plant", "floorLamp", "dresser" },
		centre = "coffeeTable" },
	bedroom = { core = { "bed" }, extra = { "wardrobe", "desk", "dresser", "bookcase", "plant", "nightstand" } },
	bathroom = { core = { "toilet", "vanity" }, extra = { "bathtub", "washer", "plant" } },
}
-- Signature pieces, by the Name they build under (interior_check and the interior gallery read it).
local FURNITURE_NAME = {
	crates = "Crate", barrel = "Barrel", table = "Table", shelf = "Shelf",
	counter = "Counter", stove = "Stove", fridge = "Fridge", pantry = "Pantry", diningTable = "DiningTable",
	sofa = "Sofa", tvUnit = "TvUnit", bookcase = "Bookcase", armchair = "Armchair", coffeeTable = "CoffeeTable",
	bed = "Bed", singleBed = "Bed", nightstand = "Nightstand", floorLamp = "FloorLamp", plant = "Plant", wardrobe = "Wardrobe", desk = "Desk", dresser = "Dresser",
	toilet = "Toilet", vanity = "Vanity", bathtub = "Bathtub", washer = "Washer",
}

-- Builds one piece whose footprint is centred on (x, z), turned by `yaw`, as its own breakable
-- pool: every part carries `Destructible = "Furniture:<tag>"`, so DestructibleService breaks the
-- piece as one thing, and its trim goes with it.
local function buildPiece(parent, name, x, floorY, z, yaw, style, tag, lights)
	local spec = PIECES[name]
	local frame = CFrame.new(x, floorY, z) * CFrame.Angles(0, yaw, 0)
	local group = "Furniture:" .. tag
	local kit = { wall = -spec.depth / 2 - WALL_GAP, fabric = pick(style.fabric) }
	currentName = FURNITURE_NAME[name]
	function kit.solid(size, px, py, pz, color, material)
		local part = makePart(parent, size, frame * CFrame.new(px, py, pz), color, material)
		part:SetAttribute("Destructible", group)
		return part
	end
	function kit.deco(size, px, py, pz, color, material)
		local part = trim(parent, size, frame * CFrame.new(px, py, pz), color, material)
		part:SetAttribute("Destructible", group)
		return part
	end
	-- One lit lamp per floor at most: lights are the costly part of a lamp.
	function kit.lamp(part)
		if lights.count < 1 then
			lights.count += 1
			local light = Instance.new("PointLight")
			light.Color = rgb(255, 224, 170)
			light.Brightness = 1.2
			light.Range = 14
			light.Parent = part
		end
		return part
	end
	spec.build(kit, style)
	currentName = "Part"
end

-- The footprint of `name` against wall `face` at `along`: centre and world half-extents.
local function wallFootprint(face, name, along)
	local spec = PIECES[name]
	local x, z = face.at(along, WALL_GAP + spec.depth / 2)
	if face.alongX then
		return x, z, spec.len / 2, spec.depth / 2
	end
	return x, z, spec.depth / 2, spec.len / 2
end

-- Stands `name` against wall `face` at `along` if its footprint is clear; claims it and returns true.
local function tryWallPiece(ctx, name, face, along)
	local spec = PIECES[name]
	if math.abs(along) + spec.len / 2 > face.reach - WALL_GAP then
		return false
	end
	local x, z, hx, hz = wallFootprint(face, name, along)
	if not rectFree(ctx.room, x, z, hx, hz) then
		return false
	end
	ctx.room:AddRect(x, z, hx, hz)
	ctx.serial += 1
	buildPiece(ctx.parent, name, x, ctx.floorY, z, face.yaw, ctx.style, ctx.tag .. "_" .. ctx.serial, ctx.lights)
	return true
end

-- Every stretch of wall `spec` fits along between the openings (window and door lanes, from
-- buildWall's own window list), as candidate spots: snug to each end of the stretch and one between,
-- shuffled. The room's claims (stairs, partition, loot, other pieces) are checked when one is tried.
local function wallSpots(ctx, spec)
	local spots = {}
	for index, face in ipairs(ctx.faces) do
		local blocked = {}
		for _, offset in ipairs(ctx.windows[index] or {}) do
			table.insert(blocked, { offset - WINDOW_WIDTH / 2 - VAULT_MARGIN, offset + WINDOW_WIDTH / 2 + VAULT_MARGIN })
		end
		if index == 1 and ctx.ground then
			table.insert(blocked, { -DOOR_WIDTH / 2 - DOOR_MARGIN, DOOR_WIDTH / 2 + DOOR_MARGIN })
		end
		table.sort(blocked, function(a, b)
			return a[1] < b[1]
		end)
		local low = -face.reach + WALL_GAP
		local function stretch(high)
			-- 0.2 spare at each end: rectFree's circles reach a little past the footprint.
			local first, last = low + 0.2 + spec.len / 2, high - 0.2 - spec.len / 2
			if last >= first then
				table.insert(spots, { face, first })
				if last - first > 0.1 then
					table.insert(spots, { face, last })
					table.insert(spots, { face, first + random() * (last - first) })
				end
			end
		end
		for _, span in ipairs(blocked) do
			stretch(span[1])
			low = math.max(low, span[2])
		end
		stretch(face.reach - WALL_GAP)
	end
	for index = #spots, 2, -1 do
		local other = random(1, index)
		spots[index], spots[other] = spots[other], spots[index]
	end
	return spots
end

-- A wall spot for `name` (and then its `beside` pieces next to it), or its `fallback` piece if it
-- fits nowhere.
local function placeOnWall(ctx, name)
	local spec = PIECES[name]
	for _, spot in ipairs(wallSpots(ctx, spec)) do
		local face, along = spot[1], spot[2]
		if tryWallPiece(ctx, name, face, along) then
			for index, other in ipairs(spec.beside or {}) do
				local side = index % 2 == 1 and 1 or -1
				local gap = spec.len / 2 + PIECES[other].len / 2 + 0.2
				local _ = tryWallPiece(ctx, other, face, along + side * gap) or tryWallPiece(ctx, other, face, along - side * gap)
			end
			return true
		end
	end
	if spec.fallback then
		return placeOnWall(ctx, spec.fallback)
	end
	return false
end

-- A freestanding spot for `name`, well clear of the walls (so the vault lanes and the wall pieces keep
-- their floor) with WALKWAY round it. Returns its centre and half-extents, claimed.
local function placeFree(ctx, name, halfW, halfD)
	local spec = PIECES[name]
	for _ = 1, 14 do
		local turned = random() < 0.5
		local hx, hz = spec.len / 2, spec.depth / 2
		if turned then
			hx, hz = hz, hx
		end
		local keepX = halfW - WALL_THICKNESS / 2 - VAULT_DEPTH - hx
		local keepZ = halfD - WALL_THICKNESS / 2 - VAULT_DEPTH - hz
		if keepX > 0 and keepZ > 0 then
			local x = ctx.origin.X + (random() * 2 - 1) * keepX
			local z = ctx.origin.Z + (random() * 2 - 1) * keepZ
			if rectFree(ctx.room, x, z, hx + WALKWAY, hz + WALKWAY) then
				ctx.room:AddRect(x, z, hx, hz)
				ctx.serial += 1
				buildPiece(ctx.parent, name, x, ctx.floorY, z, turned and math.pi / 2 or 0, ctx.style,
					ctx.tag .. "_" .. ctx.serial, ctx.lights)
				return x, z, hx, hz
			end
		end
	end
	return nil
end

-- A lived-in room: the purpose's pieces against the walls between the windows, one piece standing
-- free in the middle, a rug, and skirting and door frames as trim.
local function furnishRoom(parent, origin, width, depth, baseY, room, purpose, floor, style, stairClear, wallWindows)
	local halfW, halfD = width / 2, depth / 2
	local set = ROOM_SETS[purpose]
	local ctx = {
		parent = parent, origin = origin, room = room, style = style, floorY = baseY + 0.5,
		faces = wallFaces(origin, halfW, halfD), serial = 0, tag = "F" .. floor, lights = { count = 0 },
		windows = wallWindows or {}, ground = floor == 0,
	}
	for _, name in ipairs(set.core) do
		placeOnWall(ctx, name)
	end
	local rugX, rugZ, rugHX, rugHZ = nil, nil, nil, nil
	if set.centre then
		rugX, rugZ, rugHX, rugHZ = placeFree(ctx, set.centre, halfW, halfD)
	end
	local extra = table.clone(set.extra)
	for index = #extra, 2, -1 do
		local other = random(1, index)
		extra[index], extra[other] = extra[other], extra[index]
	end
	for index = 1, random(math.ceil(#extra / 2) + 1, #extra) do
		placeOnWall(ctx, extra[index])
	end

	-- A rug under the centre piece, or in the middle of the room when there is none. Trim: it never
	-- collides, so it can't be what blocks a door, a stair or a vault.
	currentName = "Rug"
	if rugX then
		trim(parent, Vector3.new(rugHX * 2 + 2.4, 0.12, rugHZ * 2 + 2.4), CFrame.new(rugX, baseY + 0.56, rugZ),
			pick(style.fabric):Lerp(style.accent, 0.3), Enum.Material.Fabric)
	elseif rectFree(room, origin.X, origin.Z + 2, 3.5, 2.5) then
		trim(parent, Vector3.new(7, 0.12, 5), CFrame.new(origin.X, baseY + 0.56, origin.Z + 2),
			pick(style.fabric):Lerp(style.accent, 0.3), Enum.Material.Fabric)
	end

	-- Skirting along the back and side walls, below every sill; the side runs stop at the back one,
	-- and the left one starts past the stairs' strip (`stairClear` deep, when the house has stairs)
	-- rather than running over the flight or the well.
	local face = WALL_THICKNESS / 2
	currentName = "Skirting"
	local backZ = origin.Z + halfD - face - 0.34
	trim(parent, Vector3.new(width - 2 * face, 0.6, 0.3), CFrame.new(origin.X, baseY + 0.8, backZ + 0.17),
		style.dark, Enum.Material.Wood)
	for _, side in ipairs({ -1, 1 }) do
		local frontZ = origin.Z - halfD + (side < 0 and stairClear or face)
		if backZ - frontZ > 1 then
			trim(parent, Vector3.new(0.3, 0.6, backZ - frontZ),
				CFrame.new(origin.X + side * (halfW - face - 0.17), baseY + 0.8, (frontZ + backZ) / 2), style.dark, Enum.Material.Wood)
		end
	end
	if floor == 0 then
		-- Door-frame jambs either side of the entry, on the inside face (the front wall of the ground
		-- floor has the door and no windows).
		currentName = "DoorFrame"
		for _, side in ipairs({ -1, 1 }) do
			trim(parent, Vector3.new(0.8, 8.5, 0.3), CFrame.new(origin.X + side * (DOOR_WIDTH / 2 + 0.42), baseY + 4.75,
				origin.Z - halfD + face + 0.17), style.dark, Enum.Material.Wood)
		end
	end
	currentName = "Part"
end

-- Rooms need something to fight around. `room` already holds the stairwell, the partition wall, the
-- lanes inside every door and window, and the loot on this floor; every piece checks it and stays
-- inside the walls. A house floor gets a lived-in purpose (kitchen, living room, bedroom, bathroom)
-- furnished in the house's `style`; other archetypes keep the plain crates-and-barrels stockroom.
local function buildInterior(parent, origin, width, depth, baseY, floorHeight, room, archetype, floor, style, stairClear,
	wallWindows)
	local purpose = roomPurpose(archetype, floor)
	if purpose then
		furnishRoom(parent, origin, width, depth, baseY, room, purpose, floor, style or INTERIOR_STYLES.cosy,
			stairClear or WALL_THICKNESS / 2, wallWindows)
		return
	end

	local inset = WALL_THICKNESS / 2 + 0.5
	for _ = 1, random(3, 6) do
		local kind = rollKind(GENERIC_KINDS)
		local radius = FURNITURE_RADIUS[kind]
		local reachX, reachZ = width / 2 - inset - radius, depth / 2 - inset - radius
		local x, z = nil, nil
		if reachX > 0 and reachZ > 0 then
			x, z = freeSpot(room, origin, reachX, reachZ, radius)
		end

		if not x then
			continue
		end
		currentName = FURNITURE_NAME[kind]
		if kind == "crates" then
			-- A stack: each crate rests on the one below, a little askew, and the stack stops short of
			-- CRATE_HEADROOM under the ceiling. (Each level used to be placed by its own size alone, so
			-- a bigger crate hung in the air over a smaller one, a smaller one sank into a bigger one,
			-- and three big ones went up through the floor into the room above.)
			local top, crateX = baseY + 0.5, x + random(-1, 1)
			for _ = 1, random(1, 3) do
				local size = random(4, 6)
				if top + size > baseY + floorHeight - 0.5 - CRATE_HEADROOM then
					break
				end
				makePart(parent, Vector3.new(size, size, size),
					CFrame.new(crateX, top + size / 2, z) * CFrame.Angles(0, random() * 3, 0),
					Color3.fromRGB(152, 114, 70), Enum.Material.WoodPlanks)
				top += size
				crateX = math.clamp(crateX + random() - 0.5, x - 1, x + 1)
			end
		elseif kind == "barrel" then
			if random() < 0.45 then
				-- A red one: shoot it and it goes up, taking whoever is beside it with it.
				HazardService.Barrel(parent, CFrame.new(x, baseY + 0.5, z) * CFrame.Angles(0, random() * 3, 0))
			else
				local barrel = makePart(parent, Vector3.new(7, 4.5, 4.5),
					CFrame.new(x, baseY + 4, z) * CFrame.Angles(0, 0, math.rad(90)),
					Color3.fromRGB(92, 108, 96), Enum.Material.Metal)
				barrel.Shape = Enum.PartType.Cylinder
			end
		elseif kind == "table" then
			makePart(parent, Vector3.new(11, 0.8, 6), CFrame.new(x, baseY + 5, z), Color3.fromRGB(122, 88, 58), Enum.Material.Wood)
			for _, corner in ipairs({ Vector3.new(-5, 0, -2.4), Vector3.new(5, 0, -2.4), Vector3.new(-5, 0, 2.4), Vector3.new(5, 0, 2.4) }) do
				makePart(parent, Vector3.new(0.8, 4.1, 0.8), CFrame.new(Vector3.new(x, baseY + 2.55, z) + corner),
					Color3.fromRGB(98, 70, 46), Enum.Material.Wood)
			end
		else
			-- Shelving unit, tall enough to break sightlines, with a little clutter on top that never
			-- collides so it can't snag a jump or eat a bullet meant for the shelf itself.
			local yaw = random() * 3
			makePart(parent, Vector3.new(9, 10, 2.5), CFrame.new(x, baseY + 5.5, z) * CFrame.Angles(0, yaw, 0),
				Color3.fromRGB(108, 96, 84), Enum.Material.Wood)
			local face = CFrame.new(x, baseY + 10.3, z) * CFrame.Angles(0, yaw, 0)
			for _, along in ipairs({ -3, -0.5, 2 }) do
				clutter(decorPart(parent, Vector3.new(random(6, 12) / 10, random(6, 12) / 10, random(6, 12) / 10),
					face * CFrame.new(along, 0.4, 0), pick(ART_COLORS), Enum.Material.SmoothPlastic))
			end
		end
	end
	currentName = "Part"
end

--------------------------------------------------------------------------------
-- Buildings
--------------------------------------------------------------------------------

local ARCHETYPES = { "house", "house", "tower", "warehouse" }

local SHUTTER_COLORS = {
	Color3.fromRGB(60, 110, 80), Color3.fromRGB(70, 90, 150), Color3.fromRGB(150, 60, 50),
	Color3.fromRGB(230, 220, 200), Color3.fromRGB(50, 50, 56),
}
local FLOWER_COLORS = {
	Color3.fromRGB(255, 96, 140), Color3.fromRGB(255, 214, 70), Color3.fromRGB(170, 120, 255), Color3.fromRGB(255, 255, 255),
}
local SIGN_COLORS = {
	Color3.fromRGB(255, 214, 90), Color3.fromRGB(120, 230, 255), Color3.fromRGB(255, 130, 190), Color3.fromRGB(140, 255, 150),
}
local SHOP_NAMES = {
	"ROT MART", "PIZZA ROT", "ARCADE", "BAKERY", "SIGMA GYM", "SAHUR SNACKS", "AURA SALON", "LAG CAFE",
	"NOOB NOODLES", "BRAINROT BOOKS", "OOF OUTLET", "DELULU DELI", "RIZZ RENTALS", "GRASS & CO",
}

-- A trim colour that reads against the wall: darker on pale walls, lighter on dark ones.
local function trimFor(wallColor)
	local luminance = wallColor.R * 0.3 + wallColor.G * 0.59 + wallColor.B * 0.11
	if luminance > 0.55 then
		return wallColor:Lerp(Color3.new(0, 0, 0), 0.32)
	end
	return wallColor:Lerp(Color3.new(1, 1, 1), 0.45)
end

-- Window glass: the name DestructibleService breaks at a touch and lets shots through.
local GLASS_NAME = "WindowGlass"
-- Tinted and a little reflective, so a pane reads as glass from a distance instead of as an open
-- window (at 0.6 the first render showed windows as plain holes, which matters when glass stops
-- you climbing through).
local GLASS_COLOR = Color3.fromRGB(150, 196, 222)
local GLASS_TRANSPARENCY = 0.45
local GLASS_REFLECTANCE = 0.15
-- A pane reaches this far into the sill, lintel and piers round its opening, so no light shows at
-- its edges and DestructibleService finds it attached to each of them.
local GLASS_OVERLAP = 0.1
local GLASS_THICKNESS = 0.2

-- One wall's facade: a cornice at the floor line above, a sill and a header on every window,
-- and on houses, window frames, shutters and the odd flower box. `normal` points out of the
-- wall. All trim, except the pane of glass in each window.
local function dressWall(model, axis, cx, cz, length, baseY, floorHeight, normal, windows, facade, floor)
	local along = axis == "x" and Vector3.new(1, 0, 0) or Vector3.new(0, 0, 1)
	local function place(name, size, offsetAlong, y, out, color, material)
		currentName = name
		local position = Vector3.new(cx, y, cz) + along * offsetAlong + normal * (WALL_THICKNESS / 2 + out)
		local part = trim(model, size, CFrame.lookAt(position, position + normal), color, material)
		currentName = "Part"
		return part
	end

	-- One pane per window, on the wall's centre plane, well inside the wall's own faces and every
	-- piece of trim, so it has no face in any plane another part uses. Solid: it keeps people and
	-- bullets out until it's broken, and one hit breaks it.
	local function pane(offsetAlong)
		currentName = GLASS_NAME
		local position = Vector3.new(cx, baseY + 0.5 + (SILL_HEIGHT + WINDOW_TOP) / 2, cz) + along * offsetAlong
		local size = Vector3.new(WINDOW_WIDTH + GLASS_OVERLAP * 2, WINDOW_TOP - SILL_HEIGHT + GLASS_OVERLAP * 2, GLASS_THICKNESS)
		local glass = makePart(model, size, CFrame.lookAt(position, position + normal), GLASS_COLOR, Enum.Material.Glass)
		glass.Transparency = GLASS_TRANSPARENCY
		glass.Reflectance = GLASS_REFLECTANCE
		glass.CastShadow = false
		glass.CanTouch = false
		currentName = "Part"
		return glass
	end

	-- Not at the top of a house, where it poked out through the eaves of the pitched roof.
	if not (facade.archetype == "house" and floor == (facade.floors or 1) - 1) then
		place("Cornice", Vector3.new(length + 1.8, 0.6, 0.7), 0, baseY + floorHeight, 0.35, facade.trim, Enum.Material.Concrete)
	end

	local house = facade.archetype == "house"
	local windowMid = baseY + 0.5 + (SILL_HEIGHT + WINDOW_TOP) / 2
	for _, offset in ipairs(windows) do
		pane(offset)
		place("Sill", Vector3.new(WINDOW_WIDTH + 0.8, 0.3, 0.7), offset, baseY + 0.5 + SILL_HEIGHT - 0.15, 0.35, facade.trim, Enum.Material.Concrete)
		place("Header", Vector3.new(WINDOW_WIDTH + 0.7, 0.5, 0.45), offset, baseY + 0.5 + WINDOW_TOP + 0.25, 0.22, facade.trim, Enum.Material.Concrete)
		if house then
			for _, side in ipairs({ -1, 1 }) do
				place("WindowFrame", Vector3.new(0.3, WINDOW_TOP - SILL_HEIGHT, 0.3), offset + side * (WINDOW_WIDTH / 2 + 0.15), windowMid, 0.15,
					facade.trim, Enum.Material.Wood)
				place("Shutter", Vector3.new(1.3, WINDOW_TOP - SILL_HEIGHT - 0.4, 0.2), offset + side * (WINDOW_WIDTH / 2 + 0.95), windowMid, 0.1,
					facade.shutter, Enum.Material.WoodPlanks)
			end
			if floor == 0 and random() < 0.5 then
				local boxY = baseY + 0.5 + SILL_HEIGHT - 0.65
				place("FlowerBox", Vector3.new(WINDOW_WIDTH, 0.7, 0.8), offset, boxY, 0.55, Color3.fromRGB(120, 84, 54), Enum.Material.WoodPlanks)
				for index = -1, 1 do
					local flower = place("Flower", Vector3.new(0.8, 0.8, 0.8), offset + index * 1.4, boxY + 0.55, 0.55, pick(FLOWER_COLORS),
						Enum.Material.SmoothPlastic)
					flower.Shape = Enum.PartType.Ball
					flower.Size = Vector3.new(0.8, 0.8, 0.8)
				end
			end
		end
	end
end

-- Street level: a plinth round the base, corner pilasters, a step and a lamp at the door, a
-- shop sign over the door of towers and warehouses, and a rug inside houses.
local function dressGround(model, origin, archetype, width, depth, height, facade)
	local halfW, halfD = width / 2, depth / 2
	local plinth = facade.trim:Lerp(Color3.new(0, 0, 0), 0.35)
	local frontZ = origin.Z - halfD

	-- The plinth stands 1 above grade and carries on FOUNDATION_DEPTH below it.
	local segment = (width + 1.9 - DOOR_WIDTH) / 2
	local plinthHeight, plinthY = 1 + FOUNDATION_DEPTH, origin.Y + (1 - FOUNDATION_DEPTH) / 2
	currentName = "Plinth"
	for _, side in ipairs({ -1, 1 }) do
		trim(model, Vector3.new(segment, plinthHeight, 0.5), CFrame.new(origin.X + side * (DOOR_WIDTH / 2 + segment / 2), plinthY, frontZ - 0.95),
			plinth, Enum.Material.Concrete)
		-- The side runs fit between the front and back ones instead of crossing them at the corners.
		trim(model, Vector3.new(0.5, plinthHeight, depth + 1.4), CFrame.new(origin.X + side * (halfW + 0.95), plinthY, origin.Z),
			plinth, Enum.Material.Concrete)
	end
	trim(model, Vector3.new(width + 1.9, plinthHeight, 0.5), CFrame.new(origin.X, plinthY, origin.Z + halfD + 0.95), plinth, Enum.Material.Concrete)

	-- Pilasters stop a hair short of the wall tops, so their tops never share the walls' plane.
	currentName = "Pilaster"
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			trim(model, Vector3.new(1.3, height - 0.06, 1.3),
				CFrame.new(origin.X + sx * (halfW + 0.2), origin.Y + 0.5 + (height - 0.06) / 2, origin.Z + sz * (halfD + 0.2)), facade.trim, Enum.Material.Concrete)
		end
	end

	currentName = "Step"
	-- A solid block from the foundation up to 0.3 above grade.
	makePart(model, Vector3.new(DOOR_WIDTH, 0.3 + FOUNDATION_DEPTH, 2), CFrame.new(origin.X, origin.Y + (0.3 - FOUNDATION_DEPTH) / 2, frontZ - 1.7),
		plinth, Enum.Material.Concrete)
	-- A stone threshold across the doorway, through the wall's thickness from the step to the floor
	-- inside, and down to the foundation, so there's no slot down to the ground under the door.
	-- It meets the step, the floor and the wall ends edge to edge, never face to face.
	currentName = "Threshold"
	makePart(model, Vector3.new(DOOR_WIDTH, 0.5 + FOUNDATION_DEPTH, WALL_THICKNESS), CFrame.new(origin.X, origin.Y + (0.5 - FOUNDATION_DEPTH) / 2, frontZ),
		plinth, Enum.Material.Concrete)
	local lampX = origin.X + DOOR_WIDTH / 2 + 1.9
	currentName = "DoorLamp"
	trim(model, Vector3.new(0.25, 0.25, 0.9), CFrame.new(lampX, origin.Y + 8.6, frontZ - 1.1), Color3.fromRGB(40, 40, 46), Enum.Material.Metal)
	trim(model, Vector3.new(0.6, 0.8, 0.6), CFrame.new(lampX, origin.Y + 8.2, frontZ - 1.6), Color3.fromRGB(255, 226, 160), Enum.Material.Neon)

	if archetype == "house" then
		-- 0.12 thick and centred on the floor's top, so 0.06 shows as before but its underside is buried
		-- in the slab. Resting ON the floor put that underside in the same plane as the bottoms of the
		-- walls, and where a partition crossed the rug the map's z-fight pass grew the partition, which
		-- then pushed into the side walls and grew their piers too.
		currentName = "Rug"
		trim(model, Vector3.new(7, 0.12, 5), CFrame.new(origin.X + halfW * 0.25, origin.Y + 0.5, origin.Z + halfD * 0.25),
			pick(RUG_COLORS), Enum.Material.Fabric)
	elseif facade.sign ~= false then
		-- The town profile's sign, if it has one: `false` means this town's buildings carry no shop
		-- sign at all (an industrial row has none), a table names the text and colour instead of
		-- rolling them, and nil is the rolled sign the game has always put up.
		local spec = type(facade.sign) == "table" and facade.sign or nil
		currentName = "ShopSign"
		local signPosition = Vector3.new(origin.X, origin.Y + 13.9, frontZ - 0.85)
		local sign = trim(model, Vector3.new(DOOR_WIDTH + 7, 1.8, 0.3), CFrame.lookAt(signPosition, signPosition - Vector3.new(0, 0, 1)),
			Color3.fromRGB(30, 30, 36), Enum.Material.SmoothPlastic)
		MapDecor.SignText(sign, (spec and spec.text) or pick(SHOP_NAMES), (spec and spec.color) or pick(SIGN_COLORS),
			{ Enum.NormalId.Front })
	end
	currentName = "Part"
end

-- A small railed balcony outside one of a tower's upper windows. Solid: climb out and stand on it.
local function addBalcony(model, origin, halfD, offset, floorY, facade)
	local z = origin.Z - halfD - 0.7 - 1.6
	local rail = Color3.fromRGB(46, 48, 54)
	local width = WINDOW_WIDTH + 3
	currentName = "Balcony"
	makePart(model, Vector3.new(width, 0.5, 3.2), CFrame.new(origin.X + offset, floorY + 0.25, z), facade.trim, Enum.Material.Concrete)
	currentName = "BalconyRail"
	makePart(model, Vector3.new(width, 1.4, 0.25), CFrame.new(origin.X + offset, floorY + 1.2, z - 1.5), rail, Enum.Material.Metal)
	for _, side in ipairs({ -1, 1 }) do
		makePart(model, Vector3.new(0.25, 1.4, 3.2), CFrame.new(origin.X + offset + side * width / 2, floorY + 1.2, z), rail, Enum.Material.Metal)
	end
	currentName = "Part"
end

-- A loading dock behind a warehouse, with a hazard-striped edge and bumpers.
local function addLoadingDock(model, origin, halfW, halfD)
	local x = origin.X + halfW * 0.35
	local z = origin.Z + halfD + 2.7
	local yellow = Color3.fromRGB(255, 200, 40)
	currentName = "Dock"
	makePart(model, Vector3.new(12, 1.5 + FOUNDATION_DEPTH, 4), CFrame.new(x, origin.Y + (1.5 - FOUNDATION_DEPTH) / 2, z),
		Color3.fromRGB(150, 148, 142), Enum.Material.Concrete)
	currentName = "DockStripe"
	trim(model, Vector3.new(12, 0.2, 0.3), CFrame.new(x, origin.Y + 1.45, z + 1.9), yellow, Enum.Material.SmoothPlastic)
	currentName = "Bumper"
	for _, side in ipairs({ -1, 1 }) do
		makePart(model, Vector3.new(0.8, 1.2, 0.8), CFrame.new(x + side * 5.2, origin.Y + 2.1, z + 1.4), yellow, Enum.Material.Metal)
	end
	-- Two explosive barrels waiting beside the dock.
	for index, dx in ipairs({ -8.6, -12.4 }) do
		HazardService.Barrel(model, CFrame.new(x + dx, origin.Y, z - 0.5 + index * 0.8) * CFrame.Angles(0, index * 1.1, 0))
	end
	currentName = "Part"
end

-- A building's shape. Towers cluster downtown near the square; houses and warehouses spread out
-- toward the edge of town.
-- A town's kind profile (the Cities tab's #32 `plan`): an opaque table that says what this town's
-- buildings should look like, or nil for the mix the game has always rolled. Everything below reads
-- it defensively -- a missing field falls back to the default, so a profile can set one thing.
--
--   weights = { downtown = { tower = 45, house = 37, warehouse = 18 }, edge = { ... } }
--             (a list { tower, house, warehouse } is accepted too; the numbers are relative)
--   sizes   = { tower = { width = { 26, 34 }, depth = { 26, 34 }, floors = { 3, 5 } }, ... }
--             (a plain number instead of a pair means every one of them is that size)
--   palette = { wallMaterials = {...}, wallColors = {...}, roofColors = {...}, roofMaterial = ... }
--   sign    = false for a town with no shop signs, or { text = "...", color = Color3 }
--
-- Rolled with the SAME number of random draws as before in the same order, so a town that passes no
-- profile builds the identical map from the identical seed. That is the whole contract of `nil`.
local ARCHETYPES = { "tower", "house", "warehouse" }
local DEFAULT_WEIGHTS = {
	downtown = { tower = 45, house = 37, warehouse = 18 },
	edge = { tower = 15, house = 53, warehouse = 32 },
}
local DEFAULT_SIZES = {
	tower = { width = { 26, 34 }, depth = { 26, 34 }, floors = { 3, 5 } },
	warehouse = { width = { 40, 52 }, depth = { 34, 44 }, floors = 1 },
	house = { width = { 26, 38 }, depth = { 26, 34 }, floors = { 1, 2 } },
}

-- A range is { min, max } or a single number. A fixed value draws no random at all, which is what
-- keeps a warehouse's two draws two (its floors have always been 1, never rolled).
local function rollRange(range, fallback)
	range = range or fallback
	if type(range) == "number" then
		return range
	end
	local low, high = range[1], range[2]
	if low == high then
		return low
	end
	return math.random(low, high)
end

local function weightsFor(plan, downtown)
	local set = plan and plan.weights and plan.weights[downtown and "downtown" or "edge"]
	if not set then
		return DEFAULT_WEIGHTS[downtown and "downtown" or "edge"]
	end
	-- Keyed or in ARCHETYPES order, whichever the profile used.
	if set.tower or set.house or set.warehouse then
		return set
	end
	return { tower = set[1] or 0, house = set[2] or 0, warehouse = set[3] or 0 }
end

local function rollPlan(downtown, townPlan)
	local weights = weightsFor(townPlan, downtown)
	local total = 0
	for _, name in ipairs(ARCHETYPES) do
		total += math.max(0, weights[name] or 0)
	end
	-- One draw, as before. A profile that weights everything to zero would divide by zero and pick
	-- nothing, so it falls back rather than building a town of nils.
	local roll = math.random()
	local archetype = "house"
	if total > 0 then
		local seen = 0
		for _, name in ipairs(ARCHETYPES) do
			seen += math.max(0, weights[name] or 0)
			if roll < seen / total then
				archetype = name
				break
			end
		end
	end

	local plan = { archetype = archetype }
	local sizes = (townPlan and townPlan.sizes and townPlan.sizes[archetype]) or nil
	local default = DEFAULT_SIZES[archetype]
	plan.width = rollRange(sizes and sizes.width, default.width)
	plan.depth = rollRange(sizes and sizes.depth, default.depth)
	plan.floors = rollRange(sizes and sizes.floors, default.floors)
	plan.dock = archetype == "warehouse" and plan.depth <= 40
	-- Carried, not applied: buildBuilding reads these off the rolled plan. `sign` may be false, which
	-- is a real value and must survive -- hence the explicit test rather than `and ... or nil`.
	if townPlan ~= nil then
		plan.palette = townPlan.palette
		plan.sign = townPlan.sign
		plan.variant = townPlan.variant
	end
	return plan
end

-- What of a building stands on the ground, measured out from its lot centre in its own frame
-- (door toward -Z): the plinth round the walls reaches PLINTH_OUT past the centre lines of the
-- walls, the door step STEP_OUT in front, and a warehouse's loading dock and the barrels beside it
-- DOCK_OUT behind (the dock reaches 4.7, the far barrel's rims 5.56). These mirror dressGround and
-- addLoadingDock.
local PLINTH_OUT = 1.2
local STEP_OUT = 2.7
local DOCK_OUT = 5.56
-- Ground the building uses without standing on it: the doorstep gun spawn out front, and the back
-- yard where buildTown stacks crates (YARD_* mirror its numbers: a dock adds its 5, crates stand
-- 5.4 further back and claim 4.3 round themselves).
local DOORSTEP_OUT = 6
local YARD_DOCK, YARD_OFFSET, YARD_RADIUS = 5, 5.4, 4.3

-- A rectangle in the building's frame: `halfX` either side of the lot centre, and `front` and
-- `back` out from it along its depth, as { halfX, halfZ, offsetZ } (offsetZ: the rectangle's centre
-- along the depth).
local function extent(halfX, front, back)
	return { halfX = halfX, halfZ = (front + back) / 2, offsetZ = (back - front) / 2 }
end

-- The part of the building that touches the ground: the footing_probe footprint.
local function groundContact(plan)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	return extent(halfW + PLINTH_OUT, halfD + STEP_OUT, halfD + (plan.dock and DOCK_OUT or PLINTH_OUT))
end

-- All the ground a building's lot needs flat, for the terrain pad under it: the footprint plus the
-- doorstep and the back yard.
local function footprint(plan)
	local halfW, halfD = plan.width / 2, plan.depth / 2
	return extent(math.max(halfW + PLINTH_OUT, (plan.width - 6) / 2 + YARD_RADIUS), halfD + DOORSTEP_OUT,
		halfD + (plan.dock and YARD_DOCK or 0) + YARD_OFFSET + YARD_RADIUS)
end

-- Builds one building from its `plan` centred at `origin` with the door on its local -Z side,
-- then turns the whole thing by `yaw` about its centre so the door faces the street. Chest and
-- loot spots are collected while it's built and turned along with it.
local function buildBuilding(parent, origin, preset, chestSpots, lootSpots, plan, yaw)
	rng = Random.new(math.random(1, 2147483646))
	local archetype = plan.archetype
	local width, depth, floors = plan.width, plan.depth, plan.floors

	-- The town profile's palette, where it has one, otherwise the map preset's. Field by field, so a
	-- profile can recolour the walls and leave the roofs alone. Each is still one `pick`, so a palette
	-- changes what a building looks like and never how many random draws it takes to build it.
	local palette = plan.palette
	local wallMat = pick((palette and palette.wallMaterials) or preset.wallMaterials)
	local wallColor = pick((palette and palette.wallColors) or preset.wallColors)
	local roofColor = pick((palette and palette.roofColors) or preset.roofColors)
	local roofMat = (palette and palette.roofMaterial) or preset.roofMaterial
	-- `plan.variant` is the Cities tab's shape for this building (#32 batch 2). Only "terrace" changes
	-- the shell; the rest are decoration hung on it further down.
	local partyWalls = plan.variant == "terrace"
	local partyColor = partyWalls and wallColor:Lerp(Color3.new(0, 0, 0), 0.12) or wallColor

	local model = Instance.new("Model")
	model.Name = archetype
	model.Parent = parent

	local halfW, halfD = width / 2, depth / 2
	local floorHeight = archetype == "warehouse" and FLOOR_HEIGHT * 1.6 or FLOOR_HEIGHT
	-- The stairs keep a strip down the left wall, from the front wall to STAIR_EXIT past the top step
	-- and STAIR_EXIT wide beside the flight. Every building deep enough to hold that gets stairs; a
	-- multi-storey one without them had floors, and loot on them, that nobody could reach.
	local stairSide = 1 + STAIR_WIDTH + STAIR_EXIT
	local stairClear = 1 + STAIR_LANDING + STAIR_RUN + STAIR_EXIT
	local canClimb = floors > 1 and width >= 26 and depth >= stairClear + WALL_THICKNESS
	local reachX, reachZ = math.max(1, halfW - 3.5), math.max(1, halfD - 3.5)
	local facade = { archetype = archetype, trim = trimFor(wallColor), shutter = pick(SHUTTER_COLORS), floors = floors,
		sign = plan.sign }
	local frontWindows = {}
	-- One interior style for the whole house, leaning to its town's palette.
	local style = archetype == "house" and interiorStyle(palette) or nil
	local localChests = {}
	local localLoot = { weapon = {}, heal = {}, item = {} }

	for floor = 0, floors - 1 do
		local baseY = origin.Y + floor * floorHeight
		local room = MapSpace.new()

		buildFloorWithWell(model, origin, width, depth, baseY, preset.floorMaterial, wallColor,
			canClimb and floor > 0, facade.trim, floor == floors - 1)
		-- The ground-floor slab breaks like every other floor (Oliver 2026-09-24: "the ground breaks
		-- too"). Nothing can fall through it: it lies on the pad MapTerrain.FlattenPad levelled for the
		-- building, and craters never dig under anything built or deeper than DestructibleService's dig
		-- floor. To the support pass it is ground while it lies on that pad (it stands on terrain).

		-- The front and back walls run the full width; the side walls fit between them, so no two
		-- walls share a corner (their tops would lie in one plane and flicker).
		local isGround = floor == 0
		local walls = {
			{ "x", origin.X, origin.Z - halfD, width, Vector3.new(0, 0, -1), isGround },
			{ "x", origin.X, origin.Z + halfD, width, Vector3.new(0, 0, 1), false },
			{ "z", origin.X - halfW, origin.Z, depth - WALL_THICKNESS, Vector3.new(-1, 0, 0), false },
			{ "z", origin.X + halfW, origin.Z, depth - WALL_THICKNESS, Vector3.new(1, 0, 0), false },
		}
		local wallWindows = {}
		for index, wall in ipairs(walls) do
			-- A terrace's SIDE walls (3 and 4) are party walls: no windows, and a flatter colour, so a
			-- row reads as one continuous frontage from the street. They are still this building's own
			-- walls -- nothing is shared across models, by the Cities tab's decision (2026-09-18): a
			-- wall owned by one model leaves its neighbour's interior open when DestructibleService
			-- shoots it out, footing_probe measures per model, and two models sharing a plane is the
			-- flush case the map's z-fight pass fights on every build. They sit 3 studs apart in
			-- buildTown's alley band and the Cities tab closes that gap at the front with its own wall.
			local party = partyWalls and index >= 3
			local windows = buildWall(model, wall[1], wall[2], wall[3], wall[4], baseY + 0.5, floorHeight,
				wallMat, party and partyColor or wallColor, wall[6], not party)
			dressWall(model, wall[1], wall[2], wall[3], wall[4], baseY, floorHeight, wall[5], windows, facade, floor)
			if index == 1 then
				frontWindows[floor] = windows
			end
			wallWindows[index] = windows
		end
		-- The lanes inside the door and every window, before anything else claims this floor.
		claimOpenings(room, origin, halfW, halfD, wallWindows, isGround)

		-- A light panel on the ceiling. A house's top floor has no ceiling, only the roof, so its light is
		-- fixed flat against the underside of the roof slope instead of hanging in mid-air.
		currentName = "CeilingLight"
		local lightX, lightZ = origin.X + halfW * 0.3, origin.Z + halfD * 0.3
		local lightFrame = CFrame.new(lightX, baseY + floorHeight - 0.62, lightZ)
		if archetype == "house" and floor == floors - 1 then
			lightFrame = roofUnderside(origin, depth, origin.Y + floors * floorHeight, lightX, lightZ) * CFrame.new(0, -0.095, 0)
		end
		trim(model, Vector3.new(3, 0.15, 3), lightFrame, Color3.fromRGB(255, 244, 214), Enum.Material.Neon)
		currentName = "Part"

		if canClimb then
			if floor < floors - 1 then
				buildStairs(model,
					origin.X - halfW + STAIR_WIDTH / 2 + 1,
					origin.Z - halfD + 1 + STAIR_LANDING,
					baseY + 0.5, preset.floorMaterial, wallColor)
			end
			-- The stairs, the landing at their foot, the well above them and the clear floor round
			-- them: nothing else on this floor goes in the strip.
			room:AddRect(origin.X - halfW + stairSide / 2, origin.Z - halfD + stairClear / 2, stairSide / 2, stairClear / 2)
		end
		if isGround then
			room:AddCircle(origin.X, origin.Z - halfD + 3, 6)
		end

		-- Interior partition. It runs wall to wall with a doorway in the middle, stopping
		-- PARTITION_WALL_GAP short of each side wall's inner face: far too thin to see or shoot through
		-- (it used to stop 0.3 short, a visible slit), and never touching the wall, so the map's z-fight
		-- pass has no contact between the two to act on. Where it would cross the stairs' strip it
		-- starts beside the strip instead, a solid wall with the way round it by the stairs; it used
		-- to cut straight through a flight or stand across the top of one.
		-- It meets the side walls between their windows, never across one (partitionZ).
		local sideWindows = table.clone(wallWindows[3])
		for _, offset in ipairs(wallWindows[4]) do
			table.insert(sideWindows, offset)
		end
		local partitionLimit = math.max(3, math.floor(halfD - 4))
		local partitionAt = width > 30 and random() < 0.6
			and partitionZ(random(2, partitionLimit), partitionLimit, sideWindows) or nil
		if partitionAt then
			local wallZ = origin.Z + partitionAt
			local right = origin.X + halfW - WALL_THICKNESS / 2 - PARTITION_WALL_GAP
			local left = origin.X - halfW + WALL_THICKNESS / 2 + PARTITION_WALL_GAP
			local besideStairs = canClimb and wallZ - WALL_THICKNESS / 2 < origin.Z - halfD + stairClear
			if besideStairs then
				left = origin.X - halfW + stairSide
			end
			buildWall(model, "x", (left + right) / 2, wallZ, right - left, baseY + 0.5, floorHeight * 0.92,
				wallMat, wallColor, not besideStairs, false)
			room:AddStrip(Vector3.new(origin.X - halfW, 0, wallZ), Vector3.new(origin.X + halfW, 0, wallZ), 2.2)
			if not besideStairs then
				room:AddCircle(origin.X, wallZ, 5)
			end
		end

		-- Loot first, so furniture fits around it rather than on top of it: a chest anywhere, a
		-- heal against the back wall on every floor you can reach, and a gun in the ground-floor room.
		if isGround or canClimb then
			local chestX, chestZ = freeSpot(room, origin, reachX, reachZ, 2.6)
			if chestX then
				table.insert(localChests, CFrame.new(chestX, baseY + 3, chestZ))
			end
			local healX, healZ = freeSpot(room, origin, reachX, reachZ, 1.8, origin.Z + halfD - 3)
			if healX then
				table.insert(localLoot.heal, Vector3.new(healX, baseY + 0.6, healZ))
			end
		end
		if isGround then
			local gunX, gunZ = freeSpot(room, origin, reachX, reachZ, 1.8)
			if gunX then
				table.insert(localLoot.weapon, Vector3.new(gunX, baseY + 0.6, gunZ))
			end
		end

		buildInterior(model, origin, width, depth, baseY, floorHeight, room, archetype, floor, style,
			canClimb and stairClear or nil, wallWindows)
	end

	local topY = origin.Y + floors * floorHeight
	-- A "barn" is a warehouse under a pitched roof. NOTE for whoever tunes loot: a pitched roof has no
	-- flat top, so a barn does not get the roof chest a warehouse gets. A town of barns therefore holds
	-- fewer chests than the same town of warehouses -- deliberate here, but say the word and I will
	-- put that chest somewhere else on a barn rather than drop it.
	if archetype == "house" or plan.variant == "barn" then
		buildPitchedRoof(model, origin, width, depth, topY, roofMat, roofColor)
	else
		buildFlatRoof(model, origin, width, depth, topY, roofMat, roofColor)
		table.insert(localChests, CFrame.new(origin.X, topY + 3, origin.Z))
	end

	-- Door trim, awnings, chimneys and rooftop clutter, then the street-level detail.
	decorateBuilding(model, origin, archetype, width, depth, topY, wallColor, DOOR_WIDTH)
	dressGround(model, origin, archetype, width, depth, floors * floorHeight, facade)

	if archetype == "tower" and floors > 1 then
		local floor = random(1, floors - 1)
		local windows = frontWindows[floor]
		if windows and #windows > 0 then
			addBalcony(model, origin, halfD, pick(windows), origin.Y + floor * floorHeight, facade)
		end
	end
	if plan.dock then
		addLoadingDock(model, origin, halfW, halfD)
	end

	-- On the doorstep, under the awning.
	table.insert(localLoot.weapon, Vector3.new(origin.X + random(-6, 6), origin.Y, origin.Z - halfD - 5))
	-- Flat roofs reward the climb with a movement item, off to one side of the rooftop chest (the
	-- one rooftop corner the clutter never uses).
	if archetype ~= "house" then
		table.insert(localLoot.item, Vector3.new(origin.X + halfW * 0.4, topY + 0.6, origin.Z - halfD * 0.4))
	end

	-- Face the street.
	local turn = CFrame.new(origin) * CFrame.Angles(0, yaw, 0) * CFrame.new(-origin)
	if math.abs(yaw) > 1e-3 then
		local parts, cframes = {}, {}
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
				table.insert(cframes, turn * descendant.CFrame)
			end
		end
		workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end
	-- For footing_probe: the ground floor's grade and what stands on it, round a pivot at the
	-- footprint's centre (after the turn: moving the parts doesn't move a model's pivot).
	local contact = groundContact(plan)
	model.WorldPivot = turn * CFrame.new(origin.X, origin.Y, origin.Z + contact.offsetZ)
	model:SetAttribute("FootingBase", origin.Y)
	model:SetAttribute("FootingSize", Vector3.new(contact.halfX * 2, 0, contact.halfZ * 2))
	for _, spot in ipairs(localChests) do
		table.insert(chestSpots, turn * spot)
	end
	for kind, spots in pairs(localLoot) do
		for _, spot in ipairs(spots) do
			table.insert(lootSpots[kind], turn * spot)
		end
	end
end

--------------------------------------------------------------------------------
-- Props
--------------------------------------------------------------------------------

-- Trees, rocks and the rest of the open-ground scenery live in MapDecor.

local function buildCrate(parent, position)
	-- One back yard in four keeps a pair of explosive barrels instead of a crate.
	if math.random() < 0.25 then
		local yaw = math.random() * math.pi * 2
		local across = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
		HazardService.Barrel(parent, CFrame.new(position - across * 2) * CFrame.Angles(0, yaw, 0))
		HazardService.Barrel(parent, CFrame.new(position + across * 2) * CFrame.Angles(0, yaw + 0.7, 0))
		return
	end
	currentName = "YardCrate"
	makePart(parent, Vector3.new(6, 6, 6),
		CFrame.new(position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, math.random() * 3, 0),
		Color3.fromRGB(150, 112, 68), Enum.Material.WoodPlanks)
	currentName = "Part"
end

MapBuildings.RollPlan = rollPlan
-- How wide a front door is, for anything keeping the way to it clear (MapGenerator claims the path).
MapBuildings.DoorWidth = DOOR_WIDTH
MapBuildings.BuildBuilding = buildBuilding
MapBuildings.BuildCrate = buildCrate
MapBuildings.Footprint = footprint

return MapBuildings
