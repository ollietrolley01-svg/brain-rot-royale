-- Loot crates. Two families:
--
--   Brainrot crates  Common up to Legendary, then Mythic. Every crate rolls only within a window
--                    of four adjacent rarities around its own tier — the tier below it, itself
--                    and the two above (the ends of the ladder clamp) — so a Rare Crate is
--                    Uncommon to Legendary and nothing outside that, and the Legendary Crate is
--                    the first with any shot at Mythic and Secret. Brainrot crates can also pay
--                    out an accessory instead (`accessoryChance`, percent).
--   Item crates      Accessory, Gun Skin and Aura crates roll only that kind of cosmetic, and
--                    only ones you don't own yet. With nothing new left at the rolled rarity
--                    they refund `duplicateRefund` of the price instead, so they're never a waste.
--
-- `jackpot` is a chance of bonus SahurCoins on top of whatever the crate paid out.
-- `pity` is a guarantee: open `every` of that crate without rolling `rarity` or better and the
-- next one is forced to `rarity`. The counter is per player per crate and resets on any roll at
-- or above the guaranteed rarity, so a lucky pull doesn't stack with the guarantee.
-- Legendary and up are deliberately scarce: every crate that can roll them does so at low odds,
-- and the pity guarantees for those tiers are long, so they're a backstop rather than a schedule.
-- `productKey` points at a developer product in GamepassConfig so a crate can be bought with
-- Robux; the newer crates are coins-only. `robuxOnly` crates have no `coinPrice` at all.

local CrateData = {}

CrateData.Order = { "Super", "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic",
	"Style", "DeluxeStyle", "PrestigeStyle", "Accessory", "Skin", "Aura", "Parachute" }

