-- Damage you can read (#71; Oliver 2026-09-24: "every material has its own cracking animation", and
-- then "improve the cracking animations"): whatever on the map is taking a beating cracks, chips,
-- splits, dents, flakes, crumbles, tears or flickers the way ITS material fails, and each new stage
-- GROWS in instead of popping in. Drawn on every client from what DestructibleService replicates:
--
--   DamageStage   attribute on the part (or on the Model, for a pool that is a whole Model):
--                 0 whole, 1 at 75% health, 2 at 50%, 3 at 25%. It only ever goes up.
--   DamageSites   attribute on each part that was hit: up to four "face,x,y,z" points in the part's
--                 own space, face being the Enum.NormalId value. Where the hits landed.
--   Damaged       tag on every part carrying sites, so a player who joins late, or streams the part
--                 in later, finds it and draws the same cracks (finished: nothing replays).
--   DamageFx      event, one per frame: that frame's hits, { part, point, face, count } each, for
--                 the burst and the sound every hit makes.
--
-- Each site grows from its own seed (its position), so a later stage extends the same cracks rather
-- than drawing new ones, and every client draws the same thing. EVERY Roblox part material has its
-- own look (PROFILES, one per material, its generator in LOOKS): concrete spalls to its rebar,
-- marble veins, granite fractures in crystal steps, slate flakes off in layers, sandstone crumbles
-- and trickles grains, basalt splits into hexagonal columns, cobblestone fails between its stones and
-- pebble spits its pebbles, asphalt alligator-cracks to a pothole, cracked lava glows hotter, ice and
-- glacier craze white along fracture planes, planks split at their seams and one springs loose,
-- diamond plate buckles, corroded metal flakes and rusts through, foil crumples and tears, neon goes
-- dark and flickers, tiles crack along the grout and pop off, roof tiles slip, shingles curl, plaster
-- falls away to lath or brick, cardboard creases, rubber gouges, leather slashes, carpet loses its
-- tufts, sand, snow, mud and earth slump and shed clods.
--
-- DEPTH. A crack is a GROOVE, not a line: a dark core, a thin lit lip along its upper side and a
-- shadow along its lower side (addLine), its width tapering to fine tips, with hairline branches off
-- the main cracks. At 25% the face itself is broken: displaced chunks of it standing proud with
-- their own shadow and outline (addDisplaced), and what is under it showing: rebar in concrete, lath
-- or brick under plaster, the pale core of split wood, bare metal under paint and rust.
--
-- MOTION. A stage that rises near you (ANIMATE_WITHIN) is PLAYED, in the material's own time (its
-- profile's `style`): every new piece waits a delay set by its distance from the hit along the crack
-- (so parents run first and branches sprout from them after, with BRANCH_STAGGER more per level),
-- then grows with an ease-out (a fast burst, then slowing):
--   steps   stone, brick, concrete, rock: the crack jumps outward in three hard steps
--   web     glass: the spiderweb's rays shoot out almost at once, then its rings creep round
--   race    ice, glacier: fracture planes race across behind a white flash at the hit
--   creep   wood, planks: splits creep along the grain, slowly and evenly
--   push    metal, diamond plate: dents push in and overshoot a little before they settle
--   flicker neon, force field: everything new blinks as it arrives, the dead patches keep blinking
--   slump   sand, snow, mud, earth: soft and slow, heaps sliding down
--   burst   everything else: a quick ease-out
-- Chips, flakes, splinters, tiles, bricks, pebbles, plaster and clods that come away leave as local
-- bits the moment their hole appears (and really fall, bounce, settle and fade); stone, plaster and
-- sand throw dust along the crack as it runs, metal sparks, glass tinkles shards. Late joiners and
-- anything built out of range get the finished marks.
--
-- SOUND. Every hit plays its material's two layers (a crack and a texture: `layers`), each with its
-- own pitch and volume jitter; a stage rising plays them again, louder. SoundConfig cues only.
--
-- READABLE FAR OFF (LOD). Near (under LOD_NEAR studs): everything. Middle: grooves without their
-- shadow, no hairlines. Far (over LOD_FAR): only the main cracks, drawn BOLDER (FAR_BOLD wider), and
-- the big pieces. A part's detail changes with hysteresis (LOD_SLACK) and is simply redrawn.
--
-- NEVER THE PART ITSELF. Every mark is a separate local part laid on the face (anchored, no
-- collision, no query, no shadow); nothing here writes the damaged part's Transparency,
-- LocalTransparencyModifier, Color or anything else, so it stays exactly as solid and as opaque as
-- the server left it right up to the moment it breaks (#71: never fade toward clear). Neon's
-- flicker is dark patches over it blinking, not the neon itself. tools/crack_check.py holds that,
-- with the old fade planted.
--
-- BUDGET (lag, #131), all enforced here and held by tools/crack_check.py:
--   per site      SPECS_PER_SITE pieces grown, PER_SITE_CAP of them drawn (fewer far off: LOD)
--   per part      MAX_SITES_PER_PART sites (the server's cap too), so at most 4 x PER_SITE_CAP pieces
--   in total      MAX_BUILT parts drawn at once (the nearest), MAX_PIECES pieces, MAX_TRICKLES
--                 emitters (dust, grains, embers, sparks), MAX_BITS flying bits (each gone after its
--                 life), MAX_FLICKER flickering patches (FLICKER_HZ updates a second), MAX_PUFFS
--                 puff emitters alive at once
--   animation     at most MAX_ANIMATING pieces moving at once, each for at most its style's spread +
--                 grow (0.9 s at the longest, glass rings), only within ANIMATE_WITHIN studs; past
--                 either, a piece simply appears finished. All moves go through one BulkMoveTo a frame.
--   distance      drawn within BUILD_WITHIN studs, taken down past DROP_BEYOND; hit bursts and sounds
--                 only within BURST_DISTANCE, BURSTS_PER_EVENT / SOUNDS_PER_EVENT per event
--   cleanup       a part's marks go the moment it is destroyed (it broke, or the map unloaded), when
--                 it comes loose (a collapsing chunk: drawn again, finished, once it lands as rubble),
--                 and the sweep drops anything no longer in the workspace

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local SoundConfig = require(Shared:WaitForChild("SoundConfig"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local damageFx = Remotes.Event("DamageFx")
local camera = workspace.CurrentCamera

-- Must match DestructibleService.StageAttribute / SitesAttribute / DamagedTag.
local STAGE_ATTRIBUTE, SITES_ATTRIBUTE, DAMAGED_TAG = "DamageStage", "DamageSites", "Damaged"

local MAX_SITES_PER_PART = 4
local SPECS_PER_SITE = 170
local PER_SITE_CAP = 90
-- ...of which at most PER_SITE_LINES are crack lines (a groove is three), so a site's chips, craters,
-- plates and holes are never crowded out by its cracks.
local PER_SITE_LINES = 60
local MAX_BUILT = 60
local MAX_PIECES = 2600
local MAX_TRICKLES = 16
local MAX_BITS = 90
local MAX_ANIMATING = 420
local MAX_FLICKER = 24
local MAX_PUFFS = 24
local FLICKER_HZ = 20
local BIT_LIFE = 2.6
local BIT_FADE = 0.5
local BUILD_WITHIN, DROP_BEYOND = 150, 190
local ANIMATE_WITHIN = 140
local BURST_DISTANCE = 180
local BURSTS_PER_EVENT, SOUNDS_PER_EVENT = 10, 3
local LOD_NEAR, LOD_FAR, LOD_SLACK = 45, 100, 6
local FAR_BOLD = 1.8
local BRANCH_STAGGER = 0.06
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
local NEON = Enum.Material.Neon
local LIGHT = PhysicalProperties.new(0.08, 0.5, 0.3)
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/fire_sparks_main.dds"
local RUST = Color3.fromRGB(128, 62, 30)
local EMBER = Color3.fromRGB(255, 132, 36)

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- DestructibleService's CLASS_OF with brick told apart from the other stone (it cracks along its
-- courses). tools/crack_check.py holds the two tables to agreeing. The FAMILY is the coarse kind a
-- material is (what its dust trickles are); the PROFILE below is what it LOOKS like failing.
local M = Enum.Material
local FAMILY = {
	[M.Wood] = "wood", [M.WoodPlanks] = "wood",
	[M.Brick] = "brick",
	[M.Concrete] = "stone", [M.Slate] = "stone", [M.Rock] = "stone", [M.Cobblestone] = "stone",
	[M.Granite] = "stone", [M.Marble] = "stone", [M.Pebble] = "stone", [M.Basalt] = "stone",
	[M.Limestone] = "stone", [M.Sandstone] = "stone", [M.Pavement] = "stone", [M.Asphalt] = "stone",
	[M.CrackedLava] = "stone", [M.Salt] = "stone", [M.Plaster] = "stone", [M.CeramicTiles] = "stone",
	[M.ClayRoofTiles] = "stone", [M.RoofShingles] = "stone",
	[M.Metal] = "metal", [M.DiamondPlate] = "metal", [M.CorrodedMetal] = "metal", [M.Foil] = "metal",
	[M.Grass] = "foliage", [M.LeafyGrass] = "foliage",
	[M.Ground] = "soil", [M.Sand] = "soil", [M.Snow] = "soil", [M.Mud] = "soil",
	[M.Fabric] = "cloth", [M.Carpet] = "cloth", [M.Leather] = "cloth", [M.Cardboard] = "cloth",
	[M.Glass] = "glass", [M.Ice] = "glass", [M.Glacier] = "glass", [M.Neon] = "glass", [M.ForceField] = "glass",
	[M.Plastic] = "plastic", [M.SmoothPlastic] = "plastic", [M.Rubber] = "plastic",
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
-- v, z out of the face), each tagged with the stage it appears at, its distance from the hit along
-- the crack (`dist`, which orders the growth), its branch level (0 a main crack, 1 a fork, 2 a
-- hairline: `branch`, which staggers it) and the coarsest detail it is drawn at (`lod`: 3 always,
-- 2 middle and near, 1 near only). Grown whole from the site's seed; a stage shows the pieces tagged
-- at or below it, in order, up to PER_SITE_CAP. How a piece arrives:
--   line    a crack: grows from its start point to its end
--   pop     swells from `pop` of its size to all of it (chips, dents, craters, holes, glows)
--   swing   a plate hinged at one edge swings from flat to its angle, overshooting a little
--   slide   moves in from `slide` (face frame) to where it rests (a slipping tile, a brick)
--   detach  as it appears, a bit shaped `detach` flies off from it (what left the hole)
--   flicker keeps blinking (neon's dead patches, a force field's torn edge) while drawn
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
				return nil, nil, nil, nil, false
			end
		else
			local t = q / p
			if p < 0 then
				if t > t1 then
					return nil, nil, nil, nil, false
				elseif t > t0 then
					t0 = t
				end
			else
				if t < t0 then
					return nil, nil, nil, nil, false
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

local function radial(s, u, v)
	return math.sqrt((u - s.u) ^ 2 + (v - s.v) ^ 2)
end

local function lineSpec(kind, stage, a, b, length, angle, width, z, color, material, transparency, dist, branch, lod, grow)
	return {
		kind = kind,
		stage = stage,
		grow = grow,
		size = Vector3.new(length + width * 0.5, width, LINE_DEPTH),
		frame = CFrame.new(a + math.cos(angle) * length / 2, b + math.sin(angle) * length / 2, z) * CFrame.Angles(0, 0, angle),
		line = { u = a, v = b, angle = angle, length = length, width = width, z = z },
		color = color,
		material = material,
		transparency = transparency,
		dist = dist,
		branch = branch,
		lod = lod,
	}
end

-- A crack from (u1, v1) to (u2, v2). Unless `o.flat` (a scratch, a seam line, a pale web), it is a
-- GROOVE of three: the dark core; a thin lip lit along its upper side (the side facing up the face,
-- or +u on a floor); a shadow along its lower side (near detail only). `o` (optional): { flat, widen,
-- material, name, dist, lift, branch, lod, reflect, lip }. Returns false once it has run off the face.
local function addLine(specs, stage, g, u1, v1, u2, v2, width, color, transparency, o)
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
	local angle = math.atan2(dv, du)
	local lift = (o and o.lift or LIFT)
	local branch = o and o.branch or 0
	local lod = o and o.lod or (branch == 0 and 3 or (branch == 1 and 2 or 1))
	local dist = o and o.dist or (g.s and radial(g.s, a, b) or 0)
	local grow = not (o and o.widen == false)
	local core = lineSpec(o and o.name or "CrackLine", stage, a, b, length, angle, width, lift + LINE_DEPTH / 2, color,
		o and o.material or nil, transparency, dist, branch, lod, grow)
	core.core = true
	core.reflect = o and o.reflect
	table.insert(specs, core)
	if not (o and o.flat) and width >= 0.02 and not full(specs) then
		-- The side facing up the face (or +u on a floor) catches the light.
		local px, py = -math.sin(angle), math.cos(angle)
		if py < -1e-3 or (math.abs(py) <= 1e-3 and px < 0) then
			px, py = -px, -py
		end
		local surface = g.color or color
		local lipW = math.max(0.014, width * 0.4)
		local lip = lineSpec("CrackLip", stage, a + px * (width + lipW) / 2, b + py * (width + lipW) / 2, length, angle, lipW,
			lift + LINE_DEPTH / 2 + 0.003, (o and o.lip) or surface:Lerp(WHITE, 0.5), nil, transparency, dist, branch, math.min(lod, 2), false)
		table.insert(specs, lip)
		if not full(specs) then
			local shadowW = math.max(0.012, width * 0.35)
			local shadow = lineSpec("CrackShade", stage, a - px * (width + shadowW) / 2, b - py * (width + shadowW) / 2, length, angle, shadowW,
				lift + LINE_DEPTH / 2 - 0.002, surface:Lerp(BLACK, 0.5), nil, transparency, dist, branch, 1, false)
			table.insert(specs, shadow)
		end
	end
	return whole
end

-- A flat piece on the face: `size` along u, along v and out of it; turned `angle` about the normal;
-- its underside `lift` off the face. Skipped if its middle would be off the face. `o` (optional):
-- { name, pop, slide, detach, flicker, shape, class, reflect, lod }.
local function addBox(specs, stage, g, u, v, size, angle, lift, color, material, transparency, o)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return nil
	end
	local spec = {
		kind = o and o.name or "CrackChip",
		stage = stage,
		size = size,
		frame = CFrame.new(u, v, lift + size.Z / 2) * CFrame.Angles(0, 0, angle),
		color = color,
		material = material,
		transparency = transparency,
		dist = g.s and radial(g.s, u, v) or 0,
		pop = o and o.pop or 0.25,
		slide = o and o.slide,
		detach = o and o.detach,
		flicker = o and o.flicker,
		shape = o and o.shape,
		class = o and o.class,
		reflect = o and o.reflect,
		lod = o and o.lod or 3,
		branch = 0,
	}
	table.insert(specs, spec)
	return spec
end

-- A round mark (a dent ring, a scorch, a socket, a dimple): a disc `diameter` across.
local function addDisc(specs, stage, g, u, v, diameter, lift, color, material, transparency, o)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return nil
	end
	local thickness = o and o.thickness or 0.02
	-- A cylinder's length is its X axis, so X goes along the normal.
	local spec = {
		kind = o and o.name or "CrackDent",
		stage = stage,
		shape = Enum.PartType.Cylinder,
		size = Vector3.new(thickness, diameter, diameter),
		frame = CFrame.fromMatrix(Vector3.new(u, v, lift + thickness / 2), Vector3.new(0, 0, 1), Vector3.new(0, 1, 0)),
		color = color,
		material = material,
		transparency = transparency,
		dist = g.s and radial(g.s, u, v) or 0,
		pop = o and o.pop or 0.2,
		detach = o and o.detach,
		flicker = o and o.flicker,
		slide = o and o.slide,
		reflect = o and o.reflect,
		lod = o and o.lod or 3,
		branch = 0,
	}
	table.insert(specs, spec)
	return spec
end

-- Something sticking out of the face from (u, v) along `direction` (a unit vector in the face's
-- frame, pointing out of it): a splinter, a snapped twig, a tuft.
local function addStick(specs, stage, g, u, v, direction, length, thickness, color, material, o)
	if full(specs) or math.abs(u) > g.hu - EDGE or math.abs(v) > g.hv - EDGE then
		return nil
	end
	local across = Vector3.new(-direction.Y, direction.X, 0)
	across = across.Magnitude > 1e-3 and across.Unit or Vector3.new(1, 0, 0)
	local centre = Vector3.new(u, v, 0) + direction * (length / 2)
	local spec = {
		kind = o and o.name or "CrackStick",
		stage = stage,
		size = Vector3.new(thickness, thickness, length),
		frame = CFrame.fromMatrix(centre, across, direction:Cross(across), direction),
		color = color,
		material = material,
		dist = g.s and radial(g.s, u, v) or 0,
		pop = 0.05,
		lod = o and o.lod or 2,
		branch = 1,
	}
	table.insert(specs, spec)
	return spec
end

-- A plate hinged at (u, v), lying along the in-plane direction (du, dv) and lifted off the face by
-- `angle`: a loose board, a peeled edge, a torn flap, a curled shingle. It swings open when shown.
local function hingeFrame(u, v, du, dv, length, thickness, angle)
	local along = Vector3.new(du, dv, 0).Unit
	local out = Vector3.new(0, 0, 1)
	local x = along * math.cos(angle) + out * math.sin(angle)
	local z = out * math.cos(angle) - along * math.sin(angle)
	local centre = Vector3.new(u, v, thickness / 2 + LIFT) + x * (length / 2)
	return CFrame.fromMatrix(centre, x, z:Cross(x), z)
end

local function addHinged(specs, stage, g, u, v, du, dv, length, width, thickness, angle, color, material, o)
	if full(specs) or math.abs(u) > g.hu or math.abs(v) > g.hv then
		return nil
	end
	local spec = {
		kind = o and o.name or "CrackPlate",
		stage = stage,
		size = Vector3.new(length, width, thickness),
		frame = hingeFrame(u, v, du, dv, length, thickness, angle),
		swing = { u = u, v = v, du = du, dv = dv, length = length, thickness = thickness, angle = angle },
		color = color,
		material = material,
		dist = g.s and radial(g.s, u, v) or 0,
		detach = o and o.detach,
		reflect = o and o.reflect,
		lod = o and o.lod or 3,
		branch = 0,
	}
	table.insert(specs, spec)
	return spec
end

-- A rod lying in the face plane at depth `z`: rebar, lath, a corrugation, a strand.
local function addRod(specs, stage, g, u1, v1, u2, v2, z, thickness, color, material, o)
	if full(specs) then
		return nil
	end
	local a, b, c, d, _ = clip(u1, v1, u2, v2, g.hu - EDGE, g.hv - EDGE)
	if not a then
		return nil
	end
	local du, dv = c - a, d - b
	local length = math.sqrt(du * du + dv * dv)
	if length < 0.05 then
		return nil
	end
	local angle = math.atan2(dv, du)
	local round = not (o and o.square)
	local spec = {
		kind = o and o.name or "CrackRod",
		stage = stage,
		shape = round and Enum.PartType.Cylinder or nil,
		size = Vector3.new(length, thickness, thickness),
		frame = CFrame.new((a + c) / 2, (b + d) / 2, z) * CFrame.Angles(0, 0, angle),
		color = color,
		material = material,
		dist = g.s and radial(g.s, (a + c) / 2, (b + d) / 2) or 0,
		pop = 0.1,
		lod = o and o.lod or 3,
		branch = 0,
	}
	table.insert(specs, spec)
	return spec
end

-- A wedge on the face (a crystal facet, a shard, a sharp-edged hole): WedgePart, its slope toward +v.
local function addWedge(specs, stage, g, u, v, size, angle, lift, color, material, transparency, o)
	local spec = addBox(specs, stage, g, u, v, size, angle, lift, color, material, transparency, o)
	if spec then
		spec.class = "WedgePart"
		spec.kind = o and o.name or "CrackFacet"
		-- Laid flat: its sloped face out of the face.
		spec.frame = CFrame.new(u, v, lift + size.Y / 2) * CFrame.Angles(0, 0, angle) * CFrame.Angles(math.pi / 2, 0, 0)
		spec.size = Vector3.new(size.X, size.Z, size.Y)
	end
	return spec
end

-- A regular hexagon (three boxes turned 60 degrees apart), circumradius r: a basalt column's face.
local function addHex(specs, stage, g, u, v, r, lift, depth, color, material, o)
	local first = nil
	for k = 0, 2 do
		local spec = addBox(specs, stage, g, u, v, Vector3.new(r, math.sqrt(3) * r, depth), k * math.pi / 3, lift, color, material, nil, o)
		first = first or spec
		if spec and k > 0 then
			-- Only the first carries the detach, so one column leaves, not three.
			spec.detach = nil
		end
	end
	return first
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

local function near(rng, s, radius)
	local angle, r = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.3, 1) * radius
	return s.u + math.cos(angle) * r, s.v + math.sin(angle) * r
end

-- Branching cracks: `rays` of them out from the site, each a jagged run of short segments that may
-- fork, the forks shorter and finer; fine HAIRLINES (branch 2, near detail only) flick off the
-- main runs. Width tapers along each run to a fine tip. A segment's stage is how far out it ends, so
-- each stage carries the same cracks further. opts: rays, jag, fork, width, color, transparency,
-- material, step ({min, max}), snap (angles held to multiples of it: crystal steps), bias (a
-- preferred heading and its pull), name, hair (chance of a hairline per segment), flat, lip.
local function crackTree(rng, specs, s, g, reach, opts)
	local branches = {}
	local start = opts.start or rng:NextNumber(0, math.pi * 2)
	for ray = 1, opts.rays do
		table.insert(branches, {
			u = s.u, v = s.v, depth = 0, travelled = 0,
			angle = start + ray / opts.rays * math.pi * 2 + rng:NextNumber(-0.4, 0.4),
			limit = reach[3] * rng:NextNumber(0.75, 1),
		})
	end
	local stepMin, stepMax = (opts.step or { 0.35, 0.6 })[1], (opts.step or { 0.35, 0.6 })[2]
	local hair = opts.hair or 0.35
	local index = 1
	while index <= #branches and not full(specs) do
		local branch = branches[index]
		index += 1
		while branch.travelled < branch.limit do
			local step = rng:NextNumber(stepMin, stepMax) * g.scale
			branch.angle += rng:NextNumber(-opts.jag, opts.jag)
			if opts.bias then
				local target = opts.bias[1] + (math.cos(branch.angle - opts.bias[1]) < 0 and math.pi or 0)
				branch.angle += (target - branch.angle) * opts.bias[2]
			end
			local heading = branch.angle
			if opts.snap then
				heading = math.floor(heading / opts.snap + 0.5) * opts.snap
			end
			local nu = branch.u + math.cos(heading) * step
			local nv = branch.v + math.sin(heading) * step
			local stage = stageAt(reach, branch.travelled + step)
			if not stage then
				break
			end
			-- Tapers: full width at the root, a fine tip at the end of its run.
			local along = math.clamp(branch.travelled / math.max(branch.limit, 0.01), 0, 1)
			local width = opts.width * (1 - 0.72 * along * along) * (branch.depth > 0 and 0.62 or 1)
			if not addLine(specs, stage, g, branch.u, branch.v, nu, nv, width, opts.color, opts.transparency,
				{ material = opts.material, name = opts.name, dist = branch.travelled, widen = opts.widen, branch = math.min(branch.depth, 1),
					flat = opts.flat, lip = opts.lip }) then
				break
			end
			-- A hairline off the run (near detail only).
			if branch.depth == 0 and rng:NextNumber() < hair and not full(specs) then
				local side = rng:NextNumber() < 0.5 and -1 or 1
				local ha = heading + side * rng:NextNumber(0.7, 1.4)
				local hl = rng:NextNumber(0.15, 0.4) * g.scale
				addLine(specs, stage, g, nu, nv, nu + math.cos(ha) * hl, nv + math.sin(ha) * hl, math.max(0.012, opts.width * 0.28), opts.color,
					opts.transparency, { material = opts.material, name = "CrackHair", dist = branch.travelled + step, branch = 2, flat = true })
			end
			if branch.depth < 2 and rng:NextNumber() < opts.fork then
				local turn = (rng:NextNumber() < 0.5 and -1 or 1) * rng:NextNumber(0.5, 1.1)
				table.insert(branches, {
					u = nu, v = nv, depth = branch.depth + 1, travelled = branch.travelled + step,
					angle = heading + turn,
					limit = branch.travelled + step + (branch.limit - branch.travelled - step) * 0.6,
				})
			end
			branch.u, branch.v = nu, nv
			branch.travelled += step
		end
	end
end

-- A net of cracks: a jittered grid of nodes round the site (cell `cell` studs), every node joined to
-- its right and upper neighbours, each edge shown at the stage its nearer end reaches. Alligator
-- cracking, dried mud, crazing. The inner rings are main cracks (seen from anywhere), the outer ones
-- finer detail. opts: cell, jitter, width, color, transparency, material, name, hex, flat, density.
local function crackNet(rng, specs, s, g, reach, opts)
	local cell = opts.cell * math.sqrt(g.scale)
	local n = math.ceil(reach[3] / cell) + 1
	local nodes = {}
	for i = -n, n do
		nodes[i] = {}
		for j = -n, n do
			local shift = opts.hex and (j % 2) * cell / 2 or 0
			nodes[i][j] = { s.u + i * cell + shift + rng:NextNumber(-opts.jitter, opts.jitter) * cell,
				s.v + j * cell * (opts.hex and 0.866 or 1) + rng:NextNumber(-opts.jitter, opts.jitter) * cell }
		end
	end
	local edges = {}
	for i = -n, n do
		for j = -n, n do
			local a = nodes[i][j]
			local neighbours = { nodes[i + 1] and nodes[i + 1][j], nodes[i][j + 1] }
			if opts.hex then
				local k = (j % 2 == 0) and i - 1 or i + 1
				table.insert(neighbours, nodes[k] and nodes[k][j + 1])
			end
			for _, b in ipairs(neighbours) do
				if b then
					local d = math.min(radial(s, a[1], a[2]), radial(s, b[1], b[2]))
					if d <= reach[3] then
						table.insert(edges, { a, b, d })
					end
				end
			end
		end
	end
	table.sort(edges, function(x, y)
		return x[3] < y[3]
	end)
	for _, e in ipairs(edges) do
		if full(specs) then
			break
		end
		local stage = stageAt(reach, e[3])
		if stage and rng:NextNumber() < (opts.density or 1) then
			-- The innermost ring is main cracks (grooves, seen from anywhere); the next two finer detail.
			local branch = e[3] <= reach[0] * 1.5 and 0 or (e[3] <= reach[2] and 1 or 2)
			addLine(specs, stage, g, e[1][1], e[1][2], e[2][1], e[2][2], opts.width * (1 - 0.4 * e[3] / reach[3]), opts.color,
				opts.transparency, { material = opts.material, name = opts.name, dist = e[3], branch = branch,
					flat = opts.flat or (opts.outerFlat and branch > 0) })
		end
	end
	return nodes
end

-- A chip knocked out: the fresh broken inside in a darker rim; it leaves as a flying chip.
local function addChip(specs, stage, g, rng, u, v, across, color, o)
	local angle = rng:NextNumber(0, math.pi)
	local a, b = across * rng:NextNumber(0.8, 1.2), across * rng:NextNumber(0.6, 1)
	local inner = (o and o.inner) or color:Lerp(WHITE, 0.18)
	addBox(specs, stage, g, u, v, Vector3.new(a + 0.08, b + 0.08, 0.02), angle, LIFT, (o and o.rim) or color:Lerp(BLACK, 0.55), SMOOTH)
	return addBox(specs, stage, g, u, v, Vector3.new(a, b, 0.03), angle, LIFT + 0.004, inner, (o and o.material) or SMOOTH, nil,
		{ detach = { size = Vector3.new(a, b, a * 0.7), color = color, kind = o and o.bit or "chip" } })
end

-- A crater where the hits went in: dark rim, lighter broken floor, lumps still clinging on.
local function addCrater(specs, stage, g, rng, s, size, color, o)
	local crater = math.min(size * math.sqrt(g.scale), g.hu, g.hv)
	addBox(specs, stage, g, s.u, s.v, Vector3.new(crater, crater * 0.8, 0.02), rng:NextNumber(0, math.pi), LIFT - 0.004,
		(o and o.rim) or color:Lerp(BLACK, 0.6), SMOOTH, nil, { name = "CrackCrater", pop = 0.1 })
	addBox(specs, stage, g, s.u, s.v, Vector3.new(crater * 0.8, crater * 0.6, 0.03), rng:NextNumber(0, math.pi), LIFT,
		(o and o.floor) or color:Lerp(WHITE, 0.12), (o and o.material) or SMOOTH, nil, { name = "CrackCrater", pop = 0.1 })
	return crater
end

-- 25%: the face itself broken: `count` chunks of it (its own material and colour) knocked out of
-- line round the hit, each tilted proud of the face with a dark gap round it and its own shadow on
-- its low side, so the face reads as shattered into plates, not drawn on.
local function addDisplaced(specs, stage, g, rng, s, count, spread, size, material, color)
	for k = 1, count do
		if full(specs) then
			return
		end
		local a = k / count * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
		local r = spread * rng:NextNumber(0.45, 1) * math.sqrt(g.scale)
		local u, v = s.u + math.cos(a) * r, s.v + math.sin(a) * r
		local w, h = size * rng:NextNumber(0.7, 1.2), size * rng:NextNumber(0.5, 0.9)
		local turn = rng:NextNumber(-0.5, 0.5)
		-- The gap round it (dark, a little bigger, flat on the face).
		addBox(specs, stage, g, u, v, Vector3.new(w + 0.12, h + 0.12, 0.012), turn, LIFT - 0.002, color:Lerp(BLACK, 0.75), SMOOTH, nil,
			{ name = "CrackGap", pop = 0.6 })
		-- The chunk, pushed out and tipped: it slides out of the face as it breaks.
		local chunk = addBox(specs, stage, g, u, v, Vector3.new(w, h, 0.14), turn, LIFT + 0.05, color:Lerp(BLACK, rng:NextNumber(0, 0.12)), material, nil,
			{ name = "CrackDisplaced", slide = Vector3.new(0, 0, -0.16), pop = 1 })
		if chunk then
			chunk.frame = chunk.frame * CFrame.Angles(rng:NextNumber(-0.14, 0.14), rng:NextNumber(-0.14, 0.14), 0)
		end
		-- Its shadow, on the low side.
		addBox(specs, stage, g, u + 0.04, v - h * 0.5 - 0.05, Vector3.new(w * 0.95, 0.09, 0.012), turn, LIFT - 0.001, BLACK, SMOOTH, 0.35,
			{ name = "CrackShadow", lod = 2 })
	end
end

--------------------------------------------------------------------------------
-- LOOKS: one per material. Each draws a site into `specs`; `s` is the hit ({u, v}), `g` its face
-- (half sizes hu, hv; scale; side = an upright face), `c` the part's colour, `mat` its material.
--------------------------------------------------------------------------------

local LOOKS = {}

-- CONCRETE: jagged branching cracks, chips knocked out, a spall at 50%, and at 25% the spall goes
-- deep enough to show the rebar: rusty rods crossing the hole in a grid.
function LOOKS.Concrete(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.8, 3.0 }, g.scale)
	addChip(specs, 0, g, rng, s.u, s.v, 0.22, c)
	local cu, cv = near(rng, s, 0.6 * g.scale)
	addChip(specs, 1, g, rng, cu, cv, 0.26, c)
	local crater = addCrater(specs, 2, g, rng, s, 1.1, c, { floor = c:Lerp(WHITE, 0.2) })
	for _ = 1, 4 do
		local u, v = near(rng, s, crater * 0.4)
		addBox(specs, 2, g, u, v, Vector3.new(0.12, 0.1, 0.06), rng:NextNumber(0, 3), LIFT + 0.03, c:Lerp(BLACK, 0.35), SMOOTH, nil, { name = "CrackAggregate" })
	end
	-- 25%: deeper, and the steel inside it: two bars one way, one the other.
	local deep = addCrater(specs, 3, g, rng, s, 1.6, c, { rim = c:Lerp(BLACK, 0.7), floor = c:Lerp(BLACK, 0.3) })
	for k = -1, 1, 2 do
		addRod(specs, 3, g, s.u - deep * 0.6, s.v + k * deep * 0.18, s.u + deep * 0.6, s.v + k * deep * 0.18, LIFT + 0.08, 0.14, RUST, M.CorrodedMetal, { name = "CrackRebar" })
	end
	addRod(specs, 3, g, s.u + deep * 0.12, s.v - deep * 0.45, s.u + deep * 0.12, s.v + deep * 0.45, LIFT + 0.12, 0.13, RUST, M.CorrodedMetal, { name = "CrackRebar" })
	addDisplaced(specs, 3, g, rng, s, 4, deep * 0.9, 0.7, M.Concrete, c)
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 4), jag = 0.55, fork = 0.28, width = 0.085, color = c:Lerp(BLACK, 0.72), hair = 0.5 })
end

