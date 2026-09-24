-- Everything you can carry that isn't a gun: heals, shield potions and movement items.
--
-- Your inventory is eight slots. A gun takes a slot to itself; an item takes a slot and stacks up
-- to `stack` of the same thing in it. Select a slot to hold what's in it, then click to use it.
--
--   kind      "heal" restores health up to `cap`; "shield" fills your shield up to `cap`;
--             "movement" does its effect through MovementService; "defense" builds a structure
--             in front of you through DefenseService; "throwable" is thrown along your aim and
--             bounces (ProjectileService, with its flight and blast in Ballistics.Throwables)
--   useTime   seconds spent using it (unrolling a bandage, drinking a potion); 0 is instant.
--             Switching slots cancels a use in progress.
--   pickup    how many come in one pickup on the map
--   weight    how often it turns up in its loot pool, relative to the others there

local ItemData = {}

ItemData.Items = {
	Bandage = {
		name = "Bandage",
		kind = "heal",
		rarity = "Common",
		amount = 30,
		cap = 75,
		useTime = 2.5,
		stack = 10,
		pickup = 3,
		weight = 45,
		color = Color3.fromRGB(236, 226, 200),
		description = "+30 health, up to 75% of your max health.",
	},
	MedKit = {
		name = "Med Kit",
		kind = "heal",
		rarity = "Uncommon",
		amount = 100,
		cap = 100,
		useTime = 5,
		stack = 3,
		pickup = 1,
		weight = 18,
		color = Color3.fromRGB(235, 70, 70),
		description = "Back to full health.",
	},
	MiniShield = {
		name = "Mini Shield Potion",
		kind = "shield",
		rarity = "Uncommon",
		amount = 25,
		cap = 50,
		useTime = 2,
		stack = 6,
		pickup = 2,
		weight = 25,
		color = Color3.fromRGB(90, 190, 255),
		description = "+25 shield, up to 50.",
	},
	ShieldPotion = {
		name = "Shield Potion",
		kind = "shield",
		rarity = "Rare",
		amount = 50,
		cap = 100,
		useTime = 4.5,
		stack = 3,
		pickup = 1,
		weight = 12,
		color = Color3.fromRGB(60, 120, 255),
		description = "+50 shield, up to a full 100.",
	},
	SpeedSoda = {
		name = "Speed Soda",
		kind = "movement",
		rarity = "Common",
		useTime = 0.5,
		stack = 3,
		pickup = 1,
		weight = 26,
		color = Color3.fromRGB(80, 220, 255),
		description = "+65% movement speed for 10 seconds, and a RUSH: sprint, slide, vault and climb without using stamina.",
	},
	RotRocket = {
		name = "Rot Rocket",
		kind = "movement",
		rarity = "Uncommon",
		useTime = 0,
		stack = 3,
		pickup = 1,
		weight = 20,
		color = Color3.fromRGB(255, 130, 60),
		description = "Blasts you high and far, keeping its speed all the way down. Aim up for height, level for distance.",
	},
	LaunchPad = {
		name = "Launch Pad",
		kind = "movement",
		rarity = "Uncommon",
		useTime = 0,
		stack = 2,
		pickup = 1,
		weight = 14,
		color = Color3.fromRGB(190, 110, 255),
		description = "Drops a pad that throws anyone high into the air, along the way they're running, for 30 seconds.",
	},
	BlinkBean = {
		name = "Blink Bean",
		kind = "movement",
		rarity = "Rare",
		useTime = 0,
		stack = 4,
		pickup = 2,
		weight = 18,
		color = Color3.fromRGB(255, 90, 220),
		description = "A lightning-fast 44-stud dash the way you're facing. You come out still moving, and it cancels a fall. It stops short of walls.",
	},
	BounceBoots = {
		name = "Bounce Boots",
		kind = "movement",
		rarity = "Rare",
		useTime = 0.6,
		stack = 2,
		pickup = 1,
		weight = 12,
		color = Color3.fromRGB(120, 230, 120),
		description = "Nearly triple-height jumps plus a mid-air double jump, for 18 seconds.",
	},
	RotGlider = {
		name = "Rot Glider",
		kind = "movement",
		rarity = "Epic",
		useTime = 0,
		stack = 2,
		pickup = 1,
		weight = 10,
		color = Color3.fromRGB(170, 120, 255),
		description = "A wing over your head. Near the ground an updraft throws you up first; then sail where you look for 16 seconds, falling slowly.",
	},

	-- Portable defenses: throw the kit and it pops up wherever it lands, facing the way you were
	-- looking. They take gunfire and explosions and collapse when shot out. Rare, and rarer up the
	-- tiers.
	RotBarricade = {
		name = "Rot Barricade",
		kind = "defense",
		rarity = "Rare",
		useTime = 0,
		stack = 3,
		pickup = 2,
		weight = 8,
		color = Color3.fromRGB(226, 196, 130),
		description = "Throw it: a sandbag wall pops up where it lands. 250 HP.",
	},
	PopupBunker = {
		name = "Pop-up Bunker",
		kind = "defense",
		rarity = "Epic",
		useTime = 0,
		stack = 2,
		pickup = 1,
		weight = 4,
		color = Color3.fromRGB(150, 160, 178),
		description = "Throw it: a roofed bunker with a firing slot and a back door. 1,250 HP.",
	},
	BrainrotFortress = {
		name = "Brainrot Fortress",
		kind = "defense",
		rarity = "Legendary",
		useTime = 0,
		stack = 1,
		pickup = 1,
		weight = 1,
		color = Color3.fromRGB(255, 196, 64),
		description = "Throw it: a two-floor fort with windows, a hatch ladder and battlements. 2,500 HP.",
	},
	-- The trap in the defense pool: thrown like a kit, but it arms where it lands instead of
	-- building anything, and goes off under the next enemy to step near it (HazardService).
	RotMine = {
		name = "Rot Mine",
		kind = "defense",
		rarity = "Rare",
		useTime = 0,
		stack = 3,
		pickup = 2,
		weight = 6,
		color = Color3.fromRGB(150, 210, 90),
		description = "Throw it: arms where it lands and blows up under the next enemy who steps near it. 95 damage.",
	},

	-- Throwables: hold one and a dotted arc shows where it will land; click to throw. They bounce off
	-- whatever they hit. How they fly and what they do is in Ballistics.Throwables.
	CookedCoconut = {
		name = "Cooked Coconut",
		kind = "throwable",
		rarity = "Uncommon",
		useTime = 0,
		stack = 4,
		pickup = 2,
		weight = 14,
		color = Color3.fromRGB(255, 140, 50),
		description = "Frag grenade. Hold the click to cook the fuse, let go to throw. Blows 3.2 s after the pin: up to 100 damage.",
	},
	LowkeyLatte = {
		name = "Lowkey Latte",
		kind = "throwable",
		rarity = "Uncommon",
		useTime = 0,
		stack = 3,
		pickup = 2,
		weight = 10,
		color = Color3.fromRGB(170, 182, 196),
		description = "Smoke bomb. Pours out a cloud 32 studs across for about 18 s. Nobody sees through it, bots included.",
	},
	ClingyCrumpet = {
		name = "Clingy Crumpet",
		kind = "throwable",
		rarity = "Rare",
		useTime = 0,
		stack = 3,
		pickup = 1,
		weight = 8,
		color = Color3.fromRGB(214, 44, 78),
		description = "Sticky bomb. Sticks to whatever it hits, vehicles and players included, and blows 2.5 s later: up to 110 damage. A ghost shows where it will stick.",
	},
}

