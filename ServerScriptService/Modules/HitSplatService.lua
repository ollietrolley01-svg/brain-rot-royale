-- The little red splat where a bullet lands on someone.
--
-- CombatService tells this module about every hit (a CombatService.OnDamage listener). Hits are gathered
-- over the frame and sent to every client as one HitSplat event, the way GlassShatter batches panes.
-- A frame of a forty-bot firefight is one small message, not forty. HitSplatClient finds the spot on
-- the body facing the shooter and draws the splat there when the tracer arrives.
--
-- Only gunfire splats. Blasts, grenades, companions, barrels and mines have effects of their own, and
-- the storm isn't a hit.
--
-- Each hit sent: { victim character, attacker character or nil, headshot, shield, rarity }. `shield`
-- is true when the shield soaked the hit, which clients draw as blue chips rather than blood.
-- `rarity` is the rank of the weapon that dealt it ("Common" .. "Secret"), decided here from the
-- weapon id CombatService passed, never from a client: the splat is drawn in that rank's colour
-- (Oliver, 2026-09-18: "recolor the blood splats to the color of the rank of gun the target player
-- or bot gets shot by"). A hit with no known weapon sends false and is drawn plain red.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))

local HitSplatService = {}

-- More hits than this in one frame and the rest aren't drawn: nobody reads the fortieth splat.
local MAX_PER_FRAME = 40

local hitSplat = Remotes.Event("HitSplat")

local pending = nil

-- Gunfire only: a weapon id WeaponData knows that doesn't blow up. A round that flies but only cuts
-- whoever it hits (a thrown disc) still lands as a hit and gets its splat.
local function isGunfire(weaponId)
	local def = type(weaponId) == "string" and WeaponData.Get(weaponId) or nil
	if not def or def.ability == "explosive" then
		return false
	end
	if def.projectile then
		local spec = Ballistics.Rounds[def.projectile]
		return spec ~= nil and spec.explosive == false
	end
	return true
end

-- The rank of whatever dealt a hit: a gun's from WeaponData, a thrown item's from ItemData, nil for
-- anything else (a hazard, a companion's bite), which clients draw plain red.
function HitSplatService.RarityOf(weaponId)
	if type(weaponId) ~= "string" then
		return nil
	end
	local def = WeaponData.Get(weaponId)
	if def and def.rarity then
		return def.rarity
	end
	local item = ItemData.Get(weaponId)
	return item and item.rarity or nil
end

-- One hit as it is sent to clients, for the probe as much as for the batch.
function HitSplatService.Payload(victim, attacker, headshot, shield, weaponId)
	return { victim, attacker or false, headshot == true, shield == true, HitSplatService.RarityOf(weaponId) or false }
end

function HitSplatService.OnHit(attackerToken, victimToken, dealt, weaponId, headshot, shield)
	if not dealt or dealt <= 0 or attackerToken == victimToken or not isGunfire(weaponId) then
		return
	end
	local victim = Combatants.GetCharacter(victimToken)
	if not victim then
		return
	end
	if not pending then
		pending = {}
		task.defer(function()
			local batch = pending
			pending = nil
			hitSplat:FireAllClients(batch)
		end)
	end
	if #pending < MAX_PER_FRAME then
		table.insert(pending, HitSplatService.Payload(victim, attackerToken and Combatants.GetCharacter(attackerToken) or nil, headshot, shield, weaponId))
	end
end

-- Until CombatService offers damage listeners there is nothing to register with, and no splats.
if CombatService.OnDamage then
	CombatService.OnDamage(HitSplatService.OnHit)
end

return HitSplatService
