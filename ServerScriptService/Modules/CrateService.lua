-- Crate inventory and opening.
--
-- Brainrot crates roll a rarity from their odds, then a random brainrot of it — or, now and then
-- (`accessoryChance`), an accessory of that rarity the player doesn't own yet. Item crates roll a
-- rarity and hand out an unowned cosmetic of their kind at it, refunding part of the price when
-- there's nothing new left there. The big crates can also hit a coin jackpot on top.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))

local Monetization = require(script.Parent:WaitForChild("Monetization"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local CrateService = {}

local crateOpened = Remotes.Event("CrateOpened")

-- Crates the game HANDS OUT: placements, the Daily Spin, quests, the pass, rank rewards. They're
-- counted in FreeCrates too, because nobody paid for them (see Open: Beginner's Luck only ever
-- touches a free crate, never one bought with Robux or coins).
function CrateService.Give(player, tier, amount)
	local data = PlayerData.Get(player)
	if not data or not CrateData.Get(tier) then
		return false
	end
	amount = amount or 1
	data.Crates[tier] = (data.Crates[tier] or 0) + amount
	if data.FreeCrates then
		data.FreeCrates[tier] = (data.FreeCrates[tier] or 0) + amount
	end
	return true
end

-- Crates bought with Robux (a crate product or a bundle): counted in PaidCrates, so the pull they
-- give can be marked as purchased (see Open). Never counted as free.
function CrateService.GivePaid(player, tier, amount)
	local data = PlayerData.Get(player)
	if not data or not CrateData.Get(tier) then
		return false
	end
	amount = amount or 1
	data.Crates[tier] = (data.Crates[tier] or 0) + amount
	data.PaidCrates[tier] = (data.PaidCrates[tier] or 0) + amount
	return true
end

-- The one-off Beginner's Luck grant, run once per profile when it loads (Bootstrap calls it). Every
-- profile gets its charges once, new or existing, and the marker is written in the same breath as
-- the charges, so nothing can hand them out twice: the trigger is `granted`, never the field being
-- absent. Nothing else in the game may raise the count (verify.py enforces that).
function CrateService.GrantBeginnerLuck(player)
	local data = PlayerData.Get(player)
	local progression = data and data.Progression
	if not progression then
		return false
	end
	local beginner = progression.beginnerLuck
	if not beginner then
		beginner = { left = 0, granted = false }
		progression.beginnerLuck = beginner
	end
	if beginner.granted == true then
		return false
	end
	beginner.left = CrateData.BeginnerCrates
	beginner.granted = true
	return true
end

-- Whether the next crate of this tier would roll with Beginner's Luck (CrateData holds the rule, so
-- StateSync's card data and this roll can't disagree).
function CrateService.BeginnerBoosted(data, tier)
	return CrateData.BeginnerBoosted(CrateData.Get(tier), data.Crates[tier], data.PaidCrates[tier],
		data.FreeCrates and data.FreeCrates[tier] or 0, CrateData.BeginnerLeft(data.Progression))
end

function CrateService.Buy(player, tier)
	local crate = CrateData.Get(tier)
	if not crate then
		return false, "No such crate."
	end

	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if crate.robuxOnly or not crate.coinPrice then
		return false, crate.name .. "s are bought with Robux."
	end

	if not ShopRotation.IsCrateInStock(tier) then
		return false, string.format("%s is out of stock. Stock changes in %s.", crate.name, ShopRotation.FormatTimeLeft())
	end

	if data.SahurCoins < crate.coinPrice then
		return false, string.format("Need %d more SahurCoins.", math.ceil(crate.coinPrice - data.SahurCoins))
	end

	data.SahurCoins -= crate.coinPrice
	data.Crates[tier] = (data.Crates[tier] or 0) + 1

	StateSync.Push(player)
	return true, "Bought a " .. crate.name .. "."
end

-- A random cosmetic of `kind` at `rarity` the player doesn't own yet, or nil.
-- `kind` is one cosmetic kind, or a list of them (a Style Crate tier draws from all four, which is
-- what lets the tiers vary by quality instead of splitting pools too small to tier).
local function unownedCosmetic(data, kind, rarity)
	local kinds = type(kind) == "table" and kind or { kind }
	local pool = {}
	for _, oneKind in ipairs(kinds) do
		for _, id in ipairs(CosmeticData.OfKind(oneKind)) do
			local item = CosmeticData.Get(id)
			if item.rarity == rarity and not data.Cosmetics.owned[id] then
				table.insert(pool, item)
			end
		end
	end
	return #pool > 0 and pool[math.random(1, #pool)] or nil
end

-- `shownLuck` is the crate luck the player's crate cards were showing odds for (nil from places that
-- show no odds, like the lobby altar). If it's no longer their luck, say because a Daily Spin 2x Crate
-- Luck has just run out, nothing is spent: the cards are refreshed and they're told, so a crate is
-- never rolled at odds other than the ones on screen.
function CrateService.Open(player, tier, shownLuck)
	local crate = CrateData.Get(tier)
	if not crate then
		return false, "No such crate."
	end

	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if (data.Crates[tier] or 0) <= 0 then
		return false, "You don't have a " .. crate.name .. "."
	end

	-- Beginner's Luck rides on top of the pass's luck, for a free brainrot crate only, while charges
	-- remain. Worked out before anything is spent, and from the same function the menu draws with.
	local boosted = CrateService.BeginnerBoosted(data, tier)
	local luck = CrateData.LuckFor(crate, Monetization.CrateLuck(player), boosted)
	if shownLuck ~= nil and shownLuck ~= luck then
		local message = luck > 1
			and string.format("Your crate luck is now %dx. The odds on the card have been updated, check them and open again.", luck)
			or "Your crate luck boost has run out. The odds on the card have been updated, check them and open again."
		StateSync.Push(player)
		-- Not toasted here: the REPLY is. Bootstrap's guard() toasts every menu remote's message, and
		-- the altar (LobbyService.OnAltarOpen) toasts what it is returned -- this line said it twice.
		return false, message
	end

	-- Opened in this order: Robux crates, then coin-bought ones, then the ones the game handed out.
	-- Bought before free, so a crate anyone paid for is never left waiting behind a boosted free one
	-- (that's also what lets a boosted card be the only card that hides its percentages).
	local held = data.Crates[tier] or 0
	local free = data.FreeCrates and (data.FreeCrates[tier] or 0) or 0
	local paid = data.PaidCrates[tier] or 0
	local coinBought = math.max(0, held - paid - free)
	data.Crates[tier] = held - 1

	-- `purchased` goes out on the result, and Bootstrap's openCrateFor has the Rot Index record that
	-- pull without Brain Cells.
	local purchased = paid > 0
	if purchased then
		data.PaidCrates[tier] -= 1
		if data.PaidCrates[tier] <= 0 then
			data.PaidCrates[tier] = nil
		end
	elseif coinBought <= 0 and free > 0 then
		data.FreeCrates[tier] -= 1
		if data.FreeCrates[tier] <= 0 then
			data.FreeCrates[tier] = nil
		end
	end
	-- One charge per boosted open, here, where the crate itself is spent: a refused open above has
	-- already returned, and nothing between the two yields.
	if boosted then
		data.Progression.beginnerLuck.left -= 1
	end

	-- The player's crate luck (the 2x Crate Luck pass), applied through CrateData.EffectiveOdds: the
	-- very function the crate cards use to show this player their odds, so shown and rolled agree
	-- (`luck` is read above, before anything is spent).
	local rolledRarity = Rarity.Roll(CrateData.EffectiveOdds(crate, luck))
	local category = crate.category or "Brainrot"

	-- Pity: enough dry opens in a row and this one is forced up to the guaranteed rarity.
	local pityHit = false
	if crate.pity then
		local count = (data.Pity[tier] or 0) + 1
		if (Rarity.Index[rolledRarity] or 0) >= (Rarity.Index[crate.pity.rarity] or 0) then
			count = 0
		elseif count >= crate.pity.every then
			rolledRarity = crate.pity.rarity
			pityHit = true
			count = 0
		end
		data.Pity[tier] = count
	end

	-- Everything the client's opening animation needs: which crate, what came out, and how rare.
	local result = {
		crate = crate.name,
		crateId = tier,
		crateColor = crate.color or Rarity.Color(tier),
		rarity = rolledRarity,
		pity = pityHit or nil,
		luck = luck > 1 and luck or nil,
		purchased = purchased or nil,
	}
	local message

	if category == "Brainrot" then
		local accessory = nil
		if math.random() * 100 < (crate.accessoryChance or 0) then
			accessory = unownedCosmetic(data, "Accessory", rolledRarity)
		end

		if accessory then
			data.Cosmetics.owned[accessory.id] = true
			result.kind = "Accessory"
			result.id = accessory.id
			result.name = accessory.name
			result.color = accessory.color
			message = string.format("%s: %s accessory!", crate.name, accessory.name)
		else
			local def = BrainrotData.RandomOfRarity(rolledRarity)
			table.insert(data.Brainrots, def.name)
			result.kind = "Brainrot"
			result.name = def.name
			result.rarity = def.rarity
			result.coinValue = def.coinValue
			message = string.format("%s: %s!", crate.name, def.name)
		end
	else
		-- A Style Crate tier names the kinds it draws from; a kind-crate is just its own category.
		local item = unownedCosmetic(data, crate.kinds or category, rolledRarity)
		-- Oliver, 2026-09-22 14:14: no duplicate refund from crates. When the rolled rarity has nothing
		-- new left, the pull moves to the NEAREST rarity this crate can drop that still has something
		-- unowned (lower first on a tie), so it still pays out a real cosmetic. Only a player who owns
		-- everything this crate can give still gets the coins below, since there is nothing else to hand out.
		if not item then
			local odds = CrateData.EffectiveOdds(crate, luck)
			local home = Rarity.Index[rolledRarity] or 1
			for distance = 1, #Rarity.Order do
				for _, index in ipairs({ home - distance, home + distance }) do
					local rarity = Rarity.Order[index]
					if not item and rarity and (odds[rarity] or 0) > 0 then
						item = unownedCosmetic(data, crate.kinds or category, rarity)
					end
				end
				if item then
					break
				end
			end
		end
		if item then
			data.Cosmetics.owned[item.id] = true
			result.kind = item.kind
			-- The cosmetic's id, so the reveal can build the real thing (a Parachute's canopy).
			result.id = item.id
			result.name = item.name
			result.color = item.color
			message = string.format("%s: %s!", crate.name, item.name)
		else
			-- Nothing new left anywhere in this crate: a partial refund rather than a dead pull.
			local refund = math.floor(crate.coinPrice * (crate.duplicateRefund or 0.3))
			data.SahurCoins += refund
			result.kind = "Refund"
			result.name = string.format("%d SahurCoins", refund)
			result.coinValue = refund
			message = string.format("%s: you own everything in this crate — refunded %d SahurCoins.", crate.name, refund)
		end
	end

	if crate.jackpot and math.random() < crate.jackpot.chance then
		local bonus = math.random(crate.jackpot.min, crate.jackpot.max)
		data.SahurCoins += bonus
		result.jackpot = bonus
		message = string.format("%s  +%d SahurCoin JACKPOT!", message, bonus)
	end
	if pityHit then
		message = message .. "  (guaranteed — your luck was due)"
	end

	crateOpened:FireClient(player, result)
	StateSync.Push(player)
	-- The result goes back too, so the lobby stage can show everyone what came out.
	return true, message, result
end

return CrateService
