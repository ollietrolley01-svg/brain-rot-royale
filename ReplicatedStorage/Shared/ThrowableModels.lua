-- Models for thrown items (grenades, smoke bombs) and the launcher rounds seen in flight, built from
-- parts.
--
-- Throwables follow ItemModels' contract exactly, because ItemModels hands them over here: built
-- facing -Z around the design origin, pivoting on it, a part named "Grip" where the hand goes, and
-- glowing parts named "Glow" (pulsed while the item is in use, and while a frag is cooking). So the
-- pickup on the map, the item in a player's hands, the first-person view, the HUD icon and the thing
-- flying through the air are all the same model.
--
--   ThrowableModels.Build(id, options)   (model, body) for a throwable item id, or nil.
--                                        options: scale (1), anchored (true), name ("HeldItem")
--   ThrowableModels.Round(kind, scale)   the model of a round in flight for ANY kind in
--                                        Ballistics.Rounds, nose along -Z, anchored, nothing
--                                        collides or queries. Never nil for a registered kind.
--   ThrowableModels.RoundBuilders[kind]  = function(b, look) -> body. A hand-built model for a kind,
--                                        registered from any module (rocket and grenade live here).
--
-- A round with no builder is drawn from its spec's `look`, the contract agreed with the creative
-- arsenal (Shared/CreativeRounds.lua mirrors it):
--   look = {
--     shape = "disc" | "slipper" | "toast" | "ball" | "box" | "cylinder",
--     size  = studs, the longest dimension,
--     color = Color3,            the main colour
--     trim  = Color3 (optional)  an accent: a strap band, a crust
--     glow  = Color3 (optional)  a neon accent: a disc's rim
--     spin  = "roll" | "flat" | "tumble" | "none" (optional)   how it turns in flight (Ballistics.RoundOrientation):
--             roll about its velocity; flat = level, spinning about the up axis like a frisbee;
--             tumble = a bouncing body's end-over-end; none = nose along its velocity.
--             Default: "tumble" for body motion, "none" otherwise.
--   }
-- A kind with no look, or a shape not listed, is a plain ball in `color` (or grey), so nothing is ever
-- invisible in flight.
--
-- Curved things are made of real curves: a pull ring is a torus of overlapping tangent segments with a
-- ball at every joint, and a tapering cup is thin slices whose radius steps by hundredths of a stud.
-- Every part is placed against the surface it belongs to; nothing floats beside its parent. Every
-- model runs through ZFight.Fix before its welds, the same net every other builder has, and the
-- geometry is meant to give it nothing to do: tools/projectile_probe.lua builds with the pass off and
-- reports any pair it would have touched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Ballistics = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Ballistics"))
local ItemData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemData"))
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local ThrowableModels = {}

-- kind -> function(b, look) -> body. Filled below with the rocket and the 40mm; other modules add
-- their own kinds.
ThrowableModels.RoundBuilders = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local STEEL = Color3.fromRGB(150, 156, 164)
local STEEL_DARK = Color3.fromRGB(78, 82, 90)
local BRASS = Color3.fromRGB(196, 158, 84)

