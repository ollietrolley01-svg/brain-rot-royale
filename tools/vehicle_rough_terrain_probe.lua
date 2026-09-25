-- Rough terrain handling probe (Oliver 09-24: "make the vehicles handle better on rough terrain too").
-- Real physics: Run mode, the way tools/mapvehicle_physics_probe.lua does, proven by a falling part.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/vehicle_rough_terrain_probe.lua -WaitSeconds 900 -PlaceFile <build> > rough.log
--   python tools/vehicle_rough_terrain_check.py rough.log
--
-- Each vehicle is built with VehicleModels.Build and rigged with VehicleDynamics.Rig, NOT registered with
-- VehicleService, and stepped from RunService.Stepped by this file the way VehicleClient steps a driver's.
-- A scripted driver holds a target speed and a line. Every run has its own lane, an identical course
-- (one seed), all running at once, 6,000 studs out:
--   rough    the map's own relief (MapTerrain's three Perlin octaves, same wavelengths and amplitudes)
--            written as voxels, with rock domes (the Hills recipe's boulders) sunk into it
--   slope    a 14 degree ramp up, a crest, 14 degrees down
--   kerb     three 0.5 kerbs across the lane at 25 degrees (one wheel first), laid like MapDecor's: thin,
--            anchored, not colliding, ridden by the rays
--   crater   the rim of a blast crater 3 deep (DestructibleService's cone) with a lip of rock clods, its
--            centre 7 off the line: over the lip, across the edge of the bowl, out over the far lip
--   rubble   anchored broken blocks 0.3-1.1 studs, turned every way, collidable
--   steer    rough again, and halfway a lane change of 8 studs: the steering has to work mid-bump
-- At 3 speeds per model: 35%, 65% and 90% of its top speed.
-- Per run and per segment: the largest vertical acceleration (g), airtime (total and longest single
-- flight), wheel contact %, roll and pitch peaks against the ground under it, flips, snag time (under
-- half the target speed after reaching it), speed held (mean / target), and the lane change reached.
-- Planted faults (always run): "FAULT_underdamped" (Rotster at 65%, damping ratio 0.08), which the
-- rough check must fail, and "CASE_outcrop_FAULT_oneray" (Rotster on the outcrop rock field, one ray
-- per wheel), which vehicle_visuals_check must fail. One ray per wheel used to be planted on the
-- course; with the belly, the lift and the caps its course runs came out inside the limits (09-25),
-- but on rocks the single ray misses what the tyre's front meets and the physics wheel sinks into
-- the rock where the drawn one sits on it.
-- Lines: "[ROUGH] PHYSICS ...", "[ROUGH] run <model> <speed%> <segment> key=value ...", "[ROUGH] done".

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local VehicleDynamics = require(Shared:WaitForChild("VehicleDynamics"))
local VehicleModels = require(Shared:WaitForChild("VehicleModels"))
local VehicleVisuals = require(Shared:WaitForChild("VehicleVisuals"))
local Lighting = game:GetService("Lighting")

local TAG = "[ROUGH]"
local function out(format, ...)
	print(TAG .. " " .. string.format(format, ...))
end

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(2)
do
	local ball = Instance.new("Part")
	ball.Size = Vector3.new(2, 2, 2)
	ball.Position = Vector3.new(-6000, 900, 6000)
	ball.Parent = workspace
	local y0 = ball.Position.Y
	task.wait(1)
	out("PHYSICS running=%s fell=%.2f", tostring(RunService:IsRunning()), y0 - ball.Position.Y)
	ball:Destroy()
end

local MODELS = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan", "TartarugaScout", "CameloCarrier", "PatapimScrambler", "BananiniScoot",
	"BrrStreetfighter" }
local SPEEDS = { 0.35, 0.65, 0.9 }
-- Physics in Studio is not deterministic, so one run of a course is one sample: every run is repeated
-- on its own copy of the lane, and the check judges them all.
local REPEATS = 1
-- The drive-over rocks of the real maps, copied from their builders:
--   wilds   MapWilds boulder()'s companion rock, a block 0.45 x (4.5-7.5) across and 0.75 of that tall,
--           laid tilted on the ground (1.5-2.5 studs tall)
--   pebble  MapDecor rock()'s pebble, a ball 0.35 x (6-16) across, 0.7 of that tall, centred 0.2 of its
--           size up (1.2-3.1 studs showing)
--   outcrop the terrain's own rock: balls of Rock voxels 1.5-3.5 in radius standing 0.4-2.4 out of the
--           ground, the way the rough stretch below (and RotRidge) has them
-- Halfway along each field the car brakes to a halt among the rocks and pulls away again: where a
-- player or a bot hangs up is starting off beside a rock, not rolling over one at speed.
local ROCK_FIELDS = { "wilds", "pebble", "outcrop" }
local OX, OZ = -6000, 6000     -- lanes run toward -Z from z = OZ
local LANE = 44
local RUNOFF = 6      -- studs of the gap between lanes a run may use before it has left its course
local GRAVITY = workspace.Gravity

-- Segments, in studs along the lane (distance travelled toward -Z).
local SEGMENTS = {
	{ "runup", 0, 60 }, { "rough", 60, 220 }, { "slope", 220, 340 }, { "kerb", 340, 390 },
	{ "rubble", 390, 500 }, { "steer", 500, 660 }, { "crater", 660, 730 }, { "end", 730, 790 },
}
local LENGTH = 790
local FINISH = 660      -- the course is done here; the crater after it is reported only
local SLOPE = 18

local folder = Instance.new("Folder")
folder.Name = "RoughTerrainProbe"
folder.Parent = workspace
local terrain = workspace.Terrain

-- MapTerrain's relief, its three octaves, taken at a stretch of real map coordinates.
local SEED = 137.5
local function relief(x, z)
	local broad = math.noise(x / 300, z / 300, SEED) * 2
	local mid = math.noise(x / 150, z / 150, SEED + 17) * 2
	local fine = math.noise(x / 65, z / 65, SEED + 41) * 2
	return broad * 30 + mid * 10 + fine * 4
end
local MAPX, MAPZ = 180, -240
local REL0 = relief(MAPX, MAPZ)

local function part(size, cf, collide, material, color)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = collide
	p.Size = size
	p.CFrame = cf
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = folder
	return p
end

local function buildLane(x)
	local rng = Random.new(42)
	-- Base: grass to y = 0 over the whole lane.
	-- (With run-off both sides: the base fills the gap to the next lane, so no lane has void beside it.)
	terrain:FillBlock(CFrame.new(x, -6, OZ - LENGTH / 2), Vector3.new(LANE + 12, 12, LENGTH + 40), Enum.Material.Grass)
	-- Rough stretches: the relief, as 4-stud columns from y = 0 up (fractional tops, as Relief writes
	-- them), faded in and out over their first and last 20 studs, with rocks sunk into it near the line
	-- the wheels take. `rocks` per 100 studs, their tops `lo`..`hi` above the ground (calibrated: see the
	-- header).
	local function roughStretch(from, to, rocks, lo, hi, material)
		local function heightAt(dx, s)
			local fade = math.clamp(math.min(s - from, to - s) / 20, 0, 1)
			return 3 + math.clamp((relief(MAPX + dx, MAPZ + s) - REL0) * 0.5, -3, 3) * fade
		end
		for s = from, to - 4, 4 do
			for dx = -LANE / 2, LANE / 2 - 4, 4 do
				local h = heightAt(dx + 2, s + 2)
				terrain:FillBlock(CFrame.new(x + dx + 2, h / 2 - 0.01, OZ - s - 2), Vector3.new(4, h, 4), material)
			end
		end
		for _ = 1, math.floor((to - from) * rocks / 100) do
			local r = rng:NextNumber(1.5, 3.5)
			local sink = r - rng:NextNumber(lo, hi)
			local s = rng:NextNumber(from + 10, to - 10)
			terrain:FillBall(Vector3.new(x + rng:NextNumber(-7, 7), heightAt(0, s) - sink, OZ - s), r, Enum.Material.Rock)
		end
		terrain:FillWedge(CFrame.new(x, 1.5, OZ - from + 6) * CFrame.Angles(0, math.pi, 0), Vector3.new(LANE, 3, 12), material)
		terrain:FillWedge(CFrame.new(x, 1.5, OZ - to - 6), Vector3.new(LANE, 3, 12), material)
	end
	roughStretch(60, 220, 20, 0.4, 2.4, Enum.Material.Rock)      -- RotRidge-like: rocky
	roughStretch(500, 660, 8, 0.2, 1.0, Enum.Material.Grass)     -- SahurSprings-like: grassy
	-- Slope: up SLOPE degrees for 40, a 30 crest, down for 40 (the real maps' off-road p90 is 17-20).
	local rise = math.tan(math.rad(SLOPE)) * 40
	terrain:FillWedge(CFrame.new(x, rise / 2, OZ - 225 - 20) * CFrame.Angles(0, math.pi, 0), Vector3.new(LANE, rise, 40), Enum.Material.Grass)
	terrain:FillBlock(CFrame.new(x, rise / 2, OZ - 265 - 15), Vector3.new(LANE, rise, 30), Enum.Material.Grass)
	terrain:FillWedge(CFrame.new(x, rise / 2, OZ - 295 - 20), Vector3.new(LANE, rise, 40), Enum.Material.Grass)
	-- Kerbs.
	for i = 0, 2 do
		part(Vector3.new(LANE * 1.2, 0.5, 1), CFrame.new(x, 0.25, OZ - 350 - i * 12) * CFrame.Angles(0, math.rad(25), 0), false,
			Enum.Material.Concrete, Color3.fromRGB(170, 170, 170))
	end
	-- Rubble: anchored broken blocks 0.3-1.1, turned every way, collidable.
	for _ = 1, 150 do
		local size = Vector3.new(rng:NextNumber(0.3, 1.1), rng:NextNumber(0.3, 1.1), rng:NextNumber(0.3, 1.1))
		part(size, CFrame.new(x + rng:NextNumber(-LANE / 2 + 2, LANE / 2 - 2), size.Y * 0.3, OZ - rng:NextNumber(395, 495))
			* CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28)), true,
			Enum.Material.Slate, Color3.fromRGB(120, 116, 110))
	end
	-- Crater, REPORTED ONLY and last, so a vehicle that stays in it has already done the course: the real
	-- blast crater measured on RotRidge (3.2 deep, walls to 46 degrees at single-stud spacing), carved
	-- straight across the line.
	local cz = OZ - 695
	for z = 0, 2 do
		terrain:FillCylinder(CFrame.new(x, -(z + 0.5), cz), 1, 2.5 + (3 - z) * 2, Enum.Material.Air)
	end
	for clod = 0, 9 do
		local a = clod / 10 * math.pi * 2
		terrain:FillBall(Vector3.new(x + math.cos(a) * 9.5, -0.6, cz + math.sin(a) * 9.5), 1.4, Enum.Material.Rock)
	end
