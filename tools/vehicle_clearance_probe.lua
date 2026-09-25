-- Ground clearance of every vehicle at rest (Oliver 09-25: cars hang up on rocks by the underside).
-- Each model is built, rigged and stepped with no input on a flat plate for 3 s, then measured:
--   clear  lowest point of any collidable part above the ground (the belly's worst corner)
--   nose / tail  the same, only over the front / rear fifth of the collider's length
--   wheelR  smallest wheel radius (a wheel climbs roughly what's under half of it)
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/vehicle_clearance_probe.lua -PlaceFile <build>
-- Lines: "[CLEAR] <model> clear=.. nose=.. tail=.. wheelR=.. colliders=N".
local RunService = game:GetService("RunService")
local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))

local function out(f, ...) print("[CLEAR] " .. string.format(f, ...)) end
if not RunService:IsRunning() then RunService:Run() end
task.wait(2)

local MODELS = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan", "TartarugaScout", "PatapimScrambler", "BananiniScoot", "BrrStreetfighter", "CameloCarrier" }
local OX, OY, OZ = 7000, 50, -7000
local plate = Instance.new("Part")
plate.Anchored, plate.Size = true, Vector3.new(40 * #MODELS + 40, 2, 80)
plate.Position = Vector3.new(OX + 20 * #MODELS, OY - 1, OZ)
plate.Parent = workspace

local rigs = {}
for i, id in ipairs(MODELS) do
	local model = VehicleModels.Build(id, Random.new(7))
	model:PivotTo(CFrame.new(OX + 40 * (i - 1) + 20, OY + 0.5, OZ))
	model.Parent = workspace
	rigs[i] = { id = id, model = model, rig = VehicleDynamics.Rig(model) }
end
local conn = RunService.Stepped:Connect(function(_, dt)
	for _, r in ipairs(rigs) do
		if r.rig then VehicleDynamics.Step(r.rig, { throttle = 0, steer = 0 }, dt) end
	end
end)
task.wait(3)
conn:Disconnect()

for _, r in ipairs(rigs) do
	local chassis = r.model.PrimaryPart
	local look = chassis.CFrame.LookVector
	local low, nose, tail, n = math.huge, math.huge, math.huge, 0
	-- the collider's extent along the car, for the nose/tail fifths
	local minZ, maxZ, pts = math.huge, -math.huge, {}
	for _, p in ipairs(r.model:GetDescendants()) do
		if p:IsA("BasePart") and p.CanCollide then
			n += 1
			local s = p.Size / 2
			for _, c in ipairs({ -1, 1 }) do for _, d in ipairs({ -1, 1 }) do for _, e in ipairs({ -1, 1 }) do
				local w = p.CFrame * Vector3.new(s.X * c, s.Y * d, s.Z * e)
				local along = (w - chassis.Position):Dot(look)
				minZ, maxZ = math.min(minZ, along), math.max(maxZ, along)
				table.insert(pts, { w.Y - OY, along })
			end end end
		end
	end
	local span = maxZ - minZ
	for _, q in ipairs(pts) do
		low = math.min(low, q[1])
		if q[2] > maxZ - span / 5 then nose = math.min(nose, q[1]) end
		if q[2] < minZ + span / 5 then tail = math.min(tail, q[1]) end
	end
	local wheelR = math.huge
	for _, w in ipairs(r.rig and r.rig.wheels or {}) do wheelR = math.min(wheelR, w.radius) end
	out("%s clear=%.2f nose=%.2f tail=%.2f wheelR=%.2f colliders=%d", r.id, low, nose, tail, wheelR, n)
end
out("done")
