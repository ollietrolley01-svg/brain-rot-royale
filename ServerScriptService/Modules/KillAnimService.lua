-- Death effects (#24; "kill animations" in the code and the save): when a player is credited with a
-- kill, the death effect they have equipped plays on the body, for everyone nearby. The server only
-- decides WHICH one, WHERE and whether it gets the BODY; KillAnimFxClient builds it on each client, so
-- no parts are made or replicated here.
--
-- The body: a plain ragdoll is claimed through DeathFxService.Claim (anchored now, hidden once the
-- effect's life is over) and sent along, so the effect can pop, squash, melt or lift it. A body a
-- gun's own kill effect already has (burn, freeze, confetti...) keeps that, and the effect plays
-- beside it with no body.
--
-- Hooked by wrapping MatchService.OnKillCredited (Bootstrap, one line after ProgressionService is
-- set). That hook is the one place both kill paths meet: the battle royale path and the respawn
-- modes' capped one (MatchService, "if MatchService.OnKillCredited then"). It only ever fires for
-- a real player killer who isn't the victim, which is exactly who can own a kill animation.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

local DeathEffectDesigns = require(Shared:WaitForChild("DeathEffectDesigns"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local DeathFxService = require(script.Parent:WaitForChild("DeathFxService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local KillAnimService = {}

local killAnimFx = Remotes.Event("KillAnimFx")

-- How long after the effect's own life the server waits before hiding a claimed body: the client's
-- copy starts a round trip later than this clock, and every design has the body gone by its end.
local CLAIM_MARGIN = 0.4

-- Where the body is. The root first; a rig that has lost it (a shattered or vaporised body) still
-- has a pivot while it exists.
local function bodyPosition(victimToken)
	local root = Combatants.GetRoot(victimToken)
	if root then
		return root.Position
	end
	local character = Combatants.GetCharacter(victimToken)
	if character and character.Parent then
		return character:GetPivot().Position
	end
	return nil
end

-- The kill animation `killer` has equipped, if it's one they own and it really is a kill
-- animation. A save edited by hand, or an item renamed since, plays nothing rather than erroring.
function KillAnimService.EquippedFor(killer)
	if not Combatants.IsPlayer(killer) then
		return nil
	end
	local data = PlayerData.Get(killer)
	local id = data and data.Cosmetics and data.Cosmetics.killAnimation
	local item = id and CosmeticData.Get(id)
	if not item or item.kind ~= "KillAnimation" or not data.Cosmetics.owned[id] then
		return nil
	end
	return id
end

-- Returns true if an animation was sent.
function KillAnimService.Play(killer, victim)
	local id = KillAnimService.EquippedFor(killer)
	if not id then
		return false
	end
	local position = bodyPosition(victim)
	if not SafeValue.Vector3(position) then
		return false
	end
	local design = DeathEffectDesigns.Get(id)
	local character = Combatants.GetCharacter(victim)
	local body = nil
	if design and character and DeathFxService.Claim(character, design.life + CLAIM_MARGIN) then
		body = character
	end
	killAnimFx:FireAllClients({ id = id, position = position, body = body })
	return true
end

-- Wraps whatever OnKillCredited already was. Ours runs first and inside a pcall, so a failure here
-- can never stop gun mastery; the previous hook is then called exactly as before, errors and all
-- (the battle royale path calls it without a pcall, and that behaviour is kept).
function KillAnimService.Chain(previous)
	return function(killer, victim, weaponId)
		local ok, err = pcall(KillAnimService.Play, killer, victim)
		if not ok then
			warn("[KillAnimService] " .. tostring(err))
		end
		if previous then
			return previous(killer, victim, weaponId)
		end
	end
end

return KillAnimService
