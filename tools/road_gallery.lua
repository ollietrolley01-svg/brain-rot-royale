-- Road gallery: builds a whole map in the gallery copy of the place, measures its roads and
-- photographs them -- the network from above, a crossroads with its lights (twice, some seconds
-- apart, with the real TrafficClient running, to show them change), a T-junction and its stop sign,
-- a bend, a road leaving a town, a bridge, the town junctions, and the steepest stretch side-on.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/road_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Measurements (printed as notes):
--   ground   road top minus the terrain under the carriageway and the shoulders, sampled every 4
--            studs along every road. The road top is RoadNetwork.Lift above the ground it was
--            shaped for, so a flat road on flat ground reads that everywhere.
--   gaps     points along every road's centre line and both lanes, a stud apart from junction
--            centre to junction centre (and on into the town street at a mouth), that no surface
--            part covers. Must be 0.
--   steps    neighbouring points whose surface tops differ by more than the grade allows: a
--            step or an overlap where two pieces meet. Must be 0.
--   zfight   what the build's own pass had to nudge on the roads and towns, and what is still flush.
--
-- RUNS picks the maps and seeds; a fixed seed means a layout can be looked at again.

-- Each run builds one map from a fixed seed and photographs it. Edit to taste.
local RUNS = {
	{ map = "SahurSprings", seed = 7 },
	{ map = "BombardiroBay", seed = 7 },
	{ map = "RotRidge", seed = 101 },
	{ map = "TralalaTown", seed = 101 },
	{ map = "PatapimPlains", seed = 101 },
}

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function topDown(camera, position, height, fov)
	camera.FieldOfView = fov or 70
	camera.CFrame = CFrame.lookAt(position + Vector3.new(0, height, 0), position, Vector3.new(0, 0, -1))
end

local function look(camera, from, at, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, at)
end

