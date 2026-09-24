-- Crates and chests, built from parts, shared by everything that shows one:
--
--   Crate   the loot crates you open — the menu's opening animation, the Crate Altar's shelf,
--           the idle crate on the altar between pulls. A dark capsule with rounded metal edges,
--           tier-coloured corner caps and glowing seams, a badge on the front, a domed lid with
--           a neon band, and a gold padlock. Every part that takes the tier colour is returned
--           in `tinted`, so the opening animation can walk it up the rarity ladder.
--   Chest   the chests on the map, a different thing altogether: a banded wooden treasure
--           chest with brass straps and corners, a keyhole plate, a curved lid, and a warm glow
--           waiting under it. The lid is a child named "Lid", which LootFxClient swings open.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Rarity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Rarity"))
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local CrateModels = {}

local V = Vector3.new
local SHELL = Color3.fromRGB(38, 42, 56)
local SHELL_DARK = Color3.fromRGB(26, 28, 38)
local STEEL = Color3.fromRGB(168, 172, 182)
local GOLD = Color3.fromRGB(255, 200, 60)
local WOOD = Color3.fromRGB(104, 68, 40)
local WOOD_DARK = Color3.fromRGB(74, 48, 30)
local BRASS = Color3.fromRGB(214, 170, 80)
local GLOW = Color3.fromRGB(255, 214, 120)

local function newPart(parent, name, size, cframe, color, material, shape, transparency)
	local part = Instance.new("Part")
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- A wedge through the same path as a part, for the peaked lids.
local function newWedge(parent, name, size, cframe, color, material)
	local part = Instance.new("WedgePart")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = parent
	return part
end

-- What makes each crate read as itself at the size of a card (72 px) — beyond its colour, which was
-- all that told them apart. Each is a silhouette a thumb can pick out: the lid's shape (flat, a
-- dome, a peaked roof, a crown of points round a dome), studs down the corner columns, a ring of
-- lights hanging over the lid, a glass shell with a glowing core, a ribbon and bow for the cosmetic
-- crates, gold fittings for the top tiers, and what the badge says. A tier not listed gets the
-- dome (the old look).
local STYLES = {
	Common = { lid = "flat" },
	Uncommon = { lid = "dome" },
	Rare = { lid = "dome", studs = true },
	Epic = { lid = "peak", studs = true },
	Legendary = { lid = "crown", studs = true, gold = true },
	Mythic = { lid = "peak", halo = true, studs = true, metal = true },
	Secret = { lid = "dome", glass = true, core = true, glyph = "?" },
	Super = { lid = "crown", halo = true, gold = true },
	Style = { lid = "flat", bow = true, cloth = true },
	DeluxeStyle = { lid = "flat", bow = true, cloth = true, studs = true },
	PrestigeStyle = { lid = "flat", bow = true, cloth = true, gold = true, halo = true },
}
CrateModels.Styles = STYLES

