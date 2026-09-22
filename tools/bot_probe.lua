-- Bot behaviour and server-cost probe.
--
-- Run with: runtest.ps1 -Probe tools/bot_probe.lua -WaitSeconds 600 [-MapId is ignored; see MAP_ID]
--
-- Bots need physics, and a -Probe run is in edit mode, so this switches the snapshot into Run mode
-- itself (the same call the full harness makes) and then works in two parts:
--
--   1. SCENARIOS on platforms high over the void, far outside the map, one behaviour each, so a
--      result can't be explained away by whatever else happened to be nearby.
--   2. FREE ROAM: 40 bots dropped around the map's towns and landmarks with the map's loot and a
--      storm running at 3x, sampled every half second.
--
-- Everything prints as [BRR_Bots] lines. The same probe measures the old and new BotService, so
-- every number is a before/after pair. Only living bots are ever counted, and BotService.Start()
-- runs after every bot is placed (both lessons from memory).
--
-- `BotService.Stats` is read when present (think-tick time, path requests, fallbacks, hops); a
-- BotService without it still gets every behavioural number.

local MAP_ID = "SahurSprings"
local FREE_ROAM_BOTS = 40
local FREE_ROAM_SECONDS = 150
local STORM_SPEED = 3

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_Bots] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end

local MapGenerator = mod("MapGenerator")
local LootService = mod("LootService")
local CombatService = mod("CombatService")
local StormService = mod("StormService")
local Combatants = mod("Combatants")
-- Requiring it wires the glass hooks into CombatService, as Bootstrap's copy does in a real server.
mod("DestructibleService")
local BotService = mod("BotService")
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

--------------------------------------------------------------------------------
-- Shot and damage taps
--------------------------------------------------------------------------------

local shotsBy = {}
local lastShotAt = {}
local shotEnds = {}
local realBroadcast = CombatService.BroadcastShot
local shotsMidParkour = 0
CombatService.BroadcastShot = function(shooter, origin, endPoints, rarity)
	shotsBy[shooter] = (shotsBy[shooter] or 0) + 1
	-- Bots stop steering (and shooting) while MovementService runs a climb or vault.
	local shooterCharacter = type(shooter) == "table" and shooter.character
	if shooterCharacter and shooterCharacter:GetAttribute("Parkour") then
		shotsMidParkour += 1
	end
	lastShotAt[shooter] = os.clock()
	local list = shotEnds[shooter]
	if not list then
		list = {}
		shotEnds[shooter] = list
	end
	table.insert(list, endPoints and endPoints[1])
	return realBroadcast(shooter, origin, endPoints, rarity)
end

local dealtBy = {}
local hitsBy = {}
local lastHitAt = {}
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	local dealt = realDeal(attacker, victim, amount, weaponId, headshot)
	if victim and (dealt or 0) > 0 then
		lastHitAt[victim] = os.clock()
		if attacker then
			hitsBy[attacker] = hitsBy[attacker] or {}
			hitsBy[attacker][victim] = (hitsBy[attacker][victim] or 0) + 1
		end
	end
	if attacker then
		local row = dealtBy[attacker]
		if not row then
			row = {}
			dealtBy[attacker] = row
		end
		row[victim] = (row[victim] or 0) + (dealt or 0)
	end
	return dealt
end

-- Damage from a pretend shooter: through the untapped function so it doesn't count as bot damage.
local function hurt(attacker, victim, amount)
	return realDeal(attacker, victim, amount, "SahurPistol", false)
end

local function statsSnapshot()
	local stats = BotService.Stats
	if not stats then
		return nil
	end
	return table.clone(stats)
end

local function statsDelta(before, after, seconds, label)
	if not (before and after) then
		say("%s cost: BotService.Stats not available", label)
		return
	end
	local d = {}
	for key, value in pairs(after) do
		d[key] = value - (before[key] or 0)
	end
	local updates = math.max(1, d.updates)
	local moves = math.max(1, d.fallbackMoves + d.pathMoves)
	local requests = math.max(1, d.pathRequests)
	local computed = math.max(1, d.pathOk + d.pathFail)
	say("%s cost: think %.1f us/bot-update (%d updates, %d ticks), worst tick %.2f ms; paths %.2f req/s, %d%% rejected at the cap, %d%% failed, %.0f ms avg compute; straight-line fallback %d%% of moves; hops %d (%d while holding loot)",
		label, d.thinkTime / updates * 1e6, d.updates, d.thinkTicks, after.maxTick * 1000,
		d.pathRequests / seconds, 100 * d.pathRejected / requests, 100 * d.pathFail / computed,
		1000 * d.pathTime / computed, 100 * d.fallbackMoves / moves, d.hops, d.hopsWhileLooting)
	for key, value in pairs(d) do
		if not ({ thinkTime = 1, thinkTicks = 1, updates = 1, maxTick = 1, pathRequests = 1, pathRejected = 1, pathOk = 1, pathFail = 1, pathTime = 1, fallbackMoves = 1, pathMoves = 1, hops = 1, hopsWhileLooting = 1 })[key] then
			say("%s extra stat %s = %s", label, key, tostring(value))
		end
	end
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function rootOf(bot)
	return bot and bot.character and bot.character:FindFirstChild("HumanoidRootPart")
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function posOf(bot)
	local root = rootOf(bot)
	return root and root.Position or nil
end

-- Why a dummy or bot no longer counts: nil record, no character, character gone, no root, dead.
local function status(bot)
	if not bot then
		return "no record"
	end
	if not bot.character then
		return "no character"
	end
	if not bot.character.Parent then
		return "character removed"
	end
	if not rootOf(bot) then
		return "no root"
	end
	return string.format("hp %.0f", bot.humanoid.Health)
end

local function gap(a, b)
	local pa, pb = posOf(a), posOf(b)
	return (pa and pb) and flat(pa - pb).Magnitude or -1
end

local function alive(bot)
	return bot and bot.humanoid and bot.humanoid.Health > 0 and bot.character and bot.character.Parent ~= nil
end

local function spawnBot(cframe)
	local list = BotService.Spawn(1, function()
		return cframe
	end, function() end)
	return list[1]
end

-- A target that stands still: an unarmed bot with its root anchored. It's a real combatant token,
-- so bots can pick it, see it and damage it, but it never moves or shoots.
local function spawnDummy(cframe)
	local bot = spawnBot(cframe)
	local root = rootOf(bot)
	if root then
		root.Anchored = true
	end
	return bot
end

local function arm(bot, weaponId)
	bot.weapon = WeaponData.Get(weaponId)
end

-- Under Map, because loot drops settle by raycasting against Terrain and Map only; parented anywhere
-- else, a gun dropped on a platform would sink into it. Created after the map is built.
local arena = nil

local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Concrete
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if not arena then
		arena = Instance.new("Model")
		arena.Name = "BRR_BotProbeArena"
		arena.Parent = workspace:WaitForChild("Map")
	end
	part.Parent = arena
	return part
end

-- Clear line from one root to another, ignoring both characters.
local function sees(fromBot, toBot)
	local a, b = rootOf(fromBot), rootOf(toBot)
	if not (a and b) then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { fromBot.character, toBot.character }
	return workspace:Raycast(a.Position + Vector3.new(0, 1.5, 0), b.Position - a.Position, params) == nil
end

-- One grounded sample: told to walk somewhere (its MoveTo point, WalkToPoint, is more than 3 studs
-- off) but not actually going anywhere. MoveDirection can't be used: a server-driven MoveTo leaves it
-- at zero, which read as "never grinding" even in the alley.
local function grinding(bot)
	local root = rootOf(bot)
	local humanoid = bot.humanoid
	if not root or humanoid.FloorMaterial == Enum.Material.Air or root.Anchored then
		return false
	end
	local wants = flat(humanoid.WalkToPoint - root.Position).Magnitude > 3
	return wants and flat(root.AssemblyLinearVelocity).Magnitude < 1.5
end

local ARENA_Y = 1600
local ARENA_X = 3400
local PAD_SPACING = 700

local function padCenter(index)
	return Vector3.new(ARENA_X + index * PAD_SPACING, ARENA_Y, 3400)
end

local function pad(index, size)
	local c = padCenter(index)
	block("Pad" .. index, size or Vector3.new(240, 2, 240), CFrame.new(c - Vector3.new(0, 1, 0)))
	return c
end

local function standAt(c, offset)
	return CFrame.new(c + offset + Vector3.new(0, 3.2, 0))
end

