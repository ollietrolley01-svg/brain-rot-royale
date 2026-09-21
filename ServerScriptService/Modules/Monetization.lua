-- Gamepass ownership (cached per session) and developer-product fulfilment.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local Monetization = {}

-- Test purchases in Studio, where there's no DataStore to save them to (see HandleReceipt). Never
-- true in a live server: this is Studio AND no store, both.
local STUDIO_TEST_GRANTS = RunService:IsStudio()

local NO_PASSES = table.freeze({})
-- Receipts remembered per profile (saved with it). Roblox only re-sends a receipt that was never
-- confirmed, which is at most a few purchases back; this is far more than enough, and small.
local MAX_TRACKED_PURCHASES = 500
-- An ownership check that errors (MarketplaceService having a bad moment) is asked again this many
-- times, this far apart, instead of leaving a paying player without their pass all session.
local REFRESH_RETRIES = 3
local REFRESH_RETRY_SECONDS = 30

local ownedCache = {}
-- Passes bought in this session, straight from PromptGamePassPurchaseFinished. Roblox caches
-- UserOwnsGamePassAsync, which can go on saying false for a while after a purchase.
local boughtThisSession = {}
local refreshRetries = {}
local grantHandlers = {}
local onPassesChanged = nil

-- Asks Roblox whether a user owns a pass. A field, so tools/receipt_probe.lua can stand in for it.
Monetization.OwnsPassAsync = function(userId, passId)
	return MarketplaceService:UserOwnsGamePassAsync(userId, passId)
end

function Monetization.Refresh(player)
	local owned = {}
	local previous = ownedCache[player.UserId]
	local failed = false

	for key, pass in pairs(GamepassConfig.Passes) do
		if pass.id and pass.id > 0 then
			local ok, result = pcall(Monetization.OwnsPassAsync, player.UserId, pass.id)
			if ok then
				owned[key] = result == true
			else
				warn("[Monetization] Ownership check failed for " .. key .. ": " .. tostring(result))
				failed = true
				owned[key] = previous and previous[key] or false
			end
		else
			owned[key] = false
		end
	end
	-- After the checks, which yield: a pass bought while they ran still counts.
	for key in pairs(boughtThisSession[player.UserId] or {}) do
		owned[key] = true
	end

	ownedCache[player.UserId] = owned

	if failed then
		local tries = (refreshRetries[player.UserId] or 0) + 1
		if tries <= REFRESH_RETRIES then
			refreshRetries[player.UserId] = tries
			task.delay(REFRESH_RETRY_SECONDS, function()
				-- Only while they're still here (Clear on leaving drops the cache).
				if ownedCache[player.UserId] and typeof(player) == "Instance" and player.Parent then
					Monetization.Refresh(player)
					if onPassesChanged then
						onPassesChanged(player)
					end
				end
			end)
		end
	else
		refreshRetries[player.UserId] = nil
	end
	return owned
end

function Monetization.GetPasses(player)
	return ownedCache[player.UserId] or NO_PASSES
end

-- Owned outright, or won for a day on the Daily Spin and not run out yet.
function Monetization.Owns(player, key)
	if Monetization.GetPasses(player)[key] == true then
		return true
	end
	local data = PlayerData.Get(player)
	local until_ = data and data.TempPasses and data.TempPasses[key]
	return type(until_) == "number" and until_ > os.time()
end

-- The crate luck a player opens with (CrateData.EffectiveOdds): the 2x Crate Luck pass's `luck`
-- when owned (or won for a day on the Daily Spin), otherwise 1. CrateService rolls with this and
-- StateSync sends it to the crate cards, so both always agree.
function Monetization.CrateLuck(player)
	local pass = GamepassConfig.Passes.CrateLuck
	if pass and Monetization.Owns(player, "CrateLuck") then
		return pass.luck or 2
	end
	return 1
end

