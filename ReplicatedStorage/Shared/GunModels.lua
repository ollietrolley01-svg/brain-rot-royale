-- Gun models.
--
-- One builder for every gun in the game, shared by the server (the gun a character holds, what lies
-- on the floor, the podium displays) and the client (the first-person viewmodel, which is built
-- locally at full detail rather than cloned from the character's copy).
--
--   GunModels.Build(def, color, material, options) -> model, receiver
--
-- options.detail   "full" (default) or "world". Every copy has the same shapes -- the gun on the
--                  floor, on a podium and in your hands is one model -- and "world" only leaves out
--                  the smallest fittings (pins, screw heads, knurling), for guns bots carry.
-- options.skinned  true when `color`/`material` come from a gun skin. Skins repaint the gun's
--                  panels; without one, rarity is carried by finish instead (see Builder:finish).
--
-- Guns are authored in MILLIMETRES at close to real proportions and scaled by MM. Real dimensions
-- are what make a part-built gun read as a gun: the old models were two and a half times real size
-- with every panel painted in the rarity colour, and at that size a rail is a slab and a grip is a
-- brick. The origin sits on the bore axis above the trigger; the gun faces -Z, +X is the right
-- (ejection) side.
--
-- The model carries its own animation contract, so nothing downstream guesses from part names:
--   attribute Anim on a part         the moving group it belongs to (slide, bolt, charge, pump, mag,
--                                    drum, spin, hinge, cover, lever, hammer, trigger, round, crane,
--                                    string, rounds)
--   model attribute KP_<name>        keypoints as CFrames in model space: GripHand, SupportHand,
--                                    MagHand, ChargeHand, BoltHand, Sight, Muzzle, Eject, MagWell,
--                                    Load
--   model attribute Pivot_<group>    where an angular group turns (about the pivot's X for hinges
--                                    and levers, its Z for drums and spinning barrels)
--   model attribute Travel_<group>   how far a sliding group moves back, in studs
--   model attribute Swing_<group>    how far an angular group turns, in degrees
--   model attributes Action, Optic, EyeRelief, Flash, Casing, WeaponId, Style, Detail
-- The old names the rest of the game relies on stay: Receiver (the PrimaryPart), Grip, AimPoint,
-- Scope on scoped guns, FrontSight/RearSight on iron-sighted ones, EjectionPort, LaserEmitter, and
-- the Muzzle attachment on the receiver.

local Shared = script.Parent
local Rarity = require(Shared:WaitForChild("Rarity"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local ArsenalExpansion = require(Shared:WaitForChild("ArsenalExpansion"))
local ArsenalFinish = require(Shared:WaitForChild("ArsenalFinish"))
-- claude-3b's creative guns: Variants and Builders keyed by weapon id, built through the same Builder
-- and contract (see GunModels.Kit and Build). Optional: without the module every gun builds as before.
local creativeModule = Shared:FindFirstChild("GunModelsCreative")
local GunModelsCreative = creativeModule and require(creativeModule) or { Variants = {}, Builders = {} }
-- The workshop guns (WorkshopArsenal) build the same way, from their own module.
local workshopModule = Shared:FindFirstChild("GunModelsWorkshop")
local GunModelsWorkshop = workshopModule and require(workshopModule) or { Variants = {}, Builders = {} }

local GunModels = {}

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad

local MM = 0.0038
GunModels.StudsPerMillimetre = MM

-- Everything a gun is built from sits at least this far off any face it would otherwise lie flush
-- with. The z-fight pass runs on guns with a tolerance scaled to their size (GunModels.ZFightOptions);
-- this keeps the builder clear of it by design rather than relying on the pass to push things apart.
local RELIEF = 3.5
-- Fine surface work (engraving, checkering, grip texture) stands this far proud. A gun is small and
-- seen up close, where depth precision is plentiful, so guns run the z-fight pass with a tolerance of
-- about a millimetre rather than the map's 17: at the map's tolerance every inlay line had to stand
-- out like a wire.
local FINE = 1.4

GunModels.ZFightOptions = { all = true, tolerance = 0.0035, gap = 0.0045 }
-- The harness scans finished guns with this.
GunModels.ZFightTolerance = 0.003

local SIGNS = { 1, -1 }

local function A(x, y, z)
	return CFrame.Angles(rad(x or 0), rad(y or 0), rad(z or 0))
end

local function place(at)
	if typeof(at) == "Vector3" then
		return CFrame.new(at)
	end
	return at or CFrame.identity
end

--------------------------------------------------------------------------------
-- Finishes
--------------------------------------------------------------------------------

local Mat = Enum.Material

local function finish(r, g, b, material, reflectance, transparency)
	return {
		color = Color3.fromRGB(r, g, b),
		material = material,
		reflectance = reflectance or 0,
		transparency = transparency or 0,
	}
end

local function finishOf(color, material, reflectance, transparency)
	return { color = color, material = material, reflectance = reflectance or 0, transparency = transparency or 0 }
end

-- Real gun finishes. Nothing here glows except what would: tritium, the red dot, a laser, a lens.
local F = {
	polymer = finish(38, 38, 41, Mat.SmoothPlastic),
	polymerDark = finish(27, 27, 30, Mat.SmoothPlastic),
	texture = finish(33, 33, 36, Mat.Plastic),
	anodized = finish(48, 49, 53, Mat.Metal),
	anodizedDark = finish(34, 35, 38, Mat.Metal),
	parkerized = finish(62, 63, 66, Mat.Metal),
	blued = finish(40, 43, 52, Mat.Metal, 0.04),
	nitride = finish(24, 24, 27, Mat.Metal),
	steel = finish(104, 107, 112, Mat.Metal, 0.03),
	steelMag = finish(74, 77, 84, Mat.Metal, 0.02),
	bright = finish(170, 173, 178, Mat.Metal, 0.08),
	stainless = finish(166, 168, 172, Mat.Metal, 0.1),
	shadow = finish(9, 9, 11, Mat.SmoothPlastic),
	bore = finish(4, 4, 5, Mat.SmoothPlastic),
	brass = finish(206, 162, 82, Mat.Metal, 0.08),
	copper = finish(186, 114, 72, Mat.Metal, 0.06),
	gold = finish(228, 184, 78, Mat.Metal, 0.18),
	goldDeep = finish(196, 146, 52, Mat.Metal, 0.1),
	wood = finish(118, 70, 40, Mat.Wood),
	woodDark = finish(80, 47, 28, Mat.Wood),
	woodLight = finish(150, 102, 62, Mat.Wood),
	rubber = finish(30, 30, 32, Mat.Rubber),
	fabric = finish(58, 60, 54, Mat.Fabric),
	tape = finish(64, 64, 68, Mat.Fabric),
	leather = finish(84, 54, 34, Mat.Leather),
	fde = finish(146, 124, 92, Mat.SmoothPlastic),
	od = finish(92, 96, 72, Mat.SmoothPlastic),
	camoLight = finish(128, 112, 82, Mat.SmoothPlastic),
	camoDark = finish(88, 84, 62, Mat.SmoothPlastic),
	camoBrown = finish(108, 86, 60, Mat.SmoothPlastic),
	ghillie = finish(84, 96, 60, Mat.Fabric),
	ghillieDark = finish(58, 66, 42, Mat.Fabric),
	glass = finish(96, 132, 150, Mat.Glass, 0.25, 0.55),
	lens = finish(120, 170, 190, Mat.Glass, 0.2, 0.82),
	coated = finish(70, 60, 120, Mat.Glass, 0.35, 0.35),
	-- A red dot or holo's windows are looked through: barely tinted, and not Glass, which darkens
	-- and warps whatever is behind it.
	sightCoated = finish(120, 96, 170, Mat.SmoothPlastic, 0, 0.9),
	sightLens = finish(170, 210, 225, Mat.SmoothPlastic, 0, 0.94),
	tank = finish(200, 235, 250, Mat.Glass, 0.3, 0.72),
	soap = finish(120, 214, 245, Mat.Glass, 0.2, 0.38),
	bubble = finish(236, 250, 255, Mat.Glass, 0.45, 0.4),
	film = finish(200, 236, 255, Mat.Glass, 0.5, 0.8),
	dial = finish(236, 232, 220, Mat.SmoothPlastic),
	energy = finish(140, 230, 255, Mat.Neon),
	ceramic = finish(196, 198, 202, Mat.SmoothPlastic),
	tritium = finish(140, 255, 160, Mat.Neon),
	tritiumOrange = finish(255, 150, 60, Mat.Neon),
	redDot = finish(255, 36, 36, Mat.Neon),
	laser = finish(255, 30, 30, Mat.Neon),
	shell = finish(176, 34, 36, Mat.SmoothPlastic),
	shellGreen = finish(46, 110, 70, Mat.SmoothPlastic),
	warhead = finish(84, 96, 70, Mat.SmoothPlastic),
	warning = finish(230, 190, 40, Mat.SmoothPlastic),
	cork = finish(170, 130, 90, Mat.Wood),
}
GunModels.Finishes = F

--------------------------------------------------------------------------------
-- What sets each gun apart from the others of its silhouette
--------------------------------------------------------------------------------

--   pattern        "ak" builds the rifle as a stamped-receiver AK rather than an AR
--   compact        shorter barrel and furniture           drum           a drum magazine
--   suppressor     a can on the muzzle                    laser          a laser module (a real beam when you aim)
--   light          a weapon light                         holo           a holographic sight
--   camo           tiger-stripe furniture                 woodFurniture  wooden furniture
--   bayonet        a blade under the muzzle               foregrip       a vertical foregrip
--   skeletonStock  a folding skeleton stock               engraved       gold inlay on the metal
--   heatShield     a ventilated shield over the barrel    longBarrel     an extra length of barrel
--   sawnOff        barrels cut short, pistol grip         ghillie        rag wraps along the gun
--   sixShot        a six-round revolving launcher         bigTank        a larger reservoir
--   flutes         fluted barrel                          irons          flip-up iron sights, no optic
--   boltAction     worked by hand after every shot        semiAuto       magazine-fed semi-automatic
local VARIANTS = {
	SahurPistol = { light = true },
	PocketPopper = { compact = true, laser = true },
	RotSMG = { skeletonStock = true, suppressor = true },
	LagSwitchSMG = { drum = true, laser = true },
	GlitchSMG = { drum = true, holo = true, camo = true },
	CrocodiloRifle = { pattern = "ak", woodFurniture = true, bayonet = true },
	CrumblyCarbine = { compact = true, camo = true, irons = true },
	BananiniBurst = { foregrip = true, holo = true, camo = true },
	SigmaRevolver = { longBarrel = true, engraved = true },
	TralalaShotgun = { heatShield = true },
	AuraScattergun = { semiAuto = true, drum = true, heatShield = true, foregrip = true },
	BonkerDoubleBarrel = { sawnOff = true },
	NonnaDoubleBarrel = { engraved = true },
	LarilaSniper = { boltAction = true, longBarrel = true, ghillie = true, flutes = true },
	SixSevenMarksman = { camo = true, flutes = true },
	GrassToucherDMR = { woodFurniture = true, laser = true },
	SigmaScout = { compact = true, foregrip = true, light = true },
	TralalaThumper = { sixShot = true },
	BubbleBurster = { bigTank = true },
	RizzRotary = { holo = true, engraved = true, foregrip = true },
}
GunModels.Variants = VARIANTS
for id, variant in pairs(ArsenalExpansion.Variants) do
	VARIANTS[id] = variant
end
for id, variant in pairs(GunModelsCreative.Variants or {}) do
	VARIANTS[id] = variant
end
for id, variant in pairs(GunModelsWorkshop.Variants or {}) do
	VARIANTS[id] = variant
end

--------------------------------------------------------------------------------
-- Builder
--------------------------------------------------------------------------------

local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
-- A cylinder's axis is its local X. These turn it to run front to back, or upright.
local ALONG_Z = CFrame.Angles(0, math.pi / 2, 0)
local ALONG_Y = CFrame.Angles(0, 0, math.pi / 2)

local Builder = {}
Builder.__index = Builder

-- `scale` enlarges a whole gun about its origin: the AR-10s and the 12-gauge AR are the AR's own parts
-- at their real, larger proportions.
local function toStuds(cframe, scale)
	return CFrame.new(cframe.Position * (MM * (scale or 1))) * cframe.Rotation
end

function Builder.new(def, color, material, options)
	local self = setmetatable({}, Builder)
	self.def = def
	self.style = def.style or "rifle"
	self.variant = VARIANTS[def.id] or {}
	-- Every copy of a gun is built with the same shapes, so the one on the floor or on a podium is the
	-- one in your hands. "world" only leaves out the smallest fittings (pins, screw heads, knurling,
	-- rivets), for copies nobody gets within arm's length of, like the guns bots carry.
	self.high = true
	self.micro = options.detail ~= "world"
	self.model = Instance.new("Model")
	self.model.Name = "HeldGun"
	self.frame = CFrame.identity
	self.anim = nil
	self.rarityIndex = Rarity.Index[def.rarity] or 1
	self.accent = Rarity.Color(def.rarity)
	self.skinned = options.skinned == true
	self.skin = finishOf(color or self.accent, material or Mat.Metal)
	self.parts = 0
	self.scale = 1
	return self
end

-- Every part goes through here. Sizes and placements are in millimetres, relative to the current
-- frame (Builder:at).
function Builder:make(className, shape, name, size, cframe, look)
	local part = Instance.new(className)
	part.Name = name
	if shape then
		part.Shape = shape
	end
	part.Size = size * (MM * self.scale)
	part.CFrame = toStuds(self.frame * cframe, self.scale)
	part.Color = look.color
	part.Material = look.material
	part.Reflectance = look.reflectance
	part.Transparency = look.transparency
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if self.anim then
		part:SetAttribute("Anim", self.anim)
	end
	part.Parent = self.model
	self.parts += 1
	return part
end

function Builder:box(name, size, at, look)
	return self:make("Part", nil, name, size, place(at), look)
end

-- Cylinders run front to back (Z) unless they say otherwise.
function Builder:cyl(name, length, diameter, at, look)
	return self:make("Part", CYLINDER, name, V(length, diameter, diameter), place(at) * ALONG_Z, look)
end

function Builder:cylX(name, length, diameter, at, look)
	return self:make("Part", CYLINDER, name, V(length, diameter, diameter), place(at), look)
end

function Builder:cylY(name, length, diameter, at, look)
	return self:make("Part", CYLINDER, name, V(length, diameter, diameter), place(at) * ALONG_Y, look)
end

function Builder:ball(name, diameter, at, look)
	return self:make("Part", BALL, name, V(diameter, diameter, diameter), place(at), look)
end

-- A raw wedge: vertical face at the back (+Z), sloping down to the front.
function Builder:wedge(name, size, at, look)
	return self:make("WedgePart", nil, name, size, place(at), look)
end

-- Only built at high detail.
function Builder:detail(fn)
	if self.micro then
		fn()
	end
end

-- Builds `fn` in a frame placed at `at` inside the current one.
function Builder:at(at, fn)
	local saved = self.frame
	self.frame = saved * place(at)
	fn()
	self.frame = saved
end

-- Parts built inside `fn` belong to the named animation group.
function Builder:group(name, fn)
	local saved = self.anim
	self.anim = name
	fn()
	self.anim = saved
end

local function modelSpace(self, at)
	return toStuds(self.frame * place(at), self.scale)
end

function Builder:key(name, at)
	self.model:SetAttribute("KP_" .. name, modelSpace(self, at))
end

-- A hand keypoint: the palm centre, the way the fingers point, and the way the back of the hand
-- faces. The viewmodel's hand is built to that frame: -Z along the fingers, +Y out of the back of
-- the hand.
function Builder:hand(name, position, fingers, back)
	local z = -fingers.Unit
	local x = back.Unit:Cross(z).Unit
	local y = z:Cross(x).Unit
	self:key(name, CFrame.fromMatrix(position, x, y, z))
end

function Builder:travel(group, millimetres)
	self.model:SetAttribute("Travel_" .. group, millimetres * MM * self.scale)
end

function Builder:swing(group, at, degrees)
	self.model:SetAttribute("Pivot_" .. group, modelSpace(self, at))
	if degrees then
		self.model:SetAttribute("Swing_" .. group, degrees)
	end
end

--------------------------------------------------------------------------------
-- Shapes
--------------------------------------------------------------------------------

-- The wedge that fills one long edge of a chamfered prism running along Z. `sx`/`sy` pick the
-- corner. A wedge's triangle lives in its local YZ plane, so it is laid down with its X along the
-- prism: local Y out along the corner's side, local Z back toward the prism's middle.
local function bevelFrame(sx, sy, x, y)
	return CFrame.fromMatrix(V(x, y, 0), V(0, 0, sx * sy), V(0, sy, 0), V(-sx, 0, 0))
end

-- A block running along Z with its long edges chamfered: a machined receiver, a handguard, a slide.
-- Built from a core, a cap slab per chamfered side and a wedge per edge, arranged so no two faces
-- ever lie flush (every seam is two faces meeting edge to edge or back to back). `edges` is "all",
-- "top" or "bottom". Low detail is the plain block.
function Builder:prism(name, size, at, chamfer, look, edges)
	local frame = place(at)
	local c = math.min(chamfer, size.X * 0.45, size.Y * 0.45)
	if not self.high or c < 1 then
		return self:box(name, size, frame, look)
	end
	edges = edges or "all"
	local top = edges ~= "bottom"
	local bottom = edges ~= "top"
	local coreHeight = size.Y - (top and c or 0) - (bottom and c or 0)
	local coreY = ((bottom and c or 0) - (top and c or 0)) / 2
	local main = self:box(name, V(size.X, coreHeight, size.Z), frame * CF(0, coreY, 0), look)
	for _, sy in ipairs(SIGNS) do
		if (sy > 0 and top) or (sy < 0 and bottom) then
			self:box(name .. "Cap", V(size.X - 2 * c, c, size.Z), frame * CF(0, sy * (size.Y - c) / 2, 0), look)
			for _, sx in ipairs(SIGNS) do
				self:wedge(name .. "Bevel", V(size.Z, c, c), frame * bevelFrame(sx, sy, sx * (size.X - c) / 2, sy * (size.Y - c) / 2), look)
			end
		end
	end
	return main
end

-- The same with rounded long edges: grips, stocks, polymer frames. The corner rods stop RELIEF short
-- of each end so their end discs never lie in the end faces of the slabs beside them.
function Builder:rounded(name, size, at, radius, look)
	local frame = place(at)
	local r = math.min(radius, size.X * 0.45, size.Y * 0.45)
	if not self.high or r < 1.5 then
		return self:box(name, size, frame, look)
	end
	local main = self:box(name, V(size.X, size.Y - 2 * r, size.Z), frame, look)
	for _, sy in ipairs(SIGNS) do
		self:box(name .. "Cap", V(size.X - 2 * r, r, size.Z), frame * CF(0, sy * (size.Y - r) / 2, 0), look)
		for _, sx in ipairs(SIGNS) do
			-- Where the slab is thin its corner rods overlap in plan, and any two whose end discs share a
			-- plane fight there. Each rod is cut a different amount at each end — fronts 0/1/2/3 × FINE,
			-- backs 3/2/1/0 — so no two rods end in the same plane at either end, and every rod loses the
			-- same 3 × FINE overall (the earlier two-length scheme left the two untrimmed rods, and the two
			-- trimmed ones, coplanar whenever the slab was thin in both axes).
			local front = (sx > 0 and 1 or 0) + (sy > 0 and 2 or 0)
			local back = 3 - front
			self:cyl(name .. "Round", size.Z - 2 * RELIEF - (front + back) * FINE, 2 * r,
				frame * CF(sx * (size.X / 2 - r), sy * (size.Y / 2 - r), (back - front) * FINE / 2), look)
		end
	end
	return main
end

-- A hollow tube along Z made of staves, for anything you look *through*: a red dot's body, a
-- muzzle's bore. Low detail is a solid cylinder, which from any distance looks the same.
function Builder:shell(name, length, outer, wall, at, look, sides)
	local frame = place(at)
	if not self.high then
		return self:cyl(name, length, outer, frame, look)
	end
	sides = sides or 12
	local radius = outer / 2 - wall / 2
	local width = 2 * (outer / 2) * math.tan(math.pi / sides) + 0.4
	local first
	for index = 0, sides - 1 do
		local angle = index / sides * math.pi * 2
		-- Neighbouring staves overlap a sliver along their shared edge, so their end faces would lie in
		-- one plane over it; every other stave stops FINE short at each end to keep them apart.
		local staveLength = index % 2 == 0 and length or length - FINE * 2
		local stave = self:box(name, V(width, wall, staveLength), frame * CFrame.Angles(0, 0, angle) * CF(0, radius, 0), look)
		first = first or stave
	end
	return first
end

--------------------------------------------------------------------------------
-- Finish by role
--------------------------------------------------------------------------------

-- Rarity used to be the colour of the whole gun, which is what made every gun a toy. It lives in
-- finish now, the way a real rifle is dressed up: Common is plain black, Uncommon picks out its
-- small anodised parts, Rare has its handguard and slide cerakoted, Epic cerakotes the receiver as
-- well, and a Legendary is black with gold parts and gold inlay. Furniture (grips, stocks, pumps)
-- stays black polymer at every rarity: a purple stock and grip is what a toy gun looks like. A gun
-- skin paints the panels and furniture in its own colour whatever the rarity.
--
-- Roles: receiver, handguard, slide, furniture (grip, stock, pump), barrel, small (levers, pins,
-- charging handle, mag base), trim (bolts, screws, springs).
function Builder:finish(role)
	local rarity = self.rarityIndex
	local cerakote = finishOf(self.accent:Lerp(Color3.fromRGB(34, 34, 38), 0.78), Mat.Metal, 0.04)
	if role == "barrel" then
		return F.nitride
	elseif role == "trim" then
		return rarity >= 5 and F.gold or F.steel
	elseif role == "small" then
		if rarity >= 5 then
			return F.gold
		elseif rarity >= 2 then
			return finishOf(self.accent:Lerp(Color3.fromRGB(30, 30, 34), 0.3), Mat.Metal, 0.05)
		end
		return F.anodizedDark
	end
	if self.skinned then
		if role == "receiver" or role == "handguard" or role == "slide" or role == "furniture" then
			return self.skin
		end
	end
	if role == "receiver" then
		return rarity == 4 and cerakote or F.anodized
	elseif role == "handguard" or role == "slide" then
		return (rarity == 3 or rarity == 4) and cerakote or F.anodized
	elseif role == "furniture" then
		return F.polymer
	end
	return F.anodized
end

--------------------------------------------------------------------------------
-- Components
--------------------------------------------------------------------------------

-- A Picatinny rail along Z. `at` is the centre of its base; it stands 9.5mm tall. Real cross slots
-- between the teeth at high detail.
function Builder:rail(name, length, at, look)
	local frame = place(at)
	look = look or F.anodizedDark
	if not self.high then
		return self:box(name, V(21, 9.5, length), frame * CF(0, 4.75, 0), look)
	end
	local base = self:box(name, V(15.6, 5, length), frame * CF(0, 2.5, 0), look)
	self:box(name .. "Spine", V(21.2, 2, length), frame * CF(0, 6, 0), look)
	local teeth = math.max(1, math.floor((length - 4) / 10))
	local first = -(teeth - 1) * 5
	for index = 0, teeth - 1 do
		self:box(name .. "Tooth", V(21.2, 2.5, 4.8), frame * CF(0, 8.25, first + index * 10), look)
	end
	return base
end

-- Screw heads, pins and rivets: a short cylinder standing proud of a side face.
function Builder:pin(name, diameter, at, look, length)
	if not self.micro then
		return nil
	end
	return self:cylX(name, length or RELIEF * 2, diameter, at, look or F.anodizedDark)
end

-- A muzzle's bore: a polygon ring so the hole is a hole.
function Builder:crown(name, length, outer, bore, at, look)
	local frame = place(at)
	if not self.high then
		self:cyl(name, length, outer, frame, look)
		return
	end
	self:shell(name, length, outer, (outer - bore) / 2, frame, look, 10)
	-- The dark disc's edge bites 1.5 mm into the ring's wall, so it is seated, not touching by a hair.
	self:cyl(name .. "Bore", 2, bore + 3, frame * CF(0, 0, length / 2 - 6), F.bore)
end

-- An A2 birdcage flash hider: a collar, five prongs with open slots between, a front ring, and the
-- bottom left closed (on a real one that stops dust kicking up when fired prone).
function Builder:birdcage(at, diameter)
	local d = diameter or 22
	self:at(at, function()
		self:cyl("MuzzleBrake", 16, d, CF(0, 0, -8), F.nitride)
		if self.high then
			for index = 0, 5 do
				local angle = index / 6 * math.pi * 2
				local width = index == 3 and 12 or 4
				self:box("MuzzleProng", V(width, 3.5, 30), CFrame.Angles(0, 0, angle) * CF(0, d / 2 - 1.75, -31), F.nitride)
			end
			self:crown("MuzzleBrake", 8, d, 9, CF(0, 0, -50), F.nitride)
			-- The bore's dark core runs back 1 mm into the collar (ending 1 mm short of it, it floated).
			self:cyl("Bore", 32, 8, CF(0, 0, -31), F.bore)
		else
			self:cyl("MuzzleBrake", 38, d, CF(0, 0, -35), F.nitride)
		end
	end)
	return -54
end

-- Ridges round an axis: knurling, castle-nut notches, the forward assist's grip. Each ridge is a short
-- radial bar that starts `inner` out from the axis rather than crossing it, so no two share a patch of
-- their end planes (bars through the centre all overlap there, which the z-fight pass flags).
--   `at`'s Z is the axis; `thickness` is along it.
function Builder:ridges(name, count, inner, outer, width, thickness, at, look)
	local frame = place(at)
	for index = 0, count - 1 do
		local angle = index / count * math.pi * 2
		self:box(name, V(width, outer - inner, thickness), frame * CFrame.Angles(0, 0, angle) * CF(0, (inner + outer) / 2, 0), look)
	end
end

-- A muzzle brake: a collar, then chambers whose side ports are real gaps between a top and a bottom
-- bar, solid rings between the chambers, the bore showing through the ports, and a crown.
function Builder:brake(at, diameter, length)
	local d = diameter or 24
	local l = length or 60
	self:at(at, function()
		local ports, ring, collar, crown = 3, 6, 10, 6
		local port = (l - collar - crown - (ports - 1) * ring) / ports
		self:cyl("MuzzleBrake", collar, d, CF(0, 0, -collar / 2), F.nitride)
		local z = -collar
		for index = 1, ports do
			for _, sy in ipairs(SIGNS) do
				self:box("MuzzleBrake", V(d * 0.86, d * 0.3, port), CF(0, sy * d * 0.3, z - port / 2), F.nitride)
			end
			z -= port
			if index < ports then
				self:cyl("MuzzleBrake", ring, d, CF(0, 0, z - ring / 2), F.nitride)
				z -= ring
			end
		end
		self:cyl("Bore", l - collar - crown - 2, d * 0.34, CF(0, 0, -collar - (l - collar - crown) / 2), F.bore)
		self:crown("MuzzleBrake", crown, d, 9, CF(0, 0, z - crown / 2), F.nitride)
	end)
	return -l
end

-- A suppressor can: a tube with a knurled collar, an end cap with a bore.
function Builder:suppressor(at, diameter, length)
	local d = diameter or 38
	local l = length or 170
	self:at(at, function()
		self:cyl("Suppressor", 24, d - 4, CF(0, 0, -12), F.nitride)
		self:ridges("SuppressorKnurl", 12, d / 2 - 5, d / 2 - 0.5, 3, 18, CF(0, 0, -12), F.nitride)
		self:cyl("Suppressor", l - 34, d, CF(0, 0, -24 - (l - 34) / 2), F.anodizedDark)
		self:cyl("Suppressor", 10, d - 3, CF(0, 0, -l + 5), F.nitride)
		self:detail(function()
			self:cyl("SuppressorBore", 2, 9, CF(0, 0, -l - 1 + RELIEF), F.bore)
		end)
	end)
	return -l
end

-- A flip-up rear aperture sight standing on a rail, aperture centre `height` above the rail top.
function Builder:rearAperture(at, height)
	self:at(at, function()
		self:box("RearSightBase", V(24, 9, 34), CF(0, 4.5, 0), F.anodizedDark)
		-- The tower rises to the ring, and the ring is four bars round a real hole, so the front post
		-- shows through it. The hole is the large (0.2 in) aperture, sized for the eye close behind it:
		-- the small one read as a black slab with a pinhole from where the eye sits.
		local outer, hole = 17, 7.5
		local bar = (outer - hole) / 2
		local ringBottom = height - outer / 2
		self:box("RearSightTower", V(12, ringBottom - 7, 5), CF(0, 7 + (ringBottom - 7) / 2, 4), F.anodizedDark)
		self:box("RearSight", V(outer, bar, 5), CF(0, height + hole / 2 + bar / 2, 4), F.anodizedDark)
		self:box("RearSightRing", V(outer, bar, 5), CF(0, height - hole / 2 - bar / 2, 4), F.anodizedDark)
		for _, sx in ipairs(SIGNS) do
			self:box("RearSightRing", V(bar, hole, 5), CF(sx * (hole / 2 + bar / 2), height, 4), F.anodizedDark)
		end
		self:detail(function()
			self:cylX("RearSightKnob", 6, 11, CF(15, 5, -6), F.anodizedDark)
		end)
	end)
end

-- The plate an aperture ring (a 10 mm shell) is set in between a rear sight's ears: a web from the
-- sight base up to the ring and a bar either side of it, so the ring is carried rather than hanging in
-- the air. `base` is the top of what it stands on and `ring` the ring's centre; the hole stays clear.
function Builder:aperturePlate(at, base, ring, finish)
	self:at(at, function()
		self:box("RearSightPlate", V(14, ring - 5 - base + 0.5, 3), CF(0, (base + ring - 5.5) / 2 + 0.25, 0), finish)
		for _, sx in ipairs(SIGNS) do
			self:box("RearSightPlate", V(2.5, 11, 3), CF(sx * 5.25, ring + 0.5, 0), finish)
		end
	end)
end

-- A flip-up front post in protective ears, its tip `height` above the rail top.
function Builder:frontPost(at, height)
	self:at(at, function()
		self:box("FrontSightBase", V(24, 9, 30), CF(0, 4.5, 0), F.anodizedDark)
		for _, sx in ipairs(SIGNS) do
			self:box("FrontSightEar", V(4, height - 5, 16), CF(sx * 9, 9 + (height - 5) / 2, 0), F.anodizedDark)
		end
		self:box("FrontSightPost", V(4, height - 17, 4), CF(0, 9 + (height - 17) / 2, 0), F.anodizedDark)
		-- The part named FrontSight is the tip the aim lines up over; its top is the sight line.
		self:box("FrontSight", V(2.4, 8, 3), CF(0, height - 4, 0), F.anodizedDark)
	end)
end

-- A tube red dot on a riser, standing on a rail. Its body is a hollow shell so aiming actually looks
-- through it; the dot floats in the front glass. Returns the sight-line height above the rail.
function Builder:redDot(at)
	local h = 40
	self:at(at, function()
		self:box("SightMount", V(26, 10, 40), CF(0, 5, 0), F.anodizedDark)
		self:detail(function()
			self:box("SightMountLever", V(5, 8, 22), CF(-15.5, 5, 4), F.anodizedDark)
			self:cylX("SightMountNut", 5, 9, CF(15.5, 5, -6), F.steel)
		end)
		self:box("SightRiser", V(18, 14, 30), CF(0, 17, 0), F.anodizedDark)
		self:shell("Sight", 96, 34, 4, CF(0, h, 0), F.anodized)
		self:shell("SightBell", 10, 38, 5, CF(0, h, -53), F.anodized)
		self:shell("SightBell", 10, 37, 4.5, CF(0, h, 53), F.anodized)
		self:detail(function()
			self:cylY("SightTurret", 8, 15, CF(0, h + 19, -8), F.anodized)
			self:cylY("SightTurretCap", 5, 12, CF(0, h + 25.5, -8), F.anodizedDark)
			self:cylX("SightTurret", 8, 15, CF(19, h, -8), F.anodized)
			self:cylX("SightTurretCap", 5, 12, CF(25.5, h, -8), F.anodizedDark)
			self:cylX("SightDial", 7, 14, CF(-19.5, h, 10), F.anodizedDark)
		end)
		self:cyl("SightLens", 1.5, 30, CF(0, h, -40), F.sightCoated)
		self:cyl("SightLens", 1.5, 29, CF(0, h, 44), F.sightLens)
		self:ball("SightDot", 1.4, CF(0, h, -37), F.redDot)
	end)
	return h
end

-- A holographic sight: a battery housing on a base, a squared hood over a window, a glass plate
-- front and back, and the reticle -- a ring of light with a dot in it -- in the front plate.
function Builder:holo(at)
	local h = 38
	self:at(at, function()
		self:prism("SightBase", V(34, 12, 94), CF(0, 6, 0), 3, F.anodizedDark, "top")
		self:detail(function()
			for index = 0, 1 do
				self:box("SightButton", V(9, 4, 7), CF(-7 + index * 14, 12 + 2, 38), F.rubber)
			end
			self:cylX("SightBattery", 36, 14, CF(0, 7, -33), F.anodized)
			self:box("SightMountBolt", V(5, 9, 12), CF(-19.5, 5, 12), F.steel)
		end)
		local window = 28
		local wall = 4
		for _, sx in ipairs(SIGNS) do
			self:box("SightHood", V(wall, window + 7, 62), CF(sx * (window / 2 + wall / 2), h - 3.5, 8), F.anodized)
		end
		self:prism("SightHood", V(window + wall * 2 + 2, 7, 66), CF(0, h + window / 2 + 3.5, 8), 2.5, F.anodized, "top")
		self:box("Sight", V(window, 5, 58), CF(0, h - window / 2 - 2.5, 8), F.anodizedDark)
		-- The body the window stands on, down to the base, so the hood isn't held up by nothing.
		self:box("SightBody", V(window + wall * 2 - 2, 8.5, 54), CF(0, 15.75, 8), F.anodizedDark)
		-- The glass plates are set 1 mm into the hood's walls, roof and floor all round (a hair smaller than
		-- the window, they hung in it), and the reticle lies on the front plate's back face.
		self:box("SightLens", V(window + 2, window + 2, 1.5), CF(0, h, -18), F.sightCoated)
		self:box("SightLens", V(window + 2, window + 2, 1.5), CF(0, h, 34), F.sightLens)
		self:detail(function()
			local segments = 16
			local radius = 6.5
			-- The ring runs right through the glass, standing more than the z-fight gap proud of both its
			-- faces: lying on the front face, all sixteen segments fought it.
			for index = 0, segments - 1 do
				local angle = index / segments * math.pi * 2
				self:box("SightReticle", V(2.6, 0.7, 4), CF(0, h, -18) * CFrame.Angles(0, 0, angle) * CF(0, radius, 0), F.redDot)
			end
		end)
		self:ball("SightDot", 1.2, CF(0, h, -18), F.redDot)
	end)
	return h
end

-- A scope on a cantilever mount. `kind` is "lpvo" (short, low power) or "long" (a precision scope
-- with a big objective and tall turrets). Aiming hands over to the full-screen scope view once the
-- gun is up, so the tube is solid; the part named Scope marks the gun as scoped and carries the
-- sight line. Returns the axis height above the rail.
function Builder:scope(at, kind)
	local long = kind == "long"
	local h = long and 52 or 46
	local tube = long and 34 or 30
	local body = long and 150 or 120
	-- Staves round the scope's hollow parts (rings, tube, saddle, bells, eyepiece), all alike.
	local sides = 10
	self:at(at, function()
		-- Mount: a base clamped to the rail, two rings.
		self:box("ScopeMount", V(28, 10, body + 20), CF(0, 5, 6), F.anodizedDark)
		self:detail(function()
			for _, z in ipairs({ -body * 0.28, body * 0.34 }) do
				self:cylX("ScopeMountNut", 5, 10, CF(16.5, 5, z), F.steel)
			end
		end)
		for _, z in ipairs({ -body * 0.3, body * 0.32 }) do
			-- The post is FINE shorter than the ring at each end. Measured, not derived: the audit reports
			-- both spanning 16.1..36.3 mm along the bore at a scope station -- the same two planes, both
			-- facing the same way -- and dropping the post to 18 - 2 * FINE takes TouchGrassScout from 11
			-- written flush pairs to 7. (Local part sizes cannot be compared here: a shell segment is
			-- rotated, so its local Z is not the ring's axis. Face positions are the only readable unit.)
			self:box("ScopeStanchion", V(20, h - tube / 2 - 10 + 2, 18 - 2 * FINE), CF(0, 10 + (h - tube / 2 - 10) / 2, z), F.anodizedDark)
			self:shell("ScopeRing", 18, tube + 8, 4, CF(0, h, z), F.anodizedDark, sides)
			self:detail(function()
				for _, sx in ipairs(SIGNS) do
					self:box("ScopeRingScrew", V(6, 5, 5), CF(sx * (tube / 2 + 6), h + 2, z), F.steel)
				end
			end)
		end
		-- Tube, turret saddle. The whole scope is hollow along its axis: staves round the bore, rings and
		-- bells as open shells, glass that's barely tinted, and a fine reticle in the objective, so
		-- aiming in you see the target through it rather than a black disc (fully aimed, the
		-- full-screen scope takes over). The part named Scope, which marks the gun as scoped and carries
		-- the sight line, is an invisible rod down the axis.
		self:shell("ScopeTube", body, tube, 2.5, CF(0, h, 0), F.anodized, sides)
		local marker = self:box("Scope", V(1, 1, body), CF(0, h, 0), F.anodized)
		marker.Transparency = 1
		marker.CastShadow = false
		self:shell("ScopeSaddle", 40, tube + 5, 2.5, CF(0, h, -4), F.anodized, sides)
		local turret = long and 24 or 18
		local turretHeight = long and 20 or 13
		self:cylY("ScopeTurret", turretHeight, turret, CF(0, h + tube / 2 + 2 + turretHeight / 2, -4), F.anodized)
		self:cylX("ScopeTurret", turretHeight, turret, CF(tube / 2 + 2 + turretHeight / 2, h, -4), F.anodized)
		self:detail(function()
			-- Knurled caps: fine ribs around each turret.
			self:ridges("ScopeKnurl", 16, turret / 2 - 2, turret / 2 + 0.75, 1.8, turretHeight * 0.55,
				CF(0, h + tube / 2 + 2 + turretHeight * 0.62, -4) * A(-90, 0, 0), F.anodizedDark)
			self:ridges("ScopeKnurl", 16, turret / 2 - 2, turret / 2 + 0.75, 1.8, turretHeight * 0.55,
				CF(tube / 2 + 2 + turretHeight * 0.62, h, -4) * A(0, 90, 0), F.anodizedDark)
			self:box("ScopeTurretMark", V(1.4, 1.2, 4), CF(0, h + tube / 2 + 2 + turretHeight + 0.2, -4 - turret / 2 + 3), F.bright)
			if long then
				self:cylX("ScopeParallax", 14, 26, CF(-(tube / 2 + 9), h, -4), F.anodized)
			end
		end)
		-- Objective: a shoulder stepping out to the bell, a sunshade, and the glass.
		local objective = long and 56 or 42
		local front = -body / 2
		local shoulder = tube + (objective - tube) * 0.45
		-- The shoulder runs 2 mm into the bell, and the bell's wall reaches in past the shoulder's outside,
		-- so the objective end is joined to the tube rather than two open rings touching at a plane.
		self:shell("ScopeShoulder", 20, shoulder, (shoulder - tube) / 2 + 2.5, CF(0, h, front - 10), F.anodized, sides)
		self:shell("ScopeBell", long and 58 or 30, objective, (objective - shoulder) / 2 + 1.5, CF(0, h, front - 18 - (long and 29 or 15)), F.anodized, sides)
		local bellFront = front - 18 - (long and 58 or 30)
		self:detail(function()
			self:shell("ScopeRim", 5, objective + 3, 3, CF(0, h, bellFront + 6), F.anodizedDark, sides)
		end)
		self:cyl("ScopeLens", FINE, objective - 6, CF(0, h, bellFront - FINE / 2), F.sightCoated)
		-- A duplex reticle just behind the objective glass: fine lines toward the middle, heavier posts
		-- out to the edge, a clear gap where they'd meet so the aim point itself is never covered.
		local reach = objective / 2 - 2.5 -- the posts run into the bell's wall, so they're held by it
		local reticleZ = bellFront + 3
		for index = 0, 3 do
			local turn = CFrame.Angles(0, 0, index * math.pi / 2)
			self:box("ScopeReticle", V(0.5, reach * 0.55 - 1.2, 0.5), CF(0, h, reticleZ) * turn * CF(0, 1.2 + (reach * 0.55 - 1.2) / 2, 0), F.shadow)
			self:box("ScopeReticle", V(1.4, reach * 0.45, 0.5), CF(0, h, reticleZ) * turn * CF(0, reach * 0.55 + reach * 0.225, 0), F.shadow)
		end
		-- Ocular: the power ring with its throw lever, the eyepiece, a rubber eye cup. The power ring's wall
		-- reaches in to the tube's bore, so its front face bears on the tube's end all round (with a wall
		-- only as deep as the tube is wide, the two touched along a circle and the ocular hung off the lens).
		local back = body / 2
		self:shell("ScopePowerRing", 24, tube + 10, 7.5, CF(0, h, back + 12), F.anodizedDark, sides)
		self:detail(function()
			self:ridges("ScopeKnurl", 20, (tube + 10) / 2 - 2, (tube + 12) / 2, 2, 14, CF(0, h, back + 12), F.anodizedDark)
			self:box("ScopeThrowLever", V(6, 16, 8), CF(0, h + tube / 2 + 10, back + 12), F.anodized)
		end)
		local eyepiece = long and 44 or 40
		self:shell("ScopeEyepiece", long and 46 or 38, eyepiece, (eyepiece - tube) / 2 + 3, CF(0, h, back + 24 + (long and 23 or 19)), F.anodized, sides)
		local eyeBack = back + 24 + (long and 46 or 38)
		self:shell("ScopeEyecup", 10, eyepiece + 2, 4, CF(0, h, eyeBack + 5), F.rubber, sides)
		-- The ocular glass sits inside the eye cup, its edge in the cup's wall.
		self:cyl("ScopeLens", FINE, eyepiece - 2, CF(0, h, eyeBack + 5), F.sightLens)
	end)
	return h
end

-- A vertical foregrip on a rail clamp. `at` is on the rail's surface, the grip hanging below.
function Builder:foregrip(at)
	self:at(at, function()
		self:box("ForeGripClamp", V(30, 12, 34), CF(0, -6, 0), F.polymerDark)
		self:detail(function()
			self:cylX("ForeGripScrew", 6, 8, CF(18, -6, 0), F.steel)
		end)
		self:at(CF(0, -12, 0) * A(-8, 0, 0), function()
			self:rounded("ForeGrip", V(28, 30, 76), CF(0, -38, 0) * A(90, 0, 0), 11, F.polymer)
			self:detail(function()
				for index = 0, 3 do
					self:box("ForeGripRib", V(31, 3, 3), CF(0, -24 - index * 12, -12.5), F.polymerDark)
				end
				self:cylY("ForeGripCap", 6, 26, CF(0, -79, 0), F.polymerDark)
			end)
		end)
	end)
end

-- A weapon light on a side rail clamp, pointing forward.
function Builder:weaponLight(at)
	self:at(at, function()
		self:box("TorchMount", V(12, 22, 30), CF(0, 0, 0), F.anodizedDark)
		self:cyl("Torch", 90, 24, CF(12, 0, -8), F.anodized)
		self:cyl("TorchBezel", 22, 30, CF(12, 0, -64), F.anodized)
		self:detail(function()
			for index = 0, 5 do
				self:box("TorchFin", V(26, 2.4, 40), CF(12, 0, -20 - index * FINE) * CFrame.Angles(0, 0, index / 6 * math.pi), F.anodizedDark)
			end
			self:cyl("TorchTail", 12, 20, CF(12, 0, 42), F.rubber)
		end)
		self:cyl("TorchLens", 2, 25, CF(12, 0, -74 + RELIEF), finish(255, 248, 225, Mat.Glass, 0.3, 0.2))
	end)
end

-- A laser module: a box with an emitter and an aiming lens. The viewmodel throws a beam from the
-- part named LaserEmitter while you aim.
function Builder:laserModule(at)
	self:at(at, function()
		self:prism("LaserBody", V(28, 24, 72), CF(0, 0, 0), 3, F.polymerDark)
		self:box("LaserMount", V(22, 8, 30), CF(0, 16, 4), F.anodizedDark)
		self:detail(function()
			self:box("LaserSwitch", V(8, 6, 14), CF(-9, 3, 36 + 7), F.rubber)
			self:cyl("LaserLens", 3, 10, CF(7, -4, -36 - 1.5 + RELIEF - 3), F.glass)
		end)
		self:cyl("LaserEmitter", 3, 6, CF(-7, -4, -36 - 1.5 + RELIEF - 3), F.laser)
	end)
end

-- A two-leg bipod folded forward under the barrel, hanging from a clamp at `at`.
function Builder:bipod(at, deployed)
	self:at(at, function()
		self:box("BipodMount", V(34, 16, 30), CF(0, -8, 0), F.anodizedDark)
		for _, sx in ipairs(SIGNS) do
			if deployed then
				self:at(CF(sx * 12, -16, 0) * A(0, 0, sx * 14), function()
					self:cylY("Bipod", 150, 10, CF(0, -75, 0), F.anodizedDark)
					self:cylY("Bipod", 70, 8, CF(0, -170, 0), F.steel)
					self:ball("BipodFoot", 14, CF(0, -206, 0), F.rubber)
				end)
			else
				self:at(CF(sx * 11, -20, 6), function()
					self:cyl("Bipod", 160, 10, CF(0, 0, -80), F.anodizedDark)
					self:cyl("Bipod", 40, 8, CF(0, 0, -180), F.steel)
					self:ball("BipodFoot", 13, CF(0, 0, -202), F.rubber)
				end)
			end
		end
	end)
end

-- A sling swivel: a loop standing off a side.
function Builder:slingLoop(at)
	self:detail(function()
		self:at(at, function()
			self:box("SlingLoop", V(4, 4, 18), CF(0, -7, 0), F.steel)
			for _, sz in ipairs(SIGNS) do
				self:box("SlingLoop", V(4, 10, 4), CF(0, -2, sz * 7), F.steel)
			end
		end)
	end)
end

-- Inlay along a side: a border above and below and a scrolling vine between them, each stroke laid end
-- to end with the next so no two overlap in the surface. `at` sits ON the surface (its x is the face),
-- so the inlay stands FINE proud of it. Gold by default; `look` changes it (dark inlay on a gold gun).
function Builder:engraving(at, length, height, look)
	if not self.micro then
		return
	end
	local inlay = look or F.goldDeep
	self:at(at, function()
		for _, sy in ipairs(SIGNS) do
			self:box("Engraving", V(FINE * 2, 1.1, length), CF(0, sy * height / 2, 0), inlay)
		end
		local waves = math.max(1, math.floor(length / 38 + 0.5))
		local steps = waves * 10
		local amplitude = height * 0.26
		local previous = nil
		for index = 0, steps do
			local t = index / steps
			local point = V(0, math.sin(t * waves * math.pi * 2) * amplitude, -length / 2 + 3 + t * (length - 6))
			if previous then
				local middle = (previous + point) / 2
				local stroke = point - previous
				self:box("Engraving", V(FINE * 2, 0.9, stroke.Magnitude), CFrame.lookAt(middle, middle + stroke), inlay)
			end
			-- A leaf off each crest.
			if index % 10 == 5 then
				local side = (math.floor(index / 10) % 2 == 0) and -1 or 1
				self:box("Engraving", V(FINE * 2, 0.9, height * 0.2), CF(point + V(0, side * height * 0.09, 2.5)) * A(side * 35, 0, 0), inlay)
			end
			previous = point
		end
	end)
end

-- A box magazine hanging from `at` (the middle of its top), built down its length in segments.
--   spec.width, spec.depth   across and front to back, mm
--   spec.segments            { {length, degrees}, ... } from the top down; positive degrees curve
--                            the bottom forward. Each segment turns about its FRONT edge and the
--                            wedge of a gap that opens at the back is filled exactly, so the curve
--                            has no steps and no two faces lie over each other in a plane. The old
--                            magazines overlapped rotated boxes, which kinked visibly at every joint
--                            and left the z-fight pass nudging their sides apart.
--   spec.ribs                "stanag" (two long pressed ribs a side, a stepped front spine and the
--                            catch window), "across" (the AK's pressed cross ribs) or nil
--   spec.caliber             diameter of the round showing in the feed lips, mm (nil for none)
--   spec.plate               the base plate's finish (default: the rarity's small-part finish)
function Builder:magazine(name, spec, at, look)
	local w, d = spec.width, spec.depth
	self:at(at, function()
		local frame = CFrame.identity
		for index, segment in ipairs(spec.segments) do
			local length, degrees = segment[1], segment[2]
			if degrees > 0 then
				if index > 1 then
					local gap = d * math.tan(math.rad(degrees))
					self:wedge(name .. "Joint", V(w, gap, d), frame * CF(0, -gap / 2, 0) * CFrame.Angles(0, 0, math.pi), look)
				end
				frame = frame * CF(0, 0, -d / 2) * A(degrees, 0, 0) * CF(0, 0, d / 2)
			end
			self:box(name, V(w, length, d), frame * CF(0, -length / 2, 0), look)
			if self.micro and spec.ribs == "stanag" then
				local top = index == 1 and 34 or 0
				local ribLength = length - top
				for _, sx in ipairs(SIGNS) do
					for _, rz in ipairs({ -0.2, 0.2 }) do
						self:box(name .. "Rib", V(FINE * 2, ribLength, 5), frame * CF(sx * w / 2, -top - ribLength / 2, rz * d), look)
					end
				end
				self:box(name .. "Spine", V(w * 0.46, length, FINE * 2), frame * CF(0, -length / 2, -d / 2), look)
				if index == 1 then
					self:box(name .. "Catch", V(FINE * 2, 9, 11), frame * CF(-w / 2, -22, d / 2 - 15), F.shadow)
				end
			elseif self.micro and spec.ribs == "across" then
				local bands = math.max(1, math.floor(length / 26))
				for band = 1, bands do
					self:box(name .. "Rib", V(w + FINE * 2, 5, d - 16), frame * CF(0, -length * band / (bands + 1), 3), look)
				end
			end
			frame = frame * CF(0, -length, 0)
		end
		self:prism(name .. "Plate", V(w + 4, 7, d + 5), frame * CF(0, -3.5, -1), 2, spec.plate or self:finish("small"), "bottom")
		if spec.caliber then
			-- Feed lips and the top round: a brass case with its copper bullet pointing forward.
			local c = spec.caliber
			for _, sx in ipairs(SIGNS) do
				self:box(name .. "Lip", V(2.5, 4, d * 0.62), CF(sx * (w / 2 - 1.25), 2, d * 0.1), look)
			end
			self:cyl(name .. "Round", d * 0.58, c, CF(-w * 0.12, c / 2 - 1, d * 0.12), F.brass)
			self:cyl(name .. "Bullet", d * 0.2, c * 0.8, CF(-w * 0.12, c / 2 - 1, d * 0.12 - d * 0.39), F.copper)
		end
	end)
end

-- A drum magazine: a feed tower into the magwell and the drum below it, a raised cover with a ring of
-- rivets and the winding key in the middle of each side.
function Builder:drumMag(name, diameter, thickness, at, look)
	self:at(at, function()
		self:box(name, V(20, 42, 34), CF(0, -21, 0), look)
		local centre = CF(0, -42 - diameter / 2 + 8, -2)
		self:cylX(name, thickness, diameter, centre, look)
		for _, sx in ipairs(SIGNS) do
			self:cylX(name .. "Cover", RELIEF, diameter * 0.8, centre * CF(sx * (thickness / 2 + RELIEF / 2), 0, 0), F.polymerDark)
			self:cylX(name .. "Key", RELIEF * 2, 16, centre * CF(sx * (thickness / 2 + RELIEF * 2), 0, 0), self:finish("small"))
			self:box(name .. "KeyBar", V(RELIEF, 5, 24), centre * CF(sx * (thickness / 2 + RELIEF * 3 + RELIEF / 2), 0, 0), self:finish("small"))
			if self.micro then
				for index = 0, 7 do
					local angle = index / 8 * math.pi * 2
					self:cylX(name .. "Rivet", FINE * 2, 4, centre * CF(sx * (thickness / 2 + RELIEF + FINE), math.cos(angle) * diameter * 0.32, math.sin(angle) * diameter * 0.32), F.steel)
				end
			end
		end
	end)
end

-- A pistol grip hanging from `at` (the middle of its top, where it meets the frame), raked back `rake`
-- degrees. Its cross-section is a teardrop, the way a real grip's is: a narrow rounded front strap, a
-- wide rounded backstrap and flanks tapering between them. The old grip was a rounded brick.
--   spec.length, spec.depth   mm
--   spec.front, spec.back     front strap and backstrap widths
--   spec.nub                  an A2 grip's finger nub on the front strap
--   spec.grooves              finger grooves down the front strap
-- Polymer grips come out in textured plastic. The core carries the name Grip. Returns the grip's
-- frame, for anything hung off it.
function Builder:grip(at, rake, look, spec)
	local frame = place(at) * A(-(rake or 18), 0, 0)
	local length = spec.length or 100
	local depth = spec.depth or 46
	local wf = spec.front or 22
	local wb = spec.back or 30
	local zf = -depth / 2 + wf / 2
	local zb = depth / 2 - wb / 2
	-- spec.top carries the grip's front (its core and front rounding) that far on up past its top, into the
	-- frame above: a raked grip's top edge dips below a level frame at the front, and this fills that
	-- wedge instead of leaving air. spec.name renames the pieces (a magazine's grip-shaped extension).
	local top = spec.top or 0
	local name = spec.name or "Grip"
	if look.material == Mat.SmoothPlastic then
		look = finishOf(look.color:Lerp(Color3.new(0, 0, 0), 0.08), Mat.Plastic)
	end
	self:at(frame, function()
		self:box(name, V(wf, length + top, zb - zf), CF(0, (top - length) / 2, (zf + zb) / 2), look)
		self:cylY(name .. "Front", length + top - FINE * 2, wf, CF(0, (top - length) / 2, zf), look)
		self:cylY(name .. "Back", length - FINE * 2, wb, CF(0, -length / 2, zb), look)
		if wb - wf >= 1 then
			for _, sx in ipairs(SIGNS) do
				self:wedge(name .. "Flank", V(length, (wb - wf) / 2, zb - zf),
					CFrame.fromMatrix(V(sx * (wf / 2 + (wb - wf) / 4), -length / 2, (zf + zb) / 2), V(0, -sx, 0), V(sx, 0, 0), V(0, 0, 1)), look)
			end
		end
		if spec.nub then
			self:cylX(name .. "Nub", wf - 4, 13, CF(0, -length * 0.36, -depth / 2 + 3.5), look)
		end
		for index = 1, spec.grooves or 0 do
			self:cylX(name .. "Groove", wf - 4, 9, CF(0, -length * (0.14 + index * 0.21), -depth / 2 + 2), look)
		end
	end)
	return frame
end

--------------------------------------------------------------------------------
-- Silhouettes
--------------------------------------------------------------------------------

local STYLES = {}

-- A ventilated heat shield over the top of a barrel: a half shell of staves standing off the barrel,
-- with rows of vent slots down its upper flanks. Cutting the staves into segments made the top line
-- read as battlements from the side; a real shield's outline is smooth and its vents are in its face.
function Builder:heatShield(at, length, radius, barrel)
	barrel = barrel or radius - 8
	self:at(at, function()
		for _, degrees in ipairs({ -72, -36, 0, 36, 72 }) do
			local around = CFrame.Angles(0, 0, math.rad(degrees))
			local width = 2 * radius * math.tan(math.pi / 10) + 0.5
			self:box("Shroud", V(width, 2.5, length), around * CF(0, radius, 0), F.nitride)
			if math.abs(degrees) == 36 then
				local vents = math.floor((length - 20) / 24)
				for index = 0, vents - 1 do
					self:box("ShroudVent", V(width * 0.5, FINE * 2, 14), around * CF(0, radius + 1.25, -(vents - 1) * 12 + index * 24), F.shadow)
				end
			end
		end
		-- The clamp: a plate each side down past the barrel, and a strap under the barrel between them,
		-- so the shield is held on the barrel rather than hovering round it.
		local top, bottom = radius * 0.25, -(barrel + 3.5)
		for _, sx in ipairs(SIGNS) do
			self:box("ShroudClamp", V(4, top - bottom, 18), CF(sx * radius * 0.95, (top + bottom) / 2, -length / 2 + 14), F.nitride)
		end
		self:box("ShroudClamp", V(radius * 1.9 + 3, 4, 16), CF(0, -(barrel + 1.5), -length / 2 + 14), F.nitride)
	end)
end

-- The AR family, measured off an M4 carbine: a flat-top upper with the ejection port, forward assist and
-- brass deflector, a lower whose rear rises into the buffer tower, a flared magwell, a free-float
-- M-LOK handguard with real slots, a curved 30-round magazine, a stock covering nearly all of its
-- buffer tube, and a birdcage. Trigger at z=0, bore at y=0: the upper runs from -18 to +21 with its
-- rail to +30.5, the lower down to -48 and the magwell to -68, which is why the magazine and grip hang
-- as low as they do on the real thing.
--
-- The same machinery builds every AR-pattern gun at its own proportions: `spec.scale`
-- enlarges the whole receiver group for the .308 AR-10s and the 12-gauge MKA-style shotgun (their
-- receivers really are that much bigger), and the rest of `spec` swaps the parts that differ.
--   spec.scale        receiver scale (1 for 5.56)
--   spec.hgLength     handguard length, spec.barrelEnd where the barrel stops (both before scaling)
--   spec.barrelDia    barrel diameter
--   spec.muzzle       "birdcage", "brake" or "choke"
--   spec.optic        nil (red dot, or the variant's holo/irons), "lpvo" or "long"
--   spec.mag          a function(g) building the magazine, or nil for a STANAG
--   spec.stock        "m4" or "precision"
--   spec.heatShield, spec.bipod, spec.flutes
local function buildAR(g, spec)
	spec = spec or {}
	local v = g.variant
	g.scale = spec.scale or 1
	local receiver = g:finish("receiver")
	local handguardFinish = g:finish("handguard")
	local furniture = v.camo and F.fde or g:finish("furniture")
	local small = g:finish("small")
	local compact = v.compact
	local hgLength = spec.hgLength or (compact and 226 or 306)
	local barrelEnd = spec.barrelEnd or (compact and -380 or -480)
	local barrelDia = spec.barrelDia or 17

	-- Upper receiver: the right wall is built round a real ejection port with the bolt carrier recessed
	-- inside it, rather than a dark plate on the outside.
	local upper = g:prism("Receiver", V(30, 16, 170), CF(0, 13, -15), 4, receiver, "top")
	g:box("UpperWall", V(15, 23, 170), CF(-7.5, -6.5, -15), receiver)
	g:box("UpperWall", V(15, 8, 170), CF(7.5, -14, -15), receiver)
	g:box("UpperWall", V(15, 15, 72), CF(7.5, -2.5, 34), receiver)
	g:box("UpperWall", V(15, 15, 38), CF(7.5, -2.5, -81), receiver)
	g:box("EjectionPort", V(3.5, 15, 60), CF(5.25, -2.5, -32), F.shadow)
	g:group("bolt", function()
		g:box("BoltCarrier", V(11.5, 13, 44), CF(5.75, -2.5, -28), F.nitride)
		g:box("BoltLug", V(11.5, 5, 8), CF(5.75, -2.5, -54), F.steel)
	end)
	g:box("DustCover", V(2, 22, 58), CF(19.5, -20, -32) * A(0, 0, 60), receiver)
	g:detail(function()
		g:box("DustCoverLatch", V(4, 5, 8), CF(24, -26, -8) * A(0, 0, 60), F.steel)
	end)
	g:travel("bolt", 70)
	g:key("Eject", CF(20, -2, -32) * A(0, -70, 0))
	g:rail("UpperRail", 145, CF(0, 21, -22.5))
	g:detail(function()
		-- The forward assist boss and the brass deflector behind the port.
		g:cyl("ForwardAssist", 34, 17, CF(14, 9, 38), receiver)
		g:cyl("ForwardAssistButton", 7, 13, CF(14, 9, 58.5), F.anodizedDark)
		-- The knurled rim stands a little proud of the receiver's side, as the real knob does (level with
		-- it, the rib's end fought the receiver face).
		-- Turned an eighth of a rib, so no rib's side lies in the plane of the receiver's side.
		g:ridges("ForwardAssistRib", 8, 2.5, 8.8, 1.6, 1.6, CF(14, 9, 62.5) * CFrame.Angles(0, 0, math.pi / 8), F.anodizedDark)
		g:wedge("Deflector", V(8, 13, 16), CF(18.5, 10, 10) * A(0, 180, 0), receiver)
	end)

	-- Charging handle: the T-handle over the back of the upper, latch on the left.
	g:group("charge", function()
		g:box("ChargingHandle", V(16, 7, 40), CF(0, 24.5, 75), F.anodizedDark)
		g:prism("ChargingHandleWings", V(50, 9, 13), CF(0, 24.5, 101.5), 2.5, F.anodizedDark)
		g:detail(function()
			g:box("ChargingHandleLatch", V(9, 6, 11), CF(-21, 24.5, 90), small)
		end)
	end)
	g:travel("charge", 64)
	g:hand("ChargeHand", V(-30, 34, 104), V(0.75, -0.25, 0.6), V(-0.3, 1, 0.2))

	-- Lower receiver, the buffer tower rising at its back, the magwell hanging under its front.
	g:prism("Lower", V(26, 30, 190), CF(0, -33, 0), 3, receiver, "bottom")
	g:rounded("BufferTower", V(24, 36, 25), CF(0, -2, 82.5), 11, receiver)
	g:prism("MagWell", V(33, 22, 76), CF(0, -57, -57), 4, receiver, "bottom")
	g:wedge("MagWellFlare", V(33, 12, 14), CF(0, -62, -102), receiver)
	g:cyl("CastleNut", 8, 34, CF(0, -3, 99), F.parkerized)
	g:detail(function()
		g:ridges("CastleNutNotch", 8, 13, 18.25, 6, 5, CF(0, -3, 99), F.parkerized)
		g:cylX("MagRelease", 7, 11, CF(16.5, -38, -12), small)
		g:box("BoltCatch", V(3.5, 18, 10), CF(-14.75, -30, -10), small)
		g:at(CF(-15, -33, 40), function()
			g:cylX("Selector", 3.5, 12, CF(0, 0, 0), F.anodizedDark)
			g:box("SelectorLever", V(3.5, 5, 17), CF(-1, 0, -7) * A(-25, 0, 0), small)
		end)
		g:pin("PivotPin", 7, CF(0, -24, -88), F.anodizedDark, 33)
		g:pin("TakedownPin", 7, CF(0, -24, 64), F.anodizedDark, 33)
		g:pin("TriggerPin", 5, CF(0, -40, 4), F.steel, 33)
		g:pin("HammerPin", 5, CF(0, -40, 26), F.steel, 33)
	end)

	-- Trigger guard and trigger.
	g:box("TriggerGuard", V(12, 6, 58), CF(0, -73, 10), receiver)
	g:box("TriggerGuard", V(12, 24, 7), CF(0, -58, 38), receiver)
	g:group("trigger", function()
		g:box("Trigger", V(6, 20, 6), CF(0, -57, -2) * A(-12, 0, 0), small)
	end)
	g:swing("trigger", CF(0, -47, 0), 12)

	-- A2 pistol grip.
	g:grip(V(0, -48, 64), 22, furniture, { length = 106, depth = 48, front = 22, back = 31, nub = true })
	g:hand("GripHand", V(31, -88, 86), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- Magazine.
	g:group("mag", function()
		if spec.mag then
			spec.mag(g)
		else
			g:magazine("Magazine", { width = 22.5, depth = 62, segments = { { 62, 0 }, { 24, 4 }, { 24, 4 }, { 24, 4 }, { 24, 4 } }, ribs = "stanag", caliber = 9.5 },
				CF(0, -52, -57), F.anodizedDark)
		end
	end)
	g:key("MagWell", CF(0, -52, -57))
	g:hand("MagHand", V(-28, -120, -62), V(0.4, 0.25, -0.15), V(-1, -0.15, 0))

	-- Buffer tube and stock.
	if spec.stock == "precision" then
		-- A fixed precision stock: a long body over the tube with a raised cheek riser on posts, a lower
		-- hook running back to an adjustable butt plate, and a monopod under it.
		g:cyl("BufferTube", 60, 30, CF(0, -3, 133), F.anodizedDark)
		g:rounded("Stock", V(42, 44, 240), CF(0, -2, 222), 12, furniture)
		g:prism("StockCheek", V(36, 16, 150), CF(0, 36, 230), 5, furniture, "top")
		for _, z in ipairs({ 180, 280 }) do
			g:cylY("StockCheekPost", 12, 9, CF(0, 23, z), F.anodizedDark)
		end
		g:box("StockHook", V(32, 22, 176), CF(0, -82, 256), furniture)
		g:box("StockHook", V(34, 60, 30), CF(0, -41, 326), furniture)
		g:prism("Buttpad", V(46, 150, 18), CF(0, -38, 350), 4, F.rubber)
		g:detail(function()
			g:cylY("Monopod", 40, 16, CF(0, -113, 290), F.anodizedDark)
			g:cylY("MonopodFoot", 8, 24, CF(0, -137, 290), F.rubber)
			g:cylX("StockKnob", 10, 18, CF(25.5, 2, 230), F.anodizedDark)
		end)
	else
		-- M4 stock, riding most of the way up the tube as it does in its second position.
		g:cyl("BufferTube", 177, 30, CF(0, -3, 191.5), F.anodizedDark)
		g:at(CF(0, 0, 205), function()
			g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, furniture)
			g:prism("StockCheek", V(34, 8, 120), CF(0, 22, 10), 3, furniture, "top")
			g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), furniture)
			g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, F.rubber)
			g:box("StockLever", V(10, 12, 40), CF(0, -30, -32), F.polymerDark)
			g:detail(function()
				g:cylX("StockQD", 7, 14, CF(-23.5, -8, 50), F.anodizedDark)
				g:slingLoop(CF(0, -98, 70))
			end)
		end)
	end

	-- Handguard: a free-float M-LOK tube whose walls are frames, so the slots are holes with the
	-- barrel showing through.
	local hgFront = -103 - hgLength
	local hgZ = -103 - hgLength / 2
	local hw, hh = 44, 50
	g:at(CF(0, -4, hgZ), function()
		-- M-LOK slots are 7mm x 32mm on 40mm centres; these are a touch taller so they read at arm's length.
		local slab = (hh - 10) / 2
		g:prism("Handguard", V(hw, slab, hgLength), CF(0, hh / 2 - slab / 2, 0), 8, handguardFinish, "top")
		g:prism("Handguard", V(hw, slab, hgLength), CF(0, -hh / 2 + slab / 2, 0), 8, handguardFinish, "bottom")
		local slotLength, post = 32, 10
		local slots = math.floor((hgLength - 40) / (slotLength + post))
		local run = slots * slotLength + (slots + 1) * post
		local ends = (hgLength - run) / 2
		for _, sx in ipairs(SIGNS) do
			local x = sx * (hw / 2 - 2.5)
			for index = 0, slots do
				g:box("HandguardPost", V(5, 10, post), CF(x, 0, -run / 2 + post / 2 + index * (slotLength + post)), handguardFinish)
			end
			for _, sz in ipairs(SIGNS) do
				g:box("HandguardPost", V(5, 10, ends), CF(x, 0, sz * (run / 2 + ends / 2)), handguardFinish)
			end
		end
		g:box("HandguardCap", V(hw - 14, 10, 5), CF(0, 0, -hgLength / 2 + 6), F.anodizedDark)
		g:rail("HandguardRail", hgLength - 8, CF(0, hh / 2, 0))
		g:cylX("SlingCup", 7, 14, CF(-(hw / 2 + 3.5), -hh / 2 + 13, hgLength / 2 - 30), F.anodizedDark)
	end)
	g:hand("SupportHand", V(-10, -48, hgZ - hgLength * 0.1), V(0.8, 0.45, -0.3), V(-0.35, -1, 0))

	-- Barrel and muzzle device.
	g:cyl("Barrel", -100 - barrelEnd, barrelDia, CF(0, 0, (barrelEnd - 100) / 2), F.nitride)
	if spec.flutes then
		g:detail(function()
			local run = -hgFront + barrelEnd - 20
			for index = 0, 5 do
				local angle = (index + 0.5) / 6 * math.pi * 2
				g:box("Flute", V(4, FINE * 2, run), CF(0, 0, hgFront - 10 - run / 2) * CFrame.Angles(0, 0, angle) * CF(0, barrelDia / 2 - 0.5, 0), F.shadow)
			end
		end)
	end
	if spec.heatShield then
		g:heatShield(CF(0, 0, (hgFront + barrelEnd) / 2 - 10), -barrelEnd + hgFront - 40, barrelDia / 2 + 8)
	end
	local muzzleZ
	if spec.muzzle == "brake" then
		muzzleZ = barrelEnd + g:brake(CF(0, 0, barrelEnd), barrelDia + 9, 64)
	elseif spec.muzzle == "choke" then
		g:cyl("MuzzleBrake", 36, barrelDia + 5, CF(0, 0, barrelEnd - 18), F.nitride)
		g:detail(function()
			for index = 0, 3 do
				g:cyl("MuzzleBrakeRing", 4, barrelDia + 7.8, CF(0, 0, barrelEnd - 6 - index * 8), F.anodizedDark)
			end
		end)
		g:cyl("Bore", FINE, barrelDia - 3, CF(0, 0, barrelEnd - 36 - FINE / 2), F.bore)
		muzzleZ = barrelEnd - 38
	else
		muzzleZ = barrelEnd + g:birdcage(CF(0, 0, barrelEnd), 22)
	end
	g:key("Muzzle", CF(0, 0, muzzleZ))

	-- Sights, on the rail 30.5mm over the bore: a red dot or holo's window and the irons' aperture
	-- share the 66mm line an M4's own sights use; scopes sit higher on their mounts.
	local railTop = 30.5
	if spec.optic == "lpvo" or spec.optic == "long" then
		local h = g:scope(CF(0, railTop, -15), spec.optic)
		g:key("Sight", CF(0, railTop + h, 150))
		g.model:SetAttribute("Optic", "scope")
		g.model:SetAttribute("EyeRelief", 0.6)
	elseif v.holo then
		local h = g:holo(CF(0, railTop, -30))
		g:key("Sight", CF(0, railTop + h, 50))
		g.model:SetAttribute("Optic", "holo")
		g.model:SetAttribute("EyeRelief", 0.62)
	elseif v.irons then
		g:rearAperture(CF(0, railTop, 30), 36)
		g:frontPost(CF(0, -4 + hh / 2 + 9.5, hgFront + 26), 36 + (railTop - (-4 + hh / 2 + 9.5)))
		g:key("Sight", CF(0, railTop + 36, 40))
		g.model:SetAttribute("Optic", "iron")
		-- Cheek on the stock, the eye a few centimetres behind the aperture.
		g.model:SetAttribute("EyeRelief", 0.3)
	else
		local h = g:redDot(CF(0, railTop, -20))
		g:key("Sight", CF(0, railTop + h, 45))
		g.model:SetAttribute("Optic", "reddot")
		g.model:SetAttribute("EyeRelief", 0.66)
	end

	if v.foregrip then
		local z = hgZ - hgLength * 0.14
		g:foregrip(CF(0, -4 - hh / 2, z))
		g:hand("SupportHand", V(-27, -80, z + 6), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
	end
	if spec.bipod then
		g:bipod(CF(0, -4 - hh / 2, hgFront + 40))
	end
	if v.light then
		g:weaponLight(CF(-(hw / 2 + 6), 4, hgFront + 58) * A(0, 0, 180))
	end
	if v.laser then
		g:laserModule(CF(0, -4 - hh / 2 - 16, hgFront + 50))
	end
	if v.engraved or g.rarityIndex >= 5 then
		for _, sx in ipairs(SIGNS) do
			g:engraving(CF(sx * 13, -33, 30), 96, 16)
		end
	end

	g.model:SetAttribute("Action", spec.action or "ar")
	g.model:SetAttribute("Flash", v.suppressor and "suppressed" or spec.flash or "rifle")
	g.model:SetAttribute("Casing", spec.casing or "rifle")
	return upper
end

-- The .308 magazine for the AR-10s: straighter and deeper than a 5.56 one.
local function magazine308(g)
	g:magazine("Magazine", { width = 24, depth = 70, segments = { { 64, 0 }, { 30, 3 }, { 30, 3 } }, ribs = "stanag", caliber = 10.5 },
		CF(0, -52, -57), F.anodizedDark)
end

-- The AK, measured off an AKM: a long stamped receiver with a ribbed top cover and the rear sight
-- block at its front, the charging handle riding the bolt carrier on the right, the big safety
-- lever, a strongly curved ribbed magazine rocked into the receiver, wooden handguards over and
-- under the gas tube, the front sight tower and a slant brake, and a wooden stock whose top line
-- runs level with the bore.
local function buildAK(g)
	local v = g.variant
	local metal = g.skinned and g.skin or F.nitride
	local wood = v.woodFurniture and F.wood or g:finish("furniture")
	local small = g:finish("small")

	-- Receiver body, with a real ejection port in the right wall at high detail.
	local body
	if g.high then
		body = g:box("Receiver", V(15, 38, 297), CF(-7.5, -7, -36.5), metal)
		g:box("ReceiverWall", V(15, 18, 297), CF(7.5, -17, -36.5), metal)
		g:box("ReceiverWall", V(15, 20, 190), CF(7.5, 2, 17), metal)
		g:box("ReceiverWall", V(15, 20, 37), CF(7.5, 2, -166.5), metal)
		-- Stops short of the handguard, whose cap's side it otherwise lay level with.
		g:box("EjectionPort", V(3.5, 20, 64), CF(5.25, 2, -110), F.shadow)
	else
		body = g:box("Receiver", V(30, 38, 297), CF(0, -7, -36.5), metal)
		g:box("EjectionPort", V(3.5, 20, 70), CF(16.25, 2, -113), F.shadow)
	end
	-- The carrier and its charging handle, which reciprocate together.
	g:group("bolt", function()
		g:box("BoltCarrier", V(11.5, 16, 64), CF(5.75, 2, -114), F.steel)
		g:box("ChargingHandle", V(24, 7, 9), CF(22, 6, -86), F.steel)
		g:ball("ChargingKnob", 12, CF(36, 6, -86), F.steel)
	end)
	g:travel("bolt", 110)
	g:hand("ChargeHand", V(40, 26, -80), V(0.2, -1, 0.1), V(0.3, 0.2, 1))
	g:key("Eject", CF(20, 4, -113) * A(0, -75, 0))

	-- Top cover: rounded, ribbed, with the latch button out the back.
	g:prism("TopCover", V(29, 18, 262), CF(0, 21, -19), 7, metal, "top")
	g:detail(function()
		for index = 0, 2 do
			g:box("TopCoverRib", V(22, 5, 7), CF(0, 31.5, 20 + index * 30), metal)
		end
		g:cyl("CoverLatch", 12, 12, CF(0, 8, 118), F.steel)
		-- Rivets: trunnion and trigger group.
		for _, rivet in ipairs({ { -150, -18 }, { -165, -18 }, { -30, -24 }, { 15, -24 }, { 50, -24 }, { -150, 4 } }) do
			g:pin("Rivet", 6, CF(0, rivet[2], rivet[1]), F.steel, 30 + 7)
		end
	end)
	-- The safety lever: a long plate down the right side, pivoting at the back.
	g:group("safety", function()
		g:box("SafetyLever", V(3.5, 11, 118), CF(16.75, -2, 40) * A(-6, 0, 0), F.parkerized)
		g:box("SafetyTab", V(9, 12, 12), CF(20.5, -9, -16), F.parkerized)
	end)

	-- Rear sight block and leaf, on the trunnion at the front of the receiver.
	g:box("RearSightBlock", V(26, 14, 40), CF(0, 19, -166), metal)
	g:box("RearSight", V(18, 4, 62), CF(0, 30, -154) * A(-6, 0, 0), metal)
	g:detail(function()
		g:box("RearSightSlider", V(22, 7, 10), CF(0, 31, -170), metal)
		-- The notch is a real U: two blades with the front post showing between them, and a shallower
		-- web at the bottom, so the sight picture is the post's tip level with the blade tops.
		for _, sx in ipairs(SIGNS) do
			g:box("RearSightNotch", V(7.5, 13, 4), CF(sx * 5.25, 39.5, -124), metal)
		end
		g:box("RearSightNotch", V(3.5, 8, 3), CF(0, 38, -124), metal)
	end)

	-- Gas tube with the upper handguard over it, gas block, lower handguard round the barrel.
	g:cyl("GasTube", 30, 19, CF(0, 25, -334), metal)
	g:rounded("HandguardUpper", V(30, 20, 118), CF(0, 27, -245), 9, wood)
	g:box("GasBlock", V(24, 34, 26), CF(0, 12, -360), metal)
	g:rounded("Handguard", V(42, 44, 158), CF(0, -3, -224), 14, wood)
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			g:box("HandguardSwell", V(3.5, 16, 96), CF(sx * 22.75, -12, -230), wood)
		end
		g:cyl("HandguardFerrule", 8, 40, CF(0, -3, -307), metal)
		g:box("HandguardRetainer", V(34, 10, 24), CF(0, -4, -150), metal)
	end)
	g:hand("SupportHand", V(-6, -38, -220), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- Barrel, front sight tower, cleaning rod, slant brake.
	g:cyl("Barrel", 300, 18, CF(0, 0, -335), F.nitride)
	g:box("FrontSightBase", V(22, 24, 44), CF(0, 2, -478), metal)
	for _, sx in ipairs(SIGNS) do
		g:box("FrontSightEar", V(4, 36, 14), CF(sx * 10, 30, -482), metal)
	end
	g:box("FrontSightPost", V(4, 17.5, 4), CF(0, 22.75, -482), metal)
	g:box("FrontSight", V(2.4, 15, 3), CF(0, 38.5, -482), metal)
	g:detail(function()
		g:cyl("CleaningRod", 215, 6, CF(0, -15, -410), F.steel)
		g:box("BayonetLug", V(10, 8, 20), CF(0, -13, -468), metal)
	end)
	g:at(CF(0, 0, -500), function()
		g:cyl("MuzzleBrake", 36, 22, CF(0, 0, -18), F.nitride)
		g:detail(function()
			g:wedge("MuzzleBrakeSlant", V(22.5, 10, 18), CF(0, 6, -31) * A(0, 180, 0), F.nitride)
			g:cyl("Bore", FINE, 9, CF(0, 0, -36 - FINE / 2), F.bore)
		end)
	end)
	g:key("Muzzle", CF(0, 0, -536))

	-- Trigger guard, trigger, magazine release paddle.
	g:box("TriggerGuard", V(12, 5, 70), CF(0, -47, 2), metal)
	g:box("TriggerGuard", V(12, 22, 6), CF(0, -34, 36), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 20, 6), CF(0, -34, -4) * A(-12, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -26, -2), 12)
	g:box("MagRelease", V(20, 12, 8), CF(0, -32, -32) * A(-20, 0, 0), F.steel)

	-- Pistol grip.
	g:grip(V(0, -26, 78), 20, v.woodFurniture and F.woodDark or g:finish("furniture"), { length = 100, depth = 44, front = 22, back = 29, grooves = 0 })
	g:hand("GripHand", V(31, -64, 98), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- Magazine: the AK's strong curve, ribbed across the sides.
	g:group("mag", function()
		g:magazine("Magazine", { width = 26, depth = 72, segments = { { 38, 0 }, { 28, 8 }, { 28, 8 }, { 28, 8 }, { 28, 8 }, { 28, 8 } }, ribs = "across", caliber = 11 }, CF(0, -24, -80), F.steelMag)
	end)
	g:key("MagWell", CF(0, -24, -80))
	g:hand("MagHand", V(-30, -112, -120), V(0.4, 0.25, -0.2), V(-1, -0.15, 0))

	-- Stock: level top line, the lower edge sweeping down to the heel, a steel buttplate.
	g:at(CF(0, 0, 112), function()
		g:rounded("Stock", V(32, 36, 228), CF(0, -13, 114), 10, wood)
		g:wedge("StockWeb", V(30, 64, 214), CF(0, -63, 121) * A(0, 0, 180), wood)
		g:box("Buttplate", V(38, 104, 6), CF(0, -46, 231), metal)
		g:detail(function()
			g:box("StockTang", V(14, 4, 60), CF(0, 5, 26), metal)
			-- Its posts sunk into the stock's web, which slopes up toward the grip.
			g:slingLoop(CF(0, -85, 200))
		end)
	end)

	if v.bayonet then
		-- AKM-pattern bayonet: a ring over the barrel behind the brake, the grip under the gas block,
		-- a clipped blade running past the muzzle.
		g:at(CF(0, -30, 0), function()
			g:cyl("BayonetRing", 12, 30, CF(0, 30, -493), F.nitride)
			g:rounded("BayonetGrip", V(18, 26, 116), CF(0, -2, -410), 8, F.woodDark)
			g:box("BayonetGuard", V(22, 38, 8), CF(0, 5, -472), F.nitride)
			g:box("Bayonet", V(3.6, 24, 128), CF(0, -2, -540), F.bright)
			g:wedge("BayonetTip", V(3.6, 24, 34), CF(0, -2, -621), F.bright)
			g:detail(function()
				g:box("BayonetFuller", V(3.6 + FINE * 2, 5, 90), CF(0, 2, -534), F.steel)
			end)
		end)
	end

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.52)
	g:key("Sight", CF(0, 46, -118))
	g.model:SetAttribute("Action", "ak")
	g.model:SetAttribute("Flash", "rifle")
	g.model:SetAttribute("Casing", "rifle")
	return body
end

STYLES.rifle = function(g)
	if g.variant.pattern == "ak" then
		return buildAK(g)
	end
	return buildAR(g)
end

-- The pistol, measured off a Glock 17: a 188mm slide 25.5mm wide and 22mm tall with rear
-- serrations cut into its sides, the barrel hood showing in the ejection port, a polymer frame with
-- its rail groove and the trigger hanging from it, the squared trigger guard, a grip raked back 15
-- degrees with a stippled panel and a modest beavertail, and the magazine's base plate under it. The
-- compact variant is the subcompact: a 160mm slide and a grip two fingers tall with a pinky
-- extension on the magazine.
STYLES.pistol = function(g)
	local v = g.variant
	local compact = v.compact
	local slideFinish = g.skinned and g.skin or (g.rarityIndex >= 3 and g:finish("slide") or F.nitride)
	-- A polymer frame is as black as the slide on the real pistol; plain polymer read grey beside it.
	local frame = g:finish("furniture")
	if frame == F.polymer then
		frame = F.polymerDark
	end
	local small = g:finish("small")
	local front = compact and -94 or -111
	local back = compact and 66 or 77
	local gripLength = compact and 74 or 100

	-- Slide, in sections so the ejection port and the serrations are real openings and cuts.
	local slide
	g:group("slide", function()
		slide = g:prism("Slide", V(25.5, 22, -35 - front), CF(0, 1, (front - 35) / 2), 3, slideFinish, "top")
		-- Port: the slide's floor and left wall, and the barrel hood filling the opening the way the chamber
		-- block does on the real pistol, its top and right face 1.5 mm inside the slide's (a hood sunk deep
		-- in the port read as a hole through the slide).
		g:box("SlidePort", V(25.5, 12, 50), CF(0, -4, -10), slideFinish)
		g:prism("SlidePort", V(9.5, 10, 50), CF(-8, 7, -10), 3, slideFinish, "top")
		g:box("BarrelHood", V(16, 10, 44), CF(3.25, 5.5, -10), F.nitride)
		-- Rear: a plain band, the serrations, the back plate.
		g:prism("Slide", V(25.5, 22, 25), CF(0, 1, 27.5), 3, slideFinish, "top")
		local serrationEnd = back - 5
		g:box("SlideCore", V(19.5, 18, serrationEnd - 40), CF(0, -1, (serrationEnd + 40) / 2), slideFinish)
		g:prism("Slide", V(25.5, 4, serrationEnd - 40), CF(0, 10, (serrationEnd + 40) / 2), 3, slideFinish, "top")
		local ridges = math.floor((serrationEnd - 40) / 4)
		for index = 0, ridges - 1 do
			g:box("SlideSerration", V(25.5, 15, 2), CF(0, -1, 42 + index * 4), slideFinish)
		end
		g:prism("Slide", V(25.5, 22, 5), CF(0, 1, back - 2.5), 3, slideFinish, "top")
		-- Sights: a dovetailed front post and a notched rear, both with dots.
		g:box("FrontSight", V(3.5, 6, 6), CF(0, 15, front + 10), F.nitride)
		g:box("RearSight", V(8, 6, 7), CF(-7, 15, back - 12), F.nitride)
		g:box("RearSight", V(8, 6, 7), CF(7, 15, back - 12), F.nitride)
		g:box("RearSightBase", V(6, 2.5, 7), CF(0, 13.25, back - 12), F.nitride)
		g:detail(function()
			g:ball("SightDot", 2, CF(0, 16.5, front + 13.2), F.tritium)
			for _, sx in ipairs(SIGNS) do
				g:ball("SightDot", 2, CF(sx * 7, 16.5, back - 8.2), F.tritium)
			end
		end)
		-- The bore in the slide's nose.
		g:cyl("Bore", FINE, 9.5, CF(0, 0, front - FINE / 2), F.bore)
	end)
	g:travel("slide", 58)
	g:key("Eject", CF(14, 8, -10) * A(0, -60, 0))
	g:key("Sight", CF(0, 18, back - 6))
	g:hand("ChargeHand", V(-4, 34, back - 22), V(1, -0.45, 0.1), V(0, 1, 0.1))

	-- Frame: the dust cover with its rail groove, the frame over the trigger, slide stop and takedown.
	local dustFront = front + 5
	local dustLength = -28 - dustFront
	g:at(CF(0, 0, dustFront + dustLength / 2), function()
		g:box("Frame", V(24, 5, dustLength), CF(0, -12.5, 0), frame)
		g:box("Frame", V(17, 4, dustLength), CF(0, -17, 0), frame)
		g:prism("Frame", V(24, 5, dustLength), CF(0, -21.5, 0), 2, frame, "bottom")
	end)
	g:box("Frame", V(24, 16, 104), CF(0, -18, 24), frame)
	g:detail(function()
		g:box("SlideStop", V(3.5, 5, 14), CF(-13.75, -13, -14), F.nitride)
		g:box("SlideStopTab", V(4.5, 6, 6), CF(-14.25, -16, -7), F.nitride)
		for _, sx in ipairs(SIGNS) do
			g:box("TakedownLever", V(3.5, 5, 9), CF(sx * 13.75, -13, 4), F.nitride)
		end
		g:pin("FramePin", 4, CF(0, -21, 16), F.polymerDark, 31)
	end)

	-- Trigger guard: the squared front with its hook, and the bar under it back to the grip.
	g:box("TriggerGuard", V(12, 24, 9), CF(0, -38, -34), frame)
	g:box("TriggerGuard", V(12, 8, 60), CF(0, -54, -8), frame)
	g:wedge("TriggerGuardHook", V(12, 8, 8), CF(0, -46, -42.5), frame)
	g:group("trigger", function()
		g:box("Trigger", V(6, 17, 5), CF(0, -34.5, -2) * A(-10, 0, 0), F.polymerDark)
		g:detail(function()
			g:box("TriggerSafety", V(2, 10, 2.5), CF(0, -35, -5.2) * A(-10, 0, 0), F.polymerDark)
		end)
	end)
	g:swing("trigger", CF(0, -26, 0), 10)

	-- Grip, magazine, beavertail. A Glock's grip is a flattened teardrop with the stippling all over
	-- it; its magazine is a polymer-jacketed steel box whose base plate has a lip at the front.
	-- The grip's front runs 10 mm on up into the frame, so where the raked grip meets the level frame there
	-- is polymer, not a wedge of air with the magazine's top round showing through it.
	local gripFrame = g:grip(V(0, -26, 40), 15, frame, { length = gripLength, depth = 54, front = 24, back = 30, grooves = compact and 0 or 3, top = 10 })
	g:at(gripFrame, function()
		g:detail(function()
			-- On the grip's flat flank just behind its front rounding, sunk in, standing 2.3 mm proud (out over
			-- the rounding it stood clear of the grip altogether).
			g:box("MagRelease", V(3.5, 8, 9), CF(-12.6, -8, -14), F.polymerDark)
		end)
		g:group("mag", function()
			g:box("Magazine", V(19, gripLength - 4, 32), CF(0, -gripLength / 2 - 4, 2), F.polymerDark)
			-- Its top clear of the grip's own top faces (level with the back strap's end, it fought it).
			g:box("MagazineLiner", V(17, 6, 30), CF(0, -5.6, 2), F.nitride)
			if compact then
				-- The subcompact's +2 extension carries the grip's own shape on down (a hairline under the
				-- frame's grip), finished like the grip, with a base plate flared a millimetre past it.
				g:grip(V(0, -gripLength - 0.3, 0), 0, frame, { length = 18, depth = 54, front = 24, back = 30, name = "MagazineExtension" })
				g:grip(V(0, -gripLength - 18.6, 0), 0, small, { length = 5, depth = 56, front = 26, back = 32, name = "MagazinePlate" })
			else
				g:prism("MagazinePlate", V(25, 7, 42), CF(0, -gripLength - 3.5, 2), 2, small, "bottom")
				g:wedge("MagazinePlateLip", V(25, 7, 6), CF(0, -gripLength - 3.5, -22), small)
			end
			g:detail(function()
				for index = 0, 2 do
					g:cylX("MagazineWitness", FINE * 2, 3.5, CF(-9.5, -24 - index * 20, 14), F.shadow)
				end
				g:cyl("MagazineRound", 18, 9, CF(-2, 1.5, 4), F.brass)
				g:cyl("MagazineBullet", 9, 7, CF(-2, 1.5, -9.5), F.copper)
			end)
		end)
		g:key("MagWell", CF(0, -gripLength, 2))
	end)
	g:prism("Beavertail", V(24, 9, 9), CF(0, -14.5, 80.5), 3, frame, "bottom")
	g:hand("GripHand", V(30, -62, 52), V(-0.3, 0.1, -1), V(1, 0.15, 0.3))
	g:hand("SupportHand", V(-33, -74, 38), V(0.55, -0.05, -1), V(-1, -0.1, -0.3))
	g:hand("MagHand", V(-26, compact and -112 or -136, 62), V(0.35, 0.3, -0.2), V(-1, -0.1, 0))

	if v.light then
		-- A weapon light clamped on the rail just ahead of the trigger guard, its bezel standing a
		-- little past the muzzle the way a full-size light does on a full-size pistol.
		g:box("TorchMount", V(20, 6, 26), CF(0, -27, -58), F.anodizedDark)
		g:prism("Torch", V(30, 24, 72), CF(0, -41, -84), 6, F.anodizedDark)
		g:cyl("TorchBezel", 10, 31, CF(0, -41, -125), F.anodizedDark)
		g:cyl("TorchLens", FINE, 25, CF(0, -41, -130 - FINE / 2), finish(255, 248, 225, Mat.Glass, 0.3, 0.2))
		g:detail(function()
			for _, sx in ipairs(SIGNS) do
				g:box("TorchSwitch", V(5, 10, 14), CF(sx * 17.5, -39, -56), F.polymerDark)
			end
		end)
	end
	if v.laser and v.light then
		-- A light with the laser built in (one unit on the rail): the laser's housing runs along the
		-- torch's left side, its window beside the bezel.
		g:prism("LaserBody", V(12, 14, 40), CF(-19, -38, -96), 2, F.polymerDark)
		g:cyl("LaserEmitter", FINE * 2, 5, CF(-19, -38, -116 - FINE), F.laser)
	elseif v.laser then
		g:box("LaserMount", V(20, 6, 20), CF(0, -27, -58), F.anodizedDark)
		g:prism("LaserBody", V(26, 20, 46), CF(0, -37, -70), 4, F.polymerDark)
		g:cyl("LaserEmitter", FINE * 2, 5, CF(-6, -37, -93 - FINE), F.laser)
		g:detail(function()
			g:cyl("LaserLens", FINE * 2, 9, CF(6, -37, -93 - FINE), F.glass)
		end)
	end

	g.model:SetAttribute("Optic", "iron")
	-- A handgun is aimed out at arm's length, not from a hand's breadth away.
	g.model:SetAttribute("EyeRelief", 1.1)
	g.model:SetAttribute("Action", "pistol")
	g.model:SetAttribute("Flash", "pistol")
	g.model:SetAttribute("Casing", "pistol")
	g:key("Muzzle", CF(0, 0, front - 4))
	return slide
