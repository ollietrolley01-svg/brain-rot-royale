-- Crouching, as an animation rather than a held pose.
--
-- Nothing in this project can upload keyframed animation, so this is procedural — but procedural done
-- properly: every value here is a pure function of its arguments (how far into the crouch, how far the
-- body has WALKED, and the clock), the way Shared/CompanionAnimations is written. That means the gallery
-- can render any frame of it and tools/crouch_probe.lua can measure it, with no client running.
--
--   CrouchAnimation.Weight(elapsed, entering)   0..1, eased: 0.18 s in, 0.14 s out
--   CrouchAnimation.Segments(character)         { upper, lower, foot, length } measured off the rig
--   CrouchAnimation.Depth(segments, drop)       how high the hips ride over the soles while crouched
--   CrouchAnimation.Stride(character)           the step length, and the segments it came from
--   CrouchAnimation.Walk(speed, crouchSpeed)    0..1: how much walk cycle to mix over the idle
--   CrouchAnimation.Advance(phase, moved, ...)  turns studs travelled into cycle phase
--   CrouchAnimation.Foot(phase, ...)            where a sole is, relative to the hip (the probe's hook)
--   CrouchAnimation.Pose(state)                 { Root, Waist, Neck, hips, knees, ankles }
--   CrouchAnimation.Apply(joints, pose, weight) writes them onto Motor6Ds / AnimationConstraints
--
-- HOW THE FEET STAY PLANTED. The legs are not a pair of sine waves on the hip and knee — that was the
-- first cut, and it skated nearly a stud a cycle, because a FOLDED leg's foot swings far less than
-- sin(SWING) x its length. Instead each sole is given a target in the world and the leg is solved to
-- reach it:
--
--   * planted half-cycle: the sole holds still on the ground and slides backward through the body,
--     covering exactly the distance the body travels, so skate is zero by construction;
--   * swing half-cycle: it lifts and swings forward to meet the next plant;
--   * a two-link IK (upper leg, lower leg) turns that target into hip and knee angles, and the ankle
--     takes whatever is left over so the sole stays flat.
--
-- Measured by tools/crouch_probe.lua on a real R15: 0.00 studs of skate at any steady speed, 0.07 while
-- accelerating from a standstill to full crouch speed in 0.2 s, against a target of 0.35. (The residue is
-- the step length changing mid-step as the speed changes.) The sole is flat under the body at mid-stance
-- and rolls at most 30 degrees at the ends of the stride, which is toe-off and heel-strike.
--
-- The hips ride at `depth` over the soles, and depth comes from the body's OWN HipHeight — the same
-- number MatchService lowered to put the body down (MovementConfig.Crouch.HipScale). Pose and collision
-- can therefore never disagree: retune HipScale and the legs fold to match.
--
-- Lower body, spine and neck: the arms keep the gun pose (GunPoseClient), exactly like Parkour.ApplyPose.
-- The neck is here only to undo the chest's lean, so the body doesn't crouch staring at its own feet.

local CrouchAnimation = {}

CrouchAnimation.EnterTime = 0.18
CrouchAnimation.ExitTime = 0.14

-- The crouch itself, in degrees at full weight. The legs aren't in this list: they are solved.
local LEAN = 16
local WAIST = 10
-- The walk cycle, all as fractions of the LEG (hip joint to sole), so every avatar scales with it.
--
-- STEP is not taste: it is the longest step the foot can take before the ankle has to bend further than
-- an ankle bends. Crouched, the hips ride barely half a leg off the ground, and the further the foot
-- reaches from under them the more the ankle has to roll to keep the sole down. Measured across the
-- cycle by tools/crouch_probe.lua: 0.75 costs 30 degrees of roll at the ends of the stride, which is
-- toe-off and heel-strike; 0.88 costs 45, which is a broken foot. So the step is 0.75 and the cadence
-- (about 4.8 steps a second at crouch speed) follows from it, rather than the other way round.
--
-- STANCE is how far in front of the hips the feet sit. Crouching puts your hips BACK over your heels —
-- with the feet directly under them the ankle needs 63 degrees at mid-stance and the sole can never lie
-- flat. At 0.3 of a leg forward it needs 35, inside a real ankle, and the sole is flat where it matters.
local STEP = 0.75
local STANCE = 0.2 -- of the full stride, which works out at 0.3 of a leg
-- How high the swinging foot lifts, also of the stride: 0.077 of a stride is 0.115 of a leg, about a
-- quarter of a stud on a default rig. Enough to clear the ground and read as a step; more and the ankle
-- has to roll past its limit at the top of the swing.
local LIFT = 0.077
-- How far the ankle may bend to keep the sole flat, in degrees (toes down positive). Holding the foot
-- flat through the WHOLE cycle would want 74 degrees at the back of the stride, which is not a foot, it
-- is a break — a human ankle points to about 50. Clamped here, the heel simply comes up at the back
-- instead (toe-off, which is what a real foot does there) while mid-stance stays flat to under 2
-- degrees. Measured by tools/crouch_probe.lua, which asserts both ends of that.
local ANKLE_DOWN, ANKLE_UP = 50, 25
-- How much of the chest's lean the neck takes back out. The Root and the Waist together pitch the torso
-- 26 degrees over, and the head is bolted to the top of it: left alone, a crouching body stares at its
-- own feet. Not all of it — a crouch does drop the chin a little, and a head held perfectly level over a
-- folded body looks stuffed.
local HEAD_LEVEL = 0.85
local BOB = 1.4
-- The idle: breathing and a slow shift of weight, so a held crouch is never a statue.
local BREATH_RATE, BREATH = 1.6, 1.5
local SHIFT_RATE, SHIFT = 1.25, 2.2
-- Below this fraction of the crouch's own speed the walk cycle fades out into the idle.
local WALK_FADE = 0.12
-- The phase advances per stud travelled against the stride the CURRENT amplitude actually covers, or a
-- half-speed walk would skate as badly as the old formula did. Amplitude below this is treated as this
-- (the legs are barely moving there, and dividing by zero is worse).
local MIN_AMPLITUDE = 0.3

local rad, sin, cos = math.rad, math.sin, math.cos
local pi = math.pi
local TAU = pi * 2

local function smoothIn(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- 0..1 while crouching down, 1..0 while standing up. Going down eases out (it drops quickly, then
-- settles); standing up eases in (a push off the knees), so the two read as different movements.
function CrouchAnimation.Weight(elapsed, entering)
	if entering then
		local t = math.clamp(elapsed / CrouchAnimation.EnterTime, 0, 1)
		return 1 - (1 - t) * (1 - t)
	end
	local t = math.clamp(elapsed / CrouchAnimation.ExitTime, 0, 1)
	return 1 - smoothIn(t)
end

-- The leg, measured off the rig's own JOINTS: hip to knee, knee to ankle, ankle to sole.
--
-- NOT off the part sizes, which was the first cut and was wrong by a third: R15's leg parts OVERLAP, so
-- on a default rig their heights add up to 2.98 studs while the hip really sits 2.27 above the sole. A
-- pose built on the longer number reaches for ground that isn't there — the probe caught the soles a
-- third of a stud under the floor and the ankle bent to 92 degrees trying to stay flat.
--
-- Bone lengths are distances between joints, so they don't care what the body is doing when we measure:
-- this is safe to call on a character mid-animation, which is exactly when it is called.
function CrouchAnimation.Segments(character)
	-- A bone is measured between the two joint points that sit on the SAME part, in that part's own
	-- local space: the hip's socket and the knee's socket are both fixed points on the upper leg, so their
	-- distance is the thigh, whatever the body is doing and however the rig is being simulated. Measuring
	-- between WORLD points on different parts looks equivalent and isn't: a bot is a physics rig whose
	-- joints stretch slightly under load, and the gallery caught that reading a leg 6% long.
	local function pointOn(part, jointName, which)
		local joint = part and part:FindFirstChild(jointName)
		if not joint then
			return nil
		end
		if joint:IsA("Motor6D") then
			return (which == 0 and joint.C0 or joint.C1).Position
		end
		if joint:IsA("AnimationConstraint") then
			local attachment = which == 0 and joint.Attachment0 or joint.Attachment1
			return attachment and attachment.Position or nil
		end
		return nil
	end
	local upperPart = character and character:FindFirstChild("LeftUpperLeg")
	local lowerPart = character and character:FindFirstChild("LeftLowerLeg")
	local footPart = character and character:FindFirstChild("LeftFoot")
	-- On the upper leg: where it hangs from the hip (the hip joint's far end) and where the knee is.
	local hipOnUpper = pointOn(upperPart, "LeftHip", 1)
	local kneeOnUpper = pointOn(lowerPart, "LeftKnee", 0)
	-- On the lower leg: the knee's far end and the ankle.
	local kneeOnLower = pointOn(lowerPart, "LeftKnee", 1)
	local ankleOnLower = pointOn(footPart, "LeftAnkle", 0)
	-- On the foot: the ankle's far end, and the sole straight below it.
	local ankleOnFoot = pointOn(footPart, "LeftAnkle", 1)
	local segments
	if hipOnUpper and kneeOnUpper and kneeOnLower and ankleOnLower and ankleOnFoot and footPart then
		segments = {
			upper = (hipOnUpper - kneeOnUpper).Magnitude,
			lower = (kneeOnLower - ankleOnLower).Magnitude,
			foot = ankleOnFoot.Y + footPart.Size.Y / 2,
		}
	else
		-- A default R15, measured.
		segments = { upper = 1.04, lower = 0.99, foot = 0.24 }
	end
	segments.length = segments.upper + segments.lower + segments.foot
	return segments
end

-- How high the hip joints ride over the soles once the body has dropped by `drop` studs. Clamped so the
-- leg can always reach: fully folded it still spans a little, and fully straight it spans `length`.
function CrouchAnimation.Depth(segments, drop)
	local straight = segments.length
	local shortest = math.abs(segments.upper - segments.lower) + segments.foot + 0.15
	return math.clamp(straight - math.max(drop or 0, 0), shortest, straight - 0.05)
end

-- The ground a full cycle covers: two steps, each STEP of a leg. Takes the segments a caller already
-- has (this runs per body per frame) or a character to measure them from.
function CrouchAnimation.Stride(segments)
	if typeof(segments) == "Instance" or segments == nil then
		segments = CrouchAnimation.Segments(segments)
	end
	return math.max(segments.length * STEP, 0.4) * 2, segments
end

-- How much walk cycle to mix over the idle, from how fast the body is actually moving against the speed
-- a crouch-walk runs at.
function CrouchAnimation.Walk(speed, crouchSpeed)
	local fraction = (speed or 0) / math.max(crouchSpeed or 8.1, 0.1)
	return math.clamp((fraction - WALK_FADE) / (1 - WALK_FADE), 0, 1)
end

-- Studs travelled -> cycle phase. The stride shrinks with the amplitude, so a half-speed walk takes half
-- the steps rather than the same steps with sliding feet.
function CrouchAnimation.Advance(phase, moved, stride, walk)
	local cycle = math.max(stride, 0.1) * math.max(walk or 1, MIN_AMPLITUDE)
	return ((phase or 0) + (moved or 0) / cycle * TAU) % TAU
end

-- Where one sole sits relative to its hip joint: `forward` studs ahead of it, `drop` studs below.
--
-- The cycle is halves: over the first (phase 0..pi) the foot is PLANTED, moving backward through the body
-- at exactly the rate the body advances; over the second it lifts and swings forward again. The other leg
-- runs half a cycle out, so one foot is always planted.
--
-- The reach uses the SAME amplitude Advance divides by — clamped the same way — because the two must
-- agree or the foot covers a different distance from the body: that mismatch was worth 0.22 studs of
-- skate at quarter speed on its own. Only the lift follows the raw walk blend.
function CrouchAnimation.Foot(phase, walk, stride, depth)
	walk = math.clamp(walk or 0, 0, 1)
	phase = (phase or 0) % TAU
	local reach = stride * 0.25 * math.max(walk, MIN_AMPLITUDE) -- half a step either side of the stance
	-- The feet sit forward of the hips, not under them: see STANCE. Both are tied to the stride so one
	-- leg measurement sets the whole shape of the walk.
	local stance = stride * STANCE
	local lift0 = stride * LIFT
	local forward, lift
	if phase < pi then
		-- Planted: straight line from in front to behind, the same distance the body covers.
		forward = stance + reach - (phase / pi) * reach * 2
		lift = 0
	else
		-- Swing: back to the front on a raised arc. The curve is a cubic with its END SLOPES MATCHED to
		-- the planted half's, not an ease-in-out: eased, the foot would arrive still travelling forward
		-- with the body and stop dead the instant it landed, which reads as a stamp. Matching the slopes
		-- means the foot is already moving backward through the body at exactly ground speed when it
		-- touches down, so its speed over the ground is zero at the moment of contact. It also makes the
		-- foot carry on backward a little as it lifts and reach a little past the mark before settling —
		-- which is what a real swinging leg does.
		local t = (phase - pi) / pi
		forward = stance + reach * (((-8 * t + 12) * t - 2) * t - 1)
		lift = sin(t * pi) * lift0 * walk
	end
	return forward, depth - lift
end

-- Two-link IK: hip and knee angles (radians, forward positive) that put the ankle at (forward, drop)
-- relative to the hip, with the leg bending knee-first like a real one.
local function solveLeg(forward, drop, upper, lower)
	local reach = math.sqrt(forward * forward + drop * drop)
	local limit = (upper + lower) * 0.999
	local floor = math.abs(upper - lower) + 0.02
	reach = math.clamp(reach, floor, limit)
	-- Interior angle at the knee, then the angle the thigh makes with the straight line to the ankle.
	local knee = math.acos(math.clamp((upper * upper + lower * lower - reach * reach) / (2 * upper * lower), -1, 1))
	local thigh = math.acos(math.clamp((reach * reach + upper * upper - lower * lower) / (2 * reach * upper), -1, 1))
	local toTarget = math.atan2(forward, math.max(drop, 0.05))
	return toTarget + thigh, -(pi - knee)
end

-- The pose `state` describes. There is no weight here: the pose is always the full crouch, and Apply
-- does all the blending — that way one pose can be handed to several bodies at different stages of the
-- same move without being rebuilt.
--   phase       radians, from Advance
--   walk        0..1, from Walk
--   clock       os.clock(), for breathing
--   segments    from Segments
--   depth       from Depth
--   stride      from Stride
function CrouchAnimation.Pose(state)
	local segments = state.segments or CrouchAnimation.Segments(nil)
	local depth = state.depth or CrouchAnimation.Depth(segments, 0.94)
	local stride = state.stride or CrouchAnimation.Stride(segments)
	local walk = math.clamp(state.walk or 0, 0, 1)
	local phase = state.phase or 0
	local clock = state.clock or 0

	-- Idle: the spine breathes and the hips trade weight; both fade out as the walk comes in.
	local breath = sin(clock * BREATH_RATE) * BREATH * (1 - walk)
	local shift = sin(clock * SHIFT_RATE) * SHIFT * (1 - walk)
	-- Walk: the torso counter-bobs at twice the leg rate. The bob moves the HIPS, so it is taken out of
	-- the legs' targets below and the soles stay where they are.
	local bob = sin(phase * 2) * BOB * walk
	local lean = LEAN + bob

	-- The breath moves the WAIST, which is above the hips, so the legs owe it nothing.
	local rightForward, rightDrop = CrouchAnimation.Foot(phase, walk, stride, depth)
	local leftForward, leftDrop = CrouchAnimation.Foot(phase + pi, walk, stride, depth)

	-- The legs hang off LowerTorso, which the Root joint has just pitched forward by `lean`, so that
	-- pitch comes back out of the targets or the whole stance would tip with the torso.
	local pitch = rad(lean)
	local ankle = segments.foot
	--
	-- WHICH WAY THE PITCH GOES, since it is easy to get backwards and costs a stud when you do. Every R15
	-- joint here turns about its PARENT's X axis, so the angles down a limb simply add: a thigh's angle in
	-- the world is the Root's own turn plus the hip's. The Root leans the chest FORWARD on a NEGATIVE turn
	-- (Parkour.Poses agrees: the mantle leans in at -12 and the slide lies back at +48), so with `pitch`
	-- positive-forward the world thigh angle is hip - pitch. Turning a world target into the torso's own
	-- frame is therefore a turn of +pitch, which in (forward, down) terms is the pair below.
	local function leg(forward, drop)
		-- Ankle target, in the tilted torso's own frame, with the foot's own height taken off.
		local toAnkle = drop - ankle
		local x = forward * cos(pitch) + toAnkle * sin(pitch)
		local y = toAnkle * cos(pitch) - forward * sin(pitch)
		local hip, knee = solveLeg(x, y, segments.upper, segments.lower)
		-- Whatever the chain adds up to, the ankle takes back out, so the sole stays flat: the foot's own
		-- angle in the world is -pitch + hip + knee + ankle, and that has to come to nothing — as far as
		-- an ankle can, anyway.
		return hip, knee, math.clamp(pitch - hip - knee, -rad(ANKLE_UP), rad(ANKLE_DOWN))
	end
	local rightHip, rightKnee, rightAnkle = leg(rightForward, rightDrop)
	local leftHip, leftKnee, leftAnkle = leg(leftForward, leftDrop)

	-- The joints add down the chain, so the head's own angle in the world is -(lean) + -(WAIST - breath)
	-- plus whatever the neck does; this gives most of that back.
	local stoop = lean + WAIST - breath
	return {
		Root = CFrame.Angles(rad(-lean), 0, rad(shift * 0.5)),
		Waist = CFrame.Angles(rad(-WAIST + breath), 0, rad(-shift * 0.35)),
		Neck = CFrame.Angles(rad(stoop * HEAD_LEVEL), 0, rad(-shift * 0.25)),
		RightHip = CFrame.Angles(rightHip, 0, rad(shift * 0.2)),
		RightKnee = CFrame.Angles(rightKnee, 0, 0),
		RightAnkle = CFrame.Angles(rightAnkle, 0, 0),
		LeftHip = CFrame.Angles(leftHip, 0, rad(-shift * 0.2)),
		LeftKnee = CFrame.Angles(leftKnee, 0, 0),
		LeftAnkle = CFrame.Angles(leftAnkle, 0, 0),
	}
end

-- Writes a pose onto the joints (Shared/Parkour.PoseJoints finds them), blending over whatever the
-- Animator wrote this frame. Arms are never touched.
--
-- TWO WEIGHTS, and the reason matters. The body's height is not eased by anyone: MatchService sets
-- HipHeight the moment a crouch starts and the moment it ends, so the hips are DOWN on the very next
-- frame. Easing the legs into the fold over the same moment would leave them straighter than the hips
-- are low — feet through the floor going down, feet in the air coming up. So the legs take the body's
-- own timing (`legs`, normally 1 while crouched and 0 while not) and only the spine eases, which is the
-- part of the transition an ease actually reads on.
function CrouchAnimation.Apply(joints, pose, weight, legs)
	weight = math.clamp(weight == nil and 1 or weight, 0, 1)
	legs = math.clamp(legs == nil and weight or legs, 0, 1)
	if weight <= 0 and legs <= 0 then
		return
	end
	for name, target in pairs(pose) do
		local joint = joints[name]
		-- The neck exists to undo the spine's lean, so it has to ease with the spine. On the legs' timing
		-- it would be fully counter-rotated while the chest was only half over, and the head would tip UP.
		local blend = (name == "Root" or name == "Waist" or name == "Neck") and weight or legs
		if joint and blend > 0 then
			joint.Transform = blend >= 1 and target or joint.Transform:Lerp(target, blend)
		end
	end
end

return CrouchAnimation
