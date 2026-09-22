-- Roads audit over several maps and seeds in one probe run, after claude-4a's tools/audit_roads.lua
-- (same measurements, same thresholds), with the part names of the road rework, plus
-- RoadNetwork:Audit's own numbers.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/road_audit_all.lua -WaitSeconds 1800 [-PlaceFile <rbxlx>]
--
-- Road and street parts don't all answer raycasts in play (town streets never have), so for the
-- duration of the measurement every surface and marking is made queryable.

local RUNS = {
	{ "SahurSprings", 101 }, { "SahurSprings", 7 },
	{ "TralalaTown", 101 }, { "TralalaTown", 7 },
	{ "BombardiroBay", 101 }, { "BombardiroBay", 7 },
	{ "RotRidge", 101 }, { "RotRidge", 7 },
	{ "PatapimPlains", 101 }, { "PatapimPlains", 7 },
}
local SURFACE = { RoadSurface = true, BridgeRoad = true, JunctionAsphalt = true, Asphalt = true, RoadCurve = true }
local MARKING = { RoadEdge = true, RoadDash = true, RoadCentreLine = true, StopLine = true, Dash = true, Crossing = true }
local STEP = 0.06
local DOUBLE = 0.12
local ALONG_STEP, ACROSS_STEP = 1, 2

