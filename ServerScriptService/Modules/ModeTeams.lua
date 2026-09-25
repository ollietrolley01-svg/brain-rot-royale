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
local TeamBaseRoads = require(script.Parent:WaitForChild("TeamBaseRoads"))
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
	local ray = hit and hit.Position.Y or nil
	-- A terrain raycast straight after Terrain:WriteVoxels still reads the ground as it was BEFORE the
	-- write (measured in Studio, 2026-09-24: round both compounds the rays read the untouched slope,
	-- up to 14 studs off the pad the voxels hold). The compounds reshape the ground round them
	-- (TeamBaseRuins.Build) in the same frame this is asked where the base loot and pads go, so the
	-- voxels are read too, the way MapTerrain measures every pad, and trusted whenever the ray is
	-- further off them than a rough material draws its surface (Rock, up to 1.1).
	if MapTerrain.PadCost then
		local ok, _, _, mean = pcall(MapTerrain.PadCost, CFrame.new(x, 0, z), Vector3.zero, { shape = "round", margin = 2.9 })
		if ok and mean and (not ray or math.abs(mean - ray) > 1.5) then
			return mean
		end
	end
	return ray
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
-- How many of the best pairs of compound sites (ModeTeams.RankBaseAxes) Setup builds on before giving
-- up on compounds: a site FlattenPad refuses after all (SiteCost samples every 8 studs, FlattenPad
-- every 4) sends both compounds to the next pair.
local RUIN_TRIES = 10

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
	-- The pairs of sites to build on, best first; a compound whose site FlattenPad refuses after all
	-- (Build returns nil) sends both to the next pair, RUIN_TRIES pairs at most.
	local candidates = { { axis = axis, fraction = fraction } }
	if withRuins then
		local ranked = ModeTeams.RankBaseAxes(axis, mapInfo)
		if #ranked > 0 then
			candidates = ranked
		end
	end
	local ruinSeed = withRuins and math.random(1, 2147483646) or nil
	local tries = withRuins and math.min(RUIN_TRIES, #candidates) or 1
	for attempt = 1, tries do
		axis, fraction = candidates[attempt].axis, candidates[attempt].fraction
		for team = 1, GameModes.TeamCount do
			local heading = axis + (team - 1) * math.pi
			bases[team] = arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * fraction)
			if withRuins then
				ModeTeams.BuildRuin(team, bases[team], mapInfo, ruinSeed)
			end
		end
		if not withRuins or (ruins[1] and ruins[2]) or attempt == tries then
			break
		end
		ModeTeams.ClearRuins()
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
	-- The battleground in the middle (BEGIN BATTLEGROUND, below), after the bases so it faces them.
	if withRuins then
		ModeTeams.BuildBattleground(mapInfo, axis, ruinSeed)
	end
	-- Each compound's access road to the map's roads, after the battleground so it keeps out of it.
	if ruins[1] and ruins[2] then
		local ok, problem = pcall(ModeTeams.BuildAccessRoads, mapInfo)
		if not ok then
			warn("ModeTeams: access roads failed: " .. tostring(problem))
		end
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

-- Other axes tried when the rolled one puts a compound on a road, in the river, over a town or on a
-- slope (16, every 11.25 degrees, since the two bases are opposite), at the usual distance and nearer
-- the middle. The rolled axis wins any tie, so the base still moves about from match to match. The
-- compounds are built flush with the ground (TeamBaseRuins.Build), so a sloping site costs banks and
-- gate ramps rather than a plinth: more candidates find ground that needs less of either.
local RUIN_AXES = 24
local RUIN_FRACTIONS = { BASE_FRACTION, 0.66, 0.6, 0.8, 0.86, 0.54 }
-- The clear ground kept between a compound's levelled pad and the battleground's apron (the arena is
-- growing toward the bases, pc/battleground-v2): a site nearer the middle than the battleground's reach
-- (ModeTeams.ArenaReach, set where the battleground is required), the compound's flat half-depth and
-- this is not ranked at all.
local ARENA_BUFFER = 40
-- A pair of sites costing under this is as good as it gets (flat, clear ground: SiteCost is the
-- ground's rise plus half the surroundings'), and RUIN_TRIES of them end the search: every SiteCost
-- reads a few hundred thousand voxels, and 96 pairs of them is seconds.
local RUIN_GOOD = 6
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

