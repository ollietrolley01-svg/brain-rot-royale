-- Death effects (#24), every one at its three moments (anticipation, burst, follow-through), plus the
-- plain death's dressing, for tools/gallery.ps1 on Oliver's machine:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/deathfx_gallery.lua -OutDir <folder> -TimeoutSeconds 1200
--
-- Rebuild the place first (python build_place.py .): this requires Shared/DeathEffectFx and
-- Shared/DeathEffectDesigns out of the built place.
--
-- Each view builds a stand-in body (DeathEffectFx.Dummy, the one the shop previews use) on a grass
-- plate, builds the REAL design on it and steps it straight to the moment. That jump is exactly the
-- frame the game shows at that moment: tools/killanim_check.py proves a jump and 60 fps stepping give
-- the same parts, to 1e-4, for every design at every moment here. The scene then stands still for the
-- capture.
--
-- What a still can't show, said plainly: the effects run in PREVIEW mode here, so particles are the
-- preview's neon sparks and there are no PointLights (the neon flash parts are still there). In the
-- game the same moments have real particles (sparkle/smoke/fire textures) and light flashes on top.
-- A ParticleEmitter can't be frozen at a moment, so they can't be shown still.
--
-- Things to look at: the body does something in every burst view (popped, flattened, melted, lifted,
-- swallowed); nothing is buried in the plate or floating off it by accident; cylinders are upright or
-- lying flat as meant (a Cylinder's length is its X axis); the bat lands ON the body; the ghost faces
-- the camera side; the meteor's crater sits on the ground; the black hole's disc is tilted, not edge-on.
-- Every view prints its part count and an occlusion ray from the camera to the body (COORDINATION.md:
-- "in frame" is not "visible").

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local DeathEffectFx = require(Shared:WaitForChild("DeathEffectFx"))
local Designs = require(Shared:WaitForChild("DeathEffectDesigns"))

local V = Vector3.new
local HIGH = V(600, 1400, -2600)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function stage(folder, at)
	local plate = Instance.new("Part")
	plate.Name = "Plate"
	plate.Anchored = true
	plate.Size = V(70, 1, 70)
	plate.CFrame = CFrame.new(at - V(0, 0.5, 0))
	plate.Color = Color3.fromRGB(96, 150, 80)
	plate.Material = Enum.Material.Grass
	plate.Parent = folder
end

-- Casts from the camera to the body's chest and names whatever it meets first.
local function occlusion(label, camera, target, subject)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace }
	local from = camera.CFrame.Position
	local hit = workspace:Raycast(from, target - from, params)
	if not hit then
		note(string.format("%s: camera -> body clear (%.1f studs)", label, (target - from).Magnitude))
	elseif subject and hit.Instance:IsDescendantOf(subject) then
		note(string.format("%s: camera -> body reaches %s first (the subject itself)", label, hit.Instance:GetFullName()))
	else
		note(string.format("%s: camera -> body OCCLUDED by %s at %.1f studs", label, hit.Instance:GetFullName(), hit.Distance))
	end
end

-- The camera where the shop's stage puts it (CosmeticPreview's frameDeath), at a 16:9 capture.
local function frame(camera, design, at)
	local view = design.view or { focus = V(0, 3.5, 0), radius = 8 }
	camera.FieldOfView = 40
	local half = math.tan(math.rad(40 / 2))
	local distance = view.radius / half * 1.1
	local focus = at + view.focus
	camera.CFrame = CFrame.lookAt(focus + V(0.45, 0.28, -0.85).Unit * distance, focus)
end

local live = {}
local function clearOld()
	for _, entry in ipairs(live) do
		pcall(function()
			entry.fx:destroy()
			entry.dummy:Destroy()
		end)
	end
	live = {}
end

-- One view: the design `design` built on a fresh stand-in body at `at`, stepped to `moment`.
local function scene(folder, design, at, moment, ownsBody)
	local dummy = DeathEffectFx.Dummy(CFrame.new(at))
	dummy.Parent = folder
	if not ownsBody then
		for _, part in ipairs(dummy:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Anchored = true
			end
		end
	end
	local fx = DeathEffectFx.new({
		parent = folder,
		origin = at + DeathEffectFx.DummyRoot,
		ground = at,
		life = design.life,
		body = dummy,
		ownsBody = ownsBody,
		preview = true,
		seed = 7,
	})
	design.build(fx)
	fx:step(moment)
	table.insert(live, { fx = fx, dummy = dummy })
	return fx, dummy
end

local views = {}
local BEATS = { "anticipation", "burst", "follow-through" }

for _, id in ipairs(CosmeticData.OfKind("KillAnimation")) do
	local design = Designs.Get(id)
	if not design then
		note(id .. " has no design")
	else
		for index, moment in ipairs(design.moments) do
			table.insert(views, {
				name = string.format("deathfx_%s_%d_%s_%.2fs", id, index, BEATS[index], moment),
				settle = 1.2,
				hold = 3,
				setup = function(folder, camera)
					clearOld()
					stage(folder, HIGH)
					frame(camera, design, HIGH)
					local ok, err = pcall(function()
						local fx, dummy = scene(folder, design, HIGH, moment, true)
						note(string.format("%s %s at %.2f s: %d parts, %d sparks", id, BEATS[index], moment, fx.parts, fx.sparkCount))
						occlusion(id .. " " .. BEATS[index], camera, HIGH + V(0, 3.9, 0), dummy)
					end)
					if not ok then
						note(id .. " failed: " .. tostring(err))
					end
				end,
			})
		end
	end
end

-- The plain death's dressing (DeathFxClient): the hit flash as a tint here, the dust, the rot-soul
-- wisp, and the puff when the ragdoll fades. It never moves the body, so the stand-in stands.
local DEFAULT = {
	{ "impact", Designs.Default.Impact },
	{ "poof", Designs.Default.Poof },
}
for _, entry in ipairs(DEFAULT) do
	local label, design = entry[1], entry[2]
	for index, moment in ipairs(design.moments) do
		table.insert(views, {
			name = string.format("deathfx_default_%s_%d_%.2fs", label, index, moment),
			settle = 1.2,
			hold = 3,
			setup = function(folder, camera)
				clearOld()
				stage(folder, HIGH)
				frame(camera, design, HIGH)
				local ok, err = pcall(function()
					local fx, dummy = scene(folder, design, HIGH, moment, true)
					note(string.format("default %s at %.2f s: %d parts, %d sparks", label, moment, fx.parts, fx.sparkCount))
					occlusion("default " .. label, camera, HIGH + V(0, 3.9, 0), dummy)
				end)
				if not ok then
					note("default " .. label .. " failed: " .. tostring(err))
				end
			end,
		})
	end
end

table.insert(views, {
	name = "deathfx_cleanup",
	settle = 1,
	hold = 1,
	setup = function(_, camera)
		clearOld()
		camera.CFrame = CFrame.lookAt(HIGH + V(14, 10, -20), HIGH)
	end,
})

return views
