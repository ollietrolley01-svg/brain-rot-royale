-- Vehicle models: every drivable vehicle's body, built from parts. Shared by the server (the
-- vehicles parked on a map), the client (which animates their moving parts) and the galleries.
--
--   VehicleModels.Pick(kind, rng)             -> modelId          kind "car" or "bike"
--   VehicleModels.Build(modelId, rng, opts)   -> model, info
--   VehicleModels.Models[modelId]             -> the definition
--
-- `rng` is a Random. The builder never touches the global math.random, so a map that builds
-- vehicles makes exactly the global rolls its caller makes and nothing after it shifts.
--
-- Model space: the origin is on the ground under the middle of the wheelbase, the front is -Z,
-- the right is +X. Figures are studs.
--
-- The model carries its own contract, so nothing downstream guesses from part names:
--   Chassis        the collidable body and the PrimaryPart (the harness looks for it by name)
--   Hull_*         further colliders welded to it (a roof to stand on)
--   wheel hubs     invisible parts with a Radius attribute (plus Width, Steer, Front), each joined
--                  by a Motor6D named Joint; a client animates spin, and bob and steer where no
--                  pivot above the hub does them. Names: Wheel_FL/FR/RL/RR, bikes Wheel_F/R.
--   pivots         invisible parts with a Pivot attribute, joined by a Motor6D named Joint:
--                    Steer       turns about its own Y (a bike's fork and bars)
--                    Slider      slides along its own Y (a fork's lower legs)
--                    Swing       swings about its own X (a swingarm)
--                    SteerWheel  turns about its own Z by Ratio times the steering angle
--   info.seats     driver and passenger seat frames, model space (and `gunner`, an armed model's gun seat)
--   info.exits     where an occupant is put down, model space, tried in order
--   info.pose      how a rider sits (read by VehicleClient to pose them)
-- Nothing is named Wall, Floor, Roof, Gable, Parapet, Stair, Crate, Table, Shelf or WindowGlass:
-- under workspace.Map those names make a part breakable.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local VehicleModels = {}

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad

-- Detail laid on a face stands off it by at least this much. The z-fight pass leaves 0.06 and
-- goes after anything closer than 0.055, so building clear of it leaves the pass little to do.
local RELIEF = 0.08

-- Names DestructibleService gives health to under workspace.Map.
-- Bodywork above the belt line: these stop a shot even though they are not part of the collision
-- hull (see Build). Matched on the start of a part's name, so PillarBL and PillarCR both count.
-- "Armor" is every armoured car's plate above the belt line AND its armoured glass: shot at, an
-- armoured cabin stops the round and the vehicle takes it (VehicleArmor), where a car's glass lets it
-- through to whoever is behind it.
-- A prefix catches every part it starts, so none may start a glass pane's name or a bit of trim's:
-- "QuarterSill"/"QuarterHead", not "Quarter" (the van's QuarterGlass is glass), and the bikes' exhaust
-- pipes are HeadPipe*, clear of the van's roof "Header". RearDoor, CornerBack and PostC close the van's
-- back above the belt, RearWall the Ranger's cab back (its RearWindow stays glass).
local SOLID_NAMES = { "Pillar", "Sail", "BedWall", "BedCorner", "Tailgate", "DoorTop", "CabHead",
	"PostB", "PostC", "Header", "Roof", "QuarterSill", "QuarterHead", "CornerBack", "RearDoor", "RearWall", "Armor" }

local RESERVED_NAMES = {
	Wall = true, Floor = true, Roof = true, Gable = true, Parapet = true, Stair = true,
	Crate = true, YardCrate = true, Table = true, Shelf = true, WindowGlass = true,
}

local function A(x, y, z)
	return CFrame.Angles(rad(x or 0), rad(y or 0), rad(z or 0))
end

--------------------------------------------------------------------------------
-- Colour roles
--------------------------------------------------------------------------------

-- Roles a scheme doesn't set come from here.
local FIXED = {
	chrome = Color3.fromRGB(206, 210, 216),
	glass = Color3.fromRGB(40, 58, 70),
	tyre = Color3.fromRGB(30, 30, 33),
	rubber = Color3.fromRGB(44, 44, 48),
	lamp = Color3.fromRGB(255, 248, 226),
	drl = Color3.fromRGB(230, 244, 255),
	tail = Color3.fromRGB(232, 30, 38),
	amber = Color3.fromRGB(255, 150, 36),
	lens = Color3.fromRGB(236, 242, 248),
	redlens = Color3.fromRGB(160, 18, 26),
	dash = Color3.fromRGB(32, 32, 37),
	interior = Color3.fromRGB(52, 52, 58),
	plate = Color3.fromRGB(242, 240, 230),
	engine = Color3.fromRGB(62, 64, 70),
	alloy = Color3.fromRGB(168, 172, 180),
	frame = Color3.fromRGB(186, 190, 198),
	gold = Color3.fromRGB(212, 164, 58),
	mesh = Color3.fromRGB(24, 24, 28),
	disc = Color3.fromRGB(150, 150, 156),
	exhaust = Color3.fromRGB(96, 78, 64),
	gauge = Color3.fromRGB(120, 210, 255),
	trim = Color3.fromRGB(34, 34, 38),
	teeth = Color3.fromRGB(242, 238, 220),
	wood = Color3.fromRGB(160, 112, 66),
	banana = Color3.fromRGB(250, 214, 60),
	stalk = Color3.fromRGB(96, 70, 40),
	-- A gun sight's lit reticle and its window (the reflex sights on the vehicle guns).
	reticle = Color3.fromRGB(255, 52, 40),
	ticks = Color3.fromRGB(255, 70, 50),
	sightglass = Color3.fromRGB(190, 226, 220),
}

local ROLE_LOOK = {
	body = { Enum.Material.SmoothPlastic, 0.08, 0 },
	accent = { Enum.Material.SmoothPlastic, 0.08, 0 },
	stripe = { Enum.Material.SmoothPlastic, 0.05, 0 },
	trim = { Enum.Material.SmoothPlastic, 0.02, 0 },
	seat = { Enum.Material.Fabric, 0, 0 },
	rim = { Enum.Material.Metal, 0.2, 0 },
	chrome = { Enum.Material.Metal, 0.14, 0 },
	glass = { Enum.Material.Glass, 0.18, 0.42 },
	tyre = { Enum.Material.SmoothPlastic, 0, 0 },
	rubber = { Enum.Material.SmoothPlastic, 0, 0 },
	lamp = { Enum.Material.Neon, 0, 0 },
	drl = { Enum.Material.Neon, 0, 0 },
	tail = { Enum.Material.Neon, 0, 0 },
	amber = { Enum.Material.Neon, 0, 0 },
	gauge = { Enum.Material.Neon, 0, 0 },
	lens = { Enum.Material.SmoothPlastic, 0.12, 0 },
	redlens = { Enum.Material.SmoothPlastic, 0.1, 0 },
	dash = { Enum.Material.SmoothPlastic, 0, 0 },
	interior = { Enum.Material.SmoothPlastic, 0, 0 },
	plate = { Enum.Material.SmoothPlastic, 0, 0 },
	engine = { Enum.Material.Metal, 0.06, 0 },
	alloy = { Enum.Material.Metal, 0.16, 0 },
	frame = { Enum.Material.Metal, 0.14, 0 },
	gold = { Enum.Material.Metal, 0.22, 0 },
	mesh = { Enum.Material.Metal, 0, 0 },
	disc = { Enum.Material.Metal, 0.12, 0 },
	exhaust = { Enum.Material.Metal, 0.1, 0 },
	teeth = { Enum.Material.SmoothPlastic, 0.12, 0 },
	wood = { Enum.Material.WoodPlanks, 0, 0 },
	banana = { Enum.Material.SmoothPlastic, 0.04, 0 },
	stalk = { Enum.Material.SmoothPlastic, 0, 0 },
	reticle = { Enum.Material.Neon, 0, 0 },
	-- Unlit: a row of lit ticks right by the eye blooms into one red smear.
	ticks = { Enum.Material.SmoothPlastic, 0, 0 },
	sightglass = { Enum.Material.SmoothPlastic, 0.2, 0.88 },
}

--------------------------------------------------------------------------------
-- Builder
--------------------------------------------------------------------------------

local Builder = {}
Builder.__index = Builder

local function newBuilder(model, scheme)
	return setmetatable({
		model = model,
		scheme = scheme,
		anchors = {},   -- visual part -> the part it welds to (false: the chassis)
		joints = {},    -- { part, parent } for hubs and pivots, in the order they were made
		jointed = {},
		chassis = nil,
		hulls = {},
		wheels = {},
		current = nil,
	}, Builder)
end

function Builder:color(role)
	if typeof(role) == "Color3" then
		return role, Enum.Material.SmoothPlastic, 0.05, 0
	end
	local look = ROLE_LOOK[role] or ROLE_LOOK.body
	local color = self.scheme[role] or FIXED[role] or self.scheme.body
	return color, look[1], look[2], look[3]
end

-- Everything made inside `fn` welds to `anchor` (a hub or pivot) instead of the chassis.
function Builder:with(anchor, fn)
	local previous = self.current
	self.current = anchor
	fn()
	self.current = previous
end

-- The roles a client may brighten or dim: head lamps and daytime runners come on with the driver,
-- brake lamps with the brakes. (A gauge lights with the dash, an indicator is left alone.)
local LIT_ROLES = { lamp = true, drl = true, tail = true }

-- Every visual part goes through here: unanchored, non-colliding, massless, no touch or query.
function Builder:make(className, name, size, cframe, role, anchor)
	local part = Instance.new(className)
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CF(cframe) or cframe
	local color, material, reflectance, transparency = self:color(role)
	part.Color = color
	part.Material = material
	part.Reflectance = reflectance
	part.Transparency = transparency
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	-- Small trim casting its own shadow costs more than it shows.
	part.CastShadow = transparency < 0.3 and (size.X > 0.4 or size.Y > 0.4 or size.Z > 0.4)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	-- Lights are lit by their colour role, and clients brighten and dim them (brake lamps under
	-- braking, head lamps when someone is in it), so they say which kind they are.
	if LIT_ROLES[role] then
		part:SetAttribute("Lamp", role)
	end
	part.Parent = self.model
	self.anchors[part] = anchor or self.current or false
	return part
end

function Builder:box(name, size, at, role, anchor)
	return self:make("Part", name, size, at, role, anchor)
end

-- Tall at its +Z, nothing at its -Z: the slope faces up and forward.
function Builder:wedge(name, size, at, role, anchor)
	return self:make("WedgePart", name, size, at, role, anchor)
end

-- A cylinder runs along its own X axis.
function Builder:cyl(name, length, diameter, at, role, anchor)
	local part = self:make("Part", name, V(length, diameter, diameter), at, role, anchor)
	part.Shape = Enum.PartType.Cylinder
	return part
end

-- A cylinder whose axis runs along world Z (a lamp or an exhaust tip seen from the back).
function Builder:cylZ(name, length, diameter, at, role, anchor)
	return self:cyl(name, length, diameter, CF(at) * A(0, 90, 0), role, anchor)
end

function Builder:ball(name, diameter, at, role, anchor)
	local part = self:make("Part", name, V(diameter, diameter, diameter), at, role, anchor)
	part.Shape = Enum.PartType.Ball
	return part
end

local function barFrame(a, b)
	local delta = b - a
	local direction = delta.Unit
	local up = math.abs(direction.Y) > 0.98 and V(0, 0, 1) or V(0, 1, 0)
	local right = direction:Cross(up).Unit
	local trueUp = right:Cross(direction).Unit
	return (a + b) / 2, direction, trueUp, right, delta.Magnitude
end

-- A round bar from `a` to `b`.
function Builder:tube(name, a, b, diameter, role, anchor)
	if (b - a).Magnitude < 0.01 then
		return nil
	end
	local middle, direction, trueUp, right, length = barFrame(a, b)
	return self:cyl(name, length, diameter, CFrame.fromMatrix(middle, direction, trueUp, -right), role, anchor)
end

-- The most a tapered tube's radius may step at a joint. Roblox has no cone, so a taper is a stack
-- of cylinders, and each joint shows a ring the width of its step: at 0.06-0.08 (the bat before
-- this) that ring reads as a see-through seam; at 0.015 it is under a pixel from a close camera.
-- tools/vehicle_models_axis_check.py holds every joint to it.
local TAPER_STEP = 0.015

-- A round bar from `a` to `b` that widens from `d0` across to `d1`, for a run that carries on from
-- a tube `d0` across ending at `a` into one `d1` across starting at `b` (a bat's handle into its
-- barrel). Every joint, the two ends included, steps by the same amount, at most TAPER_STEP on
-- the radius. Returns diameterAt(t), the diameter at a fraction t of the way from `a` to `b`, for
-- anything that has to sit on its surface.
function Builder:taper(name, a, b, d0, d1, role, anchor)
	local count = math.max(1, math.ceil(math.abs(d1 - d0) / 2 / TAPER_STEP - 1e-9) - 1)
	local step = (d1 - d0) / (count + 1)
	for index = 1, count do
		self:tube(name .. index, a:Lerp(b, (index - 1) / count), a:Lerp(b, index / count), d0 + step * index, role, anchor)
	end
	return function(t)
		return d0 + step * math.clamp(math.floor(t * count) + 1, 1, count)
	end
end

-- A square-section bar from `a` to `b`: `width` across, `height` in the plane with world up.
function Builder:beam(name, a, b, width, height, role, anchor)
	if (b - a).Magnitude < 0.01 then
		return nil
	end
	local middle, direction, trueUp, right, length = barFrame(a, b)
	return self:box(name, V(width, height, length), CFrame.fromMatrix(middle, right, trueUp, -direction), role, anchor)
end

-- A bent pipe through `points`, a ball at every bend so the joints stay round.
-- A run of tube through a list of points. Each length is pushed a little PAST its corner so the next
-- one starts inside it, which fills the bend with the tubes themselves. The obvious alternative --
-- a ball at each corner -- is worse twice over: at the tube's own diameter the ball's surface and
-- the tube's touch along a circle instead of crossing, and two curved surfaces that graze each other
-- shimmer as the camera moves (which is what "glitchy pipes" looks like, and which the flat-face
-- z-fight audit cannot see); and at a larger diameter it reads as a bulge at every corner.
function Builder:pipe(name, points, diameter, role, anchor)
	local over = diameter * 0.5
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local along = (b - a)
		if along.Magnitude > 0.01 then
			along = along.Unit
			local from = index > 1 and (a - along * over) or a
			local to = index < #points - 1 and (b + along * over) or b
			self:tube(string.format("%s%d", name, index), from, to, diameter, role, anchor)
		end
	end
end

-- A wedge that fills a box's edge: its slope faces `outward` and `up` (unit axes at right angles),
-- it runs `length` along the third axis, `depth` along outward and `height` along up. `center` is
-- its bounding box's centre. Shorten the box by `depth` on that side and this rounds it off.
function Builder:bevel(name, center, length, depth, height, outward, up, role, anchor)
	return self:wedge(name, V(length, height, depth), CFrame.fromMatrix(center, up:Cross(-outward), up), role, anchor)
end

-- A thin layer on a face: `face` is a point on the face, `normal` its outward normal (an axis),
-- `stand` how far the layer's front stands proud of the face. The layer is `depth` deep, most of
-- it sunk into whatever it sits on, so only its front and edges show.
function Builder:layer(name, size2, face, normal, stand, role, depth, anchor)
	depth = depth or 0.3
	local center = face + normal * (stand - depth / 2)
	local size
	if math.abs(normal.X) > 0.5 then
		size = V(depth, size2.Y, size2.X)
	elseif math.abs(normal.Y) > 0.5 then
		size = V(size2.X, depth, size2.Y)
	else
		size = V(size2.X, size2.Y, depth)
	end
	return self:box(name, size, center, role, anchor)
end

-- A number or registration plate: a thin panel with text on the face that points along `face`.
-- textArea (optional) is {x, y, w, h} in the face's 0..1 scale.
function Builder:plate(name, size, at, text, face, role, textRole, textArea)
	local part = self:box(name, size, at, role or "plate")
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.LightInfluence = 1
	-- Plates and number boards stop drawing well before they'd be readable anyway.
	gui.MaxDistance = 140
	gui.Parent = part
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	if textArea then
		label.Position = UDim2.fromScale(textArea[1], textArea[2])
		label.Size = UDim2.fromScale(textArea[3], textArea[4])
	else
		label.Size = UDim2.fromScale(1, 1)
	end
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = self:color(textRole or "dash")
	label.Parent = gui
	return part
end

local HULL_FRICTION, HULL_FRICTION_WEIGHT = 0.05, 20

-- A collider: transparent, and with the chassis the only collidable parts. Only "Chassis" has mass.
function Builder:hull(name, size, center, density)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CF(center)
	part.Transparency = 1
	part.Anchored = false
	part.CanCollide = true
	part.CanTouch = true
	part.CanQuery = true
	part.Massless = name ~= "Chassis"
	-- Rough ground (Oliver 09-24): the body slides on what it scrapes. With ordinary friction, a belly or
	-- a nose that touched a rock the wheels were still climbing gripped it and the vehicle stopped dead
	-- on it -- measured on a course cut to the real maps' rockiest ground, most cars stuck on the first
	-- rock taller than their clearance. The friction weight makes the body's own (near-zero) friction
	-- win over the ground's. Hitting a wall or a vehicle head-on is unchanged: that is the normal force.
	part.CustomPhysicalProperties = PhysicalProperties.new(density or 1.0, HULL_FRICTION, 0, HULL_FRICTION_WEIGHT, 1)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = self.model
	if name == "Chassis" then
		self.chassis = part
	else
		table.insert(self.hulls, part)
		self.anchors[part] = false
	end
	return part
end

-- The underside (Oliver 09-25: cars hung up on rocks by the belly). The Chassis block is one box whose
-- bottom sat 1.0-1.6 studs off the ground (tools/vehicle_clearance_probe.lua) with square ends, so a
-- rock taller than that caught its flat front face or its bottom edge and held the car while the
-- wheels spun. Now the Chassis keeps its size, mass and CanQuery (shots, blast falloff, bot footprint
-- all read it unchanged) but no longer collides; its collision is three boxes and two ramps:
--   Hull_Body   the block above the ramps, full length -- the same sides, ends and roof as before
--   Hull_Belly  the underside, BELLY_RAISE higher than the block's bottom, between the ramps
--   Hull_NoseRamp / Hull_TailRamp  wedges bevelling the belly's front and rear edges (~25 deg), so
--               a rock the wheels are climbing meets a slope the low-friction hull slides up, not a face
local BELLY_RAISE, BELLY_RAMP, BELLY_RUN = 0.5, 0.9, 2.0
function Builder:belly()
	local chassis = self.chassis
	local size, at = chassis.Size, chassis.Position
	local raise = math.min(BELLY_RAISE, size.Y * 0.25)
	local ramp = math.min(BELLY_RAMP, (size.Y - raise) * 0.45)
	local run = math.min(BELLY_RUN * ramp / BELLY_RAMP, size.Z * 0.2)
	local bottom = -size.Y / 2 + raise
	local upper = size.Y / 2 - (bottom + ramp)
	self:hull("Hull_Body", V(size.X, upper, size.Z), at + V(0, bottom + ramp + upper / 2, 0), 0.1)
	self:hull("Hull_Belly", V(size.X, ramp, size.Z - 2 * run), at + V(0, bottom + ramp / 2, 0), 0.1)
	-- A WedgePart's slope runs from its bottom front edge up to its top back edge; turned over about Z
	-- the cut-away corner is the bottom front (-Z), turned over about X it is the bottom rear (+Z).
	for _, end_ in ipairs({ { "Hull_NoseRamp", -1, CFrame.Angles(0, 0, math.pi) }, { "Hull_TailRamp", 1, CFrame.Angles(math.pi, 0, 0) } }) do
		local part = self:hull(end_[1], V(size.X, ramp, run), at + V(0, bottom + ramp / 2, end_[2] * (size.Z / 2 - run / 2)), 0.1)
		local wedge = Instance.new("WedgePart")
		for _, key in ipairs({ "Name", "Size", "Transparency", "Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless",
			"CustomPhysicalProperties", "Parent" }) do
			wedge[key] = part[key]
		end
		wedge.CFrame = part.CFrame * end_[3]
		self.hulls[table.find(self.hulls, part)] = wedge
		self.anchors[part], self.anchors[wedge] = nil, false
		part:Destroy()
	end
	chassis.CanCollide = false
end

local function invisible(name, frame, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = V(0.2, 0.2, 0.2)
	part.CFrame = frame
	part.Transparency = 1
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = parent
	return part
end

-- A joint that moves what's welded to it: see Pivot in the header. `parent` is the pivot it
-- hangs from (the chassis when nil).
function Builder:pivot(name, frame, kind, parent, attributes)
	local part = invisible(name, frame, self.model)
	part:SetAttribute("Pivot", kind)
	for key, value in pairs(attributes or {}) do
		part:SetAttribute(key, value)
	end
	table.insert(self.joints, { part = part, parent = parent })
	self.jointed[part] = true
	return part
end

function Builder:hubPart(name, frame, radius, width, opts)
	local hub = invisible(name, frame, self.model)
	hub:SetAttribute("Radius", radius)
	hub:SetAttribute("Width", width)
	hub:SetAttribute("Steer", opts.steer == true)
	hub:SetAttribute("Front", frame.Position.Z < 0)
	table.insert(self.joints, { part = hub, parent = opts.parent })
	self.jointed[hub] = true
	table.insert(self.wheels, hub)
	return hub
end

--------------------------------------------------------------------------------
-- Wheels
--------------------------------------------------------------------------------

-- A ring of boxes round `frame`'s X axis.
function Builder:ring(name, frame, radius, thickness, width, segments, role, phase)
	-- Well past the inscribed chord: neighbours meet end to end, and ends that only just touch are
	-- two nearly-parallel faces a hundredth apart, which is exactly what z-fights. The overlap is
	-- buried inside the ring, so nothing shows.
	local chord = 2 * (radius + thickness / 2) * math.tan(math.pi / segments) + 0.16
	for index = 1, segments do
		local angle = (index - 1 + (phase or 0)) * 360 / segments
		-- Neighbours overlap at their outer corners; alternating widths keeps their side faces
		-- out of one plane.
		local w = index % 2 == 0 and width - 0.12 or width
		self:box(string.format("%s%d", name, index), V(w, thickness, chord), frame * A(angle, 0, 0) * CF(0, radius + thickness / 2, 0), role)
	end
end

-- A car wheel: tyre with a bulged sidewall, a rim lip, a dark barrel with the brake disc in it,
-- spokes, centre cap and nuts. `side` is -1 on the left, 1 on the right; the face points that way.
-- opts: steer, parent, spokes, style ("sport", "steel", "offroad", "mesh"), tread (block count)
function Builder:roadWheel(name, center, radius, width, side, opts)
	opts = opts or {}
	local hub = self:hubPart(name, CF(center), radius, width, opts)
	self:with(hub, function()
		local frame = CF(center)
		self:cyl(name .. "_Tyre", width, radius * 2, frame, "tyre")
		self:cyl(name .. "_Wall", width - 0.22, radius * 2 + 0.07, frame, "tyre")

		-- The face is a stack of discs, each standing 0.06 further out than the one under it, so
		-- a few parts give a lipped rim round a dark barrel (a ring of boxes cost sixteen) and no two
		-- discs share a plane.
		local face = side * width / 2
		local rimRadius = radius * (opts.rimScale or 0.66)
		local stand = 0
		local function nextLayer()
			stand += 0.06
			return CF(center + V(face + side * (stand - 0.15), 0, 0))
		end
		if opts.sneaker then
			-- A white stripe round the sidewall, like the sole of a trainer.
			self:cyl(name .. "_Sneaker", 0.3, radius * 2 - 0.34, nextLayer(), "plate")
			self:cyl(name .. "_SneakerInner", 0.3, radius * 2 - 0.64, nextLayer(), "tyre")
		end
		self:cyl(name .. "_Lip", 0.3, rimRadius * 2 + 0.12, nextLayer(), "rim")
		self:cyl(name .. "_Barrel", 0.3, rimRadius * 2 - 0.16, nextLayer(), "mesh")
		self:cyl(name .. "_Disc", 0.3, rimRadius * 1.5, nextLayer(), "disc")

		local style = opts.style or "sport"
		local spokes = opts.spokes or 5
		if style == "steel" then
			-- A pressed steel wheel: a dished face with round holes and a big cap.
			self:cyl(name .. "_Face", 0.3, rimRadius * 1.66, nextLayer(), "rim")
			local holeBase = nextLayer()
			for index = 1, 6 do
				local angle = (index - 0.5) * 60
				self:cyl(string.format("%s_Hole%d", name, index), 0.3, rimRadius * 0.3, holeBase * A(angle, 0, 0) * CF(0, rimRadius * 0.58, 0), "mesh")
			end
			self:cyl(name .. "_Cap", 0.3, rimRadius * 0.7, nextLayer(), "chrome")
		else
			local spokeWidth = style == "mesh" and 0.1 or 0.2
			local count = style == "mesh" and spokes * 2 or spokes
			local spokeBase = nextLayer()
			for index = 1, count do
				local angle = (index - 1) * 360 / count
				self:box(string.format("%s_Spoke%d", name, index), V(0.3, rimRadius * 0.9, spokeWidth), spokeBase * A(angle, 0, 0) * CF(0, rimRadius * 0.52, 0), "rim")
				if style == "offroad" then
					self:cyl(string.format("%s_Bolt%d", name, index), 0.3, 0.12, spokeBase * A(angle + 180 / count, 0, 0) * CF(0, rimRadius - 0.04, 0), "chrome")
				end
			end
			local nutBase = nextLayer()
			for index = 1, 5 do
				local angle = (index - 0.5) * 72
				self:cyl(string.format("%s_Nut%d", name, index), 0.3, 0.1, nutBase * A(angle, 0, 0) * CF(0, rimRadius * 0.34, 0), "chrome")
			end
			self:cyl(name .. "_Cap", 0.3, rimRadius * 0.5, nextLayer(), "chrome")
		end

		if opts.tread then
			local blocks = opts.tread
			for index = 1, blocks do
				local angle = (index - 1) * 360 / blocks
				local blockFrame = frame * A(angle, 0, 0) * CF(0, radius + 0.04, 0)
				-- One knob per step, alternating width. Two staggered rows cost 27 parts a wheel and
				-- read the same from any distance a player sees a tyre from.
				local w = index % 2 == 0 and width * 0.44 or width * 0.62
				self:box(string.format("%s_Tread%d", name, index), V(w, 0.2, 0.36), blockFrame, "tyre")
			end
		end
	end)
	return hub
end

-- A spoked motorbike wheel you can see through: a tyre of segments with knobs, a rim ring, wire
-- spokes, the hub, a brake disc and (opts.sprocket) the rear sprocket.
function Builder:spokedWheel(name, center, radius, width, opts)
	opts = opts or {}
	local frame = opts.frame and (CF(center) * opts.frame.Rotation) or CF(center)
	local hub = self:hubPart(name, frame, radius, width, opts)
	self:with(hub, function()
		local segments = opts.segments or 14
		local tyreDepth = opts.tyreDepth or 0.36
		local rimRadius = radius - tyreDepth
		local axle = CF(center)
		self:ring(name .. "_Tyre", axle, rimRadius, tyreDepth, width, segments, "tyre")
		self:ring(name .. "_Rim", axle, rimRadius - 0.14, 0.14, width * 0.42, segments, "rim", 0.5)
		if opts.knobbly then
			for index = 1, segments do
				local knobFrame = axle * A((index - 0.5) * 360 / segments, 0, 0) * CF(0, radius + 0.06, 0)
				if index % 2 == 0 then
					self:box(string.format("%s_Knob%d", name, index), V(width * 0.46, 0.14, 0.26), knobFrame, "tyre")
				else
					self:box(string.format("%s_KnobL%d", name, index), V(width * 0.3, 0.14, 0.26), knobFrame * CF(-width * 0.34, 0, 0), "tyre")
					self:box(string.format("%s_KnobR%d", name, index), V(width * 0.3, 0.14, 0.26), knobFrame * CF(width * 0.34, 0, 0), "tyre")
				end
			end
		end

		local spokes = opts.spokes or 12
		for index = 1, spokes do
			local angle = rad((index - 1) * 360 / spokes)
			local rimPoint = center + V(0, math.cos(angle) * (rimRadius - 0.16), math.sin(angle) * (rimRadius - 0.16))
			local hubSide = (index % 2 == 0) and 1 or -1
			local hubPoint = center + V(hubSide * width * 0.3, math.cos(angle + 0.5) * 0.22, math.sin(angle + 0.5) * 0.22)
			self:tube(string.format("%s_Spoke%d", name, index), hubPoint, rimPoint, 0.05, "chrome")
		end
		self:cyl(name .. "_Hub", width * 0.72, 0.42, axle, "alloy")
		if opts.disc then
			self:cyl(name .. "_Disc", 0.05, radius * (opts.discScale or 0.66), axle * CF(opts.disc * width * 0.5, 0, 0), "disc")
			self:cyl(name .. "_DiscCarrier", 0.08, 0.5, axle * CF(opts.disc * width * 0.3, 0, 0), "gold")
		end
		if opts.sprocket then
			self:cyl(name .. "_Sprocket", 0.06, opts.sprocketSize or 1.05, axle * CF(opts.sprocket * width * 0.55, 0, 0), "alloy")
		end
	end)
	return hub
end

-- A cast motorbike wheel: a rounded tyre (tread and two shoulders), a dark barrel with twin
-- spokes on both faces, a hub cap, and brake discs ("twin", "left", "right") or a sprocket
-- (opts.sprocket -1 or 1) standing off the faces.
function Builder:castWheel(name, center, radius, width, opts)
	opts = opts or {}
	local hub = self:hubPart(name, CF(center), radius, width, opts)
	self:with(hub, function()
		local axle = CF(center)
		self:cyl(name .. "_Tread", width * 0.7, radius * 2, axle, "tyre")
		for _, s in ipairs({ -1, 1 }) do
			self:cyl(string.format("%s_Shoulder%s", name, s < 0 and "L" or "R"), width * 0.16, radius * 2 - 0.22, axle * CF(s * width * 0.42, 0, 0), "tyre")
		end
		local rimRadius = radius - 0.3
		local face = width / 2 + 0.1
		self:cyl(name .. "_Barrel", face * 2, rimRadius * 2, axle, "mesh")
		local spokes = opts.spokes or 3
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			for index = 1, spokes do
				local angle = (index - 1) * 360 / spokes
				-- Twin spokes stand out by different amounts, so where they cross at the hub their
				-- faces aren't in one plane.
				for twin, spread in ipairs({ -10, 10 }) do
					local stand = twin == 1 and 0.08 or 0.14
					self:box(string.format("%s_Spoke%s%d%d", name, n, index, twin), V(stand, rimRadius * 0.92, 0.08),
						axle * CF(s * (face + stand / 2), 0, 0) * A(angle + spread, 0, 0) * CF(0, rimRadius * 0.5, 0), "rim")
				end
			end
			self:cyl(name .. "_Cap" .. n, 0.3, 0.34, axle * CF(s * (face + 0.22 - 0.15), 0, 0), "alloy")
			local disc = opts.discs == "twin" or (opts.discs == "right" and s > 0) or (opts.discs == "left" and s < 0)
			if disc or opts.sprocket == s then
				-- The carrier the disc or sprocket is bolted to. They stand 0.32 off the face, past the cap
				-- (which ends at 0.22), so without it they hung 0.08 clear of the wheel: a floating disc,
				-- with its caliper holding it up.
				self:cyl(name .. "_Carrier" .. n, 0.34, 0.46, axle * CF(s * (face + 0.155), 0, 0), "alloy")
			end
			if disc then
				self:cyl(name .. "_Disc" .. n, 0.05, radius * 1.12, axle * CF(s * (face + 0.32), 0, 0), "disc")
			elseif opts.sprocket == s then
				self:cyl(name .. "_Sprocket", 0.05, opts.sprocketSize or 0.95, axle * CF(s * (face + 0.32), 0, 0), "alloy")
			end
		end
	end)
	return hub
end

--------------------------------------------------------------------------------
-- Car pieces
--------------------------------------------------------------------------------

-- Body side round a wheel opening: columns from the opening's circle up to `top`, spanning
-- `xInner`..`xOuter` (both on the side `side` points to).
function Builder:archPanel(name, axleY, axleZ, radius, top, side, xInner, xOuter, columns, role)
	local width = 2 * radius / columns
	local function circle(z)
		local d = z - axleZ
		return axleY + math.sqrt(math.max(0, radius * radius - d * d))
	end
	for index = 1, columns do
		local z0 = axleZ - radius + (index - 1) * width
		local z1 = z0 + width
		local bottom = math.max(circle(z0), circle(z1))
		if top - bottom > 0.03 then
			self:box(string.format("%s%d", name, index), V(xOuter - xInner, top - bottom, width),
				V(side * (xInner + xOuter) / 2, (bottom + top) / 2, (z0 + z1) / 2), role)
		end
	end
end

-- An arc of flat segments over a wheel: a mudguard or fender. Neighbours alternate width so their
-- sides never lie in one plane (which reads as z-fighting).
function Builder:arc(name, axle, radius, from, to, segments, width, thickness, role, anchor)
	local step = (to - from) / segments
	local chord = 2 * radius * math.tan(rad(math.abs(step) / 2)) + 0.16
	for index = 1, segments do
		local angle = from + (index - 0.5) * step
		local w = index % 2 == 0 and width - 0.12 or width
		self:box(string.format("%s%d", name, index), V(w, thickness, chord), CF(axle) * A(angle, 0, 0) * CF(0, radius, 0), role, anchor)
	end
end

-- Rounds a body block's two front (or rear) corners: the block is built `2 * radius` narrower than
-- the body and a vertical cylinder stands at each corner, so the corner is round in plan instead of
-- square. `faceZ` is the outer face, `into` is +1 when the block runs back from it and -1 when it
-- runs forward.
function Builder:roundCorners(name, halfWidth, radius, faceZ, into, y, height, role)
	for _, s in ipairs({ -1, 1 }) do
		-- A touch shorter than the block it rounds, so its flat ends do not land in the block's own
		-- top and bottom planes (which is what z-fights).
		self:cyl(string.format("%s%s", name, s < 0 and "L" or "R"), height - 0.14, radius * 2,
			CF(V(s * (halfWidth - radius), y, faceZ + into * radius)) * A(0, 0, 90), role)
	end
end

-- A flared lip following a wheel opening from `from` to `to` degrees (0 is straight up, positive
-- toward the back).
function Builder:archLip(name, axleY, axleZ, radius, x, width, thickness, from, to, segments, role)
	local step = (to - from) / segments
	local chord = 2 * (radius + thickness) * math.tan(rad(math.abs(step) / 2)) + 0.16
	for index = 1, segments do
		local angle = from + (index - 0.5) * step
		local w = index % 2 == 0 and width - 0.12 or width
		self:box(string.format("%s%d", name, index), V(w, thickness, chord),
			CF(x, axleY, axleZ) * A(angle, 0, 0) * CF(0, radius + thickness / 2, 0), role)
	end
end

-- A lamp on a face: housing, lit element, and a lens over it, stepped out RELIEF apart.
-- `face` is the point on the face, `normal` the face's outward axis.
function Builder:lamp(name, face, normal, size2, role, lensRole)
	self:layer(name .. "_Housing", size2 + Vector2.new(0.3, 0.3), face, normal, 0.1, "dash")
	self:layer(name, size2, face, normal, 0.18, role)
	if lensRole then
		-- Behind the lit element, not over it: the cover is opaque (see the lens roles), so a lamp is
		-- a bright element standing proud of a glossy surround, and nothing here is see-through.
		self:layer(name .. "_Lens", size2 + Vector2.new(0.16, 0.16), face, normal, 0.12, lensRole)
	end
end

-- A tooth on a face that points along -Z: two mirrored wedges making a triangle `width` across at
-- the jaw line `jawY` and `height` long, pointing down (`dir` -1) or up (1), standing `stand` proud.
function Builder:tooth(name, x, jawY, faceZ, width, height, dir, stand, role)
	-- The wedge's flat bottom lies along the jaw, so its up points the way the tooth does.
	local up = V(0, dir, 0)
	local y = jawY + dir * height / 2
	local z = faceZ - stand + 0.06
	for _, s in ipairs({ -1, 1 }) do
		-- The wedge's right angle sits on the tooth's centre line at the jaw.
		local toward = V(-s, 0, 0)
		local frame = CFrame.fromMatrix(V(x + s * width / 4, y, z), up:Cross(toward), up)
		self:wedge(string.format("%s%s", name, s < 0 and "L" or "R"), V(0.12, height, width / 2), frame, role)
	end
end

-- A ridge of scutes along a line: little two-sided wedges like a crocodile's back.
function Builder:scute(name, center, length, width, height, role)
	self:wedge(name .. "Front", V(width, height, length / 2), CF(center + V(0, 0, -length / 4)), role)
	self:wedge(name .. "Back", V(width, height, length / 2), CF(center + V(0, 0, length / 4)) * A(0, 180, 0), role)
end

function Builder:bucketSeat(name, at, width, depth, height, rake)
	self:box(name .. "_Cushion", V(width, 0.42, depth), at, "seat")
	local back = CF(at + V(0, 0.21, depth / 2 - 0.2)) * A(rake or 12, 0, 0) * CF(0, height / 2, 0)
	self:box(name .. "_Back", V(width - 0.14, height, 0.4), back, "seat")
	for _, s in ipairs({ -1, 1 }) do
		self:box(string.format("%s_Bolster%s", name, s < 0 and "L" or "R"), V(0.26, height * 0.8, 0.5), back * CF(s * (width / 2 - 0.1), -height * 0.08, -0.12), "interior")
		self:box(string.format("%s_Side%s", name, s < 0 and "L" or "R"), V(0.2, 0.5, depth * 0.9), CF(at + V(s * (width / 2 + 0.01), 0.14, 0)), "interior")
	end
	self:box(name .. "_Headrest", V(width * 0.52, 0.5, 0.36), back * CF(0, height / 2 + 0.3, 0.02), "seat")
end

-- A steering wheel on a SteerWheel pivot, facing the driver along `column` (pointing from the
-- dash toward the driver).
function Builder:steeringWheel(name, center, column, radius)
	local frame = CFrame.lookAt(center, center - column)
	local pivot = self:pivot(name, frame, "SteerWheel", nil, { Ratio = 7 })
	self:with(pivot, function()
		local segments = 14
		local chord = 2 * radius * math.tan(math.pi / segments) + 0.18
		for index = 1, segments do
			local t = index % 2 == 0 and 0.14 or 0.1
			self:box(string.format("%s_Rim%d", name, index), V(chord, t, t), frame * A(0, 0, (index - 1) * 360 / segments) * CF(0, radius, 0), "rubber")
		end
		self:box(name .. "_SpokeH", V(radius * 1.9, 0.1, 0.07), frame * CF(0, 0, 0.02), "dash")
		-- Thicker than the spoke it crosses, so the two don't share a face where they meet.
		self:box(name .. "_SpokeV", V(0.1, radius, 0.13), frame * CF(0, -radius / 2, 0.02), "dash")
		self:cyl(name .. "_Boss", 0.2, radius * 0.7, frame * A(0, 90, 0), "dash")
	end)
	return pivot
end

--------------------------------------------------------------------------------
-- Models
--------------------------------------------------------------------------------

VehicleModels.Models = {}

-- Rotster: a chunky hot hatch. The everyday car: nimble, forgiving, and the one you'll find most.
VehicleModels.Models.Rotster = {
	kind = "car",
	displayName = "Rotster",
	weight = 30,
	schemes = {
		{ name = "Sahur Red", body = Color3.fromRGB(204, 44, 46), accent = Color3.fromRGB(30, 30, 34), stripe = Color3.fromRGB(245, 245, 240), seat = Color3.fromRGB(46, 44, 48), rim = Color3.fromRGB(218, 220, 226) },
		{ name = "Ice Pop", body = Color3.fromRGB(118, 196, 238), accent = Color3.fromRGB(246, 246, 248), stripe = Color3.fromRGB(34, 86, 150), seat = Color3.fromRGB(70, 110, 150), rim = Color3.fromRGB(240, 242, 246) },
		{ name = "Bananini", body = Color3.fromRGB(248, 208, 44), accent = Color3.fromRGB(26, 26, 28), stripe = Color3.fromRGB(26, 26, 28), seat = Color3.fromRGB(40, 40, 44), rim = Color3.fromRGB(30, 30, 34) },
		{ name = "Mint Scoop", body = Color3.fromRGB(150, 222, 186), accent = Color3.fromRGB(250, 242, 218), stripe = Color3.fromRGB(228, 94, 124), seat = Color3.fromRGB(196, 150, 112), rim = Color3.fromRGB(250, 242, 218) },
		{ name = "Graphite Lime", body = Color3.fromRGB(62, 66, 74), accent = Color3.fromRGB(62, 66, 74), stripe = Color3.fromRGB(172, 238, 58), seat = Color3.fromRGB(30, 30, 34), rim = Color3.fromRGB(172, 238, 58) },
	},
	build = function(b)
		local HW = 3.3
		-- Oliver: "make the car wheel models more flat" -- width (tw) narrowed from 1.05 to 0.8, a
		-- ratio of 0.40 to 0.31 (radius r UNCHANGED: the suspension samples the wheel's radius for
		-- ride height, so touching that would also change how the car sits, not just how it looks).
		-- tw is the wheel builder's WIDTH argument, not a raw cylinder Size -- Builder:roadWheel maps
		-- it onto whichever local axis each part needs, so this is the correct place to flatten it.
		local r, tw, track = 1.3, 0.8, 2.85
		local fz, rz = -4.2, 4.3
		local R = 1.52
		local sill, shoulder, belt, roofY = 1.0, 3.15, 3.4, 5.75
		local noseZ, tailZ = -6.35, 6.45
		local wsBase, wsTop = -1.9, 0.0
		local hatchTop, hatchFoot = 3.9, 6.1
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.1, 2.1, 12.6), V(0, 2.3, 0.05), 1.3)
		b:hull("Hull_Roof", V(5.6, 0.3, 4.2), V(0, roofY + 0.1, 1.95), 0.1)

		-- Body shell: nose and tail blocks, doors, and the panels round each wheel opening.
		b:box("NoseBlock", V(5.9, shoulder - sill, fz - R - noseZ), V(0, (sill + shoulder) / 2, (noseZ + fz - R) / 2), "body")
		b:box("TailBlock", V(5.9, shoulder - sill, tailZ - rz - R), V(0, (sill + shoulder) / 2, (rz + R + tailZ) / 2), "body")
		b:roundCorners("NoseCorner", HW, 0.35, noseZ, 1, (sill + shoulder) / 2, shoulder - sill, "body")
		b:roundCorners("TailCorner", HW, 0.35, tailZ, -1, (sill + shoulder) / 2, shoulder - sill, "body")
		b:box("EngineBay", V(3.8, 1.9, wsBase - noseZ - 0.05), V(0, 2.2, (noseZ + 0.05 + wsBase) / 2), "mesh")
		b:box("CabinPan", V(5.7, 0.2, hatchFoot - wsBase), V(0, 1.35, (wsBase + hatchFoot) / 2), "interior")
		b:box("BootFloor", V(4.34, 0.2, hatchFoot - hatchTop + 0.2), V(0, 2.3, (hatchTop + hatchFoot) / 2 + 0.1), "interior")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Door" .. n, V(0.5, shoulder - sill, doorBack - doorFront), V(s * (HW - 0.25), (sill + shoulder) / 2, (doorFront + doorBack) / 2), "body")
			b:archPanel("ArchPanelF" .. n, r, fz, R, shoulder, s, HW - 1.15, HW, 10, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, shoulder, s, HW - 1.15, HW, 10, "body")
			b:box("WellF" .. n, V(0.1, 1.9, 2.9), V(s * 1.95, 1.95, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 1.9, 2.9), V(s * 1.95, 1.95, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * 3.32, 0.36, 0.2, -96, 96, 10, "trim")
			b:archLip("LipR" .. n, r, rz, R, s * 3.32, 0.36, 0.2, -96, 96, 10, "trim")
		end

		-- Shoulder: a bevel down each side, the bonnet with its bulge, the tail deck.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:bevel("Shoulder" .. n, V(s * (HW - 0.25), (shoulder + belt) / 2, (noseZ + tailZ) / 2), tailZ - noseZ, 0.5, belt - shoulder, V(s, 0, 0), UP, "body")
			b:box("DoorTop" .. n, V(0.3, belt - shoulder, hatchFoot - wsBase), V(s * 2.65, (shoulder + belt) / 2, (wsBase + hatchFoot) / 2), "body")
			-- The rocker: the same treatment along the bottom edge, which is what turns a slab side into
			-- a flank with a line through it.
			b:bevel("Rocker" .. n, V(s * (HW - 0.17), sill + 0.19, (noseZ + tailZ) / 2), tailZ - noseZ, 0.34, 0.38, V(s, 0, 0), V(0, -1, 0), "body")
		end
		b:box("BonnetDeck", V(6.16, belt - shoulder, wsBase - noseZ - 0.35), V(0, (shoulder + belt) / 2, (noseZ + 0.35 + wsBase) / 2), "body")
		b:bevel("BonnetNose", V(0, (shoulder + belt) / 2, noseZ + 0.175), 6.16, 0.35, belt - shoulder, FRONT, UP, "body")
		b:box("BonnetBulge", V(2.3, 0.12, 3.3), V(0, belt + 0.06, -3.75), "body")
		b:bevel("BonnetBulgeNose", V(0, belt + 0.06, -5.55), 2.3, 0.3, 0.12, FRONT, UP, "body")
		b:bevel("TailDeck", V(0, (shoulder + belt) / 2, tailZ - 0.175), 6.16, 0.35, belt - shoulder, BACK, UP, "body")

		-- Glasshouse.
		b:wedge("Windscreen", V(5.6, roofY - belt, wsTop - wsBase), V(0, (belt + roofY) / 2, (wsBase + wsTop) / 2), "glass")
		-- 5.44 wide, so its feet end just inside the C-pillars' instead of sharing their plane.
		b:wedge("HatchGlass", V(5.44, roofY - belt, hatchFoot - hatchTop), CF(0, (belt + roofY) / 2, (hatchTop + hatchFoot) / 2) * A(0, 180, 0), "glass")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local tilt = A(0, 0, s * 6.9)
			b:box("SideGlass" .. n, V(0.08, roofY - belt, hatchTop - wsTop), CF(s * 2.86, (belt + roofY) / 2, (wsTop + hatchTop) / 2) * tilt, "glass")
			b:beam("PillarA" .. n, V(s * 2.94, belt, wsBase), V(s * 2.74, roofY + 0.05, wsTop + 0.05), 0.3, 0.26, "accent")
			b:box("PillarB" .. n, V(0.32, roofY - belt + 0.18, 0.36), CF(s * 2.88, (belt + roofY) / 2, 1.75) * tilt, "trim")
			b:wedge("PillarC" .. n, V(0.36, roofY - belt, hatchFoot - hatchTop), CF(s * 2.93, (belt + roofY) / 2, (hatchTop + hatchFoot) / 2) * A(0, 180, 0), "accent")
			b:box("WindowSeal" .. n, V(0.12, 0.1, hatchTop - wsTop + 0.16), V(s * 3.02, belt + 0.1, (wsTop + hatchTop) / 2), "trim")
		end
		-- The roof is built round the gunner's hatch (Mounts below: the roof gun rides a ring round it and
		-- the gunner stands in it, Oliver 09-24 "make the car guns controllable by a gunner seat"): four
		-- panels leave a 2.2-stud square hole centred at z 2.4 -- wide enough for a body turning in it (hips
		-- 2 across), with the square coaming and the ring over its edge -- and the roof reads the same from
		-- the street when it is built unarmed, because an unarmed build gets a hatch lid instead.
		local hatchZ, hatchHalf = 2.4, 1.1
		local roofBack = hatchTop + 0.1
		b:box("RoofPanel", V(5.3, 0.25, hatchZ - hatchHalf - 0.2), V(0, roofY + 0.125, (0.2 + hatchZ - hatchHalf) / 2), "accent")
		b:box("RoofPanelBack", V(5.3, 0.25, roofBack - hatchZ - hatchHalf), V(0, roofY + 0.125, (hatchZ + hatchHalf + roofBack) / 2), "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:box(s < 0 and "RoofPanelL" or "RoofPanelR", V(2.65 - hatchHalf, 0.25, 2 * hatchHalf),
				V(s * (hatchHalf + 2.65) / 2, roofY + 0.125, hatchZ), "accent")
		end
		b.hatch = { at = V(0, roofY + 0.25, hatchZ), half = hatchHalf }
		b:bevel("RoofBrow", V(0, roofY + 0.125, 0.05), 5.3, 0.3, 0.25, FRONT, UP, "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:bevel(s < 0 and "RoofEdgeL" or "RoofEdgeR", V(s * 2.76, roofY + 0.125, (hatchTop + 0.1 - 0.1) / 2), hatchTop + 0.2, 0.22, 0.25, V(s, 0, 0), UP, "accent")
		end
		-- The roof gun (Mounts below) swings right round over the roof, so what is on it keeps out of
		-- the gun's way: the spoiler is 0.7 deep, not 0.9, and 0.06 lower, so the flash hider clears
		-- it with the gun turned to the rear and tipped right down; and there is no shark fin any
		-- more -- at z 3.0 the yoke and cheeks went through it at every turn, and anywhere else on
		-- this roof the ammo box or the receiver does. The gun is the roof's feature now.
		b:box("Spoiler", V(5.12, 0.16, 0.7), CF(0, roofY + 0.24, hatchTop + 0.02) * A(-7, 0, 0), "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:beam(s < 0 and "WiperL" or "WiperR", V(s * 0.35, belt + 0.28, -1.72), V(s * 2.15, belt + 0.2, -1.78), 0.08, 0.06, "trim")
		end
		b:beam("WiperRear", V(-0.2, 4.2, 5.2), V(1.3, 4.6, 4.85), 0.06, 0.06, "trim")

		-- Nose: grille, badge, lamps, indicators.
		local noseFace = V(0, 0, noseZ)
		b:layer("GrilleSurround", Vector2.new(3.3, 0.95), noseFace + V(0, 2.3, 0), FRONT, 0.1, "trim")
		for index, y in ipairs({ 2.0, 2.2, 2.4, 2.6 }) do
			b:layer("GrilleSlat" .. index, Vector2.new(3.05, 0.07), noseFace + V(0, y, 0), FRONT, 0.2, "mesh")
		end
		b:cylZ("Badge", 0.3, 0.42, V(0, 2.3, noseZ - 0.28 + 0.15), "stripe")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:layer("HeadlampHousing" .. n, Vector2.new(1.66, 0.84), noseFace + V(s * 2.37, 2.72, 0), FRONT, 0.1, "dash")
			b:layer("Headlamp" .. n, Vector2.new(1.16, 0.3), noseFace + V(s * 2.37, 2.8, 0), FRONT, 0.18, "lamp")
			b:layer("Drl" .. n, Vector2.new(1.02, 0.08), noseFace + V(s * 2.37, 2.52, 0), FRONT, 0.18, "drl")
			b:ball("Projector" .. n, 0.34, V(s * 2.62, 2.8, noseZ - 0.1), "lens")
			b:layer("HeadlampLens" .. n, Vector2.new(1.4, 0.54), noseFace + V(s * 2.37, 2.72, 0), FRONT, 0.12, "lens")
			b:layer("Indicator" .. n, Vector2.new(0.3, 0.22), noseFace + V(s * 3.08, 2.2, 0), FRONT, 0.14, "amber")
		end

		-- Bumpers.
		for _, e in ipairs({ { "Front", -1 }, { "Rear", 1 } }) do
			local label, dir = e[1], e[2]
			local z = dir * 6.55
			local outward = V(0, 0, dir)
			b:box(label .. "Bumper", V(6.1, 0.95, 0.5), V(0, 1.3, z), "trim")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:box(label .. "BumperCorner" .. n, V(0.3, 0.95, 0.2), V(s * 3.2, 1.3, dir * 6.4), "trim")
				b:bevel(label .. "BumperBevel" .. n, V(s * 3.2, 1.3, dir * 6.65), 0.95, 0.3, 0.3, outward, V(s, 0, 0), "trim")
			end
			b:box(label .. "Splitter", V(5.6, 0.1, 0.4), V(0, 0.78, dir * 6.6), "mesh")
		end
		local bumperFront, bumperBack = V(0, 0, -6.8), V(0, 0, 6.8)
		b:layer("Intake", Vector2.new(3.2, 0.34), bumperFront + V(0, 1.08, 0), FRONT, 0.1, "mesh")
		b:plate("PlateFront", V(1.7, 0.42, 0.3), bumperFront + V(0, 1.55, -0.12 + 0.15), "ROT 042", Enum.NormalId.Front)
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:cylZ("FogBezel" .. n, 0.3, 0.46, bumperFront + V(s * 2.4, 1.1, -0.08 + 0.15), "mesh")
			b:cylZ("Fog" .. n, 0.3, 0.32, bumperFront + V(s * 2.4, 1.1, -0.16 + 0.15), "lamp")
		end

		-- Tail: lamps that wrap round the corner, plate, handle, diffuser, twin pipes.
		local tailFace = V(0, 0, tailZ)
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:layer("TailHousing" .. n, Vector2.new(1.36, 0.64), tailFace + V(s * 2.4, 2.72, 0), BACK, 0.1, "dash")
			b:layer("Tail" .. n, Vector2.new(0.84, 0.46), tailFace + V(s * 2.6, 2.72, 0), BACK, 0.18, "tail")
			b:layer("Reverse" .. n, Vector2.new(0.3, 0.46), tailFace + V(s * 1.94, 2.72, 0), BACK, 0.18, "lamp")
			b:layer("TailLens" .. n, Vector2.new(1.26, 0.56), tailFace + V(s * 2.4, 2.72, 0), BACK, 0.12, "redlens")
			b:layer("TailWrapHousing" .. n, Vector2.new(0.4, 0.64), V(s * HW, 2.72, 6.12), V(s, 0, 0), 0.16, "dash")
			b:layer("TailWrap" .. n, Vector2.new(0.3, 0.46), V(s * HW, 2.72, 6.12), V(s, 0, 0), 0.3, "tail")
			b:layer("Reflector" .. n, Vector2.new(0.6, 0.12), bumperBack + V(s * 2.5, 1.5, 0), BACK, 0.1, "redlens")
		end
		b:plate("PlateRear", V(1.7, 0.42, 0.3), tailFace + V(0, 2.3, 0.12 - 0.15), "ROT 042", Enum.NormalId.Back)
		b:layer("HatchHandle", Vector2.new(1.0, 0.12), tailFace + V(0, 2.84, 0), BACK, 0.12, "chrome")
		b:layer("Diffuser", Vector2.new(3.2, 0.3), bumperBack + V(0, 0.98, 0), BACK, 0.1, "mesh")
		for index, x in ipairs({ 1.95, 2.4 }) do
			b:cylZ("Exhaust" .. index, 0.5, 0.3, V(x, 0.95, 6.8), "chrome")
			b:cylZ("ExhaustBore" .. index, 0.36, 0.2, V(x, 0.95, 6.8), "mesh")
		end

		-- Sides: stripe, handles, seams, skirts, mirrors, repeaters, fuel cap.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local side = V(s, 0, 0)
			-- Each decal on this face stands off it by its own amount, so no two of their fronts
			-- share a plane where they cross.
			b:layer("Stripe" .. n, Vector2.new(tailZ - noseZ - 0.2, 0.12), V(s * HW, 3.07, (noseZ + tailZ) / 2), side, 0.08, "stripe")
			b:layer("Handle" .. n, Vector2.new(0.55, 0.14), V(s * HW, 2.9, 0.9), side, 0.14, "chrome")
			b:layer("SeamFront" .. n, Vector2.new(0.05, 1.86), V(s * HW, 2.08, doorFront + 0.1), side, 0.02, "mesh")
			b:layer("SeamBack" .. n, Vector2.new(0.05, 1.86), V(s * HW, 2.08, doorBack - 0.1), side, 0.02, "mesh")
			b:layer("Skirt" .. n, Vector2.new(doorBack - doorFront - 0.16, 0.34), V(s * HW, 1.12, (doorFront + doorBack) / 2), side, 0.26, "trim")
			b:layer("Repeater" .. n, Vector2.new(0.3, 0.1), V(s * HW, 2.55, -2.95), side, 0.32, "amber")
			b:box("MirrorFoot" .. n, V(0.3, 0.3, 0.5), V(s * 3.3, 3.55, -1.62), "trim")
			b:box("Mirror" .. n, V(0.62, 0.46, 0.36), V(s * 3.68, 3.7, -1.6), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.44, 0.28), V(s * 3.68, 3.7, -1.42), BACK, 0.08, "chrome")
		end
		b:layer("FuelCap", Vector2.new(0.42, 0.42), V(3.11, 3.75, 4.4), V(1, 0, 0), 0.08, "trim")

		-- Cabin.
		b:box("Dash", V(5.5, 0.5, 0.9), V(0, 3.05, -1.42), "dash")
		b:box("Binnacle", V(1.3, 0.3, 0.5), V(-1.35, 3.5, -1.18), "dash")
		for index, x in ipairs({ -1.62, -1.08 }) do
			b:cylZ("Gauge" .. index, 0.3, 0.32, V(x, 3.5, -0.93 + 0.1 - 0.15), "gauge")
		end
		b:box("Screen", V(0.9, 0.5, 0.2), CF(0, 3.55, -1.12) * A(-15, 0, 0), "mesh")
		b:box("Console", V(0.72, 0.8, 2.2), V(0, 1.85, -0.3), "interior")
		b:tube("GearStick", V(0.05, 2.25, 0.1), V(0.05, 2.75, 0.2), 0.08, "chrome")
		b:ball("GearKnob", 0.22, V(0.05, 2.8, 0.2), "dash")
		b:tube("Column", V(-1.35, 3.2, -1.3), V(-1.35, 3.5, -0.75), 0.18, "dash")
		b:steeringWheel("SteeringWheel", V(-1.35, 3.55, -0.62), V(0, 0.45, 0.89).Unit, 0.46)
		b:bucketSeat("SeatDriver", V(-1.35, 1.6, 0.55), 1.8, 1.8, 2.1, 12)
		b:bucketSeat("SeatPassenger", V(1.35, 1.6, 0.55), 1.8, 1.8, 2.1, 12)
		b:box("RearBench", V(4.2, 0.42, 1.5), V(0, 1.7, 3.05), "seat")
		b:box("RearBenchBack", V(4.04, 1.9, 0.38), CF(0, 1.88, 3.72) * A(14, 0, 0) * CF(0, 0.95, 0), "seat")
		for _, s in ipairs({ -1, 1 }) do
			b:box(s < 0 and "RearHeadrestL" or "RearHeadrestR", V(1.0, 0.48, 0.3), CF(s * 1.3, 1.88, 3.72) * A(14, 0, 0) * CF(0, 2.15, 0.02), "seat")
		end
		b:box("ParcelShelf", V(4.3, 0.08, 1.7), V(0, 3.62, 5.0), "dash")

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "sport", spokes = 5 })
		end

		return {
			seats = {
				driver = CF(-1.35, 1.66, 0.55),
				passengers = { CF(1.35, 1.66, 0.55), CF(-1.25, 1.76, 3.0), CF(1.25, 1.76, 3.0) },
			},
			exits = { CF(-5.4, 0, 0.3), CF(5.4, 0, 0.3), CF(-5.4, 0, 3.4), CF(5.4, 0, 3.4), CF(0, 0, -9.4), CF(0, 0, 9.4), CF(0, 6.2, 1.9) },
			pose = { kind = "car", wheel = V(-1.35, 3.55, -0.62), wheelRadius = 0.46 },
		}
	end,
}

-- Patapim Scrambler: a tall, long-travel motocross bike. Climbs anything, lands anything.
VehicleModels.Models.PatapimScrambler = {
	kind = "bike",
	displayName = "Patapim Scrambler",
	weight = 30,
	schemes = {
		{ name = "Mudslinger", body = Color3.fromRGB(246, 128, 24), accent = Color3.fromRGB(246, 246, 244), stripe = Color3.fromRGB(28, 28, 32), seat = Color3.fromRGB(28, 28, 32), rim = Color3.fromRGB(36, 36, 42), number = "27", numberText = Color3.fromRGB(246, 128, 24) },
		{ name = "Swamp Racer", body = Color3.fromRGB(96, 196, 60), accent = Color3.fromRGB(28, 28, 32), stripe = Color3.fromRGB(246, 246, 244), seat = Color3.fromRGB(28, 60, 30), rim = Color3.fromRGB(210, 212, 218), number = "8", numberText = Color3.fromRGB(246, 246, 244) },
		{ name = "Blue Thunder", body = Color3.fromRGB(34, 98, 220), accent = Color3.fromRGB(246, 246, 248), stripe = Color3.fromRGB(252, 212, 36), seat = Color3.fromRGB(30, 34, 46), rim = Color3.fromRGB(252, 212, 36), number = "51", numberText = Color3.fromRGB(34, 98, 220) },
		{ name = "Grape Soda", body = Color3.fromRGB(132, 70, 208), accent = Color3.fromRGB(178, 240, 70), stripe = Color3.fromRGB(246, 246, 244), seat = Color3.fromRGB(32, 30, 40), rim = Color3.fromRGB(32, 30, 40), number = "69", numberText = Color3.fromRGB(88, 40, 150) },
		{ name = "Redline", body = Color3.fromRGB(214, 34, 42), accent = Color3.fromRGB(246, 246, 244), stripe = Color3.fromRGB(24, 24, 26), seat = Color3.fromRGB(24, 24, 26), rim = Color3.fromRGB(214, 34, 42), number = "1", numberText = Color3.fromRGB(214, 34, 42) },
	},
	build = function(b)
		local fr, rr = 1.45, 1.42
		local fz, rz = -3.3, 3.05
		local head = V(0, 4.0, -2.05)
		local down = V(0, -0.899, -0.438)
		local function P(t, x)
			return head + down * t + V(x or 0, 0, 0)
		end
		local steerRotation = CFrame.fromMatrix(Vector3.zero, V(1, 0, 0), -down)
		local function onAxis(t, x)
			return CF(P(t, x)) * steerRotation
		end

		b:hull("Chassis", V(1.0, 1.6, 5.0), V(0, 2.6, -0.05), 1.5)

		-- Steering: fork, clamps, bars, number board and front fender all turn together.
		local steer = b:pivot("Steer_F", onAxis(0), "Steer")
		local slider = b:pivot("Slider_F", onAxis(1.8), "Slider", steer)
		b:with(steer, function()
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				-- Down to 2.0 along the fork (it was 1.45), so the lower leg (on the slider, which
				-- VehicleDynamics slides 0.89 out and 1.34 in along the fork) stays inside it: with a
				-- 0.25 overlap the wheel, lowers and fender came right off the bike with the front
				-- wheel hanging (vehicle_models_runtime_check).
				b:tube("ForkUpper" .. n, P(-0.42, s * 0.36), P(2.0, s * 0.36), 0.3, "gold")
			end
			b:box("ClampTop", V(1.06, 0.16, 0.5), onAxis(-0.3), "alloy")
			b:box("ClampBottom", V(1.06, 0.22, 0.56), onAxis(0.5), "alloy")
			for _, s in ipairs({ -1, 1 }) do
				b:tube(s < 0 and "RiserL" or "RiserR", P(-0.36, s * 0.28), V(s * 0.28, 4.62, -1.8), 0.16, "alloy")
			end
			b:tube("BarCentre", V(-0.5, 4.62, -1.8), V(0.5, 4.62, -1.8), 0.14, "trim")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:ball("BarBend" .. n, 0.14, V(s * 0.5, 4.62, -1.8), "trim")
				b:tube("BarOuter" .. n, V(s * 0.5, 4.62, -1.8), V(s * 1.3, 4.82, -1.6), 0.13, "trim")
				b:tube("Grip" .. n, V(s * 0.95, 4.73, -1.69), V(s * 1.32, 4.83, -1.6), 0.22, "rubber")
				b:beam("Lever" .. n, V(s * 0.55, 4.64, -1.92), V(s * 1.18, 4.66, -2.06), 0.06, 0.05, "chrome")
				-- Hand guard: a brace from the bar end curling forward, and the plastic shell on it.
				b:pipe("GuardBrace" .. n, { V(s * 1.33, 4.83, -1.6), V(s * 1.4, 4.78, -1.95), V(s * 1.2, 4.72, -2.22), V(s * 0.66, 4.68, -1.98) }, 0.07, "alloy")
				b:box("HandGuard" .. n, V(0.1, 0.4, 0.72), CF(s * 1.33, 4.86, -1.98) * A(0, s * 22, 0), "accent")
				b:wedge("HandGuardLip" .. n, V(0.24, 0.18, 0.4), CF(s * 1.33, 5.13, -1.98) * A(0, s * 22, 0) * A(0, 180, 0), "accent")
			end
			b:box("Reservoir", V(0.26, 0.18, 0.2), V(0.56, 4.68, -1.98), "dash")
			b:box("BarPad", V(0.86, 0.24, 0.3), V(0, 4.75, -1.8), "stripe")

			local board = CF(0, 3.86, -2.66) * A(22, 0, 0)
			b:plate("NumberBoard", V(1.26, 1.24, 0.12), board, b.scheme.number or "27", Enum.NormalId.Front, "accent", "numberText", { 0.06, 0.02, 0.88, 0.6 })
			b:box("Headlight", V(0.58, 0.28, 0.3), board * CF(0, -0.36, -0.06 - 0.1 + 0.15), "lamp")
			b:box("HeadlightLens", V(0.76, 0.34, 0.26), board * CF(0, -0.42, -0.06 - 0.02 + 0.15), "lens")
			for _, s in ipairs({ -1, 1 }) do
				b:beam(s < 0 and "BoardBracketL" or "BoardBracketR", board.Position + board.RightVector * s * 0.38 + board.LookVector * -0.08, P(0.72, s * 0.36), 0.08, 0.08, "trim")
			end

		end)
		b:with(slider, function()
			-- The fender rides on the fork legs, so it follows the wheel and never meets the tyre.
			local axle = V(0, fr, fz)
			local fenderRadius = fr + 0.34
			b:arc("FrontFender", axle, fenderRadius, -58, 28, 8, 0.62, 0.07, "accent")
			b:box("FenderBeak", V(0.44, 0.07, 0.8), CF(axle) * A(-58, 0, 0) * CF(0, fenderRadius, -0.36) * A(-14, 0, 0), "accent")
			b:box("FenderBridge", V(0.84, 0.12, 0.36), CF(axle) * A(24, 0, 0) * CF(0, fenderRadius + 0.08, 0), "trim")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				-- From 0.95: at full compression its top is still under the top clamp, at full extension
				-- still 0.16 up inside the upper.
				b:tube("ForkLower" .. n, P(0.95, s * 0.36), P(2.84, s * 0.36), 0.22, "chrome")
				b:beam("ForkGuard" .. n, P(2.05, s * 0.36) + V(0, 0, -0.16), P(2.62, s * 0.36) + V(0, 0, -0.16), 0.16, 0.08, "accent")
				b:box("AxleFoot" .. n, V(0.26, 0.36, 0.42), onAxis(2.84, s * 0.36), "trim")
			end
			b:box("Caliper", V(0.14, 0.34, 0.3), CF(-0.24, fr + 0.36, fz + 0.3) * A(30, 0, 0), "gold")
		end)
		b:spokedWheel("Wheel_F", V(0, fr, fz), fr, 0.44, { steer = true, parent = slider, frame = steerRotation, knobbly = true, disc = -1 })

		-- Frame.
		b:tube("HeadTube", P(-0.28), P(0.6), 0.38, "frame")
		b:tube("DownTube", V(0, 3.5, -2.18), V(0, 1.62, -1.08), 0.26, "frame")
		b:ball("DownTubeFoot", 0.26, V(0, 1.62, -1.08), "frame")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:beam("Spar" .. n, V(s * 0.2, 3.72, -1.86), V(s * 0.47, 3.28, -0.58), 0.18, 0.38, "frame")
			b:beam("SparDrop" .. n, V(s * 0.47, 3.28, -0.58), V(s * 0.47, 2.26, 0.46), 0.18, 0.4, "frame")
			b:pipe("Cradle" .. n, { V(s * 0.05, 1.62, -1.08), V(s * 0.24, 1.36, -0.2), V(s * 0.34, 1.5, 0.35), V(s * 0.44, 2.2, 0.5) }, 0.18, "frame")
			-- Its back end runs up into the underside of the rear fender (at 3.76 it stopped 0.09 short,
			-- leaving 0.4 studs of bare tube hanging under the tail).
			-- Its front end starts in the top of the spar (it used to start 0.26 clear of everything,
			-- in the air above the throttle body).
			b:tube("Subframe" .. n, V(s * 0.45, 3.24, -0.45), V(s * 0.3, 3.9, 3.1), 0.12, "frame")
			b:tube("SubframeStay" .. n, V(s * 0.46, 2.45, 0.6), V(s * 0.33, 3.74, 2.35), 0.1, "frame")
		end
		b:cyl("PivotBolt", 1.1, 0.2, CF(0, 2.3, 0.55), "chrome")

		-- Engine: crankcase and covers, the finned cylinder leaning forward, throttle body.
		b:box("Crankcase", V(0.84, 0.95, 1.4), V(0, 1.95, -0.25), "engine")
		b:cyl("IgnitionCover", 0.14, 0.92, CF(-0.6, 1.95, -0.12), "alloy")
		b:cyl("ClutchCover", 0.14, 0.98, CF(0.6, 1.9, -0.18), "alloy")
		b:cyl("WaterPump", 0.14, 0.42, CF(0.72, 1.66, -0.66), "gold")
		local cylinder = CF(0, 2.86, -0.66) * A(-12, 0, 0)
		b:box("Cylinder", V(0.7, 0.8, 0.7), cylinder, "engine")
		for index = 1, 5 do
			b:box("Fin" .. index, V(0.9, 0.06, 0.9), cylinder * CF(0, -0.34 + (index - 1) * 0.16, 0), "alloy")
		end
		b:box("CylinderHead", V(0.88, 0.28, 0.88), cylinder * CF(0, 0.52, 0), "engine")
		b:tube("ThrottleBody", V(0, 3.0, -0.28), V(0, 3.12, 0.3), 0.34, "alloy")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Radiator" .. n, V(0.12, 1.05, 0.86), CF(s * 0.54, 3.28, -1.22) * A(0, -s * 8, 0), "mesh")
			b:box("Peg" .. n, V(0.52, 0.12, 0.26), V(s * 0.74, 2.02, 0.42), "trim")
		end
		b:beam("ShiftLever", V(-0.54, 1.98, 0.02), V(-0.66, 2.1, -0.56), 0.07, 0.07, "chrome")
		b:beam("BrakePedal", V(0.56, 1.92, 0.3), V(0.66, 1.76, -0.46), 0.07, 0.07, "chrome")
		b:cyl("FrontSprocket", 0.08, 0.55, CF(-0.62, 1.95, 0.3), "alloy")

		-- Bodywork.
		b:box("Tank", V(1.06, 0.62, 1.2), V(0, 4.05, -0.95), "body")
		b:bevel("TankNose", V(0, 4.05, -1.72), 1.06, 0.34, 0.62, V(0, 0, -1), V(0, 1, 0), "body")
		b:cyl("TankCap", 0.1, 0.3, CF(0, 4.4, -1.15) * A(0, 0, 90), "trim")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local shroud = CF(s * 0.72, 3.62, -1.32) * A(4, -s * 10, 0)
			b:box("Shroud" .. n, V(0.14, 1.16, 1.66), shroud, "body")
			b:wedge("ShroudTip" .. n, V(0.14, 1.16, 0.45), shroud * CF(0, 0, -1.055), "body")
			b:box("ShroudStripe" .. n, V(0.3, 0.3, 1.4), shroud * CF(s * (0.07 + 0.1 - 0.15), -0.2, 0.06), "stripe")
			-- Side panel from under the seat down over the airbox, its top tucked under the seat edge.
			b:plate("SidePlate" .. n, V(0.3, 0.92, 1.7), CF(s * 0.52, 3.38, 1.72) * A(-10, 0, 0), b.scheme.number or "27",
				s < 0 and Enum.NormalId.Left or Enum.NormalId.Right, "accent", "numberText")
		end
		b:box("Airbox", V(0.8, 0.72, 1.0), V(0, 3.38, 1.28), "dash")
		b:box("Seat", V(0.96, 0.34, 2.5), V(0, 3.98, 1.36), "seat")
		b:beam("SeatRamp", V(0, 3.98, 0.16), V(0, 4.28, -0.72), 0.82, 0.32, "seat")
		for _, s in ipairs({ -1, 1 }) do
			b:layer(s < 0 and "SeatPipingL" or "SeatPipingR", Vector2.new(2.4, 0.08), V(s * 0.48, 3.9, 1.36), V(s, 0, 0), 0.06, "stripe")
		end
		-- The tail: one moulded piece from under the seat, as wide as the seat where they meet.
		b:beam("RearFender", V(0, 3.86, 2.1), V(0, 4.28, 4.9), 1.08, 0.2, "body")
		b:beam("RearFenderLip", V(0, 4.28, 4.9), V(0, 4.4, 5.4), 0.66, 0.12, "body")
		b:box("TailLight", V(0.34, 0.16, 0.3), CF(0, 4.22, 4.9) * A(-9, 0, 0), "tail")

		-- Exhaust: an expansion chamber round the right side and a silencer up under the tail.
		b:pipe("HeadPipe", { V(0.1, 2.92, -0.92), V(0.3, 2.36, -1.42), V(0.5, 1.8, -1.0), V(0.7, 2.2, 0.3), V(0.82, 3.1, 1.5) }, 0.24, "chrome")
		b:pipe("Chamber", { V(0.46, 1.78, -1.18), V(0.6, 1.58, -0.4), V(0.72, 2.18, 0.55), V(0.8, 2.95, 1.35) }, 0.34, "exhaust")
		b:tube("Silencer", V(0.82, 3.04, 1.3), V(0.84, 3.52, 3.4), 0.5, "alloy")
		b:tube("SilencerCap", V(0.84, 3.50, 3.36), V(0.845, 3.56, 3.58), 0.64, "dash")
		-- The mouth: a dark bore set back inside the can, so the end reads as a hole rather than as a
		-- bright disc you can seem to see through.
		b:tube("SilencerBore", V(0.838, 3.44, 3.14), V(0.845, 3.55, 3.55), 0.34, "mesh")
		b:tube("Shock", V(0, 3.55, 0.75), V(0, 2.45, 1.24), 0.16, "chrome")
		b:tube("ShockSpring", V(0, 3.35, 0.84), V(0, 2.7, 1.13), 0.34, "stripe")

		-- Swingarm and the rear wheel swing together.
		local swing = b:pivot("Swing_R", CF(0, 2.3, 0.55), "Swing")
		b:with(swing, function()
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:beam("Swingarm" .. n, V(s * 0.42, 2.3, 0.62), V(s * 0.4, 1.8, 2.0), 0.18, 0.42, "alloy")
				b:beam("SwingarmTail" .. n, V(s * 0.4, 1.8, 2.0), V(s * 0.38, 1.42, 3.2), 0.18, 0.3, "alloy")
				b:box("AxleBlock" .. n, V(0.3, 0.3, 0.42), V(s * 0.38, rr, rz), "trim")
			end
			-- From the front sprocket's plane (x -0.62) to the rear one's (x -0.33, see spokedWheel): run
			-- straight down x -0.5 they missed the rear sprocket by 0.17 and ended in the air beside it.
			b:beam("ChainTop", V(-0.62, 2.22, 0.3), V(-0.33, 1.95, rz), 0.08, 0.1, "dash")
			b:beam("ChainBottom", V(-0.62, 1.68, 0.3), V(-0.33, rr - 0.53, rz), 0.08, 0.1, "dash")
			b:box("ChainGuide", V(0.24, 0.36, 0.6), V(-0.46, 1.2, 2.2), "stripe")
			b:box("RearCaliper", V(0.14, 0.36, 0.4), V(0.36, rr - 0.55, rz + 0.2), "gold")
		end)
		b:spokedWheel("Wheel_R", V(0, rr, rz), rr, 0.6, { parent = swing, knobbly = true, disc = 1, discScale = 0.56, sprocket = -1 })

		return {
			seats = {
				driver = CF(0, 3.99, 0.7),
				passengers = { CF(0, 4.0, 2.1) },
			},
			exits = { CF(-2.8, 0, 0.2), CF(2.8, 0, 0.2), CF(-2.8, 0, -2.2), CF(2.8, 0, 2.4), CF(0, 0, -6.2), CF(0, 0, 6.2) },
			pose = { kind = "bike", grips = V(1.15, 4.78, -1.66), pegs = V(0.74, 2.1, 0.42) },
		}
	end,
}

-- Crocodilo Ranger: a tall four-wheel-drive pickup with a crocodile's grin. Wide to turn, but it
-- climbs what nothing else can, and two more ride in the bed.
VehicleModels.Models.CrocodiloRanger = {
	kind = "car",
	displayName = "Crocodilo Ranger",
	weight = 22,
	schemes = {
		{ name = "Swamp Croc", body = Color3.fromRGB(84, 122, 62), accent = Color3.fromRGB(46, 58, 38), stripe = Color3.fromRGB(222, 204, 128), seat = Color3.fromRGB(88, 70, 52), rim = Color3.fromRGB(46, 46, 50) },
		{ name = "Albino", body = Color3.fromRGB(234, 230, 216), accent = Color3.fromRGB(164, 70, 70), stripe = Color3.fromRGB(120, 176, 110), seat = Color3.fromRGB(150, 60, 60), rim = Color3.fromRGB(226, 226, 230) },
		{ name = "Nile Gold", body = Color3.fromRGB(198, 150, 62), accent = Color3.fromRGB(70, 54, 34), stripe = Color3.fromRGB(248, 228, 164), seat = Color3.fromRGB(70, 54, 34), rim = Color3.fromRGB(70, 54, 34) },
		{ name = "Night Hunter", body = Color3.fromRGB(38, 50, 46), accent = Color3.fromRGB(22, 24, 24), stripe = Color3.fromRGB(190, 250, 70), seat = Color3.fromRGB(28, 30, 30), rim = Color3.fromRGB(190, 250, 70), teeth = Color3.fromRGB(190, 250, 70) },
		{ name = "Tangerine Snap", body = Color3.fromRGB(240, 118, 38), accent = Color3.fromRGB(34, 34, 38), stripe = Color3.fromRGB(250, 236, 200), seat = Color3.fromRGB(34, 34, 38), rim = Color3.fromRGB(34, 34, 38) },
	},
	build = function(b)
		local HW = 3.6
		-- Oliver: "make the car wheel models more flat" -- tw narrowed 1.35 -> 1.15 (ratio 0.39 ->
		-- 0.33, top of the "quarter to a third" band, kept a touch wider than the others as this is
		-- the off-road model). r UNCHANGED (ride height; see Rotster's comment for why).
		local r, tw, track = 1.75, 1.15, 3.2
		local fz, rz = -4.9, 4.6
		local R = 2.05
		local sill, shoulder, belt, roofY = 1.9, 4.1, 4.35, 6.9
		local noseZ, tailZ = -7.45, 7.35
		local wsBase, wsTop = -1.85, -0.5
		local cabBack = 2.1
		local bedY, railY = 3.1, 4.75
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.9, 2.5, 14.6), V(0, 3.35, -0.05), 1.3)
		b:hull("Hull_Roof", V(6.3, 0.3, 2.6), V(0, 7.0, 0.85), 0.1)

		-- Body shell.
		b:box("NoseBlock", V(6.4, shoulder - sill, fz - R - noseZ), V(0, (sill + shoulder) / 2, (noseZ + fz - R) / 2), "body")
		b:box("TailBlock", V(6.4, bedY - sill, tailZ - rz - R), V(0, (sill + bedY) / 2, (rz + R + tailZ) / 2), "body")
		b:roundCorners("NoseCorner", 3.6, 0.4, noseZ, 1, (sill + shoulder) / 2, shoulder - sill, "body")
		b:roundCorners("TailCorner", 3.6, 0.4, tailZ, -1, (sill + bedY) / 2, bedY - sill, "body")
		b:box("EngineBay", V(4.2, 2.1, wsBase - noseZ - 0.05), V(0, 3.05, (noseZ + 0.05 + wsBase) / 2), "mesh")
		b:box("CabinPan", V(6.5, 0.2, cabBack - wsBase), V(0, 2.2, (wsBase + cabBack) / 2), "interior")
		b:box("BedFloor", V(4.1, 0.25, tailZ - 0.3 - cabBack), V(0, bedY - 0.125, (cabBack + tailZ - 0.3) / 2), "mesh")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Door" .. n, V(0.5, shoulder - sill, doorBack - doorFront), V(s * (HW - 0.25), (sill + shoulder) / 2, (doorFront + doorBack) / 2), "body")
			b:archPanel("ArchPanelF" .. n, r, fz, R, shoulder, s, HW - 1.5, HW, 12, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, shoulder, s, HW - 1.5, HW, 12, "body")
			b:box("WellF" .. n, V(0.1, 2.3, 3.8), V(s * 2.05, 2.85, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 2.3, 3.8), V(s * 2.05, 2.85, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * 3.75, 0.5, 0.34, -100, 100, 12, "trim")
			b:archLip("LipR" .. n, r, rz, R, s * 3.75, 0.5, 0.34, -100, 100, 12, "trim")
			b:bevel("Shoulder" .. n, V(s * (HW - 0.22), (shoulder + belt) / 2, (noseZ + cabBack) / 2), cabBack - noseZ, 0.44, belt - shoulder, V(s, 0, 0), UP, "body")
			b:box("DoorTop" .. n, V(0.32, belt - shoulder, cabBack - wsBase), V(s * 3.06, (shoulder + belt) / 2, (wsBase + cabBack) / 2), "body")
			b:bevel("Rocker" .. n, V(s * (HW - 0.17), sill + 0.21, (noseZ + cabBack) / 2), cabBack - noseZ, 0.34, 0.42, V(s, 0, 0), V(0, -1, 0), "body")
			b:box("BedWall" .. n, V(0.4, railY - shoulder, tailZ - cabBack - 0.16), V(s * 3.4, (shoulder + railY) / 2, (cabBack + tailZ) / 2), "body")
			b:box("BedRail" .. n, V(0.56, 0.12, tailZ - cabBack + 0.18), V(s * 3.4, railY + 0.06, (cabBack + tailZ) / 2), "accent")
			b:box("BedCorner" .. n, V(0.46, shoulder - bedY, tailZ - rz - R - 0.18), V(s * 3.4, (bedY + shoulder) / 2, (rz + R + tailZ) / 2), "body")
			b:box("TubPad" .. n, V(1.1, 0.1, 2.8), V(s * 2.65, shoulder + 0.05, rz), "seat")
		end
		b:box("BonnetDeck", V(6.9, belt - shoulder, wsBase - noseZ - 0.3), V(0, (shoulder + belt) / 2, (noseZ + 0.3 + wsBase) / 2), "body")
		b:bevel("BonnetNose", V(0, (shoulder + belt) / 2, noseZ + 0.15), 6.9, 0.3, belt - shoulder, FRONT, UP, "body")
		for index, z in ipairs({ -5.9, -5.1, -4.3, -3.5, -2.7 }) do
			for _, s in ipairs({ -1, 1 }) do
				b:scute(string.format("Scute%s%d", s < 0 and "L" or "R", index), V(s * 0.8, belt + 0.11, z), 0.7, 0.46, 0.22, "accent")
			end
		end
		b:box("Tailgate", V(7.06, railY - bedY, 0.3), V(0, (bedY + railY) / 2, tailZ - 0.15), "body")
		b:box("TailgateCap", V(7.3, 0.12, 0.42), V(0, railY + 0.06, tailZ - 0.15), "accent")

		-- Eyes: headlamps in raised pods at the corners of the bonnet, like a croc's.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local eye = V(s * 2.35, belt + 0.38, -6.55)
			b:box("EyePod" .. n, V(1.5, 0.76, 1.3), eye, "body")
			b:bevel("EyeBrow" .. n, eye + V(0, 0.5, 0.2), 1.5, 0.9, 0.24, FRONT, UP, "accent")
			b:bevel("EyePodBack" .. n, eye + V(0, 0, 0.95), 1.5, 0.6, 0.76, BACK, UP, "body")
			b:cylZ("EyeIris" .. n, 0.3, 0.98, V(s * 2.35, eye.Y, -7.2 - 0.06 + 0.15), "amber")
			b:cylZ("EyeLamp" .. n, 0.3, 0.72, V(s * 2.35, eye.Y, -7.2 - 0.14 + 0.15), "lamp")
			b:box("EyePupil" .. n, V(0.16, 0.62, 0.3), V(s * 2.35, eye.Y, -7.2 - 0.22 + 0.15), "mesh")
		end

		-- The grin.
		local noseFace = V(0, 0, noseZ)
		b:layer("Mouth", Vector2.new(4.6, 1.45), noseFace + V(0, 3.05, 0), FRONT, 0.1, "mesh")
		b:layer("GumUpper", Vector2.new(4.8, 0.14), noseFace + V(0, 3.84, 0), FRONT, 0.16, "accent")
		b:layer("GumLower", Vector2.new(4.8, 0.14), noseFace + V(0, 2.26, 0), FRONT, 0.16, "accent")
		for index = 0, 7 do
			b:tooth("ToothUpper" .. index, -1.89 + index * 0.54, 3.77, noseZ, 0.5, 0.46, -1, 0.2, "teeth")
		end
		for index = 0, 6 do
			b:tooth("ToothLower" .. index, -1.62 + index * 0.54, 2.33, noseZ, 0.5, 0.52, 1, 0.2, "teeth")
		end
		for _, s in ipairs({ -1, 1 }) do
			b:layer(s < 0 and "IndicatorL" or "IndicatorR", Vector2.new(0.4, 0.24), noseFace + V(s * 3.1, 3.85, 0), FRONT, 0.12, "amber")
		end

		-- Bumper, winch, tow hooks and a bull bar with two spot lamps.
		b:box("FrontBumper", V(6.8, 1.0, 0.8), V(0, 1.95, -7.75), "trim")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("FrontBumperCorner" .. n, V(0.3, 1.0, 0.4), V(s * 3.55, 1.95, -7.55), "trim")
			b:bevel("FrontBumperBevel" .. n, V(s * 3.55, 1.95, -7.95), 1.0, 0.4, 0.3, FRONT, V(s, 0, 0), "trim")
			b:beam("TowHook" .. n, V(s * 2.6, 1.72, -8.1), V(s * 2.6, 1.72, -8.55), 0.16, 0.3, "tail")
			-- #61 ("random poles sticking out"): the bull bar used to be three separate thin members
			-- per side (an upright, diameter 0.26, plus a two-segment wing brace, diameter 0.22, bent
			-- at a mid-point) -- measured worst-first in tools/vehicle_gallery.lua's rodAudit and
			-- confirmed in the render (brain-rot-royale-playtest/vehicle_0d_0921_rerun2/
			-- 002_polesfront_CrocodiloRanger.png): thin diagonal wire crossing in front of the
			-- headlamps, nothing like a grille guard. Replaced with ONE continuous, thicker member
			-- per side straight from the bumper corner to the top rail (no bend), so it reads as a
			-- frame, not scattered rods.
			-- #61 / #116 again: that one member still ran corner-to-top on a 44 degree diagonal, from the
			-- bumper's outer corner in to the top rail, and at 0.42 across a thick rod leaning across the
			-- grin is exactly what "bat parts sideways" describes -- it was the thickening that turned a
			-- thin pole into a bat. A grille guard's uprights stand straight: each now rises plumb from
			-- the bumper to the end of the top rail (the ball there closes the corner). It starts 0.25
			-- inside the bumper so its end disc is buried rather than lying in the bumper's top face.
			-- tools/vehicle_models_axis_check.py holds every rod on the car to a world axis.
			b:tube("BullFrame" .. n, V(s * 1.9, 2.2, -8.05), V(s * 1.9, 4.15, -8.05), 0.42, "trim")
			b:cylZ("SpotHousing" .. n, 0.3, 0.8, V(s * 1.0, 4.55, -8.0), "mesh")
			b:cylZ("Spot" .. n, 0.3, 0.6, V(s * 1.0, 4.55, -8.08), "lamp")
			b:tube("SpotMount" .. n, V(s * 1.0, 4.15, -8.05), V(s * 1.0, 4.4, -8.0), 0.12, "trim")
		end
		b:tube("BullTop", V(-1.9, 4.15, -8.05), V(1.9, 4.15, -8.05), 0.42, "trim")
		b:ball("BullTopL", 0.42, V(-1.9, 4.15, -8.05), "trim")
		b:ball("BullTopR", 0.42, V(1.9, 4.15, -8.05), "trim")
		b:cyl("Winch", 1.6, 0.5, CF(0, 1.95, -8.36), "engine")
		b:box("WinchHook", V(0.16, 0.3, 0.12), V(0, 1.68, -8.66), "chrome")

		-- Cab: screen, windows, pillars, the back wall with its little window, the roof and its lights.
		b:wedge("Windscreen", V(6.2, roofY - belt, wsTop - wsBase), V(0, (belt + roofY) / 2, (wsBase + wsTop) / 2), "glass")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local tilt = A(0, 0, s * 4)
			b:box("SideGlass" .. n, V(0.08, roofY - belt, cabBack - 0.3 - wsTop), CF(s * 3.12, (belt + roofY) / 2, (wsTop + cabBack - 0.3) / 2) * tilt, "glass")
			b:beam("PillarA" .. n, V(s * 3.25, belt, wsBase), V(s * 3.08, roofY + 0.05, wsTop + 0.05), 0.34, 0.3, "accent")
			b:box("PillarC" .. n, V(0.42, roofY - belt + 0.18, 0.44), CF(s * 3.18, (belt + roofY) / 2, cabBack - 0.12) * tilt, "body")
			b:box("RearWallSide" .. n, V(1.8, roofY - belt - 1.25, 0.3), V(s * 2.3, belt + 0.8 + (roofY - belt - 1.25) / 2, cabBack + 0.02), "body")
		end
		b:box("RearWallLow", V(6.4, 0.8, 0.3), V(0, belt + 0.4, cabBack + 0.02), "body")
		b:box("RearWallHigh", V(6.4, 0.45, 0.3), V(0, roofY - 0.225, cabBack + 0.02), "body")
		b:box("RearWindow", V(2.8, roofY - belt - 1.25, 0.12), V(0, belt + 0.8 + (roofY - belt - 1.25) / 2, cabBack + 0.02), "glass")
		b:box("RoofPanel", V(5.9, 0.25, cabBack + 0.15 - (wsTop + 0.25)), V(0, roofY + 0.125, (wsTop + 0.25 + cabBack + 0.15) / 2), "accent")
		b:bevel("RoofBrow", V(0, roofY + 0.125, wsTop + 0.1), 5.9, 0.3, 0.25, FRONT, UP, "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:bevel(s < 0 and "RoofEdgeL" or "RoofEdgeR", V(s * 3.05, roofY + 0.125, (wsTop - 0.05 + cabBack + 0.15) / 2), cabBack + 0.2 - wsTop, 0.2, 0.25, V(s, 0, 0), UP, "accent")
		end
		-- The light bar lies low on the roof's front edge. It stood on 0.34-stud feet (top at 7.83), right
		-- across the line the bed's rocket launcher fires forward along (Mounts below): its lower tubes
		-- leave at 7.45 and pass the light bar's line 2.95 studs on, so a bar that tall had every rocket
		-- fired over the cab come out through it. Down here (top 7.35) the launcher's front-arc floor of 4
		-- degrees (VehicleWeaponData, RangerRocketPod.frontGuard) carries the lowest rocket clear of it.
		b:box("LightBar", V(4.6, 0.2, 0.42), V(0, roofY + 0.25 + 0.1, 0.1), "trim")
		for index = 1, 6 do
			b:layer("LightBarLamp" .. index, Vector2.new(0.56, 0.08), V(-1.9 + (index - 1) * 0.76, roofY + 0.35, -0.11), FRONT, 0.08, "lamp")
		end
		b:pipe("Snorkel", { V(3.78, 4.2, -2.4), V(3.78, 5.0, -1.9), V(3.42, 6.85, -0.55), V(3.4, 7.3, -0.5) }, 0.4, "trim")
		b:box("SnorkelHead", V(0.55, 0.5, 0.8), V(3.4, 7.45, -0.65), "trim")
		b:bevel("SnorkelMouth", V(3.4, 7.45, -1.2), 0.55, 0.3, 0.5, FRONT, V(0, -1, 0), "trim")

		-- Bed: the roll bar with its braces. The spare wheel that lay flat in the middle of the bed has gone
		-- under the tail (below), because the bed is the gunner's now: a pedestal rocket launcher bolted to
		-- its floor, with the gunner walking round it (Mounts, "pedestal"). Its floor is clear from the cab to
		-- the tailgate for exactly that. An unarmed Ranger (a parked one) gets a load of crates instead.
		b.bedFloor = { y = bedY, z0 = cabBack, z1 = tailZ - 0.3 }
		-- #61: the bed roll bar's top crossbar (RollBar3, the longest run at 5.3 studs) measured the
		-- single worst ratio on the Ranger, 17.7 at the original 0.3 diameter -- thickened here along
		-- with the rest of the pipe (one continuous tube reads as one gauge throughout; thickening
		-- only the middle segment would look like a lump) and the corner braces that carry it down to
		-- the bed rail.
		b:pipe("RollBar", { V(-3.0, railY, 2.6), V(-3.0, 6.3, 2.6), V(-2.5, 6.8, 2.6), V(2.5, 6.8, 2.6), V(3.0, 6.3, 2.6), V(3.0, railY, 2.6) }, 0.42, "trim")
		for _, s in ipairs({ -1, 1 }) do
			b:tube(s < 0 and "RollBraceL" or "RollBraceR", V(s * 3.0, 6.3, 2.6), V(s * 3.35, railY, 4.4), 0.32, "trim")
		end

		-- Tail.
		local tailFace = V(0, 0, tailZ)
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:lamp("Tail" .. n, tailFace + V(s * 3.2, 3.95, 0), BACK, Vector2.new(0.5, 1.3), "tail", "redlens")
			b:box("MudFlap" .. n, V(1.5, 1.25, 0.1), V(s * track, 1.35, rz + r + 0.45), "rubber")
		end
		b:plate("TailgateName", V(4.2, 0.5, 0.3), V(0, 4.25, tailZ + 0.12 - 0.15), "CROCODILO", Enum.NormalId.Back, "body", "stripe")
		b:plate("PlateRear", V(1.7, 0.42, 0.3), V(0, 3.45, tailZ + 0.12 - 0.15), "CROC 88", Enum.NormalId.Back)
		b:layer("TailgateHandle", Vector2.new(1.0, 0.14), tailFace + V(0, 3.85, 0), BACK, 0.1, "chrome")
		b:box("RearBumper", V(7.0, 0.8, 0.8), V(0, 2.05, tailZ + 0.3), "trim")
		b:box("BumperStep", V(2.2, 0.1, 0.5), V(0, 2.5, tailZ + 0.45), "chrome")
		b:tube("HitchStem", V(0, 2.1, tailZ + 0.7), V(0, 2.1, tailZ + 1.15), 0.2, "trim")
		b:ball("HitchBall", 0.42, V(0, 2.42, tailZ + 1.15), "chrome")
		-- The spare wheel, slung flat under the tail on a cradle bolted to the underside of the tail block
		-- (sill 1.9), the way a pickup carries it, between and behind the rear wheels; its face (the rim,
		-- 0.06 proud of the tyre) is 1.22 off the ground.
		b:box("SpareCradle", V(1.7, 0.12, 0.3), V(0, sill - 0.06, 6.25), "trim")
		b:cyl("SpareTyre", 0.5, 2.3, CF(0, sill - 0.12 - 0.25, 6.25) * A(0, 0, 90), "tyre")
		b:cyl("SpareRim", 0.3, 1.5, CF(0, sill - 0.12 - 0.5 + 0.15 - 0.06, 6.25) * A(0, 0, 90), "rim")

		-- Sides.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local side = V(s, 0, 0)
			b:layer("Belly" .. n, Vector2.new(doorBack - doorFront - 0.2, 0.8), V(s * HW, 2.55, (doorFront + doorBack) / 2), side, 0.06, "stripe")
			-- (seams, handle and badge each stand off by their own amount below)
			b:plate("DoorBadge" .. n, V(0.3, 0.5, 2.6), V(s * (HW + 0.12 - 0.15), 3.55, -0.3), "RANGER",
				s < 0 and Enum.NormalId.Left or Enum.NormalId.Right, "body", "stripe")
			b:layer("Handle" .. n, Vector2.new(0.6, 0.16), V(s * HW, 3.92, 1.45), side, 0.14, "chrome")
			b:layer("SeamFront" .. n, Vector2.new(0.05, 1.94), V(s * HW, 3.0, doorFront + 0.1), side, 0.02, "mesh")
			b:layer("SeamBack" .. n, Vector2.new(0.05, 1.94), V(s * HW, 3.0, cabBack - 0.1), side, 0.02, "mesh")
			b:box("SideStep" .. n, V(0.6, 0.14, 4.6), V(s * 3.95, 1.6, -0.15), "trim")
			for index, z in ipairs({ -1.8, 1.5 }) do
				b:box(string.format("StepBracket%s%d", n, index), V(0.5, 0.3, 0.2), V(s * 3.65, 1.8, z), "trim")
			end
			b:layer("Repeater" .. n, Vector2.new(0.3, 0.12), V(s * HW, 3.95, -2.55), side, 0.1, "amber")
			-- #61: the last of the three thin-rod kinds the rod audit found on the Ranger (the other
			-- two were the bull bar and the roll bar, both fixed above) -- a 0.12x0.14 arm read as a
			-- ball-on-a-stick in the render. Thickened; still slender relative to the mirror head,
			-- which is correct for a mirror arm.
			b:beam("MirrorArm" .. n, V(s * 3.35, 5.0, -1.3), V(s * 3.9, 5.15, -1.2), 0.20, 0.18, "trim")
			b:box("Mirror" .. n, V(0.3, 0.95, 0.62), V(s * 4.1, 5.2, -1.15), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.18, 0.79), V(s * 4.1, 5.2, -0.84), BACK, 0.08, "chrome")
		end
		b:layer("FuelCap", Vector2.new(0.5, 0.5), V(HW, 4.42, 2.45), V(1, 0, 0), 0.08, "trim")
		b:tube("SideExhaust", V(3.15, 1.72, 2.3), V(3.92, 1.72, 2.45), 0.34, "chrome")
		b:tube("SideExhaustBore", V(3.72, 1.72, 2.41), V(3.9, 1.72, 2.44), 0.22, "mesh")

		-- Cabin.
		b:box("Dash", V(6.2, 0.7, 1.0), V(0, 4.0, -1.4), "dash")
		b:box("Binnacle", V(1.4, 0.34, 0.55), V(-1.5, 4.45, -1.15), "dash")
		for index, x in ipairs({ -1.8, -1.2 }) do
			b:cylZ("Gauge" .. index, 0.3, 0.36, V(x, 4.45, -0.875 + 0.1 - 0.15), "gauge")
		end
		b:box("Console", V(0.8, 1.0, 2.0), V(0, 2.8, -0.1), "interior")
		b:tube("GearStick", V(0.05, 3.3, 0.1), V(0.05, 3.9, 0.25), 0.1, "chrome")
		b:ball("GearKnob", 0.26, V(0.05, 3.95, 0.26), "dash")
		b:tube("TransferStick", V(-0.25, 3.3, 0.45), V(-0.25, 3.75, 0.55), 0.08, "chrome")
		-- Its own knob, as the gear stick has: without one it was a bare chrome rod ending in the air.
		b:ball("TransferKnob", 0.18, V(-0.25, 3.78, 0.56), "dash")
		b:tube("Column", V(-1.5, 3.9, -1.3), V(-1.5, 4.3, -0.62), 0.2, "dash")
		b:steeringWheel("SteeringWheel", V(-1.5, 4.36, -0.5), V(0, 0.5, 0.87).Unit, 0.55)
		b:bucketSeat("SeatDriver", V(-1.5, 2.6, 0.55), 2.0, 1.8, 2.3, 10)
		b:bucketSeat("SeatPassenger", V(1.5, 2.6, 0.55), 2.0, 1.8, 2.3, 10)

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "offroad", spokes = 6, rimScale = 0.58, tread = 18 })
		end

		return {
			seats = {
				driver = CF(-1.5, 2.66, 0.55),
				-- The two in the bed sit up on its rails facing out, legs over the side, the way people ride
				-- on a technical: sat on the wheel tubs facing in (as they were) their knees reached 1.2 into
				-- the bed, right through where the gunner stands when the launcher is turned to the side.
				passengers = { CF(1.5, 2.66, 0.55), CF(3.3, railY + 0.14, 5.0) * A(0, -90, 0), CF(-3.3, railY + 0.14, 5.0) * A(0, 90, 0) },
			},
			exits = { CF(-6.0, 0, 0.3), CF(6.0, 0, 0.3), CF(-6.0, 0, 4.6), CF(6.0, 0, 4.6), CF(0, 0, -10.8), CF(0, 0, 10.4), CF(0, 7.5, 0.85) },
			pose = { kind = "car" },
		}
	end,
}

