-- Probe for tools/runtest.ps1 -Probe: Rot Rank and Prestige, Brain Cells, gun mastery, the Rot Index
-- and the Cell Shop, against the real modules. Runs inside Studio in edit mode.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/progression_probe.lua
--
-- Players are stand-in tables (PlayerData keys sessions by UserId), so anything that fires a remote
-- at one or asks Roblox about its passes is stubbed. The plugin has its own copy of every module, so
-- the stubs only affect this probe. PlayerData.Release is never called: it saves.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayerScripts = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = ServerScriptService:WaitForChild("Modules")

local failures = 0
local passes = 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

-- Compile every file progression touches, client ones included (a probe never runs LocalScripts).
for _, script in ipairs({
	Shared:WaitForChild("ProgressionData"), Shared:WaitForChild("AchievementData"),
	modules:WaitForChild("ProgressionService"), modules:WaitForChild("PlayerData"), modules:WaitForChild("StateSync"),
	modules:WaitForChild("BattlePassService"), modules:WaitForChild("MatchService"), modules:WaitForChild("NameplateService"),
	ServerScriptService:WaitForChild("Bootstrap"),
	StarterPlayerScripts:WaitForChild("ProgressionPanel"), StarterPlayerScripts:WaitForChild("MenuClient"),
	StarterPlayerScripts:WaitForChild("HudClient"),
}) do
	local compiled, err = loadstring(script.Source, script.Name)
	expect("compiles " .. script:GetFullName(), compiled ~= nil, not compiled and err or nil)
end

