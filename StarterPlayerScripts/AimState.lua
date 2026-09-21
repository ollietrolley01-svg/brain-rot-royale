-- Where the local player is aiming, shared between client scripts. ModuleScript, so anything that has
-- to aim exactly as shots and throws do (the pop-up defense placement preview) uses CombatClient's own
-- crosshair raycast instead of a copy of it that could drift.
--
-- CombatClient owns it: it registers its aim function at start-up and records every point it sends
-- with Fire, UseSelected and the companion command. Other scripts only read:
--   AimState.Point   the last aim point CombatClient computed (Vector3), or nil before the first
--   AimState.Get()   the point under the crosshair right now, by the same raycast (Vector3 or nil;
--                    nil until CombatClient has started, or with no character). Also updates Point.

local AimState = {
	Point = nil,
}

local resolver = nil

-- CombatClient only.
function AimState.SetResolver(fn)
	resolver = fn
end

function AimState.Get()
	if not resolver then
		return nil
	end
	-- The resolver records the point in AimState.Point itself.
	return resolver()
end

return AimState
