-- Wilds gallery: photographs every MapWilds specimen up close, then a whole map with its wilds.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/wilds_gallery.lua -OutDir <folder> -TimeoutSeconds 1200
--
-- Pick the map by editing MAP_ID below. Uses the place's own MapWilds module; until the place is
-- built with it, a copy of this file with the module's source pasted in at WILDS_EMBED works too.

local MAP_ID = "SahurSprings"
local SEED = 424242

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")

local EMBEDDED_WILDS = nil --[[WILDS_EMBED]]
local MapWilds
if modules:FindFirstChild("MapWilds") then
	MapWilds = require(modules.MapWilds)
else
	MapWilds = loadstring(EMBEDDED_WILDS)()
end

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local ORIGIN = Vector3.new(6000, 400, 6000)
local state = {}

local function look(camera, from, to, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, to)
end

-- The specimen row, built once and kept outside the folder the runner clears between views.
local function specimens()
	if state.entries then
		return state.entries
	end
	local stage = Instance.new("Folder")
	stage.Name = "WildsGalleryStage"
	stage.Parent = workspace
	local pad = Instance.new("Part")
	pad.Anchored = true
	pad.Size = Vector3.new(1300, 2, 160)
	pad.CFrame = CFrame.new(ORIGIN + Vector3.new(620, -1, 0))
	pad.Color = Color3.fromRGB(86, 122, 66)
	pad.Material = Enum.Material.Grass
	pad.Parent = stage
	local _, entries = MapWilds.Specimens(stage, ORIGIN, function()
		return ORIGIN.Y
	end, 11)
	local byName = {}
	for _, entry in ipairs(entries) do
		byName[entry.name] = entry
	end
	state.entries = byName
	return byName
end

-- A view of a stretch of the row, from the front and a little above.
local function rowView(name, first, last, height, back)
	return {
		name = name,
		settle = 2,
		setup = function(_, camera)
			local entries = specimens()
			local a, b = entries[first], entries[last]
			if not (a and b) then
				note("missing " .. first .. " or " .. last)
				return
			end
			local mid = (a.at + b.at) / 2
			local span = (b.at - a.at).Magnitude + 30
			look(camera, mid + Vector3.new(0, height or span * 0.25, -(back or span * 0.85)), mid + Vector3.new(0, 7, 0), 55)
		end,
	}
end

local function closeView(name, entryName, from, target)
	return {
		name = name,
		settle = 2,
		setup = function(_, camera)
			local entry = specimens()[entryName]
			if not entry then
				note("missing " .. entryName)
				return
			end
			look(camera, entry.at + from, entry.at + (target or Vector3.new(0, 5, 0)), 60)
		end,
	}
end

