-- Workshop gun models: the shed-and-kitchen guns from WorkshopArsenal, in the spirit of the Bubble
-- Blaster -- a thing off a shelf that has been made to shoot.
--
-- GunModels.Build calls Builders[weaponId](g, Kit) for these ids instead of the style's stock builder, and
-- does everything after the build itself (the AimPoint, the z-fight pass, the Receiver, the Muzzle
-- attachment and the welds). `g` is GunModels' Builder: every size and position below is in millimetres,
-- the origin on the bore axis above the trigger, the gun facing -Z with +X to the right. Each builder
-- returns its receiver part.
--
-- Each gun keeps the animation contract of the mechanism it borrows (Action), with that mechanism's
-- keypoints, so the viewmodel's reload, rack and fire clips work unchanged:
--   belt    cover group (swings open) + charge group with travel, ChargeHand, CoverHand, a box magazine
--   bolt    bolt group with travel and swing, BoltHand, Eject, a box magazine
--   break   hinge group (the barrels swing down), Load and SupportHand riding it, a rib with a bead
--   lever   lever group (swings), hammer group, Load, a tube magazine
--   rotary  spin group turning about Pivot_spin (its X laid along the bore), a box magazine
--   semi    bolt and charge groups, Eject, a box magazine
-- Sights follow the ADS contract: KP_Sight on the line the eye looks along, with Optic and EyeRelief, and
-- nothing solid on that line. tools/ads_align_probe.lua, gun_contact_probe.lua and ads_hands_probe.lua
-- check every one.

local GunModelsWorkshop = {}

-- No variants yet: each workshop gun is one design.
GunModelsWorkshop.Variants = {}

local Builders = {}
GunModelsWorkshop.Builders = Builders

local SIGNS = { 1, -1 }

local function plastic(K, r, g, b)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.SmoothPlastic)
end

local function rough(K, r, g, b)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.Plastic)
end

local function fabric(K, r, g, b)
	return K.finishOf(Color3.fromRGB(r, g, b), K.Mat.Fabric)
end

-- A corrugated tube: a core with ribs round it every `pitch` mm, the way a blower or a vacuum hose reads.
local function corrugated(g, K, name, from, to, diameter, look, ribLook)
	local V, CF = K.V, K.CF
	local length = from - to
	g:cyl(name, length, diameter - 6, CF(0, 0, (from + to) / 2), look)
	local ribs = math.floor(length / 26)
	for index = 0, ribs - 1 do
		g:cyl(name .. "Rib", 9, diameter, CF(0, 0, from - 16 - index * 26), ribLook or look)
	end
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
-- Yard Work: a leaf blower fed from a leaf bag (belt mechanism, LMG keypoints)
--------------------------------------------------------------------------------

