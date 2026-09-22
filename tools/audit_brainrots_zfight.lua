-- Probe for tools/runtest.ps1 -Probe: what the z-fight pass does to every brainrot model.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_brainrots_zfight.lua
--
-- BrainrotModels.Build runs ZFight.Fix on its own output (BrainrotModels.lua:2206), so a brainrot
-- written with flush faces is silently reshaped every time it is built — as a companion at the
-- shoulder (scale 0.55), on a lobby podium (1), on the showcase and the crate reveal (1.8) — and no
-- audit of the finished model can see it, the way the glider's canopy cells were stretched into a
-- staircase before the items got this measurement. Every one of BrainrotData.Types is built at
-- each of those scales with the pass off (the geometry as written) and as the game builds it, and
-- the two are diffed part by part in build order. Reported per model: the flush pairs as written,
-- every part the pass moved or resized and by how much, and whether a second pass still changes
-- anything. Clean means 0 written pairs, 0 parts changed, 0 on the second pass.
--
-- Planted every run, on the first model: a part duplicated in place must read as a flush pair, and
-- a part nudged 0.01 in the pass-off copy must show as one changed part in the diff.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))

-- Companion at the shoulder, podium/statue, showcase and reveal.
local SCALES = { 0.55, 1, 1.8 }
local MAX_PAIR_NAMES = 8
local MAX_CHANGES = 10

local function out(fmt, ...)
	print("[AUDIT brainrotzfight] " .. string.format(fmt, ...))
end

local function v3(v)
	return string.format("(%.3f,%.3f,%.3f)", v.X, v.Y, v.Z)
end

local function partsOf(model)
	local list = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

-- The self-test plants on a block of its own, appended AFTER the model's parts (so the build-order
-- diff of the real parts is untouched): the first plants looked for a suitable part on the model and
-- a bean-bodied brainrot had none (balls and meshes have no flat face to pair; a Seam is a sliver).
local PLANT_AT = Vector3.new(0, -50, 0)
local function plantBlock(model, name)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = CFrame.new(PLANT_AT)
	part.Anchored = true
	part.Parent = model
	return part
end

-- Builds twice (pass off, pass on), scans the written copy and diffs the two. Returns the counts;
-- `nudge` (self-test only) moves one plantable part of the written copy by 0.01 before the diff.
local function measure(build, nudge)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local okRaw, raw = pcall(build)
	ZFight.Enabled = wasEnabled
	local okFixed, fixed = pcall(build)
	if not (okRaw and raw and okFixed and fixed) then
		return nil, tostring(okRaw and fixed or raw)
	end
	local a, b = partsOf(raw), partsOf(fixed)
	if nudge == "nudge" then
		-- One block in each build at the same place, the written one moved 0.01: exactly one change.
		plantBlock(raw, "PlantNudge").CFrame = CFrame.new(PLANT_AT + Vector3.new(0.01, 0, 0))
		plantBlock(fixed, "PlantNudge")
		a, b = partsOf(raw), partsOf(fixed)
	elseif nudge == "duplicate" then
		-- Two identical blocks in the written build: a flush pair on every face.
		plantBlock(raw, "PlantTwin")
		plantBlock(raw, "PlantTwin")
		a = partsOf(raw)
	end
	local written = ZFight.Scan({ raw }, ZFight.FixTolerance)
	local rawOrigin = raw.PrimaryPart and raw.PrimaryPart.CFrame or CFrame.new()
	local fixedOrigin = fixed.PrimaryPart and fixed.PrimaryPart.CFrame or CFrame.new()
	local changes = {}
	for index = 1, math.min(#a, #b) do
		local pa, pb = a[index], b[index]
		local ra, rb = rawOrigin:ToObjectSpace(pa.CFrame), fixedOrigin:ToObjectSpace(pb.CFrame)
		local shift = (ra.Position - rb.Position).Magnitude
		local grow = pb.Size - pa.Size
		if shift > 0.001 or grow.Magnitude > 0.001 then
			table.insert(changes, string.format("%s moved %.3f resized %s", pa.Name, shift, v3(grow)))
		end
	end
	local again = ZFight.Fix({ fixed }, { all = true })
	local pairNames = {}
	for index = 1, math.min(#written, MAX_PAIR_NAMES) do
		local pair = written[index]
		table.insert(pairNames, string.format("%s/%s gap %.3f", pair.a.Name, pair.b.Name, pair.gap or -1))
	end
	local result = {
		parts = #a, written = #written, pairNames = pairNames, changes = changes,
		secondPass = again.moved + again.resized, countMismatch = #a ~= #b,
	}
	raw:Destroy()
	fixed:Destroy()
	return result
end

-- Self-test on the first model: a duplicated block must read as a flush pair; a nudged one as one change.
do
	local def = BrainrotData.Types[1]
	local function build()
		return BrainrotModels.Build(def, { scale = 1 })
	end
	local plain = measure(build)
	local duplicated = measure(build, "duplicate")
	local nudged = measure(build, "nudge")
	local dupOk = duplicated and plain and duplicated.written > plain.written
	local nudgeExact = nudged and plain and #nudged.changes == #plain.changes + 1
	out("self-test on %s: duplicated block reads %s written pairs (plain %s); nudged block reads %s changes (plain %s, want exactly one more) -> %s",
		def.name, tostring(duplicated and duplicated.written), tostring(plain and plain.written),
		tostring(nudged and #nudged.changes), tostring(plain and #plain.changes),
		(dupOk and nudgeExact) and "PASS" or "FAIL (the counts below prove nothing)")
end

local clean, dirty, failed = 0, 0, 0
local dirtyNames = {}
for index, def in ipairs(BrainrotData.Types) do
	for _, scale in ipairs(SCALES) do
		local label = string.format("%s x%.2f", def.name, scale)
		local result, err = measure(function()
			return BrainrotModels.Build(def, { scale = scale })
		end)
		if not result then
			failed += 1
			out("%s: build failed: %s", label, err)
		elseif result.written == 0 and #result.changes == 0 and result.secondPass == 0 and not result.countMismatch then
			clean += 1
		else
			dirty += 1
			dirtyNames[def.name] = true
			out("%s: %d parts%s; written flush pairs %d [%s]; build pass changed %d parts [%s]; second pass %d",
				label, result.parts, result.countMismatch and " (PART COUNT DIFFERS between builds)" or "",
				result.written, table.concat(result.pairNames, "; "),
				#result.changes, table.concat(result.changes, "; ", 1, math.min(#result.changes, MAX_CHANGES)), result.secondPass)
		end
	end
	if index % 4 == 0 then
		task.wait()
	end
end

local names = {}
for name in pairs(dirtyNames) do
	table.insert(names, name)
end
table.sort(names)
out("SUMMARY %d brainrots x %d scales: %d builds clean, %d with written flush pairs or pass changes, %d failed to build; %d models affected",
	#BrainrotData.Types, #SCALES, clean, dirty, failed, #names)
if #names > 0 then
	out("affected: %s", table.concat(names, ", "))
end
out("RESULT %s", (dirty == 0 and failed == 0) and "PASS" or "FAIL")
pcall(flush)
