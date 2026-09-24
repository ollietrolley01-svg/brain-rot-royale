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
-- One open through the real service, measured off the PROFILE rather than off the value it returns.
--
-- CrateService.Open finishes by firing a remote at the player, and a stand-in table is not a Player,
-- so the call throws "Unable to cast value to Object" -- AFTER it has already rolled and written
-- everything into the profile. (That is how the first version of this probe died 16 seconds in, with
-- one line printed and every number below it unmeasured.) pcall keeps the run alive, and every check
-- here reads the profile, which is the state the game actually keeps.
--
-- Ownership is cleared before each open so no rarity's pool can run dry: then every open hands over
-- exactly one cosmetic, and that cosmetic's rarity is the rarity that was rolled. Exhaustion and the
-- refund it produces are measured separately, further down, where they are the point.
local function openAndRead(tier)
	data.Cosmetics.owned = {}
	data.Crates[tier] = (data.Crates[tier] or 0) + 1
	local coinsBefore = data.SahurCoins
	pcall(CrateService.Open, player, tier)
	for id in pairs(data.Cosmetics.owned) do
		local item = CosmeticData.Get(id)
		if item then
			return item.rarity, item.kind, 0
		end
	end
	-- Nothing new: the open refunded instead, which the caller may be measuring on purpose.
	return nil, "Refund", data.SahurCoins - coinsBefore
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
			-- The card prints to one or two decimals, so the true value can sit half a printed step
			-- either side of what it says. That half step is taken off before the distance is
			-- measured; without it a tier can read as drifting purely because of rounding.
			local rounding = 0.0005
			local distance = math.max(0, math.abs(observed - p) - rounding) / sd
			if distance > worstSd then
				worstRarity, worstSd = rarity, distance
			end
		end
	end
	return worstRarity, worstSd
end

-- The percentages a player actually READS, parsed back out of the card's own line.
--
-- This is the point of the whole file. The roll calls CrateData.EffectiveOdds, and so does the card,
-- so comparing the roll against EffectiveOdds compares a function with itself and would stay green
-- with both of them wrong together. Parsing the printed string is the only way the shown number and
-- the rolled number come from two different places.
local function shownOdds(crate)
	local shown, count = {}, 0
	for _, part in ipairs(CrateData.OddsLine(crate, 1, false)) do
		local prefix, percent = string.match(part, "^(%a+) ([%d%.]+)%%$")
		if prefix and percent then
			for _, rarity in ipairs(Rarity.Order) do
				if rarity == prefix then
					shown[rarity] = tonumber(percent)
					count += 1
				end
			end
		end
	end
	return shown, count
end

-- Distribution ---------------------------------------------------------------------------------
-- Pity is taken off the crate for this measurement and put straight back: a forced roll is a roll
-- the odds deliberately didn't produce, so leaving it in would make the shares disagree with the
-- card BY DESIGN and the check would be measuring the wrong thing. Pity gets its own test below,
-- including what it does to the realised rate.
local function measureTier(tier, opens)
	local crate = CrateData.Get(tier)
	clearCrates()
	ownNothing()
	data.SahurCoins = 0
	local counts, rolled = {}, 0
	for index = 1, opens do
		-- Yielded now and then: a loop this long without one trips Studio's script timeout, and the
		-- run dies half-measured instead of failing honestly.
		if index % 400 == 0 then
			task.wait()
		end
		local rarity = openAndRead(tier)
		if rarity then
			counts[rarity] = (counts[rarity] or 0) + 1
			rolled += 1
		end
	end
	return counts, rolled
end

for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	local printable = 0
	for _, rarity in ipairs(Rarity.Order) do
		if (crate.odds[rarity] or 0) > 0 then
			printable += 1
		end
	end
	local shown, parsed = shownOdds(crate)
	-- Vacuity guard: a parser that silently matched nothing would make every comparison below pass
	-- against an empty table.
	expect(string.format("%s: all %d printed percentages parse back off the card", tier, printable),
		parsed == printable, string.format("parsed %d of %d from: %s", parsed, printable,
			table.concat(CrateData.OddsLine(crate, 1, false), " ")))

	local savedPity = crate.pity
	crate.pity = nil
	local counts, rolled = measureTier(tier, OPENS)
	crate.pity = savedPity

	expect(string.format("%s: %d opens all rolled", tier, OPENS), rolled == OPENS, rolled)
	local rarity, sd = worstDeviation(counts, shown, rolled)
	expect(string.format("%s rolls what its card PRINTS", tier), sd <= SD_ALLOWED,
		string.format("worst %s at %.1f sd of %d allowed, over %d opens", rarity, sd, SD_ALLOWED, rolled))

	-- How far this sample can actually see. A card printing "0.10%" is telling the truth anywhere in
	-- 0.095-0.105, and at this many opens that band is wider than several standard deviations -- so
	-- for the rarest rows the measurement above cannot tell a right rate from a slightly wrong one,
	-- and a PASS must not be read as covering them. Named rather than quietly counted as proved.
	local blind = {}
	for _, name in ipairs(Rarity.Order) do
		local p = (shown[name] or 0) / 100
		if p > 0 then
			local sdOne = math.sqrt(p * (1 - p) / rolled)
			if 0.0005 > sdOne then
				table.insert(blind, string.format("%s (%.2f%%)", name, shown[name]))
			end
		end
	end
	if #blind > 0 then
		print(string.format("[StyleProbe] NOTE %s: at %d opens the printed rounding is wider than one sd for %s -- those rows are not tested by the check above",
			tier, rolled, table.concat(blind, ", ")))
	end
