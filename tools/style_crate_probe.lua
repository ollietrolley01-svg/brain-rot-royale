-- Style Crate probe for tools/runtest.ps1 -Probe: the three cosmetic crate tiers (Style, Deluxe
-- Style, Prestige Style) against the real CrateService, CrateData, CosmeticData and PlayerData with
-- a stand-in player.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/style_crate_probe.lua
--
-- These are SOLD -- for coins and, once the products exist, for Robux -- so the thing that matters
-- most is that what the card shows is what the crate does. What has to hold:
--   * The rarity shares a tier rolls match the percentages its card prints, tier by tier. Measured,
--     not asserted: n opens per tier, compared against CrateData.EffectiveOdds -- the same function
--     the menu draws with -- and allowed 4 standard deviations of sampling noise.
--   * The comparison can FAIL. A planted mismatch (Style's rolls judged against Prestige's odds)
--     has to be caught, or a green run means nothing.
--   * Every card shows percentages. A cosmetic crate is never a boosted card: Beginner's Luck must
--     not touch anything bought, and these are bought.
--   * Beginner's Luck stays off them even with charges in hand and the crate handed out free.
--   * Pity fires exactly on its stated interval and forces exactly its stated rarity.
--   * A duplicate-only rarity refunds floor(coinPrice * duplicateRefund) coins and says so.
--   * Drops only ever come from the tier's own `kinds` list.
--   * Buying costs exactly coinPrice and is refused when the coins aren't there.
--   * A Robux-granted crate is marked purchased when it opens (the Rot Index records it without
--     Brain Cells), and a coin-bought one is not.
-- PlayerData.Save is stubbed: a stand-in profile must never reach a real DataStore.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local CrateService = require(modules:WaitForChild("CrateService"))

StateSync.Push = function() end
StateSync.Notify = function() end
PlayerData.Save = function()
	return true
end
PlayerData.CanSave = function()
	return true
end

