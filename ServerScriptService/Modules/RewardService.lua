-- Coins, XP, brainrot grants, placement payouts, and selling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))

local BattlePassService = require(script.Parent:WaitForChild("BattlePassService"))
local CrateService = require(script.Parent:WaitForChild("CrateService"))
local Monetization = require(script.Parent:WaitForChild("Monetization"))
local GlobalBoardService = require(script.Parent:WaitForChild("GlobalBoardService"))
local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))

local RewardService = {}

-- Placement coins are scaled by this for the match; a High Stakes event raises it.
RewardService.PlacementMultiplier = 1

-- Coins earned by playing, through Monetization.EarnCoins so the 2x SahurCoins pass applies to
-- every source alike. `source` "sell" marks coins from selling brainrots (see GamepassConfig).
function RewardService.AddCoins(player, amount, source)
	return Monetization.EarnCoins(player, amount, source)
end

function RewardService.GiveBrainrot(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false
	end
	if not BrainrotData.Get(name) then
		return false
	end
	table.insert(data.Brainrots, name)
	return true
end

-- Bot kills pay noticeably less than real ones, so a lobby full of backfill can't be farmed
-- as hard as a lobby full of people.
function RewardService.AwardKill(player, wasBot)
	local data = PlayerData.Get(player)
	if not data then
		return
	end

	data.Stats.kills += 1
	RewardService.AddCoins(player, wasBot and MatchConfig.CoinsPerBotKill or MatchConfig.CoinsPerKill)
	BattlePassService.AddXp(player, wasBot and MatchConfig.XpPerBotKill or MatchConfig.XpPerKill)
	StateSync.Push(player)
	QuestService.Progress(player, "kills", 1)
end

function RewardService.AwardBonusCoins(player, amount, reason)
	local granted = RewardService.AddCoins(player, amount)
	if granted > 0 then
		StateSync.Notify(player, string.format("+%d SahurCoins (%s)", granted, reason))
		StateSync.Push(player)
	end
end

-- Placement rewards do not stack: one crate, from the bracket you landed in. Open it from
-- the menu to find out what's inside.
function RewardService.AwardPlacement(player, rank)
	local data = PlayerData.Get(player)
	if not data then
		return nil
	end

	data.Stats.matches += 1
	if rank == 1 then
		data.Stats.wins += 1
		GlobalBoardService.SubmitWins(player, data.Stats.wins)
	end

	QuestService.Progress(player, "matches", 1)
	if rank <= 10 then
		QuestService.Progress(player, "top10", 1)
	end
	if rank == 1 then
		QuestService.Progress(player, "wins", 1)
	end

	local bracket = MatchConfig.GetBracket(rank)
	if not bracket then
		StateSync.Push(player)
		return nil
	end

	CrateService.Give(player, bracket.crate, 1)

	local coins = RewardService.AddCoins(player, math.floor(bracket.coins * RewardService.PlacementMultiplier))
	BattlePassService.AddXp(player, bracket.xp)
	StateSync.Push(player)

	return {
		rank = rank,
		crate = bracket.crate,
		coins = coins,
		xp = bracket.xp,
	}
end

-- One-time bonus for owning every brainrot of a rarity at once. Paid the first time the set is
-- complete and never again, even if copies are later sold or traded away.
RewardService.CollectionBonus = BrainrotData.CollectionBonus

function RewardService.CheckCollections(player)
	local data = PlayerData.Get(player)
	if not data then
		return false
	end

	local owned = {}
	for _, name in ipairs(data.Brainrots) do
		owned[name] = true
	end

	local completed = false
	for rarity, bonus in pairs(RewardService.CollectionBonus) do
		if not data.Collections[rarity] then
			local set = BrainrotData.OfRarity(rarity)
			local complete = #set > 0
			for _, def in ipairs(set) do
				if not owned[def.name] then
					complete = false
					break
				end
			end
			if complete then
				data.Collections[rarity] = true
				completed = true
				local granted = RewardService.AddCoins(player, bonus)
				StateSync.Notify(player, string.format("%s set complete! +%d SahurCoins", rarity, granted))
				QuestService.Progress(player, "sets", 1)
			end
		end
	end

	if completed then
		StateSync.Push(player)
	end
	return completed
end

-- The brainrot that follows you around and fights for you. Equipping the one already equipped
-- (or nil) takes it off.
function RewardService.SetCompanion(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if name == nil or data.Companion == name then
		data.Companion = nil
		StateSync.Push(player)
		return true, "Companion unequipped."
	end

	if not BrainrotData.Get(name) then
		return false, "No such brainrot."
	end
	if not table.find(data.Brainrots, name) then
		return false, "You don't own that."
	end

	data.Companion = name
	StateSync.Push(player)
	return true, name .. " will follow you now."
end

function RewardService.SetShowcase(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if name == nil then
		data.Showcase = nil
		StateSync.Push(player)
		return true, "Showcase cleared."
	end

	if not BrainrotData.Get(name) then
		return false, "No such brainrot."
	end
	if not table.find(data.Brainrots, name) then
		return false, "You don't own that."
	end

	data.Showcase = name
	StateSync.Push(player)
	return true, "Showing off " .. name .. "."
end

function RewardService.CountOf(data, name)
	local count = 0
	for _, owned in ipairs(data.Brainrots) do
		if owned == name then
			count += 1
		end
	end
	return count
end

-- Set by Bootstrap to TradeService.InSession. Merging is refused while a trade is open: the
-- trade re-checks ownership when it executes, so nothing could be duplicated, but merging away
-- copies you'd offered would quietly turn a trade you were about to confirm into a cancellation.
RewardService.IsTrading = function()
	return false
end

-- Fuses spare copies of a brainrot into the one you keep for its next star (BrainrotData
-- merging). The spares are used up; the kept copy, and every later copy of that brainrot, fights
-- with the bonus.
--
-- `fromStars` is the star count the player saw when they confirmed. If it no longer matches, the
-- merge already happened (a double-click, or two menus) and this one is refused rather than
-- spending a second batch of copies nobody asked to spend. It's optional for server callers.
--
-- Atomic: everything is validated, then the new collection is built aside and checked, and only
-- then is anything written. Nothing here yields, so no other request can run in between.
function RewardService.MergeBrainrot(player, name, fromStars)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local def = BrainrotData.Get(name)
	if not def then
		return false, "No such brainrot."
	end

	if RewardService.IsTrading(player) then
		return false, "Finish or cancel your trade before merging."
	end

	local stars = BrainrotData.ClampStars(data.Stars[name])
	if fromStars ~= nil and fromStars ~= stars then
		return false, string.format("%s is already at %d star%s — that merge went through.", name, stars, stars == 1 and "" or "s")
	end

	local cost = BrainrotData.MergeCost(stars)
	if not cost then
		return false, string.format("%s is already fully merged.", name)
	end

	local owned = RewardService.CountOf(data, name)
	if owned < 1 then
		return false, "You don't own that."
	end
	local spare = owned - 1
	if spare < cost then
		return false, string.format("Merging %s to %d stars takes %d spare cop%s — you have %d.",
			name, stars + 1, cost, cost == 1 and "y" or "ies", spare)
	end

	-- The spares come off the end of the list, so the oldest copy is the one that stays.
	local kept, removed = {}, 0
	for index = #data.Brainrots, 1, -1 do
		local entry = data.Brainrots[index]
		if entry == name and removed < cost then
			removed += 1
		else
			table.insert(kept, entry)
		end
	end
	if removed ~= cost or #kept ~= #data.Brainrots - cost then
		return false, "Couldn't merge that — nothing was changed."
	end
	-- `kept` was filled back to front.
	local reordered = {}
	for index = #kept, 1, -1 do
		table.insert(reordered, kept[index])
	end

	data.Brainrots = reordered
	data.Stars[name] = stars + 1
	StateSync.Push(player)
	return true, string.format("Merged %s to %s!  +%d%% damage and health", name,
		BrainrotData.StarText(stars + 1), math.floor((BrainrotData.StarBonus(stars + 1) - 1) * 100 + 0.5)), stars + 1
end

function RewardService.SellBrainrot(player, name)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local def = BrainrotData.Get(name)
	if not def then
		return false, "No such brainrot."
	end

	local index = table.find(data.Brainrots, name)
	if not index then
		return false, "You don't own that."
	end
	-- Stars would survive the sale, but nothing to equip them on would, and SELL 1 has no
	-- confirmation step. Trading the last copy away is still allowed: that takes two confirms.
	if (data.Stars[name] or 0) > 0 and RewardService.CountOf(data, name) <= 1 then
		return false, string.format("%s is merged (%s) — you can't sell your last copy.", name, BrainrotData.StarText(data.Stars[name]))
	end

	table.remove(data.Brainrots, index)
	-- Selling your last copy of your companion sends it home.
	if data.Companion == name and not table.find(data.Brainrots, name) then
		data.Companion = nil
	end
	local coins = RewardService.AddCoins(player, def.coinValue, "sell")

	StateSync.Push(player)
	return true, string.format("Sold %s for %d SahurCoins.", name, coins)
end

function RewardService.SellAllOfRarity(player, rarity)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	-- One copy of every merged brainrot stays behind, for the same reason SELL 1 won't take it.
	local kept, total, sold, spared = {}, 0, 0, {}
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and def.rarity == rarity and (data.Stars[name] or 0) > 0 and not spared[name] then
			spared[name] = true
			table.insert(kept, name)
		elseif def and def.rarity == rarity then
			total += def.coinValue
			sold += 1
		else
			table.insert(kept, name)
		end
	end

	if sold == 0 then
		return false, "No " .. rarity .. " brainrots to sell" .. (next(spared) and " (merged ones keep their last copy)." or ".")
	end

	data.Brainrots = kept
	if data.Companion and not table.find(kept, data.Companion) then
		data.Companion = nil
	end
	local coins = RewardService.AddCoins(player, total, "sell")

	StateSync.Push(player)
	return true, string.format("Sold %d %s brainrots for %d SahurCoins.%s", sold, rarity, coins,
		next(spared) and " Kept one copy of each merged one." or "")
end

-- Sells every copy beyond the first of each brainrot, so a collector can cash in doubles without
-- touching the collection itself (and never the last copy of a companion or showcase pick).
function RewardService.SellDuplicates(player)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	local seen, kept, total, sold = {}, {}, 0, 0
	for _, name in ipairs(data.Brainrots) do
		local def = BrainrotData.Get(name)
		if def and seen[name] then
			total += def.coinValue
			sold += 1
		else
			seen[name] = true
			table.insert(kept, name)
		end
	end

	if sold == 0 then
		return false, "No duplicates to sell."
	end

	data.Brainrots = kept
	local coins = RewardService.AddCoins(player, total, "sell")
	StateSync.Push(player)
	return true, string.format("Sold %d duplicate%s for %d SahurCoins.", sold, sold == 1 and "" or "s", coins)
end

function RewardService.BuyCosmetic(player, cosmeticId)
	local item = CosmeticData.Get(cosmeticId)
	if not item then
		return false, "No such cosmetic."
	end

	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	if data.Cosmetics.owned[cosmeticId] then
		return false, "You already own that."
	end

	-- Crate exclusives have no price; the menu shows them as unbuyable, and this makes sure.
	if item.crateOnly or not item.price then
		return false, "That one only comes from crates."
	end

	if not ShopRotation.IsCosmeticInStock(cosmeticId) then
		return false, string.format("%s isn't in the shop right now. Stock changes in %s.", item.name, ShopRotation.FormatTimeLeft())
	end

	if data.SahurCoins < item.price then
		return false, string.format("Need %d more SahurCoins.", math.ceil(item.price - data.SahurCoins))
	end

	data.SahurCoins -= item.price
	data.Cosmetics.owned[cosmeticId] = true

	StateSync.Push(player)
	return true, "Unlocked " .. item.name .. "."
end

function RewardService.EquipCosmetic(player, cosmeticId)
	local data = PlayerData.Get(player)
	if not data then
		return false, "Profile still loading."
	end

	-- nil clears every cosmetic slot. (It used to clear only the gun skin, so an equipped aura
	-- could never be removed.)
	if cosmeticId == nil then
		data.Cosmetics.gunSkin = nil
		data.Cosmetics.aura = nil
		data.Cosmetics.accessory = nil
		data.Cosmetics.parachute = nil
		StateSync.Push(player)
		return true, "Cosmetics removed."
	end

	local item = CosmeticData.Get(cosmeticId)
	if not item then
		return false, "No such cosmetic."
	end
	if not data.Cosmetics.owned[cosmeticId] then
		return false, "You don't own that."
	end

	local SLOT_FOR_KIND = { GunSkin = "gunSkin", Aura = "aura", Accessory = "accessory", Parachute = "parachute" }
	local slotKey = SLOT_FOR_KIND[item.kind]
	if not slotKey then
		return false, "That can't be equipped."
	end

	-- Equipping what's already equipped takes it off — the only way back to the default
	-- rarity colours, since the menu used to show a dead "EQUIPPED" button instead.
	if data.Cosmetics[slotKey] == cosmeticId then
		data.Cosmetics[slotKey] = nil
		StateSync.Push(player)
		return true, "Unequipped " .. item.name .. "."
	end

	data.Cosmetics[slotKey] = cosmeticId

	StateSync.Push(player)
	return true, "Equipped " .. item.name .. "."
end

return RewardService