-- Tralala GT: a long, low, rear-drive coupe with a shark's fin on the roof, gills behind the front
-- wheels and a grin full of little teeth. The fastest thing on four wheels.
VehicleModels.Models.TralalaGT = {
	kind = "car",
	displayName = "Tralala GT",
	weight = 18,
	schemes = {
		{ name = "Great White", body = Color3.fromRGB(122, 146, 166), accent = Color3.fromRGB(236, 238, 242), stripe = Color3.fromRGB(236, 238, 242), seat = Color3.fromRGB(176, 40, 46), rim = Color3.fromRGB(34, 36, 40), sneaker = true },
		{ name = "Hammerhead Orange", body = Color3.fromRGB(242, 108, 32), accent = Color3.fromRGB(26, 26, 30), stripe = Color3.fromRGB(26, 26, 30), seat = Color3.fromRGB(28, 28, 32), rim = Color3.fromRGB(204, 208, 214) },
		{ name = "Reef Teal", body = Color3.fromRGB(30, 168, 170), accent = Color3.fromRGB(250, 218, 66), stripe = Color3.fromRGB(250, 218, 66), seat = Color3.fromRGB(38, 40, 46), rim = Color3.fromRGB(250, 218, 66) },
		{ name = "Midnight Fin", body = Color3.fromRGB(26, 30, 46), accent = Color3.fromRGB(26, 30, 46), stripe = Color3.fromRGB(226, 40, 90), seat = Color3.fromRGB(226, 40, 90), rim = Color3.fromRGB(226, 40, 90) },
		{ name = "Sneaker Drip", body = Color3.fromRGB(244, 244, 246), accent = Color3.fromRGB(32, 108, 232), stripe = Color3.fromRGB(32, 108, 232), seat = Color3.fromRGB(32, 108, 232), rim = Color3.fromRGB(244, 244, 246), sneaker = true },
	},
	build = function(b)
		local HW = 3.5
		-- Oliver: "make the car wheel models more flat" -- this was the fattest wheel of the four
		-- (ratio 0.46), so the biggest cut: tw 1.25 -> 0.78 (ratio 0.29). r UNCHANGED; see Rotster.
		local r, tw, track = 1.35, 0.78, 2.93
		local fz, rz = -4.45, 4.55
		local R = 1.56
		local sill, shoulder, belt, hip, roofY = 0.72, 2.65, 2.9, 3.2, 4.85
		local noseZ, tailZ = -7.3, 7.25
		local noseTop = 1.97
		local wsBase, wsTop = -3.1, -0.1
		local roofBack, fastFoot = 2.8, 6.2
		local inner = HW - 1.35
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.7, 1.8, 14.2), V(0, 1.95, 0), 1.3)
		b:hull("Hull_Roof", V(4.8, 0.3, 2.2), V(0, roofY + 0.07, (wsTop + roofBack) / 2), 0.1)

		-- Body: a low nose, a bonnet in a valley between the front wings, hips over the rear wheels.
		b:box("NoseBlock", V(6.3, noseTop - sill, fz - R - noseZ), V(0, (sill + noseTop) / 2, (noseZ + fz - R) / 2), "body")
		b:roundCorners("NoseCorner", 3.5, 0.35, noseZ, 1, (sill + noseTop) / 2, noseTop - sill, "body")
		b:box("EngineBay", V(3.7, noseTop - 0.9, wsBase - (fz - R)), V(0, (0.9 + noseTop) / 2, (fz - R + wsBase) / 2), "mesh")
		b:wedge("Bonnet", V(2 * inner, belt - noseTop, wsBase - noseZ), V(0, (noseTop + belt) / 2, (noseZ + wsBase) / 2), "body")
		b:box("CabinPan", V(2 * HW - 0.8, 0.2, roofBack + 0.5 - wsBase), V(0, 0.8, (wsBase + roofBack + 0.5) / 2), "interior")
		b:box("RearShelf", V(2 * inner, hip - belt, fastFoot - roofBack), V(0, (belt + hip) / 2, (roofBack + fastFoot) / 2), "interior")
		b:box("RearDeck", V(2 * inner, hip - belt, tailZ - fastFoot), V(0, (belt + hip) / 2, (fastFoot + tailZ) / 2), "body")
		b:box("TailBlock", V(6.3, hip - sill, tailZ - rz - R), V(0, (sill + hip) / 2, (rz + R + tailZ) / 2), "body")
		b:roundCorners("TailCorner", 3.5, 0.35, tailZ, -1, (sill + hip) / 2, hip - sill, "body")
		b:wedge("Ducktail", V(6.4, 0.26, 0.8), V(0, hip + 0.13, tailZ - 0.4), "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local mid = s * (inner + HW) / 2
			b:box("Door" .. n, V(0.5, shoulder - sill, doorBack - doorFront), V(s * (HW - 0.25), (sill + shoulder) / 2, (doorFront + doorBack) / 2), "body")
			-- The wings stop short of the crest, which is a cap with its outer edge bevelled off.
			local crest = 0.18
			b:archPanel("ArchPanelF" .. n, r, fz, R, hip - crest, s, inner, HW, 10, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, hip - crest, s, inner, HW, 10, "body")
			for _, e in ipairs({ { "WingTop", fz }, { "HipTop", rz } }) do
				b:box(e[1] .. n, V(1.35 - crest, crest, 2 * R), V(s * (inner + HW - crest) / 2, hip - crest / 2, e[2]), "body")
				b:bevel(e[1] .. "Bevel" .. n, V(s * (HW - crest / 2), hip - crest / 2, e[2]), 2 * R, crest, crest, V(s, 0, 0), UP, "body")
			end
			b:box("WellF" .. n, V(0.1, 1.9, 2.9), V(s * 1.86, 1.7, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 1.9, 2.9), V(s * 1.86, 1.7, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * 3.56, 0.24, 0.14, -100, 100, 12, "body")
			b:archLip("LipR" .. n, r, rz, R, s * 3.56, 0.24, 0.14, -100, 100, 12, "body")
			b:wedge("WingNose" .. n, V(1.35, hip - noseTop, fz - R - noseZ), V(mid, (noseTop + hip) / 2, (noseZ + fz - R) / 2), "body")
			b:wedge("WingTail" .. n, V(1.35, hip - belt, 0.8), CF(mid, (belt + hip) / 2, doorFront + 0.4) * A(0, 180, 0), "body")
			b:wedge("HipFront" .. n, V(1.35, hip - belt, doorBack - roofBack), V(mid, (belt + hip) / 2, (roofBack + doorBack) / 2), "body")
			b:box("DoorTop" .. n, V(0.3, belt - shoulder, doorBack - doorFront), V(s * (HW - 0.15), (shoulder + belt) / 2, (doorFront + doorBack) / 2), "body")
			b:bevel("Shoulder" .. n, V(s * (HW - 0.25), (shoulder + belt) / 2, (doorFront + doorBack) / 2), doorBack - doorFront, 0.5, belt - shoulder, V(s, 0, 0), UP, "body")
			b:bevel("Rocker" .. n, V(s * (HW - 0.17), sill + 0.17, (doorFront + doorBack) / 2), doorBack - doorFront, 0.34, 0.34, V(s, 0, 0), V(0, -1, 0), "body")
			b:box("SailLower" .. n, V(0.7, hip - belt + 0.18, doorBack - roofBack - 0.16), V(s * 2.5, (belt + hip) / 2, (roofBack + doorBack) / 2), "accent")
			b:wedge("Sail" .. n, V(0.7, roofY - hip, fastFoot - roofBack), CF(s * 2.5, (hip + roofY) / 2, (roofBack + fastFoot) / 2) * A(0, 180, 0), "accent")
			-- Gills.
			for index = 0, 2 do
				b:box(string.format("Gill%s%d", n, index + 1), V(0.3, 0.72, 0.09), CF(s * (HW + 0.08 - 0.15), 1.72, doorFront + 0.25 + index * 0.26) * A(-18, 0, 0), "mesh")
			end
		end

		-- Glass, roof and the fin.
		b:wedge("Windscreen", V(5.44, roofY - belt, wsTop - wsBase), V(0, (belt + roofY) / 2, (wsBase + wsTop) / 2), "glass")
		b:wedge("FastbackGlass", V(2 * inner, roofY - hip, fastFoot - roofBack), CF(0, (hip + roofY) / 2, (roofBack + fastFoot) / 2) * A(0, 180, 0), "glass")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("SideGlass" .. n, V(0.08, roofY - belt, roofBack - wsTop), CF(s * 2.78, (belt + roofY) / 2, (wsTop + roofBack) / 2) * A(0, 0, s * 9), "glass")
			b:beam("PillarA" .. n, V(s * 2.92, belt, wsBase), V(s * 2.5, roofY + 0.05, wsTop + 0.05), 0.34, 0.28, "accent")
			b:box("WindowSeal" .. n, V(0.1, 0.08, roofBack - wsBase), V(s * 3.0, belt + 0.08, (wsBase + roofBack) / 2), "trim")
		end
		b:box("RoofPanel", V(4.9, 0.22, roofBack - wsTop - 0.25), V(0, roofY + 0.11, (wsTop + 0.25 + roofBack) / 2), "accent")
		b:bevel("RoofBrow", V(0, roofY + 0.11, wsTop + 0.125), 4.9, 0.25, 0.22, FRONT, UP, "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:bevel(s < 0 and "RoofEdgeL" or "RoofEdgeR", V(s * 2.55, roofY + 0.11, (wsTop + roofBack) / 2), roofBack - wsTop, 0.2, 0.22, V(s, 0, 0), UP, "accent")
		end
		b:wedge("Fin", V(0.24, 1.0, 1.6), V(0, roofY + 0.22 + 0.5, 1.5), "accent")
		b:wedge("FinTip", V(0.16, 0.26, 0.46), CF(0, roofY + 0.22 + 0.87, 2.53) * A(0, 180, 0), "accent")

		-- The grin, lamps and vents.
		local noseFace = V(0, 0, noseZ)
		b:layer("Mouth", Vector2.new(4.4, 0.62), noseFace + V(0, 1.22, 0), FRONT, 0.1, "mesh")
		for index = 0, 8 do
			b:tooth("ToothLower" .. index, -1.84 + index * 0.46, 0.93, noseZ, 0.34, 0.24, 1, 0.18, "teeth")
		end
		for index = 0, 9 do
			b:tooth("ToothUpper" .. index, -2.07 + index * 0.46, 1.51, noseZ, 0.34, 0.22, -1, 0.18, "teeth")
		end
		b:box("Splitter", V(6.6, 0.1, 0.6), V(0, 0.68, noseZ + 0.1), "mesh")
		b:cylZ("Badge", 0.3, 0.3, V(0, 1.72, noseZ - 0.14 + 0.15), "stripe")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:layer("HeadlampHousing" .. n, Vector2.new(1.74, 0.6), noseFace + V(s * 2.75, 1.74, 0), FRONT, 0.1, "dash")
			b:layer("Headlamp" .. n, Vector2.new(1.1, 0.14), noseFace + V(s * 2.85, 1.8, 0), FRONT, 0.18, "lamp")
			b:layer("Drl" .. n, Vector2.new(1.3, 0.05), noseFace + V(s * 2.75, 1.64, 0), FRONT, 0.18, "drl")
			b:layer("HeadlampLens" .. n, Vector2.new(1.42, 0.3), noseFace + V(s * 2.75, 1.74, 0), FRONT, 0.12, "lens")
			b:layer("BrakeVent" .. n, Vector2.new(0.7, 0.3), noseFace + V(s * 2.85, 1.05, 0), FRONT, 0.1, "mesh")
		end

		-- Tail: a light bar across the back, a diffuser with four pipes, the wing.
		local tailFace = V(0, 0, tailZ)
		b:layer("TailHousing", Vector2.new(6.3, 0.42), tailFace + V(0, 2.62, 0), BACK, 0.1, "dash")
		b:layer("TailStrip", Vector2.new(5.2, 0.1), tailFace + V(0, 2.62, 0), BACK, 0.18, "tail")
		for _, s in ipairs({ -1, 1 }) do
			b:cylZ(s < 0 and "TailRoundL" or "TailRoundR", 0.3, 0.5, V(s * 2.8, 2.62, tailZ + 0.22 - 0.15), "tail")
		end
		b:layer("TailLens", Vector2.new(6.1, 0.34), tailFace + V(0, 2.62, 0), BACK, 0.12, "redlens")
		b:plate("PlateRear", V(1.7, 0.42, 0.3), V(0, 1.95, tailZ + 0.12 - 0.15), "TRALALA", Enum.NormalId.Back)
		b:layer("Diffuser", Vector2.new(4.2, 0.5), tailFace + V(0, 0.98, 0), BACK, 0.1, "mesh")
		for index, x in ipairs({ -1.9, -1.1, 0, 1.1, 1.9 }) do
			b:layer("DiffuserFin" .. index, Vector2.new(0.06, 0.36), tailFace + V(x, 0.98, 0), BACK, 0.24, "trim")
		end
		for index, x in ipairs({ -1.35, -0.85, 0.85, 1.35 }) do
			b:cylZ("Exhaust" .. index, 0.5, 0.34, V(x, 1.0, tailZ + 0.3 - 0.25), "chrome")
			b:cylZ("ExhaustBore" .. index, 0.36, 0.24, V(x, 1.0, tailZ + 0.3 - 0.25), "mesh")
		end
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:beam("WingPost" .. n, V(s * 1.9, hip, 6.55), V(s * 1.9, hip + 0.75, 6.8), 0.14, 0.34, "trim")
			b:box("WingPlate" .. n, V(0.1, 0.55, 1.2), V(s * 3.0, hip + 0.8, 6.85), "accent")
		end
		b:box("Wing", V(6.0, 0.14, 1.05), CF(0, hip + 0.85, 6.85) * A(-6, 0, 0), "accent")

		-- Sides and stripes.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local side = V(s, 0, 0)
			b:layer("Skirt" .. n, Vector2.new(doorBack - doorFront - 0.18, 0.42), V(s * HW, 0.82, (doorFront + doorBack) / 2), side, 0.16, "trim")
			b:layer("Handle" .. n, Vector2.new(0.5, 0.08), V(s * HW, 2.28, 1.6), side, 0.06, "chrome")
			b:layer("Crease" .. n, Vector2.new(4.7, 0.06), V(s * HW, 1.95, 0.45), side, 0.06, "stripe")
			b:beam("MirrorArm" .. n, V(s * 3.2, 2.85, -2.3), V(s * 3.55, 2.95, -2.2), 0.1, 0.08, "trim")
			b:box("Mirror" .. n, V(0.62, 0.42, 0.3), V(s * 3.78, 3.0, -2.2), "accent")
			b:bevel("MirrorNose" .. n, V(s * 3.78, 3.0, -2.45), 0.5, 0.2, 0.3, FRONT, V(0, -1, 0), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.42, 0.22), V(s * 3.78, 3.0, -2.05), BACK, 0.08, "chrome")
			b:beam("StripeBonnet" .. n, V(s * 0.5, noseTop, noseZ + 0.05), V(s * 0.5, belt, wsBase), 0.5, 0.12, "stripe")
			b:layer("StripeRoof" .. n, Vector2.new(0.5, roofBack - wsTop - 0.2), V(s * 0.5, roofY + 0.22, (wsTop + roofBack) / 2 + 0.1), UP, 0.06, "stripe")
			b:layer("StripeDeck" .. n, Vector2.new(0.5, 0.2), V(s * 0.5, hip, 6.32), UP, 0.06, "stripe")
		end

		-- Cabin.
		b:box("Dash", V(5.2, 0.5, 1.2), V(0, 2.5, -2.4), "dash")
		b:box("Display", V(1.6, 0.5, 0.12), CF(0, 2.9, -1.95) * A(-20, 0, 0), "mesh")
		b:box("Console", V(0.8, 0.6, 3.0), V(0, 1.2, -0.3), "interior")
		b:tube("Column", V(-1.25, 2.45, -2.1), V(-1.25, 2.55, -1.2), 0.16, "dash")
		b:steeringWheel("SteeringWheel", V(-1.25, 2.6, -1.1), V(0, 0.35, 0.94).Unit, 0.42)
		b:bucketSeat("SeatDriver", V(-1.25, 0.8, 0.9), 1.7, 1.7, 2.1, 20)
		b:bucketSeat("SeatPassenger", V(1.25, 0.8, 0.9), 1.7, 1.7, 2.1, 20)

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "mesh", spokes = 5, rimScale = 0.72, sneaker = b.scheme.sneaker })
		end

		return {
			seats = {
				driver = CF(-1.25, 0.86, 0.9),
				passengers = { CF(1.25, 0.86, 0.9) },
			},
			exits = { CF(-5.4, 0, 0.6), CF(5.4, 0, 0.6), CF(-5.4, 0, -2.4), CF(5.4, 0, -2.4), CF(0, 0, -10.2), CF(0, 0, 10.2), CF(0, 5.8, 1.2) },
			pose = { kind = "car" },
		}
	end,
}

