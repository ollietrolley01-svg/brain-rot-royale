-- Experimental replacement art for the brainrot collection.
--
-- This module is deliberately NOT required by production code.  It gives every entry in
-- BrainrotData a newly-built model while leaving BrainrotModels.lua and every live caller alone.
-- Use tools/brainrot_remake_gallery.lua to review the set.  If the art is approved, callers can
-- later be switched in one place without changing names, saves, stats, or attacks.

local Remake = {}

local WHITE = Color3.fromRGB(247, 244, 236)
local BLACK = Color3.fromRGB(24, 22, 25)
local BROWN = Color3.fromRGB(124, 79, 42)
local WOOD = Color3.fromRGB(157, 105, 62)
local GREEN = Color3.fromRGB(70, 139, 67)
local YELLOW = Color3.fromRGB(248, 210, 55)
local PINK = Color3.fromRGB(237, 111, 154)
local STEEL = Color3.fromRGB(147, 157, 170)

local METRICS = { top = 1.9, faceY = 0.45, faceZ = -0.8, halfW = 1.55, bottom = -1.65, sideW = 1.0 }

function Remake.Metrics(_def)
	return METRICS
end

local CANONICAL = {
	["Tung Tung Tung Sahur"] = "Sahur",
	["Golden Sahur"] = "Sahur",
	["Bombardiro Crocodilo"] = "CrocodileBomber",
	["Tralalero Tralala"] = "ThreeShoeShark",
	["Chimpanzini Bananini"] = "BananaChimp",
	["Boneca Ambalabu"] = "FrogTire",
	["Lirili Larila"] = "CactusElephant",
	["Ballerina Cappuccina"] = "CoffeeBallerina",
	["Brr Brr Patapim"] = "ForestWalker",
	["Frigo Camelo"] = "FridgeCamel",
	["Bombombini Gusini"] = "JetGoose",
	["La Vacca Saturno Saturnita"] = "SaturnCow",
}

local function dark(color, amount)
	return color:Lerp(BLACK, amount or 0.28)
end

local function light(color, amount)
	return color:Lerp(WHITE, amount or 0.3)
end

