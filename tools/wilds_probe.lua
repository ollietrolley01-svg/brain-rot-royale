-- Wilds specimen probe: one of every MapWilds tree, ground piece and shelter, audited.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wilds_probe.lua -WaitSeconds 300
--
-- Runs in edit mode, on a flat pad far off the map, and reports:
--   apex      which corner of a CornerWedgePart is its tall one (MapWilds.CornerApex must match),
--             and whether a spruce comes out pointed at the top
--   parts     per specimen
--   flush     ZFight.Scan pairs inside each specimen (want 0)
--   floating  groups of visible parts touching neither the rest of the specimen nor the pad (want 0)
--   room      a player-sized box inside each shelter is clear of solid parts, and each hut's
--             doorway is found by sweeping a box along its front wall
--   breaking  every Wall/Roof/Gable in a cabin, a lean-to, a deer stand and a campsite broken
--             through DestructibleService: which parts went, and that nothing solid is left
--             hanging (roofs on posts)
-- (MapWilds' own map build is checked by tools/wilds_map_probe.lua.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapWilds = require(modules:WaitForChild("MapWilds"))

local function out(fmt, ...)
	print("[Wilds] " .. string.format(fmt, ...))
end

local ORIGIN = Vector3.new(4000, 1200, 4000)

local stage = Instance.new("Folder")
stage.Name = "WildsProbe"
stage.Parent = workspace

--------------------------------------------------------------------------------
-- 1. The corner wedge's tall corner
--------------------------------------------------------------------------------
do
	local wedge = Instance.new("CornerWedgePart")
	wedge.Size = Vector3.new(4, 4, 4)
	wedge.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 50, 0))
	wedge.Anchored = true
	wedge.Parent = stage
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { wedge }
	local best, bestY = nil, -math.huge
	local lines = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			local from = wedge.Position + Vector3.new(sx * 1.6, 10, sz * 1.6)
			local hit = workspace:Raycast(from, Vector3.new(0, -20, 0), params)
			local y = hit and (hit.Position.Y - wedge.Position.Y) or -99
			table.insert(lines, string.format("(%d,%d)=%.2f", sx, sz, y))
			if y > bestY then
				best, bestY = { x = sx, z = sz }, y
			end
		end
	end
	out("apex: corner wedge heights at local corners %s -> tall corner x=%d z=%d; MapWilds.CornerApex is x=%d z=%d (%s)",
		table.concat(lines, " "), best.x, best.z, MapWilds.CornerApex.x, MapWilds.CornerApex.z,
		(best.x == MapWilds.CornerApex.x and best.z == MapWilds.CornerApex.z) and "MATCH" or "MISMATCH")
	-- Use the measured one for the rest of this run either way, so the audits below are meaningful.
	MapWilds.CornerApex = best
	wedge:Destroy()
end

--------------------------------------------------------------------------------
-- 2. Specimens
--------------------------------------------------------------------------------

local pad = Instance.new("Part")
pad.Name = "Pad"
pad.Anchored = true
pad.Size = Vector3.new(1300, 2, 120)
pad.CFrame = CFrame.new(ORIGIN + Vector3.new(620, -1, 0))
pad.Color = Color3.fromRGB(90, 120, 70)
pad.Parent = stage
local padTop = ORIGIN.Y

local function flatGround()
	return padTop
end