-- Sahur Van: a tall, square delivery van with wooden side panels, and a drum and a giant bat strapped
-- to the roof. Slow and steady, with room for four.
VehicleModels.Models.SahurVan = {
	kind = "car",
	displayName = "Sahur Van",
	weight = 16,
	schemes = {
		{ name = "Tung Tung", body = Color3.fromRGB(236, 226, 200), accent = Color3.fromRGB(122, 80, 46), stripe = Color3.fromRGB(196, 60, 40), seat = Color3.fromRGB(120, 70, 40), rim = Color3.fromRGB(236, 226, 200), wood = Color3.fromRGB(150, 102, 58) },
		{ name = "Midnight Sahur", body = Color3.fromRGB(40, 52, 90), accent = Color3.fromRGB(240, 196, 80), stripe = Color3.fromRGB(240, 196, 80), seat = Color3.fromRGB(30, 30, 36), rim = Color3.fromRGB(240, 196, 80), wood = Color3.fromRGB(110, 74, 44) },
		{ name = "Sunrise", body = Color3.fromRGB(246, 150, 60), accent = Color3.fromRGB(250, 240, 214), stripe = Color3.fromRGB(200, 60, 70), seat = Color3.fromRGB(60, 44, 34), rim = Color3.fromRGB(250, 240, 214), wood = Color3.fromRGB(170, 120, 70) },
		{ name = "Forest Log", body = Color3.fromRGB(86, 110, 66), accent = Color3.fromRGB(60, 44, 30), stripe = Color3.fromRGB(236, 220, 170), seat = Color3.fromRGB(60, 44, 30), rim = Color3.fromRGB(236, 220, 170), wood = Color3.fromRGB(130, 90, 52) },
		{ name = "Strawberry Milk", body = Color3.fromRGB(246, 200, 214), accent = Color3.fromRGB(250, 250, 246), stripe = Color3.fromRGB(120, 200, 220), seat = Color3.fromRGB(250, 250, 246), rim = Color3.fromRGB(250, 250, 246), wood = Color3.fromRGB(196, 150, 104) },
	},
	build = function(b)
		local HW = 3.5
		-- Oliver: "make the car wheel models more flat" -- tw narrowed 1.1 -> 0.85 (ratio 0.38 ->
		-- 0.29). r UNCHANGED; see Rotster's comment for why.
		local r, tw, track = 1.45, 0.85, 3.0
		local fz, rz = -4.3, 4.4
		local R = 1.68
		local sill, belt, roofY = 1.3, 4.3, 7.5
		local frontZ, tailZ = -6.6, 7.4
		local screenBase, screenTop = -6.25, -5.85
		local header = roofY - 0.3
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.8, 3.2, 13.8), V(0, 3.1, 0.4), 1.1)
		b:hull("Hull_Roof", V(6.8, 0.3, 13.4), V(0, roofY + 0.15, 0.55), 0.1)
		for _, s in ipairs({ -1, 1 }) do
			b:hull(s < 0 and "Hull_PanelL" or "Hull_PanelR", V(0.3, roofY - belt, 6.0), V(s * 3.35, (belt + roofY) / 2, -0.25), 0.1)
		end

		-- Lower body.
		b:box("FrontBlock", V(7.0, belt - sill, fz - R - frontZ), V(0, (sill + belt) / 2, (frontZ + fz - R) / 2), "body")
		b:box("TailBlock", V(6.3, belt - sill, tailZ - rz - R), V(0, (sill + belt) / 2, (rz + R + tailZ) / 2), "body")
		b:roundCorners("TailCorner", 3.5, 0.35, tailZ, -1, (sill + belt) / 2, belt - sill, "body")
		b:box("CabFloor", V(3.8, 0.2, doorFront - (fz - R) + 1.6), V(0, 2.9, (fz - R + doorFront + 1.6) / 2), "interior")
		b:box("CargoFloor", V(3.66, 0.2, tailZ - doorFront - 1.6), V(0, 2.5, (doorFront + 1.6 + tailZ) / 2), "interior")
		b:box("CabStep", V(3.52, 0.6, 0.2), V(0, 2.7, doorFront + 1.6), "interior")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Door" .. n, V(0.4, belt - sill, doorBack - doorFront), V(s * (HW - 0.2), (sill + belt) / 2, (doorFront + doorBack) / 2), "body")
			b:archPanel("ArchPanelF" .. n, r, fz, R, belt, s, HW - 1.3, HW, 12, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, belt, s, HW - 1.3, HW, 12, "body")
			b:box("WellF" .. n, V(0.1, 2.2, 3.2), V(s * 1.96, 2.2, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 2.2, 3.2), V(s * 1.96, 2.2, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * 3.56, 0.24, 0.16, -95, 95, 12, "accent")
			b:archLip("LipR" .. n, r, rz, R, s * 3.56, 0.24, 0.16, -95, 95, 12, "accent")
		end

		-- Upper body: split windscreen, cab windows, solid panels with wooden inserts, rear windows.
		b:wedge("Windscreen", V(6.2, header - belt, screenTop - screenBase), V(0, (belt + header) / 2, (screenBase + screenTop) / 2), "glass")
		b:beam("ScreenDivider", V(0, belt, screenBase), V(0, header, screenTop), 0.2, 0.2, "accent")
		b:box("Header", V(7.0, roofY - header, screenTop - frontZ), V(0, (header + roofY) / 2, (frontZ + screenTop) / 2), "body")
		b:plate("HeaderSign", V(3.6, 0.24, 0.3), V(0, (header + roofY) / 2 - 0.08, frontZ - 0.1 + 0.15), "SAHUR", Enum.NormalId.Front, "accent", "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local x = s * 3.35
			b:box("CornerFront" .. n, V(0.3, header - belt, 0.5), V(x, (belt + header) / 2, -6.05), "accent")
			b:box("CabSill" .. n, V(0.26, 0.15, 2.3), V(x, belt + 0.075, -4.65), "body")
			b:box("CabHead" .. n, V(0.34, roofY - 6.75, 2.3), V(x, (6.75 + roofY) / 2, -4.65), "body")
			b:box("CabGlass" .. n, V(0.08, 6.75 - belt - 0.15, 2.0), V(x, (belt + 0.15 + 6.75) / 2, -4.75), "glass")
			b:box("PostB" .. n, V(0.42, roofY - belt, 0.4), V(x, (belt + roofY) / 2, -3.55), "body")
			b:box("Panel" .. n, V(0.3, roofY - belt, 6.2), V(x, (belt + roofY) / 2, -0.25), "body")
			local side = V(s, 0, 0)
			local face = V(s * HW, 5.8, -0.25)
			b:layer("PanelWood" .. n, Vector2.new(5.6, 2.2), face, side, 0.08, "wood")
			b:layer("PanelRailTop" .. n, Vector2.new(5.9, 0.16), face + V(0, 1.18, 0), side, 0.16, "accent")
			b:layer("PanelRailLow" .. n, Vector2.new(5.9, 0.16), face + V(0, -1.18, 0), side, 0.16, "accent")
			b:layer("PanelStileFront" .. n, Vector2.new(0.16, 2.2), face + V(0, 0, -2.87), side, 0.16, "accent")
			b:layer("PanelStileBack" .. n, Vector2.new(0.16, 2.2), face + V(0, 0, 2.87), side, 0.16, "accent")
			b:plate("PanelName" .. n, V(0.3, 0.7, 3.4), V(s * (HW + 0.24 - 0.15), 5.8, -0.25), "SAHUR", s < 0 and Enum.NormalId.Left or Enum.NormalId.Right, "accent", "body")
			b:box("PostC" .. n, V(0.3, roofY - belt, 0.2), V(x, (belt + roofY) / 2, 2.95), "body")
			b:box("QuarterSill" .. n, V(0.26, 0.15, 3.75), V(x, belt + 0.075, 4.925), "body")
			b:box("QuarterHead" .. n, V(0.34, roofY - 6.75, 3.75), V(x, (6.75 + roofY) / 2, 4.925), "body")
			b:box("QuarterGlass" .. n, V(0.08, 6.75 - belt - 0.15, 3.6), V(x, (belt + 0.15 + 6.75) / 2, 4.9), "glass")
			b:box("CornerBack" .. n, V(0.3, roofY - belt, 0.6), V(x, (belt + roofY) / 2, tailZ - 0.3), "body")
		end
		b:box("RoofPanel", V(7.0, 0.3, tailZ - frontZ - 0.35), V(0, roofY + 0.15, (frontZ + 0.35 + tailZ) / 2), "body")
		b:bevel("RoofBrow", V(0, roofY + 0.15, frontZ + 0.175), 7.0, 0.35, 0.3, FRONT, UP, "body")

		-- Rear doors with windows and the spare wheel.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("RearDoor" .. n, V(3.1, roofY - belt, 0.3), V(s * 1.6, (belt + roofY) / 2, tailZ - 0.15), "body")
			b:layer("RearWindow" .. n, Vector2.new(2.2, 1.1), V(s * 1.6, 6.5, tailZ), BACK, 0.08, "glass")
			b:layer("RearHandle" .. n, Vector2.new(0.14, 0.5), V(s * 0.35, 5.3, tailZ), BACK, 0.1, "chrome")
		end
		b:layer("RearSeam", Vector2.new(0.06, roofY - belt - 0.2), V(0, (belt + roofY) / 2, tailZ), BACK, 0.06, "trim")
		b:cylZ("SpareTyre", 0.7, 2.3, V(1.6, 4.9, tailZ + 0.1 + 0.35), "tyre")
		b:cylZ("SpareCover", 0.3, 1.9, V(1.6, 4.9, tailZ + 0.8 + 0.08 - 0.15), "stripe")
		local spareBadge = b:cylZ("SpareBadge", 0.3, 1.2, V(1.6, 4.9, tailZ + 0.8 + 0.16 - 0.15), "accent")
		local gui = Instance.new("SurfaceGui")
		gui.Face = Enum.NormalId.Left
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 60
		gui.LightInfluence = 1
		gui.Parent = spareBadge
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(0.1, 0.25)
		label.Size = UDim2.fromScale(0.8, 0.5)
		label.Font = Enum.Font.FredokaOne
		label.Text = "TUNG"
		label.TextScaled = true
		label.TextColor3 = b:color("body")
		label.Parent = gui

		-- Roof rack, the bat and the drum.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:tube("RackRail" .. n, V(s * 3.0, roofY + 0.65, -4.5), V(s * 3.0, roofY + 0.65, 6.0), 0.14, "chrome")
			for index, z in ipairs({ -4.5, 0.75, 6.0 }) do
				b:tube(string.format("RackLeg%s%d", n, index), V(s * 3.0, roofY + 0.3, z), V(s * 3.0, roofY + 0.65, z), 0.14, "chrome")
			end
		end
		for index, z in ipairs({ -3.5, -1.0, 1.5, 4.0 }) do
			b:tube("RackBar" .. index, V(-3.0, roofY + 0.65, z), V(3.0, roofY + 0.65, z), 0.12, "chrome")
		end
		-- The bat is built in its own frame, raked up at the barrel and turned across the roof, so it
		-- reads as a bat strapped on at an angle. Laid out along Z at one height -- which is how it was
		-- -- every piece is horizontal and the whole thing looks like a length of pipe lying on the
		-- rack, which is exactly what Oliver reported.
		--
		-- #116 ("bat parts still appear sideways"): the rake above was already correct (confirmed by
		-- an axis audit across all 7 vehicle kinds, 562 Cylinder parts, zero orientation defects --
		-- this was never the Enum.PartType.Cylinder X-axis bug). The actual fault was clearance, not
		-- axis: at the old batY (roofY + 0.95) the handle end's own geometry put BatKnob's centre at
		-- roofY - 0.01, so its lower half (radius 0.23) sank ~0.23 studs INTO Hull_Roof, and
		-- BatHandle's near end (+0.04, radius 0.15) dipped in too -- confirmed by an occlusion ray
		-- (BatKnob occluded by Hull_Roof) and a close render showing the handle vanishing into the
		-- roof by the drum. Raised so the lowest point (BatKnob's underside) clears the roof by about
		-- 0.16 studs, matching the ~0.15-0.2 stud margins used elsewhere in this file; nothing about
		-- the rotation (A(-15, 13, 0)) changed.
		--
		-- #116 again (Oliver, after the fix above: "bat parts still sideways"): measured by
		-- tools/vehicle_models_axis_check.py, the bat ran 21 degrees off the van's length -- the 13
		-- degree turn plus the 15 degree rake put its barrel 3.1 studs above the roof, the highest point
		-- on the van, with nothing under it -- and it was not even straight: the lifts on the taper,
		-- throat and barrel bent each piece off the bat's own line by up to 4.5 degrees. So: one straight
		-- line, pointing along the van like the rack rails, and resting ON the rack. The rake left is the
		-- one a real bat takes lying on a rack: handle on the front bar, barrel on the middle-rear bar,
		-- so the axis climbs by the difference between the two radii over the gap between the bars.
		local barTop = roofY + 0.65 + 0.06 -- the cross bars' tops (0.12 across, at roofY + 0.65)
		local batX, batZ = -1.4, -0.4
		local handleBar, barrelBar = -3.5, 1.5 -- the cross bars the handle and the barrel lie on
		local handleR, barrelR = 0.15, 0.49
		local rake = math.deg(math.atan((barrelR - handleR) / (barrelBar - handleBar)))
		local batY = barTop + handleR + (batZ - handleBar) * (barrelR - handleR) / (barrelBar - handleBar)
		local bat = CF(V(batX, batY, batZ)) * A(-rake, 0, 0)
		local function batAt(z, lift)
			return (bat * CF(0, lift or 0, z)).Position
		end
		-- #116 a third time (Oliver 09-24, "the bat on top is broken"), measured by
		-- tools/vehicle_models_axis_check.py with the real z-fight pass and the mortar swung through
		-- its arc: (1) the straps were placed in the bat's own frame at -1.0 and 1.5, which were the
		-- bars' positions before the bat moved to batZ, so both hung 0.4 studs off their bars in thin
		-- air under the bat; (2) the handle went 0.30 -> 0.56 -> 0.78 -> 0.98 across in three hard
		-- steps, which reads as separate pieces stuck end to end; (3) the roof mortar's tube swung
		-- straight through the barrel (see Mounts). Now: six pieces stepping 0.12-0.16 at a time,
		-- the straps on the bars themselves, and the mortar high enough to pass over.
		-- Seams (handoff 09-25): those six pieces still showed a ring at every joint (radius steps of
		-- 0.06-0.08), which read as see-through. The handle now widens into the barrel through
		-- Builder:taper, one straight taper in steps under TAPER_STEP.
		b:ball("BatKnob", 0.46, batAt(-3.8), "wood")
		b:tube("BatHandle", batAt(-3.6), batAt(-1.6), handleR * 2, "wood")
		local taperFrom, taperTo = -1.6, 1.6 -- the barrel's end is 4.0
		local taperDiameter = b:taper("BatTaper", batAt(taperFrom), batAt(taperTo), handleR * 2, barrelR * 2, "wood")
		b:tube("BatBarrel", batAt(taperTo), batAt(4.0), barrelR * 2, "wood")
		b:cyl("BatEnd", 0.16, 0.9, CF(batAt(4.06)) * (bat - bat.Position) * A(0, 90, 0), "wood")
		for index, barZ in ipairs({ -1.0, barrelBar }) do
			-- Each strap lies across the bar it is named for, just under the bat: its top 0.04 into the
			-- wood and its bottom 0.04 into the bar (the bat's underside meets the bar top within a hair
			-- at both, see the rake above).
			local z = (barZ - batZ) / math.cos(math.rad(rake))
			local radius = barrelR
			if z >= taperFrom and z < taperTo then
				radius = taperDiameter((z - taperFrom) / (taperTo - taperFrom)) / 2
			end
			b:box("BatStrap" .. index, V(0.9, 0.12, 0.2), CF(batAt(z, -radius - 0.02)) * (bat - bat.Position), "accent")
		end
		local drum = V(1.4, roofY + 1.3, 2.8)
		b:cyl("DrumShell", 1.2, 2.0, CF(drum) * A(0, 0, 90), "stripe")
		-- Rims stand 0.06 past the shell's ends and the skin 0.12, so no two end faces share a plane.
		b:cyl("DrumRimTop", 0.14, 2.12, CF(drum + V(0, 0.6 + 0.06 - 0.07, 0)) * A(0, 0, 90), "accent")
		b:cyl("DrumRimLow", 0.14, 2.12, CF(drum + V(0, -0.6 - 0.06 + 0.07, 0)) * A(0, 0, 90), "accent")
		b:cyl("DrumSkin", 0.3, 1.9, CF(drum + V(0, 0.6 + 0.12 - 0.15, 0)) * A(0, 0, 90), "plate")
		for index = 1, 8 do
			local a0 = rad((index - 1) * 45)
			local a1 = rad((index - 1) * 45 + 22.5)
			b:beam("DrumRope" .. index, drum + V(math.cos(a0) * 1.03, -0.45, math.sin(a0) * 1.03), drum + V(math.cos(a1) * 1.03, 0.45, math.sin(a1) * 1.03), 0.05, 0.05, "plate")
		end
		-- Fatter than they were: at 0.1 across and nearly two studs long these read from any distance as
		-- thin dark rods stuck on the roof, which is what "random black poles" describes. With a head on
		-- each they read as drumsticks, which is what they are.
		b:tube("DrumstickA", drum + V(-0.7, 0.75, -0.5), drum + V(0.7, 0.8, 0.5), 0.17, "wood")
		b:tube("DrumstickB", drum + V(-0.7, 0.8, 0.5), drum + V(0.7, 0.75, -0.5), 0.17, "wood")
		b:ball("DrumstickTipA", 0.27, drum + V(0.7, 0.8, 0.5), "wood")
		b:ball("DrumstickTipB", 0.27, drum + V(0.7, 0.75, -0.5), "wood")

		-- Front: a two-tone face with round lamps, a drum badge, bumper and overriders, big mirrors.
		local frontFace = V(0, 0, frontZ)
		b:layer("FrontBand", Vector2.new(6.9, 0.7), frontFace + V(0, 3.9, 0), FRONT, 0.08, "accent")
		b:cylZ("DrumBadge", 0.3, 0.62, V(0, 3.9, frontZ - 0.16 + 0.15), "stripe")
		b:layer("Grille", Vector2.new(2.4, 0.6), frontFace + V(0, 2.75, 0), FRONT, 0.1, "mesh")
		for index, y in ipairs({ 2.6, 2.9 }) do
			b:layer("GrilleBar" .. index, Vector2.new(2.2, 0.08), frontFace + V(0, y, 0), FRONT, 0.18, "chrome")
		end
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:cylZ("HeadlampBezel" .. n, 0.3, 1.1, V(s * 2.45, 2.75, frontZ - 0.1 + 0.15), "chrome")
			b:cylZ("Headlamp" .. n, 0.3, 0.84, V(s * 2.45, 2.75, frontZ - 0.18 + 0.15), "lamp")
			b:cylZ("Indicator" .. n, 0.3, 0.4, V(s * 2.45, 1.95, frontZ - 0.14 + 0.15), "amber")
			b:box("Overrider" .. n, V(0.35, 0.9, 0.4), V(s * 1.6, 1.6, frontZ - 0.55), "chrome")
			b:beam("MirrorArm" .. n, V(s * 3.5, 6.2, -6.1), V(s * 4.1, 6.0, -6.3), 0.12, 0.12, "chrome")
			b:box("Mirror" .. n, V(0.22, 1.1, 0.7), V(s * 4.2, 5.7, -6.35), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.6, 0.18), V(s * 4.2, 5.7, -6.0), BACK, 0.08, "chrome")
			b:beam("Wiper" .. n, V(s * 0.3, belt + 0.25, screenBase - 0.05), V(s * 2.6, belt + 0.2, screenBase - 0.05), 0.06, 0.08, "trim")
		end
		b:box("FrontBumper", V(7.4, 0.6, 0.6), V(0, 1.5, frontZ - 0.25), "chrome")
		b:plate("PlateFront", V(1.7, 0.42, 0.3), V(0, 1.5, frontZ - 0.55 - 0.12 + 0.15), "TUNG 3X", Enum.NormalId.Front)

		-- Tail.
		local tailFace = V(0, 0, tailZ)
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:cylZ("TailBezel" .. n, 0.3, 0.9, V(s * 2.9, 3.6, tailZ + 0.1 - 0.15), "chrome")
			b:cylZ("Tail" .. n, 0.3, 0.7, V(s * 2.9, 3.6, tailZ + 0.18 - 0.15), "tail")
			b:cylZ("Reverse" .. n, 0.3, 0.36, V(s * 2.9, 2.75, tailZ + 0.14 - 0.15), "lamp")
		end
		b:box("RearBumper", V(7.4, 0.6, 0.6), V(0, 1.5, tailZ + 0.25), "chrome")
		b:plate("PlateRear", V(1.7, 0.42, 0.3), V(0, 2.5, tailZ + 0.12 - 0.15), "TUNG 3X", Enum.NormalId.Back)

		-- Sides.
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local side = V(s, 0, 0)
			b:layer("Stripe" .. n, Vector2.new(tailZ - frontZ - 0.4, 0.3), V(s * HW, 3.6, (frontZ + tailZ) / 2), side, 0.06, "stripe")
			b:layer("CabHandle" .. n, Vector2.new(0.5, 0.14), V(s * HW, 4.05, -3.9), side, 0.12, "chrome")
			b:layer("CabSeam" .. n, Vector2.new(0.05, belt - sill - 0.3), V(s * HW, (sill + belt) / 2, doorFront + 0.1), side, 0.06, "mesh")
		end
		b:layer("SlidingRail", Vector2.new(4.6, 0.08), V(HW, belt - 0.25, 0.3), V(1, 0, 0), 0.1, "chrome")
		b:layer("SlidingHandle", Vector2.new(0.14, 0.5), V(HW, 3.0, 2.3), V(1, 0, 0), 0.12, "chrome")
		b:layer("FuelCap", Vector2.new(0.46, 0.46), V(-HW, 3.0, 5.9), V(-1, 0, 0), 0.08, "trim")

		-- Cabin and the benches in the back.
		b:box("Dash", V(5.94, 0.8, 0.9), V(0, 4.0, -5.6), "dash")
		for index, x in ipairs({ -1.85, -1.35 }) do
			b:cylZ("Gauge" .. index, 0.3, 0.4, V(x, 4.2, -5.15 + 0.1 - 0.15), "gauge")
		end
		b:tube("Column", V(-1.45, 4.2, -5.4), V(-1.45, 4.7, -5.0), 0.2, "dash")
		b:steeringWheel("SteeringWheel", V(-1.45, 4.76, -4.9), V(0, 0.8, 0.6).Unit, 0.62)
		b:bucketSeat("SeatDriver", V(-1.45, 3.2, -4.2), 1.6, 1.6, 2.2, 10)
		b:bucketSeat("SeatPassenger", V(1.45, 3.2, -4.2), 1.6, 1.6, 2.2, 10)
		b:box("Partition", V(4.2, 1.0, 0.2), V(0, 3.5, doorFront + 1.8), "dash")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Bench" .. n, V(0.9, 0.45, 3.2), V(s * 1.65, 2.83, 3.0), "seat")
			b:box("BenchBack" .. n, V(0.3, 1.6, 3.2), V(s * 2.0, 3.85, 3.0), "seat")
		end
		b:box("CargoCrate", V(1.3, 1.1, 1.1), V(0, 3.15, 6.3), "wood")

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "steel", rimScale = 0.6, sneaker = true })
		end

		return {
			seats = {
				driver = CF(-1.45, 3.26, -4.2),
				passengers = { CF(1.45, 3.26, -4.2), CF(1.65, 2.9, 3.0) * A(0, 90, 0), CF(-1.65, 2.9, 3.0) * A(0, -90, 0) },
			},
			exits = { CF(-5.6, 0, -4.2), CF(5.6, 0, -4.2), CF(-5.6, 0, 1.0), CF(5.6, 0, 1.0), CF(0, 0, -9.6), CF(0, 0, 10.4), CF(0, 8.2, 0) },
			pose = { name = "CarDriver" },
		}
	end,
}