-- BRICK: cracks stepping along the mortar courses; bricks working loose, one gone at 25%.
function LOOKS.Brick(rng, specs, s, g, c)
	if not g.side then
		return LOOKS.Concrete(rng, specs, s, g, c)
	end
	local reach = reachOf({ 0.4, 1.4, 2.8, 4.6 }, g.scale)
	local mortar = c:Lerp(BLACK, 0.7)
	addChip(specs, 0, g, rng, s.u, s.v, 0.2, c)
	-- Loose bricks first (so the per-site cap only ever trims crack ends).
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
		local spec = addBox(specs, stage, g, u, v, Vector3.new(BRICK_W * 0.94, BRICK_H * 0.86, 0.3), 0, -rng:NextNumber(0.04, 0.12),
			c:Lerp(rng:NextNumber() < 0.5 and BLACK or WHITE, rng:NextNumber(0.04, 0.12)), SMOOTH, nil,
			{ name = "CrackBrick", slide = Vector3.new(0, 0, -0.25), pop = 1 })
		if spec then
			spec.frame = spec.frame * CFrame.Angles(rng:NextNumber(-0.07, 0.07), rng:NextNumber(-0.07, 0.07), rng:NextNumber(-0.04, 0.04))
		end
	end
	loose(2, cell, row)
	loose(3, cell + (rng:NextNumber() < 0.5 and -1 or 1), row)
	local gu, gv = brickAt(cell, row + (rng:NextNumber() < 0.5 and -1 or 1))
	if math.abs(gu) + BRICK_W / 2 <= g.hu and math.abs(gv) + BRICK_H / 2 <= g.hv then
		-- Where this brick was: it drops out as the wall reaches the stage.
		addBox(specs, 3, g, gu, gv, Vector3.new(BRICK_W * 0.92, BRICK_H * 0.84, 0.02), 0, LIFT, c:Lerp(BLACK, 0.85), SMOOTH, nil,
			{ name = "CrackBrickGap", detach = { size = Vector3.new(BRICK_W * 0.9, BRICK_H * 0.8, 0.4), color = c, kind = "brick", life = 3 } })
	end
	for path = 1, rng:NextInteger(2, 3) do
		local dirU = rng:NextNumber() < 0.5 and -1 or 1
		local dirV = (path == 1 or rng:NextNumber() < 0.7) and -1 or 1
		local course = math.floor(s.v / BRICK_H + 0.5)
		local u, v = s.u, course * BRICK_H
		local travelled = math.abs(v - s.v)
		addLine(specs, 0, g, s.u, s.v, u, v, 0.06, mortar, nil, { dist = 0 })
		while travelled < reach[3] and not full(specs) do
			local r = dirV < 0 and course - 1 or course
			local off = (r % 2) * BRICK_W / 2
			local k = dirU > 0 and math.floor((u - off) / BRICK_W) + 1 or math.ceil((u - off) / BRICK_W) - 1
			if rng:NextNumber() < 0.3 then
				k += dirU
			end
			local head = k * BRICK_W + off
			local run = math.abs(head - u)
			local stage = stageAt(reach, travelled + run)
			if not stage or not addLine(specs, stage, g, u, v, head, v, 0.06, mortar, nil, { dist = travelled }) then
				break
			end
			travelled += run
			stage = stageAt(reach, travelled + BRICK_H)
			if not stage or not addLine(specs, stage, g, head, v, head, v + dirV * BRICK_H, 0.06, mortar, nil, { dist = travelled }) then
				break
			end
			travelled += BRICK_H
			u, v, course = head, v + dirV * BRICK_H, course + dirV
		end
	end
end

-- MARBLE: long hairline veins, pale and fine, that barely branch; bright conchoidal scallops where
-- flakes came off; at 25% a clean sharp-edged piece gone, white inside.
function LOOKS.Marble(rng, specs, s, g, c)
	local reach = reachOf({ 0.5, 1.5, 2.8, 4.2 }, g.scale)
	local vein = c:Lerp(rgb(70, 80, 96), 0.55)
	for stage = 0, 3 do
		local count = stage == 0 and 1 or 2
		for _ = 1, count do
			local u, v = near(rng, s, (0.2 + stage * 0.35) * g.scale)
			addDisc(specs, stage, g, u, v, rng:NextNumber(0.25, 0.45) * math.sqrt(g.scale), LIFT, c:Lerp(WHITE, 0.55), SMOOTH, nil,
				{ name = "CrackScallop", detach = { size = Vector3.new(0.3, 0.05, 0.25), color = c:Lerp(WHITE, 0.3), kind = "flake" } })
		end
	end
	local shard = math.min(1.1 * math.sqrt(g.scale), g.hu, g.hv)
	addWedge(specs, 3, g, s.u, s.v, Vector3.new(shard, shard * 0.7, 0.05), rng:NextNumber(0, 6), LIFT, c:Lerp(WHITE, 0.7), SMOOTH, nil, { name = "CrackShard" })
	addWedge(specs, 3, g, s.u + 0.1, s.v - 0.1, Vector3.new(shard * 0.7, shard * 0.5, 0.06), rng:NextNumber(0, 6), LIFT + 0.01, c:Lerp(BLACK, 0.25), SMOOTH, nil, { name = "CrackShard" })
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(2, 3), jag = 0.12, fork = 0.08, width = 0.03, color = vein, transparency = 0.15,
		step = { 0.5, 0.9 }, name = "CrackVein", flat = true, hair = 0.2 })
end

-- GRANITE: fractures that turn in hard crystal steps (every heading a multiple of 30 degrees),
-- speckled grains glinting where it broke, and at 25% a faceted pit of broken crystals.
function LOOKS.Granite(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 1.0, 1.9, 3.0 }, g.scale)
	local speck = { rgb(30, 28, 30), rgb(236, 230, 228), rgb(196, 140, 132) }
	addChip(specs, 0, g, rng, s.u, s.v, 0.22, c)
	for stage = 1, 3 do
		for _ = 1, 3 do
			local u, v = near(rng, s, (0.3 + stage * 0.3) * g.scale)
			addWedge(specs, stage, g, u, v, Vector3.new(0.18, 0.14, 0.05), rng:NextInteger(0, 5) * math.pi / 3, LIFT, speck[rng:NextInteger(1, 3)],
				SMOOTH, nil, { name = "CrackCrystal", reflect = 0.35, detach = { size = Vector3.new(0.14, 0.1, 0.1), color = speck[rng:NextInteger(1, 3)], kind = "crystal" } })
		end
	end
	local pit = math.min(1.3 * math.sqrt(g.scale), g.hu, g.hv)
	for k = 0, 4 do
		local a = k / 5 * math.pi * 2
		addWedge(specs, 3, g, s.u + math.cos(a) * pit * 0.22, s.v + math.sin(a) * pit * 0.22, Vector3.new(pit * 0.45, pit * 0.4, 0.08),
			a + math.pi / 2, LIFT, c:Lerp(k % 2 == 0 and BLACK or WHITE, 0.3), SMOOTH, nil, { name = "CrackFacet" })
	end
	addDisplaced(specs, 3, g, rng, s, 3, pit * 1.1, 0.6, M.Granite, c)
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 4), jag = 0.9, fork = 0.3, width = 0.07, color = c:Lerp(BLACK, 0.75),
		snap = math.pi / 6, step = { 0.25, 0.45 }, name = "CrackFracture" })