CrateData.Crates = {
	-- The best crate in the game, and the only one sold for Robux alone (no coin price): a Mythic
	-- or Secret brainrot every time, and more often than not a big coin jackpot on top. Always
	-- in stock.
	Super = {
		name = "Super Crate",
		category = "Brainrot",
		productKey = "CrateSuper",
		robuxOnly = true,
		color = Color3.fromRGB(255, 80, 230),
		odds = { Mythic = 90, Secret = 10 },
		jackpot = { chance = 0.6, min = 50000, max = 250000 },
		description = "Mythic or Secret every time, 10% Secret, 60% chance of a 50K-250K jackpot.",
	},
	Common = {
		name = "Common Crate",
		category = "Brainrot",
		coinPrice = 500,
		productKey = "CrateCommon",
		accessoryChance = 6,
		odds = { Common = 62, Uncommon = 26, Rare = 9, Epic = 3 },
		pity = { every = 20, rarity = "Rare" },
		description = "Common to Epic, mostly the everyday kind.",
	},
	Uncommon = {
		name = "Uncommon Crate",
		category = "Brainrot",
		coinPrice = 1500,
		productKey = "CrateUncommon",
		accessoryChance = 8,
		odds = { Common = 30, Uncommon = 40, Rare = 22, Epic = 8 },
		pity = { every = 15, rarity = "Epic" },
		description = "Common to Epic, with real odds of a Rare.",
	},
	Rare = {
		name = "Rare Crate",
		category = "Brainrot",
		coinPrice = 5000,
		productKey = "CrateRare",
		accessoryChance = 10,
		odds = { Uncommon = 24, Rare = 45, Epic = 28, Legendary = 3 },
		pity = { every = 12, rarity = "Epic" },
		description = "Uncommon to Legendary, with a slim 3% shot at a Legendary.",
	},
	Epic = {
		name = "Epic Crate",
		category = "Brainrot",
		coinPrice = 20000,
		productKey = "CrateEpic",
		accessoryChance = 14,
		odds = { Rare = 32, Epic = 54, Legendary = 12, Mythic = 2 },
		pity = { every = 25, rarity = "Legendary" },
		description = "Rare to Mythic. Nothing below a Rare, and a Legendary about one time in eight.",
	},
	Legendary = {
		name = "Legendary Crate",
		category = "Brainrot",
		coinPrice = 75000,
		productKey = "CrateLegendary",
		accessoryChance = 18,
		odds = { Epic = 58, Legendary = 34, Mythic = 7, Secret = 1 },
		jackpot = { chance = 0.25, min = 5000, max = 25000 },
		pity = { every = 40, rarity = "Mythic" },
		description = "Epic to Secret: a third Legendary, a small shot at Mythic, and a 25% coin jackpot.",
	},
	Mythic = {
		name = "Mythic Crate",
		category = "Brainrot",
		coinPrice = 250000,
		odds = { Legendary = 80, Mythic = 17, Secret = 3 },
		jackpot = { chance = 0.4, min = 20000, max = 100000 },
		pity = { every = 50, rarity = "Secret" },
		description = "Legendary or better, every time. 17% Mythic, 3% Secret.",
	},
	-- The STYLE CRATES: cosmetic crates in tiers, drawing from every cosmetic kind at once rather than
	-- one slot each (Oliver, 2026-09-18: "varying tiers of these crates"). Tiers rather than more
	-- kind-crates because the pools are small — 13 accessories, 15 auras, 22 gun skins, 15 parachutes —
	-- so a tier that only dropped Legendary accessories would exhaust after two opens and refund
	-- forever. `kinds` is what a tier can draw from; the rarity is rolled first, then an unowned
	-- cosmetic of that rarity from any of them.
	--
	-- All three are sold for coins AND for Robux, which makes them paid random items: the odds on the
	-- card are the odds rolled, always, on both routes. Beginner's Luck can never touch them —
	-- CrateData.BeginnerBoosted only ever returns true for a brainrot crate, and that must not be
	-- widened to these.
	Style = {
		name = "Style Crate",
		category = "Cosmetic",
		kinds = { "Accessory", "GunSkin", "Aura", "Parachute" },
		coinPrice = 8000,
		productKey = "CrateStyle",
		color = Color3.fromRGB(120, 200, 255),
		duplicateRefund = 0.35,
		odds = { Common = 42, Uncommon = 30, Rare = 18, Epic = 7, Legendary = 2.5, Mythic = 0.4, Secret = 0.1 },
		description = "Any cosmetic: an accessory, a gun skin, an aura or a parachute.",
	},

	DeluxeStyle = {
		name = "Deluxe Style Crate",
		category = "Cosmetic",
		kinds = { "Accessory", "GunSkin", "Aura", "Parachute" },
		coinPrice = 25000,
		productKey = "CrateDeluxeStyle",
		color = Color3.fromRGB(180, 140, 255),
		duplicateRefund = 0.4,
		odds = { Common = 20, Uncommon = 28, Rare = 27, Epic = 16, Legendary = 7, Mythic = 1.6, Secret = 0.4 },
		pity = { every = 10, rarity = "Epic" },
		description = "Any cosmetic, weighted to the good end.",
	},

	PrestigeStyle = {
		name = "Prestige Style Crate",
		category = "Cosmetic",
		kinds = { "Accessory", "GunSkin", "Aura", "Parachute" },
		coinPrice = 60000,
		productKey = "CratePrestigeStyle",
		color = Color3.fromRGB(255, 190, 90),
		duplicateRefund = 0.45,
		odds = { Uncommon = 18, Rare = 30, Epic = 28, Legendary = 17, Mythic = 5, Secret = 2 },
		pity = { every = 8, rarity = "Legendary" },
		description = "No Commons at all. The best cosmetics in the game are in here.",
	},

	Accessory = {
		name = "Accessory Crate",
		category = "Accessory",
		coinPrice = 10000,
		color = Color3.fromRGB(255, 120, 190),
		duplicateRefund = 0.35,
		odds = { Common = 40, Uncommon = 30, Rare = 18, Epic = 9, Legendary = 3 },
		description = "Accessories only, never one you already own.",
	},
	Skin = {
		name = "Gun Skin Crate",
		category = "GunSkin",
		coinPrice = 7500,
		color = Color3.fromRGB(120, 200, 255),
		duplicateRefund = 0.35,
		odds = { Common = 35, Uncommon = 30, Rare = 20, Epic = 10, Legendary = 4, Mythic = 0.8, Secret = 0.2 },
		description = "Gun skins only, including crate-exclusive Legendary, Mythic and Secret skins.",
	},
	Aura = {
		name = "Aura Crate",
		category = "Aura",
		coinPrice = 20000,
		color = Color3.fromRGB(190, 120, 255),
		duplicateRefund = 0.35,
		odds = { Common = 25, Uncommon = 28, Rare = 25, Epic = 14, Legendary = 6, Mythic = 1.6, Secret = 0.4 },
		description = "Auras only, including crate-exclusive Legendary, Mythic and Secret auras.",
	},
	-- Canopies for the drop-in and the Rot Glider (CosmeticData kind "Parachute", designed by
	-- ParachuteModels). Like the other item crates it only gives one you don't own yet, drawing from
	-- every parachute of the rolled rarity, shop ones included, and refunds when there's none left.
	Parachute = {
		name = "Parachute Crate",
		category = "Parachute",
		coinPrice = 15000,
		color = Color3.fromRGB(255, 146, 54),
		duplicateRefund = 0.35,
		odds = { Common = 25, Uncommon = 28, Rare = 25, Epic = 14, Legendary = 6, Mythic = 1.6, Secret = 0.4 },
		description = "Parachutes only, never one you already own.",
	},
}

function CrateData.Get(tier)
	return CrateData.Crates[tier]
end

-- Crate luck. Luck L means the crate is rolled L times and the rarest result is kept, the way
-- "2x luck" works in most games. Rather than literally rolling L times, the odds are transformed
-- exactly: the chance of rarity r OR BETTER becomes 1 - (1 - p)^L, where p is that chance at base
-- odds. So nothing can exceed 100%, a crate can still only roll the rarities it lists, and the rare
-- end gains the most (1% becomes 1.99% at 2x). Pity is separate and unchanged: its counter reads
-- whatever this roll produced.
--
-- The roll (CrateService.Open) and every place odds are shown (the crate cards) call this same
-- function with the same luck, so the odds a player sees are exactly the odds they get. Returns
-- rarity -> percent, summing to 100.
local Rarity = require(script.Parent:WaitForChild("Rarity"))

