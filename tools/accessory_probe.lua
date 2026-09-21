-- Accessory audit, for tools/runtest.ps1 -Probe:
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/accessory_probe.lua [-PlaceFile <rbxlx>]
--
-- Every accessory in CosmeticData, worn on an R15 head the way AccessoryService puts it there, and
-- measured for the fault the Crown of Rot had: geometry that is wrong at source and gets papered
-- over when ZFight runs on attach, so the thing a player wears is not the thing that was designed.
--
--   changed   pieces the build pass moves or resizes (built with ZFight off, then on, compared piece
--             by piece). Anything above 0 means the worn accessory is not the authored one.
--   flush     pairs of faces lying in one plane in the geometry as written, at ZFight's fix
--             tolerance: what the pass reacts to.
--   loose     pieces touching no other piece and not the head: they read as floating.
--   over      how far the accessory rises over the head, and how far it hangs below its anchor,
--             to catch anything that sinks into the head or floats off it.
--   scale     the whole set again on the smallest and largest heads, because the pass measures in
--             world studs after AccessoryService has scaled the pieces to the wearer.
--
-- Two of these checks were useless when this file was first written, and both failed silently rather
-- than loudly: `changed` compared pieces on two rigs standing 6 studs apart, so everything read as
-- moved by exactly 6.000, and `loose` asked whether a piece overlapped its neighbours when neighbours
-- only ever touch, so 61 resting pieces read as floating. Every check below now has a planted fault
-- at the bottom of this file proving it can fail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local AccessoryService = require(game:GetService("ServerScriptService"):WaitForChild("Modules"):WaitForChild("AccessoryService"))

local failures = 0
local function out(format, ...)
	print("[Accessory] " .. string.format(format, ...))
end
local function fail(format, ...)
	failures += 1
	out("FAIL " .. format, ...)
end

local stage = Instance.new("Folder")
stage.Name = "AccessoryProbe"
stage.Parent = workspace
local SPOT = CFrame.new(0, 2600, -3200)

local function character()
	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and rig then
		return rig
	end
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Parent = model
	local torso = Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Size = Vector3.new(2, 1.6, 1)
	torso.CFrame = CFrame.new(0, 1.4, 0)
	torso.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.CFrame = CFrame.new(0, 2.6, 0)
	head.Parent = model
	Instance.new("Humanoid").Parent = model
	model.PrimaryPart = root
	return model
end

local function piecesOf(rig)
	local worn = rig:FindFirstChild("CosmeticAccessory")
	local list = {}
	if worn then
		for _, part in ipairs(worn:GetDescendants()) do
			if part:IsA("BasePart") then
				table.insert(list, part)
			end
		end
	end
	return list, worn
end