-- The pairs of sites (an axis, and a distance from the centre as a fraction of the arena's radius) that
-- suit the compounds, best first, starting from the rolled `axis`: { { axis, fraction, cost }... }.
-- The search stops once RUIN_TRIES pairs cost under RUIN_GOOD. Empty when no pair is usable at all.
-- Where the battleground will end the map's roads (its gateways, before it is built): every road edge's
-- crossing of the circle ModeTeams.ArenaReach round the middle.
local function gatewayGuesses(mapInfo)
	local out = {}
	local roads = mapInfo and mapInfo.roads
	local r = ModeTeams.ArenaReach or 200
	local c = Vector3.new(arenaCentre.X, 0, arenaCentre.Z)
	for _, e in ipairs(roads and roads.edges or {}) do
		local a = Vector3.new(e.a.position.X, 0, e.a.position.Z)
		local d = Vector3.new(e.b.position.X, 0, e.b.position.Z) - a
		local A, B, C = d:Dot(d), 2 * (a - c):Dot(d), (a - c):Dot(a - c) - r * r
		local disc = B * B - 4 * A * C
		if A > 0 and disc > 0 then
			for _, t in ipairs({ (-B - math.sqrt(disc)) / (2 * A), (-B + math.sqrt(disc)) / (2 * A) }) do
				if t > 0 and t < 1 then
					table.insert(out, a + d * t)
				end
			end
		end
	end
	return out
end
-- How much an unfair pair of sites costs, per unit of the share their gates' distances to the nearest
-- gateway differ by (Oliver: both teams equal road distance to the arena).
local FAIR_WEIGHT = 25

function ModeTeams.RankBaseAxes(axis, mapInfo)
	local ranked, good = {}, 0
	local guesses = gatewayGuesses(mapInfo)
	local function toGateway(base)
		local toward = Vector3.new(arenaCentre.X - base.X, 0, arenaCentre.Z - base.Z)
		local gate = Vector3.new(base.X, 0, base.Z) + (toward.Magnitude > 1 and toward.Unit or Vector3.zero) * 58
		local best = math.huge
		for _, g in ipairs(guesses) do
			best = math.min(best, (g - gate).Magnitude)
		end
		return best
	end
	-- Up to RUIN_AXES x #RUIN_FRACTIONS pairs of SiteCost (each ~1000 terrain samples and two box
	-- queries) took seconds in one piece, freezing the whole server at match start. Nothing is built
	-- here, so hand the frame back whenever a slice has run SLICE_BUDGET seconds.
	local SLICE_BUDGET = 1 / 30
	local sliceStart = os.clock()
	for step = 0, RUIN_AXES - 1 do
		local candidate = axis + step * math.pi / RUIN_AXES
		for index, fraction in ipairs(RUIN_FRACTIONS) do
			if os.clock() - sliceStart > SLICE_BUDGET then
				task.wait()
				sliceStart = os.clock()
			end
			local total = step * 0.01 + (index - 1) * 0.5
			local keep = (ModeTeams.ArenaReach or 0) + (TeamBaseRuins.Footprint and TeamBaseRuins.Footprint.Z / 2 or 55) + 12 + ARENA_BUFFER
			if arenaRadius * fraction < keep then
				total = math.huge
			end
			-- Fair roads to the arena: the two sites' distances to their nearest gateways alike.
			if total < math.huge and #guesses > 0 then
				local d = {}
				for team = 1, GameModes.TeamCount do
					local heading = candidate + (team - 1) * math.pi
					d[team] = toGateway(arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * fraction))
				end
				if d[1] < math.huge and d[2] < math.huge then
					total += FAIR_WEIGHT * math.abs(d[1] - d[2]) / math.max(d[1], d[2], 1)
				end
			end
			for team = 1, GameModes.TeamCount do
				local heading = candidate + (team - 1) * math.pi
				local base = arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * fraction)
				local cost = total < math.huge and TeamBaseRuins.SiteCost(ruinFrame(base), mapInfo) or nil
				total = cost and total + cost or math.huge
			end
			if total < math.huge then
				table.insert(ranked, { axis = candidate, fraction = fraction, cost = total })
				if total < RUIN_GOOD then
					good += 1
				end
			end
		end
		if good >= RUIN_TRIES then
			break
		end
	end
	table.sort(ranked, function(a, b)
		return a.cost < b.cost
	end)
	return ranked
end

