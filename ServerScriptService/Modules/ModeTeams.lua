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
	for team = 1, GameModes.TeamCount do
		local heading = axis + (team - 1) * math.pi
		local base = arenaCentre + Vector3.new(math.cos(heading), 0, math.sin(heading)) * (arenaRadius * BASE_FRACTION)
		pads[team] = ModeTeams.BuildPads(base, mapInfo)
		bases[team] = base
	end
	ModeTeams.MapRiver = mapInfo and mapInfo.river

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

-- Where the base loot goes (Oliver, 2026-09-23: "way more loot around the spawns of the teams"). Up to
-- `count` open-ground spots between `inner` and `outer` studs from the team's base, each passing the
-- same checks a spawn pad does (inside the arena, real ground, not in the river, nothing built on it)
-- and kept `gap` studs apart so pickups never sit in one another.
function ModeTeams.BaseLootSpots(team, count, inner, outer, gap)
	local base = bases[team]
	if not active or not base then
		return {}
	end
	inner, outer, gap = inner or 12, outer or 80, gap or 6
	local spots = {}
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
	active = false
	mode = nil
	table.clear(bases)
	table.clear(teamOf)
	table.clear(protectedUntil)
	table.clear(downed)
	pads = { {}, {} }
end

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

-- Protection ends the moment you take a swing, not when you move. Called from the fire and throw
-- paths; safe to call when nothing is protected.
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

function ModeTeams.ClearSpotNear(pad, except)
	if not occupiedAt(pad, except) then
		return pad
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

	pad = ModeTeams.ClearSpotNear(pad, character)
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
