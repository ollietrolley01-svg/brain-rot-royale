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
--     clears the choice.

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local BrainrotShopService = {}

-- How long an unanswered prompt blocks a new choice for its rarity, in case the "finished" event
-- never arrives (it always should).
local PROMPT_HOLD_SECONDS = 180

-- Player -> rarity -> os.clock() when that rarity's purchase prompt opened.
local openPrompts = {}

-- Opens the purchase prompt. A field, so tools/brainrot_shop_probe.lua can stand in for Roblox's.
BrainrotShopService.Prompt = function(player, productId)
	MarketplaceService:PromptProductPurchase(player, productId)
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

	data.PendingBrainrot[def.rarity] = { name = def.name, at = os.time() }
	openPrompts[player] = prompts or {}
	openPrompts[player][def.rarity] = os.clock()
	local ok, err = pcall(BrainrotShopService.Prompt, player, product.id)
	if not ok then
		openPrompts[player][def.rarity] = nil
		data.PendingBrainrot[def.rarity] = nil
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

	local pending = data.PendingBrainrot[rarity]
	local def = pending and BrainrotData.Get(pending.name) or nil
	local chosen = def ~= nil and def.rarity == rarity
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
	data.PendingBrainrot[rarity] = nil
	if openPrompts[player] then
		openPrompts[player][rarity] = nil
	end
	return def, chosen
end

function BrainrotShopService.Start()
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, isPurchased)
		local player = Players:GetPlayerByUserId(userId)
		local product = GamepassConfig.GetProductById(productId)
		if not player or not product or not product.grant or product.grant.kind ~= "Brainrot" then
			return
		end
		local rarity = product.grant.rarity
		if openPrompts[player] then
			openPrompts[player][rarity] = nil
		end
		-- Closed without buying: forget the choice. (A purchase keeps it until its receipt uses it,
		-- whichever of the two events arrives first.)
		if not isPurchased then
			local data = PlayerData.Get(player)
			if data then
				data.PendingBrainrot[rarity] = nil
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		openPrompts[player] = nil
	end)
end

return BrainrotShopService
