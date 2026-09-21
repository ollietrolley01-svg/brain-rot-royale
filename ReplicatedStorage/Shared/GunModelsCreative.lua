-- Creative gun models: the everyday-object guns from CreativeArsenal.
--
-- GunModels.Build calls Builders[weaponId](g, Kit) for these ids instead of the style's stock builder,
-- and does everything after the build itself (the AimPoint, the z-fight pass, the Receiver, the Muzzle
-- attachment and welds). `g` is GunModels' Builder: every size and position below is in millimetres,
-- the origin on the bore axis above the trigger, the gun facing -Z with +X to the right. Each builder
-- returns its receiver part.
--
-- Each gun keeps the stock animation contract of the mechanism it borrows (Action), with the stock
-- keypoint layout for that mechanism, so the viewmodel's reload, rack and fire clips work unchanged:
--   pistol    slide group + Travel_slide, ChargeHand on the slide, Eject, a magazine in the grip
--   smg       bolt and charge groups + travel, ChargeHand, Eject, a box magazine forward of the grip
--   pump      pump group + Travel_pump, SupportHand riding it (SupportGroup), Load, Eject
--   blaster   the pump group as above plus a detachable magazine
--   rotary    the spin group turning about Pivot_spin (its X axis laid along the bore), a box magazine
--   rocket    one round group loaded at Load, fired from Muzzle
--   crossbow  string / stringRest groups (drawn and loosed), a round group at Load, ChargeHand
--   energy    charge group + travel and ChargeHand, a magazine
--   semi      bolt and charge groups, Eject, a box magazine
-- Sights follow the ADS contract: KP_Sight on the line the eye looks along, Optic, EyeRelief. Every
-- decoration is kept off that line and clear of the hands; tools/ads_align_probe.lua,
-- gun_gaps_probe.lua and ads_hands_probe.lua check each gun, gun_flush_probe.lua what z-fighting the
-- model's nudge pass couldn't fix, and gun_anim_probe.lua that a gun carries everything its Action needs.

local GunModelsCreative = {}

-- No variants yet: each creative gun is one design.
GunModelsCreative.Variants = {}

local Builders = {}
GunModelsCreative.Builders = Builders

local SIGNS = { 1, -1 }

-- A box spanning two points (a strut, a strap, a noodle).
local function strut(g, K, name, from, to, width, look)
	local length = (to - from).Magnitude
	return g:box(name, K.V(width, width, length), CFrame.lookAt((from + to) / 2, to), look)
end

-- A cylinder spanning two points.
local function rod(g, K, name, from, to, diameter, look)
	return g:cyl(name, (to - from).Magnitude, diameter, CFrame.lookAt((from + to) / 2, to), look)
end

local function plastic(K, r, g, b)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.SmoothPlastic)
end

local function glossy(K, r, g, b, reflectance)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.SmoothPlastic, reflectance or 0.15)
end

local function neon(K, r, g, b)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.Neon)
end

-- A trigger in its guard, the swing the viewmodel pulls it through.
local function trigger(g, K, z, bottom, look, guardLook)
	local V, CF, A = K.V, K.CF, K.A
	g:box("TriggerGuard", V(12, 6, 58), CF(0, bottom - 3, z + 8), guardLook)
	g:box("TriggerGuard", V(12, 26, 6), CF(0, bottom + 10, z - 22), guardLook)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, bottom + 18, z) * A(-10, 0, 0), look)
	end)
	g:swing("trigger", CF(0, bottom + 26, z + 2), 12)
end

--------------------------------------------------------------------------------
-- Common
--------------------------------------------------------------------------------

-- A bath-toy pistol: sky-blue frame, a yellow slide with an orange safety tip, and a rubber duck
-- perched beside the rear sight. Pistol mechanism, pistol keypoints.
Builders.SqueakyDuckPopper = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local frameLook = g.skinned and g.skin or plastic(K, 86, 176, 232)
	local slideLook = plastic(K, 255, 214, 64)
	local orange = plastic(K, 255, 128, 32)
	local front, back = -111, 77

	local frame = g:rounded("Frame", V(24, 22, 150), CF(0, -14, -22), 4, frameLook)
	g:box("FrameRail", V(20, 6, 60), CF(0, -26, -60), frameLook)

	g:group("slide", function()
		g:rounded("Slide", V(26, 26, back - front), CF(0, 4, (front + back) / 2), 7, slideLook)
		for index = 0, 5 do
			g:box("SlideSerration", V(27.5, 16, 3), CF(0, 4, back - 14 - index * 7), plastic(K, 232, 186, 40))
		end
		g:cyl("MuzzleCap", 14, 22, CF(0, 2, front - 5), orange)
		g:cyl("Bore", K.FINE, 10, CF(0, 0, front - 12 - K.FINE / 2), F.bore)
		-- Sights: a post at the front, a notch at the back, both tops on the line.
		g:box("FrontSightBase", V(8, 3, 10), CF(0, 17.5, front + 12), slideLook)
		g:box("FrontSight", V(3.5, 5, 6), CF(0, 19.5, front + 12), orange)
		g:box("RearSightBase", V(20, 4, 8), CF(0, 17.6, back - 12), slideLook)
		for _, sx in ipairs(SIGNS) do
			g:box("RearSight", V(7, 5, 7), CF(sx * 6.5, 19.5, back - 12), orange)
		end
	end)
	g:travel("slide", 58)
	g:key("Eject", CF(14, 8, -10) * A(0, -60, 0))
	g:key("Sight", CF(0, 22, back - 6))
	g:hand("ChargeHand", V(-4, 34, back - 22), V(1, -0.45, 0.1), V(0, 1, 0.1))

	-- The duck, on a perch off the frame's left side, clear of the slide's travel and of the sights.
	g:box("DuckPerch", V(22, 6, 24), CF(-21, -7, 52), frameLook)
	g:at(CF(-30, 4, 52), function()
		local yellow = plastic(K, 255, 220, 40)
		g:ball("DuckBody", 28, CF(0, 0, 0), yellow)
		g:ball("DuckTail", 12, CF(0, 8, 14), yellow)
		g:ball("DuckHead", 20, CF(0, 18, -10), yellow)
		g:wedge("DuckBeak", V(10, 5, 12), CF(0, 16, -22) * A(0, 180, 0), orange)
		for _, sx in ipairs(SIGNS) do
			g:ball("DuckEye", 4, CF(sx * 7, 21, -16), F.shadow)
		end
	end)

	trigger(g, K, 2, -40, orange, frameLook)
	local gripFrame = g:grip(V(0, -26, 40), 15, frameLook, { length = 100, depth = 54, front = 24, back = 30, grooves = 3 })
	g:at(gripFrame, function()
		g:group("mag", function()
			g:box("Magazine", V(19, 96, 32), CF(0, -54, 2), plastic(K, 60, 140, 200))
			g:prism("MagazinePlate", V(25, 7, 42), CF(0, -103.5, 2), 2, orange, "bottom")
		end)
		g:key("MagWell", CF(0, -100, 2))
	end)
	g:hand("GripHand", V(30, -62, 52), V(-0.3, 0.1, -1), V(1, 0.15, 0.3))
	g:hand("SupportHand", V(-33, -74, 38), V(0.55, -0.05, -1), V(-1, -0.1, -0.3))
	g:hand("MagHand", V(-26, -136, 62), V(0.35, 0.3, -0.2), V(-1, -0.1, 0))

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 1.1)
	g.model:SetAttribute("Action", "pistol")
	g.model:SetAttribute("Flash", "squeak")
	g.model:SetAttribute("Casing", "none")
	g:key("Muzzle", CF(0, 0, front - 14))
	return frame