Builders.YardWorkBlower = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local shell = g.skinned and g.skin or rough(K, 238, 106, 30)
	local dark = plastic(K, 46, 48, 54)
	local tube = plastic(K, 62, 64, 70)

	-- The motor housing, its intake grille on the right, and the hatch on top the feed comes through.
	local receiver = g:rounded("Receiver", V(78, 108, 250), CF(0, 8, 60), 16, shell)
	g:cylX("Intake", 16, 86, CF(40, 8, 70), dark)
	g:detail(function()
		-- Set into the intake's outer face rather than level with it.
		for index = 0, 3 do
			g:cylX("IntakeVane", 3, 82, CF(44, 8, 70) * A(0, 0, 45 * index), tube)
		end
		for index = 0, 2 do
			g:box("MotorVent", V(K.FINE * 2, 40, 10), CF(-39.5, 8, 20 + index * 22), K.F.shadow)
		end
	end)

	g:group("cover", function()
		-- Its top stays 4 mm under the sight line, which runs at y = 70 to the post on the tube.
		g:rounded("BlowerHatch", V(72, 20, 150), CF(0, 56, 40), 8, shell)
		-- The catch hangs below the hatch's underside, not flush with it.
		g:box("HatchCatch", V(26, 10, 14), CF(0, 49, -36), dark)
	end)
	g:swing("cover", CF(0, 52, 118), -68)
	g:hand("CoverHand", V(-12, 74, 40), V(0.3, -0.6, -1), V(-0.2, 1, 0))

	-- The blower tube, corrugated, stepping down to the nozzle. It starts inside the housing: ending at its
	-- front face left the whole front of the gun hanging in the air.
	corrugated(g, K, "Barrel", -50, -470, 56, tube, dark)
	g:cyl("Nozzle", 70, 44, CF(0, 0, -505), shell)
	g:cyl("NozzleTip", 24, 34, CF(0, 0, -552), dark)
	g:cyl("Bore", K.FINE, 26, CF(0, 0, -564 - K.FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -568))

	-- The pull-start cord on the left: the charging handle.
	g:group("charge", function()
		g:box("StartHandle", V(14, 28, 40), CF(-46, 24, 120), dark)
		g:cyl("StartCord", 60, 6, CF(-46, 24, 148) * A(0, 90, 0), plastic(K, 226, 226, 220))
	end)
	g:travel("charge", 90)
	g:hand("ChargeHand", V(-62, 26, 120), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))

	-- Sights: a post on a band round the tube, an aperture on the housing, both on y = 70.
	g:cyl("SightBand", 16, 62, CF(0, 0, -300), dark)
	g:box("FrontSightBase", V(14, 12, 16), CF(0, 34, -300), dark)
	g:box("FrontSightPost", V(4, 22, 5), CF(0, 51, -300), dark)
	g:box("FrontSight", V(2.4, 9, 3), CF(0, 65.5, -300), dark)
	g:box("RearSightBase", V(30, 10, 26), CF(0, 55, 150), dark)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSightEar", V(4, 18, 18), CF(sx * 12, 69, 150), dark)
	end
	g:shell("RearSight", 4, 10, 3, CF(0, 70, 150), dark)
	g:aperturePlate(CF(0, 0, 150), 58, 70, dark)
	g:key("Sight", CF(0, 70, 150))
	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.5)

	-- The leaf bag, hung under the housing: the magazine, with leaves showing in its mouth. 40 mm ahead of
	-- where it first hung: there its back stood against the grip's front strap and the trigger hand's
	-- fingers, even lying open, were inside it -- a bare palm on the grip (#92, tools/fps_arms_check.py).
	g:group("mag", function()
		g:rounded("Magazine", V(84, 128, 118), CF(0, -92, 40), 22, fabric(K, 74, 108, 56))
		g:box("MagazineStrap", V(88, 14, 26), CF(0, -44, 40), fabric(K, 52, 74, 40))
		g:detail(function()
			for index = 0, 3 do
				g:box("MagazineLeaf", V(24, 4, 16), CF(-18 + index * 12, -34, 20 + index * 9) * A(12 * index, 20 * index, 8),
					plastic(K, 126, 186, 74))
			end
		end)
	end)
	g:key("MagWell", CF(0, -40, 40))
	g:hand("MagHand", V(-58, -104, 40), V(0.6, 0.5, -0.1), V(-1, 0, 0))

	-- Trigger on the rear grip, and the bail handle under the tube for the other hand.
	trigger(g, K, 96, -54, dark, shell)
	g:grip(V(0, -48, 140), 14, dark, { length = 104, depth = 48, front = 26, back = 32, grooves = 3 })
	g:hand("GripHand", V(33, -88, 158), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	g:box("BailHandle", V(12, 70, 14), CF(0, -52, -232), dark)
	g:box("BailHandle", V(12, 14, 96), CF(0, -80, -280), dark)
	g:hand("SupportHand", V(-8, -86, -280), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- A short shoulder brace off the back, so it shoulders like a machine gun.
	g:rounded("Stock", V(52, 60, 96), CF(0, -6, 232), 14, dark)
	g:prism("Buttpad", V(56, 108, 20), CF(0, -16, 286), 6, F.rubber)

	g.model:SetAttribute("Action", "belt")
	g.model:SetAttribute("Flash", "leaves")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Party Foul: a party popper the size of a cannon (lever mechanism, cannon keypoints)
--------------------------------------------------------------------------------

Builders.PartyFoulCannon = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local foil = g.skinned and g.skin or K.finishOf(Color3.fromRGB(226, 178, 66), K.Mat.Metal, 0.25)
	local card = plastic(K, 214, 66, 108)
	local cream = plastic(K, 246, 238, 220)
	local cork = K.finishOf(Color3.fromRGB(206, 170, 118), K.Mat.Wood)

	-- The body: a foil-wrapped drum with a card band round it, and the loading gate on its right.
	local receiver = g:rounded("Receiver", V(52, 72, 190), CF(0, -10, -10), 14, foil)
	g:cyl("BodyBand", 26, 58, CF(0, -10, 30) * A(0, 0, 0), card)
	g:box("LoadingGate", V(5.5, 24, 46), CF(25.15, -18, -40), card)
	g:key("Load", CF(44, -18, -40))
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			g:box("BodyStar", V(K.FINE * 2, 16, 16), CF(sx * 26.2, 0, -66) * A(0, 0, 45), cream)
		end
	end)

	-- The tube: a card barrel in foil bands, flaring at the mouth, with the cork still in it.
	g:cyl("Barrel", 380, 58, CF(0, 0, -300), card)
	for _, z in ipairs({ -160, -300, -440 }) do
		g:cyl("BarrelBand", 14, 62, CF(0, 0, z), foil)
	end
	g:cyl("BarrelMouth", 40, 72, CF(0, 0, -510), foil)
	g:group("round", function()
		g:cyl("Cork", 54, 44, CF(0, 0, -552), cork)
		g:cyl("CorkTop", 10, 50, CF(0, 0, -578), cork)
	end)
	g:cyl("Bore", K.FINE, 40, CF(0, 0, -531 - K.FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -584))

	-- Sights: a bead on a ramp over the tube, a buckhorn on the body, both on y = 46.
	g:box("FrontSightRamp", V(5, 14, 26), CF(0, 36, -470), foil)
	g:ball("FrontBead", 6, CF(0, 43, -470), cream)
	g:box("RearSightBase", V(22, 14, 16), CF(0, 32, -70), foil)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSightHorn", V(6, 16, 5), CF(sx * 7, 45, -70), foil)
	end
	g:box("RearSight", V(8, 8, 5), CF(0, 40, -70), foil)
	g:key("Sight", CF(0, 46, -30))
	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.5)

	-- The streamer lever: a ribboned finger loop under the body, and a party-horn hammer at the back.
	g:group("lever", function()
		g:box("Lever", V(10, 6, 56), CF(0, -50, 10), foil)
		g:box("Lever", V(10, 38, 8), CF(0, -68, 44) * A(-12, 0, 0), foil)
		g:box("Lever", V(10, 8, 60), CF(0, -88, 70), foil)
		g:box("LeverRibbon", V(4, 26, 10), CF(0, -100, 96) * A(18, 0, 0), card)
	end)
	g:swing("lever", CF(0, -46, -20), 50)
	g.model:SetAttribute("GripGroup", "lever")
	g:group("hammer", function()
		g:cyl("Hammer", 22, 16, CF(0, 26, 62) * A(28, 0, 0), foil)
		g:cyl("HammerHorn", 26, 10, CF(0, 34, 76) * A(38, 0, 0), card)
	end)
	g:swing("hammer", CF(0, 16, 56), -30)

	-- The streamer tube under the barrel, the grip and the bottle-shaped butt.
	g:cyl("MagTube", 300, 28, CF(0, -34, -290), cream)
	g:cyl("MagCap", 14, 31, CF(0, -34, -446), foil)
	g:rounded("ForeGrip", V(44, 36, 150), CF(0, -32, -190), 12, card)
	g:hand("SupportHand", V(-8, -62, -190), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	trigger(g, K, 0, -44, foil, foil)
	g:rounded("Grip", V(34, 40, 104), CF(0, -24, 104) * A(8, 0, 0), 12, card)
	g:rounded("Stock", V(44, 52, 230), CF(0, -44, 276) * A(4, 0, 0), 15, cream)
	g:cyl("StockNeck", 60, 34, CF(0, -30, 150) * A(6, 0, 0), foil)
	g:prism("Buttplate", V(46, 130, 10), CF(0, -54, 394), 6, F.rubber)
	g:hand("GripHand", V(30, -34, 88), V(-0.3, 0.2, -1), V(1, 0.2, 0.3))
	g:hand("MagHand", V(-40, -40, -320), V(0.4, 0.3, -0.2), V(-1, -0.1, 0))

	g.model:SetAttribute("Action", "lever")
	g.model:SetAttribute("Flash", "confetti")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Rage Quit: a mechanical keyboard that fires its keycaps (semi mechanism, rifle keypoints)
--------------------------------------------------------------------------------

Builders.RageQuitCarbine = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local case = g.skinned and g.skin or plastic(K, 44, 46, 54)
	local cap = plastic(K, 226, 232, 244)
	local accent = plastic(K, 255, 140, 60)
	local braid = plastic(K, 62, 66, 76)

	-- The board: a low case with a deck of keycaps along its top and a lit strip down each side.
	local receiver = g:rounded("Receiver", V(104, 30, 290), CF(0, -2, 30), 8, case)
	-- The deck: rows of keycaps big enough to read as a keyboard from across a room, a few of them lit. They
	-- run either side of the sight rail's spine, which takes the middle of the case.
	local KEY_COLUMNS = { -46, -25, 25, 46 }
	for row = 0, 3 do
		for column, x in ipairs(KEY_COLUMNS) do
			local lit = (row * 4 + column) % 6 == 0
			g:box("Keycap", V(18, 9, 18), CF(x, 16, -70 + row * 22), lit and accent or cap)
		end
	end
	g:detail(function()
		for row = 0, 3 do
			for _, x in ipairs(KEY_COLUMNS) do
				g:box("KeycapLegend", V(9, K.FINE * 2, 9), CF(x, 20.5, -70 + row * 22), braid)
			end
		end
		for _, sx in ipairs(SIGNS) do
			g:box("CaseGlow", V(K.FINE * 2, 5, 240), CF(sx * 52.2, -6, 30), K.finishOf(Color3.fromRGB(120, 200, 255), K.Mat.Neon))
		end
	end)

	-- The cable: a braided lead for a barrel, ending in a plug, with a loose coil hanging off its middle.
	corrugated(g, K, "Barrel", -110, -400, 24, braid, case)
	g:detail(function()
		for index = 0, 5 do
			g:cylX("CableCoil", 10, 46, CF(0, -26, -250 - index * 16) * A(0, 0, 90) * A(0, 8 * index, 0), braid)
		end
	end)
	g:box("MuzzlePlug", V(26, 20, 46), CF(0, 0, -424), K.finishOf(Color3.fromRGB(186, 190, 198), K.Mat.Metal, 0.2))
	g:cyl("Bore", K.FINE, 14, CF(0, 0, -448 - K.FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -452))

	-- The bolt under the deck and the spacebar that charges it, out the right.
	g:group("bolt", function()
		g:box("BoltCarrier", V(16, 12, 54), CF(20, 6, 40), braid)
	end)
	g:travel("bolt", 46)
	g:key("Eject", CF(54, 6, 40) * A(0, -70, 0))
	g:group("charge", function()
		g:box("Spacebar", V(18, 10, 78), CF(56, 4, 70), cap)
		g:box("SpacebarStem", V(10, 8, 20), CF(48, 4, 70), braid)
	end)
	g:travel("charge", 60)
	g:hand("ChargeHand", V(74, 8, 70), V(-0.2, -1, 0.1), V(1, 0.2, 0))

	-- A red dot on a riser, its line well above the keycaps.
	g:box("SightRail", V(26, 8, 120), CF(0, 22, -20), case)
	local h = g:redDot(CF(0, 26, -20))
	g:key("Sight", CF(0, 26 + h, 30))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- The keycap tray that feeds it, and a mouse for a foregrip.
	g:group("mag", function()
		g:box("Magazine", V(56, 86, 52), CF(0, -56, -42), case)
		g:box("MagazineLip", V(60, 8, 56), CF(0, -16, -42), braid)
		g:detail(function()
			for index = 0, 2 do
				g:box("MagazineKeycap", V(12, 6, 12), CF(-14 + index * 14, -9, -42), cap)
			end
		end)
	end)
	g:key("MagWell", CF(0, -16, -42))
	g:hand("MagHand", V(-40, -80, -42), V(0.5, 0.4, -0.1), V(-1, 0, 0))

	g:rounded("Mouse", V(52, 30, 92), CF(0, -34, -190), 14, case)
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			g:box("MouseButton", V(22, K.FINE * 2, 40), CF(sx * 13, -20, -214), braid)
		end
		g:cylX("MouseWheel", 8, 16, CF(0, -18, -214), accent)
	end)
	g:hand("SupportHand", V(-12, -54, -196), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	trigger(g, K, -4, -40, braid, case)
	g:grip(V(0, -20, 74), 16, case, { length = 100, depth = 46, front = 24, back = 30, grooves = 3 })
	g:hand("GripHand", V(31, -58, 92), V(-0.3, 0.1, -1), V(1, 0.15, 0.3))
	g:rounded("Stock", V(40, 62, 150), CF(0, -12, 214), 12, case)
	g:prism("Buttpad", V(44, 96, 16), CF(0, -20, 292), 5, F.rubber)

	g.model:SetAttribute("Action", "semi")
	g.model:SetAttribute("Flash", "keycap")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Clean Sweep: two broom handles over a dustpan (break mechanism, double-barrel keypoints)
--------------------------------------------------------------------------------

Builders.CleanSweepDouble = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local pan = g.skinned and g.skin or plastic(K, 96, 148, 186)
	local handle = K.finishOf(Color3.fromRGB(176, 130, 78), K.Mat.Wood)
	local bristle = fabric(K, 226, 188, 96)
	local band = K.finishOf(Color3.fromRGB(176, 180, 188), K.Mat.Metal, 0.1)

	-- The action: a dustpan pressed into a body, with the top lever and two hammers on it.
	local receiver = g:rounded("Receiver", V(46, 58, 110), CF(0, -16, -5), 10, pan)
	-- The pan itself, wide under the barrels with a lip at its mouth, so the gun reads as a dustpan on sight.
	g:wedge("DustpanLip", V(98, 34, 96), CF(0, -40, -104) * A(0, 180, 0), pan)
	g:box("DustpanFloor", V(98, 6, 70), CF(0, -55, -118), pan)
	for _, sx in ipairs(SIGNS) do
		g:box("DustpanWall", V(6, 26, 96), CF(sx * 46, -30, -104), pan)
	end
	g:box("TopTang", V(16, 4, 50), CF(0, 13.6, 75) * A(8, 0, 0), band)
	g:box("TopLever", V(8, 5, 34), CF(6, 17.5, 62) * A(8, 25, 0), band)
	g:group("hammer", function()
		for _, sx in ipairs(SIGNS) do
			g:box("Hammer", V(7, 16, 10), CF(sx * 17, 16, 42) * A(35, 0, 0), band)
			g:box("HammerSpur", V(8, 5, 12), CF(sx * 17, 24, 49) * A(55, 0, 0), band)
		end
	end)
	g:swing("hammer", CF(0, 8, 38), -30)

	-- The barrels break downward about the pin at the front of the frame, the way a break gun opens.
	g:cylX("Hinge", 50, 16, CF(0, -30, -62), band)
	g:swing("hinge", CF(0, -30, -62), -40)
	g:group("hinge", function()
		for _, sx in ipairs(SIGNS) do
			g:cyl("Barrel", 330, 22, CF(sx * 11, 0, -227), handle)
			g:cyl("BarrelFerrule", 16, 25, CF(sx * 11, 0, -120), band)
			g:cyl("Bristles", 60, 30, CF(sx * 11, 0, -422), bristle)
			g:detail(function()
				for index = 0, 5 do
					g:box("Bristle", V(3, 26, 3), CF(sx * 11, 0, -452) * A(0, 0, 60 * index) * CF(0, 11, 0), bristle)
				end
			end)
			g:cyl("Bore", K.FINE, 18, CF(sx * 11, 0, -392 - K.FINE / 2), F.bore)
		end
		-- A raised rib between the handles with a brass bead, so the line clears the tang and lever.
		g:box("Rib", V(10, 18, 330), CF(0, 11, -227), band)
		g:ball("FrontBead", 5, CF(0, 21.5, -380), F.brass)
		g:rounded("ForeGrip", V(40, 22, 190), CF(0, -21, -185), 9, handle)
		g:box("ForendIron", V(20, 6, 40), CF(0, -34, -210), band)
	end)
	g:hand("SupportHand", V(-8, -46, -185), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "hinge")
	g:key("Load", CF(0, 0, -40))
	g.model:SetAttribute("LoadGroup", "hinge")
	g:key("Eject", CF(0, 6, -46) * A(118, 0, 0))
	g:key("Muzzle", CF(0, 0, -396))
	g:key("Sight", CF(0, 24, 50))
	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.78)

	-- Guard, two triggers, and a mop-head stock.
	g:box("TriggerGuard", V(12, 6, 60), CF(0, -60, 6), band)
	g:box("TriggerGuard", V(12, 17, 6), CF(0, -48.5, -21), band)
	g:box("TriggerGuard", V(12, 17, 6), CF(0, -48.5, 33), band)
	g:group("trigger", function()
		for _, z in ipairs({ -8, 10 }) do
			g:box("Trigger", V(5, 18, 5), CF(0, -46, z) * A(-12, 0, 0), band)
		end
	end)
	g:swing("trigger", CF(0, -38, 0), 12)
	g:rounded("Grip", V(34, 44, 96), CF(0, -34, 96) * A(10, 0, 0), 12, handle)
	g:rounded("Stock", V(42, 50, 150), CF(0, -52, 210) * A(6, 0, 0), 14, handle)
	g:cyl("MopCollar", 26, 52, CF(0, -58, 268) * A(6, 0, 0), band)
	g:detail(function()
		for index = 0, 7 do
			g:cyl("MopStrand", 90, 12, CF(0, -58, 300) * A(6, 0, 0) * A(0, 0, 45 * index) * CF(0, 16, 26), fabric(K, 236, 232, 220))
		end
	end)
	g:hand("GripHand", V(31, -74, 112), V(-0.3, 0.1, -1), V(1, 0.15, 0.3))
	g:hand("MagHand", V(-34, -40, -60), V(0.5, 0.3, -0.2), V(-1, -0.1, 0))

	g.model:SetAttribute("Action", "break")
	g.model:SetAttribute("Flash", "dust")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Hose Down: a hose reel with a brass nozzle and a jam-jar scope (bolt mechanism, sniper keypoints)
--------------------------------------------------------------------------------

Builders.HoseDownSniper = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local body = g.skinned and g.skin or plastic(K, 66, 132, 84)
	local hose = K.finishOf(Color3.fromRGB(46, 96, 62), K.Mat.Rubber)
	local brass = K.finishOf(Color3.fromRGB(206, 162, 82), K.Mat.Metal, 0.12)
	local steel = K.finishOf(Color3.fromRGB(176, 180, 188), K.Mat.Metal, 0.1)

	-- The reel: a drum of wound hose on a frame, with the crank on the right.
	local receiver = g:rounded("Receiver", V(54, 84, 210), CF(0, -12, 60), 14, body)
	g:cylX("Reel", 76, 130, CF(0, -6, 92), body)
	g:detail(function()
		for index = 0, 5 do
			g:cylX("ReelCoil", 74, 116 - index * 16, CF(0, -6, 92), index % 2 == 0 and hose or body)
		end
		g:cylX("ReelCrank", 14, 22, CF(44, -6, 92), steel)
		g:box("ReelHandle", V(10, 44, 10), CF(50, 16, 92), steel)
	end)

	-- The hose out of the reel to a brass nozzle, with a tap on the way.
	g:cyl("Barrel", 470, 26, CF(0, 0, -260), hose)
	for _, z in ipairs({ -120, -300, -440 }) do
		g:cyl("HoseBand", 12, 29, CF(0, 0, z), brass)
	end
	g:cyl("NozzleBody", 70, 34, CF(0, 0, -520), brass)
	g:cyl("NozzleTip", 40, 18, CF(0, 0, -572), brass)
	g:cyl("Bore", K.FINE, 12, CF(0, 0, -592 - K.FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -596))

	-- The tap handle is the bolt: turned up, drawn back, pushed home.
	g:group("bolt", function()
		g:box("BoltBody", V(20, 20, 90), CF(22, 10, 40), steel)
		g:box("TapHandle", V(12, 46, 12), CF(34, 30, 64), brass)
		g:ball("TapKnob", 18, CF(34, 54, 64), brass)
	end)
	g:swing("bolt", CF(0, 6, 60) * A(0, 90, 0), 60)
	g:travel("bolt", 90)
	g:hand("BoltHand", V(48, 30, 64), V(-0.5, 0.1, -0.8), V(0.4, 1, 0.2))
	g:key("Eject", CF(24, 12, -20) * A(0, -70, 20))

	-- A jam jar for a scope: the kit's scope inside a jar body with a screw lid.
	g:box("ScopeBase", V(30, 12, 150), CF(0, 30, 10), body)
	local h = g:scope(CF(0, 36, 10), "long")
	g:key("Sight", CF(0, 36 + h, 180))
	g:detail(function()
		-- Rings round the scope, not discs across it: you look through this.
		g:shell("JarLid", 22, 62, 9, CF(0, 36 + h, 96), brass)
		g:shell("JarRing", 10, 66, 10, CF(0, 36 + h, 84), brass)
		g:box("JarLabel", V(K.FINE * 2, 26, 40), CF(-29, 36 + h, 30), fabric(K, 244, 240, 226))
	end)
	g.model:SetAttribute("Optic", "scope")
	g.model:SetAttribute("EyeRelief", 0.6)

	-- A watering-can cartridge for a magazine, the grip, the trigger and a padded stock.
	g:group("mag", function()
		g:rounded("Magazine", V(56, 96, 60), CF(0, -76, -40), 12, K.finishOf(Color3.fromRGB(150, 226, 255), K.Mat.Glass, 0.15, 0.45))
		g:rounded("MagazineWater", V(46, 64, 50), CF(0, -88, -40), 8, K.finishOf(Color3.fromRGB(80, 170, 255), K.Mat.SmoothPlastic, 0, 0.3))
		g:box("MagazineCollar", V(60, 12, 64), CF(0, -30, -40), body)
	end)
	g:key("MagWell", CF(0, -30, -40))
	g:hand("MagHand", V(-40, -110, -40), V(0.4, 0.25, -0.15), V(-1, -0.15, 0))

	trigger(g, K, 0, -48, steel, body)
	g:grip(V(0, -42, 44), 14, body, { length = 104, depth = 48, front = 24, back = 32, grooves = 3 })
	g:hand("GripHand", V(32, -84, 62), V(-0.3, 0.05, -1), V(1, 0.2, 0.25))
	g:rounded("ForeGrip", V(44, 30, 170), CF(0, -26, -250), 10, body)
	g:hand("SupportHand", V(-6, -50, -250), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:rounded("Stock", V(46, 58, 190), CF(0, -30, 210) * A(3, 0, 0), 14, body)
	g:prism("Buttpad", V(50, 116, 18), CF(0, -40, 306), 6, F.rubber)

	g.model:SetAttribute("Action", "bolt")
	g.model:SetAttribute("Flash", "spray")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Dust Devil: a canister vacuum whose hoses spin (rotary mechanism, minigun keypoints)
--------------------------------------------------------------------------------

Builders.DustDevilRotary = function(g, K)
	local V, CF, A, F = K.V, K.CF, K.A, K.F
	local can = g.skinned and g.skin or plastic(K, 206, 74, 74)
	local hose = K.finishOf(Color3.fromRGB(58, 60, 68), K.Mat.Rubber)
	local steel = K.finishOf(Color3.fromRGB(176, 180, 188), K.Mat.Metal, 0.1)
	local bag = fabric(K, 214, 206, 186)

	-- The canister, its lid and the motor housing the hoses turn in front of.
	local receiver = g:rounded("Receiver", V(96, 120, 240), CF(0, -6, 90), 24, can)
	g:cyl("CanisterLid", 26, 104, CF(0, -6, -34), steel)
	g:cylX("CanisterWheel", 16, 56, CF(-54, -58, 150), hose)
	g:cylX("CanisterWheel", 16, 56, CF(54, -58, 150), hose)
	g:detail(function()
		g:box("PowerDial", V(40, K.FINE * 2, 40), CF(0, 56, 60), steel)
		for index = 0, 2 do
			g:box("CanisterVent", V(K.FINE * 2, 36, 12), CF(-48.2, -6, 20 + index * 24), F.shadow)
		end
	end)

	-- Four hoses on a hub, turning about the bore.
	g:group("spin", function()
		g:cyl("Hub", 60, 76, CF(0, 0, -120), steel)
		for index = 0, 3 do
			local around = CFrame.Angles(0, 0, index / 4 * math.pi * 2)
			g:at(CF(0, 0, -120) * around * CF(0, 30, 0), function()
				corrugated(g, K, "Hose", 0, -260, 34, hose, steel)
				g:cyl("HoseTip", 26, 40, CF(0, 0, -274), steel)
				g:cyl("Bore", K.FINE, 22, CF(0, 0, -288 - K.FINE / 2), F.bore)
			end)
		end
	end)
	g:swing("spin", CF(0, 0, -120) * A(0, 90, 0))
	-- On the bore, where the hoses converge, the way the chaingun's is.
	g:key("Muzzle", CF(0, 0, -412))

	-- The dust bag under it: the magazine, with a zip and a window of fluff. 20 mm ahead of where it first
	-- hung, clear of the grip's front strap so the trigger hand's fingers can close (#92).
	g:group("mag", function()
		g:rounded("Magazine", V(84, 110, 130), CF(0, -92, 60), 20, bag)
		g:box("MagazineZip", V(88, 10, 30), CF(0, -52, 60), steel)
		g:detail(function()
			for index = 0, 2 do
				g:ball("MagazineFluff", 26, CF(-22 + index * 22, -40, 40 + index * 10), bag)
			end
		end)
	end)
	g:key("MagWell", CF(0, -46, 60))
	g:hand("MagHand", V(-58, -104, 60), V(0.6, 0.5, -0.1), V(-1, 0, 0))

	-- A red dot on the canister's spine, clear of the hoses.
	g:box("SightRail", V(26, 10, 120), CF(0, 56, 10), steel)
	local h = g:redDot(CF(0, 60, 10))
	g:key("Sight", CF(0, 60 + h, 70))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- The wand handle at the back, the carry grip under the hoses.
	trigger(g, K, 120, -66, steel, can)
	g:grip(V(0, -60, 164), 14, hose, { length = 106, depth = 50, front = 26, back = 34, grooves = 3 })
	g:hand("GripHand", V(34, -100, 182), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	g:box("CarryBar", V(14, 80, 16), CF(0, -60, -60), steel)
	g:box("CarryBar", V(14, 16, 90), CF(0, -96, -104), hose)
	g:hand("SupportHand", V(-10, -100, -104), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	g.model:SetAttribute("Action", "rotary")
	g.model:SetAttribute("Flash", "dust")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

return GunModelsWorkshop