-- Bananini Scoot: a round, friendly scooter with a crate of bananas on the rack. Not fast, but it
-- turns on the spot and shrugs off a knock.
VehicleModels.Models.BananiniScoot = {
	kind = "bike",
	displayName = "Bananini Scoot",
	weight = 22,
	schemes = {
		{ name = "Ripe Banana", body = Color3.fromRGB(250, 210, 48), accent = Color3.fromRGB(110, 76, 42), stripe = Color3.fromRGB(108, 176, 60), seat = Color3.fromRGB(96, 60, 36), rim = Color3.fromRGB(232, 232, 234) },
		{ name = "Green Banana", body = Color3.fromRGB(150, 202, 72), accent = Color3.fromRGB(250, 236, 150), stripe = Color3.fromRGB(250, 210, 48), seat = Color3.fromRGB(62, 52, 40), rim = Color3.fromRGB(240, 240, 240) },
		{ name = "Banana Split", body = Color3.fromRGB(250, 236, 214), accent = Color3.fromRGB(206, 58, 80), stripe = Color3.fromRGB(122, 72, 42), seat = Color3.fromRGB(122, 72, 42), rim = Color3.fromRGB(206, 58, 80) },
		{ name = "Monkey Business", body = Color3.fromRGB(132, 88, 56), accent = Color3.fromRGB(250, 210, 48), stripe = Color3.fromRGB(250, 210, 48), seat = Color3.fromRGB(40, 36, 34), rim = Color3.fromRGB(250, 210, 48) },
		{ name = "Gelato Mint", body = Color3.fromRGB(170, 230, 206), accent = Color3.fromRGB(250, 246, 236), stripe = Color3.fromRGB(240, 120, 150), seat = Color3.fromRGB(250, 246, 236), rim = Color3.fromRGB(250, 246, 236) },
	},
	build = function(b)
		local r = 0.95
		local fz, rz = -2.35, 2.15
		local head = V(0, 3.9, -1.4)
		local down = V(0, -0.951, -0.309)
		local function P(t, x)
			return head + down * t + V(x or 0, 0, 0)
		end
		local steerRotation = CFrame.fromMatrix(Vector3.zero, V(1, 0, 0), -down)
		local function onAxis(t)
			return CF(P(t)) * steerRotation
		end
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(1.2, 1.5, 4.2), V(0, 2.05, 0.1), 1.6)

		-- Steering: the headset with its round lamp, bars and mirrors, and the front mudguard.
		local steer = b:pivot("Steer_F", onAxis(0), "Steer")
		local slider = b:pivot("Slider_F", onAxis(2.6), "Slider", steer)
		b:with(steer, function()
			b:tube("Column", P(-0.1), P(2.2), 0.24, "chrome")
			b:box("Headset", V(1.0, 0.46, 0.9), V(0, 4.28, -1.5), "body")
			b:cylZ("HeadsetDome", 0.8, 1.0, V(0, 4.51, -1.5), "body")
			b:cylZ("HeadlampRing", 0.3, 0.74, V(0, 4.28, -1.95 - 0.1 + 0.15), "chrome")
			b:cylZ("Headlamp", 0.3, 0.54, V(0, 4.28, -1.95 - 0.18 + 0.15), "lamp")
			b:cylZ("Speedo", 0.3, 0.36, V(0, 4.42, -1.05 + 0.1 - 0.15), "gauge")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:tube("Bar" .. n, V(s * 0.45, 4.3, -1.32), V(s * 1.1, 4.35, -1.14), 0.13, "chrome")
				b:tube("Grip" .. n, V(s * 0.78, 4.33, -1.22), V(s * 1.12, 4.36, -1.13), 0.2, "rubber")
				b:beam("Lever" .. n, V(s * 0.45, 4.37, -1.44), V(s * 1.0, 4.37, -1.36), 0.05, 0.05, "chrome")
				b:tube("MirrorStalk" .. n, V(s * 0.42, 4.5, -1.3), V(s * 0.8, 5.15, -1.26), 0.07, "chrome")
				b:cylZ("Mirror" .. n, 0.12, 0.44, V(s * 0.84, 5.26, -1.25), "chrome")
			end
			local axle = V(0, r, fz)
			b:arc("Mudguard", axle, 1.3, -76, 56, 8, 0.86, 0.12, "body")
			b:box("MudguardCrest", V(0.24, 0.14, 0.9), CF(axle) * A(-30, 0, 0) * CF(0, 1.42, 0), "stripe")
		end)
		b:with(slider, function()
			-- A sleeve that slides on the column, with brackets out to the link and the damper. The
			-- link and damper used to start 0.36 to the side of the column with nothing joining them
			-- to it, so with the front wheel hanging (the slider 0.37 down the column) the whole
			-- front wheel assembly hung clear of the scooter (vehicle_models_runtime_check).
			b:tube("ForkSleeve", P(1.7), P(2.55), 0.34, "chrome")
			b:beam("LinkBracket", P(2.45), P(2.45, -0.42), 0.14, 0.14, "engine")
			b:beam("DamperBracket", P(1.9), P(1.9, -0.42), 0.14, 0.14, "engine")
			b:beam("TrailingLink", P(2.45, -0.36), V(-0.4, r, fz), 0.12, 0.26, "engine")
			b:tube("Damper", P(1.9, -0.36), V(-0.4, r + 0.3, fz + 0.35), 0.16, "chrome")
		end)
		b:roadWheel("Wheel_F", V(0, r, fz), r, 0.6, -1, { steer = true, parent = slider, style = "steel", rimScale = 0.62 })

		-- Leg shield, its glovebox and badge.
		b:beam("ShieldLow", V(0, 1.3, -1.72), V(0, 2.6, -1.98), 1.9, 0.28, "body")
		b:beam("ShieldMid", V(0, 2.6, -1.98), V(0, 3.55, -1.9), 1.7, 0.28, "body")
		b:beam("ShieldTop", V(0, 3.55, -1.9), V(0, 4.02, -1.62), 1.3, 0.28, "body")
		for _, s in ipairs({ -1, 1 }) do
			-- The shield's edges wrap back round the rider's shins.
			b:beam(s < 0 and "ShieldWingL" or "ShieldWingR", V(s * 0.9, 1.35, -1.72), V(s * 0.8, 3.4, -1.75), 0.3, 0.5, "body")
		end
		b:beam("Glovebox", V(0, 2.3, -1.72), V(0, 3.4, -1.66), 1.1, 0.14, "accent")
		b:cylZ("Badge", 0.3, 0.46, V(0, 3.1, -2.12 - 0.1 + 0.15), "stripe")

		-- Floorboard and the round body.
		b:box("Floorboard", V(1.3, 0.18, 1.8), V(0, 1.35, -0.8), "body")
		for index = 1, 3 do
			b:layer("FloorStrip" .. index, Vector2.new(0.08, 1.6), V(-0.4 + (index - 1) * 0.4, 1.44, -0.8), UP, 0.06, "rubber")
		end
		b:box("Tunnel", V(0.52, 0.45, 1.8), V(0, 1.05, -0.8), "body")
		b:box("Cowl", V(1.5, 0.9, 2.3), V(0, 2.2, 1.3), "body")
		-- The body sweeps down to the floorboard at its front and over the back wheel at its sides.
		b:box("CowlFoot", V(1.32, 0.5, 0.5), V(0, 1.55, 0.4), "body")
		for _, s in ipairs({ -1, 1 }) do
			b:box(s < 0 and "HipPanelL" or "HipPanelR", V(0.2, 0.9, 2.16), V(s * 0.82, 1.75, 1.5), "body")
		end
		b:box("CowlTop", V(1.1, 0.3, 1.9), V(0, 2.8, 1.3), "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:bevel("CowlShoulder" .. n, V(s * 0.65, 2.8, 1.3), 1.9, 0.2, 0.3, V(s, 0, 0), UP, "body")
			b:cylZ("Cheek" .. n, 1.9, 0.96, V(s * 0.66, 1.98, 1.45), "body")
			b:layer("CheekStripe" .. n, Vector2.new(1.6, 0.08), V(s * 1.14, 1.98, 1.45), V(s, 0, 0), 0.06, "stripe")
		end
		b:bevel("CowlBrow", V(0, 2.8, 0.25), 1.1, 0.2, 0.3, FRONT, UP, "body")
		b:bevel("CowlTail", V(0, 2.8, 2.35), 1.1, 0.2, 0.3, BACK, UP, "body")
		b:layer("TailLight", Vector2.new(0.5, 0.22), V(0, 2.42, 2.45), BACK, 0.12, "tail")
		b:plate("PlateRear", V(0.9, 0.36, 0.3), V(0, 2.0, 2.45 + 0.12 - 0.15), "BAN 4NA", Enum.NormalId.Back)

		-- Seat, grab rail, rack and the crate of bananas.
		b:box("Seat", V(1.02, 0.34, 2.0), V(0, 3.12, 1.2), "seat")
		b:bevel("SeatNose", V(0, 3.12, 0.05), 1.02, 0.3, 0.34, FRONT, UP, "seat")
		for _, s in ipairs({ -1, 1 }) do
			b:layer(s < 0 and "SeatPipingL" or "SeatPipingR", Vector2.new(1.9, 0.07), V(s * 0.51, 3.05, 1.2), V(s, 0, 0), 0.06, "accent")
		end
		b:pipe("GrabRail", { V(-0.56, 3.08, 1.2), V(-0.56, 3.12, 2.05), V(0, 3.16, 2.3), V(0.56, 3.12, 2.05), V(0.56, 3.08, 1.2) }, 0.12, "chrome")
		for _, s in ipairs({ -1, 1 }) do
			b:tube(s < 0 and "RackRailL" or "RackRailR", V(s * 0.4, 3.02, 2.3), V(s * 0.4, 3.05, 3.15), 0.08, "chrome")
		end
		b:tube("RackCross", V(-0.4, 3.05, 3.1), V(0.4, 3.05, 3.1), 0.06, "chrome")
		b:box("BananaCrate", V(0.95, 0.5, 0.75), V(0, 3.34, 2.78), "wood")
		b:box("BananaStalk", V(0.5, 0.1, 0.12), V(0, 3.66, 2.48), "stalk")
		for index, x in ipairs({ -0.22, 0, 0.22 }) do
			b:pipe("Banana" .. index, { V(x, 3.66, 2.52), V(x, 3.74, 2.72), V(x, 3.76, 2.92), V(x, 3.7, 3.08) }, 0.16, "banana")
			b:ball("BananaTip" .. index, 0.1, V(x, 3.69, 3.12), "stalk")
		end

		-- The engine and silencer swing with the back wheel, as a scooter's do.
		local swing = b:pivot("Swing_R", CF(0, 1.35, 0.5), "Swing")
		b:with(swing, function()
			-- The pivot bolt the engine swings on, and a transmission case long enough to reach the
			-- back axle, with the axle itself: the case stopped 0.25 short of the axle and 0.1 short of
			-- the pivot, so the engine and the back wheel swung round points in thin air.
			b:cyl("SwingPivotBolt", 1.0, 0.22, CF(-0.6, 1.35, 0.5), "alloy")
			b:box("Transmission", V(0.34, 0.55, 1.75), V(-0.98, 1.1, 1.475), "engine")
			b:cyl("RearAxle", 0.7, 0.2, CF(-0.5, r, rz), "alloy")
			b:cyl("FanCover", 0.1, 0.6, CF(-1.12, 1.15, 0.95), "alloy")
			b:pipe("ExhaustPipe", { V(-0.1, 1.05, 0.62), V(0.5, 0.85, 1.3), V(0.81, 1.12, 1.78) }, 0.2, "chrome")
			b:tube("Silencer", V(0.8, 1.1, 1.65), V(0.82, 1.35, 2.6), 0.34, "chrome")
			b:tube("SilencerBore", V(0.81, 1.28, 2.32), V(0.82, 1.34, 2.57), 0.22, "mesh")
		end)
		b:roadWheel("Wheel_R", V(0, r, rz), r, 0.65, -1, { parent = swing, style = "steel", rimScale = 0.62 })

		return {
			seats = {
				driver = CF(0, 3.14, 0.55),
				passengers = { CF(0, 3.14, 1.7) },
			},
			exits = { CF(-2.6, 0, 0.2), CF(2.6, 0, 0.2), CF(-2.6, 0, -1.8), CF(2.6, 0, 1.9), CF(0, 0, -4.4), CF(0, 0, 4.6) },
			pose = { name = "ScootRider" },
		}
	end,
}

