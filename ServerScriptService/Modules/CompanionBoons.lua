-- What your companion does FOR you, as opposed to what it does to the enemy.
--
-- A brainrot opts in by carrying a `boon` field in BrainrotData; nothing in here names a brainrot,
-- the same way StatusEffects names no gun. Add the field to a definition and the effect exists; the
-- vocabulary of what a field may say is BrainrotData.Boons, and verify.py checks every boon against
-- it so a typo cannot ship as "no effect".
--
-- The four kinds, and the seam each one goes through rather than inventing a second rule:
--
--   regen = hpPerSecond    healed on a tick while the companion is out and the owner is alive.
--                          Never past MaxHealth, never on a downed companion.
--   speed = factor         MatchService.SetStatusSpeed(token, KEY, factor, ...), which is already a
--                          KEYED composition — a chill and a boon multiply instead of overwriting
--                          each other. Re-asserted on the tick because that function expires by
--                          design (60 s cap) and a passive must not.
--   jump  = factor         MovementService.SetJumpFactor(humanoid, KEY, factor), the composing seam.
--                          NOT a direct JumpHeight write: Bounce Boots restore JumpHeight to its base
--                          when they expire, so a direct write would be silently wiped by a consumable
--                          the player drank earlier. One rule, not two.
--   health = bonusMaxHp    raises MaxHealth while equipped.
--   venom = { damage, duration }
--                          the companion's hits poison: `damage` total over `duration` seconds,
--                          dealt through CombatService.DealDamage with the companion's own tag, so a
--                          kill by the tick is credited to the owner exactly as a direct hit is.
--
-- THE EXPLOIT THIS IS WRITTEN AROUND. Equipping and unequipping a companion is two menu clicks and
-- costs nothing (CompanionService's own heal exploit was exactly that shape). So:
--   * `health` raises MaxHealth and NEVER current Health. Toggling therefore grants nothing — the
--     player ends with the same HP they started with and a smaller bar. If it healed on apply, a
--     toggle would be a free heal on a 0 s cooldown.
--   * `regen` is rate-based and its clock is the tick, not the spawn, so a toggle cannot advance it.
--   * `speed` and `jump` are factors that are set, not accumulated.
-- If a fifth kind is added, ask what a toggle does to it BEFORE landing it.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

local Modules = ServerScriptService:WaitForChild("Modules")
-- MatchService is loaded on first use, not here: MatchService requires BotService, which requires
-- CompanionService, which requires this module, so a top-level require here is a cycle and Roblox
-- refuses it ("Requested module was required recursively"), killing Bootstrap before the lobby builds.
local MatchService
local function matchService()
	if not MatchService then
		MatchService = require(Modules:WaitForChild("MatchService"))
	end
	return MatchService
end
local MovementService = require(Modules:WaitForChild("MovementService"))
local CombatService = require(Modules:WaitForChild("CombatService"))
local Combatants = require(Modules:WaitForChild("Combatants"))

local CompanionBoons = {}

-- One key for every boon this module sets, so a stale entry from a previous character is overwritten
-- rather than added to, and so a reader of MatchService's status table can see where a factor is from.
local KEY = "CompanionBoon"

-- [player] = { def, grantedHealth, baseHealth, humanoid }. `humanoid` is the body the grant went on: a
-- respawn is a new Humanoid, which never had it, so Clear takes it off the old one and Apply grants
-- afresh. `baseHealth` is that body's MaxHealth before the grant, the floor Clear never goes under.
local active = {}

local function humanoidOf(player)
	local character = player and player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

-- The boon a definition declares, or nil. Validated here rather than at the call site so a malformed
-- entry is inert instead of an error in the middle of a spawn.
local function boonOf(def)
	local boon = def and def.boon
	if type(boon) ~= "table" then
		return nil
	end
	return boon
end

--------------------------------------------------------------------------------
-- What the owner's HUD shows (Oliver, 2026-09-23 14:49: "a small hud to pop up showing what companion
-- buffs i have activated"). Two attributes on the Player, read by BoonHud.client.lua:
--   CompanionBoonName   the brainrot giving the buffs, or nil
--   CompanionBoons      one buff per line, e.g. "+15 max HP", or nil
-- Players only: a bot has no HUD.
--------------------------------------------------------------------------------

local function describe(boon)
	local lines = {}
	if SafeValue.Number(boon.health, 500) and boon.health > 0 then
		table.insert(lines, string.format("+%d max HP", boon.health))
	end
	if SafeValue.Number(boon.regen, 100) and boon.regen > 0 then
		table.insert(lines, string.format("+%s HP/s regen", (string.format("%.1f", boon.regen):gsub("%.0$", ""))))
	end
	if SafeValue.Number(boon.speed, 10) and boon.speed > 1 then
		table.insert(lines, string.format("+%d%% move speed", math.floor((boon.speed - 1) * 100 + 0.5)))
	end
	if SafeValue.Number(boon.jump, 10) and boon.jump > 1 then
		table.insert(lines, string.format("+%d%% jump height", math.floor((boon.jump - 1) * 100 + 0.5)))
	end
	local venom = CompanionBoons.VenomOf and type(boon.venom) == "table" and boon.venom or nil
	if venom and SafeValue.Number(venom.damage, 500) and SafeValue.Number(venom.duration, 60) then
		table.insert(lines, string.format("Venom hits: %d dmg over %ds", venom.damage, venom.duration))
	end
	return lines
end

local function publish(player, def, boon)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local lines = boon and describe(boon) or {}
	if #lines > 0 then
		player:SetAttribute("CompanionBoonName", def and def.name or "Companion")
		player:SetAttribute("CompanionBoons", table.concat(lines, "\n"))
	else
		player:SetAttribute("CompanionBoonName", nil)
		player:SetAttribute("CompanionBoons", nil)
	end
end

--------------------------------------------------------------------------------
-- Apply / clear
--------------------------------------------------------------------------------

-- Called when a companion is placed for `player`. Safe to call twice: the second call clears the
-- first, so a respawn cannot stack two health grants.
function CompanionBoons.Apply(player, def)
	-- SAME COMPANION, SAME BODY, SAME BOON: LEAVE IT ALONE. `CompanionService.Refresh` respawns the
	-- companion through `spawnFor` for reasons that have nothing to do with the boon (re-equipping it, a
	-- trade). Clearing and re-applying would take MaxHealth down and clamp Health under the lower
	-- ceiling, then put the ceiling back without healing (it must not heal), so the player would quietly
	-- lose the bonus's worth of HP each time. spawnFor's despawn skips Clear when the same companion is
	-- coming straight back, and this guard is what then leaves the boon alone. A NEW BODY is not the
	-- same: its Humanoid never had the grant, so it is granted afresh.
	--
	-- This runs INSIDE spawnFor, which is before Refresh re-applies the companion's own carried health
	-- fraction and lastAttackAt -- and it touches the OWNER's humanoid, never the companion entry, so it
	-- cannot disturb that carry. The toggle exploit that carry closes stays closed.
	local humanoid = humanoidOf(player)
	local existing = active[player]
	if existing and existing.def == def and existing.humanoid == humanoid then
		return
	end

	CompanionBoons.Clear(player)

	local boon = boonOf(def)
	if not boon then
		return
	end

	local state = { def = def, grantedHealth = 0, humanoid = humanoid }
	active[player] = state
	publish(player, def, boon)

	if SafeValue.Number(boon.health, 500) and boon.health > 0 and humanoid then
		-- MaxHealth only. See the exploit note at the top: healing here would make a toggle a free heal.
		state.baseHealth = humanoid.MaxHealth
		humanoid.MaxHealth += boon.health
		state.grantedHealth = boon.health
	end

	if SafeValue.Number(boon.jump, 10) and boon.jump > 0 and humanoid then
		MovementService.SetJumpFactor(humanoid, KEY, boon.jump)
	end

	-- Speed is asserted here and re-asserted on the tick; SetStatusSpeed expires by design.
	CompanionBoons.Tick(player, 0)
end

-- Called when the companion goes away for any reason: unequipped, sold, downed, character removed,
-- match over. Everything this module granted comes off, and nothing else does.
function CompanionBoons.Clear(player)
	local state = active[player]
	if not state then
		return
	end
	active[player] = nil
	publish(player, nil, nil)

	-- The body the grant went on, not whatever body the player has now: a respawn's fresh Humanoid
	-- never had it, and taking it off that one cost the new body its health bonus's worth of HP.
	local humanoid = state.humanoid
	if humanoid then
		if state.grantedHealth > 0 then
			-- Take the ceiling back down first, then bring Health under it. Doing it the other way
			-- round lets Health sit above MaxHealth for a frame, which reads as a full bar.
			-- Never under the ceiling the body had before the grant (and never raised): a spawn path
			-- that rewrote MaxHealth without adding the grant back (the lobby's PlaceInLobby) has
			-- already taken it off, and taking it off twice left a lobby body at 30 of 100.
			local floor = math.min(state.baseHealth or 1, humanoid.MaxHealth)
			humanoid.MaxHealth = math.max(1, floor, humanoid.MaxHealth - state.grantedHealth)
			if humanoid.Health > humanoid.MaxHealth then
				humanoid.Health = humanoid.MaxHealth
			end
		end
		MovementService.SetJumpFactor(humanoid, KEY, 1)
	end

	local token = player
	matchService().SetStatusSpeed(token, KEY, 1, 0)
end

-- The max health the boon has put on `humanoid`, or 0. MatchService's spawn boosts set MaxHealth
-- outright, and read this so they don't wipe a boon that was applied first (the companion and the
-- match's own boosts both land on CharacterAdded, in either order).
function CompanionBoons.GrantedHealth(player, humanoid)
	local state = active[player]
	if state and humanoid ~= nil and state.humanoid == humanoid then
		return state.grantedHealth
	end
	return 0
end

--------------------------------------------------------------------------------
-- Tick
--------------------------------------------------------------------------------

-- Driven by CompanionService's Heartbeat, so a boon stops the instant the companion does and this
-- module owns no loop of its own. `delta` is seconds since the last tick.
function CompanionBoons.Tick(player, delta)
	local state = active[player]
	if not state then
		return
	end
	local boon = boonOf(state.def)
	if not boon then
		return
	end

	if SafeValue.Number(boon.speed, 10) and boon.speed > 0 then
		-- Re-asserted every tick with a duration comfortably longer than the tick, so the factor never
		-- lapses between ticks and never outlives the companion by more than one.
		matchService().SetStatusSpeed(player, KEY, boon.speed, 5)
	end

	if SafeValue.Number(boon.regen, 100) and boon.regen > 0 and SafeValue.Number(delta, 60) and delta > 0 then
		local humanoid = humanoidOf(player)
		if humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + boon.regen * delta)
		end
	end
end

--------------------------------------------------------------------------------
-- Venom
--------------------------------------------------------------------------------

-- The venom a companion's hit should apply, or nil. Returned as a plain table rather than applied
-- here, because the thing that knows a hit landed is CompanionService and the thing that owns
-- damage-over-time is the combat path. Kept pure so a probe can read it without a Player.
function CompanionBoons.VenomOf(def)
	local boon = boonOf(def)
	local venom = boon and boon.venom
	if type(venom) ~= "table" then
		return nil
	end
	if not SafeValue.Number(venom.damage, 500) or venom.damage <= 0 then
		return nil
	end
	if not SafeValue.Number(venom.duration, 60) or venom.duration <= 0 then
		return nil
	end
	return venom
end


--------------------------------------------------------------------------------
-- Venom ticking
--------------------------------------------------------------------------------

-- [victimToken] = { owner, perTick, ticksLeft, weaponId }
-- A fresh bite REFRESHES rather than stacking, the same rule bleed and ignite use -- otherwise a fast
-- companion against one target is a damage multiplier nobody costed.
local venoms = {}
local VENOM_TICK = 0.5

-- Called by CompanionService when a companion's hit lands. `weaponId` is the companion's own tag, so
-- a kill by the tick is credited to the owner and reads in the feed as that brainrot.
function CompanionBoons.StartVenom(owner, victimToken, venom, weaponId)
	if not venom or victimToken == nil or victimToken == owner then
		return false
	end
	local ticks = math.max(1, math.floor(venom.duration / VENOM_TICK))
	venoms[victimToken] = {
		owner = owner,
		perTick = venom.damage / ticks,
		ticksLeft = ticks,
		weaponId = weaponId,
	}
	return true
end

-- Driven by the same Heartbeat as the boons. Deliberately not inside StatusEffects: that module is
-- documented as reading effects off WeaponData fields, and a companion is not a weapon -- putting it
-- there would mean either naming a brainrot in it or inventing a fake gun.
local venomAccumulated = 0
function CompanionBoons.TickVenom(delta)
	-- Nothing ticks while combat is off, the rule StatusEffects' DoTs follow: a bite in the last
	-- seconds of a match would otherwise keep hurting (and could kill) a winner on the results screen.
	if not CombatService.IsEnabled() then
		table.clear(venoms)
		venomAccumulated = 0
		return
	end
	venomAccumulated += delta
	if venomAccumulated < VENOM_TICK then
		return
	end
	venomAccumulated = 0
	for victim, dot in pairs(venoms) do
		if not Combatants.Exists(victim) or not Combatants.IsAlive(victim) then
			venoms[victim] = nil
		else
			local ok, err = pcall(CombatService.DealDamage, dot.owner, victim, dot.perTick, dot.weaponId, false)
			if not ok then
				warn("[CompanionBoons] venom tick failed: " .. tostring(err))
			end
			dot.ticksLeft -= 1
			if dot.ticksLeft <= 0 then
				venoms[victim] = nil
			end
		end
	end
end

-- Exposed for probes.
function CompanionBoons.VenomOn(victimToken)
	return venoms[victimToken]
end

-- Exposed for probes: what this module currently holds for a player.
function CompanionBoons.Get(player)
	return active[player]
end

return CompanionBoons
