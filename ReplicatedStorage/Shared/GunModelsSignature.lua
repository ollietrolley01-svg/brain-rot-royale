-- Signature gun models: the older arsenal's guns rebuilt with an identity of their own (Oliver, 2026-09-24:
-- "make more fun and quality guns and gun models ... change some of the older boring ones to be more fun").
--
-- Every gun here keeps its weapon id, its stats (WeaponData / ArsenalExpansion) and the MECHANISM it always
-- had: the same Action, the same moving groups, and the hand, sight, magazine and muzzle keypoints where the
-- stock builder put them, so the viewmodel's clips, the third-person pose and the hand checks that already
-- pass keep passing. What changes is everything you look at. Each gun is built on a chassis below -- the
-- stock mechanism's working parts at the stock positions -- and a THEME that dresses it: its own slide,
-- handguard, stock, muzzle, magazine and a signature piece or two, in its own colours.
--
-- GunModels.Build calls Builders[weaponId](g, Kit) for these ids, exactly as it does for the creative and
-- workshop guns, and does everything after the build itself (AimPoint, z-fight pass, Receiver, Muzzle
-- attachment, welds). `g` is GunModels' Builder: sizes and positions in millimetres, the origin on the bore
-- axis above the trigger, the gun facing -Z with +X to the right.
--
-- Model attributes set here beyond the stock contract:
--   Flair      the gun's signature handling in the viewmodel (inspect, draw and reload flourishes):
--              see Viewmodel's FLAIR table. A gun without it animates exactly as before.
--   Signature  true: ArsenalFinish leaves the gun's own colours alone.
--
-- Rules every builder keeps (tools/gunfun_lab.py sight, gun_tube_check, fps_arms_check):
--   * nothing solid on the sight line from the eye (KP_Sight + EyeRelief back) forward;
--   * nothing new within a finger's reach of a hand keypoint that the hand would sink into -- decoration
--     on a grip is FINE-thin and lies on its surface;
--   * no rod that touches nothing, no tube floating off the bore, no second barrel through the first.

local GunModelsSignature = {}

GunModelsSignature.Variants = {}

local Builders = {}
GunModelsSignature.Builders = Builders

local SIGNS = { 1, -1 }

--------------------------------------------------------------------------------
-- Looks
--------------------------------------------------------------------------------

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local function look(K, r, g, b, material, reflectance, transparency)
	return K.finishOf(rgb(r, g, b), material or K.Mat.SmoothPlastic, reflectance, transparency)
end

local function metal(K, r, g, b, reflectance)
	return K.finishOf(rgb(r, g, b), K.Mat.Metal, reflectance or 0.04)
end

local function wood(K, r, g, b)
	return K.finishOf(rgb(r, g, b), K.Mat.Wood)
end

local function fabric(K, r, g, b)
	return K.finishOf(rgb(r, g, b), K.Mat.Fabric)
end

local function neon(K, r, g, b)
	return K.finishOf(rgb(r, g, b), K.Mat.Neon)
end

local function glass(K, r, g, b, transparency)
	return K.finishOf(rgb(r, g, b), K.Mat.Glass, 0.2, transparency or 0.5)
end

-- A skin repaints a gun's body and furniture; without one the theme's own colours stand.
local function skin(g, own)
	return g.skinned and g.skin or own
end

-- A frame at `at` whose -Z runs along `direction`, with its X kept level where it can be. Built from the
-- axes rather than CFrame.lookAt, which has no answer for a direction straight up or down.
local function along(at, direction)
	local back = -direction.Unit
	local reference = math.abs(back.Y) > 0.95 and Vector3.xAxis or Vector3.yAxis
	local right = reference:Cross(back).Unit
	return CFrame.fromMatrix(at, right, back:Cross(right).Unit, back)
end

-- A box spanning two points.
local function strut(g, K, name, from, to, width, lk, height)
	local length = (to - from).Magnitude
	return g:box(name, K.V(width, height or width, length), along((from + to) / 2, to - from), lk)
end

-- A cylinder spanning two points.
local function rod(g, K, name, from, to, diameter, lk)
	return g:cyl(name, (to - from).Magnitude, diameter, along((from + to) / 2, to - from), lk)
end

-- An arc of short boxes laid end to end: a crescent, a hoop, a smile. In the YZ plane at `at` (x is the
-- face it lies on), from angle a0 to a1 degrees round `radius`.
local function arc(g, K, name, at, radius, a0, a1, segments, width, depth, lk)
	local V, CF = K.V, K.CF
	local step = (a1 - a0) / segments
	local chord = 2 * radius * math.sin(math.rad(math.abs(step)) / 2) + 0.6
	g:at(at, function()
		for index = 0, segments - 1 do
			local angle = math.rad(a0 + step * (index + 0.5))
			local point = V(0, math.cos(angle) * radius, -math.sin(angle) * radius)
			local tangent = V(0, -math.sin(angle), -math.cos(angle))
			g:box(name, V(depth, width, chord), CFrame.fromMatrix(point, Vector3.xAxis, Vector3.xAxis:Cross(-tangent), -tangent), lk)
		end
	end)
end

-- A mushroom, a puff, a blob: a stem and a cap, standing up from `at`.
local function mushroom(g, K, at, height, capDiameter, capLook, stemLook, spotLook)
	local CF = K.CF
	g:at(at, function()
		g:cylY("MushroomStem", height, capDiameter * 0.34, CF(0, height / 2, 0), stemLook)
		g:ball("MushroomCap", capDiameter, CF(0, height, 0), capLook)
		-- The cap's underside, so it reads as a cap and not a ball on a stick.
		g:cylY("MushroomGill", capDiameter * 0.12, capDiameter * 0.86, CF(0, height - capDiameter * 0.06, 0), stemLook)
		if spotLook then
			for index = 0, 2 do
				local angle = index / 3 * math.pi * 2 + 0.4
				g:ball("MushroomSpot", capDiameter * 0.2,
					CF(math.cos(angle) * capDiameter * 0.3, height + capDiameter * 0.36, math.sin(angle) * capDiameter * 0.3), spotLook)
			end
		end
	end)
end

-- Restyling a stock build. Some guns keep the whole stock mechanism (an AK, an M14) and are rebuilt from
-- the outside: `strip` takes off the parts the new design replaces (by Lua name pattern), `paint` refinishes
-- what stays, and the builder then adds its own pieces. Hand, sight and group keypoints are untouched.
local function strip(g, patterns)
	for _, part in ipairs(g.model:GetChildren()) do
		if part:IsA("BasePart") then
			for _, pattern in ipairs(patterns) do
				if string.match(part.Name, pattern) then
					part:Destroy()
					break
				end
			end
		end
	end
end

local function paint(g, rules)
	for _, part in ipairs(g.model:GetChildren()) do
		if part:IsA("BasePart") then
			for _, rule in ipairs(rules) do
				if string.match(part.Name, rule[1]) then
					part.Color = rule[2].color
					part.Material = rule[2].material
					part.Reflectance = rule[2].reflectance or 0
					break
				end
			end
		end
	end
end

-- The stock build of this gun's style, with a variant of the builder's choosing in place of the table's.
local function stock(g, K, variant)
	g.variant = variant or {}
	return K.STYLES[g.style](g)
end

--------------------------------------------------------------------------------
-- Chassis: the pistol (the stock pistol's mechanism and keypoints)
--------------------------------------------------------------------------------

-- T.frame, T.slide, T.small: looks. T.compact: the subcompact's lengths.
-- T.slideBody(g, front, back): builds the slide's shape (inside the slide group); default a prism.
-- T.grip: extra grip spec fields. T.gripDress(g, gripFrame, length): dressing on the grip, in its frame.
-- T.mag(g, length): the magazine in the grip frame (inside the mag group); default a polymer box.
-- T.under(g, front): whatever hangs under the dust cover. T.sights(g, front, back): the sights.
local function pistolChassis(g, K, T)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local compact = T.compact
	local front = compact and -94 or -111
	local back = compact and 66 or 77
	local gripLength = compact and 74 or 100
	local frame = T.frame
	local slideLook = T.slide

	local slide
	g:group("slide", function()
		if T.slideBody then
			slide = T.slideBody(g, front, back)
		else
			slide = g:prism("Slide", V(25.5, 22, back - front), CF(0, 1, (front + back) / 2), 3, slideLook, "top")
		end
		-- The port, dark, with the barrel hood in it, on the right.
		g:box("SlidePort", V(FINE * 2, 10, 44), CF(12.8 + FINE, 4, -10), F.shadow)
		g:box("BarrelHood", V(10, 9, 40), CF(8.5, 4.5, -10), T.hood or F.nitride)
		if T.sights then
			T.sights(g, front, back)
		else
			g:box("FrontSight", V(3.5, 6, 6), CF(0, 15, front + 10), F.nitride)
			for _, sx in ipairs(SIGNS) do
				g:box("RearSight", V(8, 6, 7), CF(sx * 7, 15, back - 12), F.nitride)
			end
			g:box("RearSightBase", V(6, 2.5, 7), CF(0, 13.25, back - 12), F.nitride)
		end
		g:cyl("Bore", FINE, 9.5, CF(0, 0, (T.boreZ or front) - FINE / 2), F.bore)
	end)
	g:travel("slide", 58)
	g:key("Eject", CF(14, 8, -10) * A(0, -60, 0))
	g:key("Sight", CF(0, 18, back - 6))
	g:hand("ChargeHand", V(-4, 34, back - 22), V(1, -0.45, 0.1), V(0, 1, 0.1))

	-- Frame: dust cover, the frame over the trigger, guard and trigger.
	local dustFront = front + 5
	local dustLength = -28 - dustFront
	g:at(CF(0, 0, dustFront + dustLength / 2), function()
		g:box("Frame", V(24, 5, dustLength), CF(0, -12.5, 0), frame)
		g:box("Frame", V(17, 4, dustLength), CF(0, -17, 0), frame)
		g:prism("Frame", V(24, 5, dustLength), CF(0, -21.5, 0), 2, frame, "bottom")
	end)
	g:box("Frame", V(24, 16, 104), CF(0, -18, 24), frame)
	g:box("TriggerGuard", V(12, 24, 9), CF(0, -38, -34), T.guard or frame)
	g:box("TriggerGuard", V(12, 8, 60), CF(0, -54, -8), T.guard or frame)
	g:wedge("TriggerGuardHook", V(12, 8, 8), CF(0, -46, -42.5), T.guard or frame)
	g:group("trigger", function()
		g:box("Trigger", V(6, 17, 5), CF(0, -34.5, -2) * A(-10, 0, 0), T.trigger or F.polymerDark)
	end)
	g:swing("trigger", CF(0, -26, 0), 10)
	g:detail(function()
		g:box("SlideStop", V(3.5, 5, 14), CF(-13.75, -13, -14), T.small or F.nitride)
	end)

	local spec = { length = gripLength, depth = 54, front = 24, back = 30, grooves = compact and 0 or 3, top = 10 }
	for key, value in pairs(T.grip or {}) do
		spec[key] = value
	end
	local gripFrame = g:grip(V(0, -26, 40), 15, T.gripLook or frame, spec)
	g:at(gripFrame, function()
		if T.gripDress then
			T.gripDress(g, gripLength)
		end
		g:group("mag", function()
			if T.mag then
				T.mag(g, gripLength)
			else
				g:box("Magazine", V(19, gripLength - 4, 32), CF(0, -gripLength / 2 - 4, 2), F.polymerDark)
				g:prism("MagazinePlate", V(25, 7, 42), CF(0, -gripLength - 3.5, 2), 2, T.small or F.nitride, "bottom")
			end
		end)
		g:key("MagWell", CF(0, -gripLength, 2))
	end)
	g:prism("Beavertail", V(24, 9, 9), CF(0, -14.5, 80.5), 3, frame, "bottom")
	g:hand("GripHand", V(30, -62, 52), V(-0.3, 0.1, -1), V(1, 0.15, 0.3))
	g:hand("SupportHand", V(-33, -74, 38), V(0.55, -0.05, -1), V(-1, -0.1, -0.3))
	g:hand("MagHand", V(-26, compact and -112 or -136, 62), V(0.35, 0.3, -0.2), V(-1, -0.1, 0))

	if T.under then
		T.under(g, front)
	end

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 1.1)
	g.model:SetAttribute("Action", "pistol")
	g.model:SetAttribute("Flash", T.flash or "pistol")
	g.model:SetAttribute("Casing", T.casing or "pistol")
	g:key("Muzzle", CF(0, 0, (T.muzzleZ or front) - 4))
	return slide
