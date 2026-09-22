-- Guns, ordered by rarity. Higher rarity means better stats AND an ability, which is what
-- makes chest loot worth fighting over versus the floor loot you trip on at drop.
--
-- Abilities are resolved in ServerScriptService.Modules.CombatService:
--   pierce    - the shot keeps going through the first target it hits
--   explosive - splash damage around the impact point
--   lifesteal - heals the shooter for a fraction of damage dealt
--   chain     - damage arcs to one extra nearby enemy
--   goldRush  - eliminations with this weapon pay bonus SahurCoins
--
-- `style` picks the model silhouette WeaponService.BuildGunModel builds: pistol, revolver,
-- smg, rifle, dmr, shotgun, doublebarrel, crossbow, sniper, blaster, launcher, lmg, minigun,
-- cannon or railgun.
--
-- groundWeight > 0 means it spawns loose on the map. Only Common and Uncommon do; the good
-- stuff is chest-only.
--
-- A hitscan shot does its full `damage` anywhere inside `range` and nothing at all beyond it: there is
-- no falloff with distance. So a shotgun's feel is `spread` and `range`, NOT its burst -- pellets go out
-- in a cone of `spread` degrees (ADS x0.34, a steady crouch tighter still), and against a two-stud torso
-- a hip-fired 9-degree gun puts about a third of its pellets on target at 10 studs and almost none at 30.
-- Don't buff a shotgun's paper damage to make it feel stronger; tighten the cone and lengthen the reach.
--
-- `projectile` makes the gun fire a real round instead of a hitscan shot: its kind in
-- Ballistics.Rounds ("rocket", "grenade", ...) says how it flies, and ProjectileService flies it.
-- `damage` and `splashRadius` are then the round's blast.

local WeaponData = {}

