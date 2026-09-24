-- The battleground in the middle of a team match (TeamBattleground), built the way a match builds it and
-- photographed.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/team_battleground_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Oliver, 2026-09-24: "make a way better quality and more fun to play around battleground in the centre
-- of the maps for the team gamemodes". tools/team_battleground_check.py has measured the layout offline
-- (mirror symmetry, nothing floating, walkable from both bases with no traps, every power position two
-- ways up, lane sightlines, cover spacing, objectives, vehicle routes, loot, ziplines, z-fighting) and
-- tools/team_battleground_modeteams_check.py the wiring. What neither can say is how it LOOKS, or how it
-- sits in a real town once the town has been cleared off the site. This builds a real map (RotRidge,
-- the roughest ground of the five, and the one tools/team_base_ruins_gallery.lua uses), runs the real
-- ModeTeams.Setup for a Team Deathmatch (bases, then the battleground: site clearing, FlattenPad, the
-- ziplines, the loot), then frames each part of it.
--
-- The notes are the probe: parts, the height it stands at, whether the ground was levelled, ZFight.Scan
-- over the placed model (terrain pairs included, which the offline check cannot see), the ground under
-- every paving slab by raycast (a slab whose underside is above the terrain is floating; want 0), map
-- things the clearing left standing inside the site (want 0), ziplines hung (want 4), loot standing on
-- its spots, each objective's floor (a ray down from it must land on the battleground within half a
-- stud) and its distance to each base (want equal), and whether BotNav has its cover hints. Planted: a
-- paving slab lifted 1 stud must read floating.
--
-- Views: 01 overview from team 1's side, 02 the whole thing from high in the west, 03-05 the three lanes
-- at eye level from team 1's end (centre through the forecourt, west to the pit, east down the
-- container lane), 06 the keep's gallery looking down into the hall, 06b off the keep top towards team
-- 1, 07 objective A on the rot-eye mosaic, 08 objective B at the pit's fountain, 09 the market, 10 the
-- bridge to the gantry, 11 the keep at dusk with its braziers lit.

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

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.IgnoreWater = true

local function terrainUnder(position)
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(position + Vector3.new(0, 50, 0), Vector3.new(0, -200, 0), terrainParams)
	return hit and hit.Position.Y or nil
end

-- Slabs that should be sitting on the levelled ground: how many have their underside clear of the
-- terrain at any corner (floating) or no terrain under them at all.
local function groundGaps(parts)
	local floating = 0
	for _, part in ipairs(parts) do
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
	return floating
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
			if part.Name == "Paving" and part.Position.Y - part.Size.Y / 2 < field.height + 0.5 then
				table.insert(paving, part)
			end
		end
	end
	local flat = field.frame.Position
	local levelled = math.abs((terrainUnder(flat + Vector3.new(30, 0, 30)) or -999) - field.height) < 0.6
	note(string.format("battleground: %d parts, floor at %.2f, ground %s", parts, field.height,
		levelled and "levelled" or "NOT LEVELLED (built on it as it stands)"))

	local pairsFound = ZFight.Scan({ model })
	note(string.format("ZFight.Scan over the placed model: %d pairs", #pairsFound))
	for index, pair in ipairs(pairsFound) do
		if index > 8 then
			break
		end
		note(string.format("  zfight %s / %s gap %.3f", pair.a:GetFullName(), pair.b.Name, pair.gap))
	end
	note(string.format("ground: %d of %d paving slabs floating", groundGaps(paving), #paving))

	-- The clearing: anything of the map's own (not terrain, not the bases, not this) left standing on
	-- the site above the floor.
	local leftovers = {}
	local map = info.map
	for _, part in ipairs(map:GetDescendants()) do
		if part:IsA("BasePart") and not part:IsDescendantOf(model) and not part:GetAttribute("TeamBaseRuin")
			and part.Transparency < 1 and part.CanCollide then
			local offset = part.Position - flat
			if Vector3.new(offset.X, 0, offset.Z).Magnitude < TeamBattleground.Radius
				and part.Position.Y + part.Size.Y / 2 > field.height + 0.3 then
				table.insert(leftovers, part)
			end
		end
	end
	note(string.format("clearing: %d map parts left standing inside the site", #leftovers))
	for index, part in ipairs(leftovers) do
		if index > 8 then
			break
		end
		note("  left " .. part:GetFullName())
	end

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

	-- Planted: a paving slab lifted a stud off the ground must be reported floating.
	if paving[1] then
		local copy = paving[1]:Clone()
		copy.CFrame = paving[1].CFrame + Vector3.new(0, 1, 0)
		copy.Parent = workspace
		note("planted: a paving slab lifted 1 stud reads " .. (groundGaps({ copy }) == 1 and "FLOATING (caught)" or "grounded (MISSED)"))
		copy:Destroy()
	end
	state.ready = true
end

local function view(name, from, target, fov, extra)
	return {
		name = name,
		settle = 3,
		setup = function(_, camera)
			setup()
			if extra then
				extra()
			end
			look(camera, at(from[1], from[2], from[3]), at(target[1], target[2], target[3]), fov)
		end,
	}
end

local views = {
	view("01_overview_from_team1", { 0, 110, -190 }, { 0, 0, -10 }, 55),
	view("02_overview_high_west", { -200, 140, -40 }, { -10, 0, 0 }, 55),
	-- Eye level (5.2 above the floor, an R15's eyes) from team 1's end of each lane.
	view("03_centre_lane_eye_level", { 0, 5.2, -118 }, { 0, 5, 0 }, 70),
	view("04_west_lane_to_the_pit_eye_level", { -62, 5.2, -108 }, { -80, 4, 0 }, 70),
	view("05_east_container_lane_eye_level", { 70, 5.2, -112 }, { 84, 5, -20 }, 70),
	view("06_keep_gallery_into_the_hall", { -15, 16.2, -16 }, { 10, 9, 8 }, 70),
	view("06b_keep_top_towards_team1", { 0, 16.2, -13 }, { 0, 2, -80 }, 75),
	view("07_objective_A_rot_eye", { 14, 5.5, -14 }, { -4, 3, 4 }, 75),
	view("08_objective_B_pit_fountain", { -60, 12, -24 }, { -86, 1, 2 }, 70),
	view("09_market_eye_level", { 50, 5.2, -70 }, { 48, 4, -10 }, 70),
	view("10_bridge_to_the_gantry", { 32, 16, -1 }, { 104, 11, 0 }, 65),
	view("11_keep_at_dusk", { -30, 34, -80 }, { 0, 6, 0 }, 60, function()
		Lighting.ClockTime = 19.4
	end),
}

return views
