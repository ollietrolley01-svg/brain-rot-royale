-- Brainrot model probe, for tools/runtest.ps1 -Probe (edit mode, ~1-2 min).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/brainrot_models_probe.lua
--
-- Measures every brainrot in BrainrotData the way its callers use it:
--   parts      BaseParts per model at scale 1 (companions, statues and showcase rings multiply it),
--              and the build time
--   nested     BaseParts that aren't direct children of the model. ShowcaseService and the lobby's
--              crate stage move only the model's direct children, so a nested part would vanish.
--   base       the lowest visible point against the BODIES contract's `bottom`. Statues are stood
--              on their plinth by `bottom`, so anything lower sinks into it.
--   flush      ZFight.Scan pairs left after the builder's own pass
--   drift      statues get a SECOND z-fight pass (the lobby-wide and map-wide ones). Each creature
--              is built at every statue scale, off-axis and far from the origin, then run through
--              ZFight.Fix again the way those passes do; any part that moves or grows is reported.
--              That second pass is what turned the podium guns into black blocks.
--   companion  at the companion scale (0.55) the builder's own pass is relatively coarse, so the
--              largest ZFixed nudge is reported against the size of the part it moved.
--
-- Uses the place's own BrainrotModels, or a scratch copy pasted in at MODELS_EMBED.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))

local EMBEDDED_MODELS = nil --[[MODELS_EMBED]]
local BrainrotModels
if EMBEDDED_MODELS then
	BrainrotModels = loadstring(EMBEDDED_MODELS)()
else
	BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
end

local function out(fmt, ...)
	print("[PROBE brainrots] " .. string.format(fmt, ...))
end

-- Scales the callers really use: lobby trophy 1.1, springs statue 1.2, showcase 1.3, crate stage
-- 1.5/1.8, lobby statue 1.6, plaza statue 2.6.
local STATUE_SCALES = { 1.1, 1.2, 1.3, 1.6, 2.6 }
local COMPANION_SCALE = 0.55
local FAR = CFrame.new(3000.137, 800.411, -2500.783) * CFrame.Angles(0, 0.7, 0)

local stage = Instance.new("Folder")
stage.Name = "BrainrotModelsProbe"
stage.Parent = workspace

-- How far a part reaches along a world direction from its centre, from its real shape.
local function support(part, direction)
	local cf = part.CFrame
	local size = part.Size
	local dx, dy, dz = cf.RightVector:Dot(direction), cf.UpVector:Dot(direction), cf.LookVector:Dot(direction)
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	if mesh and mesh.MeshType == Enum.MeshType.Sphere then
		local a, b, c = size.X / 2 * mesh.Scale.X, size.Y / 2 * mesh.Scale.Y, size.Z / 2 * mesh.Scale.Z
		return math.sqrt((a * dx) ^ 2 + (b * dy) ^ 2 + (c * dz) ^ 2)
	end
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return math.min(size.X, size.Y, size.Z) / 2
	end
	if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local radius = math.min(size.Y, size.Z) / 2
		return math.abs(dx) * size.X / 2 + radius * math.sqrt(math.max(0, 1 - dx * dx))
	end
	return math.abs(dx) * size.X / 2 + math.abs(dy) * size.Y / 2 + math.abs(dz) * size.Z / 2
end

local function partsOf(model)
	local all, visible, nested = {}, {}, 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(all, d)
			if d.Transparency < 0.98 then
				table.insert(visible, d)
			end
			if d.Parent ~= model then
				nested += 1
			end
		end
	end
	return all, visible, nested
end

local function snapshot(parts)
	local shot = {}
	for _, part in ipairs(parts) do
		shot[part] = { part.CFrame, part.Size }
	end
	return shot
end

-- Self-test first: every check below must be able to fail. A planted flush pair has to show up in
-- ZFight.Scan and be moved by a second ZFight.Fix, and a part planted below a body's base has to read
-- as sinking. If any of these can't see its planted fault, the zeros further down mean nothing.
do
	local planted = Instance.new("Model")
	planted.Parent = stage
	local function block(size, position)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = CFrame.new(position)
		part.Parent = planted
		return part
	end
	local base = Vector3.new(-3000.3, 700.2, 2500.1)
	block(Vector3.new(4, 1, 4), base)
	local lid = block(Vector3.new(2, 1, 2), base + Vector3.new(0, 0.02, 0))
	local flushSeen = #ZFight.Scan({ planted })
	local before = lid.Position
	ZFight.Fix({ planted })
	local moved = (lid.Position - before).Magnitude + math.abs(lid.Size.Y - 1)
	local low = Instance.new("Part")
	low.Shape = Enum.PartType.Ball
	low.Size = Vector3.new(0.4, 0.4, 0.4)
	low.CFrame = CFrame.new(0, -1.3, 0)
	local sink = -1.0 - (low.Position.Y - support(low, Vector3.new(0, -1, 0)))
	local pass = flushSeen > 0 and moved > 0.01 and sink > 0.06
	out("== self-test: planted flush pair seen %d, second pass moved it %.3f, planted low part sinks %.3f -> %s",
		flushSeen, moved, sink, pass and "PASS" or "FAIL (the checks below can't see what they measure)")
	planted:Destroy()
	low:Destroy()
end

local totals = { parts = 0, visible = 0, models = 0, ms = 0, nested = 0, sinking = 0, flush = 0, drifted = 0 }
local heaviest = {}
local findings = {}
local driftByScale = {}
local worstCompanion = {}

