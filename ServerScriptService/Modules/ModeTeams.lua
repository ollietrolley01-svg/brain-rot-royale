-- Teams, spawn pads, respawning, the spawn loadout, friendly fire and spawn protection.
--
-- Shared by Team Deathmatch and King of the Hill. Knows nothing about either one's scoreline.
--
-- Nothing in here runs unless a respawn mode is the current mode: GameMode calls Setup at match
-- start and Teardown at match end, and everything below is inert in between.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local MapTerrain = require(script.Parent:WaitForChild("MapTerrain"))
local TeamBaseRuins = require(script.Parent:WaitForChild("TeamBaseRuins"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local ModeTeams = {}

--------------------------------------------------------------------------------
-- The green gun pool
--------------------------------------------------------------------------------

-- Built at run time from WeaponData.Weapons, never hardcoded: the arsenal packs register
-- themselves into that table, so the count moves whenever a pack lands. `PoolSize` is printed by
-- the loadout probe and an empty pool is a hard failure, not a silent empty-handed spawn.
local greenPool = {}

local function buildGreenPool()
	table.clear(greenPool)
	for id, def in pairs(WeaponData.Weapons) do
		if def.rarity == GameModes.GreenRarity then
			table.insert(greenPool, { id = id, weight = math.max(def.groundWeight or 0, 1) })
		end
	end
	-- Sorted so the pool is the same order on every server: an unsorted pairs() walk would make
	-- a seeded roll unreproducible between runs and the probe's distribution meaningless.
	table.sort(greenPool, function(a, b)
		return a.id < b.id
	end)
	return #greenPool
end

buildGreenPool()

function ModeTeams.PoolSize()
	return #greenPool
end

function ModeTeams.PoolIds()
	local list = {}
	for _, entry in ipairs(greenPool) do
		table.insert(list, entry.id)
	end
	return list
end

-- One green gun, weighted by how common it is on the ground.
function ModeTeams.RollGreenWeapon()
	if #greenPool == 0 and buildGreenPool() == 0 then
		return nil
	end
	local total = 0
	for _, entry in ipairs(greenPool) do
		total += entry.weight
	end
	local roll = math.random() * total
	local cumulative = 0
	for _, entry in ipairs(greenPool) do
		cumulative += entry.weight
		if roll <= cumulative then
			return entry.id
		end
	end
	return greenPool[#greenPool].id
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local active = false
local mode = nil
local arenaCentre = Vector3.zero
local arenaRadius = 0
local pads = { {}, {} }
-- Each team's base point (the centre its pads were looked for around), for the base loot.
local bases = {}
-- Each team's compound in a team match (TeamBaseRuins.Build's result), or nothing when it was not
-- built and the pads are the open-ground ones.
local ruins = {}

-- token -> 1 or 2
local teamOf = {}
-- token -> the WALL-CLOCK millisecond at which spawn protection ends.
--
-- NOT os.clock(). os.clock() is process CPU TIME in Roblox, not elapsed time, so a deadline stored
-- with it runs for `seconds / cpuRatio` real seconds -- measured at 0.4 under load in this project,
-- which turns 3 seconds of spawn protection into about 7.5 of a player nobody can kill. The same
-- mistake also made the expiry safety net unable to fire: see grantProtection.
local protectedUntil = {}

-- One clock, used for the deadline AND for every test of it. Sub-second, because the window is 3 s.
local function protectionNowMs()
	return DateTime.now().UnixTimestampMillis
end
-- token -> true while dead and waiting to come back
local downed = {}
-- Which team the next joiner goes to, so an odd number of late joiners still balances.
local nextTeam = 1

function ModeTeams.IsActive()
	return active
end

function ModeTeams.TeamOf(token)
	return teamOf[token]
end

function ModeTeams.IsDowned(token)
	return downed[token] == true
end

function ModeTeams.Arena()
	return arenaCentre, arenaRadius
end

function ModeTeams.Counts()
	local counts = { 0, 0 }
	for _, index in pairs(teamOf) do
		counts[index] = (counts[index] or 0) + 1
	end
	return counts
end

--------------------------------------------------------------------------------
-- Ground
--------------------------------------------------------------------------------

-- The terrain surface at a point, or nil where there is none. Two things here are deliberate and
-- have both cost this project real bugs: the ray starts at y = 2000 because a ray never reports
-- terrain it STARTS inside, and IgnoreWater is set explicitly because it defaults to FALSE — a
-- pad placed on a river surface reads as perfectly good ground otherwise.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.IgnoreWater = true

local function terrainAt(x, z)
	groundParams.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), groundParams)
	return hit and hit.Position.Y or nil
end

-- Anything solid standing in the 12 studs above a pad: a building, a wall, a parked car. A bounds
-- query answers for a part's QUERY SHAPE rather than its silhouette, so this over-reports — which
-- is the right way round here, because there are far more candidate pads than we need and
-- refusing a good one costs nothing.
local occupyParams = OverlapParams.new()
occupyParams.FilterType = Enum.RaycastFilterType.Exclude
occupyParams.RespectCanCollide = true

local function blocked(position)
	occupyParams.FilterDescendantsInstances = { workspace.Terrain }
	local parts = workspace:GetPartBoundsInBox(CFrame.new(position + Vector3.new(0, 6, 0)), Vector3.new(8, 12, 8), occupyParams)
	for _, part in ipairs(parts) do
		if part.CanCollide then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

-- Oliver 09-22 15:33: "spawn a little further apart" and "play areas a little larger". 8 pads (was 5),
-- spread over 60 studs (was 30), players kept 20 apart when they land (SPAWN_CLEARANCE, was 14), and the
-- arena 0.72 of the map radius clamped 650..950 (was 0.62, 560..820).
local PADS_PER_TEAM = 8
local BASE_FRACTION = 0.72
-- Where a team's pads are looked for around its base. The first number is the original
-- spacing; the rest are only reached when that pass finds nothing at all.
local PAD_SPREADS = { 60, 110, 180 }