local function builder(def, options)
	options = options or {}
	local look = def.look or {}
	local scale = (options.scale or 1) * (look.size or 1)
	local origin = options.cframe or CFrame.new()
	local anchored = options.anchored ~= false
	local color = look.color or Color3.fromRGB(190, 190, 190)
	local accent = look.accent or light(color, 0.25)
	local material = look.material == Enum.Material.Foil and Enum.Material.SmoothPlastic
		or look.material or Enum.Material.SmoothPlastic

	local model = Instance.new("Model")
	model.Name = def.name
	model:SetAttribute("BrainrotRemake", true)
	model:SetAttribute("Concept", CANONICAL[def.name] or "NameLiteral")

	local root
	local function part(className, name, size, cf, partColor, partMaterial, shape, transparency)
		local p = Instance.new(className or "Part")
		p.Name = name
		p.Size = size * scale
		p.CFrame = origin * CFrame.new(cf.Position * scale) * cf.Rotation
		p.Color = partColor or color
		p.Material = partMaterial or Enum.Material.SmoothPlastic
		p.Transparency = transparency or 0
		p.Anchored = anchored
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		if shape == "Ball" then
			p.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		elseif shape == "Ellipsoid" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = p
		end
		p.Parent = model
		return p
	end

	local function ellipsoid(name, size, pos, c, mat, rotation, transparency)
		return part("Part", name, size, CFrame.new(pos) * (rotation or CFrame.new()), c, mat, "Ellipsoid", transparency)
	end
	local function ball(name, diameter, pos, c, mat, transparency)
		return part("Part", name, Vector3.new(diameter, diameter, diameter), CFrame.new(pos), c, mat, "Ball", transparency)
	end
	local function block(name, size, pos, c, mat, rotation, transparency)
		return part("Part", name, size, CFrame.new(pos) * (rotation or CFrame.new()), c, mat, nil, transparency)
	end
	local function cylinder(name, height, diameter, pos, c, mat, rotation)
		return part("Part", name, Vector3.new(height, diameter, diameter), CFrame.new(pos) * (rotation or CFrame.Angles(0, 0, math.pi / 2)), c, mat, "Cylinder")
	end
	local function rod(name, a, b, width, c, mat)
		local delta = b - a
		return part("Part", name, Vector3.new(width, width, delta.Magnitude),
			CFrame.lookAt((a + b) / 2, b), c, mat, "Ellipsoid")
	end
	local function wedge(name, size, pos, c, rotation)
		return part("WedgePart", name, size, CFrame.new(pos) * (rotation or CFrame.new()), c)
	end
	local function intentionalFloat(p)
		p:SetAttribute("IntentionalFloat", true)
		return p
	end

	root = block("Root", Vector3.new(0.3, 0.3, 0.3), Vector3.zero, color, nil, nil, 1)
	model.PrimaryPart = root

	local function eye(x, y, z, radius, pupilScale, angry)
		ellipsoid("EyeWhite", Vector3.new(radius * 1.55, radius * 1.75, 0.16), Vector3.new(x, y, z), WHITE)
		local py = y + (angry and -0.03 or 0)
		ball("Pupil", radius * (pupilScale or 0.62), Vector3.new(x, py, z - 0.11), BLACK)
		if angry then
			rod("Brow", Vector3.new(x - 0.2, y + 0.22, z - 0.15), Vector3.new(x + 0.18, y + 0.13, z - 0.15), 0.08, dark(accent, 0.45))
		end
	end

	local function face(y, z, width, mood)
		local spread = width or 0.34
		eye(-spread, y, z, 0.3, nil, mood == "Angry")
		eye(spread, y, z, 0.3, nil, mood == "Angry")
		if mood ~= "None" then
			local mouthY = y - 0.47
			if mood == "O" then
				ellipsoid("Mouth", Vector3.new(0.36, 0.44, 0.13), Vector3.new(0, mouthY, z - 0.08), BLACK)
			else
				ellipsoid("Mouth", Vector3.new(mood == "Grin" and 0.76 or 0.55, 0.18, 0.12), Vector3.new(0, mouthY, z - 0.08), BLACK,
					nil, CFrame.Angles(0, 0, mood == "Frown" and math.pi or 0))
			end
		end
	end

	local function limb(name, shoulder, hand, thickness, c)
		local elbow = shoulder:Lerp(hand, 0.52) + Vector3.new(math.sign(hand.X) * 0.12, 0.08, -0.06)
		rod(name, shoulder, elbow, thickness, c or color)
		rod(name, elbow, hand, thickness * 0.86, c or color)
		ball(name .. "Hand", thickness * 1.25, hand, c or color)
	end

	local function shoe(name, pos, shoeColor, yaw)
		ellipsoid(name, Vector3.new(0.68, 0.34, 1.0), pos, shoeColor, nil, CFrame.Angles(0, yaw or 0, 0))
		block(name .. "Sole", Vector3.new(0.65, 0.09, 0.92), pos + Vector3.new(0, -0.17, -0.01), WHITE)
	end

	local function standardBody()
		-- A new two-volume toy silhouette, rather than the old one-piece body vocabulary.
		local body = look.body or "Blob"
		if body == "Cube" or body == "Can" or body == "Loaf" then
			block("Torso", Vector3.new(1.65, 1.75, 1.25), Vector3.new(0, -0.22, 0.12), color, material)
			ellipsoid("Head", Vector3.new(1.5, 1.22, 1.18), Vector3.new(0, 0.82, -0.03), light(color, 0.08), material)
		elseif body == "Disc" or body == "Cloud" then
			ellipsoid("Torso", Vector3.new(2.35, 1.15, 1.15), Vector3.new(0, -0.1, 0.1), color, material)
			ellipsoid("Head", Vector3.new(1.35, 1.2, 1.1), Vector3.new(0, 0.76, -0.12), light(color, 0.08), material)
		elseif body == "Pear" or body == "Cone" then
			ellipsoid("Torso", Vector3.new(1.8, 1.9, 1.32), Vector3.new(0, -0.3, 0.12), color, material)
			ball("Head", 1.25, Vector3.new(0, 0.88, -0.04), light(color, 0.08), material)
		else
			ellipsoid("Torso", Vector3.new(1.7, 1.85, 1.32), Vector3.new(0, -0.28, 0.12), color, material)
			ellipsoid("Head", Vector3.new(1.48, 1.35, 1.2), Vector3.new(0, 0.78, -0.04), light(color, 0.08), material)
		end
		face(0.82, -0.68, 0.32, look.eyes == "Angry" and "Angry" or look.mouth == "O" and "O" or look.mouth == "None" and "None" or "Smile")
		limb("ArmL", Vector3.new(-0.72, 0.05, 0), Vector3.new(-1.08, -0.6, -0.16), 0.2, color)
		limb("ArmR", Vector3.new(0.72, 0.05, 0), Vector3.new(1.08, -0.6, -0.16), 0.2, color)
		rod("LegL", Vector3.new(-0.4, -0.93, 0.1), Vector3.new(-0.48, -1.4, -0.06), 0.25, color)
		rod("LegR", Vector3.new(0.4, -0.93, 0.1), Vector3.new(0.48, -1.4, -0.06), 0.25, color)
		shoe("FootL", Vector3.new(-0.48, -1.5, -0.22), dark(accent, 0.15))
		shoe("FootR", Vector3.new(0.48, -1.5, -0.22), dark(accent, 0.15))
	end

	local function sahur()
		local gold = def.name == "Golden Sahur"
		local woodColor = gold and Color3.fromRGB(245, 183, 45) or WOOD
		cylinder("WoodenBody", 2.5, 1.25, Vector3.new(0, 0, 0.05), woodColor, gold and Enum.Material.Metal or Enum.Material.Wood)
		-- Rings make the kentongan/log origin readable even without a texture.
		for _, y in ipairs({ -0.82, -0.45, 0.52, 0.9 }) do
			cylinder("GrowthRing", 0.07, 1.27, Vector3.new(0, y, 0.05), dark(woodColor, 0.18))
		end
		face(0.42, -0.65, 0.3, "Smile")
		limb("ArmL", Vector3.new(-0.58, 0.2, 0), Vector3.new(-1.0, -0.42, -0.22), 0.18, woodColor)
		limb("ArmR", Vector3.new(0.58, 0.22, 0), Vector3.new(0.96, -0.1, -0.34), 0.18, woodColor)
		rod("LegL", Vector3.new(-0.3, -1.05, 0), Vector3.new(-0.38, -1.5, -0.1), 0.2, woodColor)
		rod("LegR", Vector3.new(0.3, -1.05, 0), Vector3.new(0.38, -1.5, -0.1), 0.2, woodColor)
		ellipsoid("BareFootL", Vector3.new(0.5, 0.24, 0.72), Vector3.new(-0.38, -1.56, -0.28), woodColor)
		ellipsoid("BareFootR", Vector3.new(0.5, 0.24, 0.72), Vector3.new(0.38, -1.56, -0.28), woodColor)
		rod("Bat", Vector3.new(0.86, -0.18, -0.26), Vector3.new(1.38, 1.35, 0.05), 0.22, dark(woodColor, 0.22), Enum.Material.Wood)
		ball("BatKnob", 0.29, Vector3.new(1.42, 1.47, 0.08), dark(woodColor, 0.22), Enum.Material.Wood)
		if gold then
			for i = -2, 2 do
				wedge("CrownPoint", Vector3.new(0.28, 0.55, 0.18), Vector3.new(i * 0.25, 1.6, 0), YELLOW, CFrame.Angles(0, 0, i * 0.08))
			end
		end
	end

	local function crocodileBomber()
		ellipsoid("Fuselage", Vector3.new(1.65, 1.2, 3.0), Vector3.new(0, 0.1, 0.2), GREEN, Enum.Material.SmoothPlastic)
		ellipsoid("CrocodileSnout", Vector3.new(1.15, 0.58, 1.45), Vector3.new(0, 0.18, -1.45), light(GREEN, 0.08))
		ball("EyeL", 0.32, Vector3.new(-0.36, 0.55, -1.42), WHITE)
		ball("EyeR", 0.32, Vector3.new(0.36, 0.55, -1.42), WHITE)
		ball("PupilL", 0.14, Vector3.new(-0.36, 0.55, -1.57), BLACK)
		ball("PupilR", 0.14, Vector3.new(0.36, 0.55, -1.57), BLACK)
		for _, x in ipairs({ -0.42, -0.14, 0.14, 0.42 }) do
			wedge("Tooth", Vector3.new(0.18, 0.26, 0.18), Vector3.new(x, -0.08, -2.06), WHITE, CFrame.Angles(math.pi, 0, 0))
		end
		block("WingL", Vector3.new(2.4, 0.12, 1.1), Vector3.new(-1.35, 0.08, 0.25), STEEL, Enum.Material.Metal, CFrame.Angles(0, -0.15, 0))
		block("WingR", Vector3.new(2.4, 0.12, 1.1), Vector3.new(1.35, 0.08, 0.25), STEEL, Enum.Material.Metal, CFrame.Angles(0, 0.15, 0))
		for _, x in ipairs({ -1.25, 1.25 }) do
			cylinder("Engine", 0.82, 0.52, Vector3.new(x, -0.04, 0), dark(STEEL, 0.2), Enum.Material.Metal, CFrame.Angles(0, math.pi / 2, 0))
			ball("EngineGlow", 0.28, Vector3.new(x, -0.04, 0.43), Color3.fromRGB(255, 120, 40), Enum.Material.Neon)
		end
		wedge("TailFin", Vector3.new(0.18, 0.85, 0.8), Vector3.new(0, 0.75, 1.35), GREEN)
		rod("LandingLegL", Vector3.new(-0.45, -0.4, 0.25), Vector3.new(-0.5, -1.05, 0), 0.16, GREEN)
		rod("LandingLegR", Vector3.new(0.45, -0.4, 0.25), Vector3.new(0.5, -1.05, 0), 0.16, GREEN)
		shoe("PilotShoeL", Vector3.new(-0.5, -1.17, -0.16), dark(GREEN, 0.35))
		shoe("PilotShoeR", Vector3.new(0.5, -1.17, -0.16), dark(GREEN, 0.35))
	end

	local function threeShoeShark()
		local blue = Color3.fromRGB(70, 142, 198)
		ellipsoid("SharkBody", Vector3.new(1.45, 1.45, 3.0), Vector3.new(0, 0.25, 0), blue)
		ellipsoid("WhiteBelly", Vector3.new(1.12, 0.68, 2.2), Vector3.new(0, -0.18, -0.34), WHITE)
		for _, x in ipairs({ -0.34, 0.34 }) do
			ball("Eye", 0.28, Vector3.new(x, 0.58, -1.38), WHITE)
			ball("Pupil", 0.12, Vector3.new(x, 0.58, -1.51), BLACK)
		end
		ellipsoid("Mouth", Vector3.new(0.72, 0.18, 0.12), Vector3.new(0, 0.05, -1.54), BLACK)
		wedge("DorsalFin", Vector3.new(0.22, 0.8, 0.9), Vector3.new(0, 1.05, 0.15), blue)
		wedge("TailTop", Vector3.new(0.18, 0.9, 0.8), Vector3.new(0, 0.67, 1.63), blue, CFrame.Angles(0, 0, 0.5))
		wedge("TailBottom", Vector3.new(0.18, 0.9, 0.8), Vector3.new(0, -0.15, 1.63), blue, CFrame.Angles(math.pi, 0, -0.5))
		-- The original's defining absurdity: three legs, each in a blue sneaker.
		for index, x in ipairs({ -0.55, 0, 0.55 }) do
			rod("Leg" .. index, Vector3.new(x, -0.45, 0), Vector3.new(x, -1.22, -0.12), 0.18, light(blue, 0.05))
			shoe("BlueSneaker" .. index, Vector3.new(x, -1.38, -0.38), Color3.fromRGB(45, 95, 205))
		end
	end

	local function bananaChimp()
		local fur = Color3.fromRGB(82, 126, 62)
		ellipsoid("BananaCore", Vector3.new(1.1, 2.15, 1.05), Vector3.new(0, -0.18, 0.08), YELLOW)
		for index, angle in ipairs({ -0.9, -0.3, 0.3, 0.9 }) do
			local x = math.sin(angle) * 0.72
			rod("Peel" .. index, Vector3.new(x * 0.25, -0.55, 0.25), Vector3.new(x, -1.45, 0.25 + math.abs(x) * 0.2), 0.3, YELLOW)
		end
		ball("ChimpHead", 1.22, Vector3.new(0, 0.86, -0.08), fur)
		ellipsoid("Muzzle", Vector3.new(0.78, 0.5, 0.36), Vector3.new(0, 0.67, -0.67), Color3.fromRGB(190, 132, 105))
		ball("EarL", 0.46, Vector3.new(-0.65, 0.9, -0.02), fur)
		ball("EarR", 0.46, Vector3.new(0.65, 0.9, -0.02), fur)
		face(0.98, -0.61, 0.27, "Smile")
		limb("ChimpArmL", Vector3.new(-0.52, 0.25, 0), Vector3.new(-1.0, -0.45, -0.25), 0.25, fur)
		limb("ChimpArmR", Vector3.new(0.52, 0.25, 0), Vector3.new(1.0, -0.45, -0.25), 0.25, fur)
	end

	local function frogTire()
		local frog = Color3.fromRGB(75, 183, 72)
		cylinder("Tire", 0.72, 1.95, Vector3.new(0, -0.15, 0.05), BLACK, Enum.Material.Rubber, CFrame.Angles(0, math.pi / 2, 0))
		cylinder("TireHub", 0.78, 0.9, Vector3.new(0, -0.15, 0.05), dark(STEEL, 0.15), Enum.Material.Metal, CFrame.Angles(0, math.pi / 2, 0))
		ellipsoid("FrogHead", Vector3.new(1.5, 0.95, 1.0), Vector3.new(0, 0.82, -0.12), frog)
		ball("EyeBumpL", 0.48, Vector3.new(-0.48, 1.22, -0.3), frog)
		ball("EyeBumpR", 0.48, Vector3.new(0.48, 1.22, -0.3), frog)
		eye(-0.48, 1.22, -0.58, 0.24)
		eye(0.48, 1.22, -0.58, 0.24)
		ellipsoid("FrogMouth", Vector3.new(0.78, 0.12, 0.1), Vector3.new(0, 0.62, -0.66), BLACK)
		for _, side in ipairs({ -1, 1 }) do
			rod("WoodenLeg", Vector3.new(side * 0.5, -0.48, 0), Vector3.new(side * 0.62, -1.42, -0.1), 0.22, WOOD, Enum.Material.Wood)
			ellipsoid("BareFoot", Vector3.new(0.55, 0.25, 0.72), Vector3.new(side * 0.62, -1.55, -0.28), WOOD)
		end
	end

	local function cactusElephant()
		local cactus = Color3.fromRGB(82, 151, 79)
		ellipsoid("CactusBody", Vector3.new(1.55, 2.1, 1.32), Vector3.new(0, -0.15, 0.12), cactus)
		ball("ElephantHead", 1.25, Vector3.new(0, 0.9, -0.05), cactus)
		ellipsoid("EarL", Vector3.new(0.75, 0.95, 0.16), Vector3.new(-0.72, 0.88, -0.08), light(cactus, 0.12))
		ellipsoid("EarR", Vector3.new(0.75, 0.95, 0.16), Vector3.new(0.72, 0.88, -0.08), light(cactus, 0.12))
		rod("Trunk", Vector3.new(0, 0.7, -0.58), Vector3.new(0.08, -0.2, -0.82), 0.28, cactus)
		rod("TrunkTip", Vector3.new(0.08, -0.2, -0.82), Vector3.new(0.32, -0.4, -0.7), 0.25, cactus)
		eye(-0.27, 1.0, -0.61, 0.22)
		eye(0.27, 1.0, -0.61, 0.22)
		for _, side in ipairs({ -1, 1 }) do
			rod("Leg", Vector3.new(side * 0.4, -0.92, 0.1), Vector3.new(side * 0.48, -1.35, -0.05), 0.28, cactus)
			shoe("Sandal", Vector3.new(side * 0.48, -1.5, -0.22), BROWN)
		end
		for i = 0, 10 do
			local angle = i / 10 * math.pi * 2
			rod("CactusSpine", Vector3.new(math.sin(angle) * 0.7, -0.1, math.cos(angle) * 0.55),
				Vector3.new(math.sin(angle) * 0.86, -0.02, math.cos(angle) * 0.7), 0.05, WHITE)
		end
	end

	local function coffeeBallerina()
		local skin = Color3.fromRGB(232, 190, 158)
		ellipsoid("BallerinaTorso", Vector3.new(0.72, 1.15, 0.52), Vector3.new(0, -0.05, 0), skin)
		cylinder("CupHead", 0.75, 1.02, Vector3.new(0, 0.9, -0.03), Color3.fromRGB(242, 224, 200))
		cylinder("Coffee", 0.05, 0.86, Vector3.new(0, 1.29, -0.03), Color3.fromRGB(79, 42, 27))
		-- Torus-free cup handle: three curved-looking links.
		rod("CupHandle", Vector3.new(0.47, 1.08, 0), Vector3.new(0.77, 1.08, 0), 0.12, Color3.fromRGB(242, 224, 200))
		rod("CupHandle", Vector3.new(0.77, 1.08, 0), Vector3.new(0.77, 0.72, 0), 0.12, Color3.fromRGB(242, 224, 200))
		rod("CupHandle", Vector3.new(0.77, 0.72, 0), Vector3.new(0.47, 0.72, 0), 0.12, Color3.fromRGB(242, 224, 200))
		face(0.93, -0.53, 0.25, "Smile")
		-- Layered tutu and ballet pose.
		for i = 0, 2 do
			cylinder("Tutu", 0.12, 1.75 - i * 0.25, Vector3.new(0, -0.48 - i * 0.08, 0.04), light(PINK, i * 0.12))
		end
		rod("ArmL", Vector3.new(-0.3, 0.25, 0), Vector3.new(-0.92, 0.65, -0.08), 0.14, skin)
		rod("ArmR", Vector3.new(0.3, 0.25, 0), Vector3.new(0.92, 0.65, -0.08), 0.14, skin)
		rod("LegL", Vector3.new(-0.18, -0.55, 0), Vector3.new(-0.24, -1.48, -0.1), 0.17, skin)
		rod("LegR", Vector3.new(0.18, -0.55, 0), Vector3.new(0.58, -1.15, 0.08), 0.17, skin)
		ellipsoid("SlipperL", Vector3.new(0.35, 0.2, 0.55), Vector3.new(-0.24, -1.55, -0.25), PINK)
		ellipsoid("SlipperR", Vector3.new(0.35, 0.2, 0.55), Vector3.new(0.66, -1.2, -0.05), PINK, nil, CFrame.Angles(0.4, 0, 0))
	end

	local function forestWalker()
		local bark = Color3.fromRGB(102, 78, 48)
		ellipsoid("LeafBody", Vector3.new(1.75, 1.95, 1.35), Vector3.new(0, -0.2, 0.1), dark(GREEN, 0.08))
		ball("WoodFace", 1.2, Vector3.new(0, 0.75, -0.08), bark, Enum.Material.Wood)
		face(0.82, -0.68, 0.3, "Smile")
		for i = 0, 7 do
			local angle = i / 8 * math.pi * 2
			ball("LeafClump", 0.62, Vector3.new(math.sin(angle) * 0.72, 1.17 + (i % 2) * 0.18, math.cos(angle) * 0.45),
				(i % 2 == 0) and GREEN or light(GREEN, 0.12))
		end
		for _, side in ipairs({ -1, 1 }) do
			limb("BranchArm", Vector3.new(side * 0.7, 0.1, 0), Vector3.new(side * 1.2, -0.42, -0.1), 0.2, bark)
			rod("RootLeg", Vector3.new(side * 0.36, -0.95, 0.1), Vector3.new(side * 0.55, -1.43, -0.05), 0.27, bark)
			ellipsoid("BareRootFoot", Vector3.new(0.64, 0.3, 0.92), Vector3.new(side * 0.55, -1.53, -0.3), bark)
		end
	end

	local function fridgeCamel()
		block("Fridge", Vector3.new(1.55, 2.1, 1.15), Vector3.new(0, -0.18, 0.1), Color3.fromRGB(222, 231, 236), Enum.Material.Metal)
		block("FreezerLine", Vector3.new(1.42, 0.06, 1.18), Vector3.new(0, 0.28, 0.08), dark(STEEL, 0.05), Enum.Material.Metal)
		block("Handle", Vector3.new(0.1, 0.72, 0.1), Vector3.new(0.54, 0.02, -0.52), STEEL, Enum.Material.Metal)
		-- Camel neck and head emerge unmistakably from the appliance.
		rod("CamelNeck", Vector3.new(-0.38, 0.66, 0.08), Vector3.new(-0.62, 1.5, -0.05), 0.44, Color3.fromRGB(186, 143, 88))
		ellipsoid("CamelHead", Vector3.new(0.82, 0.58, 1.0), Vector3.new(-0.62, 1.62, -0.36), Color3.fromRGB(186, 143, 88))
		ball("CamelEyeL", 0.17, Vector3.new(-0.84, 1.75, -0.79), BLACK)
		ball("CamelEyeR", 0.17, Vector3.new(-0.42, 1.75, -0.79), BLACK)
		ellipsoid("CamelMuzzle", Vector3.new(0.62, 0.3, 0.42), Vector3.new(-0.62, 1.5, -0.82), light(BROWN, 0.25))
		for _, side in ipairs({ -1, 1 }) do
			rod("CamelLeg", Vector3.new(side * 0.43, -1.05, 0.1), Vector3.new(side * 0.5, -1.42, -0.05), 0.24, Color3.fromRGB(186, 143, 88))
			shoe("Boot", Vector3.new(side * 0.5, -1.54, -0.26), dark(BROWN, 0.18))
		end
	end

	local function jetGoose()
		ellipsoid("GooseBody", Vector3.new(1.3, 1.45, 1.9), Vector3.new(0, -0.05, 0.2), WHITE)
		rod("GooseNeck", Vector3.new(0, 0.42, -0.55), Vector3.new(0, 1.25, -0.82), 0.34, WHITE)
		ball("GooseHead", 0.68, Vector3.new(0, 1.38, -0.9), WHITE)
		ellipsoid("Beak", Vector3.new(0.48, 0.24, 0.65), Vector3.new(0, 1.34, -1.42), Color3.fromRGB(240, 147, 36))
		ball("GooseEyeL", 0.12, Vector3.new(-0.2, 1.51, -1.19), BLACK)
		ball("GooseEyeR", 0.12, Vector3.new(0.2, 1.51, -1.19), BLACK)
		block("WingL", Vector3.new(1.65, 0.16, 0.8), Vector3.new(-1.02, 0.18, 0.18), WHITE, nil, CFrame.Angles(0, -0.18, -0.05))
		block("WingR", Vector3.new(1.65, 0.16, 0.8), Vector3.new(1.02, 0.18, 0.18), WHITE, nil, CFrame.Angles(0, 0.18, 0.05))
		for _, x in ipairs({ -1.2, -0.78, 0.78, 1.2 }) do
			cylinder("JetEngine", 0.72, 0.42, Vector3.new(x, 0.02, 0.25), STEEL, Enum.Material.Metal, CFrame.Angles(0, math.pi / 2, 0))
			ball("JetFlame", 0.22, Vector3.new(x, 0.02, 0.64), Color3.fromRGB(255, 124, 35), Enum.Material.Neon)
		end
		for _, side in ipairs({ -1, 1 }) do
			rod("GooseLeg", Vector3.new(side * 0.3, -0.68, 0.2), Vector3.new(side * 0.34, -1.22, 0.05), 0.14, Color3.fromRGB(240, 147, 36))
			ellipsoid("WebbedFoot", Vector3.new(0.5, 0.14, 0.65), Vector3.new(side * 0.34, -1.3, -0.12), Color3.fromRGB(240, 147, 36))
		end
	end

	local function saturnCow()
		ball("Saturn", 1.65, Vector3.new(0, -0.05, 0.12), Color3.fromRGB(174, 142, 105))
		cylinder("SaturnRing", 0.09, 3.2, Vector3.new(0, -0.02, 0.12), Color3.fromRGB(214, 180, 125), nil, CFrame.Angles(0, 0, math.pi / 2) * CFrame.Angles(0.28, 0, 0.2))
		ball("CowHead", 1.12, Vector3.new(0, 1.08, -0.05), WHITE)
		ellipsoid("CowMuzzle", Vector3.new(0.78, 0.42, 0.42), Vector3.new(0, 0.88, -0.62), Color3.fromRGB(224, 155, 157))
		ball("CowSpotL", 0.36, Vector3.new(-0.3, 1.28, -0.48), BLACK)
		eye(-0.28, 1.2, -0.6, 0.2)
		eye(0.28, 1.2, -0.6, 0.2)
		rod("HornL", Vector3.new(-0.42, 1.48, -0.05), Vector3.new(-0.76, 1.75, -0.08), 0.14, Color3.fromRGB(226, 208, 156))
		rod("HornR", Vector3.new(0.42, 1.48, -0.05), Vector3.new(0.76, 1.75, -0.08), 0.14, Color3.fromRGB(226, 208, 156))
		for _, side in ipairs({ -1, 1 }) do
			rod("HumanLeg", Vector3.new(side * 0.35, -0.72, 0.08), Vector3.new(side * 0.38, -1.35, -0.08), 0.2, Color3.fromRGB(198, 151, 122))
			ellipsoid("BareFoot", Vector3.new(0.5, 0.23, 0.75), Vector3.new(side * 0.38, -1.48, -0.3), Color3.fromRGB(198, 151, 122))
		end
	end

	local function addNameLiteralDetails()
		local name = def.name
		local extras = look.extras or {}
		local has = {}
		for _, extra in ipairs(extras) do has[extra] = true end

		if has.Horns or string.find(name, "Drago") or string.find(name, "Cervo") then
			for _, side in ipairs({ -1, 1 }) do
				rod("Horn", Vector3.new(side * 0.38, 1.3, 0), Vector3.new(side * 0.62, 1.78, 0.04), 0.14, accent)
			end
		end
		if has.Wings or string.find(name, "Fenice") or string.find(name, "Farfalla") or string.find(name, "Grifone") then
			for _, side in ipairs({ -1, 1 }) do
				wedge("Wing", Vector3.new(1.15, 1.2, 0.18), Vector3.new(side * 1.08, 0.25, 0.35), accent,
					CFrame.Angles(0, side * 0.3, side * 0.18))
			end
		end
		if has.Tail or has.TailFin or string.find(name, "Serpentino") or string.find(name, "Biscione") or string.find(name, "Lupo") then
			rod("Tail", Vector3.new(0, -0.45, 0.55), Vector3.new(0.65, -0.25, 1.25), 0.28, accent)
			rod("TailTip", Vector3.new(0.65, -0.25, 1.25), Vector3.new(0.85, 0.1, 1.35), 0.2, accent)
		end
		if has.Crown or string.find(name, "Imperat") or string.find(name, "Re ") then
			for i = -2, 2 do
				wedge("CrownPoint", Vector3.new(0.25, 0.52, 0.18), Vector3.new(i * 0.22, 1.55, 0), YELLOW)
			end
		end
		if has.WizardHat or string.find(name, "Mago") or string.find(name, "Streg") then
			cylinder("HatBrim", 0.1, 1.42, Vector3.new(0, 1.38, 0), dark(accent, 0.25))
			wedge("HatCone", Vector3.new(1.05, 1.28, 1.05), Vector3.new(0, 1.96, 0.03), dark(accent, 0.25), CFrame.Angles(0, math.pi / 4, 0))
		end
		if has.Halo or string.find(name, "Stell") or string.find(name, "Galass") then
			intentionalFloat(cylinder("Halo", 0.08, 1.35, Vector3.new(0, 1.72, 0), accent, Enum.Material.Neon))
		end
		if has.Antenna or string.find(name, "Robot") or string.find(name, "Mecha") then
			rod("Antenna", Vector3.new(0, 1.32, 0), Vector3.new(0.2, 1.83, 0), 0.09, STEEL, Enum.Material.Metal)
			ball("AntennaLight", 0.24, Vector3.new(0.2, 1.88, 0), accent, Enum.Material.Neon)
		end
		if has.Tentacles or string.find(name, "Polipo") or string.find(name, "Calamaro") or string.find(name, "Medusa") or string.find(name, "Kraken") then
			for i = 0, 5 do
				local angle = i / 6 * math.pi * 2
				rod("Tentacle", Vector3.new(math.sin(angle) * 0.45, -0.82, math.cos(angle) * 0.35),
					Vector3.new(math.sin(angle) * 0.82, -1.45, math.cos(angle) * 0.65), 0.18, accent)
			end
		end
		if has.Spikes or has.Quills or string.find(name, "Riccio") or string.find(name, "Cactus") then
			for i = 0, 7 do
				local angle = i / 8 * math.pi * 2
				rod("Spike", Vector3.new(math.sin(angle) * 0.68, 0, math.cos(angle) * 0.52),
					Vector3.new(math.sin(angle) * 1.0, 0.12, math.cos(angle) * 0.82), 0.08, accent)
			end
		end
		if has.Shell or string.find(name, "Tartar") or string.find(name, "Lumach") then
			ellipsoid("Shell", Vector3.new(1.45, 1.35, 0.55), Vector3.new(0, -0.08, 0.72), accent)
			rod("ShellSpiral", Vector3.new(0, 0.35, 1.02), Vector3.new(0.4, 0.05, 1.05), 0.1, dark(accent, 0.35))
		end
		if has.Orbit or string.find(name, "Orbit") or string.find(name, "Astron") or string.find(name, "Cosmo") or string.find(name, "Buco Nero") then
			intentionalFloat(cylinder("OrbitRing", 0.08, 2.5, Vector3.new(0, 0, 0.1), accent, Enum.Material.Neon,
				CFrame.Angles(0, 0, math.pi / 2) * CFrame.Angles(0.35, 0, 0.2)))
		end
		if has.Propeller then
			rod("Propeller", Vector3.new(-0.85, 1.48, 0), Vector3.new(0.85, 1.48, 0), 0.12, STEEL, Enum.Material.Metal)
			ball("PropellerHub", 0.25, Vector3.new(0, 1.48, 0), accent)
		end
		if has.Mane or string.find(name, "Leone") or string.find(name, "Lupo") then
			for i = 0, 9 do
				local angle = i / 10 * math.pi * 2
				ball("Mane", 0.48, Vector3.new(math.sin(angle) * 0.67, 0.8 + math.cos(angle) * 0.65, 0.18), accent)
			end
		end

		-- Name-defining props for the game's original concepts.
		if string.find(name, "Pizza") then
			cylinder("Pizza", 0.16, 1.65, Vector3.new(0, -0.12, -0.72), Color3.fromRGB(236, 184, 83))
			for _, p in ipairs({ Vector3.new(-0.35, 0.05, -0.84), Vector3.new(0.3, -0.22, -0.84), Vector3.new(0.2, 0.25, -0.84) }) do ball("Pepperoni", 0.28, p, Color3.fromRGB(190, 55, 45)) end
		elseif string.find(name, "Toast") or string.find(name, "Tostapane") then
			block("Toast", Vector3.new(1.12, 0.92, 0.24), Vector3.new(0, 0.12, -0.76), Color3.fromRGB(225, 168, 84))
		elseif string.find(name, "Nood") or string.find(name, "Spaghett") then
			for i = -2, 2 do rod("Noodle", Vector3.new(i * 0.19, 1.2, -0.2), Vector3.new(i * 0.24, 0.35, -0.78), 0.1, YELLOW) end
		elseif string.find(name, "Fungo") then
			cylinder("MushroomStem", 0.72, 0.65, Vector3.new(0, 1.22, 0), WHITE)
			ellipsoid("MushroomCap", Vector3.new(1.6, 0.62, 1.25), Vector3.new(0, 1.64, 0), accent)
		elseif string.find(name, "Nuvol") then
			for _, p in ipairs({ Vector3.new(-0.5, 0.55, 0), Vector3.new(0, 0.75, -0.1), Vector3.new(0.5, 0.55, 0) }) do ball("CloudPuff", 0.9, p, WHITE) end
			wedge("Lightning", Vector3.new(0.35, 0.85, 0.2), Vector3.new(0, -1.15, -0.72), YELLOW)
		elseif string.find(name, "Gelato") or string.find(name, "Ghiacciolo") then
			wedge("IceCream", Vector3.new(1.0, 1.4, 1.0), Vector3.new(0, 1.34, 0), light(accent, 0.2), CFrame.Angles(0, math.pi / 4, math.pi))
		elseif string.find(name, "Cavaliere") then
			ellipsoid("Helmet", Vector3.new(1.58, 1.25, 1.22), Vector3.new(0, 0.92, 0), STEEL, Enum.Material.Metal)
			block("Visor", Vector3.new(1.25, 0.24, 0.12), Vector3.new(0, 0.84, -0.66), BLACK, Enum.Material.Metal)
		elseif string.find(name, "Faraone") then
			wedge("NemesL", Vector3.new(0.75, 1.25, 0.2), Vector3.new(-0.5, 0.72, 0), YELLOW)
			wedge("NemesR", Vector3.new(0.75, 1.25, 0.2), Vector3.new(0.5, 0.72, 0), YELLOW)
		elseif string.find(name, "Castello") then
			for _, x in ipairs({ -0.62, 0, 0.62 }) do block("Tower", Vector3.new(0.42, 0.75, 0.42), Vector3.new(x, 1.45, 0), STEEL, Enum.Material.Slate) end
		elseif string.find(name, "Balena") then
			wedge("WhaleTailL", Vector3.new(0.65, 0.72, 0.18), Vector3.new(-0.34, 0.02, 1.05), accent, CFrame.Angles(0, 0.4, 0.3))
			wedge("WhaleTailR", Vector3.new(0.65, 0.72, 0.18), Vector3.new(0.34, 0.02, 1.05), accent, CFrame.Angles(0, -0.4, -0.3))
		elseif string.find(name, "Faro") then
			cylinder("Beacon", 0.55, 0.95, Vector3.new(0, 1.5, 0), WHITE, Enum.Material.Glass)
			intentionalFloat(ball("BeaconLight", 0.4, Vector3.new(0, 1.5, 0), YELLOW, Enum.Material.Neon))
		elseif string.find(name, "Tuba") then
			cylinder("HornBell", 0.62, 0.82, Vector3.new(0.72, 0.15, -0.6), YELLOW, Enum.Material.Metal, CFrame.Angles(0, 0, 0))
		elseif string.find(name, "Lavatrice") then
			cylinder("WasherDoor", 0.12, 1.0, Vector3.new(0, -0.12, -0.7), STEEL, Enum.Material.Metal, CFrame.Angles(0, math.pi / 2, 0))
			cylinder("WasherGlass", 0.13, 0.7, Vector3.new(0, -0.12, -0.77), Color3.fromRGB(90, 185, 225), Enum.Material.Glass, CFrame.Angles(0, math.pi / 2, 0))
		elseif string.find(name, "Mortadella") then
			for i = -1, 1 do ball("MortadellaSpot", 0.24, Vector3.new(i * 0.4, 0, -0.74), WHITE) end
		elseif string.find(name, "Gorgonzola") or string.find(name, "Formaggio") then
			for i = 0, 4 do ball("CheeseHole", 0.22, Vector3.new(-0.6 + i * 0.3, -0.2 + (i % 2) * 0.5, -0.76), dark(YELLOW, 0.32)) end
		elseif string.find(name, "Pixel") or string.find(name, "Glitch") then
			for i = 0, 7 do
				local p = Vector3.new(((i * 7) % 5 - 2) * 0.42, -0.9 + (i % 4) * 0.58, (i % 2 == 0) and -0.82 or 0.74)
				intentionalFloat(block("Pixel", Vector3.new(0.22, 0.22, 0.22), p, (i % 2 == 0) and accent or PINK, Enum.Material.Neon))
			end
		end
	end

	local concept = CANONICAL[def.name]
	if concept == "Sahur" then sahur()
	elseif concept == "CrocodileBomber" then crocodileBomber()
	elseif concept == "ThreeShoeShark" then threeShoeShark()
	elseif concept == "BananaChimp" then bananaChimp()
	elseif concept == "FrogTire" then frogTire()
	elseif concept == "CactusElephant" then cactusElephant()
	elseif concept == "CoffeeBallerina" then coffeeBallerina()
	elseif concept == "ForestWalker" then forestWalker()
	elseif concept == "FridgeCamel" then fridgeCamel()
	elseif concept == "JetGoose" then jetGoose()
	elseif concept == "SaturnCow" then saturnCow()
	else
		standardBody()
		addNameLiteralDetails()
	end

	if options.glow then
		local lightObject = Instance.new("PointLight")
		lightObject.Color = options.glow
		lightObject.Range = 10 * scale
		lightObject.Brightness = 1.4
		lightObject.Parent = root
	end

	if not anchored then
		for _, child in ipairs(model:GetChildren()) do
			if child:IsA("BasePart") and child ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = child
				weld.Parent = child
			end
		end
		root.Anchored = false
	end

	return model
end

function Remake.Build(def, options)
	assert(type(def) == "table", "BrainrotModelsRemake.Build expects a BrainrotData definition")
	return builder(def, options)
end

function Remake.FrameViewport(viewport, def, distance)
	local camera = viewport.CurrentCamera
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = viewport
		viewport.CurrentCamera = camera
	end
	local size = (def and def.look and def.look.size) or 1
	local d = (distance or 7.8) * size
	camera.FieldOfView = 38
	camera.CFrame = CFrame.lookAt(Vector3.new(d * 0.25, 1.0 * size + d * 0.14, -d), Vector3.new(0, 0.15 * size, 0))
	return camera
end

return Remake