local views = {
	rowView("trees_all", "Tree_oak", "Tree_spruceSnowy", 18, 150),
	closeView("tree_oak", "Tree_oak", Vector3.new(-18, 14, -34), Vector3.new(0, 14, 0)),
	closeView("tree_birch_spruce", "Tree_birch", Vector3.new(8, 12, -40), Vector3.new(12, 11, 0)),
	closeView("tree_dead_acacia", "Tree_dead", Vector3.new(10, 10, -36), Vector3.new(14, 8, 0)),
	closeView("tree_yucca_palm_apple", "Tree_fanPalm", Vector3.new(-4, 9, -38), Vector3.new(4, 6, 0)),
	closeView("tree_spruce_snowy", "Tree_spruceSnowy", Vector3.new(-10, 10, -28), Vector3.new(0, 9, 0)),
	rowView("ground_all", "Ground_fern", "Ground_boulder", 8, 36),
	closeView("ground_close", "Ground_flowers", Vector3.new(2, 4, -12), Vector3.new(4, 1, 0)),
	closeView("shelter_leanto", "Shelter_leanTo", Vector3.new(-14, 9, -24), Vector3.new(0, 3, -1)),
	closeView("shelter_campsite", "Shelter_campsite", Vector3.new(10, 14, -26), Vector3.new(0, 2, 0)),
	closeView("shelter_cabin_front", "Shelter_cabin", Vector3.new(-20, 12, -34), Vector3.new(0, 5, 0)),
	closeView("shelter_cabin_back", "Shelter_cabin", Vector3.new(22, 14, 30), Vector3.new(0, 5, 0)),
	closeView("shelter_bothy", "Shelter_bothy", Vector3.new(-16, 12, -30), Vector3.new(0, 5, 0)),
	closeView("shelter_beachhut", "Shelter_beachHut", Vector3.new(16, 12, -32), Vector3.new(0, 5, 0)),
	closeView("shelter_shack", "Shelter_shack", Vector3.new(-18, 11, -28), Vector3.new(0, 4, 0)),
	closeView("shelter_ruin", "Shelter_ruin", Vector3.new(-20, 18, -34), Vector3.new(0, 3, 0)),
	closeView("shelter_ruin_sandstone", "Shelter_sandstoneRuin", Vector3.new(20, 16, -32), Vector3.new(0, 3, 0)),
	closeView("shelter_ruin_concrete", "Shelter_concreteRuin", Vector3.new(-18, 14, 30), Vector3.new(0, 3, 0)),
	closeView("shelter_rock", "Shelter_rockShelter", Vector3.new(-10, 8, -26), Vector3.new(0, 4, 0)),
	closeView("shelter_deerstand", "Shelter_deerStand", Vector3.new(-16, 16, -28), Vector3.new(0, 10, 0)),
	closeView("shelter_polebarn", "Shelter_poleBarn", Vector3.new(18, 12, -32), Vector3.new(0, 5, 0)),
	closeView("shelter_palapa", "Shelter_palapa", Vector3.new(-14, 9, -22), Vector3.new(0, 4, 0)),
	closeView("shelter_pipes", "Shelter_pipes", Vector3.new(14, 8, -26), Vector3.new(0, 3, 0)),
	closeView("shelter_bus", "Shelter_busShelter", Vector3.new(-8, 6, -16), Vector3.new(0, 3.5, 0)),
	closeView("shelter_wreck", "Shelter_wreck", Vector3.new(-14, 8, -16), Vector3.new(0, 2, 0)),
	closeView("shelter_boat", "Shelter_upturnedBoat", Vector3.new(10, 6, -14), Vector3.new(0, 1.5, 0)),
	closeView("ground_cairn_picnic", "Ground_cairn", Vector3.new(2, 7, -16), Vector3.new(4, 1.5, 0)),
	closeView("season_autumn", "Season_oakAutumn", Vector3.new(6, 14, -40), Vector3.new(9, 13, 0)),
	closeView("season_snow", "Season_slateShelterSnow", Vector3.new(12, 16, -34), Vector3.new(14, 5, 0)),
}

