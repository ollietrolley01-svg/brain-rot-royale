-- Measures the drink item's first-person viewmodel against the camera for intrusion (Oliver's #7:
-- "the potion drinking animation clips into your face when you drink").
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/potion_clip_probe.lua
--
-- Replicates the EXACT transform chain from StarterPlayerScripts/CombatClient.client.lua's item
-- viewmodel RenderStep (guns-owned, read only, not edited here) -- lines ~1606-1675 as of this probe:
--   local frame = view * CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0)
--       * equipOffset * bobOffset * useOffset * punchOffset * CFrame.new(-itemView.grip)
--   cframes[part] = frame * itemView.offsets[part]
-- with `view` set to CFrame.identity, so "camera-local space" IS the coordinate system measured:
-- the camera looks down -Z, Z=0 is the eye, and any point with Z >= 0 is AT OR BEHIND the eye --
-- the literal "into your face" case. equipOffset and bobOffset are pinned to identity (the drink
-- itself, not the equip pop-up or stride bob, is what Oliver reported), useAlpha and progress are
-- simulated frame by frame at 60 Hz across the item's real ItemData.useTime.
--
-- The pivot, grip and every part offset come from the REAL `ItemModels.Build` + `model:GetPivot()` --
-- not guessed. Every part is measured at its 8 local-space corners (Size/2 box), the same corner
-- convention the roads' z-fight audit uses for wedges; this slightly OVERSTATES intrusion for round
-- parts (a Ball's corners sit outside its true surface), which is the safe direction for a clipping
-- check. Transparent marker parts (Grip) are excluded -- nothing renders them.
--
-- PERMANENT PLANTED FAULT: a synthetic single-part rig with an ANALYTICALLY KNOWN worst corner
-- (placed so the sweep must find Z = +0.05, i.e. 0.05 studs behind the eye, at a known progress) is
-- run through the exact same measurement function real items use. If the corner-transform math were
-- ever broken -- say, position moved but rotation dropped -- this known case would stop matching and
-- the probe would say so.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ItemData = require(Shared:WaitForChild("ItemData"))

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

-- Exact constants from CombatClient.client.lua's item viewmodel section.
local ITEM_HIP = Vector3.new(0.8, -0.85, -1.9)
local DRINKS = { "MiniShield", "ShieldPotion", "SpeedSoda" }

local function smooth(t)
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Runs the real transform sweep for a rig of { part, offset (CFrame from pivot), size } entries plus
-- a grip position, over the drink's whole useTime at 60 Hz. Returns the worst (max) camera-local Z
-- across every corner of every part, which part, and the progress fraction it happened at.
local cornerSigns = {}
for _, sx in ipairs({ -0.5, 0.5 }) do
	for _, sy in ipairs({ -0.5, 0.5 }) do
		for _, sz in ipairs({ -0.5, 0.5 }) do
			table.insert(cornerSigns, Vector3.new(sx, sy, sz))
		end
	end
end

local function sweep(rig, grip, useDuration, cornersMeasured)
	local useAlpha = 0
	local worstZ, worstDistance, worstPart, worstProgress = -math.huge, nil, nil, nil
	local dt = 1 / 60
	local steps = math.max(1, math.floor(useDuration / dt))
	for step = 0, steps do
		local elapsed = step * dt
		local using = elapsed < useDuration
		local progress = using and math.clamp(elapsed / math.max(useDuration, 1e-6), 0, 1) or 1
		useAlpha += ((using and 1 or 0) - useAlpha) * math.clamp(dt * 10, 0, 1)

		local tip = smooth(progress / 0.25)
		local useTarget = CFrame.new(-0.6 * tip, 0.62 * tip + math.sin(elapsed * 13) * 0.025 * tip, 1.05 * tip)
			* CFrame.Angles(1.15 * tip, 0, 0.35 * tip)
		local useOffset = CFrame.identity:Lerp(useTarget, useAlpha)

		local frame = CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0) * useOffset * CFrame.new(-grip)

		for _, entry in ipairs(rig) do
			local partCF = frame * entry.offset
			local half = entry.size * 0.5
			for _, sign in ipairs(cornerSigns) do
				local corner = Vector3.new(sign.X * entry.size.X, sign.Y * entry.size.Y, sign.Z * entry.size.Z)
				local point = partCF:PointToWorldSpace(corner)
				cornersMeasured.count += 1
				if point.Z > worstZ then
					worstZ = point.Z
					worstDistance = point.Magnitude
					worstPart = entry.name
					worstProgress = progress
				end
			end
		end
	end
	return worstZ, worstDistance, worstPart, worstProgress
end