-- The one way coins EARNED by playing are paid, so the 2x SahurCoins pass doubles all of them alike.
-- `source` "sell" marks coins from selling brainrots, doubled only if the pass says `doublesSelling`
-- (see GamepassConfig for why not). Robux grants, crate jackpots and refunds don't come through here.
-- Returns the coins actually added.
function Monetization.EarnCoins(player, amount, source)
	local data = PlayerData.Get(player)
	if not data or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return 0
	end
	local pass = GamepassConfig.Passes.CoinBoost
	local multiplier = 1
	if pass and Monetization.Owns(player, "CoinBoost") and (source ~= "sell" or pass.doublesSelling) then
		multiplier = pass.multiplier or 2
	end
	local granted = math.floor(amount * multiplier)
	data.SahurCoins += granted
	return granted
end

-- Seconds left on a temporary pass, or nil.
function Monetization.TempRemaining(player, key)
	local data = PlayerData.Get(player)
	local until_ = data and data.TempPasses and data.TempPasses[key]
	if type(until_) == "number" and until_ > os.time() then
		return until_ - os.time()
	end
	return nil
end

-- The player has left: forget everything held for them. (Only then: clearing the cache mid-session
-- switches every pass they paid for off, since nothing fetches it again.)
function Monetization.Clear(player)
	ownedCache[player.UserId] = nil
	boughtThisSession[player.UserId] = nil
	refreshRetries[player.UserId] = nil
end

-- Server-side PromptGamePassPurchaseFinished, which Roblox fires and clients can't: trusted. The pass
-- bought is owned from this moment, whatever the cached ownership check still says.
function Monetization.OnPassPurchaseFinished(player, gamePassId, wasPurchased)
	if not wasPurchased then
		return
	end
	for key, pass in pairs(GamepassConfig.Passes) do
		if pass.id and pass.id > 0 and pass.id == gamePassId then
			boughtThisSession[player.UserId] = boughtThisSession[player.UserId] or {}
			boughtThisSession[player.UserId][key] = true
			if ownedCache[player.UserId] then
				ownedCache[player.UserId][key] = true
			end
		end
	end
	Monetization.Refresh(player)
	if typeof(player) == "Instance" and not player.Parent then
		-- Left while the checks ran: don't keep what Refresh just cached.
		Monetization.Clear(player)
		return
	end
	if onPassesChanged then
		onPassesChanged(player)
	end
end

-- Registered by Bootstrap so this module stays unaware of CrateService/RewardService.
--
-- handler(player, data, grant, product) makes the grant's changes to `data`, validating everything
-- it needs BEFORE changing anything, and must not yield. It may return an `announce` function for
-- everything else (toasts, state pushes, reveals, collection checks): HandleReceipt runs that only
-- after the purchase is recorded and saved, in its own pcall, so a failing announcement can never
-- make a receipt look ungranted and get granted again.
function Monetization.RegisterGrantHandler(kind, handler)
	grantHandlers[kind] = handler
end

local function alreadyGranted(data, purchaseId)
	for _, id in ipairs(data.PurchaseIds) do
		if id == purchaseId then
			return true
		end
	end
	return false
end

local function recordPurchase(data, purchaseId)
	table.insert(data.PurchaseIds, purchaseId)
	while #data.PurchaseIds > MAX_TRACKED_PURCHASES do
		table.remove(data.PurchaseIds, 1)
	end
end

-- The profile as one string with its keys in sorted order, so two snapshots are equal exactly when
-- the contents are. Nil if it holds something a DataStore couldn't (it never should).
local function snapshot(value)
	local out = {}
	local function write(v, depth)
		local kind = type(v)
		if kind == "table" then
			if depth > 40 then
				error("too deep")
			end
			local keys = {}
			for k in pairs(v) do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				if type(a) ~= type(b) then
					return type(a) < type(b)
				end
				return a < b
			end)
			table.insert(out, "{")
			for _, k in ipairs(keys) do
				write(k, depth + 1)
				table.insert(out, "=")
				write(v[k], depth + 1)
				table.insert(out, ";")
			end
			table.insert(out, "}")
		elseif kind == "number" then
			table.insert(out, string.format("%.17g", v))
		elseif kind == "string" then
			table.insert(out, string.format("%q", v))
		elseif kind == "boolean" then
			table.insert(out, tostring(v))
		else
			error("unsaveable " .. kind)
		end
	end
	local ok = pcall(write, value, 0)
	return ok and table.concat(out) or nil
