-- Sniper round gallery (task 17), for tools/gallery.ps1 (or Jacob's tools/linux/studio.py gallery):
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/sniper_round_gallery.lua -OutDir <folder>
--
-- A sniper's bullet in flight, drawn with the model clients draw (ThrowableModels.Round "sniperRound") at
-- positions from the real flight maths (Ballistics.RoundState at the live gravity):
--   sniper_round_leaving   the round 0.02 s out of a shooter's head (18 studs), over the shooter's shoulder
--   sniper_round_arriving  the round at each server step (1/60 s, 15 studs apart) over its last 0.1 s to a
--                          target 300 studs away, aimed at the head: where it is frame by frame as it lands
-- Built high above the map on a plain plate, with block figures for scale (1 stud = the head's 1.2).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))
require(Shared:WaitForChild("WeaponData"))

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local V = Vector3.new
local HIGH = V(0, 1400, 3400)
local SPEC = Ballistics.Rounds.sniperRound
local GRAVITY = workspace.Gravity

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = setup })
end

local function block(parent, name, size, cframe, color)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Anchored = true
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = parent
	return part
end

-- A block figure standing with its feet at `feet`: legs, torso, head (head centre 4.6 above the feet).
local function figure(parent, feet, color)
	block(parent, "Legs", V(1.8, 2, 1), CFrame.new(feet + V(0, 1, 0)), Color3.fromRGB(60, 60, 70))
	block(parent, "Torso", V(2, 1.8, 1), CFrame.new(feet + V(0, 2.9, 0)), color)
	return block(parent, "Head", V(1.2, 1.2, 1.2), CFrame.new(feet + V(0, 4.6, 0)), Color3.fromRGB(240, 200, 160))
end

local function stage(folder, from, to)
	local mid = (from + to) / 2
	block(folder, "Plate", V(40, 1, math.abs(to.Z - from.Z) + 60), CFrame.new(mid.X, from.Y - 0.5, mid.Z), Color3.fromRGB(110, 130, 110))
end

local function round(folder, origin, direction, t)
	local position, velocity = Ballistics.RoundState(SPEC, origin, direction, GRAVITY, t)
	local model = ThrowableModels.Round("sniperRound", 1)
	model:PivotTo(Ballistics.RoundOrientation("none", position, velocity, 0))
	model.Parent = folder
	return position
end

add("sniper_round_leaving", function(folder, camera)
	local feet = HIGH
	local target = feet + V(0, 0, -300)
	stage(folder, feet, target)
	local head = figure(folder, feet, Color3.fromRGB(90, 120, 200))
	figure(folder, target, Color3.fromRGB(200, 80, 80))
	local origin = head.Position
	local direction = ((target + V(0, 4.6, 0)) - origin).Unit
	local at = round(folder, origin, direction, 0.02)
	note(string.format("round at %.3f s: %.1f studs out, %.3f below the line", 0.02, (at - origin).Magnitude, (origin + direction * (SPEC.speed * 0.02) - at).Y))
	camera.FieldOfView = 35
	camera.CFrame = CFrame.lookAt(origin + V(2.5, 1.2, 5), at)
end)

add("sniper_round_arriving", function(folder, camera)
	local feet = HIGH + V(200, 0, 0)
	local target = feet + V(0, 0, -300)
	stage(folder, feet, target)
	local head = figure(folder, feet, Color3.fromRGB(90, 120, 200))
	local targetHead = figure(folder, target, Color3.fromRGB(200, 80, 80))
	local origin = head.Position
	local direction = (targetHead.Position - origin).Unit
	local flight = Ballistics.RoundTimeFor(SPEC, 300)
	local parts = {}
	for i = 6, 1, -1 do
		local t = flight - i / 60
		local at = round(folder, origin, direction, t)
		table.insert(parts, string.format("t %.3f z %.1f drop %.2f", t, at.Z - origin.Z, (origin + direction * (SPEC.speed * t) - at).Y))
	end
	note("arriving (one per 1/60 s server step): " .. table.concat(parts, " | "))
	note(string.format("flight to 300 studs %.3f s; drop there %.2f studs (head is 1.2 tall)", flight, 0.5 * GRAVITY * SPEC.gravityScale * flight * flight))
	camera.FieldOfView = 70
	local look = targetHead.Position + V(0, -1, 14)
	camera.CFrame = CFrame.lookAt(look + V(16, 3, 4), look)
end)

return views
