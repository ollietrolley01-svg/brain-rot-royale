-- Probe for tools/runtest.ps1 -Probe: the passes, crate luck, coin earning and the brainrot shop,
-- against the real modules with a stand-in player (edit mode).
--
--   * Odds tables for every crate at luck 1 and 2 (what the crate cards show).
--   * Opens thousands of crates through the real CrateService.Open, with and without 2x Crate Luck,
--     and checks each rarity's share against CrateData.EffectiveOdds within 4.5 standard deviations.
--     (Open finishes by firing a RemoteEvent at the player, which a stand-in can't receive; that
--     comes after every change to the profile, so each open is pcall'd and its result read back from
--     the profile.) Pity is reset before each of these opens so it can't skew the shares.
--   * Pity with luck: a long run of Legendary Crates never goes 40 opens without a Mythic or better.
--   * Monetization.EarnCoins with and without 2x SahurCoins, and selling at face value.
--   * Receipts through Monetization.HandleReceipt: the same PurchaseId twice grants once, a pick
--     survives a disconnect (profile saved and reloaded), a lost pick still pays out, a second pick
--     is refused while a prompt is open, and old saves migrate.
-- PlayerData.Save is stubbed (a stand-in profile must never reach a real DataStore), and so is the
-- purchase prompt.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local Monetization = require(modules:WaitForChild("Monetization"))
local CrateService = require(modules:WaitForChild("CrateService"))
local RewardService = require(modules:WaitForChild("RewardService"))
local BrainrotShopService = require(modules:WaitForChild("BrainrotShopService"))

StateSync.Push = function() end
StateSync.Notify = function() end
local saveResult = false
local saves = 0
PlayerData.Save = function()
	saves += 1
	return saveResult
end
-- HandleReceipt refuses a profile that can't save (edit mode has no DataStore); this one "can".
PlayerData.CanSave = function()
	return true
end
-- And it has a Studio-only exception for "no DataStore at all", which would otherwise confirm the
-- save-failure case below. This probe tests the LIVE path, so it says a store exists.
PlayerData.HasStore = function()
	return true
end