-- The arena: a disc centred on town 1. MapGenerator's placeTowns puts town index 1 at distance 0
-- (plus a +/-40 jitter) on every map and every seed, so it is the one stable anchor there is, and
-- it is the ground the battle royale's last circle already lands on.
function ModeTeams.Setup(currentMode, mapInfo)
	ModeTeams.Teardown()
	mode = currentMode
	active = true
	nextTeam = 1

	local dropSpots = mapInfo and mapInfo.dropSpots
	arenaCentre = (dropSpots and dropSpots[1]) or Vector3.zero
	arenaCentre = Vector3.new(arenaCentre.X, 0, arenaCentre.Z)
	-- 0.62 of the map's radius, between 560 and 820 (Oliver's #121, "bigger maps on every
	-- gamemode"; claude-43 approved 09-21 22:4x).
	--
	-- It was 0.30 clamped to 280..380, then 0.50 clamped to 450..650 -- and the comment that came
	-- with 0.50 claimed it left "room for the towns on the first ring as well as the centre one".
	-- MEASURED ACROSS ALL FIVE MAPS, that was wrong: at 0.50 there is EXACTLY ONE town inside the
	-- arena on every map, because placeTowns puts the first ring 543..1160 studs from the centre
	-- town while the arena reached only 450..650. The clamp was also doing the deciding on two
	-- maps rather than the map itself -- BombardiroBay (radius 1480) was pinned at 650, giving the
	-- BIGGEST map the proportionally SMALLEST arena at 0.439 R, while RotRidge (880) was pushed up
	-- to 450 from 440.
	--
	-- 0.62 with a 560..820 clamp is +24% radius and +54% area, uniform across all five, and it
	-- unsticks both clamped maps. The cost is traversal, not build time: the arena is only a
	-- boundary circle drawn over a map that is already built at full size, so this is free. Bases
	-- sit BASE_FRACTION apart, so the longest crossing (BombardiroBay) goes 936 -> 1181 studs,
	-- about 52 s -> 66 s at MatchConfig.BaseWalkSpeed, which is a respawn mode's to absorb.
	-- Oliver 09-24 (#5): "slightly" smaller than 0.72 / 650..950: about 8% less radius, 16% less area.
	arenaRadius = math.clamp((mapInfo and mapInfo.radius or 900) * 0.66, 600, 875)

	-- Two bases on opposite sides of the centre, on an axis rolled per match so the same map does
	-- not always play along the same street.
	local axis = math.random() * math.pi * 2
	local fraction = BASE_FRACTION
	ModeTeams.MapRiver = mapInfo and mapInfo.river

	-- In a team match each base is a ruined compound (TeamBaseRuins; Oliver 2026-09-24: "so that all
	-- the item chests and cars aren't just sitting in random fields"), both built from one seed so
	-- they are the same compound turned to face the middle. The axis may be turned to find ground the
	-- compounds can stand on. If either cannot be built, neither is: one side in a fort and the other
	-- in a field is not a fair start, so both fall back to the open-ground pads.
	local withRuins = TeamBaseRuins ~= nil and currentMode ~= nil and currentMode.teams == true
		and mapInfo ~= nil and mapInfo.map ~= nil
	if withRuins then
		axis, fraction = ModeTeams.PickBaseAxis(axis, mapInfo)
	end
	local ruinSeed = withRuins and math.random(1, 2147483646) or nil
	for team = 1, GameModes.TeamCount do
		local heading = axis + (team - 1) * math.pi
		bases[team] = arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * fraction)
		if withRuins then
			ModeTeams.BuildRuin(team, bases[team], mapInfo, ruinSeed)
		end
	end
	if withRuins and not (ruins[1] and ruins[2]) then
		ModeTeams.ClearRuins()
	end
	for team = 1, GameModes.TeamCount do
		local ruin = ruins[team]
		if ruin then
			pads[team] = {}
			for _, pad in ipairs(ruin.pads) do
				table.insert(pads[team], pad.Position)
			end
		else
			pads[team] = ModeTeams.BuildPads(bases[team], mapInfo)
		end
	end
	if ruins[1] and ruins[2] then
		ModeTeams.BaseVehicleBays = ModeTeams.RuinBays
	end

	-- After the pads (it keeps clear of them) and before GameMode seeds the base loot, which then
	-- keeps clear of the vehicles through RefusePad's blocked test. A failure here costs the base its
	-- vehicles, never the match its start.
	if currentMode and currentMode.teams then
		local ok, problem = pcall(ModeTeams.SpawnBaseVehicles, mapInfo)
		if not ok then
			warn("ModeTeams: base vehicles failed: " .. tostring(problem))
		end
	end

	return arenaCentre, arenaRadius, #pads[1], #pads[2]
end

-- Candidate pads around a base point, each one validated. Public so the spawn probe can call it
-- against a built map and count what it accepted and refused.
--
-- WIDENS WHEN IT COMES UP EMPTY. A base that lands in a town, on a road or in woodland can have all
-- 60 of its candidates refused inside the first spread, and an empty list is the one case the
-- placer has no good answer for. Each pass reaches further before giving up, so "no pads" means the
-- arena really has nowhere to stand rather than the first 30 studs being busy. (Measured: 0 of 120
-- team-arenas across five maps and twelve axes came up empty even before this, so the widening is
-- insurance, not a fix for anything seen.)
function ModeTeams.BuildPads(base, mapInfo)
	local list = {}
	local river = mapInfo and mapInfo.river
	for pass = 1, #PAD_SPREADS do
		local spread = PAD_SPREADS[pass]
		for attempt = 1, PADS_PER_TEAM * 12 do
			if #list >= PADS_PER_TEAM then
				break
			end
			-- The first candidate is the base itself, so a clean base always yields at least one pad.
			local x, z = base.X, base.Z
			if attempt > 1 or pass > 1 then
				local angle = math.random() * math.pi * 2
				local reach = math.sqrt(math.random()) * spread
				x, z = base.X + math.cos(angle) * reach, base.Z + math.sin(angle) * reach
			end

			local refusal = ModeTeams.RefusePad(x, z, river)
			if not refusal then
				table.insert(list, Vector3.new(x, terrainAt(x, z) or 0, z))
			end
		end
		if #list > 0 then
			break
		end
	end
	return list
end

-- Why a pad at (x, z) cannot be used, or nil if it can. Split out so the probe can plant a fault
-- and watch each rule fire.
function ModeTeams.RefusePad(x, z, river)
	local flat = Vector3.new(x, 0, z)
	if (flat - arenaCentre).Magnitude > arenaRadius - 40 then
		return "outside the arena"
	end
	local ground = terrainAt(x, z)
	-- "No ground where I expect ground" fails here and now rather than spawning someone into the
	-- void and waiting out a timeout.
	if not ground then
		return "no ground"
	end
	if MapTerrain.InRiver(river, x, z, 14) then
		return "in the river"
	end
	if blocked(Vector3.new(x, ground, z)) then
		return "blocked"
	end
	return nil
end

-- The team's base point, or nil outside a team match.
function ModeTeams.BaseOf(team)
	return active and bases[team] or nil
end

--------------------------------------------------------------------------------
-- The compounds (TeamBaseRuins)
--------------------------------------------------------------------------------

-- Other axes tried when the rolled one puts a compound on a road, in the river or over a town (8
-- more, every 22.5 degrees, since the two bases are opposite), at the usual distance and a little
-- nearer the middle. The rolled axis wins any tie, so the base still moves about from match to match.
local RUIN_AXES = 8
local RUIN_FRACTIONS = { BASE_FRACTION, 0.64 }
-- A chest or pickup lying within this of a compound's spot means the spot is taken.
local RUIN_SPOT_TAKEN = 3
-- GameMode asks for chests with this gap (and nothing else with it). Read as "chest" only when the
-- caller does not name the kind; see BaseLootSpots.
local RUIN_CHEST_GAP = 14

-- The flat frame a compound is built in at `base`: on the ground, facing the arena centre.
local function ruinFrame(base)
	local ground = terrainAt(base.X, base.Z) or 0
	local at = Vector3.new(base.X, ground, base.Z)
	return CFrame.lookAt(at, Vector3.new(arenaCentre.X, ground, arenaCentre.Z))
end

-- The axis (and distance from the centre, as a fraction of the arena's radius) whose two sites suit
-- a compound best, starting from the rolled `axis`. Returns the rolled axis unchanged when no pair
-- of sites is usable at all; Build then stands the compounds on plinths.
function ModeTeams.PickBaseAxis(axis, mapInfo)
	local best, bestFraction, bestCost = axis, BASE_FRACTION, math.huge
	for step = 0, RUIN_AXES - 1 do
		local candidate = axis + step * math.pi / RUIN_AXES
		for _, fraction in ipairs(RUIN_FRACTIONS) do
			local total = step * 0.01 + (fraction == BASE_FRACTION and 0 or 0.5)
			for team = 1, GameModes.TeamCount do
				local heading = candidate + (team - 1) * math.pi
				local base = arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * fraction)
				local cost = TeamBaseRuins.SiteCost(ruinFrame(base), mapInfo)
				total = cost and total + cost or math.huge
			end
			if total < bestCost then
				best, bestFraction, bestCost = candidate, fraction, total
			end
		end
		-- Flat, clear ground on the rolled axis (or near it) is as good as it gets.
		if bestCost < 4 then
			break
		end
	end
	return best, bestFraction
end

-- Builds `team`'s compound at `base`. Returns it, or nil (warned) when it could not be built.
function ModeTeams.BuildRuin(team, base, mapInfo, seed)
	local ok, ruin = pcall(TeamBaseRuins.Build, ruinFrame(base), GameModes.TeamColor(team), mapInfo, seed)
	if not ok or type(ruin) ~= "table" or #ruin.pads == 0 then
		warn("ModeTeams: team " .. team .. "'s base was not built: " .. tostring(ok and "no pads" or ruin))
		if ok and type(ruin) == "table" and ruin.model then
			ruin.model:Destroy()
		end
		return nil
	end
	ruin.model.Name = "TeamBase" .. team
	ruins[team] = ruin
	return ruin
end

-- Takes both compounds down (a match ending, or one side failing to build).
function ModeTeams.ClearRuins()
	for team, ruin in pairs(ruins) do
		if ruin.model then
			ruin.model:Destroy()
		end
		ruins[team] = nil
	end
end

-- The team's compound (model, pads, chestSpots, vehicleBays, lootSpots), or nil.
function ModeTeams.BaseRuin(team)
	return ruins[team]
end

-- ModeTeams.BaseVehicleBays while the compounds stand: each compound's named bays.
function ModeTeams.RuinBays(team)
	local ruin = ruins[team]
	return ruin and ruin.vehicleBays or {}
end

-- The first `count` of `list` (CFrames) with no chest or pickup already lying on them, as positions.
local function freeRuinSpots(list, count)
	local loot = workspace:FindFirstChild("Loot")
	local out = {}
	for _, spot in ipairs(list) do
		if #out >= count then
			break
		end
		local at = spot.Position
		local taken = false
		if loot then
			for _, item in ipairs(loot:GetChildren()) do
				if item:IsA("BasePart") and Vector3.new(item.Position.X - at.X, 0, item.Position.Z - at.Z).Magnitude < RUIN_SPOT_TAKEN then
					taken = true
					break
				end
			end
		end
		if not taken then
			table.insert(out, at)
		end
	end
	return out
end

-- Where the base loot goes (Oliver, 2026-09-23: "way more loot around the spawns of the teams"). Up to
-- `count` open-ground spots between `inner` and `outer` studs from the team's base, each passing the
-- same checks a spawn pad does (inside the arena, real ground, not in the river, nothing built on it)
-- and kept `gap` studs apart so pickups never sit in one another.
--
-- With a compound standing, its own spots come first: chests ("chest" as `kind`) go ONLY in its named
-- chest spots, never out in the field, and other pickups fill its loot spots before the ground round
-- it. GameMode does not pass `kind` yet; until it does, the chest call is known by its gap
-- (RUIN_CHEST_GAP), which is the only one that asks for 14.
function ModeTeams.BaseLootSpots(team, count, inner, outer, gap, kind)
	local base = bases[team]
	if not active or not base then
		return {}
	end
	inner, outer, gap = inner or 12, outer or 80, gap or 6
	local spots = {}
	local ruin = ruins[team]
	if ruin then
		if kind == nil and gap >= RUIN_CHEST_GAP then
			kind = "chest"
		end
		spots = freeRuinSpots(kind == "chest" and ruin.chestSpots or ruin.lootSpots, count)
		if kind == "chest" then
			return spots
		end
	end
	for _ = 1, count * 10 do
		if #spots >= count then
			break
		end
		local angle = math.random() * math.pi * 2
		local reach = inner + math.sqrt(math.random()) * (outer - inner)
		local x, z = base.X + math.cos(angle) * reach, base.Z + math.sin(angle) * reach
		if not ModeTeams.RefusePad(x, z, ModeTeams.MapRiver) then
			local spot = Vector3.new(x, terrainAt(x, z) or 0, z)
			local clear = true
			-- Never on a spawn pad: a chest there would block the pad, and a gun there is grabbed
			-- by accident on every respawn.
			for _, pad in ipairs(pads[team] or {}) do
				if (Vector3.new(pad.X, 0, pad.Z) - Vector3.new(x, 0, z)).Magnitude < 7 then
					clear = false
					break
				end
			end
			for _, other in ipairs(spots) do
				if (other - spot).Magnitude < gap then
					clear = false
					break
				end
			end
			if clear then
				table.insert(spots, spot)
			end
		end
	end
	return spots
end

function ModeTeams.Teardown()
	ModeTeams.StopBaseVehicles()
	ModeTeams.ClearRuins()
	if ModeTeams.BaseVehicleBays == ModeTeams.RuinBays then
		ModeTeams.BaseVehicleBays = nil
	end
	active = false
	mode = nil
	table.clear(bases)
	table.clear(teamOf)
	table.clear(protectedUntil)
	table.clear(downed)
	pads = { {}, {} }
end

--------------------------------------------------------------------------------
-- BEGIN BASE VEHICLES
--------------------------------------------------------------------------------
-- Everything for the base vehicles is in this block, down to END BASE VEHICLES, apart from one
-- call in Setup and one in Teardown. tools/team_vehicles_check.py runs it.

local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))

