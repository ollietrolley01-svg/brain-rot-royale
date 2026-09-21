-- Do the first-person hands and arms ever cover the crosshair or the sights? And do the arms hold
-- together, wear the player's own skin, and carry no stray lettering?
--
-- Runs under BOTH harnesses, so one Studio slot buys the numbers and the pictures:
--   powershell -File tools/runtest.ps1 -Probe tools/ads_hands_probe.lua -WaitSeconds 420
--   powershell -File tools/gallery.ps1 -Gallery tools/ads_hands_probe.lua -OutDir <dir> -TimeoutSeconds 1500
-- (rebuild the place first: it runs against the built .rbxlx, not the .lua files)
--
-- Poses every gun's real viewmodel with the game's own Viewmodel module at a camera far from the map,
-- then traces rays from the eye against the arm parts only -- the player's own avatar arms
-- (vm.arms.parts), or the older gloved hands' named parts if a build still has them:
--
--   * the crosshair: the ray straight down the view;
--   * the sights (aiming only): the line from the eye to each part the aim is taken with -- the front
--     post's top, the bead, the red-dot or holo dot -- which a hand must never cross;
--   * the middle of the screen: rings 1 and 2.5 degrees out from the crosshair;
--   * how much of the whole screen the arms fill.
--
-- Rays are traced by hand against the parts' real shapes, not with workspace:Raycast, which pads small
-- parts by millimetres.
--
-- WHAT ELSE IT ANSWERS, measured in the same posed viewmodel rather than in a second run:
--   #26/regression B  the fingers. THE PLANTED FAULT IS THE REGRESSION ITSELF: the run is done twice,
--                     once shipped and once with Viewmodel.FingerMinCloseForTest = 0, which is the
--                     18 September bug put back (a finger with nothing to grip stands straight forward
--                     along the barrel instead of parking inside the palm). The planted pass MUST
--                     report more hidden sights than the shipped one or this check proves nothing.
--   #11               the arm joints. The gap between the upper arm's elbow end and the lower arm's
--                     elbow end, and between the lower arm's wrist end and the hand's wrist, in studs,
--                     per gun and pose. "Looks disconnected" is a distance and is measured as one.
--   #44               the arms are the player's own avatar. With an avatar built to a known arm colour,
--                     the posed arm parts must carry THAT colour; a planted second avatar in a
--                     different colour must change the measurement, or it is reading a constant.
--   #72               stray lettering. Every text-bearing instance on every gun model is listed with
--                     its host part, the face it is on, and whether its box overflows that face.
--   #87               the grenade launcher's reach, stepped through Ballistics -- the same arithmetic
--                     the server, the client and the arc preview all run -- at the live gravity.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local IN_GALLERY = string.find(game.Name, "BRR_Gallery", 1, true) ~= nil
local PREFIX = IN_GALLERY and "[BRR_Gallery] note " or "[BRR_Hands] "
local function say(fmt, ...)
	print(PREFIX .. string.format(fmt, ...))
end

local ORIGIN = Vector3.new(0, 5000, 0)
local ARM = { Sleeve = true, Elbow = true, Forearm = true, Cuff = true, Wrist = true, Palm = true, Knuckles = true, Finger = true, Thumb = true }
local SIGHTS = { FrontSight = "top", FrontBead = "top", SightDot = "centre" }
local POSES = {
	{ name = "hip", state = { aim = 0 }, fov = 70 },
	{ name = "ads", state = { aim = 1 }, fov = 70 * 0.64 },
	{ name = "ads+fire", state = { aim = 1, clip = "fire", progress = 0.5, roundsLeft = 5 }, fov = 70 * 0.64 },
	{ name = "ads+rack", state = { aim = 1, clip = "rack", progress = 0.5 }, fov = 70 * 0.64 },
}
local ASPECT = 16 / 9
-- A joint further apart than this reads as a break in the arm at first-person distance.
local JOINT_GAP = 0.03

--------------------------------------------------------------------------------
-- Avatars: a real R15 to take the arms from, and a second in a different colour so the "it is your
-- own avatar" check can be shown to move.
--------------------------------------------------------------------------------

local SKIN_A = Color3.fromRGB(204, 142, 105)
local SKIN_B = Color3.fromRGB(86, 170, 96)