end

-- A squirt SMG: a teal pressure body, an orange nozzle, a pump-grip, and a clear juice box for a
-- magazine with its bendy straw feeding the gun. SMG mechanism, SMG keypoints.
Builders.JuiceBoxSquirter = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or plastic(K, 40, 190, 180)
	local orange = plastic(K, 255, 140, 40)
	local white = plastic(K, 240, 240, 236)

	local receiver = g:rounded("Receiver", V(40, 50, 300), CF(0, -2, -20), 12, body)
	g:rounded("Tank", V(34, 30, 180), CF(0, -34, -70), 10, K.finishOf(Color3.fromRGB(150, 230, 255), K.Mat.Glass, 0.2, 0.55))
	g:rounded("TankWater", V(26, 16, 160), CF(0, -40, -70), 6, K.finishOf(Color3.fromRGB(80, 170, 255), K.Mat.SmoothPlastic, 0, 0.35))
	-- The nozzle, stepped down to a point.
	g:cyl("Barrel", 150, 18, CF(0, 0, -240), orange)
	g:cyl("MuzzleBrake", 30, 12, CF(0, 0, -330), orange)
	g:cyl("Bore", K.FINE, 6, CF(0, 0, -345 - K.FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -348))

	-- The bolt and the charging knob on the left, as on the stock SMG.
	g:group("bolt", function()
		g:box("BoltCarrier", V(10, 12, 40), CF(16, 8, -30), white)
	end)
	g:travel("bolt", 40)
	g:key("Eject", CF(20, 8, -30) * A(0, -70, 0))
	g:group("charge", function()
		g:box("ChargingHandle", V(14, 10, 12), CF(-24, 8, -120), orange)
		g:ball("ChargingKnob", 14, CF(-34, 8, -120), orange)
	end)
	g:travel("charge", 60)
	g:hand("ChargeHand", V(-44, 20, -122), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))

	-- Toy sights: a notch on a fin at the back, a post on a fin at the front, tops on the line (y=37).
	g:box("RearSightBase", V(26, 14, 20), CF(0, 28, 90), body)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSight", V(8, 12, 8), CF(sx * 7, 31, 92), white)
	end
	g:box("FrontSightBase", V(10, 14, 16), CF(0, 28, -150), body)
	g:box("FrontSight", V(3, 8, 5), CF(0, 33, -150), white)
	g:key("Sight", CF(0, 37, 100))

	trigger(g, K, 24, -46, orange, body)
	g:grip(V(0, -26, 66), 16, body, { length = 98, depth = 46, front = 22, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -64, 82), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- The juice box: clear carton, juice, a label band, and the straw bending up into the gun.
	g:group("mag", function()
		g:box("Magazine", V(40, 76, 30), CF(0, -66, -76), K.finishOf(Color3.fromRGB(255, 250, 240), K.Mat.Glass, 0.15, 0.5))
		g:box("MagazineJuice", V(34, 52, 24), CF(0, -76, -76), K.finishOf(Color3.fromRGB(255, 150, 40), K.Mat.SmoothPlastic, 0, 0.2))
		g:box("MagazineLabel", V(41.5, 18, 31.5), CF(0, -86, -76), K.finishOf(g.accent, K.Mat.SmoothPlastic))
		rod(g, K, "MagazineStraw", V(0, -30, -76), V(0, -36, -76), 7, plastic(K, 255, 90, 150))
		rod(g, K, "MagazineStraw", V(0, -36, -76), V(0, -28, -88), 7, plastic(K, 255, 90, 150))
	end)
	-- The carton clips into a collar under the body rather than hanging off the straw.
	g:box("MagazineCollar", V(48, 12, 38), CF(0, -28, -76), body)
	g:key("MagWell", CF(0, -28, -76))
	g:hand("MagHand", V(-30, -120, -80), V(0.4, 0.25, -0.2), V(-1, -0.15, 0))

	-- The pump-grip the left hand holds.
	g:rounded("ForeGrip", V(34, 30, 70), CF(0, -24, -212), 10, orange)
	g:hand("SupportHand", V(-12, -44, -212), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	-- A stubby stock.
	g:rounded("Stock", V(30, 40, 90), CF(0, -8, 170), 10, body)
	g:rounded("Buttpad", V(34, 46, 16), CF(0, -8, 220), 8, orange)

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.45)
	g.model:SetAttribute("Action", "smg")
	g.model:SetAttribute("Flash", "droplets")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Uncommon
--------------------------------------------------------------------------------

-- A pump shotgun with a stockpot for a receiver, a wooden-spoon pump and stock, and a colander rim for
-- a muzzle with noodles hanging off it. Pump mechanism, pump keypoints; the bead's crown is on the line.
Builders.SpaghettiSlinger = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local pot = g.skinned and g.skin or K.finishOf(Color3.fromRGB(200, 204, 210), K.Mat.Metal, 0.12)
	local wood = F.woodLight
	local noodle = plastic(K, 246, 212, 120)
	local sauce = plastic(K, 196, 44, 30)

	-- The pot's top stays 7 mm under the sight line (y = 23) so the pump's kick never lifts it into view.
	local receiver = g:cyl("Receiver", 220, 44, CF(0, -6, -30), pot)
	g:cyl("ReceiverRim", 8, 50, CF(0, -6, -142), pot)
	for _, sx in ipairs(SIGNS) do
		g:cylY("PotHandle", 8, 30, CF(sx * 34, -6, -30), F.shadow)
	end
	g:box("SauceDrip", V(20, 3, 30), CF(0, -24, -80), sauce)
	g:cyl("Barrel", 470, 24, CF(0, 0, -370), F.steel)
	g:cyl("MagTube", 400, 20, CF(0, -26, -330), pot)

	-- The colander rim at the muzzle: a ring of staves round the bore with a perforated flare, open in
	-- the middle so the bead and the target show through it.
	g:at(CF(0, 0, -618), function()
		-- Three spokes off the barrel's end carry the rim, none of them at the top.
		for _, degrees in ipairs({ 210, 270, 330 }) do
			local angle = math.rad(degrees)
			strut(g, K, "ColanderSpoke", V(math.cos(angle) * 8, math.sin(angle) * 8, 18), V(math.cos(angle) * 37, math.sin(angle) * 37, 0), 5, pot)
		end
		for index = 0, 15 do
			g:box("ColanderRim", V(15, 5, 6), CFrame.Angles(0, 0, index / 16 * math.pi * 2) * CF(0, 38, 0), pot)
		end
		for index = 0, 11 do
			local angle = index / 12 * math.pi * 2
			-- Each plank starts on the rim (radius 38) and flares out and back, so the inner edge stays
			-- well above the sight line (y = 23) at the top of the ring.
			g:box("ColanderWall", V(16, 3, 26), CFrame.Angles(0, 0, angle) * CF(0, 46, 10) * A(-40, 0, 0), pot)
			g:box("ColanderHole", V(4, 3 + K.FINE * 2, 4), CFrame.Angles(0, 0, angle) * CF(0, 46, 10) * A(-40, 0, 0), F.shadow)
		end
		-- Noodles hanging from the lower half of the rim only, never across the top.
		for index = 1, 5 do
			local angle = math.rad(200 + index * 28)
			local start = V(math.cos(angle) * 38, math.sin(angle) * 38, 0)
			local sway = V(math.cos(angle) * 6, -24 - index * 3, 6)
			strut(g, K, "Noodle", start, start + sway, 3, noodle)
			strut(g, K, "Noodle", start + sway, start + sway + V(-3, -14, 4), 3, noodle)
		end
	end)
	-- The bead on a post off the barrel, its crown on the line at y = 23.
	g:box("FrontSightPost", V(4, 9, 4), CF(0, 14, -606), F.steel)
	g:ball("FrontBead", 5, CF(0, 20.5, -606), F.brass)
	g:key("Muzzle", CF(0, 0, -624))

	-- The wooden-spoon pump.
	g:group("pump", function()
		g:rounded("Pump", V(46, 40, 180), CF(0, -28, -300), 16, wood)
		g:ball("PumpBowl", 44, CF(0, -34, -400), wood)
	end)
	g:travel("pump", 85)
	g:hand("SupportHand", V(-8, -56, -300), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "pump")
	g:key("Eject", CF(20, -2, -45) * A(0, -70, 0))
	-- Shells go in through the port in the pot's underside.
	g:key("Load", CF(0, -26, -60))

	trigger(g, K, 28, -48, F.steel, pot)
	g:grip(V(0, -26, 72), 22, wood, { length = 96, depth = 46, front = 22, back = 30 })
	g:hand("GripHand", V(31, -68, 104), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	-- The spoon-handle stock.
	rod(g, K, "Stock", V(0, -18, 90), V(0, -40, 330), 36, wood)
	g:ball("StockBowl", 60, CF(0, -44, 350), wood)
	g:box("MeatballBadge", V(3, 12, 12), CF(19, -24, 180), sauce)

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.8)
	g:key("Sight", CF(0, 23, 40))
	g.model:SetAttribute("Action", "pump")
	g.model:SetAttribute("Flash", "noodle")
	g.model:SetAttribute("Casing", "shell")
	return receiver
end

-- A cassette boombox blaster: a chunky body with a speaker cone for a muzzle, an LED-meter holo on top,
-- a tape-deck slider as the pump and a cassette as the magazine. Blaster mechanism.
Builders.BoomboxBassline = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or plastic(K, 52, 54, 62)
	local chrome = K.finishOf(Color3.fromRGB(196, 198, 204), K.Mat.Metal, 0.25)
	local purple = neon(K, 170, 90, 255)

	local receiver = g:rounded("Receiver", V(76, 84, 250), CF(0, -8, -70), 14, body)
	-- Speaker grille panels on each side, with the tape window on the left.
	for _, sx in ipairs(SIGNS) do
		g:box("SideGrille", V(3, 56, 110), CF(sx * 38.5, -8, -120), F.shadow)
		for index = 0, 5 do
			g:box("SideGrilleBar", V(4, 3, 104), CF(sx * 40, -28 + index * 8, -120), chrome)
		end
	end
	g:box("TapeWindow", V(3, 30, 60), CF(-38.5, -6, 10), K.finishOf(Color3.fromRGB(120, 140, 160), K.Mat.Glass, 0.2, 0.5))
	for _, dz in ipairs({ -16, 16 }) do
		g:cylX("TapeReel", 4, 18, CF(-37, -6, 10 + dz), F.shadow)
	end
	-- The front speaker: a surround, the cone and a dust cap, round the bore.
	g:at(CF(0, 0, -200), function()
		g:cyl("SpeakerSurround", 10, 70, CF(0, 0, -2), F.rubber)
		g:shell("SpeakerCone", 26, 56, 4, CF(0, 0, -18), plastic(K, 30, 30, 34), 12)
		g:cyl("SpeakerPole", 22, 12, CF(0, 0, -14), chrome)
		g:cyl("SpeakerCap", 6, 20, CF(0, 0, -24), chrome)
		g:cyl("SpeakerRing", 6, 74, CF(0, 0, 4), chrome)
	end)
	g:key("Muzzle", CF(0, 0, -232))
	-- The top: a rail and an LED-meter holo.
	g:rail("TopRail", 150, CF(0, 34, -40))
	local h = g:holo(CF(0, 43.5, -50))
	g:key("Sight", CF(0, 43.5 + h, 30))
	g.model:SetAttribute("Optic", "holo")
	g.model:SetAttribute("EyeRelief", 0.62)
	for index = 0, 4 do
		g:box("EqualizerLed", V(3, 4 + index * 3, 5), CF(38.5, 20 + index * 1.5, -40 + index * 9), purple)
	end

	-- The tape-deck slider under the body is the pump.
	g:group("pump", function()
		g:rounded("Pump", V(40, 26, 100), CF(0, -62, -150), 8, chrome)
	end)
	g:travel("pump", 50)
	g:hand("SupportHand", V(-6, -82, -150), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "pump")
	g:hand("ChargeHand", V(-6, -82, -150), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	trigger(g, K, 8, -80, chrome, body)
	g:grip(V(0, -50, 60), 12, body, { length = 96, depth = 46, front = 22, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -88, 80), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- The cassette magazine, on its edge.
	g:group("mag", function()
		g:box("Magazine", V(16, 64, 90), CF(0, -80, -40), plastic(K, 240, 236, 226))
		g:box("MagazineLabel", V(17.5, 30, 70), CF(0, -74, -40), K.finishOf(g.accent, K.Mat.SmoothPlastic))
		for _, dz in ipairs({ -22, 22 }) do
			g:cylX("MagazineReel", 18, 16, CF(0, -94, -40 + dz), F.shadow)
		end
	end)
	g:box("TapeDeck", V(26, 20, 100), CF(0, -50, -40), body)
	g:key("MagWell", CF(0, -50, -40))
	g:hand("MagHand", V(-26, -120, -40), V(0.4, 0.5, -0.1), V(-1, 0, 0))
	g:rounded("Stock", V(40, 50, 110), CF(0, -20, 110), 12, body)
	g:rounded("Buttpad", V(44, 58, 16), CF(0, -22, 170), 8, F.rubber)

	g.model:SetAttribute("Action", "blaster")
	g.model:SetAttribute("Flash", "bassring")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Rare
--------------------------------------------------------------------------------

-- A gumball machine gatling: a red housing, six candy-striped barrels spinning round the axis, a
-- glass globe of gumballs on the left as the magazine, a coin-slot crank on the right, a red dot on
-- top. Rotary mechanism, minigun keypoints.
Builders.GumballGatling = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local red = g.skinned and g.skin or glossy(K, 214, 40, 48)
	local white = plastic(K, 246, 244, 240)
	local chrome = K.finishOf(Color3.fromRGB(200, 202, 208), K.Mat.Metal, 0.25)
	local candy = { plastic(K, 255, 90, 160), plastic(K, 90, 200, 255), plastic(K, 255, 220, 60), plastic(K, 120, 230, 120), plastic(K, 190, 120, 255) }

	g:group("spin", function()
		for index = 0, 5 do
			local offset = CFrame.Angles(0, 0, index / 6 * math.pi * 2) * CF(0, 22, 0)
			g:cyl("Barrel", 380, 16, CF(0, 0, -330) * offset, index % 2 == 0 and white or candy[1])
			for stripe = 0, 3 do
				g:cyl("BarrelStripe", 14, 17.5, CF(0, 0, -200 - stripe * 90) * offset, index % 2 == 0 and candy[1] or white)
			end
			g:cyl("Bore", K.FINE, 11, CF(0, 0, -520 - K.FINE / 2) * offset, F.bore)
		end
		g:cyl("BarrelClampHub", 20, 26, CF(0, 0, -300), chrome)
		g:cyl("BarrelClamp", 12, 72, CF(0, 0, -300), chrome)
		g:cyl("BarrelClamp", 12, 72, CF(0, 0, -470), chrome)
	end)
	g:swing("spin", CF(0, 0, -300) * A(0, 90, 0))
	g:key("Muzzle", CF(0, 0, -524))

	local housing = g:rounded("Receiver", V(90, 110, 260), CF(0, 0, 20), 20, red)
	g:cyl("FrontBell", 40, 84, CF(0, 0, -125), chrome)
	g:box("CoinSlot", V(6, 30, 14), CF(45.6, 10, 40), chrome)
	g:box("CoinSlotHole", V(2.8, 20, 4), CF(48.6, 10, 40), F.shadow)
	-- The crank on the right side.
	g:cylX("CrankHub", 16, 30, CF(53, -20, 60), chrome)
	strut(g, K, "CrankArm", V(60, -20, 60), V(66, -60, 60), 10, chrome)
	g:cylX("CrankKnob", 22, 16, CF(74, -60, 60), red)

	-- The globe of gumballs, on its red base on the left.
	g:group("mag", function()
		g:cylY("MagazineBase", 40, 90, CF(-96, -70, 20), red)
		g:ball("Magazine", 120, CF(-96, -8, 20), K.finishOf(Color3.fromRGB(220, 240, 255), K.Mat.Glass, 0.3, 0.72))
		for index = 1, 14 do
			local angle = index * 2.2
			local ring = (index % 4) * 11 + 8
			g:ball("MagazineGumball", 18, CF(-96 + math.cos(angle) * ring, -40 + (index % 5) * 9, 20 + math.sin(angle) * ring), candy[(index % #candy) + 1])
		end
		g:cylY("MagazineCap", 12, 30, CF(-96, 56, 20), red)
	end)
	strut(g, K, "Chute", V(-44, -40, -10), V(-62, -60, 10), 18, chrome)
	g:box("GlobeBracket", V(20, 12, 50), CF(-50, -58.6, 20), chrome)
	g:key("MagWell", CF(-60, -40, 0))
	g:hand("MagHand", V(-96, -110, 60), V(0, 0.4, -1), V(-1, 0, 0))

	g:rounded("SupportGrip", V(40, 40, 80), CF(0, -72, -90), 12, white)
	g:hand("SupportHand", V(-10, -106.5, -90), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:grip(V(0, -52, 128), 8, white, { length = 112, depth = 50, front = 26, back = 34, grooves = 3 })
	g:hand("GripHand", V(34, -92, 142), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	trigger(g, K, 104, -70, chrome, red)

	g:rail("TopRail", 120, CF(0, 55, -10))
	local h = g:redDot(CF(0, 64.5, -10))
	g:key("Sight", CF(0, 64.5 + h, 55))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)
	g:rounded("Stock", V(50, 60, 120), CF(0, -20, 200), 16, white)

	g.model:SetAttribute("Action", "rotary")
	g.model:SetAttribute("Flash", "gumball")
	g.model:SetAttribute("Casing", "none")
	return housing
end

-- A disc launcher: a wide channel with glowing edges, a loaded fidget spinner in its mouth (the round),
-- a stack of spare spinners along the side, a red dot on a riser. Rocket mechanism.
-- Action "rocket" for the single round loaded at Load, but no KP_Backblast: a spring-loaded disc
-- thrower has no venturi, and CombatClient only draws a backblast for guns that carry the keypoint.
Builders.FidgetDiscLauncher = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or plastic(K, 40, 44, 58)
	local glow = neon(K, 90, 255, 200)
	local chrome = K.finishOf(Color3.fromRGB(200, 202, 208), K.Mat.Metal, 0.25)

	local function spinner(name, at, look)
		g:at(at, function()
			g:cylY(name, 10, 22, CF(0, 0, 0), chrome)
			for index = 0, 2 do
				local angle = index / 3 * math.pi * 2
				local arm = V(math.cos(angle) * 24, 0, math.sin(angle) * 24)
				g:box(name, V(6, 6, 24), CFrame.lookAt(arm / 2, arm), look)
				g:cylY(name, 9, 20, CF(arm), look)
			end
		end)
	end

	local channel = g:box("Receiver", V(96, 16, 560), CF(0, -16, -220), body)
	for _, sx in ipairs(SIGNS) do
		g:box("ChannelWall", V(8, 30, 560), CF(sx * 44, 4, -220), body)
		g:box("ChannelGlow", V(3, 4, 540), CF(sx * 49.5, 14, -220), glow)
	end
	g:key("Muzzle", CF(0, 0, -500))
	g:group("round", function()
		spinner("Rocket", CF(0, -3, -440), plastic(K, 255, 80, 180))
	end)
	g:key("Load", CF(0, 0, -520))
	-- Spare spinners along the left wall.
	for index = 0, 2 do
		spinner("SpareSpinner", CF(-64 - index * 3, -10 + index * 10, -120 - index * 4) * A(0, 0, 90), plastic(K, 80, 200, 255))
	end
	g:box("SpareRack", V(12, 44, 40), CF(-54, -6, -122), body)

	g:grip(V(0, -24, 14), 6, body, { length = 100, depth = 44, front = 24, back = 30, grooves = 2 })
	g:hand("GripHand", V(33, -58, 30), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	trigger(g, K, -14, -44, chrome, body)
	g:rounded("ForeGrip", V(36, 70, 40), CF(0, -58, -210), 12, body)
	g:hand("SupportHand", V(-32, -58, -204), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
	g:rounded("Stock", V(60, 50, 180), CF(0, -24, 140), 14, body)

	g:box("SightRiser", V(30, 54, 60), CF(0, 18, -30), body)
	g:rail("TopRail", 70, CF(0, 45, -30))
	local h = g:redDot(CF(0, 54.5, -30))
	g:key("Sight", CF(0, 54.5 + h, 35))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.9)

	g.model:SetAttribute("Action", "rocket")
	g.model:SetAttribute("Flash", "launcher")
	g.model:SetAttribute("Casing", "none")
	return channel
end

--------------------------------------------------------------------------------
-- Epic
--------------------------------------------------------------------------------

-- A countertop microwave on a stock: the enamel box is the receiver, its door window glows with the
-- turntable inside, the keypad and door handle on the right (the handle is the charging handle), a
-- magnetron horn with glowing coils for a barrel, a holo on top. Energy mechanism.
Builders.MicrowaveZapper = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local enamel = g.skinned and g.skin or glossy(K, 236, 236, 232, 0.08)
	local dark = plastic(K, 40, 42, 48)
	local glow = neon(K, 255, 190, 80)
	local copper = F.copper

	local receiver = g:box("Receiver", V(100, 80, 170), CF(0, -6, -20), enamel)
	g:box("DoorWindow", V(3, 50, 100), CF(-51.5, -4, -30), K.finishOf(Color3.fromRGB(30, 30, 34), K.Mat.Glass, 0.25, 0.35))
	g:cylX("Turntable", 3, 44, CF(-47, -20, -30), glow)
	g:box("DoorFrame", V(4, 62, 112), CF(-50, -4, -30), dark)
	g:box("Keypad", V(3, 60, 36), CF(51.5, -4, 40), dark)
	for row = 0, 3 do
		for col = 0, 1 do
			g:box("KeypadButton", V(3, 7, 9), CF(53, 14 - row * 12, 32 + col * 14), plastic(K, 200, 200, 196))
		end
	end
	g:box("ClockGlow", V(3, 8, 24), CF(53, 24, 40), neon(K, 90, 255, 120))
	g:group("charge", function()
		g:box("ChargingHandle", V(12, 50, 10), CF(56, -4, -80), dark)
	end)
	g:travel("charge", 40)
	g:hand("ChargeHand", V(70, -4, -80), V(-0.2, -1, 0.1), V(1, 0.2, 0))

	-- The magnetron horn: a copper throat, coils with glow between them, a flared emitter.
	g:cyl("Barrel", 260, 26, CF(0, 0, -230), copper)
	for index = 0, 4 do
		g:cyl("Coil", 14, 50, CF(0, 0, -140 - index * 44), copper)
		g:cyl("CoilGlow", 6, 44, CF(0, 0, -162 - index * 44), glow)
	end
	g:cyl("MuzzleMount", 20, 54, CF(0, 0, -360), copper)
	g:shell("MuzzleBrake", 36, 60, 5, CF(0, 0, -372), copper, 12)
	g:key("Muzzle", CF(0, 0, -392))

	g:rail("TopRail", 140, CF(0, 34, -20))
	local h = g:holo(CF(0, 43.5, -30))
	g:key("Sight", CF(0, 43.5 + h, 50))
	g.model:SetAttribute("Optic", "holo")
	g.model:SetAttribute("EyeRelief", 0.62)

	g:grip(V(0, -46, 50), 16, dark, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	g:hand("GripHand", V(33, -84, 70), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	trigger(g, K, 20, -68, copper, enamel)
	g:rounded("ForeGrip", V(40, 40, 90), CF(0, -34, -260), 12, dark)
	g:hand("SupportHand", V(-8, -68.5, -260), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	g:group("mag", function()
		g:prism("Magazine", V(44, 90, 60), CF(0, -90, -60), 6, dark)
		for _, sx in ipairs(SIGNS) do
			g:box("MagazineGlow", V(K.FINE * 2, 56, 12), CF(sx * 22, -90, -60), glow)
		end
	end)
	g:key("MagWell", CF(0, -46, -60))
	g:hand("MagHand", V(-30, -146, -60), V(0.4, 0.5, -0.1), V(-1, 0, 0))
	g:rounded("Stock", V(40, 60, 150), CF(0, -16, 140), 14, enamel)
	g:rounded("Buttpad", V(44, 70, 16), CF(0, -18, 220), 8, F.rubber)

	g.model:SetAttribute("Action", "energy")
	g.model:SetAttribute("Flash", "zap")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

-- A crossbow on a pizza board: rolling pins for limbs, a floury wooden rail, and a pizza cutter
-- loaded as the bolt. Crossbow mechanism and layout.
Builders.PizzaCutterCrossbow = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local wood = g.skinned and g.skin or F.woodLight
	local darkWood = F.wood
	local steel = K.finishOf(Color3.fromRGB(210, 212, 216), K.Mat.Metal, 0.3)
	local red = plastic(K, 200, 40, 36)
	local flour = plastic(K, 244, 240, 228)

	local housing = g:prism("Receiver", V(42, 42, 220), CF(0, -12, 20), 6, darkWood)
	g:cyl("BufferTube", 170, 30, CF(0, -6, 215), F.anodizedDark)
	g:rounded("Stock", V(40, 42, 150), CF(0, -6, 247), 13, wood)
	g:rounded("Buttpad", V(44, 20, 128), CF(0, -41, 330) * A(90, 0, 0), 8, F.rubber)
	g:rail("TopRail", 150, CF(0, 9, 30))
	g:grip(V(0, -33, 60), 18, darkWood, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	trigger(g, K, 18, -58, steel, darkWood)
	g:hand("GripHand", V(33, -70, 80), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- The board: the rail, with flour dusted along it and a checked cloth tied round the front.
	g:prism("Rail", V(40, 26, 520), CF(0, -6, -350), 5, wood, "bottom")
	g:box("FlightGroove", V(8, K.FINE * 2, 500), CF(0, 7 + K.FINE, -350), F.shadow)
	g:box("Flour", V(44, 2, 90), CF(0, -20, -200), flour)
	g:box("Cloth", V(46, 30, 40), CF(0, -10, -520), red)
	g:box("Latch", V(22, 8, 20), CF(0, 13, -72), steel)
	g:prism("Riser", V(150, 44, 50), CF(0, -4, -633), 8, darkWood)
	g:box("RiserBlock", V(60, 66, 40), CF(0, -30, -640), darkWood)
	g:key("Muzzle", CF(0, 12, -660))
	g:hand("ChargeHand", V(-4, 26, -50), V(0.1, -0.3, 1), V(0, 1, 0))

	-- Rolling-pin limbs with their handles, and the string drawn back to the latch or loosed.
	local latch = V(0, 12, -70)
	for _, sx in ipairs(SIGNS) do
		local root = V(sx * 70, -4, -650)
		local tip = V(sx * 240, -4, -588)
		rod(g, K, "Limb", root, tip, 34, wood)
		rod(g, K, "LimbHandle", tip, tip + (tip - root).Unit * 40, 16, darkWood)
		local handleEnd = tip + (tip - root).Unit * 40
		g:ball("LimbKnob", 22, CF(handleEnd), darkWood)
		local camEdge = tip + V(-sx * 10, 18, 0)
		g:group("string", function()
			strut(g, K, "String", camEdge, latch, 3, F.polymerDark)
		end)
		local restEnd = V(0, camEdge.Y, -600)
		local rest = strut(g, K, "StringRest", camEdge, restEnd, 3, F.polymerDark)
		rest.Transparency = 1
		rest:SetAttribute("Anim", "stringRest")
	end

	g:rounded("ForeGrip", V(40, 40, 130), CF(0, -38.5, -330), 14, darkWood)
	g:hand("SupportHand", V(-6, -74.5, -330), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	local h = g:redDot(CF(0, 18.5, 30))
	g:key("Sight", CF(0, 18.5 + h, 95))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- The pizza cutter: a red handle for a shaft, a steel wheel at the front on its fork.
	g:group("round", function()
		g:cyl("RocketShaft", 360, 12, CF(0, 12, -260), red)
		g:cyl("RocketNock", 14, 16, CF(0, 12, -86), steel)
		strut(g, K, "RocketFork", V(0, 12, -440), V(0, 12, -470), 8, steel)
		g:cylX("RocketHead", 3, 56, CF(0, 12, -490), steel)
		g:cylX("RocketHub", 10, 12, CF(0, 12, -490), steel)
	end)
	g:key("Load", CF(0, 30, -300))

	g.model:SetAttribute("Action", "crossbow")
	g.model:SetAttribute("Flash", "crossbow")
	g.model:SetAttribute("Casing", "none")
	return housing
end

--------------------------------------------------------------------------------
-- Legendary
--------------------------------------------------------------------------------

-- A disco blaster: a caged mirror ball out front that spins up as you fire, a glossy gold-and-purple
-- body with a vinyl record for a magazine, a holo high on top so the sight line clears the ball.
-- Rotary mechanism (for the spin), rotary keypoints.
Builders.DiscoBallDeleter = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or glossy(K, 120, 60, 170, 0.2)
	local gold = F.gold
	local mirror = K.finishOf(Color3.fromRGB(210, 214, 222), K.Mat.SmoothPlastic, 0.6)
	local vinyl = plastic(K, 20, 20, 22)

	g:group("spin", function()
		g:ball("DiscoBall", 110, CF(0, 0, -320), mirror)
		g:detail(function()
			for ring = -2, 2 do
				local count = 10 - math.abs(ring) * 2
				for index = 0, count - 1 do
					local angle = index / count * math.pi * 2
					g:box("DiscoTile", V(2, 12, 12), CF(0, 0, -320) * CFrame.Angles(0, 0, angle) * A(ring * 26, 0, 0) * CF(0, 55, 0) * A(0, 0, 90),
						index % 3 == 0 and glossy(K, 255, 120, 220, 0.5) or mirror)
				end
			end
		end)
		g:cyl("BarrelClampHub", 30, 24, CF(0, 0, -250), gold)
	end)
	g:swing("spin", CF(0, 0, -320) * A(0, 90, 0))
	-- The cage: four hoops round the ball, meeting at a disc at each pole (so no two hoops stack a
	-- segment in the same place), the rear disc fixed to the collar.
	for index = 0, 3 do
		local angle = index / 4 * math.pi
		for step = 0, 11 do
			if step ~= 3 and step ~= 9 then
				g:box("Cage", V(6, 4, 38), CF(0, 0, -320) * CFrame.Angles(0, 0, angle) * A(step / 12 * 360, 0, 0) * CF(0, 66, 0), gold)
			end
		end
	end
	for _, z in ipairs({ -254, -386 }) do
		g:cyl("CagePole", 4, 44, CF(0, 0, z), gold)
	end
	g:cyl("Collar", 50, 50, CF(0, 0, -233), gold)
	g:key("Muzzle", CF(0, 0, -390))

	local receiver = g:rounded("Receiver", V(60, 70, 260), CF(0, -2, -80), 18, body)
	for _, sx in ipairs(SIGNS) do
		g:box("TrimStrip", V(3, 8, 240), CF(sx * 30.5, 12, -80), gold)
	end
	g:group("charge", function()
		g:ball("ChargingKnob", 18, CF(-40, 10, -30), gold)
	end)
	g:travel("charge", 40)
	g:hand("ChargeHand", V(-52, 16, -30), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))

	g:box("SightRiser", V(30, 32, 80), CF(0, 46, -60), body)
	g:rail("TopRail", 90, CF(0, 62, -60))
	local h = g:holo(CF(0, 71.5, -70))
	g:key("Sight", CF(0, 71.5 + h, 10))
	g.model:SetAttribute("Optic", "holo")
	g.model:SetAttribute("EyeRelief", 0.62)

	g:group("mag", function()
		g:cylX("Magazine", 6, 110, CF(0, -80, -80), vinyl)
		g:cylX("MagazineLabel", 9, 36, CF(0, -80, -80), K.finishOf(g.accent, K.Mat.SmoothPlastic))
	end)
	g:box("RecordSlot", V(16, 24, 118), CF(0, -40, -80), body)
	g:key("MagWell", CF(0, -36, -80))
	g:hand("MagHand", V(-26, -130, -80), V(0.4, 0.5, -0.1), V(-1, 0, 0))

	g:grip(V(0, -38, 40), 14, body, { length = 100, depth = 46, front = 22, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -76, 58), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	trigger(g, K, 10, -62, gold, body)
	g:rounded("ForeGrip", V(36, 40, 70), CF(0, -52, -180), 12, gold)
	g:hand("SupportHand", V(-8, -86.5, -180), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:rounded("Stock", V(40, 56, 130), CF(0, -12, 110), 14, body)

	g.model:SetAttribute("Action", "rotary")
	g.model:SetAttribute("Flash", "disco")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

-- A chrome two-slot toaster on a launch tube: the lever and dial on its side, a crumb tray, the tube
-- running forward with a slice of toast loaded in its mouth (the round), a red dot on the toaster.
-- Rocket mechanism.
-- Action "rocket" for the one slice loaded at a time; no KP_Backblast, for the same reason as the
-- Fidget above -- a toaster popping toast upward vents nothing out of its back.
Builders.ToasterMortar = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local chrome = g.skinned and g.skin or K.finishOf(Color3.fromRGB(214, 216, 222), K.Mat.Metal, 0.35)
	local dark = plastic(K, 34, 34, 38)
	local toast = plastic(K, 206, 150, 80)
	local crust = plastic(K, 150, 96, 48)

	local toaster = g:rounded("Receiver", V(90, 90, 170), CF(0, 6, 40), 22, chrome)
	for _, dx in ipairs({ -18, 18 }) do
		g:box("ToastSlot", V(10, 4, 110), CF(dx, 50, 40), dark)
		g:box("ToastPeek", V(8, 12, 90), CF(dx, 54, 40), toast)
	end
	g:box("LeverSlot", V(4, 50, 8), CF(45.6, 10, 90), dark)
	g:box("Lever", V(12, 8, 16), CF(52.6, 24, 90), dark)
	g:cylX("Dial", 8, 24, CF(47.6, -14, 50), dark)
	g:box("CrumbTray", V(80, 6, 150), CF(0, -41, 40), chrome)

	-- The launch tube, square like the slot.
	local tubeLook = K.finishOf(Color3.fromRGB(180, 182, 188), K.Mat.Metal, 0.2)
	for _, side in ipairs({ { V(66, 6, 440), CF(0, 30, -260) }, { V(66, 6, 440), CF(0, -30, -260) }, { V(6, 54, 440), CF(30, 0, -260) }, { V(6, 54, 440), CF(-30, 0, -260) } }) do
		g:box("Tube", side[1], side[2], tubeLook)
	end
	g:box("TubeLip", V(80, 8, 12), CF(0, 36, -484), chrome)
	g:box("TubeLip", V(80, 8, 12), CF(0, -36, -484), chrome)
	g:key("Muzzle", CF(0, 0, -492))
	g:group("round", function()
		g:box("Rocket", V(10, 54, 48), CF(0, 0, -440), toast)
		g:box("RocketCrust", V(11.5, 54, 4), CF(0, 0, -416), crust)
	end)
	g:key("Load", CF(0, 0, -520))

	g:grip(V(0, -42, 60), 6, dark, { length = 100, depth = 44, front = 24, back = 30, grooves = 2 })
	g:hand("GripHand", V(33, -76, 76), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	trigger(g, K, 32, -58, chrome, dark)
	g:rounded("ForeGrip", V(36, 70, 40), CF(0, -64, -210), 12, dark)
	g:hand("SupportHand", V(-32, -64, -204), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
	g:box("Cord", V(8, 8, 140), CF(-20, -30, 190), dark)
	g:box("CordPlug", V(24, 16, 20), CF(-20, -30, 266), dark)

	g:rail("TopRail", 70, CF(0, 51, -40))
	local h = g:redDot(CF(0, 60.5, -40))
	g:key("Sight", CF(0, 60.5 + h, 25))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.9)

	g.model:SetAttribute("Action", "rocket")
	g.model:SetAttribute("Flash", "launcher")
	g.model:SetAttribute("Casing", "none")
	return toaster
end

--------------------------------------------------------------------------------
-- Mythic
--------------------------------------------------------------------------------

-- A twin-rail coilgun with a rubber chicken stretched along the rails between the coils, head at the
-- muzzle, a long scope high above it all. Energy mechanism, railgun keypoints.
Builders.RubberChickenRailgun = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or F.anodizedDark
	local copper = F.copper
	local glow = neon(K, 140, 230, 255)
	local chicken = plastic(K, 250, 214, 50)
	local orange = plastic(K, 255, 120, 30)
	local comb = plastic(K, 220, 30, 40)

	local receiver = g:prism("Receiver", V(62, 84, 440), CF(0, -22, 150), 8, body)
	g:prism("TopCover", V(54, 14, 360), CF(0, 27, 90), 5, body, "top")
	g:rail("TopRail", 300, CF(0, 34, 90))
	-- The rails: two long bars either side of the bore, coils round them, glow between.
	for _, sx in ipairs(SIGNS) do
		g:box("Rail", V(10, 22, 700), CF(sx * 24.6, 0, -300), body)
	end
	for index = 0, 5 do
		local z = -100 - index * 100
		g:box("Coil", V(70, 10, 20), CF(0, -16, z), copper)
		for _, sx in ipairs(SIGNS) do
			g:box("Coil", V(10, 36, 20), CF(sx * 33, 0, z), copper)
		end
		g:box("CoilGlow", V(40, K.FINE * 2, 16), CF(0, -20, z - 16), glow)
	end
	g:key("Muzzle", CF(0, 0, -660))

	-- The chicken, lying along the rails: body, stretched neck, head with comb and beak, legs back.
	g:rounded("Chicken", V(36, 30, 200), CF(0, 14, -160), 12, chicken)
	strut(g, K, "ChickenNeck", V(0, 16, -260), V(0, 20, -560), 16, chicken)
	g:ball("ChickenHead", 34, CF(0, 22, -574), chicken)
	g:wedge("ChickenBeak", V(12, 8, 22), CF(0, 18, -598) * A(0, 180, 0), orange)
	for index = 0, 2 do
		g:box("ChickenComb", V(4, 12, 8), CF(0, 40, -566 - index * 8), comb)
	end
	for _, sx in ipairs(SIGNS) do
		g:ball("ChickenEye", 6, CF(sx * 12, 27, -586), F.shadow)
		strut(g, K, "ChickenLeg", V(sx * 8, 6, -70), V(sx * 12, 0, 20), 6, orange)
	end

	local h = g:scope(CF(0, 43.5, 90), "long")
	g:key("Sight", CF(0, 43.5 + h, 270))
	g.model:SetAttribute("Optic", "scope")
	g.model:SetAttribute("EyeRelief", 0.6)

	g:group("charge", function()
		g:box("ChargingHandle", V(16, 20, 30), CF(36, -10, 226), body)
	end)
	g:travel("charge", 40)
	g:hand("ChargeHand", V(52, 22, 226), V(-0.2, -1, 0.1), V(1, 0.2, 0))
	g:grip(V(0, -64, 14), 16, body, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	trigger(g, K, -12, -86, copper, body)
	g:hand("GripHand", V(33, -102, 34), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	g:rounded("ForeGrip", V(40, 44, 120), CF(0, -38, -351), 14, body)
	g:hand("SupportHand", V(-27, -76, -351), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
	g:group("mag", function()
		g:prism("Magazine", V(44, 100, 70), CF(0, -104, 150), 6, F.polymerDark)
		for _, sx in ipairs(SIGNS) do
			g:box("MagazineGlow", V(K.FINE * 2, 60, 14), CF(sx * 22, -104, 150), glow)
		end
	end)
	g:key("MagWell", CF(0, -64, 150))
	g:hand("MagHand", V(-30, -160, 150), V(0.4, 0.5, -0.1), V(-1, 0, 0))
	g:rounded("Buttpad", V(66, 20, 110), CF(0, -24, 380) * A(90, 0, 0), 8, F.rubber)

	g.model:SetAttribute("Action", "energy")
	g.model:SetAttribute("Flash", "rail")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

-- A marksman rifle whose receiver is a lava lamp: a glass capsule with glowing wax blobs, a metal
-- base at the back and a cap at the front, a brass barrel, a holo on a rail above. Semi mechanism.
Builders.LavaLampLancer = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local metal = g.skinned and g.skin or K.finishOf(Color3.fromRGB(70, 40, 90), K.Mat.Metal, 0.15)
	local glass = K.finishOf(Color3.fromRGB(255, 120, 150), K.Mat.Glass, 0.2, 0.5)
	local wax = neon(K, 255, 140, 40)
	local brass = F.brass

	g:cyl("LampGlass", 220, 64, CF(0, -4, -40), glass)
	for index = 0, 5 do
		g:ball("LampWax", 14 + (index % 3) * 8, CF(math.sin(index * 1.7) * 12, -14 + (index % 3) * 8, -120 + index * 32), wax)
	end
	local receiver = g:cyl("Receiver", 80, 72, CF(0, -4, 108), metal)
	g:cyl("LampCap", 30, 56, CF(0, -4, -164), metal)
	g:cyl("Barrel", 300, 20, CF(0, 0, -320), brass)
	g:cyl("MuzzleBrake", 34, 28, CF(0, 0, -484), brass)
	g:key("Muzzle", CF(0, 0, -504))
	-- A rail on two posts off the lamp's base and cap, clear above the glass.
	for _, z in ipairs({ 90, -150 }) do
		g:box("RailPost", V(16, 32, 16), CF(0, 36, z), metal)
	end
	g:rail("TopRail", 280, CF(0, 52, -30))
	local h = g:holo(CF(0, 61.5, -20))
	g:key("Sight", CF(0, 61.5 + h, 60))
	g.model:SetAttribute("Optic", "holo")
	g.model:SetAttribute("EyeRelief", 0.62)

	g:group("bolt", function()
		g:box("BoltCarrier", V(10, 14, 40), CF(38, 0, 110), brass)
	end)
	g:travel("bolt", 50)
	g:key("Eject", CF(40, 4, 110) * A(0, -70, 0))
	g:group("charge", function()
		g:box("ChargingHandle", V(14, 10, 14), CF(-40, 0, 130), metal)
		g:ball("ChargingKnob", 14, CF(-52, 0, 130), wax)
	end)
	g:travel("charge", 60)
	g:hand("ChargeHand", V(-62, 12, 130), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))

	g:grip(V(0, -40, 150), 18, metal, { length = 100, depth = 46, front = 22, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -80, 170), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	trigger(g, K, 120, -64, brass, metal)
	g:group("mag", function()
		g:box("Magazine", V(24, 80, 50), CF(0, -60, 70), metal)
		g:box("MagazineGlow", V(25.5, 10, 30), CF(0, -60, 70), wax)
	end)
	g:key("MagWell", CF(0, -40, 70))
	g:hand("MagHand", V(-30, -120, 70), V(0.4, 0.25, -0.2), V(-1, -0.15, 0))
	g:rounded("Handguard", V(40, 30, 160), CF(0, -24, -280), 10, metal)
	g:hand("SupportHand", V(-8, -50, -280), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:rounded("Stock", V(40, 60, 170), CF(0, -16, 230), 14, metal)
	g:rounded("Buttpad", V(44, 70, 16), CF(0, -18, 320), 8, F.rubber)

	g.model:SetAttribute("Action", "semi")
	g.model:SetAttribute("Flash", "lava")
	g.model:SetAttribute("Casing", "rifle")
	return receiver
end

--------------------------------------------------------------------------------
-- Secret
--------------------------------------------------------------------------------

-- A snow globe on a brass frame: a tiny snowy town with a pine tree inside the glass, flakes drifting,
-- a wooden plinth, a red dot high on top to see over the globe. Energy mechanism.
Builders.SnowGlobeSingularity = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local brass = g.skinned and g.skin or F.brass
	local wood = F.woodDark
	local snow = plastic(K, 248, 250, 255)
	local glass = K.finishOf(Color3.fromRGB(220, 240, 255), K.Mat.Glass, 0.3, 0.75)

	g:at(CF(0, 0, -300), function()
		g:ball("Globe", 124, CF(0, 0, 0), glass)
		g:cylY("SnowGround", 10, 90, CF(0, -34, 0), snow)
		for index = 0, 2 do
			local x, z = -26 + index * 26, (index - 1) * 14
			g:box("House", V(18, 16, 18), CF(x, -22.4, z), plastic(K, 200 - index * 30, 90 + index * 40, 80))
			g:wedge("HouseRoof", V(20, 10, 10), CF(x, -9.4, z + 5) * A(0, 0, 0), snow)
			g:wedge("HouseRoof", V(20, 10, 10), CF(x, -9.4, z - 5) * A(0, 180, 0), snow)
		end
		g:cylY("TreeTrunk", 12, 6, CF(34, -25, -24), wood)
		for tier = 0, 2 do
			g:cylY("Tree", 12, 24 - tier * 7, CF(34, -14 + tier * 9, -24), plastic(K, 40, 120, 70))
		end
		for index = 0, 11 do
			local angle = index * 2.4
			g:ball("Snowflake", 3, CF(math.cos(angle) * (10 + index * 3), -10 + (index % 5) * 9, math.sin(angle) * (10 + index * 3)), snow)
		end
	end)
	g:cyl("Plinth", 44, 110, CF(0, -4, -220), wood)
	g:cyl("PlinthBand", 8, 116, CF(0, -4, -210), brass)
	g:key("Muzzle", CF(0, 0, -368))

	local receiver = g:rounded("Receiver", V(56, 64, 240), CF(0, -8, -80), 16, brass)
	for _, sx in ipairs(SIGNS) do
		g:box("Filigree", V(3, 20, 200), CF(sx * 28.5, 0, -80), F.goldDeep)
	end
	g:group("charge", function()
		g:cylX("ChargingHandle", 20, 16, CF(-38, 10, -40), brass)
		g:ball("ChargingKnob", 16, CF(-52, 10, -40), wood)
	end)
	g:travel("charge", 40)
	g:hand("ChargeHand", V(-62, 20, -40), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))

	g:box("SightRiser", V(28, 40, 80), CF(0, 44, -80), brass)
	g:rail("TopRail", 90, CF(0, 64, -80))
	local h = g:redDot(CF(0, 73.5, -80))
	g:key("Sight", CF(0, 73.5 + h, -15))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	g:group("mag", function()
		g:cylY("Magazine", 70, 40, CF(0, -75, -60), glass)
		g:cylY("MagazineSnow", 50, 32, CF(0, -81, -60), snow)
		g:cylY("MagazineCap", 8, 44, CF(0, -113, -60), brass)
	end)
	g:cylY("MagazineCollar", 12, 50, CF(0, -44, -60), brass)
	g:key("MagWell", CF(0, -40, -60))
	g:hand("MagHand", V(-26, -120, -60), V(0.4, 0.5, -0.1), V(-1, 0, 0))
	-- The grip's top sinks 6 mm into the body: raked, a grip set flush on the body's underside meets it
	-- only along one edge.
	g:grip(V(0, -34, 40), 14, wood, { length = 100, depth = 46, front = 22, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -72, 58), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	trigger(g, K, 10, -58, brass, brass)
	g:rounded("ForeGrip", V(36, 40, 60), CF(0, -54, -170), 12, wood)
	g:hand("SupportHand", V(-8, -88.5, -170), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:rounded("Stock", V(40, 56, 130), CF(0, -12, 110), 14, wood)

	g.model:SetAttribute("Action", "energy")
	g.model:SetAttribute("Flash", "snow")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

-- A spring-loaded launcher built from a wooden bed, knitting needles for limbs with a pink elastic,
-- and a fuzzy slipper with a pom-pom loaded as the bolt. Crossbow mechanism and layout.
Builders.GrandmasSlipperLauncher = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local wood = g.skinned and g.skin or F.wood
	local pink = K.finishOf(Color3.fromRGB(255, 150, 190), K.Mat.Fabric)
	local sole = plastic(K, 120, 80, 60)
	local yarn = K.finishOf(Color3.fromRGB(150, 110, 200), K.Mat.Fabric)
	local steel = K.finishOf(Color3.fromRGB(200, 202, 208), K.Mat.Metal, 0.25)

	local housing = g:prism("Receiver", V(42, 42, 220), CF(0, -12, 20), 6, wood)
	g:cyl("BufferTube", 170, 30, CF(0, -6, 215), F.anodizedDark)
	g:rounded("Stock", V(40, 42, 150), CF(0, -6, 247), 13, wood)
	g:ball("YarnBall", 60, CF(-20, -54, 250), yarn)
	g:rounded("Buttpad", V(44, 20, 128), CF(0, -41, 330) * A(90, 0, 0), 8, pink)
	g:rail("TopRail", 150, CF(0, 9, 30))
	g:grip(V(0, -33, 60), 18, wood, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	trigger(g, K, 18, -58, steel, wood)
	g:hand("GripHand", V(33, -70, 80), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	g:prism("Rail", V(40, 26, 520), CF(0, -6, -350), 5, wood, "bottom")
	g:box("FlightGroove", V(8, K.FINE * 2, 500), CF(0, 7 + K.FINE, -350), F.shadow)
	g:box("Latch", V(22, 12, 20), CF(0, 13, -72), steel)
	g:prism("Riser", V(150, 44, 50), CF(0, -4, -633), 8, wood)
	g:box("RiserBlock", V(60, 66, 40), CF(0, -30, -640), wood)
	g:key("Muzzle", CF(0, 12, -660))
	g:hand("ChargeHand", V(-4, 26, -50), V(0.1, -0.3, 1), V(0, 1, 0))

	-- Knitting needles for limbs, their bead ends, and the elastic.
	local latch = V(0, 12, -70)
	for _, sx in ipairs(SIGNS) do
		local root = V(sx * 60, -4, -650)
		local tip = V(sx * 250, -4, -600)
		rod(g, K, "Limb", root, tip, 12, steel)
		g:ball("LimbBead", 22, CF(tip), pink)
		local camEdge = tip + V(-sx * 8, 14, 0)
		g:group("string", function()
			strut(g, K, "String", camEdge, latch, 3, pink)
		end)
		local restEnd = V(0, camEdge.Y, -600)
		local rest = strut(g, K, "StringRest", camEdge, restEnd, 3, pink)
		rest.Transparency = 1
		rest:SetAttribute("Anim", "stringRest")
	end

	g:rounded("ForeGrip", V(40, 40, 130), CF(0, -38.5, -330), 14, wood)
	g:hand("SupportHand", V(-6, -74.5, -330), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	local h = g:redDot(CF(0, 18.5, 30))
	g:key("Sight", CF(0, 18.5 + h, 95))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- The slipper: a sole, the fuzzy upper, a pom-pom on the toe.
	g:group("round", function()
		g:rounded("RocketSole", V(44, 8, 150), CF(0, 9.6, -420), 3, sole)
		g:rounded("Rocket", V(46, 26, 120), CF(0, 26.6, -410), 10, pink)
		g:ball("RocketPomPom", 22, CF(0, 35.6, -478), K.finishOf(Color3.fromRGB(255, 240, 250), K.Mat.Fabric))
	end)
	g:key("Load", CF(0, 30, -300))

	g.model:SetAttribute("Action", "crossbow")
	g.model:SetAttribute("Flash", "crossbow")
	g.model:SetAttribute("Casing", "none")
	return housing
end

return GunModelsCreative
