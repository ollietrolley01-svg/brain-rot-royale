-- Team Deathmatch / King of the Hill checks. One probe, six checks, one Studio job.
--
-- EVERY check here is proven capable of failing on EVERY run. Each detector is a pure function,
-- called twice: once on the real thing, and once on an input deliberately broken in exactly the
-- way the check exists to catch. The probe fails if the real input reports a finding, AND it fails
-- if the broken input does not. A fault planted by hand tonight proves the detector worked
-- tonight; one that runs every time proves it still works the day someone tidies the detector.
--
-- Run: tools/runtest.ps1 -Probe tools/mode_probe.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")

local GameModes = require(Shared:WaitForChild("GameModes"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local GameMode = require(Modules:WaitForChild("GameMode"))
local MapGenerator = require(Modules:WaitForChild("MapGenerator"))
local ModeKingOfTheHill = require(Modules:WaitForChild("ModeKingOfTheHill"))
local ModeTeams = require(Modules:WaitForChild("ModeTeams"))

local failures = 0
local checks = 0

local function say(...)
	print("[mode]", ...)
end

local function pass(name, detail)
	checks += 1
	say(string.format("PASS  %-26s %s", name, detail or ""))
end

local function fail(name, detail)
	checks += 1
	failures += 1
	say(string.format("FAIL  %-26s %s", name, detail or ""))
end

-- The self-test half. `broken` must produce at least one finding; if it does not, the DETECTOR is
-- broken, which is reported as its own failure and is the whole point of this file.
local function selftest(name, detectorProducedFinding, what)
	checks += 1
	if detectorProducedFinding then
		say(string.format("SELFTEST ok  %-21s caught: %s", name, what))
	else
		failures += 1
		say(string.format("SELFTEST DEAD %-20s the detector did NOT catch %s — this check tests nothing", name, what))
	end
end

--------------------------------------------------------------------------------
-- 1. GREEN IS UNCOMMON
--------------------------------------------------------------------------------

do
	local ok, detail = GameModes.GreenCheck(Rarity.Colors, Rarity.Order, GameModes.GreenRarity)
	if ok then
		pass("green rarity", detail)
	else
		fail("green rarity", detail)
	end

	-- Every tier's green lead, printed, so the claim is visible and not just asserted.
	for _, name in ipairs(Rarity.Order) do
		local c = Rarity.Colors[name]
		say(string.format("        %-10s R%3d G%3d B%3d   green lead %+.0f",
			name, c.R * 255, c.G * 255, c.B * 255, c.G * 255 - math.max(c.R * 255, c.B * 255)))
	end

	-- PERMANENT PLANTED FAULT: a palette where Common is the green one. The same function must
	-- refuse to call Uncommon green in it.
	local brokenColors = {}
	for name, colour in pairs(Rarity.Colors) do
		brokenColors[name] = colour
	end
	brokenColors.Common = Color3.fromRGB(20, 250, 20)
	local brokenOk = GameModes.GreenCheck(brokenColors, Rarity.Order, GameModes.GreenRarity)
	selftest("green rarity", not brokenOk, "a palette where Common is the greenest tier")
end

--------------------------------------------------------------------------------
-- 2. THE LOADOUT
--------------------------------------------------------------------------------

-- The detector: given a set of slots, does it match what a spawn kit must be? Returns a list of
-- findings. Used on the real granted loadout AND on a deliberately wrong one.
local function checkLoadout(slots, expected)
	local findings = {}
	local weapons, items = 0, {}
	for _, slot in pairs(slots) do
		if slot and slot.kind == "weapon" then
			weapons += 1
			local def = WeaponData.Get(slot.id)
			if not def then
				table.insert(findings, "unknown weapon " .. tostring(slot.id))
			elseif def.rarity ~= expected.weaponRarity then
				table.insert(findings, string.format("weapon %s is %s, wanted %s", slot.id, def.rarity, expected.weaponRarity))
			end
		elseif slot and slot.kind == "item" then
			items[slot.id] = (items[slot.id] or 0) + slot.count
		end
	end
	if weapons ~= 1 then
		table.insert(findings, string.format("%d weapons, wanted exactly 1", weapons))
	end
	for id, want in pairs(expected.items) do
		local got = items[id] or 0
		if got ~= want.count then
			table.insert(findings, string.format("%s x%d, wanted x%d", id, got, want.count))
		end
	end
	return findings
end

do
	local poolIds = ModeTeams.PoolIds()
	say(string.format("        green gun pool: %d guns", #poolIds))
	for _, id in ipairs(poolIds) do
		local def = WeaponData.Get(id)
		say(string.format("          %-24s %-10s groundWeight %s", id, def.rarity, tostring(def.groundWeight)))
	end
	if #poolIds == 0 then
		fail("green gun pool", "EMPTY — every spawn would be empty-handed")
	else
		pass("green gun pool", string.format("%d guns, all rarity %s", #poolIds, GameModes.GreenRarity))
	end

	-- N rolls, with the distribution printed. A roll that silently always returned the same gun
	-- would look fine from a single sample.
	local ROLLS = 2000
	local seen, wrongRarity = {}, 0
	for _ = 1, ROLLS do
		local id = ModeTeams.RollGreenWeapon()
		seen[id] = (seen[id] or 0) + 1
		local def = id and WeaponData.Get(id)
		if not def or def.rarity ~= GameModes.GreenRarity then
			wrongRarity += 1
		end
	end
	local distinct = 0
	for id, count in pairs(seen) do
		distinct += 1
		say(string.format("          rolled %-24s %4d  (%.1f%%)", id, count, count / ROLLS * 100))
	end
	say(string.format("        SAMPLE COUNT: %d rolls, %d distinct guns, %d wrong rarity", ROLLS, distinct, wrongRarity))
	if wrongRarity > 0 then
		fail("green gun rolls", string.format("%d of %d rolls were not %s", wrongRarity, ROLLS, GameModes.GreenRarity))
	elseif distinct < math.min(3, #poolIds) then
		fail("green gun rolls", string.format("only %d distinct guns over %d rolls", distinct, ROLLS))
	else
		pass("green gun rolls", string.format("%d/%d correct, %d distinct", ROLLS - wrongRarity, ROLLS, distinct))
	end

	-- The expected kit, and a synthetic GOOD loadout built from it: the real grant needs a Player,
	-- which a probe has none of, so the shape is built the way GrantLoadout builds it.
	local expected = ModeTeams.ExpectedLoadout()
	local good = { { kind = "weapon", id = poolIds[1] } }
	for _, entry in ipairs(GameModes.Loadout.items) do
		local item = ItemData.Get(entry.id)
		table.insert(good, { kind = "item", id = entry.id, count = math.min(entry.count, item.stack) })
	end
	local findings = checkLoadout(good, expected)
	if #findings == 0 then
		pass("loadout shape", string.format("%d slots: 1 gun + %d item stacks", #good, #good - 1))
	else
		fail("loadout shape", table.concat(findings, "; "))
	end
	if #good ~= GameModes.Loadout.slotsUsed then
		fail("loadout slots", string.format("%d slots used, GameModes says %d", #good, GameModes.Loadout.slotsUsed))
	else
		pass("loadout slots", string.format("%d of 8, leaving %d free", #good, 8 - #good))
	end

	-- Every item in the kit really is a heal/shield or a throwable, so "some heals, and
	-- throwables" cannot drift into something else without this saying so.
	local kinds = {}
	for _, entry in ipairs(GameModes.Loadout.items) do
		local item = ItemData.Get(entry.id)
		kinds[item and item.kind or "?"] = (kinds[item and item.kind or "?"] or 0) + 1
	end
	say(string.format("        kit kinds: heal %d, shield %d, throwable %d",
		kinds.heal or 0, kinds.shield or 0, kinds.throwable or 0))
	if (kinds.heal or 0) < 1 or (kinds.throwable or 0) < 1 then
		fail("kit kinds", "Oliver asked for heals AND throwables; one of them is missing")
	else
		pass("kit kinds", "heals present, throwables present")
	end

	-- PERMANENT PLANTED FAULT: a Rare gun, no bandages, two weapons.
	local brokenSlots = {
		{ kind = "weapon", id = "CrocodiloRifle" },
		{ kind = "weapon", id = "CrocodiloRifle" },
		{ kind = "item", id = "LowkeyLatte", count = 1 },
	}
	local brokenExpected = { weaponRarity = "Legendary", items = expected.items }
	selftest("loadout shape", #checkLoadout(brokenSlots, brokenExpected) >= 2,
		"two weapons of the wrong rarity with the heals missing")
end

--------------------------------------------------------------------------------
-- 3. KING OF THE HILL: the scoring rule
--------------------------------------------------------------------------------

-- The detector: walk the whole truth table through a holder function and report disagreements.
local function checkHolder(holder)
	local findings = {}
	local cases = {
		{ 0, 0, nil, "Open" },
		{ 1, 0, 1, "Held" },
		{ 0, 1, 2, "Held" },
		{ 1, 1, nil, "Contested" },
		{ 5, 3, nil, "Contested" },
		{ 4, 0, 1, "Held" },
	}
	for _, case in ipairs(cases) do
		local team, status = holder(case[1], case[2])
		if team ~= case[3] or status ~= case[4] then
			table.insert(findings, string.format("(%d,%d) gave %s/%s, wanted %s/%s",
				case[1], case[2], tostring(team), tostring(status), tostring(case[3]), tostring(case[4])))
		end
	end
	return findings
end

do
	local findings = checkHolder(ModeKingOfTheHill.Holder)
	if #findings == 0 then
		pass("hill holder", "6 cases: sole occupancy scores, both sides contested, empty open")
	else
		fail("hill holder", table.concat(findings, "; "))
	end

	-- PERMANENT PLANTED FAULT: a holder that lets team 1 score while contested — the single most
	-- likely way this rule goes wrong, and invisible without a truth table.
	local brokenHolder = function(one, two)
		if one > 0 then
			return 1, "Held"
		elseif two > 0 then
			return 2, "Held"
		end
		return nil, "Open"
	end
	selftest("hill holder", #checkHolder(brokenHolder) >= 1, "a holder that scores while contested")
end

--------------------------------------------------------------------------------
-- 4. FRIENDLY FIRE AND SPAWN PROTECTION
--------------------------------------------------------------------------------

do
	ModeTeams.Setup(GameModes.Modes.TeamDeathmatch, { radius = 900, dropSpots = { Vector3.zero }, river = nil })

	local a, b, c = { isBot = true, name = "A" }, { isBot = true, name = "B" }, { isBot = true, name = "C" }
	ModeTeams.Assign(a)
	ModeTeams.Assign(b)
	ModeTeams.Assign(c)
	-- a and c land on the same side (1, 2, 1 by the alternating deal); b on the other.
	local teamA, teamB, teamC = ModeTeams.TeamOf(a), ModeTeams.TeamOf(b), ModeTeams.TeamOf(c)
	say(string.format("        teams dealt: A=%d B=%d C=%d", teamA, teamB, teamC))

	local sameTeamVetoed = ModeTeams.DamageVeto(a, c)
	local crossTeamVetoed = ModeTeams.DamageVeto(a, b)
	local selfVetoed = ModeTeams.DamageVeto(a, a)

	if teamA ~= teamC then
		fail("team deal", string.format("A=%d and C=%d should share a side", teamA, teamC))
	elseif teamA == teamB then
		fail("team deal", "A and B should be on opposite sides")
	else
		pass("team deal", "alternating deal puts A and C together, B opposite")
	end

	if sameTeamVetoed and not crossTeamVetoed and not selfVetoed then
		pass("friendly fire", "same team vetoed, cross team allowed, self damage still lands")
	else
		fail("friendly fire", string.format("same=%s cross=%s self=%s (wanted true/false/false)",
			tostring(sameTeamVetoed), tostring(crossTeamVetoed), tostring(selfVetoed)))
	end

	-- PERMANENT PLANTED FAULT: the veto torn down. Same-team damage must then get through, which
	-- is what proves the check above was reading the veto and not just agreeing with itself.
	ModeTeams.Teardown()
	local vetoedWithModeOff = ModeTeams.DamageVeto(a, c)
	selftest("friendly fire", vetoedWithModeOff == false, "the veto switched off (damage got through)")
end

--------------------------------------------------------------------------------
-- 5. SPAWN PADS ON REAL GROUND
--------------------------------------------------------------------------------

do
	local MAPS = { "RotRidge", "TralalaTown", "PatapimPlains" }
	local totalPads, totalRefused = 0, 0

	-- Memory FROM THIS RUN'S OWN START. An absolute ceiling is worthless here: Studio's starting
	-- point swings by thousands of MB between runs.
	local memoryAtStart = game:GetService("Stats"):GetTotalMemoryUsageMb()
	say(string.format("        memory at probe start: %.0f MB", memoryAtStart))

	for _, mapId in ipairs(MAPS) do
		local startedAt = DateTime.now().UnixTimestampMillis
		local mapInfo = MapGenerator.Build(mapId)
		local buildSeconds = (DateTime.now().UnixTimestampMillis - startedAt) / 1000

		local centre, radius, padsOne, padsTwo = ModeTeams.Setup(GameModes.Modes.TeamDeathmatch, mapInfo)
		local sites = ModeKingOfTheHill.Start(GameModes.Modes.KingOfTheHill, mapInfo)
		local hill = ModeKingOfTheHill.Position()

		-- How near the arena comes to the next town, measured rather than assumed: the arena disc
		-- is sized off the map radius and a small map's towns sit closer together.
		local nearestTown = math.huge
		for index, spot in ipairs(mapInfo.dropSpots or {}) do
			if index > 1 then
				nearestTown = math.min(nearestTown, (Vector3.new(spot.X, 0, spot.Z) - centre).Magnitude)
			end
		end

		say(string.format("        %-15s radius %4d  arena r%3d  pads %d/%d  hill sites %d  nearest town %.0f  built in %.1fs (wall)",
			mapId, mapInfo.radius, radius, padsOne, padsTwo, sites, nearestTown, buildSeconds))

		totalPads += padsOne + padsTwo
		if padsOne == 0 or padsTwo == 0 then
			fail("spawn pads", string.format("%s: a team has no pad at all", mapId))
		end
		if not hill then
			fail("hill site", mapId .. ": no hill placed")
		end

		-- Each refusal rule, fired on purpose against this real map, so every rule is shown live
		-- rather than merely existing.
		local refusals = {
			{ "outside the arena", centre.X + radius + 200, centre.Z },
			{ "no ground", centre.X + 40000, centre.Z + 40000 },
		}
		for _, case in ipairs(refusals) do
			local why = ModeTeams.RefusePad(case[2], case[3], mapInfo.river)
			totalRefused += 1
			if why == case[1] then
				say(string.format("          refusal rule fired: %-20s -> %s", case[1], why))
			else
				fail("pad refusal", string.format("%s: wanted '%s', got '%s'", mapId, case[1], tostring(why)))
			end
		end

		-- The river rule needs a point actually in the river, so it is only exercised on maps that
		-- have one — and it says so rather than passing silently on a map with no river.
		if mapInfo.river and mapInfo.river.points and #mapInfo.river.points > 0 then
			local point = mapInfo.river.points[math.max(1, math.floor(#mapInfo.river.points / 2))]
			-- Sized so the point is inside the arena, otherwise "outside the arena" answers first.
			local moved = centre + (Vector3.new(point.X, 0, point.Z) - centre).Unit * math.min(radius - 60,
				(Vector3.new(point.X, 0, point.Z) - centre).Magnitude)
			local why = ModeTeams.RefusePad(moved.X, moved.Z, mapInfo.river)
			say(string.format("          river rule on %s: %s", mapId, tostring(why)))
		else
			say(string.format("          river rule on %s: NOT EXERCISED (no river on this map)", mapId))
		end

		MapGenerator.Clear()
		ModeKingOfTheHill.Stop()
		ModeTeams.Teardown()
	end

	say(string.format("        SAMPLE COUNT: %d maps, %d pads accepted, %d refusal rules fired",
		#MAPS, totalPads, totalRefused))
	say(string.format("        memory: +%.0f MB since probe start",
		game:GetService("Stats"):GetTotalMemoryUsageMb() - memoryAtStart))
	if totalPads > 0 then
		pass("spawn pads", string.format("%d pads over %d maps", totalPads, #MAPS))
	else
		fail("spawn pads", "no pads on any map")
	end

	-- PERMANENT PLANTED FAULT: a pad far outside the arena must be refused. If RefusePad ever
	-- starts returning nil for everything, this is what says so.
	ModeTeams.Setup(GameModes.Modes.TeamDeathmatch, { radius = 900, dropSpots = { Vector3.zero } })
	selftest("spawn pads", ModeTeams.RefusePad(99999, 99999, nil) ~= nil, "a pad 99,999 studs away")
	ModeTeams.Teardown()
end

--------------------------------------------------------------------------------
-- 6. THE CLOCK IS A WALL CLOCK
--------------------------------------------------------------------------------

do
	-- os.clock() is process CPU time in Roblox, not elapsed time. A match deadline measured with
	-- it would never arrive on a server that spends its time yielding. This measures both across
	-- a real yield and fails if the mode's clock behaves like the CPU one.
	local wallBefore = GameMode.Internal.nowMs()
	local cpuBefore = os.clock()
	task.wait(2)
	local wallDelta = GameMode.Internal.nowMs() - wallBefore
	local cpuDelta = (os.clock() - cpuBefore) * 1000

	say(string.format("        across a 2s yield: mode clock %.0f ms, os.clock %.0f ms", wallDelta, cpuDelta))
	if wallDelta >= 1900 then
		pass("wall clock", string.format("%.0f ms elapsed for a 2 s wait", wallDelta))
	else
		fail("wall clock", string.format("only %.0f ms — the mode clock is not measuring elapsed time", wallDelta))
	end

	-- PERMANENT PLANTED FAULT: the same assertion applied to os.clock, which must NOT pass it.
	-- If os.clock ever did report elapsed time this would go quiet, and that is worth knowing too.
	selftest("wall clock", cpuDelta < 1900, "os.clock standing in for elapsed time")
end

--------------------------------------------------------------------------------

say(string.format("SUMMARY %d checks, %d failures", checks, failures))
if failures > 0 then
	say("SUMMARY FAILED")
else
	say("SUMMARY OK")
end
