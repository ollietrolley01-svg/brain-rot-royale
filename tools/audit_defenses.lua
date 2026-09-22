-- Probe for tools/runtest.ps1: the deployed defenses, as cover and as models.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_defenses.lua
--
-- A Rot Barricade, Pop-up Bunker or Brainrot Fortress is something a player stands behind and is
-- shot at through, so two things matter that nothing measured before:
--
--   holes   a gap you can see through is a gap a bullet goes through. Rays are fired across each
--           structure on a grid from four sides at chest height and at head height, and any opening
--           bigger than a sliver is reported with its size and where it is. Windows and doorways
--           ARE openings, so this reports every one and leaves the judgement to a person — what it
--           is really for is finding the ones nobody meant.
--   geometry the z-fight pass runs inside DefenseService.Build, so a structure written with flush
--           faces is silently reshaped on every deploy. Measured the way the items were: built once
--           with ZFight.Enabled false to count the pairs as WRITTEN, and once as the game builds it
--           to count what the pass moved or resized.
--
-- Both self-test: a planted hole must be found, and a planted flush pair must show up as written.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local DefenseService = require(modules:WaitForChild("DefenseService"))
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))

local IDS = { "RotBarricade", "PopupBunker", "BrainrotFortress" }
-- Ray spacing across the face, and the heights sampled (studs above the structure's base).
local STEP = 0.5
local HEIGHTS = { 1.5, 3.2 }
-- An opening this many square studs or larger is worth printing.
local MIN_HOLE = 1.0

local function out(fmt, ...)
	print("[AUDIT defenses] " .. string.format(fmt, ...))
end

local stage = Instance.new("Folder")
stage.Name = "DefenseProbeStage"
stage.Parent = workspace

local function partsOf(model)
	local parts = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.98 then
			table.insert(parts, d)
		end
	end
	return parts
end

-- Fires a grid of rays straight through the structure from one side and counts the cells that pass
-- clean through. Returns the open area and the widest run, in studs.
local function openings(model, parts, along)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = parts
	local box, size = model:GetBoundingBox()
	local across = along == "x" and size.Z or size.X
	local depth = along == "x" and size.X or size.Z
	local open, widest = 0, 0
	local cells = {}
	for _, height in ipairs(HEIGHTS) do
		local y = box.Position.Y - size.Y / 2 + height
		if height < size.Y then
			local run = 0
			local offset = -across / 2 + STEP / 2
			while offset < across / 2 do
				local from = along == "x"
					and Vector3.new(box.Position.X - depth / 2 - 2, y, box.Position.Z + offset)
					or Vector3.new(box.Position.X + offset, y, box.Position.Z - depth / 2 - 2)
				local direction = along == "x" and Vector3.new(depth + 4, 0, 0) or Vector3.new(0, 0, depth + 4)
				if workspace:Raycast(from, direction, params) == nil then
					open += STEP * STEP
					run += STEP
					widest = math.max(widest, run)
					if #cells < 6 then
						table.insert(cells, string.format("%.1f across at %.1f up", offset, height))
					end
				else
					run = 0
				end
				offset += STEP
			end
		end
	end
	if #cells > 0 then
		out("  %s: open cells along %s (relative to the model's centre): %s", model.Name, along, table.concat(cells, "; "))
	end
	return open, widest
end

local function measure(label, itemId)
	-- As written: the pass off, so nothing is tidied before it's counted. Switched back inside a
	-- pcall's shadow — a build that throws here must not leave the pass off for everything after it
	-- (this probe runs merged with others).
	ZFight.Enabled = false
	local built, raw = pcall(DefenseService.Build, itemId, CFrame.new(0, 500, 0), nil)
	ZFight.Enabled = true
	if not built then
		out("%s: build failed with the pass off: %s", label, tostring(raw))
		raw = nil
	end
	local writtenPairs = raw and ZFight.Scan({ raw }) or {}
	local written = raw and #writtenPairs or -1
	for index = 1, math.min(#writtenPairs, 8) do
		local pair = writtenPairs[index]
		out("  %s written pair %d: %s %s / %s %s, gap %.3f", label, index, pair.a.Name, tostring(pair.a.Size), pair.b.Name, tostring(pair.b.Size), pair.gap or -1)
	end
	if raw then
		raw:Destroy()
	end

	local model = DefenseService.Build(itemId, CFrame.new(0, 500, 0), nil)
	if not model then
		out("%s: nothing built", label)
		return 0, 0
	end
	model.Parent = stage
	local parts = partsOf(model)
	local moved = 0
	local movedNames = {}
	for _, part in ipairs(parts) do
		if part:GetAttribute("ZFixed") then
			moved += 1
			if #movedNames < 8 then
				table.insert(movedNames, string.format("%s %s at %s", part.Name, tostring(part.Size), tostring(part.Position - model:GetPivot().Position)))
			end
		end
	end
	if moved > 0 then
		-- Named, so "the pass changed 1 part" is a fix and not a search.
		out("  %s: parts the pass changed: %s", label, table.concat(movedNames, "; "))
	end
	local openX, widestX = openings(model, parts, "x")
	local openZ, widestZ = openings(model, parts, "z")
	out("%s: %d parts; written flush pairs %d; pass changed %d; see-through %.1f sq studs across, %.1f along (widest run %.1f / %.1f)",
		label, #parts, written, moved, openX, openZ, widestX, widestZ)
	model:Destroy()
	return written, moved
end

-- Self-test: the counters have to be able to fire.
do
	local holder = Instance.new("Model")
	holder.Name = "SelfTest"
	holder.Parent = stage
	local function plate(size, cframe)
		local part = Instance.new("Part")
		part.Size = size
		part.CFrame = cframe
		part.Anchored = true
		part.Parent = holder
		return part
	end
	-- Two plates with a 2-stud slot between them, and a smaller block set into the first with its
	-- top in the same plane as the first's top: two faces pointing the same way, coplanar and
	-- overlapping, which is the only thing the z-fight rules count. (A plate LYING on the first was
	-- planted before: that is a butt joint, faces pointing at each other, which the rules rightly
	-- ignore, so the self-test read 0 and failed itself.)
	plate(Vector3.new(4, 6, 1), CFrame.new(-3, 503, 0))
	plate(Vector3.new(4, 6, 1), CFrame.new(3, 503, 0))
	plate(Vector3.new(2, 2, 0.5), CFrame.new(-3, 505, 0))
	local parts = partsOf(holder)
	local open = openings(holder, parts, "z")
	local flush = #ZFight.Scan({ holder })
	out("self-test: planted slot reads %.1f sq studs (want > 0), planted flush pair reads %d (want > 0) -> %s",
		open, flush, (open > 0 and flush > 0) and "PASS" or "FAIL (the numbers below prove nothing)")
	holder:Destroy()
end

local totalWritten, totalMoved = 0, 0
for _, itemId in ipairs(IDS) do
	local written, moved = measure(itemId, itemId)
	totalWritten += math.max(written, 0)
	totalMoved += moved
end

out("RESULT %s: %d flush pairs as written, %d parts the pass had to change",
	(totalWritten == 0 and totalMoved == 0) and "PASS" or "FAIL", totalWritten, totalMoved)
stage:Destroy()
pcall(flush)
