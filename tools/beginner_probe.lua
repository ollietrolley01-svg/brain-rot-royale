-- Beginner's Luck probe for tools/runtest.ps1 -Probe: the hidden boost on a new profile's first few
-- FREE brainrot crates, against the real CrateService, CrateData and StateSync with a stand-in player.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/beginner_probe.lua
--
-- What has to hold, and why each one matters:
--   * Only FREE crates are boosted. A crate bought with Robux or coins rolls the odds its card
--     shows, always: that's the rule for anything sold, and the reason this feature exists only on
--     crates the game hands out.
--   * The card and the roll agree. The menu draws a boosted card with rarity names and no
--     percentages (StateSync.crateBoosted says which), so no number on screen is ever a number the
--     roll didn't use. The shares measured here are checked against EffectiveOdds at the luck that
--     was actually rolled.
--   * Exactly one charge per boosted open, none on a refused open, none on an item crate, none on a
--     paid or coin crate, and nothing refills them.
--   * The pass composes: 4x alone, 8x with 2x Crate Luck, clamped at CrateData.MaxLuck.
--   * A profile with no charges behaves exactly as before the feature existed.
-- PlayerData.Save is stubbed: a stand-in profile must never reach a real DataStore.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local Monetization = require(modules:WaitForChild("Monetization"))
local CrateService = require(modules:WaitForChild("CrateService"))

StateSync.Push = function() end
StateSync.Notify = function() end
PlayerData.Save = function()
	return true
end
PlayerData.CanSave = function()
	return true
