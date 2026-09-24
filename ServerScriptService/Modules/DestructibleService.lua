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
}
DestructibleService.Kinds = KINDS

-- Material families: how tough each is, and what BreakFxClient throws when it goes.
local CLASS_OF = {
	[Enum.Material.Wood] = "wood", [Enum.Material.WoodPlanks] = "wood",
	[Enum.Material.Brick] = "stone", [Enum.Material.Concrete] = "stone", [Enum.Material.Slate] = "stone",
	[Enum.Material.Rock] = "stone", [Enum.Material.Cobblestone] = "stone", [Enum.Material.Granite] = "stone",
	[Enum.Material.Marble] = "stone", [Enum.Material.Pebble] = "stone", [Enum.Material.Basalt] = "stone",
	[Enum.Material.Limestone] = "stone", [Enum.Material.Sandstone] = "stone", [Enum.Material.Pavement] = "stone",
	[Enum.Material.Asphalt] = "stone", [Enum.Material.CrackedLava] = "stone",
	[Enum.Material.Metal] = "metal", [Enum.Material.DiamondPlate] = "metal", [Enum.Material.CorrodedMetal] = "metal",
	[Enum.Material.Foil] = "metal",
	[Enum.Material.Grass] = "foliage", [Enum.Material.LeafyGrass] = "foliage", [Enum.Material.Ground] = "foliage",
	[Enum.Material.Fabric] = "cloth",
	[Enum.Material.Glass] = "glass", [Enum.Material.Ice] = "glass", [Enum.Material.Neon] = "glass",
}
local CLASS_TOUGHNESS = { stone = 2, metal = 1.6, wood = 1, plastic = 1, foliage = 0.55, cloth = 0.4, glass = 0.3 }

local function classOf(material)
	return CLASS_OF[material] or "plastic"
end
DestructibleService.ClassOf = classOf

-- health = toughness(material) * (BASE + PER_STUD * size) * kind, where size is the cube root of the
-- pool's solid volume (capped): a bench about 55, an oak about 120, a boulder about 200, a parked car
-- about 280. A rocket's wallDamage is 110-150, a rifle round 20-40.
local HEALTH_BASE, HEALTH_PER_STUD, SIZE_CAP = 20, 14, 12
local MIN_HEALTH, MAX_HEALTH = 15, 1500

-- Never breakable, by the part's own name or any ancestor's inside the Map.
local NEVER = {
	Asphalt = true, Kerb = true, Paving = true, Road = true, Street = true, Junction = true, Crossing = true,
	Bridge = true, Deck = true, Footbridge = true, SteppingStone = true,
	Ground = true, Footing = true, Foundation = true, Plinth = true, Pad = true,
	SpawnLocation = true, Spawn = true, Lobby = true, Storm = true, Objective = true, Zipline = true,
}
DestructibleService.Never = NEVER
-- A tagged pool wider than this is somebody's floor, not a prop.
local MAX_POOL_SPAN = 90
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
-- How far apart two parts may be and still count as attached: trim sits a hair off its wall.
local ATTACH_MARGIN = 0.35
-- A pane only overlaps the wall bands round its opening by a tenth of a stud.
local PANE_MARGIN = 0.02

local glassShatter = Remotes.Event("GlassShatter")
local breakFx = Remotes.Event("BreakFx")

-- Anything inside these is fair game; anything else on the map is scenery and stays put.
local ROOTS = { Map = true }

-- pool key -> { health, max, broken, members, target }. The key is the part (a single part), the
-- Model (a tagged Model) or the tag string (a group). Strong keys, dropped when the pool's first
-- member is destroyed: a weak-keyed table loses live Instances, since Roblox collects an instance's
-- Lua handle whenever nothing but a weak table holds it.
local damaged = {}

-- The Map this part stands in, or nil if it's outside one or anything on the way is off limits.
local function mapRootOf(part)
	if NEVER[part.Name] then
		return nil
	end
	local node = part.Parent
	while node and node.Parent ~= workspace do
		if NEVER[node.Name] then
			return nil
		end
		node = node.Parent
	end
	if not node or node.Parent ~= workspace or not ROOTS[node.Name] then
		return nil
	end
	return node
end

local function positiveNumber(value)
	return type(value) == "number" and value > 0 and value or nil
end

