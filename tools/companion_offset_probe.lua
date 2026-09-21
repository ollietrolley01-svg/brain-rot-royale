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
-- FOV 70 (Settings.lua's FieldOfView default).
--
-- Occupancy is measured in ANGLE, not pixels: `Camera.ViewportSize` is READ-ONLY (confirmed by a
-- first run of this probe throwing "Property is read only" trying to set it for a reproducible
-- area) -- there is no real window in an edit-mode probe to read a meaningful size from either. So
-- every corner of the companion's world bounding box is transformed into camera-local space and
-- measured as an angle off the forward axis, horizontal and vertical separately, against the
-- camera's own FieldOfView (vertical) and a horizontal FOV derived from an ASSUMED 16:9 aspect
-- (stated as an assumption, not measured) -- this is viewport-size-independent and exactly
-- reproducible. The HUD-overlap check projects to assumed 1920x1080 pixels using the same angles,
-- for comparison against HudClient's real anchor positions -- again a stated assumption, not a
-- measured window.
--
-- "Before" goes through the REAL public path -- CompanionService.AttachBot + ModelOf -- so the
-- measured geometry (crown, glow, health bar included) is exactly what a match would build, at
-- today's FOLLOW_OFFSET (right/up/behind). "After" calls the SAME underlying BrainrotModels.Build
-- CompanionService.lua itself calls (same scale, same cframe shape), with only the X mirrored to
-- -2.8 -- the one-line fix -- since that constant isn't landed yet.

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
local FOV = 70
local ASSUMED_ASPECT = 16 / 9 -- stated assumption, not measured: a 1920x1080-shaped window
local ASSUMED_VIEWPORT = Vector2.new(1920, 1080)

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
	camera.CFrame = CFrame.lookAt(position, position + look.LookVector)
	return camera
end

-- The companion's angular extent in the frame: horizontal/vertical angle off the camera's forward
-- axis for every bounding-box corner, clamped to the camera's own half-angles, as a fraction of the
-- full frame. Also the same thing projected to assumed 1920x1080 pixels, for the HUD check.
local function angularRect(camera, model)
	local cframe, size = model:GetBoundingBox()
	local half = size * 0.5
	local vFov = math.rad(camera.FieldOfView)
	local hFov = 2 * math.atan(math.tan(vFov / 2) * ASSUMED_ASPECT)
	local minH, maxH, minV, maxV = math.huge, -math.huge, math.huge, -math.huge
	local anyBehind = false
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local corner = cframe:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				local local_ = camera.CFrame:PointToObjectSpace(corner)
				local depth = -local_.Z
				if depth <= 0.05 then
					anyBehind = true
				end
				local safeDepth = math.max(depth, 0.05)
				local hAngle = math.atan2(local_.X, safeDepth)
				local vAngle = math.atan2(local_.Y, safeDepth)
				minH, maxH = math.min(minH, hAngle), math.max(maxH, hAngle)
				minV, maxV = math.min(minV, vAngle), math.max(maxV, vAngle)
			end
		end
	end
	local hHalf, vHalf = hFov / 2, vFov / 2
	local clampedMinH, clampedMaxH = math.clamp(minH, -hHalf, hHalf), math.clamp(maxH, -hHalf, hHalf)
	local clampedMinV, clampedMaxV = math.clamp(minV, -vHalf, vHalf), math.clamp(maxV, -vHalf, vHalf)
	local fraction = (math.max(0, clampedMaxH - clampedMinH) / hFov) * (math.max(0, clampedMaxV - clampedMinV) / vFov)
	-- Assumed-pixel projection for the HUD comparison only (tan(angle)/tan(halfFov) * halfSize).
	local function px(angle, halfFov, halfSize)
		return halfSize + (math.tan(angle) / math.tan(halfFov)) * halfSize
	end
	return {
		minH = minH, maxH = maxH, minV = minV, maxV = maxV, hFov = hFov, vFov = vFov,
		fraction = fraction, anyBehind = anyBehind,
		pxMinX = px(minH, hHalf, ASSUMED_VIEWPORT.X / 2), pxMaxX = px(maxH, hHalf, ASSUMED_VIEWPORT.X / 2),
		-- vertical angle here is measured with +Y up in camera space and screen Y grows downward.
		pxMinY = ASSUMED_VIEWPORT.Y - px(minV, vHalf, ASSUMED_VIEWPORT.Y / 2),
		pxMaxY = ASSUMED_VIEWPORT.Y - px(maxV, vHalf, ASSUMED_VIEWPORT.Y / 2),
	}
end

local function rectOverlapPx(rect, x0, y0, x1, y1)
	local rx0, rx1 = math.min(rect.pxMinX, rect.pxMaxX), math.max(rect.pxMinX, rect.pxMaxX)
	local ry0, ry1 = math.min(rect.pxMinY, rect.pxMaxY), math.max(rect.pxMinY, rect.pxMaxY)
	local ox = math.max(0, math.min(rx1, x1) - math.max(rx0, x0))
	local oy = math.max(0, math.min(ry1, y1) - math.max(ry0, y0))
	return ox * oy
end

-- HUD's own bottom-left panels (companion_icon_gallery.lua's stand-ins, HudClient's real anchors):
-- health ~[16,296]x[viewportY-96,viewportY], companion panel ~[16,316]x[viewportY-166,viewportY-104],
-- speed pill ~[16,166]x[viewportY-202,viewportY-174]. One bounding rect over all three, generous, at
-- the assumed viewport above.
local HUD_RECT = { x0 = 16, y0 = ASSUMED_VIEWPORT.Y - 202, x1 = 320, y1 = ASSUMED_VIEWPORT.Y }

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
		local rect = angularRect(camera, model)
		out("measure  before (right): %.1f%% of the frame (h %.1f/%.1f deg, v %.1f/%.1f deg)%s",
			rect.fraction * 100, math.deg(rect.maxH - rect.minH), math.deg(rect.hFov),
			math.deg(rect.maxV - rect.minV), math.deg(rect.vFov), rect.anyBehind and " (partly behind camera)" or "")
		check(rect.fraction > 0, "the companion is actually in frame to measure (%.2f%%)", rect.fraction * 100)
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
		local rect = angularRect(camera, model)
		out("measure  after (left): %.1f%% of the frame (h %.1f/%.1f deg, v %.1f/%.1f deg)%s",
			rect.fraction * 100, math.deg(rect.maxH - rect.minH), math.deg(rect.hFov),
			math.deg(rect.maxV - rect.minV), math.deg(rect.vFov), rect.anyBehind and " (partly behind camera)" or "")
		local hudOverlap = rectOverlapPx(rect, HUD_RECT.x0, HUD_RECT.y0, HUD_RECT.x1, HUD_RECT.y1)
		out("measure  after (left): overlap with the assumed bottom-left HUD rect = %.0f px^2 (%.2f%% of the HUD rect, at an assumed %dx%d window)",
			hudOverlap, hudOverlap / ((HUD_RECT.x1 - HUD_RECT.x0) * (HUD_RECT.y1 - HUD_RECT.y0)) * 100,
			ASSUMED_VIEWPORT.X, ASSUMED_VIEWPORT.Y)
		check(hudOverlap == 0, "moved to the left, the companion does NOT overlap the bottom-left HUD panels (assumed window)")
		model:Destroy()
	end
end)

folder:Destroy()

out("done: %d failures, %d checks", failures, samples)
