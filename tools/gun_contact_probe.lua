-- Probe for tools/runtest.ps1 -Probe: is every piece of every gun really held on, by more than a corner
-- or an edge?
--
-- tools/gun_gaps_probe.lua joins parts whose bounding boxes touch, which can't see a round part
-- standing a couple of millimetres off a flat one (the RPG's optic on its bracket: the boxes met, the
-- cylinder didn't). This one works with the real shapes -- blocks, cylinders, balls and wedges -- and
-- measures how much each pair actually touches:
--
--   * every visible part's surface is sampled (about 1-2 mm apart on small parts, coarser on big ones);
--   * a sample of A counts as touching B when it lies inside B or within EPS of it, and the pair's
--     contact is the larger of A's area on B and B's area on A;
--   * the contact patch's width is its second-largest extent, measured on the finer-sampled side, so a
--     face-to-face seat has a real width, and a corner or an edge line has next to none.
--
-- A pair holds when its contact is at least HOLD_AREA mm^2 (or 60% of the smaller part's smallest
-- face, for thin rods and pins) and at least HOLD_WIDTH mm wide (or half the smaller part's thinnest
-- dimension). Tiny fittings (no dimension over TINY mm) hold on any contact. Parts are joined
-- through holding pairs; every group that doesn't reach the gun's main body is reported with its best
-- link to it: the partner, the contact area and width, or "no contact".
--
-- FOCUS prints every contact of the named parts (by name prefix) on the named guns, for exact numbers.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_contact_probe.lua -WaitSeconds 600

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

-- BEGIN measureContacts
-- Everything from here to "END measureContacts" measures any Model, read-only: copy it into another probe
-- (it needs `GunModels` required above it, for the millimetre), then call
--   measureContacts(model, { label = "Name", style = "-", focus = { "NamePrefix" }, ignore = { SightDot = true },
--       holdArea = 16, holdWidth = 2.5, tiny = 8 })
-- It prints the model's loose groups (and every contact of parts whose names start with a `focus`
-- prefix) and returns how many loose groups there are. The main body is the group with the most volume;
-- `ignore` names parts left out (default: SightDot); holdArea (mm^2), holdWidth and tiny (mm) override
-- the thresholds below for other scales. Positions are reported in millimetres of the model's pivot.
local MM = GunModels.StudsPerMillimetre
local EPS = 0.35 * MM
local MIN_SPACING = 1.2 * MM
local MAX_SAMPLES = 240
local HOLD_AREA = 16 -- mm^2
local HOLD_WIDTH = 2.5 -- mm
local TINY = 8 -- mm

local function out(fmt, ...)
	-- A merged gallery run sets the prefix to "[BRR_Gallery] note " so its log echoes these.
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

-- Is a model-space point inside the node's shape, grown by eps?
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
		local r = math.min(h.X, h.Y, h.Z) + eps
		return p.Magnitude <= r
	end
	-- Wedge: flat bottom (-Y), upright back (+Z), the slope from the bottom front edge to the top back edge.
	if math.abs(p.X) > h.X + eps or p.Y < -h.Y - eps or p.Z > h.Z + eps then
		return false
	end
	local d = ((p.Y + h.Y) * h.Z - (p.Z + h.Z) * h.Y) / math.sqrt(h.Y * h.Y + h.Z * h.Z)
	return d <= eps
end