-- The nearest Model above `part` (inside the Map) tagged as one pool, if any.
local function taggedModel(part)
	local node = part.Parent
	while node and node.Parent ~= workspace do
		if node:IsA("Model") then
			local tag = node:GetAttribute("Destructible")
			if tag == false then
				return nil, true
			elseif type(tag) == "string" or positiveNumber(node:GetAttribute("DestructibleHealth")) then
				return node
			end
		end
		node = node.Parent
	end
	return nil
end

-- Which pool a part belongs to, cheaply (no search): (key, kind, owner, explicit health) or nil.
-- The key is the part itself, the tagged Model, or the group's tag string; `owner` is where the
-- members are found (the Model, or the part's parent for a group), nil for a pool of one.
local function keyOf(part)
	if not part or not part:IsA("BasePart") or not part.Anchored then
		return nil
	end
	-- A window pane is always its own pool of one, even in a tagged cabin: glass breaks at a touch.
	if part.Name == DestructibleService.GlassName then
		return (part.CanCollide and mapRootOf(part)) and part or nil, nil, nil, HEALTH[part.Name]
	end
	local tag = part:GetAttribute("Destructible")
	if tag == false then
		return nil
	end
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
	local model, refused = taggedModel(part)
	if refused then
		return nil
	end
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
			return part, nil, nil, own or HEALTH[part.Name]
		end
	end
	return nil
end
DestructibleService.KeyOf = keyOf

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
local function poolHealth(kind, members)
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
	local health = CLASS_TOUGHNESS[classOf(biggest.Material)] * (HEALTH_BASE + HEALTH_PER_STUD * scale) * (KINDS[kind] or 1)
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

-- The pool entry for a part, made on its first hit; nil if the part can't be broken.
local function entryFor(part)
	local key, kind, owner, explicit = keyOf(part)
	if not key then
		return nil
	end
	local entry = damaged[key]
	if entry then
		return entry, key
	end
	-- Only things standing on the map itself, so lobby furniture and deployables are untouched.
	if not mapRootOf(part) then
		return nil
	end
	local tagged = kind ~= nil
	local members = membersOf(key, part, owner)
	local max = explicit
	if tagged then
		local _, span = boundsOf(members)
		if math.max(span.X, span.Z) > MAX_POOL_SPAN then
			return nil
		end
		max = max or poolHealth(kind, members)
	end
	if type(max) ~= "number" or max <= 0 then
		return nil
	end
	entry = { health = max, max = max, members = members, tagged = tagged,
		target = typeof(key) == "Instance" and key:IsA("Model") and key or nil }
	damaged[key] = entry
	-- Dropped when the pool's anchor goes: the part itself, the Model, or the group's first member.
	local anchor = typeof(key) == "Instance" and key or members[1]
	anchor.Destroying:Connect(function()
		if damaged[key] == entry then
			damaged[key] = nil
		end
	end)
	return entry, key
end

-- Answers without looking anything up beyond the part and its parents: whether it is worth
-- sending the hit here. (An oversized pool is only refused on the hit itself, which then deals 0.)
function DestructibleService.FromPart(part)
	local key = keyOf(part)
	if not key then
		return nil
	end
	local entry = damaged[key]
	if entry then
		return not entry.broken and part or nil
	end
	return mapRootOf(part) and part or nil
end

-- Glass doesn't stop a shot: the pane breaks and the bullet goes on to whatever is behind it.
function DestructibleService.PassesThrough(part)
	return part ~= nil and part.Name == DestructibleService.GlassName
end

-- Panes broken this frame, sent to every client as one event: { cframe, size, color, from } each,
-- where `from` (optional) is where the shot or blast came from, so the shards fly away from it.
local pendingPanes = nil

local function breakPane(pane, from)
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
	table.insert(pendingPanes, { pane.CFrame, pane.Size, pane.Color, typeof(from) == "Vector3" and from or nil })
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

local function dropDressing(part, from)
	local building = part.Parent
	if not building or not CARRIES_DRESSING[part.Name] then
		return
	end
	local children = building:GetChildren()
	local gone = { [part] = true }

	local function heldBySolid(trim)
		for _, other in ipairs(children) do
			if not gone[other] and other:IsA("BasePart") and other.CanCollide and other.Name ~= DestructibleService.GlassName
				and not ATTACHED[other.Name] and attached(other, trim, ATTACH_MARGIN) then
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
-- { cframe, size, color, material, class, from } each. Capped per frame, biggest pools first come
-- first served, so a rocket through a street of props costs one bounded message.
local FX_PER_FRAME = 60
local pendingFx = nil

queueFx = function(part, from)
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
			typeof(from) == "Vector3" and from or nil })
	end
