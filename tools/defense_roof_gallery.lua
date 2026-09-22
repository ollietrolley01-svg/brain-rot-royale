-- The Brainrot Fortress's roof hatch (#35, "the roof is inaccessible on the legendary barricade").
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/defense_roof_gallery.lua -OutDir <folder>
--
-- The fix is coded and has never been SEEN: the second-floor hatch went from 3.8 x 3.8 with a 2-stud
-- truss in its middle (0.9 studs of opening either side, which stopped every climb at the top) to
-- 5.8 x 3.8 with the truss against its +X edge, and the whole-floor neon "trim" slab that plugged the
-- opening to the eye became four rim strips outside the battlements. Raycast numbers are already
-- taken (3.8 studs of opening in front of the climbing face, headroom clear for 8); what nobody has
-- is a picture, so each view frames the hatch itself rather than the building.
--
-- A body-sized stand-in (2 x 5 x 1, the size of a standing character) is placed in the opening in the
-- last view: whether a player fits is the actual question, and a slab that fits answers it.

local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")
local DefenseService = require(modules:WaitForChild("DefenseService"))

local V = Vector3.new
local ORIGIN = V(0, 500, 0)
local views = {}

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, name, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Color = color or Color3.fromRGB(150, 148, 144)
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.Parent = folder
	return part
end

local function light(folder, position, brightness, range)
	local holder = block(folder, "Light", V(0.2, 0.2, 0.2), position, Color3.new(1, 1, 1))
	holder.Transparency = 1
	local point = Instance.new("PointLight")
	point.Brightness = brightness
	point.Range = range
	point.Shadows = false
	point.Parent = holder
end

-- The fort, built through DefenseService's own builder so this is the thing players get, standing on
-- a plate. It rises out of the ground over RISE_TIME, so every view waits for it first.
local function fortress(folder)
	block(folder, "Ground", V(80, 2, 80), ORIGIN - V(0, 1, 0), Color3.fromRGB(128, 126, 120))
	local model = DefenseService.Build("BrainrotFortress", CFrame.new(ORIGIN), nil)
	model.Parent = folder
	task.wait(1.2)
	local truss = model:FindFirstChildWhichIsA("TrussPart")
	note(string.format("fortress built: %d parts, truss at x %+.1f",
		#model:GetDescendants(), truss and (truss.Position.X - ORIGIN.X) or 0))
	return model, truss
end

local function add(name, settle, setup)
	table.insert(views, { name = name, settle = settle or 1.4, hold = 2, setup = setup })
end

-- 1. Down into the hatch from just above the roof: the opening and the truss inside it, filling the
-- frame. Not the building -- a fort from twenty studs settles nothing.
add("fortress_hatch_from_above", 1.8, function(folder, camera)
	local _, truss = fortress(folder)
	local hatch = ORIGIN + V(0, 8.3, 0)
	light(folder, hatch + V(0, 6, 0), 2, 30)
	note("hatch_from_above: looking down at the second floor's opening" .. (truss and "" or " (no truss found)"))
	camera.FieldOfView = 55
	camera.CFrame = CFrame.lookAt(hatch + V(-3.5, 9, -5), hatch)
end)

-- 2. From inside at head height, under the hatch: what a player climbing the truss sees, and whether
-- there is anywhere to come out. The old neon slab filled this frame solid yellow.
add("fortress_hatch_from_inside", 1.8, function(folder, camera)
	local _, truss = fortress(folder)
	local eye = ORIGIN + V(-4.5, 5.2, 3.5)
	light(folder, ORIGIN + V(0, 6, 0), 1.6, 26)
	note("hatch_from_inside: head height on the ground floor, looking up the truss" .. (truss and "" or " (no truss found)"))
	camera.FieldOfView = 70
	camera.CFrame = CFrame.lookAt(eye, ORIGIN + V(0.4, 8.6, 0))
end)

-- 3. Does a body fit? A 2 x 5 x 1 slab -- a standing character -- stood in the opening beside the
-- truss, seen from the side at hatch height.
add("fortress_hatch_body_fits", 1.8, function(folder, camera)
	local _, truss = fortress(folder)
	local trussX = truss and (truss.Position.X - ORIGIN.X) or 1.9
	-- The climbing face is the truss's -X side; the body stands in the clear half of the opening.
	local stand = ORIGIN + V(trussX - 2.6, 8.3 + 2.5 - 0.3, 0)
	block(folder, "BodyStandIn", V(2, 5, 1), stand, Color3.fromRGB(70, 130, 200), Enum.Material.SmoothPlastic)
	light(folder, stand + V(-4, 4, -4), 2, 26)
	note(string.format("hatch_body_fits: a 2 x 5 x 1 stand-in at x %+.1f, truss at x %+.1f", stand.X - ORIGIN.X, trussX))
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(ORIGIN + V(trussX - 1, 9.6, -9), ORIGIN + V(trussX - 1.3, 9.4, 0))
end)

return views
