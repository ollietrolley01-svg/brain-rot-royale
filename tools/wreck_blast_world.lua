-- The stand-in world for tools/wreck_blast_check.py: just enough of a Roblox client to run the REAL
-- VehicleWreckFx, the REAL OnWreck hook cut from ProjectileClient, and the REAL track / watchFolder /
-- lampsOf / updateLamps and vehicle Stepped loop cut from VehicleClient, under plain Lua (lupa).
--
-- What it keeps from Roblox, because the wreck blast depends on it:
--   * GetAttributeChangedSignal fires only when the value CHANGES (a second SetAttribute("Wrecked",
--     true) fires nothing, as in Roblox), and synchronously, in the frame of the write.
--   * AncestryChanged fires on an instance and its descendants when anything above it is re-parented;
--     ChildAdded fires on the new parent. A vehicle streaming out is Parent = nil, and in, Parent = folder.
--   * RunService.Stepped fires once a frame at 60 Hz, with the clock (tick()) at the frame's time.
-- Everything else (rendering, physics, sound) is a recorder.
--
--   local W = world.new(wreckChunk, vehicleClientChunk, projectileClientChunk)
--   local car = W.vehicle(400, false)   a vehicle 400 studs down +X, whole (true: already a wreck)
--   W.at(10, function() W.wreck(car) end)  W.camera(0)  W.run(30)
--   W.blasts   { t, id, drawn, heard, distance } per OnWreck
--   W.smoke    id -> the time its smoke first came on

local world = {}

local FRAME = 1 / 60

