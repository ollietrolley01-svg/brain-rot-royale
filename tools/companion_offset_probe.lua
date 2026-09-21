-- Measures how much of the third-person camera's frame the companion occupies, before (the current
-- right-side FOLLOW_OFFSET) and after (mirrored to the left) -- Oliver's #67: "move the companion to
-- the characters left side so it doesn't block the third person view."
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/companion_offset_probe.lua
--
-- Replicates the REAL third-person camera (StarterPlayerScripts/CombatClient.client.lua:219-259,
-- guns-owned, read only): not aiming, default zoom, level look (lookYaw=lookPitch=0), no occlusion
-- (open stage, so clearPoint is a no-op) --
--   base = root.Position + (0, SHOULDER_HEIGHT=1.7, 0)
--   shoulder = base + RightVector * SHOULDER_SIDE(1.9)
--   position = shoulder - LookVector * THIRD_PERSON_DISTANCE(9)
--   camera.CFrame = CFrame.lookAt(position, position + LookVector)
-- FOV 70 (Settings.lua's FieldOfView default), viewport pinned to 1920x1080 for a reproducible area.
--
-- "Before" goes through the REAL public path -- CompanionService.AttachBot + ModelOf -- so the
-- measured geometry (crown, glow, health bar included) is exactly what a match would build, at
-- today's FOLLOW_OFFSET (right/up/behind). "After" calls the SAME underlying BrainrotModels.Build
-- CompanionService.lua itself calls (same scale, same cframe shape), with only the X mirrored to
-- -2.8 -- the one-line fix -- since that constant isn't landed yet.
--
-- Occupancy = the companion's projected screen-space bounding box area / viewport area, from its
-- world bounding box's 8 corners. This slightly OVERSTATES true silhouette occupancy for a
-- non-box-shaped creature (a bounding box is a superset of its shape), the same conservative
-- direction the potion probe's corner method takes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")

local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionService = require(Modules:WaitForChild("CompanionService"))

local failures, samples = 0, 0
local function out(fmt, ...)
	print("[BRR_Probe] " .. string.format(fmt, ...))
end
local function check(ok, fmt, ...)
	samples += 1
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
end
local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		out("FAIL  section %s threw: %s", name, tostring(err))
	end
end

local SHOULDER_HEIGHT, SHOULDER_SIDE, THIRD_PERSON_DISTANCE = 1.7, 1.9, 9
local VIEWPORT = Vector2.new(1920, 1080)
local FOV = 70

local folder = Instance.new("Folder")
folder.Name = "BRR_CompanionOffsetProbe"
folder.Parent = workspace

local function stageCharacter()
	local model = Instance.new("Model")
	model.Name = "ProbeOwner"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(0, 3, 0) -- facing -Z (identity rotation), matches the real convention
	root.Anchored = true
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.Parent = folder
	return model, root, humanoid
end

-- Exact replica of updateThirdPersonCamera's geometry for a level look, not aiming, default zoom,
-- open ground (clearPoint is the identity when nothing occludes).
local function thirdPersonCamera(root, humanoid)
	local look = CFrame.Angles(0, 0, 0)
	local base = root.Position + Vector3.new(0, SHOULDER_HEIGHT, 0) + root.CFrame:VectorToWorldSpace(humanoid.CameraOffset)
	local shoulder = base + look.RightVector * SHOULDER_SIDE
	local position = shoulder - look.LookVector * THIRD_PERSON_DISTANCE
	local camera = Instance.new("Camera")
	camera.FieldOfView = FOV
	camera.ViewportSize = VIEWPORT
	camera.CFrame = CFrame.lookAt(position, position + look.LookVector)
	return camera
end

-- Screen-space bounding rect (clamped to the viewport) from a model's world bounding box, plus how
-- much of it (if any) falls outside the frame entirely.
local function screenRect(camera, model)
	local cframe, size = model:GetBoundingBox()
	local half = size * 0.5
	local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
	local anyOffFront = false
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local corner = cframe:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				local screen, onScreen = camera:WorldToViewportPoint(corner)
				if not onScreen then
					anyOffFront = true
				end
				minX, maxX = math.min(minX, screen.X), math.max(maxX, screen.X)
				minY, maxY = math.min(minY, screen.Y), math.max(maxY, screen.Y)
			end
		end
	end
	local clampedMinX, clampedMaxX = math.clamp(minX, 0, VIEWPORT.X), math.clamp(maxX, 0, VIEWPORT.X)
	local clampedMinY, clampedMaxY = math.clamp(minY, 0, VIEWPORT.Y), math.clamp(maxY, 0, VIEWPORT.Y)
	return {
		minX = minX, minY = minY, maxX = maxX, maxY = maxY,
		clampedArea = math.max(0, clampedMaxX - clampedMinX) * math.max(0, clampedMaxY - clampedMinY),
		anyOffFront = anyOffFront,
	}
end

local function rectOverlap(a, ax0, ay0, ax1, ay1)
	local ox = math.max(0, math.min(a.maxX, ax1) - math.max(a.minX, ax0))
	local oy = math.max(0, math.min(a.maxY, ay1) - math.max(a.minY, ay0))
	return ox * oy
end

-- HUD's own bottom-left panels (companion_icon_gallery.lua's stand-ins, HudClient's real anchors):
-- health ~[16,296]x[viewportY-96,viewportY], companion panel ~[16,316]x[viewportY-166,viewportY-104],
-- speed pill ~[16,166]x[viewportY-202,viewportY-174]. One bounding rect over all three, generous.
local HUD_RECT = { x0 = 16, y0 = VIEWPORT.Y - 202, x1 = 320, y1 = VIEWPORT.Y }

local viewportArea = VIEWPORT.X * VIEWPORT.Y
local def = BrainrotData.Get("Golden Sahur") or BrainrotData.Types[1]

section("before: current right-side offset, through the real public path", function()
	local owner = { isBot = true }
	local character, root, humanoid = stageCharacter()
	owner.character = character
	local camera = thirdPersonCamera(root, humanoid)

	local ok = pcall(CompanionService.AttachBot, owner, def)
	check(ok, "CompanionService.AttachBot succeeds through the real path")
	local model = CompanionService.ModelOf(owner)
	check(model ~= nil, "ModelOf returns the attached companion")
	if model then
		local rect = screenRect(camera, model)
		local fraction = rect.clampedArea / viewportArea
		out("measure  before (right): screen rect [%.0f,%.0f]-[%.0f,%.0f] px, %.1f%% of the %dx%d frame%s",
			rect.minX, rect.minY, rect.maxX, rect.maxY, fraction * 100, VIEWPORT.X, VIEWPORT.Y,
			rect.anyOffFront and " (partly off-frame)" or "")
		check(fraction > 0, "the companion is actually in frame to measure (%.2f%%)", fraction * 100)
	end
	pcall(CompanionService.AttachBot, owner, nil) -- despawn, leaves no companion for the next section
end)

section("after: mirrored to the left, same builder CompanionService itself calls", function()
	local character, root, humanoid = stageCharacter()
	local camera = thirdPersonCamera(root, humanoid)
	local scale = 0.55
	local model = BrainrotModels.Build(def, {
		scale = scale,
		anchored = true,
		rig = true,
		cframe = root.CFrame * CFrame.new(-2.8, 2.6, 2.4), -- mirrored X; up and behind unchanged
	})
	check(model ~= nil, "the mirrored build succeeds")
	if model then
		model.Parent = folder
		local rect = screenRect(camera, model)
		local fraction = rect.clampedArea / viewportArea
		out("measure  after (left): screen rect [%.0f,%.0f]-[%.0f,%.0f] px, %.1f%% of the %dx%d frame%s",
			rect.minX, rect.minY, rect.maxX, rect.maxY, fraction * 100, VIEWPORT.X, VIEWPORT.Y,
			rect.anyOffFront and " (partly off-frame)" or "")
		local hudOverlap = rectOverlap(rect, HUD_RECT.x0, HUD_RECT.y0, HUD_RECT.x1, HUD_RECT.y1)
		out("measure  after (left): overlap with the bottom-left HUD rect = %.0f px^2 (%.2f%% of the HUD rect)",
			hudOverlap, hudOverlap / ((HUD_RECT.x1 - HUD_RECT.x0) * (HUD_RECT.y1 - HUD_RECT.y0)) * 100)
		check(hudOverlap == 0, "moved to the left, the companion does NOT overlap the bottom-left HUD panels")
		model:Destroy()
	end
end)

folder:Destroy()

out("done: %d failures, %d checks", failures, samples)
