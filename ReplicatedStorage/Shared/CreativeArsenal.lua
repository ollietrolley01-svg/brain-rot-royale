-- Fourteen creative guns, two for every rarity: everyday objects turned into weapons, in the spirit of
-- the Bubble Blaster. A tier's body-DPS band (damage x fireRate) is ANALYSIS, not a gate -- nothing in
-- the tools checks it, and slow high-damage guns sit below their tier's fast ones everywhere (QuietHours
-- is a Mythic sniper at 74.9 against a 232 in the same tier). Below a tier's floor is an archetype, not a
-- fault: don't raise a slow gun's fireRate to reach a band. The gate that matters is the one-shot
-- threshold -- health 100 plus shield 100 is a 200 pool -- and which guns cross it on a head hit.
-- Stats sit inside each tier's body-DPS band (damage x fireRate) against the guns
-- already in WeaponData and ArsenalExpansion; models are built by GunModelsCreative.
--
-- STAGED: `staged = true` keeps a gun out of players' hands until it has passed tools/ads_align_probe,
-- gun_gaps_probe, ads_hands_probe, tools/status_effects_probe, claude-f0's sight review and renders.
-- Ground and chest loot go by weight, so those are 0; bot loot and supply drops roll every gun of a
-- rarity and ignore weights, so they skip `staged` instead -- it is the one flag that gates all four.
-- `plannedGroundWeight` and `plannedChestWeight` are the numbers to switch on: when a gun passes, drop
-- its `staged` and set its weights in the same edit (tools/verify.py fails if the two ever disagree).
--
-- What those weights do to the drop mix, since WeaponData rolls ONE global weighted pool and a tier's
-- share is its guns' weights over the total. Ground: Common 67.0% -> 67.5%, Uncommon 33.0% -> 32.5%.
-- Chest: Common 35.0% -> 34.3%, Uncommon 38.0% -> 39.2%, Rare 17.7% -> 17.3%, Epic 6.7% -> 6.6%,
-- Legendary 2.3% -> 2.3%, Mythic 0.10% -> 0.20%, Secret 0.05% -> 0.10%. The top two tiers double
-- because they hold two guns each and these add two more apiece: accepted deliberately (twice as many
-- top-tier guns to find, each still vanishingly rare) rather than by splitting the stock guns' weights.
--
-- `style` matters beyond the fallback model, though less than it used to: CombatClient decides whether
-- a gun scopes in from the MODEL's `Optic` attribute, and uses `style` only for how far it zooms
-- (sniper 0.3, dmr 0.45, railgun 0.4, anything else the 0.4 default). So a scoped gun on an unusual
-- style -- the Snow Globe is a scoped "blaster" -- zooms at the default, and a red dot on a "sniper"
-- no longer scopes by accident.
--
-- Fields past the usual WeaponData ones, all read by ServerScriptService/Modules/StatusEffects.lua
-- (a CombatService damage listener) except `projectile`, which Ballistics and ProjectileService read:
--   knockback   studs/s shove along the shot       (StatusEffects, via MovementService.Launch)
--   bleed       { damage, duration }                (StatusEffects, damage over time)
--   ignite      { damage, duration }                (StatusEffects, damage over time)
--   chill       { slow, duration, stacks, freeze }  (StatusEffects, via the status speed API)
--   projectile  a ballistics kind registered in CreativeRounds: "ricochetDisc", "homingSlipper", "lobbedToast"
--               (a projectile gun's damage is dealt by ProjectileService, which has no headshot flag,
--               so those guns carry headshotMultiplier = 1 like the stock launcher does)
-- The three projectile guns' rounds are registered by CreativeRounds; loading it here puts the kinds in
-- Ballistics wherever WeaponData loads, before anything looks one up.
require(script.Parent:WaitForChild("CreativeRounds"))

local Pack = {}

Pack.Order = {
	"SqueakyDuckPopper", "JuiceBoxSquirter",
	"SpaghettiSlinger", "BoomboxBassline",
	"GumballGatling", "FidgetDiscLauncher",
	"MicrowaveZapper", "PizzaCutterCrossbow",
	"DiscoBallDeleter", "ToasterMortar",
	"RubberChickenRailgun", "LavaLampLancer",
	"SnowGlobeSingularity", "GrandmasSlipperLauncher",
}

