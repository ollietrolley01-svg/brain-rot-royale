-- Mounted vehicle weapons: what each armed vehicle model carries and how it behaves.
-- Oliver: "vehicles with different guns and explosive weapons on them".
--
--   VehicleWeaponData.ForModel(modelId, mount)  -> spec or nil   (modelId: the VehicleModel attribute;
--                                                 mount "turret" (the default) or "driver")
--   VehicleWeaponData.Weapons[id]               -> spec
--   VehicleWeaponData.Parts[mount], .Attributes[mount]   the part and attribute names of a mount
--
-- An armed vehicle carries two weapons (Oliver 09-24: "make the car guns controllable by a gunner seat"
-- and "make the drivers have their own gun that they can control"):
--   turret   ByModel: worked ONLY from the GunnerSeat. A driver alone in the vehicle cannot work it
--            (the gunner's seat has to be manned; VehicleWeapons.DrivenBy).
--   driver   DriverByModel: a short-arc gun at the front, worked only from the driving seat.
-- The metal is in VehicleModels (Mounts, DriverMounts); the server rules are in VehicleWeapons; the HUD,
-- the aim and the gunner's first-person view are in VehicleWeaponClient. Two-wheelers carry nothing.
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
--   damageClass   what a hit is to a vehicle (VehicleArmor.Classes): "bullet" (the default for a
--                 hitscan gun) or "heavy" (a heavy machine gun's round, which armour stops less of);
--                 a round's blast is always "explosive"
--   fireRate      shots a second, held to the same budget CombatService puts on a hand gun
--   magazine      shots before it runs dry
--   recharge      shots a second it gets back, once it has not fired for `rechargeDelay` seconds
--   overheat      (optional) a belt run dry overheats the gun: it will not fire again until it has
--                 cooled back up to this share of its magazine (the HUD's heat bar shows it)
--   yawLimit      degrees either side of straight ahead the mount turns (180: all the way round)
--   pitchMin, pitchMax   degrees below/above level the barrel tips (negative is down)
--   frontGuard    (optional) { arc, pitchMin }: within `arc` degrees of straight ahead the barrel
--                 does not go below `pitchMin`, so it never fires into its own cab
--   rearGuard     (optional) the same within `arc` degrees of straight BEHIND (a turret over the hull's
--                 own back end). Both are measured: tools/vehicle_weapons_gallery.lua's sweep casts the
--                 shot's first stretch at every pose and names what it meets.
--   restPitch     where the barrel sits when nobody is aiming it
--   slew          (turret) degrees a second the gunner can turn it (the first-person view rides it)
--   rarity        colours the tracer and flash like a gun of that rarity
--   hud           the short name on the ammo readout

local VehicleWeaponData = {}

VehicleWeaponData.Weapons = {
	-- Roof machine gun: fast and very powerful (Oliver, 2026-09-25), a long belt that cools back quickly.
	RotsterRoofGun = {
		id = "Rotster Roof Gun",
		hud = "ROOF GUN",
		kind = "hitscan",
		damage = 22,
		headshotMultiplier = 1.5,
		range = 320,
		spread = 1.1,
		fireRate = 12,
		magazine = 80,
		recharge = 18,
		rechargeDelay = 1.2,
		overheat = 0.5,
		yawLimit = 180,
		-- Widened for more range of motion (Jacob's playtest, 09-25; it was -12..25). Up: the spade grips
		-- first meet the roof panels at 39 (turned 20 or 70 degrees; tools/vehicle_models_axis_check.py's
		-- arc sweep), so 36. Down: the jacket meets the roof and spoiler at 22 (turned 50 or 130), but
		-- the sight posts come into the gunner's hip crosshair below 17 (tools/gunner_hip_view_check.py,
		-- PR #70's raised eye), so 17.
		pitchMin = -17,
		pitchMax = 36,
		restPitch = 0,
		slew = 320,
		rarity = "Uncommon",
	},
	-- Rocket pod: eight heavy rockets (twice a hand launcher's damage, a wider blast); a car in two.
	RangerRocketPod = {
		id = "Ranger Rocket Pod",
		hud = "ROCKETS",
		kind = "round",
		projectile = "rocket",
		damage = 130,
		splashRadius = 16,
		headshotMultiplier = 1,
		fireRate = 2.2,
		magazine = 8,
		recharge = 1.0,
		rechargeDelay = 1.5,
		-- All the way round now it stands in the middle of the bed on its pedestal.
		yawLimit = 180,
		-- Widened for more range of motion (09-25; it was -8..30): nothing on the truck stops the pod
		-- going up, and to the sides and back the rails and tailgate stop the shot at 28-43 down. The
		-- floor is the hip view's: below 12 down the launcher's bands and fuze box come into the gunner's
		-- hip crosshair (tools/gunner_hip_view_check.py, PR #70's raised eye).
		pitchMin = -12,
		pitchMax = 60,
		-- Over the cab the launcher's lowest tubes (7.45 up) must clear the cab roof and its light bar
		-- (top 7.35, 2.95 studs ahead of the tubes): 4 degrees up does it (VehicleModels, the Ranger).
		-- The roof's corners and the roll bar reach further out the lower the pod points: at -12 the shot
		-- meets the roll bar out to 55 degrees either side (the axis check's shot line), so the guard runs
		-- to 58, where the shot clears to 17 down.
		frontGuard = { arc = 58, pitchMin = 4 },
		restPitch = 4,
		slew = 200,
		rarity = "Epic",
	},
	-- Mortar: lobs heavy 40mm grenades in an arc, six to a load; a car in two.
	VanMortar = {
		id = "Sahur Van Mortar",
		hud = "MORTAR",
		kind = "round",
		projectile = "grenade",
		damage = 130,
		splashRadius = 18,
		headshotMultiplier = 1,
		fireRate = 1.8,
		magazine = 6,
		recharge = 0.8,
		rechargeDelay = 1.5,
		yawLimit = 180,
		pitchMin = 10,
		-- 75, not 60 (09-25): the steep end lobs onto targets close to the van. Nothing is above the tube.
		-- Not 80: a round bursts at Ballistics maxTime (5 s), and above ~76 on flat ground it is still up.
		pitchMax = 75,
		restPitch = 30,
		slew = 160,
		rarity = "Rare",
	},
	-- The scout car's heavy machine gun: harder hitting and steadier than the Rotster's, a heavier
	-- round that armour stops less of, and a belt that overheats if it is run dry.
	TartarugaHMG = {
		id = "Tartaruga HMG",
		hud = "HEAVY MG",
		kind = "hitscan",
		damageClass = "heavy",
		damage = 34,
		headshotMultiplier = 1.5,
		range = 420,
		spread = 0.7,
		fireRate = 9,
		magazine = 90,
		recharge = 18,
		rechargeDelay = 1.4,
		overheat = 0.5,
		yawLimit = 180,
		-- Widened (09-25; it was -8..25): the grips meet the cabin roof and shell at 38 up, and the barrel
		-- and shield meet them at 16 down (turned 30 degrees).
		pitchMin = -12,
		pitchMax = 34,
		restPitch = 0,
		slew = 260,
		rarity = "Epic",
	},
	-- The carrier's automatic grenade launcher: 40mm grenades fired flat and fast, sixteen to a can. Smaller
	-- blasts than the mortar's or a hand launcher's, many more of them.
	CameloGrenadeLauncher = {
		id = "Camelo Grenade Launcher",
		hud = "GRENADES",
		kind = "round",
		projectile = "grenade",
		damage = 75,
		splashRadius = 11,
		headshotMultiplier = 1,
		spread = 0.8,
		fireRate = 3,
		magazine = 16,
		recharge = 1.4,
		rechargeDelay = 1.6,
		yawLimit = 180,
		-- Widened (09-25; it was -8..30). Up: the grips meet the armour roof at 62, so 55. Down: the barrel
		-- meets the roof at 23 to the sides, but the sight comes into the gunner's hip crosshair below 10
		-- (tools/gunner_hip_view_check.py, PR #70's raised eye), so 10.
		pitchMin = -10,
		pitchMax = 55,
		-- Turned toward the back, the low shot goes into the carrier's own roof and rear hump: the floor
		-- clears 14 down at 150 degrees round, 12 at 155-163 and 6 at 180 (the axis check's shot line), so
		-- behind 150 the barrel stops 5 down.
		rearGuard = { arc = 30, pitchMin = -5 },
		restPitch = 2,
		slew = 180,
		rarity = "Epic",
	},

	-- The drivers' guns: machine guns at the front, a 20-degree arc either side and a little up and down,
	-- fired from the wheel. Very powerful, like every vehicle gun (Oliver, 2026-09-25): 200-220 damage a
	-- second, a Rare rifle's worth, and a car in 8-9 s (tools/vehicle_ttk_check.py holds the band). Each
	-- overheats when run dry.
	RotsterNoseGun = {
		id = "Rotster Nose Gun",
		hud = "NOSE GUN",
		kind = "hitscan",
		damage = 20,
		headshotMultiplier = 1.25,
		range = 260,
		spread = 1.5,
		fireRate = 11,
		magazine = 70,
		recharge = 18,
		rechargeDelay = 1.0,
		overheat = 0.5,
		yawLimit = 20,
		pitchMin = -5,
		pitchMax = 10,
		restPitch = 0,
		rarity = "Uncommon",
	},
	RangerBonnetGun = {
		id = "Ranger Bonnet Gun",
		hud = "BONNET GUN",
		kind = "hitscan",
		damage = 22,
		headshotMultiplier = 1.25,
		range = 280,
		spread = 1.4,
		fireRate = 10,
		magazine = 80,
		recharge = 18,
		rechargeDelay = 1.0,
		overheat = 0.5,
		yawLimit = 20,
		pitchMin = -5,
		pitchMax = 10,
		restPitch = 0,
		rarity = "Uncommon",
	},
	VanBumperGun = {
		id = "Sahur Bumper Gun",
		hud = "BUMPER GUN",
		kind = "hitscan",
		damage = 20,
		headshotMultiplier = 1.25,
		range = 260,
		spread = 1.5,
		fireRate = 11,
		magazine = 70,
		recharge = 18,
		rechargeDelay = 1.0,
		overheat = 0.5,
		yawLimit = 20,
		pitchMin = -5,
		pitchMax = 10,
		restPitch = 0,
		rarity = "Uncommon",
	},
	TartarugaBowGun = {
		id = "Tartaruga Bow Gun",
		hud = "BOW GUN",
		kind = "hitscan",
		damage = 22,
		headshotMultiplier = 1.25,
		range = 300,
		spread = 1.3,
		fireRate = 10,
		magazine = 80,
		recharge = 18,
		rechargeDelay = 1.0,
		overheat = 0.5,
		yawLimit = 20,
		pitchMin = -5,
		pitchMax = 10,
		restPitch = 0,
		rarity = "Rare",
	},
	CameloBonnetGun = {
		id = "Camelo Bonnet Gun",
		hud = "BONNET GUN",
		kind = "hitscan",
		damage = 22,
		headshotMultiplier = 1.25,
		range = 300,
		spread = 1.3,
		fireRate = 10,
		magazine = 80,
		recharge = 18,
		rechargeDelay = 1.0,
		overheat = 0.5,
		yawLimit = 20,
		pitchMin = -5,
		pitchMax = 10,
		restPitch = 0,
		rarity = "Rare",
	},
}

-- Vehicle model -> turret weapon. Must match VehicleModels.Mounts (the harness checks they agree).
VehicleWeaponData.ByModel = {
	Rotster = "RotsterRoofGun",
	CrocodiloRanger = "RangerRocketPod",
	SahurVan = "VanMortar",
	TartarugaScout = "TartarugaHMG",
	CameloCarrier = "CameloGrenadeLauncher",
}

-- Vehicle model -> the driver's gun. Must match VehicleModels.DriverMounts.
VehicleWeaponData.DriverByModel = {
	Rotster = "RotsterNoseGun",
	CrocodiloRanger = "RangerBonnetGun",
	SahurVan = "VanBumperGun",
	TartarugaScout = "TartarugaBowGun",
	CameloCarrier = "CameloBonnetGun",
}

-- The two mounts, their parts on the model and what the server publishes on it for each.
VehicleWeaponData.Mounts = { "turret", "driver" }
VehicleWeaponData.Parts = {
	turret = { yaw = "TurretYaw", pitch = "TurretPitch", muzzle = "TurretMuzzle" },
	driver = { yaw = "DriverGunYaw", pitch = "DriverGunPitch", muzzle = "DriverGunMuzzle" },
}
VehicleWeaponData.Attributes = {
	turret = { ammo = "WeaponAmmo", firedAt = "WeaponFiredAt", yaw = "AimYaw", pitch = "AimPitch", hot = "WeaponHot" },
	driver = { ammo = "DriverGunAmmo", firedAt = "DriverGunFiredAt", yaw = "DriverAimYaw", pitch = "DriverAimPitch", hot = "DriverGunHot" },
}

function VehicleWeaponData.ForModel(modelId, mount)
	local byModel = mount == "driver" and VehicleWeaponData.DriverByModel or VehicleWeaponData.ByModel
	local key = type(modelId) == "string" and byModel[modelId] or nil
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

-- Whether a mount holding `ammo` (as AmmoAt counts it) with its overheat flag `hot` may fire, and the
-- flag afterwards. A belt run dry overheats a gun with `overheat`; it stays hot until it has cooled
-- back up to that share of its magazine.
function VehicleWeaponData.Ready(spec, ammo, hot)
	if ammo < 1 then
		return false, spec.overheat ~= nil
	end
	if hot and spec.overheat and ammo < spec.magazine * spec.overheat then
		return false, true
	end
	return true, false
end

-- The lowest the barrel may go at `yaw` (radians): pitchMin, or the front guard's floor inside its arc.
function VehicleWeaponData.PitchFloor(spec, yaw)
	local guard = spec.frontGuard
	if guard and math.abs(yaw) < math.rad(guard.arc) then
		return math.rad(math.max(spec.pitchMin, guard.pitchMin))
	end
	local rear = spec.rearGuard
	if rear and math.abs(yaw) > math.pi - math.rad(rear.arc) then
		return math.rad(math.max(spec.pitchMin, rear.pitchMin))
	end
	return math.rad(spec.pitchMin)
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
	pitch = math.clamp(pitch, VehicleWeaponData.PitchFloor(spec, yaw), math.rad(spec.pitchMax))
	return yaw, pitch
end

-- A mount-space vector turned by the pitch pivot (about X), then the yaw pivot (about Y): what the
-- two Motor6D Transforms do to a point of the barrel.
function VehicleWeaponData.Turn(v, yaw, pitch)
	local cp, sp, cy, sy = math.cos(pitch), math.sin(pitch), math.cos(yaw), math.sin(yaw)
	local y1 = v.Y * cp - v.Z * sp
	local z1 = v.Y * sp + v.Z * cp
	return Vector3.new(v.X * cy + z1 * sy, y1, -v.X * sy + z1 * cy)
end

-- THE AIM, solved exactly, for the server's shot and the client's turret and sight alike.
--   frame    the yaw pivot's frame at rest (world); the yaw axis is its Y through its position
--   pivot    the pitch pivot at rest, in that frame (on its YZ plane: x = 0)
--   muzzle   the muzzle at rest, relative to the pitch pivot, in that frame (x = 0)
--   aim      the world point the shot should pass through
-- Returns yaw, pitch (radians, clamped to the arc), and the world origin (the muzzle at those angles)
-- and unit direction of the shot; nil for an aim on top of the mount.
-- Because the pitch pivot and the muzzle sit on the yaw pivot's YZ plane, the barrel's vertical plane
-- always holds the yaw axis: the yaw is the aim's own bearing about that axis, however far out in
-- front the pitch pivot is (the Rotster's pintle stands 1.75 ahead of its ring). The pitch is then
-- found in that plane so the line out of the MUZZLE -- not the pivot -- runs through the aim point:
-- a close target is hit where it is aimed at rather than a barrel's length beside it.
function VehicleWeaponData.Solve(spec, frame, pivot, muzzle, aim)
	local q = frame:PointToObjectSpace(aim)
	local flat = math.sqrt(q.X * q.X + q.Z * q.Z)
	if flat < 0.05 then
		return nil
	end
	local yaw = math.atan2(-q.X, -q.Z)
	-- The aim in the barrel's plane: straight ahead of the unturned mount, `flat` out.
	local toAim = Vector3.new(0, q.Y, -flat) - pivot
	if toAim.Magnitude < 1 then
		return nil
	end
	local pitch = math.atan2(toAim.Y, -toAim.Z)
	for _ = 1, 3 do
		local mouth = VehicleWeaponData.Turn(muzzle, 0, pitch)
		local fromMouth = toAim - mouth
		if fromMouth.Magnitude <= 1 then
			break
		end
		pitch = math.atan2(fromMouth.Y, -fromMouth.Z)
	end
	local yawLimit = math.rad(spec.yawLimit)
	yaw = math.clamp(yaw, -yawLimit, yawLimit)
	pitch = math.clamp(pitch, VehicleWeaponData.PitchFloor(spec, yaw), math.rad(spec.pitchMax))
	local origin = frame:PointToWorldSpace(VehicleWeaponData.Turn(pivot, yaw, 0) + VehicleWeaponData.Turn(muzzle, yaw, pitch))
	local direction = frame:VectorToWorldSpace(VehicleWeaponData.Turn(Vector3.new(0, 0, -1), yaw, pitch))
	return yaw, pitch, origin, direction
end

-- The stationary emplacements (Shared/MountedGunData, ServerScriptService MountedGuns) are turrets with
-- no vehicle under them: their weapons and model ids are merged in here so every reader of this table
-- finds them. Additive only; outside Roblox (the lupa checks) there is no `script` and this is skipped.
pcall(function()
	local MountedGunData = require(script.Parent:WaitForChild("MountedGunData"))
	for key, spec in pairs(MountedGunData.Weapons) do
		VehicleWeaponData.Weapons[key] = VehicleWeaponData.Weapons[key] or spec
	end
	for modelId, key in pairs(MountedGunData.ByModel) do
		VehicleWeaponData.ByModel[modelId] = VehicleWeaponData.ByModel[modelId] or key
	end
end)

return VehicleWeaponData
