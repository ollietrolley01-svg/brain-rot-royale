-- Shooting the map apart: walls, floors, roofs, the props inside buildings, and the things standing
-- about the map (trees, rocks, wrecks, shelters, parked cars, benches, street furniture) take damage
-- and break, so cover is something you wear down rather than something permanent.
--
--   DestructibleService.FromPart(part)              the part if it can be broken, or nil
--   DestructibleService.Damage(part, amount, by)    hurt it (or the pool it belongs to); breaks at zero
--   DestructibleService.DamageInRadius(...)         splash from a blast: each pool once per blast
--   DestructibleService.Count()                     how many are damaged but still standing
--
-- Registered with CombatService at load the way defenses and hazards are, so bullets find it.
--
-- WHAT CAN BREAK. Two ways in, both decided when the map is built and neither a registry:
--
--   by name   a building's own Wall, Floor, Roof... (HEALTH below): health per PART, so a house is
--             250 a wall rather than one pool for the whole building
--   by tag    the attribute `Destructible`, set by the map modules on what they build:
--               "Kind"        on a Model: the whole Model is one pool (a TownThemes street prop)
--               "Kind"        on a part: that part alone
--               "Kind:id"     on parts: every sibling with the same string is one pool, so a tree's
--                             trunk and its leaves go together (MapDecor, MapWilds, Landmarks group
--                             each thing they build this way, since their parts share one parent)
--               false         never, whatever its name says (the ground floor of a building)
--             `DestructibleHealth` (a number) beside it overrides the health rule below; on its
--             own, a positive number marks the Model (one pool) or part it is on as breakable with
--             exactly that health (#51: MapDecor's ParkedCar Models carry 240).
--
-- A tagged pool's health comes from its size and what it is made of (poolHealth), times its kind's
-- toughness (KINDS), found on its first hit. Nothing is tracked until someone shoots it, and an
-- entry dies with the part it hangs on: a map carries thousands of breakable things, and looking
-- them all up at match start would cost real time and need clearing between matches.
--
-- WHAT NEVER BREAKS, whatever it is tagged: anything outside the Map; anything unanchored (vehicles
-- and deployables have health of their own); anything named, or inside something named, in NEVER
-- (roads, bridges, footings, spawns, the storm, objectives); and a tagged pool bigger than
-- MAX_POOL_SPAN across, which would be a slab something else stands on. The map modules never tag
-- those in the first place; this is the backstop, and tools/destruct_map_check.py plants a tag on
-- a bridge to show it holds.
--
-- FLOORS. A building's upper floors, stairs and roofs keep breaking per part as before (loot and
-- deployables on them resettle through OnPartBroken). Its ground-floor slab never breaks
-- (MapBuildings tags it false): it is what everyone inside is standing on, and under it is only
-- footing. Small single-storey things built as one pool (a wilds cabin, a lean-to, a deer stand)
-- come down whole, never leaving a roof in the air.
--
-- Window glass is the one thing that breaks at a touch: any bullet or blast shatters a pane, and
-- the shot carries on through it (CombatService asks PassesThrough). Clients draw the shards
-- (GlassFxClient) from one GlassShatter event per frame; the server only removes the pane, so
-- anyone joining later simply sees the window open.
--
-- Everything else that breaks is drawn the same way (#71): the server removes it and sends one
-- BreakFx event per frame, { cframe, size, color, material, class, from } for each piece, and
-- BreakFxClient throws debris shaped for the material (splinters, chunks and dust, plates and
-- sparks, leaves). No rubble is made on the server, so nothing breaking replicates a part.
--
-- When a wall, floor or roof part breaks, everything hanging off it goes too: the panes set into
-- it shatter, and its trim (sills, shutters, frames, cornices, signs, lights) is removed rather
-- than left floating where the wall used to be. Trim is found by overlap with the broken part,
-- walking the building's own children, so nothing is registered ahead of time. Solid pieces that
-- hang off the structure (ATTACHED: balconies and their rails, stair railings, ridge caps, coping,
-- stair soffits and headers) go the same way unless another structural part still holds them, and
-- break properly as they go: debris, and whatever rested on them is told.
--
-- A blast that goes off on open ground also takes a small bite out of the terrain (craterAt),
-- capped per map and never on a road, paving or water, or under anything built.
--
-- DAMAGE YOU CAN SEE (#71). Nothing that is taking damage ever turns see-through: a wall fading
-- toward clear read as a ghost of cover. Instead it cracks, and the cracks are drawn on every client
-- by CrackFxClient from three cheap things replicated here:
--
--   DamageStage   attribute, 0 whole, 1 at 75% health, 2 at 50%, 3 at 25%; only ever goes up. On
--                 the part (a pool of one, or each member of a group) or on the Model (a Model
--                 pool). Written at most three times per pool. Each stage also weathers the pool's
--                 colour a little toward what its material looks like broken (STAGE_TINT).
--   DamageSites   attribute on each part that was hit: up to MAX_SITES_PER_PART "face,x,y,z" points
--                 in the part's own space (face is the Enum.NormalId value). Written only when a new
--                 site opens, so a wall under a minigun costs four writes, not one per bullet.
--   Damaged       tag on those parts, so a player who joins late (or streams the part in) finds
--                 them and draws the same cracks.
--
-- and one DamageFx event per frame with that frame's hits, { part, point, face, count } each
-- (capped, one record per part), for the chips, sparks, dust and sound each hit makes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))

local DestructibleService = {}

DestructibleService.GlassName = "WindowGlass"
DestructibleService.Tag = "Destructible"
DestructibleService.HealthTag = "DestructibleHealth"
DestructibleService.HealthAttribute = DestructibleService.HealthTag