end

--------------------------------------------------------------------------------
-- Chassis: the SMG (the stock SMG's mechanism and keypoints)
--------------------------------------------------------------------------------

-- T.metal, T.furniture, T.small: looks. T.suppressed: the SD's lengths (support hand at -205, muzzle -472).
-- T.receiverDress(g), T.front(g) -> muzzleZ (barrel, handguard, muzzle; the support hand's handguard must
-- stay where the stock one was), T.stock(g), T.mag(g), T.sights(g) (default: the stock diopter and hooded
-- post; must set KP_Sight, Optic and EyeRelief), T.drum.
local function smgChassis(g, K, T)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local metal, furniture, small = T.metal, T.furniture, T.small or F.steel

	local receiver = g:box("Receiver", V(15, 42, 300), CF(-7.5, -1, 10), metal)
	g:box("ReceiverWall", V(15, 42, 150), CF(7.5, -1, 85), metal)
	g:box("ReceiverWall", V(15, 42, 80), CF(7.5, -1, -100), metal)
	g:box("ReceiverWall", V(15, 12, 70), CF(7.5, -16, -25), metal)
	g:box("ReceiverWall", V(15, 12, 70), CF(7.5, 14, -25), metal)
	g:box("EjectionPort", V(3.5, 18, 70), CF(5.25, -1, -25), F.shadow)
	g:group("bolt", function()
		g:box("BoltCarrier", V(11.5, 14, 50), CF(5.75, -1, -18), T.bolt or F.steel)
	end)
	g:travel("bolt", 60)
	g:key("Eject", CF(18, 0, -25) * A(0, -70, 0))
	g:box("EndCap", V(34, 44, 8), CF(0, -1, 164), T.endCap or furniture)
	if T.receiverDress then
		T.receiverDress(g)
	end

	-- The cocking tube, banded to the front end, with the handle out the left.
	g:cyl("CockingTube", 150, 22, CF(0, 28, -215), T.tube or metal)
	g:box("TubeSupport", V(20, 10, 20), CF(0, 16, -150), metal)
	g:box("BarrelBand", V(28, 13, 14), CF(0, 14, -258), T.tube or metal)
	g:group("charge", function()
		g:box("ChargingHandle", V(24, 8, 9), CF(-18, 34, -236) * A(0, 0, -40), small)
		g:ball("ChargingKnob", 13, CF(-30, 44, -236), T.knob or F.polymerDark)
	end)
	g:travel("charge", 90)
	g:hand("ChargeHand", V(-42, 58, -240), V(-0.6, -0.36, -0.71), V(-0.77, 0, 0.64))

	if T.sights then
		T.sights(g)
	else
		g:at(CF(0, 28, -282), function()
			g:box("FrontSightBase", V(26, 14.5, 26), CF(0, -2.75, 0), T.tube or metal)
			g:shell("FrontSightHood", 18, 28, 4, CF(0, 16, 0), T.tube or metal, 10)
			g:box("FrontSightPost", V(3, 12, 3), CF(0, 10, 0), F.nitride)
			g:box("FrontSight", V(2.2, 6, 3), CF(0, 19, 0), T.post or F.nitride)
		end)
		g:box("RearSightBase", V(26, 8, 34), CF(0, 24, 136), metal)
		g:cylX("RearSightDrum", 26, 26, CF(0, 32.5, 136), T.drumLook or metal)
		g:shell("RearSight", 6, 12, 3, CF(0, 50, 136), metal, 8)
		g:key("Sight", CF(0, 50, 142))
		g.model:SetAttribute("Optic", "iron")
		g.model:SetAttribute("EyeRelief", 0.36)
	end

	g:prism("TriggerGroup", V(28, 20, 128), CF(0, -32, 34), 3, furniture, "bottom")
	g:box("TriggerGuard", V(12, 6, 60), CF(0, -58, 6), furniture)
	g:box("TriggerGuard", V(12, 13, 6), CF(0, -48.5, -24), furniture)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -47, 0) * A(-12, 0, 0), small)
	end)
	g:swing("trigger", CF(0, -38, 0), 12)
	local gripFrame = g:grip(V(0, -42, 66), 16, T.gripLook or furniture, { length = 98, depth = 46, front = 22, back = 30, grooves = 3 })
	if T.gripDress then
		g:at(gripFrame, function()
			T.gripDress(g)
		end)
	end
	g:hand("GripHand", V(31, -80, 82), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	g:box("MagWell", V(30, 23, 48), CF(0, -33.5, -76), metal)
	g:group("mag", function()
		if T.mag then
			T.mag(g)
		elseif T.drum then
			g:drumMag("Magazine", 100, 56, CF(0, -44, -76), T.magLook or F.polymerDark)
		else
			g:magazine("Magazine", { width = 22, depth = 34, segments = { { 60, 0 }, { 42, 4 }, { 42, 4 }, { 42, 4 } }, ribs = "stanag", caliber = 9, plate = T.plate },
				CF(0, -40, -76), T.magLook or F.nitride)
		end
	end)
	g:key("MagWell", CF(0, -40, -76))
	g:hand("MagHand", V(-30, T.drum and -150 or -120, -80), V(0.4, 0.25, -0.2), V(-1, -0.15, 0))

	local muzzleZ = T.front(g)
	g:key("Muzzle", CF(0, 0, muzzleZ))
	g:hand("SupportHand", V(-12, -44, T.suppressed and -205 or -212), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	T.stock(g)

	g.model:SetAttribute("Action", "smg")
	g.model:SetAttribute("Flash", T.flash or "smg")
	g.model:SetAttribute("Casing", "pistol")
	return receiver
end

--------------------------------------------------------------------------------
-- Chassis: the AR family (the stock AR's mechanism and keypoints, at any of its scales)
--------------------------------------------------------------------------------

-- spec: scale, hgLength, barrelEnd, barrelDia, action, flash, casing (as buildAR).
-- T.receiver, T.furniture, T.small, T.lower: looks.
-- T.handguard(g, info): the handguard round the barrel from z = -103 back to info.front (in the scaled
--   frame); info = { front, z, length }. Must leave something under the support hand at
--   (-10, -48, z - length * 0.1), or set T.supportHand.
-- T.muzzle(g, barrelEnd) -> muzzleZ. T.stock(g). T.mag(g). T.sights(g, railTop): must set KP_Sight,
-- Optic and EyeRelief. T.dress(g, info): anything else.
local function arChassis(g, K, spec, T)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	g.scale = spec.scale or 1
	local receiverLook, lower, furniture, small = T.receiver, T.lower or T.receiver, T.furniture, T.small or F.anodizedDark
	local hgLength = spec.hgLength or 306
	local barrelEnd = spec.barrelEnd or -480
	local barrelDia = spec.barrelDia or 17

	local upper = g:prism("Receiver", V(30, 16, 170), CF(0, 13, -15), 4, receiverLook, "top")
	g:box("UpperWall", V(15, 23, 170), CF(-7.5, -6.5, -15), receiverLook)
	g:box("UpperWall", V(15, 8, 170), CF(7.5, -14, -15), receiverLook)
	g:box("UpperWall", V(15, 15, 72), CF(7.5, -2.5, 34), receiverLook)
	g:box("UpperWall", V(15, 15, 38), CF(7.5, -2.5, -81), receiverLook)
	g:box("EjectionPort", V(3.5, 15, 60), CF(5.25, -2.5, -32), F.shadow)
	g:group("bolt", function()
		g:box("BoltCarrier", V(11.5, 13, 44), CF(5.75, -2.5, -28), T.bolt or F.nitride)
		g:box("BoltLug", V(11.5, 5, 8), CF(5.75, -2.5, -54), F.steel)
	end)
	g:travel("bolt", 70)
	g:key("Eject", CF(20, -2, -32) * A(0, -70, 0))
	if not T.noRail then
		g:rail("UpperRail", 145, CF(0, 21, -22.5), T.rail)
	end

	g:group("charge", function()
		g:box("ChargingHandle", V(16, 7, 40), CF(0, 24.5, 75), small)
		g:prism("ChargingHandleWings", V(50, 9, 13), CF(0, 24.5, 101.5), 2.5, small)
	end)
	g:travel("charge", 64)
	g:hand("ChargeHand", V(-30, 34, 104), V(0.75, -0.25, 0.6), V(-0.3, 1, 0.2))

	g:prism("Lower", V(26, 30, 190), CF(0, -33, 0), 3, lower, "bottom")
	g:rounded("BufferTower", V(24, 36, 25), CF(0, -2, 82.5), 11, lower)
	g:prism("MagWell", V(33, 22, 76), CF(0, -57, -57), 4, lower, "bottom")
	g:wedge("MagWellFlare", V(33, 12, 14), CF(0, -62, -102), lower)
	g:detail(function()
		g:cylX("MagRelease", 7, 11, CF(16.5, -38, -12), small)
		g:at(CF(-15, -33, 40), function()
			g:cylX("Selector", 3.5, 12, CF(0, 0, 0), F.anodizedDark)
			g:box("SelectorLever", V(3.5, 5, 17), CF(-1, 0, -7) * A(-25, 0, 0), small)
		end)
	end)

	g:box("TriggerGuard", V(12, 6, 58), CF(0, -73, 10), T.guard or lower)
	g:box("TriggerGuard", V(12, 24, 7), CF(0, -58, 38), T.guard or lower)
	g:group("trigger", function()
		g:box("Trigger", V(6, 20, 6), CF(0, -57, -2) * A(-12, 0, 0), small)
	end)
	g:swing("trigger", CF(0, -47, 0), 12)

	local gripFrame = g:grip(V(0, -48, 64), 22, T.gripLook or furniture, { length = 106, depth = 48, front = 22, back = 31, nub = true })
	if T.gripDress then
		g:at(gripFrame, function()
			T.gripDress(g)
		end)
	end
	g:hand("GripHand", V(31, -88, 86), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	g:group("mag", function()
		if T.mag then
			T.mag(g)
		else
			g:magazine("Magazine", { width = 22.5, depth = 62, segments = { { 62, 0 }, { 24, 4 }, { 24, 4 }, { 24, 4 }, { 24, 4 } }, ribs = "stanag", caliber = 9.5, plate = T.plate },
				CF(0, -52, -57), T.magLook or F.anodizedDark)
		end
	end)
	g:key("MagWell", CF(0, -52, -57))
	g:hand("MagHand", V(-28, -120, -62), V(0.4, 0.25, -0.15), V(-1, -0.15, 0))

	T.stock(g)

	local hgFront = -103 - hgLength
	local hgZ = -103 - hgLength / 2
	local info = { front = hgFront, z = hgZ, length = hgLength, barrelEnd = barrelEnd, barrelDia = barrelDia }
	T.handguard(g, info)
	if T.supportHand then
		T.supportHand(g, info)
	else
		g:hand("SupportHand", V(-10, -48, hgZ - hgLength * 0.1), V(0.8, 0.45, -0.3), V(-0.35, -1, 0))
	end

	g:cyl("Barrel", -100 - barrelEnd, barrelDia, CF(0, 0, (barrelEnd - 100) / 2), T.barrel or F.nitride)
	local muzzleZ = T.muzzle(g, barrelEnd, barrelDia)
	g:key("Muzzle", CF(0, 0, muzzleZ))

	T.sights(g, 30.5, info)
	if T.dress then
		T.dress(g, info)
	end

	g.model:SetAttribute("Action", spec.action or "ar")
	g.model:SetAttribute("Flash", spec.flash or "rifle")
	g.model:SetAttribute("Casing", spec.casing or "rifle")
	return upper
end

--------------------------------------------------------------------------------
-- Chassis: the pump gun (the stock pump's mechanism and keypoints)
--------------------------------------------------------------------------------

-- T.metal, T.furniture: looks. T.pumpBody(g): the pump (inside the pump group, round the stock pump's
-- place: centre (0, -28, -300), 46 x 44 x 180). T.stock(g). T.saddle(g): the left side. T.front(g): the
-- barrel's end (after the barrel, tube and bead are built).
local function pumpChassis(g, K, T)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local metal, furniture = T.metal, T.furniture

	g:prism("ReceiverTop", V(30, 8, 210), CF(0, 14, -30), 4, metal, "top")
	local receiver = g:box("Receiver", V(15, 52, 210), CF(-7.5, -16, -30), metal)
	g:box("ReceiverWall", V(15, 26, 210), CF(7.5, -29, -30), metal)
	g:box("ReceiverWall", V(15, 26, 80), CF(7.5, -3, 35), metal)
	g:box("ReceiverWall", V(15, 26, 50), CF(7.5, -3, -110), metal)
	g:box("EjectionPort", V(3.5, 26, 80), CF(5.25, -3, -45), F.shadow)
	g:group("pump", function()
		g:box("BoltCarrier", V(11.5, 20, 60), CF(5.75, -3, -40), F.steel)
	end)
	g:key("Eject", CF(20, -2, -45) * A(0, -70, 0))
	g:box("LoadingPort", V(20, FINE * 2, 70), CF(0, -42 - FINE, -90), F.shadow)
	g:key("Load", CF(0, -60, -80))
	g:box("TriggerPlate", V(24, 10, 120), CF(0, -47, 10), metal)
	g:box("TriggerGuard", V(12, 6, 62), CF(0, -70, 8), T.guard or metal)
	g:box("TriggerGuard", V(12, 15, 6), CF(0, -59.5, -22), T.guard or metal)
	g:box("TriggerGuard", V(12, 15, 6), CF(0, -59.5, 38), T.guard or metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 17, 6), CF(0, -60, -2) * A(-10, 0, 0), T.trigger or F.steel)
	end)
	g:swing("trigger", CF(0, -52, 0), 10)
	if T.receiverDress then
		T.receiverDress(g)
	end

	g:cyl("Barrel", 485, 23, CF(0, 0, -377.5), T.barrel or F.nitride)
	g:cyl("Bore", FINE, 19, CF(0, 0, -620 - FINE / 2), F.bore)
	g:box("BeadRamp", V(5, 8, 12), CF(0, 15, -606), T.barrel or F.nitride)
	g:ball("FrontBead", 5, CF(0, 20.5, -606), T.bead or F.brass)
	g:cyl("MagTube", 425, 26, CF(0, -30, -347.5), T.tube or F.nitride)
	g:cyl("MagCap", 22, 29, CF(0, -30, -571), T.cap or F.nitride)
	g:box("BarrelClamp", V(34, 50, 14), CF(0, -14, -536), T.tube or F.nitride)
	g:key("Muzzle", CF(0, 0, -624))
	if T.front then
		T.front(g)
	end

	g:group("pump", function()
		T.pumpBody(g)
		for _, sx in ipairs(SIGNS) do
			g:box("ActionBar", V(3, 6, 90), CF(sx * 12, -18, -165), F.steel)
		end
	end)
	g:travel("pump", 85)
	g:hand("SupportHand", V(-8, -58, -300), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "pump")

	T.stock(g)
	g:grip(V(0, -44, 72), 22, T.gripLook or furniture, { length = 96, depth = 46, front = 22, back = 30 })
	g:hand("GripHand", V(31, -86, 104), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	if T.saddle then
		T.saddle(g)
	end

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.8)
	g:key("Sight", CF(0, 23, 40))
	g.model:SetAttribute("Action", "pump")
	g.model:SetAttribute("Flash", T.flash or "shotgun")
	g.model:SetAttribute("Casing", "shell")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Sahur Pistol -- a carved night-drummer's pistol
--------------------------------------------------------------------------------

-- The drummer who walks the street before dawn knocking everyone awake for the meal. The slide is a turned
-- drumstick of pale ash bound with dark cord, its nose rounded into the stick's head; the frame is walnut,
-- the grip cord-wrapped; a little hand drum hangs where a light would, its skin laced over the shell; a brass
-- crescent and star are inlaid in the slide's left side. Tap it and it goes tok.
Builders.SahurPistol = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local ash = skin(g, wood(K, 214, 178, 128))
	local walnut = skin(g, wood(K, 92, 56, 34))
	local cord = fabric(K, 58, 36, 24)
	local brass = F.brass
	local drumSkin = look(K, 238, 226, 196, K.Mat.Fabric)

	local receiver = pistolChassis(g, K, {
		frame = walnut,
		slide = ash,
		small = brass,
		guard = walnut,
		trigger = brass,
		hood = brass,
		slideBody = function(g, front, back)
			local length = back - front
			-- A turned stick: the round-edged body, and the head where the muzzle comes out.
			local body = g:rounded("Slide", V(26, 23, length - 14), CF(0, 1.5, (front + back) / 2 + 7), 9, ash)
			g:ball("SlideHead", 26, CF(0, 1, front + 13), ash)
			g:cyl("SlideNeck", 16, 24, CF(0, 1, front + 21), ash)
			-- Cord bindings round the stick, dark against the pale wood.
			for _, z in ipairs({ front + 36, front + 44, back - 40, back - 32 }) do
				g:rounded("SlideBinding", V(27.8, 24.8, 4), CF(0, 1.5, z), 9.5, cord)
			end
			-- Grip grooves cut into the back of the stick, where a slide's serrations would be.
			g:detail(function()
				for index = 0, 5 do
					for _, sx in ipairs(SIGNS) do
						g:box("SlideSerration", V(FINE * 2, 13, 2.2), CF(sx * 13, 0, back - 10 - index * 4.5), K.finishOf(rgb(150, 112, 70), K.Mat.Wood))
					end
				end
			end)
			-- The inlay: a brass crescent and a star, on the left face.
			g:detail(function()
				arc(g, K, "SlideInlay", CF(-13 - FINE, 2, -40), 7, 200, 340, 7, 2.2, FINE * 2, brass)
				g:ball("SlideInlayStar", 3.4, CF(-13.2, 6, -30), brass)
			end)
			return body
		end,
		sights = function(g, front, back)
			-- A brass bead on a wooden ramp at the front; a notched walnut block at the back.
			g:box("FrontSightBase", V(6, 5, 10), CF(0, 12.5, front + 26), ash)
			g:box("FrontSight", V(3.5, 4, 5), CF(0, 16, front + 26), brass)
			g:ball("SightDot", 2.4, CF(0, 17, front + 23.8), K.F.tritiumOrange)
			for _, sx in ipairs(SIGNS) do
				g:box("RearSight", V(8, 6, 7), CF(sx * 7, 15, back - 12), walnut)
			end
			g:box("RearSightBase", V(6, 2.5, 7), CF(0, 13.25, back - 12), walnut)
		end,
		gripDress = function(g, length)
			-- Cord wrapped round the grip in four turns, a brass ferrule at its heel.
			for index = 0, 3 do
				g:box("GripWrap", V(31.5, 5, 55.5), CF(0, -18 - index * 18, -1.5), cord)
			end
			g:box("GripFerrule", V(31.5, 6, 55.5), CF(0, -length + 6, -1.5), brass)
		end,
		mag = function(g, length)
			g:box("Magazine", V(19, length - 4, 32), CF(0, -length / 2 - 4, 2), walnut)
			g:prism("MagazinePlate", V(25, 7, 42), CF(0, -length - 3.5, 2), 2, brass, "bottom")
		end,
		under = function(g, front)
			-- A hand drum on the rail: a walnut shell, two skins, and the lacing zigzagging between them.
			g:box("DrumMount", V(18, 7, 26), CF(0, -27.5, -58), walnut)
			local z = -80
			g:cyl("Drum", 34, 30, CF(0, -44, z), walnut)
			for _, sz in ipairs(SIGNS) do
				g:cyl("DrumSkin", 3, 31.5, CF(0, -44, z + sz * 17.5), drumSkin)
				g:cyl("DrumHoop", 3, 33, CF(0, -44, z + sz * 15.5), brass)
			end
			g:detail(function()
				for index = 0, 7 do
					local angle = index / 8 * math.pi * 2
					local lean = (index % 2 == 0) and 24 or -24
					g:box("DrumLace", V(1.6, 1.6, 30), CF(0, -44, z) * CFrame.Angles(0, 0, angle) * CF(0, 15.6, 0) * A(lean, 0, 0), cord)
				end
			end)
		end,
	})

	g.model:SetAttribute("Flair", "drum")
	g.model:SetAttribute("ShotCue", "GunshotTung")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Pocket Popper -- the cinema's pocket popcorn pistol
--------------------------------------------------------------------------------

-- A buttery yellow slide over a red-and-white striped carton of a frame, popcorn spilling out of the
-- ejection port, a butter pump slung under the nose, and the magazine's base a little striped bucket
-- heaped with popcorn.
Builders.PocketPopper = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local butter = skin(g, look(K, 255, 208, 72, K.Mat.SmoothPlastic, 0.12))
	local red = skin(g, look(K, 214, 38, 44))
	local white = look(K, 246, 242, 232)
	local pop = look(K, 255, 248, 222)
	local kernel = look(K, 238, 180, 70)

	local function puff(at, size)
		g:ball("Popcorn", size, at, pop)
		g:ball("Popcorn", size * 0.7, at * CF(size * 0.32, size * 0.18, -size * 0.1), pop)
		g:ball("PopcornKernel", size * 0.36, at * CF(-size * 0.28, -size * 0.12, size * 0.22), kernel)
	end

	local receiver = pistolChassis(g, K, {
		compact = true,
		frame = red,
		slide = butter,
		small = white,
		guard = white,
		trigger = white,
		slideBody = function(g, front, back)
			local body = g:rounded("Slide", V(26, 22, back - front), CF(0, 1, (front + back) / 2), 7, butter)
			-- A white band round the nose: the carton's rim.
			g:rounded("SlideBand", V(27.6, 23.6, 10), CF(0, 1, front + 9), 7.5, white)
			g:detail(function()
				for index = 0, 5 do
					for _, sx in ipairs(SIGNS) do
						g:box("SlideSerration", V(FINE * 2, 13, 2), CF(sx * 13, 0, back - 8 - index * 4.5), kernel)
					end
				end
			end)
			-- Popcorn bursting out of the port on the right.
			puff(CF(16, 9, -14), 11)
			puff(CF(15, 12, -2), 9)
			return body
		end,
		gripDress = function(g, length)
			-- White stripes down both flanks: the carton.
			for _, sx in ipairs(SIGNS) do
				for _, z in ipairs({ -9, 3 }) do
					g:box("GripStripe", V(FINE * 2, length - 8, 5), CF(sx * 12.2, -length / 2, z), white)
				end
			end
		end,
		mag = function(g, length)
			g:box("Magazine", V(19, length - 4, 32), CF(0, -length / 2 - 4, 2), red)
			-- The bucket: flared, striped, heaped with popcorn below the grip.
			g:grip(V(0, -length - 0.3, 0), 0, red, { length = 16, depth = 58, front = 26, back = 32, name = "MagazineBucket" })
			for _, z in ipairs({ -16, -4, 8, 20 }) do
				g:box("MagazineStripe", V(34, 16.5, 3), CF(0, -length - 8.5, z), white)
			end
			g:prism("MagazinePlate", V(30, 5, 58), CF(0, -length - 19, 0), 2, white, "bottom")
		end,
		under = function(g, front)
			-- The butter pump: a yellow bottle on the rail with a red nozzle pointing forward.
			g:box("PumpMount", V(18, 6, 22), CF(0, -27, -60), white)
			g:cyl("ButterBottle", 44, 22, CF(0, -40, -66), butter)
			g:cyl("ButterCap", 10, 16, CF(0, -40, -93), red)
			g:cyl("ButterNozzle", 12, 7, CF(0, -40, -104), red)
			g:detail(function()
				g:box("ButterLabel", V(22.6, 10, 18), CF(0, -40, -66), white)
			end)
		end,
	})
	g.model:SetAttribute("Flair", "toss")
	g.model:SetAttribute("ShotCue", "GunshotPopcorn")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Pistacchio Pum -- the pawnshop's pistachio pistol
--------------------------------------------------------------------------------

-- A pistachio-green slide with a cream nose, grip panels that are two halves of a cracked pistachio shell
-- with the green nut showing in the crack, and the pawnshop's price tag still tied to the trigger guard.
Builders.PawnshopNine = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local green = skin(g, look(K, 148, 190, 92))
	local greenDark = look(K, 96, 138, 58)
	local shell = look(K, 222, 196, 150, K.Mat.SmoothPlastic)
	local shellDark = look(K, 176, 142, 96)
	local cream = look(K, 240, 226, 190)
	local frame = skin(g, look(K, 122, 98, 70))
	local tag = look(K, 250, 234, 120)
	local twine = fabric(K, 230, 226, 214)

	local receiver = pistolChassis(g, K, {
		frame = frame,
		slide = green,
		small = shellDark,
		guard = frame,
		slideBody = function(g, front, back)
			local body = g:prism("Slide", V(25.5, 22, back - front - 26), CF(0, 1, (front + back) / 2 + 13), 3, green, "top")
			-- The nose in cream, rounded like the tip of a nut.
			g:rounded("SlideNose", V(25.5, 22, 26), CF(0, 1, front + 13), 8, cream)
			g:detail(function()
				-- A darker seam down each side where a shell would split.
				for _, sx in ipairs(SIGNS) do
					g:box("SlideSeam", V(FINE * 2, 2, back - front - 40), CF(sx * 12.8, 1, (front + back) / 2 + 8), greenDark)
				end
				for index = 0, 6 do
					g:box("SlideSerration", V(25.5 + FINE * 2, 13, 2), CF(0, -1, back - 8 - index * 4.5), greenDark)
				end
			end)
			return body
		end,
		gripDress = function(g, length)
			-- A shell half on each flank: a rounded slab, its crack running down the middle, the nut in it.
			for _, sx in ipairs(SIGNS) do
				-- Three stepped layers make the dome of the shell.
				g:rounded("GripShell", V(4.5, length - 16, 44), CF(sx * 14.2, -length / 2 - 2, -1), 2.2, shell)
				g:rounded("GripShell", V(3, length - 28, 34), CF(sx * 17.4, -length / 2 - 2, -1), 1.4, shell)
				g:rounded("GripShell", V(2, length - 42, 22), CF(sx * 19.6, -length / 2 - 2, -1), 0.9, shell)
				g:detail(function()
					g:box("GripShellCrack", V(1.2, length - 44, 4), CF(sx * 20.8, -length / 2 - 2, -1), greenDark)
					g:box("GripNut", V(1.2, length - 50, 2), CF(sx * 21.4, -length / 2 - 2, -1), green)
				end)
			end
		end,
		mag = function(g, length)
			g:box("Magazine", V(19, length - 4, 32), CF(0, -length / 2 - 4, 2), shellDark)
			g:prism("MagazinePlate", V(25, 7, 42), CF(0, -length - 3.5, 2), 2, cream, "bottom")
		end,
		under = function(g, front)
			-- The price tag, on a loop of string round the front of the trigger guard.
			g:box("TagLoop", V(14, 2, 2), CF(0, -52, -39), twine)
			strut(g, K, "TagString", V(0, -52, -40), V(0, -70, -44), 1.6, twine)
			g:box("PriceTag", V(1.6, 16, 26), CF(0, -77, -44) * A(-12, 0, 0), tag)
			g:detail(function()
				g:cylX("PriceTagHole", 2.2, 3.6, CF(0, -70.5, -44), shellDark)
				g:box("PriceTagStripe", V(2.2, 2, 18), CF(0, -80, -45) * A(-12, 0, 0), shellDark)
			end)
		end,
	})
	g.model:SetAttribute("Flair", "tap")
	g.model:SetAttribute("ShotCue", "GunshotPistachio")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Rot SMG -- the one that has been in the swamp too long
--------------------------------------------------------------------------------

-- A swamp-green SMG gone to rot: fuzzy mould blooming on the receiver, a seam stitched shut down its left
-- side, the handguard wrapped in grubby bandage, a rusted tin can for a suppressor dripping green ooze, a
-- stock made of two old bones, and mushrooms growing out of the whole thing.
Builders.RotSMG = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local rot = skin(g, look(K, 98, 112, 78))
	local rotDark = look(K, 62, 72, 50)
	local mould = fabric(K, 168, 186, 132)
	local bandage = fabric(K, 214, 204, 170)
	local rust = metal(K, 140, 82, 48, 0.02)
	local rustDark = metal(K, 96, 56, 34, 0.02)
	local ooze = neon(K, 120, 255, 80)
	local bone = look(K, 232, 224, 198)
	local capRed = look(K, 196, 48, 40)
	local capBrown = look(K, 150, 96, 60)
	local stem = look(K, 240, 232, 214)

	local receiver = smgChassis(g, K, {
		metal = rot,
		furniture = skin(g, rotDark),
		small = rust,
		tube = rot,
		endCap = rotDark,
		suppressed = true,
		flash = "suppressed",
		receiverDress = function(g)
			-- Mould blooms: soft pale patches standing proud of the walls.
			for _, patch in ipairs({ { -15.2, 8, 60, 22, 40 }, { -15.2, -8, 118, 16, 26 }, { 15.2, 6, 110, 18, 30 }, { 15.2, -10, -110, 14, 22 } }) do
				g:box("Mould", V(FINE * 2, patch[4], patch[5]), CF(patch[1], patch[2], patch[3]), mould)
				g:box("Mould", V(FINE * 2 + 1, patch[4] * 0.55, patch[5] * 0.5), CF(patch[1] + (patch[1] > 0 and 0.5 or -0.5), patch[2] + 2, patch[3] - 3), mould)
			end
			-- A seam stitched shut down the left side.
			g:box("Seam", V(FINE * 2, 2, 150), CF(-15.2, -2, 20), rotDark)
			g:detail(function()
				for index = 0, 8 do
					g:box("Stitch", V(FINE * 2 + 0.6, 9, 1.8), CF(-15.3, -2, -50 + index * 17) * A(0, 0, 0) * A(20, 0, 0), bandage)
				end
			end)
			-- Mushrooms growing out of the right side of the receiver.
			mushroom(g, K, CF(15, 12, 40) * A(0, 0, -70), 14, 22, capRed, stem, stem)
			mushroom(g, K, CF(15, 2, 66) * A(0, 0, -80), 10, 15, capBrown, stem, nil)
		end,
		front = function(g)
			-- The handguard under its bandage, and the rusted can past it.
			g:rounded("Handguard", V(56, 56, 120), CF(0, -2, -200), 26, rotDark)
			for index = 0, 5 do
				g:shell("Bandage", 12, 61, 5, CF(0, -2, -250 + index * 19) * A((index % 2 == 0) and 9 or -9, 0, 0), bandage, 14)
			end
			g:cyl("Suppressor", 330, 52, CF(0, -2, -305), rust)
			g:detail(function()
				-- The can's pressed ribs, and its paper label peeling off.
				for index = 0, 6 do
					g:cyl("SuppressorBand", 3, 54, CF(0, -2, -300 - index * 22), rustDark)
				end
				g:cyl("SuppressorLabel", 28, 53, CF(0, -2, -404), K.finishOf(rgb(120, 150, 90), K.Mat.Fabric))
				g:cyl("SuppressorLabel", 22, 53, CF(0, -2, -432), K.finishOf(rgb(200, 190, 120), K.Mat.Fabric))
				g:cyl("Bore", 2, 10, CF(0, -2, -470.4), F.bore)
			end)
			g:cyl("SuppressorRim", 4, 53.5, CF(0, -2, -468), rustDark)
			-- Ooze running over the rim and dripping off it.
			for index, drip in ipairs({ { -14, -24, 8 }, { 6, -27, 6 }, { 18, -20, 5 } }) do
				g:box("Ooze", V(8, 14, 5), CF(drip[1], drip[2] + 6, -467), ooze)
				g:ball("OozeDrip", drip[3] * 1.5, CF(drip[1], drip[2] - drip[3] * 0.3, -467), ooze)
			end
			return -472
		end,
		stock = function(g)
			-- Two bones for a stock, knuckled at both ends, and a pad lashed across their ends.
			for _, sx in ipairs(SIGNS) do
				g:prism("StockBone", V(14, 14, 180), CF(sx * 14, -6, 262), 4, bone)
				for _, z in ipairs({ 172, 352 }) do
					for _, sy in ipairs(SIGNS) do
						g:ball("StockBoneKnuckle", 17, CF(sx * 14, -6 + sy * 7, z), bone)
					end
				end
			end
			g:box("StockYoke", V(34, 12, 18), CF(0, -6, 360), rotDark)
			g:rounded("Buttpad", V(40, 30, 104), CF(0, -26, 372) * A(90, 0, 0), 12, F.rubber)
			g:box("StockLashing", V(42, 14, 8), CF(0, -6, 348), bandage)
			mushroom(g, K, CF(-14, 1, 300), 13, 20, capRed, stem, stem)
			mushroom(g, K, CF(14, 1, 230), 9, 14, capBrown, stem, nil)
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 22, depth = 34, segments = { { 60, 0 }, { 42, 4 }, { 42, 4 }, { 42, 4 } }, ribs = "stanag", caliber = 9, plate = rustDark },
				CF(0, -40, -76), rot)
			g:detail(function()
				for index = 0, 2 do
					g:box("Mould", V(24 + FINE * 2, 14, 10), CF(0, -76 - index * 38, -76 + (index - 1) * 6) * A(12, 0, 0), mould)
				end
			end)
		end,
	})
	g.model:SetAttribute("Flair", "shake")
	g.model:SetAttribute("ShotCue", "GunshotRot")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Crumbly Carbine -- the biscuit tin carbine
--------------------------------------------------------------------------------

-- A short carbine baked rather than machined: shortbread-gold furniture studded with chocolate chips, a
-- cream-sandwich biscuit for a handguard (two docked biscuits and the filling between), a stock with a
-- bite out of it, a muzzle ring of biscuit, and a magazine packed like a sleeve of cookies.
Builders.CrumblyCarbine = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local biscuit = skin(g, look(K, 214, 162, 96))
	local biscuitDark = look(K, 170, 118, 64)
	local cream = look(K, 246, 238, 218)
	local choc = look(K, 74, 44, 28)
	local tin = metal(K, 70, 96, 140, 0.06)

	local function chips(list)
		for _, at in ipairs(list) do
			g:ball("ChocolateChip", at[4] or 6, CF(at[1], at[2], at[3]), choc)
		end
	end

	local receiver = arChassis(g, K, { hgLength = 226, barrelEnd = -380 }, {
		receiver = skin(g, tin),
		lower = skin(g, tin),
		furniture = biscuit,
		small = choc,
		rail = choc,
		magLook = biscuitDark,
		plate = choc,
		gripDress = function(g)
			for _, sx in ipairs(SIGNS) do
				g:ball("ChocolateChip", 5, CF(sx * 12, -30, 4), choc)
				g:ball("ChocolateChip", 4, CF(sx * 12, -62, -2), choc)
			end
		end,
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), tin)
			g:at(CF(0, 0, 205), function()
				-- The stock, with a bite taken out of its top rear corner: two blocks leave the notch, and the
				-- crumbs round it are the edge of the bite.
				g:rounded("Stock", V(40, 42, 110), CF(0, -3, -20), 13, biscuit)
				g:rounded("Stock", V(40, 20, 40), CF(0, -14, 55), 8, biscuit)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), biscuit)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, biscuitDark)
				for index, crumb in ipairs({ { 8, 2, 38, 7 }, { -6, 0, 44, 6 }, { 2, -2, 52, 8 }, { -10, 4, 30, 5 } }) do
					g:ball("StockCrumb", crumb[4], CF(crumb[1], crumb[2], crumb[3]), biscuitDark)
				end
				chips({ { 20, -8, -40 }, { 20, 6, -8 }, { -20, -2, -30 }, { -20, -10, 10 }, { 17, -40, 30, 5 }, { -17, -48, 20, 5 } })
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				-- A stack of chocolate-chip cookies threaded on a cream-filled core: every third one a chocolate
				-- cookie, each studded with chips on both faces and round its rim.
				g:cyl("HandguardCore", info.length, 40, CF(0, 0, 0), cream)
				local count = 7
				local pitch = info.length / count
				for index = 0, count - 1 do
					local z = -info.length / 2 + pitch * (index + 0.5)
					local dark = index % 3 == 1
					g:cyl("Handguard", pitch - 7, 58, CF(0, 0, z), dark and choc or biscuit)
					g:detail(function()
						for chip = 0, 4 do
							local angle = chip / 5 * math.pi * 2 + index * 0.9
							g:ball("ChocolateChip", 5, CF(math.cos(angle) * 28.2, math.sin(angle) * 28.2, z), dark and cream or choc)
						end
					end)
				end
				-- A block of chocolate on the front cookie for the front sight to stand on.
				g:box("HandguardRail", V(18, 9, 26), CF(0, 29 + 4.5 - 4, -info.length / 2 + 26), choc)
			end)
		end,
		muzzle = function(g, barrelEnd, barrelDia)
			-- A ring biscuit on the muzzle, holed through the middle.
			g:crown("MuzzleBrake", 16, 36, 12, CF(0, 0, barrelEnd - 8), biscuit)
			g:cyl("MuzzleCollar", 14, barrelDia + 4, CF(0, 0, barrelEnd + 2), choc)
			g:detail(function()
				for index = 0, 5 do
					local angle = index / 6 * math.pi * 2 + 0.3
					g:ball("ChocolateChip", 4.5, CF(math.cos(angle) * 12.5, math.sin(angle) * 12.5, barrelEnd - 16.5), choc)
				end
			end)
			return barrelEnd - 17
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 22.5, depth = 62, segments = { { 62, 0 }, { 24, 4 }, { 24, 4 }, { 24, 4 }, { 24, 4 } }, caliber = 9.5, plate = choc },
				CF(0, -52, -57), biscuitDark)
			-- A paper sleeve round the middle of the pack.
			g:box("MagazineSleeve", V(24.5, 40, 63), CF(0, -52 - 44, -57 + 1.5) * A(4, 0, 0), cream)
		end,
		sights = function(g, railTop, info)
			g:rearAperture(CF(0, railTop, 30), 36)
			g:frontPost(CF(0, 30.5 - 0.5, info.front + 26), 36.5)
			g:key("Sight", CF(0, railTop + 36, 40))
			g.model:SetAttribute("Optic", "iron")
			g.model:SetAttribute("EyeRelief", 0.3)
		end,
		dress = function(g)
			chips({ { 15.5, -34, -30, 5 }, { -15.5, -30, 20, 5 }, { 15.5, -26, 50, 4 } })
		end,
	})
	g.model:SetAttribute("Flair", "crumbs")
	g.model:SetAttribute("ShotCue", "GunshotCrumb")
	return receiver
