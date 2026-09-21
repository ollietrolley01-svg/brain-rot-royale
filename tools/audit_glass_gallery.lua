-- Window glass gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/audit_glass_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- SahurSprings from a fixed seed: glazed windows on a tower, a house and a warehouse from outside
-- and from inside, a pane shattering (the real GlassFxClient, loaded here with a local stand-in for
-- its remote, its shards stepped by hand because edit mode runs no physics), a wall part broken with
-- the panes and trim attached to it, and the client's shard cap with 25 panes broken at once.

local MAP_ID, SEED = "SahurSprings", 101

local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local modules = ServerScriptService:WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}
local FLOOR_HEIGHT = 15

local function frameOf(model)
	local ground, area = nil, -1
	local levels = {}
	local fh = model.Name == "warehouse" and FLOOR_HEIGHT * 1.6 or FLOOR_HEIGHT
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p.Name == "Floor" then
			levels[math.floor(p.Position.Y / fh + 0.5)] = true
			if math.abs(p.Position.Y) < 0.3 and p.Size.X * p.Size.Z > area then
				ground, area = p, p.Size.X * p.Size.Z
			end
		end
	end
	if not ground then
		return nil
	end
	local floors = 0
	for _ in pairs(levels) do
		floors += 1
	end
	local width = math.floor(ground.Size.X + 1.4 + 0.5)
	local depth = math.floor(ground.Size.Z + 1.4 + 0.5)
	return {
		model = model, frame = CFrame.new(ground.Position.X, 0, ground.Position.Z) * ground.CFrame.Rotation,
		width = width, depth = depth, halfW = width / 2, halfD = depth / 2, floors = floors, fh = fh, topY = floors * fh,
	}
end

local function buildings(archetype, minFloors)
	local list = {}
	for _, town in ipairs(workspace.Map:GetChildren()) do
		if town.Name == "Town" then
			for _, child in ipairs(town:GetChildren()) do
				if child:IsA("Model") and child.Name == archetype then
					local b = frameOf(child)
					if b and b.floors >= (minFloors or 1) then
						table.insert(list, b)
					end
				end
			end
		end
	end
	return list
end

-- A pane of `b` on its back wall (local +Z) on `floor`, or nil.
local function backPane(b, floor)
	for _, part in ipairs(b.model:GetChildren()) do
		if part.Name == "WindowGlass" then
			local l = b.frame:PointToObjectSpace(part.Position)
			if math.abs(l.Z - b.halfD) < 0.2 and math.floor(l.Y / b.fh) == floor then
				return part, l
			end
		end
	end
end

