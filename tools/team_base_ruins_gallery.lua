-- The team-base compounds (TeamBaseRuins), built the way a team match builds them and photographed.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/team_base_ruins_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- Oliver, 2026-09-24: "design a ruined base with very high quality for both team spawns so that all the
-- item chests and cars aren't just sitting in random fields", then "the team bases are on a platform
-- that's raised up and needs a ramp for the players and vehicles, or it needs to be made more flush to
-- the ground". tools/team_base_ruins_check.py has measured the geometry offline (no coplanar faces,
-- nothing floating, walkable, bays level and clear, both bases identical) and Build on a hillside (flush,
-- banks at 1 in 3, gate ramps at 1 in 8, scenery on moved ground cleared); what it cannot say is how the
-- thing LOOKS, or how it sits on a real map's ground. This builds a real map (RotRidge, the roughest
-- ground of the five), runs the real ModeTeams.Setup for a Team Deathmatch (so the site choice, the
-- terrain levelling and grading, the site clearing, the base vehicles in their bays), seeds each base's
-- chests through the real ModeTeams.BaseLootSpots and LootService.SeedAt, and then frames the compound
-- and the ground round it.
--
-- The notes are the probe. THE GROUND IS READ FROM THE VOXELS (MapTerrain.PadCost over a column), and a
-- terrain ray is trusted only where it agrees with them to 1.5 studs (a rough material draws its surface
-- up to 1.1 off its voxels): a terrain ray straight after Terrain:WriteVoxels still reads the ground as
-- it was before the write, and that is what put the compounds on plinths and made this gallery report
-- "61 of 61 slabs/panels floating". Per base: parts, the floor, the ground work (columns moved, the
-- highest bank), FLUSH (the ground two studs outside every wall against the floor's ground: want under
-- 0.5), the gate ramps (the steepest grade out of each vehicle gate: want 1 in 8 or gentler) and the
-- banks (want 1 in 3), pads, chests on their spots, vehicles in their bays and overlapping, ZFight.Scan
-- over the placed model, slabs/panels floating over the ground, and map scenery hovering round the
-- compound (named). Planted: a slab lifted 1 stud must read floating.
--
-- Views: 01-02 the two compounds from high; 03-06 team 1's from outside at eye level (on the ground
-- there) on every side; 07-08 each vehicle gate's ramp with a vehicle on it; 09 the ground round the
-- compound from high on the downhill side; 10 team 2's front at eye level; 11-14 inside (spawn shelter,
-- vehicle yard, supply room, courtyard from the tower); 15 dusk.

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

-- A point in team `team`'s compound frame (local studs; -Z is the front, the gate side is +X).
local function at(team, x, y, z)
	return state.ruins[team].frame * Vector3.new(x, y, z)
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.IgnoreWater = true

-- The ground at (x, z): the voxels' (the columns within 2.9, averaged), or the terrain ray's where it
-- agrees with them to 1.5 (the drawn surface, which a rough material puts up to 1.1 off its voxels).
local function groundAt(x, z)
	local ok, _, _, mean = pcall(state.MapTerrain.PadCost, CFrame.new(x, 0, z), Vector3.zero, { shape = "round", margin = 2.9 })
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1800, 0), terrainParams)
	local ray = hit and hit.Position.Y or nil
	if ok and mean and (not ray or math.abs(mean - ray) > 1.5) then
		return mean
	end
	return ray
end

-- The ground in team `team`'s frame, at a local point.
local function groundLocal(team, x, z)
	local p = at(team, x, 0, z)
	return groundAt(p.X, p.Z)
end

-- The ground's SHAPE at a local point: the voxels' alone (a rough material's drawn surface is not the
-- grade a wheel climbs over a few studs).
local function shapeLocal(team, x, z)
	local p = at(team, x, 0, z)
	local ok, _, _, mean = pcall(state.MapTerrain.PadCost, CFrame.new(p.X, 0, p.Z), Vector3.zero, { shape = "round", margin = 2.9 })
	return ok and mean or nil