end

--------------------------------------------------------------------------------
-- Common: Ciabatta Clonk -- the night-shift bakery's shotgun
--------------------------------------------------------------------------------

-- The bakery's night security gun: a charcoal receiver with an amber ID plate, a pump that is a floury
-- ciabatta loaf scored across the top, the stock the heel of a baguette, and breadsticks where the side
-- saddle's spare shells would be.
Builders.NightShiftPump = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local charcoal = skin(g, metal(K, 50, 55, 62))
	local crust = skin(g, look(K, 198, 142, 78))
	local crustDark = look(K, 150, 96, 48)
	local flour = look(K, 246, 240, 226, K.Mat.Sand)
	local amber = look(K, 232, 168, 48)
	local grissini = look(K, 222, 176, 108)

	local receiver = pumpChassis(g, K, {
		metal = charcoal,
		furniture = crust,
		receiverDress = function(g)
			g:box("IdPlate", V(FINE * 2, 16, 60), CF(-15.2, -16, -40), amber)
			g:detail(function()
				g:box("IdPlateStripe", V(FINE * 2 + 0.4, 3, 50), CF(-15.4, -12, -40), charcoal)
			end)
		end,
		pumpBody = function(g)
			-- The loaf: a low, wide rounded bread, darker along its bottom edge, flour on top and three scores.
			g:rounded("Pump", V(50, 44, 180), CF(0, -28, -300), 18, crust)
			g:rounded("PumpBase", V(52, 10, 170), CF(0, -46, -300), 5, crustDark)
			for index = 0, 2 do
				g:box("PumpScore", V(40, 4, 9), CF(0, -5, -250 - index * 50) * A(0, 35, 0), crustDark)
				g:box("PumpFlour", V(24, 2, 30), CF(0, -5.5, -275 - index * 50) * A(0, -20, 0), flour)
			end
		end,
		stock = function(g)
			g:at(CF(0, 0, 75), function()
				-- The heel of a baguette: long and round, scored, its end cut flat for a butt.
				g:rounded("Stock", V(44, 46, 330), CF(0, -24, 165), 18, crust)
				g:wedge("StockWeb", V(38, 100, 220), CF(0, -95, 245) * A(0, 0, 180), crust)
				g:prism("Buttpad", V(44, 146, 20), CF(0, -72, 340), 4, crustDark)
				g:box("ButtpadCrumb", V(36, 120, 3), CF(0, -72, 351.5), look(K, 244, 226, 186))
				for index = 0, 3 do
					g:box("StockScore", V(30, 4, 10), CF(0, 0, 90 + index * 62) * A(0, 40, 0), crustDark)
				end
			end)
		end,
		saddle = function(g)
			-- Breadsticks in the saddle.
			g:box("SideSaddle", V(4, 44, 110), CF(-17, -8, -40), charcoal)
			for index = 0, 4 do
				g:cylY("Grissini", 52, 10, CF(-25, -10, -80 + index * 20) * A(0, 0, (index % 2 == 0) and 4 or -4), grissini)
			end
			g:box("SaddleStrap", V(24, 8, 108), CF(-27, -20, -40), charcoal)
		end,
	})
	g.model:SetAttribute("Flair", "pump")
	g.model:SetAttribute("ShotCue", "GunshotClonk")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon: Crocodilo Rifle -- the crocodile bomber