-- The best axis and fraction (RankBaseAxes' first), or the rolled axis unchanged when no pair of sites
-- is usable at all (the bases then fall back to open-ground pads).
function ModeTeams.PickBaseAxis(axis, mapInfo)
	local best = ModeTeams.RankBaseAxes(axis, mapInfo)[1]
	if best then
		return best.axis, best.fraction
	end
	return axis, BASE_FRACTION
end

-- Builds `team`'s compound at `base`. Returns it, or nil (warned) when it could not be built.
function ModeTeams.BuildRuin(team, base, mapInfo, seed)
	local ok, ruin, why = pcall(TeamBaseRuins.Build, ruinFrame(base), GameModes.TeamColor(team), mapInfo, seed)
	if not ok or type(ruin) ~= "table" or #ruin.pads == 0 then
		-- Build returns nil and why when its site cannot be levelled (Setup then tries the next pair).
		warn("ModeTeams: team " .. team .. "'s base was not built: " .. tostring(ok and (ruin == nil and why or "no pads") or ruin))
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
	ModeTeams.UnregisterAccessRoads()
	for team, ruin in pairs(ruins) do
		if ruin.model then
			ruin.model:Destroy()
		end
		ruins[team] = nil
	end
end

--------------------------------------------------------------------------------
-- The access roads (Oliver, 2026-09-24: "make sure the team bases connect to the roads too")
--------------------------------------------------------------------------------
-- TeamBaseRoads plans, builds and registers one per compound, from the foot of its gatehouse ramp to
-- the nearest map road it can reach at a T-junction: never through the battleground or the other
-- compound, never through a building (anything bigger than TeamBaseRuins.ClearableSpan); the small
-- scenery in its way (trees, rocks, props) is cleared. The road is parented into the compound, so it
-- goes with it; the bot road data is put back by UnregisterAccessRoads.
local accessUndo = {}
local ACCESS_CLEAR = (TeamBaseRoads and TeamBaseRoads.Width or 18) / 2 + 3

function ModeTeams.UnregisterAccessRoads()
	local okNav, nav = pcall(require, script.Parent:WaitForChild("BotNav"))
	if okNav and type(nav) == "table" then
		nav.Arena = nil
	end
	for index = #accessUndo, 1, -1 do
		pcall(accessUndo[index])
		accessUndo[index] = nil
	end
end

-- The thing in the map that `part` belongs to (a building in a town, a tree in the props), or nil.
local function mapItemOf(part, map)
	local node = part
	while node.Parent and node.Parent ~= map and node.Parent.Parent ~= map do
		node = node.Parent
	end
	if node.Parent == map or not node.Parent then
		return nil
	end
	return node
end

local function itemSpan(item)
	if item:IsA("BasePart") then
		return math.max(item.Size.X, item.Size.Z)
	end
	local ok, size = pcall(function()
		return item:GetExtentsSize()
	end)
	return ok and math.max(size.X, size.Z) or math.huge
end

-- The arena's gateways: the finished road ends at the battleground's apron (TeamBattleground's
-- RoadEnds, each marked by its StopLine), as flat points.
local function arenaGateways()
	local out = {}
	local built = ModeTeams.Battleground and ModeTeams.Battleground()
	local ends = built and built.roadEnds
	for _, roadEnd in ipairs(ends and ends:GetChildren() or {}) do
		if roadEnd.Name == "RoadEnd" then
			for _, part in ipairs(roadEnd:GetDescendants()) do
				if part.Name == "StopLine" and part:IsA("BasePart") then
					table.insert(out, Vector3.new(part.Position.X, 0, part.Position.Z))
					break
				end
			end
		end
	end
	return out
end
ModeTeams.ArenaGateways = arenaGateways
-- The two teams' ways to the arena may differ by this share of the longer at most (Oliver: "mirror-fair
-- so both teams get equal road distance").
local FAIR_SHARE = 0.1
ModeTeams.AccessFairShare = FAIR_SHARE

function ModeTeams.BuildAccessRoads(mapInfo)
	ModeTeams.UnregisterAccessRoads()
	local roads = mapInfo and mapInfo.roads
	local map = mapInfo and mapInfo.map
	if not (TeamBaseRoads and roads and roads.edges and map) then
		return
	end
	local keep = { Roads = true, River = true, Ziplines = true }
	local avoid = { { centre = arenaCentre, radius = (ModeTeams.ArenaReach or 150) + 10, name = "battleground" } }
	local boxes = {}
	for team = 1, GameModes.TeamCount do
		if ruins[team] then
			table.insert(boxes, { frame = ruins[team].frame, halfX = TeamBaseRuins.Footprint.X / 2 + 4, halfZ = TeamBaseRuins.Footprint.Z / 2 + 4 })
		end
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	-- World loot too: it is seeded before Setup, and pickups left on the route would end up buried by the
	-- ground shaping or inside the asphalt (TeamBaseRuins.ClearSite clears it for the same reason).
	local lootFolder = workspace:FindFirstChild("Loot")
	params.FilterDescendantsInstances = lootFolder and { map, lootFolder } or { map }
	local function groundAt(x, z)
		return terrainAt(x, z)
	end
	-- What stands in a stretch of `ruin`'s way: nil when it is clear or can be cleared (then put in
	-- `clear`), else why not.
	local function blocker(ruin, clear)
		return function(a, b)
			local mid = (a + b) / 2
			local length = (b - a).Magnitude
			if length < 0.1 then
				return nil
			end
			local ground = terrainAt(mid.X, mid.Z) or ruin.height
			local frame = CFrame.lookAt(Vector3.new(mid.X, ground + 7, mid.Z), Vector3.new(b.X, ground + 7, b.Z))
			for _, part in ipairs(workspace:GetPartBoundsInBox(frame, Vector3.new(ACCESS_CLEAR * 2, 16, length), params)) do
				if lootFolder and part:IsDescendantOf(lootFolder) then
					-- A pickup is always cleared, never a blocker: its whole entry under the Loot folder goes.
					local pickup = part
					while pickup.Parent ~= lootFolder do
						pickup = pickup.Parent
					end
					if clear then
						clear[pickup] = true
					end
					continue
				end
				local item = mapItemOf(part, map)
				local top = item and item.Parent
				if item and not (top and keep[top.Name]) and item ~= ruin.model and not item:IsDescendantOf(ruin.model) then
					-- mapItemOf returns the map's grandchild, so a compound or the battleground is its container
					-- (`top`), not the item itself: refuse by either name, or a piece of them would be cleared.
					local topName = top and top.Name or ""
					if string.sub(item.Name, 1, 8) == "TeamBase" or item.Name == "TeamBattleground"
						or string.sub(topName, 1, 8) == "TeamBase" or topName == "TeamBattleground"
						or itemSpan(item) > TeamBaseRuins.ClearableSpan then
						return item.Name
					end
					if clear then
						clear[item] = true
					end
				end
			end
			return nil
		end
	end
	-- The road data inside the battleground's apron closed (its roads are cut there), so no bot drives
	-- through the apron and walls; the gateways become the network's ends.
	local gateways = arenaGateways()
	if #gateways > 0 then
		table.insert(accessUndo, (TeamBaseRoads.CutAtArena(roads, arenaCentre, (ModeTeams.ArenaReach or 200) - 1)))
		-- Bots into the arena only through a gateway (BotNav.DriveRoute).
		local okNav, nav = pcall(require, script.Parent:WaitForChild("BotNav"))
		if okNav and type(nav) == "table" then
			nav.Arena = { center = arenaCentre, radius = ModeTeams.ArenaReach or 200, gateways = gateways }
		end
	end
	-- Each team's best way to each arena gateway (onto that gateway's road, outside it, then along it),
	-- or -- no gateways -- to the nearest road.
	local targets = #gateways > 0 and TeamBaseRoads.GatewayTargets(roads, gateways, arenaCentre) or nil
	local options = {}
	for team = 1, GameModes.TeamCount do
		local ruin = ruins[team]
		options[team] = {}
		if ruin then
			local gates = {
				{ position = ruin.frame * TeamBaseRuins.GateOut, heading = ruin.frame.LookVector },
				{ position = ruin.frame * TeamBaseRuins.GateOutEast, heading = ruin.frame.RightVector },
			}
			local base = { avoid = avoid, boxes = boxes, blocked = blocker(ruin), groundAt = groundAt, startY = ruin.height }
			if targets then
				for gi = 1, #gateways do
					local mine = {}
					for _, target in ipairs(targets) do
						if target.gateway == gi then
							table.insert(mine, target)
						end
					end
					if #mine > 0 then
						-- Several acceptable routes to each gateway (the junction nearer or further out along its
						-- road), so the fairest pair can be found among them.
						base.targets = mine
						base.collect = 6
						local plans, why = TeamBaseRoads.Plan(gates, nil, roads, base)
						base.collect = nil
						if plans then
							for _, plan in ipairs(plans) do
								table.insert(options[team], plan)
							end
						else
							ruin.accessWhy = why
						end
					end
				end
			end
			if #options[team] == 0 then
				-- No gateway reachable: at least onto the map's roads, which run on to the arena.
				base.targets = nil
				base.collect = 6
				local plans, why = TeamBaseRoads.Plan(gates, nil, roads, base)
				base.collect = nil
				for _, plan in ipairs(plans or {}) do
					-- On along the map's roads to the nearest gateway, for the fairness sum; a road that never
					-- reaches one is no way to the arena (unless there are no gateways at all).
					local on, gi = nil, nil
					if #gateways > 0 then
						on, gi = TeamBaseRoads.DistanceToGateway(roads, plan, gateways)
					end
					if on or #gateways == 0 then
						plan.total, plan.gateway = plan.length + (on or 0), gi
						table.insert(options[team], plan)
					end
				end
				if #options[team] == 0 then
					ruin.accessWhy = why
					warn("ModeTeams: team " .. team .. "'s base has no access road: " .. tostring(why))
				end
			end
		end
	end
	local chosen, gap = TeamBaseRoads.ChooseFair(options[1] or {}, options[2] or {}, FAIR_SHARE)
	-- Still unfair: the shorter way joins its gateway's road further out (it drives more of that road),
	-- by the difference, up to three times.
	for _ = 1, 3 do
		if not (gap and gap > FAIR_SHARE and chosen[1] and chosen[2] and targets) then
			break
		end
		local short = chosen[1].total < chosen[2].total and 1 or 2
		local plan, want = chosen[short], chosen[3 - short].total * (1 - FAIR_SHARE * 0.6)
		local mine = {}
		for _, target in ipairs(targets) do
			if target.gateway == plan.gateway and target.edge == plan.edge then
				local outward = target.lo > target.at and 1 or -1
				local extra = want - plan.total
				local copy = table.clone(target)
				if outward > 0 then
					copy.lo = math.max(target.lo, plan.along + extra)
				else
					copy.hi = math.min(target.hi, plan.along - extra)
				end
				table.insert(mine, copy)
			end
		end
		if #mine == 0 then
			break
		end
		local ruin = ruins[short]
		local gates = {
			{ position = ruin.frame * TeamBaseRuins.GateOut, heading = ruin.frame.LookVector },
			{ position = ruin.frame * TeamBaseRuins.GateOutEast, heading = ruin.frame.RightVector },
		}
		local longer = TeamBaseRoads.Plan(gates, nil, roads, { avoid = avoid, boxes = boxes, blocked = blocker(ruin), groundAt = groundAt,
			startY = ruin.height, targets = mine })
		if not longer then
			break
		end
		chosen[short] = longer
		local long = math.max(chosen[1].total, chosen[2].total)
		gap = math.abs(chosen[1].total - chosen[2].total) / math.max(long, 1)
	end
	if gap and gap > FAIR_SHARE then
		warn(string.format("ModeTeams: the bases' ways to the arena differ by %.0f%% (no fairer pair)", gap * 100))
	end
	for team = 1, GameModes.TeamCount do
		local ruin, plan = ruins[team], chosen[team]
		if ruin and plan and not ruin.accessRoad then
			-- Only what is in the chosen way goes.
			local clear = {}
			local check = blocker(ruin, clear)
			for i = 2, #plan.points do
				check(plan.points[i - 1], plan.points[i])
			end
			for item in pairs(clear) do
				item:Destroy()
			end
			local heights = plan.heights or TeamBaseRoads.Profile(plan, groundAt, ruin.height)
			TeamBaseRoads.SurfaceLift = MapTerrain.SurfaceLift or TeamBaseRoads.SurfaceLift
			pcall(TeamBaseRoads.ShapeGround, workspace.Terrain, plan, heights)
			ruin.accessRoad = TeamBaseRoads.Build(plan, heights, ruin.model)
			ruin.accessPlan = plan
			ruin.accessGateway = plan.gateway and gateways[plan.gateway] or nil
			local undo, gateNode = TeamBaseRoads.Register(roads, plan, heights)
			table.insert(accessUndo, undo)
			ruin.accessGateNode = gateNode
		end
	end