WeaponData.Weapons = {
	-- Common ------------------------------------------------------------------
	SahurPistol = {
		name = "Sahur Pistol",
		rarity = "Common",
		style = "pistol",
		damage = 22,
		headshotMultiplier = 1.8,
		fireRate = 4,
		magSize = 15,
		reserveAmmo = 90,
		reloadTime = 1.3,
		range = 250,
		spread = 1.2,
		pellets = 1,
		groundWeight = 45,
		chestWeight = 14,
	},
	RotSMG = {
		name = "Rot SMG",
		rarity = "Common",
		style = "smg",
		damage = 13,
		headshotMultiplier = 1.5,
		fireRate = 11,
		magSize = 28,
		reserveAmmo = 180,
		reloadTime = 1.9,
		range = 180,
		spread = 3.2,
		pellets = 1,
		groundWeight = 35,
		chestWeight = 14,
	},
	BubbleBlaster = {
		name = "Bubble Blaster",
		rarity = "Common",
		style = "blaster",
		damage = 16,
		headshotMultiplier = 1.5,
		fireRate = 6,
		magSize = 20,
		reserveAmmo = 140,
		reloadTime = 1.5,
		range = 170,
		spread = 2.2,
		pellets = 1,
		groundWeight = 30,
		chestWeight = 14,
	},
	CrumblyCarbine = {
		name = "Crumbly Carbine",
		rarity = "Common",
		style = "rifle",
		-- The first rifle most people find: reach the pistols don't have, at a slow, forgiving rate.
		damage = 18,
		headshotMultiplier = 1.7,
		fireRate = 5.5,
		magSize = 24,
		reserveAmmo = 144,
		reloadTime = 1.9,
		range = 300,
		spread = 2,
		pellets = 1,
		groundWeight = 30,
		chestWeight = 14,
	},
	PocketPopper = {
		name = "Pocket Popper",
		rarity = "Common",
		style = "pistol",
		damage = 17,
		headshotMultiplier = 1.9,
		fireRate = 6,
		magSize = 12,
		reserveAmmo = 96,
		reloadTime = 1.1,
		range = 200,
		spread = 1.6,
		pellets = 1,
		groundWeight = 35,
		chestWeight = 14,
	},

	-- Uncommon ----------------------------------------------------------------
	CrocodiloRifle = {
		name = "Crocodilo Rifle",
		rarity = "Uncommon",
		style = "rifle",
		damage = 27,
		headshotMultiplier = 1.9,
		fireRate = 7,
		magSize = 30,
		reserveAmmo = 150,
		reloadTime = 2.1,
		range = 380,
		spread = 1.7,
		pellets = 1,
		groundWeight = 22,
		chestWeight = 18,
	},
	TralalaShotgun = {
		name = "Tralala Shotgun",
		rarity = "Uncommon",
		style = "shotgun",
		damage = 13,
		headshotMultiplier = 1.4,
		fireRate = 1.1,
		magSize = 6,
		reserveAmmo = 48,
		reloadTime = 2.6,
		range = 110,
		spread = 7,
		pellets = 8,
		groundWeight = 18,
		chestWeight = 16,
	},
	SigmaRevolver = {
		name = "Sigma Revolver",
		rarity = "Uncommon",
		style = "revolver",
		-- Slow and heavy: two body shots and a tap, or one headshot and a tap.
		damage = 46,
		headshotMultiplier = 2,
		fireRate = 2.2,
		magSize = 6,
		reserveAmmo = 42,
		reloadTime = 2.2,
		range = 320,
		spread = 0.7,
		pellets = 1,
		groundWeight = 14,
		chestWeight = 12,
	},
	LagSwitchSMG = {
		name = "Lag Switch SMG",
		rarity = "Uncommon",
		style = "smg",
		damage = 16,
		headshotMultiplier = 1.5,
		fireRate = 12,
		magSize = 32,
		reserveAmmo = 192,
		reloadTime = 1.8,
		range = 190,
		spread = 2.6,
		pellets = 1,
		groundWeight = 14,
		chestWeight = 14,
	},
	AuraCrossbow = {
		name = "Aura Crossbow",
		rarity = "Uncommon",
		style = "crossbow",
		-- A body shot takes 70; a headshot kills anyone without shield. THREE body shots are needed
		-- to kill through a full shield (100 health + 100 shield), so a magazine of one meant two full
		-- 1.4s reloads inside every kill and the weapon's real time-to-kill was nowhere near the 2.22s
		-- its numbers implied. The magazine now holds the shots the kill actually takes; reserveAmmo is
		-- unchanged, so nothing about how much ammo you carry moves.
		damage = 70,
		headshotMultiplier = 2.2,
		fireRate = 0.9,
		magSize = 3,
		reserveAmmo = 20,
		reloadTime = 1.4,
		range = 520,
		spread = 0.25,
		pellets = 1,
		groundWeight = 10,
		chestWeight = 12,
	},
	BonkerDoubleBarrel = {
		name = "Bonker Double Barrel",
		rarity = "Uncommon",
		style = "doublebarrel",
		-- Two shells back to back, then a reload. Brutal at arm's length, useless past a room.
		damage = 13,
		headshotMultiplier = 1.4,
		fireRate = 3,
		magSize = 2,
		reserveAmmo = 40,
		reloadTime = 2.2,
		range = 90,
		spread = 8,
		pellets = 9,
		groundWeight = 12,
		chestWeight = 14,
	},

	-- Rare --------------------------------------------------------------------
	BananiniBurst = {
		name = "Bananini Burst",
		rarity = "Rare",
		style = "rifle",
		damage = 31,
		headshotMultiplier = 2,
		-- Must out-damage the Uncommon Crocodilo Rifle (0.57s to kill), or the rarity
		-- ladder inverts and Pierce is the only reason to pick this up.
		fireRate = 7.5,
		magSize = 27,
		reserveAmmo = 135,
		reloadTime = 2,
		range = 450,
		spread = 1.1,
		pellets = 1,
		ability = "pierce",
		groundWeight = 0,
		chestWeight = 8,
	},
	LarilaSniper = {
		name = "Larila Sniper",
		rarity = "Rare",
		style = "sniper",
		damage = 95,
		headshotMultiplier = 2.5,
		fireRate = 0.8,
		magSize = 5,
		reserveAmmo = 25,
		reloadTime = 2.9,
		range = 1200,
		spread = 0.1,
		pellets = 1,
		ability = "pierce",
		groundWeight = 0,
		chestWeight = 6,
	},
	GrassToucherDMR = {
		name = "Grass Toucher DMR",
		rarity = "Rare",
		style = "dmr",
		damage = 46,
		headshotMultiplier = 2.2,
		fireRate = 3,
		magSize = 12,
		reserveAmmo = 72,
		reloadTime = 2.3,
		range = 650,
		spread = 0.35,
		pellets = 1,
		ability = "pierce",
		groundWeight = 0,
		chestWeight = 7,
	},
	AuraScattergun = {
		name = "Aura Scattergun",
		rarity = "Rare",
		style = "shotgun",
		damage = 13,
		headshotMultiplier = 1.3,
		fireRate = 1.6,
		magSize = 8,
		reserveAmmo = 56,
		reloadTime = 2.4,
		range = 125,
		spread = 6,
		pellets = 9,
		ability = "lifesteal",
		lifestealRatio = 0.15,
		groundWeight = 0,
		chestWeight = 7,
	},
	SigmaScout = {
		name = "Sigma Scout",
		rarity = "Rare",
		style = "dmr",
		-- A lighter, faster marksman rifle than the Grass Toucher: less per shot, more shots.
		damage = 38,
		headshotMultiplier = 2.3,
		fireRate = 3.5,
		magSize = 10,
		reserveAmmo = 70,
		reloadTime = 2,
		range = 700,
		spread = 0.3,
		pellets = 1,
		ability = "pierce",
		groundWeight = 0,
		chestWeight = 6,
	},
	BubbleBurster = {
		name = "Bubble Burster",
		rarity = "Rare",
		style = "blaster",
		damage = 21,
		headshotMultiplier = 1.5,
		fireRate = 9,
		magSize = 36,
		reserveAmmo = 216,
		reloadTime = 2,
		range = 220,
		spread = 2.4,
		pellets = 1,
		ability = "chain",
		chainRadius = 14,
		chainRatio = 0.3,
		groundWeight = 0,
		chestWeight = 6,
	},

	-- Epic --------------------------------------------------------------------
	CappuccinaLauncher = {
		name = "Cappuccina Launcher",
		rarity = "Epic",
		style = "launcher",
		damage = 68,
		headshotMultiplier = 1,
		fireRate = 0.9,
		magSize = 4,
		reserveAmmo = 16,
		reloadTime = 3.2,
		range = 400,
		spread = 0.6,
		pellets = 1,
		ability = "explosive",
		splashRadius = 14,
		projectile = "rocket",
		groundWeight = 0,
		chestWeight = 3,
	},
	CameloLMG = {
		name = "Camelo Vampire LMG",
		rarity = "Epic",
		style = "lmg",
		damage = 24,
		headshotMultiplier = 1.6,
		fireRate = 10,
		magSize = 60,
		reserveAmmo = 240,
		reloadTime = 3.6,
		range = 400,
		spread = 2.6,
		pellets = 1,
		ability = "lifesteal",
		lifestealRatio = 0.22,
		groundWeight = 0,
		chestWeight = 3,
	},
	SixSevenMarksman = {
		name = "Six-Seven Marksman",
		rarity = "Epic",
		style = "sniper",
		damage = 62,
		headshotMultiplier = 2.3,
		fireRate = 2.2,
		magSize = 8,
		reserveAmmo = 48,
		reloadTime = 2.6,
		range = 900,
		spread = 0.2,
		pellets = 1,
		ability = "pierce",
		groundWeight = 0,
		chestWeight = 3,
	},
	TralalaThumper = {
		name = "Tralala Thumper",
		rarity = "Epic",
		style = "launcher",
		-- Smaller blasts than the Cappuccina Launcher, but six of them before a reload.
		damage = 58,
		headshotMultiplier = 1,
		fireRate = 1.4,
		magSize = 6,
		reserveAmmo = 24,
		reloadTime = 3.4,
		range = 320,
		spread = 1.2,
		pellets = 1,
		ability = "explosive",
		splashRadius = 11,
		projectile = "grenade",
		groundWeight = 0,
		chestWeight = 2,
	},
	GlitchSMG = {
		name = "Glitch SMG",
		rarity = "Epic",
		style = "smg",
		damage = 19,
		headshotMultiplier = 1.6,
		fireRate = 14,
		magSize = 40,
		reserveAmmo = 240,
		reloadTime = 1.7,
		range = 220,
		spread = 2.2,
		pellets = 1,
		ability = "lifesteal",
		lifestealRatio = 0.1,
		groundWeight = 0,
		chestWeight = 3,
	},

	-- Legendary ---------------------------------------------------------------
	NonnaDoubleBarrel = {
		name = "Nonna Double Barrel",
		rarity = "Legendary",
		style = "doublebarrel",
		-- Grandma's heirloom. Every elimination with it pays out like the Golden Sahur Cannon.
		-- the eight, which is what a Legendary double barrel should have; it no longer one-shots.
		damage = 16,
		headshotMultiplier = 1.5,
		fireRate = 3.2,
		magSize = 2,
		reserveAmmo = 36,
		reloadTime = 2,
		range = 105,
		spread = 7.5,
		pellets = 10,
		ability = "goldRush",
		goldRushBonus = 120,
		groundWeight = 0,
		chestWeight = 1,
	},
	PatapimChaingun = {
		name = "Patapim Chaingun",
		rarity = "Legendary",
		style = "minigun",
		damage = 29,
		headshotMultiplier = 1.7,
		fireRate = 13,
		magSize = 100,
		reserveAmmo = 300,
		reloadTime = 4,
		range = 450,
		spread = 2.2,
		pellets = 1,
		ability = "chain",
		chainRadius = 22,
		chainRatio = 0.5,
		groundWeight = 0,
		chestWeight = 1,
	},
	GoldenSahurCannon = {
		name = "Golden Sahur Cannon",
		rarity = "Legendary",
		style = "cannon",
		-- Deliberately just under 100: a body shot leaves a full-health player on 8 HP
		-- rather than deleting them, so there's a moment to react. Headshots (x2.2) still
		-- kill outright, which is where the weapon earns its rarity.
		damage = 92,
		headshotMultiplier = 2.2,
		fireRate = 1.2,
		magSize = 6,
		reserveAmmo = 30,
		reloadTime = 3,
		range = 700,
		spread = 0.8,
		pellets = 1,
		ability = "goldRush",
		goldRushBonus = 150,
		groundWeight = 0,
		chestWeight = 1,
	},
	-- The id stays "RizzRotary" for saved skins and stats; the gun is a rifle now.
	RizzRotary = {
		name = "Rizz Rifle",
		rarity = "Legendary",
		style = "rifle",
		damage = 27,
		headshotMultiplier = 1.8,
		fireRate = 8.5,
		magSize = 32,
		reserveAmmo = 224,
		reloadTime = 2.1,
		range = 340,
		spread = 1.4,
		pellets = 1,
		ability = "lifesteal",
		lifestealRatio = 0.12,
		groundWeight = 0,
		chestWeight = 1,
	},
	DeluluRailgun = {
		name = "Delulu Railgun",
		rarity = "Legendary",
		style = "railgun",
		-- Same under-100 rule as the Cannon for body shots; the arc to a second enemy is the reward.
		damage = 88,
		headshotMultiplier = 2.4,
		fireRate = 0.75,
		magSize = 3,
		reserveAmmo = 18,
		reloadTime = 3.2,
		range = 1500,
		spread = 0,
		pellets = 1,
		ability = "chain",
		chainRadius = 20,
		chainRatio = 0.5,
		groundWeight = 0,
		chestWeight = 1,
	},
}

