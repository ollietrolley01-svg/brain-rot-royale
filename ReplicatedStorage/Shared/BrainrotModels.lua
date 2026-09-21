-- Builds brainrot creatures from the `look` specs in BrainrotData.
--
-- Shared by the server (companions that follow you, podium displays, town statues) and the
-- client (the inventory's photos and the crate reveal), so a brainrot looks the same everywhere.
-- Every creature is assembled from primitive parts — a body shape, a face and a handful of
-- extras — so there are no uploaded meshes or images to load.
--
--   bodies   Blob Bean Cube Pear Disc Stack Egg Mushroom Cloud Can Cone Ghost Loaf Totem
--   eyes     Round Sleepy Angry Worried Big Wink Hearts Stars Goggles Triple Cyclops Visor Dots
--   mouths   Smile Grin O Fangs Tongue Beak Teeth Frown Wavy Tusks None
--   extras   Horns Antenna Ears Wings Crown Halo Tail Feet Arms Cap Spikes Leaf Propeller Bow
--            Mustache Shades Scarf Flame Orbit Antlers Fins Tentacles TopHat Headphones Cape
--            Monocle Beard Petals Gem Spots Stripes Blush Unicorn Whiskers Helmet Bolt Shell Tie
--            WizardHat Nightcap Nemes Battlements ButterflyWings Pixels Porthole Knobs Accretion
--            Rainbow Sprinkles ToastSlots Spout Cherry Nori Topknot Drips Bun Fries Flower Tears
--            Nose Mortarboard Beret Stinger Plume Lamp Humps Handle Backpack Panel Exhaust Surfboard
--            Flaps GumBubble Raindrops Bubbles Stink Noodles Fork Umbrella Eggshell InsectLegs
--            Buttonholes Drupelets TailFin Folds SpiderLegs Drum NinjaBand BatWings Quills Claws
--            Zigzag Cracks Mane Ribs
--
-- `look.spotColor` recolours Spots (a white-spotted red mushroom cap, say); otherwise they use
-- the accent colour. `look.iris` sets the eye colour; otherwise it comes from the accent.
-- `look.belly` colours the pale belly patch, `look.faceGlow` lights the pupils and mouth from
-- inside in that colour (a carved lantern), and `look.reflectance` makes the body mirror-bright.
--
-- Placement. The body is built first and every one of its primitives is remembered, so the face,
-- the limbs and whatever is worn can be put on the surface that is really there: a ray is cast
-- at the recorded shapes (ellipsoid, ball, cylinder or box, solved exactly) rather than guessing
-- from the metrics. Faces are placed the same on both sides of the centre line, so a lopsided
-- body still gets a symmetric face.
--
-- Fine detail (eyes, mouths, hands, feathers) is made of balls and sphere-meshed blocks. Those
-- have no flat faces, so the z-fight passes — the builder's own, and the lobby-wide and map-wide
-- ones every statue goes through again — have nothing to nudge on them. Parallel flat faces also
-- need to stay more than 0.1 stud apart: the passes work to a fixed 0.055-stud tolerance, so at the
-- companion scale of 0.55 anything closer than that gets pushed about.
--
-- Two attributes tell the model audits what is deliberate, so their counts mean something:
--   IntentionalFloat      a part that hovers clear of the body on purpose (orbiting motes, a halo,
--                         a gem, lightning, pixel shards, an accretion ring, raindrops, bubbles).
--                         Set it with `floating(...)`.
--   IntentionalAsymmetry  scatter that is deliberately not mirrored (sprinkles, fries, quills, the
--                         tilted ring, stink lines, noodles, drips, a flower to one side, eggshell
--                         shards, a zigzag band, lava cracks). Set it with `scattered(...)`.
-- Anything left in the audits' floating or mirror counts is then a real mistake.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local BrainrotModels = {}

-- Your own art: a Model in ReplicatedStorage.BrainrotModelOverrides named exactly after a
-- brainrot is used for that brainrot everywhere instead of the part-built creature — scaled to
-- the same size, given the same invisible Root, glow and physics setup. Use models you made or
-- have the rights to.
local OVERRIDE_FOLDER = "BrainrotModelOverrides"
local OVERRIDE_HEIGHT = 2.6

local WHITE = Color3.fromRGB(250, 250, 250)
local BLACK = Color3.fromRGB(22, 22, 26)
local GOLD = Color3.fromRGB(255, 200, 60)
local LEAF = Color3.fromRGB(86, 170, 70)
local PINK = Color3.fromRGB(255, 96, 150)
local BLUSH = Color3.fromRGB(255, 140, 160)
local BROWN = Color3.fromRGB(140, 100, 64)
local IVORY = Color3.fromRGB(250, 244, 222)
local BEAK = Color3.fromRGB(255, 170, 50)
local EYE_WHITE = Color3.fromRGB(248, 248, 244)
local PUPIL = Color3.fromRGB(16, 14, 22)
local MOUTH = Color3.fromRGB(58, 24, 34)
local MOUTH_IN = Color3.fromRGB(92, 32, 46)
local TONGUE = Color3.fromRGB(238, 108, 128)
local NEON = Enum.Material.Neon
local GLASS = Enum.Material.Glass

-- Where things attach on each body shape: head top, face height and depth, half-width, base,
-- and the half-width at face height (`sideW`) for things worn at the sides of the head.
-- Characters face -Z, so the face sits on the negative-Z side.
local BODIES = {
	Blob = { top = 1.0, faceY = 0.15, faceZ = -1.05, halfW = 1.2, bottom = -1.0, sideW = 1.15 },
	Bean = { top = 1.6, faceY = 0.5, faceZ = -0.88, halfW = 0.9, bottom = -1.6, sideW = 0.9 },
	Cube = { top = 1.1, faceY = 0.2, faceZ = -1.1, halfW = 1.1, bottom = -1.1, sideW = 1.1, boxy = true },
	Pear = { top = 1.55, faceY = 0.85, faceZ = -0.72, halfW = 1.2, bottom = -1.2, sideW = 0.8 },
	Disc = { top = 0.9, faceY = 0.3, faceZ = -0.85, halfW = 1.5, bottom = -0.7, sideW = 0.9 },
	Stack = { top = 1.55, faceY = 0.85, faceZ = -0.72, halfW = 1.0, bottom = -1.5, sideW = 0.75 },
	Egg = { top = 1.4, faceY = 0.35, faceZ = -0.97, halfW = 1.0, bottom = -1.4, sideW = 1.0 },
	Mushroom = { top = 1.3, faceY = -0.6, faceZ = -0.64, halfW = 1.5, bottom = -1.3, sideW = 0.65, round = true },
	Cloud = { top = 1.55, faceY = 0.15, faceZ = -0.9, halfW = 1.8, bottom = -1.0, sideW = 0.95 },
	Can = { top = 1.2, faceY = 0.3, faceZ = -1.02, halfW = 1.0, bottom = -1.2, sideW = 1.0, round = true },
	Cone = { top = 1.65, faceY = -0.05, faceZ = -0.94, halfW = 1.2, bottom = -1.3, sideW = 0.95 },
	Ghost = { top = 1.4, faceY = 0.45, faceZ = -0.95, halfW = 1.0, bottom = -1.45, sideW = 1.0 },
	Loaf = { top = 1.25, faceY = 0.1, faceZ = -1.03, halfW = 1.5, bottom = -0.75, sideW = 1.5, boxy = true },
	Totem = { top = 2.2, faceY = 0.5, faceZ = -0.75, halfW = 1.0, bottom = -1.9, sideW = 0.8 },
}

function BrainrotModels.Metrics(def)
	local look = def and def.look or {}
	return BODIES[look.body] or BODIES.Blob
end

-- options:
--   scale     multiplier on top of the look's own size (default 1)
--   anchored  default true; false welds everything to the root for physics-driven followers
--   cframe    where the creature's centre goes (default origin)
--   glow      Color3 for a soft PointLight, or nil
--   rig       (with anchored = false) weld into posable groups for CompanionAnimations
local function buildOverride(source, def, options)
	local look = def.look or {}
	local scale = (options.scale or 1) * (look.size or 1)
	local anchored = options.anchored ~= false

	local model = source:Clone()
	model.Name = def.name or source.Name
	local parts = {}
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			table.insert(parts, descendant)
		elseif descendant:IsA("JointInstance") or descendant:IsA("WeldConstraint") then
			descendant:Destroy()
		end
	end
	if #parts == 0 then
		model:Destroy()
		return nil
	end

	-- Centre it on an invisible Root at the origin, then scale it to a creature's height.
	local boxCFrame, boxSize = model:GetBoundingBox()
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(0.4, 0.4, 0.4)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Massless = true
	root.CFrame = CFrame.new(boxCFrame.Position)
	root.Parent = model
	model.PrimaryPart = root
	model:PivotTo(CFrame.new())
	model:ScaleTo(math.max(0.01, OVERRIDE_HEIGHT / math.max(boxSize.Y, 0.1)) * scale)
	model:PivotTo(options.cframe or CFrame.new())

	if options.glow then
		local light = Instance.new("PointLight")
		light.Color = options.glow
		light.Range = 10 * scale
		light.Brightness = 1.4
		light.Parent = root
	end

	if not anchored then
		for _, part in ipairs(parts) do
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
		root.Anchored = false
	end
	return model
end

-- Sparkle settings per rarity for the flair below; anything not listed gets none.
local FLAIR = {
	Legendary = { rate = 3, size = 1 },
	Mythic = { rate = 7, size = 1.2 },
	Secret = { rate = 14, size = 1.5 },
}

--------------------------------------------------------------------------------
-- Ray casts against primitive shapes, in the shape's own frame. Each returns the distance along
-- a unit ray to where it enters the shape, or nil for a miss (or a ray starting inside).
--------------------------------------------------------------------------------

local function hitEllipsoid(o, d, a, b, c)
	local ox, oy, oz = o.X / a, o.Y / b, o.Z / c
	local dx, dy, dz = d.X / a, d.Y / b, d.Z / c
	local qa = dx * dx + dy * dy + dz * dz
	local qb = 2 * (ox * dx + oy * dy + oz * dz)
	local qc = ox * ox + oy * oy + oz * oz - 1
	local disc = qb * qb - 4 * qa * qc
	if qa < 1e-12 or disc < 0 then
		return nil
	end
	local t = (-qb - math.sqrt(disc)) / (2 * qa)
	return t >= 0 and t or nil
end

local function hitBox(o, d, hx, hy, hz)
	local near, far = -math.huge, math.huge
	for _, axis in ipairs({ { o.X, d.X, hx }, { o.Y, d.Y, hy }, { o.Z, d.Z, hz } }) do
		local p, v, h = axis[1], axis[2], axis[3]
		if math.abs(v) < 1e-9 then
			if math.abs(p) > h then
				return nil
			end
		else
			local t1, t2 = (-h - p) / v, (h - p) / v
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			near, far = math.max(near, t1), math.min(far, t2)
			if near > far then
				return nil
			end
		end
	end
	return near >= 0 and near or nil
end

-- A Roblox cylinder runs along its X axis.
local function hitCylinder(o, d, halfLength, radius)
	local best = nil
	local qa = d.Y * d.Y + d.Z * d.Z
	if qa > 1e-12 then
		local qb = 2 * (o.Y * d.Y + o.Z * d.Z)
		local qc = o.Y * o.Y + o.Z * o.Z - radius * radius
		local disc = qb * qb - 4 * qa * qc
		if disc >= 0 then
			local t = (-qb - math.sqrt(disc)) / (2 * qa)
			if t >= 0 and math.abs(o.X + t * d.X) <= halfLength then
				best = t
			end
		end
	end
	if math.abs(d.X) > 1e-9 then
		for _, sign in ipairs({ -1, 1 }) do
			local t = (sign * halfLength - o.X) / d.X
			if t >= 0 and (best == nil or t < best) then
				local y, z = o.Y + t * d.Y, o.Z + t * d.Z
				if y * y + z * z <= radius * radius then
					best = t
				end
			end
		end
	end
	return best
end

local function hitShape(shape, origin, direction)
	local o = shape.cframe:PointToObjectSpace(origin)
	local d = shape.cframe:VectorToObjectSpace(direction)
	local s = shape.size
	if shape.kind == "Ball" then
		local r = math.min(s.X, s.Y, s.Z) / 2
		return hitEllipsoid(o, d, r, r, r)
	elseif shape.kind == "Sphere" then
		return hitEllipsoid(o, d, s.X / 2, s.Y / 2, s.Z / 2)
	elseif shape.kind == "Cylinder" then
		return hitCylinder(o, d, s.X / 2, math.min(s.Y, s.Z) / 2)
	end
	return hitBox(o, d, s.X / 2, s.Y / 2, s.Z / 2)
end

-- An iris colour that reads against both the eye white and the body: the accent's hue, deepened;
-- a soft slate for accents too grey or dark to carry one.
local function irisFor(look)
	if look.iris then
		return look.iris
	end
	local accent = look.accent or look.color
	if accent then
		local h, s, v = accent:ToHSV()
		if s >= 0.28 and v >= 0.25 then
			return Color3.fromHSV(h, math.clamp(s * 1.1, 0.45, 0.9), math.clamp(v * 0.72, 0.32, 0.62))
		end
	end
	return Color3.fromRGB(86, 112, 146)
end

-- Stacked bodies nod their top half on its own in a companion rig; the neck is where it splits.
-- Kept in step with CompanionAnimations.Neck.
local CompanionNeck = { Pear = 0.3, Stack = 0.2, Totem = -0.16 }

-- Arm poses by attack: where the elbow sits from the shoulder, and the hand from the elbow, for the
-- right arm (the left mirrors it). Bonkers flex, throwers hold one up, the rest let them hang.
local ARM_POSES = {
	Hang = { elbow = Vector3.new(0.3, -0.24, -0.05), hand = Vector3.new(0.06, -0.3, -0.16) },
	Flex = { elbow = Vector3.new(0.36, -0.1, -0.04), hand = Vector3.new(-0.02, 0.34, -0.14) },
	Ready = { elbow = Vector3.new(0.28, -0.2, -0.16), hand = Vector3.new(-0.06, -0.08, -0.3) },
}
local POSE_FOR_ATTACK = { Bonk = "Flex", Shockwave = "Flex", Lob = "Ready", Zap = "Ready", Chain = "Ready" }

function BrainrotModels.Build(def, options)
	options = options or {}

	local overrides = ReplicatedStorage:FindFirstChild(OVERRIDE_FOLDER)
	local source = overrides and def.name and overrides:FindFirstChild(def.name)
	if source and source:IsA("Model") then
		local custom = buildOverride(source, def, options)
		if custom then
			return custom
		end
	end

	local look = def.look or {}
	local scale = (options.scale or 1) * (look.size or 1)
	local origin = options.cframe or CFrame.new()
	local anchored = options.anchored ~= false
	local body = BODIES[look.body] and look.body or "Blob"
	local metrics = BODIES[body]
	local color = look.color or Color3.fromRGB(200, 200, 200)
	local accent = look.accent or color
	local material = look.material or Enum.Material.SmoothPlastic

	local model = Instance.new("Model")
	model.Name = def.name or "Brainrot"

	-- While the body is being built its shapes are recorded here, for the surface casts below.
	local recorded = nil
	-- Which rig group each part belongs to (arms, feet, wings and tail move on their own).
	local groupOf = {}
	local group = "Body"
	-- Where each moving group's joint sits (shoulder, hip, wing root, tail base), unscaled.
	local pivotAt = {}

	local function add(name, size, offset, partColor, partMaterial, shape, transparency)
		local part = Instance.new("Part")
		part.Name = name
		if shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
		-- Foil renders as crumpled tinfoil on anything this size; the shine it meant is a glossy
		-- smooth surface.
		local shiny = partMaterial == Enum.Material.Foil
		if shiny then
			partMaterial = Enum.Material.SmoothPlastic
		end
		part.Size = size * scale
		part.CFrame = origin * CFrame.new(offset.Position * scale) * offset.Rotation
		part.Color = partColor
		part.Material = partMaterial or Enum.Material.SmoothPlastic
		part.Transparency = transparency or 0
		if shiny then
			part.Reflectance = 0.12
		end
		part.Anchored = anchored
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CastShadow = part.Material ~= NEON
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		if shape == "Sphere" then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = part
		end
		if recorded then
			table.insert(recorded, { kind = shape or "Block", cframe = offset, size = size })
			if look.reflectance then
				part.Reflectance = look.reflectance
			end
		end
		groupOf[part] = group
		part.Parent = model
		return part
	end

	-- Upright cylinder centred at (x, y, z). Cylinder parts run along X, hence the quarter turn.
	local function column(name, height, diameter, x, y, z, partColor, partMaterial)
		return add(name, Vector3.new(height, diameter, diameter),
			CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.pi / 2), partColor, partMaterial, "Cylinder")
	end

	-- Cylinder running from point a to point b.
	local function rod(name, a, b, diameter, partColor, partMaterial)
		return add(name, Vector3.new((b - a).Magnitude, diameter, diameter),
			CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0), partColor, partMaterial, "Cylinder")
	end

	-- A rounded limb segment from a to b: an ellipsoid stretched along the segment, overlapping its
	-- neighbours so a run of them reads as one smooth tapering shape (tails, tentacles, horns).
	-- `up` (optional) is which way `depth` faces; by default up, or forward for an upright segment.
	local function capsule(name, a, b, width, partColor, partMaterial, depth, up)
		local along = b - a
		local length = along.Magnitude
		local frame = length > 1e-3 and CFrame.lookAt((a + b) / 2, b, up or (math.abs(along.Unit.Y) > 0.95 and Vector3.zAxis or Vector3.yAxis))
			or CFrame.new(a)
		return add(name, Vector3.new(width, depth or width, length + width * 0.9), frame, partColor, partMaterial, "Sphere")
	end

	-- Parts meant to hover clear of the body (orbiting motes, halos, sparks) say so, and the model
	-- audits leave them out of their floating checks.
	local function floating(part)
		part:SetAttribute("IntentionalFloat", true)
		return part
	end

	-- Scatter that is deliberately not mirrored (sprinkles, fries, quills, a flower to one side), so
	-- the audits' symmetry check doesn't read it as sloppy work.
	local function scattered(part)
		part:SetAttribute("IntentionalAsymmetry", true)
		return part
	end

	-- A disc facing forward (-Z), for goggle rims, lenses and the like.
	local function faceDisc(name, thickness, diameter, x, y, z, partColor, partMaterial, transparency)
		return add(name, Vector3.new(thickness, diameter, diameter), CFrame.new(x, y, z) * CFrame.Angles(0, math.pi / 2, 0),
			partColor, partMaterial, "Cylinder", transparency)
	end

	local function capsuleShape(name, a, b, width, partColor)
		return capsule(name, a, b, width, partColor, material)
	end

	-- Invisible centre, so every body shape pivots from the same point.
	local root = add("Root", Vector3.new(0.4, 0.4, 0.4), CFrame.new(), color, nil, nil, 1)
	model.PrimaryPart = root

	local top, halfW, bottom = metrics.top, metrics.halfW, metrics.bottom
	local sideW = metrics.sideW or halfW
	local midY = (top + bottom) / 2
	local fy, fz = metrics.faceY, metrics.faceZ
	local back = -fz
	local radiusY = (top - bottom) / 2

	-- The front surface at sideways offset x and height y, treating the body as an ellipsoid
	-- (or a flat front for boxy bodies). Only a fallback now, for rays that miss the body.
	local function frontZ(x, y)
		if metrics.boxy then
			return fz
		end
		local nx = x / math.max(sideW, 0.1)
		local ny = metrics.round and 0 or (y - midY) / radiusY
		return -back * math.sqrt(math.max(0.05, 1 - nx * nx - ny * ny))
	end

	--------------------------------------------------------------------------
	-- Body
	--------------------------------------------------------------------------

	-- Shading. A creature built from two flat-coloured primitives reads as two primitives; giving
	-- every shape a lit crown, a shaded underside and a seam or band where its masses meet is what
	-- makes it read as one solid thing. These stay strictly inside the body's envelope — the
	-- metrics table above is what the face and all 38 extras attach to, so nothing here may push
	-- past `top`, `bottom` or `halfW`, or creatures float, sink or wear their hats crooked.
	local shade = function(amount)
		return color:Lerp(BLACK, amount)
	end
	local lit = function(amount)
		return color:Lerp(WHITE, amount)
	end
	-- A ring of small masses round the body at a height, for seams, gill rims and segment joins.
	local function ring(name, count, radius, y, thickness, ringColor, ringMaterial)
		for index = 0, count - 1 do
			local angle = index / count * math.pi * 2
			add(name, Vector3.new(thickness, thickness, thickness),
				CFrame.new(math.cos(angle) * radius, y, math.sin(angle) * radius), ringColor, ringMaterial, "Ball")
		end
	end
	-- Pale belly patches are laid on the finished surface further down, so they hug it instead of
	-- standing out as a shelf in front of the mouth.
	local bellies = {}

	recorded = {}
	if body == "Bean" then
		column("Body", 1.4, 1.8, 0, 0, 0, color, material)
		add("BodyTop", Vector3.new(1.8, 1.8, 1.8), CFrame.new(0, 0.7, 0), color, material, "Ball")
		add("BodyBottom", Vector3.new(1.8, 1.8, 1.8), CFrame.new(0, -0.7, 0), color, material, "Ball")
		add("Crown", Vector3.new(1.6, 1.6, 1.6), CFrame.new(0, 0.82, 0.1), lit(0.12), material, "Ball")
		add("Seam", Vector3.new(1.86, 0.1, 1.86), CFrame.new(0, 0.02, 0), shade(0.14), material, "Sphere")
		table.insert(bellies, { y = -0.62, w = 1.2, h = 1.3 })
	elseif body == "Cube" then
		add("Body", Vector3.new(2.2, 2.2, 2.2), CFrame.new(), color, material)
		-- Rounded beads along every edge and down every corner, so it's a soft-edged block rather than
		-- a bare box. Rounded, they have no flat faces for the z-fight pass to push around at
		-- companion scale, and the bottom ones stay inside the base.
		for _, y in ipairs({ -1.0, 1.06 }) do
			for _, side in ipairs({ -1, 1 }) do
				local tone = y > 0 and lit(0.18) or shade(0.18)
				capsuleShape("Edge", Vector3.new(-1.0, y, side * 1.06), Vector3.new(1.0, y, side * 1.06), 0.2, tone)
				capsuleShape("Edge", Vector3.new(side * 1.06, y, -1.0), Vector3.new(side * 1.06, y, 1.0), 0.2, tone)
			end
		end
		for _, sx in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				capsuleShape("Corner", Vector3.new(sx * 1.06, -0.92, sz * 1.06), Vector3.new(sx * 1.06, 0.98, sz * 1.06), 0.2, shade(0.1))
			end
		end
		add("FacePlate", Vector3.new(1.56, 1.56, 0.2), CFrame.new(0, fy + 0.1, -1.08), lit(0.08), material, "Sphere")
	elseif body == "Pear" then
		add("Body", Vector3.new(2.4, 1.8, 2.2), CFrame.new(0, -0.3, 0), color, material, "Sphere")
		add("Head", Vector3.new(1.6, 1.5, 1.5), CFrame.new(0, 0.8, 0), color, material, "Sphere")
		-- A blend where the head meets the body, so the two spheres read as one form.
		add("Neck", Vector3.new(1.75, 0.9, 1.7), CFrame.new(0, 0.3, 0), color, material, "Sphere")
		add("Crown", Vector3.new(1.3, 1.2, 1.2), CFrame.new(0, 1.0, 0.06), lit(0.13), material, "Sphere")
		add("Shadow", Vector3.new(2.1, 0.7, 1.9), CFrame.new(0, -0.85, 0.1), shade(0.16), material, "Sphere")
		table.insert(bellies, { y = -0.45, w = 1.5, h = 1.0 })
	elseif body == "Disc" then
		column("Body", 0.7, 3, 0, -0.25, 0, accent, material)
		add("Dome", Vector3.new(1.8, 1.4, 1.8), CFrame.new(0, 0.2, 0), color, material, "Sphere")
		column("Rim", 0.24, 3.08, 0, -0.3, 0, accent:Lerp(BLACK, 0.25), material)
		column("DomeCollar", 0.18, 2.05, 0, 0.06, 0, accent:Lerp(BLACK, 0.12), material)
		column("Underside", 0.3, 2.7, 0, -0.55, 0, shade(0.2), material)
		add("DomeLight", Vector3.new(1.5, 1.1, 1.5), CFrame.new(0, 0.38, 0.06), lit(0.14), material, "Sphere")
		ring("Stud", 8, 1.55, -0.3, 0.2, accent:Lerp(WHITE, 0.25), Enum.Material.Metal)
	elseif body == "Stack" then
		add("Body", Vector3.new(2, 2, 2), CFrame.new(0, -0.5, 0), color, material, "Ball")
		add("Head", Vector3.new(1.5, 1.5, 1.5), CFrame.new(0, 0.8, 0), color, material, "Ball")
		add("Squash", Vector3.new(1.62, 0.5, 1.62), CFrame.new(0, 0.2, 0), shade(0.12), material, "Sphere")
		add("Crown", Vector3.new(1.25, 1.2, 1.2), CFrame.new(0, 1.02, 0.06), lit(0.13), material, "Sphere")
		table.insert(bellies, { y = -0.6, w = 1.25, h = 1.15 })
	elseif body == "Egg" then
		add("Body", Vector3.new(2.0, 2.8, 2.0), CFrame.new(), color, material, "Sphere")
		add("Crown", Vector3.new(1.5, 1.4, 1.5), CFrame.new(0, 0.82, 0.05), lit(0.14), material, "Sphere")
		add("Base", Vector3.new(1.6, 0.8, 1.6), CFrame.new(0, -1.02, 0), shade(0.18), material, "Sphere")
		-- A speckled band, the one thing that stops a plain egg reading as a plain sphere.
		ring("Speckle", 7, 0.95, 0.12, 0.22, accent:Lerp(BLACK, 0.1), material)
		table.insert(bellies, { y = -0.6, w = 1.25, h = 1.1 })
	elseif body == "Mushroom" then
		column("Stem", 1.8, 1.3, 0, -0.4, 0, color, material)
		add("StemBase", Vector3.new(1.5, 0.5, 1.5), CFrame.new(0, -1.05, 0), color, material, "Sphere")
		column("Gills", 0.2, 2.7, 0, 0.02, 0, shade(0.25), material)
		add("Cap", Vector3.new(3.0, 1.5, 3.0), CFrame.new(0, 0.55, 0), accent, material, "Sphere")
		-- A skirt where the cap tore away from the stem, a lip round the cap and a lit crown.
		column("Skirt", 0.22, 1.75, 0, -0.16, 0, lit(0.1), material)
		column("CapLip", 0.3, 2.92, 0, 0.22, 0, accent:Lerp(BLACK, 0.2), material)
		add("CapLight", Vector3.new(2.3, 1.05, 2.3), CFrame.new(0, 0.82, 0.1), accent:Lerp(WHITE, 0.16), material, "Sphere")
		ring("GillRib", 10, 1.22, 0.02, 0.22, shade(0.35), material)
	elseif body == "Cloud" then
		add("Body", Vector3.new(1.9, 1.9, 1.9), CFrame.new(), color, material, "Ball")
		for _, puff in ipairs({
			{ 1.5, Vector3.new(1.05, -0.25, 0.1) }, { 1.5, Vector3.new(-1.05, -0.25, 0.1) },
			{ 1.4, Vector3.new(0.35, 0.85, 0.15) }, { 1.3, Vector3.new(-0.45, 0.7, 0.35) },
			{ 1.5, Vector3.new(0, -0.25, 0.55) },
		}) do
			add("Puff", Vector3.new(puff[1], puff[1], puff[1]), CFrame.new(puff[2]), color, material, "Ball")
		end
		-- Smaller puffs break the silhouette; a shaded row underneath gives the cloud a bottom.
		for _, puff in ipairs({
			{ 0.95, Vector3.new(0.78, 0.5, -0.2) }, { 0.9, Vector3.new(-0.82, 0.42, -0.15) },
			{ 0.85, Vector3.new(0, 1.18, -0.1) },
		}) do
			add("Puff", Vector3.new(puff[1], puff[1], puff[1]), CFrame.new(puff[2]), lit(0.12), material, "Ball")
		end
		for _, puff in ipairs({
			{ 1.0, Vector3.new(0.6, -0.72, 0.15) }, { 1.0, Vector3.new(-0.6, -0.72, 0.15) },
			{ 0.9, Vector3.new(0, -0.8, -0.25) },
		}) do
			add("Underpuff", Vector3.new(puff[1], puff[1], puff[1]), CFrame.new(puff[2]), shade(0.14), material, "Ball")
		end
	elseif body == "Can" then
		column("Body", 2.0, 2.0, 0, 0, 0, color, material)
		for _, y in ipairs({ -1.1, 1.1 }) do
			column("Rim", 0.2, 2.08, 0, y, 0, accent:Lerp(WHITE, 0.3), Enum.Material.Metal)
		end
		column("Label", 0.7, 2.03, 0, -0.62, 0, accent, material)
		-- A lid with a pull tab and a recessed base. The highlight down one side is laid on later.
		add("Lid", Vector3.new(1.82, 0.12, 1.82), CFrame.new(0, 1.2, 0), lit(0.2), Enum.Material.Metal, "Sphere")
		add("Tab", Vector3.new(0.5, 0.08, 0.26), CFrame.new(0.2, 1.25, 0), accent:Lerp(WHITE, 0.4), Enum.Material.Metal, "Sphere")
		faceDisc("TabRing", 0.08, 0.3, 0.44, 1.26, 0, accent:Lerp(WHITE, 0.4), Enum.Material.Metal)
		add("BaseRecess", Vector3.new(1.7, 0.1, 1.7), CFrame.new(0, -1.2, 0), shade(0.24), Enum.Material.Metal, "Sphere")
		add("LabelEdge", Vector3.new(2.08, 0.08, 2.08), CFrame.new(0, -0.27, 0), accent:Lerp(BLACK, 0.3), material, "Sphere")
	elseif body == "Cone" then
		for _, tier in ipairs({ { 0.8, 2.4, -0.9 }, { 0.8, 1.9, -0.1 }, { 0.8, 1.35, 0.7 }, { 0.55, 0.8, 1.375 } }) do
			column("Tier", tier[1], tier[2], 0, tier[3], 0, color, material)
		end
		-- A lip under each tier so the stack reads as scoops, and a swirl on top.
		for _, lip in ipairs({ { 2.5, -0.48 }, { 2.0, 0.32 }, { 1.45, 1.08 } }) do
			add("Lip", Vector3.new(lip[1], 0.22, lip[1]), CFrame.new(0, lip[2], 0), shade(0.16), material, "Sphere")
		end
		add("Swirl", Vector3.new(0.62, 0.62, 0.62), CFrame.new(0, 1.66, 0), lit(0.18), material, "Ball")
		add("SwirlTip", Vector3.new(0.34, 0.34, 0.34), CFrame.new(0.08, 1.92, 0), lit(0.3), material, "Ball")
		add("BaseRim", Vector3.new(2.5, 0.26, 2.5), CFrame.new(0, -1.17, 0), shade(0.22), material, "Sphere")
	elseif body == "Ghost" then
		add("Body", Vector3.new(2.0, 2.2, 2.0), CFrame.new(0, 0.3, 0), color, material, "Sphere")
		column("Skirt", 1.1, 2.0, 0, -0.55, 0, color, material)
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			add("Wisp", Vector3.new(0.7, 0.7, 0.7), CFrame.new(math.cos(angle) * 0.72, -1.1, math.sin(angle) * 0.72),
				color, material, "Ball")
		end
		-- Smaller wisps between the big ones make a ragged hem rather than a circle of six balls.
		for index = 0, 5 do
			local angle = (index + 0.5) / 6 * math.pi * 2
			add("Wisp", Vector3.new(0.44, 0.44, 0.44), CFrame.new(math.cos(angle) * 0.82, -1.3, math.sin(angle) * 0.82),
				shade(0.12), material, "Ball")
		end
		add("Crown", Vector3.new(1.55, 1.5, 1.5), CFrame.new(0, 0.72, 0.06), lit(0.14), material, "Sphere")
		table.insert(bellies, { y = -0.45, w = 1.3, h = 0.8 })
	elseif body == "Loaf" then
		add("Body", Vector3.new(3.0, 1.2, 2.0), CFrame.new(0, -0.15, 0), color, material)
		add("Crust", Vector3.new(3.0, 1.6, 2.0), CFrame.new(0, 0.45, 0), color, material, "Sphere")
		add("CrustTop", Vector3.new(2.6, 1.2, 1.7), CFrame.new(0, 0.68, 0.05), lit(0.15), material, "Sphere")
		-- Scored slashes across the top, the thing that makes bread look like bread.
		for _, x in ipairs({ -0.8, 0, 0.8 }) do
			add("Score", Vector3.new(0.16, 0.2, 1.5), CFrame.new(x, 0.96, 0) * CFrame.Angles(0, 0.5, 0), shade(0.28), material)
		end
		add("Base", Vector3.new(3.16, 0.34, 2.14), CFrame.new(0, -0.58, 0), shade(0.22), material, "Sphere")
		for _, side in ipairs({ -1, 1 }) do
			add("EndCap", Vector3.new(0.18, 1.3, 1.8), CFrame.new(side * 1.5, 0.2, 0), shade(0.12), material, "Sphere")
		end
	elseif body == "Totem" then
		add("Body", Vector3.new(2.0, 2.0, 2.0), CFrame.new(0, -0.9, 0), color, material, "Ball")
		add("Middle", Vector3.new(1.6, 1.6, 1.6), CFrame.new(0, 0.55, 0), color, material, "Ball")
		add("Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 1.6, 0), accent, material, "Ball")
		-- Carved rings where the segments meet, and a shaded plinth at the bottom.
		column("Join", 0.18, 1.72, 0, -0.16, 0, shade(0.3), material)
		column("Join", 0.16, 1.32, 0, 1.06, 0, shade(0.3), material)
		-- A carved cap ring at the head's shoulder. As a ball on top of the head it sat inside it
		-- almost entirely (the head's own top is the contract's `top`), so nothing of it showed.
		add("Crown", Vector3.new(1.32, 0.3, 1.32), CFrame.new(0, 1.94, 0), accent:Lerp(WHITE, 0.2), material, "Sphere")
		column("Plinth", 0.3, 1.9, 0, -1.72, 0, shade(0.24), material)
		ring("Notch", 6, 0.92, -0.9, 0.24, shade(0.2), material)
	else
		add("Body", Vector3.new(2.4, 2.0, 2.2), CFrame.new(), color, material, "Sphere")
		add("Crown", Vector3.new(1.85, 1.5, 1.7), CFrame.new(0, 0.42, 0.06), lit(0.13), material, "Sphere")
		add("Shadow", Vector3.new(2.1, 0.8, 1.9), CFrame.new(0, -0.6, 0.05), shade(0.16), material, "Sphere")
		table.insert(bellies, { y = -0.4, w = 1.5, h = 1.05 })
	end
	local shapes = recorded
	recorded = nil

	--------------------------------------------------------------------------
	-- Surfaces
	--------------------------------------------------------------------------

	local FAR = 30

	-- Distance along a unit ray to the body, or nil.
	local function cast(from, direction)
		local best, bestShape = nil, nil
		for _, shape in ipairs(shapes) do
			local t = hitShape(shape, from, direction)
			if t and (best == nil or t < best) then
				best, bestShape = t, shape
			end
		end
		return best, bestShape
	end

	-- z of the front surface at (x, y): the nearer of the two sides, so the face is symmetric.
	local function surfaceZ(x, y)
		local a = cast(Vector3.new(x, y, -FAR), Vector3.zAxis)
		local b = x ~= 0 and cast(Vector3.new(-x, y, -FAR), Vector3.zAxis) or a
		if not a and not b then
			return frontZ(x, y)
		end
		return -FAR + math.min(a or math.huge, b or math.huge)
	end

	-- The body primitive the front surface at (x, y) belongs to, picked the same way surfaceZ picks
	-- its depth, so both sides of the centre line agree.
	local function surfaceShape(x, y)
		local a, shapeA = cast(Vector3.new(x, y, -FAR), Vector3.zAxis)
		if x == 0 then
			return shapeA
		end
		local b, shapeB = cast(Vector3.new(-x, y, -FAR), Vector3.zAxis)
		if not a then
			return shapeB
		elseif not b then
			return shapeA
		end
		return (a <= b) and shapeA or shapeB
	end

	-- The outward normal of the front surface at (x, y), mirrored across the centre line and kept
	-- facing mostly forward, so a detail at a crease doesn't turn edge-on.
	local function surfaceNormal(x, y)
		local h = 0.05
		local ax = math.abs(x)
		local slopeX = 0
		if ax >= h then
			slopeX = (surfaceZ(ax + h, y) - surfaceZ(ax - h, y)) / (2 * h)
		elseif ax > 0 then
			slopeX = (surfaceZ(ax + h, y) - surfaceZ(0, y)) / (ax + h)
		end
		if x < 0 then
			slopeX = -slopeX
		end
		local slopeY = (surfaceZ(x, y + h) - surfaceZ(x, y - h)) / (2 * h)
		return Vector3.new(math.clamp(slopeX, -1.4, 1.4), math.clamp(slopeY, -1.4, 1.4), -1).Unit
	end

	-- A frame on the front surface at (x, y), `lift` out along the normal, looking out of the body.
	local function surfaceFrame(x, y, lift)
		local normal = surfaceNormal(x, y)
		local point = Vector3.new(x, y, surfaceZ(x, y)) + normal * (lift or 0)
		return CFrame.lookAt(point, point + normal), point, normal
	end

	-- The body's outermost side at height y and depth z, either side (so pairs stay mirrored).
	local function sideX(y, z)
		local a = cast(Vector3.new(FAR, y, z), -Vector3.xAxis)
		local b = cast(Vector3.new(-FAR, y, z), Vector3.xAxis)
		local x = math.max(a and FAR - a or 0, b and FAR - b or 0)
		return x > 0 and x or sideW
	end

	-- The body's top surface above (x, z), the higher of x and -x.
	local function topAt(x, z)
		local a = cast(Vector3.new(x, FAR, z), -Vector3.yAxis)
		local b = x ~= 0 and cast(Vector3.new(-x, FAR, z), -Vector3.yAxis) or a
		if not a and not b then
			return nil
		end
		return FAR - math.min(a or math.huge, b or math.huge)
	end

	-- The contract's `top` where the body has nothing at (x, z): callers that must not hang a part
	-- in the air over that gap should use topAt and skip instead.
	local function topY(x, z)
		return topAt(x, z) or top
	end

	-- The body's underside below (x, z), the lower of x and -x; nil where there's nothing above.
	local function underY(x, z)
		local a = cast(Vector3.new(x, -FAR, z), Vector3.yAxis)
		local b = x ~= 0 and cast(Vector3.new(-x, -FAR, z), Vector3.yAxis) or a
		if not a and not b then
			return nil
		end
		return -FAR + math.min(a or math.huge, b or math.huge)
	end

	-- Where a ray from outside at `angle` round the vertical axis (0 = the front, -Z) meets the
	-- body at height y.
	local function around(angle, y)
		local direction = Vector3.new(math.sin(angle), 0, -math.cos(angle))
		local t = cast(Vector3.new(0, y, 0) + direction * FAR, -direction)
		local distance = t and FAR - t or sideW
		return Vector3.new(0, y, 0) + direction * distance, direction
	end

	-- A flat ellipsoid lying on the front surface: `w` by `h`, standing `proud` out at its centre.
	-- Its back is sunk as far as the body curves away under its rim, so the rim stays buried.
	local function decal(name, x, y, w, h, proud, partColor, partMaterial)
		local z0 = surfaceZ(x, y)
		local recede = 0
		for _, o in ipairs({ { w / 2, 0 }, { -w / 2, 0 }, { 0, h / 2 }, { 0, -h / 2 } }) do
			recede = math.max(recede, surfaceZ(x + o[1] * 0.97, y + o[2] * 0.97) - z0)
		end
		local sink = math.clamp(recede * 2.6, 0.03, 0.35)
		local frame = surfaceFrame(x, y, (proud - sink) / 2)
		return add(name, Vector3.new(w, h, proud + sink), frame, partColor, partMaterial, "Sphere")
	end

	-- A rounded stroke along the face from (ax, ay) to (bx, by), for mouth lines and brows.
	-- Consecutive strokes overlap into one smooth line.
	local function stroke(name, ax, ay, bx, by, thickness, proud, partColor, partMaterial)
		local mx, my = (ax + bx) / 2, (ay + by) / 2
		local _, point, normal = surfaceFrame(mx, my, 0)
		local pa = Vector3.new(ax, ay, surfaceZ(ax, ay))
		local pb = Vector3.new(bx, by, surfaceZ(bx, by))
		local along = pb - pa
		local length = along.Magnitude
		along = length > 1e-3 and along / length or Vector3.xAxis
		local out = normal - along * along:Dot(normal)
		out = out.Magnitude > 1e-3 and out.Unit or normal
		local chordZ = (pa.Z + pb.Z) / 2
		local sink = math.clamp(math.abs(chordZ - point.Z) * 2 + 0.02, 0.03, 0.35)
		local centre = Vector3.new(mx, my, math.min(chordZ, point.Z)) + out * ((proud - sink) / 2)
		local zAxis = -out
		local frame = CFrame.fromMatrix(centre, along, zAxis:Cross(along), zAxis)
		return add(name, Vector3.new(length + thickness * 1.6, thickness, proud + sink), frame, partColor, partMaterial, "Sphere")
	end

	-- A run of strokes through points {x, y}.
	local function polyline(name, points, thickness, proud, partColor, partMaterial)
		for index = 1, #points - 1 do
			local a, b = points[index], points[index + 1]
			stroke(name, a[1], a[2], b[1], b[2], thickness, proud, partColor, partMaterial)
		end
	end

	-- Points along a curve across the face: `width` wide at height y, bending `bend` at the ends.
	local function arc(width, y, bend, count)
		local points = {}
		for index = 0, count do
			local t = index / count * 2 - 1
			table.insert(points, { t * width / 2, y + bend * t * t })
		end
		return points
	end

	-- Laid now that the surface is known: the pale bellies.
	if material ~= GLASS then
		for _, patch in ipairs(bellies) do
			decal("Belly", 0, patch.y, patch.w, patch.h, 0.035, look.belly or lit(0.15), material)
		end
	end

	--------------------------------------------------------------------------
	-- Face
	--------------------------------------------------------------------------

	local carries = {}
	for _, extra in ipairs(look.extras or {}) do
		carries[extra] = true
	end

	local eyes = look.eyes or "Round"
	local ey = fy + 0.2
	local glow = look.faceGlow
	local pupilColor, pupilMaterial = glow or PUPIL, glow and NEON or nil
	local mouthColor, mouthInside, mouthMaterial = glow or MOUTH, glow or MOUTH_IN, glow and NEON or nil
	local irisColor = irisFor(look)

	-- Deepened until it reads: a pale tone on white, or under Neon, is a shape you can't see.
	local function readable(tone)
		local lum = tone.R * 0.3 + tone.G * 0.59 + tone.B * 0.11
		if lum <= 0.6 then
			return tone
		end
		return tone:Lerp(Color3.fromRGB(80, 90, 150), math.min((lum - 0.6) * 2.2, 0.65))
	end
	local eyeAt = {}

	-- A white eyeball set into the surface, an iris and pupil lying on its front like lenses (so
	-- they curve with it instead of bulging), and a glint. `gaze` tips where it looks.
	local function eyeball(x, y, size, opts)
		opts = opts or {}
		local _, point, normal = surfaceFrame(x, y, 0)
		local centre = point + normal * (size * 0.06)
		add("Eye", Vector3.new(size, size, size), CFrame.new(centre), EYE_WHITE, nil, "Ball")
		local gaze = (Vector3.new(0, 0, -1) * 0.65 + normal * 0.35).Unit
		if opts.gaze then
			gaze = (gaze + opts.gaze).Unit
		end
		local r = size / 2
		local info = { centre = centre, gaze = gaze, radius = r, normal = normal, x = x, y = y }
		if opts.bare then
			return info
		end
		local ri = r * (opts.iris or 0.62)
		local ti = size * 0.18
		local irisCentre = centre + gaze * (math.sqrt(r * r - ri * ri) + size * 0.02)
		local frame = CFrame.lookAt(irisCentre, irisCentre + gaze)
		add("Iris", Vector3.new(ri * 2, ri * 2, ti), frame, opts.irisColor or irisColor, nil, "Sphere")
		local rp = ri * (opts.pupil or 0.55)
		local tp = ti * 0.6
		local pupilCentre = irisCentre + gaze * (ti / 2 * math.sqrt(1 - (rp / ri) ^ 2) + size * 0.014)
		add("Pupil", Vector3.new(rp * 2, rp * 2, tp), CFrame.lookAt(pupilCentre, pupilCentre + gaze), pupilColor, pupilMaterial, "Sphere")
		-- Upper and a little outward on each eye, mirrored, so the pair stays symmetric.
		local outward = x == 0 and 0 or (x > 0 and 1 or -1)
		local glintSize = size * 0.16
		local glint = pupilCentre + frame.UpVector * (ri * (opts.glintLow and -0.3 or 0.4)) + frame.RightVector * (ri * 0.18 * outward) + gaze * (tp * 0.25)
		add("Glint", Vector3.new(glintSize, glintSize, glintSize), CFrame.new(glint), WHITE, nil, "Ball")
		info.frame = frame
		return info
	end

	if eyes == "Cyclops" then
		eyeAt[1] = eyeball(0, ey, 0.8, { iris = 0.6 })
		-- A lid line arcing over the one big eye.
		polyline("Lash", arc(0.62, ey + 0.46, -0.1, 3), 0.07, 0.07, PUPIL)
	elseif eyes == "Visor" then
		decal("VisorFrame", 0, ey, 1.46, 0.5, 0.06, BLACK, nil)
		decal("Visor", 0, ey, 1.28, 0.3, 0.1, readable(accent), NEON)
	elseif eyes == "Dots" then
		for _, side in ipairs({ -1, 1 }) do
			local frame, point, normal = surfaceFrame(side * 0.36, ey, 0)
			add("Eye", Vector3.new(0.26, 0.26, 0.26), CFrame.new(point + normal * 0.03), PUPIL, nil, "Ball")
			add("Glint", Vector3.new(0.07, 0.07, 0.07), CFrame.new(point + normal * 0.13 + frame.UpVector * 0.05 + frame.RightVector * 0.02 * side),
				WHITE, nil, "Ball")
			eyeAt[side] = { centre = point, gaze = normal, radius = 0.13, normal = normal, x = side * 0.36, y = ey }
		end
	elseif eyes == "Big" then
		for _, side in ipairs({ -1, 1 }) do
			eyeAt[side] = eyeball(side * 0.42, ey + 0.05, 0.72, { iris = 0.66 })
		end
	elseif eyes == "Triple" then
		for index, x in ipairs({ -0.42, 0, 0.42 }) do
			eyeAt[index] = eyeball(x, ey + (index == 2 and 0.14 or -0.02), 0.38, { iris = 0.64 })
		end
	elseif eyes == "Wink" then
		eyeAt[-1] = eyeball(-0.36, ey, 0.5)
		-- The winking eye, squeezed shut into an upturned arc.
		polyline("WinkLid", { { 0.17, ey - 0.02 }, { 0.36, ey + 0.08 }, { 0.55, ey - 0.02 } }, 0.075, 0.07, PUPIL)
		stroke("WinkLash", 0.55, ey - 0.02, 0.63, ey + 0.05, 0.05, 0.06, PUPIL)
	elseif eyes == "Goggles" then
		for _, side in ipairs({ -1, 1 }) do
			local eye = eyeball(side * 0.38, ey, 0.46)
			eyeAt[side] = eye
			local rimCentre = eye.centre + eye.normal * 0.02
			local frame = CFrame.lookAt(rimCentre, rimCentre + eye.normal) * CFrame.Angles(0, math.pi / 2, 0)
			add("GoggleRim", Vector3.new(0.14, 0.66, 0.66), frame, accent, Enum.Material.Metal, "Cylinder")
			local lensCentre = eye.centre + eye.normal * (eye.radius + 0.1)
			add("GoggleLens", Vector3.new(0.52, 0.52, 0.08), CFrame.lookAt(lensCentre, lensCentre + eye.normal),
				Color3.fromRGB(190, 230, 255), GLASS, "Sphere", 0.5)
		end
		-- A strap wrapped tight round the head, from rim to rim the long way round.
		local points = {}
		for index = 0, 4 do
			local angle = math.rad(62 + index * (236 / 8))
			local point, direction = around(angle, ey)
			table.insert(points, point + direction * 0.02)
		end
		for index = 4, 1, -1 do
			local point = points[index]
			table.insert(points, Vector3.new(-point.X, point.Y, point.Z))
		end
		for index = 1, #points - 1 do
			capsule("GoggleStrap", points[index], points[index + 1], 0.07, BLACK, nil, 0.14)
		end
	elseif eyes == "Hearts" or eyes == "Stars" then
		for _, side in ipairs({ -1, 1 }) do
			local eye = eyeball(side * 0.37, ey, 0.52, { bare = true })
			eyeAt[side] = eye
			local front = CFrame.lookAt(eye.centre, eye.centre + eye.gaze) * CFrame.new(0, 0, -eye.radius + 0.02)
			if eyes == "Hearts" then
				for _, lobe in ipairs({ -1, 1 }) do
					add("Heart", Vector3.new(0.17, 0.17, 0.17), front * CFrame.new(lobe * 0.065, 0.045, -0.02), PINK, nil, "Ball")
					add("Heart", Vector3.new(0.1, 0.22, 0.08), front * CFrame.new(lobe * 0.05, -0.04, -0.03) * CFrame.Angles(0, 0, -lobe * 0.62),
						PINK, nil, "Sphere")
				end
			else
				local starColor = readable(accent)
				add("Star", Vector3.new(0.12, 0.12, 0.12), front * CFrame.new(0, 0, -0.03), starColor, NEON, "Ball")
				for spoke = 0, 4 do
					add("Star", Vector3.new(0.075, 0.22, 0.05), front * CFrame.Angles(0, 0, spoke / 5 * math.pi * 2) * CFrame.new(0, 0.1, -0.03),
						starColor, NEON, "Sphere")
				end
			end
		end
	else
		for _, side in ipairs({ -1, 1 }) do
			local x = side * 0.36
			if eyes == "Sleepy" then
				local eye = eyeball(x, ey, 0.5, { gaze = Vector3.new(0, -0.35, 0), glintLow = true })
				eyeAt[side] = eye
				-- A heavy lid in the body's colour, half over the eye.
				add("Lid", Vector3.new(0.56, 0.34, 0.56), CFrame.new(eye.centre + Vector3.new(0, 0.1, 0) + eye.normal * 0.025),
					shade(0.05), material, "Sphere")
			else
				eyeAt[side] = eyeball(x, ey, 0.5)
				if eyes == "Angry" then
					stroke("Brow", x + side * 0.28, ey + 0.44, x - side * 0.2, ey + 0.3, 0.11, 0.08, PUPIL)
				elseif eyes == "Worried" then
					stroke("Brow", x + side * 0.28, ey + 0.32, x - side * 0.2, ey + 0.44, 0.1, 0.08, PUPIL)
				end
			end
		end
	end

	local mouth = look.mouth or "Smile"
	local my = carries.Mustache and fy - 0.38 or fy - 0.32
	-- A porthole puts a chrome hoop round the eye, and the mouth was ending up right under its
	-- bottom segment: drop it clear of the ring's outer edge.
	if carries.Porthole then
		my -= 0.16
	end
	-- Keep the mouth on the same piece of the body as the eyes. On a body built as a head sitting on
	-- a wider hull (the saucer, the stacked tiers) the lower half of the face otherwise lands on the
	-- hull, a good half stud further forward, and reads as a second face below the first. Walk it up
	-- until it is back on the eyes' surface, never closer than 0.18 under them.
	local faceShape = surfaceShape(0.36, ey)
	if faceShape and surfaceShape(0, my - 0.22) ~= faceShape and surfaceZ(0, ey) - surfaceZ(0, my - 0.22) > 0.25 then
		local limit = ey - 0.2
		local lifted = my
		while lifted < limit do
			lifted = math.min(lifted + 0.05, limit)
			if surfaceShape(0, lifted - 0.22) == faceShape then
				my = lifted
				break
			end
		end
	end
	if mouth == "Smile" then
		polyline("Mouth", arc(0.52, my, 0.09, 4), 0.075, 0.07, mouthColor, mouthMaterial)
	elseif mouth == "Grin" then
		-- An open grin: one dark hollow with a lip drawn round it, teeth under the top lip and a
		-- tongue at the bottom. (Stacked rows of narrowing ovals read as a tiered cake, because each
		-- row's edge bulges out of the one below.)
		decal("Mouth", 0, my - 0.05, 0.6, 0.28, 0.06, mouthInside, mouthMaterial)
		polyline("Lip", arc(0.62, my + 0.1, 0.03, 3), 0.07, 0.07, mouthColor, mouthMaterial)
		polyline("Lip", arc(0.58, my - 0.2, -0.07, 3), 0.07, 0.07, mouthColor, mouthMaterial)
		decal("Teeth", 0, my + 0.04, 0.46, 0.08, 0.085, WHITE)
		decal("Tongue", 0, my - 0.15, 0.24, 0.09, 0.08, TONGUE)
	elseif mouth == "O" then
		decal("MouthRim", 0, my, 0.34, 0.38, 0.05, shade(0.35), material)
		decal("Mouth", 0, my, 0.23, 0.27, 0.075, mouthInside, mouthMaterial)
	elseif mouth == "Fangs" then
		polyline("Mouth", arc(0.54, my, 0.06, 4), 0.075, 0.07, mouthColor, mouthMaterial)
		for _, side in ipairs({ -1, 1 }) do
			decal("Fang", side * 0.15, my - 0.035, 0.085, 0.17, 0.085, WHITE)
		end
	elseif mouth == "Tongue" then
		polyline("Mouth", arc(0.5, my, 0.08, 4), 0.075, 0.07, mouthColor, mouthMaterial)
		decal("Tongue", 0.07, my - 0.07, 0.19, 0.2, 0.09, TONGUE)
	elseif mouth == "Beak" then
		local _, upper, normal = surfaceFrame(0, my + 0.1, 0)
		add("Beak", Vector3.new(0.5, 0.22, 0.55), CFrame.lookAt(upper + normal * 0.17, upper + normal * 2), BEAK, nil, "Sphere")
		local _, lower, normalLow = surfaceFrame(0, my - 0.03, 0)
		add("BeakLow", Vector3.new(0.38, 0.14, 0.4), CFrame.lookAt(lower + normalLow * 0.11, lower + normalLow * 2), BEAK:Lerp(BLACK, 0.2), nil, "Sphere")
	elseif mouth == "Teeth" then
		polyline("Mouth", arc(0.46, my, 0.05, 4), 0.075, 0.07, mouthColor, mouthMaterial)
		for _, side in ipairs({ -1, 1 }) do
			decal("Tooth", side * 0.065, my - 0.075, 0.11, 0.14, 0.085, WHITE)
		end
	elseif mouth == "Frown" then
		polyline("Mouth", arc(0.46, my + 0.03, -0.08, 4), 0.075, 0.07, mouthColor, mouthMaterial)
	elseif mouth == "Wavy" then
		local points = {}
		for index = 0, 6 do
			table.insert(points, { -0.3 + index * 0.1, my + (index % 2 == 0 and -0.03 or 0.03) })
		end
		polyline("Mouth", points, 0.065, 0.07, mouthColor, mouthMaterial)
	elseif mouth == "Tusks" then
		polyline("Mouth", arc(0.5, my, 0.07, 4), 0.075, 0.07, mouthColor, mouthMaterial)
		for _, side in ipairs({ -1, 1 }) do
			local _, point, normal = surfaceFrame(side * 0.2, my + 0.02, 0)
			local base = point + normal * 0.03
			local tip = base + Vector3.new(side * 0.08, 0.24, 0) + normal * 0.16
			capsule("Tusk", base, tip, 0.12, IVORY)
		end
	end

	--------------------------------------------------------------------------
	-- Limbs
	--------------------------------------------------------------------------

	local pose = ARM_POSES[POSE_FOR_ATTACK[def.attack] or "Hang"]
	local handAt = {}

	-- A jointed arm: upper arm and forearm meeting at an elbow, and a mitten hand with a thumb.
	local function arm(side, shoulderY, thickness, handSize)
		group = side < 0 and "ArmL" or "ArmR"
		local z = -0.05
		local shoulder = Vector3.new(side * (sideX(shoulderY, z) - thickness * 0.55), shoulderY, z)
		local elbow = shoulder + Vector3.new(side * pose.elbow.X, pose.elbow.Y, pose.elbow.Z)
		local hand = elbow + Vector3.new(side * pose.hand.X, pose.hand.Y, pose.hand.Z)
		-- On a short body a hanging hand would reach the ground; lift the arm clear of the base.
		local lowest = bottom + handSize * 0.6 + 0.03
		if hand.Y < lowest then
			local lift = lowest - hand.Y
			hand += Vector3.new(0, lift, 0)
			elbow += Vector3.new(0, lift * 0.55, 0)
		end
		capsule("Arm", shoulder, elbow, thickness, color, material)
		capsule("Forearm", elbow, hand, thickness * 0.92, color, material)
		local along = (hand - elbow).Unit
		pivotAt[group] = shoulder
		local frame = CFrame.lookAt(hand, hand + along, math.abs(along.Y) > 0.9 and Vector3.new(0, 0, -1) or Vector3.yAxis)
		handAt[side] = hand
		if carries.Claws then
			-- A pincer: two curved jaws opening forward from a round wrist.
			add("Hand", Vector3.new(handSize * 0.8, handSize * 0.8, handSize * 0.8), CFrame.new(hand), accent, material, "Ball")
			for _, jaw in ipairs({ 1, -1 }) do
				add("Claw", Vector3.new(handSize * 0.55, handSize * 0.34, handSize * 1.5),
					frame * CFrame.Angles(jaw * 0.4, 0, 0) * CFrame.new(0, jaw * handSize * 0.2, -handSize * 0.6), accent:Lerp(WHITE, jaw > 0 and 0 or 0.15),
					material, "Sphere")
			end
		else
			add("Hand", Vector3.new(handSize * 0.92, handSize * 0.8, handSize * 1.06), frame * CFrame.new(0, 0, -handSize * 0.16),
				accent, material, "Sphere")
			local thumb = handSize * 0.42
			add("Thumb", Vector3.new(thumb, thumb, thumb), frame * CFrame.new(0, handSize * 0.45, -handSize * 0.2),
				accent, material, "Ball")
		end
		group = "Body"
	end

	-- A foot with a darker sole and three toes, and a leg down to it wherever the body's underside
	-- stands clear of it. Nothing goes below `bottom`, so a statue stands on its plinth.
	local function foot(side, x, z, size)
		group = side < 0 and "FootL" or "FootR"
		-- Under a flat or wide underside (a cube, a disc, a loaf) a foot would sit inside the body;
		-- bring it forward until its front half sticks out past the surface in front of it.
		local front = surfaceZ(x, bottom + 0.14 * size)
		local reach = 0.33 * size
		if z - reach > front - 0.15 * size then
			z = front + reach - 0.2 * size
		end
		local fx = side * x
		pivotAt[group] = Vector3.new(fx, bottom + 0.3 * size, z)
		add("Foot", Vector3.new(0.5, 0.26, 0.66) * size, CFrame.new(fx, bottom + 0.14 * size, z), accent, material, "Sphere")
		add("Sole", Vector3.new(0.54, 0.1, 0.7) * size, CFrame.new(fx, bottom + 0.05 * size, z + 0.01 * size), accent:Lerp(BLACK, 0.28), material, "Sphere")
		for _, tx in ipairs({ -0.13, 0, 0.13 }) do
			local toe = 0.15 * size
			add("Toe", Vector3.new(toe, toe, toe), CFrame.new(fx + tx * size, bottom + 0.1 * size, z - (0.29 - math.abs(tx) * 0.3) * size),
				accent:Lerp(WHITE, 0.18), material, "Ball")
		end
		local under = underY(x, z + 0.08 * size)
		if under and under > bottom + 0.34 * size then
			capsule("Leg", Vector3.new(fx, under + 0.12, z + 0.08 * size), Vector3.new(fx, bottom + 0.22 * size, z + 0.04 * size),
				0.24 * size, color, material)
		end
		group = "Body"
	end

	if carries.Arms then
		for _, side in ipairs({ -1, 1 }) do
			arm(side, fy - 0.3, 0.28, 0.4)
		end
	end
	if carries.Feet then
		for _, side in ipairs({ -1, 1 }) do
			foot(side, math.min(halfW * 0.45, 0.7), fz * 0.3, 1.3)
		end
	end

	--------------------------------------------------------------------------
	-- Extras
	--------------------------------------------------------------------------

	local crownY = topY(0, 0)

	for _, extra in ipairs(look.extras or {}) do
		if extra == "Arms" or extra == "Feet" or extra == "Claws" then
			-- Built with the limbs above, so they're jointed and rigged like the automatic ones.
		elseif extra == "Horns" then
			for _, side in ipairs({ -1, 1 }) do
				local x = halfW * 0.4
				local base = Vector3.new(side * x, topY(x, 0) - 0.12, 0)
				local mid = base + Vector3.new(side * 0.32, 0.36, 0)
				local tip = mid + Vector3.new(side * 0.06, 0.3, 0.04)
				capsule("Horn", base, mid, 0.3, accent)
				capsule("Horn", mid, tip, 0.18, accent:Lerp(WHITE, 0.25))
			end
		elseif extra == "Antenna" then
			-- A pair leaning out and forward, each with a bead on the end: one aerial up the centre
			-- line read as a stray wire, and on the insects it should be a pair anyway.
			for _, side in ipairs({ -1, 1 }) do
				local base = Vector3.new(side * 0.18, crownY - 0.06, 0.02)
				local bend = base + Vector3.new(side * 0.26, 0.42, -0.04)
				local tip = bend + Vector3.new(side * 0.2, 0.34, -0.12)
				capsule("Antenna", base, bend, 0.075, BLACK)
				capsule("Antenna", bend, tip, 0.065, BLACK)
				add("AntennaTip", Vector3.new(0.24, 0.24, 0.24), CFrame.new(tip), accent, NEON, "Ball")
			end
		elseif extra == "Ears" then
			for _, side in ipairs({ -1, 1 }) do
				local x = halfW * 0.5
				local base = Vector3.new(side * x, topY(x, 0) - 0.1, 0)
				local frame = CFrame.new(base + Vector3.new(side * 0.08, 0.3, 0)) * CFrame.Angles(0, 0, -side * 0.35)
				add("Ear", Vector3.new(0.55, 0.8, 0.3), frame, accent, nil, "Sphere")
				add("EarInner", Vector3.new(0.32, 0.52, 0.14), frame * CFrame.new(0, -0.02, -0.12), accent:Lerp(PINK, 0.45), nil, "Sphere")
			end
		elseif extra == "Wings" then
			-- Three feathered tiers fanned from the shoulder blade, swept back.
			for _, side in ipairs({ -1, 1 }) do
				group = side < 0 and "WingL" or "WingR"
				local y = midY + 0.35
				local rootPoint = Vector3.new(side * sideX(y, back * 0.35) * 0.8, y, back * 0.45)
				pivotAt[group] = rootPoint
				local frame = CFrame.new(rootPoint) * CFrame.Angles(0, -side * 0.55, 0)
				for index, feather in ipairs({ { 1.25, 0.46, 0.55 }, { 1.05, 0.38, 0.2 }, { 0.8, 0.3, -0.15 } }) do
					local tone = accent:Lerp(WHITE, (index - 1) * 0.14)
					add("Wing", Vector3.new(feather[1], feather[2], 0.1),
						frame * CFrame.Angles(0, 0, side * feather[3]) * CFrame.new(side * feather[1] * 0.45, 0, index * 0.02), tone, nil, "Sphere")
				end
				group = "Body"
			end
		elseif extra == "Crown" then
			local width = math.min(halfW, 1.1)
			local radius = width * 0.44
			local bandY = topY(radius * 0.8, 0) + 0.02
			column("Crown", 0.24, radius * 2, 0, bandY + 0.08, 0, GOLD, Enum.Material.Foil)
			for index = 0, 4 do
				local angle = index / 5 * math.pi * 2
				local at = Vector3.new(math.sin(angle) * radius, bandY + 0.3, -math.cos(angle) * radius)
				add("CrownPoint", Vector3.new(0.16, 0.42, 0.16), CFrame.new(at), GOLD, Enum.Material.Foil, "Sphere")
				add("CrownJewel", Vector3.new(0.12, 0.12, 0.12), CFrame.new(at + Vector3.new(0, 0.22, 0)),
					index == 0 and accent or accent:Lerp(WHITE, 0.35), index == 0 and NEON or nil, "Ball")
			end
		elseif extra == "Halo" then
			-- A smooth ring of overlapping glowing links.
			local radius = halfW * 0.55
			local count = 14
			local link = 2 * math.pi * radius / count
			for index = 0, count - 1 do
				local angle = (index + 0.5) / count * math.pi * 2
				floating(add("Halo", Vector3.new(0.1, 0.1, link * 1.5),
					CFrame.new(0, top + 0.6, 0) * CFrame.Angles(0, angle, 0) * CFrame.new(radius, 0, 0), GOLD, NEON, "Sphere"))
			end
		elseif extra == "Tail" then
			group = "Tail"
			local a = Vector3.new(0, bottom + 0.55, back * 0.75)
			pivotAt.Tail = a
			local b = a + Vector3.new(0, 0.2, 0.55)
			local c = b + Vector3.new(0, 0.5, 0.3)
			capsule("Tail", a, b, 0.3, accent)
			capsule("Tail", b, c, 0.22, accent)
			add("TailTip", Vector3.new(0.36, 0.36, 0.36), CFrame.new(c), accent:Lerp(WHITE, 0.2), nil, "Ball")
			group = "Body"
		elseif extra == "Cap" then
			column("CapBrim", 0.12, halfW * 1.5, 0, crownY - 0.02, -0.2, accent)
			add("CapTop", Vector3.new(halfW * 1.2, 0.7, halfW * 1.2), CFrame.new(0, crownY + 0.18, 0), accent, nil, "Sphere")
			add("CapButton", Vector3.new(0.16, 0.16, 0.16), CFrame.new(0, crownY + 0.52, 0), accent:Lerp(WHITE, 0.3), nil, "Ball")
		elseif extra == "Spikes" then
			for index = 1, 5 do
				local z = -0.6 + index * 0.3
				local base = topY(0, z)
				local height = 0.55 - math.abs(index - 3) * 0.08
				capsule("Spike", Vector3.new(0, base - 0.1, z), Vector3.new(0, base + height, z + 0.06), 0.24, accent)
			end
		elseif extra == "Leaf" then
			capsule("Stem", Vector3.new(0, crownY - 0.05, 0), Vector3.new(0, crownY + 0.45, 0), 0.1, LEAF)
			for _, side in ipairs({ -1, 1 }) do
				add("Leaf", Vector3.new(0.6, 0.12, 0.35),
					CFrame.new(side * 0.28, crownY + 0.55, 0) * CFrame.Angles(0, 0, side * 0.4), LEAF, Enum.Material.Grass, "Sphere")
			end
		elseif extra == "Propeller" then
			capsule("Stem", Vector3.new(0, crownY - 0.05, 0), Vector3.new(0, crownY + 0.5, 0), 0.1, BLACK)
			add("Hub", Vector3.new(0.2, 0.2, 0.2), CFrame.new(0, crownY + 0.52, 0), accent:Lerp(WHITE, 0.3), nil, "Ball")
			for _, angle in ipairs({ 0, math.pi / 2 }) do
				add("Blade", Vector3.new(1.6, 0.06, 0.28), CFrame.new(0, crownY + 0.52, 0) * CFrame.Angles(0, angle, 0.12), accent, nil, "Sphere")
			end
		elseif extra == "Bow" then
			local x = halfW * 0.35
			local at = Vector3.new(x, topY(x, 0), 0)
			for _, side in ipairs({ -1, 1 }) do
				add("Bow", Vector3.new(0.5, 0.4, 0.25), CFrame.new(at + Vector3.new(side * 0.25, 0, 0)) * CFrame.Angles(0, 0, -side * 0.25),
					accent, nil, "Sphere")
			end
			add("BowKnot", Vector3.new(0.18, 0.18, 0.18), CFrame.new(at), accent:Lerp(BLACK, 0.15), nil, "Ball")
		elseif extra == "Mustache" then
			for _, side in ipairs({ -1, 1 }) do
				stroke("Mustache", side * 0.03, fy - 0.14, side * 0.2, fy - 0.16, 0.15, 0.1, BLACK)
				stroke("Mustache", side * 0.2, fy - 0.16, side * 0.35, fy - 0.07, 0.1, 0.1, BLACK)
			end
		elseif extra == "Shades" then
			local lenses = {}
			for _, side in ipairs({ -1, 1 }) do
				local eye = (eyeAt[3] and eyeAt[side < 0 and 1 or 3]) or eyeAt[side]
					or { centre = Vector3.new(side * 0.36, ey, surfaceZ(side * 0.36, ey)), normal = Vector3.new(0, 0, -1), radius = 0.25 }
				local lens = eye.centre + eye.normal * (eye.radius + 0.1)
				lenses[side] = lens
				add("Shades", Vector3.new(0.52, 0.36, 0.08), CFrame.lookAt(lens, lens + eye.normal), BLACK, nil, "Sphere")
			end
			capsule("ShadesBridge", lenses[-1] + Vector3.new(0.22, 0.07, 0), lenses[1] + Vector3.new(-0.22, 0.07, 0), 0.06, BLACK)
		elseif extra == "Scarf" then
			-- Wrapped round the neck, knotted at one side with a tail hanging down.
			local y = fy - 0.62
			local points = {}
			for index = 0, 12 do
				local point, direction = around(index / 12 * math.pi * 2, y)
				table.insert(points, point + direction * 0.06)
			end
			for index = 1, 12 do
				capsule("Scarf", points[index], points[index + 1], 0.2, accent, Enum.Material.Fabric, 0.34)
			end
			local knot = around(math.rad(-30), y)
			local _, direction = around(math.rad(-30), y)
			capsule("ScarfTail", knot + direction * 0.12, knot + direction * 0.2 + Vector3.new(0.06, -0.55, 0), 0.26, accent:Lerp(BLACK, 0.1),
				Enum.Material.Fabric, 0.1)
		elseif extra == "Flame" then
			-- A teardrop of glowing layers: orange outside, yellow within, a pale core, a flicking tip.
			add("Flame", Vector3.new(0.76, 0.95, 0.76), CFrame.new(0, top + 0.42, 0), Color3.fromRGB(255, 110, 30), NEON, "Sphere", 0.15)
			add("Flame", Vector3.new(0.5, 0.8, 0.5), CFrame.new(0, top + 0.56, -0.06), Color3.fromRGB(255, 190, 50), NEON, "Sphere")
			add("Flame", Vector3.new(0.26, 0.5, 0.26), CFrame.new(0, top + 0.52, -0.2), Color3.fromRGB(255, 245, 190), NEON, "Sphere")
			add("FlameTip", Vector3.new(0.26, 0.6, 0.26), CFrame.new(0.05, top + 1.02, 0) * CFrame.Angles(0, 0, -0.25),
				Color3.fromRGB(255, 150, 40), NEON, "Sphere", 0.1)
		elseif extra == "Orbit" then
			for index = 0, 2 do
				local angle = index / 3 * math.pi * 2
				floating(add("Orbiter", Vector3.new(0.3, 0.3, 0.3),
					CFrame.new(math.cos(angle) * (halfW + 0.6), midY + 0.3, math.sin(angle) * (halfW + 0.6)), accent, NEON, "Ball"))
			end
		elseif extra == "Antlers" then
			for _, side in ipairs({ -1, 1 }) do
				local x = math.min(halfW, 1.1) * 0.35
				local base = Vector3.new(side * x, topY(x, 0) - 0.08, 0)
				local tip = base + Vector3.new(side * 0.55, 0.95, 0.1)
				capsule("Antler", base, tip, 0.14, BROWN)
				local fork = base:Lerp(tip, 0.55)
				capsule("Antler", fork, fork + Vector3.new(side * 0.35, 0.32, -0.25), 0.11, BROWN)
				local low = base:Lerp(tip, 0.25)
				capsule("Antler", low, low + Vector3.new(side * 0.05, 0.3, -0.25), 0.1, BROWN)
			end
		elseif extra == "Fins" then
			for _, side in ipairs({ -1, 1 }) do
				local x = sideX(midY, 0.1)
				add("Fin", Vector3.new(0.12, 0.7, 0.85), CFrame.new(side * (x + 0.02), midY, 0.1) * CFrame.Angles(0, 0, side * 0.5),
					accent, nil, "Sphere")
			end
			add("DorsalFin", Vector3.new(0.12, 0.8, 1.0), CFrame.new(0, topY(0, 0.25) + 0.12, 0.25) * CFrame.Angles(-0.4, 0, 0), accent, nil, "Sphere")
		elseif extra == "Tentacles" then
			-- Curling out along the ground from under the body, tapering to a lifted tip.
			for index = 0, 4 do
				local angle = index / 5 * math.pi * 2 + math.pi / 5
				local out = Vector3.new(math.sin(angle), 0, -math.cos(angle))
				local reachOut = cast(Vector3.new(0, bottom + 0.42, 0) + out * FAR, -out)
				local r0 = (reachOut and FAR - reachOut or sideX(bottom + 0.4, 0)) - 0.12
				local a = Vector3.new(0, bottom + 0.42, 0) + out * r0
				local b = Vector3.new(0, bottom + 0.14, 0) + out * (r0 + 0.5)
				local c = Vector3.new(0, bottom + 0.1, 0) + out * (r0 + 0.95)
				local d = Vector3.new(0, bottom + 0.34, 0) + out * (r0 + 1.18)
				capsule("Tentacle", a, b, 0.28, accent)
				capsule("Tentacle", b, c, 0.2, accent)
				capsule("TentacleTip", c, d, 0.13, accent:Lerp(WHITE, 0.2))
			end
		elseif extra == "TopHat" then
			local width = math.min(halfW, 1.1)
			column("HatBrim", 0.1, width * 1.5, 0, crownY + 0.02, 0, BLACK)
			column("HatCrown", 1.0, width * 0.95, 0, crownY + 0.55, 0, BLACK)
			column("HatBand", 0.18, width * 0.97, 0, crownY + 0.2, 0, accent)
		elseif extra == "Headphones" then
			local x = sideX(ey, 0)
			for _, side in ipairs({ -1, 1 }) do
				add("Earcup", Vector3.new(0.28, 0.62, 0.62), CFrame.new(side * (x + 0.1), ey, 0), accent, nil, "Cylinder")
				add("Cushion", Vector3.new(0.14, 0.5, 0.5), CFrame.new(side * (x + 0.28), ey, 0), accent:Lerp(BLACK, 0.4), nil, "Sphere")
			end
			local headTop = topY(0, 0)
			local points = {
				Vector3.new(-(x + 0.1), ey + 0.3, 0), Vector3.new(-x * 0.62, headTop + 0.02, 0),
				Vector3.new(x * 0.62, headTop + 0.02, 0), Vector3.new(x + 0.1, ey + 0.3, 0),
			}
			for index = 1, 3 do
				capsule("Headband", points[index], points[index + 1], 0.16, BLACK, nil, 0.09)
			end
		elseif extra == "Cape" then
			-- Three panels hung across the back, each following the body round to its own side, with a
			-- clasp at the neck. Narrow enough not to pile into one another.
			local hangTop = midY + (top - bottom) * 0.28
			local panelWidth = math.min(halfW, 1.2) * 0.62
			local hangLow = bottom + 0.05 + panelWidth * 0.45
			for _, panel in ipairs({ -1, 0, 1 }) do
				local angle = math.pi + panel * 0.42
				local high, direction = around(angle, hangTop)
				local low = around(angle, math.max(hangLow, bottom + 0.25))
				capsule("Cape", high + direction * 0.06, Vector3.new(low.X * 1.1, hangLow, low.Z + 0.12), panelWidth,
					accent, Enum.Material.Fabric, 0.12)
			end
			local clasp = around(math.pi, math.min(hangTop + 0.2, top - 0.1))
			add("CapeClasp", Vector3.new(0.3, 0.22, 0.2), CFrame.new(clasp + Vector3.new(0, 0.04, 0.02)),
				accent:Lerp(WHITE, 0.45), Enum.Material.Metal, "Sphere")
		elseif extra == "Monocle" then
			-- The right-hand eye: key 1 for a pair or a cyclops, the last of three.
			local eye = eyeAt[3] or eyeAt[1] or { centre = Vector3.new(0.36, ey, fz), normal = Vector3.new(0, 0, -1), radius = 0.25 }
			local rimCentre = eye.centre + eye.normal * (eye.radius + 0.06)
			local frame = CFrame.lookAt(rimCentre, rimCentre + eye.normal)
			local radius = eye.radius + 0.06
			local count = 12
			for index = 0, count - 1 do
				local angle = (index + 0.5) / count * math.pi * 2
				add("MonocleRim", Vector3.new(0.06, 2 * math.pi * radius / count * 1.5, 0.06),
					frame * CFrame.Angles(0, 0, angle) * CFrame.new(radius, 0, 0), GOLD, Enum.Material.Foil, "Sphere")
			end
			add("MonocleLens", Vector3.new(radius * 2, radius * 2, 0.04), frame, Color3.fromRGB(220, 240, 255), GLASS, "Sphere", 0.6)
			local hang = frame * CFrame.new(radius * 0.7, -radius * 0.7, 0)
			capsule("MonocleChain", hang.Position, hang.Position + Vector3.new(0.12, -0.55, 0.2), 0.04, GOLD, Enum.Material.Foil)
		elseif extra == "Beard" then
			-- Hangs below the mouth rather than over it: the chin mass starts a clear stretch under
			-- the mouth line and the cheek tufts sit out at the jaw, so the smile still reads. Each
			-- piece is kept off the ground, since a short body puts the mouth low already.
			local beardColor = Color3.fromRGB(236, 236, 242)
			local _, chin, normal = surfaceFrame(0, math.max(my - 0.58, bottom + 0.45), 0)
			add("Beard", Vector3.new(0.95, 0.8, 0.5), CFrame.new(chin + normal * 0.12), beardColor, nil, "Sphere")
			for _, side in ipairs({ -1, 1 }) do
				local _, cheek, cheekNormal = surfaceFrame(side * 0.42, math.max(my - 0.42, bottom + 0.55), 0)
				add("Beard", Vector3.new(0.45, 0.6, 0.4), CFrame.new(cheek + cheekNormal * 0.08), beardColor, nil, "Sphere")
			end
			local tipY = math.max(chin.Y - 0.4, bottom + 0.24)
			add("BeardTip", Vector3.new(0.42, 0.45, 0.36), CFrame.new(Vector3.new(chin.X, tipY, chin.Z) + normal * 0.18), beardColor:Lerp(BLACK, 0.06),
				nil, "Sphere")
		elseif extra == "Petals" then
			-- A ring of petals round the face: each one set against the body where a ray out from the
			-- ring's centre leaves it, so none hides inside and none hangs off in the air.
			local length = 0.75
			local ringCentre = Vector3.new(0, fy + 0.05, fz * 0.35 + 0.1)
			for index = 0, 11 do
				local angle = index / 12 * math.pi * 2
				local direction = Vector3.new(math.sin(angle), math.cos(angle), 0)
				local mirrored = Vector3.new(-direction.X, direction.Y, 0)
				local hit = cast(ringCentre + direction * FAR, -direction)
				local twin = cast(ringCentre + mirrored * FAR, -mirrored)
				local reach = math.min(hit and FAR - hit or math.huge, twin and FAR - twin or math.huge)
				local radius = (reach < math.huge and reach or sideW) + length * 0.3
				if ringCentre.Y + math.cos(angle) * radius - length / 2 >= bottom + 0.02 then
					add("Petal", Vector3.new(length * 0.6, length, 0.16),
						CFrame.new(ringCentre) * CFrame.Angles(0, 0, angle) * CFrame.new(0, radius, 0),
						index % 2 == 0 and accent or accent:Lerp(WHITE, 0.2), nil, "Sphere")
				end
			end
		elseif extra == "Gem" then
			floating(add("Gem", Vector3.new(0.44, 0.44, 0.44), CFrame.new(0, top + 0.75, 0) * CFrame.Angles(math.rad(45), 0, math.rad(45)), accent, GLASS, nil, 0.25))
			floating(add("GemCore", Vector3.new(0.24, 0.24, 0.24), CFrame.new(0, top + 0.75, 0), accent:Lerp(WHITE, 0.3), NEON, "Ball"))
		elseif extra == "Spots" then
			local spotColor = look.spotColor or accent
			if body == "Mushroom" then
				for _, spot in ipairs({
					Vector3.new(0.6, 1.02, -0.55), Vector3.new(-0.75, 0.92, -0.35), Vector3.new(0.1, 1.28, 0.2),
					Vector3.new(-0.2, 0.88, -0.95), Vector3.new(0.95, 0.72, 0.45), Vector3.new(-0.6, 0.95, 0.7),
				}) do
					scattered(add("Spot", Vector3.new(0.4, 0.4, 0.4), CFrame.new(spot.X, topY(math.abs(spot.X), spot.Z) - 0.1, spot.Z), spotColor, nil, "Ball"))
				end
			else
				-- Round patches lying on the body, wherever the rays from its middle come out.
				for index, direction in ipairs({
					Vector3.new(0.75, 0.25, -0.6), Vector3.new(-0.8, -0.2, -0.55), Vector3.new(0.35, 0.8, 0.5),
					Vector3.new(-0.5, 0.55, 0.65), Vector3.new(0.9, -0.3, 0.3), Vector3.new(-0.3, -0.6, 0.75),
				}) do
					local unit = direction.Unit
					local centre = Vector3.new(0, midY, 0)
					local t = cast(centre + unit * FAR, -unit)
					local point = t and centre + unit * (FAR - t)
					if point and point.Y > bottom + 0.35 then
						local size = index % 2 == 0 and 0.36 or 0.46
						add("Spot", Vector3.new(size, size, 0.14), CFrame.lookAt(point, point + unit), spotColor, nil, "Sphere")
					end
				end
			end
		elseif extra == "Stripes" then
			for _, fraction in ipairs({ 0.18, 0.33 }) do
				local y = bottom + (top - bottom) * fraction
				if metrics.boxy then
					add("Stripe", Vector3.new(halfW * 2 + 0.24, 0.16, back * 2 + 0.24), CFrame.new(0, y, 0), accent)
				else
					-- An ellipsoid band just proud of the body wherever it is at that height.
					local x = sideX(y, 0)
					local front = around(0, y)
					local rear = around(math.pi, y)
					add("Stripe", Vector3.new(x * 2 + 0.07, 0.18, (rear.Z - front.Z) + 0.07), CFrame.new(0, y, (rear.Z + front.Z) / 2), accent, nil, "Sphere")
				end
			end
		elseif extra == "Blush" then
			for _, side in ipairs({ -1, 1 }) do
				decal("Blush", side * math.min(0.62, sideW * 0.7), fy - 0.05, 0.34, 0.2, 0.05, BLUSH)
			end
		elseif extra == "Unicorn" then
			local frame = CFrame.new(0, crownY - 0.05, fz * 0.25) * CFrame.Angles(math.rad(-20), 0, 0)
			for _, segment in ipairs({ { 0.36, 0.34, 0.17 }, { 0.36, 0.24, 0.5 }, { 0.3, 0.14, 0.8 } }) do
				add("Horn", Vector3.new(segment[1], segment[2], segment[2]),
					frame * CFrame.new(0, segment[3], 0) * CFrame.Angles(0, 0, math.pi / 2), GOLD, Enum.Material.Foil, "Cylinder")
			end
			add("HornTip", Vector3.new(0.14, 0.14, 0.14), frame * CFrame.new(0, 1.0, 0), accent, NEON, "Ball")
		elseif extra == "Whiskers" then
			for _, side in ipairs({ -1, 1 }) do
				for row = -1, 1 do
					local _, point, normal = surfaceFrame(side * 0.3, fy - 0.12 + row * 0.07, 0)
					rod("Whisker", point + normal * 0.02, Vector3.new(side * (sideW + 0.3), fy - 0.05 + row * 0.18, point.Z + 0.25), 0.035, BLACK)
				end
			end
		elseif extra == "Helmet" then
			-- A fishbowl over the head and shoulders, with a collar where it meets the body.
			local high = crownY + 0.35
			local low = fy - 0.55
			local diameter = math.max(high - low, sideX(fy, 0) * 2 + 0.45)
			local centreY = high - diameter / 2
			centreY = math.max(centreY, bottom + diameter / 2 + 0.02)
			add("Helmet", Vector3.new(diameter, diameter, diameter), CFrame.new(0, centreY, 0),
				Color3.fromRGB(215, 238, 255), GLASS, "Ball", 0.82)
			local collarY = centreY - diameter * 0.42
			local collarX = sideX(collarY, 0)
			add("HelmetCollar", Vector3.new(collarX * 2 + 0.3, 0.24, collarX * 2 + 0.3), CFrame.new(0, collarY, 0), accent, Enum.Material.Metal, "Sphere")
		elseif extra == "Bolt" then
			local yellow = Color3.fromRGB(255, 230, 60)
			-- Rounded strokes rather than boxes: nothing for the z-fight pass to push at companion scale.
			local zig = {
				Vector3.new(-0.1, top + 0.25, 0), Vector3.new(0.14, top + 0.6, 0), Vector3.new(-0.12, top + 0.8, 0), Vector3.new(0.1, top + 1.3, 0),
			}
			for index = 1, 3 do
				floating(capsule("Bolt", zig[index], zig[index + 1], 0.15, yellow, NEON))
			end
		elseif extra == "Shell" then
			add("Shell", Vector3.new(sideW * 1.9, (top - bottom) * 0.85, 1.3), CFrame.new(0, midY + 0.1, back + 0.15), accent, nil, "Sphere")
			add("ShellSwirl", Vector3.new(0.9, 0.9, 0.2), CFrame.new(0, midY + 0.15, back + 0.8), accent:Lerp(WHITE, 0.35), nil, "Sphere")
		elseif extra == "WizardHat" or extra == "Nightcap" then
			-- A tall soft cone that bends back (a wizard's, with a band and a star) or flops over to one
			-- side (a nightcap, with a bobble on the end).
			local width = math.min(halfW, 1.1)
			local wizard = extra == "WizardHat"
			local base = Vector3.new(0, topY(0, 0) - 0.08, 0)
			if wizard then
				add("HatBrim", Vector3.new(width * 1.9, 0.12, width * 1.9), CFrame.new(base + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0.08, 0, 0),
					accent:Lerp(BLACK, 0.2), nil, "Sphere")
			end
			local height = wizard and width * 1.6 or width * 1.2
			local diameter = wizard and width * 1.15 or width * 1.35
			local last = base
			for index = 0, 5 do
				local t = index / 5
				local bend = wizard and Vector3.new(0, 0, t * t * 0.45) or Vector3.new(t * t * 0.9, -t * t * 0.35, t * 0.1)
				local centre = base + Vector3.new(0, 0.15 + t * height, 0) + bend
				local d = diameter * (1 - t * 0.82)
				local direction = (centre - last).Unit
				local side = direction:Cross(Vector3.zAxis)
				side = side.Magnitude > 1e-3 and side.Unit or Vector3.xAxis
				add("Hat", Vector3.new(d, height * 0.34, d), CFrame.fromMatrix(centre, side, direction, side:Cross(direction)),
					wizard and accent or color:Lerp(accent, 0.5), nil, "Sphere")
				last = centre
			end
			if wizard then
				column("HatBand", 0.16, diameter * 0.93, 0, base.Y + 0.3, 0, GOLD, Enum.Material.Foil)
				-- On the cone's surface at that height, not hovering off it.
				local star = base + Vector3.new(diameter * 0.17, height * 0.45, -diameter * 0.25)
				add("HatStar", Vector3.new(0.18, 0.18, 0.18), CFrame.new(star), GOLD, NEON, "Ball")
			else
				column("HatBand", 0.2, diameter * 0.97, 0, base.Y + 0.24, 0, WHITE)
				add("Bobble", Vector3.new(0.34, 0.34, 0.34), CFrame.new(last + Vector3.new(0.12, -0.12, 0)), WHITE, nil, "Ball")
			end
		elseif extra == "Nemes" then
			-- A striped royal headcloth: a cap over the crown, lappets hanging beside the face and a
			-- small emblem at the brow.
			local width = sideX(ey + 0.2, 0.05)
			local capTop = topY(0, 0)
			add("NemesCap", Vector3.new(width * 2.2, 0.55, width * 2.1), CFrame.new(0, capTop - 0.12, 0.05), GOLD, Enum.Material.Foil, "Sphere")
			for _, side in ipairs({ -1, 1 }) do
				local high = Vector3.new(side * (width + 0.06), ey + 0.25, 0.05)
				local low = Vector3.new(side * (sideX(fy - 0.6, 0) + 0.12), math.max(fy - 0.75, bottom + 0.32), -0.08)
				capsule("Nemes", high, low, 0.5, accent, nil, 0.14)
				for _, t in ipairs({ 0.3, 0.65 }) do
					local at = high:Lerp(low, t)
					capsule("NemesStripe", at - Vector3.new(0.2, 0, 0), at + Vector3.new(0.2, 0, 0), 0.2, GOLD, Enum.Material.Foil, 0.1)
				end
			end
			local _, brow, normal = surfaceFrame(0, math.min(ey + 0.45, capTop - 0.2), 0)
			capsule("Emblem", brow + normal * 0.05, brow + normal * 0.3 + Vector3.new(0, 0.22, 0), 0.12, GOLD, Enum.Material.Foil)
			add("EmblemGem", Vector3.new(0.13, 0.13, 0.13), CFrame.new(brow + normal * 0.36 + Vector3.new(0, 0.26, 0)), accent:Lerp(WHITE, 0.3), NEON, "Ball")
		elseif extra == "Battlements" then
			-- Merlons round the rim of the top, like a tower, and a pennant flying from the middle.
			local rimY = topY(0, 0) - 0.05
			for index = 0, 7 do
				local angle = (index + 0.5) / 8 * math.pi * 2
				local point, direction = around(angle, rimY - 0.15)
				add("Merlon", Vector3.new(0.34, 0.4, 0.26), CFrame.lookAt(point - direction * 0.08 + Vector3.new(0, 0.28, 0), point + direction * 2 + Vector3.new(0, 0.28, 0)),
					shade(0.08), material)
			end
			local pole = Vector3.new(0, rimY, 0.1)
			capsule("FlagPole", pole, pole + Vector3.new(0, 1.1, 0), 0.07, BROWN)
			add("Flag", Vector3.new(0.5, 0.32, 0.05), CFrame.new(pole + Vector3.new(0.27, 0.92, 0)), accent, Enum.Material.Fabric, "Sphere")
		elseif extra == "ButterflyWings" then
			-- Big rounded forewings over smaller hindwings, each with a pale eyespot.
			for _, side in ipairs({ -1, 1 }) do
				group = side < 0 and "WingL" or "WingR"
				local y = midY + 0.35
				local rootPoint = Vector3.new(side * sideX(y, back * 0.35) * 0.75, y, back * 0.5)
				pivotAt[group] = rootPoint
				local frame = CFrame.new(rootPoint) * CFrame.Angles(0, -side * 0.5, 0)
				for index, wing in ipairs({ { 1.5, 1.15, 0.55, 0.55 }, { 1.0, 0.85, -0.45, 0.4 } }) do
					local wingFrame = frame * CFrame.Angles(0, 0, side * wing[3]) * CFrame.new(side * wing[1] * 0.42, 0, index * 0.03)
					add("Wing", Vector3.new(wing[1], wing[2], 0.08), wingFrame, index == 1 and accent or accent:Lerp(color, 0.35), nil, "Sphere")
					add("WingSpot", Vector3.new(wing[4], wing[4], 0.1), wingFrame * CFrame.new(side * wing[1] * 0.12, 0.05, 0), WHITE:Lerp(accent, 0.25), nil, "Sphere")
				end
				group = "Body"
			end
		elseif extra == "Pixels" then
			-- Blocky shards of the creature hanging in the air around it, as if it hasn't finished loading.
			local radius = math.max(sideX(midY, 0), halfW * 0.8) + 0.55
			for index = 0, 7 do
				local angle = index / 8 * math.pi * 2 + 0.2
				local y = midY + ((index * 37) % 7 - 3) * (top - bottom) * 0.08
				local r = radius + ((index * 13) % 3) * 0.15
				local size = 0.18 + ((index * 5) % 3) * 0.06
				local tone = index % 3 == 0 and accent or (index % 3 == 1 and WHITE or color)
				scattered(floating(add("Pixel", Vector3.new(size, size, size),
					CFrame.new(math.sin(angle) * r, y, -math.cos(angle) * r) * CFrame.Angles(0, angle, 0), tone, index % 3 == 0 and NEON or nil)))
			end
		elseif extra == "Porthole" then
			-- A chrome ring round the one big eye (or the middle of the face), glazed, like a washing
			-- machine's door.
			local eye = eyeAt[1] and eyeAt[1].x == 0 and eyeAt[1] or nil
			local centre, normal, radius
			if eye then
				centre, normal, radius = eye.centre + eye.normal * 0.02, eye.normal, eye.radius + 0.1
			else
				-- No single eye to ring: take in the pair, or the ring's own segments run straight
				-- through the eyeballs.
				local wide = 0
				for _, other in pairs(eyeAt) do
					wide = math.max(wide, math.abs(other.x) + other.radius)
				end
				local _, point, n = surfaceFrame(0, wide > 0 and ey or fy, 0)
				centre, normal, radius = point + n * 0.05, n, math.max(0.45, wide + 0.14)
			end
			local frame = CFrame.lookAt(centre, centre + normal)
			local count = 16
			for index = 0, count - 1 do
				local angle = (index + 0.5) / count * math.pi * 2
				add("Porthole", Vector3.new(0.13, 2 * math.pi * radius / count * 1.5, 0.13),
					frame * CFrame.Angles(0, 0, angle) * CFrame.new(radius, 0, 0), Color3.fromRGB(205, 212, 222), Enum.Material.Metal, "Sphere")
			end
			-- The glass bulges over the eye: centred at the ring, deep enough to clear the eye's front.
			add("PortholeGlass", Vector3.new(radius * 2, radius * 2, (radius + 0.06) * 2), frame, Color3.fromRGB(200, 235, 255), GLASS, "Sphere", 0.75)
		elseif extra == "Knobs" then
			-- A row of dials across the front, each with a pointer.
			local y = math.min(ey + 0.62, topY(0, 0) - 0.16)
			if y < ey + 0.45 then
				y = my - 0.34
			end
			for index, x in ipairs({ -0.46, 0, 0.46 }) do
				local _, point, normal = surfaceFrame(x, y, 0)
				local centre = point + normal * 0.02
				add("Knob", Vector3.new(0.12, 0.26, 0.26), CFrame.lookAt(centre, centre + normal) * CFrame.Angles(0, math.pi / 2, 0),
					index == 2 and accent or Color3.fromRGB(230, 232, 238), Enum.Material.Metal, "Cylinder")
				local tip = CFrame.lookAt(centre, centre + normal) * CFrame.Angles(0, 0, (index - 2) * 0.9) * CFrame.new(0, 0.06, -0.05)
				add("KnobPointer", Vector3.new(0.05, 0.12, 0.05), tip, BLACK, nil, "Sphere")
			end
		elseif extra == "Accretion" then
			-- A tilted ring of glowing matter circling the body.
			local radius = math.max(sideX(midY, 0), halfW) + 0.55
			local count = 20
			local tilt = CFrame.new(0, midY + 0.1, 0) * CFrame.Angles(0.35, 0, 0.12)
			for index = 0, count - 1 do
				local angle = (index + 0.5) / count * math.pi * 2
				local tone = accent:Lerp(WHITE, (index % 4) * 0.12)
				scattered(floating(add("Accretion", Vector3.new(0.14, 0.1, 2 * math.pi * radius / count * 1.45),
					tilt * CFrame.Angles(0, angle, 0) * CFrame.new(radius, 0, 0), tone, NEON, "Sphere", 0.1)))
			end
		elseif extra == "Rainbow" then
			-- An arch of four colours over the head, touching down at either shoulder.
			local centre = Vector3.new(0, midY + 0.15, back * 0.35)
			local base = sideX(midY + 0.15, back * 0.35) + 0.02
			for band, tone in ipairs({ Color3.fromRGB(255, 90, 90), Color3.fromRGB(255, 210, 70), Color3.fromRGB(110, 220, 110), Color3.fromRGB(90, 160, 255) }) do
				local radius = base + (4 - band) * 0.17
				local last = nil
				for index = 0, 7 do
					local angle = index / 7 * math.pi
					local point = centre + Vector3.new(math.cos(angle) * radius, math.sin(angle) * (radius + (top - midY) * 0.55), 0)
					if last then
						capsule("Rainbow", last, point, 0.18, tone, nil, 0.1, Vector3.zAxis)
					end
					last = point
				end
			end
		elseif extra == "Sprinkles" then
			-- Little rods of colour scattered over the top.
			local tones = { Color3.fromRGB(255, 90, 140), Color3.fromRGB(255, 220, 80), Color3.fromRGB(120, 210, 255),
				Color3.fromRGB(140, 230, 120), WHITE }
			local reach = math.min(halfW, 1.1) * 0.7
			for index = 0, 11 do
				local angle = index * 2.4
				local r = reach * (0.72 + 0.28 * ((index * 7) % 12) / 11)
				-- Shifted back off the face, so none lands on an eye of an upward-looking body.
				local x, z, surface
				for _ = 1, 4 do
					x, z = math.sin(angle) * r, -math.cos(angle) * r + reach * 0.3
					surface = topAt(x, z)
					if surface then
						break
					end
					r *= 0.65
				end
				if surface then
					local at = Vector3.new(x, surface - 0.06, z)
					scattered(add("Sprinkle", Vector3.new(0.07, 0.07, 0.24), CFrame.new(at) * CFrame.Angles(0, angle * 1.7, 0) * CFrame.Angles(0.2, 0, 0),
						tones[index % #tones + 1], nil, "Sphere"))
				end
			end
		elseif extra == "ToastSlots" then
			-- Two slices popping out of slots in the top, and the lever down one side.
			local topAt = topY(0, 0)
			for _, x in ipairs({ -0.32, 0.32 }) do
				add("Slot", Vector3.new(0.3, 0.1, 1.1), CFrame.new(x, topAt, 0), BLACK, nil, "Sphere")
				add("Toast", Vector3.new(0.16, 0.9, 1.0), CFrame.new(x, topAt + 0.3, 0), Color3.fromRGB(214, 160, 90), nil, "Sphere")
				add("ToastCrust", Vector3.new(0.13, 0.98, 1.08), CFrame.new(x, topAt + 0.28, 0.01), Color3.fromRGB(150, 96, 48), nil, "Sphere")
			end
			local side = sideX(midY + 0.3, 0)
			capsule("Lever", Vector3.new(side - 0.05, midY + 0.35, -0.2), Vector3.new(side + 0.25, midY + 0.35, -0.2), 0.1, BLACK)
			add("LeverKnob", Vector3.new(0.2, 0.2, 0.2), CFrame.new(side + 0.3, midY + 0.35, -0.2), accent, nil, "Ball")
		elseif extra == "Spout" then
			-- A fountain of water from the top: a rising column that splits and falls either side.
			local water = Color3.fromRGB(150, 210, 255)
			local base = Vector3.new(0, topY(0, 0.2) - 0.05, 0.2)
			capsule("Spout", base, base + Vector3.new(0, 0.75, 0), 0.2, water, GLASS, nil)
			for _, side in ipairs({ -1, 1 }) do
				capsule("Spout", base + Vector3.new(0, 0.75, 0), base + Vector3.new(side * 0.4, 0.95, 0), 0.14, water, GLASS)
				floating(add("SpoutDrop", Vector3.new(0.14, 0.18, 0.14), CFrame.new(base + Vector3.new(side * 0.58, 0.82, 0)), water, GLASS, "Sphere"))
			end
		elseif extra == "Cherry" then
			local at = Vector3.new(0.1, topY(0.1, 0), 0)
			add("Cherry", Vector3.new(0.46, 0.46, 0.46), CFrame.new(at + Vector3.new(0, 0.2, 0)), Color3.fromRGB(215, 30, 50), nil, "Ball")
			add("CherryShine", Vector3.new(0.12, 0.12, 0.12), CFrame.new(at + Vector3.new(-0.1, 0.34, -0.14)), WHITE, nil, "Ball")
			capsule("CherryStem", at + Vector3.new(0, 0.38, 0), at + Vector3.new(0.12, 0.8, 0.05), 0.05, Color3.fromRGB(90, 140, 60))
			add("CherryLeaf", Vector3.new(0.3, 0.06, 0.16), CFrame.new(at + Vector3.new(0.26, 0.74, 0.05)) * CFrame.Angles(0, 0, -0.4), LEAF, nil, "Sphere")
		elseif extra == "Nori" then
			-- A band of seaweed wrapped round the middle.
			local y = bottom + (top - bottom) * 0.3
			local x = sideX(y, 0)
			local front = around(0, y)
			local rear = around(math.pi, y)
			add("Nori", Vector3.new(x * 2 + 0.08, (top - bottom) * 0.2, (rear.Z - front.Z) + 0.08), CFrame.new(0, y, (rear.Z + front.Z) / 2),
				Color3.fromRGB(34, 52, 40), nil, "Sphere")
		elseif extra == "Topknot" then
			local base = Vector3.new(0, topY(0, 0.25), 0.25)
			add("Topknot", Vector3.new(0.34, 0.34, 0.34), CFrame.new(base + Vector3.new(0, 0.1, 0)), BLACK, nil, "Ball")
			capsule("Topknot", base + Vector3.new(0, 0.18, 0), base + Vector3.new(0, 0.3, 0.45), 0.16, BLACK)
			column("TopknotTie", 0.08, 0.3, 0, base.Y + 0.25, base.Z, accent)
		elseif extra == "Drips" then
			-- Glossy drips running down from the top, as if it's been dunked.
			local startY = top - (top - bottom) * 0.12
			for index = 0, 4 do
				local angle = 1.0 + index / 4 * (math.pi * 2 - 2.0)
				local length = 0.35 + ((index * 3) % 3) * 0.14
				local a, direction = around(angle, startY)
				local b = around(angle, startY - length)
				scattered(capsule("Drip", a + direction * 0.02, b + direction * 0.05, 0.15, accent, nil, 0.12))
				scattered(add("DripDrop", Vector3.new(0.2, 0.2, 0.2), CFrame.new(b + direction * 0.06 + Vector3.new(0, -0.03, 0)), accent, nil, "Ball"))
			end
		elseif extra == "Bun" then
			-- Hair gathered into a bun on top, with a pin through it.
			local hair = Color3.fromRGB(222, 222, 234)
			local base = Vector3.new(0, topY(0, 0.3), 0.3)
			add("Bun", Vector3.new(0.7, 0.62, 0.7), CFrame.new(base + Vector3.new(0, 0.18, 0)), hair, nil, "Sphere")
			add("Bun", Vector3.new(0.42, 0.38, 0.42), CFrame.new(base + Vector3.new(0, 0.5, 0.05)), hair:Lerp(WHITE, 0.3), nil, "Sphere")
			capsule("Hairpin", base + Vector3.new(-0.45, 0.3, 0), base + Vector3.new(0.45, 0.45, 0.05), 0.05, accent)
		elseif extra == "Fries" then
			-- A carton's worth of fries standing up out of the top, fanned out a little.
			local topAt = topY(0, 0)
			local reach = math.min(sideX(topAt - 0.2, 0), halfW) * 0.55
			for index = 0, 8 do
				local angle = index * 2.4
				local r = reach * math.sqrt((index + 0.5) / 9)
				local x, z = math.sin(angle) * r, -math.cos(angle) * r
				local height = 0.75 + ((index * 7) % 4) * 0.12
				local lean = Vector3.new(x, 0, z) * 0.35
				local foot = Vector3.new(x, topAt - 0.25, z)
				scattered(add("Fry", Vector3.new(0.17, height, 0.17), CFrame.lookAt(foot + Vector3.new(0, height / 2, 0) + lean * 0.5,
					foot + Vector3.new(0, height, 0) + lean, Vector3.zAxis) * CFrame.Angles(math.pi / 2, 0, 0) * CFrame.Angles(0, index * 0.37, 0),
					Color3.fromRGB(250, 214, 96):Lerp(Color3.fromRGB(214, 150, 60), ((index * 3) % 4) * 0.15)))
			end
		elseif extra == "Flower" then
			-- A bloom on top: five petals round a bright middle.
			local at = Vector3.new(0.12, topY(0.12, 0) + 0.12, 0)
			for index = 0, 4 do
				local angle = index / 5 * math.pi * 2
				scattered(add("Petal", Vector3.new(0.26, 0.08, 0.36), CFrame.new(at) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -0.2) * CFrame.Angles(0.35, 0, 0),
					accent, nil, "Sphere"))
			end
			scattered(add("FlowerHeart", Vector3.new(0.2, 0.2, 0.2), CFrame.new(at + Vector3.new(0, 0.05, 0)), Color3.fromRGB(255, 220, 80), nil, "Ball"))
		elseif extra == "Tears" then
			-- A tear welling at each eye and one running down the cheek.
			local water = Color3.fromRGB(140, 205, 255)
			for _, side in ipairs({ -1, 1 }) do
				-- The eye on this side: of three, the outer ones; one big eye is shared, so each tear sits
				-- toward its own side of it.
				local eye = eyeAt[3] and eyeAt[side < 0 and 1 or 3] or eyeAt[side] or eyeAt[1]
				local x = eye and (eye.x ~= 0 and eye.x or side * eye.radius * 0.7) or side * 0.36
				local y = (eye and eye.y or ey) - 0.26
				local _, point, normal = surfaceFrame(x, y, 0)
				add("Tear", Vector3.new(0.14, 0.2, 0.12), CFrame.new(point + normal * 0.05), water, GLASS, "Sphere")
				local _, lower, lowerNormal = surfaceFrame(x + side * 0.04, y - 0.3, 0)
				add("Tear", Vector3.new(0.12, 0.17, 0.1), CFrame.new(lower + lowerNormal * 0.04), water, GLASS, "Sphere")
			end
		elseif extra == "Nose" then
			-- A big soft nose between the eyes and the mouth.
			local y = (ey + my) / 2
			local _, point, normal = surfaceFrame(0, y, 0)
			add("Nose", Vector3.new(0.4, 0.32, 0.3), CFrame.lookAt(point + normal * 0.1, point + normal * 2), shade(0.55), nil, "Sphere")
			add("NoseShine", Vector3.new(0.1, 0.07, 0.06), CFrame.new(point + normal * 0.23 + Vector3.new(-0.08, 0.08, 0)), WHITE, nil, "Sphere")
		elseif extra == "Mortarboard" then
			-- A graduation cap: skullcap, the flat square board and a tassel hanging off one corner.
			local capTop = topY(0, 0)
			local width = math.min(halfW, 1.1)
			add("CapSkull", Vector3.new(width * 1.2, 0.4, width * 1.2), CFrame.new(0, capTop - 0.02, 0), BLACK, nil, "Sphere")
			add("Board", Vector3.new(width * 1.5, 0.08, width * 1.5), CFrame.new(0, capTop + 0.2, 0) * CFrame.Angles(0, math.pi / 4, 0), BLACK)
			add("BoardButton", Vector3.new(0.12, 0.12, 0.12), CFrame.new(0, capTop + 0.26, 0), accent, nil, "Ball")
			local corner = Vector3.new(width * 0.75, capTop + 0.2, 0)
			capsule("Tassel", Vector3.new(0, capTop + 0.26, 0), corner, 0.04, accent)
			capsule("Tassel", corner, corner + Vector3.new(0.02, -0.42, 0), 0.07, accent)
		elseif extra == "Beret" then
			local capTop = topY(-0.15, 0)
			local width = math.min(halfW, 1.1)
			add("Beret", Vector3.new(width * 1.45, 0.34, width * 1.4), CFrame.new(-0.15, capTop + 0.05, 0.05) * CFrame.Angles(0, 0, 0.22), accent, nil, "Sphere")
			capsule("BeretStem", Vector3.new(-0.15, capTop + 0.18, 0.05), Vector3.new(-0.12, capTop + 0.34, 0.05), 0.07, accent:Lerp(BLACK, 0.2))
		elseif extra == "Stinger" then
			-- Out of the back, low down, pointing back and a little down.
			local y = bottom + (top - bottom) * 0.3
			local base = around(math.pi, y)
			capsule("Stinger", base - Vector3.new(0, 0, 0.1), base + Vector3.new(0, -0.08, 0.35), 0.26, BLACK)
			capsule("Stinger", base + Vector3.new(0, -0.08, 0.3), base + Vector3.new(0, -0.16, 0.62), 0.12, BLACK)
		elseif extra == "Plume" then
			-- A knight's crest: three curling feathers over the top, front to back.
			local capTop = topY(0, 0)
			-- Three feathers side by side, the middle one tallest, all curling back.
			for index, tone in ipairs({ accent, accent:Lerp(WHITE, 0.3), accent }) do
				local x = (index - 2) * math.min(halfW, 1.1) * 0.34
				local height = index == 2 and 0.62 or 0.46
				local base = Vector3.new(x, topY(math.abs(x), 0) - 0.05, 0)
				local mid = base + Vector3.new(x * 0.25, height, 0.12)
				local tip = mid + Vector3.new(x * 0.3, height * 0.45, 0.34)
				-- Flat blades, not round rods, so they read as feathers, each with a pale tip.
				capsule("Plume", base, mid, 0.34, tone, Enum.Material.Fabric, 0.11)
				capsule("Plume", mid, tip, 0.26, tone:Lerp(WHITE, 0.25), Enum.Material.Fabric, 0.09)
				add("PlumeTip", Vector3.new(0.16, 0.09, 0.2), CFrame.new(tip), tone:Lerp(WHITE, 0.45),
					Enum.Material.Fabric, "Sphere")
			end
			column("PlumeHolder", 0.14, 0.3, 0, capTop + 0.02, 0, GOLD, Enum.Material.Foil)
		elseif extra == "Lamp" then
			-- A lighthouse lamp room: a gallery rail, glazing round a glowing lamp, and a dome cap.
			local base = topY(0, 0) - 0.04
			local width = math.max(math.min(sideX(base - 0.1, 0), halfW) * 0.9, 0.42)
			-- Each piece overlaps the one under it: the glazing used to sit a whisker above the deck,
			-- which left the lamp room hanging as a group of its own.
			column("LampDeck", 0.14, width * 2 + 0.2, 0, base + 0.05, 0, BLACK, Enum.Material.Metal)
			add("LampGlass", Vector3.new(width * 1.3, 0.8, width * 1.3), CFrame.new(0, base + 0.44, 0), Color3.fromRGB(220, 240, 255), GLASS, "Sphere", 0.55)
			add("LampLight", Vector3.new(0.4, 0.4, 0.4), CFrame.new(0, base + 0.44, 0), Color3.fromRGB(255, 240, 150), NEON, "Ball")
			add("LampDome", Vector3.new(width * 1.4, 0.5, width * 1.4), CFrame.new(0, base + 0.78, 0), accent, nil, "Sphere")
			add("LampTip", Vector3.new(0.14, 0.14, 0.14), CFrame.new(0, base + 1.02, 0), accent:Lerp(WHITE, 0.3), nil, "Ball")
		elseif extra == "Humps" then
			for index, z in ipairs({ 0.05, 0.65 }) do
				local at = Vector3.new(0, topY(0, z), z)
				add("Hump", Vector3.new(0.9, 0.7 - index * 0.1, 0.62), CFrame.new(at + Vector3.new(0, 0.12, 0)), shade(0.08), material, "Sphere")
			end
		elseif extra == "Handle" then
			-- A long door handle down one side of the front, and the line where the door meets the body.
			local x = math.min(sideW, halfW) * 0.62
			local high, low = midY + (top - midY) * 0.55, midY - (midY - bottom) * 0.35
			local _, a, normalA = surfaceFrame(x, high, 0)
			local _, b, normalB = surfaceFrame(x, low, 0)
			capsule("Handle", a + normalA * 0.2, b + normalB * 0.2, 0.12, Color3.fromRGB(215, 220, 230), Enum.Material.Metal)
			for _, pair in ipairs({ { a, normalA }, { b, normalB } }) do
				capsule("HandleMount", pair[1], pair[1] + pair[2] * 0.2, 0.09, Color3.fromRGB(190, 195, 205), Enum.Material.Metal)
			end
		elseif extra == "Backpack" then
			-- An air tank strapped on the back, with a hose over the shoulder.
			local y = midY + 0.1
			local rear = around(math.pi, y)
			add("Tank", Vector3.new(0.75, 1.1, 0.5), CFrame.new(rear + Vector3.new(0, 0, 0.12)), Color3.fromRGB(230, 232, 238), Enum.Material.Metal, "Sphere")
			add("TankCap", Vector3.new(0.26, 0.2, 0.26), CFrame.new(rear + Vector3.new(0, 0.55, 0.12)), accent, nil, "Sphere")
			local shoulder = Vector3.new(sideX(fy - 0.35, 0.1) + 0.08, fy - 0.35, 0.1)
			capsule("Hose", rear + Vector3.new(0.12, 0.5, 0.2), shoulder + Vector3.new(0.05, 0.25, 0.2), 0.08, BLACK)
			capsule("Hose", shoulder + Vector3.new(0.05, 0.25, 0.2), shoulder, 0.08, BLACK)
		elseif extra == "Panel" then
			-- A chest panel of three blinking lights.
			local y = my - 0.42
			if y - 0.2 < bottom + 0.25 then
				y = midY
			end
			decal("PanelPlate", 0, y, 0.7, 0.32, 0.05, shade(0.3), Enum.Material.Metal)
			for index, x in ipairs({ -0.2, 0, 0.2 }) do
				local tones = { Color3.fromRGB(255, 80, 80), Color3.fromRGB(255, 220, 70), Color3.fromRGB(90, 230, 120) }
				decal("PanelLight", x, y, 0.13, 0.13, 0.1, tones[index], NEON)
			end
		elseif extra == "Exhaust" then
			-- Twin exhaust pipes out of the back, puffing.
			local y = bottom + (top - bottom) * 0.28
			for _, side in ipairs({ -1, 1 }) do
				local rear = around(math.pi + side * 0.35, y)
				local tip = rear + Vector3.new(side * 0.1, 0, 0.4)
				capsule("Exhaust", rear - Vector3.new(0, 0, 0.1), tip, 0.2, Color3.fromRGB(180, 184, 192), Enum.Material.Metal)
				floating(add("ExhaustPuff", Vector3.new(0.3, 0.3, 0.3), CFrame.new(tip + Vector3.new(side * 0.05, 0.08, 0.3)), Color3.fromRGB(210, 210, 215), nil, "Ball", 0.35))
			end
		elseif extra == "Surfboard" then
			-- A surfboard carried on the back, standing up behind one shoulder.
			local rear, rearOut = around(math.pi, midY + 0.25)
			local frame = CFrame.new(rear + Vector3.new(0.25, 0, 0) - rearOut * 0.04) * CFrame.Angles(0, 0, -0.25)
			add("Surfboard", Vector3.new(0.7, math.min(top - bottom + 0.6, 2.6), 0.12), frame, accent, nil, "Sphere")
			add("SurfStripe", Vector3.new(0.12, math.min(top - bottom + 0.4, 2.4), 0.14), frame, WHITE, nil, "Sphere")
		elseif extra == "Flaps" then
			-- The flaps of an opened box standing up round the top, and a strip of tape.
			local lidY = topY(0, 0)
			for index, flap in ipairs({ { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
				local out = Vector3.new(flap[1], 0, flap[2])
				local length = index <= 2 and halfW * 1.6 or back * 1.6
				-- Pulled in until the body has a top there to stand on.
				local spread, x, z, surface = 0.92, 0, 0, nil
				repeat
					x, z = flap[1] * halfW * spread, flap[2] * back * spread
					surface = topAt(x, z)
					spread -= 0.16
				until surface or spread < 0.3
				local edge = Vector3.new(x, (surface or lidY) - 0.02, z)
				add("Flap", Vector3.new(index <= 2 and length or 0.07, 0.62, index <= 2 and 0.07 or length),
					CFrame.new(edge + Vector3.new(0, 0.2, 0) + out * 0.02) * CFrame.fromAxisAngle(Vector3.new(-flap[2], 0, flap[1]), -0.4), shade(0.12), material)
			end
			decal("Tape", 0, lidY - 0.3, 0.36, 0.5, 0.05, Color3.fromRGB(214, 190, 140))
		elseif extra == "GumBubble" then
			-- A big pink bubble being blown from the mouth.
			local _, point, normal = surfaceFrame(0, my, 0)
			add("GumBubble", Vector3.new(0.7, 0.7, 0.7), CFrame.new(point + normal * 0.36), accent:Lerp(WHITE, 0.25), nil, "Ball", 0.15)
			add("GumShine", Vector3.new(0.14, 0.1, 0.06), CFrame.new(point + normal * 0.66 + Vector3.new(-0.14, 0.14, 0)), WHITE, nil, "Sphere")
		elseif extra == "Raindrops" then
			-- Drops falling from underneath.
			local water = Color3.fromRGB(120, 180, 255)
			for index = 0, 4 do
				local x = (index - 2) * 0.4
				local z = ((index * 3) % 3 - 1) * 0.25
				local under = underY(math.abs(x), z) or bottom
				floating(add("Raindrop", Vector3.new(0.14, 0.26, 0.14), CFrame.new(x, under - 0.3 - (index % 2) * 0.25, z), water, GLASS, "Sphere"))
			end
		elseif extra == "Bubbles" then
			-- Three bubbles rising off to one side.
			for index = 0, 2 do
				local size = 0.34 - index * 0.08
				floating(add("Bubble", Vector3.new(size, size, size),
					CFrame.new(sideX(top - 0.3, 0) + 0.25 + index * 0.12, top + 0.05 + index * 0.4, -0.2), Color3.fromRGB(200, 235, 255), GLASS, "Ball", 0.35))
			end
		elseif extra == "Stink" then
			-- Wavy green lines rising off the top.
			local stink = Color3.fromRGB(150, 205, 90)
			for index, x in ipairs({ -0.35, 0, 0.35 }) do
				local base = Vector3.new(x, topY(x, 0.1) - 0.05, 0.1)
				local last = base
				for step = 1, 3 do
					local point = base + Vector3.new(((step % 2) * 2 - 1) * 0.12, step * 0.28 + index * 0.04, 0)
					scattered(capsule("Stink", last, point, 0.08, stink, nil, 0.08))
					last = point
				end
			end
		elseif extra == "Noodles" then
			-- Strands hanging from the crown and wobbling down the sides.
			local noodle = color:Lerp(WHITE, 0.25)
			local startY = top - (top - bottom) * 0.1
			for index = 0, 4 do
				local angle = (index - 2) * 0.5 + math.pi
				local last, lastDirection = around(angle, startY)
				last += lastDirection * 0.04
				for step = 1, 3 do
					local point, direction = around(angle + ((step % 2) * 2 - 1) * 0.12, startY - step * (top - bottom) * 0.14)
					point += direction * 0.06
					scattered(capsule("Noodle", last, point, 0.12, noodle, nil, 0.12))
					last = point
				end
			end
		elseif extra == "Fork" then
			-- A fork stuck in the top at a jaunty angle, noodles still wound round its tines.
			local steel = Color3.fromRGB(205, 210, 220)
			local base = Vector3.new(-0.15, topY(-0.15, 0) - 0.1, 0)
			local tipDirection = Vector3.new(-0.35, 1, 0.15).Unit
			local neck = base + tipDirection * 0.55
			capsule("ForkTines", base, neck, 0.28, steel, Enum.Material.Metal, 0.06)
			capsule("ForkHandle", neck, neck + tipDirection * 1.0, 0.1, steel, Enum.Material.Metal, 0.06)
			add("ForkNoodles", Vector3.new(0.5, 0.26, 0.4), CFrame.new(base + tipDirection * 0.25), accent:Lerp(color, 0.5), nil, "Sphere")
		elseif extra == "Umbrella" then
			-- Ribs running down the canopy from a tip at the top.
			local reach = math.min(halfW, 1.5) * 0.9
			for index = 0, 5 do
				local angle = index / 6 * math.pi * 2
				local last = Vector3.new(0, topY(0, 0), 0)
				for step = 1, 2 do
					local r = reach * step / 2
					local x, z = math.sin(angle) * r, -math.cos(angle) * r
					local point = Vector3.new(x, topY(x, z) + 0.01, z)
					capsule("Rib", last, point, 0.07, accent:Lerp(BLACK, 0.35), nil, 0.07)
					last = point
				end
			end
			capsule("UmbrellaTip", Vector3.new(0, topY(0, 0) - 0.05, 0), Vector3.new(0, topY(0, 0) + 0.35, 0), 0.1, Color3.fromRGB(80, 70, 60))
		elseif extra == "Eggshell" then
			-- The broken half of the egg it hatched from, round its base, with a zigzag rim.
			local shell = Color3.fromRGB(252, 248, 236)
			for index = 0, 9 do
				local angle = (index + 0.5) / 10 * math.pi * 2
				local height = index % 2 == 0 and 0.6 or 0.36
				local centreY = bottom + height * 0.8 + 0.02
				local point, direction = around(angle, centreY)
				scattered(add("Eggshell", Vector3.new(0.5, height * 1.6, 0.12), CFrame.lookAt(point + direction * 0.05, point + direction * 2), shell, nil, "Sphere"))
			end
		elseif extra == "InsectLegs" then
			-- Two more pairs of thin jointed legs below the arms, feet planted.
			for _, side in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -0.25, 0.3 }) do
					local y = bottom + (top - bottom) * 0.3
					local hip = Vector3.new(side * (sideX(y, z) - 0.05), y, z)
					local knee = hip + Vector3.new(side * 0.4, 0.22, z * 0.3)
					local toe = Vector3.new(side * (hip.X * side + 0.7), bottom + 0.05, z * 1.4)
					capsule("Leg", hip, knee, 0.12, accent:Lerp(BLACK, 0.2))
					capsule("Leg", knee, toe, 0.1, accent:Lerp(BLACK, 0.2))
				end
			end
		elseif extra == "Buttonholes" then
			-- Four holes in a square on top, with a stitch of thread crossing them.
			local holes = {}
			local spread = math.min(halfW, 1.5) * 0.55
			for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
				local x, z = corner[1] * spread, corner[2] * spread
				local at = Vector3.new(x, topY(math.abs(x), z), z)
				table.insert(holes, at)
				add("Buttonhole", Vector3.new(0.28, 0.08, 0.28), CFrame.new(at), shade(0.5), nil, "Sphere")
			end
			for _, pair in ipairs({ { 1, 3 }, { 2, 4 } }) do
				capsule("Thread", holes[pair[1]] + Vector3.new(0, 0.04, 0), holes[pair[2]] + Vector3.new(0, 0.04, 0), 0.06, accent, Enum.Material.Fabric, 0.06)
			end
		elseif extra == "Drupelets" then
			-- A berry's little round bumps, in rings round the lower body.
			for row, fraction in ipairs({ 0.18, 0.33, 0.48 }) do
				local y = bottom + (top - bottom) * fraction
				local count = row == 2 and 7 or 6
				for index = 0, count - 1 do
					local angle = (index + row * 0.5) / count * math.pi * 2
					local point, direction = around(angle, y)
					add("Drupelet", Vector3.new(0.32, 0.32, 0.32), CFrame.new(point + direction * 0.02), color:Lerp(accent, 0.25 + (index % 2) * 0.15), material, "Ball")
				end
			end
		elseif extra == "TailFin" then
			-- A fish's forked tail out of the back.
			group = "Tail"
			local y = bottom + (top - bottom) * 0.3
			local base = around(math.pi, y)
			pivotAt.Tail = base
			capsule("TailStalk", base - Vector3.new(0, 0, 0.1), base + Vector3.new(0, 0, 0.35), 0.3, accent)
			for _, lobe in ipairs({ 1, -1 }) do
				add("TailFin", Vector3.new(0.12, 0.8, 0.5), CFrame.new(base + Vector3.new(0, lobe * 0.28, 0.6)) * CFrame.Angles(lobe * 0.6, 0, 0),
					accent:Lerp(WHITE, 0.15), nil, "Sphere")
			end
			group = "Body"
		elseif extra == "Folds" then
			-- A brain's squiggly folds across the top.
			local fold = shade(0.18)
			for row = -1, 1 do
				local z = row * 0.45
				local last = nil
				for step = -2, 2 do
					local x = step * 0.28
					local point = Vector3.new(x, topY(math.abs(x), z + (step % 2) * 0.08) + 0.01, z + (step % 2) * 0.08)
					if last then
						capsule("Fold", last, point, 0.08, fold, nil, 0.08)
					end
					last = point
				end
			end
		elseif extra == "SpiderLegs" then
			-- Four long jointed legs a side, arching up and out and down to the ground.
			for _, side in ipairs({ -1, 1 }) do
				for index = 0, 3 do
					local z = -0.5 + index * 0.35
					local y = midY - (top - bottom) * 0.05
					local hip = Vector3.new(side * (sideX(y, z) - 0.08), y, z)
					local knee = hip + Vector3.new(side * 0.45, 0.45, z * 0.35)
					local toe = Vector3.new(side * (math.abs(hip.X) + 0.95), bottom + 0.05, z * 1.6)
					capsule("SpiderLeg", hip, knee, 0.13, accent:Lerp(BLACK, 0.25))
					capsule("SpiderLeg", knee, toe, 0.1, accent:Lerp(BLACK, 0.25))
				end
			end
		elseif extra == "Drum" then
			-- A drumhead on top, a zigzag cord round the side and a stick in each hand.
			local topAt = topY(0, 0)
			local width = sideX(topAt - 0.1, 0)
			add("Drumhead", Vector3.new(width * 2 - 0.02, 0.1, width * 2 - 0.02), CFrame.new(0, topAt + 0.01, 0), Color3.fromRGB(250, 246, 236), nil, "Sphere")
			local high, low = topAt - 0.25, bottom + 0.35
			local last = nil
			for index = 0, 8 do
				local angle = index / 8 * math.pi * 2 - math.pi / 2
				local point, direction = around(angle, index % 2 == 0 and high or low)
				point += direction * 0.05
				if last then
					scattered(capsule("DrumCord", last, point, 0.06, WHITE, Enum.Material.Fabric))
				end
				last = point
			end
			for _, side in ipairs({ -1, 1 }) do
				local hand = handAt[side]
				if hand then
					local tip = hand + Vector3.new(-side * 0.15, 0.75, -0.2)
					capsule("Drumstick", hand, tip, 0.08, BROWN)
					add("DrumstickTip", Vector3.new(0.16, 0.16, 0.16), CFrame.new(tip), Color3.fromRGB(250, 246, 236), nil, "Ball")
				end
			end
		elseif extra == "NinjaBand" then
			-- A band tied round the forehead, its tails flying out behind.
			local y = math.min(ey + 0.42, topY(0, 0) - 0.15)
			local points = {}
			for index = 0, 10 do
				local point, direction = around(index / 10 * math.pi * 2, y)
				table.insert(points, point + direction * 0.04)
			end
			for index = 1, 10 do
				capsule("NinjaBand", points[index], points[index + 1], 0.08, accent, Enum.Material.Fabric, 0.16)
			end
			local knot = around(math.pi, y)
			for _, side in ipairs({ -1, 1 }) do
				capsule("NinjaTail", knot + Vector3.new(0, 0, 0.05), knot + Vector3.new(side * 0.35, -0.2, 0.6), 0.14, accent, Enum.Material.Fabric, 0.05)
			end
		elseif extra == "BatWings" then
			-- Webbed wings: three finger bones fanning from the shoulder with skin stretched between.
			for _, side in ipairs({ -1, 1 }) do
				group = side < 0 and "WingL" or "WingR"
				local y = midY + 0.35
				local rootPoint = Vector3.new(side * sideX(y, back * 0.35) * 0.8, y, back * 0.45)
				pivotAt[group] = rootPoint
				local frame = CFrame.new(rootPoint) * CFrame.Angles(0, -side * 0.5, 0)
				local tips = {}
				for index, angle in ipairs({ 0.75, 0.25, -0.25 }) do
					local tip = (frame * CFrame.Angles(0, 0, side * angle) * CFrame.new(side * (1.3 - index * 0.15), 0, 0)).Position
					tips[index] = tip
					capsule("WingBone", rootPoint, tip, 0.08, accent:Lerp(BLACK, 0.35))
				end
				for index = 1, 2 do
					local centre = (rootPoint + tips[index] + tips[index + 1]) / 3
					local across = tips[index] - tips[index + 1]
					local outward = (centre - rootPoint).Unit
					local normal = across.Unit:Cross(outward).Unit
					add("WingSkin", Vector3.new(across.Magnitude * 1.1, (centre - rootPoint).Magnitude * 2.3, 0.06),
						CFrame.fromMatrix(centre, across.Unit, normal:Cross(across.Unit), normal), accent, nil, "Sphere")
				end
				group = "Body"
			end
		elseif extra == "Quills" then
			-- Rows of quills over the back, all sweeping backward.
			for row, fraction in ipairs({ 0.4, 0.58, 0.76 }) do
				local y = bottom + (top - bottom) * fraction
				for index = 0, 4 do
					local angle = math.pi + (index - 2) * 0.42 + (row % 2) * 0.2
					local point, direction = around(angle, y)
					local tip = point + (direction * 0.7 + Vector3.new(0, 0.25, 0.25)).Unit * (0.5 - row * 0.05)
					scattered(capsule("Quill", point - direction * 0.08, tip, 0.14, accent:Lerp(WHITE, (index % 2) * 0.2)))
				end
			end
		elseif extra == "Claws" then
			-- Built into the hands above.
		elseif extra == "Zigzag" then
			-- A zigzag band all the way round the middle.
			local high, low = midY + 0.18, midY - 0.18
			local last = nil
			for index = 0, 12 do
				local angle = index / 12 * math.pi * 2
				local point, direction = around(angle, index % 2 == 0 and high or low)
				point += direction * 0.03
				if last then
					scattered(capsule("Zigzag", last, point, 0.14, accent, nil, 0.12))
				end
				last = point
			end
		elseif extra == "Cracks" then
			-- Glowing cracks in the crust, as if lava's showing through.
			local lava = Color3.fromRGB(255, 120, 30)
			for index, crack in ipairs({ { 0.9, 0.62, 0.42 }, { -0.95, 0.4, 0.22 }, { 2.4, 0.35, 0.55 } }) do
				local a, direction = around(crack[1], bottom + (top - bottom) * crack[2])
				local b = around(crack[1] + 0.25, bottom + (top - bottom) * (crack[2] - 0.12))
				local c = around(crack[1] + 0.08, bottom + (top - bottom) * (crack[2] - crack[3] * 0.4))
				scattered(capsule("Crack", a + direction * 0.02, b + direction * 0.02, 0.08, lava, NEON, 0.06))
				scattered(capsule("Crack", b + direction * 0.02, c + direction * 0.02, 0.07, lava, NEON, 0.06))
			end
		elseif extra == "Mane" then
			-- A pastel mane down the back of the head.
			local tones = { Color3.fromRGB(255, 150, 200), Color3.fromRGB(190, 150, 255), Color3.fromRGB(140, 210, 255),
				Color3.fromRGB(160, 240, 190), Color3.fromRGB(255, 230, 140) }
			for index, tone in ipairs(tones) do
				local t = (index - 1) / (#tones - 1)
				local y = top - (top - midY) * t * 0.9
				local point, direction = around(math.pi, y)
				capsule("Mane", point + direction * 0.02, point + direction * 0.3 + Vector3.new(0, -0.22, 0), 0.3, tone, nil, 0.22)
			end
		elseif extra == "Ribs" then
			-- A ribcage drawn across the front.
			local startY = my - 0.3
			for index = 0, 2 do
				local y = startY - index * 0.22
				if y - 0.1 > bottom + 0.2 then
					for _, side in ipairs({ -1, 1 }) do
						stroke("Rib", side * 0.06, y, side * 0.42, y - 0.08, 0.09, 0.06, accent)
					end
				end
			end
			stroke("Sternum", 0, startY + 0.08, 0, startY - 0.5, 0.08, 0.07, accent)
		elseif extra == "Tie" then
			local knotY = my - 0.3
			-- As long as it can be without reaching the ground.
			local length = math.clamp(knotY - 0.1 - (bottom + 0.12), 0.3, 0.66)
			decal("Tie", 0, knotY - 0.08 - length / 2, 0.3, length, 0.06, accent)
			decal("TieKnot", 0, knotY, 0.24, 0.2, 0.1, accent:Lerp(BLACK, 0.15))
		end
	end

	--------------------------------------------------------------------------
	-- Body plan
	--
	-- Stubby arms and little feet on anything that doesn't already carry them. A silhouette needs
	-- limbs before it looks like it could move. `look.limbs = "None"` opts out entirely.
	--------------------------------------------------------------------------

	if look.limbs ~= "None" then
		if not carries.Arms and not carries.Tentacles then
			for _, side in ipairs({ -1, 1 }) do
				arm(side, fy - 0.42, 0.22, 0.3)
			end
		end
		-- Things that hover have no business standing on feet.
		local hovers = body == "Ghost" or body == "Cloud"
		if not carries.Feet and not carries.Tentacles and not hovers then
			for _, side in ipairs({ -1, 1 }) do
				foot(side, math.min(halfW * 0.42, 0.62), fz * 0.3, 1)
			end
		end
	end

	if options.glow then
		local light = Instance.new("PointLight")
		light.Color = options.glow
		light.Range = 10 * scale
		light.Brightness = 1.4
		light.Parent = root
	end

	-- Rarity flair: the top tiers sparkle. Legendary a few motes, Mythic a steady shimmer, Secret
	-- a shower — in the brainrot's accent colour, so it's obvious from across a street what
	-- someone has following them. (ParticleEmitters don't draw in viewports, so menus are unaffected.)
	local flair = FLAIR[def.rarity]
	if flair and options.flair ~= false then
		local sparkles = Instance.new("ParticleEmitter")
		sparkles.Name = "Flair"
		sparkles.Color = ColorSequence.new(accent:Lerp(WHITE, 0.3), accent)
		sparkles.LightEmission = 0.8
		sparkles.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.25 * flair.size * scale),
			NumberSequenceKeypoint.new(1, 0),
		})
		sparkles.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		sparkles.Lifetime = NumberRange.new(0.8, 1.6)
		sparkles.Rate = flair.rate
		sparkles.Speed = NumberRange.new(0.6 * scale, 1.6 * scale)
		sparkles.SpreadAngle = Vector2.new(180, 180)
		sparkles.Acceleration = Vector3.new(0, 1.2, 0)
		sparkles.Parent = root
	end

	-- No two faces left flush (an eye level with the face it's on would flicker), before the
	-- welds so only the one part moves.
	ZFight.Fix({ model }, { all = true })

	if not anchored and options.rig then
		-- A companion rig: each group welded to an invisible pivot, joined to its parent by a Motor6D
		-- named after the group, so CompanionAnimations can pose it (see that module).
		local neck = CompanionNeck[body]
		if neck then
			for part, name in pairs(groupOf) do
				if name == "Body" and part ~= root and origin:PointToObjectSpace(part.Position).Y / scale > neck then
					groupOf[part] = "Head"
				end
			end
			pivotAt.Head = Vector3.new(0, neck, 0)
		end
		pivotAt.Body = Vector3.new(0, bottom, 0)
		local pivots = {}
		local function pivotFor(name)
			if pivots[name] then
				return pivots[name]
			end
			local at = pivotAt[name]
			if not at then
				return nil
			end
			local parentPart = root
			if name == "Head" then
				parentPart = pivotFor("Body")
			elseif name ~= "Body" then
				parentPart = (neck and at.Y > neck) and pivotFor("Head") or pivotFor("Body")
			end
			local pivot = Instance.new("Part")
			pivot.Name = "Pivot" .. name
			pivot.Size = Vector3.new(0.2, 0.2, 0.2) * scale
			pivot.Transparency = 1
			pivot.CanCollide = false
			pivot.CanQuery = false
			pivot.CanTouch = false
			pivot.Massless = true
			pivot.CFrame = origin * CFrame.new(at * scale)
			local joint = Instance.new("Motor6D")
			joint.Name = name
			joint.Part0 = parentPart
			joint.Part1 = pivot
			joint.C0 = parentPart.CFrame:ToObjectSpace(pivot.CFrame)
			joint.Parent = pivot
			pivot.Parent = model
			pivots[name] = pivot
			return pivot
		end
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and part ~= root and not string.find(part.Name, "^Pivot") then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = pivotFor(groupOf[part] or "Body") or pivotFor("Body")
				weld.Part1 = part
				weld.Parent = part
			end
		end
		for _, pivot in pairs(pivots) do
			pivot.Anchored = false
		end
		root.RootPriority = 127
		model:SetAttribute("RigBody", body)
		model:SetAttribute("RigScale", scale)
	elseif not anchored then
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and part ~= root then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = root
				weld.Part1 = part
				weld.Parent = part
			end
		end
	end

	return model
end

-- Points a ViewportFrame's camera at a creature built at the origin: from the front, a little
-- above and to one side, and far enough back to fit its body plus whatever it wears on its head.
function BrainrotModels.FrameViewport(viewport, def, distance)
	local camera = viewport.CurrentCamera
	if not camera then
		camera = Instance.new("Camera")
		camera.Parent = viewport
		viewport.CurrentCamera = camera
	end
	local size = (def and def.look and def.look.size) or 1
	local metrics = BrainrotModels.Metrics(def)
	local extent = math.max(metrics.top + 0.9 - metrics.bottom, metrics.halfW * 2 + 0.6)
	local d = (distance or 6.8) * size * math.max(1, extent / 3.2)
	local centerY = (metrics.top + 0.5 + metrics.bottom) / 2 * size
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(d * 0.28, centerY + d * 0.2, -d), Vector3.new(0, centerY, 0))
	return camera
end

return BrainrotModels
