-- Meta-progression that outlasts the Brainrot Pass: Rot Rank and Prestige, Brain Cells, weapon
-- mastery, the Rot Index and the Cell Shop. Pure data and maths, required by the server
-- (ProgressionService), by StateSync for the menu snapshot and by the Rank tab
-- (ProgressionPanel), so every side works a number out the same way.
--
--   Rot Rank     an account level, 1 to MaxRank, fed by every point of Brainrot Pass XP (the pass
--                itself is untouched) plus mastery bonuses. Reaching MaxRank lets you PRESTIGE:
--                rank goes back to 1 and every rank reward pays again, a little bigger. XP earned
--                while sitting at MaxRank isn't wasted — every OverflowXp of it pays Cells.
--   Brain Cells  the currency progression pays in. They can't be bought with Robux and no gamepass
--                multiplies them. Spent in the Cell Shop.
--   Mastery      per gun. Credited eliminations earn points (a real player is worth more than a
--                bot) and every tier pays Cells and Rot Rank XP.
--   Rot Index    a lifetime log of every brainrot you have ever owned. Selling or trading a copy
--                never takes an entry back. Each discovery is claimed once for Cells, and a whole
--                rarity page claimed pays a page bonus on top. A brainrot first found by buying it
--                with Robux is logged as Purchased: it shows, but pays nothing until it turns up
--                in play (a crate pull or a Cell Shop buy), so buying one with Robux pays no Cells.
--   Cell Shop    a daily rotation, the same on every server: one brainrot each of Common to Epic
--                and a Companion Snack. Never Legendary or better, and never crates, so the
--                scarcity CrateData and ShopRotation keep isn't touched (tools/verify.py checks).
--
-- Save data lives on the profile as `Progression` (see Default). Reconcile only ever keeps clean,
-- bounded values: counters are whole, finite and non-negative, and every map is capped.

local BrainrotData = require(script.Parent:WaitForChild("BrainrotData"))
local Rarity = require(script.Parent:WaitForChild("Rarity"))
-- WeaponData is required lazily (MasteryWeapons): PlayerData requires this module, and a profile
-- must still load if a gun file is mid-edit and fails.

local ProgressionData = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- Bumped when a profile's Progression has been backfilled from what the profile already held
-- (ProgressionService.Migrate). 0 means "not yet".
ProgressionData.Version = 1

--------------------------------------------------------------------------------
-- Rot Rank and Prestige
--------------------------------------------------------------------------------

ProgressionData.MaxRank = 100
ProgressionData.MaxPrestige = 10

-- XP to go from `rank` to the next one. Rank 2 is about one match; the climb steepens to a flat 2,000
-- near the top, so a late rank still costs twelve times an early one. Halved on 2026-09-17 (Oliver:
-- the ladder was too long) — one prestige went from 31 to 16 hours for a strong player, 74 to 38 for a
-- casual one. The shape was kept rather than flattened: a ladder whose rungs all cost the same is a
-- worse ladder. tools/progression_model.py prints the current hours.
function ProgressionData.XpToNext(rank)
	return math.min(150 + 20 * rank, 2000)
end

local rankStart = { [1] = 0 }
for rank = 2, ProgressionData.MaxRank do
	rankStart[rank] = rankStart[rank - 1] + ProgressionData.XpToNext(rank - 1)
end

-- XP from rank 1 to MaxRank: one prestige's worth.
ProgressionData.PrestigeXp = rankStart[ProgressionData.MaxRank]

-- Past MaxRank, every OverflowXp pays OverflowCells (times the prestige multiplier).
ProgressionData.OverflowXp = 25000
ProgressionData.OverflowCells = 500

function ProgressionData.RankStart(rank)
	return rankStart[math.clamp(math.floor(rank), 1, ProgressionData.MaxRank)]
end

function ProgressionData.RankForXp(xp)
	xp = xp or 0
	local low, high = 1, ProgressionData.MaxRank
	while low < high do
		local mid = (low + high + 1) // 2
		if rankStart[mid] <= xp then
			low = mid
		else
			high = mid - 1
		end
	end
	return low
end