ItemData.Order = {
	"Bandage", "MedKit", "MiniShield", "ShieldPotion",
	"SpeedSoda", "RotRocket", "LaunchPad", "BlinkBean", "BounceBoots", "RotGlider",
	"RotBarricade", "RotMine", "PopupBunker", "BrainrotFortress",
	"CookedCoconut", "LowkeyLatte", "ClingyCrumpet",
}

for id, item in pairs(ItemData.Items) do
	item.id = id
end

-- How many structures ONE player can have standing at once. DefenseService enforces it (a fourth
-- collapses their oldest), and it lives here because the client has to be able to say so: a cap the
-- player only discovers by losing a wall they built is not a rule, it is a surprise.
--
-- Mines are not structures and are not capped -- they arm where they land and belong to
-- HazardService -- so the sentence below goes on the three that build something, not on all four
-- "defense" items.
ItemData.MaxStructuresPerPlayer = 3

-- `capRule` is its own field rather than a sentence glued onto `description`, at the HUD tab's asking
-- and for their reason, which is better than the editorial one: joining two fields is a line of code,
-- while splitting one requires parsing English. A fused field imposes its choice on every consumer
-- that will ever exist; a split field imposes nothing on anyone.
--
-- Still composed from the constant, never typed: a split is exactly the moment someone writes
-- "three" by hand, and tools/lua_static_check.py fails that pattern for good reason.
for _, id in ipairs({ "RotBarricade", "PopupBunker", "BrainrotFortress" }) do
	ItemData.Items[id].capRule = string.format(
		"Up to %d of your own can stand at once - a new one replaces your oldest.",
		ItemData.MaxStructuresPerPlayer)
end

function ItemData.Get(id)
	return ItemData.Items[id]
end

-- Heals and shields share the "heal" loot spots; movement items have their own.
local function pool(kinds)
	local list = {}
	for _, id in ipairs(ItemData.Order) do
		if kinds[ItemData.Items[id].kind] then
			table.insert(list, ItemData.Items[id])
		end
	end
	return list
end

local healPool = pool({ heal = true, shield = true })
local movementPool = pool({ movement = true })
local defensePool = pool({ defense = true })
local throwablePool = pool({ throwable = true })

local function roll(list)
	local total = 0
	for _, item in ipairs(list) do
		total += item.weight
	end
	local value = math.random() * total
	for _, item in ipairs(list) do
		value -= item.weight
		if value <= 0 then
			return item
		end
	end
	return list[#list]
end

function ItemData.RollRecovery()
	return roll(healPool)
end

function ItemData.RollMovement()
	return roll(movementPool)
end

-- Weighted toward the barricade: fortresses are one in nineteen of these, mines about a third.
function ItemData.RollDefense()
	return roll(defensePool)
end

-- Frags a little more often than smoke: 14 to 10.
function ItemData.RollThrowable()
	return roll(throwablePool)
end

return ItemData
