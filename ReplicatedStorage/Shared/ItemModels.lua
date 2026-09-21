-- Models for every carryable item — heals, shield potions and movement items — built from parts.
--
-- Shared by the pickups on the map, the item held in a player's hands and the first-person
-- viewmodel, so an item looks the same wherever you see it. Each is built facing -Z around the
-- design origin with a part named "Grip" where the hand goes, the same conventions the guns use,
-- and pivots on the origin. Glowing parts are named "Glow" so the viewmodel can pulse them while
-- the item is being used.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemData"))
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local ItemModels = {}

local WHITE = Color3.fromRGB(245, 245, 242)
local DARK = Color3.fromRGB(40, 42, 48)
local STEEL = Color3.fromRGB(170, 176, 186)
local CORK = Color3.fromRGB(150, 110, 70)
local RED = Color3.fromRGB(220, 50, 50)
local GLASS_TINT = Color3.fromRGB(200, 230, 255)

local V = Vector3.new

-- options: scale (default 1), anchored (default true), name (default "HeldItem"), open (the Rot
-- Glider's wing deployed rather than packed)
function ItemModels.Build(id, options)
	options = options or {}
	local item = ItemData.Get(id)
	if not item then
		return nil
	end
	-- Grenades and smoke bombs are built by ThrowableModels, to this same contract.
	if item.kind == "throwable" then
		return require(ReplicatedStorage.Shared:WaitForChild("ThrowableModels")).Build(id, options)
	end
	local scale = options.scale or 1
	local anchored = options.anchored ~= false
	local color = item.color

	local model = Instance.new("Model")
	model.Name = options.name or "HeldItem"
	model:SetAttribute("ItemId", id)

	local function piece(name, size, cframe, pieceColor, material, shape, transparency)
		local part = Instance.new("Part")
		part.Name = name
		if shape then
			part.Shape = shape
		end
		local frame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
		part.Size = size * scale
		part.CFrame = CFrame.new(frame.Position * scale) * frame.Rotation
		part.Color = pieceColor
		part.Material = material or Enum.Material.SmoothPlastic
		part.Transparency = transparency or 0
		part.Anchored = anchored
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = part.Material ~= Enum.Material.Neon and (transparency or 0) < 0.3
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	-- Upright cylinder centred at `position`.
	local function column(name, height, diameter, position, pieceColor, material, transparency)
		return piece(name, V(height, diameter, diameter), CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2),
			pieceColor, material, Enum.PartType.Cylinder, transparency)
	end

	-- Cylinder running front to back.
	local function tube(name, length, diameter, position, pieceColor, material, transparency)
		return piece(name, V(length, diameter, diameter), CFrame.new(position) * CFrame.Angles(0, math.pi / 2, 0),
			pieceColor, material, Enum.PartType.Cylinder, transparency)
	end

	local function ball(name, diameter, position, pieceColor, material, transparency)
		return piece(name, V(diameter, diameter, diameter), position, pieceColor, material, Enum.PartType.Ball, transparency)
	end

	-- An invisible handle marker.
	local function grip(position)
		return piece("Grip", V(0.2, 0.2, 0.2), position, DARK, nil, nil, 1)
	end

	local body

	if id == "Bandage" then
		-- A roll of gauze lying on its side, a tail of it unrolled, clipped, with a red cross.
		body = piece("Body", V(0.7, 0.9, 0.9), V(0, 0.1, 0), color, Enum.Material.Fabric, Enum.PartType.Cylinder)
		-- The cardboard core pokes clear out of both ends of the roll. It used to stop 0.01 past
		-- them, close enough that the build's z-fight pass had to push it out itself.
		piece("Core", V(0.84, 0.3, 0.3), V(0, 0.1, 0), Color3.fromRGB(180, 160, 130), Enum.Material.Fabric, Enum.PartType.Cylinder)
		for _, x in ipairs({ -0.22, 0.22 }) do
			piece("Band", V(0.08, 0.92, 0.92), V(x, 0.1, 0), WHITE, Enum.Material.Fabric, Enum.PartType.Cylinder)
		end
		local tail = CFrame.new(0, -0.32, -0.42) * CFrame.Angles(-0.45, 0, 0)
		-- The tail unrolls from between the two bands, clear of both their edges and the roll's.
		piece("Tail", V(0.36, 0.05, 0.9), tail, color, Enum.Material.Fabric)
		-- The clip is a rod across the gauze, sunk into it. A cylinder has only its two ends, so
		-- nothing of it can lie flush with the tail the way the old flat clip's faces did. (Before
		-- that it hung in the air 0.3 above the tail.)
		piece("Clip", V(0.22, 0.09, 0.09), tail * CFrame.new(0, 0.03, -0.33), STEEL, Enum.Material.Metal, Enum.PartType.Cylinder)
		-- The cross lies on top of the roll, a bar with a stub butted on each end. On the end of the
		-- roll it was two bars crossing through each other, sharing their whole front face, and both
		-- of them within four hundredths of the core and the roll's own rim.
		piece("Glow", V(0.3, 0.07, 0.1), V(0, 0.555, 0), RED, Enum.Material.Neon)
		for _, z in ipairs({ -0.1, 0.1 }) do
			piece("Glow", V(0.1, 0.07, 0.1), V(0, 0.555, z), RED, Enum.Material.Neon)
		end
		grip(V(0, -0.1, 0.15))
	elseif id == "MedKit" then
		-- A hard case with a carry handle, latches, trim bands and a cross on both faces.
		-- Everything that sits on the case stands a clear 0.07 proud of it. The bumpers and the lid
		-- seam used to be 0.01-0.02 over the shell, which is the width the cleanup pass then had to
		-- open up itself — on every one of the thirteen parts, the cross and the handle included.
		body = piece("Body", V(1.36, 0.9, 0.52), V(0, 0, 0), WHITE)
		for _, y in ipairs({ -0.32, 0.32 }) do
			piece("Trim", V(1.5, 0.08, 0.66), V(0, y, 0), color)
		end
		piece("Seam", V(1.5, 0.03, 0.66), V(0, 0.12, 0), DARK)
		-- The cross is an arm with a stub butted on each end, not two bars crossing through each
		-- other: two bars at the same depth share their whole front face where they cross.
		for _, z in ipairs({ -0.295, 0.295 }) do
			piece("Glow", V(0.3, 0.1, 0.07), V(0, -0.1, z), color, Enum.Material.Neon)
			for _, y in ipairs({ -0.2, 0 }) do
				piece("Glow", V(0.1, 0.1, 0.07), V(0, y, z), color, Enum.Material.Neon)
			end
		end
		for _, x in ipairs({ -0.3, 0.3 }) do
			piece("HandlePost", V(0.08, 0.2, 0.08), V(x, 0.55, 0), DARK, Enum.Material.Metal)
			-- A draw latch across the seam, standing off the shell far enough to clear the seam's own
			-- face. It used to end 0.045 short of it.
			piece("Latch", V(0.12, 0.24, 0.14), V(x * 1.5, 0.14, -0.33), STEEL, Enum.Material.Metal)
		end
		-- The handle bar rests on top of its posts rather than sinking 0.05 into them.
		piece("Grip", V(0.7, 0.08, 0.12), V(0, 0.69, 0), DARK, Enum.Material.Fabric)
	elseif id == "MiniShield" then
		-- A round flask of glowing blue, with a cork and a paper label round the middle.
		body = ball("Body", 0.9, V(0, 0, 0), GLASS_TINT, Enum.Material.Glass, 0.45)
		ball("Glow", 0.72, V(0, -0.05, 0), color, Enum.Material.Neon)
		column("Neck", 0.35, 0.3, V(0, 0.55, 0), GLASS_TINT, Enum.Material.Glass, 0.45)
		column("Cork", 0.18, 0.26, V(0, 0.8, 0), CORK, Enum.Material.Wood)
		column("Label", 0.16, 0.93, V(0, -0.05, 0), Color3.fromRGB(240, 232, 210), Enum.Material.Fabric)
		ball("Glow", 0.12, V(0.12, 0.22, -0.2), Color3.fromRGB(220, 245, 255), Enum.Material.Neon)
		grip(V(0, -0.1, 0.2))
	elseif id == "ShieldPotion" then
		-- A tall bottle: glass body and shoulder, glowing liquid, a sealed cork and a label.
		-- The liquid stops a glass thickness above the floor, the neck, lip and cork stack in clear
		-- steps, and the foot wraps under the bottle. Every one of those used to land within a few
		-- hundredths of the face beside it, and the pass then moved all twelve parts.
		body = column("Body", 1.1, 0.7, V(0, 0, 0), GLASS_TINT, Enum.Material.Glass, 0.45)
		column("Glow", 0.9, 0.58, V(0, -0.03, 0), color, Enum.Material.Neon)
		ball("Shoulder", 0.7, V(0, 0.45, 0), GLASS_TINT, Enum.Material.Glass, 0.45)
		ball("Glow", 0.58, V(0, 0.42, 0), color, Enum.Material.Neon)
		column("Neck", 0.37, 0.26, V(0, 0.935, 0), GLASS_TINT, Enum.Material.Glass, 0.45)
		column("Lip", 0.08, 0.32, V(0, 1.16, 0), GLASS_TINT, Enum.Material.Glass, 0.3)
		column("Cork", 0.25, 0.2, V(0, 1.175, 0), CORK, Enum.Material.Wood)
		ball("Seal", 0.2, V(0, 1.38, 0), RED, Enum.Material.SmoothPlastic)
		-- The label stands off the glass rather than 0.01 over it, and the badge off the label.
		column("Label", 0.35, 0.76, V(0, -0.05, 0), Color3.fromRGB(240, 232, 210), Enum.Material.Fabric)
		piece("Glow", V(0.22, 0.22, 0.06), CFrame.new(0, -0.05, -0.38) * CFrame.Angles(0, 0, math.pi / 4),
			Color3.fromRGB(140, 230, 255), Enum.Material.Neon)
		column("Base", 0.11, 0.74, V(0, -0.605, 0), Color3.fromRGB(150, 180, 210), Enum.Material.Glass, 0.2)
		grip(V(0, -0.1, 0.25))
	elseif id == "SpeedSoda" then
		-- A can with rolled rims, a ring pull, a white label band and a lightning bolt.
		body = column("Body", 1.0, 0.62, V(0, 0, 0), color, Enum.Material.Metal)
		-- The rims cap the ends of the body rather than standing 0.05 proud of them, and the top one
		-- is the lid: the separate lid disc sat 0.02 under the rim's own face, so the two fought, and
		-- the cleanup pass answered by stretching the can 0.22 taller and the lid six times thicker.
		for _, y in ipairs({ -0.55, 0.55 }) do
			column("Rim", 0.1, 0.7, V(0, y, 0), STEEL, Enum.Material.Metal)
		end
		-- The ring pull lies at a slight angle, the way a lifted tab does, rather than flat on the lid
		-- a couple of hundredths above it.
		piece("Tab", V(0.14, 0.03, 0.22), CFrame.new(0.08, 0.615, 0) * CFrame.Angles(0, 0, 0.12), STEEL, Enum.Material.Metal)
		-- The label stands clear of the can's own curve instead of 0.005 over it (that close, the two
		-- surfaces shimmer against each other as the camera moves), and inside the rims.
		column("Label", 0.4, 0.66, V(0, 0, 0), WHITE)
		piece("Glow", V(0.08, 0.26, 0.02), CFrame.new(0.02, 0.06, -0.335) * CFrame.Angles(0, 0, 0.4), Color3.fromRGB(255, 220, 60), Enum.Material.Neon)
		piece("Glow", V(0.08, 0.26, 0.02), CFrame.new(-0.02, -0.08, -0.335) * CFrame.Angles(0, 0, 0.4), Color3.fromRGB(255, 220, 60), Enum.Material.Neon)
		piece("Straw", V(0.06, 0.55, 0.06), CFrame.new(0.12, 0.8, 0) * CFrame.Angles(0, 0, -0.25), Color3.fromRGB(255, 110, 190), Enum.Material.Neon)
		grip(V(0, -0.05, 0.2))
	elseif id == "RotRocket" then
		-- A hand rocket: striped body, nose cone, three fins, a nozzle with a pilot flame, a handle.
		body = tube("Body", 1.3, 0.36, V(0, 0, 0), color, Enum.Material.Metal)
		tube("Nose", 0.25, 0.3, V(0, 0, -0.75), WHITE)
		ball("Tip", 0.26, V(0, 0, -0.88), WHITE)
		for _, z in ipairs({ -0.35, 0.1 }) do
			tube("Stripe", 0.08, 0.37, V(0, 0, z), DARK)
		end
		-- The fins run past the tail. At 0.36 they ended 0.03 beyond it, so all three fought the
		-- body's end face and the pass stretched every one of them.
		for index = 0, 2 do
			local angle = index / 3 * math.pi * 2
			piece("Fin", V(0.04, 0.3, 0.44),
				CFrame.new(0, 0, 0.5) * CFrame.Angles(0, 0, angle) * CFrame.new(0, 0.25, 0), WHITE)
		end
		tube("Nozzle", 0.15, 0.28, V(0, 0, 0.72), DARK, Enum.Material.Metal)
		ball("Glow", 0.22, V(0, 0, 0.86), Color3.fromRGB(255, 210, 80), Enum.Material.Neon)
		piece("Grip", V(0.14, 0.42, 0.16), CFrame.new(0, -0.36, 0.2) * CFrame.Angles(-0.25, 0, 0), DARK, Enum.Material.Fabric)
	elseif id == "LaunchPad" then
		-- A folded pad: a plated base, a glowing ring, a coil spring and the top plate with its arrow.
		body = column("Body", 0.2, 1.2, V(0, -0.3, 0), DARK, Enum.Material.DiamondPlate)
		-- The ring glows round the rim of the base. It used to be a disc inside the base standing
		-- 0.01 past its top and bottom, which is a hundredth of light where the two faces flicker.
		column("Glow", 0.06, 1.26, V(0, -0.3, 0), color, Enum.Material.Neon)
		-- The coils sit on a post from the base to the plate, so the plate is held up rather than
		-- hovering over three loose rings.
		column("Post", 0.49, 0.46, V(0, -0.015, 0), DARK, Enum.Material.Metal)
		for index, y in ipairs({ -0.13, -0.01, 0.11 }) do
			column("Spring", 0.05, 0.62 + index * 0.04, V(0, y, 0), STEEL, Enum.Material.Metal)
		end
		column("Plate", 0.12, 1.0, V(0, 0.24, 0), color, Enum.Material.SmoothPlastic)
		-- The arrow stands proud of the plate instead of 0.03 over it.
		piece("Glow", V(0.2, 0.09, 0.5), V(0, 0.345, 0), WHITE, Enum.Material.Neon)
		piece("Grip", V(0.5, 0.1, 0.14), V(0, -0.45, 0.45), DARK, Enum.Material.Fabric)
	elseif id == "BlinkBean" then
		-- A glass capsule round a crackling pink core, with a steel band.
		body = column("Body", 0.5, 0.6, V(0, 0, 0), Color3.fromRGB(255, 200, 245), Enum.Material.Glass, 0.45)
		for _, y in ipairs({ -0.25, 0.25 }) do
			ball("Shell", 0.6, V(0, y, 0), Color3.fromRGB(255, 200, 245), Enum.Material.Glass, 0.45)
		end
		ball("Glow", 0.42, V(0, 0, 0), color, Enum.Material.Neon)
		for index = 0, 2 do
			local angle = index / 3 * math.pi * 2
			ball("Glow", 0.1, V(math.cos(angle) * 0.18, math.sin(angle * 2) * 0.2, math.sin(angle) * 0.18), WHITE, Enum.Material.Neon)
		end
		column("Band", 0.05, 0.64, V(0, 0, 0), STEEL, Enum.Material.Metal)
		grip(V(0, -0.1, 0.2))
	elseif id == "BounceBoots" then
		-- A pair of chunky boots on coil springs, with glowing laces.
		for _, x in ipairs({ -0.32, 0.32 }) do
			local upper = piece("Upper", V(0.32, 0.45, 0.42), V(x, -0.02, 0.1), color, Enum.Material.Fabric)
			body = body or upper
			ball("Toe", 0.34, V(x, -0.18, -0.2), color, Enum.Material.Fabric)
			-- The sole is deep enough to take the upper into it. At 0.14 its top stopped 0.025 under the
			-- upper's bottom: a slit of daylight round the back of the boot, held together only by the
			-- toe overlapping both.
			piece("Sole", V(0.46, 0.22, 0.76), V(x, -0.3, 0), DARK)
			-- The coils ride a strut that runs up into the sole, the way the Launch Pad's do. They were
			-- three loose rings hanging 0.03 under the boot with nothing joining them to it or to each
			-- other — welded, so they never fell, but floating all the same.
			column("Strut", 0.35, 0.1, V(x, -0.525, -0.02), STEEL, Enum.Material.Metal)
			for index = 0, 2 do
				column("Spring", 0.04, 0.26, V(x, -0.46 - index * 0.07, -0.02), STEEL, Enum.Material.Metal)
			end
			piece("Glow", V(0.2, 0.04, 0.3), V(x, 0.12, -0.08), Color3.fromRGB(230, 255, 120), Enum.Material.Neon)
		end
		grip(V(0, 0, 0.1))
	elseif id == "RotBarricade" then
		-- A folded kit: three sandbag panels strapped together, a carry handle underneath.
		local sand = color
		local strap = Color3.fromRGB(60, 56, 50)
		-- The panels overlap the one under them by a hair: stacked with gaps, light showed through
		-- the kit between every layer.
		body = piece("Body", V(1.0, 0.16, 0.7), V(0, 0, 0), sand, Enum.Material.Fabric)
		piece("Panel", V(0.96, 0.17, 0.68), V(0, 0.165, 0.02), sand:Lerp(Color3.new(0, 0, 0), 0.1), Enum.Material.Fabric)
		piece("Panel", V(0.92, 0.16, 0.66), V(0, 0.325, -0.02), sand, Enum.Material.Fabric)
		-- The straps stand clear of the stack they cross, round it as well as across it: at 0.5 tall
		-- they ended a hundredth under the bottom bag and half a hundredth over the top one, and at
		-- 0.74 deep they were a fifth of a stud proud of one panel and a hundredth of another.
		for _, x in ipairs({ -0.3, 0.3 }) do
			piece("Strap", V(0.12, 0.64, 0.86), V(x, 0.16, 0), strap, Enum.Material.Fabric)
		end
		-- The buckle rides on top of the strap rather than ending level with the panel under it.
		piece("Buckle", V(0.14, 0.08, 0.2), V(0.3, 0.52, 0), STEEL, Enum.Material.Metal)
		piece("Glow", V(0.3, 0.08, 0.06), V(0, 0.44, -0.2), Color3.fromRGB(90, 200, 255), Enum.Material.Neon)
		-- The handle is sewn to the underside, its top just inside the bottom bag, and narrow enough
		-- to pass between the two straps instead of ending a hundredth off their undersides. (At
		-- -0.14 it hung 0.02 under the kit, a slit of light the length of the handle.)
		piece("Grip", V(0.44, 0.08, 0.14), V(0, -0.115, 0), strap, Enum.Material.Fabric)
	elseif id == "RotMine" then
		-- A squat pressure mine: a dark steel disc, a plate in the item's colour with three
		-- pressure prongs around an arming light, and a carry strap underneath. The deployed mine
		-- is this same model at three times the size (HazardService), so it reads the same
		-- in your hand and on the ground.
		local steel = Color3.fromRGB(70, 74, 80)
		body = column("Body", 0.2, 0.9, V(0, 0, 0), steel, Enum.Material.Metal)
		column("Plate", 0.06, 0.72, V(0, 0.13, 0), color, Enum.Material.SmoothPlastic)
		column("Rim", 0.04, 0.94, V(0, 0.02, 0), DARK, Enum.Material.Metal)
		for index = 0, 2 do
			local angle = index / 3 * math.pi * 2 + math.pi / 2
			piece("Prong", V(0.08, 0.14, 0.08), V(math.cos(angle) * 0.24, 0.23, math.sin(angle) * 0.24), STEEL, Enum.Material.Metal)
		end
		ball("Glow", 0.16, V(0, 0.2, 0), Color3.fromRGB(255, 80, 60), Enum.Material.Neon)
		piece("Grip", V(0.5, 0.08, 0.14), V(0, -0.14, 0), DARK, Enum.Material.Fabric)
	elseif id == "PopupBunker" then
		-- An armoured case with rivets and a warning stripe, carried by the handle on top.
		local steel = color
		body = piece("Body", V(1.1, 0.7, 0.5), V(0, 0, 0), steel, Enum.Material.DiamondPlate)
		-- The seam stands a clear 0.07 off the shell; at 1.12 x 0.52 it was a hundredth over it on
		-- four sides.
		piece("Seam", V(1.24, 0.03, 0.64), V(0, 0.08, 0), DARK)
		for _, x in ipairs({ -0.45, 0.45 }) do
			for _, y in ipairs({ -0.25, 0.25 }) do
				ball("Rivet", 0.09, V(x, y, -0.26), STEEL, Enum.Material.Metal)
			end
		end
		-- Hazard bars: one layer of alternating diagonals, each butted against the next (faces that
		-- only share an edge don't fight). It used to be a yellow plate with a dark one turned across
		-- it a hundredth in front, both a couple of hundredths off the shell.
		local tilt = 0.6
		local barStep = 0.09 / math.cos(tilt)
		for index = 0, 3 do
			piece("Stripe", V(0.09, 0.16, 0.07), CFrame.new((index - 1.5) * barStep, -0.14, -0.285) * CFrame.Angles(0, 0, tilt),
				index % 2 == 0 and Color3.fromRGB(240, 190, 40) or DARK, Enum.Material.SmoothPlastic)
		end
		piece("Glow", V(0.6, 0.05, 0.07), V(0, 0.255, -0.285), Color3.fromRGB(90, 200, 255), Enum.Material.Neon)
		for _, x in ipairs({ -0.22, 0.22 }) do
			piece("HandlePost", V(0.08, 0.16, 0.08), V(x, 0.42, 0), DARK, Enum.Material.Metal)
		end
		-- The handle bar rests on top of its posts rather than sinking into them.
		piece("Grip", V(0.56, 0.08, 0.12), V(0, 0.54, 0), DARK, Enum.Material.Fabric)
	elseif id == "BrainrotFortress" then
		-- A gold-trimmed crate with a little keep on top, so the Legendary reads as one.
		local wood = Color3.fromRGB(120, 86, 52)
		body = piece("Body", V(1.0, 0.7, 0.7), V(0, 0, 0), wood, Enum.Material.WoodPlanks)
		-- The gold bands stand a clear 0.07 off the crate, and the end plates sit inside them on the
		-- crate's ends. Before this every trim face landed within three hundredths of the crate's or
		-- of another band's — eight of the thirty-seven flush pairs were trim against trim, four of
		-- them exactly level — and the pass grew the crate itself to sort it out.
		for _, y in ipairs({ -0.24, 0.24 }) do
			piece("Trim", V(1.14, 0.08, 0.84), V(0, y, 0), color, Enum.Material.Foil)
		end
		for _, x in ipairs({ -0.535, 0.535 }) do
			piece("Trim", V(0.07, 0.36, 0.36), V(x, 0, 0), color, Enum.Material.Foil)
		end
		column("Keep", 0.42, 0.4, V(0, 0.56, 0), Color3.fromRGB(190, 182, 168), Enum.Material.Cobblestone)
		for index = 0, 3 do
			local angle = index / 4 * math.pi * 2
			piece("Merlon", V(0.1, 0.12, 0.1), V(math.cos(angle) * 0.15, 0.83, math.sin(angle) * 0.15), Color3.fromRGB(190, 182, 168),
				Enum.Material.Cobblestone)
		end
		-- The pole is stepped into the keep. At 0.4 tall from y 1.0 its foot stood 0.03 above the roof
		-- and 0.1 clear of the merlons, so the pole and its flag were an island hanging over the tower.
		piece("Flagpole", V(0.03, 0.48, 0.03), V(0, 0.96, 0), DARK, Enum.Material.Metal)
		-- The flag flies from the pole, hoist edge just inside it, swung round so it isn't a thin
		-- sheet lying parallel to a thin pole a hundredth away. (Before that it hung in the air a
		-- tenth of a stud to the side of the pole.)
		piece("Glow", V(0.02, 0.14, 0.22), CFrame.new(0, 1.05, 0.005) * CFrame.Angles(0, 0.3, 0) * CFrame.new(0, 0, 0.11),
			color, Enum.Material.Neon)
		-- Sewn to the underside. At -0.42 its top was 0.03 below the crate: a slit of daylight the
		-- length of the handle, which nothing in the z-fight pass looks for (it hunts faces that are
		-- too close, never ones left apart).
		piece("Grip", V(0.6, 0.08, 0.14), V(0, -0.39, 0), DARK, Enum.Material.Fabric)
	elseif id == "RotGlider" and options.open then
		-- The wing, open: eleven cells on an arc, drooping at the tips, striped in the item's colour,
		-- a rib over every seam, and lines down to a harness bar (the body, welded over the head).
		-- This is also every player's drop-in canopy, at three times the size.
		--
		-- The cells tile the arc with nothing between them. Each is exactly as wide as its slice of
		-- the arc at the top skin, so neighbours meet at the crease along the top and overlap
		-- underneath. (The first version spaced nine 0.62-wide cells 18.75 degrees apart, which left
		-- eight see-through slits the length of the wing, half a stud wide on the drop-in canopy.)
		-- Turning a cell about the arc never turns its front and back faces, so every cell's lie in the
		-- same two planes, and where neighbours overlap underneath those faces overlapped: ten flush
		-- pairs. The build's z-fight pass then stretched each cell a step longer than the one before,
		-- one side of the wing 1.2 studs deeper than the other on the drop-in canopy. So every second
		-- cell is STAGGER longer at both ends, and the ribs and tip caps stand STAGGER past those.
		-- No glowing leading edge: Oliver asked for the canopy without it.
		body = piece("Body", V(1.4, 0.12, 0.12), V(0, 0, 0), DARK, Enum.Material.Metal)
		local mint = Color3.fromRGB(120, 230, 160)
		local cells = 11
		local arc = 2.3
		local span = math.rad(150)
		local step = span / (cells - 1)
		local thick, depth = 0.16, 1.6
		local STAGGER = 0.08
		local cellWidth = 2 * (arc + thick / 2) * math.tan(step / 2) + 0.01
		local function onArc(angle)
			return CFrame.new(math.sin(angle) * arc, math.cos(angle) * arc - arc + 2.6, 0) * CFrame.Angles(0, 0, -angle)
		end
		for index = 0, cells - 1 do
			local at = onArc(-span / 2 + index * step)
			local cellDepth = index % 2 == 0 and depth or depth + STAGGER * 2
			piece("Cell", V(cellWidth, thick, cellDepth), at, index % 2 == 0 and color or mint, Enum.Material.Fabric)
		end
		-- Ribs on every seam and a cap at each tip, lying along the seam's own angle.
		for index = 0, cells do
			local at = onArc(-span / 2 + (index - 0.5) * step)
			local tip = index == 0 or index == cells
			piece(tip and "TipCap" or "CellRib", V(tip and 0.08 or 0.05, thick + 0.06, depth + STAGGER * 4), at, DARK, Enum.Material.Fabric)
			-- Lines from alternate ribs, mirrored, down to a riser at each end of the harness bar.
			if index == 2 or index == 4 or index == 5 or index == 6 or index == 7 or index == 9 then
				local anchor = (at * CFrame.new(0, -(thick / 2 + 0.03) + 0.01, 0.3)).Position
				local riser = V(anchor.X > 0 and 0.55 or -0.55, 0, 0)
				local line = CFrame.lookAt(anchor:Lerp(riser, 0.5), anchor)
				piece("Line", V(0.03, 0.03, (anchor - riser).Magnitude), line, Color3.fromRGB(236, 232, 220), Enum.Material.Fabric)
			end
		end
		-- Harness straps down to the shoulders, run down the back of the bar. Centred on it, their front
		-- and back faces lay in the bar's own (four flush pairs, which the pass fixed by doubling the
		-- straps' thickness).
		for _, x in ipairs({ -0.55, 0.55 }) do
			piece("Strap", V(0.12, 1.1, 0.12), CFrame.new(x, -0.55, 0.07) * CFrame.Angles(0, 0, x * 0.3), DARK, Enum.Material.Fabric)
		end
	elseif id == "RotGlider" then
		-- Packed: the wing rolled up on a light frame with its straps, a pull handle, and a strip
		-- of the leading edge showing. Held by the frame.
		body = piece("Body", V(0.24, 0.9, 0.16), V(0, 0.2, 0), DARK, Enum.Material.Metal)
		local mint = Color3.fromRGB(120, 230, 160)
		-- The roll lies across the top of the frame (a cylinder's length is its X), with four bands
		-- round it placed symmetrically. It used to be turned upright, and the "bands" were thin
		-- upright rods standing loose beside it.
		piece("Roll", V(1.3, 0.34, 0.34), V(0, 0.62, 0), color, Enum.Material.Fabric, Enum.PartType.Cylinder)
		for index, x in ipairs({ -0.495, -0.165, 0.165, 0.495 }) do
			piece("RollBand", V(0.05, 0.4, 0.4), V(x, 0.62, 0), index % 2 == 1 and mint or DARK, Enum.Material.Fabric, Enum.PartType.Cylinder)
		end
		piece("Glow", V(1.2, 0.04, 0.06), V(0, 0.62, -0.17), color, Enum.Material.Neon)
		for _, x in ipairs({ -0.45, 0.45 }) do
			piece("Strap", V(0.08, 0.5, 0.08), CFrame.new(x, 0.32, 0.1) * CFrame.Angles(0, 0, -x * 0.5), DARK, Enum.Material.Fabric)
		end
		piece("Handle", V(0.3, 0.08, 0.08), V(0, -0.35, 0), STEEL, Enum.Material.Metal)
		-- The grip is a fabric sleeve round the frame bar. As a block it was 0.14 across inside a
		-- 0.16 frame — invisible except for the stub below it, with all five of its faces a hundredth
		-- or two off the frame's own, the one thing on this model the pass had to touch.
		column("Grip", 0.5, 0.3, V(0, -0.07, 0), DARK, Enum.Material.Fabric)
	end

	-- No two faces left flush, before the welds so only the one part moves.
	ZFight.Fix({ model }, { all = true })

	model.PrimaryPart = body
	body.PivotOffset = body.CFrame:Inverse()

	if not anchored then
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and part ~= body then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = body
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end

	return model, body
end

return ItemModels