--------------------------------------------------------------------------------

-- An AK gone to the swamp and taken to the sky: croc-green furniture with rows of scutes down the upper
-- handguard and the stock, a belly-pale magazine, the muzzle a crocodile's head -- eyes on top, nostrils at
-- the end, and a lower jaw that snaps -- and a bomber's tailplane on the butt.
Builders.CrocodiloRifle = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local croc = skin(g, look(K, 74, 118, 60))
	local crocDark = look(K, 46, 78, 38)
	local belly = look(K, 226, 214, 160)
	local tooth = look(K, 250, 248, 236)
	local iris = look(K, 250, 214, 60)
	local gunmetal = metal(K, 44, 52, 44)

	local receiver = stock(g, K, { pattern = "ak", woodFurniture = true })
	strip(g, { "^MuzzleBrake", "^Bore$", "^CleaningRod$", "^BayonetLug$" })
	paint(g, {
		{ "^MagazineRound", F.brass }, { "^MagazineBullet", F.copper }, { "^MagazineRib", crocDark }, { "^Magazine", belly },
		{ "^Handguard", croc }, { "^StockTang", gunmetal }, { "^Stock", croc }, { "^Grip", crocDark },
		{ "^Receiver", gunmetal }, { "^TopCover", gunmetal }, { "^Buttplate", crocDark }, { "^EjectionPort", F.shadow },
	})

	-- Scutes: two rows of ridged plates down the upper handguard and along the top of the stock.
	for index = 0, 5 do
		for _, sx in ipairs(SIGNS) do
			g:prism("Scute", V(7, 5, 12), CF(sx * 8, 39, -196 - index * 18), 2, crocDark, "top")
		end
	end
	for index = 0, 8 do
		for _, sx in ipairs(SIGNS) do
			g:prism("Scute", V(8, 5, 14), CF(sx * 8, 7.4, 150 + index * 21), 2, crocDark, "top")
		end
	end

	-- The head: a hinge block round the barrel's end, a snout for the upper jaw and a lower jaw on a hinge,
	-- teeth down both, nostrils at the tip and a pair of eyes on top.
	g:cyl("MuzzleExtension", 40, 18, CF(0, 0, -505), F.nitride)
	g:rounded("JawHinge", V(36, 32, 26), CF(0, 0, -513), 11, croc)
	g:prism("JawUpper", V(30, 10, 62), CF(0, 11, -556), 3, croc, "top")
	g:cyl("Bore", FINE, 12, CF(0, 0, -526 - FINE / 2), F.bore)
	for index = 0, 6 do
		for _, sx in ipairs(SIGNS) do
			g:wedge("JawTooth", V(3, 5, 5), CF(sx * 12, 3.5, -534 - index * 7.5) * A(0, 0, 180), tooth)
		end
	end
	for _, sx in ipairs(SIGNS) do
		g:ball("Nostril", 5, CF(sx * 6, 16, -582), crocDark)
		g:ball("EyeSocket", 13, CF(sx * 10, 17, -512), croc)
		g:ball("Eye", 8, CF(sx * 11.5, 20, -514), iris)
		g:box("EyePupil", V(1.6, 5.5, 2), CF(sx * 14.6, 20.5, -514.5), F.shadow)
	end
	g:group("jaw", function()
		g:prism("JawLower", V(28, 9, 58), CF(0, -11, -554), 3, croc, "bottom")
		g:box("JawChin", V(24, 4, 50), CF(0, -17, -552), belly)
		for index = 0, 6 do
			for _, sx in ipairs(SIGNS) do
				g:wedge("JawTooth", V(3, 5, 5), CF(sx * 11, -4, -532 - index * 7.5), tooth)
			end
		end
	end)
	g:swing("jaw", CF(0, -8, -524), -24)
	g:key("Muzzle", CF(0, 0, -528))

	-- The bomber's tail: a fin standing up off the back of the stock and a tailplane across the butt.
	g:wedge("TailFin", V(4, 42, 64), CF(0, 25.5, 312), croc)
	g:box("TailPlane", V(108, 4, 34), CF(0, 0, 328), croc)
	g:box("TailPlaneTip", V(6, 5, 30), CF(54, 0, 328), crocDark)
	g:box("TailPlaneTip", V(6, 5, 30), CF(-54, 0, 328), crocDark)

	g.model:SetAttribute("Flair", "chomp")
	g.model:SetAttribute("ShotCue", "GunshotCroc")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon: Tralala Shotgun -- the shark in sneakers
