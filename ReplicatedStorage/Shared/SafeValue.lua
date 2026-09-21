-- Checks for values that arrive from a client. A RemoteEvent argument is whatever a modified client
-- chooses to send, and the dangerous numbers slip past the obvious tests:
--
--   * NaN fails every comparison, so `math.abs(v) > limit` and `v.Magnitude > limit` are both FALSE
--     for it: a size check alone lets it straight through. Only `v == v` catches it.
--   * Infinity passes `v == v`, then turns into NaN the moment it meets `.Unit`, `limit / v` or `0 * v`.
--
-- So every component is tested on its own, for NaN and for size. A value that fails must be refused
-- (or replaced with a server-chosen default) before it reaches physics, a raycast or a broadcast.
--
--   SafeValue.Number(n, limit)    a real number within +-limit
--   SafeValue.Vector3(v, limit)   a Vector3 whose X, Y and Z all pass Number
--
-- `limit` defaults to 1e6, far beyond any map coordinate and far below where float precision fails.

local SafeValue = {}

SafeValue.DefaultLimit = 1e6

function SafeValue.Number(n, limit)
	return type(n) == "number" and n == n and math.abs(n) <= (limit or SafeValue.DefaultLimit)
end

function SafeValue.Vector3(v, limit)
	if typeof(v) ~= "Vector3" then
		return false
	end
	limit = limit or SafeValue.DefaultLimit
	local x, y, z = v.X, v.Y, v.Z
	return x == x and y == y and z == z and math.abs(x) <= limit and math.abs(y) <= limit and math.abs(z) <= limit
end

return SafeValue
