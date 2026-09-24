-- Damage you can read (#71): cracks, chips, splits, dents and snapped twigs on whatever on the map
-- is taking a beating, drawn on every client from what DestructibleService replicates:
--
--   DamageStage   attribute on the part (or on the Model, for a pool that is a whole Model):
--                 0 whole, 1 at 75% health, 2 at 50%, 3 at 25%. It only ever goes up.
--   DamageSites   attribute on each part that was hit: up to four "face,x,y,z" points in the part's
--                 own space, face being the Enum.NormalId value. Where the hits landed.
--   Damaged       tag on every part carrying sites, so a player who joins late, or streams the part
--                 in later, finds it and draws the same cracks.
--   DamageFx      event, one per frame: that frame's hits, { part, point, face, count } each, for
--                 the burst and the sound every hit makes.
--
-- Each site grows from its own seed (its position), so a later stage extends the same cracks rather
-- than drawing new ones, and every client draws the same thing. By material family:
--
--   stone     branching cracks that lengthen and fork each stage, older ones widening; chips knocked
--             out; a spalled crater at 25%; dust trickling from it from 50%
--   brick     cracks stepping along the mortar courses; bricks working loose, one gone at 25%
--   wood      splits running along the grain; splinters sticking out; a board hanging loose at 25%
--   metal     a dent deepening ring by ring; bright scratches; scorch; an edge peeled back at 25%
--   glass     a spiderweb from each hit, its rings spreading each stage (BreakFx shatters it)
--   foliage   twigs snapped and drooping, bare patches, leaves falling (the server browns it)
--   plastic   stress-whitened cracks and chips
--   cloth     tears that lengthen and fray, a flap hanging at 25%
--
-- NEVER THE PART ITSELF. Every mark is a separate local part laid on the face (anchored, no
-- collision, no query, no shadow); nothing here writes the damaged part's Transparency,
-- LocalTransparencyModifier, Color or anything else, so it stays exactly as solid and as opaque as
-- the server left it right up to the moment it breaks (#71: never fade toward clear).
-- tools/crack_check.py holds that, with the old fade planted.
--
-- Caps (lag, #131):
--   per site      SPECS_PER_SITE pieces grown, PER_SITE_CAP of them drawn
--   per part      MAX_SITES_PER_PART sites (the server's cap too), so at most 4 x PER_SITE_CAP pieces
--   in total      MAX_BUILT parts drawn at once (the nearest), MAX_PIECES pieces, MAX_TRICKLES dust
--                 emitters, MAX_BITS flying chips/splinters/leaves, each gone after its BIT_LIFE
--   distance      drawn within BUILD_WITHIN studs, taken down past DROP_BEYOND; hit bursts and sounds
--                 only within BURST_DISTANCE, BURSTS_PER_EVENT / SOUNDS_PER_EVENT per event
--   cleanup       a part's marks go the moment it is destroyed (it broke, or the map unloaded), and
--                 the sweep drops anything no longer in the workspace

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local damageFx = Remotes.Event("DamageFx")
local camera = workspace.CurrentCamera

-- Must match DestructibleService.StageAttribute / SitesAttribute / DamagedTag.
local STAGE_ATTRIBUTE, SITES_ATTRIBUTE, DAMAGED_TAG = "DamageStage", "DamageSites", "Damaged"

local MAX_SITES_PER_PART = 4
local SPECS_PER_SITE = 80
local PER_SITE_CAP = 48
local MAX_BUILT = 60
local MAX_PIECES = 1800
local MAX_TRICKLES = 16
local MAX_BITS = 90
local BIT_LIFE = 1.4
local BUILD_WITHIN, DROP_BEYOND = 150, 190
local BURST_DISTANCE = 180
local BURSTS_PER_EVENT, SOUNDS_PER_EVENT = 10, 3
-- One hit sound per part this often at most: a minigun on a wall is one crunch, not forty.
local SOUND_GAP = 0.12
local SWEEP_EVERY = 0.25

-- How far a mark sits off the face (clear of it, so the two never flicker) and how thick a crack is.
local LIFT, LINE_DEPTH = 0.012, 0.03
-- Cracks stop this far short of a face's edge rather than hang off it.
local EDGE = 0.04
-- One course of brick as the mortar cracks follow it.
local BRICK_W, BRICK_H = 2, 0.8

local BLACK, WHITE = Color3.new(0, 0, 0), Color3.new(1, 1, 1)
local SMOOTH = Enum.Material.SmoothPlastic
local LIGHT = PhysicalProperties.new(0.08, 0.5, 0.2)
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/fire_sparks_main.dds"

-- DestructibleService's CLASS_OF with brick told apart from the other stone (it cracks along its
-- courses). tools/crack_check.py holds the two tables to agreeing.
local M = Enum.Material
local FAMILY = {
	[M.Wood] = "wood", [M.WoodPlanks] = "wood",
	[M.Brick] = "brick",
	[M.Concrete] = "stone", [M.Slate] = "stone", [M.Rock] = "stone", [M.Cobblestone] = "stone",
	[M.Granite] = "stone", [M.Marble] = "stone", [M.Pebble] = "stone", [M.Basalt] = "stone",
	[M.Limestone] = "stone", [M.Sandstone] = "stone", [M.Pavement] = "stone", [M.Asphalt] = "stone",
	[M.CrackedLava] = "stone",
	[M.Metal] = "metal", [M.DiamondPlate] = "metal", [M.CorrodedMetal] = "metal", [M.Foil] = "metal",
	[M.Grass] = "foliage", [M.LeafyGrass] = "foliage", [M.Ground] = "foliage",
	[M.Fabric] = "cloth",
	[M.Glass] = "glass", [M.Ice] = "glass", [M.Neon] = "glass",
}

local function familyOf(part)
	return FAMILY[part.Material] or "plastic"
end

-- Each face's own axes in the part's space: u and v along it (v up the face on a side face), n out
-- of it, with u x v = n. Keyed by the Enum.NormalId value the server sends.
local FACES = {
	[0] = { n = Vector3.new(1, 0, 0), u = Vector3.new(0, 0, -1), v = Vector3.new(0, 1, 0) },
	[1] = { n = Vector3.new(0, 1, 0), u = Vector3.new(1, 0, 0), v = Vector3.new(0, 0, -1) },
	[2] = { n = Vector3.new(0, 0, 1), u = Vector3.new(1, 0, 0), v = Vector3.new(0, 1, 0) },
	[3] = { n = Vector3.new(-1, 0, 0), u = Vector3.new(0, 0, 1), v = Vector3.new(0, 1, 0) },
	[4] = { n = Vector3.new(0, -1, 0), u = Vector3.new(1, 0, 0), v = Vector3.new(0, 0, 1) },
	[5] = { n = Vector3.new(0, 0, -1), u = Vector3.new(-1, 0, 0), v = Vector3.new(0, 1, 0) },
}

local function extent(axis, size)
	return (math.abs(axis.X) * size.X + math.abs(axis.Y) * size.Y + math.abs(axis.Z) * size.Z) / 2
end

local function now()
	-- Wall clock, not os.clock (process CPU time in Roblox).
	return time()
end

local fxFolder = Instance.new("Folder")
fxFolder.Name = "CrackFx"
fxFolder.Parent = workspace

--------------------------------------------------------------------------------
-- What a site looks like: a list of pieces ("specs") in the face's own frame (x along u, y along
-- v, z out of the face), each tagged with the stage it appears at. Grown whole from the site's
-- seed; a stage shows the pieces tagged at or below it, in order, up to PER_SITE_CAP.
--------------------------------------------------------------------------------

-- The part of the segment a-b inside the face (less EDGE), or nil if none of it is; the fifth value
-- says whether its far end survived (false: it ran off the face).
local function clip(u1, v1, u2, v2, hu, hv)
	local du, dv = u2 - u1, v2 - v1
	local t0, t1 = 0, 1
	for _, check in ipairs({ { -du, u1 + hu }, { du, hu - u1 }, { -dv, v1 + hv }, { dv, hv - v1 } }) do
		local p, q = check[1], check[2]
		if p == 0 then
			if q < 0 then
				return nil
			end
		else
			local t = q / p
			if p < 0 then
				if t > t1 then
					return nil
				elseif t > t0 then
					t0 = t
				end
			else
				if t < t0 then
					return nil
				elseif t < t1 then
					t1 = t
				end
			end
		end
	end
	return u1 + du * t0, v1 + dv * t0, u1 + du * t1, v1 + dv * t1, t1 >= 1
end

local function full(specs)
	return #specs >= SPECS_PER_SITE
end

-- A crack line from (u1, v1) to (u2, v2). `grow`: it widens as later stages open it further.
-- Returns false once the line has run off the face.
local function addLine(specs, stage, g, u1, v1, u2, v2, width, color, transparency)
	if full(specs) then
		return false
	end
	local a, b, c, d, whole = clip(u1, v1, u2, v2, g.hu - EDGE, g.hv - EDGE)
	if not a then
		return false
	end
	local du, dv = c - a, d - b
	local length = math.sqrt(du * du + dv * dv)
	if length < 0.02 then
		return false
	end
	table.insert(specs, {
		kind = "CrackLine",
		stage = stage,
		grow = true,
		size = Vector3.new(length + width * 0.5, width, LINE_DEPTH),
		frame = CFrame.new((a + c) / 2, (b + d) / 2, LIFT + LINE_DEPTH / 2) * CFrame.Angles(0, 0, math.atan2(dv, du)),
		color = color,
		transparency = transparency,
	})
	return whole
end

-- A flat piece on the face: `size` along u, along v and out of it; turned `angle` about the normal;
-- its underside `lift` off the face. Skipped if its middle would be off the face.
local function addBox(specs, stage, g, u, v, size, angle, lift, color, material, transparency)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return nil
	end
	local spec = {
		kind = "CrackChip",
		stage = stage,
		size = size,
		frame = CFrame.new(u, v, lift + size.Z / 2) * CFrame.Angles(0, 0, angle),
		color = color,
		material = material,
		transparency = transparency,
	}
	table.insert(specs, spec)
	return spec
end

-- A round mark (a dent ring, a scorch, a glass impact): a disc `diameter` across.
local function addDisc(specs, stage, g, u, v, diameter, lift, color, material, transparency)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return nil
	end
	local thickness = 0.02
	-- A cylinder's length is its X axis, so X goes along the normal.
	table.insert(specs, {
		kind = "CrackDent",
		stage = stage,
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(thickness, diameter, diameter),
		frame = CFrame.fromMatrix(Vector3.new(u, v, lift + thickness / 2), Vector3.new(0, 0, 1), Vector3.new(0, 1, 0)),
		color = color,
		material = material,
		transparency = transparency,
	})
end

-- Something sticking out of the face from (u, v) along `direction` (a unit vector in the face's
-- frame, pointing out of it): a splinter, a snapped twig.
local function addStick(specs, stage, g, u, v, direction, length, thickness, color, material)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return
	end
	local across = Vector3.new(-direction.Y, direction.X, 0)
	across = across.Magnitude > 1e-3 and across.Unit or Vector3.new(1, 0, 0)
	local centre = Vector3.new(u, v, 0) + direction * (length / 2)
	table.insert(specs, {
		kind = "CrackStick",
		stage = stage,
		size = Vector3.new(thickness, thickness, length),
		frame = CFrame.fromMatrix(centre, across, direction:Cross(across), direction),
		color = color,
		material = material,
	})
end

-- A plate hinged at (u, v), lying along the in-plane direction (du, dv) and lifted off the face by
-- `angle`: a loose board, a peeled edge, a torn flap.
local function addHinged(specs, stage, g, u, v, du, dv, length, width, thickness, angle, color, material)
	if full(specs) or math.abs(u) > g.hu or math.abs(v) > g.hv then
		return
	end
	local along = Vector3.new(du, dv, 0).Unit
	local out = Vector3.new(0, 0, 1)
	local x = along * math.cos(angle) + out * math.sin(angle)
	local z = out * math.cos(angle) - along * math.sin(angle)
	local centre = Vector3.new(u, v, thickness / 2 + LIFT) + x * (length / 2)
	table.insert(specs, {
		kind = "CrackPlate",
		stage = stage,
		size = Vector3.new(length, width, thickness),
		frame = CFrame.fromMatrix(centre, x, z:Cross(x), z),
		color = color,
		material = material,
	})
end

-- The first stage whose reach covers `distance`, or nil past the last.
local function stageAt(reach, distance)
	for stage = 0, 3 do
		if distance <= reach[stage] then
			return stage
		end
	end
	return nil
end

local function reachOf(base, scale)
	return { [0] = base[1] * scale, base[2] * scale, base[3] * scale, base[4] * scale }
end

-- Branching cracks: `rays` of them out from the site, each a jagged run of short segments that may
-- fork, the forks shorter and finer. A segment's stage is how far out it ends, so each stage
-- carries the same cracks further.
local function crackTree(rng, specs, s, g, reach, opts)
	local branches = {}
	local start = rng:NextNumber(0, math.pi * 2)
	for ray = 1, opts.rays do
		table.insert(branches, {
			u = s.u, v = s.v, depth = 0, travelled = 0,
			angle = start + ray / opts.rays * math.pi * 2 + rng:NextNumber(-0.4, 0.4),
			limit = reach[3] * rng:NextNumber(0.75, 1),
		})
	end
	local index = 1
	while index <= #branches and not full(specs) do
		local branch = branches[index]
		index += 1
		while branch.travelled < branch.limit do
			local step = rng:NextNumber(0.35, 0.6) * g.scale
			branch.angle += rng:NextNumber(-opts.jag, opts.jag)
			local nu = branch.u + math.cos(branch.angle) * step
			local nv = branch.v + math.sin(branch.angle) * step
			local stage = stageAt(reach, branch.travelled + step)
			if not stage then
				break
			end
			local width = opts.width * (1 - 0.45 * branch.travelled / reach[3]) * (branch.depth > 0 and 0.7 or 1)
			if not addLine(specs, stage, g, branch.u, branch.v, nu, nv, width, opts.color, opts.transparency) then
				break
			end
			if branch.depth < 2 and rng:NextNumber() < opts.fork then
				local turn = (rng:NextNumber() < 0.5 and -1 or 1) * rng:NextNumber(0.5, 1.1)
				table.insert(branches, {
					u = nu, v = nv, depth = branch.depth + 1, travelled = branch.travelled + step,
					angle = branch.angle + turn,
					limit = branch.travelled + step + (branch.limit - branch.travelled - step) * 0.6,
				})
			end
			branch.u, branch.v = nu, nv
			branch.travelled += step
		end
	end
end

-- A chip knocked out: the fresh broken stone inside, in a darker rim.
local function addChip(specs, stage, g, rng, u, v, across, color)
	local angle = rng:NextNumber(0, math.pi)
	local a, b = across * rng:NextNumber(0.8, 1.2), across * rng:NextNumber(0.6, 1)
	addBox(specs, stage, g, u, v, Vector3.new(a + 0.08, b + 0.08, 0.02), angle, LIFT, color:Lerp(BLACK, 0.55), SMOOTH)
	addBox(specs, stage, g, u, v, Vector3.new(a, b, 0.03), angle, LIFT + 0.004, color:Lerp(WHITE, 0.18), SMOOTH)
end

local function near(rng, s, radius)
	local angle, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.3, 1) * radius
	return s.u + math.cos(angle) * r, s.v + math.sin(angle) * r
end

local function stoneSite(rng, specs, s, g, color)
	local reach = reachOf({ 0.3, 0.9, 1.8, 3.0 }, g.scale)
	-- The chips and the crater come first, so the per-site cap only ever trims crack ends.
	addChip(specs, 0, g, rng, s.u, s.v, 0.22, color)
	for _ = 1, 2 do
		local u, v = near(rng, s, 0.9 * g.scale)
		addChip(specs, 2, g, rng, u, v, 0.3, color)
	end
	-- 25%: a spalled crater where the hits went in, with lumps of it still clinging on.
	local crater = math.min(1.5 * math.sqrt(g.scale), g.hu, g.hv)
	addBox(specs, 3, g, s.u, s.v, Vector3.new(crater, crater * 0.8, 0.02), rng:NextNumber(0, math.pi), LIFT - 0.004, color:Lerp(BLACK, 0.6), SMOOTH)
	addBox(specs, 3, g, s.u, s.v, Vector3.new(crater * 0.8, crater * 0.6, 0.03), rng:NextNumber(0, math.pi), LIFT, color:Lerp(WHITE, 0.12), SMOOTH)
	for _ = 1, 3 do
		local u, v = near(rng, s, crater * 0.45)
		local lump = rng:NextNumber(0.12, 0.26)
		addBox(specs, 3, g, u, v, Vector3.new(lump, lump * 0.9, lump * 0.8), rng:NextNumber(0, math.pi), LIFT, color:Lerp(BLACK, 0.1), SMOOTH)
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 4), jag = 0.5, fork = 0.25, width = 0.07, color = color:Lerp(BLACK, 0.72) })
end

