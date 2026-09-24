-- Gun skins, auras and accessories, bought with SahurCoins or pulled from crates. Skins
-- recolor whatever gun you are holding rather than being per-weapon, so one purchase is always
-- useful.

local CosmeticData = {}

--------------------------------------------------------------------------------
-- Accessory pieces
--------------------------------------------------------------------------------

-- An accessory is a list of primitive pieces placed relative to an anchor on the wearer: the
-- top of the head ("HeadTop"), the front of the face ("Face"), or the middle of the back
-- ("Back"). Sizes and positions are authored against an R15 head 1.2 studs tall, and
-- AccessoryService scales them to whoever wears one — no uploaded meshes needed. Characters
-- face -Z, so on the face anchor negative Z points outward, and on the back anchor positive Z
-- does.

local NEON = Enum.Material.Neon

local WHITE = Color3.fromRGB(246, 246, 240)
local BLACK = Color3.fromRGB(24, 24, 28)
local PINK = Color3.fromRGB(255, 120, 190)
local CYAN = Color3.fromRGB(70, 214, 236)
local YELLOW = Color3.fromRGB(255, 214, 64)
local ORANGE = Color3.fromRGB(255, 132, 36)
local RED = Color3.fromRGB(206, 48, 48)
local BLUE = Color3.fromRGB(64, 120, 235)
local GOLD = Color3.fromRGB(255, 196, 64)
local STEEL = Color3.fromRGB(196, 202, 210)
local IVORY = Color3.fromRGB(240, 230, 200)
local BRONZE = Color3.fromRGB(176, 118, 60)
local BRAIN = Color3.fromRGB(255, 150, 176)
local BRAIN_DARK = Color3.fromRGB(206, 92, 124)
local PURPLE = Color3.fromRGB(150, 80, 240)
local GREEN = Color3.fromRGB(80, 220, 120)
local CHEESE = Color3.fromRGB(252, 204, 86)
local CRUST = Color3.fromRGB(178, 112, 52)
local TOAST = Color3.fromRGB(206, 150, 80)
local WOOD = Color3.fromRGB(168, 122, 72)
local SOCK = Color3.fromRGB(198, 220, 158)
local STINK = Color3.fromRGB(150, 196, 96)
local NOODLE = Color3.fromRGB(248, 226, 146)
local BROTH = Color3.fromRGB(222, 168, 88)
local CACTUS = Color3.fromRGB(86, 164, 88)
local BLOOM = Color3.fromRGB(246, 128, 168)
local CROC = Color3.fromRGB(92, 150, 80)
local CROC_DARK = Color3.fromRGB(58, 104, 52)

local function block(size, position, color, material)
	return { shape = "Block", size = size, offset = CFrame.new(position), color = color, material = material }
end

-- A block placed by a full CFrame, for pieces that are turned rather than just moved.
local function plate(size, frame, color, material)
	return { shape = "Block", size = size, offset = frame, color = color, material = material }
end

-- A block with a sphere mesh, so it can be squashed — Ball parts are forced round.
local function sphere(size, position, color, material)
	return { shape = "Sphere", size = size, offset = CFrame.new(position), color = color, material = material }
end

local function ball(diameter, position, color, material)
	return {
		shape = "Ball",
		size = Vector3.new(diameter, diameter, diameter),
		offset = CFrame.new(position),
		color = color,
		material = material,
	}
end

-- Upright cylinder. Cylinder parts run along their X axis, hence the quarter turn.
local function column(height, diameter, position, color, material)
	return {
		shape = "Cylinder",
		size = Vector3.new(height, diameter, diameter),
		offset = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2),
		color = color,
		material = material,
	}
end

-- Cylinder along an arbitrary direction: `frame` places and turns it; its length runs along X.
local function rod(length, diameter, frame, color, material)
	return {
		shape = "Cylinder",
		size = Vector3.new(length, diameter, diameter),
		offset = frame,
		color = color,
		material = material,
	}
end

-- One triangular point, `spread` wide and `rise` tall, standing on `seat`: two wedges, mirrored, with
-- the apex over the seat's centre. `thick` is its depth along the seat's Z.
--
-- A wedge is full height at its +Z and falls to an edge at -Z, so each half turns its +Z to the centre
-- line and slopes away outwards. The halves meet on that line exactly: overlapping there would put
-- their two triangular sides in one plane with area in common, which is the fault this exists to avoid.
local function spike(seat, rise, spread, thick, color, material)
	local half = spread / 2
	local pieces = {}
	for _, side in ipairs({ 1, -1 }) do
		table.insert(pieces, {
			shape = "Wedge",
			size = Vector3.new(thick, rise, half),
			offset = seat * CFrame.new(side * half / 2, 0, 0) * CFrame.Angles(0, -side * math.pi / 2, 0),
			color = color,
			material = material,
		})
	end
	return pieces
end

-- A ring of those points standing on a band, each turned to follow it. Keep `spread` under
-- 2 * (radius - thick / 2) * tan(pi / count) or neighbouring points overlap at their inner corners,
-- which is how the crown ended up a staircase the first time.
local function points(count, radius, base, rise, spread, thick, color, material)
	local pieces = {}
	for index = 0, count - 1 do
		local angle = index / count * math.pi * 2
		local seat = CFrame.new(0, base + rise / 2, 0) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, radius)
		for _, piece in ipairs(spike(seat, rise, spread, thick, color, material)) do
			table.insert(pieces, piece)
		end
	end
	return pieces
end

-- Pieces spaced evenly around a horizontal ring (optionally tilted), each turned to follow it.
local function ring(count, radius, height, pieceSize, color, material, tilt)
	local pieces = {}
	for index = 0, count - 1 do
		local angle = index / count * math.pi * 2
		table.insert(pieces, {
			shape = "Block",
			size = pieceSize,
			offset = CFrame.new(0, height, 0) * (tilt or CFrame.new()) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, radius),
			color = color,
			material = material,
		})
	end
	return pieces
end

local function concat(...)
	local out = {}
	for _, list in ipairs({ ... }) do
		for _, piece in ipairs(list) do
			table.insert(out, piece)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------

