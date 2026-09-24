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

local function hostile(bot, token)
	local hook = BotService.IsHostile
	if not hook then
		return true
	end
	local ok, result = pcall(hook, bot, token)
	if not ok then
		return true
	end
	return result ~= false
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

local function hasLineOfSight(fromPart, toCharacter, botCharacter)
	local toPart = toCharacter:FindFirstChild("HumanoidRootPart")
	if not toPart then
		return false
	end

	-- A smoke cloud hides whoever is behind it (ProjectileService).
	if CombatService.SmokeBlocks and CombatService.SmokeBlocks(fromPart.Position, toPart.Position) then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Terrain water is not cover: a raycast hits it unless told not to, so a bot would refuse to
	-- shoot across a river at a target a player could hit — the shot itself ignores water
	-- (CombatService.buildRaycastParams), as does the client's own trace.
	params.IgnoreWater = true
	local filter = { botCharacter }
	for _, name in ipairs({ "Loot", "Effects", "Companions" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter

	-- Window glass is see-through, and a shot breaks it on the way (CombatService), so a pane
	-- in the way is looked past rather than counted as cover. A few panes at most in one line.
	local result
	for _ = 1, 4 do
		result = workspace:Raycast(fromPart.Position, toPart.Position - fromPart.Position, params)
		if not (result and CombatService.DestructiblePassesThrough and CombatService.DestructiblePassesThrough(result.Instance)) then
			break
		end
		table.insert(filter, result.Instance)
		params.FilterDescendantsInstances = filter
	end
	return result ~= nil and result.Instance:IsDescendantOf(toCharacter)
end

-- The living combatants, looked up once per think tick for every bot to share: token, character, root,
-- humanoid and the root's position at the time. Positions are at most one think slice old
-- (BotThinkInterval / THINK_SLICES); line of sight always uses the live root.
local combatantList = {}

local function refreshCombatants()
	table.clear(combatantList)
	for character, token in pairs(Combatants.All()) do
		if character.Parent then
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = root and character:FindFirstChildOfClass("Humanoid")
			if humanoid and humanoid.Health > 0 then
				table.insert(combatantList, {
					token = token, character = character, root = root, humanoid = humanoid, position = root.Position,
				})
			end
		end
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
	local visible = hasLineOfSight(head, character, bot.character)
	entry = { at = now, visible = visible }
	bot.sight[token] = entry
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
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	-- Companions hover beside their owners and take raycasts; they aren't cover.
	params.FilterDescendantsInstances = { bot.character, workspace:FindFirstChild("Companions") }
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local hit = workspace:Raycast(head.Position, targetRoot.Position - head.Position, params)
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

-- The best target this bot can see and has noticed, or nil. Candidates are scored before any ray:
-- nearest first, players pulled closer by BotPlayerBias, whoever just shot us far closer, the current
-- target a little closer (so a bot doesn't flick between two), and the badly hurt a little closer.
--
-- The old version picked the nearest combatant and only then asked whether it was visible — so a bot
-- with an enemy hiding behind a wall 40 studs away ignored the one shooting it from 100.
local function findTarget(bot, root, head, now)
	local threat = now - bot.lastHurtAt < THREAT_WINDOW and CombatService.GetLastAttacker(bot) or nil
	local reach = math.max(MatchConfig.BotVisionRange, bot.weapon and bot.weapon.range or 0)
	local candidates = {}

	local position = root.Position
	for _, entry in ipairs(combatantList) do
		local token = entry.token
		if token ~= bot and entry.humanoid.Health > 0 and hostile(bot, token) then
			local distance = (entry.position - position).Magnitude
			-- Past vision range only whoever is shooting us, and only as far as our gun reaches.
			if distance <= MatchConfig.BotVisionRange or (token == threat and distance <= reach) then
				local humanoid = entry.humanoid
				local score = distance
				if Combatants.IsPlayer(token) then
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
				table.insert(candidates, { token = token, character = entry.character, root = entry.root, distance = distance, score = score })
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	table.sort(candidates, function(a, b)
		return a.score < b.score
	end)

	local look = flatLook(root)
	local fresh = 0
	for index, candidate in ipairs(candidates) do
		local visible, computed, entry = sightOf(bot, head, candidate.token, candidate.character, now, index == 1)
		if computed then
			fresh += 1
		end
		if not visible and candidate.distance <= 120 then
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
local function exposedTo(bot, root, from)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { bot.character }
	for _, name in ipairs({ "Loot", "Effects", "Companions" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter
	params.RespectCanCollide = true
	-- Water hides nobody. IgnoreWater defaults to false, which counted the river as cover: a bot
	-- standing in it read as hidden, so it wouldn't put a barricade up or break off while in plain
	-- sight. Every other sight line in the project ignores water (CombatService, hasLineOfSight).
	params.IgnoreWater = true
	local eye = root.Position + Vector3.new(0, 1.5, 0)
	local hit = workspace:Raycast(from, eye - from, params)
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

local function reportSighting(bot, position, now)
	local state = BotService.ModeState(bot)
	if state and state.team then
		teamSightings[state.team] = { position = position, at = now }
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
	for _, entry in ipairs(combatantList) do
		if entry.token ~= bot and entry.humanoid.Health > 0 and (entry.position - root.Position).Magnitude <= RALLY_RANGE
			and not hostile(bot, entry.token) then
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
			return state.hill + ring, "hold"
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
	BotNav.Follow(bot, humanoid, root, goal, now)
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

	-- Burst discipline: a handful of shots at the weapon's rate, then a rest.
	if bot.burstLeft <= 0 then
		bot.burstLeft = math.random(2, 5)
		bot.nextShotAt = now + MatchConfig.BotBurstRest + math.random() * 0.35
		return
	end

	bot.burstLeft -= 1
	bot.nextShotAt = now + (1 / def.fireRate)
	if size then
		bot.mag -= 1
	end

	if projectiles then
		local aim = projectiles.LeadAim
			and projectiles.LeadAim(def.id, head.Position, targetRoot.Position, targetRoot.AssemblyLinearVelocity)
			or targetRoot.Position
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
	local reach = bot.weapon and bot.weapon.range or MatchConfig.BotEngagePreferred
	local preferred = math.min(MatchConfig.BotEngagePreferred, reach * 0.6)
	-- Closing in on a target that's nearly dead (set in fight()).
	if bot.pushing and not retreating then
		preferred *= 0.5
	end
	-- A launcher wants room between itself and its own blast.
	if bot.weapon and bot.weapon.projectile then
		preferred = math.max(preferred, 30)
	end
	local dangers = dangersNear(root.Position, 40)
	local toThreat = flat(threatPosition - root.Position)
	local forward = toThreat.Magnitude > 0.5 and toThreat.Unit or flatLook(root)
	local right = Vector3.new(-forward.Z, 0, forward.X)
	local reloading = bot.reloadUntil ~= nil

	local options = {
		{ offset = Vector3.zero, hold = true },
		{ offset = right * 12, side = 1 },
		{ offset = -right * 12, side = -1 },
		{ offset = right * 22, side = 1 },
		{ offset = -right * 22, side = -1 },
		{ offset = forward * 18 + right * 8, side = 1 },
		{ offset = forward * 18 - right * 8, side = -1 },
		{ offset = -forward * 18 + right * 10, side = 1 },
		{ offset = -forward * 18 - right * 10, side = -1 },
	}
	for _, option in ipairs(options) do
		local point = root.Position + option.offset
		local range = flatDistance(point, threatPosition)
		local score
		if retreating then
			score = -range / 25
		else
			score = math.abs(range - preferred) / math.max(preferred, 1) * 3
			if reloading then
				score -= range / 60
			end
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
	table.sort(options, function(a, b)
		return a.score < b.score
	end)

	local params = BotNav.StepParams(bot.character)
	local checked = 0
	for _, option in ipairs(options) do
		if option.hold then
			return root.Position, true
		end
		if stormAllows(root.Position, option.point) then
			checked += 1
			if BotNav.CanStep(root, bot.character, option.point, params) then
				return option.point, false
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
		local point, hold = planCombatMove(bot, root, threatPosition, distance, retreating, now)
		move = {
			point = point,
			hold = hold,
			retreating = retreating,
			startedAt = now,
			startPosition = root.Position,
			untilTime = now + COMBAT_REPLAN + math.random() * 0.3,
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
	local point, direct = BotNav.FindCover(root, bot.character, threatEye, { 10, 18, 28 }, function(candidate)
		return stormAllows(from, candidate)
	end, threatCharacter)
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
	local params = BotNav.StepParams(bot.character)
	local across = Vector3.new(-facing.Z, 0, facing.X)
	local left = workspace:Raycast(centre, across * 7, params)
	local right = workspace:Raycast(centre, -across * 7, params)
	return left ~= nil and right ~= nil
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
	if reason == "angle" then
		STATS.buildsAngle += 1
		bot.anchor = { position = root.Position, untilTime = now + BOT_ANGLE_TIME }
	else
		if reason == "heal" then
			STATS.buildsHeal += 1
		else
			STATS.buildsExposed += 1
		end
		bot.coverUntil = now + BOT_COVER_TIME
		-- Out of sight now: patch up straight away rather than after the usual lull.
		bot.lastCombatAt = now - MatchConfig.BotHealLull
	end
	return true
end

local function canBuild(bot, now)
	return bot.defenses > 0 and now - bot.lastBuildAt >= BOT_BUILD_COOLDOWN
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
	local reach = bot.weapon and bot.weapon.range or MatchConfig.BotEngagePreferred
	local preferred = math.min(MatchConfig.BotEngagePreferred, reach * 0.6)
	if distance < math.max(BOT_BUILD_MIN, preferred * 1.1) or distance > BOT_BUILD_MAX then
		return false
	end
	if humanoid.Health < humanoid.MaxHealth * 0.7 then
		return false
	end
	local closing = flat(targetRoot.AssemblyLinearVelocity):Dot(flat(root.Position - targetRoot.Position).Unit)
	if closing > 6 or math.random() > BOT_ANGLE_CHANCE then
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
	if missing <= 0 or humanoid.Health > humanoid.MaxHealth * MatchConfig.BotHealBelow then
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
	local params = BotNav.StepParams(bot.character)
	-- A throw arcs over water perfectly well; only solid things stop it.
	params.IgnoreWater = true
	local apex = head.Position + Vector3.new(0, 10, 0)
	if workspace:Raycast(head.Position, apex - head.Position, params) then
		return false
	end
	local above = point + Vector3.new(0, 10, 0)
	return workspace:Raycast(apex, above - apex, params) == nil
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
	end
	if kind == "grenade" and not lobClear(bot, head, point) then
		return false
	end
	bot.throwReadyAt[kind] = now + spec.cooldown
	-- A little cook on a frag, never much: flight time is estimated the way DefenseService.throwKit
	-- times a lob, and at most 40% of what's left is burned, so there's still a moment to run.
	local options = nil
	if kind == "grenade" and info and info.fuse then
		local flight = math.clamp(distance / 40, 0.5, 1.6)
		options = { cook = math.max(0, info.fuse - flight - 0.3) * 0.4 * math.random() }
	end
	local ok = api.Throw(bot, spec.itemId, point, options)
	if ok then
		bot.throwables[spec.itemId] -= 1
		if kind == "grenade" then
			STATS.throwsGrenade += 1
		else
			STATS.throwsSmoke += 1
		end
	end
	return ok == true
end

-- A grenade is worth it at two or more enemies bunched together round the target.
local function clusterAround(bot, targetRoot)
	local count, sum = 0, Vector3.zero
	local at = targetRoot.Position
	for _, entry in ipairs(combatantList) do
		if entry.token ~= bot and entry.humanoid.Health > 0 and (entry.position - at).Magnitude <= 10 then
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
local LOOT_SNAPSHOT_SECONDS = 1
local lootSnapshot = { at = -math.huge, items = {} }

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
	return items
end

local function findLoot(bot, position, radius, heals, center, circleRadius, now)
	local best, bestDistance = nil, radius
	local wantedKind = heals and "heal" or "gear"
	for _, entry in ipairs(lootItems(now)) do
		if entry.kind == wantedKind then
			local distance = (entry.position - position).Magnitude
			if distance < bestDistance then
				local item = entry.item
				if item.Parent and not item:GetAttribute("Claimed") and (not heals or item:GetAttribute("HealId") ~= nil)
					and lootAllowed(bot, item, distance, center, circleRadius, now) then
					best, bestDistance = item, distance
				end
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
	bot.target = target
	bot.lastCombatAt = now
	-- Fighting interrupts a loot hold. Without resetting it, a bot pulled into combat mid-hold
	-- would return with the time already "elapsed" and claim instantly.
	bot.lootHoldStart = nil
	bot.searchUntil = nil
	remember(bot, target, targetRoot.Position, root, now)
	reportSighting(bot, targetRoot.Position, now)
	if bot.acquiredAt == 0 then
		bot.acquiredAt = now
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

	-- Losing badly and the shooter's close: leave by air, or smoke it and back off to cover,
	-- facing the target so the retreat reads as backpedalling under fire.
	if humanoid.Health <= MatchConfig.BotRetreatHealth and distance < 90 then
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
		local position = root.Position
		for _, entry in ipairs(combatantList) do
			if entry.token ~= bot and entry.humanoid.Health > 0 and hostile(bot, entry.token)
				and (entry.position - position).Magnitude < 70 then
				outnumbered += 1
			end
		end
	end
	local targetHumanoid = candidate.character and candidate.character:FindFirstChildOfClass("Humanoid")
	bot.pushing = targetHumanoid ~= nil and targetHumanoid.Health < targetHumanoid.MaxHealth * MatchConfig.BotPushTargetBelow
		and humanoid.Health > humanoid.MaxHealth * MatchConfig.BotPushHealthAbove and not bot.reloadUntil
	local wantsCover = (humanoid.Health <= humanoid.MaxHealth * MatchConfig.BotCoverHealth and now - bot.lastHurtAt < 2)
		or (bot.reloadUntil ~= nil and distance < 100)
		or outnumbered >= 2

	-- Hurt and being hit, reloading, or outnumbered: get behind something, or put something up.
	if wantsCover and not bot.pushing then
		local cover, direct = seekCover(bot, root, eye, now, candidate.character)
		if cover and goToCover(bot, humanoid, root, cover, direct, now) then
			setCrouch(bot, false)
			faceTarget(bot, humanoid, root, targetRoot)
			if reacted then
				shootAt(bot, target, targetRoot, distance, head)
			end
			if flatDistance(root.Position, cover) < 3 then
				STATS.coverReached += 1
				bot.coverPoint = nil
				bot.coverUntil = now + BOT_COVER_TIME
				bot.lastCombatAt = now - MatchConfig.BotHealLull
			end
			return
		end
		if tryBuildExposed(bot, humanoid, root, targetRoot, distance, now) then
			holdStill(bot, humanoid, root, now)
			faceTarget(bot, humanoid, root, targetRoot)
			return
		end
	end

	if tryBuildAngle(bot, humanoid, root, targetRoot, distance, now) then
		holdStill(bot, humanoid, root, now)
		faceTarget(bot, humanoid, root, targetRoot)
		return
	end

	-- Two or more of them bunched up: a grenade in the middle.
	local bunched, centre = clusterAround(bot, targetRoot)
	if bunched >= 2 and centre then
		tryThrow(bot, root, head, "grenade", centre, now)
	end

	-- Brief reaction delay before the first shot of an engagement — turn toward them
	-- during it rather than freezing in place facing the wrong way.
	if now - bot.acquiredAt < MatchConfig.BotReactionTime then
		holdStill(bot, humanoid, root, now)
		faceTarget(bot, humanoid, root, targetRoot)
		quickFirstShot(bot, candidate, head, now)
		return
	end

	local point = combatMove(bot, root, targetRoot.Position, distance, false, now)
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
-- BOT VEHICLES (armed vehicles: VehicleWeapons, Shared/VehicleWeaponData)
--------------------------------------------------------------------------------
-- Bots never drove. Now a few may: a bot already in a fight that finds an empty armed vehicle close
-- by walks to it and gets in, then drives at its target (circling once it is close) and fires the
-- mount through VehicleWeapons.Fire, the very function a player's trigger reaches, with the same
-- driver, rate, ammo and team checks. The target is findTarget's, so line of sight is the one
-- every bot already uses. While a bot drives, updateBot stops at the hook; once it gets out (nobody to
-- shoot for a while, or the vehicle wrecked) it carries on as a bot on foot. The server steps a
-- vehicle with no player at the wheel from its seat's ThrottleFloat/SteerFloat (VehicleService.step).

local BOT_DRIVERS_MAX = 3        -- bots behind a wheel at once, across the match
local BOT_BOARD_SEEK = 45        -- an armed vehicle this close may be taken
local BOT_BOARD_CHANCE = 0.35    -- chance, every BOT_BOARD_EVERY seconds of a fight, that a bot looks
local BOT_BOARD_EVERY = 3
local BOT_BOARD_WALK = 7         -- seconds walking to the vehicle before giving up on it
local BOT_DRIVE_IDLE = 10        -- seconds with nobody to shoot before getting out
local BOT_DRIVE_CIRCLE = 45      -- closer than this, circle the target rather than drive at it
local BOT_STEER_FULL = math.rad(35)

-- Bot record -> true while it drives. STRONG keys; pruned by botDriverCount as bots get out or die.
local botDrivers = {}

local function botDriverCount()
	local count = 0
	for driver in pairs(botDrivers) do
		local humanoid = driver.humanoid
		if humanoid and humanoid.Health > 0 and humanoid.SeatPart then
			count += 1
		else
			botDrivers[driver] = nil
		end
	end
	return count
end

local function leaveVehicle(bot, humanoid, seat)
	if seat:IsA("VehicleSeat") then
		seat.ThrottleFloat = 0
		seat.SteerFloat = 0
	end
	humanoid.Sit = false
	botDrivers[bot] = nil
end

-- Returns true when this think was spent in (or getting into) an armed vehicle.
local function botVehicleThink(bot, humanoid, root, head, now)
	local VehicleWeapons = lazy("VehicleWeapons")
	if not VehicleWeapons then
		return false
	end
	local seat = humanoid.SeatPart
	if seat then
		local vehicle = VehicleWeapons.DrivenBy(bot)
		if not vehicle or vehicle:GetAttribute("Wrecked") or not vehicle.PrimaryPart then
			leaveVehicle(bot, humanoid, seat)
			return false
		end
		botDrivers[bot] = true
		local candidate = findTarget(bot, root, head, now)
		if candidate then
			bot.driveSeenAt = now
			bot.driveGoal = nil
			VehicleWeapons.Fire(bot, candidate.root.Position)
		elseif now - (bot.driveSeenAt or now) > BOT_DRIVE_IDLE then
			leaveVehicle(bot, humanoid, seat)
			return false
		end
		local chassis = vehicle.PrimaryPart
		local goal = candidate and candidate.root.Position or bot.driveGoal
		if not goal or flatDistance(goal, chassis.Position) < 20 then
			goal = stormGoal(chassis.Position)
			bot.driveGoal = goal
		end
		local localGoal = chassis.CFrame:PointToObjectSpace(goal)
		local distance = math.sqrt(localGoal.X * localGoal.X + localGoal.Z * localGoal.Z)
		-- Positive is to the left, as the mount's yaw.
		local heading = math.atan2(-localGoal.X, -localGoal.Z)
		if candidate and distance < BOT_DRIVE_CIRCLE then
			-- Keep them off to one side and keep moving: a parked car is the easiest thing to hit.
			heading -= bot.strafeDir * math.rad(80)
		end
		local throttle = distance < 15 and 0.4 or 1
		local steer = math.clamp(-heading / BOT_STEER_FULL, -1, 1)
		if math.abs(heading) > math.rad(125) and not candidate then
			-- Behind: back round rather than drive a wide loop.
			throttle, steer = -0.6, -steer
		end
		seat.ThrottleFloat = throttle
		seat.SteerFloat = steer
		return true
	end

	botDrivers[bot] = nil
	local boarding = bot.boarding
	if boarding then
		if now > boarding.giveUpAt or boarding.seat.Occupant or not boarding.seat:IsDescendantOf(workspace) then
			bot.boarding = nil
			return false
		end
		if VehicleWeapons.BotBoard(humanoid, boarding.seat) then
			bot.boarding = nil
			bot.driveSeenAt = now
			botDrivers[bot] = true
			return true
		end
		humanoid:MoveTo(boarding.seat.Position)
		return true
	end

	-- Only in a fight, only now and then, and only while there's room behind a wheel.
	local fighting = bot.target ~= nil or (bot.threat ~= nil and now - bot.threat.at < FLEE_WINDOW)
	if not fighting or now < (bot.boardCheckAt or 0) then
		return false
	end
	bot.boardCheckAt = now + BOT_BOARD_EVERY
	if math.random() > BOT_BOARD_CHANCE or botDriverCount() >= BOT_DRIVERS_MAX then
		return false
	end
	local _, freeSeat = VehicleWeapons.FreeArmedNear(root.Position, BOT_BOARD_SEEK)
	if not freeSeat then
		return false
	end
	bot.boarding = { seat = freeSeat, giveUpAt = now + BOT_BOARD_WALK }
	humanoid:MoveTo(freeSeat.Position)
	return true
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

	-- BOT VEHICLES (section above): at the wheel of an armed vehicle, or walking to one.
	if botVehicleThink(bot, humanoid, root, head, now) then
		return
	end

	-- Slow out-of-combat regen: the fallback for a bot with no heal items left.
	if humanoid.Health < humanoid.MaxHealth and now - bot.lastCombatAt > MatchConfig.BotRegenDelay then
		humanoid.Health = math.min(
			humanoid.MaxHealth,
			humanoid.Health + MatchConfig.BotRegenPerSecond * MatchConfig.BotThinkInterval
		)
	end

	if now >= bot.strafeFlipAt then
		bot.strafeDir = -bot.strafeDir
		bot.strafeFlipAt = now + 0.9 + math.random() * 1.3
	end

	forgetStale(bot, now)
	finishReload(bot, now)
	local pressure = stormPressure(root.Position)

	-- Nothing to shoot with means nothing counts as a target: an unarmed bot falls through to
	-- looting (or running) instead of squaring up to someone empty-handed.
	local candidate = bot.weapon and findTarget(bot, root, head, now) or nil
	if candidate and candidate.distance > bot.weapon.range then
		-- Seen but out of reach: close in on where they are rather than plinking at nothing.
		remember(bot, candidate.token, candidate.root.Position, root, now)
		candidate = nil
	end
	if candidate then
		bot.branch = "fight"
		fight(bot, humanoid, root, head, candidate, pressure, now)
		return
	end

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
		local grenadeReady = now - memory.at < 4
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
		if not mark or flatDistance(root.Position, mark.position) > 6 or bot.lootHoldStart then
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
		-- walks bots off the zone.
		if objectiveKind == "hold" and flatDistance(root.Position, objective) < 6 then
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
			}
			nextSlot += 1
			BotNav.Attach(bot)

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
			refreshCombatants()
			local updated = 0
			for index, bot in ipairs(bots) do
				if index % THINK_SLICES == slice then
					updated += 1
					bot.branch = "idle"
					local began = os.clock()
					local ok, err = pcall(updateBot, bot)
					if not ok then
						warn("[BotService] Bot update failed: " .. tostring(err))
					end
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
	table.clear(combatantList)
	table.clear(botDrivers)
	lootSnapshot.at = -math.huge
	table.clear(bots)
end

return BotService