end

tellBroken = function(cframe, size)
	if DestructibleService.PartBrokenEnabled then
		for _, listener in ipairs(partBrokenListeners) do
			task.spawn(listener, cframe, size)
		end
	end
end

-- A part coming apart: it's gone at once for everyone, and each client throws its debris.
local function shatter(part, from)
	if part.Name == DestructibleService.GlassName then
		breakPane(part, from)
		return
	end
	tellBroken(part.CFrame, part.Size)
	dropDressing(part, from)
	queueFx(part, from)
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
			queueFx(member, from)
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

-- Returns the damage actually taken. `from` (optional) is where the shot or blast came from.
function DestructibleService.Damage(part, amount, attackerToken, from)
	if amount <= 0 then
		return 0
	end
	local entry = entryFor(part)
	if not entry or entry.broken then
		return 0
	end

	local dealt = math.min(entry.health, amount)
	entry.health -= dealt

	-- Half gone: it starts to look it, so you can read what is nearly through. (Glass has no
	-- halfway; it just breaks.) Darker, never see-through: a wall fading toward clear read as a
	-- ghost of cover rather than cover taking a beating (#71).
	if entry.health <= entry.max * 0.5 and not entry.battered and entry.max > 1 then
		entry.battered = true
		for _, member in ipairs(entry.members) do
			if member.Parent then
				member.Color = member.Color:Lerp(Color3.new(0, 0, 0), 0.25)
			end
		end
	end

	if entry.health <= 0 then
		entry.broken = true
		if entry.tagged then
			shatterPool(entry, from)
		else
			shatter(part, from)
		end
	end
	return dealt
end

-- Craters: a blast on open ground scoops a little terrain out. Capped per Map (a new map is a new
-- Map instance, which resets it), sized off the blast, and never where the ground is a road, paving,
-- water or ice, or where the blast first meets something built rather than terrain.
local CRATER_CAP = 40
local CRATER_SHARE, CRATER_MIN, CRATER_MAX = 0.3, 1.5, 4.5
local NO_CRATER = {
	[Enum.Material.Asphalt] = true, [Enum.Material.Pavement] = true, [Enum.Material.Concrete] = true,
	[Enum.Material.Cobblestone] = true, [Enum.Material.Brick] = true, [Enum.Material.Water] = true,
	[Enum.Material.Glacier] = true, [Enum.Material.Ice] = true, [Enum.Material.Salt] = true,
}
DestructibleService.CraterCap = CRATER_CAP
local craterMap, craterCount = nil, 0

local function craterAt(position, radius, map)
	if craterMap ~= map then
		craterMap, craterCount = map, 0
	end
	if craterCount >= CRATER_CAP then
		return false
	end
	local size = math.clamp(radius * CRATER_SHARE, CRATER_MIN, CRATER_MAX)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map, workspace.Terrain }
	params.IgnoreWater = false
	local hit = workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -(size + 2), 0), params)
	if not hit or hit.Instance ~= workspace.Terrain or NO_CRATER[hit.Material] then
		return false
	end
	craterCount += 1
	-- Whatever lay on the ground there (loot, a supply crate) settles into the hole.
	tellBroken(CFrame.new(hit.Position - Vector3.new(0, 0.5, 0)), Vector3.new(size * 2, 1, size * 2))
	workspace.Terrain:FillBall(hit.Position, size, Enum.Material.Air)
	return true
end

-- Each pool once per blast, however many of its parts the blast reaches: a tree is one tree, not
-- one hit per leaf.
function DestructibleService.DamageInRadius(position, radius, amount, attackerToken)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local region = OverlapParams.new()
	region.FilterType = Enum.RaycastFilterType.Include
	region.FilterDescendantsInstances = { map }
	local seen = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, region)) do
		local key = keyOf(part)
		if key and not seen[key] then
			seen[key] = true
			DestructibleService.Damage(part, amount, attackerToken, position)
		end
	end
	craterAt(position, radius, map)
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
CombatService.DamageDestructible = function(shooterToken, part, amount, from)
	local at = part.Position
	local dealt = DestructibleService.Damage(part, amount, shooterToken, from)
	-- "structure": the HUD marks a hit on the map differently from a hit on a person.
	CombatService.ConfirmHit(shooterToken, dealt, false, at, "structure")
	return dealt
end
CombatService.DamageDestructiblesInRadius = DestructibleService.DamageInRadius

return DestructibleService
