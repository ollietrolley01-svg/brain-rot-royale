-- Mountable guns: the stationary emplacements that stand at every GunEmplacement in the team arena and
-- at strategic spots round the battle-royale map (Oliver, 2026-09-24: "add mountable guns around the
-- battleground and map", "put the mountable guns in strategic locations").
--
--   MountedGunData.Kinds[kind]        what each kind is: its model id, weapon, health, armour
--   MountedGunData.Weapons[key]       the weapon specs, in VehicleWeaponData's own spec shape
--   MountedGunData.ByModel[modelId]   the model id -> weapon key, merged into VehicleWeaponData.ByModel
--
-- AN EMPLACEMENT IS A TURRET WITH NO VEHICLE UNDER IT. Its model keeps the mount contract that
-- VehicleModels' turrets keep (TurretYaw / TurretPitch / TurretMuzzle, GunnerEye, GunnerSight, GripR,
-- GripL, ReloadHand, a Seat named GunnerSeat), carries a VehicleModel attribute and the ArmedVehicle tag,
-- and its weapon is registered in VehicleWeaponData. So the fire and aim remotes, the server's shot
-- (VehicleWeapons.Fire: the rate budget, the belt, the overheat, the arc clamp, the lag-compensated trace,
-- CombatService's damage rules), the gunner's first-person arms and sight (GunnerView), the HUD's ammo and
-- heat readout (VehicleWeaponClient) and the bots' trigger discipline all work it without a line of their
-- own changing. What is particular to an emplacement -- the prompt, mounting and dismounting, its health,
-- breaking and rebuilding, where they stand -- is ServerScriptService/Modules/MountedGuns.
--
-- BALANCE: VERY POWERFUL (Oliver, 2026-09-25: "make sure the mounted guns on the ground and the cars are
-- very powerful"). tools/mounted_guns_check.py holds every band; the numbers below are what it measured.
--   HMG     34 a round (heavy: 1.6x on vehicles), 10 a second, a 100-round belt that overheats if run dry:
--           313 damage a second after the damage scale, half again a Rare rifle's 214. 100 health in 4
--           rounds (0.3 s), 200 with a full shield in 7 (0.6 s). The average car in about 3 s, an armoured
--           car in 8-10 s. Spread 0.6 deg: effective out to about 290 studs.
--   CANNON  110 a grenade (splash 13), 1.4 a second, ten to a load. One direct hit kills a player without
--           a shield; two with one. The average car in 3 hits (about 1.4 s).
--   THE COUNTERPLAY is unchanged, and it is the whole answer to them: the arc is limited (the HMG +-60, the
--           cannon +-50), the gun turns slower than a player can strafe round it at close range, the gunner
--           is a whole body in the open from the sides and back (the shield covers the front only), and the
--           gun breaks: 6 rockets, or 6-7 s of a Rare rifle from the side (the shield takes a quarter of a
--           bullet). A broken gun throws its gunner off and is rebuilt where it stood after RebuildDelay.

local MountedGunData = {}

MountedGunData.Tag = "MountedGun"
-- The part name and tag the team battleground (TeamBattleground) marks an emplacement with: an anchored,
-- invisible Part whose CFrame is where the gun's base goes, front along its -Z.
MountedGunData.EmplacementTag = "GunEmplacement"

MountedGunData.Weapons = {
	EmplacementHMG = {
		id = "Rattlefang HMG",
		hud = "RATTLEFANG",
		kind = "hitscan",
		damageClass = "heavy",
		damage = 34,
		headshotMultiplier = 1.5,
		range = 450,
		spread = 0.6,
		fireRate = 10,
		magazine = 100,
		recharge = 16,
		rechargeDelay = 1.2,
		overheat = 0.5,
		yawLimit = 60,
		pitchMin = -15,
		pitchMax = 25,
		restPitch = 0,
		slew = 110,
		slewAccel = 480,
		infinitePool = true,
		rarity = "Epic",
	},
	EmplacementCannon = {
		id = "Boomba Grenade Cannon",
		hud = "BOOMBA",
		kind = "round",
		projectile = "grenade",
		damage = 110,
		splashRadius = 13,
		headshotMultiplier = 1,
		spread = 0.5,
		fireRate = 1.4,
		magazine = 10,
		recharge = 2,
		rechargeDelay = 1.0,
		yawLimit = 50,
		pitchMin = -10,
		pitchMax = 35,
		restPitch = 3,
		slew = 80,
		slewAccel = 300,
		infinitePool = true,
		rarity = "Epic",
	},
}

MountedGunData.Kinds = {
	hmg = {
		modelId = "MountedHMG",
		weapon = "EmplacementHMG",
		displayName = "Rattlefang HMG",
		health = 1300,
	},
	cannon = {
		modelId = "MountedCannon",
		weapon = "EmplacementCannon",
		displayName = "Boomba Grenade Cannon",
		health = 1500,
	},
}
MountedGunData.KindOrder = { "hmg", "cannon" }

MountedGunData.ByModel = {}
for _, kind in pairs(MountedGunData.Kinds) do
	MountedGunData.ByModel[kind.modelId] = kind.weapon
end

-- What a hit does to the gun, by VehicleArmor's damage classes (bullet, heavy, explosive): a gun is a
-- light thing next to a car, so a blast takes a real bite. `Shield` parts take ShieldScale of a bullet
-- (never of a blast): shooting the shield from the front is the slow way to break it.
MountedGunData.Classes = { bullet = 1, heavy = 1.3, explosive = 4 }
MountedGunData.ShieldScale = 0.25
-- ProjectileService hands hazards a blast at this multiple of its damage (its HAZARD_SCALE); the gun
-- takes the blast itself, so it divides that back out before its own explosive class.
MountedGunData.BlastIn = 1.5

-- Seconds a broken gun lies as a wreck before a new one is built where it stood.
MountedGunData.RebuildDelay = 75
-- Seconds from the start of a battle royale before any map gun can be manned: nobody lands under a gun
-- that is already firing (the team arena's guns are ready at once; its spawns are out of their arcs).
MountedGunData.LandingGrace = 40
-- Seconds between one player's mount attempts (the prompt is the only way on; this is its rate limit).
MountedGunData.MountCooldown = 1.0
-- How far from the seat a player may be when the prompt is triggered (the prompt's own reach plus slack).
MountedGunData.PromptDistance = 8
MountedGunData.MountReach = 14

-- The ids and weapon of the model a gun was built from, for anything holding only the model.
function MountedGunData.KindOf(modelId)
	for key, kind in pairs(MountedGunData.Kinds) do
		if kind.modelId == modelId then
			return key, kind
		end
	end
	return nil
end

function MountedGunData.SpecOf(kindKey)
	local kind = MountedGunData.Kinds[kindKey]
	return kind and MountedGunData.Weapons[kind.weapon] or nil
end

return MountedGunData