-- The map, with its wilds built the way tools/wilds_map_probe.lua builds them.
table.insert(views, {
	name = "map_overview",
	settle = 4,
	setup = function(_, camera)
		local stage = workspace:FindFirstChild("WildsGalleryStage")
		if stage then
			stage:Destroy()
		end
		local MapGenerator = require(modules:WaitForChild("MapGenerator"))
		local MapSpace = require(modules:WaitForChild("MapSpace"))
		local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))
		math.randomseed(SEED)
		local info = MapGenerator.Build(MAP_ID)
		local map = workspace.Map
		local centers = {}
		for _, child in ipairs(map:GetChildren()) do
			if child.Name == "Town" and child:GetAttribute("TownCenter") then
				table.insert(centers, child:GetAttribute("TownCenter"))
			end
		end
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
		local result = MapWilds.Build(map, {
			preset = MapData.Get(MAP_ID), radius = info.radius, centers = centers,
			townSpread = math.floor(math.max(110, info.radius * 0.17)), space = space,
			groundAt = MapGenerator.GroundHeightAt, roads = info.roads, river = info.river, seed = SEED,
		})
		note(string.format("map %s wilds %d parts, %d trees, %d shelters", MAP_ID, result.parts, result.counts.trees, result.counts.shelters))
		state.info, state.wilds, state.ground = info, result, MapGenerator.GroundHeightAt

		-- Pick subjects: the biggest woods, and a spread of shelters.
		local woods, shelters = nil, {}
		for _, child in ipairs(result.model:GetChildren()) do
			local kind = string.gsub(child.Name, "_%d+$", "")
			local pivot = child:GetPivot().Position
			if kind == "Woods" then
				if not woods or #child:GetChildren() > #woods:GetChildren() then
					woods = child
				end
			elseif kind ~= "Trees" and kind ~= "Clutter" and kind ~= "GroundCover" and kind ~= "Meadow" and kind ~= "Hedgerow"
				and kind ~= "StoneWall" and kind ~= "Orchard" then
				table.insert(shelters, { model = child, kind = kind, at = pivot })
			end
		end
		state.woods = woods
		state.shelters = shelters
		look(camera, Vector3.new(0, info.radius * 1.3, info.radius * 0.35), Vector3.new(0, 0, 0), 70)
	end,
})

-- Fixed cameras, the same world position on every build, so a before and an after can be laid side
-- by side: the woods themselves move when the density changes, and a camera that follows them would
-- hide the very thing being judged.
for _, spec in ipairs({
	{ name = "compare_ground", at = Vector3.new(0.42, 0, 0.18), height = 6, look = Vector3.new(0.9, 0, 0.32), fov = 70 },
	{ name = "compare_over", at = Vector3.new(-0.35, 0, -0.3), height = 90, look = Vector3.new(0.1, 0, 0.1), fov = 60 },
}) do
	table.insert(views, {
		name = spec.name,
		settle = 3,
		setup = function(_, camera)
			local radius = state.info and state.info.radius or 1000
			local from = Vector3.new(spec.at.X * radius, 0, spec.at.Z * radius)
			local ground = state.ground and state.ground(from.X, from.Z) or 0
			local to = Vector3.new(spec.look.X * radius, (ground or 0) + spec.height * 0.35, spec.look.Z * radius)
			look(camera, Vector3.new(from.X, (ground or 0) + spec.height, from.Z), to, spec.fov)
		end,
	})
end

table.insert(views, {
	name = "map_woods_aerial",
	settle = 3,
	setup = function(_, camera)
		if not state.woods then
			return
		end
		local centre = state.woods:GetPivot().Position
		look(camera, centre + Vector3.new(-90, 110, -140), centre, 60)
	end,
})

table.insert(views, {
	name = "map_woods_inside",
	settle = 3,
	setup = function(_, camera)
		if not state.woods then
			return
		end
		local centre = state.woods:GetPivot().Position
		local from = centre + Vector3.new(-45, 0, -30)
		from = Vector3.new(from.X, state.ground(from.X, from.Z) + 5.5, from.Z)
		local to = Vector3.new(centre.X, state.ground(centre.X, centre.Z) + 5, centre.Z)
		look(camera, from, to, 70)
	end,
})

for index = 1, 6 do
	table.insert(views, {
		name = "map_shelter_" .. index,
		settle = 3,
		setup = function(_, camera)
			local shelters = state.shelters or {}
			local pickIndex = math.floor((index - 0.5) / 6 * #shelters) + 1
			local entry = shelters[pickIndex]
			if not entry then
				return
			end
			note("shelter " .. index .. ": " .. entry.model.Name)
			local at = entry.at
			local look_ = entry.model:GetPivot().LookVector
			local from = at + look_ * 40 + Vector3.new(15, 0, 0)
			from = Vector3.new(from.X, (state.ground(from.X, from.Z) or 0) + 14, from.Z)
			look(camera, from, at + Vector3.new(0, 4, 0), 60)
		end,
	})
end

return views
