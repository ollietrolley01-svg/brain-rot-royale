-- What a hit does besides damage: the creative guns' knockback, bleed, ignite and chill.
--
-- A CombatService.OnDamage listener, so it hooks itself in when required (Bootstrap requires it
-- beside HitSplatService). Every effect is read off the weapon's own WeaponData fields, so a gun opts
-- in by carrying the field and nothing here names a gun:
--
--   knockback = speed         the victim is shoved away from the shooter at this many studs/s, with a
--                             little lift (MovementService.Launch, kind "blast"; a player's own client
--                             applies it, capped at 60 studs/s across and -40..70 up)
--   bleed = { damage, duration }
--   ignite = { damage, duration }
--                             damage over time: `damage` in total, dealt in ticks across `duration`
--                             seconds through CombatService.DealDamage with the gun's weaponId, so a
--                             kill by the tick is credited to the shooter and the gun. A fresh hit
--                             refreshes the effect rather than stacking another.
--   chill = { slow, duration, stacks, freeze }
--                             each hit adds a stack (up to `stacks`), slowing by `slow` per stack for
--                             `duration` seconds (MatchService.SetStatusSpeed). The hit that would go
--                             past the last stack freezes the victim solid for `freeze` seconds and
--                             clears the stacks; a frozen victim can't be refrozen for FREEZE_IMMUNITY
--                             seconds, so a fast gun can't lock someone down forever.
--
-- A death, or combat switching off, clears everything on that combatant, the slows included.
--
-- Damage-over-time ticks call DealDamage, which tells every listener again; `ticking` makes sure a
-- tick never starts a new effect of its own.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ServerScriptService:WaitForChild("Modules")
local CombatService = require(Modules:WaitForChild("CombatService"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local MovementService = require(Modules:WaitForChild("MovementService"))
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))

local StatusEffects = {}

local TICK = 0.5
local KNOCKBACK_LIFT = 0.25
local FREEZE_IMMUNITY = 2.5

-- [victimToken] = { [kind] = { attacker, weaponId, perTick, ticksLeft } }
local dots = {}
-- [victimToken] = { stacks, expires, immuneUntil }
local chills = {}
local ticking = false

local function applyKnockback(attacker, victim, speed)
	local fromRoot, toRoot = Combatants.GetRoot(attacker), Combatants.GetRoot(victim)
	local character = Combatants.GetCharacter(victim)
	if not (fromRoot and toRoot and character) then
		return
	end
	local away = toRoot.Position - fromRoot.Position
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.01 then
		return
	end
	local velocity = away.Unit * speed + Vector3.new(0, speed * KNOCKBACK_LIFT, 0)
	-- "blast" is MovementClient's knockback kind: capped, it ends a slide or climb, and a small shove
	-- only leaves the ground in Freefall. An unknown kind would fall through to the generic launch,
	-- which forces a full jump and plays the Pickup chime on every hit.
	MovementService.Launch(character, velocity, "blast")
end

local function startDot(kind, attacker, victim, weaponId, spec)
	local damage, duration = tonumber(spec.damage), tonumber(spec.duration)
	if not damage or not duration or damage <= 0 or duration <= 0 then
		return
	end
	local ticks = math.max(1, math.floor(duration / TICK + 0.5))
	dots[victim] = dots[victim] or {}
	dots[victim][kind] = { attacker = attacker, weaponId = weaponId, perTick = damage / ticks, ticksLeft = ticks }
end

local function applyChill(victim, spec, now)
	local slow, duration, stacks, freeze = tonumber(spec.slow), tonumber(spec.duration), tonumber(spec.stacks), tonumber(spec.freeze)
	if not slow or not duration or not stacks then
		return
	end
	local state = chills[victim]
	if not state or state.expires < now then
		state = { stacks = 0, expires = 0, immuneUntil = state and state.immuneUntil or 0 }
		chills[victim] = state
	end
	if state.stacks >= stacks and freeze and freeze > 0 and now >= state.immuneUntil then
		MatchService.SetStatusSpeed(victim, "chill", 1, 0)
		MatchService.SetStatusSpeed(victim, "freeze", 0, freeze)
		state.stacks = 0
		state.expires = 0
		state.immuneUntil = now + freeze + FREEZE_IMMUNITY
		return
	end
	state.stacks = math.min(stacks, state.stacks + 1)
	state.expires = now + duration
	MatchService.SetStatusSpeed(victim, "chill", math.clamp(1 - slow * state.stacks, 0.05, 1), duration)