local TIERS = { "Style", "DeluxeStyle", "PrestigeStyle" }
local OPENS = 9000
local SD_ALLOWED = 4

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[StyleProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

local player = { UserId = -424260, Name = "StyleProbe", DisplayName = "StyleProbe" }
local data = PlayerData.Load(player)
data.FreeCrates = data.FreeCrates or {}
data.PaidCrates = data.PaidCrates or {}
data.Progression = data.Progression or {}

local function clearCrates()
	for tier in pairs(data.Crates) do
		data.Crates[tier] = 0
	end
	data.PaidCrates = {}
	data.FreeCrates = {}
end
local function ownNothing()
	data.Cosmetics.owned = {}
end
local function ownEverything()
	for id in pairs(CosmeticData.Items) do
		data.Cosmetics.owned[id] = true
	end
end
-- One open through the real service, handing back the result table it built.
local function open(tier)
	data.Crates[tier] = (data.Crates[tier] or 0) + 1
	local ok, message, result = CrateService.Open(player, tier)
	return ok, message, result
end

-- Measured shares against a set of expected percentages, in standard deviations of the sampling
-- noise. Returns the worst rarity and its distance, so a pass says how much room it had and a
-- failure says which rarity drifted.
local function worstDeviation(counts, expected, n)
	local worstRarity, worstSd = "none", 0
	for _, rarity in ipairs(Rarity.Order) do
		local p = (expected[rarity] or 0) / 100
		local observed = (counts[rarity] or 0) / n
		-- A rarity nobody can roll must never appear, whatever the sample size.
		if p <= 0 then
			if (counts[rarity] or 0) > 0 then
				return rarity, math.huge
			end
		else
			local sd = math.sqrt(p * (1 - p) / n)
			local distance = math.abs(observed - p) / sd
			if distance > worstSd then
				worstRarity, worstSd = rarity, distance
			end
		end
	end
	return worstRarity, worstSd
end

-- Distribution ---------------------------------------------------------------------------------
-- Pity is taken off the crate for this measurement and put straight back: a forced roll is a roll
-- the odds deliberately didn't produce, so leaving it in would make the shares disagree with the
-- card BY DESIGN and the check would be measuring the wrong thing. Pity gets its own test below.
local measured = {}
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	local savedPity = crate.pity
	crate.pity = nil
	clearCrates()
	ownNothing()
	data.SahurCoins = 0
	local counts, rolled, refunds = {}, 0, 0
	for index = 1, OPENS do
		-- Yielded now and then: a loop this long without one trips Studio's script timeout, and the
		-- run dies half-measured instead of failing honestly.
		if index % 400 == 0 then
			task.wait()
		end
		local ok, _, result = open(tier)
		if ok and result then
			counts[result.rarity] = (counts[result.rarity] or 0) + 1
			rolled += 1
			if result.kind == "Refund" then
				refunds += 1
			end
		end
	end
	crate.pity = savedPity
	measured[tier] = counts
	-- Vacuity guard: a run where nothing opened would pass every share check below by having no
	-- shares at all.
	expect(string.format("%s: %d opens all rolled", tier, OPENS), rolled == OPENS, rolled)
	local rarity, sd = worstDeviation(counts, CrateData.EffectiveOdds(crate, 1), rolled)
	expect(string.format("%s rolls the shares its card prints", tier), sd <= SD_ALLOWED,
		string.format("worst %s at %.1f sd of %d allowed, %d opens, %d ended in a refund", rarity, sd, SD_ALLOWED, rolled, refunds))
end

-- The check can fail: Style's rolls judged against Prestige's odds (no Commons at all, three times
-- the Legendaries) must come out wrong. A distribution test that can't fail proves nothing.
do
	local rarity, sd = worstDeviation(measured.Style, CrateData.EffectiveOdds(CrateData.Get("PrestigeStyle"), 1), OPENS)
	expect("planted mismatch: Style rolls judged against Prestige odds are caught", sd > SD_ALLOWED,
		string.format("worst %s at %.1f sd", rarity, sd))
end

-- What the card shows ---------------------------------------------------------------------------
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	local line = table.concat(CrateData.OddsLine(crate, 1, false), " ")
	local shown = 0
	for _, rarity in ipairs(Rarity.Order) do
		if (crate.odds[rarity] or 0) > 0 then
			shown += 1
			expect(string.format("%s card prints a percentage for %s", tier, rarity),
				string.find(line, rarity:sub(1, 4) .. " %d") ~= nil, line)
		end
	end
	expect(string.format("%s card prints every rarity it can roll", tier), shown >= 5, shown)
end

-- Never boosted ---------------------------------------------------------------------------------
-- Charges in hand, the crate handed out FREE: the one arrangement that boosts a brainrot crate. A
-- cosmetic crate must still roll at 1x and spend no charge, because these are sold.
for _, tier in ipairs(TIERS) do
	clearCrates()
	ownNothing()
	data.Progression.beginnerLuck = { left = 4, granted = true }
	CrateService.Give(player, tier, 1)
	local boosted = CrateService.BeginnerBoosted(data, tier)
	expect(string.format("%s is never Beginner's Luck boosted", tier), boosted == false)
	expect(string.format("%s rolls at 1x with charges in hand", tier),
		CrateData.LuckFor(CrateData.Get(tier), 1, true) == 1, CrateData.LuckFor(CrateData.Get(tier), 1, true))
	local before = CrateData.BeginnerLeft(data.Progression)
	CrateService.Open(player, tier)
	expect(string.format("%s spends no Beginner's Luck charge", tier),
		CrateData.BeginnerLeft(data.Progression) == before, CrateData.BeginnerLeft(data.Progression))
end
data.Progression.beginnerLuck = { left = 0, granted = true }

-- Pity ------------------------------------------------------------------------------------------
-- Every dry open in a row is counted, and the `every`th is forced up to the guaranteed rarity. The
-- forced one is measured by the flag the result carries, so this reads the mechanism, not a guess.
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	if crate.pity then
		clearCrates()
		ownNothing()
		data.Pity[tier] = 0
		local forced, wrongRarity, longestDry, dry = 0, 0, 0, 0
		for index = 1, 400 do
			if index % 200 == 0 then
				task.wait()
			end
			local ok, _, result = open(tier)
			if ok and result then
				if result.pity then
					forced += 1
					if result.rarity ~= crate.pity.rarity then
						wrongRarity += 1
					end
				end
				if (Rarity.Index[result.rarity] or 0) >= (Rarity.Index[crate.pity.rarity] or 0) then
					dry = 0
				else
					dry += 1
					longestDry = math.max(longestDry, dry)
				end
			end
		end
		expect(string.format("%s pity fires", tier), forced > 0, forced)
		expect(string.format("%s pity always forces %s", tier, crate.pity.rarity), wrongRarity == 0, wrongRarity)
		expect(string.format("%s never goes more than %d opens without %s+", tier, crate.pity.every, crate.pity.rarity),
			longestDry <= crate.pity.every, string.format("longest dry run %d", longestDry))
	end
end

-- Refunds ---------------------------------------------------------------------------------------
-- Owning every cosmetic in the game: every open has nothing new to give, so every one must refund
-- the stated share of the coin price rather than hand over a duplicate or a nil.
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	clearCrates()
	ownEverything()
	data.SahurCoins = 0
	local want = math.floor(crate.coinPrice * (crate.duplicateRefund or 0.3))
	local refunded, wrongAmount, notRefund = 0, 0, 0
	for _ = 1, 40 do
		local ok, _, result = open(tier)
		if ok and result then
			if result.kind == "Refund" then
				refunded += 1
				if result.coinValue ~= want then
					wrongAmount += 1
				end
			else
				notRefund += 1
			end
		end
	end
	expect(string.format("%s with everything owned refunds every open", tier), refunded == 40 and notRefund == 0,
		string.format("%d refunds, %d other", refunded, notRefund))
	expect(string.format("%s refunds %d coins (%d%% of %d)", tier, want, math.floor((crate.duplicateRefund or 0.3) * 100), crate.coinPrice),
		wrongAmount == 0, wrongAmount)
	-- The coins actually land in the profile, not just in the message.
	expect(string.format("%s refund reaches the wallet", tier), data.SahurCoins == want * refunded,
		string.format("%d coins after %d refunds", data.SahurCoins, refunded))
end

-- Kinds -----------------------------------------------------------------------------------------
-- A tier draws from its own `kinds` list and nothing else.
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	local allowed = {}
	for _, kind in ipairs(crate.kinds) do
		allowed[kind] = true
	end
	clearCrates()
	ownNothing()
	local seen, wrongKind, drops = {}, 0, 0
	for index = 1, 600 do
		if index % 200 == 0 then
			task.wait()
		end
		local ok, _, result = open(tier)
		if ok and result and result.kind ~= "Refund" then
			drops += 1
			seen[result.kind] = (seen[result.kind] or 0) + 1
			if not allowed[result.kind] then
				wrongKind += 1
			end
		end
	end
	local kindList = {}
	for kind, count in pairs(seen) do
		table.insert(kindList, string.format("%s %d", kind, count))
	end
	table.sort(kindList)
	expect(string.format("%s drops something", tier), drops > 0, drops)
	expect(string.format("%s only drops its own kinds", tier), wrongKind == 0, table.concat(kindList, ", "))
end

-- Buying ----------------------------------------------------------------------------------------
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	clearCrates()
	-- Stock rotates, and a tier that is out of stock right now can't be bought at any price; the
	-- price checks below are only meaningful while it is in.
	if not ShopRotation.IsCrateInStock(tier) then
		print(string.format("[StyleProbe] NOTE %s is out of stock this rotation; buy checks skipped", tier))
	else
		data.SahurCoins = crate.coinPrice - 1
		local ok, message = CrateService.Buy(player, tier)
		expect(string.format("%s is refused one coin short", tier), ok == false, message)
		expect(string.format("%s takes no coins when refused", tier), data.SahurCoins == crate.coinPrice - 1, data.SahurCoins)
		data.SahurCoins = crate.coinPrice
		local ok2, message2 = CrateService.Buy(player, tier)
		expect(string.format("%s buys at exactly %d coins", tier, crate.coinPrice), ok2 == true, message2)
		expect(string.format("%s costs exactly its price", tier), data.SahurCoins == 0, data.SahurCoins)
		expect(string.format("%s lands in the inventory", tier), (data.Crates[tier] or 0) == 1, data.Crates[tier])
	end
end

-- Paid or not -----------------------------------------------------------------------------------
-- The Robux route hands the crate over with GivePaid, and the pull it gives must come out marked
-- purchased; a coin-bought one must not, or the Rot Index would record a paid pull for free.
for _, tier in ipairs(TIERS) do
	clearCrates()
	ownNothing()
	CrateService.GivePaid(player, tier, 1)
	local _, _, paidResult = CrateService.Open(player, tier)
	expect(string.format("%s bought with Robux opens as purchased", tier), paidResult and paidResult.purchased == true,
		paidResult and tostring(paidResult.purchased))
	clearCrates()
	data.SahurCoins = CrateData.Get(tier).coinPrice
	data.Crates[tier] = 1 -- as CrateService.Buy leaves it: held, but in neither Paid nor Free
	local _, _, coinResult = CrateService.Open(player, tier)
	expect(string.format("%s bought with coins is not marked purchased", tier), coinResult and coinResult.purchased == nil,
		coinResult and tostring(coinResult.purchased))
end

print(string.format("[StyleProbe] %d passed, %d failed", passes, failures))
print("[PROBE] style crates: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))
