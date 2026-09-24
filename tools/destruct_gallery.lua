-- Whole-map destruction (#56) and the per-material break (#71) gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/destruct_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- SahurSprings from a fixed seed (the biggest map, ~33k parts). Notes first, then pictures:
--
--   coverage    every BasePart under the Map classified by DestructibleService: breakable by name
--               (a building's walls), by a tagged group (trees, rocks, wrecks, shelters, props),
--               by a tagged Model (TownThemes street props), or not at all; the share of each; how
--               many pools; and the attributes the tagging added (it adds no parts)
--   excluded    every part named, or inside something named, in DestructibleService.Never (roads,
--               bridges, footings...) and every building's ground-floor slab: the number of them
--               that can be damaged must be 0
--   break_*     one of each family before and after breaking it (a tree, a rock, a burnt-out wreck,
--               a parked car, a wilds shelter, a street prop), with the real BreakFxClient drawing
--               the debris (stepped by hand: edit mode runs no physics)
--   crater      a rocket-sized blast on open grass, and the hole it leaves
--   debris_cap  60 breaks in one event: the pieces alive (cap 160, 70 per event)
--
-- What to look at: debris the colour and material of what broke (splinters for wood, chunks and dust
-- for stone, plates and sparks for metal, leaves for trees); nothing left floating where a pool
-- stood; the crater small and not under a road.

local MAP_ID, SEED = "SahurSprings", 101

local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local modules = ServerScriptService:WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function service()
	state.ds = state.ds or require(modules:WaitForChild("DestructibleService"))
	return state.ds
end

-- The real BreakFxClient, with a local stand-in for its remote.
local function loadBreakFx()
	if state.fire then
		return state.fire
	end
	local script = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("BreakFxClient")
	local source = script.Source
	source = source:gsub('Remotes%.Event%("BreakFx"%)', "__breakEvent")
	source = source:gsub('require%(script%.Parent:WaitForChild%("Sfx"%)%)', "{ PlayAt = function() end }")
	local fn, err = loadstring(source, "BreakFxClient")
	assert(fn, err)
	local bindable = Instance.new("BindableEvent")
	local env = setmetatable({ script = script, __breakEvent = { OnClientEvent = bindable.Event } }, { __index = getfenv() })
	setfenv(fn, env)
	task.spawn(fn)
	state.fire = function(batch)
		bindable:Fire(batch)
	end
	return state.fire
end

-- What the server would have sent for a pool, captured before it goes.
local function fxBatch(members, from)
	local batch = {}
	for _, part in ipairs(members) do
		if part.Parent and part.Transparency < 0.95 and #batch < 10 then
			table.insert(batch, { part.CFrame, part.Size, part.Color, part.Material, service().ClassOf(part.Material), from })
		end
	end
	return batch
end

-- Edit mode runs no physics: move the pieces along their velocities by hand, with gravity.
local function stepDebris(seconds)
	local folder = workspace:FindFirstChild("BreakFx")
	if not folder then
		return 0
	end
	local pieces = {}
	for _, piece in ipairs(folder:GetChildren()) do
		if piece.Name == "BreakPiece" then
			table.insert(pieces, { part = piece, v = piece.AssemblyLinearVelocity, w = piece.AssemblyAngularVelocity })
		end
	end
	local dt = 1 / 60
	for _ = 1, math.floor(seconds / dt) do
		for _, entry in ipairs(pieces) do
			entry.v += Vector3.new(0, -workspace.Gravity * dt, 0)
			local turn = entry.w * dt
			entry.part.Anchored = true
			entry.part.CFrame = (entry.part.CFrame + entry.v * dt) * CFrame.Angles(turn.X, turn.Y, turn.Z)
		end
	end
	return #pieces
end

-- The first pool on the map whose tag starts with `kind` (or a tagged Model, for "Prop").
local function findPool(kind)
	local map = workspace:FindFirstChild("Map")
	for _, part in ipairs(map and map:GetDescendants() or {}) do
		if part:IsA("BasePart") and (part.CanCollide or part.CanQuery) and service().FromPart(part) then
			local key = service().KeyOf(part)
			if type(key) == "string" and string.sub(key, 1, #kind + 1) == kind .. ":" then
				local members = {}
				for _, other in ipairs(part.Parent:GetChildren()) do
					if other:IsA("BasePart") and other:GetAttribute("Destructible") == key then
						table.insert(members, other)
					end
				end
				return part, members
			elseif typeof(key) == "Instance" and key:IsA("Model") and kind == "Prop" then
				local members = {}
				for _, other in ipairs(key:GetDescendants()) do
					if other:IsA("BasePart") then
						table.insert(members, other)
					end
				end
				return part, members
			end
		end
	end
	return nil
end

local function boxOf(members)
	local low, high
	for _, part in ipairs(members) do
		local a, b = part.Position - part.Size / 2, part.Position + part.Size / 2
		low = low and low:Min(a) or a
		high = high and high:Max(b) or b
	end
	return (low + high) / 2, high - low
end

local views = {
	{
		name = "map_build",
		settle = 2,
		hold = 1,
		setup = function(_, camera)
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			MapGenerator.Build(MAP_ID)
			camera.CFrame = CFrame.lookAt(Vector3.new(0, 400, 400), Vector3.new(0, 0, 0))
		end,
	},
}

local function add(name, fn, hold)
	table.insert(views, { name = name, settle = 1.4, hold = hold or 2, setup = fn })
end

add("coverage", function(_, camera)
	local ds = service()
	local map = workspace:FindFirstChild("Map")
	local total, byName, byGroup, byModel, none, attributes = 0, 0, 0, 0, 0, 0
	local pools, excludedChecked, excludedBreakable, groundFloors, groundBreakable = {}, 0, 0, 0, 0
	local examples = {}
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") then
			total += 1
			if part:GetAttribute(ds.Tag) ~= nil then
				attributes += 1
			end
			local breakable = ds.FromPart(part) ~= nil
			local key = breakable and ds.KeyOf(part)
			if not key then
				none += 1
			elseif type(key) == "string" then
				byGroup += 1
				pools[key] = true
			elseif key:IsA("Model") then
				byModel += 1
				pools[key] = true
			else
				byName += 1
				pools[key] = true
			end
			-- The structural classes: nothing named in Never, or inside one, may break.
			local node, never = part, false
			while node and node ~= map do
				if ds.Never[node.Name] then
					never = true
				end
				node = node.Parent
			end
			if never then
				excludedChecked += 1
				if breakable then
					excludedBreakable += 1
					if #examples < 5 then
						table.insert(examples, part:GetFullName())
					end
				end
			end
			if part.Name == "Floor" and part:GetAttribute(ds.Tag) == false then
				groundFloors += 1
				if breakable then
					groundBreakable += 1
				end
			end
		end
	end
	local poolCount = 0
	for _ in pairs(pools) do
		poolCount += 1
	end
	local function pct(n)
		return string.format("%d (%.1f%%)", n, 100 * n / math.max(total, 1))
	end
	note(string.format("coverage: %d parts under Map; breakable by name %s, by tagged group %s, by tagged Model %s; not breakable %s; %d pools; %d Destructible attributes",
		total, pct(byName), pct(byGroup), pct(byModel), pct(none), poolCount, attributes))
	note(string.format("excluded: %d parts named or inside Never, %d of them breakable (want 0)%s; ground-floor slabs %d, %d breakable (want 0)",
		excludedChecked, excludedBreakable, #examples > 0 and (" e.g. " .. table.concat(examples, ", ")) or "", groundFloors, groundBreakable))
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 600, 600), Vector3.new(0, 0, 0))
end)

-- One of each family: before, then after (debris mid-flight).
for _, spec in ipairs({
	{ "tree", "Tree" }, { "rock", "Rock" }, { "wreck", "Wreck" }, { "car", "Car" }, { "shelter", "Shelter" }, { "prop", "Prop" },
}) do
	local label, kind = spec[1], spec[2]
	add("break_" .. label .. "_before", function(_, camera)
		local part, members = findPool(kind)
		state[label] = { part = part, members = members }
		if not part then
			note(string.format("break %s: none on this map", label))
			return
		end
		local centre, size = boxOf(members)
		state[label].centre, state[label].size = centre, size
		local reach = math.max(size.X, size.Y, size.Z) * 1.6 + 8
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(reach * 0.7, reach * 0.45, reach * 0.7), centre)
		note(string.format("break %s: %s, %d parts, pool health %d", label, tostring(service().KeyOf(part)), #members,
			service().PoolHealth(kind, members)))
	end)
	add("break_" .. label .. "_after", function(_, camera)
		local entry = state[label]
		if not entry or not entry.part then
			return
		end
		local from = entry.centre + Vector3.new(0, 2, -20)
		local batch = fxBatch(entry.members, from)
		local dealt = service().Damage(entry.part, 1e6, nil, from)
		local left = 0
		for _, member in ipairs(entry.members) do
			if member.Parent then
				left += 1
			end
		end
		loadBreakFx()(batch)
		local pieces = stepDebris(0.35)
		local reach = math.max(entry.size.X, entry.size.Y, entry.size.Z) * 1.6 + 8
		camera.CFrame = CFrame.lookAt(entry.centre + Vector3.new(reach * 0.7, reach * 0.45, reach * 0.7), entry.centre)
		note(string.format("break %s: dealt %d; members left %d (want 0); %d debris pieces", label, dealt, left, pieces))
	end)
end

add("crater", function(_, camera)
	local ds = service()
	local MapGenerator = require(modules:WaitForChild("MapGenerator"))
	-- Open grass: walk out from the centre until the ground is terrain with nothing built on it.
	for step = 1, 400 do
		local x, z = step * 7 % 900 - 450, step * 13 % 900 - 450
		local y = MapGenerator.GroundHeightAt(x, z)
		if y then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { workspace.Map, workspace.Terrain }
			local hit = workspace:Raycast(Vector3.new(x, y + 50, z), Vector3.new(0, -100, 0), params)
			if hit and hit.Instance == workspace.Terrain and hit.Material == Enum.Material.Grass then
				ds.DamageInRadius(hit.Position + Vector3.new(0, 0.5, 0), 12, 150, nil)
				local after = workspace:Raycast(Vector3.new(x, y + 50, z), Vector3.new(0, -100, 0), params)
				note(string.format("crater at (%d, %d): ground %.2f -> %.2f", x, z, hit.Position.Y, after and after.Position.Y or -1))
				camera.CFrame = CFrame.lookAt(hit.Position + Vector3.new(10, 9, 10), hit.Position)
				return
			end
		end
	end
	note("crater: no open grass found")
end)

add("debris_cap", function(_, camera)
	local fire = loadBreakFx()
	local batch = {}
	local at = camera.CFrame.Position + camera.CFrame.LookVector * 40
	for index = 1, 60 do
		table.insert(batch, { CFrame.new(at + Vector3.new(index % 10 * 4, 0, math.floor(index / 10) * 4)), Vector3.new(6, 6, 6),
			Color3.fromRGB(150, 140, 130), Enum.Material.Brick, "stone", at - Vector3.new(0, 0, 20) })
	end
	fire(batch)
	local folder = workspace:FindFirstChild("BreakFx")
	local pieces = 0
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		if child.Name == "BreakPiece" then
			pieces += 1
		end
	end
	note(string.format("debris cap: 60 breaks in one event -> %d pieces alive (cap 160 total, 70 per event)", pieces))
	stepDebris(0.2)
end)

return views