end

-- Everything on a combatant goes, including the slows MatchService holds for them: those are keyed by
-- token, not character, so a chill left on someone who died would otherwise meet their next character.
local function clearVictim(victim)
	dots[victim] = nil
	if chills[victim] then
		chills[victim] = nil
		MatchService.SetStatusSpeed(victim, "chill", 1, 0)
		MatchService.SetStatusSpeed(victim, "freeze", 1, 0)
	end
end

local function onDamage(attacker, victim, dealt, weaponId, _headshot, shieldHit)
	if ticking or not weaponId or not victim or attacker == victim then
		return
	end
	-- Listeners hear a hit after its damage lands: a killing hit starts nothing on the body.
	if not Combatants.IsAlive(victim) then
		clearVictim(victim)
		return
	end
	if (dealt or 0) <= 0 and not shieldHit then
		return
	end
	local def = WeaponData.Get(weaponId)
	if not def then
		return
	end
	if type(def.knockback) == "number" and def.knockback > 0 and attacker then
		applyKnockback(attacker, victim, def.knockback)
	end
	if type(def.bleed) == "table" then
		startDot("bleed", attacker, victim, weaponId, def.bleed)
	end
	if type(def.ignite) == "table" then
		startDot("ignite", attacker, victim, weaponId, def.ignite)
	end
	if type(def.chill) == "table" then
		applyChill(victim, def.chill, os.clock())
	end
end

-- One pass of every damage-over-time effect. Nothing ticks while combat is off: a bleed started by the
-- last shot of a match would otherwise keep hurting its victim in the lobby for its full duration.
local function tickAll()
	if CombatService.IsEnabled and not CombatService.IsEnabled() then
		for victim in pairs(chills) do
			clearVictim(victim)
		end
		table.clear(dots)
		return
	end
	for victim, kinds in pairs(dots) do
		if not Combatants.Exists(victim) or not Combatants.IsAlive(victim) then
			dots[victim] = nil
		else
			for kind, dot in pairs(kinds) do
				ticking = true
				local ok, err = pcall(CombatService.DealDamage, dot.attacker, victim, dot.perTick, dot.weaponId, false)
				ticking = false
				if not ok then
					warn("[StatusEffects] " .. kind .. " tick failed: " .. tostring(err))
				end
				dot.ticksLeft -= 1
				if dot.ticksLeft <= 0 then
					kinds[kind] = nil
				end
			end
			if next(kinds) == nil then
				dots[victim] = nil
			end
		end
	end
	local now = os.clock()
	for victim, state in pairs(chills) do
		if not Combatants.Exists(victim) then
			chills[victim] = nil
		elseif not Combatants.IsAlive(victim) then
			-- Died some other way (the storm, a fall) while slowed or frozen.
			clearVictim(victim)
		elseif state.expires < now and state.immuneUntil < now then
			chills[victim] = nil
		end
	end
end

-- Exposed for probes: what is on a combatant right now.
function StatusEffects.Get(victim)
	return dots[victim], chills[victim]
end

-- Exposed for probes: run the listener as a hit would, without a real shot.
StatusEffects.OnDamage = onDamage
StatusEffects.Tick = tickAll

if CombatService.OnDamage then
	CombatService.OnDamage(onDamage)
else
	warn("[StatusEffects] CombatService.OnDamage is missing; status effects are off")
end

task.spawn(function()
	while true do
		task.wait(TICK)
		local ok, err = pcall(tickAll)
		if not ok then
			ticking = false
			warn("[StatusEffects] tick failed: " .. tostring(err))
		end
	end
end)

return StatusEffects
