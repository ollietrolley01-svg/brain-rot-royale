-- Lifetime counters, achievement unlocks and the title worn on the nameplate.
--
-- Everything QuestService counts comes through Track, which bumps the profile's Lifetime
-- counters and checks the achievements for that stat. Wins, kills and matches live in Stats
-- (RewardService keeps those) and are checked the same way.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AchievementData = require(Shared:WaitForChild("AchievementData"))

-- Achievements worth at least this much are announced to the whole server.
local SHOUT_THRESHOLD = 10000

local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local AchievementService = {}

-- The title text as a Player attribute, so nameplates show it without a remote.
function AchievementService.SyncTitle(player)
	local data = PlayerData.Get(player)
	if not data then
		return
	end
	local achievement = data.Title and AchievementData.Get(data.Title)
	player:SetAttribute("Title", achievement and achievement.title or nil)
end

-- Unlocks anything whose target is now met. `stat` limits the check; nil checks everything
-- (used on join, so profiles from before an achievement existed catch up).
function AchievementService.Check(player, stat)
	local data = PlayerData.Get(player)
	if not data then
		return
	end

	local unlockedAny = false
	for _, achievement in ipairs(AchievementData.List) do
		if (stat == nil or achievement.stat == stat) and not data.Achievements[achievement.id]
			and AchievementData.Value(data, achievement.stat) >= achievement.target then
			data.Achievements[achievement.id] = true
			-- Earned coins, so the 2x SahurCoins pass doubles them like every other payout.
			local granted = Monetization.EarnCoins(player, achievement.coins)
			unlockedAny = true
			StateSync.Notify(player, string.format('ACHIEVEMENT: %s  •  title "%s" unlocked  •  +%d SahurCoins',
				achievement.name, achievement.title, granted))
			-- The big ones are everyone's business.
			if achievement.coins >= SHOUT_THRESHOLD then
				for _, other in ipairs(Players:GetPlayers()) do
					if other ~= player then
						StateSync.Notify(other, string.format('%s just earned "%s" (%s)!', player.DisplayName, achievement.title, achievement.name))
					end
				end
			end
			-- The first title you earn goes straight on.
			if not data.Title then
				data.Title = achievement.id
				AchievementService.SyncTitle(player)
			end
		end
	end

	if unlockedAny then
		StateSync.Push(player)
	end
end

function AchievementService.Track(player, stat, amount)
	local data = PlayerData.Get(player)
	if not data then
		return
	end
	if data.Lifetime[stat] ~= nil then
		data.Lifetime[stat] += amount
	end
	AchievementService.Check(player, stat)
end

function AchievementService.SetTitle(player, id)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end
	if id == nil then
		data.Title = nil
		AchievementService.SyncTitle(player)
		StateSync.Push(player)
		return true, "Title removed."
	end
	local achievement = AchievementData.Get(id)
	if not achievement then
		return false, "No such title."
	end
	if not data.Achievements[id] then
		return false, "You haven't unlocked that yet."
	end
	data.Title = id
	AchievementService.SyncTitle(player)
	StateSync.Push(player)
	return true, "Title: " .. achievement.title
end

return AchievementService