--------------------------------------------------------------------------------

-- A pump gun that is a shark from the grip forward: grey-blue on top and white below, gills cut into the
-- receiver, an eye either side, teeth round the muzzle, a dorsal fin and a crescent tail for a stock -- and
-- its pump is a blue high-top sneaker, laces and all.
Builders.TralalaShotgun = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local shark = skin(g, look(K, 104, 128, 156, K.Mat.SmoothPlastic, 0.05))
	local sharkDark = look(K, 72, 92, 116)
	local white = look(K, 240, 242, 244)
	local sneaker = look(K, 46, 104, 214)
	local sole = look(K, 246, 246, 240)
	local lace = look(K, 250, 250, 250)

	local receiver = pumpChassis(g, K, {
		metal = shark,
		furniture = shark,
		guard = white,
		barrel = sharkDark,
		tube = sharkDark,
		cap = white,
		receiverDress = function(g)
			-- The belly, three gills on each side, and the eyes.
			g:box("Belly", V(31.5, 16, 200), CF(0, -34, -30), white)
			for _, sx in ipairs(SIGNS) do
				for index = 0, 2 do
					g:box("Gill", V(FINE * 2, 26, 3), CF(sx * 15.2, -12, -100 + index * 12) * A(0, 0, sx * 8), sharkDark)
				end
				-- A pectoral fin swept out and down off each side of the belly.
				g:wedge("PectoralFin", V(4, 44, 58), CF(sx * 26, -44, -70) * A(0, 0, sx * 55), shark)
				g:ball("Eye", 13, CF(sx * 12.5, 2, -122), F.shadow)
				g:ball("EyeGlint", 4, CF(sx * 17.6, 5, -125), white)
			end
		end,
		front = function(g)
			-- A ring of teeth round the muzzle.
			for index = 0, 9 do
				g:wedge("MuzzleTooth", V(4, 5, 7), CF(0, 0, -618) * CFrame.Angles(0, 0, index / 10 * math.pi * 2) * CF(0, 13.5, 0) * A(0, 180, 0), white)
			end
		end,
		pumpBody = function(g)
			-- The sneaker: a white sole, the blue upper, a rounded toe, the heel tab and laces across the top.
			g:rounded("PumpSole", V(52, 12, 188), CF(0, -47, -300), 5, sole)
			g:rounded("Pump", V(46, 36, 166), CF(0, -24, -296), 13, sneaker)
			g:rounded("PumpToe", V(52, 24, 38), CF(0, -34, -378), 11, sole)
			g:rounded("PumpCollar", V(54, 14, 20), CF(0, -8, -216), 6, sole)
			g:box("PumpHeelTab", V(20, 14, 8), CF(0, -4, -206), sole)
			for index = 0, 4 do
				local z = -246 - index * 22
				g:box("PumpLace", V(36, 3, 4), CF(0, -5, z) * A(0, 28, 0), lace)
				g:box("PumpLace", V(36, 3, 4), CF(0, -5, z) * A(0, -28, 0), lace)
			end
			-- A lightning stripe down the outside of the shoe (the right: the left hand wraps the other side).
			g:box("PumpStripe", V(FINE * 2, 8, 60), CF(23.2, -24, -318) * A(-16, 0, 0), sole)
			g:box("PumpStripe", V(FINE * 2, 8, 50), CF(23.2, -30, -262) * A(16, 0, 0), sole)
		end,
		stock = function(g)
			g:at(CF(0, 0, 75), function()
				g:rounded("Stock", V(42, 44, 330), CF(0, -24, 165), 16, shark)
				g:rounded("StockBelly", V(40, 10, 300), CF(0, -44, 160), 4, white)
				g:wedge("StockWeb", V(38, 100, 220), CF(0, -95, 245) * A(0, 0, 180), white)
				-- The dorsal fin, behind the eye, and the crescent tail as the butt.
				g:wedge("DorsalFin", V(6, 62, 90), CF(0, 28, 225), shark)
				-- Two wedges make each lobe of the crescent, swept back from the butt.
				g:prism("Buttpad", V(40, 120, 16), CF(0, -60, 334), 4, sharkDark)
				g:wedge("TailFluke", V(10, 70, 46), CF(0, 30, 362) * A(-35, 0, 0), shark)
				g:wedge("TailFluke", V(10, 60, 46), CF(0, -140, 360) * A(215, 0, 0), shark)
			end)
		end,
	})
	g.model:SetAttribute("Flair", "sneaker")
	g.model:SetAttribute("ShotCue", "GunshotShark")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon: Lag Switch SMG -- the router