local row, entries = MapWilds.Specimens(stage, ORIGIN, flatGround, 11)
out("specimens: %d built, row %.0f studs long", #entries, #entries > 0 and (entries[#entries].at.X - ORIGIN.X) or 0)

local function visibleParts(root)
	local list = {}
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 0.98 then
			table.insert(list, d)
		end
	end
	return list
end

-- Groups of parts not connected (grown by 0.05 each way) to anything that reaches the pad. Every
-- part's CanQuery goes back afterwards: DestructibleService reads it to tell trim from structure, so
-- leaving it on would stop the break tests below from dropping anything.
local function floatingGroups(parts)
	local wasQueryable = {}
	for _, part in ipairs(parts) do
		wasQueryable[part] = part.CanQuery
		part.CanQuery = true
	end
	local members = table.clone(parts)
	table.insert(members, pad)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = members
	local parent = {}
	local function find(x)
		while parent[x] ~= x do
			parent[x] = parent[parent[x]]
			x = parent[x]
		end
		return x
	end
	for _, part in ipairs(members) do
		parent[part] = part
	end
	for _, part in ipairs(parts) do
		local probe = part:Clone()
		probe:ClearAllChildren()
		probe.Size = part.Size + Vector3.new(0.1, 0.1, 0.1)
		probe.Transparency = 1
		probe.CanCollide = false
		probe.Parent = workspace
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if parent[other] then
				parent[find(other)] = find(part)
			end
		end
		probe:Destroy()
	end
	local groups = {}
	local grounded = find(pad)
	for _, part in ipairs(parts) do
		local r = find(part)
		if r ~= grounded then
			groups[r] = groups[r] or {}
			table.insert(groups[r], part.Name)
		end
	end
	local list = {}
	for _, names in pairs(groups) do
		table.insert(list, table.concat(names, "+"))
	end
	for part, value in pairs(wasQueryable) do
		part.CanQuery = value
	end
	return list
end

local solidParams = OverlapParams.new()
solidParams.FilterType = Enum.RaycastFilterType.Include
solidParams.FilterDescendantsInstances = { row }

local function solidHits(cframe, size)
	local hits = {}
	for _, part in ipairs(workspace:GetPartBoundsInBox(cframe, size, solidParams)) do
		if part.CanCollide then
			table.insert(hits, part.Name)
		end
	end
	return hits
end

-- Interior spots a player should fit, in each shelter's own frame (origin at its build point).
local ROOM = {
	leanTo = CFrame.new(0, 2.9, -0.6), driftwoodLeanTo = CFrame.new(0, 2.9, -0.6),
	cabin = "hut", bothy = "hut", beachHut = "hut", shack = "hut",
	ruin = CFrame.new(0, 3.2, 0), sandstoneRuin = CFrame.new(0, 3.2, 0), concreteRuin = CFrame.new(0, 3.2, 0),
	rockShelter = CFrame.new(0, 3.1, -0.5), sandstoneShelter = CFrame.new(0, 3.1, -0.5),
	deerStand = CFrame.new(0, 12.6 + 2.4, 0),
	poleBarn = CFrame.new(0, 3.2, -2.5),
	palapa = CFrame.new(3.5, 3.2, 0),
	busShelter = CFrame.new(0, 3.2, -1.0),
}

local totals = { parts = 0, flush = 0, floating = 0, roomBlocked = 0 }
for _, entry in ipairs(entries) do
	local parts = visibleParts(entry.model)
	local flush = ZFight.Scan({ entry.model })
	local floating = floatingGroups(parts)
	totals.parts += entry.parts
	totals.flush += #flush
	totals.floating += #floating
	local room = ""
	local kind = string.match(entry.name, "^Shelter_(.+)$")
	if kind then
		local spec = MapWilds.ShelterKinds[kind]
		local base = CFrame.new(entry.at + Vector3.new(0, 0, -(spec.offsetZ or 0)))
		local where = ROOM[kind]
		if where == "hut" then
			-- Sweep a doorway-sized box along the front wall line (z = -6.5).
			local doorX = nil
			for step = -28, 28 do
				local x = step * 0.25
				if #solidHits(base * CFrame.new(x, 3.7, -6.5), Vector3.new(2.4, 5, 1.4)) == 0 then
					doorX = x
					break
				end
			end
			if doorX then
				local inside = solidHits(base * CFrame.new(doorX, 3.2, -5), Vector3.new(2.4, 4.4, 1.4))
				-- There has to be a wall to have a doorway in: if the sweep found "a door" because the
				-- front wall isn't where this check looks, it isn't checking anything.
				local wall = #solidHits(base * CFrame.new(-7, 3.7, -6.5), Vector3.new(1.4, 5, 1.4)) > 0
					and #solidHits(base * CFrame.new(7, 3.7, -6.5), Vector3.new(1.4, 5, 1.4)) > 0
				room = string.format("door at x=%.2f, inside %s%s", doorX, #inside == 0 and "clear" or ("BLOCKED by " .. table.concat(inside, ",")),
					wall and "" or ", NO FRONT WALL EITHER SIDE (is the sweep on the wall line?)")
				if #inside > 0 or not wall then
					totals.roomBlocked += 1
				end
			else
				room = "NO DOORWAY FOUND"
				totals.roomBlocked += 1
			end
		elseif where then
			local hits = solidHits(base * where, Vector3.new(2.4, 4.4, 2.4))
			room = #hits == 0 and "room clear" or ("room BLOCKED by " .. table.concat(hits, ","))
			if #hits > 0 then
				totals.roomBlocked += 1
			end
		end
	end
	out("%-26s parts %3d  flush %d%s  floating %d%s  %s", entry.name, entry.parts, #flush,
		#flush > 0 and (" [" .. table.concat(ZFight.Describe(flush, function(p) return p.Name end, 4), " | ") .. "]") or "",
		#floating, #floating > 0 and (" [" .. table.concat(floating, " ; ") .. "]") or "", room)
	task.wait()
end
out("specimen totals: parts %d, flush pairs %d, floating groups %d, blocked rooms %d", totals.parts, totals.flush, totals.floating, totals.roomBlocked)

-- Planted faults: a block standing on the pad and one hanging 8 studs over it. The floating check
-- must report the second and not the first, or "floating 0" above means nothing.
do
	local plant = Instance.new("Model")
	plant.Name = "SelfTest"
	plant.Parent = stage
	local function block(size, at)
		local p = Instance.new("Part")
		p.Anchored = true
		p.Size = size
		p.CFrame = CFrame.new(at)
		p.Parent = plant
		return p
	end
	local standing = block(Vector3.new(4, 4, 4), ORIGIN + Vector3.new(1200, 2, 40))
	local hanging = block(Vector3.new(4, 1, 4), ORIGIN + Vector3.new(1216, 8, 40))
	local groundedGroups = floatingGroups({ standing })
	local hangingGroups = floatingGroups({ standing, hanging })
	out("selftest: a block on the pad reads %d floating groups (want 0), with one hanging over it %d (want 1): %s",
		#groundedGroups, #hangingGroups, (#groundedGroups == 0 and #hangingGroups == 1) and "CHECK WORKS" or "CHECK BROKEN")
	plant:Destroy()
end

-- The spruce's top: a ray straight down its axis should land near the tip, higher than rays a few
-- studs out (a wrongly turned pyramid is a crown of four spikes with a dip in the middle).
for _, entry in ipairs(entries) do
	if entry.name == "Tree_spruce" then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { entry.model }
		for _, part in ipairs(entry.model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.CanQuery = true
			end
		end
		local heights = {}
		-- Not exactly on the axis: that ray runs down the seam where the four wedges meet and slips through.
		for _, offset in ipairs({ Vector3.new(0.3, 0, 0.2), Vector3.new(2, 0, 0), Vector3.new(-2, 0, 2), Vector3.new(4, 0, -1) }) do
			local hit = workspace:Raycast(entry.at + offset + Vector3.new(0, 60, 0), Vector3.new(0, -80, 0), params)
			table.insert(heights, hit and string.format("%.1f", hit.Position.Y - padTop) or "miss")
		end
		out("apex check: spruce heights down the axis then 2, 2.8 and 4.1 studs out: %s (want the first highest)", table.concat(heights, " "))
	end
end

--------------------------------------------------------------------------------
-- 3. Breaking shelters apart
--------------------------------------------------------------------------------
do
	local DestructibleService = require(modules:WaitForChild("DestructibleService"))
	-- DestructibleService only breaks things under a root named Map.
	local mapRoot = Instance.new("Folder")
	mapRoot.Name = "Map"
	mapRoot.Parent = workspace
	local breakOrigin = ORIGIN + Vector3.new(0, 0, 150)
	local breakPad = pad:Clone()
	breakPad.CFrame = CFrame.new(breakOrigin + Vector3.new(620, -1, 0))
	breakPad.Parent = stage
	local breakRow, breakEntries = MapWilds.Specimens(mapRoot, breakOrigin, flatGround, 11)
	pad = breakPad
	for _, entry in ipairs(breakEntries) do
		local kind = string.match(entry.name, "^Shelter_(.+)$")
		if kind == "cabin" or kind == "leanTo" or kind == "deerStand" or kind == "campsite" or kind == "busShelter" or kind == "beachHut" then
			local before = #visibleParts(entry.model)
			local broken, names = 0, {}
			for _, part in ipairs(entry.model:GetChildren()) do
				if part:IsA("BasePart") and (part.Name == "Wall" or part.Name == "Gable") and DestructibleService.FromPart(part) then
					DestructibleService.Damage(part, 1e6, nil, part.Position + Vector3.new(0, 0, -10))
					broken += 1
				end
			end
			task.wait(0.2)
			-- Rubble chunks are thrown clear and cleaned up by Debris; leave them out.
			for _, d in ipairs(entry.model:GetChildren()) do
				if d.Name == "Rubble" then
					d:Destroy()
				end
			end
			local left = visibleParts(entry.model)
			local present = {}
			for _, part in ipairs(left) do
				present[part.Name] = (present[part.Name] or 0) + 1
			end
			for name, n in pairs(present) do
				table.insert(names, name .. "x" .. n)
			end
			table.sort(names)
			local floating = floatingGroups(left)
			out("break %-10s broke %d walls/gables: %d -> %d visible parts; left %s; floating after %d%s", kind, broken, before, #left,
				table.concat(names, " "), #floating, #floating > 0 and (" [" .. table.concat(floating, " ; ") .. "]") or "")
			task.wait()
		end
	end
	-- And the roofs: a roof going must not leave anything solid hanging either.
	for _, entry in ipairs(breakEntries) do
		local kind = string.match(entry.name, "^Shelter_(.+)$")
		if kind == "cabin" or kind == "deerStand" or kind == "poleBarn" then
			for _, part in ipairs(entry.model:GetChildren()) do
				if part:IsA("BasePart") and part.Name == "Roof" and DestructibleService.FromPart(part) then
					DestructibleService.Damage(part, 1e6, nil, part.Position + Vector3.new(0, 10, 0))
				end
			end
			task.wait(0.2)
			for _, d in ipairs(entry.model:GetChildren()) do
				if d.Name == "Rubble" then
					d:Destroy()
				end
			end
			local floating = floatingGroups(visibleParts(entry.model))
			out("break %-10s roofs too: floating after %d%s", kind, #floating, #floating > 0 and (" [" .. table.concat(floating, " ; ") .. "]") or "")
		end
	end
	mapRoot:Destroy()
end

stage:Destroy()
out("done")
