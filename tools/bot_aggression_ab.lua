-- Bot aggression A/B (#75/#81): the same scenarios under three sets of dials, in one launch.
--
-- Run with: runtest.ps1 -Probe tools/bot_aggression_ab.lua -WaitSeconds 420
--
-- The in-launch dial A/B the bots tab designed as S27 (BUILT, NOT RUN, never in the tree), rebuilt
-- against today's BotService (THINK_SLICES, the timed first shot, cover, pushing). Everything prints
-- as [BRR_BotAB] lines. The variants only change MatchConfig numbers between rounds, so every round
-- runs the same code; "old dials" is therefore today's code with the old numbers, not the old build
-- (for that, tools/bot_probe.lua's S10/S12 on the old build: 0.83 s front / 2.09 s behind, duels
-- 3.1-4.9 s). On today's code even the old 0.28 reaction is a real 0.28 s (the timed first shot), so
-- `old` shows what the NUMBERS change, and the old build what the whole change did.
--
--   shipped   what MatchConfig says now
--   old       0.28 reaction, 1.2 rear notice, 70 studs, retreat 26, hunt 6 s, flee 0.8, push 0.35/0.5
--   close45   shipped but fighting at 45 studs, the S27 candidate (more lethal through the falloff)
--
-- Per variant: FLANK (first shot at a dummy appearing 30 studs in front of / behind a bot anchored so
-- it can't turn, 4 trials each), PEEK (a dummy that was behind a wall steps into view: the wall is
-- removed), DUEL (three rifle pairs 60 studs apart: first shot, distance fought at, time to finish,
-- hits per shot) and CHASE (the dummy vanishes mid-fight: how long the bot hunts before giving up).
--
-- Judge hits/shot AGAINST the distance fought at: closing in raises hits/shot through the distance
-- falloff (base chance 0.42 at 70 studs, 0.49 at 55, 0.53 at 45) with the aim itself unchanged. If
-- `shipped` hits/shot is up much more than that on `old`, something other than distance moved.
-- Aim is never dialled here (BotAccuracy*, BotDamageScale, BotBurstRest stay as they are).
--
-- Offline companion: tools/bot_aggression_check.py models the flank and peek times from the source.
-- Its predictions to compare with FLANK: shipped 0.26 s front / 1.19 s behind (true times, mean).

local MAP_ID = "SahurSprings"
local TRIALS = 4
local ROUND_SECONDS = 22

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_BotAB] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)
say("run mode: IsRunning %s", tostring(RunService:IsRunning()))

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end

local MapGenerator = mod("MapGenerator")
local LootService = mod("LootService")
local CombatService = mod("CombatService")
mod("DestructibleService")
local BotService = mod("BotService")
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))

--------------------------------------------------------------------------------
-- Variants
--------------------------------------------------------------------------------

local DIALS = {
	"BotReactionTime", "BotRearNoticeTime", "BotEngagePreferred", "BotRetreatHealth", "BotMemorySeconds",
	"BotCoverHealth", "BotFleeHealth", "BotPushTargetBelow", "BotPushHealthAbove",
}
local shipped = {}
for _, key in ipairs(DIALS) do
	shipped[key] = MatchConfig[key]
end
local function variant(overrides)
	local v = table.clone(shipped)
	for key, value in pairs(overrides) do
		v[key] = value
	end
	return v
end
local VARIANTS = {
	{ name = "shipped", dials = variant({}) },
	{ name = "old", dials = variant({
		BotReactionTime = 0.28, BotRearNoticeTime = 1.2, BotEngagePreferred = 70, BotRetreatHealth = 26,
		BotMemorySeconds = 6, BotFleeHealth = 0.8, BotPushTargetBelow = 0.35, BotPushHealthAbove = 0.5,
	}) },
	{ name = "close45", dials = variant({ BotEngagePreferred = 45 }) },
}
-- Aim must be the same in every round; printed so a run that says otherwise is void.
local AIM = string.format("near %s far %s falloff %s damage %s burst rest %s", tostring(MatchConfig.BotAccuracyNear),
	tostring(MatchConfig.BotAccuracyFar), tostring(MatchConfig.BotAccuracyFalloff), tostring(MatchConfig.BotDamageScale),
	tostring(MatchConfig.BotBurstRest))

--------------------------------------------------------------------------------
-- Taps (wall clock: os.clock is CPU time in Roblox)
--------------------------------------------------------------------------------