--------------------------------------------------------------------------------

-- A matte-black home router with a trigger: two antennas raked back off its shoulders, a row of status
-- lights down its side (one of them always amber), a vented modem for a handguard, a spool of yellow
-- network cable for a drum, and the wifi fan printed on its stock.
Builders.LagSwitchSMG = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local black = skin(g, look(K, 32, 34, 38))
	local grey = look(K, 70, 74, 80)
	local cable = look(K, 240, 200, 50)
	local cableDark = look(K, 200, 160, 30)
	local green = neon(K, 90, 255, 120)
	local amber = neon(K, 255, 180, 40)
	local cyan = neon(K, 90, 220, 255)

	local receiver = smgChassis(g, K, {
		metal = black,
		furniture = black,
		tube = grey,
		drum = true,
		receiverDress = function(g)
			-- Status lights down the left side.
			for index, light in ipairs({ green, green, amber, green, green }) do
				g:box("StatusLight", V(FINE * 2, 4, 7), CF(-15.3, 10, -40 + index * 16), light)
			end
			-- A scroll-wheel knob on the right, for turning the lag up.
			g:cylX("LagDial", 8, 30, CF(19, 4, 110), grey)
			g:detail(function()
				g:ridges("LagDialRib", 12, 12, 15.6, 2, 8, CF(19, 4, 110) * A(0, 90, 0), black)
			end)
			-- Vents across the top at the back.
			g:detail(function()
				for index = 0, 5 do
					g:box("Vent", V(24, FINE * 2, 3), CF(0, 20.2, 60 + index * 9), F.shadow)
				end
			end)
		end,
		front = function(g)
			g:cyl("Barrel", 150, 15, CF(0, 0, -215), F.nitride)
			g:rounded("Handguard", V(42, 40, 124), CF(0, -8, -205), 8, black)
			g:detail(function()
				for _, sx in ipairs(SIGNS) do
					for index = 0, 5 do
						g:box("HandguardVent", V(FINE * 2, 16, 4), CF(sx * 21, -8, -250 + index * 16), F.shadow)
					end
				end
			end)
			g:cyl("MuzzleBrake", 16, 18, CF(0, 0, -298), grey)
			g:cyl("MuzzleSignal", 4, 20, CF(0, 0, -293), cyan)
			-- Rabbit-ear antennas off the barrel band, splayed wide of the sight picture.
			for _, sx in ipairs(SIGNS) do
				g:box("AntennaHinge", V(10, 10, 12), CF(sx * 15, 18, -258), grey)
				g:at(CF(sx * 16, 22, -258) * A(-12, 0, -sx * 38), function()
					g:prism("Antenna", V(7, 64, 4), CF(0, 32, 0), 2, black)
					g:box("AntennaTip", V(7.4, 8, 4.4), CF(0, 62, 0), grey)
				end)
			end
			g:cyl("Bore", 2, 8, CF(0, 0, -307), F.bore)
			g:laserModule(CF(0, -44, -214))
			return -308
		end,
		mag = function(g)
			-- The cable spool: a feed tower into the well, the spool with its winding ridges and flanges.
			g:at(CF(0, -44, -76), function()
				g:box("Magazine", V(20, 42, 34), CF(0, -21, 0), black)
				local centre = CF(0, -42 - 50 + 8, -2)
				g:cylX("Magazine", 56, 96, centre, cable)
				for index = 0, 3 do
					g:cylX("MagazineCoil", 3, 98, centre * CF(-21 + index * 14, 0, 0), cableDark)
				end
				for _, sx in ipairs(SIGNS) do
					g:cylX("MagazineFlange", 4, 106, centre * CF(sx * 30, 0, 0), grey)
					g:cylX("MagazineHub", 6, 26, centre * CF(sx * 35, 0, 0), black)
				end
			end)
		end,
		stock = function(g)
			g:at(CF(0, 0, 168), function()
				g:rounded("Stock", V(36, 34, 200), CF(0, -2, 100), 11, black)
				g:wedge("StockWeb", V(32, 66, 180), CF(0, -52, 110) * A(0, 0, 180), black)
				g:rounded("Buttpad", V(40, 20, 104), CF(0, -34, 210) * A(90, 0, 0), 8, F.rubber)
				-- The wifi fan on each side of the stock.
				g:detail(function()
					for _, sx in ipairs(SIGNS) do
						for ring = 1, 3 do
							arc(g, K, "WifiFan", CF(sx * (18 + FINE), -14, 110), ring * 7, -45, 45, 5, 2, FINE * 2, cyan)
						end
						g:ball("WifiDot", 4, CF(sx * 18, -14, 110), cyan)
					end
				end)
			end)
		end,
	})
	g.model:SetAttribute("Flair", "lag")
	g.model:SetAttribute("ShotCue", "GunshotLag")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon: Scrolla Scrolla Brrrap -- the phone on a selfie stick
--------------------------------------------------------------------------------

-- Midnight blue, with a phone clamped to its left side, its screen lit and mid-scroll; a power bank for a
-- magazine; a selfie stick for a stock with a second phone in the clamp at its end; the camera bump for a
-- holographic sight.
Builders.DoomscrollSMG = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local navy = skin(g, look(K, 40, 49, 68))
	local phone = look(K, 24, 24, 28)
	local screen = neon(K, 70, 130, 230)
	local white = look(K, 236, 238, 240)
	local chrome = metal(K, 180, 184, 190, 0.2)
	local icons = { neon(K, 255, 90, 120), neon(K, 255, 200, 60), neon(K, 90, 230, 140), neon(K, 170, 110, 255) }

	local receiver = smgChassis(g, K, {
		metal = navy,
		furniture = look(K, 30, 36, 50),
		tube = navy,
		receiverDress = function(g)
			-- The phone on the left: a black slab, its lit screen, a scroll bar and a column of app tiles.
			g:rounded("Phone", V(8, 64, 150), CF(-19, 0, -5), 3, phone)
			g:box("PhoneScreen", V(1.2, 56, 138), CF(-23.4, 0, -5), screen)
			g:box("PhoneScrollBar", V(1.6, 16, 3), CF(-23.8, 14, 58), white)
			g:detail(function()
				for row = 0, 3 do
					for col = 0, 1 do
						g:box("PhoneApp", V(1.6, 10, 10), CF(-23.8, 18 - row * 13, -50 + col * 14), icons[(row + col) % 4 + 1])
					end
				end
				for index = 0, 3 do
					g:box("PhoneFeed", V(1.6, 3, 60), CF(-23.8, 18 - index * 9, 10), white)
				end
			end)
			g:box("PhoneClamp", V(10, 8, 30), CF(-13, 30, -5), chrome)
			g:box("PhoneClamp", V(10, 8, 30), CF(-13, -30, -5), chrome)
			-- A notification light and a lit "new posts" pill on the right.
			g:rounded("NotificationPill", V(3, 12, 34), CF(16.2, 12, 70), 1.4, icons[1])
			g:ball("NotificationDot", 6, CF(16.5, -10, 70), icons[3])
		end,
		sights = function(g)
			g:box("ClawRail", V(28, 12, 140), CF(0, 27, 40), navy)
			g:rail("OpticRail", 132, CF(0, 33, 40))
			local h = g:holo(CF(0, 42.5, 30))
			g:key("Sight", CF(0, 42.5 + h, 110))
			g.model:SetAttribute("Optic", "holo")
			g.model:SetAttribute("EyeRelief", 0.6)
			-- The front post stays on its tube, as the holo's backup.
			g:at(CF(0, 28, -282), function()
				g:box("FrontSightBase", V(26, 14.5, 26), CF(0, -2.75, 0), navy)
				g:box("FrontSight", V(2.2, 6, 3), CF(0, 6, 0), navy)
			end)
		end,
		front = function(g)
			g:cyl("Barrel", 150, 15, CF(0, 0, -215), F.nitride)
			g:rounded("Handguard", V(42, 40, 124), CF(0, -8, -205), 15, navy)
			g:cyl("MuzzleBrake", 16, 18, CF(0, 0, -298), F.nitride)
			g:cyl("Bore", 2, 8, CF(0, 0, -307), F.bore)
			g:laserModule(CF(0, -44, -214))
			return -308
		end,
		mag = function(g)
			-- The power bank, its four charge lights and the cable stub into the well.
			g:rounded("Magazine", V(24, 118, 38), CF(0, -40 - 59, -76), 6, white)
			g:detail(function()
				for index = 0, 3 do
					g:box("MagazineLight", V(FINE * 2, 3, 5), CF(-12.2, -130 + index * 8, -60), index < 3 and neon(K, 90, 230, 255) or F.shadow)
				end
			end)
			g:box("MagazinePort", V(16, 6, 12), CF(0, -160, -76), phone)
		end,
		stock = function(g)
			-- The selfie stick: three telescoping sections, a clamp on the end with a phone in it.
			g:box("StockYoke", V(34, 12, 18), CF(0, -6, 176), navy)
			local sections = { { 14, 60, 202 }, { 11, 60, 258 }, { 8, 60, 314 } }
			for _, section in ipairs(sections) do
				g:prism("SelfieStick", V(section[1], section[1], section[2]), CF(0, -6, section[3]), section[1] * 0.3, chrome)
			end
			g:box("SelfieClamp", V(18, 20, 14), CF(0, -6, 348), phone)
			g:rounded("Buttpad", V(40, 30, 104), CF(0, -26, 362) * A(90, 0, 0), 5, phone)
			g:box("ButtpadScreen", V(34, 1.2, 88), CF(0, -26, 377.6) * A(90, 0, 0), screen)
		end,
	})
	g.model:SetAttribute("Flair", "scroll")
	g.model:SetAttribute("ShotCue", "GunshotScroll")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon: Scarponcino Trotto Trotto -- the trail carbine
--------------------------------------------------------------------------------