CrateData.MaxLuck = 8

-- Beginner's Luck: a brand new profile's first few FREE brainrot crates roll at this much luck, on
-- top of any pass. Only crates the game hands out, never one bought with Robux or coins: a crate
-- someone paid for always rolls the odds its card shows. Nothing in the UI names this; the cards for
-- a boosted crate show which rarities can drop and no percentages, so no number on screen is ever a
-- number the roll didn't use.
CrateData.BeginnerLuck = 4
CrateData.BeginnerCrates = 4

-- Beginner's Luck charges left on a profile (pass it data.Progression). Missing on saves from before
-- the feature, which reads as none.
function CrateData.BeginnerLeft(progression)
	local beginner = progression and progression.beginnerLuck
	local left = beginner and tonumber(beginner.left) or 0
	if left ~= left then
		return 0
	end
	return math.max(0, math.floor(left))
end

-- Whether the next crate of this tier out of a player's inventory rolls with Beginner's Luck.
--
-- It takes the whole holding, not just the next crate, on purpose: a boosted card shows no
-- percentages, and a card with no percentages must never be one you can BUY a crate on. Crates
-- bought with coins count as paid (coins are bought with Robux), so the boost applies only when
-- every crate of that tier is one the game handed out. Buying one — with Robux or coins — puts
-- percentages straight back and opens ahead of the free ones.
-- CrateService.Open asks this before it spends anything and StateSync asks it for the menu, so the
-- card and the roll always agree.
function CrateData.BeginnerBoosted(crate, heldCount, paidCount, freeCount, beginnerLeft)
	if not crate or (crate.category ~= nil and crate.category ~= "Brainrot") then
		return false
	end
	local held, paid, free = heldCount or 0, paidCount or 0, freeCount or 0
	local bought = paid + math.max(0, held - paid - free) -- Robux crates plus coin-bought ones
	return bought <= 0 and free > 0 and (beginnerLeft or 0) > 0
end

-- The luck one open rolls with, from the player's pass luck and whether this particular crate is a
-- boosted free one. The server rolls with this and the menu draws its odds with it, so shown and
-- rolled can't drift apart.
function CrateData.LuckFor(crate, passLuck, beginnerBoosted)
	local luck = math.max(1, tonumber(passLuck) or 1)
	if beginnerBoosted and (crate.category == nil or crate.category == "Brainrot") then
		luck *= CrateData.BeginnerLuck
	end
	return math.clamp(math.floor(luck), 1, CrateData.MaxLuck)
end

-- The odds line on a crate card, as the pieces the menu joins with spaces. `boosted` is a crate
-- rolling with Beginner's Luck: those list which rarities can drop and NO percentages, because the
-- percentages for the luck they actually roll with aren't the ones a player could be told. Kept here
-- rather than in MenuClient so tools/crate_card_gallery.lua renders the real thing.
function CrateData.OddsLine(crate, luck, boosted)
	local effective = CrateData.EffectiveOdds(crate, luck)
	local parts = {}
	if luck > 1 and not boosted then
		table.insert(parts, string.format("%dx LUCK:", luck))
	end
	for _, rarity in ipairs(Rarity.Order) do
		local chance = effective[rarity]
		if chance and chance > 0 then
			-- Fractions of a percent (Secret odds) need the extra digit to not read as 0.
			table.insert(parts, boosted and rarity:sub(1, 4)
				or string.format(chance < 1 and "%s %.2f%%" or "%s %.1f%%", rarity:sub(1, 4), chance))
		end
	end
	if crate.accessoryChance and crate.accessoryChance > 0 then
		table.insert(parts, string.format("+ %d%% accessory", crate.accessoryChance))
	end
	return parts
end

function CrateData.EffectiveOdds(crate, luck)
	luck = math.clamp(math.floor(tonumber(luck) or 1), 1, CrateData.MaxLuck)
	local total = 0
	for _, weight in pairs(crate.odds) do
		total += weight
	end
	local result = {}
	if total <= 0 then
		return result
	end
	-- From the rarest down: `atLeast` is the base chance of this rarity or better, and each rarity's
	-- share is the step between its boosted cumulative chance and the one above it. The last step
	-- ends at exactly 1, so the shares always add up to 100.
	local atLeast, boostedAbove = 0, 0
	for index = #Rarity.Order, 1, -1 do
		local rarity = Rarity.Order[index]
		local weight = crate.odds[rarity]
		if weight and weight > 0 then
			atLeast = math.min(1, atLeast + weight / total)
			local boosted = 1 - (1 - atLeast) ^ luck
			result[rarity] = (boosted - boostedAbove) * 100
			boostedAbove = boosted
		end
	end
	return result
end

return CrateData
