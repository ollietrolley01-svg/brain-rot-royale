-- Mounted vehicle weapons: what each armed vehicle model carries and how it behaves.
-- Oliver: "vehicles with different guns and explosive weapons on them".
--
--   VehicleWeaponData.ForModel(modelId)  -> spec or nil   (modelId: the VehicleModel attribute)
--   VehicleWeaponData.Weapons[id]        -> spec
--
-- The metal is in VehicleModels (Mounts); the server rules are in VehicleWeapons; the HUD and the
-- turret's swing are in VehicleWeaponClient. Two-wheelers carry nothing.
--
-- A spec:
--   id            the weapon id damage is credited with; the kill feed shows it as written
--                 (CombatService.DescribeWeapon falls back to the id), so it reads as a name
--   kind          "hitscan" (a bullet, CombatService's damage rules) or "round" (a real
--                 Ballistics round flown and burst by ProjectileService)
--   projectile    ("round") Ballistics.Rounds kind: "rocket" or "grenade", so blasts, wall damage,
--                 falloff, sounds and looks are exactly the hand launchers'
--   damage, range, spread, pellets, headshotMultiplier   ("hitscan") as WeaponData
--   splashRadius  ("round") blast radius
--   fireRate      shots a second, held to the same budget CombatService puts on a hand gun
--   magazine      shots before it runs dry
--   recharge      shots a second it gets back, once it has not fired for `rechargeDelay` seconds
--   yawLimit      degrees either side of straight ahead the mount turns (180: all the way round)
--   pitchMin, pitchMax   degrees below/above level the barrel tips (negative is down)
--   restPitch     where the barrel sits when nobody is aiming it
--   rarity        colours the tracer and flash like a gun of that rarity
--   hud           the short name on the ammo readout

local VehicleWeaponData = {}

VehicleWeaponData.Weapons = {
	-- Roof machine gun: fast, light, a long belt that cools back quickly.
	RotsterRoofGun = {
		id = "Rotster Roof Gun",
		hud = "ROOF GUN",
		kind = "hitscan",
		damage = 9,
		headshotMultiplier = 1.5,
		range = 320,
		spread = 1.6,
		fireRate = 10,
		magazine = 40,
		recharge = 12,
		rechargeDelay = 1.2,
		yawLimit = 180,
		pitchMin = -12,
		pitchMax = 40,
		restPitch = 0,
		rarity = "Uncommon",
	},
	-- Rocket pod: four rockets, a slow reload. The hand launcher's round and blast.
	RangerRocketPod = {
		id = "Ranger Rocket Pod",
		hud = "ROCKETS",
		kind = "round",
		projectile = "rocket",
		damage = 60,
		splashRadius = 12,
		headshotMultiplier = 1,
		fireRate = 1.6,
		magazine = 4,
		recharge = 0.5,
		rechargeDelay = 1.5,
		yawLimit = 150,
		pitchMin = -8,
		pitchMax = 30,
		restPitch = 4,
		rarity = "Epic",
	},
	-- Mortar: lobs 40mm grenades in an arc, three to a load.
	VanMortar = {
		id = "Sahur Van Mortar",
		hud = "MORTAR",
		kind = "round",
		projectile = "grenade",
		damage = 60,
		splashRadius = 13,
		headshotMultiplier = 1,
		fireRate = 1.4,
		magazine = 3,
		recharge = 0.4,
		rechargeDelay = 1.5,
		yawLimit = 180,
		pitchMin = 10,
		pitchMax = 60,
		restPitch = 30,
		rarity = "Rare",
	},
}

-- Vehicle model -> weapon. Must match VehicleModels.Mounts (the harness checks they agree).
VehicleWeaponData.ByModel = {
	Rotster = "RotsterRoofGun",
	CrocodiloRanger = "RangerRocketPod",
	SahurVan = "VanMortar",
}

function VehicleWeaponData.ForModel(modelId)
	local key = type(modelId) == "string" and VehicleWeaponData.ByModel[modelId] or nil
	return key and VehicleWeaponData.Weapons[key] or nil
end

-- The shots a mount holds at `now`, from what it held when it last fired (see VehicleWeapons).
-- Shared so the client's readout climbs back exactly as the server's count does.
function VehicleWeaponData.AmmoAt(spec, ammo, firedAt, now)
	local idle = now - (firedAt or -math.huge) - spec.rechargeDelay
	if idle <= 0 then
		return ammo
	end
	return math.min(spec.magazine, ammo + idle * spec.recharge)
end

-- Yaw and pitch (radians) that point the mount along `direction`, held inside its arc.
-- `direction` is in the mount's own space (front -Z, up +Y). Yaw is positive to the left, pitch
-- positive up, which is what CFrame.Angles(0, yaw, 0) and CFrame.Angles(pitch, 0, 0) do to the
-- two pivots. The server fires along it and the client swings the turret by it.
function VehicleWeaponData.ClampAim(spec, direction)
	local flat = math.sqrt(direction.X * direction.X + direction.Z * direction.Z)
	local yaw = math.atan2(-direction.X, -direction.Z)
	local pitch = math.atan2(direction.Y, flat)
	local yawLimit = math.rad(spec.yawLimit)
	yaw = math.clamp(yaw, -yawLimit, yawLimit)
	pitch = math.clamp(pitch, math.rad(spec.pitchMin), math.rad(spec.pitchMax))
	return yaw, pitch
end

return VehicleWeaponData
