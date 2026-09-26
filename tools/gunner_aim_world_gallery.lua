-- The gunner's aim holds its world direction while the car turns under it (Jacob 09-25: "make the
-- gunner aim not turn with the car"). The real Rotster (VehicleModels.Build) and the real GunnerView,
-- stepped by hand (noInput, edit mode has no client): the gun is laid on a green pole 60 studs ahead,
-- then the car yaws about the turret's axis at 90 deg/s with no input, and GunnerView's turret is posed
-- as its joints would pose it. tools/gunner_aim_world_check.py is the measurement; this is the picture.
--
--   python3 tools/linux/studio.py gallery -Gallery tools/gunner_aim_world_gallery.lua -OutDir <folder>
--
-- Views: car_<N>        from a fixed camera above and behind, the car turned N degrees; a magenta beam
--                       runs 60 studs down the barrel as GunnerView's AimPoint gives it. Held, it ends on
--                       the green pole in every view while the car turns under it.
--        fp_<N>         the gunner's own view (GunnerView's camera) with the car turned N degrees: the
--                       pole stays in the middle of the sight.
-- Printed per view ("[BRR_Gallery] note ..."): the barrel's world bearing, how far it is off the laid
-- one, and the turret's own yaw (the angle it turned back against the car).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleWeaponData = require(Shared:WaitForChild("VehicleWeaponData"))
local GunnerView = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("GunnerView"))

local ORIGIN = Vector3.new(0, 420, 0)
local DT = 1 / 60
local MODEL = "Rotster"
local TURNS = { 0, 45, 90, 135 }

Lighting.ClockTime = 14.5
Lighting.Brightness = 2.4

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function block(folder, size, frame, color, material)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = frame
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Parent = folder
	return part
end

-- Parts that move with `pivot`: welded to it, or hung from it by a joint, all the way down.
local function subtree(model, pivot)
	local set = { [pivot] = true }
	local grew = true
	while grew do
		grew = false
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") and not set[part] then
				for _, link in ipairs(part:GetChildren()) do
					local parent = (link:IsA("WeldConstraint") or link:IsA("Motor6D")) and link.Part0 or nil
					if parent and set[parent] and link.Part1 == part then
						set[part] = true
						grew = true
						break
					end
				end
			end
		end
	end
	return set
end

-- The mount turned as its joints would turn it (edit mode runs no joints): pitch, then yaw.
local function poseMount(model, yawDeg, pitchDeg)
	local names = VehicleWeaponData.Parts.turret
	local yawPart, pitchPart = model:FindFirstChild(names.yaw), model:FindFirstChild(names.pitch)
	local function about(set, frame, rotation)
		local move = frame * rotation * frame:Inverse()
		for part in pairs(set) do
			part.CFrame = move * part.CFrame
		end
	end
	about(subtree(model, pitchPart), pitchPart.CFrame, CFrame.Angles(math.rad(pitchDeg), 0, 0))
	about(subtree(model, yawPart), yawPart.CFrame, CFrame.Angles(0, math.rad(yawDeg), 0))
end

local function bearing(direction)
	return math.deg(math.atan2(-direction.X, -direction.Z))
end

local current = nil
local function stopCurrent()
	if current then
		pcall(function()
			current:Stop()
		end)
		current = nil
	end
	local old = StarterGui:FindFirstChild("GunnerSight")
	if old then
		old:Destroy()
	end
end

-- Builds the scene, lays the gun, turns the car `turn` degrees at 90 deg/s and leaves the view running.
-- Returns the view, the model, the laid direction and the barrel's ray now.
local function run(folder, turn)
	stopCurrent()
	block(folder, Vector3.new(400, 1, 400), CFrame.new(ORIGIN - Vector3.new(0, 0.5, 0)), Color3.fromRGB(128, 130, 136), Enum.Material.Concrete)
	local model = VehicleModels.Build(MODEL, Random.new(7), { scheme = 1 })
	model.Parent = folder
	model:PivotTo(CFrame.new(ORIGIN))
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	local spec = VehicleWeaponData.ForModel(MODEL, "turret")
	local view = GunnerView.Start(model, spec, { noInput = true, guiParent = StarterGui })
	if not view then
		note(MODEL .. ": GunnerView did not start")
		return nil
	end
	current = view
	view.yaw, view.wantYaw, view.pitch, view.wantPitch = 0, 0, 0, 0
	for _ = 1, 30 do
		view:Update(DT, { ready = true })
	end
	local _, origin0, laid = view:AimPoint()
	local pole = origin0 + laid * 60
	block(folder, Vector3.new(1.2, 24, 1.2), CFrame.new(pole.X, ORIGIN.Y + 12, pole.Z), Color3.fromRGB(40, 220, 90), Enum.Material.Neon)
	-- The car turns about the turret's own axis, so the barrel's line stays put if the aim holds.
	local base = model:GetPivot()
	local axis = model:FindFirstChild(VehicleWeaponData.Parts.turret.yaw).Position
	local steps = math.floor(turn / 90 / DT + 0.5)
	for i = 1, steps do
		local angle = math.rad(turn * i / steps)
		model:PivotTo(CFrame.new(axis) * CFrame.Angles(0, angle, 0) * CFrame.new(-axis) * base)
		view:Update(DT, { ready = true })
	end
	for _ = 1, 10 do
		view:Update(DT, { ready = true })
	end
	local _, origin, direction = view:AimPoint()
	local off = math.deg(math.acos(math.clamp(direction:Dot(laid), -1, 1)))
	note(string.format("%s car turned %d deg: barrel bearing %.2f deg (laid %.2f), %.3f deg off the laid aim, turret yaw %.2f deg against the car -- %s",
		MODEL, turn, bearing(direction), bearing(laid), off, view.yaw, off < 0.5 and "HELD" or "TURNED WITH THE CAR"))
	return view, model, origin, direction, pole
end

local views = {}
for _, turn in ipairs(TURNS) do
	table.insert(views, {
		name = string.format("car_%03d", turn),
		settle = 1,
		setup = function(folder, camera)
			local view, model, origin, direction, pole = run(folder, turn)
			if not view then
				return
			end
			local yaw, pitch = view.yaw, view.pitch
			stopCurrent()
			poseMount(model, yaw, pitch)
			local beam = block(folder, Vector3.new(0.35, 0.35, 60), CFrame.lookAt(origin + direction * 30, origin + direction * 60),
				Color3.fromRGB(255, 40, 220), Enum.Material.Neon)
			beam.CanQuery = false
			camera.CameraType = Enum.CameraType.Scriptable
			camera.FieldOfView = 50
			local at = (origin + pole) / 2
			camera.CFrame = CFrame.lookAt(at + Vector3.new(34, 46, 26), at)
		end,
	})
	table.insert(views, {
		name = string.format("fp_%03d", turn),
		settle = 1,
		setup = function(folder, camera)
			local view, model = run(folder, turn)
			if view then
				poseMount(model, view.yaw, view.pitch)
			end
		end,
	})
end

table.insert(views, {
	name = "zz_cleanup",
	settle = 0.3,
	setup = function(folder, camera)
		stopCurrent()
		camera.CameraType = Enum.CameraType.Fixed
	end,
})

return views
