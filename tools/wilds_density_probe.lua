-- Wilds density curve: the same map built three times at three part budgets, so a density can be
-- chosen with numbers rather than taste.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wilds_density_probe.lua -WaitSeconds 900
--
-- Edit MAP_ID below; one map per run. For each budget it reports parts, trees, shelters, the build's
-- WALL CLOCK (os.clock is process CPU time, and a build spends most of its life yielding), the map's
-- part count with the wilds in it, and the flush pairs inside the wilds BEFORE any z-fight pass --
-- which is the number that says whether the pass needs to scan them at all.

local MAP_ID = "RotRidge"
local SEED = 424242
local BUDGETS = { 6, 7.5, 9 }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ZFight"))
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapSpace = require(modules:WaitForChild("MapSpace"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))
local MapWilds = require(modules:WaitForChild("MapWilds"))

local function out(fmt, ...)
	print("[Density] " .. string.format(fmt, ...))
end

math.randomseed(SEED)
local info = MapGenerator.Build(MAP_ID)
local map = workspace:WaitForChild("Map")
local preset = MapData.Get(MAP_ID)
task.wait(1)

local centers = {}
for _, child in ipairs(map:GetChildren()) do
	if child.Name == "Town" and child:GetAttribute("TownCenter") then
		table.insert(centers, child:GetAttribute("TownCenter"))
	end
end
local townSpread = math.floor(math.max(110, info.radius * 0.17))

local function countParts(root)
	local n = 0
	for _, d in ipairs(root:GetDescendants()) do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end
local mapParts = countParts(map)
out("%s radius %d, %d towns, map %d parts before any wilds", MAP_ID, info.radius, #centers, mapParts)

-- A fresh MapSpace for every build, rebuilt from the finished map exactly as the stand-in hook does:
-- a build that saw the last build's claims would place less and read as a cheaper density.
local function freshSpace()
	local space = MapSpace.new()
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") then
			local cf, size = d.CFrame, d.Size
			local ex = math.abs(cf.XVector.X) * size.X + math.abs(cf.YVector.X) * size.Y + math.abs(cf.ZVector.X) * size.Z
			local ez = math.abs(cf.XVector.Z) * size.X + math.abs(cf.YVector.Z) * size.Y + math.abs(cf.ZVector.Z) * size.Z
			space:AddRect(d.Position.X, d.Position.Z, ex / 2, ez / 2, 0)
		end
	end
	if info.river then
		for index = 1, #info.river.points - 1 do
			space:AddStrip(info.river.points[index], info.river.points[index + 1], (info.river.width or 34) / 2 + 8)
		end
	end
	for _, plateau in ipairs(info.plateaus or {}) do
		space:AddCircle(plateau.X, plateau.Z, plateau.radius + 10)
	end
	return space
end

local was = MapWilds.BUDGET_PER_RADIUS
for _, budget in ipairs(BUDGETS) do
	MapWilds.BUDGET_PER_RADIUS = budget
	local wall = DateTime.now().UnixTimestampMillis
	local result = MapWilds.Build(map, {
		preset = preset, radius = info.radius, centers = centers, townSpread = townSpread,
		space = freshSpace(), groundAt = MapGenerator.GroundHeightAt, roads = info.roads, river = info.river, seed = SEED,
	})
	local seconds = (DateTime.now().UnixTimestampMillis - wall) / 1000
	-- What the parts actually ARE: "19,563 parts" can't be acted on, "6,400 leaf clusters at four a
	-- tree" can (claude-79, 00:20).
	local byName = {}
	for _, d in ipairs(result.model:GetDescendants()) do
		if d:IsA("BasePart") then
			byName[d.Name] = (byName[d.Name] or 0) + 1
		end
	end
	local names = {}
	for name, n in pairs(byName) do
		table.insert(names, { name = name, n = n })
	end
	table.sort(names, function(a, b)
		return a.n > b.n
	end)
	local top = {}
	for index = 1, math.min(10, #names) do
		table.insert(top, string.format("%s %d", names[index].name, names[index].n))
	end
	local flush = ZFight.Scan({ result.model })
	out("budget %.1f per stud: %d parts (%d trees, %d undergrowth, %d shelters, %d grass patches painted), %.2fs wall, map %d -> %d parts, %d flush pairs inside the wilds before any pass",
		budget, result.parts, result.counts.trees, result.counts.undergrowth, result.counts.shelters, result.paintedPatches or 0,
		seconds, mapParts, mapParts + result.parts, #flush)
	out("budget %.1f parts by name, top ten: %s", budget, table.concat(top, ", "))
	if #flush > 0 then
		out("budget %.1f flush detail: %s", budget, table.concat(ZFight.Describe(flush, function(p)
			local node = p
			while node.Parent and node.Parent ~= result.model do
				node = node.Parent
			end
			return string.gsub(node.Name, "_%d+$", "") .. "/" .. p.Name
		end, 6), " | "))
	end
	result.model:Destroy()
	task.wait(0.5)
end
MapWilds.BUDGET_PER_RADIUS = was

MapGenerator.Clear()
out("done")
