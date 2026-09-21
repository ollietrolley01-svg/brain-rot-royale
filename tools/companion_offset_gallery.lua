-- Renders the third-person view with the companion, before (current right-side offset) and after
-- (mirrored left) -- Oliver's #67. Numbers are in tools/companion_offset_probe.lua; this is the
-- render the harness requires alongside them, from the same camera pose both times (the camera
-- formula depends only on the owner's root, never on the companion, so before/after are directly
-- comparable).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/companion_offset_gallery.lua -OutDir <dir> -Hold 1
--
-- Camera: the REAL third-person formula (CombatClient.client.lua:219-259, guns-owned, read only),
-- not aiming, default zoom, level look, open ground.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")

local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionService = require(Modules:WaitForChild("CompanionService"))

local SHOULDER_HEIGHT, SHOULDER_SIDE, THIRD_PERSON_DISTANCE = 1.7, 1.9, 9
local ORIGIN = Vector3.new(0, 400, 0)
local def = BrainrotData.Get("Golden Sahur") or BrainrotData.Types[1]

Lighting.ClockTime = 14
Lighting.Brightness = 2.2
Lighting.Ambient = Color3.fromRGB(90, 90, 96)
Lighting.OutdoorAmbient = Color3.fromRGB(130, 130, 138)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function stage(folder)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(80, 1, 80)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(120, 122, 128)
	floor.Material = Enum.Material.Concrete
	floor.Parent = folder
end

local rigTemplate = nil
local function ownerRig(folder)
	if not rigTemplate then
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			rigTemplate = model
		end
	end
	local rig = rigTemplate and rigTemplate:Clone()
	if not rig then
		return nil
	end
	rig.Name = "ProbeOwner"
	rig:PivotTo(CFrame.new(ORIGIN))
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	rig.Parent = folder
	return rig
end

-- Exact replica of updateThirdPersonCamera for a level look, default zoom, not aiming, open ground.
local function thirdPersonCamera(camera, root, humanoid)
	local look = CFrame.Angles(0, 0, 0)
	local base = root.Position + Vector3.new(0, SHOULDER_HEIGHT, 0) + root.CFrame:VectorToWorldSpace(humanoid and humanoid.CameraOffset or Vector3.zero)
	local shoulder = base + look.RightVector * SHOULDER_SIDE
	local position = shoulder - look.LookVector * THIRD_PERSON_DISTANCE
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(position, position + look.LookVector)
end

-- HARNESS rule: every view asserts its target is in frame.
local function assertInFrame(camera, worldPoint, label)
	local half = math.rad(camera.FieldOfView / 2) * 1.15
	local local_ = camera.CFrame:PointToObjectSpace(worldPoint)
	local distance = -local_.Z
	local inFront = distance > 0.05
	local angle = inFront and math.deg(math.atan2(math.sqrt(local_.X ^ 2 + local_.Y ^ 2), distance)) or 180
	local ok = inFront and angle <= math.deg(half)
	note(string.format("frame check %s: distance %.1f, %.1f deg off centre -- %s", label, distance, angle,
		ok and "IN FRAME" or "NOT IN FRAME"))
	return ok
end

local views = {}

table.insert(views, {
	name = "companion_before_right",
	setup = function(folder, camera)
		stage(folder)
		local rig = ownerRig(folder)
		local root = rig and rig:FindFirstChild("HumanoidRootPart")
		local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
		if not root then
			note("companion_before_right: no rig root -- ABORT")
			return
		end
		thirdPersonCamera(camera, root, humanoid)
		local owner = { isBot = true, character = rig }
		pcall(CompanionService.AttachBot, owner, def)
		local model = CompanionService.ModelOf(owner)
		if model then
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			assertInFrame(camera, model:GetBoundingBox().Position, "companion_before_right/companion")
		else
			note("companion_before_right: AttachBot produced no model")
		end
		assertInFrame(camera, root.Position + Vector3.new(0, 1.5, 0), "companion_before_right/owner")
		note("BEFORE (right): FOLLOW_OFFSET = (2.8, 2.6, 2.4), the shipped value -- IN THE BUILT PLACE today")
	end,
})

table.insert(views, {
	name = "companion_after_left",
	setup = function(folder, camera)
		stage(folder)
		local rig = ownerRig(folder)
		local root = rig and rig:FindFirstChild("HumanoidRootPart")
		local humanoid = rig and rig:FindFirstChildOfClass("Humanoid")
		if not root then
			note("companion_after_left: no rig root -- ABORT")
			return
		end
		thirdPersonCamera(camera, root, humanoid)
		local model = BrainrotModels.Build(def, {
			scale = 0.55,
			anchored = true,
			rig = true,
			cframe = root.CFrame * CFrame.new(-2.8, 2.6, 2.4), -- proposed fix: X mirrored
		})
		if model then
			model.Parent = folder
			assertInFrame(camera, model:GetBoundingBox().Position, "companion_after_left/companion")
		else
			note("companion_after_left: build failed")
		end
		assertInFrame(camera, root.Position + Vector3.new(0, 1.5, 0), "companion_after_left/owner")
		note("AFTER (left): proposed FOLLOW_OFFSET = (-2.8, 2.6, 2.4) -- NOT IN THE BUILT PLACE, design only")
	end,
})

return views
