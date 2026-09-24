-- The shape of an Objective Capture objective, in one place (#93).
--
-- Two things describe an objective: the ring players SEE on the ground, and the test the server
-- runs to decide who is STANDING on it. They used to be worked out separately (both happened to
-- read `mode.hillRadius`, and the capture band's -6 / hillHeight lived only in the capture code),
-- so nothing stopped a later change to one from leaving the other behind: a ring you are visibly
-- inside that doesn't count, or a capture that reaches past the paint. Both now come from here,
-- so the picture you approve is the rule that ships.
--
--   ObjectiveZone.Radius(mode)              -> studs from the centre to the edge of the ring
--   ObjectiveZone.Height(mode)              -> how high above the centre still counts
--   ObjectiveZone.Contains(mode, centre, p) -> is point p on the objective at `centre`
--   ObjectiveZone.RingSize(mode)            -> the ring part's Size (a Cylinder)
--   ObjectiveZone.RingCFrame(centre)        -> the ring part's CFrame
--
-- `mode` is the mode table (GameModes.Modes.KingOfTheHill) or nil for the defaults. Pure: no
-- services, so a harness can run it outside Studio (tools/objective_zone_check.py).

local ObjectiveZone = {}

ObjectiveZone.DefaultRadius = 28
ObjectiveZone.DefaultHeight = 22
-- How far BELOW the centre still counts: the ring sits on the ground, and a root part on a slope
-- or a step down the edge of the hill is a little under the centre's height.
ObjectiveZone.Below = 6
-- The ring is a thin disc; the lift keeps its top clear of the ground it lies on (ZFight's step x3,
-- as before).
ObjectiveZone.RingThickness = 0.4
ObjectiveZone.RingLift = 0.21

function ObjectiveZone.Radius(mode)
	return (mode and mode.hillRadius) or ObjectiveZone.DefaultRadius
end

function ObjectiveZone.Height(mode)
	return (mode and mode.hillHeight) or ObjectiveZone.DefaultHeight
end

-- Flat distance, so standing on the ring counts wherever the ground is; the edge itself counts, the
-- same as the painted disc, which is drawn right out to it.
function ObjectiveZone.Contains(mode, centre, point)
	local dx, dy, dz = point.X - centre.X, point.Y - centre.Y, point.Z - centre.Z
	local radius = ObjectiveZone.Radius(mode)
	return dx * dx + dz * dz <= radius * radius and dy >= -ObjectiveZone.Below and dy <= ObjectiveZone.Height(mode)
end

-- A Cylinder part's LENGTH is its X axis and its diameter is the smaller of Y and Z, so the disc is
-- (thickness, diameter, diameter) and RingCFrame turns X to point up.
function ObjectiveZone.RingSize(mode)
	local diameter = ObjectiveZone.Radius(mode) * 2
	return Vector3.new(ObjectiveZone.RingThickness, diameter, diameter)
end

function ObjectiveZone.RingCFrame(centre)
	return CFrame.new(centre + Vector3.new(0, ObjectiveZone.RingLift, 0)) * CFrame.Angles(0, 0, math.pi / 2)
end

return ObjectiveZone
