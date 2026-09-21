-- Probe for tools/runtest.ps1 -Probe: do the first-person hands actually hold the gun?
--
-- ads_hands_probe answers a different question (does a hand cross the sights). This one asks whether the
-- hand is ON the gun: the real viewmodel is posed with the game's own Viewmodel module, with a default
-- R15 avatar's arms, and for each hand it measures, with the parts' true shapes:
--
--   contact  the area (mm^2) where the hand's surface lies on gun parts, sampled like gun_contact_probe;
--   gap      how far the palm's inner face is from the nearest gun surface, along the palm's normal;
--   through  gun surface points inside the hand's volume, and the deepest (a gun through a hand);
--   holds    the gun part nearest the palm and its smaller cross-section, so a 6 mm rod or a 90 mm slab
--            shows up as something a hand can't close on.
--
-- A hand counts as holding when contact >= HELD_AREA mm^2 and the gap is at most HELD_GAP mm; it reads as
-- floating past FLOAT_GAP. Poses: at the hip, aimed, and mid-clip for the actions that move something
-- under a hand (pump, bolt, lever, break, revolver), where a hand can end up inside a moving part.
--
-- With a ViewmodelBefore module beside Viewmodel in StarterPlayerScripts, every gun is measured twice,
-- before and after, so a rig change can be compared in one run.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/hand_grip_probe.lua -WaitSeconds 900

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