-- Brr Streetfighter: a naked sports bike in frosty colours, with a trellis frame, an inline four and
-- a scowl of two slit headlamps under ice-blue brows. The fastest thing in the game.
VehicleModels.Models.BrrStreetfighter = {
	kind = "bike",
	displayName = "Brr Streetfighter",
	weight = 16,
	schemes = {
		{ name = "Glacier", body = Color3.fromRGB(150, 220, 250), accent = Color3.fromRGB(30, 34, 44), stripe = Color3.fromRGB(250, 252, 255), seat = Color3.fromRGB(30, 34, 44), rim = Color3.fromRGB(150, 220, 250), frame = Color3.fromRGB(40, 44, 56) },
		{ name = "Blizzard", body = Color3.fromRGB(240, 244, 248), accent = Color3.fromRGB(40, 44, 52), stripe = Color3.fromRGB(80, 170, 240), seat = Color3.fromRGB(40, 44, 52), rim = Color3.fromRGB(40, 44, 52), frame = Color3.fromRGB(204, 40, 50) },
		{ name = "Frostbite", body = Color3.fromRGB(60, 70, 92), accent = Color3.fromRGB(20, 22, 28), stripe = Color3.fromRGB(120, 230, 255), seat = Color3.fromRGB(20, 22, 28), rim = Color3.fromRGB(120, 230, 255), frame = Color3.fromRGB(120, 230, 255) },
		{ name = "Popsicle", body = Color3.fromRGB(240, 90, 140), accent = Color3.fromRGB(250, 240, 120), stripe = Color3.fromRGB(120, 220, 250), seat = Color3.fromRGB(40, 40, 48), rim = Color3.fromRGB(250, 240, 120), frame = Color3.fromRGB(250, 250, 250) },
		{ name = "Black Ice", body = Color3.fromRGB(24, 26, 32), accent = Color3.fromRGB(24, 26, 32), stripe = Color3.fromRGB(160, 240, 255), seat = Color3.fromRGB(24, 26, 32), rim = Color3.fromRGB(160, 240, 255), frame = Color3.fromRGB(160, 240, 255) },
	},
	build = function(b)
		local r = 1.3
		local fz, rz = -3.03, 2.75
		local head = V(0, 3.95, -1.85)
		local down = V(0, -0.9135, -0.4067)
		local function P(t, x)
			return head + down * t + V(x or 0, 0, 0)
		end
		local steerRotation = CFrame.fromMatrix(Vector3.zero, V(1, 0, 0), -down)
		local function onAxis(t, x)
			return CF(P(t, x)) * steerRotation
		end
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(1.1, 1.4, 4.6), V(0, 2.45, -0.1), 1.6)

		-- Steering: forks, clamps, flat bars with bar-end mirrors, the scowling face.
		local steer = b:pivot("Steer_F", onAxis(0), "Steer")
		local slider = b:pivot("Slider_F", onAxis(1.9), "Slider", steer)
		b:with(steer, function()
			for _, s in ipairs({ -1, 1 }) do
				b:tube(s < 0 and "ForkUpperL" or "ForkUpperR", P(-0.35, s * 0.8), P(1.55, s * 0.8), 0.3, "gold")
			end
			b:box("ClampTop", V(1.9, 0.14, 0.46), onAxis(-0.26), "alloy")
			b:box("ClampBottom", V(1.9, 0.2, 0.5), onAxis(0.55), "alloy")
			b:tube("Bar", V(-1.1, 4.22, -1.62), V(1.1, 4.22, -1.62), 0.13, "trim")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:tube("Grip" .. n, V(s * 0.82, 4.22, -1.61), V(s * 1.12, 4.22, -1.6), 0.2, "rubber")
				b:beam("Lever" .. n, V(s * 0.45, 4.25, -1.8), V(s * 1.02, 4.25, -1.74), 0.05, 0.05, "chrome")
				b:tube("MirrorArm" .. n, V(s * 1.12, 4.22, -1.6), V(s * 1.36, 4.36, -1.54), 0.06, "trim")
				b:cylZ("Mirror" .. n, 0.1, 0.46, V(s * 1.42, 4.42, -1.52), "chrome")
			end
			local face = CF(0, 3.5, -2.5) * A(18, 0, 0)
			b:box("Cowl", V(1.1, 0.9, 0.5), face, "accent")
			b:box("CowlChin", V(0.8, 0.22, 0.44), face * CF(0, -0.52, -0.04), "trim")
			b:box("Flyscreen", V(0.9, 0.5, 0.08), face * CF(0, 0.62, 0.12) * A(-25, 0, 0), "dash")
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				b:box("Eye" .. n, V(0.36, 0.16, 0.3), face * CF(s * 0.25, 0.02, -0.25 - 0.1 + 0.15) * A(0, 0, s * 14), "lamp")
				b:box("Brow" .. n, V(0.5, 0.07, 0.3), face * CF(s * 0.27, 0.24, -0.25 - 0.18 + 0.15) * A(0, 0, -s * 20), "drl")
			end
		end)
		b:with(slider, function()
			for _, s in ipairs({ -1, 1 }) do
				local n = s < 0 and "L" or "R"
				-- From 0.95 (was 1.35): the slider runs 0.38 out along the fork with the wheel hanging, and
				-- a 0.2 overlap left a gap between the legs. Inside the upper, the extra length never shows.
				b:tube("ForkLower" .. n, P(0.95, s * 0.8), P(2.92, s * 0.8), 0.22, "chrome")
				b:box("AxleFoot" .. n, V(0.24, 0.34, 0.4), onAxis(2.92, s * 0.8), "trim")
				b:box("Caliper" .. n, V(0.14, 0.5, 0.26), CF(s * 0.67, r + 0.5, fz + 0.4) * A(30, 0, 0), "tail")
			end
			b:arc("Fender", V(0, r, fz), r + 0.3, -36, 40, 4, 0.62, 0.08, "accent")
		end)
		b:castWheel("Wheel_F", V(0, r, fz), r, 0.5, { steer = true, parent = slider, discs = "twin" })
		b:cyl("FrontAxle", 1.7, 0.16, CF(0, r, fz), "chrome", slider)

		-- Trellis frame.
		local headTop, headLow = V(0, 4.05, -1.9), V(0, 3.3, -2.2)
		b:tube("HeadTube", P(-0.2), P(0.65), 0.34, "frame")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local a = V(s * 0.34, 3.9, -1.5)
			local e = V(s * 0.36, 3.0, -1.4)
			local bb = V(s * 0.5, 3.45, -0.35)
			local c = V(s * 0.5, 2.35, 0.35)
			local d = V(s * 0.46, 3.3, 0.85)
			b:tube("Trellis1" .. n, headTop, a, 0.12, "frame")
			b:tube("Trellis2" .. n, headLow, e, 0.12, "frame")
			b:tube("Trellis3" .. n, a, bb, 0.12, "frame")
			b:tube("Trellis4" .. n, e, bb, 0.12, "frame")
			b:tube("Trellis5" .. n, a, e, 0.12, "frame")
			b:tube("Trellis6" .. n, e, c, 0.12, "frame")
			b:tube("Trellis7" .. n, bb, c, 0.12, "frame")
			b:tube("Trellis8" .. n, bb, d, 0.12, "frame")
			b:tube("Trellis9" .. n, c, d, 0.12, "frame")
			b:tube("Subframe" .. n, d, V(s * 0.3, 3.72, 2.6), 0.1, "frame")
			b:tube("SubframeStay" .. n, c, V(s * 0.3, 3.55, 2.0), 0.1, "frame")
			for _, joint in ipairs({ a, e, bb, c, d }) do
				-- Clearly fatter than the 0.12 tubes they join. At 0.14 the ball's surface and the
				-- tube's grazed each other, which shimmers exactly the way the exhaust did; at 0.2 it
				-- reads as the welded lug a trellis frame actually has.
				b:ball(string.format("Node%s%d", n, math.floor(joint.Z * 10 + 50)), 0.2, joint, "frame")
			end
		end

		-- Inline four: crankcase and covers, a finned block leaning forward, radiator, four headers.
		b:box("Crankcase", V(1.2, 1.0, 1.4), V(0, 1.9, -0.1), "engine")
		b:box("Sump", V(0.8, 0.3, 0.8), V(0, 1.28, -0.2), "engine")
		b:cyl("ClutchCover", 0.14, 0.9, CF(0.67, 1.92, 0.1), "alloy")
		b:cyl("AlternatorCover", 0.14, 0.76, CF(-0.67, 1.95, -0.25), "alloy")
		local block = CF(0, 2.55, -0.6) * A(-22, 0, 0)
		b:box("Block", V(1.3, 0.9, 0.8), block, "engine")
		for index = 1, 5 do
			b:box("Fin" .. index, V(1.44, 0.05, 0.94), block * CF(0, -0.36 + (index - 1) * 0.17, 0), "alloy")
		end
		b:box("CamCover", V(1.2, 0.28, 0.78), block * CF(0, 0.6, 0), "stripe")
		b:box("Airbox", V(0.8, 0.6, 0.8), V(0, 2.95, 0.4), "dash")
		b:box("Radiator", V(1.3, 1.0, 0.12), CF(0, 2.6, -1.6) * A(12, 0, 0), "mesh")
		for _, s in ipairs({ -1, 1 }) do
			b:wedge(s < 0 and "RadiatorShroudL" or "RadiatorShroudR", V(0.14, 0.9, 0.7), CF(s * 0.72, 2.75, -1.5) * A(0, 180, 0), "body")
		end
		for index, x in ipairs({ -0.45, -0.15, 0.15, 0.45 }) do
			b:pipe("HeadPipe" .. index, { V(x, 2.62, -0.92), V(x * 0.9, 1.7, -1.55), V(x * 0.6, 1.08, -1.05), V(x * 0.2, 1.02, -0.2) }, 0.19, "chrome")
		end
		b:pipe("Collector", { V(0, 1.02, -0.2), V(0.45, 1.05, 0.4), V(0.95, 1.3, 1.0) }, 0.26, "exhaust")
		b:tube("Silencer", V(1.0, 1.38, 0.95), V(1.06, 1.8, 1.95), 0.5, "alloy")
		b:tube("SilencerCap", V(1.06, 1.78, 1.91), V(1.07, 1.85, 2.08), 0.64, "dash")
		b:tube("SilencerBore", V(1.05, 1.72, 1.7), V(1.07, 1.84, 2.05), 0.34, "mesh")

		-- Tank with scoops, seat, pointed tail.
		b:box("Tank", V(1.2, 0.7, 1.1), V(0, 3.95, -0.5), "body")
		b:box("TankBase", V(0.78, 0.5, 1.5), V(0, 3.5, -0.45), "accent")
		b:bevel("TankNose", V(0, 3.95, -1.2), 1.2, 0.3, 0.7, FRONT, UP, "body")
		b:layer("TankStripe", Vector2.new(0.3, 0.96), V(0, 4.3, -0.5), UP, 0.06, "stripe")
		for _, s in ipairs({ -1, 1 }) do
			b:wedge(s < 0 and "ScoopL" or "ScoopR", V(0.22, 0.62, 0.8), CF(s * 0.68, 3.8, -1.15), "body")
			b:plate(s < 0 and "TailBadgeL" or "TailBadgeR", V(0.3, 0.22, 0.8), CF(s * 0.4, 3.66, 2.35), "BRR", s < 0 and Enum.NormalId.Left or Enum.NormalId.Right, "body", "stripe")
		end
		b:box("Seat", V(0.95, 0.3, 1.5), V(0, 3.62, 0.75), "seat")
		b:box("PillionHump", V(0.83, 0.42, 0.9), V(0, 3.74, 1.62), "seat")
		b:box("Tail", V(0.7, 0.42, 1.0), V(0, 3.65, 2.35), "body")
		b:wedge("TailTip", V(0.78, 0.4, 0.9), CF(0, 3.72, 3.3) * A(0, 180, 0), "body")
		b:box("TailLight", V(0.46, 0.08, 0.3), CF(0, 3.5, 3.05) * A(-12, 0, 0), "tail")
		b:beam("TailTidy", V(0, 3.5, 2.8), V(0, 2.95, 3.55), 0.12, 0.1, "trim")
		b:plate("PlateRear", V(0.8, 0.46, 0.3), V(0, 2.75, 3.68), "BRR 000", Enum.NormalId.Back)
		for _, s in ipairs({ -1, 1 }) do
			b:cyl(s < 0 and "IndicatorL" or "IndicatorR", 0.3, 0.14, CF(s * 0.5, 3.05, 3.5), "amber")
			b:box(s < 0 and "PegL" or "PegR", V(0.5, 0.12, 0.24), V(s * 0.66, 2.38, 0.55), "trim")
			b:box(s < 0 and "HeelPlateL" or "HeelPlateR", V(0.08, 0.5, 0.5), V(s * 0.56, 2.5, 0.72), "alloy")
		end
		b:tube("Shock", V(0, 3.2, 0.5), V(0, 2.1, 1.1), 0.16, "chrome")
		b:tube("ShockSpring", V(0, 3.0, 0.61), V(0, 2.3, 0.99), 0.32, "stripe")

		-- Single-sided swingarm on the left, chain inside it.
		local swing = b:pivot("Swing_R", CF(0, 2.3, 0.4), "Swing")
		b:with(swing, function()
			b:beam("Swingarm", V(-0.45, 2.3, 0.45), V(-0.95, r, rz), 0.24, 0.55, "alloy")
			b:beam("SwingarmBrace", V(-0.45, 2.0, 0.6), V(-0.95, r - 0.2, rz - 0.4), 0.14, 0.2, "alloy")
			b:cyl("AxleNut", 0.2, 0.5, CF(-1.12, r, rz), "alloy")
			-- The axle the wheel hangs on: the single-sided arm ends 0.37 short of the wheel's left face,
			-- and without this the rear wheel had nothing joining it to the bike (it hung in the air
			-- beside the arm, which shows the moment the swingarm swings).
			b:cyl("RearAxle", 0.9, 0.24, CF(-0.6, r, rz), "chrome")
			-- The chain's front end goes round a sprocket; without one it stopped in the air by the engine.
			b:cyl("FrontSprocket", 0.06, 0.5, CF(-0.72, 1.95, 0.35), "alloy")
			b:beam("ChainTop", V(-0.72, 2.2, 0.35), V(-0.72, r + 0.48, rz), 0.07, 0.09, "dash")
			b:beam("ChainBottom", V(-0.72, 1.7, 0.35), V(-0.72, r - 0.48, rz), 0.07, 0.09, "dash")
			b:box("RearCaliper", V(0.14, 0.34, 0.4), V(0.78, r - 0.45, rz + 0.3), "tail")
		end)
		b:castWheel("Wheel_R", V(0, r, rz), r, 0.72, { parent = swing, discs = "right", sprocket = -1 })

		return {
			seats = {
				driver = CF(0, 3.62, 0.6),
				passengers = { CF(0, 3.8, 1.6) },
			},
			exits = { CF(-2.8, 0, 0.2), CF(2.8, 0, 0.2), CF(-2.8, 0, -2.0), CF(2.8, 0, 2.2), CF(0, 0, -5.6), CF(0, 0, 5.8) },
			pose = { name = "SportRider" },
		}
	end,
}