end

-- The lamps and the engine note, proven on every model before anything drives (VehicleVisuals is
-- what VehicleClient runs; this is the same code). Dusk, so the beams show on camera.
Lighting.ClockTime = 18.6
local TRUCKS = { CrocodiloRanger = true, TartarugaScout = true, CameloCarrier = true }
do
	local ids = table.clone(MODELS)
	if VehicleModels.Models.CameloCarrier and not table.find(ids, "CameloCarrier") then
		table.insert(ids, "CameloCarrier")
	end
	for i, id in ipairs(ids) do
		local model = VehicleModels.Build(id, Random.new(7))
		model:PivotTo(CFrame.new(OX - 400 - i * 30, 200, OZ))
		model.PrimaryPart.Anchored = true
		model.Parent = folder
		local found = VehicleVisuals.LampsOf(model)
		local heads, tails = 0, 0
		for _, entry in ipairs(found.entries) do
			heads += entry.kind == "head" and 1 or 0
			tails += entry.kind == "tail" and 1 or 0
		end
		local problems = {}
		local function lit(kind)
			for _, entry in ipairs(found.entries) do
				if entry.kind == kind then
					local c, b = entry.part.Color, entry.base
					return (c.R + c.G + c.B) / math.max(b.R + b.G + b.B, 1e-3)
				end
			end
			return -1
		end
		local function beams()
			local n = 0
			for _, spot in ipairs(found.spots) do
				n += spot.Enabled and 1 or 0
				if spot.Range > VehicleVisuals.HEAD_RANGE then
					table.insert(problems, "beam range")
				end
			end
			return n
		end
		local function brake()
			return found.brake ~= nil and found.brake.Enabled
		end
		VehicleVisuals.Lights(model, { driven = false }, 10, 20)
		if beams() > 0 or brake() then
			table.insert(problems, "lit while empty")
		end
		VehicleVisuals.Lights(model, { driven = true }, 10, 20)
		if beams() == 0 or beams() > VehicleVisuals.MAX_SPOTS then
			table.insert(problems, "beams driven=" .. beams())
		end
		if brake() or lit("tail") > 0.6 then
			table.insert(problems, "brake lit without braking")
		end
		VehicleVisuals.Lights(model, { driven = true, braking = true }, 10, 20)
		if not brake() or lit("tail") < 0.95 then
			table.insert(problems, "brake not lit under braking")
		end
		VehicleVisuals.Lights(model, { driven = true, braking = true }, VehicleVisuals.LIGHT_DISTANCE + 50, 20)
		if beams() > 0 or brake() then
			table.insert(problems, "lit past the distance cap")
		end
		VehicleVisuals.Lights(model, { driven = true, braking = true, reversing = true, wrecked = true }, 10, 20)
		if beams() > 0 or brake() or lit("head") > 0 or lit("tail") > 0 then
			table.insert(problems, "lit when wrecked")
		end
		if heads == 0 then
			table.insert(problems, "no head lens")
		end
		if tails == 0 then
			table.insert(problems, "no brake lens")
		end
		out("lights %s head=%d tail=%d spots=%d problems=%s", id, heads, tails, #found.spots,
			#problems > 0 and table.concat(problems, ",") or "none")
		model:Destroy()

		-- The engine: revs at a standstill, then a run up through the gears at full throttle.
		local h = VehicleDynamics.Handling[id]
		local function step(engine, throttle, speed)
			return VehicleVisuals.EngineStep(engine, { throttle = throttle, speed = speed, top = h.topSpeed, grounded = true,
				pitch = h.enginePitch, volume = h.engineVolume }, 1 / 60)
		end
		local engine = {}
		local base = step(engine, 0, 0)
		local last, rising = base, true
		for _ = 1, 30 do
			local pitch = step(engine, 1, 0)
			rising = rising and pitch >= last - 1e-6
			last = pitch
		end
		local blip = last
		engine = {}
		local drops, prev, dropping = 0, nil, false
		for f = 1, 60 * 14 do
			step(engine, 1, h.topSpeed * math.min(1, f / (60 * 12)))
			local falling = prev ~= nil and engine.rpm < prev - 1e-4
			if falling and not dropping then
				drops += 1
			end
			dropping = falling
			prev = engine.rpm
		end
		local class = VehicleModels.Models[id].kind == "bike" and "bike" or (TRUCKS[id] and "truck" or "car")
		out("engine %s class=%s base=%.3f blip=%.3f rising=%s shifts=%d drops=%d", id, class, base, blip, tostring(rising), engine.shifts, drops)
	end
end

-- The wreck blast (bug sweep 09-25): it goes off the moment a vehicle is wrecked, however far away
-- (VehicleWreckFx.Watch; Sfx does the falloff), never again when the smoke is next updated on the way
-- up to it, and never for a vehicle that was already a wreck when first seen.
do
	local VehicleWreckFx = require(Shared:WaitForChild("VehicleWreckFx"))
	local blasts, previous = {}, VehicleWreckFx.OnWreck
	VehicleWreckFx.OnWreck = function(model)
		blasts[model] = (blasts[model] or 0) + 1
	end
	local far = VehicleModels.Build("Rotster", Random.new(7))
	far:PivotTo(CFrame.new(OX - 1000, 200, OZ + 600))
	far.PrimaryPart.Anchored = true
	far.Parent = folder
	local old = VehicleModels.Build("Rotster", Random.new(7))
	old:PivotTo(CFrame.new(OX - 1030, 200, OZ + 600))
	old.PrimaryPart.Anchored = true
	old:SetAttribute("Wrecked", true)
	old.Parent = folder
	VehicleWreckFx.Watch(far)
	VehicleWreckFx.Watch(old)
	far:SetAttribute("Wrecked", true)
	task.wait()
	local immediate = blasts[far] or 0
	for _ = 1, 30 do
		VehicleWreckFx.SetSmoke(far, true) -- walking up to it: the smoke comes on, nothing else
		VehicleWreckFx.SetSmoke(old, true)
	end
	far:SetAttribute("Wrecked", false)
	far:SetAttribute("Wrecked", true)
	task.wait()
	out("wreck immediate=%d total=%d prewrecked=%d", immediate, blasts[far] or 0, blasts[old] or 0)
	VehicleWreckFx.OnWreck = previous
	far:Destroy()
	old:Destroy()
end

-- The runs.
local runs = {}
for _, modelId in ipairs(MODELS) do
	if VehicleModels.Models[modelId] and VehicleDynamics.Handling[modelId] then
		for _, share in ipairs(SPEEDS) do
			for rep = 1, REPEATS do
				table.insert(runs, { modelId = modelId, handlingId = modelId, share = share,
					label = modelId .. (rep > 1 and ("#" .. rep) or "") })
			end
		end
	end
end
do
	local planted = table.clone(VehicleDynamics.Handling.Rotster)
	planted.dampingRatio = 0.08
	VehicleDynamics.Handling.FAULT_underdamped = planted
	table.insert(runs, { modelId = "Rotster", handlingId = "FAULT_underdamped", share = 0.65, label = "FAULT_underdamped" })
	-- Stuck-then-fling cases: full throttle for 10 s nose-first into a wall, and into a 2.5-stud ledge.
	-- Neither may go past its speed cap or leave the ground by more than a few studs.
	for _, case in ipairs({ "wall", "ledge" }) do
		for _, modelId in ipairs({ "Rotster", "SahurVan", "PatapimScrambler" }) do
			table.insert(runs, { modelId = modelId, handlingId = modelId, share = 1, label = "CASE_" .. case .. "_" .. modelId, case = case })
		end
	end
	-- Rock fields (Oliver 09-25: cars stuck on rocks): every vehicle at 35% of top speed (picking its way) across 170 studs
	-- of each drive-over rock the maps scatter, none stuck (throttle held, under 2 studs/s) for over 3 s.
	-- The boulders and MapDecor's big rocks (4-13 studs tall) are cover to steer round, not in the field.
	for _, case in ipairs(ROCK_FIELDS) do
		for _, modelId in ipairs(MODELS) do
			if VehicleModels.Models[modelId] and VehicleDynamics.Handling[modelId] then
				table.insert(runs, { modelId = modelId, handlingId = modelId, share = 0.35, label = "CASE_" .. case .. "_" .. modelId, case = case, rocks = true })
			end
			if modelId == "Rotster" and case == "outcrop" then
				table.insert(runs, { modelId = modelId, handlingId = modelId, share = 0.35, label = "CASE_outcrop_FAULT_oneray", case = case, rocks = true, oneRay = true })
			end
			-- The armoured cars again at 65% (Oliver 09-25, the armoured cars stuck on rocks): a player
			-- doesn't pick their way at 35%.
			if modelId == "TartarugaScout" or modelId == "CameloCarrier" then
				table.insert(runs, { modelId = modelId, handlingId = modelId, share = 0.65, label = "CASE_" .. case .. "_" .. modelId .. "@65", case = case, rocks = true })
			end
		end
	end
end

-- Lanes side by side. A rock field's lane is ROCK_LANE wide (its rocks lie within 5 studs of the line,
-- and a car leaving the lane by more than ROCK_LANE/2 - 2 is a harness error before it can reach the
-- next), so all the vehicles on a field fit in one wide shot.
local ROCK_LANE = 20
local cursor = OX
for index, run in ipairs(runs) do
	local width = run.rocks and ROCK_LANE or LANE + 12
	run.x = cursor + width / 2
	run.halfWidth = run.rocks and ROCK_LANE / 2 - 2 or LANE / 2 + RUNOFF
	cursor += width
	if run.case then
		terrain:FillBlock(CFrame.new(run.x, -6, OZ - 100), Vector3.new(width, 12, 240), Enum.Material.Grass)
		if run.rocks then
			local rng = Random.new(run.case == "wilds" and 3 or 5)
			for z = 30, 190, 5 do
				for _ = 1, 3 do
					local x = run.x + rng:NextNumber(-5, 5)
					local rock
					if run.case == "outcrop" then
						local r = rng:NextNumber(1.5, 3.5)
						terrain:FillBall(Vector3.new(x, -(r - rng:NextNumber(0.4, 2.4)), OZ - z), r, Enum.Material.Rock)
					elseif run.case == "wilds" then
						local w = 0.45 * rng:NextNumber(4.5, 7.5)
						rock = part(Vector3.new(w, w * 0.75, w), CFrame.new(x, w * 0.75 * 0.34, OZ - z)
							* CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, math.pi), rng:NextNumber(-0.5, 0.5)), true,
							Enum.Material.Rock, Color3.fromRGB(118, 114, 108))
					else
						local w = 0.35 * rng:NextNumber(6, 16)
						rock = part(Vector3.new(w, w * 0.7, w), CFrame.new(x, w * 0.2, OZ - z), true, Enum.Material.Rock,
							Color3.fromRGB(132, 126, 118))
						rock.Shape = Enum.PartType.Ball
					end
					if rock then
						rock.Name = "Rock"
					end
				end
			end
		elseif run.case == "wall" then
			part(Vector3.new(30, 12, 4), CFrame.new(run.x, 6, OZ - 60), true, Enum.Material.Concrete, Color3.fromRGB(150, 150, 150))
		else
			part(Vector3.new(30, 2.5, 80), CFrame.new(run.x, 1.25, OZ - 100), true, Enum.Material.Concrete, Color3.fromRGB(150, 150, 150))
		end
	else
		buildLane(run.x)
	end
	if index % 4 == 0 then
		task.wait()
	end
