-- The battleground in the middle of a team match (TeamBattleground), built the way a match builds it and
-- photographed.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/team_battleground_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- Oliver, 2026-09-24: "make a way better quality and more fun to play around battleground in the centre
-- of the maps for the team gamemodes", then "make the battleground work with the road -- it's clipped all
-- over the road and stuff" and "make the battleground higher quality too". tools/team_battleground_check.py
-- has measured the layout offline (mirror symmetry, nothing floating, walkable from both bases with no
-- traps, every power position two ways up, lane sightlines, cover spacing, objectives, vehicle routes,
-- loot, ziplines, z-fighting, and the roads cut square and finished at the apron's edge on a mock town).
-- What it cannot say is how it LOOKS, or how it sits in a real town once the town has been cleared off
-- the site. This builds a real map (RotRidge, the roughest ground of the five, and the one
-- tools/team_base_ruins_gallery.lua uses), runs the real ModeTeams.Setup for a Team Deathmatch (bases,
-- then the battleground: site clearing and road ends, FlattenPad, the ziplines, the loot), then frames
-- each part of it.
--
-- The notes are the probe. THE GROUND IS READ FROM THE VOXELS (MapTerrain.PadCost over a column), never
-- by terrain raycast: a terrain ray straight after Terrain:WriteVoxels still reads the ground as it was
-- before the write (measured here: every "floating" slab this gallery used to report was one of those).
--   * parts, the height it stands at, whether the ground was levelled, ZFight.Scan over the placed model
--     (terrain pairs included, which the offline check cannot see), the ground under every paving slab
--     (a slab whose underside is above the ground is floating; want 0);
--   * the clearing: EVERY map part (queryable or not) left inside the disc and its margin (want 0), and
--     road pieces (asphalt, kerbs, pavements, markings) left inside the apron's edge (want 0);
--   * the road ends: how many, where round the arena, the carriageway's end over the ground there (a
--     vehicle drives straight on: want under 0.5), and the gateway's beam over the road;
--   * ziplines hung (want 4), loot on its spots, each objective's floor (a ray down from it must land on
--     the battleground within half a stud) and its distance to each base (want equal), BotNav's hints.
-- Planted: a paving slab lifted 1 stud must read floating; a Kerb dropped in the middle must be counted.
--
-- Views: 01 overview from team 1, 02 straight down over the whole site and its roads, 03-05 the three
-- lanes at eye level from team 1's end, 06 the keep's gallery, 07 objective A, 08 objective B, 09 the
-- market, 10 the bridge, 11 the keep at dusk, 12 the whole arena at dusk; then each road's end (up to
-- four): at eye level driving in, and from above.

local MAP_ID, SEED = "RotRidge", 101

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function look(camera, from, at, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, at)
end

-- A point in the battleground's frame (local studs from its centre at floor level; -Z is team 1's
-- side, +Z team 2's; the pit is -X, the container lane +X).
local function at(x, y, z)
	return state.field.frame * Vector3.new(x, y, z)
end

-- The ground at (x, z) from the voxels, as MapTerrain measures every pad (the columns within 2.9: one
-- to four of them, averaged).
local function groundAt(x, z)
	local MapTerrain = state.MapTerrain
	local ok, _, _, mean = pcall(MapTerrain.PadCost, CFrame.new(x, 0, z), Vector3.zero, { shape = "round", margin = 2.9 })
	return ok and mean or nil
end

-- Slabs that should be sitting on the levelled ground: how many have their underside clear of the
-- ground at any corner (floating) or no ground under them at all.
local function groundGaps(parts)
	local floating = 0
	for _, part in ipairs(parts) do
		local half = part.Size / 2
		for _, corner in ipairs({ Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1), Vector3.new(1, -1, -1), Vector3.new(-1, -1, -1) }) do
			local point = part.CFrame * (half * corner * Vector3.new(0.95, 1, 0.95))
			local ground = groundAt(point.X, point.Z)
			if not ground or point.Y > ground + 0.05 then
				floating += 1
				break
			end
		end
	end
	return floating
end