-- Surface samples in the part's local space, each with the area it stands for (studs^2).
local function samplesOf(node)
	local h = node.half
	local k = node.kind
	local list = {}
	local function add(x, y, z, area)
		table.insert(list, { Vector3.new(x, y, z), area })
	end
	-- A rectangle: centre c, spanned by u and v (full lengths a and b).
	local function rect(c, u, a, v, b, spacing, keep)
		local nu, nv = math.max(1, math.ceil(a / spacing)), math.max(1, math.ceil(b / spacing))
		local cell = (a / nu) * (b / nv)
		for i = 0, nu - 1 do
			for j = 0, nv - 1 do
				local p = c + u * ((i + 0.5) / nu - 0.5) * a + v * ((j + 0.5) / nv - 0.5) * b
				if not keep or keep(p) then
					add(p.X, p.Y, p.Z, cell)
				end
			end
		end
	end
	local X, Y, Z = Vector3.xAxis, Vector3.yAxis, Vector3.zAxis
	local total
	if k == "box" then
		total = 8 * (h.X * h.Y + h.Y * h.Z + h.X * h.Z)
	elseif k == "cyl" then
		local r = math.min(h.Y, h.Z)
		total = 2 * math.pi * r * 2 * h.X + 2 * math.pi * r * r
	elseif k == "ball" then
		local r = math.min(h.X, h.Y, h.Z)
		total = 4 * math.pi * r * r
	else
		total = 4 * h.X * h.Z + 4 * h.X * h.Y + 4 * h.Y * h.Z + 4 * h.X * math.sqrt(h.Y * h.Y + h.Z * h.Z)
	end
	local spacing = math.max(MIN_SPACING, math.sqrt(total / MAX_SAMPLES))
	node.spacing = spacing
	node.area = total
	if k == "box" then
		for _, s in ipairs({ 1, -1 }) do
			rect(X * s * h.X, Y, 2 * h.Y, Z, 2 * h.Z, spacing)
			rect(Y * s * h.Y, X, 2 * h.X, Z, 2 * h.Z, spacing)
			rect(Z * s * h.Z, X, 2 * h.X, Y, 2 * h.Y, spacing)
		end
		node.smallFace = 4 * math.min(h.X * h.Y, h.Y * h.Z, h.X * h.Z)
	elseif k == "cyl" then
		local r = math.min(h.Y, h.Z)
		local around = math.max(8, math.ceil(2 * math.pi * r / spacing))
		local along = math.max(1, math.ceil(2 * h.X / spacing))
		local cell = (2 * math.pi * r / around) * (2 * h.X / along)
		for i = 0, around - 1 do
			local t = (i + 0.5) / around * math.pi * 2
			for j = 0, along - 1 do
				add(((j + 0.5) / along - 0.5) * 2 * h.X, math.cos(t) * r, math.sin(t) * r, cell)
			end
		end
		local rings = math.max(1, math.ceil(r / spacing))
		for _, s in ipairs({ 1, -1 }) do
			for ring = 0, rings - 1 do
				local inner, outer = ring / rings * r, (ring + 1) / rings * r
				local radius = (inner + outer) / 2
				local count = math.max(6, math.ceil(2 * math.pi * radius / spacing))
				local cell2 = math.pi * (outer * outer - inner * inner) / count
				for i = 0, count - 1 do
					local t = (i + 0.5) / count * math.pi * 2
					add(s * h.X, math.cos(t) * radius, math.sin(t) * radius, cell2)
				end
			end
		end
		node.smallFace = math.pi * r * r
	elseif k == "ball" then
		local r = math.min(h.X, h.Y, h.Z)
		local n = math.clamp(math.ceil(total / (spacing * spacing)), 12, MAX_SAMPLES * 2)
		local golden = math.pi * (3 - math.sqrt(5))
		for i = 0, n - 1 do
			local y = 1 - (i + 0.5) / n * 2
			local ring = math.sqrt(1 - y * y)
			local t = golden * i
			add(math.cos(t) * ring * r, y * r, math.sin(t) * ring * r, total / n)
		end
		node.smallFace = math.pi * r * r
	else
		rect(-Y * h.Y, X, 2 * h.X, Z, 2 * h.Z, spacing)
		rect(Z * h.Z, X, 2 * h.X, Y, 2 * h.Y, spacing)
		local slant = Vector3.new(0, 2 * h.Y, 2 * h.Z)
		rect(Vector3.zero, X, 2 * h.X, slant.Unit, slant.Magnitude, spacing)
		for _, s in ipairs({ 1, -1 }) do
			rect(X * s * h.X, Y, 2 * h.Y, Z, 2 * h.Z, spacing, function(p)
				return (p.Y + h.Y) * h.Z <= (p.Z + h.Z) * h.Y
			end)
		end
		node.smallFace = 2 * math.min(h.X * h.Y, h.Y * h.Z, h.X * h.Z)
	end
	return list
end

-- How much of A's surface lies on B: area (studs^2) and the contact points (model space).
local function touching(a, b)
	local area = 0
	local points = {}
	for _, sample in ipairs(a.samples) do
		local world = sample[1]
		if contains(b, world, EPS) then
			area += sample[2]
			table.insert(points, world)
		end
	end
	return area, points
end

-- The patch's width: its second-largest extent along the part's own axes (mm).
local function widthOf(node, points)
	if #points == 0 then
		return 0, 0
	end
	local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
	for _, p in ipairs(points) do
		local q = node.inverse * p
		lo = lo:Min(q)
		hi = hi:Max(q)
	end
	-- A patch one sample across still has that sample's own footprint.
	local e = hi - lo + Vector3.one * node.spacing
	local extents = { e.X, e.Y, e.Z }
	table.sort(extents)
	return extents[2] / MM, extents[3] / MM
end