end
task.wait(1)

-- The course measured the way tools/terrain_roughness_probe.lua measures the real maps, along both
-- wheel tracks of the first lane, so the calibration can be read off the log.
do
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }
	local function pct(list, p)
		table.sort(list)
		return #list > 0 and list[math.clamp(math.ceil(#list * p), 1, #list)] or 0
	end
	for _, seg in ipairs({ { "rough", 70, 210 }, { "steer", 510, 650 }, { "crater", 670, 720 } }) do
		local slopes, bumps, steps = {}, {}, {}
		for _, dx in ipairs({ -3, 3 }) do
			local h = {}
			for i = seg[2], seg[3] do
				local hit = workspace:Raycast(Vector3.new(runs[1].x + dx, 100, OZ - i), Vector3.new(0, -200, 0), params)
				h[i] = hit and hit.Position.Y or 0
			end
			for i = seg[2], seg[3] - 8 do
				table.insert(slopes, math.deg(math.atan(math.abs(h[i + 8] - h[i]) / 8)))
			end
			for i = seg[2] + 6, seg[3] - 6 do
				table.insert(bumps, math.abs(h[i] - (h[i - 6] + h[i + 6]) / 2))
			end
			for i = seg[2], seg[3] - 1 do
				table.insert(steps, math.abs(h[i + 1] - h[i]))
			end
		end
		out("COURSE %s slope p50/p90/p99/max=%.1f/%.1f/%.1f/%.1f bump p50/p90/p99/max=%.2f/%.2f/%.2f/%.2f step p99/max=%.2f/%.2f",
			seg[1], pct(slopes, 0.5), pct(slopes, 0.9), pct(slopes, 0.99), pct(slopes, 1), pct(bumps, 0.5), pct(bumps, 0.9),
			pct(bumps, 0.99), pct(bumps, 1), pct(steps, 0.99), pct(steps, 1))
	end