end

-- SLATE: it splits along its cleavage: long cracks running level with short steps between them;
-- thin flakes lift at an edge, then come off, leaving a terraced scar of lighter layers beneath.
function LOOKS.Slate(rng, specs, s, g, c)
	local reach = reachOf({ 0.5, 1.4, 2.6, 3.8 }, g.scale)
	local dark = c:Lerp(BLACK, 0.7)
	local layers = { c:Lerp(WHITE, 0.1), c:Lerp(WHITE, 0.18), c:Lerp(WHITE, 0.26) }
	for stage = 1, 3 do
		local w, h = (0.7 + stage * 0.45) * g.scale, (0.35 + stage * 0.22) * g.scale
		addBox(specs, stage, g, s.u + rng:NextNumber(-0.1, 0.1), s.v - stage * 0.05, Vector3.new(w, h, 0.02 + stage * 0.012), 0, LIFT,
			layers[stage], SMOOTH, nil, { name = "CrackLayer", pop = 0.6 })
		-- The flake that was there: it lifts a stage early, then leaves.
		addHinged(specs, stage - 1, g, s.u - w / 2, s.v + (rng:NextNumber() < 0.5 and 1 or -1) * h * 0.3, 1, 0, w, h, 0.05, 0.18 + stage * 0.08,
			c:Lerp(BLACK, 0.08), M.Slate, { name = "CrackFlake" })
		addBox(specs, stage, g, s.u, s.v + h * 0.55, Vector3.new(w * 0.95, 0.03, 0.03), 0, LIFT + 0.02, dark, SMOOTH, nil,
			{ name = "CrackStep", detach = { size = Vector3.new(w * 0.6, 0.05, h * 0.8), color = c, kind = "flake" } })
	end
	-- The cleavage: level runs, stepping up or down a little between them.
	for _, sign in ipairs({ 1, -1 }) do
		local u, v, travelled = s.u, s.v, 0
		while travelled < reach[3] and not full(specs) do
			local run = rng:NextNumber(0.6, 1.2) * g.scale
			local stage = stageAt(reach, travelled + run)
			if not stage or not addLine(specs, stage, g, u, v, u + sign * run, v, 0.045, dark, nil, { dist = travelled, name = "CrackCleave" }) then
				break
			end
			u, travelled = u + sign * run, travelled + run
			local jog = rng:NextNumber(-0.25, 0.25) * g.scale
			addLine(specs, stage, g, u, v, u, v + jog, 0.035, dark, nil, { dist = travelled, name = "CrackCleave" })
			v = v + jog
		end
	end
end

-- SANDSTONE: soft, wide, pale-edged cracks; rounded pits worn out of it; grains trickling from it all
-- the while (the trickle, from 25% damage down); at 25% a crumbled hollow with a little heap of sand
-- piled under it.
function LOOKS.Sandstone(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.8, 1.5, 2.4 }, g.scale)
	local soft = c:Lerp(rgb(96, 70, 44), 0.55)
	for stage = 0, 3 do
		for _ = 1, stage == 0 and 1 or 2 do
			local u, v = near(rng, s, (0.15 + stage * 0.3) * g.scale)
			addDisc(specs, stage, g, u, v, rng:NextNumber(0.3, 0.55) * (1 + stage * 0.25), LIFT, c:Lerp(BLACK, 0.25 + stage * 0.05), SMOOTH, nil,
				{ name = "CrackPit", pop = 0.4, detach = { size = Vector3.new(0.12, 0.12, 0.12), color = c, kind = "grain" } })
		end
	end
	local hollow = math.min(1.3 * math.sqrt(g.scale), g.hu, g.hv)
	addDisc(specs, 3, g, s.u, s.v, hollow, LIFT + 0.004, c:Lerp(BLACK, 0.45), SMOOTH, nil, { name = "CrackHollow", pop = 0.5 })
	addDisc(specs, 3, g, s.u + 0.08, s.v + 0.06, hollow * 0.7, LIFT + 0.008, c:Lerp(BLACK, 0.2), SMOOTH, nil, { name = "CrackHollow", pop = 0.5 })
	if g.side then
		-- The heap: grains that ran out of the hollow, piled at its foot.
		local foot = math.max(-g.hv + 0.2, s.v - hollow * 0.8)
		addBox(specs, 3, g, s.u, foot, Vector3.new(hollow * 0.8, 0.16, 0.22), 0, LIFT, c:Lerp(WHITE, 0.08), M.Sand, nil,
			{ name = "CrackHeap", slide = Vector3.new(0, 0.5, 0) })
		addBox(specs, 3, g, s.u, foot + 0.1, Vector3.new(hollow * 0.5, 0.12, 0.3), 0, LIFT, c:Lerp(WHITE, 0.08), M.Sand, nil,
			{ name = "CrackHeap", slide = Vector3.new(0, 0.5, 0) })
	end
	addDisplaced(specs, 3, g, rng, s, 3, hollow * 0.9, 0.5, M.Sandstone, c)
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(2, 3), jag = 0.35, fork = 0.18, width = 0.11, color = soft, transparency = 0.2,
		step = { 0.3, 0.5 }, name = "CrackCrumble", lip = c:Lerp(WHITE, 0.3) })
end

-- BASALT: it breaks into columns: a ring of hexagonal joints spreading out a ring per stage, a column
-- face sinking at 50%, and at 25% a column springs clean out, leaving a dark hexagonal socket.
function LOOKS.Basalt(rng, specs, s, g, c)
	local reach = reachOf({ 0.6, 1.4, 2.4, 3.4 }, g.scale)
	local r = 0.55 * math.sqrt(g.scale)
	addHex(specs, 2, g, s.u, s.v, r * 0.92, LIFT, 0.05, c:Lerp(BLACK, 0.3), M.Basalt, { name = "CrackColumn", slide = Vector3.new(0, 0, 0.15), pop = 1 })
	addHex(specs, 3, g, s.u, s.v, r * 0.9, LIFT + 0.06, 0.02, rgb(16, 16, 18), SMOOTH,
		{ name = "CrackSocket", detach = { size = Vector3.new(r * 1.6, r * 1.6, 0.9), color = c, kind = "column", life = 3 } })
	crackNet(rng, specs, s, g, reach, { cell = r * 1.7, jitter = 0.06, hex = true, width = 0.065, color = c:Lerp(BLACK, 0.7), name = "CrackJoint" })
end

-- LIMESTONE: chalky: mid-grey cracks each with a haze of white powder along them, and crumbly pale
-- pits; powder puffs off with every hit.
function LOOKS.Limestone(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.7, 2.6 }, g.scale)
	for stage = 0, 3 do
		for _ = 1, stage + 1 do
			local u, v = near(rng, s, (0.25 + stage * 0.35) * g.scale)
			addDisc(specs, stage, g, u, v, rng:NextNumber(0.4, 0.8) * math.sqrt(g.scale), LIFT - 0.004, rgb(248, 246, 240), SMOOTH, 0.45,
				{ name = "CrackPowder", pop = 0.3 })
		end
	end
	addChip(specs, 1, g, rng, s.u, s.v, 0.3, c, { inner = c:Lerp(WHITE, 0.45) })
	addCrater(specs, 3, g, rng, s, 1.2, c, { floor = c:Lerp(WHITE, 0.4), rim = c:Lerp(BLACK, 0.3) })
	addDisplaced(specs, 3, g, rng, s, 3, 1.2, 0.55, M.Limestone, c)
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 4), jag = 0.45, fork = 0.25, width = 0.06, color = c:Lerp(BLACK, 0.45),
		name = "CrackChalk" })
end

-- ROCK: rough, wide, jagged fractures that barely fork; at 50% a big angular chunk wedges out and at
-- 25% it breaks away, leaving a dark concave scar.
function LOOKS.Rock(rng, specs, s, g, c)
	local reach = reachOf({ 0.4, 1.1, 2.2, 3.4 }, g.scale)
	local big = math.min(1.4 * math.sqrt(g.scale), g.hu, g.hv)
	addWedge(specs, 2, g, s.u, s.v, Vector3.new(big, big * 0.8, 0.35), rng:NextNumber(0, 6), LIFT, c:Lerp(BLACK, 0.12), M.Rock, nil,
		{ name = "CrackSlab", slide = Vector3.new(0, 0, -0.3), pop = 1 })
	addBox(specs, 3, g, s.u, s.v, Vector3.new(big * 1.05, big * 0.85, 0.02), rng:NextNumber(0, 6), LIFT + 0.4, c:Lerp(BLACK, 0.6), SMOOTH, nil,
		{ name = "CrackScar", detach = { size = Vector3.new(big, big * 0.8, 0.6), color = c, kind = "chunk", life = 3 } })
	addBox(specs, 3, g, s.u + 0.1, s.v, Vector3.new(big * 0.7, big * 0.55, 0.03), rng:NextNumber(0, 6), LIFT + 0.42, c:Lerp(BLACK, 0.3), SMOOTH, nil,
		{ name = "CrackScar" })
	addDisplaced(specs, 3, g, rng, s, 3, big * 1.2, 0.7, M.Rock, c)
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(2, 3), jag = 0.75, fork = 0.12, width = 0.12, color = c:Lerp(BLACK, 0.7),
		step = { 0.4, 0.8 }, name = "CrackFissure" })
end

-- COBBLESTONE: it fails between its stones: the joints round the stones near the hit open and
-- darken ring by ring, a stone rises out of its bed, and at 25% one pops out, leaving its socket.
function LOOKS.Cobblestone(rng, specs, s, g, c)
	local reach = reachOf({ 0.7, 1.4, 2.3, 3.3 }, g.scale)
	local cell = 1.05
	-- The stone the hits landed on, and its neighbour.
	local su = math.floor(s.u / cell + 0.5) * cell
	local sv = math.floor(s.v / cell + 0.5) * cell
	addDisc(specs, 2, g, su, sv, cell * 0.85, LIFT, c:Lerp(WHITE, 0.08), M.Cobblestone, nil, { name = "CrackCobble", thickness = 0.28, slide = Vector3.new(0, 0, -0.2), pop = 1 })
	addDisc(specs, 3, g, su + cell, sv, cell * 0.82, LIFT, rgb(20, 18, 16), SMOOTH, nil,
		{ name = "CrackSocket", detach = { size = Vector3.new(cell * 0.8, cell * 0.8, cell * 0.6), color = c, kind = "cobble", life = 3 } })
	crackNet(rng, specs, s, g, reach, { cell = cell, jitter = 0.18, width = 0.09, color = c:Lerp(BLACK, 0.78), name = "CrackJoint" })
end

-- PEBBLE: every hit spits pebbles out of their bed, leaving dark round sockets that spread a ring per
-- stage; at 25% a bare patch of the matrix they were set in.
function LOOKS.Pebble(rng, specs, s, g, c)
	local counts = { [0] = 2, 3, 4, 5 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, (0.2 + stage * 0.4) * g.scale)
			local d = rng:NextNumber(0.2, 0.32)
			addDisc(specs, stage, g, u, v, d, LIFT, rgb(24, 22, 20), SMOOTH, nil,
				{ name = "CrackSocket", detach = { size = Vector3.new(d, d, d), color = c:Lerp(WHITE, rng:NextNumber(0, 0.2)), kind = "pebble" } })
		end
	end
	local patch = math.min(1.4 * math.sqrt(g.scale), g.hu, g.hv)
	addDisc(specs, 3, g, s.u, s.v, patch, LIFT - 0.004, c:Lerp(rgb(110, 100, 86), 0.6), M.Sand, nil, { name = "CrackMatrix", pop = 0.3 })
	local reach = reachOf({ 0.2, 0.6, 1.1, 1.7 }, g.scale)
	crackTree(rng, specs, s, g, reach, { rays = 2, jag = 0.6, fork = 0.1, width = 0.04, color = c:Lerp(BLACK, 0.6), step = { 0.2, 0.35 } })
end

-- PAVEMENT: paving slabs: the cracks run along the slab joints near the hit, one slab cracks
-- corner to corner, and at 50% / 25% its broken pieces tip up out of the ground.
function LOOKS.Pavement(rng, specs, s, g, c)
	local slab = 2
	local reach = reachOf({ 0.8, 1.6, 2.6, 3.6 }, g.scale)
	local joint = c:Lerp(BLACK, 0.65)
	local su, sv = math.floor(s.u / slab) * slab, math.floor(s.v / slab) * slab
	-- The slab the hits landed on: split corner to corner, its halves tipping.
	addLine(specs, 0, g, su, sv, su + slab, sv + slab, 0.07, joint, nil, { dist = 0, name = "CrackSplit" })
	addLine(specs, 1, g, su + slab * 0.5, sv, su + slab * 0.2, sv + slab * 0.6, 0.05, joint, nil, { dist = 0.4, name = "CrackSplit" })
	addHinged(specs, 2, g, su, sv + slab, 1, -1, slab * 0.9, slab * 0.5, 0.18, 0.12, c:Lerp(BLACK, 0.08), M.Pavement, { name = "CrackTipped" })
	addHinged(specs, 3, g, su + slab, sv, -1, 1, slab * 0.9, slab * 0.5, 0.18, 0.2, c:Lerp(BLACK, 0.12), M.Pavement, { name = "CrackTipped" })
	for i = -2, 2 do
		for j = -2, 2 do
			local u, v = su + i * slab, sv + j * slab
			local d1 = radial(s, u + slab / 2, v)
			local d2 = radial(s, u, v + slab / 2)
			local st1, st2 = stageAt(reach, d1), stageAt(reach, d2)
			if st1 then
				addLine(specs, st1, g, u, v, u + slab, v, 0.06, joint, nil, { dist = d1, name = "CrackJoint" })
			end
			if st2 then
				addLine(specs, st2, g, u, v, u, v + slab, 0.06, joint, nil, { dist = d2, name = "CrackJoint" })
			end
		end
	end
end

-- ASPHALT: alligator cracking: a fine net of black cracks spreading from the hit, loose stones
-- ravelling out of it, and at 25% a pothole with gravel in the bottom.
function LOOKS.Asphalt(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.6, 2.4 }, g.scale)
	local hole = math.min(1.1 * math.sqrt(g.scale), g.hu, g.hv)
	addDisc(specs, 3, g, s.u, s.v, hole, LIFT, rgb(14, 14, 16), SMOOTH, nil, { name = "CrackPothole", pop = 0.3 })
	for _ = 1, 5 do
		local u, v = near(rng, s, hole * 0.35)
		addBox(specs, 3, g, u, v, Vector3.new(0.14, 0.12, 0.1), rng:NextNumber(0, 3), LIFT + 0.02, rgb(120, 118, 112), M.Pebble, nil, { name = "CrackGravel" })
	end
	for stage = 1, 2 do
		for _ = 1, 3 do
			local u, v = near(rng, s, (0.4 + stage * 0.4) * g.scale)
			addBox(specs, stage, g, u, v, Vector3.new(0.12, 0.1, 0.06), rng:NextNumber(0, 3), LIFT, rgb(132, 128, 120), M.Pebble, nil,
				{ name = "CrackRavel", detach = { size = Vector3.new(0.1, 0.1, 0.1), color = rgb(120, 118, 112), kind = "grit" } })
		end
	end
	addDisplaced(specs, 3, g, rng, s, 4, hole * 0.95, 0.45, M.Asphalt, c)
	crackNet(rng, specs, s, g, reach, { cell = 0.6, jitter = 0.28, width = 0.045, color = rgb(10, 10, 12), name = "CrackAlligator", outerFlat = true })
end

-- CRACKED LAVA: its cracks GLOW, and glow hotter each stage (dark red, orange, then yellow-white,
-- in Neon); a hot core at the hit that swells into a molten pool with crust floating on it at 25%.
-- Embers drift up from it (the trickle).
function LOOKS.CrackedLava(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 1.0, 1.9, 3.0 }, g.scale)
	addDisc(specs, 1, g, s.u, s.v, 0.4 * math.sqrt(g.scale), LIFT, rgb(255, 138, 30), NEON, nil, { name = "CrackGlow", pop = 0.1 })
	local pool = math.min(1.2 * math.sqrt(g.scale), g.hu, g.hv)
	addDisc(specs, 3, g, s.u, s.v, pool, LIFT + 0.004, rgb(255, 214, 120), NEON, nil, { name = "CrackMolten", pop = 0.2 })
	for _ = 1, 3 do
		local u, v = near(rng, s, pool * 0.3)
		addBox(specs, 3, g, u, v, Vector3.new(0.3, 0.22, 0.04), rng:NextNumber(0, 3), LIFT + 0.01, rgb(26, 20, 18), M.Basalt, nil, { name = "CrackCrust" })
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 5), jag = 0.5, fork = 0.3, width = 0.08, color = rgb(214, 62, 16), material = NEON,
		name = "CrackGlowLine", flat = true })
end

-- SALT: cubic cleavage: cracks that turn only at right angles, pale and glassy; little cubes spring
-- out of it leaving square pits; at 25% a cluster of loose crystals standing proud.
function LOOKS.Salt(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.6, 2.5 }, g.scale)
	for stage = 0, 3 do
		for _ = 1, stage + 1 do
			local u, v = near(rng, s, (0.2 + stage * 0.3) * g.scale)
			local e = rng:NextNumber(0.15, 0.26)
			addBox(specs, stage, g, u, v, Vector3.new(e, e, 0.02), 0, LIFT, c:Lerp(BLACK, 0.3), SMOOTH, nil,
				{ name = "CrackCubePit", detach = { size = Vector3.new(e, e, e), color = c:Lerp(WHITE, 0.3), kind = "crystal" } })
		end
	end
	for _ = 1, 5 do
		local u, v = near(rng, s, 0.5 * g.scale)
		local e = rng:NextNumber(0.14, 0.24)
		addBox(specs, 3, g, u, v, Vector3.new(e, e, e), rng:NextNumber(-0.3, 0.3), LIFT, c:Lerp(WHITE, 0.45), M.Glass, 0.15,
			{ name = "CrackCrystal", reflect = 0.3, slide = Vector3.new(0, 0, -0.2), pop = 1 })
	end
	crackTree(rng, specs, s, g, reach, { rays = 4, jag = 1.2, fork = 0.2, width = 0.045, color = c:Lerp(WHITE, 0.5), transparency = 0.2,
		snap = math.pi / 2, step = { 0.2, 0.4 }, start = 0, name = "CrackCleave", flat = true })
end