local function plasticSite(rng, specs, s, g, color)
	local reach = reachOf({ 0.25, 0.7, 1.3, 2.2 }, g.scale)
	addChip(specs, 0, g, rng, s.u, s.v, 0.16, color)
	-- Plastic whitens where it is stressed rather than going dark.
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(2, 3), jag = 0.3, fork = 0.15, width = 0.045, color = color:Lerp(WHITE, 0.5) })
	for stage = 2, 3 do
		local u, v = near(rng, s, 0.8 * g.scale)
		addChip(specs, stage, g, rng, u, v, 0.22, color)
	end
end

-- Cracks along the mortar: from the site to the nearest bed joint, then stepping course by course,
-- along a bed joint to the next head joint and down (or up) it, the way brickwork actually fails.
-- The loose bricks sit in the courses the cracks follow. (On a top or bottom face there are no
-- courses: it cracks like stone.)
local function brickSite(rng, specs, s, g, color)
	if not g.side then
		return stoneSite(rng, specs, s, g, color)
	end
	local reach = reachOf({ 0.4, 1.4, 2.8, 4.6 }, g.scale)
	local mortar = color:Lerp(BLACK, 0.7)
	addChip(specs, 0, g, rng, s.u, s.v, 0.2, color)
	for path = 1, rng:NextInteger(2, 3) do
		local dirU = rng:NextNumber() < 0.5 and -1 or 1
		local dirV = (path == 1 or rng:NextNumber() < 0.7) and -1 or 1
		local course = math.floor(s.v / BRICK_H + 0.5)
		local u, v = s.u, course * BRICK_H
		local travelled = math.abs(v - s.v)
		addLine(specs, 0, g, s.u, s.v, u, v, 0.06, mortar)
		while travelled < reach[3] and not full(specs) do
			-- The course about to be entered, and its next head joint along (every other course is
			-- laid half a brick over).
			local row = dirV < 0 and course - 1 or course
			local offset = (row % 2) * BRICK_W / 2
			local k = dirU > 0 and math.floor((u - offset) / BRICK_W) + 1 or math.ceil((u - offset) / BRICK_W) - 1
			if rng:NextNumber() < 0.3 then
				k += dirU
			end
			local head = k * BRICK_W + offset
			local run = math.abs(head - u)
			local stage = stageAt(reach, travelled + run)
			if not stage or not addLine(specs, stage, g, u, v, head, v, 0.06, mortar) then
				break
			end
			travelled += run
			stage = stageAt(reach, travelled + BRICK_H)
			if not stage or not addLine(specs, stage, g, head, v, head, v + dirV * BRICK_H, 0.06, mortar) then
				break
			end
			travelled += BRICK_H
			u, v, course = head, v + dirV * BRICK_H, course + dirV
		end
	end
	-- Loose bricks: the one the hits went into first, then its neighbours; at 25% one is gone.
	local row = math.floor(s.v / BRICK_H)
	local offset = (row % 2) * BRICK_W / 2
	local cell = math.floor((s.u - offset) / BRICK_W)
	local function brickAt(k, r)
		local shift = (r % 2) * BRICK_W / 2
		return k * BRICK_W + shift + BRICK_W / 2, r * BRICK_H + BRICK_H / 2
	end
	local function loose(stage, k, r)
		local u, v = brickAt(k, r)
		if math.abs(u) + BRICK_W / 2 > g.hu or math.abs(v) + BRICK_H / 2 > g.hv then
			return
		end
		-- Partly still in the wall, the rest standing proud of it.
		local spec = addBox(specs, stage, g, u, v, Vector3.new(BRICK_W * 0.94, BRICK_H * 0.86, 0.3), 0, -rng:NextNumber(0.04, 0.12),
			color:Lerp(rng:NextNumber() < 0.5 and BLACK or WHITE, rng:NextNumber(0.04, 0.12)), SMOOTH)
		if spec then
			spec.kind = "CrackBrick"
			spec.frame = spec.frame * CFrame.Angles(rng:NextNumber(-0.07, 0.07), rng:NextNumber(-0.07, 0.07), rng:NextNumber(-0.04, 0.04))
		end
	end
	loose(2, cell, row)
	loose(3, cell + (rng:NextNumber() < 0.5 and -1 or 1), row)
	local gu, gv = brickAt(cell, row + (rng:NextNumber() < 0.5 and -1 or 1))
	if math.abs(gu) + BRICK_W / 2 <= g.hu and math.abs(gv) + BRICK_H / 2 <= g.hv then
		local gap = addBox(specs, 3, g, gu, gv, Vector3.new(BRICK_W * 0.92, BRICK_H * 0.84, 0.02), 0, LIFT, color:Lerp(BLACK, 0.85), SMOOTH)
		if gap then
			-- Where this brick was: it drops out when the wall reaches the stage (build()).
			gap.falls = { size = Vector3.new(BRICK_W * 0.9, BRICK_H * 0.8, 0.4), color = color }
		end
	end