-- Oliver, 2026-09-24: "make vehicles spawn near the spawns of the teams on team gamemodes". A few
-- vehicles parked at each base with their noses to the arena centre, so the way out of the base is
-- the way to the fight. They are EXTRA to the map's own parking: MapGenerator parks the town lots and
-- the verges in every mode, and that stays as it is. What holds, each checked by
-- tools/team_vehicles_check.py:
--   * both bases get the same models, rolled once per match: one base with the rocket pod and the
--     other with a scooter is not a fair start;
--   * every spot passes RefusePad (inside the arena with 40 to spare, real ground, not in the river,
--     nothing built there), its whole footprint is clear of anything solid, and it is level enough
--     that parkOn leaves the vehicle where it was put rather than stepping it aside;
--   * clear of every spawn pad, of the base's other vehicles and of any loot lying there;
--   * a wrecked one, or one lost off the map, is replaced after RespawnDelay while the match runs,
--     one per slot, so a base never holds more live vehicles than it has slots. A live one driven
--     away and left somewhere still counts: it is still in play.
-- Bots need nothing: VehicleWeapons.FreeArmedNear finds any armed vehicle by its tag.
--
-- BAYS. Whatever builds a base's structure (TeamBaseRuins, when it lands) can hand over named
-- vehicle bays by setting ModeTeams.BaseVehicleBays to a function (team, basePoint) -> list of
-- CFrames, each the centre of a bay on its floor with LookVector the way a parked nose should point.
-- It is asked every time a slot is parked (in Setup, after the pads, and on each replacement), so
-- bays built later still count. Free bays are filled first; with none, or all taken, the spots are
-- computed as below.
ModeTeams.BaseVehicleBays = nil

