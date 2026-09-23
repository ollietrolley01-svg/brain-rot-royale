-- Shooting the map apart: walls, floors, roofs and the props inside buildings take damage and
-- break, so cover is something you wear down rather than something permanent.
--
--   DestructibleService.FromPart(part)              the part if it can be broken, or nil
--   DestructibleService.Damage(part, amount, by)    hurt one; it breaks at zero
--   DestructibleService.DamageInRadius(...)         splash from a blast
--   DestructibleService.Count()                     how many are damaged but still standing
--
-- Registered with CombatService at load the way defenses and hazards are, so bullets find it.
--
-- Two things shape the design. Health is per PART, not per model: a building is one Model, so
-- the defense registry's model lookup would give a whole house a single pool instead of 250 a
-- wall. And entries are made lazily, on the first hit — a map carries thousands of wall parts,
-- and registering them all at build time would cost real time at match start and need clearing
-- between matches. Nothing is tracked until someone shoots it, and an entry dies with its part.

--
-- Window glass is the one thing that breaks at a touch: any bullet or blast shatters a pane, and
-- the shot carries on through it (CombatService asks PassesThrough). Clients draw the shards
-- (GlassFxClient) from one GlassShatter event per frame; the server only removes the pane, so
-- anyone joining later simply sees the window open.
--
-- When a wall, floor or roof part breaks, everything hanging off it goes too: the panes set into
-- it shatter, and its trim (sills, shutters, frames, cornices, signs, lights) is removed rather
-- than left floating where the wall used to be. Trim is found by overlap with the broken part,
-- walking the building's own children, so nothing is registered ahead of time.
--
-- Not everything can be found by its name: decor built from generic parts (the parked cars were
-- all called "Part", #51, so a shot looked them up, found nothing and did no damage). Two opt-ins
-- work whatever the pieces are called. A part with a numeric DestructibleHealth attribute is one
-- more wall-like piece with that health. A Model carrying the attribute is ONE pool shared by
-- every solid part in it — shoot a car's cabin or its wheel and it is the car that wears down —
-- and when it breaks the whole model comes apart at once, so no roof is left floating over the
-- place its body was. The nearest such Model wins over a part's own name.

local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))

local DestructibleService = {}

DestructibleService.GlassName = "WindowGlass"

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
}

-- Structure whose breaking takes the panes and trim attached to it along.
local CARRIES_DRESSING = { Wall = true, Floor = true, Roof = true, Gable = true, Parapet = true }
-- How far apart two parts may be and still count as attached: trim sits a hair off its wall.
local ATTACH_MARGIN = 0.35
-- A pane only overlaps the wall bands round its opening by a tenth of a stud.
local PANE_MARGIN = 0.02

local glassShatter = Remotes.Event("GlassShatter")

-- Anything inside these is fair game; anything else on the map is scenery and stays put.
local ROOTS = { Map = true }

DestructibleService.HealthAttribute = "DestructibleHealth"

-- key -> { health, max, broken }, where the key is the part, or the Model for a pooled model.
-- Strong keys, dropped when the key is destroyed: a weak-keyed table loses live Instances, since
-- Roblox collects an instance's Lua handle whenever nothing but a weak table holds it.
local damaged = {}

local function positiveNumber(value)
	return type(value) == "number" and value > 0 and value or nil
end

-- What a hit on `part` damages and how much that takes: the key (the part, or the pooled Model
-- it belongs to) and its full health, or nil when it is scenery.
local function resolve(part)
	if not part or not part:IsA("BasePart") or not part.CanCollide then
		return nil
	end
	local key, health = nil, nil
	local node = part.Parent
	-- Walk up to the map root, noting the nearest pooled Model on the way.
	local root = part
	while node and node ~= workspace do
		if not key and node:IsA("Model") then
			local pooled = positiveNumber(node:GetAttribute(DestructibleService.HealthAttribute))
			if pooled then
				key, health = node, pooled
			end
		end
		root = node
		node = node.Parent
	end
	-- Only things standing on the map itself, so lobby furniture and deployables are untouched.
	if node ~= workspace or not ROOTS[root.Name] then
		return nil
	end
	if key then
		return key, health
	end
	health = positiveNumber(part:GetAttribute(DestructibleService.HealthAttribute)) or HEALTH[part.Name]
	if not health then
		return nil
	end
	return part, health