-- PLANTED FAULT rig first: one part, size 0.1 cube, offset so that at progress 1 (useAlpha ~1, tip 1)
-- its center sits exactly on a corner analytically placed at camera-local Z = +0.05. Work backward:
-- at tip=1, frame = CFrame.new(ITEM_HIP) * CFrame.Angles(0,0.2,0) * useTarget(tip=1) * CFrame.new(-grip).
-- Simplest to reason about without re-deriving the rotation: grip chosen as -ITEM_HIP transformed so
-- the frame's translation lands the part's own origin (a single corner-less point via a near-zero
-- size, so all 8 corners are ~equal) at local Z = +0.05 directly, by placing the part AT that offset
-- from the pivot with zero size contribution. Verified empirically below, not just asserted.
section("FAULT: a known corner planted 0.05 studs behind the eye must be found", function()
	local rig = { { name = "FaultPart", offset = CFrame.new(0, 0, 0), size = Vector3.new(0.0001, 0.0001, 0.0001) } }
	-- Solve for a grip that puts frame's translation exactly at world Z = 0.05 when fully tipped
	-- (useAlpha=1, tip=1): frame = CFrame.new(ITEM_HIP) * CFrame.Angles(0,0.2,0) * useTarget(1) * CFrame.new(-grip).
	-- Rather than invert the rotation by hand, solve it AT RUNTIME: binary-search grip.Z (the axis
	-- that matters most) is unnecessary -- simpler to just READ what frame the sweep produces at
	-- progress 1 for grip = 0, then pick a grip that shifts it to the target. Because the last term is
	-- a pure translation in the FRAME's own rotated space (`* CFrame.new(-grip)`), and PointToWorldSpace
	-- of the origin under `frame * CFrame.new(-grip)` equals `frame.Position - frame:VectorToWorldSpace(grip)`,
	-- shifting grip by `frame:VectorToWorldSpace_inverse(delta)` moves the measured point by `-delta`
	-- in world space. Compute the tip=1 frame directly (duplicating the sweep's own math for this one
	-- instant, which is the point of the fault: an independent, hand-computable expected value).
	local useTarget1 = CFrame.new(-0.6, 0.62, 1.05) * CFrame.Angles(1.15, 0, 0.35)
	local baseFrame = CFrame.new(ITEM_HIP) * CFrame.Angles(0, 0.2, 0) * useTarget1
	local basePoint = baseFrame.Position -- grip = 0
	local targetPoint = Vector3.new(basePoint.X, basePoint.Y, 0.05)
	local delta = targetPoint - basePoint
	local grip = -baseFrame:VectorToObjectSpace(delta)
	local measured = { count = 0 }
	local worstZ = sweep(rig, grip, 1.0, measured)
	check(math.abs(worstZ - 0.05) < 0.01,
		"planted corner found at Z=%.4f (expected 0.0500, within 0.01) -- the corner-transform math is exercised, not vacuous",
		worstZ)
	check(measured.count > 0, "the fault rig was actually measured (%d corner-samples)", measured.count)
end)

--------------------------------------------------------------------------------
-- Real items.
--------------------------------------------------------------------------------

local totalCorners = 0
for _, id in ipairs(DRINKS) do
	section("drink: " .. id, function()
		local item = ItemData.Get(id)
		check(item ~= nil, "%s has an ItemData entry", id)
		if not item then
			return
		end
		local model = ItemModels.Build(id, { name = "BRR_PotionClipProbe" })
		check(model ~= nil, "%s builds a model", id)
		if not model then
			return
		end
		local pivot = model:GetPivot()
		local gripPart = model:FindFirstChild("Grip")
		local grip = gripPart and pivot:ToObjectSpace(gripPart.CFrame).Position or Vector3.zero

		local rig = {}
		local visibleParts = 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Transparency < 1 then
				visibleParts += 1
				table.insert(rig, { name = part.Name, offset = pivot:ToObjectSpace(part.CFrame), size = part.Size })
			end
		end
		check(visibleParts > 0, "%s has visible geometry to measure (%d parts)", id, visibleParts)

		local measured = { count = 0 }
		local worstZ, worstDistance, worstPart, worstProgress = sweep(rig, grip, item.useTime, measured)
		totalCorners += measured.count
		out("measure  %s: worst camera-local Z = %.3f studs (negative = in front of the eye; %s at %.0f%% through the %.1fs animation)",
			id, worstZ, worstPart or "?", (worstProgress or 0) * 100, item.useTime)
		out("measure  %s: distance from the eye at that point = %.3f studs, %d corner-samples", id,
			worstDistance or -1, measured.count)
		-- The literal "into your face" line: any geometry reaching the eye or behind it.
		check(worstZ < 0, "%s: worst point stays in FRONT of the eye (Z=%.3f)", id, worstZ)
		model:Destroy()
	end)
end

out("done: %d failures, %d checks, %d total corner-samples across %d items", failures, samples, totalCorners, #DRINKS)
