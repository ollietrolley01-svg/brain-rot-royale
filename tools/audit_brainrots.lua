-- Brainrot model audit, for tools/runtest.ps1 -Probe. A copy of tools/audit_models.lua with FAMILIES
-- set to the brainrot families; the measuring code is identical, so keep the two in step.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_brainrots.lua
--
--   brainrots       all BrainrotData.Types as built (floating, flush, mirror, buried)
--   brainrotParts   every body with each of the 38 extras, 13 eyes and 11 mouths (floating, flush,
--                   buried, crooked centred extras, extras sinking below the body's base)
--   statues         each creature as a lobby statue and a plaza statue after the world z-fight pass:
--                   parts moved or resized by it
-- See tools/audit_models.lua for what each measurement means.

local FAMILIES = { "brainrots", "brainrotParts", "statues" }
-- Other families: "brainrots", "brainrotParts", "landmarks", "eggs"

local RS = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local Shared = RS:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(Shared:WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[AUDIT models] " .. string.format(fmt, ...))
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

-- A part drawn as an ellipsoid by a sphere SpecialMesh: its centre frame and half-axes, or nil.
-- (Collision and bounds queries still see the box; only these shape tests use the ellipsoid.)
local function ellipsoidOf(part)
	local mesh = part:FindFirstChildOfClass("SpecialMesh")
	if not mesh or mesh.MeshType ~= Enum.MeshType.Sphere then
		return nil
	end
	return part.CFrame * CFrame.new(mesh.Offset), part.Size / 2 * mesh.Scale
end

local function inside(point, part)
	local frame, axes = ellipsoidOf(part)
	if frame then
		local e = frame:PointToObjectSpace(point)
		return (e.X / axes.X) ^ 2 + (e.Y / axes.Y) ^ 2 + (e.Z / axes.Z) ^ 2 <= 1
	end
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
	local frame, axes = ellipsoidOf(part)
	if frame then
		-- The six ends of its axes and eight points on the surface between them.
		axes *= 0.98
		for _, d in ipairs({ Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }) do
			table.insert(points, frame * (d * axes))
		end
		local k = 1 / math.sqrt(3)
		for _, sx in ipairs({ -1, 1 }) do
			for _, sy in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					table.insert(points, frame * Vector3.new(sx * k * axes.X, sy * k * axes.Y, sz * k * axes.Z))
				end
			end
		end
		return points
	end
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
		if (not mainGroup[pair[1]] or not mainGroup[pair[2]])
			and not (pair[1]:GetAttribute("IntentionalFloat") or pair[2]:GetAttribute("IntentionalFloat")) then
			table.insert(report.nearMiss, string.format("%s~%s @%s", pair[1].Name, pair[2].Name, v3(pivot:PointToObjectSpace((pair[1].Position + pair[2].Position) / 2))))
		end
	end
	report.intentionalFloat = 0
	for index = 2, #groups do
		local names, centre = {}, Vector3.zero
		-- A group floated on purpose (IntentionalFloat on every part: an orbiting ring, a halo) isn't
		-- a finding here; it still goes through the flush and clipping checks below with the rest.
		local intended = true
		for _, part in ipairs(groups[index]) do
			names[part.Name] = (names[part.Name] or 0) + 1
			centre += part.Position
			if not part:GetAttribute("IntentionalFloat") then
				intended = false
			end
		end
		local list = {}
		for name, n in pairs(names) do
			table.insert(list, n > 1 and (name .. " x" .. n) or name)
		end
		table.sort(list)
		if intended then
			report.intentionalFloat += 1
		else
			table.insert(report.floating, table.concat(list, "+") .. " @" .. v3(pivot:PointToObjectSpace(centre / #groups[index])))
		end
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
					-- Scattered on purpose (sprinkles, noodles, fries, quills, a tilted ring, an off-centre
					-- flower): the builder marks those IntentionalAsymmetry, and sloppy symmetry is only a
					-- finding where symmetry was meant.
					if math.abs(lp.X) > 0.02 and not p:GetAttribute("IntentionalAsymmetry") then
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

local totals = {}
local function tally(family, report, name, extra)
	local t = totals[family] or { models = 0, parts = 0, floating = 0, flush = 0, mirror = 0, buried = 0, unwelded = 0, base = 0, nearMiss = 0, lines = {} }
	totals[family] = t
	t.models += 1
	t.parts += report.parts
	local problems = {}
	if #report.floating > 0 then
		t.floating += #report.floating
		table.insert(problems, "floating " .. table.concat(report.floating, "; "))
	end
	if report.flush > 0 then
		t.flush += report.flush
		table.insert(problems, "flush " .. report.flush .. " [" .. table.concat(report.flushLines, " | ") .. "]")
	end
	if #report.mirror > 0 then
		t.mirror += #report.mirror
		table.insert(problems, "mirror " .. table.concat(report.mirror, "; "))
	end
	if report.openingCount and report.openingCount > 0 then
		t.openings = (t.openings or 0) + report.openingCount
		table.insert(problems, "see-through openings " .. report.openingCount .. " [" .. table.concat(report.openings, "; ") .. "]")
	end
	if report.nearMiss and #report.nearMiss > 0 then
		t.nearMiss += #report.nearMiss
		table.insert(problems, "near-miss gaps (0.05-0.25) " .. table.concat(report.nearMiss, "; "))
	end
	if #report.buried > 0 then
		t.buried += #report.buried
		table.insert(problems, "buried " .. table.concat(report.buried, "; "))
	end
	if report.unwelded > 0 then
		t.unwelded += report.unwelded
		table.insert(problems, "unwelded " .. report.unwelded)
	end
	if report.base and math.abs(report.base) > 0.05 then
		t.base += 1
		table.insert(problems, string.format("base %.3f off its origin", report.base))
	end
	if extra then
		for _, line in ipairs(extra) do
			table.insert(problems, line)
		end
	end
	if #problems > 0 then
		table.insert(t.lines, name .. ": " .. table.concat(problems, " || "))
	end
end

local function park(model, index)
	local at = CFrame.new(SPOT + Vector3.new((index % 20) * 40, 0, math.floor(index / 20) * 40))
	model:PivotTo(at)
	model.Parent = stage
	return at
end

local runners = {}

-- The scales items are really built at: 1 in hands, icons and viewmodels; 1.25 as pickups; 1.5 as
-- thrown defense kits; 3 as a deployed mine and as the drop-in / glider canopy.
local ITEM_SCALES = {
	RotBarricade = { 1, 1.25, 1.5 }, PopupBunker = { 1, 1.25, 1.5 }, BrainrotFortress = { 1, 1.25, 1.5 }, RotMine = { 1, 1.25, 1.5, 3 },
}

-- The open wing seen from its arc's centre: rays inward through the skin across its whole span and
-- depth. Any that pass straight through are holes; neighbouring ones are one slit.
local function canopyHoles(model, pivot, scale)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local parts = visibleParts(model)
	for _, part in ipairs(parts) do
		part.CanQuery = true
	end
	params.FilterDescendantsInstances = parts
	local centre = pivot * Vector3.new(0, 0.3 * scale, 0)
	local rays, misses, slits, widest, run = 0, 0, 0, 0, 0
	for tenth = -820, 820, 2 do
		local angle = math.rad(tenth / 10)
		local outward = pivot:VectorToWorldSpace(Vector3.new(math.sin(angle), math.cos(angle), 0))
		local missedHere = false
		for z = -0.7, 0.7001, 0.1 do
			rays += 1
			local from = centre + pivot:VectorToWorldSpace(Vector3.new(0, 0, z * scale)) + outward * 2.9 * scale
			if not workspace:Raycast(from, -outward * 1.2 * scale, params) then
				misses += 1
				missedHere = true
			end
		end
		if missedHere then
			run += 1
		elseif run > 0 then
			slits += 1
			widest = math.max(widest, run * math.rad(0.2) * 2.38 * scale)
			run = 0
		end
	end
	if run > 0 then
		slits += 1
		widest = math.max(widest, run * math.rad(0.2) * 2.38 * scale)
	end
	return rays, misses, slits, widest
end

runners.items = function()
	local ItemData = require(Shared:WaitForChild("ItemData"))
	local ItemModels = require(Shared:WaitForChild("ItemModels"))
	local index = 0
	for _, id in ipairs(ItemData.Order) do
		for _, open in ipairs(id == "RotGlider" and { false, true } or { false }) do
			local scales = ITEM_SCALES[id] or { 1, 1.25 }
			if id == "RotGlider" and open then
				scales = { 1, 3 }
			end
			for _, scale in ipairs(scales) do
				index += 1
				local model = ItemModels.Build(id, { scale = scale, open = open })
				local at = park(model, index)
				local extra = nil
				if id == "RotGlider" and open then
					local rays, misses, slits, widest = canopyHoles(model, at, scale)
					out("items: open RotGlider x%.2f see-through test: %d rays, %d through the skin, %d slits, widest %.3f studs", scale, rays, misses, slits, widest)
					if misses > 0 then
						extra = { string.format("see-through: %d of %d rays pass through the canopy, %d slits, widest %.3f", misses, rays, slits, widest) }
					end
				end
				tally("items", analyze(model, at, { seeThrough = true }), string.format("%s%s x%.2f", id, open and " (open)" or "", scale), extra)
				-- The z-fight pass kits and mines get again in the world (DefenseService/HazardService).
				local again = ZFight.Fix({ model }, { all = true })
				if again.moved + again.resized > 0 then
					tally("items", { parts = 0, floating = {}, flush = 0, flushLines = {}, mirror = {}, buried = {}, unwelded = 0 },
						string.format("%s%s x%.2f second pass", id, open and " (open)" or "", scale),
						{ string.format("a second ZFight.Fix({model}, {all = true}) still moved %d and resized %d parts", again.moved, again.resized) })
				end
				model:Destroy()
			end
		end
		-- Held copies are built unanchored and welded to the body.
		index += 1
		local held, body = ItemModels.Build(id, { anchored = false })
		for _, d in ipairs(held:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = false
			end
		end
		body.Anchored = true
		local at = park(held, index)
		tally("items", analyze(held, at, { root = body, mirror = false }), id .. " (held, welded)")
		held:Destroy()
	end
end

runners.crates = function()
	local CrateModels = require(Shared:WaitForChild("CrateModels"))
	local Rarity = require(Shared:WaitForChild("Rarity"))
	local index = 100
	for _, tier in ipairs(Rarity.Order or { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }) do
		index += 1
		local ok, model = pcall(CrateModels.Crate, tier)
		if ok and model then
			local at = park(model, index)
			tally("crates", analyze(model, at, { base = true, seeThrough = true }), "Crate " .. tier)
			model:Destroy()
		else
			out("crate %s failed: %s", tier, tostring(model))
		end
	end
	index += 1
	local at = CFrame.new(SPOT + Vector3.new(0, 0, -200))
	local chest = CrateModels.Chest(at)
	chest.Parent = stage
	tally("crates", analyze(chest, at, { base = true, seeThrough = true }), "Chest (shut)")
	chest:Destroy()
end

runners.hazards = function()
	local HazardService = require(modules:WaitForChild("HazardService"))
	local at = CFrame.new(SPOT + Vector3.new(0, 0, -300))
	local barrel = HazardService.Barrel(stage, at)
	barrel = barrel or stage:FindFirstChild("ExplosiveBarrel")
	if barrel then
		tally("hazards", analyze(barrel, at, { base = true }), "ExplosiveBarrel")
		barrel:Destroy()
	end
	-- The mine lands on whatever is under it: give it a plate.
	local plate = Instance.new("Part")
	plate.Anchored = true
	plate.Size = Vector3.new(20, 1, 20)
	plate.Position = SPOT + Vector3.new(60, -0.5, -300)
	plate.Parent = stage
	local okMine, mine = pcall(HazardService.Mine, stage, SPOT + Vector3.new(60, 0, -300), nil)
	if okMine and mine then
		local pivot = CFrame.new(SPOT + Vector3.new(60, 0, -300))
		tally("hazards", analyze(mine, mine:GetPivot(), { base = false, mirror = false }), "RotMine (deployed)")
		local lowest = math.huge
		for _, part in ipairs(visibleParts(mine)) do
			lowest = math.min(lowest, part.Position.Y - part.Size.Y / 2)
		end
		out("hazards: deployed mine lowest point %.3f above the plate top", lowest - SPOT.Y)
		mine:Destroy()
	else
		out("hazards: mine failed: %s", tostring(mine))
	end
	plate:Destroy()
end

runners.defenses = function()
	local DefenseService = require(modules:WaitForChild("DefenseService"))
	for index, id in ipairs({ "RotBarricade", "PopupBunker", "BrainrotFortress" }) do
		local at = CFrame.new(SPOT + Vector3.new(index * 60, 0, -400))
		local ok, model = pcall(DefenseService.Build, id, at, nil)
		if ok and model then
			if not model.Parent then
				model.Parent = stage
			end
			task.wait(1.5) -- the rise tween
			tally("defenses", analyze(model, at, { base = true }), id)
			model:Destroy()
		else
			out("defense %s failed: %s", id, tostring(model))
		end
	end
end

runners.vendors = function()
	local VendorService = require(modules:WaitForChild("VendorService"))
	local at = CFrame.new(SPOT + Vector3.new(0, 0, -500))
	local ok, model = pcall(VendorService.Build, stage, at)
	model = ok and (model or stage:FindFirstChild("RotVendor")) or nil
	if model then
		tally("vendors", analyze(model, at, { base = true }), "RotVendor")
		model:Destroy()
	else
		out("vendor failed")
	end
end

runners.vehicles = function()
	local VehicleService = require(modules:WaitForChild("VehicleService"))
	for index, kind in ipairs({ "car", "bike" }) do
		local position = SPOT + Vector3.new(index * 40, 0, -600)
		local ok, model = pcall(VehicleService.Create, stage, position, 0, kind)
		model = ok and model or nil
		if model then
			local pivot = CFrame.new(position)
			local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
			tally("vehicles", analyze(model, pivot, { base = true, root = root }), "Vehicle " .. kind)
			model:Destroy()
		else
			out("vehicle %s failed: %s", kind, tostring(model))
		end
	end
end

runners.zipline = function()
	local ZiplineService = require(modules:WaitForChild("ZiplineService"))
	local from = SPOT + Vector3.new(0, 30, -700)
	local to = SPOT + Vector3.new(80, 0, -700)
	local ok, model = pcall(ZiplineService.Create, stage, from, to, nil)
	if ok and model then
		if not model.Parent then
			model.Parent = stage
		end
		tally("zipline", analyze(model, CFrame.new(from), { mirror = false }), "Zipline")
		model:Destroy()
	else
		out("zipline failed: %s", tostring(model))
	end
end

runners.accessories = function()
	local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
	local AccessoryService = require(modules:WaitForChild("AccessoryService"))
	local okRig, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if not okRig or not rig then
		out("accessories: no R15 rig in this mode (%s); skipped", tostring(rig))
		return
	end
	for _, d in ipairs(rig:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	rig:PivotTo(CFrame.new(SPOT + Vector3.new(0, 5, -800)))
	rig.Parent = stage
	local ids = {}
	for id, item in pairs(CosmeticData.Items or CosmeticData) do
		if type(item) == "table" and item.kind == "Accessory" then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	local head = rig:FindFirstChild("Head")
	for _, id in ipairs(ids) do
		AccessoryService.Attach(rig, id)
		local accessory = rig:FindFirstChild("CosmeticAccessory")
		if accessory then
			local item = CosmeticData.Get(id)
			local pivot = item.anchor == "Back" and rig.UpperTorso.CFrame or head.CFrame
			local report = analyze(accessory, pivot, { mirror = true })
			-- Worn: every piece should touch the rig part it hangs on.
			local wearer = item.anchor == "Back" and rig.UpperTorso or head
			local all = visibleParts(accessory)
			table.insert(all, wearer)
			local groups = components(all)
			local notTouching = 0
			for _, group in ipairs(groups) do
				if not table.find(group, wearer) then
					notTouching += #group
				end
			end
			local extra = {}
			if notTouching > 0 then
				table.insert(extra, string.format("%d pieces not touching the %s", notTouching, wearer.Name))
			end
			-- Anything sunk fully inside the head or torso?
			for _, part in ipairs(visibleParts(accessory)) do
				local sunk = true
				for _, point in ipairs(samplePoints(part)) do
					if not inside(point, wearer) then
						sunk = false
						break
					end
				end
				if sunk then
					table.insert(extra, part.Name .. " entirely inside the " .. wearer.Name)
				end
			end
			tally("accessories", report, id .. " (" .. tostring(item.anchor) .. ")", extra)
		end
	end
	AccessoryService.Attach(rig, nil)
	rig:Destroy()
end

local BODY_NAMES = { "Blob", "Bean", "Cube", "Pear", "Disc", "Stack", "Egg", "Mushroom", "Cloud", "Can", "Cone", "Ghost", "Loaf", "Totem" }
local EXTRAS_KNOWN = { "Horns", "Antenna", "Ears", "Wings", "Crown", "Halo", "Tail", "Feet", "Arms", "Cap", "Spikes", "Leaf", "Propeller", "Bow",
	"Mustache", "Shades", "Scarf", "Flame", "Orbit", "Antlers", "Fins", "Tentacles", "TopHat", "Headphones", "Cape",
	"Monocle", "Beard", "Petals", "Gem", "Spots", "Stripes", "Blush", "Unicorn", "Whiskers", "Helmet", "Bolt", "Shell", "Tie" }
-- Every extra BrainrotModels builds, read from its source the way tools/verify.py reads it
-- (`extra == "Name"`), so new extras are audited without touching this file. The list above is
-- only the fallback if the source can't be read.
local EXTRAS = {}
do
	local ok, source = pcall(function()
		return Shared:WaitForChild("BrainrotModels").Source
	end)
	local seen = {}
	if ok and type(source) == "string" then
		for name in string.gmatch(source, 'extra == "(%w+)"') do
			if not seen[name] then
				seen[name] = true
				table.insert(EXTRAS, name)
			end
		end
	end
	if #EXTRAS == 0 then
		EXTRAS = EXTRAS_KNOWN
	end
end
local EYES = { "Round", "Sleepy", "Angry", "Worried", "Big", "Wink", "Hearts", "Stars", "Goggles", "Triple", "Cyclops", "Visor", "Dots" }
local MOUTHS = { "Smile", "Grin", "O", "Fangs", "Tongue", "Beak", "Teeth", "Frown", "Wavy", "Tusks", "None" }
-- Extras worn on the centre line (the rest are pairs, or deliberately to one side).
local CENTRED = { Crown = true, Halo = true, Cap = true, Propeller = true, Mustache = true, Shades = true, Scarf = true, Flame = true,
	TopHat = true, Headphones = true, Cape = true, Beard = true, Gem = true, Unicorn = true, Helmet = true, Bolt = true, Shell = true, Tie = true,
	Tail = true, Antenna = true, Leaf = true, Spikes = true, Petals = true }
-- (Not Bow, worn to one side of the head on purpose, nor Orbit, three orbiters a third of a turn
-- apart, whose X extent is lopsided by construction.)
local MAY_HANG_LOW = { Feet = true, Tail = true, Cape = true, Tentacles = true, Fins = true, Scarf = true, Beard = true, Tie = true }

local function brainrotParts(def)
	local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
	local model = BrainrotModels.Build(def, { flair = false })
	-- In the workspace, at the origin analyze's pivot expects: GetPartsInPart only sees parts in the
	-- workspace, so an unparented model came back as every part its own floating group.
	model.Parent = stage
	return model
end

local function keyOf(part)
	return string.format("%s|%.2f|%.2f|%.2f", part.Name, part.Position.X, part.Position.Y, part.Position.Z)
end

-- The shape tests checked against cases whose answer is known, printed once before the brainrot
-- families (whose bodies, feet and domes are mostly sphere meshes).
local shapeTestDone = false
local function shapeSelfTest()
	if shapeTestDone then
		return
	end
	shapeTestDone = true
	local function block(size, position, shape, sphereMesh)
		local p = Instance.new("Part")
		p.Size = size
		p.CFrame = CFrame.new(position)
		if shape then
			p.Shape = shape
		end
		if sphereMesh then
			local mesh = Instance.new("SpecialMesh")
			mesh.MeshType = Enum.MeshType.Sphere
			mesh.Parent = p
		end
		return p
	end
	local function buried(p, q)
		for _, point in ipairs(samplePoints(p)) do
			if not inside(point, q) then
				return false
			end
		end
		return true
	end
	local body = block(Vector3.new(2, 2, 2), Vector3.zero, nil, true)
	local wide = block(Vector3.new(4, 2, 2), Vector3.zero, nil, true)
	local cylinder = block(Vector3.new(2, 1, 1), Vector3.zero, Enum.PartType.Cylinder)
	local ball = block(Vector3.new(2, 1, 1), Vector3.zero, Enum.PartType.Ball)
	local cases = {
		{ "box foot at the centre of a sphere-mesh body", block(Vector3.new(0.3, 0.3, 0.3), Vector3.zero), body, true },
		{ "box foot in the body's box corner, outside the ellipsoid", block(Vector3.new(0.2, 0.2, 0.2), Vector3.new(0.85, -0.85, 0)), body, false },
		{ "box foot poking out of the sphere-mesh body's side", block(Vector3.new(0.6, 0.6, 0.6), Vector3.new(0.9, 0, 0)), body, false },
		{ "sphere-mesh foot well inside a stretched ellipsoid", block(Vector3.new(0.6, 0.6, 0.6), Vector3.new(1.2, 0, 0), nil, true), wide, true },
		{ "sphere-mesh foot past a stretched ellipsoid's end", block(Vector3.new(0.6, 0.6, 0.6), Vector3.new(1.9, 0, 0), nil, true), wide, false },
		{ "block inside a cylinder", block(Vector3.new(0.4, 0.3, 0.3), Vector3.new(0.5, 0.1, 0)), cylinder, true },
		{ "block across a cylinder's round side", block(Vector3.new(0.4, 0.3, 0.3), Vector3.new(0.5, 0.3, 0.2)), cylinder, false },
		{ "block outside a 2x1x1 Ball (drawn with radius 0.5)", block(Vector3.new(0.2, 0.2, 0.2), Vector3.new(0.7, 0, 0)), ball, false },
	}
	local failures = 0
	for _, case in ipairs(cases) do
		local got = buried(case[2], case[3])
		if got ~= case[4] then
			failures += 1
		end
		out("shape self-test: %s -> %s (want %s)%s", case[1], tostring(got), tostring(case[4]), got == case[4] and "" or "  FAIL")
	end
	out("shape self-test: %s", failures == 0 and "PASS" or (failures .. " FAILED"))
end

runners.brainrotParts = function()
	shapeSelfTest()
	local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
	local base = { color = Color3.fromRGB(200, 120, 120), accent = Color3.fromRGB(80, 90, 200) }
	local index = 0
	local function variant(body, eyes, mouth, extras)
		return { name = "Audit", rarity = "Rare", look = { body = body, color = base.color, accent = base.accent, eyes = eyes, mouth = mouth, extras = extras } }
	end
	for _, body in ipairs(BODY_NAMES) do
		local metrics = BrainrotModels.Metrics(variant(body, "Round", "None", {}))
		-- The bare body, to tell each extra's own parts apart.
		local bare = brainrotParts(variant(body, "Round", "None", {}))
		local bareKeys = {}
		for _, part in ipairs(visibleParts(bare)) do
			bareKeys[keyOf(part)] = true
		end
		bare:Destroy()
		local function check(label, def, kind, name)
			index += 1
			local model = brainrotParts(def)
			local at = CFrame.new()
			local report = analyze(model, at)
			local extra = {}
			local own = {}
			for _, part in ipairs(visibleParts(model)) do
				if not bareKeys[keyOf(part)] then
					table.insert(own, part)
				end
			end
			if kind == "extra" and #own > 0 then
				local minX, maxX, lowest = math.huge, -math.huge, math.huge
				for _, part in ipairs(own) do
					for _, point in ipairs(samplePoints(part)) do
						minX, maxX = math.min(minX, point.X), math.max(maxX, point.X)
						lowest = math.min(lowest, point.Y)
					end
				end
				if CENTRED[name] and math.abs((minX + maxX) / 2) > 0.03 then
					table.insert(extra, string.format("crooked: centred extra is %.3f off the centre line", (minX + maxX) / 2))
				end
				if not MAY_HANG_LOW[name] and lowest < metrics.bottom - 0.05 then
					table.insert(extra, string.format("sinks %.2f below the body's base", metrics.bottom - lowest))
				end
			end
			-- Which floating groups involve this variant's own parts?
			tally("brainrot " .. kind, report, label, extra)
			model:Destroy()
			if index % 25 == 0 then
				task.wait()
			end
		end
		for _, extraName in ipairs(EXTRAS) do
			check(body .. " + " .. extraName, variant(body, "Round", "None", { extraName }), "extra", extraName)
		end
		for _, eyes in ipairs(EYES) do
			check(body .. " eyes " .. eyes, variant(body, eyes, "None", {}), "eyes", eyes)
		end
		for _, mouth in ipairs(MOUTHS) do
			check(body .. " mouth " .. mouth, variant(body, "Round", mouth, {}), "mouth", mouth)
		end
	end
end

runners.brainrots = function()
	shapeSelfTest()
	local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
	for index, def in ipairs(BrainrotData.Types) do
		local model = brainrotParts(def)
		local report = analyze(model, CFrame.new())
		tally("brainrots", report, def.name .. " (" .. tostring(def.look and def.look.body) .. ")")
		model:Destroy()
		if index % 10 == 0 then
			task.wait()
		end
	end
end

-- Statues: the same creature built as the lobby's (scale 1.6 on a plinth) and a town plaza's (scale
-- 2.6), then put through the world's own z-fight pass the way LobbyService.Build and
-- MapGenerator.Build do after placing them. Any part that pass moves or resizes is a part of the
-- statue that no longer matches the creature (the podium guns were wrecked exactly this way).
runners.statues = function()
	local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
	local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
	local settings = {
		{ name = "lobby statue", scale = 1.6, plinthTop = 4.2, options = nil },
		{ name = "plaza statue", scale = 2.6, plinthTop = 5.6, options = { yield = true } },
	}
	for _, setting in ipairs(settings) do
		local moved, resized, changedModels, maxMove, maxResize = 0, 0, 0, 0, 0
		local worst = {}
		for index, def in ipairs(BrainrotData.Types) do
			local folder = Instance.new("Folder")
			folder.Name = "Statue"
			folder.Parent = stage
			local base = SPOT + Vector3.new((index % 20) * 40, -600, math.floor(index / 20) * 40)
			local plinth = Instance.new("Part")
			plinth.Name = "Plinth"
			plinth.Shape = Enum.PartType.Cylinder
			plinth.Anchored = true
			plinth.Size = Vector3.new(setting.plinthTop, 12, 12)
			plinth.CFrame = CFrame.new(base + Vector3.new(0, setting.plinthTop / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
			plinth.Parent = folder
			local size = def.look and def.look.size or 1
			local metrics = BrainrotModels.Metrics(def)
			local foot = base + Vector3.new(0, setting.plinthTop - metrics.bottom * setting.scale * size, 0)
			local model = BrainrotModels.Build(def, { scale = setting.scale, cframe = CFrame.new(foot), flair = false })
			model.Parent = folder
			local before = {}
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					before[part] = { part.CFrame, part.Size }
				end
			end
			ZFight.Fix({ folder }, setting.options)
			local count = 0
			for part, state in pairs(before) do
				local m = (part.CFrame.Position - state[1].Position).Magnitude
				local r = (part.Size - state[2]).Magnitude
				if m > 1e-4 then
					moved += 1
					count += 1
					maxMove = math.max(maxMove, m)
				end
				if r > 1e-4 then
					resized += 1
					count += 1
					maxResize = math.max(maxResize, r)
				end
			end
			if count > 0 then
				changedModels += 1
				table.insert(worst, { name = def.name, count = count })
			end
			folder:Destroy()
			if index % 10 == 0 then
				task.wait()
			end
		end
		table.sort(worst, function(a, b)
			return a.count > b.count
		end)
		local top = {}
		for index = 1, math.min(8, #worst) do
			table.insert(top, worst[index].name .. " " .. worst[index].count)
		end
		out("%s: %d of %d brainrots changed by the world pass; %d parts moved (max %.3f), %d resized (max %.3f); most changed: %s",
			setting.name, changedModels, #BrainrotData.Types, moved, maxMove, resized, maxResize, table.concat(top, ", "))
	end
end

runners.landmarks = function()
	local Landmarks = require(modules:WaitForChild("Landmarks"))
	local models = Landmarks.BuildAll(stage, SPOT + Vector3.new(-1400, -1400, 2600), 300, function()
		return SPOT.Y - 1400
	end)
	task.wait(1)
	for _, model in ipairs(models) do
		tally("landmarks", analyze(model, model:GetPivot(), { mirror = false }), model.Name)
	end
end

runners.eggs = function()
	local EasterEggs = require(modules:WaitForChild("EasterEggs"))
	local models = EasterEggs.BuildAll(stage, SPOT + Vector3.new(-1400, 0, 3400), 90)
	task.wait(1)
	for _, model in ipairs(models) do
		tally("eggs", analyze(model, model:GetPivot(), { mirror = false }), model.Name)
	end
end

for _, family in ipairs(FAMILIES) do
	local started = os.clock()
	local ok, err = pcall(runners[family])
	if not ok then
		out("%s failed: %s", family, tostring(err))
	end
	out("%s ran in %.1fs", family, os.clock() - started)
	pcall(flush)
end

local names = {}
for family in pairs(totals) do
	table.insert(names, family)
end
table.sort(names)
for _, family in ipairs(names) do
	local t = totals[family]
	out("== %s: %d models, %d visible parts; floating groups %d, see-through openings %d, near-miss gaps %d, flush pairs %d, mirror misses %d, buried parts %d, unwelded parts %d, off-base models %d; %d models with findings",
		family, t.models, t.parts, t.floating, t.openings or 0, t.nearMiss, t.flush, t.mirror, t.buried, t.unwelded, t.base, #t.lines)
	-- Buried parts are the commonest finding by far, so models with any other finding are listed
	-- first, and buried parts are also summed up by pattern ("Toe inside Foot" x 56).
	local ordered, buriedOnly = {}, {}
	local patterns = {}
	for _, line in ipairs(t.lines) do
		local other = false
		for _, problem in ipairs(string.split(string.sub(line, (string.find(line, ": ", 1, true) or 0) + 2), " || ")) do
			if string.sub(problem, 1, 7) ~= "buried " then
				other = true
			end
		end
		table.insert(other and ordered or buriedOnly, line)
		for inner, outer in string.gmatch(line, "([%w_]+) inside ([%w_]+) @") do
			local key = inner .. " inside " .. outer
			patterns[key] = (patterns[key] or 0) + 1
		end
	end
	for _, line in ipairs(buriedOnly) do
		table.insert(ordered, line)
	end
	for index, line in ipairs(ordered) do
		if index > 60 then
			out("  ... %d more", #ordered - 60)
			break
		end
		out("  %s", line)
	end
	local patternList = {}
	for key, count in pairs(patterns) do
		table.insert(patternList, { key, count })
	end
	table.sort(patternList, function(a, b)
		return a[2] > b[2]
	end)
	for index = 1, math.min(30, #patternList) do
		out("  buried pattern: %s x%d", patternList[index][1], patternList[index][2])
	end
end
stage:Destroy()
pcall(flush)
