-- The team-base compounds (TeamBaseRuins), built the way a team match builds them and photographed.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/team_base_ruins_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Oliver, 2026-09-24: "design a ruined base with very high quality for both team spawns so that all the
-- item chests and cars aren't just sitting in random fields". tools/team_base_ruins_check.py has
-- measured the geometry offline (no coplanar faces, nothing floating, walkable, bays level and clear,
-- both bases identical); what it cannot say is how the thing LOOKS, or how it sits on a real map's
-- ground. This builds a real map (RotRidge, the roughest ground of the five), runs the real
-- ModeTeams.Setup for a Team Deathmatch (so the site choice, the terrain levelling, the site clearing,
-- the base vehicles in their bays), seeds each base's chests through the real ModeTeams.BaseLootSpots
-- and LootService.SeedAt, and then frames each part of the compound.
--
-- The notes are the probe. Per base: parts, the height it stands at, whether it fell back to a plinth,
-- pads, chests actually standing on the named chest spots, vehicles actually in the bays, ZFight.Scan
-- over the placed model (terrain pairs included, which the offline check cannot see), and the ground
-- under every paving slab and wall panel read by raycast: a slab whose underside is above the terrain
-- is floating, and the count must be 0. Planted: the same ground test run on a slab lifted 1 stud must
-- report it.
--
-- Views: 01 overview (team 1), 02 the other base (team 2, same compound turned), 03 the front at eye
-- level from the arena, 04 the spawn shelter, 05 the collapsed corner, 06 the vehicle yard (six bays), 06b the east gate from outside, 07 the
-- supply room, 08 the courtyard from the watchtower, 09 the compound at dusk with its lamps lit.

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

local function terrainUnder(position)
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(position + Vector3.new(0, 50, 0), Vector3.new(0, -200, 0), terrainParams)
	return hit and hit.Position.Y or nil
end

-- Slabs and panels that should be sitting in the ground: how many have their underside clear of the
-- terrain at any corner (floating) or no terrain at all under them.
local function groundGaps(parts)
	local floating, examined = 0, 0
	for _, part in ipairs(parts) do
		examined += 1
		local half = part.Size / 2
		for _, corner in ipairs({ Vector3.new(1, -1, 1), Vector3.new(-1, -1, 1), Vector3.new(1, -1, -1), Vector3.new(-1, -1, -1) }) do
			local point = part.CFrame * (half * corner * Vector3.new(0.95, 1, 0.95))
			local ground = terrainUnder(point)
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
		local spots = ModeTeams.BaseLootSpots(team, 8, 20, 80, 14)
		LootService.SeedAt(spots, "chest")
		local weapons = ModeTeams.BaseLootSpots(team, 16, 10, 80, 6)
		LootService.SeedAt(weapons, "weapon")
	end
	task.wait(0.5)

	local loot = workspace:FindFirstChild("Loot")
	for team = 1, 2 do
		local ruin = state.ruins[team]
		local model = ruin.model
		local parts = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				parts += 1
			end
		end
		local plinth = false
		for _, child in ipairs(model:GetChildren()) do
			if child.Name == "Foundation" and child:IsA("BasePart") then
				plinth = true
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
		local folder = ModeTeams.BaseVehicleFolder()
		for _, bay in ipairs(ruin.vehicleBays) do
			for _, vehicle in ipairs(folder and folder:GetChildren() or {}) do
				if vehicle:IsA("Model") and (vehicle:GetPivot().Position * Vector3.new(1, 0, 1) - bay.Position * Vector3.new(1, 0, 1)).Magnitude < 1 then
					vehiclesIn += 1
					break
				end
			end
		end
		local pairsFound = ZFight.Scan({ model })
		local floating, examined = groundGaps(grounded(model, ruin.height))
		note(string.format("team %d (%s): %d parts, floor at %.2f, %s; %d pads, %d of %d chest spots with a chest, %d of %d bays with a vehicle; ZFight.Scan %d pairs; ground: %d of %d slabs/panels floating",
			team, ruin.model.Name, parts, ruin.height, plinth and "ON A PLINTH (ground not levelled)" or "on levelled ground",
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
		if part.Name == "Paving" then
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
	state.ready = true
end

local views = {
	{
		name = "01_overview_team1",
		settle = 4,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 70, 70, -95), at(1, 0, 0, 0), 55)
		end,
	},
	{
		name = "02_overview_team2_same_compound",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(2, 70, 70, -95), at(2, 0, 0, 0), 55)
		end,
	},
	{
		name = "03_front_from_the_arena_eye_level",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 10, 5.5, -95), at(1, 0, 5, 0), 60)
		end,
	},
	{
		name = "04_spawn_shelter",
		settle = 3,
		setup = function(_, camera)
			setup()
			-- Just inside the west door, head height, across the two rows of pads.
			look(camera, at(1, -31, 5.8, 12), at(1, -12, 3, 32), 70)
		end,
	},
	{
		name = "05_collapsed_corner",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, -12, 6, 26), at(1, 0, 3, 13), 65)
		end,
	},
	{
		name = "06_vehicle_yard",
		settle = 3,
		setup = function(_, camera)
			setup()
			-- From above the workbench corner, over both rows of parked vehicles: the back row (bays
			-- 4-6) facing the east gate, the front row (1-3) facing the main gate.
			look(camera, at(1, 8, 14, 18), at(1, 30, 1, -16), 70)
		end,
	},
	{
		name = "06b_east_gate_from_outside",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 78, 6, 4), at(1, 32, 3, 4), 60)
		end,
	},
	{
		name = "07_supply_room",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, 23.5, 6.5, 25), at(1, 24, 2, 38), 75)
		end,
	},
	{
		name = "08_courtyard_from_the_tower",
		settle = 3,
		setup = function(_, camera)
			setup()
			look(camera, at(1, -39, 10.5, -35), at(1, -14, 1, -8), 70)
		end,
	},
	{
		name = "09_dusk_lamps",
		settle = 4,
		setup = function(_, camera)
			setup()
			Lighting.ClockTime = 19.4
			look(camera, at(1, -10, 30, -70), at(1, 0, 0, 5), 60)
		end,
	},
}

return views
