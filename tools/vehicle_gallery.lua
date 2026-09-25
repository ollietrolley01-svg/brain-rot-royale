-- Vehicle gallery: every vehicle model from several angles, a seated rider, close-ups of the
-- wheels, cabin or engine, each model's paint schemes side by side, and an audit of how much the
-- design z-fights before the build's own pass touches it.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/vehicle_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Set SHOW_OVERRIDE = { "ModelId", ... } in a chunk glued in front to render just some models, and
-- VIEW_KINDS_OVERRIDE = { "quarter", "rider" } to render just some views.
-- static-check: globals SEAT_ROOT_OVERRIDE, SHOW_OVERRIDE, VIEW_KINDS_OVERRIDE

local VehicleModels = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("VehicleModels"))
local VehicleWreckFx = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("VehicleWreckFx"))


local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")

local SHOW = SHOW_OVERRIDE or { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan", "PatapimScrambler", "BananiniScoot", "BrrStreetfighter", "TartarugaScout", "CameloCarrier" }
local ORIGIN = Vector3.new(0, 420, 0)

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4
Lighting.ExposureCompensation = 0.15
Lighting.Ambient = Color3.fromRGB(74, 74, 80)
Lighting.OutdoorAmbient = Color3.fromRGB(124, 124, 132)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function stage(folder)
	local floor = Instance.new("Part")
	floor.Anchored = true
	floor.Size = Vector3.new(260, 1, 260)
	floor.CFrame = CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0))
	floor.Color = Color3.fromRGB(128, 130, 136)
	floor.Material = Enum.Material.Concrete
	floor.Parent = folder
	local back = Instance.new("Part")
	back.Anchored = true
	back.Size = Vector3.new(260, 60, 1)
	back.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 30, 40))
	back.Color = Color3.fromRGB(160, 163, 170)
	back.Material = Enum.Material.SmoothPlastic
	back.Parent = folder
end

local rigTemplate = nil
local function rig()
	if rigTemplate then
		return rigTemplate:Clone()
	end
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and model then
		rigTemplate = model
		return model:Clone()
	end
	return nil
end

-- Builds one model on the stage at `offset`, anchored, with a rig posed in the driver seat.
local reportedFights = {}

