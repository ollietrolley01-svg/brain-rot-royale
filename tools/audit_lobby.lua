-- Lobby audit, for tools/runtest.ps1 -Probe. Built on the tools/audit_models.lua measuring code
-- (copied in; keep the two in step).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_lobby.lua
--
-- Builds the real lobby (LobbyService.Build) and measures every set piece. Each piece (the parts
-- carrying its "Group" attribute) is split into structures: parts that touch, grown by 0.05. The
-- biggest structure is the piece itself; every other one with visible parts is reported as
-- FLOATING with where it is and how far it is from the nearest part of the piece. Every structure
-- of 12 parts or more is then scanned for see-through OPENINGS along its own axes (a roof with sky
-- showing through it, a slit under a roof, a missing wall panel), with sizes and positions, plus
-- flush z-fight pairs. Open fronts, doorways and windows are openings too, so read the list against
-- the renders (tools/audit_lobby_gallery.lua).

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = RS:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(Shared:WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[AUDIT lobby] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.2f,%.2f,%.2f)", v.X, v.Y, v.Z)
end

local stage = Instance.new("Folder")
stage.Name = "AuditModels"
stage.Parent = workspace
local SPOT = Vector3.new(6000, 1500, 6000)

local function visibleParts(root)
	local list = {}
	local function consider(d)
		if d:IsA("BasePart") and d.Transparency < 0.98 then
			table.insert(list, d)
		end
	end
	if root:IsA("BasePart") then
		consider(root)
	end
	for _, d in ipairs(root:GetDescendants()) do
		consider(d)
	end
	return list
end

-- Connected groups of visible parts. Queries skip CanQuery=false parts, so it is switched on for
-- the parts measured (they belong to a throwaway copy).
local function components(parts)
	for _, part in ipairs(parts) do
		part.CanQuery = true
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = parts
	local parent = {}
	local function find(x)
		while parent[x] ~= x do
			parent[x] = parent[parent[x]]
			x = parent[x]
		end
		return x
	end
	for _, part in ipairs(parts) do
		parent[part] = part
	end
	local touching = {}
	local nearMisses = {}
	for _, part in ipairs(parts) do
		local probe = part:Clone()
		probe:ClearAllChildren()
		probe.Size = part.Size + Vector3.new(0.1, 0.1, 0.1)
		probe.Transparency = 1
		probe.Anchored = true
		probe.CanQuery = false
		probe.Parent = stage
		touching[part] = {}
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if other ~= part and parent[other] then
				touching[part][other] = true
				local a, b = find(part), find(other)
				if a ~= b then
					parent[a] = b
				end
			end
		end
		-- Near misses: within a quarter stud but not touching. Pieces meant to meet that stop short.
		probe.Size = part.Size + Vector3.new(0.5, 0.5, 0.5)
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if other ~= part and parent[other] and not touching[part][other] then
				table.insert(nearMisses, { part, other })
			end
		end
		probe:Destroy()
	end
	local groups = {}
	for _, part in ipairs(parts) do
		local r = find(part)
		groups[r] = groups[r] or {}
		table.insert(groups[r], part)
	end
	local list = {}
	for _, group in pairs(groups) do
		table.insert(list, group)
	end
	table.sort(list, function(a, b)
		return #a > #b
	end)
	-- Each near-missing pair once, and only if neither side's probe found them touching.
	local misses, seen = {}, {}
	for _, pair in ipairs(nearMisses) do
		local a, b = pair[1], pair[2]
		local key = a:GetDebugId() < b:GetDebugId() and (a:GetDebugId() .. b:GetDebugId()) or (b:GetDebugId() .. a:GetDebugId())
		if not touching[a][b] and not touching[b][a] and not seen[key] then
			seen[key] = true
			table.insert(misses, pair)
		end
	end
	return list, misses
end

local function inside(point, part)
	local l = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	local shape = part:IsA("Part") and part.Shape or Enum.PartType.Block
	if shape == Enum.PartType.Ball then
		return l.Magnitude <= math.min(half.X, half.Y, half.Z)
	elseif shape == Enum.PartType.Cylinder then
		return math.abs(l.X) <= half.X and Vector2.new(l.Y, l.Z).Magnitude <= math.min(half.Y, half.Z)
	elseif part:IsA("WedgePart") then
		-- Full height at +Z, zero at -Z.
		if math.abs(l.X) > half.X or math.abs(l.Z) > half.Z or l.Y < -half.Y then
			return false
		end
		return l.Y <= -half.Y + (l.Z + half.Z) / (2 * half.Z) * 2 * half.Y
	end
	return math.abs(l.X) <= half.X and math.abs(l.Y) <= half.Y and math.abs(l.Z) <= half.Z
