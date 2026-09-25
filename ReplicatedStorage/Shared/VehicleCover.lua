-- Vehicle cover: how much of a hit on someone riding a vehicle reaches them (Oliver, 2026-09-24:
-- "make the cars provide more protection to the player/bot as well").
--
--   VehicleCover.Share(modelId, seatName, via)          -> the share of a hit the rider takes
--   VehicleCover.Expected(modelId, seatName, dir)       -> the average share of a hit from `dir`
--   VehicleCover.Roll(modelId, seatName, dir, r)        -> "body", "glass" or "open" for a roll r in [0, 1)
--   VehicleCover.BlastShare(modelId, seatName)          -> the share of a blast the rider takes
--   VehicleCover.DirectionOf(x, y, z)                   -> "front" / "side" / "rear" / "top"
-- Server helpers (Roblox instances):
--   VehicleCover.SeatOf(character)                      -> model, seat, modelId (a live vehicle) or nil
--   VehicleCover.Direction(model, from, to)             -> where a shot from `from` at `to` comes in
--   VehicleCover.CrossesGlass(model, from, to)          -> whether that line passes a pane of its glass
--   VehicleCover.BlastShareFor(character)               -> BlastShare for whoever `character` is (1 on foot)
--
-- HOW A HIT IS SPLIT. Whatever the vehicle stops goes to the VEHICLE's health (VehicleService.DamageVehicle,
-- at its armour, VehicleArmor); the rest reaches the rider. What stops how much is the vehicle's class:
--   body   a shot that meets the bodywork (doors, pillars, roof, a bed wall, armour plate) first
--   glass  a shot that crosses a pane of the vehicle's glass to reach the rider (not armoured glass:
--          VehicleModels names that Armor*, and it is bodywork)
--   open   nothing in the way (a bike, a truck bed, a gunner's chest and head): the rider takes it all
-- A player's traced shot finds which by geometry (CombatService: the body stops the ray, the ray is
-- carried on to whoever sits behind it; a direct hit asks CrossesGlass). A bot rolls its shots instead
-- of tracing them, so it rolls which one it met from the seat's exposure (below) for the direction it
-- fires from: the same odds a traced shot has, so bots and players get the same protection.
-- A headshot through a windscreen still counts as a headshot, then the glass takes its share.
--
-- WHILE THE VEHICLE LIVES. A wrecked vehicle covers nobody (SeatOf ignores it); wrecking ejects and
-- hurts the riders as it always has (VehicleService). So a rider is protected exactly as long as the
-- vehicle's own health lasts -- which VehicleArmor keeps "not glass cannons, not juggernauts".
--
-- tools/vehicle_cover_check.py prints the time-to-kill of a rider in every seat from every side against
-- the same rider on foot, and holds the bands: a bike is about as open as on foot, an armoured car much
-- safer than a car, and no seat anywhere is immune.

local VehicleCover = {}

-- The share of a hit the vehicle takes when the shot meets its body or its glass.
VehicleCover.Classes = {
	car = { body = 0.8, glass = 0.35 },
	bike = { body = 0.5, glass = 0 },
	armored = { body = 0.92, glass = 0.8 },
}

