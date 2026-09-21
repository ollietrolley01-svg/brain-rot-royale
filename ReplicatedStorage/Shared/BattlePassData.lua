-- The Brainrot Pass: a free track everyone earns, a premium track unlocked by gamepass,
-- and a daily login streak on the side.

local BattlePassData = {}

BattlePassData.MaxTier = 50
BattlePassData.XpPerTier = 1000

-- Tier rewards are generated rather than hand-listed so the curve stays consistent and you
-- can change MaxTier without editing 50 table entries.
local function tierReward(tier, premium)
	if tier % 10 == 0 then
		return {
			kind = "Crate",
			crate = premium and (tier >= 40 and "Legendary" or "Epic") or (tier >= 30 and "Rare" or "Uncommon"),
		}
	end
	if tier % 5 == 0 then
		return { kind = "Cosmetic", pool = premium and "premium" or "free" }
	end
	return {
		kind = "Coins",
		amount = (premium and 400 or 150) + tier * (premium and 45 or 18),
	}
end

BattlePassData.Tiers = {}
for tier = 1, BattlePassData.MaxTier do
	BattlePassData.Tiers[tier] = {
		tier = tier,
		free = tierReward(tier, false),
		premium = tierReward(tier, true),
	}
end

-- Seven-day login cycle. Missing a day resets the streak to day 1.
BattlePassData.DailyRewards = {
	{ kind = "Coins", amount = 250 },
	{ kind = "Coins", amount = 400 },
	{ kind = "Crate", crate = "Common" },
	{ kind = "Coins", amount = 800 },
	{ kind = "Crate", crate = "Uncommon" },
	{ kind = "Coins", amount = 1500 },
	{ kind = "Crate", crate = "Rare" },
}

BattlePassData.DailyCycle = #BattlePassData.DailyRewards

-- Cosmetics handed out by the pass, by track.
BattlePassData.CosmeticPools = {
	free = { "BananiniYellow", "PartyCone", "CrocodiloCamo", "ChefHat" },
	premium = { "CappuccinaPink", "VikingHelm", "VoidRot", "RotAura", "ToasterPack", "GoldSahur", "SahurAura" },
}

function BattlePassData.TierForXp(xp)
	return math.min(BattlePassData.MaxTier, math.floor(xp / BattlePassData.XpPerTier) + 1)
end

function BattlePassData.XpIntoTier(xp)
	return xp % BattlePassData.XpPerTier
end

return BattlePassData