end

local function maxHealthFor(part)
	local _, health = resolve(part)
	return health
end

function DestructibleService.FromPart(part)
	local key, _ = resolve(part)
	if not key then
		return nil
	end
	local entry = damaged[key]
	if entry and entry.broken then
		return nil
	end
	return part
end

-- Glass doesn't stop a shot: the pane breaks and the bullet goes on to whatever is behind it.
function DestructibleService.PassesThrough(part)
	return part ~= nil and part.Name == DestructibleService.GlassName
end

-- Panes broken this frame, sent to every client as one event: { cframe, size, color, from } each,
-- where `from` (optional) is where the shot or blast came from, so the shards fly away from it.
local pendingPanes = nil

-- Sends the shards of one pane-shaped piece of glass with this frame's batch.
local function queueShards(glass, from)
	if not pendingPanes then
		pendingPanes = {}
		task.defer(function()
			local batch = pendingPanes
			pendingPanes = nil
			glassShatter:FireAllClients(batch)
		end)
	end
	table.insert(pendingPanes, { glass.CFrame, glass.Size, glass.Color, typeof(from) == "Vector3" and from or nil })
end

local function breakPane(pane, from)
	local entry = damaged[pane]
	if entry then
		entry.broken = true
	end
	queueShards(pane, from)
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
				and attached(other, trim, ATTACH_MARGIN) then
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
				elseif isTrim(other) and attached(current, other, ATTACH_MARGIN) and not heldBySolid(other) then
					gone[other] = true
					table.insert(queue, other)
				end
			end
		end
	end

	for trim in pairs(gone) do
		if trim ~= part and trim.Parent and trim.Name ~= DestructibleService.GlassName then
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