-- The biggest vehicle in the set plus a stud each side, as ParkInTowns assumes for a bay.
local BASE_VEHICLE_FOOTPRINT = Vector3.new(8.9, 1, 16.6)
local BASE_VEHICLE_TRIES = 80
-- A spot that cannot be found (the base is boxed in) is looked for again this often, not every tick.
local BASE_VEHICLE_RETRY_MS = 5000
-- A bay with a base vehicle standing this close to its centre is taken.
local BAY_TAKEN = 6
-- The box over a bay that must be empty of anything solid before a vehicle is put in it: the biggest
-- vehicle's footprint (Sahur Van 9.0 wide, Crocodilo Ranger 17.4 long, measured from VehicleModels by
-- tools/team_base_ruins_check.py) with half a stud all round, 8 high, from 0.6 over the floor. A car
-- put into a wreck, a driven-back car, a player or a deployable is two assemblies in one place, and
-- the physics shoves them apart into a pile (Oliver's playtest, 2026-09-24: "the vehicles in the team
-- bases are all messed up, like piled together").
local BAY_CLEAR = Vector3.new(10, 8, 18.5)
-- A vehicle put in a bay is held anchored this long, so nothing shoves it before it has settled.
local BAY_SETTLE_SECONDS = 1.5

local bayParams = OverlapParams.new()
bayParams.FilterType = Enum.RaycastFilterType.Exclude
bayParams.RespectCanCollide = true

-- Anything solid standing in the bay.
-- Critic C2: GetPartBoundsInBox matches world-aligned bounding boxes, so a wall turned to the
-- compound's yaw covered bays it never touched. Each hit is confirmed against its real box.
local function boxesOverlap(a, aSize, b, bSize)
	local axes = { a.RightVector, a.UpVector, a.LookVector, b.RightVector, b.UpVector, b.LookVector }
	for i = 1, 3 do
		for j = 4, 6 do
			local cross = axes[i]:Cross(axes[j])
			if cross.Magnitude > 1e-4 then
				table.insert(axes, cross.Unit)
			end
		end
	end
	local ha, hb = aSize / 2, bSize / 2
	local offset = b.Position - a.Position
	for _, axis in ipairs(axes) do
		local ra = math.abs(a.RightVector:Dot(axis)) * ha.X + math.abs(a.UpVector:Dot(axis)) * ha.Y + math.abs(a.LookVector:Dot(axis)) * ha.Z
		local rb = math.abs(b.RightVector:Dot(axis)) * hb.X + math.abs(b.UpVector:Dot(axis)) * hb.Y + math.abs(b.LookVector:Dot(axis)) * hb.Z
		if math.abs(offset:Dot(axis)) > ra + rb then
			return false
		end
	end
	return true
end

local function bayOccupied(bay)
	bayParams.FilterDescendantsInstances = { workspace.Terrain }
	local look = bay.LookVector
	local frame = CFrame.new(bay.Position + Vector3.new(0, 0.6 + BAY_CLEAR.Y / 2, 0)) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame, BAY_CLEAR, bayParams)) do
		-- A ball or cylinder is tested as its box: a little generous, never short.
		if part.CanCollide and (not part.CFrame or boxesOverlap(frame, BAY_CLEAR, part.CFrame, part.Size)) then
			return true
		end
	end
	return false
end

-- baseSlots[team] = list of { modelId, kind, model, lostAt }; one live vehicle per slot at most.
local baseSlots = {}
local baseFolder = nil
-- Bumped by StopBaseVehicles so the respawn loop of a finished match stops.
local baseGeneration = 0

local footprintParams = OverlapParams.new()
footprintParams.FilterType = Enum.RaycastFilterType.Exclude
footprintParams.RespectCanCollide = true

local function flatDistance(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- The yaw that points a vehicle's nose (its own -Z, see MapGenerator's verge parking) from `at` at
-- the arena centre.
local function yawTowardCentre(at)
	local toward = Vector3.new(arenaCentre.X - at.X, 0, arenaCentre.Z - at.Z)
	if toward.Magnitude < 0.01 then
		return 0
	end
	return math.atan2(-toward.X, -toward.Z)
end

-- Nothing solid anywhere over the footprint. RefusePad's blocked test covers an 8-stud square at the
-- centre only, and a car is twice that long.
local function footprintClear(at, yaw)
	footprintParams.FilterDescendantsInstances = { workspace.Terrain }
	local frame = CFrame.new(at + Vector3.new(0, 3.6, 0)) * CFrame.Angles(0, yaw, 0)
	local size = Vector3.new(BASE_VEHICLE_FOOTPRINT.X, 6, BASE_VEHICLE_FOOTPRINT.Z)
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame, size, footprintParams)) do
		if part.CanCollide then
			return false
		end
	end
	return true
end

-- The models for one base, rolled once and handed to both. "armed" is drawn from the cars that carry
-- a mount (VehicleModels.Mounts), in a fixed order so the roll is repeatable.
function ModeTeams.RollBaseVehicleModels(rng)
	local armed = {}
	for id, def in pairs(VehicleModels.Models) do
		if def.kind == "car" and VehicleModels.Mounts[id] then
			table.insert(armed, id)
		end
	end
	table.sort(armed)
	local ids = {}
	for _, slot in ipairs(MatchConfig.TeamBaseVehicles.Slots) do
		local id
		if slot == "armed" then
			id = #armed > 0 and armed[rng:NextInteger(1, #armed)] or nil
		else
			id = VehicleModels.Pick(slot == "bike" and "bike" or "car", rng)
		end
		if id then
			table.insert(ids, id)
		end
	end
	return ids
end

-- Where this team's live base vehicles stand now, wherever they have been driven, except `except`.
local function baseVehicleSpots(team, except)
	local spots = {}
	for _, slot in ipairs(baseSlots[team] or {}) do
		if slot ~= except and slot.model and slot.model.Parent then
			table.insert(spots, slot.model:GetPivot().Position)
		end
	end
	return spots
end

