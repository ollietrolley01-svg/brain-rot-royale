-- The silly explosions, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/silly_explosion_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- Each silly weapon's blast (SillyExplosionFx) detonated in turn on a plain plate with a figure for
-- scale, the camera framed on it, frozen at two ages: the burst (danger marks up, the word popping)
-- and the pieces flying. Then one at the FAR level of detail, and the realistic Tralala Thumper blast
-- beside them, so the silly ones can be seen to read as a blast of the same size.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local ExplosiveFx = require(scripts:WaitForChild("ExplosiveFx"))
local Silly = require(scripts:WaitForChild("SillyExplosionFx"))

ExplosiveFx.Paused = true
ExplosiveFx.TrustNormal = true

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local HIGH = Vector3.new(0, 1400, -3400)
local V = Vector3.new

local views = {}
local function add(name, setup, hold)
	table.insert(views, { name = name, settle = 1.2, hold = hold or 2, setup = setup })
end

local function block(parent, name, size, cframe, color, material)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Color = color or Color3.fromRGB(150, 148, 144)
	part.Material = material or Enum.Material.Concrete
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function stage(folder, centre)
	block(folder, "Ground", V(120, 2, 120), centre - V(0, 1, 0), Color3.fromRGB(118, 150, 96), Enum.Material.Grass)
	block(folder, "Wall", V(14, 6, 1), centre + V(0, 3, -16), Color3.fromRGB(170, 160, 140), Enum.Material.Brick)
	block(folder, "Body", V(2, 3.2, 1), centre + V(8, 2.6, 4), Color3.fromRGB(80, 110, 160), Enum.Material.SmoothPlastic)
	block(folder, "Head", V(1.2, 1.2, 1.2), centre + V(8, 4.8, 4), Color3.fromRGB(230, 200, 170), Enum.Material.SmoothPlastic)
	block(folder, "Legs", V(2, 2, 1), centre + V(8, 1, 4), Color3.fromRGB(60, 60, 70), Enum.Material.SmoothPlastic)
end

local function advanceTo(seconds)
	local step = 1 / 60
	local t = 0
	while t < seconds - 1e-6 do
		local dt = math.min(step, seconds - t)
		ExplosiveFx.Advance(dt)
		t += dt
	end
end

-- The radius the server uses for this weapon's blast (what the dome and ring must reach).
local function radiusOf(weaponId)
	local def = WeaponData.Weapons and WeaponData.Weapons[weaponId] or WeaponData[weaponId]
	if type(def) ~= "table" then
		return 4, true
	end
	if def.explosiveAmmo then
		return def.explosiveAmmo.radius, false
	end
	if def.splashRadius and def.ability == "explosive" then
		return def.splashRadius, false
	end
	return 4, true
end

local function blastView(weaponId, age, lod)
	local theme = Silly.ThemeFor(weaponId) or "realistic"
	add(string.format("silly_%s_%s_t%03d%s", theme, weaponId, math.floor(age * 100), lod and ("_" .. lod) or ""), function(folder, camera)
		ExplosiveFx.Clear()
		Silly.ForceLod = lod
		local centre = HIGH + V(200, 0, 0)
		stage(folder, centre)
		local radius, hit = radiusOf(weaponId)
		-- The camera first: the POW star faces it and the level of detail is measured from it.
		local back = hit and 13 or math.max(16, radius * 2.3)
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(centre + V(back * 0.55, back * 0.45, back * 0.95), centre + V(0, (hit and 1.5 or radius * 0.3), 0))
		local at = centre + V(0, hit and 1.2 or 0.2, 0)
		if hit then
			ExplosiveFx.Impact(at, Vector3.yAxis, weaponId)
		else
			ExplosiveFx.Explosion(at, Vector3.yAxis, weaponId == "TralalaThumper" and "grenade" or "rocket", radius, weaponId)
		end
		advanceTo(age)
		local live, debris = ExplosiveFx.Count()
		local parts = 0
		local effects = ExplosiveFx.Folder()
		for _, d in ipairs(effects:GetChildren()) do
			if d:IsA("BasePart") and d.Name ~= "BRR_SillyHost" and d.Name ~= "BRR_BlastHost" then
				parts += 1
			end
		end
		note(string.format("%s (%s) r%.0f at %.2fs lod=%s: %d live, %d debris, %d fx parts, %d silly active",
			weaponId, theme, radius, age, lod or "auto", live, debris, parts, Silly.Active))
		Silly.ForceLod = nil
	end)
end

for _, weaponId in ipairs({ "CappuccinaLauncher", "GoldenSahurCannon", "TamburoTungTung", "ToasterMortar", "GrandmasSlipperLauncher", "FidgetDiscLauncher" }) do
	blastView(weaponId, 0.12)
	blastView(weaponId, 0.5)
end
blastView("CappuccinaLauncher", 0.12, "far")
blastView("TralalaThumper", 0.12)

-- Cleanup: every silly part gone by 3 s.
add("silly_cleanup_after_3s", function(folder, camera)
	ExplosiveFx.Clear()
	local centre = HIGH + V(200, 0, 0)
	stage(folder, centre)
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(centre + V(18, 14, 30), centre)
	for index, weaponId in ipairs({ "CappuccinaLauncher", "GoldenSahurCannon", "TamburoTungTung", "ToasterMortar", "GrandmasSlipperLauncher", "FidgetDiscLauncher" }) do
		local radius = radiusOf(weaponId)
		ExplosiveFx.Explosion(centre + V((index - 3.5) * 6, 0.2, 0), Vector3.yAxis, "rocket", radius, weaponId)
	end
	advanceTo(3)
	local left = 0
	for _, d in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if d:IsA("BasePart") and d.Name ~= "BRR_SillyHost" and d.Name ~= "BRR_BlastHost" then
			left += 1
		end
	end
	note(string.format("cleanup: %d silly fx parts left after 3 s (want 0), %d silly active", left, Silly.Active))
end)

return views
