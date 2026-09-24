-- The first-person viewmodel: your gun, held in your own Roblox arms, animated by the gun's own
-- mechanism. ModuleScript; CombatClient drives it.
--
--   local vm = Viewmodel.new(def, { color, material, skinned, character, parent, onEvent })
--   vm:Equip(rack)            draw it (and rack it, the first time this gun comes out)
--   vm:Fire(roundsLeft)       recoil, the mechanism cycling, the muzzle flash and the casing
--   vm:StartReload(seconds, roundsLeft, magSize) / vm:StopReload()
--   vm:Inspect()
--   vm:Update(dt, input)      once a frame; returns what the frame needs to know (scope, muzzle, laser)
--   vm:Destroy()
--
-- Nothing here guesses at a gun from part names. GunModels writes an animation contract onto every
-- model -- which parts move together (the Anim attribute), where the hands go (KP_ keypoints), where
-- hinges turn and how far slides travel (Pivot_/Swing_/Travel_) -- and this reads it. A reload is a
-- clip: keyframes for the gun's own motion, each hand's target, and every moving part, laid on the
-- reload's real duration, with sounds and dropped magazines fired as events along the way. Each
-- mechanism has its own clip: an AR's magazine swap and charging handle, a pistol's dropped magazine
-- and slide release, a revolver's crane and speedloader, a pump gun fed a shell at a time, a double
-- barrel broken open, a lever gun, a belt-fed cover and box, a rocket slid in from the muzzle.
--
-- Everything is built to work in edit mode too (no LocalPlayer, no services it doesn't need), so the
-- gallery can pose a viewmodel at any moment of any clip and photograph it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GunModels = require(Shared:WaitForChild("GunModels"))

local Viewmodel = {}
Viewmodel.__index = Viewmodel

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad

local function A(x, y, z)
	return CFrame.Angles(rad(x or 0), rad(y or 0), rad(z or 0))
end

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

local function localOnly(part)
	part.Anchored = true
	part.CanCollide = false
	-- The viewmodel lives under the camera; the crosshair raycast would otherwise hit your own gun.
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
end
Viewmodel.LocalOnly = localOnly

-- Hides or shows a gun part. A SurfaceGui draws whatever its host's transparency is, so the lettering
-- stamped on a slide or magazine (ArsenalFinish) went on showing with the part hidden: hanging in
-- mid-air where the magazine was during a reload, and over the scope picture when the whole gun is
-- hidden behind it (#72). Its guis go with it.
local function veil(part, hidden)
	part.LocalTransparencyModifier = hidden and 1 or 0
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("SurfaceGui") then
			child.Enabled = not hidden
		end
	end
end
Viewmodel.Veil = veil

--------------------------------------------------------------------------------
-- Arms
--
-- The player's own Roblox arms, in their skin colour and their shirt, cloned into the viewmodel and
-- posed to hold the gun. Each arm is two bones solved to reach its hand: the upper arm from the
-- shoulder to the elbow, the lower arm on to the wrist, and the hand on the gun. The elbow is pulled
-- toward a pole below and outside the shoulder, the way elbows hang when you hold a rifle.
--
-- An R15 avatar gives its UpperArm, LowerArm and Hand, lined up by their own rig attachments so any
-- body package fits. An R6 avatar's single arm is cut into an upper and a lower half. With no
-- character to copy (the gallery in edit mode, or an avatar still loading), plain blocks stand in, in
-- a default skin and shirt colour. Everything is slimmed to ARM_THICKNESS across and stretched to the
-- bone lengths: a Roblox arm at full size fills a third of the screen from the shoulder.
--
-- A Humanoid of their own, with a copy of the avatar's Shirt, is what dresses the arms in the shirt.
--------------------------------------------------------------------------------

-- Studs, view space: where the shoulders are and where the elbows hang toward.
local SHOULDER = { [1] = V(0.72, -0.78, 0.3), [-1] = V(-0.7, -0.8, 0.25) }
local POLE = { [1] = V(1.6, -2.2, 0.4), [-1] = V(-1.0, -2.4, -0.2) }
local UPPER, FOREARM = 1.12, 1.0
-- Slimmer than an avatar's own (1 stud): at 0.4 the trigger arm of a straight-stocked gun filled half the
-- screen beside the sights.
local ARM_THICKNESS = 0.34
-- A hand, in the palm frame the rig builds: across the palm, wrist to fingertips, and palm to back. Scaled
-- on each axis rather than by the arm's width alone, which left an avatar's hand 89 mm thick and 36 mm
-- long -- a stub that stopped short of the grip instead of closing on it.
-- The palm alone: the fingers below are parts of their own, and together they come to a hand about as long
-- as before (0.3) with a hinge at the knuckles.
local HAND_WIDTH, HAND_LENGTH, HAND_THICKNESS = 0.3, 0.2, 0.11
-- How far past the keypoint the palm's inner face goes, so the hand presses into what it holds rather
-- than resting outside it. The face lands at (keypoint - HAND_SINK) whatever the hand's thickness, and the
-- guns' keypoints were authored against this depth, so it stays where it was when the hand was thicker.
local HAND_SINK = 0.055

-- An avatar hand's size in its own axes: X palm to back, Y wrist to fingertips, Z across the palm.
local function handScale(size)
	return V(HAND_THICKNESS / math.max(size.X, 1e-3), HAND_LENGTH / math.max(size.Y, 1e-3), HAND_WIDTH / math.max(size.Z, 1e-3))
end
-- Fingers. One box per hand can meet a grip but it cannot close round one, which up close reads as a slab
-- pressed against the gun rather than a hand holding it. These are two segments hinged at the knuckles,
-- swinging down over the front of whatever the palm is on and turning under it. Open, they carry straight
-- on from the palm; closed, they wrap.
local FINGER_SPAN = 0.22 -- across the hand: the four fingers, narrower than the whole palm
local FINGER_THICKNESS = 0.055
local FINGER_UPPER, FINGER_LOWER = 0.105, 0.09
-- Four fingers with daylight between them, not one slab the width of four: a slab can close round a grip
-- and still read as a mitten, and the silhouette is what a player judges. The lean makes the bundle
-- uneven, as a hand's is, so the four don't move as one plank.
local FINGER_COUNT = 4
local FINGER_GAP = 0.012
local FINGER_WIDTH = (FINGER_SPAN - FINGER_GAP * (FINGER_COUNT - 1)) / FINGER_COUNT
local FINGER_LEAN = { 0.92, 1, 0.98, 0.9 }
local FINGER_X = {}
for i = 1, FINGER_COUNT do
	FINGER_X[i] = -FINGER_SPAN / 2 + FINGER_WIDTH / 2 + (i - 1) * (FINGER_WIDTH + FINGER_GAP)
end
-- The knuckle line, ahead of the keypoint: far enough forward to clear the front face of a grip, but never
-- past the palm's own reach. A handguard runs the length of the gun, and fingers close round it where the
-- hand actually is, not out by the muzzle.
local KNUCKLE, KNUCKLE_MAX = 0.1, 0.135
local FINGER_CLEAR = 0.008
-- How far a finger may press into what it holds before the close is called too far (1.6 mm: pressed, not
-- through), and how finely the close is swept looking for that point.
local FINGER_PRESS = 0.006
local CURL_STEPS = 24
-- Below this a finger has nothing worth closing on, and is kept inside the palm rather than stood out.
local FINGER_MIN_CLOSE = 0.3
-- How deep under the palm a grip can be and still be something to close on, and the step the search walks.
local GRIP_REACH = 0.34
local GRIP_STEP = 0.0038
-- The depths below the palm at which the fingers' own band is measured: 12, 24 and 36 mm down, which is
-- where the fingers are, rather than at the middle of whatever the palm sits on.
local FINGER_LEVELS = { 0.0456, 0.0912, 0.1368 }
-- With nothing measured under the palm the fingers close on themselves, which is what a hand reaching for
-- a magazine or a pocket does.
local FIST = {}
for i = 1, FINGER_COUNT do
	FIST[i] = { knuckle = KNUCKLE, turn = 1, cap = 1 }
end

local DEFAULT_SKIN = Color3.fromRGB(234, 184, 146)
local DEFAULT_SHIRT = Color3.fromRGB(52, 56, 70)
local SIDE_NAME = { [1] = "Right", [-1] = "Left" }

-- A Roblox hand hangs with its fingers down (-Y) and the back of the hand outward (+X on the right,
-- -X on the left). The palm frame the gun gives has the fingers along -Z and the back of the hand up
-- (+Y). This turns one into the other.
local HAND_AXES = {
	[1] = CFrame.fromMatrix(Vector3.zero, V(0, 1, 0), V(0, 0, 1), V(1, 0, 0)),
	[-1] = CFrame.fromMatrix(Vector3.zero, V(0, -1, 0), V(0, 0, 1), V(-1, 0, 0)),
}

-- What a hand keypoint has under it, in the keypoint's own frame: how far material runs below the palm's
-- inner face (a grip's depth, palm side to far side), and how far the face the fingers come over stands
-- ahead of the keypoint. Measured from the parts' own shapes so the fingers close on what is actually
-- there; nil when the palm is not on anything, and the fingers then close on themselves.
local function shapeNode(part, offset)
	local kind = "box"
	if part:IsA("Part") then
		if part.Shape == Enum.PartType.Cylinder then
			kind = "cyl"
		elseif part.Shape == Enum.PartType.Ball then
			kind = "ball"
		end
	end
	return { inverse = offset:Inverse(), half = part.Size / 2, kind = kind }
end

local function insideNode(node, point)
	local p = node.inverse * point
	local h = node.half
	if node.kind == "cyl" then
		local r = math.min(h.Y, h.Z)
		return math.abs(p.X) <= h.X and p.Y * p.Y + p.Z * p.Z <= r * r
	elseif node.kind == "ball" then
		return p.Magnitude <= math.min(h.X, h.Y, h.Z)
	end
	-- A wedge counts as its whole box: the fingers then stop a little further out than they need to,
	-- which is the safe way to be wrong.
	return math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
end

-- The two finger segments, as boxes, for a given knuckle plane: `curl` swings the upper one down over
-- what the palm is on, `turn` decides how much further the lower one comes in under it. Both the build's
-- measuring and the pose itself go through here, so they cannot drift apart.
local function fingerAt(knuckleFrame, curl, turn)
	local upper = knuckleFrame * A(-90 * curl, 0, 0)
	local lower = upper * CF(0, 0, -FINGER_UPPER) * A(-90 * curl * turn, 0, 0)
	return upper * CF(0, 0, -FINGER_UPPER / 2), lower * CF(0, 0, -FINGER_LOWER / 2)
end

local function gripShape(offsets, keyFrame)
	local origin = keyFrame.Position
	local near = {}
	for part, offset in pairs(offsets) do
		if part.Transparency < 1 and (offset.Position - origin).Magnitude <= GRIP_REACH + part.Size.Magnitude / 2 then
			table.insert(near, shapeNode(part, offset))
		end
	end
	if #near == 0 then
		return nil
	end
	local function solid(cframe)
		local point = cframe.Position
		for _, node in ipairs(near) do
			if insideNode(node, point) then
				return node
			end
		end
		return nil
	end
	-- Straight down from the palm's inner face: where material starts, and the deepest still under the
	-- hand. Walking the whole way rather than stopping at the first gap keeps a grip with a hollow between
	-- its panels in one piece.
	local palm = keyFrame * CF(0, -HAND_SINK, 0)
	local first, depth
	local d = 0
	while d <= GRIP_REACH do
		if solid(palm * CF(0, -d, 0)) then
			first = first or d
			depth = d
		end
		d += GRIP_STEP
	end
	-- Nothing under the palm, or nothing until well past it: nothing to close on.
	if not depth or first > 0.02 then
		return nil
	end
	-- How far forward the face the fingers come over stands, looked for only as far as the knuckles can
	-- reach: on a grip this finds its front, and on a handguard that runs on to the muzzle it stops at
	-- the end of the hand, which is where the fingers close.
	--
	-- Measured at several depths and taking the NEAREST face, not one depth and the furthest. A trigger
	-- guard sits above the fingers and reaches much further forward than the grip they close on, so
	-- measuring at the middle of the grip put every knuckle line out at the guard: all 62 guns came back
	-- with the line at its 35.5 mm limit and 93 of 100 anchors then could not close at all.
	-- Each finger stands at its own place along what the hand holds, and what is in front of it there is
	-- its own business: a grip is raked, so its face moves back as you go down it, and a trigger guard
	-- stands far forward of the top finger and nowhere near the bottom one. Measuring once for the whole
	-- hand gave every finger the topmost obstruction's knuckle line, and three of four then had no room
	-- to close -- 50 of 100 anchors closed exactly one finger. So the line, what it wraps, and how far it
	-- may close are all measured per finger.
	local function frontAt(across)
		local nearest
		for _, level in ipairs(FINGER_LEVELS) do
			local at = palm * CF(across, -level, 0)
			local reach, z = 0, 0
			while z <= KNUCKLE_MAX do
				if solid(at * CF(0, 0, -z)) then
					reach = z
				end
				z += GRIP_STEP
			end
			-- A level below the bottom of what the hand holds finds nothing and says nothing.
			if reach > 0 and (not nearest or reach < nearest) then
				nearest = reach
			end
		end
		return nearest or 0
	end
	-- How far the fingers can actually close before they are inside the gun. Closing a hand round a short
	-- grip would otherwise bring the fingertips back through the grip itself: the arithmetic says the
	-- fingers have room, because below the knuckles there is nothing, but the grip is behind them. So the
	-- close is swept and stopped where the gun is, which needs no rule about what kind of grip it is.
	-- Returns the part in the way, or nil when the finger has room. Naming what blocks a finger is the
	-- difference between "it will not close" and knowing why, which is three measured rounds of guessing
	-- saved the next time this moves.
	local function blockedBy(frame, length)
		local hx = FINGER_WIDTH / 2 - FINGER_PRESS
		local hy = FINGER_THICKNESS / 2 - FINGER_PRESS
		local hz = length / 2 - FINGER_PRESS
		for _, sx in ipairs({ -1, 0, 1 }) do
			for _, sz in ipairs({ -1, 0, 1 }) do
				for _, sy in ipairs({ -1, 1 }) do
					local hit = solid(frame * CF(sx * hx, sy * hy, sz * hz))
					if hit then
						return hit
					end
				end
			end
		end
		return nil
	end
	-- One finger at a time: where its knuckle sits, how deep the material is in that finger's own plane
	-- (which decides how far its tip turns in), and how far it can close before it is inside the gun.
	-- A finger with no room stays out -- on a pistol grip that is the top one, lying along the trigger
	-- guard, which is where a trigger finger belongs.
	-- A finger past the end of what the hand holds -- above the top of a grip, or below its butt -- finds
	-- nothing in front of it. Given the minimum line it would be planted INSIDE the grip and blocked at
	-- every angle, which is what put 62 of 100 hands flat; it takes its nearest neighbour's line instead,
	-- and then closes on air, which is what a finger hanging off the end of a grip does.
	local fronts = {}
	for index = 1, FINGER_COUNT do
		fronts[index] = frontAt(FINGER_X[index])
	end
	for index = 1, FINGER_COUNT do
		if fronts[index] <= 0 then
			for step = 1, FINGER_COUNT do
				local before, after = fronts[index - step], fronts[index + step]
				if before and before > 0 then
					fronts[index] = before
					break
				elseif after and after > 0 then
					fronts[index] = after
					break
				end
			end
		end
	end

	local fingers = {}
	local reach = FINGER_UPPER + FINGER_LOWER
	for index = 1, FINGER_COUNT do
		local across = FINGER_X[index]
		local knuckle = math.clamp(fronts[index] + FINGER_THICKNESS / 2 + FINGER_CLEAR, KNUCKLE, KNUCKLE_MAX)
		local at = keyFrame * CF(across, -HAND_SINK, -knuckle)
		local wrap, k = 0, 0
		while k <= GRIP_REACH do
			if solid(at * CF(0, -k, 0)) then
				wrap = k
			end
			k += GRIP_STEP
		end
		local turn = math.clamp((reach - wrap) / FINGER_LOWER, 0, 1)
		local cap, blocker = 0, nil
		for step = CURL_STEPS, 0, -1 do
			local candidate = step / CURL_STEPS
			local upper, lower = fingerAt(at, candidate * FINGER_LEAN[index], turn)
			local hit = blockedBy(upper, FINGER_UPPER) or blockedBy(lower, FINGER_LOWER)
			if not hit then
				cap = candidate
				blocker = nil
				break
			end
			blocker = blocker or hit.name
		end
		fingers[index] = { knuckle = knuckle, turn = turn, cap = cap, blocker = blocker }
	end
	return { fingers = fingers }
end

local Arms = {}
Arms.__index = Arms

-- Where a joint sits on an avatar part, read from its rig attachment, or the middle of the part's top
-- or bottom face if it has none.
local function joint(source, name, fallbackY)
	local attachment = source and source:FindFirstChild(name)
	if attachment and attachment:IsA("Attachment") then
		return attachment.Position
	end
	return V(0, fallbackY, 0)
end

-- A copy of an avatar part keeping only its shape and look (its mesh and surface): joints, welds and
-- attachments stay behind. Copies the avatar part's colour and material as they are.
local function copyPart(source)
	local part = source:Clone()
	for _, child in ipairs(part:GetChildren()) do
		if not (child:IsA("SpecialMesh") or child:IsA("SurfaceAppearance") or child:IsA("Decal") or child:IsA("Texture")) then
			child:Destroy()
		end
	end
	localOnly(part)
	-- The first-person camera sets this on the avatar's own parts, and a clone would carry it over.
	part.LocalTransparencyModifier = 0
	return part
end

local function block(name, size, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	localOnly(part)
	return part
end

-- A bone: a part, its unscaled size, and its two joints in its own unscaled space. `fit` scales it to
-- ARM_THICKNESS across and `length` between the joints (times `stretch` when a hand is out of reach).
local function bone(part, top, bottom, length)
	return { part = part, base = part.Size, rawTop = top, rawBottom = bottom, length = length, stretch = -1 }
end

local function fit(b, stretch)
	if math.abs(b.stretch - stretch) < 0.005 then
		return
	end
	b.stretch = stretch
	-- Solve the Y scale so the two JOINTS end up `length * stretch` apart, instead of scaling the part
	-- by the straight-line distance between them and hoping. An R15 body package puts the shoulder and
	-- elbow attachments OFF the part's centre line -- measured at 0.1700 studs on the stock rig -- so
	-- the joint-to-joint vector has X and Z in it, and those are scaled by the arm's THICKNESS, not by
	-- its length. Scaling Y by `wanted / span` therefore left the joints 0.1643 studs apart (0.9557
	-- instead of 1.1200) on every gun and every pose: Oliver's #11, "the arms joints look disconnected".
	-- On a rig whose attachments ARE on the centre line this is arithmetically identical to what it
	-- replaced, so nothing that looks right today can be made wrong by it.
	local raw = b.rawTop - b.rawBottom
	local across, through = ARM_THICKNESS / b.base.X, ARM_THICKNESS / b.base.Z
	local wanted = b.length * stretch
	local sideways = math.sqrt((raw.X * across) ^ 2 + (raw.Z * through) ^ 2)
	local along = wanted * wanted - sideways * sideways
	-- A bone shorter than its own sideways offset has no solution; keep the old scale rather than take
	-- the root of a negative number.
	along = along > 0 and math.sqrt(along) or (wanted * math.abs(raw.Y) / math.max(raw.Magnitude, 1e-3))
	local scale = V(across, along / math.max(math.abs(raw.Y), 1e-3), through)
	b.part.Size = b.base * scale
	b.top = b.rawTop * scale
	-- The joint line in the scaled part's own space. `place` lays THIS along the bone.
	b.joint = raw * scale
end

function Arms.new(parent, character)
	local self = setmetatable({ sides = {}, parts = {} }, Arms)
	local model = Instance.new("Model")
	model.Name = "Arms"
	local r15 = character ~= nil and character:FindFirstChild("RightUpperArm") ~= nil and character:FindFirstChild("LeftUpperArm") ~= nil
	local r6 = not r15 and character ~= nil and character:FindFirstChild("Right Arm") ~= nil and character:FindFirstChild("Left Arm") ~= nil

	for _, side in ipairs({ 1, -1 }) do
		local name = SIDE_NAME[side]
		local arm = {}
		if r15 then
			local upper = character:FindFirstChild(name .. "UpperArm")
			local lower = character:FindFirstChild(name .. "LowerArm")
			local hand = character:FindFirstChild(name .. "Hand")
			arm.upper = bone(copyPart(upper), joint(upper, name .. "ShoulderRigAttachment", upper.Size.Y / 2),
				joint(upper, name .. "ElbowRigAttachment", -upper.Size.Y / 2), UPPER)
			arm.lower = lower and bone(copyPart(lower), joint(lower, name .. "ElbowRigAttachment", lower.Size.Y / 2),
				joint(lower, name .. "WristRigAttachment", -lower.Size.Y / 2), FOREARM)
			if hand then
				local handPart = copyPart(hand)
				local scale = handScale(hand.Size)
				arm.handTop = joint(hand, name .. "WristRigAttachment", hand.Size.Y / 2) * scale
				handPart.Size = hand.Size * scale
				arm.hand = handPart
			end
		elseif r6 then
			local source = character:FindFirstChild(name .. " Arm")
			local half = source.Size.Y / 2
			arm.upper = bone(copyPart(source), V(0, half, 0), V(0, -half, 0), UPPER)
			arm.lower = bone(copyPart(source), V(0, half, 0), V(0, -half, 0), FOREARM)
		else
			arm.upper = bone(block(name .. "UpperArm", V(1, 1, 1), DEFAULT_SHIRT), V(0, 0.5, 0), V(0, -0.5, 0), UPPER)
			arm.lower = bone(block(name .. "LowerArm", V(1, 1, 1), DEFAULT_SKIN), V(0, 0.5, 0), V(0, -0.5, 0), FOREARM)
			arm.hand = block(name .. "Hand", V(HAND_THICKNESS, HAND_LENGTH, HAND_WIDTH), DEFAULT_SKIN)
			arm.handTop = V(0, HAND_LENGTH / 2, 0)
		end
		if not arm.lower then
			arm.lower = bone(block(name .. "LowerArm", V(1, 1, 1), arm.upper.part.Color), V(0, 0.5, 0), V(0, -0.5, 0), FOREARM)
		end
		fit(arm.upper, 1)
		fit(arm.lower, 1)
		-- Fingers, in the hand's own colour. Only where there is a hand to hinge them on: an R6 arm ends
		-- at the palm and has none.
		if arm.hand then
			arm.fingers = {}
			for i = 1, FINGER_COUNT do
				local finger = {
					block(name .. "Finger" .. i .. "Upper", V(FINGER_WIDTH, FINGER_THICKNESS, FINGER_UPPER), arm.hand.Color),
					block(name .. "Finger" .. i .. "Lower", V(FINGER_WIDTH, FINGER_THICKNESS, FINGER_LOWER), arm.hand.Color),
					across = FINGER_X[i],
					lean = FINGER_LEAN[i],
				}
				finger[1].Material = arm.hand.Material
				finger[2].Material = arm.hand.Material
				arm.fingers[i] = finger
			end
		end
		for _, part in ipairs({ arm.upper.part, arm.lower.part, arm.hand }) do
			part.Parent = model
			table.insert(self.parts, part)
		end
		for _, finger in ipairs(arm.fingers or {}) do
			for _, part in ipairs({ finger[1], finger[2] }) do
				part.Parent = model
				table.insert(self.parts, part)
			end
		end
		self.sides[side] = arm
	end

	-- Dressing: a Humanoid of their own, told not to scale, show a name or run a state machine, and
	-- the avatar's Shirt.
	local shirt = character and character:FindFirstChildOfClass("Shirt")
	if (r15 or r6) and shirt then
		local humanoid = Instance.new("Humanoid")
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.RigType = r15 and Enum.HumanoidRigType.R15 or Enum.HumanoidRigType.R6
		pcall(function()
			humanoid.AutomaticScalingEnabled = false
		end)
		pcall(function()
			humanoid.EvaluateStateMachine = false
		end)
		humanoid.Parent = model
		shirt:Clone().Parent = model
	end
	model.Parent = parent
	self.model = model
	return self
end

function Arms:SetHidden(hidden)
	for _, part in ipairs(self.parts) do
		part.LocalTransparencyModifier = hidden and 1 or 0
	end
end

-- Poses one arm. `hand` is the palm's world CFrame (-Z along the fingers, +Y out of the back of the
-- hand). `curl` (how far a hand closes) is kept in the signature for callers; a Roblox hand has no
-- fingers to close. Appends parts and CFrames for BulkMoveTo.
function Arms:pose(side, view, hand, curl, parts, cframes, held)
	local arm = self.sides[side]
	local shoulder = (view * CF(SHOULDER[side])).Position
	-- A gun's hand keypoint is the middle of the palm against what it holds, so the hand moves out along
	-- the back of the hand by half its own thickness, less HAND_SINK, which presses the palm into the grip
	-- instead of resting it against the surface.
	hand = hand * CF(0, HAND_THICKNESS / 2 - HAND_SINK, 0)
	local handFrame = hand * HAND_AXES[side]
	-- The wrist is where the hand's own wrist joint is; an R6 arm has no hand, and ends at the palm.
	local wrist = arm.hand and (handFrame * arm.handTop) or hand.Position
	local toWrist = wrist - shoulder
	local distance = toWrist.Magnitude
	local direction = distance > 1e-3 and toWrist.Unit or view.LookVector
	local reach = UPPER + FOREARM
	local elbow
	if distance >= reach * 0.999 then
		-- Out of reach: stretch both bones rather than leave a gap at the wrist.
		local stretch = distance / reach
		fit(arm.upper, stretch)
		fit(arm.lower, stretch)
		elbow = shoulder + direction * distance * UPPER / reach
	else
		fit(arm.upper, 1)
		fit(arm.lower, 1)
		local along = (UPPER * UPPER - FOREARM * FOREARM + distance * distance) / (2 * distance)
		local out = math.sqrt(math.max(0, UPPER * UPPER - along * along))
		local pole = (view * CF(POLE[side])).Position - shoulder
		local perpendicular = pole - direction * pole:Dot(direction)
		if perpendicular.Magnitude < 1e-3 then
			perpendicular = -view.UpVector
		end
		elbow = shoulder + direction * along + perpendicular.Unit * out
	end

	local function add(part, cframe)
		parts[#parts + 1] = part
		cframes[#cframes + 1] = cframe
	end
	-- A bone runs from its top joint at `from` down to its bottom joint at `to`, its front facing on
	-- along the view the way the avatar's arm faces forward.
	local function place(b, from, to)
		local up = from - to
		up = up.Magnitude > 1e-4 and up.Unit or view.UpVector
		local right = view.LookVector:Cross(up)
		right = right.Magnitude > 1e-3 and right.Unit or view.RightVector
		local rotation = CFrame.fromMatrix(Vector3.zero, right, up)
		-- Lay the bone's JOINT LINE along the bone, not the part's +Y. With an off-centre rig
		-- attachment those are different lines -- 8.7 to 10.3 degrees apart on the stock R15 upper arm --
		-- and aligning the wrong one is the other half of why the far joint hung away from the joint it
		-- was supposed to meet (#11). A centred rig has them parallel and this correction is the
		-- identity. Measured after: worst elbow gap across 62 guns and four poses, 0.327 -> 0.004 studs.
		local joint = b.joint
		if joint and joint.Magnitude > 1e-4 then
			local have = rotation:VectorToWorldSpace(joint).Unit
			local axis = have:Cross(up)
			if axis.Magnitude > 1e-4 then
				rotation = CFrame.fromAxisAngle(axis.Unit, math.acos(math.clamp(have:Dot(up), -1, 1))) * rotation
			end
		end
		add(b.part, rotation + (from - rotation:VectorToWorldSpace(b.top)))
	end
	place(arm.upper, shoulder, elbow)
	place(arm.lower, elbow, wrist)
	if arm.hand then
		add(arm.hand, handFrame)
	end
	if arm.fingers then
		-- The knuckles sit ahead of the palm, clear of the front face of whatever it holds; `curl` is how
		-- far this anchor closes the hand, and `cap` is how far the gun lets it -- both measured for this
		-- gun when it was built. On a thin rod the fingers close right round; on a fat handguard they lie
		-- down its front and stop.
		local palmFace = hand * CF(0, -HAND_THICKNESS / 2, 0)
		held = held or FIST
		for index, finger in ipairs(arm.fingers) do
			local shape = held[index] or FIST[index]
			if shape.cap < FINGER_MIN_CLOSE then
				-- This finger has no room to close here. It is NOT stood out straight: an open finger
				-- reaches half a hand past the palm, and on some guns that put it across the sight
				-- picture. It is parked inside the palm instead, so the hand falls back to the plain
				-- shape it had before fingers existed and no gun is made worse by them.
				local inside = palmFace * CF(finger.across, HAND_THICKNESS / 2, 0)
				add(finger[1], inside)
				add(finger[2], inside)
			else
				local close = math.min(curl, shape.cap) * finger.lean
				local upper, lower = fingerAt(palmFace * CF(finger.across, 0, -shape.knuckle), close, shape.turn)
				add(finger[1], upper)
				add(finger[2], lower)
			end
		end
	end
end

Viewmodel.Arms = Arms

--------------------------------------------------------------------------------
-- Templates
--------------------------------------------------------------------------------

-- Building a gun runs its z-fight pass, which is the slow part; a viewmodel clones a cached template.
-- The cache holds the last TEMPLATE_CACHE guns used, by id and skin: a long session with many skins would
-- otherwise keep a full model of every one of them. Evicting only costs the next draw of that gun its
-- build; the hotbar's own guns are drawn often enough to stay in.
local TEMPLATE_CACHE = 6
local templates = {}
local templateOrder = {}
local templateEvictions = 0

local function templateFor(def, color, material, skinned)
	local key = def.id .. (skinned and ("|" .. tostring(color) .. "|" .. tostring(material)) or "")
	local template = templates[key]
	if template then
		local at = table.find(templateOrder, key)
		if at then
			table.remove(templateOrder, at)
		end
	else
		template = GunModels.Build(def, color, material, { skinned = skinned })
		templates[key] = template
	end
	table.insert(templateOrder, key)
	while #templateOrder > TEMPLATE_CACHE do
		local oldest = table.remove(templateOrder, 1)
		local evicted = templates[oldest]
		templates[oldest] = nil
		if evicted then
			evicted:Destroy()
		end
		templateEvictions += 1
		if templateEvictions == 1 then
			print(string.format("[Viewmodel] gun template cache full at %d; dropping the least recently drawn (%s)",
				TEMPLATE_CACHE, oldest))
		end
	end
	return template
end

-- Builds a gun's template ahead of time (when it's picked up) so drawing it never hitches.
function Viewmodel.Preload(def, color, material, skinned)
	templateFor(def, color, material, skinned)
end

-- The optic a gun's model carries ("iron", "reddot", "holo" or "scope"), read from a template already
-- built for it (any skin), or nil before one has been. Never builds one.
function Viewmodel.OpticOf(def)
	local template = templates[def.id]
	if not template then
		local prefix = def.id .. "|"
		for key, candidate in pairs(templates) do
			if string.sub(key, 1, #prefix) == prefix then
				template = candidate
				break
			end
		end
	end
	return template and template:GetAttribute("Optic") or nil
end

--------------------------------------------------------------------------------
-- Hold classes
--------------------------------------------------------------------------------

-- Where the right hand sits at the hip, in view space, and how the gun is angled there.
local HOLD = {
	handgun = { hip = V(0.46, -0.66, -1.55), yaw = -4, pitch = 2, sprint = { V(-0.1, -0.5, 0.25), V(-45, 20, 12) } },
	rifle = { hip = V(0.5, -0.74, -0.98), yaw = -3, pitch = 1, sprint = { V(-0.18, -0.22, 0.12), V(-24, 38, 22) } },
	heavy = { hip = V(0.46, -0.86, -0.92), yaw = -4, pitch = 2, sprint = { V(-0.15, -0.18, 0.12), V(-18, 30, 16) } },
	shoulder = { hip = V(0.52, -0.58, -0.42), yaw = -2, pitch = 0, sprint = { V(-0.1, -0.25, 0.1), V(-18, 25, 12) } },
}
local HIP_SIGHT_CLEARANCE = 0.6

local CLASS = {
	pistol = "handgun", revolver = "handgun",
	lmg = "heavy", minigun = "heavy",
	launcher = "shoulder",
}

-- How hard each hold class kicks: back (studs), up (degrees), roll jitter (degrees).
local KICK = {
	handgun = { 0.1, 7, 3 },
	rifle = { 0.07, 3.2, 1.6 },
	heavy = { 0.05, 2.2, 1.2 },
	shoulder = { 0.16, 6, 2 },
}

-- Fingers per anchor: how far each hand closes on what it holds.
local CURL = {
	GripHand = 0.92, SupportHand = 0.78, MagHand = 0.7, ChargeHand = 0.55, BoltHand = 0.62,
	CoverHand = 0.25, Load = 0.5, Pocket = 0.62, Slap = 0.05,
}

-- What each gun has under each hand, for the fingers to close on: the same for every skin of a gun, and
-- walking the parts to find it costs more than it is worth to repeat, so it is measured once per gun.
local gripCache = {}

-- Which moving group a keypoint rides with, when the model doesn't say.
local KEY_GROUPS = {
	ChargeHand = { "charge", "slide", "bolt", "pump" },
	BoltHand = { "bolt" },
	CoverHand = { "cover" },
}

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

function Viewmodel.new(def, options)
	options = options or {}
	local self = setmetatable({}, Viewmodel)
	self.def = def
	self.onEvent = options.onEvent

	local template = templateFor(def, options.color, options.material, options.skinned)
	local model = template:Clone()
	model.Name = "BRR_Viewmodel"
	self.model = model

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("WeldConstraint") or descendant:IsA("Weld") then
			descendant:Destroy()
		end
	end
	local pivot = model:GetPivot()
	self.parts, self.offsets, self.groupOf, self.groupParts = {}, {}, {}, {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			localOnly(part)
			if part.Name == "AimPoint" then
				part.Transparency = 1
			end
			local group = part:GetAttribute("Anim")
			-- Parts hidden in the world model (the crossbow's resting string) are shown and hidden here by
			-- LocalTransparencyModifier instead.
			if group == "stringRest" then
				part.Transparency = 0
			end
			table.insert(self.parts, part)
			self.offsets[part] = pivot:ToObjectSpace(part.CFrame)
			if group then
				self.groupOf[part] = group
				self.groupParts[group] = self.groupParts[group] or {}
				table.insert(self.groupParts[group], part)
			end
		end
	end

	-- The contract.
	self.keys, self.pivots, self.travel, self.swing = {}, {}, {}, {}
	for name, value in pairs(model:GetAttributes()) do
		local key = string.match(name, "^KP_(.+)$")
		if key then
			self.keys[key] = value
		end
		local pivotGroup = string.match(name, "^Pivot_(.+)$")
		if pivotGroup then
			self.pivots[pivotGroup] = value
		end
		local travelGroup = string.match(name, "^Travel_(.+)$")
		if travelGroup then
			self.travel[travelGroup] = value
		end
		local swingGroup = string.match(name, "^Swing_(.+)$")
		if swingGroup then
			self.swing[swingGroup] = value
		end
	end
	self.parents = {}
	for group in pairs(self.groupParts) do
		self.parents[group] = model:GetAttribute("Parent_" .. group)
	end
	for group in pairs(self.pivots) do
		self.parents[group] = self.parents[group] or model:GetAttribute("Parent_" .. group)
	end

	self.action = model:GetAttribute("Action") or "ar"
	self.optic = model:GetAttribute("Optic") or "iron"
	self.eyeRelief = model:GetAttribute("EyeRelief") or 0.6
	self.flash = model:GetAttribute("Flash") or "rifle"
	self.casing = model:GetAttribute("Casing") or "rifle"
	self.keyGroups = {
		SupportHand = model:GetAttribute("SupportGroup"),
		Load = model:GetAttribute("LoadGroup"),
		GripHand = model:GetAttribute("GripGroup"),
	}
	for key, candidates in pairs(KEY_GROUPS) do
		for _, group in ipairs(candidates) do
			if not self.keyGroups[key] and (self.groupParts[group] or self.pivots[group]) then
				self.keyGroups[key] = group
			end
		end
	end
	self.scoped = self.optic == "scope"
	-- The RPG rides on the shoulder; the six-shot grenade launcher is shouldered like a rifle.
	local class = CLASS[def.style] or "rifle"
	if class == "shoulder" and self.action ~= "rocket" then
		class = "rifle"
	end
	self.hold = HOLD[class]
	self.kick = KICK[class]
	self.gripPoint = self.keys.GripHand and self.keys.GripHand.Position or V(0, -0.2, 0.2)
	-- At the hip the sight stays at least HIP_SIGHT_CLEARANCE ahead of the eye: a bullpup's action and
	-- its scope sit well behind the grip, and at the class's usual hip spot the scope filled a quarter
	-- of the screen from a hand's breadth away.
	local sightBehindGrip = (self.keys.Sight and self.keys.Sight.Position.Z or self.gripPoint.Z) - self.gripPoint.Z
	local hip = self.hold.hip
	self.hipPosition = V(hip.X, hip.Y, math.min(hip.Z, -HIP_SIGHT_CLEARANCE - sightBehindGrip))
	-- What the eye lines up on while aiming: the red dot, or else the foremost front sight or bead top.
	-- At full aim, the draw, sprint, bob and sway turn about this point instead of the grip, so it holds on
	-- the target while the rest of the gun moves around it.
	-- Only a dot or a top that is actually on the sight line, ahead of the eye, counts: a pistol's tritium
	-- dots are named SightDot too (the rear pair 7 mm out to the sides, the front one under the post's
	-- top), the cannon's bead stands on a blade named FrontSight, and a scoped rifle keeps iron sights
	-- well under its scope's line. Anything else would put the aimed pivot off the line.
	local sightKey = self.keys.Sight or CFrame.identity
	local mm = GunModels.StudsPerMillimetre
	local function onLine(point, tolerance)
		local p = sightKey:PointToObjectSpace(point)
		return p.Z < 0 and math.sqrt(p.X * p.X + p.Y * p.Y) <= tolerance * mm
	end
	local front, dot
	for part, offset in pairs(self.offsets) do
		if part.Name == "SightDot" then
			if onLine(offset.Position, 0.6) then
				dot = offset.Position
			end
		elseif part.Name == "FrontSight" or part.Name == "FrontBead" then
			local top = (offset * CF(0, part.Size.Y / 2, 0)).Position
			if onLine(top, 1.5) and (not front or top.Z < front.Z) then
				front = top
			end
		end
	end
	self.aimPivot = dot or front or (sightKey * CF(0, 0, -1)).Position
	-- The eye, in the gun's space, when fully aimed. The kick and the working of the action turn about it
	-- at full aim, so the front and rear sights stay in line with each other and with the eye.
	self.eyePoint = ((self.keys.Sight or CF(0, 0.2, 0.2)) * CF(0, 0, self.eyeRelief)).Position
	self.laserEmitter = model:FindFirstChild("LaserEmitter")

	-- What the fingers close on at each anchor this gun has. `false` is a measured answer too: the hand is
	-- on nothing there (a pocket, a hand slapped flat on a magazine) and the fingers close on themselves.
	local shapes = gripCache[def.id]
	if not shapes then
		shapes = {}
		for name in pairs(CURL) do
			if self.keys[name] then
				shapes[name] = gripShape(self.offsets, self.keys[name]) or false
			end
		end
		gripCache[def.id] = shapes
	end
	self.gripShapes = shapes

	-- The player's own arms (their avatar, when there is one), in a model of their own under the gun.
	self.arms = Arms.new(model, options.character)

	-- Animation state.
	self.now = 0
	self.values = {}
	self.aim, self.sprint = 0, 0
	self.bob, self.swayX, self.swayY, self.roll, self.airPitch = 0, 0, 0, 0, 0
	self.kickPos, self.kickVel = V(), V()
	self.kickRot, self.kickRotVel = V(), V()
	self.drumAngle, self.drumTarget = 0, 0
	self.spin, self.spinSpeed = 0, 0
	self.slideLocked = false
	self.equipAt = -math.huge
	self.clips = {}
	self.hands = {}
	self.props = {}
	self.cocked = true
	self.roundShown = true
	self.hidden = false

	-- Night sights (Oliver, 2026-09-22: "its hard to see your gun sights in night ops event"). The
	-- iron sights are dark anodised metal, invisible against a dark sky, so in the dark they turn into
	-- glowing tritium (green posts, the dot and reticle left red but lit), and a faint light on the
	-- gun keeps its shape readable. Driven from Update by how dark the Lighting is, so it covers Night
	-- Ops and anything else that turns the lights down, and switches back when it's light.
	self.nightParts = {}
	for part in pairs(self.offsets) do
		local name = part.Name
		if name == "FrontSight" or name == "FrontBead" or name == "RearSight" or name == "RearSightRing"
			or name == "SightDot" or name == "SightReticle" then
			table.insert(self.nightParts, { part = part, color = part.Color, material = part.Material })
		end
	end
	local anchorPart = (self.keys.Sight and model:FindFirstChild("Sight", true)) or model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart", true)
	if anchorPart then
		local glow = Instance.new("PointLight")
		glow.Name = "NightSightGlow"
		glow.Color = Color3.fromRGB(170, 200, 255)
		glow.Brightness = 0.7
		glow.Range = 3
		glow.Shadows = false
		glow.Enabled = false
		glow.Parent = anchorPart
		self.nightGlow = glow
	end
	self.night = false
	self.nightCheckAt = 0

	self.model.Parent = nil
	return self
end

local NIGHT_TRITIUM = Color3.fromRGB(90, 255, 130)
local Lighting = game:GetService("Lighting")

function Viewmodel:updateNightSights()
	local clock = Lighting.ClockTime
	local dark = clock < 5.5 or clock > 18.5 or Lighting.Brightness < 0.6
	if dark == self.night then
		return
	end
	self.night = dark
	for _, entry in ipairs(self.nightParts) do
		local part = entry.part
		if dark then
			part.Material = Enum.Material.Neon
			if part.Name ~= "SightDot" and part.Name ~= "SightReticle" then
				part.Color = NIGHT_TRITIUM
			end
		else
			part.Material = entry.material
			part.Color = entry.color
		end
	end
	if self.nightGlow then
		self.nightGlow.Enabled = dark
	end
end

function Viewmodel:Destroy()
	for _, prop in pairs(self.props) do
		prop.model:Destroy()
	end
	self.model:Destroy()
end

local function emit(self, ...)
	if self.onEvent then
		self.onEvent(...)
	end
end

--------------------------------------------------------------------------------
-- Clips
--
-- A clip is a table of keyframe tracks laid over normalised time 0..1 and played over `duration`
-- seconds. Tracks:
--   gun     { t, position (studs), rotation (degrees) } around the grip
--   left    { t, anchor, offset (studs, gun space) }   and   right, for the right hand
--   values  { name = { { t, value }, ... } }          groups (slide, bolt, pump, hinge...) and holds
--   events  { t, kind, ... }                           sounds, drops, ejected cases, visibility
-- Values ease between keyframes; a pair of keys close together is a snap.
--------------------------------------------------------------------------------

local function key(t, a, b, c)
	return { t, a, b, c }
end

-- The magazine change every box-magazine gun shares, tuned by action. `tactical` keeps the old magazine
-- in hand to stow it; an empty gun drops it and works the charging handle after.
local function magazineClip(self, empty, style)
	local roll = style == "pistol" and -18 or 22
	local gun = {
		key(0, V(), V()),
		key(0.1, V(-0.04, 0.05, 0.03), V(10, style == "pistol" and 16 or -10, roll)),
		key(0.6, V(-0.04, 0.04, 0.03), V(12, style == "pistol" and 18 or -8, roll)),
		key(0.68, V(-0.03, 0.02, 0.02), V(4, style == "pistol" and 12 or -6, roll * 0.8)),
		key(0.74, V(-0.03, 0.05, 0.02), V(8, style == "pistol" and 12 or -6, roll * 0.8)),
	}
	local left = {
		key(0, "SupportHand"),
		key(0.12, "MagHand"),
		key(0.2, "MagHand", V(0, -0.34, 0.03)),
		key(0.32, "Pocket"),
		key(0.46, "Pocket"),
		key(0.56, "MagHand", V(0, -0.32, 0.03)),
		key(0.64, "MagHand"),
		key(0.68, "MagHand", V(0, 0.03, 0)),
		key(0.72, "MagHand", V(0, -0.02, 0)),
	}
	local values = {
		magHold = { key(0, 0), key(0.14, 0), key(0.16, 1), key(0.64, 1), key(0.66, 0) },
		magVisible = { key(0, 1) },
	}
	local events = {
		key(0.16, "sound", "MagOut"),
		key(0.67, "sound", "MagIn"),
	}
	if style == "pistol" then
		-- The thumb drops the magazine free; the left hand fetches the new one.
		left[2] = key(0.12, "SupportHand", V(-0.12, -0.2, 0.1))
		left[3] = key(0.2, "Pocket")
		values.magHold = { key(0, 0), key(0.4, 0), key(0.42, 1), key(0.64, 1), key(0.66, 0) }
		values.magSlide = { key(0, 0), key(0.1, 0), key(0.18, 0.4), key(0.2, 0.4), key(0.21, 0) }
		values.magVisible = { key(0, 1), key(0.2, 1), key(0.21, 0), key(0.4, 0), key(0.41, 1) }
		table.insert(events, key(0.2, "drop", "mag"))
		events[1] = key(0.1, "sound", "MagOut")
	elseif empty then
		values.magHold = { key(0, 0), key(0.14, 0), key(0.16, 1), key(0.24, 1), key(0.25, 0), key(0.42, 0), key(0.44, 1), key(0.64, 1), key(0.66, 0) }
		values.magVisible = { key(0, 1), key(0.25, 1), key(0.26, 0), key(0.42, 0), key(0.43, 1) }
		table.insert(events, key(0.25, "drop", "mag"))
	end

	local finish = 0.82
	if empty then
		if style == "pistol" then
			-- Overhand: the left hand grips the slide and snaps it forward off the stop.
			table.insert(left, key(0.8, "ChargeHand"))
			table.insert(left, key(0.86, "ChargeHand"))
			values.slide = { key(0, 1), key(0.84, 1), key(0.86, 1.06), key(0.89, 0) }
			table.insert(events, key(0.88, "sound", "SlideRelease"))
		else
			local group = self.groupParts.charge and "charge" or (self.groupParts.bolt and "bolt" or nil)
			table.insert(left, key(0.8, "ChargeHand"))
			table.insert(left, key(0.88, "ChargeHand"))
			if group then
				values[group] = { key(0, 0), key(0.8, 0), key(0.87, 1), key(0.89, 0) }
				if group == "charge" and self.groupParts.bolt then
					values.bolt = { key(0, 0), key(0.8, 0), key(0.87, 1), key(0.89, 0) }
				end
			end
			table.insert(events, key(0.85, "sound", "ChargeBack"))
			table.insert(events, key(0.89, "sound", "ChargeRelease"))
			table.insert(gun, key(0.84, V(-0.05, 0.02, 0.02), V(4, -16, 12)))
		end
		finish = 0.95
	end
	table.insert(left, key(finish, "SupportHand"))
	table.insert(gun, key(finish, V(), V()))
	table.insert(gun, key(1, V(), V()))
	table.insert(left, key(1, "SupportHand"))
	return { gun = gun, left = left, values = values, events = events }
end

-- Feeding rounds one at a time through a loading port: a pump gun, a lever gun, a grenade cylinder.
-- `rounds` is how many the clip shows going in (capped, so a long reload still reads).
local function feedClip(self, rounds, roll, prop, finishWith)
	local gun = { key(0, V(), V()), key(0.08, V(-0.05, 0.04, 0.02), V(6, -12, roll)) }
	local left = { key(0, "SupportHand"), key(0.08, "Pocket") }
	local values = { propHold = { key(0, 0) } }
	local events = {}
	local span = 0.68 / math.max(1, rounds)
	for index = 0, rounds - 1 do
		local s = 0.1 + index * span
		table.insert(left, key(s, "Pocket"))
		table.insert(left, key(s + span * 0.45, "Load", V(0, -0.12, 0.1)))
		table.insert(left, key(s + span * 0.72, "Load"))
		table.insert(values.propHold, key(s, 0))
		table.insert(values.propHold, key(s + 0.01, 1))
		table.insert(values.propHold, key(s + span * 0.74, 1))
		table.insert(values.propHold, key(s + span * 0.76, 0))
		table.insert(events, key(s + span * 0.74, "sound", "ShellIn"))
	end
	table.insert(gun, key(0.8, V(-0.05, 0.04, 0.02), V(6, -12, roll)))
	table.insert(left, key(0.84, "SupportHand"))
	table.insert(gun, key(0.86, V(), V()))
	local clip = { gun = gun, left = left, values = values, events = events, prop = prop }
	if finishWith then
		finishWith(clip)
	end
	table.insert(gun, key(1, V(), V()))
	table.insert(left, key(1, "SupportHand"))
	return clip
end

local function rackPump(clip, from)
	clip.values.pump = { key(0, 0), key(from, 0), key(from + 0.05, 1), key(from + 0.1, 0) }
	table.insert(clip.events, key(from + 0.05, "sound", "PumpBack"))
	table.insert(clip.events, key(from + 0.05, "eject"))
	table.insert(clip.events, key(from + 0.1, "sound", "PumpForward"))
end

local function reloadClip(self, empty, missing)
	local action = self.action
	if action == "pistol" then
		return magazineClip(self, empty, "pistol")
	elseif action == "revolver" then
		return {
			gun = {
				key(0, V(), V()), key(0.08, V(-0.1, 0.05, 0), V(-5, 20, -58)),
				key(0.26, V(-0.08, 0.1, 0.05), V(52, 10, -30)), key(0.4, V(-0.1, 0.02, 0.02), V(-38, 10, -30)),
				key(0.74, V(-0.1, 0.02, 0.02), V(-20, 10, -45)), key(0.84, V(), V(4, 0, -6)), key(1, V(), V()),
			},
			left = {
				key(0, "SupportHand"), key(0.1, "MagHand"), key(0.3, "MagHand", V(0.02, 0.05, 0)), key(0.4, "Pocket"),
				key(0.5, "Pocket"), key(0.62, "Load", V(0, 0, 0.12)), key(0.67, "Load"), key(0.72, "MagHand"), key(0.9, "SupportHand"),
				key(1, "SupportHand"),
			},
			values = {
				crane = { key(0, 0), key(0.12, 0), key(0.2, 1), key(0.74, 1), key(0.8, 0) },
				propHold = { key(0, 0), key(0.46, 0), key(0.47, 1), key(0.67, 1), key(0.68, 0) },
			},
			events = {
				key(0.16, "sound", "CylinderOpen"), key(0.3, "casings", 6), key(0.66, "sound", "ShellIn"), key(0.8, "sound", "CylinderClose"),
			},
			prop = "speedloader",
		}
	elseif action == "pump" then
		return feedClip(self, math.clamp(missing, 1, 4), 30, "shell", function(clip)
			if empty then
				rackPump(clip, 0.86)
			end
		end)
	elseif action == "lever" then
		return feedClip(self, math.clamp(missing, 1, 4), -34, "shellBig", function(clip)
			if empty then
				clip.values.lever = { key(0, 0), key(0.86, 0), key(0.91, 1), key(0.97, 0) }
				table.insert(clip.events, key(0.9, "sound", "LeverOpen"))
				table.insert(clip.events, key(0.96, "sound", "LeverClose"))
			end
		end)
	elseif action == "break" then
		return {
			gun = { key(0, V(), V()), key(0.1, V(0, 0.02, 0.04), V(-24, 0, 12)), key(0.7, V(0, 0.02, 0.04), V(-20, 0, 10)), key(0.78, V(), V(6, 0, 0)), key(1, V(), V()) },
			left = {
				key(0, "SupportHand"), key(0.2, "SupportHand", V(0, -0.05, 0)), key(0.26, "Pocket"), key(0.4, "Pocket"),
				key(0.52, "Load", V(0, 0.06, 0.12)), key(0.58, "Load"), key(0.66, "SupportHand"), key(1, "SupportHand"),
			},
			values = {
				hinge = { key(0, 0), key(0.1, 0), key(0.2, 1), key(0.72, 1), key(0.78, 0) },
				propHold = { key(0, 0), key(0.36, 0), key(0.37, 1), key(0.58, 1), key(0.59, 0) },
			},
			events = { key(0.15, "sound", "BreakOpen"), key(0.22, "casings", 2), key(0.58, "sound", "ShellIn"), key(0.78, "sound", "BreakClose") },
			prop = "shells",
		}
	elseif action == "bolt" then
		local clip = magazineClip(self, false, "rifle")
		clip.right = {
			key(0, "GripHand"), key(0.06, "BoltHand"), key(0.2, "BoltHand"), key(0.28, "GripHand"),
			key(0.74, "GripHand"), key(0.78, "BoltHand"), key(0.9, "BoltHand"), key(0.96, "GripHand"), key(1, "GripHand"),
		}
		clip.values.bolt = { key(0, 0), key(0.08, 1), key(0.14, 2), key(0.8, 2), key(0.85, 1), key(0.9, 0) }
		table.insert(clip.events, key(0.12, "sound", "BoltBack"))
		table.insert(clip.events, key(0.86, "sound", "BoltForward"))
		return clip
	elseif action == "belt" then
		local clip = {
			gun = { key(0, V(), V()), key(0.1, V(-0.03, 0.04, 0.02), V(6, -10, 18)), key(0.88, V(-0.03, 0.04, 0.02), V(6, -10, 18)), key(0.96, V(), V()), key(1, V(), V()) },
			left = {
				key(0, "SupportHand"), key(0.1, "CoverHand"), key(0.2, "CoverHand"), key(0.26, "MagHand"), key(0.34, "MagHand", V(-0.08, -0.36, 0.04)),
				key(0.42, "Pocket"), key(0.52, "Pocket"), key(0.62, "MagHand", V(-0.08, -0.32, 0.02)), key(0.7, "MagHand"),
				key(0.76, "CoverHand", V(0, 0.02, -0.12)), key(0.84, "CoverHand"), key(0.94, "SupportHand"), key(1, "SupportHand"),
			},
			values = {
				cover = { key(0, 0), key(0.12, 0), key(0.2, 1), key(0.8, 1), key(0.86, 0) },
				magHold = { key(0, 0), key(0.27, 0), key(0.28, 1), key(0.35, 1), key(0.36, 0), key(0.5, 0), key(0.51, 1), key(0.7, 1), key(0.71, 0) },
				magVisible = { key(0, 1), key(0.36, 1), key(0.37, 0), key(0.5, 0), key(0.51, 1) },
			},
			events = {
				key(0.16, "sound", "CoverOpen"), key(0.3, "sound", "MagOut"), key(0.36, "drop", "mag"), key(0.7, "sound", "MagIn"), key(0.86, "sound", "CoverClose"),
			},
		}
		if empty then
			clip.values.charge = { key(0, 0), key(0.88, 0), key(0.93, 1), key(0.95, 0) }
			table.insert(clip.events, key(0.93, "sound", "ChargeBack"))
		end
		return clip
	elseif action == "rotary" then
		return {
			gun = { key(0, V(), V()), key(0.12, V(-0.02, 0.03, 0.02), V(4, -6, 12)), key(0.85, V(-0.02, 0.03, 0.02), V(4, -6, 12)), key(1, V(), V()) },
			left = {
				key(0, "SupportHand"), key(0.15, "MagHand"), key(0.28, "MagHand", V(0, -0.34, 0.08)), key(0.4, "Pocket"), key(0.5, "Pocket"),
				key(0.68, "MagHand", V(0, -0.3, 0.08)), key(0.78, "MagHand"), key(0.95, "SupportHand"), key(1, "SupportHand"),
			},
			values = {
				magHold = { key(0, 0), key(0.17, 0), key(0.18, 1), key(0.29, 1), key(0.3, 0), key(0.46, 0), key(0.47, 1), key(0.78, 1), key(0.8, 0) },
				magVisible = { key(0, 1), key(0.3, 1), key(0.31, 0), key(0.46, 0), key(0.47, 1) },
			},
			events = { key(0.2, "sound", "MagOut"), key(0.3, "drop", "mag"), key(0.8, "sound", "MagIn") },
		}
	elseif action == "rocket" then
		return {
			gun = { key(0, V(), V()), key(0.12, V(0.02, 0.02, 0.06), V(-8, 22, 10)), key(0.78, V(0.02, 0.02, 0.06), V(-8, 22, 10)), key(1, V(), V()) },
			left = {
				key(0, "SupportHand"), key(0.14, "Pocket"), key(0.3, "Pocket"), key(0.5, "Load", V(0, 0, -0.45)), key(0.72, "Load"), key(0.9, "SupportHand"), key(1, "SupportHand"),
			},
			values = {
				roundHold = { key(0, 0), key(0.22, 0), key(0.23, 1), key(0.72, 1), key(0.74, 0) },
				roundVisible = { key(0, 0), key(0.22, 0), key(0.23, 1) },
			},
			events = { key(0.72, "sound", "RocketSeat") },
		}
	elseif action == "grenade" then
		local clip = feedClip(self, 3, -28, "grenade", nil)
		clip.values.crane = { key(0, 0), key(0.06, 0), key(0.1, 1), key(0.78, 1), key(0.84, 0) }
		clip.values.roundsVisible = { key(0, 1), key(0.1, 1), key(0.11, 0), key(0.76, 0), key(0.77, 1) }
		clip.values.drum = { key(0, 0), key(0.84, 0), key(0.94, 1) }
		table.insert(clip.events, key(0.08, "sound", "CylinderOpen"))
		table.insert(clip.events, key(0.12, "casings", 6))
		table.insert(clip.events, key(0.84, "sound", "CylinderClose"))
		return clip
	elseif action == "crossbow" then
		return {
			gun = { key(0, V(), V()), key(0.12, V(0, 0.02, 0.1), V(-30, 0, 8)), key(0.4, V(0, 0.02, 0.06), V(-24, 0, 8)), key(0.5, V(), V(-6, 6, 10)), key(0.9, V(), V(-6, 6, 10)), key(1, V(), V()) },
			left = {
				key(0, "SupportHand"), key(0.14, "ChargeHand", V(0, 0.02, -1.2)), key(0.34, "ChargeHand"), key(0.46, "Pocket"), key(0.56, "Pocket"),
				key(0.72, "Load", V(0, 0.02, -0.3)), key(0.84, "Load"), key(0.95, "SupportHand"), key(1, "SupportHand"),
			},
			values = {
				cocked = { key(0, 0), key(0.35, 0), key(0.36, 1) },
				roundHold = { key(0, 0), key(0.52, 0), key(0.53, 1), key(0.84, 1), key(0.85, 0) },
				roundVisible = { key(0, 0), key(0.52, 0), key(0.53, 1) },
			},
			events = { key(0.36, "sound", "StringCock"), key(0.84, "sound", "BoltSeat") },
		}
	elseif action == "blaster" then
		local clip = magazineClip(self, false, "rifle")
		for index, entry in ipairs(clip.left) do
			if entry[1] >= 0.72 then
				clip.left[index] = key(entry[1], "SupportHand")
			end
		end
		clip.values.pump = { key(0, 0), key(0.74, 0), key(0.8, 1), key(0.86, 0), key(0.92, 1), key(0.98, 0) }
		table.insert(clip.events, key(0.8, "sound", "PumpBack"))
		table.insert(clip.events, key(0.92, "sound", "PumpBack"))
		return clip
	elseif action == "energy" then
		local clip = magazineClip(self, false, "rifle")
		table.insert(clip.left, key(0.8, "ChargeHand"))
		clip.values.charge = { key(0, 0), key(0.8, 0), key(0.86, 1), key(0.9, 0) }
		clip.values.glow = { key(0, 1), key(0.12, 0.1), key(0.86, 0.1), key(0.98, 1.6), key(1, 1) }
		table.insert(clip.events, key(0.87, "sound", "EnergyCharge"))
		table.sort(clip.left, function(a, b)
			return a[1] < b[1]
		end)
		return clip
	end
	-- ar, ak, smg, semi: the box magazine swap.
	return magazineClip(self, empty, action)
end

-- Racking on the draw, by mechanism.
local function rackClip(self)
	local action = self.action
	if action == "pistol" then
		return {
			left = { key(0, "SupportHand"), key(0.25, "ChargeHand"), key(0.7, "ChargeHand"), key(1, "SupportHand") },
			values = { slide = { key(0, 0), key(0.35, 0), key(0.5, 1), key(0.58, 0) } },
			events = { key(0.5, "sound", "ChargeBack"), key(0.58, "sound", "SlideRelease") },
			gun = { key(0, V(), V()), key(0.3, V(0, 0, 0.02), V(6, 10, -10)), key(0.7, V(), V(2, 4, -4)), key(1, V(), V()) },
		}
	elseif action == "pump" or action == "blaster" then
		return { values = { pump = { key(0, 0), key(0.2, 0), key(0.45, 1), key(0.7, 0) } }, events = { key(0.45, "sound", "PumpBack"), key(0.7, "sound", "PumpForward") } }
	elseif action == "bolt" then
		return {
			right = { key(0, "GripHand"), key(0.15, "BoltHand"), key(0.85, "BoltHand"), key(1, "GripHand") },
			values = { bolt = { key(0, 0), key(0.2, 0), key(0.35, 1), key(0.5, 2), key(0.65, 1), key(0.8, 0) } },
			events = { key(0.45, "sound", "BoltBack"), key(0.7, "sound", "BoltForward") },
		}
	elseif action == "lever" then
		return { values = { lever = { key(0, 0), key(0.2, 0), key(0.5, 1), key(0.85, 0) } }, events = { key(0.45, "sound", "LeverOpen"), key(0.85, "sound", "LeverClose") } }
	elseif action == "revolver" then
		return { values = { hammer = { key(0, 0), key(0.4, 0), key(0.7, 1), key(0.8, 0) } }, events = { key(0.7, "sound", "HammerCock") } }
	elseif action == "break" then
		return { values = { hinge = { key(0, 0), key(0.2, 0), key(0.45, 0.6), key(0.7, 0) } }, events = { key(0.25, "sound", "BreakOpen"), key(0.7, "sound", "BreakClose") } }
	elseif action == "rocket" or action == "grenade" or action == "crossbow" or action == "rotary" then
		return nil
	end
	local group = self.groupParts.charge and "charge" or (self.groupParts.bolt and "bolt" or nil)
	if not group then
		return nil
	end
	local values = { [group] = { key(0, 0), key(0.35, 0), key(0.55, 1), key(0.62, 0) } }
	if group == "charge" and self.groupParts.bolt then
		values.bolt = { key(0, 0), key(0.35, 0), key(0.55, 1), key(0.62, 0) }
	end
	return {
		left = { key(0, "SupportHand"), key(0.25, "ChargeHand"), key(0.75, "ChargeHand"), key(1, "SupportHand") },
		values = values,
		events = { key(0.52, "sound", "ChargeBack"), key(0.62, "sound", "ChargeRelease") },
		gun = { key(0, V(), V()), key(0.3, V(-0.03, 0.02, 0.02), V(4, -14, 12)), key(0.75, V(-0.03, 0.02, 0.02), V(4, -14, 12)), key(1, V(), V()) },
	}
end

-- What the mechanism does between shots.
local function fireClip(self, roundsLeft)
	local action = self.action
	local interval = 1 / math.max(self.def.fireRate or 1, 0.1)
	if action == "pump" then
		return {
			duration = math.min(0.55, interval * 0.9),
			values = { pump = { key(0, 0), key(0.2, 0), key(0.5, 1), key(0.85, 0) } },
			events = { key(0.5, "sound", "PumpBack"), key(0.52, "eject"), key(0.85, "sound", "PumpForward") },
			gun = { key(0, V(), V()), key(0.45, V(0, -0.02, 0.03), V(-3, 2, 4)), key(1, V(), V()) },
		}
	elseif action == "bolt" then
		return {
			duration = math.min(0.75, interval * 0.9),
			right = { key(0, "GripHand"), key(0.14, "BoltHand"), key(0.82, "BoltHand"), key(1, "GripHand") },
			values = { bolt = { key(0, 0), key(0.18, 0), key(0.3, 1), key(0.46, 2), key(0.62, 1), key(0.76, 0) } },
			events = { key(0.44, "sound", "BoltBack"), key(0.46, "eject"), key(0.66, "sound", "BoltForward") },
			gun = { key(0, V(), V()), key(0.4, V(0.02, 0, 0.02), V(-2, 4, 8)), key(1, V(), V()) },
		}
	elseif action == "lever" then
		return {
			duration = math.min(0.5, interval * 0.9),
			values = { lever = { key(0, 0), key(0.12, 0), key(0.45, 1), key(0.8, 0) }, hammer = { key(0, 1), key(0.45, 1), key(0.5, 0) } },
			events = { key(0.4, "sound", "LeverOpen"), key(0.46, "eject"), key(0.8, "sound", "LeverClose") },
			gun = { key(0, V(), V()), key(0.45, V(0, 0.02, 0), V(-6, 0, 0)), key(1, V(), V()) },
		}
	elseif action == "pistol" then
		local locked = roundsLeft <= 0
		return {
			duration = 0.09,
			values = { slide = locked and { key(0, 0), key(0.35, 1), key(1, 1) } or { key(0, 0), key(0.35, 1), key(1, 0) } },
			events = { key(0.3, "eject") },
		}
	elseif action == "revolver" then
		self.drumTarget += math.pi / 3
		return { duration = 0.12, values = { hammer = { key(0, 1), key(0.25, 0), key(1, 0) } } }
	elseif action == "grenade" then
		self.drumTarget += math.pi / 3
		return { duration = 0.25, values = {} }
	elseif action == "ar" or action == "ak" or action == "smg" or action == "semi" or action == "belt" then
		return { duration = math.min(0.07, interval * 0.8), values = { bolt = { key(0, 0), key(0.4, 1), key(1, 0) } }, events = { key(0.35, "eject") } }
	end
	return nil
end

-- Plays a clip over `duration` seconds from now, replacing any clip of the same kind.
function Viewmodel:play(kind, clip, duration)
	if not clip then
		self.clips[kind] = nil
		return
	end
	clip.kind = kind
	clip.start = self.now
	clip.duration = math.max(duration or clip.duration or 0.3, 0.05)
	clip.fired = {}
	self.clips[kind] = clip
end

local function sample(track, t)
	if not track or #track == 0 then
		return nil
	end
	if t <= track[1][1] then
		return track[1], track[1], 0
	end
	for index = 2, #track do
		local b = track[index]
		if t <= b[1] then
			local a = track[index - 1]
			local span = b[1] - a[1]
			return a, b, span > 0 and smooth((t - a[1]) / span) or 1
		end
	end
	local last = track[#track]
	return last, last, 0
end

local function sampleValue(track, t)
	local a, b, s = sample(track, t)
	if not a then
		return nil
	end
	return a[2] + (b[2] - a[2]) * s
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

function Viewmodel:Equip(rack)
	self.equipAt = self.now
	self.clips = {}
	self.slideLocked = false
	if rack then
		local clip = rackClip(self)
		if clip then
			clip.delay = 0.3
			self.pendingRack = clip
		end
	end
	emit(self, "sound", "Equip")
end

function Viewmodel:Fire(roundsLeft)
	local kick = self.kick
	-- Aimed, the gun still drives back but turns much less: the sight picture holds, and the camera's own
	-- recoil carries the climb.
	local pushScale = 1 - self.aim * 0.45
	local turnScale = 1 - self.aim * 0.7
	self.kickVel += V((math.random() - 0.5) * 0.01, 0.004, kick[1] * 10) * pushScale
	self.kickRotVel += V(kick[2] * 14, (math.random() - 0.5) * kick[3] * 10, (math.random() - 0.5) * kick[3] * 18) * turnScale
	self.shotAt = self.now
	self.clips.inspect = nil
	self.pendingRack = nil
	self.clips.rack = nil
	if self.action == "rotary" then
		self.spinSpeed = math.max(self.spinSpeed, 26)
	end
	if self.action == "crossbow" then
		self.cocked = false
	end
	if (self.action == "rocket" or self.action == "crossbow") and roundsLeft <= 0 then
		self.roundShown = false
	end
	local clip = fireClip(self, roundsLeft)
	if clip then
		self:play("fire", clip)
		if self.action == "pistol" and roundsLeft <= 0 then
			self.slideLocked = true
		end
	end
	-- Guns that throw their empties on the shot itself; pump, bolt and lever guns throw them as they're
	-- worked, and a double barrel keeps its shells until it's broken open.
	local throwsOnShot = self.action ~= "pump" and self.action ~= "bolt" and self.action ~= "lever" and self.action ~= "break"
	if throwsOnShot and not (clip and clip.events) then
		self:eject()
	end
	return self:muzzleCFrame()
end

function Viewmodel:StartReload(seconds, roundsLeft, magSize)
	self.clips.inspect = nil
	self.pendingRack = nil
	self.clips.rack = nil
	local empty = roundsLeft <= 0
	local clip = reloadClip(self, empty, (magSize or 1) - roundsLeft)
	self:play("reload", clip, seconds)
	self.reloadEmpty = empty
end

function Viewmodel:StopReload()
	local clip = self.clips.reload
	if clip then
		self.clips.reload = nil
		self.slideLocked = false
		self.cocked = true
		self.roundShown = true
		self:clearProps()
	end
end

function Viewmodel:Inspect()
	if self.clips.reload then
		return
	end
	self:play("inspect", {
		gun = {
			key(0, V(), V()), key(0.18, V(-0.25, 0.18, 0.1), V(10, 55, -25)), key(0.45, V(-0.25, 0.18, 0.1), V(10, 65, -30)),
			key(0.6, V(-0.2, 0.14, 0.05), V(-6, -40, 35)), key(0.85, V(-0.2, 0.14, 0.05), V(-6, -48, 38)), key(1, V(), V()),
		},
	}, 2.6)
end

function Viewmodel:SetHidden(hidden)
	if self.hidden == hidden then
		return
	end
	self.hidden = hidden
	-- Everything: the gun, both arms and whatever the hand is holding. Behind a full-screen scope not a
	-- knuckle may show.
	for _, part in ipairs(self.parts) do
		veil(part, hidden)
	end
	self.arms:SetHidden(hidden)
	for _, prop in pairs(self.props) do
		for _, part in ipairs(prop.parts) do
			part.LocalTransparencyModifier = hidden and 1 or 0
		end
	end
	self.visibilityDirty = true
end

--------------------------------------------------------------------------------
-- Props: what the left hand brings from the pocket
--------------------------------------------------------------------------------

local PROP_FINISH = GunModels.Finishes

local function buildProp(kind)
	local model = Instance.new("Model")
	model.Name = "BRR_Prop"
	local function piece(shape, size, cframe, look)
		local part = Instance.new("Part")
		part.Shape = shape or Enum.PartType.Block
		part.Size = size
		part.CFrame = cframe
		part.Color = look.color
		part.Material = look.material
		part.Reflectance = look.reflectance
		localOnly(part)
		part.Parent = model
		return part
	end
	local mm = GunModels.StudsPerMillimetre
	local along = CFrame.Angles(0, math.pi / 2, 0)
	if kind == "shell" or kind == "shellBig" or kind == "shells" then
		local count = kind == "shells" and 2 or 1
		local big = kind == "shellBig" and 1.25 or 1
		for index = 1, count do
			local x = (index - (count + 1) / 2) * 22 * mm
			piece(Enum.PartType.Cylinder, V(60 * mm * big, 20 * mm * big, 20 * mm * big), CF(x, 0, -30 * mm) * along, kind == "shellBig" and PROP_FINISH.brass or PROP_FINISH.shell)
			piece(Enum.PartType.Cylinder, V(12 * mm * big, 21.4 * mm * big, 21.4 * mm * big), CF(x, 0, 6 * mm) * along, PROP_FINISH.brass)
		end
	elseif kind == "speedloader" then
		piece(Enum.PartType.Cylinder, V(14 * mm, 30 * mm, 30 * mm), CF(0, 0, 10 * mm) * along, PROP_FINISH.nitride)
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			piece(Enum.PartType.Cylinder, V(38 * mm, 9.6 * mm, 9.6 * mm), CF(math.cos(angle) * 13.5 * mm, math.sin(angle) * 13.5 * mm, -12 * mm) * along, PROP_FINISH.brass)
		end
	elseif kind == "grenade" then
		piece(Enum.PartType.Cylinder, V(50 * mm, 42 * mm, 42 * mm), CF(0, 0, 10 * mm) * along, PROP_FINISH.brass)
		piece(Enum.PartType.Ball, V(40 * mm, 40 * mm, 40 * mm), CF(0, 0, -20 * mm), PROP_FINISH.warhead)
	end
	return model
end

function Viewmodel:prop(kind)
	local prop = self.props[kind]
	if not prop then
		local model = buildProp(kind)
		local parts, offsets = {}, {}
		local pivot = model:GetPivot()
		for _, part in ipairs(model:GetChildren()) do
			table.insert(parts, part)
			offsets[part] = pivot:ToObjectSpace(part.CFrame)
		end
		prop = { model = model, parts = parts, offsets = offsets, shown = false }
		self.props[kind] = prop
	end
	return prop
end

function Viewmodel:clearProps()
	for _, prop in pairs(self.props) do
		prop.model.Parent = nil
		prop.shown = false
	end
end

--------------------------------------------------------------------------------
-- Per frame
--------------------------------------------------------------------------------

-- A group's transform in gun space at `value`.
function Viewmodel:groupTransform(group, value)
	local travel = self.travel[group]
	local pivot = self.pivots[group]
	local swing = self.swing[group]
	if group == "bolt" and pivot and swing then
		-- Turn the bolt up, then draw it back.
		local turn = math.clamp(value, 0, 1)
		local back = math.clamp(value - 1, 0, 1)
		return CF(0, 0, (travel or 0) * back) * pivot * CFrame.Angles(rad(swing) * turn, 0, 0) * pivot:Inverse()
	elseif pivot and swing then
		return pivot * CFrame.Angles(rad(swing) * value, 0, 0) * pivot:Inverse()
	elseif travel then
		return CF(0, 0, travel * value)
	end
	return CFrame.identity
end

function Viewmodel:muzzleCFrame()
	local muzzle = self.keys.Muzzle
	return self.frame and muzzle and self.frame * muzzle or nil
end

function Viewmodel:eject()
	local eject = self.keys.Eject
	if self.casing ~= "none" and eject and self.frame then
		emit(self, "casing", self.frame * eject, self.casing)
	end
end

-- Resolves a hand anchor to a CFrame in gun space: a keypoint (riding its moving group), the pocket
-- (low beside you, in view space), or the grip.
function Viewmodel:anchor(name, transforms, view, frame)
	if name == "Pocket" then
		return frame:ToObjectSpace(view * CF(-0.62, -1.45, -0.55) * A(-35, 25, 10))
	end
	local keyFrame = self.keys[name] or self.keys.SupportHand or self.keys.GripHand
	local group = self.keyGroups[name]
	local transform = group and transforms[group]
	if transform then
		keyFrame = transform * keyFrame
	end
	return keyFrame
end

-- Returns the hand's frame, how far it closes, and how its fingers close on this gun: where the knuckle
-- plane is, how far the fingertips turn in under what they hold, and how far the gun lets them close at
-- all. All nil where the hand is on nothing, and the hand then simply closes on itself.
local function handTrack(self, track, t, transforms, view, frame, default)
	local function held(name)
		local shape = self.gripShapes and self.gripShapes[name]
		return shape and shape.fingers or nil
	end
	if not track then
		return self:anchor(default, transforms, view, frame), CURL[default] or 0.8, held(default)
	end
	local a, b, s = sample(track, t)
	local function resolve(entry)
		local cframe = self:anchor(entry[2], transforms, view, frame)
		if entry[3] then
			cframe = cframe + entry[3]
		end
		return cframe, CURL[entry[2]] or 0.7, held(entry[2])
	end
	local ca, curlA, heldA = resolve(a)
	local cb, curlB, heldB = resolve(b)
	-- What each finger may do belongs to one anchor or the other: it is the gun's shape where the hand
	-- is, not a blend of two shapes. So the nearer anchor's is used whole and the hand's own `curl`,
	-- which does blend, carries the movement between them.
	local shape = heldA
	if s >= 0.5 then
		shape = heldB or heldA
	else
		shape = heldA or heldB
	end
	return ca:Lerp(cb, s), curlA + (curlB - curlA) * s, shape
end

-- input: camera (CFrame), aiming, sprinting, speed, grounded, velocity (Vector3, local to the root),
-- mouseDelta (Vector2), sway (bool), landDip, slideDip, reloading (bool)
function Viewmodel:Update(dt, input)
	dt = math.min(dt, 0.1)
	self.now += dt
	local now = self.now
	if now >= (self.nightCheckAt or 0) then
		self.nightCheckAt = now + 0.5
		self:updateNightSights()
	end
	local view = input.camera

	-- Blends.
	-- Aim blends out while the hands work the gun (a reload, a rack on the draw, breaking a double open):
	-- the pull or the break goes on below the eye, not across the sight picture.
	local wantAim = input.aiming and not self.clips.reload and not self.clips.rack and 1 or 0
	self.aim += (wantAim - self.aim) * math.clamp(dt * 13, 0, 1)
	local wantSprint = (input.sprinting and (input.speed or 0) > 4 and not input.aiming) and 1 or 0
	self.sprint += (wantSprint - self.sprint) * math.clamp(dt * 9, 0, 1)
	local aim = smooth(self.aim)

	-- The draw, and the rack that follows the first one.
	local raised = math.clamp((now - self.equipAt) / 0.35, 0, 1)
	local down = (1 - raised) ^ 3
	if self.pendingRack and now - self.equipAt >= self.pendingRack.delay then
		self:play("rack", self.pendingRack, 0.55)
		self.pendingRack = nil
	end

	-- Clips: sample every track of every playing clip. Later kinds win where they overlap.
	local values = {}
	local gunOffset = CFrame.identity
	local leftTrack, rightTrack, leftT, rightT = nil, nil, 0, 0
	local propKind
	for _, kind in ipairs({ "fire", "rack", "inspect", "reload" }) do
		local clip = self.clips[kind]
		if clip then
			local t = math.clamp((now - clip.start) / clip.duration, 0, 1)
			if clip.values then
				for name, track in pairs(clip.values) do
					values[name] = sampleValue(track, t)
				end
			end
			if clip.gun then
				local a, b, s = sample(clip.gun, t)
				local position = a[2]:Lerp(b[2], s)
				local rotation = a[3]:Lerp(b[3], s)
				-- Working the action between aimed shots (a pump, a lever, a bolt) keeps the gun on target:
				-- fully aimed, the gun moves a sixth as far, about the eye, so the sights stay in line and the
				-- crosshair stays on the sight picture instead of the receiver.
				if kind == "fire" or kind == "rack" then
					local keep = 1 - 0.85 * aim
					position *= keep
					rotation *= keep
				end
				gunOffset = gunOffset * CF(position) * A(rotation.X, rotation.Y, rotation.Z)
			end
			if clip.left then
				leftTrack, leftT = clip.left, t
			end
			if clip.right then
				rightTrack, rightT = clip.right, t
			end
			if clip.prop then
				propKind = clip.prop
			end
			for index, event in ipairs(clip.events or {}) do
				if t >= event[1] and not clip.fired[index] then
					clip.fired[index] = true
					self:handleEvent(event)
				end
			end
			if t >= 1 then
				self.clips[kind] = nil
				if kind == "reload" then
					self.slideLocked = false
					self.cocked = true
					self.roundShown = true
					self:clearProps()
				end
			end
		end
	end

	-- Persistent mechanism state.
	if self.slideLocked and values.slide == nil then
		values.slide = 1
	end
	self.drumAngle += (self.drumTarget - self.drumAngle) * math.clamp(dt * 18, 0, 1)
	self.spinSpeed = math.max(0, self.spinSpeed - dt * (self.spinSpeed > 10 and 22 or 8))
	self.spin += self.spinSpeed * dt

	-- Springs: the kick settles back, stiffer and better damped while aimed. Stepped no coarser than 1/60 s:
	-- in one step, a 10 fps frame made the spring unstable, each frame throwing the gun further.
	local stiffness, damping = 180 + 120 * aim, 16 + 8 * aim
	local springSteps = math.max(1, math.ceil(dt * 60 - 1e-6))
	local springDt = dt / springSteps
	for _ = 1, springSteps do
		self.kickVel += (-self.kickPos * stiffness - self.kickVel * damping) * springDt
		self.kickPos += self.kickVel * springDt
		self.kickRotVel += (-self.kickRot * stiffness - self.kickRotVel * damping) * springDt
		self.kickRot += self.kickRotVel * springDt
	end

	-- Sway, bob, breathing, strafe roll, the jump and the landing. Aiming steadies all of it; the stride
	-- bob, breathing and the landing and slide dips (which move the sight picture itself) almost entirely.
	local steady = 1 - aim * 0.85
	local still = 1 - aim * 0.95
	local bobOffset = CFrame.identity
	if input.sway ~= false then
		local speed = input.speed or 0
		if input.grounded and speed > 1 then
			self.bob += dt * speed * (0.55 + self.sprint * 0.25)
		end
		local amplitude = (input.grounded and math.min(speed / 16, 1.5) or 0) * still
		local breathe = math.sin(now * 1.6) * 0.01 * still
		bobOffset = CF(math.sin(self.bob) * 0.045 * amplitude, -math.abs(math.cos(self.bob)) * 0.06 * amplitude + breathe, 0)
			* A(0, 0, math.deg(math.sin(self.bob) * 0.025 * amplitude))
		local mouse = input.mouseDelta or Vector2.zero
		local blend = math.clamp(dt * 10, 0, 1)
		self.swayX += (math.clamp(-mouse.X * 0.0032, -0.12, 0.12) - self.swayX) * blend
		self.swayY += (math.clamp(-mouse.Y * 0.0032, -0.09, 0.09) - self.swayY) * blend
	else
		self.swayX, self.swayY = 0, 0
	end
	local localVelocity = input.velocity or Vector3.zero
	local moveBlend = math.clamp(dt * 6, 0, 1)
	self.roll += (math.clamp(-localVelocity.X * 0.004, -0.08, 0.08) - self.roll) * moveBlend
	self.airPitch += (math.clamp((localVelocity.Y or 0) * 0.0025, -0.1, 0.1) - self.airPitch) * moveBlend
	local swayOffset = CFrame.Angles((self.swayY + self.airPitch) * steady, self.swayX * steady, (self.swayX * 0.7 + self.roll) * steady)

	-- The frame: hip and aim poses, blended, with every motion layered around the grip at the hip. At full
	-- aim the draw, sprint, bob and sway turn about the front sight, which holds on the target while the
	-- gun wobbles; the kick and the working of the action turn about the eye, so the front and rear sights
	-- stay in line while the whole picture tips and settles.
	local hold = self.hold
	local grip = self.gripPoint
	local hip = view * CF(self.hipPosition) * A(hold.pitch, hold.yaw, 0) * CF(-grip)
	local sight = self.keys.Sight or CF(0, 0.2, 0.2)
	local ads = view * CF(0, 0, -self.eyeRelief) * sight:Inverse()
	local base = hip:Lerp(ads, aim)

	local sprintPose = hold.sprint
	local sprintOffset = CF(sprintPose[1] * self.sprint) * A(sprintPose[2].X * self.sprint, sprintPose[2].Y * self.sprint, sprintPose[2].Z * self.sprint)
	local equipOffset = CF(0, -1.0 * down, 0.35 * down) * A(-60 * down + math.sin(raised * math.pi) * 3, 0, 25 * down)
	local landDip, slideDip = (input.landDip or 0) * still, (input.slideDip or 0) * still
	local kickOffset = CF(self.kickPos.X, self.kickPos.Y - landDip - slideDip * 0.6, self.kickPos.Z)
		* A(self.kickRot.X + slideDip * 6, self.kickRot.Y, self.kickRot.Z + slideDip * 5)
	local motionPivot = grip:Lerp(self.aimPivot, aim)
	local actionPivot = grip:Lerp(self.eyePoint, aim)
	-- At the hip the two pivots are one point, toAction is the identity, and this is the one motion
	-- equip * sprint * gun * bob * sway * kick about the grip it always was.
	local toAction = CF(-motionPivot) * CF(actionPivot)
	local frame = base * CF(motionPivot) * equipOffset * sprintOffset * toAction * gunOffset * toAction:Inverse()
		* bobOffset * swayOffset * toAction * kickOffset * CF(-actionPivot)
	self.frame = frame

	-- Group transforms.
	local transforms = {}
	local function transformOf(group)
		if transforms[group] then
			return transforms[group]
		end
		local own
		if group == "drum" then
			local pivot = self.pivots.drum
			local turn = self.drumAngle + (values.drum or 0) * math.pi * 2
			own = pivot and pivot * CFrame.Angles(turn, 0, 0) * pivot:Inverse() or CFrame.identity
		elseif group == "spin" then
			local pivot = self.pivots.spin
			own = pivot and pivot * CFrame.Angles(self.spin, 0, 0) * pivot:Inverse() or CFrame.identity
		elseif group == "mag" or group == "round" or group == "rounds" or group == "string" or group == "stringRest" then
			own = CFrame.identity
		else
			own = self:groupTransform(group, values[group] or 0)
		end
		local parent = self.parents[group]
		if parent then
			own = transformOf(parent) * own
		end
		transforms[group] = own
		return own
	end
	for group in pairs(self.groupParts) do
		transformOf(group)
	end
	for group in pairs(self.pivots) do
		transformOf(group)
	end
	for group in pairs(self.travel) do
		transformOf(group)
	end

	-- Hands.
	local leftLocal, leftCurl, leftHeld = handTrack(self, leftTrack, leftT, transforms, view, frame, "SupportHand")
	local rightLocal, rightCurl, rightHeld = handTrack(self, rightTrack, rightT, transforms, view, frame, "GripHand")
	if not self.keys.SupportHand then
		leftLocal = self:anchor("Pocket", transforms, view, frame)
	end
	self.hands.left = self.hands.left and self.hands.left:Lerp(leftLocal, math.clamp(dt * 22, 0, 1)) or leftLocal
	self.hands.right = self.hands.right and self.hands.right:Lerp(rightLocal, math.clamp(dt * 22, 0, 1)) or rightLocal
	local leftWorld = frame * self.hands.left
	local rightWorld = frame * self.hands.right

	-- Held things follow the left hand: the magazine (from its seat under MagHand), the round (from its
	-- place at Load), and a pocket prop.
	local magHold = values.magHold or 0
	if magHold > 0 and self.keys.MagHand then
		local attached = frame:ToObjectSpace(leftWorld * self.keys.MagHand:Inverse())
		transforms.mag = CFrame.identity:Lerp(attached, magHold)
	end
	local magSlide = values.magSlide or 0
	if magSlide > 0 then
		local well = self.keys.MagWell or CFrame.identity
		local direction = well:VectorToWorldSpace(V(0, -1, 0))
		transforms.mag = (transforms.mag or CFrame.identity) + direction * magSlide
	end
	local roundHold = values.roundHold or 0
	if roundHold > 0 and self.keys.Load then
		local attached = frame:ToObjectSpace(leftWorld * self.keys.Load:Inverse())
		transforms.round = CFrame.identity:Lerp(attached, roundHold)
	end

	-- Visibility.
	local magVisible = (values.magVisible or 1) > 0.5
	local roundVisible
	if values.roundVisible ~= nil then
		roundVisible = values.roundVisible > 0.5
	else
		roundVisible = self.roundShown
	end
	local roundsVisible = (values.roundsVisible or 1) > 0.5
	local cocked = values.cocked ~= nil and values.cocked > 0.5 or (values.cocked == nil and self.cocked)
	if values.cocked ~= nil and values.cocked > 0.5 then
		self.cocked = true
	end
	local visibility = { mag = magVisible, round = roundVisible, rounds = roundsVisible, string = cocked, stringRest = not cocked }
	local visibilityKey = string.format("%s%s%s%s%s", tostring(magVisible), tostring(roundVisible), tostring(roundsVisible), tostring(cocked), tostring(self.hidden))
	if visibilityKey ~= self.visibilityKey or self.visibilityDirty then
		self.visibilityKey = visibilityKey
		self.visibilityDirty = false
		for group, shown in pairs(visibility) do
			for _, part in ipairs(self.groupParts[group] or {}) do
				veil(part, self.hidden or not shown)
			end
		end
	end

	-- Energy glow.
	if values.glow and self.groupParts.glow == nil then
		self.glowLevel = values.glow
	end

	-- Move everything.
	local parts = table.create(#self.parts + 16)
	local cframes = table.create(#self.parts + 16)
	for _, part in ipairs(self.model:GetChildren()) do
		local offset = self.offsets[part]
		if offset then
			local group = self.groupOf[part]
			local transform = group and transforms[group]
			parts[#parts + 1] = part
			cframes[#cframes + 1] = transform and frame * transform * offset or frame * offset
		end
	end
	self.arms:pose(1, view, rightWorld, rightCurl, parts, cframes, rightHeld)
	self.arms:pose(-1, view, leftWorld, leftCurl, parts, cframes, leftHeld)

	-- The prop in the left hand.
	local propHold = values.propHold or 0
	for kind, prop in pairs(self.props) do
		if kind ~= propKind or propHold < 0.5 then
			if prop.shown then
				prop.model.Parent = nil
				prop.shown = false
			end
		end
	end
	if propKind and propHold >= 0.5 then
		local prop = self:prop(propKind)
		if not prop.shown then
			prop.model.Parent = self.model
			prop.shown = true
		end
		local held = leftWorld * CF(0, -0.07, -0.2)
		for _, part in ipairs(prop.parts) do
			parts[#parts + 1] = part
			cframes[#cframes + 1] = held * prop.offsets[part]
		end
	end

	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)

	local scopedIn = self.scoped and self.aim > 0.92 and not self.clips.reload and not self.clips.rack
	return {
		frame = frame,
		muzzle = self:muzzleCFrame(),
		scopedIn = scopedIn,
		aim = self.aim,
		laser = self.laserEmitter and self.laserEmitter.CFrame or nil,
		reloading = self.clips.reload ~= nil,
	}
end

function Viewmodel:handleEvent(event)
	local kind = event[2]
	if kind == "sound" then
		emit(self, "sound", event[3])
	elseif kind == "eject" then
		self:eject()
	elseif kind == "drop" then
		-- A copy of the magazine where it is right now, handed off to fall away.
		local group = event[3]
		local copy = Instance.new("Model")
		copy.Name = "BRR_Dropped"
		for _, part in ipairs(self.groupParts[group] or {}) do
			local clone = part:Clone()
			veil(clone, false)
			clone:SetAttribute("Anim", nil)
			clone.Parent = copy
		end
		if #copy:GetChildren() > 0 then
			emit(self, "drop", copy, self.frame and self.frame.UpVector or Vector3.yAxis)
		else
			copy:Destroy()
		end
	elseif kind == "casings" then
		-- Out of the ejector where a gun has one (a break gun throws its empties up and back as the barrels
		-- drop); otherwise from where the hand loads, which is where a revolver's cases fall.
		local load = self.keys.Eject or self.keys.Load
		if load and self.frame then
			for _ = 1, event[3] or 1 do
				emit(self, "casing", self.frame * load * CF((math.random() - 0.5) * 0.05, (math.random() - 0.5) * 0.05, 0), self.action == "break" and "shell" or "pistol", true)
			end
		end
	end
end

-- For the gallery: freeze a viewmodel at a moment. `state` sets aim/sprint directly and can start a
-- clip `progress` of the way through.
function Viewmodel:Pose(camera, state)
	-- As in play: aim has blended out by the time a reload or a rack is under way.
	self.aim = (state.clip == "reload" or state.clip == "rack") and 0 or state.aim or 0
	self.sprint = state.sprint or 0
	self.equipAt = -math.huge
	self.clips = {}
	self.hands = {}
	if state.clip == "reload" then
		self:StartReload(1, state.roundsLeft or 0, state.magSize or 30)
	elseif state.clip == "rack" then
		self:play("rack", rackClip(self), 1)
	elseif state.clip == "fire" then
		self:play("fire", fireClip(self, state.roundsLeft or 5), 1)
	elseif state.clip == "inspect" then
		self:Inspect()
	end
	local onEvent = self.onEvent
	self.onEvent = nil
	for _, clip in pairs(self.clips) do
		clip.start = self.now - (state.progress or 0) * clip.duration
	end
	self:Update(0, { camera = camera, aiming = (state.aim or 0) > 0.5, sway = false, speed = 0, grounded = true })
	self.onEvent = onEvent
end

return Viewmodel