--------------------------------------------------------------------------------
-- Map and loot (needed by free roam; built first so the scenario loot survives Populate's Clear)
--------------------------------------------------------------------------------

say("building map %s", MAP_ID)
local buildStarted = os.clock()
local info = MapGenerator.Build(MAP_ID)
LootService.Populate(info)
task.wait(4)
CombatService.SetEnabled(true)
say("map ready in %.0fs: radius %d, %d drop spots, %d loot pickups", os.clock() - buildStarted, info.radius, #(info.dropSpots or {}),
	workspace:FindFirstChild("Loot") and #workspace.Loot:GetChildren() or 0)

--------------------------------------------------------------------------------
-- Scenarios
--------------------------------------------------------------------------------

-- S1: a visible shooter at 100 studs and a closer enemy hidden behind a wall at 35. Does the bot
-- fight the one it can see? Phase A: nobody shoots. Phase B: the visible one shoots it.
local c1 = pad(0)
block("S1Wall", Vector3.new(40, 16, 2), CFrame.new(c1 + Vector3.new(0, 8, -18)))
local s1Hidden = spawnDummy(standAt(c1, Vector3.new(0, 0, -35)))
local s1Visible = spawnDummy(standAt(c1, Vector3.new(0, 0, 100)))
local s1Bot = spawnBot(standAt(c1, Vector3.zero))
arm(s1Bot, "CrocodiloRifle")

-- S2: unarmed, in the open, being shot from 60 studs, with a wall 25 studs to one side to hide
-- behind. The pretend shooter only lands hits while it can actually see the bot.
local c2 = pad(1)
block("S2Cover", Vector3.new(4, 14, 30), CFrame.new(c2 + Vector3.new(-25, 7, 0)))
local s2Shooter = spawnDummy(standAt(c2, Vector3.new(0, 0, 60)))
local s2Bot = spawnBot(standAt(c2, Vector3.zero))

-- S3: armed, on a 40x40 ledge, with its target on a pillar 90 studs away across open air. Pushing
-- in to its preferred range walks straight off the edge unless moves are checked for a floor.
local c3 = pad(2, Vector3.new(40, 2, 40))
block("S3Pillar", Vector3.new(10, 2, 10), CFrame.new(c3 + Vector3.new(0, -1, 90)))
local s3Target = spawnDummy(standAt(c3, Vector3.new(0, 0, 90)))
local s3Bot = spawnBot(standAt(c3, Vector3.new(0, 0, 10)))
arm(s3Bot, "CrocodiloRifle")

-- S4: armed, in an 8-stud-wide alley, target 70 studs down it. Strafing sideways runs into a wall.
local c4 = pad(3)
block("S4WallL", Vector3.new(2, 14, 100), CFrame.new(c4 + Vector3.new(-5, 7, 30)))
block("S4WallR", Vector3.new(2, 14, 100), CFrame.new(c4 + Vector3.new(5, 7, 30)))
local s4Target = spawnDummy(standAt(c4, Vector3.new(0, 0, 70)))
local s4Bot = spawnBot(standAt(c4, Vector3.zero))
arm(s4Bot, "CrocodiloRifle")

-- S5: unarmed, the only gun within reach sits on top of a 24-stud pillar nobody can climb.
local c5 = pad(4)
local pillar = block("S5Pillar", Vector3.new(10, 24, 10), CFrame.new(c5 + Vector3.new(0, 12, 45)))
local pillarTop = pillar.Position + Vector3.new(0, 13, 0)
LootService.DropWeapon("SahurPistol", pillarTop, nil, pillarTop)
local s5Bot = spawnBot(standAt(c5, Vector3.zero))

-- S6: unarmed, a gun lying on the floor 25 studs away. The control for S5: it should just get it.
local c6 = pad(5)
LootService.DropWeapon("SahurPistol", c6 + Vector3.new(0, 1, 25), nil, c6 + Vector3.new(0, 1, 25))
local s6Bot = spawnBot(standAt(c6, Vector3.zero))

-- S10: flank reaction. An armed bot anchored facing +Z (so it can't turn); a dummy appears 30 studs
-- in FRONT of one and 30 studs BEHIND the other, 3 s in. Measured: time to the first shot at it.
local c10 = pad(6)
local s10Front = spawnBot(CFrame.lookAt(c10 + Vector3.new(0, 3.2, 0), c10 + Vector3.new(0, 3.2, 50)))
-- On its own pad: side by side, the two armed bots would simply shoot each other.
local c13 = pad(13)
local s10Rear = spawnBot(CFrame.lookAt(c13 + Vector3.new(0, 3.2, 0), c13 + Vector3.new(0, 3.2, 50)))
for _, bot in ipairs({ s10Front, s10Rear }) do
	arm(bot, "CrocodiloRifle")
	rootOf(bot).Anchored = true
end

-- S12: duels. Two armed bots 50 studs apart on open ground with the same rifle, three pairs at once.
-- Run twice: this block with MatchConfig.BotReload off, the block after with it on.
local function spawnDuels(firstPad, weaponId)
	local duels = {}
	for index = 0, 2 do
		local c = pad(firstPad + index)
		local a = spawnBot(CFrame.lookAt(c + Vector3.new(0, 3.2, -25), c + Vector3.new(0, 3.2, 25)))
		local b = spawnBot(CFrame.lookAt(c + Vector3.new(0, 3.2, 25), c + Vector3.new(0, 3.2, -25)))
		arm(a, weaponId)
		arm(b, weaponId)
		table.insert(duels, { a = a, b = b, endedAt = nil, reloads = 0, wasReloading = {}, weapon = weaponId })
	end
	return duels
end
local function sampleDuels(duels, t)
	for _, duel in ipairs(duels) do
		if not duel.endedAt and (not alive(duel.a) or not alive(duel.b)) then
			duel.endedAt = t
			duel.winnerHp = alive(duel.a) and duel.a.humanoid.Health or alive(duel.b) and duel.b.humanoid.Health or 0
		end
		for _, bot in ipairs({ duel.a, duel.b }) do
			local reloading = bot.reloadUntil ~= nil
			if reloading and not duel.wasReloading[bot] then
				duel.reloads += 1
			end
			duel.wasReloading[bot] = reloading
		end
	end
end
local function reportDuels(label, duels)
	local parts = {}
	for index, duel in ipairs(duels) do
		table.insert(parts, string.format("#%d %s, winner hp %.0f, shots %d, reloads %d, damage %.0f", index,
			duel.endedAt and string.format("over at %.1fs", duel.endedAt) or "still going",
			duel.winnerHp or -1, (shotsBy[duel.a] or 0) + (shotsBy[duel.b] or 0), duel.reloads,
			(dealtBy[duel.a] and dealtBy[duel.a][duel.b] or 0) + (dealtBy[duel.b] and dealtBy[duel.b][duel.a] or 0)))
	end
	say("S12 duels (%s), %s: %s", duels[1] and duels[1].weapon or "?", label, table.concat(parts, "; "))
end
MatchConfig.BotReload = false
local duelsOff = spawnDuels(7, "CrocodiloRifle")
local popperOff = spawnDuels(18, "PocketPopper")

-- The Explosives tab's ProjectileService, when this build has it.
local okProjectiles, ProjectileService = pcall(function()
	local module = modules:FindFirstChild("ProjectileService")
	return module and require(module) or nil
end)
ProjectileService = okProjectiles and ProjectileService or nil

-- S13: a launcher. An armed bot with a CappuccinaLauncher and a dummy 60 studs off: its rounds go
-- through ProjectileService.FireWeapon rather than the hitscan roll.
local c14 = pad(14)
local s13Target = spawnDummy(CFrame.new(c14 + Vector3.new(0, 3.2, 60)))
local s13Bot = spawnBot(standAt(c14, Vector3.zero))
arm(s13Bot, "CappuccinaLauncher")

-- S14: throwables. One bot with frags faces two dummies bunched 45 studs away (a grenade into the
-- middle); another, down to 20 hp with a dummy 35 studs off, has smoke to cover its retreat.
local c15 = pad(15)
local s14Pair = {
	spawnDummy(CFrame.new(c15 + Vector3.new(-2, 3.2, 45))),
	spawnDummy(CFrame.new(c15 + Vector3.new(2, 3.2, 45))),
}
local s14Frag = spawnBot(standAt(c15, Vector3.zero))
arm(s14Frag, "SahurPistol")
s14Frag.throwables = { CookedCoconut = 2 }
local c16 = pad(16)
local s14Threat = spawnDummy(CFrame.new(c16 + Vector3.new(0, 3.2, 35)))
local s14Smoke = spawnBot(standAt(c16, Vector3.zero))
arm(s14Smoke, "SahurPistol")
s14Smoke.throwables = { LowkeyLatte = 2 }
s14Smoke.humanoid.Health = 20

-- S15: a live frag. A dummy lobs a Cooked Coconut at the feet of an idle unarmed bot 30 studs away;
-- the bot should see it in ProjectileService.Dangers and get clear before the fuse runs out.
local c17 = pad(17)
local s15Thrower = spawnDummy(CFrame.new(c17 + Vector3.new(0, 3.2, 30)))
local s15Bot = spawnBot(standAt(c17, Vector3.zero))
-- Held in place (as if behind cover) so the only reason to move is the frag: an idle bot wanders at
-- ~17 studs/s and would be clear of the blast whether or not it dodged.
s15Bot.coverUntil = os.clock() + 120
-- The control: the same throw at an anchored dummy's feet must hurt it.
local c26 = pad(26)
local s15ControlThrower = spawnDummy(CFrame.new(c26 + Vector3.new(0, 3.2, 30)))
local s15Control = spawnDummy(standAt(c26, Vector3.zero))
local s15 = { thrownAt = nil, landing = nil, hpBefore = nil, distanceAtBlast = nil }

-- S16/S17: parkour on the way to loot. A wall across the whole pad (so no route goes round it) with a
-- gun 20 studs beyond it and an unarmed bot 20 studs in front. S16's wall is 6 high (a climb from
-- standing), S17's 9 high (only from the top of a jump). Measured per bot: parkour moves started
-- (rising edges of the Parkour attribute), when it got over, whether it ever came back over (a
-- follower walking back to a waypoint it passed), and when it armed.
local okMatch, MatchServiceProbe = pcall(function()
	return require(modules:WaitForChild("MatchService"))
end)
MatchServiceProbe = okMatch and MatchServiceProbe or nil

local okMovement, MovementService = pcall(function()
	return require(modules:WaitForChild("MovementService"))
end)
MovementService = okMovement and MovementService or nil

local function wallCourse(padIndex, height)
	local c = pad(padIndex)
	block("ParkourWall" .. height, Vector3.new(240, height, 2), CFrame.new(c + Vector3.new(0, height / 2, 20)))
	LootService.DropWeapon("SahurPistol", c + Vector3.new(0, 1, 40), nil, c + Vector3.new(0, 1, 40))
	local bot = spawnBot(CFrame.lookAt(c + Vector3.new(0, 3.2, 0), c + Vector3.new(0, 3.2, 40)))
	return { bot = bot, c = c, height = height, moves = 0, wasMoving = false, overAt = nil, backAt = nil,
		armedAt = nil, closest = 1e9, reason = "never within reach", tried = 0, trace = {} }
end
local courses = { wallCourse(24, 6), wallCourse(25, 9) }

-- S18: ducking out of sight. An armed bot shoots a tough dummy 40 studs off in the open; 6 s in, the
-- dummy is moved behind a wall. Hits that land more than one think (0.25 s) later went through it.
-- S19: heal caps. Bots must be held to the same ceiling as players: a Bandage lifts to 75, not to
-- full, and one at the cap isn't spent at all. Both bots are hurt below BotHealBelow so they will
-- actually reach for a heal, and are left alone (no targets on their pads) so the lull passes.
local c28 = pad(28)
local s19Bandage = spawnBot(standAt(c28, Vector3.zero))
s19Bandage.humanoid.Health = 58
s19Bandage.heals.Bandage, s19Bandage.heals.MedKit = 2, 0
-- Health is read the instant a heal is spent: out-of-combat regen (3.5/s after 9 s) would otherwise
-- carry both bots to full and hide whether the cap was applied at all.
local s19 = { bandageAfter = nil, kitAfter = nil }
local c29 = pad(29)
local s19Kit = spawnBot(standAt(c29, Vector3.zero))
s19Kit.humanoid.Health = 58
s19Kit.heals.Bandage, s19Kit.heals.MedKit = 0, 1

-- S20: water is not cover. A slab of terrain water stands between a bot and a threat, tall enough
-- that the sight line really crosses it (a river read the same way to a bot standing in one).
-- BotService.ExposedTo must say EXPOSED; the control is the same ray with Roblox's default
-- IgnoreWater = false, which is what the bug was, and it must report the water as a hit.
-- S21: crouching. An armed bot holding a spot against a dummy 60 studs off should get low (it isn't
-- going anywhere and it's shooting); an unarmed bot walking to a gun should stay up, because crouched
-- is 0.45x speed. Only meaningful once MatchService has crouch; it says so when it doesn't.
-- S22: the wandering-while-unarmed case, pinned. A lone unarmed bot on a long strip with the only
-- gun 400 studs away: further than the 320-stud sweep an empty-handed bot used to give up at, so the
-- old code never targeted it and milled about instead (that is the 312-of-534 "no loot target" count
-- from the free-roam runs). The fix walks to the nearest gun anywhere, so this bot should arm.
-- Independent of map churn: nothing here comes from the map.
-- S23: aim. One bot per range against a dummy it cannot kill, so the hit rate is measured over a
-- long burst rather than inferred. Reported against what the live constants predict and against the
-- old ones, so "nerf the aim a bit" is a number.
local s23 = {}
for index, range in ipairs({ 20, 60, 150 }) do
	local c = pad(33 + index)
	local target = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, range)))
	target.humanoid.MaxHealth = 1e6
	target.humanoid.Health = 1e6
	local shooter = spawnBot(CFrame.lookAt(c + Vector3.new(0, 3.2, 0), c + Vector3.new(0, 3.2, range)))
	arm(shooter, "CrocodiloRifle")
	-- Anchored: unanchored it strafes and pushes, so the range drifts and the hit rate is measured at
	-- a distance that isn't the one in the label.
	rootOf(shooter).Anchored = true
	table.insert(s23, { range = range, bot = shooter, target = target })