end

-- The revolver, measured off a six-inch S&W 686: a stainless L-frame whose top strap carries the
-- adjustable rear sight and runs back into the hump over the hammer, a fluted six-shot cylinder on a
-- crane that swings out to the left, a full-lug barrel with the ejector rod shroud under it and a
-- ramp front sight with a red insert, a spur hammer, and wooden grips.
STYLES.revolver = function(g)
	local v = g.variant
	local steel = g.skinned and g.skin or F.stainless
	local flute = finishOf(steel.color:Lerp(Color3.new(0, 0, 0), 0.32), Mat.Metal, 0.12)
	local barrelLength = v.longBarrel and 152 or 102
	local frameFront = -52
	local muzzle = frameFront - 10 - barrelLength
	local cylinderY = -13.5
	local small = g:finish("small")

	-- Frame: top strap, recoil shield, the lower frame the crane sits in, the hump over the hammer
	-- sloping down into the grip frame.
	local frameRear = g:box("Frame", V(24, 58, 22), CF(0, -11, 13), steel)
	g:prism("TopStrap", V(20, 10, 54), CF(0, 13, -25), 3, steel, "top")
	g:box("Frame", V(24, 44, 10), CF(0, -12, frameFront - 5), steel)
	g:box("Frame", V(22, 10, 54), CF(0, -35, -25), steel)
	-- The hump and the frame under it stop at z 40, where the backstrap (with the grip, below) takes the
	-- line on down: the hump's slope runs straight into it.
	g:wedge("FrameHump", V(24, 22, 16), CF(0, 7, 32) * A(0, 180, 0), steel)
	g:box("Frame", V(24, 36, 16), CF(0, -22, 32), steel)
	g:detail(function()
		for _, screw in ipairs({ { 14, -28 }, { 30, -8 }, { 34, -34 } }) do
			g:pin("SideplateScrew", 5, CF(0, screw[2], screw[1]), steel, 24 + FINE * 4)
		end
		g:box("ThumbPiece", V(3.5, 8, 18), CF(-13.75, 0, 12), steel)
	end)

	-- Adjustable rear sight on the top strap; ramp front sight with a red insert on the barrel rib.
	g:box("RearSightBase", V(14, 4, 26), CF(0, 20, -4), F.nitride)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSight", V(4.5, 6, 6), CF(sx * 4.75, 25, -10), F.nitride)
	end
	g:detail(function()
		g:cylX("RearSightScrew", 6, 5, CF(10, 21, 2), F.nitride)
	end)
	g:key("Sight", CF(0, 28, -2))

	-- Barrel: the tube, the full underlug with the ejector rod shroud, the rib and front sight.
	g:at(CF(0, 0, frameFront - 10 - barrelLength / 2), function()
		g:cyl("Barrel", barrelLength, 20, CF(0, 0, 0), steel)
		g:box("BarrelLug", V(15, 22, barrelLength), CF(0, -18, 0), steel)
		g:cyl("BarrelLug", barrelLength - 2 * RELIEF, 15, CF(0, -29, 0), steel)
		g:box("Rib", V(9, 6, barrelLength), CF(0, 11, 0), steel)
		local tip = -barrelLength / 2
		g:box("FrontSightRamp", V(4, 9, 22), CF(0, 18, tip + 14), steel)
		g:box("FrontSight", V(3, 6, 8), CF(0, 25, tip + 8), steel)
		g:box("FrontSightInsert", V(2, 3, FINE * 2), CF(0, 25.5, tip + 12 + FINE), F.tritiumOrange)
		g:cyl("Bore", FINE, 12, CF(0, 0, tip - FINE / 2), F.bore)
		g:detail(function()
			g:cyl("EjectorRod", FINE * 2, 8, CF(0, -29, tip - FINE), F.steel)
		end)
	end)
	g:key("Muzzle", CF(0, 0, muzzle - 6))

	-- Cylinder and crane. The cylinder fills the frame window: 1.5 mm off the recoil shield behind it, and
	-- its chamber mouths 1.6 mm off the forcing cone, the barrel's shank standing out of the frame in
	-- front of it. The flutes are six darker strips set into its surface, which is how a polished fluted
	-- cylinder actually reads. Both turn about axes laid along the bore (a swing's pivot turns about its
	-- own X): the cylinder about its own axis, a sixth of a turn a shot, and the crane out to the left and
	-- down about its hinge low on the frame's left.
	local drumFront, drumBack = -46, 0.5
	local drumZ = (drumFront + drumBack) / 2
	-- Its back end sits well inside the frame, and its face stands clear of the cylinder's chamber mouths
	-- rather than in their plane.
	g:cyl("ForcingCone", 7, 14, CF(0, 0, frameFront - 1), steel)
	g:group("crane", function()
		g:box("Crane", V(14, 8, 44), CF(-8, -30, drumZ), steel)
		g:group("drum", function()
			g:cyl("Drum", drumBack - drumFront, 42, CF(0, cylinderY, drumZ), steel)
			for index = 0, 5 do
				local angle = (index + 0.5) / 6 * math.pi * 2
				g:box("DrumFlute", V(9, FINE * 2, 33), CF(0, cylinderY, drumZ) * CFrame.Angles(0, 0, angle) * CF(0, 21 - 0.6, 0), flute)
			end
			for index = 0, 5 do
				local angle = index / 6 * math.pi * 2
				g:cyl("DrumChamber", FINE, 10, CF(0, cylinderY, drumFront - FINE / 2) * CFrame.Angles(0, 0, angle) * CF(0, 13.5, 0), F.bore)
			end
		end)
	end)
	g:swing("drum", CF(0, cylinderY, drumZ) * A(0, -90, 0), 60)
	g:swing("crane", CF(-14, -34, drumZ) * A(0, -90, 0), 90)
	g.model:SetAttribute("Parent_drum", "crane")
	-- The speedloader meets the swung-out cylinder's back face, on its axis.
	g:key("Load", CF(-34.5, -20, 9))

	-- Hammer, trigger, guard.
	-- The hammer: a chamfered body and a spur whose checkering stands up off its top.
	g:group("hammer", function()
		g:prism("Hammer", V(8, 18, 12), CF(0, 6, 36) * A(30, 0, 0), 2, steel)
		g:box("HammerSpur", V(8, 6, 18), CF(0, 14, 45) * A(38, 0, 0), steel)
		g:detail(function()
			-- Deep enough through the spur's top face that neither of the ridge's own faces lies near it.
			for index = 0, 2 do
				g:box("HammerChecker", V(5.2, 3.2, 1.6), CF(0, 14, 45) * A(38, 0, 0) * CF(0, 3, -4 + index * 4), steel)
			end
		end)
	end)
	g:swing("hammer", CF(0, -2, 34), -34)
	g:group("trigger", function()
		g:box("Trigger", V(7, 22, 6), CF(0, -46, -4) * A(-8, 0, 0), steel)
	end)
	g:swing("trigger", CF(0, -38, -2), 14)
	-- The guard is a closed loop: its front rises into the frame and its bottom bar runs back into the
	-- grip's front strap.
	g:box("TriggerGuard", V(9, 23.4, 5), CF(0, -50.3, -24), steel)
	g:box("TriggerGuard", V(9, 5, 46), CF(0, -64.5, -1), steel)
	g:box("TriggerGuard", V(9, 24, 5), CF(0, -54, 17) * A(28, 0, 0), steel)

	-- Grip: walnut panels round the grip frame, raked back further than a pistol's. The frame's own steel
	-- carries on down into the wood: a filler under the frame's underside in front (so no wedge of air
	-- shows where the raked wood meets the level frame), and the backstrap continuing the wood's back
	-- plane up into the hump. A polished medallion each side and the grip screw's polished ends.
	g:at(CF(0, -38, 28) * A(-22, 0, 0), function()
		g:rounded("Grip", V(30, 44, 84), CF(0, -42, 2) * A(90, 0, 0), 12, F.wood)
		g:cylX("GripButt", 30 - 2 * RELIEF, 44, CF(0, -84, 2), F.wood)
		-- The front filler is narrower than the backstrap it runs into, so their sides don't share a plane.
		g:box("GripFrame", V(19, 8.2, 26), CF(0, 5.9, -7), steel)
		g:box("Backstrap", V(21.6, 34, 18), CF(0, 17.3, 15), steel)
		g:detail(function()
			for _, sx in ipairs(SIGNS) do
				g:cylX("GripMedallion", FINE * 2, 10, CF(sx * 15, -24, 2), F.bright)
			end
			g:pin("GripScrew", 6, CF(0, -58, 2), F.bright, 30 + FINE * 2)
		end)
	end)
	-- Both hands 2 mm in from where they were, with the walnut now 30 mm across instead of 34.
	g:hand("GripHand", V(31, -68, 50), V(-0.3, 0.05, -1), V(1, 0.2, 0.35))
	g:hand("SupportHand", V(-34, -80, 36), V(0.55, -0.05, -1), V(-1, -0.1, -0.3))
	g:hand("MagHand", V(-40, -30, -10), V(0.3, 0.9, -0.2), V(-1, 0, 0.2))

	if v.engraved or g.rarityIndex >= 5 then
		for _, sx in ipairs(SIGNS) do
			g:engraving(CF(sx * 12, -18, 12), 18, 34)
			g:engraving(CF(sx * 12, -22, 32), 14, 22)
			g:engraving(CF(sx * 7.5, -18, frameFront - 10 - barrelLength / 2), barrelLength - 24, 12)
		end
	end

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 1.1)
	g.model:SetAttribute("Action", "revolver")
	g.model:SetAttribute("Flash", "revolver")
	g.model:SetAttribute("Casing", "none")
	return frameRear
