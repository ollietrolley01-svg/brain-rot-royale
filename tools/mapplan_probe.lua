-- Town-plan probe for tools/runtest.ps1 -Probe: MapBuildings.RollPlan with and without a town's kind
-- profile (the Cities tab's #32 `plan`).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/mapplan_probe.lua
--
-- The contract that matters most is the one about NOTHING changing: a town that passes no profile
-- must build exactly the map it built before, from the same seed. That is not a claim to make by
-- reading the diff -- it is two things at once:
--   * the same plan out (archetype, width, depth, floors, dock), roll for roll;
--   * the same number of draws taken out of math.random, in the same order, so everything built
--     AFTER a building -- every other building, the loot, the crates -- still lands where it did.
-- Both are measured here against a verbatim copy of the old rollPlan, seeded identically, with the
-- random stream compared after every roll: if the new one took one draw more or fewer at any point,
-- the streams part company and the stream check fails even when the plans happen to match.
--
-- Then what the profile is FOR: weights choosing the mix, sizes choosing the dimensions, and the
-- palette and sign riding out on the plan for buildBuilding. Planted every run: a reference with its
-- two thresholds swapped has to fail the comparison, or none of this is evidence.
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapBuildings = require(modules:WaitForChild("MapBuildings"))

local ROLLS = 4000

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[MapPlanProbe] %s %s%s", ok and "PASS" or "FAIL", label, detail and ("  (" .. tostring(detail) .. ")") or ""))
end

-- The old rollPlan, exactly as it stood before the profile went in (2026-09-18). Kept verbatim: the
-- moment this is "tidied" it stops being the thing the new one has to match.
local function referenceRollPlan(downtown)
	local roll = math.random()
	local archetype
	if downtown then
		archetype = (roll < 0.45 and "tower") or (roll < 0.82 and "house") or "warehouse"
	else
		archetype = (roll < 0.15 and "tower") or (roll < 0.68 and "house") or "warehouse"
	end

	local plan = { archetype = archetype }
	if archetype == "tower" then
		plan.width, plan.depth, plan.floors = math.random(26, 34), math.random(26, 34), math.random(3, 5)
	elseif archetype == "warehouse" then
		plan.width, plan.depth, plan.floors = math.random(40, 52), math.random(34, 44), 1
	else
		plan.width, plan.depth, plan.floors = math.random(26, 38), math.random(26, 34), math.random(1, 2)
	end
	plan.dock = archetype == "warehouse" and plan.depth <= 40
	return plan
end

-- The same reference with its thresholds swapped: the planted fault.
local function wrongReference(downtown)
	local roll = math.random()
	local archetype
	if downtown then
		archetype = (roll < 0.82 and "tower") or (roll < 0.45 and "house") or "warehouse"
	else
		archetype = (roll < 0.68 and "tower") or (roll < 0.15 and "house") or "warehouse"
	end
	local plan = { archetype = archetype }
	if archetype == "tower" then
		plan.width, plan.depth, plan.floors = math.random(26, 34), math.random(26, 34), math.random(3, 5)
	elseif archetype == "warehouse" then
		plan.width, plan.depth, plan.floors = math.random(40, 52), math.random(34, 44), 1
	else
		plan.width, plan.depth, plan.floors = math.random(26, 38), math.random(26, 34), math.random(1, 2)
	end
	plan.dock = archetype == "warehouse" and plan.depth <= 40
	return plan
end

local function same(a, b)
	return a.archetype == b.archetype and a.width == b.width and a.depth == b.depth
		and a.floors == b.floors and (a.dock or false) == (b.dock or false)
end
local function describe(plan)
	return string.format("%s %dx%d f%d%s", plan.archetype, plan.width, plan.depth, plan.floors, plan.dock and " dock" or "")
end

-- Rolls `n` plans from `seed` with `roller`, keeping each plan and the state of the random stream
-- after it (one extra draw per roll, taken from the same stream, which is what makes a difference in
-- draw COUNT visible).
local function sequence(seed, n, roller, downtownEvery)
	math.randomseed(seed)
	local plans, marks = {}, {}
	for index = 1, n do
		plans[index] = roller(index % downtownEvery == 0)
		marks[index] = math.random()
	end
	return plans, marks
end

-- No profile: the same plans and the same draws as before -----------------------------------------
do
	local newPlans, newMarks = sequence(20260918, ROLLS, function(downtown)
		return MapBuildings.RollPlan(downtown)
	end, 3)
	local oldPlans, oldMarks = sequence(20260918, ROLLS, referenceRollPlan, 3)

	local planMismatch, streamMismatch, firstBad = 0, 0, nil
	for index = 1, ROLLS do
		if not same(newPlans[index], oldPlans[index]) then
			planMismatch += 1
			firstBad = firstBad or string.format("#%d new %s vs old %s", index, describe(newPlans[index]), describe(oldPlans[index]))
		end
		if newMarks[index] ~= oldMarks[index] then
			streamMismatch += 1
		end
	end
	expect(string.format("no profile: %d rolls build the same plans as before", ROLLS), planMismatch == 0, firstBad)
	expect("no profile: the random stream is left in the same place, roll for roll", streamMismatch == 0,
		string.format("%d of %d rolls diverged", streamMismatch, ROLLS))
	-- Vacuity guard: a run where every plan came out the same would pass the comparison trivially.
	local seen = {}
	for _, plan in ipairs(newPlans) do
		seen[plan.archetype] = (seen[plan.archetype] or 0) + 1
	end
	expect("no profile: all three archetypes actually came up", (seen.tower or 0) > 0 and (seen.house or 0) > 0 and (seen.warehouse or 0) > 0,
		string.format("tower %d, house %d, warehouse %d", seen.tower or 0, seen.house or 0, seen.warehouse or 0))
end

-- The planted fault: a reference that is wrong must be caught ---------------------------------------
do
	local newPlans = sequence(20260918, ROLLS, function(downtown)
		return MapBuildings.RollPlan(downtown)
	end, 3)
	local badPlans = sequence(20260918, ROLLS, wrongReference, 3)
	local mismatch = 0
	for index = 1, ROLLS do
		if not same(newPlans[index], badPlans[index]) then
			mismatch += 1
		end
	end
	expect("planted: a reference with its thresholds swapped is caught", mismatch > 0, string.format("%d rolls differ", mismatch))
end

-- A profile that restates the defaults must be indistinguishable from none -------------------------
do
	local defaults = {
		weights = { downtown = { tower = 45, house = 37, warehouse = 18 }, edge = { tower = 15, house = 53, warehouse = 32 } },
		sizes = {
			tower = { width = { 26, 34 }, depth = { 26, 34 }, floors = { 3, 5 } },
			warehouse = { width = { 40, 52 }, depth = { 34, 44 }, floors = 1 },
			house = { width = { 26, 38 }, depth = { 26, 34 }, floors = { 1, 2 } },
		},
	}
	local withPlan, withMarks = sequence(4242, ROLLS, function(downtown)
		return MapBuildings.RollPlan(downtown, defaults)
	end, 3)
	local without, withoutMarks = sequence(4242, ROLLS, function(downtown)
		return MapBuildings.RollPlan(downtown)
	end, 3)
	local mismatch, streamMismatch = 0, 0
	for index = 1, ROLLS do
		if not same(withPlan[index], without[index]) then
			mismatch += 1
		end
		if withMarks[index] ~= withoutMarks[index] then
			streamMismatch += 1
		end
	end
	expect("a profile that restates the defaults changes nothing", mismatch == 0, mismatch)
	expect("...and takes the same draws doing it", streamMismatch == 0, streamMismatch)
end

-- Weights ------------------------------------------------------------------------------------------
do
	local onlyWarehouses = { weights = { downtown = { tower = 0, house = 0, warehouse = 1 }, edge = { tower = 0, house = 0, warehouse = 1 } } }
	local counts = {}
	math.randomseed(7)
	for _ = 1, 500 do
		local plan = MapBuildings.RollPlan(true, onlyWarehouses)
		counts[plan.archetype] = (counts[plan.archetype] or 0) + 1
	end
	expect("weights: an all-warehouse town rolls only warehouses", (counts.warehouse or 0) == 500, counts.tower or 0)

	-- The list form, in ARCHETYPES order, must mean the same as the keyed form.
	local listed = { weights = { downtown = { 0, 1, 0 }, edge = { 0, 1, 0 } } }
	local houses = 0
	math.randomseed(8)
	for _ = 1, 400 do
		if MapBuildings.RollPlan(false, listed).archetype == "house" then
			houses += 1
		end
	end
	expect("weights: a list { tower, house, warehouse } reads the same as the keyed form", houses == 400, houses)

	-- A tilted mix has to actually tilt, and by roughly the amount asked for.
	local tilted = { weights = { downtown = { tower = 80, house = 10, warehouse = 10 }, edge = { tower = 80, house = 10, warehouse = 10 } } }
	local towers = 0
	math.randomseed(9)
	for _ = 1, 2000 do
		if MapBuildings.RollPlan(true, tilted).archetype == "tower" then
			towers += 1
		end
	end
	expect("weights: 80/10/10 gives about 80% towers", math.abs(towers / 2000 - 0.8) < 0.04, string.format("%.1f%%", towers / 20))

	-- Weights that add to nothing must not build a town of nils.
	math.randomseed(10)
	local empty = MapBuildings.RollPlan(true, { weights = { downtown = { tower = 0, house = 0, warehouse = 0 } } })
	expect("weights: all-zero weights still produce a building", empty.archetype ~= nil and empty.width > 0, empty.archetype)
end

-- Sizes --------------------------------------------------------------------------------------------
do
	local terraceish = {
		weights = { downtown = { tower = 0, house = 1, warehouse = 0 }, edge = { tower = 0, house = 1, warehouse = 0 } },
		sizes = { house = { width = { 18, 22 }, depth = { 24, 28 }, floors = 2 } },
	}
	local outOfRange, wrongFloors, widths = 0, 0, {}
	math.randomseed(11)
	for _ = 1, 600 do
		local plan = MapBuildings.RollPlan(false, terraceish)
		if plan.width < 18 or plan.width > 22 or plan.depth < 24 or plan.depth > 28 then
			outOfRange += 1
		end
		if plan.floors ~= 2 then
			wrongFloors += 1
		end
		widths[plan.width] = true
	end
	local spread = 0
	for _ in pairs(widths) do
		spread += 1
	end
	expect("sizes: widths and depths stay inside the profile's ranges", outOfRange == 0, outOfRange)
	expect("sizes: a fixed floors value is used exactly", wrongFloors == 0, wrongFloors)
	expect("sizes: the range is a range, not one number repeated", spread >= 4, spread)

	-- A fixed value must take NO draw: two profiles differing only in a fixed field would otherwise
	-- pull the stream apart and move everything built after the building.
	local fixed = { sizes = { house = { width = 30, depth = 30, floors = 1 } },
		weights = { downtown = { tower = 0, house = 1, warehouse = 0 }, edge = { tower = 0, house = 1, warehouse = 0 } } }
	math.randomseed(12)
	MapBuildings.RollPlan(false, fixed)
	local afterFixed = math.random()
	math.randomseed(12)
	math.random() -- the archetype draw, and nothing else
	local expected = math.random()
	expect("sizes: fixed dimensions draw no randoms at all", afterFixed == expected)
end

-- Palette and sign ride out on the plan --------------------------------------------------------------
do
	local palette = { wallColors = { Color3.new(0.5, 0.5, 0.5) }, roofMaterial = Enum.Material.Metal }
	math.randomseed(13)
	local plan = MapBuildings.RollPlan(true, { palette = palette, sign = false })
	expect("the palette is carried out on the plan", plan.palette == palette)
	expect("sign = false survives as false, not nil", plan.sign == false, tostring(plan.sign))
	local named = { text = "SAHUR SUPPLIES", color = Color3.new(1, 0, 0) }
	math.randomseed(14)
	expect("a named sign is carried out on the plan", MapBuildings.RollPlan(true, { sign = named }).sign == named)
	math.randomseed(15)
	local plain = MapBuildings.RollPlan(true)
	expect("no profile leaves palette and sign unset", plain.palette == nil and plain.sign == nil)
end

-- Variants (#32 batch 2) --------------------------------------------------------------------------
do
	math.randomseed(16)
	expect("the variant is carried out on the plan", MapBuildings.RollPlan(true, { variant = "terrace" }).variant == "terrace")
	math.randomseed(17)
	expect("no profile leaves the variant unset", MapBuildings.RollPlan(true).variant == nil)

	-- A terrace's side walls are blank: no windows on them, and the building still has its own four
	-- walls (nothing shared with a neighbour). Measured on the built model, not on the plan: build one
	-- of each and compare how many window openings each has on its SIDE walls.
	local function sideWindows(variant)
		local folder = Instance.new("Folder")
		folder.Parent = workspace
		local preset = { wallMaterials = { Enum.Material.Brick }, wallColors = { Color3.new(0.6, 0.6, 0.6) },
			roofColors = { Color3.new(0.3, 0.3, 0.3) }, roofMaterial = Enum.Material.Slate, floorMaterial = Enum.Material.WoodPlanks }
		local plan = { archetype = "house", width = 30, depth = 30, floors = 2, variant = variant }
		MapBuildings.BuildBuilding(folder, Vector3.new(0, 0, 0), preset, {}, { weapon = {}, heal = {}, item = {} }, plan, 0)
		local model = folder:FindFirstChildOfClass("Model")
		local sides, walls = 0, 0
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "WindowGlass" then
				-- A side wall runs along Z, so its glass is thin in X.
				if part.Size.X < part.Size.Z then
					sides += 1
				end
			elseif part:IsA("BasePart") and part.Name == "Wall" then
				walls += 1
			end
		end
		folder:Destroy()
		return sides, walls
	end
	local plainSides, plainWalls = sideWindows(nil)
	local terraceSides, terraceWalls = sideWindows("terrace")
	expect("terrace: no windows in the side walls", terraceSides == 0, terraceSides)
	expect("terrace: the plain house it is compared against HAS side windows", plainSides > 0, plainSides)
	expect("terrace: it still builds its own full set of walls", terraceWalls >= plainWalls,
		string.format("%d walls vs %d", terraceWalls, plainWalls))
end

print(string.format("[MapPlanProbe] %d passed, %d failed", passes, failures))
print("[PROBE] map plans: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))