end

local function segmentAt(s)
	for _, seg in ipairs(SEGMENTS) do
		if s >= seg[2] and s < seg[3] then
			return seg[1]
		end
	end
	return nil
end

local function newStats()
	return { frames = 0, contact = 0, wheels = 0, air = 0, flight = 0, longest = 0, accel = 0, roll = 0, pitch = 0,
		flips = 0, snag = 0, speedSum = 0 }
end

for _, run in ipairs(runs) do
	local model = VehicleModels.Build(run.modelId, Random.new(7))
	model:SetAttribute("VehicleModel", run.handlingId)
	model:PivotTo(CFrame.new(run.x, 2.5, OZ - 4))
	model.Parent = folder
	local rig = VehicleDynamics.Rig(model)
	if not rig then
		out("PROBLEM no rig for %s", run.label)
		model:Destroy()
	else
		if run.oneRay then
			rig.samples = { 0 }
		end
		run.model, run.rig = model, rig
		-- Each hub's axle as built: its X against the chassis's +X (1 = along it, the way the wheel
		-- visuals turn it; -1 would roll backwards on screen, 0 an axle turned 90 degrees).
		run.axle = 1
		for _, wheel in ipairs(rig.wheels) do
			run.axle = math.min(run.axle, rig.chassis.CFrame:ToObjectSpace(wheel.hub.CFrame).RightVector.X)
		end
		run.target = rig.handling.topSpeed * run.share
		run.stats = {}
		run.lineX = run.x
		run.reached = false
	end
