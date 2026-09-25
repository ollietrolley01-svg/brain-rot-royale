-- The game modes. The battle royale is one of them and is unchanged by any of this; Team
-- Deathmatch and King of the Hill are the two that respawn you.
--
-- This module is DEFINITIONS ONLY, shared so the client can name a mode, colour a team and draw a
-- scoreline without a round trip. Everything that happens on a server lives in
-- ServerScriptService.Modules.GameMode and the three Mode* modules beside it.
--
-- The flags a mode carries, and who reads them:
--   respawn       death is not an elimination: the mode scores it and puts the player back
--   teams         combatants are split into the two sides below, and friendly fire is off
--   storm         the shrinking circle runs (battle royale only)
--   bounds        a STATIC boundary circle is drawn instead, and never shrinks
--   dropSelect    the 15-second "choose your drop" window runs
--   dropLoot      a death puts the victim's gear on the floor
--   loadout       everyone spawns carrying `Loadout` below (Oliver's green weapon + heals + throwables)
--
-- No mode introduces a new match STATE string. The HUD banner, CombatClient, MovementClient,
-- ProjectileClient and TouchControls all gate on the state string (27 sites), and an unrecognised
-- value would break them quietly — the same reason the drop window rides as a flag on `Loading`
-- rather than as a state of its own. A mode is a FIELD on the broadcast, never a new state.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rarity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Rarity"))

local GameModes = {}

--------------------------------------------------------------------------------
-- Teams
--------------------------------------------------------------------------------

-- Two sides. The colours are MEASURED, not picked by eye: of twelve readable team shades, these
-- two are the pair that is furthest from every rarity colour in Rarity.Colors while still being
-- unmistakable from each other. Weighted-RGB distance: each is at least 143 from the nearest
-- rarity colour (the next best pair scored 129) and they are 452 apart from one another. That
-- matters because a team tint on a nameplate or a scoreline must never read as a rarity tint —
-- Legendary is (255,184,48) and an orange team colour drifts into it fast (amber scored 39).
GameModes.Teams = {
	{ id = "Ember", name = "Ember Squad", short = "EMBER", color = Color3.fromRGB(255, 112, 36) },
	{ id = "Teal", name = "Teal Crew", short = "TEAL", color = Color3.fromRGB(40, 196, 190) },
}

GameModes.TeamCount = #GameModes.Teams

-- 1 -> 2, 2 -> 1. Written as a function rather than "3 - index" so a third team, if it ever
-- happens, fails loudly here instead of silently returning nothing.
function GameModes.OtherTeam(index)
	if index == 1 then
		return 2
	elseif index == 2 then
		return 1
	end
	return nil
end

function GameModes.Team(index)
	return GameModes.Teams[index]
end

function GameModes.TeamColor(index)
	local team = GameModes.Teams[index]
	return team and team.color or Color3.fromRGB(200, 200, 200)
end

function GameModes.TeamName(index)
	local team = GameModes.Teams[index]
	return team and team.name or "No team"
end

--------------------------------------------------------------------------------
-- The spawn loadout (Oliver: "you spawn with a green weapon some heals, and throwables")
--------------------------------------------------------------------------------

-- GREEN IS **Uncommon**. Not a guess: Rarity.Colors.Uncommon is (94, 214, 122) and it is the only
-- green in the table — Common is grey (178,184,196), Rare blue, Epic purple, Legendary orange,
-- Mythic pink, Secret cyan. `GameModes.GreenRarity` is the name; `GameModes.AssertGreen` below
-- re-proves it from the data at runtime so a future palette change cannot quietly make this a lie.
GameModes.GreenRarity = "Uncommon"

-- Proves the tier named above really is the green one, from a palette's own numbers. PURE and
-- parameterised on purpose: the probe calls this exact function twice, once on Rarity's real table
-- and once on a palette deliberately broken so a different tier is the green one, and fails if the
-- broken palette is accepted. A detector that has quietly stopped detecting then shows up as a red
-- probe rather than as a green one that checks nothing.
--
-- "Greenest" is argmax of (G - max(R, B)): the channel lead over the brightest of the other two.
-- Plain "largest G" would crown Secret (120,255,235), which is cyan.
function GameModes.GreenCheck(colors, order, name)
	local mine = colors and colors[name]
	if not mine then
		return false, "no such rarity: " .. tostring(name)
	end
	local r, g, b = mine.R * 255, mine.G * 255, mine.B * 255
	if g <= r or g <= b then
		return false, string.format("%s is not green: R%d G%d B%d", tostring(name), r, g, b)
	end

	local bestName, bestLead = nil, -math.huge
	for _, other in ipairs(order) do
		local colour = colors[other]
		if colour then
			local lead = colour.G * 255 - math.max(colour.R * 255, colour.B * 255)
			if lead > bestLead then
				bestName, bestLead = other, lead
			end
		end
	end
	if bestName ~= name then
		return false, string.format("%s is greener than %s (lead %.0f)", tostring(bestName), tostring(name), bestLead)
	end
	return true, string.format("%s R%d G%d B%d, lead %.0f", name, r, g, b, g - math.max(r, b))
end

function GameModes.AssertGreen()
	return GameModes.GreenCheck(Rarity.Colors, Rarity.Order, GameModes.GreenRarity)
end

-- What everyone spawns with, on the first spawn and on every respawn.
--
-- The GUN is not listed here on purpose: the pool of Uncommon guns is built at RUN TIME from
-- WeaponData.Weapons, because hardcoding ids would already be stale. Base WeaponData holds 6
-- Uncommon guns, ArsenalExpansion adds 2, CreativeArsenal 2 and WorkshopArsenal 1 — eleven today,
-- and the arsenal tabs are still landing packs. GameMode builds the pool and prints its size.
--
-- Heals: Bandages, not Med Kits. A Med Kit takes 5 seconds to use (ItemData), which is most of a
-- respawn timer; a Bandage takes 2.5.
--
-- Oliver, 2026-09-25: "everyone spawn with 2 of each of 2 random kinds of explosive, and 2 smoke
-- bombs, and ... they spawn with full shield", then "make it only 2 of one random type of portable
-- defense". The random picks are rolled per life from `pools` (two different explosives, one
-- defense, 2 of each, capped by the item's stack -- the Brainrot Fortress stacks to 1). Full shield replaces the Mini Shields that used
-- to be here: a Mini Shield only fills to 50, so at a full 100 it was a slot doing nothing, and
-- dropping it keeps two of the eight slots free for what you pick up off the map.
GameModes.Loadout = {
	items = {
		{ id = "Bandage", count = 3 },
		{ id = "LowkeyLatte", count = 2 },
	},
	pools = {
		{ ids = { "CookedCoconut", "ClingyCrumpet", "RotMine" }, kinds = 2, count = 2 },
		{ ids = { "RotBarricade", "PopupBunker", "BrainrotFortress" }, kinds = 1, count = 2 },
	},
	fullShield = true,
	-- Checked by the loadout probe so a silent drift in ItemData's stack sizes shows up as a
	-- failure rather than as a quietly truncated kit: the gun, 2 fixed items and 2 + 1 rolled.
	slotsUsed = 6,
}

-- One life's kit: the fixed items plus `kinds` different ids drawn from each pool. `random(n)`
-- returns 1..n; the default is a module Random so two players spawning together differ.
local kitRandom = Random and Random.new()
function GameModes.RollLoadout(random)
	random = random or function(n)
		return kitRandom and kitRandom:NextInteger(1, n) or math.random(n)
	end
	local list = {}
	for _, entry in ipairs(GameModes.Loadout.items) do
		table.insert(list, { id = entry.id, count = entry.count })
	end
	for _, pool in ipairs(GameModes.Loadout.pools) do
		local left = table.clone and table.clone(pool.ids) or { table.unpack(pool.ids) }
		for _ = 1, math.min(pool.kinds, #left) do
			local id = table.remove(left, random(#left))
			table.insert(list, { id = id, count = pool.count })
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Modes
--------------------------------------------------------------------------------

-- Match events that still make sense in a respawn mode. Zone Rush and Hot Drops need a storm and
-- supply drops; Loot Frenzy and Aura Farm are about chests, which nobody is fighting over when the
-- kit is handed to you. The rest change how the fight feels and are kept.
local RESPAWN_EVENTS = {
	RotRush = true,
	LowGravity = true,
	NightOps = true,
	Headhunter = true,
	ShieldUp = true,
	BountyRush = true,
}

GameModes.Order = { "BattleRoyale", "TeamDeathmatch", "KingOfTheHill" }

GameModes.Modes = {
	BattleRoyale = {
		id = "BattleRoyale",
		name = "Battle Royale",
		short = "BR",
		description = "Fifty in, one out. The storm closes until there is nowhere left to stand.",
		color = Color3.fromRGB(186, 104, 255),
		respawn = false,
		teams = false,
		storm = true,
		bounds = false,
		dropSelect = true,
		dropLoot = true,
		loadout = false,
	},

	TeamDeathmatch = {
		id = "TeamDeathmatch",
		name = "Team Deathmatch",
		short = "TDM",
		description = "Two sides, one arena, and you come straight back.",
		color = Color3.fromRGB(255, 112, 36),
		respawn = true,
		teams = true,
		storm = false,
		bounds = true,
		dropSelect = false,
		-- Nobody needs the floor covered in guns in a mode that hands out a kit every five seconds.
		dropLoot = false,
		loadout = true,

		respawnDelay = 5,
		-- Oliver 09-25: "get rid of spawn prot". 0 grants none (ModeTeams.grantProtection).
		spawnProtection = 0,
		scoreTarget = 100,  -- Oliver, 2026-09-18: first to 100 team kills (was 50)
		timeLimit = 480,
		scoreLabel = "eliminations",
		events = RESPAWN_EVENTS,
	},

	KingOfTheHill = {
		id = "KingOfTheHill",
		-- Oliver 09-22 15:39: renamed and made two objectives (ModeKingOfTheHill). The id stays.
		name = "Objective Capture",
		short = "OBJ",
		description = "Two objectives. Capture them, and each one your team holds scores every second.",
		color = Color3.fromRGB(40, 196, 190),
		respawn = true,
		teams = true,
		storm = false,
		bounds = true,
		dropSelect = false,
		dropLoot = false,
		loadout = true,

		-- A second longer than TDM: losing the hill should cost the side that lost it more than
		-- losing a duel in the open costs.
		respawnDelay = 6,
		spawnProtection = 0, -- none (Oliver 09-25, as TDM)
		scoreTarget = 250,
		timeLimit = 480,
		scoreLabel = "seconds held",
		events = RESPAWN_EVENTS,

		-- ONE FIXED HILL (Oliver's decision, taken knowing one side may fortify it). The rotation
		-- below is built and tested but NOT enabled: flipping `hillRotation` to true is the whole
		-- change if the measurement ever says a static hill kills the match.
		hillRotation = false,
		hillRotateSeconds = 90,
		hillWarnSeconds = 10,
		hillRadius = 28,
		-- How much of the hill's height counts. A capture zone that reached the sky would let
		-- someone hold it from a third-floor window across the square.
		hillHeight = 22,
	},
}

-- Which mode each match runs. Rotation, not a vote, so the modes are IN the game and playable
-- rather than waiting on owned vote UI; the vote is designed separately. The battle royale keeps
-- three slots in five because it is the main game and Oliver asked for these ALONGSIDE it, not
-- instead of it.
GameModes.Rotation = { "BattleRoyale", "TeamDeathmatch", "BattleRoyale", "KingOfTheHill", "BattleRoyale" }

-- THE SENTENCE IS BUILT FROM THE NUMBER, because the two drifted.
--
-- `TeamDeathmatch.description` read "First to 50 eliminations" while `scoreTarget` a few lines above
-- it in the same table read 100 (Oliver asked for 100 on 2026-09-18 and got it). Anything printing
-- the sentence -- a vote card, a mode picker, a toast -- told him the wrong number. Editing the
-- string would fix today and drift again the next time the target moves; composing it cannot.
--
-- So the tables above carry a description with NO NUMBER IN IT, and the scoring sentence is added
-- here from the mode's own scoreTarget. tools/verify.py refuses a build where any description
-- hard-codes a number that disagrees with its scoreTarget, with a planted needle, so a literal
-- creeping back in is caught rather than shipped.
local SCORE_SENTENCE = {
	TeamDeathmatch = " First to %d eliminations.",
	KingOfTheHill = " First to %d seconds held.",
}

for id, sentence in pairs(SCORE_SENTENCE) do
	local mode = GameModes.Modes[id]
	if mode and mode.scoreTarget then
		mode.description = mode.description .. string.format(sentence, mode.scoreTarget)
	end
end

function GameModes.Get(id)
	return GameModes.Modes[id]
end

-- The mode at a given position in the rotation, 1-based and wrapping. Takes the match number, so
-- a server that has run six matches is at rotation slot 2 again.
function GameModes.FromRotation(matchNumber)
	local list = GameModes.Rotation
	local index = ((math.floor(matchNumber) - 1) % #list) + 1
	return GameModes.Modes[list[index]] or GameModes.Modes.BattleRoyale
end

-- Whether a rolled match event is allowed in this mode. A mode with no allowlist takes anything,
-- which is the battle royale.
function GameModes.AllowsEvent(mode, event)
	if not event or not mode or not mode.events then
		return true
	end
	return mode.events[event.id] == true
end

-- What the client is told about the mode: enough to name it, colour it and draw a scoreline.
function GameModes.Describe(mode)
	if not mode then
		return nil
	end
	return {
		id = mode.id,
		name = mode.name,
		short = mode.short,
		description = mode.description,
		color = mode.color,
		teams = mode.teams == true,
		respawn = mode.respawn == true,
		scoreTarget = mode.scoreTarget,
		scoreLabel = mode.scoreLabel,
	}
end

return GameModes