end

-- Splits along the grain (the face's long way, as boards and beams run), opening further each stage
-- and a second and third beside the first; splinters of fresh wood sticking out; at 25% a board
-- working loose, hanging off the face from one end.
local function woodSite(rng, specs, s, g, color, material)
	local alongU = g.hu >= g.hv
	local reach = reachOf({ 0.4, 1.0, 2.0, 3.4 }, g.scale)
	local split = color:Lerp(BLACK, 0.75)
	local fresh = color:Lerp(Color3.fromRGB(226, 196, 150), 0.55)
	-- Splinters, leaning along the grain, fresh-coloured (drawn ahead of the splits of their stage,
	-- so the per-site cap never leaves a stage without them).
	local counts = { [0] = 1, 1, 2, 2 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, 0.35 * g.scale)
			local azimuth = (alongU and 0 or math.pi / 2) + (rng:NextNumber() < 0.5 and 0 or math.pi) + rng:NextNumber(-0.5, 0.5)
			local tilt = rng:NextNumber(0.6, 1.15)
			local direction = Vector3.new(math.cos(azimuth) * math.sin(tilt), math.sin(azimuth) * math.sin(tilt), math.cos(tilt))
			addStick(specs, stage, g, u, v, direction, rng:NextNumber(0.35, 0.8) * math.sqrt(g.scale), rng:NextNumber(0.05, 0.09), fresh, material)
		end
	end
	-- The loose board: hinged at one end (the upper, on upright grain), the free end off the face.
	local grainHalf = alongU and g.hu or g.hv
	local length = math.min(2.4 * g.scale, grainHalf * 1.6)
	if length > 0.6 then
		local du, dv = alongU and (rng:NextNumber() < 0.5 and 1 or -1) or 0, alongU and 0 or -1
		local hu, hv = s.u - du * length * 0.4, s.v - dv * length * 0.4
		addHinged(specs, 3, g, math.clamp(hu, -g.hu, g.hu), math.clamp(hv, -g.hv, g.hv), du, dv, length, 0.55, 0.14,
			rng:NextNumber(0.14, 0.26), color:Lerp(BLACK, 0.1), material)
	end
	-- The splits: the first through the hit, then one either side, each opening a stage later and
	-- running shorter.
	local splits = { { 0, 0, 1 }, { 0.22, 1, 0.75 }, { -0.3, 2, 0.6 }, { 0.5, 3, 0.45 } }
	for _, entry in ipairs(splits) do
		local across, first, share = entry[1] * g.scale, entry[2], entry[3]
		for _, sign in ipairs({ 1, -1 }) do
			local travelled, wobble = 0, 0
			local pu, pv = s.u + (alongU and 0 or across), s.v + (alongU and across or 0)
			while not full(specs) and travelled < reach[3] * share do
				local step = rng:NextNumber(0.4, 0.6) * g.scale
				local stage = stageAt(reach, travelled + step)
				if not stage then
					break
				end
				stage = math.max(stage, first)
				wobble = math.clamp(wobble + rng:NextNumber(-0.03, 0.03), -0.08, 0.08)
				local nu = pu + (alongU and sign * step or 0) + (alongU and 0 or wobble * 0.3)
				local nv = pv + (alongU and 0 or sign * step) + (alongU and wobble * 0.3 or 0)
				local width = 0.07 * (1 - 0.5 * travelled / reach[3])
				if not addLine(specs, stage, g, pu, pv, nu, nv, width, split) then
					break
				end
				pu, pv, travelled = nu, nv, travelled + step
			end
		end
	end
end

-- A dent deepening ring by ring (each stage a wider ring under the last, shaded like a hollow);
-- bright scratches where the metal was scored; soot; at 25% the nearest edge peeled back.
local function metalSite(rng, specs, s, g, color, material)
	local root = math.sqrt(g.scale)
	local rings = { [0] = { 0.45, color:Lerp(WHITE, 0.15) }, { 0.8, color:Lerp(BLACK, 0.32) }, { 1.1, color:Lerp(BLACK, 0.2) }, { 1.4, color:Lerp(BLACK, 0.12) } }
	for stage = 0, 3 do
		addDisc(specs, stage, g, s.u, s.v, rings[stage][1] * root, LIFT + (3 - stage) * 0.008, rings[stage][2], material)
	end
	local scratch = color:Lerp(WHITE, 0.55)
	local counts = { [0] = 1, 2, 2, 2 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, 1.2 * g.scale)
			local angle, length = rng:NextNumber(0, math.pi), rng:NextNumber(0.4, 1.3)
			addLine(specs, stage, g, u - math.cos(angle) * length / 2, v - math.sin(angle) * length / 2,
				u + math.cos(angle) * length / 2, v + math.sin(angle) * length / 2, 0.025, scratch)
		end
	end
	for _ = 1, 2 do
		local u, v = near(rng, s, 1.1 * g.scale)
		local across = rng:NextNumber(0.3, 0.5)
		addDisc(specs, 2, g, u, v, across, LIFT + 0.012, color:Lerp(BLACK, 0.3), material)
		addDisc(specs, 2, g, u, v, across * 0.5, LIFT + 0.02, color:Lerp(WHITE, 0.1), material)
	end
	addDisc(specs, 2, g, s.u, s.v, rng:NextNumber(1.4, 2.2) * root, LIFT - 0.008, Color3.fromRGB(26, 24, 22), SMOOTH, 0.3)
	-- The peeled edge: whichever edge of the face the hits landed nearest.
	local toU, toV = g.hu - math.abs(s.u), g.hv - math.abs(s.v)
	local du, dv, eu, ev
	if toU <= toV then
		du, dv = s.u >= 0 and 1 or -1, 0
		eu, ev = du * g.hu, math.clamp(s.v, -g.hv + 0.6, g.hv - 0.6)
	else
		du, dv = 0, s.v >= 0 and 1 or -1
		eu, ev = math.clamp(s.u, -g.hu + 0.6, g.hu - 0.6), dv * g.hv
	end
	local depth = math.min(0.7, (toU <= toV and g.hu or g.hv))
	addHinged(specs, 3, g, eu - du * depth, ev - dv * depth, du, dv, depth + 0.05, math.min(1.2, (toU <= toV and g.hv or g.hu) * 2),
		0.07, 0.45, color:Lerp(BLACK, 0.12), material)
end

-- A spiderweb: straight rays out from the hit, and rings joining them that spread a stage at a time.
local function glassSite(rng, specs, s, g)
	local white = Color3.fromRGB(236, 244, 255)
	local reach = reachOf({ 0.25, 0.7, 1.4, 2.4 }, g.scale)
	addDisc(specs, 0, g, s.u, s.v, 0.14, LIFT, white, SMOOTH, 0.05)
	local count = rng:NextInteger(7, 9)
	local angles = {}
	for ray = 1, count do
		angles[ray] = ray / count * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
	end
	for _, angle in ipairs(angles) do
		local travelled, pu, pv = 0, s.u, s.v
		while travelled < reach[3] do
			local step = rng:NextNumber(0.25, 0.4) * g.scale
			local stage = stageAt(reach, travelled + step)
			if not stage then
				break
			end
			local heading = angle + rng:NextNumber(-0.08, 0.08)
			local nu, nv = pu + math.cos(heading) * step, pv + math.sin(heading) * step
			if not addLine(specs, stage, g, pu, pv, nu, nv, 0.03, white, 0.1) then
				break
			end
			pu, pv, travelled = nu, nv, travelled + step
		end
	end
	for stage, radius in ipairs({ 0.32, 0.75, 1.45 }) do
		for ray = 1, count do
			local a, b = angles[ray], angles[ray % count + 1]
			local r1, r2 = radius * g.scale * rng:NextNumber(0.9, 1.1), radius * g.scale * rng:NextNumber(0.9, 1.1)
			-- Each chord sags a little toward the hit, the way the rings of a web do.
			local middle = (a + (b < a and b + math.pi * 2 or b)) / 2
			local rm = (r1 + r2) / 2 * 0.92
			local u1, v1 = s.u + math.cos(a) * r1, s.v + math.sin(a) * r1
			local um, vm = s.u + math.cos(middle) * rm, s.v + math.sin(middle) * rm
			local u2, v2 = s.u + math.cos(b) * r2, s.v + math.sin(b) * r2
			addLine(specs, stage, g, u1, v1, um, vm, 0.022, white, 0.1)
			addLine(specs, stage, g, um, vm, u2, v2, 0.022, white, 0.1)
		end
	end
end

-- Twigs snapped and drooping out of the canopy, and bare patches where the leaves were stripped.
-- (The leaves falling are thrown by the sweep; the browning is the server's stage tint.)
local function foliageSite(rng, specs, s, g, color)
	local bark = Color3.fromRGB(92, 66, 42)
	local counts = { [0] = 1, 1, 2, 2 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, 0.8 * g.scale)
			local direction
			if g.side then
				direction = Vector3.new(rng:NextNumber(-0.4, 0.4), -rng:NextNumber(0.5, 1), rng:NextNumber(0.4, 0.8)).Unit
			else
				local azimuth = rng:NextNumber(0, math.pi * 2)
				direction = Vector3.new(math.cos(azimuth), math.sin(azimuth), 0.35).Unit
			end
			addStick(specs, stage, g, u, v, direction, rng:NextNumber(0.5, 1.2) * math.sqrt(g.scale), 0.1, bark, Enum.Material.Wood)
		end
	end
	local bare = { [2] = 2, [3] = 2 }
	for stage = 2, 3 do
		for _ = 1, bare[stage] do
			local u, v = near(rng, s, 1.2 * g.scale)
			addBox(specs, stage, g, u, v, Vector3.new(rng:NextNumber(0.8, 1.5), rng:NextNumber(0.6, 1.2), 0.03) * g.scale,
				rng:NextNumber(0, math.pi), LIFT, color:Lerp(BLACK, 0.55), SMOOTH)
		end
	end
end

-- A tear through the cloth, lengthening each stage, frayed threads along it; at 25% a flap of it
-- hanging open.
local function clothSite(rng, specs, s, g, color, material)
	local reach = reachOf({ 0.3, 0.8, 1.5, 2.4 }, g.scale)
	local angle = g.side and math.pi / 2 + rng:NextNumber(-0.4, 0.4) or rng:NextNumber(0, math.pi)
	local dark, thread = color:Lerp(BLACK, 0.85), color:Lerp(WHITE, 0.3)
	for _, sign in ipairs({ 1, -1 }) do
		local travelled, pu, pv = 0, s.u, s.v
		while true do
			local step = rng:NextNumber(0.2, 0.32) * g.scale
			local stage = stageAt(reach, travelled + step)
			if not stage then
				break
			end
			local heading = angle + rng:NextNumber(-0.2, 0.2)
			local nu, nv = pu + sign * math.cos(heading) * step, pv + sign * math.sin(heading) * step
			if not addLine(specs, stage, g, pu, pv, nu, nv, 0.09 * (1 - 0.4 * travelled / reach[3]), dark) then
				break
			end
			local fray = heading + math.pi / 2
			addLine(specs, stage, g, nu - math.cos(fray) * 0.1, nv - math.sin(fray) * 0.1, nu + math.cos(fray) * 0.1,
				nv + math.sin(fray) * 0.1, 0.02, thread)
			pu, pv, travelled = nu, nv, travelled + step
		end
	end
	addHinged(specs, 3, g, s.u, s.v, -math.cos(angle), -math.abs(math.sin(angle)), 0.8 * g.scale, 0.6 * g.scale, 0.04, 0.35, color, material)
end

local GENERATORS = {
	stone = stoneSite, brick = brickSite, wood = woodSite, metal = metalSite, glass = glassSite,
	foliage = foliageSite, plastic = plasticSite, cloth = clothSite,
}

-- Each client draws a site from the same numbers the server wrote, so they all draw the same thing.
local function seedOf(site, index)
	local p = site.point
	local seed = site.face * 7919 + math.floor(p.X * 10 + 0.5) * 104729 + math.floor(p.Y * 10 + 0.5) * 1299709
		+ math.floor(p.Z * 10 + 0.5) * 15485863 + index * 31
	return seed % 2147483646 + 1
end

-- The face a site is on, measured: its axes, half-extents, depth from the part's centre, a scale
-- for how big its marks run, and whether it stands upright.
local function faceOf(size, face)
	local axes = FACES[face]
	local hu, hv = extent(axes.u, size), extent(axes.v, size)
	return {
		face = axes, hu = hu, hv = hv, depth = extent(axes.n, size),
		scale = math.clamp(math.min(hu, hv) / 2, 0.5, 1.6),
		side = face ~= 1 and face ~= 4,
	}
end

-- Every piece a site will ever show, full-grown, in the order they appear.
local function siteSpecs(family, size, site, index, color, material)
	local g = faceOf(size, site.face)
	local s = { u = site.point:Dot(g.face.u), v = site.point:Dot(g.face.v) }
	local specs = {}
	GENERATORS[family](Random.new(seedOf(site, index)), specs, s, g, color, material)
	for order, spec in ipairs(specs) do
		spec.order = order
	end
	table.sort(specs, function(a, b)
		if a.stage ~= b.stage then
			return a.stage < b.stage
		end
		return a.order < b.order
	end)
	return specs, g
end

-- "face,x,y,z;..." as the server writes it, at most MAX_SITES_PER_PART of them.
local function parseSites(text)
	local sites = {}
	if type(text) ~= "string" then
		return sites
	end
	for faceText, xText, yText, zText in string.gmatch(text, "(%d),(%-?[%d.]+),(%-?[%d.]+),(%-?[%d.]+)") do
		if #sites >= MAX_SITES_PER_PART then
			break
		end
		local face, x, y, z = tonumber(faceText), tonumber(xText), tonumber(yText), tonumber(zText)
		if FACES[face] and x and y and z then
			table.insert(sites, { face = face, point = Vector3.new(x, y, z) })
		end
	end
	return sites
end

-- The stage of the pool a part is in: on the part, or on the Model above it that is the pool.
local function stageOf(part)
	local node = part
	while node and node ~= workspace do
		local stage = node:GetAttribute(STAGE_ATTRIBUTE)
		if type(stage) == "number" then
			return math.clamp(math.floor(stage), 0, 3)
		end
		node = node.Parent
	end
	return 0
end

--------------------------------------------------------------------------------
-- Flying bits: the chips, splinters, sparks-without-sparks and leaves a hit knocks off, and a brick
-- dropping out. Local physics, feather-light, gone after BIT_LIFE (a brick after 3 s).
--------------------------------------------------------------------------------

local bits = {}
local rng = Random.new()

local BIT_SIZES = {
	chip = function()
		local edge = rng:NextNumber(0.1, 0.26)
		return Vector3.new(edge, edge * rng:NextNumber(0.6, 1), edge * rng:NextNumber(0.6, 1))
	end,
	splinter = function() return Vector3.new(0.05, 0.05, rng:NextNumber(0.3, 0.6)) end,
	leaf = function() return Vector3.new(rng:NextNumber(0.25, 0.4), 0.03, rng:NextNumber(0.2, 0.32)) end,
	shard = function() return Vector3.new(0.03, rng:NextNumber(0.1, 0.24), rng:NextNumber(0.08, 0.18)) end,
}

local function spawnBit(kind, position, velocity, color, material, size, life)
	if #bits >= MAX_BITS then
		return nil
	end
	local piece = Instance.new(kind == "shard" and "WedgePart" or "Part")
	piece.Name = "CrackBit"
	piece.Size = size or BIT_SIZES[kind]()
	piece.CFrame = CFrame.new(position) * CFrame.Angles(rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3))
	piece.Color = color
	piece.Material = material
	if kind == "shard" then
		piece.Transparency = 0.3
	end
	piece.CanCollide = true
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.CustomPhysicalProperties = LIGHT
	piece.Parent = fxFolder
	piece.AssemblyLinearVelocity = velocity
	piece.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
	table.insert(bits, { part = piece, born = now(), life = life or BIT_LIFE, drift = kind == "leaf" })
	return piece
end

-- One throwaway emitter burst: dust, sawdust, sparks or a glint.
local function puff(position, normal, color, kind)
	local holder = Instance.new("Part")
	holder.Name = "CrackPuff"
	holder.Size = Vector3.new(0.2, 0.2, 0.2)
	-- Its front face along the normal, so the burst comes off the surface.
	holder.CFrame = CFrame.lookAt(position + normal * 0.1, position + normal * 1.1)
	holder.Transparency = 1
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Parent = fxFolder
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.EmissionDirection = Enum.NormalId.Front
	if kind == "sparks" then
		emitter.Texture = SPARK_TEXTURE
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 226, 150), Color3.fromRGB(255, 130, 40))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(0.14, 0)
		emitter.Lifetime = NumberRange.new(0.15, 0.35)
		emitter.Speed = NumberRange.new(12, 24)
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, -50, 0)
	elseif kind == "glint" then
		emitter.Color = ColorSequence.new(Color3.fromRGB(235, 245, 255))
		emitter.LightEmission = 0.6
		emitter.Size = NumberSequence.new(0.18, 0)
		emitter.Lifetime = NumberRange.new(0.15, 0.3)
		emitter.Speed = NumberRange.new(4, 9)
		emitter.SpreadAngle = Vector2.new(50, 50)
	else
		emitter.Texture = DUST_TEXTURE
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1.1) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(35, 35)
		emitter.Acceleration = Vector3.new(0, -2, 0)
		emitter.Drag = 3
		emitter.Rotation = NumberRange.new(0, 360)
	end
	emitter.Parent = holder
	emitter:Emit(kind == "sparks" and 12 or 6)
	task.delay(1.2, function()
		holder:Destroy()
	end)
	return holder