local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local ProgressionData = require(Shared:WaitForChild("ProgressionData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local okRequire, requireErr = pcall(function()
	require(modules:WaitForChild("ProgressionService"))
	require(modules:WaitForChild("NameplateService"))
	require(StarterPlayerScripts:WaitForChild("ProgressionPanel"))
end)
expect("ProgressionService, NameplateService and ProgressionPanel require", okRequire, requireErr)

local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local Monetization = require(modules:WaitForChild("Monetization"))
local Combatants = require(modules:WaitForChild("Combatants"))
local ProgressionService = require(modules:WaitForChild("ProgressionService"))

local toasts = {}
StateSync.Push = function() end
StateSync.Notify = function(_player, message)
	table.insert(toasts, message)
end
Monetization.GetPasses = function()
	return {}
end
-- Stand-in players and bots for mastery.
Combatants.IsPlayer = function(token)
	return type(token) == "table" and token.isProbePlayer == true
end
Combatants.IsBot = function(token)
	return type(token) == "table" and token.isBot == true
end

local nextId = -7070000
local function fakePlayer(name)
	nextId -= 1
	local attributes = {}
	local player = { UserId = nextId, Name = name, DisplayName = name, Parent = game, isProbePlayer = true, attributes = attributes }
	function player:SetAttribute(key, value)
		attributes[key] = value
	end
	function player:GetAttribute(key)
		return attributes[key]
	end
	return player
end
local BOT = { isBot = true }

--------------------------------------------------------------------------------
-- Curve and tables
--------------------------------------------------------------------------------

print(string.format("[PROBE] PrestigeXp %d; XpToNext 1 %d, 49 %d, 99 %d", ProgressionData.PrestigeXp,
	ProgressionData.XpToNext(1), ProgressionData.XpToNext(49), ProgressionData.XpToNext(99)))
expect("PrestigeXp is 113,360 (the halved curve Oliver asked for)", ProgressionData.PrestigeXp == 113360, ProgressionData.PrestigeXp)
expect("number wording: commas and the Cell plural", ProgressionData.Commas(0) == "0" and ProgressionData.Commas(999) == "999"
	and ProgressionData.Commas(1000) == "1,000" and ProgressionData.Commas(1234567) == "1,234,567" and ProgressionData.Commas(-2500) == "-2,500"
	and ProgressionData.Cells(1) == "1 Brain Cell" and ProgressionData.Cells(24000) == "24,000 Brain Cells",
	ProgressionData.Commas(1234567) .. " / " .. ProgressionData.Cells(1))
expect("RankForXp(0) = 1", ProgressionData.RankForXp(0) == 1)
expect("RankForXp(PrestigeXp) = MaxRank", ProgressionData.RankForXp(ProgressionData.PrestigeXp) == ProgressionData.MaxRank)
expect("RankForXp(huge) = MaxRank", ProgressionData.RankForXp(1e12) == ProgressionData.MaxRank)
local boundariesOk = true
for rank = 2, ProgressionData.MaxRank do
	local start = ProgressionData.RankStart(rank)
	if ProgressionData.RankForXp(start) ~= rank or ProgressionData.RankForXp(start - 1) ~= rank - 1 then
		boundariesOk = false
		print("[PROBE] boundary wrong at rank " .. rank)
	end
end
expect("every rank boundary lands exactly", boundariesOk)
local r, into, need = ProgressionData.RankProgress(ProgressionData.RankStart(10) + 5)
expect("RankProgress mid-rank", r == 10 and into == 5 and need == ProgressionData.XpToNext(10), string.format("%d %d %s", r, into, tostring(need)))

local crateRanks, rankCells, legendaryCrate = {}, 0, false
for rank = 2, ProgressionData.MaxRank do
	local reward = ProgressionData.RankReward(rank, 0)
	rankCells += reward.cells
	if reward.crate then
		table.insert(crateRanks, rank .. "=" .. reward.crate)
		if Rarity.IsAtLeast(reward.crate, "Legendary") then
			legendaryCrate = true
		end
	end
end
print("[PROBE] rank crates: " .. table.concat(crateRanks, ", ") .. "; Cells per prestige at P0: " .. rankCells)
expect("five rank crates, none Legendary or better", #crateRanks == 5 and not legendaryCrate, table.concat(crateRanks, ", "))
expect("prestige 10 pays double rank Cells", ProgressionData.RankReward(10, 10).cells == ProgressionData.RankReward(10, 0).cells * 2)

expect("MasteryTier 9 = 0, 10 = 1, 74 = 2, 75 = 3, 600 = 6", ProgressionData.MasteryTier(9) == 0 and ProgressionData.MasteryTier(10) == 1
	and ProgressionData.MasteryTier(74) == 2 and ProgressionData.MasteryTier(75) == 3 and ProgressionData.MasteryTier(600) == 6
	and ProgressionData.MasteryTier(nil) == 0)
local weaponCount, stagedCount, aStagedGun = 0, 0, nil
for id, def in pairs(WeaponData.Weapons) do
	weaponCount += 1
	if def.staged then
		stagedCount += 1
		aStagedGun = aStagedGun or id
	end
end
expect("mastery lists every gun that can be looted, and no staged one", weaponCount > 27
	and #ProgressionData.MasteryWeapons() == weaponCount - stagedCount,
	string.format("%d listed, %d guns, %d staged", #ProgressionData.MasteryWeapons(), weaponCount, stagedCount))
if aStagedGun then
	local withPoints = ProgressionData.MasteryWeapons({ [aStagedGun] = 40 })
	expect("a staged gun shows once it has points, so earned mastery is never hidden",
		table.find(withPoints, aStagedGun) ~= nil and #withPoints == #ProgressionData.MasteryWeapons() + 1
		and table.find(ProgressionData.MasteryWeapons(), aStagedGun) == nil, aStagedGun)
	expect("a staged gun with no points stays off the list", table.find(ProgressionData.MasteryWeapons({ [aStagedGun] = 0 }), aStagedGun) == nil)
else
	print("[PROBE] note: no staged guns in WeaponData right now, so the staged filter saw no sample")
end

local today = ProgressionData.Day(os.time())
local shopOk, shopDetail, shopSeen = true, nil, 0
for day = today - 200, today + 200 do
	for _, offer in ipairs(ProgressionData.ShopOffers(day)) do
		if offer.kind == "Brainrot" then
			shopSeen += 1
			local def = offer.brainrot and BrainrotData.Get(offer.brainrot)
			if not def or def.rarity ~= offer.rarity or Rarity.IsAtLeast(def.rarity, ProgressionData.ShopRarityCeiling) then
				shopOk, shopDetail = false, string.format("day %d %s %s", day, offer.id, tostring(offer.brainrot))
			end
		end
	end
end
expect("401 days of Cell Shop: every brainrot offer real, on its slot's rarity, below Legendary", shopOk and shopSeen == 401 * 4,
	shopDetail or (shopSeen .. " brainrot offers seen"))
local first = ProgressionData.ShopOffers(today)[4].brainrot
ProgressionData.ShopOffers(today + 1)
expect("a day's offers are the same when drawn again", ProgressionData.ShopOffers(today)[4].brainrot == first)

--------------------------------------------------------------------------------
-- Save data
--------------------------------------------------------------------------------

local default = ProgressionData.Reconcile(nil)
expect("Reconcile(nil) is a version-0 default", default.v == 0 and default.xp == 0 and default.cells == 0 and next(default.index) == nil)

local hugeMastery, hugeIndex = {}, {}
for i = 1, 400 do
	hugeMastery["gun" .. i] = i
end
for i = 1, 2000 do
	hugeIndex["name" .. i] = 1
end
local dirty = ProgressionData.Reconcile({
	v = 99, xp = 0 / 0, total = -5, over = math.huge, prestige = 55, cells = "lots", cellsEarned = 12.7,
	mastery = hugeMastery, index = hugeIndex, pages = { Common = true, Bogus = true, Rare = "yes" },
	shop = { day = -3, bought = { common = 1.5, epic = -2, [5] = 1, snack = math.huge } },
})
local masteryKeys, indexKeys = 0, 0
for _ in pairs(dirty.mastery) do
	masteryKeys += 1
end
for _ in pairs(dirty.index) do
	indexKeys += 1
end
expect("Reconcile clamps numbers", dirty.v == ProgressionData.Version and dirty.xp == 0 and dirty.total == 0
	and dirty.over == ProgressionData.OverflowXp and dirty.prestige == ProgressionData.MaxPrestige and dirty.cells == 0
	and dirty.cellsEarned == 12, HttpService:JSONEncode({ dirty.v, dirty.xp, dirty.total, dirty.over, dirty.prestige, dirty.cells, dirty.cellsEarned }))
expect("Reconcile caps mastery at 128 keys and the Index at 512", masteryKeys == 128 and indexKeys == 512, masteryKeys .. " / " .. indexKeys)
expect("Reconcile keeps only real rarity pages set to true", dirty.pages.Common == true and dirty.pages.Bogus == nil and dirty.pages.Rare == nil)
expect("Reconcile cleans the shop", dirty.shop.day == 0 and dirty.shop.bought.common == 1 and dirty.shop.bought.epic == nil
	and dirty.shop.bought[5] == nil and dirty.shop.bought.snack == 99)

local good = {
	v = 1, xp = 12345, total = 400000, over = 10, prestige = 2, cells = 777, cellsEarned = 9000,
	mastery = { SahurPistol = 80 }, index = { ["Trippi Troppi"] = 2, ["Pizzarino Blobbo"] = 1 }, pages = { Secret = true },
	shop = { day = today, bought = { rare = 1 } },
}
local roundTrip = ProgressionData.Reconcile(HttpService:JSONDecode(HttpService:JSONEncode(good)))
expect("a clean Progression survives a JSON round trip unchanged", HttpService:JSONEncode(roundTrip) == HttpService:JSONEncode(ProgressionData.Reconcile(good))
	and roundTrip.xp == 12345 and roundTrip.prestige == 2 and roundTrip.mastery.SahurPistol == 80 and roundTrip.index["Trippi Troppi"] == 2
	and roundTrip.pages.Secret == true and roundTrip.shop.bought.rare == 1)

-- A save from before progression: nothing it had is reinterpreted, and it gains a v0 Progression.
local oldSave = {
	SahurCoins = 12345, Brainrots = { "Trippi Troppi", "Trippi Troppi", "Pizzarino Blobbo" },
	Crates = { Common = 3, Rare = 1 }, Pass = { xp = 61000, claimedFree = { ["1"] = true }, claimedPremium = {} },
	Stats = { wins = 4, kills = 90, matches = 30 }, Lifetime = { chests = 50, damage = 9000 },
	Stars = { ["Trippi Troppi"] = 2 }, CompanionXp = { ["Mudlo Splosh"] = 800 }, Achievements = { kill1 = true }, Title = "kill1",
}
local before = PlayerData.Reconcile(oldSave)
expect("old save loads with a version-0 Progression", type(before.Progression) == "table" and before.Progression.v == 0)
expect("old save's own fields are untouched", before.SahurCoins == 12345 and #before.Brainrots == 3 and before.Crates.Rare == 1
	and before.Pass.xp == 61000 and before.Stats.kills == 90 and before.Lifetime.chests == 50 and before.Stars["Trippi Troppi"] == 2
	and before.CompanionXp["Mudlo Splosh"] == 800 and before.Title == "kill1")
expect("old save gains the four progression counters at 0", before.Lifetime.rankScore == 0 and before.Lifetime.mastered == 0
	and before.Lifetime.rotmasters == 0 and before.Lifetime.discovered == 0)
local withProgression = table.clone(oldSave)
withProgression.Progression = good
expect("a save with Progression keeps it", PlayerData.Reconcile(withProgression).Progression.xp == 12345)

--------------------------------------------------------------------------------
-- Migration
--------------------------------------------------------------------------------

local veteran = fakePlayer("ProbeVeteran")
local vData = PlayerData.Load(veteran)
for key, value in pairs(PlayerData.Reconcile(oldSave)) do
	vData[key] = value
end
local cratesBefore = HttpService:JSONEncode(vData.Crates)
local coinsBefore = vData.SahurCoins
ProgressionService.OnProfileLoaded(veteran)
local vp = vData.Progression
local vetRank = ProgressionData.RankForXp(61000)
local vetCells = 0
for rank = 2, vetRank do
	vetCells += ProgressionData.RankReward(rank, 0).cells
end
print(string.format("[PROBE] veteran with 61,000 pass XP: rank %d, %d Brain Cells backfilled", vp and ProgressionData.RankForXp(vp.xp) or -1, vp and vp.cells or -1))
expect("veteran migrated from pass XP", vp.v == 1 and vp.xp == 61000 and vp.total == 61000 and ProgressionData.RankForXp(vp.xp) == vetRank)
expect("backfill pays Cells for every rank reached", vp.cells == vetCells and vp.cellsEarned == vetCells, vp.cells .. " vs " .. vetCells)
expect("backfill pays no crates", HttpService:JSONEncode(vData.Crates) == cratesBefore)
expect("Index backfilled from owned, starred and companion-XP brainrots", vp.index["Trippi Troppi"] == 1
	and vp.index["Pizzarino Blobbo"] == 1 and vp.index["Mudlo Splosh"] == 1)
expect("rank and prestige attributes set", veteran.attributes.RotRank == vetRank and veteran.attributes.Prestige == 0)
expect("rankScore and discovered counters topped up", vData.Lifetime.rankScore == vetRank and vData.Lifetime.discovered == 3,
	vData.Lifetime.rankScore .. " / " .. vData.Lifetime.discovered)
expect("rank achievements paid their coins", vData.Achievements.rank25 == true and vData.SahurCoins > coinsBefore)
ProgressionService.OnProfileLoaded(veteran)
expect("migration runs once", vp.cells == vetCells and vp.xp == 61000)
expect("the backfill marks its ranks paid", vp.paidRank == vetRank, vp.paidRank)
-- Earning again must pay only the ranks above the backfill, never the ones it already paid for.
local vetNext = ProgressionData.RankReward(vetRank + 1, 0).cells
ProgressionService.AddXp(veteran, ProgressionData.RankStart(vetRank + 1) - vp.xp)
expect("earning after a backfill pays only the new rank", vp.cells == vetCells + vetNext,
	string.format("%d, want %d", vp.cells, vetCells + vetNext))

-- Pass XP arriving before the join hook: the event's own XP is counted once, not twice.
local early = fakePlayer("ProbeEarly")
local eData = PlayerData.Load(early)
eData.Pass.xp = 5000 + 700
ProgressionService.OnPassXp(early, 700)
expect("pass XP before migration counts once", eData.Progression.v == 1 and eData.Progression.total == 5700 and eData.Progression.xp == 5700,
	eData.Progression.total)

--------------------------------------------------------------------------------
-- Rank, overflow and prestige
--------------------------------------------------------------------------------

local climber = fakePlayer("ProbeClimber")
local cData = PlayerData.Load(climber)
ProgressionService.OnProfileLoaded(climber)
local cp = cData.Progression
cp.xp = ProgressionData.RankStart(20) - 10
local cellsBefore, rareBefore = cp.cells, cData.Crates.Rare or 0
ProgressionService.AddXp(climber, 20)
expect("crossing rank 20 pays its Cells and a Rare Crate", ProgressionData.RankForXp(cp.xp) == 20
	and cp.cells - cellsBefore == ProgressionData.RankReward(20, 0).cells and (cData.Crates.Rare or 0) == rareBefore + 1)

local ok, message = ProgressionService.Prestige(climber, 0)
expect("prestige refused below MaxRank", not ok and cp.prestige == 0, message)

cp.xp = ProgressionData.PrestigeXp - 100
cellsBefore = cp.cells
ProgressionService.AddXp(climber, 100 + ProgressionData.OverflowXp + 5)
expect("XP past MaxRank banks into overflow and pays", cp.xp == ProgressionData.PrestigeXp and cp.over == 5
	and cp.cells - cellsBefore == ProgressionData.RankReward(100, 0).cells + ProgressionData.OverflowReward(0), cp.cells - cellsBefore)

ok, message = ProgressionService.Prestige(climber, 3)
expect("prestige refused on a stale expected value", not ok and cp.prestige == 0, message)
cellsBefore = cp.cells
ok, message = ProgressionService.Prestige(climber, 0)
expect("prestige works at MaxRank", ok and cp.prestige == 1 and cp.xp == 0 and cp.cells - cellsBefore == ProgressionData.PrestigeReward(1).cells, message)
expect("prestige lifts rankScore to 101 and the attribute", cData.Lifetime.rankScore == 101 and climber.attributes.Prestige == 1 and cData.Achievements.prestige1 == true)
ok, message = ProgressionService.Prestige(climber, 0)
expect("a repeated prestige click is refused", not ok and cp.prestige == 1, message)
cp.prestige, cp.xp = ProgressionData.MaxPrestige, ProgressionData.PrestigeXp
ok, message = ProgressionService.Prestige(climber, ProgressionData.MaxPrestige)
expect("no prestige past the max", not ok and cp.prestige == ProgressionData.MaxPrestige, message)
cp.prestige, cp.xp = 1, 0

local passTierBefore = cData.Pass.xp
ProgressionService.AddXp(climber, 1000)
expect("Rot Rank XP never touches the pass", cData.Pass.xp == passTierBefore)

--------------------------------------------------------------------------------
-- Mastery
--------------------------------------------------------------------------------

local shooter = fakePlayer("ProbeShooter")
local sData = PlayerData.Load(shooter)
ProgressionService.OnProfileLoaded(shooter)
local sp = sData.Progression
local totalBefore = sp.total
for _ = 1, 10 do
	ProgressionService.OnKillCredited(shooter, BOT, "SahurPistol")
end
expect("10 bot kills reach Bronze", sp.mastery.SahurPistol == 10 and ProgressionData.MasteryTier(sp.mastery.SahurPistol) == 1)
expect("Bronze pays its Cells and Rank XP", sp.cells == ProgressionData.MasteryTiers[1].cells and sp.total - totalBefore == ProgressionData.MasteryTiers[1].xp,
	sp.cells .. " cells, " .. (sp.total - totalBefore) .. " xp")
ProgressionService.OnKillCredited(shooter, fakePlayer("Victim"), "SahurPistol")
expect("a player kill is worth 3", sp.mastery.SahurPistol == 13)
ProgressionService.OnKillCredited(shooter, BOT, "Companion:Trippi Troppi")
ProgressionService.OnKillCredited(shooter, BOT, "ExplosiveBarrel")
ProgressionService.OnKillCredited(shooter, BOT, "RotMine")
ProgressionService.OnKillCredited(shooter, BOT, "NotAGun")
ProgressionService.OnKillCredited(shooter, BOT, nil)
ProgressionService.OnKillCredited(BOT, shooter, "SahurPistol")
local keys = 0
for _ in pairs(sp.mastery) do
	keys += 1
end
expect("companions, barrels, mines, unknown ids and bot killers earn nothing", keys == 1 and sp.mastery.SahurPistol == 13)
sp.mastery.SahurPistol = 74
ProgressionService.OnKillCredited(shooter, BOT, "SahurPistol")
expect("Gold counts toward the mastered title", sData.Lifetime.mastered == 1 and sData.Achievements.mastered1 == true)
sp.mastery.SahurPistol = 599
ProgressionService.OnKillCredited(shooter, BOT, "SahurPistol")
expect("Rotmaster counts toward its title", sData.Lifetime.rotmasters == 1 and sData.Achievements.rotmaster1 == true)

--------------------------------------------------------------------------------
-- Rot Index
--------------------------------------------------------------------------------

local RewardService = require(modules:WaitForChild("RewardService"))
local collector = fakePlayer("ProbeCollector")
local kData = PlayerData.Load(collector)
ProgressionService.OnProfileLoaded(collector)
local kp = kData.Progression
RewardService.GiveBrainrot(collector, "Trippi Troppi")
expect("RecordIndex finds a new brainrot", ProgressionService.RecordIndex(collector) == 1 and kp.index["Trippi Troppi"] == 1)
table.remove(kData.Brainrots, table.find(kData.Brainrots, "Trippi Troppi"))
expect("the entry outlives the copy", kp.index["Trippi Troppi"] == 1)
ok, message = ProgressionService.ClaimIndex(collector, "Trippi Troppi")
expect("claim one pays its rarity's Cells", ok and kp.index["Trippi Troppi"] == 2 and kp.cells == ProgressionData.DiscoverCells.Common, message)
ok, message = ProgressionService.ClaimIndex(collector, "Trippi Troppi")
expect("claiming twice is refused", not ok and kp.cells == ProgressionData.DiscoverCells.Common, message)
ok, message = ProgressionService.ClaimIndex(collector, "Pizzarino Blobbo")
expect("claiming an undiscovered brainrot is refused", not ok, message)
ok, message = ProgressionService.ClaimIndex(collector, string.rep("x", 200))
expect("claiming a long bogus name is refused", not ok, message)

local secretCells = 0
for _, def in ipairs(BrainrotData.OfRarity("Secret")) do
	RewardService.GiveBrainrot(collector, def.name)
	secretCells += ProgressionData.DiscoverCells.Secret
end
local cellsBeforeAll = kp.cells
ok, message = ProgressionService.ClaimIndex(collector, nil)
expect("CLAIM ALL claims the whole Secret page and pays its bonus", ok and kp.pages.Secret == true
	and kp.cells - cellsBeforeAll == secretCells + ProgressionData.PageBonus.Secret, message)
ok, message = ProgressionService.ClaimIndex(collector, nil)
expect("CLAIM ALL with nothing new is refused", not ok, message)

-- Robux never turns into Brain Cells: a brainrot bought with Robux is Purchased, pays nothing and
-- completes no page, until the same brainrot turns up in play.
local mythics = BrainrotData.OfRarity("Mythic")
local bought = mythics[#mythics].name
for index = 1, #mythics - 1 do
	RewardService.GiveBrainrot(collector, mythics[index].name)
end
ProgressionService.RecordIndex(collector, true)
RewardService.GiveBrainrot(collector, bought)
expect("RecordPurchased logs a new brainrot as Purchased", ProgressionService.RecordPurchased(collector, bought) and kp.index[bought] == ProgressionData.Purchased)
expect("a scan leaves a Purchased entry alone", ProgressionService.RecordIndex(collector, true) == 0 and kp.index[bought] == ProgressionData.Purchased)
expect("RecordPurchased doesn't downgrade something found in play", not ProgressionService.RecordPurchased(collector, mythics[1].name)
	and kp.index[mythics[1].name] == ProgressionData.Recorded)
ok, message = ProgressionService.ClaimIndex(collector, bought)
expect("claiming a Purchased entry is refused", not ok and kp.index[bought] == ProgressionData.Purchased, message)
cellsBeforeAll = kp.cells
ok, message = ProgressionService.ClaimIndex(collector, nil)
expect("CLAIM ALL pays the found Mythics but not the bought one, and no page bonus", ok and kp.pages.Mythic == nil
	and kp.cells - cellsBeforeAll == (#mythics - 1) * ProgressionData.DiscoverCells.Mythic and kp.index[bought] == ProgressionData.Purchased, message)
local counts = ProgressionData.IndexCounts(kp.index)
expect("a Purchased entry counts as found but not claimed", counts.Mythic.found == #mythics and counts.Mythic.claimed == #mythics - 1)
expect("the snapshot shows it as Purchased", ProgressionData.Snapshot(kData, os.time()).index[bought] == ProgressionData.Purchased)
ProgressionService.RecordIndex(collector, true, bought)
expect("pulling it in play makes it claimable", kp.index[bought] == ProgressionData.Recorded)
cellsBeforeAll = kp.cells
ok, message = ProgressionService.ClaimIndex(collector, bought)
expect("then it pays, and completes the Mythic page", ok and kp.pages.Mythic == true
	and kp.cells - cellsBeforeAll == ProgressionData.DiscoverCells.Mythic + ProgressionData.PageBonus.Mythic, message)
-- Beginner's Luck storage (the granting rule lives elsewhere; this module only stores and clamps).
do
	local CrateData = require(Shared:WaitForChild("CrateData"))
	local fresh = ProgressionData.Reconcile(nil)
	expect("a profile with no beginnerLuck reads as no charges, not granted",
		fresh.beginnerLuck.left == 0 and fresh.beginnerLuck.granted == false)
	local over = ProgressionData.Reconcile({ beginnerLuck = { left = 999, granted = "yes" } })
	expect("charges clamp to CrateData.BeginnerCrates and granted must be a real boolean",
		over.beginnerLuck.left == CrateData.BeginnerCrates and over.beginnerLuck.granted == false,
		over.beginnerLuck.left .. " / " .. tostring(over.beginnerLuck.granted))
	local spent = ProgressionData.Reconcile({ beginnerLuck = { left = 0, granted = true } })
	expect("a profile that has spent its charges stays spent", spent.beginnerLuck.left == 0 and spent.beginnerLuck.granted == true)
	local partial = ProgressionData.Reconcile({ beginnerLuck = { left = 2, granted = true } })
	expect("part-spent charges survive a load", partial.beginnerLuck.left == 2 and partial.beginnerLuck.granted == true)
	local negative = ProgressionData.Reconcile({ beginnerLuck = { left = -5, granted = true } })
	expect("a negative charge count can't come back", negative.beginnerLuck.left == 0)
end

expect("Reconcile keeps Purchased entries", ProgressionData.Reconcile({ index = { [bought] = 3, Other = 4 } }).index[bought] == 3
	and ProgressionData.Reconcile({ index = { Other = 4 } }).index.Other == nil)

-- Audit P3: a Robux receipt processed before the join hook, on a profile from before progression. The
-- backfill would record the new copy as found in play; RecordPurchased must still end up Purchased.
local lateBuyer = fakePlayer("ProbeLateReceipt")
local lData = PlayerData.Load(lateBuyer)
lData.Pass.xp = 20000
lData.Brainrots = { "Trippi Troppi", "Mudlo Splosh" }
expect("a receipt before migration: the bought copy ends up Purchased, older finds stay Recorded",
	ProgressionService.RecordPurchased(lateBuyer, "Mudlo Splosh") and lData.Progression.v == 1
	and lData.Progression.index["Mudlo Splosh"] == ProgressionData.Purchased and lData.Progression.index["Trippi Troppi"] == ProgressionData.Recorded)
local lateBuyer2 = fakePlayer("ProbeLateReceiptOwned")
local lData2 = PlayerData.Load(lateBuyer2)
lData2.Brainrots = { "Mudlo Splosh", "Mudlo Splosh" }
expect("…but a species the player already had an older copy of stays found in play",
	not ProgressionService.RecordPurchased(lateBuyer2, "Mudlo Splosh") and lData2.Progression.index["Mudlo Splosh"] == ProgressionData.Recorded)

--------------------------------------------------------------------------------
-- Cell Shop
--------------------------------------------------------------------------------

local shopper = fakePlayer("ProbeShopper")
local pData = PlayerData.Load(shopper)
ProgressionService.OnProfileLoaded(shopper)
local pp = pData.Progression
local offers = ProgressionData.ShopOffers(today)
local rare = ProgressionData.FindOffer(today, "rare")
ok, message = ProgressionService.BuyOffer(shopper, "rare", today)
expect("buying without enough Cells is refused and changes nothing", not ok and #pData.Brainrots == 0 and pp.cells == 0, message)
pp.cells = 5000
ok, message = ProgressionService.BuyOffer(shopper, "rare", today - 1)
expect("a stale shop day is refused", not ok and #pData.Brainrots == 0 and pp.cells == 5000, message)
ok, message = ProgressionService.BuyOffer(shopper, "legendary", today)
expect("an offer that isn't in the rotation is refused", not ok and pp.cells == 5000, message)
ok, message = ProgressionService.BuyOffer(shopper, "rare", today)
expect("a rare offer buys that exact brainrot", ok and pData.Brainrots[1] == rare.brainrot and pp.cells == 5000 - rare.price
	and pp.shop.day == today and pp.shop.bought.rare == 1 and pp.index[rare.brainrot] == 1, message)
ok, message = ProgressionService.BuyOffer(shopper, "rare", today)
expect("the daily limit holds", not ok and pp.cells == 5000 - rare.price, message)

ok, message = ProgressionService.BuyOffer(shopper, "snack", today)
expect("a snack with no companion is refused", not ok, message)
ok, message = ProgressionService.BuyOffer(shopper, "snack", today, "Il Buco Nero Bello")
expect("a snack for a brainrot you don't own is refused", not ok, message)
pData.Companion = rare.brainrot
local cellsBeforeSnack = pp.cells
local fed
ok, message, fed = ProgressionService.BuyOffer(shopper, "snack", today)
expect("a snack feeds the equipped companion", ok and fed == true and pData.CompanionXp[rare.brainrot] == 400
	and pp.cells == cellsBeforeSnack - offers[5].price, message)
pData.CompanionXp[rare.brainrot] = (BrainrotData.MaxLevel - 1) * BrainrotData.XpPerLevel
ok, message = ProgressionService.BuyOffer(shopper, "snack", today)
expect("a max-level companion can't be fed", not ok and pp.shop.bought.snack == 1, message)
pData.CompanionXp[rare.brainrot] = 0
ProgressionService.BuyOffer(shopper, "snack", today)
ok, message = ProgressionService.BuyOffer(shopper, "snack", today)
expect("two snacks a day", not ok and pp.shop.bought.snack == 2, message)

-- Snapshot and size.
local state = StateSync.Build(shopper)
local snap = state and state.progression
expect("StateSync carries the progression snapshot", snap ~= nil and snap.cells == pp.cells and snap.shop.day == today
	and snap.shop.bought.rare == 1 and snap.rank == 1)
pData.Brainrots = { "Mudlo Splosh" }
snap = ProgressionData.Snapshot(pData, os.time())
expect("owned-but-unrecorded brainrots show as found", snap.index["Mudlo Splosh"] == 1)

local full = ProgressionData.Default()
full.v, full.xp, full.total, full.prestige, full.cells, full.cellsEarned = 1, 222089, 1e9, 10, 123456789, 987654321
for _, id in ipairs(ProgressionData.MasteryWeapons()) do
	full.mastery[id] = 999999
end
for _, def in ipairs(BrainrotData.Types) do
	full.index[def.name] = 2
end
for _, rarity in ipairs(Rarity.Order) do
	full.pages[rarity] = true
end
for _, offer in ipairs(offers) do
	full.shop.bought[offer.id] = offer.limit
end
local bytes = #HttpService:JSONEncode(full)
print(string.format("[PROBE] a completely full Progression is %d bytes of JSON (%d guns, %d brainrots)", bytes, #ProgressionData.MasteryWeapons(), #BrainrotData.Types))
expect("a completely full Progression stays under 10 KB", bytes < 10000, bytes)

-- Rank-reward cosmetics.
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local leaked, listed, rankOnlyCount = {}, 0, 0
for _, item in pairs(CosmeticData.Items) do
	if item.rankOnly then
		rankOnlyCount += 1
	end
end
for _, kind in ipairs({ "GunSkin", "Aura", "Accessory", "Parachute" }) do
	for _, withCrate in ipairs({ false, true }) do
		for _, id in ipairs(CosmeticData.OfKind(kind, withCrate)) do
			listed += 1
			if CosmeticData.Get(id).rankOnly then
				table.insert(leaked, id)
			end
		end
	end
end
expect("OfKind never lists a rankOnly cosmetic (crates, shop, bots, Daily Spin)", #leaked == 0 and listed > 50 and rankOnlyCount == #ProgressionData.RankCosmetics,
	#leaked > 0 and table.concat(leaked, ", ") or string.format("%d listed, %d rankOnly", listed, rankOnlyCount))
for _, entry in ipairs(ProgressionData.RankCosmetics) do
	local item = CosmeticData.Get(entry.id)
	if not (item and item.rankOnly and not item.price) then
		expect("rank cosmetic " .. entry.id .. " is a priceless rankOnly item", false)
	end
end
expect("prestige 1 handed over the Bronze Rot skin", cData.Cosmetics.owned.PrestigeBronzeSkin == true)
expect("mastery to Rotmaster handed over Diamond Cut and Rotmaster skins", sData.Cosmetics.owned.MasteryDiamondCutSkin == true
	and sData.Cosmetics.owned.MasteryRotmasterSkin == true and not sData.Cosmetics.owned.MasteryMastercraftSkin)
-- Sahur Pistol is already at Rotmaster (Gold or better), so three more at Gold and a fourth crossing
-- makes five.
local ids = {}
for _, id in ipairs(ProgressionData.MasteryWeapons()) do
	if id ~= "SahurPistol" and #ids < 4 then
		table.insert(ids, id)
	end
end
for index = 1, 3 do
	sp.mastery[ids[index]] = 75
end
sp.mastery[ids[4]] = 74
ProgressionService.OnKillCredited(shooter, BOT, ids[4])
expect("Gold on a fifth gun hands over Mastercraft", sData.Cosmetics.owned.MasteryMastercraftSkin == true,
	string.format("%d guns at Gold", (ProgressionData.MasterySummary(sp.mastery))))

local returning = fakePlayer("ProbeReturning")
local rData = PlayerData.Load(returning)
rData.Progression = ProgressionData.Reconcile({ v = 1, prestige = 3, xp = 100, total = 700000 })
ProgressionService.OnProfileLoaded(returning)
expect("joining at prestige 3 catches up the first three prestige cosmetics", rData.Cosmetics.owned.PrestigeBronzeSkin
	and rData.Cosmetics.owned.PrestigeSilverAura and rData.Cosmetics.owned.PrestigeGoldenSkin and not rData.Cosmetics.owned.PrestigeJadeAura)

local listing = ProgressionData.FindCosmeticOffer("brainAura")
rData.Progression.cells = listing.cells - 1
ok, message = ProgressionService.BuyOffer(returning, "brainAura", today)
expect("a Cell Shop cosmetic needs its full price", not ok and not rData.Cosmetics.owned[listing.id], message)
rData.Progression.cells = listing.cells + 5
ok, message = ProgressionService.BuyOffer(returning, "brainAura", 0)
expect("buying it works (no shop day needed) and costs its price", ok and rData.Cosmetics.owned[listing.id] == true and rData.Progression.cells == 5, message)
rData.Progression.cells = listing.cells
ok, message = ProgressionService.BuyOffer(returning, "brainAura", today)
expect("it can't be bought twice", not ok and rData.Progression.cells == listing.cells, message)

-- Match summary for the results card.
local matcher = fakePlayer("ProbeMatcher")
local mData = PlayerData.Load(matcher)
ProgressionService.OnProfileLoaded(matcher)
local mp = mData.Progression
mp.xp = ProgressionData.RankStart(5) - 100
mp.mastery.RotSMG = 9
ProgressionService.BeginMatch({ matcher })
ProgressionService.OnKillCredited(matcher, BOT, "RotSMG")
ProgressionService.AddXp(matcher, 500)
local summary = ProgressionService.MatchSummary(matcher)
expect("match summary: rank from/to, XP (mastery bonus included), Cells, tier-ups", summary ~= nil and summary.rankFrom == 4
	and summary.rank == ProgressionData.RankForXp(mp.xp) and summary.xp == 500 + ProgressionData.MasteryTiers[1].xp
	and summary.cells > 0 and #summary.tiers == 1 and summary.tiers[1].tier == "Bronze",
	summary and HttpService:JSONEncode(summary))
expect("no summary for someone who wasn't there at the start", ProgressionService.MatchSummary(fakePlayer("ProbeLate")) == nil)

-- Rate limiting.
local limited = fakePlayer("ProbeLimiter")
expect("first call passes the rate limit", not ProgressionService.RateLimited(limited, "ClaimIndex"))
expect("an immediate second call is limited", ProgressionService.RateLimited(limited, "ClaimIndex"))
expect("a different remote isn't", not ProgressionService.RateLimited(limited, "BuyCellOffer"))

--------------------------------------------------------------------------------
-- Edge cases
--------------------------------------------------------------------------------

-- A Progression saved before a later field existed (here: only rank XP) loads with every missing field
-- at its default, and nothing it had is lost.
local partial = ProgressionData.Reconcile({ v = 1, xp = 500, total = 500 })
expect("a Progression from before Cells/mastery/Index/shop existed fills the rest with defaults", partial.xp == 500 and partial.cells == 0
	and next(partial.mastery) == nil and next(partial.index) == nil and partial.shop.day == 0 and next(partial.shop.bought) == nil)

-- Prestige exactly at the threshold, and one XP short of it.
local edge = fakePlayer("ProbeEdge")
local edgeData = PlayerData.Load(edge)
ProgressionService.OnProfileLoaded(edge)
edgeData.Progression.xp = ProgressionData.PrestigeXp - 1
ok, message = ProgressionService.Prestige(edge, 0)
expect("one XP short of rank 100: rank 99, no prestige", not ok and ProgressionData.RankForXp(edgeData.Progression.xp) == 99
	and not ProgressionData.Snapshot(edgeData, os.time()).canPrestige, message)
ProgressionService.AddXp(edge, 1)
expect("exactly PrestigeXp: rank 100 and canPrestige", ProgressionData.RankForXp(edgeData.Progression.xp) == 100
	and ProgressionData.Snapshot(edgeData, os.time()).canPrestige and edgeData.Progression.over == 0)
ok, message = ProgressionService.Prestige(edge, 0)
expect("prestiging at exactly the threshold works", ok and edgeData.Progression.prestige == 1, message)

-- A big XP jump pays every rank it passes, crates included.
local jumper = fakePlayer("ProbeJumper")
local jData = PlayerData.Load(jumper)
ProgressionService.OnProfileLoaded(jumper)
local rareCrates = jData.Crates.Rare or 0
local expectedCells = 0
local target = ProgressionData.RankStart(45)
for rank = 2, 45 do
	expectedCells += ProgressionData.RankReward(rank, 0).cells
end
ProgressionService.AddXp(jumper, target)
expect("one jump from rank 1 to 45 pays all 44 ranks and both Rare Crates (20, 40)", ProgressionData.RankForXp(jData.Progression.xp) == 45
	and jData.Progression.cells == expectedCells and (jData.Crates.Rare or 0) == rareCrates + 2, jData.Progression.cells .. " vs " .. expectedCells)

-- Max prestige keeps paying overflow, at the full prestige bonus.
jData.Progression.prestige, jData.Progression.xp, jData.Progression.over = ProgressionData.MaxPrestige, ProgressionData.PrestigeXp, 0
local cellsAtMax = jData.Progression.cells
ProgressionService.AddXp(jumper, ProgressionData.OverflowXp * 2 + 7)
expect("at Prestige 10, every 25,000 XP still pays (twice here)", jData.Progression.cells - cellsAtMax == 2 * ProgressionData.OverflowReward(ProgressionData.MaxPrestige)
	and jData.Progression.over == 7 and ProgressionData.OverflowReward(ProgressionData.MaxPrestige) == 1000)

-- Mastery points stop at the cap.
jData.Progression.mastery.RotSMG = ProgressionData.MasteryPointCap - 1
ProgressionService.OnKillCredited(jumper, fakePlayer("ProbeVictim2"), "RotSMG")
expect("mastery points never pass the cap", jData.Progression.mastery.RotSMG == ProgressionData.MasteryPointCap)

-- A trade reaching a profile that hasn't been migrated yet: the Purchased mark survives the backfill,
-- and species found in play are backfilled as found.
local fresh = fakePlayer("ProbeUnmigrated")
local fData = PlayerData.Load(fresh)
fData.Pass.xp = 3000
local seller = fakePlayer("ProbeSeller")
local sellerData = PlayerData.Load(seller)
ProgressionService.OnProfileLoaded(seller)
local boughtSecret = BrainrotData.OfRarity("Secret")[2].name
sellerData.Progression.index[boughtSecret] = ProgressionData.Purchased
sellerData.Progression.index["Pizzarino Blobbo"] = ProgressionData.Claimed
table.insert(fData.Brainrots, boughtSecret)
table.insert(fData.Brainrots, "Pizzarino Blobbo")
ProgressionService.OnTradeMoved(seller, fresh, { boughtSecret, "Pizzarino Blobbo" }, {})
expect("the trade marks the unmigrated receiver's bought species", fData.Progression.v == 0 and fData.Progression.index[boughtSecret] == ProgressionData.Purchased)
ProgressionService.OnProfileLoaded(fresh)
expect("migration afterwards keeps it Purchased and records the rest as found", fData.Progression.v == 1
	and fData.Progression.index[boughtSecret] == ProgressionData.Purchased and fData.Progression.index["Pizzarino Blobbo"] == ProgressionData.Recorded
	and ProgressionData.RankForXp(fData.Progression.xp) == ProgressionData.RankForXp(3000))

-- Yesterday's purchases don't count against today.
local shopperDay = fakePlayer("ProbeNewDay")
local sdData = PlayerData.Load(shopperDay)
ProgressionService.OnProfileLoaded(shopperDay)
sdData.Progression.cells = 5000
sdData.Progression.shop = { day = today - 1, bought = { rare = 1, snack = 2 } }
ok, message = ProgressionService.BuyOffer(shopperDay, "rare", today)
expect("a new day resets the shop limits", ok and sdData.Progression.shop.day == today and sdData.Progression.shop.bought.rare == 1
	and sdData.Progression.shop.bought.snack == nil, message)

-- A saved Index entry for a brainrot that no longer exists pays nothing and counts nowhere.
sdData.Progression.index["Brainrot That Was Renamed"] = ProgressionData.Recorded
local cellsBeforeGhost = sdData.Progression.cells
ok, message = ProgressionService.ClaimIndex(shopperDay, nil)
local ghostCounts, ghostTotal = ProgressionData.IndexCounts(sdData.Progression.index), 0
for _, count in pairs(ghostCounts) do
	ghostTotal += count.found
end
expect("an entry for a removed brainrot is never paid or counted", sdData.Progression.index["Brainrot That Was Renamed"] == ProgressionData.Recorded
	and ghostTotal == 1 and sdData.Progression.cells - cellsBeforeGhost == ProgressionData.DiscoverCells.Rare, message)
ok, message = ProgressionService.ClaimIndex(shopperDay, "Brainrot That Was Renamed")
expect("claiming it by name is refused", not ok, message)

-- Only Purchased entries left: CLAIM ALL has nothing to pay.
local onlyBought = fakePlayer("ProbeOnlyBought")
local obData = PlayerData.Load(onlyBought)
ProgressionService.OnProfileLoaded(onlyBought)
RewardService.GiveBrainrot(onlyBought, "Mudlo Splosh")
ProgressionService.RecordPurchased(onlyBought, "Mudlo Splosh")
ok, message = ProgressionService.ClaimIndex(onlyBought, nil)
expect("CLAIM ALL with only bought entries pays nothing", not ok and obData.Progression.cells == 0, message)

-- A profile without Progression (a save mid-load, or a hook missing) never breaks the snapshot.
local noProgression = { Brainrots = {}, CompanionXp = {} }
expect("Snapshot of a profile with no Progression is nil, not an error", ProgressionData.Snapshot(noProgression, os.time()) == nil)

-- A prestige during a match shows on the results line as a prestige.
ProgressionService.BeginMatch({ edge })
edgeData.Progression.xp = ProgressionData.PrestigeXp
ProgressionService.Prestige(edge, 1)
local prestigeSummary = ProgressionService.MatchSummary(edge)
expect("a mid-match prestige shows in the match summary", prestigeSummary and prestigeSummary.prestigeFrom == 1 and prestigeSummary.prestige == 2
	and prestigeSummary.rank == 1)

-- Review: a species the giver never had scanned (a Daily Spin prize from the menu) is written into their
-- Index when they trade it away, since no later scan could see it.
local spinner = fakePlayer("ProbeSpinner")
local spData = PlayerData.Load(spinner)
ProgressionService.OnProfileLoaded(spinner)
local spinPrize = BrainrotData.OfRarity("Epic")[1].name
table.insert(spData.Brainrots, spinPrize) -- as applySpinPrize does, with no RecordIndex after it
local spinReceiver = fakePlayer("ProbeSpinReceiver")
local srData = PlayerData.Load(spinReceiver)
ProgressionService.OnProfileLoaded(spinReceiver)
table.remove(spData.Brainrots, table.find(spData.Brainrots, spinPrize))
table.insert(srData.Brainrots, spinPrize)
ProgressionService.OnTradeMoved(spinner, spinReceiver, { spinPrize }, {})
expect("the giver keeps the discovery of a never-scanned brainrot they trade away", spData.Progression.index[spinPrize] == ProgressionData.Recorded
	and srData.Progression.index[spinPrize] == nil)

-- Review: a stale shop pushes the fresh one.
local pushedFor = nil
local realPush = StateSync.Push
StateSync.Push = function(player)
	pushedFor = player
end
ProgressionService.BuyOffer(spinner, "rare", today - 3)
StateSync.Push = realPush
expect("buying from a stale shop day sends the current shop", pushedFor == spinner)

-- Review: joining catches the mastery title counters up from the mastery map, and grants quietly.
local veteranGunner = fakePlayer("ProbeVeteranGunner")
local vgData = PlayerData.Load(veteranGunner)
vgData.Progression = ProgressionData.Reconcile({ v = 1, mastery = { SahurPistol = 700, RotSMG = 80, BubbleBlaster = 75 } })
local toastsBefore = #toasts
ProgressionService.OnProfileLoaded(veteranGunner)
expect("join tops up mastered and rotmasters from the mastery map", vgData.Lifetime.mastered == 3 and vgData.Lifetime.rotmasters == 1,
	vgData.Lifetime.mastered .. " / " .. vgData.Lifetime.rotmasters)
local unlockToasts = 0
for index = toastsBefore + 1, #toasts do
	if string.find(toasts[index], "UNLOCKED", 1, true) then
		unlockToasts += 1
	end
end
expect("join grants earned mastery skins without an immediate toast", vgData.Cosmetics.owned.MasteryDiamondCutSkin and vgData.Cosmetics.owned.MasteryRotmasterSkin
	and unlockToasts == 0, unlockToasts .. " unlock toasts")

-- The client reads the snapshot and the results payload by field name, so a field renamed or dropped on
-- the server breaks the page in silence. These read the client sources and check every field they ask
-- for is actually sent. `companion` is allowed to be nil (nobody equipped), so it's matched by name.
do
	local panel = StarterPlayerScripts:WaitForChild("ProgressionPanel").Source
	local hud = StarterPlayerScripts:WaitForChild("HudClient").Source
	local sent = ProgressionData.Snapshot(pData, os.time())
	local sendable = {}
	for field in pairs(sent) do
		sendable[field] = true
	end
	sendable.companion = true
	local missing = {}
	for field in string.gmatch(panel, "progression%.([%a%d_]+)") do
		if not sendable[field] and not table.find(missing, field) then
			table.insert(missing, field)
		end
	end
	expect("every field the Pass tab reads is in the snapshot the server sends", #missing == 0, table.concat(missing, ", "))

	-- MatchSummary only answers for a player who was there when the match began.
	ProgressionService.BeginMatch({ shopper })
	ProgressionService.AddXp(shopper, 50)
	local summary = ProgressionService.MatchSummary(shopper)
	expect("the results payload exists for a player who was in the match", summary ~= nil)
	summary = summary or {}
	local inSummary = {}
	for field in pairs(summary) do
		inSummary[field] = true
	end
	local missingResult = {}
	for field in string.gmatch(hud, "progression%.([%a%d_]+)") do
		if not inSummary[field] and not table.find(missingResult, field) then
			table.insert(missingResult, field)
		end
	end
	expect("every field the results card reads is in the match summary", #missingResult == 0, table.concat(missingResult, ", "))
end

-- A toast that throws (the remote fires at a player who is already gone, say) must not cost the player
-- anything it was announcing. This is what the live-server probe caught: the toast used to go first.
do
	local mute = fakePlayer("ProbeMuted")
	local mData = PlayerData.Load(mute)
	ProgressionService.OnProfileLoaded(mute)
	local mp = mData.Progression
	local realNotify = StateSync.Notify
	StateSync.Notify = function()
		error("no client for this player", 0)
	end
	local cellsBefore = mp.cells
	local ok = pcall(ProgressionService.AddXp, mute, ProgressionData.RankStart(4))
	StateSync.Notify = realNotify
	expect("a throwing toast doesn't throw out of AddXp", ok)
	expect("the ranks it announced were still paid", mp.cells > cellsBefore and mp.paidRank == 4,
		string.format("%d cells, paidRank %d", mp.cells - cellsBefore, mp.paidRank))
	expect("the nameplate attribute was still set", mute.attributes.RotRank == 4, mute.attributes.RotRank)
	expect("the title counter was still topped up", mData.Lifetime.rankScore == 4, mData.Lifetime.rankScore)

	-- CONTROL: the old order announced first, so a throw skipped everything after it.
	local oldOrder = function(player, data, progression, amount)
		local before = ProgressionData.RankForXp(progression.xp)
		progression.xp += amount
		local after = ProgressionData.RankForXp(progression.xp)
		if after > before then
			StateSync.Notify(player, "ROT RANK " .. after)
			player:SetAttribute("RotRank", after)
			data.Lifetime.rankScore = after
		end
	end
	local control = fakePlayer("ProbeMutedControl")
	local cData = PlayerData.Load(control)
	ProgressionService.OnProfileLoaded(control)
	StateSync.Notify = function()
		error("no client for this player", 0)
	end
	local controlOk = pcall(oldOrder, control, cData, cData.Progression, ProgressionData.RankStart(4))
	StateSync.Notify = realNotify
	expect("CONTROL: announcing first threw and left the rank unset", not controlOk and control.attributes.RotRank == 1,
		string.format("%s, attribute %s", tostring(controlOk), tostring(control.attributes.RotRank)))
end

-- paidRank: rank rewards are paid per rank, once, whatever the curve does afterwards.
do
	local tuner = fakePlayer("ProbeRetuned")
	local tData = PlayerData.Load(tuner)
	ProgressionService.OnProfileLoaded(tuner)
	local tp = tData.Progression
	-- A profile from before the field, sitting at rank 30 after a curve change: nothing is owed for the
	-- ranks its stored XP now reaches.
	tp.xp = ProgressionData.RankStart(30)
	tp.paidRank = 0
	tp.cells, tp.cellsEarned = 0, 0
	local cratesBefore = HttpService:JSONEncode(tData.Crates)
	ProgressionService.AddXp(tuner, 1)
	expect("a cheaper curve pays nothing retroactively", tp.cells == 0 and HttpService:JSONEncode(tData.Crates) == cratesBefore
		and tp.paidRank == 30, string.format("%d cells, paidRank %d", tp.cells, tp.paidRank))
	expect("stored progress into the current rank is untouched", ProgressionData.RankForXp(tp.xp) == 30
		and select(2, ProgressionData.RankProgress(tp.xp)) == 1)

	-- Climbing on from there pays each new rank exactly once.
	local expected = ProgressionData.RankReward(31, 0).cells + ProgressionData.RankReward(32, 0).cells
	ProgressionService.AddXp(tuner, ProgressionData.RankStart(32) - tp.xp)
	expect("climbing past it pays each rank once", tp.cells == expected and tp.paidRank == 32,
		string.format("%d cells (want %d), paidRank %d", tp.cells, expected, tp.paidRank))
	ProgressionService.AddXp(tuner, 1)
	expect("no rank crossed, nothing paid", tp.cells == expected)

	-- A dearer curve would drop the rank the same XP reaches; climbing back must not pay again.
	tp.xp = ProgressionData.RankStart(31)
	ProgressionService.AddXp(tuner, ProgressionData.RankStart(32) - tp.xp)
	expect("a dearer curve can't re-pay ranks already paid", tp.cells == expected and tp.paidRank == 32, tp.cells)

	-- Prestige starts the ladder again, so its ranks pay again.
	tp.xp, tp.prestige = ProgressionData.PrestigeXp, 0
	tp.paidRank = ProgressionData.MaxRank
	ProgressionService.Prestige(tuner, 0)
	expect("prestige resets paidRank so the new climb pays", tp.paidRank == 1 and tp.prestige == 1, tp.paidRank)
	local afterPrestige = tp.cells
	ProgressionService.AddXp(tuner, ProgressionData.RankStart(3))
	expect("the first ranks of a new prestige pay again", tp.cells > afterPrestige and tp.paidRank == 3, tp.paidRank)
	expect("Reconcile keeps and clamps paidRank", ProgressionData.Reconcile({ paidRank = 47 }).paidRank == 47
		and ProgressionData.Reconcile({ paidRank = 9999 }).paidRank == ProgressionData.MaxRank
		and ProgressionData.Reconcile({}).paidRank == 0)
end

-- Audit P2: trades, through the real TradeService. Its remotes need real players, so the stand-ins
-- keep a Parent only while the invite and session are set up (those two calls are pcalled because
-- FireClient refuses a table), then lose it so every later push skips them. Saves are stubbed and
-- counted: a probe must never write a profile.
local TradeService = require(modules:WaitForChild("TradeService"))
local saves = 0
PlayerData.Save = function()
	saves += 1
	return true
end
local function trade(a, b, offerA, offerB)
	a.Parent, b.Parent = game, game
	pcall(TradeService.Request, a, b)
	pcall(TradeService.Respond, b, true)
	a.Parent, b.Parent = nil, nil
	for _, name in ipairs(offerA) do
		TradeService.Offer(a, name, true)
	end
	for _, name in ipairs(offerB) do
		TradeService.Offer(b, name, true)
	end
	TradeService.Confirm(a, true)
	return TradeService.Confirm(b, true)
end
local traderA, traderB = fakePlayer("ProbeTraderA"), fakePlayer("ProbeTraderB")
local tA, tB = PlayerData.Load(traderA), PlayerData.Load(traderB)
ProgressionService.OnProfileLoaded(traderA)
ProgressionService.OnProfileLoaded(traderB)
local secret, common, rareName = BrainrotData.OfRarity("Secret")[1].name, "Trippi Troppi", BrainrotData.OfRarity("Rare")[1].name
RewardService.GiveBrainrot(traderA, secret)
ProgressionService.RecordPurchased(traderA, secret)
RewardService.GiveBrainrot(traderA, common)
RewardService.GiveBrainrot(traderB, rareName)
ProgressionService.RecordIndex(traderA, true)
ProgressionService.RecordIndex(traderB, true)
TradeService.OnTradeMoved = ProgressionService.OnTradeMoved
trade(traderA, traderB, { secret, common }, { rareName })
expect("a normal trade moves both offers and saves both profiles", table.find(tB.Brainrots, secret) and table.find(tB.Brainrots, common)
	and table.find(tA.Brainrots, rareName) and not table.find(tA.Brainrots, secret) and saves == 2, "saves " .. saves)
expect("a species the giver only bought arrives as Purchased", tB.Progression.index[secret] == ProgressionData.Purchased)
ProgressionService.RecordIndex(traderB, true)
ProgressionService.RecordIndex(traderA, true)
expect("species found in play arrive as found in play", tB.Progression.index[common] == ProgressionData.Recorded
	and tA.Progression.index[rareName] == ProgressionData.Recorded)
local hookCalled = false
TradeService.OnTradeMoved = function()
	hookCalled = true
	error("probe: a broken hook")
end
saves = 0
trade(traderB, traderA, { common }, {})
expect("a throwing hook still completes and saves the trade", hookCalled and table.find(tA.Brainrots, common) ~= nil and not table.find(tB.Brainrots, common)
	and saves == 2, "saves " .. saves .. ", hook called " .. tostring(hookCalled))
TradeService.OnTradeMoved = nil

--------------------------------------------------------------------------------
-- PlayerData forward compatibility (H1)
--------------------------------------------------------------------------------

-- A field a future version adds must survive a load and save by THIS version, so a server on older
-- code during a rolling update can't delete it. The control is the same module with the carry-through
-- block cut out: that's how reconcile behaved before, and it must drop the field.
do
	local source = modules.PlayerData.Source
	-- Cutting the carry-through block out of the module's own source, to get the pre-H1 behaviour. No
	-- patterns and no assumption about indentation: earlier attempts used both and quietly cut nothing,
	-- leaving the "control" running the unmodified module — which is exactly what this check exists to
	-- catch, and did, twice. Anchors are the comment, the one assignment inside the loop, and the two
	-- `end`s that close the `if` and the `for`. What it produced is then checked, not assumed.
	-- Plain finds only, no patterns anywhere: two pattern attempts here quietly matched nothing, which
	-- left the "control" running the unmodified module — the exact kind of test that proves nothing. The
	-- cut runs from the comment to the second `end` after the loop's one assignment (closing the `if`,
	-- then the `for`). The leading tab of the comment line is left behind on purpose: stray whitespace
	-- is harmless, and not having to find the line start removes the last pattern.
	local marker = string.find(source, "-- Forward compatibility, added", 1, true)
	local assign = marker and string.find(source, "data[field] = value", marker, true)
	local firstEnd = assign and string.find(source, "end", assign, true)
	local secondEnd = firstEnd and string.find(source, "end", firstEnd + 3, true)
	local stripped = source
	if marker and secondEnd then
		stripped = string.sub(source, 1, marker - 1) .. string.sub(source, secondEnd + 3)
	end
	-- What came out is checked, never assumed: the comment and the loop must be gone and reconcile must
	-- still end properly.
	local cut = (string.find(stripped, "Forward compatibility", 1, true) == nil
		and string.find(stripped, "for field, value in pairs(saved) do", 1, true) == nil
		and string.find(stripped, "return data", 1, true) ~= nil) and 1 or 0
	expect("the forward-compat block could be cut for the control", cut == 1,
		string.format("marker %s, assign %s, ends %s/%s, source %d bytes, stripped %d",
			tostring(marker), tostring(assign), tostring(firstEnd), tostring(secondEnd), #source, #stripped))
	local oldOk, oldModule = pcall(function()
		return loadstring(stripped, "PlayerDataOld")()
	end)
	expect("the old reconcile loads for the control", oldOk and type(oldModule) == "table", oldOk and "" or tostring(oldModule))

	local future = {
		SahurCoins = 5,
		Title = "kill1",
		-- Whatever a later version might add: nested tables, arrays, mixed value types.
		FutureField = { nested = { a = 1, b = { "x", "y" }, flag = true }, n = 5 },
		AnotherFuture = "just a string",
	}
	local loaded = PlayerData.Reconcile(future)
	expect("an unknown top-level field survives reconcile whole",
		HttpService:JSONEncode(loaded.FutureField) == HttpService:JSONEncode(future.FutureField) and loaded.AnotherFuture == "just a string")
	expect("known fields are still cleaned, not carried", loaded.SahurCoins == 5 and loaded.Title == "kill1" and loaded.Progression.v == 0)
	local roundTripped = PlayerData.Reconcile(HttpService:JSONDecode(HttpService:JSONEncode(loaded)))
	expect("load -> save -> load leaves the unknown field byte-identical",
		HttpService:JSONEncode(roundTripped.FutureField) == HttpService:JSONEncode(future.FutureField))
	if oldOk and type(oldModule) == "table" then
		local old = oldModule.Reconcile(future)
		expect("CONTROL: the old reconcile drops it", old.FutureField == nil and old.AnotherFuture == nil and old.SahurCoins == 5)
	end
end

print(string.format("[PROBE] %d toasts; last: %s", #toasts, tostring(toasts[#toasts])))
print(string.format("[PROBE] progression: %d passed, %d failed", passes, failures))
