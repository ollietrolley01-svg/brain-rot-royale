-- The Daily Spin: a wheel of nine prizes, spun once a day at the booth in the lobby (or the
-- DAILY button on the Pass tab, which is the same spin). Which segment it lands on is rolled
-- server-side by weight; the wheel then turns to it for everyone to see.
--
-- Consecutive days build a streak, and the streak multiplies the coin prizes (StreakBonus per
-- day, capped). Any gap starts the streak over.
--
--   Coins      SahurCoins, times the streak multiplier
--   Crate      one crate of that tier
--   Accessory  a shop accessory you don't own yet (Common to Epic by weight); coins if you own them all
--   Brainrot   a Rare or Epic brainrot straight into your collection (a Legendary 5% of the time)
--   TempPass   one of the gamepasses you don't own, for 24 hours; coins if you own them all

local DailySpinData = {}

-- Weights add up to 100, so each one reads straight off as a percentage.
--
-- The old table paid 500 coins on nearly a quarter of all spins, in a game where finishing first
-- pays 2,500 and a Legendary Crate. That made the likeliest outcome of your one daily spin a
-- shrug. The floor is now worth collecting, the jackpot is worth hoping for, and the top of the
-- wheel carries the same Legendary Crate a first-place finish does — so there's a reason to come
-- back and spin rather than a formality to click through.
DailySpinData.Segments = {
	{ id = "coins1200", label = "1,200 C", kind = "Coins", amount = 1200, weight = 20, color = Color3.fromRGB(255, 196, 64) },
	{ id = "rareCrate", label = "RARE CRATE", kind = "Crate", crate = "Rare", weight = 15, color = Color3.fromRGB(80, 170, 255) },
	{ id = "coins3000", label = "3,000 C", kind = "Coins", amount = 3000, weight = 14, color = Color3.fromRGB(255, 226, 120) },
	{ id = "accessory", label = "ACCESSORY", kind = "Accessory", weight = 10, color = Color3.fromRGB(255, 110, 200),
		rarities = { Common = 25, Uncommon = 30, Rare = 28, Epic = 17 } },
	{ id = "epicCrate", label = "EPIC CRATE", kind = "Crate", crate = "Epic", weight = 10, color = Color3.fromRGB(190, 120, 255) },
	{ id = "brainrot", label = "BRAINROT", kind = "Brainrot", weight = 10, color = Color3.fromRGB(94, 214, 122),
		rarities = { Rare = 55, Epic = 40, Legendary = 5 } },
	{ id = "pass", label = "PASS FOR A DAY", kind = "TempPass", hours = 24, weight = 11, color = Color3.fromRGB(110, 210, 255) },
	{ id = "legendaryCrate", label = "LEGENDARY CRATE", kind = "Crate", crate = "Legendary", weight = 5,
		color = Color3.fromRGB(255, 146, 38) },
	{ id = "jackpot", label = "15,000 C", kind = "Coins", amount = 15000, weight = 5, color = Color3.fromRGB(232, 92, 92) },
}

-- Coins pay +10% per streak day beyond the first, up to double.
DailySpinData.StreakBonus = 0.1
DailySpinData.StreakCap = 10

function DailySpinData.StreakMultiplier(streak)
	return 1 + DailySpinData.StreakBonus * math.clamp((streak or 1) - 1, 0, DailySpinData.StreakCap)
end

-- A segment index, by weight.
function DailySpinData.Roll()
	local total = 0
	for _, segment in ipairs(DailySpinData.Segments) do
		total += segment.weight
	end
	local value = math.random() * total
	for index, segment in ipairs(DailySpinData.Segments) do
		value -= segment.weight
		if value <= 0 then
			return index
		end
	end
	return #DailySpinData.Segments
end

return DailySpinData
