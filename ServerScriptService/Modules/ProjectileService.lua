-- Things that fly and blow up: launcher rounds, thrown grenades and smoke bombs.
--
-- Launcher rounds (WeaponData `projectile`): the Cappuccina Launcher's rocket and the Tralala Thumper's
-- 40mm grenade are real rounds with travel time and drop, not hitscan. They burst on whatever they
-- hit, or in the air at the end of their flight. A 40mm that hits something before it has armed is a
-- dud: it bounces and pops a moment later, so firing one into a wall at your feet hurts you rather
-- than them. Round kinds are a registry (Ballistics.Rounds): a new kind is a spec plus optional
-- behaviour callbacks, which this loop calls; nothing here needs editing for one.
-- A sniper's bullet (WeaponData `round`, Ballistics "sniperRound") is launched and flown the same way; where
-- it meets something, the hitscan rules decide what that does (CombatService.RuleBullet, via `api`).
--
-- Throwables (ItemData kind "throwable"): the Cooked Coconut is a frag. Hold the click to cook its
-- fuse, let go to throw; hold it too long and it goes off in your hand. The Lowkey Latte lands, hisses
-- and pours out a cloud nobody can see through, bots included.
--
-- Everything here is data stepped by the server: no server-side parts. Straight-line flight is
-- analytic and bouncing uses Ballistics.StepBody, so clients (ProjectileClient) replay the same paths
-- from a launch event plus a correction at each bounce, and the probe measures the same numbers.
--
-- Blasts: full damage near the centre, falling to a fifth at the edge (Ballistics.BlastScale).
-- Three lines from the blast to head, body and legs decide how exposed a victim is: a wall between
-- you and it takes all of it, glass doesn't. Your own blasts hurt you at half strength. A blast wears
-- down defenses and companions, sets off barrels, holes walls near its centre, shatters every pane in
-- reach, kicks grenades lying nearby, rocks vehicles and hurts them (VehicleService.BlastDamage: the
-- explosive class, the counter to a vehicle -- VehicleArmor), and reaches someone riding one at their
-- seat's share of its strength (VehicleCover.BlastShare: an armoured cabin VehicleArmor.CabinBlast).
--
--   ProjectileService.FireWeapon(token, weaponId, origin, aimPoint)       a launcher round (bots)
--   ProjectileService.Throw(token, itemId, targetPosition, options)       a lob onto a spot (bots)
--   ProjectileService.ProjectileInfo(id)          blast/fuse/range numbers for an item or launcher id
--   ProjectileService.LeadAim(weaponId, origin, target, targetVelocity)   where to aim a launcher
--   ProjectileService.Dangers(position, radius)   live frags and rounds that could reach `position`
--   ProjectileService.SmokeBlocks(from, to)       whether smoke hides `to` from `from`
--   ProjectileService.CancelCook(player)          the pin back in: a cook that was never thrown
--   ProjectileService.Clear()                     everything gone, for a new match
--   ProjectileService.Step(dt)                    one tick (the probe drives this by hand)
--
-- Hooks it sets: CombatService.LaunchProjectile (a player's launcher shot), CombatService.SmokeBlocks
-- (bot line of sight), WeaponService.ThrowEffect (using a throwable).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local VehicleCover = require(Shared:WaitForChild("VehicleCover"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local RateLimit = require(script.Parent:WaitForChild("RateLimit"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local VehicleService = require(script.Parent:WaitForChild("VehicleService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local ProjectileService = {}

local UP = Vector3.yAxis

-- Share of a blast's damage that its owner takes.
local SELF_SCALE = 0.5
-- Exposure: a victim reached by a share `reach` of the three lines (head, body, legs) takes
-- EXPOSED_FLOOR + (1 - EXPOSED_FLOOR) * reach of the damage: 60% for one, 80% for two, all of it for
-- three. None reached takes nothing.
local EXPOSED_FLOOR = 0.4
-- Knockback at full strength, and the weakest blast that shoves anyone at all. It goes through
-- MovementService.Launch with kind "blast" (a plain velocity set that cancels climbs, vaults and
-- slides), and the velocity is held to the same bounds the client clamps a blast launch to.
local KNOCKBACK = true
local KNOCK_AWAY = 40
local KNOCK_UP = 22
local KNOCK_MIN = 0.25
local KNOCK_MAX_FLAT = 60
local KNOCK_MIN_Y, KNOCK_MAX_Y = -40, 70
-- A blast kicks thrown things lying or flying near it: this fast at the centre.
local KICK_SPEED = 34
-- Defenses take explosives harder than bullets; companions softer; barrels always go up to a blast
-- that reaches them.
local STRUCTURE_SCALE = 2
local COMPANION_SCALE = 0.6
local HAZARD_SCALE = 1.5
-- Walls, floors and roofs break within this share of the blast radius.
local WALL_REACH = 0.5
-- A bot's lob can't reach further than a player's hardest throw.
local THROW_RANGE = 72
-- A cook this close to the fuse is already too late.
local COOK_MARGIN = 0.05
-- Bounce corrections to clients: only contacts this hard, and not more often than this.
local BOUNCE_REPORT_SPEED = 4
local BOUNCE_REPORT_GAP = 0.06
-- While a body slides or rolls, clients get its state this often so their replay stays on it.
local SLIDE_REPORT_GAP = 0.3
-- Anything still around after this long, or fallen this far, is dropped.
local MAX_AGE = 30
local FLOOR_Y = -400

local fx = Remotes.Event("ProjectileFx")
local cookRemote = Remotes.Event("ThrowCook")

-- Live projectiles, oldest first. See newEntry.
local live = {}
-- Smoke clouds: { id, position, startedAt, spec }.
local clouds = {}
-- player -> { itemId, index, slot, startedAt } while a frag is being cooked in hand.
local cooks = {}
local nextId = 0
-- Seconds since the service started, advanced only by Step, so a probe stepping by hand gets the
-- same timings as the live loop.
local clock = 0
local autoStep = true
-- The toolkit handed to round behaviour callbacks; filled in once everything it offers exists.
local api

local function serverTime()
	return workspace:GetServerTimeNow()
end

-- Every client hears about launches, bounces and bursts. Not in edit mode (the probe), where there are
-- no clients to tell.
local function broadcast(action, info)
	if RunService:IsRunning() then
		fx:FireAllClients(action, info)
	end
end

-- A token that can still be credited: a player who has left is dropped, so nothing tries to send
-- them a hit marker.
local function creditable(token)
	if token ~= nil and Combatants.Exists(token) then
		return token
	end
	return nil
end

--------------------------------------------------------------------------------
-- Sweeping
--------------------------------------------------------------------------------

local function baseFilter(ownerCharacter, ownerToken)
	local filter = {}
	if ownerCharacter then
		table.insert(filter, ownerCharacter)
	end
	local companion = ownerToken and CombatService.CompanionOf and CombatService.CompanionOf(ownerToken)
	if companion then
		table.insert(filter, companion)
	end
	for _, name in ipairs({ "Loot", "Effects", "DeathFx" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	return filter
end

local function newParams(filter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
	return params
end

local function ignore(entry, instance)
	table.insert(entry.filter, instance)
	entry.params.FilterDescendantsInstances = entry.filter
end

local function combatantOf(instance)
	local model = instance:FindFirstAncestorOfClass("Model")
	local token = model and Combatants.FromCharacter(model) or nil
	if token and Combatants.IsAlive(token) then
		return token, model
	end
	return nil, nil
end

-- A body a round flies on through: a team-mate of its owner, by the mode's friendly-fire veto (the one
-- DealDamage asks), the way a bullet has since efccfa5 (Oliver, 2026-09-25). A round used to burst on
-- the team-mate in front, shielding the enemy behind and catching the shooter in their own blast. nil
-- veto (the battle royale) and anything thrown: nothing passes, as before. Returns the body's model.
local function mateInTheWay(entry, instance)
	if entry.thrown or not CombatService.DamageVeto then
		return nil
	end
	local owner = creditable(entry.owner)
	local token, model = combatantOf(instance)
	if owner == nil or token == nil or token == owner then
		return nil
	end
	return CombatService.DamageVeto(owner, token, entry.weaponId) and model or nil
end

-- A sweep from `origin` along `displacement` that returns the first thing that stops this projectile:
-- { Instance, Position, Normal, Distance }. Glass breaks and is swept past. Anything non-solid that
-- isn't a body (trigger volumes, invisible markers) is swept past too, and so is a round owner's
-- team-mate (mateInTheWay). Thrown things also pass through companions; rounds are soaked by them the
-- way bullets are.
local function sweep(entry, origin, radius, displacement)
	local length = displacement.Magnitude
	if length < 1e-5 then
		return nil
	end
	local unit = displacement / length
	local start = origin
	local travelled = 0
	for _ = 1, 8 do
		local result = workspace:Spherecast(start, radius, unit * (length - travelled), entry.params)
		if not result then
			return nil
		end
		local instance = result.Instance
		local at = travelled + result.Distance
		local mate = mateInTheWay(entry, instance)
		if CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(instance) then
			if CombatService.DamageDestructible then
				CombatService.DamageDestructible(creditable(entry.owner), instance, 1, entry.lastFrom or origin)
			end
			ignore(entry, instance)
		elseif mate then
			ignore(entry, mate)
		elseif CombatService.CompanionFromPart and CombatService.CompanionFromPart(instance) then
			if entry.thrown then
				ignore(entry, CombatService.CompanionFromPart(instance))
			else
				return { Instance = instance, Position = result.Position, Normal = result.Normal, Distance = at }
			end
		elseif instance:IsA("BasePart") and not instance.CanCollide and not combatantOf(instance) then
			ignore(entry, instance)
		else
			return { Instance = instance, Position = result.Position, Normal = result.Normal, Distance = at }
		end
		-- Carry on from where the sphere was when it met the thing it passed.
		travelled = math.min(length, at)
		start = origin + unit * travelled
	end
	return nil
end

--------------------------------------------------------------------------------
-- Blasts
--------------------------------------------------------------------------------

local exposureParams = RaycastParams.new()
exposureParams.FilterType = Enum.RaycastFilterType.Include
exposureParams.IgnoreWater = true

local function exposureFilter()
	local include = { workspace.Terrain }
	for _, name in ipairs({ "Map", "Defenses" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(include, instance)
		end
	end
	return include
end

-- Whether nothing solid lies between two points. Glass and non-solid parts don't count.
local function clearLine(from, to, include)
	exposureParams.FilterDescendantsInstances = include
	local origin = from
	for _ = 1, 5 do
		local delta = to - origin
		if delta.Magnitude < 0.05 then
			return true
		end
		local result = workspace:Raycast(origin, delta, exposureParams)
		if not result then
			return true
		end
		local instance = result.Instance
		local passable = instance.Name == DestructibleService.GlassName or (instance:IsA("BasePart") and not instance.CanCollide)
		if not passable then
			return false
		end
		origin = result.Position + delta.Unit * 0.05
	end
	return true
end

-- How much of a body a blast at `position` can reach: head, body and legs, a third each.
local function exposure(position, character, include)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return 0
	end
	local head = character:FindFirstChild("Head")
	local samples = {
		head and head.Position or root.Position + Vector3.new(0, 1.5, 0),
		root.Position,
		root.Position - Vector3.new(0, 2, 0),
	}
	local reached = 0
	for _, sample in ipairs(samples) do
		if clearLine(position, sample, include or exposureFilter()) then
			reached += 1
		end
	end
	return reached / #samples
end

local function glassInRadius(position, radius, ownerToken)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	local query = OverlapParams.new()
	query.FilterType = Enum.RaycastFilterType.Include
	query.FilterDescendantsInstances = { map }
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position, radius, query)) do
		if part.Name == DestructibleService.GlassName then
			DestructibleService.Damage(part, 1, ownerToken, position)
		end
	end
end

-- Grenades lying or bouncing near a blast get thrown by it.
local function kickBodies(centre, radius, sourceId)
	for _, entry in ipairs(live) do
		local body = entry.body
		if body and not entry.done and entry.id ~= sourceId then
			local offset = body.position - centre
			local distance = offset.Magnitude
			if distance < radius then
				local strength = 1 - distance / radius
				local away = distance > 0.1 and offset / distance or UP
				body.velocity += (away + Vector3.new(0, 0.8, 0)).Unit * (KICK_SPEED * strength)
				body.resting = false
				entry.lastReportAt = entry.age
				broadcast("state", {
					id = entry.id,
					position = body.position,
					velocity = body.velocity,
					t = serverTime(),
					resting = false,
				})
			end
		end
	end
end

-- A combatant's team in a team mode, or nil. Required lazily and guarded, the way CompanionService
-- does: ModeTeams is optional to this module.
local modeTeams = nil
local function teamOf(token)
	if modeTeams == nil then
		local module = script.Parent:FindFirstChild("ModeTeams")
		local ok, result = false, nil
		if module then
			ok, result = pcall(require, module)
		end
		modeTeams = ok and type(result) == "table" and result or false
	end
	if not modeTeams or not modeTeams.TeamOf or token == nil then
		return nil
	end
	local ok, team = pcall(modeTeams.TeamOf, token)
	return ok and team or nil
end

-- A team-mate of a round's owner whom DealDamage's veto can no longer protect: ModeTeams forgets a
-- thrower who leaves, and a bot the moment it dies (GameMode.retireBot), while its frag, sticky or
-- rocket is still live. The team stamped on the round at launch still keeps it off their side. While
-- the `attacker` DealDamage is handed (the creditable owner) still has that team, the veto decides, as
-- for any hit. `round` is a live entry or a blast.
local function forgottenMate(round, attacker, victimToken)
	local team = round.ownerTeam
	return team ~= nil and victimToken ~= round.owner and teamOf(victimToken) == team and teamOf(attacker) ~= team
end

-- The blast itself. `blast` = { id, kind, owner, weaponId, position, normal, damage, radius,
-- innerRadius, wallDamage, direct = { token, bonus, headshot, multiplier }?, spare = fn(character)? }.
-- `spare`, when set, keeps the blast's damage (and so its shove) off any victim it returns true for:
-- a companion blast passes CompanionService's underCanopy, so it never hurts a parachuter. Returns a list of
-- { token, amount, scale, reach, headshot } for everyone it hurt, for the probe.
local function explode(blast)
	local owner = creditable(blast.owner)
	local position = blast.position
	-- Measured a hair off the surface it hit, so the lines to victims don't start inside the wall.
	local centre = position + (blast.normal or Vector3.zero) * 0.3
	local radius = blast.radius
	local include = exposureFilter()
	local dealt = {}

	broadcast("detonate", {
		id = blast.id,
		position = position,
		normal = blast.normal,
		kind = blast.kind,
		radius = radius,
		-- Which gun or item it was, so a silly one draws its own themed blast (SillyExplosionFx). Look only.
		weaponId = blast.weaponId,
	})

	for _, victim in ipairs(CombatService.InRadius(centre, radius + Ballistics.BodyAllowance, nil)) do
		local distance = math.max(0, (victim.root.Position - centre).Magnitude - Ballistics.BodyAllowance)
		local scale = Ballistics.BlastScale(distance, blast.innerRadius or 0, radius)
		local direct = blast.direct ~= nil and blast.direct.token == victim.token
		local reach = direct and 1 or exposure(centre, victim.root.Parent, include)
		if scale > 0 and reach > 0 then
			local amount = blast.damage * scale * (EXPOSED_FLOOR + (1 - EXPOSED_FLOOR) * reach)
			-- The direct victim's bonus carries the headshot multiplier; the blast part never does.
			local headshot = direct and blast.direct.headshot == true
			if direct then
				amount += (blast.direct.bonus or 0) * (blast.direct.multiplier or 1)
			end
			if victim.token == blast.owner then
				amount *= SELF_SCALE
			end
			-- Riding a vehicle, its body takes part of it (VehicleCover: an armoured cabin most, a car's
			-- cabin some, a bike or a truck bed next to none); the vehicle takes its own share of the blast
			-- below (VehicleService.BlastDamage), and a wreck covers nobody.
			amount *= VehicleCover.BlastShareFor(victim.root.Parent)
			local taken = 0
			-- A thrower who has left, or a bot retired on death, is forgotten by ModeTeams, but the team
			-- stamped on the round at launch still keeps friendly fire off their teammates.
			if not forgottenMate(blast, owner, victim.token) and not (blast.spare and blast.spare(victim.root.Parent)) then
				taken = CombatService.DealDamage(owner, victim.token, amount, blast.weaponId, headshot)
			end
			table.insert(dealt, { token = victim.token, amount = taken, scale = scale, reach = reach, headshot = headshot })

			local strength = scale * reach
			-- No shove where the hit was refused (a teammate, spawn protection): a vetoed frag mustn't fling them.
			if KNOCKBACK and taken > 0 and strength >= KNOCK_MIN and victim.humanoid.Health > 0 then
				local away = victim.root.Position - centre
				away = Vector3.new(away.X, 0, away.Z)
				away = away.Magnitude > 0.1 and away.Unit or Vector3.zero
				local velocity = victim.root.AssemblyLinearVelocity + away * (KNOCK_AWAY * strength) + UP * (KNOCK_UP * strength)
				local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
				if flatVelocity.Magnitude > KNOCK_MAX_FLAT then
					flatVelocity = flatVelocity.Unit * KNOCK_MAX_FLAT
				end
				velocity = flatVelocity + UP * math.clamp(velocity.Y, KNOCK_MIN_Y, KNOCK_MAX_Y)
				if SafeValue.Vector3(velocity) then
					MovementService.Launch(victim.root.Parent, velocity, "blast")
				end
			end
		end
	end

	if CombatService.DamageStructuresInRadius then
		CombatService.DamageStructuresInRadius(centre, radius, blast.damage * STRUCTURE_SCALE)
	end
	if owner and CombatService.DamageCompanionsInRadius then
		CombatService.DamageCompanionsInRadius(owner, centre, radius, blast.damage * COMPANION_SCALE)
	end
	if CombatService.DamageHazardsInRadius then
		CombatService.DamageHazardsInRadius(centre, radius, blast.damage * HAZARD_SCALE, owner)
	end
	if CombatService.DamageDestructiblesInRadius and (blast.wallDamage or 0) > 0 then
		CombatService.DamageDestructiblesInRadius(centre, radius * WALL_REACH, blast.wallDamage, owner)
	end
	glassInRadius(centre, radius, owner)
	kickBodies(centre, radius, blast.id)
	if VehicleService.ApplyBlast then
		VehicleService.ApplyBlast(centre, radius, blast.damage)
	end
	if VehicleService.BlastDamage then
		VehicleService.BlastDamage(blast)
	end
	return dealt
end

--------------------------------------------------------------------------------
-- Live entries
--------------------------------------------------------------------------------

-- One live projectile. Rounds carry { origin, direction } ("line"), { position, velocity } ("free"),
-- or a `body` ("body" motion, duds and everything thrown).
local function newEntry(ownerToken, character, kindName, spec, weaponId)
	nextId += 1
	local filter = baseFilter(character, ownerToken)
	local entry = {
		id = nextId,
		kindName = kindName,
		spec = spec,
		owner = ownerToken,
		-- Stamped at launch: a thrower who leaves is forgotten by ModeTeams at once, and their round
		-- still has to keep off their team.
		ownerTeam = teamOf(ownerToken),
		weaponId = weaponId,
		gravity = workspace.Gravity,
		age = 0,
		lastReportAt = -1,
		contacts = 0,
		filter = filter,
		params = newParams(filter),
	}
	table.insert(live, entry)
	return entry
end

local function report(entry, contact)
	entry.lastReportAt = entry.age
	local body = entry.body
	local now = serverTime()
	broadcast("state", {
		id = entry.id,
		position = body and body.position or entry.position,
		velocity = body and body.velocity or entry.velocity,
		t = now,
		resting = body and body.resting or false,
		bounce = contact and contact.speed or nil,
		body = body ~= nil,
		-- A dud's fuse, so clients can warn whoever it landed beside.
		fuseAt = entry.fuseAt and (now + entry.fuseAt - entry.age) or nil,
	})
end

local function remove(entry)
	entry.done = true
	broadcast("remove", { id = entry.id })
end

-- A round or grenade going off where it is: a blast, or for a non-explosive round just a hit on
-- whoever it struck.
--
-- `headshot`: the round itself struck the Head part (contactRound decides). The direct part of the
-- damage (the impact bonus, or all of it for a non-explosive round) takes the gun's
-- headshotMultiplier and the match's HeadshotScale, and the victim's one damage event is flagged a
-- headshot (gold marker, stats, Headhunter). The blast is never a headshot, for anyone, and a
-- thrown item has no gun behind it, so it never is either.
local function burst(entry, position, normal, directToken, headshot)
	entry.done = true
	local spec = entry.spec
	local multiplier = 1
	if headshot and directToken and entry.def then
		multiplier = (entry.def.headshotMultiplier or 1) * (CombatService.HeadshotScale or 1)
	else
		headshot = false
	end
	local blast = {
		id = entry.id,
		kind = entry.kindName,
		owner = entry.owner,
		ownerTeam = entry.ownerTeam,
		weaponId = entry.weaponId,
		position = position,
		normal = normal,
		damage = entry.damage,
		radius = entry.radius,
		innerRadius = spec.innerRadius or 0,
		wallDamage = spec.wallDamage or 0,
		direct = directToken and { token = directToken, bonus = spec.impactBonus or 0, headshot = headshot, multiplier = multiplier } or nil,
		-- A round that struck a vehicle's hull: that vehicle takes the impact bonus as well (BlastDamage).
		directVehicle = entry.directVehicle,
		directBonus = entry.directVehicle and (spec.impactBonus or 0) or nil,
	}
	if spec.onDetonate and spec.onDetonate(entry, blast, api) == false then
		broadcast("remove", { id = entry.id })
		return nil
	end
	if spec.explosive == false then
		broadcast("impact", { id = entry.id, position = position, normal = normal, kind = entry.kindName, weaponId = entry.weaponId })
		local direct = blast.direct
		local attacker = creditable(entry.owner)
		if direct and not forgottenMate(entry, attacker, direct.token) then
			local amount = (blast.damage + (direct.bonus or 0)) * (direct.multiplier or 1)
			CombatService.DealDamage(attacker, direct.token, amount, entry.weaponId, direct.headshot == true)
		end
		return nil
	end
	return explode(blast)
end

-- `def.round`: a hitscan gun whose bullet flies (the snipers), launched the same way as a launcher's round.
local function launchRound(ownerToken, def, origin, direction)
	local kind = def and (def.projectile or def.round)
	local spec = kind and Ballistics.Rounds[kind]
	if not spec or not SafeValue.Vector3(origin) or not SafeValue.Vector3(direction) or direction.Magnitude < 0.5 then
		return nil
	end
	direction = direction.Unit
	local character = Combatants.GetCharacter(ownerToken)
	local entry = newEntry(ownerToken, character, kind, spec, def.id)
	entry.def = def
	entry.damage = def.damage
	entry.radius = def.splashRadius or 12
	entry.lastFrom = origin
	local motion = spec.motion or "line"
	entry.motion = motion
	if motion == "body" then
		entry.body = { position = origin, velocity = direction * spec.speed, spec = spec, resting = false }
		entry.fuseAt = spec.fuse
	elseif motion == "free" then
		entry.position = origin
		entry.velocity = direction * spec.speed
	else
		entry.origin = origin
		entry.direction = direction
		entry.position = origin
	end
	if spec.onLaunch then
		spec.onLaunch(entry, api)
	end
	broadcast("round", {
		id = entry.id,
		kind = entry.kindName,
		motion = motion,
		weaponId = def.id,
		origin = origin,
		direction = direction,
		velocity = entry.body and entry.body.velocity or entry.velocity,
		gravity = entry.gravity,
		radius = spec.explosive ~= false and entry.radius or nil,
		t = serverTime(),
		shooter = character,
	})
	return entry
end

local function spawnThrown(ownerToken, character, itemId, spec, origin, velocity, cooked)
	local entry = newEntry(ownerToken, character, spec.kind, spec, itemId)
	entry.thrown = true
	entry.itemId = itemId
	entry.damage = spec.blastDamage
	entry.radius = spec.blastRadius
	entry.lastFrom = origin
	entry.body = { position = origin, velocity = velocity, spec = spec, resting = false }
	if spec.kind == "frag" then
		entry.fuseAt = math.max(0, spec.fuse - (cooked or 0))
	end
	local now = serverTime()
	broadcast("throw", {
		id = entry.id,
		item = itemId,
		position = origin,
		velocity = velocity,
		gravity = entry.gravity,
		t = now,
		thrower = character,
		fuseAt = entry.fuseAt and now + entry.fuseAt or nil,
	})
	return entry
end

-- Where a throw leaves the hand: in front of the head, unless a wall is closer than that.
local function handOrigin(filter, head, direction, radius)
	local wanted = Ballistics.ThrowOrigin(head, direction)
	local result = workspace:Raycast(head, wanted - head, newParams(filter))
	if result then
		return head + direction * math.max(0, result.Distance - radius - 0.05)
	end
	return wanted
end

-- The driver of a vehicle has both hands on the wheel: no throwing, no cooking (passengers may).
local function driving(player)
	return CombatService.IsDriving ~= nil and CombatService.IsDriving(player) == true
end

-- The use flow: a player throws what's in their hand toward `aimPoint`. Returns true if it went.
local function throwFromPlayer(player, itemId, aimPoint)
	local spec = Ballistics.Throwables[itemId]
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not spec or not head or not root or not Combatants.IsAlive(player) then
		cooks[player] = nil
		return false
	end
	if driving(player) then
		-- Sitting down at the wheel puts the pin back in.
		cooks[player] = nil
		return false
	end

	local cook = cooks[player]
	cooks[player] = nil
	local cooked = 0
	if cook and cook.itemId == itemId and spec.cookable then
		cooked = math.clamp(clock - cook.startedAt, 0, spec.fuse)
	end

	-- Held too long: it goes off in the hand.
	if spec.cookable and cooked >= spec.fuse - COOK_MARGIN then
		spawnThrown(player, character, itemId, spec, head.Position, Ballistics.CarrierVelocity(root.AssemblyLinearVelocity), spec.fuse)
		return true
	end

	local target = SafeValue.Vector3(aimPoint) and aimPoint or head.Position + root.CFrame.LookVector * 30
	local direction = Ballistics.ThrowDirection(spec, head.Position, target)
	local origin = handOrigin(baseFilter(character, player), head.Position, direction, spec.radius)
	local velocity = Ballistics.ThrowVelocity(spec, head.Position, target, root.AssemblyLinearVelocity)
	spawnThrown(player, character, itemId, spec, origin, velocity, cooked)
	return true
end

--------------------------------------------------------------------------------
-- Stepping
--------------------------------------------------------------------------------

local function deploySmoke(entry)
	entry.done = true
	local spec = entry.spec
	local cloud = {
		id = entry.id,
		position = entry.body.position,
		startedAt = clock + spec.hiss,
		spec = spec,
	}
	table.insert(clouds, cloud)
	broadcast("smoke", {
		id = entry.id,
		item = entry.itemId,
		position = cloud.position,
		t = serverTime() + spec.hiss,
	})
end

-- A straight-flying round meets something: burst, turn into a bouncing dud, stop, or fly through.
local function contactRound(entry, hit, centre, velocity)
	local spec = entry.spec
	local verdict = spec.onContact and spec.onContact(entry, hit, api) or nil
	if not verdict then
		verdict = entry.age < (spec.armTime or 0) and "dud" or "detonate"
	end
	if verdict == "pass" then
		ignore(entry, hit.Instance)
		return false
	elseif verdict == "stop" then
		remove(entry)
	elseif verdict == "dud" or verdict == "bounce" then
		local into = velocity:Dot(hit.Normal)
		local reflected = velocity - hit.Normal * (into * (1 + (spec.restitution or 0.3)))
		entry.body = { position = centre + hit.Normal * 0.05, velocity = reflected * 0.6, spec = spec, resting = false }
		if verdict == "dud" then
			entry.fuseAt = entry.age + (spec.dudFuse or 0.8)
		end
		report(entry, { speed = math.abs(into) })
	else
		-- A round in flight meeting a head is a headshot; a dud that bounces into one later is not.
		local directToken = combatantOf(hit.Instance)
		entry.directVehicle = CombatService.VehicleFromPart and CombatService.VehicleFromPart(hit.Instance) or nil
		burst(entry, hit.Position, hit.Normal, directToken, directToken ~= nil and hit.Instance.Name == "Head")
	end
	return true
end

local function stepRound(entry, dt)
	entry.age += dt
	local spec = entry.spec
	local position, velocity
	if entry.motion == "free" then
		-- The same step the client replays (Ballistics.FreeStep), with the server's own tools.
		position, velocity = Ballistics.FreeStep(entry, dt, entry.gravity, api)
	else
		position, velocity = Ballistics.RoundState(spec, entry.origin, entry.direction, entry.gravity, entry.age)
	end
	-- A round that ends at its gun's reach (`stopAtRange`: a sniper's bullet, as the hitscan shot it was)
	-- flies no further, so nothing past there is touched, not even a pane the sweep would break.
	local reach = spec.stopAtRange and entry.origin and entry.def and entry.def.range
	local spent = false
	if reach and (position - entry.origin).Magnitude >= reach then
		position = entry.origin + (position - entry.origin).Unit * reach
		spent = true
	end

	-- A "pass" verdict sweeps the same step again without the thing it flew through.
	for _ = 1, 4 do
		local displacement = position - entry.position
		local hit = sweep(entry, entry.position, spec.radius, displacement)
		if not hit then
			break
		end
		local centre = entry.position + displacement.Unit * hit.Distance
		if contactRound(entry, hit, centre, velocity) then
			return
		end
	end

	entry.lastFrom = entry.position
	entry.position = position
	entry.velocity = velocity
	if entry.motion == "free" and spec.syncEvery and entry.age - entry.lastReportAt >= spec.syncEvery then
		report(entry, nil)
	end
	if spent or entry.age >= spec.maxTime then
		burst(entry, position, nil, nil)
	end
end

local function stepBody(entry, dt)
	entry.age += dt
	local body = entry.body
	local spec = entry.spec
	local wasResting = body.resting

	-- Stuck to something: it rides with that part until its fuse runs out. If the part is gone (a
	-- wall blown out, a vehicle wrecked and cleared) it goes off where it last was.
	if entry.stuck then
		local stuck = entry.stuck
		local part = stuck.part
		if part.Parent then
			body.position = part.CFrame:PointToWorldSpace(stuck.localPosition)
			entry.stuckNormal = part.CFrame:VectorToWorldSpace(stuck.localNormal)
		else
			entry.fuseAt = entry.age
		end
		if entry.age >= entry.fuseAt then
			burst(entry, body.position, entry.stuckNormal, (combatantOf(part)))
		end
		return
	end

	local contact = Ballistics.StepBody(body, dt, entry.gravity, function(origin, radius, displacement)
		return sweep(entry, origin, radius, displacement)
	end)

	-- A sticky sticks to the first thing it touches, wherever that is on it, and its fuse starts then.
	if contact and spec.kind == "sticky" and contact.instance then
		local part = contact.instance
		local normal = contact.normal
		local position = contact.position + normal * spec.radius
		entry.contacts += 1
		entry.stuck = {
			part = part,
			localPosition = part.CFrame:PointToObjectSpace(position),
			localNormal = part.CFrame:VectorToObjectSpace(normal),
		}
		entry.stuckNormal = normal
		body.position = position
		body.velocity = Vector3.zero
		body.resting = true
		entry.fuseAt = entry.age + spec.fuse
		broadcast("stuck", {
			id = entry.id,
			part = part,
			position = entry.stuck.localPosition,
			normal = entry.stuck.localNormal,
			at = contact.position,
			fuseAt = serverTime() + spec.fuse,
		})
		return
	end

	if contact then
		entry.contacts += 1
		local verdict = not entry.thrown and spec.onContact and spec.onContact(entry, contact, api) or nil
		if not verdict and (spec.kind == "impact" or spec.impact) then
			verdict = "detonate"
		end
		if not verdict and spec.maxBounces and entry.contacts >= spec.maxBounces then
			verdict = "detonate"
		end
		if verdict == "detonate" then
			local direct = contact.instance and combatantOf(contact.instance) or nil
			burst(entry, contact.position, contact.normal, direct)
			return
		elseif verdict == "stop" then
			remove(entry)
			return
		end
	end

	if contact and contact.speed >= BOUNCE_REPORT_SPEED and entry.age - entry.lastReportAt >= BOUNCE_REPORT_GAP then
		report(entry, contact)
	elseif body.resting and not wasResting then
		report(entry, nil)
	elseif not body.resting and contact and entry.age - entry.lastReportAt >= SLIDE_REPORT_GAP then
		report(entry, nil)
	end

	if entry.fuseAt and entry.age >= entry.fuseAt then
		burst(entry, body.position, body.resting and UP or nil, nil)
		return
	end

	if spec.kind == "smoke" and (body.resting or entry.age >= spec.deployAfter) then
		deploySmoke(entry)
		return
	end

	if body.position.Y < FLOOR_Y or entry.age > MAX_AGE then
		remove(entry)
	elseif not entry.thrown and not entry.fuseAt and entry.age >= (spec.maxTime or MAX_AGE) then
		-- A bouncing round that never met its fuse or its last bounce goes off where it lies.
		burst(entry, body.position, body.resting and UP or nil, nil)
	end
end

-- Cooking only happens while the match is being played: CombatService is switched on for exactly that
-- (MatchService, InProgress). Missing in a stripped-down harness: as before, always.
local function matchLive()
	return CombatService.IsEnabled == nil or CombatService.IsEnabled() == true
end

local function stepCooks()
	for player, cook in pairs(cooks) do
		local loadout = WeaponService.Get(player)
		local slot = loadout and loadout.equipped and loadout.slots[loadout.equipped]
		local spec = Ballistics.Throwables[cook.itemId]
		if not player.Parent or not Combatants.IsAlive(player) or not loadout or loadout.equipped ~= cook.index or slot ~= cook.slot or not matchLive() then
			-- Put away, dropped or dead, or the match over (the release is refused on the results screen,
			-- and the frag must not go off there): the cook is off (the pin goes back in).
			cooks[player] = nil
		elseif clock - cook.startedAt >= spec.fuse - COOK_MARGIN then
			-- Too late. Using it now goes through the normal spend, and throwFromPlayer sees the cook.
			-- A refusal can be momentary (the instant-item cooldown, a use in progress), so try again
			-- next step rather than quietly handing back a fresh fuse; give up a second past it.
			if not WeaponService.StartUse(player, nil) and clock - cook.startedAt >= spec.fuse + 1 then
				cooks[player] = nil
			end
		end
	end
end

function ProjectileService.Step(dt)
	clock += dt
	-- Stepped from a snapshot of the list: a blast's damage can end the match, and Clear() then
	-- replaces `live` under this loop.
	local list = live
	for index = #list, 1, -1 do
		local entry = list[index]
		if entry and not entry.done then
			if entry.body then
				stepBody(entry, dt)
			else
				stepRound(entry, dt)
			end
		end
		if entry and entry.done then
			table.remove(list, index)
		end
	end
	for index = #clouds, 1, -1 do
		if clock >= Ballistics.SmokeEndsAt(clouds[index]) then
			table.remove(clouds, index)
		end
	end
	stepCooks()
end

-- The probe steps by hand; the live loop would step the same projectiles a second time.
function ProjectileService.SetAutoStep(value)
	autoStep = value == true
end

function ProjectileService.Clock()
	return clock
end

RunService.Heartbeat:Connect(function(dt)
	if autoStep then
		ProjectileService.Step(math.min(dt, 0.1))
	end
end)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Living combatants within `radius` of `position`, nearest first, leaving out `exceptToken`.
local function targets(position, radius, exceptToken)
	local found = CombatService.InRadius(position, radius, exceptToken)
	table.sort(found, function(a, b)
		return (a.root.Position - position).Magnitude < (b.root.Position - position).Magnitude
	end)
	return found
end

api = {
	Explode = explode,
	Burst = burst,
	DealDamage = CombatService.DealDamage,
	-- The owner to credit a hit to, or nil once they have left (a round's own hits, as burst credits them).
	Creditable = creditable,
	-- (entry, attacker, victimToken): a team-mate of an owner ModeTeams has forgotten, whom that hit
	-- must skip, as burst and explode do.
	ForgottenMate = forgottenMate,
	Targets = targets,
	Exposure = exposure,
	Report = report,
	Remove = remove,
	Clock = function()
		return clock
	end,
	-- For a flying bullet (a sniperRound): the hitscan rules where it lands (CombatService.RuleBullet), and
	-- a new round (its bank off a wall) launched as a gun's: (ownerToken, def, origin, direction).
	RuleBullet = CombatService.RuleBullet,
	Launch = launchRound,
}
ProjectileService.Api = api

-- A launcher round from `origin` toward `aimPoint`, for a bot holding a projectile gun. Broadcasts the
-- shot (flash and report); pacing and ammo are the caller's.
function ProjectileService.FireWeapon(shooterToken, weaponId, origin, aimPoint)
	local def = WeaponData.Get(weaponId)
	if not def or not def.projectile or not Combatants.IsAlive(shooterToken) then
		return false
	end
	if not SafeValue.Vector3(origin) or not SafeValue.Vector3(aimPoint) or (aimPoint - origin).Magnitude < 0.5 then
		return false
	end
	if not launchRound(shooterToken, def, origin, (aimPoint - origin).Unit) then
		return false
	end
	CombatService.BroadcastShot(shooterToken, origin, {}, def.rarity)
	return true
end

-- A lob onto `targetPosition`, for a bot. options.cook: seconds of fuse already burned. Spends nothing.
function ProjectileService.Throw(token, itemId, targetPosition, options)
	local spec = Ballistics.Throwables[itemId]
	local character = Combatants.GetCharacter(token)
	local head = character and character:FindFirstChild("Head")
	if not spec or not head or not Combatants.IsAlive(token) or not SafeValue.Vector3(targetPosition) then
		return false
	end
	local offset = targetPosition - head.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	if flat.Magnitude > THROW_RANGE then
		return false
	end
	local direction = flat.Magnitude > 0.1 and flat.Unit or -Vector3.zAxis
	local origin = handOrigin(baseFilter(character, token), head.Position, direction, spec.radius)
	local velocity = Ballistics.LobVelocity(origin, targetPosition, workspace.Gravity, spec.gravityScale)
	local cook = options and SafeValue.Number(options.cook, 60) and options.cook or 0
	spawnThrown(token, character, itemId, spec, origin, velocity, spec.fuse and math.clamp(cook, 0, spec.fuse - 0.3) or 0)
	return true
end

-- Numbers for a throwable item id or a launcher weapon id, or nil.
function ProjectileService.ProjectileInfo(id)
	local throwable = Ballistics.Throwables[id]
	if throwable then
		return {
			kind = throwable.kind,
			fuse = throwable.fuse,
			blastRadius = throwable.blastRadius,
			blastDamage = throwable.blastDamage,
			innerRadius = throwable.innerRadius,
			smokeRadius = throwable.smokeRadius,
			smokeDuration = throwable.smokeRadius and (throwable.grow + throwable.hold + throwable.fade) or nil,
			speed = throwable.speed,
			gravityScale = throwable.gravityScale,
			throwRange = THROW_RANGE,
		}
	end
	local def = WeaponData.Get(id)
	local spec = def and def.projectile and Ballistics.Rounds[def.projectile]
	if spec then
		return {
			kind = def.projectile,
			blastRadius = spec.explosive == false and 0 or (def.splashRadius or 12),
			blastDamage = def.damage,
			innerRadius = spec.innerRadius or 0,
			speed = spec.maxSpeed or spec.speed,
			gravityScale = spec.gravityScale,
		}
	end
	return nil
end
ProjectileService.ThrowableInfo = ProjectileService.ProjectileInfo

function ProjectileService.LeadAim(weaponId, origin, target, targetVelocity)
	local def = WeaponData.Get(weaponId)
	local kind = def and (def.projectile or def.round)
	local spec = kind and Ballistics.Rounds[kind]
	if not spec or (spec.motion or "line") ~= "line" then
		return target
	end
	return Ballistics.LeadAim(spec, origin, target, targetVelocity, workspace.Gravity)
end

-- Live frags and rounds whose blast could reach `position` within `radius` of it:
-- { position, radius, detonatesIn, owner, kind }. Only walks the live list.
function ProjectileService.Dangers(position, radius)
	local found = {}
	for _, entry in ipairs(live) do
		if not entry.done and entry.radius and entry.spec.explosive ~= false then
			local at, detonatesIn = nil, nil
			if entry.body then
				at = entry.body.position
				detonatesIn = entry.fuseAt and math.max(0, entry.fuseAt - entry.age) or nil
			else
				at = entry.position
				local speed = entry.velocity and entry.velocity.Magnitude or (entry.spec.maxSpeed or entry.spec.speed)
				detonatesIn = (position - at).Magnitude / math.max(1, speed)
			end
			if at and detonatesIn and (at - position).Magnitude <= radius + entry.radius then
				table.insert(found, {
					position = at,
					radius = entry.radius,
					detonatesIn = detonatesIn,
					owner = entry.owner,
					kind = entry.kindName,
				})
			end
		end
	end
	return found
end

function ProjectileService.SmokeBlocks(from, to)
	for _, cloud in ipairs(clouds) do
		if Ballistics.SmokeChord(cloud, from, to, clock) >= Ballistics.SeeThrough then
			return true
		end
	end
	return false
end

function ProjectileService.Clear()
	live = {}
	clouds = {}
	cooks = {}
	broadcast("clear", {})
end

-- For the probe and the build check: how many rounds, thrown or bouncing bodies and clouds are live.
function ProjectileService.Counts()
	local rounds, bodies = 0, 0
	for _, entry in ipairs(live) do
		if entry.body then
			bodies += 1
		else
			rounds += 1
		end
	end
	return rounds, bodies, #clouds
end

-- The probe's view of one projectile by id (nil once it's gone).
function ProjectileService.Peek(id)
	for _, entry in ipairs(live) do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

ProjectileService.Explode = explode
ProjectileService.LaunchRound = launchRound
ProjectileService.SpawnThrown = spawnThrown
ProjectileService.ThrowFromPlayer = throwFromPlayer
ProjectileService.Exposure = exposure
ProjectileService.AddCloud = function(position, itemId, startedAt)
	local cloud = { id = 0, position = position, startedAt = startedAt or clock, spec = Ballistics.Throwables[itemId or "LowkeyLatte"] }
	table.insert(clouds, cloud)
	return cloud
end

--------------------------------------------------------------------------------
-- Cooking and hooks
--------------------------------------------------------------------------------

-- The pin back in: a cook its thrower stopped without throwing (a menu opened, the match left
-- InProgress on their screen), or whose release the server turned down, is dropped instead of going
-- off in their hand a few seconds later. Not once the fuse is out: stepCooks is already setting it off,
-- and a fresh fuse is not handed back.
function ProjectileService.CancelCook(player)
	local cook = cooks[player]
	local spec = cook and Ballistics.Throwables[cook.itemId]
	if cook and (not spec or clock - cook.startedAt < spec.fuse - COOK_MARGIN) then
		cooks[player] = nil
	end
end

-- The press of a throw: start the fuse if a cookable throwable is in hand. The release comes through
-- the normal UseSelected remote. `pressed` false: the client stopped the cook without a throw
-- (CancelCook); it only ever takes a cook away, so it spends no rate-limit budget.
cookRemote.OnServerEvent:Connect(function(player, pressed)
	if pressed == false then
		ProjectileService.CancelCook(player)
		return
	end
	-- Rate-limited like the other combat remotes (claude-f5, 2026-09-17).
	if not RateLimit.Take(player, "Cook") then
		return
	end
	-- Not outside a live match: the release is refused there (Bootstrap's UseSelected), so the cook
	-- could only ever go off in the hand.
	if cooks[player] or not matchLive() or not Combatants.IsAlive(player) or driving(player) then
		return
	end
	local loadout = WeaponService.Get(player)
	local index = loadout and loadout.equipped
	local slot = index and loadout.slots[index]
	local spec = slot and slot.kind == "item" and Ballistics.Throwables[slot.id]
	local item = slot and ItemData.Get(slot.id)
	if not spec or not spec.cookable or not item or item.kind ~= "throwable" then
		return
	end
	if not WeaponService.IsReady(player) then
		return
	end
	cooks[player] = { itemId = slot.id, index = index, slot = slot, startedAt = clock }
	local head = player.Character and player.Character:FindFirstChild("Head")
	broadcast("cook", { thrower = player.Character, item = slot.id, position = head and head.Position or nil })
end)

Players.PlayerRemoving:Connect(function(player)
	cooks[player] = nil
end)

CombatService.LaunchProjectile = function(player, def, origin, direction)
	launchRound(player, def, origin, direction)
end
CombatService.SmokeBlocks = ProjectileService.SmokeBlocks
-- Explosive ammo (#122) goes off through this same blast, so a bullet's blast and a rocket's behave alike.
CombatService.Explode = explode
WeaponService.ThrowEffect = function(player, itemId, aimPoint)
	return throwFromPlayer(player, itemId, aimPoint)
end

return ProjectileService