local MM = GunModels.StudsPerMillimetre
local EPS = 0.35 * MM
local SPACING = 2 * MM
local HELD_AREA = 250 -- mm^2
local HELD_GAP = 1 -- mm
local FLOAT_GAP = 3 -- mm
local THROUGH_DEPTH = 3 -- mm
local GRASP_MIN, GRASP_MAX = 18, 60 -- mm across the part a hand closes on
-- Two hands this close are holding each other (a pistol's support hand cups the firing hand), which is a
-- hold, not a hand floating off the gun.
local CUP_DISTANCE = 90 -- mm

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local function kindOf(part)
	if part:IsA("WedgePart") then
		return "wedge"
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		return "cyl"
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return "ball"
	end
	return "box"
end

local function nodeOf(part)
	local cframe = part.CFrame
	return { part = part, name = part.Name, cframe = cframe, inverse = cframe:Inverse(), half = part.Size / 2, kind = kindOf(part) }
end

local function contains(node, point, eps)
	local p = node.inverse * point
	local h = node.half
	local k = node.kind
	if k == "box" then
		return math.abs(p.X) <= h.X + eps and math.abs(p.Y) <= h.Y + eps and math.abs(p.Z) <= h.Z + eps
	elseif k == "cyl" then
		local r = math.min(h.Y, h.Z) + eps
		return math.abs(p.X) <= h.X + eps and p.Y * p.Y + p.Z * p.Z <= r * r
	elseif k == "ball" then
		return p.Magnitude <= math.min(h.X, h.Y, h.Z) + eps
	end
	if math.abs(p.X) > h.X + eps or p.Y < -h.Y - eps or p.Z > h.Z + eps then
		return false
	end
	return ((p.Y + h.Y) * h.Z - (p.Z + h.Z) * h.Y) / math.sqrt(h.Y * h.Y + h.Z * h.Z) <= eps
end

-- Surface points of a node with the area each stands for (world space).
local function surface(node)
	local h = node.half
	local points = {}
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local function add(p, area)
		table.insert(points, { node.cframe * p, area })
	end
	if node.kind == "cyl" then
		local r = math.min(h.Y, h.Z)
		local around = math.max(10, math.ceil(2 * math.pi * r / SPACING))
		local along = math.max(1, math.ceil(2 * h.X / SPACING))
		local cell = (2 * math.pi * r / around) * (2 * h.X / along)
		for i = 0, around - 1 do
			local t = (i + 0.5) / around * math.pi * 2
			for j = 0, along - 1 do
				add(Vector3.new(((j + 0.5) / along * 2 - 1) * h.X, math.cos(t) * r, math.sin(t) * r), cell)
			end
		end
		for _, s in ipairs({ 1, -1 }) do
			local rings = math.max(1, math.ceil(r / SPACING))
			for ring = 0, rings - 1 do
				local inner, outer = ring / rings * r, (ring + 1) / rings * r
				local radius = (inner + outer) / 2
				local count = math.max(6, math.ceil(2 * math.pi * radius / SPACING))
				local cell2 = math.pi * (outer * outer - inner * inner) / count
				for i = 0, count - 1 do
					local t = (i + 0.5) / count * math.pi * 2
					add(Vector3.new(s * h.X, math.cos(t) * radius, math.sin(t) * radius), cell2)
				end
			end
		end
		return points
	end
	if node.kind == "ball" then
		local r = math.min(h.X, h.Y, h.Z)
		local total = 4 * math.pi * r * r
		local n = math.clamp(math.ceil(total / (SPACING * SPACING)), 12, 400)
		local golden = math.pi * (3 - math.sqrt(5))
		for i = 0, n - 1 do
			local y = 1 - (i + 0.5) / n * 2
			local ring = math.sqrt(1 - y * y)
			local t = golden * i
			add(Vector3.new(math.cos(t) * ring * r, y * r, math.sin(t) * ring * r), total / n)
		end
		return points
	end
	for a = 1, 3 do
		local u, v = axes[a % 3 + 1], axes[(a + 1) % 3 + 1]
		local hu, hv = math.abs(h:Dot(u)), math.abs(h:Dot(v))
		local nu, nv = math.max(1, math.ceil(2 * hu / SPACING)), math.max(1, math.ceil(2 * hv / SPACING))
		local cell = (2 * hu / nu) * (2 * hv / nv)
		for _, s in ipairs({ 1, -1 }) do
			for i = 0, nu - 1 do
				for j = 0, nv - 1 do
					add(axes[a] * s * math.abs(h:Dot(axes[a])) + u * ((i + 0.5) / nu * 2 - 1) * hu + v * ((j + 0.5) / nv * 2 - 1) * hv, cell)
				end
			end
		end
	end
	return points
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local okAvatar, avatar = pcall(function()
	local description = Instance.new("HumanoidDescription")
	description.LeftArmColor = Color3.fromRGB(204, 142, 105)
	description.RightArmColor = Color3.fromRGB(204, 142, 105)
	return game:GetService("Players"):CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
end)
if not okAvatar then
	out("no avatar in edit mode (%s): measuring the stand-in arms instead", tostring(avatar))
	avatar = nil
end

local folder = Instance.new("Folder")
folder.Name = "BRR_HandGrip"
folder.Parent = workspace

local eye = CFrame.new(0, 8000, 0)

-- One hand, posed: its contact with the gun, the gap under its palm, and anything of the gun inside it.
local function measureHand(handPart, allNodes)
	local hand = nodeOf(handPart)
	-- Only the gun parts anywhere near this hand: everything below tests points against them one by one.
	local gunNodes = {}
	local reach = hand.half.Magnitude + 16 * MM
	for _, node in ipairs(allNodes) do
		if (node.cframe.Position - handPart.Position).Magnitude <= node.half.Magnitude + reach then
			table.insert(gunNodes, node)
		end
	end
	local contact, area = 0, 0
	local touchSum, touchCount = Vector3.zero, 0
	for _, sample in ipairs(surface(hand)) do
		for _, node in ipairs(gunNodes) do
			if contains(node, sample[1], EPS) then
				contact += sample[2]
				touchSum += sample[1]
				touchCount += 1
				break
			end
		end
	end
	area = contact / (MM * MM)
	-- Which way the palm faces. The palm is the hand's thin axis, and the sign is whichever side the gun is
	-- on: measured, not assumed. Assuming one fixed sign measured the air behind every left hand, because
	-- the rig builds the two hands mirrored -- 492 of 496 left rows came back "on nothing" that way.
	local size = handPart.Size
	local frame = handPart.CFrame
	local axis, halfThick, axisName = frame.RightVector, size.X / 2, "X"
	if size.Y < size.X and size.Y <= size.Z then
		axis, halfThick, axisName = frame.UpVector, size.Y / 2, "Y"
	elseif size.Z < size.X and size.Z < size.Y then
		axis, halfThick, axisName = frame.LookVector, size.Z / 2, "Z"
	end
	local toward
	if touchCount > 0 then
		toward = touchSum / touchCount - handPart.Position
	else
		local best
		for _, node in ipairs(gunNodes) do
			local offset = node.cframe.Position - handPart.Position
			if not best or offset.Magnitude < best then
				best, toward = offset.Magnitude, offset
			end
		end
	end
	local sign = (not toward or toward:Dot(axis) < 0) and -1 or 1
	local palmNormal = axis * sign
	local palmSide = (sign < 0 and "-" or "+") .. axisName
	local palm = handPart.Position + palmNormal * halfThick
	local gap, nearest = nil, nil
	local step = 0.25 * MM
	local distance = 0
	while distance <= 12 * MM do
		local probe = palm + palmNormal * distance
		for _, node in ipairs(gunNodes) do
			if contains(node, probe, 0) then
				gap, nearest = distance / MM, node
				break
			end
		end
		if gap then
			break
		end
		distance += step
	end
	-- Anything of the gun standing inside the hand, and how deep.
	local through, deepest = 0, 0
	for _, node in ipairs(gunNodes) do
		if (node.cframe.Position - handPart.Position).Magnitude < (node.half.Magnitude + hand.half.Magnitude) then
			for _, sample in ipairs(surface(node)) do
				if contains(hand, sample[1], 0) then
					through += 1
					local p = hand.inverse * sample[1]
					local depth = math.min(hand.half.X - math.abs(p.X), hand.half.Y - math.abs(p.Y), hand.half.Z - math.abs(p.Z))
					deepest = math.max(deepest, depth / MM)
				end
			end
		end
	end
	local grasp = 0
	if nearest then
		local size = nearest.part.Size / MM
		local sorted = { size.X, size.Y, size.Z }
		table.sort(sorted)
		grasp = sorted[2]
	end
	return area, gap, nearest and nearest.name or "nothing", through, deepest, grasp, palmSide
end

local function measureGun(Viewmodel, label, id, def, poses)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal, character = avatar })
	if not ok or not vm then
		out("%s %s: Viewmodel.new failed: %s", label, id, tostring(vm))
		return 0
	end
	vm.model.Parent = folder
	local problems = 0
	for _, pose in ipairs(poses) do
		local posed = pcall(vm.Pose, vm, eye, pose[2])
		if not posed then
			out("%s %s %s: Pose failed", label, id, pose[1])
		else
			local armModel = vm.model:FindFirstChild("Arms")
			local gunNodes = {}
			for _, d in ipairs(vm.model:GetDescendants()) do
				if d:IsA("BasePart") and d.Transparency < 1 and not (armModel and d:IsDescendantOf(armModel)) then
					table.insert(gunNodes, nodeOf(d))
				end
			end
			local measured = {}
			for _, side in ipairs({ 1, -1 }) do
				local arm = vm.arms and vm.arms.sides and vm.arms.sides[side]
				local handPart = arm and arm.hand
				if handPart then
					local area, gap, nearest, through, deepest, grasp, palmSide = measureHand(handPart, gunNodes)
					measured[side] = { part = handPart, area = area, gap = gap, nearest = nearest, through = through,
						deepest = deepest, grasp = grasp, palmSide = palmSide }
				end
			end
			for _, side in ipairs({ 1, -1 }) do
				local m = measured[side]
				if m then
					local held = m.area >= HELD_AREA and m.gap ~= nil and m.gap <= HELD_GAP
					local floating = m.gap == nil or m.gap > FLOAT_GAP
					local pierced = m.deepest > THROUGH_DEPTH
					local graspBad = m.grasp > 0 and (m.grasp < GRASP_MIN or m.grasp > GRASP_MAX)
					-- A pistol's support hand cups the firing hand rather than the gun: that is the hold, not a
					-- fault, so it counts as held when the two hands are together.
					local other = measured[-side]
					local cupping = not held and other ~= nil
						and (m.part.Position - other.part.Position).Magnitude <= CUP_DISTANCE * MM
					if (not held and not cupping) or pierced or graspBad then
						problems += 1
					end
					out("%s %-22s %-9s %-5s contact %6.0f mm^2, gap %5s mm, on %-16s through %3d (deepest %4.1f mm), across %4.1f mm, palm %-2s -> %s",
						label, id, pose[1], side == 1 and "right" or "left", m.area, m.gap and string.format("%.1f", m.gap) or "none",
						m.nearest, m.through, m.deepest, m.grasp, m.palmSide,
						held and (pierced and "HELD but PIERCED" or (graspBad and "HELD but hard to grasp" or "held"))
							or (cupping and "cups the other hand" or (floating and "FLOATING" or "loose")))
				end
			end
		end
	end
	vm:Destroy()
	return problems