-- A part builder bound to one model, one scale and one anchoring.
local function builder(model, scale, anchored)
	local b = {}

	function b.piece(name, size, cframe, color, material, shape, transparency)
		local part = Instance.new("Part")
		part.Name = name
		if shape then
			part.Shape = shape
		end
		local frame = typeof(cframe) == "Vector3" and CF(cframe) or cframe
		part.Size = size * scale
		part.CFrame = CF(frame.Position * scale) * frame.Rotation
		part.Color = color
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

	function b.ball(name, diameter, position, color, material, transparency)
		return b.piece(name, V(diameter, diameter, diameter), position, color, material, Enum.PartType.Ball, transparency)
	end

	-- A cylinder whose axis runs along the frame's own -Z (so CFrame.lookAt(a, b) runs it from a to b).
	function b.rod(name, length, diameter, frame, color, material, transparency)
		return b.piece(name, V(length, diameter, diameter), frame * ANG(0, math.pi / 2, 0), color, material, Enum.PartType.Cylinder, transparency)
	end

	-- An upright cylinder (axis along Y) centred at `position`.
	function b.column(name, height, diameter, position, color, material, transparency)
		local frame = typeof(position) == "Vector3" and CF(position) or position
		return b.piece(name, V(height, diameter, diameter), frame * ANG(0, 0, math.pi / 2), color, material, Enum.PartType.Cylinder, transparency)
	end

	-- A rod from one point to another, with a ball on each end so joined rods meet in a smooth elbow.
	function b.link(name, from, to, diameter, color, material)
		local length = (to - from).Magnitude
		b.rod(name, length, diameter, CFrame.lookAt((from + to) / 2, to), color, material)
		b.ball(name, diameter, from, color, material)
		b.ball(name, diameter, to, color, material)
	end

	-- A torus in the XY plane of `frame`: `segments` tangent rods joined by balls.
	function b.ring(name, frame, radius, tube, segments, color, material)
		local points = {}
		for index = 0, segments - 1 do
			local angle = index / segments * math.pi * 2
			table.insert(points, (frame * CF(math.cos(angle) * radius, math.sin(angle) * radius, 0)).Position)
		end
		for index, point in ipairs(points) do
			local nextPoint = points[index % segments + 1]
			b.rod(name, (nextPoint - point).Magnitude, tube, CFrame.lookAt((point + nextPoint) / 2, nextPoint), color, material)
			b.ball(name, tube, point, color, material)
		end
	end

	-- A frame on the surface of a sphere of `radius` round `centre`, at polar angle `theta` from +Y and
	-- azimuth `phi` from -Z toward +X, looking out along the surface normal (so a flat box sized
	-- (w, h, thin) lies on the surface), lifted `lift` off it.
	function b.onSphere(centre, radius, theta, phi, lift)
		local normal = V(math.sin(theta) * math.sin(phi), math.cos(theta), -math.sin(theta) * math.cos(phi))
		local position = centre + normal * (radius + (lift or 0))
		local up = math.abs(normal.Y) > 0.98 and -Vector3.zAxis or Vector3.yAxis
		return CFrame.lookAt(position, position + normal, up), normal
	end

	return b
end

local function finish(model, body, anchored)
	-- No two faces left flush, before the welds so only the one part moves. Built right, it finds
	-- nothing; the probe proves that with the pass off.
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

--------------------------------------------------------------------------------
-- Cooked Coconut
--------------------------------------------------------------------------------

