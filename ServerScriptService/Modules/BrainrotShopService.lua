-- Buying one specific brainrot with Robux.
--
-- There's one developer product per rarity (GamepassConfig.BrainrotPrices / BrainrotProductIds), not
-- one per brainrot. So the product alone can't say WHICH brainrot was bought; the choice has to be
-- tied to the purchase some other way, safely:
--
--   1. The player picks a brainrot in the menu. Choose() checks it, writes the choice into their
--      profile (PendingBrainrot[rarity]) and only THEN opens the purchase prompt, from the server.
--   2. The receipt arrives at Monetization's ProcessReceipt, which calls Grant() through the
--      "Brainrot" grant handler. Grant() gives exactly the stored choice and clears it.
--
-- Why it holds up:
--   * Never double-granted: Monetization records every PurchaseId in the profile and answers a
--     repeated receipt with PurchaseGranted without granting again. Grant() itself validates
--     everything before changing anything, so a failure grants nothing and the receipt is retried.
--   * Disconnects: the choice lives in the profile, which is saved when the player leaves. If they
--     pay and drop, Roblox re-delivers the receipt when they next join, and the saved choice is
--     still there. If a DataStore outage lost the choice as well, the receipt still pays out: a
--     brainrot of the rarity they paid for, one they don't own yet if there is one, rather than
--     nothing.
--   * Switching mid-prompt: while a prompt for a rarity is open, a new choice for that rarity is
--     refused, so the choice can't change underneath a purchase. A prompt closed without buying
--     clears that choice.
--   * Buying twice before the first receipt lands: picks QUEUE, oldest first, and each receipt takes
--     the oldest one that was paid for. They are never overwritten. The prompt-finished event clears
--     the open-prompt hold the moment a purchase completes, so without the queue a second pick made
--     while the first receipt was still in flight REPLACED it -- and that receipt, bought for the
--     first brainrot, handed over the second, while the second purchase found nothing pending and
--     paid out a random unowned brainrot instead. One player, two purchases, neither pick.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local BrainrotShopService = {}

-- How long an unanswered prompt blocks a NEW prompt for its rarity, in case the "finished" event
-- never arrives (it always should).
local PROMPT_HOLD_SECONDS = 180

-- How many picks one rarity may have waiting on receipts at once. A pick only waits while its receipt
-- is in flight, so this is a sanity bound rather than a limit anyone reaches honestly.
local MAX_PENDING = 5

-- Player -> rarity -> os.clock() when that rarity's purchase prompt opened.
local openPrompts = {}

-- Opens the purchase prompt. A field, so tools/brainrot_shop_probe.lua can stand in for Roblox's.
BrainrotShopService.Prompt = function(player, productId)
	MarketplaceService:PromptProductPurchase(player, productId)
end

-- The picks for `rarity` that are still waiting on a receipt, OLDEST FIRST.
--
-- More than one can be waiting: a player can pay for A and, before that receipt is processed (it can
-- be delayed, retried after NotProcessedYet, or re-delivered after a rejoin), buy B of the same
-- rarity. They paid for both and must get both.
--
-- Stored in a shape an older build of this file still reads correctly: the OLDEST pick lives in the
-- slot's own `name`/`at`, and any later ones hang off `more`. Old code reads `name`, which is the
-- pick the next receipt is owed, so a rollback degrades to granting the right brainrot rather than a
-- random one. `paid` marks a pick whose prompt reported a completed purchase.
local function readPending(data, rarity)
	local slot = data.PendingBrainrot[rarity]
	if type(slot) ~= "table" or type(slot.name) ~= "string" then
		return {}
	end
	local list = { { name = slot.name, at = slot.at or 0, paid = slot.paid } }
	if type(slot.more) == "table" then
		for _, entry in ipairs(slot.more) do
			if type(entry) == "table" and type(entry.name) == "string" then
				table.insert(list, { name = entry.name, at = entry.at or 0, paid = entry.paid })
			end
		end
	end
	return list
end

local function writePending(data, rarity, list)
	if #list == 0 then
		data.PendingBrainrot[rarity] = nil
		return
	end
	local slot = { name = list[1].name, at = list[1].at, paid = list[1].paid or nil }
	if #list > 1 then
		slot.more = {}
		for index = 2, #list do
			table.insert(slot.more, { name = list[index].name, at = list[index].at, paid = list[index].paid or nil })
		end
	end
	data.PendingBrainrot[rarity] = slot
end

local function productFor(rarity)
	local product = GamepassConfig.BrainrotProduct(rarity)
	if product and product.grant and product.grant.kind == "Brainrot" and product.grant.rarity == rarity then
		return product
	end
	return nil
end

