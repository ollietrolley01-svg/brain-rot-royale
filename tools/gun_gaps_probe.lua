-- Is every piece of every gun actually attached to the gun?
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_gaps_probe.lua -WaitSeconds 180
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- A part-built gun is welded together, so a piece that floats a millimetre off the body never
-- falls off -- it just hangs in the air with daylight showing round it, which up close in a
-- viewmodel is exactly what a "gap" or a "hole" in the model looks like. This builds every gun,
-- joins parts whose boxes touch or overlap (with a hair of slack), and reports every island that
-- isn't connected to the main body, with where it is in millimetres.
--
-- Two passes decide whether a pair touches. Boxes are tested exactly (a separating-axis test). A
-- cylinder or ball is first tested as its box -- a quick reject -- and then as its real shape: points
-- sampled over its surface (every couple of millimetres) are checked against the other part's real
-- shape, and the other part's corners and centre against it. The box-only version passed an RPG
-- optic whose cylinder sat 2 mm clear of its bracket, because the cylinder's box touched.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local MM = GunModels.StudsPerMillimetre
-- Slack each way: parts closer than this count as touching.
local SLACK = 0.3 * MM

local function say(fmt, ...)
	print(string.format("[BRR_Gaps] " .. fmt, ...))
end

local SAMPLE_SPACING = 2 * MM
local MAX_SAMPLES = 2400

local function shapeOf(part)
	if part:IsA("Part") then
		if part.Shape == Enum.PartType.Ball then
			return "ball"
		elseif part.Shape == Enum.PartType.Cylinder then
			return "cylinder"
		elseif part.Shape == Enum.PartType.Wedge then
			return "wedge"
		end
	elseif part:IsA("WedgePart") then
		return "wedge"
	end
	return "box"
end

-- Is a model-space point inside (or within `pad` of) a node's real shape?
local function near(node, point, pad)
	local p = node.cframe:PointToObjectSpace(point)
	local h = node.half
	if node.shape == "ball" then
		return p.Magnitude <= math.min(h.X, h.Y, h.Z) + pad
	elseif node.shape == "cylinder" then
		return math.abs(p.X) <= h.X + pad and Vector2.new(p.Y, p.Z).Magnitude <= math.min(h.Y, h.Z) + pad
	end
	if math.abs(p.X) > h.X + pad or math.abs(p.Y) > h.Y + pad or math.abs(p.Z) > h.Z + pad then
		return false
	end
	if node.shape == "wedge" then
		-- Under the slope (tall at the back, +Z), with the pad measured square to the slope.
		return p.Y * h.Z - p.Z * h.Y <= pad * math.sqrt(h.Y * h.Y + h.Z * h.Z)
	end
	return true
end

-- Points over a round node's surface, in model space, built once per node.
local function samplesOf(node)
	if node.samples then
		return node.samples
	end
	local points = {}
	local h = node.half
	if node.shape == "ball" then
		local r = math.min(h.X, h.Y, h.Z)
		local count = math.clamp(math.floor(4 * math.pi * r * r / (SAMPLE_SPACING * SAMPLE_SPACING)), 24, MAX_SAMPLES)
		local golden = math.pi * (3 - math.sqrt(5))
		for index = 0, count - 1 do
			local y = 1 - (index + 0.5) / count * 2
			local ring = math.sqrt(1 - y * y)
			local angle = index * golden
			table.insert(points, node.cframe * Vector3.new(math.cos(angle) * ring * r, y * r, math.sin(angle) * ring * r))
		end
	else
		local r = math.min(h.Y, h.Z)
		local around = math.clamp(math.floor(2 * math.pi * r / SAMPLE_SPACING), 12, 96)
		local along = math.clamp(math.floor(2 * h.X / SAMPLE_SPACING) + 1, 2, math.max(2, math.floor(MAX_SAMPLES / around)))
		for i = 0, along - 1 do
			local x = -h.X + 2 * h.X * i / (along - 1)
			for j = 0, around - 1 do
				local angle = j / around * math.pi * 2
				table.insert(points, node.cframe * Vector3.new(x, math.cos(angle) * r, math.sin(angle) * r))
			end
		end
		-- The end caps, as rings in to the centre.
		for _, x in ipairs({ -h.X, h.X }) do
			local rings = math.max(1, math.floor(r / SAMPLE_SPACING))
			for ring = 0, rings do
				local rr = r * ring / rings
				local count = math.max(1, math.floor(2 * math.pi * rr / SAMPLE_SPACING))
				for j = 0, count - 1 do
					local angle = j / count * math.pi * 2
					table.insert(points, node.cframe * Vector3.new(x, math.cos(angle) * rr, math.sin(angle) * rr))
				end
			end
		end
	end
	node.samples = points
	return points
