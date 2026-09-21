-- Map fingerprint: proves a change to map generation altered only what it meant to.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/map_fingerprint_probe.lua -WaitSeconds 400
--
-- Builds whole maps from a fixed math.randomseed and hashes every instance under workspace.Map
-- (path, class, size, CFrame, colour, material, flags, attributes, tags, text), the loot and chest
-- spots Build returns, and terrain height on a grid. Run it before and after a change (or on two
-- source trees with runtest's -PlaceFile) and compare:
--   * the per-map hash: identical means nothing on the map changed at all;
--   * the "groups" lines: one hash per part name, so a change meant to touch only, say, Threshold
--     and Chimney parts can be checked to have left every other group alone;
--   * spotHash / groundHash: loot placement and terrain.
-- The first map is built twice, and "determinism: true" is what makes any comparison meaningful.
-- Written 2026-09-16 to prove the MapBuildings split (three maps identical before and after).
-- Edit RUNS / SEED below. Keep to about three maps per run: Studio has died at ~3.6 GB building more.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
print("[Split] tree has MapBuildings: " .. tostring(modules:FindFirstChild("MapBuildings") ~= nil))
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local SEED = 20260916
local RUNS = { "TralalaTown", "TralalaTown", "RotRidge", "PatapimPlains" }
-- The map-wide ZFight.Fix pass is order-sensitive (its sweep sort isn't stable), so a change that
-- ADDS parts anywhere can nudge faces in unrelated groups (Roof, Parapet, RoadShoulder...) through
-- the pass alone. To prove a change left generation itself untouched, run once with ZFIGHT = false
-- (identical groups there = identical generation), and separately count z-fight pairs it adds.
local ZFIGHT = true
require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight")).Enabled = ZFIGHT
print("[Split] map z-fight pass enabled: " .. tostring(ZFIGHT))

local function q(n)
	local v = math.floor(n * 100 + 0.5)
	if v == 0 then
		v = 0
	end
	return tostring(v)
end
local function vec(v)
	return q(v.X) .. "," .. q(v.Y) .. "," .. q(v.Z)
end

local function fnv(s, h)
	for i = 1, #s, 256 do
		local bytes = { string.byte(s, i, math.min(i + 255, #s)) }
		for _, b in ipairs(bytes) do
			h = bit32.bxor(h, b)
			h = (bit32.lshift(h, 24) + h * 403) % 4294967296
		end
	end
	return h
end

local function describe(inst, map)
	local path = {}
	local node = inst
	while node and node ~= map do
		table.insert(path, 1, node.Name)
		node = node.Parent
	end
	local out = { table.concat(path, "/"), inst.ClassName }
	if inst:IsA("BasePart") then
		local c = { inst.CFrame:GetComponents() }
		for i = 1, 12 do
			c[i] = q(c[i])
		end
		local col = inst.Color
		table.insert(out, vec(inst.Size))
		table.insert(out, table.concat(c, ","))
		table.insert(out, string.format("%d,%d,%d", math.floor(col.R * 255 + 0.5), math.floor(col.G * 255 + 0.5), math.floor(col.B * 255 + 0.5)))
		table.insert(out, inst.Material.Name)
		table.insert(out, q(inst.Transparency) .. "/" .. q(inst.Reflectance))
		table.insert(out, tostring(inst.CanCollide) .. tostring(inst.CanQuery) .. tostring(inst.CanTouch) .. tostring(inst.Anchored) .. tostring(inst.CastShadow) .. tostring(inst.Massless))
		if inst:IsA("Part") then
			table.insert(out, inst.Shape.Name)
		end
	end
	local attrs = {}
	for key, value in pairs(inst:GetAttributes()) do
		table.insert(attrs, key .. "=" .. tostring(value))
	end
	table.sort(attrs)
	table.insert(out, table.concat(attrs, ";"))
	local tags = CollectionService:GetTags(inst)
	table.sort(tags)
	table.insert(out, table.concat(tags, ";"))
	for _, prop in ipairs({ "Text", "Texture", "Face", "Value", "Part0", "Part1", "Enabled" }) do
		local ok, value = pcall(function()
			return inst[prop]
		end)
		if ok and value ~= nil then
			table.insert(out, prop .. "=" .. (typeof(value) == "Instance" and value.Name or tostring(value)))
		end
	end
	return table.concat(out, "|"), inst.Name
end

local function spotLines(info)
	local lines = {}
	local function add(kind, list)
		for _, spot in ipairs(list or {}) do
			local v = typeof(spot) == "Vector3" and spot or (typeof(spot) == "CFrame" and spot.Position) or (type(spot) == "table" and (spot.position or spot.Position))
			table.insert(lines, kind .. ":" .. (v and vec(v) or tostring(spot)))
		end
	end
	if type(info) == "table" then
		add("chest", info.chestSpots)
		if type(info.lootSpots) == "table" then
			for kind, list in pairs(info.lootSpots) do
				add("loot-" .. tostring(kind), list)
			end
		end
	end
	table.sort(lines)
	return lines
end

local results = {}
for runIndex, mapId in ipairs(RUNS) do
	MapGenerator.Clear()
	task.wait(1)
	math.randomseed(SEED)
	local t0 = os.clock()
	local ok, info = pcall(MapGenerator.Build, mapId)
	local buildTime = os.clock() - t0
	if not ok then
		warn("[Split] BUILD FAILED " .. mapId .. ": " .. tostring(info))
	end
	local map = workspace:FindFirstChild("Map")
	local lines, groups = {}, {}
	local count = 0
	for _, inst in ipairs(map and map:GetDescendants() or {}) do
		local line, name = describe(inst, map)
		table.insert(lines, line)
		groups[name] = groups[name] or {}
		table.insert(groups[name], line)
		count += 1
		if count % 2000 == 0 then
			task.wait()
		end
	end
	table.sort(lines)
	local h = 2166136261
	for i, line in ipairs(lines) do
		h = fnv(line .. "\n", h)
		if i % 1000 == 0 then
			task.wait()
		end
	end
	local spots = spotLines(ok and info or nil)
	local hs = fnv(table.concat(spots, "\n"), 2166136261)
	-- Terrain shapes everything placed on it; sample its height on a grid as well.
	local ground = {}
	for x = -800, 800, 100 do
		for z = -800, 800, 100 do
			-- nil where there's no solid ground (claude-79's contract): hashed as "none", not skipped,
			-- so a point that loses its ground still changes the fingerprint.
			local height = MapGenerator.GroundHeightAt(x, z)
			table.insert(ground, height and q(height) or "none")
		end
	end
	local hg = fnv(table.concat(ground, ","), 2166136261)
	print(string.format("[Split] run %d %s: ok=%s build %.1fs instances=%d hash=%08x spots=%d spotHash=%08x groundHash=%08x",
		runIndex, mapId, tostring(ok), buildTime, #lines, h, #spots, hs, hg))
	results[runIndex] = string.format("%08x/%08x/%08x", h, hs, hg)

	-- Per-name hashes, so a mismatch between trees points at the pieces that differ.
	local names = {}
	for name in pairs(groups) do
		table.insert(names, name)
	end
	table.sort(names)
	local chunk = {}
	for _, name in ipairs(names) do
		local list = groups[name]
		table.sort(list)
		table.insert(chunk, string.format("%s=%d:%08x", name, #list, fnv(table.concat(list, "\n"), 2166136261)))
		if #chunk == 40 then
			print("[Split] groups " .. mapId .. " " .. table.concat(chunk, " "))
			chunk = {}
			task.wait()
		end
	end
	if #chunk > 0 then
		print("[Split] groups " .. mapId .. " " .. table.concat(chunk, " "))
	end
end
MapGenerator.Clear()
-- Both runs must have produced a real fingerprint: two FAILED builds hash the same empty map, and
-- that used to print "determinism: true".
local ran = results[1] ~= nil and results[2] ~= nil and results[1] ~= "" and results[2] ~= ""
print("[Split] determinism (run 1 == run 2): " .. tostring(ran and results[1] == results[2])
	.. (ran and "" or "  [INVALID: one of the two builds produced no fingerprint]"))
print("[Split] summary " .. table.concat(results, " "))