-- A frag grenade grown on a palm. The husk is an egg of two overlapping spheres in hairy brown, with
-- darker fibre tufts set into it. The three eyes sit round the crown; the fuse is screwed into one of
-- them: a steel fuse body, the spoon lever running down the husk, and a pull ring with its pin. A
-- jagged crack across the front glows orange, the "cooked" part, and burns hotter while the fuse runs.
local function buildCoconut(b, color)
	local HUSK = Color3.fromRGB(112, 72, 42)
	local HUSK_DARK = Color3.fromRGB(78, 48, 28)
	local EYE = Color3.fromRGB(46, 30, 20)

	local centre = V(0, 0, 0)
	local R = 0.47
	local body = b.ball("Body", R * 2, centre, HUSK, Enum.Material.Fabric)
	-- The crown: a smaller sphere pushed up into the body makes the husk an egg, not a ball.
	local crownCentre = V(0, 0.13, 0.02)
	local crownR = 0.4
	b.ball("Husk", crownR * 2, crownCentre, HUSK, Enum.Material.Fabric)

	-- The husk's real outer surface in a direction from the centre: whichever of the two spheres
	-- reaches further that way. Everything laid on the husk uses this, so nothing ends up buried in the
	-- crown or hanging off the body where the crown bulges past it.
	local function husk(theta, phi, lift)
		local direction = V(math.sin(theta) * math.sin(phi), math.cos(theta), -math.sin(theta) * math.cos(phi))
		local along = direction:Dot(crownCentre)
		local crownReach = along + math.sqrt(math.max(0, along * along - crownCentre:Dot(crownCentre) + crownR * crownR))
		local point, normal
		if crownReach > R then
			point = direction * crownReach
			normal = (point - crownCentre).Unit
		else
			point = direction * R
			normal = direction
		end
		local position = point + normal * (lift or 0)
		local up = math.abs(normal.Y) > 0.98 and -Vector3.zAxis or Vector3.yAxis
		return CFrame.lookAt(position, position + normal, up), normal
	end

	-- The hairiness is the Fabric material's own weave: the husk needs no tufts (tufts were either
	-- mostly buried in the husk or stood proud of its outline).

	-- The three eyes round the top of the crown, 120 degrees apart. The fuse takes the front one.
	local eyeTheta = 0.42
	local fuseFrame, fuseNormal
	for index = 0, 2 do
		local phi = index / 3 * math.pi * 2
		local frame, normal = b.onSphere(crownCentre, crownR, eyeTheta, phi, -0.03)
		if index == 0 then
			fuseFrame, fuseNormal = frame, normal
		else
			b.ball("Eye", 0.11, frame.Position, EYE, Enum.Material.SmoothPlastic)
		end
	end

	-- The fuse: a threaded collar sunk into the eye, the fuse body, and the striker cap. All along the
	-- eye's own normal, so it stands straight out of the husk.
	local up = CFrame.lookAt(fuseFrame.Position, fuseFrame.Position + fuseNormal, Vector3.xAxis)
	-- `up` looks along the normal, so -Z is outward: positions below are along -Z.
	-- Each piece's end faces sit well clear (> 0.045) of the next piece's same-facing ends, so nothing
	-- in the stack z-fights.
	b.rod("FuseCollar", 0.1, 0.2, up * CF(0, 0, -0.03), BRASS, Enum.Material.Metal)
	b.rod("FuseBody", 0.2, 0.15, up * CF(0, 0, -0.15), STEEL, Enum.Material.Metal)
	b.rod("FuseCap", 0.08, 0.18, up * CF(0, 0, -0.27), STEEL_DARK, Enum.Material.Metal)
	b.ball("Striker", 0.1, (up * CF(0, 0, -0.335)).Position, STEEL_DARK, Enum.Material.Metal)

	-- The spoon lever: from the fuse head, bending over and down the husk's right side, pressed
	-- against it, clear of the crack on the front. Three flat plates, each ending where the next
	-- begins.
	local spoonStart = (up * CF(0.05, 0, -0.24)).Position
	local spoonPoints = { spoonStart }
	for _, spec in ipairs({ { 0.62, 0.72 }, { 1.0, 0.8 }, { 1.4, 0.86 } }) do
		local frame = husk(spec[1], spec[2], 0.015)
		table.insert(spoonPoints, frame.Position)
	end
	-- The plates meet end to end at each kink (a bend of ~20 degrees leaves a notch of a few
	-- thousandths at the outer edge, invisible); overlapping ends put two near-parallel faces a
	-- hair apart, which flickered.
	for index = 1, #spoonPoints - 1 do
		local from, to = spoonPoints[index], spoonPoints[index + 1]
		local mid = (from + to) / 2
		local _, outward = husk(math.acos(math.clamp(mid.Unit.Y, -1, 1)), math.atan2(mid.X, -mid.Z), 0)
		local frame = CFrame.lookAt(mid, to, outward)
		b.piece("Spoon", V(0.09, 0.025, (to - from).Magnitude), frame, STEEL, Enum.Material.Metal)
	end

	-- The pull ring hangs off the side of the fuse on its pin: a rod out of the fuse body whose end
	-- meets the ring's tube (no ball on that end: a ball there sat inside the ring).
	local pinFrom = (up * CF(-0.07, 0, -0.18)).Position
	local pinTo = (up * CF(-0.19, 0, -0.18)).Position
	local pinDirection = (pinTo - pinFrom).Unit
	b.rod("Pin", 0.12, 0.03, CFrame.lookAt((pinFrom + pinTo) / 2, pinTo), STEEL, Enum.Material.Metal)
	b.ball("Pin", 0.03, pinFrom, STEEL, Enum.Material.Metal)
	local ringCentre = pinTo + pinDirection * 0.1
	local ringFrame = CFrame.lookAt(ringCentre, ringCentre + (up.RightVector:Cross(fuseNormal)).Unit, fuseNormal)
	b.ring("PullRing", ringFrame, 0.1, 0.028, 14, STEEL, Enum.Material.Metal)

	-- The crack: a jagged split across the front of the husk. Each segment is a dark seam half sunk
	-- into the surface with a narrower strip of the item's orange passing right through it, standing
	-- 0.085 proud on top and buried below, glowing like heat through a split shell. At rest the glow
	-- is a deep ember; ProjectileClient brightens it as the fuse cooks. Every face of the strip is at
	-- least 0.07 from the seam's same-facing one (0.071 at the sides, 0.073 top and bottom, 0.08 at
	-- the ends): clear of ZFight.Tolerance (0.045) and of the pass's wider FixTolerance (0.055), so
	-- nothing z-fights and the pass has nothing to move. (At 0.048 the pairs passed the build scan
	-- but the pass still reshaped ten parts; a strip sunk flush inside the seam flickered and was
	-- hidden; a strip stood on top of it had its underside a hair off the seam's, which flickered too.)
	local EMBER = Color3.fromRGB(196, 74, 18)
	local crack = { { 1.02, -0.58 }, { 1.2, -0.34 }, { 1.1, -0.12 }, { 1.32, 0.1 }, { 1.22, 0.32 }, { 1.44, 0.56 } }
	local previous = nil
	for _, point in ipairs(crack) do
		local frame = husk(point[1], point[2], 0)
		if previous then
			local from, to = previous.Position, frame.Position
			local mid = (from + to) / 2
			local outward = (mid - centre).Unit
			-- The chord's middle dips inside the curve; lift the strip back to the surface there.
			local sag = R - mid.Magnitude
			local strip = CFrame.lookAt(mid + outward * sag, to + outward * sag, outward)
			local length = (to - from).Magnitude + 0.02
			b.piece("CrackSeam", V(0.17, 0.024, length), strip, Color3.fromRGB(40, 24, 14), Enum.Material.Fabric)
			b.piece("Glow", V(0.028, 0.17, length - 0.16), strip, EMBER, Enum.Material.Neon)
		end
		previous = frame
	end

	-- Held from underneath and behind.
	b.piece("Grip", V(0.2, 0.2, 0.2), V(0, -0.25, 0.2), HUSK, nil, nil, 1)
	return body
end

--------------------------------------------------------------------------------
-- Lowkey Latte
--------------------------------------------------------------------------------

-- A takeaway coffee that's actually a smoke canister. A paper cup narrowing to its base, a cardboard
-- sleeve with its LOWKEY label, a domed lid with a sip ridge, and through the sip hole a grey smoke
-- spout with a red pull tab. The steam-grey band round the lid is the "Glow".
local function buildLatte(b, color)
	local CUP = Color3.fromRGB(242, 238, 230)
	local SLEEVE = Color3.fromRGB(170, 122, 78)
	local LID = Color3.fromRGB(250, 249, 246)
	local INK = Color3.fromRGB(70, 46, 30)

	local HEIGHT = 1.06
	local BOTTOM, TOP = 0.3, 0.4 -- radii
	local SLICES = 8
	local base = -0.5
	local body = nil
	local sliceH = HEIGHT / SLICES
	local function radiusAt(y)
		return BOTTOM + (TOP - BOTTOM) * math.clamp((y - base) / HEIGHT, 0, 1)
	end
	for index = 0, SLICES - 1 do
		local y0 = base + index * sliceH
		-- Each slice reaches a little into the next, so there is no seam of daylight between them; its
		-- radius is the cup's at the slice's top, so the step outward is always on the upper face, hidden
		-- inside the slice above. (Adjacent slices' same-facing ends are a whole slice apart.)
		local slice = b.column(index == 0 and "Body" or "Cup", sliceH + 0.012, radiusAt(y0 + sliceH) * 2, V(0, y0 + sliceH / 2, 0), CUP, Enum.Material.SmoothPlastic)
		body = body or slice
	end

	-- The sleeve: three slices as tall as the cup's, a hair proud of it, with their seams exactly
	-- halfway between the cup's, so no flat face of the sleeve is within the z-fight tolerance of
	-- a flat face of the cup.
	local sleeveFrom = base + sliceH * 2.5
	local sleeveSlices = 3
	for index = 0, sleeveSlices - 1 do
		local y0 = sleeveFrom + index * sliceH
		b.column("Sleeve", sliceH + 0.01, (radiusAt(y0 + sliceH) + 0.022) * 2, V(0, y0 + sliceH / 2, 0), SLEEVE, Enum.Material.Cardboard)
	end
	local sleeveTo = sleeveFrom + sleeveSlices * sliceH
	-- The label on the front of the sleeve: narrow enough that its edges stay on the curve.
	local labelY = (sleeveFrom + sleeveTo) / 2
	local labelR = radiusAt(labelY) + 0.022
	local label = b.piece("Label", V(0.3, 0.2, 0.02), CF(0, labelY, -(labelR + 0.004)), Color3.fromRGB(246, 236, 214), Enum.Material.SmoothPlastic)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 160
	gui.LightInfluence = 1
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.FredokaOne
	text.Text = "lowkey"
	text.TextColor3 = INK
	text.TextScaled = true
	text.Parent = gui
	gui.Parent = label

	-- The lid: a snap rim over the cup's lip (it is the rolled lip too), a raised dome, the sip ridge
	-- and its hole. Every level's top sits at least 0.05 above the one below, so no two same-facing
	-- ends are within the z-fight tolerance; each piece's bottom rests on the top of the one below.
	local lidY = base + HEIGHT + 0.03
	b.column("LidRim", 0.08, TOP * 2 + 0.09, V(0, lidY, 0), LID, Enum.Material.SmoothPlastic)
	b.column("Lid", 0.07, TOP * 2 - 0.02, V(0, lidY + 0.07, 0), LID, Enum.Material.SmoothPlastic)
	b.column("LidDome", 0.07, TOP * 2 - 0.2, V(0, lidY + 0.14, 0), LID, Enum.Material.SmoothPlastic)
	b.piece("SipRidge", V(0.26, 0.06, 0.1), V(0, lidY + 0.205, -0.22), LID, Enum.Material.SmoothPlastic)

	-- The smoke spout standing on the sip ridge (its underside on the ridge's top, so no two
	-- same-facing ends in the lid stack are within the z-fight tolerance), its glowing tip (pulsed
	-- while the item is in use), and the pull tab on a wire that starts just outside the tip.
	b.column("Spout", 0.2, 0.1, V(0, lidY + 0.335, -0.22), STEEL_DARK, Enum.Material.Metal)
	b.column("Glow", 0.06, 0.13, V(0, lidY + 0.465, -0.22), color, Enum.Material.Neon)
	b.link("TabWire", V(0.082, lidY + 0.455, -0.22), V(0.17, lidY + 0.42, -0.22), 0.025, STEEL, Enum.Material.Metal)
	b.piece("PullTab", V(0.12, 0.09, 0.02), CF(0.25, lidY + 0.4, -0.22) * ANG(0, 0, -0.2), Color3.fromRGB(214, 52, 48), Enum.Material.SmoothPlastic)

	b.piece("Grip", V(0.2, 0.2, 0.2), V(0, -0.05, 0.25), CUP, nil, nil, 1)
	return body
end

--------------------------------------------------------------------------------
-- Clingy Crumpet
--------------------------------------------------------------------------------

-- A sticky bomb baked as a crumpet: a golden toasted disc pocked with bubble holes on top, a fat
-- blob of jam underneath that oozes past the rim (the sticky face), and a brass timer screwed into
-- the middle of the top with a neon ring round its crown and a button cap: the "Glow", pulsed
-- faster and faster while it's armed. Origin at the disc's centre; the jam's underside is
-- stickOffset (0.2) below it, which is what the stuck frame and the placement ghost stand on.
--
-- Nothing here shares a plane with anything it overlaps: the holes stand 0.07 proud of the top
-- (past the pass's 0.055), the inner three sit in the band between the timer and the outer ring
-- without touching either's footprint, and the jam disc hangs 0.09 below the body.
local function buildCrumpet(b, color)
	local TOAST = Color3.fromRGB(232, 186, 104)
	local TOAST_DARK = Color3.fromRGB(168, 118, 60)
	local EMBER = Color3.fromRGB(255, 70, 60)
	local body = b.column("Body", 0.22, 0.8, V(0, 0, 0), TOAST, Enum.Material.Sand)
	for index = 0, 8 do
		local angle = index / 9 * math.pi * 2 + 0.2
		local r = 0.27 + (index % 2) * 0.04
		b.column("Hole", 0.07, 0.07 + (index % 3) * 0.015, V(math.cos(angle) * r, 0.145, math.sin(angle) * r), TOAST_DARK, Enum.Material.SmoothPlastic)
	end
	for index = 0, 2 do
		local angle = index / 3 * math.pi * 2 + 1.1
		b.column("Hole", 0.07, 0.06, V(math.cos(angle) * 0.185, 0.145, math.sin(angle) * 0.185), TOAST_DARK, Enum.Material.SmoothPlastic)
	end
	local jam = b.column("Jam", 0.09, 0.62, V(0, -0.155, 0), color, Enum.Material.SmoothPlastic)
	jam.Reflectance = 0.22
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + 0.6
		local blob = b.ball("Jam", 0.13 + (index % 2) * 0.03, V(math.cos(angle) * 0.36, -0.13, math.sin(angle) * 0.36), color, Enum.Material.SmoothPlastic)
		blob.Reflectance = 0.22
	end
	b.column("Timer", 0.1, 0.3, V(0, 0.16, 0), BRASS, Enum.Material.Metal)
	b.ring("Glow", CF(0, 0.21, 0) * ANG(math.pi / 2, 0, 0), 0.12, 0.03, 12, EMBER, Enum.Material.Neon)
	b.ball("Glow", 0.09, V(0, 0.22, 0), EMBER, Enum.Material.Neon)
	-- Held by the rim, timer up.
	b.piece("Grip", V(0.2, 0.2, 0.2), V(0, 0, 0.28), TOAST, nil, nil, 1)
	return body
end

-- Every throwable's builder, registered here in the literal: verify.py reads this table's body.
local BUILDERS = {
	CookedCoconut = buildCoconut,
	LowkeyLatte = buildLatte,
	ClingyCrumpet = buildCrumpet,
}
ThrowableModels.Builders = BUILDERS

function ThrowableModels.Build(id, options)
	options = options or {}
	local item = ItemData.Get(id)
	local build = BUILDERS[id]
	if not build then
		return nil
	end
	local anchored = options.anchored ~= false
	local model = Instance.new("Model")
	model.Name = options.name or "HeldItem"
	model:SetAttribute("ItemId", id)
	local b = builder(model, options.scale or 1, anchored)
	local color = item and item.color or (id == "CookedCoconut" and Color3.fromRGB(255, 140, 50) or Color3.fromRGB(170, 180, 190))
	local body = build(b, color)
	return finish(model, body, anchored)
end

--------------------------------------------------------------------------------
-- Rounds in flight
--------------------------------------------------------------------------------

local MM = 0.0038 -- studs per millimetre, the guns' own scale (GunModels.StudsPerMillimetre)

-- The PG-7V the Cappuccina Launcher shows standing out of its muzzle, now whole: fuse and nose cone,
-- the fat warhead in olive with its yellow band, the booster, and the sustainer motor behind it with
-- four fins and the nozzle ring. Proportions from the loaded round in GunModels, lengths in mm.
local function buildRocket(b)
	local OLIVE = Color3.fromRGB(84, 96, 70)
	local WARNING = Color3.fromRGB(230, 190, 40)
	local MOTOR = Color3.fromRGB(62, 66, 60)
	local along = CFrame.identity
	local function seg(name, lengthMm, diameterMm, zMm, color, material)
		return b.rod(name, lengthMm * MM, diameterMm * MM, along * CF(0, 0, zMm * MM), color, material)
	end
	-- z is the centre of each piece; the nose points to -Z.
	b.ball("Tip", 16 * MM, V(0, 0, -300 * MM), STEEL)
	seg("Fuse", 20, 16, -290, STEEL, Enum.Material.Metal)
	seg("Cone", 30, 30, -265, OLIVE)
	seg("Cone", 36, 50, -232, OLIVE)
	seg("Cone", 36, 70, -196, OLIVE)
	local body = seg("Body", 120, 85, -118, OLIVE)
	-- The band sits mid-warhead and the fins end 17 mm short of the motor's rear: at this scale a
	-- ring 4 mm from a cylinder's end, or a fin ending 1 mm from it, is a pair of near-coplanar faces
	-- the z-fight pass would reshape (measured: 6 of 14 parts touched before this).
	seg("Band", 8, 86.5, -118, WARNING)
	seg("Booster", 60, 38, -28, OLIVE)
	seg("Motor", 360, 40, 182, MOTOR, Enum.Material.Metal)
	seg("NozzleRing", 24, 50, 372, STEEL_DARK, Enum.Material.Metal)
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		b.piece("Fin", V(1.5 * MM, 60 * MM, 90 * MM), CFrame.Angles(0, 0, angle) * CF(0, 48 * MM, 300 * MM), MOTOR, Enum.Material.Metal)
	end
	return body
end

-- A 40mm grenade: a round-nosed olive projectile, the copper driving band, the aluminium case base.
local function buildGrenade(b)
	local OLIVE = Color3.fromRGB(84, 96, 70)
	local COPPER = Color3.fromRGB(184, 110, 70)
	local ALU = Color3.fromRGB(176, 180, 186)
	-- Every flat face here is 17 mm or more from the next same-facing one (the pass's 0.055 studs is
	-- 14.5 mm): band mid-body, base butted to the body's rear and 20 mm long.
	b.ball("Nose", 40 * MM, V(0, 0, -16 * MM), OLIVE)
	local body = b.rod("Body", 40 * MM, 40 * MM, CF(0, 0, 0), OLIVE)
	b.rod("Band", 6 * MM, 41.5 * MM, CF(0, 0, 0), COPPER, Enum.Material.Metal)
	b.rod("Base", 20 * MM, 38 * MM, CF(0, 0, 30 * MM), ALU, Enum.Material.Metal)
	return body
end

ThrowableModels.RoundBuilders.rocket = buildRocket
ThrowableModels.RoundBuilders.grenade = buildGrenade

--------------------------------------------------------------------------------
-- Rounds drawn from a `look`
--------------------------------------------------------------------------------

local GREY = Color3.fromRGB(150, 150, 154)

-- A flying disc: a flat body with a raised hub, and a glowing rim ring. Level in flight (spin "flat").
local function lookDisc(b, look)
	local s = look.size or 0.9
	local color = look.color or GREY
	local body = b.piece("Body", V(0.1, s, s), CF(0, 0, 0) * ANG(0, 0, math.pi / 2), color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	b.piece("Hub", V(0.06, s * 0.36, s * 0.36), CF(0, 0.08, 0) * ANG(0, 0, math.pi / 2), color, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
	b.ball("HubCap", s * 0.16, V(0, 0.1, 0), look.trim or color, Enum.Material.SmoothPlastic)
	-- The rim: a torus in the horizontal plane, a hair below the top face.
	b.ring("Glow", CF(0, 0.02, 0) * ANG(math.pi / 2, 0, 0), s / 2 - 0.02, 0.06, 18, look.glow or look.trim or color, Enum.Material.Neon)
	return body
end

-- A slipper, toe along -Z: a sole with rounded ends and a heel lift, a strap over the instep in the
-- trim colour, and a pom on the toe.
local function lookSlipper(b, look)
	local s = look.size or 1.1
	local color = look.color or GREY
	local trim = look.trim or Color3.fromRGB(250, 245, 240)
	local width, thick = s * 0.42, 0.14
	local body = b.piece("Body", V(width, thick, s * 0.7), CF(0, 0, 0), color, Enum.Material.Fabric)
	b.ball("Toe", width, V(0, 0, -s * 0.35), color, Enum.Material.Fabric)
	b.ball("Heel", width, V(0, 0, s * 0.35), color, Enum.Material.Fabric)
	-- Standing on the sole (its underside on the sole's top) and ending 0.07 s short of the heel end,
	-- so its rear face and the sole's aren't a near-coplanar pair.
	b.piece("HeelLift", V(width * 0.9, thick, s * 0.16), CF(0, thick, s * 0.2), color, Enum.Material.Fabric)
	-- The strap: three plates arching over the instep.
	for index, spec in ipairs({ { -0.9, 0.12 }, { 0, 0.22 }, { 0.9, 0.12 } }) do
		local x = spec[1] * width * 0.42
		b.piece("Strap", V(width * 0.4, 0.05, s * 0.3), CF(x, thick / 2 + spec[2], -s * 0.02) * ANG(0, 0, -spec[1] * 0.75), trim, Enum.Material.Fabric)
		if index == 2 then
			b.ball("Pom", width * 0.5, V(0, thick / 2 + 0.28, -s * 0.22), trim, Enum.Material.Fabric)
		end
	end
	return body
end

-- A slice of toast, face along -Z: a square with two rounded lobes on top, a darker crust round the
-- edge, and a couple of grill scores. Laid out so no two same-facing faces sit within 0.07 of each
-- other with any overlap: the body stops at the shoulder where the lobes begin, the crust is as
-- thick as the body and stands outside its edges rather than over its faces, and the scores are
-- raised bars, 0.07 proud of the face (a 0.02 plate on a face is exactly what the pass reshapes;
-- measured before this: 21 flush pairs, 10 moved and 14 resized of 8 parts).
local function lookToast(b, look)
	local s = look.size or 0.8
	local color = look.color or GREY
	local crust = look.trim or color:Lerp(Color3.new(0, 0, 0), 0.35)
	local thick = 0.16
	local bottom, shoulder = -s * 0.45, s * 0.06
	local height = shoulder - bottom
	local body = b.piece("Body", V(s, height, thick), CF(0, (bottom + shoulder) / 2, 0), color, Enum.Material.SmoothPlastic)
	-- Discs, not balls: a Ball part is drawn at its smallest dimension, so a flattened one is a dot.
	-- Each lobe starts a hair below the shoulder, so no seam shows and the coplanar faces share no
	-- more than that hair.
	for _, x in ipairs({ -s * 0.26, s * 0.26 }) do
		b.rod("Lobe", thick, s * 0.48, CF(x, shoulder + s * 0.24 - 0.004, 0), color, Enum.Material.SmoothPlastic)
	end
	b.piece("Crust", V(s + 0.14, 0.07, thick), CF(0, bottom - 0.035, 0), crust, Enum.Material.SmoothPlastic)
	for _, x in ipairs({ -(s / 2 + 0.035), s / 2 + 0.035 }) do
		b.piece("Crust", V(0.07, height, thick), CF(x, (bottom + shoulder) / 2, 0), crust, Enum.Material.SmoothPlastic)
	end
	for _, y in ipairs({ -s * 0.2, 0 }) do
		b.piece("Score", V(s * 0.7, 0.05, 0.07), CF(0, y, -thick / 2 - 0.035), crust, Enum.Material.SmoothPlastic)
	end
	return body
end

local LOOKS = {
	disc = lookDisc,
	slipper = lookSlipper,
	toast = lookToast,
	ball = function(b, look)
		return b.ball("Body", look.size or 0.5, V(0, 0, 0), look.color or GREY, Enum.Material.SmoothPlastic)
	end,
	box = function(b, look)
		local s = look.size or 0.6
		return b.piece("Body", V(s * 0.6, s * 0.6, s), CF(0, 0, 0), look.color or GREY, Enum.Material.SmoothPlastic)
	end,
	cylinder = function(b, look)
		local s = look.size or 0.6
		return b.rod("Body", s, s * 0.4, CF(0, 0, 0), look.color or GREY, Enum.Material.SmoothPlastic)
	end,
}

function ThrowableModels.Round(kind, scale)
	local model = Instance.new("Model")
	model.Name = "BRR_Round"
	local b = builder(model, scale or 1, true)
	local spec = Ballistics.Rounds[kind]
	local look = spec and spec.look or nil
	local build = ThrowableModels.RoundBuilders[kind] or (look and LOOKS[look.shape]) or LOOKS.ball
	local body = build(b, look or {})
	for _, part in ipairs(model:GetChildren()) do
		part.CastShadow = false
	end
	return finish(model, body, true)
end

-- The spin a kind turns with in flight: its look's, else "tumble" for a bouncing body, "none" otherwise.
function ThrowableModels.SpinOf(kind)
	local spec = Ballistics.Rounds[kind]
	if not spec then
		return "none"
	end
	if spec.look and spec.look.spin then
		return spec.look.spin
	end
	return (spec.motion == "body") and "tumble" or "none"
end

return ThrowableModels