-- What can be broken and how much it takes. Walls are the headline number; structure is tougher
-- than the dressing hanging off it, and loose props give way quickly. (Trim never collides or
-- takes a raycast, so it can't be shot on its own; it goes with the part it hangs on.)
local HEALTH = {
	Wall = 100,
	Floor = 400,
	Roof = 320,
	Gable = 260,
	Parapet = 180,
	Stair = 300,
	Crate = 70,
	YardCrate = 70,
	Table = 55,
	Shelf = 55,
	WindowGlass = 1,
	-- Solid pieces fixed to the structure (#56): shootable on their own, and they come down with
	-- whatever holds them up (ATTACHED below) instead of hanging in the air.
	Balcony = 150,
	BalconyRail = 60,
	Railing = 80,
	RidgeCap = 120,
	Coping = 100,
	StairSoffit = 200,
	StairHeader = 160,
	Dock = 300,
	Bumper = 60,
}

-- How tough each tagged kind is for its size and material. 1 is a plain prop; a parked car is cover
-- you are meant to lean on, so it lasts; an umbrella is cloth on a stick.
local KINDS = {
	Tree = 1.4, Palm = 1.1, Cactus = 0.8, Bush = 0.5, HayBales = 0.6,
	Rock = 1.3, Log = 1, Stump = 1, Cairn = 1, Picnic = 0.8,
	Shelter = 1.6, Wreck = 1.5, Container = 2.2,
	Car = 1.8, Bench = 0.8, Bin = 0.7, Hydrant = 1.2, Planter = 0.8, Umbrella = 0.4, Lamp = 1,
	RoofProp = 1, Prop = 1, Sign = 0.8,
	-- A house's furniture (MapBuildings.furnishRoom): each piece is one pool, cover that gives way.
	Furniture = 0.9,
}
DestructibleService.Kinds = KINDS

-- Material families: how tough each is, and what its colour weathers toward. EVERY part material has
-- one (tools/crack_check.py holds this table, CrackFxClient's and BreakFxClient's to the full list);
-- what each material LOOKS like cracking and breaking is its own, in those two clients.
local M = Enum.Material
local CLASS_OF = {
	[M.Wood] = "wood", [M.WoodPlanks] = "wood",
	[M.Brick] = "stone", [M.Concrete] = "stone", [M.Slate] = "stone", [M.Rock] = "stone", [M.Cobblestone] = "stone",
	[M.Granite] = "stone", [M.Marble] = "stone", [M.Pebble] = "stone", [M.Basalt] = "stone", [M.Limestone] = "stone",
	[M.Sandstone] = "stone", [M.Pavement] = "stone", [M.Asphalt] = "stone", [M.CrackedLava] = "stone", [M.Salt] = "stone",
	[M.Plaster] = "stone", [M.CeramicTiles] = "stone", [M.ClayRoofTiles] = "stone", [M.RoofShingles] = "stone",
	[M.Metal] = "metal", [M.DiamondPlate] = "metal", [M.CorrodedMetal] = "metal", [M.Foil] = "metal",
	[M.Grass] = "foliage", [M.LeafyGrass] = "foliage",
	[M.Ground] = "soil", [M.Sand] = "soil", [M.Snow] = "soil", [M.Mud] = "soil",
	[M.Fabric] = "cloth", [M.Carpet] = "cloth", [M.Leather] = "cloth", [M.Cardboard] = "cloth",
	[M.Glass] = "glass", [M.Ice] = "glass", [M.Glacier] = "glass", [M.Neon] = "glass", [M.ForceField] = "glass",
	[M.Plastic] = "plastic", [M.SmoothPlastic] = "plastic", [M.Rubber] = "plastic",
}
local CLASS_TOUGHNESS = { stone = 2, metal = 1.6, wood = 1, plastic = 1, soil = 0.7, foliage = 0.55, cloth = 0.4, glass = 0.3 }

local function classOf(material)
	return CLASS_OF[material] or "plastic"
end
DestructibleService.ClassOf = classOf
DestructibleService.ClassTable = CLASS_OF

-- Each damage stage weathers what is left a step toward what its material looks like broken, from
-- the colour it had before the first stage (so stages never compound): stone greyer and dustier,
-- wood darker, metal sooty, leaves dry and brown. Glass keeps its colour; it cracks instead.
local STAGE_TINT = {
	stone = { Color3.fromRGB(104, 100, 94), 0.07 },
	wood = { Color3.fromRGB(58, 42, 28), 0.08 },
	metal = { Color3.fromRGB(38, 36, 34), 0.07 },
	foliage = { Color3.fromRGB(132, 108, 54), 0.16 },
	soil = { Color3.fromRGB(78, 62, 46), 0.08 },
	plastic = { Color3.fromRGB(76, 76, 76), 0.06 },
	cloth = { Color3.fromRGB(64, 60, 56), 0.07 },
}
DestructibleService.StageTint = STAGE_TINT

-- health = toughness(material) * (BASE + PER_STUD * size) * kind, where size is the cube root of the
-- pool's solid volume (capped): a bench about 55, an oak about 120, a boulder about 200, a parked car
-- about 280. A rocket's wallDamage is 110-150, a rifle round 20-40.
local HEALTH_BASE, HEALTH_PER_STUD, SIZE_CAP = 20, 14, 12
local MIN_HEALTH, MAX_HEALTH = 15, 1500

-- THE MAP'S STRUCTURE BY MATERIAL (Oliver 2026-09-24: "increase the health of the walls in the map
-- depending on the material"). A building's named Wall and every untagged structural part (a keep's
-- wall, a bunker, a landmark's pier) take their health from what they are made of, spread wide: glass
-- gives at a touch, cloth and wood and plaster soon, brick holds, concrete and stone hold longer, metal
-- longest and diamond plate (the reinforced stuff) longest of all. Tagged props (trees, cars, crates)
-- keep CLASS_TOUGHNESS above. A named Wall is STRUCTURE.wall times this (a wood wall 150, brick 300,
-- concrete 420, metal 510, diamond plate 600); an untagged part is this times (BASE + PER_STUD *
-- size) times STRUCTURE.scale; a blast counts STRUCTURE.blast times over on them. tools/destruct_material_check.py holds the order and the numbers.
local STRUCTURE_TOUGHNESS = {
	[M.Glass] = 0.3, [M.Neon] = 0.3, [M.ForceField] = 0.3, [M.Ice] = 0.5, [M.Glacier] = 0.8,
	[M.Cardboard] = 0.45, [M.Fabric] = 0.6, [M.Carpet] = 0.6, [M.Leather] = 0.7, [M.Foil] = 0.6,
	[M.Wood] = 1, [M.WoodPlanks] = 1, [M.RoofShingles] = 1, [M.Plastic] = 1, [M.SmoothPlastic] = 1, [M.Rubber] = 0.9,
	[M.Plaster] = 1.1, [M.CeramicTiles] = 1.2, [M.ClayRoofTiles] = 1.2, [M.Salt] = 1.6,
	[M.Brick] = 2,
	[M.Sandstone] = 2.2, [M.Pebble] = 2.2, [M.Limestone] = 2.4, [M.Asphalt] = 2.4, [M.CrackedLava] = 2.4,
	[M.Marble] = 2.6, [M.Slate] = 2.6, [M.Cobblestone] = 2.6, [M.Pavement] = 2.6,
	[M.Concrete] = 2.8, [M.Rock] = 2.8, [M.Granite] = 3, [M.Basalt] = 3,
	[M.CorrodedMetal] = 3, [M.Metal] = 3.4, [M.DiamondPlate] = 4,
	[M.Grass] = 0.55, [M.LeafyGrass] = 0.55, [M.Ground] = 0.7, [M.Mud] = 0.6, [M.Sand] = 0.6, [M.Snow] = 0.5,
}
DestructibleService.StructureToughness = STRUCTURE_TOUGHNESS
-- (One table, not three locals: this module's main chunk sits near Luau's 200-local limit.)
local STRUCTURE = { wall = 150, scale = 1.5, blast = 2 }
DestructibleService.WallHealth, DestructibleService.StructureScale = STRUCTURE.wall, STRUCTURE.scale
-- Explosives stay decisive against structure: a blast's wallDamage counts this many times over on
-- the map's own untagged parts and named walls (one rocket holes brick, two take concrete or metal).
DestructibleService.StructureBlast = STRUCTURE.blast

local function structureToughness(material)
	return STRUCTURE_TOUGHNESS[material] or CLASS_TOUGHNESS[classOf(material)]
end
DestructibleService.StructureToughnessOf = structureToughness

-- A building's named piece: its HEALTH, and for a Wall, STRUCTURE.wall by its material.
local function namedHealth(part)
	if part.Name == "Wall" then
		return math.clamp(math.floor(STRUCTURE.wall * structureToughness(part.Material) + 0.5), MIN_HEALTH, MAX_HEALTH)
	end
	return HEALTH[part.Name]
end
DestructibleService.NamedHealth = namedHealth

-- WHAT NEVER BREAKS (Oliver 2026-09-24: "make EVERYTHING breakable other than spawns, the lobby,
-- storm zone, and map edges"). By the part's own name or any ancestor's inside the match root:
--   spawns      SpawnLocation, a "Spawn" model (a team base's bunker), SpawnPad...
--   the lobby   (it isn't under the Map anyway; the name is the backstop)
--   the storm   (likewise)
-- and the MAP EDGES, which are not parts: the terrain at the edge of the world and the bedrock under
-- every crater's dig floor (see the craters). Everything else breaks -- roads, kerbs, paving, parking
-- lots, bridges and decks, foundations, footings, plinths, ground floors, stepping stones, ziplines,
-- the props round an objective (its zone is a sum on positions, not a part, and keeps working).
-- tools/destruct_coverage_probe.lua asserts that these are the only reasons anything is kept whole.
local NEVER = {
	SpawnLocation = true, Spawn = true, Lobby = true, Storm = true,
}
DestructibleService.Never = NEVER
-- ...and names that START with one of these as a word (the next letter a capital or a digit):
-- SpawnPad, SpawnBeacon, LobbyFloor, StormWall -- but not Spawner... or Stormcaller.
local NEVER_PREFIX = { "Spawn", "Lobby", "Storm" }
DestructibleService.NeverPrefix = NEVER_PREFIX
DestructibleService.KeptReasons = { spawn = true, lobby = true, storm = true, ["map edge"] = true }

local function neverName(name)
	if NEVER[name] then
		return true
	end
	for _, prefix in ipairs(NEVER_PREFIX) do
		if string.sub(name, 1, #prefix) == prefix then
			local next = string.sub(name, #prefix + 1, #prefix + 1)
			if next ~= "" and string.match(next, "[%u%d]") then
				return true
			end
		end
	end
	return false
end
DestructibleService.NeverName = neverName

-- Which of the four a NEVER name is, for the audit.
local function keptReason(name)
	for _, word in ipairs({ "Spawn", "Lobby", "Storm" }) do
		if string.sub(name, 1, #word) == word then
			return string.lower(word)
		end
	end
	return "spawn"
end

-- Models that break under their own health rather than a pool's: an explosive barrel is
-- HazardService's (a bullet must reach it to set it off), a vehicle VehicleService's.
local OWN_HEALTH_MODELS = { ExplosiveBarrel = "hazard (HazardService)" }
DestructibleService.OwnHealthModels = OWN_HEALTH_MODELS

-- Past this across, a single part breaks in pieces where it is hit (SUBDIVIDE, below), not whole.
local MAX_POOL_SPAN = 90

-- EVERYTHING ELSE BREAKS. An anchored part in the Map that collides or can be shot, and that no rule
-- above keeps whole, is a pool of its own, found on its first hit like any other:
--
--   a thing     the biggest Model round it that is compact (THING_SPAN across, THING_HEIGHT tall,
--               THING_PARTS parts at most, with no building's walls or floors in it): a flag and its
--               footing, a turbine, a fountain, a hut. It comes down whole, dressing and all. A
--               zipline is always one thing, however long: any piece of it going snaps the line.
--   a part      otherwise the part alone (a building's corner post, a chimney, an awning, a step),
--               health from its own size and material; its dressing goes with it (dropDressing).
--   a piece     a part bigger than SUBDIVIDE_OVER across (a road, a plaza, a bridge deck, a long
--               wall) is cut, on its first hit, into a grid of TILE-stud tiles along its two long
--               axes, each a pool of its own; the hit lands on the tile it struck. So a rocket holes
--               a road where it lands, and the rest of the road stays. Lazy: nothing is cut until
--               it is hit, and a part is cut once.
--
-- `Destructible = false` (a builder's "never") is no longer honoured: the only things kept whole
-- are the four above. Spawns are spawns by name.
--
-- NOTHING IS LEFT IN THE AIR, and buildings fall over: see the support pass and CollapseService.
local THING_SPAN, THING_HEIGHT, THING_PARTS = 24, 40, 48
local GROUND_SLAB_THICK, GROUND_SLAB_WIDE, GROUND_SLAB_REACH = 3, 8, 3
local SUBDIVIDE_OVER, TILE = 16, 8
DestructibleService.SubdivideOver, DestructibleService.Tile = SUBDIVIDE_OVER, TILE
local WHOLE_MODELS = { Zipline = true }
local SUPPORT_MARGIN = 0.35
local SUPPORT_CHECKS, SUPPORT_FALLS = 1200, 24
DestructibleService.ThingSpan = THING_SPAN
DestructibleService.SupportChecks, DestructibleService.SupportFalls = SUPPORT_CHECKS, SUPPORT_FALLS
-- The most parts one pool's break draws debris for (the biggest ones); the rest just go.
local FX_PER_POOL = 10

-- Structure whose breaking takes the panes and trim attached to it along.
local CARRIES_DRESSING = { Wall = true, Floor = true, Roof = true, Gable = true, Parapet = true, Stair = true, Balcony = true }
-- Solid pieces that hang off the structure rather than hold anything up. They fall with their
-- host the way trim does, and never count as what holds something else up.
local ATTACHED = {
	Balcony = true, BalconyRail = true, Railing = true, RidgeCap = true, Coping = true,
	StairSoffit = true, StairHeader = true,
}
-- How far apart two parts may be and still count as attached: trim sits a hair off its wall. To hold
-- a piece of trim up, a part must be closer than that (HOLD_MARGIN): really touching it.
local ATTACH_MARGIN = 0.35
local HOLD_MARGIN = 0.06
-- A pane only overlaps the wall bands round its opening by a tenth of a stud.
local PANE_MARGIN = 0.02

local glassShatter = Remotes.Event("GlassShatter")
local breakFx = Remotes.Event("BreakFx")
local damageFx = Remotes.Event("DamageFx")

-- Damage stages (see the header): the health fraction at or below which each stage begins.
local STAGE_AT = { 0.75, 0.5, 0.25 }
DestructibleService.StageAt = STAGE_AT
-- CrackFxClient reads these by the same literal names.
local STAGE_ATTRIBUTE, SITES_ATTRIBUTE, DAMAGED_TAG = "DamageStage", "DamageSites", "Damaged"
DestructibleService.StageAttribute = STAGE_ATTRIBUTE
DestructibleService.SitesAttribute = SITES_ATTRIBUTE
DestructibleService.DamagedTag = DAMAGED_TAG
-- Where hits leave marks: at most this many per part and per pool; a hit this close to an open site
-- on the same face deepens that one rather than opening another.
local MAX_SITES_PER_PART, MAX_SITES_PER_POOL = 4, 8
local SITE_MERGE = 1.6
DestructibleService.MaxSitesPerPart = MAX_SITES_PER_PART
DestructibleService.MaxSitesPerPool = MAX_SITES_PER_POOL
-- Hit records one DamageFx event carries at most (one per part per frame). Every hit still opens
-- its site; only the burst and sound of the ones past this are left out.
local HITS_PER_FRAME = 40
DestructibleService.HitsPerFrame = HITS_PER_FRAME

-- Anything inside these is fair game; anything else on the map is scenery and stays put. Everything
-- a match builds is under workspace.Map: the towns, wilds, landmarks, roads and props
-- (MapGenerator), and in a team match the battleground (TeamBattleground.Build) and both bases
-- (TeamBaseRuins.Build), which parent into mapInfo.map. tools/destruct_coverage_probe.lua lists
-- whatever else stands under workspace, so geometry parented somewhere new shows up.
local ROOTS = { Map = true }
DestructibleService.Roots = ROOTS

-- pool key -> { health, max, broken, members, target }. The key is the part (a single part), the
-- Model (a tagged Model) or the tag string (a group). Strong keys, dropped when the pool's first
-- member is destroyed: a weak-keyed table loses live Instances, since Roblox collects an instance's
-- Lua handle whenever nothing but a weak table holds it.
local damaged = {}

-- The Map this part stands in, or nil if it's outside one or anything on the way is off limits.
-- Second value: why not ("never:<name>" or "outside the match roots").
local function mapRootOf(part)
	if neverName(part.Name) then
		return nil, keptReason(part.Name)
	end
	local node = part.Parent
	while node and node.Parent ~= workspace do
		if neverName(node.Name) then
			return nil, keptReason(node.Name)
		end
		node = node.Parent
	end
	if not node or node.Parent ~= workspace or not ROOTS[node.Name] then
		return nil, "outside the match roots"
	end
	return node
end

local function positiveNumber(value)
	return type(value) == "number" and value > 0 and value or nil
end

-- Caches for the opt-out rules, each filled on a part's (or Model's) first hit and dropped when it
-- is destroyed, so nothing is looked at before someone shoots it and nothing outlives its map.
local thingCache, slabCache = {}, {}

local function cacheUntil(cache, instance, value)
	if cache[instance] == nil then
		instance.Destroying:Connect(function()
			cache[instance] = nil
		end)
	end
	cache[instance] = value
	return value
end

-- A part's reach along a world axis from its centre (half its extent that way), turned or not.
local function halfAlong(part, axis)
	local cf, size = part.CFrame, part.Size
	return (math.abs(cf.RightVector:Dot(axis)) * size.X + math.abs(cf.UpVector:Dot(axis)) * size.Y
		+ math.abs(cf.LookVector:Dot(axis)) * size.Z) / 2
end

local UP, EAST, NORTH = Vector3.new(0, 1, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, 1)

-- What owns this part if not us: a Model in OWN_HEALTH_MODELS round it, or whatever CombatService's
-- hooks for hazards, deployables and companions claim. nil if nobody.
local function ownerElsewhere(part)
	local node = part.Parent
	while node and node ~= workspace do
		local why = OWN_HEALTH_MODELS[node.Name]
		if why then
			return why
		end
		if node:GetAttribute("VehicleMaxHealth") ~= nil then
			return "vehicle (VehicleService)"
		end
		node = node.Parent
	end
	if CombatService.HazardFromPart and CombatService.HazardFromPart(part) then
		return "hazard (HazardService)"
	end
	if CombatService.StructureFromPart and CombatService.StructureFromPart(part) then
		return "deployable (DefenseService)"
	end
	if CombatService.CompanionFromPart and CombatService.CompanionFromPart(part) then
		return "companion"
	end
	return nil
end

-- Whether a Model is one compact thing (see THING_SPAN above). Cached per Model.
local function compact(model)
	local cached = thingCache[model]
	if cached ~= nil then
		return cached
	end
	local ok = true
	if #model:GetChildren() > THING_PARTS then
		ok = false
	else
		local count = 0
		local low, high = nil, nil
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				count += 1
				local name = d.Name
				-- A building (its own walls, floors, roofs), or a slab someone stands on, is never a
				-- thing: its pieces break one by one.
				if count > THING_PARTS or CARRIES_DRESSING[name] or d:GetAttribute("Destructible") ~= nil then
					ok = false
					break
				end
				local hx, hy, hz = halfAlong(d, EAST), halfAlong(d, UP), halfAlong(d, NORTH)
				if hy * 2 <= GROUND_SLAB_THICK and hx * 2 >= GROUND_SLAB_WIDE and hz * 2 >= GROUND_SLAB_WIDE and d.CanCollide then
					ok = false
					break
				end
				local p = d.Position
				local a, b = p - Vector3.new(hx, hy, hz), p + Vector3.new(hx, hy, hz)
				low = low and low:Min(a) or a
				high = high and high:Max(b) or b
			end
		end
		if ok and low then
			local span = high - low
			ok = math.max(span.X, span.Z) <= THING_SPAN and span.Y <= THING_HEIGHT
		elseif not low then
			ok = false
		end
	end
	return cacheUntil(thingCache, model, ok)
end

-- The biggest compact Model round a part, or nil. Never one of the Map's own children (Town, Props,
-- Roads, Landmarks, a team base): those hold everything else, however small a test map makes them.
local function thingOf(part)
	local best = nil
	local node = part.Parent
	while node and node.Parent and node.Parent ~= workspace and node.Parent.Parent ~= workspace do
		if node:IsA("Model") and WHOLE_MODELS[node.Name] then
			return node
		end
		if node:IsA("Model") then
			if compact(node) then
				best = node
			else
				break
			end
		end
		node = node.Parent
	end
	return best
end
DestructibleService.ThingOf = thingOf

-- Whether a part is ground someone stands on: a thin, wide slab lying on the terrain, or on
-- something that never breaks (a foundation, a plinth, a road). Cached per part.
local groundParams = nil
local function groundSlab(part)
	local cached = slabCache[part]
	if cached ~= nil then
		return cached
	end
	local hy = halfAlong(part, UP)
	local slab = false
	if hy * 2 <= GROUND_SLAB_THICK and halfAlong(part, EAST) * 2 >= GROUND_SLAB_WIDE and halfAlong(part, NORTH) * 2 >= GROUND_SLAB_WIDE then
		groundParams = groundParams or RaycastParams.new()
		groundParams.FilterType = Enum.RaycastFilterType.Exclude
		groundParams.FilterDescendantsInstances = { part }
		groundParams.IgnoreWater = true
		local bottom = part.Position - Vector3.new(0, hy, 0)
		local hit = workspace:Raycast(bottom + Vector3.new(0, 0.2, 0), Vector3.new(0, -GROUND_SLAB_REACH, 0), groundParams)
		if hit then
			local under = hit.Instance
			slab = under == workspace.Terrain or (under:IsA("BasePart") and (mapRootOf(under) == nil
				or under:GetAttribute("Destructible") == false))
		end
	end
	return cacheUntil(slabCache, part, slab)
end
DestructibleService.GroundSlab = groundSlab

-- A slab with nothing at all under it, ground or part, as far down as the world goes: breaking it
-- would open a hole to the void, so it never breaks (see "NO HOLE IN THE MAP" by the craters).
-- Cached per part.
local voidCache = {}
local voidParams = nil
local function overVoid(part)
	local cached = voidCache[part]
	if cached ~= nil then
		return cached
	end
	local hy = halfAlong(part, UP)
	local void = false
	if hy * 2 <= GROUND_SLAB_THICK and halfAlong(part, EAST) * 2 >= GROUND_SLAB_WIDE and halfAlong(part, NORTH) * 2 >= GROUND_SLAB_WIDE then
		voidParams = voidParams or RaycastParams.new()
		voidParams.FilterType = Enum.RaycastFilterType.Exclude
		voidParams.FilterDescendantsInstances = { part }
		voidParams.IgnoreWater = false
		void = workspace:Raycast(part.Position - Vector3.new(0, hy - 0.1, 0), Vector3.new(0, -600, 0), voidParams) == nil
	end
	return cacheUntil(voidCache, part, void)
end
DestructibleService.OverVoid = overVoid

-- The nearest Model above `part` (inside the Map) tagged as one pool, if any.
local function taggedModel(part)
	local node = part.Parent
	while node and node.Parent ~= workspace do
		if node:IsA("Model") then
			local tag = node:GetAttribute("Destructible")
			if type(tag) == "string" or positiveNumber(node:GetAttribute("DestructibleHealth")) then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

-- Which pool a part belongs to, cheaply (no search): (key, kind, owner, explicit health, auto) or
-- nil. The key is the part itself, the tagged Model, or the group's tag string; `owner` is where the
-- members are found (the Model, or the part's parent for a group), nil for a pool of one. `auto` is
-- true for the opt-out pools (nothing tagged it and it has no HEALTH name): see "EVERYTHING ELSE
-- BREAKS" above.
local function keyOf(part)
	if not part or not part:IsA("BasePart") or not part.Anchored then
		return nil
	end
	-- A window pane is always its own pool of one, even in a tagged cabin: glass breaks at a touch.
	if part.Name == DestructibleService.GlassName then
		return (part.CanCollide and mapRootOf(part)) and part or nil, nil, nil, HEALTH[part.Name]
	end
	-- (`false` is a builder's old "never", no longer honoured: it reads as no tag at all.)
	local tag = part:GetAttribute("Destructible")
	if type(tag) == "string" then
		if not (part.CanCollide or part.CanQuery) then
			return nil
		end
		local kind, id = string.match(tag, "^([^:]+):(.+)$")
		if not id then
			return part, tag, nil, part:GetAttribute("DestructibleHealth")
		end
		return tag, kind, part.Parent, part:GetAttribute("DestructibleHealth")
	end
	local model = taggedModel(part)
	if model then
		if not (part.CanCollide or part.CanQuery) then
			return nil
		end
		local kind = model:GetAttribute("Destructible")
		return model, type(kind) == "string" and kind or "Prop", model, positiveNumber(model:GetAttribute("DestructibleHealth"))
	end
	if part.CanCollide then
		-- A lone part with its own health number, or a building's own named piece.
		local own = positiveNumber(part:GetAttribute("DestructibleHealth"))
		if own or HEALTH[part.Name] then
			return part, nil, nil, own or namedHealth(part)
		end
	end
	-- Everything else that collides or can be shot: the compact thing round it, or itself. (Trim
	-- neither collides nor takes a ray: it goes with whatever it hangs on.)
	if not (part.CanCollide or part.CanQuery) then
		return nil
	end
	local thing = thingOf(part)
	if thing then
		return thing, "Prop", thing, nil, true
	end
	return part, "Prop", nil, nil, true
end
DestructibleService.KeyOf = keyOf

-- Why a part that has a pool key still may not be hurt, cheaply (the ground-slab ray is cast once per
-- part and remembered), or nil: it is outside the Map or NEVER, something else owns it, or -- for
-- the opt-out pools only, which nobody chose on purpose -- nobody can see it, or it is ground.
local function refusalOf(part, auto)
	local root, why = mapRootOf(part)
	if not root then
		return why
	end
	local owner = ownerElsewhere(part)
	if owner then
		return "own health: " .. owner
	end
	return nil
end

-- Every part in a pool, found once, on its first hit.
local function membersOf(key, part, owner)
	if not owner then
		return { part }
	end
	local members = {}
	if type(key) == "string" then
		for _, other in ipairs(owner:GetChildren()) do
			if other:IsA("BasePart") and other:GetAttribute("Destructible") == key then
				table.insert(members, other)
			end
		end
	else
		for _, other in ipairs(owner:GetDescendants()) do
			if other:IsA("BasePart") then
				table.insert(members, other)
			end
		end
	end
	return members
end

-- A tagged pool's health from what it is: the cube root of its solid volume (a tree's trunk, not
-- its leaves) in the material of its biggest solid piece, times its kind.
local function poolHealth(kind, members, structure)
	local solid, all = 0, 0
	local biggest, biggestVolume = members[1], -1
	for _, member in ipairs(members) do
		local size = member.Size
		local volume = size.X * size.Y * size.Z
		all += volume
		if member.CanCollide then
			solid += volume
			if volume > biggestVolume then
				biggest, biggestVolume = member, volume
			end
		end
	end
	local scale = math.min((solid > 0 and solid or all) ^ (1 / 3), SIZE_CAP)
	-- The map's own untagged structure by its material (STRUCTURE_TOUGHNESS); a tagged prop by family.
	local toughness = structure and structureToughness(biggest.Material) * STRUCTURE.scale or CLASS_TOUGHNESS[classOf(biggest.Material)]
	local health = toughness * (HEALTH_BASE + HEALTH_PER_STUD * scale) * (KINDS[kind] or 1)
	return math.clamp(math.floor(health + 0.5), MIN_HEALTH, MAX_HEALTH)
end
DestructibleService.PoolHealth = poolHealth

-- The box round a pool's members, axis-aligned: (centre CFrame, size).
local function boundsOf(members)
	local low, high = nil, nil
	for _, member in ipairs(members) do
		local half = member.Size / 2
		local centre = member.Position
		local a, b = centre - half, centre + half
		low = low and Vector3.new(math.min(low.X, a.X), math.min(low.Y, a.Y), math.min(low.Z, a.Z)) or a
		high = high and Vector3.new(math.max(high.X, b.X), math.max(high.Y, b.Y), math.max(high.Z, b.Z)) or b
	end
	return CFrame.new((low + high) / 2), high - low
end

-- What a part's pool would be, worked out the way its first hit works it out, without keeping it:
-- (pool, key) or (nil, why). The pool is { max, members, tagged, auto, target }.
local function resolvePool(part)
	local key, kind, owner, explicit, auto = keyOf(part)
	if not key then
		return nil, "no pool"
	end
	-- Only things standing on the map itself, so lobby furniture and deployables are untouched.
	local refusal = refusalOf(part, auto)
	if refusal then
		return nil, refusal
	end
	local members = membersOf(key, part, owner)
	local max = explicit
	if kind ~= nil then
		local _, span = boundsOf(members)
		if owner ~= nil and math.max(span.X, span.Z) > MAX_POOL_SPAN and not WHOLE_MODELS[typeof(key) == "Instance" and key.Name or ""] then
			-- Too wide to be one thing (a slab something else stands on): the part hit breaks alone.
			key, owner, members, explicit = part, nil, { part }, nil
			max = nil
		end
		max = max or poolHealth(kind, members, auto == true)
	end
	if type(max) ~= "number" or max <= 0 then
		return nil, "no health"
	end
	-- A pool of several parts (or a Model) breaks as one (shatterPool); a pool of one part breaks as
	-- a part does, taking its dressing with it (shatter).
	return { max = max, members = members, tagged = owner ~= nil, auto = auto == true,
		target = typeof(key) == "Instance" and key:IsA("Model") and key or nil }, key
end

-- Defined with the support pass, below; subdivide (by Damage) forgets what it cuts up.
local forget

-- The pool entry for a part, made on its first hit; nil if the part can't be broken.
local function entryFor(part)
	local key = keyOf(part)
	if not key then
		return nil
	end
	local entry = damaged[key]
	if entry then
		return entry, key
	end
	local pool
	pool, key = resolvePool(part)
	if not pool then
		return nil
	end
	-- (A part of a pool too wide to be one thing is a pool of its own, under its own key.)
	if damaged[key] then
		return damaged[key], key
	end
	entry = { health = pool.max, max = pool.max, members = pool.members, tagged = pool.tagged, auto = pool.auto, stage = 0,
		target = pool.target }
	damaged[key] = entry
	-- Dropped when the pool's anchor goes: the part itself, the Model, or the group's first member.
	local anchor = typeof(key) == "Instance" and key or pool.members[1]
	anchor.Destroying:Connect(function()
		if damaged[key] == entry then
			damaged[key] = nil
		end
	end)
	return entry, key
end

-- (health, max) of the pool a part is in, once it has been hit; nil before. For probes and checks.
function DestructibleService.HealthOf(part)
	local key = keyOf(part)
	local entry = key ~= nil and damaged[key] or nil
	if entry then
		return entry.health, entry.max
	end
	return nil
end

-- Answers without looking anything up beyond the part and its parents (and, for a big flat part,
-- one ray down, once): whether it is worth sending the hit here. (An oversized pool is only refused
-- on the hit itself, which then deals 0.)
function DestructibleService.FromPart(part)
	local key, _, _, _, auto = keyOf(part)
	if not key then
		return nil
	end
	local entry = damaged[key]
	if entry then
		return not entry.broken and part or nil
	end
	return refusalOf(part, auto) == nil and part or nil
end

-- For the coverage audit (tools/destruct_coverage_probe.lua): what the service makes of a part, and
-- why. ("breakable", how, pool key) | ("excluded", the rule that keeps it whole) | ("trim", ...) for
-- dressing that neither collides nor takes a ray | ("unexplained", why) for a hole in the rules.
local KEPT = DestructibleService.KeptReasons
function DestructibleService.Explain(part)
	if not part:IsA("BasePart") then
		return "excluded", "not a part"
	end
	if not part.Anchored then
		return "excluded", "unanchored (own health or none: vehicles, deployables, debris)"
	end
	local root, why = mapRootOf(part)
	if not root then
		return KEPT[why] and "excluded" or "outside", why
	end
	local owner = ownerElsewhere(part)
	if owner then
		-- It breaks, under its own health (a barrel goes up, a vehicle is wrecked).
		return "breakable", "own health: " .. owner
	end
	if not (part.CanCollide or part.CanQuery) then
		return "trim", "goes with what it hangs on"
	end
	local key = keyOf(part)
	local entry = key ~= nil and damaged[key] or nil
	if entry then
		return "breakable", entry.auto and "auto" or "tagged/named", key
	end
	local pool, found = resolvePool(part)
	if not pool then
		if KEPT[found] then
			return "excluded", found
		end
		return "unexplained", found
	end
	return "breakable", pool.auto and (pool.target and "auto: thing" or "auto: part") or "tagged/named", found
end

-- Glass doesn't stop a shot: the pane breaks and the bullet goes on to whatever is behind it.
function DestructibleService.PassesThrough(part)
	return part ~= nil and part.Name == DestructibleService.GlassName
end

-- Where on a part a hit landed: the point on the face it struck, in the part's own space, and that
-- face as its Enum.NormalId value (0 +X, 1 +Y, 2 +Z, 3 -X, 4 -Y, 5 -Z). From the exact hit when the
-- caller knows it (`at`, and `normal` if it has one); otherwise the point of the part nearest to
-- where the shot or blast came from, which is exact for a blast and, for a shot, lands on the face
-- the shot came in through. nil when there is nothing to go on.
local function hitSite(part, from, at, normal)
	local source = typeof(at) == "Vector3" and at or (typeof(from) == "Vector3" and from or nil)
	if not source then
		return nil
	end
	local cframe, half = part.CFrame, part.Size / 2
	local p = cframe:PointToObjectSpace(source)
	local coords = { p.X, p.Y, p.Z }
	local halves = { half.X, half.Y, half.Z }
	local axis, sign = 1, 1
	if typeof(normal) == "Vector3" then
		local n = cframe:VectorToObjectSpace(normal)
		local along = { n.X, n.Y, n.Z }
		for index = 2, 3 do
			if math.abs(along[index]) > math.abs(along[axis]) then
				axis = index
			end
		end
		sign = along[axis] >= 0 and 1 or -1
	else
		-- The face the point stands furthest out from (or, from inside, is nearest to).
		local best = -math.huge
		for index = 1, 3 do
			local excess = math.abs(coords[index]) - halves[index]
			if excess > best then
				best, axis = excess, index
			end
		end
		sign = coords[axis] >= 0 and 1 or -1
	end
	for index = 1, 3 do
		coords[index] = math.clamp(coords[index], -halves[index], halves[index])
	end
	coords[axis] = sign * halves[axis]
	return Vector3.new(coords[1], coords[2], coords[3]), (axis - 1) + (sign < 0 and 3 or 0)
end
DestructibleService.HitSite = hitSite

-- Panes broken this frame, sent to every client as one event:
-- { cframe, size, color, from, impact, transparency } each, where `from` (optional) is where the
-- shot or blast came from, so the shards fly away from it, and `impact` (optional) the point on the
-- pane it struck, where GlassFxClient starts the spiderweb.
local pendingPanes = nil

local function breakPane(pane, from, at, normal)
	local entry = damaged[pane]
	if entry then
		entry.broken = true
	end
	if not pendingPanes then
		pendingPanes = {}
		task.defer(function()
			local batch = pendingPanes
			pendingPanes = nil
			glassShatter:FireAllClients(batch)
		end)
	end
	-- The face doesn't matter here: a pane is one sheet, and the shards fly from the point.
	local point, _face = hitSite(pane, from, at, normal)
	table.insert(pendingPanes, { pane.CFrame, pane.Size, pane.Color, typeof(from) == "Vector3" and from or nil,
		point and pane.CFrame * point or nil, pane.Transparency })
	pane:Destroy()
end

-- Whether `other` reaches within `margin` of `part`: other's box measured along part's own axes.
-- Exact for the square-on pieces buildings are made of, and generous for anything turned.
local function attached(part, other, margin)
	local relative = part.CFrame:ToObjectSpace(other.CFrame)
	local half = other.Size / 2
	local x, y, z = relative.XVector, relative.YVector, relative.ZVector
	local reach = part.Size / 2 + Vector3.new(margin, margin, margin) + Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	local offset = relative.Position
	return math.abs(offset.X) <= reach.X and math.abs(offset.Y) <= reach.Y and math.abs(offset.Z) <= reach.Z
end

local function isTrim(part)
	return part:IsA("BasePart") and not part.CanCollide and not part.CanQuery and part.Name ~= "Rubble"
end

-- A structural part is going: the panes set into it shatter, and any trim left hanging in the air
-- goes too. Trim is only taken when nothing solid still holds it: a header spanning two piers
-- stays on the lintel when one pier goes, and a shutter on that pier falls with it. It spreads
-- through trim resting on trim that fell (flowers in a flower box that lost its wall), and no
-- further. Only the building's own loose parts count; props that are models of their own (an
-- explosive barrel) keep all their pieces.
-- Defined further down, beside the rest of the breaking; dropDressing needs them for solid pieces.
local queueFx, tellBroken

-- Any part that breaks alone takes its dressing, not only a building's walls and floors (the trim on
-- a chimney, the lamp head on a signal pole): its siblings are walked, unless there are more of
-- them than DRESSING_SCAN (a whole town's loose props), where the walk would cost more than a frame
-- should.
local DRESSING_SCAN = 800

local function dropDressing(part, from)
	local building = part.Parent
	if not building then
		return
	end
	local children = building:GetChildren()
	if not CARRIES_DRESSING[part.Name] and #children > DRESSING_SCAN then
		return
	end
	local gone = { [part] = true }

	-- Held = really touching something solid that stays (not just near its edge: a shutter beside a
	-- window that lost its wall is not held by the wall past the window).
	local function heldBySolid(trim)
		for _, other in ipairs(children) do
			if not gone[other] and other:IsA("BasePart") and other.CanCollide and other.Name ~= DestructibleService.GlassName
				and not ATTACHED[other.Name] and attached(other, trim, HOLD_MARGIN) then
				return true
			end
		end
		return false
	end

	local queue = { part }
	while #queue > 0 do
		local current = table.remove(queue)
		for _, other in ipairs(children) do
			if not gone[other] and other:IsA("BasePart") then
				if other.Name == DestructibleService.GlassName then
					-- Glass can't hang in a broken frame, but only structure breaks it.
					if current == part and attached(part, other, PANE_MARGIN) then
						gone[other] = true
						breakPane(other, from)
					end
				elseif (isTrim(other) or (ATTACHED[other.Name] and other.CanCollide))
					and attached(current, other, ATTACH_MARGIN) and not heldBySolid(other) then
					gone[other] = true
					table.insert(queue, other)
				end
			end
		end
	end

	for trim in pairs(gone) do
		if trim ~= part and trim.Parent and trim.Name ~= DestructibleService.GlassName then
			if trim.CanCollide then
				-- A solid piece: whatever rests on it settles, and it breaks like anything else.
				tellBroken(trim.CFrame, trim.Size)
				queueFx(trim, from)
			end
			trim:Destroy()
		end
	end
end

-- Told of every structural part that breaks, with its frame and size, while it still stands, so
-- whatever rests on it can come down after it: loot (LootService.Resettle), supply drops, vendors and
-- players' deployables register here. Each listener runs in its own thread, so a fault in one shows
-- in the output without stopping the shot or the listeners after it.
local partBrokenListeners = {}

-- Switched off by tools/audit_loot_resettle.lua for its planted round, so it can show that what it
-- measures really does fail when nothing settles. Always on in the game.
DestructibleService.PartBrokenEnabled = true

-- A piece of road or bridge gone (broken, or fallen into a hole): told to whoever drives on the
-- roads (BotService hands it to BotNav, which closes that stretch of the network to bot drivers).
-- A road is a part named Road..., Junction... or Bridge..., or a slab in the map's Roads model.
local roadListeners = {}
function DestructibleService.OnRoadBroken(fn)
	table.insert(roadListeners, fn)
	return fn
end

local ROAD_WORDS = { "Road", "Junction", "Bridge" }
local function isRoad(part)
	for _, word in ipairs(ROAD_WORDS) do
		if string.sub(part.Name, 1, #word) == word then
			return true
		end
	end
	local node = part.Parent
	while node and node ~= workspace do
		if node.Name == "Roads" then
			return halfAlong(part, UP) * 2 <= GROUND_SLAB_THICK
		end
		node = node.Parent
	end
	return false
end
DestructibleService.IsRoad = isRoad

local function roadBroken(part)
	if #roadListeners > 0 and isRoad(part) then
		for _, listener in ipairs(roadListeners) do
			task.spawn(listener, part.Position, part.Size)
		end
	end
end

function DestructibleService.OnPartBroken(fn)
	table.insert(partBrokenListeners, fn)
	return fn
end

-- Things standing on a broken part's top: the ones in `candidates` (Models or BaseParts) whose box
-- sits over its footprint and whose underside is within `reach` of its top face.
function DestructibleService.RestingOn(cframe, size, candidates, reach)
	reach = reach or 3
	local found = {}
	for _, node in ipairs(candidates) do
		local centre, extent = nil, nil
		if node.Parent and node:IsA("Model") then
			local box, boxSize = node:GetBoundingBox()
			centre, extent = box.Position, boxSize
		elseif node.Parent and node:IsA("BasePart") then
			centre, extent = node.Position, node.Size
		end
		if centre then
			local at = cframe:PointToObjectSpace(centre)
			local bottom = at.Y - extent.Y / 2
			if math.abs(at.X) <= (size.X + extent.X) / 2 and math.abs(at.Z) <= (size.Z + extent.Z) / 2
				and bottom >= size.Y / 2 - 1 and bottom <= size.Y / 2 + reach then
				table.insert(found, node)
			end
		end
	end
	return found
end

-- Puts one thing down on whatever is under it now. Anything that turns or bobs on the client from a
-- frame it recorded (loot pickups) must be rebuilt instead — see LootService.Resettle. Returns true
-- if it moved.
function DestructibleService.SettleDown(node, maxDrop)
	local centre, extent = nil, nil
	if node.Parent and node:IsA("Model") then
		local box, boxSize = node:GetBoundingBox()
		centre, extent = box.Position, boxSize
	elseif node.Parent and node:IsA("BasePart") then
		centre, extent = node.Position, node.Size
	end
	if not centre then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { node }
	params.IgnoreWater = true
	local bottom = centre.Y - extent.Y / 2
	local hit = workspace:Raycast(Vector3.new(centre.X, bottom + 0.5, centre.Z), Vector3.new(0, -(maxDrop or 400), 0), params)
	if not hit then
		return false
	end
	local drop = hit.Position.Y - bottom
	if drop > -0.05 then
		return false
	end
	local shift = Vector3.new(0, drop, 0)
	if node:IsA("Model") then
		node:PivotTo(node:GetPivot() + shift)
	else
		node.CFrame = node.CFrame + shift
	end
	return true
end

-- Pieces broken this frame, sent to every client as one BreakFx event:
-- { cframe, size, color, material, class, from, stage } each, `stage` being how cracked it was (the
-- debris carries the cracks on). Capped per frame, biggest pools first come first served, so a
-- rocket through a street of props costs one bounded message.
local FX_PER_FRAME = 60
local pendingFx = nil

queueFx = function(part, from, stage)
	if not pendingFx then
		pendingFx = {}
		task.defer(function()
			local batch = pendingFx
			pendingFx = nil
			breakFx:FireAllClients(batch)
		end)
	end
	if #pendingFx < FX_PER_FRAME then
		table.insert(pendingFx, { part.CFrame, part.Size, part.Color, part.Material, classOf(part.Material),
			typeof(from) == "Vector3" and from or nil, stage or 0 })
	end
end

-- What broke this frame, by box, for the support pass (runSupport, below Damage).
local pendingSupport = nil
local runSupport
-- While a support pass runs, what it breaks (and whatever it had no budget left for) waits for the
-- next frame, so one pass never sets off another in the same frame.
local supportRunning, nextFrameBoxes = false, nil

local function queueSupport(cframe, size)
	if supportRunning then
		nextFrameBoxes = nextFrameBoxes or {}
		table.insert(nextFrameBoxes, { cframe, size })
		return
	end
	if not pendingSupport then
		pendingSupport = {}
		task.defer(function()
			runSupport()
		end)
	end
	table.insert(pendingSupport, { cframe, size })
end

tellBroken = function(cframe, size)
	if DestructibleService.PartBrokenEnabled then
		for _, listener in ipairs(partBrokenListeners) do
			task.spawn(listener, cframe, size)
		end
	end
	if DestructibleService.SupportEnabled then
		queueSupport(cframe, size)
	end
	if DestructibleService.ClearCoverAround then
		DestructibleService.ClearCoverAround(cframe, size)
	end
end

--------------------------------------------------------------------------------
-- LOOSE COVER (Oliver 2026-09-24: "some parts on the map are still indestructible")
--------------------------------------------------------------------------------
-- Trim neither collides nor takes a ray, so nothing can hit it; it goes with the part it hangs on
-- (dropDressing, which walks that part's siblings). Trim that hangs on nothing -- the grass, flowers,
-- ferns and shrubs the wilds scatter over the terrain, a road's markings in a folder too big to walk,
-- a light's glow -- used to go with nothing, ever: a crater opened under a meadow left the meadow
-- hanging over it. COVER is that trim: anchored, visible, not collide, not query, not in a tagged
-- pool. It is kept in a coarse grid (built once per Map, the first time it is needed, and fed by
-- DescendantAdded after), and it goes when
--   a blast reaches it and nothing solid holds it (a flower box's flowers stay while the box does)
--   the part it lay on breaks and nothing else solid holds it (the road markings on a road tile)
-- tools/destruct_coverage_probe.lua counts what is left that nothing can take down ("orphan trim").
-- (One local table for all of it: this module's main chunk sits near Luau's 200-local limit.)
local cover = { cell = 16, grid = nil, root = nil, connection = nil, params = nil }
DestructibleService.CoverCleared = 0

function cover.is(part)
	return part:IsA("BasePart") and part.Anchored and not part.CanCollide and not part.CanQuery and part.Transparency < 1
		and part.Name ~= "Rubble" and type(part:GetAttribute("Destructible")) ~= "string" and taggedModel(part) == nil
end
DestructibleService.IsCover = cover.is

function cover.add(part)
	local p = part.Position
	local key = math.floor(p.X / cover.cell) * 65536 + math.floor(p.Z / cover.cell)
	local list = cover.grid[key]
	if not list then
		list = {}
		cover.grid[key] = list
	end
	table.insert(list, part)
end

function cover.gridFor()
	local root = workspace:FindFirstChild("Map")
	if not root then
		return nil
	end
	if cover.root ~= root then
		if cover.connection then
			cover.connection:Disconnect()
		end
		cover.root, cover.grid = root, {}
		for _, part in ipairs(root:GetDescendants()) do
			if part:IsA("BasePart") and cover.is(part) then
				cover.add(part)
			end
		end
		-- (A check's stand-in Instance may have no DescendantAdded: then the grid is only rebuilt.)
		local okSignal, added = pcall(function()
			return root.DescendantAdded
		end)
		cover.connection = okSignal and added and added:Connect(function(part)
			if cover.grid and part:IsA("BasePart") and cover.is(part) then
				cover.add(part)
			end
		end) or nil
	end
	return cover.grid
end

-- Whether something solid holds a piece of cover up.
function cover.held(part)
	if not cover.params then
		cover.params = OverlapParams.new()
		cover.params.FilterType = Enum.RaycastFilterType.Include
	end
	cover.params.FilterDescendantsInstances = { cover.root }
	local reach = Vector3.new(ATTACH_MARGIN, ATTACH_MARGIN, ATTACH_MARGIN) * 2
	for _, other in ipairs(workspace:GetPartBoundsInBox(part.CFrame, part.Size + reach, cover.params)) do
		if other ~= part and other.CanCollide and other.Parent and other.Name ~= DestructibleService.GlassName then
			return true
		end
	end
	return false
end

-- Every live piece of cover whose centre lies in the box lo..hi, pruning the gone.
function cover.within(lo, hi)
	local grid = cover.gridFor()
	local found = {}
	if not grid then
		return found
	end
	for cx = math.floor(lo.X / cover.cell), math.floor(hi.X / cover.cell) do
		for cz = math.floor(lo.Z / cover.cell), math.floor(hi.Z / cover.cell) do
			local list = grid[cx * 65536 + cz]
			if list then
				for index = #list, 1, -1 do
					local part = list[index]
					if not part.Parent then
						list[index] = list[#list]
						list[#list] = nil
					else
						local p = part.Position
						if p.X >= lo.X and p.X <= hi.X and p.Z >= lo.Z and p.Z <= hi.Z and p.Y >= lo.Y and p.Y <= hi.Y then
							table.insert(found, part)
						end
					end
				end
			end
		end
	end
	return found
end

function cover.drop(parts)
	for _, part in ipairs(parts) do
		part:Destroy()
		DestructibleService.CoverCleared += 1
	end
end

-- A blast at `position`: the cover within `radius` that nothing solid holds goes.
function DestructibleService.ClearCoverInRadius(position, radius)
	local reach = Vector3.new(radius, radius, radius)
	local gone = {}
	for _, part in ipairs(cover.within(position - reach, position + reach)) do
		local half = part.Size.Magnitude / 2
		if (part.Position - position).Magnitude <= radius + half and not cover.held(part) then
			table.insert(gone, part)
		end
	end
	cover.drop(gone)
	return #gone
end

-- A part broke (its box): the cover it held that nothing else holds goes, the frame after (when the
-- part itself is gone).
function DestructibleService.ClearCoverAround(cframe, size)
	if not cover.gridFor() then
		return
	end
	task.defer(function()
		local box = { CFrame = cframe, Size = size }
		local half = (math.abs(cframe.RightVector.X) * size.X + math.abs(cframe.UpVector.X) * size.Y + math.abs(cframe.LookVector.X) * size.Z) / 2
		local halfY = (math.abs(cframe.RightVector.Y) * size.X + math.abs(cframe.UpVector.Y) * size.Y + math.abs(cframe.LookVector.Y) * size.Z) / 2
		local halfZ = (math.abs(cframe.RightVector.Z) * size.X + math.abs(cframe.UpVector.Z) * size.Y + math.abs(cframe.LookVector.Z) * size.Z) / 2
		local pad = 2
		local lo = cframe.Position - Vector3.new(half + pad, halfY + pad, halfZ + pad)
		local hi = cframe.Position + Vector3.new(half + pad, halfY + pad, halfZ + pad)
		local gone = {}
		for _, part in ipairs(cover.within(lo, hi)) do
			if attached(box, part, ATTACH_MARGIN) and not cover.held(part) then
				table.insert(gone, part)
			end
		end
		cover.drop(gone)
	end)
end

-- Switched off only by a check's planted round (tools/destruct_map_check.py), to show that its
-- floating measurement fails when nothing comes down. Always on in the game.
DestructibleService.SupportEnabled = true

-- A part coming apart: it's gone at once for everyone, and each client throws its debris.
local function shatter(part, from, stage, at, normal)
	if part.Name == DestructibleService.GlassName then
		breakPane(part, from, at, normal)
		return
	end
	tellBroken(part.CFrame, part.Size)
	roadBroken(part)
	dropDressing(part, from)
	queueFx(part, from, stage)
	part:Destroy()
end

-- A tagged pool coming apart: every member goes; the biggest few throw debris; whatever stood on
-- it is told, by the box round the whole thing.
local function shatterPool(entry, from)
	local members = {}
	for _, member in ipairs(entry.members) do
		if member.Parent then
			table.insert(members, member)
		end
	end
	if #members == 0 then
		return
	end
	tellBroken(boundsOf(members))
	table.sort(members, function(a, b)
		return a.Size.X * a.Size.Y * a.Size.Z > b.Size.X * b.Size.Y * b.Size.Z
	end)
	for index, member in ipairs(members) do
		if index <= FX_PER_POOL and member.Transparency < 0.95 and member.Name ~= DestructibleService.GlassName then
			queueFx(member, from, entry.stage)
		end
	end
	for _, member in ipairs(members) do
		if member.Parent and member.Name == DestructibleService.GlassName then
			breakPane(member, from)
		elseif member.Parent then
			member:Destroy()
		end
	end
	-- A tagged Model with nothing left in it goes too.
	local model = entry.target
	if model and model.Parent and model:IsA("Model") then
		model:Destroy()
	end
end

-- The stage a pool is at for what it has left: 0 whole, then one more at each STAGE_AT fraction.
local function stageFor(health, max)
	local fraction = health / max
	local stage = 0
	for index, at in ipairs(STAGE_AT) do
		if fraction <= at then
			stage = index
		end
	end
	return stage
end
DestructibleService.StageFor = stageFor

-- A pool reaching a new stage: the attribute clients draw its cracks from, and its colour weathered
-- a step. Only ever colour: never Transparency, on any member, at any stage (#71;
-- tools/crack_check.py holds every damage path to that).
local function setStage(entry, stage)
	entry.stage = stage
	for _, carrier in ipairs(entry.target and { entry.target } or entry.members) do
		if carrier.Parent then
			carrier:SetAttribute(STAGE_ATTRIBUTE, stage)
		end
	end
	entry.baseColors = entry.baseColors or {}
	for _, member in ipairs(entry.members) do
		local tint = member.Parent and STAGE_TINT[classOf(member.Material)]
		if tint then
			local base = entry.baseColors[member]
			if not base then
				base = member.Color
				entry.baseColors[member] = base
			end
			member.Color = base:Lerp(tint[1], tint[2] * stage)
		end
	end
end

-- A part's hit sites: opened (and the attribute rewritten) only when a hit lands clear of every
-- site already on that face, and never past the caps. Returns true if it opened one.
local function addSite(entry, part, point, face)
	entry.sites = entry.sites or {}
	entry.siteCount = entry.siteCount or 0
	local list = entry.sites[part]
	if not list then
		list = {}
		entry.sites[part] = list
	end
	for _, site in ipairs(list) do
		if site.face == face and (site.point - point).Magnitude <= SITE_MERGE then
			return false
		end
	end
	if #list >= MAX_SITES_PER_PART or entry.siteCount >= MAX_SITES_PER_POOL then
		return false
	end
	table.insert(list, { face = face, point = point })
	entry.siteCount += 1
	local codes = {}
	for _, site in ipairs(list) do
		table.insert(codes, string.format("%d,%.1f,%.1f,%.1f", site.face, site.point.X, site.point.Y, site.point.Z))
	end
	part:SetAttribute(SITES_ATTRIBUTE, table.concat(codes, ";"))
	part:AddTag(DAMAGED_TAG)
	return true
end

-- Hits this frame, one record per part (later hits on it the same frame only add to its count),
-- worked out and sent as one DamageFx event once the frame's shots are done.
local pendingHits = nil

local function flushHits()
	local batch = pendingHits
	pendingHits = nil
	local records = {}
	for _, hit in ipairs(batch.list) do
		local part = hit.part
		if part.Parent and not hit.entry.broken then
			local point, face = hitSite(part, hit.from, hit.at, hit.normal)
			if point then
				addSite(hit.entry, part, point, face)
				if #records < HITS_PER_FRAME then
					table.insert(records, { part, point, face, hit.count })
				end
			end
		end
	end
	if #records > 0 then
		damageFx:FireAllClients(records)
	end
end

local function recordHit(entry, part, from, at, normal)
	if not pendingHits then
		pendingHits = { list = {}, byPart = {} }
		task.defer(flushHits)
	end
	local hit = pendingHits.byPart[part]
	if hit then
		hit.count += 1
		return
	end
	hit = { entry = entry, part = part, from = from, at = at, normal = normal, count = 1 }
	pendingHits.byPart[part] = hit
	table.insert(pendingHits.list, hit)
end

-- BIG PARTS BREAK IN PIECES (see "a piece" in the rules above). A single-part pool bigger than
-- SUBDIVIDE_OVER along any of its axes is cut, the first time it is hit, into a grid of tiles no
-- more than TILE studs along each long axis (its short axis stays whole: a road stays one slab
-- deep), each a clone of it in place (same name, material, colour, attributes, textures; decals,
-- guis and prompts stay off the tiles), and the part itself goes. Blocks only: a wedge or a
-- cylinder is not cut. At most MAX_TILES tiles; a bigger part gets bigger tiles. Returns the tiles
-- (or nil when the part is not one to cut).
local MAX_TILES = 256
local KEEP_ON_TILE = { Texture = true, Attachment = false }
DestructibleService.Subdivided = 0

local function subdividable(part)
	if not part:IsA("Part") or part.Shape ~= Enum.PartType.Block or not part.Anchored or part.Name == DestructibleService.GlassName then
		return false
	end
	local size = part.Size
	if math.max(size.X, size.Y, size.Z) <= SUBDIVIDE_OVER then
		return false
	end
	local key, _, owner = keyOf(part)
	return key == part and owner == nil and damaged[part] == nil
end

local function subdivide(part)
	if not subdividable(part) or not mapRootOf(part) then
		return nil
	end
	local size = part.Size
	local tile = TILE
	local function count(length)
		return length > SUBDIVIDE_OVER and math.ceil(length / tile) or 1
	end
	while count(size.X) * count(size.Y) * count(size.Z) > MAX_TILES do
		tile *= 1.5
	end
	local nx, ny, nz = count(size.X), count(size.Y), count(size.Z)
	local step = Vector3.new(size.X / nx, size.Y / ny, size.Z / nz)
	local tiles = {}
	local parent = part.Parent
	-- The clone to copy from: the part without what must not repeat on every tile.
	local proto = part:Clone()
	for _, child in ipairs(proto:GetChildren()) do
		if not KEEP_ON_TILE[child.ClassName] then
			child:Destroy()
		end
	end
	proto:SetAttribute("Subdivided", true)
	for i = 1, nx do
		for j = 1, ny do
			for k = 1, nz do
				local tilePart = proto:Clone()
				tilePart.Size = step
				local offset = Vector3.new((i - 0.5) * step.X - size.X / 2, (j - 0.5) * step.Y - size.Y / 2, (k - 0.5) * step.Z - size.Z / 2)
				tilePart.CFrame = part.CFrame * CFrame.new(offset)
				tilePart.Parent = parent
				table.insert(tiles, tilePart)
			end
		end
	end
	proto:Destroy()
	forget(part)
	part:Destroy()
	DestructibleService.Subdivided += 1
	return tiles
end
DestructibleService.Subdivide = subdivide

-- The tile of `tiles` nearest a point (the one a shot struck).
local function tileAt(tiles, point)
	local best, bestDistance = tiles[1], math.huge
	for _, tilePart in ipairs(tiles) do
		local l = tilePart.CFrame:PointToObjectSpace(point)
		local h = tilePart.Size / 2
		local d = Vector3.new(math.max(0, math.abs(l.X) - h.X), math.max(0, math.abs(l.Y) - h.Y), math.max(0, math.abs(l.Z) - h.Z)).Magnitude
		if d < bestDistance then
			best, bestDistance = tilePart, d
		end
	end
	return best, bestDistance
end

-- Returns the damage actually taken. `from` (optional) is where the shot or blast came from; `at`
-- and `normal` (optional) the exact point and surface normal it struck, when the caller has them.
function DestructibleService.Damage(part, amount, attackerToken, from, at, normal)
	if amount <= 0 then
		return 0
	end
	if subdividable(part) then
		local tiles = subdivide(part)
		if tiles then
			local point = typeof(at) == "Vector3" and at or (typeof(from) == "Vector3" and from or part.Position)
			part = tileAt(tiles, point)
		end
	end
	local entry = entryFor(part)
	if not entry or entry.broken then
		return 0
	end
	if not entry.noted then
		-- A building's first hit: what it stands on is written down (the frame after), so a later
		-- break can tell a sliver of it (the support pass, below).
		entry.noted = true
		task.defer(function()
			pcall(DestructibleService.NoteBaseline, part)
		end)
	end

	local dealt = math.min(entry.health, amount)
	entry.health -= dealt

	if entry.health <= 0 then
		entry.broken = true
		if entry.tagged then
			shatterPool(entry, from)
		else
			shatter(part, from, entry.stage, at, normal)
		end
		return dealt
	end

	-- Still standing: it cracks a stage further at 75%, 50% and 25% (glass has no stages; one hit
	-- breaks it), and the hit leaves its mark where it landed.
	local stage = stageFor(entry.health, entry.max)
	if stage > entry.stage and entry.max > 1 then
		setStage(entry, stage)
	end
	recordHit(entry, part, from, at, normal)
	return dealt
end

--------------------------------------------------------------------------------
-- Nothing left in the air, and buildings fall over (see "EVERYTHING ELSE BREAKS" in the header)
--------------------------------------------------------------------------------
--
-- STRUCTURE, worked out lazily. What touches what (adjacency) is found with one box query per part
-- the first time the support pass or a building's first hit needs it, and kept until the part moves
-- or breaks; whether a part is an ANCHOR (it stands on terrain, or it never breaks: a foundation, a
-- road, a ground floor on its levelled ground, anything floating on purpose) likewise. Nothing is
-- looked at before a building is first hit.
--
-- After every break (tellBroken queues its box) the support pass looks round it:
--   HELD?      each solid part near the break is followed through what it touches until an anchor
--              turns up (SUPPORT_REACH parts at most; past that it is taken as held). A chunk with
--              no anchor in it is cut loose: it FALLS (CollapseService.Drop).
--   STANDING?  a held chunk (TOPPLE_REACH parts at most) is weighed: its centre of mass against the
--              footprint of what it stands on (the patches where its parts rest on anchors). It
--              TOPPLES over the nearest edge when its weight is past that footprint or within
--              TOPPLE_MARGIN of its edge, or when what it stands on is under TOPPLE_AREA of what it
--              stood on when it was first hit (a sliver).
-- Everything that goes with a chunk goes with it: every member of each pool in it (a thing's
-- dressing, a tree's leaves), and each part's own dressing and panes (walked in its parent, as
-- dropDressing does). Without CollapseService (a check that leaves it out) a loose chunk breaks into
-- debris instead, as it always did.

local supportParams = nil
local SUPPORT_REACH, TOPPLE_REACH = 400, 500
local TOPPLE_MARGIN, TOPPLE_AREA = 0.08, 0.3
DestructibleService.ToppleMargin, DestructibleService.ToppleArea = TOPPLE_MARGIN, TOPPLE_AREA

local okCollapse, CollapseService = pcall(function()
	return require(script.Parent:WaitForChild("CollapseService", 5))
end)
if not okCollapse or type(CollapseService) ~= "table" or type(CollapseService.Drop) ~= "function" then
	CollapseService = nil
end
DestructibleService.Collapse = CollapseService

-- Caches: weak-keyed, so a miss only costs a query again.
local adjacency = setmetatable({}, { __mode = "k" })
local anchorCache = setmetatable({}, { __mode = "k" })
-- A building's footprint when first hit: state, not a cache, so kept until the building goes.
local baseline = {}

-- Whether terrain (not water) is right under a part's underside: a short ray down from just above
-- it finds the ground within half a stud of it (a wall on a one-stud ground floor is NOT on the
-- ground: the floor is); failing that (a part sunk into the ground, where the ray starts inside the
-- terrain), the voxel half a stud under its underside is mostly solid.
local terrainParams = nil
local function onTerrain(part)
	local bottom = part.Position - Vector3.new(0, halfAlong(part, UP), 0)
	terrainParams = terrainParams or RaycastParams.new()
	terrainParams.FilterType = Enum.RaycastFilterType.Include
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	terrainParams.IgnoreWater = true
	local hit = workspace:Raycast(bottom + Vector3.new(0, 0.3, 0), Vector3.new(0, -0.9, 0), terrainParams)
	if hit and hit.Instance == workspace.Terrain then
		return true
	end
	local below = bottom - Vector3.new(0, 0.5, 0)
	local ok, materials, occupancies = pcall(function()
		return workspace.Terrain:ReadVoxels(Region3.new(below - Vector3.new(0.1, 0.1, 0.1), below + Vector3.new(0.1, 0.1, 0.1)):ExpandToGrid(4), 4)
	end)
	if not ok or not materials or not materials[1] or not materials[1][1] then
		return false
	end
	local material, occupancy = materials[1][1][1], occupancies[1][1][1]
	return material ~= nil and material ~= Enum.Material.Air and material ~= Enum.Material.Water and (occupancy or 0) > 0.3
end
DestructibleService.OnTerrain = onTerrain

-- Meant to hang in the air (an obby platform, a sign on a wire): the attribute on it or round it.
local function floatsOnPurpose(part)
	local node = part
	while node and node ~= workspace do
		if node:GetAttribute("IntentionalFloat") then
			return true
		end
		node = node.Parent
	end
	return false
end

-- Holds everything touching it up.
local function anchors(part)
	local cached = anchorCache[part]
	if cached ~= nil then
		return cached
	end
	local key, _, _, _, auto = keyOf(part)
	-- (A ground slab counts too: a floor lying on the ground or on a footing holds up what stands on
	-- it, and can no more tip over than the ground can, though it can be shot out.)
	local result = key == nil or refusalOf(part, auto) ~= nil or floatsOnPurpose(part) or onTerrain(part) or groundSlab(part)
	anchorCache[part] = result
	return result
end
DestructibleService.Anchors = anchors

local function useRoots()
	local roots = {}
	for name in pairs(ROOTS) do
		local root = workspace:FindFirstChild(name)
		if root then
			table.insert(roots, root)
		end
	end
	supportParams = supportParams or OverlapParams.new()
	supportParams.FilterType = Enum.RaycastFilterType.Include
	supportParams.FilterDescendantsInstances = roots
	return roots
end

local function solid(part)
	return part.Parent ~= nil and part.Anchored and part.CanCollide and part.Name ~= DestructibleService.GlassName
end

local function worldBox(part)
	local hx, hy, hz = halfAlong(part, EAST), halfAlong(part, UP), halfAlong(part, NORTH)
	local p = part.Position
	return p - Vector3.new(hx, hy, hz), p + Vector3.new(hx, hy, hz)
end

-- Flat and wide: a slab (a floor, a road, a paving stone, a deck, a tile of one).
local function slabLike(lo, hi)
	return hi.Y - lo.Y <= GROUND_SLAB_THICK and hi.X - lo.X >= 4 and hi.Z - lo.Z >= 4
end

-- How two touching parts hold each other up, if they do:
--   "rest"   one sits on the other (its underside at the other's top, over some of it)
--   "side"   side by side over most of a stud of their height (a wall into a wall, a floor between
--            walls, a sign on a wall)
--   "joint"  two slabs edge to edge (a floor cut into tiles, two road slabs): it carries only so far
--            (JOINT_HOPS slabs from anything resting on something), so a slab over a crater or a
--            floor with its walls gone does not hang in the air on its neighbours' edges
--   nil      only grazing (a kerb along a road, a thin trim edge): not a support at all
local JOINT_HOPS = 2
local function contactKind(a, b)
	local alo, ahi = worldBox(a)
	local blo, bhi = worldBox(b)
	local overlapX = math.min(ahi.X, bhi.X) - math.max(alo.X, blo.X)
	local overlapZ = math.min(ahi.Z, bhi.Z) - math.max(alo.Z, blo.Z)
	if overlapX > 0.05 and overlapZ > 0.05 and (math.abs(alo.Y - bhi.Y) <= 0.6 or math.abs(blo.Y - ahi.Y) <= 0.6) then
		return "rest"
	end
	local overlapY = math.min(ahi.Y, bhi.Y) - math.max(alo.Y, blo.Y)
	if slabLike(alo, ahi) and slabLike(blo, bhi) then
		return overlapY > 0.05 and "joint" or nil
	end
	if overlapY >= 0.9 then
		return "side"
	end
	return nil
end
DestructibleService.ContactKind = contactKind

-- The solid anchored parts holding this one up or held by it, with how (found once, kept until it
-- moves). Returns (list of { part, kind }, fresh query spent).
local function neighbours(part)
	local list = adjacency[part]
	if list then
		return list, 0
	end
	list = {}
	local grown = part.Size + Vector3.new(2, 2, 2) * SUPPORT_MARGIN
	for _, other in ipairs(workspace:GetPartBoundsInBox(part.CFrame, grown, supportParams)) do
		if other ~= part and solid(other) then
			local kind = contactKind(part, other)
			if kind then
				table.insert(list, { other, kind })
			end
		end
	end
	adjacency[part] = list
	return list, 1
end

-- Forgets what is known about a part's place in its structure (it is moving, or has moved).
forget = function(part)
	local list = adjacency[part]
	if list then
		for _, pair in ipairs(list) do
			adjacency[pair[1]] = nil
		end
	end
	adjacency[part] = nil
	anchorCache[part] = nil
end
DestructibleService.Forget = forget

-- Held up = joined to an anchor through parts that hold each other up (contactKind), at most
-- JOINT_HOPS slab joints in a row. Bounded search from `start`; stops at the first anchor. `memo`
-- keeps every answer for the rest of the pass. (held, searched, cost).
local function heldUp(start, memo)
	if memo[start] ~= nil then
		return memo[start], nil, 0
	end
	local hops = { [start] = 0 }
	local queue, head = { start }, 1
	local held, cost, pruned = false, 0, false
	while head <= #queue do
		local node = queue[head]
		head += 1
		cost += 1
		if memo[node] == true or anchors(node) then
			held = true
			break
		end
		if #queue > SUPPORT_REACH then
			held = true
			break
		end
		local list, spent = neighbours(node)
		cost += spent
		for _, pair in ipairs(list) do
			local other, kind = pair[1], pair[2]
			if solid(other) then
				local h = kind == "joint" and hops[node] + 1 or 0
				if h > JOINT_HOPS then
					pruned = true
				elseif hops[other] == nil or h < hops[other] then
					if hops[other] == nil then
						table.insert(queue, other)
					end
					hops[other] = h
				end
			end
		end
	end
	-- A found anchor answers for everything joined to the start without a slab joint (their way to it
	-- is the start's); anything reached across joints may have used up its hops on the way here.
	-- "Not held" is only certain for the start (a part further out may reach ground by a way the hop
	-- limit closed from here).
	if held then
		for _, node in ipairs(queue) do
			if memo[node] == nil and hops[node] == 0 then
				memo[node] = true
			end
		end
	elseif not pruned then
		-- Nothing was cut off by the hop limit: everything searched is one chunk with no anchor.
		for _, node in ipairs(queue) do
			memo[node] = false
		end
	else
		memo[start] = false
	end
	return held, queue, cost, pruned
end

-- Everything joined to `start` that is not an anchor (the chunk), and where it rests on anchors:
-- (parts, contacts {part, anchor}, cost), or nil past TOPPLE_REACH.
local function chunkOf(start)
	local seen, queue, head = { [start] = true }, { start }, 1
	local contacts, cost = {}, 0
	while head <= #queue do
		local node = queue[head]
		head += 1
		local list, spent = neighbours(node)
		cost += 1 + spent
		for _, pair in ipairs(list) do
			local other = pair[1]
			if not seen[other] and solid(other) then
				seen[other] = true
				if anchors(other) then
					table.insert(contacts, { node, other })
				else
					table.insert(queue, other)
					if #queue > TOPPLE_REACH then
						return nil, nil, cost
					end
				end
			end
		end
	end
	return queue, contacts, cost
end

-- The convex hull of points in the ground plane (x, z), counter-clockwise.
local function hull2d(points)
	table.sort(points, function(a, b)
		return a.X < b.X or (a.X == b.X and a.Y < b.Y)
	end)
	if #points < 3 then
		return points
	end
	local function cross(o, a, b)
		return (a.X - o.X) * (b.Y - o.Y) - (a.Y - o.Y) * (b.X - o.X)
	end
	local lower, upper = {}, {}
	for _, p in ipairs(points) do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do
			table.remove(lower)
		end
		table.insert(lower, p)
	end
	for index = #points, 1, -1 do
		local p = points[index]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do
			table.remove(upper)
		end
		table.insert(upper, p)
	end
	table.remove(lower)
	table.remove(upper)
	for _, p in ipairs(upper) do
		table.insert(lower, p)
	end
	return lower
end

-- How far point p lies inside the hull (negative: outside), and the nearest point on its edge.
local function insideBy(hull, p)
	if #hull < 3 then
		return -math.huge, nil
	end
	local best, nearest = math.huge, nil
	for index = 1, #hull do
		local a, b = hull[index], hull[index % #hull + 1]
		local edge = b - a
		local length = edge.Magnitude
		if length > 1e-6 then
			-- Counter-clockwise: the inside is to the left of each edge.
			local signed = (edge.X * (p.Y - a.Y) - edge.Y * (p.X - a.X)) / length
			if signed < best then
				best = signed
				local t = math.clamp((p - a):Dot(edge) / (length * length), 0, 1)
				nearest = a + edge * t
			end
		end
	end
	return best, nearest
end

-- A chunk's balance: its mass and centre of mass, and the patches where it rests on anchors.
local function balanceOf(parts, contacts)
	local mass, weighted = 0, Vector3.new(0, 0, 0)
	for _, part in ipairs(parts) do
		local m = part:GetMass()
		mass += m
		weighted += part.Position * m
	end
	if mass <= 0 then
		return nil
	end
	local com = weighted / mass
	local points, area, centroid, restY, fixed = {}, 0, Vector3.new(0, 0, 0), -math.huge, false
	for _, contact in ipairs(contacts) do
		local nlo, nhi = worldBox(contact[1])
		local alo, ahi = worldBox(contact[2])
		local resting = ahi.Y >= nlo.Y - 0.6 and ahi.Y <= nlo.Y + 0.6
		-- Fixed to it: an anchor beside it, over a stud of its height (a sign on a wall that never
		-- breaks, a porch roof into a foundation). A kerb along a wall's foot is lower than that.
		if not resting and math.min(nhi.Y, ahi.Y) - math.max(nlo.Y, alo.Y) >= 1 then
			fixed = true
		end
		-- Resting on it: the anchor's top at the part's underside.
		if resting then
			local x0, x1 = math.max(nlo.X, alo.X), math.min(nhi.X, ahi.X)
			local z0, z1 = math.max(nlo.Z, alo.Z), math.min(nhi.Z, ahi.Z)
			if x1 > x0 and z1 > z0 then
				local a = (x1 - x0) * (z1 - z0)
				area += a
				centroid += Vector3.new((x0 + x1) / 2, 0, (z0 + z1) / 2) * a
				restY = math.max(restY, ahi.Y)
				for _, corner in ipairs({ Vector2.new(x0, z0), Vector2.new(x1, z0), Vector2.new(x1, z1), Vector2.new(x0, z1) }) do
					table.insert(points, corner)
				end
			end
		end
	end
	if area <= 0 then
		return nil, fixed
	end
	return { mass = mass, com = com, area = area, centroid = centroid / area, hull = hull2d(points), restY = restY, fixed = fixed }
end
DestructibleService.BalanceOf = balanceOf

-- The Model a chunk is a building of: where its biggest part sits.
local function structureOf(parts)
	local biggest, volume = nil, -1
	for _, part in ipairs(parts) do
		local v = part.Size.X * part.Size.Y * part.Size.Z
		if v > volume then
			biggest, volume = part, v
		end
	end
	return biggest and biggest.Parent or nil
end

-- Whether a held chunk stands badly: (topple spec or nil, why).
local function judge(parts, contacts)
	local balance = balanceOf(parts, contacts)
	if not balance or balance.fixed then
		-- Hanging off the side of an anchor, or fixed to one: it stays as long as that does.
		return nil, "fixed"
	end
	local structure = structureOf(parts)
	local first = structure and baseline[structure]
	if structure and not first then
		first = cacheUntil(baseline, structure, balance.area)
	end
	local p = Vector2.new(balance.com.X, balance.com.Z)
	local inside, nearest = insideBy(balance.hull, p)
	local size = math.sqrt(balance.area)
	local why = nil
	if inside < 0 then
		why = "weight past its footprint"
	elseif inside < TOPPLE_MARGIN * size then
		why = "weight at the edge of its footprint"
	elseif first and balance.area < TOPPLE_AREA * first then
		why = string.format("standing on %.0f%% of what it stood on", balance.area / first * 100)
	end
	if not why then
		return nil, "stands"
	end
	local lean
	if nearest and inside < TOPPLE_MARGIN * size then
		local towards = p - nearest
		lean = inside < 0 and towards or -towards
		if lean.Magnitude < 1e-3 then
			lean = p - Vector2.new(balance.centroid.X, balance.centroid.Z)
		end
	else
		lean = p - Vector2.new(balance.centroid.X, balance.centroid.Z)
	end
	if lean.Magnitude < 1e-3 then
		lean = Vector2.new(1, 0)
	end
	local pivot = nearest and Vector3.new(nearest.X, balance.restY, nearest.Y) or Vector3.new(balance.centroid.X, balance.restY, balance.centroid.Z)
	return { direction = Vector3.new(lean.X, 0, lean.Y).Unit, pivot = pivot, why = why }, why
end
DestructibleService.Judge = judge

-- A building's footprint written down on its first hit (lazily, the frame after), so "a sliver of
-- what it stood on" has something to be a sliver of.
local function noteBaseline(part)
	if not part.Parent or not part.Anchored or anchors(part) then
		return
	end
	useRoots()
	local parts, contacts, _cost = chunkOf(part)
	if parts then
		local structure = structureOf(parts)
		if structure and not baseline[structure] then
			local balance = balanceOf(parts, contacts)
			if balance then
				cacheUntil(baseline, structure, balance.area)
			end
		end
	end
end
DestructibleService.NoteBaseline = noteBaseline

-- Everything that goes with a set of solid parts: their pools' members, and their own dressing and
-- panes in their parents (up to DRESSING_SCAN siblings each).
local function gather(parts)
	local out, seen = {}, {}
	local function add(part)
		if part and part.Parent and not seen[part] then
			seen[part] = true
			table.insert(out, part)
		end
	end
	local byParent = {}
	for _, part in ipairs(parts) do
		add(part)
		local key, _, owner = keyOf(part)
		if key ~= nil and owner ~= nil then
			local entry = damaged[key]
			for _, member in ipairs(entry and entry.members or membersOf(key, part, owner)) do
				add(member)
			end
		end
		if part.Parent then
			byParent[part.Parent] = byParent[part.Parent] or {}
			table.insert(byParent[part.Parent], part)
		end
	end
	for parent, hosts in pairs(byParent) do
		local children = parent:GetChildren()
		if #children <= DRESSING_SCAN or CARRIES_DRESSING[hosts[1].Name] then
			for _, child in ipairs(children) do
				if child:IsA("BasePart") and not seen[child] and child.Anchored then
					local glass = child.Name == DestructibleService.GlassName
					if glass or isTrim(child) then
						for _, host in ipairs(hosts) do
							if attached(host, child, glass and PANE_MARGIN or ATTACH_MARGIN) then
								add(child)
								break
							end
						end
					end
				end
			end
		end
	end
	return out
end
DestructibleService.Gather = gather

-- A part the support pass has given up on: without CollapseService it breaks, the old way.
local function breakLoose(part)
	if not part.Parent then
		return
	end
	local entry = entryFor(part)
	if entry and not entry.broken then
		entry.broken = true
		entry.health = 0
		if entry.tagged then
			shatterPool(entry, nil)
		else
			shatter(part, nil, entry.stage)
		end
	elseif part.Parent then
		-- Dressing or glass with no pool of its own.
		if part.Name == DestructibleService.GlassName then
			breakPane(part, nil)
		else
			queueFx(part, nil)
			part:Destroy()
		end
	end
end

DestructibleService.SupportStats = { passes = 0, checks = 0, fell = 0, toppled = 0, worst = 0 }

-- For the checks, the probes and the coverage audit: whether a part is held up right now, and how its
-- chunk stands: (held, parts in its chunk, verdict, balance).
function DestructibleService.HeldUp(part)
	useRoots()
	return (heldUp(part, {}))
end

function DestructibleService.Standing(part)
	useRoots()
	if not heldUp(part, {}) then
		return false, 0, "loose"
	end
	if anchors(part) then
		return true, 0, "anchor"
	end
	local parts, contacts = chunkOf(part)
	if not parts then
		return true, -1, "too big to weigh"
	end
	local _, why = judge(parts, contacts)
	return true, #parts, why, balanceOf(parts, contacts)
end

local supportPass

runSupport = function()
	local boxes = pendingSupport
	pendingSupport = nil
	if not boxes then
		return
	end
	supportRunning = true
	local ok, problem = pcall(supportPass, boxes)
	supportRunning = false
	if not ok then
		warn("[DestructibleService] support pass failed: " .. tostring(problem))
	end
	if nextFrameBoxes then
		local carry = nextFrameBoxes
		nextFrameBoxes = nil
		task.delay(0, function()
			for _, box in ipairs(carry) do
				queueSupport(box[1], box[2])
			end
		end)
	end
end

supportPass = function(boxes)
	-- CPU spent (os.clock is CPU time: what this costs the server, not when it happened).
	local cpuAtStart = os.clock()
	local roots = useRoots()
	if #roots == 0 then
		return
	end
	local stats = DestructibleService.SupportStats
	stats.passes += 1
	local memo, judged, cost, drops = {}, {}, 0, 0
	local function drop(parts, topple)
		drops += 1
		for _, part in ipairs(parts) do
			roadBroken(part)
		end
		local all = gather(parts)
		if CollapseService then
			local how = CollapseService.Drop(all, topple)
			if how == "toppled" then
				stats.toppled += 1
			else
				stats.fell += 1
			end
		else
			stats.fell += 1
			for _, part in ipairs(all) do
				breakLoose(part)
			end
		end
	end
	for index, box in ipairs(boxes) do
		if cost >= SUPPORT_CHECKS or drops >= SUPPORT_FALLS then
			-- Over budget: this box and the rest go round again next frame.
			for rest = index, #boxes do
				queueSupport(boxes[rest][1], boxes[rest][2])
			end
			break
		end
		local around = workspace:GetPartBoundsInBox(box[1], box[2] + Vector3.new(2, 2, 2) * SUPPORT_MARGIN, supportParams)
		for _, part in ipairs(around) do
			-- Whatever touched the part that went has lost a neighbour.
			if adjacency[part] then
				adjacency[part] = nil
			end
		end
		for _, part in ipairs(around) do
			if solid(part) and memo[part] == nil and not judged[part] then
				local held, searched, spent, pruned = heldUp(part, memo)
				cost += spent
				if not held and searched then
					local loose = {}
					for _, p in ipairs(searched) do
						-- Past the slab-joint limit some of these may yet be held another way: asked
						-- one by one (the start is already known not to be).
						local looseToo = p == part or not pruned
						if not looseToo and cost < SUPPORT_CHECKS then
							local ok, _, more = heldUp(p, memo)
							cost += more
							looseToo = not ok
						end
						if looseToo and p.Parent and p.Anchored then
							table.insert(loose, p)
						end
					end
					drop(loose, nil)
				elseif held and not anchors(part) then
					local parts, contacts, spentChunk = chunkOf(part)
					cost += spentChunk
					if parts then
						for _, p in ipairs(parts) do
							judged[p] = true
						end
						local topple = judge(parts, contacts)
						if topple then
							drop(parts, topple)
						end
					end
				end
			end
		end
	end
	stats.checks += cost
	stats.worst = math.max(stats.worst, os.clock() - cpuAtStart)
end

--------------------------------------------------------------------------------
-- The ground (Oliver 2026-09-24: "the ground breaks too", "make sure you can't blow a hole in the
-- map and fall through", "make the craters be able to get pretty deep")
--------------------------------------------------------------------------------
--
-- A blast that goes off on open ground digs, and a bowl that keeps being hit keeps deepening. Each
-- blast takes the bowl under it DEEPEN x its crater size deeper (craterSize: off the weapon's blast
-- reach and wall damage, so a rocket digs deeper than a grenade, a grenade than a drumlet), down to
-- DIG_DEPTH under the ground as the map built it. The ground goes for everyone (Terrain:FillCylinder
-- with Air, which the engine replicates). Bullets never write terrain: they only scuff it, on each
-- client (CombatClient's bullet marks, through GroundFx). The server sends one CraterFx event per
-- crater, { surface, radius, material, normal, depth }, for the clods, dust, torn turf and spray.
--
-- A BOWL, NEVER A SHAFT: you can always get out. Every crater is a cone: a flat floor FLOOR_RADIUS
-- across, then walls rising a stud for every WALL_RUN out (1 in 2, 27 degrees: walkable on
-- foot and drivable; a humanoid walks slopes to 89 and a vehicle climbs 35), carved as stacked
-- STEP_UP-stud rings that the terrain smooths into a slope. A deeper bowl is a WIDER bowl: 24 deep is
-- 45 studs out at the rim. It stops short of anything standing within its rim that is taller than
-- LIMIT_TALL (a wall, a tree, a post: it would undermine it); a slab on the ground there (a road, a
-- floor, paving) is dug out from under and comes down into the hole (the support pass).
--
-- DIG_DEPTH is 24: four bodies deep, so a player at the bottom is out of the fire of anyone on flat
-- ground not at its rim, and its 45-stud rim still fits between the blocks of a town. Under it the
-- ground is 45 studs thick or more everywhere a match is played (MapGenerator lays it 72 deep; the
-- deepest the relief, river and lakes cut is about 20; tools/ground_probe.lua measured the thinnest
-- at 69), and at least BEDROCK must remain under the floor or nothing is dug there at all.
--
-- NO HOLE IN THE MAP, in layers:
--   (a) the DIG FLOOR and BEDROCK. The first crater near a spot writes down the height of every
--       4-stud cell under its bowl BEFORE it digs (originalSurface), so later craters find the floor
--       where the ground first was. The bowl's floor is raised wherever its cone would pass a cell's
--       floor (the ground there as built, less DIG_DEPTH); a blast that can't take it a stud deeper
--       digs nothing ("bottomed out"). Terrain under the floor is never written: it is the bedrock.
--   (b) a ground floor has the levelled terrain (MapTerrain.FlattenPad) right under it, and a road or
--       a slab over terrain breaks into a hole onto that terrain, which can then be cratered.
--   (c) water, and the map's EDGE (a cell within the rim with no terrain under it: the end of the
--       world), are never dug: the rim is pulled in short of them.
--   (d) the safety net (Rescue, below): anyone found under WORLD_FLOOR_Y is put back on the ground
--       above where they fell, unhurt.

local CRATER_CAP = 400
local CRATER_BURST, CRATER_WINDOW = 16, 1
local CRATER_FROM_REACH, CRATER_FROM_DAMAGE = 0.55, 1 / 60
local CRATER_MIN, CRATER_MAX = 1.5, 7
local DIG_DEPTH, BEDROCK = 24, 16
local DEEPEN = 0.8
local FLOOR_RADIUS, WALL_RUN, STEP_UP = 2.5, 2, 2
local LIMIT_TALL = 3
local CELL = 4
local NO_CRATER = { [Enum.Material.Water] = true }
DestructibleService.CraterCap = CRATER_CAP
DestructibleService.DigDepth, DestructibleService.Bedrock = DIG_DEPTH, BEDROCK
DestructibleService.CraterMax = CRATER_MAX
DestructibleService.WallRun = WALL_RUN

local craterFx = Remotes.Event("CraterFx")

-- A weapon's crater size from its blast: the reach its walls take damage in (half its blast
-- radius) and its wall damage. A rocket (150 at reach ~7) about 6.4; a grenade about 5; a drumlet
-- about 2.3; the smallest thing that digs at all 1.5. A blast deepens its bowl by DEEPEN of it.
local function craterSize(reach, damage)
	return math.clamp(CRATER_FROM_REACH * (reach or 0) + CRATER_FROM_DAMAGE * (damage or 0), CRATER_MIN, CRATER_MAX)
end
DestructibleService.CraterSize = craterSize

-- One map's digging: how many craters, the recent burst, and the ground as it was built, per cell.
local ground = { map = nil, count = 0, burst = {}, original = {} }
DestructibleService.GroundState = ground

local downParams, upParams = nil, nil
local function terrainRay(origin, direction)
	downParams = downParams or RaycastParams.new()
	downParams.FilterType = Enum.RaycastFilterType.Include
	downParams.FilterDescendantsInstances = { workspace.Terrain }
	downParams.IgnoreWater = true
	return workspace:Raycast(origin, direction, downParams)
end

-- The ground's height at a cell as the map built it (written down the first time any crater comes
-- near it, before that crater digs), or nil where there is no ground (off the map's edge).
local function originalSurface(cx, cz, above)
	local key = cx .. ":" .. cz
	local height = ground.original[key]
	if height == nil then
		local x, z = (cx + 0.5) * CELL, (cz + 0.5) * CELL
		local hit = terrainRay(Vector3.new(x, above + 120, z), Vector3.new(0, -500, 0))
		height = hit and hit.Position.Y or false
		ground.original[key] = height
	end
	return height or nil
end
DestructibleService.OriginalSurface = originalSurface

-- The underside of the terrain at (x, z): a ray up from under the world.
local function terrainUnderside(x, z)
	upParams = upParams or RaycastParams.new()
	upParams.FilterType = Enum.RaycastFilterType.Include
	upParams.FilterDescendantsInstances = { workspace.Terrain }
	upParams.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(x, -600, z), Vector3.new(0, 700, 0), upParams)
	return hit and hit.Position.Y or nil
end
DestructibleService.TerrainUnderside = terrainUnderside

-- Any water in the box round a bowl?
local function waterNear(centre, radius, depth)
	local reach = radius + 2
	local ok, materials = pcall(function()
		return workspace.Terrain:ReadVoxels(Region3.new(centre - Vector3.new(reach, depth + 2, reach), centre + Vector3.new(reach, 4, reach)):ExpandToGrid(4), 4)
	end)
	if not ok or not materials then
		return true
	end
	for x = 1, #materials do
		for y = 1, #materials[x] do
			for z = 1, #materials[x][y] do
				if materials[x][y][z] == Enum.Material.Water then
					return true
				end
			end
		end
	end
	return false
end

-- What a crater changes the ground under: forgotten, so the support pass sees it as it is now.
local function forgetAround(centre, radius, map)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(centre), Vector3.new(radius * 2 + 2, 60, radius * 2 + 2), params)) do
		forget(part)
		slabCache[part] = nil
		voidCache[part] = nil
	end
end

-- Digs (deeper) the bowl a blast at `position` makes, if it may: (dug, why not / how deep now).
local function craterAt(position, reach, damage, map)
	if ground.map ~= map then
		ground.map, ground.count, ground.burst, ground.original = map, 0, {}, {}
	end
	if ground.count >= CRATER_CAP then
		return false, "cap"
	end
	-- Wall clock (tick): os.clock is CPU time in Roblox, and time() stands still in edit mode.
	local clock = tick()
	for index = #ground.burst, 1, -1 do
		if clock - ground.burst[index] > CRATER_WINDOW then
			table.remove(ground.burst, index)
		end
	end
	if #ground.burst >= CRATER_BURST then
		return false, "burst"
	end
	local size = craterSize(reach, damage)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map, workspace.Terrain }
	params.IgnoreWater = false
	local hit = workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -(size + 2), 0), params)
	if not hit or hit.Instance ~= workspace.Terrain then
		return false, "not open ground"
	end
	if NO_CRATER[hit.Material] then
		return false, "water"
	end
	local surface = hit.Position
	local original = originalSurface(math.floor(surface.X / CELL), math.floor(surface.Z / CELL), surface.Y)
	if not original then
		return false, "map edge"
	end
	-- How deep this blast would take the bowl under it, then everything that holds it shallower.
	local depthNow = math.max(0, original - surface.Y)
	local target = math.min(DIG_DEPTH, depthNow + size * DEEPEN)
	local function rimOf(depth)
		return FLOOR_RADIUS + depth * WALL_RUN
	end
	-- (a) + (c): every cell under the rim: its own floor, and the edge of the world.
	local reachOut = rimOf(target)
	local lowX, highX = math.floor((surface.X - reachOut) / CELL), math.floor((surface.X + reachOut) / CELL)
	local lowZ, highZ = math.floor((surface.Z - reachOut) / CELL), math.floor((surface.Z + reachOut) / CELL)
	for cx = lowX, highX do
		for cz = lowZ, highZ do
			local nx = math.max(0, math.abs(surface.X - (cx + 0.5) * CELL) - CELL / 2)
			local nz = math.max(0, math.abs(surface.Z - (cz + 0.5) * CELL) - CELL / 2)
			local near = math.sqrt(nx * nx + nz * nz)
			if near < rimOf(target) then
				local here = originalSurface(cx, cz, surface.Y)
				if not here then
					-- The edge of the world: the rim stays a stud short of it.
					target = math.min(target, (near - 1 - FLOOR_RADIUS) / WALL_RUN)
				else
					-- The cone's bottom over this cell is (original - target) + (near - FLOOR_RADIUS) /
					-- WALL_RUN; it may not pass the cell's floor.
					local rise = math.max(0, near - FLOOR_RADIUS) / WALL_RUN
					target = math.min(target, original - (here - DIG_DEPTH) + rise)
				end
			end
		end
	end
	-- Anything tall standing inside the rim holds it back.
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { map }
	local box = rimOf(target) * 2
	for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.new(surface + Vector3.new(0, 3, 0)), Vector3.new(box, 8, box), overlap)) do
		if part.Anchored and part.CanCollide and halfAlong(part, UP) * 2 >= LIMIT_TALL then
			local l = part.Position - surface
			local reachX, reachZ = halfAlong(part, EAST), halfAlong(part, NORTH)
			local dx, dz = math.max(0, math.abs(l.X) - reachX), math.max(0, math.abs(l.Z) - reachZ)
			local distance = math.sqrt(dx * dx + dz * dz)
			target = math.min(target, (distance - 1 - FLOOR_RADIUS) / WALL_RUN)
		end
	end
	if target < depthNow + 0.75 then
		return false, "bottomed out"
	end
	local apexY = original - target
	local rim = rimOf(target)
	if waterNear(Vector3.new(surface.X, surface.Y, surface.Z), rim, target) then
		return false, "water"
	end
	local underside = terrainUnderside(surface.X, surface.Z)
	if not underside or apexY - underside < BEDROCK then
		return false, "thin ground"
	end
	ground.count += 1
	table.insert(ground.burst, clock)
	-- Whatever lay on the ground there (loot, a supply crate) settles into the hole; the slabs dug out
	-- from under come down (the support pass, after the dig).
	local top = math.max(surface.Y, original) + STEP_UP
	local layers = math.ceil((top - apexY) / STEP_UP)
	for layer = 0, layers - 1 do
		local y0 = apexY + layer * STEP_UP
		workspace.Terrain:FillCylinder(CFrame.new(surface.X, y0 + STEP_UP / 2, surface.Z), STEP_UP, FLOOR_RADIUS + layer * STEP_UP * WALL_RUN, Enum.Material.Air)
	end
	forgetAround(surface, rim, map)
	tellBroken(CFrame.new(Vector3.new(surface.X, (apexY + top) / 2, surface.Z)), Vector3.new(rim * 2, top - apexY + 2, rim * 2))
	craterFx:FireAllClients({ surface, math.max(size, FLOOR_RADIUS + (target - depthNow) * WALL_RUN), hit.Material, hit.Normal, target })
	return true, target
end
DestructibleService.CraterAt = craterAt

-- Each pool once per blast, however many of its parts the blast reaches: a tree is one tree, not
-- one hit per leaf. Then the ground under it, if it is open ground.
function DestructibleService.DamageInRadius(position, radius, amount, attackerToken)
	local roots = {}
	for name in pairs(ROOTS) do
		local root = workspace:FindFirstChild(name)
		if root then
			table.insert(roots, root)
		end
	end
	if #roots == 0 then
		return
	end
	local region = OverlapParams.new()
	region.FilterType = Enum.RaycastFilterType.Include
	region.FilterDescendantsInstances = roots
	local seen = {}
	local hits = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, region)) do
		-- A big part is cut first, and only its tiles in reach are hurt: a blast holes a road.
		local tiles = subdividable(part) and subdivide(part)
		if tiles then
			for _, tilePart in ipairs(tiles) do
				local _, distance = tileAt({ tilePart }, position)
				if distance <= radius then
					table.insert(hits, tilePart)
				end
			end
		else
			table.insert(hits, part)
		end
	end
	for _, part in ipairs(hits) do
		local key = part.Parent and keyOf(part)
		if key and not seen[key] then
			seen[key] = true
			-- The map's structure (not a tagged prop) takes a blast STRUCTURE.blast times over.
			local entry = entryFor(part)
			local scaled = (entry and not entry.tagged) and amount * STRUCTURE.blast or amount
			DestructibleService.Damage(part, scaled, attackerToken, position)
		end
	end
	-- The loose cover it reaches (grass, flowers, markings nothing solid holds) goes with it.
	DestructibleService.ClearCoverInRadius(position, radius)
	local map = workspace:FindFirstChild("Map")
	if map then
		craterAt(position, radius, amount, map)
	end
end

--------------------------------------------------------------------------------
-- (d) The safety net: nobody stays under the world
--------------------------------------------------------------------------------

-- The terrain's underside is 72 studs under the surface (about -74); under WORLD_FLOOR_Y is under the
-- world, whatever put them there. Checked RESCUE_EVERY for every combatant (players and bots).
local WORLD_FLOOR_Y = -90
local RESCUE_EVERY = 0.25
local RESCUE_STEP, RESCUE_TRIES = 24, 80
DestructibleService.WorldFloorY = WORLD_FLOOR_Y
DestructibleService.Rescued = 0

local rescueParams = nil
-- The ground (or anything standing in a match root) straight above/below a point, from high up; if
-- there is none there, the nearest ground walking back toward the middle of the map.
local function groundNear(position)
	rescueParams = rescueParams or RaycastParams.new()
	rescueParams.FilterType = Enum.RaycastFilterType.Include
	local include = { workspace.Terrain }
	for name in pairs(ROOTS) do
		local root = workspace:FindFirstChild(name)
		if root then
			table.insert(include, root)
		end
	end
	rescueParams.FilterDescendantsInstances = include
	rescueParams.IgnoreWater = false
	local flat = Vector3.new(position.X, 0, position.Z)
	local inward = flat.Magnitude > 1 and -flat.Unit or Vector3.new(0, 0, 0)
	for try = 0, RESCUE_TRIES do
		local at = flat + inward * (try * RESCUE_STEP)
		local hit = workspace:Raycast(Vector3.new(at.X, 1200, at.Z), Vector3.new(0, -1400, 0), rescueParams)
		if hit and hit.Position.Y > WORLD_FLOOR_Y then
			return hit.Position
		end
		if inward.Magnitude == 0 then
			break
		end
	end
	return nil
end
DestructibleService.GroundNear = groundNear

-- Puts a character that is under the world back on the ground above it, still and unhurt (the game
-- has no fall damage; its speed is zeroed so it doesn't land hard either). Returns true if it moved.
function DestructibleService.Rescue(character)
	if typeof(character) ~= "Instance" or not character.Parent then
		return false
	end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root or root.Position.Y > WORLD_FLOOR_Y then
		return false
	end
	local spot = groundNear(root.Position)
	if not spot then
		return false
	end
	local ok, sanity = pcall(require, script.Parent:FindFirstChild("MovementSanity"))
	if ok and type(sanity) == "table" and sanity.Expect then
		local player = game:GetService("Players"):GetPlayerFromCharacter(character)
		pcall(sanity.Expect, player or character, 1.5)
	end
	local _, yaw, _ = root.CFrame:ToOrientation()
	character:PivotTo(CFrame.new(spot + Vector3.new(0, 4, 0)) * CFrame.Angles(0, yaw, 0))
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
		end
	end
	DestructibleService.Rescued += 1
	return true
end

do
	local RunService = game:GetService("RunService")
	local Combatants = nil
	local since = 0
	RunService.Heartbeat:Connect(function(dt)
		since += dt
		if since < RESCUE_EVERY then
			return
		end
		since = 0
		if Combatants == nil then
			local ok, found = pcall(require, script.Parent:FindFirstChild("Combatants"))
			Combatants = ok and type(found) == "table" and found or false
		end
		if Combatants and Combatants.All then
			for character in pairs(Combatants.All()) do
				pcall(DestructibleService.Rescue, character)
			end
		end
		for _, player in ipairs(game:GetService("Players"):GetPlayers()) do
			if player.Character then
				pcall(DestructibleService.Rescue, player.Character)
			end
		end
	end)
end

-- How many are damaged but still standing (for the build check).
function DestructibleService.Count()
	local count = 0
	for _, entry in pairs(damaged) do
		if not entry.broken and entry.members[1] and entry.members[1].Parent then
			count += 1
		end
	end
	return count
end

CombatService.DestructibleFromPart = DestructibleService.FromPart
CombatService.DestructiblePassesThrough = DestructibleService.PassesThrough
-- `at` and `normal` (optional): where the shot struck and the surface there, so the crack opens
-- where the bullet went in rather than on the part's nearest point to the shooter.
CombatService.DamageDestructible = function(shooterToken, part, amount, from, at, normal)
	local point = typeof(at) == "Vector3" and at or part.Position
	local dealt = DestructibleService.Damage(part, amount, shooterToken, from, at, normal)
	-- "structure": the HUD marks a hit on the map differently from a hit on a person.
	CombatService.ConfirmHit(shooterToken, dealt, false, point, "structure")
	return dealt
end
CombatService.DamageDestructiblesInRadius = DestructibleService.DamageInRadius

if CollapseService then
	local Combatants = nil
	CollapseService.Init({
		breakPart = breakLoose,
		queueFx = queueFx,
		tellBroken = tellBroken,
		damagePart = function(part, amount, from)
			return DestructibleService.Damage(part, amount, nil, from)
		end,
		roots = useRoots,
		forget = forget,
		combatants = function()
			if Combatants == nil then
				local ok, found = pcall(require, script.Parent:FindFirstChild("Combatants"))
				Combatants = ok and type(found) == "table" and found or false
			end
			return Combatants and Combatants.All and Combatants.All() or {}
		end,
		dealDamage = function(token, amount)
			if CombatService.DealDamage then
				CombatService.DealDamage(nil, token, amount, "Rubble")
			end
		end,
	})
end

return DestructibleService