-- ICE: struck ice crazes white: a crushed white bruise at the hit, straight white fractures shooting
-- out, and translucent fracture planes set down INTO the ice at angles; at 25% a piece gone.
local function iceLook(rng, specs, s, g, c, big)
	local reach = reachOf(big and { 0.6, 1.8, 3.2, 4.8 } or { 0.3, 1.0, 1.9, 3.0 }, g.scale)
	local white = rgb(244, 250, 255)
	addDisc(specs, 0, g, s.u, s.v, (big and 0.5 or 0.35) * math.sqrt(g.scale), LIFT, white, SMOOTH, 0.1, { name = "CrackBruise", pop = 0.2 })
	addDisc(specs, 1, g, s.u, s.v, (big and 1.0 or 0.7) * math.sqrt(g.scale), LIFT - 0.004, white, SMOOTH, 0.55, { name = "CrackBruise", pop = 0.2 })
	for stage = 1, 3 do
		for _ = 1, 2 do
			local u, v = near(rng, s, (0.3 + stage * 0.4) * g.scale)
			local a = rng:NextNumber(0, math.pi * 2)
			local plane = addHinged(specs, stage, g, u, v, math.cos(a), math.sin(a), rng:NextNumber(0.6, 1.2) * g.scale, rng:NextNumber(0.4, 0.8), 0.02,
				-rng:NextNumber(0.5, 0.9), c:Lerp(WHITE, 0.7), M.Glass, { name = "CrackPlane" })
			if plane then
				plane.transparency = 0.5
			end
		end
	end
	if big then
		-- Glacier: a crevasse, a long blue slot across the hit.
		local a = rng:NextNumber(0, math.pi)
		local len = math.min(3 * g.scale, g.hu * 1.6)
		addBox(specs, 3, g, s.u, s.v, Vector3.new(len, 0.28, 0.02), a, LIFT + 0.002, rgb(40, 110, 170), SMOOTH, nil, { name = "CrackCrevasse", pop = 0.05 })
	else
		addWedge(specs, 3, g, s.u, s.v, Vector3.new(0.8, 0.6, 0.06), rng:NextNumber(0, 6), LIFT, c:Lerp(rgb(120, 170, 210), 0.5), M.Glass, 0.3,
			{ name = "CrackShard", detach = { size = Vector3.new(0.4, 0.3, 0.06), color = c:Lerp(WHITE, 0.4), kind = "shard" } })
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(big and 3 or 5, big and 4 or 7), jag = 0.08, fork = big and 0.12 or 0.2,
		width = big and 0.07 or 0.04, color = white, transparency = 0.05, step = { 0.4, 0.7 }, name = "CrackFracture", flat = true, hair = 0.5 })
end
function LOOKS.Ice(rng, specs, s, g, c)
	iceLook(rng, specs, s, g, c, false)
end
function LOOKS.Glacier(rng, specs, s, g, c)
	iceLook(rng, specs, s, g, c, true)
end

-- GLASS: a spiderweb from each hit, its rings spreading each stage (BreakFx shatters it).
function LOOKS.Glass(rng, specs, s, g)
	local white = rgb(236, 244, 255)
	local reach = reachOf({ 0.25, 0.7, 1.4, 2.4 }, g.scale)
	addDisc(specs, 0, g, s.u, s.v, 0.14, LIFT, white, SMOOTH, 0.05, { name = "CrackImpact" })
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
			if not addLine(specs, stage, g, pu, pv, nu, nv, 0.03, white, 0.1, { dist = travelled, name = "CrackWeb", flat = true }) then
				break
			end
			pu, pv, travelled = nu, nv, travelled + step
		end
	end
	for stage, radius in ipairs({ 0.32, 0.75, 1.45 }) do
		for ray = 1, count do
			local a, b = angles[ray], angles[ray % count + 1]
			local r1, r2 = radius * g.scale * rng:NextNumber(0.9, 1.1), radius * g.scale * rng:NextNumber(0.9, 1.1)
			local middle = (a + (b < a and b + math.pi * 2 or b)) / 2
			local rm = (r1 + r2) / 2 * 0.92
			local u1, v1 = s.u + math.cos(a) * r1, s.v + math.sin(a) * r1
			local um, vm = s.u + math.cos(middle) * rm, s.v + math.sin(middle) * rm
			local u2, v2 = s.u + math.cos(b) * r2, s.v + math.sin(b) * r2
			addLine(specs, stage, g, u1, v1, um, vm, 0.022, white, 0.1, { dist = radius, name = "CrackWebRing", flat = true, branch = 1 })
			addLine(specs, stage, g, um, vm, u2, v2, 0.022, white, 0.1, { dist = radius, name = "CrackWebRing", flat = true, branch = 1 })
		end
	end
end

-- WOOD: splits running along the grain (the face's long way), opening further each stage and a second
-- and third beside the first; splinters of fresh wood sticking out; at 25% a board hanging loose.
function LOOKS.Wood(rng, specs, s, g, c, mat)
	local alongU = g.hu >= g.hv
	local reach = reachOf({ 0.4, 1.0, 2.0, 3.4 }, g.scale)
	local split = c:Lerp(BLACK, 0.75)
	local fresh = c:Lerp(rgb(226, 196, 150), 0.55)
	local counts = { [0] = 1, 1, 2, 2 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, 0.35 * g.scale)
			local azimuth = (alongU and 0 or math.pi / 2) + (rng:NextNumber() < 0.5 and 0 or math.pi) + rng:NextNumber(-0.5, 0.5)
			local tilt = rng:NextNumber(0.6, 1.15)
			local direction = Vector3.new(math.cos(azimuth) * math.sin(tilt), math.sin(azimuth) * math.sin(tilt), math.cos(tilt))
			addStick(specs, stage, g, u, v, direction, rng:NextNumber(0.35, 0.8) * math.sqrt(g.scale), rng:NextNumber(0.05, 0.09), fresh, mat,
				{ name = "CrackSplinter" })
		end
	end
	local grainHalf = alongU and g.hu or g.hv
	local length = math.min(2.4 * g.scale, grainHalf * 1.6)
	if length > 0.6 then
		local du, dv = alongU and (rng:NextNumber() < 0.5 and 1 or -1) or 0, alongU and 0 or -1
		local hu, hv = s.u - du * length * 0.4, s.v - dv * length * 0.4
		addHinged(specs, 3, g, math.clamp(hu, -g.hu, g.hu), math.clamp(hv, -g.hv, g.hv), du, dv, length, 0.55, 0.14,
			rng:NextNumber(0.14, 0.26), c:Lerp(BLACK, 0.1), mat, { name = "CrackBoard" })
	end
	-- 25%: the split opened wide, the pale core of the wood showing in it, fibres torn across it.
	local coreLength = math.min(2.4 * g.scale, (alongU and g.hu or g.hv) * 1.4)
	addBox(specs, 3, g, s.u, s.v, alongU and Vector3.new(coreLength, 0.26, 0.02) or Vector3.new(0.26, coreLength, 0.02), 0, LIFT + 0.004,
		c:Lerp(rgb(236, 214, 170), 0.7), mat, nil, { name = "CrackCore", pop = 0.1 })
	for k = -2, 2 do
		local fu, fv = s.u + (alongU and k * 0.35 or 0), s.v + (alongU and 0 or k * 0.35)
		addStick(specs, 3, g, fu, fv, Vector3.new(alongU and 0 or 1, alongU and 1 or 0, 0.5).Unit, 0.3, 0.03, fresh, mat, { name = "CrackFibre", lod = 1 })
	end
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
				if not addLine(specs, stage, g, pu, pv, nu, nv, width, split, nil, { dist = travelled, name = "CrackGrain", lip = fresh }) then
					break
				end
				pu, pv, travelled = nu, nv, travelled + step
			end
		end
	end
end

-- WOOD PLANKS: they give at the SEAMS between the planks: the seams nearest the hit open dark and
-- straight, nail heads show, and at 50% a plank end springs loose (swinging out on its far end, with a
-- bounce), another at 25%; splinters where it was hit.
function LOOKS.WoodPlanks(rng, specs, s, g, c, mat)
	local alongU = g.hu >= g.hv
	local plank = 1
	local reach = reachOf({ 0.6, 1.4, 2.4, 3.4 }, g.scale)
	local seam = c:Lerp(BLACK, 0.8)
	local fresh = c:Lerp(rgb(226, 196, 150), 0.55)
	local across = alongU and s.v or s.u
	local base = math.floor(across / plank) * plank
	for stage = 0, 2 do
		local u, v = near(rng, s, 0.25 * g.scale)
		local azimuth = (alongU and 0 or math.pi / 2) + (rng:NextNumber() < 0.5 and 0 or math.pi)
		addStick(specs, stage, g, u, v, Vector3.new(math.cos(azimuth) * 0.6, math.sin(azimuth) * 0.6, 0.8).Unit, rng:NextNumber(0.3, 0.6), 0.06,
			fresh, mat, { name = "CrackSplinter" })
	end
	-- The loose planks: the one hit, then its neighbour; hinged at the far end, the free end out.
	for k, stage in ipairs({ 2, 3 }) do
		local centre = base + plank / 2 + (k - 1) * plank * (rng:NextNumber() < 0.5 and 1 or -1)
		local sign = rng:NextNumber() < 0.5 and 1 or -1
		local length = math.min(2.6 * g.scale, (alongU and g.hu or g.hv) * 1.2)
		local hu = alongU and (s.u + sign * length * 0.7) or centre
		local hv = alongU and centre or (s.v + sign * length * 0.7)
		addHinged(specs, stage, g, math.clamp(hu, -g.hu, g.hu), math.clamp(hv, -g.hv, g.hv), alongU and -sign or 0, alongU and 0 or -sign,
			length, plank * 0.9, 0.12, rng:NextNumber(0.22, 0.34), c:Lerp(BLACK, 0.06), mat, { name = "CrackPlank" })
	end
	-- 25%: the plank that was hit split down its middle, its pale core showing.
	local ca = alongU and Vector3.new(math.min(2 * g.scale, g.hu * 1.2), 0.22, 0.02) or Vector3.new(0.22, math.min(2 * g.scale, g.hv * 1.2), 0.02)
	addBox(specs, 3, g, alongU and s.u or base + plank / 2, alongU and base + plank / 2 or s.v, ca, 0, LIFT + 0.004, c:Lerp(rgb(236, 214, 170), 0.7), mat, nil,
		{ name = "CrackCore", pop = 0.1 })
	-- Nail heads at the plank ends near the hit.
	for stage = 1, 2 do
		local u, v = near(rng, s, 0.9 * g.scale)
		addDisc(specs, stage, g, u, v, 0.12, LIFT, rgb(40, 38, 36), M.Metal, nil, { name = "CrackNail" })
	end
	-- The seams: straight along the grain, at every plank edge within reach, each stage one further.
	for j = -3, 3 do
		local line = base + j * plank
		local dist = math.abs(line - across)
		local stage = stageAt(reach, dist)
		if stage then
			local half = (1.2 + (3 - math.abs(j)) * 0.4) * g.scale
			local a1 = (alongU and s.u or s.v) - half
			local a2 = (alongU and s.u or s.v) + half
			local w = 0.07 * (1 - 0.15 * math.abs(j))
			if alongU then
				addLine(specs, stage, g, s.u, line, a1, line, w, seam, nil, { dist = dist, name = "CrackSeam" })
				addLine(specs, stage, g, s.u, line, a2, line, w, seam, nil, { dist = dist, name = "CrackSeam" })
			else
				addLine(specs, stage, g, line, s.v, line, a1, w, seam, nil, { dist = dist, name = "CrackSeam" })
				addLine(specs, stage, g, line, s.v, line, a2, w, seam, nil, { dist = dist, name = "CrackSeam" })
			end
		end
	end
end

-- METAL: a dent deepening ring by ring (each stage a wider ring under the last, shaded like a hollow);
-- bright scratches; bullet holes with bright rims from 50%; soot; at 25% an edge peeled back.
function LOOKS.Metal(rng, specs, s, g, c, mat)
	local root = math.sqrt(g.scale)
	local rings = { [0] = { 0.45, c:Lerp(WHITE, 0.15) }, { 0.8, c:Lerp(BLACK, 0.32) }, { 1.1, c:Lerp(BLACK, 0.2) }, { 1.4, c:Lerp(BLACK, 0.12) } }
	for stage = 0, 3 do
		addDisc(specs, stage, g, s.u, s.v, rings[stage][1] * root, LIFT + (3 - stage) * 0.008, rings[stage][2], mat, nil, { name = "CrackDent", pop = 0.1 })
	end
	local scratch = c:Lerp(WHITE, 0.55)
	local counts = { [0] = 1, 2, 2, 2 }
	for stage = 0, 3 do
		for _ = 1, counts[stage] do
			local u, v = near(rng, s, 1.2 * g.scale)
			local angle, length = rng:NextNumber(0, math.pi), rng:NextNumber(0.4, 1.3)
			addLine(specs, stage, g, u - math.cos(angle) * length / 2, v - math.sin(angle) * length / 2,
				u + math.cos(angle) * length / 2, v + math.sin(angle) * length / 2, 0.03, scratch, nil, { name = "CrackScratch", flat = true, lod = 2 })
		end
	end
	for _ = 1, 2 do
		local u, v = near(rng, s, 1.1 * g.scale)
		local d = rng:NextNumber(0.3, 0.5)
		addDisc(specs, 2, g, u, v, d, LIFT + 0.012, c:Lerp(WHITE, 0.35), mat, nil, { name = "CrackHoleRim" })
		addDisc(specs, 2, g, u, v, d * 0.55, LIFT + 0.02, rgb(12, 12, 14), SMOOTH, nil, { name = "CrackHole" })
	end
	addDisc(specs, 2, g, s.u, s.v, rng:NextNumber(1.4, 2.2) * root, LIFT - 0.008, rgb(26, 24, 22), SMOOTH, 0.3, { name = "CrackSoot" })
	for stage = 2, 3 do
		for _ = 1, 2 do
			local u, v = near(rng, s, 0.9 * g.scale)
			addBox(specs, stage, g, u, v, Vector3.new(rng:NextNumber(0.25, 0.5), rng:NextNumber(0.15, 0.3), 0.012), rng:NextNumber(0, 3), LIFT + 0.002,
				rgb(196, 200, 206), M.Metal, nil, { name = "CrackBareMetal", reflect = 0.25 })
		end
	end
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
		0.07, 0.45, c:Lerp(BLACK, 0.12), mat, { name = "CrackPeel" })
end

-- DIAMOND PLATE: it BUCKLES: a ridge pushes up along a line through the hit, two tread plates tenting
-- up and growing longer each stage; dents at the hit; at 25% a corner torn up and folded back.
function LOOKS.DiamondPlate(rng, specs, s, g, c, mat)
	local a = rng:NextNumber(0, math.pi)
	local du, dv = math.cos(a), math.sin(a)
	local nu, nv = -dv, du
	local lengths = { [0] = 0.6, 1.2, 1.9, 2.6 }
	for stage = 0, 3 do
		local len = lengths[stage] * math.sqrt(g.scale)
		local rise = 0.12 + stage * 0.07
		-- The two sides of the buckle, hinged at their outer edges and meeting on the ridge line.
		for _, side in ipairs({ 1, -1 }) do
			local w = 0.35 + stage * 0.08
			local spec = addHinged(specs, stage, g, s.u + nu * side * w, s.v + nv * side * w, -nu * side, -nv * side, w * 1.02, len, 0.05, rise,
				c:Lerp(BLACK, 0.05 + stage * 0.05), mat, { name = "CrackBuckle" })
			if spec then
				-- Its long side along the ridge.
				spec.size = Vector3.new(w * 1.02, len, 0.05)
			end
		end
		addDisc(specs, stage, g, s.u + du * rng:NextNumber(-0.4, 0.4), s.v + dv * rng:NextNumber(-0.4, 0.4), 0.35 + stage * 0.1, LIFT,
			c:Lerp(BLACK, 0.3), mat, nil, { name = "CrackDent" })
	end
	-- The torn corner.
	local cu, cv = (s.u >= 0 and 1 or -1), (s.v >= 0 and 1 or -1)
	local eu, ev = cu * (g.hu - 0.05), cv * (g.hv - 0.05)
	local size = math.min(1.2, g.hu, g.hv)
	addHinged(specs, 3, g, eu - cu * size, ev - cv * size * 0.3, cu, cv * 0.3, size, size, 0.06, 1.9, c:Lerp(BLACK, 0.1), mat, { name = "CrackTorn" })
	for _ = 1, 3 do
		local u, v = near(rng, s, 1.2 * g.scale)
		local ang, length = rng:NextNumber(0, math.pi), rng:NextNumber(0.4, 1)
		addLine(specs, 1, g, u - math.cos(ang) * length / 2, v - math.sin(ang) * length / 2, u + math.cos(ang) * length / 2,
			v + math.sin(ang) * length / 2, 0.025, c:Lerp(WHITE, 0.6), nil, { name = "CrackScratch", flat = true, lod = 2 })
	end
end

-- CORRODED METAL: rust flakes lift and fall away (they swing open, then fly off), orange rust blooms
-- spread from the hit, and it RUSTS THROUGH: small holes with ragged orange rims, merging into a hole
-- at 25%.
function LOOKS.CorrodedMetal(rng, specs, s, g, c, mat)
	local rust = rgb(150, 72, 30)
	for stage = 0, 3 do
		addDisc(specs, stage, g, s.u + rng:NextNumber(-0.2, 0.2), s.v + rng:NextNumber(-0.2, 0.2), (0.6 + stage * 0.45) * math.sqrt(g.scale), LIFT - 0.004,
			rust:Lerp(c, 0.3), SMOOTH, 0.35, { name = "CrackBloom", pop = 0.4 })
		for _ = 1, 2 do
			local u, v = near(rng, s, (0.4 + stage * 0.35) * g.scale)
			local ang = rng:NextNumber(0, math.pi * 2)
			addHinged(specs, stage, g, u, v, math.cos(ang), math.sin(ang), rng:NextNumber(0.2, 0.35), rng:NextNumber(0.15, 0.3), 0.03,
				rng:NextNumber(0.3, 0.7), rust:Lerp(BLACK, rng:NextNumber(0, 0.25)), SMOOTH,
				{ name = "CrackRustFlake", detach = stage >= 1 and { size = Vector3.new(0.28, 0.03, 0.22), color = rust, kind = "flake" } or nil })
		end
	end
	for stage = 1, 3 do
		for _ = 1, stage == 3 and 3 or 1 do
			local u, v = near(rng, s, 0.5 * g.scale)
			local d = rng:NextNumber(0.2, 0.35) + (stage - 1) * 0.12
			addDisc(specs, stage, g, u, v, d * 1.5, LIFT + 0.004, rust:Lerp(rgb(220, 120, 50), 0.4), SMOOTH, nil, { name = "CrackRustRim" })
			addDisc(specs, stage, g, u, v, d, LIFT + 0.008, rgb(10, 8, 8), SMOOTH, nil, { name = "CrackRustHole" })
		end
	end
	addDisc(specs, 3, g, s.u, s.v, 0.9 * math.sqrt(g.scale), LIFT + 0.012, rgb(8, 6, 6), SMOOTH, nil, { name = "CrackRustHole", pop = 0.3 })
	for stage = 2, 3 do
		local u, v = near(rng, s, 0.8 * g.scale)
		addDisc(specs, stage, g, u, v, rng:NextNumber(0.25, 0.4), LIFT + 0.006, rgb(170, 172, 176), M.Metal, nil, { name = "CrackBareMetal", reflect = 0.2 })
	end
end

