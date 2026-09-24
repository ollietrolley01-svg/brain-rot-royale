-- Measures every structure on a built map (tools/foundation_world.py) for foundations and placement.
-- Called as measure(map, T, built, MapTerrain, options) -> { structures = {...}, violations = {...} }.
--
-- A STRUCTURE is anything built to stand on the ground:
--   town:<archetype>   MapBuildings' houses, towers and warehouses (FootingBase / FootingSize)
--   town:yardprop      the yard crates and barrel pairs behind them
--   theme:setpiece     a town's themed set piece (TownThemes), theme:flag, theme:prop
--   landmark:<Name>    Landmarks' monuments, egg:<Name> the easter eggs
--   wilds:<kind>       MapWilds' shelters, cabins, deer stands, wrecks, ruins, campsites
--   zipline:post       every zipline's posts (plateau rims, landmarks), bridge:pier, footbridge:leg
--   decor:hut          MapDecor's scenery huts (not this worker's module: reported, not fixed)
-- FootingSkip groups (woods, meadows, hedgerows) are not structures; their trunks are read as TREES.
--
-- Per structure, from its real parts and the real terrain:
--   gap      the most any point of its outline hangs over the ground: the lowest visible part at that
--            point (its plinth or skirt, not just its floor) minus the rendered ground. Points 0.3
--            inside the outline, every EDGE_STEP studs and at every corner.
--   buried   the most the ground rises above its floor line anywhere on the outline.
--   sill     for a structure with a door (town buildings, set pieces, cabins, shelters): the ground
--            just outside the door minus the door's floor. Above SILL: the step is in the ground.
--   door     how far from the door the way out is clear: no other structure, tree, prop, water,
--            bank rising more than RISE over the floor or drop more than DROP below it, sampled on
--            three lanes across the door out to DOOR_CLEAR studs.
--   overlap  outline against every other structure's outline, the roads' and streets' carriageways,
--            bridges, car parks and the river (penetration past OVERLAP).
--   water    any footprint point under water.
--   trees    any tree trunk standing inside the outline.

local map, T, built, MapTerrain, options = ...
options = options or {}

local FLOAT = options.float or 0.5
local BURY_FLOOR = options.buryFloor or 0.5
local BURY_OPEN = options.buryOpen or 1.5
local SILL = options.sill or 0.3
-- A person's way out: the width of a pavement. (A town building's step is 4.3 studs from its kerb,
-- so a car parked at the kerb in front of a door does not count against it.)
local DOOR_CLEAR = options.doorClear or 4
local RISE, DROP = 2.0, 3.0
local FACE_REACH = 14
local OVERLAP = options.overlap or 0.3
local EDGE_STEP = 2
-- Parts whose bottom is within this of the floor line are meant to stand on something.
local BAND = 1.5
local INSET = 0.3

local structures, trees, obstacles, carriageways, planks, slabs = {}, {}, {}, {}, {}, {}
local SLAB_NAMES = { Pavement = true, PavementTaper = true, Paving = true, Cobbles = true, Kerb = true, Asphalt = true,
	JunctionAsphalt = true, Crossing = true, RoadSurface = true, RoadEdge = true, RoadCurve = true, BridgeDeck = true,
	BridgeRoad = true, FootbridgePlank = true }
local skipped = 0

local function flat(v) return v.X, v.Z end

-- Parts --------------------------------------------------------------------------------------------
local function visible(part)
	return part:IsA("BasePart") and (part.Transparency or 0) < 0.95
end

-- The interval of y where the vertical line through (x, z) is inside `part` (box, ball or X-axis
-- cylinder), or nil.
local function slab(a, b, h, lo, hi)
	if math.abs(b) < 1e-9 then
		if math.abs(a) > h then return nil end
		return lo, hi
	end
	local t1, t2 = (-h - a) / b, (h - a) / b
	if t1 > t2 then t1, t2 = t2, t1 end
	lo, hi = math.max(lo, t1), math.min(hi, t2)
	if lo >= hi then return nil end
	return lo, hi
end
local function lineThrough(entry, x, z)
	local cf, s = entry.cf, entry.size
	local p, r, u, b = cf.p, cf.r, cf.u, cf.b
	local dx, dz = x - p.X, z - p.Z
	if entry.shape == "Ball" then
		local radius = math.min(s.X, s.Y, s.Z) / 2
		local d2 = radius * radius - dx * dx - dz * dz
		if d2 <= 0 then return nil end
		local h = math.sqrt(d2)
		return p.Y - h, p.Y + h
	end
	-- Local coordinate along each axis = a + b * y.
	local ar, br = r.X * dx + r.Z * dz - r.Y * p.Y, r.Y
	local au, bu = u.X * dx + u.Z * dz - u.Y * p.Y, u.Y
	local ab, bb = b.X * dx + b.Z * dz - b.Y * p.Y, b.Y
	local lo, hi = entry.lo - 1, entry.hi + 1
	lo, hi = slab(ar, br, s.X / 2, lo, hi)
	if not lo then return nil end
	if entry.shape == "Cylinder" then
		-- Round across local Y/Z: (au + bu t)^2 + (ab + bb t)^2 <= radius^2.
		local radius = math.min(s.Y, s.Z) / 2
		local A, B, C = bu * bu + bb * bb, 2 * (au * bu + ab * bb), au * au + ab * ab - radius * radius
		if A < 1e-9 then
			if C > 0 then return nil end
			return lo, hi
		end
		local disc = B * B - 4 * A * C
		if disc < 0 then return nil end
		local q = math.sqrt(disc)
		lo, hi = math.max(lo, (-B - q) / (2 * A)), math.min(hi, (-B + q) / (2 * A))
		if lo >= hi then return nil end
		return lo, hi
	end
	lo, hi = slab(au, bu, s.Y / 2, lo, hi)
	if not lo then return nil end
	lo, hi = slab(ab, bb, s.Z / 2, lo, hi)
	return lo, hi
end

local function entryOf(part)
	local cf, s = part.CFrame, part.Size
	local r, u, b, p = cf.r, cf.u, cf.b, cf.p
	local ex = math.abs(r.X) * s.X / 2 + math.abs(u.X) * s.Y / 2 + math.abs(b.X) * s.Z / 2
	local ey = math.abs(r.Y) * s.X / 2 + math.abs(u.Y) * s.Y / 2 + math.abs(b.Y) * s.Z / 2
	local ez = math.abs(r.Z) * s.X / 2 + math.abs(u.Z) * s.Y / 2 + math.abs(b.Z) * s.Z / 2
	local shape = part.Shape and part.Shape.Name or "Block"
	if part.ClassName ~= "Part" then shape = "Block" end
	return { part = part, cf = cf, size = s, shape = shape, lo = p.Y - ey, hi = p.Y + ey,
		x0 = p.X - ex, x1 = p.X + ex, z0 = p.Z - ez, z1 = p.Z + ez, name = part.Name }