local failures = 0
local function expect(label, ok, detail)
	if not ok then
		failures += 1
	end
	print(string.format("[MoneyProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

local function oddsLine(odds)
	local parts = {}
	for _, rarity in ipairs(Rarity.Order) do
		if odds[rarity] then
			table.insert(parts, string.format("%s %.2f", rarity:sub(1, 3), odds[rarity]))
		end
	end
	return table.concat(parts, "  ")
end

-- Odds tables -----------------------------------------------------------------------------------
for _, tier in ipairs(CrateData.Order) do
	local crate = CrateData.Get(tier)
	print(string.format("[MoneyProbe] odds %-10s x1: %s", tier, oddsLine(CrateData.EffectiveOdds(crate, 1))))
	print(string.format("[MoneyProbe] odds %-10s x2: %s", tier, oddsLine(CrateData.EffectiveOdds(crate, 2))))
end

-- Distributions through the real Open -----------------------------------------------------------
local player = { UserId = -424250, Name = "MoneyProbe", DisplayName = "MoneyProbe" }
local data = PlayerData.Load(player)

local function setPass(key, on)
	data.TempPasses[key] = on and (os.time() + 3600) or nil
end

local function openOnce(tier)
	data.Crates[tier] = 1
	local before = #data.Brainrots
	local ownedBefore = {}
	for id in pairs(data.Cosmetics.owned) do
		ownedBefore[id] = true
	end
	pcall(CrateService.Open, player, tier)
	if #data.Brainrots > before then
		local def = BrainrotData.Get(data.Brainrots[#data.Brainrots])
		return def and def.rarity
	end
	for id in pairs(data.Cosmetics.owned) do
		if not ownedBefore[id] then
			local item = CosmeticData.Get(id)
			return item and item.rarity
		end
	end
	return "refund"
end

local function distribution(tier, luck, opens)
	setPass("CrateLuck", luck > 1)
	local actualLuck = Monetization.CrateLuck(player)
	local counts, refunds = {}, 0
	for index = 1, opens do
		data.Pity[tier] = 0
		local rarity = openOnce(tier)
		if rarity == "refund" or rarity == nil then
			refunds += 1
		else
			counts[rarity] = (counts[rarity] or 0) + 1
		end
		if index % 250 == 0 then
			table.clear(data.Brainrots)
			task.wait()
		end
	end
	local expected = CrateData.EffectiveOdds(CrateData.Get(tier), actualLuck)
	local worst, worstRarity, observedPct = 0, nil, {}
	local n = opens - refunds
	for rarity, pct in pairs(expected) do
		local p = pct / 100
		local got = counts[rarity] or 0
		observedPct[rarity] = got / math.max(1, n) * 100
		local sigma = math.sqrt(math.max(1e-9, n * p * (1 - p)))
		local z = math.abs(got - n * p) / sigma
		if z > worst then
			worst, worstRarity = z, rarity
		end
	end
	for rarity in pairs(counts) do
		if not expected[rarity] then
			worst, worstRarity = math.huge, rarity .. " (not in this crate)"
		end
	end
	-- Brainrot crates always hand something over, so any "refund" means an open failed before it
	-- changed the profile, which would quietly shrink the sample.
	expect(string.format("%s luck x%d over %d opens matches its shown odds", tier, luck, n), actualLuck == luck and worst <= 4.5 and refunds == 0,
		string.format("worst %s at %.2f sd; failed opens %d; observed %s", tostring(worstRarity), worst, refunds, oddsLine(observedPct)))
end

for _, spec in ipairs({ { "Common", 6000 }, { "Rare", 6000 }, { "Legendary", 8000 }, { "Mythic", 8000 }, { "Super", 6000 } }) do
	distribution(spec[1], 1, spec[2])
	distribution(spec[1], 2, spec[2])
end

-- Pity still guarantees with luck: never 40 Legendary Crates in a row without Mythic or better.
setPass("CrateLuck", true)
data.Pity.Legendary = 0
local streak, longest, forced = 0, 0, 0
for index = 1, 6000 do
	local counterBefore = data.Pity.Legendary or 0
	local rarity = openOnce("Legendary")
	if rarity and rarity ~= "refund" and Rarity.IsAtLeast(rarity, "Mythic") then
		if counterBefore + 1 >= 40 then
			forced += 1
		end
		streak = 0
	else
		streak += 1
		longest = math.max(longest, streak)
	end
	if index % 250 == 0 then
		table.clear(data.Brainrots)
		task.wait()
	end
end
expect("pity with 2x luck: longest run without Mythic+ stays under 40", longest < 40, string.format("longest %d, pity forced %d times", longest, forced))
setPass("CrateLuck", false)

-- Coins ------------------------------------------------------------------------------------------
data.SahurCoins = 0
setPass("CoinBoost", false)
expect("EarnCoins without the pass pays face value", Monetization.EarnCoins(player, 1000) == 1000 and data.SahurCoins == 1000)
setPass("CoinBoost", true)
expect("EarnCoins with 2x SahurCoins doubles", Monetization.EarnCoins(player, 1000) == 2000 and data.SahurCoins == 3000)
expect("RewardService.AddCoins goes through the same path", RewardService.AddCoins(player, 50) == 100)
local sellBefore = data.SahurCoins
RewardService.GiveBrainrot(player, "Golden Sahur")
RewardService.GiveBrainrot(player, "Golden Sahur")
RewardService.SellBrainrot(player, "Golden Sahur")
expect("selling a brainrot pays face value even with 2x SahurCoins", data.SahurCoins - sellBefore == BrainrotData.Get("Golden Sahur").coinValue,
	data.SahurCoins - sellBefore)
expect("EarnCoins refuses NaN and negatives", Monetization.EarnCoins(player, 0 / 0) == 0 and Monetization.EarnCoins(player, -5) == 0)
setPass("CoinBoost", false)

-- Receipts and the brainrot shop ------------------------------------------------------------------
Monetization.RegisterGrantHandler("Brainrot", function(who, profile, grant)
	BrainrotShopService.Grant(who, profile, grant)
end)
local prompts = 0
BrainrotShopService.Prompt = function()
	prompts += 1
end
local secretProduct = GamepassConfig.BrainrotProduct("Secret")
local commonProduct = GamepassConfig.BrainrotProduct("Common")
local savedIds = { secret = secretProduct.id, common = commonProduct.id }
secretProduct.id, commonProduct.id = 9990001, 9990002

local function count(name)
	return RewardService.CountOf(data, name)
end

table.clear(data.Brainrots)
data.PendingBrainrot = {}
local secretName = BrainrotData.OfRarity("Secret")[2].name
local ok, message = BrainrotShopService.Choose(player, secretName)
expect("choosing a Secret stores the pick and opens one prompt", ok and prompts == 1 and data.PendingBrainrot.Secret and data.PendingBrainrot.Secret.name == secretName, message)
ok, message = BrainrotShopService.Choose(player, BrainrotData.OfRarity("Secret")[3].name)
expect("a second Secret pick is refused while that prompt is open", not ok and data.PendingBrainrot.Secret.name == secretName and prompts == 1, message)

saveResult = false
local decision = Monetization.HandleReceipt(player, { PlayerId = player.UserId, ProductId = 9990001, PurchaseId = "probe-purchase-1" })
expect("receipt grants the picked Secret (save failed, so NotProcessedYet for a retry)",
	decision == Enum.ProductPurchaseDecision.NotProcessedYet and count(secretName) == 1 and data.PendingBrainrot.Secret == nil, tostring(decision))
saveResult = true
decision = Monetization.HandleReceipt(player, { PlayerId = player.UserId, ProductId = 9990001, PurchaseId = "probe-purchase-1" })
expect("the same PurchaseId again confirms without granting a second copy", decision == Enum.ProductPurchaseDecision.PurchaseGranted and count(secretName) == 1,
	tostring(decision))

-- A purchase whose pick never reached the profile still pays out: a Secret they don't own yet.
local ownedSecrets = 0
for _, def in ipairs(BrainrotData.OfRarity("Secret")) do
	if count(def.name) > 0 then
		ownedSecrets += 1
	end
end
decision = Monetization.HandleReceipt(player, { PlayerId = player.UserId, ProductId = 9990001, PurchaseId = "probe-purchase-2" })
local nowOwned, dupes = 0, 0
for _, def in ipairs(BrainrotData.OfRarity("Secret")) do
	local c = count(def.name)
	if c > 0 then
		nowOwned += 1
	end
	if c > 1 then
		dupes += 1
	end
end
expect("a receipt with no stored pick grants a Secret not owned yet", decision == Enum.ProductPurchaseDecision.PurchaseGranted and nowOwned == ownedSecrets + 1 and dupes == 0,
	string.format("%s, owned %d -> %d", tostring(decision), ownedSecrets, nowOwned))

-- Disconnect: pick, the profile is saved and reloaded (a rejoin), then the receipt arrives.
local commonName = BrainrotData.OfRarity("Common")[5].name
ok = BrainrotShopService.Choose(player, commonName)
local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in pairs(value) do
		out[k] = deepCopy(v)
	end
	return out
end
local rejoined = PlayerData.Reconcile(deepCopy(data))
expect("a pending pick survives save and reload", ok and rejoined.PendingBrainrot.Common and rejoined.PendingBrainrot.Common.name == commonName)
for key in pairs(data) do
	data[key] = nil
end
for key, value in pairs(rejoined) do
	data[key] = value
end
local commonBefore = count(commonName)
decision = Monetization.HandleReceipt(player, { PlayerId = player.UserId, ProductId = 9990002, PurchaseId = "probe-purchase-3" })
expect("after the rejoin the receipt grants that exact Common", decision == Enum.ProductPurchaseDecision.PurchaseGranted and count(commonName) == commonBefore + 1,
	tostring(decision))
expect("an unknown product id is left for a retry", Monetization.HandleReceipt(player, { PlayerId = player.UserId, ProductId = 123, PurchaseId = "probe-x" })
	== Enum.ProductPurchaseDecision.NotProcessedYet)
expect("receipts saved through the stub, never a real DataStore", saves >= 1, saves .. " stubbed saves")

-- Migration.
local old = PlayerData.Reconcile({ SahurCoins = 777, Brainrots = { "Golden Sahur" }, PurchaseIds = { "a", "b" } })
expect("old save without PendingBrainrot loads with none, coins, brainrots and purchase ids intact",
	next(old.PendingBrainrot) == nil and old.SahurCoins == 777 and old.Brainrots[1] == "Golden Sahur" and #old.PurchaseIds == 2)
local cleaned = PlayerData.Reconcile({ PendingBrainrot = {
	Secret = { name = secretName, at = 5 }, Common = { name = secretName }, Rare = { name = "Nope" }, Epic = "junk", [3] = { name = secretName },
} })
local kept = {}
for rarity, pending in pairs(cleaned.PendingBrainrot) do
	table.insert(kept, rarity .. "=" .. pending.name)
end
expect("bad PendingBrainrot entries are dropped, good ones kept", #kept == 1 and cleaned.PendingBrainrot.Secret and cleaned.PendingBrainrot.Secret.name == secretName,
	table.concat(kept, ", "))

secretProduct.id, commonProduct.id = savedIds.secret, savedIds.common

-- Paid-crate provenance ------------------------------------------------------------------------------
data.Crates.Rare, data.PaidCrates.Rare = 0, nil
CrateService.Give(player, "Rare", 2)
CrateService.GivePaid(player, "Rare", 1)
expect("a Robux crate is counted as paid on top of earned ones", data.Crates.Rare == 3 and data.PaidCrates.Rare == 1)
pcall(CrateService.Open, player, "Rare")
expect("opening uses the paid crate first", data.Crates.Rare == 2 and data.PaidCrates.Rare == nil)
pcall(CrateService.Open, player, "Rare")
expect("then earned crates, with nothing left marked paid", data.Crates.Rare == 1 and data.PaidCrates.Rare == nil)
local paidLoad = PlayerData.Reconcile({ Crates = { Rare = 2, Epic = 0 }, PaidCrates = { Rare = 5, Epic = 3, Bogus = 4, Legendary = 0 / 0 } })
expect("saved PaidCrates never exceed the crates held and drop unknown tiers", paidLoad.PaidCrates.Rare == 2 and paidLoad.PaidCrates.Epic == nil
	and paidLoad.PaidCrates.Bogus == nil and paidLoad.PaidCrates.Legendary == nil)
expect("old saves have no paid crates", next(PlayerData.Reconcile({ Crates = { Rare = 4 } }).PaidCrates) == nil)

-- The Parachute Crate ---------------------------------------------------------------------------------
local parachuteIds = CosmeticData.OfKind("Parachute")
local chuteCrate = CrateData.Get("Parachute")
expect("the Parachute Crate exists and its luck odds add up", chuteCrate ~= nil and math.abs((function()
	local total = 0
	for _, pct in pairs(CrateData.EffectiveOdds(chuteCrate, 2)) do
		total += pct
	end
	return total
end)() - 100) < 1e-9)
if #parachuteIds == 0 then
	print("[MoneyProbe] note: no Parachute cosmetics yet (claude-df adding them), so opens can only refund")
else
	for _, id in ipairs(parachuteIds) do
		data.Cosmetics.owned[id] = nil
	end
	local gotten, repeats, refunds = {}, 0, 0
	for _ = 1, #parachuteIds + 25 do
		local rarity = openOnce("Parachute")
		if rarity == "refund" then
			refunds += 1
		end
	end
	local owned = 0
	for _, id in ipairs(parachuteIds) do
		if data.Cosmetics.owned[id] then
			owned += 1
		end
	end
	expect("Parachute Crate opens never repeat a parachute and refund once one rarity is exhausted",
		owned <= #parachuteIds and owned + refunds == #parachuteIds + 25, string.format("%d parachutes, %d owned, %d refunds", #parachuteIds, owned, refunds))
end

-- The reveal builds the real canopy at prize size (the same steps as MenuClient's buildPrizeParachute).
local ParachuteModels = require(Shared:WaitForChild("ParachuteModels"))
local sizes, bad = {}, 0
local ids = table.clone(parachuteIds)
table.insert(ids, "NotAParachute")
for _, id in ipairs(ids) do
	local ok, err = pcall(function()
		local measure = ParachuteModels.Build(id, { scale = 1 })
		local _, size = measure:GetBoundingBox()
		measure:Destroy()
		local longest = math.max(size.X, size.Y, size.Z)
		local model = ParachuteModels.Build(id, { scale = longest > 0 and 5.5 / longest or 1 })
		local body = model.PrimaryPart
		if body then
			local centre = model:GetBoundingBox()
			body.PivotOffset = body.CFrame:ToObjectSpace(centre)
		end
		model:PivotTo(CFrame.new(0, 2, 0))
		local box, built = model:GetBoundingBox()
		local builtLongest = math.max(built.X, built.Y, built.Z)
		table.insert(sizes, string.format("%s %.2f", id, builtLongest))
		if math.abs(builtLongest - 5.5) > 0.6 or (box.Position - Vector3.new(0, 2, 0)).Magnitude > 0.05 then
			bad += 1
		end
		model:Destroy()
	end)
	if not ok then
		bad += 1
		table.insert(sizes, id .. " ERROR " .. tostring(err))
	end
end
expect("every parachute prize (and the unknown-id fallback) builds about 5.5 studs long, centred on its pivot", bad == 0, table.concat(sizes, ", "))

print(string.format("[MoneyProbe] finished: %d failure%s", failures, failures == 1 and "" or "s"))
