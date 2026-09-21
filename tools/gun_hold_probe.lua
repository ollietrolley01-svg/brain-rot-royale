-- Is there anything under the palm at a gun's hand keypoints, and is it a shape a hand can close on?
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_hold_probe.lua -WaitSeconds 240
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- Oliver: "the hand models in fps don't look like they're actually holding some of the guns". Two things
-- can cause that: the rig (how the hand is sized and posed) and the gun (whether the keypoint the hand is
-- sent to has a handle under it). claude-f0's tools/hand_grip_probe.lua measures the posed rig; this
-- measures the gun as built, with no viewmodel involved, so a fault here is a builder's to fix.
--
-- The keypoint is NOT on the grip's surface: it is where the hand's middle goes. Viewmodel lands the
-- palm's inner face HAND_SINK (0.055 studs, 14.5 mm) past the keypoint along the palm normal, whatever
-- the hand's thickness. So a correct keypoint floats about 14.5 mm off the surface it faces, and what
-- matters is the difference:
--
--   palm gap = (distance from the keypoint to the first surface under the palm) - 14.5 mm
--
-- 0 means the palm rests exactly on the handle, positive means it floats, negative means it presses in.
-- The palm frame the gun gives has the fingers along -Z and the back of the hand up (+Y), so the palm
-- looks along its own -Y: that is the direction marched here, not "nearest part in any direction", which
-- would happily measure a magazine off to one side.
--
-- Across the contact point it then measures how much solid material there is along the palm's X (across
-- the hand) and Y (palm to back) axes: the handle's cross-section, which is what the fingers close
-- around. A 6 mm rod and a 90 mm slab are both things a hand can't hold.
--
-- Everything is analytic (boxes, cylinders and balls each as their own shape). workspace:Raycast pads
-- millimetre-scale parts by several millimetres and would land the palm on air.
--
-- Keypoints are model-space CFrames against the design origin (the bore above the trigger), and a built
-- model's PIVOT is that origin -- GunModels sets receiver.PivotOffset = receiver.CFrame:Inverse() for
-- exactly this -- so model:GetPivot() * keypoint is the keypoint in the world, wherever the model sits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local creativeModule = Shared:FindFirstChild("GunModelsCreative")
local GunModelsCreative = creativeModule and require(creativeModule) or { Builders = {} }

local MM = GunModels.StudsPerMillimetre
-- Viewmodel's HAND_SINK, in millimetres: how far past the keypoint the palm's inner face lands.
local PALM_SINK_MM = 14.5
-- claude-f0's thresholds, so the two probes' numbers read together: a palm floating more than this is
-- not holding, and a handle outside this band is not something a hand closes on.
local FLOAT_MM = 3
local BURIED_MM = 8
local GRIP_MIN, GRIP_MAX = 18, 60
-- How far to look under the palm before calling it open air, and how finely.
local REACH_MM = 70
local STEP_MM = 0.25
-- A support hand this close to the firing hand is cupping it, the way both hands go on a pistol, and has
-- no business being on the gun's own surface.
local CUPPING_MM = 90

