-- The rounds the gun rework's three new guns fire, as they look in flight: a mosquito dart, a drumlet and
-- a banana boomerang. Registered into ThrowableModels.RoundBuilders (its contract: `b` is its part builder,
-- sizes in studs, the nose along -Z, the design origin at the round's centre; return the body part), so
-- ProjectileClient, the gallery and the probe draw them like any other kind. The kinds themselves (how they
-- fly) are in Ballistics; each also carries a plain `look` there, which is what is drawn if this module
-- has not been loaded.
--
-- Loaded by GunModelsSignature, which every client loads with GunModels long before a round is in the air.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))

local GunModelsRounds = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local SMOOTH = Enum.Material.SmoothPlastic
local NEON = Enum.Material.Neon
local METAL = Enum.Material.Metal
local GLASS = Enum.Material.Glass

-- Points along a quadratic curve from p0 to p2, pulled toward p1.
local function curve(p0, p1, p2, count)
	local points = {}
	for index = 0, count do
		local t = index / count
		table.insert(points, p0 * ((1 - t) * (1 - t)) + p1 * (2 * (1 - t) * t) + p2 * (t * t))
	end
	return points
end

-- A dart with a mosquito's markings: a dark body banded white, the needle out front, two glassy wings
-- swept back and a red drop at the tail (it has already bitten someone today).
function GunModelsRounds.Dart(b)
	local DARK, WHITE, RED = rgb(38, 38, 44), rgb(240, 240, 236), rgb(200, 30, 40)
	local body = b.rod("Body", 0.3, 0.08, CF(0, 0, 0.04), DARK, SMOOTH)
	b.ball("Head", 0.1, V(0, 0, -0.11), DARK, SMOOTH)
	b.rod("Needle", 0.22, 0.022, CF(0, 0, -0.26), rgb(90, 90, 96), METAL)
	for _, z in ipairs({ 0.02, 0.1 }) do
		b.rod("Stripe", 0.03, 0.086, CF(0, 0, z), WHITE, SMOOTH)
	end
	b.ball("Blood", 0.1, V(0, 0, 0.2), RED, NEON)
	for _, side in ipairs({ -1, 1 }) do
		b.piece("Wing", V(0.2, 0.012, 0.09), CF(side * 0.1, 0.03, 0.03) * ANG(0, side * 0.5, side * 0.2), rgb(200, 220, 240), GLASS, nil, 0.45)
	end
	return body
end

-- A little marching drum with a lit fuse: a red shell, white heads, brass hoops, the white cord zig-zagging
-- between them, and the fuse spitting sparks from the top.
function GunModelsRounds.Drumlet(b)
	local RED, WHITE, BRASS = rgb(200, 40, 50), rgb(246, 242, 232), rgb(214, 172, 80)
	local height, diameter = 0.26, 0.36
	local body = b.column("Shell", height, diameter, V(0, 0, 0), RED, SMOOTH)
	for _, sy in ipairs({ -1, 1 }) do
		b.column("Head", 0.03, diameter - 0.06, V(0, sy * (height / 2 + 0.01), 0), WHITE, SMOOTH)
		b.ring("Hoop", CF(0, sy * (height / 2 - 0.01), 0) * ANG(math.pi / 2, 0, 0), diameter / 2 + 0.01, 0.035, 12, BRASS, METAL)
	end
	-- The cord: up and down between the hoops, six times round.
	local r = diameter / 2 + 0.02
	for index = 0, 5 do
		local a0, a1 = index / 6 * math.pi * 2, (index + 0.5) / 6 * math.pi * 2
		local low = V(math.cos(a0) * r, -height / 2 + 0.02, math.sin(a0) * r)
		local high = V(math.cos(a1) * r, height / 2 - 0.02, math.sin(a1) * r)
		local nextLow = V(math.cos(a1 + math.pi / 6) * r, -height / 2 + 0.02, math.sin(a1 + math.pi / 6) * r)
		b.link("Cord", low, high, 0.02, WHITE, SMOOTH)
		b.link("Cord", high, nextLow, 0.02, WHITE, SMOOTH)
	end
	b.rod("Fuse", 0.1, 0.025, CFrame.lookAt(V(0.05, height / 2 + 0.06, 0), V(0.08, height / 2 + 0.12, 0)), rgb(110, 80, 50), SMOOTH)
	b.ball("Glow", 0.05, V(0.08, height / 2 + 0.11, 0), rgb(255, 170, 60), NEON)
	return body
end

-- A banana boomerang: two curved banana arms meeting at the elbow, brown tips, a stalk at the elbow, and a
-- yellow ribbon behind it in the air. Flat in the XZ plane (it spins level, "flat").
function GunModelsRounds.Bananerang(b)
	local YELLOW, RIPE, BROWN = rgb(250, 214, 60), rgb(236, 190, 40), rgb(96, 66, 36)
	local thick = 0.08
	local elbow = V(0, 0, -0.26)
	local body = b.column("Elbow", thick, 0.2, elbow, YELLOW, SMOOTH)
	for _, side in ipairs({ -1, 1 }) do
		local points = curve(elbow, V(side * 0.22, 0, -0.2), V(side * 0.46, 0, 0.18), 5)
		for index = 1, #points - 1 do
			local a, c = points[index], points[index + 1]
			local t = index / (#points - 1)
			local width = 0.19 - 0.08 * t
			b.piece("Arm", V(width, thick, (c - a).Magnitude), CFrame.lookAt((a + c) / 2, c), index % 2 == 0 and RIPE or YELLOW, SMOOTH)
			b.column("Joint", thick, width, c, index % 2 == 0 and RIPE or YELLOW, SMOOTH)
		end
		b.ball("Tip", 0.1, points[#points] + V(side * 0.02, 0, 0.03), BROWN, SMOOTH)
		-- Two ripe freckles on the top of each arm.
		for _, index in ipairs({ 2, 4 }) do
			b.ball("Freckle", 0.04, points[index] + V(0, thick / 2, 0), BROWN, SMOOTH)
		end
	end
	b.rod("Stalk", 0.1, 0.06, CF(0, 0, -0.39), rgb(120, 140, 60), SMOOTH)
	b.ball("StalkEnd", 0.07, V(0, 0, -0.44), BROWN, SMOOTH)
	-- A ribbon behind it in the air. Built only where trails exist (not in the offline mocks).
	pcall(function()
		local top, bottom = Instance.new("Attachment"), Instance.new("Attachment")
		top.Position, bottom.Position = V(0, 0.06, 0), V(0, -0.06, 0)
		top.Parent, bottom.Parent = body, body
		local trail = Instance.new("Trail")
		trail.Attachment0, trail.Attachment1 = top, bottom
		trail.Lifetime = 0.3
		trail.Color = ColorSequence.new(YELLOW)
		trail.Transparency = NumberSequence.new(0.35, 1)
		trail.LightEmission = 0.4
		trail.FaceCamera = true
		trail.Parent = body
	end)
	return body
end

ThrowableModels.RoundBuilders.mosquitoDart = GunModelsRounds.Dart
ThrowableModels.RoundBuilders.drumlet = GunModelsRounds.Drumlet
ThrowableModels.RoundBuilders.bananerang = GunModelsRounds.Bananerang

return GunModelsRounds