end

-- The box's corners and centre, for the case of a box sitting wholly inside a round part.
local function cornersOf(node)
	local h = node.half
	local points = { node.cframe.Position }
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				table.insert(points, node.cframe * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z))
			end
		end
	end
	return points
end

-- Separating-axis test for two boxes, each grown by `pad`.
local function overlaps(a, b, pad)
	local ca, cb = a.cframe, b.cframe
	local A = { ca.RightVector, ca.UpVector, ca.LookVector }
	local B = { cb.RightVector, cb.UpVector, cb.LookVector }
	local ha = { a.half.X + pad, a.half.Y + pad, a.half.Z + pad }
	local hb = { b.half.X + pad, b.half.Y + pad, b.half.Z + pad }
	local t = cb.Position - ca.Position
	local function separated(axis)
		local length = axis.Magnitude
		if length < 1e-6 then
			return false
		end
		axis = axis / length
		local ra = ha[1] * math.abs(A[1]:Dot(axis)) + ha[2] * math.abs(A[2]:Dot(axis)) + ha[3] * math.abs(A[3]:Dot(axis))
		local rb = hb[1] * math.abs(B[1]:Dot(axis)) + hb[2] * math.abs(B[2]:Dot(axis)) + hb[3] * math.abs(B[3]:Dot(axis))
		return math.abs(t:Dot(axis)) > ra + rb
	end
	for i = 1, 3 do
		if separated(A[i]) or separated(B[i]) then
			return false
		end
	end
	for i = 1, 3 do
		for j = 1, 3 do
			if separated(A[i]:Cross(B[j])) then
				return false
			end
		end
	end
	return true
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

-- Every island of touching parts in a model, largest first, and how many parts were considered.
local function islandsOf(model)
	local pivot = model:GetPivot()
	local nodes = {}
	for _, d in ipairs(model:GetDescendants()) do
		-- Invisible markers (AimPoint) aren't geometry, and a red dot's dot floats in the middle of
		-- its tube by design: it stands for a reflection in the glass, not a part fixed to anything.
		if d:IsA("BasePart") and d.Transparency < 1 and d.Name ~= "SightDot" then
			local cf = pivot:ToObjectSpace(d.CFrame)
			table.insert(nodes, { part = d, cframe = cf, half = d.Size / 2, radius = (d.Size / 2).Magnitude, shape = shapeOf(d) })
		end
	end

	-- Union-find over touching pairs, with a bounding-sphere reject first.
	local parent = {}
	for i = 1, #nodes do
		parent[i] = i
	end
	local function find(i)
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end
	for i = 1, #nodes do
		local a = nodes[i]
		for j = i + 1, #nodes do
			local b = nodes[j]
			if (a.cframe.Position - b.cframe.Position).Magnitude <= a.radius + b.radius + 2 * SLACK then
				local ri, rj = find(i), find(j)
				if ri ~= rj and overlaps(a, b, SLACK) then
					local touching = true
					local aRound, bRound = a.shape == "ball" or a.shape == "cylinder", b.shape == "ball" or b.shape == "cylinder"
					if aRound or bRound then
						touching = false
						-- Each round part's surface against the other's real shape, then corners and
						-- centre the other way for a part sitting wholly inside a round one.
						for _, pair in ipairs({ { a, b }, { b, a } }) do
							local round, other = pair[1], pair[2]
							if not touching and (round.shape == "ball" or round.shape == "cylinder") then
								for _, point in ipairs(samplesOf(round)) do
									if (point - other.cframe.Position).Magnitude <= other.radius + SLACK and near(other, point, SLACK) then
										touching = true
										break
									end
								end
								if not touching then
									for _, point in ipairs(cornersOf(other)) do
										if near(round, point, SLACK) then
											touching = true
											break
										end
									end
								end
							end
						end
					end
					if touching then
						parent[ri] = rj
					end
				end
			end
		end
		if i % 200 == 0 then
			task.wait()
		end
	end

	local islands = {}
	for i = 1, #nodes do
		local root = find(i)
		islands[root] = islands[root] or {}
		table.insert(islands[root], nodes[i])
	end
	local list = {}
	for _, members in pairs(islands) do
		table.insert(list, members)
	end
	table.sort(list, function(x, y)
		return #x > #y
	end)

	return list, #nodes
end

