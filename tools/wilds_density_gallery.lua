-- Wilds density gallery: ONE map, built once, with its wilds rebuilt at several part budgets and
-- photographed from the SAME cameras each time. "Way more foliage" is a matter of taste, so this
-- makes it a choice between pictures rather than between numbers.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/wilds_density_gallery.lua -OutDir <folder> -TimeoutSeconds 1800
--
-- Edit MAP_ID and BUDGETS below. The cameras are fixed in world space, not aimed at whatever the
-- build happened to place: a camera that followed the woods would hide the very thing being judged.

local MAP_ID = "SahurSprings"
local SEED = 424242
local BUDGETS = { 12, 16, 20 }

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapSpace = require(modules:WaitForChild("MapSpace"))
local MapWilds = require(modules:WaitForChild("MapWilds"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function look(camera, from, to, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, to)
end

-- The map itself is built once: the terrain, towns and roads are not what is being compared, and
-- rebuilding them per budget would move every camera's subject.
local function theMap()
	if state.map then
		return state.map
	end
	math.randomseed(SEED)
	local info = MapGenerator.Build(MAP_ID)
	local map = workspace:WaitForChild("Map")
	task.wait(1)
	local centers = {}
	for _, child in ipairs(map:GetChildren()) do
		if child.Name == "Town" and child:GetAttribute("TownCenter") then
			table.insert(centers, child:GetAttribute("TownCenter"))
		end
	end
	state.map, state.info, state.centers = map, info, centers
	state.townSpread = math.floor(math.max(110, info.radius * 0.17))

	-- The longest gap between two towns, which is where the wilds have the most room. Towns do not
	-- move between budgets, so this camera is the same world position in every set -- and it is
	-- pointed at the ground the wilds are FOR, rather than at a town's own cleared hillside.
	local bestGap, a, b = 0, nil, nil
	for i = 1, #centers do
		for j = i + 1, #centers do
			local gap = (Vector3.new(centers[i].X, 0, centers[i].Z) - Vector3.new(centers[j].X, 0, centers[j].Z)).Magnitude
			if gap > bestGap then
				bestGap, a, b = gap, centers[i], centers[j]
			end
		end
	end
	if a and b then
		local from = Vector3.new(a.X, 0, a.Z)
		local to = Vector3.new(b.X, 0, b.Z)
		state.between = from + (to - from) * 0.5
		state.alongTowns = (to - from).Unit
	else
		state.between = Vector3.new(info.radius * 0.4, 0, info.radius * 0.2)
		state.alongTowns = Vector3.new(1, 0, 0)
	end
	return map
end

-- A fresh MapSpace per build, rebuilt from the finished map exactly as the hook does: a build that
-- saw the last build's claims would place less and read as a cheaper density.
local function freshSpace()
	local info, map = state.info, state.map
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

local function buildAt(budget)
	local map = theMap()
	if state.wilds then
		state.wilds.model:Destroy()
		task.wait(0.4)
	end
	local was = MapWilds.BUDGET_PER_RADIUS
	MapWilds.BUDGET_PER_RADIUS = budget
	local result = MapWilds.Build(map, {
		preset = MapData.Get(MAP_ID), radius = state.info.radius, centers = state.centers,
		townSpread = state.townSpread, space = freshSpace(), groundAt = MapGenerator.GroundHeightAt,
		roads = state.info.roads, river = state.info.river, seed = SEED,
	})
	MapWilds.BUDGET_PER_RADIUS = was
	state.wilds = result
	local casting, quiet = 0, 0
	for _, d in ipairs(result.model:GetDescendants()) do
		if d:IsA("BasePart") then
			if d.CastShadow then
				casting += 1
			else
				quiet += 1
			end
		end
	end
	note(string.format("%s at %g per stud%s: %d parts, %d trees, %d undergrowth, %d shelters, %d parts cast shadows and %d do not",
		MAP_ID, budget, MapWilds.SHADOW_TRIM and "" or " WITH EVERY PART CASTING", result.parts, result.counts.trees,
		result.counts.undergrowth, result.counts.shelters, casting, quiet))

	-- The biggest stand of trees, for the two woods cameras. Picked per budget on purpose: at a
	-- higher budget there IS a bigger stand, and pinning the camera to the sparse build's stand
	-- would photograph the one place the change is least visible.
	local woods
	for _, child in ipairs(result.model:GetChildren()) do
		if string.gsub(child.Name, "_%d+$", "") == "Woods" then
			if not woods or #child:GetChildren() > #woods:GetChildren() then
				woods = child
			end
		end
	end
	state.woods = woods
	return result
end

-- Fixed cameras in fractions of the map radius, so the same world positions are photographed at
-- every budget and the three sets lay side by side.
local SHOTS = {
	{ name = "aerial", from = Vector3.new(0, 1.3, 0.35), to = Vector3.new(0, 0, 0), fov = 70, absolute = true },
	{ name = "over", at = Vector3.new(-0.35, 0, -0.3), height = 90, look = Vector3.new(0.1, 0, 0.1), fov = 60 },
	{ name = "between_towns", between = true, back = 150, height = 6.5, ahead = 260, fov = 75 },
	{ name = "between_towns_up", between = true, back = 120, height = 70, ahead = 300, fov = 65 },
}

local views = {}
for _, budget in ipairs(BUDGETS) do
	local tag = string.format("%02d", budget)
	for index, shot in ipairs(SHOTS) do
		table.insert(views, {
			name = string.format("%s_%s", tag, shot.name),
			settle = index == 1 and 4 or 3,
			setup = function(_, camera)
				if index == 1 then
					buildAt(budget)
				end
				local radius = state.info.radius
				if shot.absolute then
					look(camera, Vector3.new(shot.from.X * radius, shot.from.Y * radius, shot.from.Z * radius),
						shot.to * radius, shot.fov)
					return
				end
				local from, to
				if shot.between then
					from = state.between - state.alongTowns * shot.back
					to = state.between + state.alongTowns * shot.ahead
				else
					from = Vector3.new(shot.at.X * radius, 0, shot.at.Z * radius)
					to = Vector3.new(shot.look.X * radius, 0, shot.look.Z * radius)
				end
				local ground = MapGenerator.GroundHeightAt(from.X, from.Z) or 0
				look(camera, Vector3.new(from.X, ground + shot.height, from.Z),
					Vector3.new(to.X, ground + shot.height * 0.35, to.Z), shot.fov)
			end,
		})
	end
	-- Inside the biggest stand, at head height: the shot that says whether woods read as woods.
	table.insert(views, {
		name = tag .. "_woods_inside",
		settle = 3,
		setup = function(_, camera)
			if not state.woods then
				return
			end
			local centre = state.woods:GetPivot().Position
			local from = centre + Vector3.new(-45, 0, -30)
			local ground = MapGenerator.GroundHeightAt(from.X, from.Z) or centre.Y
			local to = Vector3.new(centre.X, (MapGenerator.GroundHeightAt(centre.X, centre.Z) or centre.Y) + 5, centre.Z)
			look(camera, Vector3.new(from.X, ground + 5.5, from.Z), to, 75)
		end,
	})
	table.insert(views, {
		name = tag .. "_woods_aerial",
		settle = 3,
		setup = function(_, camera)
			if not state.woods then
				return
			end
			local centre = state.woods:GetPivot().Position
			look(camera, centre + Vector3.new(-90, 110, -140), centre, 60)
		end,
	})
end

-- The shadow trim, before and after, from the same two cameras at one density: the count says what
-- it saved and the pair says whether anything was lost. Last, so the budget sets above are not
-- disturbed by it.
local SHADOW_BUDGET = 12
for _, spec in ipairs({ { tag = "z1_allshadows", trim = false }, { tag = "z2_trimmed", trim = true } }) do
	for index, shot in ipairs({ SHOTS[3], SHOTS[4] }) do
		table.insert(views, {
			name = spec.tag .. "_" .. shot.name,
			settle = index == 1 and 4 or 3,
			setup = function(_, camera)
				if index == 1 then
					MapWilds.SHADOW_TRIM = spec.trim
					buildAt(SHADOW_BUDGET)
					MapWilds.SHADOW_TRIM = true
				end
				local from = state.between - state.alongTowns * shot.back
				local to = state.between + state.alongTowns * shot.ahead
				local ground = MapGenerator.GroundHeightAt(from.X, from.Z) or 0
				look(camera, Vector3.new(from.X, ground + shot.height, from.Z),
					Vector3.new(to.X, ground + shot.height * 0.35, to.Z), shot.fov)
			end,
		})
	end
end

return views