-- FOIL: it CRUMPLES: crinkle lines (bright and dark pairs, folding zigzags) running out from the hit,
-- a jagged tear through it, and its torn edges curling up; at 25% a whole curl peeled back.
function LOOKS.Foil(rng, specs, s, g, c, mat)
	local reach = reachOf({ 0.3, 0.8, 1.5, 2.3 }, g.scale)
	local bright, dark = c:Lerp(WHITE, 0.7), c:Lerp(BLACK, 0.45)
	for ray = 1, 7 do
		local a = ray / 7 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local u, v, travelled = s.u, s.v, 0
		local zig = 1
		while travelled < reach[3] and not full(specs) do
			local step = rng:NextNumber(0.18, 0.3) * g.scale
			local heading = a + zig * 0.6
			zig = -zig
			local nu, nv = u + math.cos(heading) * step, v + math.sin(heading) * step
			local stage = stageAt(reach, travelled + step)
			if not stage then
				break
			end
			addLine(specs, stage, g, u, v, nu, nv, 0.035, (ray % 2 == 0) and bright or dark, nil, { dist = travelled, name = "CrackCrinkle", reflect = 0.4, flat = true })
			u, v, travelled = nu, nv, travelled + step
		end
	end
	local a = rng:NextNumber(0, math.pi)
	for _, side in ipairs({ 1, -1 }) do
		local u, v, travelled = s.u, s.v, 0
		while travelled < reach[2] and not full(specs) do
			local step = rng:NextNumber(0.15, 0.25) * g.scale
			local heading = a + (side < 0 and math.pi or 0) + rng:NextNumber(-0.5, 0.5)
			local nu, nv = u + math.cos(heading) * step, v + math.sin(heading) * step
			local stage = math.max(1, stageAt(reach, travelled + step) or 3)
			addLine(specs, stage, g, u, v, nu, nv, 0.08, rgb(20, 20, 22), nil, { dist = travelled, name = "CrackTear" })
			addHinged(specs, stage, g, nu, nv, -math.sin(heading), math.cos(heading), 0.22, step, 0.02, 0.9, bright, mat, { name = "CrackCurl", reflect = 0.3 })
			u, v, travelled = nu, nv, travelled + step
		end
	end
	for k = 0, 2 do
		addHinged(specs, 3, g, s.u + k * 0.12, s.v, math.cos(a + 1.2), math.sin(a + 1.2), 0.45 - k * 0.08, 0.7, 0.02, 0.9 + k * 0.6, c:Lerp(WHITE, 0.3), mat,
			{ name = "CrackCurl", reflect = 0.3 })
	end
end

-- LEAVES (LeafyGrass): twigs snapped and drooping out of the canopy, bare patches where the leaves
-- were stripped; leaves keep falling off it (the sweep) and the server browns it.
function LOOKS.LeafyGrass(rng, specs, s, g, c)
	local bark = rgb(92, 66, 42)
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
			addStick(specs, stage, g, u, v, direction, rng:NextNumber(0.5, 1.2) * math.sqrt(g.scale), 0.1, bark, M.Wood, { name = "CrackTwig" })
		end
	end
	for stage = 2, 3 do
		for _ = 1, 2 do
			local u, v = near(rng, s, 1.2 * g.scale)
			addBox(specs, stage, g, u, v, Vector3.new(rng:NextNumber(0.8, 1.5), rng:NextNumber(0.6, 1.2), 0.03) * g.scale,
				rng:NextNumber(0, math.pi), LIFT, c:Lerp(BLACK, 0.55), SMOOTH, nil, { name = "CrackBare", pop = 0.3 })
		end
	end
end

-- GRASS (turf, hedges): torn up to the soil: brown gouges with green tufts standing ragged round
-- their edges, clods thrown out of them, and at 25% a divot with its flap of turf peeled back.
local SOIL = rgb(92, 66, 44)
function LOOKS.Grass(rng, specs, s, g, c)
	for stage = 0, 3 do
		local u, v = s.u, s.v
		if stage > 0 then
			u, v = near(rng, s, (0.3 + stage * 0.35) * g.scale)
		end
		local d = (0.35 + stage * 0.15) * math.sqrt(g.scale)
		addDisc(specs, stage, g, u, v, d, LIFT, SOIL:Lerp(BLACK, 0.2), M.Ground, nil,
			{ name = "CrackGouge", pop = 0.3, detach = { size = Vector3.new(0.3, 0.26, 0.26), color = SOIL, kind = "clod" } })
		for k = 1, 3 do
			local a = k / 3 * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
			local tu, tv = u + math.cos(a) * d * 0.5, v + math.sin(a) * d * 0.5
			addStick(specs, stage, g, tu, tv, Vector3.new(math.cos(a) * 0.5, math.sin(a) * 0.5, 0.85).Unit, rng:NextNumber(0.2, 0.35), 0.05,
				c:Lerp(rgb(160, 200, 90), 0.2), M.Grass, { name = "CrackTuft" })
		end
	end
	local divot = math.min(1.3 * math.sqrt(g.scale), g.hu, g.hv)
	addBox(specs, 3, g, s.u, s.v, Vector3.new(divot, divot * 0.7, 0.03), rng:NextNumber(0, 3), LIFT + 0.01, SOIL:Lerp(BLACK, 0.35), M.Ground, nil,
		{ name = "CrackDivot", pop = 0.3 })
	addHinged(specs, 3, g, s.u - divot * 0.5, s.v + divot * 0.35, 1, 0.2, divot * 0.9, divot * 0.6, 0.12, 1.1, c, M.Grass, { name = "CrackTurfFlap" })
end

-- GROUND (earth): dry earth cracks into polygons (a net of dark cracks, cells a stud across), clods
-- break off and fall, and at 25% it SLUMPS: a scooped scar with the earth heaped at its foot.
function LOOKS.Ground(rng, specs, s, g, c)
	local reach = reachOf({ 0.5, 1.2, 2.0, 3.0 }, g.scale)
	for stage = 1, 3 do
		for _ = 1, 2 do
			local u, v = near(rng, s, (0.3 + stage * 0.3) * g.scale)
			local e = rng:NextNumber(0.25, 0.4)
			addBox(specs, stage, g, u, v, Vector3.new(e, e * 0.8, 0.02), rng:NextNumber(0, 3), LIFT, c:Lerp(BLACK, 0.45), SMOOTH, nil,
				{ name = "CrackClodPit", detach = { size = Vector3.new(e, e, e * 0.8), color = c:Lerp(BLACK, 0.1), kind = "clod" } })
		end
	end
	local scar = math.min(1.4 * math.sqrt(g.scale), g.hu, g.hv)
	addDisc(specs, 3, g, s.u, s.v, scar, LIFT, c:Lerp(BLACK, 0.4), M.Ground, nil, { name = "CrackSlump", pop = 0.5 })
	if g.side then
		local foot = math.max(-g.hv + 0.2, s.v - scar * 0.75)
		addBox(specs, 3, g, s.u, foot, Vector3.new(scar * 0.9, 0.3, 0.35), 0, LIFT, c:Lerp(WHITE, 0.05), M.Ground, nil,
			{ name = "CrackHeap", slide = Vector3.new(0, 0.6, 0) })
	end
	crackNet(rng, specs, s, g, reach, { cell = 0.95, jitter = 0.25, width = 0.07, color = c:Lerp(BLACK, 0.6), name = "CrackDry" })
end

-- SAND: it doesn't crack, it gives: soft round dimples in rings, and it SLUMPS: a fan of sand spilling
-- down the face and heaping at the bottom, bigger each stage, and grains running out of it all the
-- while (the trickle).
function LOOKS.Sand(rng, specs, s, g, c)
	for stage = 0, 3 do
		for _ = 1, stage == 0 and 1 or 2 do
			local u, v = s.u, s.v
			if stage > 0 then
				u, v = near(rng, s, (0.2 + stage * 0.35) * g.scale)
			end
			local d = (0.45 + stage * 0.12) * math.sqrt(g.scale)
			addDisc(specs, stage, g, u, v, d, LIFT - 0.004, c:Lerp(BLACK, 0.18), M.Sand, nil, { name = "CrackDimple", pop = 0.5 })
			addDisc(specs, stage, g, u, v, d * 0.62, LIFT, c:Lerp(BLACK, 0.3), M.Sand, nil, { name = "CrackDimple", pop = 0.5 })
		end
	end
	if g.side then
		for stage = 1, 3 do
			local w = (0.6 + stage * 0.4) * math.sqrt(g.scale)
			local foot = math.max(-g.hv + 0.15, s.v - 0.4 - stage * 0.35)
			addWedge(specs, stage, g, s.u, foot, Vector3.new(w, 0.35 + stage * 0.12, 0.3 + stage * 0.1), 0, LIFT, c:Lerp(WHITE, 0.06), M.Sand, nil,
				{ name = "CrackSlump", slide = Vector3.new(0, 0.7, 0) })
		end
	else
		addDisc(specs, 3, g, s.u, s.v, 1.6 * math.sqrt(g.scale), LIFT - 0.008, c:Lerp(BLACK, 0.12), M.Sand, nil, { name = "CrackSlump", pop = 0.6 })
	end
end

-- SNOW: clean round holes with blue shadows in them, soft grey-blue creases, clumps dropping off, and
-- at 25% a slab of snow sliding down off the face, the packed snow under it showing.
function LOOKS.Snow(rng, specs, s, g, c)
	local shadow = rgb(170, 190, 220)
	local reach = reachOf({ 0.3, 0.9, 1.7, 2.6 }, g.scale)
	for stage = 0, 3 do
		for _ = 1, stage == 0 and 1 or 2 do
			local u, v = s.u, s.v
			if stage > 0 then
				u, v = near(rng, s, (0.3 + stage * 0.3) * g.scale)
			end
			local d = rng:NextNumber(0.35, 0.55)
			addDisc(specs, stage, g, u, v, d, LIFT, shadow, SMOOTH, 0.15,
				{ name = "CrackSnowHole", detach = { size = Vector3.new(0.35, 0.3, 0.3), color = rgb(248, 250, 255), kind = "clump" } })
			addDisc(specs, stage, g, u - 0.03, v + 0.04, d * 0.6, LIFT + 0.004, shadow:Lerp(rgb(110, 140, 190), 0.4), SMOOTH, 0.2, { name = "CrackSnowHole" })
		end
	end
	local slab = math.min(1.8 * math.sqrt(g.scale), g.hu * 1.6)
	addBox(specs, 3, g, s.u, s.v - 0.3, Vector3.new(slab, slab * 0.5, 0.02), 0, LIFT, rgb(206, 214, 228), M.Snow, nil, { name = "CrackPacked", pop = 0.5 })
	addBox(specs, 3, g, s.u, s.v - 0.45, Vector3.new(slab * 0.95, slab * 0.45, 0.25), 0, LIFT + 0.02, c:Lerp(WHITE, 0.2), M.Snow, nil,
		{ name = "CrackSnowSlab", slide = Vector3.new(0, 0.9, 0), pop = 1 })
	crackTree(rng, specs, s, g, reach, { rays = 3, jag = 0.35, fork = 0.15, width = 0.09, color = shadow:Lerp(rgb(90, 110, 150), 0.3), transparency = 0.35,
		name = "CrackCrease", flat = true })
end

-- MUD: every hit SPLATS: a wet dark crater with a glossy rim, drips running down from it, and clods
-- thrown out of it; at 25% a deep splash crater.
function LOOKS.Mud(rng, specs, s, g, c)
	local wet = c:Lerp(BLACK, 0.45)
	for stage = 0, 3 do
		local u, v = s.u, s.v
		if stage > 0 then
			u, v = near(rng, s, (0.3 + stage * 0.3) * g.scale)
		end
		local d = (0.4 + stage * 0.1) * math.sqrt(g.scale)
		addDisc(specs, stage, g, u, v, d * 1.4, LIFT, c:Lerp(WHITE, 0.05), M.Mud, nil, { name = "CrackSplatRim", pop = 0.4, reflect = 0.25 })
		addDisc(specs, stage, g, u, v, d, LIFT + 0.004, wet, SMOOTH, nil,
			{ name = "CrackSplat", reflect = 0.35, detach = { size = Vector3.new(0.22, 0.2, 0.2), color = wet, kind = "drop" } })
		if g.side then
			for _ = 1, 2 do
				local du = rng:NextNumber(-d * 0.5, d * 0.5)
				local len = rng:NextNumber(0.3, 0.8)
				addBox(specs, stage, g, u + du, v - d * 0.4 - len / 2, Vector3.new(0.09, len, 0.04), 0, LIFT, wet, SMOOTH, nil,
					{ name = "CrackDrip", reflect = 0.35, slide = Vector3.new(0, len * 0.6, 0) })
			end
		end
	end
	addDisc(specs, 3, g, s.u, s.v, 1.3 * math.sqrt(g.scale), LIFT + 0.008, rgb(34, 24, 16), SMOOTH, nil, { name = "CrackSplat", reflect = 0.35, pop = 0.3 })
end

-- FABRIC: a tear through the cloth, lengthening each stage, frayed threads along it; at 25% a flap of
-- it hanging open.
function LOOKS.Fabric(rng, specs, s, g, c, mat)
	local reach = reachOf({ 0.3, 0.8, 1.5, 2.4 }, g.scale)
	local angle = g.side and math.pi / 2 + rng:NextNumber(-0.4, 0.4) or rng:NextNumber(0, math.pi)
	local dark, thread = c:Lerp(BLACK, 0.85), c:Lerp(WHITE, 0.3)
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
			if not addLine(specs, stage, g, pu, pv, nu, nv, 0.09 * (1 - 0.4 * travelled / reach[3]), dark, nil, { dist = travelled, name = "CrackTear" }) then
				break
			end
			local fray = heading + math.pi / 2
			addLine(specs, stage, g, nu - math.cos(fray) * 0.1, nv - math.sin(fray) * 0.1, nu + math.cos(fray) * 0.1,
				nv + math.sin(fray) * 0.1, 0.02, thread, nil, { dist = travelled, name = "CrackFray", flat = true, lod = 2 })
			pu, pv, travelled = nu, nv, travelled + step
		end
	end
	addHinged(specs, 3, g, s.u, s.v, -math.cos(angle), -math.abs(math.sin(angle)), 0.8 * g.scale, 0.6 * g.scale, 0.04, 0.35, c, mat, { name = "CrackFlap" })
end

-- LEATHER: clean SLASHES, not tears: a dark gash with the pale suede showing along both lips, scuffed
-- pale patches round it, and at 25% a puncture with its flap curled back and the stitching torn.
function LOOKS.Leather(rng, specs, s, g, c, mat)
	local suede = c:Lerp(rgb(214, 180, 140), 0.6)
	local dark = c:Lerp(BLACK, 0.8)
	for stage = 0, 3 do
		local a = rng:NextNumber(-0.6, 0.6) + (stage % 2) * 0.5
		local len = (0.5 + stage * 0.35) * math.sqrt(g.scale)
		local u, v = s.u, s.v
		if stage > 0 then
			u, v = near(rng, s, 0.4 * g.scale)
		end
		local du, dv = math.cos(a) * len / 2, math.sin(a) * len / 2
		addLine(specs, stage, g, u - du, v - dv, u + du, v + dv, 0.07, dark, nil, { name = "CrackSlash", widen = false, flat = true })
		local ou, ov = -math.sin(a) * 0.06, math.cos(a) * 0.06
		addLine(specs, stage, g, u - du * 0.9 + ou, v - dv * 0.9 + ov, u + du * 0.9 + ou, v + dv * 0.9 + ov, 0.03, suede, nil, { name = "CrackSuede", widen = false, flat = true })
		addLine(specs, stage, g, u - du * 0.9 - ou, v - dv * 0.9 - ov, u + du * 0.9 - ou, v + dv * 0.9 - ov, 0.03, suede, nil, { name = "CrackSuede", widen = false, flat = true })
		addBox(specs, stage, g, u, v, Vector3.new(len * 0.8, 0.3, 0.01), a, LIFT - 0.004, suede, SMOOTH, 0.55, { name = "CrackScuff", pop = 0.5 })
	end
	addDisc(specs, 3, g, s.u, s.v, 0.5, LIFT + 0.004, rgb(14, 10, 8), SMOOTH, nil, { name = "CrackPuncture" })
	addHinged(specs, 3, g, s.u + 0.25, s.v, 1, 0.3, 0.4, 0.35, 0.05, 1.3, suede, mat, { name = "CrackFlap" })
	for k = -2, 2 do
		addLine(specs, 3, g, s.u + k * 0.18 - 0.05, s.v - 0.55, s.u + k * 0.18 + 0.05, s.v - 0.5, 0.025, rgb(220, 210, 190), nil, { name = "CrackStitch", flat = true })
	end
end

-- CARPET: tufts torn up standing proud, bald patches down to the woven backing (a pale grid), and at
-- 25% a flap of it pulled up from its backing.
function LOOKS.Carpet(rng, specs, s, g, c, mat)
	local backing = rgb(206, 194, 168)
	for stage = 0, 3 do
		for _ = 1, 3 do
			local u, v = near(rng, s, (0.2 + stage * 0.35) * g.scale)
			addStick(specs, stage, g, u, v, Vector3.new(rng:NextNumber(-0.3, 0.3), rng:NextNumber(-0.3, 0.3), 1).Unit, rng:NextNumber(0.15, 0.3), 0.06,
				c:Lerp(WHITE, 0.1), mat, { name = "CrackTuft" })
		end
		if stage >= 1 then
			local u, v = near(rng, s, 0.5 * g.scale)
			local w = (0.4 + stage * 0.2) * math.sqrt(g.scale)
			addBox(specs, stage, g, u, v, Vector3.new(w, w * 0.8, 0.02), rng:NextNumber(0, 1), LIFT, backing, M.Fabric, nil, { name = "CrackBacking", pop = 0.3 })
			for k = -1, 1 do
				addLine(specs, stage, g, u - w * 0.4, v + k * w * 0.25, u + w * 0.4, v + k * w * 0.25, 0.018, backing:Lerp(BLACK, 0.3), nil,
					{ name = "CrackWeave", lift = LIFT + 0.02, widen = false, flat = true, lod = 2 })
			end
		end
	end
	addHinged(specs, 3, g, s.u - 0.5, s.v, 1, 0, 1.1 * math.sqrt(g.scale), 0.8, 0.12, 0.6, c, mat, { name = "CrackFlap" })
end

-- CARDBOARD: it CREASES: straight fold lines, each a bright ridge beside a dark valley, a crumpled dent
-- at the hit, and a tear that shows the corrugation inside; at 25% a flap folded right open.
function LOOKS.Cardboard(rng, specs, s, g, c, mat)
	local ridge, valley = c:Lerp(WHITE, 0.35), c:Lerp(BLACK, 0.5)
	for stage = 0, 3 do
		local a = rng:NextNumber(0, math.pi)
		local len = (0.8 + stage * 0.5) * g.scale
		local du, dv = math.cos(a) * len / 2, math.sin(a) * len / 2
		local ou, ov = -math.sin(a) * 0.035, math.cos(a) * 0.035
		addLine(specs, stage, g, s.u - du + ou, s.v - dv + ov, s.u + du + ou, s.v + dv + ov, 0.04, ridge, nil, { name = "CrackCrease", widen = false, flat = true })
		addLine(specs, stage, g, s.u - du - ou, s.v - dv - ov, s.u + du - ou, s.v + dv - ov, 0.04, valley, nil, { name = "CrackCrease", widen = false, flat = true })
	end
	addDisc(specs, 0, g, s.u, s.v, 0.4, LIFT - 0.004, valley, SMOOTH, 0.3, { name = "CrackDentMark" })
	local a = rng:NextNumber(0, math.pi)
	local tear = 0.9 * math.sqrt(g.scale)
	addBox(specs, 2, g, s.u, s.v, Vector3.new(tear, 0.3, 0.02), a, LIFT, rgb(60, 44, 28), SMOOTH, nil, { name = "CrackTear", pop = 0.1 })
	for k = -3, 3 do
		local t = k / 3 * tear * 0.45
		addRod(specs, 2, g, s.u + math.cos(a) * t - math.sin(a) * 0.13, s.v + math.sin(a) * t + math.cos(a) * 0.13,
			s.u + math.cos(a) * t + math.sin(a) * 0.13, s.v + math.sin(a) * t - math.cos(a) * 0.13, LIFT + 0.04, 0.05, c:Lerp(WHITE, 0.2), M.Cardboard,
			{ name = "CrackCorrugation" })
	end
	addHinged(specs, 3, g, s.u, s.v + 0.15, math.cos(a + 1.5), math.sin(a + 1.5), 0.9 * g.scale, 0.8 * g.scale, 0.05, 2.2, c, mat, { name = "CrackFold" })
