-- Merged render for this job's two visual items: #7 (potion clip, before/after) and #67 (companion
-- offset, before/after). One gallery.ps1 run instead of two, per the harness's "merge everything you
-- have into it" rule. Each section is otherwise identical to its own standalone file
-- (tools/potion_clip_gallery.lua, tools/companion_offset_gallery.lua), kept separately too for
-- anyone re-running just one later.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/orphan3_render_gallery.lua -OutDir <dir> -Hold 1

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")

local ItemModels = require(Shared:WaitForChild("ItemModels"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionService = require(Modules:WaitForChild("CompanionService"))

Lighting.ClockTime = 14
Lighting.Brightness = 2.2
Lighting.Ambient = Color3.fromRGB(90, 90, 96)
Lighting.OutdoorAmbient = Color3.fromRGB(130, 130, 138)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local views = {}

--------------------------------------------------------------------------------
-- #7 potion clip
--------------------------------------------------------------------------------

do
	local ITEM_HIP = Vector3.new(0.8, -0.85, -1.9)
	local POTION_ORIGIN = Vector3.new(0, 400, 0)
	local TIP = 1 -- held pose: the numeric probe's worst frame for every drink item

	local function currentUseTarget()
		return CFrame.new(-0.6 * TIP, 0.62 * TIP, 1.05 * TIP) * CFrame.Angles(1.15 * TIP, 0, 0.35 * TIP)
	end
	local DRINK_PIVOT_LIFT = 1.4
	local function fixedUseTarget()
		local lift = DRINK_PIVOT_LIFT * TIP
		return CFrame.new(-0.6 * TIP, 0.62 * TIP, 1.05 * TIP)
			* CFrame.new(0, lift, 0) * CFrame.Angles(1.15 * TIP, 0, 0.35 * TIP) * CFrame.new(0, -lift, 0)
	end
	local function buildAt(camera, id, useTarget)
		local model = ItemModels.Build(id, { name = "BRR_PotionClipGallery" })
		local pivot = model:GetPivot()
		local gripPart = model:FindFirstChild("Grip")
		local grip = gripPart and pivot:ToObjectSpace(gripPart.CFrame).Position or Vector3.zero
		local frame = camera.CFrame * CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0) * useTarget * CFrame.new(-grip)
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CFrame = frame * pivot:ToObjectSpace(part.CFrame)
				part.Anchored = true
			end
		end
		return model
	end
	local function eyeMarker(folder)
		local eye = Instance.new("Part")
		eye.Shape = Enum.PartType.Ball
		eye.Size = Vector3.new(0.4, 0.4, 0.4)
		eye.CFrame = CFrame.new(POTION_ORIGIN)
		eye.Color = Color3.fromRGB(255, 90, 90)
		eye.Material = Enum.Material.Neon
		eye.Transparency = 0.35
		eye.CanCollide = false
		eye.Anchored = true
		eye.Parent = folder
	end
	local function stagePotionCamera(camera)
		camera.FieldOfView = 70
		camera.CFrame = CFrame.new(POTION_ORIGIN, POTION_ORIGIN + Vector3.new(0, 0, -1))
	end

	table.insert(views, {
		name = "potion_before_ShieldPotion",
		setup = function(folder, camera)
			stagePotionCamera(camera)
			eyeMarker(folder)
			local model = buildAt(camera, "ShieldPotion", currentUseTarget())
			model.Parent = folder
			note("BEFORE: ShieldPotion held pose, current formula -- measured worst Z +0.636 studs BEHIND the eye (red marker). IN THE BUILT PLACE today.")
		end,
	})
	table.insert(views, {
		name = "potion_after_ShieldPotion",
		setup = function(folder, camera)
			stagePotionCamera(camera)
			eyeMarker(folder)
			local model = buildAt(camera, "ShieldPotion", fixedUseTarget())
			model.Parent = folder
			note("AFTER: ShieldPotion held pose, tip pivot lifted 1.4 studs toward the neck (translation unchanged) -- measured worst Z -0.636 studs, in front of the eye. NOT IN THE BUILT PLACE, design only -- patch to guns tab.")
		end,
	})
	table.insert(views, {
		name = "potion_before_MiniShield",
		setup = function(folder, camera)
			stagePotionCamera(camera)
			eyeMarker(folder)
			local model = buildAt(camera, "MiniShield", currentUseTarget())
			model.Parent = folder
			note("BEFORE: MiniShield held pose -- measured worst Z +0.135 studs behind the eye. IN THE BUILT PLACE today.")
		end,
	})
	table.insert(views, {
		name = "potion_after_MiniShield",
		setup = function(folder, camera)
			stagePotionCamera(camera)
			eyeMarker(folder)
			local model = buildAt(camera, "MiniShield", fixedUseTarget())
			model.Parent = folder
			note("AFTER: MiniShield held pose, same fix -- measured worst Z -1.131 studs. NOT IN THE BUILT PLACE, design only.")
		end,
	})
end

--------------------------------------------------------------------------------
-- #67 companion offset
--------------------------------------------------------------------------------

do
	local SHOULDER_HEIGHT, SHOULDER_SIDE, THIRD_PERSON_DISTANCE = 1.7, 1.9, 9
	local COMPANION_ORIGIN = Vector3.new(0, 400, 40) -- separate stage, clear of the potion rig above
	local def = BrainrotData.Get("Golden Sahur") or BrainrotData.Types[1]

	local function stage(folder)
		local floor = Instance.new("Part")
		floor.Anchored = true
		floor.Size = Vector3.new(80, 1, 80)
		floor.CFrame = CFrame.new(COMPANION_ORIGIN - Vector3.new(0, 0.5, 0))
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
		rig:PivotTo(CFrame.new(COMPANION_ORIGIN))
		for _, part in ipairs(rig:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
		rig.Parent = folder
		return rig
	end

	local function thirdPersonCamera(camera, root, humanoid)
		local look = CFrame.Angles(0, 0, 0)
		local base = root.Position + Vector3.new(0, SHOULDER_HEIGHT, 0) + root.CFrame:VectorToWorldSpace(humanoid and humanoid.CameraOffset or Vector3.zero)
		local shoulder = base + look.RightVector * SHOULDER_SIDE
		local position = shoulder - look.LookVector * THIRD_PERSON_DISTANCE
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(position, position + look.LookVector)
	end

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
end

return views
