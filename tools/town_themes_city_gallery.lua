-- City gallery (#32): builds one map and photographs EVERY town twice — from 200 studs (the "what
-- town is this" view: silhouette, density, colour, the district block) and from its main street (the
-- "what is it like to stand here" view). Run once before #32 for the baseline, then again as each
-- town lands, so every town has a before and an after from the same two cameras.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/town_themes_city_gallery.lua -OutDir <folder> -TimeoutSeconds 900 [-PlaceFile <rbxlx>]
--
-- Pick the map by editing MAP_ID and SEED below (the gallery runner takes no arguments). Views are
-- numbered by town in name order; each view's note names the town, its kind and its theme cost, so
-- a file maps back to a town by the log.

local MAP_ID, SEED = "SahurSprings", 101
-- The most towns any preset has (Bombardiro Bay, 7); a map with fewer leaves the spare views blank
-- with a note.
local MAX_TOWNS = 7

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local state = { towns = {} }

local function collect(map)
	for _, town in ipairs(map:GetChildren()) do
		local name = town.Name == "Town" and town:GetAttribute("TownName")
		local center = name and town:GetAttribute("TownCenter")
		if typeof(center) == "Vector3" then
			local theme = town:FindFirstChild("Theme")
			-- How far the main street (along X) is actually drawn: streets stop past their last
			-- building, so a camera at the planned length stands on grass (the baseline run did).
			local reach = 40
			for _, child in ipairs(town:GetChildren()) do
				if child:IsA("BasePart") and child.Name == "Asphalt" and child.Size.Z >= 30 and math.abs(child.CFrame.LookVector.X) > 0.9
					and math.abs(child.Position.Z - center.Z) < 2 then
					local far = math.abs(child.Position.X - center.X) + child.Size.Z / 2
					reach = math.max(reach, far)
				end
			end
			table.insert(state.towns, {
				name = name,
				center = center,
				reach = reach,
				spread = town:GetAttribute("TownSpread") or 150,
				kind = town:GetAttribute("TownKind") or "(no kind yet)",
				tagline = town:GetAttribute("TownTagline") or "",
				themeParts = theme and theme:GetAttribute("ThemeParts") or 0,
				themeMillis = theme and theme:GetAttribute("ThemeMillis") or -1,
			})
		end
	end
	table.sort(state.towns, function(a, b)
		return a.name < b.name
	end)
end

-- 200 studs from the town centre, 35 degrees up, standing on the side most players arrive from (the
-- map's middle; the central town picks +X), looking at the square.
local function farView(camera, town)
	camera.FieldOfView = 55
	local c = town.center
	local flat = Vector3.new(c.X, 0, c.Z)
	local toward = flat.Magnitude > 1 and -flat.Unit or Vector3.new(1, 0, 0)
	local eye = c + toward * 164 + Vector3.new(0, 115, 0)
	camera.CFrame = CFrame.lookAt(eye, c + Vector3.new(0, 8, 0))
end

-- Eye height on the main street's pavement at the street's built end (its +X end), looking back at
-- the square: the fronts, the verges and whatever stands over the road.
local function streetView(camera, town)
	camera.FieldOfView = 70
	local c = town.center
	local eye = c + Vector3.new(math.max(30, town.reach - 6), 5.5, 11)
	camera.CFrame = CFrame.lookAt(eye, c + Vector3.new(0, 5, 0))
end

local views = {
	{
		name = "00_build",
		settle = 2,
		setup = function(_, camera)
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			local started = DateTime.now().UnixTimestampMillis
			local info = MapGenerator.Build(MAP_ID)
			local map = workspace:FindFirstChild("Map")
			note("built %s seed %d in %.2fs WALL, radius %d; hook ThemeParts=%s ThemeSeconds=%s", MAP_ID, SEED,
				(DateTime.now().UnixTimestampMillis - started) / 1000, info and info.radius or -1,
				tostring(map and map:GetAttribute("ThemeParts")), tostring(map and map:GetAttribute("ThemeSeconds")))
			collect(map)
			for index, town in ipairs(state.towns) do
				note("town %d = %s [%s] \"%s\": centre %s, spread %d, theme parts %d, theme ms %d", index, town.name, town.kind, town.tagline,
					tostring(town.center), town.spread, town.themeParts, town.themeMillis)
			end
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt(Vector3.new(0, 900, 1), Vector3.zero)
		end,
	},
}

for index = 1, MAX_TOWNS do
	for _, shot in ipairs({ "200", "street" }) do
		table.insert(views, {
			name = string.format("%02d_town_%s", index, shot),
			settle = 2,
			setup = function(_, camera)
				local town = state.towns[index]
				if not town then
					note("no town %d on %s", index, MAP_ID)
					camera.CFrame = CFrame.lookAt(Vector3.new(0, 900, 1), Vector3.zero)
					return
				end
				note("%02d %s: %s [%s]", index, shot == "200" and "from 200 studs" or "from the main street", town.name, town.kind)
				if shot == "200" then
					farView(camera, town)
				else
					streetView(camera, town)
				end
			end,
		})
	end
end

return views