local firstShotAt, shotsBy, hitsBy = {}, {}, {}
local realBroadcast = CombatService.BroadcastShot
CombatService.BroadcastShot = function(shooter, origin, endPoints, rarity)
	shotsBy[shooter] = (shotsBy[shooter] or 0) + 1
	firstShotAt[shooter] = firstShotAt[shooter] or tick()
	return realBroadcast(shooter, origin, endPoints, rarity)
end
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, weaponId, headshot)
	local dealt = realDeal(attacker, victim, amount, weaponId, headshot)
	if attacker and (dealt or 0) > 0 then
		hitsBy[attacker] = (hitsBy[attacker] or 0) + 1
	end
	return dealt
end

--------------------------------------------------------------------------------
-- Helpers (as tools/bot_probe.lua)
--------------------------------------------------------------------------------

local function rootOf(bot)
	return bot and bot.character and bot.character:FindFirstChild("HumanoidRootPart")
end

local function alive(bot)
	return bot and bot.humanoid and bot.humanoid.Health > 0 and bot.character and bot.character.Parent ~= nil
end

local function spawnBot(cframe)
	return BotService.Spawn(1, function()
		return cframe
	end, function() end)[1]
end

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

local arena = nil
local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Concrete
	if not arena then
		arena = Instance.new("Model")
		arena.Name = "BRR_BotABArena"
		arena.Parent = workspace:WaitForChild("Map")
	end
	part.Parent = arena
	return part
end

local ARENA_Y, ARENA_X, PAD_SPACING = 1600, 3400, 700
local function pad(index)
	local c = Vector3.new(ARENA_X + index * PAD_SPACING, ARENA_Y, 3400)
	block("Pad" .. index, Vector3.new(240, 2, 240), CFrame.new(c - Vector3.new(0, 1, 0)))
	return c
end
local function facing(c, offset, toward)
	local at = c + offset + Vector3.new(0, 3.2, 0)
	return CFrame.lookAt(at, c + toward + Vector3.new(0, 3.2, 0))
end

local function mean(list)
	if #list == 0 then
		return nil
	end
	local sum = 0
	for _, v in ipairs(list) do
		sum += v
	end
	return sum / #list
end
local function fmt(v, unit)
	return v and string.format("%.2f%s", v, unit or "") or "none"
end

--------------------------------------------------------------------------------
-- Map (BotService reads the storm and the map; the pads sit far outside it)
--------------------------------------------------------------------------------

say("building map %s", MAP_ID)
local info = MapGenerator.Build(MAP_ID)
LootService.Populate(info)
task.wait(4)
CombatService.SetEnabled(true)
say("aim for every round: %s", AIM)

--------------------------------------------------------------------------------
-- One round
--------------------------------------------------------------------------------