-- A crate for `tier` (a CrateData tier name; the colour comes from Rarity, or `options.color`),
-- centred on the origin with its bottom at y = 0, facing -Z. options: scale, color.
-- Returns model, lid, lidBand, tinted.
function CrateModels.Crate(tier, options)
	options = options or {}
	local scale = options.scale or 1
	local color = options.color or (tier and Rarity.Color(tier)) or GOLD
	local style = (tier and STYLES[tier]) or STYLES.Uncommon
	local fittingColor = style.gold and GOLD or STEEL
	local fittingMaterial = style.gold and Enum.Material.Foil or Enum.Material.Metal
	local model = Instance.new("Model")
	model.Name = "Crate"
	model:SetAttribute("CrateTier", tier or "")
	local tinted = {}

	local function piece(name, size, cframe, pieceColor, material, shape, transparency)
		local frame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
		return newPart(model, name, size * scale, CFrame.new(frame.Position * scale) * frame.Rotation, pieceColor, material, shape, transparency)
	end

	-- The shell: a box with its vertical edges rounded off by columns and a plinth underneath.
	-- Everything layered on the front is stepped a clear 0.06 out from what's behind it (body
	-- 1.50, bands 1.56, seam 1.62, badge ring 1.70, badge 1.80, keyhole 1.86), so no two faces
	-- lie flush.
	-- The shell stands clear of the plinth and the corner columns: its underside used to be 0.04
	-- over the plinth's, which is inside the z-fight pass's reach, and the pass answered by growing
	-- the shell and shifting all 27 parts of the crate.
	-- The shell: dark plastic; glass with the glow inside for the Secret crate; cloth in the crate's
	-- own colour for the cosmetic crates; brushed metal for the Mythic.
	local body = piece("Body", V(4, 2.7, 3), V(0, 1.61, 0),
		style.cloth and color:Lerp(SHELL, 0.55) or (style.glass and SHELL_DARK or SHELL),
		style.glass and Enum.Material.Glass or (style.cloth and Enum.Material.Fabric or (style.metal and Enum.Material.Metal or Enum.Material.SmoothPlastic)),
		nil, style.glass and 0.3 or nil)
	-- The plinth rides on the feet, which stand on y = 0: the crate's base is its origin. (The feet
	-- used to hang 0.06 below the plinth's bottom, so a crate set on a surface sank into it.)
	piece("Plinth", V(4.3, 0.3, 3.3), V(0, 0.21, 0), SHELL_DARK, Enum.Material.Metal)
	for _, x in ipairs({ -2, 2 }) do
		for _, z in ipairs({ -1.5, 1.5 }) do
			-- Cylinder length is its X, so the column's height goes first and the quarter turn stands
			-- it up. It runs from inside the plinth to inside the lid, clear of the body's top and
			-- bottom faces.
			piece("Edge", V(2.7, 0.5, 0.5), CFrame.new(x, 1.52, z) * CFrame.Angles(0, 0, math.pi / 2), fittingColor, fittingMaterial, Enum.PartType.Cylinder)
			if style.studs then
				-- Three studs down each column, set most of the way into it (balls: no flat faces).
				for _, y in ipairs({ 0.9, 1.52, 2.14 }) do
					piece("Stud", V(0.3, 0.3, 0.3), V(x * 1.07, y, z * 1.093), fittingColor, fittingMaterial, Enum.PartType.Ball)
				end
			end
			table.insert(tinted, piece("Cap", V(0.7, 0.7, 0.7), V(x, 2.95, z), color, Enum.Material.Foil, Enum.PartType.Ball))
			piece("Foot", V(0.6, 0.42, 0.6), V(x, 0.21, z), STEEL, Enum.Material.Metal)
		end
	end
	-- Seams of light round the body and a badge on the front.
	for _, y in ipairs({ 0.75, 2.15 }) do
		table.insert(tinted, piece("Band", V(4.12, 0.22, 3.12), V(0, y, 0), color, Enum.Material.Neon))
	end
	table.insert(tinted, piece("Seam", V(0.12, 2.38, 3.24), V(0, 1.55, 0), color, Enum.Material.Neon, nil, 0.2))
	local badge = piece("Badge", V(1.4, 1.4, 0.1), V(0, 1.45, -1.75), SHELL_DARK, Enum.Material.Metal)
	table.insert(tinted, piece("BadgeRing", V(0.08, 1.5, 1.5), CFrame.new(0, 1.45, -1.66) * CFrame.Angles(0, math.pi / 2, 0), color, Enum.Material.Neon,
		Enum.PartType.Cylinder))
	if tier then
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Front
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 50
		gui.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.FredokaOne
		label.Text = style.glyph or string.sub(tier, 1, 1)
		label.TextColor3 = color
		label.TextScaled = true
		label.Parent = gui
		gui.Parent = badge
	end
	-- Side handles, against the body.
	for _, x in ipairs({ -2.1, 2.1 }) do
		piece("Handle", V(0.2, 0.3, 1.2), V(x, 1.6, 0), STEEL, Enum.Material.Metal)
	end

	-- The lid: a dome (a cylinder lying across) on a rim, with its own band and the padlock. Its
	-- pivot is its hinge — the middle of its back edge, at the underside — so an open swings it:
	-- lid:PivotTo(lid:GetPivot() * CFrame.Angles(angle, 0, 0)) with a POSITIVE angle: the crate
	-- faces -Z, so the lid's front lies at -Z from the hinge, and a positive turn about the hinge's
	-- X lifts it (a negative one swings it down into the crate — measured by CrateOpen's gallery,
	-- and LootFxClient's chest swing uses positive too). The riders (dome, band, lock) are carried
	-- along by their offsets from the lid the way the reveal already does. The same hinge is on
	-- the lid as the attribute "Hinge", in the lid's own space, for anything that animates by
	-- CFrame rather than by pivot.
	local lid = piece("Lid", V(4.2, 0.4, 3.2), V(0, 3.0, 0), SHELL_DARK, Enum.Material.Metal)
	-- Scaled like every other offset here, so a scaled crate's lid still swings about its own back edge.
	local hinge = CFrame.new(0, -0.2 * scale, 1.6 * scale)
	lid.PivotOffset = hinge
	lid:SetAttribute("Hinge", hinge)
	-- What stands on the lid plate (its top is 3.2). Every piece here butts the plate or clears it
	-- by 0.07 or more; the returned `lidBand` is the tier-coloured neon of whichever lid this is.
	local lidBand
	if style.lid == "dome" or style.lid == "crown" then
		local dome = piece("LidDome", V(3.6, 1.6, 1.6), CFrame.new(0, 3.2, 0), style.cloth and body.Color or SHELL, body.Material, Enum.PartType.Cylinder)
		dome.Parent = lid
		lidBand = piece("LidBand", V(3.72, 1.7, 1.7), CFrame.new(0, 3.2, 0), color, Enum.Material.Neon, Enum.PartType.Cylinder, 0.55)
		if style.lid == "crown" then
			-- Eight points round the dome, on the plate outside the dome's reach (|z| > 0.85).
			for _, x in ipairs({ -1.55, -0.55, 0.55, 1.55 }) do
				for _, z in ipairs({ -1.3, 1.3 }) do
					piece("Point", V(0.6, 0.18, 0.18), CFrame.new(x, 3.5, z) * CFrame.Angles(0, 0, math.pi / 2), fittingColor, fittingMaterial, Enum.PartType.Cylinder).Parent = lid
					piece("PointTip", V(0.3, 0.3, 0.3), V(x, 3.85, z), fittingColor, fittingMaterial, Enum.PartType.Ball).Parent = lid
				end
			end
		end
	elseif style.lid == "peak" then
		-- Two wedges back to back, their vertical faces meeting at z = 0 and their undersides on the
		-- plate (they touch each other only along the ridge line), and a neon cap along the ridge.
		newWedge(lid, "LidPeak", V(3.6, 1.1, 1.5) * scale, CFrame.new(V(0, 3.75, -0.75) * scale), SHELL, body.Material)
		newWedge(lid, "LidPeak", V(3.6, 1.1, 1.5) * scale, CFrame.new(V(0, 3.75, 0.75) * scale) * CFrame.Angles(0, math.pi, 0), SHELL, body.Material)
		lidBand = piece("LidBand", V(3.72, 0.14, 0.14), V(0, 4.34, 0), color, Enum.Material.Neon)
	elseif style.bow then
		-- A present: a ribbon each way across the flat lid, the cross ribbon a step above the other
		-- (so no faces share a plane) and neon — it is this lid's band — and a knot where they cross.
		piece("Ribbon", V(0.5, 0.1, 3.44), V(0, 3.25, 0), color, Enum.Material.Fabric).Parent = lid
		lidBand = piece("LidBand", V(4.44, 0.1, 0.5), V(0, 3.35, 0), color, Enum.Material.Neon)
		piece("Knot", V(0.7, 0.7, 0.7), V(0, 3.45, 0), color, Enum.Material.Fabric, Enum.PartType.Ball).Parent = lid
	else
		-- Flat: a low ridge bar and a neon strip along the front edge.
		piece("LidRidge", V(3.2, 0.24, 0.8), V(0, 3.32, 0.2), style.cloth and body.Color or SHELL, body.Material).Parent = lid
		lidBand = piece("LidBand", V(3.72, 0.1, 0.16), V(0, 3.25, -1.45), color, Enum.Material.Neon)
	end
	lidBand.Parent = lid
	table.insert(tinted, lidBand)
	-- No padlock on a present.
	if not style.bow then
		local lock = piece("Lock", V(0.7, 0.8, 0.3), V(0, 2.72, -1.65), GOLD, Enum.Material.Foil)
		lock.Parent = lid
		local shackle = piece("Shackle", V(0.15, 0.6, 0.6), CFrame.new(0, 3.25, -1.65) * CFrame.Angles(0, math.pi / 2, 0), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		shackle.Parent = lid
		piece("Keyhole", V(0.14, 0.24, 0.06), V(0, 2.7, -1.83), SHELL_DARK, Enum.Material.Metal).Parent = lid
	end
	if style.halo then
		-- A ring of eight lights hung over the lid, touching nothing (floating on purpose).
		for index = 0, 7 do
			local angle = index / 8 * math.pi * 2
			local light = piece("HaloLight", V(0.32, 0.32, 0.32), V(math.cos(angle) * 1.7, 4.55, math.sin(angle) * 1.7), color, Enum.Material.Neon, Enum.PartType.Ball)
			light:SetAttribute("IntentionalFloat", true)
			table.insert(tinted, light)
		end
	end
	if style.core then
		table.insert(tinted, piece("Core", V(1.6, 1.6, 1.6), V(0, 1.61, 0), color, Enum.Material.Neon, Enum.PartType.Ball))
	end

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 8 * scale
	light.Brightness = 1.2
	light.Parent = body

	-- No two faces left flush: the badge and bands sit a clear hair proud of the body.
	ZFight.Fix({ model }, { all = true })

	model.PrimaryPart = body
	body.PivotOffset = body.CFrame:Inverse()
	return model, lid, lidBand, tinted
end

-- A map chest at `cframe` (its base on the ground): the "Chest" part with everything attached
-- under it, the lid a child named "Lid". Nothing is parented into the world yet.
function CrateModels.Chest(cframe)
	-- The body stands on its four feet, which stand on `cframe` (the ground), so no face of it
	-- lies in the ground's own surface.
	local chest = Instance.new("Part")
	chest.Name = "Chest"
	chest.Size = V(3.6, 2.0, 2.6)
	chest.Color = WOOD
	chest.Material = Enum.Material.WoodPlanks
	chest.Anchored = true
	chest.CFrame = cframe * CFrame.new(0, 1.3, 0)
	chest.TopSurface = Enum.SurfaceType.Smooth
	chest.BottomSurface = Enum.SurfaceType.Smooth
	local frame = chest.CFrame

	-- Plank lines, brass corners and straps, feet, and the lock plate. Every layer stands a clear
	-- 0.07 or more proud of the one under it — half-extents across: body 1.30, lid 1.35, planks
	-- 1.37, lip 1.42, straps and corners 1.44; along: lid 1.70, body 1.80, planks 1.87, corners
	-- 1.94, staves 1.95 and 2.03, lip 2.12; and on the front, plate 1.46, keyhole 1.52. The corners
	-- and straps stop inside the body's top, under the lid's lip, so nothing lies flush with
	-- anything else. (At 0.06 steps the pass still moved all 56 parts: 0.06 clears the scan's
	-- tolerance but not the pass's, so measure against FixTolerance, not Tolerance.)
	for _, y in ipairs({ -0.35, 0.35 }) do
		newPart(chest, "Plank", V(3.74, 0.06, 2.74), frame * CFrame.new(0, y, 0), WOOD_DARK, Enum.Material.Wood)
	end
	for _, x in ipairs({ -1.77, 1.77 }) do
		for _, z in ipairs({ -1.27, 1.27 }) do
			newPart(chest, "Corner", V(0.34, 1.96, 0.34), frame * CFrame.new(x, -0.08, z), BRASS, Enum.Material.Metal)
			newPart(chest, "Foot", V(0.5, 0.3, 0.5), frame * CFrame.new(x, -1.15, z), BRASS, Enum.Material.Metal)
		end
	end
	for _, x in ipairs({ -1.0, 1.0 }) do
		newPart(chest, "Strap", V(0.34, 1.96, 2.88), frame * CFrame.new(x, -0.08, 0), BRASS, Enum.Material.Metal)
	end
	-- The lock plate sits below the hasp that closes onto it rather than overlapping its last 0.08:
	-- where they overlapped, their faces were 0.03 apart and the z-fight pass pulled the hasp out.
	newPart(chest, "Plate", V(0.9, 0.9, 0.16), frame * CFrame.new(0, 0.2, -1.38), BRASS, Enum.Material.Foil)
	newPart(chest, "Keyhole", V(0.16, 0.3, 0.06), frame * CFrame.new(0, 0.18, -1.49), Color3.fromRGB(20, 20, 24), Enum.Material.Metal)
	-- The glow waiting inside: a lit strip down inside the chest (its light spills out through the
	-- seam and the keyhole). It used to sit up inside the lid's base, where its top face was a
	-- twentieth of a stud off the lid's own and off the brass lip's.
	local seam = newPart(chest, "Seam", V(3.0, 0.1, 2.0), frame * CFrame.new(0, 0.78, 0), GLOW, Enum.Material.Neon, nil, 0.25)
	local light = Instance.new("PointLight")
	light.Color = GLOW
	light.Range = 7
	light.Brightness = 0.9
	light.Parent = seam

	-- The lid: a barrel top of staves on a half circle over a flat base plate, with brass bands, a
	-- head at each end and a lip under it. It rests on the body's rim rather than sinking into it.
	-- LootFxClient hinges it on its back edge.
	--
	-- It used to be a single cylinder with its lower half sunk into the body's rim. That reads
	-- correctly only while the chest is shut: LootFxClient hinges the lid on its back edge and
	-- swings it up, which brings the buried half round with it, so opening a chest showed a
	-- complete tube instead of a dome. A cylinder cannot be both half sunk and opened. An arc of
	-- staves is genuinely open underneath, so the lid reveals the inside of a dome.
	--
	-- The part itself stays the hinge: LootFxClient reads its Z size to place the hinge on the
	-- back edge and carries every descendant along with it, so the staves must be its children.
	-- The lid's base plate: narrower than the staves that cover it, so its ends aren't in their
	-- plane, and lifted until its underside meets the body's rim rather than sinking 0.09 into it
	-- (the two overlapped, which put their side faces 0.05 apart).
	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = V(3.4, 0.26, 2.7)
	lid.CFrame = frame * CFrame.new(0, 1.13, 0)
	lid.Color = WOOD_DARK
	lid.Material = Enum.Material.WoodPlanks
	lid.Anchored = true
	lid.CanCollide = false
	lid.CanQuery = false
	lid.CanTouch = false
	lid.Parent = chest

	-- Staves over the arc with brass bands across them.
	--
	-- Turning a stave about the arc does NOT turn the two faces at its ends: every stave's ends lay
	-- in the same two planes, and since neighbours overlap along the arc, that was twelve pairs of
	-- faces lying flush — the same mistake the glider's canopy cells made. So alternate staves run
	-- STAGGER longer at both ends. The bands are cut to exactly their share of the arc instead of
	-- overlapping their neighbours, which leaves their ends in one plane but with nothing to fight
	-- (faces that only share an edge don't).
	local STAVES = 8
	local STAGGER = 0.08
	local archRadius = 1.26
	-- A shade under each band's share of the arc, so neighbours leave a hair of daylight rather
	-- than overlapping: cut to exactly their share they still overlapped by 0.016 at the inner
	-- edge (turned rectangles meet at their corners, not along their faces), and 0.016 sits right
	-- on the pass's minimum overlap, which Roblox's arithmetic tipped over.
	local bandDepth = (archRadius + 0.16) * math.pi / STAVES * 0.92
	for index = 0, STAVES - 1 do
		local around = -math.pi / 2 + (index + 0.5) * (math.pi / STAVES)
		local at = lid.CFrame * CFrame.Angles(around, 0, 0)
		newPart(lid, "LidStave", V(3.9 + (index % 2) * STAGGER * 2, 0.2, 0.62), at * CFrame.new(0, archRadius, 0), WOOD,
			Enum.Material.WoodPlanks)
		for _, x in ipairs({ -1.0, 1.0 }) do
			newPart(lid, "LidBand", V(0.42, 0.12, bandDepth), at * CFrame.new(x, archRadius + 0.16, 0), BRASS, Enum.Material.Metal)
		end
	end
	-- The barrel's two ends. The staves only make the curve, so without these both ends of the lid
	-- stood open and you looked straight into a hollow half-tube from the side. Each end is a head
	-- of planks stacked up the half circle, inset 0.06 from the stave ends so no face is shared.
	-- Every plank reaches past the staves' inside surface at its bottom and stops inside their
	-- thickness at its top corners, so nothing shows between head and staves and nothing pokes out.
	-- The heads stack from the lid's top face upward (starting at its mid-plane put a plank edge
	-- 0.03 off the lid's own top), stand well inside the staves' ends, and stop short of the lid's
	-- sides so no plank's width lands in the lid's side plane.
	local HEAD_PLANKS = 8
	local headBase = 0.13
	local plankHeight = (archRadius - headBase) / HEAD_PLANKS
	local headReach = 1.28
	for _, side in ipairs({ -1, 1 }) do
		for index = 0, HEAD_PLANKS - 1 do
			local top = headBase + (index + 1) * plankHeight
			local halfWidth = math.sqrt(headReach * headReach - top * top)
			newPart(lid, "LidHead", V(0.2, plankHeight, halfWidth * 2),
				lid.CFrame * CFrame.new(side * 1.7, headBase + (index + 0.5) * plankHeight, 0), WOOD_DARK, Enum.Material.WoodPlanks)
		end
	end
	newPart(lid, "LidLip", V(4.24, 0.2, 2.84), lid.CFrame * CFrame.new(0, -0.1, 0), BRASS, Enum.Material.Metal)
	newPart(lid, "Hasp", V(0.5, 0.6, 0.14), lid.CFrame * CFrame.new(0, -0.16, -1.42), BRASS, Enum.Material.Foil)

	ZFight.Fix({ chest }, { all = true })
	return chest, lid
end

return CrateModels