-- A short carbine packed for a hike: an aluminium trekking-pole handguard with a foam grip where the hand
-- goes and a headlamp strapped round its nose, paracord wrapped round the stock and the magazine, a
-- compass set in the stock's side and a carabiner hanging off it.
Builders.TrailheadCarbine = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local olive = skin(g, look(K, 100, 112, 79))
	local tan = look(K, 214, 196, 150)
	local alu = metal(K, 176, 180, 186, 0.12)
	local foam = look(K, 40, 62, 110, K.Mat.Fabric)
	local cord = fabric(K, 230, 96, 40)
	local lamp = look(K, 40, 42, 46)
	local orange = look(K, 240, 120, 30)

	local receiver = arChassis(g, K, { hgLength = 226, barrelEnd = -380 }, {
		receiver = olive,
		lower = olive,
		furniture = tan,
		small = orange,
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), alu)
			g:at(CF(0, 0, 205), function()
				g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, tan)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), tan)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, F.rubber)
				-- Paracord wraps, the compass set in the left face, the carabiner under the heel.
				for index = 0, 3 do
					g:rounded("StockCord", V(42.5, 44.5, 5), CF(0, -3, -50 + index * 8), 14, cord)
				end
				g:cylX("Compass", 5, 30, CF(-21.5, -8, 30), alu)
				g:cylX("CompassFace", 1.4, 26, CF(-24.7, -8, 30), look(K, 240, 238, 226))
				g:box("CompassNeedle", V(1.6, 2, 20), CF(-25, -8, 30) * A(40, 0, 0), look(K, 210, 40, 40))
				g:box("CarabinerMount", V(10, 10, 12), CF(0, -94, 70), alu)
				arc(g, K, "Carabiner", CF(0, -112, 70), 12, 0, 360, 12, 3, 3, orange)
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				g:cyl("Handguard", info.length, 44, CF(0, 0, 0), alu)
				g:cyl("HandguardFoam", 80, 48, CF(0, 0, -info.length * 0.1), foam)
				for _, z in ipairs({ -info.length / 2 + 10, info.length / 2 - 10 }) do
					g:cyl("HandguardCollar", 12, 47, CF(0, 0, z), lamp)
				end
				g:box("HandguardRail", V(18, 9, 40), CF(0, 25 + 4.5 - 4, -info.length / 2 + 30), lamp)
				-- The headlamp on its band round the nose, its lamp on the left.
				g:cyl("HeadlampBand", 10, 46.4, CF(0, 0, -info.length / 2 + 46), orange)
				g:rounded("Headlamp", V(14, 26, 24), CF(-28, 0, -info.length / 2 + 46), 5, lamp)
				g:cylX("HeadlampLens", 2, 18, CF(-35.5, 0, -info.length / 2 + 46), look(K, 255, 250, 220, K.Mat.Glass, 0.3, 0.2))
			end)
		end,
		muzzle = function(g, barrelEnd)
			return barrelEnd + g:birdcage(CF(0, 0, barrelEnd), 22)
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 22.5, depth = 62, segments = { { 62, 0 }, { 24, 4 }, { 24, 4 }, { 24, 4 }, { 24, 4 } }, ribs = "stanag", caliber = 9.5, plate = orange },
				CF(0, -52, -57), lamp)
			for index = 0, 2 do
				g:box("MagazineCord", V(25, 4, 65), CF(0, -52 - 70 - index * 6, -55) * A(6, 0, 0), cord)
			end
		end,
		sights = function(g, railTop, info)
			g:rearAperture(CF(0, railTop, 30), 36)
			g:frontPost(CF(0, 30.5 - 0.5, info.front + 30), 36.5)
			g:key("Sight", CF(0, railTop + 36, 40))
			g.model:SetAttribute("Optic", "iron")
			g.model:SetAttribute("EyeRelief", 0.3)
		end,
	})
	g.model:SetAttribute("Flair", "compass")
	g.model:SetAttribute("ShotCue", "GunshotTrail")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare: Bananini Burst -- the banana rifle
--------------------------------------------------------------------------------

-- Half peeled: the handguard is the fruit with four strips of peel curling back off it, the vertical grip
-- a small banana, the magazine one long curved banana with a brown tip, a stem jutting out of the back of
-- the stock, and brown speckles over the yellow.
Builders.BananiniBurst = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local peel = skin(g, look(K, 250, 214, 60))
	local peelDark = look(K, 214, 170, 40)
	local flesh = look(K, 250, 242, 196)
	local brown = look(K, 112, 76, 40)
	local receiverLook = skin(g, look(K, 58, 50, 40))

	local function speckles(list)
		for _, at in ipairs(list) do
			g:ball("Speckle", 3.4, CF(at[1], at[2], at[3]), brown)
		end
	end

	local receiver = arChassis(g, K, {}, {
		receiver = receiverLook,
		lower = receiverLook,
		furniture = peel,
		small = brown,
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), receiverLook)
			g:at(CF(0, 0, 205), function()
				g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 16, peel)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), peel)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, brown)
				-- The stem, out of the back of the stock's top.
				g:cyl("BananaStem", 34, 12, CF(0, 8, 90) * A(-20, 0, 0), brown)
				g:cyl("BananaStemEnd", 6, 15, CF(0, 14, 106) * A(-20, 0, 0), look(K, 70, 50, 30))
				speckles({ { 20.5, 0, -40 }, { 20.5, -10, 10 }, { -20.5, 4, -20 }, { -20.5, -12, 30 }, { 17, -40, 20 } })
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				-- The fruit round the barrel, then four peel strips, each in three pieces curling out further
				-- toward the front.
				g:cyl("HandguardFruit", info.length, 40, CF(0, 0, 0), flesh)
				g:cyl("HandguardPeel", info.length * 0.5, 45, CF(0, 0, info.length * 0.25), peel)
				for index = 0, 3 do
					local angle = (index + 0.5) / 4 * math.pi * 2
					for piece = 0, 2 do
						local z = -info.length * 0.08 - piece * info.length * 0.16
						local out = 23 + piece * 3.5
						g:box("HandguardPeel", V(26, 3.5, info.length * 0.17), CFrame.Angles(0, 0, angle) * CF(0, out, z) * A(-8 - piece * 7, 0, 0), piece == 2 and peelDark or peel)
					end
				end
				speckles({ { 22.8, 3, info.length * 0.3 }, { -22.8, -4, info.length * 0.15 }, { 0, -22.8, info.length * 0.35 } })
			end)
			g:rail("HandguardRail", 90, CF(0, 21 - 4, info.z + info.length * 0.25))
		end,
		supportHand = function(g, info)
			-- A small banana for a vertical grip, hung from the peel collar.
			local z = info.z - info.length * 0.14
			g:box("ForeGripClamp", V(30, 12, 34), CF(0, -4 - 22.5 - 6, z), brown)
			g:at(CF(0, -4 - 22.5 - 12, z) * A(-8, 0, 0), function()
				g:rounded("ForeGrip", V(28, 30, 60), CF(0, -30, -2) * A(90, 0, 0), 12, peel)
				g:rounded("ForeGrip", V(24, 26, 24), CF(0, -64, -8) * A(70, 0, 0), 10, peel)
				g:cylY("ForeGripTip", 8, 12, CF(0, -80, -12), brown)
			end)
			g:hand("SupportHand", V(-27, -80, z + 6), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
		end,
		muzzle = function(g, barrelEnd)
			-- The flower end of the banana: a brown cap round the muzzle.
			g:cyl("MuzzleBrake", 26, 24, CF(0, 0, barrelEnd - 13), brown)
			g:cyl("MuzzleTip", 8, 16, CF(0, 0, barrelEnd - 30), look(K, 70, 50, 30))
			g:cyl("Bore", FINE, 9, CF(0, 0, barrelEnd - 34 - FINE / 2), F.bore)
			return barrelEnd - 35
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 22.5, depth = 62, segments = { { 62, 0 }, { 24, 6 }, { 24, 6 }, { 24, 6 }, { 24, 6 } }, caliber = 9.5, plate = brown },
				CF(0, -52, -57), peel)
			speckles({ { 11.6, -70, -60 }, { -11.6, -95, -50 }, { 11.6, -120, -38 } })
		end,
		sights = function(g, railTop)
			local h = g:holo(CF(0, railTop, -30))
			g:key("Sight", CF(0, railTop + h, 50))
			g.model:SetAttribute("Optic", "holo")
			g.model:SetAttribute("EyeRelief", 0.62)
		end,
	})
	g.model:SetAttribute("Flair", "peel")
	g.model:SetAttribute("ShotCue", "GunshotBanana")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare: Grass Toucher DMR -- the lawn rifle
--------------------------------------------------------------------------------

-- An M14 that has been outside: turf growing along its stock with daisies in it, a ladybird on the scope,
-- and the watering can's rose screwed on for a muzzle.
Builders.GrassToucherDMR = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local turf = K.finishOf(rgb(86, 150, 64), K.Mat.Grass)
	local blade = look(K, 110, 176, 70)
	local petal = look(K, 250, 250, 246)
	local centre = look(K, 250, 204, 50)
	local ladybird = look(K, 214, 40, 36)
	local tin = metal(K, 110, 150, 120, 0.1)

	local receiver = stock(g, K, { woodFurniture = true, laser = true })
	strip(g, { "^MuzzleBrake", "^MuzzleProng", "^BayonetLug", "^FrontSight" })
	paint(g, { { "^Receiver", skin(g, metal(K, 70, 84, 64)) } })

	-- Turf along the butt, grass blades standing out of it, three daisies.
	g:box("Turf", V(40, 7, 230), CF(0, -2.5, 305), turf)
	g:detail(function()
		for index = 0, 13 do
			local x = ((index * 7) % 5 - 2) * 7
			g:box("GrassBlade", V(2, 10, 2), CF(x, 5.5, 200 + index * 16) * A((index % 3 - 1) * 12, 0, (index % 2 == 0) and 10 or -10), blade)
		end
	end)
	for index, at in ipairs({ { -10, 3, 230 }, { 12, 3, 300 }, { -6, 3, 380 } }) do
		g:at(CF(at[1], at[2], at[3]), function()
			g:cylY("DaisyStem", 20, 2.6, CF(0, 7, 0), blade)
			for p = 0, 7 do
				local angle = p / 8 * math.pi * 2
				g:ball("DaisyPetal", 8, CF(math.cos(angle) * 7, 18, math.sin(angle) * 7), petal)
			end
			g:ball("DaisyCentre", 8, CF(0, 19, 0), centre)
		end)
	end
	-- A ladybird on top of the scope's tube.
	g:at(CF(0, 44.5 + 46 + 15, -40), function()
		g:ball("Ladybird", 12, CF(0, 2, 0), ladybird)
		g:ball("LadybirdHead", 6, CF(0, 1, -7), F.shadow)
		for _, spot in ipairs({ { 3, 7, 2 }, { -3, 7, -1 }, { 0, 7.6, 3 } }) do
			g:ball("LadybirdSpot", 2.4, CF(spot[1], spot[2], spot[3]), F.shadow)
		end
	end)
	-- The rose: a collar, a cone stepping out, and the face pricked with holes.
	g:cyl("RoseCollar", 16, 24, CF(0, 0, -568), tin)
	g:cyl("Rose", 12, 34, CF(0, 0, -582), tin)
	g:cyl("Rose", 12, 46, CF(0, 0, -594), tin)
	g:cyl("RoseFace", 3, 48, CF(0, 0, -601.5), tin)
	g:detail(function()
		for ring = 1, 2 do
			for index = 0, ring * 6 - 1 do
				local angle = index / (ring * 6) * math.pi * 2
				g:cyl("RoseHole", 2, 3, CF(math.cos(angle) * ring * 9, math.sin(angle) * ring * 9, -603.5), F.bore)
			end
		end
	end)
	g:cyl("Bore", 2, 7, CF(0, 0, -603.5), F.bore)
	g:key("Muzzle", CF(0, 0, -604))

	g.model:SetAttribute("Flair", "sniff")
	g.model:SetAttribute("ShotCue", "GunshotLawn")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare: Sigma Scout -- the grindset rifle
--------------------------------------------------------------------------------