end

-- For whoever is watching Studio (Oliver 09-25: all the cars at once): one wide shot, high and behind,
-- following the pack's average position and backed off to frame every lane. It only moves the camera
-- (in Heartbeat, after the physics), so nothing it does reaches what is measured.
do
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
		RunService.Heartbeat:Connect(function()
			-- The pack: the rock fields' runs while any is still going (the widest shot that still shows
			-- the cars), else every run still going.
			local sum, n, minX, maxX = Vector3.zero, 0, math.huge, -math.huge
			for pass = 1, 2 do
				for _, run in ipairs(runs) do
					local chassis = run.rig and run.rig.chassis
					if chassis and chassis.Parent and not run.done and (pass == 2 or run.rocks) then
						local p = chassis.Position
						sum += p
						n += 1
						minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
					end
				end
				if n > 0 then
					break
				end
			end
			if n > 0 then
				local centre = sum / n
				local back = math.max(40, (maxX - minX) * 0.75)
				camera.CFrame = CFrame.lookAt(centre + Vector3.new(0, back * 0.55, back), centre - Vector3.new(0, 0, back * 0.15))
			end
		end)
	end
end

-- What the drawn wheels do on the rock fields, measured after the physics each frame (Heartbeat):
--   sink / float  the drawn tyre's lowest point against the ground under it, across its footprint
--   vis_phys      the drawn compression against the physics step's (where the spring isn't bottomed)
--   strut         a car strut's rod inside its sleeve, its bottom on the hub centre, upright
--   fwd / rev     the wheels' drawn roll rate against contact speed over radius, on the flat, off the
--                 line and backing up
-- The lamps follow each car's own inputs, and the engine plays if the client sound module loads here.
local Sfx
do
	local ok, module = pcall(function()
		return require(game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Sfx"))
	end)
	Sfx = ok and module or nil
	out("engine sound in this run: %s", ok and "yes" or ("no (" .. tostring(module) .. ")"))
end
do
	local exclude = {}
	for _, run in ipairs(runs) do
		if run.model then
			table.insert(exclude, run.model)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local SAMPLE = { -0.9, -0.6, -0.3, 0, 0.3, 0.6, 0.9 }
	RunService.Heartbeat:Connect(function(dt)
		local camera = workspace.CurrentCamera
		for _, run in ipairs(runs) do
			local rig = run.rig
			if run.rocks and rig and not run.done and run.throttle then
				local chassis = rig.chassis
				local cf = chassis.CFrame
				local h = rig.handling
				local w = run.wheelStats or { sink = {}, float = {}, diff = {}, strutBad = 0, strutFrames = 0, fwdMeas = 0, fwdExp = 0,
					revMeas = 0, revExp = 0 }
				run.wheelStats = w
				local s = OZ - cf.Position.Z
				local flat = s < 26
				-- Drawn travel against the physics compression, as the step drew it (Stepped)...
				for _, wheel in ipairs(rig.wheels) do
					if wheel.grounded and wheel.compression < h.travelUp + h.travelDown - 0.05 then
						table.insert(w.diff, math.abs(wheel.visualOffset + h.travelDown - wheel.compression))
					end
				end
				-- ...then the wheels put back on the ground where the body is after the physics, as
				-- VehicleClient does before each frame is drawn (RenderStepped), and the tyres measured
				-- against the ground there: what the player sees.
				VehicleDynamics.AnimateWheels(rig, 0)
				for _, wheel in ipairs(rig.wheels) do
					local hub, r = wheel.hub, wheel.radius
					if wheel.grounded then
						local c = hub.Position
						local worst
						for _, share in ipairs(SAMPLE) do
							local d = share * r
							local at = c + cf.LookVector * d
							local hit = workspace:Raycast(at + Vector3.new(0, r + 2, 0), Vector3.new(0, -(2 * r + 6), 0), params)
							if hit then
								local sink = hit.Position.Y - (at.Y - math.sqrt(r * r - d * d))
								worst = worst and math.max(worst, sink) or sink
							end
						end
						if worst then
							table.insert(w.sink, math.max(worst, 0))
							table.insert(w.float, math.max(-worst, 0))
						end
					end
					if wheel.strutJoint then
						local rod = wheel.strutJoint.Parent
						local sleeve = rig.model:FindFirstChild("StrutSleeve_" .. wheel.name)
						if sleeve then
							w.strutFrames += 1
							local rodAt = cf:ToObjectSpace(rod.CFrame)
							local sleeveAt = cf:ToObjectSpace(sleeve.CFrame)
							local hubAt = cf:PointToObjectSpace(hub.Position)
							local rodTop = rodAt.Y + rod.Size.Y / 2
							if rodTop < sleeveAt.Y - sleeve.Size.Y / 2 + 0.02 or rodTop > sleeveAt.Y + sleeve.Size.Y / 2 + 0.02
								or math.abs(rodAt.Y - rod.Size.Y / 2 - hubAt.Y) > 0.15 or rodAt.UpVector.Y < 0.95 then
								w.strutBad += 1
							end
						end
					end
				end
				-- Lamps and engine, from this car's own inputs.
				local throttle, forward = run.throttle, run.forward
				local distance = camera and (camera.CFrame.Position - cf.Position).Magnitude or 0
				VehicleVisuals.Lights(rig.model, { driven = true,
					braking = (throttle < -0.05 and forward > 1) or (throttle > 0.05 and forward < -1),
					reversing = throttle < -0.05 and forward < 0.5 }, distance, Lighting.ClockTime)
				if Sfx then
					if not run.engineLoop then
						local attachment = Instance.new("Attachment")
						attachment.Parent = chassis
						run.engineLoop, run.engine = Sfx.Loop("VehicleEngine", attachment), {}
					end
					if run.engineLoop then
						local pitch, volume = VehicleVisuals.EngineStep(run.engine, { throttle = throttle, speed = forward, top = h.topSpeed,
							grounded = (rig.visualGrounded or 1) > 0, pitch = h.enginePitch, volume = h.engineVolume }, dt)
						run.engineLoop:SetPitch(pitch)
						run.engineLoop:SetVolume(math.clamp(volume, 0, 1))
					end
				end
			elseif run.engineLoop and run.done then
				run.engineLoop:Stop()
				run.engineLoop = nil
			end
		end
	end)
end

-- What a stopped car is resting on: each wheel (down or up, load as a share of the car's weight,
-- compression against full travel), and every collider (CanCollide) within 0.15 studs of the ground or
-- a rock under or ahead of it, at the closest point found, in the chassis's frame (x right, y up,
-- z back): rays from inside each collider down through its underside and forward through its front.
local CONTACT_GAP = 0.15
local function stallReport(rig)
	local chassis = rig.chassis
	local cf = chassis.CFrame
	local weight = chassis.AssemblyMass * GRAVITY
	local wheels = {}
	for _, wheel in ipairs(rig.wheels) do
		table.insert(wheels, string.format("%s:%s/%.2f/%.2f", wheel.name:gsub("^Wheel_", ""), wheel.grounded and "dn" or "up",
			wheel.load / weight, wheel.compression / (rig.handling.travelUp + rig.handling.travelDown)))
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig.model }
	local touching = {}
	for _, hull in ipairs(rig.model:GetDescendants()) do
		if hull:IsA("BasePart") and hull.CanCollide then
			local best, bestHit
			local half = hull.Size / 2
			for _, fx in ipairs({ -0.9, 0, 0.9 }) do
				for _, fz in ipairs({ -0.9, -0.45, 0, 0.45, 0.9 }) do
					-- Down: from the collider's middle height to 0.15 below its underside (a wedge's
					-- sloped face is above its box's bottom, so a wedge reads high: fine for "which part").
					local from = hull.CFrame:PointToWorldSpace(Vector3.new(fx * half.X, 0, fz * half.Z))
					local hit = workspace:Raycast(from, Vector3.new(0, -(half.Y + CONTACT_GAP), 0), params)
					if hit then
						local gap = (from.Y - hit.Position.Y) - half.Y
						if not best or gap < best then
							best, bestHit = gap, hit
						end
					end
				end
			end
			for _, fx in ipairs({ -0.9, 0, 0.9 }) do
				for _, fy in ipairs({ -0.8, 0 }) do
					local from = hull.CFrame:PointToWorldSpace(Vector3.new(fx * half.X, fy * half.Y, 0))
					local hit = workspace:Raycast(from, cf.LookVector * (half.Z + CONTACT_GAP), params)
					if hit then
						local gap = (hit.Position - from):Dot(cf.LookVector) - half.Z
						if not best or gap < best then
							best, bestHit = gap, hit
						end
					end
				end
			end
			if best and best <= CONTACT_GAP then
				local at = cf:PointToObjectSpace(bestHit.Position)
				table.insert(touching, string.format("%s>%s@(%.1f,%.1f,%.1f)gap%.2f", hull.Name, bestHit.Instance.Name, at.X, at.Y, at.Z, best))
			end
		end
	end
	return string.format("wheels=%s touching=%s", table.concat(wheels, " "), #touching > 0 and table.concat(touching, ",") or "none")
end

-- See-through parts (Oliver 09-25: parts of the vehicles looked partly transparent in the trial):
-- every half second, every vehicle's parts other than its glass (Glass material, or a SightGlass)
-- with Transparency or LocalTransparencyModifier between 0.05 and 0.95; and every change to the van
-- bat's pieces, as it happens. Only the glass is meant to be see-through.
local seeThrough, seeThroughSeen, batChanges = 0, {}, 0
local function partlyClear(part)
	if part.Material == Enum.Material.Glass or string.find(part.Name, "SightGlass") then
		return false
	end
	local t = math.max(part.Transparency, part.LocalTransparencyModifier)
	return t > 0.05 and t < 0.95
end
for _, run in ipairs(runs) do
	if run.modelId == "SahurVan" and run.model then
		for _, part in ipairs(run.model:GetDescendants()) do
			if part:IsA("BasePart") and string.sub(part.Name, 1, 3) == "Bat" then
				for _, property in ipairs({ "Transparency", "LocalTransparencyModifier" }) do
					part:GetPropertyChangedSignal(property):Connect(function()
						batChanges += 1
						if batChanges <= 5 then
							out("batchange %s %s.%s=%.2f", run.label, part.Name, property, part[property])
						end
					end)
				end
			end
		end
	end
end
local lastScan = 0
RunService.Heartbeat:Connect(function()
	if tick() - lastScan < 0.5 then
		return
	end
	lastScan = tick()
	for _, run in ipairs(runs) do
		if run.model and run.model.Parent then
			for _, part in ipairs(run.model:GetDescendants()) do
				if part:IsA("BasePart") and partlyClear(part) then
					seeThrough += 1
					local key = run.modelId .. "/" .. part.Name
					if not seeThroughSeen[key] then
						seeThroughSeen[key] = true
						out("seethrough %s %s T=%.2f LTM=%.2f", run.label, part.Name, part.Transparency, part.LocalTransparencyModifier)
					end
				end
			end
		end
	end
end)

local startAt = tick()
local finished = 0
local live = 0
for _, run in ipairs(runs) do
	if run.rig then
		live += 1
	end
end

local connection
connection = RunService.Stepped:Connect(function(_, dt)
	for _, run in ipairs(runs) do
		local rig = run.rig
		if rig and not run.done then
			local chassis = rig.chassis
			local cf = chassis.CFrame
			local pos = cf.Position
			local s = OZ - pos.Z
			local v = chassis.AssemblyLinearVelocity
			local forward = v:Dot(cf.LookVector)
			local seg = segmentAt(s)
			-- The lane change.
			local wantX = run.x + ((s >= 570) and 8 or 0)
			local steer = math.clamp(-(pos.X - wantX) * 0.12 - cf.LookVector.X * 2.5, -1, 1)
			local throttle = (run.case and not run.rocks) and 1 or math.clamp((run.target - forward) / 4, -1, 1)
			if run.rocks then
				-- On the flat before the field: off the line, brake to a stop, back up 1.5 s, then on
				-- through the rocks -- every car at once, for the lamps and the wheels in reverse.
				run.phase = run.phase or "launch"
				if run.phase == "launch" and s >= 20 then
					run.phase = "stop"
				elseif run.phase == "stop" and forward < 0.5 then
					run.phase, run.reverseUntil = "reverse", tick() + 1.5
				elseif run.phase == "reverse" and tick() > run.reverseUntil then
					run.phase = "go"
				end
				if run.phase == "stop" then
					throttle = -1
				elseif run.phase == "reverse" then
					-- Backing up the lane-keeping steer turns the wrong way (it would put the car off the
					-- lane in a second): straight back, wheels centred.
					throttle, steer = -0.7, 0
				elseif s >= 110 and not run.halted then
					throttle = -1
					run.halted = forward < 0.5
				end
				run.through = math.max(run.through or 0, s)
				run.throttle, run.forward = throttle, forward
			end
			if run.rocks then
				local wasStuck = run.stuckFor or 0
				run.stuckFor = (run.phase == "go" and throttle > 0.5 and forward < 2) and wasStuck + dt or 0
				run.maxStuck = math.max(run.maxStuck or 0, run.stuckFor)
				-- Past the pull-away from a standstill (about 0.6 s under 2 studs/s for the heaviest): held by
				-- something. Say what -- each collider the ground or a rock is against, where on the car, and
				-- the wheel loads -- once per stall; count stalls over 1 s.
				if run.stuckFor > 1 and wasStuck <= 1 then
					run.stalls = (run.stalls or 0) + 1
					out("rockstall %s s=%.0f %s", run.label, s, stallReport(rig))
				end
			end
			-- Peaks while stepped, for the fling question: speed, spin, and height over the start.
			run.startY = run.startY or pos.Y
			if v.Magnitude > (run.peakV or 0) then
				run.peakV, run.peakAt = v.Magnitude, s
			end
			run.peakW = math.max(run.peakW or 0, chassis.AssemblyAngularVelocity.Magnitude)
			run.rise = math.max(run.rise or 0, pos.Y - run.startY)
			local telemetry = VehicleDynamics.Step(rig, { throttle = throttle, steer = steer }, dt)
			if run.case then
				-- What a client draws (no LocalScript runs in a server-only run): the wheels, their
				-- struts; on the rock fields the lamps and the engine too (Heartbeat, below).
				local spinBefore = {}
				for _, wheel in ipairs(rig.wheels) do
					spinBefore[wheel] = wheel.spin
				end
				VehicleDynamics.AnimateWheels(rig, dt)
				-- Roll: the turn each wheel was drawn this frame against contact speed over radius, over the
				-- frames on the flat it rolled freely (down, not slipping, not braked). With every hub's axle
				-- along the chassis's +X (checked at the start, `axle`), that is the turn on screen.
				if run.rocks and s < 26 then
					local w = run.wheelStats
					for _, wheel in ipairs(w and rig.wheels or {}) do
						local rolling = chassis:GetVelocityAtPosition(cf:PointToWorldSpace(wheel.mount)):Dot(cf.LookVector)
						if wheel.grounded and not wheel.slip and not rig.lastBraking and math.abs(rolling) > 4 then
							local turned = -((wheel.spin - spinBefore[wheel] + math.pi) % (2 * math.pi) - math.pi)
							if run.phase == "launch" then
								w.fwdMeas += turned
								w.fwdExp += rolling / wheel.radius * dt
							elseif run.phase == "reverse" then
								w.revMeas += turned
								w.revExp += rolling / wheel.radius * dt
							end
						end
					end
				end
			end
			if seg and not run.case and seg ~= "runup" and seg ~= "end" then
				local st = run.stats[seg]
				if not st then
					st = newStats()
					run.stats[seg] = st
				end
				st.frames += 1
				st.contact += telemetry.grounded
				st.wheels += #rig.wheels
				if telemetry.grounded == 0 then
					st.air += dt
					st.flight += dt
					st.longest = math.max(st.longest, st.flight)
				else
					st.flight = 0
				end
				if run.lastVy then
					-- Vertical acceleration past gravity's own, in g.
					local a = (v.Y - run.lastVy) / math.max(dt, 1 / 240)
					st.accel = math.max(st.accel, math.abs(a + (telemetry.grounded == 0 and GRAVITY or 0)) / GRAVITY)
				end
				-- The ground under it: the average of its grounded wheels' contact normals (level when airborne).
				local ground = Vector3.zero
				for _, wheel in ipairs(rig.wheels) do
					if wheel.grounded and wheel.normal then
						ground += wheel.normal
					end
				end
				ground = ground.Magnitude > 0.1 and ground.Unit or Vector3.yAxis
				st.roll = math.max(st.roll, math.deg(math.abs(math.asin(math.clamp(-cf.RightVector:Dot(ground), -1, 1)))))
				st.pitch = math.max(st.pitch, math.deg(math.abs(math.asin(math.clamp(cf.LookVector:Dot(ground), -1, 1)))))
				if cf.UpVector.Y < 0.25 then
					st.flips = 1
				end
				if run.reached and forward < run.target * 0.5 then
					st.snag += dt
				end
				st.speedSum += forward
				if seg == "steer" and s >= 570 and not run.steerFrom then
					run.steerFrom = { t = tick(), x = pos.X }
				end
				if run.steerFrom and not run.steerAt and tick() - run.steerFrom.t >= 1.5 then
					run.steerAt = pos.X - run.x
				end
			end
			run.lastVy = v.Y
			-- A course run sat still for over 1 s: say what's holding it (stallReport), once per stall, and
			-- count them.
			if not run.case and seg and seg ~= "runup" and forward < 1 then
				run.stallFor = (run.stallFor or 0) + dt
				if run.stallFor > 1 and run.stallFor - dt <= 1 then
					run.stalls = (run.stalls or 0) + 1
					local look = cf.LookVector
					out("stall %s %d s=%.0f seg=%s pitch=%.0f roll=%.0f %s", run.label, math.floor(run.share * 100 + 0.5), s, seg,
						math.deg(math.asin(math.clamp(look.Y, -1, 1))), math.deg(math.asin(math.clamp(-cf.RightVector.Y, -1, 1))), stallReport(rig))
				end
			else
				run.stallFor = 0
			end
			-- Below the course's floor (its grass base is 12 deep) is not a vehicle result: the harness put it
			-- somewhere with no ground, so it is reported as a HARNESS error, never as "unfinished".
			if pos.Y < -14 or math.abs(pos.X - run.x) > run.halfWidth then
				run.harness = string.format("left the course at s=%.0f x=%+.1f y=%.1f", s, pos.X - run.x, pos.Y)
			end
			if s >= LENGTH - 20 or tick() - startAt > 120 or run.harness or (run.case and s >= 200)
				or (run.case and tick() - startAt > (run.rocks and 35 or 12)) then
				run.done = true
				run.finalS = s
				finished += 1
				-- Parked where it stopped. The forces from its last step stay on a VectorForce until
				-- something changes them, so a car no longer being stepped used to carry on under full
				-- throttle, off the end of its lane and into the void.
				VehicleDynamics.Idle(rig)
				chassis.Anchored = true
			end
		end
	end
end)

while finished < live and tick() - startAt < 125 do
	task.wait(0.5)
end
connection:Disconnect()

for _, run in ipairs(runs) do
	if run.rig then
		local s = run.finalS or (OZ - run.rig.chassis.Position.Z)
		for _, seg in ipairs(SEGMENTS) do
			local st = run.stats[seg[1]]
			if st and st.frames > 0 then
				out("run %s %d %s accel=%.2f air=%.3f longest=%.3f contact=%.1f roll=%.1f pitch=%.1f flips=%d snag=%.2f held=%.2f",
					run.label, math.floor(run.share * 100 + 0.5), seg[1], st.accel, st.air, st.longest, 100 * st.contact / st.wheels,
					st.roll, st.pitch, st.flips, st.snag, st.speedSum / st.frames / run.target)
			end
		end
		if run.harness then
			out("HARNESS %s %d %s", run.label, math.floor(run.share * 100 + 0.5), run.harness)
		end
		out("peak %s %d v=%.1f cap=%.1f w=%.1f rise=%.1f at_s=%.0f", run.label, math.floor(run.share * 100 + 0.5), run.peakV or 0,
			run.rig.handling.topSpeed * 1.5, run.peakW or 0, run.rise or 0, run.peakAt or -1)
		if run.rocks then
			out("rocks %s stuck=%.2f stalls=%d distance=%.0f", run.label, run.maxStuck or 0, run.stalls or 0, run.through or s)
			local w = run.wheelStats
			if w then
				local function p95(list)
					table.sort(list)
					return #list > 0 and list[math.max(1, math.ceil(#list * 0.95))] or 0
				end
				out("wheels %s sink95=%.3f float95=%.3f vis_phys95=%.3f strut_bad=%d/%d fwd_ratio=%.3f rev_ratio=%.3f samples=%d axle=%.2f",
					run.label, p95(w.sink), p95(w.float), p95(w.diff), w.strutBad, w.strutFrames,
					w.fwdExp ~= 0 and w.fwdMeas / w.fwdExp or 0, w.revExp ~= 0 and w.revMeas / w.revExp or 0, #w.sink, run.axle or 0)
			end
		end
		out("run %s %d total finished=%s distance=%.0f lanechange=%.2f crater_crossed=%s stalls=%d", run.label, math.floor(run.share * 100 + 0.5),
			tostring(s >= FINISH), s, run.steerAt or -1, tostring(s >= LENGTH - 20), run.stalls or 0)
	end
end
VehicleDynamics.Handling.FAULT_underdamped = nil
out("transparency partly_clear=%d bat_changes=%d", seeThrough, batChanges)
out("done %d runs", #runs)
