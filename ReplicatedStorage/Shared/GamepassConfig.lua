-- Every `id = 0` is a placeholder. Anything still at 0 is hidden from the in-game shop, so
-- the game runs fine before you set monetization up.
--
-- GAMEPASS = bought once, owned forever.
-- DEVELOPER PRODUCT = bought repeatedly (single-use boosts, crates, coin packs, brainrots).
--
-- SETTING IT UP (do this once, after the place is published)
-- ------------------------------------------------------------
--  1. Open https://create.roblox.com/dashboard/creations, click this experience, then in the left
--     menu choose Monetization.
--  2. GAMEPASSES: Monetization -> Passes -> Create a Pass. Make one pass for every entry in
--     GamepassConfig.Passes below, using its `name` and `description`, and upload any square image.
--     After creating it, open the pass, choose Sales, switch "Item for Sale" on and set the price to
--     `suggestedPrice`. The pass's ID is the number in its URL: paste it over that entry's `id = 0`.
--       Iron Sahur 50 R$, Rot Runner 50 R$, 2x SahurCoins 350 R$, Brainrot Pass Premium 50 R$,
--       2x Crate Luck 350 R$.
--  3. DEVELOPER PRODUCTS: Monetization -> Developer Products -> Create a Developer Product. Make one
--     product for every entry in GamepassConfig.Products (bundles, boosts, crates, coin packs, and
--     the seven "Brainrot: <Rarity>" products), with its `name`, `description` and `suggestedPrice`.
--     Paste each product's ID over its `id = 0`. The brainrot products' IDs go in the
--     BrainrotProductIds table further down, one per rarity, not in the Products table.
--  4. Game Settings -> Security: switch on "Enable Studio Access to API Services" (purchases and
--     saving both need DataStores), then publish.
--  5. Test from a real client (not Studio's Run): Studio fakes purchases, and receipts are only
--     retried and saved properly in a live server.
--
-- Prices are only suggestions here: whatever you set on the dashboard is what players pay. Keep the
-- dashboard and `suggestedPrice` in step, since the shop cards show `suggestedPrice`.

local GamepassConfig = {}

-- The Daily Spin can hand any pass out for a day (a temporary pass, tracked in the profile), so
-- everyone gets a taste.
GamepassConfig.Passes = {
	ExtraHealth = {
		id = 0,
		name = "Iron Sahur",
		description = "+50 max health in every match, permanently.",
		suggestedPrice = 50,
		order = 1,
	},
	ExtraSpeed = {
		id = 0,
		name = "Rot Runner",
		description = "+4 walkspeed in every match, permanently.",
		suggestedPrice = 50,
		order = 2,
	},
	-- Doubles every coin EARNED by playing, through Monetization.EarnCoins: placements, kills,
	-- bounties, streaks, match events, quests and weekly challenges, achievements, Brainrot Pass coin
	-- rewards, Daily Spin coins, set bonuses, the obby, goals and easter eggs.
	-- Never doubled: coins bought with Robux (coin packs, bundles), crate jackpots and duplicate
	-- refunds (those are part of what a crate says it contains), and, while `doublesSelling` is false,
	-- coins from selling brainrots. Selling stays at face value because with it doubled, buying crates
	-- with coins and selling the pulls turns a profit for an owner of both this and 2x Crate Luck (a
	-- Common Crate returns 794 coins on average for 500). tools/verify.py checks that no crate is
	-- profitable that way, so turning `doublesSelling` on without re-pricing crates fails the build.
	CoinBoost = {
		id = 0,
		name = "2x SahurCoins",
		description = "Doubles every SahurCoin you earn by playing: matches, kills, bounties, quests, achievements, the Brainrot Pass, the Daily Spin and set bonuses.",
		suggestedPrice = 350,
		multiplier = 2,
		doublesSelling = false,
		order = 3,
	},
	-- Every crate you open rolls twice and keeps the rarer result (CrateData.EffectiveOdds). Owners
	-- see the boosted odds on every crate card, because the cards and the roll use the same function.
	CrateLuck = {
		id = 0,
		name = "2x Crate Luck",
		description = "Every crate you open rolls twice and keeps the rarer result. Crate cards show your boosted odds.",
		suggestedPrice = 350,
		luck = 2,
		order = 5,
	},
	BrainrotPassPremium = {
		id = 0,
		name = "Brainrot Pass Premium",
		description = "Unlocks the premium reward track on the Brainrot Pass.",
		-- 450 R$ (Oliver, 2026-09-18). The premium track runs the length of a season, so it's priced
		-- as a season pass rather than as a one-off unlock.
		suggestedPrice = 450,
		order = 4,
	},
}

-- `grant` tells Monetization what to hand over. Kinds: Coins, Crate, Consumable, Bundle.
--
-- A Bundle's `contents` is a list of the other kinds plus Cosmetic (`id` from CosmeticData). A
-- `limit` makes the shop stop offering it once a player has bought it that many times; a player
-- who somehow buys past it still gets everything, since they paid. Bundle exclusives that are
-- already owned turn into `duplicateCoins` instead. `featured` products get a big card at the top
-- of the Robux Shop, in `featured` order, with `badge` and `worth` shown on it.
GamepassConfig.Products = {
	StarterBundle = {
		id = 0,
		name = "Starter Bundle",
		description = "One time only. Everything you need to get your collection going.",
		featured = 1,
		badge = "ONE TIME ONLY",
		worth = "Worth 1,200+ R$  •  4x value",
		limit = 1,
		color = Color3.fromRGB(94, 214, 122),
		suggestedPrice = 300,
		order = 5,
		grant = {
			kind = "Bundle",
			duplicateCoins = 15000,
			contents = {
				{ kind = "Coins", amount = 25000 },
				{ kind = "Crate", crate = "Legendary", amount = 1 },
				{ kind = "Crate", crate = "Epic", amount = 1 },
				{ kind = "Crate", crate = "Rare", amount = 2 },
				-- One-match 1.5x max health (150), twice.
				{ kind = "Consumable", consumable = "Health", amount = 2 },
				{ kind = "Cosmetic", id = "StarterSpark" },
			},
		},
	},
	ProBundle = {
		id = 0,
		name = "Pro Bundle",
		description = "The big one: a Super Crate, 2 Mythic Crates, 2 Legendary Crates, 50K coins, Pro boosts and two Pro exclusives.",
		featured = 2,
		badge = "BEST VALUE",
		worth = "Worth 7,000+ R$  •  8x value",
		color = Color3.fromRGB(255, 184, 48),
		suggestedPrice = 800,
		order = 6,
		grant = {
			kind = "Bundle",
			duplicateCoins = 40000,
			contents = {
				-- Cut on 2026-09-18, with the crate repricing: at the rationalised prices the old contents
				-- (5 Super, 10 Mythic, 150k coins) came to roughly 30,000 R$ of crates for 800 R$, which
				-- isn't a bundle, it's an arbitrage — nobody would buy a crate directly again. This is
				-- still about 7,000 R$ of value for 800.
				{ kind = "Coins", amount = 50000 },
				{ kind = "Crate", crate = "Super", amount = 1 },
				{ kind = "Crate", crate = "Mythic", amount = 2 },
				{ kind = "Crate", crate = "Legendary", amount = 2 },
				-- Pro boosts: one-match 2x max health (200) and 1.5x speed, five of each.
				{ kind = "Consumable", consumable = "HealthPro", amount = 5 },
				{ kind = "Consumable", consumable = "SpeedPro", amount = 5 },
				{ kind = "Cosmetic", id = "ProPlating" },
				{ kind = "Cosmetic", id = "ProAura" },
			},
		},
	},
	BoostHealthOnce = {
		id = 0,
		name = "One-Match Iron Sahur",
		description = "+50 max health for your next match only.",
		grant = { kind = "Consumable", consumable = "Health", amount = 1 },
		suggestedPrice = 35,
		order = 1,
	},
	BoostSpeedOnce = {
		id = 0,
		name = "One-Match Rot Runner",
		description = "+4 walkspeed for your next match only.",
		grant = { kind = "Consumable", consumable = "Speed", amount = 1 },
		suggestedPrice = 35,
		order = 2,
	},
	CrateSuper = {
		id = 0,
		name = "Super Crate",
		description = "The best crate in the game: a Mythic or Secret brainrot every time, plus a 60% chance of a 50K-250K coin jackpot.",
		grant = { kind = "Crate", crate = "Super" },
		featured = 3,
		badge = "ALWAYS IN STOCK",
		worth = "Mythic or Secret, guaranteed",
		color = Color3.fromRGB(255, 90, 200),
		suggestedPrice = 999,
		order = 9,
	},
	CrateCommon = {
		id = 0,
		name = "Common Crate",
		description = "One Common loot crate.",
		grant = { kind = "Crate", crate = "Common" },
		suggestedPrice = 5,
		order = 10,
	},
	CrateUncommon = {
		id = 0,
		name = "Uncommon Crate",
		description = "One Uncommon loot crate.",
		grant = { kind = "Crate", crate = "Uncommon" },
		suggestedPrice = 10,
		order = 11,
	},
	CrateRare = {
		id = 0,
		name = "Rare Crate",
		description = "One Rare loot crate.",
		grant = { kind = "Crate", crate = "Rare" },
		suggestedPrice = 35,
		order = 12,
	},
	CrateEpic = {
		id = 0,
		name = "Epic Crate",
		description = "One Epic loot crate.",
		grant = { kind = "Crate", crate = "Epic" },
		suggestedPrice = 135,
		order = 13,
	},
	CrateMythic = {
		id = 0,
		name = "Mythic Crate",
		description = "One Mythic loot crate: Legendary or better every time, 17% Mythic, 3% Secret.",
		grant = { kind = "Crate", crate = "Mythic" },
		suggestedPrice = 899,
		order = 14,
	},
	CrateLegendary = {
		id = 0,
		name = "Legendary Crate",
		description = "One Legendary loot crate. Best odds you can also buy with coins.",
		grant = { kind = "Crate", crate = "Legendary" },
		suggestedPrice = 499,
		order = 14,
	},

	-- The Style Crate tiers (Oliver, 2026-09-18). Priced off the coin packs: 125 coins per Robux at the
	-- 50k pack, then about 15% better than converting, because a direct purchase should beat laundering
	-- through currency. 8,000 / 25,000 / 60,000 coins -> 69 / 199 / 449 R$.
	--
	-- These are PAID RANDOM ITEMS on both routes, so the card shows the odds that are rolled, exactly,
	-- whichever way the crate was bought. Beginner's Luck never applies: CrateData.BeginnerBoosted only
	-- returns true for a brainrot crate, and widening it to a crate anyone paid for would be deceptive.
	CrateStyle = {
		id = 0,
		name = "Style Crate",
		description = "One Style Crate: any cosmetic — accessory, gun skin, aura or parachute.",
		grant = { kind = "Crate", crate = "Style" },
		suggestedPrice = 69,
		order = 15,
	},
	CrateDeluxeStyle = {
		id = 0,
		name = "Deluxe Style Crate",
		description = "One Deluxe Style Crate: any cosmetic, weighted to the good end.",
		grant = { kind = "Crate", crate = "DeluxeStyle" },
		suggestedPrice = 199,
		order = 16,
	},
	CratePrestigeStyle = {
		id = 0,
		name = "Prestige Style Crate",
		description = "One Prestige Style Crate: no Commons at all, and the best cosmetics in the game.",
		grant = { kind = "Crate", crate = "PrestigeStyle" },
		suggestedPrice = 449,
		order = 17,
	},
	Coins10k = {
		id = 0,
		name = "10,000 SahurCoins",
		description = "Instant coin top-up.",
		grant = { kind = "Coins", amount = 10000 },
		suggestedPrice = 99,
		order = 20,
	},
	Coins50k = {
		id = 0,
		name = "50,000 SahurCoins",
		description = "Instant coin top-up.",
		grant = { kind = "Coins", amount = 50000 },
		suggestedPrice = 399,
		order = 21,
	},
}

-- Buying a brainrot outright. Rather than a product per brainrot (126 of them to create by hand),
-- there's one developer product per rarity, priced here. The player picks the exact brainrot in the
-- menu; the server stores that choice in their profile (PendingBrainrot) and only then opens the
-- purchase prompt, and the receipt grants exactly the stored choice (BrainrotShopService). These
-- products never show up as ordinary shop rows: they're only bought through the brainrot picker.
GamepassConfig.BrainrotPrices = {
	Secret = 2000, Mythic = 1100, Legendary = 600, Epic = 300, Rare = 150, Uncommon = 75, Common = 35,
}
-- Paste each rarity's developer product ID here (step 3 of the setup at the top of this file).
GamepassConfig.BrainrotProductIds = {
	Secret = 0, Mythic = 0, Legendary = 0, Epic = 0, Rare = 0, Uncommon = 0, Common = 0,
}
for rarity, price in pairs(GamepassConfig.BrainrotPrices) do
	GamepassConfig.Products["Brainrot" .. rarity] = {
		id = GamepassConfig.BrainrotProductIds[rarity] or 0,
		name = "Brainrot: " .. rarity,
		description = "One " .. rarity .. " brainrot of your choice, straight into your collection.",
		grant = { kind = "Brainrot", rarity = rarity },
		suggestedPrice = price,
		brainrotShop = true,
		order = 30,
	}
end

-- The product that sells brainrots of `rarity`, or nil.
function GamepassConfig.BrainrotProduct(rarity)
	return GamepassConfig.Products["Brainrot" .. tostring(rarity)]
end

for key, product in pairs(GamepassConfig.Products) do
	product.key = key
end
for key, pass in pairs(GamepassConfig.Passes) do
	pass.key = key
end

-- Products with a big card at the top of the shop, in their `featured` order.
function GamepassConfig.Featured()
	local list = {}
	for _, product in pairs(GamepassConfig.Products) do
		if product.featured then
			table.insert(list, product)
		end
	end
	table.sort(list, function(a, b)
		return a.featured < b.featured
	end)
	return list
end

-- One line per thing in a bundle, for the shop card: "25,000 SahurCoins", "2x Rare Crate".
function GamepassConfig.DescribeContents(grant, cosmeticName)
	local lines = {}
	for _, entry in ipairs(grant.contents or {}) do
		if entry.kind == "Coins" then
			local text = tostring(entry.amount):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
			table.insert(lines, text .. " SahurCoins")
		elseif entry.kind == "Crate" then
			table.insert(lines, string.format("%dx %s Crate", entry.amount or 1, entry.crate))
		elseif entry.kind == "Consumable" then
			local labels = { Health = "1.5x Health Boost", Speed = "Speed Boost", HealthPro = "2x Health Boost (Pro)", SpeedPro = "1.5x Speed Boost (Pro)" }
			table.insert(lines, string.format("%dx %s", entry.amount or 1, labels[entry.consumable] or (entry.consumable .. " Boost")))
		elseif entry.kind == "Cosmetic" then
			table.insert(lines, "EXCLUSIVE " .. (cosmeticName and cosmeticName(entry.id) or entry.id))
		end
	end
	return lines
end

function GamepassConfig.GetProductById(productId)
	for _, product in pairs(GamepassConfig.Products) do
		if product.id == productId then
			return product
		end
	end
	return nil
end

return GamepassConfig