end

-- S24: a dead bot's body. MatchService drops a bot's gun from its root position, and gives up if
-- there is no root — which is what happens to a body that fell out of the world. Two deaths: one by
-- damage, one into the void, each asked whether a root still existed when it died.
local c37 = pad(37)
local s24 = { shot = "not killed yet", void = "not killed yet" }
local s24Shot = spawnBot(standAt(c37, Vector3.new(-10, 0, 0)))
local s24Void = spawnBot(standAt(c37, Vector3.new(10, 0, 0)))
arm(s24Shot, "SahurPistol")
arm(s24Void, "SahurPistol")
for name, bot in pairs({ shot = s24Shot, void = s24Void }) do
	bot.humanoid.Died:Connect(function()
		local root = bot.character:FindFirstChild("HumanoidRootPart")
		s24[name] = string.format("Died fired: root %s, character %s, weapon %s",
			root and "present" or "GONE (nothing to drop from)",
			bot.character.Parent and "still in the world" or "already removed",
			bot.weapon and bot.weapon.id or "none")
	end)
end

-- S25: a team mode, faked. Six armed bots, three a side, on a pad with a "hill" 45 studs from where
-- they spawn. Mode state is fed through BotService.ModeState (the seam it reads a real mode through)
-- and hostility through BotService.IsHostile, so nothing of the mode tab's runs here. Measured: how
-- many bots stand on the hill over time, and how often a bot has no objective at all (the "circles").
-- Both hooks are put back to nil afterwards so the battle royale free roam below is unaffected.
local c38 = pad(38, Vector3.new(240, 2, 240))
local s25Hill = c38 + Vector3.new(0, 0, 45)
local s25Team, s25Bots = {}, {}
for index = 1, 6 do
	local side = index % 2 + 1
	local bot = spawnBot(standAt(c38, Vector3.new((index - 3.5) * 8, 0, -30)))
	arm(bot, "SahurPistol")
	s25Team[bot] = side
	table.insert(s25Bots, bot)
end
local function s25Occupancy()
	local counts = { 0, 0 }
	for _, bot in ipairs(s25Bots) do
		local at = posOf(bot)
		if at and alive(bot) and flat(at - s25Hill).Magnitude <= 28 then
			counts[s25Team[bot]] += 1
		end
	end
	return counts
end
local s25 = { samples = 0, onHill = 0, noObjective = 0, kinds = {} }
-- #125 (bots walking in unison): teammates within 30 studs, both walking, heading within 20 degrees.
local s25Prev, s25Pairs, s25Aligned = {}, 0, 0
-- The real seam is a FUNCTION, not nil: it must be put back afterwards, not cleared. Clearing it
-- (as the first version did) deleted the seam and every bot crashed on it for the rest of the run.
local realModeState = BotService.ModeState
if BotService.ModeState then
	BotService.ModeState = function(bot)
		local team = s25Team[bot]
		if not team then
			return nil
		end
		local counts = s25Occupancy()
		local holder = nil
		if counts[1] > 0 and counts[2] == 0 then holder = 1 elseif counts[2] > 0 and counts[1] == 0 then holder = 2 end
		return { team = team, hill = s25Hill, occupancy = counts, holder = holder, arena = c38 }
	end
	BotService.IsHostile = function(a, b)
		local ta, tb = s25Team[a], s25Team[b]
		if ta and tb then
			return ta ~= tb
		end
		return true
	end