end

-- Slabs and panels that should be sitting in the ground: how many have their underside clear of the
-- ground at any corner (floating) or no ground at all under them.
local function groundGaps(parts)
	local floating, examined = 0, 0
	for _, part in ipairs(parts) do
		examined += 1
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
	return floating, examined
end

local function grounded(model, height)
	local list = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and (part.Name == "Paving" or part.Name == "Wall" or part.Name == "BunkerWall" or part.Name == "GatePost") then
			-- Only what stands on the flattened ground itself (the supply room's walls stand on it too).
			if part.Position.Y - part.Size.Y / 2 < height + 0.5 or part.Name == "Paving" then
				table.insert(list, part)
			end
		end
	end
	return list
end

-- The steepest grade of the ground's shape along a local line from `from` (over 4 studs, a voxel column,
-- sampled every 2), and the height it ends at over the floor's ground.
local function steepest(team, from, dir, length)
	local worst, at, heights = 0, 0, {}
	local base = state.ruins[team].height
	for k = 0, length, 2 do
		local p = from + dir * k
		heights[#heights + 1] = shapeLocal(team, p.X, p.Z)
	end
	for index = 3, #heights do
		if heights[index] and heights[index - 2] then
			local grade = math.abs(heights[index] - heights[index - 2]) / 4
			if grade > worst then
				worst, at = grade, (index - 2) * 2
			end
		end
	end
	local last = heights[#heights]
	return worst, last and last - base or 0, at
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
	local LootService = require(modules:WaitForChild("LootService"))
	state.MapTerrain = require(modules:WaitForChild("MapTerrain"))
	state.TeamBaseRuins = require(modules:WaitForChild("TeamBaseRuins"))
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

	state.ruins = {}
	for team = 1, 2 do
		local ruin = ModeTeams.BaseRuin(team)
		if not ruin then
			note("team " .. team .. ": NO COMPOUND (fell back to open-ground pads)")
			error("no compound")
		end
		state.ruins[team] = ruin
	end

	-- Chests, as GameMode seeds them (its call today passes no kind; gap 14 is the chest call).
	for team = 1, 2 do
		local spots = ModeTeams.BaseLootSpots(team, LootService.BaseStock.chest, 20, 80, 14, "chest")
		LootService.SeedAt(spots, "chest")
		local weapons = ModeTeams.BaseLootSpots(team, 16, 10, 80, 6)
		LootService.SeedAt(weapons, "weapon")
	end
	task.wait(0.5)

	local loot = workspace:FindFirstChild("Loot")
	local folder = ModeTeams.BaseVehicleFolder()
	for team = 1, 2 do
		local ruin = state.ruins[team]
		local model = ruin.model
		local parts = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				parts += 1
			end
		end
		local chestsOn = 0
		for _, spot in ipairs(ruin.chestSpots) do
			for _, item in ipairs(loot and loot:GetChildren() or {}) do
				if item.Name == "Chest" and (item.Position - spot.Position).Magnitude < 3 then
					chestsOn += 1
					break
				end
			end
		end
		local vehiclesIn = 0
		for _, bay in ipairs(ruin.vehicleBays) do
			for _, vehicle in ipairs(folder and folder:GetChildren() or {}) do
				if vehicle:IsA("Model") and (vehicle:GetPivot().Position * Vector3.new(1, 0, 1) - bay.Position * Vector3.new(1, 0, 1)).Magnitude < 1 then
					vehiclesIn += 1
					break
				end
			end
		end
		local vehicles = {}
		for _, vehicle in ipairs(folder and folder:GetChildren() or {}) do
			if vehicle:IsA("Model") then
				table.insert(vehicles, vehicle)
			end
		end
		local overlaps = 0
		for i = 1, #vehicles do
			for j = i + 1, #vehicles do
				local ca, sa = vehicles[i]:GetBoundingBox()
				local cb, sb = vehicles[j]:GetBoundingBox()
				local d = ca:PointToObjectSpace(cb.Position)
				if math.abs(d.X) < (sa.X + sb.X) / 2 - 0.2 and math.abs(d.Z) < (sa.Z + sb.Z) / 2 - 0.2 then
					overlaps += 1
				end
			end
		end

		-- FLUSH: the ground two studs outside each wall, seven points a side, against the floor's ground.
		local floorGround = ruin.height
		local worst, sides = 0, {}
		for _, side in ipairs({ { "front", 0, -1 }, { "east", 1, 0 }, { "back", 0, 1 }, { "west", -1, 0 } }) do
			local sideWorst = 0
			for t = -0.9, 0.91, 0.3 do
				local x = side[2] ~= 0 and side[2] * 48 or t * 44
				local z = side[3] ~= 0 and side[3] * 44 or t * 40
				local g = groundLocal(team, x, z)
				if g then
					sideWorst = math.max(sideWorst, math.abs(g - floorGround))
				end
			end
			worst = math.max(worst, sideWorst)
			table.insert(sides, string.format("%s %.2f", side[1], sideWorst))
		end
		note(string.format("team %d FLUSH: the ground 2 outside the walls is at most %.2f off the floor's ground (%s; want under 0.5)",
			team, worst, table.concat(sides, ", ")))
		-- The ramps out of the vehicle gates and the banks on the other sides.
		-- Out of each gate along its middle, from 6 past the wall to 124 past the pad's flat edge (the work
		-- reaches 136 past it and meets the ground as it stands there); the banks on the other sides out to 48.
		local frontRamp, frontEnd, frontAt = steepest(team, Vector3.new(33, 0, -60), Vector3.new(0, 0, -1), 130)
		local eastRamp, eastEnd, eastAt = steepest(team, Vector3.new(72, 0, 29), Vector3.new(1, 0, 0), 130)
		local banks, bankAt = 0, ""
		for _, line in ipairs({ { -30, 60, 0, 1 }, { 20, 60, 0, 1 }, { -72, -30, -1, 0 }, { -72, 10, -1, 0 }, { -50, -60, 0, -1 } }) do
			local grade, _, where = steepest(team, Vector3.new(line[1], 0, line[2]), Vector3.new(line[3], 0, line[4]), 48)
			if grade > banks then
				banks, bankAt = grade, string.format("%d out from (%d, %d)", where, line[1], line[2])
			end
		end
		local graded = ruin.graded or {}
		note(string.format("team %d ground work: %s columns moved, the most by %.1f, banks up to %.1f off the floor; %s scenery cleared off moved ground",
			team, tostring(graded.moved), graded.most or -1, graded.bank or -1, tostring(graded.cleared)))
		note(string.format("team %d RAMPS: main gate steepest 1 in %.1f (%d out; ground %+.1f at 130); east gate 1 in %.1f (%d out; %+.1f); banks elsewhere steepest 1 in %.1f (%s)",
			team, frontRamp > 0 and 1 / frontRamp or math.huge, frontAt, frontEnd, eastRamp > 0 and 1 / eastRamp or math.huge, eastAt, eastEnd,
			banks > 0 and 1 / banks or math.huge, bankAt))

		-- Map scenery round the compound hovering over the ground under it (named).
		local hovering, looked, named, onMoved = 0, 0, {}, 0
		local restParams = RaycastParams.new()
		restParams.FilterType = Enum.RaycastFilterType.Exclude
		local centreFlat = ruin.frame.Position * Vector3.new(1, 0, 1)
		local function meantToFloat(part)
			local node = part
			while node and node ~= workspace.Map do
				if node:GetAttribute("IntentionalFloat") then
					return true
				end
				node = node.Parent
			end
			return false
		end
		for _, part in ipairs(workspace.Map:GetDescendants()) do
			if part:IsA("BasePart") and not part:IsDescendantOf(model) and part.Anchored and not meantToFloat(part)
				and not part:FindFirstAncestor("TeamBaseVehicles")
				and (part.Position * Vector3.new(1, 0, 1) - centreFlat).Magnitude < 140 then
				local bottom = part.Position.Y - part.Size.Y / 2
				local ground = groundAt(part.Position.X, part.Position.Z)
				if ground and bottom < ground + 6 then
					looked += 1
					-- Resting on another part (a road's marking on its slab, a landmark's piece on its
					-- platform) is not hovering: a short ray down from just inside its underside.
					restParams.FilterDescendantsInstances = { part, workspace.Terrain }
					local under = workspace:Raycast(Vector3.new(part.Position.X, bottom + 0.3, part.Position.Z), Vector3.new(0, -0.9, 0), restParams)
					local moved = state.TeamBaseRuins.MovedAt(ruin.graded, part.Position.X, part.Position.Z)
					if bottom > ground + 0.3 and not under then
						hovering += 1
						if moved and math.abs(moved) > 0.3 then
							onMoved += 1
						end
						if #named < 10 or (moved and math.abs(moved) > 0.3) then
							local top = part
							while top.Parent and top.Parent ~= workspace.Map do
								top = top.Parent
							end
							local l = ruin.frame:PointToObjectSpace(part.Position)
							table.insert(named, (moved and math.abs(moved) > 0.3) and 1 or #named + 1, string.format("%s/%s %.1f up at (%.0f, %.0f)%s, ground %s", top.Name, part.Name, bottom - ground, l.X, l.Z,
								part.CanCollide and "" or " non-collidable", moved and string.format("moved %+.1f", moved) or "not graded"))
						end
					end
				end
			end
		end
		note(string.format("team %d: %d base vehicles, %d overlapping pairs (want 0); map scenery within 140: %d near the ground, %d hovering over 0.3 with nothing under it, %d of them on ground the base's work moved (want 0)%s",
			team, #vehicles, overlaps, looked, hovering, onMoved, #named > 0 and (": " .. table.concat(named, ", ")) or ""))
		local pairsFound = ZFight.Scan({ model })
		local floating, examined = groundGaps(grounded(model, ruin.height))
		local plinth = false
		for _, child in ipairs(model:GetChildren()) do
			if child.Name == "Foundation" and child:IsA("BasePart") then
				plinth = true
			end
		end
		note(string.format("team %d (%s): %d parts, floor at %.2f, %s; %d pads, %d of %d chest spots with a chest, %d of %d bays with a vehicle; ZFight.Scan %d pairs; ground: %d of %d slabs/panels floating",
			team, ruin.model.Name, parts, ruin.height, plinth and "ON A PLINTH" or "flush on levelled ground",
			#ruin.pads, chestsOn, #ruin.chestSpots, vehiclesIn, #ruin.vehicleBays, #pairsFound, floating, examined))
		for index, pair in ipairs(pairsFound) do
			if index > 6 then
				break
			end
			note(string.format("  zfight %s / %s gap %.3f", pair.a:GetFullName(), pair.b.Name, pair.gap))
		end
	end

	-- Planted: a slab lifted a stud off the ground must be reported floating.
	local sample = nil
	for _, part in ipairs(state.ruins[1].model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Paving" then
			sample = part
			break
		end
	end
	if sample then
		local copy = sample:Clone()
		copy.CFrame = sample.CFrame + Vector3.new(0, 1, 0)
		copy.Parent = workspace
		local floating = groundGaps({ copy })
		note("planted: a paving slab lifted 1 stud reads " .. (floating == 1 and "FLOATING (caught)" or "grounded (MISSED)"))
		copy:Destroy()
	end

	-- A vehicle for the ramp views: the biggest of team 1's, copied.
	local biggest, biggestSize = nil, 0
	for _, vehicle in ipairs(folder and folder:GetChildren() or {}) do
		if vehicle:IsA("Model") then
			local _, size = vehicle:GetBoundingBox()
			if size.X * size.Z > biggestSize then
				biggest, biggestSize = vehicle, size.X * size.Z
			end
		end
	end
	state.vehicle = biggest
	state.ready = true
end

-- A copy of the biggest base vehicle stood on team 1's ground at local (x, z), nose along `dir`,
-- pitched to the ground's grade there.
local function standVehicle(x, z, dir)
	if state.shown then
		state.shown:Destroy()
		state.shown = nil
	end
	if not state.vehicle then
		return
	end
	local copy = state.vehicle:Clone()
	local pivot = copy:GetPivot()
	local box, size = copy:GetBoundingBox()
	local drop = pivot.Position.Y - (box.Position.Y - size.Y / 2)
	local ahead, behind = Vector3.new(x, 0, z) + dir * 5, Vector3.new(x, 0, z) - dir * 5
	local g1, g2 = groundLocal(1, ahead.X, ahead.Z), groundLocal(1, behind.X, behind.Z)
	local mid = at(1, x, 0, z)
	local y = ((g1 or 0) + (g2 or 0)) / 2
	local worldDir = (at(1, ahead.X, 0, ahead.Z) - at(1, behind.X, 0, behind.Z)) * Vector3.new(1, 0, 1)
	local rise = (g1 or 0) - (g2 or 0)
	local forward = (worldDir + Vector3.new(0, rise, 0)).Unit
	copy:PivotTo(CFrame.lookAt(Vector3.new(mid.X, y + drop + 0.1, mid.Z), Vector3.new(mid.X, y + drop + 0.1, mid.Z) + forward))
	copy.Parent = workspace
	state.shown = copy
end

-- An eye-level view from outside team 1's compound: the camera 5.2 over the ground at local (x, z),
-- looking at local (tx, ty over the floor, tz).
local function outside(name, x, z, tx, ty, tz, fov)
	return {
		name = name,
		settle = 3,
		setup = function(_, camera)
			setup()
			Lighting.ClockTime = 14.5
			local g = groundLocal(1, x, z) or state.ruins[1].height
			local from = at(1, x, 0, z)
			look(camera, Vector3.new(from.X, g + 5.2, from.Z), at(1, tx, ty, tz), fov or 65)
		end,
	}
end

local views = {
	{
		name = "01_overview_team1",
		settle = 4,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 125, 115, -175), at(1, 0, 0, 0), 55)
		end,
	},
	{
		name = "02_overview_team2_same_compound",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(2, 125, 115, -175), at(2, 0, 0, 0), 55)
		end,
	},
	outside("03_front_from_the_arena_eye_level", 5, -135, 5, 7, 0),
	outside("04_east_side_eye_level", 140, -5, 0, 7, 0),
	outside("05_back_eye_level", -5, 130, 0, 7, 0),
	outside("06_west_side_eye_level", -140, 5, 0, 7, 0),
	{
		name = "07_main_gate_ramp_with_a_vehicle",
		settle = 3,
		setup = function(_, camera)
			setup()
			standVehicle(25.5, -78, Vector3.new(0, 0, -1))
			local g = groundLocal(1, 75, -140) or state.ruins[1].height
			local from = at(1, 75, 0, -140)
			look(camera, Vector3.new(from.X, g + 18, from.Z), at(1, 30, 4, -60), 65)
		end,
	},
	{
		name = "08_east_gate_ramp_with_a_vehicle",
		settle = 3,
		setup = function(_, camera)
			setup()
			standVehicle(92, 29, Vector3.new(1, 0, 0))
			local g = groundLocal(1, 150, 75) or state.ruins[1].height
			local from = at(1, 150, 0, 75)
			look(camera, Vector3.new(from.X, g + 18, from.Z), at(1, 72, 4, 29), 65)
		end,
	},
	{
		name = "09_the_ground_round_it_from_high",
		settle = 3,
		setup = function(_, camera)
			setup()
			if state.shown then
				state.shown:Destroy()
				state.shown = nil
			end
			look(camera, at(1, 200, 165, 170), at(1, 0, 0, 0), 55)
		end,
	},
	{
		name = "10_team2_front_eye_level",
		settle = 3,
		setup = function(_, camera)
			setup()
			local p = at(2, 5, 0, -135)
			local g = groundAt(p.X, p.Z) or state.ruins[2].height
			look(camera, Vector3.new(p.X, g + 5.2, p.Z), at(2, 5, 7, 0), 65)
		end,
	},
	{
		name = "11_spawn_shelter",
		settle = 3,
		setup = function(_, camera)
			setup()
			-- Inside the east end of the spawn hall, head height, across the 28 pads.
			look(camera, at(1, -11, 7.5, 27.5), at(1, -52, 1.5, 47), 75)
		end,
	},
	{
		name = "12_vehicle_yard",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 2, 15, -4), at(1, 38, 1, -40), 72)
		end,
	},
	{
		name = "13_supply_room",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 14, 6.5, 11), at(1, 14, 2.5, 46), 75)
		end,
	},
	{
		name = "14_courtyard_from_the_tower",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, -60, 12.8, -48.8), at(1, -28, 1, -4), 72)
		end,
	},
	{
		name = "15_dusk_lamps",
		settle = 4,
		setup = function(_, camera)
			setup()
			Lighting.ClockTime = 19.4
			look(camera, at(1, -10, 42, -110), at(1, 0, 0, 5), 60)
		end,
	},
	{
		name = "16_gatehouse_from_outside",
		settle = 3,
		setup = function(_, camera)
			setup()
			local g = groundLocal(1, 18, -100) or state.ruins[1].height
			local from = at(1, 18, 0, -100)
			look(camera, Vector3.new(from.X, g + 5.2, from.Z), at(1, 33, 13, -54), 65)
		end,
	},
	{
		name = "17_spawn_hall_facade",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, -26, 7, -8), at(1, -40, 8, 24), 70)
		end,
	},
}

