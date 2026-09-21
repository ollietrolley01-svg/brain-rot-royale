-- Probe for tools/runtest.ps1 -Probe: do swinging mechanisms turn about the right axes?
--
-- A swing's pivot turns about its OWN X axis (Viewmodel:groupTransform), so a cylinder or a crane whose
-- pivot isn't laid along the bore tumbles end over end instead of turning. For every gun with a "crane"
-- or "drum" pivot this poses the real viewmodel and prints, in the gun's own millimetres:
--   * at rest: the cylinder's centre and axis;
--   * halfway through the reload (crane fully out): the same, which should be moved sideways with the
--     axis still along Z (|axis.Z| near 1);
--   * after one shot, settled: the axis again (still along Z), and how far a flute turned about it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local MM = GunModels.StudsPerMillimetre

local function out(fmt, ...)
	-- A merged gallery run sets the prefix to "[BRR_Gallery] note " so its log echoes these.
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local function describe(vm, part)
	local cf = vm.frame:ToObjectSpace(part.CFrame)
	local axis = cf.RightVector -- a cylinder's length runs along its X
	return cf.Position / MM, axis
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local eye = CFrame.new(0, 7000, 0)
local bad = 0
local checked = 0
-- Self-test first: the first revolver again with its pivots stripped of their rotation (the way the
-- builder had them), which must come out TUMBLES.
local selfTestId
for _, id in ipairs(ids) do
	if WeaponData.Get(id).style == "revolver" then
		selfTestId = id
		break
	end
end
if selfTestId then
	table.insert(ids, 1, "SELFTEST")
end
for _, entry in ipairs(ids) do
	local selfTest = entry == "SELFTEST"
	local id = selfTest and selfTestId or entry
	local def = WeaponData.Get(id)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if ok and vm and selfTest then
		for _, group in ipairs({ "drum", "crane" }) do
			if vm.pivots[group] then
				vm.pivots[group] = CFrame.new(vm.pivots[group].Position)
			end
		end
		id = "SELFTEST(" .. id .. ", unrotated pivots)"
	end
	if ok and vm and (vm.pivots.crane or vm.pivots.drum) then
		checked += 1
		vm.model.Parent = workspace
		local drum = vm.model:FindFirstChild("Drum") or vm.model:FindFirstChild("DrumAxle")
		local flute = vm.model:FindFirstChild("DrumFlute") or vm.model:FindFirstChild("DrumTube")
		if not drum then
			out("%s: no Drum/DrumAxle part", id)
		else
			vm:Pose(eye, { aim = 0 })
			local restPos, restAxis = describe(vm, drum)
			local flutePos0 = flute and vm.frame:ToObjectSpace(flute.CFrame).Position / MM
			vm:Pose(eye, { aim = 0, clip = "reload", progress = 0.45, roundsLeft = 0, magSize = def.magSize })
			local outPos, outAxis = describe(vm, drum)
			-- One shot, then let the cylinder's turn settle.
			vm:Pose(eye, { aim = 0 })
			vm:Fire(math.max(0, (def.magSize or 6) - 1))
			for _ = 1, 40 do
				vm:Update(1 / 60, { camera = eye, aiming = false, sway = false, speed = 0, grounded = true })
			end
			local _, firedAxis = describe(vm, drum)
			local turned = 0
			if flute and flutePos0 then
				local flutePos1 = vm.frame:ToObjectSpace(flute.CFrame).Position / MM
				local a0 = flutePos0 - restPos
				local a1 = flutePos1 - restPos
				local d = math.atan2(a1.Y, a1.X) - math.atan2(a0.Y, a0.X)
				turned = math.deg((d + math.pi) % (2 * math.pi) - math.pi)
			end
			local moved = (outPos - restPos)
			local fine = math.abs(restAxis.Z) > 0.99 and math.abs(outAxis.Z) > 0.99 and math.abs(firedAxis.Z) > 0.99
			if selfTest then
				out("self-test %s: the unrotated pivots %s", fine and "FAILED" or "ok", fine and "passed (the probe can't see a tumble)" or "tumble, as they must")
			elseif not fine then
				bad += 1
			end
			out("%s %s: rest centre (%.1f, %.1f, %.1f) axis (%.2f, %.2f, %.2f) | reload centre (%.1f, %.1f, %.1f) moved (%.1f, %.1f, %.1f) axis (%.2f, %.2f, %.2f) | after a shot axis (%.2f, %.2f, %.2f), flute turned %.0f deg",
				fine and "ok" or "TUMBLES", id, restPos.X, restPos.Y, restPos.Z, restAxis.X, restAxis.Y, restAxis.Z,
				outPos.X, outPos.Y, outPos.Z, moved.X, moved.Y, moved.Z, outAxis.X, outAxis.Y, outAxis.Z,
				firedAxis.X, firedAxis.Y, firedAxis.Z, turned)
		end
		vm:Destroy()
		if selfTest then
			checked -= 1
		end
	elseif ok and vm then
		vm:Destroy()
	end
end
out("mechanisms: %d guns with a crane or drum pivot, %d with an axis off the bore", checked, bad)

-- Break actions open DOWNWARD: the muzzles drop and the breech rises off the standing breech. Measured on
-- the barrels themselves (the parts riding the hinge group), at rest and halfway through the reload.
local breakGuns, breakBad = 0, 0
local function hingeSwing(id, flip)
	local def = WeaponData.Get(id)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if not ok or not vm or not vm.pivots.hinge then
		if ok and vm then
			vm:Destroy()
		end
		return nil
	end
	if flip then
		vm.swing.hinge = -vm.swing.hinge
	end
	vm.model.Parent = workspace
	-- The barrel end: the hinge-group part furthest forward.
	local tip
	for _, part in ipairs(vm.model:GetDescendants()) do
		if part:IsA("BasePart") and part:GetAttribute("Anim") == "hinge" and (not tip or part.Position.Z < tip.Position.Z) then
			tip = part
		end
	end
	local result
	if tip then
		vm:Pose(eye, { aim = 0 })
		local rest = vm.frame:ToObjectSpace(tip.CFrame).Position
		vm:Pose(eye, { clip = "reload", progress = 0.45, roundsLeft = 0, magSize = def.magSize })
		local open = vm.frame:ToObjectSpace(tip.CFrame).Position
		result = { drop = (open.Y - rest.Y) / MM, part = tip.Name }
	end
	vm:Destroy()
	return result
end
for _, id in ipairs(ids) do
	if id ~= "SELFTEST" then
		local measured = hingeSwing(id, false)
		if measured then
			breakGuns += 1
			local opens = measured.drop < -20
			if not opens then
				breakBad += 1
			end
			out("%s %s: the barrels (%s) move %.0f mm %s as they open (want down)", opens and "ok" or "OPENS UPWARD",
				id, measured.part, math.abs(measured.drop), measured.drop < 0 and "down" or "up")
		end
	end
end
-- Self-test: the same gun with its hinge swung the other way has to come out as opening upward.
for _, id in ipairs(ids) do
	if id ~= "SELFTEST" then
		local flipped = hingeSwing(id, true)
		if flipped then
			out("self-test %s: hinge reversed on %s moves the barrels %.0f mm %s (want up)",
				flipped.drop > 20 and "ok" or "FAILED", id, math.abs(flipped.drop), flipped.drop < 0 and "down" or "up")
			break
		end
	end
end
out("break actions: %d guns, %d opening the wrong way", breakGuns, breakBad)
out("done")