-- Why a base vehicle of `team` cannot stand at `at`, or nil. Split out, like RefusePad, so the
-- harness can watch each rule fire; also asked of where a vehicle actually landed. A declared bay
-- (`inBay`) keeps the arena and pad rules, since those are ours to guarantee, but not the spacing or
-- loot rules: whoever built the bays laid them out side by side with the chests beside them, on
-- purpose, and baySpot does its own "is this bay taken" test.
function ModeTeams.RefuseVehicleSpot(team, at, others, inBay)
	local config = MatchConfig.TeamBaseVehicles
	if flatDistance(at, arenaCentre) > arenaRadius - 40 then
		return "outside the arena"
	end
	for _, pad in ipairs(pads[team] or {}) do
		if flatDistance(pad, at) < config.PadClearance then
			return "on a spawn pad"
		end
	end
	if inBay then
		return nil
	end
	for _, other in ipairs(others or {}) do
		if flatDistance(other, at) < config.Gap then
			return "on another vehicle"
		end
	end
	local loot = workspace:FindFirstChild("Loot")
	if loot then
		for _, item in ipairs(loot:GetChildren()) do
			if item:IsA("BasePart") and flatDistance(item.Position, at) < config.LootClearance then
				return "on the loot"
			end
		end
	end
	return nil
end

-- The first free declared bay of `team`'s, as a spot and yaw, or nil when there are none or all are
-- taken. A bay counts as taken while any live base vehicle of the team stands within BAY_TAKEN
-- studs of its centre (the one being replaced, `except`, does not count).
local function baySpot(team, except)
	local provider = ModeTeams.BaseVehicleBays
	if type(provider) ~= "function" then
		return nil
	end
	local ok, bays = pcall(provider, team, bases[team])
	if not ok or type(bays) ~= "table" then
		if not ok then
			warn("ModeTeams: BaseVehicleBays failed: " .. tostring(bays))
		end
		return nil
	end
	local others = baseVehicleSpots(team, except)
	for _, bay in ipairs(bays) do
		if typeof(bay) == "CFrame" then
			local at = bay.Position
			local free = not ModeTeams.RefuseVehicleSpot(team, at, nil, true)
			-- Taken: one of the team's base vehicles stands there, or anything solid at all does.
			local function taken()
				for _, other in ipairs(others) do
					if flatDistance(other, at) < BAY_TAKEN then
						return true
					end
				end
				return bayOccupied(bay)
			end
			if free and taken() then
				free = false
			end
			if free then
				local look = bay.LookVector
				return at, math.atan2(-look.X, -look.Z), true
			end
		end
	end
	return nil
end

-- A spot and yaw for one of `team`'s vehicles, or nil, and whether it is a declared bay. A free bay
-- wins; otherwise a computed spot: a level one is taken the moment one turns up, failing that the
-- least sloping acceptable one, which parkOn then levels or steps aside (and parkSlot checks where
-- it went).
function ModeTeams.BaseVehicleSpot(team, except)
	local base = bases[team]
	if not base or not baseFolder then
		return nil
	end
	local bayAt, bayYaw = baySpot(team, except)
	if bayAt then
		return bayAt, bayYaw, true
	end
	-- A compound's bays are where its vehicles go. With all of them taken, the slot waits and tries
	-- again (BASE_VEHICLE_RETRY_MS) rather than dropping a car in a random spot round the walls.
	if ModeTeams.BaseVehicleBays ~= nil and ModeTeams.BaseVehicleBays == ModeTeams.RuinBays then
		return nil
	end
	local config = MatchConfig.TeamBaseVehicles
	local others = baseVehicleSpots(team, except)
	local best, bestYaw, bestSpread = nil, nil, math.huge
	for _ = 1, BASE_VEHICLE_TRIES do
		local angle = math.random() * math.pi * 2
		local reach = config.Inner + math.sqrt(math.random()) * (config.Outer - config.Inner)
		local x, z = base.X + math.cos(angle) * reach, base.Z + math.sin(angle) * reach
		if not ModeTeams.RefusePad(x, z, ModeTeams.MapRiver) then
			local at = Vector3.new(x, terrainAt(x, z) or 0, z)
			local yaw = yawTowardCentre(at)
			if not ModeTeams.RefuseVehicleSpot(team, at, others) then
				local spread, top = VehicleService.FootingAt(baseFolder, at, yaw, BASE_VEHICLE_FOOTPRINT)
				if spread and footprintClear(Vector3.new(x, top, z), yaw) then
					if spread <= VehicleService.FootingTolerance then
						return Vector3.new(x, top, z), yaw
					elseif spread < bestSpread then
						best, bestYaw, bestSpread = Vector3.new(x, top, z), yaw, spread
					end
				end
			end
		end
	end
	return best, bestYaw
end

-- Parks the slot's model at a fresh spot. Returns the model, or nil (the slot stays empty).
local function parkSlot(team, slot)
	for _ = 1, 3 do
		local at, yaw, inBay = ModeTeams.BaseVehicleSpot(team, slot)
		if not at then
			return nil
		end
		-- In a bay the spot is exact (its floor read by raycast when the compound was built), so it
		-- is used as given: parkOn's step-aside would move the car off its bay onto the next one.
		local model = VehicleService.Create(baseFolder, at, yaw, slot.kind,
			{ model = slot.modelId, rng = Random.new(math.random(1, 2147483646)), exact = inBay or nil })
		if model and inBay and model.PrimaryPart then
			local chassis = model.PrimaryPart
			chassis.Anchored = true
			task.delay(BAY_SETTLE_SECONDS, function()
				if chassis.Parent then
					chassis.Anchored = false
				end
			end)
		end
		if model then
			-- parkOn may have stepped a not-quite-level spot aside; one that went onto a pad or out
			-- of the arena is taken back and another spot tried.
			if not ModeTeams.RefuseVehicleSpot(team, model:GetPivot().Position, baseVehicleSpots(team, slot), inBay) then
				slot.model = model
				slot.lostAt = nil
				return model
			end
			model:Destroy()
		end
	end
	return nil
end

local function isLive(model)
	return model ~= nil and model.Parent ~= nil and model:GetAttribute("Wrecked") ~= true
end

-- Live base vehicles of `team`, counted from the slots.
function ModeTeams.LiveBaseVehicles(team)
	local live = 0
	for _, slot in ipairs(baseSlots[team] or {}) do
		if isLive(slot.model) then
			live += 1
		end
	end
	return live
end

-- A team's spawn pads, for the harness and for whatever lays out bays around them.
function ModeTeams.BasePads(team)
	return pads[team] or {}
end

-- The folder the base vehicles are parked in (for probes), or nil outside a team match.
function ModeTeams.BaseVehicleFolder()
	return baseFolder
end