end

-- Self-test: a planted hand a known distance off a planted grip, measured in both mirrored orientations.
-- The first version of this probe assumed the palm was always the hand's -X, so it measured the air behind
-- every left hand and called all 56 guns' support hands FLOATING. Case B is that fault, planted.
local function selfTest()
	local ok, err = pcall(function()
		local bench = Instance.new("Folder")
		bench.Name = "BRR_HandGripSelfTest"
		bench.Parent = folder
		local grip = Instance.new("Part")
		grip.Name = "SelfTestGrip"
		grip.Anchored = true
		grip.Size = Vector3.new(30, 60, 30) * MM
		grip.CFrame = CFrame.new(0, 8200, 0)
		grip.Parent = bench
		local thick, halfGrip = 29 * MM, grip.Size.X / 2
		local function place(gapMM, flipped)
			local hand = Instance.new("Part")
			hand.Name = "SelfTestHand"
			hand.Anchored = true
			hand.Size = Vector3.new(thick, 79 * MM, 79 * MM)
			hand.CFrame = CFrame.new(grip.Position + Vector3.new(halfGrip + gapMM * MM + thick / 2, 0, 0))
				* (flipped and CFrame.Angles(0, math.pi, 0) or CFrame.identity)
			hand.Parent = bench
			local area, gap, nearest, _, _, _, palmSide = measureHand(hand, { nodeOf(grip) })
			hand:Destroy()
			return area, gap, nearest, palmSide
		end
		local cases = {
			{ "A hand off the grip, palm on -X", 2.5, false, 2.5, "-X" },
			{ "B same hand mirrored, palm on +X", 2.5, true, 2.5, "+X" },
			{ "C mirrored hand touching the grip", 0, true, 0, "+X" },
		}
		for _, case in ipairs(cases) do
			local area, gap, nearest, palmSide = place(case[2], case[3])
			local gapOk = gap ~= nil and math.abs(gap - case[4]) <= 0.3
			local sideOk = palmSide == case[5]
			local touchOk = case[2] > 0 and area < 1 or case[2] == 0 and area > 100
			out("self-test %s: gap %s mm (want %.1f), palm %s (want %s), contact %.0f mm^2, on %s -> %s",
				case[1], gap and string.format("%.1f", gap) or "none", case[4], tostring(palmSide), case[5], area, nearest,
				(gapOk and sideOk and touchOk) and "ok" or "ERROR self-test failed")
		end
		bench:Destroy()
	end)
	if not ok then
		out("ERROR self-test crashed: %s", tostring(err))
	end
end
selfTest()

local variants = { { "after", scripts:FindFirstChild("Viewmodel") } }
local beforeModule = scripts:FindFirstChild("ViewmodelBefore")
if beforeModule then
	table.insert(variants, 1, { "before", beforeModule })
end

for _, variant in ipairs(variants) do
	local label, module = variant[1], variant[2]
	local Viewmodel = require(module)
	local total, guns = 0, 0
	for _, id in ipairs(ids) do
		local def = WeaponData.Get(id)
		-- Mid-reload and mid-shot as well as at rest: a hand that sits right on a still gun can end up inside
		-- a pump, a bolt, a lever or a cylinder once it moves.
		local poses = {
			{ "hip", { aim = 0 } },
			{ "ads", { aim = 1 } },
			{ "reload45", { clip = "reload", progress = 0.45, roundsLeft = 0, magSize = def.magSize } },
			{ "fire50", { aim = 1, clip = "fire", progress = 0.5, roundsLeft = 5 } },
		}
		total += measureGun(Viewmodel, label, id, def, poses)
		guns += 1
		task.wait()
	end
	out("%s: %d guns, %d hand poses not held (or pierced, or hard to grasp)", label, guns, total)
end
folder:Destroy()
out("done")