end

-- What each hit knocks off, by family.
local BURSTS = {
	stone = { bit = "chip", count = 3, dust = Color3.fromRGB(180, 174, 164) },
	brick = { bit = "chip", count = 3, dust = Color3.fromRGB(172, 120, 98) },
	wood = { bit = "splinter", count = 3, dust = Color3.fromRGB(204, 176, 132) },
	metal = { sparks = true },
	glass = { bit = "shard", count = 3, glint = true },
	foliage = { bit = "leaf", count = 4 },
	plastic = { bit = "chip", count = 2 },
	cloth = { dust = Color3.fromRGB(222, 216, 206) },
}
local HIT_SOUNDS = {
	stone = { "BreakStone", "GoldCrumble" }, brick = { "BreakStone", "GoldCrumble" },
	wood = { "BreakWood", "BodyFall" }, metal = { "CasingTink", "BreakMetal" }, glass = { "CasingTink" },
	foliage = { "BreakFoliage" }, plastic = { "CasingTink" }, cloth = { "BreakFoliage" },
}

local function hitBurst(family, position, normal, color, material, count)
	local burst = BURSTS[family] or BURSTS.plastic
	if burst.sparks then
		puff(position, normal, color, "sparks")
	elseif burst.glint then
		puff(position, normal, color, "glint")
	elseif burst.dust then
		puff(position, normal, burst.dust, "dust")
	end
	for _ = 1, math.min((burst.count or 0) + count - 1, 6) do
		local spread = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.4, 1), rng:NextNumber(-1, 1))
		local speed = burst.bit == "leaf" and rng:NextNumber(1, 3) or rng:NextNumber(5, 11)
		spawnBit(burst.bit, position + normal * 0.15, (normal + spread * 0.6).Unit * speed + Vector3.new(0, 2, 0),
			burst.bit == "leaf" and color or color:Lerp(BLACK, rng:NextNumber(0, 0.2)), material)
	end
