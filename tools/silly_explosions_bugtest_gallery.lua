-- Finding C4b of reports/bugtest-silly-explosions.md, on camera, for tools/gallery.ps1 (the coordinator's
-- Studio; not run from here):
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/silly_explosions_bugtest_gallery.lua -OutDir <folder>
--
-- The same barrel blast (the server's cue: "grenade" look, radius 15, weaponId ExplosiveBarrel), framed
-- the same way, at 0.35 s and 0.9 s:
--   a_*  alone
--   b_*  0.1 s after three Zanzarino Pikpik darts landed 20 studs away (the pistol fires 4.2 a second;
--        each dart is ExplosiveFx.Impact, which ExplosiveFx counts as a live blast)
-- tools/silly_explosions_bugtest_check.py measures the difference (6 rock chunks and a smoke column
-- against none, 74 particles against 38); this shows whether a player would notice.

local StarterPlayer = game:GetService("StarterPlayer")

local ExplosiveFx = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("ExplosiveFx"))

ExplosiveFx.Paused = true

local V = Vector3.new
local HIGH = Vector3.new(0, 1400, -3400)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local views = {}
local function add(name, setup)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = setup })
end

local function block(parent, name, size, position, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = CFrame.new(position)
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.Parent = parent
	return part
end

local function advance(seconds)
	local t = 0
	while t < seconds - 1e-6 do
		local dt = math.min(1 / 60, seconds - t)
		ExplosiveFx.Advance(dt)
		t += dt
	end
end

for _, age in ipairs({ 0.35, 0.9 }) do
	for _, darts in ipairs({ 0, 3 }) do
		local name = string.format("%s_barrel_%s_t%03d", darts == 0 and "a" or "b", darts == 0 and "alone" or "after_3_darts", math.floor(age * 100))
		add(name, function(folder, camera)
			ExplosiveFx.Clear()
			local centre = HIGH + V(200, 0, 0)
			block(folder, "Ground", V(160, 2, 160), centre - V(0, 1, 0), Color3.fromRGB(118, 150, 96), Enum.Material.Grass)
			block(folder, "Figure", V(2, 5, 1), centre + V(10, 2.5, 2), Color3.fromRGB(80, 110, 160), Enum.Material.SmoothPlastic)
			camera.FieldOfView = 60
			camera.CFrame = CFrame.lookAt(centre + V(19, 14, 34), centre + V(0, 5, 0))
			for shot = 1, darts do
				ExplosiveFx.Impact(centre + V(-20, 1, shot * 2), Vector3.yAxis, "ZanzarinoPikpik")
				advance(1 / 4.2)
			end
			ExplosiveFx.Explosion(centre + V(0, 2.3, 0), Vector3.yAxis, "grenade", 15, "ExplosiveBarrel")
			advance(age)
			local live, debris = ExplosiveFx.Count()
			note(string.format("%s: %d live effects, %d debris chunks at %.2f s", name, live, debris, age))
		end)
	end
end

return views
