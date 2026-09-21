-- Probe for tools/runtest.ps1 -Probe: where do the sights go while you hold the trigger, aimed?
--
-- Draws every gun's viewmodel the way the game does, fully aimed at a fixed camera (the camera's own
-- recoil is left out: the viewmodel rides the camera, so that moves the whole sight picture together),
-- then runs the viewmodel at 60 fps while firing at the gun's fire rate for up to a second (or a
-- magazine), and on for 0.8 s after the last shot. Every frame it measures, in degrees off the centre
-- of the view:
--   * front: the point you aim with (the front post's top, the bead, the dot) -- where the shot goes,
--     so this is the one that must hold;
--   * rear: the sight keypoint (the rear aperture, notch or eyepiece);
--   * apart: the angle between the two, how far out of line the sights are thrown;
-- and how long after the last shot both are back within 0.05°.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/recoil_probe.lua -WaitSeconds 300

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local DT = 1 / 60
local FIRE_SECONDS = 1
local SETTLE_SECONDS = 0.8
local SETTLED = 0.05
-- Worth a look above these (degrees).
local FRONT_LIMIT = 0.35
local APART_LIMIT = 2.5

local function out(text)
	-- A merged gallery run sets the prefix to "[BRR_Gallery] note " so its log echoes these.
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. text)
end

local eye = CFrame.new(0, 6000, 0)

-- Degrees off the view's centre line, and the screen direction (right, up) of a world point.
local function offCentre(point)
	local p = eye:PointToObjectSpace(point)
	local depth = math.max(-p.Z, 1e-6)
	local x, y = math.deg(math.atan2(p.X, depth)), math.deg(math.atan2(p.Y, depth))
	return math.sqrt(x * x + y * y), x, y
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local folder = Instance.new("Folder")
folder.Name = "BRR_RecoilProbe"
folder.Parent = workspace

local flagged = 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	math.randomseed(7)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if not ok or not vm then
		out(string.format("FAILED %s: Viewmodel.new: %s", id, tostring(vm)))
		flagged += 1
		continue
	end
	vm.model.Parent = folder
	vm:Pose(eye, { aim = 1, magSize = def.magSize })

	local sight = vm.keys.Sight
	local interval = 1 / math.max(def.fireRate or 1, 0.1)
	local shots = math.max(1, math.min(def.magSize or 1, math.floor(FIRE_SECONDS / interval) + 1))
	local input = { camera = eye, aiming = true, sway = false, speed = 0, grounded = true }

	local frontMax, rearMax, apartMax = 0, 0, 0
	local frontSum, apartSum, samples = 0, 0, 0
	local frontUp = 0
	local fired, nextShot, lastShot = 0, 0, 0
	local settledAt = nil
	local t = 0
	local okRun, err = pcall(function()
		while t < shots * interval + SETTLE_SECONDS do
			if fired < shots and t >= nextShot then
				fired += 1
				vm:Fire(math.max(0, (def.magSize or shots) - fired))
				lastShot = t
				nextShot += interval
			end
			vm:Update(DT, input)
			t += DT
			if vm.frame and sight then
				local frontPoint = vm.frame * vm.aimPivot
				local rearPoint = vm.frame * sight.Position
				local front, fx, fy = offCentre(frontPoint)
				local rear, rx, ry = offCentre(rearPoint)
				local apart = math.sqrt((fx - rx) ^ 2 + (fy - ry) ^ 2)
				if fired < shots or t - lastShot < interval then
					frontMax = math.max(frontMax, front)
					rearMax = math.max(rearMax, rear)
					apartMax = math.max(apartMax, apart)
					frontUp = math.max(frontUp, fy)
					frontSum += front
					apartSum += apart
					samples += 1
					settledAt = nil
				elseif front < SETTLED and rear < SETTLED then
					settledAt = settledAt or (t - lastShot)
				else
					settledAt = nil
				end
			end
		end
	end)
	if not okRun then
		out(string.format("FAILED %s: %s", id, tostring(err)))
		flagged += 1
	else
		local bad = frontMax > FRONT_LIMIT or apartMax > APART_LIMIT or settledAt == nil
		if bad then
			flagged += 1
		end
		out(string.format("%s %s (%s, %s, %d shots at %.1f/s): front max %.2f° mean %.2f° (up %.2f°) | rear max %.2f° | apart max %.2f° mean %.2f° | settled %s",
			bad and "LOOK" or "ok", id, tostring(def.style), tostring(vm.action), shots, def.fireRate or 0,
			frontMax, samples > 0 and frontSum / samples or 0, frontUp, rearMax, apartMax, samples > 0 and apartSum / samples or 0,
			settledAt and string.format("%.2fs after", settledAt) or "NEVER"))
	end
	vm:Destroy()
end
folder:Destroy()
out(string.format("%d of %d guns over front %.2f° / apart %.1f° or never settling", flagged, #ids, FRONT_LIMIT, APART_LIMIT))
out("done")