local totalIslands = 0
local worst = {}
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if not ok or not model then
		say("%-20s BUILD FAILED: %s", id, tostring(model))
		continue
	end
	local list, partCount = islandsOf(model)

	local lines = {}
	for index = 2, #list do
		local members = list[index]
		local names, seen, centre = {}, {}, Vector3.zero
		for _, node in ipairs(members) do
			centre += node.cframe.Position
			if not seen[node.part.Name] and #names < 4 then
				seen[node.part.Name] = true
				table.insert(names, node.part.Name .. (node.part:GetAttribute("Anim") and ("[" .. node.part:GetAttribute("Anim") .. "]") or ""))
			end
		end
		centre /= #members
		table.insert(lines, string.format("%d part%s {%s} at (%.0f, %.0f, %.0f) mm", #members, #members == 1 and "" or "s",
			table.concat(names, ", "), centre.X / MM, centre.Y / MM, centre.Z / MM))
	end
	totalIslands += #list - 1
	if #list > 1 then
		table.insert(worst, string.format("%s(%d)", id, #list - 1))
	end
	say("%-20s %-12s %4d parts, %d floating island%s", id, tostring(def.style), partCount, #list - 1, #list == 2 and "" or "s")
	for _, line in ipairs(lines) do
		say("    floating: %s", line)
	end
	model:Destroy()
end

-- Self-test: plant faults the probe must catch and a near-miss it must not, on a real gun, so a "0 floating
-- islands" above is known not to be vacuous. A ball 3 mm clear of the body and a cylinder whose BOX touches
-- the body while the cylinder itself stays 2 mm clear (the RPG-optic case) must each come out as an island;
-- a ball sunk 2 mm into the body must not.
do
	local planted, caught = 0, 0
	local okBuild, model = pcall(WeaponService.BuildGunModel, WeaponData.Get("SahurPistol"), Color3.new(1, 1, 1), Enum.Material.Metal, { detail = "full" })
	if okBuild and model then
		local baseline = #islandsOf(model)
		local _, size = model:GetBoundingBox()
		local top = model:GetBoundingBox().Position.Y + size.Y / 2
		local function plant(name, shape, partSize, cframe)
			local part = Instance.new("Part")
			part.Name = name
			part.Shape = shape
			part.Size = partSize
			part.CFrame = cframe
			part.Parent = model
			return part
		end
		local centre = model:GetBoundingBox().Position
		-- 3 mm above the highest point of the gun.
		local r = 8 * MM
		plant("PlantedFloatingBall", Enum.PartType.Ball, Vector3.one * 2 * r, CFrame.new(centre.X, top + r + 3 * MM, centre.Z))
		-- A cylinder lying across the top (axis X) whose box bottom touches the top plane but whose round
		-- surface is 2 mm above it at the ends: sized so the box reaches down and the curve does not.
		local cr = 10 * MM
		local cylinder = plant("PlantedBoxTouchCylinder", Enum.PartType.Cylinder, Vector3.new(4 * MM, 2 * cr, 2 * cr),
			CFrame.new(centre.X, top + cr + 2 * MM, centre.Z + 40 * MM) * CFrame.Angles(math.rad(45), 0, 0))
		-- Rotating it 45 degrees about its axis leaves the round surface where it was but swings the box's
		-- corner down by (sqrt 2 - 1) * r = 4.1 mm, past the 2 mm gap: the box touches, the cylinder doesn't.
		local after = #islandsOf(model)
		planted = 2
		caught = math.clamp(after - baseline, 0, 2)
		-- The near miss: a ball sunk 2 mm into a part must join the body. It has to sit on a real part's
		-- own top face, not the model's bounding box -- the highest point of a pistol is its rear sight,
		-- so a ball 2 mm under that ceiling hangs in mid-air above the slide, and is an island after all
		-- (which is what the first run of this self-test reported, correctly, as a failure to join).
		cylinder:Destroy()
		model:FindFirstChild("PlantedFloatingBall"):Destroy()
		local biggest, volume = nil, 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				local space = part.Size.X * part.Size.Y * part.Size.Z
				if space > volume then
					biggest, volume = part, space
				end
			end
		end
		plant("PlantedSunkBall", Enum.PartType.Ball, Vector3.one * 2 * r,
			biggest.CFrame * CFrame.new(0, biggest.Size.Y / 2 + r - 2 * MM, 0))
		local sunk = #islandsOf(model)
		say("selftest: planted %d floating parts, caught %d (want %d); ball sunk 2 mm into %s joined the body: %s (want true)",
			planted, caught, planted, biggest and biggest.Name or "?", tostring(sunk == baseline))
		model:Destroy()
	else
		say("selftest: FAILED to build the test gun: %s", tostring(model))
	end
end

say("guns %d; floating islands in total %d%s", #ids, totalIslands, #worst > 0 and ("  ->  " .. table.concat(worst, ", ")) or "")
say("done")
