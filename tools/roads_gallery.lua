-- Roads touch-up gallery (Oliver 09-24: "looks over every road and touches it up and makes sure all
-- roads are flush and connected"): the places tools/roads_check.py measures, photographed on the real
-- terrain, which the harness only models. For each run, a map from a fixed seed and:
--
--   curve_join_top / curve_join_wheel   where a straight meets a curve: the edge lines carry straight
--                                       on round it (they used to step sideways by 0.3 there)
--   cross_top / tee_top                 a junction's arms meeting its box
--   bridge_a_wheel / bridge_b_wheel     each end of a bridge from the driver's seat, and one side-on
--   mouth_wheel                         a road running into a town's street
--   carpark_top / carpark_low           a car park in a street's row of lots, its kerb dropped and pavement cut at its aisle
--   driveway_low                        a driveway's dropped kerb
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/roads_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Notes printed: RoadNetwork:Audit's summary (holes, steps, ground under the road, joints, overlaps,
-- connectivity) on the REAL terrain, and how many car parks and dropped kerbs the map has. What to look
-- for, by eye: no lip or seam where anything meets anything, no terrain showing through asphalt, no
-- asphalt edge standing in the air, lines unbroken round the curves, a way in to every car park.

local RUNS = {
	{ map = "TralalaTown", seed = 1 },
	{ map = "RotRidge", seed = 2 },
	{ map = "BombardiroBay", seed = 3 },
}