end

-- One receipt, for `player` (nil if they aren't in this server). Everything ProcessReceipt does lives
-- here, so tools/receipt_probe.lua and tools/monetization_probe.lua can drive the real logic.
--
-- The rules, each one a way a purchase used to be lost or doubled:
--   * Nothing is granted into a profile that can't be saved (still loading, or running on defaults
--     after a failed load): that grant would die with the session. NotProcessedYet, and Roblox sends
--     the receipt again later.
--   * PurchaseGranted only ever follows a successful save of a profile holding the grant and its
--     PurchaseId, including for a receipt already granted: that may be a retry in this same session
--     after the save failed, when the grant is still only in memory.
--   * A PurchaseId is granted once, in this session or any later one (the ids are saved).
--   * A handler that fails after changing the profile has granted (part of) the purchase, so it's
--     recorded like any grant; answering NotProcessedYet there would grant it all again on the retry.
--   * The handler's `announce` runs only after all that, and its errors change nothing.
function Monetization.HandleReceipt(player, receiptInfo)
	local notYet = Enum.ProductPurchaseDecision.NotProcessedYet
	if not player then
		return notYet
	end

	local data = PlayerData.Get(player)
	if not data then
		return notYet
	end
	-- Studio has no DataStore, so CanSave is false there and a test purchase would never be granted,
	-- which makes the shop look broken while you're working on it. BOTH halves are required, so this
	-- can never be true on a live server (which always has a DataStore); a live failed load still
	-- refuses, which is the case that matters.
	local studioTestGrant = STUDIO_TEST_GRANTS and not PlayerData.HasStore()
	if not PlayerData.CanSave(player) and not studioTestGrant then
		return notYet
	end

	local product = GamepassConfig.GetProductById(receiptInfo.ProductId)
	if not product then
		warn("[Monetization] Unknown product id " .. tostring(receiptInfo.ProductId))
		return notYet
	end

	local purchaseId = tostring(receiptInfo.PurchaseId)
	if alreadyGranted(data, purchaseId) then
		if not PlayerData.Save(player) and not studioTestGrant then
			return notYet
		end
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end

	local handler = grantHandlers[product.grant.kind]
	if not handler then
		warn("[Monetization] No handler for grant kind " .. tostring(product.grant.kind))
		return notYet
	end

	local before = snapshot(data)
	local ok, result = pcall(handler, player, data, product.grant, product)
	if not ok then
		if before == nil or snapshot(data) == before then
			warn("[Monetization] Grant failed, nothing changed, left for a retry: " .. tostring(result))
			return notYet
		end
		warn(string.format("[Monetization] Grant for %s (%s) failed AFTER changing the profile; recorded as granted so a retry can't grant it again: %s",
			tostring(product.key), purchaseId, tostring(result)))
	end

	recordPurchase(data, purchaseId)
	local saved = PlayerData.Save(player)
	if not saved and studioTestGrant then
		warn(string.format("[Monetization] Studio test grant of %s: there's no DataStore here, so it won't persist.",
			tostring(product.key)))
	end

	if ok and type(result) == "function" then
		task.spawn(function()
			local announced, err = pcall(result)
			if not announced then
				warn("[Monetization] Announcing a grant failed (the grant itself stands): " .. tostring(err))
			end
		end)
	end

	return (saved or studioTestGrant) and Enum.ProductPurchaseDecision.PurchaseGranted or notYet
end

function Monetization.Init(onPassPurchased)
	onPassesChanged = onPassPurchased

	MarketplaceService.ProcessReceipt = function(receiptInfo)
		return Monetization.HandleReceipt(Players:GetPlayerByUserId(receiptInfo.PlayerId), receiptInfo)
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(Monetization.OnPassPurchaseFinished)
end

return Monetization
