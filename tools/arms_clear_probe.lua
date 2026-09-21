-- Probe for tools/runtest.ps1 -Probe: do the viewmodel's arms stay out of the crosshair and the sights?
--
-- Poses every gun's viewmodel the way the game does (Viewmodel:Pose) at the hip, fully aimed, and
-- aimed part way through a shot's clip, then traces rays from the eye against the arms' parts (their
-- exact boxes; a mesh sits inside its box, so a miss is certain and a hit is at worst a near miss):
-- the centre ray, 24 rays on a 1° ring and 24 on a 2.5° ring. Nothing of either arm should touch any of
-- them. With no avatar in edit mode the arms are the plain stand-in blocks, the same size as a real
-- avatar's arms in the viewmodel.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/arms_clear_probe.lua -WaitSeconds 300

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local RINGS = { { 0, 1 }, { 1, 24 }, { 2.5, 24 } }
local POSES = {
	{ "hip", { aim = 0 } },
	{ "ads", { aim = 1 } },
	{ "adsFire", { aim = 1, clip = "fire", progress = 0.3, roundsLeft = 5 } },
}

local function out(text)
	print("[PROBE] " .. text)
end

-- Where a ray first enters a box, or nil.
local function hitBox(part, origin, direction)
	local o = part.CFrame:PointToObjectSpace(origin)
	local d = part.CFrame:VectorToObjectSpace(direction)
	local h = part.Size / 2
	local t0, t1 = 0, 1e6
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local oi, di, hi = o[axis], d[axis], h[axis]
		if math.abs(di) < 1e-9 then
			if math.abs(oi) > hi then
				return nil
			end
		else
			local a, b = (-hi - oi) / di, (hi - oi) / di
			t0 = math.max(t0, math.min(a, b))
			t1 = math.min(t1, math.max(a, b))
			if t0 > t1 then
				return nil
			end
		end
	end
	return t0
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local folder = Instance.new("Folder")
folder.Name = "ArmsClearProbe"
folder.Parent = workspace
local eye = CFrame.new(0, 2000, 0)
local bad = 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if not ok then
		out(id .. ": viewmodel failed: " .. tostring(vm))
	else
		vm.model.Parent = folder
		local report = {}
		local offenders = {}
		local clean = true
		for _, pose in ipairs(POSES) do
			local state = table.clone(pose[2])
			state.magSize = def.magSize
			vm:Pose(eye, state)
			local counts = {}
			for _, ring in ipairs(RINGS) do
				local hits = 0
				for index = 1, ring[2] do
					local around = (index - 1) / ring[2] * math.pi * 2
					local tilt = math.rad(ring[1])
					local direction = (eye * CFrame.Angles(0, 0, around) * CFrame.Angles(tilt, 0, 0)).LookVector * 60
					local hit = false
					for _, part in ipairs(vm.arms.parts) do
						if hitBox(part, eye.Position, direction) then
							hit = true
							offenders[pose[1] .. " " .. part.Name] = true
						end
					end
					if hit then
						hits += 1
					end
				end
				table.insert(counts, string.format("%d/%d", hits, ring[2]))
				if hits > 0 then
					clean = false
				end
			end
			table.insert(report, pose[1] .. " " .. table.concat(counts, " "))
		end
		-- Self-test, so a clean result means something: a ray straight at each arm part's centre must hit
		-- it, and the nearest arm part to the view centre is reported (degrees off centre, fully aimed).
		vm:Pose(eye, { aim = 1, magSize = def.magSize })
		local selfTest, nearest, nearestName = true, math.huge, "?"
		for _, part in ipairs(vm.arms.parts) do
			local toward = part.Position - eye.Position
			if not hitBox(part, eye.Position, toward.Unit * 60) then
				selfTest = false
			end
			local local_ = eye:VectorToObjectSpace(toward)
			local off = math.deg(math.acos(math.clamp(-local_.Unit.Z, -1, 1)))
			local reach = math.deg(math.atan2(part.Size.Magnitude / 2, toward.Magnitude))
			if off - reach < nearest then
				nearest, nearestName = off - reach, part.Name
			end
		end
		table.insert(report, string.format("self-test %s, nearest arm part at ADS about %.1f deg off centre (%s)",
			selfTest and "ok" or "FAILED", nearest, nearestName))
		local names = {}
		for name in pairs(offenders) do
			table.insert(names, name)
		end
		table.sort(names)
		if not clean then
			bad += 1
		end
		out(string.format("%s %s: %s%s", clean and "clean" or "BLOCKED", id, table.concat(report, " | "),
			#names > 0 and (" <- " .. table.concat(names, ", ")) or ""))
		vm:Destroy()
	end
end
folder:Destroy()
out(string.format("%d of %d guns have an arm in the centre, 1° or 2.5° rays (want 0)", bad, #ids))
out("done")
