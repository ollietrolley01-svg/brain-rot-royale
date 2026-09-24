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
		description = "A pistachio-green pawnshop pistol with cracked-shell grips and the price tag still on.",
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
		description = "The night-shift bakery's shotgun: a ciabatta for a pump, a baguette for a stock, breadsticks in the saddle.",
	},
	DoomscrollSMG = {
		name = "Scrolla Scrolla Brrrap", rarity = "Uncommon", style = "smg",
		damage = 15, headshotMultiplier = 1.6, fireRate = 11.5, magSize = 30,
		reserveAmmo = 180, reloadTime = 1.95, range = 205, spread = 2.4, pellets = 1,
		groundWeight = 13, chestWeight = 8, killEffect = "shock",
		description = "A phone clamped to its side mid-scroll, a power bank for a magazine, a selfie stick for a stock. One more mag, then bed.",
	},
	TrailheadCarbine = {
		name = "Scarponcino Trotto Trotto", rarity = "Uncommon", style = "rifle",
		damage = 25, headshotMultiplier = 1.9, fireRate = 6.8, magSize = 25,
		reserveAmmo = 150, reloadTime = 1.9, range = 410, spread = 1.35, pellets = 1,
		groundWeight = 12, chestWeight = 8,
		description = "Packed for a hike: a trekking-pole handguard, a headlamp, paracord and a compass in the stock.",
	},
	TouchGrassScout = {
		name = "Prato Prato Pium", rarity = "Rare", style = "dmr",
		damage = 43, headshotMultiplier = 2.2, fireRate = 3.3, magSize = 14,
		reserveAmmo = 70, reloadTime = 2.2, range = 690, spread = 0.32, pellets = 1,
		ability = "pierce", groundWeight = 0, chestWeight = 4,
		description = "A picnic scout: wicker stock, gingham handguard, a flower on the muzzle and a butterfly on the scope.",
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
		-- Ratio (the gun rework): five hits with no gap over a second and a half mark the target for three
		-- seconds, and a marked target takes 1.12x from everyone. Damage comes down from 20 to 19 and the
		-- lifesteal goes: 19 x 12.5 = 237.5 body DPS, 266 once the mark is up, against the old 250.
		damage = 19, headshotMultiplier = 1.6, fireRate = 12.5, magSize = 36,
		reserveAmmo = 216, reloadTime = 1.85, range = 230, spread = 2.05, pellets = 1,
		ratio = { stacks = 5, window = 1.5, duration = 3, scale = 1.12 }, groundWeight = 0, chestWeight = 2,
		killEffect = "confetti",
		description = "L + RATIO: five quick hits and the target takes extra damage from everyone for three seconds.",
	},
	BackroomsBreacher = {
		name = "Porta Porta Bonk", rarity = "Epic", style = "shotgun",
		-- A door (the gun rework): the nine pellets land in the shape of a doorway -- the frame, the lintel, the
		-- knob -- scaled to the spread, so the pattern is the same every shot, and each hit shoves. Damage and
		-- pellets are untouched; the lifesteal goes for the shove.
		damage = 13, headshotMultiplier = 1.3, fireRate = 1.85, magSize = 8,
		reserveAmmo = 48, reloadTime = 2.85, range = 125, spread = 6, pellets = 9,
		pattern = "door", knockback = 14, groundWeight = 0, chestWeight = 2,
		killEffect = "ash",
		description = "Fluorescent-yellow breacher from the backrooms. Its pellets land in the shape of a door, and they shove.",
	},
	ReceiptPrinterLMG = {
		name = "Scontrino Infinito Brrrrr", rarity = "Legendary", style = "lmg",
		-- The total (the gun rework): every tenth hit in a run on one target (no gap over 0.8 s) prints a 30
		-- bonus. Damage comes down from 26 to 25 to pay for it; the kill still takes nine hits, 0.76 s.
		damage = 25, headshotMultiplier = 1.6, fireRate = 10.5, magSize = 70,
		reserveAmmo = 280, reloadTime = 4.1, range = 425, spread = 2.5, pellets = 1,
		ability = "goldRush", goldRushBonus = 100, groundWeight = 0, chestWeight = 0.65,
		receipt = { every = 10, bonus = 30, window = 0.8 },
		killEffect = "gold",
		description = "A till that fires. Every tenth hit in a row prints the total: 30 extra damage.",
	},
	SundaySpecial = {
		name = "Pranzo Della Nonna Bum", rarity = "Legendary", style = "cannon",
		damage = 87, headshotMultiplier = 2.2, fireRate = 1.35, magSize = 7,
		reserveAmmo = 35, reloadTime = 3.15, range = 720, spread = 0.65, pellets = 1,
		ability = "goldRush", goldRushBonus = 120, groundWeight = 0, chestWeight = 0.65,
		killEffect = "gold",
		description = "Heirloom lever rifle with deep walnut furniture and restrained brass trim.",
	},
