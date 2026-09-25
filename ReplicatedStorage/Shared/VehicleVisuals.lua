-- A vehicle's lights and engine note, for whichever machine draws and hears it (Oliver 09-25: "make
-- the headlights and brake lights work", "make the cars make engine sounds"). ModuleScript, so
-- VehicleClient uses it every frame and a Studio probe (server-only Run mode, where no LocalScript
-- runs) can drive and prove the very same code.
--   VehicleVisuals.Lights(model, state, distance, clockTime)   state = { driven, braking, reversing, wrecked }
--   VehicleVisuals.LampsOf(model) -> { entries = { {part, kind, base} }, spots = { SpotLight }, brake = PointLight }
--   VehicleVisuals.LampShare(kind, state) -> 0..1          pure
--   VehicleVisuals.EngineStep(engine, input, dt) -> pitch, volume   pure; `engine` is the caller's state table
-- Nothing here replicates: lens colours and the lights are set on the machine that shows them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VehicleWreckFx = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("VehicleWreckFx"))

local VehicleVisuals = {}

--------------------------------------------------------------------------------
-- Lights
--------------------------------------------------------------------------------

-- Lens parts say what they are with a "Lamp" attribute (VehicleModels: lamp, drl, tail). A "lamp"
-- lens facing backwards is a reversing lamp. Head lamps throw a SpotLight -- at most MAX_SPOTS per
-- vehicle, the outermost pair (one on a bike) -- and the brake lamps one small red PointLight; both
-- are switched off past LIGHT_DISTANCE (#131's lag caps), and all of it is off on a wreck.
VehicleVisuals.LIGHT_DISTANCE = 250
VehicleVisuals.MAX_SPOTS = 2
VehicleVisuals.HEAD_RANGE, VehicleVisuals.HEAD_ANGLE = 40, 50
VehicleVisuals.BRAKE_RANGE = 6
local HEAD_BRIGHT_NIGHT, HEAD_BRIGHT_DAY = 3, 0.6
local BRAKE_BRIGHT = 1.1
local DIM_PARKED = 0.34
local HEAD_COLOR, BRAKE_COLOR = Color3.fromRGB(255, 244, 214), Color3.fromRGB(255, 36, 36)

function VehicleVisuals.IsNight(clockTime)
	return clockTime < 6.5 or clockTime > 18
end

function VehicleVisuals.LampShare(kind, state)
	if state.wrecked then
		return 0
	end
	if kind == "reverse" then
		return state.reversing and 1 or DIM_PARKED
	end
	return VehicleWreckFx.LampShare(kind == "tail" and "tail" or "lamp", false, state.driven, state.braking)
end

-- STRONG keys (bug-hunt B3-2): a rebuilt entry must never re-read a dimmed colour as its base, so
-- the base comes from VehicleWreckFx.LampBaseColor and the entry is dropped when the model leaves.
local cache = {}

local function lightAt(chassis, name, position, className, props)
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Position = position
	attachment.Parent = chassis
	local light = Instance.new(className)
	for key, value in pairs(props) do
		light[key] = value
	end
	light.Enabled = false
	light.Parent = attachment
	return light
end

function VehicleVisuals.LampsOf(model)
	local found = cache[model]
	if found then
		return found
	end
	local chassis = model.PrimaryPart
	found = { entries = {}, spots = {}, state = nil }
	if not chassis then
		return found
	end
	local heads, tails = {}, {}
	for _, part in ipairs(model:GetDescendants()) do
		local role = part:IsA("BasePart") and part:GetAttribute("Lamp")
		if role then
			local at = chassis.CFrame:PointToObjectSpace(part.Position)
			local kind = role == "tail" and "tail" or ((role == "lamp" and at.Z > 0) and "reverse" or "head")
			table.insert(found.entries, { part = part, kind = kind, base = VehicleWreckFx.LampBaseColor(part) })
			if kind == "head" and role == "lamp" then
				table.insert(heads, { at = at, size = part.Size.X * part.Size.Y * part.Size.Z })
			elseif kind == "tail" then
				table.insert(tails, at)
			end
		end
	end
	-- The outermost head lamp on each side (the biggest, where a side has several at one width).
	local bike = model:GetAttribute("VehicleKind") == "bike"
	local pick = {}
	for _, head in ipairs(heads) do
		local side = bike and 0 or (head.at.X < 0 and -1 or 1)
		local best = pick[side]
		if not best or math.abs(head.at.X) > math.abs(best.at.X) + 0.05
			or (math.abs(head.at.X - best.at.X) <= 0.05 and head.size > best.size) then
			pick[side] = head
		end
	end
	for _, head in pairs(pick) do
		if #found.spots < VehicleVisuals.MAX_SPOTS then
			table.insert(found.spots, lightAt(chassis, "HeadBeam", head.at, "SpotLight", { Face = Enum.NormalId.Front,
				Range = VehicleVisuals.HEAD_RANGE, Angle = VehicleVisuals.HEAD_ANGLE, Shadows = false, Color = HEAD_COLOR }))
		end
	end
	if #tails > 0 then
		local sum = Vector3.zero
		for _, at in ipairs(tails) do
			sum += at
		end
		found.brake = lightAt(chassis, "BrakeGlow", sum / #tails + Vector3.new(0, 0, 0.4), "PointLight",
			{ Range = VehicleVisuals.BRAKE_RANGE, Brightness = BRAKE_BRIGHT, Shadows = false, Color = BRAKE_COLOR })
	end
	cache[model] = found
	local watch
	watch = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(game) then
			cache[model] = nil
			watch:Disconnect()
		end
	end)
	return found
