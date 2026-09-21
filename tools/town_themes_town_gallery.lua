-- Town themes in real towns: builds a whole map and photographs each themed town's set piece where
-- it landed, with the terrain it stands on. Then, for set pieces whose ground was swapped for a
-- smooth stand-in (Pavement -> Asphalt and so on: rough or stud-snapping materials move the surface),
-- repaints that lot in the material it asked for and photographs it again, so the swap can be
-- judged side by side ("_after" is what ships, "_before" is the old paint).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/town_themes_town_gallery.lua -OutDir <folder> -TimeoutSeconds 900 [-PlaceFile <rbxlx>]
--
-- Pick the map by editing MAP_ID and SEED below (the gallery runner takes no arguments).

local MAP_ID, SEED = "SahurSprings", 101
local TOWNS = 5

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local state = { sites = {} }

-- Each themed town's set piece: its site frame and size, the ground it asked for, and the town level.
local function collect(TownThemes, map, groundAt)
	for _, town in ipairs(map:GetChildren()) do
		local name = town.Name == "Town" and town:GetAttribute("TownName")
		local theme = name and TownThemes.Themes[name]
		local root = theme and town:FindFirstChild("Theme")
		if root then
			for _, child in ipairs(root:GetChildren()) do
				local site = child:GetAttribute("Site")
				if typeof(site) == "CFrame" then
					local center = town:GetAttribute("TownCenter")
					table.insert(state.sites, {
						name = name,
						id = theme.id,
						model = child,
						site = site,
						size = child:GetAttribute("SiteSize"),
						onStreet = child:GetAttribute("OnStreet"),
						wanted = theme.setPiece.ground,
						level = center and groundAt(center.X, center.Z) or site.Position.Y,
					})
				end
			end
		end
	end
	table.sort(state.sites, function(a, b)
		return a.id < b.id
	end)
end

local function street(camera, entry)
	camera.FieldOfView = 72
	local eye = entry.site * Vector3.new(-10, 5.5, -entry.size.Z / 2 - 13)
	camera.CFrame = CFrame.lookAt(eye, entry.site * Vector3.new(2, 6, 0))
end

local function aerial(camera, entry)
	camera.FieldOfView = 58
	local eye = entry.site * Vector3.new(entry.size.X * 0.35, 48, -entry.size.Z / 2 - 40)
	camera.CFrame = CFrame.lookAt(eye, entry.site * Vector3.new(0, 0, 2))
end

-- The old paint, exactly as the module used to lay it: the top four studs of solid ground in the
-- wanted material, reaching on to the pavement for a street lot.
local function repaintWanted(MapTerrain, entry)
	local reach = entry.onStreet and 3 or 0
	local centre = entry.site * Vector3.new(0, 0, -reach / 2)
	workspace.Terrain:FillBlock(CFrame.new(centre.X, -2 - MapTerrain.SurfaceLift, centre.Z) * entry.site.Rotation,
		Vector3.new(entry.size.X, 4, entry.size.Z + reach), entry.wanted)
end

local views = {
	{
		name = "00_build",
		settle = 2,
		setup = function(_, camera)
			Lighting.ClockTime = 14.5
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			local TownThemes = require(modules:WaitForChild("TownThemes"))
			math.randomseed(SEED)
			local started = os.clock()
			local info = MapGenerator.Build(MAP_ID)
			local map = workspace:FindFirstChild("Map")
			note("built %s seed %d in %.1fs, radius %d", MAP_ID, SEED, os.clock() - started, info and info.radius or -1)
			collect(TownThemes, map, MapGenerator.GroundHeightAt)
			for index, entry in ipairs(state.sites) do
				local stand = TownThemes.SmoothGround and TownThemes.SmoothGround(entry.wanted)
				note("site %d %s (%s): wanted %s, painted %s, street=%s, at %s",
					index, entry.name, entry.model.Name, tostring(entry.wanted), tostring(stand), tostring(entry.onStreet), tostring(entry.site.Position))
			end
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt(Vector3.new(0, 900, 1), Vector3.zero)
		end,
	},
}

for index = 1, TOWNS do
	for _, shot in ipairs({ "street", "aerial" }) do
		table.insert(views, {
			name = string.format("%02d_after_%s", index, shot),
			settle = 2,
			setup = function(_, camera)
				local entry = state.sites[index]
				if not entry then
					note("no themed town %d", index)
					return
				end
				note("%s after %s", entry.id, shot)
				if shot == "street" then
					street(camera, entry)
				else
					aerial(camera, entry)
				end
			end,
		})
	end
end

-- The befores come last: repainting changes the map for every shot after it.
for index = 1, TOWNS do
	for _, shot in ipairs({ "street", "aerial" }) do
		table.insert(views, {
			name = string.format("%02d_before_%s", index, shot),
			settle = 2,
			setup = function(_, camera)
				local entry = state.sites[index]
				local TownThemes = require(modules:WaitForChild("TownThemes"))
				local stand = entry and TownThemes.SmoothGround and TownThemes.SmoothGround(entry.wanted)
				-- Only lots flat at the town's own level were ever painted.
				if not entry or not entry.wanted or stand == entry.wanted or math.abs(entry.site.Position.Y - entry.level) >= 0.3 then
					note("town %d: nothing swapped or not a painted lot", index)
					camera.CFrame = CFrame.lookAt(Vector3.new(0, 900, 1), Vector3.zero)
					return
				end
				if not entry.repainted then
					repaintWanted(require(modules:WaitForChild("MapTerrain")), entry)
					entry.repainted = true
				end
				note("%s before %s (%s)", entry.id, shot, tostring(entry.wanted))
				if shot == "street" then
					street(camera, entry)
				else
					aerial(camera, entry)
				end
			end,
		})
	end
end

return views
