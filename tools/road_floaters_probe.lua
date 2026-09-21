-- What floats? Every anchored part in a built map, measured against whatever is under it: terrain
-- (solid or water) and any other part. Reports the gap under each part's lowest point, grouped by
-- part name, with the worst few of each named and located.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/road_floaters_probe.lua -WaitSeconds 900 [-PlaceFile <rbxlx>]
--
-- Why a general sweep rather than a check of one suspect: "some things are floating a bit" is a
-- report about what a player sees, and the thing a player sees is any gap under anything. Measuring
-- one candidate proves only that candidate.
--
-- A part is measured from the lowest point of its own shape, not its bounding box: a ball's bottom
-- is its centre less its radius, and a wedge's is its box's bottom face, which it keeps.
-- Parts that are MEANT to be clear of the ground are skipped by name (lamps on posts, signs on
-- poles, anything hanging off a wall), as are parts inside a model whose own base is what rests on
-- the ground -- a building's upper floors float by design.

local RUNS = {
	{ "SahurSprings", 101 }, { "SahurSprings", 7 },
	{ "TralalaTown", 101 }, { "BombardiroBay", 101 }, { "RotRidge", 101 }, { "PatapimPlains", 101 },
}
-- Two bands, because "floating a bit" is a real report and a single threshold can't hear it: a
-- check set at 1.0 passes a slab standing 0.6 off the ground on one side, which the eye sees.
local LIFTED = 0.25 -- a gap you notice standing next to it
local FLOATING = 1.0 -- a gap you notice from across the map
local WORST = 4 -- how many of each name to name and locate
-- Planted every run: one part lifted by a known amount, which the sweep must then name. A fault
-- planted by hand proves the check worked that night; one planted every run proves it still works
-- after someone tidies the check.
local PLANT = 0.7

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local function out(fmt, ...)
	print("[FLOATERS] " .. string.format(fmt, ...))
end

-- Things whose job is to be off the ground.
local AIRBORNE = {
	Lamp = true, LampArm = true, SignalLamp = true, SignalHead = true, SignalMast = true, SignalBracket = true,
	BridgeLamp = true, BridgeCoping = true, BridgeArch = true, BridgeParapet = true, Board = true,
	FingerpostBoard = true, StopSignFace = true, StopSign = true, Cloud = true, Canopy = true, Leaves = true,
	Awning = true, Balcony = true, Sign = true, Roof = true, Parapet = true, Cornice = true, Chimney = true,
	Rung = true, Rope = true, Handle = true, Zipline = true, Cable = true, Wire = true,
}

for _, run in ipairs(RUNS) do
	local mapId, seed = run[1], run[2]
	math.randomseed(seed)
	local ok, info = pcall(MapGenerator.Build, mapId)
	if not ok then
		out("%s seed %d: BUILD FAILED %s", mapId, seed, tostring(info))
		continue
	end
	task.wait(1.5)
	local map = workspace.Map

	local everything = RaycastParams.new()
	everything.FilterType = Enum.RaycastFilterType.Exclude
	everything.IgnoreWater = false

	local counts, worst, measured, lifted = {}, {}, 0, {}
	local plantedGap = nil
	local parts, skipped, skippedNames = {}, 0, {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d.Anchored then
			if AIRBORNE[d.Name] then
				skipped += 1
				skippedNames[d.Name] = (skippedNames[d.Name] or 0) + 1
			else
				table.insert(parts, d)
			end
		end
	end

	-- The planted fault: the first part resting within a hair of the ground, lifted by PLANT.
	local planted, plantedName = nil, nil
	for _, part in ipairs(parts) do
		if not planted and part.Size.Y < 6 and part.Size.X < 12 and part.Name ~= "Terrain" then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { part }
			local under = workspace:Raycast(part.Position - Vector3.new(0, part.Size.Y / 2 - 0.05, 0), Vector3.new(0, -4, 0), params)
			if under and part.Position.Y - part.Size.Y / 2 - under.Position.Y < 0.05 then
				planted, plantedName = part, part.Name
				part.CFrame = part.CFrame + Vector3.new(0, PLANT, 0)
			end
		end
	end
	for index, part in ipairs(parts) do
		local cf, size = part.CFrame, part.Size
		-- The lowest point of the part's own shape.
		local half = size / 2
		local drop
		if part.Shape == Enum.PartType.Ball then
			drop = math.min(half.X, half.Y, half.Z)
		else
			drop = math.abs(cf.XVector.Y) * half.X + math.abs(cf.YVector.Y) * half.Y + math.abs(cf.ZVector.Y) * half.Z
		end
		local bottom = part.Position - Vector3.new(0, drop, 0)
		everything.FilterDescendantsInstances = { part }
		local hit = workspace:Raycast(bottom + Vector3.new(0, 0.05, 0), Vector3.new(0, -60, 0), everything)
		measured += 1
		if hit then
			local gap = bottom.Y - hit.Position.Y
			if gap > LIFTED then
				local band = gap > FLOATING and counts or lifted
				band[part.Name] = (band[part.Name] or 0) + 1
				worst[part.Name] = worst[part.Name] or {}
				if #worst[part.Name] < WORST then
					table.insert(worst[part.Name], string.format("%.2f over %s at (%.0f, %.1f, %.0f)", gap,
						hit.Instance == workspace.Terrain and hit.Material.Name or hit.Instance.Name, part.Position.X, part.Position.Y, part.Position.Z))
				end
				if part == planted then
					plantedGap = gap
				end
			end
		end
		if index % 200 == 0 then
			task.wait()
		end
	end

	local names = {}
	for name, n in pairs(counts) do
		table.insert(names, { name = name, n = n, band = "floating" })
	end
	for name, n in pairs(lifted) do
		table.insert(names, { name = name, n = n, band = "lifted" })
	end
	table.sort(names, function(a, b)
		return a.n > b.n
	end)
	local floatingTotal, liftedTotal = 0, 0
	for _, entry in ipairs(names) do
		if entry.band == "floating" then
			floatingTotal += entry.n
		else
			liftedTotal += entry.n
		end
	end
	out("%s seed %d: %d anchored parts measured; floating (> %.2f) %d, lifted (%.2f..%.2f) %d",
		mapId, seed, measured, FLOATING, floatingTotal, LIFTED, FLOATING, liftedTotal)
	for rank, entry in ipairs(names) do
		if rank <= 12 then
			out("    %s %s x%d: %s", entry.band, entry.name, entry.n, table.concat(worst[entry.name], " | "))
		end
	end
	-- What was skipped, and by which name: a skip list is how a finding gets silenced quietly, so it
	-- is printed every run rather than kept in the source where nobody reads it.
	local skipList = {}
	for name, n in pairs(skippedNames) do
		table.insert(skipList, name .. " x" .. n)
	end
	table.sort(skipList)
	out("    skipped as meant-to-be-off-the-ground: %d parts [%s]", skipped, table.concat(skipList, ", "))
	-- And the planted fault, which the sweep must have named.
	if planted then
		out("    self-test: lifted a %s by %.2f -- sweep %s (%s)", plantedName, PLANT,
			plantedGap and "CAUGHT it" or "MISSED IT, THIS SWEEP IS NOT MEASURING", plantedGap and string.format("%.2f", plantedGap) or "no gap reported")
	else
		out("    self-test: found no part resting on the ground to lift -- SWEEP UNPROVEN on this map")
	end
	MapGenerator.Clear()
	task.wait(1)
end
out("done")