-- The player picked `name` to buy. Returns ok, message.
function BrainrotShopService.Choose(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end
	local def = type(name) == "string" and BrainrotData.Get(name) or nil
	if not def then
		return false, "No such brainrot."
	end
	local product = productFor(def.rarity)
	if not product or type(product.id) ~= "number" or product.id <= 0 then
		return false, "Buying " .. def.rarity .. " brainrots isn't set up yet."
	end

	local prompts = openPrompts[player]
	local openedAt = prompts and prompts[def.rarity]
	if openedAt and os.clock() - openedAt < PROMPT_HOLD_SECONDS then
		return false, string.format("Finish or close your current %s purchase first.", def.rarity)
	end

	local now = os.time()
	local list = readPending(data, def.rarity)
	-- Abandoned picks are dropped here: unpaid, and older than the hold. Only a prompt whose
	-- "finished" event never arrived leaves one, and without this it would sit in the queue forever
	-- and take a receipt that a real pick is owed.
	local kept = {}
	for _, entry in ipairs(list) do
		if entry.paid or (now - (entry.at or 0)) <= PROMPT_HOLD_SECONDS then
			table.insert(kept, entry)
		end
	end
	list = kept
	if #list >= MAX_PENDING then
		return false, string.format("You have %d %s purchases still being delivered. Try again in a moment.", #list, def.rarity)
	end

	-- APPENDED, never overwritten. Overwriting is the bug this queue exists to make impossible: the
	-- prompt-finished event clears `openPrompts` as soon as the purchase completes, so a player could
	-- pick again while the paid pick was still waiting on its receipt -- and that receipt, bought for
	-- the first brainrot, would hand over the second. The second purchase then found nothing pending
	-- and paid out a RANDOM unowned brainrot, so one player lost both picks across two purchases.
	table.insert(list, { name = def.name, at = now })
	writePending(data, def.rarity, list)

	openPrompts[player] = prompts or {}
	openPrompts[player][def.rarity] = os.clock()
	local ok, err = pcall(BrainrotShopService.Prompt, player, product.id)
	if not ok then
		openPrompts[player][def.rarity] = nil
		-- Only the pick this call added: anything already waiting has been paid for.
		local current = readPending(data, def.rarity)
		if #current > 0 and current[#current].name == def.name and not current[#current].paid then
			table.remove(current)
			writePending(data, def.rarity, current)
		end
		warn("[BrainrotShop] prompt failed: " .. tostring(err))
		return false, "Couldn't open the purchase. Try again."
	end
	return true, nil
end

-- The receipt handler for kind "Brainrot" (registered by Bootstrap with Monetization). Returns the
-- brainrot given and whether it was the player's stored choice. Errors, changing nothing, if the
-- product is misconfigured, so the receipt is retried rather than half-granted.
function BrainrotShopService.Grant(player, data, grant)
	local rarity = grant and grant.rarity
	local pool = BrainrotData.OfRarity(rarity)
	if #pool == 0 then
		error("brainrot product for unknown rarity " .. tostring(rarity))
	end

	-- The oldest pick that is known to have been paid for, and otherwise the oldest pick of any kind.
	-- Preferring a paid one keeps a pick whose "finished" event was lost from taking the receipt that
	-- a genuinely paid pick is waiting on.
	local list = readPending(data, rarity)
	local index = nil
	for position, entry in ipairs(list) do
		if entry.paid then
			index = position
			break
		end
	end
	if not index and #list > 0 then
		index = 1
	end

	local def = index and BrainrotData.Get(list[index].name) or nil
	local chosen = def ~= nil and def.rarity == rarity
	if index then
		-- Consumed either way: a stored name that is no longer a brainrot of this rarity is rubbish
		-- and must not jam the queue for the receipts behind it.
		table.remove(list, index)
		writePending(data, rarity, list)
	end

	if not chosen then
		local owned = {}
		for _, name in ipairs(data.Brainrots) do
			owned[name] = true
		end
		local unowned = {}
		for _, candidate in ipairs(pool) do
			if not owned[candidate.name] then
				table.insert(unowned, candidate)
			end
		end
		local from = #unowned > 0 and unowned or pool
		def = from[math.random(1, #from)]
	end

	table.insert(data.Brainrots, def.name)
	if openPrompts[player] then
		openPrompts[player][rarity] = nil
	end
	return def, chosen
end

-- What Roblox's PromptProductPurchaseFinished means for the stored picks. Split out from the event
-- so tools/brainrot_shop_probe.lua can drive it: this branch decides whether a pick is kept for its
-- receipt or forgotten, which is the half of the money path an event nobody can fire is the worst
-- place to hide.
function BrainrotShopService.PromptFinished(player, rarity, isPurchased)
	if openPrompts[player] then
		openPrompts[player][rarity] = nil
	end
	local data = PlayerData.Get(player)
	if not data then
		return
	end
	-- This event belongs to the prompt that just closed, which is the NEWEST pick for the rarity:
	-- a second prompt for the same rarity cannot be open while this one is (PROMPT_HOLD_SECONDS).
	local list = readPending(data, rarity)
	if #list == 0 then
		return
	end
	if isPurchased then
		-- Paid: keep the pick until its receipt uses it, and mark it so nothing else can take it.
		list[#list].paid = true
	elseif not list[#list].paid then
		-- Closed without buying: forget that pick, and only that pick.
		table.remove(list)
	end
	writePending(data, rarity, list)
end

function BrainrotShopService.Start()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		local player = Players:GetPlayerByUserId(userId)
		local product = GamepassConfig.GetProductById(productId)
		if not player or not product or not product.grant or product.grant.kind ~= "Brainrot" then
			return
		end
		BrainrotShopService.PromptFinished(player, product.grant.rarity, isPurchased)
	end)
	Players.PlayerRemoving:Connect(function(player)
		openPrompts[player] = nil
	end)
end

return BrainrotShopService