end

-- The SMG, measured off an MP5: a stamped receiver with pressed ribs and the cocking tube running
-- forward over the barrel to the hooded front sight, the diopter drum at the back, the non-
-- reciprocating cocking handle out the left side, a slim handguard, the polymer trigger group with
-- its grip, and a curved 30-round magazine. Variants: the SD's integral suppressor and retractable
-- stock, a 100-round drum, a claw-mount rail with an optic.
STYLES.smg = function(g)
	local v = g.variant
	local metal = g.skinned and g.skin or (g.rarityIndex >= 4 and g:finish("receiver") or F.nitride)
	local furniture = v.camo and F.fde or g:finish("furniture")
	local small = g:finish("small")
	local suppressed = v.suppressor

	-- Receiver with its ribs and the ejection port (a real opening, bolt inside).
	local receiver = g:box("Receiver", V(15, 42, 300), CF(-7.5, -1, 10), metal)
	g:box("ReceiverWall", V(15, 42, 150), CF(7.5, -1, 85), metal)
	g:box("ReceiverWall", V(15, 42, 80), CF(7.5, -1, -100), metal)
	g:box("ReceiverWall", V(15, 12, 70), CF(7.5, -16, -25), metal)
	g:box("ReceiverWall", V(15, 12, 70), CF(7.5, 14, -25), metal)
	g:box("EjectionPort", V(3.5, 18, 70), CF(5.25, -1, -25), F.shadow)
	g:group("bolt", function()
		g:box("BoltCarrier", V(11.5, 14, 50), CF(5.75, -1, -18), F.steel)
	end)
	g:travel("bolt", 60)
	g:key("Eject", CF(18, 0, -25) * A(0, -70, 0))
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			g:box("ReceiverRib", V(3.5, 6, 180), CF(sx * 16.75, 12, 60), metal)
			g:box("ReceiverRib", V(3.5, 6, 120), CF(sx * 16.75, -14, 90), metal)
		end
		-- The claw mounts stop short of the diopter's base, whose underside they used to lie level with.
		for _, z in ipairs({ -80, 40, 100 }) do
			g:box("ClawMount", V(22, 4, 14), CF(0, 21.5, z), metal)
		end
		g:box("EndCap", V(34, 44, 8), CF(0, -1, 164), F.polymerDark)
	end)

	-- Cocking tube over the barrel, the handle out the left, the hooded front sight.
	-- The tube carries the front sight at its own height, so it cannot come down to the handguard; it is
	-- banded to it instead. Without the front band it stood 5 mm clear of the handguard along its whole
	-- run, held at one point near the receiver, and that slot of daylight is what made it read as a second
	-- barrel floating over the first.
	g:cyl("CockingTube", 150, 22, CF(0, 28, -215), metal)
	g:box("TubeSupport", V(20, 10, 20), CF(0, 16, -150), metal)
	g:box("BarrelBand", V(28, 13, 14), CF(0, 14, -258), metal)
	g:group("charge", function()
		g:box("ChargingHandle", V(24, 8, 9), CF(-18, 34, -236) * A(0, 0, -40), F.steel)
		g:ball("ChargingKnob", 13, CF(-30, 44, -236), F.polymerDark)
	end)
	g:travel("charge", 90)
	g:hand("ChargeHand", V(-42, 58, -240), V(0.25, -1, 0.3), V(-0.4, 0.2, 1))
	g:at(CF(0, 28, -282), function()
		-- The base's top stops 1.5 mm under the hood's inner face rather than level with it.
		g:box("FrontSightBase", V(26, 14.5, 26), CF(0, -2.75, 0), metal)
		g:shell("FrontSightHood", 18, 28, 4, CF(0, 16, 0), metal, 10)
		g:box("FrontSightPost", V(3, 12, 3), CF(0, 10, 0), metal)
		g:box("FrontSight", V(2.2, 6, 3), CF(0, 19, 0), metal)
	end)

	-- The diopter drum at the back.
	g:box("RearSightBase", V(26, 8, 34), CF(0, 24, 136), metal)
	-- Its top sits 1.5 mm under the aperture ring, never across the hole or level with the ring's inside.
	g:cylX("RearSightDrum", 26, 26, CF(0, 32.5, 136), metal)
	g:shell("RearSight", 6, 12, 3, CF(0, 50, 136), metal, 8)
	g:detail(function()
		for index = 0, 3 do
			g:box("RearSightFlat", V(28, 5, 5), CF(0, 32.5, 136) * CFrame.Angles(index / 4 * math.pi, 0, 0) * CF(0, 10.5, 0), metal)
		end
	end)

	-- Trigger group, grip, selector.
	g:prism("TriggerGroup", V(28, 20, 128), CF(0, -32, 34), 3, furniture, "bottom")
	g:box("TriggerGuard", V(12, 6, 60), CF(0, -58, 6), furniture)
	g:box("TriggerGuard", V(12, 13, 6), CF(0, -48.5, -24), furniture)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -47, 0) * A(-12, 0, 0), F.polymerDark)
	end)
	g:swing("trigger", CF(0, -38, 0), 12)
	g:grip(V(0, -42, 66), 16, furniture, { length = 98, depth = 46, front = 22, back = 30, grooves = 3 })
	g:detail(function()
		g:at(CF(-15, -34, 64), function()
			g:cylX("Selector", 3.5, 14, CF(0, 0, 0), F.polymerDark)
			g:box("SelectorLever", V(3.5, 6, 20), CF(-1, -4, -8) * A(-35, 0, 0), small)
		end)
		g:pin("TriggerGroupPin", 7, CF(0, -28, 94), F.nitride, 35)
	end)
	g:hand("GripHand", V(31, -80, 82), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- Magazine well and magazine (or drum).
	g:box("MagWell", V(30, 23, 48), CF(0, -33.5, -76), metal)
	g:box("MagRelease", V(14, 12, 6), CF(0, -40, -50), F.steel)
	g:group("mag", function()
		if v.drum then
			g:drumMag("Magazine", 100, 56, CF(0, -44, -76), F.polymerDark)
		else
			g:magazine("Magazine", { width = 22, depth = 34, segments = { { 60, 0 }, { 42, 4 }, { 42, 4 }, { 42, 4 } }, ribs = "stanag", caliber = 9 }, CF(0, -40, -76), F.nitride)
		end
	end)
	g:key("MagWell", CF(0, -40, -76))
	g:hand("MagHand", V(-30, v.drum and -150 or -120, -80), V(0.4, 0.25, -0.2), V(-1, -0.15, 0))

	-- Front end: the handguard round the barrel, or the SD's suppressor with its own handguard.
	local muzzleZ
	if suppressed then
		g:cyl("Suppressor", 330, 52, CF(0, -2, -305), F.nitride)
		g:rounded("Handguard", V(56, 56, 120), CF(0, -2, -200), 26, furniture)
		g:detail(function()
			for index = 0, 5 do
				g:cyl("SuppressorBand", 4, 55, CF(0, -2, -300 - index * 26), F.anodizedDark)
			end
			g:cyl("Bore", 2, 10, CF(0, -2, -470.4), F.bore)
		end)
		muzzleZ = -472
	else
		g:cyl("Barrel", 150, 15, CF(0, 0, -215), F.nitride)
		g:rounded("Handguard", V(42, 40, 124), CF(0, -8, -205), 15, furniture)
		g:detail(function()
			for _, sx in ipairs(SIGNS) do
				for index = 0, 4 do
					g:box("HandguardGroove", V(FINE * 2, 6, 12), CF(sx * 21, -14, -250 + index * 22), furniture)
				end
			end
		end)
		-- Three lugs round the barrel's end.
		g:cyl("MuzzleBrake", 16, 18, CF(0, 0, -298), F.nitride)
		g:detail(function()
			for index = 0, 2 do
				g:box("MuzzleProng", V(6, 7, 12), CF(0, 0, -298) * CFrame.Angles(0, 0, index / 3 * math.pi * 2) * CF(0, 10, 0), F.nitride)
			end
			g:cyl("Bore", 2, 8, CF(0, 0, -307), F.bore)
		end)
		muzzleZ = -308
	end
	g:key("Muzzle", CF(0, 0, muzzleZ))
	g:hand("SupportHand", V(-12, -44, suppressed and -205 or -212), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- Stock: the retractable skeleton on the SD, a fixed polymer stock otherwise.
	if v.skeletonStock then
		for _, sx in ipairs(SIGNS) do
			g:box("StockStrut", V(6, 9, 210), CF(sx * 14, -6, 262), F.nitride)
		end
		g:rounded("Buttpad", V(40, 30, 104), CF(0, -26, 372) * A(90, 0, 0), 12, F.rubber)
		g:box("StockYoke", V(34, 12, 18), CF(0, -6, 360), F.nitride)
	else
		g:at(CF(0, 0, 168), function()
			g:rounded("Stock", V(36, 34, 200), CF(0, -2, 100), 11, furniture)
			g:wedge("StockWeb", V(32, 66, 180), CF(0, -52, 110) * A(0, 0, 180), furniture)
			g:rounded("Buttpad", V(40, 20, 104), CF(0, -34, 210) * A(90, 0, 0), 8, F.rubber)
		end)
	end

	-- Sights: the diopter, or a rail on the claw mounts with an optic.
	if v.holo then
		g:box("ClawRail", V(28, 12, 140), CF(0, 27, 40), F.anodizedDark)
		g:rail("OpticRail", 132, CF(0, 33, 40))
		local h = g:holo(CF(0, 42.5, 30))
		g:key("Sight", CF(0, 42.5 + h, 110))
		g.model:SetAttribute("Optic", "holo")
		g.model:SetAttribute("EyeRelief", 0.6)
	else
		g:key("Sight", CF(0, 50, 142))
		g.model:SetAttribute("Optic", "iron")
		g.model:SetAttribute("EyeRelief", 0.36)
	end
	if v.laser then
		g:laserModule(CF(0, -44, suppressed and -170 or -214))
	end

	g.model:SetAttribute("Action", "smg")
	g.model:SetAttribute("Flash", suppressed and "suppressed" or "smg")
	g.model:SetAttribute("Casing", "pistol")
	return receiver
end

-- The M14 pattern, measured off an M1A: a one-piece walnut stock with a semi-pistol grip and a steel
-- butt plate, a parkerized receiver with the protected aperture rear sight and the op-rod handle
-- running along the right side, a fibreglass upper handguard, the front band and gas cylinder under
-- the barrel, a prong flash suppressor carrying the front sight, a straight 20-round magazine, and a
-- scope on a mount over the action.
local function buildM14(g)
	local v = g.variant
	local metal = g.skinned and g.skin or F.parkerized
	local wood = v.woodFurniture and F.wood or g:finish("furniture")
	local small = g:finish("small")

	-- Stock.
	g:rounded("Stock", V(46, 34, 250), CF(0, -24, -205), 12, wood)
	local body = g:box("Stock", V(46, 40, 150), CF(0, -30, -5), wood)
	g:at(CF(0, -34, 115) * A(-8, 0, 0), function()
		g:rounded("Stock", V(38, 44, 90), CF(0, 0, 0), 13, wood)
	end)
	g:rounded("Stock", V(42, 40, 290), CF(0, -26, 305), 12, wood)
	g:wedge("StockWeb", V(40, 100, 250), CF(0, -96, 325) * A(0, 0, 180), wood)
	g:box("Buttplate", V(44, 142, 8), CF(0, -76, 454), metal)
	-- The semi-pistol grip: a short swell under the wrist behind the trigger guard, sweeping back up
	-- into the butt's lower line.
	g:grip(V(0, -52, 74), 12, wood, { length = 48, depth = 44, front = 30, back = 36 })
	g:wedge("StockSwell", V(36, 45, 106), CF(0, -77.5, 149) * A(180, 0, 0), wood)
	g:hand("GripHand", V(33, -76, 92), V(-0.35, 0.2, -1), V(1, 0.15, 0.3))
	g:hand("SupportHand", V(-10, -54, -220), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- Receiver, bolt, op rod, rear sight.
	g:rounded("Receiver", V(30, 30, 200), CF(0, 6, -10), 10, metal)
	g:group("bolt", function()
		g:cyl("BoltCarrier", 70, 14, CF(0, 16, 30), F.steel)
	end)
	g:travel("bolt", 80)
	g:group("charge", function()
		g:box("ChargingHandle", V(12, 14, 30), CF(21, 6, -40), metal)
		g:cyl("OpRod", 290, 9, CF(17, -8, -185), metal)
	end)
	g:travel("charge", 80)
	g:hand("ChargeHand", V(40, 14, -44), V(-0.1, -1, 0.2), V(1, 0.1, 0))
	g:key("Eject", CF(18, 22, 10) * A(0, -60, 30))
	g:box("RearSightBase", V(26, 12, 26), CF(0, 27, 74), metal)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSightEar", V(4, 26, 20), CF(sx * 11, 40, 74), metal)
	end
	g:shell("RearSight", 4, 10, 3, CF(0, 44, 74), metal, 8)
	g:aperturePlate(CF(0, 0, 74), 33, 44, metal)
	g:box("ClipGuide", V(12, 8, 18), CF(0, 19, -60), metal)

	-- Scope mount and scope.
	g:box("ScopeBase", V(34, 14, 160), CF(0, 28, -30), F.anodizedDark)
	g:rail("ScopeRail", 150, CF(0, 35, -30))
	local h = g:scope(CF(0, 44.5, -20), "lpvo")
	g:key("Sight", CF(0, 44.5 + h, 150))
	g.model:SetAttribute("Optic", "scope")
	g.model:SetAttribute("EyeRelief", 0.6)

	-- Handguard, barrel, front band, gas cylinder, flash suppressor with the front sight.
	g:rounded("HandguardUpper", V(28, 16, 200), CF(0, 12, -210), 7, F.polymerDark)
	g:detail(function()
		for index = 0, 3 do
			g:box("HandguardVent", V(20, FINE * 2, 14), CF(0, 20, -150 - index * 40), F.shadow)
		end
	end)
	g:cyl("Barrel", 450, 20, CF(0, 0, -335), F.nitride)
	g:box("FrontBand", V(40, 26, 22), CF(0, -14, -330), metal)
	g:cyl("GasCylinder", 70, 22, CF(0, -22, -445), metal)
	-- The gas cylinder hangs off the barrel on its block.
	g:box("GasBlock", V(16, 14, 30), CF(0, -12, -458), metal)
	g:box("GasCylinderLock", V(18, 14, 18), CF(0, -34, -482), metal)
	g:at(CF(0, 0, -560), function()
		g:cyl("MuzzleBrake", 16, 24, CF(0, 0, -8), metal)
		for index = 0, 4 do
			g:box("MuzzleProng", V(4, 3.5, 40), CFrame.Angles(0, 0, index / 5 * math.pi * 2) * CF(0, 10.25, -36), metal)
		end
		g:crown("MuzzleBrake", 8, 24, 9, CF(0, 0, -60), metal)
		g:box("BayonetLug", V(10, 10, 26), CF(0, -16, -24), metal)
		-- The ears and post stand on a base seated on the suppressor's collar (on the round collar alone,
		-- the ears' feet hung 3 mm clear of it).
		g:box("FrontSightBase", V(24, 8, 18), CF(0, 10, -14), metal)
		for _, sx in ipairs(SIGNS) do
			g:box("FrontSightEar", V(4, 30, 14), CF(sx * 9, 26, -14), metal)
		end
		g:box("FrontSightPost", V(3.5, 22, 4), CF(0, 22, -14), metal)
		g:box("FrontSight", V(2.4, 11, 3), CF(0, 38.5, -14), metal)
	end)
	g:key("Muzzle", CF(0, 0, -626))

	-- Magazine, trigger guard, trigger, safety.
	g:group("mag", function()
		g:magazine("Magazine", { width = 26, depth = 84, segments = { { 108, 0 } }, ribs = "stanag", caliber = 11.5 }, CF(0, -44, -75), F.parkerized)
	end)
	g:key("MagWell", CF(0, -44, -75))
	g:hand("MagHand", V(-32, -150, -80), V(0.4, 0.25, -0.15), V(-1, -0.15, 0))
	g:box("TriggerGuard", V(12, 6, 70), CF(0, -72, 8), metal)
	g:box("TriggerGuard", V(12, 17, 6), CF(0, -60.5, -24), metal)
	g:box("TriggerGuard", V(12, 17, 8), CF(0, -60.5, 40), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -59, -2) * A(-10, 0, 0), metal)
	end)
	g:swing("trigger", CF(0, -50, 0), 12)
	g:box("Safety", V(10, 8, 10), CF(0, -54, -32), small)

	if v.laser then
		g:rail("LaserRail", 60, CF(0, -41, -290) * A(180, 0, 0))
		g:laserModule(CF(0, -70.5, -290))
	end
	g:slingLoop(CF(0, -41, -200))

	g.model:SetAttribute("Action", "semi")
	g.model:SetAttribute("Flash", "rifle")
	g.model:SetAttribute("Casing", "rifle")
	return body
end

-- The bolt-action precision rifle, patterned on the Accuracy International AWM: a chassis with a flat
-- forend, a thumbhole stock with an adjustable cheek piece, a vertical grip, butt pad and monopod, a
-- round action with its bolt and tactical knob, a heavy fluted barrel and a muzzle brake, a detachable
-- box magazine, a long scope and a folded bipod. Larila's wears ghillie rags.
local function buildBoltAction(g)
	local v = g.variant
	local chassis = g.skinned and g.skin or (g.rarityIndex == 4 and g:finish("receiver") or F.od)
	local metal = F.nitride
	local small = g:finish("small")
	local barrelEnd = v.longBarrel and -780 or -680

	-- Action and rail.
	local action = g:cyl("Receiver", 220, 34, CF(0, 6, -10), metal)
	g:box("RailBase", V(20, 6, 230), CF(0, 23, -10), metal)
	g:rail("ScopeRail", 220, CF(0, 26, -10))
	g:box("EjectionPort", V(FINE * 2, 14, 70), CF(16.5, 12, -30), F.shadow)
	-- The bolt: lifts, then draws back. Its knob is where the right hand works it.
	g:group("bolt", function()
		g:cyl("BoltShroud", 30, 26, CF(0, 6, 115), metal)
		g:cyl("BoltBody", 60, 20, CF(0, 6, 72), F.steel)
		g:box("BoltHandle", V(40, 8, 10), CF(22, 0, 82) * A(0, 0, -25), metal)
		g:ball("BoltKnob", 22, CF(44, -12, 82), F.polymerDark)
	end)
	g:swing("bolt", CF(0, 6, 82) * A(0, 90, 0), 60)
	g:travel("bolt", 95)
	g:hand("BoltHand", V(52, -8, 88), V(-0.5, 0.1, -0.8), V(0.4, 1, 0.2))
	g:key("Eject", CF(24, 12, -30) * A(0, -70, 20))

	-- Chassis: centre section, forend, the thumbhole stock.
	g:box("Chassis", V(54, 44, 250), CF(0, -30, -5), chassis)
	g:prism("Forend", V(50, 46, 330), CF(0, -22, -295), 6, chassis)
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			for index = 0, 3 do
				g:box("ForendVent", V(FINE * 2, 12, 48), CF(sx * 25, -22, -190 - index * 68), F.shadow)
			end
		end
	end)
	g:grip(V(0, -52, 84), 12, chassis, { length = 104, depth = 46, front = 24, back = 32, grooves = 3 })
	g:hand("GripHand", V(32, -90, 100), V(-0.3, 0.05, -1), V(1, 0.2, 0.25))
	g:hand("SupportHand", V(-6, -58, -300), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:box("Stock", V(46, 44, 330), CF(0, -18, 285), chassis)
	g:prism("StockCheek", V(40, 16, 150), CF(0, 12, 320), 5, chassis, "top")
	g:box("StockToe", V(40, 30, 280), CF(0, -128, 330), chassis)
	g:box("StockToe", V(40, 30, 110), CF(0, -140, 150) * A(-8, 0, 0), chassis)
	g:box("Butt", V(46, 170, 34), CF(0, -65, 457), chassis)
	g:prism("Buttpad", V(50, 176, 16), CF(0, -65, 482), 4, F.rubber)
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			g:cylX("CheekKnob", 8, 16, CF(sx * 26.5, -4, 280), F.anodizedDark)
		end
		g:cylY("Monopod", 50, 18, CF(0, -168, 430), F.anodizedDark)
		g:cylY("MonopodFoot", 8, 26, CF(0, -197, 430), F.rubber)
	end)

	-- Magazine, guard, trigger.
	g:group("mag", function()
		g:magazine("Magazine", { width = 28, depth = 80, segments = { { 70, 0 } }, caliber = 12 }, CF(0, -46, -60), F.anodizedDark)
	end)
	g:key("MagWell", CF(0, -46, -60))
	g:hand("MagHand", V(-34, -130, -62), V(0.4, 0.25, -0.15), V(-1, -0.15, 0))
	g:box("MagRelease", V(24, 6, 12), CF(0, -55, -10), small)
	g:box("TriggerGuard", V(14, 6, 70), CF(0, -72, 12), chassis)
	g:box("TriggerGuard", V(14, 17, 8), CF(0, -60.5, -19), chassis)
	g:group("trigger", function()
		g:box("Trigger", V(6, 16, 6), CF(0, -60, 4) * A(-8, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -52, 4), 10)

	-- Barrel: heavy near the action, fluted, a brake at the muzzle.
	g:cyl("Barrel", 130, 28, CF(0, 0, -185), metal)
	g:cyl("Barrel", -250 - barrelEnd, 22, CF(0, 0, (barrelEnd - 250) / 2), metal)
	if v.flutes then
		g:detail(function()
			local run = -barrelEnd - 290
			for index = 0, 5 do
				local angle = (index + 0.5) / 6 * math.pi * 2
				g:box("Flute", V(4, FINE * 2, run), CF(0, 0, -270 - run / 2) * CFrame.Angles(0, 0, angle) * CF(0, 10.5, 0), F.shadow)
			end
		end)
	end
	local muzzleZ = barrelEnd + g:brake(CF(0, 0, barrelEnd), 32, 84)
	g:key("Muzzle", CF(0, 0, muzzleZ))

	-- Long scope and a folded bipod.
	local h = g:scope(CF(0, 35.5, -20), "long")
	g:key("Sight", CF(0, 35.5 + h, 190))
	g.model:SetAttribute("Optic", "scope")
	g.model:SetAttribute("EyeRelief", 0.6)
	g:bipod(CF(0, -45, -420))

	if v.ghillie then
		-- Ghillie wrap: strips of burlap wound round the barrel, the forend and the stock, a strip draped
		-- over the scope, and short frayed tufts hanging off each wrap. The tufts' angles come from their
		-- index, so every copy of the gun wears exactly the same rags.
		local function tufts(centre, radius, seed)
			for index = 0, 2 do
				local around = math.rad(-60 + index * 60)
				local root = centre + V(math.sin(around) * radius, -math.cos(around) * radius, 0)
				local length = 22 + ((seed + index) % 3) * 8
				local swing = math.sin((seed + index) * 12.9898) * 22
				g:box("Ghillie", V(3, length, 10), CF(root) * A(swing, 0, math.deg(around) * 0.4) * CF(0, -length / 2, 0),
					(seed + index) % 2 == 0 and F.ghillie or F.ghillieDark)
			end
		end
		for index, z in ipairs({ -330, -470, -610 }) do
			g:cyl("GhillieWrap", 36, 30, CF(0, 0, z), index % 2 == 0 and F.ghillieDark or F.ghillie)
			tufts(V(0, 0, z), 15, index)
		end
		-- The tufts' roots sit inside each wrap, not on its corner: hung at the wrap's own half-height they
		-- reached past the bottom face and the lowest one hung on nothing.
		g:box("GhillieWrap", V(50 + RELIEF * 2, 46 + RELIEF * 2, 54), CF(0, -22, -420), F.ghillieDark)
		tufts(V(0, -22, -420), 24, 4)
		g:box("GhillieWrap", V(46 + RELIEF * 2, 44 + RELIEF * 2, 60), CF(0, -18, 330), F.ghillie)
		tufts(V(0, -18, 330), 23, 7)
		g:box("GhillieDrape", V(30, 3, 110), CF(0, 35.5 + 52 + 18.5, -20) * A(4, 0, 0), F.ghillie)
	end

	g.model:SetAttribute("Action", "bolt")
	g.model:SetAttribute("Flash", "brake")
	g.model:SetAttribute("Casing", "rifle")
	return action
end

-- The pump shotgun, measured off a Remington 870 with a tactical barrel: a steel receiver with a real
-- ejection port and the loading port underneath, the magazine tube under the barrel with its cap and
-- clamp, a ribbed polymer pump riding on twin action bars, a pistol-grip stock, a side saddle of
-- shells, and a ventilated heat shield over the barrel.
local function buildPump(g)
	local v = g.variant
	local metal = g.skinned and g.skin or (g.rarityIndex >= 3 and g:finish("receiver") or F.nitride)
	local furniture = g:finish("furniture")
	local small = g:finish("small")

	-- Receiver round the ejection port.
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
	g:box("TriggerGuard", V(12, 6, 62), CF(0, -70, 8), metal)
	g:box("TriggerGuard", V(12, 15, 6), CF(0, -59.5, -22), metal)
	g:box("TriggerGuard", V(12, 15, 6), CF(0, -59.5, 38), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 17, 6), CF(0, -60, -2) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -52, 0), 10)
	g:detail(function()
		g:cylX("Safety", 30, 8, CF(0, -47, 48), small)
		g:box("SlideRelease", V(4, 10, 14), CF(-17, -45, -40), F.steel)
		for _, z in ipairs({ -110, 40 }) do
			g:pin("ReceiverPin", 6, CF(0, -34, z), F.steel, 30 + FINE * 2)
		end
	end)

	-- Barrel, heat shield, bead; magazine tube, cap and clamp.
	g:cyl("Barrel", 485, 23, CF(0, 0, -377.5), F.nitride)
	g:cyl("Bore", FINE, 19, CF(0, 0, -620 - FINE / 2), F.bore)
	if v.heatShield then
		g:heatShield(CF(0, 0, -340), 280, 17, 11.5)
	end
	-- The bead stands on a ramp, so the line over it clears the receiver top and the heat shield.
	g:box("BeadRamp", V(5, 8, 12), CF(0, 15, -606), F.nitride)
	g:ball("FrontBead", 5, CF(0, 20.5, -606), F.brass)
	g:cyl("MagTube", 425, 26, CF(0, -30, -347.5), F.nitride)
	g:cyl("MagCap", 22, 29, CF(0, -30, -571), F.nitride)
	g:box("BarrelClamp", V(34, 50, 14), CF(0, -14, -536), F.nitride)
	g:slingLoop(CF(0, -44, -566))
	g:key("Muzzle", CF(0, 0, -624))

	-- The pump on its action bars.
	g:group("pump", function()
		g:rounded("Pump", V(46, 44, 180), CF(0, -28, -300), 16, furniture)
		g:detail(function()
			for index = 0, 7 do
				g:box("PumpRib", V(46 + FINE * 2, 30, 5), CF(0, -33, -226 - index * 21), furniture)
			end
		end)
		for _, sx in ipairs(SIGNS) do
			g:box("ActionBar", V(3, 6, 90), CF(sx * 12, -18, -165), F.steel)
		end
	end)
	g:travel("pump", 85)
	g:hand("SupportHand", V(-8, -58, -300), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "pump")

	-- Pistol-grip stock.
	g:at(CF(0, 0, 75), function()
		g:rounded("Stock", V(40, 42, 330), CF(0, -24, 165), 12, furniture)
		g:wedge("StockWeb", V(38, 100, 220), CF(0, -95, 245) * A(0, 0, 180), furniture)
		g:prism("Buttpad", V(44, 146, 20), CF(0, -72, 340), 4, F.rubber)
	end)
	g:grip(V(0, -44, 72), 22, furniture, { length = 96, depth = 46, front = 22, back = 30 })
	g:hand("GripHand", V(31, -86, 104), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- Side saddle of shells on the left.
	g:box("SideSaddle", V(4, 44, 110), CF(-17, -8, -40), F.polymerDark)
	for index = 0, 4 do
		g:cylY("SpareShell", 44, 20, CF(-29, -8, -80 + index * 20), F.shell)
		g:cylY("SpareShellBase", 12, 21.4, CF(-29, -36, -80 + index * 20), F.brass)
	end

	g.model:SetAttribute("Optic", "iron")
	-- Cheek down on the comb, the eye well back over the stock: from closer, the back of the receiver
	-- filled the bottom of the sight picture.
	g.model:SetAttribute("EyeRelief", 0.8)
	g:key("Sight", CF(0, 23, 40))
	g.model:SetAttribute("Action", "pump")
	g.model:SetAttribute("Flash", "shotgun")
	g.model:SetAttribute("Casing", "shell")
	return receiver
end

STYLES.dmr = function(g)
	if g.variant.woodFurniture then
		return buildM14(g)
	end
	return buildAR(g, { scale = 1.12, hgLength = 250, barrelEnd = -470, barrelDia = 19, muzzle = "brake", optic = "lpvo", mag = magazine308,
		action = "semi" })
end

STYLES.sniper = function(g)
	if g.variant.boltAction then
		return buildBoltAction(g)
	end
	return buildAR(g, { scale = 1.12, hgLength = 330, barrelEnd = -600, barrelDia = 21, muzzle = "brake", optic = "long", mag = magazine308,
		stock = "precision", bipod = true, flutes = g.variant.flutes, action = "semi", flash = "brake" })
end

STYLES.shotgun = function(g)
	if g.variant.semiAuto then
		return buildAR(g, { scale = 1.18, hgLength = 230, barrelEnd = -420, barrelDia = 22, muzzle = "choke", heatShield = g.variant.heatShield,
			mag = function(builder)
				builder:drumMag("Magazine", 170, 64, CF(0, -52, -57), F.polymerDark)
			end,
			action = "semi", flash = "shotgun", casing = "shell" })
	end
	return buildPump(g)
end

-- The side-by-side, patterned on a coach gun: a case-hardened action with sidelock plates and two
-- exposed hammers, a top lever, the barrels on their hinge with the rib and a brass bead, a splinter
-- forend, double triggers, and a straight English stock. The sawn-off is cut down to short barrels and
-- a taped pistol grip.
STYLES.doublebarrel = function(g)
	local v = g.variant
	local sawn = v.sawnOff
	local steel = g.skinned and g.skin or F.blued
	local plates = g.rarityIndex >= 5 and F.bright or F.steel
	local small = g:finish("small")
	local barrelEnd = sawn and -300 or -570
	local length = -62 - barrelEnd

	-- The action: a deep body with long sidelock plates running back into the wrist, the tang lying
	-- along the top of the wrist with the top lever on it, and a hammer low on each side.
	local action = g:rounded("Receiver", V(46, 58, 110), CF(0, -16, -5), 10, steel)
	g:box("SidePlate", V(46 + FINE * 2, 40, 96), CF(0, -18, 8), plates)
	g:box("TopTang", V(16, 4, 50), CF(0, 13.6, 75) * A(8, 0, 0), steel)
	g:box("TopLever", V(8, 5, 34), CF(6, 17.5, 62) * A(8, 25, 0), small)
	g:group("hammer", function()
		for _, sx in ipairs(SIGNS) do
			g:box("Hammer", V(7, 16, 10), CF(sx * 17, 16, 42) * A(35, 0, 0), plates)
			g:box("HammerSpur", V(8, 5, 12), CF(sx * 17, 24, 49) * A(55, 0, 0), plates)
		end
	end)
	g:swing("hammer", CF(0, 8, 38), -30)
	-- The hinge pin is low at the front of the frame, and the barrels break DOWNWARD about it the way a
	-- real break gun opens: the muzzles drop and the breech end rises off the standing breech (swung the
	-- other way, the gun opened by pointing its muzzles at the sky).
	g:cylX("Hinge", 50, 16, CF(0, -30, -62), F.steel)
	g:swing("hinge", CF(0, -30, -62), -40)

	g:group("hinge", function()
		for _, sx in ipairs(SIGNS) do
			g:cyl("Barrel", length, 22, CF(sx * 11, 0, -62 - length / 2), steel)
			g:cyl("Bore", FINE, 18, CF(sx * 11, 0, barrelEnd - FINE / 2), F.bore)
			g:cyl("ShellRim", FINE * 2, 21, CF(sx * 11, 0, -62 + FINE), F.brass)
		end
		-- A raised sighting rib, so the line along it clears the top lever and the tang, with the bead's
		-- top on that line.
		-- It stands down in the valley between the barrels (from 8 mm up it only met them along its edges).
		g:box("Rib", V(10, 18, length), CF(0, 11, -62 - length / 2), steel)
		g:box("Rib", V(8, 10, length - 20), CF(0, -9, -72 - length / 2), steel)
		g:ball("FrontBead", 5, CF(0, 21.5, barrelEnd + 12), F.brass)
		local foreLength = sawn and 120 or 210
		g:rounded("ForeGrip", V(40, 22, foreLength), CF(0, -21, -80 - foreLength / 2), 9, F.wood)
		g:box("ForendIron", V(20, 6, 40), CF(0, -34, -110), F.steel)
	end)
	g:hand("SupportHand", V(-8, -46, -80 - (sawn and 60 or 105)), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "hinge")
	g:key("Load", CF(0, 0, -40))
	-- The ejector throws the empties up and back over your hand as the barrels drop.
	g:key("Eject", CF(0, 6, -46) * A(118, 0, 0))
	g.model:SetAttribute("LoadGroup", "hinge")

	-- Guard and double triggers.
	g:box("TriggerGuard", V(12, 6, 60), CF(0, -60, 6), steel)
	g:box("TriggerGuard", V(12, 17, 6), CF(0, -48.5, -21), steel)
	g:box("TriggerGuard", V(12, 17, 6), CF(0, -48.5, 33), steel)
	g:group("trigger", function()
		for _, z in ipairs({ -8, 10 }) do
			g:box("Trigger", V(5, 18, 5), CF(0, -46, z) * A(-12, 0, 0), g.rarityIndex >= 5 and F.gold or F.steel)
		end
	end)
	g:swing("trigger", CF(0, -38, 0), 12)

	if sawn then
		-- Cut back to a stub of wrist and a pistol grip, wrapped in tape where the checkering was.
		-- The stub of wrist runs up under the tang and into the back of the action, carrying both.
		g:rounded("Stock", V(34, 48, 36), CF(0, -10, 65), 12, F.wood)
		local gf = g:grip(V(0, -34, 62), 30, F.wood, { length = 96, depth = 44, front = 26, back = 32 })
		g:at(gf, function()
			g:detail(function()
				for index = 0, 1 do
					g:box("Tape", V(32 + FINE * 2, 14, 44 + FINE * 2), CF(0, -30 - index * 32, 0), F.tape)
				end
			end)
		end)
		g:hand("GripHand", V(32, -66, 84), V(-0.3, 0.1, -1), V(1, 0.1, 0.3))
	else
		-- A straight English stock: a slim wrist dropping from the tang, the butt below it, checkering
		-- on the wrist.
		-- The wrist is where the hand holds a straight stock, so it carries the name Grip.
		g:rounded("Grip", V(34, 40, 130), CF(0, -14, 115) * A(8, 0, 0), 12, F.wood)
		g:rounded("Stock", V(40, 48, 250), CF(0, -42, 295) * A(4, 0, 0), 14, F.wood)
		g:wedge("StockWeb", V(38, 90, 230), CF(0, -110, 305) * A(0, 0, 180), F.wood)
		g:box("Buttplate", V(42, 140, 8), CF(0, -88, 424), F.woodDark)
		g:detail(function()
			for _, sx in ipairs(SIGNS) do
				g:box("Checkering", V(FINE * 2, 24, 60), CF(sx * 17, -14, 115) * A(8, 0, 0), F.woodDark)
			end
		end)
		-- The trigger hand wraps the wrist from the right: fingers down and round under it, the back of
		-- the hand to the right, the heel of the hand behind and above, below the line of sight.
		-- Forward on the wrist, just behind the guard, where the index finger reaches the triggers: further
		-- back it sat a hand's breadth under the eye and its forearm filled the right of the sight picture.
		-- The fingers point 30 degrees down the wrist rather than 50, and the hand sits 4 mm lower and 4 mm
		-- further forward: steeper, no elbow that stays out of the sight picture could line the forearm up
		-- with the hand, and the wrist met it at 105 degrees at full aim (#11); with the palm at its real
		-- length, the forearm behind it then came into the crosshair's ring unless the hand came forward.
		-- Measured by tools/fps_arms_check.py.
		g:hand("GripHand", V(32, -24, 70), V(-0.25, -0.5, -0.83), V(1, 0.35, 0.05))
	end

	if v.engraved or g.rarityIndex >= 5 then
		for _, sx in ipairs(SIGNS) do
			g:engraving(CF(sx * (23 + FINE), -18, 8), 80, 30)
		end
	end

	g.model:SetAttribute("Optic", "iron")
	-- The full gun has its cheek on the comb, the eye over the stock; the sawn-off has no stock and is
	-- aimed held out in front, like a handgun.
	g.model:SetAttribute("EyeRelief", sawn and 1.0 or 0.78)
	g:key("Sight", CF(0, 24, 50))
	g:key("Muzzle", CF(0, 0, barrelEnd - 4))
	g.model:SetAttribute("Action", "break")
	g.model:SetAttribute("Flash", "shotgun")
	g.model:SetAttribute("Casing", "shell")
	return action
end

-- The light machine gun, measured off an M249: a long stamped receiver with the feed cover hinged at
-- its front and a rail on it, the charging handle on the right, a railed handguard under the barrel
-- and a heat shield over it, the carry handle folded up over the barrel, the gas block with its
-- bipod, a fixed stock with its shoulder rest, and a 200-round box under the feed tray with the belt
-- climbing out of it into the gun.
STYLES.lmg = function(g)
	local metal = g.skinned and g.skin or (g.rarityIndex >= 4 and g:finish("receiver") or F.nitride)
	local furniture = g:finish("furniture")
	local small = g:finish("small")

	-- Receiver, feed tray, port, charging handle.
	local receiver = g:box("Receiver", V(50, 60, 330), CF(0, -12, -60), metal)
	g:detail(function()
		for _, sx in ipairs(SIGNS) do
			for _, y in ipairs({ 6, -30 }) do
				g:box("ReceiverRib", V(FINE * 2, 5, 110), CF(sx * 25, y, 35), metal)
			end
		end
		for _, z in ipairs({ -200, 60 }) do
			g:pin("ReceiverPin", 8, CF(0, -34, z), F.steel, 50 + FINE * 2)
		end
	end)
	g:box("FeedTray", V(FINE * 2, 22, 56), CF(-25, 6, -110), F.shadow)
	g:box("EjectionPort", V(FINE * 2, 20, 70), CF(25, -22, -110), F.shadow)
	g:key("Eject", CF(30, -26, -110) * A(0, -60, -40))
	g:group("charge", function()
		g:box("ChargingHandle", V(22, 12, 18), CF(36, 0, -170), F.steel)
		g:ball("ChargingKnob", 14, CF(48, 0, -170), F.polymerDark)
	end)
	g:travel("charge", 110)
	g:hand("ChargeHand", V(56, 20, -164), V(-0.2, -1, 0.1), V(1, 0.2, 0))

	-- Feed cover, hinged at its front, with a rail and the rear sight.
	g:group("cover", function()
		g:prism("FeedCover", V(52, 20, 190), CF(0, 28, -80), 5, metal, "top")
		g:rail("CoverRail", 150, CF(0, 38, -90))
		g:box("CoverLatch", V(30, 10, 18), CF(0, 30, 24), small)
		g:box("RearSightBase", V(30, 8, 26), CF(0, 42, 0), metal)
		for _, sx in ipairs(SIGNS) do
			g:box("RearSightEar", V(4, 18, 18), CF(sx * 12, 55, 0), metal)
		end
		g:shell("RearSight", 4, 10, 3, CF(0, 58, 0), metal, 8)
		g:aperturePlate(CF(0, 0, 0), 46, 58, metal)
	end)
	g:swing("cover", CF(0, 30, -175), -72)
	g:hand("CoverHand", V(-14, 58, 20), V(0.3, -0.6, -1), V(-0.2, 1, 0))

	-- Trigger housing, guard, grip.
	g:box("TriggerHousing", V(34, 18, 110), CF(0, -51, 20), metal)
	g:box("TriggerGuard", V(14, 6, 70), CF(0, -78, 20), metal)
	g:box("TriggerGuard", V(14, 15, 7), CF(0, -67.5, -12), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -68, 12) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -60, 12), 10)
	g:grip(V(0, -60, 52), 14, furniture, { length = 104, depth = 48, front = 24, back = 32, grooves = 3 })
	g:hand("GripHand", V(33, -98, 70), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))

	-- Stock.
	g:cyl("StockTube", 20, 32, CF(0, -8, 115), metal)
	g:rounded("Stock", V(44, 44, 260), CF(0, -10, 255), 13, furniture)
	g:wedge("StockWeb", V(40, 90, 230), CF(0, -77, 270) * A(0, 0, 180), furniture)
	g:prism("Buttpad", V(48, 140, 24), CF(0, -55, 397), 5, F.rubber)
	-- The folded shoulder rest lies on top of the butt.
	g:box("ShoulderRest", V(40, 10, 60), CF(0, 16.5, 350), metal)

	-- Barrel, heat shield, handguard, gas block, bipod, front sight, carry handle, flash hider.
	g:cyl("Barrel", 465, 24, CF(0, 0, -457.5), F.nitride)
	g:heatShield(CF(0, 0, -355), 230, 20)
	g:prism("Handguard", V(52, 34, 200), CF(0, -30, -335), 6, furniture)
	g:rail("HandguardRail", 180, CF(0, -47, -335) * A(180, 0, 0))
	for _, sx in ipairs(SIGNS) do
		g:rail("HandguardRail", 150, CF(sx * 26, -30, -335) * A(0, 0, -sx * 90))
	end
	-- On the rail under the handguard: its teeth are the lowest surface at y -56.5, and a palm lands 14.5 mm
	-- past its keypoint, so the hand's middle sits at -71. At -86 it held nothing but air.
	g:hand("SupportHand", V(-8, -71, -330), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:cyl("GasTube", 245, 16, CF(0, -22, -347.5), metal)
	g:box("GasBlock", V(32, 36, 50), CF(0, -18, -495), metal)
	g:bipod(CF(0, -36, -500))
	g:box("FrontSightBase", V(30, 16, 22), CF(0, 16, -655), metal)
	g:box("FrontSightPost", V(4, 34, 5), CF(0, 41, -655), metal)
	g:box("FrontSight", V(2.4, 9, 3), CF(0, 53.5, -655), metal)
	-- The carry handle is folded down to the left, the way it's carried when firing, so it's out of
	-- the line between the rear aperture and the front post.
	g:at(CF(0, 12, -300), function()
		g:box("CarryHandleBase", V(26, 12, 32), CF(0, 6, 0), metal)
		g:at(CF(0, 12, 0) * A(0, 0, 75), function()
			g:box("CarryHandle", V(14, 80, 14), CF(0, 40, 0), metal)
			g:cylX("CarryHandleGrip", 64, 20, CF(0, 84, 0), F.rubber)
		end)
	end)
	local muzzleZ = -690 + g:birdcage(CF(0, 0, -690), 26)
	g:key("Muzzle", CF(0, 0, muzzleZ))

	-- The 200-round box and the belt climbing into the feed tray: rounds point forward, links between.
	g:group("mag", function()
		g:prism("Magazine", V(80, 110, 120), CF(-14, -100, -110), 6, F.polymerDark)
		g:box("MagazineLid", V(82, 8, 122), CF(-14, -43, -110), F.polymerDark)
		g:detail(function()
			for _, sx in ipairs(SIGNS) do
				g:box("MagazineLatch", V(FINE * 2, 20, 16), CF(-14 + sx * 40, -60, -110), small)
			end
		end)
		local path = { V(-40, -40, -110), V(-44, -26, -110), V(-44, -12, -110), V(-38, 0, -110), V(-30, 8, -110) }
		for index, point in ipairs(path) do
			g:cyl("MagazineBelt", 50, 10, CF(point + V(0, 0, 6)), F.brass)
			g:cyl("MagazineBullet", 12, 8, CF(point + V(0, 0, -25)), F.copper)
			if index < #path then
				local nextPoint = path[index + 1]
				local middle = (point + nextPoint) / 2
				g:box("MagazineLink", V(12, 3, 8), CFrame.lookAt(middle, middle + (nextPoint - point)) * A(0, 90, 0), F.steel)
			end
		end
	end)
	g:key("MagWell", CF(-14, -45, -110))
	g:hand("MagHand", V(-62, -100, -110), V(0.6, 0.5, -0.1), V(-1, 0, 0))

	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.5)
	g:key("Sight", CF(0, 58, 10))
	g.model:SetAttribute("Action", "belt")
	g.model:SetAttribute("Flash", "rifle")
	g.model:SetAttribute("Casing", "rifle")
	return receiver