end

local c33 = padCenter(33)
block("S22Strip", Vector3.new(60, 2, 520), CFrame.new(c33 + Vector3.new(0, -1, 200)))
LootService.DropWeapon("SahurPistol", c33 + Vector3.new(0, 1, 400), nil, c33 + Vector3.new(0, 1, 400))
local s22Bot = spawnBot(CFrame.lookAt(c33 + Vector3.new(0, 3.2, 0), c33 + Vector3.new(0, 3.2, 40)))
local s22 = { armedAt = nil, targetedAt = nil, walked = 0, last = nil }

local c31 = pad(31)
local s21Target = spawnDummy(CFrame.new(c31 + Vector3.new(0, 3.2, 60)))
local s21Holder = spawnBot(standAt(c31, Vector3.zero))
arm(s21Holder, "CrocodiloRifle")
local c32 = pad(32)
LootService.DropWeapon("SahurPistol", c32 + Vector3.new(0, 1, 45), nil, c32 + Vector3.new(0, 1, 45))
local s21Walker = spawnBot(standAt(c32, Vector3.zero))
local s21 = { holderCrouched = 0, holderSamples = 0, walkerCrouchedWhileMoving = 0, walkerMoving = 0 }

local c30 = pad(30)
local s20Bot = spawnBot(standAt(c30, Vector3.zero))
local s20From = c30 + Vector3.new(0, 4.7, 40)
workspace.Terrain:FillBlock(CFrame.new(c30 + Vector3.new(0, 6, 20)), Vector3.new(40, 16, 8), Enum.Material.Water)
task.wait(0.2)
local s20 = { exposed = nil, controlHit = nil }
do
	local root = rootOf(s20Bot)
	s20.exposed = BotService.ExposedTo and BotService.ExposedTo(s20Bot, root, s20From) or nil
	local control = RaycastParams.new()
	control.FilterType = Enum.RaycastFilterType.Exclude
	control.FilterDescendantsInstances = { s20Bot.character }
	control.RespectCanCollide = true
	-- IgnoreWater left at its default, false: the old behaviour.
	local eye = root.Position + Vector3.new(0, 1.5, 0)
	local hit = workspace:Raycast(s20From, eye - s20From, control)
	s20.controlHit = hit and hit.Material == Enum.Material.Water
end
workspace.Terrain:FillBlock(CFrame.new(c30 + Vector3.new(0, 6, 20)), Vector3.new(40, 16, 8), Enum.Material.Air)

local c27 = pad(27)
block("S18Wall", Vector3.new(30, 14, 2), CFrame.new(c27 + Vector3.new(40, 7, 38)))
local s18Target = spawnDummy(CFrame.new(c27 + Vector3.new(0, 3.2, 40)))
s18Target.humanoid.MaxHealth = 100000
s18Target.humanoid.Health = 100000
local s18Bot = spawnBot(standAt(c27, Vector3.zero))
arm(s18Bot, "CrocodiloRifle")
local s18 = { movedAt = nil, hpAtMove = nil, hpAfterOneThink = nil, hpLater = nil }

task.wait(2)
local statsBefore = statsSnapshot()
BotService.Start()
local scenarioStart = os.clock()
local s10Dummies = nil
local s10FirstShot = {}

-- Sampling for every scenario at once, 5 Hz, for 24 s.
local S = {
	s1 = { shotsA = 0, shotsB = 0, grind = 0, samples = 0, towardHidden = 0 },
	s2 = { seen = 0, samples = 0, taken = 0, grind = 0, firstHurtAt = nil, hurtFrom = nil, reactedAt = nil },
	s3 = { fell = false, fellAt = nil, grind = 0, samples = 0 },
	s4 = { grind = 0, samples = 0 },
	s5 = { grind = 0, samples = 0, hopsSeen = 0, lastHop = nil, fixatedAtEnd = false, travel = 0 },
	s6 = { armedAt = nil },
}
local s1HiddenStart = gap(s1Bot, s1Hidden)
local s5Last = posOf(s5Bot) or c5
local s2DamageUntil = scenarioStart + 12
local nextHurt = scenarioStart