local function round(v)
	for key, value in pairs(v.dials) do
		MatchConfig[key] = value
	end
	table.clear(firstShotAt)
	table.clear(shotsBy)
	table.clear(hitsBy)
	if arena then
		arena:Destroy()
		arena = nil
	end

	local padIndex = 0
	local function nextPad()
		padIndex += 1
		return pad(padIndex)
	end

	-- FLANK and PEEK: shooters placed now, targets later.
	local flank = {}
	for trial = 1, TRIALS do
		for _, side in ipairs({ "front", "behind", "peek" }) do
			local c = nextPad()
			local bot = spawnBot(facing(c, Vector3.zero, Vector3.new(0, 0, 50)))
			arm(bot, "CrocodiloRifle")
			rootOf(bot).Anchored = true
			local row = { side = side, bot = bot, c = c, trial = trial }
			if side == "peek" then
				-- Hidden from the start, so the bot has a cached "can't see them" row when it opens.
				row.wall = block("PeekWall", Vector3.new(16, 14, 2), CFrame.new(c + Vector3.new(0, 7, 15)))
				row.dummy = spawnDummy(CFrame.new(c + Vector3.new(0, 3.2, 30)))
			end
			table.insert(flank, row)
		end
	end

	-- DUEL: three rifle pairs, 60 studs apart.
	local duels = {}
	for _ = 1, 3 do
		local c = nextPad()
		local a = spawnBot(facing(c, Vector3.new(0, 0, -30), Vector3.new(0, 0, 30)))
		local b = spawnBot(facing(c, Vector3.new(0, 0, 30), Vector3.new(0, 0, -30)))
		arm(a, "CrocodiloRifle")
		arm(b, "CrocodiloRifle")
		table.insert(duels, { a = a, b = b, gaps = {} })
	end

	-- CHASE: a tough dummy 40 studs off, which vanishes 4 s in.
	local cc = nextPad()
	local chaser = spawnBot(facing(cc, Vector3.zero, Vector3.new(0, 0, 40)))
	arm(chaser, "CrocodiloRifle")
	local quarry = spawnDummy(CFrame.new(cc + Vector3.new(0, 3.2, 40)))
	quarry.humanoid.MaxHealth = 100000
	quarry.humanoid.Health = 100000
	local chase = { vanishedAt = nil, gaveUpAt = nil }

	task.wait(2)
	BotService.Start()
	local start = tick()

	-- Targets appear 3 s in, each trial offset by up to one think so the phases differ.
	for _, row in ipairs(flank) do
		task.delay(3 + (row.trial - 1) * 0.067 + math.random() * 0.1, function()
			row.at = tick()
			if row.side == "peek" then
				row.wall:Destroy()
			else
				local z = row.side == "front" and 30 or -30
				row.dummy = spawnDummy(CFrame.new(row.c + Vector3.new(0, 3.2, z)))
			end
		end)
	end

	while tick() - start < ROUND_SECONDS do
		task.wait(0.1)
		local t = tick() - start
		for _, duel in ipairs(duels) do
			if not duel.endedAt then
				if alive(duel.a) and alive(duel.b) then
					table.insert(duel.gaps, (rootOf(duel.a).Position - rootOf(duel.b).Position).Magnitude)
				else
					duel.endedAt = t
				end
			end
		end
		if not chase.vanishedAt and t >= 4 then
			chase.vanishedAt = t
			chase.shotBefore = shotsBy[chaser] or 0
			rootOf(quarry).CFrame = CFrame.new(cc + Vector3.new(0, -400, 0))
		elseif chase.vanishedAt and not chase.gaveUpAt and alive(chaser) and chaser.memory == nil and chaser.target == nil then
			chase.gaveUpAt = t
		end
	end

	-- Report.
	local times = { front = {}, behind = {}, peek = {} }
	local never = { front = 0, behind = 0, peek = 0 }
	for _, row in ipairs(flank) do
		local shot = firstShotAt[row.bot]
		if row.at and shot and shot >= row.at then
			table.insert(times[row.side], shot - row.at)
		else
			never[row.side] += 1
		end
	end
	say("%s FLANK first shot (mean of %d): front %s, behind %s, peek %s; never %d/%d/%d", v.name, TRIALS,
		fmt(mean(times.front), "s"), fmt(mean(times.behind), "s"), fmt(mean(times.peek), "s"),
		never.front, never.behind, never.peek)

	local over, gaps, shots, hits, firsts = {}, {}, 0, 0, {}
	for _, duel in ipairs(duels) do
		if duel.endedAt then
			table.insert(over, duel.endedAt)
		end
		local g = mean(duel.gaps)
		if g then
			table.insert(gaps, g)
		end
		for _, bot in ipairs({ duel.a, duel.b }) do
			shots += shotsBy[bot] or 0
			hits += hitsBy[bot] or 0
			if firstShotAt[bot] then
				table.insert(firsts, firstShotAt[bot] - start)
			end
		end
	end
	say("%s DUEL: first shot %s after start, fought at %s studs, over in %s (%d/3 finished), hits/shot %s (%d/%d)",
		v.name, fmt(mean(firsts), "s"), fmt(mean(gaps)), fmt(mean(over), "s"), #over,
		shots > 0 and string.format("%.3f", hits / shots) or "none", hits, shots)
	say("%s CHASE: target gone at %s, hunted until %s (%s s; model BotMemorySeconds %s + the walk), shots before %d",
		v.name, fmt(chase.vanishedAt, "s"), fmt(chase.gaveUpAt, "s"),
		(chase.vanishedAt and chase.gaveUpAt) and string.format("%.1f", chase.gaveUpAt - chase.vanishedAt) or "never",
		tostring(v.dials.BotMemorySeconds), chase.shotBefore or 0)
	say("%s STATS (running totals): timed first shots %s, sight checks %s", v.name, tostring(BotService.Stats and BotService.Stats.quickShots),
		tostring(BotService.Stats and BotService.Stats.sightChecks))

	BotService.Clear()
	task.wait(1)
end

for _, v in ipairs(VARIANTS) do
	say("round %s: %s", v.name, (function()
		local parts = {}
		for _, key in ipairs(DIALS) do
			table.insert(parts, key .. "=" .. tostring(v.dials[key]))
		end
		return table.concat(parts, " ")
	end)())
	local ok, err = pcall(round, v)
	if not ok then
		say("round %s FAILED: %s", v.name, tostring(err))
		pcall(BotService.Clear)
	end
end
for key, value in pairs(shipped) do
	MatchConfig[key] = value
end
say("done")