local ServerScriptService = game:GetService("ServerScriptService")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function topDown(camera, position, height, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(position + Vector3.new(0, height, 0), position, Vector3.new(0, 0, -1))
end

local function look(camera, from, at, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, at)
end

local function survey(info)
	local map = workspace.Map
	local roads = info.roads
	local audit = roads:Audit(map)
	note("roads: " .. audit.summary)
	for _, node in ipairs(roads.nodes) do
		if node.curve and not state.curve then
			state.curve = node
		end
		if (node.kind == "cross" or node.kind == "tee") and not state[node.kind] then
			state[node.kind] = node
		end
		if node.kind == "mouth" and not state.mouth then
			state.mouth = node
		end
	end
	for _, edge in ipairs(roads.edges) do
		if edge.bridges and #edge.bridges > 0 and not state.bridge then
			state.bridge = { edge = edge, span = edge.bridges[1] }
		end
	end
	local lots, dropped = 0, 0
	for _, d in ipairs(map:GetDescendants()) do
		if d.Name == "ParkingLot" then
			lots += 1
		elseif d.Name == "DroppedKerb" then
			dropped += 1
			-- A car park's is its aisle's width (ParkingLots' AISLE, 14); a driveway's the width of its strip.
			local width = math.max(d.Size.X, d.Size.Z)
			if width > 10 and not state.carpark then
				state.carpark = d
			elseif width <= 10 and not state.driveway then
				state.driveway = d
			end
		end
	end
	note(string.format("car parks %d, dropped kerbs %d", lots, dropped))
end

local function ground(node)
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
				local MapGenerator = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("MapGenerator"))
				local ok, info = pcall(MapGenerator.Build, MAP_ID)
				if not ok then
					note("BUILD FAILED: " .. tostring(info))
					error(info)
				end
				state.info = info
				-- Terrain written this frame isn't raycastable yet (COORDINATION: measure a frame after).
				task.wait(1)
				local okSurvey, err = pcall(survey, info)
				if not okSurvey then
					note("SURVEY FAILED: " .. tostring(err))
				end
				topDown(camera, Vector3.zero, info.radius * 1.45, 70)
			end,
		},
		{
			name = "curve_join_top",
			setup = function(_, camera)
				local node = state.curve
				if node then
					local c = node.curve
					local p = Vector3.new(c.centre.X + math.cos(c.a1) * c.radius, node.height, c.centre.Z + math.sin(c.a1) * c.radius)
					topDown(camera, p, 30)
				end
			end,
		},
		{
			name = "curve_join_wheel",
			setup = function(_, camera)
				local node = state.curve
				if node then
					-- On the straight, 20 studs before the curve, at the wheel, looking into it.
					local c = node.curve
					local tangent = Vector3.new(c.centre.X + math.cos(c.a1) * c.radius, 0, c.centre.Z + math.sin(c.a1) * c.radius)
					local into = Vector3.new(-math.sin(c.a1), 0, math.cos(c.a1)) * (c.sweep >= 0 and 1 or -1)
					local from = tangent - into * 20 + Vector3.new(0, node.height + 3.5, 0)
					local ahead = c.a1 + c.sweep * 0.3
					local at = Vector3.new(c.centre.X + math.cos(ahead) * c.radius, node.height + 1, c.centre.Z + math.sin(ahead) * c.radius)
					look(camera, from, at, 70)
				end
			end,
		},
		{
			name = "cross_top",
			setup = function(_, camera)
				if state.cross then
					topDown(camera, ground(state.cross), 45)
				end
			end,
		},
		{
			name = "tee_top",
			setup = function(_, camera)
				if state.tee then
					topDown(camera, ground(state.tee), 45)
				end
			end,
		},
		{
			name = "bridge_a_wheel",
			setup = function(_, camera)
				local b = state.bridge
				if b then
					local e = b.edge
					local p = e.from + e.dir * (b.span.s0 - 25)
					look(camera, Vector3.new(p.X, e.topAt(p) + 3.5, p.Z), Vector3.new(p.X, e.topAt(p) + 1, p.Z) + e.dir * 40, 70)
				end
			end,
		},
		{
			name = "bridge_b_wheel",
			setup = function(_, camera)
				local b = state.bridge
				if b then
					local e = b.edge
					local p = e.from + e.dir * (b.span.s1 + 25)
					look(camera, Vector3.new(p.X, e.topAt(p) + 3.5, p.Z), Vector3.new(p.X, e.topAt(p) + 1, p.Z) - e.dir * 40, 70)
				end
			end,
		},
		{
			name = "bridge_end_side",
			setup = function(_, camera)
				local b = state.bridge
				if b then
					local e = b.edge
					local p = e.from + e.dir * b.span.s0
					local right = Vector3.new(-e.dir.Z, 0, e.dir.X)
					look(camera, Vector3.new(p.X, e.topAt(p) + 2, p.Z) + right * 30, Vector3.new(p.X, e.topAt(p) - 1, p.Z), 60)
				end
			end,
		},
		{
			name = "mouth_wheel",
			setup = function(_, camera)
				local node = state.mouth
				if node then
					local _, edge = next(node.arms)
					local out = edge and edge.dir * (edge.a == node and 1 or -1) or Vector3.new(1, 0, 0)
					local right = Vector3.new(-out.Z, 0, out.X)
					local c = ground(node)
					look(camera, c + out * 30 - right * 4 + Vector3.new(0, 3.5, 0), c - out * 25 + Vector3.new(0, 1, 0), 70)
				end
			end,
		},
		{
			name = "carpark_top",
			setup = function(_, camera)
				local d = state.carpark
				if d then
					topDown(camera, d.Position, 55)
				end
			end,
		},
		{
			name = "carpark_low",
			setup = function(_, camera)
				local d = state.carpark
				if d then
					-- At head height 18 studs off the dropped kerb, square across it (from the street or
					-- from the car park, whichever side that is), looking over it.
					local across = d.Size.X >= d.Size.Z and d.CFrame.LookVector or d.CFrame.RightVector
					look(camera, d.Position + across * 18 + Vector3.new(0, 5, 0), d.Position - across * 20, 65)
				end
			end,
		},
		{
			name = "driveway_low",
			setup = function(_, camera)
				local d = state.driveway
				if d then
					local across = d.Size.X >= d.Size.Z and d.CFrame.LookVector or d.CFrame.RightVector
					look(camera, d.Position + across * 10 + Vector3.new(0, 4, 0) + d.CFrame.LookVector * 3, d.Position - across * 6, 65)
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
