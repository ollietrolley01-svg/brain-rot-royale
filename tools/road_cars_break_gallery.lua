-- #51 road cars, the picture and the live probe (tools/road_cars_proof_check.py measures the numbers under
-- lupa; this is what they look like, on the real terrain, with Roblox's own rays). Needs the coordinator's
-- Studio:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/road_cars_break_gallery.lua -OutDir <folder> -TimeoutSeconds 600
--
-- Builds TralalaTown (seed 7), then for a kerb car, a driveway car, a car-park car and a wilds wreck:
--   _a  the car whole, from eye level across it
--   _b  after 150 of damage (the pool at 90 of 240: cracks at stage 2, colour weathered, never see-through)
--   _c  0.3 s after the break (the debris BreakFxClient throws, if the gallery runner draws client effects)
--   _d  3 s after: what is left where the car stood (the check says nothing: every part and the Model gone)
-- and one drivable car wrecked by VehicleService.DamageVehicle, _a before and _d three seconds after, for the
-- contrast: a drivable's wreck stays where it is, whole, and nothing more can hurt it.
--
-- The notes ("[BRR_Gallery] note ...") are the probe. For each car: its health before and after, the
-- parts left, and a ring of Roblox rays (8 directions x 3 heights, 24 in all) fired at it from 10 studs:
-- how many met the car, and how many of those met a part DestructibleService.FromPart takes and
-- KeyOf puts in the car's pool. lupa's rays treat a wheel as a box; these are Roblox's own, cylinders and
-- all. Expected: every ray that meets the car counts for its pool, and 0 parts left after the break.

local MAP, SEED = "TralalaTown", 7

local Lighting = game:GetService("Lighting")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local state = { targets = {} }

local function partsOf(target)
	local out = {}
	if target.model then
		for _, d in ipairs(target.model:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(out, d)
			end
		end
	else
		for _, d in ipairs(target.parts) do
			if d.Parent then
				table.insert(out, d)
			end
		end
	end
	return out
end

local function boxOf(parts)
	local lo, hi = nil, nil
	for _, p in ipairs(parts) do
		local h = p.Size / 2
		local a, b = p.Position - h, p.Position + h
		lo = lo and lo:Min(a) or a
		hi = hi and hi:Max(b) or b
	end
	if not lo then
		return nil, nil
	end
	return (lo + hi) / 2, hi - lo
end

-- The ring of rays: how many meet the car, and how many of those count for its pool.
local function ring(target, DS)
	local parts = partsOf(target)
	local centre, size = boxOf(parts)
	if not centre then
		return 0, 0
	end
	local own = {}
	for _, p in ipairs(parts) do
		own[p] = true
	end
	local key = target.model or target.tag
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace:FindFirstChild("Map") }
	local met, counted = 0, 0
	for i = 0, 7 do
		local angle = i * math.pi / 4
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		for _, y in ipairs({ -0.3, 0, 0.3 }) do
			local from = centre + dir * (math.max(size.X, size.Z) / 2 + 10) + Vector3.new(0, y * size.Y, 0)
			local aim = centre + Vector3.new(0, y * size.Y, 0)
			local hit = workspace:Raycast(from, (aim - from) * 1.5, params)
			if hit and own[hit.Instance] then
				met += 1
				if DS.FromPart(hit.Instance) == hit.Instance and DS.KeyOf(hit.Instance) == key then
					counted += 1
				end
			end
		end
	end
	return met, counted
end

local function eyeLevel(camera, target)
	local centre, size = boxOf(partsOf(target))
	if not centre then
		return
	end
	target.centre = target.centre or centre
	target.size = target.size or size
	local at = target.centre
	local reach = math.max(target.size.X, target.size.Z)
	camera.FieldOfView = 55
	camera.CFrame = CFrame.lookAt(at + Vector3.new(reach * 0.9, 4, reach * 0.7), at)
end