-- Oliver, 2026-09-23 14:57: "make the mythic and secret guns slightly more common so that the rarest ones may
-- appear a few times per game". Mythic 0.18 -> 1.5 each and Secret 0.045 -> 0.8 each (chest weights): of a chest
-- gun roll that is about 1.1% Mythic and 0.6% Secret (was 0.13% and 0.03%), so roughly 2-3 Mythics and 1-2
-- Secrets across a full battle royale's chests. Legendary is untouched and still more common per gun.
	AuraAuditRifle = {
		name = "Occhietto Pium Pium", rarity = "Mythic", style = "rifle",
		damage = 29, headshotMultiplier = 1.9, fireRate = 8.0, magSize = 28,
		reserveAmmo = 168, reloadTime = 2.35, range = 470, spread = 1.05, pellets = 1,
		ability = "chain", chainRadius = 12, chainRatio = 0.22,
		-- The audit (the gun rework): every eighth hit in a run arcs to two more people near the target for 0.6
		-- of the hit. The target's own damage is untouched.
		audit = { every = 8, ratio = 0.6, targets = 2, window = 1 },
		groundWeight = 0, chestWeight = 1.5, killEffect = "shock",
		description = "The auditor: clipboard, checklist and stamp. Every eighth hit in a row arcs to two more people.",
	},
	QuietHours = {
		name = "Nanna Nanna Puff", rarity = "Mythic", style = "sniper",
		damage = 96, headshotMultiplier = 2.35, fireRate = 0.78, magSize = 4,
		reserveAmmo = 24, reloadTime = 3.3, range = 1350, spread = 0.06, pellets = 1,
		ability = "lifesteal", lifestealRatio = 0.16,
		groundWeight = 0, chestWeight = 1.5, killEffect = "freeze",
		description = "Long fluted bolt rifle with dark plum furniture and a moon insignia.",
	},
	AdminOverride = {
		name = "Capo Supremo Bonkolone", rarity = "Secret", style = "pistol",
		damage = 34, headshotMultiplier = 2.0, fireRate = 3.5, magSize = 10,
		reserveAmmo = 60, reloadTime = 1.7, range = 335, spread = 0.65, pellets = 1,
		-- Noclip (the gun rework): each round passes through one wall of the map for 0.7 of its damage.
		ability = "pierce", noclip = { walls = 1, scale = 0.7 }, groundWeight = 0, chestWeight = 0.8, killEffect = "vaporize",
		description = "The admin's sidearm, a terminal glowing down its slide. Its rounds noclip through one wall.",
	},
	FinalNotice = {
		name = "Ultimo Bum", rarity = "Secret", style = "rifle",
		-- Collection (the gun rework): every fifth hit in a run (no gap over 1.5 s) sets off a small blast on the
		-- target, 20 at its centre over 6 studs. Damage comes down from 33 to 31; the kill still takes seven
		-- hits, 0.92 s.
		damage = 31, headshotMultiplier = 1.9, fireRate = 6.5, magSize = 24,
		reserveAmmo = 144, reloadTime = 2.5, range = 490, spread = 1.15, pellets = 1,
		ability = "goldRush", goldRushBonus = 135,
		collect = { every = 5, damage = 20, radius = 6, window = 1.5 },
		groundWeight = 0, chestWeight = 0.8, killEffect = "gold",
		description = "The debt collector's AK. Every fifth hit in a row collects: a small blast on the target.",
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