end

local function samplePoints(part)
	local half = part.Size / 2 * 0.98
	local points = { part.Position }
	local shape = part:IsA("Part") and part.Shape or Enum.PartType.Block
	if shape == Enum.PartType.Ball then
		local r = math.min(half.X, half.Y, half.Z)
		for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }) do
			table.insert(points, part.CFrame * (d * r))
		end
	else
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					table.insert(points, part.CFrame * Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				end
			end
		end
	end
	return points
end


-- See-through openings: rays straight through the model along each of its own axes on a grid. A ray
-- that hits nothing while the model has something on both sides of it along the row AND along the
-- column is an enclosed opening (a hole in a lid, a slit between panels). Neighbouring misses are
-- one opening; each is reported with its size in grid cells and area. Designed openings (a handle's
-- loop) show up too, so read the list, don't just count it.
local function seeThrough(parts, pivot, cells)
	cells = cells or 60
	for _, part in ipairs(parts) do
		part.CanQuery = true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = parts
	local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, part in ipairs(parts) do
		for _, point in ipairs(samplePoints(part)) do
			local l = pivot:PointToObjectSpace(point)
			lo = Vector3.new(math.min(lo.X, l.X), math.min(lo.Y, l.Y), math.min(lo.Z, l.Z))
			hi = Vector3.new(math.max(hi.X, l.X), math.max(hi.Y, l.Y), math.max(hi.Z, l.Z))
		end
	end
	local size = hi - lo
	local step = math.max(size.X, size.Y, size.Z) / cells
	local axes = { { "X", Vector3.xAxis, "Y", "Z" }, { "Y", Vector3.yAxis, "X", "Z" }, { "Z", Vector3.zAxis, "X", "Y" } }
	local openings = {}
	for _, axis in ipairs(axes) do
		local along, uName, vName = axis[2], axis[3], axis[4]
		local nu = math.max(1, math.floor(size[uName] / step))
		local nv = math.max(1, math.floor(size[vName] / step))
		local hit = {}
		for i = 0, nu do
			hit[i] = {}
			for j = 0, nv do
				local u = lo[uName] + (i + 0.5) * step
				local v = lo[vName] + (j + 0.5) * step
				local startLocal = Vector3.new(0, 0, 0)
				local function set(name, value)
					startLocal = Vector3.new(name == "X" and value or startLocal.X, name == "Y" and value or startLocal.Y, name == "Z" and value or startLocal.Z)
				end
				set(uName, u)
				set(vName, v)
				set(axis[1], lo[axis[1]] - 1)
				local from = pivot * startLocal
				local direction = pivot:VectorToWorldSpace(along) * (size[axis[1]] + 2)
				hit[i][j] = workspace:Raycast(from, direction, params) ~= nil
			end
		end
		local enclosed = {}
		for i = 0, nu do
			for j = 0, nv do
				if not hit[i][j] then
					local left, right, down, up = false, false, false, false
					for k = 0, i - 1 do left = left or hit[k][j] end
					for k = i + 1, nu do right = right or hit[k][j] end
					for k = 0, j - 1 do down = down or hit[i][k] end
					for k = j + 1, nv do up = up or hit[i][k] end
					if left and right and down and up then
						enclosed[i .. "," .. j] = true
					end
				end
			end
		end
		local seen = {}
		for key in pairs(enclosed) do
			if not seen[key] then
				local stack, count, minI, maxI, minJ, maxJ = { key }, 0, math.huge, -math.huge, math.huge, -math.huge
				seen[key] = true
				while #stack > 0 do
					local current = table.remove(stack)
					local ci, cj = string.match(current, "(-?%d+),(-?%d+)")
					ci, cj = tonumber(ci), tonumber(cj)
					count += 1
					minI, maxI, minJ, maxJ = math.min(minI, ci), math.max(maxI, ci), math.min(minJ, cj), math.max(maxJ, cj)
					for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
						local nextKey = (ci + d[1]) .. "," .. (cj + d[2])
						if enclosed[nextKey] and not seen[nextKey] then
							seen[nextKey] = true
							table.insert(stack, nextKey)
						end
					end
				end
				local centreU = lo[uName] + ((minI + maxI) / 2 + 0.5) * step
				local centreV = lo[vName] + ((minJ + maxJ) / 2 + 0.5) * step
				table.insert(openings, { axis = axis[1], cells = count, area = count * step * step,
					span = string.format("%.2fx%.2f", (maxI - minI + 1) * step, (maxJ - minJ + 1) * step),
					at = string.format("%s=%.2f %s=%.2f", uName, centreU, vName, centreV) })
			end
		end
	end
	table.sort(openings, function(a, b)
		return a.area > b.area
	end)
	return openings, step
end

-- The measurements for one model. `pivot` is the frame its symmetry and base are measured in.
local function analyze(model, pivot, options)
	options = options or {}
	local parts = visibleParts(model)
	local report = { parts = #parts, floating = {}, flush = 0, flushLines = {}, mirror = {}, buried = {}, unwelded = 0 }

	local groups, misses = components(parts)
	report.nearMiss = {}
	local mainGroup = {}
	for _, part in ipairs(groups[1] or {}) do
		mainGroup[part] = true
	end
	for _, pair in ipairs(misses) do
		if not mainGroup[pair[1]] or not mainGroup[pair[2]] then
			table.insert(report.nearMiss, string.format("%s~%s @%s", pair[1].Name, pair[2].Name, v3(pivot:PointToObjectSpace((pair[1].Position + pair[2].Position) / 2))))
		end
	end
	for index = 2, #groups do
		local names, centre = {}, Vector3.zero
		for _, part in ipairs(groups[index]) do
			names[part.Name] = (names[part.Name] or 0) + 1
			centre += part.Position
		end
		local list = {}
		for name, n in pairs(names) do
			table.insert(list, n > 1 and (name .. " x" .. n) or name)
		end
		table.sort(list)
		table.insert(report.floating, table.concat(list, "+") .. " @" .. v3(pivot:PointToObjectSpace(centre / #groups[index])))
	end

	local flush = ZFight.Scan({ model }, options.tolerance)
	report.flush = #flush
	if #flush > 0 then
		report.flushLines = ZFight.Describe(flush, function()
			return ""
		end, 4)
	end

	if options.mirror ~= false then
		local byKey = {}
		for _, part in ipairs(parts) do
			local key = string.format("%s|%.2f|%.2f|%.2f|%s", part.Name, part.Size.X, part.Size.Y, part.Size.Z, part:IsA("Part") and part.Shape.Name or part.ClassName)
			byKey[key] = byKey[key] or {}
			table.insert(byKey[key], part)
		end
		for _, group in pairs(byKey) do
			if #group >= 2 then
				for _, p in ipairs(group) do
					local lp = pivot:PointToObjectSpace(p.Position)
					if math.abs(lp.X) > 0.02 then
						local best = math.huge
						for _, q in ipairs(group) do
							if q ~= p then
								local lq = pivot:PointToObjectSpace(q.Position)
								if lq.X * lp.X < 0 then
									best = math.min(best, (Vector3.new(-lq.X, lq.Y, lq.Z) - lp).Magnitude)
								end
							end
						end
						if best > 0.01 and best < 0.35 and lp.X > 0 then
							table.insert(report.mirror, string.format("%s off its mirror twin by %.3f @%s", p.Name, best, v3(lp)))
						end
					end
				end
			end
		end
	end

	-- Candidates come from a bounds query (components() already switched CanQuery on), so large
	-- models don't cost every pair.
	local boundsParams = OverlapParams.new()
	boundsParams.FilterType = Enum.RaycastFilterType.Include
	boundsParams.FilterDescendantsInstances = parts
	for _, p in ipairs(parts) do
		for _, q in ipairs(workspace:GetPartBoundsInBox(p.CFrame, p.Size, boundsParams)) do
			if q ~= p and q.Transparency < 0.05 and q.Material ~= Enum.Material.Glass and q.Material ~= Enum.Material.ForceField
				and q.Size.Magnitude > p.Size.Magnitude * 0.5 then
				local all = true
				for _, point in ipairs(samplePoints(p)) do
					if not inside(point, q) then
						all = false
						break
					end
				end
				if all then
					table.insert(report.buried, string.format("%s inside %s @%s", p.Name, q.Name, v3(pivot:PointToObjectSpace(p.Position))))
					break
				end
			end
		end
	end

	if options.root then
		local connected = {}
		for _, part in ipairs(options.root:GetConnectedParts(true)) do
			connected[part] = true
		end
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and not d.Anchored and not connected[d] then
				report.unwelded += 1
			end
		end
	end

	if options.seeThrough then
		local openings, step = seeThrough(parts, pivot)
		report.openings = {}
		for index = 1, math.min(6, #openings) do
			local o = openings[index]
			table.insert(report.openings, string.format("along %s: %d cells (%.3f sq studs, %s) at %s", o.axis, o.cells, o.area, o.span, o.at))
		end
		report.openingCount = #openings
	end

	if options.base then
		local lowest = math.huge
		for _, part in ipairs(parts) do
			for _, point in ipairs(samplePoints(part)) do
				lowest = math.min(lowest, pivot:PointToObjectSpace(point).Y)
			end
		end
		report.base = lowest
	end
	return report
end


local LobbyService = require(modules:WaitForChild("LobbyService"))
local GROUPS_ONLY = nil -- e.g. { TradingHall = true }

local lobbyFolder = Instance.new("Folder")
lobbyFolder.Name = "AuditLobby"
lobbyFolder.Parent = workspace
local base = Vector3.new(0, 2000, 0)
-- The nudge count below reads the ZFixed attribute ZFight.Fix leaves on what it moves. Check that
-- it does before trusting a zero: two flush plates, one pass, and the moved one must be marked.
do
	local ZFightCheck = require(RS:WaitForChild("Shared"):WaitForChild("ZFight"))
	local holder = Instance.new("Model")
	for index = 1, 2 do
		local plate = Instance.new("Part")
		plate.Anchored = true
		plate.Size = Vector3.new(4, 1, 4)
		plate.CFrame = CFrame.new(0, -3000, index * 0.5)
		plate.Parent = holder
	end
	ZFightCheck.Fix({ holder }, { terrain = false })
	local marked = 0
	for _, plate in ipairs(holder:GetChildren()) do
		if plate:GetAttribute("ZFixed") then
			marked += 1
		end
	end
	out("self-test: a planted flush pair left %d part(s) marked ZFixed (want at least 1) -> %s", marked, marked > 0 and "PASS" or "FAIL")
	holder:Destroy()
end
local okBuild, errBuild = pcall(LobbyService.Build, lobbyFolder, base)
out("lobby build: %s", okBuild and "ok" or tostring(errBuild))
task.wait(1)

local groups = {}
for _, d in ipairs(lobbyFolder:GetDescendants()) do
	if d:IsA("BasePart") then
		local node, group = d, nil
		while node and node ~= lobbyFolder do
			group = node:GetAttribute("Group")
			if group then
				break
			end
			node = node.Parent
		end
		group = group or "(untagged)"
		if not GROUPS_ONLY or GROUPS_ONLY[group] then
			groups[group] = groups[group] or {}
			table.insert(groups[group], d)
		end
	end
end
local names = {}
for name in pairs(groups) do
	table.insert(names, name)
end
table.sort(names)

local function yawFrame(parts)
	local biggest, volume = nil, -1
	local centre = Vector3.zero
	for _, part in ipairs(parts) do
		centre += part.Position
		local v = part.Size.X * part.Size.Y * part.Size.Z
		if v > volume then
			biggest, volume = part, v
		end
	end
	centre /= #parts
	local look = biggest.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.2 then
		local right = biggest.CFrame.RightVector
		flat = Vector3.new(-right.Z, 0, right.X)
	end
	flat = flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
	return CFrame.lookAt(centre, centre + flat)
end

local summary = {}
for _, name in ipairs(names) do
	local all = groups[name]
	local visible = {}
	for _, part in ipairs(all) do
		if part.Transparency < 0.98 then
			table.insert(visible, part)
		end
	end
	local structures, misses = components(visible)
	local floating, openingsTotal, flushTotal = 0, 0, 0
	local main = structures[1] or {}
	local mainSet = {}
	for _, part in ipairs(main) do
		mainSet[part] = true
	end
	out("== %s: %d parts (%d visible), %d structures", name, #all, #visible, #structures)
	for index, structure in ipairs(structures) do
		local centre = Vector3.zero
		local label = {}
		for _, part in ipairs(structure) do
			centre += part.Position
			label[part.Name] = (label[part.Name] or 0) + 1
		end
		centre /= #structure
		local list = {}
		for partName, n in pairs(label) do
			table.insert(list, n > 1 and (partName .. " x" .. n) or partName)
		end
		table.sort(list, function(a, b)
			return #a < #b
		end)
		local labelText = table.concat(list, "+", 1, math.min(#list, 6)) .. (#list > 6 and "+..." or "")
		if index > 1 then
			-- Anything not touching the rest of its own set piece. Nearest gap to the piece's main
			-- structure, measured between bounding boxes (0 = the boxes overlap: only the shapes miss).
			local gap = math.huge
			for _, part in ipairs(structure) do
				for _, other in ipairs(main) do
					local d = (part.Position - other.Position).Magnitude - (part.Size.Magnitude + other.Size.Magnitude) / 2
					gap = math.min(gap, d)
				end
			end
			-- Floated on purpose (IntentionalFloat on every part: spinning tokens and the like) is
			-- listed but not counted.
			local intended = true
			for _, part in ipairs(structure) do
				if not part:GetAttribute("IntentionalFloat") then
					intended = false
					break
				end
			end
			if not intended then
				floating += 1
			end
			out("  %s structure %d (%d parts: %s) at %s, rel. %s, approx gap to the piece %.2f", intended and "intentionally floating" or "floating",
				index, #structure, labelText, v3(centre), v3(centre - base), math.max(0, gap))
		end
		if #structure >= 12 then
			local pivot = yawFrame(structure)
			local openings, step = seeThrough(structure, pivot, 90)
			openingsTotal += #openings
			local flushPairs = ZFight.Scan(structure)
			flushTotal += #flushPairs
			if #openings > 0 or #flushPairs > 0 then
				out("  structure %d (%d parts: %s) at rel. %s: %d see-through openings (grid %.2f)%s", index, #structure, labelText, v3(centre - base),
					#openings, step, #flushPairs > 0 and string.format(", %d flush pairs", #flushPairs) or "")
				for o = 1, math.min(12, #openings) do
					local opening = openings[o]
					out("    opening along %s: %.2f sq studs, %s, at %s (local to the structure's frame)", opening.axis, opening.area, opening.span, opening.at)
				end
			end
		end
		if index % 20 == 0 then
			task.wait()
		end
	end
	-- Flush pairs are scanned after LobbyService.Build's own z-fight pass, which has already nudged
	-- them apart, so on their own they prove nothing. What that pass had to change is the real
	-- measure: every part it moved or resized carries ZFixed (how far) and ZFixedWith (what it fought).
	local nudged, nudgedBy, patterns = 0, 0, {}
	-- The worst few, with where they are and how big they are: a count and a largest distance say
	-- there's a stack of coplanar faces somewhere but not WHICH stack, and a nudge only matters when
	-- it's large against the part it moved (0.6 is nothing on a dais and everything on a 0.3 cell).
	local worst = {}
	for _, part in ipairs(all) do
		local fixed = part:GetAttribute("ZFixed")
		if fixed then
			nudged += 1
			nudgedBy = math.max(nudgedBy, fixed)
			local key = part.Name .. "/" .. tostring(part:GetAttribute("ZFixedWith"))
			patterns[key] = (patterns[key] or 0) + 1
			table.insert(worst, { part = part, fixed = fixed })
		end
	end
	table.sort(worst, function(a, b)
		return a.fixed > b.fixed
	end)
	for index = 1, math.min(#worst, 5) do
		local entry = worst[index]
		local part, size = entry.part, entry.part.Size
		local smallest = math.min(size.X, size.Y, size.Z)
		out("    worst %d: %s moved %.3f (%.1fx its thinnest side %.2f), size %.2f,%.2f,%.2f, at %s, fought %s",
			index, part.Name, entry.fixed, entry.fixed / math.max(smallest, 0.001), smallest, size.X, size.Y, size.Z,
			v3(part.Position), tostring(part:GetAttribute("ZFixedWith")))
	end
	if nudged > 0 then
		local list = {}
		for key, count in pairs(patterns) do
			table.insert(list, key .. " x" .. count)
		end
		table.sort(list)
		out("  z-fight pass changed %d parts (largest %.3f): %s", nudged, nudgedBy, table.concat(list, ", ", 1, math.min(#list, 12)))
	end
	table.insert(summary, string.format("%s: %d structures, %d floating, %d openings, %d flush, %d nudged", name, #structures, floating, openingsTotal,
		flushTotal, nudged))
	pcall(flush)
	task.wait()
end
out("SUMMARY %s", table.concat(summary, " | "))
lobbyFolder:Destroy()
pcall(flush)