end

local lastSound = {}

local function playHit(family, part, position)
	local clock = now()
	if lastSound[part] and clock - lastSound[part] < SOUND_GAP then
		return false
	end
	for _, name in ipairs(HIT_SOUNDS[family] or {}) do
		if SoundConfig.Get(name) then
			lastSound[part] = clock
			Sfx.PlayAt(name, position, 0.25, nil, 0.4)
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- The parts being drawn
--------------------------------------------------------------------------------

-- part -> record. Strong keys: every record is removed when its part goes (Destroying, the tag
-- coming off, or the sweep finding it out of the workspace).
local tracked = {}
local totals = { pieces = 0, built = 0, trickles = 0 }

local TRICKLE = {
	stone = Color3.fromRGB(186, 180, 170),
	brick = Color3.fromRGB(176, 128, 104),
}

local function realize(part, faceFrame, spec, stage)
	local piece = Instance.new("Part")
	-- CrackLine, CrackChip, CrackDent, CrackStick, CrackPlate or CrackBrick: what it is, for Explorer.
	piece.Name = spec.kind
	if spec.shape then
		piece.Shape = spec.shape
	end
	local size = spec.size
	if spec.grow and stage > spec.stage then
		size = Vector3.new(size.X, size.Y * (1 + 0.35 * (stage - spec.stage)), size.Z)
	end
	piece.Size = size
	piece.CFrame = part.CFrame * faceFrame * spec.frame
	piece.Color = spec.color
	piece.Material = spec.material or SMOOTH
	piece.Transparency = spec.transparency or 0
	piece.Anchored = true
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.Parent = fxFolder
	return piece
