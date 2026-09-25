-- Every explosion beside the grenade, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/silly_explosion_gallery.lua -OutDir <folder> -TimeoutSeconds 1500
--
-- One row per blast, the same three moments in each (0.10 s: flash and shock; 0.35 s: the cluster
-- and the pieces in flight; 0.90 s: smoke and what is left), the camera framed the same way against
-- each blast's radius, so a contact sheet with three columns compares them honestly. Row 1 is the
-- reference: the Cooked Coconut, the grenade. Then the silly ones (SillyExplosionFx) and the
-- realistic ones that used to be weaker (mines, barrels, a mounted gun and a vehicle breaking; they
-- are drawn here exactly as ProjectileClient draws the server's "detonate" for them). Last, a
-- crowd of six silly blasts at once and a check that every piece is gone after 3 s.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
require(Shared:WaitForChild("WeaponData"))
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

-- A plate, a wall behind and a figure beside the blast (2 studs wide, 5 tall) for scale.
local function stage(folder, centre, radius)
	block(folder, "Ground", V(160, 2, 160), centre - V(0, 1, 0), Color3.fromRGB(118, 150, 96), Enum.Material.Grass)
	block(folder, "Wall", V(16, 7, 1), centre + V(0, 3.5, -radius * 1.4 - 3), Color3.fromRGB(170, 160, 140), Enum.Material.Brick)
	local x = math.max(4, radius * 0.7)
	block(folder, "Body", V(2, 3.2, 1), centre + V(x, 2.6, 2), Color3.fromRGB(80, 110, 160), Enum.Material.SmoothPlastic)
	block(folder, "Head", V(1.2, 1.2, 1.2), centre + V(x, 4.8, 2), Color3.fromRGB(230, 200, 170), Enum.Material.SmoothPlastic)
	block(folder, "Legs", V(2, 2, 1), centre + V(x, 1, 2), Color3.fromRGB(60, 60, 70), Enum.Material.SmoothPlastic)
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

local function fxParts()
	local count = 0
	for _, d in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if d:IsA("BasePart") and d.Name ~= "BRR_SillyHost" and d.Name ~= "BRR_BlastHost" then
			count += 1
		end
	end
	return count
end

-- { label, weaponId, look kind (as ProjectileClient maps it), server radius, hit-only }
local ROWS = {
	{ "grenade_ref", "CookedCoconut", "frag", 13 },
	{ "party", "TamburoTungTung", "frag", 7 },
	{ "gold", "GoldenSahurCannon", "frag", 5 },
	{ "coffee", "CappuccinaLauncher", "rocket", 14 },
	{ "toast", "ToasterMortar", "frag", 10 },
	{ "impact_ref", "ZanzarinoPikpik", "impact", 4, true },
	{ "slipper", "GrandmasSlipperLauncher", "impact", 4, true },
	{ "fidget", "FidgetDiscLauncher", "impact", 4, true },
	{ "rocket", "VehicleRocket", "rocket", 12 },
	{ "mine", "RotMine", "grenade", 10 },
	{ "barrel", "ExplosiveBarrel", "grenade", 15 },
	{ "mounted_wreck", "MountedGunWreck", "grenade", 8 },
	{ "vehicle_wreck_proposed", "VehicleWreck", "rocket", 12 },
}
local AGES = { 0.1, 0.35, 0.9 }

for index, row in ipairs(ROWS) do
	local label, weaponId, kind, radius, hit = row[1], row[2], row[3], row[4], row[5]
	for column, age in ipairs(AGES) do
		add(string.format("r%02d_%s_c%d_t%03d", index, label, column, math.floor(age * 100)), function(folder, camera)
			ExplosiveFx.Clear()
			Silly.ForceLod = "full"
			local centre = HIGH + V(200, 0, 0)
			local scale = hit and 4 or math.max(radius, 6)
			stage(folder, centre, scale)
			-- The camera first (the level of detail is measured from it), the same framing per radius.
			camera.FieldOfView = 60
			camera.CFrame = CFrame.lookAt(centre + V(scale * 1.25, scale * 0.95, scale * 2.3), centre + V(0, scale * 0.35, 0))
			if hit then
				ExplosiveFx.Impact(centre + V(0, 1, 0), Vector3.yAxis, weaponId)
			else
				ExplosiveFx.Explosion(centre + V(0, 0.2, 0), Vector3.yAxis, kind, radius, weaponId)
			end
			advanceTo(age)
			local live, debris = ExplosiveFx.Count()
			note(string.format("%s (%s, %s r%d) at %.2fs: %d live, %d debris, %d fx parts", label, weaponId, kind, radius, age, live, debris, fxParts()))
			Silly.ForceLod = nil
		end)
	end
end

-- A crowd: eight silly blasts at once. Past MAX_BLASTS the rest are drawn FAR (no pieces).
add("z1_crowd_of_8", function(folder, camera)
	ExplosiveFx.Clear()
	local centre = HIGH + V(200, 0, 0)
	stage(folder, centre, 12)
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(centre + V(0, 26, 52), centre)
	local ids = { "CappuccinaLauncher", "GoldenSahurCannon", "TamburoTungTung", "ToasterMortar" }
	for index = 1, 8 do
		local id = ids[(index - 1) % #ids + 1]
		ExplosiveFx.Explosion(centre + V((index - 4.5) * 8, 0.2, (index % 2) * 8 - 4), Vector3.yAxis, "frag", 7, id)
	end
	advanceTo(0.35)
	note(string.format("crowd of 8: %d fx parts, %d silly active (MAX_BLASTS %d)", fxParts(), Silly.Active, Silly.MAX_BLASTS))
end)

add("z2_cleanup_after_3s", function(folder, camera)
	ExplosiveFx.Clear()
	local centre = HIGH + V(200, 0, 0)
	stage(folder, centre, 12)
	camera.FieldOfView = 60
	camera.CFrame = CFrame.lookAt(centre + V(18, 14, 30), centre)
	for index, id in ipairs({ "CappuccinaLauncher", "GoldenSahurCannon", "TamburoTungTung", "ToasterMortar", "GrandmasSlipperLauncher", "FidgetDiscLauncher" }) do
		ExplosiveFx.Explosion(centre + V((index - 3.5) * 6, 0.2, 0), Vector3.yAxis, "frag", 7, id)
	end
	advanceTo(3)
	local left = 0
	for _, d in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if d:IsA("BasePart") and d.Name ~= "BRR_SillyHost" and d.Name ~= "BRR_BlastHost" and d.Name ~= "SmokeColumn" then
			left += 1
		end
	end
	note(string.format("cleanup: %d silly pieces left after 3 s (want 0), %d silly active", left, Silly.Active))
end)

return views
