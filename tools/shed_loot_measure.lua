-- Measures shed loot (MapWilds.addShedLoot) on a built map, against its OWN records
-- (built.shedLoot.records, one per spot: the shelter's own halfX/halfZ/base/pivot and the distance
-- to the nearest town it used for the keepout guard) -- ground truth from the placement code itself,
-- not a footprint the checker has to re-derive by guessing which shelter a spot belongs to.
--
-- Called as measure(map, built, options) -> { shelterCount, withLoot, itemSpots, chestSpots,
-- violations = { { what, detail, x, z }, ... } }.

local map, built, options = ...
options = options or {}
local MARGIN = options.margin or 0.4
local FLOOR_TOL = options.floorTol or 0.15
local DOOR_TOL = options.doorTol or 0.1
local KEEPOUT = options.keepout or 260

local violations = {}
local function violate(what, detail, x, z)
	table.insert(violations, { what = what, detail = detail, x = x, z = z })
end

local shelterCount = map:GetAttribute("WildsShelters") or 0
local withLoot = (built.shedLoot and built.shedLoot.structures) or 0
local itemSpots = #built.lootSpots.weapon + #built.lootSpots.heal + #built.lootSpots.item
local chestSpots = #built.chestSpots

local records = (built.shedLoot and built.shedLoot.records) or {}
for _, r in ipairs(records) do
	local diff = r.pos - Vector3.new(r.pivotX, r.base, r.pivotZ)
	local lx = diff.X * r.rightX + diff.Z * r.rightZ
	local lz = diff.X * r.lookX + diff.Z * r.lookZ
	if math.abs(r.pos.Y - r.base) > FLOOR_TOL then
		violate("floor", string.format("%.2f studs off the floor", r.pos.Y - r.base), r.pos.X, r.pos.Z)
	end
	if math.abs(lx) > r.halfX - MARGIN then
		violate("bounds", string.format("side: %.2f vs halfX %.2f", lx, r.halfX), r.pos.X, r.pos.Z)
	end
	if math.abs(lz) > r.halfZ - MARGIN then
		violate("bounds", string.format("depth: %.2f vs halfZ %.2f", lz, r.halfZ), r.pos.X, r.pos.Z)
	end
	-- The door wall is at local Z = +halfZ along `along` (== the shelter's WorldPivot.LookVector); a
	-- spot meant to be reachable through the opening sits between the centre and that wall, so lz
	-- should be positive.
	if lz < -DOOR_TOL then
		violate("reach", string.format("lz %.2f: on the wrong side of the shelter's centre from its door", lz), r.pos.X, r.pos.Z)
	end
	if r.nearest < KEEPOUT - MARGIN then
		violate("keepout", string.format("%.0f studs from a town centre", r.nearest), r.pos.X, r.pos.Z)
	end
end

return {
	shelterCount = shelterCount,
	withLoot = withLoot,
	itemSpots = itemSpots,
	chestSpots = chestSpots,
	violations = violations,
}