end

-- The rotary gun, patterned on an M134 carried by hand: six barrels in two clamps round a hub, the
-- rotor housing and gearbox behind them, the drive motor slung underneath, the feeder-delinker on the
-- left fed by a chute from the ammunition box, a battery on the back, a raised carry handle for the
-- left hand and a spade grip under the gearbox for the right, and a red dot sighting between the
-- handle's posts.
STYLES.minigun = function(g)
	local metal = g.skinned and g.skin or F.nitride
	local trim = g.rarityIndex >= 5 and F.gold or F.anodizedDark
	local furniture = g:finish("furniture")
	local small = g:finish("small")

	-- The spinning group: barrels, clamps, hub, muzzle faces.
	g:group("spin", function()
		for index = 0, 5 do
			local offset = CFrame.Angles(0, 0, index / 6 * math.pi * 2) * CF(0, 24, 0)
			g:cyl("Barrel", 600, 16, CF(0, 0, -420) * offset, metal)
			g:cyl("Bore", FINE, 11, CF(0, 0, -720 - FINE / 2) * offset, F.bore)
		end
		g:cyl("BarrelClamp", 16, 76, CF(0, 0, -680), trim)
		g:cyl("BarrelClamp", 14, 72, CF(0, 0, -440), metal)
		g:cyl("BarrelClampHub", 20, 20, CF(0, 0, -697), F.steel)
		g:detail(function()
			for index = 0, 5 do
				local angle = (index + 0.5) / 6 * math.pi * 2
				g:box("BarrelClampBolt", V(6, 6, 16 + FINE * 2), CF(0, 0, -680) * CFrame.Angles(0, 0, angle) * CF(0, 33, 0), F.steel)
			end
		end)
	end)
	g:swing("spin", CF(0, 0, -400) * A(0, 90, 0))
	g:key("Muzzle", CF(0, 0, -724))

	-- Rotor housing, gearbox, rear cap, motor, battery.
	local housing = g:cyl("Receiver", 180, 110, CF(0, 0, -30), metal)
	g:detail(function()
		for index = 0, 3 do
			g:cyl("HousingRib", 6, 110 + FINE * 2, CF(0, 0, -100 + index * 44), trim)
		end
	end)
	g:cyl("Gearbox", 90, 104, CF(0, 0, 105), metal)
	g:cyl("RearCap", 20, 90, CF(0, 0, 160), metal)
	g:cyl("Motor", 130, 56, CF(0, -64, 50), F.anodizedDark)
	g:cyl("MotorCap", 14, 50, CF(0, -64, 122), trim)
	g:box("Battery", V(70, 50, 90), CF(0, -40, 215), F.polymerDark)
	g:detail(function()
		g:box("BatteryLight", V(10, 5, FINE * 2), CF(20, -30, 260 + FINE), F.tritium)
	end)

	-- Feeder-delinker on the left, the chute, the ammunition box under it.
	g:box("Feeder", V(56, 70, 90), CF(-78, 0, -20), metal)
	g:box("FeederChute", V(40, FINE * 2, 60), CF(-78, -35 - FINE, -20), F.shadow)
	g:group("mag", function()
		g:prism("Magazine", V(90, 130, 170), CF(-88, -140, 10), 8, F.od)
		g:box("MagazineLid", V(92, 8, 172), CF(-88, -71, 10), F.od)
		for index = 0, 3 do
			local t = index / 3
			g:box("MagazineChute", V(46, 12, 60), CF(-80 - t * 6, -64 + t * 26, -20) * A(0, 0, (t - 0.5) * 20), F.fabric)
		end
		g:detail(function()
			g:box("MagazineMark", V(FINE * 2, 30, 80), CF(-88 - 45, -140, 10), F.warning)
		end)
	end)
	g:key("MagWell", CF(-78, -40, -20))
	g:hand("MagHand", V(-88, -150, 90), V(0, 0.4, -1), V(-1, 0, 0))

	-- A raised carry handle for the left hand, a spade grip for the right. Each end stands on a pair of
	-- posts either side of the red dot, joined by a crossbar high over it, so nothing crosses the
	-- sight picture.
	for _, z in ipairs({ -90, 70 }) do
		for _, sx in ipairs(SIGNS) do
			g:box("CarryHandlePost", V(10, 112, 18), CF(sx * 30, 96, z), metal)
		end
		g:box("CarryHandleBar", V(74, 14, 22), CF(0, 154, z), metal)
	end
	g:cyl("CarryHandle", 180, 26, CF(0, 160, -10), F.rubber)
	-- The left hand holds the gun up from under the front of the housing; reaching up to the carry
	-- handle put the whole arm across the sight picture.
	g:hand("SupportHand", V(-10, -70, -90), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:grip(V(0, -52, 128), 8, furniture, { length = 112, depth = 50, front = 26, back = 34, grooves = 3 })
	g:hand("GripHand", V(34, -92, 142), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	g:group("trigger", function()
		g:box("Trigger", V(12, 14, 8), CF(0, -66, 102), small)
	end)
	g:swing("trigger", CF(0, -60, 104), 8)

	-- A red dot on a short rail over the housing, sighting under the handle.
	g:box("SightRailBase", V(26, 10, 90), CF(0, 58, -10), metal)
	g:rail("SightRail", 80, CF(0, 63, -10))
	local h = g:redDot(CF(0, 72.5, -10))
	g:key("Sight", CF(0, 72.5 + h, 55))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	g.model:SetAttribute("Action", "rotary")
	g.model:SetAttribute("Flash", "rotary")
	g.model:SetAttribute("Casing", "rifle")
	return housing
end

-- The rocket launcher, patterned on an RPG-7 with a PG-7V round loaded: a launch tube with its rear
-- venturi flaring out behind, two wooden heat shields in steel bands, a trigger grip and a rear grip,
-- folding iron sights on top and the optic on its bracket on the left, and the warhead standing out
-- of the muzzle -- booster, the fat body and the stepped nose cone with its fuse.
local function buildRocketLauncher(g)
	local metal = g.skinned and g.skin or F.parkerized
	local furniture = g:finish("furniture")

	local tube = g:cyl("Receiver", 810, 42, CF(0, 0, -75), metal)
	-- Venturi: stepping out behind the tube, hollow so it reads as the exhaust it is. Each step's wall
	-- reaches in past the one before and overlaps it, so the flare is one piece.
	g:shell("Venturi", 44, 52, 5, CF(0, 0, 350), metal)
	g:shell("Venturi", 44, 66, 8, CF(0, 0, 390), metal)
	g:shell("Venturi", 44, 80, 8, CF(0, 0, 430), metal)
	g:shell("VenturiRim", 8, 86, 7, CF(0, 0, 454), metal)
	g:cyl("VenturiThroat", 8, 44, CF(0, 0, 334), F.bore)
	g:key("Backblast", CF(0, 0, 470))

	-- Wooden heat shields in bands.
	for _, shield in ipairs({ { -205, 190 }, { 120, 160 } }) do
		g:cyl("HeatShield", shield[2], 60, CF(0, 0, shield[1]), F.wood)
		for _, sz in ipairs(SIGNS) do
			g:cyl("HeatShieldBand", 10, 63, CF(0, 0, shield[1] + sz * (shield[2] / 2 - 8)), metal)
		end
	end

	-- Grips, trigger housing, guard.
	g:box("TriggerHousing", V(28, 24, 90), CF(0, -30, -10), metal)
	g:grip(V(0, -42, 14), 6, furniture, { length = 100, depth = 44, front = 24, back = 30, grooves = 2 })
	g:grip(V(0, -26, 170), 4, furniture, { length = 88, depth = 40, front = 24, back = 28 })
	g:box("TriggerGuard", V(12, 6, 66), CF(0, -76, -12), metal)
	g:box("TriggerGuard", V(12, 28, 6), CF(0, -59, -42), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -50, -14) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -46, -14), 10)
	g:hand("GripHand", V(33, -76, 30), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	g:hand("SupportHand", V(-8, -44, -210), V(0.8, 0.55, -0.2), V(-0.4, -1, 0))

	-- Folding iron sights and the optic.
	g:box("FrontSightBase", V(20, 8, 26), CF(0, 24, -330), metal)
	for _, sx in ipairs(SIGNS) do
		g:box("FrontSightEar", V(4, 26, 12), CF(sx * 8, 40, -330), metal)
	end
	g:box("FrontSightPost", V(3.5, 14, 4), CF(0, 34, -330), metal)
	g:box("FrontSight", V(2.4, 8, 3), CF(0, 45, -330), metal)
	g:box("RearSightBase", V(26, 8, 34), CF(0, 24, -40), metal)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSight", V(9, 22, 5), CF(sx * 7, 38, -40), metal)
	end
	g:key("Sight", CF(0, 49, -20))
	-- The optic rides a PGO-7-style side mount: a rail along the tube's left flank (its inner face sunk
	-- into the tube), a riser standing up out of it, and a saddle with two clamp rings that the optic body
	-- sits down into, closed by a lever on the riser.
	g:box("OpticRail", V(11, 22, 76), CF(-20.5, 0, -62), metal)
	g:box("OpticBracket", V(12, 38, 46), CF(-30, 11, -73), metal)
	g:box("OpticSaddle", V(24, 12, 86), CF(-44, 31, -75), metal)
	for _, z in ipairs({ -110, -40 }) do
		g:shell("OpticClamp", 10, 40, 4, CF(-44, 48, z), metal)
	end
	g:detail(function()
		g:box("OpticLever", V(5, 8, 30), CF(-37, 8, -73), F.steel)
		g:ball("OpticLeverKnob", 8, CF(-40, 8, -88), F.steel)
	end)
	g:at(CF(-44, 48, -80), function()
		g:cyl("Optic", 140, 34, CF(0, 0, 0), F.anodizedDark)
		g:cyl("OpticEyecup", 26, 38, CF(0, 0, 83), F.rubber)
		g:cyl("OpticObjective", 20, 38, CF(0, 0, -80), F.anodizedDark)
		g:cyl("OpticLens", FINE, 30, CF(0, 0, -90 - FINE / 2), F.coated)
		g:cylY("OpticKnob", 12, 16, CF(0, 23, 20), F.anodizedDark)
	end)
	g:slingLoop(CF(0, -21, -300))
	g:slingLoop(CF(0, -21, 250))

	-- The PG-7V round, standing out of the muzzle: booster, body, nose cone, fuse. A reload slides a
	-- new one into the tube from the front.
	g:group("round", function()
		g:cyl("RocketBooster", 60, 38, CF(0, 0, -510), F.warhead)
		g:cyl("RocketBody", 120, 85, CF(0, 0, -600), F.warhead)
		g:cyl("RocketBand", 8, 86, CF(0, 0, -548), F.warning)
		g:cyl("RocketCone", 36, 70, CF(0, 0, -678), F.warhead)
		g:cyl("RocketCone", 36, 50, CF(0, 0, -714), F.warhead)
		g:cyl("RocketCone", 30, 30, CF(0, 0, -747), F.warhead)
		g:cyl("RocketFuse", 20, 16, CF(0, 0, -772), F.steel)
		g:ball("RocketTip", 16, CF(0, 0, -782), F.steel)
	end)
	g:key("Load", CF(0, 0, -520))
	g:key("Muzzle", CF(0, 0, -482))

	g.model:SetAttribute("Optic", "iron")
	-- The eye rides over the rear grip, well behind the optic on its bracket, so the optic sits off to
	-- the left of the sight picture instead of filling that side of it.
	g.model:SetAttribute("EyeRelief", 0.9)
	g.model:SetAttribute("Action", "rocket")
	g.model:SetAttribute("Flash", "rocket")
	g.model:SetAttribute("Casing", "none")
	return tube