end

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[BeginnerProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

local player = { UserId = -424253, Name = "BeginnerProbe", DisplayName = "BeginnerProbe" }
local data = PlayerData.Load(player)
-- The profile fields this feature needs. PlayerData owns their defaults and reconcile (claude-a4);
-- the probe sets them directly so the rules here can be measured either way.
data.FreeCrates = data.FreeCrates or {}
data.Progression = data.Progression or {}

local function setCharges(n)
	data.Progression.beginnerLuck = { left = n, granted = true }
end
local function charges()
	return CrateData.BeginnerLeft(data.Progression)
end
local function setPass(on)
	data.TempPasses.CrateLuck = on and (os.time() + 3600) or nil
end
local function clearCrates()
	for tier in pairs(data.Crates) do
		data.Crates[tier] = 0
	end
	data.PaidCrates = {}
	data.FreeCrates = {}
end

-- One open, with the profile read back (Open ends by firing a remote at the player, which a stand-in
-- can't receive; everything before that has already changed the profile).
-- Returns the rarity of the brainrot that came out, or nil with `other` true when the open paid out
-- something else it's entitled to: a brainrot crate can hand over an ACCESSORY instead
-- (crate.accessoryChance), which is a real outcome and not a failed open.
local function openOnce(tier, shownLuck)
	local before = #data.Brainrots
	local ownedBefore = 0
	for _ in pairs(data.Cosmetics.owned) do
		ownedBefore += 1
	end
	local ok, message = pcall(CrateService.Open, player, tier, shownLuck)
	local got, other = nil, false
	if #data.Brainrots > before then
		local def = BrainrotData.Get(data.Brainrots[#data.Brainrots])
		got = def and def.rarity
	else
		local ownedAfter = 0
		for _ in pairs(data.Cosmetics.owned) do
			ownedAfter += 1
		end
		other = ownedAfter > ownedBefore
	end
	return got, ok, message, other
end

-- Free crates and paid crates are told apart by the service, not by the probe.
local function giveFree(tier, amount)
	CrateService.Give(player, tier, amount or 1)
end
local function givePaid(tier, amount)
	CrateService.GivePaid(player, tier, amount or 1)
end

-- Boost on and off ----------------------------------------------------------------------------------
clearCrates()
setCharges(4)
setPass(false)
giveFree("Rare", 1)
expect("a free brainrot crate with charges left is boosted", CrateService.BeginnerBoosted(data, "Rare") == true)
expect("the boost is 4x on its own", CrateData.LuckFor(CrateData.Get("Rare"), Monetization.CrateLuck(player), true) == 4)
setPass(true)
expect("with the 2x pass it composes to 8x", CrateData.LuckFor(CrateData.Get("Rare"), Monetization.CrateLuck(player), true) == 8,
	CrateData.LuckFor(CrateData.Get("Rare"), Monetization.CrateLuck(player), true))
expect("the composed luck never passes CrateData.MaxLuck", CrateData.LuckFor(CrateData.Get("Rare"), 4, true) <= CrateData.MaxLuck)
setPass(false)

clearCrates()
givePaid("Rare", 1)
giveFree("Rare", 1)
expect("a paid crate in the queue is NOT boosted (paid crates open first and always roll their shown odds)",
	CrateService.BeginnerBoosted(data, "Rare") == false)
openOnce("Rare")
expect("after the paid one is opened, the free one behind it is boosted", CrateService.BeginnerBoosted(data, "Rare") == true)
expect("opening the paid crate spent no charge", charges() == 4, charges())

clearCrates()
data.Crates.Rare = 1 -- a coin purchase: marked neither paid nor free
expect("a coin-bought crate is not boosted", CrateService.BeginnerBoosted(data, "Rare") == false)
openOnce("Rare")
expect("opening a coin-bought crate spent no charge", charges() == 4, charges())

-- A card with no percentages must never be a card you can buy a crate on, so holding ANY bought
-- crate of that tier (coins count: coins are bought with Robux) turns the boost off for it.
clearCrates()
giveFree("Rare", 1)
expect("a free crate alone is boosted", CrateService.BeginnerBoosted(data, "Rare") == true)
data.Crates.Rare += 1 -- they buy one with coins
expect("buying a coin crate of that tier puts the percentages back (no boost while one is held)",
	CrateService.BeginnerBoosted(data, "Rare") == false)
openOnce("Rare")
expect("the bought crate opens first, and spends no charge", charges() == 4 and (data.Crates.Rare or 0) == 1, charges())
expect("with the bought one gone, the free crate behind it is boosted again", CrateService.BeginnerBoosted(data, "Rare") == true)

clearCrates()
giveFree("Accessory", 1)
expect("an item crate is never boosted, even when free", CrateService.BeginnerBoosted(data, "Accessory") == false)
openOnce("Accessory")
expect("opening a free item crate spent no charge", charges() == 4, charges())

-- Charges are spent exactly once per boosted open ----------------------------------------------------
clearCrates()
setCharges(4)
giveFree("Common", 6)
local spent = {}
for index = 1, 6 do
	local boostedBefore = CrateService.BeginnerBoosted(data, "Common")
	local left = charges()
	openOnce("Common")
	table.insert(spent, string.format("%s:%d->%d", boostedBefore and "boost" or "plain", left, charges()))
end
expect("four free crates spend the four charges, one each, and the fifth and sixth are plain",
	charges() == 0 and table.concat(spent, " ") == "boost:4->3 boost:3->2 boost:2->1 boost:1->0 plain:0->0 plain:0->0",
	table.concat(spent, " "))

-- A refused open spends nothing.
clearCrates()
setCharges(2)
giveFree("Common", 1)
local _, ok, message = openOnce("Common", 1) -- the card claimed plain odds, the crate is boosted
expect("an open refused for a luck mismatch spends no crate and no charge",
	charges() == 2 and (data.Crates.Common or 0) == 1, string.format("charges %d, crates %d, %s", charges(), data.Crates.Common or 0, tostring(message)))
local before = data.Crates.Common
openOnce("Rare") -- none held
expect("an open with no crate held spends no charge", charges() == 2 and data.Crates.Common == before)

-- Shown odds are rolled odds --------------------------------------------------------------------------
local function distribution(tier, boosted, opens)
	clearCrates()
	setCharges(boosted and opens + 10 or 0)
	local crate = CrateData.Get(tier)
	local luck = CrateData.LuckFor(crate, Monetization.CrateLuck(player), boosted)
	local counts, n, accessories = {}, 0, 0
	for index = 1, opens do
		data.Pity[tier] = 0
		giveFree(tier, 1)
		local rarity, _ok, _message, other = openOnce(tier)
		if rarity then
			counts[rarity] = (counts[rarity] or 0) + 1
			n += 1
		elseif other then
			accessories += 1
		end
		if index % 250 == 0 then
			table.clear(data.Brainrots)
			task.wait()
		end
	end
	-- The worst deviation of this sample from a given odds table, in standard deviations.
	local function worstSd(odds)
		local worst, worstRarity = 0, nil
		for rarity, pct in pairs(odds) do
			local p = pct / 100
			local got = counts[rarity] or 0
			local sigma = math.sqrt(math.max(1e-9, n * p * (1 - p)))
			local z = math.abs(got - n * p) / sigma
			if z > worst then
				worst, worstRarity = z, rarity
			end
		end
		return worst, worstRarity
	end
	local worst, worstRarity = worstSd(CrateData.EffectiveOdds(crate, luck))
	-- Every open must have paid out SOMETHING (a brainrot or an accessory): an open that changed
	-- nothing would quietly shrink the sample and make the shares meaningless.
	expect(string.format("%s crate, %s: %d opens match EffectiveOdds at the luck actually rolled (x%d)",
		tier, boosted and "Beginner's Luck" or "plain", n, luck), n + accessories == opens and worst <= 4.5,
		string.format("worst %s at %.2f sd; %d accessories, %d opens that paid nothing", tostring(worstRarity), worst,
			accessories, opens - n - accessories))
	-- And the check must be able to FAIL: the same sample against the odds for one luck step away has
	-- to break the 4.5 sd tolerance. Without this, "matches the shown odds" could just mean the
	-- tolerance is wide enough to accept anything.
	local wrongLuck = math.min(CrateData.MaxLuck, luck + 1) == luck and luck - 1 or luck + 1
	local plantedWorst, plantedRarity = worstSd(CrateData.EffectiveOdds(crate, math.clamp(wrongLuck, 1, CrateData.MaxLuck)))
	expect(string.format("%s crate x%d: the odds check itself fails against the wrong luck (x%d)", tier, luck, wrongLuck),
		plantedWorst > 4.5, string.format("worst %s at %.2f sd against x%d", tostring(plantedRarity), plantedWorst, wrongLuck))
end

setPass(false)
distribution("Common", false, 4000)
distribution("Common", true, 4000)
distribution("Legendary", true, 4000)
setPass(true)
distribution("Legendary", true, 4000)
setPass(false)

-- What the menu is told -------------------------------------------------------------------------------
clearCrates()
setCharges(1)
giveFree("Rare", 1)
givePaid("Epic", 1)
local snapshot = StateSync.Build(player)
expect("the snapshot marks exactly the boosted tiers, so the card can be drawn without odds",
	snapshot.crateBoosted ~= nil and snapshot.crateBoosted.Rare == true and snapshot.crateBoosted.Epic == nil,
	snapshot.crateBoosted and ("Rare=" .. tostring(snapshot.crateBoosted.Rare) .. " Epic=" .. tostring(snapshot.crateBoosted.Epic)) or "nil")
expect("the snapshot's boosted flag agrees with what Open will do", snapshot.crateBoosted.Rare == CrateService.BeginnerBoosted(data, "Rare"))

setCharges(0)
snapshot = StateSync.Build(player)
expect("with no charges left the snapshot marks nothing, and the cards go back to showing percentages",
	snapshot.crateBoosted == nil, tostring(snapshot.crateBoosted))

-- A profile from before the feature -------------------------------------------------------------------
local old = PlayerData.Reconcile({ SahurCoins = 10, Crates = { Rare = 1 } })
expect("a save from before Beginner's Luck reads as no charges", CrateData.BeginnerLeft(old.Progression) == 0,
	CrateData.BeginnerLeft(old.Progression))
expect("a profile that has spent its charges stays spent", CrateData.BeginnerLeft({ beginnerLuck = { left = 0, granted = true } }) == 0)
expect("a junk charge count can't boost anything", CrateData.BeginnerLeft({ beginnerLuck = { left = 0 / 0 } }) == 0
	and CrateData.BeginnerLeft({ beginnerLuck = { left = -5 } }) == 0)

-- The one-off grant ------------------------------------------------------------------------------------
data.Progression.beginnerLuck = nil
local granted = CrateService.GrantBeginnerLuck(player)
expect("a profile that has never had Beginner's Luck gets its charges once, marked granted",
	granted == true and charges() == CrateData.BeginnerCrates and data.Progression.beginnerLuck.granted == true,
	string.format("granted %s, left %d", tostring(granted), charges()))

local again = CrateService.GrantBeginnerLuck(player)
expect("running the grant again changes nothing", again == false and charges() == CrateData.BeginnerCrates, charges())

-- Spend them, then reload the profile and try to grant again: the marker is what stops it, not the
-- charges being there, so a player who has used them up never gets more.
clearCrates()
giveFree("Common", CrateData.BeginnerCrates)
for _ = 1, CrateData.BeginnerCrates do
	openOnce("Common")
end
expect("the charges are spent", charges() == 0)
local reloaded = PlayerData.Reconcile({ Progression = { beginnerLuck = { left = 0, granted = true } } })
data.Progression = reloaded.Progression
expect("a spent profile reloaded gets no more charges",
	CrateService.GrantBeginnerLuck(player) == false and CrateData.BeginnerLeft(data.Progression) == 0,
	CrateData.BeginnerLeft(data.Progression))

-- An existing player from before the feature: no field at all, so they get the charges once.
local existing = PlayerData.Reconcile({ SahurCoins = 5000, Brainrots = { "Golden Sahur" } })
data.Progression = existing.Progression
expect("an existing player's profile gets the charges once", CrateService.GrantBeginnerLuck(player) == true
	and CrateData.BeginnerLeft(data.Progression) == CrateData.BeginnerCrates and CrateService.GrantBeginnerLuck(player) == false,
	CrateData.BeginnerLeft(data.Progression))

print(string.format("[BeginnerProbe] finished: %d passed, %d failed", passes, failures))
