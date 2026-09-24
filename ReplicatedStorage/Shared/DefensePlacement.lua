-- Where a portable defense goes up: the placement rules DefenseService builds by, shared with the
-- client so the translucent preview (StarterPlayerScripts/DefensePreview) shows exactly the site the
-- server will use. One copy of the rules, so the two can't drift apart.
--
--   DefensePlacement.Sizes[itemId]                               each structure's box (studs)
--   DefensePlacement.ThrowTarget(from, look, aimPoint)          -> target, facing
--   DefensePlacement.FindSite(character, size, centre, flat, defenses, extraExclude)
--                                                               -> origin CFrame, nil, plan
--                                                               or nil, why not
--   DefensePlacement.Landing(from, velocity, flightTime, params) -> where a thrown kit comes down
--
-- "Place it anywhere" (OLIVER_LIST #128, Oliver 09-24: "allow defense placement anywhere"). FindSite
-- no longer refuses a site for being sloped, wet, cluttered or against a wall; it works out HOW the
-- structure stands there, and the plan it returns is what DefenseService builds and what the preview
-- draws, footings included:
--   * sloped or uneven ground, rooftops: a bunker or fortress is built LEVEL at the highest ground
--     under it, and every lower edge gets a post down to the ground, so nothing hangs in the air and
--     nothing is buried in the hill; a barricade (a wall) tilts along its length to follow the
--     ground, up to WallTilt, and posts take up whatever is left;
--   * rubble and small props: sat over, the way a pad sits over a stone; loose debris is shoved;
--   * shallow water: posts down to the bed, with floats at the waterline;
--   * over a ledge: posts where the ground below is in reach, and up to half of it may overhang;
--   * against a wall or in a gap too small for it: slid to the nearest spot within SlideMax that is
--     free, rather than refused.
-- What it still refuses, because each one protects somebody: a player, bot or vehicle in the way;
-- a spawn (the pads, the team bunker), an objective's centre, a team base's vehicle bays and their
-- ways out (TeamBaseRuins tags those "NoBuild"); a doorway or a covered passage the structure would seal; the lobby; nothing to stand on
-- at all (off the map, deep water); and anything tagged "NoBuild". The count cap stays in
-- DefenseService. `defenses` is the folder built defenses live in, which never counts as ground;
-- `extraExclude` lets the client leave out what only it has (the camera's viewmodel and preview,
-- client-side effects), which the server never sees. Proven offline by tools/defense_anywhere_check.py.

local DefensePlacement = {}

-- #128 B's slope allowances. Since "anywhere" (#128, 09-24) they no longer refuse a site: a slope is
-- levelled and stood on posts instead. Kept, with the numbers tools/defense_throw_probe.lua pins,
-- because they are still the honest answer to "how steep can this stand with no footing at all".
DefensePlacement.MaxSlope = 5
-- How much drop a site may have across the footprint, per structure. One number for all three made
-- the limit an accident of size: the five sampled points are the centre and the corners inset 0.5, so
-- 5 studs of drop is ~24 degrees across a barricade's 11-stud span, ~14 across a bunker's 19.8 and
-- only ~10 across a fortress's 28.3 -- the biggest thing in the game was also the fussiest, which
-- nobody chose. A barricade is a fence and tolerates more; the fortress is held to the bunker's ANGLE
-- (14.2 degrees) over its own diagonal, which is 7.2 studs. Anything not listed keeps that angle too,
-- never stricter than MaxSlope.
DefensePlacement.MaxSlopeFor = {
	RotBarricade = 7,
	PopupBunker = 5,
	BrainrotFortress = 7.2,
}
DefensePlacement.SlopeAngle = math.rad(14.2)

-- The drop a footprint of `size` may have. Sizes are shared table values, so the structure is
-- recognised by identity; an unknown footprint gets the angle over its own sampled diagonal.
function DefensePlacement.SlopeAllowance(size)
	for id, known in pairs(DefensePlacement.Sizes) do
		if known == size then
			return DefensePlacement.MaxSlopeFor[id] or DefensePlacement.MaxSlope
		end
	end
	local halfX, halfZ = size.X / 2 - 0.5, size.Z / 2 - 0.5
	local span = 2 * math.sqrt(halfX * halfX + halfZ * halfZ)
	return math.max(DefensePlacement.MaxSlope, span * math.tan(DefensePlacement.SlopeAngle))
end
-- How far a kit can be thrown.
DefensePlacement.ThrowRange = 60
-- Where a kit comes to rest is lifted this far before the site checks (DefenseService.landKit).
DefensePlacement.LandLift = 1

DefensePlacement.Sizes = {
	RotBarricade = Vector3.new(12, 7.5, 1.6),
	PopupBunker = Vector3.new(15, 8.5, 15),
	BrainrotFortress = Vector3.new(21, 12, 21),
}

-- Workspace folders that are never ground and never in the way: pickups, companions, effects,
-- deployables, supply drops.
DefensePlacement.IgnoredFolders = { "Loot", "Companions", "Effects", "Deployables", "SupplyDrops" }
-- The overlap check ignores the same, except deployables (a launch pad in the box blocks a build).
DefensePlacement.OverlapIgnoredFolders = { "Loot", "Companions", "Effects", "SupplyDrops" }

-- Where a throw from `from`, with the thrower looking along `look`, aimed at `aimPoint` (already
-- checked by the caller; nil throws straight ahead) comes down, and which way the structure faces:
-- along the aim, or the thrower's facing when the aim is straight down at their feet. The throw is
-- clamped to ThrowRange.
function DefensePlacement.ThrowTarget(from, look, aimPoint)
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)
	local target = aimPoint or (from + look * 30)
	local offset = target - from
	if offset.Magnitude > DefensePlacement.ThrowRange then
		offset = offset.Unit * DefensePlacement.ThrowRange
	end
	local facing = Vector3.new(offset.X, 0, offset.Z)
	facing = facing.Magnitude > 0.5 and facing.Unit or flatLook
	return from + offset, facing, offset
