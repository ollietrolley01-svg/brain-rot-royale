-- The metal of the mountable guns (Shared/MountedGunData says what they do, ServerScriptService's
-- MountedGuns where they stand and who works them).
--
--   MountedGunModels.Layout(kind)             -> layout   PURE: every part, pivot and marker, model space
--   MountedGunModels.Build(kind, cframe)      -> Model    built and placed, base anchored, ready to parent
--
-- Two kinds, both original:
--   hmg     the RATTLEFANG: a belt-fed heavy machine gun on a low tripod over a round skid plate, behind a
--           front arc of sandbags. Receiver and hinged top cover, a finned cooling jacket and a muzzle
--           brake, spade grips with a butterfly trigger, an ammo can on the left feeding a brass belt, a
--           charging handle on the right, an iron ring sight and a front post, and a shield with a sight
--           window and a barrel port, wings angled back. The T&E handwheel sits under the gun.
--   cannon  the BOOMBA: a belt-fed grenade cannon on a pedestal (a pintle column with gussets on a steel
--           skid) behind a full horseshoe of sandbags. A fat receiver, a recoil sleeve and a flared muzzle,
--           a can of 40mm grenades on the left feeding a belt of them, spade grips, a ladder range sight
--           with range bars, a tall front post, an elevation handwheel on the yoke, and a wider shield.
--
-- THE MOUNT CONTRACT is VehicleModels' own (see its "Mounted weapons" section), so VehicleWeapons,
-- VehicleWeaponClient and GunnerView work these exactly as they work a car's turret:
--   TurretYaw     pivot on the base, turns about its own Y        (Motor6D "Joint" from the base plate)
--   TurretPitch   pivot on TurretYaw, tips about its own X         (Motor6D "Joint" from TurretYaw)
--   TurretMuzzle  marker welded to TurretPitch at the mouth, on the pitch pivot's YZ plane
--   GunnerEye, GunnerSight, GripR, GripL, ReloadHand (all on TurretPitch: GunnerView lets an emplacement
--                 carry its eye on the pitch pivot, so the hip view rides the gun through the shield window)
--   GunnerSeat    a Seat (Gunner attribute true) where a standing gunner's eyes land on GunnerEye
-- and three more pivots of its own that only the clients move (MountedGunClient): BarrelRecoil (the
-- barrel and brake slam back a shot), BeltFeed (the belt steps into the feed tray) and BoltSlide (the
-- charging handle rides the bolt). Their parts are welded to them; TurretMuzzle is NOT, so the server's
-- shot never moves.
--
-- THE LAYOUT IS PURE (plain Lua and arithmetic, between the PURE markers): tools/mounted_guns_check.py
-- runs it under lupa and holds the model to its rules -- grounded, nothing floating, no part of the
-- swinging gun passing through the tripod or yoke anywhere in its arc, the sight line clear through the
-- shield's window, the grips in the arms' reach, the shield in front of the gunner.
-- Rotations are 3x3 matrices, row-major, whose columns are the part's own X, Y and Z axes (what
-- CFrame.new(x, y, z, r00 ... r22) takes). A cylinder's axis is its X, as in Roblox.

local MountedGunModels = {}

-- PURE BEGIN
local Pure = {}

