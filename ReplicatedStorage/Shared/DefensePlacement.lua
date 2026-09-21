-- Where a portable defense goes up: the placement rules DefenseService builds by, shared with the
-- client so the translucent preview (StarterPlayerScripts/DefensePreview) shows exactly the site the
-- server will use. One copy of the rules, so the two can't drift apart.
--
--   DefensePlacement.Sizes[itemId]                               each structure's box (studs)
--   DefensePlacement.ThrowTarget(from, look, aimPoint)          -> target, facing
--   DefensePlacement.FindSite(character, size, centre, flat, defenses, extraExclude)
--                                                               -> origin CFrame, or nil and why not
--
-- FindSite was DefenseService's findSite, moved here unchanged (tools/hud_ux_probe.lua compares the two
-- over a real map). A site needs ground under the centre and the four corners, no more than MaxSlope
-- between the highest and lowest, and nothing solid already in the box. `defenses` is the folder
-- built defenses live in, which never counts as ground; `extraExclude` lets the client leave out what
-- only it has (the camera's viewmodel and preview, client-side effects), which the server never sees.

local DefensePlacement = {}

DefensePlacement.MaxSlope = 5
-- How far a kit can be thrown.
DefensePlacement.ThrowRange = 60
-- Where a kit comes to rest is lifted this far before the site checks (DefenseService.landKit).
DefensePlacement.LandLift = 1

DefensePlacement.Sizes = {
	RotBarricade = Vector3.new(12, 7.5, 1.6),
	PopupBunker = Vector3.new(15, 8.5, 15),
	BrainrotFortress = Vector3.new(21, 12, 21),
}

-- Workspace folders that are never ground and never in the way: pickups, companions, effects,
-- deployables, supply drops.
DefensePlacement.IgnoredFolders = { "Loot", "Companions", "Effects", "Deployables", "SupplyDrops" }
-- The overlap check ignores the same, except deployables (a launch pad in the box blocks a build).
DefensePlacement.OverlapIgnoredFolders = { "Loot", "Companions", "Effects", "SupplyDrops" }

-- Where a throw from `from`, with the thrower looking along `look`, aimed at `aimPoint` (already
-- checked by the caller; nil throws straight ahead) comes down, and which way the structure faces:
-- along the aim, or the thrower's facing when the aim is straight down at their feet. The throw is
-- clamped to ThrowRange.
function DefensePlacement.ThrowTarget(from, look, aimPoint)
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)
	local target = aimPoint or (from + look * 30)
	local offset = target - from
	if offset.Magnitude > DefensePlacement.ThrowRange then
		offset = offset.Unit * DefensePlacement.ThrowRange
	end
	local facing = Vector3.new(offset.X, 0, offset.Z)
	facing = facing.Magnitude > 0.5 and facing.Unit or flatLook
	return from + offset, facing, offset
end

-- The lob itself, in one place: DefenseService throws the kit on this arc and the client's preview
-- walks the same one to work out where the kit will actually arrive. Longer throws take longer, so the
-- arc keeps its shape; the velocity is the one that puts the kit on `target` after `flightTime` under
-- the world's gravity. Returns velocity, flightTime, target, facing, offset.
DefensePlacement.ThrowSpeed = 40
DefensePlacement.ThrowMinTime = 0.5
DefensePlacement.ThrowMaxTime = 1.6

function DefensePlacement.ThrowArc(from, look, aimPoint)
	local target, facing, offset = DefensePlacement.ThrowTarget(from, look, aimPoint)
	local flightTime = math.clamp(offset.Magnitude / DefensePlacement.ThrowSpeed, DefensePlacement.ThrowMinTime, DefensePlacement.ThrowMaxTime)
	local velocity = Vector3.new(offset.X / flightTime, offset.Y / flightTime + 0.5 * workspace.Gravity * flightTime, offset.Z / flightTime)
	return velocity, flightTime, target, facing, offset
end

-- Where that arc first meets the world, walked in `steps` straight segments with a raycast each: the
-- kit is thrown flat enough that on a hill it can arrive well short of the aim, and this is the only
-- honest answer to "where will it land". Returns the point and whether anything was hit at all (when
-- nothing is, the arc's end is returned, which is the aim point).
function DefensePlacement.TraceThrow(from, velocity, flightTime, params, steps)
	steps = steps or 20
	local gravity = workspace.Gravity
	local previous = from
	for index = 1, steps do
		local t = flightTime * index / steps
		local point = from + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
		local hit = params and workspace:Raycast(previous, point - previous, params) or nil
		if hit then
			return hit.Position, true, t
		end
		previous = point
	end
	return previous, false, flightTime
end

local function addFolders(list, names)
	for _, name in ipairs(names) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(list, instance)
		end
	end
end

function DefensePlacement.GroundParams(character, defenses, extraExclude)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if character then
		table.insert(filter, character)
	end
	if defenses then
		table.insert(filter, defenses)
	end
	addFolders(filter, DefensePlacement.IgnoredFolders)
	for _, instance in ipairs(extraExclude or {}) do
		table.insert(filter, instance)
	end
	params.FilterDescendantsInstances = filter
	return params
end

-- Whether a structure of `size` can stand centred on `centre` with its front toward `flat` (a unit
-- direction on the ground plane): the ground-level origin to build at, or nil and why not.
function DefensePlacement.FindSite(character, size, centre, flat, defenses, extraExclude)
	local facing = CFrame.lookAt(Vector3.zero, flat)

	-- Ground under the centre and the corners; the lowest sets the level so nothing floats.
	local params = DefensePlacement.GroundParams(character, defenses, extraExclude)
	local low, high = math.huge, -math.huge
	local halfX, halfZ = size.X / 2 - 0.5, size.Z / 2 - 0.5
	for _, corner in ipairs({ { 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		local offset = facing:VectorToWorldSpace(Vector3.new(corner[1] * halfX, 0, corner[2] * halfZ))
		local from = centre + offset + Vector3.new(0, 20, 0)
		local hit = workspace:Raycast(from, Vector3.new(0, -60, 0), params)
		if not hit then
			return nil, "No ground to build on there."
		end
		-- Rays hit terrain water by default, and the surface of a lake read as ground: a barricade
		-- or bunker could be set down floating on it, a platform to walk across the water on.
		if hit.Material == Enum.Material.Water then
			return nil, "Can't build on water."
		end
		low, high = math.min(low, hit.Position.Y), math.max(high, hit.Position.Y)
	end
	if high - low > DefensePlacement.MaxSlope then
		return nil, "Too steep to build there."
	end

	local origin = CFrame.new(Vector3.new(centre.X, low, centre.Z)) * facing
	-- Nothing solid may already be in the box (other players included).
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local filter = {}
	if character then
		table.insert(filter, character)
	end
	addFolders(filter, DefensePlacement.OverlapIgnoredFolders)
	for _, instance in ipairs(extraExclude or {}) do
		table.insert(filter, instance)
	end
	overlap.FilterDescendantsInstances = filter
	local box = origin * CFrame.new(0, size.Y / 2 + 0.6, 0)
	for _, part in ipairs(workspace:GetPartBoundsInBox(box, size * 0.9, overlap)) do
		if part.CanCollide then
			return nil, "No room to build here."
		end
	end
	return origin
end

return DefensePlacement
