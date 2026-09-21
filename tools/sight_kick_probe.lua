-- Probe for tools/runtest.ps1 -Probe: does the gun cover the crosshair while it is being fired?
--
-- claude-3b's ads_hands_probe reported two guns swinging a front sight post over the crosshair mid-clip.
-- This asks the same question a different way, so that agreement means something: it poses the real
-- viewmodel against a fixed camera and fires the crosshair's own ray -- straight down the camera's look
-- axis -- at the gun's parts, reporting what it meets and how far off the axis the front sight hardware
-- sits in degrees. Aimed, the sight belongs ON the axis (that is how you aim); what does not belong there
-- is the post below it, or a receiver, or a hand.
--
-- Poses: aimed at rest, and aimed at the peak of a shot, which is where the kick has moved the gun most.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/sight_kick_probe.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local Viewmodel = require(scripts:WaitForChild("Viewmodel"))

local MM = GunModels.StudsPerMillimetre
-- Sight hardware is meant to be near the axis; anything else on it is worth naming.
local SIGHT_NAMES = {
	FrontSight = true, FrontBead = true, SightDot = true, SightLens = true, SightReticle = true,
	ScopeLens = true, ScopeReticle = true, ScopeTube = true, Scope = true, ScopeEyepiece = true,
}

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local function nodeOf(part)
	return { part = part, name = part.Name, inverse = part.CFrame:Inverse(), half = part.Size / 2 }
end

-- Where a ray enters a part, in studs along the ray, or nil. Boxes exactly; a cylinder or ball counts as
-- its box, which can only report a hit slightly early -- the safe way to be wrong for "is it in the way".
local function rayEnters(node, origin, direction)
	local o = node.inverse * origin
	local d = node.inverse:VectorToObjectSpace(direction)
	local near, far = -math.huge, math.huge
	local os = { o.X, o.Y, o.Z }
	local ds = { d.X, d.Y, d.Z }
	local hs = { node.half.X, node.half.Y, node.half.Z }
	for axis = 1, 3 do
		if math.abs(ds[axis]) < 1e-9 then
			if math.abs(os[axis]) > hs[axis] then
				return nil
			end
		else
			local t1 = (-hs[axis] - os[axis]) / ds[axis]
			local t2 = (hs[axis] - os[axis]) / ds[axis]
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			near = math.max(near, t1)
			far = math.min(far, t2)
			if near > far then
				return nil
			end
		end
	end
	return far >= 0 and math.max(near, 0) or nil
end

-- Self-test: a box planted on the axis must be found, one planted two widths off it must not, and the
-- reported angle of a box a known height above the axis must match the height it was planted at.
local function selfTest()
	local ok, err = pcall(function()
		local bench = Instance.new("Folder")
		bench.Name = "BRR_SightKickSelfTest"
		bench.Parent = workspace
		local origin, direction = Vector3.new(0, 9000, 0), Vector3.new(0, 0, -1)
		local function box(offset)
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(0.2, 0.2, 0.2)
			part.CFrame = CFrame.new(origin + Vector3.new(0, 0, -2) + offset)
			part.Parent = bench
			return nodeOf(part)
		end
		local on = rayEnters(box(Vector3.zero), origin, direction)
		local off = rayEnters(box(Vector3.new(0.4, 0, 0)), origin, direction)
		local high = box(Vector3.new(0, 0.1, 0))
		local angle = math.deg(math.atan2(0.1, 2))
		out("self-test on the axis: enters at %s (want about 1.9) -> %s",
			on and string.format("%.2f", on) or "none", (on and math.abs(on - 1.9) < 0.05) and "ok" or "ERROR")
		out("self-test two widths off: %s -> %s", off and string.format("%.2f", off) or "none",
			off == nil and "ok" or "ERROR should have missed")
		local measured = math.deg(math.atan2((CFrame.new(origin) :PointToObjectSpace(high.part.Position)).Y,
			-(CFrame.new(origin):PointToObjectSpace(high.part.Position)).Z))
		out("self-test angle of a box 0.1 up at 2 away: %.2f deg (want %.2f) -> %s", measured, angle,
			math.abs(measured - angle) < 0.05 and "ok" or "ERROR")
		bench:Destroy()
	end)
	if not ok then
		out("ERROR self-test crashed: %s", tostring(err))
	end
end

selfTest()

local folder = Instance.new("Folder")
folder.Name = "BRR_SightKick"
folder.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local eye = CFrame.new(0, 7000, 0)
local poses = {
	{ "ads", { aim = 1 } },
	{ "ads+fire", { aim = 1, clip = "fire", progress = 0.5, roundsLeft = 5 } },
}

local problems = 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if not ok or not vm then
		out("%s: Viewmodel.new failed: %s", id, tostring(vm))
	else
		vm.model.Parent = folder
		for _, pose in ipairs(poses) do
			local posed = pcall(vm.Pose, vm, eye, pose[2])
			if not posed then
				out("%s %s: Pose failed", id, pose[1])
			else
				local arms = vm.model:FindFirstChild("Arms")
				local hit, hitAt, sightAngle, sightName
				for _, d in ipairs(vm.model:GetDescendants()) do
					if d:IsA("BasePart") and d.Transparency < 0.5 then
						local node = nodeOf(d)
						local at = rayEnters(node, eye.Position, eye.LookVector)
						if at and (not hitAt or at < hitAt) then
							local onArm = arms and d:IsDescendantOf(arms)
							hit, hitAt = (onArm and "hand:" or "") .. d.Name, at
						end
						if d.Name == "FrontSight" or d.Name == "FrontSightPost" or d.Name == "FrontBead" then
							local top = (d.CFrame * CFrame.new(0, d.Size.Y / 2, 0)).Position
							local p = eye:PointToObjectSpace(top)
							local angle = math.deg(math.atan2(p.Y, -p.Z))
							if not sightAngle or math.abs(angle) < math.abs(sightAngle) then
								sightAngle, sightName = angle, d.Name
							end
						end
					end
				end
				-- Sight hardware on the axis is the sight picture working. Anything else on it is the gun
				-- standing in front of what the player is shooting at.
				local blocking = hit and not SIGHT_NAMES[string.gsub(hit, "^hand:", "")]
				if blocking then
					problems += 1
				end
				out("%-22s %-8s crosshair %-22s %8s, %s top %s deg -> %s", id, pose[1],
					hit or "clear", hitAt and string.format("%.3f st", hitAt) or "",
					sightName or "no front sight", sightAngle and string.format("%+.2f", sightAngle) or "n/a",
					blocking and "BLOCKED" or "clear")
			end
		end
		vm:Destroy()
	end
	task.wait()
end

folder:Destroy()
out("%d guns, %d poses with something other than sight hardware on the crosshair", #ids, problems)
out("done")