-- Rank, XP into it, and the XP it needs (nil at MaxRank).
function ProgressionData.RankProgress(xp)
	local rank = ProgressionData.RankForXp(xp)
	if rank >= ProgressionData.MaxRank then
		return rank, 0, nil
	end
	return rank, (xp or 0) - rankStart[rank], ProgressionData.XpToNext(rank)
end

-- Each prestige makes rank Cells worth 10% more. Cells only: never coins, never crates.
ProgressionData.PrestigeCellBonus = 0.10

function ProgressionData.PrestigeMultiplier(prestige)
	return 1 + ProgressionData.PrestigeCellBonus * math.clamp(prestige or 0, 0, ProgressionData.MaxPrestige)
end

-- A crate on a handful of milestone ranks. Kept sparse and below Legendary on purpose: a whole
-- prestige is five crates next to the hundreds that placements pay over the same hours.
ProgressionData.RankCrates = { [20] = "Rare", [40] = "Rare", [60] = "Rare", [80] = "Rare", [100] = "Epic" }

-- What reaching `rank` pays, at a given prestige. Trimmed alongside the halved curve so twice as many
-- rank-ups don't double Cell income: it lands about 20% above the old rate (263/h for a strong player
-- against 217), which keeps the Cell Shop's 40,000-Cell cosmetics a long-term goal.
function ProgressionData.RankReward(rank, prestige)
	local cells = 14 + 1 * (rank // 5)
	if rank % 25 == 0 then
		cells += 250
	elseif rank % 10 == 0 then
		cells += 100
	end
	return {
		cells = math.floor(cells * ProgressionData.PrestigeMultiplier(prestige) + 0.5),
		crate = ProgressionData.RankCrates[rank],
	}
end

function ProgressionData.OverflowReward(prestige)
	return math.floor(ProgressionData.OverflowCells * ProgressionData.PrestigeMultiplier(prestige) + 0.5)
end

-- Paid on the moment of prestiging into `prestige`.
function ProgressionData.PrestigeReward(prestige)
	return { cells = 1000 * prestige }
end

-- Emblem colour and name per prestige, 0 (none yet) to MaxPrestige.
ProgressionData.Prestiges = {
	[0] = { name = "Fresh", color = rgb(146, 152, 170) },
	{ name = "Bronze Rot", color = rgb(205, 127, 50) },
	{ name = "Silver Rot", color = rgb(200, 206, 216) },
	{ name = "Golden Rot", color = rgb(255, 196, 64) },
	{ name = "Jade Rot", color = rgb(80, 220, 140) },
	{ name = "Sapphire Rot", color = rgb(74, 156, 255) },
	{ name = "Amethyst Rot", color = rgb(186, 104, 255) },
	{ name = "Ruby Rot", color = rgb(236, 64, 96) },
	{ name = "Neon Rot", color = rgb(255, 90, 200) },
	{ name = "Diamond Rot", color = rgb(150, 236, 255) },
	{ name = "Eternal Rot", color = rgb(255, 245, 190) },
}

function ProgressionData.PrestigeInfo(prestige)
	return ProgressionData.Prestiges[math.clamp(prestige or 0, 0, ProgressionData.MaxPrestige)]
end

-- Numbers in sentences: whole, comma-grouped ("24,000"). The compact form ("24.0K", UiKit.formatNumber)
-- is only for chips, tiles and buttons with no room. `Cells(n)` also gets the plural right.
function ProgressionData.Commas(n)
	local text = tostring(math.floor(math.abs(n or 0)))
	local grouped = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if grouped:sub(1, 1) == "," then
		grouped = grouped:sub(2)
	end
	return ((n or 0) < 0 and "-" or "") .. grouped
end

function ProgressionData.Cells(n)
	return ProgressionData.Commas(n) .. (math.floor(math.abs(n or 0)) == 1 and " Brain Cell" or " Brain Cells")
end

-- One number that only ever goes up: 147 is prestige 1, rank 47. Titles hang off it.
function ProgressionData.RankScore(prestige, rank)
	return (prestige or 0) * ProgressionData.MaxRank + (rank or 1)
end

--------------------------------------------------------------------------------
-- Weapon mastery
--------------------------------------------------------------------------------

ProgressionData.KillPoints = { bot = 1, player = 3 }

ProgressionData.MasteryTiers = {
	{ name = "Bronze", points = 10, cells = 20, xp = 150, color = rgb(205, 127, 50) },
	{ name = "Silver", points = 30, cells = 40, xp = 300, color = rgb(200, 206, 216) },
	{ name = "Gold", points = 75, cells = 80, xp = 600, color = rgb(255, 196, 64) },
	{ name = "Platinum", points = 150, cells = 150, xp = 1000, color = rgb(120, 230, 210) },
	{ name = "Diamond", points = 300, cells = 250, xp = 1500, color = rgb(120, 200, 255) },
	{ name = "Rotmaster", points = 600, cells = 400, xp = 2500, color = rgb(255, 90, 200) },
}

-- Reaching this tier counts toward the "mastered" titles.
ProgressionData.MasteredTier = 3
ProgressionData.MasteryPointCap = 1000000

function ProgressionData.MasteryTier(points)
	local tier = 0
	for index, info in ipairs(ProgressionData.MasteryTiers) do
		if (points or 0) >= info.points then
			tier = index
		else
			break
		end
	end
	return tier
end

-- Every gun in WeaponData (packs merged into it included, so new guns count with no list to keep),
-- commonest first and then by name, for the Mastery page. Built on first use.
local masteryWeapons = nil

-- `staged` guns (a pack's guns that aren't in loot yet) are left out, so the page never shows a goal
-- nobody can reach; the list grows on its own the day the flag comes off, with no migration. Pass a
-- mastery map to also include any staged gun that already has points, so earned progress is never
-- hidden — for instance if a gun is staged again after going live.
function ProgressionData.MasteryWeapons(mastery)
	local WeaponData = require(script.Parent:WaitForChild("WeaponData"))
	local function order(a, b)
		local ra = Rarity.Index[WeaponData.Weapons[a].rarity] or 0
		local rb = Rarity.Index[WeaponData.Weapons[b].rarity] or 0
		if ra ~= rb then
			return ra < rb
		end
		return WeaponData.Weapons[a].name < WeaponData.Weapons[b].name
	end

	if not masteryWeapons then
		local list = {}
		for id, def in pairs(WeaponData.Weapons) do
			if not def.staged then
				table.insert(list, id)
			end
		end
		table.sort(list, order)
		masteryWeapons = list
	end

	if not mastery then
		return masteryWeapons
	end

	local extra = {}
	for id, points in pairs(mastery) do
		if WeaponData.Weapons[id] and WeaponData.Weapons[id].staged and (points or 0) > 0 then
			table.insert(extra, id)
		end
	end
	if #extra == 0 then
		return masteryWeapons
	end
	table.sort(extra, order)
	local combined = table.clone(masteryWeapons)
	for _, id in ipairs(extra) do
		table.insert(combined, id)
	end
	return combined
end

--------------------------------------------------------------------------------
-- Rot Index
--------------------------------------------------------------------------------

-- Index states. Recorded: found in play, Cells waiting to be claimed. Claimed: paid. Purchased: first
-- found by buying it with Robux, so it pays nothing and counts toward no page bonus until the same
-- brainrot comes out of a crate or the Cell Shop (ProgressionService.RecordIndex's `earnedName`).
ProgressionData.Recorded = 1
ProgressionData.Claimed = 2
ProgressionData.Purchased = 3

ProgressionData.DiscoverCells = {
	Common = 10, Uncommon = 20, Rare = 40, Epic = 100, Legendary = 250, Mythic = 600, Secret = 1500,
}

-- Paid once, when the last brainrot of a rarity is claimed.
ProgressionData.PageBonus = {
	Common = 250, Uncommon = 500, Rare = 1000, Epic = 2500, Legendary = 5000, Mythic = 8000, Secret = 15000,
}

--------------------------------------------------------------------------------
-- Cell Shop
--------------------------------------------------------------------------------

-- Nothing at or above this rarity is ever offered (tools/verify.py holds it there).
ProgressionData.ShopRarityCeiling = "Legendary"

ProgressionData.ShopSlots = {
	{ id = "common", kind = "Brainrot", rarity = "Common", price = 60, limit = 1 },
	{ id = "uncommon", kind = "Brainrot", rarity = "Uncommon", price = 150, limit = 1 },
	{ id = "rare", kind = "Brainrot", rarity = "Rare", price = 450, limit = 1 },
	{ id = "epic", kind = "Brainrot", rarity = "Epic", price = 1500, limit = 1 },
	{ id = "snack", kind = "Snack", xp = 400, price = 350, limit = 2 },
}

function ProgressionData.Day(now)
	return math.floor((now or os.time()) / 86400)
end

local cachedShopDay, cachedOffers = nil, nil

-- The day's offers: each slot with, for brainrot slots, the brainrot picked for it. Drawn with a
-- Random seeded from the day, so every server and every client agrees without asking.
function ProgressionData.ShopOffers(day)
	if cachedShopDay == day then
		return cachedOffers
	end
	local random = Random.new(day * 7331 + 17)
	local offers = {}
	for _, slot in ipairs(ProgressionData.ShopSlots) do
		local offer = table.clone(slot)
		if slot.kind == "Brainrot" then
			local pool = BrainrotData.OfRarity(slot.rarity)
			offer.brainrot = #pool > 0 and pool[random:NextInteger(1, #pool)].name or nil
		end
		table.insert(offers, offer)
	end
	cachedShopDay, cachedOffers = day, offers
	return offers
end

function ProgressionData.FindOffer(day, offerId)
	for _, offer in ipairs(ProgressionData.ShopOffers(day)) do
		if offer.id == offerId then
			return offer
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Rank-reward cosmetics
--------------------------------------------------------------------------------

-- The `rankOnly` cosmetics in CosmeticData and what earns each. Exactly one condition per entry:
--   prestige     reaching that prestige
--   mastered     Gold mastery or better on that many different guns
--   masteryTier  any one gun at that tier or better
--   cells        a permanent Cell Shop listing at that many Brain Cells (`offer` is its offer id)
-- tools/verify.py checks every entry is a rankOnly cosmetic and every rankOnly cosmetic is here.
ProgressionData.RankCosmetics = {
	{ id = "PrestigeBronzeSkin", prestige = 1 },
	{ id = "PrestigeSilverAura", prestige = 2 },
	{ id = "PrestigeGoldenSkin", prestige = 3 },
	{ id = "PrestigeJadeAura", prestige = 4 },
	{ id = "PrestigeSapphireSkin", prestige = 5 },
	{ id = "PrestigeAmethystAura", prestige = 6 },
	{ id = "PrestigeRubySkin", prestige = 7 },
	{ id = "PrestigeNeonAura", prestige = 8 },
	{ id = "PrestigeDiamondSkin", prestige = 9 },
	{ id = "PrestigeEternalAura", prestige = 10 },
	{ id = "MasteryMastercraftSkin", mastered = 5 },
	{ id = "MasteryDiamondCutSkin", masteryTier = 5 },
	{ id = "MasteryRotmasterSkin", masteryTier = 6 },
	{ id = "CellBrainAura", cells = 15000, offer = "brainAura" },
	{ id = "CellSynapseSkin", cells = 25000, offer = "synapseSkin" },
}

-- Guns at Gold or better, and the best tier on any gun, from a mastery map.
function ProgressionData.MasterySummary(mastery)
	local mastered, best = 0, 0
	for _, points in pairs(mastery or {}) do
		local tier = ProgressionData.MasteryTier(points)
		if tier >= ProgressionData.MasteredTier then
			mastered += 1
		end
		best = math.max(best, tier)
	end
	return mastered, best
end

-- Whether a rank cosmetic's condition is met (Cell Shop ones are bought, so never "earned").
function ProgressionData.CosmeticEarned(entry, progression)
	if entry.prestige then
		return (progression.prestige or 0) >= entry.prestige
	end
	local mastered, best = ProgressionData.MasterySummary(progression.mastery)
	if entry.mastered then
		return mastered >= entry.mastered
	elseif entry.masteryTier then
		return best >= entry.masteryTier
	end
	return false
end

-- How an entry is earned, in words, for the menu.
function ProgressionData.CosmeticRequirement(entry)
	if entry.prestige then
		return "Prestige " .. entry.prestige
	elseif entry.mastered then
		return string.format("Gold mastery on %d guns", entry.mastered)
	elseif entry.masteryTier then
		return string.format("%s mastery on any gun", ProgressionData.MasteryTiers[entry.masteryTier].name)
	elseif entry.cells then
		return ProgressionData.Cells(entry.cells) .. " in the Cell Shop"
	end
	return "?"
end

function ProgressionData.FindCosmeticOffer(offerId)
	for _, entry in ipairs(ProgressionData.RankCosmetics) do
		if entry.offer and entry.offer == offerId then
			return entry
		end
	end
	return nil
end

function ProgressionData.PrestigeCosmetic(prestige)
	for _, entry in ipairs(ProgressionData.RankCosmetics) do
		if entry.prestige == prestige then
			return entry
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Save data
--------------------------------------------------------------------------------

local MAX_MASTERY_KEYS = 128
local MAX_INDEX_KEYS = 512
local MAX_SHOP_KEYS = 16
local MAX_COUNTER = 1e15

function ProgressionData.Default()
	return {
		v = 0,
		-- XP into the current prestige (0 to PrestigeXp), lifetime XP, and XP banked past MaxRank.
		xp = 0,
		total = 0,
		over = 0,
		prestige = 0,
		cells = 0,
		cellsEarned = 0,
		-- Weapon id -> mastery points.
		mastery = {},
		-- Brainrot name -> Recorded or Claimed.
		index = {},
		-- Rarity -> true once its page bonus has been paid.
		pages = {},
		-- The highest rank this profile has already been PAID for. Rewards are handed out when a rank is
		-- crossed, so without this a cheaper curve would silently skip the ranks a player's stored XP now
		-- reaches, and a dearer one could pay the same ranks twice. Set from the player's rank the first
		-- time it's seen (no windfall), reset to 1 on prestige.
		paidRank = 0,
		-- The Cell Shop day these purchases belong to, and offer id -> times bought that day.
		shop = { day = 0, bought = {} },
		-- Beginner's Luck charges (CrateData): how many are left, and whether this profile has ever been
		-- given them. `granted` is the marker the grant keys off, so charges can't be handed out twice;
		-- an absent field reads as no charges, which is why this module only stores and clamps.
		beginnerLuck = { left = 0, granted = false },
	}
end

local function whole(value, max)
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(math.floor(value), 0, max or MAX_COUNTER)
end

local function cleanKey(key, maxLength)
	return type(key) == "string" and #key > 0 and #key <= maxLength
end

function ProgressionData.Reconcile(saved)
	local clean = ProgressionData.Default()
	if type(saved) ~= "table" then
		return clean
	end

	clean.v = whole(saved.v, ProgressionData.Version)
	clean.xp = whole(saved.xp, ProgressionData.PrestigeXp)
	clean.total = whole(saved.total)
	clean.over = whole(saved.over, ProgressionData.OverflowXp)
	clean.prestige = whole(saved.prestige, ProgressionData.MaxPrestige)
	clean.paidRank = whole(saved.paidRank, ProgressionData.MaxRank)
	clean.cells = whole(saved.cells)
	clean.cellsEarned = whole(saved.cellsEarned)

	if type(saved.mastery) == "table" then
		local count = 0
		for id, points in pairs(saved.mastery) do
			if cleanKey(id, 64) and type(points) == "number" and count < MAX_MASTERY_KEYS then
				local value = whole(points, ProgressionData.MasteryPointCap)
				if value > 0 then
					clean.mastery[id] = value
					count += 1
				end
			end
		end
	end

	if type(saved.index) == "table" then
		local count = 0
		for name, state in pairs(saved.index) do
			if cleanKey(name, 64)
				and (state == ProgressionData.Recorded or state == ProgressionData.Claimed or state == ProgressionData.Purchased)
				and count < MAX_INDEX_KEYS then
				clean.index[name] = state
				count += 1
			end
		end
	end

	if type(saved.pages) == "table" then
		for _, rarity in ipairs(Rarity.Order) do
			if saved.pages[rarity] == true then
				clean.pages[rarity] = true
			end
		end
	end

	if type(saved.beginnerLuck) == "table" then
		local CrateData = require(script.Parent:WaitForChild("CrateData"))
		clean.beginnerLuck.left = whole(saved.beginnerLuck.left, CrateData.BeginnerCrates or 0)
		clean.beginnerLuck.granted = saved.beginnerLuck.granted == true
	end

	if type(saved.shop) == "table" then
		clean.shop.day = whole(saved.shop.day)
		if type(saved.shop.bought) == "table" then
			local count = 0
			for id, times in pairs(saved.shop.bought) do
				if cleanKey(id, 16) and type(times) == "number" and count < MAX_SHOP_KEYS then
					local value = whole(times, 99)
					if value > 0 then
						clean.shop.bought[id] = value
						count += 1
					end
				end
			end
		end
	end

	return clean
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

-- Discoveries per rarity from an index map: { [rarity] = { found, claimed, total } }.
function ProgressionData.IndexCounts(index)
	local counts = {}
	for _, rarity in ipairs(Rarity.Order) do
		counts[rarity] = { found = 0, claimed = 0, total = #BrainrotData.OfRarity(rarity) }
	end
	for name, state in pairs(index) do
		local def = BrainrotData.Get(name)
		local entry = def and counts[def.rarity]
		if entry then
			entry.found += 1
			if state == ProgressionData.Claimed then
				entry.claimed += 1
			end
		end
	end
	return counts
end

-- What the Rank tab draws. `data` is the whole profile; returns nil for a profile without
-- Progression. Maps are sent as they are (weapon id -> points, name -> state) and the panel works
-- tiers and counts out with the functions above, so a push stays small.
function ProgressionData.Snapshot(data, now)
	local progression = data and data.Progression
	if type(progression) ~= "table" then
		return nil
	end
	now = now or os.time()

	local rank, into, need = ProgressionData.RankProgress(progression.xp)

	-- Anything owned right now counts as found even before the server has written it down.
	local index = {}
	for name, state in pairs(progression.index) do
		if BrainrotData.Get(name) then
			index[name] = state
		end
	end
	for _, name in ipairs(data.Brainrots or {}) do
		if not index[name] and BrainrotData.Get(name) then
			index[name] = ProgressionData.Recorded
		end
	end

	local day = ProgressionData.Day(now)
	local shop = progression.shop
	local companion = data.Companion

	return {
		rank = rank,
		prestige = progression.prestige,
		xpInto = into,
		xpNeed = need,
		total = progression.total,
		over = progression.over,
		cells = progression.cells,
		cellsEarned = progression.cellsEarned,
		canPrestige = rank >= ProgressionData.MaxRank and progression.prestige < ProgressionData.MaxPrestige,
		mastery = progression.mastery,
		index = index,
		pages = progression.pages,
		shop = {
			day = day,
			bought = shop.day == day and shop.bought or {},
			resetIn = math.max(0, (day + 1) * 86400 - now),
		},
		companion = companion,
		companionXp = companion and data.CompanionXp and data.CompanionXp[companion] or 0,
	}
end

-- Playtime awards (#76), paid by PlaytimeService: coins for every IntervalSeconds of active play
-- in one visit, each award StepCoins bigger than the last up to CapCoins. Leaving the server
-- starts the ladder again; nothing is saved. A stretch only counts if the player moved in at
-- least MinActiveSamples of its SampleSeconds checks, so standing still in the lobby earns nothing.
-- Hour 1 pays 50+75+...+175 = 675 and every hour after pays 6 x 200 = 1,200. Against ECONOMY.md
-- section 2's cash an hour, that is +12% then +22% for a player who only ever loses (5,431), and
-- +6% then +10% for one who wins sometimes (12,024): it matters most to the player losing most.
ProgressionData.Playtime = {
	IntervalSeconds = 600,
	FirstCoins = 50,
	StepCoins = 25,
	CapCoins = 200,
	SampleSeconds = 30,
	MinActiveSamples = 10, -- of the 20 checks in a stretch
	MoveStuds = 4,
}

-- The coins the award'th playtime award pays (1 = the first one of a visit).
function ProgressionData.PlaytimeCoins(award)
	local p = ProgressionData.Playtime
	return math.min(p.CapCoins, p.FirstCoins + p.StepCoins * math.max(0, award - 1))
end

return ProgressionData
