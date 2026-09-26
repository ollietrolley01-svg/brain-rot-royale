-- The results card with a win's Mythic Crate roll (Task 24), for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/mythic_crate_gallery.lua -OutDir <folder>
--
-- Draws the REAL ResultsScreen: its source is loaded as a ModuleScript beside it, with the two things edit
-- mode doesn't have swapped out (LocalPlayer's PlayerGui becomes StarterGui, which Studio draws over the view,
-- and the MatchResults remote becomes a stub that hands back the card's own handler). The payloads come from
-- the REAL RewardService.MythicLine and RewardService.TeamBreakdown, cut out of RewardService.lua the same way
-- (RewardService itself needs the server's services), with MatchConfig's real mythicChance. So the words and
-- the number on the card are the shipped ones. Four views: a battle royale win and a team win, the crate
-- dropped and not.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

-- Replaces `old` in `text` exactly once, or stops the gallery: a substitution that silently didn't apply
-- would draw something that isn't the shipped card.
local function swap(text, old, new)
	local at = string.find(text, old, 1, true)
	assert(at and not string.find(text, old, at + 1, true), "gallery: can't find exactly one " .. old)
	return string.sub(text, 1, at - 1) .. new .. string.sub(text, at + #old)
end

local function moduleFrom(name, parent, source)
	local module = Instance.new("ModuleScript")
	module.Name = name
	module.Source = source
	module.Parent = parent
	return module
end

-- RewardService's MythicLine and TeamBreakdown (with RESULT_LABEL), verbatim.
local rewardSource = ServerScriptService:WaitForChild("Modules"):WaitForChild("RewardService").Source
local function cut(from, to)
	local a = assert(string.find(rewardSource, from, 1, true), "gallery: RewardService has no " .. from)
	local b = assert(string.find(rewardSource, to, a, true), "gallery: RewardService has no " .. to)
	return string.sub(rewardSource, a, b - 1)
end
local rewardCut = moduleFrom("BRR_MythicRewardCut", ServerScriptService,
	"local MatchConfig = require(game:GetService(\"ReplicatedStorage\").Shared.MatchConfig)\nlocal RewardService = {}\n"
		.. cut("function RewardService.MythicLine(", "-- Placement rewards do not stack")
		.. cut("local RESULT_LABEL = ", "-- A player's team-mode record")
		.. "return RewardService\n")
local Reward = require(rewardCut)

-- ResultsScreen as a module that returns its MatchResults handler.
local source = scripts:WaitForChild("ResultsScreen").Source
source = swap(source, "local player = Players.LocalPlayer\nlocal playerGui = player:WaitForChild(\"PlayerGui\")",
	"local playerGui = game:GetService(\"StarterGui\")")
source = swap(source, "local matchResults = Remotes.Event(\"MatchResults\")\nlocal matchChanged = Remotes.Event(\"MatchChanged\")",
	"local matchResults = { OnClientEvent = { Connect = function(_, fn) BRR_SHOW = fn end } }\n"
		.. "local matchChanged = { OnClientEvent = { Connect = function() end } }")
local old = StarterGui:FindFirstChild("BrrResults")
if old then
	old:Destroy()
end
local show = require(moduleFrom("BRR_ResultsScreenCopy", scripts, "local BRR_SHOW\n" .. source .. "\nreturn function(result) BRR_SHOW(result) end\n"))

local brChance = MatchConfig.GetBracket(1).mythicChance
local teamChance = MatchConfig.TeamModeRewards.mythicChance
note("mythicChance: battle royale rank 1 %s, team win %s", tostring(brChance), tostring(teamChance))

local function battleRoyale(dropped)
	local bracket = MatchConfig.GetBracket(1)
	local mythic = Reward.MythicLine(brChance, dropped)
	note("battle royale chip (%s): %s", dropped and "dropped" or "missed", mythic.chip)
	return {
		rank = 1, total = 50, mode = "BattleRoyale", kills = 7,
		tally = { damage = 2345, chests = 9, items = 5 },
		combat = { shots = 200, hits = 90, headshots = 12, longestKill = 140, damageTaken = 600 },
		reward = { rank = 1, crate = bracket.crate, coins = bracket.coins, xp = bracket.xp, mythic = mythic },
		progression = { xp = 1200, rank = 12, rankFrom = 11, prestige = 0, prestigeFrom = 0, cells = 40 },
	}
end

local function teamWin(dropped)
	local lines, coins, xp, crate, bonusCrate, bonusCoins = Reward.TeamBreakdown({
		playerKills = 2, botKills = 9, assists = 5, revenges = 1, streakCoins = 100, activeSamples = 30,
		mvp = true, winStreak = 2, mythic = dropped }, "win", 1)
	for _, line in ipairs(lines) do
		if line.id == "mythic" then
			note("team card line (%s): %s | %s", dropped and "dropped" or "missed", line.label, line.note)
		end
	end
	return {
		rank = 1, total = 30, mode = "TeamDeathmatch", kills = 11,
		tally = { damage = 5400, chests = 2, items = 3 },
		combat = { shots = 300, hits = 150, headshots = 40, longestKill = 180, damageTaken = 900 },
		modeResults = { scores = { 100, 71 }, teams = { "Ember Squad", "Teal Crew" }, winner = 1, target = 100,
			mvps = { { team = 1, name = "You" }, { team = 2, name = "Bot_Tralala" } } },
		reward = { rank = 1, crate = crate, coins = coins, xp = xp, outcome = "win", lines = lines, mvp = true,
			bonusCrate = bonusCrate, bonusCoins = bonusCoins },
		progression = { xp = xp, rank = 12, rankFrom = 11, prestige = 0, prestigeFrom = 0, cells = 40 },
	}
end

local views = {}
local function add(name, payload)
	table.insert(views, { name = name, settle = 1.5, hold = 2, setup = function(_folder, camera)
		camera.CFrame = CFrame.lookAt(Vector3.new(0, 400, 0), Vector3.new(0, 400, -10))
		show(payload)
	end })
end
add("mythic_br_win_dropped", battleRoyale(true))
add("mythic_br_win_missed", battleRoyale(false))
add("mythic_team_win_dropped", teamWin(true))
add("mythic_team_win_missed", teamWin(false))
return views