Pack.Weapons = {
	-- Common ------------------------------------------------------------------
	SqueakyDuckPopper = {
		name = "Squeaky Duck Popper", rarity = "Common", style = "pistol",
		damage = 20, headshotMultiplier = 1.8, fireRate = 4.5, magSize = 14,
		reserveAmmo = 98, reloadTime = 1.25, range = 230, spread = 1.3, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 30, plannedChestWeight = 10,
		killEffect = "confetti",
		description = "A chunky bath-toy pistol with a rubber duck perched beside the sights. It squeaks.",
	},
	JuiceBoxSquirter = {
		name = "Juice Box Squirter", rarity = "Common", style = "smg",
		damage = 12, headshotMultiplier = 1.5, fireRate = 11.5, magSize = 32,
		reserveAmmo = 192, reloadTime = 1.8, range = 170, spread = 3.0, pellets = 1,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 26, plannedChestWeight = 10,
		killEffect = "float",
		description = "Squirt gun fed from a clear juice box. Watch the level drop.",
	},

	-- Uncommon ----------------------------------------------------------------
	SpaghettiSlinger = {
		name = "Spaghetti Slinger", rarity = "Uncommon", style = "shotgun",
		damage = 14, headshotMultiplier = 1.3, fireRate = 1.2, magSize = 6,
		reserveAmmo = 42, reloadTime = 2.5, range = 105, spread = 7, pellets = 7,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 14, plannedChestWeight = 14,
		killEffect = "ash",
		description = "A colander on a pump. Seven noodles, al dente, point blank.",
	},
	BoomboxBassline = {
		name = "Boombox Bassline", rarity = "Uncommon", style = "blaster",
		damage = 34, headshotMultiplier = 1.4, fireRate = 2.4, magSize = 10,
		reserveAmmo = 60, reloadTime = 2.0, range = 120, spread = 1.5, pellets = 1,
		ability = "pierce", knockback = 45,
		staged = true, groundWeight = 0, chestWeight = 0, plannedGroundWeight = 10, plannedChestWeight = 14,
		killEffect = "confetti",
		description = "Cassette boombox with speaker-cone muzzles. The drop hits people.",
	},

	-- Rare ----------------------------------------------------------------------
	GumballGatling = {
		name = "Gumball Gatling", rarity = "Rare", style = "minigun",
		damage = 16, headshotMultiplier = 1.4, fireRate = 12, magSize = 60,
		reserveAmmo = 240, reloadTime = 3.2, range = 260, spread = 3.0, pellets = 1,
		ability = "chain", chainRadius = 8, chainRatio = 0.15,
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 5,
		killEffect = "confetti",
		description = "Crank the gumball machine. The globe empties as you fire; gumballs bounce to a neighbour.",
	},
	FidgetDiscLauncher = {
		name = "Fidget Disc Launcher", rarity = "Rare", style = "launcher",
		damage = 55, headshotMultiplier = 1.5, fireRate = 1.3, magSize = 5,
		reserveAmmo = 30, reloadTime = 2.6, range = 300, spread = 0.8, pellets = 1,
		-- No `ability`: a projectile gun's hits go through ProjectileService, which applies none, and the
		-- HUD would advertise one the gun doesn't have.
		projectile = "ricochetDisc",
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 5,
		killEffect = "shock",
		description = "Fires glowing fidget spinners that glance off the first wall they meet.",
	},

	-- Epic ------------------------------------------------------------------------
	MicrowaveZapper = {
		name = "Microwave Zapper", rarity = "Epic", style = "blaster",
		damage = 22, headshotMultiplier = 1.5, fireRate = 11, magSize = 45,
		reserveAmmo = 180, reloadTime = 2.8, range = 240, spread = 1.6, pellets = 1,
		ability = "chain", chainRadius = 12, chainRatio = 0.25,
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 2,
		killEffect = "burn",
		description = "A countertop microwave on a stock. The door window is the sight. Ding.",
	},
	PizzaCutterCrossbow = {
		name = "Pizza Cutter Crossbow", rarity = "Epic", style = "crossbow",
		damage = 82, headshotMultiplier = 2.0, fireRate = 1.0, magSize = 3,
		reserveAmmo = 24, reloadTime = 2.2, range = 480, spread = 0.3, pellets = 1,
		ability = "pierce", bleed = { damage = 12, duration = 3 },
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 2,
		killEffect = "ash",
		description = "Rolling-pin limbs throw spinning pizza cutters that keep going.",
	},

	-- Legendary ---------------------------------------------------------------------
	DiscoBallDeleter = {
		name = "Disco Ball Deleter", rarity = "Legendary", style = "blaster",
		damage = 26, headshotMultiplier = 1, fireRate = 9, magSize = 40,
		reserveAmmo = 200, reloadTime = 2.4, range = 330, spread = 1.6, pellets = 1,
		ability = "chain", chainRadius = 14, chainRatio = 0.35,
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.65,
		killEffect = "confetti",
		description = "A caged mirror ball that spins up and throws light that jumps between people.",
	},
	ToasterMortar = {
		name = "Toaster Mortar", rarity = "Legendary", style = "launcher",
		-- Explosive, so only the round's impactBonus (15) is multiplied and the blast share stays flat:
		-- this is worth about three damage on a direct hit to the head.
		damage = 70, headshotMultiplier = 1.2, fireRate = 1.0, magSize = 2,
		reserveAmmo = 16, reloadTime = 2.4, range = 350, spread = 1.0, pellets = 1,
		ability = "explosive", splashRadius = 10, projectile = "lobbedToast",
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.65,
		killEffect = "burn",
		description = "A chrome two-slot toaster on a tube. Push the lever down, toast comes out hot.",
	},

	-- Mythic ------------------------------------------------------------------------------
	RubberChickenRailgun = {
		name = "Rubber Chicken Railgun", rarity = "Mythic", style = "railgun",
		damage = 105, headshotMultiplier = 2.2, fireRate = 0.7, magSize = 3,
		reserveAmmo = 18, reloadTime = 3.0, range = 1400, spread = 0, pellets = 1,
		ability = "pierce",
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.18,
		killEffect = "vaporize",
		description = "A rubber chicken stretched along a coil rail. It screams every single time.",
	},
	LavaLampLancer = {
		name = "Lava Lamp Lancer", rarity = "Mythic", style = "rifle",
		damage = 48, headshotMultiplier = 2.0, fireRate = 3.2, magSize = 12,
		reserveAmmo = 60, reloadTime = 2.4, range = 700, spread = 0.3, pellets = 1,
		ability = "lifesteal", lifestealRatio = 0.2, ignite = { damage = 15, duration = 3 },
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.18,
		killEffect = "burn",
		description = "The receiver is a lava lamp. The wax rises while you hold it.",
	},

	-- Secret ------------------------------------------------------------------------------
	SnowGlobeSingularity = {
		name = "Snow Globe Singularity", rarity = "Secret", style = "blaster",
		damage = 30, headshotMultiplier = 1.8, fireRate = 5, magSize = 20,
		reserveAmmo = 100, reloadTime = 2.2, range = 380, spread = 0.9, pellets = 1,
		ability = "chain", chainRadius = 10, chainRatio = 0.3,
		chill = { slow = 0.12, duration = 2, stacks = 3, freeze = 0.6 },
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.045,
		killEffect = "freeze",
		description = "A tiny town in a snow globe on a brass frame. Three hits and they're part of the scenery.",
	},
	GrandmasSlipperLauncher = {
		name = "Grandma's Slipper Launcher", rarity = "Secret", style = "crossbow",
		-- Headshots reach projectile rounds again (a round striking a Head counts), so this carries a real
		-- multiplier once more. 2.2 rather than its old 2.5, and the fireRate back to 0.9: 2.5 x (90 + 10)
		-- would be a 250 hit, a one-shot through a full 200 pool and the hardest in the game on a round
		-- that homes. 2.2 puts it under QuietHours (225.6) and the RubberChickenRailgun (231), in the same
		-- family as the other slow, high-damage guns. The 1.15 rate was raised to reach the Secret DPS
		-- band and never did (103.5 against a 119 floor), so nothing is lost putting it back.
		-- Measured since (projectile_probe, IMPACT homing): the steer takes the target's ROOT, so a homing
		-- hit aimed at a head lands 100 on the torso with headshot = false, and against a peeker with only
		-- a head showing the round follows the root into the wall and hits nobody. The multiplier is
		-- therefore reachable only when a head is what the round meets on its way to the root -- it cannot
		-- be aimed for. Don't read a low headshot rate here as the multiplier going to waste.
		damage = 90, headshotMultiplier = 2.2, fireRate = 0.9, magSize = 4,
		reserveAmmo = 20, reloadTime = 2.6, range = 420, spread = 0.4, pellets = 1,
		ability = "goldRush", goldRushBonus = 150, projectile = "homingSlipper",
		staged = true, groundWeight = 0, chestWeight = 0, plannedChestWeight = 0.045,
		killEffect = "gold",
		description = "A fuzzy house slipper on a spring-loaded launcher. It always finds you.",
	},
}

return Pack