-- A plate lying on a sloped face (a wedge's slope running from (y0, z0) up and back to (y1, z1)), at
-- `t` of the way up it and `x` across: its Z along the slope, its Y out of it, standing `stand` proud.
-- Builder:layer only lays detail on faces square to an axis; armour is sloped.
function Builder:slopePlate(name, y0, z0, y1, z1, t, x, size, stand, role)
	local rise, run = y1 - y0, z1 - z0
	local normal = V(0, run, -rise).Unit
	local surface = V(x, y0 + rise * t, z0 + run * t)
	return self:box(name, size, CFrame.fromMatrix(surface + normal * (stand - size.Y / 2), V(1, 0, 0), normal), role)
end

-- Tartaruga Scout: a light armoured scout car, low and broad, with a turtle's domed shell over its
-- back half -- diamond scutes on top, plates down its flanks -- a sloped glacis with the bow gun's ball
-- in it, a beak-like snout, and an open gun ring on the shell where the gunner stands behind a
-- shielded heavy machine gun. Armoured all round: its vision blocks and slits are armoured glass, so
-- the two up front are shot through the car, not the windows (VehicleArmor). Quick for its weight,
-- still slower and heavier than any car (VehicleDynamics). Rarer than a car in the world, and never
-- parked at the kerb (drivableOnly: VehicleModels.Pick leaves it out unless asked).
VehicleModels.Models.TartarugaScout = {
	kind = "car",
	displayName = "Tartaruga Scout",
	weight = 6,
	drivableOnly = true,
	schemes = {
		{ name = "Snapping Olive", body = Color3.fromRGB(98, 114, 66), accent = Color3.fromRGB(72, 62, 42), stripe = Color3.fromRGB(214, 190, 120), seat = Color3.fromRGB(60, 52, 40), rim = Color3.fromRGB(56, 58, 52) },
		{ name = "Desert Shell", body = Color3.fromRGB(196, 168, 118), accent = Color3.fromRGB(124, 94, 60), stripe = Color3.fromRGB(96, 122, 70), seat = Color3.fromRGB(90, 70, 50), rim = Color3.fromRGB(80, 74, 62) },
		{ name = "Sea Turtle", body = Color3.fromRGB(70, 132, 128), accent = Color3.fromRGB(40, 72, 74), stripe = Color3.fromRGB(236, 214, 150), seat = Color3.fromRGB(40, 50, 52), rim = Color3.fromRGB(40, 50, 52) },
		{ name = "Night Shell", body = Color3.fromRGB(48, 54, 52), accent = Color3.fromRGB(30, 32, 30), stripe = Color3.fromRGB(150, 230, 90), seat = Color3.fromRGB(26, 28, 28), rim = Color3.fromRGB(30, 32, 30) },
		{ name = "Mango Shell", body = Color3.fromRGB(232, 150, 52), accent = Color3.fromRGB(110, 70, 36), stripe = Color3.fromRGB(250, 226, 140), seat = Color3.fromRGB(60, 44, 32), rim = Color3.fromRGB(60, 44, 32) },
	},
	build = function(b)
		local HW = 3.3
		local r, tw, track = 1.6, 1.05, 3.05
		local fz, rz = -4.3, 4.3
		local R = 1.95
		local sill, deck = 1.6, 3.6
		local noseZ, tailZ = -7.0, 6.9
		local screenZ, cabBack = -3.4, 0.8
		local topY = 6.0 -- the cabin roof and the shell's top, which the gun ring stands on
		local glacisTop = 4.7
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.4, 2.6, 13.6), V(0, 2.9, -0.05), 2.2)
		b:hull("Hull_Upper", V(5.6, 1.8, 10.0), V(0, 5.1, 1.6), 0.1)

		-- The lower hull: nose and tail blocks, the flanks between the wheels, the panels round each
		-- opening, the wells, and armoured flares over the tyres.
		b:box("NoseBlock", V(2 * HW - 0.2, deck - sill, fz - R - noseZ), V(0, (sill + deck) / 2, (noseZ + fz - R) / 2), "body")
		b:box("TailBlock", V(2 * HW - 0.2, deck - sill, tailZ - rz - R), V(0, (sill + deck) / 2, (rz + R + tailZ) / 2), "body")
		b:box("Belly", V(2 * (HW - 1.4) - 0.1, deck - sill, doorBack - doorFront), V(0, (sill + deck) / 2, (doorFront + doorBack) / 2), "mesh")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("ArmorFlank" .. n, V(0.5, deck - sill, doorBack - doorFront), V(s * (HW - 0.25), (sill + deck) / 2, (doorFront + doorBack) / 2), "body")
			b:archPanel("ArchPanelF" .. n, r, fz, R, deck, s, HW - 1.4, HW, 12, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, deck, s, HW - 1.4, HW, 12, "body")
			b:box("WellF" .. n, V(0.1, 2.0, 3.6), V(s * 1.95, 2.45, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 2.0, 3.6), V(s * 1.95, 2.45, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * (HW + 0.02), 0.56, 0.32, -104, 104, 12, "accent")
			b:archLip("LipR" .. n, r, rz, R, s * (HW + 0.02), 0.56, 0.32, -104, 104, 12, "accent")
			b:bevel("Rocker" .. n, V(s * (HW - 0.17), sill + 0.2, (doorFront + doorBack) / 2), doorBack - doorFront, 0.34, 0.4, V(s, 0, 0), V(0, -1, 0), "accent")
		end

		-- The glacis: one plate from the snout up to the cabin, the engine's louvres in it, the bow
		-- gun's ball (DriverMounts) off to the right, and the eye-lamps in cages at its front corners.
		b:wedge("ArmorGlacis", V(2 * HW - 0.4, glacisTop - deck, screenZ - noseZ), V(0, (deck + glacisTop) / 2, (noseZ + screenZ) / 2), "body")
		b:slopePlate("EngineGrille", deck, noseZ, glacisTop, screenZ, 0.66, -0.9, V(2.2, 0.2, 1.1), 0.06, "mesh")
		for index = 1, 4 do
			b:slopePlate("EngineLouvre" .. index, deck, noseZ, glacisTop, screenZ, 0.53 + index * 0.052, -0.9, V(2.0, 0.2, 0.08), 0.12, "trim")
		end
		b:slopePlate("GlacisPlate", deck, noseZ, glacisTop, screenZ, 0.2, 0, V(4.6, 0.2, 0.9), 0.08, "accent")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local eye = V(s * 2.35, deck + 0.38, noseZ + 0.3)
			b:box("EyePod" .. n, V(1.0, 0.76, 0.7), eye, "accent")
			b:cylZ("HeadlampRing" .. n, 0.3, 0.64, eye + V(0, 0, -0.42), "trim")
			b:cylZ("Headlamp" .. n, 0.3, 0.46, eye + V(0, 0, -0.48), "lamp")
			for _, x in ipairs({ -0.14, 0.14 }) do
				b:box(string.format("EyeCage%s%d", n, x < 0 and 1 or 2), V(0.06, 0.74, 0.06), eye + V(x, 0, -0.7), "mesh")
			end
			b:box("EyeCageTop" .. n, V(0.66, 0.06, 0.34), eye + V(0, 0.4, -0.56), "mesh")
			b:layer("Indicator" .. n, Vector2.new(0.3, 0.2), V(s * 2.9, deck - 0.35, noseZ), FRONT, 0.1, "amber")
		end

		-- The snout: a beaked bumper with a slatted mouth, tow hooks, and a plate.
		b:box("FrontBumper", V(5.8, 0.8, 0.5), V(0, sill + 0.55, noseZ - 0.25), "trim")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:beam("TowHook" .. n, V(s * 1.9, sill + 0.35, noseZ - 0.45), V(s * 1.9, sill + 0.35, noseZ - 0.8), 0.16, 0.28, "tail")
		end
		b:box("Snout", V(2.6, 0.8, 0.5), V(0, deck - 0.2, noseZ - 0.25), "accent")
		for index, y in ipairs({ deck - 0.42, deck - 0.2, deck + 0.02 }) do
			b:layer("SnoutSlat" .. index, Vector2.new(2.2, 0.08), V(0, y, noseZ - 0.5), FRONT, 0.06, "mesh")
		end
		b:plate("PlateFront", V(1.7, 0.42, 0.3), V(0, sill + 0.55, noseZ - 0.5 - 0.12 + 0.15), "TRT 01", Enum.NormalId.Front)

		-- The cabin: a sloped front plate with two vision blocks, flanks with slits, a flat roof.
		local screenTop = topY - 0.2
		b:wedge("ArmorScreen", V(5.4, screenTop - glacisTop, 1.0), V(0, (glacisTop + screenTop) / 2, screenZ + 0.5), "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:slopePlate("ArmorGlass" .. n, glacisTop, screenZ, screenTop, screenZ + 1.0, 0.55, s * 1.25, V(1.8, 0.2, 0.62), 0.07, "glass")
			b:slopePlate("ArmorGlassFrame" .. n, glacisTop, screenZ, screenTop, screenZ + 1.0, 0.55, s * 1.25, V(2.0, 0.2, 0.8), 0.04, "trim")
			b:box("ArmorCabin" .. n, V(0.3, screenTop - deck, cabBack - screenZ - 1.0), V(s * 2.55, (deck + screenTop) / 2, (screenZ + 1.0 + cabBack) / 2), "body")
			b:layer("ArmorSlit" .. n, Vector2.new(1.0, 0.16), V(s * 2.7, 5.15, -1.3), V(s, 0, 0), 0.06, "glass")
			b:layer("ArmorSlitFrame" .. n, Vector2.new(1.2, 0.34), V(s * 2.7, 5.15, -1.3), V(s, 0, 0), 0.03, "trim")
			b:beam("MirrorArm" .. n, V(s * 2.7, 5.3, -2.15), V(s * 3.2, 5.42, -2.25), 0.18, 0.16, "trim")
			b:box("Mirror" .. n, V(0.26, 0.56, 0.42), V(s * 3.3, 5.45, -2.25), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.16, 0.44), V(s * 3.3, 5.45, -2.04), BACK, 0.08, "chrome")
		end
		b:box("ArmorCabinRoof", V(5.4, 0.2, cabBack - screenZ - 1.0), V(0, topY - 0.1, (screenZ + 1.0 + cabBack) / 2), "accent")
		b:bevel("ArmorCabinBrow", V(0, topY - 0.1, screenZ + 0.85), 5.4, 0.3, 0.2, FRONT, UP, "accent")

		-- The shell: three tiers, each bevelled in, the top one carrying the gun ring (Mounts) and
		-- diamond scutes behind it; plates down the flanks; a rear slope with the hatch.
		local shellBack = tailZ - 0.3
		b:box("ShellLow", V(5.6, 1.3, shellBack - cabBack), V(0, deck + 0.65, (cabBack + shellBack) / 2), "body")
		b:box("ShellMid", V(4.8, 0.7, shellBack - 0.4 - cabBack), V(0, deck + 1.65, (cabBack + shellBack - 0.4) / 2), "body")
		b:box("ShellTop", V(4.0, 0.4, shellBack - 1.0 - cabBack), V(0, topY - 0.2, (cabBack + shellBack - 1.0) / 2), "accent")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:bevel("ShellMidEdge" .. n, V(s * 2.6, deck + 1.65, (cabBack + shellBack - 0.4) / 2), shellBack - 0.4 - cabBack, 0.4, 0.7, V(s, 0, 0), UP, "body")
			b:bevel("ShellTopEdge" .. n, V(s * 2.2, topY - 0.2, (cabBack + shellBack - 1.0) / 2), shellBack - 1.0 - cabBack, 0.4, 0.4, V(s, 0, 0), UP, "accent")
			for index, z in ipairs({ 1.9, 3.6, 5.3 }) do
				b:layer(string.format("ShellPlate%s%d", n, index), Vector2.new(1.5, 0.9), V(s * 2.8, deck + 0.62, z), V(s, 0, 0), 0.08, "accent")
			end
			b:layer("ShellBand" .. n, Vector2.new(shellBack - cabBack - 0.2, 0.12), V(s * 2.8, deck + 1.18, (cabBack + shellBack) / 2), V(s, 0, 0), 0.05, "stripe")
		end
		b:bevel("ShellMidBack", V(0, deck + 1.65, shellBack - 0.2), 4.8, 0.4, 0.7, BACK, UP, "body")
		b:bevel("ShellTopBack", V(0, topY - 0.2, shellBack - 0.8), 4.0, 0.4, 0.4, BACK, UP, "accent")
		for index, at in ipairs({ V(-0.8, 0, 4.35), V(0.8, 0, 4.35), V(0, 0, 5.05) }) do
			b:box("ShellScute" .. index, V(0.9, 0.12, 0.9), CF(at.X, topY + 0.02, at.Z) * A(0, 45, 0), "stripe")
		end
		b:cyl("TurretWell", 0.06, 2.2, CF(0, topY + 0.03, 1.55) * A(0, 0, 90), "mesh")

		-- The tail: the hatch, two jerry cans, lamps in guards, the bumper and the hitch.
		local tailFace = V(0, 0, shellBack)
		b:layer("RearHatch", Vector2.new(2.2, 1.0), tailFace + V(0, deck + 0.6, 0), BACK, 0.08, "accent")
		b:layer("RearHatchHandle", Vector2.new(0.9, 0.12), tailFace + V(0, deck + 0.75, 0), BACK, 0.16, "chrome")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("JerryCan" .. n, V(0.7, 1.0, 0.34), V(s * 1.95, deck + 0.55, shellBack + 0.17), "stripe")
			b:box("JerryCanCap" .. n, V(0.16, 0.14, 0.16), V(s * 1.95 + s * 0.18, deck + 1.12, shellBack + 0.17), "trim")
			b:box("JerryStrap" .. n, V(0.78, 0.1, 0.42), V(s * 1.95, deck + 0.6, shellBack + 0.17), "mesh")
			b:lamp("Tail" .. n, V(s * 2.65, deck - 0.4, tailZ), BACK, Vector2.new(0.5, 0.36), "tail", "redlens")
			b:box("TailGuard" .. n, V(0.7, 0.08, 0.3), V(s * 2.65, deck - 0.1, tailZ + 0.15), "mesh")
		end
		b:box("RearBumper", V(5.8, 0.6, 0.4), V(0, sill + 0.4, tailZ + 0.2), "trim")
		b:plate("PlateRear", V(1.7, 0.42, 0.3), V(0, deck - 0.8, tailZ + 0.12 - 0.15), "TRT 01", Enum.NormalId.Back)
		b:tube("HitchStem", V(0, sill + 0.3, tailZ + 0.4), V(0, sill + 0.3, tailZ + 0.85), 0.2, "trim")
		b:ball("HitchBall", 0.4, V(0, sill + 0.6, tailZ + 0.85), "chrome")

		-- Inside (seen through the blocks): floor, dash, wheel, two seats.
		b:box("CabinPan", V(4.6, 0.2, 3.8), V(0, 2.35, -1.15), "interior")
		b:box("Dash", V(4.6, 0.6, 0.8), V(0, 4.0, -2.8), "dash")
		b:tube("Column", V(-1.2, 4.0, -2.55), V(-1.2, 4.2, -2.2), 0.2, "dash")
		b:steeringWheel("SteeringWheel", V(-1.2, 4.25, -2.1), V(0, 0.45, 0.89).Unit, 0.5)
		b:bucketSeat("SeatDriver", V(-1.2, 2.64, -1.1), 1.8, 1.7, 2.1, 10)
		b:bucketSeat("SeatPassenger", V(1.2, 2.64, -1.1), 1.8, 1.7, 2.1, 10)

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "offroad", spokes = 6, rimScale = 0.56, tread = 16 })
		end

		return {
			seats = {
				driver = CF(-1.2, 2.7, -1.1),
				passengers = { CF(1.2, 2.7, -1.1) },
			},
			exits = { CF(-5.4, 0, -1.1), CF(5.4, 0, -1.1), CF(-5.4, 0, 3.2), CF(5.4, 0, 3.2), CF(0, 0, -9.8), CF(0, 0, 9.6), CF(0, 7.2, 4.2) },
			pose = { name = "CarDriver" },
		}
	end,
}