-- How each material comes apart (#71): wood splinters into long thin sticks, stone and brick
-- crumble into chunky lumps under a puff of dust, metal tears into thin plates with a spray of
-- sparks. `piece` shapes one chunk from the part's size and the piece count; `extra` adds pieces,
-- `throw` and `lift` set how hard they fly. Anything unlisted keeps the plain slabs.
local M = Enum.Material
local SPLINTER = {
	extra = 2, throw = 22, lift = 12, spin = 14,
	piece = function(size, pieces)
		return Vector3.new(0.25, 0.25, math.clamp(math.max(size.X, size.Y, size.Z) / (pieces + 1), 1, 2.6))
	end,
}
local CRUMBLE = {
	extra = 1, throw = 10, lift = 5, spin = 5, dust = true,
	piece = function(size, pieces)
		local side = math.clamp(math.max(size.X, size.Y, size.Z) / (pieces + 1), 0.5, 1.6)
		return Vector3.new(side, side * 0.8, side)
	end,
}
local TEAR = {
	extra = 0, throw = 16, lift = 8, spin = 10, sparks = true,
	piece = function(size, pieces)
		local side = math.clamp(math.max(size.X, size.Z) / (pieces + 1), 0.6, 1.8)
		return Vector3.new(side, 0.15, side * 0.7)
	end,
}
local BREAKS_AS = {
	[M.Wood] = SPLINTER, [M.WoodPlanks] = SPLINTER,
	[M.Concrete] = CRUMBLE, [M.Brick] = CRUMBLE, [M.Cobblestone] = CRUMBLE, [M.Slate] = CRUMBLE,
	[M.Granite] = CRUMBLE, [M.Marble] = CRUMBLE, [M.Pebble] = CRUMBLE, [M.Rock] = CRUMBLE,
	[M.Sandstone] = CRUMBLE, [M.Limestone] = CRUMBLE, [M.Basalt] = CRUMBLE, [M.Asphalt] = CRUMBLE,
	[M.Pavement] = CRUMBLE, [M.Plaster] = CRUMBLE,
	[M.Metal] = TEAR, [M.DiamondPlate] = TEAR, [M.CorrodedMetal] = TEAR, [M.Foil] = TEAR,
}

-- A short burst from the broken part's whole volume: dust for stone, sparks for metal. The
-- emitter runs for a fraction of a second and is then switched off rather than using Emit, since
-- a property change replicates to every client and a server-side Emit call does not.
local function burst(part, parent, how)
	local holder = Instance.new("Part")
	holder.Name = "Rubble"
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.CanTouch = false
	holder.Transparency = 1
	holder.Size = part.Size
	holder.CFrame = part.CFrame
	local emitter = Instance.new("ParticleEmitter")
	emitter.Shape = Enum.ParticleEmitterShape.Box
	if how.dust then
		emitter.Color = ColorSequence.new(part.Color:Lerp(Color3.fromRGB(200, 196, 188), 0.6))
		emitter.Size = NumberSequence.new(1.5, 5)
		emitter.Transparency = NumberSequence.new(0.35, 1)
		emitter.Lifetime = NumberRange.new(0.9, 1.6)
		emitter.Speed = NumberRange.new(2, 6)
		emitter.Drag = 3
		emitter.Rate = 70
	else
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 190, 90))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(0.25, 0)
		emitter.Lifetime = NumberRange.new(0.2, 0.45)
		emitter.Speed = NumberRange.new(14, 26)
		emitter.Acceleration = Vector3.new(0, -60, 0)
		emitter.Rate = 120
	end
	emitter.Parent = holder
	holder.Parent = parent
	task.delay(0.18, function()
		emitter.Enabled = false
	end)
	Debris:AddItem(holder, 2)
end

-- A few chunks of a breaking part thrown out, cleared away a moment later, shaped by what it was
-- made of. `cap` (optional) caps how many, so a model breaking all at once throws a bounded
-- number; `parent` (optional) is where they go, the part's own parent by default.
local function throwRubble(part, cap, parent)
	local size = part.Size
	local how = BREAKS_AS[part.Material]
	local pieces = math.clamp(math.floor(math.max(size.X, size.Y, size.Z) / 3), 2, 5) + (how and how.extra or 0)
	pieces = math.min(pieces, cap or pieces)
	parent = parent or part.Parent
	for index = 1, pieces do
		local chunk = Instance.new("Part")
		chunk.Name = "Rubble"
		chunk.Size = how and how.piece(size, pieces) or Vector3.new(
			math.max(0.4, size.X / (pieces + 1)),
			math.max(0.4, size.Y / (pieces + 1)),
			math.max(0.4, math.min(size.Z, 1.4))
		)
		chunk.CFrame = part.CFrame * CFrame.new(
			(math.random() - 0.5) * size.X * 0.6,
			(math.random() - 0.5) * size.Y * 0.6,
			0
		) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		chunk.Color = part.Color
		chunk.Material = part.Material
		chunk.CanCollide = false
		chunk.CanQuery = false
		chunk.CanTouch = false
		chunk.CastShadow = false
		chunk.Parent = parent
		local throw, lift, spin = how and how.throw or 18, how and how.lift or 6, how and how.spin or 8
		chunk.AssemblyLinearVelocity = Vector3.new(
			(math.random() - 0.5) * throw,
			lift + math.random() * 10,
			(math.random() - 0.5) * throw
		)
		chunk.AssemblyAngularVelocity = Vector3.new(math.random() * spin, math.random() * spin, math.random() * spin)
		Debris:AddItem(chunk, 2.5 + math.random())
	end
	if how and (how.dust or how.sparks) then
		burst(part, parent, how)
	end
end