end

-- RUBBER: it doesn't crack, it GOUGES: grooves dug out of it with pale torn rims, a chunk torn out,
-- and at 25% a deep gash with stretched strands across it.
function LOOKS.Rubber(rng, specs, s, g, c, mat)
	local torn = c:Lerp(WHITE, 0.3)
	for stage = 0, 3 do
		local a = rng:NextNumber(0, math.pi)
		local len = (0.4 + stage * 0.25) * math.sqrt(g.scale)
		local u, v = s.u, s.v
		if stage > 0 then
			u, v = near(rng, s, 0.5 * g.scale)
		end
		addBox(specs, stage, g, u, v, Vector3.new(len, 0.16, 0.03), a, LIFT, c:Lerp(BLACK, 0.55), SMOOTH, nil,
			{ name = "CrackGouge", pop = 0.2, detach = { size = Vector3.new(0.2, 0.15, 0.15), color = c, kind = "crumb" } })
		addBox(specs, stage, g, u - math.sin(a) * 0.1, v + math.cos(a) * 0.1, Vector3.new(len * 0.9, 0.04, 0.05), a, LIFT, torn, mat, nil, { name = "CrackTornRim" })
	end
	local gash = 1.2 * math.sqrt(g.scale)
	local a = rng:NextNumber(0, math.pi)
	addBox(specs, 3, g, s.u, s.v, Vector3.new(gash, 0.35, 0.02), a, LIFT + 0.005, rgb(10, 10, 10), SMOOTH, nil, { name = "CrackGash", pop = 0.1 })
	for k = -2, 2 do
		local t = k / 2 * gash * 0.35
		addRod(specs, 3, g, s.u + math.cos(a) * t - math.sin(a) * 0.2, s.v + math.sin(a) * t + math.cos(a) * 0.2,
			s.u + math.cos(a) * t + math.sin(a) * 0.2, s.v + math.sin(a) * t - math.cos(a) * 0.2, LIFT + 0.04, 0.03, c, mat, { name = "CrackStrand" })
	end
end

-- PLASTER: fine map-like cracks, then flakes of it fall away (they come off as flying flakes) to show
-- what is under it: wooden lath on a thin wall, brick on a thick one; at 25% a wide bare patch.
function LOOKS.Plaster(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.8, 2.8 }, g.scale)
	local thick = g.depth >= 0.45
	for stage = 1, 3 do
		local w, h = (0.5 + stage * 0.4) * g.scale, (0.4 + stage * 0.3) * g.scale
		local u, v = s.u + rng:NextNumber(-0.1, 0.1), s.v + rng:NextNumber(-0.1, 0.1)
		addBox(specs, stage, g, u, v, Vector3.new(w, h, 0.02), rng:NextNumber(-0.2, 0.2), LIFT, thick and rgb(150, 82, 62) or rgb(118, 86, 58), SMOOTH, nil,
			{ name = "CrackUnder", pop = 0.7, detach = { size = Vector3.new(w * 0.6, 0.06, h * 0.6), color = c, kind = "flake" } })
		if thick then
			for row = -1, 1 do
				addLine(specs, stage, g, u - w * 0.45, v + row * 0.35, u + w * 0.45, v + row * 0.35, 0.05, rgb(200, 196, 186), nil,
					{ name = "CrackMortar", lift = LIFT + 0.02, widen = false, flat = true })
			end
		else
			for row = -1, 1 do
				addBox(specs, stage, g, u, v + row * 0.3, Vector3.new(w * 0.9, 0.18, 0.04), 0, LIFT + 0.02, rgb(150, 110, 70), M.Wood, nil, { name = "CrackLath" })
			end
		end
		addBox(specs, stage, g, u, v, Vector3.new(w + 0.14, h + 0.12, 0.02), rng:NextNumber(-0.2, 0.2), LIFT - 0.004, c:Lerp(BLACK, 0.35), SMOOTH, nil,
			{ name = "CrackPlasterEdge" })
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 5), jag = 0.7, fork = 0.35, width = 0.04, color = c:Lerp(BLACK, 0.5),
		step = { 0.2, 0.35 }, name = "CrackCraze", hair = 0.5 })
end

-- CERAMIC TILES: the tile that was hit cracks star-wise, the cracks run on along the GROUT between
-- tiles, and tiles pop off (flying as tiles), leaving grey adhesive with its trowel ridges.
function LOOKS.CeramicTiles(rng, specs, s, g, c)
	local tile = 1.2
	local grout = c:Lerp(BLACK, 0.55)
	local reach = reachOf({ 0.8, 1.5, 2.4, 3.4 }, g.scale)
	local tu, tv = math.floor(s.u / tile) * tile + tile / 2, math.floor(s.v / tile) * tile + tile / 2
	for ray = 1, 5 do
		local a = ray / 5 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		addLine(specs, 0, g, s.u, s.v, s.u + math.cos(a) * tile * 0.55, s.v + math.sin(a) * tile * 0.55, 0.03, c:Lerp(BLACK, 0.7), nil,
			{ name = "CrackTileStar", dist = 0 })
	end
	local adhesive = rgb(150, 150, 146)
	for k, stage in ipairs({ 2, 3, 3 }) do
		local ou = (k == 1) and 0 or ((k == 2) and tile or -tile)
		local u, v = tu + ou, tv
		addBox(specs, stage, g, u, v, Vector3.new(tile * 0.94, tile * 0.94, 0.02), 0, LIFT, adhesive, M.Concrete, nil,
			{ name = "CrackTileGone", detach = { size = Vector3.new(tile * 0.9, tile * 0.9, 0.08), color = c, kind = "tile", life = 2.5 } })
		for r = -2, 2 do
			addLine(specs, stage, g, u - tile * 0.42, v + r * 0.18, u + tile * 0.42, v + r * 0.18, 0.03, adhesive:Lerp(BLACK, 0.3), nil,
				{ name = "CrackTrowel", lift = LIFT + 0.02, widen = false, flat = true, lod = 2 })
		end
	end
	for i = -3, 3 do
		for j = -3, 3 do
			local u, v = tu - tile / 2 + i * tile, tv - tile / 2 + j * tile
			local d1, d2 = radial(s, u + tile / 2, v), radial(s, u, v + tile / 2)
			local st1, st2 = stageAt(reach, d1), stageAt(reach, d2)
			if st1 then
				addLine(specs, st1, g, u, v, u + tile, v, 0.05, grout, nil, { dist = d1, name = "CrackGrout" })
			end
			if st2 then
				addLine(specs, st2, g, u, v, u, v + tile, 0.05, grout, nil, { dist = d2, name = "CrackGrout" })
			end
		end
	end
end

-- CLAY ROOF TILES: the tiles near the hit crack, SLIP down their course (sliding) and lift, dark gaps
-- opening above them onto the batten; at 25% one slides right off (flying off down the slope).
function LOOKS.ClayRoofTiles(rng, specs, s, g, c)
	local w, h = 1, 1.2
	local gap = rgb(40, 30, 26)
	local tu, tv = math.floor(s.u / w) * w + w / 2, math.floor(s.v / h) * h + h / 2
	local cells = { { 0, 0, 1 }, { 1, 0, 2 }, { -1, 1, 2 }, { 0, -1, 3 }, { 1, 1, 3 } }
	for _, cell in ipairs(cells) do
		local u, v, stage = tu + cell[1] * w, tv + cell[2] * h, cell[3]
		addBox(specs, stage, g, u, v + h * 0.4, Vector3.new(w * 0.9, 0.22, 0.02), 0, LIFT, gap, SMOOTH, nil, { name = "CrackBatten" })
		addBox(specs, stage, g, u, v - 0.18, Vector3.new(w * 0.92, h * 0.9, 0.16), 0, LIFT, c:Lerp(BLACK, 0.08), M.ClayRoofTiles, nil,
			{ name = "CrackSlipped", slide = Vector3.new(0, 0.3, -0.1), pop = 1 })
		addLine(specs, stage, g, u - w * 0.3, v + h * 0.2, u + w * 0.2, v - h * 0.3, 0.035, c:Lerp(BLACK, 0.6), nil, { name = "CrackTileCrack", lift = LIFT + 0.18 })
	end
	addBox(specs, 3, g, tu, tv, Vector3.new(w * 0.95, h * 0.95, 0.02), 0, LIFT + 0.17, gap, SMOOTH, nil,
		{ name = "CrackTileGone", detach = { size = Vector3.new(w * 0.9, 0.2, h * 0.9), color = c, kind = "tile", life = 3 } })
end

-- ROOF SHINGLES: the tabs near the hit CURL UP at their lower edges, then tear away (flying off),
-- showing the black felt under them; at 25% the felt itself torn.
function LOOKS.RoofShingles(rng, specs, s, g, c, mat)
	local w, h = 1, 0.6
	local felt = rgb(22, 22, 24)
	local tu, tv = math.floor(s.u / w) * w + w / 2, math.floor(s.v / h) * h + h / 2
	local cells = { { 0, 0, 0 }, { 1, 0, 1 }, { -1, 0, 1 }, { 0, 1, 2 }, { 1, -1, 2 }, { -1, 1, 3 }, { 0, -1, 3 } }
	for _, cell in ipairs(cells) do
		local u, v, stage = tu + cell[1] * w + (cell[2] % 2) * w / 2, tv + cell[2] * h, cell[3]
		addHinged(specs, stage, g, u - w * 0.45, v + h * 0.45, 0, -1, h * 0.9, w * 0.9, 0.05, 0.5, c:Lerp(BLACK, 0.05), mat, { name = "CrackCurl" })
		if stage >= 2 then
			addBox(specs, stage, g, u, v, Vector3.new(w * 0.92, h * 0.88, 0.02), 0, LIFT, felt, M.Fabric, nil,
				{ name = "CrackFelt", detach = { size = Vector3.new(w * 0.9, 0.05, h * 0.9), color = c, kind = "shingle" } })
		end
	end
	addLine(specs, 3, g, tu - 0.5, tv - 0.2, tu + 0.4, tv + 0.25, 0.06, rgb(90, 80, 70), nil, { name = "CrackFeltTear", flat = true })
end

-- PLASTIC: it goes stress-white: pale blooms where it bent, whitened cracks, chips, and at 25% a hole
-- with a raised pale lip.
function LOOKS.Plastic(rng, specs, s, g, c)
	local reach = reachOf({ 0.25, 0.7, 1.3, 2.2 }, g.scale)
	for stage = 0, 3 do
		addDisc(specs, stage, g, s.u + rng:NextNumber(-0.1, 0.1), s.v + rng:NextNumber(-0.1, 0.1), (0.4 + stage * 0.35) * math.sqrt(g.scale), LIFT - 0.004,
			c:Lerp(WHITE, 0.55), SMOOTH, 0.55, { name = "CrackBloom", pop = 0.4 })
	end
	addChip(specs, 0, g, rng, s.u, s.v, 0.16, c)
	for stage = 2, 3 do
		local cu, cv = near(rng, s, 0.8 * g.scale)
		addChip(specs, stage, g, rng, cu, cv, 0.22, c)
	end
	addDisc(specs, 3, g, s.u, s.v, 0.55, LIFT + 0.01, c:Lerp(WHITE, 0.45), SMOOTH, nil, { name = "CrackLip" })
	addDisc(specs, 3, g, s.u, s.v, 0.35, LIFT + 0.02, rgb(18, 18, 20), SMOOTH, nil, { name = "CrackHole" })
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(2, 3), jag = 0.3, fork = 0.15, width = 0.05, color = c:Lerp(WHITE, 0.5), name = "CrackWhitened", flat = true })
end

-- SMOOTH PLASTIC: hard and brittle: crisp straight dark cracks, a crazing of fine pale hairlines
-- round the hit, a clean scalloped chip with a glossy edge, and at 25% a sharp-edged chunk gone.
function LOOKS.SmoothPlastic(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.6, 2.5 }, g.scale)
	addDisc(specs, 0, g, s.u, s.v, 0.3, LIFT, c:Lerp(WHITE, 0.4), SMOOTH, nil, { name = "CrackConchoid", reflect = 0.4 })
	for stage = 1, 2 do
		local a = rng:NextNumber(0, math.pi)
		for k = -3, 3 do
			local o = k * 0.09
			local u, v = s.u - math.sin(a) * o, s.v + math.cos(a) * o
			addLine(specs, stage, g, u - math.cos(a) * 0.4, v - math.sin(a) * 0.4, u + math.cos(a) * 0.4, v + math.sin(a) * 0.4, 0.014,
				c:Lerp(WHITE, 0.6), 0.2, { name = "CrackCraze", widen = false, flat = true, lod = 2 })
		end
	end
	for k = 0, 2 do
		local a = k / 3 * math.pi * 2 + rng:NextNumber(0, 1)
		addWedge(specs, 3, g, s.u + math.cos(a) * 0.25, s.v + math.sin(a) * 0.25, Vector3.new(0.55, 0.4, 0.05), a, LIFT, c:Lerp(BLACK, 0.5), SMOOTH, nil,
			{ name = "CrackChunk", reflect = 0.3, detach = { size = Vector3.new(0.4, 0.3, 0.2), color = c, kind = "chip" } })
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(4, 6), jag = 0.06, fork = 0.1, width = 0.035, color = c:Lerp(BLACK, 0.65),
		step = { 0.4, 0.7 }, name = "CrackCrisp" })
end

-- NEON: it goes DARK where it cracks: black cracks, and dead patches spreading round the hit that
-- blink on and off (the flicker is on the patches: the neon itself is never touched); sparks now and
-- then from 50% (the trickle).
function LOOKS.Neon(rng, specs, s, g, c)
	local reach = reachOf({ 0.3, 0.9, 1.7, 2.6 }, g.scale)
	for stage = 0, 3 do
		for _ = 1, stage + 1 do
			local u, v = s.u, s.v
			if stage > 0 then
				u, v = near(rng, s, (0.25 + stage * 0.3) * g.scale)
			end
			addDisc(specs, stage, g, u, v, (0.35 + stage * 0.22) * math.sqrt(g.scale), LIFT - 0.004, rgb(14, 14, 16), SMOOTH, 0.15,
				{ name = "CrackDead", flicker = 0.15 + rng:NextNumber(0, 0.2) })
		end
	end
	crackTree(rng, specs, s, g, reach, { rays = rng:NextInteger(3, 4), jag = 0.4, fork = 0.25, width = 0.06, color = rgb(8, 8, 10), name = "CrackDeadLine", flat = true })
end

-- FORCE FIELD: the shield frays: bright hexagonal fault lines in its own colour spreading out, and a
-- torn edge round the hit that fizzes (flickers).
function LOOKS.ForceField(rng, specs, s, g, c)
	local reach = reachOf({ 0.5, 1.2, 2.0, 3.0 }, g.scale)
	local bright = c:Lerp(WHITE, 0.6)
	addDisc(specs, 2, g, s.u, s.v, 0.8 * math.sqrt(g.scale), LIFT, bright, NEON, 0.2, { name = "CrackFizz", flicker = 0.2 })
	addDisc(specs, 3, g, s.u, s.v, 1.3 * math.sqrt(g.scale), LIFT - 0.004, bright, NEON, 0.4, { name = "CrackFizz", flicker = 0.4 })
	crackNet(rng, specs, s, g, reach, { cell = 0.6, jitter = 0.02, hex = true, width = 0.045, color = bright, material = NEON, name = "CrackHexFault", flat = true })
end

--------------------------------------------------------------------------------
-- PROFILES: every Roblox part material: what it looks like failing (LOOKS), how it moves as it does
-- (`style`, `spread`: the whole stage's growth in seconds, `grow`: each piece's), what each hit
-- knocks off it (`burst`: its bits, its puff, sparks / glints / embers), what it trickles once badly
-- hurt (`trickle`, from 50%), its dust along a running crack (`trail`), and what a hit sounds like
-- (`layers`: two SoundConfig cues, a crack and a texture, each { cue, gain, delay }).
-- tools/crack_check.py holds every material to having one, and each looking like itself.
--------------------------------------------------------------------------------

local P = {}
local function profile(name, look, style, spread, grow, burst, layers, trickle, trail)
	P[name] = { look = LOOKS[look], style = style, spread = spread, grow = grow, burst = burst, layers = layers, trickle = trickle,
		trail = trail }
end
local DUST = rgb(180, 174, 164)
local function L(a, ga, b, gb)
	return { { a, ga, 0 }, { b, gb, 0.045 } }