end

-- The six-shot grenade launcher, patterned on an MGL: a cylinder of six chamber tubes between end
-- plates on a crane that swings out to the left, a top strap carrying a rail and a reflex sight, the
-- short 40mm barrel, a pistol grip and a vertical foregrip, and a collapsible stock on a tube.
local function buildGrenadeLauncher(g)
	local metal = g.skinned and g.skin or F.nitride
	local furniture = g:finish("furniture")
	local axisY = -52

	-- Rear frame, top strap, front frame, barrel.
	local frame = g:box("Receiver", V(64, 160, 36), CF(0, -52, 8), metal)
	-- The top strap sits down into both frames, joining the front of the gun to the back.
	g:prism("TopStrap", V(32, 15.5, 330), CF(0, 35.25, -145), 4, metal, "top")
	g:rail("TopRail", 250, CF(0, 43, -130))
	g:box("Frame", V(70, 150, 30), CF(0, -47, -305), metal)
	g:cyl("Barrel", 280, 54, CF(0, 0, -460), metal)
	g:cyl("Bore", FINE, 42, CF(0, 0, -600 - FINE / 2), F.bore)
	g:detail(function()
		for index = 0, 3 do
			g:cyl("BarrelRib", 10, 54 + FINE * 2, CF(0, 0, -360 - index * 60), F.anodizedDark)
		end
	end)
	g:key("Muzzle", CF(0, 0, -604))

	-- The cylinder: six tubes round an axle, plates front and back, grenade noses showing.
	g:group("crane", function()
		-- The crane arm runs the cylinder's full length into both end plates (short of them, it floated).
		g:box("Crane", V(20, 20, 264), CF(-30, -118, -145), metal)
		g:group("drum", function()
			g:cyl("DrumAxle", 270, 22, CF(0, axisY, -145), F.steel)
			for _, z in ipairs({ -14, -276 }) do
				g:cyl("DrumPlate", 12, 150, CF(0, axisY, z), metal)
			end
			for index = 0, 5 do
				local offset = CF(0, axisY, 0) * CFrame.Angles(0, 0, index / 6 * math.pi * 2) * CF(0, 52, 0)
				g:cyl("DrumTube", 250, 50, offset * CF(0, 0, -145), metal)
				g:group("rounds", function()
					g:ball("RoundNose", 36, offset * CF(0, 0, -283), F.warhead)
				end)
			end
		end)
	end)
	g:swing("drum", CF(0, axisY, -145) * A(0, 90, 0), 60)
	-- Out to the left, clear of the frame and of the hand on the grip (about its own hinge's X, laid along
	-- the bore; the other way round it swung right, across the firing hand).
	g:swing("crane", CF(-34, -128, -145) * A(0, -90, 0), 70)
	g.model:SetAttribute("Parent_drum", "crane")
	g.model:SetAttribute("Parent_rounds", "drum")
	g:key("Load", CF(-120, -40, -300))

	-- Grip, guard, trigger, foregrip, stock.
	g:grip(V(0, -132, 20), 14, furniture, { length = 100, depth = 46, front = 24, back = 32, grooves = 3 })
	g:box("TriggerGuard", V(14, 6, 70), CF(0, -160, -16), metal)
	g:box("TriggerGuard", V(14, 22, 6), CF(0, -146, -48), metal)
	-- The trigger hangs from a housing run forward under the receiver's front (it was in front of the
	-- receiver with nothing above it).
	g:box("TriggerHousing", V(20, 10, 30), CF(0, -129, -20), metal)
	g:group("trigger", function()
		g:box("Trigger", V(6, 24, 6), CF(0, -137, -12) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -132, -12), 10)
	g:hand("GripHand", V(34, -170, 40), V(-0.3, 0.05, -1), V(1, 0.2, 0.3))
	g:foregrip(CF(0, -122, -305))
	g:hand("SupportHand", V(-30, -182, -300), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))
	g:cyl("StockTube", 200, 30, CF(0, -40, 126), F.anodizedDark)
	g:at(CF(0, -40, 230), function()
		g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, furniture)
		g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), furniture)
		g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, F.rubber)
	end)

	-- Reflex sight.
	local h = g:redDot(CF(0, 52.5, -90))
	g:key("Sight", CF(0, 52.5 + h, -20))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	g.model:SetAttribute("Action", "grenade")
	g.model:SetAttribute("Flash", "launcher")
	g.model:SetAttribute("Casing", "none")
	return frame