local function tellPartBroken(cframe, size)
	if DestructibleService.PartBrokenEnabled then
		for _, listener in ipairs(partBrokenListeners) do
			task.spawn(listener, cframe, size)
		end
	end
end

-- A part coming apart: a few chunks of itself thrown out, then it's gone.
local function shatter(part, from)
	if part.Name == DestructibleService.GlassName then
		breakPane(part, from)
		return
	end
	tellPartBroken(part.CFrame, part.Size)
	dropDressing(part, from)
	throwRubble(part)
	part:Destroy()
end

-- A pooled model coming apart: every piece of it at once. Rubble comes from its solid pieces,
-- biggest first and a dozen chunks in all, so a car costs no more than two walls; its glass
-- goes to shards the way a window does, and its trim and lights simply go with it.
local MODEL_RUBBLE = 12

local function shatterModel(model, from)
	local box, boxSize = model:GetBoundingBox()
	tellPartBroken(box, boxSize)
	local solid = {}
	for _, piece in ipairs(model:GetDescendants()) do
		if piece:IsA("BasePart") and piece.CanCollide and piece.Transparency < 1 then
			-- Glass in a model (a car's windows) bursts into shards like a window pane.
			if piece.Material == Enum.Material.Glass then
				queueShards(piece, from)
			else
				table.insert(solid, piece)
			end
		end
	end
	table.sort(solid, function(a, b)
		return a.Size.X * a.Size.Y * a.Size.Z > b.Size.X * b.Size.Y * b.Size.Z
	end)
	local left = MODEL_RUBBLE
	for _, piece in ipairs(solid) do
		if left <= 0 then
			break
		end
		-- Rubble goes beside the model, not inside the thing being destroyed.
		throwRubble(piece, math.min(left, 4), model.Parent)
		left -= math.min(left, 4)
	end
	model:Destroy()
end

-- Returns the damage actually taken. `from` (optional) is where the shot or blast came from.
function DestructibleService.Damage(part, amount, attackerToken, from)
	if amount <= 0 then
		return 0
	end
	local key, max = resolve(part)
	if not key then
		return 0
	end
	local entry = damaged[key]
	if not entry then
		entry = { health = max, max = max }
		damaged[key] = entry
		key.Destroying:Connect(function()
			damaged[key] = nil
		end)
	end
	if entry.broken then
		return 0
	end

	local dealt = math.min(entry.health, amount)
	entry.health -= dealt

	-- Half gone: it starts to look it, so you can read what is nearly through. (Glass has no
	-- halfway; it just breaks.) A pooled model darkens all over. Darker, never see-through: a wall
	-- fading toward clear read as a ghost of cover rather than cover taking a beating (#71).
	if entry.health <= entry.max * 0.5 and not entry.battered and entry.max > 1 then
		entry.battered = true
		local pieces = key:IsA("Model") and key:GetDescendants() or { key }
		for _, piece in ipairs(pieces) do
			if piece:IsA("BasePart") then
				piece.Color = piece.Color:Lerp(Color3.new(0, 0, 0), 0.25)
			end
		end
	end

	if entry.health <= 0 then
		entry.broken = true
		if key:IsA("Model") then
			shatterModel(key, from)
		else
			shatter(key, from)
		end
	end
	return dealt
end

-- One blast hurts each thing once: a car with six parts in the radius takes the blast once, not
-- six times.
function DestructibleService.DamageInRadius(position, radius, amount, attackerToken)
	local region = OverlapParams.new()
	region.FilterType = Enum.RaycastFilterType.Include
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	region.FilterDescendantsInstances = { map }
	local hit = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, region)) do
		local key, _ = resolve(part)
		if key and not hit[key] then
			hit[key] = true
			DestructibleService.Damage(part, amount, attackerToken, position)
		end
	end
end

-- How many are damaged but still standing (for the build check).
function DestructibleService.Count()
	local count = 0
	for part, entry in pairs(damaged) do
		if not entry.broken and part.Parent then
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
