-- Receipt and pass probe for tools/runtest.ps1 -Probe: every way a paid purchase used to be lost or
-- doubled, driven through the real Monetization.HandleReceipt, Monetization pass ownership,
-- BattlePassService.ClaimDaily and CrateService.Open with a stand-in player (edit mode).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/receipt_probe.lua
--
-- Nothing here touches Roblox's servers: PlayerData.Save / CanSave, the ownership check
-- (Monetization.OwnsPassAsync), StateSync's pushes and the Daily Spin's roll are stubbed, and the
-- products are stand-ins added to GamepassConfig for the run and removed after. "Saving" keeps a deep
-- copy of the profile, which is what a new session loads.
--
-- Written for the review of 2026-09-17 (claude-f5), and run first on the code from before the fixes,
-- where the cases marked [bug] must FAIL:
--   [bug] a save failure, then a retry in the same session, must not confirm
--         a save failure, then a retry in a new session, grants once and confirms
--         a confirmed-but-unacknowledged receipt retried in a new session doesn't grant again
--   [bug] ...even after many more purchases in between (the saved PurchaseId window)
--   [bug] a handler that changes the profile and then errors (a failing toast) doesn't grant twice
--         an announce that errors after the grant changes nothing
--         the same receipt twice grants once
--         a receipt for a player whose profile isn't loaded waits
--   [bug] a receipt for a profile that can't save grants nothing and waits
--   [bug] paid passes survive a Daily Spin TempPass win, and the TempPass expiring
--   [bug] a pass bought this session counts even while Roblox's ownership check still says no
--   [bug] a crate open is refused, spending nothing, when the luck shown isn't the player's luck
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local DailySpinData = require(Shared:WaitForChild("DailySpinData"))
local PlayerData = require(modules:WaitForChild("PlayerData"))
local StateSync = require(modules:WaitForChild("StateSync"))
local Monetization = require(modules:WaitForChild("Monetization"))
local CrateService = require(modules:WaitForChild("CrateService"))
local BattlePassService = require(modules:WaitForChild("BattlePassService"))