end

local function unbuild(record)
	for _, piece in ipairs(record.pieces) do
		piece:Destroy()
	end
	totals.pieces -= #record.pieces
	record.pieces, record.pieceSites = {}, {}
	if record.trickle then
		record.trickle:Destroy()
		record.trickle = nil
		totals.trickles -= 1
	end
	if record.built then
		record.built = false
		totals.built -= 1
	end
end

-- Draws a part's sites at its stage (all of them again: a part is rebuilt at most once per new site
-- or stage, seven times in its life).
local function build(part, record)
	unbuild(record)
	record.built = true
	totals.built += 1
	local family = familyOf(part)
	local stage = record.stage
	local cframe = part.CFrame
	local lowest = nil
	for index, site in ipairs(record.sites) do
		local specs, g = siteSpecs(family, part.Size, site, index, part.Color, part.Material)
		local faceFrame = CFrame.fromMatrix(g.face.n * g.depth, g.face.u, g.face.v, g.face.n)
		local shown = 0
		for _, spec in ipairs(specs) do
			if spec.stage > stage or shown >= PER_SITE_CAP or totals.pieces >= MAX_PIECES then
				break
			end
			table.insert(record.pieces, realize(part, faceFrame, spec, stage))
			table.insert(record.pieceSites, index)
			shown += 1
			totals.pieces += 1
			-- A brick drops out as the wall reaches the stage that loses it.
			if spec.falls and record.rose == spec.stage and record.distance and record.distance <= BURST_DISTANCE then
				local at = cframe * (faceFrame * spec.frame).Position
				spawnBit("chip", at, cframe:VectorToWorldSpace(g.face.n) * 4 + Vector3.new(0, 2, 0), spec.falls.color, part.Material, spec.falls.size, 3)
			end
		end
		local world = cframe * site.point
		if not lowest or world.Y < lowest.world.Y then
			lowest = { world = world, normal = cframe:VectorToWorldSpace(g.face.n) }
		end
	end
	record.rose = nil
	-- Dust trickling out of broken stone and brick from half health, from the lowest site.
	if stage >= 2 and TRICKLE[family] and lowest and totals.trickles < MAX_TRICKLES then
		local holder = Instance.new("Part")
		holder.Name = "CrackDust"
		holder.Size = Vector3.new(0.4, 0.2, 0.4)
		holder.CFrame = CFrame.new(lowest.world + lowest.normal * 0.15)
		holder.Transparency = 1
		holder.Anchored = true
		holder.CanCollide = false
		holder.CanQuery = false
		holder.CanTouch = false
		holder.Parent = fxFolder
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = DUST_TEXTURE
		emitter.Color = ColorSequence.new(TRICKLE[family])
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.7) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(1.2, 2)
		emitter.Rate = stage >= 3 and 5 or 2.5
		emitter.Speed = NumberRange.new(0.4, 1.2)
		emitter.SpreadAngle = Vector2.new(15, 15)
		emitter.Acceleration = Vector3.new(0, -3, 0)
		emitter.Drag = 1
		emitter.Parent = holder
		record.trickle = holder
		totals.trickles += 1
	end