end

-- The points a base vehicle leaving its bay at `position` (nose `look`) drives through after its lane
-- to reach its base's access road (TeamBaseRoads.DriveVia), or nil when it is in no compound or there
-- is no road. BotService hands them to the drive after the lane.
function ModeTeams.BaseDriveVia(position, look)
	for _, ruin in pairs(ruins) do
		local plan = ruin.accessPlan
		if plan then
			local l = ruin.frame:PointToObjectSpace(position)
			if math.abs(l.X) <= TeamBaseRuins.Footprint.X / 2 and math.abs(l.Z) <= TeamBaseRuins.Footprint.Z / 2 then
				local lanes = TeamBaseRuins.Lanes
				-- The front corner on the east side, past both gates' ramps.
				local corner = Vector3.new(TeamBaseRuins.Footprint.X / 2 + 16, 0, -TeamBaseRuins.Footprint.Z / 2 - 16)
				local _ = lanes
				return TeamBaseRoads.DriveVia(ruin.frame, plan, look, corner)
			end
		end
	end
	return nil
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
	ModeTeams.ClearBattleground()
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
-- BEGIN BATTLEGROUND
--------------------------------------------------------------------------------
-- The battleground in the middle of a team match (TeamBattleground; Oliver, 2026-09-24: "make a way
-- better quality and more fun to play around battleground in the centre of the maps for the team
-- gamemodes"). Everything for it is in this block, apart from one call in Setup and one in Teardown.
-- tools/team_battleground_modeteams_check.py runs it.

local TeamBattleground = require(script.Parent:WaitForChild("TeamBattleground"))
-- How far from the middle the battleground and its apron reach, for RankBaseAxes' buffer.
ModeTeams.ArenaReach = TeamBattleground and ((TeamBattleground.Radius or 0) + (TeamBattleground.Margin or 0) + (TeamBattleground.Apron or 0)) or 0
local BotNav = require(script.Parent:WaitForChild("BotNav"))
local battleground = nil

-- Builds it at the arena's centre facing the bases (team 1's along the frame's LookVector, so the
-- mirror between its halves is the plane halfway between the two bases), from the match's one seed.
-- Returns it, or nil and why (warned when it was tried and failed): a failure costs the match its
-- battleground, never its start.
function ModeTeams.BuildBattleground(mapInfo, axis, seed)
	ModeTeams.ClearBattleground()
	if not (TeamBattleground and mapInfo and mapInfo.map and seed) then
		return nil, "no map or no seed"
	end
	local at = Vector3.new(arenaCentre.X, terrainAt(arenaCentre.X, arenaCentre.Z) or 0, arenaCentre.Z)
	local toTeamOne = Vector3.new(math.cos(axis), 0, math.sin(axis))
	local ok, built, why = pcall(TeamBattleground.Build, CFrame.lookAt(at, at + toTeamOne), mapInfo, seed)
	if not ok or type(built) ~= "table" then
		local reason = tostring(ok and why or built)
		warn("ModeTeams: no battleground: " .. reason)
		return nil, reason
	end
	battleground = built
	local seeded, problem = pcall(TeamBattleground.SeedLoot, built)
	if not seeded then
		warn("ModeTeams: battleground loot failed: " .. tostring(problem))
	end
	-- The bots take cover behind what it built (BotNav.FindCover asks this first).
	if BotNav then
		BotNav.CoverHints = function(origin, radius)
			return TeamBattleground.CoverNear(built, origin, radius)
		end
	end
	return built