end
profile("Concrete", "Concrete", "steps", 0.36, 0.08, { bit = "chip", count = 3, dust = DUST }, L("BreakStone", 0.5, "GoldCrumble", 0.3), { kind = "dust", color = DUST }, DUST)
profile("Brick", "Brick", "steps", 0.4, 0.09, { bit = "chip", count = 3, dust = rgb(172, 120, 98) }, L("BreakStone", 0.5, "GoldCrumble", 0.3), { kind = "dust", color = rgb(176, 128, 104) }, rgb(176, 128, 104))
profile("Marble", "Marble", "burst", 0.22, 0.06, { bit = "flake", count = 3, dust = rgb(240, 238, 234), glint = true }, L("CasingTink", 0.45, "BreakStone", 0.3), nil, rgb(244, 242, 238))
profile("Granite", "Granite", "steps", 0.3, 0.06, { bit = "crystal", count = 4, dust = rgb(170, 160, 158), glint = true }, L("BreakStone", 0.5, "CasingTink", 0.2), { kind = "dust", color = rgb(170, 164, 160) }, rgb(170, 164, 160))
profile("Slate", "Slate", "steps", 0.36, 0.1, { bit = "flake", count = 3, dust = rgb(96, 100, 108) }, L("GoldCrumble", 0.45, "FlairTap", 0.3), nil, rgb(110, 114, 120))
profile("Sandstone", "Sandstone", "slump", 0.5, 0.18, { bit = "grain", count = 5, dust = rgb(214, 186, 140) }, L("FootstepSand", 0.55, "GoldCrumble", 0.3), { kind = "grains", color = rgb(220, 190, 140) }, rgb(222, 196, 150))
profile("Basalt", "Basalt", "steps", 0.3, 0.08, { bit = "chip", count = 3, dust = rgb(90, 90, 94) }, L("BreakStone", 0.55, "FlairClank", 0.15), { kind = "dust", color = rgb(96, 96, 100) }, rgb(100, 100, 104))
profile("Limestone", "Limestone", "steps", 0.4, 0.12, { bit = "chip", count = 2, dust = rgb(250, 248, 240), puffSize = 1.6 }, L("GoldCrumble", 0.5, "BreakStone", 0.3), { kind = "dust", color = rgb(245, 243, 236) }, rgb(250, 248, 242))
profile("Rock", "Rock", "steps", 0.36, 0.1, { bit = "chunk", count = 3, dust = rgb(150, 140, 128) }, L("BreakStone", 0.6, "GoldCrumble", 0.35), { kind = "dust", color = rgb(160, 150, 138) }, rgb(160, 150, 138))
profile("Cobblestone", "Cobblestone", "steps", 0.4, 0.1, { bit = "pebble", count = 3, dust = rgb(160, 156, 150) }, L("FlairRattle", 0.45, "BreakStone", 0.35), nil, rgb(164, 160, 154))
profile("Pebble", "Pebble", "burst", 0.35, 0.07, { bit = "pebble", count = 5, dust = rgb(170, 164, 150) }, L("FlairPop", 0.45, "FlairRattle", 0.35), nil, nil)
profile("Pavement", "Pavement", "steps", 0.4, 0.1, { bit = "chip", count = 3, dust = rgb(176, 174, 168) }, L("BreakStone", 0.5, "GoldCrumble", 0.3), { kind = "dust", color = rgb(176, 174, 168) }, rgb(180, 178, 172))
profile("Asphalt", "Asphalt", "burst", 0.34, 0.08, { bit = "grit", count = 5, dust = rgb(70, 70, 72) }, L("GoldCrumble", 0.5, "BreakStone", 0.3), nil, rgb(80, 80, 82))
profile("CrackedLava", "CrackedLava", "burst", 0.36, 0.1, { bit = "chip", count = 2, embers = true }, L("Burn", 0.4, "SmokeHiss", 0.25), { kind = "embers", color = EMBER }, nil)
profile("Salt", "Salt", "steps", 0.25, 0.06, { bit = "crystal", count = 4, dust = rgb(250, 250, 250), glint = true }, L("CasingTink", 0.45, "GoldCrumble", 0.25), nil, rgb(252, 252, 252))
profile("Ice", "Ice", "race", 0.12, 0.05, { bit = "shard", count = 4, dust = rgb(235, 245, 255), glint = true }, L("Freeze", 0.35, "CasingTink", 0.35), nil, nil)
profile("Glacier", "Glacier", "race", 0.2, 0.07, { bit = "chunk", count = 3, dust = rgb(240, 248, 255), puffSize = 1.8, glint = true }, L("Freeze", 0.45, "BreakStone", 0.3), nil, rgb(244, 250, 255))
profile("Glass", "Glass", "web", 0.08, 0.04, { bit = "shard", count = 3, glint = true }, L("CasingTink", 0.5, "Shatter", 0.18), nil, nil)
profile("Wood", "Wood", "creep", 0.6, 0.28, { bit = "splinter", count = 3, dust = rgb(204, 176, 132) }, L("BreakWood", 0.5, "FlairKnock", 0.35), nil, nil)
profile("WoodPlanks", "WoodPlanks", "creep", 0.55, 0.25, { bit = "splinter", count = 3, dust = rgb(210, 184, 140) }, L("FlairKnock", 0.5, "BreakWood", 0.4), nil, nil)
profile("Metal", "Metal", "push", 0.18, 0.16, { sparks = true }, L("CasingTink", 0.5, "FlairClank", 0.35), nil, nil)
profile("DiamondPlate", "DiamondPlate", "push", 0.24, 0.2, { sparks = true, bit = "chip", count = 1 }, L("FlairClank", 0.5, "BreakMetal", 0.35), nil, nil)
profile("CorrodedMetal", "CorrodedMetal", "burst", 0.36, 0.12, { bit = "flake", count = 4, dust = rgb(160, 86, 44), fewSparks = true }, L("BreakMetal", 0.4, "GoldCrumble", 0.35), { kind = "rust", color = rgb(150, 76, 36) }, rgb(160, 86, 44))
profile("Foil", "Foil", "burst", 0.22, 0.06, { bit = "foil", count = 3, glint = true }, L("FlairTear", 0.45, "CasingTink", 0.25), nil, nil)
profile("Grass", "Grass", "burst", 0.3, 0.1, { bit = "tuft", count = 4, dust = rgb(118, 96, 64), clods = 2 }, L("FootstepGrass", 0.6, "BreakFoliage", 0.35), nil, rgb(120, 98, 68))
profile("LeafyGrass", "LeafyGrass", "burst", 0.3, 0.1, { bit = "leaf", count = 4 }, L("BreakFoliage", 0.55, "FootstepGrass", 0.3), nil, nil)
profile("Ground", "Ground", "slump", 0.45, 0.16, { bit = "clod", count = 3, dust = rgb(150, 120, 90) }, L("FootstepSand", 0.55, "GoldCrumble", 0.35), { kind = "dust", color = rgb(150, 122, 92) }, rgb(156, 126, 96))
profile("Sand", "Sand", "slump", 0.55, 0.22, { bit = "grain", count = 6, dust = rgb(226, 206, 160), spray = true }, L("FootstepSand", 0.65, "GoldCrumble", 0.2), { kind = "grains", color = rgb(226, 204, 156) }, rgb(228, 208, 164))
profile("Snow", "Snow", "slump", 0.45, 0.16, { bit = "clump", count = 3, dust = rgb(250, 252, 255), puffSize = 1.8 }, L("FootstepSand", 0.55, "FootstepGrass", 0.3), { kind = "snow", color = rgb(252, 252, 255) }, rgb(250, 252, 255))
profile("Mud", "Mud", "slump", 0.35, 0.12, { bit = "drop", count = 5, splash = true }, L("StickySquelch", 0.45, "HitSplat", 0.35), nil, nil)
profile("Fabric", "Fabric", "burst", 0.3, 0.1, { bit = "scrap", count = 2, dust = rgb(222, 216, 206) }, L("FlairTear", 0.45, "BreakFoliage", 0.25), nil, nil)
profile("Leather", "Leather", "burst", 0.25, 0.08, { bit = "scrap", count = 2 }, L("FlairTear", 0.4, "FlairTap", 0.35), nil, nil)
profile("Carpet", "Carpet", "burst", 0.35, 0.12, { bit = "tuft", count = 3, dust = rgb(200, 190, 176) }, L("FootstepGrass", 0.5, "FlairTear", 0.3), nil, nil)
profile("Cardboard", "Cardboard", "burst", 0.3, 0.1, { bit = "scrap", count = 3 }, L("FlairStamp", 0.45, "FlairTear", 0.35), nil, nil)
profile("Rubber", "Rubber", "push", 0.2, 0.14, { bit = "crumb", count = 3 }, L("FlairSqueak", 0.45, "FlairBounce", 0.35), nil, nil)
profile("Plaster", "Plaster", "steps", 0.4, 0.12, { bit = "flake", count = 3, dust = rgb(240, 236, 228), puffSize = 1.4 }, L("GoldCrumble", 0.5, "BreakStone", 0.3), { kind = "dust", color = rgb(236, 232, 224) }, rgb(242, 238, 230))
profile("CeramicTiles", "CeramicTiles", "steps", 0.3, 0.06, { bit = "tileShard", count = 3, glint = true, dust = rgb(210, 208, 204) }, L("FlairTap", 0.5, "CasingTink", 0.35), nil, rgb(214, 212, 208))
profile("ClayRoofTiles", "ClayRoofTiles", "slump", 0.4, 0.14, { bit = "chip", count = 3, dust = rgb(190, 110, 80) }, L("FlairRattle", 0.5, "BreakStone", 0.35), nil, rgb(196, 118, 88))
profile("RoofShingles", "RoofShingles", "burst", 0.35, 0.12, { bit = "grit", count = 4, dust = rgb(90, 88, 86) }, L("FlairRattle", 0.45, "FlairTear", 0.3), nil, nil)
profile("Plastic", "Plastic", "burst", 0.25, 0.08, { bit = "chip", count = 2 }, L("FlairTap", 0.5, "CasingTink", 0.3), nil, nil)
profile("SmoothPlastic", "SmoothPlastic", "web", 0.14, 0.05, { bit = "chip", count = 2, glint = true }, L("CasingTink", 0.5, "FlairTap", 0.35), nil, nil)
profile("Neon", "Neon", "flicker", 0.25, 0.08, { bit = "shard", count = 2, sparks = true }, L("Shock", 0.2, "FlairBuzz", 0.4), { kind = "sparks", color = rgb(255, 230, 160) }, nil)
profile("ForceField", "ForceField", "flicker", 0.25, 0.08, { motes = true }, L("Shock", 0.18, "FlairBuzz", 0.35), nil, nil)
local PROFILES = P

local function profileOf(material)
	return PROFILES[material.Name] or PROFILES.Plastic
end

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
local function siteSpecs(size, site, index, color, material)
	local g = faceOf(size, site.face)
	local s = { u = site.point:Dot(g.face.u), v = site.point:Dot(g.face.v) }
	g.s = s
	g.color = color
	local specs = {}
	profileOf(material).look(Random.new(seedOf(site, index)), specs, s, g, color, material)
	for order, spec in ipairs(specs) do
		spec.order = order
		-- Cracked lava's lines glow a stage hotter as it gets worse (the colour is set when drawn).
		if spec.kind == "CrackGlowLine" then
			spec.lava = true
		end
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
-- Flying bits: the chips, splinters, flakes, grains, pebbles, clods, tiles and leaves a hit knocks
-- off or a stage lets go of. Local physics, light and a little bouncy: they fall, bounce, settle,
-- and fade out over their last BIT_FADE seconds (debris, not the damaged part: #71 is about that).
--------------------------------------------------------------------------------

local bits = {}
local rng = Random.new()

local BIT_SIZES = {
	chip = function()
		local edge = rng:NextNumber(0.1, 0.26)
		return Vector3.new(edge, edge * rng:NextNumber(0.6, 1), edge * rng:NextNumber(0.6, 1))
	end,
	chunk = function()
		local edge = rng:NextNumber(0.25, 0.45)
		return Vector3.new(edge, edge * rng:NextNumber(0.6, 1), edge * rng:NextNumber(0.6, 1))
	end,
	splinter = function() return Vector3.new(0.05, 0.05, rng:NextNumber(0.3, 0.6)) end,
	leaf = function() return Vector3.new(rng:NextNumber(0.25, 0.4), 0.03, rng:NextNumber(0.2, 0.32)) end,
	shard = function() return Vector3.new(0.03, rng:NextNumber(0.1, 0.24), rng:NextNumber(0.08, 0.18)) end,
	flake = function() return Vector3.new(rng:NextNumber(0.18, 0.32), 0.03, rng:NextNumber(0.14, 0.26)) end,
	foil = function() return Vector3.new(rng:NextNumber(0.12, 0.22), 0.015, rng:NextNumber(0.1, 0.18)) end,
	scrap = function() return Vector3.new(rng:NextNumber(0.2, 0.34), 0.02, rng:NextNumber(0.14, 0.26)) end,
	grain = function()
		local e = rng:NextNumber(0.05, 0.09)
		return Vector3.new(e, e, e)
	end,
	grit = function()
		local e = rng:NextNumber(0.06, 0.12)
		return Vector3.new(e, e, e)
	end,
	crystal = function()
		local e = rng:NextNumber(0.08, 0.16)
		return Vector3.new(e, e, e)
	end,
	pebble = function()
		local e = rng:NextNumber(0.18, 0.3)
		return Vector3.new(e, e, e)
	end,
	clod = function()
		local e = rng:NextNumber(0.2, 0.34)
		return Vector3.new(e, e * 0.85, e * 0.9)
	end,
	clump = function()
		local e = rng:NextNumber(0.24, 0.4)
		return Vector3.new(e, e, e)
	end,
	drop = function()
		local e = rng:NextNumber(0.1, 0.18)
		return Vector3.new(e, e, e)
	end,
	crumb = function()
		local e = rng:NextNumber(0.1, 0.18)
		return Vector3.new(e, e * 0.7, e)
	end,
	tuft = function() return Vector3.new(0.05, rng:NextNumber(0.25, 0.4), 0.05) end,
	tileShard = function() return Vector3.new(rng:NextNumber(0.2, 0.34), 0.04, rng:NextNumber(0.16, 0.28)) end,
}
-- Round bits: pebbles, clods, drops, clumps and grains are balls.
local ROUND = { pebble = true, clod = true, drop = true, clump = true, grain = true, cobble = true }
local BIT_MATERIAL = { leaf = M.Grass, tuft = M.Grass, drop = M.Mud, clump = M.Snow, grain = M.Sand, foil = M.Foil,
	crystal = M.Glass, shard = M.Glass, pebble = M.Pebble, grit = M.Pebble }
local BOUNCY = PhysicalProperties.new(0.9, 0.4, 0.55)

local function spawnBit(kind, position, velocity, color, material, size, life)
	if #bits >= MAX_BITS then
		return nil
	end
	local wedge = kind == "shard" or kind == "tileShard"
	local piece = Instance.new(wedge and "WedgePart" or "Part")
	piece.Name = "CrackBit"
	if ROUND[kind] and not wedge then
		piece.Shape = Enum.PartType.Ball
	end
	piece.Size = size or (BIT_SIZES[kind] or BIT_SIZES.chip)()
	piece.CFrame = CFrame.new(position) * CFrame.Angles(rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3), rng:NextNumber(0, 6.3))
	piece.Color = color
	piece.Material = BIT_MATERIAL[kind] or material
	if kind == "shard" or kind == "crystal" then
		piece.Transparency = 0.3
	end
	piece.CanCollide = true
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.CustomPhysicalProperties = (kind == "crumb" or kind == "pebble") and BOUNCY or LIGHT
	piece.Parent = fxFolder
	piece.AssemblyLinearVelocity = velocity
	piece.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
	table.insert(bits, { part = piece, born = now(), life = life or BIT_LIFE, base = piece.Transparency,
		drift = kind == "leaf" or kind == "scrap" or kind == "foil" or kind == "flake" })
	return piece
end

-- One throwaway emitter burst off a surface: dust, sawdust, sparks, a glint, embers, a spray of sand,
-- a splash of mud, powder of snow, light motes. At most MAX_PUFFS alive at once.
local puffs = 0
local function puff(position, normal, color, kind, size, count)
	if puffs >= MAX_PUFFS then
		return nil
	end
	puffs += 1
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
	local n = 6
	if kind == "sparks" or kind == "embers" or kind == "motes" then
		emitter.Texture = SPARK_TEXTURE
		local hot = kind == "embers" and EMBER or (kind == "motes" and color or rgb(255, 226, 150))
		emitter.Color = ColorSequence.new(hot, kind == "motes" and color or rgb(255, 130, 40))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(kind == "embers" and 0.2 or 0.14, 0)
		emitter.Lifetime = NumberRange.new(kind == "embers" and 0.6 or 0.15, kind == "embers" and 1.2 or 0.35)
		emitter.Speed = NumberRange.new(kind == "sparks" and 12 or 3, kind == "sparks" and 24 or 7)
		emitter.SpreadAngle = Vector2.new(40, 40)
		emitter.Acceleration = Vector3.new(0, kind == "sparks" and -50 or 6, 0)
		n = kind == "sparks" and 12 or 10
	elseif kind == "glint" then
		emitter.Color = ColorSequence.new(rgb(235, 245, 255))
		emitter.LightEmission = 0.6
		emitter.Size = NumberSequence.new(0.18, 0)
		emitter.Lifetime = NumberRange.new(0.15, 0.3)
		emitter.Speed = NumberRange.new(4, 9)
		emitter.SpreadAngle = Vector2.new(50, 50)
	elseif kind == "spray" or kind == "splash" then
		-- Sand or mud thrown up in an arc that falls back.
		emitter.Texture = DUST_TEXTURE
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new(kind == "splash" and 0.22 or 0.14, kind == "splash" and 0.1 or 0.05)
		emitter.Lifetime = NumberRange.new(0.4, 0.8)
		emitter.Speed = NumberRange.new(8, 14)
		emitter.SpreadAngle = Vector2.new(35, 35)
		emitter.Acceleration = Vector3.new(0, -40, 0)
		n = 18
	else
		emitter.Texture = DUST_TEXTURE
		emitter.Color = ColorSequence.new(color)
		local big = size or 1
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3 * big), NumberSequenceKeypoint.new(1, 1.1 * big) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(2, 5)
		emitter.SpreadAngle = Vector2.new(35, 35)
		emitter.Acceleration = Vector3.new(0, -2, 0)
		emitter.Drag = 3
		emitter.Rotation = NumberRange.new(0, 360)
	end
	emitter.Parent = holder
	emitter:Emit(count or n)
	task.delay(1.4, function()
		puffs -= 1
		holder:Destroy()
	end)
	return holder
end

-- What a hit knocks off, by material (the profile's `burst`).
local SOIL = rgb(92, 66, 44)
local function hitBurst(material, position, normal, color, count)
	local burst = profileOf(material).burst
	if burst.sparks then
		puff(position, normal, color, "sparks")
	end
	if burst.fewSparks and rng:NextNumber() < 0.3 then
		puff(position, normal, color, "sparks")
	end
	if burst.embers then
		puff(position, normal, color, "embers")
	end
	if burst.motes then
		puff(position, normal, color:Lerp(WHITE, 0.4), "motes")
	end
	if burst.glint then
		puff(position, normal, color, "glint")
	end
	if burst.spray then
		puff(position, normal, burst.dust or color, "spray")
	elseif burst.splash then
		puff(position, normal, color:Lerp(BLACK, 0.4), "splash")
	elseif burst.dust then
		puff(position, normal, burst.dust, "dust", burst.puffSize)
	end
	local kind = burst.bit
	for _ = 1, kind and math.min((burst.count or 0) + count - 1, 6) or 0 do
		local spread = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.4, 1), rng:NextNumber(-1, 1))
		local soft = kind == "leaf" or kind == "scrap" or kind == "tuft"
		local speed = soft and rng:NextNumber(1, 3) or rng:NextNumber(5, 11)
		local tint = (kind == "leaf" or kind == "tuft") and color or color:Lerp(BLACK, rng:NextNumber(0, 0.2))
		spawnBit(kind, position + normal * 0.15, (normal + spread * 0.6).Unit * speed + Vector3.new(0, 2, 0), tint, material)
	end
	for _ = 1, burst.clods or 0 do
		local spread = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0, 1), rng:NextNumber(-1, 1))
		spawnBit("clod", position + normal * 0.15, (normal + spread * 0.5).Unit * rng:NextNumber(5, 9) + Vector3.new(0, 3, 0), SOIL, M.Ground)
	end
end

-- A hit's sound: the material's two layers, each with its own pitch jitter and a little volume
-- jitter, the second a beat behind. `loud` (a stage rising) plays them up.
local lastSound = {}

local function playLayers(material, position, loud)
	local p = profileOf(material)
	local played = 0
	for _, layer in ipairs(p.layers) do
		local cue, gain, delay = layer[1], layer[2], layer[3]
		if SoundConfig.Get(cue) then
			played += 1
			local volume = gain * rng:NextNumber(0.85, 1.12) * (loud and 1.6 or 1)
			if delay > 0 then
				task.delay(delay, function()
					Sfx.PlayAt(cue, position, 0.3, nil, volume)
				end)
			else
				Sfx.PlayAt(cue, position, 0.3, nil, volume)
			end
		end
	end
	return played
end

local function playHit(material, part, position)
	local clock = now()
	if lastSound[part] and clock - lastSound[part] < SOUND_GAP then
		return false
	end
	lastSound[part] = clock
	return playLayers(material, position, false) > 0
end

--------------------------------------------------------------------------------
-- Moving pieces: every animated piece is in `anims` until it arrives. One pass a frame, one
-- BulkMoveTo for all their frames.
--------------------------------------------------------------------------------

local anims = {}
local flickers = {}
local counts = { animating = 0, flickering = 0 }

-- Fast then slowing (the default arrival), and the even crawl of a split running along the grain.
local function easeOut(t)
	return 1 - (1 - t) ^ 3
end
local function crawl(t)
	return t ^ 0.9
end

-- 0 -> 1 with an overshoot that settles: a board springing loose, a dent pushing in.
local function spring(t)
	return 1 - math.cos(t * math.pi * 2.5) * math.exp(-4.5 * t)
end