local function place(folder, modelId, schemeIndex, offset, yaw, withRider)
	if not reportedFights[modelId] then
		-- Build once with the pass switched off and count the flush pairs the design itself has:
		-- counting after the pass would only see what it failed to nudge.
		local ZFight = require(game:GetService("ReplicatedStorage").Shared.ZFight)
		local was = ZFight.Enabled
		ZFight.Enabled = false
		local raw = VehicleModels.Build(modelId, Random.new(7), { scheme = schemeIndex })
		ZFight.Enabled = was
		local pairsOff = ZFight.Scan({ raw })
		note(string.format("%s z-fight with the pass OFF: %d flush pairs", modelId, #pairsOff))
		for _, line in ipairs((ZFight.Describe(pairsOff, nil, 15))) do
			note("  " .. modelId .. " flush: " .. line)
		end
		raw:Destroy()
		reportedFights[modelId] = "scanned"
	end
	local model, info = VehicleModels.Build(modelId, Random.new(7), { scheme = schemeIndex })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN + offset) * CFrame.Angles(0, math.rad(yaw or 0), 0))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	local zf = info.zfight
	local partCount = 0
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			partCount += 1
		end
	end
	note(string.format("%s scheme %d (%s): %d parts, zfight moved %s resized %s remaining %d",
		modelId, info.schemeIndex, info.scheme.name, partCount, tostring(zf and zf.moved), tostring(zf and zf.resized),
		zf and zf.remaining and #zf.remaining or -1))
	if zf and zf.remaining and #zf.remaining > 0 and reportedFights[modelId] ~= "remaining" then
		reportedFights[modelId] = "remaining"
		local ZFight = require(game:GetService("ReplicatedStorage").Shared.ZFight)
		for _, line in ipairs((ZFight.Describe(zf.remaining, nil, 12))) do
			note(modelId .. " fight: " .. line)
		end
	end

	if withRider then
		local r = rig()
		if r then
			local seatFrame = model:GetPivot() * info.seats.driver
			-- Approximate a seated pose: hips on the seat, legs forward. Good enough to judge head room
			-- and whether the rider pokes through the body.
			r.Parent = folder
			local humanoid = r:FindFirstChildOfClass("Humanoid")
			local root = r:FindFirstChild("HumanoidRootPart")
			local hip = humanoid and humanoid.HipHeight or 2
			r:PivotTo(seatFrame * CFrame.new(0, 0.2 + (root and root.Size.Y / 2 or 1), 0))
			for _, part in ipairs(r:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
			local head = r:FindFirstChild("Head")
			if head then
				note(string.format("%s rider head top %.2f above ground (seat %.2f)", modelId,
					head.Position.Y + head.Size.Y / 2 - (ORIGIN.Y + offset.Y), info.seats.driver.Position.Y))
			end
		end
	end
	return model, info
end

-- Poses a stand-in R15 in a seat without physics: the root goes where a SeatWeld puts it, then
-- every joint is solved down from the root with a sitting base pose under the vehicle pose.
-- SEAT_ROOT is the root's frame in the seat part's space, as measured by the handling probe.
local SEAT_ROOT = SEAT_ROOT_OVERRIDE or CFrame.new(0, 1.486, 0)
local SIT_BASE = {
	LeftHip = CFrame.Angles(math.rad(90), 0, 0),
	RightHip = CFrame.Angles(math.rad(90), 0, 0),
	LeftKnee = CFrame.Angles(math.rad(-90), 0, 0),
	RightKnee = CFrame.Angles(math.rad(-90), 0, 0),
}

-- Only the Chassis and the Hull_* parts are CanQuery, so a shot only hits those: every panel is
-- invisible to a raycast. That is fine while the hulls cover the body, and a lie when they don't, so
-- measure how far the visible body stands outside the nearest hull. Wheels are counted apart: they
-- are meant to stand outside the body, and whether a tyre should stop a bullet is a design question.
local WHEEL_WORDS = { "Wheel", "Tyre", "Rim", "Spoke", "Hub", "Disc", "Nut", "Knob", "Cap" }

local function outsideBox(point, part)
	local here = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	local dx = math.max(math.abs(here.X) - half.X, 0)
	local dy = math.max(math.abs(here.Y) - half.Y, 0)
	local dz = math.max(math.abs(here.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function hullCover(model, label)
	local hulls, panels = {}, {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			if part.CanQuery then
				table.insert(hulls, part)
			elseif part.Transparency < 0.9 then
				table.insert(panels, part)
			end
		end
	end
	if #hulls == 0 then
		note(string.format("hull cover %s: no hulls at all, so nothing stops a shot", label))
		return
	end
	local worst, worstName, clear, wheelClear = 0, "-", {}, 0
	for _, part in ipairs(panels) do
		local partWorst = 0
		for _, corner in ipairs({ Vector3.new(1, 1, 1), Vector3.new(1, 1, -1), Vector3.new(1, -1, 1), Vector3.new(1, -1, -1),
			Vector3.new(-1, 1, 1), Vector3.new(-1, 1, -1), Vector3.new(-1, -1, 1), Vector3.new(-1, -1, -1) }) do
			local point = part.CFrame:PointToWorldSpace(corner * part.Size / 2)
			local nearest = math.huge
			for _, hull in ipairs(hulls) do
				nearest = math.min(nearest, outsideBox(point, hull))
				if nearest == 0 then
					break
				end
			end
			partWorst = math.max(partWorst, nearest)
		end
		local isWheel = false
		for _, word in ipairs(WHEEL_WORDS) do
			isWheel = isWheel or string.find(part.Name, word, 1, true) ~= nil
		end
		if isWheel then
			wheelClear += partWorst > 0.5 and 1 or 0
		else
			if partWorst > worst then
				worst, worstName = partWorst, part.Name
			end
			if partWorst > 0.5 then
				table.insert(clear, { name = part.Name, clear = partWorst })
			end
		end
	end
	-- Naming them matters: a mirror or a fender lip standing clear of the hulls is fine (a shot passes
	-- through and carries on to whatever is behind), and so is the glass, or you could not shoot a
	-- driver through a windscreen. Bodywork standing clear is not fine. Only the list tells them apart.
	table.sort(clear, function(a, b)
		return a.clear > b.clear
	end)
	local worstFew = {}
	for index = 1, math.min(8, #clear) do
		worstFew[index] = string.format("%s %.1f", clear[index].name, clear[index].clear)
	end
	note(string.format("hull cover %s: %d hulls, %d visible parts | worst body part stands %.2f studs clear (%s) | %d body parts over 0.5 clear%s | %d wheel parts clear",
		label, #hulls, #panels, worst, worstName, #clear,
		#worstFew > 0 and (" [" .. table.concat(worstFew, ", ") .. "]") or "", wheelClear))
	return worst
end

-- A measure that cannot report an uncovered part would read "all covered" on a vehicle made entirely
-- of shoot-through panels, so it is shown one: a wing bolted nine studs above the roof, well clear of
-- every hull, must come back as the worst thing on the model.
local function hullCoverSelfCheck(model, normalWorst)
	local plant = Instance.new("Part")
	plant.Name = "PlantedWing"
	plant.Size = Vector3.new(2, 0.2, 1)
	plant.CFrame = model:GetPivot() * CFrame.new(0, 9, 0)
	plant.CanQuery = false
	plant.CanCollide = false
	plant.Parent = model
	local worst = hullCover(model, "Rotster+plantedWing")
	-- The property being tested is that an uncovered part becomes the worst thing on the model, not
	-- that it reaches some absolute number: the wing's distance depends on where the hulls happen to
	-- be. (My first version demanded over 4 studs and failed a measure that was working.)
	note(string.format("hull cover self-check: the planted wing read %.2f studs clear against the model's own worst of %.2f: %s",
		worst or 0, normalWorst or 0,
		(worst and normalWorst and worst > normalWorst + 0.8) and "PASS" or "FAIL (the measure cannot see an uncovered part)"))
	plant:Destroy()
end

-- Holes in the bodywork, measured rather than eyeballed (Oliver: "fix the holes in their designs").
--
-- A vehicle is mostly open by design -- under the arches, through the windows, between the frame
-- tubes of a bike -- so "a ray went through it" is not a hole. A HOLE is a pinhole: a spot where a
-- ray passes clean through a surface that is solid all around it. So each model is swept from six
-- directions on a fixed grid, each cell recorded as hit or miss, and a cell counts as a hole when it
-- misses and all four of its neighbours hit. Big openings have missing neighbours and are ignored;
-- a slit between two panels that do not quite meet does not.
--
-- The seat test is the one a player notices: from the driver's eye, a ray that escapes the vehicle
-- entirely (not even through glass, which is a part and is hit) means daylight through the bodywork.
-- A bike is open by nature, so its number is reported and not judged.

local HOLE_STEP = 0.16 -- studs between rays; a gap narrower than this can hide between them
local EYE_RAYS = 2000

local function sweepGrid(model, params, axis, size, center)
	-- axis: the direction the rays travel. The grid covers the model's bounding box face.
	local up = math.abs(axis.Y) > 0.9 and Vector3.new(0, 0, 1) or Vector3.new(0, 1, 0)
	local right = axis:Cross(up).Unit
	up = right:Cross(axis).Unit
	local halfA = math.abs(right.X * size.X) + math.abs(right.Y * size.Y) + math.abs(right.Z * size.Z)
	local halfB = math.abs(up.X * size.X) + math.abs(up.Y * size.Y) + math.abs(up.Z * size.Z)
	halfA, halfB = halfA / 2 + 0.3, halfB / 2 + 0.3
	local depth = math.abs(axis.X * size.X) + math.abs(axis.Y * size.Y) + math.abs(axis.Z * size.Z) + 4
	local columns = math.floor(halfA * 2 / HOLE_STEP)
	local rows = math.floor(halfB * 2 / HOLE_STEP)
	local grid, rays = {}, 0
	for i = 0, columns do
		grid[i] = {}
		for j = 0, rows do
			local from = center - axis * (depth / 2)
				+ right * (-halfA + i * HOLE_STEP) + up * (-halfB + j * HOLE_STEP)
			grid[i][j] = workspace:Raycast(from, axis * depth, params) ~= nil
			rays += 1
		end
	end
	-- A miss with four hits around it is a pinhole.
	local holes = 0
	for i = 1, columns - 1 do
		for j = 1, rows - 1 do
			if not grid[i][j] and grid[i - 1][j] and grid[i + 1][j] and grid[i][j - 1] and grid[i][j + 1] then
				holes += 1
			end
		end
	end
	return holes, rays
end

-- Every part that is reflective or see-through, named. Oliver reported a "weird transparency effect"
-- twice, on the bike's pipes and then on the cars, and the way to answer that is to list what could
-- possibly cause it rather than fix the one part he happened to name. Fully invisible parts (the
-- collision hulls and the seats) are not listed: they are meant to be invisible.
local function shinyAudit(model, label)
	local shiny = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Transparency < 0.95 then
			if part.Reflectance > 0.2 or part.Transparency > 0 then
				table.insert(shiny, string.format("%s %s r%.2f t%.2f", part.Name, part.Material.Name,
					part.Reflectance, part.Transparency))
			end
		end
	end
	if #shiny == 0 then
		note(string.format("shiny audit %s: nothing reflective or see-through except its glass", label))
		return
	end
	local few = {}
	for index = 1, math.min(10, #shiny) do
		few[index] = shiny[index]
	end
	note(string.format("shiny audit %s: %d parts are reflective or see-through [%s]", label, #shiny,
		table.concat(few, ", ")))
end

local function holeSweep(model, label, seatFrame)
	-- Every part must be visible to a ray for this to mean anything. Most of a vehicle is
	-- CanQuery = false on purpose (only the hulls and the structure above the belt line stop a shot),
	-- and with that left alone the sweep saw through the entire body and reported no holes anywhere --
	-- a measurement of nothing. The first run said so plainly: 2000 of 2000 rays from the driver's
	-- seat reached open air. So query is turned on for the sweep and put back afterwards.
	local wasQuery = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			wasQuery[part] = part.CanQuery
			part.CanQuery = part.Transparency < 0.95
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true
	local box, size = model:GetBoundingBox()
	local total, rays = 0, 0
	for _, axis in ipairs({ Vector3.new(0, -1, 0), Vector3.new(0, 1, 0), Vector3.new(0, 0, 1),
		Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0) }) do
		local holes, cast = sweepGrid(model, params, axis, size, box.Position)
		total += holes
		rays += cast
	end

	-- From the driver's eye: anything that gets out is daylight through the body.
	local escaped = 0
	if seatFrame then
		local eye = seatFrame.Position + Vector3.new(0, 2.6, 0)
		for index = 1, EYE_RAYS do
			-- An even-ish spread over the sphere.
			local y = 1 - 2 * (index - 0.5) / EYE_RAYS
			local r = math.sqrt(math.max(0, 1 - y * y))
			local theta = index * 2.399963
			local dir = Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
			if not workspace:Raycast(eye, dir * 40, params) then
				escaped += 1
			end
		end
	end
	for part, was in pairs(wasQuery) do
		part.CanQuery = was
	end
	note(string.format("holes %s: %d pinholes from %d rays over six sweeps | %d of %d rays from the driver's eye reach open air (%.0f%%)",
		label, total, rays, escaped, EYE_RAYS, escaped / EYE_RAYS * 100))
	return total
end

-- An R15's joints: parent part, child part, and the joint's name, which is also the name of the
-- attachment both parts carry. Used when the Humanoid has not built them (edit mode).
local R15_JOINTS = {
	{ "HumanoidRootPart", "LowerTorso", "Root" },
	{ "LowerTorso", "UpperTorso", "Waist" },
	{ "UpperTorso", "Head", "Neck" },
	{ "UpperTorso", "LeftUpperArm", "LeftShoulder" },
	{ "LeftUpperArm", "LeftLowerArm", "LeftElbow" },
	{ "LeftLowerArm", "LeftHand", "LeftWrist" },
	{ "UpperTorso", "RightUpperArm", "RightShoulder" },
	{ "RightUpperArm", "RightLowerArm", "RightElbow" },
	{ "RightLowerArm", "RightHand", "RightWrist" },
	{ "LowerTorso", "LeftUpperLeg", "LeftHip" },
	{ "LeftUpperLeg", "LeftLowerLeg", "LeftKnee" },
	{ "LeftLowerLeg", "LeftFoot", "LeftAnkle" },
	{ "LowerTorso", "RightUpperLeg", "RightHip" },
	{ "RightUpperLeg", "RightLowerLeg", "RightKnee" },
	{ "RightLowerLeg", "RightFoot", "RightAnkle" },
}

local function seatRider(folder, seatFrame, seatHeight, poseName)
	local r = rig()
	if not r then
		return nil
	end
	r.Parent = folder
	local root = r:FindFirstChild("HumanoidRootPart")
	local pose = VehicleModels.Poses[poseName] or {}
	-- The Humanoid builds the rig's joints from its attachments a moment after it is parented in,
	-- so a clone has none at first: wait for them, or the pose has nothing to solve and the whole
	-- stand-in stays where it was built.
	local motors = {}
	for _ = 1, 4 do
		motors = {}
		for _, d in ipairs(r:GetDescendants()) do
			if d:IsA("Motor6D") then
				table.insert(motors, { name = d.Name, part0 = d.Part0, part1 = d.Part1, c0 = d.C0, c1 = d.C1 })
			end
		end
		if #motors > 0 then
			break
		end
		task.wait()
	end
	-- Anchored only now: the parts are held still for the pose, but anchoring them before the
	-- Humanoid had built its joints risked it never building them at all, and then there would be
	-- nothing to read the rest pose from.
	for _, part in ipairs(r:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	if #motors == 0 then
		-- The real reason a clone has no joints here: a Humanoid only builds them while the place is
		-- RUNNING, and the gallery photographs in edit mode. So build the same list the Humanoid
		-- would have, from the rig attachments it does have: an R15's joints are a fixed set, and
		-- each one is a pair of attachments of the same name, the parent's giving C0 and the
		-- child's C1. That is exactly what Humanoid:BuildRigFromAttachments does.
		for _, joint in ipairs(R15_JOINTS) do
			local part0 = r:FindFirstChild(joint[1])
			local part1 = r:FindFirstChild(joint[2])
			local name = joint[3]
			local a0 = part0 and part0:FindFirstChild(name .. "RigAttachment")
			local a1 = part1 and part1:FindFirstChild(name .. "RigAttachment")
			if a0 and a1 then
				table.insert(motors, { name = name, part0 = part0, part1 = part1, c0 = a0.CFrame, c1 = a1.CFrame })
			end
		end
		note(string.format("rider poser: the Humanoid had built no joints (edit mode), so %d were read from the rig attachments", #motors))
	end
	local originalRoot = root.CFrame
	-- The Humanoid rebuilds missing joints from the rig attachments, so it goes too.
	local humanoid = r:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Destroy()
	end
	for _, d in ipairs(r:GetDescendants()) do
		if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end
	root.CFrame = seatFrame * CFrame.new(0, seatHeight / 2, 0) * SEAT_ROOT
	local placed = { [root] = true }
	for _ = 1, 4 do
		for _, m in ipairs(motors) do
			if placed[m.part0] and not placed[m.part1] then
				local t = pose[m.name] or SIT_BASE[m.name] or CFrame.identity
				m.part1.CFrame = m.part0.CFrame * m.c0 * t * m.c1:Inverse()
				placed[m.part1] = true
			end
		end
	end
	-- Anything the joints didn't reach (accessories, or every part if the rig never got its joints)
	-- is carried rigidly with the root, so the stand-in is at least in the seat.
	local carry = root.CFrame * originalRoot:Inverse()
	for _, d in ipairs(r:GetDescendants()) do
		if d:IsA("BasePart") and not placed[d] then
			d.CFrame = carry * d.CFrame
		end
	end
	if #motors == 0 then
		note("rider poser: the stand-in had no joints to pose with (moved rigidly instead)")
	end
	return r
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 40
	camera.CFrame = CFrame.lookAt(ORIGIN + eye, ORIGIN + target)
end

local views = {}
local ONLY = VIEW_KINDS_OVERRIDE

local function hideNamed(model, prefixes)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			for _, prefix in ipairs(prefixes) do
				if string.sub(part.Name, 1, #prefix) == prefix then
					part.Transparency = 1
				end
			end
		end
	end
end

-- Every model's z-fighting, measured honestly: the flush pairs its design has with the pass OFF,
-- and how many parts the pass then moves or resizes (each of those is a nudge to fine detail).
table.insert(views, {
	name = "audit_zfight",
	setup = function(folder, camera)
		stage(folder)
		local ZFight = require(game:GetService("ReplicatedStorage").Shared.ZFight)
		local ids = {}
		for id in pairs(VehicleModels.Models) do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local def = VehicleModels.Models[id]
			for schemeIndex = 1, #def.schemes do
				local was = ZFight.Enabled
				ZFight.Enabled = false
				local raw, rawInfo = VehicleModels.Build(id, Random.new(7), { scheme = schemeIndex })
				ZFight.Enabled = was
				local off = ZFight.Scan({ raw })
				if id == "Rotster" and schemeIndex == 1 then
					-- Planted fault: a second door exactly on the first must add at least one pair.
					local door = raw:FindFirstChild("DoorL")
					local twin = door:Clone()
					twin.Name = "PlantedTwinDoor"
					twin.Parent = raw
					local planted = ZFight.Scan({ raw })
					note(string.format("audit self-check: Rotster %d pairs, with a planted twin door %d (want more): %s",
						#off, #planted, #planted > #off and "PASS" or "FAIL"))
					twin:Destroy()
				end
				local parts = 0
				for _, d in ipairs(raw:GetDescendants()) do
					if d:IsA("BasePart") then
						parts += 1
					end
				end
				if schemeIndex == 1 then
					local coverWorst = hullCover(raw, id)
					if id == "Rotster" then
						hullCoverSelfCheck(raw, coverWorst)
					end
					shinyAudit(raw, id)
					local holesBefore = holeSweep(raw, id, raw:GetPivot() * rawInfo.seats.driver)
					if id == "Rotster" then
						-- Planted fault: lift one door panel a third of a stud out of line, and the slit
						-- it leaves must show up as pinholes, or this sweep proves nothing.
						local door = raw:FindFirstChild("DoorL")
						local where = door.CFrame
						door.CFrame = where * CFrame.new(0, 0.34, 0)
						local planted = holeSweep(raw, "Rotster+plantedSlit", raw:GetPivot() * rawInfo.seats.driver)
						door.CFrame = where
						note(string.format("holes self-check: %d pinholes normally, %d with a door lifted out of line: %s",
							holesBefore, planted, planted > holesBefore and "PASS" or "FAIL (the sweep cannot see a gap)"))
					end
				end
				raw:Destroy()
				local _, info = VehicleModels.Build(id, Random.new(7), { scheme = schemeIndex })
				local zf = info.zfight
				note(string.format("audit %s scheme %d: %d parts | flush pairs with the pass OFF %d | pass moved %d resized %d | left %d",
					id, schemeIndex, parts, #off, zf.moved or -1, zf.resized or -1, zf.remaining and #zf.remaining or -1))
				if schemeIndex == 1 then
					for _, line in ipairs((ZFight.Describe(off, nil, 20))) do
						note("  " .. id .. " flush: " .. line)
					end
				end
				info.chassis.Parent.Parent = nil
				task.wait()
			end
		end
		look(camera, Vector3.new(0, 20, -40), Vector3.new(0, 0, 0), 50)
	end,
})

for _, id in ipairs(SHOW) do
	local def = VehicleModels.Models[id]
	local big = def.kind == "car"
	local d = big and 1 or 0.62
	table.insert(views, {
		name = "quarter_" .. id,
		setup = function(folder, camera)
			stage(folder)
			place(folder, id, 1, Vector3.zero, 0, false)
			look(camera, Vector3.new(-17, 8, -19) * d, Vector3.new(0, 2.2 * d, 0))
		end,
	})
	table.insert(views, {
		name = "rearquarter_" .. id,
		setup = function(folder, camera)
			stage(folder)
			place(folder, id, 5, Vector3.zero, 0, false)
			look(camera, Vector3.new(16, 7, 19) * d, Vector3.new(0, 2.2 * d, 0))
		end,
	})
	table.insert(views, {
		name = "side_" .. id,
		setup = function(folder, camera)
			stage(folder)
			place(folder, id, 2, Vector3.zero, 0, false)
			look(camera, Vector3.new(-30, 3.2, 0) * d, Vector3.new(0, 2.6 * d, 0))
		end,
	})
	table.insert(views, {
		name = "front_" .. id,
		setup = function(folder, camera)
			stage(folder)
			place(folder, id, 3, Vector3.zero, 0, false)
			look(camera, Vector3.new(0, 4, -24) * d, Vector3.new(0, 2.4 * d, 0))
		end,
	})
	table.insert(views, {
		name = "rear_" .. id,
		setup = function(folder, camera)
			stage(folder)
			place(folder, id, 4, Vector3.zero, 0, false)
			look(camera, Vector3.new(0, 4, 24) * d, Vector3.new(0, 2.4 * d, 0))
		end,
	})
	if big then
		table.insert(views, {
			name = "wheel_" .. id,
			setup = function(folder, camera)
				stage(folder)
				place(folder, id, 1, Vector3.zero, 0, false)
				look(camera, Vector3.new(-9, 2.2, -6.5), Vector3.new(-2.6, 1.4, -4.2), 40)
			end,
		})
		table.insert(views, {
			name = "cabin_" .. id,
			setup = function(folder, camera)
				stage(folder)
				local model = place(folder, id, 1, Vector3.zero, 0, false)
				hideNamed(model, { "Roof", "Spoiler", "SharkFin", "Windscreen", "SideGlass", "HatchGlass" })
				look(camera, Vector3.new(-3, 15, 4), Vector3.new(0, 2.5, 0.5), 50)
			end,
		})
	else
		table.insert(views, {
			name = "engine_" .. id,
			setup = function(folder, camera)
				stage(folder)
				place(folder, id, 1, Vector3.zero, 0, false)
				look(camera, Vector3.new(9, 3.2, -1.5), Vector3.new(0, 2.6, 0), 45)
			end,
		})
		table.insert(views, {
			name = "top_" .. id,
			setup = function(folder, camera)
				stage(folder)
				place(folder, id, 3, Vector3.zero, 0, false)
				look(camera, Vector3.new(-2, 14, 3), Vector3.new(0, 3, 0), 50)
			end,
		})
	end
	table.insert(views, {
		name = "rider_" .. id,
		setup = function(folder, camera)
			stage(folder)
			local model, info = place(folder, id, 2, Vector3.zero, 0, false)
			local pivot = model:GetPivot()
			local seatHeight = 0.3
			local r = seatRider(folder, pivot * info.seats.driver, seatHeight, model:GetAttribute("RiderPose"))
			if not big and info.seats.passengers[1] then
				seatRider(folder, pivot * info.seats.passengers[1], seatHeight, "BikePillion")
			end
			if r then
				local head = r:FindFirstChild("Head")
				local top = head.Position.Y + head.Size.Y / 2 - ORIGIN.Y
				-- A posed head can't be below the seat; if it is, the poser didn't move the stand-in.
				local seatTop = info.seats.driver.Position.Y + seatHeight / 2
				note(string.format("%s posed rider head top %.2f above ground, seat top %.2f (want head above seat): %s", id, top, seatTop,
					top > seatTop + 1 and "ok" or "POSER BROKEN"))
			end
			if big then
				hideNamed(model, { "SideGlassL", "Door", "PillarBL" })
			end
			look(camera, Vector3.new(-26, 6.0, -3) * d, Vector3.new(0, 4.6 * d, 0), 44)
		end,
	})
	table.insert(views, {
		name = "riderquarter_" .. id,
		setup = function(folder, camera)
			stage(folder)
			local model, info = place(folder, id, 1, Vector3.zero, 0, false)
			local pivot = model:GetPivot()
			seatRider(folder, pivot * info.seats.driver, 0.3, model:GetAttribute("RiderPose"))
			look(camera, Vector3.new(-16, 10, -18) * d, Vector3.new(0, 4.4 * d, 0), 46)
		end,
	})
	table.insert(views, {
		name = "schemes_" .. id,
		setup = function(folder, camera)
			stage(folder)
			local count = #def.schemes
			local spacing = big and 9 or 4.2
			for index = 1, count do
				place(folder, id, index, Vector3.new((index - (count + 1) / 2) * spacing, 0, (index % 2) * 2), 35, false)
			end
			look(camera, Vector3.new(-6, 22, -40) * d, Vector3.new(0, 1.5, 0), 50)
		end,
	})
end

--------------------------------------------------------------------------------
-- #61 Ranger pole audit: every rod/pipe/tube on the CrocodiloRanger, dimensions named, worst
-- (thinnest relative to its length) first -- before touching a single one, per Oliver's "it still
-- has poles after a previous tab declared it clean" and claude-43's rule that this lands only after
-- an audit list and a close render have been sent and approved.
--------------------------------------------------------------------------------

-- Camera-space check for every render view (HARNESS rule): transforms `worldPoint` into the
-- camera's own space and prints distance + angle off centre, so a shot that frames empty sky says
-- so instead of looking fine in the log.
local function assertInFrame(camera, worldPoint, label, fov)
	local half = math.rad((fov or camera.FieldOfView) / 2) * 1.15 -- generous margin for aspect ratio
	local local_ = camera.CFrame:PointToObjectSpace(worldPoint)
	local distance = -local_.Z
	local inFront = distance > 0.05
	local angle = inFront and math.deg(math.atan2(math.sqrt(local_.X ^ 2 + local_.Y ^ 2), distance)) or 180
	local ok = inFront and angle <= math.deg(half)
	note(string.format("frame check %s: distance %.1f, %.1f deg off centre -- %s", label, distance, angle,
		ok and "IN FRAME" or "NOT IN FRAME"))
	return ok
end

-- "IN FRAME" says where the camera points, not what's between it and the subject (2026-09-21
-- lesson, match-flow/guns tabs -- occluded renders read as passes until this ray is added). Casts
-- camera->worldPoint and fails loud, naming what it hit, rather than passing on geometry alone.
local function assertVisible(camera, worldPoint, label, folder)
	local origin = camera.CFrame.Position
	local delta = worldPoint - origin
	local targetDist = delta.Magnitude
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local result = workspace:Raycast(origin, delta, params)
	if result then
		local hitDist = (result.Position - origin).Magnitude
		if hitDist < targetDist - 0.5 then
			note(string.format("%s: OCCLUDED by %s at %.1f studs (target at %.1f studs)",
				label, result.Instance:GetFullName(), hitDist, targetDist))
			return false
		end
	end
	note(string.format("%s: clear line of sight, %.1f studs", label, targetDist))
	return true
end

-- Every rod-CANDIDATE part on a built model, ANY shape, named with its length, cross-section and
-- length/cross-section ratio -- the same ratio that flagged the Van's roof drumsticks (1.72 studs
-- at diameter 0.10, ratio 17.2, thickened to 0.17, ratio 10.1). The first version of this checked
-- only Cylinder-shaped Parts and MISSED a real one: the Ranger's Mirror/MirrorArm reads as a thin
-- stick in the render (`073_polesrear_CrocodiloRanger.png`) because MirrorArm is a 0.12x0.14 BEAM
-- (Builder:beam builds a box, not a cylinder), so `Shape == Cylinder` skipped it entirely -- not
-- "zero thin beams found", but "beams were never looked at". Fixed by working from the part's own
-- Size regardless of Shape: sort its three dimensions, the largest is the "length" and the SECOND
-- dimension is the cross-section (a rod is thin in BOTH the other axes, unlike a panel or a seam
-- strip, which is thin in only one -- the crossRatio check below is what tells them apart: a door
-- seam is 0.05 x 0.3 x 1.94, crossRatio 6, correctly NOT a rod; MirrorArm is 0.12 x 0.14, crossRatio
-- 1.17, correctly is one). Excludes WedgePart (bevels: legitimately thin in one axis, wide in the
-- other two) and Ball (knobs, hitch ball -- round, not rod-shaped) outright.
local ROD_EXCLUDE_WORDS = { "Wheel", "Tyre", "Rim", "Spoke", "GearStick", "TransferStick", "Column",
	"Gauge", "SteeringWheel", "SpareTyre", "SpareRim", "SpareCap", "Exhaust" }
local function rodAudit(model, label, quiet)
	local rods = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("Part") and part.Shape ~= Enum.PartType.Ball then
			local excluded = false
			for _, word in ipairs(ROD_EXCLUDE_WORDS) do
				if string.find(part.Name, word, 1, true) then
					excluded = true
					break
				end
			end
			if not excluded then
				local dims = { part.Size.X, part.Size.Y, part.Size.Z }
				table.sort(dims)
				local length, crossSection, thinnest = dims[3], dims[2], dims[1]
				local crossRatio = thinnest > 0 and crossSection / thinnest or math.huge
				if length > 0.3 and crossSection > 0 and crossSection < 0.5 and crossRatio <= 4 and length / crossSection >= 3 then
					table.insert(rods, { name = part.Name, length = length, crossSection = crossSection,
						ratio = length / crossSection, shape = tostring(part.Shape), part = part })
				end
			end
		end
	end
	table.sort(rods, function(a, b) return a.ratio > b.ratio end)
	if not quiet then
		note(string.format("%s rod audit: %d candidate rods, any shape (worst/thinnest-relative-to-length first)", label, #rods))
		for _, rod in ipairs(rods) do
			note(string.format("  %s (%s): length %.2f, cross-section %.2f, ratio %.1f, at %s", rod.name, rod.shape,
				rod.length, rod.crossSection, rod.ratio, tostring(rod.part.Position)))
		end
	end
	return rods
end

-- Every model, not just the Ranger: the Van's drumsticks were declared clean by this same
-- cylinder-only blind spot before being found and fixed, so that result is suspect until it is
-- re-checked under the broadened audit too. Cheap (no camera, build-scan-destroy) so it runs for
-- everything, matching audit_zfight's own pattern above.
table.insert(views, {
	name = "audit_rods",
	setup = function(folder, camera)
		local ids = {}
		for id in pairs(VehicleModels.Models) do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ipairs(ids) do
			local model = VehicleModels.Build(id, Random.new(7), { scheme = 1 })
			model.Parent = folder
			rodAudit(model, id)
			model:Destroy()
			task.wait()
		end
		look(camera, Vector3.new(0, 20, -40), Vector3.new(0, 0, 0), 50)
	end,
})

table.insert(views, {
	name = "polesfront_CrocodiloRanger",
	setup = function(folder, camera)
		stage(folder)
		local model = place(folder, "CrocodiloRanger", 1, Vector3.zero, 0, false)
		rodAudit(model, "CrocodiloRanger")
		local target = ORIGIN + Vector3.new(0, 3.6, -8.0)
		look(camera, Vector3.new(6, 5, -18), Vector3.new(0, 3.6, -8.0), 32)
		assertInFrame(camera, target, "polesfront_CrocodiloRanger bull bar cluster")
		for _, name in ipairs({ "BullTop", "BullFrameL", "SpotMountL" }) do
			local part = model:FindFirstChild(name)
			if part then
				assertInFrame(camera, part.Position, "polesfront_CrocodiloRanger/" .. name)
			else
				note("polesfront_CrocodiloRanger: part not found: " .. name)
			end
		end
	end,
})

table.insert(views, {
	name = "polesrear_CrocodiloRanger",
	setup = function(folder, camera)
		stage(folder)
		local model = place(folder, "CrocodiloRanger", 1, Vector3.zero, 0, false)
		local target = ORIGIN + Vector3.new(0, 6.0, 3.2)
		look(camera, Vector3.new(10, 9, 16), Vector3.new(0, 6.0, 3.2), 32)
		assertInFrame(camera, target, "polesrear_CrocodiloRanger roll bar cluster")
		for _, name in ipairs({ "RollBar1", "RollBar2", "RollBar3", "RollBar4", "RollBar5", "RollBraceL", "RollBraceR" }) do
			local part = model:FindFirstChild(name)
			if part then
				assertInFrame(camera, part.Position, "polesrear_CrocodiloRanger/" .. name)
			else
				note("polesrear_CrocodiloRanger: part not found: " .. name)
			end
		end
	end,
})

--------------------------------------------------------------------------------
-- #84 bump measurement: chassis vertical velocity and orientation, logged every physics step, on
-- flat road, a rough verge and a road seam, at several speeds. Says which of suspension settings,
-- wheel collision sampling, road part seams or network ownership the numbers point at.
--------------------------------------------------------------------------------

table.insert(views, {
	name = "bump_measure",
	settle = 1,
	hold = 1,
	setup = function(folder, camera)
		local RunService = game:GetService("RunService")
		local ServerScriptService = game:GetService("ServerScriptService")
		if not RunService:IsRunning() then
			RunService:Run()
		end
		task.wait(3)
		local VehicleService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("VehicleService"))
		-- Unconditional and idempotent (VehicleService.Start guards on `started`): the first run's
		-- IsClient() guard here was wrong and meant this never ran, so nothing ever stepped the
		-- dynamics -- every result read "actual 0", the vehicle never having left rest. Matches
		-- vehicle_probe.lua's own proven call.
		pcall(VehicleService.Start)

		local BUMP_ORIGIN = Vector3.new(-4000, 500, 4000)
		local function makeSlab(size, cframe, material, color)
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = size
			part.CFrame = cframe
			part.Material = material or Enum.Material.Asphalt
			part.Color = color or Color3.fromRGB(70, 70, 74)
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Parent = folder
			return part
		end

		-- Flat: one true, unbroken slab.
		local function buildFlat(x, top)
			makeSlab(Vector3.new(30, 4, 900), CFrame.new(x, top - 2, BUMP_ORIGIN.Z - 420))
		end
		-- Seam: the same strip, but butted from 20-stud slabs with a deliberate misalignment at
		-- every joint (0.08-0.15 studs, both up and down), as a real road segment boundary can leave.
		local function buildSeam(x, top)
			local z = BUMP_ORIGIN.Z + 30
			local step = 20
			local bumps = { 0.08, -0.1, 0.12, -0.08, 0.15, -0.12 }
			local index = 0
			while z > BUMP_ORIGIN.Z - 870 do
				index += 1
				local misalign = bumps[((index - 1) % #bumps) + 1]
				makeSlab(Vector3.new(30, 4, step), CFrame.new(x, top - 2 + misalign, z - step / 2))
				z -= step
			end
		end
		-- Rough verge: a mildly uneven grass shoulder -- small terrain undulations, not a deliberate
		-- bump field (that already exists as "terrain bumps" in vehicle_probe.lua).
		local function buildVerge(x, top)
			workspace.Terrain:FillBlock(CFrame.new(x, top - 4, BUMP_ORIGIN.Z - 420), Vector3.new(40, 8, 900), Enum.Material.Grass)
			for index = 1, 55 do
				local z = BUMP_ORIGIN.Z + 20 - index * 16
				local offset = ((index * 5) % 7 - 3) * 4
				workspace.Terrain:FillBall(Vector3.new(x + offset, top - 2, z), 3 + (index % 3) * 0.35, Enum.Material.Grass)
			end
		end

		local function terrainTopAt(x, z, fromY)
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { folder }
			local hit = workspace:Raycast(Vector3.new(x, fromY + 40, z), Vector3.new(0, -120, 0), params)
			return hit and hit.Position.Y or fromY
		end

		local function drive(seat, throttle, steer)
			seat.ThrottleFloat = throttle
			seat.SteerFloat = steer
			seat.Throttle = throttle > 0.01 and 1 or 0
			seat.Steer = 0
		end

		local template
		for _ = 1, 3 do
			local ok, m = pcall(function()
				return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
			end)
			if ok and m then
				template = m
				break
			end
			task.wait(2)
		end

		-- Two kinds bracket the handling table: Rotster is the softest spring (springHz 2.0, travel
		-- 0.7/0.45), TralalaGT the stiffest and shortest-travel (springHz 2.6, travel 0.45/0.3) --
		-- least room to absorb a step, so the one most likely to read "bumpy and glitchy" at speed.
		local KINDS = { "Rotster", "TralalaGT" }
		local SURFACES = { { "flat", buildFlat }, { "verge", buildVerge }, { "seam", buildSeam } }
		local SPEED_TARGETS = { 35, 70 }
		local laneX = BUMP_ORIGIN.X
		local results = {}

		for _, kind in ipairs(KINDS) do
			for _, surface in ipairs(SURFACES) do
				local name, build = surface[1], surface[2]
				laneX += 90
				local x = laneX
				build(x, BUMP_ORIGIN.Y)
				local top = terrainTopAt(x, BUMP_ORIGIN.Z, BUMP_ORIGIN.Y)
				local model = VehicleService.Create(folder, Vector3.new(x, top + 3, BUMP_ORIGIN.Z + 20), 0, kind)
				task.wait(1.2)
				local seat = model and model:FindFirstChildOfClass("VehicleSeat")
				local chassis = model and model:FindFirstChild("Chassis")
				if not seat or not chassis then
					note(string.format("bump %s/%s: no seat or chassis", kind, name))
				else
					local r = template and template:Clone()
					if r then
						r:PivotTo(seat.CFrame + Vector3.new(0, 3, 0))
						r.Parent = folder
						local humanoid = r:FindFirstChildOfClass("Humanoid")
						task.wait(0.2)
						seat:Sit(humanoid)
						for _ = 1, 40 do
							if seat.Occupant == humanoid then break end
							task.wait(0.05)
						end
					end
					for _, targetSpeed in ipairs(SPEED_TARGETS) do
						drive(seat, 1, 0)
						local began = os.clock()
						local flatSpeed = 0
						while os.clock() - began < 8 do
							local v = chassis.AssemblyLinearVelocity
							flatSpeed = Vector3.new(v.X, 0, v.Z).Magnitude
							if flatSpeed >= targetSpeed then break end
							RunService.Heartbeat:Wait()
						end
						-- Measurement window: log every physics step for 3s at (roughly) held speed.
						local sumVSq, peakV, sumTiltSq, peakTilt, n = 0, 0, 0, 0, 0
						local windowEnd = os.clock() + 3
						local worldUp = Vector3.new(0, 1, 0)
						while os.clock() < windowEnd do
							local vy = chassis.AssemblyLinearVelocity.Y
							local tiltDeg = math.deg(math.acos(math.clamp(chassis.CFrame.UpVector:Dot(worldUp), -1, 1)))
							sumVSq += vy * vy
							peakV = math.max(peakV, math.abs(vy))
							sumTiltSq += tiltDeg * tiltDeg
							peakTilt = math.max(peakTilt, tiltDeg)
							n += 1
							RunService.Heartbeat:Wait()
						end
						drive(seat, targetSpeed > 50 and 1 or 0.6, 0) -- hold speed roughly, not brake
						local rmsV = n > 0 and math.sqrt(sumVSq / n) or 0
						local rmsTilt = n > 0 and math.sqrt(sumTiltSq / n) or 0
						local line = string.format("bump %s/%s target %.0f actual %.0f: vertical vel RMS %.2f peak %.2f studs/s | tilt RMS %.2f peak %.2f deg | %d samples",
							kind, name, targetSpeed, flatSpeed, rmsV, peakV, rmsTilt, peakTilt, n)
						note(line)
						table.insert(results, line)
					end
					drive(seat, 0, 0)
				end
			end
		end
		note(string.format("bump measurement: %d result lines (want %d, %d kinds x %d surfaces x %d speeds)",
			#results, #KINDS * #SURFACES * #SPEED_TARGETS, #KINDS, #SURFACES, #SPEED_TARGETS))
		camera.CFrame = CFrame.lookAt(BUMP_ORIGIN + Vector3.new(-40, 60, 80), BUMP_ORIGIN + Vector3.new(200, 0, 0))
	end,
})

--------------------------------------------------------------------------------
-- Bug-hunt B3-2/B3-3: proves the lamp base-colour fix by BEHAVIOUR (repeated collect-and-rebuild),
-- not by reading -- main's own words: "that is the bug that hides from inspection". Also checks the
-- smoke emitter never duplicates under repeated calls (B3-3a), the shape a dropped weak entry used
-- to produce.
--------------------------------------------------------------------------------

table.insert(views, {
	name = "wreckfx_proof",
	setup = function(folder, camera)
		stage(folder)
		local model = place(folder, "CrocodiloRanger", 1, Vector3.zero, 0, false)
		local lampParts = {}
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part:GetAttribute("Lamp") then
				table.insert(lampParts, part)
			end
		end
		note(string.format("wreckfx_proof: %d lamp parts found on CrocodiloRanger", #lampParts))
		if #lampParts == 0 then
			note("wreckfx_proof: FAIL -- no lamp parts to test against")
		else
			local part = lampParts[1]
			local trueBase = part.Color
			-- Repeated collect-and-rebuild: what a weak `lamps` table used to force on every drop.
			-- Each cycle reads the base through the fixed mechanism, writes a dimmed colour the
			-- exact way updateLamps does (LampShare's own share, not a guessed number), then reads
			-- the base again as if the cache had just been rebuilt from nothing.
			local worstDrift = 0
			for cycle = 1, 6 do
				local base = VehicleWreckFx.LampBaseColor(part)
				local share = VehicleWreckFx.LampShare(part:GetAttribute("Lamp"), false, false, false)
				part.Color = Color3.new(base.R * share, base.G * share, base.B * share)
				local recovered = VehicleWreckFx.LampBaseColor(part)
				local drift = math.abs(recovered.R - trueBase.R) + math.abs(recovered.G - trueBase.G) + math.abs(recovered.B - trueBase.B)
				worstDrift = math.max(worstDrift, drift)
			end
			note(string.format("wreckfx_proof: base colour after 6 collect-and-rebuild cycles, worst drift from true base %.4f (want 0): %s",
				worstDrift, worstDrift < 0.001 and "PASS" or "FAIL"))
			-- Planted fault: the OLD mechanism (re-deriving base from .Color itself), run the same
			-- 6 cycles, must show real compounding drift -- proving this checker can fail, not just
			-- pass by construction.
			local plantedPart = lampParts[#lampParts > 1 and 2 or 1]
			local plantedTrueBase = plantedPart.Color
			local plantedBase = plantedTrueBase
			for cycle = 1, 6 do
				local share = VehicleWreckFx.LampShare(plantedPart:GetAttribute("Lamp"), false, false, false)
				plantedPart.Color = Color3.new(plantedBase.R * share, plantedBase.G * share, plantedBase.B * share)
				plantedBase = plantedPart.Color -- the bug: re-deriving "base" from the just-dimmed colour
			end
			local plantedDrift = math.abs(plantedBase.R - plantedTrueBase.R)
			note(string.format("wreckfx_proof self-check: the OLD mechanism drifts %.4f over 6 cycles (want > 0, proving the checker can fail): %s",
				plantedDrift, plantedDrift > 0.01 and "PASS" or "FAIL (self-check did not fail -- the drift test proves nothing)"))
		end

		-- B3-3a: SetSmoke must never create a second emitter, called repeatedly the way
		-- updateLamps calls it every frame for every nearby vehicle.
		for _ = 1, 20 do
			VehicleWreckFx.SetSmoke(model, true)
		end
		local chassis = model:FindFirstChild("Chassis")
		local emitters = 0
		if chassis then
			for _, d in ipairs(chassis:GetDescendants()) do
				if d:IsA("ParticleEmitter") then
					emitters += 1
				end
			end
		end
		note(string.format("wreckfx_proof: %d ParticleEmitter(s) under Chassis after 20 SetSmoke calls (want 1): %s",
			emitters, emitters == 1 and "PASS" or "FAIL"))

		look(camera, Vector3.new(-17, 8, -19), Vector3.new(0, 2.2, 0), 40)
	end,
})

--------------------------------------------------------------------------------
-- Oliver: "make the car wheel models more flat". Measures every car's tyre width/diameter ratio
-- from the BUILT model (not the source constants), and that the tyre still meets the ground --
-- narrowing width must never have touched radius, which is what the suspension samples for ride
-- height. Documented before-values (the tw this file's VehicleModels.lua carried before this
-- change): Rotster 1.05, CrocodiloRanger 1.35, TralalaGT 1.25, SahurVan 1.1 -- all read against a
-- diameter that did not change, so those are also the before-ratios.
--------------------------------------------------------------------------------

local WHEEL_BEFORE = {
	Rotster = 1.05, CrocodiloRanger = 1.35, TralalaGT = 1.25, SahurVan = 1.1,
}

table.insert(views, {
	name = "audit_wheels",
	setup = function(folder, camera)
		stage(folder)
		local ids = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan" }
		for _, id in ipairs(ids) do
			local model = VehicleModels.Build(id, Random.new(7), { scheme = 1 })
			model.Parent = folder
			-- Without this, the model sits wherever VehicleModels.Build's own local geometry puts
			-- it, nowhere near the stage() floor the ground-clearance raycast below is aimed at --
			-- measured: every one of the four read "no ground found" until this line was added.
			model:PivotTo(CFrame.new(ORIGIN))
			local diameter, width, tyres = nil, nil, 0
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder and string.find(part.Name, "_Tyre", 1, true)
					and not string.find(part.Name, "Wall", 1, true) then
					tyres += 1
					width, diameter = part.Size.X, part.Size.Y
				end
			end
			-- Ground clearance measured against the actual terrain/floor under the wheel, not an
			-- assumed Y, the same "sample, don't trust it" rule every other footing check here uses.
			-- Tracks the WORST (largest magnitude) gap across all four tyres, not the best.
			local worstGroundGap, foundGround = 0, false
			if tyres > 0 then
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { model }
				for _, part in ipairs(model:GetDescendants()) do
					if part:IsA("Part") and string.find(part.Name, "_Tyre", 1, true) and not string.find(part.Name, "Wall", 1, true) then
						local radius = part.Size.Y / 2
						local bottom = part.Position - Vector3.new(0, radius, 0)
						local hit = workspace:Raycast(bottom + Vector3.new(0, 3, 0), Vector3.new(0, -6, 0), params)
						if hit then
							foundGround = true
							local gap = bottom.Y - hit.Position.Y
							if math.abs(gap) > math.abs(worstGroundGap) then
								worstGroundGap = gap
							end
						end
					end
				end
			end
			local ratio = (tyres > 0) and (width / diameter) or nil
			local before = WHEEL_BEFORE[id]
			local beforeRatio = (before and diameter) and (before / diameter) or nil
			note(string.format("audit_wheels %s: %d tyres, width %.2f diameter %.2f, ratio %s (was width %.2f, ratio %s) | worst tyre-to-ground gap %s studs (0 = sitting exactly on it)",
				id, tyres, width or -1, diameter or -1, ratio and string.format("%.2f", ratio) or "N/A",
				before, beforeRatio and string.format("%.2f", beforeRatio) or "N/A",
				foundGround and string.format("%.3f", worstGroundGap) or "no ground found"))
			model:Destroy()
			task.wait()
		end
		look(camera, Vector3.new(0, 20, -40), Vector3.new(0, 0, 0), 50)
	end,
})

-- The worst two (TralalaGT ratio 0.46, Rotster 0.40) at a standing player's eye height (~5 studs),
-- close enough to read the tyre profile the way Oliver actually sees it walking up to the car.
-- The first attempt at this framing shipped empty-hood shots with no wheel in them at all -- the
-- exact "empty sky" failure the harness rule exists for -- because it had no in-frame assertion.
-- Fixed by targeting the actual front-left tyre part and asserting on it, not just eyeballing the
-- numbers.
for _, id in ipairs({ "TralalaGT", "Rotster" }) do
	table.insert(views, {
		name = "wheelflat_" .. id,
		setup = function(folder, camera)
			stage(folder)
			local model = place(folder, id, 1, Vector3.zero, 0, false)
			local wheel = model:FindFirstChild("Wheel_FL_Tyre", true)
			local target = wheel and wheel.Position or (ORIGIN + Vector3.new(-2.6, 1.4, -4.2))
			-- Deliberately NOT going through look(): it adds ORIGIN to whatever it's given, and
			-- `target` here is already an absolute world position (wheel.Position), so routing it
			-- through look() would add ORIGIN a second time -- precisely the "camera helper adds
			-- the world origin twice" trap this whole job was warned about at the start. Eye set in
			-- the same absolute frame instead: standing height (5 studs above the stage floor,
			-- which sits at ORIGIN.Y) a few studs off to the side of the wheel.
			local eye = Vector3.new(target.X - 6, ORIGIN.Y + 5, target.Z - 6)
			camera.FieldOfView = 45
			camera.CFrame = CFrame.lookAt(eye, target)
			assertInFrame(camera, target, "wheelflat_" .. id .. "/Wheel_FL_Tyre")
			if not wheel then
				note("wheelflat_" .. id .. ": Wheel_FL_Tyre not found, fell back to an assumed position")
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- #116 ("bat parts still appear sideways on the Sahur RV, this problem is also on the Ranger"):
-- old #50/#61 already attempted this. #61's own fix (above, on CrocodiloRanger) was measured and
-- confirmed to be a THINNESS fix (bull bar/roll bar/mirror arm rods were too thin, ratio-wise) --
-- rodAudit's own ratio test, not an axis test, so it says nothing about whether a Cylinder is
-- lying on the wrong axis. That is a DIFFERENT bug class (Enum.PartType.Cylinder's circular faces
-- sit on local X, so Size.X is the length ALONG the axis -- get the CFrame's rotation wrong and an
-- elongated cylinder points the wrong way). This audit checks THAT invariant directly and by name
-- covers every Cylinder-shaped part on every one of the 7 vehicle kinds, not a sample: for each it
-- reads the part's OWN CFrame.RightVector (the world direction its local +X -- its length axis --
-- actually points, after every rotation in the build function has been applied) and prints length,
-- diameter and that direction. "Flagged" is elongation (length/diameter) >= 2.5 -- short covers and
-- bolts don't read as "sideways" however they're turned, only genuinely rod/barrel-shaped ones do.
--------------------------------------------------------------------------------

local function axisBucket(axis)
	local ax, ay, az = math.abs(axis.X), math.abs(axis.Y), math.abs(axis.Z)
	if ay >= ax and ay >= az then
		return ay > 0.85 and "VERTICAL" or "diagonal-ish vertical"
	elseif ax >= ay and ax >= az then
		return ax > 0.85 and "LATERAL (world X, left-right)" or "diagonal-ish lateral"
	else
		return az > 0.85 and "LONGITUDINAL (world Z, front-back)" or "diagonal-ish longitudinal"
	end
end

table.insert(views, {
	name = "axis_audit",
	setup = function(folder, camera)
		local examined, flagged = 0, {}
		local ids = {}
		for id in pairs(VehicleModels.Models) do
			table.insert(ids, id)
		end
		table.sort(ids)
		-- Every kind gets built and scanned, not sampled -- the map tab's "29 of 29" lesson: a probe
		-- that walks "every X" only covers the kinds its sample happened to deal.
		for _, id in ipairs(ids) do
			local model = VehicleModels.Build(id, Random.new(7), { scheme = 1 })
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
					examined += 1
					local length = part.Size.X
					local diameter = (part.Size.Y + part.Size.Z) / 2
					local ratio = diameter > 0 and length / diameter or math.huge
					if ratio >= 2.5 then
						local axis = part.CFrame.RightVector
						table.insert(flagged, {
							model = id, name = part.Name, length = length, diameter = diameter,
							ratio = ratio, axis = axis, bucket = axisBucket(axis),
						})
					end
				end
			end
			model:Destroy()
			task.wait()
		end
		note(string.format("axis audit: %d Cylinder parts examined across %d vehicle kinds (every kind built, none sampled), %d elongated (ratio >= 2.5) flagged for axis review",
			examined, #ids, #flagged))
		table.sort(flagged, function(a, b) return a.ratio > b.ratio end)
		for _, f in ipairs(flagged) do
			note(string.format("  %s/%s: length %.2f, diameter %.2f, ratio %.1f, axis (%.2f, %.2f, %.2f) -- %s",
				f.model, f.name, f.length, f.diameter, f.ratio, f.axis.X, f.axis.Y, f.axis.Z, f.bucket))
		end
		look(camera, Vector3.new(0, 20, -40), Vector3.new(0, 0, 0), 50)
	end,
})

table.insert(views, {
	name = "closeup_bat_SahurVan",
	setup = function(folder, camera)
		stage(folder)
		-- Pinned model AND scheme (VehicleService.Create draws its own Random with no options.model --
		-- 09-21 vehicle-tab lesson), same seed `place()` always uses, so this is the exact geometry
		-- that ships.
		local model = place(folder, "SahurVan", 1, Vector3.zero, 0, false)
		-- The taper is BatTaper1..22 (Builder:taper); its two ends and middle stand for it.
		local names = { "BatKnob", "BatHandle", "BatTaper1", "BatTaper11", "BatTaper22", "BatBarrel", "BatEnd",
			"BatStrap1", "BatStrap2", "DrumShell" }
		for _, name in ipairs(names) do
			local part = model:FindFirstChild(name)
			if part then
				local axis = part.Shape == Enum.PartType.Cylinder and part.CFrame.RightVector or nil
				if axis then
					local length, diameter = part.Size.X, (part.Size.Y + part.Size.Z) / 2
					note(string.format("closeup_bat_SahurVan/%s: length %.2f, diameter %.2f, ratio %.1f, axis (%.2f, %.2f, %.2f) -- %s",
						name, length, diameter, diameter > 0 and length / diameter or 0, axis.X, axis.Y, axis.Z, axisBucket(axis)))
				else
					note(string.format("closeup_bat_SahurVan/%s: %s, size (%.2f, %.2f, %.2f)",
						name, tostring(part.Shape), part.Size.X, part.Size.Y, part.Size.Z))
				end
			else
				note("closeup_bat_SahurVan: part not found: " .. name)
			end
		end
		-- Roof rack sits around (batX=-1.4 .. 4, roofY+~1) in model space on a van whose roofY is
		-- ~5.8-6; framed from the left-front quarter, close enough that the bat fills the frame
		-- rather than being a few pixels of a wide shot (the "wide shot of something small is not a
		-- picture of it" lesson).
		local target = ORIGIN + Vector3.new(0.8, 7.3, -0.5)
		look(camera, Vector3.new(-9, 10, -9), Vector3.new(0.8, 7.3, -0.5), 32)
		assertInFrame(camera, target, "closeup_bat_SahurVan roof rack")
		for _, name in ipairs({ "BatKnob", "BatBarrel", "BatEnd", "DrumShell" }) do
			local part = model:FindFirstChild(name)
			if part then
				assertVisible(camera, part.Position, "closeup_bat_SahurVan/" .. name, folder)
			end
		end
	end,
})

if ONLY then
	local kept = {}
	for _, view in ipairs(views) do
		for _, kind in ipairs(ONLY) do
			if string.sub(view.name, 1, #kind + 1) == kind .. "_" or view.name == kind then
				table.insert(kept, view)
				break
			end
		end
	end
	views = kept
end

return views
