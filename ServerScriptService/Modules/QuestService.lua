-- Counts what players do toward today's quests (QuestData) and pays out as each one completes.
--
-- Everything that counts calls QuestService.Progress(player, stat, amount) — kills and
-- placements from RewardService, chests from LootService, item uses from WeaponService, damage
-- from CombatService, and crates, supply drops, obby clears and goals from where they happen.
-- Nothing here is required by those modules' dependencies, so any of them can call in.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local QuestData = require(Shared:WaitForChild("QuestData"))

local AchievementService = require(script.Parent:WaitForChild("AchievementService"))
local BattlePassService = require(script.Parent:WaitForChild("BattlePassService"))
local CrateService = require(script.Parent:WaitForChild("CrateService"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local QuestService = {}

-- Damage progress ticks on every hit; pushing the whole profile each time would be wasteful, so
-- pushes are coalesced. Completions push straight away.
local PUSH_DELAY = 1.5
local pushPending = {}

-- Per-match tallies of the same events, for the results card. Cleared when a match starts.
local tallies = {}

function QuestService.ResetTallies()
	table.clear(tallies)
end

function QuestService.MatchTally(player)
	return tallies[player] or {}
end

local function schedulePush(player)
	if pushPending[player] then
		return
	end
	pushPending[player] = true
	task.delay(PUSH_DELAY, function()
		pushPending[player] = nil
		if player.Parent then
			StateSync.Push(player)
		end
	end)
end

function QuestService.Progress(player, stat, amount)
	local data = PlayerData.Get(player)
	if not data or type(amount) ~= "number" or amount <= 0 then
		return
	end

	-- Lifetime counters and achievements ride on the same events, and so does the match tally.
	AchievementService.Track(player, stat, amount)
	local tally = tallies[player]
	if not tally then
		tally = {}
		tallies[player] = tally
	end
	tally[stat] = (tally[stat] or 0) + amount

	local day = StateSync.CurrentDay()
	local quests = QuestData.Ensure(data.Quests, day)
	local changed, completed = false, false

	local function advance(list, progress, done, label)
		for _, quest in ipairs(list) do
			if quest.stat == stat and not done[quest.id] then
				local value = math.min(quest.target, (progress[quest.id] or 0) + amount)
				progress[quest.id] = value
				changed = true

				if value >= quest.target then
					done[quest.id] = true
					completed = true
					-- Through Monetization.EarnCoins, so the 2x SahurCoins pass applies here like everywhere.
					local coins = Monetization.EarnCoins(player, quest.coins)
					BattlePassService.AddXp(player, quest.xp)
					local extra = ""
					if quest.crate then
						CrateService.Give(player, quest.crate, 1)
						extra = string.format("  +1 %s Crate", quest.crate)
					end
					StateSync.Notify(player, string.format("%s: %s  •  +%d SahurCoins  +%d XP%s",
						label, QuestData.Title(quest), coins, quest.xp, extra))
					AchievementService.Track(player, "questsDone", 1)
				end
			end
		end
	end

	advance(QuestData.Today(day), quests.progress, quests.done, "QUEST COMPLETE")
	advance(QuestData.ThisWeek(quests.week), quests.weekProgress, quests.weekDone, "WEEKLY CHALLENGE DONE")

	if not changed then
		return
	end

	if completed and not quests.bonus then
		local allDone = true
		for _, quest in ipairs(QuestData.Today(day)) do
			if not quests.done[quest.id] then
				allDone = false
				break
			end
		end
		if allDone then
			quests.bonus = true
			CrateService.Give(player, QuestData.BonusCrate, 1)
			StateSync.Notify(player, string.format("ALL DAILY QUESTS DONE!  +1 %s Crate", QuestData.BonusCrate))
		end
	end

	if completed then
		StateSync.Push(player)
	else
		schedulePush(player)
	end
end

return QuestService
