"""Behaviour check for the team modes' rewards (Oliver, 2026-09-24: "improve the rewards for team gamemodes
too"), without Studio.

    python3 tools/team_rewards_check.py            the checks, then every planted fault (each must be caught)
    python3 tools/team_rewards_check.py --no-plants

Runs the REAL ServerScriptService/Modules/GameMode.lua, RewardService.lua and ModeKingOfTheHill.lua and the
real ReplicatedStorage/Shared/MatchConfig.lua in a Lua interpreter (lupa), with the rest of the game mocked:
players, bots, teams, the payout sinks (coins, pass XP, crates, quests) and a clock. The mode's own loops
run: task.spawn / task.wait / task.delay are a scheduler the check steps through time, so the Objective
Capture tick, the participation checks and the respawn timers are the shipped code, not copies.

Matches it plays, and what it holds the code to (every one an invariant the code must keep forever):
  win     Team Deathmatch won: the kill line stops at the cap (a real player's kill first), multi-kills,
          revenge and assists are counted from what happened (and a hit too small, or too old, is no
          assist); the best player on the side is MVP; the lines sum to the coins and XP paid, a 2x pass
          included; the crate is the win's; the team quests move.
  afk     A player who stood still all match (and whose respawn teleport is not movement) gets the afk
          line only: no crate, no win pay, no MVP, no quests.
  draw / loss   the right result line and crate.
  koth    Objective Capture: one capture per change of hands (not per tick), time on an owned objective
          (contested included) paid up to its cap, a kill on your objective is a defend and one off it is not.
  caps    every line holds its cap however much is done.
  mvp     a bot that out-performs the player takes MVP from them; the pick survives the teams being torn
          down before the payout (MatchService pays after StopWorld).
  live    MatchService's live kill call (RewardService.AwardKill at killScale) pays nothing and still counts.
  streak  the team streak's window, step pay and labels are MatchService's own.
  finish  the kill that reaches the score target (FinishNow, synchronously) is already on the killer's
          ledger when the match hands over to the payout.
  bonus   TEAM BONUS across a run of matches: the first win of the day pays once (Epic Crate included) and
          again the next UTC day; consecutive wins pay a growing win streak, capped at maxSteps, ended by a
          loss and by an idle match; the milestone cosmetics unlock at their win counts, once each, never
          sold (no price, left out of CosmeticData.OfKind); bonusCoins is the sum of the gold lines.

Not covered: the real MatchService calling in (its finishMatch reads RankOf before StopWorld and AwardResult
after, which is what this replays), CombatService.DealDamage's order of Died and the damage listeners (the
check fires the listener directly), and anything drawn (tools/team_rewards_layout_check.py).
"""
import os
import re
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