CosmeticData.Items = {
	GoldSahur = {
		name = "Gold Sahur",
		kind = "GunSkin",
		rarity = "Epic",
		price = 25000,
		color = Color3.fromRGB(255, 194, 62),
		material = Enum.Material.Foil,
		description = "The coin, but on your gun.",
	},
	CrocodiloCamo = {
		name = "Crocodilo Camo",
		kind = "GunSkin",
		rarity = "Uncommon",
		price = 6000,
		color = Color3.fromRGB(88, 128, 68),
		material = Enum.Material.Fabric,
		description = "Bombardiro-issue green.",
	},
	BananiniYellow = {
		name = "Bananini",
		kind = "GunSkin",
		rarity = "Common",
		price = 4500,
		color = Color3.fromRGB(240, 214, 70),
		material = Enum.Material.SmoothPlastic,
		description = "Slippery. Loud.",
	},
	VoidRot = {
		name = "Void Rot",
		kind = "GunSkin",
		rarity = "Rare",
		price = 15000,
		color = Color3.fromRGB(38, 26, 58),
		material = Enum.Material.Neon,
		description = "Absorbs light and dignity.",
	},
	CappuccinaPink = {
		name = "Cappuccina",
		kind = "GunSkin",
		rarity = "Uncommon",
		price = 8000,
		color = Color3.fromRGB(245, 148, 196),
		material = Enum.Material.SmoothPlastic,
		description = "Ballerina-approved.",
	},
	SahurAura = {
		name = "Sahur Aura",
		kind = "Aura",
		rarity = "Epic",
		price = 30000,
		color = Color3.fromRGB(255, 184, 48),
		description = "A golden glow that follows you around.",
	},
	RotAura = {
		name = "Rot Aura",
		kind = "Aura",
		rarity = "Rare",
		price = 12000,
		color = Color3.fromRGB(150, 90, 220),
		description = "Purple haze. Purely cosmetic.",
	},

	-- More skins and auras. The top rarities are crate exclusives: the Gun Skin and Aura crates
	-- are the only way to get them.
	RustBucket = {
		name = "Rust Bucket",
		kind = "GunSkin",
		rarity = "Common",
		price = 3000,
		color = Color3.fromRGB(150, 92, 60),
		material = Enum.Material.CorrodedMetal,
		description = "Held together by optimism.",
	},
	DiamondTread = {
		name = "Diamond Tread",
		kind = "GunSkin",
		rarity = "Uncommon",
		price = 7000,
		color = Color3.fromRGB(190, 196, 204),
		material = Enum.Material.DiamondPlate,
		description = "Grippy, shiny, serious.",
	},
	FrostbiteSkin = {
		name = "Frostbite",
		kind = "GunSkin",
		rarity = "Rare",
		price = 16000,
		color = Color3.fromRGB(170, 220, 255),
		material = Enum.Material.Ice,
		description = "Cold to the touch.",
	},
	MagmaCore = {
		name = "Magma Core",
		kind = "GunSkin",
		rarity = "Legendary",
		crateOnly = true,
		color = Color3.fromRGB(255, 110, 40),
		material = Enum.Material.CrackedLava,
		description = "Crate exclusive. Still cooling.",
	},
	GlitchSkin = {
		name = "Glitch",
		kind = "GunSkin",
		rarity = "Mythic",
		crateOnly = true,
		color = Color3.fromRGB(0, 255, 200),
		material = Enum.Material.ForceField,
		description = "Crate exclusive. Rendered wrong on purpose.",
	},
	PrismaticSkin = {
		name = "Prismatic",
		kind = "GunSkin",
		rarity = "Secret",
		crateOnly = true,
		color = Color3.fromRGB(255, 170, 255),
		material = Enum.Material.Glass,
		description = "Crate exclusive. Every colour at once.",
	},
	MintAura = {
		name = "Mint Aura",
		kind = "Aura",
		rarity = "Common",
		price = 5000,
		color = Color3.fromRGB(140, 255, 200),
		description = "Fresh.",
	},
	EmberAura = {
		name = "Ember Aura",
		kind = "Aura",
		rarity = "Uncommon",
		price = 9000,
		color = Color3.fromRGB(255, 140, 60),
		description = "Warm sparks that drift upward.",
	},
	FrostAura = {
		name = "Frost Aura",
		kind = "Aura",
		rarity = "Rare",
		price = 18000,
		color = Color3.fromRGB(160, 220, 255),
		description = "A chill in the air around you.",
	},
	VoidAura = {
		name = "Void Aura",
		kind = "Aura",
		rarity = "Legendary",
		crateOnly = true,
		color = Color3.fromRGB(120, 60, 200),
		description = "Crate exclusive. Light bends around you.",
	},
	RoseAura = {
		name = "Mythic Rose",
		kind = "Aura",
		rarity = "Mythic",
		crateOnly = true,
		color = Color3.fromRGB(255, 80, 150),
		description = "Crate exclusive. Petals of pure rot.",
	},
	StarlightAura = {
		name = "Starlight",
		kind = "Aura",
		rarity = "Secret",
		crateOnly = true,
		color = Color3.fromRGB(255, 245, 190),
		description = "Crate exclusive. You are the main character.",
	},

	-- Bundle exclusives. `bundleOnly` items only come from the Robux bundles in GamepassConfig:
	-- never from crates, the shop rotation or the bots' outfits.
	StarterSpark = {
		name = "Starter Spark",
		kind = "GunSkin",
		rarity = "Rare",
		bundleOnly = true,
		color = Color3.fromRGB(110, 240, 150),
		material = Enum.Material.Foil,
		description = "Starter Bundle exclusive. Where every legend starts.",
	},
	ProPlating = {
		name = "Pro Plating",
		kind = "GunSkin",
		rarity = "Legendary",
		bundleOnly = true,
		color = Color3.fromRGB(96, 58, 170),
		material = Enum.Material.Foil,
		description = "Pro Bundle exclusive. Royal purple chrome.",
	},
	ProAura = {
		name = "Pro Aura",
		kind = "Aura",
		rarity = "Legendary",
		bundleOnly = true,
		color = Color3.fromRGB(255, 214, 96),
		description = "Pro Bundle exclusive. Everyone can tell.",
	},

	-- Rank rewards. `rankOnly` items are earned through progression and nothing else: one per prestige,
	-- three for gun mastery, and two sold for Brain Cells. Never in crates, the coin shop, bot outfits or
	-- the Daily Spin (OfKind leaves them out), and never for Robux. What unlocks each is in
	-- ProgressionData.RankCosmetics; ProgressionService grants them.
	PrestigeBronzeSkin = {
		name = "Bronze Rot", kind = "GunSkin", rarity = "Rare", rankOnly = true,
		color = Color3.fromRGB(205, 127, 50), material = Enum.Material.Metal,
		description = "Prestige 1 reward. The first lap is the hardest.",
	},
	PrestigeSilverAura = {
		name = "Silver Rot Aura", kind = "Aura", rarity = "Rare", rankOnly = true,
		color = Color3.fromRGB(200, 206, 216),
		description = "Prestige 2 reward. A cool shine that says you went round again.",
	},
	PrestigeGoldenSkin = {
		name = "Golden Rot", kind = "GunSkin", rarity = "Epic", rankOnly = true,
		color = Color3.fromRGB(255, 196, 64), material = Enum.Material.Foil,
		description = "Prestige 3 reward. Polished by three hundred ranks.",
	},
	PrestigeJadeAura = {
		name = "Jade Rot Aura", kind = "Aura", rarity = "Epic", rankOnly = true,
		color = Color3.fromRGB(80, 220, 140),
		description = "Prestige 4 reward. Calm, green and completely unbothered.",
	},
	PrestigeSapphireSkin = {
		name = "Sapphire Rot", kind = "GunSkin", rarity = "Legendary", rankOnly = true,
		color = Color3.fromRGB(74, 156, 255), material = Enum.Material.Glass,
		description = "Prestige 5 reward. Deep blue and see-through.",
	},
	PrestigeAmethystAura = {
		name = "Amethyst Rot Aura", kind = "Aura", rarity = "Legendary", rankOnly = true,
		color = Color3.fromRGB(186, 104, 255),
		description = "Prestige 6 reward. A violet glow that took six climbs.",
	},
	PrestigeRubySkin = {
		name = "Ruby Rot", kind = "GunSkin", rarity = "Mythic", rankOnly = true,
		color = Color3.fromRGB(236, 64, 96), material = Enum.Material.Neon,
		description = "Prestige 7 reward. It glows like it's angry about it.",
	},
	PrestigeNeonAura = {
		name = "Neon Rot Aura", kind = "Aura", rarity = "Mythic", rankOnly = true,
		color = Color3.fromRGB(255, 90, 200),
		description = "Prestige 8 reward. Visible from orbit.",
	},
	PrestigeDiamondSkin = {
		name = "Diamond Rot", kind = "GunSkin", rarity = "Secret", rankOnly = true,
		color = Color3.fromRGB(150, 236, 255), material = Enum.Material.Ice,
		description = "Prestige 9 reward. Cut from nine hundred ranks of grind.",
	},
	PrestigeEternalAura = {
		name = "Eternal Rot Aura", kind = "Aura", rarity = "Secret", rankOnly = true,
		color = Color3.fromRGB(255, 245, 190),
		description = "Prestige 10 reward. There is nothing after this. You did it.",
	},
	MasteryMastercraftSkin = {
		name = "Mastercraft", kind = "GunSkin", rarity = "Epic", rankOnly = true,
		color = Color3.fromRGB(226, 186, 92), material = Enum.Material.DiamondPlate,
		description = "Mastery reward: Gold mastery on 5 different guns.",
	},
	MasteryDiamondCutSkin = {
		name = "Diamond Cut", kind = "GunSkin", rarity = "Legendary", rankOnly = true,
		color = Color3.fromRGB(170, 225, 255), material = Enum.Material.Glass,
		description = "Mastery reward: Diamond mastery on any gun.",
	},
	MasteryRotmasterSkin = {
		name = "Rotmaster", kind = "GunSkin", rarity = "Mythic", rankOnly = true,
		color = Color3.fromRGB(255, 90, 200), material = Enum.Material.ForceField,
		description = "Mastery reward: Rotmaster, the top tier, on any gun.",
	},
	CellBrainAura = {
		name = "Brain Cell Aura", kind = "Aura", rarity = "Epic", rankOnly = true,
		color = Color3.fromRGB(255, 150, 176),
		description = "Cell Shop: 15,000 Brain Cells. Thinking about it, visibly.",
	},
	CellSynapseSkin = {
		name = "Synapse", kind = "GunSkin", rarity = "Legendary", rankOnly = true,
		color = Color3.fromRGB(120, 255, 235), material = Enum.Material.Neon,
		description = "Cell Shop: 25,000 Brain Cells. Fires faster than you think. (It doesn't.)",
	},

	-- Accessories. Every one has a rarity, which decides which crates can drop it. `crateOnly`
	-- ones have no price at all: the only way to get one is to pull it.

	PartyCone = {
		name = "Party Cone",
		kind = "Accessory",
		rarity = "Common",
		price = 2500,
		anchor = "HeadTop",
		color = PINK,
		description = "It's always someone's birthday somewhere.",
		-- Seven steps, not four. A cone has to be faked out of cylinders here, and the taller each one is
		-- the more the hat reads as a stack of tins; at 0.17 the steps are shallower than the stripes are
		-- wide, so the eye takes the whole thing for a taper. Each step's top and the next one's bottom
		-- share a plane facing opposite ways, which is ordinary contact, not a z-fight.
		parts = {
			column(0.17, 0.9, Vector3.new(0, 0.085, 0), PINK),
			column(0.17, 0.774, Vector3.new(0, 0.255, 0), CYAN),
			column(0.17, 0.646, Vector3.new(0, 0.425, 0), PINK),
			column(0.17, 0.52, Vector3.new(0, 0.595, 0), CYAN),
			column(0.17, 0.394, Vector3.new(0, 0.765, 0), PINK),
			column(0.17, 0.266, Vector3.new(0, 0.935, 0), CYAN),
			column(0.17, 0.14, Vector3.new(0, 1.105, 0), PINK),
			ball(0.3, Vector3.new(0, 1.3, 0), WHITE),
		},
	},
	RotShades = {
		name = "Rot Shades",
		kind = "Accessory",
		rarity = "Common",
		price = 3000,
		anchor = "Face",
		color = BLACK,
		description = "Cool enough to ignore the storm.",
		parts = {
			-- The lenses are turned 12 degrees so they wrap round the face instead of standing off it
			-- like two flat plates -- which also means no face of either lens is parallel to anything
			-- else on the shades, so there is nothing for the z-fight pass to argue with.
			plate(Vector3.new(0.5, 0.26, 0.08), CFrame.new(-0.27, 0.04, -0.05) * CFrame.Angles(0, math.rad(12), 0), BLACK),
			plate(Vector3.new(0.5, 0.26, 0.08), CFrame.new(0.27, 0.04, -0.05) * CFrame.Angles(0, math.rad(-12), 0), BLACK),
			-- The bridge spans the 0.04 between the lenses rather than lapping over them. Overlapping
			-- them put its top a fiftieth under their top and its back a twenty-fifth behind theirs,
			-- both close enough for the pass to shove it; sitting in the gap, no face of it shares a
			-- plane with anything, whatever height it is. Which is also where a nose bridge goes.
			block(Vector3.new(0.036, 0.1, 0.08), Vector3.new(0, 0.11, -0.1), BLACK),
			-- Round arms, and not for looks: a cylinder's only flat faces are its two ends, so an arm has
			-- no top face to line up with the lens top. As blocks they sat 0.06 under it, which sounds
			-- clear of the 0.055 tolerance until you remember the whole accessory is scaled to the
			-- wearer's head -- on the standard R15 rig that is 0.9, the gap measured 0.054, and the pass
			-- nudged both arms. Every flat-face clearance here is really `gap * headScale`, and headScale
			-- runs from 0.6 to 1.8, so the only clearances worth trusting are the ones that don't exist.
			rod(0.62, 0.07, CFrame.new(-0.545, 0.1, 0.26) * CFrame.Angles(0, math.rad(90), 0), BLACK),
			rod(0.62, 0.07, CFrame.new(0.545, 0.1, 0.26) * CFrame.Angles(0, math.rad(90), 0), BLACK),
			-- The glint is a rod lying at an angle: its only flat faces are its two ends, and they point
			-- along the slant, so they are parallel to nothing on the lens behind it. As a thin block it
			-- sat a fiftieth proud of the lens face, in plane with it, and the pass moved it every time.
			rod(0.16, 0.035, CFrame.new(-0.36, 0.1, -0.085) * CFrame.Angles(0, math.rad(12), 0) * CFrame.Angles(0, 0, math.rad(35)),
				WHITE, NEON),
		},
	},
	PropellerBeanie = {
		name = "Propeller Beanie",
		kind = "Accessory",
		rarity = "Common",
		price = 3500,
		anchor = "HeadTop",
		color = RED,
		description = "Generates no lift. Morale only.",
		parts = {
			sphere(Vector3.new(1.26, 0.72, 1.26), Vector3.new(0, 0.02, 0), RED),
			-- A band round the cap, in the second colour, so it reads as a beanie and not a dome.
			column(0.1, 1.2, Vector3.new(0, 0.12, 0), BLUE),
			-- The spindle runs past both blades to 0.76. Ending at 0.59 put its top face a hundredth under
			-- the lower blade's top, in plane with it, so the pass lifted the spindle out of the cap.
			column(0.43, 0.1, Vector3.new(0, 0.545, 0), STEEL),
			-- The two blades sit at different heights. Crossed at the same one, their tops and bottoms
			-- were in one plane over the 0.18 they overlap, and the build's z-fight pass lifted a blade.
			block(Vector3.new(1.1, 0.04, 0.18), Vector3.new(0, 0.58, 0), YELLOW),
			block(Vector3.new(0.18, 0.04, 1.1), Vector3.new(0, 0.66, 0), BLUE),
			ball(0.14, Vector3.new(0, 0.72, 0), STEEL),
		},
	},
	ChefHat = {
		name = "Chef of Rot",
		kind = "Accessory",
		rarity = "Uncommon",
		price = 6000,
		anchor = "HeadTop",
		color = WHITE,
		description = "Tonight's special: whatever you find in chests.",
		-- SmoothPlastic, not Fabric. Fabric on white renders as grey rock: in the first preview
		-- sheet this hat read as a stone mushroom, the same thing that dulled every parachute
		-- canopy until they came off Fabric too. Cloth here is colour and shape, not texture.
		parts = {
			column(0.6, 1.05, Vector3.new(0, 0.3, 0), WHITE),
			sphere(Vector3.new(1.36, 0.7, 1.36), Vector3.new(0, 0.76, 0), WHITE),
			sphere(Vector3.new(0.7, 0.56, 0.7), Vector3.new(0.3, 0.98, 0.16), WHITE),
			sphere(Vector3.new(0.64, 0.5, 0.64), Vector3.new(-0.28, 0.96, -0.2), WHITE),
			-- Two more puffs, so the toque is round from every side rather than lopsided from behind.
			sphere(Vector3.new(0.62, 0.48, 0.62), Vector3.new(0.02, 1, -0.36), WHITE),
			sphere(Vector3.new(0.58, 0.46, 0.58), Vector3.new(-0.04, 0.98, 0.34), WHITE),
		},
	},
	TrafficCone = {
		name = "Traffic Cone",
		kind = "Accessory",
		rarity = "Uncommon",
		price = 7000,
		anchor = "HeadTop",
		color = ORANGE,
		description = "Found on a road. Now it's yours.",
		-- Seven 0.18 steps instead of four tall ones, for the same reason as the party hat, and the white
		-- band is two of them so the stripe keeps its width. The first step starts at 0.10, inside the
		-- 0.12-thick base, so the two meet without their faces lining up.
		parts = {
			block(Vector3.new(1.3, 0.12, 1.3), Vector3.new(0, 0.06, 0), ORANGE),
			column(0.18, 0.95, Vector3.new(0, 0.19, 0), ORANGE),
			column(0.18, 0.84, Vector3.new(0, 0.37, 0), ORANGE),
			column(0.18, 0.73, Vector3.new(0, 0.55, 0), WHITE),
			column(0.18, 0.62, Vector3.new(0, 0.73, 0), WHITE),
			column(0.18, 0.51, Vector3.new(0, 0.91, 0), ORANGE),
			column(0.18, 0.4, Vector3.new(0, 1.09, 0), ORANGE),
			column(0.18, 0.29, Vector3.new(0, 1.27, 0), ORANGE),
		},
	},
	PizzaBackpack = {
		name = "Pizza Backpack",
		kind = "Accessory",
		rarity = "Uncommon",
		price = 8000,
		anchor = "Back",
		color = CHEESE,
		description = "Emergency rations. Do not eat mid-fight.",
		-- The slice is one triangle now. It was five blocks of falling width stacked up to a point, which
		-- from the side was a staircase with 0.34-tall steps -- and a pizza slice is the one shape a
		-- wedge pair gets exactly right. Crust at the wide end, sticking out 0.1 either side.
		parts = concat(
			spike(CFrame.new(0, 0.13, 0.3), 1.7, 1.4, 0.2, CHEESE),
			{
				rod(1.6, 0.32, CFrame.new(0, -0.78, 0.3), CRUST),
				-- Five pepperoni and two basil leaves, all balls, which the pass has no flat faces to
				-- catch on. The slice dropped from nine parts to six when the staircase became one
				-- triangle; at ten the shape is better AND the detail is up, rather than traded away.
				-- Each sits inside the triangle at its own height, where the half-width is
				-- 0.7 * (1 - (y + 0.72) / 1.7).
				ball(0.26, Vector3.new(-0.36, -0.52, 0.42), RED),
				ball(0.26, Vector3.new(0.3, -0.28, 0.42), RED),
				ball(0.24, Vector3.new(0, 0.18, 0.42), RED),
				ball(0.22, Vector3.new(-0.16, -0.05, 0.42), RED),
				ball(0.18, Vector3.new(0.12, 0.42, 0.42), RED),
				ball(0.14, Vector3.new(0.4, -0.6, 0.42), GREEN),
				ball(0.12, Vector3.new(-0.2, 0.06, 0.43), GREEN),
			}
		),
	},
	VikingHelm = {
		name = "Viking Helm",
		kind = "Accessory",
		rarity = "Rare",
		price = 15000,
		anchor = "HeadTop",
		color = STEEL,
		description = "Horns sold separately. Just kidding, they're included.",
		parts = {
			sphere(Vector3.new(1.32, 0.84, 1.32), Vector3.new(0, 0, 0), STEEL, Enum.Material.Metal),
			column(0.14, 1.36, Vector3.new(0, 0.02, 0), BRONZE, Enum.Material.Metal),
			-- Each horn is two segments on one axis, 0.26 thick at the helm and 0.18 at the tip, so it
			-- tapers instead of being a pipe with a ball on the end. They meet end to end, where their
			-- faces point at each other rather than the same way, so the pass has nothing to resolve.
			rod(0.38, 0.26, CFrame.new(-0.78, 0.32, 0) * CFrame.Angles(0, 0, math.rad(-35)) * CFrame.new(0.17, 0, 0), IVORY),
			rod(0.38, 0.18, CFrame.new(-0.78, 0.32, 0) * CFrame.Angles(0, 0, math.rad(-35)) * CFrame.new(-0.21, 0, 0), IVORY),
			rod(0.38, 0.26, CFrame.new(0.78, 0.32, 0) * CFrame.Angles(0, 0, math.rad(35)) * CFrame.new(-0.17, 0, 0), IVORY),
			rod(0.38, 0.18, CFrame.new(0.78, 0.32, 0) * CFrame.Angles(0, 0, math.rad(35)) * CFrame.new(0.21, 0, 0), IVORY),
			ball(0.16, Vector3.new(-1.07, 0.53, 0), IVORY),
			ball(0.16, Vector3.new(1.07, 0.53, 0), IVORY),
		},
	},
	ExposedBrain = {
		name = "Exposed Brain",
		kind = "Accessory",
		rarity = "Rare",
		price = 18000,
		anchor = "HeadTop",
		color = BRAIN,
		description = "Full brainrot, now visible from the outside.",
		parts = {
			sphere(Vector3.new(1.16, 0.78, 1.3), Vector3.new(0, 0.18, 0), BRAIN),
			block(Vector3.new(0.06, 0.1, 1.16), Vector3.new(0, 0.55, 0), BRAIN_DARK),
			sphere(Vector3.new(0.52, 0.32, 0.56), Vector3.new(-0.3, 0.44, -0.3), BRAIN),
			sphere(Vector3.new(0.52, 0.32, 0.56), Vector3.new(0.3, 0.44, -0.3), BRAIN),
			sphere(Vector3.new(0.52, 0.32, 0.56), Vector3.new(-0.3, 0.44, 0.3), BRAIN),
			sphere(Vector3.new(0.52, 0.32, 0.56), Vector3.new(0.3, 0.44, 0.3), BRAIN),
		},
	},
	RubberDuck = {
		name = "Duck Buddy",
		kind = "Accessory",
		rarity = "Rare",
		price = 16000,
		anchor = "HeadTop",
		color = YELLOW,
		description = "Has seen things. Won't talk about them.",
		parts = concat(
			{
				sphere(Vector3.new(0.82, 0.56, 1.0), Vector3.new(0, 0.26, 0.05), YELLOW),
				ball(0.52, Vector3.new(0, 0.72, -0.3), YELLOW),
				block(Vector3.new(0.3, 0.1, 0.26), Vector3.new(0, 0.68, -0.62), ORANGE),
				ball(0.1, Vector3.new(-0.14, 0.8, -0.52), BLACK),
				ball(0.1, Vector3.new(0.14, 0.8, -0.52), BLACK),
			},
			-- A tail that comes to a point and cocks back over the body, rather than a cube stuck on the
			-- end. Rooted at 0.44 so its wide base is inside the body and only the point shows.
			spike(CFrame.new(0, 0.44, 0.46) * CFrame.Angles(math.rad(30), 0, 0), 0.36, 0.3, 0.18, YELLOW)
		),
	},
	ToasterPack = {
		name = "Toaster Pack",
		kind = "Accessory",
		rarity = "Epic",
		price = 35000,
		anchor = "Back",
		color = STEEL,
		description = "Always ready. Always toasting.",
		parts = {
			block(Vector3.new(1.2, 1.0, 0.7), Vector3.new(0, 0.05, 0.38), STEEL, Enum.Material.Metal),
			-- Raised lips standing 0.1 above the toaster's top, not plates laid level with it, and 0.24
			-- wide around 0.1-wide toast. Every face of a lip clears every face of the body and of the
			-- toast in it by more than the pass's tolerance -- at 0.16 wide the lip's sides sat three
			-- hundredths off the toast's, which is exactly the gap it reacts to.
			block(Vector3.new(0.24, 0.25, 0.54), Vector3.new(-0.26, 0.525, 0.38), BLACK),
			block(Vector3.new(0.24, 0.25, 0.54), Vector3.new(0.26, 0.525, 0.38), BLACK),
			block(Vector3.new(0.1, 0.5, 0.34), Vector3.new(-0.26, 0.76, 0.38), TOAST),
			block(Vector3.new(0.1, 0.5, 0.34), Vector3.new(0.26, 0.76, 0.38), TOAST),
			block(Vector3.new(0.1, 0.26, 0.12), Vector3.new(0.64, 0.1, 0.38), BLACK),
			-- A browning dial standing off the side, so there's something to look at besides a box.
			rod(0.06, 0.26, CFrame.new(0.64, -0.24, 0.38), BLACK),
		},
	},
	CrownOfRot = {
		name = "Crown of Rot",
		kind = "Accessory",
		rarity = "Epic",
		price = 40000,
		anchor = "HeadTop",
		color = GOLD,
		description = "Heavy is the head. Mostly because of the brainrot.",
		-- A band with points rising out of it, and the rot showing through the middle.
		--
		-- It used to be two rings of blocks: ten 0.36-wide teeth on a 0.54 radius, where the ring clears
		-- only 0.318 at their inner corners, so every neighbouring pair overlapped with their tops
		-- and bottoms in one plane (pieces turn about Y, which never turns those faces). AccessoryService
		-- runs the z-fight pass over a worn accessory, and it resolved those ten coplanar tops by
		-- stepping each tooth up in turn: 18 pieces moved, the worst by 0.60, so every player who wore
		-- it got a spiral staircase of teeth from 0.32 to 0.92 tall. Narrowing them to 0.32 stopped that,
		-- but it was still a ring of blocks with a second ring of blocks behind it.
		--
		-- Now: one cylinder for the band, so its outside is actually round rather than faceted; eight
		-- points, each a pair of wedges meeting at its centre line, sunk 0.12 into the band so nothing
		-- rests on a seam; and a brain dome filling the middle, which a solid gold lid was never going to
		-- sell as the Crown of Rot. 0.34 wide on a 0.51 radius leaves each point 0.016 clear of its
		-- neighbours at the inner corners, where they come closest.
		parts = concat(
			{ column(0.2, 1.02, Vector3.new(0, 0.1, 0), GOLD, Enum.Material.Foil) },
			points(8, 0.51, 0.08, 0.44, 0.34, 0.12, GOLD, Enum.Material.Foil),
			{
				-- Balls and meshed spheres have no flat faces for the pass to catch on, so the gems and
				-- the dome can sit wherever they look right.
				sphere(Vector3.new(0.86, 0.26, 0.86), Vector3.new(0, 0.2, 0), BRAIN),
				-- Two creases crossing and five gems, not one and three: 25 pieces against the 23 of
				-- the two-ring crown this replaced. The creases are cylinders laid at right angles, so
				-- the only flat faces either has -- its two ends -- are never parallel to the other's.
				rod(0.44, 0.07, CFrame.new(0, 0.31, 0), BRAIN_DARK),
				rod(0.44, 0.07, CFrame.new(0, 0.31, 0) * CFrame.Angles(0, math.pi / 2, 0), BRAIN_DARK),
				ball(0.17, Vector3.new(0, 0.27, -0.55), PURPLE, NEON),
				ball(0.14, Vector3.new(0.55, 0.27, 0), GREEN, NEON),
				ball(0.14, Vector3.new(-0.55, 0.27, 0), GREEN, NEON),
				ball(0.12, Vector3.new(0.389, 0.27, -0.389), GREEN, NEON),
				ball(0.12, Vector3.new(-0.389, 0.27, -0.389), GREEN, NEON),
			}
		),
	},
	GoldenHalo = {
		name = "Golden Halo",
		kind = "Accessory",
		rarity = "Legendary",
		crateOnly = true,
		anchor = "HeadTop",
		color = GOLD,
		description = "Crate exclusive. You didn't earn it, you pulled it.",
		-- Fourteen segments 0.27 wide on a 0.56 radius overlapped: the ring clears only 0.233 at their
		-- inner corners, where they come closest, and they had their tops and bottoms in one plane, so
		-- the z-fight pass stepped the halo into a spiral on every player who wore it. Sixteen of 0.20
		-- on the old 0.1-deep ring clear by only 0.003 -- the limit is 2 * (radius - depth / 2) *
		-- tan(pi / count), so the way to buy margin is a thinner ring, not a shorter segment: at 0.05
		-- deep the gap is 0.013, and a slimmer halo is the better-looking one anyway. tools/verify.py
		-- does this arithmetic on every ring in this file.
		parts = ring(16, 0.56, 0.62, Vector3.new(0.2, 0.07, 0.05), GOLD, NEON),
	},
	GalaxyBrain = {
		name = "Galaxy Brain",
		kind = "Accessory",
		rarity = "Legendary",
		crateOnly = true,
		anchor = "HeadTop",
		color = PURPLE,
		description = "Crate exclusive. Thinks in eleven dimensions, still misses shots.",
		parts = concat(
			{
				sphere(Vector3.new(1.2, 0.82, 1.34), Vector3.new(0, 0.22, 0), PURPLE, NEON),
				block(Vector3.new(0.07, 0.1, 1.2), Vector3.new(0, 0.62, 0), Color3.fromRGB(70, 30, 130)),
			},
			ring(16, 1.0, 0.3, Vector3.new(0.34, 0.05, 0.08), CYAN, NEON, CFrame.Angles(math.rad(18), 0, math.rad(8)))
		),
	},

	BonkStick = {
		name = "Bonk Stick",
		kind = "Accessory",
		rarity = "Common",
		price = 3200,
		anchor = "HeadTop",
		color = WOOD,
		description = "Sahur's own. Strapped on so both hands stay free for more bonking.",
		-- Tung Tung Tung Sahur carries the bat; this is the bat, worn. Two collinear cylinders meeting
		-- end to end make the taper (barrel into handle) -- their touching faces point at each other,
		-- which is contact rather than a fight -- and the strap is a 12-piece band, each 0.22 wide where
		-- the ring allows 0.236 at the inner corners.
		--
		-- The heights matter and were wrong first time. The strap sits at 0.04 so its underside is 0.01
		-- INSIDE the head, and the bat at 0.31 so the barrel reaches down to 0.075, under the strap's
		-- 0.09 top. At 0.08 and 0.44 the whole thing touched nothing at all -- a bat floating over a
		-- strap floating over the head, 15 disconnected clusters. The probe's loose check never caught
		-- it because every piece had a neighbour; none of them had the wearer.
		parts = concat(
			ring(12, 0.5, 0.04, Vector3.new(0.22, 0.1, 0.12), BLACK),
			{
				rod(0.86, 0.34, CFrame.new(-0.12, 0.31, 0) * CFrame.Angles(0, 0, math.rad(9)), WOOD),
				rod(0.54, 0.19, CFrame.new(0.58, 0.42, 0) * CFrame.Angles(0, 0, math.rad(9)), WOOD),
				ball(0.25, Vector3.new(0.86, 0.47, 0), WOOD),
				-- On the skin, not in the wood: radial 0.20 against the barrel's 0.17 leaves each stud 0.08
				-- proud. Two of these three were buried inside the barrel and invisible.
				ball(0.1, Vector3.new(-0.3, 0.47, 0.08), STEEL),
				ball(0.1, Vector3.new(-0.02, 0.499, -0.1), STEEL),
				ball(0.1, Vector3.new(0.188, 0.486, 0.155), STEEL),
			}
		),
	},
	StinkoSock = {
		name = "Sockolino's Sock",
		kind = "Accessory",
		rarity = "Uncommon",
		price = 6500,
		anchor = "HeadTop",
		color = SOCK,
		description = "Worn on the head, which is the only place left. The cloud comes with it.",
		-- The sock is spheres, which have no flat faces at all, so the only pieces the pass can see are
		-- the cuff and the two stripes -- and they are 0.15 and 0.2 apart in Y, clear of 0.055 even on
		-- the smallest head, where every authored gap shrinks to 0.6 of itself.
		parts = {
			sphere(Vector3.new(1.24, 0.66, 1.24), Vector3.new(0, 0.22, 0), SOCK),
			sphere(Vector3.new(0.62, 0.46, 0.78), Vector3.new(0, 0.42, -0.52), SOCK),
			column(0.12, 1.28, Vector3.new(0, 0.06, 0), WHITE),
			column(0.06, 1.24, Vector3.new(0, 0.24, 0), STINK),
			column(0.06, 1.18, Vector3.new(0, 0.44, 0), STINK),
			-- A chain, not a scatter: each puff's centre is closer to the next than the sum of their radii,
			-- and the first overlaps the sock itself (its underside reaches 0.45 where the sock's surface
			-- at that point is 0.465). Spread out as they first were, all six touched nothing whatever --
			-- six balls hanging in the air over a hat -- which the probe reports as loose and a player
			-- reads as a bug. Top of the cloud is 1.24 over the head, inside the 1.43 ceiling.
			ball(0.42, Vector3.new(0.34, 0.66, 0.24), STINK, Enum.Material.Snow),
			ball(0.34, Vector3.new(0.12, 0.8, 0.02), STINK, Enum.Material.Snow),
			ball(0.3, Vector3.new(-0.1, 0.9, 0.14), STINK, Enum.Material.Snow),
			ball(0.26, Vector3.new(0.02, 0.99, 0.02), STINK, Enum.Material.Snow),
			ball(0.22, Vector3.new(0.18, 1.08, 0.1), STINK, Enum.Material.Snow),
			ball(0.18, Vector3.new(0.06, 1.15, -0.02), STINK, Enum.Material.Snow),
		},
	},
	NoodleBowl = {
		name = "Wobblo's Bowl",
		kind = "Accessory",
		rarity = "Uncommon",
		price = 7500,
		anchor = "HeadTop",
		color = BROTH,
		description = "Noodlo Wobblo wore it first. He has not asked for it back.",
		-- Eight noodles hang at eight different angles, so no two rods put their end faces in one plane,
		-- and the bowl above them is a sphere with none of its own.
		parts = concat(
			{
				sphere(Vector3.new(1.3, 0.64, 1.3), Vector3.new(0, 0.3, 0), BROTH),
				column(0.1, 1.36, Vector3.new(0, 0.58, 0), CRUST),
				-- Dropped until they rest in the bowl: at 0.92 and 0.90 both chopsticks hung clear of
				-- everything, which the probe reports as loose. Their low ends now reach 0.622 and 0.625,
				-- inside the rim's 0.63 top. A cylinder's flank carries no face, so resting one on the rim
				-- cannot start a fight.
				rod(0.9, 0.07, CFrame.new(0.16, 0.78, -0.1) * CFrame.Angles(0, 0, math.rad(16)), WOOD),
				rod(0.9, 0.07, CFrame.new(0.2, 0.84, 0.12) * CFrame.Angles(0, 0, math.rad(24)), WOOD),
			},
			(function()
				local strands = {}
				for index = 0, 7 do
					local angle = index / 8 * math.pi * 2
					-- Keep every lean more than 1.82 degrees off 90. Index 5 lands on 87, and that strand's end
					-- disc overlaps the rim's top face by 0.19 while sitting only 0.06 under it -- the angle is
					-- the ONLY thing keeping the pass off it. Base 63.2, or step 5.24, would put it in the window.
					local lean = math.rad(62 + index * 5)
					table.insert(strands, rod(0.54 + index % 3 * 0.12, 0.1,
						CFrame.Angles(0, angle, 0) * CFrame.new(0, 0.18, 0.56) * CFrame.Angles(0, 0, lean), NOODLE))
				end
				return strands
			end)()
		),
	},
	CactinoCrown = {
		name = "Pokko's Cactus",
		kind = "Accessory",
		rarity = "Rare",
		price = 14000,
		anchor = "HeadTop",
		color = CACTUS,
		description = "Needles included. Pokko does not consider that a warning.",
		-- Both arms stop clear of the stem's 1.0 top face: the left at 0.85, the right at 0.87. The
		-- right one was at 0.96 -- 0.04 under the stem's top, well inside the pass's reach -- and was
		-- saved only by 0.144 of plan separation that nothing recorded. Both are +Y cylinder discs, so
		-- only height and plan separation keep them apart.
		-- The needles are rods pointing out radially, so their ends face along the spine they sit on and
		-- are parallel to nothing.
		parts = concat(
			{
				column(1, 0.46, Vector3.new(0, 0.5, 0), CACTUS),
				rod(0.34, 0.2, CFrame.new(-0.3, 0.42, 0), CACTUS),
				column(0.44, 0.2, Vector3.new(-0.44, 0.63, 0), CACTUS),
				rod(0.3, 0.18, CFrame.new(0.28, 0.6, 0), CACTUS),
				column(0.36, 0.18, Vector3.new(0.4, 0.69, 0), CACTUS),
				ball(0.17, Vector3.new(0, 1.06, 0), BLOOM),
				ball(0.13, Vector3.new(0.13, 1.04, 0.05), BLOOM),
				ball(0.13, Vector3.new(-0.11, 1.05, -0.08), BLOOM),
				ball(0.12, Vector3.new(0.04, 1.02, -0.13), BLOOM),
				ball(0.12, Vector3.new(-0.06, 1.03, 0.12), BLOOM),
				ball(0.09, Vector3.new(0, 1.14, 0), YELLOW),
			},
			(function()
				local spines = {}
				for index = 0, 9 do
					local angle = index / 10 * math.pi * 2 + index * 0.3
					local height = 0.22 + index % 5 * 0.16
					table.insert(spines, rod(0.16, 0.045,
						CFrame.new(0, height, 0) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, 0.24)
							* CFrame.Angles(0, math.pi / 2, 0) * CFrame.Angles(0, 0, math.rad(18)), IVORY))
				end
				return spines
			end)()
		),
	},
	CrocodiloWings = {
		name = "Bombardiro Wings",
		kind = "Accessory",
		rarity = "Epic",
		price = 32000,
		anchor = "Back",
		color = CROC,
		description = "Air Drop, without the drop. Or the air. They are decorative.",
		-- Each wing is a wedge pair, which is the one shape that gives a real swept point; the pack
		-- between them is a sphere with no faces.
		--
		-- The struts are at 10 degrees, not the 6 they read best at. spike() rolls each wing 96 degrees,
		-- so a wedge's bottom-face normal points 6 degrees off horizontal -- and a cylinder's only faces
		-- are its two end discs, whose normal is its own axis. At 6 those two normals were IDENTICAL
		-- (96 - 90 = 6 exactly): 0.038 apart with 0.096 of overlap, so the z-fight pass moved both struts
		-- on every head under 1.75 studs, which is every standard rig. At 10 the axis sits 4 degrees off
		-- the wedge normal, and the pass calls anything within 1.81 degrees parallel -- better than double
		-- the margin. 8 would have left 0.19 of a degree.
		parts = concat(
			spike(CFrame.new(-0.78, 0.18, 0.32) * CFrame.Angles(0, 0, math.rad(96)), 1.04, 0.72, 0.14, CROC),
			spike(CFrame.new(0.78, 0.18, 0.32) * CFrame.Angles(0, 0, math.rad(-96)), 1.04, 0.72, 0.14, CROC),
			{
				sphere(Vector3.new(0.74, 0.86, 0.44), Vector3.new(0, 0.1, 0.3), CROC_DARK),
				rod(0.86, 0.09, CFrame.new(-0.74, 0.3, 0.33) * CFrame.Angles(0, 0, math.rad(10)), CROC_DARK),
				rod(0.86, 0.09, CFrame.new(0.74, 0.3, 0.33) * CFrame.Angles(0, 0, math.rad(-10)), CROC_DARK),
				rod(0.66, 0.08, CFrame.new(-0.66, -0.06, 0.33) * CFrame.Angles(0, 0, math.rad(-14)), CROC_DARK),
				rod(0.66, 0.08, CFrame.new(0.66, -0.06, 0.33) * CFrame.Angles(0, 0, math.rad(14)), CROC_DARK),
				ball(0.2, Vector3.new(0, 0.62, 0.34), STEEL),
				ball(0.16, Vector3.new(0, -0.42, 0.34), STEEL),
			}
		),
	},
	StinkoCloud = {
		name = "Stinko Cloud",
		kind = "Aura",
		rarity = "Uncommon",
		price = 8000,
		color = STINK,
		description = "Sockolino's own weather. It follows you and it sinks.",
		-- The first aura that is a shape rather than a hue: heavy puffs, slow, thrown wide and falling,
		-- because a stink cloud that rises is steam. rise is negative and drag holds them near the feet.
		aura = {
			lightRange = 8,
			lightBrightness = 0.7,
			layers = {
				{ rate = 9, size = 0.85, endSize = 0.3, speed = { 0.6, 1.2 }, rise = -1.4,
					lifetime = { 1.4, 2.2 }, transparency = 0.45, spread = 70, drag = 1.2 },
			},
		},
	},
	PokkoNeedles = {
		name = "Pokko's Needles",
		kind = "Aura",
		rarity = "Rare",
		price = 13000,
		color = IVORY,
		description = "Needle Shot, permanently. Cactino Pokko does not aim it.",
		-- Fast, small, tight and spinning: the opposite end of the same contract. A 35 degree spread
		-- reads as a spit rather than a halo, and the short life keeps them close.
		--
		-- rise is -28, not the -9 it was: at -9 a needle thrown at 6-9 studs/s needs 0.67-1.0 s to turn
		-- around and only lives 0.35-0.6, so every one of them RISES for its whole life. The sign alone
		-- was enough to flip CosmeticPreview's specks to sinking, so the shop picture disagreed with the
		-- game. At -28 the slowest needle peaks at 0.21 s and spends the rest of its life falling.
		aura = {
			lightColor = CACTUS,
			lightRange = 7,
			lightBrightness = 0.9,
			layers = {
				{ rate = 26, size = 0.22, endSize = 0.05, speed = { 6, 9 }, rise = -28,
					lifetime = { 0.35, 0.6 }, transparency = 0.1, spread = 35, spin = 180 },
			},
		},
	},
	WobbloSteam = {
		name = "Wobblo Steam",
		kind = "Aura",
		rarity = "Common",
		price = 4000,
		color = NOODLE,
		description = "Still hot. Noodlo Wobblo insists it is always still hot.",
		-- Two layers: wide slow wisps, and a few darker flecks of broth riding up through them.
		aura = {
			lightRange = 6,
			lightBrightness = 0.6,
			layers = {
				{ rate = 10, size = 0.6, endSize = 0.15, speed = { 0.8, 1.6 }, rise = 3.2,
					lifetime = { 1.2, 2 }, transparency = 0.55, spread = 120 },
				{ rate = 5, size = 0.15, color = BROTH, speed = { 1.5, 2.5 }, rise = 2.4,
					lifetime = { 0.8, 1.4 }, transparency = 0.3, spread = 60 },
			},
		},
	},
	BombardiroContrail = {
		name = "Bombardiro Contrail",
		kind = "Aura",
		rarity = "Epic",
		price = 28000,
		color = STEEL,
		description = "Air Drop leaves a line in the sky. This is the line, minus the sky.",
		-- A trail that hangs where you were, with green sparks cutting down through it. `fade` gives the
		-- trail a second colour at the end of its life, which is the one thing a single emitter could
		-- never do when an aura was one Color3.
		--
		-- Two numbers are deliberate. The sparks' rise is -20 so a 7 studs/s spark turns over at 0.35 s
		-- and falls for the rest of its 0.4-0.8 life -- at -2 they rose the whole way and the word
		-- 'cutting down' was a lie about my own design. And the trail's rate is 12, not 20: at 20 with
		-- a 1.6-2.4 life this carried about 2.8x the live particles of any aura that shipped, on an
		-- Epic nobody had profiled. It should be the densest; it should not be triple.
		aura = {
			lightColor = CROC,
			lightRange = 11,
			lightBrightness = 1,
			layers = {
				{ rate = 12, size = 0.7, endSize = 0.2, speed = { 0.5, 1 }, rise = 0.6, drag = 0.6,
					lifetime = { 1.6, 2.4 }, transparency = 0.5, spread = 40, fade = WHITE },
				{ rate = 8, size = 0.18, color = CROC, speed = { 4, 7 }, rise = -20,
					lifetime = { 0.4, 0.8 }, transparency = 0.15, spread = 55, spin = 120 },
			},
		},
	},
	GummoBubbles = {
		name = "Gummo Bubbles",
		kind = "Aura",
		rarity = "Rare",
		price = 14000,
		color = PINK,
		description = "Bubblo Gummo blows one every few seconds. They all pop. He keeps going.",
		-- Big slow bubbles fading pale, and small fast pops underneath them.
		aura = {
			lightRange = 9,
			lightBrightness = 0.9,
			layers = {
				{ rate = 7, size = 0.9, endSize = 0.5, speed = { 1, 2 }, rise = 1.8,
					lifetime = { 1.8, 2.6 }, transparency = 0.55, spread = 90, fade = WHITE },
				{ rate = 12, size = 0.12, speed = { 3, 5 }, rise = 0.5,
					lifetime = { 0.3, 0.5 }, transparency = 0.25, spread = 160 },
			},
		},
	},
	-- Parachutes: the canopy that opens over you on the drop-in and with the Rot Glider. Each id is a
	-- design in Shared/ParachuteModels, which builds it; `color` is its main colour for icons and
	-- crate reveals. Common to Epic rotate through the shop; Legendary and up only come from the
	-- Parachute Crate. With none equipped you get the default Rot Glider canopy.

	PatchworkChute = {
		name = "Patchwork Sheet",
		kind = "Parachute",
		rarity = "Common",
		price = 3000,
		color = Color3.fromRGB(78, 142, 198),
		description = "Somebody's bedsheet. Holds air. Mostly.",
	},
	ConeChute = {
		name = "Traffic Cone",
		kind = "Parachute",
		rarity = "Common",
		price = 3500,
		color = Color3.fromRGB(255, 118, 26),
		description = "Landing zone: under construction.",
	},
	GinghamChute = {
		name = "Picnic Gingham",
		kind = "Parachute",
		rarity = "Common",
		price = 4000,
		color = Color3.fromRGB(206, 44, 50),
		description = "Drops in, lays out, eats your loot.",
	},
	MelonChute = {
		name = "Watermelon",
		kind = "Parachute",
		rarity = "Uncommon",
		price = 7000,
		color = Color3.fromRGB(238, 78, 96),
		description = "One slice, fifty seeds, zero regrets.",
	},
	PizzaChute = {
		name = "Pizza Glider",
		kind = "Parachute",
		rarity = "Uncommon",
		price = 8000,
		color = Color3.fromRGB(252, 204, 84),
		description = "Delivered hot, straight from the sky.",
	},
	RainbowChute = {
		name = "Rainbow Arc",
		kind = "Parachute",
		rarity = "Uncommon",
		price = 9000,
		color = Color3.fromRGB(96, 196, 72),
		description = "The gold is wherever you land.",
	},
	RoundChute = {
		name = "Round Classic",
		kind = "Parachute",
		rarity = "Rare",
		price = 14000,
		color = Color3.fromRGB(214, 44, 44),
		description = "Red, white and old school. Falls with dignity.",
	},
	SharkChute = {
		name = "Sharkwing",
		kind = "Parachute",
		rarity = "Rare",
		price = 15000,
		color = Color3.fromRGB(92, 112, 134),
		description = "Smells blood from 1,000 studs up.",
	},
	BomberChute = {
		name = "Bomber Wing",
		kind = "Parachute",
		rarity = "Rare",
		price = 17000,
		color = Color3.fromRGB(96, 104, 60),
		description = "Air-dropped with military precision. Allegedly.",
	},
	CandyChute = {
		name = "Cotton Candy Cloud",
		kind = "Parachute",
		rarity = "Epic",
		price = 32000,
		color = Color3.fromRGB(255, 164, 212),
		description = "Sticky, fluffy, surprisingly aerodynamic.",
	},
	DragonChute = {
		name = "Dragonwing",
		kind = "Parachute",
		rarity = "Epic",
		price = 38000,
		color = Color3.fromRGB(150, 24, 32),
		description = "Bones, claws and a crimson membrane. Here be dropping.",
	},
	SahurChute = {
		name = "Golden Sahur",
		kind = "Parachute",
		rarity = "Legendary",
		crateOnly = true,
		color = Color3.fromRGB(255, 198, 66),
		description = "Crate exclusive. Gold, velvet, rubies, and the bats, crossed.",
	},
	PhoenixChute = {
		name = "Phoenix Plume",
		kind = "Parachute",
		rarity = "Legendary",
		crateOnly = true,
		color = Color3.fromRGB(242, 106, 22),
		description = "Crate exclusive. Rise from the ashes, then land on them.",
	},
	StormChute = {
		name = "Stormcaller",
		kind = "Parachute",
		rarity = "Mythic",
		crateOnly = true,
		color = Color3.fromRGB(146, 152, 166),
		description = "Crate exclusive. Brings its own weather.",
	},
	MantaChute = {
		name = "Galaxy Manta",
		kind = "Parachute",
		rarity = "Secret",
		crateOnly = true,
		color = Color3.fromRGB(36, 112, 134),
		description = "Crate exclusive. Swims through space. Glides through lobbies.",
	},

	-- Kill animations (#24, 2026-09-24): what plays where a body falls when the owner gets the
	-- kill. KillAnimService fires the equipped one to every client and KillAnimFxClient builds it,
	-- keyed by these ids, with a cap on parts and particles and a lifetime under three seconds.
	-- Priced inside the same rarity bands as the skins, auras and parachutes. None is a crate
	-- exclusive, because no crate draws this kind yet: a crateOnly one could never be had.
	KillConfettiPop = {
		name = "Party Popper",
		kind = "KillAnimation",
		rarity = "Common",
		price = 3000,
		color = Color3.fromRGB(255, 120, 190),
		description = "Pop. Streamers. Nobody asked.",
	},
	KillRotPuddle = {
		name = "Rot Puddle",
		kind = "KillAnimation",
		rarity = "Common",
		price = 3500,
		color = Color3.fromRGB(150, 196, 96),
		description = "They melt into a bubbling green puddle. Mind your shoes.",
	},
	KillBigBonk = {
		name = "Big Bonk",
		kind = "KillAnimation",
		rarity = "Uncommon",
		price = 7000,
		color = Color3.fromRGB(168, 122, 72),
		description = "A bat the size of a lamppost comes down from the sky. Bonk.",
	},
	KillRotGhost = {
		name = "Rot Ghost",
		kind = "KillAnimation",
		rarity = "Uncommon",
		price = 8000,
		color = Color3.fromRGB(214, 236, 255),
		description = "Their ghost floats up, waves, and fades. Very polite.",
	},
	KillDrumStamp = {
		name = "Drum Stamp",
		kind = "KillAnimation",
		rarity = "Rare",
		price = 15000,
		color = Color3.fromRGB(206, 150, 80),
		description = "A spinning war drum slams down and stamps a ring in the ground.",
	},
	KillCoinFountain = {
		name = "Coin Fountain",
		kind = "KillAnimation",
		rarity = "Rare",
		price = 16000,
		color = Color3.fromRGB(255, 196, 64),
		description = "A fountain of SahurCoins. Sadly not real ones.",
	},
	KillBrainBlast = {
		name = "Brain Blast",
		kind = "KillAnimation",
		rarity = "Epic",
		price = 30000,
		color = Color3.fromRGB(255, 150, 176),
		description = "A giant brain swells, wobbles and pops in a pink shockwave.",
	},
}

for id, item in pairs(CosmeticData.Items) do
	item.id = id
end

function CosmeticData.Get(id)
	return CosmeticData.Items[id]
end

-- Sorted ids of one kind. Bundle exclusives and rank rewards are never included, since nothing but a
-- bundle or progression hands them out; `excludeCrateOnly` also leaves out the crate exclusives.
function CosmeticData.OfKind(kind, excludeCrateOnly)
	local ids = {}
	for id, item in pairs(CosmeticData.Items) do
		if item.kind == kind and not item.bundleOnly and not item.rankOnly and not (excludeCrateOnly and item.crateOnly) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

return CosmeticData