local function say(fmt, ...)
	print(string.format("[BRR_Hold] " .. fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "BRR_HoldProbe"
folder.Parent = workspace

-- Only a Part has a Shape; a WedgePart or MeshPart would throw on reading it, and both are measured as
-- their box (a wedge reads slightly fatter than it is).
local function shapeOf(part)
	if part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			return "ball"
		elseif part.Shape == Enum.PartType.Cylinder then
			return "cylinder"
		end
	end
	return "box"
end

local function inside(part, point)
	local at = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	local shape = shapeOf(part)
	if shape == "ball" then
		return at.Magnitude <= math.min(half.X, half.Y, half.Z)
	elseif shape == "cylinder" then
		return math.abs(at.X) <= half.X and Vector2.new(at.Y, at.Z).Magnitude <= math.min(half.Y, half.Z)
	end
	return math.abs(at.X) <= half.X and math.abs(at.Y) <= half.Y and math.abs(at.Z) <= half.Z
end

local function firstSolid(parts, from, direction, reachMM)
	local steps = math.floor(reachMM / STEP_MM)
	for step = 0, steps do
		local point = from + direction * (step * STEP_MM * MM)
		for _, part in ipairs(parts) do
			if inside(part, point) then
				return step * STEP_MM, part, point
			end
		end
	end
	return nil
end

-- A palm is a face, not a point. One ray down its normal can slip past the very handle it is supposed to
-- be resting on when that normal is tilted -- on CameloLMG a single ray missed the handguard entirely and
-- reported 39 mm to something far beyond, where the handguard itself was 15 mm away. So the palm's
-- footprint is sampled across its width and its finger direction, and the NEAREST of those rays is the
-- one that counts: the first part of the palm to touch something is what the hand rests on.
local PALM_HALF_ACROSS, PALM_HALF_ALONG = 18, 22
local function palmReach(parts, frame, reachMM)
	local best, bestPart, bestPoint = nil, nil, nil
	for _, across in ipairs({ 0, -PALM_HALF_ACROSS, PALM_HALF_ACROSS }) do
		for _, along in ipairs({ 0, -PALM_HALF_ALONG, PALM_HALF_ALONG }) do
			local from = frame.Position + frame.RightVector * (across * MM) + frame.LookVector * (along * MM)
			local reach, part, point = firstSolid(parts, from, -frame.UpVector, reachMM)
			if reach and (not best or reach < best) then
				best, bestPart, bestPoint = reach, part, point
			end
		end
	end
	return best, bestPart, bestPoint
end

-- How much solid material lies either side of `point` along `axis`, in millimetres. Stops at the first
-- gap, so a separate part further out isn't counted.
local function spanAlong(parts, point, axis)
	local total = 0
	for _, direction in ipairs({ axis, -axis }) do
		local step = 0
		while step * STEP_MM < GRIP_MAX * 2 do
			step += 1
			local probe = point + direction * (step * STEP_MM * MM)
			local hit = false
			for _, part in ipairs(parts) do
				if inside(part, probe) then
					hit = true
					break
				end
			end
			if not hit then
				break
			end
		end
		total += (step - 1) * STEP_MM
	end
	return total
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local KEYPOINTS = { "KP_GripHand", "KP_SupportHand" }

local guns, problems, floating, unholdable = 0, 0, 0, 0
local rows = {}

for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if ok and model then
		guns += 1
		model.Parent = folder
		local origin = model:GetPivot()
		local parts = {}
		for _, part in ipairs(model:GetDescendants()) do
			-- Glass, sight lenses and the aiming dot are not things to hold.
			if part:IsA("BasePart") and part.Transparency < 0.5 then
				table.insert(parts, part)
			end
		end
		local gripKey, supportKey = model:GetAttribute("KP_GripHand"), model:GetAttribute("KP_SupportHand")
		local cupping = false
		if typeof(gripKey) == "CFrame" and typeof(supportKey) == "CFrame" then
			cupping = (gripKey.Position - supportKey.Position).Magnitude / MM <= CUPPING_MM
		end
		local notes, found = {}, {}
		for _, key in ipairs(KEYPOINTS) do
			local keypoint = model:GetAttribute(key)
			if typeof(keypoint) == "CFrame" then
				local frame = origin * keypoint
				-- The palm looks along its own -Y (the back of the hand is +Y).
				local reachMM, part, contact = palmReach(parts, frame, REACH_MM)
				if not reachMM then
					if not (cupping and key == "KP_SupportHand") then
						table.insert(found, string.format("%s: nothing under the palm within %d mm", key, REACH_MM))
						floating += 1
					else
						table.insert(notes, key:sub(4) .. " cups the firing hand")
					end
				else
					local gap = reachMM - PALM_SINK_MM
					-- The handle's cross-section, measured on the assembled gun rather than from one
					-- part's Size. Measuring at the contact point reads a tangent: touch a 31 mm round
					-- grip off-centre and the span across it comes out a third of that. So the material
					-- is followed inward along the palm normal to its far side, and the spans are taken
					-- through the MIDDLE of it. The longest of the three is the handle's length -- down a
					-- grip, along a barrel -- so the other two are what the fingers close around.
					local depth = spanAlong(parts, contact - frame.UpVector * (0.5 * MM), frame.UpVector)
					local core = contact - frame.UpVector * (math.max(depth / 2, 1) * MM)
					local spans = {
						spanAlong(parts, core, frame.RightVector),
						spanAlong(parts, core, frame.UpVector),
						spanAlong(parts, core, frame.LookVector),
					}
					table.sort(spans)
					local across, deep = spans[1], spans[2]
					table.insert(notes, string.format("%s gap %+.1fmm on %s (%.0f x %.0f mm section)",
						key:sub(4), gap, part.Name, across, deep))
					if not (cupping and key == "KP_SupportHand") then
						if gap > FLOAT_MM then
							floating += 1
							table.insert(found, string.format("%s: the palm floats %.1f mm off %s -- move the keypoint %.1f mm along its own -Y",
								key, gap, part.Name, gap))
						elseif gap < -BURIED_MM then
							-- How far back out of the material the keypoint has to come: the hand's middle
							-- is inside the gun, so say by how much rather than only that it is.
							local step = 0
							while step * STEP_MM < REACH_MM do
								local probe = frame.Position + frame.UpVector * (step * STEP_MM * MM)
								local hit = false
								for _, candidate in ipairs(parts) do
									if inside(candidate, probe) then
										hit = true
										break
									end
								end
								if not hit then
									break
								end
								step += 1
							end
							local outMM = step * STEP_MM
							table.insert(found, string.format("%s: the palm sinks %.1f mm into %s -- the keypoint is %.1f mm inside it; move it %.1f mm along its own +Y",
								key, -gap, part.Name, outMM, outMM - gap))
						end
						-- Judged on the section the fingers close around, not the handle's length.
						if across < GRIP_MIN or deep > GRIP_MAX then
							unholdable += 1
							table.insert(found, string.format("%s: the handle under the palm is %.0f x %.0f mm -- %s",
								key, across, deep, across < GRIP_MIN and "too thin to grip" or "too fat to close a hand round"))
						end
					end
				end
			else
				table.insert(found, key .. " is missing")
			end
		end
		table.insert(rows, string.format("%-24s %-10s %s%s", id, def.style or "?",
			GunModelsCreative.Builders[id] and "[creative] " or "", table.concat(notes, " | ")))
		for _, problem in ipairs(found) do
			problems += 1
			table.insert(rows, string.format("  PROBLEM %-20s %s", id, problem))
		end
		model:Destroy()
	else
		say("%-24s FAILED to build: %s", id, tostring(model))
	end
end

for _, row in ipairs(rows) do
	say("%s", row)
end
folder:Destroy()
say("guns %d; problems %d (palms holding air %d, handles unholdable %d) (want 0)", guns, problems, floating, unholdable)
say("palm lands %.1f mm past the keypoint (Viewmodel's HAND_SINK); floating past %d mm, buried past %d mm, graspable %d-%d mm across",
	PALM_SINK_MM, FLOAT_MM, BURIED_MM, GRIP_MIN, GRIP_MAX)
say("done")
