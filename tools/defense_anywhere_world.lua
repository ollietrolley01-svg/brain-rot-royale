-- The world for tools/defense_anywhere_check.py (#128 "place defenses anywhere"). Plain Lua (lupa),
-- loaded after tools/destruct_mocks.lua, which supplies Vector3, CFrame and the Instance tree. This
-- file adds what placement READS: raycasts against every part (exact, rotated boxes) and against a
-- heightfield terrain with water, GetPartBoundsInBox the way Roblox answers it (bounding boxes, so a
-- sloped slab "overlaps" what is above its ridge), CollectionService tags, a camera, a deep Clone for
-- the preview's templates, and module loading for the REAL DefensePlacement, DefenseService,
-- DefensePreview, ItemData, ItemModels, ZFight and SafeValue. The rest of the server is stubs.
--
-- Then the scenes and the measurements. The measurements are written here on their own, from the
-- geometry of what was built -- they never ask DefensePlacement anything -- so a placement rule that
-- is wrong cannot also be the rule that marks it right.

local mock, sources = ...
-- Plain Lua's loader (the modules are compiled with their own `script`).
local compileChunk = rawget(_G, "load")
local W = {}
W.problems = {}
W.lines = {}

local V = Vector3.new
workspace.Gravity = 196.2

-- A Vector2 with arithmetic (the mock's is a bare record; ZFight does sums with them).
local V2 = {}
V2.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y)
		return Vector2.new(v.X / m, v.Y / m)
	end
	return V2[key]
end
V2.__add = function(a, b) return Vector2.new(a.X + b.X, a.Y + b.Y) end
V2.__sub = function(a, b) return Vector2.new(a.X - b.X, a.Y - b.Y) end
V2.__mul = function(a, b)
	if type(a) == "number" then return Vector2.new(a * b.X, a * b.Y) end
	if type(b) == "number" then return Vector2.new(a.X * b, a.Y * b) end
	return Vector2.new(a.X * b.X, a.Y * b.Y)
end
V2.__unm = function(a) return Vector2.new(-a.X, -a.Y) end
function V2.Dot(a, b) return a.X * b.X + a.Y * b.Y end
Vector2 = { new = function(x, y) return setmetatable({ X = x or 0, Y = y or 0, __type = "Vector2" }, V2) end }
Vector2.zero = Vector2.new(0, 0)

--------------------------------------------------------------------------------
-- Services the modules touch
--------------------------------------------------------------------------------
local Players = game:GetService("Players")
Players.PlayerRemoving = mock.signal()
Players.LocalPlayer.UserId = 1
local RunService = game:GetService("RunService")
RunService.IsRunning = function() return false end
local CollectionService = game:GetService("CollectionService")
W.tagged = {}
CollectionService.GetTagged = function(_, tag) return W.tagged[tag] or {} end

local camera = mock.newInstance("Camera")
camera.Name = "Camera"
camera.ViewportSize = V(1280, 720, 0)
camera.Parent = workspace
workspace.CurrentCamera = camera

-- A deep Clone (the mock's copies properties only; the preview clones whole templates).
local I = getmetatable(workspace)
local shallowClone = I.Clone
I.Clone = function(inst)
	local copy = shallowClone(inst)
	for _, child in ipairs(inst:GetChildren()) do
		child:Clone().Parent = copy
	end
	return copy
end
-- Every parenting marks the part list stale, so raycasts can keep one list between changes.
local oldNewIndex = I.__newindex
W.dirty = true
I.__newindex = function(inst, key, value)
	if key == "Parent" then
		W.dirty = true
	end
	return oldNewIndex(inst, key, value)
end

--------------------------------------------------------------------------------
-- Terrain: a heightfield (nil = no ground: off the map) and boxes of water.
--------------------------------------------------------------------------------
W.height = function() return 0 end
W.waters = {}

local function waterAt(x, z)
	for _, w in ipairs(W.waters) do
		if x >= w[1] and x <= w[2] and z >= w[3] and z <= w[4] then
			return w[5]
		end
	end
	return nil
end
W.waterAt = waterAt

local function solidAt(p, ignoreWater)
	local g = W.height(p.X, p.Z)
	if g and p.Y < g then
		return "ground"
	end
	if not ignoreWater then
		local s = waterAt(p.X, p.Z)
		if s and p.Y < s then
			return "water"
		end
	end
	return nil
end

-- A terrain ray: exact for vertical rays, marched and bisected otherwise. A ray that starts inside the
-- ground reports nothing until it has come out (Roblox does not report the voxel a ray starts in).
local function rayTerrain(origin, dir, ignoreWater)
	local length = dir.Magnitude
	if length < 1e-9 then
		return nil
	end
	if math.abs(dir.X) < 1e-9 and math.abs(dir.Z) < 1e-9 then
		if dir.Y > 0 then
			return nil
		end
		local g = W.height(origin.X, origin.Z)
		local s = (not ignoreWater) and waterAt(origin.X, origin.Z) or nil
		local topY, kind = g, "ground"
		if s and (not topY or s > topY) then
			topY, kind = s, "water"
		end
		if not topY or origin.Y < topY or origin.Y + dir.Y > topY then
			return nil
		end
		return (origin.Y - topY) / -dir.Y, kind
	end
	local steps = math.max(1, math.ceil(length / 0.4))
	local inside = solidAt(origin, ignoreWater) ~= nil
	local previous = 0
	for index = 1, steps do
		local t = index / steps
		local kind = solidAt(origin + dir * t, ignoreWater)
		if kind and not inside then
			local lo, hi = previous, t
			for _ = 1, 40 do
				local mid = (lo + hi) / 2
				if solidAt(origin + dir * mid, ignoreWater) then hi = mid else lo = mid end
			end
			return hi, solidAt(origin + dir * hi, ignoreWater) or kind
		end
		inside = kind ~= nil
		previous = t
	end
	return nil
end

--------------------------------------------------------------------------------
-- Parts
--------------------------------------------------------------------------------
local partList = {}
local function allParts()
	if W.dirty then
		partList = {}
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(partList, d)
			end
		end
		W.dirty = false
	end
	return partList
end
W.allParts = allParts

local function excluded(inst, list)
	for _, e in ipairs(list or {}) do
		if inst == e or inst:IsDescendantOf(e) then
			return true
		end
	end
	return false
end

-- A ray against one rotated box: the entering t in [0, 1] and the face normal, or nil. A ray that
-- starts inside the box does not hit it (Roblox's rule too).
local function rayPart(part, origin, dir)
	local cf, size = part.CFrame, part.Size
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(dir)
	local h = { size.X / 2, size.Y / 2, size.Z / 2 }
	local oo, dd = { o.X, o.Y, o.Z }, { d.X, d.Y, d.Z }
	if math.abs(oo[1]) < h[1] and math.abs(oo[2]) < h[2] and math.abs(oo[3]) < h[3] then
		return nil
	end
	local tmin, tmax, axis, sign = 0, 1, nil, 0
	for i = 1, 3 do
		if math.abs(dd[i]) < 1e-12 then
			if math.abs(oo[i]) > h[i] then
				return nil
			end
		else
			local t1 = (-h[i] - oo[i]) / dd[i]
			local t2 = (h[i] - oo[i]) / dd[i]
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, axis, sign = t1, i, s
			end
			if t2 < tmax then
				tmax = t2
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	if not axis then
		return nil
	end
	local axes = { cf.RightVector, cf.UpVector, -cf.LookVector }
	return tmin, axes[axis] * sign
end

W.rayCount = 0
function workspace.Raycast(_, origin, dir, params)
	W.rayCount = W.rayCount + 1
	params = params or {}
	local list = params.FilterDescendantsInstances or {}
	local best, normal, instance, material = nil, nil, nil, nil
	for _, part in ipairs(allParts()) do
		if part.CanQuery ~= false and not (params.RespectCanCollide and not part.CanCollide) and not excluded(part, list) then
			local t, n = rayPart(part, origin, dir)
			if t and (not best or t < best) then
				best, normal, instance, material = t, n, part, part.Material
			end
		end
	end
	local terrain = workspace.Terrain
	if not excluded(terrain, list) then
		local t, kind = rayTerrain(origin, dir, params.IgnoreWater)
		if t and (not best or t < best) then
			best, normal, instance = t, V(0, 1, 0), terrain
			material = kind == "water" and Enum.Material.Water or Enum.Material.Grass
		end
	end
	if not best then
		return nil
	end
	return { Position = origin + dir * best, Normal = normal, Instance = instance, Material = material, Distance = dir.Magnitude * best }
end

-- How deep two boxes interpenetrate (the smallest overlap over the separating axes), <= 0 when apart.
function W.overlapDepth(cfA, sizeA, cfB, sizeB)
	local a = { cfA.RightVector, cfA.UpVector, cfA.LookVector }
	local b = { cfB.RightVector, cfB.UpVector, cfB.LookVector }
	local ha = { sizeA.X / 2, sizeA.Y / 2, sizeA.Z / 2 }
	local hb = { sizeB.X / 2, sizeB.Y / 2, sizeB.Z / 2 }
	local axes = { a[1], a[2], a[3], b[1], b[2], b[3] }
	for i = 1, 3 do
		for j = 1, 3 do
			local c = a[i]:Cross(b[j])
			if c.Magnitude > 1e-6 then
				table.insert(axes, c.Unit)
			end
		end
	end
	local d = cfB.Position - cfA.Position
	local least = math.huge
	for _, axis in ipairs(axes) do
		local ra = ha[1] * math.abs(a[1]:Dot(axis)) + ha[2] * math.abs(a[2]:Dot(axis)) + ha[3] * math.abs(a[3]:Dot(axis))
		local rb = hb[1] * math.abs(b[1]:Dot(axis)) + hb[2] * math.abs(b[2]:Dot(axis)) + hb[3] * math.abs(b[3]:Dot(axis))
		least = math.min(least, ra + rb - math.abs(d:Dot(axis)))
	end
	return least
end

local function worldBounds(part)
	local cf, s = part.CFrame, part.Size
	local r, u, b = cf.RightVector, cf.UpVector, cf.LookVector
	local ex = math.abs(r.X) * s.X / 2 + math.abs(u.X) * s.Y / 2 + math.abs(b.X) * s.Z / 2
	local ey = math.abs(r.Y) * s.X / 2 + math.abs(u.Y) * s.Y / 2 + math.abs(b.Y) * s.Z / 2
	local ez = math.abs(r.Z) * s.X / 2 + math.abs(u.Z) * s.Y / 2 + math.abs(b.Z) * s.Z / 2
	return CFrame.new(cf.Position), V(2 * ex, 2 * ey, 2 * ez)
end

-- Roblox answers with each part's bounding box, not its shape: that is modelled, deliberately.
function workspace.GetPartBoundsInBox(_, cf, size, params)
	local out = {}
	local list = params and params.FilterDescendantsInstances or {}
	for _, part in ipairs(allParts()) do
		if part.CanQuery ~= false and not excluded(part, list) then
			local bcf, bsize = worldBounds(part)
			if W.overlapDepth(bcf, bsize, cf, size) > 0 then
				table.insert(out, part)
			end
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------
local loaded = {}
local stubs = {}
local function folder(name, parent)
	local f = Instance.new("Folder")
	f.Name = name
	f.Parent = parent
	return f
end
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local shared = folder("Shared", ReplicatedStorage)
local modules = folder("Modules", ServerScriptService)
local playerScripts = folder("StarterPlayerScripts", nil)
local function moduleInstance(name, parent)
	local inst = mock.newInstance("ModuleScript")
	inst.Name = name
	inst.Parent = parent
	return inst
end
for _, name in ipairs({ "DefensePlacement", "ItemData", "ItemModels", "ZFight", "SafeValue", "Remotes", "ThrowableModels" }) do
	moduleInstance(name, shared)
end
for _, name in ipairs({ "DefenseService", "CombatService", "HazardService", "DestructibleService", "LootService",
	"QuestService", "StateSync", "WeaponService" }) do
	moduleInstance(name, modules)
end
moduleInstance("DefensePreview", playerScripts)

W.dropped, W.notes = {}, {}
W.fired = {}
local remoteEvents = {}
stubs.Remotes = { Event = function(name)
	if not remoteEvents[name] then
		W.fired[name] = {}
		remoteEvents[name] = { FireAllClients = function(_, info) table.insert(W.fired[name], info) end, FireClient = function() end }
	end
	return remoteEvents[name]
end, Function = function() return {} end }
stubs.CombatService = { ConfirmHit = function() end }
stubs.HazardService = { Mine = function() return nil end }
stubs.DestructibleService = { OnPartBroken = function() end, RestingOn = function() return {} end, SettleDown = function() end }
stubs.LootService = { DropItem = function(id, position) table.insert(W.dropped, { id = id, position = position }) end }
stubs.QuestService = { Progress = function() end }
stubs.StateSync = { Notify = function(_, text) table.insert(W.notes, text) end }
stubs.WeaponService = {}

function require(inst)
	local name = type(inst) == "table" and inst.Name or tostring(inst)
	if loaded[name] ~= nil then
		return loaded[name]
	end
	if stubs[name] then
		loaded[name] = stubs[name]
		return stubs[name]
	end
	local src = sources[name]
	if not src then
		error("no module " .. tostring(name))
	end
	local env = setmetatable({ script = inst }, { __index = _G, __newindex = _G })
	local chunk, err = compileChunk(src, "=" .. name, "t", env)
	if not chunk then
		error(name .. ": " .. tostring(err))
	end
	local result = chunk()
	loaded[name] = result
	return result
end

local DefensePlacement = require(shared.DefensePlacement)
local DefenseService = require(modules.DefenseService)
local DefensePreview = require(playerScripts.DefensePreview)
local WeaponService = stubs.WeaponService
DefenseService.PublishTemplates()

--------------------------------------------------------------------------------
-- World building
--------------------------------------------------------------------------------
local mapFolder
local function reset()
	DefenseService.Clear()
	for _, child in ipairs(workspace:GetChildren()) do
		if child ~= workspace.Terrain and child ~= camera then
			child:Destroy()
		end
	end
	for _, child in ipairs(camera:GetChildren()) do
		child:Destroy()
	end
	W.height = function() return 0 end
	W.waters = {}
	W.tagged = {}
	W.dropped, W.notes = {}, {}
	mapFolder = folder("Map", workspace)
	W.dirty = true
end

local function block(name, size, cf, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cf) == "Vector3" and CFrame.new(cf) or cf
	part.Anchored = true
	part.Parent = parent or mapFolder
	return part
end

-- A hollow building: four walls, a roof, and optional doorway in its -X wall.
local function building(centre, width, depth, height, doorway, parent)
	local model = Instance.new("Model")
	model.Name = "Building"
	model.Parent = parent or mapFolder
	local x0, x1 = centre.X - width / 2, centre.X + width / 2
	local z0, z1 = centre.Z - depth / 2, centre.Z + depth / 2
	local y = centre.Y
	block("Roof", V(width, 1, depth), V(centre.X, y + height + 0.5, centre.Z), model)
	block("Wall", V(width, height, 1), V(centre.X, y + height / 2, z0 + 0.5), model)
	block("Wall", V(width, height, 1), V(centre.X, y + height / 2, z1 - 0.5), model)
	block("Wall", V(1, height, depth), V(x1 - 0.5, y + height / 2, centre.Z), model)
	if doorway then
		local half = doorway.width / 2
		local left = (centre.Z - half) - z0
		local right = z1 - (centre.Z + half)
		block("Wall", V(1, height, left), V(x0 + 0.5, y + height / 2, z0 + left / 2), model)
		block("Wall", V(1, height, right), V(x0 + 0.5, y + height / 2, z1 - right / 2), model)
		block("Lintel", V(1, height - doorway.height, doorway.width), V(x0 + 0.5, y + doorway.height + (height - doorway.height) / 2, centre.Z), model)
	else
		block("Wall", V(1, height, depth), V(x0 + 0.5, y + height / 2, centre.Z), model)
	end
	return model
end

local function body(name, position, humanoid)
	local model = Instance.new("Model")
	model.Name = name
	block("HumanoidRootPart", V(2, 2, 1), position + V(0, 3, 0), model).CanCollide = false
	block("UpperTorso", V(2, 1.6, 1), position + V(0, 3.4, 0), model)
	block("Head", V(1.2, 1.2, 1.2), position + V(0, 4.6, 0), model)
	if humanoid ~= false then
		local h = Instance.new("Humanoid")
		h.Name = "Humanoid"
		h.Parent = model
	end
	model.Parent = workspace
	return model
end

-- The thrower: a character standing `back` studs behind the target along -facing, `up` above it,
-- looking along `facing`. Its body is left out of every check, as the owner's always is.
local owner = mock.newInstance("Player")
owner.Name = "Thrower"
owner.UserId = 1
local playersFolder = folder("PlayersHolder", nil)
owner.Parent = playersFolder
local function thrower(target, facing, back, up)
	local old = workspace:FindFirstChild("ThrowerCharacter")
	if old then
		old:Destroy()
	end
	local stand = target - facing * (back or 18) + V(0, up or 6, 0)
	local model = Instance.new("Model")
	model.Name = "ThrowerCharacter"
	local root = block("HumanoidRootPart", V(2, 2, 1), CFrame.lookAt(stand, stand + facing), model)
	root.CanCollide = false
	block("Head", V(1.2, 1.2, 1.2), CFrame.lookAt(stand + V(0, 1.5, 0), stand + V(0, 1.5, 0) + facing), model)
	local h = Instance.new("Humanoid")
	h.Name = "Humanoid"
	h.Parent = model
	model.Parent = workspace
	owner.Character = model
	return model
end

--------------------------------------------------------------------------------
-- Measurements (independent of DefensePlacement)
--------------------------------------------------------------------------------
W.PEN_TOL = 0.45 -- the base set 0.15 into the ground, the builders' own posts 0.2 below it, slack
W.GAP_TOL = 1.0 -- more air than this under an edge, with no post near, is floating
W.POST_REACH = 3.6 -- how far along an edge one post carries it (the columns are 3.5 apart)

local function problem(tag, scene, id, text)
	table.insert(W.problems, string.format("[%s] %s %s: %s", tag, scene, id or "-", text))
end

local function structureParts(model)
	local parts, footings = {}, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Name ~= "Core" then
			if d:GetAttribute("Footing") then
				table.insert(footings, d)
			else
				table.insert(parts, d)
			end
		end
	end
	return parts, footings
end

local function groundBelow(point, exclude, ignoreWater, reach)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = exclude
	params.RespectCanCollide = true
	params.IgnoreWater = ignoreWater
	local hit = workspace:Raycast(point, V(0, -(reach or 80), 0), params)
	return hit and hit.Position.Y or nil, hit
end

local function isBody(part)
	local node = part
	while node and node ~= workspace do
		if node:IsA("Model") and (node:FindFirstChildOfClass("Humanoid") or node:GetAttribute("VehicleMaxHealth")) then
			return true
		end
		node = node.Parent
	end
	return false
end

local function corners(part)
	local out = {}
	local h = part.Size / 2
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				table.insert(out, part.CFrame * V(sx * h.X, sy * h.Y, sz * h.Z))
			end
		end
	end
	return out
end

-- Everything that can be said about a built structure from its geometry alone.
function W.measure(scene, id, model, origin, size)
	local parts, footings = structureParts(model)
	local exclude = { model }
	local worst = { pen = 0, float = 0, reach = 0 }
	-- 1. Every post and ladder reaches the ground under it, and doesn't dive absurdly deep.
	for _, f in ipairs(footings) do
		local kind = f:GetAttribute("Footing")
		if kind == "post" or kind == "ladder" then
			local topY = f.Position.Y + f.Size.Y / 2
			local bottomY = f.Position.Y - f.Size.Y / 2
			local g = groundBelow(V(f.Position.X, topY + 0.5, f.Position.Z), exclude, true)
			if not g then
				problem("reach", scene, id, string.format("%s at (%.1f, %.1f) stands on nothing", kind, f.Position.X, f.Position.Z))
			elseif bottomY > g + 0.05 or bottomY < g - 3 then
				worst.reach = math.max(worst.reach, math.abs(bottomY - g))
				problem("reach", scene, id, string.format("%s bottom %.2f vs ground %.2f", kind, bottomY, g))
			end
		end
	end
	-- 2. Under every edge of the base: resting (gap <= GAP_TOL), carried by a post within POST_REACH,
	-- or over nothing within reach (an overhang, counted). Anything else is floating.
	-- The edges are the structure's own: the extent, in its frame, of every part that comes down to
	-- the base (the bunker's sandbags stand out in front of its pad, and they must not hang either).
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, part in ipairs(parts) do
		local low = math.huge
		local cs = corners(part)
		for _, c in ipairs(cs) do
			low = math.min(low, origin:PointToObjectSpace(c).Y)
		end
		if low <= 0.5 then
			for _, c in ipairs(cs) do
				local l = origin:PointToObjectSpace(c)
				x0, x1, z0, z1 = math.min(x0, l.X), math.max(x1, l.X), math.min(z0, l.Z), math.max(z1, l.Z)
			end
		end
	end
	x0, x1, z0, z1 = x0 + 0.1, x1 - 0.1, z0 + 0.1, z1 - 0.1
	local samples, overhang = 0, 0
	local carriedMemo = {}
	local function carried(f)
		if carriedMemo[f] ~= nil then
			return carriedMemo[f]
		end
		carriedMemo[f] = false
		for _, part in ipairs(parts) do
			if W.overlapDepth(f.CFrame, f.Size, part.CFrame, part.Size) > -0.01 then
				carriedMemo[f] = true
				return true
			end
		end
		for _, other in ipairs(footings) do
			if other ~= f and other:GetAttribute("Footing") == "sill" and W.overlapDepth(f.CFrame, f.Size, other.CFrame, other.Size) > -0.01 then
				carriedMemo[f] = true
				return true
			end
		end
		return false
	end
	local function edgePoint(lx, lz)
		samples = samples + 1
		local p = origin * V(lx, 0, lz)
		local g = groundBelow(p + V(0, 0.3, 0), exclude, false, 40.3)
		if not g then
			overhang = overhang + 1
			return
		end
		local gap = p.Y - g
		if gap <= W.GAP_TOL then
			return
		end
		for _, f in ipairs(footings) do
			local kind = f:GetAttribute("Footing")
			if (kind == "post" or kind == "ladder" or kind == "float") then
				local dx, dz = f.Position.X - p.X, f.Position.Z - p.Z
				if math.sqrt(dx * dx + dz * dz) <= W.POST_REACH and carried(f) then
					return
				end
			end
		end
		worst.float = math.max(worst.float, gap)
		problem("float", scene, id, string.format("edge (%.1f, %.1f) hangs %.2f over the ground with no post near", lx, lz, gap))
	end
	local nx, nz = math.max(1, math.ceil(x1 - x0)), math.max(1, math.ceil(z1 - z0))
	for index = 0, nx do
		local x = x0 + (x1 - x0) * index / nx
		edgePoint(x, z0)
		edgePoint(x, z1)
	end
	for index = 0, nz do
		local z = z0 + (z1 - z0) * index / nz
		edgePoint(x0, z)
		edgePoint(x1, z)
	end
	if overhang > samples * 0.5 then
		problem("float", scene, id, string.format("%d of %d edge points over nothing", overhang, samples))
	end
	-- 3. Into the terrain no deeper than PEN_TOL (the footings are the only things allowed down), and
	-- into no part of the world at all beyond it -- a wall through the structure, or it through a wall.
	for _, part in ipairs(parts) do
		for _, c in ipairs(corners(part)) do
			local g = W.height(c.X, c.Z)
			if g and g - c.Y > W.PEN_TOL then
				worst.pen = math.max(worst.pen, g - c.Y)
				problem("pen", scene, id, string.format("%s corner %.2f into the ground", part.Name, g - c.Y))
				break
			end
		end
	end
	for _, other in ipairs(allParts()) do
		-- Loose debris is shoved aside by the rise, as it would be in the game: not a clip.
		if not other:IsDescendantOf(model) and other.CanCollide and other.Anchored and other.Parent then
			local bodyPart = isBody(other)
			for _, part in ipairs(bodyPart and structureParts(model) or parts) do
				local depth = W.overlapDepth(part.CFrame, part.Size, other.CFrame, other.Size)
				if bodyPart and depth > 0.01 and other.Parent.Name ~= "ThrowerCharacter" then
					problem("body", scene, id, string.format("%s is inside %s", part.Name, other.Parent.Name))
					break
				elseif not bodyPart and depth > W.PEN_TOL then
					worst.pen = math.max(worst.pen, depth)
					problem("pen", scene, id, string.format("%s is %.2f into %s", part.Name, depth, other.Name))
					break
				end
			end
		end
	end
	return worst, #footings
end

--------------------------------------------------------------------------------
-- Scenes
--------------------------------------------------------------------------------
local IDS = { "RotBarricade", "PopupBunker", "BrainrotFortress" }
local EAST = V(1, 0, 0)
local NORTH = V(0, 0, -1)

local function slope(angle, dir)
	local t = math.tan(math.rad(angle))
	return function(x, z)
		return t * (x * dir.X + z * dir.Z)
	end
end

-- Each scene builds its world and returns the target (where the kit lands, on the surface) and the
-- facing. `expect` is "build" or a Refusals key (a list means any of them).
local scenes = {}
local function scene(name, expect, build, opts)
	table.insert(scenes, { name = name, expect = expect, build = build, opts = opts or {} })
end

scene("flat", "build", function() return V(0, 0, 0), NORTH end)
for _, angle in ipairs({ 10, 20, 30, 40, 50, 60 }) do
	for _, d in ipairs({ { "across", EAST }, { "along", NORTH }, { "diagonal", V(1, 0, 1).Unit } }) do
		scene(string.format("slope%02d_%s", angle, d[1]), "build", function()
			W.height = slope(angle, d[2])
			return V(0, 0, 0), NORTH
		end)
	end
end
scene("uneven", "build", function()
	W.height = function(x, z) return 0.8 * math.sin(x / 3) * math.cos(z / 4) end
	return V(0, W.height(0, 0), 0), NORTH
end)
scene("flat_roof", "build", function()
	building(V(0, 0, 0), 40, 40, 10)
	return V(0, 11, 0), NORTH
end)
scene("roof_ledge", "build", function()
	building(V(0, 0, 0), 40, 40, 10)
	-- 3 studs in from the east edge: the rest of the structure hangs over the street, on posts.
	return V(17, 11, 0), NORTH
end)
for _, angle in ipairs({ 20, 35 }) do
	scene(string.format("sloped_roof%02d", angle), "build", function()
		local slab = block("RoofSlab", V(60, 2, 60), CFrame.new(0, 20, 0) * CFrame.Angles(0, 0, math.rad(angle)))
		local hit = workspace:Raycast(V(0, 80, 0), V(0, -100, 0), {})
		return hit.Position, NORTH
	end)
end
scene("rubble", "build", function()
	for index, spot in ipairs({ { 2, 1 }, { -3, 0.4 }, { 4.5, -0.3 }, { -1, -4 }, { 6, 5 }, { -6, 4 } }) do
		block("Rubble", V(1.4, 0.9 + index * 0.1, 1.1), CFrame.new(spot[1], 0.45, spot[2]) * CFrame.Angles(0, index, 0))
	end
	local loose = block("Debris", V(1, 1, 1), V(1, 0.5, 2))
	loose.Anchored = false
	return V(0, 0, 0), NORTH
end)
scene("crate", "build", function()
	block("Crate", V(2.4, 2.4, 2.4), V(0.5, 1.2, 0.5))
	return V(0, 0, 0), NORTH
end)
scene("against_wall", "build", function()
	building(V(0, 0, -21.5), 60, 40, 12)
	-- The building's south wall face is at z = -1.5; thrown straight at it.
	return V(0, 0, -1), NORTH
end)
scene("wall_corner", "build", function()
	-- Into the inside corner of two buildings, a stud or so off each wall.
	building(V(-21.5, 0, -21.5), 40, 40, 12)
	building(V(-21.5, 0, 20.5), 40, 40, 12)
	return V(0, 0, 0.5), NORTH
end)
scene("fence_across", "build", function()
	-- A 6-stud fence under the middle of the site: slid off it, never balanced on top of it.
	block("Fence", V(1, 6, 60), V(1.5, 3, 0))
	return V(0, 0, 0), NORTH
end)
scene("shallow_water", "build", function()
	W.height = function(x, z) return -3 end
	W.waters = { { -100, 100, -100, 100, 0 } }
	return V(0, 0, 0), NORTH
end)
scene("lake_edge", "build", function()
	W.height = function(x, z) return x < 0 and -3 or 0.5 end
	W.waters = { { -100, 0, -100, 100, 0 } }
	return V(1, 0.5, 0), NORTH
end)
scene("cliff_ledge", "build", function()
	W.height = function(x, z) return x < 5 and 20 or 0 end
	return V(0, 20, 0), NORTH
end)
scene("doorway", "build", function()
	building(V(10.5, 0, 0), 20, 30, 10, { width = 4, height = 7 })
	-- Thrown straight into the doorway (the wall is x = 0.5..1.5): it must end up clear of it.
	return V(0.5, 0, 0), EAST
end, { doorway = { x = 1, z0 = -2, z1 = 2, height = 7 } })
scene("objective_ring", "build", function()
	local hill = Instance.new("Model")
	hill.Name = "Hill"
	hill.Parent = workspace
	local objective = Instance.new("Model")
	objective.Name = "ObjectiveA"
	objective:SetAttribute("HillX", 40)
	objective:SetAttribute("HillZ", 0)
	objective:SetAttribute("HillRadius", 28)
	objective.Parent = hill
	-- On the ring, well clear of its centre: fighting over an objective is what defenses are for.
	return V(18, 0, 0), NORTH
end)

-- Protected.
scene("player_in_way", "body", function()
	body("Enemy", V(1, 0, 0))
	return V(0, 0, 0), NORTH
end)
scene("bot_in_way", "body", function()
	body("Bot", V(-2, 0, 0.3))
	return V(0, 0, 0), NORTH
end)
scene("vehicle_in_way", "body", function()
	local car = Instance.new("Model")
	car.Name = "Buggy"
	car:SetAttribute("VehicleMaxHealth", 400)
	block("Chassis", V(6, 2, 10), V(0.5, 1.5, 0), car)
	car.Parent = workspace
	return V(0, 0, 0), NORTH
end)
scene("spawn_pad", "spawn", function()
	local pad = Instance.new("SpawnLocation")
	pad.Name = "LobbySpawn"
	pad.Size = V(6, 1, 6)
	pad.CFrame = CFrame.new(3, 0.5, 2)
	pad.Anchored = true
	pad.Parent = mapFolder
	return V(0, 1, 0), NORTH
end)
scene("team_spawn_bunker", "spawn", function()
	local base = Instance.new("Model")
	base.Name = "TeamBaseRed"
	base.Parent = mapFolder
	local bunker = building(V(0, 0, 0), 30, 30, 9, nil, base)
	bunker.Name = "Spawn"
	return V(0, 0, 0), NORTH
end)
scene("objective_centre", "objective", function()
	local hill = Instance.new("Model")
	hill.Name = "Hill"
	hill.Parent = workspace
	local objective = Instance.new("Model")
	objective.Name = "ObjectiveB"
	objective:SetAttribute("HillX", 4)
	objective:SetAttribute("HillZ", -3)
	objective:SetAttribute("HillRadius", 28)
	objective.Parent = hill
	return V(0, 0, 0), NORTH
end)
-- A team base's bay and its way out, as TeamBaseRuins now marks them: an invisible NoBuildLane part
-- tagged NoBuild (tools/defense_anywhere_check.py checks the real base's parts cover every lane).
local function lane(x0, x1, z0, z1)
	local zone = block("NoBuildLane", V(x1 - x0, 20, z1 - z0), V((x0 + x1) / 2, 4, (z0 + z1) / 2))
	zone.Transparency = 1
	zone.CanCollide = false
	zone.CanQuery = false
	zone.CanTouch = false
	zone:SetAttribute("NoBuildReason", DefensePlacement.Refusals.lane)
	W.tagged.NoBuild = W.tagged.NoBuild or {}
	table.insert(W.tagged.NoBuild, zone)
	return zone
end
scene("vehicle_lane", "lane", function()
	lane(19.6, 30.4, -62, -14.37)
	-- In the lane between the bay and the gate.
	return V(25, 0, -36), NORTH
end)
scene("beside_vehicle_lane", "build", function()
	lane(19.6, 30.4, -62, -14.37)
	-- The rest of the yard is buildable: 12 studs clear of the lane's side.
	return V(4, 0, -36), NORTH
end)
scene("covered_passage", { "door", "room" }, function()
	-- A 14-wide tunnel, 60 long: nothing fits across it without shutting it.
	block("TunnelWall", V(60, 10, 1), V(0, 5, -7.5))
	block("TunnelWall", V(60, 10, 1), V(0, 5, 7.5))
	block("TunnelRoof", V(60, 1, 16), V(0, 10.5, 0))
	return V(0, 0, 0), EAST
end)
scene("lobby", "lobby", function()
	local lobby = Instance.new("Model")
	lobby.Name = "Lobby"
	lobby.Parent = workspace
	block("Island", V(200, 4, 200), V(0, 498, 0), lobby)
	return V(0, 500, 0), NORTH
end)
scene("off_the_map", "ground", function()
	W.height = function() return nil end
	return V(0, 0, 0), NORTH
end)
scene("deep_water", "ground", function()
	W.height = function() return -70 end
	W.waters = { { -200, 200, -200, 200, 0 } }
	return V(0, 0, 0), NORTH
end)
scene("tagged_nobuild", "nobuild", function()
	local zone = block("NoBuildZone", V(30, 10, 30), V(0, 5, 0))
	zone.CanCollide = false
	zone.CanQuery = false
	W.tagged.NoBuild = { zone }
	return V(0, 0, 0), NORTH
end)

--------------------------------------------------------------------------------
-- Running them
--------------------------------------------------------------------------------
local function matches(expect, reason)
	local R = DefensePlacement.Refusals
	if type(expect) == "table" then
		for _, key in ipairs(expect) do
			if R[key] == reason then
				return true
			end
		end
		return false
	end
	return R[expect] == reason
end

local function latest(itemId)
	local defenses = workspace:FindFirstChild("Defenses")
	local found = nil
	for _, child in ipairs(defenses and defenses:GetChildren() or {}) do
		if child.Name == itemId then
			found = child
		end
	end
	return found
end

-- The ghost the preview draws against the model the server builds: every built part has a ghost
-- part in the same place and size, and the footings are the same list.
local function comparePreview(sceneName, id, preview, model)
	local ghostParts = {}
	for _, entry in ipairs(preview.ghostParts) do
		table.insert(ghostParts, entry.part)
	end
	for _, part in ipairs(preview.footParts) do
		table.insert(ghostParts, part)
	end
	local parts, footings = structureParts(model)
	local all = {}
	for _, p in ipairs(parts) do table.insert(all, p) end
	for _, p in ipairs(footings) do table.insert(all, p) end
	local worst = 0
	for _, part in ipairs(all) do
		local best = math.huge
		for _, ghost in ipairs(ghostParts) do
			if (ghost.Size - part.Size).Magnitude < 0.02 then
				local d = (ghost.CFrame.Position - part.CFrame.Position).Magnitude
					+ (ghost.CFrame.RightVector - part.CFrame.RightVector).Magnitude
					+ (ghost.CFrame.UpVector - part.CFrame.UpVector).Magnitude
				best = math.min(best, d)
			end
		end
		worst = math.max(worst, best)
		if best > 0.02 then
			problem("preview", sceneName, id, string.format("built %s at (%.2f, %.2f, %.2f) has no ghost (nearest off by %.3f)",
				part.Name, part.Position.X, part.Position.Y, part.Position.Z, best))
			return worst
		end
	end
	if #ghostParts ~= #all then
		problem("preview", sceneName, id, string.format("ghost has %d parts, the build %d", #ghostParts, #all))
	end
	return worst
end

function W.runAll(only)
	local counts = { scenes = 0, built = 0, refused = 0, posts = 0, throws = 0, previewChecked = 0 }
	local preview = DefensePreview.new()
	for _, sc in ipairs(scenes) do
		if not only or string.find(sc.name, only, 1, true) then
			for _, id in ipairs(IDS) do
				counts.scenes = counts.scenes + 1
				-- 1. Deployed straight onto the target (the path a bot takes).
				reset()
				local target, facing = sc.build()
				local centre = target + V(0, DefensePlacement.LandLift, 0)
				-- What a bot asking first is told, before anything stands there.
				local okCheck, checkOrigin, checkReason, plan = pcall(DefenseService.CheckSite, nil, id, centre, facing)
				if not okCheck then
					problem("error", sc.name, id, "CheckSite: " .. tostring(checkOrigin))
					checkOrigin, plan = nil, nil
				end
				local okDeploy, model, reason = pcall(DefenseService.Deploy, owner, nil, id, centre, facing)
				if okDeploy and (model ~= nil) ~= (checkOrigin ~= nil) then
					problem("api", sc.name, id, string.format("CheckSite said %s, Deploy %s", tostring(checkReason or "yes"), tostring(reason or "built")))
				end
				if not okDeploy then
					problem("error", sc.name, id, tostring(model))
					model = nil
				end
				local summary
				if sc.expect == "build" then
					if not model then
						problem("accept", sc.name, id, "refused: " .. tostring(reason))
						summary = "REFUSED " .. tostring(reason)
					else
						counts.built = counts.built + 1
						local origin = model.PrimaryPart.CFrame * CFrame.new(0, -(DefensePlacement.Sizes[id].Y + 0.5), 0)
						local worst, footings = W.measure(sc.name, id, model, origin, DefensePlacement.Sizes[id])
						counts.posts = counts.posts + footings
						if sc.opts.doorway then
							local d = sc.opts.doorway
							local zone = CFrame.new(d.x, d.height / 2, (d.z0 + d.z1) / 2)
							local zoneSize = V(1 + 2 * DefensePlacement.DoorGap, d.height, d.z1 - d.z0)
							for _, part in ipairs((structureParts(model))) do
								-- Solid parts only: the bunker's sandbag row is decor a body walks through.
								if part.CanCollide and W.overlapDepth(part.CFrame, part.Size, zone, zoneSize) > 0.01 then
									problem("door", sc.name, id, part.Name .. " stands in the doorway's way")
									break
								end
							end
						end
						local slid = plan and plan.slid and plan.slid.Magnitude or -1
						summary = string.format("BUILT level %.2f roll %.1f slid %.1f footings %d pen %.2f float %.2f",
							origin.Y, math.deg(plan and plan.roll or 0), slid, footings, worst.pen, worst.float)
					end
				else
					if model then
						problem("refuse", sc.name, id, "built where it must refuse (expected " .. tostring(type(sc.expect) == "table" and table.concat(sc.expect, "/") or sc.expect) .. ")")
						W.measure(sc.name, id, model, model.PrimaryPart.CFrame * CFrame.new(0, -(DefensePlacement.Sizes[id].Y + 0.5), 0), DefensePlacement.Sizes[id])
						summary = "BUILT (wrong)"
					elseif not matches(sc.expect, reason) then
						problem("refuse", sc.name, id, "refused for the wrong reason: " .. tostring(reason))
						summary = "REFUSED " .. tostring(reason) .. " (wrong reason)"
					else
						counts.refused = counts.refused + 1
						summary = "REFUSED " .. tostring(reason)
					end
				end
				table.insert(W.lines, string.format("%-22s %-16s %s", sc.name, id, summary))

				-- 2. Thrown by a player: the preview's ghost, then the server's build from the same throw.
				reset()
				target, facing = sc.build()
				local character = thrower(target, facing, 18, 6)
				local aim = target
				local site = DefensePreview.Site(character, id, aim, { camera })
				preview:Update(character, id, aim, { camera })
				counts.throws = counts.throws + 1
				local flights = #W.fired.DefenseKitFlight
				local okThrow, thrown = pcall(WeaponService.DefenseEffect, owner, id, aim)
				if not okThrow then
					problem("error", sc.name, id, "throw: " .. tostring(thrown))
				else
					-- The kit in flight is the clients' (critic C10): the server sends the arc and puts no
					-- kit in the world; a client flies it and it arrives on the spot the ghost showed.
					local info = W.fired.DefenseKitFlight[flights + 1]
					local serverKit = false
					for _, d in ipairs(workspace:GetDescendants()) do
						if d.Name == id .. "Kit" then
							serverKit = true
						end
					end
					if serverKit or not info then
						problem("flight", sc.name, id, serverKit and "the server put a kit in the world to move" or "no flight sent to clients")
					end
					local flownAt = time()
					local kit = info and DefensePreview.FlyKit(info)
					-- Every frame the client draws, the kit is where the server's own arc says (the
					-- arc the server built from, recomputed here from the throw, not from the message).
					local worstOff = 0
					for _ = 1, 180 do
						mock.advance(1 / 30, 1 / 30)
						RunService.RenderStepped:Fire(1 / 30)
						if kit and kit.Parent then
							local t = time() - flownAt
							local want = DefensePlacement.ArcPoint(site.from, site.velocity, t)
							worstOff = math.max(worstOff, (kit:GetPivot().Position - want).Magnitude)
						end
					end
					if kit and kit.Parent then
						problem("flight", sc.name, id, "the flown kit is still in the air after it landed")
					end
					if info then
						local arrive = DefensePlacement.ArcPoint(site.from, site.velocity, info.landTime)
						local off = (arrive - site.target).Magnitude
						if off > 0.2 or worstOff > 0.05 then
							problem("flight", sc.name, id, string.format("the flown kit arrives %.2f from the ghost's landing, strays %.2f off the arc", off, worstOff))
						end
					end
					local built = latest(id)
					if site.origin and not built then
						problem("preview", sc.name, id, "the ghost said it builds; the throw built nothing (" .. tostring(W.notes[#W.notes]) .. ")")
					elseif built and not site.origin then
						problem("preview", sc.name, id, "the ghost said refused (" .. tostring(site.reason) .. "); the throw built")
					elseif built then
						counts.previewChecked = counts.previewChecked + 1
						comparePreview(sc.name, id, preview, built)
						W.measure(sc.name .. "(thrown)", id, built,
							built.PrimaryPart.CFrame * CFrame.new(0, -(DefensePlacement.Sizes[id].Y + 0.5), 0), DefensePlacement.Sizes[id])
					end
				end
				preview:Hide()
			end
		end
	end

	-- The cap: a fourth structure knocks the oldest down, and says so.
	reset()
	local standing = 0
	for index = 1, 4 do
		DefenseService.Deploy(owner, nil, "RotBarricade", V(index * 30, 1, 0), NORTH)
	end
	for _, child in ipairs(workspace.Defenses:GetChildren()) do
		if child.Name == "RotBarricade" and child.Parent then
			standing = standing + 1
		end
	end
	mock.advance(5, 1 / 10)
	standing = 0
	for _, child in ipairs(workspace.Defenses:GetChildren()) do
		if child.Name == "RotBarricade" then
			standing = standing + 1
		end
	end
	if standing ~= 3 or #W.notes < 1 then
		problem("cap", "cap", "RotBarricade", string.format("%d standing after four, %d notes", standing, #W.notes))
	end
	table.insert(W.lines, string.format("cap: %d of 4 barricades standing, %d notice(s)", standing, #W.notes))

	counts.rays = W.rayCount
	return counts
end

W.scenes = scenes
W.reset = reset
W.DefensePlacement = DefensePlacement
return W