-- What a kill with the gun does to the body (ServerScriptService.Modules.DeathFxService):
-- float, ash, burn, freeze, shock, confetti, vaporize or gold. Anything not listed ragdolls.
WeaponData.KillEffects = {
	BubbleBlaster = "float",
	CrumblyCarbine = "ash",
	PocketPopper = "confetti",
	LagSwitchSMG = "shock",
	AuraCrossbow = "float",
	BananiniBurst = "confetti",
	LarilaSniper = "freeze",
	AuraScattergun = "shock",
	BubbleBurster = "float",
	CappuccinaLauncher = "burn",
	CameloLMG = "ash",
	SixSevenMarksman = "freeze",
	TralalaThumper = "burn",
	GlitchSMG = "shock",
	NonnaDoubleBarrel = "burn",
	PatapimChaingun = "ash",
	GoldenSahurCannon = "gold",
	RizzRotary = "float",
	DeluluRailgun = "vaporize",
}

-- Additive arsenal pack; existing IDs remain valid for saved skins and stats.
local ArsenalExpansion = require(script.Parent:WaitForChild("ArsenalExpansion"))
for id, def in pairs(ArsenalExpansion.Weapons) do
	assert(WeaponData.Weapons[id] == nil, "Duplicate arsenal weapon: " .. id)
	WeaponData.Weapons[id] = table.clone(def)
	WeaponData.KillEffects[id] = def.killEffect or "ragdoll"