local function shot(camera, b, eye, target, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(b.frame * eye, b.frame * target)
end

-- The real client effect, with its remote swapped for a local event and its sound for a no-op.
local function loadGlassFx()
	if state.fire then
		return state.fire
	end
	local script = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("GlassFxClient")
	local source = script.Source
	source = source:gsub('Remotes%.Event%("GlassShatter"%)', "__glassEvent")
	source = source:gsub('require%(script%.Parent:WaitForChild%("Sfx"%)%)', "{ PlayAt = function() end }")
	local fn, err = loadstring(source, "GlassFxClient")
	assert(fn, err)
	local bindable = Instance.new("BindableEvent")
	local env = setmetatable({ script = script, __glassEvent = { OnClientEvent = bindable.Event } }, { __index = getfenv() })
	setfenv(fn, env)
	task.spawn(fn)
	state.fire = function(batch)
		bindable:Fire(batch)
	end
	return state.fire
end

-- Edit mode runs no physics: move the shards along their velocities by hand, with gravity.
local function stepShards(seconds)
	local folder = workspace:FindFirstChild("GlassFx")
	if not folder then
		return 0
	end
	local shards = {}
	for _, shard in ipairs(folder:GetChildren()) do
		if shard.Name == "GlassShard" and not shard.Anchored then
			table.insert(shards, { part = shard, v = shard.AssemblyLinearVelocity, w = shard.AssemblyAngularVelocity })
		end
	end
	local dt = 1 / 60
	for _ = 1, math.floor(seconds / dt) do
		for _, entry in ipairs(shards) do
			entry.v += Vector3.new(0, -workspace.Gravity * dt, 0)
			local turn = entry.w * dt
			entry.part.Anchored = true
			entry.part.CFrame = (entry.part.CFrame + entry.v * dt) * CFrame.Angles(turn.X, turn.Y, turn.Z)
		end
	end
	return #shards
end

local views = {
	{
		name = "map_build",
		settle = 2,
		hold = 1,
		setup = function(_, camera)
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			state.info = MapGenerator.Build(MAP_ID)
			task.wait(1.5)
			local panes = 0
			for _, d in ipairs(workspace.Map:GetDescendants()) do
				if d.Name == "WindowGlass" then
					panes += 1
				end
			end
			note(string.format("%s seed %d: %d panes", MAP_ID, SEED, panes))
			camera.CFrame = CFrame.lookAt(Vector3.new(0, 300, -260), Vector3.new(0, 0, 0))
		end,
	},
}

local function add(name, fn, hold)
	table.insert(views, { name = name, settle = 1.4, hold = hold or 2, setup = fn })
end

add("tower_outside", function(_, camera)
	local b = buildings("tower", 3)[1]
	note(string.format("tower %dx%d, %d floors", b.width, b.depth, b.floors))
	shot(camera, b, Vector3.new(b.halfW * 0.6, b.topY * 0.42, b.halfD + b.topY * 0.95), Vector3.new(0, b.topY * 0.42, b.halfD), 55)
end)
add("tower_window_close", function(_, camera)
	local b = buildings("tower", 3)[1]
	local _, l = backPane(b, 1)
	shot(camera, b, l + Vector3.new(3.5, 1.2, 7), l, 50)
end)
add("tower_inside_looking_out", function(_, camera)
	local b = buildings("tower", 3)[1]
	local _, l = backPane(b, 1)
	shot(camera, b, Vector3.new(l.X - 2.5, l.Y - 0.8, b.halfD - 6.5), l + Vector3.new(0, 0, 3), 70)
end)
add("house_outside", function(_, camera)
	local b = buildings("house", 1)[1]
	local _, l = backPane(b, 0)
	shot(camera, b, l + Vector3.new(-6, 2.5, 12), l, 55)
end)
add("house_inside_looking_out", function(_, camera)
	local b = buildings("house", 1)[1]
	local _, l = backPane(b, 0)
	shot(camera, b, Vector3.new(l.X + 3, l.Y + 0.4, b.halfD - 5.5), l + Vector3.new(0, 0, 3), 70)
end)
add("warehouse_outside", function(_, camera)
	local b = buildings("warehouse", 1)[1]
	shot(camera, b, Vector3.new(b.halfW * 0.4, 9, b.halfD + 26), Vector3.new(0, 7, b.halfD), 60)
end)

-- A pane shattering: before, mid-burst, and a moment later.
add("shatter_1_before", function(_, camera)
	local b = buildings("house", 1)[2] or buildings("house", 1)[1]
	local pane, l = backPane(b, 0)
	state.shatterPane, state.shatterB, state.shatterLocal = pane, b, l
	loadGlassFx()
	shot(camera, b, l + Vector3.new(-4.5, 1.2, 9), l + Vector3.new(0, -0.8, -1), 55)
end)
add("shatter_2_burst", function(_, camera)
	local DestructibleService = require(modules:WaitForChild("DestructibleService"))
	local pane, b, l = state.shatterPane, state.shatterB, state.shatterLocal
	local from = b.frame * (l + Vector3.new(0, 0.2, 14))
	local entry = { pane.CFrame, pane.Size, pane.Color, from }
	DestructibleService.Damage(pane, 18, nil, from)
	note("pane still there after a shot: " .. tostring(pane.Parent ~= nil))
	state.fire({ entry })
	local moved = stepShards(0.12)
	note("shards in the burst: " .. moved)
	shot(camera, b, l + Vector3.new(-4.5, 1.2, 9), l + Vector3.new(0, -0.8, -1), 55)
end)
add("shatter_3_later", function(_, camera)
	local b, l = state.shatterB, state.shatterLocal
	stepShards(0.18)
	shot(camera, b, l + Vector3.new(-4.5, 1.2, 9), l + Vector3.new(0, -0.8, -1), 55)
end)

-- A wall part broken: the panes and trim on it go too.
add("wall_break_1_before", function(_, camera)
	local b = buildings("house", 1)[3] or buildings("house", 1)[1]
	local pane, l = backPane(b, 0)
	local wall = nil
	for _, other in ipairs(b.model:GetChildren()) do
		if other.Name == "Wall" and other:IsA("BasePart") then
			local ol = b.frame:PointToObjectSpace(other.Position)
			-- The pier beside the pane: same wall, same band, next to it along the wall.
			if math.abs(ol.Z - b.halfD) < 0.2 and math.abs(ol.Y - l.Y) < 1 and math.abs(math.abs(ol.X - l.X) - (2.5 + other.Size.X / 2)) < 0.2 then
				wall = other
				break
			end
		end
	end
	state.wallB, state.wall, state.wallLocal = b, wall, l
	note("wall break: pier found " .. tostring(wall ~= nil))
	shot(camera, b, l + Vector3.new(3, 2, 13), l + Vector3.new(2, -0.5, 0), 55)
end)
add("wall_break_2_after", function(_, camera)
	local DestructibleService = require(modules:WaitForChild("DestructibleService"))
	local b, wall, l = state.wallB, state.wall, state.wallLocal
	if wall then
		local before = #b.model:GetChildren()
		DestructibleService.Damage(wall, 10000, nil, b.frame * (l + Vector3.new(2, 0, 14)))
		task.wait()
		local rubble = 0
		for _, child in ipairs(b.model:GetChildren()) do
			if child.Name == "Rubble" then
				rubble += 1
				child.Anchored = true
			end
		end
		note(string.format("wall break: building children %d -> %d (%d of them rubble)", before, #b.model:GetChildren(), rubble))
	end
	shot(camera, b, l + Vector3.new(3, 2, 13), l + Vector3.new(2, -0.5, 0), 55)
end)

-- The cap: 25 panes at once.
add("shard_cap", function(_, camera)
	local fire = loadGlassFx()
	local b = buildings("tower", 3)[2] or buildings("tower", 3)[1]
	local batch = {}
	for _, part in ipairs(b.model:GetChildren()) do
		if part.Name == "WindowGlass" and #batch < 25 then
			table.insert(batch, { part.CFrame, part.Size, part.Color, part.Position + part.CFrame.LookVector * 10 })
		end
	end
	shot(camera, b, Vector3.new(0, b.topY * 0.4, b.halfD + 45), Vector3.new(0, b.topY * 0.4, 0), 60)
	fire(batch)
	local folder = workspace:FindFirstChild("GlassFx")
	local shards = 0
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		if child.Name == "GlassShard" then
			shards += 1
		end
	end
	note(string.format("shard cap: %d panes in one event -> %d shards alive (cap 150)", #batch, shards))
	stepShards(0.15)
end)

return views