end

-- The battleground standing in this match ({ model, objectives, cover, lootSpots, ... }), or nil.
function ModeTeams.Battleground()
	return active and battleground or nil
end

function ModeTeams.ClearBattleground()
	if BotNav then
		BotNav.CoverHints = nil
	end
	if battleground then
		TeamBattleground.Destroy(battleground)
		battleground = nil
	end
end

--------------------------------------------------------------------------------
-- END BATTLEGROUND
--------------------------------------------------------------------------------

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
-- vehicle's footprint (Sahur Van 9.0 wide; Crocodilo Ranger 19.04 long, its bull-bar gun's muzzle
-- included -- 17.4 before it had one; measured from VehicleModels by tools/team_base_ruins_check.py)
-- with half a stud all round, 8 high, from 0.6 over the floor. A car
-- put into a wreck, a driven-back car, a player or a deployable is two assemblies in one place, and
-- the physics shoves them apart into a pile (Oliver's playtest, 2026-09-24: "the vehicles in the team
-- bases are all messed up, like piled together").
local BAY_CLEAR = Vector3.new(10, 8, 20.1)
-- A vehicle put in a bay is held anchored this long, so nothing shoves it before it has settled.
local BAY_SETTLE_SECONDS = 1.5
-- Failed tries to find a free bay before a compound's slot takes a spot outside the bays.
local BAY_FALLBACK_FAILS = 2
-- A chassis less than this above FallenPartsDestroyHeight is below anything playable: lost.
local BELOW_MAP_MARGIN = 100

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

local personParams = OverlapParams.new()
personParams.FilterType = Enum.RaycastFilterType.Exclude
personParams.RespectCanCollide = false

-- Anyone (a player's or a bot's character) with any part in the box, collidable or not: a character's
-- root part does not always collide, and a car is never put into a person.
local function personIn(frame, size)
	personParams.FilterDescendantsInstances = { workspace.Terrain }
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame, size, personParams)) do
		local owner = part.Parent
		if owner and owner.FindFirstChildOfClass and owner:FindFirstChildOfClass("Humanoid")
			and (not part.CFrame or boxesOverlap(frame, size, part.CFrame, part.Size)) then
			return true
		end
	end
	return false