end

function VehicleVisuals.Lights(model, state, distance, clockTime)
	local found = VehicleVisuals.LampsOf(model)
	local near = distance <= VehicleVisuals.LIGHT_DISTANCE
	local night = VehicleVisuals.IsNight(clockTime or 14)
	-- One number for the whole state: nothing is written while nothing changes.
	local key = (state.driven and 1 or 0) + (state.braking and 2 or 0) + (state.reversing and 4 or 0)
		+ (state.wrecked and 8 or 0) + (near and 16 or 0) + (night and 32 or 0)
	if found.state == key then
		return found
	end
	found.state = key
	for _, entry in ipairs(found.entries) do
		local share = VehicleVisuals.LampShare(entry.kind, state)
		entry.part.Color = Color3.new(entry.base.R * share, entry.base.G * share, entry.base.B * share)
	end
	local beams = near and state.driven and not state.wrecked
	for _, spot in ipairs(found.spots) do
		spot.Enabled = beams
		spot.Brightness = night and HEAD_BRIGHT_NIGHT or HEAD_BRIGHT_DAY
	end
	if found.brake then
		found.brake.Enabled = near and state.braking and not state.wrecked
	end
	return found
end

--------------------------------------------------------------------------------
-- Engine
--------------------------------------------------------------------------------

-- The note follows an engine speed (0 idle .. 1 redline), not road speed: the throttle drives it and
-- a simulated gearbox ties it to the road. Each gear covers road speed up to GEAR_TOPS x top speed;
-- at SHIFT_AT it shifts up, the revs dropping to the next gear's over SHIFT_TIME with the throttle
-- cut; standing still (or with the wheels off the ground) the throttle revs it freely, and letting
-- off from high revs pitches it down with a burble. Pitch and loudness are scaled by the model's
-- enginePitch / engineVolume (VehicleDynamics.Handling).
VehicleVisuals.GEAR_TOPS = { 0.2, 0.36, 0.54, 0.74, 1.0 }
VehicleVisuals.IDLE = 0.16
local SHIFT_AT, DOWN_AT, SHIFT_TIME = 0.85, 0.38, 0.16
local REV_UP, REV_DOWN, SHIFT_DROP = 3.2, 1.3, 6
local BURBLE_TIME = 0.5

-- input = { throttle = -1..1, speed = studs/s along the heading (either way), top = top speed,
--           grounded = bool, pitch = enginePitch, volume = engineVolume }
function VehicleVisuals.EngineStep(engine, input, dt)
	local gears = VehicleVisuals.GEAR_TOPS
	local idle = VehicleVisuals.IDLE
	engine.rpm = engine.rpm or idle
	engine.gear = engine.gear or 1
	engine.shift = engine.shift or 0
	engine.burble = engine.burble or 0
	engine.shifts = engine.shifts or 0
	local t = math.abs(input.throttle)
	local speed = math.abs(input.speed)
	local top = math.max(input.top, 1)
	local function road(gear)
		return speed / (top * gears[gear])
	end
	if engine.shift > 0 then
		engine.shift -= dt
	elseif t > 0.1 and road(engine.gear) > SHIFT_AT and engine.gear < #gears then
		engine.gear += 1
		engine.shift = SHIFT_TIME
		engine.shifts += 1
	elseif engine.gear > 1 and road(engine.gear) < DOWN_AT then
		engine.gear -= 1
	end
	local target
	if speed < 2 or not input.grounded then
		target = idle + t * (0.92 - idle)
	else
		target = math.max(idle + (1 - idle) * math.clamp(road(engine.gear), 0, 1), speed < 8 and idle + t * 0.45 or 0)
	end
	local rate
	if engine.shift > 0 then
		rate = SHIFT_DROP
	elseif target > engine.rpm then
		rate = REV_UP * (0.4 + t)
	else
		rate = REV_DOWN
	end
	engine.rpm += math.clamp(target - engine.rpm, -rate * dt, rate * dt)
	if (engine.lastThrottle or 0) > 0.5 and t < 0.1 and engine.rpm > 0.45 then
		engine.burble = BURBLE_TIME
	end
	engine.burble = math.max(0, engine.burble - dt)
	engine.lastThrottle = t
	local pitch = (input.pitch or 1) * (0.75 + 1.5 * engine.rpm)
	local volume = (input.volume or 1) * (0.4 + 0.35 * engine.rpm + 0.25 * t)
	if engine.shift > 0 then
		volume *= 0.75
	end
	if engine.burble > 0 then
		-- Uneven pops on the overrun.
		volume *= 0.7 + 0.3 * math.abs(math.noise(os.clock() * 23, engine.rpm * 7))
	end
	return pitch, volume
end

return VehicleVisuals