-- Measures one model, prints its loose groups (and the contacts of any `focus` name prefixes), and
-- returns how many loose groups it has.
local function measureContacts(model, options)
	options = options or {}
	local id, style, focus = options.label or model.Name, options.style or "-", options.focus
	-- Invisible markers aren't geometry, and a red dot's dot floats in its window by design.
	local ignore = options.ignore or { SightDot = true }
	local holdArea, holdWidth, tiny = options.holdArea or HOLD_AREA, options.holdWidth or HOLD_WIDTH, options.tiny or TINY
	local pivot = model:GetPivot()
	local nodes = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 and not ignore[d.Name] then
			local cframe = pivot:ToObjectSpace(d.CFrame)
			local node = { part = d, name = d.Name, cframe = cframe, inverse = cframe:Inverse(), half = d.Size / 2, kind = kindOf(d) }
			local localSamples = samplesOf(node)
			node.samples = {}
			for _, sample in ipairs(localSamples) do
				table.insert(node.samples, { cframe * sample[1], sample[2] })
			end
			local size = d.Size / MM
			node.maxDim = math.max(size.X, size.Y, size.Z)
			node.minDim = math.min(size.X, size.Y, size.Z)
			node.volume = d.Size.X * d.Size.Y * d.Size.Z
			-- Model-space bounds.
			local r = cframe.Rotation
			local extent = Vector3.new(
				math.abs(r.RightVector.X) * node.half.X + math.abs(r.UpVector.X) * node.half.Y + math.abs(r.LookVector.X) * node.half.Z,
				math.abs(r.RightVector.Y) * node.half.X + math.abs(r.UpVector.Y) * node.half.Y + math.abs(r.LookVector.Y) * node.half.Z,
				math.abs(r.RightVector.Z) * node.half.X + math.abs(r.UpVector.Z) * node.half.Y + math.abs(r.LookVector.Z) * node.half.Z
			) + Vector3.one * EPS
			node.lo, node.hi = cframe.Position - extent, cframe.Position + extent
			table.insert(nodes, node)
		end
	end

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

	-- Every touching pair and how well it holds.
	local contacts = {}
	for i = 1, #nodes do
		local a = nodes[i]
		for j = i + 1, #nodes do
			local b = nodes[j]
			if a.lo.X <= b.hi.X and b.lo.X <= a.hi.X and a.lo.Y <= b.hi.Y and b.lo.Y <= a.hi.Y and a.lo.Z <= b.hi.Z and b.lo.Z <= a.hi.Z then
				local areaAB, pointsAB = touching(a, b)
				local areaBA, pointsBA = touching(b, a)
				if areaAB > 0 or areaBA > 0 then
					local area = math.max(areaAB, areaBA) / (MM * MM)
					-- The width from the finer-sampled side that has contact, else the other.
					local width, length
					if (a.spacing <= b.spacing and #pointsAB > 0) or #pointsBA == 0 then
						width, length = widthOf(a, pointsAB)
					else
						width, length = widthOf(b, pointsBA)
					end
					local small = a.volume <= b.volume and a or b
					local smallFace = small.smallFace / (MM * MM)
					local holds
					if small.maxDim <= tiny then
						holds = true
					else
						holds = area >= math.min(holdArea, 0.6 * smallFace) and width >= math.min(holdWidth, 0.5 * small.minDim)
					end
					local contact = { a = i, b = j, area = area, width = width, length = length, holds = holds }
					table.insert(contacts, contact)
					if holds then
						local ri, rj = find(i), find(j)
						if ri ~= rj then
							parent[ri] = rj
						end
					end
				end
			end
		end
		if i % 25 == 0 then
			task.wait()
		end
	end

	-- Groups, the main body being the one with the most volume.
	local groups = {}
	for i, node in ipairs(nodes) do
		local root = find(i)
		groups[root] = groups[root] or { members = {}, volume = 0 }
		table.insert(groups[root].members, i)
		groups[root].volume += node.volume
	end
	local main, mainVolume = nil, -1
	for root, group in pairs(groups) do
		if group.volume > mainVolume then
			main, mainVolume = root, group.volume
		end
	end

	local lines = {}
	for root, group in pairs(groups) do
		if root ~= main then
			local names, seen = {}, {}
			local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
			for _, index in ipairs(group.members) do
				local node = nodes[index]
				lo = lo:Min(node.lo)
				hi = hi:Max(node.hi)
				if not seen[node.name] and #names < 5 then
					seen[node.name] = true
					local anim = node.part:GetAttribute("Anim")
					table.insert(names, node.name .. (anim and ("[" .. anim .. "]") or ""))
				end
			end
			-- Its best link to anything outside the group.
			local best
			for _, c in ipairs(contacts) do
				local inA, inB = find(c.a) == root, find(c.b) == root
				if inA ~= inB and (not best or c.area > best.area) then
					best = c
				end
			end
			local centre = (lo + hi) / 2 / MM
			local link = "no contact"
			if best then
				local inside = find(best.a) == root and nodes[best.a] or nodes[best.b]
				local outside = find(best.a) == root and nodes[best.b] or nodes[best.a]
				link = string.format("best link %s-%s: %.1f mm^2, %.1f mm wide x %.1f mm long", inside.name, outside.name, best.area, best.width, best.length)
			end
			table.insert(lines, string.format("%d part%s {%s} at (%.0f, %.0f, %.0f) mm; %s", #group.members, #group.members == 1 and "" or "s",
				table.concat(names, ", "), centre.X, centre.Y, centre.Z, link))
		end
	end
	table.sort(lines)
	out("%-24s %-12s %4d parts, %5d contacts, %d loose group%s", id, tostring(style), #nodes, #contacts, #lines, #lines == 1 and "" or "s")
	for _, line in ipairs(lines) do
		out("    LOOSE %s", line)
	end

	if focus then
		for _, c in ipairs(contacts) do
			local a, b = nodes[c.a], nodes[c.b]
			for _, prefix in ipairs(focus) do
				if string.sub(a.name, 1, #prefix) == prefix or string.sub(b.name, 1, #prefix) == prefix then
					out("    focus %s-%s: %.1f mm^2, %.1f mm wide x %.1f mm long, %s", a.name, b.name, c.area, c.width, c.length, c.holds and "holds" or "WEAK")
					break
				end
			end
		end
	end
	return #lines
end
-- END measureContacts

-- Only these guns, when non-empty (ids).
local ONLY = {}
local FOCUS = {
	CappuccinaLauncher = { "Optic" },
}

local ids = {}
for id in pairs(WeaponData.Weapons) do
	if next(ONLY) == nil or table.find(ONLY, id) then
		table.insert(ids, id)
	end
end
table.sort(ids)

-- Self-test, first: the RPG's optic mount as the builder had it before its PGO-7 mount (a bracket whose
-- top stops 2 mm under the optic), which must come out loose with no contact, and beside it a block
-- properly sunk into the tube, which must hold.
do
	local test = Instance.new("Model")
	local function piece(name, shape, size, cframe)
		local part = Instance.new("Part")
		part.Name = name
		if shape then
			part.Shape = shape
		end
		part.Size = size * MM
		part.CFrame = CFrame.new(cframe.Position * MM) * cframe.Rotation
		part.Anchored = true
		part.Parent = test
		return part
	end
	local alongZ, upright = CFrame.Angles(0, math.pi / 2, 0), CFrame.Angles(0, 0, math.pi / 2)
	local cylinder = Enum.PartType.Cylinder
	local tube = piece("Receiver", cylinder, Vector3.new(810, 42, 42), CFrame.new(0, 0, -75) * alongZ)
	piece("OpticBracket", nil, Vector3.new(12, 34, 64), CFrame.new(-27, 16, -70))
	piece("Optic", cylinder, Vector3.new(140, 34, 34), CFrame.new(-44, 48, -80) * alongZ)
	piece("OpticEyecup", cylinder, Vector3.new(26, 38, 38), CFrame.new(-44, 48, 3) * alongZ)
	piece("OpticObjective", cylinder, Vector3.new(20, 38, 38), CFrame.new(-44, 48, -160) * alongZ)
	piece("OpticKnob", cylinder, Vector3.new(12, 16, 16), CFrame.new(-44, 71, -60) * upright)
	piece("SeatedBlock", nil, Vector3.new(12, 20, 40), CFrame.new(-26, 0, -300))
	test.PrimaryPart = tube
	tube.PivotOffset = tube.CFrame:Inverse()
	local loose = measureContacts(test, { label = "SELFTEST old RPG mount", focus = { "Optic", "SeatedBlock" } })
	out("self-test %s: %d loose group(s), want exactly 1 (the optic, no contact) with SeatedBlock holding", loose == 1 and "ok" or "FAILED", loose)
	test:Destroy()
end

local flaggedGuns = {}
local totalIslands = 0
local started = os.clock()
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if not ok or not model then
		out("%-24s BUILD FAILED: %s", id, tostring(model))
		continue
	end
	local loose = measureContacts(model, { label = id, style = def.style, focus = FOCUS[id] })
	totalIslands += loose
	if loose > 0 then
		table.insert(flaggedGuns, string.format("%s(%d)", id, loose))
	end
	model:Destroy()
	task.wait()
end

out("guns %d; loose groups %d%s; %.0fs", #ids, totalIslands, #flaggedGuns > 0 and ("  ->  " .. table.concat(flaggedGuns, ", ")) or "", os.clock() - started)
out("done")