local function collect(map)
	local kerb, driveway, bay, wreck, drivable = nil, nil, nil, nil, nil
	local driveways = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d.Name == "Driveway" then
			table.insert(driveways, d)
		end
	end
	local wreckParts = {}
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("Model") and d.Name == "ParkedCar" then
			if d:GetAttribute("ParkStyle") then
				bay = bay or d
			else
				local pivot = d:GetPivot().Position
				local onDriveway = false
				for _, w in ipairs(driveways) do
					local l = w.CFrame:PointToObjectSpace(pivot)
					if math.abs(l.X) <= w.Size.X / 2 + 1 and math.abs(l.Z) <= w.Size.Z / 2 + 1 then
						onDriveway = true
					end
				end
				if onDriveway then
					driveway = driveway or d
				else
					kerb = kerb or d
				end
			end
		elseif d:IsA("Model") and d:GetAttribute("VehicleMaxHealth") and d:GetAttribute("VehicleKind") ~= "bike" then
			drivable = drivable or d
		elseif d:IsA("BasePart") then
			local tag = d:GetAttribute("Destructible")
			if type(tag) == "string" and string.sub(tag, 1, 6) == "Wreck:" then
				wreckParts[tag] = wreckParts[tag] or {}
				table.insert(wreckParts[tag], d)
			end
		end
	end
	for tag, parts in pairs(wreckParts) do
		wreck = wreck or { tag = tag, parts = parts }
	end
	state.targets = {
		{ name = "kerb", model = kerb },
		{ name = "driveway", model = driveway },
		{ name = "bay", model = bay },
		{ name = "wreck", tag = wreck and wreck.tag, parts = wreck and wreck.parts },
	}
	state.drivable = drivable
	for _, t in ipairs(state.targets) do
		note("%s: %s", t.name, (t.model or t.parts) and "found" or "NONE on this map")
	end
	note("drivable car: %s", drivable and drivable:GetAttribute("VehicleModel") or "NONE")
end

local views = {
	{
		name = "00_map",
		settle = 3,
		setup = function(_, camera)
			Lighting.ClockTime = 13
			local MapGenerator = require(modules:WaitForChild("MapGenerator"))
			math.randomseed(SEED)
			local info = MapGenerator.Build(MAP)
			note("built %s seed %d", MAP, SEED)
			task.wait(3)
			collect(workspace:FindFirstChild("Map"))
			camera.CFrame = CFrame.new(0, (info and info.radius or 900) * 1.3, 0) * CFrame.Angles(-math.pi / 2, 0, 0)
		end,
	},
}

for index, stage in ipairs({ "a", "b", "c", "d" }) do
	for targetIndex = 1, 4 do
		table.insert(views, {
			name = string.format("%02d_%d%s", 10 + targetIndex, targetIndex, stage),
			settle = stage == "c" and 0.3 or (stage == "d" and 3 or 1),
			setup = function(_, camera)
				local target = state.targets[targetIndex]
				if not target or not (target.model or target.parts) then
					return
				end
				local DS = require(modules:WaitForChild("DestructibleService"))
				local parts = partsOf(target)
				if stage == "a" then
					local met, counted = ring(target, DS)
					note("%s whole: %d parts, %d of 24 rays met it, %d of those count for its pool", target.name, #parts, met, counted)
				elseif stage == "b" and parts[1] then
					for _, p in ipairs(parts) do
						if p.CanQuery then
							DS.Damage(p, 150, nil, p.Position + Vector3.new(0, 20, 0))
							break
						end
					end
					for _, p in ipairs(parts) do
						local h, m = DS.HealthOf(p)
						if h then
							note("%s after 150: %.0f of %.0f", target.name, h, m)
							break
						end
					end
				elseif stage == "c" and parts[1] then
					for _, p in ipairs(parts) do
						if p.CanQuery and p.Parent then
							DS.Damage(p, 1e6, nil, p.Position + Vector3.new(0, 20, 0))
							break
						end
					end
				elseif stage == "d" then
					note("%s 3 s after the break: %d parts left, Model %s", target.name, #partsOf(target),
						target.model and (target.model.Parent and "still in the map" or "gone") or "n/a")
				end
				eyeLevel(camera, target)
			end,
		})
	end
	if index == 1 or index == 4 then
		table.insert(views, {
			name = string.format("20_drivable_%s", stage),
			settle = index == 4 and 3 or 1,
			setup = function(_, camera)
				local model = state.drivable
				if not model then
					return
				end
				local target = { model = model }
				if index == 4 then
					local VehicleService = require(modules:WaitForChild("VehicleService"))
					local dealt, wrecked = VehicleService.DamageVehicle(nil, model, 1e6, "bullet")
					task.wait(3)
					local again = VehicleService.DamageVehicle(nil, model, 100, "bullet")
					note("drivable wrecked: dealt %s, wrecked %s, still in the map %s, a later hit dealt %s", tostring(dealt),
						tostring(wrecked), tostring(model.Parent ~= nil), tostring(again))
				end
				state.drivableTarget = state.drivableTarget or target
				eyeLevel(camera, state.drivableTarget)
			end,
		})
	end
end

return views