-- Camelo Carrier: a heavy armoured carrier on big wheels, after Frigo Camelo -- a tall, square,
-- fridge-white box with a camel's face (sleepy lidded eye-lamps, two nostrils over a slatted mouth),
-- two humps on its back (the gunner's open cupola with a grenade machine gun, and a rounded hatch),
-- and a fridge door at the back with the long chrome handle. Up to six ride inside behind armoured
-- glass. The slowest and toughest thing on wheels (VehicleDynamics, VehicleArmor); rarer than the
-- scout car, never parked at the kerb.
VehicleModels.Models.CameloCarrier = {
	kind = "car",
	displayName = "Camelo Carrier",
	weight = 4,
	drivableOnly = true,
	schemes = {
		{ name = "Frigo White", body = Color3.fromRGB(236, 234, 226), accent = Color3.fromRGB(196, 158, 104), stripe = Color3.fromRGB(96, 150, 196), seat = Color3.fromRGB(70, 64, 58), rim = Color3.fromRGB(70, 66, 60) },
		{ name = "Sand Camel", body = Color3.fromRGB(206, 170, 112), accent = Color3.fromRGB(150, 110, 66), stripe = Color3.fromRGB(246, 232, 196), seat = Color3.fromRGB(96, 74, 50), rim = Color3.fromRGB(96, 74, 50) },
		{ name = "Oasis Night", body = Color3.fromRGB(44, 58, 72), accent = Color3.fromRGB(210, 170, 90), stripe = Color3.fromRGB(210, 170, 90), seat = Color3.fromRGB(30, 34, 40), rim = Color3.fromRGB(30, 34, 40) },
		{ name = "Mint Fridge", body = Color3.fromRGB(170, 222, 200), accent = Color3.fromRGB(236, 236, 228), stripe = Color3.fromRGB(230, 110, 120), seat = Color3.fromRGB(60, 70, 66), rim = Color3.fromRGB(236, 236, 228) },
		{ name = "Olive Caravan", body = Color3.fromRGB(104, 112, 72), accent = Color3.fromRGB(70, 62, 44), stripe = Color3.fromRGB(226, 196, 120), seat = Color3.fromRGB(56, 50, 40), rim = Color3.fromRGB(56, 50, 40) },
	},
	build = function(b)
		local HW = 3.5
		local r, tw, track = 1.85, 1.25, 3.2
		local fz, rz = -5.0, 4.5
		local R = 2.2
		local sill, deck = 2.0, 4.4
		local noseZ, tailZ = -7.7, 7.5
		local hoodTop = deck + 0.45
		local screenZ = -4.0
		local roofY = 7.25
		local doorFront, doorBack = fz + R, rz - R
		local FRONT, BACK, UP = V(0, 0, -1), V(0, 0, 1), V(0, 1, 0)

		b:hull("Chassis", V(6.8, 2.6, 15.0), V(0, 3.3, -0.1), 2.6)
		b:hull("Hull_Upper", V(6.6, roofY + 0.2 - deck, tailZ - screenZ), V(0, (deck + roofY + 0.2) / 2, (screenZ + tailZ) / 2), 0.1)

		-- Lower hull, as the scout car's but deeper.
		b:box("NoseBlock", V(2 * HW - 0.2, deck - sill, fz - R - noseZ), V(0, (sill + deck) / 2, (noseZ + fz - R) / 2), "body")
		b:box("TailBlock", V(2 * HW - 0.2, deck - sill, tailZ - rz - R), V(0, (sill + deck) / 2, (rz + R + tailZ) / 2), "body")
		b:box("Belly", V(2 * (HW - 1.6) - 0.1, deck - sill, doorBack - doorFront), V(0, (sill + deck) / 2, (doorFront + doorBack) / 2), "mesh")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("ArmorFlank" .. n, V(0.5, deck - sill, doorBack - doorFront), V(s * (HW - 0.25), (sill + deck) / 2, (doorFront + doorBack) / 2), "body")
			b:archPanel("ArchPanelF" .. n, r, fz, R, deck, s, HW - 1.6, HW, 12, "body")
			b:archPanel("ArchPanelR" .. n, r, rz, R, deck, s, HW - 1.6, HW, 12, "body")
			b:box("WellF" .. n, V(0.1, 2.3, 4.0), V(s * 1.95, 3.0, fz), "mesh")
			b:box("WellR" .. n, V(0.1, 2.3, 4.0), V(s * 1.95, 3.0, rz), "mesh")
			b:archLip("LipF" .. n, r, fz, R, s * (HW + 0.02), 0.6, 0.34, -104, 104, 12, "accent")
			b:archLip("LipR" .. n, r, rz, R, s * (HW + 0.02), 0.6, 0.34, -104, 104, 12, "accent")
			b:bevel("Rocker" .. n, V(s * (HW - 0.17), sill + 0.2, (doorFront + doorBack) / 2), doorBack - doorFront, 0.34, 0.4, V(s, 0, 0), V(0, -1, 0), "accent")
			b:box("SideStep" .. n, V(0.6, 0.14, 2.2), V(s * (HW + 0.3), sill - 0.1, -2.0), "trim")
			b:box("StepBracket" .. n, V(0.5, 0.3, 0.2), V(s * (HW + 0.05), sill + 0.05, -2.0), "trim")
		end

		-- The bonnet, the face and the bumper. The camel: big eye-lamps with heavy lids, two nostrils,
		-- a slatted mouth.
		b:box("Hood", V(2 * HW - 0.4, hoodTop - deck, screenZ - noseZ - 0.3), V(0, (deck + hoodTop) / 2, (noseZ + 0.3 + screenZ) / 2), "body")
		b:bevel("HoodNose", V(0, (deck + hoodTop) / 2, noseZ + 0.15), 2 * HW - 0.4, 0.3, hoodTop - deck, FRONT, UP, "body")
		b:layer("HoodVent", Vector2.new(2.6, 1.6), V(0, hoodTop, -5.3), UP, 0.06, "mesh")
		for index = 1, 5 do
			b:layer("HoodLouvre" .. index, Vector2.new(2.4, 0.08), V(0, hoodTop, -6.2 + index * 0.25), UP, 0.12, "trim")
		end
		local face = V(0, 0, noseZ)
		b:layer("Mouth", Vector2.new(3.6, 0.85), face + V(0, sill + 1.3, 0), FRONT, 0.08, "mesh")
		for index = 1, 7 do
			b:layer("MouthBar" .. index, Vector2.new(0.1, 0.73), face + V(-1.5 + (index - 1) * 0.5, sill + 1.3, 0), FRONT, 0.16, "trim")
		end
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:cylZ("Nostril" .. n, 0.3, 0.52, V(s * 0.7, deck - 0.35, noseZ - 0.1 + 0.15), "mesh")
			b:cylZ("NostrilRim" .. n, 0.3, 0.7, V(s * 0.7, deck - 0.35, noseZ - 0.04 + 0.15), "accent")
			local eye = V(s * 2.3, deck - 0.3, noseZ)
			b:cylZ("EyeHousing" .. n, 0.3, 1.2, eye + V(0, 0, -0.08 + 0.15), "trim")
			b:cylZ("EyeLens" .. n, 0.3, 0.98, eye + V(0, 0, -0.14 + 0.15), "lens")
			b:cylZ("Headlamp" .. n, 0.3, 0.64, eye + V(0, 0, -0.2 + 0.15), "lamp")
			b:wedge("EyeLid" .. n, V(1.4, 0.36, 0.5), CF(eye + V(0, 0.62, -0.1)) * A(0, 0, s * -6), "accent")
			b:layer("Indicator" .. n, Vector2.new(0.36, 0.22), face + V(s * 3.0, deck + 0.2, 0), FRONT, 0.1, "amber")
		end
		b:box("FrontBumper", V(6.8, 1.0, 0.6), V(0, sill + 0.3, noseZ - 0.3), "trim")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:beam("TowHook" .. n, V(s * 2.1, sill + 0.05, noseZ - 0.55), V(s * 2.1, sill + 0.05, noseZ - 0.9), 0.18, 0.3, "tail")
		end
		b:cyl("Winch", 1.7, 0.55, CF(0, sill + 0.05, noseZ - 0.72), "engine")
		b:box("WinchHook", V(0.16, 0.3, 0.12), V(0, sill - 0.25, noseZ - 1.02), "chrome")
		b:plate("PlateFront", V(1.7, 0.42, 0.3), V(0, sill + 0.55, noseZ - 0.6 - 0.12 + 0.15), "CML 22", Enum.NormalId.Front)

		-- The cab's steep armoured screen (two thick panes with a post between), under a visor.
		b:wedge("ArmorScreen", V(6.4, roofY - hoodTop, 0.8), V(0, (hoodTop + roofY) / 2, screenZ + 0.4), "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:slopePlate("ArmorGlass" .. n, hoodTop, screenZ, roofY, screenZ + 0.8, 0.5, s * 1.5, V(2.5, 0.2, 1.5), 0.14, "glass")
			b:slopePlate("ArmorGlassFrame" .. n, hoodTop, screenZ, roofY, screenZ + 0.8, 0.5, s * 1.5, V(2.7, 0.2, 1.7), 0.07, "trim")
		end
		b:slopePlate("ArmorScreenPost", hoodTop, screenZ, roofY, screenZ + 0.8, 0.5, 0, V(0.24, 0.2, 1.7), 0.1, "accent")
		b:bevel("RoofVisor", V(0, roofY + 0.1, screenZ + 0.65), 6.4, 0.3, 0.2, FRONT, UP, "accent")

		-- The box: flanks, roof, the fridge-door back; windows and a band down each side.
		local boxFront = screenZ + 0.8
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			local side = V(s, 0, 0)
			b:box("ArmorSide" .. n, V(0.4, roofY - deck, tailZ - boxFront), V(s * (HW - 0.3), (deck + roofY) / 2, (boxFront + tailZ) / 2), "body")
			b:layer("ArmorDoorGlass" .. n, Vector2.new(1.3, 0.9), V(s * (HW - 0.1), 6.3, -2.4), side, 0.14, "glass")
			b:layer("ArmorDoorFrame" .. n, Vector2.new(1.5, 1.1), V(s * (HW - 0.1), 6.3, -2.4), side, 0.07, "trim")
			for index, z in ipairs({ 1.4, 4.2 }) do
				b:layer(string.format("ArmorPort%s%d", n, index), Vector2.new(0.8, 0.5), V(s * (HW - 0.1), 6.35, z), side, 0.14, "glass")
				b:layer(string.format("ArmorPortFrame%s%d", n, index), Vector2.new(1.0, 0.7), V(s * (HW - 0.1), 6.35, z), side, 0.07, "trim")
			end
			b:layer("DoorSeamFront" .. n, Vector2.new(0.06, 2.6), V(s * (HW - 0.1), 5.75, -3.3), side, 0.03, "mesh")
			b:layer("DoorSeamBack" .. n, Vector2.new(0.06, 2.6), V(s * (HW - 0.1), 5.75, -1.2), side, 0.03, "mesh")
			b:layer("DoorHandle" .. n, Vector2.new(0.5, 0.14), V(s * (HW - 0.1), 5.2, -1.6), side, 0.12, "chrome")
			b:layer("Band" .. n, Vector2.new(tailZ - boxFront - 0.4, 0.22), V(s * (HW - 0.1), 5.0, (boxFront + tailZ) / 2), side, 0.05, "stripe")
			b:plate("SideName" .. n, V(0.3, 0.45, 1.8), V(s * (HW - 0.1 + 0.12 - 0.15), 6.35, 2.8), "CAMELO",
				s < 0 and Enum.NormalId.Left or Enum.NormalId.Right, "accent", "stripe")
			b:box("Stowage" .. n, V(0.6, 0.7, 2.0), V(s * (HW + 0.2), deck + 0.45, rz), "accent")
			b:box("StowageLid" .. n, V(0.66, 0.08, 2.06), V(s * (HW + 0.2), deck + 0.84, rz), "trim")
			b:beam("MirrorArm" .. n, V(s * (HW - 0.1), 6.4, boxFront + 0.3), V(s * (HW + 0.45), 6.55, boxFront + 0.2), 0.2, 0.18, "trim")
			b:box("Mirror" .. n, V(0.3, 0.9, 0.5), V(s * (HW + 0.6), 6.4, boxFront + 0.18), "accent")
			b:layer("MirrorGlass" .. n, Vector2.new(0.18, 0.74), V(s * (HW + 0.6), 6.4, boxFront + 0.43), BACK, 0.08, "chrome")
		end
		b:box("ArmorRoof", V(2 * (HW - 0.1) + 0.14, 0.2, tailZ - boxFront), V(0, roofY + 0.1, (boxFront + tailZ) / 2), "accent")

		-- The back hump: a rounded hatch, stepped in twice, with its handle.
		local humpZ = 4.6
		b:box("HumpLow", V(3.0, 0.45, 2.6), V(0, roofY + 0.2 + 0.225, humpZ), "accent")
		b:box("HumpTop", V(2.0, 0.3, 1.6), V(0, roofY + 0.2 + 0.45 + 0.15, humpZ), "accent")
		for _, e in ipairs({ { "L", V(-1, 0, 0) }, { "R", V(1, 0, 0) }, { "F", FRONT }, { "B", BACK } }) do
			local out = e[2]
			local lowLen = math.abs(out.X) > 0.5 and 2.6 or 3.0
			local topLen = math.abs(out.X) > 0.5 and 1.6 or 2.0
			local lowOff = math.abs(out.X) > 0.5 and 1.5 + 0.2 or 1.3 + 0.2
			local topOff = math.abs(out.X) > 0.5 and 1.0 + 0.2 or 0.8 + 0.2
			b:bevel("HumpLowEdge" .. e[1], V(0, roofY + 0.425, humpZ) + out * lowOff, lowLen, 0.4, 0.45, out, UP, "accent")
			b:bevel("HumpTopEdge" .. e[1], V(0, roofY + 0.8, humpZ) + out * topOff, topLen, 0.4, 0.3, out, UP, "accent")
		end
		b:box("HumpHandle", V(0.7, 0.1, 0.12), V(0, roofY + 1.0, humpZ + 0.3), "chrome")
		b:cyl("TurretWell", 0.06, 2.5, CF(0, roofY + 0.23, -1.2) * A(0, 0, 90), "mesh")

		-- The back: a fridge's door, long chrome handle and all, lamps, steps, the hitch.
		b:box("ArmorRear", V(2 * (HW - 0.5), roofY - deck, 0.3), V(0, (deck + roofY) / 2, tailZ - 0.15), "body")
		b:layer("FridgeSeal", Vector2.new(3.0, 2.7), V(0, 5.75, tailZ), BACK, 0.07, "trim")
		b:layer("FridgeDoor", Vector2.new(2.8, 2.5), V(0, 5.75, tailZ), BACK, 0.14, "body")
		b:box("FridgeHandle", V(0.14, 1.6, 0.12), V(1.05, 5.75, tailZ + 0.34), "chrome")
		for _, y in ipairs({ 5.1, 6.4 }) do
			b:cylZ(y < 6 and "FridgeHandleFootLow" or "FridgeHandleFootHigh", 0.3, 0.1, V(1.05, y, tailZ + 0.14), "chrome")
		end
		b:plate("FridgeBadge", V(1.6, 0.4, 0.3), V(-0.4, 6.6, tailZ + 0.21 - 0.15), "FRIGO", Enum.NormalId.Back, "stripe", "body")
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:lamp("Tail" .. n, V(s * 2.9, deck + 0.3, tailZ), BACK, Vector2.new(0.46, 0.9), "tail", "redlens")
		end
		b:box("RearBumper", V(6.6, 0.6, 0.5), V(0, sill + 0.3, tailZ + 0.25), "trim")
		b:box("RearStep", V(2.4, 0.12, 0.5), V(0, sill + 0.66, tailZ + 0.3), "chrome")
		b:plate("PlateRear", V(1.7, 0.42, 0.3), V(0, deck - 0.5, tailZ + 0.12 - 0.15), "CML 22", Enum.NormalId.Back)
		b:tube("HitchStem", V(0, sill + 0.2, tailZ + 0.5), V(0, sill + 0.2, tailZ + 0.95), 0.22, "trim")
		b:ball("HitchBall", 0.44, V(0, sill + 0.52, tailZ + 0.95), "chrome")

		-- Inside: floor, dash, wheel, the two up front and benches down both sides of the box.
		b:box("CabinPan", V(5.6, 0.2, tailZ - 0.4 - screenZ), V(0, 2.6, (screenZ + tailZ - 0.4) / 2), "interior")
		b:box("Dash", V(5.8, 0.7, 0.8), V(0, 4.6, -3.45), "dash")
		b:tube("Column", V(-1.4, 4.7, -3.2), V(-1.4, 4.95, -2.8), 0.22, "dash")
		b:steeringWheel("SteeringWheel", V(-1.4, 5.0, -2.7), V(0, 0.5, 0.87).Unit, 0.56)
		b:bucketSeat("SeatDriver", V(-1.4, 3.2, -1.9), 1.9, 1.8, 2.2, 10)
		b:bucketSeat("SeatPassenger", V(1.4, 3.2, -1.9), 1.9, 1.8, 2.2, 10)
		for _, s in ipairs({ -1, 1 }) do
			local n = s < 0 and "L" or "R"
			b:box("Bench" .. n, V(0.9, 0.45, 4.2), V(s * 2.2, 3.4, 3.7), "seat")
			b:box("BenchBack" .. n, V(0.3, 1.6, 4.2), V(s * 2.75, 4.4, 3.7), "seat")
		end

		for _, w in ipairs({ { "Wheel_FL", -1, fz, true }, { "Wheel_FR", 1, fz, true }, { "Wheel_RL", -1, rz, false }, { "Wheel_RR", 1, rz, false } }) do
			b:roadWheel(w[1], V(w[2] * track, r, w[3]), r, tw, w[2], { steer = w[4], style = "offroad", spokes = 8, rimScale = 0.54, tread = 18 })
		end

		return {
			seats = {
				driver = CF(-1.4, 3.26, -1.9),
				passengers = { CF(1.4, 3.26, -1.9), CF(-2.2, 3.7, 2.6) * A(0, -90, 0), CF(2.2, 3.7, 2.6) * A(0, 90, 0),
					CF(-2.2, 3.7, 4.8) * A(0, -90, 0), CF(2.2, 3.7, 4.8) * A(0, 90, 0) },
			},
			exits = { CF(-5.9, 0, -1.9), CF(5.9, 0, -1.9), CF(-5.9, 0, 3.6), CF(5.9, 0, 3.6), CF(0, 0, -10.6), CF(0, 0, 10.4), CF(0, 8.8, 2.6) },
			pose = { name = "CarDriver" },
		}
	end,
}

--------------------------------------------------------------------------------
-- Mounted weapons (Oliver: "vehicles with different guns and explosive weapons on them")
--------------------------------------------------------------------------------
-- What each armed model's weapons DO lives in Shared/VehicleWeaponData; this is only the metal.
--
-- An armed model carries two weapons (Oliver 09-24: "make the car guns controllable by a gunner seat"
-- and "make the drivers have their own gun that they can control"):
--   the TURRET (VehicleModels.Mounts), worked from the GunnerSeat, named Turret*
--   the DRIVER'S GUN (VehicleModels.DriverMounts), a short-arc gun at the front, fired from the wheel,
--     named DriverGun*
-- Every mount keeps the same contract, so VehicleWeapons and VehicleWeaponClient never guess (the
-- names below are the turret's; a driver's gun is DriverGunYaw / DriverGunPitch / DriverGunMuzzle):
--   TurretYaw     pivot (Pivot "TurretYaw") on the chassis; turns about its own Y
--   TurretPitch   pivot (Pivot "TurretPitch") hung from TurretYaw, square to it and anywhere in its
--                 YZ plane -- straight above it (a pedestal, a plinth) or out in front on a pintle arm
--                 (the Rotster's hatch ring, where the gunner stands on the yaw axis); tips about its
--                 own X, positive is up
--   TurretMuzzle  invisible marker welded to TurretPitch at the mouth, on the pitch pivot's YZ plane
-- Both pivots are built square to the chassis and facing the front (-Z), so a Transform of
-- CFrame.Angles(0, yaw, 0) and CFrame.Angles(pitch, 0, 0) is the whole of aiming, and because the
-- barrel's vertical plane always holds the yaw axis, VehicleWeaponData.Solve finds both angles exactly.
-- A ring bearing (the hatch ring) has nothing on its axis, so its yaw pivot carries RingRadius: the
-- ring it turns on (tools/vehicle_models_runtime_check.py tests that circle instead of the axis line).
--
-- The gunner's markers (Attachments), read by VehicleWeaponClient's first-person view and by
-- VehicleClient's third-person pose:
--   on TurretYaw     GunnerEye     the gunner's eye, facing -Z: where the camera sits in first person
--                                  (it rides the turret round; the gunner's body turns with it)
--   on TurretPitch   GunnerSight   the eye behind the sight, looking along the bore (aiming down it)
--                    GripR, GripL  the palms on the handles (-Z along the fingers, +Y out of the back
--                                  of the hand, the gun keypoints' own convention)
--   on either        ReloadHand    where the right hand goes to load
-- TurretYaw's attribute Stance ("stand" or "kneel") says how the gunner is posed.
-- Two-wheelers carry none; an unarmed build (a parked prop) carries neither mount.

VehicleModels.Mounts = {
	-- A machine gun on a ring round the roof hatch, on a pintle arm out in front of the gunner, who
	-- stands in the hatch and turns with the ring (a Humvee's gun, on a hot hatch).
	Rotster = { style = "ring", base = V(0, 6.0, 2.4) },
	-- A four-tube rocket launcher on a pedestal bolted to the middle of the bed floor, the gunner on a
	-- platform that turns with it. It used to sit on a ring clamped over the roll bar (Oliver 09-24:
	-- "the ranger car's gun is floating in the air"; "put the gun in the truck bed on a mount").
	CrocodiloRanger = { style = "pedestal", base = V(0, 3.1, 4.55) },
	-- A mortar on a plinth at the back of the roof rack, between the last rack bar and the rail ends.
	-- The plinth is 0.9 tall so the tube clears the bat and the drum wherever it points: on a 0.4
	-- plinth, swung 30-40 degrees left at its lowest pitch (10) it went straight through the bat's
	-- barrel and end cap, and 20-60 degrees right through the drum (0.8 still clips a drumstick).
	-- Measured over the whole arc by tools/vehicle_models_axis_check.py.
	SahurVan = { style = "mortar", base = V(0, 7.8, 5.2), column = 0.9 },
	-- The armoured cars' turrets (their bodies are further up): a heavy machine gun behind a shield on
	-- the scout car's ring, and a grenade machine gun in the carrier's one-man turret.
	TartarugaScout = { style = "shielded", base = V(0, 6.0, 1.55) },
	CameloCarrier = { style = "agl", base = V(0, 7.45, -1.2) },
}

-- The driver's own gun on each armed model: fixed forward, a short arc either side, aimed with the
-- mouse from the wheel. In a cowl on the Rotster's bonnet bulge, in a cowl at the front of the Ranger's
-- bonnet deck (between the first pair of scutes, the barrel out over the bull bar and between its spot
-- lamps), on top of the van's bumper, in a ball mount in the scout car's glacis, and in a cowl at the
-- front of the carrier's bonnet. Every muzzle stays inside the body's own length: the Ranger's used to
-- ride on the bull bar and stuck 1.6 studs out past the winch, which made the truck longer than every
-- parking bay and team-base bay is laid out for (tools/car_placement_check.py, team_base_ruins_check.py).
VehicleModels.DriverMounts = {
	Rotster = { style = "cowl", base = V(0, 3.52, -4.6), depth = 1.1, length = 1.8 },
	CrocodiloRanger = { style = "cowl", base = V(0, 4.35, -7.05), depth = 1.1, length = 1.7 },
	SahurVan = { style = "cowl", base = V(0, 1.8, -7.15), depth = 0.55, length = 1.7 },
	TartarugaScout = { style = "ball", base = V(1.1, 4.41, -5.52), normal = V(0, 3.6, -1.1) },
	CameloCarrier = { style = "cowl", base = V(0, 4.85, -7.2), depth = 1.1, length = 1.8 },
}

-- Each armed model's gun seat, model space (Oliver, 2026-09-24: "make the bots not drive away if they
-- have a gun on their car, wait till it's manned"). VehicleService makes it a Seat named GunnerSeat
-- with a true Gunner attribute, and whoever sits there works the turret (VehicleWeapons;
-- VehicleWeaponClient reads the same name and attribute). It is placed so the rider's eye lands on the
-- mount's GunnerEye with the rider posed as its Stance says (VehicleModels.Poses.GunnerStand /
-- GunnerKneel): measured in Studio, a seated R15 rider's root sits RIDER_ROOT above the seat's centre,
-- and a standing one's eye EYE_ABOVE_ROOT above its root (tools/gunner_fp_gallery.lua prints both).
-- A seat is an invisible, non-colliding part welded to the chassis; nothing about the metal changes.
VehicleModels.GunnerSeats = {}

-- A rider's root above its seat's centre, and a posed gunner's eye above its root. Measured in Studio
-- (tools/gunner_fp_gallery.lua, 09-24): a standing R15 posed GunnerStand has its eyes 1.7 over its root;
-- kneeling (GunnerKneel) 1.6 -- the root is the hips, which kneeling does not lower, the shins fold back.
-- (Its eyes also sit 0.7 / 0.9 in front of where the seat puts the eye: the first-person camera stays on
-- the mount's GunnerEye, a little behind the head, which nobody can see.)
local RIDER_ROOT = 1.65
local EYE_ABOVE_ROOT = { stand = 1.7, kneel = 1.6 }

--------------------------------------------------------------------------------
-- Weapon pieces (built in a pitch pivot's frame at rest: front -Z, up +Y)
--------------------------------------------------------------------------------

local function mark(pivot, name, frame)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.CFrame = pivot.CFrame:ToObjectSpace(frame)
	attachment.Parent = pivot
	return attachment
end

-- A palm frame from where it is, the way the fingers point and the way the back of the hand faces:
-- the convention of the gun keypoints (GunModels' Builder:hand) and of the viewmodel arms.
local function palm(position, fingers, back)
	local z = -fingers.Unit
	local x = back.Unit:Cross(z).Unit
	return CFrame.fromMatrix(position, x, z:Cross(x).Unit, z)
end

-- A reflex sight, in a weapon's own frame through P (P(x, y, z) is a point on the weapon, already
-- scaled): an open window of w x h centred on (cx, cy, cz), which is on the line from the GunnerSight
-- marker straight down the bore's way, so the lit dot in the middle of the glass sits on the middle of the
-- view and on the impact ring GunnerView draws (the bore runs parallel, a hand's width below: the two
-- meet on the screen at range). A base clamped to the gun, a post either side, a hood over the top with
-- a sunshade lip, the glass leaning back a touch, the dot, and `ticks` ranging marks under it for a gun
-- whose round drops. For such a gun `drop` makes the window that much deeper below the dot, where
-- GunnerView's view goes down to the landing point, with the ticks spread down it (the dot is point
-- blank, each tick further out). `fine` draws a thin frame, a pin-prick dot and hairline ticks on the
-- glass itself (a sight set close to the eye, where the ordinary ones fill the view). Every piece
-- starts with `name`.
local function reflexSight(b, name, P, s, cx, cy, cz, w, h, ticks, drop, fine)
	drop = drop or 0
	cy = cy - drop / 2
	h = h + drop
	local dotY = cy + drop / 2
	local t = fine and 0.025 or 0.05
	b:box(name .. "SightBase", V(w + 2 * t + 0.04, 0.06, 0.34) * s, P(cx, cy - h / 2 - t - 0.03, cz + 0.02), "trim")
	b:box(name .. "SightClamp", V(0.14, 0.08, 0.2) * s, P(cx, cy - h / 2 - t - 0.1, cz + 0.02), "mesh")
	b:box(name .. "SightKnob", V(0.06, 0.06, 0.06) * s, P(cx + w / 2 + t + 0.03, cy - h / 2 - t - 0.03, cz + 0.1), "chrome")
	for _, x in ipairs({ -1, 1 }) do
		b:box(name .. (x < 0 and "SightPostL" or "SightPostR"), V(t, h + t, 0.26) * s, P(cx + x * (w / 2 + t / 2), cy - t / 2, cz), "trim")
	end
	b:box(name .. "SightHood", V(w + 2 * t, t, 0.34) * s, P(cx, cy + h / 2 + t / 2, cz - 0.02), "engine")
	b:box(name .. "SightLip", V(w + 2 * t, 0.04, 0.12) * s, P(cx, cy + h / 2 + 0.02, cz - 0.22), "trim")
	b:box(name .. "SightGlass", V(w, h, 0.02) * s, CF(P(cx, cy, cz - 0.08)) * A(-6, 0, 0), "sightglass")
	local onGlass = fine and cz - 0.09 or cz - 0.1
	b:ball(name .. "SightDot", (fine and 0.014 or 0.036) * s, P(cx, dotY, onGlass), "reticle")
	local step = drop > 0 and drop / ((ticks or 0) + 1) or 0.045
	for index = 1, ticks or 0 do
		local size = fine and V(0.036 - index * 0.006, 0.005, 0.005) or V(0.08 - index * 0.012, 0.014, 0.014)
		b:box(name .. "SightTick" .. index, size * s, P(cx, dotY - step * index, onGlass), "ticks")
	end
end

-- Brass rounds lying across a belt, `count` of them from `a` to `c` (points already through P).
local function beltRounds(b, name, a, c, count, s)
	for index = 1, count do
		local at = a + (c - a) * ((index - 0.5) / count)
		b:cyl(name .. index, 0.22 * s, 0.07 * s, CF(at) * A(0, 90, 0), "gold")
	end
end

-- A belt-fed machine gun round `at`, the trunnion it tips on, at scale `s`. What one is made of, from
-- the back: spade grips with the butterfly trigger between them on the backplate; the receiver and
-- its hinged top cover, with the belt running into the feed tray from the ammo box on the left and the
-- charging handle on the right; the barrel support, the ventilated jacket, the barrel, the flash hider;
-- and iron sights -- a leaf at the back and a post at the front -- on one line 0.43 above the bore and
-- parallel to it, so looking along them is looking along the barrel. The cradle round the receiver's
-- belly carries the trunnion pin. opts.grips/opts.ammo leave those off a driver's gun, which is worked
-- from the wheel. Returns the muzzle's distance ahead of `at` and the frames the gunner's markers use.
local function machineGun(b, name, at, s, opts)
	opts = opts or {}
	local function P(x, y, z)
		return at + V(x, y, z) * s
	end
	local bore = 0.12
	b:box(name .. "Receiver", V(0.4, 0.44, 1.3) * s, P(0, 0.12, 0.05), "trim")
	b:box(name .. "TopCover", V(0.52, 0.08, 0.78) * s, P(0, 0.37, 0.12), "engine")
	b:cyl(name .. "CoverHinge", 0.64 * s, 0.1 * s, CF(P(0, 0.37, -0.29)), "mesh")
	b:box(name .. "Support", V(0.34, 0.3, 0.3) * s, P(0, 0.12, -0.72), "trim")
	b:tube(name .. "Jacket", P(0, bore, -0.84), P(0, bore, -1.86), 0.3 * s, "trim")
	for index, z in ipairs({ -1.08, -1.36, -1.64 }) do
		b:tube(name .. "JacketBand" .. index, P(0, bore, z - 0.04), P(0, bore, z + 0.04), 0.36 * s, "mesh")
	end
	b:tube(name .. "Barrel", P(0, bore, -1.8), P(0, bore, -2.7), 0.15 * s, "mesh")
	b:tube(name .. "FlashHider", P(0, bore, -2.62), P(0, bore, -2.96), 0.24 * s, "trim")
	b:tube(name .. "FlashBore", P(0, bore, -2.9), P(0, bore, -3.02), 0.14 * s, "mesh")
	-- The sight: a reflex sight on the top cover, its dot 0.55 up (the bore is at 0.12), on the line
	-- from the GunnerSight marker. A slotted heat shield over the jacket, below that line.
	reflexSight(b, name, P, s, 0, 0.55, -0.3, 0.3, 0.22)
	b:box(name .. "HeatShield", V(0.3, 0.03, 0.86) * s, P(0, 0.3, -1.35), "engine")
	for index = 1, 4 do
		b:box(name .. "HeatShieldSlot" .. index, V(0.18, 0.035, 0.08) * s, P(0, 0.3, -1.05 - index * 0.13), "mesh")
	end
	b:box(name .. "HeatShieldFoot", V(0.12, 0.08, 0.1) * s, P(0, 0.25, -0.98), "trim")
	-- A carrying handle on the jacket's right, for the barrel change; rivets on the receiver's sides.
	b:box(name .. "CarryBracket", V(0.1, 0.08, 0.14) * s, P(0.2, 0.16, -1.2), "trim")
	b:tube(name .. "CarryHandle", P(0.3, 0.02, -1.2), P(0.3, 0.34, -1.2), 0.08 * s, "rubber")
	for _, x in ipairs({ -1, 1 }) do
		for index, z in ipairs({ -0.35, 0.05, 0.45 }) do
			b:cyl(string.format("%sRivet%s%d", name, x < 0 and "L" or "R", index), 0.03 * s, 0.07 * s, CF(P(x * 0.205, 0.24, z)), "chrome")
		end
	end
	-- The cradle under the receiver, with the pin through its cheeks.
	b:box(name .. "Cradle", V(0.42, 0.07, 0.6) * s, P(0, -0.135, 0.02), "mesh")
	for _, x in ipairs({ -1, 1 }) do
		b:box(string.format("%sCradle%s", name, x < 0 and "L" or "R"), V(0.06, 0.3, 0.52) * s, P(x * 0.24, -0.01, 0.02), "mesh")
	end
	b:box(name .. "ChargingHandle", V(0.1, 0.08, 0.22) * s, P(0.24, 0.16, -0.2), "chrome")
	b:ball(name .. "ChargingKnob", 0.12 * s, P(0.31, 0.16, -0.26), "rubber")
	local frames = {}
	if opts.grips ~= false then
		b:box(name .. "Backplate", V(0.52, 0.56, 0.1) * s, P(0, 0.12, 0.74), "trim")
		for _, x in ipairs({ -1, 1 }) do
			local n = x < 0 and "L" or "R"
			b:tube(name .. "GripArmTop" .. n, P(x * 0.21, 0.32, 0.76), P(x * 0.21, 0.32, 1.04), 0.07 * s, "trim")
			b:tube(name .. "GripArmLow" .. n, P(x * 0.21, -0.06, 0.76), P(x * 0.21, -0.06, 1.0), 0.07 * s, "trim")
			b:tube(name .. "Grip" .. n, P(x * 0.21, -0.09, 1.0), P(x * 0.21, 0.35, 1.04), 0.14 * s, "rubber")
		end
		b:box(name .. "TriggerStem", V(0.06, 0.06, 0.12) * s, P(0, 0.14, 0.84), "trim")
		b:box(name .. "Trigger", V(0.24, 0.1, 0.05) * s, P(0, 0.14, 0.91), "gold")
		-- Both hands round the spade grips, thumbs on the trigger between them.
		frames.GripR = palm(P(0.21, 0.13, 1.02), V(-0.35, 0, -1), V(1, 0.15, 0.3))
		frames.GripL = palm(P(-0.21, 0.13, 1.02), V(0.35, 0, -1), V(-1, 0.15, 0.3))
	end
	if opts.ammo ~= false then
		b:box(name .. "AmmoBracket", V(0.14, 0.18, 0.36) * s, P(-0.26, 0.06, 0.1), "mesh")
		b:box(name .. "AmmoBox", V(0.36, 0.44, 0.62) * s, P(-0.51, 0.0, 0.1), "accent")
		b:box(name .. "AmmoLid", V(0.4, 0.06, 0.66) * s, P(-0.51, 0.24, 0.1), "trim")
		b:box(name .. "AmmoHandle", V(0.06, 0.06, 0.3) * s, P(-0.51, 0.3, 0.1), "rubber")
		b:beam(name .. "Belt", P(-0.44, 0.27, 0.1), P(-0.19, 0.33, 0.1), 0.16 * s, 0.05 * s, "gold")
		beltRounds(b, name .. "BeltRound", P(-0.44, 0.3, 0.1), P(-0.2, 0.36, 0.1), 3, s)
		b:box(name .. "AmmoLatch", V(0.04, 0.12, 0.1) * s, P(-0.71, 0.18, 0.1), "chrome")
		b:box(name .. "AmmoStencil", V(0.37, 0.08, 0.5) * s, P(-0.51, -0.08, 0.1), "stripe")
		frames.ReloadHand = palm(P(-0.3, 0.44, 0.08), V(0.2, -0.3, -1), V(0.1, 1, 0))
	end
	frames.Sight = CF(P(0, 0.55, 1.05))
	return 3.02 * s, frames
end

-- A trunnion pin along X through `at`, `span` wide: what a pitching weapon hangs on.
local function trunnion(b, name, at, span, diameter)
	b:cyl(name, span, diameter, CF(at), "chrome")
end

--------------------------------------------------------------------------------
-- Turret styles. Each builds its fixed base on the chassis, its yaw pivot, its pitch pivot and the
-- weapon, and returns yaw, pitch, muzzle position, markers { name = { pivot, frame } }, stance.
--------------------------------------------------------------------------------

local MountStyles = {}

-- The Rotster's hatch ring. The roof has a 2.2-stud square hole at `base` (see the Rotster); a square
-- coaming stands round it, a ring bearing (RingRadius 1.38) turns on the coaming, and a pintle arm
-- carries the gun 1.75 in front of the ring's centre, where the gunner stands. The gun's pivot is high
-- enough (0.78 over the ring) that with the gun turned right round and tipped to its lowest the
-- ammo box and cradle still clear the ring, and over the rear the barrel clears the spoiler.
function MountStyles.ring(b, mount, names)
	local base = mount.base
	local half = 1.1
	local coamingTop = base.Y + 0.2
	for _, e in ipairs({ { "F", V(0, 0, -1) }, { "B", V(0, 0, 1) }, { "L", V(-1, 0, 0) }, { "R", V(1, 0, 0) } }) do
		local out = e[2]
		local along = math.abs(out.X) > 0.5 and V(0.26, 0.2, 2 * half) or V(2 * half, 0.2, 0.26)
		b:box("TurretCoaming" .. e[1], along, base + out * (half + 0.13) + V(0, 0.1, 0), "trim")
	end
	for _, x in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do
			b:box(string.format("TurretCoamingCorner%s%s", x < 0 and "L" or "R", z < 0 and "F" or "B"), V(0.38, 0.14, 0.38),
				base + V(x * (half + 0.13), 0.07, z * (half + 0.13)), "trim")
		end
	end
	local yawAt = V(base.X, coamingTop, base.Z)
	local yaw = b:pivot(names.yaw, CF(yawAt), "TurretYaw", nil, { RingRadius = 1.38 })
	local reach = 1.75
	local pitchAt = yawAt + V(0, 0.58, -reach)
	local pitch = b:pivot(names.pitch, CF(pitchAt), "TurretPitch", yaw)
	b:with(yaw, function()
		b:ring("TurretRing", CF(yawAt + V(0, 0.07, 0)) * A(0, 0, 90), 1.24, 0.28, 0.14, 12, "accent")
		-- The pintle: a socket plate bolted across the ring's front, reaching out under the gun, and a
		-- fork either side of the cradle for the pin.
		-- It stops short of the ring's middle: at full elevation (25) the receiver's back end comes down
		-- to 0.19 over the ring, just behind it.
		b:box("TurretPintleSocket", V(0.46, 0.08, 0.57), yawAt + V(0, 0.18, -reach + 0.085), "trim")
		for _, x in ipairs({ -1, 1 }) do
			b:box(x < 0 and "TurretForkL" or "TurretForkR", V(0.06, 0.44, 0.3), pitchAt + V(x * 0.3, -0.14, 0), "trim")
		end
		-- The pintle post the fork turns on, its spring collar, and the ring's rollers and lock lever.
		b:cyl("TurretPintlePost", 0.16, 0.22, CF(yawAt + V(0, 0.3, -reach + 0.05)) * A(0, 0, 90), "chrome")
		b:cyl("TurretPintleCollar", 0.06, 0.3, CF(yawAt + V(0, 0.25, -reach + 0.05)) * A(0, 0, 90), "trim")
		for index = 1, 6 do
			local a = rad(30 + (index - 1) * 60)
			b:cyl("TurretRoller" .. index, 0.1, 0.14, CF(yawAt + V(math.sin(a) * 1.38, 0.2, math.cos(a) * 1.38)) * A(0, 0, 90), "chrome")
		end
		b:box("TurretLockLever", V(0.08, 0.06, 0.34), yawAt + V(0.9, 0.2, 0.9), "rubber")
	end)
	local muzzleZ, frames
	b:with(pitch, function()
		trunnion(b, "TurretTrunnion", pitchAt, 0.8, 0.12)
		muzzleZ, frames = machineGun(b, "Gun", pitchAt, 1, {})
	end)
	return yaw, pitch, pitchAt + V(0, 0.12, -muzzleZ), {
		GunnerEye = { yaw, CF(yawAt + V(0, 1.13, 0.25)) },
		GunnerSight = { pitch, frames.Sight },
		GripR = { pitch, frames.GripR },
		GripL = { pitch, frames.GripL },
		ReloadHand = { pitch, frames.ReloadHand },
	}, "stand"
end

-- The Ranger's pedestal: a base plate bolted to the bed floor with a socket and a bearing race; above
-- the race everything turns -- the collar, the gunner's platform on two arms off it, the column, the
-- yoke with its rounded arms, a rack of two spare rockets on the left arm -- and the launcher tips on
-- the pins through the yoke. The launcher is a box of four tubes (mouths and bores at the front,
-- breech caps at the back), banded twice, with a side sight on the left and a handle on each side.
-- The pin is at 7.7: every rocket leaving over the cab (with the front arc's floor, VehicleWeaponData
-- RangerRocketPod.frontGuard) clears the roof, the light bar and the roll bar; and the launcher never
-- reaches the roll bar at all (its front corner stays 1.71 from the pin, which stands 1.74 behind it).
-- The gunner stands a stud behind the pin: turned to either side, that keeps them inside the bed's
-- 4-stud floor between the wheel tubs.
function MountStyles.pedestal(b, mount, names)
	local base = mount.base
	local floorY = base.Y
	b:box("TurretBasePlate", V(1.7, 0.14, 1.7), base + V(0, 0.07, 0), "trim")
	for index = 1, 8 do
		local a = rad((index - 0.5) * 45)
		b:cyl("TurretBaseBolt" .. index, 0.12, 0.17, CF(base + V(math.cos(a) * 0.7, 0.19, math.sin(a) * 0.7)) * A(0, 0, 90), "chrome")
	end
	b:cyl("TurretSocket", 0.3, 1.0, CF(base + V(0, 0.29, 0)) * A(0, 0, 90), "trim")
	for index = 1, 4 do
		local a = rad(45 + (index - 1) * 90)
		local out = V(math.cos(a), 0, math.sin(a))
		local at = base + out * 0.66 + V(0, 0.28, 0)
		b:wedge("TurretGusset" .. index, V(0.1, 0.28, 0.32), CFrame.lookAt(at, at + out), "trim")
	end
	b:cyl("TurretRace", 0.08, 1.12, CF(base + V(0, 0.48, 0)) * A(0, 0, 90), "chrome")
	local yawAt = base + V(0, 0.52, 0)
	local pitchY = 7.7
	local pitchAt = V(base.X, pitchY, base.Z)
	local yaw = b:pivot(names.yaw, CF(yawAt), "TurretYaw")
	local pitch = b:pivot(names.pitch, CF(pitchAt), "TurretPitch", yaw)
	local yokeY = pitchY - 1.02
	b:with(yaw, function()
		b:cyl("TurretCollar", 0.3, 0.96, CF(yawAt + V(0, 0.15, 0)) * A(0, 0, 90), "accent")
		b:cyl("TurretColumn", yokeY - (yawAt.Y + 0.3), 0.72, CF(V(base.X, (yawAt.Y + 0.3 + yokeY) / 2, base.Z)) * A(0, 0, 90), "accent")
		for index, y in ipairs({ yawAt.Y + 1.25, yokeY - 0.55 }) do
			b:cyl("TurretClamp" .. index, 0.12, 0.84, CF(V(base.X, y, base.Z)) * A(0, 0, 90), "trim")
		end
		-- The gunner's platform, nearly a stud over the bed floor on two arms off the column: high enough
		-- that a standing gunner's eye clears the top of the pod (at half a stud over the floor it sat level
		-- with the pod's top edge and the pod filled the lower third of the first-person view).
		local stepY = floorY + 0.98
		b:box("TurretStep", V(1.6, 0.12, 0.9), V(base.X, stepY, base.Z + 1.05), "mesh")
		for _, x in ipairs({ -1, 1 }) do
			b:beam(x < 0 and "TurretStepArmL" or "TurretStepArmR", V(base.X + x * 0.3, stepY + 0.11, base.Z + 0.3),
				V(base.X + x * 0.3, stepY + 0.11, base.Z + 0.6), 0.1, 0.1, "trim")
			b:box(x < 0 and "TurretStepRibL" or "TurretStepRibR", V(0.08, 0.04, 0.78), V(base.X + x * 0.4, stepY + 0.08, base.Z + 1.05), "trim")
		end
		-- The yoke: a base across the column's top and two arms, rounded where the pins go through.
		b:box("TurretYokeBase", V(2.6, 0.2, 0.7), V(base.X, yokeY + 0.1, base.Z), "accent")
		for _, x in ipairs({ -1, 1 }) do
			local n = x < 0 and "L" or "R"
			-- The rounded top is a boss standing 0.06 proud of the arm either side, where the pin goes through.
			b:box("TurretYokeArm" .. n, V(0.14, pitchY - yokeY - 0.2, 0.62), V(base.X + x * 1.0, (yokeY + 0.2 + pitchY) / 2, base.Z), "accent")
			b:cyl("TurretYokeEye" .. n, 0.26, 0.62, CF(V(base.X + x * 1.0, pitchY, base.Z)), "accent")
		end
		-- Two spare rockets racked on the left arm (the reload comes from here).
		local rackX = base.X - 1.1
		b:box("TurretRackPlate", V(0.06, 0.56, 0.96), V(rackX, pitchY - 0.62, base.Z), "trim")
		for index, y in ipairs({ pitchY - 0.8, pitchY - 0.46 }) do
			local x = rackX - 0.03 - 0.14
			b:tube("TurretSpareRocket" .. index, V(x, y, base.Z + 0.5), V(x, y, base.Z - 0.42), 0.28, "stripe")
			b:ball("TurretSpareWarhead" .. index, 0.3, V(x, y, base.Z - 0.46), "trim")
			b:box("TurretSpareFins" .. index, V(0.3, 0.06, 0.2), V(rackX - 0.03 - 0.15, y, base.Z + 0.44), "mesh")
		end
		for index, z in ipairs({ -0.22, 0.28 }) do
			b:box("TurretRackStrap" .. index, V(0.31, 0.76, 0.08), V(rackX - 0.03 - 0.155, pitchY - 0.62, base.Z + z), "mesh")
		end
	end)
	local frames = {}
	b:with(pitch, function()
		local function P(x, y, z)
			return pitchAt + V(x, y, z)
		end
		trunnion(b, "TurretTrunnion", pitchAt, 2.28, 0.2)
		b:box("PodCasing", V(1.2, 1.06, 1.88), P(0, 0, -0.6), "accent")
		b:box("PodFrontFrame", V(1.3, 1.16, 0.12), P(0, 0, -1.56), "trim")
		b:box("PodRearFrame", V(1.3, 1.16, 0.12), P(0, 0, 0.34), "trim")
		for index, z in ipairs({ -1.02, -0.2 }) do
			b:box("PodBand" .. index, V(1.32, 1.18, 0.12), P(0, 0, z), "stripe")
		end
		for row = 0, 1 do
			for col = 0, 1 do
				local x, y = (col - 0.5) * 0.56, (row - 0.5) * 0.5
				b:cylZ(string.format("PodMouth%d%d", row, col), 0.3, 0.46, P(x, y, -1.57), "trim")
				b:cylZ(string.format("PodBore%d%d", row, col), 0.2, 0.3, P(x, y, -1.68), "mesh")
				b:cylZ(string.format("PodBreech%d%d", row, col), 0.3, 0.36, P(x, y, 0.49), "trim")
			end
		end
		for _, x in ipairs({ -1, 1 }) do
			local n = x < 0 and "L" or "R"
			b:cyl("PodLug" .. n, 0.14, 0.36, CF(P(x * 0.67, 0, 0)), "trim")
			-- A handle on each side, just ahead of the pins' bosses and clear of them by 0.06.
			b:beam("PodHandleArm" .. n, P(x * 0.6, 0.3, 0.1), P(x * 0.74, 0.3, 0.1), 0.08, 0.08, "trim")
			b:tube("PodHandle" .. n, P(x * 0.74, 0.1, 0.11), P(x * 0.74, 0.46, 0.09), 0.14, "rubber")
		end
		b:box("PodTrigger", V(0.05, 0.12, 0.06), P(0.74, 0.3, 0.01), "gold")
		-- The sight on the left side, forward of the bosses: a bracket, the body, the objective at the
		-- front and the eyepiece's rubber cup at the back.
		b:box("PodSightBracket", V(0.1, 0.12, 0.3), P(-0.65, 0.28, -0.8), "mesh")
		reflexSight(b, "Pod", P, 1, -0.78, 0.32, -0.8, 0.26, 0.22, 2)
		b:box("PodFuzeBox", V(0.3, 0.16, 0.3), P(0.3, 0.61, 0.05), "mesh")
		b:beam("PodFuzeCable", P(0.3, 0.6, 0.2), P(0.3, 0.6, 0.39), 0.05, 0.05, "rubber")
		frames.GripR = palm(P(0.74, 0.28, 0.1), V(-0.35, -0.05, -1), V(1, 0.1, 0.35))
		frames.GripL = palm(P(-0.74, 0.28, 0.1), V(0.35, -0.05, -1), V(-1, 0.1, 0.35))
		frames.Sight = CF(P(-0.78, 0.32, -0.1))
	end)
	return yaw, pitch, pitchAt + V(0, 0, -1.78), {
		GunnerEye = { yaw, CF(pitchAt + V(0, 1.05, 1.0)) },
		GunnerSight = { pitch, frames.Sight },
		GripR = { pitch, frames.GripR },
		GripL = { pitch, frames.GripL },
		ReloadHand = { yaw, palm(V(base.X - 1.28, pitchY - 0.63, base.Z + 0.05), V(0.2, -0.2, -1), V(-1, 0.2, 0)) },
	}, "stand"
end

-- The van's mortar on its plinth: a bolted plinth with bevelled top edges, a turntable on it, and a
-- cradle -- two cheeks and a baseplate -- carrying the tube on its pins, the elevating screw under it
-- and the sight on the left. The gunner kneels behind it on the roof and turns with it.
function MountStyles.mortar(b, mount, names)
	local base = mount.base
	local column = mount.column or 0.9
	b:box("TurretPlinth", V(1.4, column, 1.2), base + V(0, column / 2, 0), "trim")
	for _, x in ipairs({ -1, 1 }) do
		for _, z in ipairs({ -1, 1 }) do
			b:cyl(string.format("TurretPlinthBolt%s%s", x < 0 and "L" or "R", z < 0 and "F" or "B"), 0.12, 0.16,
				CF(base + V(x * 0.55, column + 0.05, z * 0.45)) * A(0, 0, 90), "chrome")
		end
	end
	local top = base + V(0, column, 0)
	b:cyl("TurretRing", 0.24, 1.6, CF(top + V(0, 0.12 + 0.02, 0)) * A(0, 0, 90), "trim")
	for index = 1, 8 do
		local a = rad((index - 0.5) * 45)
		b:cyl("TurretRingBolt" .. index, 0.05, 0.1, CF(top + V(math.cos(a) * 0.74, 0.285, math.sin(a) * 0.74)) * A(0, 0, 90), "chrome")
	end
	local yawAt = top + V(0, 0.28, 0)
	local pitchAt = yawAt + V(0, 0.85, 0)
	local yaw = b:pivot(names.yaw, CF(yawAt), "TurretYaw")
	local pitch = b:pivot(names.pitch, CF(pitchAt), "TurretPitch", yaw)
	b:with(yaw, function()
		b:box("TurretYoke", V(1.1, 0.2, 0.9), yawAt + V(0, 0.1, 0), "accent")
		for _, s in ipairs({ -1, 1 }) do
			b:box(s < 0 and "TurretCheekL" or "TurretCheekR", V(0.16, pitchAt.Y - yawAt.Y + 0.25, 0.7),
				V(s * (0.4 + 0.08 + 0.02), (yawAt.Y + pitchAt.Y + 0.25) / 2, yawAt.Z), "accent")
		end
		-- Three bombs in a crate on the turntable's back edge, the reload's source.
		b:box("TurretBombCrate", V(0.8, 0.34, 0.36), yawAt + V(0, 0.37, 0.62), "wood")
		for index = 1, 3 do
			b:ball("TurretBombNose" .. index, 0.22, yawAt + V((index - 2) * 0.24, 0.6, 0.62), "trim")
		end
	end)
	local frames = {}
	b:with(pitch, function()
		local at = pitchAt
		trunnion(b, "TurretTrunnion", at, 1.0, 0.18)
		b:ball("MortarBreech", 0.8, at + V(0, 0, 0.35), "trim")
		b:tube("MortarTube", at + V(0, 0, 0.3), at + V(0, 0, -2.0), 0.7, "trim")
		b:tube("MortarLip", at + V(0, 0, -1.8), at + V(0, 0, -2.1), 0.84, "stripe")
		b:tube("MortarBore", at + V(0, 0, -1.9), at + V(0, 0, -2.16), 0.5, "mesh")
		-- The receiver round the breech (between the cheeks), a slotted shroud over the tube, a bomb
		-- magazine on top with a feed chute, spade handles behind, bolts along the receiver.
		b:box("MortarReceiver", V(0.76, 0.72, 0.62), at + V(0, 0, 0.05), "accent")
		b:box("MortarReceiverCap", V(0.8, 0.08, 0.66), at + V(0, 0.38, 0.05), "trim")
		b:tube("MortarShroud", at + V(0, 0, -0.3), at + V(0, 0, -1.2), 0.82, "accent")
		for index, z in ipairs({ -0.3, -1.2 }) do
			b:tube("MortarBand" .. index, at + V(0, 0, z - 0.05), at + V(0, 0, z + 0.05), 0.88, "mesh")
		end
		for index = 1, 4 do
			local z = -0.42 - index * 0.15
			b:box("MortarShroudSlotL" .. index, V(0.05, 0.3, 0.08), at + V(-0.405, 0, z), "mesh")
			b:box("MortarShroudSlotR" .. index, V(0.05, 0.3, 0.08), at + V(0.405, 0, z), "mesh")
		end
		b:box("MortarMagazine", V(0.36, 0.3, 0.5), at + V(0.12, 0.57, 0.02), "stripe")
		b:box("MortarMagazineLid", V(0.4, 0.05, 0.54), at + V(0.12, 0.74, 0.02), "trim")
		b:box("MortarMagazineHandle", V(0.06, 0.05, 0.26), at + V(0.12, 0.79, 0.02), "rubber")
		b:box("MortarFeedChute", V(0.2, 0.1, 0.2), at + V(0.12, 0.44, -0.18), "mesh")
		for _, x in ipairs({ -1, 1 }) do
			local n = x < 0 and "L" or "R"
			b:box("MortarHandleArm" .. n, V(0.08, 0.08, 0.3), at + V(x * 0.3, 0.2, 0.52), "trim")
			b:tube("MortarHandle" .. n, at + V(x * 0.3, -0.04, 0.68), at + V(x * 0.3, 0.26, 0.68), 0.13, "rubber")
			for index, z in ipairs({ -0.12, 0.22 }) do
				b:cyl(string.format("MortarBolt%s%d", n, index), 0.04, 0.09, CF(at + V(x * 0.39, 0.22, z)), "chrome")
			end
		end
		b:box("MortarSightArm", V(0.3, 0.1, 0.12), at + V(-0.45, 0.12, -0.45), "mesh")
		reflexSight(b, "Mortar", function(x, y, z)
			return at + V(x, y, z)
		end, 1, -0.62, 0.24, -0.45, 0.24, 0.2, 3)
		b:cyl("MortarWheel", 0.08, 0.36, CF(at + V(0.46, -0.08, 0.02)), "chrome")
		b:box("MortarWheelKnob", V(0.12, 0.06, 0.06), at + V(0.52, -0.08, -0.12), "rubber")
		frames.GripR = palm(at + V(0.54, -0.08, -0.1), V(-0.4, -0.2, -1), V(1, 0.3, 0))
		frames.GripL = palm(at + V(-0.3, 0.11, 0.68), V(0.35, 0, -1), V(-1, 0.15, 0.3))
		frames.Sight = CF(at + V(-0.62, 0.24, 0.12))
	end)
	return yaw, pitch, pitchAt + V(0, 0, -2.2), {
		-- The first-person eye is over the sight, left of the tube (behind it the tube filled the view);
		-- the kneeling rider stays square behind the mortar (SeatEye: where its own eyes are).
		GunnerEye = { yaw, CF(yawAt + V(-0.8, 2.9, 1.35)) },
		SeatEye = { yaw, CF(yawAt + V(0, 2.9, 1.35)) },
		GunnerSight = { pitch, frames.Sight },
		GripR = { pitch, frames.GripR },
		GripL = { pitch, frames.GripL },
		ReloadHand = { yaw, palm(yawAt + V(0.1, 0.74, 0.5), V(0, -0.4, -1), V(0, 1, -0.3)) },
	}, "kneel"
end

-- A shield on the gun's cradle, tipping with it: two side panels and a skirt round a slot the jacket
-- passes through, armoured glass above the slot (the sight line runs through it), and a wing angled
-- back at each side, carried on two arms off the cradle. `at` is the pin, `s` the gun's scale.
local function gunShield(b, at, s, z, bottom, top)
	local function P(x, y, zz)
		return at + V(x, y, zz)
	end
	local slotLow, slotHigh = -0.1 * s, 0.36 * s
	for _, x in ipairs({ -1, 1 }) do
		local n = x < 0 and "L" or "R"
		b:box("GunShield" .. n, V(0.5, top - bottom, 0.1), P(x * 0.75, (bottom + top) / 2, z), "accent")
		local wing = CF(P(x * 1.0, (bottom + top) / 2, z)) * A(0, x * -32, 0) * CF(x * 0.28, 0, 0.14)
		b:box("GunShieldWing" .. n, V(0.56, top - bottom - 0.2, 0.1), wing, "accent")
		b:beam("GunShieldArm" .. n, P(x * 0.26 * s, -0.08 * s, -0.25 * s), P(x * 0.26 * s, -0.08 * s, z + 0.08), 0.08, 0.1, "mesh")
	end
	b:box("GunShieldSkirt", V(1.0, slotLow - bottom, 0.1), P(0, (bottom + slotLow) / 2, z), "accent")
	b:box("GunShieldGlass", V(1.0, top - slotHigh - 0.08, 0.08), P(0, (slotHigh + top - 0.08) / 2, z), "glass")
	b:box("GunShieldCap", V(1.0, 0.08, 0.12), P(0, top - 0.04, z), "accent")
end

-- The scout car's gun ring: the ring on the shell, a pintle out in front of the gunner as on the
-- Rotster (the gunner stands 0.45 behind the ring's middle, 2.2 behind the pin, so the spade grips
-- are a stud in front of them), a heavy machine gun (1.15 scale) and a shield on its cradle.
function MountStyles.shielded(b, mount, names)
	local base = mount.base
	local yawAt = base + V(0, 0.2, 0)
	b:ring("TurretCoaming", CF(base + V(0, 0.1, 0)) * A(0, 0, 90), 1.12, 0.3, 0.2, 12, "trim", 0.5)
	local yaw = b:pivot(names.yaw, CF(yawAt), "TurretYaw", nil, { RingRadius = 1.27 })
	local reach, s = 1.75, 1.15
	local pitchAt = yawAt + V(0, 0.7, -reach)
	local pitch = b:pivot(names.pitch, CF(pitchAt), "TurretPitch", yaw)
	b:with(yaw, function()
		b:ring("TurretRing", CF(yawAt + V(0, 0.07, 0)) * A(0, 0, 90), 1.12, 0.3, 0.14, 12, "accent")
		b:box("TurretPintleSocket", V(0.5, 0.08, 0.66), yawAt + V(0, 0.18, -reach + 0.13), "trim")
		for _, x in ipairs({ -1, 1 }) do
			b:box(x < 0 and "TurretForkL" or "TurretForkR", V(0.07, 0.56, 0.32), pitchAt + V(x * 0.34, -0.2, 0), "trim")
		end
	end)
	local muzzleZ, frames
	b:with(pitch, function()
		trunnion(b, "TurretTrunnion", pitchAt, 0.88, 0.13)
		muzzleZ, frames = machineGun(b, "Gun", pitchAt, s, {})
		gunShield(b, pitchAt, s, -1.3, -0.34, 0.95)
	end)
	return yaw, pitch, pitchAt + V(0, 0.12 * s, -muzzleZ), {
		GunnerEye = { yaw, CF(yawAt + V(0, 1.32, 0.45)) },
		GunnerSight = { pitch, frames.Sight },
		GripR = { pitch, frames.GripR },
		GripL = { pitch, frames.GripL },
		ReloadHand = { pitch, frames.ReloadHand },
	}, "stand"
end

-- The carrier's turret: an open-topped cupola (walls to the gunner's chest, a low front under the gun)
-- turning on a ring on the roof, and an automatic grenade launcher on a mantlet at its front -- a
-- boxy receiver, a short, thick, banded barrel and a big ammo can -- in front of the gunner, who
-- stands in the cupola.
function MountStyles.agl(b, mount, names)
	local base = mount.base
	local yawAt = base + V(0, 0.18, 0)
	b:ring("TurretCoaming", CF(base + V(0, 0.09, 0)) * A(0, 0, 90), 1.3, 0.3, 0.18, 12, "trim", 0.5)
	local yaw = b:pivot(names.yaw, CF(yawAt), "TurretYaw", nil, { RingRadius = 1.45 })
	local reach, s = 1.6, 1.1
	local pitchAt = yawAt + V(0, 0.95, -reach)
	local pitch = b:pivot(names.pitch, CF(pitchAt), "TurretPitch", yaw)
	b:with(yaw, function()
		b:ring("TurretRing", CF(yawAt + V(0, 0.08, 0)) * A(0, 0, 90), 1.3, 0.3, 0.16, 12, "accent")
		-- Walls: the back and its corners 0.95 high, the sides 0.8, and low ones either side of the gun.
		-- Neighbouring walls stand 0.06 apart in height at the top and the foot (the foot sunk into
		-- the ring by turns), so where their corners meet no two faces share a plane.
		for _, e in ipairs({ { "B", 180, 0.95, 0.16 }, { "BL", 135, 0.87, 0.1 }, { "BR", -135, 0.87, 0.1 },
			{ "L", 90, 0.73, 0.16 }, { "R", -90, 0.73, 0.16 }, { "FL", 45, 0.48, 0.1 }, { "FR", -45, 0.48, 0.1 } }) do
			local frame = CF(yawAt) * A(0, e[2], 0) * CF(0, 0, -1.47)
			b:box("TurretWall" .. e[1], V(1.2, e[3], 0.16), frame + V(0, e[4] + e[3] / 2, 0), "accent")
		end
		b:box("TurretMantlet", V(1.1, 0.55, 0.7), yawAt + V(0, 0.16 + 0.275, -reach + 0.05), "trim")
		b:bevel("TurretMantletNose", yawAt + V(0, 0.16 + 0.275, -reach - 0.4), 1.1, 0.2, 0.55, V(0, 0, -1), V(0, 1, 0), "trim")
		b:box("TurretCradleBase", V(0.9, 0.12, 0.5), pitchAt + V(0, -0.23, 0), "mesh")
		for _, x in ipairs({ -1, 1 }) do
			b:box(x < 0 and "TurretForkL" or "TurretForkR", V(0.08, 0.32, 0.34), pitchAt + V(x * 0.36, -0.01, 0), "mesh")
		end
		-- A spare ammo can inside the back wall: where a reload comes from.
		b:box("TurretSpareCan", V(0.7, 0.5, 0.4), yawAt + V(0, 0.16 + 0.3, 1.1), "stripe")
		b:box("TurretSpareCanLid", V(0.74, 0.06, 0.44), yawAt + V(0, 0.16 + 0.58, 1.1), "trim")
	end)
	local frames
	b:with(pitch, function()
		local function P(x, y, z)
			return pitchAt + V(x, y, z) * s
		end
		trunnion(b, "TurretTrunnion", pitchAt, 0.92, 0.14)
		b:box("GunReceiver", V(0.56, 0.5, 1.2) * s, P(0, 0.12, 0.1), "trim")
		b:box("GunTopCover", V(0.7, 0.08, 0.9) * s, P(0, 0.4, 0.1), "engine")
		b:box("GunFeedTray", V(0.2, 0.14, 0.4) * s, P(-0.38, 0.22, 0.0), "mesh")
		b:box("GunAmmoCan", V(0.44, 0.56, 0.7) * s, P(-0.72, 0.02, 0.05), "stripe")
		b:box("GunAmmoCanLid", V(0.5, 0.06, 0.76) * s, P(-0.72, 0.33, 0.05), "trim")
		b:beam("GunBelt", P(-0.62, 0.34, 0.0), P(-0.36, 0.3, 0.0), 0.2 * s, 0.08 * s, "gold")
		b:box("GunSupport", V(0.42, 0.36, 0.3) * s, P(0, 0.12, -0.62), "trim")
		b:tube("GunJacket", P(0, 0.12, -0.74), P(0, 0.12, -1.6), 0.44 * s, "trim")
		for index, z in ipairs({ -0.95, -1.25 }) do
			b:tube("GunJacketBand" .. index, P(0, 0.12, z - 0.05), P(0, 0.12, z + 0.05), 0.5 * s, "mesh")
		end
		b:tube("GunBarrel", P(0, 0.12, -1.55), P(0, 0.12, -2.1), 0.3 * s, "mesh")
		b:tube("GunMuzzleRing", P(0, 0.12, -2.02), P(0, 0.12, -2.26), 0.38 * s, "trim")
		b:tube("GunMuzzleBore", P(0, 0.12, -2.2), P(0, 0.12, -2.32), 0.24 * s, "mesh")
		-- A reflex sight with range ticks under the dot (the grenades drop), on the sight line.
		reflexSight(b, "Gun", P, s, 0, 0.72, -0.45, 0.32, 0.2, 3, 0.15, true)
		beltRounds(b, "GunBeltRound", P(-0.6, 0.37, 0.0), P(-0.38, 0.33, 0.0), 3, s * 1.5)
		b:box("GunCanLatch", V(0.04, 0.14, 0.12) * s, P(-0.95, 0.18, 0.05), "chrome")
		b:box("GunCanStencil", V(0.45, 0.1, 0.56) * s, P(-0.72, -0.1, 0.05), "trim")
		for _, x in ipairs({ -1, 1 }) do
			for index, z in ipairs({ -0.3, 0.1, 0.5 }) do
				b:cyl(string.format("GunRivet%s%d", x < 0 and "L" or "R", index), 0.03 * s, 0.08 * s, CF(P(x * 0.285, 0.24, z)), "chrome")
			end
		end
		for index = 1, 3 do
			b:box("GunJacketVent" .. index, V(0.12, 0.04, 0.1) * s, P(0, 0.35, -0.85 - index * 0.2), "mesh")
		end
		b:box("GunBackplate", V(0.7, 0.38, 0.1) * s, P(0, 0.12, 0.74), "trim")
		for _, x in ipairs({ -1, 1 }) do
			local n = x < 0 and "L" or "R"
			b:tube("GunGripArmTop" .. n, P(x * 0.24, 0.26, 0.76), P(x * 0.24, 0.26, 1.04), 0.07 * s, "trim")
			b:tube("GunGripArmLow" .. n, P(x * 0.24, -0.04, 0.76), P(x * 0.24, -0.04, 1.0), 0.07 * s, "trim")
			b:tube("GunGrip" .. n, P(x * 0.24, -0.07, 1.0), P(x * 0.24, 0.37, 1.04), 0.14 * s, "rubber")
		end
		b:box("GunTrigger", V(0.28, 0.1, 0.05) * s, P(0, 0.15, 0.86), "gold")
		frames = {
			GripR = palm(P(0.24, 0.15, 1.02), V(-0.35, 0, -1), V(1, 0.15, 0.3)),
			GripL = palm(P(-0.24, 0.15, 1.02), V(0.35, 0, -1), V(-1, 0.15, 0.3)),
			Sight = CF(P(0, 0.72, 1.1)),
			ReloadHand = palm(P(-0.6, 0.5, 0.1), V(0.3, -0.3, -1), V(0, 1, 0)),
		}
	end)
	return yaw, pitch, pitchAt + V(0, 0.12 * s, -2.32 * s), {
		GunnerEye = { yaw, CF(yawAt + V(0, 1.62, 0.45)) },
		GunnerSight = { pitch, frames.Sight },
		GripR = { pitch, frames.GripR },
		GripL = { pitch, frames.GripL },
		ReloadHand = { pitch, frames.ReloadHand },
	}, "stand"
end

--------------------------------------------------------------------------------
-- Driver's gun styles: a short-arc gun at the front, fired from the wheel.
--------------------------------------------------------------------------------

local DriverStyles = {}

-- The race a ball turns in, on the yaw pivot: a ring round the ball's middle, standing proud of the
-- ball either side (the pitch pins' housings), so the ball tips inside it and the pair turn together.
local function ballRace(b, at)
	b:cyl("DriverGunRace", 0.66, 0.34, CF(at), "mesh")
end

-- The gun coming out of its ball along -Z: a banded jacket, the barrel, a flash hider.
local function ballGun(b, at, length)
	b:ball("DriverGunBall", 0.56, at, "trim")
	b:tube("DriverGunJacket", at + V(0, 0, -0.2), at + V(0, 0, -length * 0.62), 0.22, "trim")
	for index, t in ipairs({ 0.34, 0.5 }) do
		b:tube("DriverGunBand" .. index, at + V(0, 0, -length * t + 0.03), at + V(0, 0, -length * t - 0.03), 0.27, "mesh")
	end
	b:tube("DriverGunBarrel", at + V(0, 0, -length * 0.58), at + V(0, 0, -length + 0.12), 0.11, "mesh")
	b:tube("DriverGunFlash", at + V(0, 0, -length + 0.18), at + V(0, 0, -length), 0.17, "trim")
end

-- A low armoured cowl on a flat surface (the Rotster's bonnet bulge, the van's bumper): the ball in
-- its bevelled front, the gun's feed humped on its back. Yaw and pitch turn about the ball's middle.
function DriverStyles.cowl(b, mount, names)
	local base = mount.base
	local depth = mount.depth or 1.1
	local height = 0.58
	local frontZ = base.Z
	b:box("DriverGunCowl", V(0.9, height, depth - 0.2), V(base.X, base.Y + height / 2, frontZ + 0.2 + (depth - 0.2) / 2), "trim")
	b:bevel("DriverGunCowlNose", V(base.X, base.Y + height / 2, frontZ + 0.1), 0.9, 0.2, height, V(0, 0, -1), V(0, 1, 0), "trim")
	b:box("DriverGunFeed", V(0.5, 0.14, math.min(0.5, depth - 0.4)), V(base.X, base.Y + height + 0.07, frontZ + 0.2 + (depth - 0.2) / 2), "mesh")
	local at = V(base.X, base.Y + 0.36, frontZ + 0.08)
	local yaw = b:pivot(names.yaw, CF(at), "TurretYaw")
	local pitch = b:pivot(names.pitch, CF(at), "TurretPitch", yaw)
	local length = mount.length or 1.7
	b:with(yaw, function()
		ballRace(b, at)
	end)
	b:with(pitch, function()
		ballGun(b, at, length)
	end)
	return yaw, pitch, at + V(0, 0, -length)
end

-- A ball mount in a sloped plate: an armoured collar set into the plate (its axis along the plate's
-- outward normal, `mount.normal`) and the ball in it.
function DriverStyles.ball(b, mount, names)
	local at = mount.base
	local normal = (mount.normal or V(0, 0.5, -1)).Unit
	-- From the plate's face (sunk 0.05 into it) up round the ball's lower half.
	b:cyl("DriverGunCollar", 0.44, 0.86, CFrame.lookAt(at - normal * 0.17, at + normal) * A(0, 90, 0), "trim")
	local yaw = b:pivot(names.yaw, CF(at), "TurretYaw")
	local pitch = b:pivot(names.pitch, CF(at), "TurretPitch", yaw)
	local length = mount.length or 1.6
	b:with(yaw, function()
		ballRace(b, at)
	end)
	b:with(pitch, function()
		ballGun(b, at, length)
	end)
	return yaw, pitch, at + V(0, 0, -length)
end

local MOUNT_NAMES = {
	turret = { yaw = "TurretYaw", pitch = "TurretPitch", muzzle = "TurretMuzzle" },
	driver = { yaw = "DriverGunYaw", pitch = "DriverGunPitch", muzzle = "DriverGunMuzzle" },
}
VehicleModels.MountNames = MOUNT_NAMES

-- The gunner's seat for an eye at `eye` (a GunnerEye frame, model space) and a stance.
function VehicleModels.GunnerSeatFor(eye, stance)
	return CF(eye.Position - V(0, RIDER_ROOT + (EYE_ABOVE_ROOT[stance] or EYE_ABOVE_ROOT.stand), 0))
end

local function buildMount(b, which, mount)
	local names = MOUNT_NAMES[which]
	local style = which == "turret" and MountStyles[mount.style] or DriverStyles[mount.style]
	assert(style, "no " .. which .. " mount style " .. tostring(mount.style))
	local yaw, pitch, muzzleAt, markers, stance = style(b, mount, names)
	local muzzle = invisible(names.muzzle, CF(muzzleAt), b.model)
	b.anchors[muzzle] = pitch
	local frames = {}
	for name, entry in pairs(markers or {}) do
		-- SeatEye (optional) is only where the rider's own eyes go, for the seat: no marker for it.
		if name ~= "SeatEye" then
			mark(entry[1], name, entry[2])
		end
		frames[name] = entry[2]
	end
	if stance then
		yaw:SetAttribute("Stance", stance)
	end
	return frames, stance
end

-- What an unarmed build (a parked prop) has where the mount would be, so it reads as a whole car: a
-- lid on the Rotster's hatch, a couple of crates in the Ranger's bed.
local function buildUnarmed(b)
	if b.hatch then
		local at = b.hatch.at
		b:box("HatchLid", V(2 * b.hatch.half + 0.3, 0.12, 2 * b.hatch.half + 0.3), at + V(0, 0.06, 0), "accent")
		b:box("HatchHandle", V(0.6, 0.08, 0.1), at + V(0, 0.16, 0.6), "trim")
	end
	if b.bedFloor then
		local floor = b.bedFloor
		b:box("BedLoadCrateA", V(1.6, 1.1, 1.3), V(-0.9, floor.y + 0.55, floor.z0 + 1.4), "wood")
		b:box("BedLoadCrateB", V(1.3, 0.9, 1.2), CF(0.8, floor.y + 0.45, floor.z0 + 2.2) * A(0, 14, 0), "wood")
	end
end

--------------------------------------------------------------------------------
-- Rider poses
--------------------------------------------------------------------------------

-- R15 joint transforms laid over a seated character (VehicleClient sets them after animation, the
-- galleries pose their stand-ins with the same numbers). Angles in degrees about the joint's own
-- axes: +X swings a limb forward, a torso back.
local function pose(angles)
	local out = {}
	for joint, a in pairs(angles) do
		out[joint] = A(a[1], a[2], a[3])
	end
	return out
end

VehicleModels.Poses = {
	BikeRider = pose({
		Waist = { -24, 0, 0 },
		Neck = { 18, 0, 0 },
		LeftShoulder = { 62, 0, -12 },
		RightShoulder = { 62, 0, 12 },
		LeftElbow = { 28, 0, 0 },
		RightElbow = { 28, 0, 0 },
		LeftHip = { 58, 0, -10 },
		RightHip = { 58, 0, 10 },
		LeftKnee = { -104, 0, 0 },
		RightKnee = { -104, 0, 0 },
		LeftAnkle = { 40, 0, 0 },
		RightAnkle = { 40, 0, 0 },
	}),
	ScootRider = pose({
		Waist = { -4, 0, 0 },
		LeftShoulder = { 50, 0, -10 },
		RightShoulder = { 50, 0, 10 },
		LeftElbow = { 26, 0, 0 },
		RightElbow = { 26, 0, 0 },
		LeftHip = { 76, 0, -6 },
		RightHip = { 76, 0, 6 },
		LeftKnee = { -66, 0, 0 },
		RightKnee = { -66, 0, 0 },
	}),
	SportRider = pose({
		Waist = { -32, 0, 0 },
		Neck = { 26, 0, 0 },
		LeftShoulder = { 70, 0, -10 },
		RightShoulder = { 70, 0, 10 },
		LeftElbow = { 22, 0, 0 },
		RightElbow = { 22, 0, 0 },
		LeftHip = { 62, 0, -12 },
		RightHip = { 62, 0, 12 },
		LeftKnee = { -112, 0, 0 },
		RightKnee = { -112, 0, 0 },
		LeftAnkle = { 45, 0, 0 },
		RightAnkle = { 45, 0, 0 },
	}),
	BikePillion = pose({
		Waist = { -8, 0, 0 },
		LeftShoulder = { 30, 0, -8 },
		RightShoulder = { 30, 0, 8 },
		LeftElbow = { 40, 0, 0 },
		RightElbow = { 40, 0, 0 },
		LeftHip = { 50, 0, -12 },
		RightHip = { 50, 0, 12 },
		LeftKnee = { -96, 0, 0 },
		RightKnee = { -96, 0, 0 },
	}),
	CarDriver = pose({
		LeftShoulder = { 52, 0, 8 },
		RightShoulder = { 52, 0, -8 },
		LeftElbow = { 34, 0, 0 },
		RightElbow = { 34, 0, 0 },
	}),
	-- A gunner stands at the gun, legs straight under them (the seat's sit animation bends them), arms
	-- out to the handles. VehicleClient turns the whole body round the turret's yaw axis with the gun,
	-- and tips the arms with its pitch.
	GunnerStand = pose({
		Waist = { -6, 0, 0 },
		LeftHip = { 0, 0, -3 },
		RightHip = { 0, 0, 3 },
		LeftKnee = { -6, 0, 0 },
		RightKnee = { -6, 0, 0 },
		LeftAnkle = { 6, 0, 0 },
		RightAnkle = { 6, 0, 0 },
		LeftShoulder = { 66, 0, 10 },
		RightShoulder = { 66, 0, -10 },
		LeftElbow = { 38, 0, 0 },
		RightElbow = { 38, 0, 0 },
	}),
	-- Kneeling behind the mortar: thighs upright, shins flat behind, hands down on the handwheels.
	GunnerKneel = pose({
		Waist = { -12, 0, 0 },
		LeftHip = { 0, 0, -6 },
		RightHip = { 0, 0, 6 },
		LeftKnee = { -90, 0, 0 },
		RightKnee = { -90, 0, 0 },
		LeftAnkle = { 30, 0, 0 },
		RightAnkle = { 30, 0, 0 },
		LeftShoulder = { 40, 0, 12 },
		RightShoulder = { 40, 0, -12 },
		LeftElbow = { 30, 0, 0 },
		RightElbow = { 30, 0, 0 },
	}),
}

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

-- opts.drivable also draws from the models a map only ever parks as drivable vehicles (the armoured
-- cars, `drivableOnly`): VehicleService.Create asks for them, MapDecor's kerbside props never do, so the
-- streets keep the designs they had and their rolls are untouched.
function VehicleModels.Pick(kind, rng, opts)
	local drivable = type(opts) == "table" and opts.drivable == true
	-- Walk in a fixed order: pairs() order isn't stable, and a pick has to be.
	local ids, total = {}, 0
	for id, def in pairs(VehicleModels.Models) do
		if def.kind == kind and (drivable or not def.drivableOnly) then
			table.insert(ids, id)
			total += def.weight
		end
	end
	if total <= 0 then
		return nil
	end
	table.sort(ids)
	local roll = rng:NextNumber() * total
	for _, id in ipairs(ids) do
		roll -= VehicleModels.Models[id].weight
		if roll <= 0 then
			return id
		end
	end
	return ids[#ids]
end

-- Builds the model at the origin (see the header for its space) and returns it with its info.
-- opts.scheme picks a paint scheme by index; otherwise `rng` does.
function VehicleModels.Build(modelId, rng, opts)
	opts = opts or {}
	local def = VehicleModels.Models[modelId]
	assert(def, "unknown vehicle model " .. tostring(modelId))
	local schemeIndex = type(opts.scheme) == "number" and math.clamp(math.floor(opts.scheme), 1, #def.schemes) or rng:NextInteger(1, #def.schemes)
	local scheme = def.schemes[schemeIndex]

	local model = Instance.new("Model")
	model.Name = "Vehicle"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("VehicleModel", modelId)
	model:SetAttribute("VehicleKind", def.kind)
	model:SetAttribute("Scheme", scheme.name)

	local b = newBuilder(model, scheme)
	local layout = def.build(b)
	assert(b.chassis, modelId .. " built no Chassis")
	b:belly()
	-- An armed model's weapons (see Mounted weapons above): the turret, and the driver's gun; bikes have
	-- none. opts.unarmed leaves both off: BuildStatic's parked cars are scenery, not something to man, and
	-- get what an unarmed car has there instead (a lid on the Rotster's hatch, crates in the Ranger's bed).
	if VehicleModels.Mounts[modelId] and def.kind ~= "bike" and not opts.unarmed then
		local frames, stance = buildMount(b, "turret", VehicleModels.Mounts[modelId])
		if VehicleModels.DriverMounts[modelId] then
			buildMount(b, "driver", VehicleModels.DriverMounts[modelId])
		end
		model:SetAttribute("Armed", true)
		-- The gun's own seat, alongside the driver's and the passengers', where the gunner's eye lands on
		-- the mount's GunnerEye.
		if frames.GunnerEye and layout.seats then
			local gunner = VehicleModels.GunnerSeatFor(frames.SeatEye or frames.GunnerEye, stance)
			VehicleModels.GunnerSeats[modelId] = gunner
			local seats = { gunner = gunner }
			for key, value in pairs(layout.seats) do
				seats[key] = value
			end
			layout.seats = seats
		end
		-- VehicleWeapons finds empty armed vehicles for bots by this tag.
		game:GetService("CollectionService"):AddTag(model, "ArmedVehicle")
	else
		buildUnarmed(b)
	end
	-- A part under workspace.Map with a breakable name would be shot to pieces (see the header).
	for _, part in ipairs(model:GetChildren()) do
		if RESERVED_NAMES[part.Name] then
			part.Name = "Vehicle" .. part.Name
		end
	end

	-- Only the Chassis and the Hull_* parts stop a shot, which keeps two hundred panels out of every
	-- raycast. Structure ABOVE THE BELT LINE is the exception: a pillar or a bed wall is bodywork, and
	-- a shot that visibly hits one and does nothing is the kind of thing a player remembers as broken.
	-- These are made query-able but stay non-collidable, so they stop bullets without touching the
	-- physics. What is deliberately left shoot-through, and should stay that way: the glass (or you
	-- could not shoot a driver through a windscreen) and trim that stands clear of the body -- mirrors,
	-- fender lips, winch hooks -- where a bullet simply carries on to whatever is behind it.
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and not part.CanQuery then
			for _, prefix in ipairs(SOLID_NAMES) do
				if string.sub(part.Name, 1, #prefix) == prefix then
					part.CanQuery = true
					break
				end
			end
		end
	end

	-- No two faces flush anywhere, before any joint goes in so only the one part moves.
	local zfight = ZFight.Fix({ model }, { all = true })

	for part, anchor in pairs(b.anchors) do
		if part ~= b.chassis and not b.jointed[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = anchor or b.chassis
			weld.Part1 = part
			weld.Parent = part
		end
	end
	for _, entry in ipairs(b.joints) do
		local parent = entry.parent or b.chassis
		local joint = Instance.new("Motor6D")
		joint.Name = "Joint"
		joint.Part0 = parent
		joint.Part1 = entry.part
		joint.C0 = parent.CFrame:ToObjectSpace(entry.part.CFrame)
		joint.C1 = CFrame.identity
		joint.Parent = entry.part
	end

	-- Clients pose riders from this, since the layout itself never leaves the server.
	model:SetAttribute("RiderPose", layout.pose and layout.pose.name or (def.kind == "bike" and "BikeRider" or "CarDriver"))
	model.PrimaryPart = b.chassis
	-- The chassis stays the assembly's root even with a rider welded on (a HumanoidRootPart would
	-- otherwise compete for it, and a root part's Massless is ignored).
	b.chassis.RootPriority = 127
	-- Pivot on the ground under the wheelbase, so PivotTo(position) puts the wheels on `position`.
	b.chassis.PivotOffset = b.chassis.CFrame:Inverse()

	return model, {
		modelId = modelId,
		kind = def.kind,
		displayName = def.displayName,
		scheme = scheme,
		schemeIndex = schemeIndex,
		chassis = b.chassis,
		hulls = b.hulls,
		wheels = b.wheels,
		seats = layout.seats,
		exits = layout.exits,
		pose = layout.pose,
		zfight = zfight,
	}
end

--------------------------------------------------------------------------------
-- Static builds: the same designs as map scenery (#16 / #94)
--------------------------------------------------------------------------------

-- A static car is the real design, built by Build above, with the cost cut down to what reads from
-- the street: a parked car is looked at from ten studs off, not sat in. Left out:
--   * every joint and weld, and the invisible hubs and pivots they hung from (nothing moves)
--   * all of each wheel but its tyre, rim lip and centre disc (a wheel is sixteen to forty parts,
--     most of them wall, barrel, spokes and nuts that only show on a wheel you can turn)
--   * the wheel-arch lips (a ring of ten or twelve trim segments per arch; the arch panels, which
--     are the body round the wheel, all stay, so no hole opens in the side)
--   * the steering wheel and the gauges, which are inside behind glass
--   * a car's steering column with them: left on its own it is a bare rod standing up out of the
--     dash at the driver's chest, 0.2-0.5 studs of it clear of anything (measured by
--     tools/vehicle_models_axis_check.py), which through the windscreen is a pole in the cabin.
--     (Only a car's: a scooter's Column is its front fork.)
-- The Chassis and Hull_* colliders stay: they are what you take cover behind and what a shot hits.
local STATIC_DROP = { "^SteeringWheel", "^Lip[FR][LR]", "^Gauge" }
local STATIC_CAR_DROP = { "^Column$" }
-- (A bike's sprocket too: without it the chain ends in the air at the back wheel.)
local STATIC_WHEEL_KEEP = { Tyre = true, Lip = true, Disc = true, Sprocket = true }

local function staticKeeps(part, hubs, car)
	if part.Name == "Chassis" or string.sub(part.Name, 1, 5) == "Hull_" then
		return true
	end
	if part.Transparency >= 1 then
		return false
	end
	local hub, piece = string.match(part.Name, "^(Wheel_%a+)_(.+)$")
	if hub and hubs[hub] then
		return STATIC_WHEEL_KEEP[piece] == true
	end
	for _, pattern in ipairs(STATIC_DROP) do
		if string.find(part.Name, pattern) then
			return false
		end
	end
	if car then
		for _, pattern in ipairs(STATIC_CAR_DROP) do
			if string.find(part.Name, pattern) then
				return false
			end
		end
	end
	return true
end

-- Builds `modelId` as an anchored, jointless, seatless prop standing at `cframe` (the ground under
-- the middle of the wheelbase, nose along its LookVector) and returns it with Build's info. It
-- carries none of the attributes or tags that make a model a vehicle (VehicleModel, Lamp, Radius,
-- ArmedVehicle), so VehicleClient never rigs it and bots never try to man it.
function VehicleModels.BuildStatic(modelId, rng, cframe, opts)
	opts = opts or {}
	local model, info = VehicleModels.Build(modelId, rng, { scheme = opts.scheme, unarmed = true })
	local hubs = {}
	for _, hub in ipairs(info.wheels) do
		hubs[hub.Name] = true
	end
	for _, child in ipairs(model:GetChildren()) do
		if child:IsA("BasePart") and not staticKeeps(child, hubs, info.kind == "car") then
			child:Destroy()
		end
	end
	local parts = 0
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			parts += 1
			-- Welds and joints live under the part they hold; anchored, the part needs neither. (Only
			-- those: a number plate's SurfaceGui lives there too.)
			for _, joint in ipairs(part:GetChildren()) do
				if joint:IsA("JointInstance") or joint:IsA("WeldConstraint") then
					joint:Destroy()
				end
			end
			part.Anchored = true
			part.CanTouch = false
			for key in pairs(part:GetAttributes()) do
				part:SetAttribute(key, nil)
			end
		end
	end
	for key in pairs(model:GetAttributes()) do
		model:SetAttribute(key, nil)
	end
	model.Name = "StaticVehicle"
	model:PivotTo(cframe)
	info.parts = parts
	return model, info
end

return VehicleModels
