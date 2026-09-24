-- Floating foundations, before and after (Oliver, 2026-09-24: "look for floating building foundations
-- and poor placement"). Builds one whole map with the monuments' and easter eggs' underpinning switched
-- OFF -- the code as it was -- finds the pieces that hang furthest over the ground, photographs each
-- one, then underpins that one structure exactly as MapTerrain.Underpin does in the game and photographs
-- it again from the same place. Underpinning takes no random rolls, so the map is the same map either
-- way: the only difference between a pair of shots is the fix.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/foundation_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- Edit MAP_ID / SEED below; one map per run. RotRidge and PatapimPlains have the steepest ground.
-- Also shown, after only (their before is a different map: those fixes move things): the plateau
-- zipline rim posts, which now stand on the rim's own ground. The numbers for everything else (door
-- paths, shelter openings, tents, set-piece entrances) are tools/foundation_check.py's.
--
-- Every view prints what an occlusion ray from the camera to its target hits first (COORDINATION: "IN
-- FRAME" IS NOT "VISIBLE"); a shot whose ray stops on something else is named in the notes.

local MAP_ID = "RotRidge"
local SEED = 101
local SITES = 6

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = { sites = {} }

local function look(camera, from, to, fov)
	camera.FieldOfView = fov or 50
	camera.CFrame = CFrame.lookAt(from, to)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local hit = workspace:Raycast(from, (to - from) * 1.02, params)
	return hit and hit.Instance:GetFullName() or "nothing"
end

-- Where to stand: out from the structure's middle past the piece, a little above its foot.
local function viewOf(site)
	local part = site.part
	local centre = site.centre
	local away = Vector3.new(part.Position.X - centre.X, 0, part.Position.Z - centre.Z)
	if away.Magnitude < 1 then
		away = Vector3.new(1, 0, 0)
	end
	away = away.Unit
	local foot = Vector3.new(part.Position.X, site.bottom, part.Position.Z)
	local distance = math.clamp(math.max(part.Size.X, part.Size.Z) * 1.4 + 14, 18, 60)
	return foot + away * distance + Vector3.new(0, 3 + site.drop * 0.4, 0), foot + Vector3.new(0, site.drop * 0.3, 0)
end

local views = {
	{
		name = "before_map_" .. MAP_ID,
		settle = 4,
		setup = function(_, camera)
			local MapTerrain = require(modules:WaitForChild("MapTerrain"))
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			-- The code as it was: nothing underpinned.
			local real = MapTerrain.Underpin
			MapTerrain.Underpin = function()
				return 0, {}
			end
			math.randomseed(SEED)
			local ok, info = pcall(MapGenerator.Build, MAP_ID)
			MapTerrain.Underpin = real
			if not ok then
				note("build failed: " .. tostring(info))
				return
			end
			state.info = info
			-- Every structure the fix covers, dry-run: what would be carried down, and how far.
			local candidates = {}
			for _, folderName in ipairs({ "Landmarks", "EasterEggs" }) do
				local folder = workspace.Map:FindFirstChild(folderName)
				for _, child in ipairs(folder and folder:GetChildren() or {}) do
					local models = { child }
					if child:GetAttribute("FootingGroup") then
						models = {}
						for _, foot in ipairs(child:GetChildren()) do
							if foot:IsA("Model") then
								table.insert(models, foot)
							end
						end
					end
					for _, model in ipairs(models) do
						local base = model:GetAttribute("FootingBase")
						if type(base) == "number" then
							local count, found = real(model, base, { dryRun = true })
							local centre = model:GetPivot().Position
							for _, entry in ipairs(found or {}) do
								local bottom = entry.part.Position.Y - entry.part.Size.Y / 2
								table.insert(candidates, { model = model, base = base, part = entry.part, drop = entry.drop,
									bottom = bottom, centre = centre, name = child.Name })
							end
							if count > 0 then
								note(string.format("%s: %d pieces hang (dry run)", model:GetFullName(), count))
							end
						end
					end
				end
			end
			table.sort(candidates, function(a, b)
				return a.drop > b.drop
			end)
			-- The worst piece of each structure, worst structures first.
			local seen = {}
			for _, site in ipairs(candidates) do
				if not seen[site.model] and #state.sites < SITES then
					seen[site.model] = true
					table.insert(state.sites, site)
				end
			end
			note(string.format("%s seed %d: %d hanging pieces before underpinning; photographing the worst %d",
				MAP_ID, SEED, #candidates, #state.sites))
			look(camera, Vector3.new(0, info.radius * 1.25, info.radius * 0.45), Vector3.new(0, 0, 0), 70)
		end,
	},
}

for index = 1, SITES do
	table.insert(views, {
		name = string.format("site%d_before", index),
		settle = 2,
		setup = function(_, camera)
			local site = state.sites[index]
			if not site then
				return
			end
			local from, to = viewOf(site)
			local first = look(camera, from, to)
			note(string.format("site %d BEFORE: %s, %s hangs %.2f over the ground at (%.0f, %.0f); ray hits %s",
				index, site.name, site.part.Name, site.drop, to.X, to.Z, first))
		end,
	})
	table.insert(views, {
		name = string.format("site%d_after", index),
		settle = 2,
		setup = function(_, camera)
			local site = state.sites[index]
			if not site then
				return
			end
			local MapTerrain = require(modules:WaitForChild("MapTerrain"))
			if not site.model:GetAttribute("GalleryUnderpinned") then
				local count = MapTerrain.Underpin(site.model, site.base)
				site.model:SetAttribute("GalleryUnderpinned", count)
				local again = MapTerrain.Underpin(site.model, site.base, { dryRun = true })
				note(string.format("site %d AFTER: %d pieces carried down; a second dry run finds %d", index, count, again))
			end
			local from, to = viewOf(site)
			local first = look(camera, from, to)
			note(string.format("site %d AFTER: ray hits %s", index, first))
		end,
	})
end

-- The plateaus' zipline rim posts (after only).
for index = 1, 3 do
	table.insert(views, {
		name = "rimpost_" .. index,
		settle = 2,
		setup = function(_, camera)
			local folder = workspace.Map:FindFirstChild("Ziplines")
			local posts = {}
			for _, part in ipairs(folder and folder:GetChildren() or {}) do
				if part:IsA("BasePart") then
					table.insert(posts, part)
				end
			end
			local post = posts[index]
			if not post then
				return
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = { workspace.Terrain }
			local hit = workspace:Raycast(Vector3.new(post.Position.X, 2000, post.Position.Z), Vector3.new(0, -4000, 0), params)
			local bottom = post.Position.Y - post.Size.Y / 2
			local foot = Vector3.new(post.Position.X, bottom, post.Position.Z)
			local first = look(camera, foot + Vector3.new(9, 3, 9), foot + Vector3.new(0, 1, 0))
			note(string.format("rim post %d: foot %.2f, ground %.2f (gap %.2f); ray hits %s", index, bottom,
				hit and hit.Position.Y or -999, hit and (bottom - hit.Position.Y) or 999, first))
		end,
	})
end

return views