end

-- What can be SEEN to float: a piece with some body to it. A foundation, floor, wall, post, plinth or
-- skirt, collidable or not (a building's plinth is trim); not a strip of caution tape between posts,
-- a hoop round a drum or a handle, whose hang is the design.
local function bearing(part, e)
	local s = part.Size
	local cf = part.CFrame
	if part.ClassName ~= "Part" and part.ClassName ~= "WedgePart" and part.ClassName ~= "CornerWedgePart" and part.ClassName ~= "TrussPart" then
		return false
	end
	local wide = math.min(e.x1 - e.x0, e.z1 - e.z0)
	if part.CanCollide and wide >= 0.8 then
		return true
	end
	-- Upright boxes a stud or more tall: plinths, skirts, posts.
	return (part.Shape == nil or part.Shape == Enum.PartType.Block) and math.abs(cf.UpVector.Y) > 0.95 and s.Y >= 1.0 and wide >= 0.4
end

-- Structures ---------------------------------------------------------------------------------------
-- MapWilds' shelters with a way in down their local -Z (all of them open that way by convention),
-- and of those the closed huts, whose floor is hidden inside their walls.
local DOOR_KINDS = { cabin = true, bothy = true, beachHut = true, shack = true, leanTo = true, driftwoodLeanTo = true,
	rockShelter = true, slateShelter = true, sandstoneShelter = true, busShelter = true, poleBarn = true }
local CLOSED_KINDS = { cabin = true, bothy = true, beachHut = true, shack = true }

local function addStructure(model, kind, owner, frame, halfX, halfZ, base, opts)
	opts = opts or {}
	local look = frame.LookVector
	local fx, fz = look.X, look.Z
	local m = math.sqrt(fx * fx + fz * fz)
	if m < 1e-6 then fx, fz, m = 0, -1, 1 end
	fx, fz = fx / m, fz / m
	local s = {
		model = model, kind = kind, owner = owner, name = model and model.Name or kind,
		cx = frame.Position.X, cz = frame.Position.Z,
		-- local +X (right) and local -Z (front) in the ground plane
		rx = -fz, rz = fx, fx = fx, fz = fz,
		halfX = halfX, halfZ = halfZ, base = base,
		door = opts.door, strict = opts.strict, parts = {}, v = {},
		prop = kind == "theme:prop" or kind == "theme:flag" or kind == "town:yardprop",
	}
	local list = opts.parts
	if not list and model then
		list = {}
		for _, d in ipairs(model:GetDescendants()) do
			-- A zipline's rope and far post belong to the zipline (measured on their own), not to the
			-- landmark it hangs from.
			if visible(d) and not d:FindFirstAncestor("Zipline") then table.insert(list, d) end
		end
	end
	s.all = {}
	for _, part in ipairs(list or {}) do
		local e = entryOf(part)
		table.insert(s.all, e)
		if e.lo <= base + BAND and not part:GetAttribute("IntentionalFloat") and bearing(part, e) then
			table.insert(s.parts, e)
		end
	end
	table.insert(structures, s)
	return s
end

-- World point from a structure's local (x across, f forward toward its front).
local function at(s, lx, lf)
	return s.cx + s.rx * lx + s.fx * lf, s.cz + s.rz * lx + s.fz * lf
end
-- Local coordinates of a world point.
local function toLocal(s, x, z)
	local dx, dz = x - s.cx, z - s.cz
	return dx * s.rx + dz * s.rz, dx * s.fx + dz * s.fz
end
local function insideRect(s, x, z, grow)
	local lx, lf = toLocal(s, x, z)
	return math.abs(lx) <= s.halfX + (grow or 0) and math.abs(lf) <= s.halfZ + (grow or 0)
end

local function declared(model)
	local base, size = model:GetAttribute("FootingBase"), model:GetAttribute("FootingSize")
	if type(base) == "number" and size and size.X then
		local pivot = model:GetPivot()
		return pivot, size.X / 2, size.Z / 2, base
	end
	return nil
end

local function byBox(model, kind, owner, opts)
	local cf, size = model:GetBoundingBox()
	local base = cf.Position.Y - size.Y / 2
	return addStructure(model, kind, owner, CFrame.new(cf.Position.X, base, cf.Position.Z), size.X / 2, size.Z / 2, base, opts)
end

local counts = { declaredModels = 0, boxModels = 0, skippedGroups = 0 }

local function isTrunk(part)
	if not part:IsA("BasePart") then return false end
	local name = part.Name
	if name == "Trunk" or name == "PalmTrunk" or name == "RestTrunk" then return true end
	-- MapDecor's trees are plain "Part"s: a tall, thin, upright piece of wood.
	local s = part.Size
	local u = part.CFrame.UpVector
	local length, thick = s.Y, math.max(s.X, s.Z)
	if part.Shape == Enum.PartType.Cylinder then
		length, thick = s.X, math.max(s.Y, s.Z)
		u = part.CFrame.RightVector
	end
	return part.Material == Enum.Material.Wood and length >= 5 and thick <= 3.6 and math.abs(u.Y) > 0.8
end

local function collectTrees(container)
	for _, d in ipairs(container:GetDescendants()) do
		if isTrunk(d) then
			local p = d.Position
			local s = d.Size
			local radius = (d.Shape == Enum.PartType.Cylinder and math.max(s.Y, s.Z) or math.max(s.X, s.Z)) / 2
			local bottom = p.Y - (d.Shape == Enum.PartType.Cylinder and s.X or s.Y) / 2
			table.insert(trees, { x = p.X, z = p.Z, r = radius, part = d, bottom = bottom })
		end
	end
end

local function measureModel(model, kind, owner, opts)
	local pivot, hx, hz, base = declared(model)
	if pivot then
		counts.declaredModels += 1
		return addStructure(model, kind, owner, pivot, hx, hz, base, opts)
	end
	counts.boxModels += 1
	return byBox(model, kind, owner, opts)
end

-- Zipline posts, bridge piers and footbridge legs: each part is its own little structure.
local function measurePart(part, kind, owner)
	local e = entryOf(part)
	local frame = CFrame.new(part.Position.X, e.lo, part.Position.Z)
	local s = addStructure(nil, kind, owner, frame, (e.x1 - e.x0) / 2, (e.z1 - e.z0) / 2, e.lo, { parts = { part } })
	s.name = part.Name
	s.single = true
	return s
end

local CARRIAGEWAY = { RoadSurface = true, JunctionAsphalt = true, RoadCurve = true, BridgeDeck = true, BridgeRoad = true,
	Asphalt = true, Crossing = true }
local SQUARE = { Paving = true, Cobbles = true, FountainWall = true, FountainBowl = true, FountainPool = true }

for _, top in ipairs(map:GetChildren()) do
	local name = top.Name
	if name == "Town" then
		for _, child in ipairs(top:GetChildren()) do
			if child:IsA("Model") then
				if child.Name == "house" or child.Name == "tower" or child.Name == "warehouse" then
					measureModel(child, "town:" .. child.Name, "Town", { door = { half = 3, sill = 0.5, street = true }, strict = true })
				elseif child.Name == "Theme" then
					for _, piece in ipairs(child:GetChildren()) do
						if piece:IsA("Model") and (piece.Name == "Flags" or piece.Name == "Props") then
							for _, item in ipairs(piece:GetChildren()) do
								if item:IsA("Model") then
									if item:GetAttribute("FootingSkip") then
										skipped += 1
									else
										measureModel(item, piece.Name == "Flags" and "theme:flag" or "theme:prop", "Town/Theme/" .. piece.Name)
									end
								end
							end
						elseif piece:IsA("Model") then
							measureModel(piece, "theme:setpiece", "Town/Theme", { door = { half = 0, street = true } })
						end
					end
					collectTrees(child)
				elseif child.Name == "ExplosiveBarrel" then
					measureModel(child, "town:yardprop", "Town")
				elseif child.Name == "ParkingLot" then
					for _, d in ipairs(child:GetDescendants()) do
						if d:IsA("BasePart") then table.insert(carriageways, { entry = entryOf(d), what = "parking" }) end
					end
				elseif child.Name == "ParkedCar" or child.Name == "RotVendor" then
					for _, d in ipairs(child:GetDescendants()) do
						if d:IsA("BasePart") and d.CanCollide then table.insert(obstacles, entryOf(d)) end
					end
				end
			elseif child:IsA("BasePart") then
				if child.Name == "YardCrate" then
					measurePart(child, "town:yardprop", "Town")
				elseif CARRIAGEWAY[child.Name] then
					table.insert(carriageways, { entry = entryOf(child), what = "street" })
				elseif SQUARE[child.Name] then
					table.insert(carriageways, { entry = entryOf(child), what = "square" })
				elseif child.CanCollide and child.Size.Y > 1.5 then
					table.insert(obstacles, entryOf(child))
				end
			end
		end
	elseif name == "Landmarks" or name == "EasterEggs" then
		for _, child in ipairs(top:GetChildren()) do
			local kind = (name == "Landmarks" and "landmark:" or "egg:") .. child.Name
			if child:IsA("Model") and child:GetAttribute("FootingGroup") then
				-- Stands on its own feet (Turbine Ridge's turbines): each foot is measured, not a box
				-- round the whole ridge.
				for _, foot in ipairs(child:GetChildren()) do
					if foot:IsA("Model") and foot.Name ~= "Zipline" then
						measureModel(foot, kind, name)
					end
				end
			elseif child:IsA("Model") then
				measureModel(child, kind, name)
			end
		end
		collectTrees(top)
	elseif name == "Wilds" then
		for _, child in ipairs(top:GetChildren()) do
			if child:IsA("Model") then
				if child:GetAttribute("FootingSkip") then
					skipped += 1
					collectTrees(child)
					-- Their solid bits (rocks, logs, walls) stand in a doorway as surely as a tree.
					for _, d in ipairs(child:GetDescendants()) do
						if d:IsA("BasePart") and d.CanCollide and not isTrunk(d) and d.Size.Y > 1.2 then
							table.insert(obstacles, entryOf(d))
						end
					end
				else
					local kind = string.match(child.Name, "^(.-)_%d+$") or child.Name
					measureModel(child, "wilds:" .. kind, "Wilds", { door = DOOR_KINDS[kind] and { half = 1.5 } or nil, strict = CLOSED_KINDS[kind] })
				end
			end
		end
	elseif name == "Roads" then
		for _, d in ipairs(top:GetDescendants()) do
			if d:IsA("BasePart") then
				if CARRIAGEWAY[d.Name] then
					table.insert(carriageways, { entry = entryOf(d), what = d.Name:find("Bridge") and "bridge" or "road" })
				end
				if d.Name == "BridgePier" then
					measurePart(d, "bridge:pier", "Roads")
				elseif d.CanCollide and (d.Name == "LampPost" or d.Name == "FingerpostPost" or d.Name == "StopSignPost" or d.Name == "SignalPole") then
					table.insert(obstacles, entryOf(d))
				end
			end
		end
	elseif name == "River" then
		for _, d in ipairs(top:GetDescendants()) do
			-- The legs go down into the bed; the rail posts stand on the deck, not the ground.
			if d:IsA("BasePart") and d.Name == "FootbridgeLeg" then
				measurePart(d, "footbridge:leg", "River")
			elseif d:IsA("BasePart") and d.Name == "FootbridgePlank" then
				table.insert(carriageways, { entry = entryOf(d), what = "bridge" })
				table.insert(planks, d)
			end
		end
		-- Each footbridge's end planks meet the bank: neither hanging off it nor under it.
		for _, plank in ipairs(planks) do
			local p = plank.Position
			local neighbours = 0
			for _, other in ipairs(planks) do
				if other ~= plank and (other.Position - p).Magnitude < 1.8 then
					neighbours += 1
				end
			end
			if neighbours <= 1 then
				local s = measurePart(plank, "footbridge:end", "River")
				s.deckTop = p.Y + plank.Size.Y / 2
			end
		end
	elseif name == "Props" then
		collectTrees(top)
		-- MapDecor's sheds are loose parts (four walls, a lintel over the doorway, a roof, a crate):
		-- gathered back into one structure each, the walls of one shed being within a few studs of
		-- each other. Their walls are sunk into the ground on purpose (MapDecor's SINK), so their floor
		-- line is not known and only floating is judged, not burial.
		local walls = {}
		for _, d in ipairs(top:GetChildren()) do
			if d:IsA("BasePart") and d.CanCollide and not isTrunk(d) and d.Size.Y > 1.2 then
				table.insert(obstacles, entryOf(d))
			end
			if d:IsA("BasePart") and (d.Name == "Wall" or d.Name == "Roof" or d.Name == "Crate") then
				table.insert(walls, d)
			end
		end
		local group = {}
		for i, d in ipairs(walls) do
			group[i] = group[i] or i
			for j = i + 1, #walls do
				if (walls[j].Position - d.Position).Magnitude < 12 and walls[j].Name ~= "Crate" and d.Name ~= "Crate" then
					local gi, gj = group[i], group[j] or j
					for k = 1, #walls do
						if group[k] == gj then group[k] = gi end
					end
					group[j] = gi
				end
			end
		end
		local sheds = {}
		for i, d in ipairs(walls) do
			sheds[group[i]] = sheds[group[i]] or {}
			table.insert(sheds[group[i]], d)
		end
		for _, list in pairs(sheds) do
			local lx, hx, lz, hz, low = math.huge, -math.huge, math.huge, -math.huge, math.huge
			local hasWall = false
			for _, d in ipairs(list) do
				local e = entryOf(d)
				if d.Name == "Wall" then
					hasWall = true
					lx, hx, lz, hz = math.min(lx, e.x0), math.max(hx, e.x1), math.min(lz, e.z0), math.max(hz, e.z1)
					low = math.min(low, e.lo)
				end
			end
			if hasWall then
				-- Crates inside it belong to it.
				for _, d in ipairs(walls) do
					if d.Name == "Crate" and d.Position.X >= lx and d.Position.X <= hx and d.Position.Z >= lz and d.Position.Z <= hz then
						table.insert(list, d)
					end
				end
				local s = addStructure(nil, "decor:hut", "Props", CFrame.new((lx + hx) / 2, low, (lz + hz) / 2), (hx - lx) / 2, (hz - lz) / 2, low,
					{ parts = list })
				s.name = "Shed"
				s.noBury = true
			end
		end
	end
end

-- Made ground, for `ground` below.
for _, top in ipairs(map:GetChildren()) do
	if top.Name == "Town" or top.Name == "Roads" or top.Name == "River" then
		for _, d in ipairs(top:GetDescendants()) do
			if d:IsA("BasePart") and (SLAB_NAMES[d.Name] or (d.Parent and d.Parent.Name == "ParkingLot")) then
				table.insert(slabs, entryOf(d))
			end
		end
	end
end

-- Every zipline, wherever it hangs: its posts (tall upright parts) stand on the ground.
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("Model") and d.Name == "Zipline" then
		for _, part in ipairs(d:GetDescendants()) do
			if part:IsA("BasePart") and part.Size.Y >= 5 and math.abs(part.CFrame.UpVector.Y) > 0.95 and part.Name ~= "ZiplineHandle" then
				measurePart(part, "zipline:post", "Zipline")
			end
		end
	end
end
if map:FindFirstChild("Ziplines") then
	for _, part in ipairs(map.Ziplines:GetChildren()) do
		if part:IsA("BasePart") then
			measurePart(part, "zipline:post", "Ziplines")
		end
	end
end

-- Measuring ----------------------------------------------------------------------------------------
-- The rendered ground, from two models of how smooth terrain draws a column: blended between column
-- centres (right for graded slopes), and the column's own top out to its edges (right at a cliff: a
-- plateau rim, a pad's retained edge). A gap counts only if BOTH models see it, and ground rising over
-- a floor only if both do: nothing is flagged that depends on which model Studio agrees with.
local function groundBoth(x, z)
	local blended = T.surface(x, z, true)
	local own = T.column(math.floor(x / 4), math.floor(z / 4))
	if not blended then
		return nil
	end
	own = own or blended
	return math.max(blended, own), math.min(blended, own)
end
-- Made ground: the pavements, squares, streets, roads, car parks and footbridge decks a thing can
-- stand on instead of the terrain (a theme's prop on the pavement, a vendor on the square's paving).
-- Only where it lies within a few studs of the terrain: a bridge deck high over a gorge is not ground
-- for what stands in the gorge.
local SLAB_CELL = 16
local slabGrid = {}
for _, entry in ipairs(slabs) do
	for cx = math.floor(entry.x0 / SLAB_CELL), math.floor(entry.x1 / SLAB_CELL) do
		for cz = math.floor(entry.z0 / SLAB_CELL), math.floor(entry.z1 / SLAB_CELL) do
			local key = cx * 100000 + cz
			slabGrid[key] = slabGrid[key] or {}
			table.insert(slabGrid[key], entry)
		end
	end
end
local function slabTop(x, z, terrain)
	local list = slabGrid[math.floor(x / SLAB_CELL) * 100000 + math.floor(z / SLAB_CELL)]
	local top = nil
	for _, e in ipairs(list or {}) do
		if x >= e.x0 and x <= e.x1 and z >= e.z0 and z <= e.z1 then
			local lo, hi = lineThrough(e, x, z)
			if hi and (not terrain or hi <= terrain + 3) and (not top or hi > top) then
				top = hi
			end
		end
	end
	return top
end
local function ground(x, z)
	local g = groundBoth(x, z)
	local slab = slabTop(x, z, g)
	if slab and (not g or slab > g) then
		return slab
	end
	return g
end
local function groundLow(x, z)
	local _, low = groundBoth(x, z)
	return low
end
local function wetAt(x, z)
	local dry = T.surface(x, z, true)
	local wet = T.surface(x, z, false)
	if dry and wet and wet > dry + 0.2 then
		return wet - dry
	end
	return nil
end

-- The lowest visible part of `s` on the vertical line through (x, z), among parts reaching down
-- to its floor band; its floor line where none does.
local function underside(s, x, z)
	local low = nil
	for _, e in ipairs(s.parts) do
		if x >= e.x0 - 0.01 and x <= e.x1 + 0.01 and z >= e.z0 - 0.01 and z <= e.z1 + 0.01 then
			local lo = lineThrough(e, x, z)
			if lo and (not low or lo < low) then
				low = lo
			end
		end
	end
	return low
end

local function outline(s)
	local points = {}
	local hx, hz = math.max(0.05, s.halfX - INSET), math.max(0.05, s.halfZ - INSET)
	if s.single then
		hx, hz = math.max(0.05, s.halfX * 0.8), math.max(0.05, s.halfZ * 0.8)
	end
	local nx = math.max(1, math.ceil(hx * 2 / EDGE_STEP))
	local nz = math.max(1, math.ceil(hz * 2 / EDGE_STEP))
	for i = 0, nx do
		local lx = -hx + 2 * hx * i / nx
		table.insert(points, { lx, -hz, "front" })
		table.insert(points, { lx, hz, "back" })
	end
	for j = 1, nz - 1 do
		local lf = -hz + 2 * hz * j / nz
		table.insert(points, { -hx, lf, "side" })
		table.insert(points, { hx, lf, "side" })
	end
	return points
end

-- Floating ----------------------------------------------------------------------------------------
--
-- Three questions, each for the structures it fits:
--
--   SILHOUETTE (a closed building: a town house, a cabin): along the outline of its declared
--     footprint, the lowest visible piece there (its plinth or skirt, trim included) against the
--     ground. Inside, the floor's underside is hidden by that skirt.
--   PIECES (anything open: a monument, an egg, a set piece, a camp, a wreck): every solid, level
--     piece meant to stand on something (its underside within BAND of the floor), sampled over its
--     own footprint, against whatever is under it -- the ground, or another piece it rests on. A piece
--     may overhang what carries it by OVERHANG (a lip, an eave); past that it is a cantilever over
--     the ground, which is what a deck corner off a pad or a stair into a pit looks like. What carries
--     it includes thin legs and posts the grid would miss: any piece whose top meets its underside.
--     A tipped board laid on the ground (a tent's side) must meet the ground all along its low edge.
--   ASSEMBLIES: pieces fixed together (touching, to a tenth of a stud) are one thing -- a tent, a wreck
--     and its wheels, a sign on its posts. One that comes down to the floor band and yet touches
--     neither the ground nor the rest of the structure is hanging in the air.
--
-- A single part (a post, a pier, a plank end) floats by its own underside; a small prop (a theme's
-- cart or topiary, a yard crate) when none of it reaches the ground.
local OVERHANG = 1.0

-- The support under (x, z) for a piece whose underside there is `lo`: the ground, or the top of any
-- other piece of `s` directly under it; true for `held` when another piece encloses that point.
local function supportAt(s, e, x, z, lo)
	local support = ground(x, z) or -math.huge
	for _, other in ipairs(s.all) do
		if other.part ~= e.part and x >= other.x0 and x <= other.x1 and z >= other.z0 and z <= other.z1 then
			local olo, ohi = lineThrough(other, x, z)
			if olo then
				if ohi <= lo + 0.05 then
					support = math.max(support, ohi)
				elseif olo < lo then
					return support, true
				end
			end
		end
	end
	return support, false
end

-- A grid over a piece's underside -- its own face that looks most nearly down -- along the face's
-- two axes, `inset` in from its edges. (On the face itself, not on a level cut through the middle: a
-- 40-stud truss leaning four degrees is two studs off its foot at half height.)
local function pieceGrid(e, step, inset)
	local axes = { { e.cf.r, e.size.X }, { e.cf.u, e.size.Y }, { e.cf.b, e.size.Z } }
	table.sort(axes, function(p, q) return math.abs(p[1].Y) < math.abs(q[1].Y) end)
	local a1, a2, up = axes[1], axes[2], axes[3]
	local down = up[1].Y > 0 and -up[2] / 2 or up[2] / 2
	local base = e.cf.p + up[1] * down
	local n1 = math.max(1, math.ceil(a1[2] / step))
	local n2 = math.max(1, math.ceil(a2[2] / step))
	local in1, in2 = math.min(inset, a1[2] / 4), math.min(inset, a2[2] / 4)
	local cells = {}
	for i = 0, n1 do
		for j = 0, n2 do
			local s1 = -a1[2] / 2 + in1 + (a1[2] - 2 * in1) * i / n1
			local s2 = -a2[2] / 2 + in2 + (a2[2] - 2 * in2) * j / n2
			-- A round end (a cylinder standing on its end) has no corners.
			local roundEnd = e.shape == "Cylinder" and up[1] == e.cf.r
			local radius = math.min(e.size.Y, e.size.Z) / 2 - math.min(in1, in2)
			if not roundEnd or s1 * s1 + s2 * s2 <= radius * radius then
				local point = base + a1[1] * s1 + a2[1] * s2
				table.insert(cells, { s1 = s1, s2 = s2, x = point.X, z = point.Z, y = point.Y })
			end
		end
	end
	return cells, a1, a2
end

-- Over a piece's world-axis box instead (a tipped or round piece: its low edge is what touches).
local function boxGrid(e, step)
	local cells = {}
	local nx = math.max(1, math.ceil((e.x1 - e.x0) / step))
	local nz = math.max(1, math.ceil((e.z1 - e.z0) / step))
	for i = 0, nx do
		for j = 0, nz do
			table.insert(cells, { x = e.x0 + (e.x1 - e.x0) * (i + 0.5) / (nx + 1), z = e.z0 + (e.z1 - e.z0) * (j + 0.5) / (nz + 1) })
		end
	end
	return cells
end

local function isRound(e)
	return e.shape == "Ball" or (e.shape == "Cylinder" and math.abs(e.cf.r.Y) < 0.99)
end
local function isTipped(e)
	local up = math.max(math.abs(e.cf.r.Y), math.abs(e.cf.u.Y), math.abs(e.cf.b.Y))
	return up < 0.995
end

local function worse(v, gap, x, z, support, e, rule)
	if gap > v.gap then
		v.gap, v.gapAt = gap, { x, z, support, e and e.name, e, rule }
	end
end

local function measurePieces(s, v)
	for _, e in ipairs(s.parts) do
		if e.part.CanCollide and not isRound(e) then
			if isTipped(e) then
				-- A board laid on the ground along one level edge: where it touches at all, it must
				-- touch all along that edge.
				local level = math.abs(e.cf.r.Y) < 0.02 or math.abs(e.cf.b.Y) < 0.02 or math.abs(e.cf.u.Y) < 0.02
				local board = math.min(e.size.X, e.size.Y, e.size.Z) <= 0.5
				if level and board then
					local cells, lowLo = {}, math.huge
					for _, c in ipairs(boxGrid(e, 1)) do
						local lo = lineThrough(e, c.x, c.z)
						if lo then
							local support = supportAt(s, e, c.x, c.z, lo)
							c.lo, c.gap, c.support = lo, lo - support, support
							lowLo = math.min(lowLo, lo)
							table.insert(cells, c)
						end
					end
					local touch, worst = math.huge, nil
					for _, c in ipairs(cells) do
						if c.lo <= lowLo + 0.3 then
							touch = math.min(touch, c.gap)
							if not worst or c.gap > worst.gap then worst = c end
						end
					end
					if touch <= FLOAT and worst and worst.gap > FLOAT then
						worse(v, worst.gap, worst.x, worst.z, worst.support, e, "board")
					end
				end
			else
				-- A level piece: where is it carried, and how far past that does it reach over lower ground?
				local cells, a1, a2 = pieceGrid(e, EDGE_STEP, 0.2)
				local lo1, hi1, lo2, hi2 = math.huge, -math.huge, math.huge, -math.huge
				local function carried(p1, p2)
					lo1, hi1 = math.min(lo1, p1), math.max(hi1, p1)
					lo2, hi2 = math.min(lo2, p2), math.max(hi2, p2)
				end
				local bottom = e.cf.p.Y - e.size.Y / 2 * math.abs(e.cf.u.Y) - e.size.X / 2 * math.abs(e.cf.r.Y) - e.size.Z / 2 * math.abs(e.cf.b.Y)
				for _, c in ipairs(cells) do
					-- The underside face's own height there (a leaning leg's foot, not where a vertical line
					-- through that point first meets its side).
					local lo = c.y
					local support, held = supportAt(s, e, c.x, c.z, lo)
					c.gap, c.support = held and 0 or lo - support, support
					if c.gap <= FLOAT then
						carried(c.s1, c.s2)
					end
				end
				-- Legs, posts and brackets the grid steps over: anything whose top meets this underside.
				for _, other in ipairs(s.all) do
					if other.part ~= e.part and other.hi >= bottom - 0.1 and other.hi <= bottom + 0.3 and other.lo < bottom
						and other.x0 <= e.x1 and e.x0 <= other.x1 and other.z0 <= e.z1 and e.z0 <= other.z1 then
						local dx, dz = other.cf.p.X - e.cf.p.X, other.cf.p.Z - e.cf.p.Z
						local p1 = dx * a1[1].X + dz * a1[1].Z
						local p2 = dx * a2[1].X + dz * a2[1].Z
						local r1 = math.abs(a1[1].X) * (other.x1 - other.x0) / 2 + math.abs(a1[1].Z) * (other.z1 - other.z0) / 2
						local r2 = math.abs(a2[1].X) * (other.x1 - other.x0) / 2 + math.abs(a2[1].Z) * (other.z1 - other.z0) / 2
						carried(p1 - r1, p2 - r2)
						carried(p1 + r1, p2 + r2)
					end
				end
				-- A post or pole (upright, taller than it is wide) stands on something or hangs in the air.
				local tall = math.abs(e.cf.u.Y) > 0.995 and e.size.Y >= 1.5 * math.max(e.size.X, e.size.Z)
				-- Anything else is judged by its overhang only if it mostly stands on something: a sign
				-- board between its posts or a cowcatcher on the front of its engine is held from the
				-- side, and that is its assembly's business.
				local held = 0
				for _, c in ipairs(cells) do
					if c.gap <= FLOAT then
						held += 1
					end
				end
				if tall and held == 0 and lo1 == math.huge then
					local best = nil
					for _, c in ipairs(cells) do
						if not best or c.gap < best.gap then best = c end
					end
					if best then
						worse(v, best.gap, best.x, best.z, best.support, e, "post")
					end
				elseif held >= 0.3 * #cells then
					for _, c in ipairs(cells) do
						if c.gap > FLOAT then
							local out1 = math.max(lo1 - c.s1, c.s1 - hi1, 0)
							local out2 = math.max(lo2 - c.s2, c.s2 - hi2, 0)
							if out1 > OVERHANG or out2 > OVERHANG then
								worse(v, c.gap, c.x, c.z, c.support, e, "overhang")
							end
						end
					end
				end
			end
		end
	end
end

local function measureAssemblies(s, v)
	-- Every visible piece, trim included: a rail laid as trim still carries the cowcatcher over it.
	local all = s.all
	local parent = {}
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	for i = 1, #all do parent[i] = i end
	for i = 1, #all do
		local a = all[i]
		for j = i + 1, #all do
			local b = all[j]
			if a.x0 <= b.x1 + 0.15 and b.x0 <= a.x1 + 0.15 and a.z0 <= b.z1 + 0.15 and b.z0 <= a.z1 + 0.15
				and a.lo <= b.hi + 0.15 and b.lo <= a.hi + 0.15 then
				parent[find(i)] = find(j)
			end
		end
	end
	local lowest, where, bottom = {}, {}, {}
	for i, e in ipairs(all) do
		local root = find(i)
		bottom[root] = math.min(bottom[root] or math.huge, e.lo)
		for _, c in ipairs(boxGrid(e, 1.5)) do
			local lo = lineThrough(e, c.x, c.z)
			local g = lo and ground(c.x, c.z)
			if g and (not lowest[root] or lo - g < lowest[root]) then
				lowest[root], where[root] = lo - g, { c.x, c.z, g, e.name, e }
			end
		end
	end
	for root, gap in pairs(lowest) do
		if gap > FLOAT and bottom[root] <= s.base + BAND then
			local w = where[root]
			worse(v, gap, w[1], w[2], w[3], w[5], "assembly")
		end
	end
end

local function measureProp(s, v)
	local lowest, at = math.huge, nil
	for _, e in ipairs(s.all) do
		for _, c in ipairs(boxGrid(e, 1)) do
			local lo = lineThrough(e, c.x, c.z)
			local g = lo and ground(c.x, c.z)
			if g and lo - g < lowest then
				lowest, at = lo - g, { c.x, c.z, g, e.name, e }
			end
		end
	end
	v.gap, v.gapAt = lowest, at
end

for _, s in ipairs(structures) do
	local v = s.v
	v.gap, v.buried, v.gapAt, v.buriedAt = -math.huge, -math.huge, nil, nil
	v.points = 0
	-- The outline: ground rising over the floor line (a wall swallowed), and for a closed building or
	-- a single part, the silhouette's own gap.
	for _, pt in ipairs(outline(s)) do
		local x, z = at(s, pt[1], pt[2])
		local g = ground(x, z)
		v.points += 1
		-- Only where the structure has something solid: open ground inside the outline (in front of a
		-- plinth, between a sign's posts) neither floats nor is buried.
		local under = s.single and s.base or underside(s, x, z)
		if not under then
			v.open = (v.open or 0) + 1
		elseif not g then
			v.gap, v.gapAt = math.huge, { x, z, "nothing" }
		else
			if s.single or s.strict then
				worse(v, under - g, x, z, g, nil, "silhouette")
			end
			local rise = groundLow(x, z) - (s.deckTop or s.base)
			if rise > v.buried and not s.noBury then v.buried, v.buriedAt = rise, { x, z, g } end
		end
	end
	if s.prop then
		measureProp(s, v)
	elseif not s.single and not s.strict then
		measurePieces(s, v)
		measureAssemblies(s, v)
	elseif s.strict then
		-- A closed building's pieces still hang together: a porch, a chimney stack or a lean-to added
		-- to it is judged as an assembly.
		measureAssemblies(s, v)
	end
	-- Water and trees over the whole footprint, a grid a stud or two apart.
	v.water, v.trees = 0, 0
	if not s.single then
		local nx = math.max(1, math.ceil(s.halfX * 2 / 3))
		local nz = math.max(1, math.ceil(s.halfZ * 2 / 3))
		for i = 0, nx do
			for j = 0, nz do
				local x, z = at(s, -s.halfX + 2 * s.halfX * i / nx, -s.halfZ + 2 * s.halfZ * j / nz)
				if wetAt(x, z) then v.water += 1 end
			end
		end
		for _, tree in ipairs(trees) do
			if insideRect(s, tree.x, tree.z, tree.r * 0.5) and not (s.model and tree.part:IsDescendantOf(s.model)) then
				v.trees += 1
				v.treeAt = { tree.x, tree.z }
			end
		end
	end
end

-- Rectangles overlap (separating axis in the ground plane); returns the penetration depth.
local function rectCorners(cx, cz, rx, rz, fx, fz, hx, hz)
	return {
		{ cx + rx * hx + fx * hz, cz + rz * hx + fz * hz },
		{ cx - rx * hx + fx * hz, cz - rz * hx + fz * hz },
		{ cx - rx * hx - fx * hz, cz - rz * hx - fz * hz },
		{ cx + rx * hx - fx * hz, cz + rz * hx - fz * hz },
	}
end
local function project(corners, ax, az)
	local lo, hi = math.huge, -math.huge
	for _, c in ipairs(corners) do
		local d = c[1] * ax + c[2] * az
		lo, hi = math.min(lo, d), math.max(hi, d)
	end
	return lo, hi
end
local function penetration(a, b)
	local depth = math.huge
	for _, axis in ipairs({ { a.ax1, a.az1 }, { a.ax2, a.az2 }, { b.ax1, b.az1 }, { b.ax2, b.az2 } }) do
		local l1, h1 = project(a.corners, axis[1], axis[2])
		local l2, h2 = project(b.corners, axis[1], axis[2])
		local overlap = math.min(h1, h2) - math.max(l1, l2)
		if overlap <= 0 then return 0 end
		depth = math.min(depth, overlap)
	end
	return depth
end
local function rectOfStructure(s)
	-- A prop's declared footprint is the square round the circle it claims; its body is round-ish, so
	-- its corners are not its body. The square inscribed in that circle is.
	local hx, hz = s.halfX, s.halfZ
	if s.prop then
		hx, hz = hx * 0.71, hz * 0.71
	end
	return { corners = rectCorners(s.cx, s.cz, s.rx, s.rz, s.fx, s.fz, hx, hz), ax1 = s.rx, az1 = s.rz, ax2 = s.fx, az2 = s.fz,
		x0 = s.cx - s.halfX - s.halfZ, x1 = s.cx + s.halfX + s.halfZ, z0 = s.cz - s.halfX - s.halfZ, z1 = s.cz + s.halfX + s.halfZ }
end
local function rectOfEntry(e)
	local cf, sz = e.cf, e.size
	-- The part's footprint: its two most horizontal axes.
	local axes = { { cf.r, sz.X }, { cf.u, sz.Y }, { cf.b, sz.Z } }
	table.sort(axes, function(p, q) return math.abs(p[1].Y) < math.abs(q[1].Y) end)
	local a1, a2 = axes[1], axes[2]
	local function unit(v)
		local m = math.sqrt(v.X * v.X + v.Z * v.Z)
		if m < 1e-6 then return 1, 0 end
		return v.X / m, v.Z / m
	end
	local ax1, az1 = unit(a1[1])
	local ax2, az2 = unit(a2[1])
	local h1 = a1[2] / 2 * math.sqrt(a1[1].X ^ 2 + a1[1].Z ^ 2)
	local h2 = a2[2] / 2 * math.sqrt(a2[1].X ^ 2 + a2[1].Z ^ 2)
	local p = cf.p
	return { corners = rectCorners(p.X, p.Z, ax1, az1, ax2, az2, h1, h2), ax1 = ax1, az1 = az1, ax2 = ax2, az2 = az2,
		x0 = e.x0, x1 = e.x1, z0 = e.z0, z1 = e.z1 }
end

for _, s in ipairs(structures) do
	s.rect = rectOfStructure(s)
	s.v.overlaps = {}
end
local function boxesMeet(a, b)
	return a.x0 <= b.x1 and b.x0 <= a.x1 and a.z0 <= b.z1 and b.z0 <= a.z1
end

-- Which structures a pair check is for: a structure and the props that belong to it (the dock
-- barrels inside a warehouse) are one thing; zipline posts, piers and legs are checked against
-- the ground only (a post on a landmark's platform is meant to be there).
local function overlapKind(s)
	return not (s.kind == "zipline:post" or s.kind == "bridge:pier" or s.kind:find("^footbridge"))
end
-- Pieces of one thing, measured apart: a scenery hut's four walls, a yard's pair of barrels.
local function sameThing(a, b)
	if a.kind == "decor:hut" and b.kind == "decor:hut" then
		return true
	end
	if a.kind == "town:yardprop" and b.kind == "town:yardprop" then
		local dx, dz = a.cx - b.cx, a.cz - b.cz
		return dx * dx + dz * dz < 4.5 * 4.5
	end
	return false
end
for i = 1, #structures do
	local a = structures[i]
	if overlapKind(a) then
		for j = i + 1, #structures do
			local b = structures[j]
			if overlapKind(b) and boxesMeet(a.rect, b.rect) then
				local nested = (a.model and b.model and (b.model:IsDescendantOf(a.model) or a.model:IsDescendantOf(b.model)))
					or sameThing(a, b)
				if not nested then
					local depth = penetration(a.rect, b.rect)
					if depth > OVERLAP then
						table.insert(a.v.overlaps, { with = b.kind .. " " .. b.name, depth = depth })
						table.insert(b.v.overlaps, { with = a.kind .. " " .. a.name, depth = depth })
					end
				end
			end
		end
		for _, c in ipairs(carriageways) do
			-- A town building's front step meets its pavement; the carriageways here are the roads,
			-- streets, crossings, bridges, car parks and the square's paving, none of which it may reach.
			c.rect = c.rect or rectOfEntry(c.entry)
			if boxesMeet(a.rect, c.rect) then
				local depth = penetration(a.rect, c.rect)
				local allowed = OVERLAP
				-- Theme flags and props stand on the square's paving and the verges on purpose.
				if (a.kind == "theme:flag" or a.kind == "theme:prop") and (c.what == "square") then
					allowed = math.huge
				end
				if depth > allowed then
					table.insert(a.v.overlaps, { with = c.what .. " " .. c.entry.name, depth = depth })
				end
			end
		end
		-- The river: any footprint point inside its channel (MapTerrain.InRiver, no margin).
		if built.river and MapTerrain.InRiver and not a.single then
			local inRiver = 0
			for _, pt in ipairs(outline(a)) do
				local x, z = at(a, pt[1], pt[2])
				if MapTerrain.InRiver(built.river, x, z, 0) then inRiver += 1 end
			end
			if inRiver > 0 then
				table.insert(a.v.overlaps, { with = "river", depth = inRiver })
			end
		end
	end
end

-- Doors ------------------------------------------------------------------------------------------
local function blockedBy(x, z, self)
	for _, s in ipairs(structures) do
		if s ~= self and overlapKind(s) and not (self.model and s.model and s.model:IsDescendantOf(self.model)) and insideRect(s, x, z, 0) then
			return s.kind .. " " .. s.name
		end
	end
	for _, tree in ipairs(trees) do
		local dx, dz = x - tree.x, z - tree.z
		if dx * dx + dz * dz <= (tree.r + 0.5) ^ 2 and not (self.model and tree.part:IsDescendantOf(self.model)) then
			return "tree"
		end
	end
	for _, e in ipairs(obstacles) do
		if x >= e.x0 and x <= e.x1 and z >= e.z0 and z <= e.z1 and not (self.model and e.part:IsDescendantOf(self.model)) then
			local lo = lineThrough(e, x, z)
			if lo and lo < self.base + 5 then
				return "prop " .. e.name
			end
		end
	end
	return nil
end

for _, s in ipairs(structures) do
	if s.door then
		local v = s.v
		local half = math.min(s.door.half, s.halfX * 0.6)
		-- Just outside the door: the ground there against the floor.
		local sx, sz = at(s, 0, s.halfZ + 1.0)
		local g = ground(sx, sz)
		-- Against the door's own floor: a town building's threshold is its floor top, half a stud up.
		v.sill = g and (g - s.base - (s.door.sill or 0)) or math.huge
		v.doorClear = DOOR_CLEAR
		for step = 0.5, DOOR_CLEAR, 0.5 do
			local why = nil
			for _, lane in ipairs({ -half, 0, half }) do
				local x, z = at(s, lane, s.halfZ + step)
				local gg = ground(x, z)
				why = why or blockedBy(x, z, s)
				if not why and wetAt(x, z) then why = "water" end
				if not why and gg and gg - s.base > RISE then why = string.format("bank %.1f up", gg - s.base) end
				if not why and gg and step <= 4 and s.base - gg > DROP then why = string.format("drop %.1f", s.base - gg) end
				if not why and not gg then why = "nothing" end
				if why then break end
			end
			if why then
				v.doorClear, v.doorWhy = step - 0.5, why
				break
			end
		end
		-- A town's buildings and set pieces open onto a street, a pavement or the square: within
		-- FACE_REACH of the door there is made ground, not a back yard, a field or a wall.
		local town = s.model and s.model:FindFirstAncestor("Town")
		local centre = town and town:GetAttribute("TownCenter")
		if s.door.street and s.model:GetAttribute("OnStreet") == false and centre then
			-- A set piece round the edge of town has no street: it faces the square across the town.
			local dx, dz = centre.X - s.cx, centre.Z - s.cz
			local m = math.sqrt(dx * dx + dz * dz)
			v.facing = m > 0 and (dx * s.fx + dz * s.fz) / m >= math.cos(math.rad(35)) and 0 or nil
		elseif s.door.street then
			v.facing = nil
			for step = 0.5, FACE_REACH, 0.5 do
				local x, z = at(s, 0, s.halfZ + step)
				if slabTop(x, z, nil) then
					v.facing = step
					break
				end
			end
		end
	end
end

-- Verdicts ---------------------------------------------------------------------------------------
local violations = {}
local function flag(s, what, value, detail)
	table.insert(violations, { kind = s.kind, name = s.name, what = what, value = value, detail = detail or "",
		x = s.cx, z = s.cz, base = s.base })
end
for _, s in ipairs(structures) do
	local v = s.v
	if v.gap > FLOAT then
		flag(s, "floating", v.gap, v.gapAt and string.format("at (%.0f,%.0f)%s [%s]", v.gapAt[1], v.gapAt[2], v.gapAt[4] and (" " .. v.gapAt[4]) or "", tostring(v.gapAt[6])) or "")
	end
	local bury = s.strict and BURY_FLOOR or BURY_OPEN
	-- Posts, piers and legs are driven into the ground on purpose.
	if (not s.single or s.deckTop) and v.buried > (s.deckTop and SILL or bury) then
		flag(s, "buried", v.buried, v.buriedAt and string.format("at (%.0f,%.0f)", v.buriedAt[1], v.buriedAt[2]) or "")
	end
	if s.door and v.sill > SILL then
		flag(s, "sill", v.sill)
	end
	if s.door and v.doorClear < DOOR_CLEAR then
		flag(s, "door", v.doorClear, v.doorWhy)
	end
	if s.door and s.door.street and not v.facing then
		flag(s, "facing", FACE_REACH, "no street, pavement or square in front of its door (or, off the streets, not facing the square)")
	end
	for _, o in ipairs(v.overlaps) do
		flag(s, "overlap", o.depth, o.with)
	end
	if v.water > 0 then
		flag(s, "water", v.water)
	end
	if v.trees > 0 then
		flag(s, "tree", v.trees)
	end
end

local summary = {}
for _, s in ipairs(structures) do
	summary[s.kind] = summary[s.kind] or { n = 0, maxGap = -math.huge, maxBury = -math.huge, maxSill = -math.huge, minDoor = math.huge }
	local e = summary[s.kind]
	e.n += 1
	e.maxGap = math.max(e.maxGap, s.v.gap)
	if not s.single then e.maxBury = math.max(e.maxBury, s.v.buried) end
	if s.v.sill then e.maxSill = math.max(e.maxSill, s.v.sill) end
	if s.v.doorClear then e.minDoor = math.min(e.minDoor, s.v.doorClear) end
end

return { structures = structures, violations = violations, summary = summary, skipped = skipped, counts = counts,
	trees = #trees, obstacles = #obstacles, carriageways = #carriageways }