-- One pass of the respawn rule at wall-clock `nowMs`. Called every second by the loop
-- SpawnBaseVehicles starts; public so the harness can drive the clock.
function ModeTeams.TickBaseVehicles(nowMs)
	if not active or not baseFolder then
		return
	end
	local delayMs = MatchConfig.TeamBaseVehicles.RespawnDelay * 1000
	for team, slots in pairs(baseSlots) do
		for _, slot in ipairs(slots) do
			if not isLive(slot.model) then
				slot.lostAt = slot.lostAt or nowMs
				if nowMs - slot.lostAt >= delayMs and ModeTeams.LiveBaseVehicles(team) < #slots then
					-- The wreck goes BEFORE its replacement is parked: it is still standing in its bay,
					-- and the bay test skips this slot's own vehicle, so the replacement used to be
					-- put into the wreck. Wrecking has already put everyone out of it.
					local wreck = slot.model
					if wreck and wreck.Parent then
						wreck:Destroy()
					end
					if not parkSlot(team, slot) then
						slot.lostAt = nowMs - delayMs + BASE_VEHICLE_RETRY_MS
					end
				end
			end
		end
	end
end

-- Parks every base's vehicles and starts the respawn loop. Called from Setup, after the pads.
function ModeTeams.SpawnBaseVehicles(mapInfo)
	ModeTeams.StopBaseVehicles()
	local config = MatchConfig.TeamBaseVehicles
	local map = mapInfo and mapInfo.map
	if not config or not config.Enabled or not map then
		return 0
	end
	-- A child of the map, so parkOn's hardstanding (it goes in the parent's parent) lands in the map
	-- and goes with it.
	baseFolder = Instance.new("Model")
	baseFolder.Name = "TeamBaseVehicles"
	baseFolder.Parent = map

	local modelIds = ModeTeams.RollBaseVehicleModels(Random.new(math.random(1, 2147483646)))
	local parked = 0
	local now = protectionNowMs()
	for team = 1, GameModes.TeamCount do
		baseSlots[team] = {}
		for _, modelId in ipairs(modelIds) do
			local slot = { modelId = modelId, kind = VehicleModels.Models[modelId].kind }
			table.insert(baseSlots[team], slot)
			if parkSlot(team, slot) then
				parked += 1
			else
				-- Tried again once the delay has run, like a wreck.
				slot.lostAt = now
			end
		end
	end
	if parked < #modelIds * GameModes.TeamCount then
		warn(string.format("ModeTeams: parked %d of %d base vehicles", parked, #modelIds * GameModes.TeamCount))
	end

	local generation = baseGeneration
	task.spawn(function()
		while baseGeneration == generation do
			task.wait(1)
			if baseGeneration ~= generation then
				return
			end
			ModeTeams.TickBaseVehicles(protectionNowMs())
		end
	end)
	return parked
end

-- Removes every base vehicle, whoever is in it, and stops the respawn loop. From Teardown.
function ModeTeams.StopBaseVehicles()
	baseGeneration += 1
	if baseFolder then
		baseFolder:Destroy()
		baseFolder = nil
	end
	table.clear(baseSlots)
end

-- END BASE VEHICLES

--------------------------------------------------------------------------------
-- Team assignment
--------------------------------------------------------------------------------

-- Deals a combatant onto the smaller side, dealing alternately when they are level. Returns the
-- team index.
function ModeTeams.Assign(token)
	local existing = teamOf[token]
	if existing then
		return existing
	end
	local counts = ModeTeams.Counts()
	local team
	if counts[1] < counts[2] then
		team = 1
	elseif counts[2] < counts[1] then
		team = 2
	else
		team = nextTeam
		nextTeam = GameModes.OtherTeam(nextTeam) or 1
	end
	teamOf[token] = team

	-- On the character too, so nameplates and clients can colour by team without a lookup.
	local character = Combatants.GetCharacter(token)
	if character then
		character:SetAttribute("Team", team)
	end
	return team
end

function ModeTeams.Forget(token)
	teamOf[token] = nil
	protectedUntil[token] = nil
	downed[token] = nil
end

--------------------------------------------------------------------------------
-- Friendly fire and spawn protection
--------------------------------------------------------------------------------

-- Hung off CombatService.DamageVeto. True means the damage does not happen.
--
-- SIGNATURE, as the two real call sites actually use it:
--   CombatService.DealDamage:353   DamageVeto(attackerToken, victimToken, weaponId)
--   CompanionService:594           DamageVeto(player, target.token, tag)
-- Both pass an IDENTIFIER third. This used to be declared (attacker, victim, amount, weaponId,
-- headshot) after a comment that no caller ever matched, so `weaponId` arrived in the `amount` slot
-- and the last two were never passed at all -- harmless only while they went unread.
-- DO NOT "re-align" this by changing the callers: two tabs calling it the same way IS the contract.
-- If the callers ever change, change this declaration to follow them, not the other way round.
--
-- Every combat damage path in the game reaches CombatService.DealDamage — guns, thrown coconuts
-- and rockets (ProjectileService), barrels and mines (HazardService) and companions
-- (CompanionService). TWO paths do not: the battle royale's storm and the respawn modes' own arena
-- boundary both call humanoid:TakeDamage directly (StormService:136 and :232), so neither friendly
-- fire nor spawn protection applies to either. That is deliberate for the boundary -- protection
-- must not let anyone camp outside the arena -- and it corrects the older comment here, which
-- claimed no respawn mode runs a storm. StormService.StartStatic IS one, at 4 damage a second.
--
-- CombatService calls this AFTER its own dead-victim and zero-amount guards, so it is never asked
-- about a hit that was going nowhere anyway.
function ModeTeams.DamageVeto(attackerToken, victimToken, _weaponId)
	if not active or attackerToken == nil or attackerToken == victimToken then
		-- Your own grenade still hurts you. It is a real cost and removing it would be a free
		-- panic button.
		return false
	end

	local attackerTeam, victimTeam = teamOf[attackerToken], teamOf[victimToken]
	if attackerTeam and victimTeam and attackerTeam == victimTeam then
		return true
	end

	-- A swing at an enemy ends the swinger's own protection. The comment on BreakProtection always
	-- promised this and nothing called it from an attack, so a fresh spawn could fire at you for the
	-- whole window while being unhittable back (#86). Here, because every hit on a combatant --
	-- gun, blast, melee -- comes through this veto; a clean miss does not, which is the one gap.
	ModeTeams.BreakProtection(attackerToken)

	if ModeTeams.IsProtected(victimToken) then
		return true
	end
	return false
end

-- Bots ask this before picking a target, so a friendly-fire veto makes them hold fire rather than
-- making them look broken by shooting team-mates who never take damage.
function ModeTeams.IsHostile(a, b)
	if not active then
		return true
	end
	local teamA, teamB = teamOf[a], teamOf[b]
	if teamA and teamB and teamA == teamB then
		return false
	end
	return true
end

-- THE ONE COPY OF THIS RULE. It used to exist twice: here, and inline inside DamageVeto, with the
-- inline one live and this one dead. Two copies of a rule is one copy that gets fixed and one that
-- does not, which is exactly what happened to the clock. DamageVeto now calls this.
function ModeTeams.IsProtected(token)
	local until_ = protectedUntil[token]
	return until_ ~= nil and protectionNowMs() < until_
end

-- Protection ends the moment you land a swing on an enemy, not when you move: DamageVeto calls
-- BreakProtection for the attacker. Safe to call when nothing is protected.
-- The raw deadline, for tools/respawn_probe.lua. Read-only and read by nothing in the game.
--
-- It exists because the UNITS are checkable offline and the BEHAVIOUR is not: this deadline was
-- once `os.clock() + seconds` (process CPU time, a small number of seconds since the process
-- started) and is now a wall-clock millisecond (~1.7e12). Under load those two implementations
-- behave very differently -- 3 seconds of invulnerability became about 7.5 -- but in an idle window
-- they behave identically, so no timing test can tell them apart there. The magnitude can, always.
function ModeTeams.ProtectionDeadline(token)
	return protectedUntil[token]
end

function ModeTeams.BreakProtection(token)
	if protectedUntil[token] then
		protectedUntil[token] = nil
		local character = Combatants.GetCharacter(token)
		if character then
			character:SetAttribute("SpawnProtected", nil)
		end
	end
end

local function grantProtection(token, seconds)
	if not seconds or seconds <= 0 then
		return
	end
	protectedUntil[token] = protectionNowMs() + seconds * 1000
	local character = Combatants.GetCharacter(token)
	if character then
		character:SetAttribute("SpawnProtected", true)
	end
	-- task.delay is WALL time, so the test inside it has to be a wall test too. It used to re-read a
	-- CPU deadline, which at this moment has NOT been reached however long the player has really been
	-- standing there -- so this never called BreakProtection, and protection ended only when the
	-- player took a swing or the mode tore down. A condition that cannot be true when it is checked.
	--
	-- IsProtected, not a re-implementation: a second grant with a later deadline must win, and it
	-- brings its own delay with it.
	task.delay(seconds, function()
		if protectedUntil[token] and not ModeTeams.IsProtected(token) then
			ModeTeams.BreakProtection(token)
		end
	end)
end

--------------------------------------------------------------------------------
-- Picking a pad
--------------------------------------------------------------------------------

local ENEMY_CLEARANCE = 90

local sightParams = RaycastParams.new()
sightParams.FilterType = Enum.RaycastFilterType.Exclude
sightParams.RespectCanCollide = true
sightParams.IgnoreWater = true

local function enemySees(from, enemyRoot, enemyCharacter)
	sightParams.FilterDescendantsInstances = { enemyCharacter }
	local eye = enemyRoot.Position
	local delta = (from + Vector3.new(0, 3, 0)) - eye
	local hit = workspace:Raycast(eye, delta, sightParams)
	return hit == nil
end

-- The best pad for a team right now: the one furthest from the nearest live enemy, refusing
-- outright any pad an enemy is close to or can see. Returns the pad and how many were refused,
-- or nil when every pad is refused — the caller waits a second and asks again rather than
-- spawning someone in front of a gun.
function ModeTeams.PickPad(team, extraScore)
	local list = pads[team]
	if not list or #list == 0 then
		return nil, 0
	end

	local enemies = {}
	for token, index in pairs(teamOf) do
		if index ~= team and not downed[token] then
			local character = Combatants.GetCharacter(token)
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if root and humanoid and humanoid.Health > 0 then
				table.insert(enemies, { root = root, character = character })
			end
		end
	end

	local best, bestScore, refused = nil, -math.huge, 0
	-- The least bad of the refused pads, for a caller that must place a body now.
	local leastBad, leastBadDistance = nil, -math.huge
	for _, pad in ipairs(list) do
		local nearest, refuse = math.huge, false
		for _, enemy in ipairs(enemies) do
			local distance = (enemy.root.Position - pad).Magnitude
			nearest = math.min(nearest, distance)
			-- Too close, or in plain sight from where they stand: either one is a spawn in front
			-- of an enemy, which is the thing this whole function exists to prevent.
			if distance < ENEMY_CLEARANCE or enemySees(pad, enemy.root, enemy.character) then
				refuse = true
			end
		end
		if refuse then
			refused += 1
			if nearest > leastBadDistance then
				leastBad, leastBadDistance = pad, nearest
			end
		else
			local score = nearest == math.huge and 1e6 or nearest
			if extraScore then
				score += extraScore(pad)
			end
			if score > bestScore then
				best, bestScore = pad, score
			end
		end
	end
	return best, refused, leastBad
end

--------------------------------------------------------------------------------
-- Ground of last resort, and nobody spawning on anybody
--------------------------------------------------------------------------------

-- Real ground inside the arena, searched outward from `from` in rings. Returns a point ON the
-- surface, or nil when the arena has no usable ground anywhere.
--
-- This exists because `arenaCentre` is stored FLAT -- Setup forces its Y to 0 -- so "the arena
-- centre" is sea level, not the ground. The old emergency fallback pivoted a body to
-- centre + (0, 4, 0). On the five shipped maps the centre's ground measures 0.0, so that happens to
-- land four studs ABOVE it today; on any map whose centre town stands higher it is underground.
-- Measured rather than assumed, and fixed because it is wrong either way.
local GROUND_RINGS = 8
local GROUND_STEP = 40

function ModeTeams.GroundNear(from)
	local centre = Vector3.new(from.X, 0, from.Z)
	for ring = 0, GROUND_RINGS do
		local reach = ring * GROUND_STEP
		local steps = ring == 0 and 1 or 8
		for step = 1, steps do
			local angle = (step / steps) * math.pi * 2
			local x = centre.X + math.cos(angle) * reach
			local z = centre.Z + math.sin(angle) * reach
			local ground = terrainAt(x, z)
			if ground and not blocked(Vector3.new(x, ground, z)) then
				return Vector3.new(x, ground, z)
			end
		end
	end
	return nil
end

-- Nobody spawns on top of anybody. PickPad scores a pad by its distance to the nearest ENEMY only,
-- so a team-mate already standing on the best pad is invisible to it -- which is why three
-- replacement bots in a row came back at the SAME point with the nearest living body 0 studs away
-- (measured, tools/respawn_probe.lua). Rings out until the spot is clear, and gives the pad back
-- unchanged when it already is.
-- 14, not 10: the probe measured a replacement bot landing 11 studs from a living body, which
-- cleared the old constant and still reads as close. Before this whole fix the same measurement
-- was 0 studs -- three replacements on one point. A character is about 5 studs across.
local SPAWN_CLEARANCE = 20

-- `except` is the body being placed. It is already registered as a combatant by the time
-- OnCharacterAdded reaches the respawn, and the placement watchdog can run this again when the body
-- is ALREADY standing on the pad -- so without this it would see itself, call the pad occupied and
-- shuffle sideways on every check.
local function occupiedAt(point, except)
	for character in pairs(Combatants.All()) do
		if character.Parent and character ~= except then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 and (root.Position - point).Magnitude < SPAWN_CLEARANCE then
				return true
			end
		end
	end
	return false
end

-- `others` (optional) are the team's other pads, tried nearest first before the rings. In a compound
-- the pads stand 9 to 14 apart under one roof, so the ring search from a busy pad would put the body
-- out in the courtyard, or outside the walls, while a free pad stood a few steps away.
function ModeTeams.ClearSpotNear(pad, except, others)
	if not occupiedAt(pad, except) then
		return pad
	end
	if others then
		local sorted = table.clone(others)
		table.sort(sorted, function(a, b)
			return (a - pad).Magnitude < (b - pad).Magnitude
		end)
		for _, other in ipairs(sorted) do
			if not occupiedAt(other, except) then
				return other
			end
		end
	end
	for ring = 1, 3 do
		local reach = ring * SPAWN_CLEARANCE * 1.4
		for step = 1, 8 do
			local angle = (step / 8) * math.pi * 2 + ring
			local x = pad.X + math.cos(angle) * reach
			local z = pad.Z + math.sin(angle) * reach
			local ground = terrainAt(x, z)
			if ground then
				local candidate = Vector3.new(x, ground, z)
				if not blocked(candidate) and not occupiedAt(candidate, except) then
					return candidate
				end
			end
		end
	end
	-- Everywhere within 42 studs is busy. The pad is still better than the lobby.
	return pad
end

-- Places a body when its team has NO PADS AT ALL. PlaceAt's least-bad branch cannot cover this: it
-- picks the least bad of the pads that WERE refused, and there are none to be least bad. `place`
-- used to answer that by waiting a second and asking again, up to four times -- while LoadCharacter
-- had already stood the body on the LOBBY's spawn pad. That wait measured 3075 ms.
--
-- Returns whether a body was placed, and the point it went to.
function ModeTeams.PlaceWithoutPad(token, character)
	if not character or not character.Parent then
		return false
	end
	local team = teamOf[token] or ModeTeams.Assign(token)
	local spot = ModeTeams.GroundNear(arenaCentre)
	if not spot then
		return false
	end
	spot = ModeTeams.ClearSpotNear(spot, character)
	local position = spot + Vector3.new(0, 4, 0)
	-- Face the middle -- unless this IS the middle. CFrame.lookAt with the eye and the target in the
	-- same place has no look vector, and the ring search starts AT the centre, so that is the common
	-- case here rather than a rare one.
	local facing = Vector3.new(arenaCentre.X, position.Y, arenaCentre.Z)
	if Vector3.new(facing.X - position.X, 0, facing.Z - position.Z).Magnitude < 1 then
		facing = position + Vector3.new(0, 0, 1)
	end
	character:PivotTo(CFrame.lookAt(position, facing))
	character:SetAttribute("Team", team)
	downed[token] = nil
	grantProtection(token, mode and mode.spawnProtection or 0)
	return true, position
end

-- Deals a combatant onto a NAMED side. Assign deals onto whichever side is smaller, so it cannot be
-- asked for a particular one -- spawnReplacementBot used to call Forget and Assign again hoping for
-- a different answer, which deals the same way and could not force anything.
function ModeTeams.AssignTo(token, team)
	if team ~= 1 and team ~= 2 then
		return ModeTeams.Assign(token)
	end
	teamOf[token] = team
	local character = Combatants.GetCharacter(token)
	if character then
		character:SetAttribute("Team", team)
	end
	return team
end

-- How far a body may be from where it was put before the placement is treated as not having taken.
-- Far more than a player can travel in GameMode's confirm delay, far less than the 500 studs
-- between the arena and the lobby.
ModeTeams.PlacedTolerance = 150

--------------------------------------------------------------------------------
-- The loadout
--------------------------------------------------------------------------------

-- Everything here is WeaponService's existing public API — GiveWeapon and GiveConsumable — so no
-- other tab's file is touched to hand out a kit. Returns the gun id granted and how many item
-- stacks landed, for the probe.
function ModeTeams.GrantLoadout(player)
	WeaponService.Reset(player)

	local weaponId = ModeTeams.RollGreenWeapon()
	if weaponId then
		WeaponService.GiveWeapon(player, weaponId)
	end

	local stacks = 0
	for _, entry in ipairs(GameModes.Loadout.items) do
		local item = ItemData.Get(entry.id)
		if item then
			local wanted = math.min(entry.count, item.stack)
			if WeaponService.GiveConsumable(player, entry.id, wanted) > 0 then
				stacks += 1
			end
		end
	end
	-- Everything present now is the issued kit: tagged so a death in this mode drops only what was
	-- picked up later (MatchService.dropPickedUp, Oliver's #124). A pickup that displaces an issued
	-- slot arrives untagged, so it drops.
	local loadout = WeaponService.Get(player)
	if loadout then
		for _, slot in pairs(loadout.slots) do
			slot.issued = true
		end
	end
	return weaponId, stacks
end

-- What the loadout SHOULD look like, for the probe to check a real one against. Kept here so the
-- expectation and the granting read from the same list.
function ModeTeams.ExpectedLoadout()
	local expected = { weaponRarity = GameModes.GreenRarity, items = {} }
	for _, entry in ipairs(GameModes.Loadout.items) do
		local item = ItemData.Get(entry.id)
		expected.items[entry.id] = {
			count = item and math.min(entry.count, item.stack) or entry.count,
			kind = item and item.kind or nil,
			rarity = item and item.rarity or nil,
		}
	end
	return expected
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

-- Puts a body on a pad, facing the middle of the arena, and starts its spawn protection. `extra`
-- is an optional per-pad score (King of the Hill adds nearness to the hill). Returns false when
-- every pad was refused, which is the caller's cue to wait and try again.
-- `allowRefused`: when every pad is refused, take the least bad one rather than returning false.
-- Returns whether a body was placed, and whether the pad it got was a refused one.
function ModeTeams.PlaceAt(token, character, extra, allowRefused)
	local team = teamOf[token] or ModeTeams.Assign(token)
	local pad, _, leastBad = ModeTeams.PickPad(team, extra)
	local settled = false
	if not pad and allowRefused and leastBad then
		pad, settled = leastBad, true
	end
	if not pad then
		return false
	end

	pad = ModeTeams.ClearSpotNear(pad, character, ruins[team] and pads[team] or nil)
	local position = pad + Vector3.new(0, 4, 0)
	character:PivotTo(CFrame.lookAt(position, Vector3.new(arenaCentre.X, position.Y, arenaCentre.Z)))
	character:SetAttribute("Team", team)
	downed[token] = nil
	grantProtection(token, mode and mode.spawnProtection or 0)
	-- THIRD RETURN: where the body was actually put, so the caller can read it back a moment later
	-- and see whether the placement took. Additive; the first two returns are unchanged.
	return true, settled, position
end

-- Marks a combatant down. The scoreline is the caller's business; this only tracks the body.
function ModeTeams.MarkDown(token)
	downed[token] = true
	ModeTeams.BreakProtection(token)
end

-- A colour for a rarity, for anything that wants to tint the granted gun the way the rest of the
-- game does. Here so ModeTeams is the one place a mode asks about the green kit.
function ModeTeams.GreenColor()
	return Rarity.Color(GameModes.GreenRarity)
end

return ModeTeams