local ROAD_PIECES = {
	RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true, RoadEdge = true, RoadDash = true,
	RoadCentreLine = true, StopLine = true, Dash = true, Crossing = true, Kerb = true, Pavement = true, Paving = true,
	Cobbles = true, RoadCurve = true, DroppedKerb = true, PavementTaper = true,
}

-- The map's own parts on the site: everything (queryable or not) but the terrain, the bases, the
-- battleground itself and KEEP's folders, within `radius` of the middle (by the nearest point of its
-- footprint); and the road pieces within `roadRadius`.
local function leftOn(map, model, flat, radius, roadRadius)
	local left, roads = {}, {}
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and not part:IsDescendantOf(model) and not part:GetAttribute("TeamBaseRuin") then
			local top = part
			while top.Parent and top.Parent ~= map do
				top = top.Parent
			end
			local keep = top.Name == "River" or top.Name == "Ziplines" or top.Name == "TeamBaseVehicles"
			local cf, size = part.CFrame, part.Size
			local ex = math.abs(cf.RightVector.X) * size.X / 2 + math.abs(cf.UpVector.X) * size.Y / 2 + math.abs(cf.LookVector.X) * size.Z / 2
			local ez = math.abs(cf.RightVector.Z) * size.X / 2 + math.abs(cf.UpVector.Z) * size.Y / 2 + math.abs(cf.LookVector.Z) * size.Z / 2
			local dx = math.max(0, math.abs(cf.Position.X - flat.X) - ex)
			local dz = math.max(0, math.abs(cf.Position.Z - flat.Z) - ez)
			local near = math.sqrt(dx * dx + dz * dz)
			if not keep and near < radius and part.Transparency < 1 then
				table.insert(left, part)
			end
			if not keep and ROAD_PIECES[part.Name] and near < roadRadius - 0.5 then
				table.insert(roads, part)
			end
		end
	end
	return left, roads
end

