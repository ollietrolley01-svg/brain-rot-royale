-- Fifteen additive weapons. All figures are game balance values, in Roblox units.
-- Presentation shares GunModels' tested mechanisms, sights and hand keypoints.
local Pack = {}

Pack.Order = {
	"PawnshopNine", "RustbeltMarshal", "NightShiftPump",
	"DoomscrollSMG", "TrailheadCarbine", "TouchGrassScout", "DeadAirPrecision",
	"RatioPDW", "BackroomsBreacher", "ReceiptPrinterLMG", "SundaySpecial",
	"AuraAuditRifle", "QuietHours", "AdminOverride", "FinalNotice",
}

Pack.Weapons = {
	PawnshopNine = {
		name = "Pistacchio Pum", rarity = "Common", style = "pistol",
		damage = 21, headshotMultiplier = 1.8, fireRate = 4.8, magSize = 13,
		reserveAmmo = 91, reloadTime = 1.45, range = 230, spread = 1.35, pellets = 1,
		groundWeight = 24, chestWeight = 8,
		description = "Scuffed two-tone compact. Fast follow-up shots, modest reach.",
	},
	RustbeltMarshal = {
		name = "Sceriffo Sgrunf", rarity = "Common", style = "revolver",
		damage = 38, headshotMultiplier = 1.9, fireRate = 1.9, magSize = 6,
		reserveAmmo = 42, reloadTime = 2.45, range = 290, spread = 0.85, pellets = 1,
		groundWeight = 16, chestWeight = 8,
		description = "Blunt working revolver with walnut grips; deliberate, accurate taps.",
	},
	NightShiftPump = {
		name = "Ciabatta Clonk", rarity = "Common", style = "shotgun",
		damage = 13, headshotMultiplier = 1.3, fireRate = 0.95, magSize = 5,
		reserveAmmo = 40, reloadTime = 2.75, range = 110, spread = 7, pellets = 8,
		groundWeight = 18, chestWeight = 8,
		description = "Worn security shotgun. Work the pump between close-range shots.",
	},
	DoomscrollSMG = {
		name = "Scrolla Scrolla Brrrap", rarity = "Uncommon", style = "smg",
		damage = 15, headshotMultiplier = 1.6, fireRate = 11.5, magSize = 30,
		reserveAmmo = 180, reloadTime = 1.95, range = 205, spread = 2.4, pellets = 1,
		groundWeight = 13, chestWeight = 8, killEffect = "shock",
		description = "Folded-stock SMG in midnight blue. One more mag, then bed.",
	},
	TrailheadCarbine = {
		name = "Scarponcino Trotto Trotto", rarity = "Uncommon", style = "rifle",
		damage = 25, headshotMultiplier = 1.9, fireRate = 6.8, magSize = 25,
		reserveAmmo = 150, reloadTime = 1.9, range = 410, spread = 1.35, pellets = 1,
		groundWeight = 12, chestWeight = 8,
		description = "Short ranger carbine with iron sights and olive furniture.",
	},
	TouchGrassScout = {
		name = "Prato Prato Pium", rarity = "Rare", style = "dmr",
		damage = 43, headshotMultiplier = 2.2, fireRate = 3.3, magSize = 14,
		reserveAmmo = 70, reloadTime = 2.2, range = 690, spread = 0.32, pellets = 1,
		ability = "pierce", groundWeight = 0, chestWeight = 4,
		description = "Light scoped scout with a field-green finish and a tiny grass insignia.",
	},
	DeadAirPrecision = {
		name = "Silenzio Sussurrone", rarity = "Rare", style = "sniper",
		damage = 91, headshotMultiplier = 2.4, fireRate = 0.85, magSize = 6,
		reserveAmmo = 30, reloadTime = 3.0, range = 1250, spread = 0.09, pellets = 1,
		ability = "pierce", groundWeight = 0, chestWeight = 3.5, killEffect = "freeze",
		description = "Slate precision rifle. A visible hand-worked bolt rewards measured shots.",
	},
	RatioPDW = {
		name = "Piccolino Ratatatà", rarity = "Epic", style = "smg",
		damage = 20, headshotMultiplier = 1.6, fireRate = 12.5, magSize = 36,
		reserveAmmo = 216, reloadTime = 1.85, range = 230, spread = 2.05, pellets = 1,
		ability = "lifesteal", lifestealRatio = 0.1, groundWeight = 0, chestWeight = 2,
		killEffect = "confetti",
		description = "Suppressed drum-fed PDW, berry panels and a small L + RATIO marking.",
	},
	BackroomsBreacher = {
		name = "Porta Porta Bonk", rarity = "Epic", style = "shotgun",
		damage = 13, headshotMultiplier = 1.3, fireRate = 1.85, magSize = 8,
		reserveAmmo = 48, reloadTime = 2.85, range = 125, spread = 6, pellets = 9,
		ability = "lifesteal", lifestealRatio = 0.12, groundWeight = 0, chestWeight = 2,
		killEffect = "ash",
		description = "Drum-fed breacher in tired yellow: EXIT lettering, black rails, real sights.",
	},
	ReceiptPrinterLMG = {
		name = "Scontrino Infinito Brrrrr", rarity = "Legendary", style = "lmg",
		damage = 26, headshotMultiplier = 1.6, fireRate = 10.5, magSize = 70,
		reserveAmmo = 280, reloadTime = 4.1, range = 425, spread = 2.5, pellets = 1,
		ability = "goldRush", goldRushBonus = 100, groundWeight = 0, chestWeight = 0.65,
		killEffect = "gold",
		description = "Cream-and-charcoal belt-fed. The ammo box prints an ITEM / TOTAL receipt.",
	},
	SundaySpecial = {
		name = "Pranzo Della Nonna Bum", rarity = "Legendary", style = "cannon",
		damage = 87, headshotMultiplier = 2.2, fireRate = 1.35, magSize = 7,
		reserveAmmo = 35, reloadTime = 3.15, range = 720, spread = 0.65, pellets = 1,
		ability = "goldRush", goldRushBonus = 120, groundWeight = 0, chestWeight = 0.65,
		killEffect = "gold",
		description = "Heirloom lever rifle with deep walnut furniture and restrained brass trim.",
	},
	AuraAuditRifle = {
		name = "Occhietto Pium Pium", rarity = "Mythic", style = "rifle",
		damage = 29, headshotMultiplier = 1.9, fireRate = 8.0, magSize = 28,
		reserveAmmo = 168, reloadTime = 2.35, range = 470, spread = 1.05, pellets = 1,
		ability = "chain", chainRadius = 12, chainRatio = 0.22,
		groundWeight = 0, chestWeight = 0.18, killEffect = "shock",
		description = "White-and-titanium evaluation carbine. Small arcs punish tightly stacked teams.",
	},
	QuietHours = {
		name = "Nanna Nanna Puff", rarity = "Mythic", style = "sniper",
		damage = 96, headshotMultiplier = 2.35, fireRate = 0.78, magSize = 4,
		reserveAmmo = 24, reloadTime = 3.3, range = 1350, spread = 0.06, pellets = 1,
		ability = "lifesteal", lifestealRatio = 0.16,
		groundWeight = 0, chestWeight = 0.18, killEffect = "freeze",
		description = "Long fluted bolt rifle with dark plum furniture and a moon insignia.",
	},
	AdminOverride = {
		name = "Capo Supremo Bonkolone", rarity = "Secret", style = "pistol",
		damage = 34, headshotMultiplier = 2.0, fireRate = 3.5, magSize = 10,
		reserveAmmo = 60, reloadTime = 1.7, range = 335, spread = 0.65, pellets = 1,
		ability = "pierce", groundWeight = 0, chestWeight = 0.045, killEffect = "vaporize",
		description = "Black prototype sidearm with mint AUTH / LOCAL markings. No actual admin powers.",
	},
	FinalNotice = {
		name = "Ultimo Bum", rarity = "Secret", style = "rifle",
		damage = 33, headshotMultiplier = 1.9, fireRate = 6.5, magSize = 24,
		reserveAmmo = 144, reloadTime = 2.5, range = 490, spread = 1.15, pellets = 1,
		ability = "goldRush", goldRushBonus = 135,
		groundWeight = 0, chestWeight = 0.045, killEffect = "gold",
		description = "Stamped receiver, burgundy wood and a FINAL NOTICE label: the collector's AK.",
	},
}

