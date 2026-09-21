-- Probe for tools/runtest.ps1 -Probe: brainrot merging and the Legendary+ odds, against the real
-- modules. Runs inside Studio in edit mode. The player is a stand-in table (PlayerData keys
-- sessions by UserId), so StateSync.Push is stubbed out: it fires a RemoteEvent at the player,
-- which needs a real Player. The plugin has its own copy of every module, so the stub only
-- affects this probe.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local DailySpinData = require(Shared:WaitForChild("DailySpinData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local RewardService = require(modules:WaitForChild("RewardService"))

StateSync.Push = function() end

-- Compile (not run) every script merging touches, client ones included: a probe never runs
-- LocalScripts, and a syntax error in MenuClient would otherwise only show in a full runtest.
local compileFailures = 0
do
	local StarterPlayerScripts = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
	local sources = {
		StarterPlayerScripts:WaitForChild("MenuClient"), StarterPlayerScripts:WaitForChild("MergeDialog"),
		StarterPlayerScripts:WaitForChild("HudClient"), game:GetService("ServerScriptService"):WaitForChild("Bootstrap"),
		modules:WaitForChild("RewardService"), modules:WaitForChild("CompanionService"), modules:WaitForChild("ShowcaseService"),
		modules:WaitForChild("StateSync"), modules:WaitForChild("PlayerData"), Shared:WaitForChild("BrainrotData"),
		Shared:WaitForChild("CrateData"), Shared:WaitForChild("DailySpinData"), Shared:WaitForChild("ShopRotation"),
	}
	for _, script in ipairs(sources) do
		local compiled, err = loadstring(script.Source, script.Name)
		if not compiled then
			compileFailures += 1
		end
		print(string.format("[PROBE] %s compiles %s%s", compiled and "PASS" or "FAIL", script:GetFullName(), compiled and "" or ("  (" .. tostring(err) .. ")")))
	end
end

local failures = compileFailures
local function expect(label, ok, detail)
	if not ok then
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

-- Numbers ----------------------------------------------------------------------
expect("StarBonus 0 = 1", BrainrotData.StarBonus(0) == 1)
-- The five-star multiplier, from the data rather than a copy of it, so retuning BonusPerStar
-- doesn't break the probe. It is asserted to be +50% because that's the balance Oliver asked for.
local FULL = 1 + BrainrotData.BonusPerStar * BrainrotData.MaxStars
expect("five stars is +50%", math.abs(FULL - 1.5) < 1e-9, FULL)
expect("StarBonus 5 = full bonus", math.abs(BrainrotData.StarBonus(5) - FULL) < 1e-9, BrainrotData.StarBonus(5))
expect("StarBonus clamps 9 to 5", BrainrotData.StarBonus(9) == BrainrotData.StarBonus(5))
expect("MergeCost 0..4 = 1,1,2,2,3", BrainrotData.MergeCost(0) == 1 and BrainrotData.MergeCost(1) == 1
	and BrainrotData.MergeCost(2) == 2 and BrainrotData.MergeCost(3) == 2 and BrainrotData.MergeCost(4) == 3)
expect("MergeCost at max is nil", BrainrotData.MergeCost(5) == nil)
expect("StarText 0 is empty", BrainrotData.StarText(0) == "")
expect("StarText 2", BrainrotData.StarText(2) == "★★☆☆☆", BrainrotData.StarText(2))

local common = BrainrotData.Get("Tung Tung Tung Sahur")
local legendary = BrainrotData.Get("Golden Sahur")
for _, def in ipairs({ common, legendary }) do
	local fresh = BrainrotData.Stats(def, 1)
	local freshZero = BrainrotData.Stats(def, 1, 0)
	local maxed = BrainrotData.Stats(def, 1, 5)
	local both = BrainrotData.Stats(def, 10, 5)
	print(string.format("[PROBE] %s: fresh %d dmg %d hp | 5 stars %d dmg %d hp | Lv10 + 5 stars %d dmg %d hp",
		def.name, fresh.damage, fresh.health, maxed.damage, maxed.health, both.damage, both.health))
	expect(def.name .. " nil stars == 0 stars", fresh.damage == freshZero.damage and fresh.health == freshZero.health)
	expect(def.name .. " 5 stars health ~full bonus", math.abs(maxed.health / fresh.health - FULL) < 0.02, maxed.health / fresh.health)
	expect(def.name .. " 5 stars damage ~full bonus", math.abs(maxed.damage / fresh.damage - FULL) < 0.06, maxed.damage / fresh.damage)
	expect(def.name .. " stats.stars", maxed.stars == 5 and fresh.stars == 0)
end

-- Merge flow ---------------------------------------------------------------------
local player = { UserId = -424242, Name = "MergeProbe", DisplayName = "MergeProbe" }
local data = PlayerData.Load(player)
expect("profile has a Stars table", type(data.Stars) == "table")

local name = common.name
local function count()
	return RewardService.CountOf(data, name)
end

local ok, message = RewardService.MergeBrainrot(player, name)
expect("merge refused when not owned", not ok, message)

RewardService.GiveBrainrot(player, name)
ok, message = RewardService.MergeBrainrot(player, name)
expect("merge refused with no spares", not ok and count() == 1 and (data.Stars[name] or 0) == 0, message)

for _ = 1, 9 do
	RewardService.GiveBrainrot(player, name)
end
-- A different brainrot in between, so removal has to pick the right entries.
RewardService.GiveBrainrot(player, "Trippi Troppi")
expect("10 copies before merging", count() == 10, count())

local expectedCounts = { 9, 8, 6, 4, 1 }
for star = 1, 5 do
	ok, message = RewardService.MergeBrainrot(player, name)
	expect(string.format("merge to %d stars", star), ok and data.Stars[name] == star and count() == expectedCounts[star],
		string.format("%s; stars %s, copies %d", tostring(message), tostring(data.Stars[name]), count()))
end
expect("other brainrot untouched", RewardService.CountOf(data, "Trippi Troppi") == 1)
ok, message = RewardService.MergeBrainrot(player, name)
expect("merge refused at max", not ok and data.Stars[name] == 5 and count() == 1, message)

ok, message = RewardService.MergeBrainrot(player, "Not A Brainrot")
expect("merge refused for unknown name", not ok, message)

-- Selling guards -------------------------------------------------------------------
ok, message = RewardService.SellBrainrot(player, name)
expect("SELL 1 refuses the last merged copy", not ok and count() == 1, message)

RewardService.GiveBrainrot(player, name)
ok, message = RewardService.SellBrainrot(player, name)
expect("SELL 1 sells a spare of a merged brainrot", ok and count() == 1, message)

RewardService.GiveBrainrot(player, name)
RewardService.GiveBrainrot(player, name)
RewardService.GiveBrainrot(player, "Pizzarino Blobbo")
ok, message = RewardService.SellAllOfRarity(player, "Common")
expect("SELL ALL keeps one merged copy, sells the rest", ok and count() == 1
	and RewardService.CountOf(data, "Pizzarino Blobbo") == 0 and RewardService.CountOf(data, "Trippi Troppi") == 0, message)
ok, message = RewardService.SellAllOfRarity(player, "Common")
expect("SELL ALL with only a merged copy left sells nothing", not ok and count() == 1, message)
expect("stars survive selling", data.Stars[name] == 5)

-- Stars survive losing every copy (a trade), and come back on a new one.
table.remove(data.Brainrots, table.find(data.Brainrots, name))
expect("no copies left", count() == 0)
RewardService.GiveBrainrot(player, name)
local state = StateSync.Build(player)
local entry = nil
for _, item in ipairs(state and state.brainrots or {}) do
	if item.name == name then
		entry = item
	end
end
expect("profile snapshot carries stars", entry ~= nil and entry.stars == 5, entry and entry.stars)
-- Deliberately no PlayerData.Release: it saves, and with API access on that would write this
-- stand-in profile to the real DataStore.

-- Double-click / stale dialog: the second confirm carries the old star count and must be refused
-- without spending anything.
local gum = "Bubblo Gummo"
for _ = 1, 3 do
	RewardService.GiveBrainrot(player, gum)
end
ok, message = RewardService.MergeBrainrot(player, gum, 0)
expect("confirm from 0 stars merges", ok and data.Stars[gum] == 1 and RewardService.CountOf(data, gum) == 2, message)
ok, message = RewardService.MergeBrainrot(player, gum, 0)
expect("repeat confirm from 0 stars is refused and spends nothing", not ok and data.Stars[gum] == 1 and RewardService.CountOf(data, gum) == 2, message)
ok, message = RewardService.MergeBrainrot(player, gum, 1)
expect("confirm from the current 1 star merges", ok and data.Stars[gum] == 2 and RewardService.CountOf(data, gum) == 1, message)

-- Open trade: refused, nothing touched.
for _ = 1, 4 do
	RewardService.GiveBrainrot(player, gum)
end
local before = #data.Brainrots
local realIsTrading = RewardService.IsTrading
RewardService.IsTrading = function()
	return true
end
ok, message = RewardService.MergeBrainrot(player, gum, 2)
RewardService.IsTrading = realIsTrading
expect("merge refused during a trade, nothing changed", not ok and data.Stars[gum] == 2 and #data.Brainrots == before, message)

-- Order: everything else keeps its place and the oldest copy is the one kept.
data.Brainrots = { "Mudlo Splosh", gum, "Trippi Troppi", gum, "Cactino Pokko", gum, gum }
data.Stars[gum] = 2
ok, message = RewardService.MergeBrainrot(player, gum, 2)
local order = table.concat(data.Brainrots, ",")
expect("merge keeps order and the oldest copy", ok and order == "Mudlo Splosh,Bubblo Gummo,Trippi Troppi,Bubblo Gummo,Cactino Pokko",
	order)

-- Saves from before merging existed load unchanged, with no stars.
local oldSave = {
	SahurCoins = 12345,
	Brainrots = { "Golden Sahur", "Trippi Troppi", "Trippi Troppi" },
	Crates = { Common = 2, Legendary = 1 },
	CompanionXp = { ["Golden Sahur"] = 1234 },
	Pity = { Epic = 7 },
	Companion = "Golden Sahur",
}
local migrated = PlayerData.Reconcile(oldSave)
expect("old save: coins, brainrots, crates, XP, pity and companion unchanged",
	migrated.SahurCoins == 12345 and table.concat(migrated.Brainrots, ",") == "Golden Sahur,Trippi Troppi,Trippi Troppi"
		and migrated.Crates.Common == 2 and migrated.Crates.Legendary == 1 and migrated.CompanionXp["Golden Sahur"] == 1234
		and migrated.Pity.Epic == 7 and migrated.Companion == "Golden Sahur")
expect("old save: empty Stars", type(migrated.Stars) == "table" and next(migrated.Stars) == nil)
local cleaned = PlayerData.Reconcile({ Stars = { A = 3, B = 9, C = -1, D = 2.7, E = "x", F = 0, [5] = 2 } })
local keys = {}
for key, value in pairs(cleaned.Stars) do
	table.insert(keys, string.format("%s=%s", tostring(key), tostring(value)))
end
table.sort(keys)
expect("bad Stars entries cleaned", table.concat(keys, ",") == "A=3,B=5,D=2", table.concat(keys, ","))
local roundTrip = PlayerData.Reconcile({ Stars = { ["Golden Sahur"] = 4 }, Brainrots = { "Golden Sahur" } })
expect("saved stars load back", roundTrip.Stars["Golden Sahur"] == 4)

-- Levels and stars stack multiplicatively.
local stacked = BrainrotData.Stats(legendary, 10, 5)
local expectedHealth = math.floor(BrainrotData.RarityHealth.Legendary * BrainrotData.LevelBonus(10) * BrainrotData.StarBonus(5) + 0.5)
expect("level 10 and 5 stars stack", stacked.health == expectedHealth, string.format("%d vs %d", stacked.health, expectedHealth))

-- The trade rule. Stars are a per-profile record of what that player has merged, paid for in
-- their own copies; a trade moves plain copies. So across a trade: the giver keeps their stars,
-- the receiver keeps exactly theirs (the incoming copy doesn't carry the giver's), no stars are
-- created, and a later copy comes back at the rank its owner already paid for. The move below is
-- the same table.remove / table.insert TradeService's execute() does; the real TradeService
-- can't be driven here because it fires RemoteEvents at the players.
local giver = { UserId = -424243, Name = "TradeGiver", DisplayName = "TradeGiver" }
local receiver = { UserId = -424244, Name = "TradeReceiver", DisplayName = "TradeReceiver" }
local giverData = PlayerData.Load(giver)
local receiverData = PlayerData.Load(receiver)
local species = "Frigo Camelo"
for _ = 1, 3 do
	RewardService.GiveBrainrot(giver, species)
end
RewardService.MergeBrainrot(giver, species, 0)
RewardService.MergeBrainrot(giver, species, 1)
for _ = 1, 2 do
	RewardService.GiveBrainrot(receiver, species)
end
RewardService.MergeBrainrot(receiver, species, 0)
expect("trade setup: giver 2 stars on 1 copy, receiver 1 star on 1 copy",
	giverData.Stars[species] == 2 and RewardService.CountOf(giverData, species) == 1
		and receiverData.Stars[species] == 1 and RewardService.CountOf(receiverData, species) == 1)

local function snapshotStars(who)
	for _, item in ipairs(StateSync.Build(who).brainrots) do
		if item.name == species then
			return item.stars
		end
	end
	return nil
end
local starsBefore = giverData.Stars[species] + receiverData.Stars[species]
table.remove(giverData.Brainrots, table.find(giverData.Brainrots, species))
table.insert(receiverData.Brainrots, species)

expect("after trade: giver keeps the 2 stars it paid for, with no copy", giverData.Stars[species] == 2 and RewardService.CountOf(giverData, species) == 0)
expect("after trade: receiver's copy is at the receiver's own 1 star, not the giver's 2",
	receiverData.Stars[species] == 1 and snapshotStars(receiver) == 1)
expect("a trade creates no stars", giverData.Stars[species] + receiverData.Stars[species] == starsBefore)
expect("receiver's snapshot shows the stars map for the trade screen", StateSync.Build(receiver).stars[species] == 1)
ok, message = RewardService.MergeBrainrot(giver, species, 2)
expect("giver can't merge with no copy", not ok and giverData.Stars[species] == 2, message)
ok, message = RewardService.SellBrainrot(giver, species)
expect("giver can't sell a copy it no longer has", not ok, message)

-- Merging again costs the receiver its own copies, whoever they came from.
ok, message = RewardService.MergeBrainrot(receiver, species, 1)
expect("receiver merges using the traded-in copy as a spare",
	ok and receiverData.Stars[species] == 2 and RewardService.CountOf(receiverData, species) == 1, message)

-- A later copy comes back at the rank the giver already paid for; no new stars appear.
RewardService.GiveBrainrot(giver, species)
expect("giver's new copy is at its own 2 stars", snapshotStars(giver) == 2 and giverData.Stars[species] == 2)

-- Stars are never worth coins: selling a merged brainrot's spare pays the plain coin value.
RewardService.GiveBrainrot(receiver, species)
local coinsBefore = receiverData.SahurCoins
ok, message = RewardService.SellBrainrot(receiver, species)
expect("selling a merged spare pays the plain coin value", ok and receiverData.SahurCoins - coinsBefore == BrainrotData.Get(species).coinValue,
	string.format("%s (+%d)", tostring(message), receiverData.SahurCoins - coinsBefore))

-- Odds -------------------------------------------------------------------------------
local function atLeast(odds, rarity)
	local total, share = 0, 0
	for tier, weight in pairs(odds) do
		total += weight
		if Rarity.IsAtLeast(tier, rarity) then
			share += weight
		end
	end
	return share / total * 100
end
for _, tier in ipairs(CrateData.Order) do
	local crate = CrateData.Get(tier)
	if (crate.category or "Brainrot") == "Brainrot" then
		local total = 0
		for _, weight in pairs(crate.odds) do
			total += weight
		end
		print(string.format("[PROBE] %-16s total %.1f  Legendary+ %.1f%%  Mythic+ %.1f%%  Secret %.1f%%  pity %s",
			crate.name, total, atLeast(crate.odds, "Legendary"), atLeast(crate.odds, "Mythic"), atLeast(crate.odds, "Secret"),
			crate.pity and (crate.pity.rarity .. " in " .. crate.pity.every) or "-"))
		expect(crate.name .. " odds total 100", math.abs(total - 100) < 1e-6, total)
	end
end
expect("Rare Crate Legendary <= 3%", atLeast(CrateData.Get("Rare").odds, "Legendary") <= 3)
expect("Legendary Crate Mythic+ <= 8%", atLeast(CrateData.Get("Legendary").odds, "Mythic") <= 8)
for _, segment in ipairs(DailySpinData.Segments) do
	if segment.kind == "Brainrot" then
		expect("spin brainrot Legendary <= 5%", atLeast(segment.rarities, "Legendary") <= 5)
	end
end

print(string.format("[PROBE] merge probe finished: %d failure%s", failures, failures == 1 and "" or "s"))
