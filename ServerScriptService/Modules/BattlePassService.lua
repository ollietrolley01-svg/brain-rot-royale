-- Brainrot Pass: XP and tier claims on two tracks, plus the daily login streak.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BattlePassData = require(Shared:WaitForChild("BattlePassData"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local DailySpinData = require(Shared:WaitForChild("DailySpinData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local CrateService = require(script.Parent:WaitForChild("CrateService"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local BattlePassService = {}

-- The pass tier as a Player attribute, so nameplates can show it without a remote.
function BattlePassService.SyncTier(player)
	local data = PlayerData.Get(player)
	if data then
		player:SetAttribute("PassTier", BattlePassData.TierForXp(data.Pass.xp))
	end
end

function BattlePassService.AddXp(player, amount)
	local data = PlayerData.Get(player)
	if not data or amount <= 0 then
		return
	end

	local before = BattlePassData.TierForXp(data.Pass.xp)
	data.Pass.xp += amount
	local after = BattlePassData.TierForXp(data.Pass.xp)

	if after > before then
		StateSync.Notify(player, string.format("Brainrot Pass tier %d unlocked!", after))
		BattlePassService.SyncTier(player)
	end

	-- Set by Bootstrap to ProgressionService.OnPassXp: the same XP also feeds Rot Rank.
	if BattlePassService.OnXp then
		BattlePassService.OnXp(player, amount)
	end
end

-- Hands out the first cosmetic in the pool the player doesn't already own. Falls back to
-- coins once they own everything, so a tier reward is never a dead slot.
-- Coins here all go through Monetization.EarnCoins, so the 2x SahurCoins pass doubles pass rewards
-- and Daily Spin coins the same as every other earned coin.
local function grantCosmetic(player, data, poolName)
	local pool = BattlePassData.CosmeticPools[poolName] or {}
	for _, id in ipairs(pool) do
		if not data.Cosmetics.owned[id] then
			data.Cosmetics.owned[id] = true
			local item = CosmeticData.Get(id)
			return string.format("Unlocked cosmetic: %s", item and item.name or id)
		end
	end
	local granted = Monetization.EarnCoins(player, 1000)
	return string.format("Already own every cosmetic on this track — %d SahurCoins instead.", granted)
end

local function applyReward(player, data, reward)
	if reward.kind == "Coins" then
		local granted = Monetization.EarnCoins(player, reward.amount)
		return string.format("+%d SahurCoins", granted)
	elseif reward.kind == "Crate" then
		CrateService.Give(player, reward.crate, 1)
		return string.format("+1 %s Crate", reward.crate)
	elseif reward.kind == "Cosmetic" then
		return grantCosmetic(player, data, reward.pool)
	end
	return "Reward granted."
end

function BattlePassService.ClaimTier(player, tier, track)
	-- Whole numbers only. 1.5 or NaN passed the range check and then indexed a tier that
	-- doesn't exist; `tier % 1 ~= 0` also rejects NaN and infinity.
	if type(tier) ~= "number" or tier % 1 ~= 0 or tier < 1 or tier > BattlePassData.MaxTier then
		return false, "Invalid tier."
	end
	if track ~= "free" and track ~= "premium" then
		return false, "Invalid track."
	end

	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if BattlePassData.TierForXp(data.Pass.xp) < tier then
		return false, "You haven't reached that tier yet."
	end

	if track == "premium" and not Monetization.Owns(player, "BrainrotPassPremium") then
		return false, "Premium track requires Brainrot Pass Premium."
	end

	local claimed = track == "premium" and data.Pass.claimedPremium or data.Pass.claimedFree
	if claimed[tostring(tier)] then
		return false, "Already claimed."
	end

	local reward = BattlePassData.Tiers[tier][track]
	local message = applyReward(player, data, reward)
	claimed[tostring(tier)] = true

	StateSync.Push(player)
	return true, message
end

-- Every unlocked, unclaimed tier on both tracks (premium only if owned) in one go, with a
-- single profile push. Claiming a backlog tier by tier pushed the profile — and re-rendered the
-- whole Pass tab — once per reward.
function BattlePassService.ClaimAll(player)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local reached = math.min(BattlePassData.TierForXp(data.Pass.xp), BattlePassData.MaxTier)
	local tracks = Monetization.Owns(player, "BrainrotPassPremium") and { "free", "premium" } or { "free" }

	local count = 0
	for tier = 1, reached do
		for _, track in ipairs(tracks) do
			local claimed = track == "premium" and data.Pass.claimedPremium or data.Pass.claimedFree
			if not claimed[tostring(tier)] then
				applyReward(player, data, BattlePassData.Tiers[tier][track])
				claimed[tostring(tier)] = true
				count += 1
			end
		end
	end

	if count == 0 then
		return false, "Nothing to claim yet."
	end

	StateSync.Push(player)
	return true, string.format("Claimed %d pass reward%s.", count, count == 1 and "" or "s")
end

-- The Daily Spin's prize for a segment (DailySpinData), applied to the profile. Returns what it
-- was, in words.
local function applySpinPrize(player, data, segment)
	if segment.kind == "Coins" then
		local amount = math.floor(segment.amount * DailySpinData.StreakMultiplier(data.Daily.streak))
		local granted = Monetization.EarnCoins(player, amount)
		return string.format("+%d SahurCoins", granted)
	elseif segment.kind == "Crate" then
		CrateService.Give(player, segment.crate, 1)
		return string.format("+1 %s Crate", segment.crate)
	elseif segment.kind == "Accessory" then
		local rarity = Rarity.Roll(segment.rarities)
		local pool = {}
		for _, id in ipairs(CosmeticData.OfKind("Accessory", true)) do
			local item = CosmeticData.Get(id)
			if item.rarity == rarity and not data.Cosmetics.owned[id] then
				table.insert(pool, item)
			end
		end
		-- Nothing left at that rarity: any unowned accessory, then coins.
		if #pool == 0 then
			for _, id in ipairs(CosmeticData.OfKind("Accessory", true)) do
				if not data.Cosmetics.owned[id] then
					table.insert(pool, CosmeticData.Get(id))
				end
			end
		end
		if #pool == 0 then
			return string.format("+%d SahurCoins (you own every accessory!)", Monetization.EarnCoins(player, 2000))
		end
		local item = pool[math.random(1, #pool)]
		data.Cosmetics.owned[item.id] = true
		return string.format("the %s accessory (%s)", item.name, item.rarity)
	elseif segment.kind == "Brainrot" then
		local rarity = Rarity.Roll(segment.rarities)
		local def = BrainrotData.RandomOfRarity(rarity)
		if not def then
			return string.format("+%d SahurCoins", Monetization.EarnCoins(player, 2000))
		end
		table.insert(data.Brainrots, def.name)
		return string.format("%s — a %s brainrot!", def.name, def.rarity)
	elseif segment.kind == "TempPass" then
		local choices = {}
		for key in pairs(GamepassConfig.Passes) do
			if not Monetization.GetPasses(player)[key] and not Monetization.TempRemaining(player, key) then
				table.insert(choices, key)
			end
		end
		if #choices == 0 then
			return string.format("+%d SahurCoins (you have every pass already)", Monetization.EarnCoins(player, 2000))
		end
		table.sort(choices)
		local key = choices[math.random(1, #choices)]
		-- Monetization.Owns reads TempPasses live. (This used to call Monetization.Clear too, which
		-- dropped the cached passes the player had PAID for until they rejoined.)
		data.TempPasses[key] = os.time() + (segment.hours or 24) * 3600
		return string.format("%s for %d hours!", GamepassConfig.Passes[key].name, segment.hours or 24)
	end
	return "a prize"
end

-- One spin a day. Returns ok, message, and the segment the wheel should stop on.
function BattlePassService.ClaimDaily(player)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local today = StateSync.CurrentDay()
	if data.Daily.lastClaimDay >= today then
		return false, "Already spun today. Come back tomorrow."
	end

	-- Consecutive day continues the streak; any gap starts over at day 1.
	if data.Daily.lastClaimDay == today - 1 then
		data.Daily.streak += 1
	else
		data.Daily.streak = 1
	end
	data.Daily.lastClaimDay = today

	local index = DailySpinData.Roll()
	local segment = DailySpinData.Segments[index]
	local prize = applySpinPrize(player, data, segment)
	local multiplier = DailySpinData.StreakMultiplier(data.Daily.streak)

	StateSync.Push(player)
	return true, string.format("Daily Spin: %s   (day %d streak%s)", prize, data.Daily.streak,
		multiplier > 1 and string.format(", coins x%.1f", multiplier) or ""), index
end

return BattlePassService