end

-- Where a thrown kit actually leaves the hand: ThrowLead in front of the head and ThrowLift up,
-- unless something solid is nearer than that. Pressed against a building wall, the unclipped point
-- sat on the FAR side of it, so the kit settled, built or armed inside the building: a 95-damage Rot
-- Mine nobody could reach. ProjectileService.handOrigin already clips a grenade's origin the same
-- way; this is that clip, in the shared module so the server's throw and the client's ghost cannot
-- drift apart. Solid geometry only (RespectCanCollide), so a bush or a decal doesn't shorten a throw.
DefensePlacement.ThrowLead = 2
DefensePlacement.ThrowLift = 0.5
-- The kit is a stud and a half across at its throw scale; half of that, and a little margin, is how
-- far short of the wall the kit's CENTRE has to start so no part of it is inside the wall.
DefensePlacement.ThrowSkin = 0.9

function DefensePlacement.ThrowOrigin(character, headPosition, look, extraExclude)
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)
	local wanted = headPosition + flatLook * DefensePlacement.ThrowLead + Vector3.new(0, DefensePlacement.ThrowLift, 0)
	local params = DefensePlacement.GroundParams(character, nil, extraExclude)
	params.RespectCanCollide = true
	local delta = wanted - headPosition
	if delta.Magnitude < 1e-4 then
		return wanted
	end
	-- Cast ThrowSkin PAST the spawn point, not just to it: a wall standing exactly at the spawn point
	-- is not "between" head and point, so a ray that stops there reports nothing and the kit is left
	-- centred on the wall's face with half of itself inside (measured at a 2.0 gap,
	-- tools/defense_throw_probe.lua).
	local direction = delta.Unit
	local hit = workspace:Raycast(headPosition, delta + direction * DefensePlacement.ThrowSkin, params)
	if not hit then
		return wanted
	end
	-- Pulled back so the kit's whole width clears the wall. Where there isn't room in front of the
	-- head for that -- pressed against a wall closer than the kit is wide -- it goes BEHIND the head
	-- rather than into the wall: inside the thrower's own body, which physics resolves against the
	-- thrower, on their side of the wall. Never further back than the kit is deep.
	local keep = math.clamp(hit.Distance - DefensePlacement.ThrowSkin, -DefensePlacement.ThrowSkin, delta.Magnitude)
	return headPosition + direction * keep
end

-- The lob itself, in one place: DefenseService throws the kit on this arc and the client's preview
-- walks the same one to work out where the kit will actually arrive. Longer throws take longer, so the
-- arc keeps its shape; the velocity is the one that puts the kit on `target` after `flightTime` under
-- the world's gravity. Returns velocity, flightTime, target, facing, offset.
DefensePlacement.ThrowSpeed = 40
DefensePlacement.ThrowMinTime = 0.5
DefensePlacement.ThrowMaxTime = 1.6

function DefensePlacement.ThrowArc(from, look, aimPoint)
	local target, facing, offset = DefensePlacement.ThrowTarget(from, look, aimPoint)
	local flightTime = math.clamp(offset.Magnitude / DefensePlacement.ThrowSpeed, DefensePlacement.ThrowMinTime, DefensePlacement.ThrowMaxTime)
	local velocity = Vector3.new(offset.X / flightTime, offset.Y / flightTime + 0.5 * workspace.Gravity * flightTime, offset.Z / flightTime)
	return velocity, flightTime, target, facing, offset
end