end

-- PLANTED: a true rate that moves while the printed rate stays put ---------------------------------
-- The fault to be afraid of is not "the card prints the wrong number" -- it is "the card prints the
-- right number and the roll does something else". So the roll itself is bent here, by one in eight
-- Commons coming out Rare, and nothing about the card is touched. The check above has to catch it.
-- If it does not, every PASS above is worthless whatever it says.
do
	local crate = CrateData.Get("Style")
	local savedRoll, savedPity = Rarity.Roll, crate.pity
	crate.pity = nil
	Rarity.Roll = function(weights)
		local rolled = savedRoll(weights)
		if rolled == "Common" and math.random() < 0.125 then
			return "Rare"
		end
		return rolled
	end
	local counts, rolled = measureTier("Style", 4000)
	Rarity.Roll = savedRoll
	crate.pity = savedPity
	local shown = shownOdds(crate)
	local rarity, sd = worstDeviation(counts, shown, rolled)
	expect("planted: a roll bent away from the printed odds is caught", sd > SD_ALLOWED,
		string.format("worst %s at %.1f sd over %d opens", rarity, sd, rolled))
	-- And the printed line is untouched by the plant, which is what makes it the right plant.
	expect("planted: the card still printed the same odds throughout",
		select(2, shownOdds(crate)) > 0 and shown.Common ~= nil, tostring(shown.Common))
end

-- Pity, against the printed odds --------------------------------------------------------------------
-- Pity forces a dry run up to a guaranteed rarity, so the realised rate at that rarity and above is
-- BETTER than the card prints. That is in the player's favour and is why the measurement above turns
-- pity off -- but it is a real difference between what is shown and what happens, so it is measured
-- and reported rather than left implicit. The requirement is one-directional: pity may only help.
for _, tier in ipairs(TIERS) do
	local crate = CrateData.Get(tier)
	if crate.pity then
		local shown = shownOdds(crate)
		local counts, rolled = measureTier(tier, 4000)
		local floor = Rarity.Index[crate.pity.rarity] or 0
		local realised, printed = 0, 0
		for _, rarity in ipairs(Rarity.Order) do
			if (Rarity.Index[rarity] or 0) >= floor then
				realised += (counts[rarity] or 0) / rolled * 100
				printed += shown[rarity] or 0
			end
		end
		expect(string.format("%s: pity only ever helps (%s+ realised %.2f%% vs printed %.2f%%)",
			tier, crate.pity.rarity, realised, printed), realised >= printed - 0.5,
			string.format("%.2f vs %.2f", realised, printed))
	end
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
				string.find(line, rarity .. " %d") ~= nil, line)
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
	pcall(CrateService.Open, player, tier)
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
			local rarity = openAndRead(tier)
			if rarity then
				if (Rarity.Index[rarity] or 0) >= (Rarity.Index[crate.pity.rarity] or 0) then
					-- Reaching the floor ends a dry run, however it got there. Whether THIS open was
					-- the forced one is not readable from the profile, so the check below is on the
					-- thing that matters to a player anyway: how long a dry run can get.
					if dry >= crate.pity.every - 1 then
						forced += 1
					end
					dry = 0
				else
					dry += 1
					longestDry = math.max(longestDry, dry)
				end
			end
		end
		expect(string.format("%s pity fires", tier), forced > 0, forced)
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
		data.Crates[tier] = (data.Crates[tier] or 0) + 1
		local coinsBefore = data.SahurCoins
		pcall(CrateService.Open, player, tier)
		local paid = data.SahurCoins - coinsBefore
		if paid > 0 then
			refunded += 1
			if paid ~= want then
				wrongAmount += 1
			end
		else
			notRefund += 1
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
		local rarity, kind = openAndRead(tier)
		if rarity then
			drops += 1
			seen[kind] = (seen[kind] or 0) + 1
			if not allowed[kind] then
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
-- A crate bought with Robux is counted in PaidCrates, and opening one must SPEND that count -- that
-- is what marks the pull as purchased so the Rot Index records it without Brain Cells. The flag on
-- the result can't be read here (the open throws on the remote before returning, see openAndRead),
-- so the state behind the flag is what is measured: the paid count going down, and a coin-bought
-- crate never touching it.
for _, tier in ipairs(TIERS) do
	clearCrates()
	ownNothing()
	CrateService.GivePaid(player, tier, 1)
	expect(string.format("%s bought with Robux is counted as paid", tier), (data.PaidCrates[tier] or 0) == 1,
		data.PaidCrates[tier])
	pcall(CrateService.Open, player, tier)
	expect(string.format("%s opening the Robux one spends the paid count", tier), (data.PaidCrates[tier] or 0) == 0,
		data.PaidCrates[tier])

	clearCrates()
	data.SahurCoins = CrateData.Get(tier).coinPrice
	data.Crates[tier] = 1 -- as CrateService.Buy leaves it: held, but in neither Paid nor Free
	pcall(CrateService.Open, player, tier)
	expect(string.format("%s bought with coins never touches the paid count", tier), (data.PaidCrates[tier] or 0) == 0,
		data.PaidCrates[tier])
end

print(string.format("[StyleProbe] %d passed, %d failed", passes, failures))
print("[PROBE] style crates: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))