-- Seat exposure: from each direction, the share of shots at the rider that meet the body and the glass
-- first (the rest are open). `blast` is the share of a blast that reaches them.
local CABIN = { -- a car's front seats: windscreen ahead, doors and side glass, a roof overhead
	front = { body = 0.4, glass = 0.6 }, side = { body = 0.5, glass = 0.5 },
	rear = { body = 0.5, glass = 0.5 }, top = { body = 1, glass = 0 }, blast = 0.6,
}
local VAN_BACK = { -- the back of a van: panel sides, a small window, the cab ahead
	front = { body = 0.9, glass = 0.1 }, side = { body = 0.7, glass = 0.3 },
	rear = { body = 0.7, glass = 0.3 }, top = { body = 1, glass = 0 }, blast = 0.5,
}
local BED = { -- sat on a truck bed's rail, legs over the side
	front = { body = 0.25, glass = 0 }, side = { body = 0.1, glass = 0 },
	rear = { body = 0.2, glass = 0 }, top = { body = 0, glass = 0 }, blast = 0.9,
}
local HATCH = { -- a gunner on a mount: covered to the waist, open from the chest up
	front = { body = 0.35, glass = 0 }, side = { body = 0.35, glass = 0 },
	rear = { body = 0.35, glass = 0 }, top = { body = 0, glass = 0 }, blast = 0.9,
}
local SADDLE = { -- a bike's rider: the fairing and tank ahead, nothing else
	front = { body = 0.25, glass = 0 }, side = { body = 0.15, glass = 0 },
	rear = { body = 0.1, glass = 0 }, top = { body = 0, glass = 0 }, blast = 1,
}
local PILLION = {
	front = { body = 0.1, glass = 0 }, side = { body = 0.15, glass = 0 },
	rear = { body = 0.1, glass = 0 }, top = { body = 0, glass = 0 }, blast = 1,
}
local SEALED = { -- inside armour all round (its glass is armour); blast share is VehicleArmor.CabinBlast
	front = { body = 1, glass = 0 }, side = { body = 1, glass = 0 },
	rear = { body = 1, glass = 0 }, top = { body = 1, glass = 0 }, blast = 0.25,
}
VehicleCover.Seats = { CABIN = CABIN, VAN_BACK = VAN_BACK, BED = BED, HATCH = HATCH, SADDLE = SADDLE,
	PILLION = PILLION, SEALED = SEALED }

VehicleCover.Models = {
	Rotster = { class = "car", seats = { DriverSeat = CABIN, PassengerSeat1 = CABIN } },
	TralalaGT = { class = "car", seats = { DriverSeat = CABIN, PassengerSeat1 = CABIN } },
	CrocodiloRanger = { class = "car", seats = { DriverSeat = CABIN, PassengerSeat1 = CABIN,
		PassengerSeat2 = BED, PassengerSeat3 = BED } },
	SahurVan = { class = "car", seats = { DriverSeat = CABIN, PassengerSeat1 = CABIN,
		PassengerSeat2 = VAN_BACK, PassengerSeat3 = VAN_BACK } },
	BrrStreetfighter = { class = "bike", seats = { DriverSeat = SADDLE, PassengerSeat1 = PILLION } },
	BananiniScoot = { class = "bike", seats = { DriverSeat = SADDLE, PassengerSeat1 = PILLION } },
	PatapimScrambler = { class = "bike", seats = { DriverSeat = SADDLE, PassengerSeat1 = PILLION } },
	TartarugaScout = { class = "armored", seats = { DriverSeat = SEALED, PassengerSeat1 = SEALED } },
	CameloCarrier = { class = "armored", seats = { DriverSeat = SEALED, PassengerSeat1 = SEALED,
		PassengerSeat2 = SEALED, PassengerSeat3 = SEALED, PassengerSeat4 = SEALED, PassengerSeat5 = SEALED } },
}

-- Any vehicle's gun seat is a mount: open from the chest up.
VehicleCover.GunnerSeat = HATCH

local function entryOf(modelId)
	return VehicleCover.Models[modelId] or { class = "car", seats = {} }
end

-- The class values and the seat exposure a rider of `seatName` has.
function VehicleCover.Profile(modelId, seatName)
	local entry = entryOf(modelId)
	local seat = seatName == "GunnerSeat" and VehicleCover.GunnerSeat or entry.seats[seatName]
	if not seat then
		seat = entry.class == "bike" and PILLION or (entry.class == "armored" and SEALED or CABIN)
	end
	return VehicleCover.Classes[entry.class] or VehicleCover.Classes.car, seat
end

function VehicleCover.Share(modelId, seatName, via)
	local class = VehicleCover.Profile(modelId, seatName)
	if via == "body" then
		return 1 - class.body
	elseif via == "glass" then
		return 1 - class.glass
	end
	return 1
end

