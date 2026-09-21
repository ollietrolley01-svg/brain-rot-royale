-- Companion gallery: every body shape caught mid-attack, one frame per move.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/companion_gallery.lua -OutDir <folder> -Hold 1
--
-- Each view stands seven copies of one brainrot in a row, left to right: idle, Spit (the snap),
-- Bonk (mid-leap), Zap (the recoil), Chain (mid-spin), Lob (arms up in the windup) and Shockwave
-- (top of the jump). Poses come from CompanionAnimations exactly as a client plays them; since
-- joints don't solve in edit mode, the gallery works out each rigged part's posed CFrame itself
-- and anchors it there.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))

local ORIGIN = Vector3.new(-6000, 400, 6000)
local SPACING = 5
local W = CompanionAnimations.Windup

local FRAMES = {
	{ label = "idle" },
	{ label = "Spit", kind = "Spit", t = W + 0.1 },
	{ label = "Bonk", kind = "Bonk", t = W + 0.175, target = Vector3.new(0, 0, -3) },
	{ label = "Zap", kind = "Zap", t = W + 0.12 },
	{ label = "Chain", kind = "Chain", t = W + 0.2 },
	{ label = "Lob", kind = "Lob", t = W * 0.95 },
	{ label = "Shockwave", kind = "Shockwave", t = W * 0.6 },
}

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- Builds a rigged creature at `at` and freezes it in `pose`.
local function posed(def, at, pose)
	local model = BrainrotModels.Build(def, { rig = true, anchored = false, flair = false, cframe = at })
	local root = model.PrimaryPart
	local rest, pivotOf, joints = {}, {}, {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			rest[part] = part.CFrame
			local joint = part:FindFirstChildOfClass("Motor6D")
			if joint then
				joints[part] = { part0 = joint.Part0, c0 = joint.C0, c1 = joint.C1, name = joint.Name }
			end
			local weld = part:FindFirstChildOfClass("WeldConstraint")
			if weld then
				pivotOf[part] = weld.Part0
			end
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	local transforms = CompanionAnimations.Transforms(pose)
	local world = { [root] = rest[root] }
	local function solve(pivot)
		if world[pivot] then
			return world[pivot]
		end
		local joint = joints[pivot]
		world[pivot] = solve(joint.part0) * joint.c0 * (transforms[joint.name] or CFrame.new()) * joint.c1:Inverse()
		return world[pivot]
	end
	for part, cf in pairs(rest) do
		local pivot = pivotOf[part]
		if pivot then
			part.CFrame = solve(pivot) * rest[pivot]:ToObjectSpace(cf)
		end
	end
	for pivot in pairs(joints) do
		pivot.CFrame = solve(pivot)
	end
	return model
end

local BODY_ORDER = { "Blob", "Bean", "Cube", "Pear", "Disc", "Stack", "Egg", "Mushroom", "Cloud", "Can", "Cone", "Ghost", "Loaf", "Totem" }
-- The most animated brainrot on each body: arms, wings and a tail all count.
local best = {}
for _, def in ipairs(BrainrotData.Types) do
	local body = def.look and def.look.body or "Blob"
	local score = 0
	for _, extra in ipairs(def.look and def.look.extras or {}) do
		score += (extra == "Wings" or extra == "Tail" or extra == "Arms") and 2 or 0
	end
	if not best[body] or score > best[body].score then
		best[body] = { def = def, score = score }
	end
end

local views = {}
for index, body in ipairs(BODY_ORDER) do
	local entry = best[body]
	if entry then
		table.insert(views, {
			name = string.format("attack_%02d_%s", index, body),
			settle = 1,
			setup = function(folder, camera)
				local pad = Instance.new("Part")
				pad.Anchored = true
				pad.Size = Vector3.new(60, 1, 24)
				pad.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
				pad.Color = Color3.fromRGB(150, 152, 158)
				pad.Parent = folder
				local metrics = BrainrotModels.Metrics(entry.def)
				local size = entry.def.look and entry.def.look.size or 1
				for frameIndex, frame in ipairs(FRAMES) do
					local x = (frameIndex - (#FRAMES + 1) / 2) * SPACING
					local at = CFrame.new(ORIGIN + Vector3.new(x, -metrics.bottom * size, 0))
					local pose = CompanionAnimations.IdlePose(body, 0.3, 0, 1)
					if frame.kind then
						CompanionAnimations.Layer(pose, body, { kind = frame.kind, start = 0, target = frame.target or Vector3.new(0, 0, -6), travel = 0.35 },
							frame.t, 1)
					end
					posed(entry.def, at, pose).Parent = folder
				end
				note(string.format("%s: %s", body, entry.def.name))
				camera.FieldOfView = 34
				camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(-6, 7, -30), ORIGIN + Vector3.new(0, 2, 0))
			end,
		})
	end
end

return views