local RS = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ZFight = require(RS:WaitForChild("Shared"):WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[AUDIT roads] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end
local function describe(part)
	local cf = part.CFrame
	return string.format("%s@%s size %s look %s up %s", part.Name, v3(part.Position), v3(part.Size), v3(cf.LookVector), v3(cf.UpVector))
end

-- The build's own z-fight pass is switched off here, so what's measured is what the builders made,
-- not what the pass tidied up afterwards.
ZFight.Enabled = false

local totals = {}
local diagnosed = 0
-- Each planted fault is tried on the first map that can carry it (a bridge for the water one).
local selfTested = { ground = false, contact = false, water = false }

for _, run in ipairs(RUNS) do
	local MAP_ID, SEED = run[1], run[2]
	math.randomseed(SEED)
	-- Every warning the build prints, counted. A build that warns is a build doing something it
	-- didn't mean to: "Region has to be aligned to the grid" was printed twice a map for weeks, from
	-- a road chunk whose terrain was then never restored, and everyone had learned to read past it.
	local warnings, warningTexts = 0, {}
	local logConnection = game:GetService("LogService").MessageOut:Connect(function(text, kind)
		if kind == Enum.MessageType.MessageWarning or kind == Enum.MessageType.MessageError then
			warnings += 1
			local short = text:sub(1, 90)
			warningTexts[short] = (warningTexts[short] or 0) + 1
		end
	end)
	local started = os.clock()
	local ok, info = pcall(MapGenerator.Build, MAP_ID)
	if not ok then
		out("%s seed %d: BUILD FAILED %s", MAP_ID, SEED, tostring(info))
		continue
	end
	task.wait(1.5)
	logConnection:Disconnect()
	local warningList = {}
	for text, n in pairs(warningTexts) do
		table.insert(warningList, string.format("%s x%d", text, n))
	end
	table.sort(warningList)
	out("  build warnings: %d%s", warnings, warnings > 0 and (" [" .. table.concat(warningList, " | ") .. "]") or "")
	local map = workspace.Map
	out("%s seed %d built in %.1fs", MAP_ID, SEED, os.clock() - started)

	local surfaces, markings = {}, {}
	local byName = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") then
			if SURFACE[d.Name] then
				d.CanQuery = true
				table.insert(surfaces, d)
				byName[d.Name] = (byName[d.Name] or 0) + 1
			elseif MARKING[d.Name] then
				d.CanQuery = true
				table.insert(markings, d)
				byName[d.Name] = (byName[d.Name] or 0) + 1
			end
		end
	end
	local counts = {}
	for name, n in pairs(byName) do
		table.insert(counts, name .. " " .. n)
	end
	table.sort(counts)
	out("  parts: %s", table.concat(counts, ", "))

	local surfaceParams = RaycastParams.new()
	surfaceParams.FilterType = Enum.RaycastFilterType.Include
	surfaceParams.FilterDescendantsInstances = surfaces
	local terrainParams = RaycastParams.new()
	terrainParams.FilterType = Enum.RaycastFilterType.Include
	terrainParams.FilterDescendantsInstances = { workspace.Terrain }
	terrainParams.IgnoreWater = true

	local examples = {}
	local function example(key, text)
		examples[key] = examples[key] or {}
		if #examples[key] < 6 then
			table.insert(examples[key], text)
		end
	end
	local function ownerOf(part)
		local node = part
		while node.Parent and node.Parent ~= map do
			node = node.Parent
		end
		return node.Name
	end

	-- Sampling, as audit_roads.lua. The check for a second surface just under the top one starts a
	-- hair inside the top part, which a ray never reports, instead of rebuilding an exclusion list per
	-- sample (the original's cost grows with the square of the part count).
	local samples, holes, doubles, openEnds, unjustifiedEnds, connectedToSquare = 0, 0, 0, 0, 0, 0
	local squares = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "Paving" or d.Name == "Cobbles") then
			d.CanQuery = true
			table.insert(squares, d)
		end
	end
	local squareParams = RaycastParams.new()
	squareParams.FilterType = Enum.RaycastFilterType.Include
	squareParams.FilterDescendantsInstances = squares
	local openEndReasons = {}
	-- What finishes an open end: the road edge lines and the town kerbs.
	local finishes = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and (d.Name == "RoadEdge" or d.Name == "Kerb") then
			d.CanQuery = true
			table.insert(finishes, d)
		end
	end
	-- A part's solid corners: eight for a box, six for a wedge, whose top face is cut away from its
	-- (+Y, -Z) edge. A curve's wedges fill half of the box they sit in, and the empty half reaches
	-- into the next piece's sector, so measuring them as boxes finds contacts that aren't there.
	local function cornersOf(part)
		local cf, half = part.CFrame, part.Size / 2
		local wedge = part:IsA("WedgePart")
		local list = {}
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					if not (wedge and sy > 0 and sz < 0) then
						table.insert(list, (cf * CFrame.new(sx * half.X, sy * half.Y, sz * half.Z)).Position)
					end
				end
			end
		end
		return list
	end
	-- How far apart two parts are along any of their faces (a negative value is overlap); a wedge's
	-- slope counts as one of its faces.
	local function separation(a, b)
		local cornersA, cornersB = cornersOf(a), cornersOf(b)
		local axes = { a.CFrame.XVector, a.CFrame.YVector, a.CFrame.ZVector, b.CFrame.XVector, b.CFrame.YVector, b.CFrame.ZVector }
		for _, part in ipairs({ a, b }) do
			if part:IsA("WedgePart") then
				table.insert(axes, (part.CFrame.YVector * part.Size.Z - part.CFrame.ZVector * part.Size.Y).Unit)
			end
		end
		local worst = -math.huge
		for _, axis in ipairs(axes) do
			local lowA, highA, lowB, highB = math.huge, -math.huge, math.huge, -math.huge
			for _, corner in ipairs(cornersA) do
				local value = corner:Dot(axis)
				lowA, highA = math.min(lowA, value), math.max(highA, value)
			end
			for _, corner in ipairs(cornersB) do
				local value = corner:Dot(axis)
				lowB, highB = math.min(lowB, value), math.max(highB, value)
			end
			worst = math.max(worst, math.max(lowA - highB, lowB - highA))
		end
		return worst
	end
	local steps = { small = 0, medium = 0, large = 0 }
	local stepMax = 0
	for index, part in ipairs(surfaces) do
		local length, width = part.Size.Z, part.Size.X
		local columns = math.max(1, math.floor((width - 1) / ACROSS_STEP))
		for column = 0, columns do
			local x = -width / 2 + 0.5 + column * (width - 1) / math.max(1, columns)
			local previousTop, previousPart, previousHit = nil, nil, nil
			local z = -length / 2 - 1
			while z <= length / 2 + 1 do
				samples += 1
				local point = part.CFrame * Vector3.new(x, 0, z)
				local hit = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), surfaceParams)
				local beyond = math.abs(z) > length / 2
				if not hit then
					if beyond and previousTop then
						-- A hole is surface missing between two surfaces; nothing at all further on is an
						-- open end (the side of a junction with no road off it, a street that stops).
						local resumes = nil
						for further = 1, 4 do
							local ahead = part.CFrame * Vector3.new(x, 0, z + (z > 0 and further or -further))
							resumes = resumes or workspace:Raycast(ahead + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), surfaceParams)
						end
						-- A street that runs into its town square carries on onto the square's paving.
						local ontoSquare = workspace:Raycast(point + Vector3.new(0, 6, 0), Vector3.new(0, -12, 0), squareParams)
						if ontoSquare then
							connectedToSquare += 1
						elseif resumes then
							holes += 1
							example("hole", string.format("%s in %s: no surface %.1f past its end at %s, surface again beyond (%s)", describe(part), ownerOf(part),
								math.abs(z) - length / 2, v3(point), describe(resumes.Instance)))
						else
							-- Why it ends, and whether the end is finished: a junction's side with no road off it
							-- carries an edge line (roads) or a kerb (towns) across; a street that stops has a
							-- kerb across its end. Anything else, or a missing finish, is unjustified.
							local finishNames = { RoadEdge = true, Kerb = true }
							local finishParams = OverlapParams.new()
							finishParams.FilterType = Enum.RaycastFilterType.Include
							finishParams.FilterDescendantsInstances = finishes
							local edgePoint = part.CFrame * Vector3.new(x, part.Size.Y / 2, z > 0 and length / 2 or -length / 2)
							local nearby = workspace:GetPartBoundsInRadius(edgePoint, 1.6, finishParams)
							local finished = false
							for _, other in ipairs(nearby) do
								if finishNames[other.Name] then
									finished = true
								end
							end
							-- A curve is walked across its width rather than along it -- its pieces run from the
							-- road's inner edge to its outer one -- so a piece's "ends" are the road's own edges,
							-- finished by the edge line exactly as a junction's side is.
							local reason = (part.Name == "JunctionAsphalt" and (ownerOf(part) == "Roads" and "junction side" or "town junction side"))
								or (part.Name == "Asphalt" and "street end") or (part.Name == "RoadCurve" and "curve side")
								or ("road end (" .. part.Name .. ")")
							local justified = finished and (part.Name == "JunctionAsphalt" or part.Name == "Asphalt" or part.Name == "RoadCurve")
							local key = reason .. (justified and "" or " UNFINISHED")
							openEndReasons[key] = (openEndReasons[key] or 0) + 1
							if justified then
								openEnds += 1
							else
								unjustifiedEnds += 1
								example("unjustified", string.format("%s at %s: %s", key, v3(point), describe(part)))
							end
						end
					end
					previousTop, previousPart, previousHit = nil, nil, nil
				else
					-- A ray landing exactly on the line where two parts meet can graze an end face and come
					-- back with a sideways normal; a plane predicted from that is meaningless, so steps are
					-- only measured between hits on top faces.
					if previousHit and previousHit.Normal.Y > 0.9 and hit.Normal.Y > 0.9 then
						local n, p0 = previousHit.Normal, previousHit.Position
						local predicted = p0.Y - (n.X * (hit.Position.X - p0.X) + n.Z * (hit.Position.Z - p0.Z)) / math.max(0.2, n.Y)
						local excess = math.abs(hit.Position.Y - predicted)
						if excess > STEP and hit.Instance ~= previousPart then
							stepMax = math.max(stepMax, excess)
							local bucket = excess < 0.2 and "small" or (excess < 0.5 and "medium" or "large")
							steps[bucket] += 1
							example("step_" .. bucket, string.format("%.2f step at %s from %s to %s", excess, v3(hit.Position), describe(previousPart), describe(hit.Instance)))
						end
					end
					local under = workspace:Raycast(hit.Position - Vector3.new(0, 0.01, 0), Vector3.new(0, -DOUBLE, 0), surfaceParams)
					-- A second surface counts only where the point is well inside both parts' footprints:
					-- on the line where two slabs meet, the ray can clip the neighbour's edge.
					local function wellInside(p, instance)
						local localPoint = instance.CFrame:PointToObjectSpace(p)
						return math.abs(localPoint.X) < instance.Size.X / 2 - 0.05 and math.abs(localPoint.Z) < instance.Size.Z / 2 - 0.05
					end
					if under and under.Instance ~= hit.Instance and wellInside(hit.Position, hit.Instance) and wellInside(under.Position, under.Instance) then
						doubles += 1
						example("double", string.format("%.3f apart at %s: %s over %s", hit.Position.Y - under.Position.Y, v3(hit.Position), describe(hit.Instance), describe(under.Instance)))
					end
					previousTop, previousPart, previousHit = hit.Position.Y, hit.Instance, { Normal = hit.Normal, Position = hit.Position }
				end
				z += ALONG_STEP
			end
		end
		if index % 40 == 0 then
			task.wait()
		end
	end

	local function overlaps(list, label)
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = list
		local pairsByName, seen, total = {}, {}, 0
		for index, part in ipairs(list) do
			local probe = part:Clone()
			probe:ClearAllChildren()
			probe.Size = Vector3.new(math.max(0.02, part.Size.X - 0.1), math.max(0.02, part.Size.Y - 0.1), math.max(0.02, part.Size.Z - 0.1))
			probe.Transparency = 1
			probe.CanCollide = false
			probe.CanQuery = false
			probe.Parent = workspace
			for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
				-- GetPartsInPart answers for a wedge's whole box, and a curve's wedges fill only half
				-- of theirs -- the empty half reaching into the next piece's sector. So every hit is
				-- measured again against the parts' real shapes, slope faces included.
				local depth = other ~= part and -separation(part, other) or 0
				if other ~= part and not seen[other] and depth > 0.01 then
					total += 1
					local key = part.Name < other.Name and (part.Name .. "/" .. other.Name) or (other.Name .. "/" .. part.Name)
					pairsByName[key] = (pairsByName[key] or 0) + 1
					example(label, string.format("%.3f deep: %s (%s) x %s (%s)", depth, describe(part), ownerOf(part), describe(other), ownerOf(other)))
				end
			end
			seen[part] = true
			probe:Destroy()
			if index % 60 == 0 then
				task.wait()
			end
		end
		local list2 = {}
		for key, n in pairs(pairsByName) do
			table.insert(list2, key .. " " .. n)
		end
		table.sort(list2)
		return total, table.concat(list2, ", ")
	end
	local surfaceTotal, surfacePairs = overlaps(surfaces, "overlap")
	local markingTotal, markingPairs = overlaps(markings, "markingOverlap")

	local roots = {}
	for _, child in ipairs(map:GetChildren()) do
		if child.Name == "Roads" or child.Name == "Town" or child.Name == "River" then
			table.insert(roots, child)
		end
	end
	local flushPairs = ZFight.Scan(roots)
	-- Everything a road, street or square is made of, for the raw pairs.
	local ROADISH = { Kerb = true, Pavement = true, PavementTaper = true, Paving = true, Cobbles = true, JunctionAsphalt = true }
	local rawRoad = {}
	for _, pair in ipairs(flushPairs) do
		local a, b = pair.a.Name, pair.b and pair.b.Name or "?"
		if SURFACE[a] or SURFACE[b] or MARKING[a] or MARKING[b] or ROADISH[a] or ROADISH[b] then
			table.insert(rawRoad, pair)
			if #rawRoad <= 6 then
				example("zfightRaw", string.format("gap %.3f normal %s overlap %.3f: %s / %s", pair.gap, v3(pair.normal), pair.overlap or -1, describe(pair.a),
					pair.b:IsA("Terrain") and "Terrain" or describe(pair.b)))
			end
		end
	end
	local roadFlush = rawRoad

	local floating, buried, checked, floatMax, buryMax = 0, 0, 0, 0, 0
	for _, part in ipairs(surfaces) do
		if part.Name == "RoadSurface" or part.Name == "JunctionAsphalt" then
			checked += 1
			local top = part.CFrame * Vector3.new(0, part.Size.Y / 2, 0)
			local ground = workspace:Raycast(top + Vector3.new(0, 60, 0), Vector3.new(0, -120, 0), terrainParams)
			if ground then
				local lift = top.Y - ground.Position.Y
				if lift > 0.9 then
					floating += 1
					floatMax = math.max(floatMax, lift)
					example("floating", string.format("%s top %.2f above the ground at %s", part.Name, lift, v3(top)))
				elseif lift < 0.05 then
					buried += 1
					buryMax = math.max(buryMax, -lift)
					example("buried", string.format("%s top %.2f under the ground at %s", part.Name, -lift, v3(top)))
				end
			end
		end
	end

	local reasons = {}
	for key, n in pairs(openEndReasons) do
		table.insert(reasons, key .. " " .. n)
	end
	table.sort(reasons)
	out("  sampling: %d samples; holes %d; street ends onto the square %d; open ends justified %d, unjustified %d [%s]; steps > %.2f: small %d, medium %d, large %d (max %.2f); doubles %d",
		samples, holes, connectedToSquare, openEnds, unjustifiedEnds, table.concat(reasons, ", "), STEP, steps.small, steps.medium, steps.large, stepMax, doubles)
	out("  overlapping surfaces %d [%s]; overlapping markings %d [%s]", surfaceTotal, surfacePairs, markingTotal, markingPairs)
	out("  z-fight (raw, the build's pass switched off): %d flush pairs involving roads, streets or squares (of %d in roads/towns/river)%s", #roadFlush, #flushPairs,
		#roadFlush > 0 and (" [" .. table.concat(ZFight.Describe(roadFlush, ownerOf, 6), " | ") .. "]") or "")
	out("  ground: %d parts; floating %d (max %.2f); buried %d (max %.2f)", checked, floating, floatMax, buried, buryMax)
	if info.roads then
		local okAudit, audit = pcall(info.roads.Audit, info.roads, map)
		out("  network: %s", okAudit and audit.summary or ("AUDIT FAILED " .. tostring(audit)))
	end
	local acceptance = ""
	local okAcceptance, acceptanceError = pcall(function()
	-- ============================================================================ acceptance checks
	local roads = info.roads
	local terrainWater = RaycastParams.new()
	terrainWater.FilterType = Enum.RaycastFilterType.Include
	terrainWater.FilterDescendantsInstances = { workspace.Terrain }
	terrainWater.IgnoreWater = false

	-- (1) Every place two road or street surfaces touch, classified. Allowed: consecutive slabs of one
	-- road (same line, grade change at most MAX_CREASE), a road or street arm butting its own junction
	-- piece square-on, a road carrying straight on from a town street at the same height, a street
	-- butting its town square, and the square's own paving pieces. Anything else is a failure.
	local MAX_CREASE = 1.0
	local contactParts = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and (SURFACE[d.Name] or d.Name == "Paving" or d.Name == "Cobbles") then
			d.CanQuery = true
			table.insert(contactParts, d)
		end
	end
	local contactParams = OverlapParams.new()
	contactParams.FilterType = Enum.RaycastFilterType.Include
	contactParams.FilterDescendantsInstances = contactParts
	local function flatLook(part)
		local l = part.CFrame.LookVector
		return Vector3.new(l.X, 0, l.Z).Unit
	end
	-- How far apart two parts' boxes are along any of their axes (a negative value is overlap).
	local contactKinds, contactFailures, contactsSeen = {}, 0, {}
	-- A part's footprint on the ground plane, as min/max X and Z.
	local function footprint(part)
		local cf, half = part.CFrame, part.Size / 2
		local ex = math.abs(cf.XVector.X) * half.X + math.abs(cf.YVector.X) * half.Y + math.abs(cf.ZVector.X) * half.Z
		local ez = math.abs(cf.XVector.Z) * half.X + math.abs(cf.YVector.Z) * half.Y + math.abs(cf.ZVector.Z) * half.Z
		return part.Position.X - ex, part.Position.X + ex, part.Position.Z - ez, part.Position.Z + ez
	end
	-- How far two footprints share along X and along Z (negative is apart).
	local function shared(a, b)
		local ax0, ax1, az0, az1 = footprint(a)
		local bx0, bx1, bz0, bz1 = footprint(b)
		return math.min(ax1, bx1) - math.max(ax0, bx0), math.min(az1, bz1) - math.max(az0, bz0)
	end
	-- A whole side of `arm` against a side of `piece`: sharing a stretch of edge, not overlapping.
	local function butts(arm, piece)
		local sx, sz = shared(arm, piece)
		return (sx > 1 and math.abs(sz) < 0.3) or (sz > 1 and math.abs(sx) < 0.3)
	end
	local junctionPieces = {}
	for _, p in ipairs(contactParts) do
		if p.Name == "JunctionAsphalt" then
			table.insert(junctionPieces, p)
		end
	end
	-- The junction piece both `a` and `b` butt onto, if there is one.
	local function commonJunction(a, b)
		for _, piece in ipairs(junctionPieces) do
			if (piece.Position - a.Position).Magnitude < 400 and butts(a, piece) and butts(b, piece) then
				return piece
			end
		end
		return nil
	end
	local function classify(a, b)
		local names = { a.Name, b.Name }
		table.sort(names)
		local pairName = names[1] .. "/" .. names[2]
		local la, lb = flatLook(a), flatLook(b)
		local parallel = math.abs(la:Dot(lb)) > 0.9999
		local lateralOffset = math.abs((b.Position - a.Position):Dot(Vector3.new(-la.Z, 0, la.X)))
		-- The angle between the two parts' long axes. From the cross product rather than acos of the
		-- dot: CFrames are single precision, and the nearest float below 1 already reads as 0.02 deg
		-- through acos, which made two identical level parts look creased.
		local lookA, lookB = a.CFrame.LookVector, b.CFrame.LookVector
		local crease = math.deg(math.atan2(lookA:Cross(lookB).Magnitude, math.abs(lookA:Dot(lookB))))
		local sx, sz = shared(a, b)
		-- The nearer end of each top face: how far apart in height.
		local function endTop(part, other)
			local toward = (other.Position - part.Position):Dot(part.CFrame.LookVector) > 0 and -1 or 1
			return (part.CFrame * CFrame.new(0, part.Size.Y / 2, toward * part.Size.Z / 2)).Position
		end
		local topGap = math.abs(endTop(a, b).Y - endTop(b, a).Y)
		local detail = string.format(" [shared %.3f x %.3f, crease %.3f deg, lateral %.3f, tops %.3f]", sx, sz, crease, lateralOffset, topGap)
		local roadish = { RoadSurface = true, BridgeRoad = true, Asphalt = true, JunctionAsphalt = true, RoadCurve = true }
		-- The pieces of one curve: flat plates at one height, sharing the radii between them, so
		-- their tops are level and their faces meet exactly. A curve's ends butt the straights.
		if a.Name == "RoadCurve" or b.Name == "RoadCurve" then
			-- Top faces, taken from each part's own axes: a curve's wedges lie on their side, so
			-- their upright extent is not Size.Y.
			local function topOf(part)
				local cf, half = part.CFrame, part.Size / 2
				return part.Position.Y + math.abs(cf.XVector.Y) * half.X + math.abs(cf.YVector.Y) * half.Y + math.abs(cf.ZVector.Y) * half.Z
			end
			local level = math.abs(topOf(a) - topOf(b)) < 0.02
			if a.Name == "RoadCurve" and b.Name == "RoadCurve" then
				if a.Parent == b.Parent and level then
					return "pieces of one curve", true
				end
				return "two curve pieces out of line" .. detail, false
			end
			if (a.Name == "RoadSurface" or b.Name == "RoadSurface") and level then
				return "a road into the curve it turns onto", true
			end
			return "a curve meeting " .. (a.Name == "RoadCurve" and b.Name or a.Name) .. " out of line" .. detail, false
		end
		-- Two pieces touching only along a vertical line at a corner, with nothing of either face
		-- against the other: allowed only where both are arms butting the same junction piece, which
		-- fills the corner between them.
		if roadish[a.Name] and roadish[b.Name] and sx < 0.3 and sz < 0.3 then
			if commonJunction(a, b) then
				return "arms of one junction meeting at its corner", true
			end
			return "corner touch with no junction piece between" .. detail, false
		end
		if (pairName == "RoadSurface/RoadSurface" or pairName == "BridgeRoad/RoadSurface" or pairName == "BridgeRoad/BridgeRoad") then
			if parallel and lateralOffset < 0.1 and crease <= MAX_CREASE and topGap < 0.02 then
				return "graded joint along one road", true
			end
			return "two road slabs meeting off-line or creased" .. detail, false
		elseif pairName == "JunctionAsphalt/RoadSurface" or pairName == "Asphalt/JunctionAsphalt" or pairName == "BridgeRoad/JunctionAsphalt" then
			local arm = a.Name == "JunctionAsphalt" and b or a
			local box = a.Name == "JunctionAsphalt" and a or b
			local armLook = flatLook(arm)
			local square = math.abs(armLook.X) > 0.9999 or math.abs(armLook.Z) > 0.9999
			local centred = math.abs((box.Position - arm.Position):Dot(Vector3.new(-armLook.Z, 0, armLook.X))) < 0.1
			if square and centred and topGap < 0.02 and butts(arm, box) then
				return "arm into its junction piece", true
			end
			return "arm meeting a junction piece off-centre or at an angle" .. detail, false
		elseif pairName == "Asphalt/RoadSurface" then
			-- 0.15 degrees, not 0.01: where an edge is too short to hold a level stretch at both ends
			-- it is level end to end, and the two junction heights it joins are relaxed to within a
			-- hundredth of a stud of each other rather than to nothing. That leaves a slab tilted by
			-- about 0.06 of a degree -- 0.01 studs over its length, under the 0.02 the tops are held
			-- to. Demanding 0.01 degrees of angle while allowing 0.02 studs of height was inconsistent.
			if parallel and lateralOffset < 0.1 and crease <= 0.15 and topGap < 0.02 then
				return "road carrying straight on from a town street", true
			end
			return "road meeting a town street off-line" .. detail, false
		elseif pairName == "Asphalt/Asphalt" then
			if parallel and lateralOffset < 0.1 and crease <= 0.01 and topGap < 0.02 then
				return "consecutive pieces of one street", true
			end
			return "two street pieces meeting off-line" .. detail, false
		elseif pairName == "Asphalt/Paving" or pairName == "Asphalt/Cobbles" then
			return "street into its town square", true
		elseif pairName == "Cobbles/Paving" or pairName == "Paving/Paving" then
			return "the square's own paving", true
		end
		return "unplanned contact " .. pairName .. detail, false
	end
	-- Every contact in the map, classified. Returns how many failed; `report` also files examples.
	local function contactCheck(report)
		contactKinds, contactFailures, contactsSeen = {}, 0, {}
		for index, part in ipairs(contactParts) do
			local box = part.CFrame
			local nearby = workspace:GetPartBoundsInBox(box, part.Size + Vector3.new(0.2, 0.2, 0.2), contactParams)
			for _, other in ipairs(nearby) do
				if other ~= part and not contactsSeen[other] and separation(part, other) < 0.03 then
					local kind, ok = classify(part, other)
					local label = kind:gsub(" %[.*%]$", "")
					contactKinds[label] = (contactKinds[label] or 0) + 1
					if not ok then
						contactFailures += 1
						if report then
							example("contact", string.format("%s: %s / %s", kind, describe(part), describe(other)))
						end
					end
				end
			end
			contactsSeen[part] = true
			if index % 80 == 0 then
				task.wait()
			end
		end
		return contactFailures
	end
	contactCheck(true)
	local contactList = {}
	for kind, n in pairs(contactKinds) do
		table.insert(contactList, kind .. " " .. n)
	end
	table.sort(contactList)
	out("  contacts: failures %d [%s]", contactFailures, table.concat(contactList, ", "))

	-- (2) Dense ground grid under and beside every road, off the bridges: every 2 studs along,
	-- every 2 studs across the carriageway plus the shoulders. Wanted: the terrain surface at the
	-- road's ground height, the road top LIFT above it, within TOLERANCE either way.
	local TOLERANCE = 0.25
	local RN = require(modules:WaitForChild("RoadNetwork"))
	-- The terrain under and beside `edges`, every 2 studs along and every 2 across the carriageway
	-- and shoulders, off the bridges. `report` files examples; the self-test below calls this again
	-- on one edge, quietly, after planting a fault.
	--
	-- A ray that finds no terrain counts as a failure rather than a skipped sample: smooth terrain
	-- never reports the voxel a ray starts inside, so ground standing higher than the ray's start
	-- reads as nothing at all -- which is why the ray starts 500 studs up, well over any terrain.
	-- The points to measure along a road: every 2 studs from one end of the straight to the other,
	-- and every 2 studs round each curve, each with the road's own ground height there and a
	-- direction across the road. Curves are level, so their ground height is the bend's own.
	local function roadPoints(edges, curves, step)
		local points = {}
		for _, edge in ipairs(edges) do
			local right = Vector3.new(-edge.dir.Z, 0, edge.dir.X)
			local from = edge.a.curve and edge.a.box or 0
			local to = edge.length - (edge.b.curve and edge.b.box or 0)
			for along = from, to, step do
				local onBridge = false
				for _, span in ipairs(edge.bridges or {}) do
					if along >= span.s0 - 6 and along <= span.s1 + 6 then
						onBridge = true
					end
				end
				table.insert(points, { centre = edge.from + edge.dir * along, across = right, ground = RN.EdgeHeight(edge, along),
					bridge = onBridge, what = string.format("%d along a %s-to-%s road", along, edge.a.kind, edge.b.kind) })
			end
		end
		for _, curve in ipairs(curves) do
			local c = curve.curve
			local length = math.abs(c.sweep) * c.radius
			local count = math.max(4, math.ceil(length / step))
			for index = 0, count do
				local angle = c.a1 + c.sweep * (index / count)
				local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
				table.insert(points, { centre = Vector3.new(c.centre.X + out.X * c.radius, 0, c.centre.Z + out.Z * c.radius),
					across = out, ground = curve.node.height, bridge = false,
					what = string.format("%.0f%% round a curve of radius %.0f", index / count * 100, c.radius) })
			end
		end
		return points
	end

	local function denseGround(edges, report, curves)
		local result = { samples = 0, expected = 0, poke = 0, float = 0, missed = 0, over = 0, under = 0,
			apron = 0, apronOff = 0, apronWorst = 0, apronAt = nil }
		for index, spot in ipairs(roadPoints(edges, curves or {}, 2)) do
			if not spot.bridge then
				local function groundAt(lateral)
					local p = spot.centre + spot.across * lateral
					return p, workspace:Raycast(Vector3.new(p.X, spot.ground + 500, p.Z), Vector3.new(0, -1000, 0), terrainParams)
				end
				for _, lateral in ipairs({ -19, -17, -15, -13, 13, 15, 17, 19 }) do
					local p, hit = groundAt(lateral)
					if hit then
						result.apron += 1
						local error = math.abs(hit.Position.Y - spot.ground)
						if error > TOLERANCE then
							result.apronOff += 1
							-- WHERE, not just how much. A count with a worst case and no location is a
							-- number nobody can act on: RotRidge reported 935 samples off and a worst of
							-- 1.17 with no way to go and look at it.
							if error > result.apronWorst then
								result.apronWorst = error
								result.apronAt = string.format("(%.0f, %.0f), %s, %d out", p.X, p.Z, spot.what, lateral)
							end
						end
					end
				end
				for lateral = -11, 11, 2 do
					local p, hit = groundAt(lateral)
					result.expected += 1
					if not hit then
						result.missed += 1
						if report then
							example("denseMiss", string.format("no terrain at all under (%.1f, %.1f), %s, lateral %d", p.X, p.Z, spot.what, lateral))
						end
					else
						result.samples += 1
						local error = hit.Position.Y - spot.ground
						if error > TOLERANCE then
							result.poke += 1
							result.over = math.max(result.over, error)
							if report then
								example("densePoke", string.format("terrain %.2f above road ground at (%.1f, %.1f), %s, lateral %d", error, p.X, p.Z, spot.what, lateral))
							end
						elseif error < -TOLERANCE then
							result.float += 1
							result.under = math.max(result.under, -error)
							if report then
								example("denseFloat", string.format("terrain %.2f below road ground at (%.1f, %.1f), %s, lateral %d", -error, p.X, p.Z, spot.what, lateral))
							end
						end
					end
				end
			end
			if index % 120 == 0 then
				task.wait()
			end
		end
		return result
	end
	local dense = denseGround(roads and roads.edges or {}, true, roads and roads:Curves() or {})
	local densePoke, denseFloat = dense.poke, dense.float
	out("  dense ground: %d of %d samples found terrain (every 2 studs along and across, off bridges), %d found none; terrain more than %.2f above road ground %d (worst %.2f), more than %.2f below %d (worst %.2f); flat past the shoulders (13..19 out, for information): %d samples, %d off by more than %.2f (worst %.2f%s)",
		dense.samples, dense.expected, dense.missed, TOLERANCE, dense.poke, dense.over, TOLERANCE, dense.float, dense.under,
		dense.apron, dense.apronOff, TOLERANCE, dense.apronWorst, dense.apronAt and (" at " .. dense.apronAt) or "")

	-- (3) Water under any road without a bridge deck over it.
	-- `report` files examples; the self-test calls this again after taking a bridge's deck away.
	local function waterUnderRoads(edges, report, curves)
		local deckParams = RaycastParams.new()
		deckParams.FilterType = Enum.RaycastFilterType.Include
		local decks = {}
		for _, d in ipairs(map:GetDescendants()) do
			if d:IsA("BasePart") and (d.Name == "BridgeRoad" or d.Name == "BridgeDeck") then
				d.CanQuery = true
				table.insert(decks, d)
			end
		end
		deckParams.FilterDescendantsInstances = decks
		local samples, uncovered, covered = 0, 0, 0
		for index, spot in ipairs(roadPoints(edges, curves or {}, 2)) do
			for _, lateral in ipairs({ -8, 0, 8 }) do
				local p = spot.centre + spot.across * lateral
				samples += 1
				local hit = workspace:Raycast(Vector3.new(p.X, 300, p.Z), Vector3.new(0, -600, 0), terrainWater)
				if hit and hit.Material == Enum.Material.Water then
					local deck = workspace:Raycast(Vector3.new(p.X, 300, p.Z), Vector3.new(0, -600, 0), deckParams)
					if deck and deck.Position.Y > hit.Position.Y then
						covered += 1
					else
						uncovered += 1
						if report then
							example("water", string.format("water under the road with no deck at (%.1f, %.1f), %s", p.X, p.Z, spot.what))
						end
					end
				end
			end
			if index % 200 == 0 then
				task.wait()
			end
		end
		return samples, covered, uncovered
	end
	local waterSamples, waterCovered, waterUncovered = waterUnderRoads(roads and roads.edges or {}, true, roads and roads:Curves() or {})
	out("  water: %d samples; over water with a deck %d, over water with NO deck %d", waterSamples, waterCovered, waterUncovered)

	-- Anything the wilds planted standing in the road. The foliage tab counts the spots its veto
	-- REFUSED; this counts what got through, which is the other half of the same question and the only
	-- half that can be a fault. Their number being high and this one being zero is agreement, not
	-- disagreement. Three bands, so a disagreement says which one we read differently: inside the
	-- corridor (carriageway, shoulders and the flat apron -- the road's own ground), inside the 8 studs
	-- of blend beyond it (allowed, but the ground there moves by up to a stud), and clear.
	-- The zero is only worth printing if there was something to find, so this says which zero it is.
	local wilds = map:FindFirstChild("Wilds")
	if not roads then
		out("  wilds in the road: no road network, nothing to measure")
	elseif not wilds then
		out("  wilds in the road: NO WILDS IN THIS BUILD (MapWilds is not called yet) -- this is a zero because there is nothing there, not because nothing is wrong")
	else
		local inCorridor, inBlend, clear, worst, worstAt = 0, 0, 0, nil, nil
		local parts = 0
		for _, part in ipairs(wilds:GetDescendants()) do
			if part:IsA("BasePart") then
				parts += 1
				-- The middle and the four compass points at the footprint's edge, capped at 26 studs:
				-- a trunk clear at its centre can still have a canopy post in the apron.
				local reach = math.min(26, math.max(part.Size.X, part.Size.Z) / 2)
				local worstHere = nil
				for _, offset in ipairs({ Vector3.new(0, 0, 0), Vector3.new(reach, 0, 0), Vector3.new(-reach, 0, 0),
					Vector3.new(0, 0, reach), Vector3.new(0, 0, -reach) }) do
					local p = part.Position + offset
					if roads:WithinCorridor(p.X, p.Z) then
						worstHere = "corridor"
					elseif worstHere ~= "corridor" and roads:GroundAt(p.X, p.Z, 8) then
						worstHere = "blend"
					end
				end
				if worstHere == "corridor" then
					inCorridor += 1
					if not worst then
						worst, worstAt = part.Name, part.Position
					end
					-- Unconditionally: `report` is a parameter of the sampling passes, not a name in scope
					-- here, and `if report then` would have read as nil and filed nothing, for ever.
					example("wilds", string.format("%s at (%.1f, %.1f) stands in the road corridor", part.Name, part.Position.X, part.Position.Z))
				elseif worstHere == "blend" then
					inBlend += 1
				else
					clear += 1
				end
			end
		end
		out("  wilds in the road: %d parts measured; in the corridor %d%s, in the 8-stud blend beyond it %d, clear %d",
			parts, inCorridor, worst and string.format(" (first: %s at (%.0f, %.0f))", worst, worstAt.X, worstAt.Z) or "", inBlend, clear)
	end
		acceptance = string.format("build warnings %d, contacts failing %d, ground off by >%.2f %d/%d, no terrain found %d, water without deck %d",
		warnings, contactFailures, TOLERANCE, densePoke, denseFloat, dense.missed, waterUncovered)

	-- Lakes: open water off the end of each dock, and no ground over the dock.
	local lakes, lakesDry, docksBuried = 0, 0, 0
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "LakeDock" then
			lakes += 1
			local farEnd = (d.CFrame * CFrame.new(0, 0, -d.Size.Z / 2 + 1)).Position
			local water = workspace:Raycast(farEnd + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0), terrainWater)
			if not water or water.Material ~= Enum.Material.Water then
				lakesDry += 1
				example("lake", string.format("no open water off the dock at %s (hit %s)", v3(farEnd), water and water.Material.Name or "nothing"))
			end
			local nearEnd = (d.CFrame * CFrame.new(0, 0, d.Size.Z / 2 - 1)).Position
			local ground = workspace:Raycast(nearEnd + Vector3.new(0, 20, 0), Vector3.new(0, -40, 0), terrainParams)
			if ground and ground.Position.Y > nearEnd.Y + d.Size.Y / 2 then
				docksBuried += 1
				example("lake", string.format("ground %.2f over the dock's shore end at %s", ground.Position.Y - nearEnd.Y - d.Size.Y / 2, v3(nearEnd)))
			end
		end
	end
	out("  lakes: %d; without open water off the dock %d; docks buried %d", lakes, lakesDry, docksBuried)
	acceptance ..= string.format(", lakes dry %d/%d, docks buried %d", lakesDry, lakes, docksBuried)

	-- Ground diagnostics for the first few maps with an off point: a cross-section of the terrain
	-- surface through it, every 2 studs from 29 out on one side to 29 on the other, as height over
	-- the road's ground there.
	if (densePoke > 0 or denseFloat > 0) and diagnosed < 3 then
		diagnosed += 1
		for _, key in ipairs({ "densePoke", "denseFloat" }) do
			local text = examples[key] and examples[key][1]
			if text then
				local x, z = text:match("at %(([%-%d%.]+), ([%-%d%.]+)%)")
				x, z = tonumber(x), tonumber(z)
				for _, edge in ipairs(roads.edges) do
					local dx, dz = x - edge.from.X, z - edge.from.Z
					local along = dx * edge.dir.X + dz * edge.dir.Z
					local lateral = dx * edge.dir.Z - dz * edge.dir.X
					if along >= 0 and along <= edge.length and math.abs(lateral) <= 12 then
						local right = Vector3.new(-edge.dir.Z, 0, edge.dir.X)
						local ground = RN.EdgeHeight(edge, along)
						local row = {}
						for across = -29, 29, 2 do
							local p = edge.from + edge.dir * along + right * across
							local hit = workspace:Raycast(Vector3.new(p.X, ground + 120, p.Z), Vector3.new(0, -300, 0), terrainParams)
							table.insert(row, string.format("%d:%s", across, hit and string.format("%.2f", hit.Position.Y - ground) or "-"))
						end
						out("  DIAG %s cross-section at (%.1f, %.1f), %.0f along a %s-to-%s road, ground %.2f: %s", key, x, z, along, edge.a.kind, edge.b.kind, ground, table.concat(row, " "))
						-- The voxel columns across the same line: what GroundAt wants (over the road's
						-- ground), whether the corridor covers it, and the column's top solid voxel.
						local columns = {}
						for across = -30, 30, 4 do
							local p = edge.from + edge.dir * along + right * across
							local cx, cz = (math.floor(p.X / 4) + 0.5) * 4, (math.floor(p.Z / 4) + 0.5) * 4
							local region = Region3.new(Vector3.new(cx - 2, ground - 24, cz - 2), Vector3.new(cx + 2, ground + 24, cz + 2)):ExpandToGrid(4)
							local mats, occs = workspace.Terrain:ReadVoxels(region, 4)
							local origin = region.CFrame.Position - region.Size / 2
							local top = "air"
							for iy = mats.Size.Y, 1, -1 do
								if occs[1][iy][1] > 0 then
									top = string.format("%s@%.0f+%.2f", mats[1][iy][1].Name, origin.Y + (iy - 1) * 4, occs[1][iy][1])
									break
								end
							end
							local want = roads:GroundAt(cx, cz, 0)
							table.insert(columns, string.format("%d:%s/%s/%s", across, want and string.format("%.2f", want - ground) or "nil",
								roads:WithinCorridor(cx, cz) and "in" or "out", top))
						end
						out("  DIAG %s voxel columns (want/corridor/top): %s", key, table.concat(columns, " "))
						-- Anything built within 30 studs.
						local near, seen = {}, {}
						for _, d in ipairs(map:GetDescendants()) do
							if d:IsA("BasePart") then
								local offset = d.Position - Vector3.new(x, ground, z)
								if Vector3.new(offset.X, 0, offset.Z).Magnitude < 30 and not SURFACE[d.Name] and not MARKING[d.Name] then
									local owner = ownerOf(d) .. "/" .. d.Name
									if not seen[owner] then
										seen[owner] = true
										table.insert(near, owner)
									end
								end
							end
						end
						out("  DIAG %s parts within 30: %s", key, table.concat(near, ", "))
						-- Writing the corridor again: does it change?
						require(modules:WaitForChild("MapTerrain")).RestoreRoadGround(workspace.Terrain, roads, true)
						task.wait(1)
						local again = {}
						for across = -29, 29, 2 do
							local p = edge.from + edge.dir * along + right * across
							local hit = workspace:Raycast(Vector3.new(p.X, ground + 120, p.Z), Vector3.new(0, -300, 0), terrainParams)
							table.insert(again, string.format("%d:%s", across, hit and string.format("%.2f", hit.Position.Y - ground) or "-"))
						end
						out("  DIAG %s after writing the corridor again: %s", key, table.concat(again, " "))
						break
					end
				end
			end
		end
	end
	-- Does any of this actually fail? Three faults are planted in the built map -- one at a time, the
	-- last of them destructive -- and each is re-measured with the very same function that reported
	-- zero above. A check that still reads zero here is testing nothing, however clean the run looked
	-- (the road audit's own version of the footing ray that started inside the terrain).
	-- Planted on the first map only; the map is cleared straight afterwards either way.
	if roads and #roads.edges > 0 and not (selfTested.ground and selfTested.contact and selfTested.water) then
		local caught = {}

		-- (1) A block of rock standing 4 studs proud of the carriageway.
		local edge = nil
		for _, candidate in ipairs(roads.edges) do
			local onBridge = #(candidate.bridges or {}) > 0
			if candidate.length > 140 and not onBridge then
				edge = candidate
				break
			end
		end
		if edge and not selfTested.ground then
			selfTested.ground = true
			local along = edge.length / 2
			local p = edge.from + edge.dir * along
			local ground = RN.EdgeHeight(edge, along)
			workspace.Terrain:FillBlock(CFrame.new(p.X, ground + 1.5, p.Z), Vector3.new(6, 6, 6), Enum.Material.Rock)
			task.wait(1)
			local after = denseGround({ edge }, false)
			caught.ground = after.poke
		end

		-- (2) One road slab lifted a third of a stud out of line with its neighbours.
		local slab = nil
		for _, part in ipairs(contactParts) do
			if part.Name == "RoadSurface" and part.Size.Z < 40 then
				slab = part
				break
			end
		end
		if slab and not selfTested.contact then
			selfTested.contact = true
			local was = slab.CFrame
			slab.CFrame = was + Vector3.new(0, 0.33, 0)
			caught.contact = contactCheck(false)
			slab.CFrame = was
		end

		-- (3) A bridge with its deck taken away, where there was one.
		if waterCovered > 0 and not selfTested.water then
			selfTested.water = true
			for _, d in ipairs(map:GetDescendants()) do
				if d:IsA("BasePart") and (d.Name == "BridgeRoad" or d.Name == "BridgeDeck") then
					d:Destroy()
				end
			end
			task.wait()
			local _, _, uncovered = waterUnderRoads(roads.edges, false)
			caught.water = uncovered
		end

		local function tell(name, value)
			if value == nil then
				return name .. " no sample"
			end
			return string.format("%s %s (%d)", name, value > 0 and "CAUGHT" or "MISSED THE FAULT", value)
		end
		local missed = (caught.ground == 0) or (caught.contact == 0) or (caught.water == 0)
		local tried = caught.ground or caught.contact or caught.water
		if tried then
			out("  self-test (faults planted on purpose): %s, %s, %s%s", tell("raised ground", caught.ground),
				tell("slab out of line", caught.contact), tell("bridge deck removed", caught.water),
				missed and " -- A CHECK ISN'T TESTING ANYTHING" or "")
			acceptance ..= missed and ", SELF-TEST MISSED A PLANTED FAULT" or ", self-test ok"
		end
	end

	end)
	if not okAcceptance then
		out("  ACCEPTANCE CHECKS FAILED: %s", tostring(acceptanceError))
	end
	local keys = {}
	for key in pairs(examples) do
		table.insert(keys, key)
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		for _, text in ipairs(examples[key]) do
			out("    %s: %s", key, text)
		end
	end
	table.insert(totals, string.format("%s/%d holes %d unjustified-ends %d steps %d doubles %d overlaps %d+%d zfight %d floating %d buried %d; %s",
		MAP_ID, SEED, holes, unjustifiedEnds, steps.small + steps.medium + steps.large, doubles, surfaceTotal, markingTotal, #roadFlush, floating, buried, acceptance))
	print("[AUDIT roads] " .. totals[#totals])
	MapGenerator.Clear()
	task.wait(1)
end
out("TOTALS: %s", table.concat(totals, " || "))