Pack.Variants = {
	PawnshopNine = { compact = true },
	RustbeltMarshal = {},
	NightShiftPump = {},
	DoomscrollSMG = { skeletonStock = true, laser = true, holo = true },
	TrailheadCarbine = { compact = true, irons = true, light = true },
	TouchGrassScout = { compact = true, light = true },
	DeadAirPrecision = { boltAction = true, flutes = true },
	RatioPDW = { suppressor = true, drum = true, holo = true },
	BackroomsBreacher = { semiAuto = true, drum = true, holo = true, heatShield = true },
	ReceiptPrinterLMG = {},
	SundaySpecial = {},
	AuraAuditRifle = { holo = true, foregrip = true, light = true, engraved = true },
	QuietHours = { boltAction = true, longBarrel = true, flutes = true },
	AdminOverride = { laser = true, light = true },
	FinalNotice = { pattern = "ak", woodFurniture = true },
}

-- Test expectations: a mechanism is a contract, not a guess based on a weapon's name.
Pack.Actions = {
	PawnshopNine = "pistol", RustbeltMarshal = "revolver", NightShiftPump = "pump",
	DoomscrollSMG = "smg", TrailheadCarbine = "ar", TouchGrassScout = "semi",
	DeadAirPrecision = "bolt", RatioPDW = "smg", BackroomsBreacher = "semi",
	ReceiptPrinterLMG = "belt", SundaySpecial = "lever", AuraAuditRifle = "ar",
	QuietHours = "bolt", AdminOverride = "pistol", FinalNotice = "ak",
}

return Pack