local function M(r00, r01, r02, r10, r11, r12, r20, r21, r22)
	return { r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end
local IDENTITY = M(1, 0, 0, 0, 1, 0, 0, 0, 1)
local function mul(a, b)
	local out = {}
	for i = 0, 2 do
		for j = 0, 2 do
			out[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[j + 4] + a[i * 3 + 3] * b[j + 7]
		end
	end
	return out
end
local function rx(d)
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return M(1, 0, 0, 0, c, -s, 0, s, c)
end
local function ry(d)
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return M(c, 0, s, 0, 1, 0, -s, 0, c)
end
local function rz(d)
	local c, s = math.cos(math.rad(d)), math.sin(math.rad(d))
	return M(c, -s, 0, s, c, 0, 0, 0, 1)
end
-- CFrame.Angles(x, y, z) in degrees: Rx * Ry * Rz.
local function angles(x, y, z)
	return mul(mul(rx(x or 0), ry(y or 0)), rz(z or 0))
end
local function sub(a, b)
	return { a[1] - b[1], a[2] - b[2], a[3] - b[3] }
end
local function unit(v)
	local m = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	return { v[1] / m, v[2] / m, v[3] / m }, m
end
local function cross(a, b)
	return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
-- A frame whose X axis runs along `dir` (a cylinder between two points).
local function alongX(dir)
	local x = unit(dir)
	local helper = math.abs(x[2]) > 0.9 and { 1, 0, 0 } or { 0, 1, 0 }
	local z = unit(cross(x, helper))
	local y = cross(z, x)
	return M(x[1], y[1], z[1], x[2], y[2], z[2], x[3], y[3], z[3])
end
Pure.mul, Pure.angles, Pure.alongX = mul, angles, alongX

-- What each look is: colour, material and reflectance. Worn gunmetal, painted olive steel, brass, rubber,
-- canvas sandbags, a little rust and hazard paint so the thing reads at a distance and up close.
Pure.Looks = {
	gunmetal = { 54, 57, 62, "Metal", 0.06 },
	steel = { 98, 102, 108, "Metal", 0.1 },
	darksteel = { 40, 42, 46, "Metal", 0.04 },
	olive = { 86, 94, 58, "SmoothPlastic", 0.02 },
	olivedark = { 64, 70, 44, "SmoothPlastic", 0.02 },
	shield = { 92, 98, 72, "DiamondPlate", 0.02 },
	rust = { 124, 74, 44, "CorrodedMetal", 0 },
	brass = { 200, 158, 78, "Metal", 0.22 },
	copper = { 172, 104, 64, "Metal", 0.16 },
	rubber = { 28, 28, 30, "SmoothPlastic", 0 },
	canvas = { 176, 156, 114, "Fabric", 0 },
	canvasdark = { 150, 130, 94, "Fabric", 0 },
	twine = { 96, 80, 56, "Fabric", 0 },
	hazard = { 226, 178, 42, "SmoothPlastic", 0.02 },
	black = { 20, 20, 22, "SmoothPlastic", 0 },
	sightdot = { 255, 110, 40, "Neon", 0 },
}

local function builder()
	local L = { parts = {}, pivots = {}, markers = {} }
	L.group = "base"
	function L.add(name, shape, size, pos, m, look, opts)
		opts = opts or {}
		local part = {
			name = name, shape = shape, size = { size[1], size[2], size[3] }, pos = { pos[1], pos[2], pos[3] },
			m = m or IDENTITY, look = look, group = opts.group or L.group, collide = opts.collide == true,
			shield = opts.shield == true,
		}
		table.insert(L.parts, part)
		return part
	end
	function L.box(name, size, pos, look, opts)
		return L.add(name, "Block", size, pos, (opts and opts.m) or IDENTITY, look, opts)
	end
	-- A cylinder from a to b.
	function L.tube(name, a, b, diameter, look, opts)
		local dir, length = unit(sub(b, a))
		local mid = { (a[1] + b[1]) / 2, (a[2] + b[2]) / 2, (a[3] + b[3]) / 2 }
		return L.add(name, "Cylinder", { length, diameter, diameter }, mid, alongX(dir), look, opts)
	end
	function L.ball(name, d, pos, look, opts)
		return L.add(name, "Ball", { d, d, d }, pos, IDENTITY, look, opts)
	end
	-- A ring of `n` short boxes round an axis along Z (a sight ring) centred at `c`.
	function L.ringZ(name, c, radius, n, width, depth, look)
		for i = 1, n do
			local a = (i - 0.5) / n * 360
			local x, y = math.sin(math.rad(a)) * radius, math.cos(math.rad(a)) * radius
			local chord = 2 * radius * math.sin(math.pi / n) + 0.004
			L.add(name .. i, "Block", { chord, width, depth }, { c[1] + x, c[2] + y, c[3] }, rz(-a), look)
		end
	end
	function L.pivot(name, pos, parent)
		L.pivots[name] = { pos = { pos[1], pos[2], pos[3] }, parent = parent }
	end
	-- A palm frame (GunModels' keypoint convention): -Z along the fingers, +Y out of the back of the hand.
	function L.palm(name, pos, fingers, back, on)
		local z = unit({ -fingers[1], -fingers[2], -fingers[3] })
		local x = unit(cross(unit(back), z))
		local y = cross(z, x)
		L.markers[name] = { pos = pos, m = M(x[1], y[1], z[1], x[2], y[2], z[2], x[3], y[3], z[3]), on = on }
	end
	function L.mark(name, pos, on, m)
		L.markers[name] = { pos = pos, m = m or IDENTITY, on = on }
	end
	return L
end

-- Sandbags round the front: `layers` rows of bags on an arc of radius `radius`, from -`half` to +`half`
-- degrees either side of straight ahead (-Z), each bag a little turned and squashed so the wall reads as
-- stacked by hand, with its tied ends. Group base, collidable: this is low cover a player can crouch at.
local function sandbags(L, radius, half, layers, perRow)
	local bagH = 0.6
	for layer = 1, layers do
		local count = perRow - (layer - 1)
		local r = radius - (layer - 1) * 0.12
		for i = 1, count do
			local t = count == 1 and 0.5 or (i - 1) / (count - 1)
			local a = -half + t * 2 * half + ((layer % 2 == 0) and 0 or 0)
			if layer % 2 == 0 then
				a = -half * (count - 1) / count + t * 2 * half * (count - 1) / count
			end
			local jitter = ((i * 37 + layer * 11) % 7 - 3) * 1.1
			local x, z = math.sin(math.rad(a)) * r, -math.cos(math.rad(a)) * r
			local y = bagH / 2 + (layer - 1) * (bagH - 0.04)
			local frame = ry(-a + jitter)
			local look = ((i + layer) % 3 == 0) and "canvasdark" or "canvas"
			L.add(string.format("Sandbag%d_%d", layer, i), "Block", { 1.5, bagH, 0.86 }, { x, y, z }, frame, look,
				{ collide = true })
			-- The tied ends: a narrower, darker gather at each end of the bag.
			for _, e in ipairs({ -1, 1 }) do
				local ex, ez = frame[1] * e * 0.8, frame[7] * e * 0.8
				L.add(string.format("SandbagTie%d_%d%s", layer, i, e < 0 and "L" or "R"), "Block", { 0.14, bagH * 0.62, 0.56 },
					{ x + ex, y, z + ez }, frame, "twine")
			end
		end
	end
end

-- A spade-gripped back end: the backplate, two grips on arms, the butterfly trigger between them.
local function spadeGrips(L, y, zBack, halfX, gripLen)
	L.box("Backplate", { halfX * 2 + 0.04, 0.5, 0.1 }, { 0, y, zBack }, "gunmetal")
	L.box("BackplateRim", { halfX * 2 + 0.1, 0.06, 0.14 }, { 0, y + 0.27, zBack }, "darksteel")
	local zGrip = zBack + 0.3
	for _, s in ipairs({ -1, 1 }) do
		local n = s < 0 and "L" or "R"
		L.tube("GripArmTop" .. n, { s * halfX, y + 0.2, zBack + 0.04 }, { s * halfX, y + 0.2, zGrip + 0.04 }, 0.07, "gunmetal")
		L.tube("GripArmLow" .. n, { s * halfX, y - 0.2, zBack + 0.04 }, { s * halfX, y - 0.2, zGrip + 0.02 }, 0.07, "gunmetal")
		L.tube("Grip" .. n, { s * halfX, y - gripLen / 2, zGrip }, { s * halfX, y + gripLen / 2, zGrip + 0.03 }, 0.12, "rubber")
	end
	L.box("TriggerStem", { 0.06, 0.06, 0.16 }, { 0, y, zBack + 0.12 }, "gunmetal")
	L.box("Trigger", { halfX * 1.2, 0.09, 0.05 }, { 0, y, zBack + 0.2 }, "brass")
	return zGrip
end

-- The shield, on the pitch pivot so its window stays on the sight line: a centre plate built round a
-- barrel port and a sight window, wings either side angled back, a rim along the top, bolt heads, a
-- hazard band and some rust. `c` is the plate's middle at the bore's height; `bore` the bore's height;
-- `sight` the sight line's; `port` the barrel port's half size; `win` the window's half width and half
-- height. Every piece carries Shield (the damage rule in MountedGunData).
local function shield(L, z, bore, sight, width, bottom, top, port, win, wing)
	local t = 0.1
	local half = width / 2
	local o = { shield = true }
	local portTop, portBottom = bore + port, bore - port
	local winBottom, winTop = sight - win[2], sight + win[2]
	-- Left and right of the openings, full height.
	for _, s in ipairs({ -1, 1 }) do
		local inner = win[1]
		L.box("ShieldSide" .. (s < 0 and "L" or "R"), { half - inner, top - bottom, t }, { s * (inner + (half - inner) / 2), (top + bottom) / 2, z },
			"shield", o)
		-- Beside the barrel port, between the side plate and the port.
		L.box("ShieldPortCheek" .. (s < 0 and "L" or "R"), { inner - port, winBottom - bottom, t },
			{ s * (port + (inner - port) / 2), (winBottom + bottom) / 2, z }, "shield", o)
	end
	L.box("ShieldTop", { win[1] * 2, top - winTop, t }, { 0, (top + winTop) / 2, z }, "shield", o)
	L.box("ShieldBar", { port * 2, winBottom - portTop, t }, { 0, (winBottom + portTop) / 2, z }, "shield", o)
	L.box("ShieldBottom", { port * 2, portBottom - bottom, t }, { 0, (portBottom + bottom) / 2, z }, "shield", o)
	-- The rim along the top edge and the window's hood.
	L.box("ShieldRim", { width + 0.04, 0.08, t + 0.08 }, { 0, top + 0.03, z }, "darksteel", o)
	L.box("ShieldHood", { win[1] * 2 + 0.1, 0.05, 0.22 }, { 0, winTop + 0.025, z - 0.1 }, "darksteel", o)
	-- Wings angled 28 degrees back from each edge.
	for _, s in ipairs({ -1, 1 }) do
		local a = 28
		local cx = s * (half + math.cos(math.rad(a)) * wing / 2 - 0.02)
		local cz = z + math.sin(math.rad(a)) * wing / 2
		L.box("ShieldWing" .. (s < 0 and "L" or "R"), { wing, (top - bottom) * 0.92, t }, { cx, (top + bottom) / 2 - (top - bottom) * 0.04, cz },
			"shield", { shield = true, m = ry(-s * a) })
	end
	-- Bolt heads across the front, a hazard band low down and two rust streaks.
	local front = z - t / 2 - 0.035
	for i, x in ipairs({ -half + 0.18, -win[1] - 0.14, win[1] + 0.14, half - 0.18 }) do
		for j, y in ipairs({ bottom + 0.2, top - 0.2 }) do
			L.ball(string.format("ShieldBolt%d_%d", i, j), 0.1, { x, y, front + 0.01 }, "darksteel", o)
		end
	end
	for _, s in ipairs({ -1, 1 }) do
		L.box("ShieldHazard" .. (s < 0 and "L" or "R"), { half - win[1] - 0.3, 0.14, 0.02 },
			{ s * (win[1] + 0.15 + (half - win[1] - 0.3) / 2), bottom + 0.42, z - t / 2 - 0.012 }, "hazard", o)
	end
	L.box("ShieldRustA", { 0.22, 0.7, 0.02 }, { -half + 0.55, top - 0.55, z - t / 2 - 0.012 }, "rust", o)
	L.box("ShieldRustB", { 0.16, 0.45, 0.02 }, { half - 0.7, bottom + 0.75, z - t / 2 - 0.012 }, "rust", o)
end

-- A belt of rounds from `a` (the can's mouth) to `b` (the feed tray), `n` rounds, each `len` long and
-- `d` across, on the BeltFeed pivot, over a dark link strip.
local function belt(L, a, b, n, len, d, tip)
	local dir, length = unit(sub(b, a))
	L.tube("BeltLink", a, b, 0.05, "darksteel", { group = "belt" })
	for i = 1, n do
		local t = (i - 0.5) / n
		local p = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t + d * 0.45, a[3] + (b[3] - a[3]) * t }
		local fromA = { p[1], p[2], p[3] - len / 2 }
		local toB = { p[1], p[2], p[3] + len / 2 }
		L.tube("BeltRound" .. i, fromA, toB, d, "brass", { group = "belt" })
		if tip then
			L.tube("BeltTip" .. i, { p[1], p[2], p[3] - len / 2 - 0.08 }, { p[1], p[2], p[3] - len / 2 + 0.01 }, d * 0.8, tip,
				{ group = "belt" })
		end
	end
	return length, dir
end

--------------------------------------------------------------------------------
-- The Rattlefang HMG
--------------------------------------------------------------------------------

local function hmg()
	local L = builder()
	-- Heights from the floor: a standing gunner's eyes (GunnerEye, on the sight line) at 5.1.
	local YAW = 3.44
	local PITCH = 4.42
	local BORE = PITCH + 0.1
	local SIGHT = BORE + 0.46
	L.eyeZ = 2.0

	-- BASE: skid plate, tripod, sandbags, a spare can.
	L.group = "base"
	L.add("BasePlate", "Cylinder", { 0.25, 2.6, 2.6 }, { 0, 0.125, 0 }, rz(90), "darksteel", { collide = true })
	L.add("BasePlateRim", "Cylinder", { 0.08, 2.7, 2.7 }, { 0, 0.21, 0 }, rz(90), "steel")
	L.add("TripodHub", "Cylinder", { 0.36, 0.52, 0.52 }, { 0, YAW - 0.2, 0 }, rz(90), "gunmetal")
	L.add("TripodHubCollar", "Cylinder", { 0.1, 0.62, 0.62 }, { 0, YAW - 0.33, 0 }, rz(90), "steel")
	local feet = { { -0.82, -0.66 }, { 0.82, -0.66 }, { 0, 1.02 } }
	for i, f in ipairs(feet) do
		local top = { f[1] * 0.16, YAW - 0.34, f[2] * 0.16 }
		local foot = { f[1], 0.34, f[2] }
		L.tube("TripodLeg" .. i, top, foot, 0.15, "gunmetal")
		local mid = { top[1] + (foot[1] - top[1]) * 0.42, top[2] + (foot[2] - top[2]) * 0.42, top[3] + (foot[3] - top[3]) * 0.42 }
		L.tube("TripodSleeve" .. i, top, mid, 0.21, "olive")
		L.tube("TripodClamp" .. i, { mid[1], mid[2] + 0.05, mid[3] }, { mid[1], mid[2] - 0.05, mid[3] }, 0.27, "steel")
		L.box("TripodFoot" .. i, { 0.42, 0.1, 0.42 }, { foot[1], 0.3, foot[2] }, "darksteel")
		L.ball("TripodFootBolt" .. i, 0.12, { foot[1], 0.37, foot[2] }, "steel")
	end
	sandbags(L, 2.25, 70, 2, 5)
	L.box("SpareCan", { 0.4, 0.46, 0.72 }, { -1.46, 0.23, 0.45 }, "olive", { m = ry(18), collide = true })
	L.box("SpareCanLid", { 0.44, 0.06, 0.76 }, { -1.46, 0.49, 0.45 }, "olivedark", { m = ry(18) })
	L.box("SpareCanStripe", { 0.02, 0.08, 0.5 }, { -1.67, 0.3, 0.38 }, "hazard", { m = ry(18) })

	-- YAW: pintle, traverse ring, yoke, T&E wheel.
	L.pivot("TurretYaw", { 0, YAW, 0 }, nil)
	L.group = "yaw"
	L.add("TraverseRing", "Cylinder", { 0.08, 0.72, 0.72 }, { 0, YAW + 0.05, 0 }, rz(90), "steel")
	L.add("Pintle", "Cylinder", { 0.36, 0.34, 0.34 }, { 0, YAW + 0.26, 0 }, rz(90), "gunmetal")
	L.box("YokeBase", { 0.9, 0.12, 0.36 }, { 0, YAW + 0.48, 0 }, "gunmetal")
	for _, s in ipairs({ -1, 1 }) do
		L.box("YokeArm" .. (s < 0 and "L" or "R"), { 0.08, PITCH + 0.06 - (YAW + 0.42), 0.34 }, { s * 0.41, (PITCH + 0.06 + YAW + 0.42) / 2, 0 }, "gunmetal")
		L.add("TrunnionCap" .. (s < 0 and "L" or "R"), "Cylinder", { 0.06, 0.2, 0.2 }, { s * 0.48, PITCH, 0 }, IDENTITY, "steel")
	end
	L.box("TEBracket", { 0.14, 0.1, 0.42 }, { 0, YAW + 0.48, 0.38 }, "gunmetal")
	L.tube("TEScrew", { 0, YAW + 0.1, 0.55 }, { 0, YAW + 0.43, 0.55 }, 0.1, "steel")
	L.add("TEWheel", "Cylinder", { 0.05, 0.4, 0.4 }, { 0, YAW + 0.2, 0.55 }, rz(90), "darksteel")
	L.tube("TEWheelKnob", { 0.15, YAW + 0.2, 0.55 }, { 0.15, YAW + 0.05, 0.55 }, 0.06, "rubber")
	L.tube("TraverseLock", { 0.17, YAW + 0.3, 0.05 }, { 0.44, YAW + 0.3, 0.05 }, 0.06, "steel")
	L.ball("TraverseLockKnob", 0.13, { 0.48, YAW + 0.3, 0.05 }, "rubber")
	L.mark("GunnerEye", { 0, SIGHT + 0.04, L.eyeZ }, "TurretPitch")

	-- PITCH: the gun.
	L.pivot("TurretPitch", { 0, PITCH, 0 }, "TurretYaw")
	L.group = "pitch"
	L.tube("TrunnionPin", { -0.45, PITCH, 0 }, { 0.45, PITCH, 0 }, 0.12, "steel")
	L.box("Cradle", { 0.44, 0.1, 0.76 }, { 0, PITCH - 0.19, 0.1 }, "darksteel")
	for _, s in ipairs({ -1, 1 }) do
		L.box("CradleCheek" .. (s < 0 and "L" or "R"), { 0.05, 0.34, 0.5 }, { s * 0.25, PITCH - 0.03, 0 }, "darksteel")
	end
	L.box("Receiver", { 0.44, 0.46, 1.5 }, { 0, BORE - 0.03, 0.25 }, "gunmetal")
	L.box("ReceiverRib", { 0.46, 0.06, 1.2 }, { 0, BORE - 0.16, 0.3 }, "darksteel")
	L.box("TopCover", { 0.48, 0.08, 0.95 }, { 0, BORE + 0.24, 0.32 }, "steel")
	L.tube("CoverHinge", { -0.24, BORE + 0.24, -0.18 }, { 0.24, BORE + 0.24, -0.18 }, 0.09, "darksteel")
	L.box("CoverLatch", { 0.2, 0.06, 0.1 }, { 0, BORE + 0.3, 0.76 }, "darksteel")
	L.box("FeedTray", { 0.12, 0.12, 0.34 }, { -0.28, BORE + 0.1, 0.05 }, "darksteel")
	L.box("EjectPort", { 0.03, 0.13, 0.32 }, { 0.235, BORE - 0.02, 0.05 }, "black")
	local zGrip = spadeGrips(L, BORE - 0.02, 1.05, 0.26, 0.46)
	L.tube("Jacket", { 0, BORE, -0.5 }, { 0, BORE, -2.08 }, 0.34, "gunmetal")
	for i = 0, 6 do
		local z = -1.03 - i * 0.15
		L.tube("CoolingFin" .. i, { 0, BORE, z - 0.025 }, { 0, BORE, z + 0.025 }, 0.46, "darksteel")
	end
	L.tube("JacketBand", { 0, BORE, -2.02 }, { 0, BORE, -2.1 }, 0.4, "steel")
	L.tube("CarryHandle", { -0.3, BORE + 0.05, -1.1 }, { -0.3, BORE + 0.05, -1.62 }, 0.08, "rubber")
	L.box("CarryHandlePostA", { 0.16, 0.05, 0.05 }, { -0.21, BORE + 0.05, -1.1 }, "darksteel")
	L.box("CarryHandlePostB", { 0.16, 0.05, 0.05 }, { -0.21, BORE + 0.05, -1.62 }, "darksteel")
	-- Iron sights: a ring at the back, a post in ears at the front, both centred on the sight line.
	L.box("FrontSightBase", { 0.16, SIGHT - 0.14 - (BORE + 0.15), 0.12 }, { 0, (SIGHT - 0.14 + BORE + 0.15) / 2, -1.96 }, "darksteel")
	L.box("FrontSightPost", { 0.035, 0.16, 0.04 }, { 0, SIGHT - 0.07, -1.96 }, "black")
	for _, s in ipairs({ -1, 1 }) do
		L.box("FrontSightEar" .. (s < 0 and "L" or "R"), { 0.03, 0.2, 0.08 }, { s * 0.1, SIGHT - 0.06, -1.96 }, "darksteel")
	end
	L.box("RingSightStem", { 0.05, SIGHT - 0.12 - (BORE + 0.28), 0.05 }, { 0, (SIGHT - 0.12 + BORE + 0.28) / 2, 0.92 }, "darksteel")
	L.ringZ("RingSight", { 0, SIGHT, 0.92 }, 0.12, 12, 0.022, 0.03, "black")
	L.box("RearSightLeaf", { 0.2, 0.04, 0.1 }, { 0, BORE + 0.3, 0.92 }, "darksteel")
	-- The ammo can on the left and the belt into the feed tray.
	L.box("AmmoBracket", { 0.28, 0.08, 0.3 }, { -0.4, BORE + 0.09, 0.1 }, "darksteel")
	L.box("AmmoCan", { 0.4, 0.5, 0.72 }, { -0.74, BORE - 0.1, 0.1 }, "olive")
	L.box("AmmoCanLid", { 0.44, 0.06, 0.76 }, { -0.74, BORE + 0.18, 0.1 }, "olivedark")
	L.box("AmmoCanHandle", { 0.06, 0.05, 0.3 }, { -0.74, BORE + 0.235, 0.1 }, "rubber")
	L.box("AmmoCanStripe", { 0.02, 0.08, 0.5 }, { -0.95, BORE - 0.06, 0.1 }, "hazard")
	L.box("AmmoCanRust", { 0.02, 0.16, 0.14 }, { -0.95, BORE - 0.26, 0.34 }, "rust")
	L.pivot("BeltFeed", { -0.45, BORE + 0.2, 0.08 }, "TurretPitch")
	belt(L, { -0.62, BORE + 0.2, 0.08 }, { -0.3, BORE + 0.17, 0.06 }, 4, 0.26, 0.07)
	-- The charging handle rides the bolt.
	L.pivot("BoltSlide", { 0.28, BORE + 0.06, -0.2 }, "TurretPitch")
	L.box("ChargingHandle", { 0.1, 0.08, 0.26 }, { 0.28, BORE + 0.06, -0.2 }, "steel", { group = "bolt" })
	L.ball("ChargingKnob", 0.13, { 0.35, BORE + 0.06, -0.3 }, "rubber", { group = "bolt" })
	-- Barrel and brake on the recoil slide.
	L.pivot("BarrelRecoil", { 0, BORE, -2.1 }, "TurretPitch")
	L.tube("Barrel", { 0, BORE, -2.06 }, { 0, BORE, -2.88 }, 0.17, "darksteel", { group = "recoil" })
	L.tube("MuzzleBrake", { 0, BORE, -2.86 }, { 0, BORE, -3.16 }, 0.28, "gunmetal", { group = "recoil" })
	for i, z in ipairs({ -2.94, -3.06 }) do
		L.box("BrakePort" .. i, { 0.3, 0.07, 0.05 }, { 0, BORE, z }, "black", { group = "recoil" })
	end
	-- The shield's top is just over the gunner's eyes and its window a wide slit on the sight line: the
	-- gunner sees through it and over it, and it covers them from the front up to the eyes.
	shield(L, -0.86, BORE, SIGHT, 3.2, PITCH - 0.95, SIGHT + 0.42, 0.22, { 0.9, 0.2 }, 0.9)
	L.muzzle = { 0, BORE, -3.18 }
	-- The gunner's markers: the eye behind the ring, the palms on the spade grips, the reload hand on the can.
	L.mark("GunnerSight", { 0, SIGHT, 1.8 }, "TurretPitch")
	L.palm("GripR", { 0.26, BORE - 0.02, zGrip + 0.02 }, { -0.35, 0, -1 }, { 1, 0.15, 0.3 }, "TurretPitch")
	L.palm("GripL", { -0.26, BORE - 0.02, zGrip + 0.02 }, { 0.35, 0, -1 }, { -1, 0.15, 0.3 }, "TurretPitch")
	L.palm("ReloadHand", { -0.66, BORE + 0.3, 0.12 }, { 0.2, -0.3, -1 }, { 0.1, 1, 0 }, "TurretPitch")
	L.mark("EjectPoint", { 0.26, BORE - 0.02, 0.05 }, "TurretPitch")
	L.mark("SteamPoint", { 0, BORE + 0.2, -1.5 }, "TurretPitch")
	L.heatParts = { "Jacket", "Barrel", "JacketBand" }
	L.promptAt = { 0, 3.0, 1.9 }
	return L
end

--------------------------------------------------------------------------------
-- The Boomba grenade cannon
--------------------------------------------------------------------------------

local function cannon()
	local L = builder()
	local YAW = 3.4
	local PITCH = 4.28
	local BORE = PITCH + 0.12
	local SIGHT = BORE + 0.58
	L.eyeZ = 2.05

	L.group = "base"
	L.box("BaseSkid", { 2.7, 0.22, 2.7 }, { 0, 0.11, 0 }, "darksteel", { collide = true })
	for _, s in ipairs({ -1, 1 }) do
		L.box("SkidRunner" .. (s < 0 and "L" or "R"), { 0.2, 0.14, 2.9 }, { s * 1.2, 0.07, 0 }, "steel", { collide = true })
	end
	for i, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
		L.ball("SkidBolt" .. i, 0.14, { c[1] * 1.12, 0.24, c[2] * 1.12 }, "steel")
	end
	L.box("SkidRust", { 0.6, 0.02, 0.4 }, { 0.7, 0.225, -0.8 }, "rust")
	L.add("PedestalFoot", "Cylinder", { 0.2, 1.0, 1.0 }, { 0, 0.32, 0 }, rz(90), "gunmetal")
	L.tube("Pedestal", { 0, 0.4, 0 }, { 0, YAW - 0.12, 0 }, 0.56, "olive")
	L.add("PedestalCollar", "Cylinder", { 0.14, 0.72, 0.72 }, { 0, YAW - 0.1, 0 }, rz(90), "steel")
	for i = 0, 3 do
		local a = i * 90 + 45
		local x, z = math.sin(math.rad(a)), -math.cos(math.rad(a))
		L.add("Gusset" .. i, "Wedge", { 0.08, 0.7, 0.34 }, { x * 0.44, 0.77, z * 0.44 }, ry(-a + 180), "olivedark")
	end
	sandbags(L, 2.45, 95, 3, 7)
	L.box("SpareCrate", { 0.8, 0.5, 0.6 }, { 1.62, 0.25, 0.9 }, "olive", { m = ry(-24), collide = true })
	L.box("SpareCrateLid", { 0.84, 0.06, 0.64 }, { 1.62, 0.53, 0.9 }, "olivedark", { m = ry(-24) })

	L.pivot("TurretYaw", { 0, YAW, 0 }, nil)
	L.group = "yaw"
	L.add("Turntable", "Cylinder", { 0.1, 1.0, 1.0 }, { 0, YAW + 0.06, 0 }, rz(90), "steel")
	L.box("YokeBase", { 1.24, 0.14, 0.52 }, { 0, YAW + 0.18, 0 }, "gunmetal")
	for _, s in ipairs({ -1, 1 }) do
		L.box("YokeArm" .. (s < 0 and "L" or "R"), { 0.1, PITCH + 0.08 - (YAW + 0.11), 0.46 }, { s * 0.57, (PITCH + 0.08 + YAW + 0.11) / 2, 0 }, "gunmetal")
		L.add("TrunnionCap" .. (s < 0 and "L" or "R"), "Cylinder", { 0.08, 0.26, 0.26 }, { s * 0.66, PITCH, 0 }, IDENTITY, "steel")
	end
	-- The elevation handwheel outside the right arm, with its spokes and a knob.
	L.tube("ElevationShaft", { 0.62, YAW + 0.5, 0.1 }, { 0.8, YAW + 0.5, 0.1 }, 0.08, "steel")
	L.add("ElevationWheel", "Cylinder", { 0.05, 0.56, 0.56 }, { 0.82, YAW + 0.5, 0.1 }, IDENTITY, "darksteel")
	L.tube("ElevationKnob", { 0.84, YAW + 0.7, 0.1 }, { 0.98, YAW + 0.7, 0.1 }, 0.07, "rubber")
	L.mark("GunnerEye", { 0, SIGHT + 0.02, L.eyeZ }, "TurretPitch")

	L.pivot("TurretPitch", { 0, PITCH, 0 }, "TurretYaw")
	L.group = "pitch"
	L.tube("TrunnionPin", { -0.64, PITCH, 0 }, { 0.64, PITCH, 0 }, 0.16, "steel")
	for _, s in ipairs({ -1, 1 }) do
		L.box("CradleCheek" .. (s < 0 and "L" or "R"), { 0.06, 0.42, 0.6 }, { s * 0.42, PITCH, 0.02 }, "darksteel")
	end
	L.box("Receiver", { 0.72, 0.62, 1.3 }, { 0, BORE - 0.02, 0.24 }, "olive")
	L.box("ReceiverBelly", { 0.6, 0.12, 1.0 }, { 0, BORE - 0.38, 0.26 }, "olivedark")
	L.box("TopCover", { 0.74, 0.08, 0.9 }, { 0, BORE + 0.33, 0.3 }, "olivedark")
	L.tube("CoverHinge", { -0.36, BORE + 0.33, -0.16 }, { 0.36, BORE + 0.33, -0.16 }, 0.1, "darksteel")
	L.box("FeedTray", { 0.16, 0.16, 0.4 }, { -0.43, BORE + 0.12, 0.05 }, "darksteel")
	L.box("EjectPort", { 0.03, 0.18, 0.36 }, { 0.375, BORE - 0.05, 0.1 }, "black")
	L.box("ReceiverRust", { 0.02, 0.2, 0.3 }, { 0.376, BORE - 0.22, 0.6 }, "rust")
	local zGrip = spadeGrips(L, BORE - 0.02, 0.94, 0.3, 0.5)
	L.tube("RecoilSleeve", { 0, BORE, -0.42 }, { 0, BORE, -1.08 }, 0.46, "gunmetal")
	L.tube("SleeveBandA", { 0, BORE, -0.55 }, { 0, BORE, -0.62 }, 0.52, "steel")
	L.tube("SleeveBandB", { 0, BORE, -0.92 }, { 0, BORE, -0.99 }, 0.52, "steel")
	-- Sights: a ladder range sight at the back with range bars, a tall post at the front.
	for _, s in ipairs({ -1, 1 }) do
		L.box("LadderRail" .. (s < 0 and "L" or "R"), { 0.03, 0.46, 0.03 }, { s * 0.13, BORE + 0.6, 0.78 }, "darksteel")
	end
	L.box("LadderFoot", { 0.32, 0.05, 0.1 }, { 0, BORE + 0.39, 0.78 }, "darksteel")
	for i, y in ipairs({ SIGHT - 0.14, SIGHT + 0.03, SIGHT + 0.14 }) do
		L.box("RangeBar" .. i, { 0.08, 0.018, 0.02 }, { -0.19, y, 0.78 }, "hazard")
		L.box("RangeBarR" .. i, { 0.08, 0.018, 0.02 }, { 0.19, y, 0.78 }, "hazard")
	end
	L.ringZ("Aperture", { 0, SIGHT, 0.78 }, 0.07, 10, 0.02, 0.025, "black")
	L.box("ApertureSlide", { 0.2, 0.03, 0.03 }, { 0, SIGHT - 0.085, 0.78 }, "darksteel")
	L.box("FrontPostBase", { 0.12, SIGHT - 0.1 - (BORE + 0.2), 0.1 }, { 0, (SIGHT - 0.1 + BORE + 0.2) / 2, -1.7 }, "darksteel")
	L.box("FrontPost", { 0.035, 0.12, 0.035 }, { 0, SIGHT - 0.05, -1.7 }, "black")
	L.ball("FrontPostDot", 0.03, { 0, SIGHT, -1.72 }, "sightdot")
	-- The can of 40mm grenades on the left and their belt.
	L.box("AmmoBracket", { 0.34, 0.1, 0.2 }, { -0.66, PITCH + 0.3, 0.02 }, "darksteel")
	L.box("AmmoCan", { 0.5, 0.62, 0.78 }, { -1.02, BORE - 0.08, 0.12 }, "olive")
	L.box("AmmoCanLid", { 0.54, 0.07, 0.82 }, { -1.02, BORE + 0.265, 0.12 }, "olivedark")
	L.box("AmmoCanHandle", { 0.06, 0.05, 0.34 }, { -1.02, BORE + 0.33, 0.12 }, "rubber")
	L.box("AmmoCanStripe", { 0.02, 0.1, 0.56 }, { -1.28, BORE - 0.02, 0.12 }, "hazard")
	L.pivot("BeltFeed", { -0.66, BORE + 0.27, 0.1 }, "TurretPitch")
	belt(L, { -0.9, BORE + 0.28, 0.1 }, { -0.47, BORE + 0.24, 0.06 }, 3, 0.26, 0.15, "olivedark")
	L.pivot("BoltSlide", { 0.42, BORE + 0.12, -0.1 }, "TurretPitch")
	L.box("ChargingHandle", { 0.12, 0.1, 0.3 }, { 0.43, BORE + 0.12, -0.1 }, "steel", { group = "bolt" })
	L.ball("ChargingKnob", 0.16, { 0.5, BORE + 0.12, -0.22 }, "rubber", { group = "bolt" })
	L.pivot("BarrelRecoil", { 0, BORE, -1.1 }, "TurretPitch")
	L.tube("Barrel", { 0, BORE, -1.06 }, { 0, BORE, -2.02 }, 0.3, "darksteel", { group = "recoil" })
	L.tube("MuzzleCollar", { 0, BORE, -1.98 }, { 0, BORE, -2.08 }, 0.38, "steel", { group = "recoil" })
	L.tube("MuzzleFlare", { 0, BORE, -2.06 }, { 0, BORE, -2.34 }, 0.44, "gunmetal", { group = "recoil" })
	L.tube("MuzzleBore", { 0, BORE, -2.3 }, { 0, BORE, -2.36 }, 0.3, "black", { group = "recoil" })
	shield(L, -0.78, BORE, SIGHT, 3.4, PITCH - 0.72, SIGHT + 0.42, 0.28, { 0.9, 0.2 }, 1.0)
	L.muzzle = { 0, BORE, -2.38 }
	L.mark("GunnerSight", { 0, SIGHT, 1.75 }, "TurretPitch")
	L.palm("GripR", { 0.3, BORE - 0.02, zGrip + 0.02 }, { -0.35, 0, -1 }, { 1, 0.15, 0.3 }, "TurretPitch")
	L.palm("GripL", { -0.3, BORE - 0.02, zGrip + 0.02 }, { 0.35, 0, -1 }, { -1, 0.15, 0.3 }, "TurretPitch")
	L.palm("ReloadHand", { -0.95, BORE + 0.4, 0.15 }, { 0.2, -0.3, -1 }, { 0.1, 1, 0 }, "TurretPitch")
	L.mark("EjectPoint", { 0.4, BORE - 0.05, 0.1 }, "TurretPitch")
	L.mark("SteamPoint", { 0, BORE + 0.25, -0.8 }, "TurretPitch")
	L.heatParts = { "Barrel", "RecoilSleeve", "MuzzleFlare" }
	L.promptAt = { 0, 3.0, 1.95 }
	return L
end

Pure.Makers = { hmg = hmg, cannon = cannon }

-- Which pivot each part group welds to.
Pure.GroupPivot = { base = false, yaw = "TurretYaw", pitch = "TurretPitch", recoil = "BarrelRecoil", belt = "BeltFeed",
	bolt = "BoltSlide" }
-- What each group swings with, for the checks: the groups that ride the pitch pivot.
Pure.RidesPitch = { pitch = true, recoil = true, belt = true, bolt = true }

-- The seat a standing gunner stands in: where VehicleModels puts a seat for an eye (RIDER_ROOT 1.65 over
-- the seat, eyes 1.7 over the root when posed GunnerStand), moved back by EYE_AHEAD because a posed
-- rider's eyes sit that far in front of where the seat puts them (measured in Studio, gunner_fp_gallery).
Pure.RiderRoot = 1.65
Pure.EyeAboveRoot = 1.7
Pure.EyeAhead = 0.7

function Pure.Layout(kind)
	local maker = Pure.Makers[kind]
	assert(maker, "no mounted gun kind " .. tostring(kind))
	local L = maker()
	local eye = L.markers.GunnerEye.pos
	L.seat = { eye[1], eye[2] - Pure.RiderRoot - Pure.EyeAboveRoot, eye[3] + Pure.EyeAhead }
	return L
end
-- PURE END

MountedGunModels.Pure = Pure
MountedGunModels.Layout = Pure.Layout

--------------------------------------------------------------------------------
-- Building (Roblox)
--------------------------------------------------------------------------------

local function frameOf(pos, m)
	return CFrame.new(pos[1], pos[2], pos[3], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
end

local SHAPES = { Block = Enum.PartType.Block, Cylinder = Enum.PartType.Cylinder, Ball = Enum.PartType.Ball }

local function invisible(name, cframe, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.CFrame = cframe
	part.Transparency = 1
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- Builds `kind` at `cframe` (its base on the floor, facing -Z). The base plate is the anchored root;
-- everything else is welded to its group's pivot, and the pivots hang from each other on Motor6Ds named
-- Joint. Parts are queryable (bullets and blasts find them) and only the base, the sandbags and the
-- spare cans collide. Returns the model, not yet parented.
function MountedGunModels.Build(kind, cframe)
	local L = Pure.Layout(kind)
	local model = Instance.new("Model")
	model.Name = "MountedGun"
	local root
	local byGroup = {}
	for _, p in ipairs(L.parts) do
		local part
		if p.shape == "Wedge" then
			part = Instance.new("WedgePart")
		else
			part = Instance.new("Part")
			part.Shape = SHAPES[p.shape]
		end
		part.Name = p.name
		part.Size = Vector3.new(p.size[1], p.size[2], p.size[3])
		part.CFrame = cframe * frameOf(p.pos, p.m)
		local look = Pure.Looks[p.look] or Pure.Looks.gunmetal
		part.Color = Color3.fromRGB(look[1], look[2], look[3])
		part.Material = Enum.Material[look[4]]
		part.Reflectance = look[5]
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = false
		part.CanCollide = p.collide
		part.CanTouch = false
		part.CanQuery = true
		part.Massless = true
		part.CastShadow = p.size[1] > 0.35 or p.size[2] > 0.35 or p.size[3] > 0.35
		if p.shield then
			part:SetAttribute("Shield", true)
		end
		part.Parent = model
		if not root and (p.name == "BasePlate" or p.name == "BaseSkid") then
			root = part
		end
		byGroup[part] = p.group
	end
	root.Anchored = true
	root.Massless = false

	local pivots = {}
	-- Parents before children: TurretYaw, then TurretPitch, then the three on it.
	for _, name in ipairs({ "TurretYaw", "TurretPitch", "BarrelRecoil", "BeltFeed", "BoltSlide" }) do
		local info = L.pivots[name]
		if info then
			local pivot = invisible(name, cframe * CFrame.new(info.pos[1], info.pos[2], info.pos[3]), model)
			pivot:SetAttribute("Pivot", name)
			local parent = info.parent and pivots[info.parent] or root
			local joint = Instance.new("Motor6D")
			joint.Name = "Joint"
			joint.Part0 = parent
			joint.Part1 = pivot
			joint.C0 = parent.CFrame:ToObjectSpace(pivot.CFrame)
			joint.C1 = CFrame.identity
			joint.Parent = pivot
			pivots[name] = pivot
		end
	end
	pivots.TurretYaw:SetAttribute("Stance", "stand")

	local muzzle = invisible("TurretMuzzle", cframe * CFrame.new(L.muzzle[1], L.muzzle[2], L.muzzle[3]), model)
	byGroup[muzzle] = "pitch"
	for part, group in pairs(byGroup) do
		if part ~= root then
			local anchor = Pure.GroupPivot[group] and pivots[Pure.GroupPivot[group]] or root
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = anchor
			weld.Part1 = part
			weld.Parent = part
		end
	end
	for name, marker in pairs(L.markers) do
		local on = pivots[marker.on]
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.CFrame = on.CFrame:ToObjectSpace(cframe * frameOf(marker.pos, marker.m))
		attachment.Parent = on
	end

	local seat = Instance.new("Seat")
	seat.Name = "GunnerSeat"
	seat.Size = Vector3.new(1.6, 0.3, 1.6)
	seat.CFrame = cframe * CFrame.new(L.seat[1], L.seat[2], L.seat[3])
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false
	seat.CanQuery = false
	seat.Massless = true
	seat:SetAttribute("Gunner", true)
	seat.Parent = model
	local seatWeld = Instance.new("WeldConstraint")
	seatWeld.Part0 = root
	seatWeld.Part1 = seat
	seatWeld.Parent = seat

	local promptAt = Instance.new("Attachment")
	promptAt.Name = "MountPromptAt"
	promptAt.CFrame = root.CFrame:ToObjectSpace(cframe * CFrame.new(L.promptAt[1], L.promptAt[2], L.promptAt[3]))
	promptAt.Parent = root

	local heat = {}
	for _, name in ipairs(L.heatParts or {}) do
		heat[#heat + 1] = name
	end
	model:SetAttribute("HeatParts", table.concat(heat, ","))
	model.PrimaryPart = root
	return model
end

return MountedGunModels