end

local function untrack(part)
	local record = tracked[part]
	if not record then
		return
	end
	tracked[part] = nil
	lastSound[part] = nil
	unbuild(record)
	if record.connection then
		record.connection:Disconnect()
	end
end

local function track(part)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return nil
	end
	local record = tracked[part]
	if record then
		return record
	end
	record = { part = part, pieces = {}, pieceSites = {}, sites = {}, stage = -1, built = false, dirty = true }
	record.connection = part.Destroying:Connect(function()
		untrack(part)
	end)
	tracked[part] = record
	return record
end

-- Re-reads what the server has written for a part; marks it for a rebuild if anything changed.
local function refresh(part, record)
	local text = part:GetAttribute(SITES_ATTRIBUTE)
	if text ~= record.text then
		record.text = text
		record.sites = parseSites(text)
		record.dirty = true
	end
	local stage = stageOf(part)
	if stage ~= record.stage then
		if record.stage >= 0 and stage > record.stage then
			record.rose = stage
		end
		record.stage = stage
		record.dirty = true
	end
end

local LEAF_CHANCE = { [2] = 0.25, [3] = 0.5 }

-- Four times a second: drop what has gone, re-read what changed, and draw the nearest damaged parts
-- within reach (the farthest giving up theirs when the caps are reached).
local function sweep()
	local eye = camera and camera.CFrame.Position
	if not eye then
		return
	end
	local candidates = {}
	for part, record in pairs(tracked) do
		if not part.Parent or not part:IsDescendantOf(workspace) then
			untrack(part)
		else
			refresh(part, record)
			record.distance = math.max(0, (part.Position - eye).Magnitude - part.Size.Magnitude / 2)
			if #record.sites == 0 or record.distance > DROP_BEYOND then
				if record.built then
					unbuild(record)
				end
			elseif record.distance <= BUILD_WITHIN or record.built then
				table.insert(candidates, record)
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)
	local farthest = #candidates
	for rank, record in ipairs(candidates) do
		if rank > MAX_BUILT then
			if record.built then
				unbuild(record)
			end
		elseif not record.built or record.dirty then
			while totals.pieces > MAX_PIECES - PER_SITE_CAP * MAX_SITES_PER_PART and farthest > rank do
				if candidates[farthest].built then
					unbuild(candidates[farthest])
				end
				farthest -= 1
			end
			build(record.part, record)
			record.dirty = false
		end
		-- Leaves keep coming down off a tree that has been shot bare.
		local chance = LEAF_CHANCE[record.stage]
		if chance and record.built and familyOf(record.part) == "foliage" and record.distance <= BURST_DISTANCE and rng:NextNumber() < chance then
			local site = record.sites[rng:NextInteger(1, #record.sites)]
			local at = record.part.CFrame * site.point
			spawnBit("leaf", at + Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)), Vector3.new(0, -1, 0), record.part.Color, Enum.Material.Grass)
		end
	end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

