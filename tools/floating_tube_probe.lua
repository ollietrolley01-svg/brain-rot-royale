-- Probe for tools/runtest.ps1 -Probe: a tube running the length of a gun with daylight under it.
--
-- Oliver: "some weapons like the lag switch smg models have a messed up barrel which looks duplicated and
-- out of place." On the SMG the cause was a cocking tube standing 5 mm clear of the handguard along its
-- whole run, held at one point near the receiver -- so it read as a second barrel floating over the first.
-- Nothing was disconnected, so the contact sweep passed it: the fault is a SLOT, not a gap in the model.
--
-- This looks for the shape of that fault on every gun: a cylinder lying along the bore, long, off the bore
-- line, with a run of nothing underneath it. It reports the longest such run per tube, so a tube banded at
-- both ends reads as short runs and a tube held at one point reads as one long one.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/floating_tube_probe.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))

local MM = GunModels.StudsPerMillimetre
local LONG = 60 -- mm: shorter than this is a band or a block, not a tube
local OFF_BORE = 8 -- mm: a tube this far off the bore line is beside the barrel, not the barrel
local UNDER = 7 -- mm: how far below a tube counts as "something holding it up"
local STEP = 4 -- mm between samples along a tube
local RUN = 55 -- mm: a clear run longer than this is the fault, not a styling gap
-- The bore itself, and the parts that ARE the barrel, are allowed to be off on their own.
local SKIP = { Bore = true, Barrel = true, Suppressor = true, MuzzleBrake = true, Silencer = true }

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local function nodeOf(part)
	return { part = part, name = part.Name, cframe = part.CFrame, inverse = part.CFrame:Inverse(),
		half = part.Size / 2, cyl = part:IsA("Part") and part.Shape == Enum.PartType.Cylinder }
end

local function inside(node, point, eps)
	local p = node.inverse * point
	local h = node.half
	if node.cyl then
		local r = math.min(h.Y, h.Z) + eps
		return math.abs(p.X) <= h.X + eps and p.Y * p.Y + p.Z * p.Z <= r * r
	end
	return math.abs(p.X) <= h.X + eps and math.abs(p.Y) <= h.Y + eps and math.abs(p.Z) <= h.Z + eps
end

-- A cylinder's own axis is its X; this asks whether that axis lies along the gun's bore (Z).
local function alongBore(node)
	return math.abs(node.cframe.RightVector.Z) > 0.9
end

local function longestClearRun(tube, others)
	local radius = math.min(tube.half.Y, tube.half.Z)
	local length = tube.half.X * 2
	local samples = math.max(2, math.floor(length / (STEP * MM)))
	local best, current = 0, 0
	for i = 0, samples do
		local along = (i / samples * 2 - 1) * tube.half.X
		-- Just under the tube's belly, in world space.
		local at = tube.cframe * Vector3.new(along, -radius - 1 * MM, 0)
		local held = false
		for _, other in ipairs(others) do
			if inside(other, at, UNDER * MM) then
				held = true
				break
			end
		end
		if held then
			current = 0
		else
			current += length / samples
			best = math.max(best, current)
		end
	end
	return best / MM
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

-- Self-test: a planted tube held at one end only must be caught, and the same tube banded at both ends
-- and along the middle must not be.
local function selfTest()
	local ok, err = pcall(function()
		local bench = Instance.new("Folder")
		bench.Name = "BRR_FloatingTubeSelfTest"
		bench.Parent = workspace
		local function tube(z)
			local part = Instance.new("Part")
			part.Anchored = true
			part.Shape = Enum.PartType.Cylinder
			part.Size = Vector3.new(150 * MM, 22 * MM, 22 * MM)
			part.CFrame = CFrame.new(0, 5000, z) * CFrame.Angles(0, math.pi / 2, 0)
			part.Parent = bench
			return nodeOf(part)
		end
		local function band(z, y)
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(28 * MM, 13 * MM, 14 * MM)
			part.CFrame = CFrame.new(0, 5000 + y * MM, z)
			part.Parent = bench
			return nodeOf(part)
		end
		local floating = tube(0)
		local oneEnd = { band(-0.28, -14) }
		local banded = { band(-0.28, -14), band(0, -14), band(0.28, -14) }
		local a = longestClearRun(floating, oneEnd)
		local b = longestClearRun(floating, banded)
		out("self-test tube held at one end: longest clear run %.0f mm -> %s", a, a > RUN and "ok" or "ERROR should have been caught")
		out("self-test tube banded along its run: longest clear run %.0f mm -> %s", b, b <= RUN and "ok" or "ERROR should have passed")
		bench:Destroy()
	end)
	if not ok then
		out("ERROR self-test crashed: %s", tostring(err))
	end
end

selfTest()

local folder = Instance.new("Folder")
folder.Name = "BRR_FloatingTube"
folder.Parent = workspace

local flagged, checked = 0, 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(GunModels.Build, def, Rarity.Color(def.rarity), Enum.Material.Metal, {})
	if not ok or not model then
		out("%s: build failed: %s", id, tostring(model))
	else
		model.Parent = folder
		local nodes = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.Transparency < 1 then
				table.insert(nodes, nodeOf(d))
			end
		end
		local origin = model:GetPivot()
		for _, node in ipairs(nodes) do
			if node.cyl and not SKIP[node.name] and alongBore(node) and node.half.X * 2 / MM >= LONG then
				local local_ = origin:ToObjectSpace(node.cframe).Position
				if math.abs(local_.Y) / MM > OFF_BORE or math.abs(local_.X) / MM > OFF_BORE then
					checked += 1
					local others = {}
					for _, other in ipairs(nodes) do
						if other ~= node then
							table.insert(others, other)
						end
					end
					local run = longestClearRun(node, others)
					if run > RUN then
						flagged += 1
						out("%-22s %-18s %3.0f mm long, %3.0f mm of it with nothing under it -> FLOATING TUBE",
							id, node.name, node.half.X * 2 / MM, run)
					end
				end
			end
		end
		model:Destroy()
	end
	task.wait()
end

folder:Destroy()
out("%d tubes off the bore line checked on %d guns: %d float", checked, #ids, flagged)
out("done")