end

-- What may be cleared out of a bay so a vehicle can be parked in it: settled rubble (CollapseService
-- marks it Rubble) and the wreck of any vehicle, as the thing to remove. Never a live vehicle, a person,
-- a wall or a deployable. Oliver, 2026-09-25: the yards stand among buildings that now come down, and
-- a bay that took a slab of roof used to stay shut for the rest of the match.
local function clearable(part)
	if not part.GetAttribute then
		return nil
	end
	if part:GetAttribute("Rubble") == true then
		return part
	end
	local node = part.Parent
	while node and node ~= workspace do
		if node.GetAttribute and node:GetAttribute("Wrecked") == true then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Anything solid standing in the bay, or anyone in it. Rubble and wrecks are cleared out, but only
-- when nothing else blocks the bay (so they are never cleared for nothing).
local function bayOccupied(bay)
	bayParams.FilterDescendantsInstances = { workspace.Terrain }
	local look = bay.LookVector
	local frame = CFrame.new(bay.Position + Vector3.new(0, 0.6 + BAY_CLEAR.Y / 2, 0)) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
	if personIn(frame, BAY_CLEAR) then
		return true
	end
	local debris = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(frame, BAY_CLEAR, bayParams)) do
		-- A ball or cylinder is tested as its box: a little generous, never short.
		if part.CanCollide and (not part.CFrame or boxesOverlap(frame, BAY_CLEAR, part.CFrame, part.Size)) then
			local junk = clearable(part)
			if not junk then
				return true
			end
			debris[junk] = true
		end
	end
	for junk in pairs(debris) do
		junk:Destroy()
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
	return not personIn(frame, size)
end