local function measure(info)
	local map = workspace.Map
	local roads = info.roads
	local audit = roads:Audit(map)
	note("roads: " .. audit.summary)

	local ZFight = require(ReplicatedStorage.Shared.ZFight)
	local function groupOf(part)
		local node = part
		while node.Parent and node.Parent ~= map do
			node = node.Parent
		end
		return node.Name
	end
	local touched, lines, patterns = ZFight.Report({ map }, groupOf, 30)
	local remaining = ZFight.Scan({ map })
	local remainingLines = ZFight.Describe(remaining, groupOf, 20)
	note(string.format("zfight: nudged at build %d parts in %d patterns; still flush %d%s", touched, patterns, #remaining,
		#remaining > 0 and (" [" .. table.concat(remainingLines, " | ") .. "]") or ""))
	local roadLines = {}
	for _, line in ipairs(lines) do
		if line:find("^Roads") or line:find("^Town") then
			table.insert(roadLines, line)
		end
	end
	if #roadLines > 0 then
		note("zfight road/town patterns: " .. table.concat(roadLines, " | "))
	end

	-- Points of interest: the steepest stretch from the profiles, and one of each kind of node.
	local RoadNetwork = require(ServerScriptService.Modules.RoadNetwork)
	local steepest = 0
	for _, edge in ipairs(roads.edges) do
		for along = 4, edge.length - 4, 4 do
			local grade = math.abs(RoadNetwork.EdgeHeight(edge, along + 4) - RoadNetwork.EdgeHeight(edge, along - 4)) / 8
			if grade > steepest then
				steepest, state.steepest = grade, { edge = edge, along = along }
			end
		end
	end
	for _, node in ipairs(roads.nodes) do
		state[node.kind] = state[node.kind] or node
		if node.curve and (not state.curve or node.curve.radius > state.curve.curve.radius) then
			state.curve = node
		end
	end
	local curves = roads:Curves()
	if #curves > 0 then
		local tightest, widest = math.huge, 0
		for _, curve in ipairs(curves) do
			tightest = math.min(tightest, curve.curve.radius)
			widest = math.max(widest, curve.curve.radius)
		end
		-- Bends, not nodes: this line used to divide by every node on the map -- junctions, tees and
		-- street mouths included -- and so reported "26 of 79 bends" on a map whose every bend was
		-- curved. A bend is a node with two arms that turn, which is RoadNetwork's own "bend" kind.
		local bends = 0
		for _, node in ipairs(roads.nodes) do
			if node.kind == "bend" then
				bends += 1
			end
		end
		note(string.format("curves: %d of %d bends (nodes on this map: %d), radius %.0f..%.0f",
			#curves, bends, #roads.nodes, tightest, widest))
	else
		note("curves: none on this map")
	end
	-- The deepest cutting or highest embankment: where the ground 40 studs out from the road differs
	-- most from the road's own, off the bridges; and the middle of the longest edge, for the verges.
	local terrainOnly = RaycastParams.new()
	terrainOnly.FilterType = Enum.RaycastFilterType.Include
	terrainOnly.FilterDescendantsInstances = { workspace.Terrain }
	local biggest, longest = 0, 0
	for _, edge in ipairs(roads.edges) do
		local right = Vector3.new(-edge.dir.Z, 0, edge.dir.X)
		for along = 40, edge.length - 40, 16 do
			local onBridge = false
			for _, span in ipairs(edge.bridges or {}) do
				onBridge = onBridge or (along > span.s0 - 60 and along < span.s1 + 60)
			end
			if not onBridge then
				local ground = RoadNetwork.EdgeHeight(edge, along)
				for _, side in ipairs({ -1, 1 }) do
					local p = edge.from + edge.dir * along + right * side * 40
					local hit = workspace:Raycast(Vector3.new(p.X, ground + 150, p.Z), Vector3.new(0, -300, 0), terrainOnly)
					if hit and math.abs(hit.Position.Y - ground) > biggest then
						biggest, state.cutting = math.abs(hit.Position.Y - ground), { edge = edge, along = along, side = side, rise = hit.Position.Y - ground }
					end
				end
			end
		end
		if edge.length > longest then
			longest, state.longest = edge.length, { edge = edge, along = edge.length / 2 }
		end
	end
	if state.cutting then
		note(string.format("deepest cutting or embankment: %.1f studs, %.0f along a %s-to-%s road", state.cutting.rise, state.cutting.along, state.cutting.edge.a.kind, state.cutting.edge.b.kind))
	end
	for _, edge in ipairs(roads.edges) do
		if edge.bridges and #edge.bridges > 0 and not state.bridge then
			local span = edge.bridges[1]
			state.bridge = { edge = edge, along = (span.s0 + span.s1) / 2 }
		end
	end
	state.towns = {}
	for _, child in ipairs(map:GetChildren()) do
		if child.Name == "Town" then
			table.insert(state.towns, child)
		end
	end
	-- Town junctions, found by what stands at them, and a street's closed end (the kerb across it is
	-- the only kerb that runs across a street).
	for _, town in ipairs(state.towns) do
		for _, d in ipairs(town:GetChildren()) do
			if d.Name == "SignalPole" and not state.townSignals then
				state.townSignals = d.Position
			elseif d.Name == "StopSignPost" and not state.townStop then
				state.townStop = d.Position
			elseif d.Name == "Kerb" and d.Size.X > 20 and not state.streetEnd then
				state.streetEnd = d
			elseif d.Name == "PavementTaper" and not state.taper then
				state.taper = d
			end
		end
	end
end

local function nodeGround(node)
	return Vector3.new(node.position.X, node.height or 0, node.position.Z)
end

local function viewsFor(MAP_ID, SEED)
	local views = {
	{
		name = "overview",
		settle = 3,
		setup = function(_, camera)
			for key in pairs(state) do
				state[key] = nil
			end
			math.randomseed(SEED)
			local modules = ServerScriptService:WaitForChild("Modules")
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			local started = os.clock()
			local ok, info = pcall(MapGenerator.Build, MAP_ID)
			if not ok then
				note("BUILD FAILED: " .. tostring(info))
				error(info)
			end
			state.info = info
			note(string.format("built %s in %.1fs, radius %d", MAP_ID, os.clock() - started, info.radius))
			local okMeasure, err = pcall(measure, info)
			if not okMeasure then
				note("MEASURE FAILED: " .. tostring(err))
			end
			-- The lights, run by the real client script.
			local source = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("TrafficClient")
			if source then
				local fn, compileError = loadstring(source.Source, "TrafficClient")
				if fn then
					task.spawn(fn)
					note("TrafficClient running")
				else
					note("TrafficClient failed to compile: " .. tostring(compileError))
				end
			end
			topDown(camera, Vector3.zero, info.radius * 1.45, 70)
		end,
	},
	{
		name = "cross_top",
		setup = function(_, camera)
			local node = state.cross
			if node then
				topDown(camera, nodeGround(node), 70)
			end
		end,
	},
	{
		name = "cross_approach_a",
		settle = 2,
		setup = function(_, camera)
			local node = state.cross
			if node then
				local c = nodeGround(node)
				look(camera, c + Vector3.new(46, 7, -4.5), c + Vector3.new(-10, 9, -3))
			end
		end,
	},
	{
		name = "cross_approach_b_later",
		settle = 7,
		setup = function(_, camera)
			local node = state.cross
			if node then
				local c = nodeGround(node)
				look(camera, c + Vector3.new(46, 7, -4.5), c + Vector3.new(-10, 9, -3))
			end
		end,
	},
	{
		name = "cross_corner",
		setup = function(_, camera)
			local node = state.cross
			if node then
				local c = nodeGround(node)
				look(camera, c + Vector3.new(30, 18, 30), c)
			end
		end,
	},
	{
		name = "tee_top",
		setup = function(_, camera)
			local node = state.tee
			if node then
				topDown(camera, nodeGround(node), 70)
			end
		end,
	},
	{
		name = "tee_stem_approach",
		setup = function(_, camera)
			local node = state.tee
			if node and node.stem then
				local out = ({ E = Vector3.new(1, 0, 0), W = Vector3.new(-1, 0, 0), N = Vector3.new(0, 0, 1), S = Vector3.new(0, 0, -1) })[node.stem]
				local right = Vector3.new(out.Z, 0, -out.X)
				local c = nodeGround(node)
				look(camera, c + out * 34 + right * 4 + Vector3.new(0, 5, 0), c + out * 8 + right * 12 + Vector3.new(0, 6, 0))
			end
		end,
	},
	{
		name = "curve_top",
		setup = function(_, camera)
			local node = state.curve
			if node then
				local middle = node.curve.centre:Lerp(node.position, 0.5)
				topDown(camera, Vector3.new(middle.X, node.height, middle.Z), node.curve.radius * 2.4, 60)
			end
		end,
	},
	{
		name = "curve_driver",
		setup = function(_, camera)
			local node = state.curve
			if node then
				-- At the wheel, entering the curve from one arm.
				local curve = node.curve
				local angle = curve.a1 + curve.sweep * 0.04
				local entry = Vector3.new(curve.centre.X + math.cos(angle) * curve.radius, node.height + 3.5, curve.centre.Z + math.sin(angle) * curve.radius)
				local ahead = curve.a1 + curve.sweep * 0.45
				local at = Vector3.new(curve.centre.X + math.cos(ahead) * curve.radius, node.height + 2, curve.centre.Z + math.sin(ahead) * curve.radius)
				look(camera, entry, at, 70)
			end
		end,
	},
	{
		name = "curve_outside_low",
		setup = function(_, camera)
			local node = state.curve
			if node then
				local curve = node.curve
				local angle = curve.a1 + curve.sweep * 0.5
				local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
				local on = Vector3.new(curve.centre.X + out.X * curve.radius, node.height, curve.centre.Z + out.Z * curve.radius)
				look(camera, on + out * 46 + Vector3.new(0, 7, 0), on + Vector3.new(0, 0.4, 0), 60)
			end
		end,
	},
	{
		name = "bend_top",
		setup = function(_, camera)
			local node = state.bend
			if node then
				topDown(camera, nodeGround(node), 60)
			end
		end,
	},
	{
		name = "bend_low",
		setup = function(_, camera)
			local node = state.bend
			if node then
				local c = nodeGround(node)
				look(camera, c + Vector3.new(24, 8, 26), c)
			end
		end,
	},
	{
		name = "mouth_top",
		setup = function(_, camera)
			local node = state.mouth
			if node then
				topDown(camera, nodeGround(node), 60)
			end
		end,
	},
	{
		name = "mouth_low",
		setup = function(_, camera)
			local node = state.mouth
			if node then
				local armName, edge = next(node.arms)
				local out = edge and edge.dir * (edge.a == node and 1 or -1) or Vector3.new(1, 0, 0)
				local c = nodeGround(node)
				look(camera, c + out * 40 + Vector3.new(0, 7, 0) + Vector3.new(out.Z, 0, -out.X) * 12, c - out * 20)
			end
		end,
	},
	{
		name = "bridge_side",
		setup = function(_, camera)
			local b = state.bridge
			if b then
				local p = b.edge.from + b.edge.dir * b.along
				local top = b.edge.topAt(p)
				local right = Vector3.new(-b.edge.dir.Z, 0, b.edge.dir.X)
				look(camera, Vector3.new(p.X, top, p.Z) + right * 70 + Vector3.new(0, 10, 0), Vector3.new(p.X, top - 4, p.Z))
			end
		end,
	},
	{
		name = "bridge_road",
		setup = function(_, camera)
			local b = state.bridge
			if b then
				local p = b.edge.from + b.edge.dir * (b.along - 60)
				local top = b.edge.topAt(p)
				look(camera, Vector3.new(p.X, top + 6, p.Z), Vector3.new(p.X, top + 3, p.Z) + b.edge.dir * 60)
			end
		end,
	},
	{
		name = "steepest_side",
		setup = function(_, camera)
			local s = state.steepest
			if s then
				local p = s.edge.from + s.edge.dir * s.along
				local top = s.edge.topAt(p)
				local right = Vector3.new(-s.edge.dir.Z, 0, s.edge.dir.X)
				look(camera, Vector3.new(p.X, top, p.Z) + right * 70 + Vector3.new(0, 6, 0), Vector3.new(p.X, top, p.Z), 50)
			end
		end,
	},
	{
		name = "cutting_low",
		setup = function(_, camera)
			local s = state.cutting
			if s then
				-- From the road's edge, low, looking along the road with the bank to one side.
				local right = Vector3.new(-s.edge.dir.Z, 0, s.edge.dir.X)
				local p = s.edge.from + s.edge.dir * (s.along - 45)
				local top = s.edge.topAt(p)
				local at = s.edge.from + s.edge.dir * (s.along + 10) + right * s.side * 22
				look(camera, Vector3.new(p.X, top + 3, p.Z) - right * s.side * 6, Vector3.new(at.X, s.edge.topAt(at) + 1, at.Z), 60)
			end
		end,
	},
	{
		name = "cutting_across",
		setup = function(_, camera)
			local s = state.cutting
			if s then
				-- Across the road at the bank, from the far verge at head height.
				local right = Vector3.new(-s.edge.dir.Z, 0, s.edge.dir.X)
				local p = s.edge.from + s.edge.dir * s.along
				local top = s.edge.topAt(p)
				look(camera, Vector3.new(p.X, top + 5, p.Z) - right * s.side * 18 - s.edge.dir * 20, Vector3.new(p.X, top, p.Z) + right * s.side * 24, 60)
			end
		end,
	},
	{
		name = "verge_low",
		setup = function(_, camera)
			local s = state.longest
			if s then
				-- Standing on the flat verge beside a long straight, looking along the road.
				local right = Vector3.new(-s.edge.dir.Z, 0, s.edge.dir.X)
				local p = s.edge.from + s.edge.dir * s.along + right * 16
				local top = s.edge.topAt(p)
				local at = s.edge.from + s.edge.dir * (s.along + 50) + right * 4
				look(camera, Vector3.new(p.X, top + 4, p.Z), Vector3.new(at.X, s.edge.topAt(at), at.Z), 60)
			end
		end,
	},
	{
		name = "town_signals_top",
		setup = function(_, camera)
			if state.townSignals then
				topDown(camera, state.townSignals, 60)
			end
		end,
	},
	{
		name = "town_signals_low",
		setup = function(_, camera)
			if state.townSignals then
				local p = state.townSignals
				look(camera, p + Vector3.new(-26, 10, 30), p + Vector3.new(0, 3, 0))
			end
		end,
	},
	{
		name = "street_end_low",
		setup = function(_, camera)
			local kerb = state.streetEnd
			if kerb then
				-- From back up the street, at head height, looking at the kerb across its end.
				local back = kerb.CFrame.LookVector
				local p = kerb.Position
				look(camera, p + back * 26 + Vector3.new(0, 5.5, 0) + kerb.CFrame.RightVector * 4, p + Vector3.new(0, 0.5, 0))
			end
		end,
	},
	{
		name = "town_edge_taper_low",
		setup = function(_, camera)
			local taper = state.taper
			if taper then
				local p = taper.Position
				look(camera, p + Vector3.new(14, 5.5, 14), p)
			end
		end,
	},
	{
		name = "bend_outside_player",
		setup = function(_, camera)
			local node = state.bend
			if node then
				local c = nodeGround(node)
				-- Outside the corner, standing on the verge.
				local out = Vector3.zero
				for name in pairs(node.arms) do
					out -= ({ E = Vector3.new(1, 0, 0), W = Vector3.new(-1, 0, 0), N = Vector3.new(0, 0, 1), S = Vector3.new(0, 0, -1) })[name]
				end
				look(camera, c + out * 22 + Vector3.new(0, 5.5, 0), c + Vector3.new(0, 0.4, 0))
			end
		end,
	},
	{
		name = "town_stop_top",
		setup = function(_, camera)
			if state.townStop then
				topDown(camera, state.townStop, 60)
			end
		end,
	},
	{
		name = "town_stop_low",
		setup = function(_, camera)
			if state.townStop then
				local p = state.townStop
				look(camera, p + Vector3.new(14, 6, 16), p + Vector3.new(0, 5, 0))
			end
		end,
	},
}
	for _, view in ipairs(views) do
		view.name = MAP_ID .. "_" .. view.name
	end
	return views
end

-- If the map didn't build, every later view of that map fails straight away instead of holding the
-- camera on nothing.
local views = {}
for _, run in ipairs(RUNS) do
	for index, view in ipairs(viewsFor(run.map, run.seed)) do
		if index > 1 then
			local setup = view.setup
			view.setup = function(folder, camera)
				if not state.info then
					error("no map")
				end
				setup(folder, camera)
			end
		end
		table.insert(views, view)
	end
end

return views
