-- The gunner at a mounted gun, as everyone else sees them: one component for the stationary emplacements
-- (MountedGunClient) and the vehicles' turrets (VehicleClient), so both hold their guns the same way.
--
--   MountRig.GunFrames(model)                 -> yawWorld, pitchWorld   the mount as swung THIS frame (from
--                                                its joints' Transforms, not the parts, which lag a frame)
--   MountRig.GripWorld(model, name)           -> Vector3 or nil         GripR / GripL where they are this frame
--   MountRig.ArmsToGrips(character, joints, model)   both arms reach for the grips (after the body's pose)
--   MountRig.Solve(a, b, d)                   -> shoulder angle         PURE: the two-bone reach (law of cosines)
--
-- THE ARMS. A posed rider's arms are a fixed pose, and a gun that turns and tips moves its grips away from
-- them (the gallery measured the GunnerStand hands 1.1-1.2 studs off an emplacement's grips). So after the
-- body is posed, each arm is solved as two bones -- shoulder to elbow, elbow to the palm -- to put the palm
-- on its grip: the elbow hangs toward a pole below, outside and behind the shoulder, the upper arm is turned
-- to point at the elbow and the forearm at the grip. The body's own frames are worked out from the root and
-- waist joints as they stand this frame (a Transform only reaches the parts at the next physics step).
-- R15 only; an R6 rider keeps its pose.

local MountRig = {}

-- PURE BEGIN
local Pure = {}
-- The angle at the shoulder between the reach line and the upper arm, for bones `a` and `b` and a reach
-- `d` (clamped to what the arm can span).
function Pure.Solve(a, b, d)
	d = math.max(math.abs(a - b) + 1e-3, math.min(a + b - 1e-3, d))
	local c = (a * a + d * d - b * b) / (2 * a * d)
	return math.acos(math.max(-1, math.min(1, c))), d
end
-- PURE END
MountRig.Pure = Pure
MountRig.Solve = Pure.Solve

local function jointOf(model, name)
	local pivot = model:FindFirstChild(name)
	local joint = pivot and pivot:FindFirstChild("Joint")
	return joint and joint:IsA("Motor6D") and joint or nil
end

function MountRig.GunFrames(model)
	local yawJoint, pitchJoint = jointOf(model, "TurretYaw"), jointOf(model, "TurretPitch")
	if not yawJoint or not pitchJoint or not yawJoint.Part0 then
		return nil
	end
	local yawWorld = yawJoint.Part0.CFrame * yawJoint.C0 * yawJoint.Transform
	local pitchWorld = yawWorld * pitchJoint.C0 * pitchJoint.Transform
	return yawWorld, pitchWorld
end

function MountRig.GripWorld(model, name)
	local _, pitchWorld = MountRig.GunFrames(model)
	local pitch = model:FindFirstChild("TurretPitch")
	local grip = pitch and pitch:FindFirstChild(name)
	if not pitchWorld or not grip then
		return nil
	end
	return (pitchWorld * grip.CFrame).Position
end

-- The minimal rotation taking unit vector `from` onto unit vector `to`.
local function turnOnto(from, to)
	local axis = from:Cross(to)
	local s = axis.Magnitude
	local c = from:Dot(to)
	if s < 1e-6 then
		return c > 0 and CFrame.identity or CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.fromAxisAngle(axis / s, math.atan2(s, c))
end

-- World frame of a joint's Part1 given its Part0's world frame.
local function across(part0World, joint)
	return part0World * joint.C0 * joint.Transform * joint.C1:Inverse()
end

local function reach(joints, upperTorso, side, target)
	local prefix = side > 0 and "Right" or "Left"
	local shoulder, elbow, wrist = joints[prefix .. "Shoulder"], joints[prefix .. "Elbow"], joints[prefix .. "Wrist"]
	if not (shoulder and elbow and wrist) then
		return
	end
	-- Bone vectors in each bone's own part: shoulder joint to elbow joint, elbow joint to the palm.
	local upperBone = elbow.C0.Position - shoulder.C1.Position
	local palmInHand = Vector3.new(0, -0.35, 0)
	local lowerBone = wrist.C0.Position - elbow.C1.Position
	local a = upperBone.Magnitude
	local b = lowerBone.Magnitude + (palmInHand - wrist.C1.Position).Magnitude
	local shoulderWorld = upperTorso * shoulder.C0
	local s = shoulderWorld.Position
	local toTarget = target - s
	if toTarget.Magnitude < 1e-3 then
		return
	end
	local alpha, d = Pure.Solve(a, b, toTarget.Magnitude)
	local dir = toTarget.Unit
	local pole = upperTorso:VectorToWorldSpace(Vector3.new(side * 0.6, -1, 0.35))
	local across2 = pole - dir * pole:Dot(dir)
	if across2.Magnitude < 1e-3 then
		across2 = upperTorso:VectorToWorldSpace(Vector3.new(0, -1, 0))
	end
	local bend = across2.Unit
	local elbowAt = s + (dir * math.cos(alpha) + bend * math.sin(alpha)) * a
	-- The upper arm onto the elbow.
	-- Part1's world frame is Part0 * C0 * Transform * C1^-1, so a bone in Part1 points along C1^-1's turn of it.
	local fromUpper = shoulder.C1.Rotation:Inverse() * upperBone.Unit
	local want = shoulderWorld.Rotation:Inverse() * (elbowAt - s).Unit
	shoulder.Transform = turnOnto(fromUpper, want)
	-- The forearm onto the grip (from where the elbow now is).
	local upperArm = across(upperTorso, shoulder)
	local elbowWorld = upperArm * elbow.C0
	local handPoint = s + dir * d
	local fromLower = elbow.C1.Rotation:Inverse() * lowerBone.Unit
	local wantLower = elbowWorld.Rotation:Inverse() * (handPoint - elbowWorld.Position).Unit
	elbow.Transform = turnOnto(fromLower, wantLower)
	wrist.Transform = CFrame.Angles(0, 0, side * math.rad(8))
end

-- GETTING ON. Sitting teleports the body to the seat; Blend makes it a move. Where each character stood a
-- moment ago is noted (NoteStanding, sampled by MountedGunClient for everyone on foot), and for BLEND_TIME
-- after they first appear in a gun's seat the body is shown on its way from there to the grips.
MountRig.BlendTime = 0.35
-- Strong tables, cleared when the character leaves the game: weak Instance keys drop live entries
-- whenever Luau collects the wrapper, which restarted a blend half way through (a visible snap).
local standing = {} -- character -> CFrame; a cache of where they stood
local blends = {} -- character -> { seat, from, at }
local watching = {} -- character -> the connections that clear the two above

local function forget(character)
	local connections = watching[character]
	if connections then
		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
	end
	watching[character] = nil
	standing[character] = nil
	blends[character] = nil
end

local function watch(character)
	if watching[character] or typeof(character) ~= "Instance" then
		return
	end
	watching[character] = {
		character.Destroying:Connect(function()
			forget(character)
		end),
		character.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				forget(character)
			end
		end),
	}
end

function MountRig.NoteStanding(character, cframe)
	watch(character)
	standing[character] = cframe
	blends[character] = nil
end

-- `want` is the world turn the body is to be given (applied about its root, as VehicleClient's turn is);
-- `rootWorld` the HumanoidRootPart's frame; `seat` the gun's seat. Returns the turn to use this frame.
function MountRig.Blend(character, want, rootWorld, seat)
	local blend = blends[character]
	if not blend or blend.seat ~= seat then
		local from = standing[character]
		blend = { seat = seat, from = from, at = os.clock() }
		watch(character)
		blends[character] = blend
	end
	local t = blend.from and (os.clock() - blend.at) / MountRig.BlendTime or 1
	if t >= 1 then
		return want
	end
	t = t * t * (3 - 2 * t)
	local seated = want * rootWorld
	return blend.from:Lerp(seated, t) * rootWorld:Inverse()
end

-- Both arms to the grips. `joints` maps Motor6D names to the rider's joints (the pose and the root turn
-- already set this frame). `rightTarget` (optional, world) sends the right hand elsewhere: the ammo can
-- while the gun reloads or cools. Returns true when both reached for a grip.
function MountRig.ArmsToGrips(character, joints, model, rightTarget)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local rootJoint, waist = joints.Root, joints.Waist
	if not (root and rootJoint and waist and joints.RightShoulder) then
		return false
	end
	local gripR, gripL = MountRig.GripWorld(model, "GripR"), MountRig.GripWorld(model, "GripL")
	if not gripR or not gripL then
		return false
	end
	local lowerTorso = across(root.CFrame, rootJoint)
	local upperTorso = across(lowerTorso, waist)
	reach(joints, upperTorso, 1, rightTarget or gripR)
	reach(joints, upperTorso, -1, gripL)
	return true
end

return MountRig
