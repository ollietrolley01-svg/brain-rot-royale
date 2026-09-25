-- Roundabout gallery (Oliver 09-24: "make high quality roundabouts around the fountain at the center of the
-- towns"): builds whole maps and photographs one town's roundabout of each size (village, town, city) --
-- from high up, at eye level down each approach, with a car going round, and at dusk with the lamps on.
-- tools/roundabout_check.py scores the same roundabouts by rule; this is the picture.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/roundabout_gallery.lua -PlaceFile <copy.rbxlx> -OutDir <folder>
--
-- Town names (and so kinds, and so sizes) are dealt at random per build, so each run takes the first town
-- of each size it finds that hasn't been shot yet. Pick the maps by editing RUNS.

local RUNS = {
	{ map = "TralalaTown", seed = 7 },
	{ map = "SahurSprings", seed = 101 },
}
-- Which views to take (nil = all): above, eye_E/N/W/S, car, dusk, detail (close-ups of a manhole cover, a
-- gully grate). Which sizes (nil = all).
local ONLY = nil
local CLASSES = nil

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local ARMS = { { "E", 0 }, { "N", math.pi / 2 }, { "W", math.pi }, { "S", 3 * math.pi / 2 } }
local shot = {} -- class -> roundabout model
local order = { "small", "medium", "large" }

local function armPoint(c, theta, u, v, y)
	local cs, sn = math.cos(theta), math.sin(theta)
	return Vector3.new(c.X + cs * u - sn * v, y, c.Z + sn * u + cs * v)
end

local function spec(model)
	return {
		c = model:GetAttribute("Center"),
		island = model:GetAttribute("Island"),
		outer = model:GetAttribute("Outer"),
		approach = model:GetAttribute("Approach"),
		half = model:GetAttribute("StreetHalf"),
		circulate = model:GetAttribute("Circulate"),
	}
end

local views = {}
local function wanted(kind, class)
	return (not ONLY or ONLY[kind]) and (not CLASSES or CLASSES[class])
end

-- Close up, at eye level, on the first part of the roundabout called `name`.
local function detail(model, name, camera)
	local part = model:FindFirstChild(name, true)
	if not part then
		note("no %s to look at", name)
		return
	end
	local c = model:GetAttribute("Center")
	local out = Vector3.new(part.Position.X - c.X, 0, part.Position.Z - c.Z).Unit
	local side = Vector3.new(-out.Z, 0, out.X)
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(part.Position - side * 7 - out * 2 + Vector3.new(0, 3.2, 0), part.Position)
end

for runIndex, run in ipairs(RUNS) do
	table.insert(views, {
		name = string.format("%d%s_00_build", runIndex, run.map),
		settle = 2,
		setup = function(_, camera)
			Lighting.ClockTime = 13
			-- The legacy part outlines, off whatever the place file says (they drew cyan edges round everything).
			pcall(function()
				Lighting.Outlines = false
			end)
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(run.seed)
			local started = os.clock()
			local info = MapGenerator.Build(run.map)
			note("built %s seed %d in %.1fs", run.map, run.seed, os.clock() - started)
			for _, town in ipairs(workspace.Map:GetChildren()) do
				local r = town.Name == "Town" and town:FindFirstChild("Roundabout")
				if r then
					local class = r:GetAttribute("Class")
					note("town %s [%s] roundabout %s, %d parts", tostring(town:GetAttribute("TownName")), tostring(town:GetAttribute("TownKind")),
						tostring(class), #r:GetDescendants())
					if not shot[class] then
						shot[class] = { model = r, run = runIndex, name = town:GetAttribute("TownName") }
					end
				end
			end
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(0, (info and info.radius or 1000) * 1.2, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
		end,
	})
	for _, class in ipairs(order) do
		local function current()
			local entry = shot[class]
			if entry and entry.run == runIndex and entry.model.Parent then
				return entry
			end
			return nil
		end
		local tag = string.format("%d_%s", runIndex, class)
		local function add(kind, view)
			if wanted(kind, class) then
				table.insert(views, view)
			end
		end
		add("above", {
			name = tag .. "_above",
			settle = 2,
			setup = function(_, camera)
				local entry = current()
				if not entry then
					return
				end
				Lighting.ClockTime = 13
				local s = spec(entry.model)
				note("%s: %s", class, tostring(entry.name))
				-- A plan: straight down, north up the frame, the four approaches out to their crossings.
				camera.FieldOfView = 50
				camera.CFrame = CFrame.new(s.c + Vector3.new(0, s.approach * 2.6, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
			end,
		})
		for _, arm in ipairs(ARMS) do
			add("eye_" .. arm[1], {
				name = string.format("%s_eye_%s", tag, arm[1]),
				settle = 2,
				setup = function(_, camera)
					local entry = current()
					if not entry then
						return
					end
					Lighting.ClockTime = 14
					local s = spec(entry.model)
					camera.FieldOfView = 70
					camera.CFrame = CFrame.lookAt(armPoint(s.c, arm[2], s.approach + 26, -s.half / 2, 5.5), armPoint(s.c, arm[2], 0, 0, 3))
				end,
			})
		end
		add("car", {
			name = tag .. "_car",
			settle = 3,
			setup = function(folder, camera)
				local entry = current()
				if not entry then
					return
				end
				Lighting.ClockTime = 15
				local s = spec(entry.model)
				local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
				local ids = {}
				for id in pairs(VehicleModels.Models) do
					table.insert(ids, id)
				end
				table.sort(ids)
				local a = -0.35
				-- Going round anticlockwise from above (decreasing angle), on the circulating path.
				local at = Vector3.new(s.c.X + math.cos(a) * s.circulate, 0.4, s.c.Z + math.sin(a) * s.circulate)
				local heading = Vector3.new(math.sin(a), 0, -math.cos(a))
				local ok, car = pcall(VehicleModels.BuildStatic, ids[1], Random.new(3), CFrame.lookAt(at, at + heading))
				if ok and car then
					car.Parent = folder
				end
				camera.FieldOfView = 60
				camera.CFrame = CFrame.lookAt(at - heading * 22 + Vector3.new(0, 9, 0) + (at - s.c).Unit * 6, at)
			end,
		})
		for _, part in ipairs({ "Manhole", "Drain" }) do
			add("detail", {
				name = string.format("%s_detail_%s", tag, part),
				settle = 2,
				setup = function(_, camera)
					local entry = current()
					if entry then
						Lighting.ClockTime = 14
						detail(entry.model, part, camera)
					end
				end,
			})
		end
		add("dusk", {
			name = tag .. "_dusk",
			settle = 3,
			setup = function(folder, camera)
				local entry = current()
				if not entry then
					return
				end
				folder:ClearAllChildren()
				Lighting.ClockTime = 18.9
				local s = spec(entry.model)
				camera.FieldOfView = 65
				camera.CFrame = CFrame.lookAt(armPoint(s.c, math.pi / 4 + 0.35, s.outer + 18, 0, 17), s.c + Vector3.new(0, 2, 0))
			end,
		})
	end
end

return views