end

STYLES.launcher = function(g)
	if g.variant.sixShot then
		return buildGrenadeLauncher(g)
	end
	return buildRocketLauncher(g)
end

-- The crossbow, patterned on a modern compound hunting crossbow: an AR-style stock on a buffer tube, a
-- trigger housing with its grip and safety, an aluminium rail with the flight groove, a riser carrying
-- split limbs out to the cams, the string cocked back to the latch with the cables crossing, a
-- foregrip with finger guards, a stirrup, a red dot, and the bolt on the rail with its vanes and
-- broadhead. With the bolt loosed the string lies straight between the cams (the StringRest parts,
-- hidden until then).
STYLES.crossbow = function(g)
	local metal = g.skinned and g.skin or F.anodizedDark
	local furniture = g:finish("furniture")
	local small = g:finish("small")

	-- Stock and trigger housing.
	g:cyl("BufferTube", 170, 30, CF(0, -6, 215), F.anodizedDark)
	g:at(CF(0, -3, 250), function()
		g:rounded("Stock", V(40, 42, 150), CF(0, -3, 0), 13, furniture)
		g:prism("StockCheek", V(34, 8, 120), CF(0, 22, 10), 3, furniture, "top")
		g:wedge("StockWeb", V(34, 76, 130), CF(0, -60, 10) * A(0, 0, 180), furniture)
		g:rounded("Buttpad", V(44, 20, 128), CF(0, -38, 83) * A(90, 0, 0), 8, F.rubber)
	end)
	local housing = g:prism("Receiver", V(40, 42, 220), CF(0, -12, 20), 6, furniture)
	g:rail("TopRail", 150, CF(0, 9, 30))
	g:grip(V(0, -33, 60), 18, furniture, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	g:box("TriggerGuard", V(14, 6, 64), CF(0, -60, 20), furniture)
	g:box("TriggerGuard", V(14, 24, 6), CF(0, -45, -10), furniture)
	g:group("trigger", function()
		g:box("Trigger", V(6, 18, 6), CF(0, -41, 18) * A(-12, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -34, 18), 12)
	g:detail(function()
		g:box("Safety", V(FINE * 2, 10, 22), CF(20, -4, 60), small)
	end)
	g:hand("GripHand", V(33, -70, 80), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- Rail with its flight groove, the latch, the riser.
	g:prism("Rail", V(34, 26, 520), CF(0, -6, -350), 5, metal, "bottom")
	g:box("FlightGroove", V(8, FINE * 2, 500), CF(0, 7 + FINE, -350), F.shadow)
	g:box("Latch", V(22, 8, 20), CF(0, 13, -72), F.steel)
	g:prism("Riser", V(150, 44, 50), CF(0, -4, -633), 8, metal)
	g:box("RiserBlock", V(60, 66, 40), CF(0, -30, -640), metal)
	g:key("Muzzle", CF(0, 12, -660))
	g:hand("ChargeHand", V(-4, 26, -50), V(0.1, -0.3, 1), V(0, 1, 0))

	-- Split limbs sweeping out and back to the cams, the strings and the cables.
	local limbFinish = finishOf(metal.color:Lerp(Color3.new(0, 0, 0), 0.25), Mat.SmoothPlastic)
	local latch = V(0, 12, -70)
	local rest = -600
	for _, sx in ipairs(SIGNS) do
		local root = V(sx * 70, -4, -650)
		local tip = V(sx * 262, -4, -578)
		local along = tip - root
		for _, y in ipairs({ 14, -22 }) do
			local middle = (root + tip) / 2 + V(0, y, 0)
			g:box("Limb", V(along.Magnitude, 9, 40), CFrame.lookAt(middle, middle + along) * A(0, 90, 0), limbFinish)
		end
		g:cylY("Cam", 14, 66, CF(tip), F.anodized)
		g:cylY("CamGroove", 18, 58, CF(tip), F.anodizedDark)
		g:cylY("CamAxle", 50, 10, CF(tip), F.steel)
		local camEdge = tip + V(-sx * 30, 16, 0)
		-- Cocked: from the cam back to the latch.
		g:group("string", function()
			g:box("String", V(3, 3, (latch - camEdge).Magnitude), CFrame.lookAt((camEdge + latch) / 2, latch), F.polymerDark)
		end)
		-- At rest: straight across between the cams, hidden until the bolt is loosed.
		local restEnd = V(0, camEdge.Y, rest)
		local restString = g:box("StringRest", V(3, 3, (restEnd - camEdge).Magnitude), CFrame.lookAt((camEdge + restEnd) / 2, restEnd), F.polymerDark)
		restString.Transparency = 1
		restString:SetAttribute("Anim", "stringRest")
		local cableStart = tip + V(-sx * 22, -14, 0)
		local cableEnd = V(-sx * 24, -40, -610)
		g:box("Cable", V(3, 3, (cableEnd - cableStart).Magnitude), CFrame.lookAt((cableStart + cableEnd) / 2, cableEnd), F.polymerDark)
	end

	-- Foregrip with finger guards, stirrup.
	-- The foregrip hangs from the rail and the finger guards stand on its sides; the stirrup sweeps
	-- forward and down from the riser's front face.
	g:rounded("ForeGrip", V(40, 40, 130), CF(0, -38.5, -330), 14, furniture)
	for _, sx in ipairs(SIGNS) do
		g:box("FingerGuard", V(4, 34, 110), CF(sx * 21.5, -22, -330), furniture)
	end
	g:hand("SupportHand", V(-6, -74.5, -330), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g:box("Stirrup", V(104, 12, 12), CF(0, -72, -702), metal)
	for _, sx in ipairs(SIGNS) do
		g:box("Stirrup", V(12, 62, 12), CF(sx * 44, -46, -678) * A(30, 0, 0), metal)
	end

	-- Red dot.
	local h = g:redDot(CF(0, 18.5, 30))
	g:key("Sight", CF(0, 18.5 + h, 95))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- The bolt on the rail: carbon shaft, nock, three vanes, ferrule and broadhead.
	g:group("round", function()
		g:cyl("RocketShaft", 470, 8, CF(0, 12, -305), F.polymerDark)
		g:cyl("RocketNock", 12, 9, CF(0, 12, -64), finishOf(g.accent, Mat.SmoothPlastic))
		for index = 0, 2 do
			g:box("RocketFletch", V(1.5, 14, 60), CF(0, 12, -110) * CFrame.Angles(0, 0, index / 3 * math.pi * 2) * CF(0, 9, 0), F.shell)
		end
		g:cyl("RocketHead", 30, 10, CF(0, 12, -555), F.steel)
		for index = 0, 2 do
			g:wedge("RocketBlade", V(1.5, 12, 34), CF(0, 12, -580) * CFrame.Angles(0, 0, index / 3 * math.pi * 2) * CF(0, 6, 0), F.bright)
		end
	end)
	g:key("Load", CF(0, 30, -300))

	g.model:SetAttribute("Action", "crossbow")
	g.model:SetAttribute("Flash", "crossbow")
	g.model:SetAttribute("Casing", "none")
	return housing
end

-- The bubble gun: a pneumatic rifle built like a real one, in brass, copper, glass and black polymer.
-- A glass reservoir of soap solution rides on the left with a pressure gauge on its front cap and a
-- copper line to the barrel; a pump under the brass barrel charges it; the muzzle is a stepped bell
-- carrying a wand ring with a film of soap across it; the canister of solution plugs in under the
-- receiver ahead of the grip; the stock is a skeleton of brass tubes with a leather cheek pad. The
-- Burster carries the bigger reservoir.
STYLES.blaster = function(g)
	local v = g.variant
	local body = g.skinned and g.skin or g:finish("receiver")
	local furniture = g:finish("furniture")
	local small = g:finish("small")
	local tankDia = v.bigTank and 76 or 60
	local tankLength = v.bigTank and 180 or 150

	-- Receiver, rail and red dot.
	local receiver = g:rounded("Receiver", V(46, 56, 220), CF(0, -8, -10), 14, body)
	g:rail("TopRail", 150, CF(0, 20, -10))
	local h = g:redDot(CF(0, 29.5, 0))
	g:key("Sight", CF(0, 29.5 + h, 65))
	g.model:SetAttribute("Optic", "reddot")
	g.model:SetAttribute("EyeRelief", 0.66)

	-- Brass barrel, the stepped bell, the wand ring with its film of soap.
	g:cyl("Barrel", 260, 24, CF(0, 0, -250), F.brass)
	g:cyl("MuzzleBrake", 20, 32, CF(0, 0, -390), F.brass)
	g:cyl("MuzzleBrake", 16, 42, CF(0, 0, -408), F.brass)
	g:cyl("MuzzleBrake", 10, 54, CF(0, 0, -421), F.brass)
	g:cyl("Bore", FINE, 20, CF(0, 0, -426 - FINE / 2), F.bore)
	for index = 0, 15 do
		g:box("WandRing", V(12.2, 3, 3), CF(0, 0, -440) * CFrame.Angles(0, 0, index / 16 * math.pi * 2) * CF(0, 30, 0), F.brass)
	end
	-- Three spokes carry the ring off the bell's face, each running from inside the bell out to the ring.
	for index = 0, 2 do
		g:box("WandSpoke", V(2, 20, 2), CF(0, 0, -432) * CFrame.Angles(0, 0, index / 3 * math.pi * 2) * CF(0, 25, 0) * A(-58, 0, 0), F.brass)
	end
	-- The film's edge sits a millimetre into the ring all round.
	g:cyl("WandFilm", 0.6, 59, CF(0, 0, -440), F.film)
	g:key("Muzzle", CF(0, 0, -444))

	-- Pump tube and pump.
	g:cyl("PumpTube", 260, 22, CF(0, -34, -250), F.copper)
	g:group("pump", function()
		g:rounded("Pump", V(40, 34, 110), CF(0, -36, -230), 12, furniture)
		g:detail(function()
			for index = 0, 4 do
				g:box("PumpRib", V(40 + FINE * 2, 22, 5), CF(0, -40, -270 + index * 20), furniture)
			end
		end)
	end)
	g:travel("pump", 60)
	g:hand("SupportHand", V(-6, -62, -230), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))
	g.model:SetAttribute("SupportGroup", "pump")
	g:hand("ChargeHand", V(-6, -62, -230), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- The reservoir on the left: glass, the solution in it, bubbles, brass caps, tie rods, brackets.
	g:at(CF(-26 - tankDia / 2, 6, -40), function()
		g:cyl("Tank", tankLength, tankDia, CF(0, 0, 0), F.tank)
		g:cyl("TankLiquid", tankLength - 10, tankDia - 8, CF(0, -3, 0), F.soap)
		for index = 1, 6 do
			local angle = index * 2.4
			g:ball("TankBubble", 5 + (index % 3) * 2.5, CF(math.cos(angle) * tankDia * 0.2, tankDia * 0.14 - index * 3, -tankLength * 0.4 + index * tankLength * 0.12), F.bubble)
		end
		for _, sz in ipairs(SIGNS) do
			g:cyl("TankCap", 12, tankDia + 6, CF(0, 0, sz * (tankLength / 2 + 6)), F.brass)
		end
		for index = 0, 2 do
			local angle = math.rad(90 + index * 120)
			g:cyl("TankRod", tankLength + 24, 4, CF(math.cos(angle) * (tankDia / 2 + 4), math.sin(angle) * (tankDia / 2 + 4), 0), F.brass)
		end
		for _, sz in ipairs(SIGNS) do
			g:box("TankBracket", V(26, 16, 14), CF(tankDia / 2 + 6, 0, sz * tankLength * 0.3), F.brass)
		end
		-- Pressure gauge on the front cap, facing back at the shooter.
		g:box("GaugeStem", V(6, 12, 6), CF(0, tankDia / 2 + 6, -tankLength / 2 - 6), F.brass)
		g:at(CF(0, tankDia / 2 + 26, -tankLength / 2 - 6), function()
			g:cyl("Gauge", 10, 32, CF(0, 0, 0), F.brass)
			g:cyl("GaugeFace", FINE, 26, CF(0, 0, 5 + FINE / 2), F.dial)
			g:box("GaugeNeedle", V(1.2, 10, FINE * 2), CF(0, 0, 5 + FINE * 2) * A(0, 0, -40) * CF(0, 4, 0), F.redDot)
			g:cyl("GaugeGlass", FINE, 24, CF(0, 0, 5 + FINE * 3.5), F.lens)
		end)
	end)
	-- The copper line from the reservoir's front cap to the barrel.
	local line = { V(-26 - tankDia / 2, 6, -40 - tankLength / 2 - 12), V(-26 - tankDia / 2, 6, -150), V(-18, 4, -170), V(-10, 0, -190) }
	for index = 1, #line - 1 do
		local from, to = line[index], line[index + 1]
		g:box("CopperLine", V(6, 6, (to - from).Magnitude), CFrame.lookAt((from + to) / 2, to), F.copper)
		g:ball("CopperElbow", 8, CF(to), F.copper)
	end

	-- Grip, guard, trigger.
	g:grip(V(0, -36, 50), 16, furniture, { length = 100, depth = 46, front = 22, back = 30, grooves = 3 })
	g:box("TriggerGuard", V(12, 6, 60), CF(0, -66, 10), body)
	g:box("TriggerGuard", V(12, 27, 6), CF(0, -49.5, -20), body)
	g:group("trigger", function()
		-- Its top runs up into the body (it hung a millimetre under it).
		g:box("Trigger", V(6, 24, 6), CF(0, -43, -2) * A(-10, 0, 0), F.brass)
	end)
	g:swing("trigger", CF(0, -38, 0), 12)
	g:hand("GripHand", V(31, -72, 70), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))

	-- The canister of solution.
	g:group("mag", function()
		g:cylY("Magazine", 90, 40, CF(0, -80, -70), F.tank)
		g:cylY("MagazineLiquid", 80, 34, CF(0, -83, -70), F.soap)
		g:cylY("MagazineLabel", 30, 40 + FINE * 2, CF(0, -85, -70), finishOf(g.accent:Lerp(Color3.fromRGB(40, 40, 44), 0.35), Mat.SmoothPlastic))
		g:cylY("MagazineCap", 8, 36, CF(0, -129, -70), F.brass)
	end)
	g:key("MagWell", CF(0, -36, -70))
	g:hand("MagHand", V(-26, -120, -70), V(0.4, 0.5, -0.1), V(-1, 0, 0))

	-- Skeleton stock of brass tubes, a leather cheek pad, a rubber butt.
	g:cyl("StockTube", 200, 12, CF(0, 4, 200), F.brass)
	local from, to = V(0, -30, 100), V(0, -80, 300)
	g:box("StockTube", V(12, 12, (to - from).Magnitude), CFrame.lookAt((from + to) / 2, to), F.brass)
	g:rounded("Buttpad", V(44, 20, 130), CF(0, -34, 306) * A(90, 0, 0), 8, F.rubber)
	g:rounded("CheekPad", V(30, 16, 90), CF(0, 16, 210), 6, F.leather)

	g.model:SetAttribute("Action", "blaster")
	g.model:SetAttribute("Flash", "bubble")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

-- The Golden Sahur Cannon: a big-bore lever gun in the pattern of a Winchester 1887, gold-plated and
-- engraved. A deep receiver with a loading gate on the right and dark inlay down both sides, the finger
-- lever that swings down to cycle it, an exposed hammer, an octagonal barrel banded in gold ending in
-- a bell mouth, the magazine tube under it with a walnut forend, a buckhorn rear sight and a gold bead,
-- and a walnut stock with a gold butt plate.
STYLES.cannon = function(g)
	local gold = g.skinned and g.skin or F.gold
	local deep = g.skinned and g.skin or F.goldDeep

	local receiver = g:rounded("Receiver", V(44, 64, 170), CF(0, -12, -30), 12, gold)
	-- The gate stands proud of the side and reaches in past the engraving's inlay, so neither of its
	-- faces lies in the inlay's planes.
	g:box("LoadingGate", V(5.5, 22, 44), CF(22.15, -20, -40), F.blued)
	g:key("Load", CF(40, -20, -40))
	for _, sx in ipairs(SIGNS) do
		g:engraving(CF(sx * 22, -8, -40), 120, 34, F.blued)
	end

	g:group("hammer", function()
		g:box("Hammer", V(8, 22, 12), CF(0, 24, 48) * A(28, 0, 0), F.blued)
		g:box("HammerSpur", V(10, 6, 16), CF(0, 35, 56) * A(45, 0, 0), F.blued)
	end)
	g:swing("hammer", CF(0, 14, 44), -30)

	-- The finger lever, hinged under the front of the receiver.
	g:group("lever", function()
		g:box("Lever", V(10, 6, 60), CF(0, -47, 20), gold)
		g:box("Lever", V(10, 40, 8), CF(0, -66, 56) * A(-12, 0, 0), gold)
		g:box("Lever", V(10, 8, 64), CF(0, -88, 82), gold)
		g:box("Lever", V(10, 42, 8), CF(0, -68, 112) * A(20, 0, 0), gold)
	end)
	g:swing("lever", CF(0, -44, -10), 50)
	g:group("trigger", function()
		g:box("Trigger", V(6, 16, 5), CF(0, -54, 40) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -46, 40), 10)

	-- Octagonal barrel in gold bands, the bell, the bead and buckhorn.
	g:prism("Barrel", V(34, 34, 420), CF(0, 0, -325), 10, deep)
	for _, z in ipairs({ -150, -330, -500 }) do
		g:prism("BarrelBand", V(38.8, 38.8, 12), CF(0, 0, z), 11.4, gold)
	end
	g:cyl("MuzzleBrake", 25, 40, CF(0, 0, -547.5), gold)
	g:cyl("MuzzleBrake", 20, 54, CF(0, 0, -570), gold)
	g:cyl("MuzzleBrake", 14, 68, CF(0, 0, -587), gold)
	g:cyl("Bore", FINE, 36, CF(0, 0, -594 - FINE / 2), F.bore)
	g:key("Muzzle", CF(0, 0, -600))
	-- Sights stand tall enough that the line over them clears the bell mouth, and the eye rides high
	-- enough over the receiver that the camera's near plane never cuts into it. The bead's top is on
	-- the line; the buckhorn's notch bottom sits 2 mm under it, between the horns.
	g:box("FrontSight", V(3, 18, 6), CF(0, 25, -520), gold)
	g:ball("FrontBead", 5, CF(0, 34.5, -520), F.gold)
	g:box("RearSightBase", V(20, 12, 14), CF(0, 23, -150), gold)
	for _, sx in ipairs(SIGNS) do
		g:box("RearSightHorn", V(6, 15, 4), CF(sx * 7, 36, -150), gold)
	end
	g:box("RearSight", V(8, 7, 4), CF(0, 31.5, -150), gold)
	g:key("Sight", CF(0, 37, -100))
	g.model:SetAttribute("Optic", "iron")
	g.model:SetAttribute("EyeRelief", 0.5)

	-- Magazine tube and forend.
	g:cyl("MagTube", 350, 26, CF(0, -32, -290), gold)
	g:cyl("MagCap", 14, 29, CF(0, -32, -472), gold)
	g:rounded("ForeGrip", V(46, 38, 185), CF(0, -30, -208), 13, F.woodDark)
	g:box("ForendCap", V(48.8, 40.8, 10), CF(0, -30, -305), gold)
	g:hand("SupportHand", V(-8, -62, -210), V(0.8, 0.5, -0.25), V(-0.4, -1, 0))

	-- Walnut stock with a gold butt plate.
	g:rounded("Grip", V(34, 40, 110), CF(0, -22, 110) * A(8, 0, 0), 12, F.woodDark)
	g:rounded("Stock", V(42, 50, 250), CF(0, -44, 290) * A(4, 0, 0), 14, F.woodDark)
	g:wedge("StockWeb", V(40, 90, 230), CF(0, -110, 300) * A(0, 0, 180), F.woodDark)
	g:box("Buttplate", V(44, 145, 8), CF(0, -85, 418), gold)
	g:hand("GripHand", V(30, -32, 90), V(-0.3, 0.2, -1), V(1, 0.2, 0.3))
	g.model:SetAttribute("GripGroup", "lever")

	g.model:SetAttribute("Action", "lever")
	g.model:SetAttribute("Flash", "cannon")
	g.model:SetAttribute("Casing", "shell")
	return receiver
end

-- The Delulu Railgun: a bullpup electromagnetic rifle, engineered rather than toy-like. A chamfered
-- body with the power cell behind the grip, two copper conductor rails in polymer insulators running
-- out ahead of it through six coil braces that glow along their inner faces, capacitors down the left
-- side and cooling fins down the right, a charging lever, a long scope, a foregrip under the rails,
-- and a crown of light at the muzzle.
STYLES.railgun = function(g)
	local body = g.skinned and g.skin or F.anodizedDark
	local furniture = g:finish("furniture")
	local small = g:finish("small")
	local energy = F.energy

	local receiver = g:prism("Receiver", V(62, 84, 500), CF(0, -22, 120), 8, body)
	g:prism("TopCover", V(54, 14, 360), CF(0, 27, 90), 5, furniture, "top")
	g:rail("TopRail", 300, CF(0, 34, 60))
	local h = g:scope(CF(0, 43.5, 80), "long")
	g:key("Sight", CF(0, 43.5 + h, 260))
	g.model:SetAttribute("Optic", "scope")
	g.model:SetAttribute("EyeRelief", 0.6)

	-- Rails and coil braces.
	for _, sx in ipairs(SIGNS) do
		g:box("RailInsulator", V(14, 40, 640), CF(sx * 22, 0, -450), F.polymerDark)
		g:box("RailConductor", V(FINE * 2, 26, 620), CF(sx * 15, 0, -450), F.copper)
	end
	for index = 0, 5 do
		local z = -200 - index * 105
		for _, sy in ipairs(SIGNS) do
			g:box("Coil", V(76, 10, 20), CF(0, sy * 25, z), body)
			g:box("CoilGlow", V(40, FINE * 2, 16), CF(0, sy * 20, z), energy)
		end
		for _, sx in ipairs(SIGNS) do
			g:box("Coil", V(10, 40, 20), CF(sx * 33, 0, z), body)
		end
	end
	-- The crown clamps the ends of the rail insulators: its sides bear on them and it overlaps their
	-- front ends.
	for _, sy in ipairs(SIGNS) do
		g:box("MuzzleCrown", V(84, 12, 16), CF(0, sy * 28, -775), body)
		g:box("MuzzleGlow", V(46, FINE * 2, 12), CF(0, sy * 22, -775), energy)
	end
	for _, sx in ipairs(SIGNS) do
		g:box("MuzzleCrown", V(12, 44, 16), CF(sx * 34.5, 0, -775), body)
	end
	g:key("Muzzle", CF(0, 0, -790))

	-- Capacitors down the left, cooling fins down the right, the charging lever.
	for _, y in ipairs({ 6, -30 }) do
		g:cyl("Capacitor", 160, 26, CF(-44, y, 60), F.anodized)
		for _, sz in ipairs(SIGNS) do
			g:cyl("CapacitorBand", 8, 26 + FINE * 2, CF(-44, y, 60 + sz * 60), energy)
		end
	end
	for index = 0, 6 do
		g:box("CoolingFin", V(12, 50, 3), CF(37, -10, -100 + index * 12), body)
	end
	g:group("charge", function()
		g:box("ChargingHandle", V(8, 12, 50), CF(35, 8, 200), small)
		g:ball("ChargingKnob", 12, CF(41, 8, 228), F.polymerDark)
	end)
	g:travel("charge", 40)
	g:hand("ChargeHand", V(52, 22, 226), V(-0.2, -1, 0.1), V(1, 0.2, 0))

	-- Grip, guard, trigger, foregrip.
	g:grip(V(0, -64, 14), 16, furniture, { length = 104, depth = 48, front = 22, back = 31, grooves = 3 })
	g:box("TriggerGuard", V(14, 6, 70), CF(0, -94, -10), body)
	g:box("TriggerGuard", V(14, 27, 6), CF(0, -77.5, -42), body)
	g:group("trigger", function()
		-- Its top runs up into the body (it hung a millimetre under it).
		g:box("Trigger", V(6, 24, 6), CF(0, -71, -12) * A(-10, 0, 0), F.steel)
	end)
	g:swing("trigger", CF(0, -66, -12), 10)
	g:hand("GripHand", V(33, -102, 34), V(-0.3, 0.12, -1), V(1, 0.1, 0.3))
	-- The foregrip's clamp hangs from a bridge across both rail insulators (under the gap between them it
	-- met only their inside edges).
	g:box("ForeGripBridge", V(55, 6, 40), CF(0, -21.6, -357), body)
	g:foregrip(CF(0, -20, -357))
	g:hand("SupportHand", V(-27, -76, -351), V(0.45, -0.1, -1), V(-1, 0.1, 0.4))

	-- The power cell behind the grip, its charge showing through a window on each side.
	g:group("mag", function()
		g:prism("Magazine", V(44, 100, 70), CF(0, -104, 150), 6, F.polymerDark)
		for _, sx in ipairs(SIGNS) do
			g:box("MagazineGlow", V(FINE * 2, 60, 14), CF(sx * 22, -104, 150), energy)
		end
	end)
	g:key("MagWell", CF(0, -64, 150))
	g:hand("MagHand", V(-30, -160, 150), V(0.4, 0.5, -0.1), V(-1, 0, 0))

	-- Butt.
	g:rounded("Buttpad", V(66, 20, 110), CF(0, -24, 380) * A(90, 0, 0), 8, F.rubber)
	g:prism("CheekRest", V(46, 12, 150), CF(0, 40, 300), 4, furniture, "top")

	g.model:SetAttribute("Action", "energy")
	g.model:SetAttribute("Flash", "rail")
	g.model:SetAttribute("Casing", "none")
	return receiver
end

--------------------------------------------------------------------------------
-- Finishing
--------------------------------------------------------------------------------

function GunModels.Supports(style)
	return STYLES[style or "rifle"] ~= nil
end

-- The sight line, as the old code named it: an invisible part on the line the eye looks along. Its
-- keypoint (KP_Sight) is the authority; this part is kept for anything still looking for it.
local function markSight(g)
	local sight = g.model:GetAttribute("KP_Sight")
	if not sight then
		return
	end
	local part = Instance.new("Part")
	part.Name = "AimPoint"
	part.Size = V(0.02, 0.02, 0.02)
	part.CFrame = sight
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Parent = g.model
end

-- What a creative gun's builder gets besides the Builder `g`: the finishes and helpers, and STYLES so it
-- can borrow a stock mechanism. Read-only by convention.
GunModels.Kit = {
	F = F, finishOf = finishOf, V = V, CF = CF, A = A, SIGNS = SIGNS, RELIEF = RELIEF, FINE = FINE, MM = MM,
	Mat = Mat, STYLES = STYLES,
}

function GunModels.Build(def, color, material, options)
	options = options or {}
	local g = Builder.new(def, color, material, options)
	-- A creative or workshop gun (their Builders, by id) builds itself; everything after this (finish,
	-- sight marker, z-fight, receiver, muzzle, welds) is shared with the stock guns.
	local own = (GunModelsCreative.Builders and GunModelsCreative.Builders[def.id])
		or (GunModelsWorkshop.Builders and GunModelsWorkshop.Builders[def.id])
	local build = own and function(builder)
		return own(builder, GunModels.Kit)
	end or STYLES[g.style] or STYLES.rifle
	local receiver = build(g)
	ArsenalFinish.Apply(g.model, def.id, options.skinned == true)
	markSight(g)

	local model = g.model
	model:SetAttribute("WeaponId", def.id)
	model:SetAttribute("Style", g.style)
	model:SetAttribute("Detail", g.high and "high" or "low")

	ZFight.Fix({ model }, GunModels.ZFightOptions)

	model.PrimaryPart = receiver
	receiver.Name = "Receiver"
	-- Pivot on the design origin (the bore above the trigger), facing -Z, whatever the receiver's own
	-- orientation.
	receiver.PivotOffset = receiver.CFrame:Inverse()

	local muzzle = model:GetAttribute("KP_Muzzle") or CFrame.new(0, 0, -1)
	local attachment = Instance.new("Attachment")
	attachment.Name = "Muzzle"
	attachment.CFrame = receiver.CFrame:ToObjectSpace(muzzle)
	attachment.Parent = receiver

	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part ~= receiver then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = receiver
			weld.Part1 = part
			weld.Parent = part
		end
	end
	return model, receiver
end

return GunModels
