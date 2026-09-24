-- The shop's rotating stock.
--
-- Every five minutes a new selection of cosmetics goes on sale and a new set of crates can be
-- bought. It's the same on every server and every client: each rotation is drawn with a Random
-- seeded from the rotation number, and the rotation number comes from the shared server clock
-- (workspace:GetServerTimeNow), so nobody needs to be told what's in stock.
--
-- Rarer things turn up less often. Cosmetic slots are filled by weighted draws — a Common is a
-- hundred times as likely to be picked as a Legendary — and each crate has its own chance of
-- being in stock at all. Only buying is limited: crates you own can always be opened, and
-- cosmetics you own can always be equipped.

local CosmeticData = require(script.Parent:WaitForChild("CosmeticData"))
local CrateData = require(script.Parent:WaitForChild("CrateData"))

local ShopRotation = {}

ShopRotation.RotationSeconds = 300

-- How many of each kind of cosmetic are on sale per rotation, in the order they're drawn. The
-- order matters: every client has to make the same draws in the same sequence.
ShopRotation.Slots = {
	{ kind = "GunSkin", count = 3 },
	{ kind = "Aura", count = 2 },
	{ kind = "Accessory", count = 4 },
}

-- How likely an item of each rarity is to fill a slot, relative to the others.
ShopRotation.RarityWeight = { Common = 100, Uncommon = 55, Rare = 25, Epic = 9, Legendary = 1, Mythic = 0.4, Secret = 0.1 }

-- Chance each crate is buyable in a given rotation. The two crates that pay out mostly Legendary
-- and up are the hardest to catch on the shelf.
ShopRotation.CrateChance = {
	Common = 1, Uncommon = 1, Rare = 0.85, Epic = 0.6, Legendary = 0.25, Mythic = 0.1,
	Accessory = 0.7, Skin = 0.75, Aura = 0.5, Parachute = 0.5,
	-- The Death Effect Crate (2026-09-24). Drawn last in CrateData.Order, so its roll comes after
	-- every other crate's in each rotation and theirs are exactly as they were.
	DeathEffect = 0.5,
	-- Sold for Robux, so it's never out of stock.
	Super = 1,
}

local function serverNow()
	local ok, time = pcall(function()
		return workspace:GetServerTimeNow()
	end)
	return ok and time or os.time()
end

function ShopRotation.Window(at)
	return math.floor((at or serverNow()) / ShopRotation.RotationSeconds)
end

function ShopRotation.SecondsLeft(at)
	local time = at or serverNow()
	return ShopRotation.RotationSeconds - (time % ShopRotation.RotationSeconds)
end

-- Parachutes on sale per rotation. They're drawn after everything else, from a Random of their
-- own, so adding them (2026-09-17) left every rotation's skins, auras, accessories and crates
-- exactly as they were. tools/parachute_shop_probe.lua checks that against the old draw.
ShopRotation.ParachuteSlots = 2

-- Death effects (kind "KillAnimation") on sale per rotation (#24, 2026-09-24). Drawn last, from a
-- Random of their own, for the same reason as the parachutes: every earlier draw in every rotation
-- stays as it was. Four of the eleven buyable ones at a time, so the Death Effects tab always has a
-- real choice without the whole range being on the shelf at once.
ShopRotation.KillAnimationSlots = 4

local cached = nil

-- `count` weighted draws, without repeats, from the buyable cosmetics of `kind`, marked in `into`.
local function drawCosmetics(random, kind, count, into)
	local pool = {}
	for _, id in ipairs(CosmeticData.OfKind(kind, true)) do
		local item = CosmeticData.Get(id)
		if item.price then
			table.insert(pool, { id = id, weight = ShopRotation.RarityWeight[item.rarity] or 1 })
		end
	end
	for _ = 1, math.min(count, #pool) do
		local total = 0
		for _, entry in ipairs(pool) do
			total += entry.weight
		end
		local roll = random:NextNumber() * total
		for index, entry in ipairs(pool) do
			roll -= entry.weight
			if roll <= 0 or index == #pool then
				into[entry.id] = true
				table.remove(pool, index)
				break
			end
		end
	end
end

local function stockFor(window)
	if cached and cached.window == window then
		return cached
	end
	local random = Random.new(window * 7919 + 17)

	local cosmetics = {}
	for _, slot in ipairs(ShopRotation.Slots) do
		drawCosmetics(random, slot.kind, slot.count, cosmetics)
	end

	local crates = {}
	for _, id in ipairs(CrateData.Order) do
		crates[id] = random:NextNumber() < (ShopRotation.CrateChance[id] or 1)
	end
	-- There's always something to buy.
	crates.Common = true
	crates.Super = true

	drawCosmetics(Random.new(window * 6311 + 29), "Parachute", ShopRotation.ParachuteSlots, cosmetics)
	drawCosmetics(Random.new(window * 4513 + 41), "KillAnimation", ShopRotation.KillAnimationSlots, cosmetics)

	cached = { window = window, cosmetics = cosmetics, crates = crates }
	return cached
end

function ShopRotation.IsCosmeticInStock(id, at)
	return stockFor(ShopRotation.Window(at)).cosmetics[id] == true
end

function ShopRotation.IsCrateInStock(id, at)
	return stockFor(ShopRotation.Window(at)).crates[id] == true
end

-- "3:42" until the next rotation.
function ShopRotation.FormatTimeLeft(at)
	local seconds = math.max(0, math.floor(ShopRotation.SecondsLeft(at)))
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

return ShopRotation
