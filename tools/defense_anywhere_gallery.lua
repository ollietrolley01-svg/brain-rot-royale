-- #128 "place defenses anywhere": what the footings LOOK like, for Oliver's machine.
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/defense_anywhere_gallery.lua -OutDir <folder>
--
-- tools/defense_anywhere_check.py proves the numbers offline (nothing floats, nothing is buried past
-- its footing, the ghost is the build, the protected places refuse). What no number says is whether a
-- bunker on posts down a hillside reads as a bunker on posts, or as a bug. Each view builds one site
-- out of parts, deploys through the real DefenseService.Deploy (the placement plan and all), and frames
-- the result from the downhill side, where the posts are.
--
-- The ground here is PARTS: a runtest probe cannot make terrain (COORDINATION, #128 B: Terrain:FillBlock
-- does nothing, silently). So every slope is a rotated slab, which DefensePlacement treats exactly as
-- it treats terrain (it samples columns with rays either way). The water view TRIES FillBlock and says
-- in its note whether any water came of it; if none did, that view is a plain floor and says so.
--
-- Every view notes the plan: the level it stood at, the barricade's tilt, how far it slid off a wall,
-- and how many footing parts it stands on -- so a frame that looks wrong can be matched to its numbers.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = ServerScriptService:WaitForChild("Modules")
local DefenseService = require(modules:WaitForChild("DefenseService"))
local DefensePlacement = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("DefensePlacement"))

local V = Vector3.new
-- Far from the lobby (500 up at the origin) and from any map.
local ORIGIN = V(4000, 200, 4000)
local NORTH = V(0, 0, -1)
local EAST = V(1, 0, 0)
local views = {}
-- A stand-in owner: Deploy keys its cap by owner, and a table is what a bot passes.
local OWNER = { Name = "Gallery" }

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, name, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Color = color or Color3.fromRGB(120, 150, 96)
	part.Material = material or Enum.Material.Grass
	part.Anchored = true
	part.Parent = folder
	return part
end

local function light(folder, position)
	local holder = block(folder, "Light", V(0.2, 0.2, 0.2), position, Color3.new(1, 1, 1))
	holder.Transparency = 1
	holder.CanCollide = false
	local point = Instance.new("PointLight")
	point.Brightness = 1.4
	point.Range = 60
	point.Shadows = false
	point.Parent = holder
end

-- A slope through ORIGIN rising toward `uphill` at `angle` degrees: one thick rotated slab, so its top
-- is a clean plane.
local function slope(folder, angle, uphill)
	local axis = uphill:Cross(V(0, 1, 0))
	local frame = CFrame.new(ORIGIN) * CFrame.fromAxisAngle(axis, math.rad(angle))
	block(folder, "Slope", V(160, 6, 160), frame * CFrame.new(0, -3, 0))
end