-- Gym steel: a chrome receiver, black knurled furniture, a barbell's plates slid on over the handguard, a
-- dumbbell handle for a vertical grip, a protein shaker clipped where a light would go, and a kettlebell
-- hanging off the sling loop.
Builders.SigmaScout = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local chrome = skin(g, metal(K, 188, 192, 198, 0.2))
	local knurl = look(K, 34, 34, 38, K.Mat.Plastic)
	local plate = look(K, 30, 30, 34, K.Mat.Rubber)
	local rim = look(K, 236, 236, 236)
	local shaker = look(K, 240, 110, 40)
	local iron = metal(K, 52, 54, 58)

	local receiver = arChassis(g, K, { scale = 1.12, hgLength = 250, barrelEnd = -470, barrelDia = 19, action = "semi" }, {
		receiver = chrome,
		lower = chrome,
		furniture = knurl,
		small = iron,
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), iron)
			g:at(CF(0, 0, 205), function()
				g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, knurl)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), knurl)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, F.rubber)
				for index = 0, 5 do
					g:box("StockKnurl", V(41, 3, 3), CF(0, 6, -50 + index * 18), iron)
				end
				-- The kettlebell under the heel.
				g:box("KettlebellLoop", V(4, 12, 14), CF(0, -99, 60), chrome)
				arc(g, K, "KettlebellHandle", CF(0, -116, 60), 8, -80, 80, 8, 3.5, 3.5, iron)
				g:ball("Kettlebell", 26, CF(0, -134, 60), iron)
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				-- The bar: a knurled steel sleeve, collars, and two plates with white rims.
				g:cyl("Handguard", info.length, 44, CF(0, 0, 0), chrome)
				g:detail(function()
					for index = 0, 9 do
						g:cyl("HandguardKnurl", 3, 45.5, CF(0, 0, -info.length / 2 + 60 + index * 9), iron)
					end
				end)
				for _, z in ipairs({ -info.length / 2 + 22, -info.length / 2 + 40 }) do
					g:cyl("WeightPlate", 12, 82, CF(0, 0, z), plate)
					g:cyl("WeightPlateRim", 13, 84, CF(0, 0, z), rim)
					g:cyl("WeightPlateHub", 14, 50, CF(0, 0, z), chrome)
				end
				g:cyl("HandguardCollar", 10, 52, CF(0, 0, -info.length / 2 + 52), iron)
			end)
			g:rail("HandguardRail", 80, CF(0, 18, info.z + 50))
		end,
		supportHand = function(g, info)
			-- The dumbbell grip: a clamp, a knurled handle and a hex head at the bottom.
			local z = info.z - info.length * 0.14
			g:box("ForeGripClamp", V(30, 12, 34), CF(0, -4 - 22 - 6, z), iron)
			g:at(CF(0, -4 - 22 - 12, z) * A(-8, 0, 0), function()
				g:cylY("ForeGrip", 70, 28, CF(0, -35, 0), chrome)
				g:detail(function()
					for index = 0, 4 do
						g:cylY("ForeGripKnurl", 2.5, 29.5, CF(0, -12 - index * 11, 0), iron)
					end
				end)
				g:cylY("ForeGripWeight", 16, 44, CF(0, -76, 0), plate)
			end)
			g:hand("SupportHand", V(-27, -80, z + 6), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
			-- The protein shaker on the left, capped.
			g:box("ShakerStrap", V(8, 34, 12), CF(-30, 4, info.front + 70), iron)
			g:cyl("Shaker", 90, 30, CF(-37.5, 0, info.front + 50), shaker)
			g:cyl("ShakerCap", 16, 32, CF(-37.5, 0, info.front + 2), rim)
			g:cyl("ShakerSpout", 8, 12, CF(-37.5, 0, info.front - 10), rim)
		end,
		muzzle = function(g, barrelEnd, barrelDia)
			return barrelEnd + g:brake(CF(0, 0, barrelEnd), barrelDia + 9, 64)
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 24, depth = 70, segments = { { 64, 0 }, { 30, 3 }, { 30, 3 } }, ribs = "stanag", caliber = 10.5, plate = chrome },
				CF(0, -52, -57), iron)
		end,
		sights = function(g, railTop)
			local h = g:scope(CF(0, railTop, -15), "lpvo")
			g:key("Sight", CF(0, railTop + h, 150))
			g.model:SetAttribute("Optic", "scope")
			g.model:SetAttribute("EyeRelief", 0.6)
		end,
	})
	g.model:SetAttribute("Flair", "curl")
	g.model:SetAttribute("ShotCue", "GunshotSigma")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare: Prato Prato Pium -- the picnic scout
--------------------------------------------------------------------------------

-- A scout rifle for a day in the meadow: a wicker stock, a red-and-white gingham handguard, a flower
-- round the muzzle, and a butterfly resting on the scope.
Builders.TouchGrassScout = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local field = skin(g, look(K, 80, 106, 64))
	local wicker = look(K, 206, 164, 100, K.Mat.Fabric)
	local wickerDark = look(K, 150, 110, 60)
	local red = look(K, 206, 50, 50, K.Mat.Fabric)
	local white = look(K, 246, 244, 236, K.Mat.Fabric)
	local pink = look(K, 250, 140, 190)
	local yellow = look(K, 250, 214, 60)
	local wingA, wingB = look(K, 255, 150, 40), look(K, 80, 150, 250)

	local receiver = arChassis(g, K, { scale = 1.12, hgLength = 250, barrelEnd = -470, barrelDia = 19, action = "semi" }, {
		receiver = field,
		lower = field,
		furniture = wicker,
		small = wickerDark,
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), field)
			g:at(CF(0, 0, 205), function()
				g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, wicker)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), wicker)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, wickerDark)
				-- The weave: strands crossing on both sides.
				g:detail(function()
					for _, sx in ipairs(SIGNS) do
						for index = 0, 5 do
							g:box("StockWeave", V(FINE * 2, 3, 46), CF(sx * 20.2, -3, -54 + index * 20) * A(35, 0, 0), wickerDark)
							g:box("StockWeave", V(FINE * 2, 3, 46), CF(sx * 20.2, -3, -44 + index * 20) * A(-35, 0, 0), wickerDark)
						end
					end
				end)
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				g:rounded("Handguard", V(44, 46, info.length), CF(0, 0, 0), 12, red)
				-- The gingham: white squares on both sides and the bottom in a check.
				g:detail(function()
					for row = 0, 2 do
						for col = 0, 9 do
							if (row + col) % 2 == 0 then
								for _, sx in ipairs(SIGNS) do
									g:box("HandguardCheck", V(FINE * 2, 10, 20), CF(sx * 22.2, -12 + row * 12, -info.length / 2 + 20 + col * 23), white)
								end
							end
						end
					end
				end)
			end)
			g:rail("HandguardRail", 90, CF(0, 19, info.z + 60))
		end,
		muzzle = function(g, barrelEnd, barrelDia)
			local z = barrelEnd + g:brake(CF(0, 0, barrelEnd), barrelDia + 9, 64)
			-- The flower: petals round the brake's collar.
			for index = 0, 7 do
				local angle = index / 8 * math.pi * 2
				g:ball("Petal", 11, CF(math.cos(angle) * 17, math.sin(angle) * 17, barrelEnd - 6), pink)
			end
			g:cyl("PetalCentre", 6, 32, CF(0, 0, barrelEnd - 4), yellow)
			return z
		end,
		mag = function(g)
			g:magazine("Magazine", { width = 24, depth = 70, segments = { { 64, 0 }, { 30, 3 }, { 30, 3 } }, ribs = "stanag", caliber = 10.5, plate = wickerDark },
				CF(0, -52, -57), field)
		end,
		sights = function(g, railTop)
			local h = g:scope(CF(0, railTop, -15), "lpvo")
			g:key("Sight", CF(0, railTop + h, 150))
			g.model:SetAttribute("Optic", "scope")
			g.model:SetAttribute("EyeRelief", 0.6)
			-- The butterfly on the scope's saddle, wings up.
			g:at(CF(0, railTop + h + 16.5, -30), function()
				g:box("ButterflyBody", V(3, 3, 16), CF(0, 0, 0), F.shadow)
				for _, sx in ipairs(SIGNS) do
					g:box("ButterflyWing", V(1.2, 16, 14), CF(sx * 6, 7, -3) * A(0, 0, -sx * 30), wingA)
					g:box("ButterflyWing", V(1.2, 11, 10), CF(sx * 5, 5, 7) * A(0, 0, -sx * 40), wingB)
				end
			end)
		end,
	})
	g.model:SetAttribute("Flair", "breeze")
	g.model:SetAttribute("ShotCue", "GunshotMeadow")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare: Aura Scattergun -- the halo shotgun
--------------------------------------------------------------------------------

-- Pearl-white and lilac, with halos of light round the handguard and the choke, feathered wings folded
-- along the stock, and a crystal drum with a glowing core.
Builders.AuraScattergun = function(g, K)
	local V, CF, A, F, FINE = K.V, K.CF, K.A, K.F, K.FINE
	local pearl = skin(g, look(K, 238, 234, 246, K.Mat.SmoothPlastic, 0.2))
	local lilac = look(K, 186, 156, 232)
	local halo = neon(K, 255, 236, 150)
	local feather = look(K, 250, 250, 255)
	local crystal = glass(K, 200, 180, 255, 0.45)
	local core = neon(K, 200, 140, 255)

	local receiver = arChassis(g, K, { scale = 1.18, hgLength = 230, barrelEnd = -420, barrelDia = 22, action = "semi", flash = "shotgun", casing = "shell" }, {
		receiver = pearl,
		lower = pearl,
		furniture = lilac,
		small = look(K, 200, 170, 90, K.Mat.Metal),
		stock = function(g)
			g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), pearl)
			g:at(CF(0, 0, 205), function()
				g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, lilac)
				g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), lilac)
				g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, pearl)
				-- Wings folded back along the stock, three feathers a side.
				for _, sx in ipairs(SIGNS) do
					for index = 0, 2 do
						g:wedge("WingFeather", V(3, 38 - index * 7, 120 - index * 18), CF(sx * 21.5, 10 - index * 12, 18 + index * 10) * A(0, 0, sx * 12), feather)
					end
				end
			end)
		end,
		handguard = function(g, info)
			g:at(CF(0, -4, info.z), function()
				g:rounded("Handguard", V(44, 48, info.length), CF(0, 0, 0), 14, pearl)
				for index = 0, 2 do
					g:shell("Halo", 5, 58, 3, CF(0, 0, -info.length / 2 + 40 + index * 60), halo, 14)
				end
			end)
			g:rail("HandguardRail", 90, CF(0, 20, info.z + 50))
		end,
		supportHand = function(g, info)
			local z = info.z - info.length * 0.14
			g:foregrip(CF(0, -4 - 25, z))
			g:hand("SupportHand", V(-27, -80, z + 6), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
		end,
		muzzle = function(g, barrelEnd, barrelDia)
			g:cyl("MuzzleBrake", 36, barrelDia + 5, CF(0, 0, barrelEnd - 18), pearl)
			g:shell("MuzzleHalo", 4, barrelDia + 22, 3, CF(0, 0, barrelEnd - 26), halo, 14)
			for _, sx in ipairs(SIGNS) do
				g:box("MuzzleHaloSpoke", V(8, 3, 3), CF(sx * (barrelDia / 2 + 6.5), 0, barrelEnd - 26), pearl)
			end
			g:cyl("Bore", FINE, barrelDia - 3, CF(0, 0, barrelEnd - 36 - FINE / 2), F.bore)
			return barrelEnd - 38
		end,
		mag = function(g)
			-- The crystal drum, and the core glowing inside it.
			g:at(CF(0, -52, -57), function()
				g:box("Magazine", V(20, 42, 34), CF(0, -21, 0), pearl)
				local centre = CF(0, -42 - 85 + 8, -2)
				g:cylX("Magazine", 64, 170, centre, crystal)
				g:cylX("MagazineCore", 50, 60, centre, core)
				for _, sx in ipairs(SIGNS) do
					g:cylX("MagazineRim", 4, 174, centre * CF(sx * 33, 0, 0), pearl)
				end
			end)
		end,
		sights = function(g, railTop)
			local h = g:holo(CF(0, railTop, -30))
			g:key("Sight", CF(0, railTop + h, 50))
			g.model:SetAttribute("Optic", "holo")
			g.model:SetAttribute("EyeRelief", 0.62)
		end,
	})
	g.model:SetAttribute("Flair", "halo")
	g.model:SetAttribute("ShotCue", "GunshotAura")
	return receiver
end

return GunModelsSignature
