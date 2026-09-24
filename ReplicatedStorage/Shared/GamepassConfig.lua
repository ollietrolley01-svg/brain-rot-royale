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
--       Iron Sahur 300 R$, Rot Runner 300 R$, 2x SahurCoins 350 R$, Brainrot Pass Premium 450 R$,
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
		id = 1995380456,
		name = "Iron Sahur",
		description = "+50 max health in every match, permanently.",
		-- 300 R$: every permanent pass is at least 300 (Oliver, 2026-09-24).
		suggestedPrice = 300,
		order = 1,
	},
	ExtraSpeed = {
		id = 1994036507,
		name = "Rot Runner",
		description = "+4 walkspeed in every match, permanently.",
		-- 300 R$: every permanent pass is at least 300 (Oliver, 2026-09-24).
		suggestedPrice = 300,
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
		id = 1993988489,
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
		id = 1994690460,
		name = "2x Crate Luck",
		description = "Every crate you open rolls twice and keeps the rarer result. Crate cards show your boosted odds.",
		suggestedPrice = 350,
		luck = 2,
		order = 5,
	},
	BrainrotPassPremium = {
		id = 1994252489,
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
		id = 3714557565,
		name = "Starter Bundle",
		description = "One time only. Everything you need to get your collection going.",
		featured = 1,
		badge = "ONE TIME ONLY",
		-- "Worth" is counted at this shop's own Robux prices (Oliver, 2026-09-22: fix the worth lines):
		-- 25K coins at the 50K pack's rate, Legendary 499, Epic 135, 2 Rare 70, 2 Health boosts 70 =
		-- 974 R$, before the exclusive. Recount it here if a price or the contents change.
		worth = "Worth 950+ R$  •  3x value",
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
		id = 3714557634,
		name = "Pro Bundle",
		description = "The big one: a Super Crate, 2 Mythic Crates, 2 Legendary Crates, 50K coins, Pro boosts and two Pro exclusives.",
		featured = 2,
		badge = "BEST VALUE",
		-- At this shop's own Robux prices: 50K coins 399, Super 100, 2 Mythic 1,798, 2 Legendary 998 =
		-- 3,295 R$, before the Pro boosts and the two exclusives, which aren't sold alone. (It used to
		-- say 7,000+, which only held with the Mythic Crates counted at their coin price.)
		worth = "Worth 3,200+ R$  •  4x value",
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
				-- about 4,200 R$ at the shop's Robux prices for 800 (see `worth`).
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
		id = 3714557823,
		name = "One-Match Iron Sahur",
		description = "+50 max health for your next match only.",
		grant = { kind = "Consumable", consumable = "Health", amount = 1 },
		-- The Iron Sahur pass already gives this much every match, so an owner is never sold one
		-- (GamepassConfig.Outclassed); PlanBoosts would never spend it for them.
		outclassedBy = "ExtraHealth",
		suggestedPrice = 35,
		order = 1,
	},
	BoostSpeedOnce = {
		id = 3714557909,
		name = "One-Match Rot Runner",
		description = "+4 walkspeed for your next match only.",
		grant = { kind = "Consumable", consumable = "Speed", amount = 1 },
		outclassedBy = "ExtraSpeed",
		suggestedPrice = 35,
		order = 2,
	},
	CrateSuper = {
		id = 3714558011,
		name = "Super Crate",
		description = "The best crate in the game: a Mythic or Secret brainrot every time, plus a 60% chance of a 50K-250K coin jackpot.",
		grant = { kind = "Crate", crate = "Super" },
		featured = 3,
		badge = "ALWAYS IN STOCK",
		worth = "Mythic or Secret, guaranteed",
		color = Color3.fromRGB(255, 90, 200),
		-- 100 R$ (Oliver, 2026-09-22 22:22; was 999). Set the same on the Creator Dashboard.
		suggestedPrice = 100,
		order = 9,
	},
	CrateCommon = {
		id = 3714558251,
		name = "Common Crate",
		description = "One Common loot crate.",
		grant = { kind = "Crate", crate = "Common" },
		suggestedPrice = 5,
		order = 10,
	},
	CrateUncommon = {
		id = 3714558357,
		name = "Uncommon Crate",
		description = "One Uncommon loot crate.",
		grant = { kind = "Crate", crate = "Uncommon" },
		suggestedPrice = 10,
		order = 11,
	},
	CrateRare = {
		id = 3714558505,
		name = "Rare Crate",
		description = "One Rare loot crate.",
		grant = { kind = "Crate", crate = "Rare" },
		suggestedPrice = 35,
		order = 12,
	},
	CrateEpic = {
		id = 3714558626,
		name = "Epic Crate",
		description = "One Epic loot crate.",
		grant = { kind = "Crate", crate = "Epic" },
		suggestedPrice = 135,
		order = 13,
	},
	CrateMythic = {
		id = 3714558717,
		name = "Mythic Crate",
		description = "One Mythic loot crate: Legendary or better every time.",
		grant = { kind = "Crate", crate = "Mythic" },
		suggestedPrice = 899,
		order = 14,
	},
	CrateLegendary = {
		id = 3714558898,
		name = "Legendary Crate",
		-- It used to say "Best odds you can also buy with coins", beside a Mythic Crate that is coin-buyable
		-- and better (#86).
		description = "One Legendary loot crate: Epic to Secret, with a shot at a coin jackpot.",
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
		id = 3714558949,
		name = "Style Crate",
		description = "One Style Crate: any cosmetic — accessory, gun skin, aura or parachute.",
		grant = { kind = "Crate", crate = "Style" },
		suggestedPrice = 69,
		order = 15,
	},
	CrateDeluxeStyle = {
		id = 3714558950,
		name = "Deluxe Style Crate",
		description = "One Deluxe Style Crate: any cosmetic, weighted to the good end.",
		grant = { kind = "Crate", crate = "DeluxeStyle" },
		suggestedPrice = 199,
		order = 16,
	},
	CratePrestigeStyle = {
		id = 3714558952,
		name = "Prestige Style Crate",
		description = "One Prestige Style Crate: no Commons at all, and the best cosmetics in the game.",
		grant = { kind = "Crate", crate = "PrestigeStyle" },
		suggestedPrice = 449,
		order = 17,
	},
	Coins10k = {
		id = 3714558954,
		name = "10,000 SahurCoins",
		description = "Instant coin top-up.",
		grant = { kind = "Coins", amount = 10000 },
		suggestedPrice = 99,
		order = 20,
	},
	Coins50k = {
		id = 3714558956,
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
	Secret = 3714558957, Mythic = 3714558959, Legendary = 3714558960, Epic = 3714558963,
	Rare = 3714558966, Uncommon = 3714558969, Common = 3714558974,
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
			-- The multiplier lives in brackets after the name, so a count never sits beside it: "5x 2x
			-- Health Boost (Pro)" read as a typo, and nothing said the boost lasts one match (#86).
			local labels = { Health = "Health Boost (1.5x max HP)", Speed = "Speed Boost", HealthPro = "Pro Health Boost (2x max HP)", SpeedPro = "Pro Speed Boost (1.5x speed)" }
			table.insert(lines, string.format("%d × one-match %s", entry.amount or 1, labels[entry.consumable] or (entry.consumable .. " Boost")))
		elseif entry.kind == "Cosmetic" then
			table.insert(lines, "EXCLUSIVE " .. (cosmeticName and cosmeticName(entry.id) or entry.id))
		end
	end
	return lines
end

-- What one match start grants: the passes' bonuses, and at most one one-match boost per stat, spent
-- only when it BEATS what the player already has. A boost never stacks on a pass (the bigger one
-- applies), so a pass owner still gets the Pro boosts from the Pro Bundle -- 2x health is more than
-- the pass's +50, 1.5x speed more than its +4 -- and keeps a regular boost that would add nothing.
-- Pure, so MatchService.applyBoosts and a check run the same rule.
--   owns       { ExtraHealth = bool, ExtraSpeed = bool }
--   stock      the profile's Consumables counts (nothing is taken off here)
-- Returns { health = bonus max HP, speed = bonus walkspeed, scale = walkspeed factor, spend = { names } }.
GamepassConfig.PassHealth = 50
GamepassConfig.PassSpeed = 4

function GamepassConfig.PlanBoosts(owns, stock, startHealth, baseSpeed)
	stock = stock or {}
	local plan = { health = 0, speed = 0, scale = 1, spend = {} }
	if owns.ExtraHealth then
		plan.health = GamepassConfig.PassHealth
	end
	if owns.ExtraSpeed then
		plan.speed = GamepassConfig.PassSpeed
	end
	-- Health: Pro (2x max health, i.e. +startHealth) first, then the regular +50.
	if (stock.HealthPro or 0) > 0 and startHealth > plan.health then
		plan.health = startHealth
		table.insert(plan.spend, "HealthPro")
	elseif (stock.Health or 0) > 0 and GamepassConfig.PassHealth > plan.health then
		plan.health = GamepassConfig.PassHealth
		table.insert(plan.spend, "Health")
	end
	-- Speed, compared as the walkspeed each would give: Pro is 1.5x base on its own, the regular +4.
	local current = baseSpeed + plan.speed
	if (stock.SpeedPro or 0) > 0 and baseSpeed * 1.5 > current then
		plan.speed, plan.scale = 0, 1.5
		table.insert(plan.spend, "SpeedPro")
	elseif (stock.Speed or 0) > 0 and baseSpeed + GamepassConfig.PassSpeed > current then
		plan.speed = GamepassConfig.PassSpeed
		table.insert(plan.spend, "Speed")
	end
	return plan
end

-- A one-match product that can never beat a pass this player owns for good (`owned` and `temp` are
-- the profile snapshot's ownedPasses and tempPasses). The shop hides it rather than sell something
-- PlanBoosts would never spend. A pass won for a day on the Daily Spin doesn't count: it runs out.
function GamepassConfig.Outclassed(product, owned, temp)
	local pass = product and product.outclassedBy
	return pass ~= nil and owned ~= nil and owned[pass] == true and not (temp and temp[pass])
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