while os.clock() - scenarioStart < 24 do
	task.wait(0.2)
	local t = os.clock() - scenarioStart

	-- S1: phase A is the first 4 s, phase B the 8 s after.
	if alive(s1Bot) and t < 12 then
		S.s1.samples += 1
		if grinding(s1Bot) then
			S.s1.grind += 1
		end
		if t >= 4 and os.clock() >= nextHurt then
			nextHurt = os.clock() + 0.5
			hurt(s1Visible, s1Bot, 3)
		end
	end

	-- S2
	if alive(s2Bot) and os.clock() < s2DamageUntil then
		S.s2.samples += 1
		if s2Bot.coverPoint then
			S.s2.coverSamples = (S.s2.coverSamples or 0) + 1
			S.s2.coverRouted = (S.s2.coverRouted or 0) + (s2Bot.coverPoint.direct and 0 or 1)
		end
		S.s2.branches = S.s2.branches or {}
		S.s2.branches[s2Bot.branch or "?"] = (S.s2.branches[s2Bot.branch or "?"] or 0) + 1
		if sees(s2Shooter, s2Bot) then
			S.s2.seen += 1
			if S.s2.samples % 2 == 0 then
				S.s2.taken += hurt(s2Shooter, s2Bot, 2) or 0
				if not S.s2.firstHurtAt then
					S.s2.firstHurtAt = t
					S.s2.hurtFrom = posOf(s2Bot)
				end
			end
		end
		if grinding(s2Bot) then
			S.s2.grind += 1
		end
		-- Reaction: the first sample after the first hit where it has a cover spot or has moved 3 studs.
		if S.s2.firstHurtAt and not S.s2.reactedAt and (s2Bot.coverPoint or (posOf(s2Bot)
			and S.s2.hurtFrom and flat(posOf(s2Bot) - S.s2.hurtFrom).Magnitude >= 3)) then
			S.s2.reactedAt = t
		end
	end

	-- S3
	local r3 = rootOf(s3Bot)
	if r3 and not S.s3.fell then
		S.s3.samples += 1
		if r3.Position.Y < ARENA_Y - 20 then
			S.s3.fell = true
			S.s3.fellAt = t
		elseif grinding(s3Bot) then
			S.s3.grind += 1
		end
	end

	-- S4
	if alive(s4Bot) then
		S.s4.samples += 1
		if grinding(s4Bot) then
			S.s4.grind += 1
		end
	end

	-- S5
	local r5 = rootOf(s5Bot)
	if r5 and alive(s5Bot) then
		S.s5.samples += 1
		S.s5.travel += (r5.Position - s5Last).Magnitude
		s5Last = r5.Position
		if grinding(s5Bot) then
			S.s5.grind += 1
		end
		-- Old BotService keeps the hop time on the bot, the new one on bot.nav.
		local hopAt = s5Bot.lastHopAt or (s5Bot.nav and s5Bot.nav.lastHopAt)
		if hopAt and hopAt > 0 and hopAt ~= S.s5.lastHop then
			S.s5.lastHop = hopAt
			S.s5.hopsSeen += 1
		end
	end

	-- S6
	if not S.s6.armedAt and s6Bot.weapon then
		S.s6.armedAt = t
	end

	-- S10
	if not s10Dummies and t >= 3 then
		s10Dummies = {
			front = spawnDummy(CFrame.new(c10 + Vector3.new(0, 3.2, 30))),
			rear = spawnDummy(CFrame.new(c13 + Vector3.new(0, 3.2, -30))),
			at = t,
		}
		shotsBy[s10Front], shotsBy[s10Rear] = 0, 0
	end
	if s10Dummies then
		for key, bot in pairs({ front = s10Front, rear = s10Rear }) do
			if not s10FirstShot[key] and (shotsBy[bot] or 0) > 0 then
				s10FirstShot[key] = t - s10Dummies.at
			end
		end
	end

	if t > 3 and t < 4 then
		-- Kill one by damage and drop the other out of the world.
		if alive(s24Shot) then
			hurt(s24Void, s24Shot, 500)
		end
		local voidRoot = rootOf(s24Void)
		if voidRoot and alive(s24Void) then
			voidRoot.CFrame = CFrame.new(voidRoot.Position.X, -800, voidRoot.Position.Z)
		end
	end

	sampleDuels(duelsOff, t)
	sampleDuels(popperOff, t)

	if BotService.ModeState then
		local counts = s25Occupancy()
		for _, bot in ipairs(s25Bots) do
			if alive(bot) then
				s25.samples += 1
				local kind = bot.objectiveKind or "none"
				s25.kinds[kind] = (s25.kinds[kind] or 0) + 1
				if kind == "none" and not bot.lootTarget and (bot.branch == "wander" or bot.branch == "idle") then
					s25.noObjective += 1
				end
			end
		end
		s25.onHill += counts[1] + counts[2]
		local moves = {}
		for _, bot in ipairs(s25Bots) do
			local at = posOf(bot)
			if at and alive(bot) then
				local previous = s25Prev[bot]
				if previous then
					local step = flat(at - previous)
					if step.Magnitude > 1 then
						moves[bot] = { at = at, dir = step.Unit }
					end
				end
				s25Prev[bot] = at
			end
		end
		for a, ma in pairs(moves) do
			for b, mb in pairs(moves) do
				if a ~= b and s25Team[a] == s25Team[b] and flat(ma.at - mb.at).Magnitude < 30 then
					s25Pairs += 1
					if ma.dir:Dot(mb.dir) > 0.94 then
						s25Aligned += 1
					end
				end
			end
		end
	end

	if not s18.movedAt and t >= 6 then
		s18.hitsBefore = dealtBy[s18Bot] and dealtBy[s18Bot][s18Target] or 0
		rootOf(s18Target).CFrame = CFrame.new(c27 + Vector3.new(40, 3.2, 44))
		s18.movedAt = t
		s18.hpAtMove = s18Target.humanoid.Health
	end
	if s18.movedAt and not s18.hpAfterOneThink and t >= s18.movedAt + 0.3 then
		s18.hpAfterOneThink = s18Target.humanoid.Health
	end
	if s18.movedAt and not s18.hpLater and t >= s18.movedAt + 1.5 then
		s18.hpLater = s18Target.humanoid.Health
	end

	do
		local match = MatchServiceProbe
		if match and match.IsCrouching then
			if alive(s21Holder) then
				s21.holderSamples += 1
				if match.IsCrouching(s21Holder) then
					s21.holderCrouched += 1
				end
			end
			local walkerRoot = rootOf(s21Walker)
			if walkerRoot and alive(s21Walker) and flat(walkerRoot.AssemblyLinearVelocity).Magnitude > 3 then
				s21.walkerMoving += 1
				if match.IsCrouching(s21Walker) then
					s21.walkerCrouchedWhileMoving += 1
				end
			end
		end
	end

	do
		local at = posOf(s22Bot)
		if at then
			if s22.last then
				s22.walked += flat(at - s22.last).Magnitude
			end
			s22.last = at
		end
		if not s22.targetedAt and s22Bot.lootTarget then
			s22.targetedAt = t
		end
		if not s22.armedAt and s22Bot.weapon then
			s22.armedAt = t
		end
	end

	for _, course in ipairs(courses) do
		local position = posOf(course.bot)
		if position then
			local moving = course.bot.character:GetAttribute("Parkour") ~= nil
			if moving and not course.wasMoving then
				course.moves += 1
			end
			course.wasMoving = moving
			local beyond = position.Z > course.c.Z + 21.5
			if beyond and not course.overAt then
				course.overAt = t
			elseif course.overAt and not course.backAt and not course.armedAt and position.Z < course.c.Z + 18.5 then
				course.backAt = t
			end
		end
		if not s19.bandageAfter and s19Bandage.heals.Bandage < 2 then
			s19.bandageAfter = s19Bandage.humanoid.Health
		end
		if not s19.kitAfter and s19Kit.heals.MedKit < 1 then
			s19.kitAfter = s19Kit.humanoid.Health
		end
		if course.bot.weapon and not course.armedAt then
			course.armedAt = t
		end
		-- Why a climb is refused, asked at the wall itself: CanParkour is read-only.
		local at = posOf(course.bot)
		if at and MovementService and MovementService.CanParkour then
			local gap = math.abs(at.Z - (course.c.Z + 20)) - 1
			course.closest = math.min(course.closest, gap)
			if gap < 4 and at.Z < course.c.Z + 20 then
				course.tried += 1
				local kind, why = MovementService.CanParkour(course.bot.character, Vector3.new(0, 0, 1), {
					speed = course.bot.humanoid.WalkSpeed,
					groundY = at.Y - 3,
				})
				course.reason = kind or tostring(why)
			end
			-- The bot's own state on the approach, so "never asked" has a reason next to it.
			if gap < 8 and #course.trace < 14 then
				local nav = course.bot.nav or {}
				local refusal = course.bot.character:GetAttribute("BotParkourRefusal")
				table.insert(course.trace, string.format("%.1fs g%.1f %s/%s %s%s%s%s", t, gap,
					tostring(nav.directReason), nav.directWallDistance and string.format("%.1f", nav.directWallDistance) or "-",
					course.bot.branch or "?", course.bot.lootTarget and " loot" or " NOLOOT",
					(nav.request or nav.computing) and " pending" or "",
					refusal and (" ref=" .. tostring(refusal)) or ""))
			end
		end
	end

	-- S15: throw at 2 s, measure the gap to the landing point 3.6 s later (fuse 3.2 s plus flight).
	if ProjectileService and not s15.thrownAt and t >= 2 and alive(s15Bot) then
		s15.landing = posOf(s15Bot) - Vector3.new(0, 3, 0)
		s15.startPosition = posOf(s15Bot)
		s15.hpBefore = s15Bot.humanoid.Health
		s15.ok = ProjectileService.Throw(s15Thrower, "CookedCoconut", s15.landing)
		s15.controlHpBefore = s15Control.humanoid.Health
		s15.controlOk = ProjectileService.Throw(s15ControlThrower, "CookedCoconut", posOf(s15Control) - Vector3.new(0, 3, 0))
		s15.thrownAt = t
	end
	-- Still where it was just before the throw? (It should be: it's holding.)
	if s15.thrownAt and not s15.movedBeforeThrow then
		s15.movedBeforeThrow = false
	end
	if s15.thrownAt and not s15.distanceAtBlast and t >= s15.thrownAt + 3.6 then
		s15.distanceAtBlast = posOf(s15Bot) and flat(posOf(s15Bot) - s15.landing).Magnitude or -1
	end
end

-- S1 results: which enemy did the shots go toward?
say("scenario dummies: S1 hidden %s, S1 visible %s, S2 shooter %s, S3 target %s, S4 target %s",
	status(s1Hidden), status(s1Visible), status(s2Shooter), status(s3Target), status(s4Target))
local toVisible, toHidden = 0, 0
local visibleAt, hiddenAt = c1 + Vector3.new(0, 3.2, 100), c1 + Vector3.new(0, 3.2, -35)
for _, point in ipairs(shotEnds[s1Bot] or {}) do
	if point then
		local dv = (point - visibleAt).Magnitude
		local dh = (point - hiddenAt).Magnitude
		if dv < dh then
			toVisible += 1
		else
			toHidden += 1
		end
	end
end
local s1Dealt = dealtBy[s1Bot] and dealtBy[s1Bot][s1Visible] or 0
say("S1 visible shooter vs hidden closer enemy: shots toward visible %d, toward hidden %d (want most toward visible); damage to visible %.0f (want > 0); moved %.0f -> %.0f studs from the hidden one; grinding %d/%d samples; alive=%s",
	toVisible, toHidden, s1Dealt, s1HiddenStart, gap(s1Bot, s1Hidden),
	S.s1.grind, S.s1.samples, tostring(alive(s1Bot)))

local s2Distance = flat((posOf(s2Bot) or c2) - (c2 + Vector3.new(0, 0, 60))).Magnitude
say("S2 unarmed under fire: visible to the shooter %d/%d samples (want low), took %.0f damage, ended %.0f studs from the shooter (started 60), grinding %d, alive=%s, armed=%s; reacted %s after the first hit, cover spot %s",
	S.s2.seen, S.s2.samples, S.s2.taken, s2Distance, S.s2.grind, tostring(alive(s2Bot)), tostring(s2Bot.weapon ~= nil),
	S.s2.reactedAt and string.format("%.2fs", S.s2.reactedAt - S.s2.firstHurtAt) or "never",
	s2Bot.coverPoint and (s2Bot.coverPoint.direct and "straight" or "routed") or "none now")
do
	local parts = {}
	for name, count in pairs(S.s2.branches or {}) do
		table.insert(parts, string.format("%s %d", name, count))
	end
	table.sort(parts)
	say("S2 detail: had a cover spot in %d samples (%d of them needing a route); think branches: %s",
		S.s2.coverSamples or 0, S.s2.coverRouted or 0, table.concat(parts, ", "))
end

say("S3 ledge push: fell off=%s%s (want false), grinding %d/%d, shots %d, damage to target %.0f",
	tostring(S.s3.fell), S.s3.fellAt and string.format(" at %.1fs", S.s3.fellAt) or "", S.s3.grind, S.s3.samples,
	shotsBy[s3Bot] or 0, dealtBy[s3Bot] and dealtBy[s3Bot][s3Target] or 0)

say("S4 alley fight: grinding %d/%d samples (want low), shots %d, damage to target %.0f, alive=%s",
	S.s4.grind, S.s4.samples, shotsBy[s4Bot] or 0, dealtBy[s4Bot] and dealtBy[s4Bot][s4Target] or 0, tostring(alive(s4Bot)))

local s5Target = s5Bot.lootTarget
local s5OnPillar = s5Target and s5Target.Parent and (flat(s5Target.Position) - flat(pillar.Position)).Magnitude < 8
say("S5 unreachable gun on a pillar: still chasing it after 24 s=%s (want false), hops %d, grinding %d/%d, walked %.0f studs, final distance to pillar %.0f",
	tostring(s5OnPillar == true), S.s5.hopsSeen, S.s5.grind, S.s5.samples, S.s5.travel,
	posOf(s5Bot) and flat(posOf(s5Bot) - pillar.Position).Magnitude or -1)

say("S6 reachable gun 25 studs away: armed after %s (want a few seconds)", S.s6.armedAt and string.format("%.1fs", S.s6.armedAt) or "never")

-- Burst rests mean the first shot can trail the decision by up to ~0.8 s, so compare the two.
say("S10 flank: first shot at a target appearing in front %s, behind %s (want behind later by about BotRearNoticeTime)",
	s10FirstShot.front and string.format("%.2fs", s10FirstShot.front) or "never",
	s10FirstShot.rear and string.format("%.2fs", s10FirstShot.rear) or "never")
reportDuels("reload OFF", duelsOff)
reportDuels("reload OFF", popperOff)

do
	local match = MatchServiceProbe
	if match and match.IsCrouching then
		say("S21 crouching: holder crouched in %d of %d samples (want most: it's holding a spot and shooting); walker crouched in %d of %d moving samples (want 0: crouched is 0.45x speed)",
			s21.holderCrouched, s21.holderSamples, s21.walkerCrouchedWhileMoving, s21.walkerMoving)
	else
		say("S21 crouching: skipped, this build's MatchService has no crouch")
	end
end
do
	local function expected(near, far, range)
		local t = math.clamp(range / MatchConfig.BotAccuracyFalloff, 0, 1)
		return far + (near - far) * (1 - t)
	end
	local parts = {}
	for _, entry in ipairs(s23) do
		local shots = shotsBy[entry.bot] or 0
		-- Hits are counted as damage EVENTS, not damage divided by a per-hit figure: a headshot does
		-- 1.9x, and dividing damage out inflated the rate by about a tenth.
		local hits = hitsBy[entry.bot] and hitsBy[entry.bot][entry.target] or 0
		table.insert(parts, string.format("%d studs: %d shots, %.0f%% hit (live constants predict %.0f%%, the old 0.66/0.19 predicted %.0f%%)",
			entry.range, shots, shots > 0 and hits / shots * 100 or 0,
			expected(MatchConfig.BotAccuracyNear, MatchConfig.BotAccuracyFar, entry.range) * 100,
			expected(0.66, 0.19, entry.range) * 100))
	end
	say("S23 aim: %s", table.concat(parts, "; "))
	local voidState = s24.void
	if voidState == "not killed yet" then
		-- A body that falls out of the world can be destroyed without Died ever firing: that is the
		-- case that silently drops nothing.
		voidState = string.format("no Died event; character %s, health %.0f",
			s24Void.character.Parent and "still in the world" or "REMOVED by the fall, so nothing dropped",
			s24Void.humanoid and s24Void.humanoid.Health or -1)
	end
	say("S24 a dead bot's body: killed by damage -> %s; dropped into the void -> %s", s24.shot, voidState)
end
if BotService.ModeState then
	local parts = {}
	for kind, count in pairs(s25.kinds) do
		table.insert(parts, string.format("%s %d", kind, count))
	end
	table.sort(parts)
	local living = 0
	for _, bot in ipairs(s25Bots) do
		if alive(bot) then living += 1 end
	end
	say("S25 team mode (faked hill, 3v3): bots on the hill averaged %.1f per sample over %d samples (want well above 0), objectives seen: %s; samples with NO objective while wandering %d (want 0, that is the circling); %d of 6 alive at the end",
		s25.samples > 0 and s25.onHill / (s25.samples / math.max(1, living)) or 0, s25.samples, table.concat(parts, ", "), s25.noObjective, living)
	say("S25 teammates within 30 studs and both walking: %d pair-samples, %.0f%% heading within 20 degrees of each other (#125 unison; independent headings would give about 11%%)",
		s25Pairs / 2, s25Pairs > 0 and 100 * s25Aligned / s25Pairs or 0)
	BotService.ModeState = realModeState
	BotService.IsHostile = nil
else
	say("S25 team mode: skipped, this build has no BotService.ModeState")
end
say("S22 unarmed with the only gun 400 studs away (beyond the old 320-stud sweep): targeted it at %s, armed at %s (want both; 'never' is the old wandering), walked %.0f studs, alive=%s",
	s22.targetedAt and string.format("%.1fs", s22.targetedAt) or "never",
	s22.armedAt and string.format("%.1fs", s22.armedAt) or "never", s22.walked, tostring(alive(s22Bot)))
say("S20 water is not cover: bot reads as exposed through water = %s (want true); control ray with the old params hit water = %s (want true, or this test proves nothing)",
	tostring(s20.exposed), tostring(s20.controlHit))
say("S19 heal caps, health read AT the moment the item was spent: Bandage bot 58 -> %s hp (want 75, a player's Bandage cap; 88 means the cap is missing), bandages left %d of 2 (want 1: the second is refused at the cap); Med Kit bot 58 -> %s hp (want 100, its own cap), kits left %d of 1",
	s19.bandageAfter and string.format("%.0f", s19.bandageAfter) or "never spent one",
	s19Bandage.heals.Bandage,
	s19.kitAfter and string.format("%.0f", s19.kitAfter) or "never spent one", s19Kit.heals.MedKit)
say("S18 ducking behind a wall: damage before the move %.0f (want > 0); after the move, damage between one think (0.3 s) and 1.5 s: %.0f (want 0)",
	s18.hitsBefore or -1, (s18.hpAfterOneThink and s18.hpLater) and (s18.hpAfterOneThink - s18.hpLater) or -1)

for index, course in ipairs(courses) do
	say("S%d parkour over a %d-stud wall to a gun: parkour moves started %d, over at %s (want yes), came back over at %s (want never), armed at %s, alive=%s; closest approach %.1f studs, CanParkour asked %d times, last answer %s",
		15 + index, course.height, course.moves,
		course.overAt and string.format("%.1fs", course.overAt) or "never",
		course.backAt and string.format("%.1fs", course.backAt) or "never",
		course.armedAt and string.format("%.1fs", course.armedAt) or "never", tostring(alive(course.bot)),
		course.closest, course.tried, course.reason)
	say("   S%d the bot's OWN last refusal (not the probe's question): %s", 15 + index,
		tostring(course.bot.character:GetAttribute("BotParkourRefusal")))
	say("   S%d approach trace (t gap directReason/wallDist branch loot pending refusal): %s", 15 + index,
		#course.trace > 0 and table.concat(course.trace, " | ") or "never within 8 studs")
end
do
	local BotNavModule = require(modules:WaitForChild("BotNav"))
	say("parkour refusals seen by the bots themselves: last reason %s (the courses above ask CanParkour from standing; this is what the bot's own attempts, jump included, were told)",
		tostring(BotNavModule.LastParkourReason))
end

if ProjectileService then
	say("S13 launcher: shots %d (want > 0), damage to the dummy %.0f, bot alive=%s",
		shotsBy[s13Bot] or 0, dealtBy[s13Bot] and dealtBy[s13Bot][s13Target] or 0, tostring(alive(s13Bot)))
	say("S14 throwables: frag bot has %d of 2 frags left (want fewer), damage to the pair %.0f; smoke bot has %d of 2 smokes left (want fewer), alive=%s",
		s14Frag.throwables.CookedCoconut or 0,
		(dealtBy[s14Frag] and (dealtBy[s14Frag][s14Pair[1]] or 0) + (dealtBy[s14Frag][s14Pair[2]] or 0)) or 0,
		s14Smoke.throwables.LowkeyLatte or 0, tostring(alive(s14Smoke)))
	say("S15 dodge: throw ok=%s; bot held still until the throw (moved %.1f studs from spawn by then, want ~0), %.0f studs from the landing point at the blast (want > 13), hp %.0f -> %s; CONTROL anchored dummy throw ok=%s, hp %.0f -> %.0f (want lower, or the test proves nothing)",
		tostring(s15.ok), s15.startPosition and flat(s15.startPosition - (c17 + Vector3.new(0, 3.2, 0))).Magnitude or -1,
		s15.distanceAtBlast or -1, s15.hpBefore or -1,
		alive(s15Bot) and string.format("%.0f", s15Bot.humanoid.Health) or "dead",
		tostring(s15.controlOk), s15.controlHpBefore or -1, s15Control.humanoid.Health)
else
	say("S13-S15 skipped: this build has no ProjectileService")
end

statsDelta(statsBefore, statsSnapshot(), 24, "scenarios (13 bots)")

BotService.Clear()
task.wait(1)

-- Second duel block, reloads on.
MatchConfig.BotReload = true
local duelsOn = spawnDuels(10, "CrocodiloRifle")
local popperOn = spawnDuels(21, "PocketPopper")
task.wait(1)
BotService.Start()
local duelStart = os.clock()
while os.clock() - duelStart < 24 do
	task.wait(0.2)
	sampleDuels(duelsOn, os.clock() - duelStart)
	sampleDuels(popperOn, os.clock() - duelStart)
end
reportDuels("reload ON", duelsOn)
reportDuels("reload ON", popperOn)

BotService.Clear()
if arena then
	arena:Destroy()
end
-- Clear() stops the think loop by flag; wait out a tick so a Start() straight after can't find the
-- old loop still awake.
task.wait(1)

--------------------------------------------------------------------------------
-- Free roam
--------------------------------------------------------------------------------

-- The vault/pane warning's harness tell: BreakPane is a no-op inside MovementService until
-- Bootstrap.server wires it, so its source file says whether a probe could ever break a pane.
do
	local okInfo, source = pcall(debug.info, MovementService and MovementService.BreakPane or function() end, "s")
	say("harness tell for the vault/pane warning: MovementService.BreakPane comes from %s (MovementService = the default no-op, Bootstrap.server = wired); CombatService.DamageDestructible set = %s",
		okInfo and tostring(source) or "?", tostring(CombatService.DamageDestructible ~= nil))
end

local spots = info.dropSpots or {}
local roam = BotService.Spawn(FREE_ROAM_BOTS, function(index)
	local spot = spots[(index - 1) % math.max(1, #spots) + 1] or Vector3.zero
	local angle = index * 2.399963
	local reach = 18 + (index * 7) % 23
	local x, z = spot.X + math.cos(angle) * reach, spot.Z + math.sin(angle) * reach
	return CFrame.new(x, MapGenerator.GroundHeightAt(x, z) + 5, z)
end, function() end)
say("free roam: %d bots spawned over %d drop spots", #roam, #spots)
do
	local claimed, checked = 0, 0
	for _, bot in ipairs(roam) do
		local root = rootOf(bot)
		if root then
			checked += 1
			local ok, auto = pcall(function()
				return root:GetNetworkOwnershipAuto()
			end)
			if ok and auto == false then
				claimed += 1
			end
		end
	end
	say("network ownership: %d of %d bot roots claimed by the server (want all; automatic ownership hands bots to nearby players)%s", claimed, checked,
		BotService.ClaimError and ("; last claim error: " .. tostring(BotService.ClaimError)) or "; no claim error recorded")
	-- Ask one real bot directly. The recorded error can come from the anchored dummies this probe
	-- spawns, whose reason has nothing to do with the bots in a match.
	local first = roam[1] and rootOf(roam[1])
	if first then
		local okSet, setErr = pcall(first.SetNetworkOwner, first, nil)
		local okRead, auto = pcall(function()
			return first:GetNetworkOwnershipAuto()
		end)
		say("network ownership, asked of one live bot: SetNetworkOwner ok=%s%s; GetNetworkOwnershipAuto ok=%s value=%s",
			tostring(okSet), okSet and "" or (" err=" .. tostring(setErr)), tostring(okRead), tostring(auto))
	end
	-- The error says "anchored, or welded to something anchored", so name the part rather than guess.
	local sample = roam[1] and roam[1].character
	if sample then
		local anchored, welds = {}, {}
		for _, d in ipairs(sample:GetDescendants()) do
			if d:IsA("BasePart") and d.Anchored then
				table.insert(anchored, d:GetFullName())
			elseif d:IsA("WeldConstraint") then
				local a, b = d.Part0, d.Part1
				if (a and a.Anchored) or (b and b.Anchored) then
					table.insert(welds, string.format("%s <-> %s", a and a.Name or "?", b and b.Name or "?"))
				end
			end
		end
		say("anchored parts on a bot: %s; welds touching an anchored part: %s",
			#anchored > 0 and table.concat(anchored, ", ") or "none",
			#welds > 0 and table.concat(welds, ", ") or "none")
	end
end

local unarmedDeaths = 0
-- Where and in what a bot is when it reads as swimming or airborne: pin_run14 showed 12.5% / 14% of
-- samples in those states on a map that is 0.6% water, so the cause is not "more water". Each such
-- sample records the terrain material under the root, the humanoid state, crouch, and a coarse cell.
local wetSamples = { count = 0, materials = {}, states = {}, crouched = 0, cells = {} }
local wetParams = RaycastParams.new()
wetParams.FilterType = Enum.RaycastFilterType.Include
wetParams.FilterDescendantsInstances = { workspace.Terrain }
wetParams.IgnoreWater = false
local deaths = { storm = 0, shot = 0, fall = 0, other = 0 }
local diedAt = {}
for _, bot in ipairs(roam) do
	bot.humanoid.Died:Connect(function()
		diedAt[bot] = os.clock()
		if not bot.weapon then
			unarmedDeaths += 1
		end
		local root = rootOf(bot)
		-- Shot means hit within the last 1.5 s. (GetLastAttacker remembers 12 s, which counted storm deaths
		-- of anyone shot earlier as shot.)
		local recentlyHit = lastHitAt[bot] and os.clock() - lastHitAt[bot] <= 1.5
		if root and root.Position.Y < MapGenerator.GroundHeightAt(root.Position.X, root.Position.Z) - 25 then
			deaths.fall += 1
		elseif recentlyHit then
			deaths.shot += 1
		elseif root and StormService.IsOutside(root.Position) then
			deaths.storm += 1
		else
			deaths.other += 1
		end
	end)
end

task.wait(1)
StormService.SetSpeed(STORM_SPEED)
StormService.Start(info.radius)
local roamBefore = statsSnapshot()
BotService.Start()
local roamStart = os.clock()

local R = {
	samples = 0, grind = 0, outside = 0, swimming = 0, airborne = 0, engaged = 0, idle = 0, looting = 0,
	stationaryNoReason = 0,
	queued = 0, queuedStill = 0, nearPairs = 0, alignedPairs = 0, queuedPairs = 0, queuedAligned = 0,
	unarmed = 0, unarmedLooting = 0, unarmedNoTarget = 0, unarmedUnderFire = 0,
}
local firstArmed = {}
-- How far a bot walked before it held a gun: the wandering-while-unarmed question is about distance
-- as much as time, since a bot milling about covers ground without getting anywhere.
local walkedBeforeArmed = {}
local travelled = {}
local lastSeenAt = {}
local lootSince = {}
local lootFixations = 0
local fixated = {}
local history = {}

while os.clock() - roamStart < FREE_ROAM_SECONDS do
	task.wait(0.5)
	local now = os.clock()
	local roamMoves = {}
	for _, bot in ipairs(roam) do
		if alive(bot) then
			local root = rootOf(bot)
			if root then
				R.samples += 1
				local humanoid = bot.humanoid
				local state = humanoid:GetState()
				local engaged = bot.facing and bot.facing.Enabled
				if grinding(bot) then
					R.grind += 1
				end
				if StormService.IsOutside(root.Position) then
					R.outside += 1
				end
				if state == Enum.HumanoidStateType.Swimming then
					R.swimming += 1
				end
				if humanoid.FloorMaterial == Enum.Material.Air then
					R.airborne += 1
				end
				if state == Enum.HumanoidStateType.Swimming or humanoid.FloorMaterial == Enum.Material.Air then
					wetSamples.count += 1
					local under = workspace:Raycast(root.Position, Vector3.new(0, -12, 0), wetParams)
					local material = under and under.Material.Name or "nothing within 12 studs"
					wetSamples.materials[material] = (wetSamples.materials[material] or 0) + 1
					local stateName = state.Name
					wetSamples.states[stateName] = (wetSamples.states[stateName] or 0) + 1
					if bot.crouching then
						wetSamples.crouched += 1
					end
					local cell = string.format("(%d,%d)", math.floor(root.Position.X / 100) * 100, math.floor(root.Position.Z / 100) * 100)
					wetSamples.cells[cell] = (wetSamples.cells[cell] or 0) + 1
				end
				if engaged then
					R.engaged += 1
				end
				if bot.lootTarget then
					R.looting += 1
				end
				if not bot.weapon then
					R.unarmed += 1
					if bot.lootTarget then
						R.unarmedLooting += 1
					else
						R.unarmedNoTarget += 1
					end
					if bot.threat and now - bot.threat.at < 3 then
						R.unarmedUnderFire += 1
					end
				end
				local previous = lastSeenAt[bot]
				-- Waiting on a route with none in hand: the state Oliver sees as bots that cannot move.
				local nav = bot.nav
				local queuedNow = nav and (nav.request or nav.computing) and not nav.waypoints
				if queuedNow then
					R.queued += 1
					if previous and flat(root.Position - previous).Magnitude < 0.5 then
						R.queuedStill += 1
					end
				end
				if previous then
					travelled[bot] = (travelled[bot] or 0) + flat(root.Position - previous).Magnitude
					local step = flat(root.Position - previous)
					if step.Magnitude > 1 then
						roamMoves[bot] = { at = root.Position, dir = step.Unit, queued = queuedNow }
					end
				end
				lastSeenAt[bot] = root.Position
				if bot.weapon and not firstArmed[bot] then
					firstArmed[bot] = now - roamStart
					walkedBeforeArmed[bot] = travelled[bot] or 0
				end

				-- The same loot target for 25 s is a bot that can't reach it and hasn't given up.
				if bot.lootTarget then
					local entry = lootSince[bot]
					if not entry or entry.item ~= bot.lootTarget then
						lootSince[bot] = { item = bot.lootTarget, at = now }
					elseif now - entry.at > 25 and fixated[bot] ~= entry.item then
						fixated[bot] = entry.item
						lootFixations += 1
					end
				else
					lootSince[bot] = nil
				end

				-- Not fighting, not holding loot, not behind cover, and hasn't moved 4 studs in 5 s.
				local h = history[bot]
				if not h then
					h = {}
					history[bot] = h
				end
				table.insert(h, root.Position)
				if #h > 10 then
					table.remove(h, 1)
				end
				local busy = engaged or bot.lootHoldStart or (bot.coverUntil or 0) > now or bot.dropping
				if #h == 10 and not busy and flat(h[10] - h[1]).Magnitude < 4 then
					R.stationaryNoReason += 1
				end
			end
		end
	end
	for a, ma in pairs(roamMoves) do
		for b, mb in pairs(roamMoves) do
			if a ~= b and flat(ma.at - mb.at).Magnitude < 30 then
				R.nearPairs += 1
				local aligned = ma.dir:Dot(mb.dir) > 0.94
				if aligned then
					R.alignedPairs += 1
				end
				-- Both waiting on a route: this is the mill's own heading spread, not the map's.
				if ma.queued and mb.queued then
					R.queuedPairs += 1
					if aligned then
						R.queuedAligned += 1
					end
				end
			end
		end
	end
end

local elapsed = os.clock() - roamStart
local armedTimes = {}
for _, bot in ipairs(roam) do
	if firstArmed[bot] then
		table.insert(armedTimes, firstArmed[bot])
	end
end
table.sort(armedTimes)
local function pct(n)
	return R.samples > 0 and 100 * n / R.samples or 0
end
local shots, hits, damage = 0, 0, 0
for _, bot in ipairs(roam) do
	shots += shotsBy[bot] or 0
	for _, amount in pairs(dealtBy[bot] or {}) do
		damage += amount
	end
end

say("free roam %.0fs, storm x%d: %d/%d alive at end; deaths storm %d, shot %d, fall %d, other %d",
	elapsed, STORM_SPEED, BotService.Count(), #roam, deaths.storm, deaths.shot, deaths.fall, deaths.other)
say("free roam behaviour (%% of living bot-samples): grinding %.1f, outside storm %.1f, swimming %.1f, airborne %.1f, engaged %.1f, chasing loot %.1f, stationary with no reason %.1f",
	pct(R.grind), pct(R.outside), pct(R.swimming), pct(R.airborne), pct(R.engaged), pct(R.looting), pct(R.stationaryNoReason))
say("free roam while a route is queued: %d bot-samples queued with no route in hand, %.1f%% of them stationary (under 0.5 studs in 0.5 s: the frozen look), mill legs %s; near pairs both walking %d, %.0f%% heading within 20 degrees (#125; independent headings would give about 11%%); near pairs BOTH WAITING and walking %d, %.0f%% aligned (the mill's own spread)",
	R.queued, R.queued > 0 and 100 * R.queuedStill / R.queued or 0, tostring((mod("BotNav").Stats or {}).mills), R.nearPairs / 2,
	R.nearPairs > 0 and 100 * R.alignedPairs / R.nearPairs or 0, R.queuedPairs / 2,
	R.queuedPairs > 0 and 100 * R.queuedAligned / R.queuedPairs or 0)
say("free roam loot: %d/%d armed; time to first gun median %s, 90th %s; loot fixations >25 s: %d",
	#armedTimes, #roam, armedTimes[1] and string.format("%.1fs", armedTimes[math.max(1, math.ceil(#armedTimes * 0.5))]) or "-",
	armedTimes[1] and string.format("%.1fs", armedTimes[math.max(1, math.ceil(#armedTimes * 0.9))]) or "-", lootFixations)
say("free roam combat: %d shots, %.0f damage dealt by bots", shots, damage)
do
	local function top(map, n)
		local rows = {}
		for key, count in pairs(map) do
			table.insert(rows, { key = key, count = count })
		end
		table.sort(rows, function(a, b)
			return a.count > b.count
		end)
		local parts = {}
		for index = 1, math.min(n, #rows) do
			table.insert(parts, string.format("%s %d", rows[index].key, rows[index].count))
		end
		return table.concat(parts, ", ")
	end
	say("free roam swimming/airborne samples %d: under the root %s; humanoid state %s; crouched in %d; top 100-stud cells %s",
		wetSamples.count, top(wetSamples.materials, 4), top(wetSamples.states, 4), wetSamples.crouched, top(wetSamples.cells, 5))
end
say("free roam unarmed: %d bot-samples (heading for loot %d, NO LOOT TARGET %d -- that is the wandering-while-unarmed case, under fire %d); %d bots died unarmed",
	R.unarmed, R.unarmedLooting, R.unarmedNoTarget, R.unarmedUnderFire, unarmedDeaths)
do
	local walks = {}
	for _, bot in ipairs(roam) do
		if walkedBeforeArmed[bot] then
			table.insert(walks, walkedBeforeArmed[bot])
		end
	end
	table.sort(walks)
	local function at(share)
		return #walks > 0 and string.format("%.0f", walks[math.max(1, math.ceil(#walks * share))]) or "-"
	end
	say("free roam distance walked before holding a gun: median %s studs, 90th %s, worst %s (over %d bots that armed); far-reach searches (nothing within 320 studs, went for the nearest anywhere) %d",
		at(0.5), at(0.9), at(1), #walks, (BotService.Stats and BotService.Stats.lootFarReach) or -1)
end
statsDelta(roamBefore, statsSnapshot(), elapsed, string.format("free roam (%d bots)", #roam))

BotService.Clear()
StormService.Stop()
LootService.Clear()
MapGenerator.Clear()
say("shots fired by a bot mid-climb or mid-vault: %d (want 0)", shotsMidParkour)
-- The harness keeps the last 5,000 output lines. If this run produced more (an error storm, say),
-- the earliest results were evicted and a reader would take their absence for "not printed". Say so
-- in the last line, where a reader looks first, rather than leaving it to be inferred.
if #lines >= 4990 then
	say("LOG TRUNCATED: %d lines kept of more than that, earliest results evicted -- results VOID, fix the spam and re-run", #lines)
end
say("probe finished")
