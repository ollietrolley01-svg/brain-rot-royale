-- Bots that actually play. Each carries a real weapon from WeaponData and uses its damage,
-- fire rate, range and magazine; they strafe while engaging, push when out of position, take cover
-- or put a barricade up when hurt, and rotate to the safe zone when there's nobody to shoot.
--
-- They fight each other as well as players, which is what makes the match thin out on its
-- own instead of 29 statues waiting to be farmed.
--
-- Accuracy falls off with distance, so a close-range fight is genuinely dangerous while a
-- long-range one is survivable — that's the main difficulty dial, alongside BotDamageScale.
--
-- What a bot knows is what it could know. It sees a target only with a clear line to it, notices
-- one behind it a moment late (so flanking a bot works), and when a target breaks line of sight it
-- hunts where it last saw them rather than tracking them through walls.
--
-- Getting around lives in BotNav: queued path requests, step checks before every combat move, cover
-- search, and the stuck ladder.
--
-- One rig is built up front and cloned for the rest: CreateHumanoidModelFromDescription is
-- a web call, and doing it 29 times would stall the match start.
--
-- SHARED INFRASTRUCTURE (for every section in this file: archetypes, looting, vehicles, animation).
-- Bot code is hot: up to 13 bots think in one server frame. Anything a new behaviour needs from the
-- world goes through these, never through its own workspace:Raycast or a walk over Combatants.All():
--   BotService.Tick                  counts think slices; stamp a per-tick cache with it (see hostile()).
--   combatantList / combatantsNear   the living combatants this tick (token, character, root, humanoid,
--     (BotService.SpatialQuery)      position, isPlayer) and the ones within a radius, from a uniform
--                                    grid rebuilt once a tick. The returned list is a SHARED scratch
--                                    buffer: read it, never keep it. SpatialQuery.Loot(position,
--                                    radius, kind) does the same for pickups; SpatialQuery.NewGrid
--                                    makes a grid for anything else (vehicles, structures).
--   castRay(origin, direction,       every ray a bot casts. A per-frame budget (BotService.RaycastBudget)
--     params, priority)              serves "combat" (sight lines) before "navigation" (steps, cover,
--                                    floors) before "idle" (wander and loot walking). Returns result,
--                                    granted; on granted == false do the cautious thing (not visible,
--                                    can't step) and DON'T cache the answer: the next think retries.
--                                    BotNav.CastRay is the same function for BotNav's own rays.
--   BotService.LodDefers             far from every player, an idle bot thinks every other turn; a
--                                    bot that is fighting, fleeing, in the storm or was just hit never
--                                    does. Time-based behaviour (regen, timers) must use elapsed time,
--                                    not "one think = BotThinkInterval".
-- Allocation: reuse rows (see refreshCombatants, findTarget, planCombatMove) rather than building
-- tables in a per-think path; the GC pause is part of the frame. tools/perf_bot_cost.py counts rays,
-- candidates examined, KB allocated and thinks per frame at 30 and 50 bots, and its planted faults
-- must all still be caught after a change here.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameModes = require(Shared:WaitForChild("GameModes"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local AccessoryService = require(script.Parent:WaitForChild("AccessoryService"))
local BotNav = require(script.Parent:WaitForChild("BotNav"))
local CombatService = require(script.Parent:WaitForChild("CombatService"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))
local DefenseService = require(script.Parent:WaitForChild("DefenseService"))
local CompanionService = require(script.Parent:WaitForChild("CompanionService"))
local LootService = require(script.Parent:WaitForChild("LootService"))
local MapGenerator = require(script.Parent:WaitForChild("MapGenerator"))
local MovementService = require(script.Parent:WaitForChild("MovementService"))
local NameplateService = require(script.Parent:WaitForChild("NameplateService"))
local StormService = require(script.Parent:WaitForChild("StormService"))
local SupplyDropService = require(script.Parent:WaitForChild("SupplyDropService"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local BotService = {}

-- Hooks for game modes, set by whoever runs the match (nil in the battle royale, where everyone is
-- everyone's enemy and bots spawn empty-handed):
--   BotService.IsHostile(bot, otherToken) -> false to make a bot ignore a combatant entirely: it is
--     not chosen as a target, and a shot at it is refused even if it was chosen a moment earlier.
--     Anything other than a literal false means hostile, so a hook that errors or forgets a case
--     leaves the old behaviour rather than a pacifist bot.
--   BotService.SpawnLoadout(bot, humanoid) -> weaponIdOrDef, items: what this bot starts with. The
--     weapon may be a WeaponData def or its id; `items` is a list of { id = , count = } handed to the
--     same granters a chest uses, so a mode can feed bots and players from ONE loadout list instead
--     of two that drift apart. Heals, shields, throwables, barricades and rockets are understood; an
--     id that is none of those is ignored. Nil leaves the bot empty-handed to loot, the BR's rule.
BotService.IsHostile = nil
BotService.SpawnLoadout = nil

-- The think slice being run, bumped by refreshCombatants. Per-tick caches are stamped with it.
BotService.Tick = 0

-- The hook is a pcall per pair, and findTarget asks it for every combatant in reach of every bot
-- that thinks: at 50 bots that was ~600 pcalls a slice. Teams don't change inside a slice, so the
-- answer is kept per bot for the tick (cleared when BotService.Tick moves on). shootAt still asks
-- at the trigger, through this same cache, so a side swap mid-match is seen by the next slice.
local function hostile(bot, token)
	-- Riding together is a truce: nobody sharing a bot's vehicle is its target (BOT VEHICLES).
	local ride = bot.ride
	if ride and ride.model then
		local character = Combatants.GetCharacter(token)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local seat = humanoid and humanoid.SeatPart
		if seat and seat.Parent == ride.model then
			return false
		end
	end
	local hook = BotService.IsHostile
	if not hook then
		return true
	end
	local cache = bot.hostileCache
	if cache then
		if bot.hostileTick ~= BotService.Tick then
			table.clear(cache)
			bot.hostileTick = BotService.Tick
		else
			local known = cache[token]
			if known ~= nil then
				return known
			end
		end
	elseif type(bot) == "table" then
		cache = {}
		bot.hostileCache = cache
		bot.hostileTick = BotService.Tick
	end
	local ok, result = pcall(hook, bot, token)
	result = (not ok) or result ~= false
	if cache then
		cache[token] = result
	end
	return result
end

-- Counters for tools/bot_probe.lua, shared with BotNav so the probe reads one table.
local STATS = BotNav.Stats
for _, key in ipairs({
	"thinkTime", "thinkTicks", "updates", "maxTick", "pathRejected", "hopsWhileLooting",
	"buildsExposed", "buildsAngle", "buildsHeal", "buildsRefused", "throwsGrenade", "throwsSmoke",
	"reloads", "flees", "hunts", "searches", "coverSearches", "coverFound", "coverReached",
	"lootBlacklisted", "combatReplans", "badMoves", "sprints", "slides", "dangerDodges", "coverRouted",
	"launcherShots", "launcherMisses", "coverUnreachable", "crouches", "lootIgnored", "lootFarReach",
	"coverShots", "sightChecks", "coverChecks", "maxTickWall", "maxBotUpdate", "quickShots",
	-- BOT ARCHETYPES (tools/bot_archetype_sim.py reads these)
	"peeks", "repositions", "thirdPartyHolds", "avoided", "flankMoves", "focusFire", "throwsSticky",
	"buildsFortify", "buildsBlock", "buildsCross", "buildsPushed", "throwsRefusedFriendly", "buildsRefusedFriendly",
	"rays", "raysCombat", "raysNavigation", "raysIdle", "raysDenied", "raysFrameMax", "sightDenied",
	"candidatesExamined", "lodSkips", "lodThinks",
}) do
	STATS[key] = STATS[key] or 0
end
BotService.Stats = STATS

local BOT_NAMES = {
	"SahurFan2011", "TungTungKing", "crocodilo_xd", "TralalaGamer", "BananiniBoss",
	"rot_enjoyer", "PatapimPro", "LarilaLover", "BombardiroBoi", "CappuccinaQT",
	"SaturnitaX", "AmbalabuAce", "TrippiTroppi99", "brainrot_fan", "GoldSahurGuy",
	"FrigoFreeze", "GusiniGamer", "SkibidiSahur", "LiriliMain", "BallerinaBlitz",
	"CameloCrew", "RotRidgeRat", "TownTakerr", "ZoneRunner7", "LootGoblin44",
	"ChestSniffer", "StormDodger", "QuietDropper", "FinalCircler", "NoScopeNate",
}

-- Guns bots don't pick up yet, whatever their rarity. BoomboxBassline shoves its target 45 studs/s,
-- and a bot aims by turning its whole body with an AlignOrientation, so being shoved mid-burst turns
-- its aim: worth one playtest look before bots can hold one. Remove the entry after that.
local BOT_WEAPON_HOLD = { BoomboxBassline = true }

-- Mostly floor-tier guns, with the occasional good one so some fights bite harder.
local WEAPON_ODDS = { Common = 44, Uncommon = 38, Rare = 15, Epic = 3, Legendary = 0 }

--------------------------------------------------------------------------------
-- BOT ARCHETYPES
--------------------------------------------------------------------------------
-- Every bot used to play the same way: nearest target, 55 studs, strafe, cover at 80% health. Thirty
-- copies of one player read as thirty statues that move. Each bot is now dealt an ARCHETYPE at spawn
-- (Oliver, 2026-09-24: "different kinds that have different strategies in fighting and looting"), a
-- table of dials the fighting, looting and rotation code reads instead of one shared constant. The
-- dials say how a bot COMMITS: what it fights, from how far, when it hides, when it leaves. They never
-- touch how well it shoots. Aim is MatchConfig.BotAccuracy* and AIM_SETTLE_DELAY, and stays where
-- Oliver put it (#40/#75/#81): aggression is commitment, not lethality. tools/bot_aggression_check.py
-- fails if the hit chance at any range moves.
--
-- Layered on top is the WEAPON CLASS a bot happens to hold (WeaponData `style`): a shotgun wants to be
-- at 12 studs and pushes corners, a sniper wants 130 and moves after every shot, an LMG sits and
-- suppresses, a launcher never fires point-blank. ARCHETYPE_CLASS is the small table where the two
-- meet (a Marksman with a shotgun still keeps more distance than a Rusher with one). The merged result
-- for a bot's current gun is BotService.DialsOf(bot), rebuilt when its gun changes.
--
-- Reading the dials elsewhere:
--   BotService.ArchetypeOf(bot)  -> the archetype table (has .name), nil for a token that isn't a bot
--   BotService.DialsOf(bot)      -> archetype x weapon class, the table the fight code runs on
--   BotService.Archetypes        -> name -> archetype, for probes and the mode mix
--   BotService.WeaponClasses     -> style -> class dials
--   BotService.AssignArchetype(bot, name) -> force one (probes, a mode that wants a set squad)
-- Loot and rotation dials (lootGreed, preferredWeaponClasses, rotateEarly, chestPriority, healPriority)
-- are DEFINED here so the whole personality is one table, and READ by the loot/rotation code.
--
-- Dial meanings (fighting):
--   rangeScale         multiplies the weapon class's preferred engagement distance
--   coverUse           0-1, how readily the bot takes cover when the fight rules say it may
--   peek               peeks from cover: hides between bursts rather than standing in the gap
--   repositionOnHit    0-1, chance a fresh hit makes it change position (and drop the current move)
--   targetPick         "closest" | "weakest" | "threat" | "engaged": what the target score favours
--   pushTargetBelow    pushes a target under this health share (the MatchConfig one is the floor)
--   retreatHealth      absolute health under which it leaves a close fight (MatchConfig is the default)
--   healBelow          health share under which it uses heals (MatchConfig is the default)
--   grenadeAt          minimum enemies bunched round the target before a frag goes over
--   smokeToMove        smokes the ground between itself and the target before repositioning
--   thirdParty         holds off a target that is busy with someone else until it is hurt
--   thirdPartyBelow    ...under this health share (or the wait runs out: thirdPartyWait seconds)
--   avoidUnforced      fights only what shoots it, is close, or is on its objective
--   flank              works round the side of the target rather than straight at it
--   holdObjective      KOTH: stays on a hill the team already holds rather than pushing off it
--   buildRate          0-1, how readily it puts a barricade up when a build rule fires
--   buildFortify       builds at a held objective or building with nobody shooting yet
--   buildToCross       builds a wall mid-field to cross open ground toward the target
--   buildToBlock       builds behind itself to break a pursuer's line of sight while leaving
--   cookFrags          skilled enough to cook a frag for an airburst
-- One local for the whole section: this file is close to Luau's 200-local limit for a chunk.
local ARCH = {}

ARCH.Types = {
	Rusher = {
		rangeScale = 0.55, coverUse = 0.25, peek = false, repositionOnHit = 0.15, targetPick = "weakest",
		pushTargetBelow = 0.7, pushHealthAbove = 0.3, retreatHealth = 8, healBelow = 0.45,
		grenadeAt = 2, smokeToMove = false, thirdParty = false, avoidUnforced = false, flank = false,
		holdObjective = false, buildRate = 0.15, buildFortify = false, buildToCross = false, buildToBlock = false,
		cookFrags = false,
		lootGreed = 0.4, preferredWeaponClasses = { "shotgun", "smg", "doublebarrel" }, rotateEarly = false,
		chestPriority = 0.4, healPriority = 0.3,
	},
	Marksman = {
		rangeScale = 1.6, coverUse = 0.8, peek = true, repositionOnHit = 0.7, targetPick = "closest",
		pushTargetBelow = 0.3, pushHealthAbove = 0.7, retreatHealth = 30, healBelow = 0.7,
		grenadeAt = 3, smokeToMove = true, thirdParty = false, avoidUnforced = false, flank = false,
		holdObjective = false, buildRate = 0.6, buildFortify = true, buildToCross = false, buildToBlock = false,
		cookFrags = true,
		lootGreed = 0.6, preferredWeaponClasses = { "sniper", "dmr", "rifle" }, rotateEarly = true,
		chestPriority = 0.6, healPriority = 0.6,
	},
	Flanker = {
		rangeScale = 0.85, coverUse = 0.6, peek = false, repositionOnHit = 0.5, targetPick = "engaged",
		pushTargetBelow = 0.6, pushHealthAbove = 0.4, retreatHealth = 25, healBelow = 0.55,
		grenadeAt = 2, smokeToMove = true, thirdParty = false, avoidUnforced = false, flank = true,
		holdObjective = false, buildRate = 0.35, buildFortify = false, buildToCross = true, buildToBlock = false,
		cookFrags = true,
		lootGreed = 0.5, preferredWeaponClasses = { "smg", "rifle", "shotgun" }, rotateEarly = false,
		chestPriority = 0.5, healPriority = 0.5,
	},
	Anchor = {
		rangeScale = 1.15, coverUse = 0.9, peek = true, repositionOnHit = 0.1, targetPick = "threat",
		pushTargetBelow = 0.3, pushHealthAbove = 0.8, retreatHealth = 20, healBelow = 0.65,
		grenadeAt = 2, smokeToMove = false, thirdParty = false, avoidUnforced = false, flank = false,
		holdObjective = true, buildRate = 0.9, buildFortify = true, buildToCross = false, buildToBlock = false,
		cookFrags = false,
		lootGreed = 0.5, preferredWeaponClasses = { "lmg", "rifle", "dmr" }, rotateEarly = true,
		chestPriority = 0.7, healPriority = 0.6,
	},
	Opportunist = {
		rangeScale = 1.2, coverUse = 0.7, peek = false, repositionOnHit = 0.4, targetPick = "weakest",
		pushTargetBelow = 0.6, pushHealthAbove = 0.5, retreatHealth = 30, healBelow = 0.6,
		grenadeAt = 2, smokeToMove = false, thirdParty = true, thirdPartyBelow = 0.6, thirdPartyWait = 8,
		avoidUnforced = false, flank = false,
		holdObjective = false, buildRate = 0.3, buildFortify = false, buildToCross = false, buildToBlock = false,
		cookFrags = true,
		lootGreed = 0.8, preferredWeaponClasses = { "rifle", "dmr", "smg" }, rotateEarly = false,
		chestPriority = 0.8, healPriority = 0.7,
	},
	Survivor = {
		rangeScale = 1.3, coverUse = 0.9, peek = true, repositionOnHit = 0.6, targetPick = "threat",
		pushTargetBelow = 0.25, pushHealthAbove = 0.9, retreatHealth = 35, healBelow = 0.75,
		grenadeAt = 3, smokeToMove = true, thirdParty = false, avoidUnforced = true, flank = false,
		holdObjective = true, buildRate = 0.7, buildFortify = false, buildToCross = false, buildToBlock = true,
		cookFrags = false,
		lootGreed = 0.7, preferredWeaponClasses = { "rifle", "dmr", "pistol" }, rotateEarly = true,
		chestPriority = 0.6, healPriority = 0.9,
	},
}
for name, archetype in pairs(ARCH.Types) do
	archetype.name = name
end
BotService.Archetypes = ARCH.Types

-- What each gun class asks of the bot holding it, whatever its personality (Oliver: "react differently
-- depending on the gun they have"). `range` is the preferred engagement distance before the archetype
-- scales it; `minRange` is where it opens distance instead of closing (a launcher's own blast, a
-- sniper's dead zone). `peek` is the style of working a corner: "push" goes round it, "hold" waits
-- behind it and steps out to fire, "suppress" stands its ground and fires long bursts, "strafe"
-- keeps moving in the open, "lob" fires at feet and cover from range. `burst` is the shots in one
-- burst; `restScale` stretches (or trims) BotBurstRest so the class fires the same rounds a minute
-- as the stock 2-5 burst did with its guns' fire rates (throughput is a lethality dial and stays
-- put; the numbers come from tools/bot_archetype_sim.py's rounds-a-second table, and it checks them). `repositionAfterShots` moves the bot after that many
-- shots from one spot. `reloadUnder` reloads early, behind cover, once the magazine is under that
-- share. `fragToFlush` frags a target it can't see out of cover before pushing; `smokeToCross` smokes
-- its own approach; `noFrags` never wastes a throwable on what it can simply shoot.
ARCH.Classes = {
	pistol       = { range = 30, minRange = 4, peek = "strafe", burst = { 2, 4 }, restScale = 0.8, repositionAfterShots = 0, reloadUnder = 0.3, fragToFlush = false, smokeToCross = false, noFrags = false },
	revolver     = { range = 34, minRange = 4, peek = "hold", burst = { 1, 2 }, restScale = 0.25, repositionAfterShots = 0, reloadUnder = 0.35, fragToFlush = false, smokeToCross = false, noFrags = false },
	smg          = { range = 20, minRange = 3, peek = "strafe", burst = { 4, 7 }, restScale = 1.8, repositionAfterShots = 0, reloadUnder = 0.25, fragToFlush = false, smokeToCross = true, noFrags = false },
	shotgun      = { range = 12, minRange = 2, peek = "push", burst = { 1, 2 }, restScale = 0.25, repositionAfterShots = 0, reloadUnder = 0.3, fragToFlush = true, smokeToCross = true, noFrags = false },
	doublebarrel = { range = 10, minRange = 2, peek = "push", burst = { 1, 2 }, restScale = 0.25, repositionAfterShots = 0, reloadUnder = 0.5, fragToFlush = true, smokeToCross = true, noFrags = false },
	rifle        = { range = 55, minRange = 8, peek = "strafe", burst = { 2, 5 }, restScale = 1, repositionAfterShots = 0, reloadUnder = 0.3, fragToFlush = false, smokeToCross = false, noFrags = false },
	dmr          = { range = 90, minRange = 20, peek = "hold", burst = { 1, 2 }, restScale = 0.25, repositionAfterShots = 3, reloadUnder = 0.3, fragToFlush = false, smokeToCross = false, noFrags = false },
	sniper       = { range = 130, minRange = 35, peek = "hold", burst = { 1, 1 }, restScale = 0.05, repositionAfterShots = 1, reloadUnder = 0.4, fragToFlush = false, smokeToCross = false, noFrags = false },
	lmg          = { range = 60, minRange = 10, peek = "suppress", burst = { 6, 10 }, restScale = 2.75, repositionAfterShots = 0, reloadUnder = 0.2, fragToFlush = false, smokeToCross = false, noFrags = true },
	minigun      = { range = 45, minRange = 8, peek = "suppress", burst = { 8, 14 }, restScale = 3.9, repositionAfterShots = 0, reloadUnder = 0.15, fragToFlush = false, smokeToCross = false, noFrags = true },
	launcher     = { range = 45, minRange = 18, peek = "lob", burst = { 1, 1 }, restScale = 0.05, repositionAfterShots = 0, reloadUnder = 0.5, fragToFlush = false, smokeToCross = false, noFrags = true, aimLow = true },
	blaster      = { range = 28, minRange = 4, peek = "strafe", burst = { 3, 6 }, restScale = 1.4, repositionAfterShots = 0, reloadUnder = 0.3, fragToFlush = false, smokeToCross = false, noFrags = false },
	crossbow     = { range = 70, minRange = 12, peek = "hold", burst = { 1, 1 }, restScale = 0.05, repositionAfterShots = 2, reloadUnder = 0.5, fragToFlush = false, smokeToCross = false, noFrags = false },
	railgun      = { range = 110, minRange = 25, peek = "hold", burst = { 1, 1 }, restScale = 0.05, repositionAfterShots = 1, reloadUnder = 0.5, fragToFlush = false, smokeToCross = false, noFrags = false },
	cannon       = { range = 50, minRange = 15, peek = "lob", burst = { 1, 2 }, restScale = 0.25, repositionAfterShots = 0, reloadUnder = 0.5, fragToFlush = false, smokeToCross = false, noFrags = true, aimLow = true },
}
ARCH.Classes.default = ARCH.Classes.rifle
-- Empty-handed: the fight code never runs without a gun, but the dials must still exist.
ARCH.Classes.none = { range = 20, minRange = 0, peek = "strafe", burst = { 2, 5 }, restScale = 1, repositionAfterShots = 0, reloadUnder = 0.3, fragToFlush = false, smokeToCross = false, noFrags = false }
for style, class in pairs(ARCH.Classes) do
	class.style = class.style or style
end
BotService.WeaponClasses = ARCH.Classes

-- Where personality and gun disagree: overrides applied last, archetype -> class -> dial.
ARCH.Overrides = {
	Rusher = {
		sniper = { rangeScale = 0.8, repositionAfterShots = 0 }, -- a Rusher with a sniper still closes
		dmr = { rangeScale = 0.75 },
		lmg = { peekStyle = "strafe" },
	},
	Marksman = {
		shotgun = { rangeScale = 2.2, peekStyle = "hold" }, -- keeps corners between it and the target
		doublebarrel = { rangeScale = 2.2, peekStyle = "hold" },
		smg = { rangeScale = 1.8 },
	},
	Anchor = {
		shotgun = { peekStyle = "hold" }, -- holds the doorway rather than pushing through it
		smg = { peekStyle = "hold" },
	},
	Survivor = {
		shotgun = { rangeScale = 2 }, -- won't go looking for the knife fight
	},
	Flanker = {
		sniper = { rangeScale = 0.7, repositionAfterShots = 1 },
	},
}

-- The archetype x weapon-class table a bot fights by, rebuilt only when its gun changes.
function ARCH.classOf(def)
	if not def then
		return ARCH.Classes.none
	end
	return ARCH.Classes[def.style] or ARCH.Classes.default
end

function ARCH.dialsOf(bot)
	local archetype = bot.archetype or ARCH.Types.Rusher
	local class = ARCH.classOf(bot.weapon)
	local cached = bot.dials
	if cached and cached.archetype == archetype and cached.class == class then
		return cached
	end
	local dials = {}
	for key, value in pairs(archetype) do
		dials[key] = value
	end
	dials.archetype = archetype
	dials.class = class
	dials.peekStyle = class.peek
	dials.burst = class.burst
	dials.restScale = class.restScale
	dials.repositionAfterShots = class.repositionAfterShots
	dials.reloadUnder = class.reloadUnder
	dials.fragToFlush = class.fragToFlush
	dials.smokeToCross = class.smokeToCross
	dials.noFrags = class.noFrags
	dials.aimLow = class.aimLow == true
	dials.minRange = class.minRange
	local overrides = ARCH.Overrides[archetype.name]
	overrides = overrides and overrides[class.style]
	if overrides then
		for key, value in pairs(overrides) do
			dials[key] = value
		end
	end
	-- The distance it wants between itself and the target: class range x personality, never past
	-- what the gun reaches comfortably, never inside the class's dead zone.
	local reach = bot.weapon and bot.weapon.range or MatchConfig.BotEngagePreferred
	dials.range = math.max(dials.minRange + 4, math.min(class.range * dials.rangeScale, reach * 0.6))
	bot.dials = dials
	return dials
end

-- How many of each archetype a mode wants, out of a hundred. Team modes want role balance PER TEAM
-- (below); the hill wants bodies that stay on it.
ARCH.Mix = {
	BattleRoyale = { Rusher = 20, Marksman = 15, Flanker = 15, Anchor = 10, Opportunist = 15, Survivor = 25 },
	TeamDeathmatch = { Rusher = 30, Marksman = 20, Flanker = 20, Anchor = 15, Opportunist = 10, Survivor = 5 },
	KingOfTheHill = { Rusher = 20, Marksman = 15, Flanker = 15, Anchor = 35, Opportunist = 10, Survivor = 5 },
}
BotService.ArchetypeMix = ARCH.Mix

-- Stable order for a deck: pairs() order is not.
ARCH.Order = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }

function BotService.AssignArchetype(bot, name)
	local archetype = type(name) == "table" and name or ARCH.Types[name]
	if not archetype then
		return nil
	end
	bot.archetype = archetype
	bot.dials = nil
	if bot.character then
		-- Read by tools/bot_probe.lua and the nameplate/debug overlays; nothing gameplay keys off it.
		bot.character:SetAttribute("Archetype", archetype.name)
	end
	return archetype
end

function BotService.ArchetypeOf(bot)
	return type(bot) == "table" and bot.isBot and (bot.archetype or ARCH.Types.Rusher) or nil
end

function BotService.DialsOf(bot)
	return type(bot) == "table" and bot.isBot and ARCH.dialsOf(bot) or nil
end

-- Roblox's stock R15 animations. These ship with the platform, so they resolve without
-- uploading anything; swap the ids here if you want a different set.
--
-- Every one of these was checked with `tools/anim_probe.lua` before being added, because
-- setupAnimations below drops a failed load without a word: an id that does not resolve is not
-- an error, it is simply no animation. `hold` is the stock tool pose and is the important one —
-- it plays at Action priority over whatever the legs are doing, so a bot carrying a rifle stops
-- running the empty-handed cycle. `jump` and `fall` stop them walking through the air.
local ANIM_IDS = {
	idle = { id = "rbxassetid://507766388", looped = true },
	walk = { id = "rbxassetid://507777826", looped = true },
	run = { id = "rbxassetid://507767714", looped = true },
	jump = { id = "rbxassetid://507765000", looped = false },
	fall = { id = "rbxassetid://507767968", looped = true },
	hold = { id = "rbxassetid://507768375", looped = true, overArms = true },
}

-- Bots come out of CreateHumanoidModelFromDescription as identical grey mannequins.
-- Giving each one a shirt/skin pairing is what stops a lobby of 29 looking like clones.
local OUTFITS = {
	{ shirt = Color3.fromRGB(196, 62, 62), pants = Color3.fromRGB(48, 52, 64) },
	{ shirt = Color3.fromRGB(52, 96, 186), pants = Color3.fromRGB(38, 42, 52) },
	{ shirt = Color3.fromRGB(74, 150, 82), pants = Color3.fromRGB(60, 50, 40) },
	{ shirt = Color3.fromRGB(226, 178, 58), pants = Color3.fromRGB(56, 48, 44) },
	{ shirt = Color3.fromRGB(142, 76, 190), pants = Color3.fromRGB(40, 40, 56) },
	{ shirt = Color3.fromRGB(232, 124, 60), pants = Color3.fromRGB(52, 44, 38) },
	{ shirt = Color3.fromRGB(58, 168, 178), pants = Color3.fromRGB(36, 48, 52) },
	{ shirt = Color3.fromRGB(214, 214, 220), pants = Color3.fromRGB(60, 62, 70) },
}

local SKIN_TONES = {
	Color3.fromRGB(234, 196, 162),
	Color3.fromRGB(198, 152, 112),
	Color3.fromRGB(150, 106, 72),
	Color3.fromRGB(104, 72, 50),
	Color3.fromRGB(246, 222, 196),
}

local TORSO_PARTS = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "Torso" }
local LEG_PARTS = {
	"LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
	"RightUpperLeg", "RightLowerLeg", "RightFoot",
	"Left Leg", "Right Leg",
}
local SKIN_PARTS = {
	"Head", "LeftLowerArm", "RightLowerArm", "LeftHand", "RightHand",
	"Left Arm", "Right Arm",
}

-- Share of bots that spawn wearing a shop accessory, so lobbies look dressed up.
local BOT_ACCESSORY_CHANCE = 0.35

-- Share of bots that bring a brainrot companion. Mostly low rarities, so a lobby of bots
-- doesn't out-damage the real players in it.
local BOT_COMPANION_CHANCE = 0.3
local BOT_COMPANION_ODDS = { Common = 62, Uncommon = 30, Rare = 8, Epic = 0, Legendary = 0 }

local function paintBot(character)
	local outfit = OUTFITS[math.random(1, #OUTFITS)]
	local skin = SKIN_TONES[math.random(1, #SKIN_TONES)]

	local function paint(names, color, material)
		for _, name in ipairs(names) do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				part.Color = color
				part.Material = material
			end
		end
	end

	paint(TORSO_PARTS, outfit.shirt, Enum.Material.Fabric)
	paint(LEG_PARTS, outfit.pants, Enum.Material.Fabric)
	paint(SKIN_PARTS, skin, Enum.Material.SmoothPlastic)

	-- Crate exclusives are left off bots, so seeing one still means a real player pulled it.
	if math.random() < BOT_ACCESSORY_CHANCE then
		local pool = CosmeticData.OfKind("Accessory", true)
		if #pool > 0 then
			AccessoryService.Attach(character, pool[math.random(1, #pool)])
		end
	end
end

-- Server-owned NPCs have no Animate LocalScript, which is why they slide around instead of
-- walking. Loading the tracks onto the Animator directly is the server-side equivalent.
local function setupAnimations(bot, humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local tracks = {}
	for name, entry in pairs(ANIM_IDS) do
		local animation = Instance.new("Animation")
		animation.AnimationId = entry.id
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Looped = entry.looped
			-- The gun pose has to outrank the walk cycle or the legs' animation wins and the
			-- arms drop back to their empty-handed swing.
			track.Priority = entry.overArms and Enum.AnimationPriority.Action or Enum.AnimationPriority.Movement
			tracks[name] = track
		end
	end

	bot.tracks = tracks
	bot.currentTrack = nil
end

-- Called every think tick: match the playing track to what the humanoid is actually doing.
local function updateAnimation(bot, humanoid)
	local tracks = bot.tracks
	if not tracks then
		return
	end

	-- The gun pose runs over the top of the movement track rather than instead of it, so a bot
	-- walks and holds its weapon at the same time instead of choosing between them.
	local hold = tracks.hold
	if hold then
		local character = bot.character
		local wantHold = humanoid.Health > 0 and character ~= nil and character:FindFirstChild("HeldGun") ~= nil
		if wantHold and not hold.IsPlaying then
			hold:Play(0.2)
		elseif not wantHold and hold.IsPlaying then
			hold:Stop(0.2)
		end
	end

	local speed = humanoid.MoveDirection.Magnitude * humanoid.WalkSpeed
	local state = humanoid:GetState()
	local wanted
	if state == Enum.HumanoidStateType.Freefall then
		wanted = "fall"
	elseif state == Enum.HumanoidStateType.Jumping then
		wanted = "jump"
	elseif speed < 0.5 then
		wanted = "idle"
	elseif speed > 20 then
		wanted = "run"
	else
		wanted = "walk"
	end

	if bot.currentTrack == wanted then
		return
	end

	local previous = bot.currentTrack and tracks[bot.currentTrack]
	if previous then
		previous:Stop(0.15)
	end

	local track = tracks[wanted]
	if track then
		track:Play(0.15)
	end
	bot.currentTrack = wanted
end

local bots = {}
local template = nil
local running = false

-- Bumped by Clear(). Spawn checks it after every yield so a spawn in progress stops the
-- moment the match it was for is torn down.
local spawnGeneration = 0

-- Bumped by Start() and Clear(). The think loop stops when it changes, so a Clear() followed by a
-- Start() inside one think interval can't leave the old loop running alongside the new one (it
-- only checked a flag, which the Start() had already set back to true).
local loopGeneration = 0

-- Every bot's golden-angle fan-out slot (modeObjective), assigned once here and never reused
-- within a match. Spawn() used to hand out `index` from its own loop (1..count) instead, which
-- is fine for one big batch but not for a team mode's replacement bots: spawnReplacementBot calls
-- Spawn(1, ...) one bot at a time, so `index` was 1 on every call and every replacement landed on
-- the exact same golden-angle point as every other replacement, all standing together. Reset by
-- Clear() so slot numbers stay small and stable within one match; the golden-angle spread works
-- for any starting value, so continuing to climb across a match is harmless too.
local nextSlot = 0

local LOOT_SEEK_RANGE = 200

-- Supply drops pull bots in from further away, but only nearby ones — a map-wide radius would
-- send all 29 bots stampeding toward every drop.
-- Oliver 15:27: bots weren't going for supply drops; they are rare and worth a long walk (was 300).
local SUPPLY_SEEK_RANGE = 900

--------------------------------------------------------------------------------
-- Other modules, reached lazily
--------------------------------------------------------------------------------

-- MatchService requires this module while it loads, so it can't be required back at the top. By
-- the time a bot thinks, it has finished loading and require hands back the finished table. The
-- movement tab's stamina, sprint and base-speed functions live there.
local lazyModules = {}
local function lazy(name)
	local cached = lazyModules[name]
	if cached == nil then
		local module = script.Parent:FindFirstChild(name)
		local ok, result = false, nil
		if module then
			ok, result = pcall(require, module)
		end
		cached = ok and type(result) == "table" and result or false
		lazyModules[name] = cached
	end
	return cached or nil
end

-- Live blasts about to go off near a point, from ProjectileService.Dangers, or an empty list.
local NO_DANGERS = {}
local function dangersNear(position, radius)
	local api = lazy("ProjectileService")
	if not (api and api.Dangers) then
		return NO_DANGERS
	end
	return api.Dangers(position, radius) or NO_DANGERS
end

local function inDanger(point, dangers)
	for _, danger in ipairs(dangers) do
		if (danger.position - point).Magnitude < (danger.radius or 13) + 2 then
			return danger
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Rig
--------------------------------------------------------------------------------

-- Bots are simulated by the server. Left to automatic network ownership, a bot's physics goes to the
-- nearest player's client: bots stutter at every handoff, the server's own pushes (a stuck hop, a Rot
-- Rocket, a climb or vault run by MovementService) get fought or overwritten, and a modified client
-- that owns a bot can move it wherever it likes, say in front of its own gun. So the server claims
-- each bot's assembly when it spawns, again when anything is welded on or taken off (the canopy, a
-- gun), and checks now and then that the claim still holds. Errors (an anchored part in the
-- assembly) just leave it for the next check.
local function claimPhysics(character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsDescendantOf(workspace) then
		return false
	end
	-- Just claim it. Reading the current owner first is no cheaper and GetNetworkOwner() ERRORS while
	-- ownership is automatic, which is exactly the case this has to fix; sharing one pcall with the
	-- claim meant the claim never ran. The last failure is kept so a probe can print why rather than
	-- reporting "not claimed" with no reason.
	local ok, err = pcall(root.SetNetworkOwner, root, nil)
	if not ok then
		BotService.ClaimError = tostring(err)
	end
	return ok
end
BotService.ClaimPhysics = claimPhysics

local function ensureTemplate()
	if template then
		return template
	end

	local description = Instance.new("HumanoidDescription")
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)

	if not ok or not model then
		warn("[BotService] Could not build a bot rig: " .. tostring(model))
		return nil
	end

	model.Name = "BotTemplate"
	template = model
	return template
end

local function shuffled(list)
	local pool = table.clone(list)
	for index = #pool, 2, -1 do
		local swap = math.random(1, index)
		pool[index], pool[swap] = pool[swap], pool[index]
	end
	return pool
end

-- `spawnWeapon` only, and never a staged gun: a def marked `staged` is one that isn't in the loot
-- pool yet (weight 0), and rolling by rarity here would put it in players' hands through bots.
local function rollWeapon()
	local rarity = Rarity.Roll(WEAPON_ODDS)
	local pool = {}
	for _, def in pairs(WeaponData.Weapons) do
		if def.rarity == rarity and not def.staged and not BOT_WEAPON_HOLD[def.id] then
			table.insert(pool, def)
		end
	end
	if #pool == 0 then
		return WeaponData.Get("SahurPistol")
	end
	return pool[math.random(1, #pool)]
end

-- Same model builder players use, so bots aren't visibly holding a different object.
local function giveBotGun(character, def)
	local existing = character:FindFirstChild("HeldGun")
	if existing then
		existing:Destroy()
	end

	local model, receiver = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal)
	WeaponService.MountGun(character, model, receiver)

	-- Raise it now rather than on the next think tick, so a bot is never seen carrying a gun at its side.
	for _, bot in ipairs(bots) do
		local hold = bot.character == character and bot.tracks and bot.tracks.hold
		if hold and not hold.IsPlaying and bot.humanoid and bot.humanoid.Health > 0 then
			hold:Play(0.2)
		end
	end
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function flatDistance(a, b)
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function flatLook(root)
	local look = flat(root.CFrame.LookVector)
	return look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, -1)
end

-- A wander goal can be most of a map away, and ComputeAsync over thousands of studs is slow
-- and frequently fails — at which point the bot fell back to walking in a straight line
-- into whatever was in the way. Long goals are walked in short legs instead, each of which
-- paths reliably. The leg's height comes from the terrain so it isn't buried in a hill.
local MAX_LEG = 220

local function nextLeg(from, goal)
	local delta = Vector3.new(goal.X - from.X, 0, goal.Z - from.Z)
	local flatPoint = delta.Magnitude <= MAX_LEG and Vector3.new(goal.X, 0, goal.Z)
		or Vector3.new(from.X, 0, from.Z) + delta.Unit * MAX_LEG
	return Vector3.new(flatPoint.X, MapGenerator.GroundHeightAt(flatPoint.X, flatPoint.Z) + 3, flatPoint.Z)
end

--------------------------------------------------------------------------------
-- Storm
--------------------------------------------------------------------------------

-- The circle a bot should be heading for: the next one once it's been announced, otherwise the
-- current one. Nil while no storm is running.
local function safeCircle()
	local storm = StormService.GetState()
	if storm.status == "Idle" or storm.radius <= 0 then
		return nil
	end
	if storm.targetRadius and storm.targetRadius > 0 then
		return storm.targetCenter, storm.targetRadius, storm
	end
	return storm.center, storm.radius, storm
end

-- How pressed a bot is by the storm: 0 when it's comfortably inside where the storm is going, 1
-- when getting there at walking pace takes every second the storm leaves it, more when it can't
-- make it. Always at least 1 when already outside the current circle.
local function stormPressure(position)
	local center, radius, storm = safeCircle()
	if not center then
		return 0
	end
	local outside = StormService.IsOutside(position)
	local need = flatDistance(position, center) - radius * 0.8
	if need <= 0 and not outside then
		return 0
	end
	-- A circle that isn't closing sets no deadline: anywhere inside it is fine, and only being
	-- OUTSIDE is urgent. Without this a boundary that never moves (a game mode's fixed arena, or the
	-- last circle of a match) read as closing the moment a bot passed 80% of the radius, and it would
	-- drop its loot and sprint for the middle for no reason.
	local closing = storm.status == "Waiting" or storm.status == "Shrinking"
	if not outside and not closing then
		return 0
	end
	local seconds = storm.secondsLeft or 0
	if storm.status == "Waiting" then
		local phase = MatchConfig.StormPhases[storm.phase]
		seconds += storm.shrinkSeconds or (phase and phase.shrinkTime) or 30
	end
	local pressure = math.max(0, need) / (MatchConfig.BotWalkSpeed * math.max(1, seconds))
	if outside then
		pressure = math.max(pressure, 1)
	end
	return pressure
end

-- Somewhere to wander: inside the circle the storm is heading for, on the bot's own side of it, so
-- rotating in doesn't mean walking across the whole circle and out the other side.
local function stormGoal(position)
	local center, radius = safeCircle()
	if not center then
		local angle = math.random() * math.pi * 2
		local reach = 60 + math.random() * 140
		return position + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
	end
	local fromCenter = flat(position - center)
	local base = fromCenter.Magnitude > 1 and math.atan2(fromCenter.Z, fromCenter.X) or math.random() * math.pi * 2
	local angle = base + (math.random() - 0.5) * math.rad(150)
	local distance = math.sqrt(math.random()) * math.max(10, radius * 0.7)
	return center + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
end

-- A combat step may not leave the storm's current circle, except to get back into it.
local function stormAllows(from, point)
	local storm = StormService.GetState()
	if storm.status == "Idle" or storm.radius <= 0 then
		return true
	end
	if flatDistance(point, storm.center) <= storm.radius - 6 then
		return true
	end
	return StormService.IsOutside(from) and flatDistance(point, storm.center) < flatDistance(from, storm.center)
end

local function insideCircle(point, center, radius, share)
	return not center or flatDistance(point, center) <= radius * (share or 1)
end

--------------------------------------------------------------------------------
-- Perception
--------------------------------------------------------------------------------

-- RAYCAST BUDGET. Rays are the bots' frame cost: a think can cast 6 sight rays, 5 combat-step checks
-- of up to 6 rays each and a cover search of up to 24 sight rays plus 6 step checks, and 13 bots
-- think in one frame. Every bot ray goes through castRay, which counts it against one frame's cap
-- and refuses the rest, least important class first: "idle" (a wandering or looting bot checking
-- its footing) is cut at half the cap, "navigation" (combat steps, cover, floors, fleeing) at three
-- quarters, "combat" (the sight lines that decide whether anyone gets shot) only at the cap itself.
-- The cap is sized so an ordinary slice never reaches it; it is there for the burst (a fight
-- breaking out in a crowd, the drop) so that burst costs a bounded number of rays a frame and a
-- few bots wait one think, rather than the whole server waiting on the frame. A refused ray returns
-- nil, false; callers take the cautious answer and don't cache it. tools/perf_bot_cost.py runs
-- this against a crowd and checks the order of refusal; tools/perf_tick_probe.lua reads
-- Stats.raysFrameMax / raysDenied in Studio.
local castRay
BotService.RaycastBudget = { FrameCap = 240, Share = { combat = 1, navigation = 0.75, idle = 0.5 } }
do
	local budget = BotService.RaycastBudget
	local spent = 0
	-- One RaycastParams and one filter list per class, refilled rather than rebuilt: RaycastParams.new
	-- plus a filter table per ray was two allocations for every sight line.
	local folderNames = { "Loot", "Effects", "Companions" }
	local folders = { at = -1 }

	-- The workspace folders every bot ray looks past, found once a frame rather than per ray.
	function budget.Folders()
		if folders.at ~= BotService.Tick then
			folders.at = BotService.Tick
			for index, name in ipairs(folderNames) do
				folders[index] = workspace:FindFirstChild(name) or false
			end
		end
		return folders
	end

	-- Fill `filter` with `first` and the folders (nil entries skipped), for params.FilterDescendantsInstances.
	function budget.Filter(filter, first, withCompanions)
		table.clear(filter)
		filter[1] = first
		local list = budget.Folders()
		for index = 1, #folderNames do
			local folder = list[index]
			if folder and (withCompanions ~= false or index ~= 3) then
				filter[#filter + 1] = folder
			end
		end
		return filter
	end

	function budget.BeginFrame()
		if spent > STATS.raysFrameMax then
			STATS.raysFrameMax = spent
		end
		spent = 0
	end

	function budget.Spent()
		return spent
	end

	function budget.Remaining(priority)
		local share = budget.Share[priority or "navigation"] or budget.Share.navigation
		return math.max(0, math.floor(budget.FrameCap * share) - spent)
	end

	function budget.Cast(origin, direction, params, priority)
		priority = priority or "navigation"
		local share = budget.Share[priority] or budget.Share.navigation
		if spent >= budget.FrameCap * share then
			STATS.raysDenied += 1
			return nil, false
		end
		spent += 1
		STATS.rays += 1
		if priority == "combat" then
			STATS.raysCombat += 1
		elseif priority == "idle" then
			STATS.raysIdle += 1
		else
			STATS.raysNavigation += 1
		end
		return workspace:Raycast(origin, direction, params), true
	end
	-- A spatial query that is not a ray (a driving bot's block sweeps, BotNav.DriveSense), counted
	-- against the same cap and share. True if granted.
	function budget.Spend(priority)
		priority = priority or "navigation"
		if spent >= budget.FrameCap * (budget.Share[priority] or budget.Share.navigation) then
			STATS.raysDenied += 1
			return false
		end
		spent += 1
		STATS.rays += 1
		STATS.raysNavigation += priority == "navigation" and 1 or 0
		return true
	end
	castRay = budget.Cast
	-- BotNav casts through the same budget (it loads before this module, so it is handed the function).
	BotNav.CastRay = castRay
	BotNav.CastSpend = budget.Spend
	BotNav.CastRemaining = budget.Remaining

	-- The sight-line params (hasLineOfSight). Terrain water is not cover: a raycast hits it unless
	-- told not to, so a bot would refuse to shoot across a river at a target a player could hit — the
	-- shot itself ignores water (CombatService.buildRaycastParams), as does the client's own trace.
	budget.LosParams = RaycastParams.new()
	budget.LosParams.FilterType = Enum.RaycastFilterType.Exclude
	budget.LosParams.IgnoreWater = true
	budget.LosFilter = {}
	-- The barricade-finding params (coverBetween): only what can be collided with counts as cover.
	budget.CoverParams = RaycastParams.new()
	budget.CoverParams.FilterType = Enum.RaycastFilterType.Exclude
	budget.CoverParams.RespectCanCollide = true
	budget.CoverParams.IgnoreWater = true
	budget.CoverFilter = {}
	-- The "can that spot see me" params (exposedTo).
	budget.ExposedParams = RaycastParams.new()
	budget.ExposedParams.FilterType = Enum.RaycastFilterType.Exclude
	budget.ExposedParams.RespectCanCollide = true
	budget.ExposedParams.IgnoreWater = true
	budget.ExposedFilter = {}
end

-- Returns visible, denied. `denied` is true when the ray budget refused the frame's ray, in which
-- case `visible` is the cautious false and the caller must not cache it.
local function hasLineOfSight(fromPart, toCharacter, botCharacter)
	local toPart = toCharacter:FindFirstChild("HumanoidRootPart")
	if not toPart then
		return false, false
	end

	-- A smoke cloud hides whoever is behind it (ProjectileService).
	if CombatService.SmokeBlocks and CombatService.SmokeBlocks(fromPart.Position, toPart.Position) then
		return false, false
	end

	local budget = BotService.RaycastBudget
	local params = budget.LosParams
	local filter = budget.Filter(budget.LosFilter, botCharacter)
	-- A bot at the wheel looks out from inside its own vehicle: its roof and panels aren't cover, or
	-- it would never see anyone to fire the mount at.
	local seated = botCharacter:FindFirstChildOfClass("Humanoid")
	local node = seated and seated.SeatPart
	while node and node ~= workspace and not node:GetAttribute("VehicleModel") do
		node = node.Parent
	end
	if node and node ~= workspace then
		table.insert(filter, node)
	end
	params.FilterDescendantsInstances = filter

	-- Window glass is see-through, and a shot breaks it on the way (CombatService), so a pane
	-- in the way is looked past rather than counted as cover. A few panes at most in one line.
	local result, granted
	for _ = 1, 4 do
		result, granted = castRay(fromPart.Position, toPart.Position - fromPart.Position, params, "combat")
		if not granted then
			return false, true
		end
		if not (result and CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(result.Instance)) then
			break
		end
		table.insert(filter, result.Instance)
		params.FilterDescendantsInstances = filter
	end
	return result ~= nil and result.Instance:IsDescendantOf(toCharacter), false
end

-- The living combatants, looked up once per think tick for every bot to share: token, character, root,
-- humanoid, whether it is a player, and the root's position at the time. Positions are at most one
-- think slice old (BotThinkInterval / THINK_SLICES); line of sight always uses the live root.
--
-- SPATIAL QUERY. The list is also binned into a uniform grid, so "who is within R of here" reads
-- the few cells R covers instead of every combatant: findTarget (vision range), squadCentroid
-- (80), the outnumbered count (70) and clusterAround (10) used to each walk the whole list for
-- every bot, N² a slice. Rows are pooled and refilled, not rebuilt, so a refresh allocates nothing
-- once the pool has grown to the lobby. combatantsNear returns one shared scratch list, valid until
-- the next call: read it there and then; never keep it or hand it on.
local combatantList = {}
local combatantsNear
local refreshCombatants
BotService.SpatialQuery = {}
do
	local query = BotService.SpatialQuery
	local FLOOR = math.floor
	local OFFSET = 32768 -- cells are keyed (cx + OFFSET) + (cz + OFFSET) * 65536: unique to ±2M studs

	-- A grid of rows that carry `.position`. Cells are reused across Rebuild calls; `Near` fills and
	-- returns the grid's own scratch list.
	function query.NewGrid(cellSize)
		local grid = { cellSize = cellSize, cells = {}, used = {}, scratch = {}, count = 0 }
		local cells, used, scratch = grid.cells, grid.used, grid.scratch

		local function keyOf(x, z)
			return (FLOOR(x / cellSize) + OFFSET) + (FLOOR(z / cellSize) + OFFSET) * 65536
		end

		function grid.Rebuild(rows)
			for index = 1, #used do
				table.clear(used[index])
			end
			table.clear(used)
			for index = 1, #rows do
				local row = rows[index]
				local position = row.position
				local key = keyOf(position.X, position.Z)
				local cell = cells[key]
				if not cell then
					cell = {}
					cells[key] = cell
				end
				if #cell == 0 then
					used[#used + 1] = cell
				end
				cell[#cell + 1] = row
			end
			grid.count = #rows
		end

		-- Rows within `radius` of `position` (3D distance, as the linear scans measured), in the
		-- shared scratch list. `accept(row)` may filter; the distance is stored on `distances[i]`.
		function grid.Near(position, radius, accept)
			table.clear(scratch)
			local n = 0
			local px, pz = position.X, position.Z
			local minX, maxX = FLOOR((px - radius) / cellSize), FLOOR((px + radius) / cellSize)
			local minZ, maxZ = FLOOR((pz - radius) / cellSize), FLOOR((pz + radius) / cellSize)
			for cz = minZ, maxZ do
				local rowKey = (cz + OFFSET) * 65536 + OFFSET
				for cx = minX, maxX do
					local cell = cells[rowKey + cx]
					if cell then
						for index = 1, #cell do
							local row = cell[index]
							if (row.position - position).Magnitude <= radius and (accept == nil or accept(row)) then
								n += 1
								scratch[n] = row
							end
						end
					end
				end
			end
			return scratch, n
		end

		return grid
	end

	local grid = query.NewGrid(128)
	local pool = {}
	local playerPositions = {}

	function refreshCombatants()
		BotService.Tick += 1
		-- A tick is a frame to the ray budget: whoever drives the thinks (the loop, or a sim calling
		-- updateBot itself) opens the budget here, so it can never run dry across ticks.
		BotService.RaycastBudget.BeginFrame()
		local count = 0
		local players = 0
		for character, token in pairs(Combatants.All()) do
			if character.Parent then
				local root = character:FindFirstChild("HumanoidRootPart")
				local humanoid = root and character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					count += 1
					local row = pool[count]
					if not row then
						row = {}
						pool[count] = row
					end
					row.token, row.character, row.root, row.humanoid = token, character, root, humanoid
					row.position = root.Position
					row.isPlayer = Combatants.IsPlayer(token)
					combatantList[count] = row
					if row.isPlayer then
						players += 1
						playerPositions[players] = row.position
					end
				end
			end
		end
		for index = #combatantList, count + 1, -1 do
			combatantList[index] = nil
		end
		for index = #playerPositions, players + 1, -1 do
			playerPositions[index] = nil
		end
		grid.Rebuild(combatantList)
	end

	function combatantsNear(position, radius, accept)
		return grid.Near(position, radius, accept)
	end
	query.Combatants = combatantsNear

	-- All living combatants this tick (the snapshot itself; read-only).
	function query.All()
		return combatantList
	end

	-- How far the nearest living player is from `position`, or math.huge with no players in the match.
	function query.NearestPlayerDistance(position)
		local best = math.huge
		for index = 1, #playerPositions do
			local distance = (playerPositions[index] - position).Magnitude
			if distance < best then
				best = distance
			end
		end
		return best
	end

	function query.Clear()
		table.clear(combatantList)
		table.clear(playerPositions)
		grid.Rebuild(combatantList)
	end
end

-- Line-of-sight rays are the expensive part of looking around, so each think tests at most a few
-- fresh pairs, best candidate first. Only "can't see them" is remembered, for a moment: a target the
-- bot CAN see is looked at again every think, so someone who ducks behind a wall stops being shot
-- straight away. (Caching "visible" too let hits land through the wall for up to that moment.)
local LOS_CHECKS_PER_THINK = 3
local SIGHT_CACHE_SECONDS = 0.4

-- Inside this cone a target is noticed straight away; outside it (behind the bot) it takes
-- MatchConfig.BotRearNoticeTime, unless it's the one shooting.
local FRONT_CONE_COS = math.cos(math.rad(75))

-- How long being shot marks the shooter as the threat that outranks everything else.
local THREAT_WINDOW = 3

-- Returns visible, computed, entry: `entry` is the cache row, which findTarget also uses to keep
-- the barricade test (coverBetween) on the same cadence as the sight ray it follows.
-- `recheck` skips the cache: findTarget passes it for its best-scored candidate only, so the one a
-- bot most wants to fight is looked at every think (someone stepping out from a corner is seen on
-- the next think, not up to two later: the 0.4 s row outlived one ~0.267 s think). It spends the
-- same LOS_CHECKS_PER_THINK budget, so a think's worst case is unchanged (#75/#81). Not for a row
-- that already found a barricade in the way: that target is being fought through the cover anyway.
local function sightOf(bot, head, token, character, now, recheck)
	local entry = bot.sight[token]
	local fresh = recheck and not (entry and entry.cover)
	if entry and not entry.visible and not fresh and now - entry.at < SIGHT_CACHE_SECONDS then
		return false, false, entry
	end
	STATS.sightChecks += 1
	local visible, denied = hasLineOfSight(head, character, bot.character)
	if denied then
		-- The frame's ray budget is spent: nothing is learned, nothing is cached, and this think
		-- carries on with what it already knew. The next think looks again.
		STATS.sightDenied += 1
		return false, false, nil
	end
	-- The row is reused when there is one: a fresh table per sight ray was one allocation per ray.
	if entry then
		entry.at, entry.visible, entry.cover = now, visible, nil
	else
		entry = { at = now, visible = visible }
		bot.sight[token] = entry
	end
	return visible, true, entry
end

-- A player's bullet does not pass through a barricade: it takes a bite out of it and stops
-- (CombatService.Fire). So a bot facing someone behind one shouldn't refuse the shot and stand
-- there — it should do what a player does and shoot the cover down. This finds cover of that kind on
-- the line: a player-built barricade, bunker or fortress. Map walls are deliberately NOT included;
-- a bot demolishing a house to reach someone inside is a different (and much stronger) behaviour
-- than what "shoot through barricades" asks for, and is worth deciding on its own.
local function coverBetween(bot, head, targetRoot)
	if not (CombatService.StructureFromPart and CombatService.DamageStructure) then
		return nil
	end
	STATS.coverChecks += 1
	local budget = BotService.RaycastBudget
	local params = budget.CoverParams
	-- Companions hover beside their owners and take raycasts; they aren't cover.
	local filter = budget.CoverFilter
	filter[1] = bot.character
	filter[2] = budget.Folders()[3] or nil
	params.FilterDescendantsInstances = filter
	-- Refused by the frame's ray budget: no barricade found this think (the target is treated as
	-- hidden by the world, as it was a moment ago); the next think asks again.
	local hit = castRay(head.Position, targetRoot.Position - head.Position, params, "combat")
	if not hit then
		return nil
	end
	local structure = CombatService.StructureFromPart(hit.Instance)
	-- Only barricades (250 hp), which is what was asked for: a bunker or fortress would have a bot
	-- with a pistol plinking for minutes. And never its OWN barricade — a bot fighting from behind the
	-- wall it just built would otherwise shoot that wall down.
	if not structure or structure.Name ~= "RotBarricade" or bot.ownStructures[structure] then
		return nil
	end
	-- Nor a TEAMMATE's (DefenseService.OwnerOf existed for exactly this and nothing asked it): in a
	-- team mode a bot would otherwise shoot down the cover its own side is fighting from.
	local owner = DefenseService.OwnerOf and DefenseService.OwnerOf(structure) or nil
	if owner and owner ~= bot and not hostile(bot, owner) then
		return nil
	end
	return structure, hit.Position
end

-- Team modes: the target a teammate is fighting right now, one per team, so a squad puts its fire on
-- one body (focus fire) instead of six bots on six targets. Written by reportSighting from fight(),
-- read by findTarget through bot.focusTeam (set at the same time, so a bot that has never fought
-- pays nothing). Cleared in Clear().
local teamFocus = {}

-- The best target this bot can see and has noticed, or nil. Candidates are scored before any ray:
-- nearest first, players pulled closer by BotPlayerBias, whoever just shot us far closer, the current
-- target a little closer (so a bot doesn't flick between two), and the badly hurt a little closer.
--
-- The old version picked the nearest combatant and only then asked whether it was visible — so a bot
-- with an enemy hiding behind a wall 40 studs away ignored the one shooting it from 100.
--
-- Candidate rows are pooled and the list reused: findTarget runs for every armed bot every think,
-- and a fresh list plus a row per combatant in reach was the biggest per-think allocation. The row
-- returned is valid until the next findTarget call (fight() and botVehicleThink use it at once;
-- quickFirstShot copies what it needs before its timer).
--
-- One table for the file's pooled per-think rows (the main chunk is near Luau's 200-local limit;
-- tools/verify.py counts them): findTarget's candidates and planCombatMove's options.
local scratch = {
	candidatePool = {},
	candidates = {},
	-- planCombatMove sorts combatOptions in place, so it is refilled from baseOptions (the nine
	-- standard moves) plus, for a Flanker, the two flankOptions rows, every replan.
	combatOptions = {},
	baseOptions = {
		{ kind = 1, hold = true }, { kind = 2, side = 1 }, { kind = 3, side = -1 }, { kind = 4, side = 1 },
		{ kind = 5, side = -1 }, { kind = 6, side = 1 }, { kind = 7, side = -1 }, { kind = 8, side = 1 },
		{ kind = 9, side = -1 },
	},
	flankOptions = { { flank = true }, { flank = true } },
	coverRadii = { 10, 18, 28 },
	byScore = function(a, b)
		return a.score < b.score
	end,
}

local function findTarget(bot, root, head, now)
	local threat = now - bot.lastHurtAt < THREAT_WINDOW and CombatService.GetLastAttacker(bot) or nil
	local reach = math.max(MatchConfig.BotVisionRange, bot.weapon and bot.weapon.range or 0)
	local candidatePool, candidates = scratch.candidatePool, scratch.candidates
	table.clear(candidates)
	local count = 0

	local position = root.Position
	-- Only combatants within reach can qualify, so only they are looked at (the grid, not the list).
	local near, nearCount = combatantsNear(position, reach)
	STATS.candidatesExamined += nearCount
	for index = 1, nearCount do
		local entry = near[index]
		local token = entry.token
		if token ~= bot and entry.humanoid.Health > 0 and hostile(bot, token) then
			local distance = (entry.position - position).Magnitude
			-- Past vision range only whoever is shooting us, and only as far as our gun reaches.
			if distance <= MatchConfig.BotVisionRange or (token == threat and distance <= reach) then
				local humanoid = entry.humanoid
				local score = distance
				if entry.isPlayer then
					score /= MatchConfig.BotPlayerBias
				end
				if token == threat then
					score *= 0.45
				end
				if token == bot.target then
					score *= 0.7
				end
				if humanoid.Health < humanoid.MaxHealth * 0.4 then
					score *= 0.85
				end
				-- BOT ARCHETYPES: what the personality favours. "weakest" pulls the hurt closer in
				-- proportion to what they have lost; "threat" doubles down on whoever is shooting us;
				-- "engaged" (Flanker, Opportunist) prefers someone busy fighting somebody else. "closest"
				-- is the score as it stands. A team's focus target is pulled closer for everyone on it.
				local pick = bot.archetype and bot.archetype.targetPick
				if pick == "weakest" then
					score *= 0.45 + 0.55 * humanoid.Health / math.max(1, humanoid.MaxHealth)
				elseif pick == "threat" and token == threat then
					score *= 0.5
				elseif pick == "engaged" then
					local attacker, _, hitAt = CombatService.GetLastAttacker(token)
					if attacker and attacker ~= bot and hitAt and now - hitAt < THREAT_WINDOW then
						score *= 0.55
					end
				end
				local focus = bot.focusTeam and teamFocus[bot.focusTeam]
				if focus and focus.token == token and focus.by ~= bot and now - focus.at < THREAT_WINDOW then
					score *= 0.6
					STATS.focusFire += 1
				end
				count += 1
				local row = candidatePool[count]
				if not row then
					row = {}
					candidatePool[count] = row
				end
				row.token, row.character, row.root, row.distance, row.score = token, entry.character, entry.root, distance, score
				row.throughCover = nil
				candidates[count] = row
			end
		end
	end
	if count == 0 then
		return nil
	end
	table.sort(candidates, scratch.byScore)

	local look = flatLook(root)
	local fresh = 0
	for index, candidate in ipairs(candidates) do
		local visible, computed, entry = sightOf(bot, head, candidate.token, candidate.character, now, index == 1)
		if computed then
			fresh += 1
		end
		-- No `entry` means the ray budget refused the look: nothing is known, so nothing is decided.
		if not visible and entry and candidate.distance <= 120 then
			-- Hidden by a barricade rather than by the world: engage, and the shots go into the cover.
			-- The barricade ray is cast when the sight ray is (or once, for a row made while the
			-- target was out past 120), and its answer kept on the sight row for as long as that
			-- "can't see them" is (SIGHT_CACHE_SECONDS). It used to be cast again for every
			-- cached hidden candidate the loop passed, outside the LOS_CHECKS_PER_THINK budget: in a
			-- crowd (#126) up to 12 rays a think (3 sight, 3 barricade, 6 cached rows), now at most 6.
			-- tools/perf_bot_cost.py counts it (7.5 -> 6.0 a think on average, all hidden).
			local structure
			if computed or entry.cover == nil then
				structure = coverBetween(bot, head, candidate.root)
				entry.cover = structure or false
			else
				structure = entry.cover
			end
			-- A cached barricade that has since been shot down no longer hides anyone.
			if structure and structure.Parent then
				candidate.throughCover = structure
				visible = true
			end
		end
		if visible then
			local seen = bot.seen[candidate.token]
			if not seen or now - seen.last > 1 then
				seen = { since = now, last = now }
				bot.seen[candidate.token] = seen
			end
			seen.last = now
			local delay = 0
			if candidate.token ~= threat then
				local to = flat(candidate.root.Position - root.Position)
				if to.Magnitude > 1 and look:Dot(to.Unit) < FRONT_CONE_COS then
					delay = MatchConfig.BotRearNoticeTime
				end
			end
			if now - seen.since >= delay then
				return candidate
			end
		end
		if fresh >= LOS_CHECKS_PER_THINK then
			break
		end
	end
	return nil
end

-- Where a target was last seen (or where the shots came from), and until when that's worth
-- going to look at: long enough to walk there at bot speed and a few seconds more.
local HUNT_MAX_DISTANCE = 150

local function remember(bot, token, position, root, now)
	local distance = flatDistance(root.Position, position)
	bot.memory = {
		token = token,
		position = position,
		at = now,
		expires = now + MatchConfig.BotMemorySeconds + distance / MatchConfig.BotWalkSpeed,
	}
	bot.searchUntil = nil
end

local function forgetStale(bot, now)
	if now < bot.pruneAt then
		return
	end
	bot.pruneAt = now + 5
	claimPhysics(bot.character)
	for token, entry in pairs(bot.sight) do
		if now - entry.at > 2 then
			bot.sight[token] = nil
		end
	end
	for token, entry in pairs(bot.seen) do
		if now - entry.last > 3 then
			bot.seen[token] = nil
		end
	end
	for item, untilTime in pairs(bot.lootBlacklist) do
		if now > untilTime or not item.Parent then
			bot.lootBlacklist[item] = nil
		end
	end
end

-- Can anything at `from` see this bot? Characters, loot and effects don't count as cover.
-- Water hides nobody: IgnoreWater (set on ExposedParams) defaulted to false, which counted the river
-- as cover: a bot standing in it read as hidden, so it wouldn't put a barricade up or break off
-- while in plain sight. Every other sight line in the project ignores water (CombatService,
-- hasLineOfSight). A ray the frame's budget refuses reads as NOT exposed, so nothing is built on
-- it this think; the next think asks again.
local function exposedTo(bot, root, from)
	local budget = BotService.RaycastBudget
	local params = budget.ExposedParams
	params.FilterDescendantsInstances = budget.Filter(budget.ExposedFilter, bot.character)
	local eye = root.Position + Vector3.new(0, 1.5, 0)
	local hit, granted = castRay(from, eye - from, params, "navigation")
	if not granted then
		return false
	end
	return hit == nil or hit.Instance:FindFirstAncestorOfClass("Model") ~= nil
		and hit.Instance:FindFirstAncestorOfClass("Model"):FindFirstChildOfClass("Humanoid") ~= nil
end
-- tools/bot_probe.lua checks this directly (S20): whether a bot counts as exposed decides if it
-- builds a barricade before healing, and it must not be fooled by water.
BotService.ExposedTo = exposedTo

--------------------------------------------------------------------------------
-- Team modes: what a bot is FOR when there's no storm to run from and nothing to loot
--------------------------------------------------------------------------------

-- What the running mode looks like to a bot, or nil in the battle royale. Read through this one
-- function so a probe can substitute a fake hill and two teams and measure the behaviour without
-- starting a real mode:
--   { team = 1|2, hill = Vector3|nil, occupancy = {n1, n2}|nil, holder = 1|2|nil, arena = Vector3|nil }
function BotService.ModeState(bot)
	local teams = lazy("ModeTeams")
	if not (teams and teams.IsActive and teams.IsActive()) then
		return nil
	end
	local state = { team = teams.TeamOf and teams.TeamOf(bot) or nil }
	if not state.team then
		return nil
	end
	if teams.Arena then
		state.arena = teams.Arena()
	end
	local koth = lazy("ModeKingOfTheHill")
	-- Objective Capture: which objective THIS bot goes for. Every bot used to take Position(team), the
	-- first objective its team didn't own, so the whole team walked to the same one and left the other
	-- to the enemy (Oliver, 16:40: "all the bots only go for one objective"). Now the team splits by
	-- each bot's slot: a third hold what the team owns (the contested one first), the rest spread
	-- across the ones it doesn't. Stable per bot, so nobody flips back and forth between them.
	local hill = nil
	local objectives = koth and koth.Objectives and koth.Objectives() or {}
	if #objectives > 0 then
		local mine, theirs, contested = {}, {}, nil
		for _, objective in ipairs(objectives) do
			if objective.owner == state.team then
				table.insert(mine, objective)
				if objective.status == "Contested" then
					contested = contested or objective
				end
			else
				table.insert(theirs, objective)
			end
		end
		local seat = math.floor(bot.slot or 0)
		if #theirs == 0 or (#mine > 0 and seat % 3 == 0) then
			hill = (contested or mine[seat % #mine + 1]).position
		else
			-- Alternate seats when nobody is holding; skip the holders' seats (multiples of 3) otherwise.
			local pick = #mine == 0 and seat or math.floor(seat / 3) + seat % 3
			hill = theirs[pick % #theirs + 1].position
		end
	elseif koth and koth.Position then
		hill = koth.Position(state.team)
	end
	if hill then
		state.hill = hill
		local counts = koth.Occupancy and koth.Occupancy(hill) or { 0, 0 }
		state.occupancy = counts
		state.holder = koth.Holder and koth.Holder(counts[1] or 0, counts[2] or 0) or nil
	end
	return state
end

-- Where each team last saw an enemy, shared by every bot on it: a squad pushes toward one place
-- instead of each bot toward its own memory. Written in fight(), cleared in Clear().
local teamSightings = {}

local function reportSighting(bot, position, now, token)
	local state = BotService.ModeState(bot)
	if state and state.team then
		teamSightings[state.team] = { position = position, at = now }
		bot.focusTeam = state.team
		if token then
			local focus = teamFocus[state.team]
			-- The first bot on a target names the focus; it is kept while that bot keeps fighting it.
			if not focus or focus.by == bot or now - focus.at >= THREAT_WINDOW then
				teamFocus[state.team] = { token = token, by = bot, at = now }
			end
		end
	end
end

-- Read from Shared/GameModes instead of keeping a second copy of the number: this used to be a
-- hardcoded 28 that happened to agree with GameModes.Modes.KingOfTheHill.hillRadius (also 28)
-- purely by nobody having changed either one yet. ModeKingOfTheHill.Occupancy's own `mode.hillRadius
-- or 28` is a genuine fallback for a mode argument that failed to carry one; this had no such excuse,
-- since KingOfTheHill.hillRadius always exists. A future resize (#121, bigger maps) now reaches the
-- bots' fan-out automatically instead of silently drifting the ring away from the real hill radius.
local HILL_RADIUS = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ObjectiveZone")).Radius(GameModes.Modes.KingOfTheHill) -- one source with the drawn ring, #93
local HILL_SPREAD = 0.55 -- bots stand this share of the hill radius out from its centre, spread round it
local RALLY_RANGE = 80 -- friendlies this close count as the squad
local RALLY_GAP = 40 -- further than this from the squad, go to it before pushing
local SIGHTING_MEMORY = 25

-- Living friendlies near a bot, from the shared per-tick snapshot.
local function squadCentroid(bot, root, team)
	local sum, count = Vector3.zero, 0
	local near, nearCount = combatantsNear(root.Position, RALLY_RANGE)
	for index = 1, nearCount do
		local entry = near[index]
		if entry.token ~= bot and entry.humanoid.Health > 0 and not hostile(bot, entry.token) then
			sum += entry.position
			count += 1
		end
	end
	if count == 0 then
		return nil, 0
	end
	return sum / count, count
end

-- The bot's objective in a team mode: a position and what it is, or nil when the mode gives it none.
-- `slot` spreads bots round a point so a team doesn't stack on one spot.
local function modeObjective(bot, root, state, now)
	local slot = (bot.slot or 0) * 2.399963 -- golden angle, so any number of bots fan out evenly
	if state.hill then
		local ring = Vector3.new(math.cos(slot), 0, math.sin(slot)) * HILL_RADIUS * HILL_SPREAD
		if state.holder == state.team then
			-- BOT ARCHETYPES: Anchors and Survivors sit on a hill the team holds; the rest leave it to
			-- them and go for the enemy the team last saw, so a held hill has guards AND hunters.
			local dials = ARCH.dialsOf(bot)
			local sighting = teamSightings[state.team]
			if not dials.holdObjective and sighting and now - sighting.at < SIGHTING_MEMORY
				and flatDistance(root.Position, sighting.position) > 20 then
				return sighting.position + Vector3.new(math.cos(slot), 0, math.sin(slot)) * 10, "push"
			end
			-- A Marksman holds from the ring's edge, where its range counts; nobody stands past it.
			local spread = math.min(0.9, HILL_SPREAD * math.max(1, dials.rangeScale))
			return state.hill + ring.Unit * HILL_RADIUS * spread, "hold"
		end
		return state.hill + ring, "contest"
	end
	-- Team deathmatch (Oliver #134: bots camped spawn or circled a town). No squad rally any more; it
	-- clumped them. Push the team's last sighting, else hunt the nearest living enemy, so every bot
	-- always has somewhere real to go and the teams meet.
	local sighting = teamSightings[state.team]
	if sighting and now - sighting.at < SIGHTING_MEMORY and flatDistance(root.Position, sighting.position) > 20 then
		local spread = Vector3.new(math.cos(slot), 0, math.sin(slot)) * 10
		return sighting.position + spread, "push"
	end
	local nearest, nearestDistance = nil, math.huge
	for _, entry in ipairs(combatantList) do
		if entry.token ~= bot and entry.humanoid.Health > 0 and hostile(bot, entry.token) then
			local distance = flatDistance(root.Position, entry.position)
			if distance < nearestDistance then
				nearest, nearestDistance = entry, distance
			end
		end
	end
	if nearest then
		local spread = Vector3.new(math.cos(slot), 0, math.sin(slot)) * 8
		return nearest.position + spread, "hunt"
	end
	if state.arena then
		return state.arena + Vector3.new(math.cos(slot), 0, math.sin(slot)) * 60, "sweep"
	end
	return nil
end

--------------------------------------------------------------------------------
-- Movement abilities (the movement tab's server API, used when it exists)
--------------------------------------------------------------------------------

-- Sprinting is only used once stamina exists, so a bot can never sprint forever: before the stamina
-- ledger lands, SetSprinting would give bots a free permanent 1.45x.
local function setSprint(bot, want)
	if not want and not bot.sprinting then
		return
	end
	local match = lazy("MatchService")
	if not (match and match.SetSprinting and match.GetStamina) then
		return
	end
	if want then
		local fraction, exhausted = match.GetStamina(bot)
		if exhausted or (not bot.sprinting and (fraction or 0) < 0.4) then
			want = false
		end
	end
	if bot.sprinting ~= want then
		local accepted = match.SetSprinting(bot, want)
		bot.sprinting = want and accepted ~= false
		if bot.sprinting then
			STATS.sprints += 1
		end
	end
end

-- Crouching, once MatchService has it. Measured by the movement tab: a crouched body is 0.85x the
-- standing hit profile (head and torso still fully hittable, most of the difference is shins hidden
-- by the floor) and aim steadies after 0.2 s of holding still. So a bot crouches when it is staying
-- put in a fight and stands the moment it moves. It does NOT crouch to squeeze through the 4.6-5.3
-- stud gaps that only a crouched body fits: pathfinding plans for a 6-stud agent, so those gaps are
-- never on a bot's route in the first place.
local function setCrouch(bot, want)
	if not want and not bot.crouching then
		return
	end
	local match = lazy("MatchService")
	if not (match and match.SetCrouching) then
		return
	end
	if bot.crouching == want then
		return
	end
	local accepted = match.SetCrouching(bot, want)
	bot.crouching = want and accepted ~= false
	if bot.crouching then
		STATS.crouches += 1
	end
end

-- An occasional slide while running flat out: across open ground, fleeing or rotating.
local function trySlide(bot, humanoid, now)
	local match = lazy("MatchService")
	if not (bot.sprinting and match and match.StartSlide and match.GetStamina) then
		return
	end
	if now < bot.nextSlideAt or humanoid.FloorMaterial == Enum.Material.Air then
		return
	end
	bot.nextSlideAt = now + 4 + math.random() * 5
	local fraction = match.GetStamina(bot)
	if (fraction or 0) >= 0.5 and match.StartSlide(bot) then
		STATS.slides += 1
		-- The burst carries the bot further than its route expects; catch up once it's over.
		bot.nav.recheckRouteAt = now + 0.7
	end
end

-- The stuck ladder's third rung: climb or vault the thing in the way.
BotNav.TryParkour = function(character, forward, groundY)
	if not (MovementService.CanParkour and MovementService.TryParkour) then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local options = { speed = humanoid and humanoid.WalkSpeed or MatchConfig.BotWalkSpeed, groundY = groundY }
	-- The refusal reason is kept for probes: "no climb happened" on its own says nothing about whether
	-- the wall was too high, the ground too far below, or the move simply not found.
	local kind, plan = MovementService.CanParkour(character, forward, options)
	if not kind then
		BotNav.LastParkourReason = tostring(plan)
		-- Per bot too: the shared one is whichever bot asked last, which says nothing when several
		-- are working on different walls at once.
		character:SetAttribute("BotParkourRefusal", tostring(plan))
		return nil
	end
	-- Hand over the plan we were just shown. Without it TryParkour measures again from wherever the
	-- body has moved to in the meantime, which for a walking bot is a few studs on and often past the
	-- lip: 42 attempts completed 0, with no reason recorded, because the refusal happened inside that
	-- second look rather than in the check above.
	options.kind, options.plan = kind, plan
	local done, why = MovementService.TryParkour(character, forward, options)
	if not done then
		BotNav.LastParkourReason = "TryParkour: " .. tostring(why)
		character:SetAttribute("BotParkourRefusal", "TryParkour: " .. tostring(why))
	end
	return done
end

--------------------------------------------------------------------------------
-- Navigation
--------------------------------------------------------------------------------

-- Walk toward `goal` by route when there is one, asking for one when there isn't. Returns "abandon"
-- when the stuck ladder has given up on getting there.
local function navigate(bot, humanoid, root, goal, priority, now)
	local destination = BotNav.Destination(bot)
	if destination and (destination - goal).Magnitude > 10 then
		BotNav.Drop(bot)
	end
	if not BotNav.HasRoute(bot) and not BotNav.IsPending(bot) and not BotNav.RecentlyFailed(bot, goal, 3) then
		BotNav.Request(bot, goal, priority)
	end
	-- Footing checks for a wandering or looting bot are the first rays the frame budget gives up.
	local branch = bot.branch
	BotNav.Follow(bot, humanoid, root, goal, now, (branch == "wander" or branch == "loot") and "idle" or "navigation")
	-- No route and the straight line isn't safe: wait for the route that's coming, or give up on this
	-- goal once a route has already failed.
	if bot.nav.directBlockedAt == now then
		BotNav.Progress(bot, humanoid, root, nil, now)
		if not BotNav.IsPending(bot) and BotNav.RecentlyFailed(bot, goal, 3) then
			return "abandon"
		end
		return nil
	end
	return BotNav.Progress(bot, humanoid, root, bot.nav.moveTarget, now)
end

-- Standing still on purpose: stop, and tell the stuck ladder so.
local function holdStill(bot, humanoid, root, now)
	humanoid:MoveTo(root.Position)
	BotNav.Progress(bot, humanoid, root, nil, now)
end

--------------------------------------------------------------------------------
-- Shooting
--------------------------------------------------------------------------------

local BOT_HEADSHOT_CHANCE = 0.12

-- Launcher rounds ProjectileService.LeadAim can lead (straight-line flight with drop). Anything else a
-- bot would mis-aim, so it doesn't pick those guns up.
local BOT_PROJECTILE_KINDS = { rocket = true, grenade = true }

local function accuracyAt(distance)
	local t = math.clamp(distance / MatchConfig.BotAccuracyFalloff, 0, 1)
	return MatchConfig.BotAccuracyFar
		+ (MatchConfig.BotAccuracyNear - MatchConfig.BotAccuracyFar) * (1 - t)
end

-- Magazines, when MatchConfig.BotReload is on: the gun's own magSize and reloadTime, so a bot that's
-- just emptied a magazine is as open to a push as a player would be.
local function magazineOf(def)
	return MatchConfig.BotReload and def and def.magSize and def.magSize > 0 and def.magSize or nil
end

local function startReload(bot, now)
	local def = bot.weapon
	if not magazineOf(def) or bot.reloadUntil then
		return
	end
	bot.reloadUntil = now + (def.reloadTime or 1.5)
	-- #13: players see a bot's reload on its body (GunPoseClient reads these, as for a player).
	if bot.character then
		bot.character:SetAttribute("Reloading", def.reloadTime or 1.5)
		bot.character:SetAttribute("ReloadEmpty", (bot.mag or 0) <= 0)
	end
	STATS.reloads += 1
end

local function finishReload(bot, now)
	if bot.reloadUntil and now >= bot.reloadUntil then
		bot.reloadUntil = nil
		if bot.character then
			bot.character:SetAttribute("Reloading", nil)
		end
		local size = magazineOf(bot.weapon)
		if size then
			bot.mag = size
		end
	end
end

-- Aim starts settling this long after a target is picked up. It is the old BotReactionTime, pinned
-- here on its own: #75/#81 made bots react faster, and Oliver's ruling is that aim must not move with
-- it (#40). Read off BotReactionTime, the faster reaction would have settled aim earlier in every fight.
-- tools/bot_aggression_check.py fails if the hit chance at any range and moment changes.
local AIM_SETTLE_DELAY = 0.28

local function shootAt(bot, target, targetRoot, distance, head)
	local def = bot.weapon
	-- Empty-handed until it finds something on the map.
	if not def then
		return
	end
	-- Teams can change mid-match (a mode swapping sides, a player joining one): check at the trigger,
	-- not only when the target was chosen.
	if not hostile(bot, target) then
		return
	end
	local now = os.clock()

	if now < bot.nextShotAt then
		return
	end

	-- A launcher's round is real (ProjectileService flies it); never fire one at a target inside its
	-- own blast.
	local projectiles = def.projectile and lazy("ProjectileService") or nil
	if projectiles and not projectiles.FireWeapon then
		projectiles = nil
	end
	local blastRadius = 13
	if projectiles then
		local info = (projectiles.ProjectileInfo and projectiles.ProjectileInfo(def.id))
			or (projectiles.ThrowableInfo and projectiles.ThrowableInfo(def.id)) or nil
		blastRadius = info and info.blastRadius or blastRadius
		if distance < blastRadius + 4 then
			return
		end
	end

	local size = magazineOf(def)
	if size then
		if bot.reloadUntil then
			return
		end
		if bot.magWeapon ~= def.id then
			bot.magWeapon = def.id
			bot.mag = size
		end
		if bot.mag <= 0 then
			startReload(bot, now)
			return
		end
	end

	-- Burst discipline: a handful of shots at the weapon's rate, then a rest. The shape is the gun
	-- class's (BOT ARCHETYPES: a sniper fires one and waits, an LMG six to ten): restScale stretches
	-- the rest so a longer burst is not more rounds a minute. Rounds a minute and the hit chance are
	-- lethality, which stays where Oliver set it; tools/bot_archetype_sim.py checks the throughput
	-- of every class against the stock 2-5 burst.
	local dials = ARCH.dialsOf(bot)
	if bot.burstLeft <= 0 then
		bot.burstLeft = math.random(dials.burst[1], dials.burst[2])
		bot.nextShotAt = now + MatchConfig.BotBurstRest * dials.restScale + math.random() * 0.35
		return
	end

	bot.burstLeft -= 1
	bot.nextShotAt = now + (1 / def.fireRate)
	if size then
		bot.mag -= 1
	end
	-- Shots since the last deliberate reposition, for the class's rule (fight() resets it there).
	bot.shotsFromSpot = (bot.shotsFromSpot or 0) + 1

	if projectiles then
		-- A launcher aims at the feet (aimLow): the round lands and splashes where a torso shot that
		-- misses would sail past. Where it lands, not whether it hits: the accuracy roll is below.
		local aimAt = dials.aimLow and targetRoot.Position - Vector3.new(0, 2.5, 0) or targetRoot.Position
		local aim = projectiles.LeadAim
			and projectiles.LeadAim(def.id, head.Position, aimAt, targetRoot.AssemblyLinearVelocity)
			or aimAt
		-- A miss has to land clear of its own blast, or splash turns every miss into a hit: the round
		-- goes a blast radius and more to one side.
		if math.random() >= accuracyAt(distance) then
			local angle = math.random() * math.pi * 2
			local off = blastRadius + 6 + math.random() * 6
			aim += Vector3.new(math.cos(angle) * off, math.random(-2, 4), math.sin(angle) * off)
			STATS.launcherMisses += 1
		end
		STATS.launcherShots += 1
		projectiles.FireWeapon(bot, def.id, head.Position, aim)
		return
	end

	-- Cover in the way takes the round, and the target behind it takes nothing: same as a player's
	-- shot, which stops at the first thing it meets.
	local structure, hitPoint = coverBetween(bot, head, targetRoot)
	if structure then
		CombatService.BroadcastShot(bot, head.Position, { hitPoint or targetRoot.Position }, def.rarity)
		CombatService.DamageStructure(bot, structure, def.damage * MatchConfig.BotDamageScale)
		STATS.coverShots += 1
		return
	end

	-- Aim settles the longer a bot stays on one target (90% of its accuracy on the first shots, up to
	-- 105% after about 1.5 s), and a target moving fast is harder to hit, so strafing and jumping pay
	-- off for a player (Oliver, 2026-09-22: "aim a little better", "more strategic").
	local chance = accuracyAt(distance)
	local settle = math.clamp((now - (bot.acquiredAt or now) - AIM_SETTLE_DELAY) / 1.5, 0, 1)
	chance *= 0.9 + 0.15 * settle
	local velocity = targetRoot.AssemblyLinearVelocity
	if Vector3.new(velocity.X, 0, velocity.Z).Magnitude > 18 or math.abs(velocity.Y) > 8 then
		chance *= 0.85
	end
	local hit = math.random() < chance
	local endPoint = hit
		and targetRoot.Position
		or targetRoot.Position + Vector3.new(math.random(-12, 12), math.random(-5, 9), math.random(-12, 12))

	-- Hit or miss, the shot was fired along this line: any window it crosses breaks.
	CombatService.BreakGlassAlong(bot, head.Position, endPoint)
	CombatService.BroadcastShot(bot, head.Position, { endPoint }, def.rarity)

	if hit then
		-- One hit in ten lands on the head, with the gun's multiplier (and the match's, in a
		-- Headhunter match), so bot fire has the same spikes a player's does (and you hear it).
		local headshot = math.random() < BOT_HEADSHOT_CHANCE
		local damage = def.damage * MatchConfig.BotDamageScale * (def.pellets or 1)
		if headshot then
			damage *= (def.headshotMultiplier or 1) * CombatService.HeadshotScale
		end
		CombatService.DealDamage(bot, target, damage, def.id, headshot)
	end
end

-- Turning to face a target used to be a direct root.CFrame write. With AutoRotate on, the
-- Humanoid simultaneously turned the root toward its movement direction, so the two fought
-- every tick; the CFrame write also teleported the assembly and killed its momentum. An
-- AlignOrientation turns smoothly through physics instead, and AutoRotate is handed back
-- whenever the bot isn't fighting so it faces where it walks.
local function facePoint(bot, humanoid, root, point)
	humanoid.AutoRotate = false
	if bot.facing then
		bot.facing.CFrame = CFrame.lookAt(root.Position, Vector3.new(point.X, root.Position.Y, point.Z))
		bot.facing.Enabled = true
	end
end

local function faceTarget(bot, humanoid, root, targetRoot)
	facePoint(bot, humanoid, root, targetRoot.Position)
end

local function stopFacing(bot, humanoid)
	if bot.facing and bot.facing.Enabled then
		bot.facing.Enabled = false
	end
	humanoid.AutoRotate = true
end

--------------------------------------------------------------------------------
-- Combat movement
--------------------------------------------------------------------------------

-- A fight is a series of short committed moves rather than a new point every tick: every
-- COMBAT_REPLAN seconds (or sooner, when a move is walking into something) the bot scores a handful
-- of candidates — hold, strafe either way at two lengths, advance or fall back on a diagonal — and
-- takes the best one that BotNav.CanStep says it can actually walk to. The old engage picked one
-- point by formula and walked at it, into walls, off ledges and out into the storm.
local COMBAT_REPLAN = 0.45
local COMBAT_CHECKS = 5

local function planCombatMove(bot, root, threatPosition, distance, retreating, now)
	-- BOT ARCHETYPES: the range is the gun class's, scaled by the personality (ARCH.dialsOf): a
	-- shotgun Rusher wants 7 studs, a sniper Marksman 130. It used to be one number for everyone.
	local dials = ARCH.dialsOf(bot)
	local preferred = dials.range
	-- Closing in on a target that's nearly dead (set in fight()).
	if bot.pushing and not retreating then
		preferred *= 0.5
	end
	-- A launcher wants room between itself and its own blast.
	if bot.weapon and bot.weapon.projectile then
		preferred = math.max(preferred, 30)
	end
	-- Inside the class's dead zone (a sniper at 20 studs, a launcher at 10): open the distance, and
	-- count it as a retreat for the scoring below so every option that gains range wins.
	local opening = not retreating and distance < dials.minRange
	local dangers = dangersNear(root.Position, 40)
	local toThreat = flat(threatPosition - root.Position)
	local forward = toThreat.Magnitude > 0.5 and toThreat.Unit or flatLook(root)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local reloading = bot.reloadUntil ~= nil
	local relocating = bot.relocateUntil ~= nil and now < bot.relocateUntil

	-- The rows are reused across replans (a fighting bot replans every 0.45 s); only the offsets
	-- change. The list is sorted in place, so it is put back in base order first and any flank rows
	-- from the last replan dropped; the hold row is found by its flag, not its index.
	local options = scratch.combatOptions
	for i = #options, 10, -1 do
		options[i] = nil
	end
	for i = 1, 9 do
		options[i] = scratch.baseOptions[i]
	end
	for _, option in ipairs(options) do
		local kind = option.kind
		if kind == 1 then
			option.offset = Vector3.zero
		elseif kind == 2 then
			option.offset = right * 12
		elseif kind == 3 then
			option.offset = -right * 12
		elseif kind == 4 then
			option.offset = right * 22
		elseif kind == 5 then
			option.offset = -right * 22
		elseif kind == 6 then
			option.offset = forward * 18 + right * 8
		elseif kind == 7 then
			option.offset = forward * 18 - right * 8
		elseif kind == 8 then
			option.offset = -forward * 18 + right * 10
		else
			option.offset = -forward * 18 - right * 10
		end
	end
	-- A Flanker works round the target: two points on the arc at its range, 35 degrees round in the
	-- direction it settled on when the fight began (bot.flankDir), so the angle keeps growing instead
	-- of wobbling either side of the line between them.
	-- The flank points are the two pooled rows past the nine base ones, refilled, not rebuilt.
	if dials.flank and not retreating and toThreat.Magnitude > 8 then
		local fromThreat = -forward
		for _, step in ipairs({ math.rad(35), math.rad(60) }) do
			local angle = step * (bot.flankDir or 1)
			local turned = Vector3.new(
				fromThreat.X * math.cos(angle) - fromThreat.Z * math.sin(angle), 0,
				fromThreat.X * math.sin(angle) + fromThreat.Z * math.cos(angle))
			local point = threatPosition + turned * math.max(preferred, 12)
			local row = scratch.flankOptions[#options - 8]
			row.offset, row.side = point - root.Position, bot.flankDir or 1
			options[#options + 1] = row
		end
	end
	-- Team modes: the nearest teammate also on this target. Points that line up behind or in front of
	-- it are worse (one target, one line of fire); points off to a side make a crossfire.
	local friendBearing = nil
	if bot.focusTeam then
		local nearest = 60
		local near, nearCount = combatantsNear(root.Position, nearest)
		for index = 1, nearCount do
			local entry = near[index]
			if entry.token ~= bot and entry.humanoid.Health > 0 and not hostile(bot, entry.token) then
				local gap = flatDistance(entry.position, root.Position)
				if gap < nearest then
					local away = flat(entry.position - threatPosition)
					if away.Magnitude > 1 then
						nearest, friendBearing = gap, away.Unit
					end
				end
			end
		end
	end
	for _, option in ipairs(options) do
		local point = root.Position + option.offset
		local range = flatDistance(point, threatPosition)
		local score
		if retreating or opening then
			score = -range / 25
		else
			score = math.abs(range - preferred) / math.max(preferred, 1) * 3
			if reloading then
				score -= range / 60
			end
		end
		if option.flank then
			score -= 0.8
		end
		if friendBearing and not option.hold then
			local away = flat(point - threatPosition)
			if away.Magnitude > 1 and away.Unit:Dot(friendBearing) > math.cos(math.rad(25)) then
				score += 0.8
			end
		end
		-- Just hit, or too many shots from one spot: anything but here.
		if relocating and option.hold then
			score += 3
		end
		if option.hold then
			-- Standing still is normally the worst option, but a bot already at the range it wants,
			-- with a clear shot, is better off holding and getting low than shuffling sideways. That
			-- is also what makes crouching happen at all.
			local settled = not retreating and math.abs(distance - preferred) < preferred * 0.25
			-- Holding still is only worth it from cover; in the open a bot keeps strafing (Oliver,
			-- 2026-09-22: "jump and strafe more").
			local covered = bot.coverUntil and now < bot.coverUntil
			score += retreating and 3 or ((settled and covered) and -0.6 or (settled and 0.4 or 1.2))
		elseif option.side == bot.strafeDir then
			score -= 0.6
		end
		-- Fighting from its own barricade: stay by it, stepping out either side to shoot.
		if bot.anchor and now < bot.anchor.untilTime and flatDistance(point, bot.anchor.position) > 9 then
			score += 1.2
		end
		-- Standing in, or stepping into, a blast that's about to go off.
		if inDanger(point, dangers) then
			score += 10
		end
		-- Just walked into something going this way.
		local bad = bot.badMove
		if bad and now < bad.untilTime and not option.hold and option.offset.Unit:Dot(bad.direction) > 0.7 then
			score += 5
		end
		option.point = point
		option.score = score + math.random() * 0.25
	end
	table.sort(options, scratch.byScore)

	local params = BotNav.StepParams(bot.character, bot.nav)
	local checked = 0
	for _, option in ipairs(options) do
		if option.hold then
			return root.Position, true
		end
		if stormAllows(root.Position, option.point) then
			checked += 1
			local ok, reason = BotNav.CanStep(root, bot.character, option.point, params, "navigation")
			if ok then
				if option.flank then
					STATS.flankMoves += 1
				end
				return option.point, false
			end
			-- The frame's ray budget is spent: hold this think rather than walk unchecked, and
			-- don't commit to the hold for the whole COMBAT_REPLAN (the caller replans next think).
			if reason == "budget" then
				return root.Position, true, true
			end
			if checked >= COMBAT_CHECKS then
				break
			end
		end
	end
	return root.Position, true
end

-- Keep the current combat move, or pick a new one when it's due, used up, or walking into something.
local function combatMove(bot, root, threatPosition, distance, retreating, now)
	local move = bot.combatMove
	local replan = not move or now >= move.untilTime or move.retreating ~= retreating
	if move and not replan and not move.hold and now - move.startedAt > 0.5
		and flatDistance(root.Position, move.startPosition) < 1 and flatDistance(root.Position, move.point) > 2 then
		local heading = flat(move.point - move.startPosition)
		if heading.Magnitude > 0.1 then
			bot.badMove = { direction = heading.Unit, untilTime = now + 2 }
		end
		STATS.badMoves += 1
		replan = true
	end
	-- Something live landed next to us: move now, not when this move is due.
	if not replan and move.hold and inDanger(root.Position, dangersNear(root.Position, 20)) then
		replan = true
	end
	if replan then
		STATS.combatReplans += 1
		local point, hold, unchecked = planCombatMove(bot, root, threatPosition, distance, retreating, now)
		move = {
			point = point,
			hold = hold,
			retreating = retreating,
			startedAt = now,
			startPosition = root.Position,
			-- A hold forced by the ray budget lasts one think, not a whole replan interval.
			untilTime = unchecked and now or now + COMBAT_REPLAN + math.random() * 0.3,
		}
		bot.combatMove = move
	end
	return move.point
end

-- Somewhere nearby that `threatEye` can't see, rate-limited; remembered for a few seconds so a bot
-- keeps heading for the same spot instead of re-searching on every think.
local COVER_SEARCH_INTERVAL = 1.5

local function seekCover(bot, root, threatEye, now, threatCharacter)
	local cover = bot.coverPoint
	if cover and now < cover.untilTime then
		return cover.position, cover.direct
	end
	bot.coverPoint = nil
	if now - bot.lastCoverSearchAt < COVER_SEARCH_INTERVAL then
		return nil
	end
	bot.lastCoverSearchAt = now
	STATS.coverSearches += 1
	local from = root.Position
	if now < (bot.coverBlockedUntil or 0) then
		return nil
	end
	local point, direct, refused = BotNav.FindCover(root, bot.character, threatEye, scratch.coverRadii, function(candidate)
		return stormAllows(from, candidate)
	end, threatCharacter, "navigation")
	if refused == "budget" then
		-- The frame's rays are spent: this search didn't happen, so it isn't rate-limited away.
		bot.lastCoverSearchAt = now - COVER_SEARCH_INTERVAL
		return nil
	end
	if point then
		STATS.coverFound += 1
		if not direct then
			STATS.coverRouted += 1
		end
		bot.coverPoint = { position = point, direct = direct, untilTime = now + (direct and 4 or 6) }
	end
	return point, direct
end

-- Head for a cover spot: straight there when that's a clear walk, by route when it's round the back
-- of whatever hides it.
local function goToCover(bot, humanoid, root, cover, direct, now)
	if direct then
		humanoid:MoveTo(cover)
		return true
	end
	local result = navigate(bot, humanoid, root, cover, BotNav.Priority.Urgent, now)
	-- No route and the straight line is blocked: standing still waiting for one is the worst thing to
	-- do under fire, so drop this spot and don't look again for a moment.
	if result == "abandon" or (not BotNav.HasRoute(bot) and not BotNav.IsPending(bot)
		and BotNav.RecentlyFailed(bot, cover, 3)) then
		STATS.coverUnreachable += 1
		bot.coverPoint = nil
		bot.coverBlockedUntil = now + 5
		return false
	end
	return true
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

-- How far a hurt bot with no heal items will detour for a loose Bandage or Med Kit.
local HEAL_SEEK_RANGE = 140

-- Bots carry the same Bandages and Med Kits players do, capped the same way.
local function giveBotHeal(bot, healId, amount)
	local heal = WeaponService.Heals[healId]
	if heal then
		bot.heals[healId] = math.min(heal.max, (bot.heals[healId] or 0) + amount)
	end
end

-- Shield potions too. A bot's shield lives on its humanoid as the "Shield" attribute, which is
-- where CombatService takes damage from first — the same place a player's loadout shield goes.
local BOT_SHIELD_LOW = 50

local function giveBotShield(bot, itemId, amount)
	local shield = WeaponService.Shields[itemId]
	if shield then
		bot.shields[itemId] = math.min(shield.max, (bot.shields[itemId] or 0) + amount)
	end
end

-- Same lull and cooldown as heals: a shield is topped up after breaking contact, never mid-duel.
local function tryShield(bot, humanoid, now)
	local current = humanoid:GetAttribute("Shield") or 0
	if current >= BOT_SHIELD_LOW then
		return
	end
	if now - bot.lastCombatAt < MatchConfig.BotHealLull or now - bot.lastHealAt < MatchConfig.BotHealCooldown then
		return
	end

	-- A full potion on a nearly-full shield is a waste; save it for when a mini wouldn't do.
	local itemId
	if bot.shields.ShieldPotion > 0 and (current <= 25 or bot.shields.MiniShield <= 0) then
		itemId = "ShieldPotion"
	elseif bot.shields.MiniShield > 0 then
		itemId = "MiniShield"
	end
	local shield = itemId and WeaponService.Shields[itemId]
	if not shield or current >= shield.cap then
		return
	end

	bot.shields[itemId] -= 1
	bot.lastHealAt = now
	humanoid:SetAttribute("Shield", math.min(shield.cap, current + shield.amount))
end

-- Rot Barricades too, from chests (the same one-in-five as a player's chest) and supply drops.
-- A bot puts one up for three reasons, each counted in Stats:
--   exposed — getting shot up with no cover within reach: throw it between us and them and duck;
--   angle   — a long-range duel from open ground while healthy: build it and fight from beside it;
--   heal    — about to patch up out in the open with a recent shooter somewhere out there.
local BOT_CHEST_DEFENSE_CHANCE = 0.2
local BOT_MAX_DEFENSES = 3
local BOT_BUILD_COOLDOWN = 25
local BOT_BUILD_HEALTH = 0.6 -- fraction of max health; under fire below this, it builds
local BOT_BUILD_MIN, BOT_BUILD_MAX = 10, 90 -- distance to the shooter
local BOT_COVER_TIME = 4
local BOT_ANGLE_TIME = 20
local BOT_ANGLE_CHECK = 3
local BOT_ANGLE_CHANCE = 0.3

local function giveBotDefense(bot, amount)
	bot.defenses = math.min(BOT_MAX_DEFENSES, bot.defenses + amount)
end

-- Rot Rockets, from supply drops and some chests. A bot losing a close fight fires one to get
-- clear — up and away, a little off the straight line back so it's not an easy shot to follow —
-- and patches up wherever it lands, the way a player would.
local BOT_ROCKET_MAX = 2
local BOT_ROCKET_COOLDOWN = 18
local BOT_ROCKET_RANGE = 55 -- only when the shooter's close enough that walking away won't do
local BOT_CHEST_ROCKET_CHANCE = 0.25

local itemUsed = Remotes.Event("ItemUsed")

local function giveBotRocket(bot, amount)
	bot.rockets = math.min(BOT_ROCKET_MAX, bot.rockets + amount)
end

local function tryRocket(bot, humanoid, root, targetRoot, distance, now)
	if bot.rockets <= 0 or distance > BOT_ROCKET_RANGE or now - bot.lastRocketAt < BOT_ROCKET_COOLDOWN then
		return false
	end
	if humanoid.FloorMaterial == Enum.Material.Air then
		return false
	end
	local away = root.Position - targetRoot.Position
	local flatAway = Vector3.new(away.X, 0, away.Z)
	if flatAway.Magnitude < 1 then
		return false
	end
	local direction = CFrame.Angles(0, (math.random() - 0.5) * math.rad(70), 0) * flatAway.Unit

	bot.rockets -= 1
	bot.lastRocketAt = now
	BotNav.Drop(bot)
	bot.lootTarget = nil
	bot.coverUntil = 0
	bot.combatMove = nil
	-- Out of the fight: heal on landing rather than after the usual lull.
	bot.lastCombatAt = now - MatchConfig.BotHealLull
	itemUsed:FireAllClients(bot.character, "RotRocket")
	MovementService.Launch(bot.character, MovementService.RocketVelocity(direction))
	return true
end

-- A barricade can't go up across a doorway or an alley the bot (or anyone) needs to get through:
-- with something solid close on both sides of the site, it's a gap, not open ground.
local function narrowSite(bot, centre, facing)
	local params = BotNav.StepParams(bot.character, bot.nav)
	local across = Vector3.new(-facing.Z, 0, facing.X)
	-- Refused by the ray budget: counted as narrow, so the build waits for a think that can look.
	local left, granted = castRay(centre, across * 7, params, "navigation")
	if not granted then
		return true
	end
	local right, grantedRight = castRay(centre, -across * 7, params, "navigation")
	return not grantedRight or (left ~= nil and right ~= nil)
end

local function placeBarricade(bot, root, toward, now, reason)
	local offset = flat(toward - root.Position)
	if offset.Magnitude < 1 then
		return false
	end
	local facing = offset.Unit
	local centre = root.Position + facing * 5
	-- Not on its own way out, either.
	local nav = bot.nav
	if nav and nav.waypoints then
		for index = nav.index, math.min(#nav.waypoints, nav.index + 3) do
			if flatDistance(nav.waypoints[index].Position, centre) < 5 then
				return false
			end
		end
	end
	if narrowSite(bot, centre, facing) then
		STATS.buildsRefused += 1
		bot.lastBuildAt = now - BOT_BUILD_COOLDOWN + 3
		return false
	end
	-- Never across a teammate's path: a friendly within a couple of body widths of the site would be
	-- walled in or walled off (Oliver: "never block teammates' paths").
	for _, entry in ipairs(combatantList) do
		if entry.token ~= bot and entry.humanoid.Health > 0 and not hostile(bot, entry.token)
			and flatDistance(entry.position, centre) < 9 then
			STATS.buildsRefusedFriendly += 1
			return false
		end
	end
	-- A site that won't take it (a wall, a slope, someone in the way) is retried in a few seconds
	-- rather than every tick.
	local model = DefenseService.Deploy(bot, bot.character, "RotBarricade", centre, facing)
	if not model then
		STATS.buildsRefused += 1
		bot.lastBuildAt = now - BOT_BUILD_COOLDOWN + 3
		return false
	end
	bot.defenses -= 1
	bot.lastBuildAt = now
	bot.ownStructures[model] = true
	if reason == "angle" or reason == "fortify" then
		if reason == "angle" then
			STATS.buildsAngle += 1
		else
			STATS.buildsFortify += 1
		end
		bot.anchor = { position = root.Position, untilTime = now + BOT_ANGLE_TIME }
	else
		if reason == "heal" then
			STATS.buildsHeal += 1
		elseif reason == "block" then
			STATS.buildsBlock += 1
		elseif reason == "cross" then
			STATS.buildsCross += 1
		elseif reason == "pushed" then
			STATS.buildsPushed += 1
		else
			STATS.buildsExposed += 1
		end
		bot.coverUntil = now + BOT_COVER_TIME
		bot.coverAt = root.Position
		bot.peek = nil
		-- Out of sight now: patch up straight away rather than after the usual lull.
		bot.lastCombatAt = now - MatchConfig.BotHealLull
	end
	return true
end

-- BOT ARCHETYPES: buildRate is the share of fights in which this bot builds at all (rolled once per
-- target, bot.buildRoll, so it is a decision rather than a coin flipped every think); a fortifier
-- (Anchor, Marksman) rebuilds sooner after its wall comes down.
local function canBuild(bot, now)
	if bot.defenses <= 0 then
		return false
	end
	local dials = ARCH.dialsOf(bot)
	if (bot.buildRoll or 0) > dials.buildRate then
		return false
	end
	return now - bot.lastBuildAt >= BOT_BUILD_COOLDOWN * (dials.buildFortify and 0.6 or 1)
end

-- A quick wall when a target is coming at a bot that fights from range (a sniper or DMR pushed by
-- a shotgun): built in the target's path while it is still 15-40 studs out, then the bot fights from
-- beside it rather than being caught reloading in the open.
function ARCH.tryBuildPushed(bot, humanoid, root, targetRoot, distance, now)
	local dials = ARCH.dialsOf(bot)
	if dials.peekStyle ~= "hold" or not canBuild(bot, now) then
		return false
	end
	if distance < 15 or distance > 40 then
		return false
	end
	local closing = flat(targetRoot.AssemblyLinearVelocity):Dot(flat(root.Position - targetRoot.Position).Unit)
	if closing < 8 then
		return false
	end
	return placeBarricade(bot, root, targetRoot.Position, now, "pushed")
end

-- A Flanker crossing open ground toward its target with nothing to hide behind: a wall mid-field to
-- work from, only once it is being hit out there.
function ARCH.tryBuildCross(bot, humanoid, root, targetRoot, distance, now)
	local dials = ARCH.dialsOf(bot)
	if not dials.buildToCross or not canBuild(bot, now) or now - bot.lastHurtAt > 1 then
		return false
	end
	if distance < 30 or distance > BOT_BUILD_MAX or now >= (bot.coverBlockedUntil or 0) then
		return false
	end
	return placeBarricade(bot, root, targetRoot.Position, now, "cross")
end

-- Anchors on a hill (or Marksmen at a firing position): a wall toward where the enemy was last seen,
-- before anyone is shooting yet, when the bot is exposed from there. The cooldown and the
-- 3-structure cap keep it to a couple of walls, rebuilt when they come down.
function ARCH.tryBuildFortify(bot, humanoid, root, toward, now)
	local dials = ARCH.dialsOf(bot)
	if not dials.buildFortify or not canBuild(bot, now) then
		return false
	end
	local distance = flatDistance(root.Position, toward)
	if distance < BOT_BUILD_MIN or distance > 200 then
		return false
	end
	if not exposedTo(bot, root, toward + Vector3.new(0, 1.5, 0)) then
		return false
	end
	return placeBarricade(bot, root, toward, now, "fortify")
end

-- Getting shot up, hurt, with nowhere to hide.
local function tryBuildExposed(bot, humanoid, root, targetRoot, distance, now)
	if not canBuild(bot, now) or distance < BOT_BUILD_MIN or distance > BOT_BUILD_MAX then
		return false
	end
	if humanoid.Health > humanoid.MaxHealth * BOT_BUILD_HEALTH or now - bot.lastHurtAt > 2 then
		return false
	end
	return placeBarricade(bot, root, targetRoot.Position, now, "exposed")
end

-- Settling into a long-range duel from open ground: put a wall up and fight from beside it. Kept
-- to healthy bots facing a target that isn't rushing them, and rolled now and then rather than every
-- time so bots don't all do it.
local function tryBuildAngle(bot, humanoid, root, targetRoot, distance, now)
	if bot.defenses < 1 or not canBuild(bot, now) or now < bot.angleCheckAt then
		return false
	end
	bot.angleCheckAt = now + BOT_ANGLE_CHECK
	local preferred = ARCH.dialsOf(bot).range
	if distance < math.max(BOT_BUILD_MIN, preferred * 1.1) or distance > BOT_BUILD_MAX then
		return false
	end
	if humanoid.Health < humanoid.MaxHealth * 0.7 then
		return false
	end
	local closing = flat(targetRoot.AssemblyLinearVelocity):Dot(flat(root.Position - targetRoot.Position).Unit)
	-- An LMG (suppress) or a fortifier settles in far more readily than the stock roll.
	local dials = ARCH.dialsOf(bot)
	local chance = (dials.peekStyle == "suppress" or dials.buildFortify) and 0.6 or BOT_ANGLE_CHANCE
	if closing > 6 or math.random() > chance then
		return false
	end
	return placeBarricade(bot, root, targetRoot.Position, now, "angle")
end

-- About to heal in the open with a shooter from the last few seconds somewhere out there.
local function tryBuildBeforeHeal(bot, humanoid, root, now)
	if not canBuild(bot, now) or humanoid.Health > humanoid.MaxHealth * MatchConfig.BotHealBelow then
		return false
	end
	if bot.heals.Bandage + bot.heals.MedKit <= 0 then
		return false
	end
	local memory = bot.memory
	if not memory or now - memory.at > 10 then
		return false
	end
	local distance = flatDistance(root.Position, memory.position)
	if distance < BOT_BUILD_MIN or distance > 160 then
		return false
	end
	if not exposedTo(bot, root, memory.position + Vector3.new(0, 1.5, 0)) then
		return false
	end
	return placeBarricade(bot, root, memory.position, now, "heal")
end

-- What a heal can lift you to, the same way WeaponService figures it for a player: the item's cap is
-- authored against 100 health and scales with max health, so extra-health gamepasses don't turn a
-- Bandage into a full heal.
local function healCap(humanoid, heal)
	return math.min(humanoid.MaxHealth, heal.cap * humanoid.MaxHealth / 100)
end

local function tryHeal(bot, humanoid, now)
	local missing = humanoid.MaxHealth - humanoid.Health
	-- BOT ARCHETYPES: a Survivor patches up at 75%, a Rusher waits until 45%; MatchConfig is the default.
	local healBelow = ARCH.dialsOf(bot).healBelow or MatchConfig.BotHealBelow
	if missing <= 0 or humanoid.Health > humanoid.MaxHealth * healBelow then
		return
	end
	if now - bot.lastCombatAt < MatchConfig.BotHealLull or now - bot.lastHealAt < MatchConfig.BotHealCooldown then
		return
	end

	-- A Med Kit on a scratch is a waste; save it for when a Bandage wouldn't cover the gap. A heal
	-- that can't lift this bot any further (a Bandage at its 75 cap) isn't worth spending either.
	local bandage = bot.heals.Bandage > 0 and humanoid.Health < healCap(humanoid, WeaponService.Heals.Bandage)
	local healId
	if bot.heals.MedKit > 0 and (missing >= 60 or not bandage) then
		healId = "MedKit"
	elseif bandage then
		healId = "Bandage"
	end
	local heal = healId and WeaponService.Heals[healId]
	if not heal then
		return
	end
	-- The same ceiling a player is held to: a heal's cap is authored against 100 health and scales
	-- with max health (WeaponService.healCap). Clamping only to MaxHealth let a bot take a Bandage
	-- from 60 to 90 where a player stops at 75.
	local cap = healCap(humanoid, heal)
	if humanoid.Health >= cap then
		return
	end

	bot.heals[healId] -= 1
	bot.lastHealAt = now
	humanoid.Health = math.min(cap, humanoid.Health + heal.amount)
end

-- Frags and smoke come from the Explosives tab's ProjectileService:
--   Throw(botToken, itemId, targetPosition, { cook }) -> ok, which spends nothing (the stock is ours);
--   ProjectileInfo(itemId or launcher weaponId) -> { kind, fuse, blastRadius, throwRange, ... };
--   Dangers(position, radius) -> live frags and rounds nearby, with their owner.
-- Until that module exists bots are never given any, so all of this stays idle. Stock is kept by
-- item id in `bot.throwables`, so a death drop can read it the way it reads heals.
local THROWABLES = {
	grenade = { itemId = "CookedCoconut", cooldown = 8, minRange = 14, maxRange = 70, blast = 13, chestWeight = 14 },
	smoke = { itemId = "LowkeyLatte", cooldown = 15, minRange = 0, maxRange = 40, blast = 0, chestWeight = 10 },
	-- The Clingy Crumpet: thrown at a vehicle the target is in, or the barricade it is behind (fight()).
	-- Bots only hold them from a mode's SpawnLoadout kit for now; a chest's roll is grenade or smoke.
	sticky = { itemId = "ClingyCrumpet", cooldown = 12, minRange = 8, maxRange = 45, blast = 12, chestWeight = 0 },
}
-- What a player's chest gives: a 30% chance of one throwable, a pickup of two.
local CHEST_THROWABLE_CHANCE = 0.3
local CHEST_THROWABLE_AMOUNT = 2

local function projectileApi()
	local projectiles = lazy("ProjectileService")
	return projectiles and type(projectiles.Throw) == "function" and projectiles or nil
end

local function giveBotThrowable(bot, kind, amount)
	local spec = THROWABLES[kind]
	if spec and projectileApi() then
		bot.throwables[spec.itemId] = math.min(2, (bot.throwables[spec.itemId] or 0) + amount)
	end
end

-- A lob needs headroom: a clear line up from the hand, and across above the landing point.
local function lobClear(bot, head, point)
	-- Fresh params, not the cached step params: a throw arcs over water perfectly well; only solid
	-- things stop it, and IgnoreWater must not leak into the step checks. A ray the budget refuses
	-- reads as blocked; the throw is tried again next think.
	local params = BotNav.StepParams(bot.character)
	params.IgnoreWater = true
	local apex = head.Position + Vector3.new(0, 10, 0)
	local hit, granted = castRay(head.Position, apex - head.Position, params, "navigation")
	if hit or not granted then
		return false
	end
	local above = point + Vector3.new(0, 10, 0)
	hit, granted = castRay(apex, above - apex, params, "navigation")
	return hit == nil and granted
end

local function tryThrow(bot, root, head, kind, point, now)
	local spec = THROWABLES[kind]
	local api = projectileApi()
	if not (api and spec) or (bot.throwables[spec.itemId] or 0) <= 0 then
		return false
	end
	if now < (bot.throwReadyAt[kind] or 0) then
		return false
	end
	local lookup = api.ProjectileInfo or api.ThrowableInfo
	local info = lookup and lookup(spec.itemId) or nil
	local distance = flatDistance(root.Position, point)
	local maxRange = math.min(spec.maxRange, info and info.throwRange or spec.maxRange)
	if distance < spec.minRange or distance > maxRange then
		return false
	end
	-- Never inside its own blast, and never a second frag onto one of its own still ticking there.
	local blast = info and info.blastRadius or spec.blast
	if blast > 0 then
		if distance < blast + 4 then
			return false
		end
		for _, danger in ipairs(dangersNear(point, blast)) do
			if danger.owner == bot then
				return false
			end
		end
		-- Nor onto a teammate (Oliver: "never throw frags at teammates' positions").
		for _, entry in ipairs(combatantList) do
			if entry.token ~= bot and entry.humanoid.Health > 0 and not hostile(bot, entry.token)
				and (entry.position - point).Magnitude < blast + 3 then
				STATS.throwsRefusedFriendly += 1
				return false
			end
		end
	end
	if kind == "grenade" and not lobClear(bot, head, point) then
		return false
	end
	bot.throwReadyAt[kind] = now + spec.cooldown
	-- A little cook on a frag, never much: flight time is estimated the way DefenseService.throwKit
	-- times a lob, and at most 40% of what's left is burned, so there's still a moment to run.
	-- BOT ARCHETYPES: only the archetypes rated for it cook at all (cookFrags); the rest lob it as
	-- it comes and give the target the full fuse to run.
	local options = nil
	if kind == "grenade" and info and info.fuse and ARCH.dialsOf(bot).cookFrags then
		local flight = math.clamp(distance / 40, 0.5, 1.6)
		options = { cook = math.max(0, info.fuse - flight - 0.3) * 0.4 * math.random() }
	end
	local ok = api.Throw(bot, spec.itemId, point, options)
	if ok then
		bot.throwables[spec.itemId] -= 1
		if kind == "grenade" then
			STATS.throwsGrenade += 1
		elseif kind == "sticky" then
			STATS.throwsSticky += 1
		else
			STATS.throwsSmoke += 1
		end
	end
	return ok == true
end

-- A grenade is worth it at two or more enemies bunched together round the target.
local function clusterAround(bot, targetRoot)
	local count, sum = 0, Vector3.zero
	local near, nearCount = combatantsNear(targetRoot.Position, 10)
	for index = 1, nearCount do
		local entry = near[index]
		-- Enemies only: a team-mate in melee with the target isn't a reason to throw.
		if entry.token ~= bot and entry.humanoid.Health > 0 and hostile(bot, entry.token) then
			count += 1
			sum += entry.position
		end
	end
	return count, count > 0 and sum / count or nil
end

--------------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------------

-- Which bot is heading for which pickup. A bot skips a pickup another living bot is already closer
-- to, so a chest in a town square pulls one bot, not the six nearest.
local lootClaims = {}

local function releaseLoot(bot)
	local item = bot.lootTarget
	if item and lootClaims[item] == bot then
		lootClaims[item] = nil
	end
	bot.lootTarget = nil
	bot.lootHoldStart = nil
	bot.lootFailures = 0
end

local function setLootTarget(bot, item)
	if bot.lootTarget == item then
		return
	end
	releaseLoot(bot)
	bot.lootTarget = item
	lootClaims[item] = bot
	-- Drop the old route first, or the bot keeps following its previous wander path until the
	-- new one comes back.
	BotNav.Drop(bot)
end

local function blacklistLoot(bot, item, seconds, now)
	if item then
		bot.lootBlacklist[item] = now + seconds
		STATS.lootBlacklisted += 1
	end
	releaseLoot(bot)
end

local function lootAllowed(bot, item, distance, center, radius, now)
	-- Tagged by the map as somewhere a bot can't get to (a chest on a summit steeper than the agent's
	-- slope). The blacklist below still catches anything nobody tagged, but this costs nothing and
	-- stops the walk before it starts.
	if item:GetAttribute("BotIgnore") == true then
		STATS.lootIgnored += 1
		return false
	end
	local banned = bot.lootBlacklist[item]
	if banned and now < banned then
		return false
	end
	local holder = lootClaims[item]
	if holder and holder ~= bot and holder.lootTarget == item and holder.humanoid.Health > 0 and holder.character.Parent then
		local holderRoot = holder.character:FindFirstChild("HumanoidRootPart")
		if holderRoot and (holderRoot.Position - item.Position).Magnitude <= distance then
			return false
		end
	end
	return insideCircle(item.Position, center, radius, 0.9)
end

-- The same pickups LootService.FindNearest / FindNearestHeal consider (unclaimed GroundWeapons and
-- Chests, or HealPickups with a HealId, in workspace.Loot), with this bot's filters on top: its
-- blacklist, other bots' claims, and, when the storm is pressing, the circle it's heading for.
--
-- Pickups don't move, so the folder is read once a second into a shared list (item, position, kind)
-- rather than walked by every bot that looks.
--
-- The snapshot is also binned into a SpatialQuery grid (64-stud cells), so a bot looking 200 studs
-- around itself reads the cells that cover that circle rather than every pickup on a 1280-stud map.
-- BotService.SpatialQuery.Loot(position, radius, kind, now) is the way in for any section: rows are
-- { item, position, kind } ("gear" or "heal"), in a shared scratch list, valid until the next call.
local LOOT_SNAPSHOT_SECONDS = 1
local lootSnapshot = { at = -math.huge, items = {}, grid = BotService.SpatialQuery.NewGrid(64) }

local function lootItems(now)
	if now - lootSnapshot.at < LOOT_SNAPSHOT_SECONDS then
		return lootSnapshot.items
	end
	local items = {}
	local folder = workspace:FindFirstChild("Loot")
	if folder then
		for _, item in ipairs(folder:GetChildren()) do
			if item:IsA("BasePart") then
				local name = item.Name
				local kind = (name == "GroundWeapon" or name == "Chest") and "gear" or (name == "HealPickup" and "heal") or nil
				if kind then
					table.insert(items, { item = item, position = item.Position, kind = kind })
				end
			end
		end
	end
	lootSnapshot.at = now
	lootSnapshot.items = items
	lootSnapshot.grid.Rebuild(items)
	return items
end

function BotService.SpatialQuery.Loot(position, radius, kind, now)
	lootItems(now or os.clock())
	if radius == math.huge then
		-- No circle to read: the whole snapshot, filtered.
		local list, n = lootSnapshot.grid.scratch, 0
		table.clear(list)
		for _, entry in ipairs(lootSnapshot.items) do
			if kind == nil or entry.kind == kind then
				n += 1
				list[n] = entry
			end
		end
		return list, n
	end
	return lootSnapshot.grid.Near(position, radius, kind and function(entry)
		return entry.kind == kind
	end or nil)
end

local function findLoot(bot, position, radius, heals, center, circleRadius, now)
	local best, bestDistance = nil, radius
	local near, nearCount = BotService.SpatialQuery.Loot(position, radius, heals and "heal" or "gear", now)
	for index = 1, nearCount do
		local entry = near[index]
		local distance = (entry.position - position).Magnitude
		if distance < bestDistance then
			local item = entry.item
			if item.Parent and not item:GetAttribute("Claimed") and (not heals or item:GetAttribute("HealId") ~= nil)
				and lootAllowed(bot, item, distance, center, circleRadius, now) then
				best, bestDistance = item, distance
			end
		end
	end
	return best
end

-- Team modes: the loot stocked round the bot's own base (Oliver, 2026-09-23: "make the bots go for
-- it"). A bot at or near home takes any gun that beats the one it carries, any chest, and loose heals
-- while it is carrying fewer than three. Returns the nearest such pickup, or nil. A field rather than
-- a local, for the file's local budget.
function BotService.FindBaseLoot(bot, root, modeState, center, circleRadius, now, chestsFirst)
	local teams = lazy("ModeTeams")
	local base = teams and teams.BaseOf and teams.BaseOf(modeState.team)
	if not base then
		return nil
	end
	local baseRadius = (LootService.BaseRadius or 85) + 10
	local flatBase = Vector3.new(base.X, 0, base.Z)
	local here = root.Position
	if (Vector3.new(here.X, 0, here.Z) - flatBase).Magnitude > baseRadius + 70 then
		return nil
	end
	local myRank = bot.weapon and (Rarity.Index[bot.weapon.rarity] or 0) or -1
	local wantHeals = (bot.heals.Bandage + bot.heals.MedKit) < 3
	-- While gearing up after a spawn, an unopened chest at the base beats everything else (Oliver,
	-- 2026-09-23 14:38: "make the bots go after the chests when they spawn").
	if chestsFirst then
		local chest, chestDistance = nil, 220
		for _, entry in ipairs(lootItems(now)) do
			local item = entry.item
			local position = entry.position
			if item.Name == "Chest" and item.Parent and not item:GetAttribute("Claimed")
				and (Vector3.new(position.X, 0, position.Z) - flatBase).Magnitude <= baseRadius then
				local distance = (position - here).Magnitude
				if distance < chestDistance and lootAllowed(bot, item, distance, center, circleRadius, now) then
					chest, chestDistance = item, distance
				end
			end
		end
		if chest then
			return chest
		end
	end
	local best, bestDistance = nil, 160
	for _, entry in ipairs(lootItems(now)) do
		local item = entry.item
		local position = entry.position
		if (Vector3.new(position.X, 0, position.Z) - flatBase).Magnitude <= baseRadius then
			local distance = (position - here).Magnitude
			if distance < bestDistance and item.Parent and not item:GetAttribute("Claimed") then
				local wanted = false
				if entry.kind == "heal" then
					wanted = wantHeals and item:GetAttribute("HealId") ~= nil
				elseif item.Name == "Chest" then
					wanted = true
				else
					local id = item:GetAttribute("WeaponId")
					local def = id and WeaponData.Get(id)
					wanted = def ~= nil and (Rarity.Index[def.rarity] or 0) > myRank
						and not def.staged and not BOT_WEAPON_HOLD[def.id]
						and (not def.projectile or BOT_PROJECTILE_KINDS[def.projectile]) and true or false
				end
				if wanted and lootAllowed(bot, item, distance, center, circleRadius, now) then
					best, bestDistance = item, distance
				end
			end
		end
	end
	return best
end

-- Stand at the pickup for as long as a player would have to hold the prompt, then take it.
-- Returns true while holding.
local function holdLoot(bot, humanoid, root, now)
	local item = bot.lootTarget
	-- Give way to a player already holding the prompt.
	if item:GetAttribute("PlayerHolding") then
		releaseLoot(bot)
		BotNav.Drop(bot)
		return false
	end
	if not bot.lootHoldStart then
		bot.lootHoldStart = now
	end
	holdStill(bot, humanoid, root, now)
	if now - bot.lootHoldStart < LootService.ClaimTime(item) then
		return true
	end

	local targetName = item.Name
	local fromCrate = targetName == "SupplyCrate"
	local fromChest = targetName == "Chest"

	local def
	if targetName == "HealPickup" then
		local healId, amount = LootService.ClaimHealForBot(item)
		if healId then
			giveBotHeal(bot, healId, amount)
		end
	else
		local claim = fromCrate and SupplyDropService.ClaimForBot or LootService.ClaimForBot
		def = claim(item)
	end
	releaseLoot(bot)
	BotNav.Drop(bot)

	-- Same heal grants a player gets from the same source (LootService chest trigger,
	-- SupplyDropService prompt). A nil def means the claim was refused.
	if def and fromCrate then
		giveBotHeal(bot, "MedKit", 1)
		giveBotShield(bot, "ShieldPotion", 1)
		giveBotDefense(bot, 1)
		giveBotRocket(bot, 1)
	elseif def and fromChest then
		giveBotHeal(bot, "Bandage", math.random(1, 3))
		if math.random() < 0.4 then
			giveBotHeal(bot, "MedKit", 1)
		end
		if math.random() < BOT_CHEST_DEFENSE_CHANCE then
			giveBotDefense(bot, 1)
		end
		if math.random() < BOT_CHEST_ROCKET_CHANCE then
			giveBotRocket(bot, 1)
		end
		if math.random() < CHEST_THROWABLE_CHANCE then
			local total = THROWABLES.grenade.chestWeight + THROWABLES.smoke.chestWeight
			local kind = math.random() * total < THROWABLES.grenade.chestWeight and "grenade" or "smoke"
			giveBotThrowable(bot, kind, CHEST_THROWABLE_AMOUNT)
		end
		-- Roughly what a player's chest recovery rolls come to.
		local roll = math.random()
		if roll < 0.4 then
			giveBotShield(bot, "MiniShield", 2)
		elseif roll < 0.6 then
			giveBotShield(bot, "ShieldPotion", 1)
		end
	end

	-- Anything beats nothing; after that, only ever swap up. A bot trading a sniper for a pistol
	-- would look broken. A projectile gun whose round flies some way the bot's aim can't lead (a disc
	-- that ricochets, a homing slipper, a lobbed toast) is left for players.
	local usable = def and not def.staged and not BOT_WEAPON_HOLD[def.id]
		and (not def.projectile or BOT_PROJECTILE_KINDS[def.projectile])
	if usable and (not bot.weapon or (Rarity.Index[def.rarity] or 0) > (Rarity.Index[bot.weapon.rarity] or 0)) then
		bot.weapon = def
		bot.magWeapon = def.id
		bot.mag = magazineOf(def)
		bot.reloadUntil = nil
		if bot.character then
			bot.character:SetAttribute("Reloading", nil)
		end
		giveBotGun(bot.character, def)
		claimPhysics(bot.character)
	end
	return true
end

--------------------------------------------------------------------------------
-- Behaviour
--------------------------------------------------------------------------------

-- Closer than this, a bot would rather keep its speed than its smaller profile.
local CROUCH_MIN_RANGE = 25

-- BOT ARCHETYPES: the peek cycle. From cover a peeking bot (peek, or a "hold" gun class) alternates a
-- hidden spell with an exposed one instead of standing in the gap. Shared by fight(), where the
-- target is in view, and by updateBot's hold-in-cover, where it isn't (a bot that has reached cover
-- has usually broken line of sight, so without this it would sit behind the wall until the cover
-- time ran out and never fire from it). Returns the phase row; `exposed` is what to do this think.
-- On ARCH rather than a local, like the build rules below it: this chunk is near Luau's 200-local limit.
function ARCH.peekPhase(bot, now)
	local peek = bot.peek
	if not peek or now >= peek.untilTime then
		local exposed = not (peek and peek.exposed)
		peek = {
			exposed = exposed,
			untilTime = now + (exposed and 0.9 + math.random() * 0.6 or 1.2 + math.random() * 1),
			side = peek and peek.side or (math.random() < 0.5 and 1 or -1),
		}
		bot.peek = peek
		if exposed then
			STATS.peeks += 1
		end
	end
	return peek
end

-- Seen and noticed, gun in range: fight. Returns having issued this think's movement.
-- Reaction time is a time, not a count of thinks (#75/#81). A bot thinks every ~0.267 s (BotThinkInterval,
-- rounded up to frames by the THINK_SLICES waits), so a reaction ending between two thinks used to
-- wait for the second one: 0.28 s was really 0.53. When the reaction ends before the next think, this
-- fires the first shot on a timer at the right moment instead. Bounded: at most once per acquisition
-- (bot.quickShotFor), one line-of-sight ray, and only from the plain reaction hold, facing a target
-- inside the front cone (a bot still turning round, taking cover or building waits for its think).
local function quickFirstShot(bot, candidate, head, now)
	local acquiredAt = bot.acquiredAt
	if bot.quickShotFor == acquiredAt then
		return
	end
	local remaining = acquiredAt + MatchConfig.BotReactionTime - now
	if remaining >= MatchConfig.BotThinkInterval then
		return
	end
	bot.quickShotFor = acquiredAt
	local target, targetCharacter, targetRoot = candidate.token, candidate.character, candidate.root
	task.delay(math.max(0, remaining), function()
		if not running or bot.acquiredAt ~= acquiredAt or bot.target ~= target or not bot.weapon then
			return
		end
		local character = bot.character
		local root = character and character.Parent and character:FindFirstChild("HumanoidRootPart")
		if not (root and head.Parent and targetRoot.Parent and bot.humanoid.Health > 0) then
			return
		end
		local to = flat(targetRoot.Position - root.Position)
		if to.Magnitude > 1 and flatLook(root):Dot(to.Unit) < FRONT_CONE_COS then
			return
		end
		STATS.sightChecks += 1
		if not hasLineOfSight(head, targetCharacter, character) then
			return
		end
		STATS.quickShots += 1
		shootAt(bot, target, targetRoot, (targetRoot.Position - root.Position).Magnitude, head)
	end)
end

local function fight(bot, humanoid, root, head, candidate, pressure, now)
	local target, targetRoot, distance = candidate.token, candidate.root, candidate.distance
	local eye = targetRoot.Position + Vector3.new(0, 1.5, 0)
	local dials = ARCH.dialsOf(bot)
	bot.target = target
	bot.lastCombatAt = now
	bot.fightState = "engage"
	-- Fighting interrupts a loot hold. Without resetting it, a bot pulled into combat mid-hold
	-- would return with the time already "elapsed" and claim instantly.
	bot.lootHoldStart = nil
	bot.searchUntil = nil
	remember(bot, target, targetRoot.Position, root, now)
	reportSighting(bot, targetRoot.Position, now, target)
	if bot.acquiredAt == 0 then
		bot.acquiredAt = now
		-- BOT ARCHETYPES: the per-fight decisions, rolled once so a bot commits to them: whether it
		-- takes cover this fight (coverUse), whether it builds (buildRate), which way round it
		-- flanks, and where it was standing when the fight began (repositioning measures from here).
		bot.coverRoll = math.random()
		bot.buildRoll = math.random()
		bot.flankDir = math.random() < 0.5 and 1 or -1
		bot.shotsFromSpot = 0
		bot.peek = nil
		bot.thirdPartyFrom = now
		-- Pre-arm the burst here, during the reaction delay, rather than leaving burstLeft at the 0
		-- losing a target reset it to. Unarmed, shootAt's own burst-discipline check (below) treats
		-- the first call after the reaction delay as "burst exhausted": it only sets burstLeft and
		-- bot.nextShotAt and returns with no shot fired, so the bot pays a full BotBurstRest (0.48s
		-- +0-0.35s) on top of the reaction delay before ever shooting. Measured: a configured 0.28s
		-- reaction was taking 1.25s to the first shot. Arming here means the first shootAt call after
		-- reacting has a live burst waiting and actually fires.
		if bot.burstLeft <= 0 then
			bot.burstLeft = math.random(2, 5)
		end
	end
	BotNav.Progress(bot, humanoid, root, nil, now)
	setSprint(bot, false)

	-- Out of time to get inside, or already in the storm: keep walking in, shooting on the way. In the
	-- storm this beats cover or a retreat at any health, because staying put is what kills it.
	local inStorm = StormService.IsOutside(root.Position)
	if inStorm then
		bot.coverUntil = 0
		bot.coverPoint = nil
	end
	if (pressure >= MatchConfig.BotStormUrgent and humanoid.Health > MatchConfig.BotRetreatHealth) or inStorm then
		setCrouch(bot, false)
		bot.combatMove = nil
		local center, circleRadius = safeCircle()
		if not bot.wanderGoal or not insideCircle(bot.wanderGoal, center, circleRadius, 0.85) then
			bot.wanderGoal = stormGoal(root.Position)
		end
		navigate(bot, humanoid, root, bot.wanderGoal, BotNav.Priority.Urgent, now)
		faceTarget(bot, humanoid, root, targetRoot)
		shootAt(bot, target, targetRoot, distance, head)
		return
	end

	-- Newly spotted targets get the reaction delay before the first shot, whatever the bot is doing.
	local reacted = now - bot.acquiredAt >= MatchConfig.BotReactionTime
	local targetHumanoid = candidate.character and candidate.character:FindFirstChildOfClass("Humanoid")

	-- Reposition: after a fresh hit (repositionOnHit, a Marksman 70% of the time, an Anchor 10%), or
	-- after the class's count of shots since it last moved on purpose (a sniper moves after every
	-- shot, a DMR after three; the strafe steps every bot takes don't count, this is a deliberate
	-- change of position). The current move, cover spot and peek are dropped; for the next moment
	-- standing still is the worst option (planCombatMove), and a smoker puts smoke down before it goes.
	local freshHit = now - bot.lastHurtAt <= MatchConfig.BotThinkInterval + 0.05 and bot.lastHurtAt > bot.acquiredAt
	local overstayed = dials.repositionAfterShots > 0 and (bot.shotsFromSpot or 0) >= dials.repositionAfterShots
	if reacted and (overstayed or (freshHit and math.random() < dials.repositionOnHit)) and not (bot.relocateUntil and now < bot.relocateUntil) then
		STATS.repositions += 1
		bot.relocateUntil = now + 1.5
		bot.combatMove = nil
		bot.coverPoint = nil
		bot.coverUntil = 0
		bot.peek = nil
		bot.shotsFromSpot = 0
		bot.strafeDir = -bot.strafeDir
		local toward = flat(targetRoot.Position - root.Position)
		if dials.smokeToMove and toward.Magnitude > 1 then
			tryThrow(bot, root, head, "smoke", root.Position + toward.Unit * math.min(12, distance / 2), now)
		end
	end

	-- Losing badly and the shooter's close: leave by air, or smoke it and back off to cover,
	-- facing the target so the retreat reads as backpedalling under fire. BOT ARCHETYPES: the health
	-- it happens at is the personality's (a Survivor at 35, a Rusher at 8); MatchConfig is the default.
	if humanoid.Health <= (dials.retreatHealth or MatchConfig.BotRetreatHealth) and distance < 90 then
		bot.fightState = "retreat"
		-- Running for cover, so stand: crouched is 0.45x speed.
		setCrouch(bot, false)
		if tryRocket(bot, humanoid, root, targetRoot, distance, now) then
			return
		end
		local toward = flat(targetRoot.Position - root.Position)
		if toward.Magnitude > 1 then
			tryThrow(bot, root, head, "smoke", root.Position + toward.Unit * math.min(12, distance / 2), now)
		end
		local cover, direct = seekCover(bot, root, eye, now, candidate.character)
		if not (cover and goToCover(bot, humanoid, root, cover, direct, now)) then
			humanoid:MoveTo(combatMove(bot, root, targetRoot.Position, distance, true, now))
		end
		faceTarget(bot, humanoid, root, targetRoot)
		if reacted then
			shootAt(bot, target, targetRoot, distance, head)
		end
		return
	end

	-- Strategy (Oliver, 2026-09-22: "more strategic", "take cover"). Take cover when hurt and being
	-- hit, when reloading within reach of the target, and when two or more enemies are close while
	-- not at full health. Push a target that's nearly dead when the bot is healthy.
	local outnumbered = 0
	if humanoid.Health < humanoid.MaxHealth * 0.85 then
		local near, nearCount = combatantsNear(root.Position, 70)
		for index = 1, nearCount do
			local entry = near[index]
			if entry.token ~= bot and entry.humanoid.Health > 0 and hostile(bot, entry.token)
				and (entry.position - root.Position).Magnitude < 70 then
				outnumbered += 1
			end
		end
	end
	bot.pushing = targetHumanoid ~= nil and targetHumanoid.Health < targetHumanoid.MaxHealth * MatchConfig.BotPushTargetBelow
		and humanoid.Health > humanoid.MaxHealth * MatchConfig.BotPushHealthAbove and not bot.reloadUntil
	-- BOT ARCHETYPES: the push is the personality's call (a Rusher pushes anyone under 70% while it has
	-- 30% itself; an Anchor waits for 30% and 80%). The MatchConfig line above is the stock rule and
	-- what tools/bot_aggression_check.py reads; the dials replace it when the archetype sets them.
	if targetHumanoid and dials.pushTargetBelow then
		bot.pushing = targetHumanoid.Health < targetHumanoid.MaxHealth * dials.pushTargetBelow
			and humanoid.Health > humanoid.MaxHealth * dials.pushHealthAbove and not bot.reloadUntil
	end
	if bot.pushing then
		bot.fightState = "push"
	end
	local wantsCover = (humanoid.Health <= humanoid.MaxHealth * MatchConfig.BotCoverHealth and now - bot.lastHurtAt < 2)
		or (bot.reloadUntil ~= nil and distance < 100)
		or outnumbered >= 2
	-- BOT ARCHETYPES: coverUse is the share of fights in which the bot takes cover when those rules say
	-- it may (a Rusher one in four, an Anchor nine in ten). Reloading still sends everyone behind
	-- something: standing in the open with an empty gun is not a personality.
	if wantsCover and bot.coverRoll and bot.coverRoll > dials.coverUse and bot.reloadUntil == nil then
		wantsCover = false
	end

	-- Third party (Opportunist): the target is busy with somebody else and still healthy, and nobody
	-- is shooting us. Hang back out of the fight, low and behind something if there is anything, and
	-- let them wear each other down; go in once the target is under thirdPartyBelow, once the wait
	-- (thirdPartyWait) runs out, or the moment we are hit. tools/bot_archetype_sim.py measures how
	-- much later an Opportunist's first shot comes than a Rusher's from the same spot.
	if dials.thirdParty and reacted and targetHumanoid and now - bot.lastHurtAt >= THREAT_WINDOW
		and targetHumanoid.Health >= targetHumanoid.MaxHealth * (dials.thirdPartyBelow or 0.6)
		and now - (bot.thirdPartyFrom or now) < (dials.thirdPartyWait or 8) then
		local attacker, _, hitAt = CombatService.GetLastAttacker(target)
		if attacker and attacker ~= bot and hitAt and now - hitAt < THREAT_WINDOW then
			STATS.thirdPartyHolds += 1
			bot.fightState = "thirdParty"
			local cover, direct = seekCover(bot, root, eye, now, candidate.character)
			if cover and goToCover(bot, humanoid, root, cover, direct, now) then
				if flatDistance(root.Position, cover) < 3 then
					bot.coverPoint = nil
					bot.coverUntil = now + BOT_COVER_TIME
					bot.coverAt = root.Position
				end
			else
				holdStill(bot, humanoid, root, now)
			end
			setCrouch(bot, distance > CROUCH_MIN_RANGE)
			faceTarget(bot, humanoid, root, targetRoot)
			return
		end
	end

	-- Hurt and being hit, reloading, or outnumbered: get behind something, or put something up.
	if wantsCover and not bot.pushing then
		local cover, direct = seekCover(bot, root, eye, now, candidate.character)
		if cover and goToCover(bot, humanoid, root, cover, direct, now) then
			bot.fightState = "cover"
			setCrouch(bot, false)
			faceTarget(bot, humanoid, root, targetRoot)
			if reacted then
				shootAt(bot, target, targetRoot, distance, head)
			end
			if flatDistance(root.Position, cover) < 3 then
				STATS.coverReached += 1
				bot.coverPoint = nil
				bot.coverUntil = now + BOT_COVER_TIME
				bot.coverAt = root.Position
				bot.peek = nil
				bot.lastCombatAt = now - MatchConfig.BotHealLull
			end
			return
		end
		if tryBuildExposed(bot, humanoid, root, targetRoot, distance, now)
			or ARCH.tryBuildCross(bot, humanoid, root, targetRoot, distance, now) then
			holdStill(bot, humanoid, root, now)
			faceTarget(bot, humanoid, root, targetRoot)
			return
		end
	end

	if tryBuildAngle(bot, humanoid, root, targetRoot, distance, now)
		or ARCH.tryBuildPushed(bot, humanoid, root, targetRoot, distance, now) then
		holdStill(bot, humanoid, root, now)
		faceTarget(bot, humanoid, root, targetRoot)
		return
	end

	-- Throwables, by gun and personality (Oliver: "make it change how they use throwables too").
	-- A frag goes over when enough of them are bunched round the target (grenadeAt: a Rusher or
	-- Anchor at two, a Marksman at three) and never from a gun that can simply shoot the problem
	-- (noFrags: launcher, LMG, minigun). A corner gun (fragToFlush: shotguns) frags a target it can
	-- only reach through a barricade, to flush it before the push. A sticky goes onto a target in a
	-- vehicle, or onto the barricade it is behind. tryThrow refuses point-blank throws, a teammate in
	-- the blast, and a second frag onto one still ticking.
	if not dials.noFrags then
		local bunched, centre = clusterAround(bot, targetRoot)
		if bunched >= (dials.grenadeAt or 2) and centre then
			tryThrow(bot, root, head, "grenade", centre, now)
		elseif dials.fragToFlush and candidate.throughCover and candidate.throughCover.Parent then
			tryThrow(bot, root, head, "grenade", targetRoot.Position, now)
		end
	end
	if targetHumanoid and targetHumanoid.SeatPart then
		tryThrow(bot, root, head, "sticky", targetRoot.Position, now)
	elseif candidate.throughCover and candidate.throughCover.Parent and candidate.throughCover.GetPivot then
		tryThrow(bot, root, head, "sticky", candidate.throughCover:GetPivot().Position, now)
	end
	-- Crossing open ground toward the target (a shotgun or SMG pushing in): smoke its own approach.
	if dials.smokeToCross and bot.pushing and distance > 30 and distance < 60 then
		local toward = flat(targetRoot.Position - root.Position)
		if toward.Magnitude > 1 then
			tryThrow(bot, root, head, "smoke", root.Position + toward.Unit * (distance * 0.5), now)
		end
	end

	-- Brief reaction delay before the first shot of an engagement — turn toward them
	-- during it rather than freezing in place facing the wrong way.
	if now - bot.acquiredAt < MatchConfig.BotReactionTime then
		holdStill(bot, humanoid, root, now)
		faceTarget(bot, humanoid, root, targetRoot)
		quickFirstShot(bot, candidate, head, now)
		return
	end

	-- Peek and shoot (BOT ARCHETYPES: peek, and the "hold" gun classes): from cover or beside its own
	-- wall, a bot alternates a hidden spell (crouched, still, reloading if the magazine is low: the
	-- class's reloadUnder) with an exposed one in which it stands and fires, rather than standing in
	-- the gap the whole time. The magazine is topped up while hidden so the exposed spell never
	-- opens with a reload.
	local size = magazineOf(bot.weapon)
	local inCover = (bot.coverUntil and now < bot.coverUntil) or (bot.anchor and now < bot.anchor.untilTime)
	if inCover and (dials.peek or dials.peekStyle == "hold") and not bot.pushing then
		local peek = ARCH.peekPhase(bot, now)
		if not peek.exposed then
			bot.fightState = "peekHide"
			if size and bot.mag and bot.mag < size * dials.reloadUnder then
				startReload(bot, now)
			end
			setCrouch(bot, true)
			-- Back behind the cover it came out of, if it has stepped away from it.
			if bot.coverAt and flatDistance(root.Position, bot.coverAt) > 1.5 then
				humanoid:MoveTo(bot.coverAt)
				BotNav.Progress(bot, humanoid, root, nil, now)
			else
				holdStill(bot, humanoid, root, now)
			end
			faceTarget(bot, humanoid, root, targetRoot)
			return
		end
		bot.fightState = "peekShoot"
		setCrouch(bot, false)
		humanoid:MoveTo(combatMove(bot, root, targetRoot.Position, distance, false, now))
		faceTarget(bot, humanoid, root, targetRoot)
		shootAt(bot, target, targetRoot, distance, head)
		return
	elseif inCover and size and bot.mag and bot.mag < size * dials.reloadUnder then
		-- Any class behind cover with a low magazine reloads there rather than in the open.
		startReload(bot, now)
	end

	local point = combatMove(bot, root, targetRoot.Position, distance, false, now)
	if bot.fightState == "engage" then
		bot.fightState = distance < dials.minRange and "open" or "strafe"
	end
	-- Hop now and then while strafing in the open, like a player dodging (Oliver, 2026-09-22: "jump
	-- and strafe more"). Never from cover, never at knife range.
	local jumped = false
	if not (bot.coverUntil and now < bot.coverUntil) and distance > 12 and now >= (bot.nextJumpAt or 0) then
		bot.nextJumpAt = now + 1.2 + math.random() * 2.2
		if math.random() < 0.6 then
			jumped = true
			humanoid.Jump = true
		end
	end
	-- Holding this spot rather than moving to another: get low. Anything closer than this and being
	-- slow matters more than being small.
	-- Crouch when this move is to stay put (or has already arrived), and not at knife range where
	-- being slow costs more than being small.
	local move = bot.combatMove
	local settled = move ~= nil and (move.hold == true or flatDistance(root.Position, move.point) < 3)
	setCrouch(bot, settled and not jumped and distance > CROUCH_MIN_RANGE)
	humanoid:MoveTo(point)
	faceTarget(bot, humanoid, root, targetRoot)
	shootAt(bot, target, targetRoot, distance, head)
end

-- Out of time against the storm: head for the circle it's closing to, sprinting, dropping loot and
-- hunts, and giving up a heading that doesn't go anywhere.
local function runForCircle(bot, humanoid, root, now)
	local center, circleRadius = safeCircle()
	releaseLoot(bot)
	bot.memory = nil
	if not bot.wanderGoal or not insideCircle(bot.wanderGoal, center, circleRadius, 0.85) then
		bot.wanderGoal = stormGoal(root.Position)
		bot.wanderTarget = nil
	end
	setSprint(bot, true)
	trySlide(bot, humanoid, now)
	if not bot.wanderTarget or flatDistance(root.Position, bot.wanderTarget) < 16 then
		bot.wanderTarget = nextLeg(root.Position, bot.wanderGoal)
	end
	if navigate(bot, humanoid, root, bot.wanderTarget, BotNav.Priority.Urgent, now) == "abandon" then
		bot.wanderTarget = nil
	end

	-- Stuck in the storm (Oliver, 2026-09-22: "the bots get stuck in the storm too and just do nothing
	-- about it"). Outside the circle and hardly moved in 1.5 s: stop waiting on a route, walk straight
	-- for the middle and jump, and pick a new heading next time.
	if center and StormService.IsOutside(root.Position) then
		local mark = bot.stormMark
		if not mark or flatDistance(root.Position, mark.position) > 4 then
			bot.stormMark = { position = root.Position, at = now }
		elseif now - mark.at > 1.5 then
			STATS.stormUnstick = (STATS.stormUnstick or 0) + 1
			BotNav.Drop(bot)
			bot.wanderTarget = nil
			bot.wanderGoal = nil
			local toward = flat(center - root.Position)
			if toward.Magnitude > 1 then
				-- A little sideways each time, so a wall dead ahead gets walked round rather than into.
				local side = Vector3.new(-toward.Unit.Z, 0, toward.Unit.X) * (math.random() - 0.5) * 40
				humanoid:MoveTo(root.Position + toward.Unit * math.min(60, toward.Magnitude) + side)
			end
			humanoid.Jump = true
			bot.stormMark = { position = root.Position, at = now }
		end
	else
		bot.stormMark = nil
	end
end

-- An unarmed bot under fire goes for a gun this close instead of running, unless it's toward the shooter.
local UNARMED_GRAB_RANGE = 60

-- Being shot with nothing to shoot back with (or by someone it can't see and is too hurt to hunt):
-- break line of sight, running.
local FLEE_WINDOW = 3

local function flee(bot, humanoid, root, threatPosition, now, threatToken)
	STATS.flees += 1
	bot.combatMove = bot.combatMove and bot.combatMove.retreating and bot.combatMove or nil
	local threatCharacter = threatToken and Combatants.GetCharacter(threatToken) or nil
	-- BOT ARCHETYPES: a Survivor breaks the pursuer's line of sight on the way out, with smoke on the
	-- ground between them and a wall across the pursuer's path (placeBarricade puts it 5 studs toward
	-- the threat, so it is between them, never across the bot's own way out).
	local dials = ARCH.dialsOf(bot)
	local toward = flat(threatPosition - root.Position)
	if toward.Magnitude > 1 then
		if dials.smokeToMove then
			local head = bot.character:FindFirstChild("Head") or root
			tryThrow(bot, root, head, "smoke", root.Position + toward.Unit * math.min(10, toward.Magnitude / 2), now)
		end
		if dials.buildToBlock and canBuild(bot, now) and toward.Magnitude >= BOT_BUILD_MIN and toward.Magnitude <= 60 then
			placeBarricade(bot, root, threatPosition, now, "block")
		end
	end
	local cover, direct = seekCover(bot, root, threatPosition + Vector3.new(0, 1.5, 0), now, threatCharacter)
	setSprint(bot, true)
	trySlide(bot, humanoid, now)
	if cover and goToCover(bot, humanoid, root, cover, direct, now) then
		if direct then
			BotNav.Progress(bot, humanoid, root, cover, now)
		end
		if flatDistance(root.Position, cover) < 3 then
			STATS.coverReached += 1
			bot.coverPoint = nil
			bot.coverUntil = now + BOT_COVER_TIME
		end
		return
	end
	local point = combatMove(bot, root, threatPosition, flatDistance(root.Position, threatPosition), true, now)
	humanoid:MoveTo(point)
	BotNav.Progress(bot, humanoid, root, point, now)
end

-- Only hunt loot while under-armed. Without this, 29 bots sweeping a 200-stud radius every few
-- seconds would strip the map before a player found anything.
-- Carrying nothing always counts. Bots spawn empty-handed, and without this they would never go
-- looking, because the old test read the rarity of a gun they do not have.
--
-- A weapon SpawnLoadout issued counts as sufficient regardless of its rarity. Team modes hand out
-- GameModes.GreenRarity (Uncommon), one tier under this test's old Rare floor, so every team-mode
-- bot read as permanently under-armed: it re-entered the loot-seeking block every 1.5-5s forever,
-- and a truthy lootTarget there returns out of updateBot before the objective/wander code ever
-- runs, so the bot never went to the hill or pushed with its squad. Measured before this fix: 26
-- of 30 TDM bots stuck re-looting, drifting 457-631 studs from the arena centre over a minute.
--
-- A named function rather than an inline local: tools/bot_probe.lua checks this directly, the same
-- way it already does BotService.ExposedTo, rather than needing a real loot spawn near a bot to
-- exercise the branch that reads it.
local function isUnderArmed(bot)
	return not bot.weapon
		or (not bot.loadoutWeapon and (Rarity.Index[bot.weapon.rarity] or 0) < (Rarity.Index.Rare or 3))
end
BotService.IsUnderArmed = isUnderArmed

--------------------------------------------------------------------------------
-- BOT VEHICLES (driving: BotNav's DRIVING section; mounted guns: VehicleWeapons, Shared/VehicleWeaponData)
--------------------------------------------------------------------------------
-- Oliver, 2026-09-24: "make the bots shoot the vehicle guns and drive the cars, with quality vehicle
-- behaviour. And when a player wants to get in, the bot gets out and is replaced by the player." Then:
-- "make the bots not drive away if they have a gun on their car, wait till it's manned".
--
-- A bot gets into a vehicle for one of four reasons, looked at every VEHICLE.CHECK_EVERY seconds
-- while it is on foot (Vehicles.considerVehicle):
--   gunner     an armed vehicle close by has someone waiting at the wheel for a gunner (a teammate, or
--              in the battle royale another bot): it gets on the gun
--   fight      in a fight, an armed vehicle within VEHICLE.FIGHT_SEEK: the gun if it is free, else the
--              wheel (VEHICLE.FIGHT_CHANCE a look, so not every bot in every fight)
--   ride       a team mode: a teammate bot has just taken a vehicle for a trip and a seat is free
--   trip       where it is going (the storm's circle, its objective, the enemy's base, loot) is
--              further than MatchConfig.BotDriveMinTrip and a free vehicle stands within BotBoardReach,
--              not behind it; one without a gun first (a gun needs a gunner)
-- At most MatchConfig.BotDriversMax bots drive at once in a battle royale, BotDriversPerTeam a side
-- in a team mode.
--
-- At the wheel, BotNav's DRIVING section does the driving: routes along the roads when that is
-- quicker (BotService.SetRoads hands it the map's RoadNetwork), a base vehicle out of the yard along
-- its bay's drive-out lane, stops for teammates, goes round what is in the way, backs out when stuck
-- and gives up when it can't, never into water or off a drop, and keeps to the storm's circle or the
-- team arena (every road node it takes is inside it). The decisions are made on the bot's own sliced
-- think (Vehicles.driverThink, which calls BotNav.DriveSense: at most BotNav.DriveCastsPerSense spatial queries,
-- 4, per driving bot per think); the throttle and steer are turned every frame by the servo below,
-- which is arithmetic only (BotNav.DriveControl, no queries), for the handful of bots at a wheel.
-- An armed vehicle with nobody on its gun is not driven anywhere (Oliver: "wait till it's manned"):
-- the bot holds it, works the gun itself only once attacked, and gives it up after BotGunnerWait.
-- With a gunner, the bot at the wheel circles the target at the gun's range and the gunner fires.
--
-- On the gun, every shot goes through VehicleWeapons.Fire, the very function a player's trigger
-- reaches, with the same seat, rate, ammo and team checks. Where the bot aims comes from the same aim
-- dials as a bot on foot (Vehicles.vehicleHitChance, which is shootAt's chance line for line, and
-- tools/bot_driving_combat.py fails if the two ever differ) with the mount's own spread allowed for,
-- and a miss aimed clear of the target. It fires in bursts, lets the belt cool rather than run it dry,
-- holds fire outside the mount's arc, and a round is led by most of the target's run.
--
-- A player who wants a bot's seat triggers its prompt ("Take over", see VehicleService's TAKING OVER):
-- VehicleService asks BotService.YieldSeat, which applies BotService.TakeoverAllowed (a teammate always
-- may; with no teams, anyone the bot is not fighting) and gets the bot out, stopping the car first
-- from the wheel. The bot goes back to what it does on foot.

local RunService = game:GetService("RunService")

-- One table for the section's numbers and one for its functions: BotService's main chunk is near
-- Luau's 200-local limit, and this section would otherwise add fifty.
local VEHICLE = {}
local Vehicles = {}

VEHICLE.CHECK_EVERY = 2.5     -- a bot on foot looks for a vehicle this often (seconds)
-- Oliver 2026-09-24: "make sure the bots get in the cars and use the guns" (main's 3b593e6 took these
-- from 45 studs / 0.35 / fights only / 10 s idle to the numbers below, and let roaming bots on a gun).
VEHICLE.FIGHT_SEEK = 90       -- an armed vehicle this close may be jumped on (in a fight, or roaming)
VEHICLE.FIGHT_CHANCE = 0.7    -- chance, each look in a fight, that a bot goes for one
VEHICLE.ROAM_GUN_CHANCE = 0.4 -- the same for a bot with nobody to fight: it mans a free gun
VEHICLE.WALK = 12             -- seconds walking to a vehicle before giving up on it
VEHICLE.RIDE_REACH = 30       -- a teammate's (or waiting bot's) vehicle this close may be ridden or gunned
VEHICLE.IDLE = 30             -- seconds on a gun nobody drives, with nothing to shoot, before getting down
VEHICLE.REBOARD = 20          -- seconds before a bot that got out (or was asked out) takes one again
VEHICLE.FOE_MEMORY = 8        -- seconds someone a bot shot at, or was shot by, counts as its fight
VEHICLE.RETREAT_HEALTH = 0.35 -- share of a vehicle's health under which its bot drives away from a fight
VEHICLE.BAIL_HEALTH = 0.15    -- ...and under which it gets out before the vehicle is wrecked
VEHICLE.GUARD_RANGE = 70      -- people on foot this close are handed to BotNav to stop for
VEHICLE.ARRIVE = 30           -- studs short of the goal a trip ends (it parks and gets out)
VEHICLE.OFFER = 4             -- seconds a team driver waits at the start for a teammate walking over
VEHICLE.BASE_LANE = 40        -- studs straight out along a parked base vehicle's nose: the yard's way out
VEHICLE.BODY_RADIUS = 0.75    -- half a body's width, for the share of a mount's spread it catches (tools/bot_driving_combat.py DIAL)
VEHICLE.GUN_RANGE = { hitscan = 70, rocket = 80, grenade = 200 } -- where a driver keeps a target
VEHICLE.TAKEOVER_STOP = 1.5   -- seconds the wheel is held stopped for a takeover before the bot gets out

for _, key in ipairs({ "vehicleBoards", "vehicleShots", "vehicleAimedHits", "vehicleTakeovers", "vehicleExits",
	"vehicleWaits" }) do
	STATS[key] = STATS[key] or 0
end

-- Bot record -> its ride while it is in a vehicle. STRONG keys; dropped when it gets out, and
-- pruned when its humanoid is gone.
local riders = {}
-- The map's RoadNetwork (RoadNetwork.Plan's result), handed over when a map is built. Kept across
-- Clear: the next map's replaces it.
Vehicles.roads = nil

function BotService.SetRoads(network)
	Vehicles.roads = network
end

function Vehicles.teamsActive()
	local teams = lazy("ModeTeams")
	return teams ~= nil and teams.IsActive ~= nil and teams.IsActive()
end

function Vehicles.teamOf(token)
	local teams = lazy("ModeTeams")
	if teams and teams.IsActive and teams.IsActive() and teams.TeamOf then
		return teams.TeamOf(token)
	end
	return nil
end

-- Who this bot is fighting: whoever it has had in its sights, or been shot by, in the last
-- VEHICLE.FOE_MEMORY seconds. Published on its character as BotFoes (",userId,userId,") so a
-- player's VehicleClient hides a takeover prompt the server would refuse.
function Vehicles.refreshFoes(bot, now)
	local foes = bot.vehicleFoes
	if not foes then
		foes = {}
		bot.vehicleFoes = foes
	end
	if bot.target then
		foes[bot.target] = now
	end
	if bot.threat and bot.threat.token and now - bot.threat.at < VEHICLE.FOE_MEMORY then
		foes[bot.threat.token] = math.max(foes[bot.threat.token] or 0, bot.threat.at)
	end
	local ids = {}
	for token, at in pairs(foes) do
		if now - at > VEHICLE.FOE_MEMORY then
			foes[token] = nil
		elseif Combatants.IsPlayer(token) then
			table.insert(ids, tostring(token.UserId))
		end
	end
	table.sort(ids)
	local published = #ids > 0 and ("," .. table.concat(ids, ",") .. ",") or nil
	if bot.character and bot.character:GetAttribute("BotFoes") ~= published then
		bot.character:SetAttribute("BotFoes", published)
	end
end

-- Whether `player` may take this bot's seat: a teammate always; with no teams, anyone it is not
-- fighting. VehicleClient's mayTakeOver is the same rule, read from what the server publishes.
function BotService.TakeoverAllowed(bot, player)
	if Vehicles.teamsActive() then
		local mine, theirs = Vehicles.teamOf(bot), Vehicles.teamOf(player)
		return mine ~= nil and mine == theirs
	end
	Vehicles.refreshFoes(bot, os.clock())
	return bot.vehicleFoes[player] == nil
end

-- Gets out. The seat's own exit puts the bot down beside the vehicle (VehicleService.onSeatChanged).
function Vehicles.leaveRide(bot, reason, cooldown)
	local ride = riders[bot] or bot.ride
	riders[bot] = nil
	bot.ride = nil
	bot.boarding = nil
	if ride and ride.seat and ride.seat:IsA("VehicleSeat") then
		ride.seat.ThrottleFloat = 0
		ride.seat.SteerFloat = 0
		ride.seat:SetAttribute("Handbrake", nil)
	end
	if bot.character then
		bot.character:SetAttribute("BotFoes", nil)
	end
	local humanoid = bot.humanoid
	if humanoid and humanoid.SeatPart then
		humanoid.Sit = false
	end
	bot.noVehicleUntil = os.clock() + (cooldown or VEHICLE.REBOARD)
	bot.lastVehicleExit = reason
	STATS.vehicleExits += 1
	if bot.nav then
		BotNav.Drop(bot)
	end
end

-- VehicleService.BotYield: a player asks for `seat`, which this bot holds. False leaves the bot where
-- it is. True means it is getting out: straight away from the gun or a passenger seat, from the wheel
-- once the servo has brought the car to a stop (VEHICLE.TAKEOVER_STOP at most).
function BotService.YieldSeat(bot, player, seat)
	local ride = riders[bot]
	if not ride or ride.seat ~= seat or not BotService.TakeoverAllowed(bot, player) then
		return false
	end
	STATS.vehicleTakeovers += 1
	if ride.role == "driver" then
		ride.yieldTo = { player = player, at = os.clock() }
	else
		Vehicles.leaveRide(bot, "takeover")
	end
	return true
end

-- A driver asked out: the car held on the brake until it has all but stopped, then out.
function Vehicles.yieldServo(bot, ride, now)
	local yieldTo = ride.yieldTo
	if not yieldTo then
		return false
	end
	ride.drive.hold = true
	local speed = ride.drive.chassis.AssemblyLinearVelocity.Magnitude
	if speed < 4 or now - yieldTo.at > VEHICLE.TAKEOVER_STOP then
		Vehicles.leaveRide(bot, "takeover")
		return true
	end
	return false
end

-- The shot's chance, from the same dials as shootAt's (these lines are shootAt's, and
-- tools/bot_driving_combat.py fails if the two ever give different numbers): accuracy by distance, aim
-- settling on a target, a fast target harder to hit. Then what is particular to a mounted gun: firing
-- from a moving vehicle is harder, and a bullet aimed at a body still scatters by the mount's spread
-- (VehicleWeapons.Fire), so the roll is divided by the share of that cone a body covers, and what
-- lands is the dial rather than the dial times the cone.
function Vehicles.vehicleHitChance(ride, now, distance, targetRoot, spec)
	local chance = accuracyAt(distance)
	local settle = math.clamp((now - AIM_SETTLE_DELAY - (ride.fight.acquiredAt or now)) / 1.5, 0, 1)
	chance *= 0.9 + 0.15 * settle
	local velocity = targetRoot.AssemblyLinearVelocity
	if Vector3.new(velocity.X, 0, velocity.Z).Magnitude > 18 or math.abs(velocity.Y) > 8 then
		chance *= 0.85
	end
	local chassis = ride.model.PrimaryPart
	if chassis and chassis.AssemblyLinearVelocity.Magnitude > 30 then
		chance *= 0.85
	end
	if spec.kind ~= "round" and (spec.spread or 0) > 0 then
		-- The spread puts a bullet at a distance from the aim that is even across the cone's radius
		-- `cone` (VehicleWeapons' spread), in any direction. A body `w` wide either side catches every
		-- one inside `w`, and further out those whose sideways part is under `w`:
		-- share = (w + 2/pi * integral from w to cone of asin(w / r) dr) / cone.
		local cone = distance * math.tan(math.rad(spec.spread))
		local w = VEHICLE.BODY_RADIUS
		if cone > w then
			local integral = cone * math.asin(w / cone) + w * math.log(cone + math.sqrt(cone * cone - w * w))
				- (w * math.pi / 2 + w * math.log(w))
			chance = math.min(1, chance / ((w + integral * 2 / math.pi) / cone))
		end
	end
	return chance
end

-- One pull of the mounted gun's trigger, called every frame while `ride.trigger` is set: bursts at
-- the gun's rate with rests between, the belt left to cool back up rather than fired dry, nothing
-- outside the mount's arc or into a round's own blast.
function Vehicles.vehicleTrigger(bot, ride, now)
	local fight = ride.fight
	if not fight or not fight.root.Parent or now < (ride.nextShotAt or 0) then
		return
	end
	local VehicleWeapons = lazy("VehicleWeapons")
	local vehicle = VehicleWeapons and VehicleWeapons.DrivenBy(bot)
	if not vehicle then
		return
	end
	local ammo, spec = VehicleWeapons.AmmoOf(vehicle)
	if not ammo then
		return
	end
	if ride.cooling then
		if ammo < spec.magazine * 0.6 then
			return
		end
		ride.cooling = false
	end
	if ammo < 1 or (spec.magazine >= 10 and ammo < spec.magazine * 0.15) then
		ride.cooling = true
		return
	end
	if (ride.burstLeft or 0) <= 0 then
		local rounds = spec.kind == "round"
		ride.burstLeft = rounds and math.random(1, 2) or math.random(6, 10)
		ride.nextShotAt = now + (rounds and 1.0 + math.random() * 0.8 or MatchConfig.BotBurstRest + math.random() * 0.35)
		return
	end
	local targetRoot = fight.root
	local distance = (targetRoot.Position - vehicle.PrimaryPart.Position).Magnitude
	if not VehicleWeapons.InArc(vehicle, targetRoot.Position) then
		return
	end
	if spec.kind == "round" and distance < (spec.splashRadius or 12) + 6 then
		return
	end
	local hit = math.random() < Vehicles.vehicleHitChance(ride, now, distance, targetRoot, spec)
	local aim = VehicleWeapons.BotAimPoint(vehicle, targetRoot.Position, targetRoot.AssemblyLinearVelocity, hit)
	ride.nextShotAt = now + 1 / spec.fireRate
	local ok, why = VehicleWeapons.Fire(bot, aim)
	if ok then
		ride.burstLeft -= 1
		STATS.vehicleShots += 1
		if hit then
			STATS.vehicleAimedHits += 1
		end
	elseif why == "ammo" then
		ride.cooling = true
	end
end
BotService.VehicleTrigger = Vehicles.vehicleTrigger

-- Every frame, for the bots in a vehicle: the wheel (BotNav.DriveControl, arithmetic only) and the
-- gun's trigger. Started the first time a bot gets in.
Vehicles.servo = nil

function Vehicles.driverServo(bot, ride, dt, now)
	if Vehicles.yieldServo(bot, ride, now) then
		return
	end
	local seat = ride.seat
	local throttle, steer, handbrake = BotNav.DriveControl(ride.drive, dt, now)
	seat.ThrottleFloat = throttle
	seat.SteerFloat = steer
	if (seat:GetAttribute("Handbrake") == true) ~= handbrake then
		seat:SetAttribute("Handbrake", handbrake or nil)
	end
end

function Vehicles.ensureServo()
	local VehicleService = lazy("VehicleService")
	if VehicleService and VehicleService.BotYield ~= BotService.YieldSeat then
		VehicleService.BotYield = BotService.YieldSeat
	end
	if Vehicles.servo then
		return
	end
	Vehicles.servo = RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		for bot, ride in pairs(riders) do
			local humanoid = bot.humanoid
			if humanoid and humanoid.Health > 0 and humanoid.SeatPart == ride.seat then
				if ride.role == "driver" and ride.drive then
					Vehicles.driverServo(bot, ride, dt, now)
				end
				if riders[bot] and ride.trigger then
					Vehicles.vehicleTrigger(bot, ride, now)
				end
			end
		end
	end)
end

function Vehicles.driverCount(team)
	local count = 0
	for other, ride in pairs(riders) do
		local humanoid = other.humanoid
		if not humanoid or humanoid.Health <= 0 or not humanoid.SeatPart then
			riders[other] = nil
		elseif ride.role == "driver" and (team == nil or Vehicles.teamOf(other) == team) then
			count += 1
		end
	end
	return count
end

function Vehicles.driverRoom(bot)
	local team = Vehicles.teamOf(bot)
	local cap = team and (MatchConfig.BotDriversPerTeam or 4) or (MatchConfig.BotDriversMax or 6)
	return Vehicles.driverCount(team) < cap
end

-- Where a bot wants to go, if anywhere, and how close counts as there: its team objective in a team
-- mode; in the battle royale where the storm is going (once it presses), else the loot it is after,
-- else its wander goal.
function Vehicles.travelGoal(bot, root, now)
	local state = BotService.ModeState(bot)
	if state then
		local objective, kind = modeObjective(bot, root, state, now)
		if objective then
			return objective, (kind == "hold" or kind == "contest") and 40 or VEHICLE.ARRIVE
		end
		return nil
	end
	local center, radius = safeCircle()
	if center and (StormService.IsOutside(root.Position) or stormPressure(root.Position) >= MatchConfig.BotStormRotate) then
		if not bot.wanderGoal or not insideCircle(bot.wanderGoal, center, radius, 0.85) then
			bot.wanderGoal = stormGoal(root.Position)
			bot.wanderAt = now
		end
		return bot.wanderGoal, VEHICLE.ARRIVE
	end
	if bot.lootTarget and bot.lootTarget.Parent then
		return bot.lootTarget.Position, 40
	end
	return bot.wanderGoal, VEHICLE.ARRIVE
end

-- Where a route must stay: the circle the storm is heading for, or a team mode's arena.
function Vehicles.driveBounds()
	local teams = lazy("ModeTeams")
	if teams and teams.IsActive and teams.IsActive() and teams.Arena then
		local centre, radius = teams.Arena()
		if centre and radius and radius > 0 then
			return { center = centre, radius = radius - 40 }
		end
	end
	local center, radius = safeCircle()
	if center then
		return { center = center, radius = radius * 0.92 }
	end
	return nil
end

-- People on foot near the car, for BotNav to stop for (teammates) or go round (anyone it isn't
-- fighting). Read from the tick's combatant grid (combatantsNear), not queried.
function Vehicles.guardsNear(bot, position)
	local list = {}
	local team = Vehicles.teamOf(bot)
	local near, count = combatantsNear(position, VEHICLE.GUARD_RANGE)
	for index = 1, count do
		local entry = near[index]
		if entry.token ~= bot and entry.humanoid.Health > 0 and not entry.humanoid.SeatPart then
			local mate = team ~= nil and Vehicles.teamOf(entry.token) == team
			if mate or not (bot.vehicleFoes and bot.vehicleFoes[entry.token]) then
				table.insert(list, { root = entry.root, hard = mate })
			end
		end
	end
	return list
end

-- The sweeps must see past everyone sitting in the car, not stop at the gunner's head.
function Vehicles.riderFilter(ride)
	local list = { ride.model }
	for _, child in ipairs(ride.model:GetChildren()) do
		if child:IsA("Seat") or child:IsA("VehicleSeat") then
			local occupant = child.Occupant
			if occupant and occupant.Parent then
				table.insert(list, occupant.Parent)
			end
		end
	end
	ride.drive.params.FilterDescendantsInstances = list
	ride.drive.probeParams.FilterDescendantsInstances = list
end

function Vehicles.noteFight(bot, ride, candidate, now)
	if not ride.fight or ride.fight.token ~= candidate.token then
		ride.fight = { token = candidate.token, root = candidate.root, acquiredAt = now }
	else
		ride.fight.root = candidate.root
	end
	bot.target = candidate.token
	bot.lastCombatAt = now
	ride.lastTargetAt = now
	reportSighting(bot, candidate.root.Position, now)
end

-- Where the wheel takes an armed vehicle with a gunner in a fight: round the target at the gun's
-- range, a little ahead of where it is on that circle, so the car keeps moving (a parked car is the
-- easiest thing to hit) and the target stays out to the side, inside every mount's arc. Badly
-- damaged, away from it.
function Vehicles.combatGoal(ride, candidate, health, now)
	local VehicleWeapons = lazy("VehicleWeapons")
	local _, spec = VehicleWeapons.AmmoOf(ride.model)
	local want = spec and (spec.kind == "hitscan" and VEHICLE.GUN_RANGE.hitscan
		or VEHICLE.GUN_RANGE[spec.projectile] or VEHICLE.GUN_RANGE.rocket) or VEHICLE.GUN_RANGE.hitscan
	local chassis = ride.drive.chassis
	local target = flat(candidate.root.Position)
	local away = flat(chassis.Position) - target
	if away.Magnitude < 1 then
		away = -flat(chassis.CFrame.LookVector)
	end
	away = away.Unit
	if health < VEHICLE.RETREAT_HEALTH then
		return target + away * 220, { arrive = 25, maxSpeed = nil, loiter = false }
	end
	if not ride.orbit or now > (ride.orbitFlipAt or 0) then
		ride.orbit = ride.orbit and -ride.orbit or (math.random() < 0.5 and 1 or -1)
		ride.orbitFlipAt = now + 12 + math.random() * 8
	end
	local turn = ride.orbit * math.rad(35)
	local c, s = math.cos(turn), math.sin(turn)
	local around = Vector3.new(away.X * c - away.Z * s, 0, away.Z * c + away.X * s)
	return target + around * want, { arrive = 8, maxSpeed = 40, loiter = true }
end

-- At the wheel. Returns nothing; gets out itself when the drive is over.
function Vehicles.driverThink(bot, root, head, ride, now)
	local VehicleService = lazy("VehicleService")
	local VehicleWeapons = lazy("VehicleWeapons")
	local model = ride.model
	local drive = ride.drive
	local maxHealth = model:GetAttribute("VehicleMaxHealth") or 1
	local health = (model:GetAttribute("VehicleHealth") or maxHealth) / math.max(1, maxHealth)
	if model:GetAttribute("Wrecked") or health < VEHICLE.BAIL_HEALTH then
		Vehicles.leaveRide(bot, "wrecked")
		return
	end
	if ride.yieldTo then
		return
	end
	Vehicles.riderFilter(ride)
	Vehicles.refreshFoes(bot, now)
	drive.guard = Vehicles.guardsNear(bot, drive.chassis.Position)
	-- The vehicles about, so BotNav only pulls out to overtake into a clear lane (read from
	-- VehicleService's list, not a spatial query).
	local traffic = {}
	if VehicleService and VehicleService.VehiclesNear then
		for _, near in ipairs(VehicleService.VehiclesNear(drive.chassis.Position, 160)) do
			local chassis = near.entry.rig and near.entry.rig.chassis
			if chassis and chassis ~= drive.chassis then
				table.insert(traffic, chassis)
			end
		end
	end
	drive.traffic = traffic

	local seats = VehicleService and VehicleService.SeatsOf(model)
	local gunnerSeat = seats and seats.gunner or (VehicleWeapons and VehicleWeapons.GunnerSeatOf(model))
	local candidate = findTarget(bot, root, head, now)
	if candidate then
		Vehicles.noteFight(bot, ride, candidate, now)
	else
		ride.fight = nil
	end
	ride.trigger = false

	-- An armed vehicle is not driven anywhere with nobody on its gun: held where it is, the gun worked
	-- from the wheel only once something shoots at it, given up after BotGunnerWait.
	if gunnerSeat and not gunnerSeat.Occupant then
		if not ride.waitSince then
			ride.waitSince = now
			STATS.vehicleWaits += 1
		end
		drive.hold = true
		local attacked = bot.threat ~= nil and now - bot.threat.at < FLEE_WINDOW
		ride.trigger = attacked and candidate ~= nil
		if now - ride.waitSince > (MatchConfig.BotGunnerWait or 25) and not attacked then
			Vehicles.leaveRide(bot, "no gunner")
		end
		return
	end
	ride.waitSince = nil
	drive.hold = false
	-- A team driver off on a trip waits a moment for a teammate walking over to ride along.
	if ride.offerUntil and now < ride.offerUntil and ride.riderComing then
		drive.hold = true
		return
	end

	local goal, options
	if candidate and gunnerSeat then
		goal, options = Vehicles.combatGoal(ride, candidate, health, now)
	elseif candidate and not gunnerSeat and candidate.distance < 45
		and drive.chassis.AssemblyLinearVelocity.Magnitude < 8 then
		-- No gun, someone close, and not going anywhere: better on foot.
		Vehicles.leaveRide(bot, "fight", 6)
		return
	else
		local arrive
		goal, arrive = Vehicles.travelGoal(bot, root, now)
		if not goal then
			Vehicles.leaveRide(bot, "nowhere", 8)
			return
		end
		options = { arrive = arrive }
	end
	goal = flat(goal)
	local moved = ride.goal and flatDistance(ride.goal, goal) or math.huge
	if ride.replan or moved > (options.loiter and 12 or 40) or ride.goalLoiter ~= (options.loiter == true) then
		options.roads = Vehicles.roads
		options.bounds = Vehicles.driveBounds()
		options.preferRoads = ride.preferRoads
		options.via = ride.lane and { ride.lane } or nil
		BotNav.DriveTo(drive, goal, options)
		ride.goal = goal
		ride.goalLoiter = options.loiter == true
		ride.replan = false
		ride.lane = nil
	end

	local status = BotNav.DriveSense(drive, now)
	bot.branch = "drive"
	if status == "arrived" then
		Vehicles.leaveRide(bot, "arrived", 8)
	elseif status == "hazard" then
		-- Water or a drop in the way of the straight line: the roads, once; then on foot.
		if Vehicles.roads and not ride.preferRoads then
			ride.preferRoads = true
			ride.replan = true
		else
			Vehicles.leaveRide(bot, "hazard")
		end
	elseif status == "stuck" or status == "lost" or status == "flipped" then
		Vehicles.leaveRide(bot, status)
	end
end

-- On the gun: find a target and hold the trigger (the servo fires). Nothing to shoot for a while
-- with nobody at the wheel, get down.
function Vehicles.gunnerThink(bot, root, head, ride, now)
	local model = ride.model
	local maxHealth = model:GetAttribute("VehicleMaxHealth") or 1
	local health = (model:GetAttribute("VehicleHealth") or maxHealth) / math.max(1, maxHealth)
	if model:GetAttribute("Wrecked") or health < VEHICLE.BAIL_HEALTH then
		Vehicles.leaveRide(bot, "wrecked")
		return
	end
	Vehicles.refreshFoes(bot, now)
	local candidate = findTarget(bot, root, head, now)
	if candidate then
		Vehicles.noteFight(bot, ride, candidate, now)
		ride.trigger = true
		local VehicleWeapons = lazy("VehicleWeapons")
		if VehicleWeapons and VehicleWeapons.Aim then
			VehicleWeapons.Aim(bot, candidate.root.Position)
		end
	else
		ride.fight = nil
		ride.trigger = false
		local driverSeat = model:FindFirstChild("DriverSeat")
		if not (driverSeat and driverSeat.Occupant) and now - (ride.lastTargetAt or now) > VEHICLE.IDLE then
			Vehicles.leaveRide(bot, "idle", 8)
		end
	end
	bot.branch = "gunner"
end

-- A passenger (team modes): its own gun out of the window, as a player passenger may. No launchers
-- (a round's flight only leaves out the bot, not the car it is sitting in). Out when the driver is.
function Vehicles.passengerThink(bot, root, head, ride, now)
	local model = ride.model
	local driverSeat = model:FindFirstChild("DriverSeat")
	if model:GetAttribute("Wrecked") or not (driverSeat and driverSeat.Occupant) then
		Vehicles.leaveRide(bot, "driver gone", 6)
		return
	end
	finishReload(bot, now)
	local candidate = bot.weapon and not bot.weapon.projectile and findTarget(bot, root, head, now) or nil
	if candidate and candidate.distance <= bot.weapon.range then
		if bot.target ~= candidate.token then
			bot.acquiredAt = now
		end
		bot.target = candidate.token
		bot.lastCombatAt = now
		shootAt(bot, candidate.token, candidate.root, candidate.distance, head)
	else
		bot.target = nil
	end
	bot.branch = "passenger"
end

-- Sat down: the ride starts. A driver gets a BotNav drive; a base vehicle still in its bay is driven
-- out along the bay's nose first (TeamBaseRuins' yard: every bay faces its way out through a gate).
function Vehicles.startRide(bot, role, seat, purpose, now)
	local model = seat.Parent
	local ride = { role = role, model = model, seat = seat, purpose = purpose, boardedAt = now, lastTargetAt = now,
		burstLeft = 0, nextShotAt = 0 }
	if role == "driver" then
		local VehicleService = lazy("VehicleService")
		local entry = VehicleService and VehicleService.Get(model)
		local rig = entry and entry.rig
		if not rig or not rig.handling or not rig.wheels or #rig.wheels == 0 then
			return nil
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { model }
		params.IgnoreWater = true
		local probe = RaycastParams.new()
		probe.FilterType = Enum.RaycastFilterType.Exclude
		probe.FilterDescendantsInstances = { model }
		probe.IgnoreWater = false
		local chassis = rig.chassis
		-- Ride height, once at boarding; refused by the budget, the usual 2.5 stands.
		local below = castRay(chassis.Position, Vector3.new(0, -20, 0), params, "navigation")
		ride.drive = BotNav.NewDrive(chassis, rig.handling, {
			wheelbase = rig.wheelbase, params = params, probeParams = probe,
			rideHeight = below and chassis.Position.Y - below.Position.Y or 2.5,
		})
		local teams = lazy("ModeTeams")
		local folder = teams and teams.BaseVehicleFolder and teams.BaseVehicleFolder()
		if folder and model:IsDescendantOf(folder) and chassis.AssemblyLinearVelocity.Magnitude < 1 then
			local look = flat(chassis.CFrame.LookVector)
			if look.Magnitude > 0.1 then
				ride.lane = flat(chassis.Position) + look.Unit * VEHICLE.BASE_LANE
			end
		end
		if purpose == "trip" and Vehicles.teamsActive() then
			ride.offerUntil = now + VEHICLE.OFFER
		end
	end
	riders[bot] = ride
	bot.ride = ride
	bot.boarding = nil
	STATS.vehicleBoards += 1
	Vehicles.ensureServo()
	return ride
end

-- The seat this bot on foot should go for now, if any, with its role and reason.
-- How keen this bot is on vehicles, scaling its chance of jumping on a gun (1 = the numbers above).
-- TODO(looting worker): BotService.Loot.vehiclePreference(bot) is not in this file yet; until it
-- lands this is 1 for everyone, and it is picked up as soon as it exists.
function Vehicles.preference(bot)
	local loot = BotService.Loot
	if type(loot) == "table" and type(loot.vehiclePreference) == "function" then
		local ok, value = pcall(loot.vehiclePreference, bot)
		if ok and type(value) == "number" then
			return math.max(0, value)
		end
	end
	return 1
end

function Vehicles.pickSeat(bot, root, now)
	local VehicleService = lazy("VehicleService")
	if not VehicleService or not VehicleService.VehiclesNear then
		return nil
	end
	local team = Vehicles.teamOf(bot)
	local fighting = bot.target ~= nil or (bot.threat ~= nil and now - bot.threat.at < FLEE_WINDOW)
	local reach = math.max(MatchConfig.BotBoardReach or 60, VEHICLE.FIGHT_SEEK, VEHICLE.RIDE_REACH)
	local near = VehicleService.VehiclesNear(root.Position, reach)
	if #near == 0 then
		return nil
	end

	-- Someone waiting at the wheel for a gunner, or a teammate setting off with a seat free.
	for _, found in ipairs(near) do
		if found.distance <= VEHICLE.RIDE_REACH then
			local seats = VehicleService.SeatsOf(found.model)
			local driver = seats and seats.driver.Occupant
			local holder = driver and driver.Parent and Combatants.FromCharacter(driver.Parent)
			local friendly = holder ~= nil and ((team ~= nil and Vehicles.teamOf(holder) == team)
				or (team == nil and Combatants.IsBot(holder) and riders[holder] ~= nil))
			if friendly then
				local ride = riders[holder]
				if seats.gunner and not seats.gunner.Occupant then
					return seats.gunner, "gunner", "gunner"
				end
				if team ~= nil and ride and ride.offerUntil and now < ride.offerUntil and not fighting then
					for _, passenger in ipairs(seats.passengers) do
						if not passenger.Occupant then
							ride.riderComing = true
							return passenger, "passenger", "ride"
						end
					end
				end
			end
		end
	end

	if fighting then
		if math.random() > VEHICLE.FIGHT_CHANCE * Vehicles.preference(bot) then
			return nil
		end
		for _, found in ipairs(near) do
			local seats = VehicleService.SeatsOf(found.model)
			if found.distance <= VEHICLE.FIGHT_SEEK and seats and seats.gunner then
				if not seats.gunner.Occupant then
					return seats.gunner, "gunner", "fight"
				end
				if not seats.driver.Occupant and Vehicles.driverRoom(bot) then
					return seats.driver, "driver", "fight"
				end
			end
		end
		return nil
	end

	if bot.gearUntil and now < bot.gearUntil then
		return nil
	end
	-- Roaming past a free gun: now and then a bot mans it, and watches from it (VEHICLE.IDLE) for
	-- someone to shoot or someone to drive it.
	if math.random() < VEHICLE.ROAM_GUN_CHANCE * Vehicles.preference(bot) then
		for _, found in ipairs(near) do
			local seats = VehicleService.SeatsOf(found.model)
			if found.distance <= VEHICLE.FIGHT_SEEK and seats and seats.gunner and not seats.gunner.Occupant then
				return seats.gunner, "gunner", "fight"
			end
		end
	end

	-- A trip: somewhere far, a free wheel close by and not back the way it came. One with an unmanned
	-- gun last, since that gun needs a gunner before it goes anywhere.
	local goal = Vehicles.travelGoal(bot, root, now)
	if not goal or flatDistance(goal, root.Position) < (MatchConfig.BotDriveMinTrip or 220) or not Vehicles.driverRoom(bot) then
		return nil
	end
	local best, bestScore = nil, math.huge
	for _, found in ipairs(near) do
		local seats = VehicleService.SeatsOf(found.model)
		if seats and not seats.driver.Occupant and found.distance <= (MatchConfig.BotBoardReach or 60) then
			local position = found.model:GetPivot().Position
			if flatDistance(position, goal) < flatDistance(root.Position, goal) + 20 then
				local score = found.distance + ((seats.gunner and not seats.gunner.Occupant) and 50 or 0)
				if score < bestScore then
					best, bestScore = seats.driver, score
				end
			end
		end
	end
	if best then
		return best, "driver", "trip"
	end
	return nil
end

-- On foot: walking to a seat already, or looking for one. True while this think went on that.
function Vehicles.considerVehicle(bot, humanoid, root, now)
	local boarding = bot.boarding
	if boarding then
		local seat = boarding.seat
		if now > boarding.giveUpAt or seat.Occupant or not seat:IsDescendantOf(workspace)
			or (boarding.role == "driver" and not Vehicles.driverRoom(bot)) then
			bot.boarding = nil
			bot.noVehicleUntil = now + VEHICLE.CHECK_EVERY * 2
			return false
		end
		local VehicleService = lazy("VehicleService")
		if VehicleService and VehicleService.BotSit(humanoid, seat) then
			if Vehicles.startRide(bot, boarding.role, seat, boarding.purpose, now) then
				return true
			end
			Vehicles.leaveRide(bot, "unrideable")
			return false
		end
		if navigate(bot, humanoid, root, seat.Position, BotNav.Priority.Loot, now) == "abandon" then
			bot.boarding = nil
		end
		return true
	end
	if bot.dropping or now < (bot.noVehicleUntil or 0) or now < (bot.vehicleCheckAt or 0) then
		return false
	end
	bot.vehicleCheckAt = now + VEHICLE.CHECK_EVERY
	local seat, role, purpose = Vehicles.pickSeat(bot, root, now)
	if not seat then
		return false
	end
	bot.boarding = { seat = seat, role = role, purpose = purpose, giveUpAt = now + VEHICLE.WALK }
	navigate(bot, humanoid, root, seat.Position, BotNav.Priority.Loot, now)
	return true
end

-- Returns true when this think was spent in a vehicle, or on the way to one.
function Vehicles.botVehicleThink(bot, humanoid, root, head, now)
	local ride = bot.ride
	if ride then
		if humanoid.SeatPart ~= ride.seat or not ride.model.Parent then
			-- Out some other way (thrown clear of a wreck, a blast, jumped): back on foot.
			Vehicles.leaveRide(bot, "unseated", 6)
			return false
		end
		stopFacing(bot, humanoid)
		if ride.role == "driver" then
			Vehicles.driverThink(bot, root, head, ride, now)
		elseif ride.role == "gunner" then
			Vehicles.gunnerThink(bot, root, head, ride, now)
		else
			Vehicles.passengerThink(bot, root, head, ride, now)
		end
		return true
	end
	if humanoid.SeatPart then
		-- Sat in something this section didn't put it in: stand up.
		humanoid.Sit = false
		return false
	end
	return Vehicles.considerVehicle(bot, humanoid, root, now)
end

--------------------------------------------------------------------------------
-- BOT ARCHETYPES, the dealing half (the dials are at the top of the file)
--------------------------------------------------------------------------------

-- GameMode requires this module while loading (its replacement bots), so it is reached lazily.
function ARCH.modeIdNow()
	local gameMode = lazy("GameMode")
	local ok, current = pcall(function()
		return gameMode and gameMode.Current and gameMode.Current() or nil
	end)
	return ok and current and current.id or "BattleRoyale"
end

-- A shuffled deck holding the mix exactly for `count` bots, dealt in pairs so a team mode's alternate
-- dealing (ModeTeams.Assign puts each new bot on the smaller side) gives both teams the same roles.
function ARCH.deck(count, mix)
	local deck = {}
	local total = 0
	for _, name in ipairs(ARCH.Order) do
		total += mix[name] or 0
	end
	local carry = 0
	for _, name in ipairs(ARCH.Order) do
		local share = (mix[name] or 0) / math.max(1, total) * count + carry
		local n = math.floor(share + 0.5)
		carry = share - n
		for _ = 1, n do
			table.insert(deck, name)
		end
	end
	while #deck < count do
		table.insert(deck, ARCH.Order[math.random(1, #ARCH.Order)])
	end
	-- Shuffle in pairs: positions 1-2 alike, 3-4 alike... so alternate teams get a matching role.
	local pairsList = {}
	table.sort(deck)
	for index = 1, #deck, 2 do
		table.insert(pairsList, { deck[index], deck[index + 1] or deck[index] })
	end
	for index = #pairsList, 2, -1 do
		local j = math.random(1, index)
		pairsList[index], pairsList[j] = pairsList[j], pairsList[index]
	end
	local dealt = {}
	for _, pair in ipairs(pairsList) do
		table.insert(dealt, pair[1])
		table.insert(dealt, pair[2])
	end
	return dealt
end

-- Team modes: once a bot knows its team, the team's roles are counted and this bot swaps to whatever
-- the mix says the team is shortest of, if it is itself one the team has too many of. Once per body:
-- a replacement bot (spawned singly, so no deck) lands in the gap the death left.
function ARCH.balance(bot, team, mix, teamOf)
	local counts, total = {}, 0
	for _, other in ipairs(bots) do
		if other ~= bot and other.humanoid and other.humanoid.Health > 0 and teamOf(other) == team then
			local name = (other.archetype or ARCH.Types.Rusher).name
			counts[name] = (counts[name] or 0) + 1
			total += 1
		end
	end
	local mine = (bot.archetype or ARCH.Types.Rusher).name
	local size = total + 1
	-- A side of three is too small to have a "shortest role": the deck's deal stands.
	if size < 4 then
		return
	end
	local shortest, shortfall = nil, 0
	for _, name in ipairs(ARCH.Order) do
		local want = (mix[name] or 0) / 100 * size
		local gap = want - (counts[name] or 0)
		if gap > shortfall then
			shortest, shortfall = name, gap
		end
	end
	-- Only swap when this role is already covered: the deck put the right number on the team.
	local wantMine = (mix[mine] or 0) / 100 * size
	if shortest and shortest ~= mine and (counts[mine] or 0) + 1 > wantMine + 0.5 then
		BotService.AssignArchetype(bot, shortest)
	end
end

local function updateBot(bot)
	local humanoid = bot.humanoid
	if not humanoid or humanoid.Health <= 0 or not bot.character.Parent then
		return
	end

	local root = bot.character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	-- Still gliding in: MovementService has the controls until it lands.
	if bot.dropping then
		return
	end

	local now = os.clock()
	local head = bot.character:FindFirstChild("Head") or root

	-- Oliver: "bots teleport around a lot". Welding a gun or companion on changes the assembly and
	-- Roblox hands its physics to a nearby player's client until the server claims it back; that
	-- used to wait for forgetStale's 5 s sweep, and a client-owned bot rubber-bands. Re-claim every second.
	if now - (bot.claimedAt or 0) > 1 then
		bot.claimedAt = now
		claimPhysics(bot.character)
	end

	updateAnimation(bot, humanoid)

	-- Mid-climb or mid-vault: MovementService is driving the root until it lets go. Afterwards the
	-- route is checked against where the move left the bot.
	if bot.character:GetAttribute("Parkour") then
		bot.inParkour = true
		return
	end
	if bot.inParkour then
		bot.inParkour = false
		bot.nav.recheckRouteAt = now
	end

	-- Taking damage counts as combat even from an attacker we can't see, otherwise a bot
	-- being sniped from cover would quietly heal through it. Where the shot came from is known the
	-- way a player's damage indicator knows it.
	if humanoid.Health < bot.lastHealth then
		bot.lastCombatAt = now
		bot.lastHurtAt = now
		-- Only a hit since the last think names a shooter. GetLastAttacker remembers 12 s, so without the
		-- hit time, storm damage would send a bot running from someone who stopped shooting long ago.
		local attacker, _, hitAt = CombatService.GetLastAttacker(bot)
		local fresh = hitAt ~= nil and now - hitAt <= MatchConfig.BotThinkInterval + 0.1
		if hitAt == nil then
			-- An older CombatService without the hit time: at least ignore it while outside the storm.
			fresh = not StormService.IsOutside(root.Position)
		end
		local attackerRoot = fresh and attacker and Combatants.GetRoot(attacker)
		if attackerRoot then
			bot.threat = { token = attacker, position = attackerRoot.Position, at = now }
		end
	end
	bot.lastHealth = humanoid.Health

	-- BOT VEHICLES (section above): in a vehicle (at the wheel, on the gun, riding), or walking to one.
	if Vehicles.botVehicleThink(bot, humanoid, root, head, now) then
		return
	end

	-- Slow out-of-combat regen: the fallback for a bot with no heal items left. Over the time since
	-- the last think, not a fixed interval: a far-from-players bot thinks every other turn (LOD) and
	-- must heal at the same rate as one thinking every turn.
	if humanoid.Health < humanoid.MaxHealth and now - bot.lastCombatAt > MatchConfig.BotRegenDelay then
		local since = bot.thoughtAt and math.min(now - bot.thoughtAt, MatchConfig.BotThinkInterval * 3)
			or MatchConfig.BotThinkInterval
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + MatchConfig.BotRegenPerSecond * since)
	end

	if now >= bot.strafeFlipAt then
		bot.strafeDir = -bot.strafeDir
		bot.strafeFlipAt = now + 0.9 + math.random() * 1.3
	end

	forgetStale(bot, now)
	finishReload(bot, now)
	local pressure = stormPressure(root.Position)

	-- BOT ARCHETYPES: a team bot checks its role against its side's once it knows which side that is.
	if bot.archetypeBalancedFor ~= bot.character then
		local state = BotService.ModeState(bot)
		if state then
			bot.archetypeBalancedFor = bot.character
			local teams = lazy("ModeTeams")
			if teams and teams.TeamOf then
				ARCH.balance(bot, state.team, ARCH.Mix[ARCH.modeIdNow()] or ARCH.Mix.TeamDeathmatch, teams.TeamOf)
			end
		end
	end

	-- Nothing to shoot with means nothing counts as a target: an unarmed bot falls through to
	-- looting (or running) instead of squaring up to someone empty-handed.
	local candidate = bot.weapon and findTarget(bot, root, head, now) or nil
	if candidate and candidate.distance > bot.weapon.range then
		-- Seen but out of reach: close in on where they are rather than plinking at nothing.
		remember(bot, candidate.token, candidate.root.Position, root, now)
		candidate = nil
	end
	-- BOT ARCHETYPES: a Survivor (avoidUnforced) fights only when it has to: the target is shooting
	-- it, is inside its own range, or is at a team objective it stands on. Anyone else it lets go,
	-- ducking out of their sight if they could see it. It does not remember them to hunt.
	if candidate and ARCH.dialsOf(bot).avoidUnforced then
		local forced = now - bot.lastHurtAt < THREAT_WINDOW or candidate.distance <= ARCH.dialsOf(bot).range * 1.1
			or (bot.objectiveKind == "hold" or bot.objectiveKind == "contest") and bot.wanderGoal
				and flatDistance(root.Position, bot.wanderGoal) < 30
		if not forced then
			STATS.avoided += 1
			bot.branch = "avoid"
			bot.target = nil
			bot.acquiredAt = 0
			local threatEye = candidate.root.Position + Vector3.new(0, 1.5, 0)
			if exposedTo(bot, root, threatEye) then
				local cover, direct = seekCover(bot, root, threatEye, now, candidate.character)
				if cover and goToCover(bot, humanoid, root, cover, direct, now) then
					setSprint(bot, true)
					return
				end
			end
			candidate = nil
		end
	end
	if candidate then
		bot.branch = "fight"
		fight(bot, humanoid, root, head, candidate, pressure, now)
		return
	end
	bot.fightState = nil

	bot.target = nil
	bot.acquiredAt = 0
	bot.burstLeft = 0
	bot.combatMove = nil
	stopFacing(bot, humanoid)

	-- A lull with a half-empty magazine: reload now rather than mid-fight.
	local size = magazineOf(bot.weapon)
	if size and bot.mag and bot.mag < size * 0.5 and now - bot.lastCombatAt > 1.5 then
		startReload(bot, now)
	end

	-- A frag or round about to go off right here: get clear before anything else.
	local danger = inDanger(root.Position, dangersNear(root.Position, 20))
	if danger then
		bot.branch = "dodge"
		setCrouch(bot, false)
		STATS.dangerDodges += 1
		humanoid:MoveTo(combatMove(bot, root, danger.position, flatDistance(root.Position, danger.position), true, now))
		BotNav.Progress(bot, humanoid, root, nil, now)
		return
	end

	local threat = bot.threat
	local shotAtRecently = threat and now - threat.at < FLEE_WINDOW

	-- In the storm, getting out comes before healing up, building or holding in cover: every one of
	-- those stood a bot still while the storm killed it. Heals still go in on the move.
	if StormService.IsOutside(root.Position) and pressure >= MatchConfig.BotStormUrgent then
		bot.coverUntil = 0
		bot.branch = "storm"
		setCrouch(bot, false)
		tryHeal(bot, humanoid, now)
		tryShield(bot, humanoid, now)
		runForCircle(bot, humanoid, root, now)
		return
	end

	-- Nobody in sight: patch up before moving on (behind a barricade first, if the shooter could still
	-- see us here). Doesn't return, so it heals on the move.
	if tryBuildBeforeHeal(bot, humanoid, root, now) then
		holdStill(bot, humanoid, root, now)
		return
	end
	tryHeal(bot, humanoid, now)
	tryShield(bot, humanoid, now)

	-- Behind cover or our own barricade: hold there while the heals go in, then carry on. Down low
	-- while doing it: the bot isn't going anywhere, and something is shooting at it.
	if bot.coverUntil > now then
		-- BOT ARCHETYPES: a peeker with a target it lost a moment ago steps out to the side of its cover
		-- to look for it (peekPhase), and back in again; the moment the target is seen, fight() runs
		-- the same cycle with the gun. Everyone else waits it out.
		local dials = ARCH.dialsOf(bot)
		local memory = bot.memory
		if (dials.peek or dials.peekStyle == "hold") and bot.weapon and memory and now - memory.at < 6 then
			local peek = ARCH.peekPhase(bot, now)
			local toward = flat(memory.position - root.Position)
			if peek.exposed and toward.Magnitude > 1 then
				bot.branch = "peek"
				setCrouch(bot, false)
				local right = Vector3.new(-toward.Unit.Z, 0, toward.Unit.X)
				local from = bot.coverAt or root.Position
				humanoid:MoveTo(from + right * peek.side * 5 + toward.Unit * 2)
				BotNav.Progress(bot, humanoid, root, nil, now)
				facePoint(bot, humanoid, root, memory.position)
				return
			end
			if bot.coverAt and flatDistance(root.Position, bot.coverAt) > 1.5 then
				setCrouch(bot, true)
				humanoid:MoveTo(bot.coverAt)
				BotNav.Progress(bot, humanoid, root, nil, now)
				return
			end
		end
		setCrouch(bot, true)
		holdStill(bot, humanoid, root, now)
		BotNav.Drop(bot)
		return
	end
	setCrouch(bot, false)

	-- Outside the storm with no time left: that's what kills it first, so head in before running from
	-- anyone.
	if pressure >= MatchConfig.BotStormUrgent and StormService.IsOutside(root.Position) then
		bot.branch = "storm"
		runForCircle(bot, humanoid, root, now)
		return
	end

	-- Unarmed, or too hurt to go looking for whoever's shooting: get out of their sight. A pickup
	-- right at our feet is still worth grabbing on the way.
	local low = humanoid.Health <= humanoid.MaxHealth * MatchConfig.BotFleeHealth
	local grabbing = bot.lootTarget and (bot.lootTarget.Position - root.Position).Magnitude < 13
	if shotAtRecently and (not bot.weapon or low) and not grabbing then
		-- Unarmed, a gun close by is the better way out, as long as it isn't toward the shooter: go and
		-- get it at a sprint. Running from every shot left a quarter of the bots never armed.
		local escape = nil
		if not bot.weapon then
			local item = bot.lootTarget
			if not item and now >= bot.escapeScanAt then
				bot.escapeScanAt = now + 1
				item = findLoot(bot, root.Position, UNARMED_GRAB_RANGE, false, nil, nil, now)
			end
			if item and item.Parent then
				local toItem = flat(item.Position - root.Position)
				local toShooter = flat(threat.position - root.Position)
				local sideways = toItem.Magnitude < 20 or toShooter.Magnitude < 1
					or toItem.Unit:Dot(toShooter.Unit) < 0.5
				if toItem.Magnitude <= UNARMED_GRAB_RANGE and sideways then
					escape = item
				end
			end
		end
		if escape then
			setLootTarget(bot, escape)
			setSprint(bot, true)
		else
			releaseLoot(bot)
			if not (bot.coverPoint and not bot.coverPoint.direct) then
				BotNav.Drop(bot)
			end
			bot.branch = "flee"
			flee(bot, humanoid, root, threat.position, now, threat.token)
			return
		end
	end
	if shotAtRecently and bot.weapon and flatDistance(root.Position, threat.position) <= HUNT_MAX_DISTANCE
		and (not bot.memory or bot.memory.at < threat.at) then
		remember(bot, threat.token, threat.position, root, now)
	end

	local center, circleRadius = nil, nil
	if pressure >= MatchConfig.BotStormRotate then
		center, circleRadius = safeCircle()
	end

	-- Out of time: straight for the safe circle, sprinting, nothing else.
	if pressure >= MatchConfig.BotStormUrgent then
		bot.branch = "storm"
		runForCircle(bot, humanoid, root, now)
		return
	end

	-- Hunting: go to where the target was last seen, look around, and let it go if nobody's there.
	local memory = bot.memory
	if memory and bot.weapon and now < memory.expires and (not center or insideCircle(memory.position, center, circleRadius)) then
		bot.branch = "hunt"
		releaseLoot(bot)
		setSprint(bot, false)
		-- A frag onto where they went, from a gun that can't just shoot round the corner (BOT ARCHETYPES:
		-- noFrags classes keep theirs; a shotgun flushing a corner is the point of it).
		local grenadeReady = now - memory.at < 4 and not ARCH.dialsOf(bot).noFrags
		if grenadeReady then
			tryThrow(bot, root, head, "grenade", memory.position, now)
		end
		if flatDistance(root.Position, memory.position) < 8 then
			if not bot.searchUntil then
				STATS.searches += 1
				bot.searchUntil = now + 2
				bot.searchAngle = math.random() * math.pi * 2
			end
			if now < bot.searchUntil then
				holdStill(bot, humanoid, root, now)
				local angle = bot.searchAngle + math.floor((bot.searchUntil - now) / 0.6) * math.pi / 2
				facePoint(bot, humanoid, root, root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 10)
				return
			end
			stopFacing(bot, humanoid)
			bot.memory = nil
			bot.searchUntil = nil
		else
			if not bot.hunting or bot.hunting ~= memory then
				bot.hunting = memory
				STATS.hunts += 1
			end
			if navigate(bot, humanoid, root, memory.position, BotNav.Priority.Combat, now) == "abandon" then
				bot.memory = nil
			end
			return
		end
	end

	-- Team modes: IDLE WATCHDOG (Oliver, 2026-09-23 14:49: "many team bots still stand around and do
	-- nothing"). Out of a fight, a team bot that has hardly moved in 6 s (and is not mid-pickup) drops
	-- whatever it was waiting on and walks straight at its objective for a few seconds, jumping, before
	-- the normal planner takes over again. Whatever it was stuck on is left alone for a while.
	if BotService.ModeState(bot) then
		local mark = bot.idleMark
		if bot.idleKickUntil and now < bot.idleKickUntil and bot.idleKickGoal then
			humanoid:MoveTo(bot.idleKickGoal)
			if math.random() < 0.15 then
				humanoid.Jump = true
			end
			return
		end
		-- Standing still ON its objective is the job (holding a KOTH ring), not idling: kicking it off
		-- every few seconds left the ring unguarded.
		local onObjective = false
		if mark and not bot.lootHoldStart and now - mark.at > 6 then
			local objective = modeObjective(bot, root, BotService.ModeState(bot), now)
			onObjective = objective ~= nil and flatDistance(objective, root.Position) < 10
		end
		if not mark or flatDistance(root.Position, mark.position) > 6 or bot.lootHoldStart or onObjective then
			bot.idleMark = { position = root.Position, at = now }
		elseif now - mark.at > 6 then
			STATS.teamIdleKicks = (STATS.teamIdleKicks or 0) + 1
			if bot.lootTarget then
				blacklistLoot(bot, bot.lootTarget, 40, now)
				releaseLoot(bot)
			end
			bot.gearUntil = nil
			bot.wanderGoal = nil
			BotNav.Drop(bot)
			local goal = modeObjective(bot, root, BotService.ModeState(bot), now)
			if not goal or flatDistance(goal, root.Position) < 10 then
				local angle = math.random() * math.pi * 2
				goal = root.Position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * 40
			end
			local toward = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
			bot.idleKickGoal = root.Position + toward.Unit * math.min(50, toward.Magnitude)
				+ Vector3.new(-toward.Unit.Z, 0, toward.Unit.X) * (math.random() - 0.5) * 20
			bot.idleKickUntil = now + 3
			bot.idleMark = { position = root.Position, at = now }
			humanoid.Jump = true
			humanoid:MoveTo(bot.idleKickGoal)
			return
		end
	end

	-- Looting. Bots contest chests and floor guns like anyone else, which is what stops
	-- loot from being a resource only real players compete for.
	if bot.lootTarget and (not bot.lootTarget.Parent or bot.lootTarget:GetAttribute("Claimed")
		or not insideCircle(bot.lootTarget.Position, center, circleRadius, 0.9)) then
		releaseLoot(bot)
		BotNav.Drop(bot)
	end

	-- Only hunt loot while under-armed (isUnderArmed above updateBot).
	local underArmed = isUnderArmed(bot)

	-- Carrying nothing is urgent: look again every second or so, and look further afield, rather
	-- than idling five seconds at a time between sweeps while defenceless. Once armed it drops
	-- back to the slow sweep that keeps 29 bots from stripping the map before a player lands.
	local empty = bot.weapon == nil
	-- Team modes: GEAR UP AT THE BASE after every spawn, before heading for the fight (Oliver, 2026-09-23
	-- 14:38: the bots "left all the loot behind" and "rush into battle"; "make the bots go after the chests
	-- when they spawn"). For up to BASE_GEAR_SECONDS after a new body the bot looks every 0.6 s, chests
	-- first, then better guns and heals; the phase ends early once the base has nothing left it wants.
	-- A fight still comes first: combat and hunting run before this.
	local gearState = BotService.ModeState(bot)
	if gearState and bot.gearCharacter ~= bot.character then
		bot.gearCharacter = bot.character
		bot.gearStart = now
		bot.gearUntil = now + (MatchConfig.BotBaseGearSeconds or 30)
	end
	if gearState and bot.gearUntil and now < bot.gearUntil and not bot.lootTarget and now - bot.lootCheckedAt > 0.6 then
		bot.lootCheckedAt = now
		local item = BotService.FindBaseLoot(bot, root, gearState, center, circleRadius, now, true)
		if item then
			setLootTarget(bot, item)
		elseif now - (bot.gearStart or now) > 4 then
			-- Nothing left worth having (the first few seconds are allowed for the base to be stocked).
			bot.gearUntil = nil
		end
	end

	if not bot.lootTarget and now - bot.lootCheckedAt > (empty and 1.5 or 5) then
		bot.lootCheckedAt = now
		-- A landed supply drop is worth contesting at any armament level; ordinary loot only
		-- while under-armed.
		-- Team modes: bots fight, they don't tour the map for crates (#134). Supply drops and armed
		-- chest runs are Battle Royale only; an under-armed team bot still grabs gear nearby.
		local teamMode = BotService.ModeState(bot) ~= nil
		local item = not teamMode and SupplyDropService.FindNearest(root.Position, SUPPLY_SEEK_RANGE) or nil
		if item and not lootAllowed(bot, item, (item.Position - root.Position).Magnitude, center, circleRadius, now) then
			item = nil
		end
		if not item and underArmed then
			item = findLoot(bot, root.Position, empty and LOOT_SEEK_RANGE * 1.6 or LOOT_SEEK_RANGE, false, center, circleRadius, now)
		end
		-- Team modes: raid the home base's stock first (upgrades, chests, heals).
		if not item and teamMode then
			local modeState = BotService.ModeState(bot)
			if modeState then
				item = BotService.FindBaseLoot(bot, root, modeState, center, circleRadius, now)
			end
		end
		-- Oliver 15:27: "bots dont open crates or supply drops". An armed bot now also opens the nearest
		-- unopened chest in range, not just a bot that is short of guns.
		if not item and not teamMode then
			local bestDistance = LOOT_SEEK_RANGE
			for _, entry in ipairs(lootItems(now)) do
				local chest = entry.item
				if chest.Name == "Chest" and chest.Parent and not chest:GetAttribute("Claimed") then
					local distance = (entry.position - root.Position).Magnitude
					if distance < bestDistance and lootAllowed(bot, chest, distance, center, circleRadius, now) then
						item, bestDistance = chest, distance
					end
				end
			end
		end
		-- Empty-handed with nothing inside that sweep: walk to the nearest gun ANYWHERE rather than
		-- wandering. A bot that lands in a corner of a 1280-stud map had nothing within 320 studs and
		-- milled about picking random wander goals until a fight found it; the pickups are already in
		-- the shared snapshot, so reaching further costs nothing but the walk.
		if not item and empty then
			item = findLoot(bot, root.Position, math.huge, false, center, circleRadius, now)
			if item then
				STATS.lootFarReach += 1
			end
		end
		-- Hurt and carrying nothing to fix it: a loose Bandage or Med Kit is worth a detour.
		local carryingHeals = bot.heals.Bandage + bot.heals.MedKit > 0
		if not item and not carryingHeals and humanoid.Health < humanoid.MaxHealth * MatchConfig.BotHealBelow then
			item = findLoot(bot, root.Position, HEAL_SEEK_RANGE, true, center, circleRadius, now)
		end
		if item then
			setLootTarget(bot, item)
		end
	end

	if bot.lootTarget then
		bot.branch = "loot"
		local item = bot.lootTarget
		local reach = (item.Position - root.Position).Magnitude
		-- In reach, and on this floor: not a chest on the storey above through the ceiling.
		if reach < 13 and math.abs(item.Position.Y - (root.Position.Y - 3)) < 7 then
			holdLoot(bot, humanoid, root, now)
			return
		end
		bot.lootHoldStart = nil
		setSprint(bot, empty and reach > 60)
		local result = navigate(bot, humanoid, root, item.Position, BotNav.Priority.Loot, now)
		-- Couldn't get there: routes keep failing, or the stuck ladder gave up. Leave it for a while.
		if result == "abandon" or bot.nav.failures >= 2 then
			bot.nav.failures = 0
			blacklistLoot(bot, item, 45, now)
		end
		return
	end

	-- Re-pick the long-range goal only when it has actually gone stale. This used to re-pick
	-- whenever the bot was outside the zone, which meant every tick while it was outside —
	-- a fresh target and a fresh repath each time, so it never made progress back in.
	-- With no storm running, IsOutside is true everywhere (its radius is 0), which re-picked the goal on
	-- every think.
	-- In a team mode the bot is FOR something: the hill, or its squad and the enemy. Without this,
	-- bots with no storm to run from and nothing to loot picked random points and circled.
	local modeState = BotService.ModeState(bot)
	local objective, objectiveKind = nil, nil
	if modeState then
		objective, objectiveKind = modeObjective(bot, root, modeState, now)
	end
	bot.objectiveKind = objectiveKind
	if objective then
		bot.branch = "objective"
		if objectiveKind == "sweep" and flatDistance(root.Position, objective) < 24 then
			bot.slot = math.random(0, 999)
		end
		if not bot.wanderGoal or flatDistance(bot.wanderGoal, objective) > 12 then
			bot.wanderGoal = objective
			bot.wanderAt = now
			bot.wanderTarget = nil
		end
		-- Holding the hill: stand on the ring, low, facing out. Pacing around it reads as aimless and
		-- walks bots off the zone. BOT ARCHETYPES: an Anchor fortifies it, a wall toward where the
		-- enemy was last seen (or toward the enemy's own objective when nobody has been seen yet).
		if objectiveKind == "hold" and flatDistance(root.Position, objective) < 6 then
			local sighting = bot.focusTeam and teamSightings[bot.focusTeam]
			local toward = sighting and now - sighting.at < 60 and sighting.position or nil
			if not toward and modeState.hill then
				local away = flat(root.Position - modeState.hill)
				toward = away.Magnitude > 1 and root.Position + away.Unit * 40 or nil
			end
			if toward and ARCH.tryBuildFortify(bot, humanoid, root, toward, now) then
				holdStill(bot, humanoid, root, now)
				facePoint(bot, humanoid, root, toward)
				return
			end
			setCrouch(bot, true)
			holdStill(bot, humanoid, root, now)
			return
		end
	end

	local goalStale = not bot.wanderGoal or (safeCircle() ~= nil and StormService.IsOutside(bot.wanderGoal))
		or not insideCircle(bot.wanderGoal, center, circleRadius, 0.85)
	local goalReached = bot.wanderGoal and flatDistance(root.Position, bot.wanderGoal) < 24

	if not objective and (goalStale or goalReached or now - bot.wanderAt > 30) then
		bot.wanderGoal = stormGoal(root.Position)
		bot.wanderAt = now
		bot.wanderTarget = nil
	end

	if not bot.wanderTarget or flatDistance(root.Position, bot.wanderTarget) < 16 then
		bot.wanderTarget = nextLeg(root.Position, bot.wanderGoal)
	end

	bot.branch = "wander"
	setSprint(bot, pressure >= MatchConfig.BotStormRotate)
	local result = navigate(bot, humanoid, root, bot.wanderTarget, pressure >= MatchConfig.BotStormRotate
		and BotNav.Priority.Urgent or BotNav.Priority.Wander, now)
	if result == "abandon" or bot.nav.failures >= 2 then
		-- That way doesn't go anywhere: try another heading.
		bot.nav.failures = 0
		bot.wanderGoal = nil
		bot.wanderTarget = nil
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function BotService.Count()
	local total = 0
	for _, bot in ipairs(bots) do
		if bot.character.Parent and bot.humanoid.Health > 0 then
			total += 1
		end
	end
	return total
end

function BotService.GetAll()
	return bots
end

-- Where a dropping bot steers for: the nearest of the map's towns and landmarks to where it
-- opened its canopy (the second nearest now and then), somewhere on its outskirts rather than
-- on the fountain — so fifty bots don't all land in one square.
local function pickDropTarget(targets, from)
	if not targets or #targets == 0 then
		return Vector3.new(from.X, 0, from.Z)
	end
	local ranked = {}
	for _, spot in ipairs(targets) do
		table.insert(ranked, { spot = spot, distance = (Vector3.new(spot.X, 0, spot.Z) - Vector3.new(from.X, 0, from.Z)).Magnitude })
	end
	table.sort(ranked, function(a, b)
		return a.distance < b.distance
	end)
	local pick = ranked[1]
	if #ranked > 1 and math.random() < 0.35 then
		pick = ranked[2]
	end
	local angle = math.random() * math.pi * 2
	local reach = 18 + math.random() * 22
	return Vector3.new(pick.spot.X + math.cos(angle) * reach, pick.spot.Y or 0, pick.spot.Z + math.sin(angle) * reach)
end

-- `options.dropIn` opens a canopy over each bot where it's spawned (high over its spot) and
-- glides it toward one of `options.dropTargets`, the way players drop in.
function BotService.Spawn(count, cframeFor, onSpawned, options)
	if count <= 0 then
		return {}
	end
	options = options or {}

	-- Captured before ensureTemplate: the first rig is a web call, and a match can end while
	-- it's in flight. Without this, spawning carried on afterwards and dropped live bots
	-- into a finished match.
	local generation = spawnGeneration

	local rig = ensureTemplate()
	if not rig or generation ~= spawnGeneration then
		return {}
	end

	local names = shuffled(BOT_NAMES)
	local spawned = {}
	-- BOT ARCHETYPES: one deck for the batch holds the mode's mix exactly; a bot dealt singly (a
	-- replacement) takes the top card of a one-card deck and is rebalanced against its team on its
	-- first think (ARCH.balance).
	local deck = ARCH.deck(count, ARCH.Mix[ARCH.modeIdNow()] or ARCH.Mix.BattleRoyale)

	for index = 1, count do
		local character = rig:Clone()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			local name = names[((index - 1) % #names) + 1]
			if index > #names then
				name = name .. index
			end

			-- Rolled but NOT handed over: bots drop in empty-handed like players and have to find
			-- a gun on the map. `spawnWeapon` keeps the roll for reference only; nothing grants it.
			local weapon = rollWeapon()

			character.Name = name
			humanoid.DisplayName = name
			humanoid.MaxHealth = MatchConfig.BotHealth
			-- Bots drop in with no shield, like players; potions from chests fill it.
			humanoid:SetAttribute("Shield", 0)
			humanoid.Health = MatchConfig.BotHealth
			-- The body stays in one piece at death for DeathFxService to ragdoll, burn or float.
			humanoid.BreakJointsOnDeath = false
			humanoid.RequiresNeck = false
			-- A bot that jumps at a wall trips into FallingDown, and Parkour.Find refuses to climb from
			-- that state: it was the reason every mid-jump climb of a 9-stud wall was turned down
			-- ("state FallingDown", measured). Nothing else in the game wants a bot sprawling either,
			-- so the trip states are off; death still ragdolls through DeathFxService.
			pcall(function()
				humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			end)

			local bot = {
				isBot = true,
				name = name,
				character = character,
				humanoid = humanoid,
				weapon = nil,
				loadoutWeapon = false, -- true once SpawnLoadout hands over a gun: sufficient at any rarity
				spawnWeapon = weapon,
				nextShotAt = os.clock() + math.random() * 1.5,
				burstLeft = 0,
				acquiredAt = 0,
				strafeDir = math.random() < 0.5 and 1 or -1,
				strafeFlipAt = os.clock() + math.random() * 2,
				wanderTarget = nil,
				wanderAt = 0,
				wanderGoal = nil,
				lootTarget = nil,
				lootCheckedAt = 0,
				lootHoldStart = nil,
				lootBlacklist = {},
				lastCombatAt = 0,
				lastHealth = MatchConfig.BotHealth,
				tracks = nil,
				currentTrack = nil,
				facing = nil,
				heals = { Bandage = math.random(0, MatchConfig.BotStartBandages), MedKit = 0 },
				shields = { MiniShield = 0, ShieldPotion = 0 },
				lastHealAt = 0,
				defenses = 0,
				lastBuildAt = 0,
				angleCheckAt = 0,
				anchor = nil,
				lastHurtAt = 0,
				coverUntil = 0,
				coverPoint = nil,
				lastCoverSearchAt = 0,
				rockets = 0,
				lastRocketAt = 0,
				throwables = {},
				ownStructures = {},
				slot = nextSlot,
				objectiveKind = nil,
				escapeScanAt = 0,
				coverBlockedUntil = 0,
				throwReadyAt = {},
				-- Perception
				target = nil,
				sight = {},
				seen = {},
				memory = nil,
				searchUntil = nil,
				threat = nil,
				pruneAt = 0,
				-- Combat
				combatMove = nil,
				badMove = nil,
				mag = nil,
				magWeapon = nil,
				reloadUntil = nil,
				sprinting = false,
				crouching = false,
				nextSlideAt = 0,
				-- BOT ARCHETYPES (dealt below): the personality, and its dials merged with the gun held
				archetype = nil,
				dials = nil,
				archetypeBalancedFor = nil,
				coverRoll = nil, -- rolled per fight against coverUse / buildRate
				buildRoll = nil,
				flankDir = 1,
				shotsFromSpot = 0, -- shots since the last deliberate reposition (the class's repositionAfterShots)
				relocateUntil = nil,
				peek = nil, -- the peek cycle's phase row (peekPhase)
				coverAt = nil, -- the cover spot the bot last reached, to peek from and step back to
				thirdPartyFrom = nil,
				focusTeam = nil,
				fightState = nil, -- what fight() decided this think: engage/strafe/open/cover/peekHide/peekShoot/push/retreat/thirdParty
			}
			nextSlot += 1
			BotNav.Attach(bot)
			BotService.AssignArchetype(bot, deck[index] or ARCH.Order[math.random(1, #ARCH.Order)])

			-- Everything that doesn't need the rig in the world is set up before parenting, so the
			-- bot replicates once, fully built, already at its spawn point. Parenting first sent
			-- the gun, nameplate and facing controller as separate steps for all 29 bots — and
			-- briefly placed every bot at the template's position before teleporting it.
			paintBot(character)
			character:PivotTo(cframeFor(index))
			-- About a third wear a title, like players who've earned one.
			local botTitle = nil
			if math.random() < 0.35 then
				local pool = AchievementData.List
				botTitle = pool[math.random(1, #pool)].title
			end
			NameplateService.Attach(character, name, true, nil, botTitle)

			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				local attachment = Instance.new("Attachment")
				attachment.Name = "FacingAttachment"
				attachment.Parent = root

				local align = Instance.new("AlignOrientation")
				align.Name = "Facing"
				align.Mode = Enum.OrientationAlignmentMode.OneAttachment
				align.Attachment0 = attachment
				align.MaxTorque = 1e6
				align.Responsiveness = 18
				align.Enabled = false
				align.Parent = root

				bot.facing = align
			end

			character.Parent = workspace
			claimPhysics(character)

			-- Must come after parenting: Animator:LoadAnimation needs the rig in the DataModel.
			-- setupAnimations pcalls each load, so running it early would fail silently and the
			-- bots would slide instead of walk.
			setupAnimations(bot, humanoid)

			Combatants.Register(character, bot)

			-- A game mode may hand a bot its gun instead of making it loot for one.
			if BotService.SpawnLoadout then
				local okLoadout, granted, items = pcall(BotService.SpawnLoadout, bot, humanoid)
				local def = okLoadout and granted or nil
				if type(def) == "string" then
					def = WeaponData.Get(def)
				end
				if type(def) == "table" and def.id then
					bot.weapon = def
					bot.loadoutWeapon = true
					bot.magWeapon = def.id
					bot.mag = magazineOf(def)
					giveBotGun(character, def)
				end
				if okLoadout and type(items) == "table" then
					for _, entry in ipairs(items) do
						local id = type(entry) == "table" and entry.id or entry
						local count = (type(entry) == "table" and tonumber(entry.count)) or 1
						if type(id) == "string" and count > 0 then
							if WeaponService.Heals[id] then
								giveBotHeal(bot, id, count)
							elseif WeaponService.Shields[id] then
								giveBotShield(bot, id, count)
							elseif id == "RotBarricade" then
								giveBotDefense(bot, count)
							elseif id == "RotRocket" then
								giveBotRocket(bot, count)
							else
								for kind, spec in pairs(THROWABLES) do
									if spec.itemId == id then
										giveBotThrowable(bot, kind, count)
									end
								end
							end
						end
					end
				end
			end

			-- Speed is composed in MatchService.applySpeed (base × boost × sprint × slide), with the match
			-- event's multiplier on the base, so a Rot Rush speeds bots up too. A direct WalkSpeed write
			-- would be wiped by the next sprint or boost; it's only the fallback where that doesn't exist.
			local match = lazy("MatchService")
			if not (match and match.SetBaseSpeed and match.SetBaseSpeed(bot, MatchConfig.BotWalkSpeed)) then
				humanoid.WalkSpeed = MatchConfig.BotWalkSpeed
			end

			if options.dropIn then
				bot.dropping = true
				local target = pickDropTarget(options.dropTargets, character:GetPivot().Position)
				if not MovementService.BotDrop(character, target, function()
					bot.dropping = false
					-- The canopy came off, so the assembly changed; claim it again.
					claimPhysics(character)
				end) then
					bot.dropping = false
				end
			end

			if math.random() < BOT_COMPANION_CHANCE then
				local pool = BrainrotData.OfRarity(Rarity.Roll(BOT_COMPANION_ODDS))
				if #pool > 0 then
					CompanionService.AttachBot(bot, pool[math.random(1, #pool)])
				end
			end
			table.insert(bots, bot)
			table.insert(spawned, bot)

			if onSpawned then
				onSpawned(bot, humanoid)
			end
		end

		if index % 5 == 0 then
			task.wait()
			-- Clear() may have run during the yield; it already destroyed what exists.
			if generation ~= spawnGeneration then
				break
			end
		end
	end

	return spawned
end

-- LEVEL OF DETAIL. A bot no player is anywhere near is being simulated for the match's sake, not
-- for anyone to watch: it thinks every LodSkip-th turn instead of every turn, so at the drop (fifty
-- bots spread over the map, players in two or three places) a slice carries about half its thinks.
-- Never deferred: a bot that is fighting, fleeing, dodging or in the storm (its last branch), one
-- that has taken damage since it last thought, or one within LodDistance of a living player. Bot
-- fights far from players therefore run at full rate; only the walking and looting between them is
-- coarser. Time-based behaviour reads elapsed time (bot.thoughtAt), so regen and timers are
-- unchanged. tools/perf_bot_cost.py checks the far/idle period and that no fighting or hurt bot
-- is ever deferred; tools/perf_tick_probe.lua runs Studio with LodEnabled on and off.
BotService.LodEnabled = true
BotService.LodDistance = 300
BotService.LodSkip = 2
BotService.LodActiveBranches = { fight = true, flee = true, dodge = true, storm = true }

function BotService.LodDefers(bot, now)
	if not BotService.LodEnabled or BotService.LodSkip <= 1 then
		return false
	end
	if BotService.LodActiveBranches[bot.lastBranch] then
		return false
	end
	local humanoid = bot.humanoid
	if humanoid and humanoid.Health < bot.lastHealth then
		return false
	end
	if bot.threat and now - bot.threat.at < FLEE_WINDOW then
		return false
	end
	local root = bot.character and bot.character:FindFirstChild("HumanoidRootPart")
	if not root or BotService.SpatialQuery.NearestPlayerDistance(root.Position) <= BotService.LodDistance then
		return false
	end
	bot.lodTurn = (bot.lodTurn or 0) + 1
	if bot.lodTurn % BotService.LodSkip == 0 then
		STATS.lodThinks += 1
		return false
	end
	STATS.lodSkips += 1
	return true
end

-- Bots think every BotThinkInterval, but not all in the same frame: they are split into
-- THINK_SLICES groups that take turns, one group every BotThinkInterval / THINK_SLICES, so each bot
-- still thinks once an interval and the worst frame carries 1/THINK_SLICES of the bots. It was two
-- halves (#113/#126/#131): at 50 bots that put 25 thinks in one frame, now 13; at 30, 15 -> 8.
-- tools/perf_bot_cost.py runs this loop and counts thinks per frame; tools/perf_tick_probe.lua
-- measures the worst frame in Studio.
local THINK_SLICES = 4
BotService.ThinkSlices = THINK_SLICES

function BotService.Start()
	if running then
		return
	end
	running = true
	loopGeneration += 1
	local generation = loopGeneration

	task.spawn(function()
		local slice = 0
		while running and generation == loopGeneration do
			task.wait(MatchConfig.BotThinkInterval / THINK_SLICES)
			if not running or generation ~= loopGeneration then
				break
			end
			local started = os.clock()
			local startedWall = tick()
			BotNav.Pump()
			-- Also opens the frame's ray budget: every ray this slice casts is counted against it.
			refreshCombatants()
			local updated = 0
			for index, bot in ipairs(bots) do
				if index % THINK_SLICES == slice and not BotService.LodDefers(bot, started) then
					updated += 1
					bot.branch = "idle"
					local began = os.clock()
					local ok, err = pcall(updateBot, bot)
					if not ok then
						warn("[BotService] Bot update failed: " .. tostring(err))
					end
					bot.lastBranch = bot.branch
					bot.thoughtAt = began
					-- Where the think time goes, for tools/bot_probe.lua; the slowest single think and
					-- its branch, for tools/perf_tick_probe.lua (the 42.6 ms tick is still unexplained).
					local took = os.clock() - began
					local key = "time_" .. bot.branch
					STATS[key] = (STATS[key] or 0) + took
					if took > STATS.maxBotUpdate then
						STATS.maxBotUpdate = took
						-- Not in STATS: bot_probe subtracts every STATS value, so it holds numbers only.
						BotService.MaxBotBranch = bot.branch
					end
				end
			end
			slice = (slice + 1) % THINK_SLICES
			local spent = os.clock() - started
			STATS.thinkTime += spent
			STATS.thinkTicks += 1
			STATS.updates += updated
			STATS.maxTick = math.max(STATS.maxTick, spent)
			-- os.clock() is CPU time in Roblox (COORDINATION.md); the wall-clock figure beside it says
			-- whether a long tick was work or a yield inside a think.
			STATS.maxTickWall = math.max(STATS.maxTickWall, tick() - startedWall)
		end
	end)
end

function BotService.Clear()
	running = false
	loopGeneration += 1
	spawnGeneration += 1
	nextSlot = 0

	for _, bot in ipairs(bots) do
		BotNav.Drop(bot)
		-- Teardown must finish even if the sprint or crouch hand-off errors.
		pcall(setSprint, bot, false)
		pcall(setCrouch, bot, false)
		Combatants.Unregister(bot.character)
		CombatService.ForgetToken(bot)
		if bot.character.Parent then
			bot.character:Destroy()
		end
	end

	BotNav.Clear()
	table.clear(lootClaims)
	table.clear(teamSightings)
	table.clear(teamFocus)
	BotService.SpatialQuery.Clear()
	table.clear(riders)
	lootSnapshot.at = -math.huge
	table.clear(bots)
end

return BotService