end

-- Creative pack (everyday-object guns; models in GunModelsCreative). Their loot weights stay 0 in the
-- pack until each gun has passed its sight, gap and hand probes and renders.
local CreativeArsenal = require(script.Parent:WaitForChild("CreativeArsenal"))
for id, def in pairs(CreativeArsenal.Weapons) do
	assert(WeaponData.Weapons[id] == nil, "Duplicate creative weapon: " .. id)
	WeaponData.Weapons[id] = table.clone(def)
	WeaponData.KillEffects[id] = def.killEffect or "ragdoll"
end

-- Workshop pack (shed-and-kitchen guns; models in GunModelsWorkshop). Staged the same way: weights stay 0
-- until a gun has passed its sight, contact, grip and hand probes and its renders.
local WorkshopArsenal = require(script.Parent:WaitForChild("WorkshopArsenal"))
for id, def in pairs(WorkshopArsenal.Weapons) do
	assert(WeaponData.Weapons[id] == nil, "Duplicate workshop weapon: " .. id)
	WeaponData.Weapons[id] = table.clone(def)
	WeaponData.KillEffects[id] = def.killEffect or "ragdoll"
end

local groundPool, chestPool = {}, {}
for id, def in pairs(WeaponData.Weapons) do
	def.id = id
	def.killEffect = WeaponData.KillEffects[id] or "ragdoll"
	if (def.groundWeight or 0) > 0 then
		table.insert(groundPool, def)
	end
	if (def.chestWeight or 0) > 0 then
		table.insert(chestPool, def)
	end
end

local function weightedPick(pool, weightKey)
	local total = 0
	for _, def in ipairs(pool) do
		total += def[weightKey]
	end
	local roll = math.random() * total
	local cumulative = 0
	for _, def in ipairs(pool) do
		cumulative += def[weightKey]
		if roll <= cumulative then
			return def
		end
	end
	return pool[1]
end

function WeaponData.Get(id)
	return WeaponData.Weapons[id]
end

function WeaponData.RollGroundWeapon()
	return weightedPick(groundPool, "groundWeight")
end

function WeaponData.RollChestWeapon()
	return weightedPick(chestPool, "chestWeight")
end

return WeaponData
