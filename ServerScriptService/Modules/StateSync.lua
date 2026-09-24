-- Builds the profile snapshot the menu UI renders from, and pushes it whenever it changes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AchievementData = require(Shared:WaitForChild("AchievementData"))
local BattlePassData = require(Shared:WaitForChild("BattlePassData"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local QuestData = require(Shared:WaitForChild("QuestData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local CrateData = require(Shared:WaitForChild("CrateData"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local StateSync = {}

-- Crate tiers whose next open rolls with Beginner's Luck, by CrateData's rule (the same one
-- CrateService.Open uses). Empty for everyone who has no charges left, which is almost everyone.
local function crateBoosted(data)
	local boosted = nil
	if CrateData.BeginnerLeft(data.Progression) <= 0 then
		return boosted
	end
	for _, tier in ipairs(CrateData.Order) do
		if CrateData.BeginnerBoosted(CrateData.Get(tier), data.Crates[tier], data.PaidCrates[tier],
			data.FreeCrates and data.FreeCrates[tier] or 0, CrateData.BeginnerLeft(data.Progression)) then
			boosted = boosted or {}
			boosted[tier] = true
		end
	end
	return boosted
end

local profileChanged = Remotes.Event("ProfileChanged")
local notify = Remotes.Event("Notify")

function StateSync.CurrentDay()
	return math.floor(os.time() / 86400)
end

function StateSync.DailyAvailable(data)
	return data.Daily.lastClaimDay < StateSync.CurrentDay()
end

function StateSync.Build(player)
	local data = PlayerData.Get(player)
	if not data then
		return nil
	end

	local grouped = {}
	local order = {}
	local totalValue = 0

	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def then
			if not grouped[name] then
				local xp = data.CompanionXp[name] or 0
				grouped[name] = {
					name = name,
					rarity = def.rarity,
					coinValue = def.coinValue,
					count = 0,
					xp = xp,
					level = BrainrotData.LevelForXp(xp),
					stars = BrainrotData.ClampStars(data.Stars[name]),
				}
				table.insert(order, grouped[name])
			end
			grouped[name].count += 1
			totalValue += def.coinValue
		end
	end

	table.sort(order, function(a, b)
		local ra, rb = Rarity.Index[a.rarity] or 0, Rarity.Index[b.rarity] or 0
		if ra ~= rb then
			return ra > rb
		end
		return a.name < b.name
	end)

	local tier = BattlePassData.TierForXp(data.Pass.xp)
	local premium = Monetization.Owns(player, "BrainrotPassPremium")

	local ownedPasses, tempPasses = {}, {}
	for key in pairs(GamepassConfig.Passes) do
		ownedPasses[key] = Monetization.Owns(player, key)
		tempPasses[key] = Monetization.TempRemaining(player, key)
	end

	-- A streak with a missed day in it is already over (BattlePassService.ClaimDaily restarts it at 1),
	-- so show it as over rather than promising the next day's bonus.
	local streakLive = (data.Daily.lastClaimDay or -1) >= StateSync.CurrentDay() - 1
	local dailyStreak = streakLive and data.Daily.streak or 0
	local nextDailyIndex = (dailyStreak % BattlePassData.DailyCycle) + 1

	-- Everyone else in the server, for the trade tab and to see what they're showing off.
	local others = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local otherData = PlayerData.Get(other)
			table.insert(others, {
				name = other.DisplayName,
				userId = other.UserId,
				showcase = otherData and otherData.Showcase or nil,
			})
		end
	end

	return {
		coins = math.floor(data.SahurCoins),
		brainrots = order,
		showcase = data.Showcase,
		companion = data.Companion,
		-- Brainrot name -> merge stars, including brainrots not currently owned (stars outlive the
		-- copies), so the trade screen can say what an incoming copy would be for you.
		stars = data.Stars,
		collections = data.Collections,
		others = others,
		brainrotValue = totalValue,
		crates = data.Crates,
		pity = data.Pity,
		-- The luck this player's crates open with, from the same function CrateService rolls with;
		-- the crate cards show CrateData.EffectiveOdds at exactly this luck.
		crateLuck = Monetization.CrateLuck(player),
		-- Tiers whose next crate rolls with Beginner's Luck. Those cards show which rarities can drop
		-- and no percentages, since the percentages for the luck they roll with aren't the ones the
		-- shop's odds table would print. Nothing in the menu says why.
		crateBoosted = crateBoosted(data),
		cosmetics = {
			owned = data.Cosmetics.owned,
			gunSkin = data.Cosmetics.gunSkin,
			aura = data.Cosmetics.aura,
			accessory = data.Cosmetics.accessory,
			parachute = data.Cosmetics.parachute,
			killAnimation = data.Cosmetics.killAnimation,
		},
		pass = {
			xp = data.Pass.xp,
			tier = tier,
			xpIntoTier = BattlePassData.XpIntoTier(data.Pass.xp),
			xpPerTier = BattlePassData.XpPerTier,
			maxTier = BattlePassData.MaxTier,
			premium = premium,
			claimedFree = data.Pass.claimedFree,
			claimedPremium = data.Pass.claimedPremium,
		},
		daily = {
			available = StateSync.DailyAvailable(data),
			streak = dailyStreak,
			nextIndex = nextDailyIndex,
		},
		stats = data.Stats,
		consumables = data.Consumables,
		ownedPasses = ownedPasses,
		-- Seconds left on passes won for a day on the Daily Spin.
		tempPasses = tempPasses,
		bundles = data.Bundles,
		quests = QuestData.Snapshot(data.Quests, StateSync.CurrentDay(), os.time()),
		achievements = AchievementData.Snapshot(data),
		-- Rot Rank, Brain Cells, mastery, the Rot Index and today's Cell Shop, for the Pass tab.
		progression = ProgressionData.Snapshot(data, os.time()),
	}
end

-- Pushes are coalesced to one snapshot per player per frame. A single kill pays coins, pass XP and
-- quest progress, and each of those asked for a push, so the whole profile — the collection, the
-- Rot Index, quests, achievements — went down the wire several times over for one coin change.
-- The client only ever draws the latest, so the last state of the frame is the one that matters.
-- Everything is sent inside the same frame (task.defer), before any caller that yields resumes.
local pendingPush = {}
local pushScheduled = false

-- Sends `player`'s snapshot now, if one is waiting. Called for a player who is leaving, so nothing
-- is dropped by the deferred send arriving after their profile is released.
function StateSync.Flush(player)
	if not pendingPush[player] then
		return
	end
	pendingPush[player] = nil
	if not player.Parent then
		return
	end
	local state = StateSync.Build(player)
	if state then
		profileChanged:FireClient(player, state)
	end
end

function StateSync.Push(player)
	pendingPush[player] = true
	if pushScheduled then
		return
	end
	pushScheduled = true
	task.defer(function()
		pushScheduled = false
		local waiting = pendingPush
		pendingPush = {}
		for target in pairs(waiting) do
			if target.Parent then
				local state = StateSync.Build(target)
				if state then
					profileChanged:FireClient(target, state)
				end
			end
		end
	end)
end

Players.PlayerRemoving:Connect(function(player)
	pendingPush[player] = nil
end)

function StateSync.Notify(player, message, isError)
	notify:FireClient(player, message, isError == true)
end

return StateSync