for index, def in ipairs(BrainrotData.Types) do
	local size = (def.look and def.look.size) or 1
	local metrics = BrainrotModels.Metrics(def)

	-- Scale 1 at the origin: parts, time, base, flush.
	local started = os.clock()
	local model = BrainrotModels.Build(def, { flair = false })
	local ms = (os.clock() - started) * 1000
	model.Parent = stage
	local all, visible, nested = partsOf(model)
	local lowest, lowestName = math.huge, ""
	local down = Vector3.new(0, -1, 0)
	for _, part in ipairs(visible) do
		local low = part.Position.Y - support(part, down)
		if low < lowest then
			lowest, lowestName = low, part.Name
		end
	end
	local sink = metrics.bottom * size - lowest
	local flush = #ZFight.Scan({ model })
	totals.models += 1
	totals.parts += #all
	totals.visible += #visible
	totals.ms += ms
	totals.nested += nested
	totals.flush += flush
	table.insert(heaviest, { def.name, #all })
	local hover = def.look and (def.look.body == "Ghost" or def.look.body == "Cloud")
	local line = string.format("%-28s %-8s parts %3d (visible %3d) %5.1f ms  base %+.3f  flush %d", def.name,
		tostring(def.look and def.look.body), #all, #visible, ms, sink, flush)
	if nested > 0 then
		table.insert(findings, string.format("%s: %d nested parts", def.name, nested))
	end
	if sink > 0.06 and not hover then
		totals.sinking += 1
		table.insert(findings, string.format("%s: lowest point %.3f below the contract's bottom (%s)", def.name, sink, lowestName))
	end
	if flush > 0 then
		table.insert(findings, string.format("%s: %d flush pairs after build", def.name, flush))
	end
	model:Destroy()

	-- Statue scales: a second z-fight pass must change nothing.
	local drift = {}
	for _, scale in ipairs(STATUE_SCALES) do
		local statue = BrainrotModels.Build(def, { flair = false, scale = scale, cframe = FAR })
		statue.Parent = stage
		local statueParts = partsOf(statue)
		local before = snapshot(statueParts)
		ZFight.Fix({ statue })
		local moved, worst, worstName = 0, 0, ""
		for part, shot in pairs(before) do
			local dp = (part.Position - shot[1].Position).Magnitude
			local ds = (part.Size - shot[2]).Magnitude
			if dp > 1e-4 or ds > 1e-4 then
				moved += 1
				if math.max(dp, ds) > worst then
					worst, worstName = math.max(dp, ds), part.Name
				end
			end
		end
		driftByScale[scale] = (driftByScale[scale] or 0) + moved
		if moved > 0 then
			totals.drifted += 1
			table.insert(drift, string.format("x%.1f %d parts (worst %s %.3f)", scale, moved, worstName, worst))
		end
		statue:Destroy()
	end
	if #drift > 0 then
		table.insert(findings, string.format("%s: second pass moved %s", def.name, table.concat(drift, "; ")))
	end

	-- Companion scale: how hard did the builder's own pass have to push?
	local companion = BrainrotModels.Build(def, { flair = false, scale = COMPANION_SCALE, anchored = false })
	local worstRatio, worstPart, nudged = 0, "", 0
	for _, part in ipairs((partsOf(companion))) do
		local fixed = part:GetAttribute("ZFixed")
		if fixed and fixed > 0 then
			nudged += 1
			local smallest = math.min(part.Size.X, part.Size.Y, part.Size.Z)
			local ratio = fixed / math.max(smallest, 0.01)
			if ratio > worstRatio then
				worstRatio, worstPart = ratio, string.format("%s nudged %.3f (smallest side %.3f)", part.Name, fixed, smallest)
			end
		end
	end
	table.insert(worstCompanion, { def.name, worstRatio, worstPart .. string.format(", %d parts nudged", nudged) })
	companion:Destroy()

	out("%s%s", line, #drift > 0 and ("  drift " .. table.concat(drift, "; ")) or "")
	if index % 8 == 0 then
		task.wait()
	end
end

table.sort(heaviest, function(a, b)
	return a[2] > b[2]
end)
table.sort(worstCompanion, function(a, b)
	return a[2] > b[2]
end)
local heavy = {}
for i = 1, math.min(10, #heaviest) do
	table.insert(heavy, string.format("%s %d", heaviest[i][1], heaviest[i][2]))
end
out("== SUMMARY %d models: parts total %d, mean %.1f, max %d; visible mean %.1f; build mean %.1f ms",
	totals.models, totals.parts, totals.parts / totals.models, heaviest[1] and heaviest[1][2] or 0, totals.visible / totals.models,
	totals.ms / totals.models)
-- Coverage, so the zeros below can't come from a probe that quietly built nothing: every entry in
-- BrainrotData has to have been built and measured.
out("== coverage: %d of %d brainrots in BrainrotData built -> %s", totals.models, #BrainrotData.Types,
	(totals.models == #BrainrotData.Types and totals.models > 0) and "PASS"
		or "FAIL (models were skipped, so every count below is measuring less than the collection)")
out("== heaviest: %s", table.concat(heavy, ", "))
local scales = {}
for _, scale in ipairs(STATUE_SCALES) do
	table.insert(scales, string.format("x%.1f %d", scale, driftByScale[scale] or 0))
end
out("== second-pass drift (parts moved, all models): %s; models with any drift %d", table.concat(scales, ", "), totals.drifted)
out("== nested parts %d; sinking models %d; flush pairs %d", totals.nested, totals.sinking, totals.flush)
for i = 1, math.min(16, #worstCompanion) do
	out("== companion nudge %s: %.2f of its smallest side, %s", worstCompanion[i][1], worstCompanion[i][2], worstCompanion[i][3])
end
out("== findings %d", #findings)
for i, line in ipairs(findings) do
	if i > 80 then
		out("  ... %d more", #findings - 80)
		break
	end
	out("  %s", line)
end
stage:Destroy()
