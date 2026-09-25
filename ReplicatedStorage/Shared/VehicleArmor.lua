-- Vehicle health and armour: how much a vehicle can take, and how much of a hit reaches it (Oliver,
-- 2026-09-24: "make the cars have a balanced health pool that doesn't make them glass cannons but
-- doesn't make them juggernauts either").
--
--   VehicleArmor.HealthOf(modelId, kind)     -> the vehicle's full health
--   VehicleArmor.Scale(modelId, class)       -> what a hit of `class` is multiplied by on this vehicle
--   VehicleArmor.Protects(modelId, seatName) -> whether a rider in that seat is inside armour
--   VehicleArmor.CollisionScale(modelId, kind) -> what a crash's damage is multiplied by
--
-- WHERE THE NUMBERS COME FROM (measured 2026-09-24; tools/vehicle_ttk_check.py recomputes every one of
-- them from WeaponData and fails if a later edit pushes one out of its band).
--
-- Before this, a vehicle took NO damage from anything but crashing: a bullet stopped on the body like
-- on a wall and a blast only shoved it. 300 health (150 for a bike) only ever met crash damage.
--
-- What a vehicle faces, after MatchConfig.CombatDamageScale (0.92), with every shot landing (a car is
-- a 6 x 14-stud target: at 60-100 studs a Rare rifle's cone is under a stud). "Firing" is while the
-- trigger is held, "with reloads" is over whole magazines:
--   Rare rifle (Bananini Burst)        214 a second firing, 137.5 with reloads (27 rounds, 770 a magazine)
--   Rare rifles and marksman rifles    148 firing, 94 with reloads (the four of them, averaged)
--   SMG, Uncommon / Epic               168 / 206 firing, 98 / 127 with reloads
--   shotgun, Rare (every pellet)       172 firing, 116 with reloads
--   sniper, Rare                       71 firing, 49 with reloads
--   a rocket (Cappuccina, direct)      (68 + 25) x 0.92 = 85.6, before the class multiplier
--   frag / sticky beside the car       92 / 101, the same
--   the vehicles' own guns             roof gun 83 a second firing, heavy MG 90 (x1.6 on a vehicle),
--                                      the drivers' guns 58-59
--   a crash                            (speed lost - 18) x 1.5, set against 300 health (VehicleService)
-- (tools/vehicle_ttk_check.py prints the whole table, every class and tier, and what each vehicle
-- weapon does to a car.)
--
-- 2026-09-25: every time-to-kill here is x1.25 (Oliver: "increase ttk of players and vehicles 25%"), done
-- by MatchConfig.CombatDamageScale 0.92 -> 0.736, not by health: a car now takes 10-15 s of the rifle
-- and 3-4 rockets, an armoured car 6-8, and the figures below are the 09-24 ones before that scale.
-- The asks: a car dies to 8-12 s of one Rare rifle at mid range and to 2-3 rockets; a bike to less;
-- an armoured car has 2-2.5x a car's health, resists small arms by 40-50%, and takes explosives in
-- full, 5-6 rockets. Two of those can't both hold with a bullet's own damage: a car worth 10 s of a
-- rifle (about 1,500) is eighteen rockets. So a blast hits a vehicle 6.5 times as hard as it hits a
-- person (the "explosive" class) -- explosives are the counter to a vehicle -- and a bullet does its
-- own damage.
--
-- The ask's own figure of "2.5-4 magazines" does not fit its "8-12 seconds" with this game's rifles:
-- the Rare rifle's magazine is 27 rounds and 770 damage, so 10 seconds of it (a reload included) is
-- two magazines. The seconds are what a player feels, so the seconds are what the health is set to and
-- what the check holds; the magazines are printed alongside. The time is counted shot by shot (the
-- kill lands part way through a magazine), and every 27th shot adds a 2-second reload, so the health
-- sits where the kill lands inside the band, not on a reload's edge.
--
-- Results (Rare rifle seconds, magazines / rockets to kill):
--   Tralala GT 1400 -> 8.5 s, 1.85 / 3     Rotster 1500 -> 8.9 s, 1.96 / 3
--   Crocodilo Ranger 1600 -> 11.5 s, 2.1 / 3     Sahur Van 1650 -> 11.6 s, 2.15 / 3
--   bikes 600-660 -> 2.8-3.1 s / 2
--   Tartaruga Scout 3100 (2.0x the average car), 45% off bullets -> 40 s / 6
--   Camelo Carrier 3330 (2.2x), 50% off bullets -> 47 s / 6
-- A rocket at a car kills in three, not two: two would make a car worth less than a frag and a sticky
-- together. The armoured pair must both sit in 3,075-3,337 to be 2-2.5 cars AND 5-6 rockets, so they
-- differ in how much small arms they shrug off and how they drive, not in rockets.

-- WHO INSIDE CAN BE HURT. A car's glass lets a bullet through to whoever is behind it, as it always
-- has, and a blast reaches the riders as it reaches anyone. An armoured car's glass is armour
-- (VehicleModels names it Armor*, which stops shots): the driver and passengers are hit only through
-- the vehicle, and a blast reaches them at CabinBlast of its strength. The gunner of any vehicle stands
-- out in the open and is shot like anyone else.

local VehicleArmor = {}

-- What a hit is multiplied by against any vehicle, before its armour.
VehicleArmor.Classes = {
	-- A hand gun's bullet, and a light vehicle gun's: its own damage.
	bullet = 1,
	-- A heavy machine gun's round (VehicleWeaponData damageClass "heavy").
	heavy = 1.6,
	-- Every blast: rockets, grenades, mortar bombs, frags, stickies, explosive ammo, barrels.
	explosive = 6.5,
}

-- health: full health. resist: the share of a class the armour takes off. cabin "armored": the
-- driver and passengers are inside armour (Protects). impact: what crash damage is multiplied by.
VehicleArmor.Models = {
	TralalaGT = { health = 1400 },
	Rotster = { health = 1500 },
	CrocodiloRanger = { health = 1600 },
	SahurVan = { health = 1650 },
	BrrStreetfighter = { health = 600 },
	BananiniScoot = { health = 620 },
	PatapimScrambler = { health = 660 },
	TartarugaScout = { health = 3100, resist = { bullet = 0.45, heavy = 0.25 }, cabin = "armored", impact = 0.5 },
	CameloCarrier = { health = 3330, resist = { bullet = 0.5, heavy = 0.3 }, cabin = "armored", impact = 0.4 },
}

-- A model this table doesn't know (another tab's registered kind).
VehicleArmor.DefaultHealth = { car = 1400, bike = 640 }

-- The share of a blast that reaches a rider inside an armoured cabin.
VehicleArmor.CabinBlast = 0.25

-- The health crash damage was set against (VehicleService's COLLISION_*): a crash takes the same
-- share of a vehicle's health it always did, times the model's `impact`.
VehicleArmor.CrashBasis = { car = 300, bike = 150 }

function VehicleArmor.HealthOf(modelId, kind)
	local entry = VehicleArmor.Models[modelId]
	if entry then
		return entry.health
	end
	return VehicleArmor.DefaultHealth[kind == "bike" and "bike" or "car"]
end

function VehicleArmor.Scale(modelId, class)
	local base = VehicleArmor.Classes[class] or 1
	local entry = VehicleArmor.Models[modelId]
	local resist = entry and entry.resist and entry.resist[class] or 0
	return base * (1 - resist)
end

-- The gunner stands in the open; everyone else in an armoured cabin is behind armour.
function VehicleArmor.Protects(modelId, seatName)
	local entry = VehicleArmor.Models[modelId]
	return entry ~= nil and entry.cabin == "armored" and seatName ~= "GunnerSeat"
end

function VehicleArmor.CollisionScale(modelId, kind)
	local entry = VehicleArmor.Models[modelId]
	local basis = VehicleArmor.CrashBasis[kind == "bike" and "bike" or "car"]
	return VehicleArmor.HealthOf(modelId, kind) / basis * (entry and entry.impact or 1)
end

return VehicleArmor