local function makeAvatar(colour)
	local ok, avatar = pcall(function()
		local description = Instance.new("HumanoidDescription")
		description.LeftArmColor = colour
		description.RightArmColor = colour
		return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	return ok and avatar or nil
end

local avatarA = makeAvatar(SKIN_A)
local avatarB = makeAvatar(SKIN_B)
if not avatarA then
	say("NO AVATAR could be built here; the viewmodel falls back to stand-in arms and #44 is NOT measured")
end

--------------------------------------------------------------------------------
-- Ray tracing
--------------------------------------------------------------------------------

-- Where a ray (origin + t * direction, t in 0..1) is inside a part's real shape, or nil.
local function interval(part, origin, direction)
	local cf = part.CFrame
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local h = part.Size / 2
	local tmin, tmax = 0, 1
	local function slab(oi, di, hi)
		if math.abs(di) < 1e-9 then
			return math.abs(oi) <= hi
		end
		local a, b = (-hi - oi) / di, (hi - oi) / di
		tmin, tmax = math.max(tmin, math.min(a, b)), math.min(tmax, math.max(a, b))
		return tmin <= tmax
	end
	local function quadratic(a, b, c)
		if a < 1e-9 then
			return c <= 0
		end
		local disc = b * b - 4 * a * c
		if disc < 0 then
			return false
		end
		local root = math.sqrt(disc)
		tmin, tmax = math.max(tmin, (-b - root) / (2 * a)), math.min(tmax, (-b + root) / (2 * a))
		return tmin <= tmax
	end
	local shape = part:IsA("Part") and part.Shape or nil
	if shape == Enum.PartType.Ball then
		local r = math.min(h.X, h.Y, h.Z)
		if not quadratic(d:Dot(d), 2 * o:Dot(d), o:Dot(o) - r * r) then
			return nil
		end
	elseif shape == Enum.PartType.Cylinder then
		local r = math.min(h.Y, h.Z)
		if not (slab(o.X, d.X, h.X) and quadratic(d.Y * d.Y + d.Z * d.Z, 2 * (o.Y * d.Y + o.Z * d.Z), o.Y * o.Y + o.Z * o.Z - r * r)) then
			return nil
		end
	elseif not (slab(o.X, d.X, h.X) and slab(o.Y, d.Y, h.Y) and slab(o.Z, d.Z, h.Z)) then
		return nil
	end
	return tmin
end

local function firstArm(arms, origin, direction)
	local best, bestT = nil, math.huge
	for _, part in ipairs(arms) do
		local t = interval(part, origin, direction)
		if t and t < bestT then
			best, bestT = part, t
		end
	end
	return best
end

local folder = Instance.new("Folder")
folder.Name = "BRR_HandsProbe"
folder.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local eye = CFrame.new(ORIGIN)

--------------------------------------------------------------------------------
-- The arm's own joints (#11)
--------------------------------------------------------------------------------

-- `fit` scales a bone by a different factor on each axis: thickness across, and length along Y. When a
-- rig attachment sits off the part's centre line (a body package's shoulder, an R15 lower arm's wrist)
-- the joint-to-joint vector is NOT along Y, so scaling it per axis changes its length and its
-- direction -- and the end that is not pinned lands away from the joint it should meet. That is what
-- "the joints look disconnected" is, so it is measured as a distance rather than judged.
local function boneEnds(bone)
	local part = bone.part
	if not part or not bone.base then
		return nil, nil
	end
	local scale = Vector3.new(part.Size.X / bone.base.X, part.Size.Y / bone.base.Y, part.Size.Z / bone.base.Z)
	local top = bone.rawTop * scale
	local bottom = bone.rawBottom * scale
	return part.CFrame * top, part.CFrame * bottom
end

-- WHY a joint is where it is, so the fix is aimed rather than guessed. `fit` scales a bone by a
-- different factor on each axis, and `place` then turns it so the part's +Y lies along the bone. Both
-- assume the two rig attachments sit on the part's centre line. When they do not:
--   * the scaled joint-to-joint vector is no longer `length x stretch` long (a LENGTH error), and
--   * it no longer points along the part's +Y (a DIRECTION error),
-- and the end that is not pinned lands away from the joint it should meet by roughly the two combined.
-- Both are computed here from the bone's own numbers, with what the corrected scale would give, so the
-- fix can be judged before it is written. If a rig's attachments ARE on the centre line both come out
-- zero and the current code is already right for it.
local function boneError(bone)
	local part = bone.part
	if not part or not bone.base or not bone.rawTop or not bone.rawBottom then
		return nil
	end
	local raw = bone.rawTop - bone.rawBottom
	local across = part.Size.X / bone.base.X
	local through = part.Size.Z / bone.base.Z
	local alongNow = part.Size.Y / bone.base.Y
	local wanted = (bone.length or 0) * (bone.stretch or 1)
	local joint = Vector3.new(raw.X * across, raw.Y * alongNow, raw.Z * through)
	local sideways = math.sqrt((raw.X * across) ^ 2 + (raw.Z * through) ^ 2)
	local lengthError = joint.Magnitude - wanted
	local direction = math.deg(math.atan2(sideways, math.abs(raw.Y * alongNow)))
	-- What the Y scale would have to be for the two joints to end up exactly `wanted` apart.
	local fixed = wanted * wanted - sideways * sideways
	fixed = fixed > 0 and math.sqrt(fixed) / math.max(math.abs(raw.Y), 1e-6) or nil
	return {
		lengthError = lengthError,
		direction = direction,
		sideways = sideways,
		wanted = wanted,
		scaleNow = alongNow,
		scaleFixed = fixed,
	}
end

local function jointGaps(arm)
	if not arm or not arm.upper or not arm.lower then
		return nil
	end
	local _, upperBottom = boneEnds(arm.upper)
	local lowerTop, lowerBottom = boneEnds(arm.lower)
	if not upperBottom or not lowerTop then
		return nil
	end
	local elbow = (upperBottom - lowerTop).Magnitude
	local wrist = nil
	if arm.hand and arm.handTop and lowerBottom then
		-- The hand is placed at its own frame; its wrist joint is handTop in that frame.
		local handWrist = arm.hand.CFrame * arm.handTop
		wrist = (lowerBottom - handWrist).Magnitude
	end
	return { elbow = elbow, wrist = wrist, upperError = boneError(arm.upper), lowerError = boneError(arm.lower) }
end

--------------------------------------------------------------------------------
-- Stray lettering on a gun (#72)
--------------------------------------------------------------------------------

local textFindings = {}
local textSeen = {}

local function sweepText(id, model)
	if textSeen[id] then
		return
	end
	textSeen[id] = true
	for _, d in ipairs(model:GetDescendants()) do
		local host = d:FindFirstAncestorWhichIsA("BasePart")
		if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
			local gui = d:FindFirstAncestorWhichIsA("SurfaceGui")
			local face = gui and gui.Face.Name or "(not on a face)"
			local hostSize = host and host.Size or Vector3.zero
			-- The two face dimensions for a Left/Right face are Z (along) and Y (up); for Front/Back,
			-- X and Y; for Top/Bottom, X and Z.
			local along, up = hostSize.Z, hostSize.Y
			if gui and (gui.Face == Enum.NormalId.Front or gui.Face == Enum.NormalId.Back) then
				along, up = hostSize.X, hostSize.Y
			elseif gui and (gui.Face == Enum.NormalId.Top or gui.Face == Enum.NormalId.Bottom) then
				along, up = hostSize.X, hostSize.Z
			end
			-- How big the lettering really is, in studs on the gun and in canvas pixels. A SurfaceGui in
			-- PixelsPerStud mode IGNORES CanvasSize, so a 640 x 160 canvas written in the source can be
			-- a 6 x 34 pixel canvas in fact -- and TextScaled then squeezes a word into a few pixels,
			-- which is what "random floating text" looks like at any distance. Both are printed, with
			-- the glyph height in studs, so the finding is a measurement and not an impression.
			local canvasH, canvasW = 0, 0
			if gui then
				if gui.SizingMode == Enum.SurfaceGuiSizingMode.FixedSize and gui.CanvasSize.Y > 0 then
					canvasW, canvasH = gui.CanvasSize.X, gui.CanvasSize.Y
				else
					canvasW, canvasH = along * gui.PixelsPerStud, up * gui.PixelsPerStud
				end
			end
			local boxH = canvasH * d.Size.Y.Scale + d.Size.Y.Offset
			local glyphStuds = canvasH > 0 and (boxH / canvasH) * up or 0
			table.insert(textFindings, string.format(
				"%s: \"%s\" on %s face %s | face %.3f x %.3f studs | sizing %s -> canvas %.0f x %.0f px | text box %.1f px tall = %.4f studs of gun | scaled %s | always-on-top %s | visible to %.0f studs",
				id, (string.gsub(d.Text, "\n", " / ")), host and host.Name or "?", face, along, up,
				gui and gui.SizingMode.Name or "-", canvasW, canvasH, boxH, glyphStuds,
				tostring(d.TextScaled), gui and tostring(gui.AlwaysOnTop) or "-",
				gui and gui.MaxDistance or 0))
		elseif d:IsA("Decal") or d:IsA("Texture") then
			table.insert(textFindings, string.format("%s: %s %s on %s (%s)", id, d.ClassName, d.Name,
				host and host.Name or "?", tostring(d.Texture)))
		end
	end
end

--------------------------------------------------------------------------------
-- One posed viewmodel, measured
--------------------------------------------------------------------------------

local function measurePose(id, pose, vm, aimed, lines, problems, counters, light)
	local arms, sights, gunParts = {}, {}, {}
	local armSet = {}
	if vm.arms and type(vm.arms.parts) == "table" then
		for _, part in ipairs(vm.arms.parts) do
			armSet[part] = true
		end
	end
	local armsModel = vm.model:FindFirstChild("Arms")
	for _, d in ipairs(vm.model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 and d.LocalTransparencyModifier < 1 then
			if armSet[d] or ARM[d.Name] or (armsModel and d:IsDescendantOf(armsModel)) then
				table.insert(arms, d)
			elseif SIGHTS[d.Name] then
				table.insert(sights, d)
			elseif d.Transparency < 0.5 and not string.find(d.Name, "Reticle", 1, true) then
				table.insert(gunParts, d)
			end
		end
	end
	if #arms == 0 then
		table.insert(problems, string.format("%s %s: found no arm parts to test (API changed?)", id, pose.name))
	end

	local centre = firstArm(arms, eye.Position, eye.LookVector * 60)
	local gunCentre = firstArm(gunParts, eye.Position, eye.LookVector * 60)
	local gunRing = 0
	for step = 0, 23 do
		local dir = (eye * CFrame.Angles(0, 0, step / 24 * math.pi * 2) * CFrame.Angles(math.rad(1), 0, 0)).LookVector
		if firstArm(gunParts, eye.Position, dir * 60) then
			gunRing += 1
		end
	end
	local ringText = {}
	local ringBlocked = 0
	for _, degrees in ipairs({ 1, 2.5 }) do
		local hits = 0
		for step = 0, 23 do
			local dir = (eye * CFrame.Angles(0, 0, step / 24 * math.pi * 2) * CFrame.Angles(math.rad(degrees), 0, 0)).LookVector
			if firstArm(arms, eye.Position, dir * 60) then
				hits += 1
			end
		end
		ringBlocked += hits
		table.insert(ringText, string.format("%.1f°:%d/24", degrees, hits))
	end
	local hidden = {}
	if aimed then
		for _, sight in ipairs(sights) do
			local target = SIGHTS[sight.Name] == "top" and (sight.CFrame * Vector3.new(0, sight.Size.Y / 2, 0)) or sight.Position
			local offAxis = eye:PointToObjectSpace(target)
			if -offAxis.Z > 0 and math.abs(offAxis.X / offAxis.Z) < 0.02 and math.abs(offAxis.Y / offAxis.Z) < 0.02 then
				local blocker = firstArm(arms, eye.Position, (target - eye.Position) * 0.999)
				if blocker then
					table.insert(hidden, sight.Name .. " by " .. blocker.Name)
				end
			end
		end
	end
	local tanV = math.tan(math.rad(pose.fov / 2))
	local tanH = tanV * ASPECT
	local covered, middle, middleTotal = 0, 0, 0
	-- The 32x18 screen grid is 576 rays against every arm part, by far the most expensive thing here.
	-- The repeat sweeps (the planted regression, the second avatar) only need the sights and the
	-- crosshair, so they skip it rather than triple the run's length for a number nobody reads twice.
	for gx = 0, (light and -1 or 31) do
		for gy = 0, 17 do
			local sx, sy = (gx + 0.5) / 32 * 2 - 1, (gy + 0.5) / 18 * 2 - 1
			local dir = eye:VectorToWorldSpace(Vector3.new(sx * tanH, sy * tanV, -1))
			local hit = firstArm(arms, eye.Position, dir * 60)
			if hit then
				covered += 1
			end
			if math.abs(sx) < 1 / 3 and math.abs(sy) < 1 / 3 then
				middleTotal += 1
				if hit then
					middle += 1
				end
			end
		end
	end

	-- How many of the blockers are FINGERS: the regression is a finger specifically, so a count that
	-- mixes a forearm in would not say whether the 18 September fix held.
	local fingerBlocks = 0
	for _, text in ipairs(hidden) do
		if string.find(text, "Finger", 1, true) then
			fingerBlocks += 1
		end
	end
	if centre and string.find(centre.Name, "Finger", 1, true) then
		fingerBlocks += 1
	end

	counters.hidden += #hidden
	counters.fingerBlocks += fingerBlocks
	counters.crosshair += (centre and 1 or 0)
	counters.poses += 1

	-- The arm's own joints, once per gun (the pose does not change which bones exist, but it does
	-- change how far they are stretched, so the worst pose is the one that matters).
	local worstElbow, worstWrist = 0, 0
	if vm.arms and vm.arms.sides then
		for _, side in ipairs({ 1, -1 }) do
			local gaps = jointGaps(vm.arms.sides[side])
			if gaps then
				worstElbow = math.max(worstElbow, gaps.elbow)
				worstWrist = math.max(worstWrist, gaps.wrist or 0)
				-- Said once, for the first arm that has anything to say: the same rig is used for every
				-- gun, so repeating it 62 times would only bury it.
				for which, e in pairs({ upper = gaps.upperError, lower = gaps.lowerError }) do
					if e and not counters.boneSaid and (math.abs(e.lengthError) > 0.002 or e.direction > 0.5) then
						counters.boneSaid = true
						say("#11 why: the %s arm's two rig attachments are %.4f studs OFF ITS CENTRE LINE, so after scaling its joint-to-joint vector is %.4f studs long instead of %.4f (%.4f out) and points %.2f degrees away from the part's own axis; the Y scale that would make the joints meet is %s instead of %.4f",
							which, e.sideways, e.wanted + e.lengthError, e.wanted, e.lengthError, e.direction,
							e.scaleFixed and string.format("%.4f", e.scaleFixed) or "impossible (the bone is shorter than its own sideways offset)", e.scaleNow)
					end
				end
			end
		end
	end
	if worstElbow > counters.worstElbow then
		counters.worstElbow, counters.worstElbowAt = worstElbow, id .. " " .. pose.name
	end
	if worstWrist > counters.worstWrist then
		counters.worstWrist, counters.worstWristAt = worstWrist, id .. " " .. pose.name
	end

	table.insert(lines, string.format("%s: crosshair %s, rings %s, gun %s ring1 %d/24, sights %s, screen %d%% (middle third %d%%), joints elbow %.3f wrist %.3f",
		pose.name, centre and ("BLOCKED by " .. centre.Name) or "clear", table.concat(ringText, " "),
		gunCentre and ("ON " .. gunCentre.Name) or "off", gunRing,
		aimed and (#hidden > 0 and ("HIDDEN: " .. table.concat(hidden, ", ")) or (#sights > 0 and "clear" or "none found")) or "-",
		math.floor(covered / (32 * 18) * 100 + 0.5), middleTotal > 0 and math.floor(middle / middleTotal * 100 + 0.5) or 0,
		worstElbow, worstWrist))

	if centre and (aimed or not pose.state.clip) then
		table.insert(problems, string.format("%s %s: the %s covers the crosshair", id, pose.name, centre.Name))
	end
	if aimed and pose.state.clip and gunCentre then
		table.insert(problems, string.format("%s %s: the gun's %s swings over the crosshair mid-clip (ring1 %d/24)", id, pose.name, gunCentre.Name, gunRing))
	end
	if #hidden > 0 then
		table.insert(problems, string.format("%s %s: sights hidden: %s", id, pose.name, table.concat(hidden, ", ")))
	end
	if aimed and ringBlocked > 0 then
		table.insert(problems, string.format("%s %s: an arm reaches within 2.5 degrees of the crosshair (%s)", id, pose.name, table.concat(ringText, " ")))
	end
	if worstElbow > JOINT_GAP or worstWrist > JOINT_GAP then
		table.insert(problems, string.format("%s %s: arm joints apart -- elbow %.3f, wrist %.3f studs", id, pose.name, worstElbow, worstWrist))
	end
end

--------------------------------------------------------------------------------
-- A whole sweep of every gun in every pose, with a given finger threshold
--------------------------------------------------------------------------------

-- `subset` limits the guns (the repeat sweeps do not need all 62 to show a difference) and `quiet`
-- and `light` cut the per-gun line and the screen-coverage grid.
local function sweep(label, fingerMinClose, avatar, quiet, subset)
	local hadSeam = Viewmodel.FingerMinCloseForTest ~= nil
	if fingerMinClose ~= nil then
		Viewmodel.FingerMinCloseForTest = fingerMinClose
	end
	local problems = {}
	local counters = { hidden = 0, fingerBlocks = 0, crosshair = 0, poses = 0, worstElbow = 0, worstWrist = 0,
		worstElbowAt = "-", worstWristAt = "-", armColour = nil, armParts = 0 }
	local list = subset or ids
	for _, id in ipairs(list) do
		local def = WeaponData.Get(id)
		local lines = {}
		for _, pose in ipairs(POSES) do
			local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
			if not ok or not vm then
				table.insert(problems, string.format("%s: Viewmodel.new failed: %s", id, tostring(vm)))
				break
			end
			vm.model.Parent = folder
			local state = table.clone(pose.state)
			state.magSize = def.magSize
			local posed, err = pcall(vm.Pose, vm, eye, state)
			local aimed = posed and (vm.aim or state.aim or 0) >= 0.5
			if not posed then
				table.insert(problems, string.format("%s %s: Pose failed: %s", id, pose.name, tostring(err)))
			else
				sweepText(id, vm.model)
				measurePose(id, pose, vm, aimed, lines, problems, counters, subset ~= nil)
				-- The skin the arms actually wear, taken from a part that is not a finger (fingers copy
				-- the hand's colour, so they would agree even if the arm did not).
				if not counters.armColour and vm.arms and vm.arms.sides and vm.arms.sides[1] then
					local hand = vm.arms.sides[1].hand
					if hand then
						counters.armColour = hand.Color
					end
				end
				if vm.arms and type(vm.arms.parts) == "table" then
					counters.armParts = math.max(counters.armParts, #vm.arms.parts)
				end
			end
			vm:Destroy()
		end
		if not quiet then
			say("%-20s %s", id, table.concat(lines, " | "))
		end
	end
	if fingerMinClose ~= nil and hadSeam then
		Viewmodel.FingerMinCloseForTest = false
	end
	counters.problems = problems
	say("%s: %d poses over %d guns -- %d sights hidden (%d by a finger), %d crosshairs blocked, %d problems; worst elbow gap %.3f (%s), worst wrist gap %.3f (%s)",
		label, counters.poses, #list, counters.hidden, counters.fingerBlocks, counters.crosshair, #problems,
		counters.worstElbow, counters.worstElbowAt, counters.worstWrist, counters.worstWristAt)
	return counters
end

--------------------------------------------------------------------------------
-- The run
--------------------------------------------------------------------------------

-- The repeat sweeps run over a spread of silhouettes rather than all 62 guns: one of each shape is
-- enough to show a difference, and three full sweeps would not fit the run.
local SUBSET = {}
do
	local byStyle = {}
	for _, id in ipairs(ids) do
		local style = (WeaponData.Get(id) or {}).style or "rifle"
		if not byStyle[style] then
			byStyle[style] = true
			table.insert(SUBSET, id)
		end
	end
	table.sort(SUBSET)
end

local SEAM = Viewmodel.FingerMinCloseForTest ~= nil
say("finger threshold seam present: %s (without it the planted regression cannot be reached and the finger result is UNPROVEN)", tostring(SEAM))

local shipped = sweep("SHIPPED", nil, avatarA)

-- THE PLANTED FAULT: the 18 September regression put back. A finger with nothing to grip stands
-- straight forward along the barrel again. This must be WORSE than the shipped run or the shipped
-- run's zero means nothing.
local planted = nil
if SEAM then
	planted = sweep("PLANTED (fingers forced open)", 0, avatarA, true, SUBSET)
	local caught = planted.hidden > shipped.hidden or planted.fingerBlocks > shipped.fingerBlocks
		or planted.crosshair > shipped.crosshair
	say("planted fault %-40s %s (shipped: %d hidden / %d finger / %d crosshair; planted: %d / %d / %d)",
		"a finger forced open covers the sights", caught and "CAUGHT" or "MISSED -- THIS CHECK PROVES NOTHING",
		shipped.hidden, shipped.fingerBlocks, shipped.crosshair, planted.hidden, planted.fingerBlocks, planted.crosshair)
else
	say("planted fault %-40s MISSED -- no seam in this build", "a finger forced open covers the sights")
end

-- #44: the arms wear the player's own avatar. Measured, then shown to move when the avatar changes.
if avatarA and avatarB then
	local other = sweep("AVATAR B", nil, avatarB, true, SUBSET)
	local function near(a, b)
		return a and b and math.abs(a.R - b.R) < 0.02 and math.abs(a.G - b.G) < 0.02 and math.abs(a.B - b.B) < 0.02
	end
	local wearsA = near(shipped.armColour, SKIN_A)
	local wearsB = near(other.armColour, SKIN_B)
	say("#44 arms wear the avatar: avatar A asked for (%d,%d,%d) and the hand is %s; avatar B asked for (%d,%d,%d) and the hand is %s; %d arm parts",
		SKIN_A.R * 255, SKIN_A.G * 255, SKIN_A.B * 255,
		shipped.armColour and string.format("(%d,%d,%d)", shipped.armColour.R * 255, shipped.armColour.G * 255, shipped.armColour.B * 255) or "none",
		SKIN_B.R * 255, SKIN_B.G * 255, SKIN_B.B * 255,
		other.armColour and string.format("(%d,%d,%d)", other.armColour.R * 255, other.armColour.G * 255, other.armColour.B * 255) or "none",
		shipped.armParts)
	say("planted fault %-40s %s", "a different avatar changes the arms",
		(wearsA and wearsB) and "CAUGHT (both avatars came back as themselves)" or "MISSED -- THIS CHECK PROVES NOTHING")
else
	say("planted fault %-40s MISSED -- no avatar available here", "a different avatar changes the arms")
end

-- #72: every piece of lettering on every gun.
say("--- #72 stray lettering: %d text-bearing instances over %d guns ---", #textFindings, #ids)
for _, text in ipairs(textFindings) do
	say("  TEXT %s", text)
end

-- #87: the grenade launcher's reach, through Ballistics itself.
do
	local spec = Ballistics.Rounds and Ballistics.Rounds.grenade
	if spec then
		local gravity = workspace.Gravity
		local EYE = 4.6
		local function flatRange(s)
			-- Fired level from eye height: where the round meets the ground.
			local t, step, last = 0, 0.002, 0
			while t < (s.maxTime or 5) do
				local position = Ballistics.RoundState(s, Vector3.zero, Vector3.new(0, 0, -1), gravity, t)
				if -position.Y >= EYE then
					return last
				end
				last = -position.Z
				t += step
			end
			return last
		end
		local function bestRange(s)
			local best = 0
			for degrees = 5, 60, 1 do
				local direction = Vector3.new(0, math.sin(math.rad(degrees)), -math.cos(math.rad(degrees)))
				local t, step, flat = 0, 0.004, 0
				while t < (s.maxTime or 5) do
					local position = Ballistics.RoundState(s, Vector3.zero, direction, gravity, t)
					if position.Y < -EYE then
						break
					end
					flat = math.sqrt(position.X * position.X + position.Z * position.Z)
					t += step
				end
				best = math.max(best, flat)
			end
			return best
		end
		say("#87 grenade round NOW: speed %.0f, gravityScale %.2f, maxTime %.1f at workspace.Gravity %.1f -> level shot from eye height lands at %.1f studs, best arc reaches %.0f studs",
			spec.speed, spec.gravityScale, spec.maxTime or 5, gravity, flatRange(spec), bestRange(spec))
		for _, candidate in ipairs({ { 180, 0.36 }, { 190, 0.45 }, { 140, 0.30 }, { 200, 0.34 } }) do
			local trial = table.clone(spec)
			trial.speed, trial.maxSpeed, trial.gravityScale = candidate[1], candidate[1], candidate[2]
			say("#87 candidate speed %.0f gravityScale %.2f -> level shot lands at %.1f studs, best arc %.0f studs",
				candidate[1], candidate[2], flatRange(trial), bestRange(trial))
		end
	else
		say("#87 NOT MEASURED: Ballistics.Rounds.grenade is missing")
	end
end

-- Oliver: "i also cant see any animations on other players like sliding." The slide IS published --
-- MatchService:858 sets the `Parkour` attribute and every client poses any body in workspace from it
-- (MovementClient:1150, :1206) -- and Oliver HEARS other people slide, which is positive proof the
-- attribute arrives, because the cue is fired from inside that same attribute handler and only for
-- bodies that are not his own. So the attribute is not the fault; the POSE is what does not show.
-- This measures whether the game's own pose actually moves a body, and on what kind of rig.
local poseReport = {}
do
	local Parkour = require(Shared:WaitForChild("Parkour"))
	local rig = makeAvatar(SKIN_A)
	if not rig then
		say("slide pose: NO RIG could be built here -- not measured")
	else
		rig.Parent = folder
		local joints = Parkour.PoseJoints(rig)
		if not joints then
			say("slide pose: Parkour.PoseJoints found no usable joints on this rig -- a body like this CANNOT be posed")
		else
			local classes, names = {}, {}
			for name, joint in pairs(joints) do
				table.insert(names, name)
				classes[joint.ClassName] = (classes[joint.ClassName] or 0) + 1
			end
			table.sort(names)
			local classText = {}
			for class, count in pairs(classes) do
				table.insert(classText, string.format("%d %s", count, class))
			end
			-- Which way each joint is facing before and after, so "the pose did nothing" is a number.
			local function snapshot()
				local shot = {}
				for name, joint in pairs(joints) do
					shot[name] = joint.Transform
				end
				return shot
			end
			local function biggestTurn(before, after)
				local worst, worstName = 0, "-"
				for name, frame in pairs(before) do
					local dot = math.clamp(frame.LookVector:Dot(after[name].LookVector), -1, 1)
					local turn = math.deg(math.acos(dot))
					if turn > worst then
						worst, worstName = turn, name
					end
				end
				return worst, worstName
			end
			for _, kind in ipairs({ "slide", "mantle", "vault" }) do
				local before = snapshot()
				Parkour.ApplyPose(joints, kind, 0)
				local zeroTurn = biggestTurn(before, snapshot())
				Parkour.ApplyPose(joints, kind, 1)
				local fullTurn, fullJoint = biggestTurn(before, snapshot())
				table.insert(poseReport, { kind = kind, zero = zeroTurn, full = fullTurn, joint = fullJoint })
				say("slide pose: \"%s\" at weight 1 turns %s by %.1f degrees (at weight 0: %.2f degrees)",
					kind, fullJoint, fullTurn, zeroTurn)
				Parkour.ApplyPose(joints, kind, 0)
			end
			say("slide pose: this rig's %d pose joints are %s (%s)", #names, table.concat(classText, ", "), table.concat(names, " "))
			say("slide pose: SCOPE -- a rig built by CreateHumanoidModelFromDescription here may not be jointed the way a live player's character is (MovementClient's own comment says bots come out as AnimationConstraint rigs), so this says the pose moves a body of THIS kind, not that it moves Oliver's.")
			local worked = #poseReport > 0 and poseReport[1].full > 5 and poseReport[1].zero < 0.01
			say("planted fault %-40s %s", "weight 0 must move nothing",
				worked and "CAUGHT (weight 0 moved nothing, weight 1 moved the body)"
					or "MISSED -- THIS CHECK PROVES NOTHING")
		end
		rig:Destroy()
	end
end

-- Sprint, unlike the slide, publishes NOTHING: there is no `Sprinting` attribute anywhere in the
-- project, so no other client can know you are sprinting. Counted here so the gap is a number.
do
	local published = { slide = "Parkour (MatchService:858)", mantle = "Parkour (MovementService:661)",
		vault = "Parkour (MovementService:753)", crouch = "Crouching (MatchService:699)", sprint = false }
	local have, missing = {}, {}
	for name, where in pairs(published) do
		if where then
			table.insert(have, name)
		else
			table.insert(missing, name)
		end
	end
	table.sort(have)
	table.sort(missing)
	say("remote movement states: %d of %d reach another client (%s); NOT published: %s",
		#have, #have + #missing, table.concat(have, ", "), #missing > 0 and table.concat(missing, ", ") or "none")
end

say("guns %d; problems %d", #ids, #shipped.problems)
for _, text in ipairs(shipped.problems) do
	say("  PROBLEM %s", text)
end

if not IN_GALLERY then
	folder:Destroy()
	say("done")
	return {}
end

--------------------------------------------------------------------------------
-- Renders (gallery only): the sight picture, shipped against the regression
--------------------------------------------------------------------------------

folder:Destroy()

Lighting.ClockTime = 14
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.1

local VIEW = Vector3.new(0, 5200, 0)

local function scene(parent)
	local function block(size, position, colour, material)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.Position = position
		part.Color = colour
		part.Material = material or Enum.Material.SmoothPlastic
		part.Parent = parent
		return part
	end
	block(Vector3.new(80, 1, 120), VIEW + Vector3.new(0, -5.5, -40), Color3.fromRGB(116, 112, 104), Enum.Material.Concrete)
	block(Vector3.new(80, 40, 1), VIEW + Vector3.new(0, 10, -60), Color3.fromRGB(172, 170, 164), Enum.Material.Plaster)
	block(Vector3.new(4, 4, 0.2), VIEW + Vector3.new(0, 0, -59.4), Color3.fromRGB(210, 60, 50))
	block(Vector3.new(2, 2, 0.2), VIEW + Vector3.new(0, 0, -59.2), Color3.fromRGB(240, 236, 226))
end

-- Which guns to photograph: whichever the shipped run found worst, and the two Oliver aims most.
local SHOW = { "CrocodiloRifle", "LarilaSniper", "TralalaShotgun", "SahurPistol" }

local function frameCheck(name, camera, target)
	local point = camera.CFrame:PointToObjectSpace(target)
	local forward = -point.Z
	local off = math.deg(math.atan2(math.sqrt(point.X * point.X + point.Y * point.Y), math.max(forward, 1e-6)))
	say("view %-30s target %s: %.2f studs ahead, %.1f deg off centre (fov %.0f)", name,
		(forward > 0 and off < camera.FieldOfView / 2) and "IN FRAME" or "NOT IN FRAME", forward, off, camera.FieldOfView)
end

local views = {
	{
		name = "warmup",
		setup = function(parent, camera)
			scene(parent)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(VIEW)
		end,
	},
}

for _, id in ipairs(SHOW) do
	for _, case in ipairs({ { "shipped", false }, { "regression", 0 } }) do
		table.insert(views, {
			name = id .. "_ads_" .. case[1],
			settle = 1.4,
			hold = 2,
			setup = function(parent, camera)
				scene(parent)
				if SEAM then
					Viewmodel.FingerMinCloseForTest = case[2]
				end
				local def = WeaponData.Get(id)
				local vm = Viewmodel.new(def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatarA })
				vm.model.Parent = parent
				local at = CFrame.new(VIEW)
				vm:Pose(at, { aim = 1, magSize = def.magSize })
				camera.FieldOfView = 70 * 0.64
				camera.CFrame = at
				if SEAM then
					Viewmodel.FingerMinCloseForTest = false
				end
				-- The target is what the player is aiming AT: the plate on the far wall, which the
				-- sights should be lined up on and a hand should never cover.
				frameCheck(id .. "_ads_" .. case[1], camera, VIEW + Vector3.new(0, 0, -59.2))
			end,
		})
	end
end

-- The slide pose, photographed: an unposed body beside a posed one, so "I can't see other players
-- sliding" has a picture on both sides of it.
do
	local Parkour = require(Shared:WaitForChild("Parkour"))
	for _, kind in ipairs({ "slide", "vault" }) do
		table.insert(views, {
			name = "pose_" .. kind,
			settle = 1.4,
			hold = 2,
			setup = function(parent, camera)
				scene(parent)
				local made = {}
				for index, weight in ipairs({ 0, 1 }) do
					local rig = makeAvatar(index == 1 and SKIN_A or SKIN_B)
					if rig then
						rig.Parent = parent
						rig:PivotTo(CFrame.new(VIEW + Vector3.new((index - 1.5) * 5, -2.5, -14)) * CFrame.Angles(0, math.pi * 0.75, 0))
						local joints = Parkour.PoseJoints(rig)
						if joints then
							Parkour.ApplyPose(joints, kind, weight)
						end
						table.insert(made, rig)
					end
				end
				camera.FieldOfView = 55
				camera.CFrame = CFrame.lookAt(VIEW + Vector3.new(0, 1.5, -4), VIEW + Vector3.new(0, -1.5, -14))
				frameCheck("pose_" .. kind, camera, VIEW + Vector3.new(0, -1.5, -14))
			end,
		})
	end
end

say("gallery: %d views", #views)
return views