function world.new(wreckChunk, vehicleClientChunk, projectileClientChunk)
	local W = { clock = 0, blasts = {}, smoke = {}, actions = {}, deferred = {}, nextId = 0 }

	-- Values ------------------------------------------------------------------------------------
	local V = {}
	V.__index = function(v, key)
		if key == "Magnitude" then
			return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		end
		return V[key]
	end
	local function vec(x, y, z)
		return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __type = "Vector3" }, V)
	end
	V.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
	V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
	V.__mul = function(a, b)
		if type(a) == "number" then a, b = b, a end
		return vec(a.X * b, a.Y * b, a.Z * b)
	end
	Vector3 = { new = vec }
	CFrame = { new = function(p) return { Position = p or vec(), __type = "CFrame" } end }
	local function stub(kind) return { new = function(...) return { __type = kind, ... } end } end
	ColorSequence, NumberSequence, NumberSequenceKeypoint = stub("ColorSequence"), stub("NumberSequence"), stub("NumberSequenceKeypoint")
	NumberRange, Vector2 = stub("NumberRange"), stub("Vector2")
	Color3 = { new = function(r, g, b) return { R = r, G = g, B = b, __type = "Color3" } end }
	Color3.fromRGB = function(r, g, b) return Color3.new(r / 255, g / 255, b / 255) end
	typeof = function(v)
		if type(v) == "table" and v.__type then return v.__type end
		if type(v) == "table" and rawget(v, "__instance") then return "Instance" end
		return type(v)
	end
	tick = function() return W.clock end
	task = {
		defer = function(fn, ...) table.insert(W.deferred, { fn = fn, args = { ... } }) end,
		spawn = function(fn, ...) fn(...) end,
		delay = function(t, fn, ...) table.insert(W.actions, { at = W.clock + (t or 0), fn = fn, args = { ... } }) end,
	}

	-- Signals -----------------------------------------------------------------------------------
	local function signal()
		local s = { handlers = {} }
		function s:Connect(fn)
			local entry = { fn = fn }
			table.insert(self.handlers, entry)
			return { Disconnect = function()
				for i, h in ipairs(s.handlers) do
					if h == entry then table.remove(s.handlers, i) break end
				end
			end }
		end
		function s:Fire(...)
			for _, h in ipairs({ table.unpack(self.handlers) }) do h.fn(...) end
		end
		return s
	end
	W.signal = signal

	-- Instances ---------------------------------------------------------------------------------
	local BASE_PARTS = { Part = true, VehicleSeat = true, Seat = true }
	local I = {}
	local function new(className, name)
		local inst = { __instance = true, __class = className, __children = {}, __attributes = {},
			__attrSignals = {}, __props = { Name = name or className, Size = vec(6, 3, 10) },
			AncestryChanged = signal(), DescendantAdded = signal(), ChildAdded = signal() }
		return setmetatable(inst, I)
	end
	I.__index = function(inst, key)
		if key == "Parent" then return rawget(inst, "__parent") end
		if key == "ClassName" then return rawget(inst, "__class") end
		if key == "Position" then
			local cf = rawget(inst, "__props").CFrame
			return cf and cf.Position or vec()
		end
		if I[key] then return I[key] end
		return rawget(inst, "__props")[key]
	end
	local function fireAncestry(inst)
		inst.AncestryChanged:Fire(inst, inst.Parent)
		for _, child in ipairs(rawget(inst, "__children")) do fireAncestry(child) end
	end
	I.__newindex = function(inst, key, value)
		if key == "Parent" then
			local old = rawget(inst, "__parent")
			if old == value then return end
			if old then
				local list = rawget(old, "__children")
				for i, c in ipairs(list) do if c == inst then table.remove(list, i) break end end
			end
			rawset(inst, "__parent", value)
			if value then
				table.insert(rawget(value, "__children"), inst)
				value.ChildAdded:Fire(inst)
				local node = value
				while node do node.DescendantAdded:Fire(inst) node = node.Parent end
			end
			fireAncestry(inst)
			return
		end
		rawget(inst, "__props")[key] = value
	end
	function I.IsA(inst, class)
		if class == "BasePart" then return BASE_PARTS[inst.ClassName] == true end
		return inst.ClassName == class
	end
	function I.GetChildren(inst) return { table.unpack(rawget(inst, "__children")) } end
	function I.GetDescendants(inst)
		local out = {}
		for _, c in ipairs(rawget(inst, "__children")) do
			table.insert(out, c)
			for _, d in ipairs(c:GetDescendants()) do table.insert(out, d) end
		end
		return out
	end
	function I.FindFirstChild(inst, name)
		for _, c in ipairs(rawget(inst, "__children")) do if c.Name == name then return c end end
		return nil
	end
	function I.IsDescendantOf(inst, other)
		local node = inst.Parent
		while node do if node == other then return true end node = node.Parent end
		return false
	end
	function I.GetAttribute(inst, name) return rawget(inst, "__attributes")[name] end
	function I.GetAttributeChangedSignal(inst, name)
		local signals = rawget(inst, "__attrSignals")
		signals[name] = signals[name] or signal()
		return signals[name]
	end
	function I.SetAttribute(inst, name, value)
		local attributes = rawget(inst, "__attributes")
		if attributes[name] == value then return end -- Roblox fires nothing for an unchanged value
		attributes[name] = value
		local s = rawget(inst, "__attrSignals")[name]
		if s then s:Fire() end
	end
	function I.Destroy(inst) inst.Parent = nil end
	Instance = { new = function(className) return new(className) end }

	local game_ = new("DataModel", "game")
	workspace = new("Workspace", "Workspace")
	workspace.Parent = game_
	game = game_
	local map = new("Model", "Map")
	map.Parent = workspace
	local folder = new("Folder", "Vehicles")
	folder.Parent = map

	-- The camera, and the recorders ExplosiveFx and Sfx stand in for ----------------------------
	local camera = new("Camera", "Camera")
	camera.CFrame = CFrame.new(vec(0, 0, 0))
	function W.camera(x) camera.CFrame = CFrame.new(vec(x, 0, 0)) end

	local ExplosiveFx = { Explosion = function(position) W.lastDrawn = true end }
	local Sfx = { Blast = function(name, position) W.lastHeard = name end }
	local Stepped = signal()
	local RunService = { Stepped = Stepped }
	local VehicleDynamics = {
		Rig = function(model)
			local body = model:FindFirstChild("Chassis")
			return body and { chassis = body, handling = { steerLow = 1 } }
		end,
		AnimateWheels = function() end,
	}

	-- The real modules --------------------------------------------------------------------------
	local VehicleWreckFx = wreckChunk()
	W.VehicleWreckFx = VehicleWreckFx
	local watchFolder = vehicleClientChunk(VehicleWreckFx, VehicleDynamics, RunService, camera, function() end, function() end)
	projectileClientChunk(VehicleWreckFx, ExplosiveFx, Sfx, camera)
	-- Every call ProjectileClient's hook makes is recorded against the wreck that caused it.
	local hook = VehicleWreckFx.OnWreck
	VehicleWreckFx.OnWreck = function(model)
		W.lastDrawn, W.lastHeard = false, nil
		if hook then hook(model) end
		local chassis = model:FindFirstChild("Chassis")
		table.insert(W.blasts, { t = W.clock, id = model:GetAttribute("TestId"), drawn = W.lastDrawn, heard = W.lastHeard,
			distance = chassis and (chassis.Position - camera.CFrame.Position).Magnitude or -1 })
	end
	W.hooked = hook ~= nil
	watchFolder(folder)

	-- Vehicles ----------------------------------------------------------------------------------
	W.models = {}
	-- A vehicle `x` studs down +X; `wrecked` true = it arrives already a wreck (streamed in, joined late).
	function W.vehicle(x, wrecked, id)
		W.nextId = W.nextId + 1
		local model = new("Model", "Car")
		model:SetAttribute("VehicleModel", "Test")
		model:SetAttribute("TestId", id or W.nextId)
		if wrecked then model:SetAttribute("Wrecked", true) end
		local chassis = new("Part", "Chassis")
		chassis.CFrame = CFrame.new(vec(x, 0, 0))
		chassis.Parent = model
		model.Parent = folder
		W.models[model:GetAttribute("TestId")] = model
		return model
	end
	-- The server's write reaching this client.
	function W.wreck(model) model:SetAttribute("Wrecked", true) end
	-- Atomic streaming (VehicleModels sets ModelStreamingMode Atomic): out, the client's copy is gone;
	-- in, a NEW copy arrives carrying the server's attributes as they are now (`wrecked`).
	function W.streamOut(model) model:Destroy() end
	function W.streamIn(old, wrecked)
		return W.vehicle(old:FindFirstChild("Chassis").Position.X, wrecked, old:GetAttribute("TestId"))
	end
	-- The same instance taken out of the world and put back (not what atomic streaming does, but
	-- nothing should double up if it ever happens).
	function W.detach(model) model.Parent = nil end
	function W.attach(model) model.Parent = folder end
	function W.at(t, fn) table.insert(W.actions, { at = t, fn = fn, args = {} }) end

	-- Frames at 60 Hz: due actions, then Stepped (VehicleClient's loop), then deferred work; then the
	-- smoke is read off each model (an enabled WreckSmoke emitter under its Chassis).
	function W.run(untilT)
		while W.clock < untilT - 1e-9 do
			W.clock = W.clock + FRAME
			table.sort(W.actions, function(a, b) return a.at < b.at end)
			while W.actions[1] and W.actions[1].at <= W.clock + 1e-9 do
				local a = table.remove(W.actions, 1)
				a.fn(table.unpack(a.args))
			end
			Stepped:Fire(W.clock, FRAME)
			local deferred = W.deferred
			W.deferred = {}
			for _, d in ipairs(deferred) do d.fn(table.unpack(d.args)) end
			for id, model in pairs(W.models) do
				local chassis = model:FindFirstChild("Chassis")
				local attachment = chassis and chassis:FindFirstChild("WreckSmoke")
				local emitter = attachment and attachment:FindFirstChild("ParticleEmitter")
				if emitter and emitter.Enabled and not W.smoke[id] then
					W.smoke[id] = W.clock
				end
			end
		end
	end
	W.FRAME = FRAME
	return W
end

return world