local function setup()
	if state.ready then
		return
	end
	Lighting.ClockTime = 14.5
	math.randomseed(SEED)
	local modules = ServerScriptService:WaitForChild("Modules")
	local MapGenerator = require(modules:WaitForChild("MapGenerator"))
	local ModeTeams = require(modules:WaitForChild("ModeTeams"))
	local BotNav = require(modules:WaitForChild("BotNav"))
	local TeamBattleground = require(modules:WaitForChild("TeamBattleground"))
	state.MapTerrain = require(modules:WaitForChild("MapTerrain"))
	local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
	local GameModes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameModes"))

	local ok, info = pcall(MapGenerator.Build, MAP_ID)
	if not ok then
		note("MAP BUILD FAILED: " .. tostring(info))
		error(info)
	end
	Lighting.ClockTime = 14.5
	note(string.format("built %s seed %d, radius %d", MAP_ID, SEED, info.radius))

	local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
	local started = os.clock()
	local centre, radius = ModeTeams.Setup(mode, info)
	note(string.format("ModeTeams.Setup: arena r %.0f at (%.0f, %.0f), %.2f s CPU", radius, centre.X, centre.Z, os.clock() - started))
	local field = ModeTeams.Battleground()
	if not field then
		note("NO BATTLEGROUND (see the warning above)")
		error("no battleground")
	end
	state.field = field
	task.wait(0.5)

	local model = field.model
	local parts, paving = 0, {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			parts += 1
			-- Slabs sunk into the ground (the keep's flagstones rest on its foundation slab, not on it).
			if part.Name == "Paving" and part.Position.Y - part.Size.Y / 2 < field.height - 0.2 then
				table.insert(paving, part)
			end
		end
	end
	local flat = field.frame.Position
	local levelled = state.MapTerrain.PadAt(flat.X + 30, flat.Z + 30)
	note(string.format("battleground: %d parts, floor at %.2f, ground %s", parts, field.height,
		levelled and string.format("levelled (pad at %.2f)", levelled) or "NOT LEVELLED (built on it as it stands)"))

	local pairsFound = ZFight.Scan({ model })
	note(string.format("ZFight.Scan over the placed model: %d pairs", #pairsFound))
	for index, pair in ipairs(pairsFound) do
		if index > 8 then
			break
		end
		note(string.format("  zfight %s / %s gap %.3f", pair.a:GetFullName(), pair.b.Name, pair.gap))
	end
	note(string.format("ground (voxels): %d of %d paving slabs floating", groundGaps(paving), #paving))

	-- The clearing and the roads.
	local map = info.map
	local left, roads = leftOn(map, model, flat, TeamBattleground.Radius + TeamBattleground.Margin, TeamBattleground.RoadEnd)
	note(string.format("clearing: %d map parts (queryable or not) left inside the disc and its margin; %d road pieces inside the apron's edge (%.0f)",
		#left, #roads, TeamBattleground.RoadEnd))
	for index, part in ipairs(left) do
		if index > 8 then
			break
		end
		note("  left " .. part:GetFullName())
	end
	for index, part in ipairs(roads) do
		if index > 6 then
			break
		end
		note("  road piece left " .. part:GetFullName())
	end
	state.ends = {}
	for _, roadEnd in ipairs(field.roadEnds and field.roadEnds:GetChildren() or {}) do
		local beam, sign, line = nil, nil, nil
		for _, part in ipairs(roadEnd:GetDescendants()) do
			if part.Name == "GatewayBeam" then
				beam = part
			elseif part.Name == "GatewaySign" then
				sign = part
			elseif part.Name == "StopLine" then
				line = part
			end
		end
		if line then
			-- The end's frame: on the carriageway's centre line at the cut, +Z out along the road.
			local look = (sign.Position - line.Position) * Vector3.new(1, 0, 1)
			local out = look.Unit
			local cut = line.Position - out * 1.4
			local road = cut.Y - 0.07 - 0.4
			local inside = cut - out * 6
			local ground = groundAt(inside.X, inside.Z)
			local l = field.frame:PointToObjectSpace(cut)
			table.insert(state.ends, { cut = Vector3.new(cut.X, road, cut.Z), out = out })
			note(string.format("road end %d: %.0f out at %.0f deg round the arena (local %.0f, %.0f); road ground %.2f, arena ground 6 in %.2f (step %.2f); beam %.1f over the road",
				#state.ends, Vector3.new(l.X, 0, l.Z).Magnitude, math.deg(math.atan2(l.X, -l.Z)), l.X, l.Z, road, ground or -1,
				ground and road - ground or -1, beam and (beam.Position.Y - beam.Size.Y / 2 - road) or -1))
		end
	end
	note(string.format("road ends finished: %d", #state.ends))

	note(string.format("ziplines hung: %d of %d", #field.ziplines, #field.zips))

	local loot = workspace:FindFirstChild("Loot")
	local onSpots = 0
	for _, spot in ipairs(field.lootSpots) do
		for _, item in ipairs(loot and loot:GetChildren() or {}) do
			if item:IsA("BasePart") and (item.Position - spot.position).Magnitude < 4 then
				onSpots += 1
				break
			end
		end
	end
	note(string.format("loot: %d of %d spots with something on them", onSpots, #field.lootSpots))

	local only = RaycastParams.new()
	only.FilterType = Enum.RaycastFilterType.Include
	only.FilterDescendantsInstances = { model }
	for index, point in ipairs(field.objectives) do
		local hit = workspace:Raycast(point + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), only)
		local floorGap = hit and (point.Y - hit.Position.Y) or math.huge
		local d1 = (point - ModeTeams.BaseOf(1)) * Vector3.new(1, 0, 1)
		local d2 = (point - ModeTeams.BaseOf(2)) * Vector3.new(1, 0, 1)
		note(string.format("objective %s at (%.1f, %.2f, %.1f): floor %s (gap %.2f), %.1f from base 1, %.1f from base 2",
			string.char(64 + index), point.X, point.Y, point.Z, hit and hit.Instance.Name or "NONE", floorGap, d1.Magnitude, d2.Magnitude))
	end
	note(string.format("cover points: %d; BotNav.CoverHints %s", #field.cover, BotNav.CoverHints and "set" or "NOT SET"))

	-- Planted: a paving slab lifted a stud off the ground must be reported floating; a kerb dropped on
	-- the site must be counted.
	if paving[1] then
		local copy = paving[1]:Clone()
		copy.CFrame = paving[1].CFrame + Vector3.new(0, 1, 0)
		copy.Parent = workspace
		note("planted: a paving slab lifted 1 stud reads " .. (groundGaps({ copy }) == 1 and "FLOATING (caught)" or "grounded (MISSED)"))
		copy:Destroy()
	end
	local kerb = Instance.new("Part")
	kerb.Name = "Kerb"
	kerb.Anchored = true
	kerb.CanQuery = false
	kerb.Size = Vector3.new(20, 0.56, 0.8)
	kerb.CFrame = CFrame.new(at(40, 0.22, -60))
	kerb.Parent = map
	local _, planted = leftOn(map, model, flat, 0, TeamBattleground.RoadEnd)
	note("planted: a non-queryable kerb on the site reads " .. (#planted == #roads + 1 and "COUNTED (caught)" or "unseen (MISSED)"))
	kerb:Destroy()
	state.ready = true
end

local function view(name, from, target, fov, extra)
	return {
		name = name,
		settle = 3,
		setup = function(_, camera)
			setup()
			Lighting.ClockTime = 14.5
			if extra then
				extra()
			end
			look(camera, at(from[1], from[2], from[3]), at(target[1], target[2], target[3]), fov)
		end,
	}
end

-- The k-th road end: at eye level on the road 34 out, looking in along it; or from 46 up over it.
local function endView(k, above)
	return {
		name = string.format("%02d_road_end_%d_%s", 12 + k * 2 - (above and 0 or 1), k, above and "from_above" or "eye_level_driving_in"),
		settle = 3,
		setup = function(_, camera)
			setup()
			Lighting.ClockTime = 14.5
			local e = state.ends[k]
			if not e then
				look(camera, at(0, 420, 1), at(0, 0, 0), 50)
				return
			end
			if above then
				look(camera, e.cut + e.out * 24 + Vector3.new(0, 46, 0) + e.out:Cross(Vector3.yAxis) * 18, e.cut - e.out * 14, 60)
			else
				look(camera, e.cut + e.out * 34 + Vector3.new(0, 5.2, 0), e.cut - e.out * 40 + Vector3.new(0, 4, 0), 70)
			end
		end,
	}
end

local views = {
	view("01_overview_from_team1", { 0, 110, -190 }, { 0, 0, -10 }, 55),
	view("02_straight_down_the_site_and_its_roads", { 0, 430, 1 }, { 0, 0, 0 }, 50),
	-- Eye level (5.2 above the floor, an R15's eyes) from team 1's end of each lane.
	view("03_centre_lane_eye_level", { 0, 5.2, -118 }, { 0, 5, 0 }, 70),
	view("04_west_lane_to_the_pit_eye_level", { -62, 5.2, -108 }, { -80, 4, 0 }, 70),
	view("05_east_container_lane_eye_level", { 70, 5.2, -112 }, { 84, 5, -20 }, 70),
	view("06_keep_gallery_into_the_hall", { -15, 16.2, -16 }, { 10, 9, 8 }, 70),
	-- From the gallery's edge, looking down through the void onto the rot eye.
	view("07_objective_A_rot_eye", { -3, 16.5, -13.5 }, { 0.5, 0.8, 0.5 }, 70),
	view("08_objective_B_pit_fountain", { -60, 12, -24 }, { -86, 1, 2 }, 70),
	view("09_market_eye_level", { 50, 5.2, -70 }, { 48, 4, -10 }, 70),
	view("10_bridge_to_the_gantry", { 32, 16, -1 }, { 104, 11, 0 }, 65),
	view("11_keep_at_dusk", { -30, 34, -80 }, { 0, 6, 0 }, 60, function()
		Lighting.ClockTime = 19.4
	end),
	view("12_arena_at_dusk", { 60, 90, -170 }, { 0, 0, 0 }, 60, function()
		Lighting.ClockTime = 19.4
	end),
}
for k = 1, 4 do
	table.insert(views, endView(k, false))
	table.insert(views, endView(k, true))
end

return views