-- Where a spec's piece is, at progress t (0 -> 1), in the face's frame, and its size.
local function poseAt(spec, t, size, style)
	if spec.line then
		local l = spec.line
		local k = style == "creep" and crawl(t) or easeOut(t)
		local shown = l.length * k
		local c, s = math.cos(l.angle), math.sin(l.angle)
		return CFrame.new(l.u + c * shown / 2, l.v + s * shown / 2, l.z) * CFrame.Angles(0, 0, l.angle),
			Vector3.new(math.max(0.02, shown + size.Y * 0.5 * t), size.Y, size.Z)
	elseif spec.swing then
		local w = spec.swing
		return hingeFrame(w.u, w.v, w.du, w.dv, w.length, w.thickness, w.angle * spring(t)), size
	elseif spec.slide then
		local k = style == "slump" and t * t * (3 - 2 * t) or easeOut(t)
		return CFrame.new(spec.slide * (1 - k)) * spec.frame, size
	else
		local from = spec.pop or 0.25
		local k = style == "push" and (from + (1 - from) * spring(t)) or (from + (1 - from) * easeOut(math.min(1, t * 1.15)))
		if spec.shape == Enum.PartType.Cylinder then
			return spec.frame, Vector3.new(size.X, size.Y * k, size.Z * k)
		end
		return spec.frame, Vector3.new(size.X * k, size.Y * k, size.Z)
	end
end

-- A piece's size at a stage and a level of detail: cracks widen as the stage rises, and far off
-- (lod 3) the main ones are drawn FAR_BOLD wider.
local function sizeFor(spec, stage, lod)
	local size = spec.size
	local wide = 1
	if spec.grow and stage > spec.stage then
		wide *= 1 + 0.35 * (stage - spec.stage)
	end
	if spec.core and lod == 3 then
		wide *= FAR_BOLD
	end
	if wide ~= 1 then
		size = Vector3.new(size.X, size.Y * wide, size.Z)
	end
	return size
end

local LAVA = { [0] = rgb(150, 26, 10), rgb(214, 62, 16), rgb(255, 138, 30), rgb(255, 214, 120) }

local function realize(part, faceFrame, spec, stage, lod)
	local piece = Instance.new(spec.class or "Part")
	-- CrackLine, CrackLip, CrackShade, CrackChip, CrackRebar, CrackFlake, CrackSeam, ...: what it is,
	-- for Explorer (and for tools/crack_check.py, which reads each material's look from these names).
	piece.Name = spec.kind
	if spec.shape and piece:IsA("Part") then
		piece.Shape = spec.shape
	end
	piece.Size = sizeFor(spec, stage, lod)
	piece.CFrame = part.CFrame * faceFrame * spec.frame
	piece.Color = spec.lava and LAVA[math.clamp(stage, 0, 3)] or spec.color
	piece.Material = spec.material or SMOOTH
	piece.Transparency = spec.transparency or 0
	if spec.reflect then
		piece.Reflectance = spec.reflect
	end
	piece.Anchored = true
	piece.CanCollide = false
	piece.CanQuery = false
	piece.CanTouch = false
	piece.CastShadow = false
	piece.Parent = fxFolder
	return piece
end

-- Starts a piece's arrival `delay` seconds from now (its bit flies, its trail puffs, when it starts).
local function animate(record, piece, spec, faceFrame, stage, delay, duration, world, normal, style, lod)
	if counts.animating >= MAX_ANIMATING then
		return false
	end
	counts.animating += 1
	local size = sizeFor(spec, stage, lod)
	local frame, startSize = poseAt(spec, 0, size, style)
	piece.CFrame = record.part.CFrame * faceFrame * frame
	piece.Size = startSize
	piece.Transparency = 1
	table.insert(anims, { piece = piece, spec = spec, face = faceFrame, record = record, size = size, start = now() + delay,
		duration = duration, transparency = spec.transparency or 0, world = world, normal = normal, style = style })
	return true
end

local function detachBit(record, spec, world, normal)
	local d = spec.detach
	if not d or not record.part.Parent then
		return
	end
	local speed = rng:NextNumber(3, 6)
	local spread = Vector3.new(rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.2, 0.6), rng:NextNumber(-0.5, 0.5))
	spawnBit(d.kind or "chip", world + normal * 0.2, (normal + spread).Unit * speed + Vector3.new(0, 2.5, 0), d.color or record.part.Color,
		record.part.Material, d.size, d.life)
end

local function stepAnims()
	if #anims == 0 then
		return
	end
	local clock = now()
	local moved, frames = {}, {}
	for index = #anims, 1, -1 do
		local a = anims[index]
		local piece = a.piece
		if not piece.Parent or not a.record.part.Parent then
			table.remove(anims, index)
			counts.animating -= 1
		elseif clock >= a.start then
			if not a.started then
				a.started = true
				piece.Transparency = a.transparency
				if a.spec.detach then
					detachBit(a.record, a.spec, a.world, a.normal)
				end
				if a.style == "push" and a.spec.kind == "CrackDent" and rng:NextNumber() < 0.5 then
					puff(a.world, a.normal, piece.Color, "sparks", nil, 6)
				end
			end
			local t = math.clamp((clock - a.start) / a.duration, 0, 1)
			local frame, size = poseAt(a.spec, t, a.size, a.style)
			if a.style == "flicker" and t < 1 then
				-- Neon and force fields blink as they crack.
				piece.Transparency = rng:NextNumber() < 0.45 and 1 or a.transparency
			end
			if t >= 1 then
				frame, size = a.spec.frame, a.size
				piece.Transparency = a.transparency
				table.remove(anims, index)
				counts.animating -= 1
				if a.trail then
					-- Dust thrown along the crack as it reaches here.
					local l = a.spec.line
					local tip = a.record.part.CFrame * a.face * Vector3.new(l.u + math.cos(l.angle) * l.length, l.v + math.sin(l.angle) * l.length, 0)
					puff(tip, a.normal, a.trail, "dust", 0.45, 3)
				end
			end
			piece.Size = size
			table.insert(moved, piece)
			table.insert(frames, a.record.part.CFrame * a.face * frame)
		end
	end
	if #moved > 0 then
		workspace:BulkMoveTo(moved, frames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

local flickerClock = 0
local function stepFlicker(dt)
	flickerClock += dt
	if flickerClock < 1 / FLICKER_HZ then
		return
	end
	flickerClock = 0
	for index = #flickers, 1, -1 do
		local f = flickers[index]
		if not f.piece.Parent then
			table.remove(flickers, index)
			counts.flickering -= 1
		else
			-- Mostly dark, now and then lit through for a frame or two: a dying tube.
			f.piece.Transparency = rng:NextNumber() < 0.22 and 0.85 or f.base
		end
	end
end

-- A white flash at the hit as ice and glacier fracture: a local disc that burns out in 0.18 s.
local function flash(world, normal, size)
	local disc = Instance.new("Part")
	disc.Name = "CrackFlash"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = Vector3.new(0.05, size, size)
	disc.CFrame = CFrame.lookAt(world + normal * 0.05, world + normal * 1.05) * CFrame.Angles(0, math.pi / 2, 0)
	disc.Color = WHITE
	disc.Material = NEON
	disc.Transparency = 0.1
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	disc.Parent = fxFolder
	TweenService:Create(disc, TweenInfo.new(0.18), { Transparency = 1, Size = Vector3.new(0.05, size * 2.2, size * 2.2) }):Play()
	task.delay(0.2, function()
		disc:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- The parts being drawn
--------------------------------------------------------------------------------

-- part -> record. Strong keys: every record is removed when its part goes (Destroying, the tag
-- coming off, or the sweep finding it out of the workspace).
local tracked = {}
local totals = { pieces = 0, built = 0, trickles = 0 }

local function unbuild(record)
	for _, piece in ipairs(record.pieces) do
		piece:Destroy()
	end
	totals.pieces -= #record.pieces
	record.pieces, record.pieceSites, record.pieceSpecs = {}, {}, {}
	record.shown, record.drawn = {}, {}
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

-- The emitter a badly hurt part keeps up (dust, sand grains, embers, sparks, rust flakes, snow).
local function trickle(record, profile, lowest, stage)
	local t = profile.trickle
	if not t or not lowest or totals.trickles >= MAX_TRICKLES then
		return
	end
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
	if t.kind == "embers" or t.kind == "sparks" then
		emitter.Texture = SPARK_TEXTURE
		emitter.Color = ColorSequence.new(t.color)
		emitter.LightEmission = 1
		emitter.EmissionDirection = t.kind == "embers" and Enum.NormalId.Top or Enum.NormalId.Bottom
		emitter.Size = NumberSequence.new(t.kind == "embers" and 0.18 or 0.12, 0)
		emitter.Lifetime = NumberRange.new(0.6, 1.4)
		emitter.Rate = t.kind == "embers" and (stage >= 3 and 8 or 4) or (stage >= 3 and 3 or 1.2)
		emitter.Speed = NumberRange.new(t.kind == "embers" and 1 or 4, t.kind == "embers" and 3 or 9)
		emitter.SpreadAngle = Vector2.new(25, 25)
		emitter.Acceleration = Vector3.new(0, t.kind == "embers" and 3 or -40, 0)
	else
		emitter.Texture = DUST_TEXTURE
		emitter.Color = ColorSequence.new(t.color)
		emitter.EmissionDirection = Enum.NormalId.Bottom
		local grains = t.kind == "grains" or t.kind == "rust" or t.kind == "snow"
		emitter.Size = grains and NumberSequence.new(0.1, 0.06)
			or NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 0.7) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, grains and 0.1 or 0.5), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(grains and 0.8 or 1.2, grains and 1.4 or 2)
		emitter.Rate = (grains and 10 or 2.5) * (stage >= 3 and 2 or 1)
		emitter.Speed = NumberRange.new(0.4, 1.2)
		emitter.SpreadAngle = Vector2.new(grains and 8 or 15, grains and 8 or 15)
		emitter.Acceleration = Vector3.new(0, grains and -25 or -3, 0)
		emitter.Drag = grains and 0 or 1
	end
	emitter.Parent = holder
	record.trickle = holder
	totals.trickles += 1
end

-- The level of detail for a part at `distance`, from the one it had (hysteresis).
local function lodFor(distance, current)
	local nearEdge = LOD_NEAR + ((current == 1) and LOD_SLACK or -LOD_SLACK)
	local farEdge = LOD_FAR + ((current == 3) and -LOD_SLACK or LOD_SLACK)
	if distance <= nearEdge then
		return 1
	elseif distance >= farEdge then
		return 3
	end
	return 2
end

-- When a new piece of this style starts, as a share of the stage's spread: steps jump in three,
-- a web's rays shoot out while its rings creep behind, everything else runs out with the distance.
local function startShare(style, share, spec)
	if style == "steps" then
		return math.floor(share * 3 + 0.5) / 3
	elseif style == "web" and spec.kind == "CrackWebRing" then
		return 1.5 + share * 4
	end
	return share
end

-- Draws what a part's sites show at its stage and level of detail, adding only what isn't drawn
-- yet. `play` (the stage rose or a site opened while the part is near): the new pieces grow in;
-- otherwise they appear finished (a late joiner, a part coming back into range, a change of detail).
local function build(part, record, play)
	if not record.built then
		record.built = true
		totals.built += 1
		record.cframe = part.CFrame
	end
	record.cache = record.cache or {}
	record.shown = record.shown or {}
	record.drawn = record.drawn or {}
	local profile = profileOf(part.Material)
	local stage = record.stage
	local lod = record.lod or 1
	local cframe = part.CFrame
	local lowest = nil
	local animated = play and record.distance and record.distance <= ANIMATE_WITHIN
	local trails = 0
	for index, site in ipairs(record.sites) do
		local cached = record.cache[index]
		if not cached then
			local specs, g = siteSpecs(part.Size, site, index, part.Color, part.Material)
			cached = { specs = specs, g = g, faceFrame = CFrame.fromMatrix(g.face.n * g.depth, g.face.u, g.face.v, g.face.n) }
			record.cache[index] = cached
		end
		local specs, faceFrame = cached.specs, cached.faceFrame
		local normal = cframe:VectorToWorldSpace(cached.g.face.n)
		local shown = record.shown[index] or 0
		-- Pieces already up: cracks widen, lava glows hotter, as the stage rises.
		for k, piece in ipairs(record.pieces) do
			local spec = record.pieceSpecs[k]
			if record.pieceSites[k] == index and spec and piece.Parent then
				if spec.grow then
					piece.Size = sizeFor(spec, stage, lod)
				end
				if spec.lava then
					piece.Color = LAVA[math.clamp(stage, 0, 3)]
				end
			end
		end
		-- The new pieces: those of stages now reached, at this level of detail, up to the caps.
		local fresh = {}
		local drawn = record.drawn[index] or { 0, 0 }
		for k = shown + 1, #specs do
			local spec = specs[k]
			if spec.stage > stage then
				break
			end
			shown = k
			local isLine = spec.line ~= nil
			if (spec.lod or 3) >= lod and drawn[1] + drawn[2] < PER_SITE_CAP and (not isLine or drawn[1] < PER_SITE_LINES)
				and totals.pieces + #fresh < MAX_PIECES then
				local slot = isLine and 1 or 2
				drawn[slot] += 1
				table.insert(fresh, spec)
			end
		end
		record.shown[index] = shown
		record.drawn[index] = drawn
		local lo, hi = math.huge, -math.huge
		for _, spec in ipairs(fresh) do
			lo, hi = math.min(lo, spec.dist or 0), math.max(hi, spec.dist or 0)
		end
		if animated and #fresh > 0 and profile.style == "race" then
			flash(cframe * site.point, normal, 1.6)
		end
		for _, spec in ipairs(fresh) do
			local piece = realize(part, faceFrame, spec, stage, lod)
			table.insert(record.pieces, piece)
			table.insert(record.pieceSites, index)
			table.insert(record.pieceSpecs, spec)
			totals.pieces += 1
			local world = cframe * (faceFrame * spec.frame).Position
			local moving = false
			if animated then
				local share = hi > lo and ((spec.dist or 0) - lo) / (hi - lo) or 0
				local delay = profile.spread * startShare(profile.style, share, spec) + (spec.branch or 0) * BRANCH_STAGGER
				local duration = profile.grow
				if spec.line then
					-- Lines take their length's time at the style's pace, within the grow.
					duration = math.clamp(spec.line.length * profile.grow, 0.04, profile.grow * 2.2)
				end
				if profile.style == "web" and spec.kind == "CrackWebRing" then
					duration = 0.25
				end
				moving = animate(record, piece, spec, faceFrame, stage, delay, duration, world, normal, profile.style, lod)
				if moving and profile.trail and spec.core and spec.branch == 0 and trails < 3 and rng:NextNumber() < 0.3 then
					trails += 1
					anims[#anims].trail = profile.trail
				end
			end
			if not moving and spec.detach and play and record.distance and record.distance <= BURST_DISTANCE then
				detachBit(record, spec, world, normal)
			end
			if spec.flicker and counts.flickering < MAX_FLICKER then
				counts.flickering += 1
				table.insert(flickers, { piece = piece, base = spec.transparency or 0 })
			end
		end
		if animated and #fresh > 0 and profile.style == "web" then
			-- Glass tinkles as it goes: a few shards off the new web.
			for _ = 1, 2 do
				spawnBit("shard", cframe * site.point + normal * 0.2, normal * rng:NextNumber(3, 6) + Vector3.new(0, 2, 0), rgb(220, 235, 245), M.Glass)
			end
		end
		local world = cframe * site.point
		if not lowest or world.Y < lowest.world.Y then
			lowest = { world = world, normal = normal }
		end
	end
	if stage >= 2 and not record.trickle then
		trickle(record, profile, lowest, stage)
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
	record = { part = part, pieces = {}, pieceSites = {}, pieceSpecs = {}, shown = {}, drawn = {}, sites = {}, stage = -1, built = false,
		dirty = true, lod = 1 }
	record.connection = part.Destroying:Connect(function()
		untrack(part)
	end)
	tracked[part] = record
	return record
end

-- Re-reads what the server has written for a part; marks it for a (partial) rebuild if anything
-- changed. `play` is set when the change should be seen happening (the stage rose, a site opened).
local function refresh(part, record)
	local text = part:GetAttribute(SITES_ATTRIBUTE)
	if text ~= record.text then
		local had = #record.sites
		record.text = text
		record.sites = parseSites(text)
		record.dirty = true
		if record.stage >= 0 and #record.sites > had then
			record.play = true
		end
	end
	local stage = stageOf(part)
	if stage ~= record.stage then
		if record.stage >= 0 and stage > record.stage then
			record.play = true
			record.rose = true
		end
		record.stage = stage
		record.dirty = true
	end
end

local LEAF_CHANCE = { [2] = 0.25, [3] = 0.5 }

-- Four times a second: drop what has gone, re-read what changed, and draw the nearest damaged parts
-- within reach (the farthest giving up theirs when the caps are reached), each at its detail.
local function sweep()
	local eye = camera and camera.CFrame.Position
	if not eye then
		return
	end
	local candidates = {}
	for part, record in pairs(tracked) do
		if not part.Parent or not part:IsDescendantOf(workspace) then
			untrack(part)
		elseif not part.Anchored then
			-- Coming down (a collapsing chunk): nothing drawn on it until it lies still again.
			if record.built then
				unbuild(record)
				record.cache = nil
			end
			record.play = false
		else
			if record.built and record.cframe and record.cframe ~= part.CFrame then
				-- It moved (it landed as rubble): drawn again where it lies, finished.
				unbuild(record)
				record.cache = nil
				record.dirty = true
				record.play = false
			end
			refresh(part, record)
			record.distance = math.max(0, (part.Position - eye).Magnitude - part.Size.Magnitude / 2)
			local lod = lodFor(record.distance, record.lod)
			if lod ~= record.lod then
				record.lod = lod
				if record.built then
					unbuild(record)
				end
				record.dirty = true
				record.play = false
			end
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
			build(record.part, record, record.built and record.play)
			record.dirty = false
			record.play = false
		end
		-- Leaves keep coming down off a tree that has been shot bare.
		local chance = LEAF_CHANCE[record.stage]
		if chance and record.built and record.part.Material == M.LeafyGrass and record.distance <= BURST_DISTANCE and rng:NextNumber() < chance then
			local site = record.sites[rng:NextInteger(1, #record.sites)]
			local at = record.part.CFrame * site.point
			spawnBit("leaf", at + Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)), Vector3.new(0, -1, 0), record.part.Color, M.Grass)
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
			record.lod = lodFor(math.max(0, distance - part.Size.Magnitude / 2), record.lod)
			if distance <= BURST_DISTANCE then
				if bursts < BURSTS_PER_EVENT then
					bursts += 1
					hitBurst(part.Material, world, part.CFrame:VectorToWorldSpace(FACES[face].n), part.Color,
						math.clamp(type(count) == "number" and count or 1, 1, 4))
				end
				if sounds < SOUNDS_PER_EVENT then
					if record.rose then
						-- A stage rising: its crack, louder.
						sounds += 1
						lastSound[part] = now()
						playLayers(part.Material, world, true)
					elseif playHit(part.Material, part, world) then
						sounds += 1
					end
				end
			end
			record.rose = false
			-- A new site or stage shows at once rather than at the next sweep, growing in.
			if record.dirty and #record.sites > 0 and part.Anchored and (record.built or (distance <= BUILD_WITHIN and totals.built < MAX_BUILT)) then
				build(part, record, record.play and record.stage >= 0)
				record.dirty = false
				record.play = false
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
	stepAnims()
	stepFlicker(dt)
	local clock = now()
	for index = #bits, 1, -1 do
		local bit = bits[index]
		local piece = bit.part
		local age = clock - bit.born
		if not piece.Parent or age > bit.life or piece.Position.Y < -500 then
			piece:Destroy()
			table.remove(bits, index)
		else
			if age > bit.life - BIT_FADE then
				-- Settled: it fades out where it lies.
				piece.Transparency = bit.base + (1 - bit.base) * (age - (bit.life - BIT_FADE)) / BIT_FADE
			end
			if bit.drift then
				local velocity = piece.AssemblyLinearVelocity
				if velocity.Y < -3 then
					-- Air under a leaf, a flake, a scrap: it flutters down rather than drops.
					piece.AssemblyLinearVelocity = Vector3.new(velocity.X * 0.96, -3, velocity.Z * 0.96)
				end
			end
		end
	end
end)
