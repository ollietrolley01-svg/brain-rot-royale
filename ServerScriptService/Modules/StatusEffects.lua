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
--   echo = { ratio, delay }   (the gun rework) the hit repeats itself `delay` seconds later for `ratio` of the
--                             gun's body damage, if the victim is still standing: a lag spike you can see
--                             in the hit markers. An echo never echoes.
--   ratio = { stacks, window, duration, scale }
--                             (the gun rework) each hit adds a stack; `stacks` of them landed with no gap
--                             longer than `window` seconds "ratio" the victim for `duration` seconds, and a
--                             ratio'd victim takes `scale` times the damage from everyone
--                             (CombatService.DamageTakenScale). A tag over their head says so.
--
-- A death, or combat switching off, clears everything on that combatant, the slows included.
--
-- Damage-over-time ticks call DealDamage, which tells every listener again; `ticking` makes sure a
-- tick never starts a new effect of its own.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

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

--------------------------------------------------------------------------------
-- Echo and ratio (the gun rework)
--------------------------------------------------------------------------------

-- Server game time (os.clock is CPU time in Roblox and drifts from the wall under load), for the chill's
-- timers as well as these; swappable for the harness, as Delay is (task.delay, which the harness runs by hand).
StatusEffects.Clock = function()
	return time()
end
StatusEffects.Delay = function(seconds, fn)
	task.delay(seconds, fn)
end

local ECHO_DELAY_MAX = 1
-- [victimToken] = { stacks, at, untilAt, scale }
local ratios = {}

local function scheduleEcho(attacker, victim, weaponId, def)
	local ratio, delay = tonumber(def.echo.ratio), tonumber(def.echo.delay)
	if not ratio or not delay or ratio <= 0 then
		return
	end
	StatusEffects.Delay(math.clamp(delay, 0, ECHO_DELAY_MAX), function()
		if not Combatants.Exists(victim) or not Combatants.IsAlive(victim) or not Combatants.Exists(attacker) then
			return
		end
		if CombatService.IsEnabled and not CombatService.IsEnabled() then
			return
		end
		-- As a damage-over-time tick: `ticking` keeps the echo from starting effects (or an echo) of its own.
		ticking = true
		local ok, err = pcall(CombatService.DealDamage, attacker, victim, def.damage * ratio, weaponId, false)
		ticking = false
		if not ok then
			warn("[StatusEffects] echo failed: " .. tostring(err))
		end
	end)
end

-- The tag over a ratio'd head, for everyone to see who is taking extra.
local function ratioTag(victim, duration)
	local character = Combatants.GetCharacter(victim)
	local head = character and character:FindFirstChild("Head")
	if not head then
		return
	end
	local old = head:FindFirstChild("RatioTag")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "RatioTag"
	gui.Size = UDim2.fromScale(4, 1.2)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 120
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Text = "RATIO'D"
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = Color3.fromRGB(255, 120, 190)
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = head
	Debris:AddItem(gui, duration)
end

local function addRatio(victim, spec, now)
	local need, window, duration, scale = tonumber(spec.stacks), tonumber(spec.window), tonumber(spec.duration), tonumber(spec.scale)
	if not (need and window and duration and scale) then
		return
	end
	local state = ratios[victim]
	if not state then
		state = { stacks = 0, at = -math.huge, untilAt = -math.huge, scale = 1 }
		ratios[victim] = state
	end
	if now - state.at > window then
		state.stacks = 0
	end
	state.at = now
	-- Already ratio'd: nothing builds until it lapses, so a fast gun can't keep it up forever.
	if now < state.untilAt then
		return
	end
	state.stacks += 1
	if state.stacks >= need then
		state.stacks = 0
		state.untilAt = now + duration
		state.scale = scale
		ratioTag(victim, duration)
	end
end

-- How much more a combatant takes from every hit right now (1 unless ratio'd). CombatService.DealDamage asks.
function StatusEffects.DamageTakenScale(victim)
	local state = ratios[victim]
	if state and StatusEffects.Clock() < state.untilAt then
		return state.scale
	end
	return 1
end

-- Everything on a combatant goes, including the slows MatchService holds for them: those are keyed by
-- token, not character, so a chill left on someone who died would otherwise meet their next character.
local function clearVictim(victim)
	dots[victim] = nil
	ratios[victim] = nil
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
		applyChill(victim, def.chill, StatusEffects.Clock())
	end
	if type(def.echo) == "table" and attacker then
		scheduleEcho(attacker, victim, weaponId, def)
	end
	if type(def.ratio) == "table" then
		addRatio(victim, def.ratio, StatusEffects.Clock())
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
		table.clear(ratios)
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
	local now = StatusEffects.Clock()
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
	local gameNow = StatusEffects.Clock()
	for victim, state in pairs(ratios) do
		if not Combatants.Exists(victim) or (state.untilAt < gameNow and gameNow - state.at > 10) then
			ratios[victim] = nil
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

CombatService.DamageTakenScale = StatusEffects.DamageTakenScale
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
