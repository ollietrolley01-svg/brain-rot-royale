-- Six workshop guns: things off a shed shelf or a kitchen counter made to shoot, in the spirit of the
-- Bubble Blaster, with a different mechanism each so they play as differently as they look. Stats sit in
-- their tier's body-DPS band against the guns already in WeaponData, ArsenalExpansion and CreativeArsenal;
-- models are built by GunModelsWorkshop.
--
-- STAGED: `staged = true` keeps a gun out of players' hands until it has passed tools/ads_align_probe,
-- gun_contact_probe, grip_junction_probe, hand_grip_probe and its renders. Ground and chest loot go by
-- weight, so those are 0; bot loot and supply drops roll every gun of a rarity and ignore weights, so they
-- skip `staged` instead -- it is the one flag that gates all four. `plannedGroundWeight` and
-- `plannedChestWeight` are the numbers to switch on: when a gun passes, drop its `staged` and set its
-- weights in the same edit (tools/verify.py fails if the two ever disagree).
--
-- `style` picks the mechanism and the fallback model, and CombatClient picks scope zoom by style (sniper,
-- dmr, railgun), so only a gun that really carries a scope may take one of those.
--
-- Extra fields, read by ServerScriptService/Modules/StatusEffects.lua:
--   knockback  studs/s shove along the shot
--   chill      { slow, duration, stacks, freeze }

local Pack = {}

-- A gun joins the pack only once GunModelsWorkshop can build it: without a builder it would fall back to
-- its style's stock model, which is not what it is. All six build now.
Pack.Order = {
	"RageQuitCarbine",
	"CleanSweepDouble",
	"HoseDownSniper",
	"DustDevilRotary",
	"YardWorkBlower",
	"PartyFoulCannon",
}

Pack.Weapons = {
	-- Common ------------------------------------------------------------------
	RageQuitCarbine = {
		name = "Rage Quit", rarity = "Common", style = "rifle",
		damage = 24, headshotMultiplier = 1.7, fireRate = 6.0, magSize = 24,
		reserveAmmo = 168, reloadTime = 1.9, range = 240, spread = 1.8, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 28, plannedChestWeight = 10,
		killEffect = "shock",
		description = "A mechanical keyboard with a trigger. Fires the keycaps, one clack at a time.",
	},

	-- Uncommon ----------------------------------------------------------------
	CleanSweepDouble = {
		name = "Clean Sweep", rarity = "Uncommon", style = "doublebarrel",
		damage = 12, headshotMultiplier = 1.4, fireRate = 2.4, magSize = 2,
		reserveAmmo = 24, reloadTime = 2.2, range = 100, spread = 8, pellets = 8,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 24, plannedChestWeight = 9,
		killEffect = "ash",
		description = "Two broom handles over a dustpan. Both barrels of bristles, then a long reload.",
	},

	-- Rare --------------------------------------------------------------------
	HoseDownSniper = {
		name = "Hose Down", rarity = "Rare", style = "sniper",
		damage = 85, headshotMultiplier = 2.0, fireRate = 0.9, magSize = 5,
		reserveAmmo = 30, reloadTime = 2.6, range = 420, spread = 0.4, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 18, plannedChestWeight = 9,
		chill = { slow = 0.22, duration = 2.0, stacks = 2 },
		killEffect = "freeze",
		description = "A garden hose reel with a brass nozzle and a jam-jar scope. A lance of cold water.",
	},
	DustDevilRotary = {
		name = "Dust Devil", rarity = "Rare", style = "minigun",
		damage = 15, headshotMultiplier = 1.3, fireRate = 12.0, magSize = 120,
		reserveAmmo = 360, reloadTime = 4.0, range = 150, spread = 4.5, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 16, plannedChestWeight = 9,
		killEffect = "ash",
		description = "A canister vacuum whose four hoses spin up and spit dust bunnies.",
	},

	-- Epic --------------------------------------------------------------------
	YardWorkBlower = {
		name = "Yard Work", rarity = "Epic", style = "lmg",
		damage = 22, headshotMultiplier = 1.4, fireRate = 10.0, magSize = 60,
		reserveAmmo = 300, reloadTime = 3.2, range = 200, spread = 3.2, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 12, plannedChestWeight = 8,
		knockback = 12,
		killEffect = "float",
		description = "A leaf blower fed from a leaf bag. Holds down a lane in a storm of leaves.",
	},

	-- Legendary ---------------------------------------------------------------
	PartyFoulCannon = {
		name = "Party Foul", rarity = "Legendary", style = "cannon",
		damage = 84, headshotMultiplier = 1.8, fireRate = 1.3, magSize = 6,
		reserveAmmo = 36, reloadTime = 2.9, range = 260, spread = 1.0, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 7, plannedChestWeight = 5,
		knockback = 40,
		killEffect = "confetti",
		description = "A party popper the size of a cannon. Corks, confetti and a shove that clears a doorway.",
	},
}

return Pack