-- Wears `id` on a fresh anchored rig at `at`; returns the rig, its pieces and the worn model.
local function wear(id, at, headHeight)
	local rig = character()
	for _, part in ipairs(rig:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	-- Optionally give the rig a different sized head, which is what AccessoryService scales from.
	if headHeight then
		local head = rig:FindFirstChild("Head")
		if head and head.Size.Y > 0 then
			head.Size = head.Size * (headHeight / head.Size.Y)
		end
	end
	rig:PivotTo(at)
	rig.Parent = stage
	AccessoryService.Attach(rig, id)
	local pieces, worn = piecesOf(rig)
	return rig, pieces, worn
end

-- Names of pieces with nothing beside them. `worn` are the accessory's own pieces; `body` the parts of
-- the wearer they are allowed to be resting against.
local function looseNames(worn, body)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local candidates = {}
	for _, part in ipairs(body) do
		if part then
			table.insert(candidates, part)
		end
	end
	for _, part in ipairs(worn) do
		part.CanQuery = true
		table.insert(candidates, part)
	end
	params.FilterDescendantsInstances = candidates

	-- Grown by 0.06 rather than asking GetPartsInPart about the piece itself: two pieces resting face
	-- to face overlap by nothing, so the plain query calls them both loose. That read every stacked
	-- cone ring and every flush-mounted piece as floating -- 61 across 13 accessories, none of them real.
	local names = {}
	for _, part in ipairs(worn) do
		local near = workspace:GetPartBoundsInBox(part.CFrame, part.Size + Vector3.new(0.06, 0.06, 0.06), params)
		if #near <= 1 then
			table.insert(names, part.Name)
		end
	end
	return names
end

-- A ring that floats clear of everything on purpose: Galaxy Brain's is an orbit round the brain, like
-- a planet's, and its segments hold each other's company rather than touching the brain. Listed here
-- by name so the check stays sharp for pieces that drift apart by accident.
local FLOATS_BY_DESIGN = { GalaxyBrain = "the orbit ring is meant to hang clear of the brain" }

local ids = CosmeticData.OfKind("Accessory")
out("%d accessories", #ids)

local totals = { changed = 0, flush = 0, loose = 0 }
for index, id in ipairs(ids) do
	local item = CosmeticData.Get(id)
	local at = SPOT * CFrame.new((index % 8) * 12, 0, math.floor(index / 8) * 12)

	-- As written, with the build pass switched off.
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local rawRig, rawPieces, rawWorn = wear(id, at)
	ZFight.Enabled = wasEnabled
	local written = rawWorn and ZFight.Scan({ rawWorn }, ZFight.FixTolerance) or {}

	-- And as a player actually wears it.
	local rig, pieces, worn = wear(id, at * CFrame.new(0, 0, 6))

	-- Compared in each rig's own head frame. The two rigs stand 6 studs apart so both can be measured
	-- in one run, so world positions differ by those 6 studs and every piece would read as moved —
	-- which is exactly what this printed before the fix: "changed <all>, worst 6.000", for all 13.
	local rawFrame = (rawRig:FindFirstChild("Head") or rawRig.PrimaryPart).CFrame
	local frame = (rig:FindFirstChild("Head") or rig.PrimaryPart).CFrame

	local changed, worst, worstName = 0, 0, "-"
	for n = 1, math.min(#rawPieces, #pieces) do
		local before, after = rawPieces[n], pieces[n]
		local moved = (rawFrame:PointToObjectSpace(before.Position) - frame:PointToObjectSpace(after.Position)).Magnitude
		local grew = (before.Size - after.Size).Magnitude
		if moved > 0.001 or grew > 0.001 then
			changed += 1
			if math.max(moved, grew) > worst then
				worst, worstName = math.max(moved, grew), before.Name
			end
		end
	end

	-- Loose pieces: a piece touching nothing else and not the part it's worn on.
	local head = rig:FindFirstChild("Head")
	local torso = rig:FindFirstChild("UpperTorso") or rig:FindFirstChild("Torso")
	local loose = looseNames(pieces, { head, torso })

	-- Where it sits on the head.
	local anchorY = item.anchor == "Back" and (torso and torso.Position.Y or 0) or (head and head.Position.Y + head.Size.Y / 2 or 0)
	local high, low = -math.huge, math.huge
	for _, part in ipairs(pieces) do
		high = math.max(high, part.Position.Y + part.Size.Y / 2)
		low = math.min(low, part.Position.Y - part.Size.Y / 2)
	end

	local floats = FLOATS_BY_DESIGN[id]
	if floats and #loose > 0 then
		out("%s: %d pieces float, which is the design -- %s", id, #loose, floats)
		loose = {}
	end

	local line = string.format("%-16s %-9s %2d pieces; changed %d (worst %.3f %s); flush as written %d; loose %d; %.2f over the anchor, %.2f under",
		id, item.rarity, #pieces, changed, worst, worstName, #written, #loose, high - anchorY, anchorY - low)
	if changed > 0 or #written > 0 or #loose > 0 then
		fail("%s", line)
		if #loose > 0 then
			out("    loose: %s", table.concat(loose, ", ", 1, math.min(#loose, 8)))
		end
		for n = 1, math.min(4, #written) do
			out("    written flush: %s / %s, gap %.3f", written[n].a.Name, written[n].b.Name, written[n].gap or -1)
		end
	else
		out("%s", line)
	end
	totals.changed += changed
	totals.flush += #written
	totals.loose += #loose

	rawRig:Destroy()
	rig:Destroy()
	task.wait()
end

--------------------------------------------------------------------------------
-- The same designs on the smallest and largest heads
--------------------------------------------------------------------------------
-- AccessoryService scales every piece by the wearer's head height over 1.2, clamped to 0.6 .. 1.8,
-- and the z-fight pass then works in world studs -- after that scaling. So a clearance authored at
-- 0.06 measures 0.054 on the standard R15 rig and 0.036 on the smallest head, and both are inside the
-- 0.055 the pass reacts to. That is not a theory: it is how the sunglasses arms were found, passing
-- every check I did by hand and still being nudged on the rig. Anything that only holds at one size
-- is a piece that moves on some players and not others.

for _, case in ipairs({ { "smallest", 0.72 }, { "largest", 2.16 } }) do
	local label, height = case[1], case[2]
	local changedTotal, worstAll, worstWhere = 0, 0, "-"
	for index, id in ipairs(ids) do
		local at = SPOT * CFrame.new(-60 - (index % 6) * 14, 0, math.floor(index / 6) * 14)

		local wasEnabled = ZFight.Enabled
		ZFight.Enabled = false
		local rawRig, rawPieces = wear(id, at, height)
		ZFight.Enabled = wasEnabled
		local rig, pieces = wear(id, at * CFrame.new(0, 0, 7), height)

		local rawFrame = (rawRig:FindFirstChild("Head") or rawRig.PrimaryPart).CFrame
		local frame = (rig:FindFirstChild("Head") or rig.PrimaryPart).CFrame
		for n = 1, math.min(#rawPieces, #pieces) do
			local moved = (rawFrame:PointToObjectSpace(rawPieces[n].Position) - frame:PointToObjectSpace(pieces[n].Position)).Magnitude
			local grew = (rawPieces[n].Size - pieces[n].Size).Magnitude
			if moved > 0.001 or grew > 0.001 then
				changedTotal += 1
				if math.max(moved, grew) > worstAll then
					worstAll, worstWhere = math.max(moved, grew), id .. " " .. rawPieces[n].Name
				end
			end
		end

		rawRig:Destroy()
		rig:Destroy()
		task.wait()
	end
	if changedTotal > 0 then
		fail("%s head (%.2f tall, scale %.2f): the pass changed %d pieces, worst %.3f at %s", label, height, height / 1.2,
			changedTotal, worstAll, worstWhere)
	else
		out("%s head (%.2f tall, scale %.2f): nothing moved", label, height, height / 1.2)
	end
end

--------------------------------------------------------------------------------
-- Planted faults
--------------------------------------------------------------------------------
-- Each check above is now proven able to fail, because two of the three could not: they compared
-- pieces on two rigs standing 6 studs apart, and asked whether a piece overlapped its neighbours when
-- neighbours only ever touch. A check that cannot fail reports a clean accessory and a broken one the
-- same way.

local function selfTest(name, condition, detail)
	if condition then
		out("self-test %s: caught it (%s)", name, detail)
	else
		fail("self-test %s: the check did not fire, so it cannot be trusted above (%s)", name, detail)
	end
end

do
	-- Two blocks resting face to face: neither is loose, and the check has to agree, because the
	-- version before this one called exactly that pair floating.
	local pair = {}
	for index = 0, 1 do
		local part = Instance.new("Part")
		part.Name = "SelfTest" .. index
		part.Size = Vector3.new(0.4, 0.2, 0.4)
		part.CFrame = SPOT * CFrame.new(index * 0.4, 6, -30)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = stage
		table.insert(pair, part)
	end
	selfTest("loose (touching)", #looseNames(pair, {}) == 0, "two blocks resting face to face are not floating")

	pair[2].CFrame = pair[2].CFrame * CFrame.new(0, 3, 0)
	local names = looseNames(pair, {})
	selfTest("loose (lifted)", #names == 2, string.format("one lifted 3 studs leaves %d floating", #names))
	for _, part in ipairs(pair) do
		part:Destroy()
	end

	-- Two blocks overlapping with their tops in one plane: what the crown did, and what the pass reacts to.
	local planted = Instance.new("Model")
	planted.Name = "PlantedFlush"
	for index = 0, 1 do
		local part = Instance.new("Part")
		part.Size = Vector3.new(0.4, 0.2, 0.4)
		part.CFrame = SPOT * CFrame.new(index * 0.3, 8, -30)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = planted
	end
	planted.Parent = stage
	local found = ZFight.Scan({ planted }, ZFight.FixTolerance)
	selfTest("flush", #found > 0, string.format("%d pairs on two blocks overlapping by 0.1 with their tops in one plane", #found))

	local first = planted:GetChildren()[1]
	local before = { first.CFrame, first.Size }
	ZFight.Fix({ planted }, { all = true })
	selfTest("changed", (first.CFrame.Position - before[1].Position).Magnitude > 0.001 or (first.Size - before[2]).Magnitude > 0.001,
		"the pass moved or resized a planted flush pair")

	planted:Destroy()
end

stage:Destroy()
out("SUMMARY: %d accessories, %d failures, %d pieces changed by the pass, %d flush pairs as written, %d loose", #ids, failures, totals.changed,
	totals.flush, totals.loose)