-- Deploys at the surface under `at` and reports the plan.
local function deploy(folder, label, itemId, at, facing)
	local hit = workspace:Raycast(at + V(0, 60, 0), V(0, -120, 0))
	local landing = hit and hit.Position or at
	local centre = landing + V(0, DefensePlacement.LandLift, 0)
	local _, reason, plan = DefenseService.CheckSite(nil, itemId, centre, facing)
	local model, why = DefenseService.Deploy(OWNER, nil, itemId, centre, facing)
	if model then
		model.Parent = folder
		local counts = {}
		for _, footing in ipairs(plan and plan.footings or {}) do
			counts[footing.kind] = (counts[footing.kind] or 0) + 1
		end
		local parts = {}
		for kind, count in pairs(counts) do
			table.insert(parts, string.format("%d %s", count, kind))
		end
		note(string.format("%s: %s built, level %+.2f from the landing, tilt %.1f deg, slid %.1f, footings: %s", label, itemId,
			(plan and plan.level or 0) - landing.Y, math.deg(plan and plan.roll or 0), plan and plan.slid.Magnitude or 0,
			#parts > 0 and table.concat(parts, ", ") or "none"))
	else
		note(string.format("%s: %s REFUSED -- %s", label, itemId, tostring(why or reason)))
	end
	task.wait(1)
	return model, landing
end

local function add(name, setup)
	table.insert(views, { name = name, settle = 1.6, hold = 2, setup = setup })
end

-- Views are framed from the downhill side, a little above the deck, so the posts are in shot.
local function frame(camera, target, from, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, target)
end

for _, case in ipairs({
	{ "slope30_bunker", "PopupBunker", 30 },
	{ "slope45_barricade_tilts", "RotBarricade", 45 },
	{ "slope60_fortress", "BrainrotFortress", 60 },
	{ "slope15_fortress", "BrainrotFortress", 15 },
}) do
	add(case[1], function(folder, camera)
		-- Rising to the east, so the downhill (post) side is west.
		slope(folder, case[3], EAST)
		DefenseService.Clear()
		local _, landing = deploy(folder, case[1], case[2], ORIGIN, NORTH)
		light(folder, landing + V(-10, 12, 0))
		frame(camera, landing + V(0, 4, 0), landing + V(-30, 10, 22), 60)
	end)
end

add("roof_ledge_bunker", function(folder, camera)
	block(folder, "Street", V(120, 2, 120), ORIGIN - V(0, 1, 0), Color3.fromRGB(90, 90, 96), Enum.Material.Asphalt)
	block(folder, "House", V(30, 12, 30), ORIGIN + V(0, 6, 0), Color3.fromRGB(196, 170, 140), Enum.Material.Brick)
	DefenseService.Clear()
	-- Three studs in from the roof's east edge: most of the bunker hangs over the street on posts.
	local _, landing = deploy(folder, "roof_ledge", "PopupBunker", ORIGIN + V(12, 12, 0), NORTH)
	light(folder, landing + V(10, 8, 0))
	frame(camera, landing + V(4, -3, 0), landing + V(34, 2, 24), 60)
end)

add("sloped_roof_fortress", function(folder, camera)
	block(folder, "Ground", V(160, 2, 160), ORIGIN - V(0, 1, 0))
	block(folder, "RoofSlab", V(60, 2, 60), CFrame.new(ORIGIN + V(0, 18, 0)) * CFrame.Angles(0, 0, math.rad(25)),
		Color3.fromRGB(150, 70, 60), Enum.Material.Slate)
	DefenseService.Clear()
	local _, landing = deploy(folder, "sloped_roof", "BrainrotFortress", ORIGIN + V(0, 30, 0), NORTH)
	light(folder, landing + V(-12, 10, 0))
	frame(camera, landing + V(0, 2, 0), landing + V(-40, 6, 30), 60)
end)

add("rubble_bunker_sits_over", function(folder, camera)
	block(folder, "Ground", V(120, 2, 120), ORIGIN - V(0, 1, 0))
	for index, spot in ipairs({ { 2, 1 }, { -3, 0.4 }, { 4.5, -3 }, { -1, -4 }, { 5, 5 }, { -6, 4 } }) do
		block(folder, "Rubble", V(1.4, 0.9 + index * 0.1, 1.1), CFrame.new(ORIGIN + V(spot[1], 0.45, spot[2])) * CFrame.Angles(0, index, 0),
			Color3.fromRGB(128, 124, 118), Enum.Material.Concrete)
	end
	DefenseService.Clear()
	local _, landing = deploy(folder, "rubble", "PopupBunker", ORIGIN, NORTH)
	light(folder, landing + V(0, 10, 12))
	frame(camera, landing + V(0, 1, 0), landing + V(-18, 3, 18), 60)
end)

add("against_wall_fortress_slides", function(folder, camera)
	block(folder, "Ground", V(160, 2, 160), ORIGIN - V(0, 1, 0))
	block(folder, "Warehouse", V(60, 14, 30), ORIGIN + V(0, 7, -16.5), Color3.fromRGB(170, 176, 186), Enum.Material.Metal)
	DefenseService.Clear()
	-- Thrown flat against the warehouse's south wall: it comes off the wall to the nearest free spot.
	local _, landing = deploy(folder, "against_wall", "BrainrotFortress", ORIGIN + V(0, 0, -1), NORTH)
	light(folder, landing + V(0, 12, 14))
	frame(camera, landing + V(0, 4, 4), landing + V(-36, 22, 40), 60)
end)

add("doorway_barricade_clear", function(folder, camera)
	block(folder, "Ground", V(120, 2, 120), ORIGIN - V(0, 1, 0))
	local x0 = ORIGIN.X + 0.5
	block(folder, "Wall", V(1, 10, 13), V(x0 + 0.5, ORIGIN.Y + 5, ORIGIN.Z - 8.5), Color3.fromRGB(196, 170, 140), Enum.Material.Brick)
	block(folder, "Wall", V(1, 10, 13), V(x0 + 0.5, ORIGIN.Y + 5, ORIGIN.Z + 8.5), Color3.fromRGB(196, 170, 140), Enum.Material.Brick)
	block(folder, "Lintel", V(1, 3, 4), V(x0 + 0.5, ORIGIN.Y + 8.5, ORIGIN.Z), Color3.fromRGB(196, 170, 140), Enum.Material.Brick)
	DefenseService.Clear()
	-- Straight into the doorway: it must stand a body's width clear of it, not across it.
	local _, landing = deploy(folder, "doorway", "RotBarricade", ORIGIN + V(0.5, 0, 0), EAST)
	light(folder, landing + V(-6, 8, 0))
	frame(camera, V(x0, ORIGIN.Y + 3, ORIGIN.Z), V(x0 - 16, ORIGIN.Y + 9, ORIGIN.Z + 14), 60)
end)

add("cliff_ledge_fortress", function(folder, camera)
	block(folder, "Valley", V(160, 2, 160), ORIGIN - V(0, 1, 0))
	block(folder, "Cliff", V(60, 20, 80), ORIGIN + V(-25, 10, 0), Color3.fromRGB(130, 120, 104), Enum.Material.Rock)
	DefenseService.Clear()
	-- Five studs in from the edge of a 20-stud cliff.
	local _, landing = deploy(folder, "cliff_ledge", "BrainrotFortress", ORIGIN + V(0, 20, 0), NORTH)
	light(folder, landing + V(12, -6, 0))
	frame(camera, landing + V(4, -8, 0), landing + V(40, -4, 30), 60)
end)

add("shallow_water_bunker", function(folder, camera)
	block(folder, "Bed", V(120, 2, 120), ORIGIN - V(0, 4, 0), Color3.fromRGB(150, 140, 110), Enum.Material.Sand)
	local ok = pcall(function()
		workspace.Terrain:FillBlock(CFrame.new(ORIGIN - V(0, 1.5, 0)), V(100, 3, 100), Enum.Material.Water)
	end)
	local probe = workspace:Raycast(ORIGIN + V(0, 10, 0), V(0, -20, 0))
	local water = probe and probe.Material == Enum.Material.Water
	note(string.format("shallow_water: FillBlock %s; water %s -- %s", ok and "ran" or "errored", water and "PRESENT" or "ABSENT",
		water and "the bunker should stand on posts to the bed with floats at the waterline"
			or "no terrain water in this harness, so this is a bunker on a sand floor 3 below the landing"))
	DefenseService.Clear()
	local _, landing = deploy(folder, "shallow_water", "PopupBunker", ORIGIN, NORTH)
	light(folder, landing + V(-8, 8, 8))
	frame(camera, landing + V(0, 0, 0), landing + V(-22, 4, 20), 60)
end)

return views