-- Each base's access road to the map's roads, from high over its middle.
for team = 1, 2 do
	table.insert(views, {
		name = string.format("%d_access_road_team%d", 17 + team, team),
		settle = 3,
		setup = function(_, camera)
			setup()
			local ruin = state.ruins[team]
			local plan = ruin and ruin.accessPlan
			if not plan then
				note(string.format("team %d: NO ACCESS ROAD (%s)", team, tostring(ruin and ruin.accessWhy)))
				look(camera, at(team, 0, 160, 120), at(team, 0, 0, -60), 60)
				return
			end
			local first, last = plan.points[1], plan.points[#plan.points]
			local mid = (first + last) / 2
			local span = (last - first).Magnitude
			note(string.format("team %d: access road %.0f studs, %d stretches, gate %d", team, plan.length, #plan.points - 1, plan.gate or 1))
			local road = ruin.accessRoad
			local slabs, first = 0, nil
			for _, p in ipairs(road and road:GetDescendants() or {}) do
				if p.Name == "RoadSurface" then
					slabs += 1
					first = first or p
				end
			end
			note(string.format("team %d: road model %s parent %s, %d slabs%s", team, tostring(road), tostring(road and road.Parent),
				slabs, first and string.format(", first top %.1f at (%.0f, %.0f), ground ray %s", first.Position.Y + first.Size.Y / 2,
				first.Position.X, first.Position.Z, tostring(groundAt(first.Position.X, first.Position.Z))) or ""))
			local base = ruin.frame.Position
			local away = Vector3.new(mid.X - base.X, 0, mid.Z - base.Z)
			away = away.Magnitude > 1 and away.Unit or Vector3.new(0, 0, 1)
			local side = Vector3.new(-away.Z, 0, away.X)
			local centre = Vector3.new(mid.X, ruin.height, mid.Z)
			look(camera, centre + side * (span * 0.6 + 80) + Vector3.new(0, span * 0.55 + 90, 0) - away * 40, centre, 60)
		end,
	})
end

return views