local GRANTED = Enum.ProductPurchaseDecision.PurchaseGranted
local NOT_YET = Enum.ProductPurchaseDecision.NotProcessedYet

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[ReceiptProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end
-- Runs one case; an error (old code missing a function, say) is a FAIL, not a crash of the whole run.
local function case(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		expect(label, false, "errored: " .. tostring(err))
	end
end

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

-- Stubs ------------------------------------------------------------------------------------------------
local real = {
	Save = PlayerData.Save, CanSave = PlayerData.CanSave, Get = PlayerData.Get, Push = StateSync.Push, Notify = StateSync.Notify,
	Roll = DailySpinData.Roll, OwnsPassAsync = Monetization.OwnsPassAsync, HasStore = PlayerData.HasStore,
}
StateSync.Push = function() end
StateSync.Notify = function() end

local player = { UserId = -424251, Name = "ReceiptProbe", DisplayName = "ReceiptProbe" }
local data = PlayerData.Load(player)
local saveWorks, canSave, stored, saveCalls = true, true, nil, 0
PlayerData.Save = function(who)
	saveCalls += 1
	if who ~= player or not saveWorks then
		return false
	end
	stored = deepCopy(data)
	return true
end
-- Receipts save through SaveAndWait (it waits out an in-flight save); same stub.
PlayerData.SaveAndWait = function(...)
	return PlayerData.Save(...)
end
PlayerData.CanSave = function(who)
	return who == player and canSave
end
-- This probe runs in Studio, where there is no DataStore, and HandleReceipt has a Studio-only
-- exception for that. Unless a case says otherwise it pretends a live server (a store exists), so
-- every other case tests the live path.
local hasStore = true
PlayerData.HasStore = function()
	return hasStore
end
-- A new session: the profile as last saved, through the real reconcile.
local function newSession()
	local loaded = PlayerData.Reconcile(deepCopy(stored or {}))
	for key in pairs(data) do
		data[key] = nil
	end
	for key, value in pairs(loaded) do
		data[key] = value
	end
end

-- Stand-in products and handlers.
local handlerMode = "clean"
local announceCalls = 0
Monetization.RegisterGrantHandler("ProbeCoins", function(_who, profile, grant)
	profile.SahurCoins += grant.amount
	if handlerMode == "failAfterChange" then
		error("a toast failed after the coins went in")
	elseif handlerMode == "failBeforeChange" then
		profile.SahurCoins -= grant.amount
		error("bad product, nothing granted")
	end
	return function()
		announceCalls += 1
		if handlerMode == "announceThrows" then
			error("announce blew up")
		end
	end
end)
local PRODUCT_ID = 99942001
GamepassConfig.Products.ProbeCoinPack = { id = PRODUCT_ID, name = "Probe coins", suggestedPrice = 1, grant = { kind = "ProbeCoins", amount = 1000 } }

local purchaseCounter = 0
local function receipt(purchaseId)
	purchaseCounter += 1
	return { PlayerId = player.UserId, ProductId = PRODUCT_ID, PurchaseId = purchaseId or ("probe-receipt-" .. purchaseCounter), CurrencySpent = 1 }
end
local function coins()
	return data.SahurCoins
end
local function reset()
	saveWorks, canSave, handlerMode, hasStore = true, true, "clean", true
	data.SahurCoins = 0
end

-- Receipts -------------------------------------------------------------------------------------------
case("[bug] a save failure then a retry in the SAME session is not confirmed until a save succeeds", function()
	reset()
	stored = deepCopy(data)
	local r = receipt()
	saveWorks = false
	local first = Monetization.HandleReceipt(player, r)
	local retry = Monetization.HandleReceipt(player, r)
	saveWorks = true
	local later = Monetization.HandleReceipt(player, r)
	expect("[bug] save fails: first NotProcessedYet, same-session retry still NotProcessedYet, then confirmed once saved; granted once",
		first == NOT_YET and retry == NOT_YET and later == GRANTED and coins() == 1000,
		string.format("first %s, retry %s, after save %s, coins %d", first.Name, retry.Name, later.Name, coins()))
end)

case("a save failure then a retry in a NEW session grants once and confirms", function()
	reset()
	stored = deepCopy(data)
	local r = receipt()
	saveWorks = false
	local first = Monetization.HandleReceipt(player, r)
	saveWorks = true
	newSession()
	local retry = Monetization.HandleReceipt(player, r)
	local again = Monetization.HandleReceipt(player, r)
	expect("save failed, rejoined: the retry grants and confirms, a further retry grants nothing",
		first == NOT_YET and retry == GRANTED and again == GRANTED and coins() == 1000 and stored.SahurCoins == 1000,
		string.format("first %s, retry %s, again %s, coins %d, saved coins %s", first.Name, retry.Name, again.Name, coins(), tostring(stored and stored.SahurCoins)))
end)

case("a saved but unacknowledged receipt retried in a new session doesn't grant again", function()
	reset()
	local r = receipt()
	local first = Monetization.HandleReceipt(player, r) -- saved; pretend Roblox never got the answer
	newSession()
	local retry = Monetization.HandleReceipt(player, r)
	expect("granted and saved, then retried after a rejoin: confirmed without a second grant", first == GRANTED and retry == GRANTED and coins() == 1000,
		string.format("coins %d", coins()))
end)

case("[bug] the saved PurchaseId window survives many purchases in between", function()
	reset()
	local r = receipt("probe-window-first")
	Monetization.HandleReceipt(player, r)
	for _ = 1, 100 do
		Monetization.HandleReceipt(player, receipt())
	end
	newSession()
	local before = coins()
	local retry = Monetization.HandleReceipt(player, r)
	expect("[bug] a receipt 100 purchases back, retried after a rejoin, grants nothing", retry == GRANTED and coins() == before,
		string.format("coins %d -> %d, %d ids kept", before, coins(), #data.PurchaseIds))
end)

case("[bug] a handler that errors after changing the profile doesn't grant twice", function()
	reset()
	local r = receipt()
	handlerMode = "failAfterChange"
	local first = Monetization.HandleReceipt(player, r)
	handlerMode = "clean"
	local retry = Monetization.HandleReceipt(player, r)
	expect("[bug] grant went in, then the handler threw: the retry must not grant again", coins() == 1000,
		string.format("first %s, retry %s, coins %d", first.Name, retry.Name, coins()))
end)

case("a handler that errors before changing anything is left for a retry", function()
	reset()
	local r = receipt()
	handlerMode = "failBeforeChange"
	local first = Monetization.HandleReceipt(player, r)
	handlerMode = "clean"
	local retry = Monetization.HandleReceipt(player, r)
	expect("nothing granted and NotProcessedYet, then the retry grants once", first == NOT_YET and retry == GRANTED and coins() == 1000,
		string.format("first %s, retry %s, coins %d", first.Name, retry.Name, coins()))
end)

case("an announce that errors after the grant changes nothing", function()
	reset()
	local r = receipt()
	handlerMode = "announceThrows"
	announceCalls = 0
	local first = Monetization.HandleReceipt(player, r)
	task.wait()
	handlerMode = "clean"
	local retry = Monetization.HandleReceipt(player, r)
	expect("confirmed, granted once, retry grants nothing", first == GRANTED and retry == GRANTED and coins() == 1000,
		string.format("first %s, retry %s, coins %d, announce ran %d", first.Name, retry.Name, coins(), announceCalls))
end)

case("the same receipt twice grants once", function()
	reset()
	local r = receipt()
	local a, b = Monetization.HandleReceipt(player, r), Monetization.HandleReceipt(player, r)
	expect("duplicate receipt: both confirmed, one grant", a == GRANTED and b == GRANTED and coins() == 1000, string.format("coins %d", coins()))
end)

case("a player whose profile isn't loaded", function()
	reset()
	local stranger = { UserId = -424299, Name = "NotLoaded" }
	local decision = Monetization.HandleReceipt(stranger, { PlayerId = stranger.UserId, ProductId = PRODUCT_ID, PurchaseId = "probe-stranger" })
	expect("no profile: NotProcessedYet", decision == NOT_YET, decision.Name)
	expect("player not in the server: NotProcessedYet", Monetization.HandleReceipt(nil, receipt()) == NOT_YET)
end)

case("[bug] a profile that can't save", function()
	reset()
	canSave = false
	saveWorks = false
	local r = receipt()
	local first = Monetization.HandleReceipt(player, r)
	local retry = Monetization.HandleReceipt(player, r)
	expect("[bug] can't save (failed load): nothing granted into the throwaway profile, and never confirmed",
		first == NOT_YET and retry == NOT_YET and coins() == 0, string.format("first %s, retry %s, coins %d", first.Name, retry.Name, coins()))
end)

case("a Studio test purchase grants even though nothing can be saved", function()
	reset()
	hasStore = false -- Studio: no DataStore at all
	canSave, saveWorks = false, false
	local decision = Monetization.HandleReceipt(player, receipt())
	expect("Studio (no DataStore): the test purchase is granted so the shop can be tried out",
		decision == GRANTED and coins() == 1000, string.format("%s, coins %d", decision.Name, coins()))
	-- And the same situation on a live server (a store exists, this profile just can't save) must not.
	reset()
	canSave, saveWorks = false, false
	local live = Monetization.HandleReceipt(player, receipt())
	expect("[bug] a live server with a store but an unsaveable profile still refuses and grants nothing",
		live == NOT_YET and coins() == 0, string.format("%s, coins %d", live.Name, coins()))
end)

-- Passes ---------------------------------------------------------------------------------------------
local coinPass = GamepassConfig.Passes.CoinBoost
local luckPass = GamepassConfig.Passes.CrateLuck
local savedPassIds = { coin = coinPass.id, luck = luckPass.id }
coinPass.id = 99942101
luckPass.id = 99942102
local ownsCalls, robloxSays = 0, {}
Monetization.OwnsPassAsync = function(_userId, passId)
	ownsCalls += 1
	return robloxSays[passId] == true
end

case("[bug] paid passes survive a Daily Spin TempPass win and its expiry", function()
	reset()
	robloxSays = { [coinPass.id] = true }
	data.TempPasses = {}
	Monetization.Refresh(player)
	local heldBefore = Monetization.Owns(player, "CoinBoost")
	local passIndex
	for index, segment in ipairs(DailySpinData.Segments) do
		if segment.kind == "TempPass" then
			passIndex = index
		end
	end
	DailySpinData.Roll = function()
		return passIndex
	end
	data.Daily.lastClaimDay = 0
	local ok, message = BattlePassService.ClaimDaily(player)
	DailySpinData.Roll = real.Roll
	local won
	for key, untilTime in pairs(data.TempPasses) do
		if untilTime > os.time() then
			won = key
		end
	end
	local heldAfterWin = Monetization.Owns(player, "CoinBoost") and Monetization.EarnCoins(player, 100) == 200
	if won then
		data.TempPasses[won] = os.time() - 1
	end
	local heldAfterExpiry = Monetization.Owns(player, "CoinBoost") and Monetization.EarnCoins(player, 100) == 200
	local tempGone = won == nil or not Monetization.Owns(player, won) or (won == "CoinBoost")
	expect("[bug] 2x SahurCoins (paid) still pays double after winning a TempPass, and after that TempPass runs out",
		heldBefore and ok and won ~= nil and heldAfterWin and heldAfterExpiry and tempGone,
		string.format("held before %s, spin %s (%s), won %s, after win %s, after expiry %s", tostring(heldBefore), tostring(ok), tostring(message),
			tostring(won), tostring(heldAfterWin), tostring(heldAfterExpiry)))
end)

case("[bug] a pass bought this session counts while Roblox's check still says no", function()
	reset()
	robloxSays = {}
	data.TempPasses = {}
	Monetization.Refresh(player)
	local before = Monetization.Owns(player, "CrateLuck")
	Monetization.OnPassPurchaseFinished(player, luckPass.id, true)
	local after = Monetization.Owns(player, "CrateLuck")
	Monetization.Refresh(player) -- a later refresh, still stale, must not take it away
	local afterRefresh = Monetization.Owns(player, "CrateLuck")
	Monetization.OnPassPurchaseFinished(player, coinPass.id, false)
	local notBought = Monetization.Owns(player, "CoinBoost")
	expect("[bug] bought 2x Crate Luck: owned at once and through a stale refresh; a cancelled prompt grants nothing",
		not before and after and afterRefresh and not notBought and Monetization.CrateLuck(player) == 2,
		string.format("before %s, after %s, after refresh %s, cancelled %s", tostring(before), tostring(after), tostring(afterRefresh), tostring(notBought)))
	Monetization.Clear(player)
	expect("leaving clears the session's bought passes", not Monetization.Owns(player, "CrateLuck"))
end)

-- Crate luck shown vs rolled ---------------------------------------------------------------------------
case("[bug] a crate open is refused when the luck shown isn't the player's luck", function()
	reset()
	robloxSays = {}
	Monetization.Clear(player)
	Monetization.Refresh(player)
	data.TempPasses = { CrateLuck = os.time() - 1 } -- the Daily Spin 2x Crate Luck just ran out
	data.Crates.Rare = 2
	local ok, message = CrateService.Open(player, "Rare", 2)
	local spent = 2 - data.Crates.Rare
	expect("[bug] cards showed 2x, luck is now 1x: refused, nothing spent, told why", not ok and spent == 0 and type(message) == "string",
		string.format("ok %s, spent %d, %s", tostring(ok), spent, tostring(message)))
	-- Open ends by firing the reveal at the player, which a stand-in can't receive: pcall and read the profile.
	pcall(CrateService.Open, player, "Rare", 1)
	expect("cards showed 1x and luck is 1x: it opens", data.Crates.Rare == 1)
	pcall(CrateService.Open, player, "Rare", nil)
	expect("no luck sent (the lobby altar shows no odds): it opens", data.Crates.Rare == 0)
end)

-- Restore -----------------------------------------------------------------------------------------------
GamepassConfig.Products.ProbeCoinPack = nil
coinPass.id, luckPass.id = savedPassIds.coin, savedPassIds.luck
PlayerData.Save, PlayerData.CanSave, StateSync.Push, StateSync.Notify = real.Save, real.CanSave, real.Push, real.Notify
PlayerData.HasStore = real.HasStore
Monetization.OwnsPassAsync = real.OwnsPassAsync
Monetization.Clear(player)
print(string.format("[ReceiptProbe] finished: %d passed, %d failed (%d stubbed saves, %d ownership checks)", passes, failures, saveCalls, ownsCalls))