FILES = {
    "MatchConfig": "ReplicatedStorage/Shared/MatchConfig.lua",
    "QuestData": "ReplicatedStorage/Shared/QuestData.lua",
    "CosmeticData": "ReplicatedStorage/Shared/CosmeticData.lua",
    "RewardService": "ServerScriptService/Modules/RewardService.lua",
    "GameMode": "ServerScriptService/Modules/GameMode.lua",
    "ModeKingOfTheHill": "ServerScriptService/Modules/ModeKingOfTheHill.lua",
}


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def luau_to_lua(source):
    # Compound assignment is the only Luau-only syntax these files use.
    return re.sub(r"^(\s*)([\w.\[\]\"]+) (\.\.|[-+*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def match_service_streak():
    """MatchService's own streak numbers, read from its source: the window, the cap, the labels, the pay."""
    text = read("ServerScriptService/Modules/MatchService.lua")
    window = int(re.search(r"^local STREAK_WINDOW = (\d+)", text, re.M).group(1))
    top = int(re.search(r"^local STREAK_MAX = (\d+)", text, re.M).group(1))
    block = re.search(r"^local STREAK_LABELS = \{(.*?)^\}", text, re.M | re.S).group(1)
    labels = {int(k): v for k, v in re.findall(r'\[(\d+)\] = "([^"]+)"', block)}
    pay = re.search(r"math\.min\(streak\.count, STREAK_MAX\) \* (\d+) - (\d+)", text)
    return window, top, labels, int(pay.group(1)), int(pay.group(2))


WORLD = r"""
local sources, moveStuds = ...
local W = { failures = {}, notes = {}, fired = {}, quests = {}, crates = {} }

-- Luau's table library additions.
table.clone = function(t) local c = {}; for k, v in pairs(t) do c[k] = v end; return setmetatable(c, getmetatable(t)) end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
function warn(msg) table.insert(W.failures, "warn: " .. tostring(msg)) end

-- The clock and the scheduler: task.wait parks a coroutine until the clock reaches its wake time.
local clock = 0
local sleepers = {}
local function resumeSafely(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then table.insert(W.failures, "task error: " .. tostring(err) .. "\n" .. debug.traceback(co)) end
end
task = {
	spawn = function(fn, ...)
		local co = coroutine.create(fn)
		resumeSafely(co, ...)
		return co
	end,
	wait = function(t)
		local co = coroutine.running()
		table.insert(sleepers, { co = co, at = clock + (t or 0) })
		coroutine.yield()
		return t
	end,
	delay = function(t, fn, ...)
		local args = table.pack(...)
		return task.spawn(function() task.wait(t); fn(table.unpack(args, 1, args.n)) end)
	end,
}
task.defer = task.spawn
function W.advance(seconds)
	local target = clock + seconds
	while true do
		local best, index = nil, nil
		for i, s in ipairs(sleepers) do
			if s.at <= target and (not best or s.at < best.at) then best, index = s, i end
		end
		if not best then break end
		table.remove(sleepers, index)
		clock = math.max(clock, best.at)
		resumeSafely(best.co)
	end
	clock = target
end
function W.now() return clock end
DateTime = { now = function() return { UnixTimestampMillis = math.floor(clock * 1000 + 0.5) } end }

-- Datatypes.
local V3 = {}
V3.__index = function(self, key)
	if key == "Magnitude" then return math.sqrt(self.X ^ 2 + self.Y ^ 2 + self.Z ^ 2) end
	return nil
end
local function vec(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3) end
V3.__add = function(a, b) return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__mul = function(a, b) if type(a) == "number" then a, b = b, a end return vec(a.X * b, a.Y * b, a.Z * b) end
Vector3 = { new = vec }
W.vec = vec
local anyMT = {}
anyMT.__index = function() return function() return setmetatable({}, anyMT) end end
anyMT.__mul = function(a) return a end
anyMT.__add = function(a) return a end
local function any() return setmetatable({}, anyMT) end
CFrame = { new = any, Angles = any, lookAt = any }
Color3 = { fromRGB = any, new = any }
UDim2 = { fromOffset = any, fromScale = any, new = any }
UDim = { new = any }
RaycastParams = { new = function() return {} end }
Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end })
Instance = { new = function() return setmetatable({}, { __index = function() return function() end end }) end }
workspace = {
	Terrain = {},
	Raycast = function() return nil end,
	GetServerTimeNow = function() return clock end,
}

-- Tokens. A player is a table with a Character whose root position the check moves by hand.
local function character(position)
	local root = { Position = position }
	local humanoid = { Health = 100 }
	local ch = { Parent = true, root = root, humanoid = humanoid }
	function ch:FindFirstChildOfClass(class) return class == "Humanoid" and humanoid or nil end
	function ch:FindFirstChild(name) return name == "HumanoidRootPart" and root or nil end
	return ch
end
W.character = character
local players = {}
function W.player(name, team, position, coinPass)
	local p = { kind = "player", Name = name, Parent = true, coinPass = coinPass, xp = 0,
		data = { Stats = { matches = 0, kills = 0, wins = 0 }, SahurCoins = 0, Cosmetics = { owned = {} },
			Quests = { progress = {}, done = {}, weekProgress = {}, weekDone = {} } } }
	p.Character = character(position or vec(0, 0, 0))
	function p:SetAttribute() end
	function p:LoadCharacter() end
	W.teams[p] = team
	table.insert(players, p)
	W.participants[p] = true
	return p
end
function W.bot(name, team, position)
	local b = { kind = "bot", Name = name }
	b.Character = character(position or vec(500, 0, 500))
	W.teams[b] = team
	return b
end
function W.move(token, position) token.Character.root.Position = position end

W.teams = {}
W.participants = {}

-- Mocked modules.
local mocks = {}
mocks.GameModes = {
	TeamCount = 2,
	Modes = {
		BattleRoyale = { id = "BattleRoyale" },
		TeamDeathmatch = { id = "TeamDeathmatch", respawn = true, respawnDelay = 5, scoreTarget = 100000, timeLimit = 480, bounds = false },
		KingOfTheHill = { id = "KingOfTheHill", respawn = true, respawnDelay = 6, scoreTarget = 100000, timeLimit = 480, bounds = false },
	},
	Loadout = { items = {} },
	TeamName = function(i) return "Team" .. tostring(i) end,
	TeamColor = function() return any() end,
	OtherTeam = function(t) return 3 - t end,
	AllowsEvent = function() return true end,
}
mocks.GameModes.Get = function(id) return mocks.GameModes.Modes[id] end
mocks.GameModes.FromRotation = function() return mocks.GameModes.Modes.TeamDeathmatch end
mocks.Remotes = { Event = function(name)
	return {
		FireAllClients = function() end,
		FireClient = function(_, p, ...) table.insert(W.fired, { name = name, to = p, args = { ... } }) end,
	}
end }
mocks.ProgressionData = { Playtime = { MoveStuds = moveStuds } }
mocks.ObjectiveZone = {
	Radius = function() return 20 end,
	Height = function() return 10 end,
	RingSize = any,
	RingCFrame = any,
	Contains = function(_, point, position)
		return position ~= nil and math.sqrt((position.X - point.X) ^ 2 + (position.Z - point.Z) ^ 2) <= 20
	end,
}
mocks.ZFight = { FixTolerance = 0.01 }
mocks.BrainrotData = { CollectionBonus = {} }
mocks.ShopRotation = {}
mocks.BotService = { Spawn = function() end }
local damageListeners = {}
mocks.CombatService = { OnDamage = function(fn) table.insert(damageListeners, fn) end }
function W.damage(attacker, victim, amount)
	for _, fn in ipairs(damageListeners) do fn(attacker, victim, amount, "Gun", false, false) end
end
mocks.Combatants = {
	IsPlayer = function(t) return type(t) == "table" and t.kind == "player" end,
	IsBot = function(t) return type(t) == "table" and t.kind == "bot" end,
	GetName = function(t) return type(t) == "table" and t.Name or "?" end,
	GetUserId = function() return 0 end,
	GetRoot = function(t) return type(t) == "table" and t.Character and t.Character.root or nil end,
	All = function()
		local all = {}
		for token in pairs(W.teams) do
			if token.Character and not token.downed then all[token.Character] = token end
		end
		return all
	end,
	Unregister = function() end,
}
mocks.ModeTeams = {
	TeamOf = function(t) return W.teams[t] end,
	IsDowned = function(t) return type(t) == "table" and t.downed == true end,
	MarkDown = function(t) t.downed = true end,
	Setup = function() return vec(0, 0, 0), 1000 end,
	Arena = function() return vec(0, 0, 0), 1000 end,
	RefusePad = function() return false end,
	Teardown = function() W.teardowns = (W.teardowns or 0) + 1; table.clear(W.teams) end,
	Assign = function(t) W.teams[t] = W.teams[t] or 1; return W.teams[t] end,
	AssignTo = function(t, team) W.teams[t] = team end,
	Forget = function() end,
	PlaceAt = function() return true, nil, nil end,
	PlaceWithoutPad = function() return false end,
	GrantLoadout = function() end,
	GroundNear = function() return nil end,
	PickPad = function() return nil end,
	BaseOf = function() return nil end,
	PlacedTolerance = 150,
}
mocks.LootService = { CountNear = function() return {} end, BaseStock = {}, BaseRadius = 40, SeedAt = function() end }
mocks.StormService = { Stop = function() end, Start = function() end }
W.day = 20000
mocks.StateSync = { Notify = function() end, Push = function() end, CurrentDay = function() return W.day end }
mocks.QuestService = { Progress = function(p, stat, amount)
	if type(amount) ~= "number" or amount <= 0 then return end
	W.quests[p] = W.quests[p] or {}
	W.quests[p][stat] = (W.quests[p][stat] or 0) + amount
end }
mocks.PlayerData = { Get = function(p) return type(p) == "table" and p.data or nil end }
mocks.Monetization = { EarnCoins = function(p, amount)
	if type(amount) ~= "number" or amount <= 0 then return 0 end
	local granted = math.floor(amount * (p.coinPass and 2 or 1))
	p.data.SahurCoins = p.data.SahurCoins + granted
	return granted
end }
mocks.BattlePassService = { AddXp = function(p, amount) if amount > 0 then p.xp = p.xp + amount end end }
mocks.CrateService = { Give = function(p, crate, n) W.crates[p] = W.crates[p] or {}; table.insert(W.crates[p], crate) end }
mocks.GlobalBoardService = { SubmitWins = function() end }

local loaded = {}
local function folder()
	return { WaitForChild = function(_, name) return { __module = name } end }
end
local function load_(name)
	if loaded[name] ~= nil then return loaded[name] end
	if mocks[name] then loaded[name] = mocks[name]; return mocks[name] end
	local source = sources[name]
	if not source then error("no module " .. name) end
	local env = setmetatable({ script = { Parent = folder() } }, { __index = _G })
	local chunk, err = load(source, "@" .. name, "t", env)
	if not chunk then error("compile " .. name .. ": " .. tostring(err)) end
	loaded[name] = chunk()
	return loaded[name]
end
require = function(marker) return load_(marker.__module) end
local servicesByName = {
	Players = { PlayerRemoving = { Connect = function() end }, GetPlayers = function() return players end },
	RunService = { Heartbeat = {} },
	ReplicatedStorage = { WaitForChild = function() return folder() end },
}
game = { GetService = function(_, name) return servicesByName[name] end }

W.MatchConfig = load_("MatchConfig")
W.RewardService = load_("RewardService")
W.GameMode = load_("GameMode")
W.KOTH = load_("ModeKingOfTheHill")
W.CosmeticData = load_("CosmeticData")
W.GameMode.Bind({
	Finish = function() W.finished = true end,
	IsParticipant = function(p) return W.participants[p] == true end,
})
return W
"""

CHECKS = r"""
local W, streakWindow, streakMax, streakLabels, streakStep, streakBase = ...
local out = { failures = {}, notes = {}, counts = {} }
local function fail(msg) table.insert(out.failures, msg) end
local function check(cond, msg) out.counts.checks = (out.counts.checks or 0) + 1; if not cond then fail(msg) end end
local GM, RS, MC = W.GameMode, W.RewardService, W.MatchConfig
local T = MC.TeamModeRewards
local I = GM.Internal
local vec = W.vec

local function lineOf(reward, id)
	for _, line in ipairs(reward.lines or {}) do if line.id == id then return line end end
	return nil
end
-- The card's lines sum to its totals, and the totals are what actually landed on the profile.
local function sums(reward, who, player)
	local coins, xp = 0, 0
	for _, line in ipairs(reward.lines or {}) do coins = coins + line.coins; xp = xp + line.xp end
	check(coins == reward.coins, string.format("%s: lines sum to %d coins, the card says %d", who, coins, reward.coins))
	check(xp == reward.xp, string.format("%s: lines sum to %d XP, the card says %d", who, xp, reward.xp))
	check(player.data.SahurCoins == reward.coins, string.format("%s: %d coins landed, the card says %d", who, player.data.SahurCoins, reward.coins))
	check(player.xp == reward.xp, string.format("%s: %d XP landed, the card says %d", who, player.xp, reward.xp))
end
-- Plays out the end the way MatchService.finishMatch does: ranks, then StopWorld, then the payout.
local function finish(mode, list)
	local ranks = {}
	for _, p in ipairs(list) do ranks[p] = mode.RankOf(p) end
	mode.StopWorld()
	local rewards = {}
	for _, p in ipairs(list) do rewards[p] = mode.AwardResult(p, ranks[p]) end
	return rewards, mode.Results()
end
local function start(id, mapInfo)
	W.GameMode.Resolve(1, id)
	local mode = W.GameMode.Current()
	mode.StartWorld(mapInfo or { radius = 500 })
	return mode
end
local kills = 0
local function killBot(mode, killer, team)
	kills = kills + 1
	local bot = W.bot("Bot" .. kills, team)
	mode.OnDeath(bot, killer, "Gun")
	return bot
end

-- ======================================================================== win + afk (Team Deathmatch)
do
	local mode = start("TeamDeathmatch")
	local p1 = W.player("Ace", 1, vec(0, 0, 0), true)
	local p2 = W.player("Idle", 1, vec(50, 0, 50))
	local enemy = W.player("Enemy", 2, vec(-200, 0, 0))
	local mate = W.bot("MateBot", 1)
	local x = 0
	local function walk(p) x = x + 10; W.move(p, vec(x, 0, 0)) end
	-- Two kills 3 s apart then one 4 s later: a double (50) and a triple (100).
	walk(p1); killBot(mode, p1, 2); W.advance(3); killBot(mode, p1, 2); W.advance(4); killBot(mode, p1, 2)
	local banners = 0
	for _, f in ipairs(W.fired) do if f.name == "KillStreak" and f.to == p1 then banners = banners + 1 end end
	check(banners == 2, "a double and a triple fire two streak banners, got " .. banners)
	-- The enemy kills Ace, Ace respawns and kills the enemy back: revenge, and a real player's kill.
	W.advance(10); walk(p1)
	mode.OnDeath(p1, enemy, "Gun"); p1.downed = nil
	W.advance(5); mode.OnRespawn(p1, p1.Character); W.move(p1, vec(-300, 0, 300))
	W.advance(10); walk(p1)
	mode.OnDeath(enemy, p1, "Gun"); enemy.downed = nil
	-- Assists: 30 damage then a team-mate's kill 3 s later counts; 10 damage does not; 40 damage 12 s
	-- before the kill does not.
	local a = W.bot("AssistMe", 2); W.damage(p1, a, 30); W.advance(3); mode.OnDeath(a, mate, "Gun")
	local b = W.bot("Scratch", 2); W.damage(p1, b, 10); W.advance(1); mode.OnDeath(b, mate, "Gun")
	local c = W.bot("Stale", 2); W.damage(p1, c, 40); W.advance(12); mode.OnDeath(c, mate, "Gun")
	-- More bot kills, 10 s apart (inside the 8-minute limit) (no streaks), to one past the cap: cap bots and the one player.
	for i = 1, T.kill.cap - 3 do W.advance(10); walk(p1); W.move(enemy, vec(-200, 0, i * 10)); killBot(mode, p1, 2) end
	-- Idle: killed once and respawned somewhere else. The teleport must not read as moving.
	mode.OnDeath(p2, enemy, "Gun"); p2.downed = nil
	W.advance(6); mode.OnRespawn(p2, p2.Character); W.move(p2, vec(400, 0, -400))
	W.advance(60)
	local L1 = I.ledgers[p1]
	check(L1.playerKills == 1 and L1.botKills == T.kill.cap, string.format("Ace's kills %d player + %d bot, want 1 + %d", L1.playerKills, L1.botKills, T.kill.cap))
	check(L1.assists == 1, "assists: want exactly the 30-damage one, got " .. tostring(L1.assists))
	check(L1.revenges == 1, "revenge: want 1, got " .. tostring(L1.revenges))
	check(L1.streakCoins == 150, "multi-kills: a double and a triple pay 150, got " .. tostring(L1.streakCoins))
	local L2 = I.ledgers[p2]
	check(L2.activeSamples == 0, string.format("Idle was active in %d of %d checks (a respawn is not movement)", L2.activeSamples, L2.samples))
	check(L1.activeSamples >= L1.samples * 0.5, string.format("Ace was active in only %d of %d checks", L1.activeSamples, L1.samples))

	local rewards, results = finish(mode, { p1, p2, enemy })
	check((W.teardowns or 0) >= 1, "StopWorld tore the teams down before the payout, as in the game")
	local r1, r2, re = rewards[p1], rewards[p2], rewards[enemy]
	check(r1.outcome == "win" and r1.crate == T.win.crate, "Ace won: outcome " .. tostring(r1.outcome) .. ", crate " .. tostring(r1.crate))
	local kl = lineOf(r1, "kills")
	check(kl and kl.count == T.kill.cap, "kill line counts the cap " .. T.kill.cap .. ", got " .. tostring(kl and kl.count))
	check(kl and kl.coins == MC.CoinsPerKill + (T.kill.cap - 1) * MC.CoinsPerBotKill,
		"kill line pays the real player's kill first, then bots to the cap: " .. tostring(kl and kl.coins))
	check(r1.mvp == true and lineOf(r1, "mvp") ~= nil, "Ace out-did everyone on team 1 and is MVP")
	check(lineOf(r1, "coinPass") ~= nil, "Ace owns 2x SahurCoins: the doubling is a line of its own")
	sums(r1, "Ace", p1)
	local q = W.quests[p1] or {}
	check(q.teamMatches == 1 and q.teamWins == 1 and q.assists == 1 and q.mvp == 1,
		string.format("Ace's team quests: matches %s wins %s assists %s mvp %s", tostring(q.teamMatches), tostring(q.teamWins), tostring(q.assists), tostring(q.mvp)))
	-- The idle player: the afk line and nothing else, however well the side did.
	check(r2.afk == true and #r2.lines == 1 and r2.lines[1].coins == T.afk.coins and r2.lines[1].xp == T.afk.xp,
		"Idle is paid the afk line only, got " .. #r2.lines .. " line(s), " .. r2.coins .. " coins")
	check(r2.crate == nil and (W.crates[p2] == nil), "Idle gets no crate")
	check(r2.mvp == false, "Idle is never MVP")
	check(((W.quests[p2] or {}).teamMatches or 0) == 0, "Idle's team quests do not move")
	sums(r2, "Idle", p2)
	-- Enemy's two player kills are worth exactly the MVP floor (at least, not more than): team 2's MVP.
	check(2 * MC.CoinsPerKill >= T.mvp.minCoins, "fixture: two player kills reach the MVP floor")
	check(re.outcome == "loss" and re.crate == T.loss.crate and re.mvp == true, "Enemy lost but out-did every bot on team 2: loss crate, MVP")
	sums(re, "Enemy", enemy)
	check(#results.mvps == 2 and results.mvps[1].name == "Ace" and results.mvps[1].team == 1 and results.mvps[2].name == "Enemy",
		"the card names Ace as team 1's MVP and Enemy as team 2's")
end

-- ======================================================================== draw and loss
do
	local mode = start("TeamDeathmatch")
	local p = W.player("Even", 1, vec(0, 0, 0))
	local q = W.player("Odd", 2, vec(0, 0, 0))
	for i = 1, 8 do W.advance(15); W.move(p, vec(i * 10, 0, 0)); W.move(q, vec(0, 0, i * 10)) end
	local rewards = finish(mode, { p, q })
	check(rewards[p].outcome == "draw" and rewards[p].crate == T.draw.crate and lineOf(rewards[p], "result").coins == T.draw.coins,
		"no score either side: a draw, its crate and coins")
	sums(rewards[p], "Even", p)
end
do
	local mode = start("TeamDeathmatch")
	local winner = W.player("Up", 1, vec(0, 0, 0))
	local loser = W.player("Down", 2, vec(100, 0, 0))
	for i = 1, 8 do W.advance(15); W.move(winner, vec(i * 10, 0, 0)); W.move(loser, vec(100, 0, i * 10)) end
	killBot(mode, winner, 2)
	local rewards = finish(mode, { winner, loser })
	local r = rewards[loser]
	check(r.outcome == "loss" and r.crate == T.loss.crate and lineOf(r, "result").label == "Defeat" and lineOf(r, "result").coins == T.loss.coins,
		"the losing side: Defeat, the loss crate and coins")
	check(lineOf(r, "time") ~= nil and lineOf(r, "time").coins > 0, "a loss still pays time played")
	sums(r, "Down", loser)
end

-- ======================================================================== Objective Capture
do
	local mode = start("KingOfTheHill", { radius = 500, landmarks = { { X = 0, Z = 0 }, { X = 300, Z = 0 } } })
	check(W.KOTH.SiteCount() == 2, "two objectives built, got " .. W.KOTH.SiteCount())
	local p = W.player("Holder", 1, vec(0, 0, 0))
	local e = W.player("Raider", 2, vec(-600, 0, 0))
	-- A player on a point shifts about inside it; this steps the clock in 5 s steps, moving 6 studs each.
	local step = 0
	local function stay(token, cx, seconds)
		for _ = 1, seconds / 5 do
			step = step + 1
			W.move(token, vec(cx + (step % 2 == 0 and 6 or 0), 0, 0))
			W.advance(5)
		end
	end
	stay(p, 0, 100)   -- alone on A: one capture, 100 s held
	W.move(e, vec(5, 0, 0)); W.advance(20)   -- contested: still Holder's side's, still held
	W.move(e, vec(300, 0, 0)); W.advance(10) -- Raider takes B alone
	-- Raider back on A (Holder's) and killed there: a defend. Killed again off every objective: no defend.
	W.move(e, vec(3, 0, 0)); mode.OnDeath(e, p, "Gun"); e.downed = nil
	W.advance(7); W.move(e, vec(-600, 0, 0)); mode.OnDeath(e, p, "Gun"); e.downed = nil
	stay(p, 300, 200) -- Holder takes B back and holds it
	local L = I.ledgers[p]
	check(L.captures == 2, "Holder captured A once and B once: want 2 captures, got " .. tostring(L.captures))
	check((I.ledgers[e] or {}).captures == 1, "Raider captured B once, got " .. tostring((I.ledgers[e] or {}).captures))
	check(L.defends == 1, "one kill on Holder's objective is a defend, one off it is not: got " .. tostring(L.defends))
	check(L.holdSeconds >= 300, "Holder stood ~330 s on owned objectives, counted " .. tostring(L.holdSeconds))
	local rewards = finish(mode, { p, e })
	local hold = lineOf(rewards[p], "hold")
	check(hold and hold.count == T.hold.capSeconds, "time on objective is paid to its cap " .. T.hold.capSeconds .. ", got " .. tostring(hold and hold.count))
	check(lineOf(rewards[p], "defends") and lineOf(rewards[p], "defends").count == 1, "the defend is on the card")
	sums(rewards[p], "Holder", p)
end

-- ======================================================================== caps, straight through the breakdown
do
	local huge = { playerKills = 999, botKills = 999, assists = 999, revenges = 999, streakCoins = 99999, captures = 999,
		holdSeconds = 99999, defends = 999, activeSamples = 32, mvp = true }
	local lines, coins, xp = RS.TeamBreakdown(huge, "win", 1)
	local want = {
		kills = T.kill.cap, assists = T.assist.cap, revenge = T.revenge.cap, captures = T.capture.cap,
		hold = T.hold.capSeconds, defends = T.defend.cap,
	}
	local byId = {}
	for _, line in ipairs(lines) do byId[line.id] = line end
	for id, cap in pairs(want) do
		check(byId[id] and byId[id].count == cap, id .. " holds its cap " .. cap .. ", got " .. tostring(byId[id] and byId[id].count))
	end
	check(byId.streaks and byId.streaks.coins == T.streak.cap, "multi-kills hold their cap " .. T.streak.cap)
	check(byId.kills.coins == T.kill.cap * MC.CoinsPerKill, "all-player kills pay the player rate to the cap")
	local ceiling = T.win.coins + T.kill.cap * MC.CoinsPerKill + T.assist.cap * T.assist.coins + T.revenge.cap * T.revenge.coins
		+ T.streak.cap + T.capture.cap * T.capture.coins + T.hold.capSeconds * T.hold.coinsPerSecond + T.defend.cap * T.defend.coins
		+ T.mvp.coins + 32 * T.participation.sampleSeconds / 60 * T.participation.coinsPerMinute
	check(coins <= ceiling, "the total never passes the sum of the caps")
	local c2, x2 = 0, 0
	for _, line in ipairs(lines) do c2 = c2 + line.coins; x2 = x2 + line.xp end
	check(c2 == coins and x2 == xp, "the breakdown's own totals are its lines' sums")
	out.counts.maxMatch = coins
end

-- ======================================================================== a bot out-performs the player
do
	local mode = start("TeamDeathmatch")
	local p = W.player("Second", 1, vec(0, 0, 0))
	local star = W.bot("StarBot", 1)
	for i = 1, 6 do W.advance(20); W.move(p, vec(i * 10, 0, 0)); mode.OnDeath(W.player("Victim" .. i, 2), star, "Gun") end
	killBot(mode, p, 2); killBot(mode, p, 2)
	local rewards, results = finish(mode, { p })
	check(rewards[p].mvp == false and lineOf(rewards[p], "mvp") == nil, "StarBot's six kills beat Second's two: no MVP line for Second")
	check(#results.mvps >= 1 and results.mvps[1].name == "StarBot", "the card names StarBot as team 1's MVP")
end

-- ======================================================================== the live kill path and the streak's source
do
	local p = W.player("Live", 1, vec(0, 0, 0))
	RS.AwardKill(p, true, T.killScale)
	check(p.data.SahurCoins == 0 and p.xp == 0, "MatchService's live team kill pays nothing (it is paid on the card)")
	check(p.data.Stats.kills == 1 and (W.quests[p] or {}).kills == 1, "the live team kill still counts for stats and the kills quest")
	check(T.maxPaidKills >= T.kill.cap, "MatchService counts at least as many kills as the card pays")
	check(T.streak.windowSeconds == streakWindow, "team streak window " .. T.streak.windowSeconds .. " is MatchService's " .. streakWindow)
	check(T.streak.max == streakMax, "team streak top step is MatchService's")
	check(T.streak.coinsPerStep == streakStep and streakStep == streakBase, "team streak pays MatchService's step")
	for k, v in pairs(streakLabels) do
		check(I.streakLabels[k] == v, "streak label " .. k .. " is MatchService's '" .. v .. "'")
	end
	for k in pairs(I.streakLabels) do check(streakLabels[k] ~= nil, "no streak label MatchService lacks") end
end
-- ======================================================================== TEAM BONUS across matches
do
	local B = T.bonus
	local p = W.player("Runner", 1, vec(0, 0, 0))
	local function play(outcome, idle)
		local summary = { botKills = 3, activeSamples = idle and 0 or 30, samples = 30, afk = idle == true }
		local before = p.data.SahurCoins
		p.xp = 0
		W.crates[p] = nil
		local reward = RS.AwardTeamResult(p, outcome, outcome == "win" and 1 or 2, summary)
		p.data.SahurCoins = p.data.SahurCoins - before -- so sums() compares this match alone
		sums(reward, "Runner " .. outcome, p)
		p.data.SahurCoins = before + reward.coins
		local bonus = 0
		for _, line in ipairs(reward.lines) do if line.bonus then bonus = bonus + line.coins end end
		check(bonus == (reward.bonusCoins or 0), "bonusCoins is the sum of the TEAM BONUS lines")
		return reward
	end
	local r1 = play("win")
	check(lineOf(r1, "firstWin") ~= nil and r1.bonusCrate == B.firstWin.crate, "the day's first team win pays the first-win bonus and its crate")
	local given = table.concat(W.crates[p] or {}, ",")
	check(given == T.win.crate .. "," .. B.firstWin.crate, "the win's crate and the first win's both land: " .. given)
	check(lineOf(r1, "winStreak") == nil, "one win is not a streak")
	local r2 = play("win")
	check(lineOf(r2, "firstWin") == nil and r2.bonusCrate == nil, "the second win of the day is not the first")
	local s2 = lineOf(r2, "winStreak")
	check(s2 and s2.count == 2 and s2.coins == B.winStreak.coins, "two in a row: a one-step streak")
	local r3 = play("win")
	check(r3.lines and lineOf(r3, "unlock") ~= nil and p.data.Cosmetics.owned[B.milestones[1].cosmetic] == true,
		"the third team win unlocks " .. B.milestones[1].cosmetic)
	for _ = 1, 5 do play("win") end
	local r9 = play("win")
	local s9 = lineOf(r9, "winStreak")
	check(s9 and s9.count == 9 and s9.coins == B.winStreak.maxSteps * B.winStreak.coins, "a nine-win run pays maxSteps steps, no more")
	check(lineOf(r9, "unlock") == nil, "no cosmetic between milestones")
	local rl = play("loss")
	check(lineOf(rl, "winStreak") == nil and RS.TeamRecord(p.data).streak == 0, "a loss ends the run")
	play("win"); play("win")
	local ri = play("win", true)
	check(#ri.lines == 1 and ri.bonusCrate == nil and RS.TeamRecord(p.data).streak == 0, "an idle win pays no bonus and ends the run")
	local rn = play("win")
	check(lineOf(rn, "winStreak") == nil, "after an idle match the run starts again")
	p.data.Cosmetics.owned[B.milestones[2].cosmetic] = nil
	RS.TeamRecord(p.data).wins = B.milestones[2].wins - 1
	local r10 = play("win")
	check(lineOf(r10, "unlock") ~= nil and p.data.Cosmetics.owned[B.milestones[2].cosmetic], "win " .. B.milestones[2].wins .. " unlocks " .. B.milestones[2].cosmetic)
	local unlocks = 0
	for _ = 1, 3 do if lineOf(play("win"), "unlock") then unlocks = unlocks + 1 end end
	check(unlocks == 0, "an owned cosmetic is never unlocked again")
	W.day = W.day + 1
	local nd = play("win")
	check(lineOf(nd, "firstWin") ~= nil, "the next UTC day's first win pays again")
	-- The team cosmetics are real, priceless and out of every OfKind pool (crates, shop, bots, spin).
	local CD = W.CosmeticData
	for _, m in ipairs(B.milestones) do
		local item = CD.Get(m.cosmetic)
		check(item ~= nil and item.teamOnly == true and item.price == nil, m.cosmetic .. " is a priceless teamOnly cosmetic")
		if item then
			for _, id in ipairs(CD.OfKind(item.kind)) do check(id ~= m.cosmetic, m.cosmetic .. " is not in OfKind") end
		end
	end
end

-- ======================================================================== the winning kill (FinishNow)
-- The kill that reaches the score target ends the match synchronously (addScore -> FinishNow -> the host's
-- Finish, which is where MatchService's payout starts). That kill must already be on the killer's ledger.
do
	local mode = start("TeamDeathmatch")
	local closer = W.player("Closer", 1, vec(0, 0, 0))
	mode.scoreTarget = 1
	local onLedger = nil
	W.GameMode.Bind({ Finish = function()
		local ledger = I.ledgers[closer]
		onLedger = ledger and ledger.botKills or 0
	end })
	killBot(mode, closer, 2)
	W.GameMode.Bind({ Finish = function() W.finished = true end })
	mode.scoreTarget = nil
	mode.StopWorld()
	check(onLedger ~= nil, "the kill that reached the score target finished the match")
	check(onLedger == 1, "the winning kill is on the killer's ledger when the match finishes: " .. tostring(onLedger) .. " bot kill(s)")
end
return out
"""


def run(overrides=None):
    overrides = overrides or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = {}
    for name, path in FILES.items():
        text = overrides.get(path, read(path))
        sources[name] = luau_to_lua(text)
    move = int(re.search(r"MoveStuds = (\d+)", read("ReplicatedStorage/Shared/ProgressionData.lua")).group(1))
    world = lua.execute(WORLD, lua.table_from(sources), move)
    failures = list(world.failures.values())
    if failures:
        return failures, {}
    window, top, labels, step, base = match_service_streak()
    out = lua.execute(CHECKS, world, window, top, lua.table_from(labels), step, base)
    failures = list(out.failures.values()) + list(world.failures.values())
    return failures, dict(out.counts.items())


def plant(path, old, new):
    source = read(path)
    assert source.count(old) == 1, (path, old)
    return {path: source.replace(old, new)}


def credit_after_score():
    """GameMode.onDeath with the old order: the TDM score (which can FinishNow) before creditDeath."""
    source = read("ServerScriptService/Modules/GameMode.lua")
    credit = source.index("\t-- Rewards bookkeeping (kills, assists")
    score = source.index("\t-- Team Deathmatch scores eliminations.")
    down = source.index("\tModeTeams.MarkDown(token)")
    assert credit < score < down
    return {"ServerScriptService/Modules/GameMode.lua":
            source[:credit] + source[score:down] + source[credit:score] + source[down:]}


RS = "ServerScriptService/Modules/RewardService.lua"
GM = "ServerScriptService/Modules/GameMode.lua"
KOTH = "ServerScriptService/Modules/ModeKingOfTheHill.lua"
MC = "ReplicatedStorage/Shared/MatchConfig.lua"
PLANTS = [
    ("the kill cap ignored",
     plant(RS, "local playerKills = math.min(n(summary.playerKills), cap)", "local playerKills = n(summary.playerKills)")),
    ("an idle player paid like everyone else",
     plant(RS, "\tif summary.afk then\n\t\tlocal afk = rules.afk", "\tif false then\n\t\tlocal afk = rules.afk")),
    ("the first-win bonus paid on every win",
     plant(RS, "\t\t\tif not quests.progress[RewardService.FirstTeamWinKey] then", "\t\t\tif true then")),
    ("a loss leaves the win streak running",
     plant(RS, "\t\telse\n\t\t\trecord.streak = 0\n\t\tend", "\t\tend")),
    ("the win streak uncapped",
     plant(RS, "local steps = math.min(streak - 1, bonus.winStreak.maxSteps or 4)", "local steps = streak - 1")),
    ("a team cosmetic unlocked again when owned",
     plant(RS, "and not data.Cosmetics.owned[milestone.cosmetic] then", "then")),
    ("team cosmetics left in the crate / shop pools",
     plant("ReplicatedStorage/Shared/CosmeticData.lua", "and not item.rankOnly and not item.teamOnly", "and not item.rankOnly")),
    ("the MVP is the worst on the side",
     plant(GM, "if not holder or value > holder.value", "if not holder or value < holder.value")),
    ("the 2x pass left off the breakdown",
     plant(RS, "\tif granted > coins then\n", "\tif false then\n")),
    ("a respawn teleport counted as moving",
     plant(GM, "\tif ledger then\n\t\tledger.lastPos = nil\n\tend\n\tdamageLog[token] = nil",
           "\tdamageLog[token] = nil")),
    ("an assist with no time limit",
     plant(GM, "and now - entry.at <= (assist.windowSeconds or 10) * 1000", "and true")),
    ("a capture every tick, not every change of hands",
     plant(KOTH, "if alone and objective.owner ~= alone then", "if alone then")),
    ("MVP picked after the teams are torn down",
     plant(GM, "\tlocal picked, pickError = pcall(pickMvps)\n\tif not picked then\n\t\twarn(\"[GameMode] MVP pick failed: \" .. tostring(pickError))\n\tend\n",
           "")),
    ("the team streak window drifted from MatchService's",
     plant(MC, "streak = { windowSeconds = 8,", "streak = { windowSeconds = 9,")),
    ("time on the objective uncapped",
     plant(RS, "local seconds = math.min(n(summary.holdSeconds), rules.hold.capSeconds or math.huge)",
           "local seconds = n(summary.holdSeconds)")),
    ("the winning kill credited after the score that ends the match", credit_after_score()),
    ("a defend counted anywhere",
     plant(GM, "\t\tif owner == killerTeam then\n\t\t\tkiller.defends += 1", "\t\tif true then\n\t\t\tkiller.defends += 1")),
]


def main():
    failures, counts = run()
    print(f"team_rewards_check: {counts.get('checks', 0)} checks, {len(failures)} failed"
          f" (the most an 8-minute match can pay, every cap hit and MVP: {counts.get('maxMatch', '?')} coins)")
    for f in failures:
        print("  FAIL: " + f)
    ok = not failures
    if "--no-plants" not in sys.argv:
        caught = 0
        for label, override in PLANTS:
            planted, _ = run(override)
            hit = bool(planted)
            caught += hit
            print(f"  {'CAUGHT' if hit else 'MISSED'}: {label}" + (f" ({planted[0].splitlines()[0]})" if hit else ""))
        print(f"team_rewards_check plant: {caught} of {len(PLANTS)} planted faults caught")
        ok = ok and caught == len(PLANTS)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