-- Where that arc first meets the world, walked in `steps` straight segments with a raycast each: the
-- kit is thrown flat enough that on a hill it can arrive well short of the aim, and this is the only
-- honest answer to "where will it land". Returns the point and whether anything was hit at all (when
-- nothing is, the arc's end is returned, which is the aim point).
function DefensePlacement.TraceThrow(from, velocity, flightTime, params, steps)
	steps = steps or 20
	local gravity = workspace.Gravity
	local previous = from
	for index = 1, steps do
		local t = flightTime * index / steps
		local point = from + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
		local hit = params and workspace:Raycast(previous, point - previous, params) or nil
		if hit then
			-- The time the arc actually reaches the hit, not the end of the segment it is on: a kit
			-- flown along the arc to this time arrives on the spot.
			local before = flightTime * (index - 1) / steps
			return hit.Position, true, before + (t - before) * hit.Distance / math.max((point - previous).Magnitude, 1e-6)
		end
		previous = point
	end
	return previous, false, flightTime
end

-- A point on the lob `t` seconds after the throw.
function DefensePlacement.ArcPoint(from, velocity, t)
	return from + velocity * t - Vector3.new(0, 0.5 * workspace.Gravity * t * t, 0)
end

-- How long past the aimed flight a kit keeps falling looking for something to land on: aimed at the
-- sky or off a cliff, the arc's end is in the air.
DefensePlacement.FallTime = 3

-- Where a kit thrown on this arc comes down, and when: the arc walked as TraceThrow walks it, and
-- carried on falling past its aimed end when it met nothing. DefenseService builds exactly here -- it
-- no longer lets the kit's physics decide, so nothing bounces or rolls off the spot -- and the
-- preview draws exactly here. Returns the point, whether anything was met, and the time.
function DefensePlacement.Landing(from, velocity, flightTime, params)
	local point, struck, t = DefensePlacement.TraceThrow(from, velocity, flightTime, params)
	if struck then
		return point, true, t
	end
	local previous = point
	local steps = 30
	for index = 1, steps do
		local at = flightTime + DefensePlacement.FallTime * index / steps
		local next_ = DefensePlacement.ArcPoint(from, velocity, at)
		local hit = params and workspace:Raycast(previous, next_ - previous, params) or nil
		if hit then
			local before = flightTime + DefensePlacement.FallTime * (index - 1) / steps
			return hit.Position, true, before + (at - before) * hit.Distance / math.max((next_ - previous).Magnitude, 1e-6)
		end
		previous = next_
	end
	return point, false, flightTime
end

local function addFolders(list, names)
	for _, name in ipairs(names) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(list, instance)
		end
	end
end

function DefensePlacement.GroundParams(character, defenses, extraExclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if character then
		table.insert(filter, character)
	end
	if defenses then
		table.insert(filter, defenses)
	end
	addFolders(filter, DefensePlacement.IgnoredFolders)
	for _, instance in ipairs(extraExclude or {}) do
		table.insert(filter, instance)
	end
	params.FilterDescendantsInstances = filter
	return params
end

--------------------------------------------------------------------------------
-- Anywhere (#128): how a structure stands where it landed
--------------------------------------------------------------------------------

-- How far the base is set INTO the highest ground under it. Not zero: a pad sat exactly on a part
-- floor shares its plane with it, and the two flicker.
DefensePlacement.Embed = 0.15
-- The ground is sampled on a grid about this fine, its outer columns on the footprint's edges.
DefensePlacement.ColumnStep = 3.5
-- Ground rising faster than this from where the kit landed is a wall or a cliff, not a slope, and
-- the structure slides away from it. 62 degrees so a 60-degree hill is still a hill.
DefensePlacement.MaxClimb = math.rad(62)
-- Small things on the ground -- rubble, a crate, a kerb -- are sat over: no bigger than PropSize
-- across and no taller than PropHeight above the ground round them. Unanchored ones are shoved.
DefensePlacement.PropHeight = 3
DefensePlacement.PropSize = 6
-- The longest post. Ground further down than this is not under the structure at all.
DefensePlacement.MaxStilt = 40
-- A deck over water stands this far above the surface, on floats.
DefensePlacement.WaterClear = 0.8
-- How far a barricade tilts to follow the ground along its length; posts take up the rest.
DefensePlacement.WallTilt = math.rad(40)
-- At least this share of the footprint needs ground within MaxStilt, on both sides of the centre
-- both ways: up to half may hang over a ledge, none of it may hang off one side.
DefensePlacement.SupportShare = 0.5
-- Against a wall: the nearest spot this far away that is free, looked for in rings SlideStep apart.
DefensePlacement.SlideStep = 2
-- 14: a fortress thrown into a doorway has to come 13 studs out of it (its half-width and a body's
-- width clear of the door).
DefensePlacement.SlideMax = 14
-- A body's width (an R15 is 2 across, 2.2 with its arms swinging). Leaving less than this between a
-- structure and a wall across a covered passage, or in front of a doorway, shuts someone in.
DefensePlacement.DoorGap = 2.2
-- Posts: a gap shorter than PostMin is bedding, not a stilt.
DefensePlacement.PostMin = 0.35
DefensePlacement.PostWidth = 0.8
-- How far a post goes into the ground: deep enough that the downhill side of its own 0.8-stud foot is
-- still in the ground on a 60-degree slope.
DefensePlacement.FootEmbed = 1
-- A door more than a step up gets a ladder, or a raised bunker is a bunker nobody can get into.
DefensePlacement.LadderStep = 1.5
-- The protected places.
DefensePlacement.ObjectiveCentreShare = 0.35
DefensePlacement.SpawnMargin = 4
DefensePlacement.NoBuildTag = "NoBuild"

-- What each structure needs beyond its box: a wall tilts along its length; a door (the local spot
-- just outside the back doorway, where a ladder goes) and the deck height it opens onto.
DefensePlacement.Profiles = {
	-- `bounds`: the ground the structure really covers, local (the columns, the posts under its edges and
	-- the box that must be clear all use it): the barricade's rail and posts reach 6.2 each way, the
	-- bunker's corner posts 7.5, the fortress's pad and towers 10.1. A post stands at each edge column
	-- and must be under something, so these are never wider than that. `rows`: extra columns (and
	-- posts) under anything standing outside the bounds -- the bunker's sandbag row, out in front of
	-- its pad at z -7.6, from x -6.3 to 6.3.
	RotBarricade = { wall = true, bounds = { x0 = -6.2, x1 = 6.2, z0 = -0.8, z1 = 0.8 } },
	PopupBunker = { door = Vector3.new(0, 0, 8.55), deck = 0.4, metal = true, bounds = { x0 = -7.5, x1 = 7.5, z0 = -7.5, z1 = 7.5 },
		rows = { { z = -8.15, x0 = -6.25, x1 = 6.25 } } },
	BrainrotFortress = { door = Vector3.new(0, 0, 11.05), deck = 0.5, metal = true,
		bounds = { x0 = -10.1, x1 = 10.1, z0 = -10.1, z1 = 10.1 } },
}

DefensePlacement.FootingLook = {
	timber = { color = Color3.fromRGB(116, 84, 52), material = Enum.Material.WoodPlanks },
	steel = { color = Color3.fromRGB(58, 60, 68), material = Enum.Material.Metal },
	float = { color = Color3.fromRGB(196, 72, 48), material = Enum.Material.SmoothPlastic },
}

-- Every refusal left, and nothing else: each protects somebody (or there is nothing to stand on).
DefensePlacement.Refusals = {
	body = "Someone's in the way.",
	spawn = "Keep the spawn clear.",
	objective = "Not on the objective's centre.",
	lane = "Keep the vehicle bays' way out clear.",
	door = "That would shut a doorway.",
	lobby = "Not in the lobby.",
	ground = "Nothing under it to stand on.",
	room = "No room to build here.",
	nobuild = "Can't build here.",
}

local CollectionService = game:GetService("CollectionService")

local function profileOf(size)
	for id, known in pairs(DefensePlacement.Sizes) do
		if known == size then
			return DefensePlacement.Profiles[id] or {}, id
		end
	end
	return {}, nil
end

-- The player, bot or vehicle an instance belongs to, if any: never ground, and never built into.
function DefensePlacement.BodyOf(instance)
	local node = instance
	while node and node ~= workspace do
		if node:IsA("Model") and (node:FindFirstChildOfClass("Humanoid") or node:GetAttribute("VehicleMaxHealth") ~= nil
			or node:FindFirstChildOfClass("VehicleSeat")) then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Whether two boxes (CFrame, Size) overlap by more than a hair: the separating-axis test.
-- GetPartBoundsInBox answers with bounding boxes, so a sloped roof slab whose ridge is far above the
-- structure "overlaps" it; this is the exact answer that query is filtered through.
function DefensePlacement.BoxesOverlap(cfA, sizeA, cfB, sizeB)
	local a = { cfA.RightVector, cfA.UpVector, cfA.LookVector }
	local b = { cfB.RightVector, cfB.UpVector, cfB.LookVector }
	local ha = { sizeA.X / 2, sizeA.Y / 2, sizeA.Z / 2 }
	local hb = { sizeB.X / 2, sizeB.Y / 2, sizeB.Z / 2 }
	local axes = { a[1], a[2], a[3], b[1], b[2], b[3] }
	for i = 1, 3 do
		for j = 1, 3 do
			local cross = a[i]:Cross(b[j])
			if cross.Magnitude > 1e-6 then
				table.insert(axes, cross.Unit)
			end
		end
	end
	local d = cfB.Position - cfA.Position
	for _, axis in ipairs(axes) do
		local ra = ha[1] * math.abs(a[1]:Dot(axis)) + ha[2] * math.abs(a[2]:Dot(axis)) + ha[3] * math.abs(a[3]:Dot(axis))
		local rb = hb[1] * math.abs(b[1]:Dot(axis)) + hb[2] * math.abs(b[2]:Dot(axis)) + hb[3] * math.abs(b[3]:Dot(axis))
		if math.abs(d:Dot(axis)) >= ra + rb - 0.02 then
			return false
		end
	end
	return true
end

-- The highest point of a part, whatever its rotation.
local function topOf(part)
	local cf, size = part.CFrame, part.Size
	return cf.Y + math.abs(cf.RightVector.Y) * size.X / 2 + math.abs(cf.UpVector.Y) * size.Y / 2
		+ math.abs(cf.LookVector.Y) * size.Z / 2
end

local function rebuildParams(ctx)
	local extra = {}
	for _, instance in ipairs(ctx.extra) do
		table.insert(extra, instance)
	end
	for _, instance in ipairs(ctx.skip) do
		table.insert(extra, instance)
	end
	-- Solid things only: a camo net or a sign is not what a post stands on.
	ctx.ground = DefensePlacement.GroundParams(ctx.character, ctx.defenses, extra)
	ctx.ground.RespectCanCollide = true
	ctx.dry = DefensePlacement.GroundParams(ctx.character, ctx.defenses, extra)
	ctx.dry.RespectCanCollide = true
	ctx.dry.IgnoreWater = true
end

-- A ray that passes through players, bots and vehicles: they are never ground, and whether one is in
-- the way is the overlap check's business.
local function cast(ctx, from, direction, dry)
	for _ = 1, 6 do
		local hit = workspace:Raycast(from, direction, dry and ctx.dry or ctx.ground)
		if not hit then
			return nil
		end
		local body = DefensePlacement.BodyOf(hit.Instance)
		if not body then
			return hit
		end
		table.insert(ctx.skip, body)
		rebuildParams(ctx)
	end
	return nil
end

-- One column of ground: `floor` is what a post stands on (the bed, under water), `top` is what the
-- deck must clear (the waterline plus WaterClear, over water), `surface` the waterline.
local function column(ctx, x, z, top, bottom)
	local from = Vector3.new(x, top, z)
	local down = Vector3.new(0, bottom - top, 0)
	local hit = cast(ctx, from, down, false)
	local col = { x = x, z = z }
	if not hit then
		return col
	end
	if ctx.lobby and hit.Instance:IsDescendantOf(ctx.lobby) then
		col.lobby = true
	end
	if hit.Material == Enum.Material.Water then
		col.surface = hit.Position.Y
		local bed = cast(ctx, from, down, true)
		col.floor = bed and bed.Position.Y or nil
		col.top = col.surface + DefensePlacement.WaterClear
	else
		col.floor = hit.Position.Y
		col.top = col.floor
	end
	return col
end

local function newContext(character, size, flat, defenses, extraExclude)
	local profile, id = profileOf(size)
	local ctx = { character = character, size = size, profile = profile, id = id, defenses = defenses,
		extra = extraExclude or {}, skip = {} }
	ctx.facing = CFrame.lookAt(Vector3.zero, flat)
	ctx.right = ctx.facing.RightVector
	ctx.look = ctx.facing.LookVector
	ctx.halfX, ctx.halfZ = size.X / 2, size.Z / 2
	ctx.probeUp = math.sqrt(ctx.halfX * ctx.halfX + ctx.halfZ * ctx.halfZ) * math.tan(DefensePlacement.MaxClimb)
		+ DefensePlacement.PropHeight + 2
	ctx.lobby = workspace:FindFirstChild("Lobby")
	-- The columns span what the structure really covers on the ground (Profiles.bounds), which is a
	-- little more than its box for some: the bunker's sandbag row stands out in front of its pad.
	local bounds = profile.bounds or {}
	local function axis(lo, hi)
		lo, hi = lo + 0.05, hi - 0.05
		local count = math.max(2, math.ceil((hi - lo) / DefensePlacement.ColumnStep) + 1)
		local list = {}
		for index = 0, count - 1 do
			table.insert(list, lo + (hi - lo) * index / (count - 1))
		end
		return list, (hi - lo) / (count - 1)
	end
	ctx.bounds = { x0 = bounds.x0 or -ctx.halfX, x1 = bounds.x1 or ctx.halfX, z0 = bounds.z0 or -ctx.halfZ, z1 = bounds.z1 or ctx.halfZ }
	local xs, zs
	xs, ctx.stepX = axis(ctx.bounds.x0, ctx.bounds.x1)
	zs, ctx.stepZ = axis(ctx.bounds.z0, ctx.bounds.z1)
	ctx.grid = {}
	for ix, x in ipairs(xs) do
		for iz, z in ipairs(zs) do
			table.insert(ctx.grid, { lx = x, lz = z, ix = ix, iz = iz, edge = ix == 1 or ix == #xs or iz == 1 or iz == #zs })
		end
	end
	ctx.nx, ctx.nz = #xs, #zs
	ctx.box = { x0 = ctx.bounds.x0, x1 = ctx.bounds.x1, z0 = ctx.bounds.z0, z1 = ctx.bounds.z1 }
	for rowIndex, row in ipairs(profile.rows or {}) do
		local rowXs = (axis(row.x0, row.x1))
		for index, x in ipairs(rowXs) do
			table.insert(ctx.grid, { lx = x, lz = row.z, ix = 900 + index, iz = 900 + rowIndex, edge = true, extra = true })
		end
		ctx.box.x0, ctx.box.x1 = math.min(ctx.box.x0, row.x0), math.max(ctx.box.x1, row.x1)
		ctx.box.z0, ctx.box.z1 = math.min(ctx.box.z0, row.z - 0.1), math.max(ctx.box.z1, row.z + 0.1)
	end
	rebuildParams(ctx)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if character then
		table.insert(filter, character)
	end
	addFolders(filter, DefensePlacement.OverlapIgnoredFolders)
	for _, instance in ipairs(ctx.extra) do
		table.insert(filter, instance)
	end
	overlap.FilterDescendantsInstances = filter
	ctx.overlap = overlap
	return ctx
end

-- The columns under a footprint centred on `c`, with a wall tilted by `roll` (its length then covers
-- less ground: the columns move in by cos(roll)).
local function sample(ctx, c, roll, top, bottom)
	local cols = {}
	local cosR = math.cos(roll)
	for _, cell in ipairs(ctx.grid) do
		local offset = ctx.facing:VectorToWorldSpace(Vector3.new(cell.lx * cosR, 0, cell.lz))
		local col = column(ctx, c.X + offset.X, c.Z + offset.Z, top, bottom)
		col.lx, col.lz, col.edge, col.ix, col.iz, col.extra = cell.lx, cell.lz, cell.edge, cell.ix, cell.iz, cell.extra
		col.dist = math.sqrt(cell.lx * cosR * cell.lx * cosR + cell.lz * cell.lz)
		table.insert(cols, col)
	end
	return cols
end

-- The tilt that lays a wall along the ground: the best straight line through the columns' heights
-- along its length, leaving out the ones that drop away (a ledge is not a slope to follow).
local function fitRoll(cols, ref)
	local climb = math.tan(DefensePlacement.MaxClimb)
	local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
	for _, col in ipairs(cols) do
		if col.top and math.abs(col.top - ref) <= col.dist * climb + DefensePlacement.PropHeight then
			n += 1
			sx += col.lx
			sy += col.top
			sxx += col.lx * col.lx
			sxy += col.lx * col.top
		end
	end
	local denom = n * sxx - sx * sx
	if n < 2 or denom < 1e-6 then
		return 0
	end
	return math.clamp(math.atan((n * sxy - sx * sy) / denom), -DefensePlacement.WallTilt, DefensePlacement.WallTilt)
end

-- Whether a wall, a cliff or a fence stands in the footprint. The ground is walked from the columns
-- round the centre, where the kit landed, to their neighbours: up no steeper than MaxClimb, down as
-- far as it likes (dropping off a ledge is what posts are for). A column that can't be reached that
-- way is the top of something the structure would be built through or balanced on: slide instead.
-- A radial "no higher than the slope from the centre" rule let a 6-stud fence between two columns
-- through as a bump, and the barricade was balanced on top of it.
local function walled(ctx, cols, ref, roll)
	local climb = math.tan(DefensePlacement.MaxClimb)
	local stepX, stepZ = ctx.stepX * math.cos(roll), ctx.stepZ
	local byCell = {}
	for _, col in ipairs(cols) do
		byCell[col.ix * 1000 + col.iz] = col
	end
	local reached, queue = {}, {}
	for _, col in ipairs(cols) do
		if not col.extra and col.top and col.dist <= math.max(stepX, stepZ) and col.top <= ref + col.dist * climb + DefensePlacement.PropHeight then
			reached[col] = true
			table.insert(queue, col)
		end
	end
	local head = 1
	while head <= #queue do
		local col = queue[head]
		head += 1
		for _, step in ipairs({ { 1, 0, stepX }, { -1, 0, stepX }, { 0, 1, stepZ }, { 0, -1, stepZ } }) do
			local next_ = byCell[(col.ix + step[1]) * 1000 + col.iz + step[2]]
			if next_ and next_.top and not reached[next_] and next_.top <= col.top + step[3] * climb then
				reached[next_] = true
				table.insert(queue, next_)
			end
		end
	end
	-- Unreached but low (the far side of a gap) is not a wall. An extra row is judged against the
	-- nearest reached column: no steeper than MaxClimb from it.
	for _, col in ipairs(cols) do
		local high = col.top and col.top > ref + DefensePlacement.PropHeight
		if col.extra and col.top then
			local nearest, gap = nil, math.huge
			for _, other in ipairs(cols) do
				if reached[other] then
					local d = math.sqrt((other.x - col.x) ^ 2 + (other.z - col.z) ^ 2)
					if d < gap then
						nearest, gap = other, d
					end
				end
			end
			high = not nearest or col.top > nearest.top + gap * climb
		end
		if high and (col.extra or not reached[col]) then
			return true
		end
	end
	return false
end

-- How far a point is from a footprint (level frame, half extents), on the ground plane.
local function footprintDistance(frame, halfX, halfZ, x, z)
	local p = frame:PointToObjectSpace(Vector3.new(x, frame.Y, z))
	local dx = math.max(math.abs(p.X) - halfX, 0)
	local dz = math.max(math.abs(p.Z) - halfZ, 0)
	return math.sqrt(dx * dx + dz * dz)
end

-- The protected places, from what the world itself shows (the client has to reach the same answer
-- for its preview, so nothing here may come from a server-only table): an objective's centre (the
-- Hill models' own HillX/HillZ/HillRadius), a spawn (any SpawnLocation, and a team base's "Spawn"
-- bunker), and anything tagged NoBuild -- a team base's bays and their ways out (TeamBaseRuins'
-- NoBuildLane parts, whose NoBuildReason says so), and the way in for any other place to keep clear.
-- Tags replicate, so the client's preview sees the same zones.
local function zoneRefusal(ctx, frame)
	local R = DefensePlacement.Refusals
	local box = frame * CFrame.new(0, ctx.size.Y / 2, 0)
	local hill = workspace:FindFirstChild("Hill")
	if hill then
		for _, objective in ipairs(hill:GetChildren()) do
			local x, z, radius = objective:GetAttribute("HillX"), objective:GetAttribute("HillZ"), objective:GetAttribute("HillRadius")
			if x and z and radius and footprintDistance(frame, ctx.halfX, ctx.halfZ, x, z) < radius * DefensePlacement.ObjectiveCentreShare then
				return R.objective
			end
		end
	end
	for _, tagged in ipairs(CollectionService:GetTagged(DefensePlacement.NoBuildTag)) do
		local cf, size = nil, nil
		if tagged:IsA("BasePart") then
			cf, size = tagged.CFrame, tagged.Size
		elseif tagged:IsA("Model") then
			cf, size = tagged:GetBoundingBox()
		end
		if cf and DefensePlacement.BoxesOverlap(cf, size, box, ctx.size) then
			return tagged:GetAttribute("NoBuildReason") or R.nobuild
		end
	end
	local margin = 2 * DefensePlacement.SpawnMargin
	for _, part in ipairs(workspace:GetPartBoundsInBox(box, ctx.size + Vector3.new(margin, 6, margin), ctx.overlap)) do
		if part:IsA("SpawnLocation") then
			return R.spawn
		end
		local bunker = part:FindFirstAncestor("Spawn")
		if bunker and bunker.Parent and string.sub(bunker.Parent.Name, 1, 8) == "TeamBase" then
			return R.spawn
		end
	end
	return nil
end

-- What is in the structure's box once it stands at `origin`: "body" (a player, bot or vehicle, at
-- all: those refuse), "static" (a wall, a tree: slide), or "prop" and the level that clears the
-- props (sit over them). Loose, unanchored debris is shoved aside by the rising structure.
local function obstruction(ctx, c, origin, level, roll)
	local size = ctx.size
	local clear = DefensePlacement.Embed + 0.1
	local height = size.Y - clear
	local b = ctx.box
	local boxCF = origin * CFrame.new((b.x0 + b.x1) / 2, clear + height / 2, (b.z0 + b.z1) / 2)
	local boxSize = Vector3.new(b.x1 - b.x0 - 0.2, height, b.z1 - b.z0 - 0.2)
	-- Bodies count half a stud out and from the ground up: one pressed against the edge would be
	-- shoved by the rise.
	local roomCF = origin * CFrame.new(0, size.Y / 2, 0)
	local roomSize = size + Vector3.new(1, 1, 1)
	local tanR = math.tan(roll)
	local static, propLevel = false, nil
	for _, part in ipairs(workspace:GetPartBoundsInBox(roomCF, roomSize, ctx.overlap)) do
		local body = DefensePlacement.BodyOf(part)
		if body then
			if DefensePlacement.BoxesOverlap(part.CFrame, part.Size, roomCF, roomSize) then
				return "body"
			end
		elseif part.CanCollide and DefensePlacement.BoxesOverlap(part.CFrame, part.Size, boxCF, boxSize) then
			local across = (part.Position - c):Dot(ctx.right)
			local base = level + across * tanR
			local small = math.max(part.Size.X, part.Size.Y, part.Size.Z) <= DefensePlacement.PropSize
			if small and topOf(part) <= base + DefensePlacement.Embed + DefensePlacement.PropHeight then
				if part.Anchored then
					propLevel = math.max(propLevel or -math.huge, topOf(part) - across * tanR - DefensePlacement.Embed)
				end
			else
				static = true
			end
		end
	end
	if static then
		return "static"
	end
	if propLevel and propLevel > level + 1e-3 then
		return "prop", propLevel
	end
	return nil
end

-- Whether a structure standing here would shut someone in: spanning a covered passage (a doorway, a
-- corridor) with less than a body's width left on both sides, or standing closer than that in front
-- of an opening in a wall (a wall on both sides of a gap at least 3 studs wide).
local function sealsPassage(ctx, c, level)
	local gap = DefensePlacement.DoorGap
	local centre = Vector3.new(c.X, level + 2.5, c.Z)
	local roof = cast(ctx, Vector3.new(c.X, level + 0.5, c.Z), Vector3.new(0, ctx.size.Y + 6, 0), false)
	if roof then
		for _, axis in ipairs({ { ctx.right, ctx.halfX }, { ctx.look, ctx.halfZ } }) do
			local reach = axis[1] * (axis[2] + gap)
			if cast(ctx, centre, reach, false) and cast(ctx, centre, -reach, false) then
				return true
			end
		end
	end
	for _, face in ipairs({
		{ ctx.look, ctx.right, ctx.halfZ, ctx.halfX },
		{ -ctx.look, ctx.right, ctx.halfZ, ctx.halfX },
		{ ctx.right, ctx.look, ctx.halfX, ctx.halfZ },
		{ -ctx.right, ctx.look, ctx.halfX, ctx.halfZ },
	}) do
		local normal, along, depth, length = face[1], face[2], face[3], face[4]
		local seenWall, run = false, 0
		local steps = math.floor(2 * length)
		for index = 0, steps - 1 do
			local s = -length + 0.5 + index * (2 * length - 1) / math.max(steps - 1, 1)
			local from = centre + along * s + normal * (depth - 0.3)
			if cast(ctx, from, normal * (gap + 0.3), false) then
				if seenWall and run >= 3 then
					return true
				end
				seenWall, run = true, 0
			else
				run += 1
			end
		end
	end
	return false
end

-- Whether the ground from `a` to `b` can be walked without climbing a wall: a slide may go round a
-- corner of the footprint's own site, never up the side of a building onto its roof.
local function pathClear(ctx, a, b, top, bottom)
	local flatA, flatB = Vector3.new(a.X, 0, a.Z), Vector3.new(b.X, 0, b.Z)
	local steps = math.max(1, math.ceil((flatB - flatA).Magnitude))
	local climb = math.tan(DefensePlacement.MaxClimb)
	local stride = (flatB - flatA).Magnitude / steps
	local previous, last = nil, nil
	for index = 0, steps do
		local p = flatA:Lerp(flatB, index / steps)
		local col = column(ctx, p.X, p.Z, top, bottom)
		if col.top and previous and col.top - previous > stride * climb + 0.5 then
			return false
		end
		-- And across, at the height a walker on the steepest slope allowed would be: a wall this
		-- stride crosses is hit, whether or not the column rays (which start inside it) saw it.
		if previous and last then
			local height = previous + stride * climb + 0.5
			if cast(ctx, Vector3.new(last.X, height, last.Z), Vector3.new(p.X - last.X, 0, p.Z - last.Z), false) then
				return false
			end
		end
		previous = col.top or previous
		last = p
	end
	return true
end

-- The level-and-footing plan for a structure centred on `c`, or nil, why not and what kind of
-- refusal it is: "zone", "body" and "ground" are final, "blocked" (a wall in the way) tries the
-- nearest free spot instead.
local function settle(ctx, c)
	local R = DefensePlacement.Refusals
	local up = cast(ctx, c, Vector3.new(0, ctx.probeUp, 0), false)
	local top = up and (up.Position.Y - 0.05) or (c.Y + ctx.probeUp)
	local bottom = c.Y - DefensePlacement.MaxStilt - 2
	local middle = column(ctx, c.X, c.Z, top, bottom)
	if middle.lobby then
		return nil, R.lobby, "zone"
	end
	local cols = sample(ctx, c, 0, top, bottom)
	local ref = middle.top
	for _, col in ipairs(cols) do
		if col.lobby then
			return nil, R.lobby, "zone"
		end
		if not middle.top and col.top then
			ref = math.max(ref or -math.huge, col.top)
		end
	end
	if not ref then
		return nil, R.ground, "ground"
	end
	-- Protected places refuse before anything else: sliding out of a spawn is not the answer.
	local zone = zoneRefusal(ctx, CFrame.new(c.X, ref, c.Z) * ctx.facing)
	if zone then
		return nil, zone, "zone"
	end

	-- A wall in the way first, so a wall's top is never taken for ground to tilt a barricade along.
	if walled(ctx, cols, ref, 0) then
		return nil, R.room, "blocked"
	end
	local roll = 0
	if ctx.profile.wall then
		roll = fitRoll(cols, ref)
		if math.abs(roll) > 1e-3 then
			cols = sample(ctx, c, roll, top, bottom)
			if walled(ctx, cols, ref, roll) then
				return nil, R.room, "blocked"
			end
		end
	end
	local lift = math.sin(roll)
	local level = -math.huge
	for _, col in ipairs(cols) do
		if col.top then
			level = math.max(level, col.top - col.lx * lift)
		end
	end
	if level == -math.huge then
		level = ref
	end
	level -= DefensePlacement.Embed

	local origin = nil
	for _ = 1, 4 do
		local candidate = CFrame.new(c.X, level, c.Z) * ctx.facing * CFrame.Angles(0, 0, roll)
		local kind, raised = obstruction(ctx, c, candidate, level, roll)
		if kind == "body" then
			return nil, R.body, "body"
		elseif kind == "static" then
			return nil, R.room, "blocked"
		elseif kind == "prop" then
			level = raised
		else
			origin = candidate
			break
		end
	end
	if not origin then
		return nil, R.room, "blocked"
	end
	-- A terrain overhang above is not a part, so the box check can't see it.
	if up and up.Instance == workspace.Terrain and level + ctx.size.Y > up.Position.Y then
		return nil, R.room, "blocked"
	end

	local count, minX, maxX, minZ, maxZ = 0, math.huge, -math.huge, math.huge, -math.huge
	for _, col in ipairs(cols) do
		if col.floor and level + col.lx * lift - col.floor <= DefensePlacement.MaxStilt then
			count += 1
			minX, maxX = math.min(minX, col.lx), math.max(maxX, col.lx)
			minZ, maxZ = math.min(minZ, col.lz), math.max(maxZ, col.lz)
		end
	end
	if count < #cols * DefensePlacement.SupportShare or minX > 0 or maxX < 0 or minZ > 0 or maxZ < 0 then
		return nil, R.ground, "ground"
	end

	if sealsPassage(ctx, c, level) then
		return nil, R.door, "blocked"
	end

	local door = nil
	if ctx.profile.door then
		local offset = ctx.facing:VectorToWorldSpace(ctx.profile.door)
		door = column(ctx, c.X + offset.X, c.Z + offset.Z, top, bottom)
	end
	local plan = { origin = origin, level = level, roll = roll, centre = c, columns = cols, door = door,
		size = ctx.size, profile = ctx.profile, id = ctx.id, facing = ctx.facing, top = top, bottom = bottom, nx = ctx.nx, nz = ctx.nz }
	plan.footings = DefensePlacement.Footings(plan)
	return plan
end

local slideOffsets = nil
local function slides()
	if slideOffsets then
		return slideOffsets
	end
	slideOffsets = {}
	local radius = DefensePlacement.SlideStep
	while radius <= DefensePlacement.SlideMax + 1e-6 do
		for index = 0, 7 do
			local angle = index * math.pi / 4
			table.insert(slideOffsets, Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
		end
		radius += DefensePlacement.SlideStep
	end
	return slideOffsets
end

-- The posts, sill, floats and ladder a plan stands on, as { kind, size, cframe, color, material,
-- shape, class } in world space. One list, read by DefenseService to build them and by the preview to
-- draw them, so the ghost's footings are the built ones to the stud.
function DefensePlacement.Footings(plan)
	local list = {}
	local profile = plan.profile or {}
	local look = profile.metal and DefensePlacement.FootingLook.steel or DefensePlacement.FootingLook.timber
	local lift = math.sin(plan.roll)
	local posts = 0
	for _, col in ipairs(plan.columns) do
		if col.edge and col.floor then
			local base = plan.level + col.lx * lift
			local gap = base - col.floor
			if gap > DefensePlacement.PostMin and gap <= DefensePlacement.MaxStilt then
				-- Up into the pad (or the sill under a wall's sandbags), never ending in its plane.
				local topY = profile.wall and (base - 0.1) or (base + 0.2)
				local bottomY = col.floor - DefensePlacement.FootEmbed
				table.insert(list, { kind = "post", size = Vector3.new(DefensePlacement.PostWidth, topY - bottomY, DefensePlacement.PostWidth),
					cframe = CFrame.new(col.x, (topY + bottomY) / 2, col.z) * plan.facing, color = look.color, material = look.material })
				posts += 1
			end
		end
		if col.edge and col.surface then
			-- A Cylinder's length is its X axis: the float lies along the structure's width.
			table.insert(list, { kind = "float", shape = Enum.PartType.Cylinder, size = Vector3.new(2.4, 1.4, 1.4),
				cframe = CFrame.new(col.x, col.surface, col.z) * plan.facing,
				color = DefensePlacement.FootingLook.float.color, material = DefensePlacement.FootingLook.float.material })
		end
	end
	if profile.wall and posts > 0 then
		-- A sill under the bottom row, so the bags between two posts rest on something.
		table.insert(list, { kind = "sill", size = Vector3.new(plan.size.X, 0.5, 1.2), cframe = plan.origin * CFrame.new(0, -0.15, 0),
			color = look.color, material = look.material })
	end
	local door = plan.door
	if door and door.floor and profile.deck then
		local deck = plan.level + profile.deck
		local gap = deck - door.floor
		if gap > DefensePlacement.LadderStep and gap <= DefensePlacement.MaxStilt then
			-- A TrussPart is sized in whole 2-stud cells: rounded up, the extra goes into the ground.
			local topY = deck + 0.3
			local height = math.ceil((topY - (door.floor - 0.3)) / 2) * 2
			table.insert(list, { kind = "ladder", class = "TrussPart", size = Vector3.new(2, height, 2),
				cframe = CFrame.new(door.x, topY - height / 2, door.z) * plan.facing,
				color = DefensePlacement.FootingLook.steel.color, material = Enum.Material.Metal })
		end
	end
	return list
end

-- The whole answer: a plan (see settle) for the structure where it landed or at the nearest free spot
-- within SlideMax, or nil, why not and the kind of refusal. Bots and the preview both come through
-- here (DefenseService.CheckSite, DefensePreview.Site), so all three agree.
function DefensePlacement.Plan(character, size, centre, flat, defenses, extraExclude)
	local ctx = newContext(character, size, flat, defenses, extraExclude)
	local plan, reason, kind = settle(ctx, centre)
	if plan then
		plan.slid = Vector3.zero
		return plan
	end
	if kind ~= "blocked" then
		return nil, reason, kind
	end
	-- Under the same ceiling the landing spot has: from a doorway, the path is walked under the lintel,
	-- not over the roof.
	local up = cast(ctx, centre, Vector3.new(0, ctx.probeUp, 0), false)
	local top = up and (up.Position.Y - 0.05) or (centre.Y + ctx.probeUp)
	local bottom = centre.Y - DefensePlacement.MaxStilt - 2
	for _, offset in ipairs(slides()) do
		local shift = ctx.facing:VectorToWorldSpace(offset)
		local moved = centre + shift
		if pathClear(ctx, centre, moved, top, bottom) then
			local found = settle(ctx, moved)
			if found then
				found.slid = shift
				return found
			end
		end
	end
	return nil, reason, kind
end

-- Whether a structure of `size` can stand centred on `centre` with its front toward `flat` (a unit
-- direction on the ground plane): the origin to build at (level with the ground, or tilted along a
-- wall's length) and the plan with its footings, or nil and why not.
function DefensePlacement.FindSite(character, size, centre, flat, defenses, extraExclude)
	local plan, reason = DefensePlacement.Plan(character, size, centre, flat, defenses, extraExclude)
	if not plan then
		return nil, reason
	end
	return plan.origin, nil, plan
end

return DefensePlacement