function VehicleCover.Roll(modelId, seatName, dir, r)
	local _, seat = VehicleCover.Profile(modelId, seatName)
	local side = seat[dir] or seat.side
	if r < side.body then
		return "body"
	elseif r < side.body + side.glass then
		return "glass"
	end
	return "open"
end

function VehicleCover.Expected(modelId, seatName, dir)
	local _, seat = VehicleCover.Profile(modelId, seatName)
	local side = seat[dir] or seat.side
	local open = math.max(0, 1 - side.body - side.glass)
	return side.body * VehicleCover.Share(modelId, seatName, "body")
		+ side.glass * VehicleCover.Share(modelId, seatName, "glass") + open
end

function VehicleCover.BlastShare(modelId, seatName)
	local _, seat = VehicleCover.Profile(modelId, seatName)
	return seat.blast or 1
end

-- Where a shot comes in, from the vehicle's own frame: (x, y, z) points from the rider toward the
-- shooter, with the front at -Z. Steeper than about 50 degrees from above is the roof.
function VehicleCover.DirectionOf(x, y, z)
	local length = math.sqrt(x * x + y * y + z * z)
	if length < 1e-6 then
		return "side"
	end
	if y / length > 0.75 then
		return "top"
	end
	if math.abs(z) >= math.abs(x) then
		return z < 0 and "front" or "rear"
	end
	return "side"
end

--------------------------------------------------------------------------------
-- Server helpers
--------------------------------------------------------------------------------

-- The live vehicle `character` rides, its seat and its model id; nil on foot or in a wreck.
-- A mounted-gun emplacement (MountedGuns) carries a VehicleModel too, but its gunner is a body in the
-- open: only its shield covers them, and that as traced geometry. So nil there as well (on foot).
function VehicleCover.SeatOf(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	local model = seat and seat.Parent
	if not model or not model:IsA("Model") then
		return nil
	end
	local modelId = model:GetAttribute("VehicleModel")
	if modelId == nil or model:GetAttribute("Wrecked") or model:GetAttribute("MountedGun") then
		return nil
	end
	return model, seat, modelId
end

function VehicleCover.Direction(model, from, to)
	local frame = model.PrimaryPart and model.PrimaryPart.CFrame or model:GetPivot()
	local incoming = frame:VectorToObjectSpace(from - to)
	return VehicleCover.DirectionOf(incoming.X, incoming.Y, incoming.Z)
end

-- The panes a vehicle's glass is made of: see-through, shoot-through parts of Glass (VehicleModels
-- builds them non-queryable, so a ray never reports them; this tests the line against their boxes).
local glassCache = setmetatable({}, { __mode = "k" })
local function panesOf(model)
	local panes = glassCache[model]
	if not panes then
		panes = {}
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Material == Enum.Material.Glass and not part.CanQuery then
				table.insert(panes, part)
			end
		end
		glassCache[model] = panes
	end
	return panes
end

local function segmentHitsBox(part, from, to)
	local a = part.CFrame:PointToObjectSpace(from)
	local b = part.CFrame:PointToObjectSpace(to)
	local half = part.Size / 2 + Vector3.new(0.05, 0.05, 0.05)
	local enter, leave = 0, 1
	local d = b - a
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local start, delta, h = a[axis], d[axis], half[axis]
		if math.abs(delta) < 1e-9 then
			if math.abs(start) > h then
				return false
			end
		else
			local t1, t2 = (-h - start) / delta, (h - start) / delta
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			enter, leave = math.max(enter, t1), math.min(leave, t2)
			if enter > leave then
				return false
			end
		end
	end
	return true
end

function VehicleCover.CrossesGlass(model, from, to)
	for _, pane in ipairs(panesOf(model)) do
		if pane.Parent and segmentHitsBox(pane, from, to) then
			return true
		end
	end
	return false
end

function VehicleCover.BlastShareFor(character)
	local _, seat, modelId = VehicleCover.SeatOf(character)
	if not seat then
		return 1
	end
	return VehicleCover.BlastShare(modelId, seat.Name)
end

return VehicleCover