-- The models for one base, rolled once and handed to both. "armed" is drawn from the ordinary cars that
-- carry a mount (VehicleModels.Mounts), "armored" from the armoured cars (drivableOnly, with a mount),
-- each in a fixed order so the roll is repeatable; "car" and "bike" are VehicleModels.Pick's, which
-- never gives an armoured car.
function ModeTeams.RollBaseVehicleModels(rng)
	local armed, armored = {}, {}
	for id, def in pairs(VehicleModels.Models) do
		if def.kind == "car" and VehicleModels.Mounts[id] then
			table.insert(def.drivableOnly and armored or armed, id)
		end
	end
	table.sort(armed)
	table.sort(armored)
	local ids = {}
	for _, slot in ipairs(MatchConfig.TeamBaseVehicles.Slots) do
		local id
		if slot == "armed" or slot == "armored" then
			local pool = (slot == "armored" and #armored > 0) and armored or armed
			id = #pool > 0 and pool[rng:NextInteger(1, #pool)] or nil
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
	-- again (BASE_VEHICLE_RETRY_MS) rather than dropping a car in a random spot round the walls --
	-- until it has waited BAY_FALLBACK_FAILS times: a bay can now be shut for good (a wall came down
	-- into it), and a base short a vehicle for the rest of the match is worse than one parked outside.
	if ModeTeams.BaseVehicleBays ~= nil and ModeTeams.BaseVehicleBays == ModeTeams.RuinBays
		and not (type(except) == "table" and (except.bayFails or 0) >= BAY_FALLBACK_FAILS) then
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

-- Anyone in any of its seats.
local function occupied(model)
	for _, seat in ipairs(model:GetDescendants()) do
		if (seat:IsA("VehicleSeat") or seat:IsA("Seat")) and seat.Occupant then
			return true
		end
	end
	return false
end

-- Terrain water filling the cell just over the chassis: the car has sunk.
local function submerged(position)
	local ok, full = pcall(function()
		local at = position + Vector3.new(0, 2, 0)
		local region = Region3.new(at - Vector3.new(1, 1, 1), at + Vector3.new(1, 1, 1)):ExpandToGrid(4)
		local materials, occupancies = workspace.Terrain:ReadVoxels(region, 4)
		for x = 1, #materials do
			for y = 1, #materials[x] do
				for z = 1, #materials[x][y] do
					if materials[x][y][z] == Enum.Material.Water and occupancies[x][y][z] >= 0.9 then
						return true
					end
				end
			end
		end
		return false
	end)
	return ok and full == true
end

-- Why `slot`'s vehicle no longer counts as the base's, or nil while it does. Lost: gone; wrecked; its
-- chassis broken off or deleted (the engine deletes whatever falls below FallenPartsDestroyHeight, and
-- a part-by-part delete leaves a parented model with no Wrecked); below the map; sunk with nobody in
-- it; or abandoned -- empty for AbandonSeconds more than AbandonDistance studs from the base. `nowMs`
-- (from the tick) advances the abandon clock; without it the last verdict stands.
local function lostReason(team, slot, nowMs)
	local model = slot.model
	if model == nil or model.Parent == nil then
		return "gone"
	end
	if model:GetAttribute("Wrecked") == true then
		return "wrecked"
	end
	local chassis = model.PrimaryPart
	if not chassis or not chassis.Parent then
		return "chassis"
	end
	local at = chassis.Position
	if at.Y < (workspace.FallenPartsDestroyHeight or -500) + BELOW_MAP_MARGIN then
		return "fell"
	end
	if occupied(model) then
		slot.emptySince, slot.abandoned = nil, nil
		return nil
	end
	if submerged(at) then
		return "drowned"
	end
	local config = MatchConfig.TeamBaseVehicles
	local base = bases[team]
	if base and config.AbandonDistance and flatDistance(at, base) > config.AbandonDistance then
		if nowMs then
			slot.emptySince = slot.emptySince or nowMs
			slot.abandoned = nowMs - slot.emptySince >= (config.AbandonSeconds or math.huge) * 1000
		end
		if slot.abandoned then
			return "abandoned"
		end
	else
		slot.emptySince, slot.abandoned = nil, nil
	end
	return nil
end

-- Live base vehicles of `team`, counted from the slots.
function ModeTeams.LiveBaseVehicles(team)
	local live = 0
	for _, slot in ipairs(baseSlots[team] or {}) do
		if not lostReason(team, slot) then
			live += 1
		end
	end
	return live
end

-- The slots of `team`, for the harness: { modelId, kind, model, lostAt, lostWhy, bayFails, ... }.
function ModeTeams.BaseVehicleSlots(team)
	return baseSlots[team] or {}
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
			-- One slot's failure never stops the others, nor the loop.
			local ok, problem = pcall(function()
				local why = lostReason(team, slot, nowMs)
				if not why then
					-- In use again (someone got back in, or drove it home): its clock starts afresh.
					slot.lostAt, slot.lostWhy = nil, nil
					return
				end
				if not slot.lostAt then
					slot.lostAt, slot.lostWhy = nowMs, why
				end
				if nowMs - slot.lostAt >= delayMs and ModeTeams.LiveBaseVehicles(team) < #slots then
					-- The wreck goes BEFORE its replacement is parked: it is still standing in its bay,
					-- and the bay test skips this slot's own vehicle, so the replacement used to be
					-- put into the wreck. Wrecking has already put everyone out of it; a lost vehicle
					-- that is no wreck (abandoned, sunk, broken) is empty, or it would not be lost.
					local wreck = slot.model
					slot.model = nil
					if wreck and wreck.Parent then
						wreck:Destroy()
					end
					if parkSlot(team, slot) then
						slot.bayFails, slot.lostWhy = nil, nil
					else
						slot.bayFails = (slot.bayFails or 0) + 1
						slot.lostAt = nowMs - delayMs + BASE_VEHICLE_RETRY_MS
					end
				end
			end)
			if not ok then
				warn("ModeTeams: base vehicle respawn failed: " .. tostring(problem))
				slot.lostAt = nowMs - delayMs + BASE_VEHICLE_RETRY_MS
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
			local ok, model = pcall(parkSlot, team, slot)
			if not ok then
				warn("ModeTeams: parking a base vehicle failed: " .. tostring(model))
			end
			if ok and model then
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
			local ok, problem = pcall(ModeTeams.TickBaseVehicles, protectionNowMs())
			if not ok then
				warn("ModeTeams: base vehicle tick failed: " .. tostring(problem))
			end
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

-- BEGIN TEAM PICKER (additive; TeamPicker.Close is the only writer). The sides the team picker settled
-- on, token -> 1 | 2, for players who have not been dealt yet. Assign honours a player's entry and
-- consumes it; for everyone else (bots, late joiners) the entries still waiting count as seats taken,
-- so a bot dealt before a picked player's body arrives fills the OTHER side. Not cleared by Teardown:
-- the picker closes before Setup runs. Replaced whole by the next SetPicks; Forget drops a leaver's.
local picks = {}

function ModeTeams.SetPicks(map)
	picks = {}
	for token, team in pairs(map or {}) do
		if team == 1 or team == 2 then
			picks[token] = team
		end
	end
end

function ModeTeams.PickOf(token)
	return picks[token]
end
-- END TEAM PICKER

-- Deals a combatant onto the smaller side, dealing alternately when they are level. Returns the
-- team index.
function ModeTeams.Assign(token)
	local existing = teamOf[token]
	if existing then
		return existing
	end
	local counts = ModeTeams.Counts()
	-- The team picker's side for this player, if it chose one (see SetPicks).
	local team = picks[token]
	if team then
		picks[token] = nil
	else
		for pending, side in pairs(picks) do
			if teamOf[pending] == nil then
				counts[side] += 1
			end
		end
		if counts[1] < counts[2] then
			team = 1
		elseif counts[2] < counts[1] then
			team = 2
		else
			team = nextTeam
			nextTeam = GameModes.OtherTeam(nextTeam) or 1
		end
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
	picks[token] = nil
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

-- Oliver 09-25 ("get rid of spawn prot"): every mode's spawnProtection is 0, so this grants nothing
-- and IsProtected is never true. The mechanism stays for a mode that wants it back.
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
-- In a compound the pads are 6.5 to 7.5 apart under one roof (TeamBaseRuins: 28 of them, for 25 a side),
-- so a pad counts as taken only when a body stands ON it: within PAD_CLEARANCE, a little more than a
-- character is wide. SPAWN_CLEARANCE is for the open ground, where "taken" means "too close".
local PAD_CLEARANCE = 3.5

-- The distance from `point` to the nearest living body other than `except` (math.huge when none).
-- `flat`: across the floor only, for a body standing on (or over) a pad -- its root is 3 or so up, so a
-- straight-line reading of a body ON the pad was 3+ and missed a clearance of 3.5 by height alone.
local function nearestBody(point, except, flat)
	local nearest = math.huge
	for character in pairs(Combatants.All()) do
		if character.Parent and character ~= except then
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local root = character:FindFirstChild("HumanoidRootPart")
			if humanoid and root and humanoid.Health > 0 then
				local offset = root.Position - point
				if flat then
					offset = math.abs(offset.Y) < 8 and Vector3.new(offset.X, 0, offset.Z) or offset
				end
				nearest = math.min(nearest, offset.Magnitude)
			end
		end
	end
	return nearest
end

local function occupiedAt(point, except, clearance)
	return nearestBody(point, except, clearance ~= nil) < (clearance or SPAWN_CLEARANCE)
end

-- `others` (optional) are the team's other pads. In a compound (Oliver, 2026-09-24: "make players and
-- bots spawn inside the bases") the answer is ALWAYS one of them: the pad itself when nobody stands on
-- it, else the nearest free pad, else -- every pad taken -- the pad with the most room round it. The ring
-- search below is for the open-ground pads only: from a compound it put bodies in the courtyard or
-- outside the walls (SPAWN_CLEARANCE is 20 and the pads are 7 apart, so with three people in the hall
-- every pad read as taken).
function ModeTeams.ClearSpotNear(pad, except, others, inCompound)
	if inCompound and others and #others > 0 then
		if not occupiedAt(pad, except, PAD_CLEARANCE) then
			return pad
		end
		local best, bestDistance, roomiest, room = nil, math.huge, nil, -1
		for _, other in ipairs(others) do
			local around = nearestBody(other, except, true)
			if around >= PAD_CLEARANCE and (other - pad).Magnitude < bestDistance then
				best, bestDistance = other, (other - pad).Magnitude
			end
			if around > room then
				roomiest, room = other, around
			end
		end
		return best or roomiest or pad
	end
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
	for _, entry in ipairs(GameModes.RollLoadout()) do
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
	-- Full shield on every spawn. SetShield clamps to MatchConfig.MaxShield.
	if GameModes.Loadout.fullShield then
		WeaponService.SetShield(player, math.huge)
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

	pad = ModeTeams.ClearSpotNear(pad, character, ruins[team] and pads[team] or nil, ruins[team] ~= nil)
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