for _, part in ipairs(CollectionService:GetTagged(DAMAGED_TAG)) do
	track(part)
end
CollectionService:GetInstanceAddedSignal(DAMAGED_TAG):Connect(track)
CollectionService:GetInstanceRemovedSignal(DAMAGED_TAG):Connect(untrack)

damageFx.OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" or not camera then
		return
	end
	local eye = camera.CFrame.Position
	local bursts, sounds = 0, 0
	for _, hit in ipairs(batch) do
		local part, point, face, count = hit[1], hit[2], hit[3], hit[4]
		if typeof(part) == "Instance" and part:IsA("BasePart") and part.Parent and typeof(point) == "Vector3" and FACES[face] then
			local record = track(part)
			refresh(part, record)
			local world = part.CFrame * point
			local distance = (world - eye).Magnitude
			record.distance = distance
			if distance <= BURST_DISTANCE then
				local family = familyOf(part)
				if bursts < BURSTS_PER_EVENT then
					bursts += 1
					hitBurst(family, world, part.CFrame:VectorToWorldSpace(FACES[face].n), part.Color, part.Material,
						math.clamp(type(count) == "number" and count or 1, 1, 4))
				end
				if sounds < SOUNDS_PER_EVENT and playHit(family, part, world) then
					sounds += 1
				end
			end
			-- A new site or stage shows at once rather than at the next sweep.
			if record.dirty and #record.sites > 0 and (record.built or (distance <= BUILD_WITHIN and totals.built < MAX_BUILT)) then
				build(part, record)
				record.dirty = false
			end
		end
	end
end)

local sinceSweep = 0
RunService.Heartbeat:Connect(function(dt)
	sinceSweep += dt
	if sinceSweep >= SWEEP_EVERY then
		sinceSweep = 0
		sweep()
	end
	local clock = now()
	for index = #bits, 1, -1 do
		local bit = bits[index]
		local piece = bit.part
		if not piece.Parent or clock - bit.born > bit.life or piece.Position.Y < -500 then
			piece:Destroy()
			table.remove(bits, index)
		elseif bit.drift then
			local velocity = piece.AssemblyLinearVelocity
			if velocity.Y < -3 then
				-- Air under a leaf: it flutters down rather than drops.
				piece.AssemblyLinearVelocity = Vector3.new(velocity.X * 0.96, -3, velocity.Z * 0.96)
			end
		end
	end
end)
