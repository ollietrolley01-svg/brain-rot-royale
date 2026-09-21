-- HUD & UX probe, for tools/runtest.ps1 -Probe (edit mode, no Run mode):
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/hud_ux_probe.lua
--
-- One section per feature; set ONLY to a section's name, or a set ({ compile = true, swap = true }), to
-- run just those (nil runs them all).
--
--   compile    every file the HUD & UX work touches compiles (loadstring), and every ModuleScript of
--              it requires cleanly
--   defense    the move of the placement rules into Shared/DefensePlacement changed nothing (240 sites against
--              the old code on a real map); the client preview and DefenseService.Deploy agree on 240 throws;
--              the published templates are inert and match a real build part for part; the ghost is inert
--   swap       WeaponService.SwapSlots edge cases on the real module source (remotes recorded): moving the
--              held slot, mid-reload, mid-use, empty hands, and every kind of bad request
--   ui         EventBanner, MenuStackToggle and InventoryPanel logic run for real: docking, tucking away,
--              attention, taps, swaps, refusals and the server's confirmation
--   touch      TouchControls against the owners' requirements: flag off draws nothing, the map's layout, hold and
--              press semantics on Touch objects, one End per Begin, End before a button goes, multi-touch,
--              priorities, extras, RUN toggling, and a context error still showing FIRE
--
-- Every comparison also runs once against a PLANTED FAULT (a turned finger, a bigger box, a moved part, a
-- broken SwapSlots, a dock that never comes...), which must be caught, so a PASS can't come from a check that
-- can't fail.
--   signpost   builds the real lobby and measures every signpost finger's bearing against where its
--              destination really is, found by a different method from the one LobbyService uses;
--              checks the fingers clear each other and the rest of the lobby, and that nothing
--              around the post is left flush
--
-- Every line it prints starts with "[HUDUX]"; a failed check says FAIL, and the last line counts them.

local ONLY = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

local failures = 0

local function out(fmt, ...)
	print("[HUDUX] " .. string.format(fmt, ...))
end

local function check(ok, fmt, ...)
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
	return ok
end

local function wanted(name)
	return ONLY == nil or ONLY == name or (type(ONLY) == "table" and ONLY[name] == true)
end

--------------------------------------------------------------------------------
-- compile
--------------------------------------------------------------------------------

local function probeCompile()
	local files = {
		{ Scripts, "HudClient" }, { Scripts, "MenuClient" }, { Scripts, "CombatClient" }, { Scripts, "Settings" },
		{ Modules, "WeaponService" }, { Modules, "DefenseService" }, { Modules, "LobbyService" },
		{ ServerScriptService, "Bootstrap" },
	}
	for _, name in ipairs({ "EventBanner", "InventoryPanel", "DefensePreview", "MenuStackToggle", "TouchControls" }) do
		if Scripts:FindFirstChild(name) then
			table.insert(files, { Scripts, name, true })
		end
	end
	if Shared:FindFirstChild("DefensePlacement") then
		table.insert(files, { Shared, "DefensePlacement", true })
	end
	for _, entry in ipairs(files) do
		local item = entry[1]:FindFirstChild(entry[2])
		if not item then
			check(false, "compile: %s is missing", entry[2])
		else
			local fn, err = loadstring(item.Source, item.Name)
			check(fn ~= nil, "compile: %s%s", item:GetFullName(), fn and "" or (" -> " .. tostring(err)))
			if fn and entry[3] and item:IsA("ModuleScript") then
				local ok, result = pcall(require, item)
				check(ok, "require: %s%s", item.Name, ok and "" or (" -> " .. tostring(result)))
			end
		end
	end
end

--------------------------------------------------------------------------------
-- signpost
--------------------------------------------------------------------------------

-- World-axis bounds of a part (its rotated box).
local function partBounds(part)
	local cf, half = part.CFrame, part.Size / 2
	local ex = math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z
	local ey = math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z
	local ez = math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
	local e = Vector3.new(ex, ey, ez)
	return cf.Position - e, cf.Position + e
end

-- Compass-style bearing on the lobby's ground plane, degrees clockwise from -Z.
local function bearing(direction)
	return (math.deg(math.atan2(direction.X, -direction.Z)) + 360) % 360
end

local function angleBetween(a, b)
	local d = math.abs(a - b) % 360
	return d > 180 and 360 - d or d
end

local function probeSignpost()
	local LobbyService = require(Modules:WaitForChild("LobbyService"))
	local CloudClimbCourse = require(Modules:WaitForChild("CloudClimbCourse"))
	local ZFight = require(Shared:WaitForChild("ZFight"))

	local BASE = Vector3.new(0, 2000, 0)
	local lobby = Instance.new("Folder")
	lobby.Name = "HudUxLobby"
	lobby.Parent = workspace
	local ok, err = pcall(LobbyService.Build, lobby, BASE)
	if not check(ok, "signpost: lobby built%s", ok and "" or (" -> " .. tostring(err))) then
		lobby:Destroy()
		return
	end

	-- Independent references: never the sign text or the biggest part LobbyService itself uses.
	local function groupBox(group, keep)
		local lo, hi = nil, nil
		for _, item in ipairs(lobby:GetDescendants()) do
			if item:IsA("BasePart") and item:GetAttribute("Group") == group and (not keep or keep(item)) then
				local a, b = partBounds(item)
				lo = lo and lo:Min(a) or a
				hi = hi and hi:Max(b) or b
			end
		end
		return lo and (lo + hi) / 2 or nil, lo, hi
	end
	local function named(name)
		local item = lobby:FindFirstChild(name, true)
		if not item then
			return nil
		end
		local lo, hi = partBounds(item)
		return item.Position, lo, hi
	end
	local function around(point, radius)
		return point, point - Vector3.new(radius, 0, radius), point + Vector3.new(radius, 0, radius)
	end
	local function entry(label, centre, lo, hi)
		return { label, centre, lo, hi }
	end
	local startRoot = CloudClimbCourse.elements[1].limbs[1].points[1]
	local references = {
		["ROT EXPRESS"] = entry("AirshipDeck part", named("AirshipDeck")),
		["CLOUD CLIMB"] = entry("start root (CloudClimbCourse)", around(BASE + Vector3.new(startRoot[1], 0, startRoot[3]), 3)),
		["CRATE ALTAR"] = entry("CrateAltar group box", groupBox("CrateAltar")),
		["DAILY SPIN"] = entry("DailySpin group box", groupBox("DailySpin")),
		["TRADING HALL"] = entry("TradingHall group box", groupBox("TradingHall")),
		["COSMETICS"] = entry("Cosmetics group box", groupBox("Cosmetics")),
		["THE ARENA"] = entry("Arena terrace (group box without the ramps)", groupBox("Arena", function(item)
			return item.Position.X > BASE.X + 50
		end)),
		["THE PITCH"] = entry("Pitch group box", groupBox("Pitch")),
		["WALK OF FAME"] = entry("Boards parts west of x-60 (statues and sign)", groupBox("Boards", function(item)
			return item.Position.X < BASE.X - 60
		end)),
	}

	local arrows = {}
	for _, item in ipairs(lobby:GetDescendants()) do
		if item.Name == "SignpostArrow" and item:IsA("BasePart") then
			table.insert(arrows, item)
		end
	end
	table.sort(arrows, function(a, b)
		return a.Position.Y > b.Position.Y
	end)
	check(#arrows == 9, "signpost: %d fingers (want 9)", #arrows)

	local post = BASE + Vector3.new(20, 0, 78)
	local seen = {}
	local worst = 0

	-- Whether a finger points straight at its place: within 3 degrees of the place's centre, or its line
	-- runs through the place itself (a sign in front of three statues is a fine thing to aim at).
	-- Takes anything with a CFrame and a Position, so a deliberately turned copy can be judged too.
	local function judge(arrow, reference)
		local hub = Vector3.new(post.X, arrow.Position.Y, post.Z)
		local pointing = bearing(arrow.CFrame.LookVector)
		local refPos = reference[2]
		local flat = Vector3.new(refPos.X - hub.X, 0, refPos.Z - hub.Z)
		local toRef = bearing(flat)
		local off = angleBetween(pointing, toRef)
		local miss = flat.Magnitude * math.sin(math.rad(off))
		local lo, hi = reference[3], reference[4]
		local through = false
		if lo and hi then
			local look = Vector3.new(arrow.CFrame.LookVector.X, 0, arrow.CFrame.LookVector.Z).Unit
			for step = 0, 400 do
				local p = hub + look * step
				if p.X >= lo.X - 1 and p.X <= hi.X + 1 and p.Z >= lo.Z - 1 and p.Z <= hi.Z + 1 then
					through = true
					break
				end
			end
		end
		return off <= 3 or through, pointing, toRef, flat.Magnitude, off, miss, through, hub
	end

	for _, arrow in ipairs(arrows) do
		local name = arrow:GetAttribute("Destination")
		seen[name] = true
		local reference = references[name]
		if not (reference and reference[2]) then
			check(false, "signpost: %s has no independent reference position", tostring(name))
		else
			local ok, pointing, toRef, distance, off, miss, through, hub = judge(arrow, reference)
			worst = math.max(worst, off)
			local target = arrow:GetAttribute("Target")
			local toTarget = target and bearing(Vector3.new(target.X - hub.X, 0, target.Z - hub.Z)) or -1
			check(ok and angleBetween(pointing, toTarget) <= 0.05,
				"signpost: %-12s at y%.1f points %5.1f deg; destination %5.1f deg, %3.0f studs away (%s): off by %.2f deg, passes %.1f studs from its centre, %s",
				name, arrow.Position.Y - BASE.Y, pointing, toRef, distance, reference[1], off, miss, through and "through it" or "MISSES it")
		end
		-- The board's text is on both long faces.
		local guis = 0
		for _, child in ipairs(arrow:GetChildren()) do
			if child:IsA("SurfaceGui") and child:FindFirstChildOfClass("TextLabel") and child:FindFirstChildOfClass("TextLabel").Text == name then
				guis += 1
			end
		end
		check(guis == 2, "signpost: %s has its name on %d faces (want 2)", tostring(name), guis)
	end
	for name in pairs(references) do
		check(seen[name] == true, "signpost: a finger for %s", name)
	end
	for _, gone in ipairs({ "ROT DISCO", "MARKET ROW", "CODEX" }) do
		check(not seen[gone], "signpost: no finger for %s, which isn't in the lobby", gone)
	end
	out("signpost: worst bearing error %.2f deg", worst)
	-- The check must be able to fail: every finger turned right off its place has to be caught. 45
	-- degrees, not 20: a finger pointing 20 degrees wide of a destination 30 studs across still has its
	-- line running through it, which the check counts (rightly) as pointing at the thing.
	local caught, tried, survivor = 0, 0, ""
	for _, arrow in ipairs(arrows) do
		local reference = references[arrow:GetAttribute("Destination")]
		if reference and reference[2] then
			tried += 1
			local turned = { CFrame = arrow.CFrame * CFrame.Angles(0, math.rad(45), 0), Position = arrow.Position }
			if not judge(turned, reference) then
				caught += 1
			else
				survivor = tostring(arrow:GetAttribute("Destination"))
			end
		end
	end
	check(tried > 0 and caught == tried, "signpost: planted fault: %d of %d fingers turned 45 deg off are caught%s", caught, tried,
		survivor ~= "" and (" (" .. survivor .. " still passed)") or "")

	-- Clearances. Scenery is CanQuery false, so it is switched on around the post for the queries.
	local near = {}
	for _, item in ipairs(lobby:GetDescendants()) do
		if item:IsA("BasePart") and (Vector3.new(item.Position.X, 0, item.Position.Z) - Vector3.new(post.X, 0, post.Z)).Magnitude < 16
			and item.Position.Y < BASE.Y + 20 then
			near[item] = item.CanQuery
			item.CanQuery = true
		end
	end
	local signpostParts = {}
	for item in pairs(near) do
		if item:GetAttribute("Group") == "Ambience" and (Vector3.new(item.Position.X, 0, item.Position.Z) - Vector3.new(post.X, 0, post.Z)).Magnitude < 7
			and item.Position.Y < BASE.Y + 14 then
			table.insert(signpostParts, item)
		end
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local candidates = {}
	for item in pairs(near) do
		table.insert(candidates, item)
	end
	params.FilterDescendantsInstances = candidates
	local fingerClashes, otherClashes = {}, {}
	for _, item in ipairs(signpostParts) do
		local probe = item:Clone()
		probe:ClearAllChildren()
		probe.Size = Vector3.new(math.max(0.02, item.Size.X - 0.04), math.max(0.02, item.Size.Y - 0.04), math.max(0.02, item.Size.Z - 0.04))
		probe.CanQuery = false
		probe.Transparency = 1
		probe.Parent = workspace
		for _, other in ipairs(workspace:GetPartsInPart(probe, params)) do
			if other ~= item then
				local mine = other:GetAttribute("Group") == "Ambience"
				local function round(part)
					return part:IsA("Part") and (part.Shape == Enum.PartType.Cylinder or part.Shape == Enum.PartType.Ball)
				end
				-- On purpose: every board runs into the post it hangs on, the post stands through its
				-- foot and the knob sits on its top (the round parts), and the foot stands in the paving.
				local expected = (mine and (round(item) or round(other))) or other:GetAttribute("Group") == "Island"
				if not expected then
					local key = item:GetDebugId() < other:GetDebugId() and item:GetDebugId() .. other:GetDebugId() or other:GetDebugId() .. item:GetDebugId()
					local list = mine and fingerClashes or otherClashes
					list[key] = string.format("%s @%s vs %s (%s) @%s", item.Name, tostring(item.Position - BASE), other.Name,
						tostring(other:GetAttribute("Group")), tostring(other.Position - BASE))
				end
			end
		end
		probe:Destroy()
	end
	for item, was in pairs(near) do
		item.CanQuery = was
	end
	local function listOf(map)
		local list = {}
		for _, text in pairs(map) do
			table.insert(list, text)
		end
		table.sort(list)
		return list
	end
	local fingers, others = listOf(fingerClashes), listOf(otherClashes)
	check(#fingers == 0, "signpost: fingers clear of each other (%d clashes)%s", #fingers, #fingers > 0 and (": " .. table.concat(fingers, " | ")) or "")
	check(#others == 0, "signpost: clear of every other set piece within 16 studs (%d clashes)%s", #others,
		#others > 0 and (": " .. table.concat(others, " | ")) or "")

	local flush = 0
	for _, pair in ipairs(ZFight.Scan({ lobby })) do
		for _, item in ipairs({ pair.a, pair.b }) do
			if item:IsA("BasePart") and item:GetAttribute("Group") == "Ambience" and (item.Position - post).Magnitude < 20 then
				flush += 1
			end
		end
	end
	local nudged = 0
	for _, item in ipairs(signpostParts) do
		if item:GetAttribute("ZFixed") then
			nudged += 1
		end
	end
	check(flush == 0, "signpost: %d flush faces left around the post; the lobby pass nudged %d of its %d parts", flush, nudged, #signpostParts)

	lobby:Destroy()
	local display = workspace:FindFirstChild("StageDisplay")
	if display then
		display:Destroy()
	end
end

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- defense
--------------------------------------------------------------------------------

-- DefenseService's placement code as it was before the move to Shared/DefensePlacement (2026-09-17),
-- copied verbatim from the backup, with its folder lookup passed in. The move must change nothing.
local OLD_MAX_SLOPE = 5
local OLD_THROW_RANGE = 60

local function oldGroundParams(character, defenses)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { character, defenses }
	for _, name in ipairs({ "Loot", "Companions", "Effects", "Deployables", "SupplyDrops" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	params.FilterDescendantsInstances = filter
	return params
end

local function oldFindSite(character, spec, centre, flat, defenses)
	local facing = CFrame.lookAt(Vector3.zero, flat)

	-- Ground under the centre and the corners; the lowest sets the level so nothing floats.
	local params = oldGroundParams(character, defenses)
	local low, high = math.huge, -math.huge
	local halfX, halfZ = spec.size.X / 2 - 0.5, spec.size.Z / 2 - 0.5
	for _, corner in ipairs({ { 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
		local offset = facing:VectorToWorldSpace(Vector3.new(corner[1] * halfX, 0, corner[2] * halfZ))
		local from = centre + offset + Vector3.new(0, 20, 0)
		local hit = workspace:Raycast(from, Vector3.new(0, -60, 0), params)
		if not hit then
			return nil, "No ground to build on there."
		end
		low, high = math.min(low, hit.Position.Y), math.max(high, hit.Position.Y)
	end
	if high - low > OLD_MAX_SLOPE then
		return nil, "Too steep to build there."
	end

	local origin = CFrame.new(Vector3.new(centre.X, low, centre.Z)) * facing
	-- Nothing solid may already be in the box (other players included).
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	local filter = { character }
	for _, name in ipairs({ "Loot", "Companions", "Effects", "SupplyDrops" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	overlap.FilterDescendantsInstances = filter
	local box = origin * CFrame.new(0, spec.size.Y / 2 + 0.6, 0)
	for _, part in ipairs(workspace:GetPartBoundsInBox(box, spec.size * 0.9, overlap)) do
		if part.CanCollide then
			return nil, "No room to build here."
		end
	end
	return origin
end

-- throwKit's aim maths as it was (target already SafeValue-checked).
local function oldThrow(from, look, target)
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)
	local offset = target - from
	if offset.Magnitude > OLD_THROW_RANGE then
		offset = offset.Unit * OLD_THROW_RANGE
	end
	local facing = Vector3.new(offset.X, 0, offset.Z)
	facing = facing.Magnitude > 0.5 and facing.Unit or flatLook
	return from + offset, facing
end

local function cframeClose(a, b, tolerance)
	if (a.Position - b.Position).Magnitude > tolerance then
		return false
	end
	return a.LookVector:Dot(b.LookVector) > 1 - 1e-6 and a.UpVector:Dot(b.UpVector) > 1 - 1e-6
end

local function probeDefense()
	local MapGenerator = require(Modules:WaitForChild("MapGenerator"))
	local DefenseService = require(Modules:WaitForChild("DefenseService"))
	local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
	local DefensePreview = require(Scripts:WaitForChild("DefensePreview"))
	local ItemData = require(Shared:WaitForChild("ItemData"))

	local MAP = "SahurSprings"
	math.randomseed(20260917)
	local okMap, info = pcall(MapGenerator.Build, MAP)
	if not check(okMap and info ~= nil, "defense: built map %s%s", MAP, okMap and "" or (" -> " .. tostring(info))) then
		return
	end
	task.wait(1)

	local ids = { "RotBarricade", "PopupBunker", "BrainrotFortress" }
	local specs = {}
	for _, id in ipairs(ids) do
		specs[id] = { size = DefensePlacement.Sizes[id] }
	end
	check(DefensePlacement.MaxSlope == OLD_MAX_SLOPE and DefensePlacement.ThrowRange == OLD_THROW_RANGE and DefensePlacement.LandLift == 1,
		"defense: shared constants match the old ones (slope %s, range %s, lift %s)", tostring(DefensePlacement.MaxSlope),
		tostring(DefensePlacement.ThrowRange), tostring(DefensePlacement.LandLift))
	local oldSizes = { RotBarricade = Vector3.new(12, 7.5, 1.6), PopupBunker = Vector3.new(15, 8.5, 15), BrainrotFortress = Vector3.new(21, 12, 21) }
	for id, size in pairs(oldSizes) do
		check(DefensePlacement.Sizes[id] == size, "defense: %s size %s (was %s)", id, tostring(DefensePlacement.Sizes[id]), tostring(size))
	end

	local spots = {}
	for _, list in ipairs({ info.lootSpots.weapon, info.lootSpots.heal, info.lootSpots.item, info.chestSpots }) do
		for _, spot in ipairs(list or {}) do
			table.insert(spots, typeof(spot) == "Vector3" and spot or (typeof(spot) == "CFrame" and spot.Position) or spot.position)
		end
	end
	out("defense: %d loot and chest spots to sample around", #spots)
	local random = Random.new(917)

	-- A stand-in body: the site checks leave the thrower's own character out.
	local rig = Instance.new("Model")
	rig.Name = "ProbeRig"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.Parent = rig
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(1.2, 1.2, 1.2)
	head.Anchored = true
	head.Parent = rig
	rig.PrimaryPart = root
	rig.Parent = workspace
	local function stand(position, yaw)
		root.CFrame = CFrame.new(position + Vector3.new(0, 3, 0)) * CFrame.Angles(0, yaw, 0)
		head.CFrame = root.CFrame * CFrame.new(0, 1.6, 0)
	end

	-- A few defenses already standing in town, so "no room" and the defenses folder are exercised.
	local defenses = workspace:FindFirstChild("Defenses")
	for index = 1, 6 do
		local spot = spots[random:NextInteger(1, #spots)]
		local okBuild = pcall(DefenseService.Build, ids[(index % 3) + 1], CFrame.new(spot) * CFrame.Angles(0, random:NextNumber(0, math.pi * 2), 0), nil)
		if not okBuild then
			out("defense: an obstacle build failed")
		end
	end
	defenses = workspace:FindFirstChild("Defenses")

	-- (1) The moved FindSite against the old one.
	local same, total, valid, reasons = 0, 0, 0, {}
	local mismatches = {}
	-- The comparison must be able to fail: a copy checking a box a quarter too big has to disagree.
	local plantedDiffer = 0
	for sample = 1, 240 do
		local spot = spots[random:NextInteger(1, #spots)]
		local centre = spot + Vector3.new(random:NextNumber(-25, 25), random:NextNumber(0, 3), random:NextNumber(-25, 25))
		local angle = random:NextNumber(0, math.pi * 2)
		local flat = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local id = ids[(sample % 3) + 1]
		stand(centre + Vector3.new(random:NextNumber(-8, 8), 0, random:NextNumber(-8, 8)), angle)
		local oldOrigin, oldReason = oldFindSite(rig, specs[id], centre, flat, defenses)
		local newOrigin, newReason = DefensePlacement.FindSite(rig, specs[id].size, centre, flat, defenses)
		local badOrigin, badReason = DefensePlacement.FindSite(rig, specs[id].size * 1.25, centre, flat, defenses)
		if (oldOrigin == nil) ~= (badOrigin == nil) or oldReason ~= badReason or (oldOrigin and not cframeClose(oldOrigin, badOrigin, 1e-4)) then
			plantedDiffer += 1
		end
		total += 1
		local agree = (oldOrigin == nil) == (newOrigin == nil) and oldReason == newReason
			and (oldOrigin == nil or cframeClose(oldOrigin, newOrigin, 1e-4))
		if agree then
			same += 1
		elseif #mismatches < 5 then
			table.insert(mismatches, string.format("%s at %s: old %s/%s new %s/%s", id, tostring(centre), tostring(oldOrigin and oldOrigin.Position),
				tostring(oldReason), tostring(newOrigin and newOrigin.Position), tostring(newReason)))
		end
		if newOrigin then
			valid += 1
		else
			reasons[newReason] = (reasons[newReason] or 0) + 1
		end
	end
	local reasonText = {}
	for reason, count in pairs(reasons) do
		table.insert(reasonText, string.format("%q x%d", reason, count))
	end
	table.sort(reasonText)
	check(same == total, "defense: FindSite moved unchanged: %d of %d sites agree with the old code (%d buildable; refused: %s)%s",
		same, total, valid, table.concat(reasonText, ", "), #mismatches > 0 and (" | " .. table.concat(mismatches, " | ")) or "")
	check(valid >= 20 and plantedDiffer >= 10, "defense: planted fault: a 25%%-bigger box disagrees with the old code on %d of %d sites (and %d sites were buildable, so both outcomes were sampled)",
		plantedDiffer, total, valid)

	-- (1b) The lob, in two parts. First the shape: whatever the constants are, the velocity ThrowArc
	-- hands out must actually put the kit on the target after its flight time -- that is the whole claim
	-- the preview's traced arc rests on. Then the constants themselves, so a change to how far the kit is
	-- thrown or how high it arcs is a deliberate edit with a failing test, not a silent drift.
	local worstThrow, worstThrowWhat = 0, ""
	local gravity = workspace.Gravity
	for sample = 1, 200 do
		local from = Vector3.new(random:NextNumber(-50, 50), random:NextNumber(0, 20), random:NextNumber(-50, 50))
		local look = CFrame.Angles(random:NextNumber(-0.6, 0.4), random:NextNumber(0, 6.28), 0).LookVector
		local aim = from + look * random:NextNumber(3, 140) + Vector3.new(0, random:NextNumber(-20, 10), 0)
		local velocity, flightTime, target, facing = DefensePlacement.ThrowArc(from, look, aim)
		local arrives = from + velocity * flightTime - Vector3.new(0, 0.5 * gravity * flightTime * flightTime, 0)
		local oldTarget, oldFacing = oldThrow(from, look, aim)
		local gaps = {
			{ "the arc misses its own target", (arrives - target).Magnitude },
			{ "target", (target - oldTarget).Magnitude },
			{ "facing", (facing - oldFacing).Magnitude },
		}
		for _, gap in ipairs(gaps) do
			if gap[2] > worstThrow then
				worstThrow, worstThrowWhat = gap[2], gap[1]
			end
		end
	end
	check(worstThrow < 1e-3, "defense: the lob lands on its own target, and the range and facing are the old ones, over 200 throws (worst: %s, %.6f)",
		worstThrowWhat, worstThrow)
	check(DefensePlacement.ThrowSpeed == 40 and DefensePlacement.ThrowMinTime == 0.5 and DefensePlacement.ThrowMaxTime == 1.6,
		"defense: the throw's constants are the shipped ones (speed %s, %s to %s seconds) -- change this check deliberately when the arc changes",
		tostring(DefensePlacement.ThrowSpeed), tostring(DefensePlacement.ThrowMinTime), tostring(DefensePlacement.ThrowMaxTime))

	-- (2) The client's whole prediction (DefensePreview.Site) against the server's own placement rules,
	-- asked to build where the preview says the throw will arrive.
	local agreeCount, chain, builtCount, worstMiss = 0, 0, 0, 0
	local chainMismatches = {}
	-- Planted fault: a preview whose site is checked 2.5 studs to the side must stop matching real builds.
	local shiftedWrong = 0
	for sample = 1, 240 do
		local spot = spots[random:NextInteger(1, #spots)]
		local yaw = random:NextNumber(0, math.pi * 2)
		stand(spot, yaw)
		local look = root.CFrame.LookVector
		local aim
		if sample % 4 == 0 then
			-- Straight along the view with a random pitch: walls, roofs, the sky.
			local pitch = math.rad(random:NextNumber(-40, 10))
			local direction = (CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0)).LookVector
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { rig }
			local hit = workspace:Raycast(head.Position, direction * 300, params)
			aim = hit and hit.Position or head.Position + direction * 300
		else
			-- A point on the ground somewhere ahead, near or well past the throw range.
			local ahead = spot + (CFrame.Angles(0, yaw + random:NextNumber(-0.6, 0.6), 0).LookVector) * random:NextNumber(3, 85)
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { rig }
			local hit = workspace:Raycast(ahead + Vector3.new(0, 80, 0), Vector3.new(0, -200, 0), params)
			aim = hit and hit.Position or ahead
		end
		local id = ids[(sample % 3) + 1]
		local predicted = DefensePreview.Site(rig, id, aim, {})

		-- The server is asked to build where the preview says the kit will arrive: the preview now walks
		-- the throw's arc (it is flat enough to clip a hill, so the aim point is not where it lands), and
		-- what this checks is that the two agree about the SITE at a given landing spot -- the property
		-- that the placement rules are shared. Where the kit really ends up is measured with physics in
		-- the gallery's `grip` section instead, which is the only honest way to ask that.
		local facing = predicted and predicted.facing or Vector3.new(0, 0, -1)
		local centre = predicted and predicted.centre or (aim + Vector3.new(0, 1, 0))
		local owner = { UserId = -1000 - sample, Name = "ProbeOwner" }
		local okDeploy, model, reason = pcall(DefenseService.Deploy, owner, rig, id, centre, facing)
		if not okDeploy then
			-- A remote firing in edit mode can throw after the build; find the build itself.
			model, reason = nil, nil
			for _, child in ipairs(workspace:FindFirstChild("Defenses") and workspace.Defenses:GetChildren() or {}) do
				if child:GetAttribute("OwnerUserId") == owner.UserId then
					model = child
				end
			end
		end
		chain += 1
		local serverOrigin = nil
		if model and model.PrimaryPart then
			builtCount += 1
			serverOrigin = model.PrimaryPart.CFrame * CFrame.new(0, -(DefensePlacement.Sizes[id].Y + 0.5), 0)
		end
		local agree = predicted ~= nil and (predicted.origin == nil) == (serverOrigin == nil)
			and (predicted.origin == nil and (not okDeploy or predicted.reason == reason) or (predicted.origin and cframeClose(predicted.origin, serverOrigin, 1e-3)))
		if predicted and predicted.origin and serverOrigin then
			worstMiss = math.max(worstMiss, (predicted.origin.Position - serverOrigin.Position).Magnitude)
		end
		if predicted and predicted.size and serverOrigin then
			local shifted = DefensePlacement.FindSite(rig, predicted.size, predicted.centre + Vector3.new(2.5, 0, 0), predicted.facing,
				workspace:FindFirstChild("Defenses"), {})
			if not shifted or not cframeClose(shifted, serverOrigin, 1e-3) then
				shiftedWrong += 1
			end
		end
		if agree then
			agreeCount += 1
		elseif #chainMismatches < 5 then
			table.insert(chainMismatches, string.format("%s aim %s: preview %s/%s server %s/%s", id, tostring(aim),
				tostring(predicted and predicted.origin and predicted.origin.Position), tostring(predicted and predicted.reason),
				tostring(serverOrigin and serverOrigin.Position), tostring(reason)))
		end
		if model then
			model:Destroy()
		end
	end
	check(agreeCount == chain, "defense: preview and server agree on %d of %d throws (%d built; worst position gap %.4f studs)%s",
		agreeCount, chain, builtCount, worstMiss, #chainMismatches > 0 and (" | " .. table.concat(chainMismatches, " | ")) or "")
	check(builtCount >= 20 and shiftedWrong == builtCount, "defense: planted fault: a preview checked 2.5 studs aside disagrees with %d of %d real builds",
		shiftedWrong, builtCount)

	-- (3) The published templates: inert, outside the workspace, and the same geometry as a real build.
	local before = workspace:FindFirstChild("Defenses") and #workspace.Defenses:GetChildren() or 0
	local okPublish, templates = pcall(DefenseService.PublishTemplates)
	check(okPublish and templates and templates.Parent == ReplicatedStorage, "defense: templates published to ReplicatedStorage.DefenseTemplates%s",
		okPublish and "" or (" -> " .. tostring(templates)))
	if not okPublish or not templates then
		rig:Destroy()
		MapGenerator.Clear()
		return
	end
	local after = workspace:FindFirstChild("Defenses") and #workspace.Defenses:GetChildren() or 0
	check(before == after, "defense: publishing left the live defenses alone (%d before, %d after)", before, after)
	for _, id in ipairs(ids) do
		local template = templates:FindFirstChild(id)
		if not check(template ~= nil, "defense: template %s exists", id) then
			continue
		end
		local parts, live, extras = {}, 0, {}
		for _, item in ipairs(template:GetDescendants()) do
			if item:IsA("BasePart") then
				table.insert(parts, item)
				if item.CanCollide or item.CanQuery or item.CanTouch or not item.Anchored then
					live += 1
				end
				if DefenseService.StructureFromPart(item) then
					live += 1
				end
			elseif not item:IsA("Model") then
				table.insert(extras, item.ClassName)
			end
		end
		check(live == 0 and #extras == 0, "defense: template %s is inert (%d parts; %d live flags; extras: %s)", id, #parts, live,
			#extras > 0 and table.concat(extras, ",") or "none")

		-- Real builds compared part for part relative to their origin: one at the world origin, where it
		-- must be exact (the same builders, the same z-fight pass), and one far away and turned, where the
		-- z-fight pass's hundredth-of-a-stud nudges may land a little differently in world space.
		-- The third number is how far a part may be out of place, the fourth how much its SIZE may differ.
		-- Far from the origin and turned, the z-fight pass (which nudges parts apart in world space) grows
		-- a couple of them by up to an eighth of a stud, so sizes get more room there and positions do not.
		for _, trial in ipairs({ { "at the origin", CFrame.new(), 2e-3, 2e-3 },
				{ "far away and turned", CFrame.new(0, 900, 4000) * CFrame.Angles(0, math.rad(33), 0), 0.08, 0.15 } }) do
			local origin, tolerance, sizeTolerance = trial[2], trial[3], trial[4]
			local model = DefenseService.Build(id, origin, nil)
			task.wait(1)
			local built = {}
			for _, item in ipairs(model:GetDescendants()) do
				if item:IsA("BasePart") and item.Name ~= "Core" then
					table.insert(built, item)
				end
			end
			-- Matches each built part to a template part of the same class, colour and material, near in
			-- size and place; returns how many found none, and the worst gap among those that did.
			-- Sorted by how far off they are, so the closest sensible pairing is made first: a greedy
			-- nearest-first walk over the built parts mis-pairs two identical parts that sit near each
			-- other and then reports both as missing.
			local function unmatchedAt(lift)
				local used, worstGap, missing = {}, 0, {}
				local pairsFound = {}
				for partIndex, part in ipairs(built) do
					local relative = CFrame.new(0, lift, 0) * origin:ToObjectSpace(part.CFrame)
					for index, candidate in ipairs(parts) do
						if candidate.ClassName == part.ClassName and candidate.Color == part.Color and candidate.Material == part.Material
							and candidate.CFrame.LookVector:Dot(relative.LookVector) > 1 - 1e-3 and candidate.CFrame.UpVector:Dot(relative.UpVector) > 1 - 1e-3 then
							-- A part matches when it is in the right place AND about the right size; the size is
							-- allowed its own slack, so the gap reported is still the distance.
							local sizeGap = (candidate.Size - part.Size).Magnitude
							local gap = (candidate.Position - relative.Position).Magnitude
							if sizeGap > sizeTolerance then
								gap = math.huge
							end
							if gap <= tolerance then
								table.insert(pairsFound, { gap = gap, part = partIndex, template = index })
							end
						end
					end
				end
				table.sort(pairsFound, function(a, b)
					return a.gap < b.gap
				end)
				local takenPart = {}
				for _, pair in ipairs(pairsFound) do
					if not takenPart[pair.part] and not used[pair.template] then
						takenPart[pair.part] = true
						used[pair.template] = true
						worstGap = math.max(worstGap, pair.gap)
					end
				end
				for partIndex, part in ipairs(built) do
					if not takenPart[partIndex] then
						local relative = CFrame.new(0, lift, 0) * origin:ToObjectSpace(part.CFrame)
						-- Why it found nothing: the nearest template part of any kind, and what differs.
						local best, why = math.huge, "nothing near"
						for _, candidate in ipairs(parts) do
							local gap = (candidate.Position - relative.Position).Magnitude
							if gap < best then
								best = gap
								why = string.format("nearest is %.3f away", gap)
								if candidate.Color ~= part.Color then
									why = why .. ", a different colour"
								elseif candidate.Material ~= part.Material then
									why = why .. ", a different material"
								elseif (candidate.Size - part.Size).Magnitude > sizeTolerance then
									why = why .. string.format(", %.3f bigger", (candidate.Size - part.Size).Magnitude)
								elseif candidate.CFrame.LookVector:Dot(relative.LookVector) <= 1 - 1e-3 then
									why = why .. ", turned"
								end
							end
						end
						table.insert(missing, string.format("%s %s (%s)", part.ClassName, part.Name, why))
					end
				end
				return #missing, worstGap, table.concat(missing, "; ", 1, math.min(3, #missing))
			end
			local settled, settledGap, settledWhy = unmatchedAt(0)
			local lowered, loweredGap, loweredWhy = unmatchedAt(DefensePlacement.Sizes[id].Y)
			local unmatched = math.min(settled, lowered)
			local gap = lowered < settled and loweredGap or settledGap
			local why = lowered < settled and loweredWhy or settledWhy
			check(#built == #parts and unmatched == 0,
				"defense: template %s matches a real build %s: %d parts vs %d built, %d unmatched, worst gap %.4f studs (allowed %.3f) %s",
				id, trial[1], #parts, #built, unmatched, gap, tolerance, why ~= "" and ("-- " .. why) or "")
			if trial[1] == "at the origin" and #parts > 0 then
				-- Planted fault: one template part half a stud out of place must be caught. The extra
				-- brackets keep `math.min` from also seeing the second and third return values.
				local moved = parts[1]
				moved.CFrame += Vector3.new(0.5, 0, 0)
				local plantedUnmatched = math.min((unmatchedAt(0)), (unmatchedAt(DefensePlacement.Sizes[id].Y)))
				moved.CFrame -= Vector3.new(0.5, 0, 0)
				check(plantedUnmatched >= 1, "defense: planted fault: template %s with one part moved 0.5 studs leaves %d unmatched", id, plantedUnmatched)
			end
			model:Destroy()
		end
	end

	-- (4) The ghost itself: built from the template, see-through, nothing live.
	local preview = DefensePreview.new()
	local spot = spots[1]
	stand(spot, 0)
	preview:Update(rig, "PopupBunker", spot + Vector3.new(0, 0, -20), {})
	local ghostParts, liveGhost = 0, 0
	for _, item in ipairs(preview.root:GetDescendants()) do
		if item:IsA("BasePart") then
			ghostParts += 1
			if item.CanCollide or item.CanQuery or item.CanTouch then
				liveGhost += 1
			end
		end
	end
	check(preview.ghost ~= nil and liveGhost == 0, "defense: the preview draws %d parts (ghost %s), none of them collide, query or touch",
		ghostParts, preview.ghost and "built" or "MISSING")
	preview:Destroy()

	rig:Destroy()
	DefenseService.Clear()
	MapGenerator.Clear()
	templates:Destroy()
end

--------------------------------------------------------------------------------
-- swap
--------------------------------------------------------------------------------

-- WeaponService.SwapSlots edge cases, on the real WeaponService source. A loadout push is a FireClient,
-- which needs a real Player, and edit mode has none; so the module's source is loaded here with its
-- Remotes swapped for recorders. Everything else (PlayerData, QuestService, the gun models) is real.
local function probeSwap(sourceOverride, quiet)
	local module = Modules:WaitForChild("WeaponService")
	local chunk, err = loadstring(sourceOverride or module.Source, "WeaponService")
	if not check(chunk ~= nil, "swap: WeaponService source loads%s", chunk and "" or (" -> " .. tostring(err))) then
		return
	end
	local pushes = 0
	local stubRemotes = {
		Event = function()
			return {
				FireClient = function()
					pushes += 1
				end,
				FireAllClients = function() end,
			}
		end,
		Function = function()
			return {}
		end,
	}
	local remotesModule = Shared:WaitForChild("Remotes")
	setfenv(chunk, setmetatable({
		script = module,
		require = function(target)
			if target == remotesModule then
				return stubRemotes
			end
			return require(target)
		end,
	}, { __index = getfenv(1) }))
	local okLoad, WS = pcall(chunk)
	if not check(okLoad and type(WS) == "table" and type(WS.SwapSlots) == "function", "swap: WeaponService runs with recording remotes%s",
		okLoad and "" or (" -> " .. tostring(WS))) then
		return
	end
	local WeaponData = require(Shared:WaitForChild("WeaponData"))
	local ItemData = require(Shared:WaitForChild("ItemData"))

	-- A body with a humanoid, so heals have someone to heal.
	local rig = Instance.new("Model")
	rig.Name = "SwapProbeRig"
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(0, 3000, 0)
	root.Parent = rig
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = rig
	rig.PrimaryPart = root
	rig.Parent = workspace
	local player = { Name = "SwapProbe", UserId = -4242, Character = rig }

	-- Two guns with different reload times, an item stack, and room.
	local gunA, gunB = "CrocodiloRifle", "SahurPistol"
	local defA, defB = WeaponData.Get(gunA), WeaponData.Get(gunB)
	local function fresh()
		WS.Reset(player)
		WS.GiveWeapon(player, gunA) -- slot 1, held
		WS.GiveWeapon(player, gunB) -- slot 2
		WS.GiveConsumable(player, "Bandage", 5) -- slot 3
		return WS.Get(player)
	end

	-- 1. Two slots neither of which is in hand.
	local l = fresh()
	local s2, s3 = l.slots[2], l.slots[3]
	local before = pushes
	local ok = WS.SwapSlots(player, 2, 3)
	check(ok and l.slots[2] == s3 and l.slots[3] == s2 and l.equipped == 1 and pushes == before + 1,
		"swap: 2<->3 swaps the tables, leaves slot 1 in hand, one push (ok %s, equipped %s, pushes +%d)", tostring(ok), tostring(l.equipped), pushes - before)

	-- 2. The held slot with a filled one: what's in hand stays in hand, no re-raise.
	l = fresh()
	local held = l.slots[1]
	local readyAt = l.equipReadyAt
	task.wait(0.05)
	ok = WS.SwapSlots(player, 1, 3)
	check(ok and l.equipped == 3 and l.slots[3] == held and l.equipReadyAt == readyAt and WS.GetEquipped(player) == defA,
		"swap: held 1<->3 moves the rifle to 3 and keeps it in hand, raise untouched (equipped %s, def %s)", tostring(l.equipped),
		tostring(WS.GetEquipped(player) and WS.GetEquipped(player).name))

	-- 3. Into an empty slot.
	l = fresh()
	held = l.slots[1]
	ok = WS.SwapSlots(player, 1, 8)
	check(ok and l.slots[1] == nil and l.slots[8] == held and l.equipped == 8, "swap: held 1 -> empty 8 moves it (slot1 %s, equipped %s)",
		tostring(l.slots[1]), tostring(l.equipped))

	-- 4. Mid-reload, moving the gun being reloaded: the reload still finishes, on that gun.
	l = fresh()
	held = l.slots[1]
	held.mag = 3
	local reserveBefore = held.reserve
	WS.Reload(player)
	local reloadingNow = l.reloading
	ok = WS.SwapSlots(player, 1, 4)
	task.wait((defA.reloadTime or 1.5) + 0.3)
	check(reloadingNow and ok and not l.reloading and held.mag == defA.magSize and held.reserve == reserveBefore - (defA.magSize - 3) and l.slots[4] == held,
		"swap: reload in progress survives moving the gun (mag %d/%d, reserve %d -> %d, reloading %s)", held.mag, defA.magSize, reserveBefore,
		held.reserve, tostring(l.reloading))

	-- 5. Mid-reload, swapping two other slots: the reload finishes too.
	l = fresh()
	held = l.slots[1]
	held.mag = 1
	WS.Reload(player)
	ok = WS.SwapSlots(player, 2, 3)
	task.wait((defA.reloadTime or 1.5) + 0.3)
	check(ok and held.mag == defA.magSize and not l.reloading, "swap: reload finishes when other slots swap (mag %d/%d)", held.mag, defA.magSize)

	-- 6. A timed use on a slot that moves is cancelled, and nothing is spent.
	l = fresh()
	humanoid.MaxHealth = 100
	humanoid.Health = 40
	WS.Equip(player, 3)
	task.wait(0.6)
	local bandage = ItemData.Get("Bandage")
	local started = WS.StartUse(player, nil)
	local usingNow = l.using ~= nil
	local stack = l.slots[3]
	ok = WS.SwapSlots(player, 3, 6)
	task.wait((bandage.useTime or 2.5) + 0.3)
	check(started and usingNow and ok and l.using == nil and stack.count == 5 and humanoid.Health == 40 and l.equipped == 6,
		"swap: a bandage mid-use on the moved slot is cancelled, not spent (started %s, count %d, health %.0f)", tostring(started), stack.count, humanoid.Health)

	-- 7. A timed use while two other slots swap finishes normally.
	l = fresh()
	humanoid.Health = 40
	WS.Equip(player, 3)
	task.wait(0.6)
	started = WS.StartUse(player, nil)
	stack = l.slots[3]
	ok = WS.SwapSlots(player, 1, 2)
	task.wait((bandage.useTime or 2.5) + 0.3)
	check(started and ok and stack.count == 4 and humanoid.Health > 40, "swap: a use on an untouched slot still finishes (count %d, health %.0f)",
		stack.count, humanoid.Health)

	-- 8. Refusals change nothing and push nothing.
	l = fresh()
	local snapshot = table.clone(l.slots)
	local equippedBefore = l.equipped
	before = pushes
	local refusals = {
		{ 1, 1 }, { 0, 2 }, { 1, 9 }, { 1.5, 2 }, { 0 / 0, 2 }, { math.huge, 1 }, { -1, 2 }, { "1", 2 }, { nil, 2 }, { 5, 7 },
	}
	local allRefused = true
	for _, pair in ipairs(refusals) do
		local okPair, result = pcall(WS.SwapSlots, player, pair[1], pair[2])
		if not okPair or result ~= false then
			allRefused = false
			out("swap: %s <-> %s was not refused cleanly (%s, %s)", tostring(pair[1]), tostring(pair[2]), tostring(okPair), tostring(result))
		end
	end
	local unchanged = l.equipped == equippedBefore
	for index = 1, 8 do
		if l.slots[index] ~= snapshot[index] then
			unchanged = false
		end
	end
	check(allRefused and unchanged and pushes == before, "swap: %d bad requests (same slot, 0, 9, 1.5, NaN, inf, -1, a string, nil, two empties) refused, loadout unchanged, no pushes",
		#refusals)
	local okNone, resultNone = pcall(WS.SwapSlots, { Name = "Nobody" }, 1, 2)
	check(okNone and resultNone == false, "swap: a player with no loadout is refused")

	-- 9. The hand is empty (the stack in it was used up): the selection follows, nothing breaks.
	l = fresh()
	l.slots[1] = nil
	ok = WS.SwapSlots(player, 1, 2)
	check(ok and l.equipped == 2 and l.slots[2] == nil and l.slots[1] ~= nil, "swap: an empty hand stays empty (equipped %s)", tostring(l.equipped))

	-- 10. After a move, firing and equipping use the new numbers.
	l = fresh()
	held = l.slots[1]
	WS.SwapSlots(player, 1, 5)
	local magBefore = held.mag
	task.wait(0.6)
	WS.ConsumeAmmo(player)
	WS.Equip(player, 5)
	check(held.mag == magBefore - 1 and l.equipped == 5, "swap: firing after a move spends the moved gun's ammo (%d -> %d), equipping it again is a no-op",
		magBefore, held.mag)

	WS.Clear(player)
	rig:Destroy()
end

-- The swap checks must be able to fail. The real source with the held slot's number NOT moving along
-- with it (the one line that keeps what's in hand in hand) is run through the same checks, which must
-- report failures; its results are counted apart from the real ones.
local function probeSwapPlanted()
	local source = Modules:WaitForChild("WeaponService").Source
	-- No newline in the pattern: the source arrives with whatever line endings the file has (it was
	-- CRLF in the place the day this was written, LF in the working copy), and matching on one of them
	-- silently stopped planting the fault at all.
	local broken, replaced = string.gsub(source, "loadout%.equipped = b", "loadout.equipped = a", 1)
	if not check(replaced == 1, "swap: planted fault: found the line that moves the held slot's number") then
		return
	end
	local before = failures
	local realOut = out
	out = function() end
	local ok = pcall(probeSwap, broken, true)
	out = realOut
	local caught = failures - before
	failures = before
	check(ok and caught >= 2, "swap: planted fault: with the held slot's number left behind, %d swap checks fail (want 2 or more)", caught)
end

--------------------------------------------------------------------------------
-- ui
--------------------------------------------------------------------------------

-- The UI modules' logic, run for real (tweens and timers included) on GUIs parented under StarterGui:
-- the event card docking into the pill and back, the menu stack tucking away and its attention dot,
-- and the Inventory panel's taps, swaps and refusals. Each has a planted fault that must be caught.
local function probeUi()
	local StarterGui = game:GetService("StarterGui")
	local gui = Instance.new("ScreenGui")
	gui.Name = "HudUxProbeGui"
	gui.Parent = StarterGui
	local screen = Instance.new("Frame")
	screen.Size = UDim2.fromOffset(1920, 1080)
	screen.BackgroundTransparency = 1
	screen.Parent = gui

	-- EventBanner ---------------------------------------------------------------
	local EventBanner = require(Scripts:WaitForChild("EventBanner"))
	local announced = 0
	local banner = EventBanner.new(screen, {
		onAnnounce = function()
			announced += 1
		end,
	})
	banner:SetViewport(Vector2.new(1920, 1080))
	local event = { id = "LowGravity", name = "Low Gravity", description = "Half gravity.", color = Color3.fromRGB(200, 150, 255) }
	banner:SetTimer("drop", 75)
	banner:Announce(event)
	task.wait(0.1)
	check(banner.phase == "card" and banner.card.Visible and not banner.pill.Visible and announced == 1,
		"ui: event announced: card up, pill hidden, sound once (phase %s, announced %d)", tostring(banner.phase), announced)
	check(banner.timerValue.Text == "1:15" and banner.timerLabel.Text == "DROP IN", "ui: event timer reads %s %s (want DROP IN 1:15)",
		banner.timerLabel.Text, banner.timerValue.Text)
	task.wait(EventBanner.Hold + 0.7)
	check(banner.phase == "pill" and banner.pill.Visible and not banner.card.Visible and banner.pillButton.Visible,
		"ui: after %.1fs the card has docked into the pill (phase %s)", EventBanner.Hold, tostring(banner.phase))
	local slotY = banner.pill.Position.Y.Offset
	banner:SetDock("below")
	check(banner.pill.Position.Y.Offset > slotY, "ui: the pill moves under the READY pill when that shows (y %d -> %d)", slotY,
		banner.pill.Position.Y.Offset)
	banner:Expand()
	task.wait(0.1)
	check(banner.phase == "card" and banner.card.Visible, "ui: tapping the pill brings the card back (phase %s)", tostring(banner.phase))
	banner:Dock()
	task.wait(0.6)
	check(banner.phase == "pill" and not banner.card.Visible, "ui: the drop screen docks it at once (phase %s)", tostring(banner.phase))
	banner:Clear()
	check(not banner.card.Visible and not banner.pill.Visible and not banner.pillButton.Visible, "ui: no event: card, pill and its button all hidden")
	-- Planted fault: with a hold far longer than the wait, the same docking check must fail.
	local realHold = EventBanner.Hold
	EventBanner.Hold = 60
	banner:Announce(event)
	task.wait(realHold + 0.7)
	check(banner.phase == "card", "ui: planted fault: with a 60s hold the card is still up after %.1fs, so the docking check can fail",
		realHold + 0.7)
	EventBanner.Hold = realHold
	banner:Clear()

	-- MenuStackToggle -------------------------------------------------------------
	local MenuStackToggle = require(Scripts:WaitForChild("MenuStackToggle"))
	local menuButton = Instance.new("TextButton")
	menuButton.Position = UDim2.new(0, 16, 0, 130)
	menuButton.Size = UDim2.fromOffset(210, 42)
	menuButton.Parent = screen
	local tracker = Instance.new("TextButton")
	tracker.Position = UDim2.new(0, 16, 0, 224)
	tracker.Size = UDim2.fromOffset(250, 120)
	tracker.Parent = screen
	-- A stand-in for Settings: Get and Set on one toggle, and a Changed event.
	local changed = Instance.new("BindableEvent")
	local store = {}
	local fakeSettings = {
		Changed = changed.Event,
		Get = function(id)
			return store[id]
		end,
		Set = function(id, value)
			store[id] = value
			changed:Fire(id)
		end,
	}
	local toggle = MenuStackToggle.new(screen, { items = { menuButton, tracker }, settings = fakeSettings })
	check(menuButton.Parent == toggle.stack and menuButton.Position.Y.Offset == 130 - 124 and tracker.Position.Y.Offset == 224 - 124,
		"ui: the stack's items move into its group without moving on screen (menu y %d, tracker y %d)", menuButton.Position.Y.Offset,
		tracker.Position.Y.Offset)
	toggle:SetCollapsed(true, false, true)
	task.wait(0.45)
	check(toggle.collapsed and not toggle.stack.Visible and store[MenuStackToggle.SettingId] == true and toggle.tab.Position.X.Offset == 16,
		"ui: tucking away hides the stack, saves the setting and puts the tab at x 16 (stack visible %s, saved %s, tab x %d)",
		tostring(toggle.stack.Visible), tostring(store[MenuStackToggle.SettingId]), toggle.tab.Position.X.Offset)
	toggle:Attention()
	check(toggle.dot.Visible and toggle.pending, "ui: something new while tucked away lights the dot")
	fakeSettings.Set(MenuStackToggle.SettingId, false)
	task.wait(0.45)
	check(not toggle.collapsed and toggle.stack.Visible and not toggle.dot.Visible and not toggle.pending,
		"ui: the setting coming back false (a RESET) brings the stack back and clears the dot")
	toggle:Attention()
	check(not toggle.dot.Visible, "ui: while the stack is out, nothing new lights a dot")
	task.wait(1.6)
	check(toggle.tabStroke.Thickness == 1.5, "ui: the expanded tab's outline is back to 1.5 after any pulse (got %.1f)", toggle.tabStroke.Thickness)
	-- Planted fault: the same call with collapsed forced on must light the dot, so the check above can fail.
	toggle.collapsed = true
	toggle:Attention()
	check(toggle.dot.Visible, "ui: planted fault: forcing collapsed makes the same call light the dot")
	toggle.collapsed = false
	toggle.pending = false

	-- InventoryPanel --------------------------------------------------------------
	local InventoryPanel = require(Scripts:WaitForChild("InventoryPanel"))
	local swaps = {}
	local closedByPanel = 0
	local panel = InventoryPanel.new(screen, {
		onSwap = function(a, b)
			table.insert(swaps, { a, b })
		end,
		onClose = function()
			closedByPanel += 1
		end,
	})
	local full = InventoryPanel.ScaleFor(Vector2.new(1920, 1080))
	panel:SetViewport(Vector2.new(1920, 1080))
	local gunA = { kind = "weapon", id = "SahurPistol", name = "Sahur Pistol", rarity = "Common", mag = 10, magSize = 15, reserve = 60 }
	local bandage = { kind = "item", id = "Bandage", name = "Bandage", rarity = "Common", count = 4 }
	local loadout = { slots = { gunA, false, bandage, false, false, false, false, false }, equipped = 1 }
	panel:Open(loadout)
	task.wait(0.4)
	check(panel:IsOpen() and panel.root.Visible and math.abs(panel.scale.Scale - full) < 1e-3, "ui: inventory opens at its full size (scale %.3f)",
		panel.scale.Scale)
	panel:Close()
	panel:Open(loadout)
	panel:Close()
	panel:Open(loadout)
	task.wait(0.4)
	check(math.abs(panel.scale.Scale - full) < 1e-3, "ui: opening again mid-animation still settles at full size (scale %.3f, want %.3f)",
		panel.scale.Scale, full)
	panel:_tap(2)
	check(panel.selected == nil and #swaps == 0, "ui: tapping an empty slot with nothing picked does nothing")
	panel:_tap(1)
	check(panel.selected == 1, "ui: tapping a filled slot picks it")
	panel:_tap(1)
	check(panel.selected == nil and #swaps == 0, "ui: tapping it again puts it back")
	panel:_tap(1)
	panel:_tap(5)
	local shownAtOnce = #swaps == 1 and swaps[1][1] == 1 and swaps[1][2] == 5 and panel.shownSlots ~= nil and panel.shownSlots[5] == gunA
		and panel.shownSlots[1] == false and panel.shownEquipped == 5
	check(shownAtOnce, "ui: tap 1 then 5 asks the server to swap 1 and 5, and shows the gun (still in hand) in 5 at once")
	task.wait(1.1)
	check(panel.shownSlots == nil and panel.cards[1].tag.Visible, "ui: no answer from the server: the panel goes back to what it last said")
	panel:_swap(3, 3)
	panel:_swap(2, 4)
	check(#swaps == 1, "ui: a slot onto itself, or two empty slots, sends nothing (%d requests)", #swaps)
	panel:_tap(3)
	panel:_tap(1)
	local confirmed = { slots = { bandage, false, gunA, false, false, false, false, false }, equipped = 3 }
	panel:SetLoadout(confirmed)
	task.wait(1.1)
	check(#swaps == 2 and panel.shownSlots == nil and panel.cards[3].tag.Visible and panel.cards[1].name.Text == "Bandage",
		"ui: the server's push confirming the swap is what's shown, and it stays")
	-- THE CURSOR. In a match the mouse is locked to the centre, so a panel that does not free it cannot
	-- be used at all -- which is how this was found, by the owner, in his own game. The panel frees it
	-- itself: its full-screen overlay is a GuiButton with Modal set, and Roblox unlocks the mouse for as
	-- long as a visible modal button is up, whatever the camera does each frame. So the test is that the
	-- overlay is modal, that it is visible exactly while the panel is open, and that it is never left
	-- behind after a close.
	panel:Close()
	task.wait(0.4)
	check(panel.overlay.Modal == true and panel.overlay.Visible == false,
		"ui: the panel's overlay is a modal button, and it is down while the panel is closed (modal %s, visible %s)",
		tostring(panel.overlay.Modal), tostring(panel.overlay.Visible))
	panel:Open(loadout)
	task.wait(0.1)
	check(panel.overlay.Visible and panel.overlay.Modal, "ui: opening the panel puts the modal overlay up, which is what frees the cursor")
	-- Planted fault: without the modal flag the same check has nothing to pass on.
	panel.overlay.Modal = false
	check(not (panel.overlay.Visible and panel.overlay.Modal), "ui: planted fault: with Modal off the cursor check fails (so it can fail)")
	panel.overlay.Modal = true
	panel:Close()
	task.wait(0.4)
	check(not panel.overlay.Visible, "ui: closing takes the overlay down again, so the cursor goes back to the game")
	-- And the key has to do something even before the first loadout push: an inventory key that silently
	-- does nothing reads as a broken key, and it is how a player finds out what is in the panel at all.
	panel:SetLoadout(nil)
	panel:Open(nil)
	task.wait(0.1)
	check(panel:IsOpen() and panel.overlay.Visible, "ui: the panel opens with no loadout at all (eight empty slots), not silently nothing")
	panel:Close()
	panel:SetLoadout(loadout)
	panel:Open(loadout)
	task.wait(0.3)

	-- A card's two bottom lines must never run into each other. The worst case is the longest rarity
	-- with a three-figure reserve and a four-figure magazine, which used to print straight under the
	-- ammo; the sub line is cut short of the count's box instead, so compare the boxes.
	local fat = { kind = "weapon", id = "PatapimChaingun", name = "Patapim Chaingun", rarity = "Legendary", mag = 0, magSize = 100, reserve = 240 }
	local fatLoadout = { slots = { fat, bandage, false, false, false, false, false, false }, equipped = 1 }
	panel:SetLoadout(fatLoadout)
	panel:Open(fatLoadout)
	task.wait(0.4)
	local fatCard = panel.cards[1]
	local function overlap(a, b)
		local aMin, aMax = a.AbsolutePosition, a.AbsolutePosition + a.AbsoluteSize
		local bMin, bMax = b.AbsolutePosition, b.AbsolutePosition + b.AbsoluteSize
		local x = math.min(aMax.X, bMax.X) - math.max(aMin.X, bMin.X)
		local y = math.min(aMax.Y, bMax.Y) - math.max(aMin.Y, bMin.Y)
		return x > 0.5 and y > 0.5, x, y
	end
	local hit, overX, overY = overlap(fatCard.sub, fatCard.count)
	check(not hit and fatCard.sub.AbsoluteSize.X > 1,
		"ui: the rarity and reserve line and the ammo chip don't share any pixels (overlap %.1f x %.1f, sub %q, ammo %q)",
		overX, overY, fatCard.sub.Text, fatCard.count.Text)
	-- Planted fault: put the ammo back on the text line and the same check must fail.
	local realCount = fatCard.count.Position
	fatCard.count.Position = UDim2.new(1, -8, 1, -11)
	task.wait(0.1)
	check((overlap(fatCard.sub, fatCard.count)), "ui: planted fault: the ammo sitting on the text line does overlap it, so the check above can fail")
	fatCard.count.Position = realCount
	panel:Close(true)
	check(not panel:IsOpen() and closedByPanel == 1, "ui: closing from the panel itself tells its owner (%d)", closedByPanel)
	panel:SetLoadout(nil)
	panel:Open(nil)
	panel:_tap(1)
	check(#swaps == 2 and panel.selected == nil, "ui: with no loadout nothing can be picked or swapped")
	panel:Close()
	-- Planted fault: the "shows at once" test must fail when the local swap isn't kept.
	panel:SetLoadout(loadout)
	panel:Open(loadout)
	panel:_tap(1)
	panel:_tap(5)
	panel.shownSlots = nil
	local plantedShown = panel.shownSlots ~= nil and panel.shownSlots[5] == gunA
	check(not plantedShown, "ui: planted fault: with the local swap dropped, the 'shows at once' test fails")
	panel:Close()

	gui:Destroy()
end

--------------------------------------------------------------------------------
-- touch
--------------------------------------------------------------------------------

-- TouchControls, the owners' hard requirements one by one, on stand-in touch InputObjects (tables with
-- UserInputType Touch) pressed through the module's own code. The flag and the touch screen are forced on
-- for this section only, into a Frame under StarterGui; both are put back at the end.
local function probeTouch()
	local TouchControls = require(Scripts:WaitForChild("TouchControls"))
	local StarterGui = game:GetService("StarterGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HudUxTouchProbe"
	screenGui.Parent = StarterGui
	local screen = Instance.new("Frame")
	screen.Size = UDim2.fromOffset(844, 390)
	screen.BackgroundTransparency = 1
	screen.Parent = screenGui

	local realEnabled = TouchControls.Enabled
	check(realEnabled == false, "touch: the shipped flag is off (Enabled = %s)", tostring(realEnabled))
	TouchControls._Reset()
	TouchControls.TestParent = screen
	TouchControls.TestViewport = Vector2.new(844, 390)
	TouchControls.ForceTouch = true

	-- Flag off: nothing at all.
	TouchControls.Enabled = false
	TouchControls.Bind("BRR_Fire", { label = "FIRE", handler = function() end })
	check(#screen:GetChildren() == 0 and TouchControls._Showing("fire") == nil, "touch: flag off: a bind draws nothing and makes no gui (%d children)",
		#screen:GetChildren())
	TouchControls.Enabled = true
	TouchControls.Bind("BRR_Fire", { label = "FIRE", handler = function() end })
	check(#screen:GetChildren() == 1 and TouchControls._Showing("fire") == "BRR_Fire",
		"touch: planted fault: the same bind with the flag on does make the gui and the button (so the check above can fail)")
	TouchControls._Reset()

	-- Layout: the approved map's numbers.
	local function near(rect, x, y, size)
		return rect and math.abs(rect.x - x) < 0.6 and math.abs(rect.y - y) < 0.6 and math.abs(rect.size - size) < 0.6
	end
	local phone = TouchControls.Layout(Vector2.new(844, 390))
	local tablet = TouchControls.Layout(Vector2.new(1024, 768))
	check(near(phone.fire, 669, 298, 72) and near(phone.aim, 681, 242, 48) and near(phone.reload, 760, 242, 48) and near(phone.run, 681, 186, 48)
		and near(phone.pet, 760, 186, 48) and near(phone.slide, 681, 130, 48) and near(phone.move, 760, 130, 48) and near(phone.cam, 684, 6, 44),
		"touch: layout at 844x390 is the map's (fire %.0f,%.0f %.0f)", phone.fire.x, phone.fire.y, phone.fire.size)
	check(near(tablet.fire, 734, 570, 108) and near(tablet.aim, 752, 474, 72), "touch: layout at 1024x768 is the map's (fire %.0f,%.0f %.0f, aim %.0f,%.0f %.0f)",
		tablet.fire.x, tablet.fire.y, tablet.fire.size, tablet.aim.x, tablet.aim.y, tablet.aim.size)
	check(not near(phone.fire, 669 + 10, 298, 72), "touch: planted fault: a fire button 10 px off the map is told apart")

	-- In a match, from here on.
	TouchControls._ContextOverride = function()
		return { match = true }, false
	end

	-- Five binds: exactly those five show, each in its slot.
	local log = {}
	local function recorder(name)
		return function(actionName, inputState, inputObject)
			table.insert(log, { name = name, action = actionName, state = inputState, input = inputObject, showing = TouchControls._Showing(TouchControls.DefaultSlots[actionName] or "") })
			return Enum.ContextActionResult.Sink
		end
	end
	for _, name in ipairs({ "BRR_Fire", "BRR_Aim", "BRR_Reload", "BRR_Slide", "BRR_Companion" }) do
		TouchControls.Bind(name, { label = name, handler = recorder(name) })
	end
	local shown = 0
	for _, slot in ipairs(TouchControls.Slots) do
		if TouchControls._Showing(slot) then
			shown += 1
		end
	end
	check(shown == 5 and TouchControls._Showing("fire") == "BRR_Fire" and TouchControls._Showing("pet") == "BRR_Companion" and not TouchControls._Showing("run"),
		"touch: five binds show five buttons in their own slots, nothing else (%d showing)", shown)

	-- Hold: Begin on touch, End only when that finger lifts, exactly once, with the same Touch object.
	local finger = { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin, Name = "finger1" }
	log = {}
	TouchControls._Press("fire", finger)
	task.wait()
	local afterPress = #log
	TouchControls._Release(finger)
	TouchControls._Release(finger)
	task.wait()
	check(afterPress == 1 and #log == 2 and log[1].state == Enum.UserInputState.Begin and log[2].state == Enum.UserInputState.End
		and log[1].input == finger and log[2].input == finger and log[2].action == "BRR_Fire",
		"touch: FIRE (hold): Begin on press, one End on lift even when lifted twice, same Touch object both times (%d then %d events)", afterPress, #log)
	-- Tap: Begin then End at once.
	log = {}
	TouchControls._Press("reload", finger)
	task.wait()
	check(#log == 2 and log[1].state == Enum.UserInputState.Begin and log[2].state == Enum.UserInputState.End and log[2].input == finger,
		"touch: RELOAD (press): Begin then End straight away (%d events)", #log)
	-- Only a starting touch presses; a finger sliding on, or a mouse click, doesn't.
	check(TouchControls._AcceptsInput(finger) and not TouchControls._AcceptsInput({ UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Change })
		and not TouchControls._AcceptsInput({ UserInputType = Enum.UserInputType.MouseButton1, UserInputState = Enum.UserInputState.Begin })
		and not TouchControls._AcceptsInput(nil),
		"touch: only a touch that starts on a button presses it (not a drag sliding on, not a mouse click, not nil)")
	check(not TouchControls._AcceptsInput({ UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.End }),
		"touch: planted fault: a touch that is ending is refused too (the acceptance check can say no)")

	-- Multi-touch: FIRE and AIM on separate fingers, each its own Begin and End.
	local finger2 = { UserInputType = Enum.UserInputType.Touch, UserInputState = Enum.UserInputState.Begin, Name = "finger2" }
	log = {}
	TouchControls._Press("fire", finger)
	TouchControls._Press("aim", finger2)
	TouchControls._Release(finger2)
	task.wait()
	local fireEnded, aimEnded = false, false
	for _, entry in ipairs(log) do
		if entry.state == Enum.UserInputState.End then
			if entry.action == "BRR_Fire" then
				fireEnded = true
			elseif entry.action == "BRR_Aim" then
				aimEnded = entry.input == finger2
			end
		end
	end
	check(#log == 3 and aimEnded and not fireEnded, "touch: FIRE and AIM on two fingers: lifting the AIM finger ends AIM only (%d events)", #log)

	-- Going away mid-hold: End first (while still showing), with the press's own object, then gone.
	log = {}
	TouchControls._ContextOverride = function()
		return { match = true }, true
	end
	TouchControls.Refresh()
	task.wait()
	check(#log == 1 and log[1].state == Enum.UserInputState.End and log[1].input == finger and log[1].showing == "BRR_Fire" and TouchControls._Showing("fire") == nil,
		"touch: a menu opening mid-hold sends FIRE's End first (while still showing), with the same finger, then hides it")
	TouchControls._ContextOverride = function()
		return { match = true }, false
	end
	TouchControls.Refresh()
	log = {}
	TouchControls._Press("fire", finger)
	TouchControls.SetState("BRR_Fire", { disabled = true })
	task.wait()
	check(#log == 2 and log[2].state == Enum.UserInputState.End, "touch: disabled mid-hold sends End (%d events)", #log)
	TouchControls.SetState("BRR_Fire", { disabled = false })
	log = {}
	TouchControls._Press("fire", finger)
	TouchControls.Unbind("BRR_Fire")
	task.wait()
	check(#log == 2 and log[2].state == Enum.UserInputState.End and log[2].input == finger and TouchControls._Showing("fire") == nil,
		"touch: unbound mid-hold sends End with the same finger, then the button goes")
	TouchControls._Release(finger)
	task.wait()
	check(#log == 2, "touch: the finger lifting afterwards sends nothing more (exactly one End per Begin)")
	TouchControls.Bind("BRR_Fire", { label = "FIRE", handler = recorder("BRR_Fire") })

	-- Priority: a lower-priority bind on a taken slot waits; the planted higher one takes it.
	TouchControls.Bind("Probe_LowFire", { slot = "fire", label = "LOW", priority = -1, handler = function() end })
	check(TouchControls._Showing("fire") == "BRR_Fire", "touch: a lower-priority bind on FIRE's slot doesn't show")
	TouchControls.Bind("Probe_LowFire", { slot = "fire", label = "HIGH", priority = 5, handler = function() end })
	check(TouchControls._Showing("fire") == "Probe_LowFire", "touch: planted fault: the same bind at a higher priority does take the slot")
	TouchControls.Unbind("Probe_LowFire")
	check(TouchControls._Showing("fire") == "BRR_Fire", "touch: when it's gone, FIRE is back")

	-- Nine and more: extras fill, then a warning and no button, with nothing else disturbed.
	for index = 1, 4 do
		TouchControls.Bind("Probe_Extra" .. index, { label = "X" .. index, handler = function() end })
	end
	check(TouchControls._Showing("extra1") == "Probe_Extra1" and TouchControls._Showing("extra2") == "Probe_Extra2" and TouchControls._Showing("fire") == "BRR_Fire",
		"touch: binds with no slot of their own fill extra1 and extra2; the rest are left off, and FIRE is untouched")
	for index = 1, 4 do
		TouchControls.Unbind("Probe_Extra" .. index)
	end

	-- RUN tapped twice toggles on then off (the movement tab's sprint reads the Touch type to toggle).
	local sprinting = false
	TouchControls.Bind("BRR_Sprint", { label = "RUN", handler = function(_, inputState, inputObject)
		if inputState == Enum.UserInputState.Begin and inputObject and inputObject.UserInputType == Enum.UserInputType.Touch then
			sprinting = not sprinting
		end
	end })
	TouchControls._Press("run", finger)
	TouchControls._Release(finger)
	task.wait()
	local afterFirst = sprinting
	TouchControls._Press("run", finger)
	TouchControls._Release(finger)
	task.wait()
	check(afterFirst == true and sprinting == false, "touch: RUN tapped twice turns sprint on, then off")

	-- A context that can't be worked out shows the match set, with one warning.
	TouchControls._ContextOverride = function()
		error("no match state yet")
	end
	TouchControls.Refresh()
	check(TouchControls._Showing("fire") == "BRR_Fire", "touch: an error working out the context still shows FIRE")
	TouchControls._ContextOverride = function()
		return { lobby = true }, false
	end
	TouchControls.Refresh()
	check(TouchControls._Showing("fire") == nil and TouchControls._Showing("run") == "BRR_Sprint",
		"touch: planted fault: in the lobby FIRE does hide (and RUN stays), so the check above can fail")

	-- Put everything back.
	TouchControls._Reset()
	TouchControls.Enabled = realEnabled
	TouchControls.ForceTouch = false
	TouchControls.TestParent = nil
	TouchControls.TestViewport = nil
	screenGui:Destroy()
end

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- phone
--------------------------------------------------------------------------------

-- PhoneLayout, against the numbers scratchpad/phone_layout_map.py sweeps (the two are separate
-- implementations of the same layout, so this catches a porting slip in either), and then the layout's
-- own rules: nothing overlapping, nothing off screen, nothing over the crosshair, nothing tappable in
-- the thumbstick's zone, and hotbar cells a finger can hit.

-- Generated from scratchpad/phone_layout_map.py: PhoneLayout's rects at the named sizes.
local EXPECTED = {
	{ w = 844, h = 390, rects = {
		{ "jump", 749.00, 300.00, 70.00, 70.00 },
		{ "stick", 29.00, 297.00, 74.00, 74.00 },
		{ "topBar", 0.00, 0.00, 200.00, 52.00 },
		{ "fire", 669.00, 298.00, 72.00, 72.00 },
		{ "aim", 681.00, 242.00, 48.00, 48.00 },
		{ "reload", 760.00, 242.00, 48.00, 48.00 },
		{ "run", 681.00, 186.00, 48.00, 48.00 },
		{ "pet", 760.00, 186.00, 48.00, 48.00 },
		{ "slide", 681.00, 130.00, 48.00, 48.00 },
		{ "move", 760.00, 130.00, 48.00, 48.00 },
		{ "banner", 257.00, 4.00, 330.00, 42.00 },
		{ "stormLine", 297.00, 48.00, 250.00, 13.50 },
		{ "compass", 257.00, 63.50, 330.00, 18.00 },
		{ "menu", 792.00, 6.00, 44.00, 44.00 },
		{ "stackTab", 734.00, 6.00, 52.00, 44.00 },
		{ "cam", 684.00, 6.00, 44.00, 44.00 },
		{ "eventPill", 689.70, 85.50, 146.30, 34.70 },
		{ "killFeed", 483.70, 85.50, 200.00, 36.00 },
		{ "toast", 279.00, 117.50, 286.00, 22.00 },
		{ "bounty", 461.00, 125.50, 200.00, 19.00 },
		{ "location", 461.00, 146.50, 200.00, 17.00 },
		{ "minimap", 16.00, 58.00, 96.00, 96.00 },
		{ "petIcon", 16.00, 233.00, 56.00, 56.00 },
		{ "coins", 16.00, 158.00, 120.00, 28.00 },
		{ "companion", 142.00, 158.00, 160.00, 32.00 },
		{ "hotbar", 349.60, 269.90, 227.20, 112.10 },
		{ "inventory", 532.80, 227.90, 44.00, 32.00 },
		{ "health", 349.60, 229.50, 177.20, 30.40 },
		{ "stamina", 349.60, 209.90, 137.20, 14.00 },
		{ "speedPill", 492.80, 203.90, 84.00, 20.00 },
		{ "useBar", 312.00, 87.50, 220.00, 30.00 },
	} },
	{ w = 667, h = 375, rects = {
		{ "jump", 572.00, 285.00, 70.00, 70.00 },
		{ "stick", 29.00, 282.00, 74.00, 74.00 },
		{ "topBar", 0.00, 0.00, 200.00, 52.00 },
		{ "fire", 492.00, 283.00, 72.00, 72.00 },
		{ "aim", 504.00, 227.00, 48.00, 48.00 },
		{ "reload", 583.00, 227.00, 48.00, 48.00 },
		{ "run", 504.00, 171.00, 48.00, 48.00 },
		{ "pet", 583.00, 171.00, 48.00, 48.00 },
		{ "slide", 504.00, 115.00, 48.00, 48.00 },
		{ "move", 583.00, 115.00, 48.00, 48.00 },
		{ "banner", 208.00, 4.00, 291.00, 42.00 },
		{ "stormLine", 228.50, 48.00, 250.00, 13.50 },
		{ "compass", 208.00, 63.50, 291.00, 18.00 },
		{ "menu", 615.00, 6.00, 44.00, 44.00 },
		{ "stackTab", 557.00, 6.00, 52.00, 44.00 },
		{ "cam", 507.00, 6.00, 44.00, 44.00 },
		{ "eventPill", 337.70, 85.50, 146.30, 34.70 },
		{ "killFeed", 131.70, 85.50, 200.00, 36.00 },
		{ "toast", 190.50, 117.50, 286.00, 22.00 },
		{ "bounty", 310.00, 125.50, 174.00, 19.00 },
		{ "location", 310.00, 146.50, 174.00, 17.00 },
		{ "minimap", 16.00, 58.00, 96.00, 96.00 },
		{ "petIcon", 16.00, 218.00, 56.00, 56.00 },
		{ "coins", 16.00, 158.00, 120.00, 28.00 },
		{ "companion", 142.00, 158.00, 160.00, 32.00 },
		{ "hotbar", 270.80, 273.50, 190.10, 93.50 },
		{ "inventory", 416.90, 231.50, 44.00, 32.00 },
		{ "health", 270.80, 239.40, 140.10, 24.10 },
		{ "stamina", 270.80, 213.50, 100.10, 14.00 },
		{ "speedPill", 376.90, 207.50, 84.00, 20.00 },
		{ "useBar", 223.50, 87.50, 220.00, 30.00 },
	} },
	{ w = 740, h = 360, rects = {
		{ "jump", 645.00, 270.00, 70.00, 70.00 },
		{ "stick", 29.00, 267.00, 74.00, 74.00 },
		{ "topBar", 0.00, 0.00, 200.00, 52.00 },
		{ "fire", 565.00, 268.00, 72.00, 72.00 },
		{ "aim", 577.00, 212.00, 48.00, 48.00 },
		{ "reload", 656.00, 212.00, 48.00, 48.00 },
		{ "run", 577.00, 156.00, 48.00, 48.00 },
		{ "pet", 656.00, 156.00, 48.00, 48.00 },
		{ "slide", 577.00, 100.00, 48.00, 48.00 },
		{ "move", 656.00, 100.00, 48.00, 48.00 },
		{ "banner", 208.00, 4.00, 330.00, 42.00 },
		{ "stormLine", 248.00, 48.00, 250.00, 13.50 },
		{ "compass", 208.00, 63.50, 330.00, 18.00 },
		{ "menu", 688.00, 6.00, 44.00, 44.00 },
		{ "stackTab", 630.00, 6.00, 52.00, 44.00 },
		{ "cam", 580.00, 6.00, 44.00, 44.00 },
		{ "eventPill", 410.70, 85.50, 146.30, 34.70 },
		{ "killFeed", 204.70, 85.50, 200.00, 36.00 },
		{ "toast", 227.00, 117.50, 286.00, 22.00 },
		{ "bounty", 357.00, 125.50, 200.00, 19.00 },
		{ "location", 357.00, 146.50, 200.00, 17.00 },
		{ "minimap", 16.00, 58.00, 96.00, 96.00 },
		{ "petIcon", 16.00, 203.00, 56.00, 56.00 },
		{ "coins", 16.00, 158.00, 120.00, 28.00 },
		{ "companion", 142.00, 158.00, 160.00, 32.00 },
		{ "hotbar", 308.00, 255.50, 196.00, 96.50 },
		{ "inventory", 460.00, 213.50, 44.00, 32.00 },
		{ "health", 308.00, 220.50, 146.00, 25.00 },
		{ "stamina", 308.00, 195.50, 106.00, 14.00 },
		{ "speedPill", 420.00, 189.50, 84.00, 20.00 },
		{ "useBar", 260.00, 87.50, 220.00, 30.00 },
	} },
	{ w = 1024, h = 768, rects = {
		{ "jump", 854.00, 558.00, 120.00, 120.00 },
		{ "stick", 58.00, 582.00, 148.00, 148.00 },
		{ "topBar", 0.00, 0.00, 220.00, 52.00 },
		{ "fire", 734.00, 570.00, 108.00, 108.00 },
		{ "aim", 752.00, 474.00, 72.00, 72.00 },
		{ "reload", 878.00, 474.00, 72.00, 72.00 },
		{ "run", 752.00, 390.00, 72.00, 72.00 },
		{ "pet", 878.00, 390.00, 72.00, 72.00 },
		{ "slide", 752.00, 306.00, 72.00, 72.00 },
		{ "move", 878.00, 306.00, 72.00, 72.00 },
		{ "banner", 292.00, 4.00, 440.00, 56.00 },
		{ "stormLine", 324.50, 62.00, 375.00, 18.00 },
		{ "compass", 292.00, 82.00, 440.00, 24.00 },
		{ "menu", 946.00, 6.00, 66.00, 66.00 },
		{ "stackTab", 862.00, 6.00, 78.00, 66.00 },
		{ "cam", 790.00, 6.00, 66.00, 66.00 },
		{ "eventPill", 821.80, 110.00, 190.20, 45.10 },
		{ "killFeed", 515.80, 110.00, 300.00, 54.00 },
		{ "toast", 297.50, 157.00, 429.00, 33.00 },
		{ "bounty", 450.00, 168.00, 272.00, 28.50 },
		{ "location", 450.00, 198.50, 272.00, 25.50 },
		{ "minimap", 16.00, 58.00, 150.00, 150.00 },
		{ "petIcon", 16.00, 486.00, 84.00, 84.00 },
		{ "coins", 16.00, 212.00, 180.00, 42.00 },
		{ "companion", 202.00, 212.00, 240.00, 48.00 },
		{ "hotbar", 413.60, 614.40, 297.20, 145.60 },
		{ "inventory", 644.80, 556.40, 66.00, 48.00 },
		{ "health", 413.60, 565.80, 225.20, 38.60 },
		{ "stamina", 413.60, 531.40, 165.20, 21.00 },
		{ "speedPill", 584.80, 522.40, 126.00, 30.00 },
		{ "useBar", 347.00, 112.00, 330.00, 45.00 },
	} },
	{ w = 1180, h = 820, rects = {
		{ "jump", 1010.00, 610.00, 120.00, 120.00 },
		{ "stick", 58.00, 634.00, 148.00, 148.00 },
		{ "topBar", 0.00, 0.00, 220.00, 52.00 },
		{ "fire", 890.00, 622.00, 108.00, 108.00 },
		{ "aim", 908.00, 526.00, 72.00, 72.00 },
		{ "reload", 1034.00, 526.00, 72.00, 72.00 },
		{ "run", 908.00, 442.00, 72.00, 72.00 },
		{ "pet", 1034.00, 442.00, 72.00, 72.00 },
		{ "slide", 908.00, 358.00, 72.00, 72.00 },
		{ "move", 1034.00, 358.00, 72.00, 72.00 },
		{ "banner", 370.00, 4.00, 440.00, 56.00 },
		{ "stormLine", 402.50, 62.00, 375.00, 18.00 },
		{ "compass", 370.00, 82.00, 440.00, 24.00 },
		{ "menu", 1102.00, 6.00, 66.00, 66.00 },
		{ "stackTab", 1018.00, 6.00, 78.00, 66.00 },
		{ "cam", 946.00, 6.00, 66.00, 66.00 },
		{ "eventPill", 977.80, 110.00, 190.20, 45.10 },
		{ "killFeed", 671.80, 110.00, 300.00, 54.00 },
		{ "toast", 375.50, 157.00, 429.00, 33.00 },
		{ "bounty", 578.00, 168.00, 300.00, 28.50 },
		{ "location", 578.00, 198.50, 300.00, 25.50 },
		{ "minimap", 16.00, 58.00, 150.00, 150.00 },
		{ "petIcon", 16.00, 538.00, 84.00, 84.00 },
		{ "coins", 16.00, 212.00, 180.00, 42.00 },
		{ "companion", 202.00, 212.00, 240.00, 48.00 },
		{ "hotbar", 476.00, 643.00, 344.00, 169.00 },
		{ "inventory", 754.00, 585.00, 66.00, 48.00 },
		{ "health", 476.00, 586.40, 272.00, 46.60 },
		{ "stamina", 476.00, 560.00, 212.00, 21.00 },
		{ "speedPill", 694.00, 551.00, 126.00, 30.00 },
		{ "useBar", 425.00, 112.00, 330.00, 45.00 },
	} },
	{ w = 320, h = 568, rects = {
		{ "jump", 225.00, 478.00, 70.00, 70.00 },
		{ "stick", 29.00, 475.00, 74.00, 74.00 },
		{ "topBar", 0.00, 0.00, 200.00, 52.00 },
		{ "fire", 145.00, 476.00, 72.00, 72.00 },
		{ "aim", 157.00, 420.00, 48.00, 48.00 },
		{ "reload", 236.00, 420.00, 48.00, 48.00 },
		{ "run", 157.00, 364.00, 48.00, 48.00 },
		{ "pet", 236.00, 364.00, 48.00, 48.00 },
		{ "slide", 157.00, 308.00, 48.00, 48.00 },
		{ "move", 236.00, 308.00, 48.00, 48.00 },
		{ "menu", 268.00, 58.00, 44.00, 44.00 },
		{ "stackTab", 210.00, 58.00, 52.00, 44.00 },
		{ "cam", 160.00, 58.00, 44.00, 44.00 },
		{ "minimap", 16.00, 58.00, 72.00, 72.00 },
		{ "banner", 16.00, 134.00, 288.00, 42.00 },
		{ "stormLine", 16.00, 178.00, 288.00, 18.00 },
		{ "eventPill", 165.70, 202.00, 146.30, 34.70 },
		{ "coins", 16.00, 202.00, 120.00, 28.00 },
		{ "companion", 16.00, 230.00, 138.00, 24.00 },
		{ "petIcon", 16.00, 258.00, 56.00, 56.00 },
		{ "toast", 16.00, 242.70, 288.00, 22.00 },
		{ "useBar", 50.00, 202.00, 220.00, 30.00 },
		{ "inventory", 268.00, 242.70, 44.00, 44.00 },
		{ "health", 16.00, 439.00, 123.00, 30.00 },
		{ "stamina", 16.00, 421.00, 123.00, 14.00 },
	} },
	{ w = 375, h = 667, rects = {
		{ "jump", 280.00, 577.00, 70.00, 70.00 },
		{ "stick", 29.00, 574.00, 74.00, 74.00 },
		{ "topBar", 0.00, 0.00, 200.00, 52.00 },
		{ "fire", 200.00, 575.00, 72.00, 72.00 },
		{ "aim", 212.00, 519.00, 48.00, 48.00 },
		{ "reload", 291.00, 519.00, 48.00, 48.00 },
		{ "run", 212.00, 463.00, 48.00, 48.00 },
		{ "pet", 291.00, 463.00, 48.00, 48.00 },
		{ "slide", 212.00, 407.00, 48.00, 48.00 },
		{ "move", 291.00, 407.00, 48.00, 48.00 },
		{ "menu", 323.00, 58.00, 44.00, 44.00 },
		{ "stackTab", 265.00, 58.00, 52.00, 44.00 },
		{ "cam", 215.00, 58.00, 44.00, 44.00 },
		{ "minimap", 16.00, 58.00, 72.00, 72.00 },
		{ "banner", 16.00, 134.00, 343.00, 42.00 },
		{ "stormLine", 16.00, 178.00, 343.00, 18.00 },
		{ "eventPill", 220.70, 202.00, 146.30, 34.70 },
		{ "coins", 16.00, 202.00, 120.00, 28.00 },
		{ "companion", 16.00, 230.00, 138.00, 24.00 },
		{ "petIcon", 16.00, 258.00, 56.00, 56.00 },
		{ "toast", 16.00, 242.70, 343.00, 22.00 },
		{ "useBar", 77.50, 202.00, 220.00, 30.00 },
		{ "hotbar", 229.00, 357.00, 138.00, 44.00 },
		{ "inventory", 179.00, 357.00, 44.00, 44.00 },
		{ "health", 16.00, 538.00, 138.00, 30.00 },
		{ "stamina", 16.00, 520.00, 138.00, 14.00 },
	} },
}

local function probePhone()
	local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
	local realForce = PhoneLayout.Force

	-- A desktop screen is left alone: that is what the whole HUD still is on a PC.
	PhoneLayout.Force = nil
	check(PhoneLayout.Mode(Vector2.new(1920, 1080)) == "desktop" and not PhoneLayout.Active(Vector2.new(844, 390)),
		"phone: with no touch screen every size is the desktop layout (%s at 844x390)", PhoneLayout.Mode(Vector2.new(844, 390)))
	PhoneLayout.Force = "handheld"
	check(PhoneLayout.Active(Vector2.new(844, 390)), "phone: planted fault: forced on, the same size is a phone (so the check above can fail)")

	-- The numbers, size by size.
	local worst, worstName = 0, ""
	for _, screen in ipairs(EXPECTED) do
		local spots = PhoneLayout.Rects(Vector2.new(screen.w, screen.h))
		for _, want in ipairs(screen.rects) do
			local got = spots[want[1]]
			if not got then
				check(false, "phone: %dx%d has no rect for %s", screen.w, screen.h, want[1])
			else
				local gap = math.max(math.abs(got.x - want[2]), math.abs(got.y - want[3]), math.abs(got.w - want[4]), math.abs(got.h - want[5]))
				if gap > worst then
					worst, worstName = gap, string.format("%s at %dx%d (%.1f,%.1f %.0fx%.0f, want %.1f,%.1f %.0fx%.0f)", want[1], screen.w,
						screen.h, got.x, got.y, got.w, got.h, want[2], want[3], want[4], want[5])
				end
			end
		end
	end
	check(worst < 0.6, "phone: every rect at all five sizes matches the swept layout (worst %.2f px%s)", worst,
		worstName ~= "" and (": " .. worstName) or "")

	-- The rules, on the module's own output.
	local SOLID = { "banner", "stormLine", "compass", "menu", "stackTab", "cam", "eventPill", "killFeed", "minimap", "bounty",
		"location", "petIcon", "hotbar", "inventory", "health", "stamina", "speedPill", "coins", "companion", "jump", "stick",
		"topBar", "fire", "aim", "reload", "run", "pet", "slide", "move" }
	local TAPPABLE = { hotbar = true, inventory = true, menu = true, stackTab = true, cam = true, eventPill = true }
	local function overlaps(a, b)
		return math.min(a.x1, b.x1) - math.max(a.x, b.x) > 0.5 and math.min(a.y1, b.y1) - math.max(a.y, b.y) > 0.5
	end
	local function problemsAt(w, h, moved)
		local spots = PhoneLayout.Rects(Vector2.new(w, h))
		if moved then
			spots[moved] = { x = spots.banner.x + 2, y = spots.banner.y + 2, w = 40, h = 10, x1 = spots.banner.x + 42, y1 = spots.banner.y + 12 }
		end
		local found = {}
		for index, nameA in ipairs(SOLID) do
			local a = spots[nameA]
			for other = index + 1, #SOLID do
				local b = spots[SOLID[other]]
				if a and b and overlaps(a, b) then
					table.insert(found, nameA .. " x " .. SOLID[other])
				end
			end
			if a and (a.x < -0.01 or a.y < -0.01 or a.x1 > w + 0.01 or a.y1 > h + 0.01) then
				table.insert(found, nameA .. " off screen")
			end
			local cross = { x = w / 2 - 12, y = h / 2 - 12, x1 = w / 2 + 12, y1 = h / 2 + 12 }
			if a and overlaps(a, cross) then
				table.insert(found, nameA .. " over the crosshair")
			end
			if a and TAPPABLE[nameA] and overlaps(a, spots.moveZone) then
				table.insert(found, nameA .. " in the thumbstick zone")
			end
		end
		-- `hotbarTight` is the layout saying the band could not give a finger-sized cell and the grid is
		-- overflowing it; the cell size itself is clamped, so this flag is what tells the truth.
		if spots.hotbarTight or spots.hotbarCell < (w >= 700 and 44 or 40) - 0.01 then
			table.insert(found, string.format("hotbar cells only %.0f px (band too narrow)", spots.hotbarCell))
		end
		return found, spots
	end
	local allProblems = {}
	for _, screen in ipairs(EXPECTED) do
		local found, spots = problemsAt(screen.w, screen.h)
		for _, problem in ipairs(found) do
			table.insert(allProblems, string.format("%dx%d %s", screen.w, screen.h, problem))
		end
		check(spots.hotbarCell >= 40 and not spots.hotbarTight, "phone: %dx%d hotbar cells are %.0f px in a band that fits them",
			screen.w, screen.h, spots.hotbarCell)
	end
	check(#allProblems == 0, "phone: the five named sizes have no overlaps, nothing off screen, nothing over the crosshair and nothing tappable in the stick's zone (%s)",
		allProblems[1] or "none")
	-- Planted fault: drop the minimap onto the banner and the same pass must report it.
	local planted = problemsAt(844, 390, "minimap")
	check(#planted > 0 and string.find(planted[1], "minimap"), "phone: planted fault: a minimap moved onto the banner is reported (%s)",
		planted[1] or "nothing")

	-- A sweep of its own: every landscape phone size in 12-pixel steps has a workable bottom band...
	local swept, tight = 0, 0
	for w = 640, 1024, 12 do
		for h = 360, 500, 12 do
			if w >= h * 1.25 then
				swept += 1
				local found = problemsAt(w, h)
				if #found > 0 then
					tight += 1
				end
			end
		end
	end
	check(tight == 0, "phone: %d landscape phone sizes swept, %d with a problem", swept, tight)
	-- ...and every portrait size from the smallest handset up, where the layout has to simplify instead.
	local sweptUp, tightUp, firstUp = 0, 0, ""
	for w = 320, 500, 8 do
		for h = 568, 1000, 16 do
			if h >= w * 1.25 then
				sweptUp += 1
				local found = problemsAt(w, h)
				if #found > 0 then
					tightUp += 1
					if firstUp == "" then
						firstUp = string.format("%dx%d %s", w, h, found[1])
					end
				end
			end
		end
	end
	check(tightUp == 0, "phone: %d portrait sizes swept from 320x568 up, %d with a problem (%s)", sweptUp, tightUp,
		firstUp ~= "" and firstUp or "none")
	-- Portrait simplifies rather than refusing: the compass, kill feed, bounty and location go, and the
	-- hotbar keeps only the slots that fit -- on the shortest screens none, just the button that opens
	-- the panel. That is the shape of the answer, so it is what the test asserts.
	local tall = PhoneLayout.Rects(Vector2.new(375, 667))
	local tiny = PhoneLayout.Rects(Vector2.new(320, 568))
	check(tall.portrait and tall.compass == nil and tall.killFeed == nil and tall.bounty == nil and tall.speedPill == nil,
		"phone: portrait drops the compass, the kill feed, the bounty and the speed pill")
	check(tall.hotbarSlots == 3 and tiny.hotbarSlots == 0 and tiny.inventory ~= nil and tall.coins ~= nil and tall.companion ~= nil,
		"phone: portrait keeps %d hotbar slots at 375x667 and none at 320x568 (where the Inventory button stands alone), with coins and companion still there",
		tall.hotbarSlots)

	-- The handsets and tablets people actually play on, by name, so a regression says which device.
	local DEVICES = {
		{ "iPhone 15 landscape", 852, 393 }, { "iPhone SE landscape", 667, 375 }, { "Pixel 7 landscape", 915, 412 },
		{ "Galaxy S21 landscape", 800, 360 }, { "iPad 10.2", 1080, 810 }, { "iPad Pro 12.9", 1366, 1024 },
	}
	local deviceProblems = {}
	for _, device in ipairs(DEVICES) do
		local found = problemsAt(device[2], device[3])
		for _, problem in ipairs(found) do
			table.insert(deviceProblems, device[1] .. ": " .. problem)
		end
	end
	check(#deviceProblems == 0, "phone: the six named devices are all clean (%s)", deviceProblems[1] or "none")

	-- Place is what HudClient calls for every piece: a frame drawn at its own size ends up filling the
	-- rect it was given, wherever its anchor used to be.
	local StarterGui = game:GetService("StarterGui")
	local placeGui = Instance.new("ScreenGui")
	placeGui.Name = "HudUxPhoneProbe"
	placeGui.IgnoreGuiInset = true
	placeGui.Parent = StarterGui
	local canvas = Instance.new("Frame")
	canvas.Size = UDim2.fromOffset(844, 390)
	canvas.BackgroundTransparency = 1
	canvas.Parent = placeGui
	local spots844 = PhoneLayout.Rects(Vector2.new(844, 390))
	local function stand(natural, anchor)
		local frame = Instance.new("Frame")
		frame.AnchorPoint = anchor or Vector2.new(1, 0)
		frame.Size = UDim2.fromOffset(natural.X, natural.Y)
		frame.Position = UDim2.fromOffset(600, 300)
		frame.Parent = canvas
		return frame, Instance.new("UIScale")
	end
	local minimapStand, minimapScale = stand(Vector2.new(190, 190))
	minimapScale.Parent = minimapStand
	PhoneLayout.Place(minimapStand, spots844.minimap, Vector2.new(190, 190), minimapScale, 0, true)
	task.wait(0.2)
	local origin = canvas.AbsolutePosition
	local gotX = minimapStand.AbsolutePosition.X - origin.X
	local gotY = minimapStand.AbsolutePosition.Y - origin.Y
	-- AbsoluteSize already has the UIScale in it, so this is the drawn width, not the authored one.
	check(math.abs(gotX - spots844.minimap.x) < 1 and math.abs(gotY - spots844.minimap.y) < 1
		and math.abs(minimapStand.AbsoluteSize.X - spots844.minimap.w) < 1,
		"phone: Place puts a 190-px minimap exactly on its 96-px slot (%.1f,%.1f %.0f wide, want %.1f,%.1f %.0f)",
		gotX, gotY, minimapStand.AbsoluteSize.X, spots844.minimap.x, spots844.minimap.y, spots844.minimap.w)
	-- The kill feed's box is taller than what it draws, so without `fit` it is scaled on width alone.
	local feedStand, feedScale = stand(Vector2.new(300, 200))
	feedScale.Parent = feedStand
	local wide = PhoneLayout.Place(feedStand, spots844.killFeed, Vector2.new(300, 200), feedScale, 0, false)
	local fitted = PhoneLayout.Place(feedStand, spots844.killFeed, Vector2.new(300, 200), feedScale, 0, true)
	check(math.abs(wide - spots844.killFeed.w / 300) < 0.001 and fitted < wide,
		"phone: Place scales on width by default (%.3f) and only squeezes on height when asked (%.3f)", wide, fitted)
	placeGui:Destroy()

	-- The layout is told each piece's authored size by hand (HudClient's locals can't be read from here),
	-- so those numbers have to still be the numbers in the files. If someone resizes the banner or the
	-- minimap, the phone layout would quietly put it in the wrong place at the wrong scale; this catches
	-- it as a failing test naming the piece instead.
	local hudSource = Scripts:WaitForChild("HudClient").Source
	local menuSource = Scripts:WaitForChild("MenuClient").Source
	local SIZES_IN_SOURCE = {
		{ "the top banner is 440x56", hudSource, "Size = UDim2%.new%(0, 440, 0, 56%)" },
		{ "the compass is 440x24", hudSource, "local COMPASS_W, COMPASS_H = 440, 24" },
		{ "the minimap is 190 across", hudSource, "local MAP_PX = 190" },
		{ "the health block is 280x80", hudSource, "Size = UDim2%.new%(0, 280, 0, 80%)" },
		{ "the kill feed's box is 300x200", hudSource, "Size = UDim2%.new%(0, 300, 0, 200%)" },
		{ "the speed pill is 150x28", hudSource, "Size = UDim2%.fromOffset%(150, 28%)" },
		{ "a hotbar cell is 78x64", hudSource, "Size = UDim2%.fromOffset%(78, 64%)" },
		{ "the drop screen's map is 440", hudSource, "local DROP_PX = 440" },
		{ "the results card is 460x410", hudSource, "Size = UDim2%.new%(0, 460, 0, 410%)" },
		{ "the map vote is 620x260", hudSource, "Size = UDim2%.new%(0, 620, 0, 260%)" },
		{ "the recap is 480x104", hudSource, "Size = UDim2%.new%(0, 480, 0, 104%)" },
		{ "the menu panel is 760x480", menuSource, "Size = UDim2%.new%(0, 760, 0, 480%)" },
	}
	local drifted = {}
	for _, entry in ipairs(SIZES_IN_SOURCE) do
		if not string.find(entry[2], entry[3]) then
			table.insert(drifted, entry[1])
		end
	end
	check(#drifted == 0, "phone: the sizes the layout assumes are still the sizes in the files (%s)",
		drifted[1] and table.concat(drifted, "; ") or "all twelve")
	-- Planted fault: a size that was never there must be reported.
	check(not string.find(hudSource, "Size = UDim2%.new%(0, 441, 0, 56%)"),
		"phone: planted fault: a banner size nobody wrote is not found (so the check above can fail)")

	-- TouchControls works out the button cluster itself (it has to draw it before anything else exists);
	-- PhoneLayout works it out to keep the hotbar band clear of it. The two must agree, or the band and
	-- the buttons drift apart.
	local TouchControlsModule = require(Scripts:WaitForChild("TouchControls"))
	local clusterWorst, clusterName = 0, ""
	for _, size in ipairs({ Vector2.new(844, 390), Vector2.new(667, 375), Vector2.new(740, 360), Vector2.new(1024, 768),
			Vector2.new(1180, 820), Vector2.new(320, 568), Vector2.new(375, 667) }) do
		local theirs = TouchControlsModule.Layout(size)
		local ours = PhoneLayout.Rects(size)
		for _, slot in ipairs({ "fire", "aim", "reload", "run", "pet", "slide", "move", "cam" }) do
			local a, b = theirs[slot], ours[slot]
			if a and b then
				local gap = math.max(math.abs(a.x - b.x), math.abs(a.y - b.y), math.abs(a.size - b.w))
				if gap > clusterWorst then
					clusterWorst, clusterName = gap, string.format("%s at %dx%d", slot, size.X, size.Y)
				end
			end
		end
	end
	check(clusterWorst < 0.6, "phone: TouchControls and PhoneLayout put the buttons in the same places (worst %.2f px%s)",
		clusterWorst, clusterName ~= "" and (" on " .. clusterName) or "")

	-- The event banner and the hotbar read the same layout, so the pill lands in its slot.
	local EventBanner = require(Scripts:WaitForChild("EventBanner"))
	local spots = PhoneLayout.Rects(Vector2.new(844, 390))
	local pillScale = EventBanner.PillScaleFor(Vector2.new(844, 390))
	check(math.abs(pillScale * EventBanner.PillSize.X - spots.eventPill.w) < 0.6 and EventBanner.CardTopFor(Vector2.new(844, 390)) == spots.eventPill.y,
		"phone: the event pill is drawn at its slot's width and the card starts at the same line (%.1f vs %.1f)",
		pillScale * EventBanner.PillSize.X, spots.eventPill.w)
	check(EventBanner.CardScaleFor(Vector2.new(844, 390)) * 160 + spots.eventPill.y <= 390 / 2 - 14 + 0.01,
		"phone: the event card's bottom edge stays above the crosshair")

	-- The centred panels. Each is authored at a desktop size and fitted by PhoneLayout.FitPanel; on a
	-- phone screen the whole panel has to be inside the viewport, and the drop screen's map has to stay
	-- big enough to pick a spot on.
	local PANELS = {
		{ name = "menu", natural = Vector2.new(760, 480), inset = true },
		{ name = "drop screen", natural = Vector2.new(480, 536) },
		{ name = "results card", natural = Vector2.new(460, 410) },
		{ name = "map vote", natural = Vector2.new(620, 260) },
		{ name = "match recap", natural = Vector2.new(480, 104) },
	}
	local PHONE_SIZES = { Vector2.new(844, 390), Vector2.new(667, 375), Vector2.new(740, 360) }
	local spilled, tightest, tightestName = {}, 1, ""
	for _, size in ipairs(PHONE_SIZES) do
		for _, panel in ipairs(PANELS) do
			local options = { inset = panel.inset, insetY = 58 }
			local scale = PhoneLayout.PanelScale(panel.natural, size, options)
			local width, height = panel.natural.X * scale, panel.natural.Y * scale
			local room = Vector2.new(size.X, size.Y - (panel.inset and 58 or 0))
			if width > room.X + 0.01 or height > room.Y + 0.01 then
				table.insert(spilled, string.format("%s at %dx%d is %.0fx%.0f in %.0fx%.0f", panel.name, size.X, size.Y, width, height, room.X, room.Y))
			end
			if scale < tightest then
				tightest, tightestName = scale, string.format("%s at %dx%d", panel.name, size.X, size.Y)
			end
		end
	end
	check(#spilled == 0, "phone: every centred panel fits its screen at all three phone sizes (%s; tightest %.2f on %s)",
		spilled[1] or "none spilled", tightest, tightestName)
	-- Planted fault: the same panels unfitted (scale 1) do spill, which is the bug this fixes.
	local unfitted = 0
	for _, size in ipairs(PHONE_SIZES) do
		for _, panel in ipairs(PANELS) do
			if panel.natural.Y > size.Y - (panel.inset and 58 or 0) then
				unfitted += 1
			end
		end
	end
	check(unfitted >= 6, "phone: planted fault: unfitted, %d of those 15 panel-and-screen pairs hang off the screen", unfitted)
	-- A desktop screen is untouched: every panel keeps its authored size.
	local desktopOne = true
	for _, panel in ipairs(PANELS) do
		if PhoneLayout.PanelScale(panel.natural, Vector2.new(1920, 1080), { inset = panel.inset, insetY = 58 }) ~= 1 then
			desktopOne = false
		end
	end
	check(desktopOne, "phone: at 1920x1080 every panel's scale is exactly 1, so nothing changes on a desktop screen")
	-- The drop screen is a 440-px map you tap: after fitting it is still a target, not a postage stamp.
	local dropScale = PhoneLayout.PanelScale(Vector2.new(480, 536), Vector2.new(844, 390))
	check(440 * dropScale >= 160 and 44 * dropScale >= 28,
		"phone: the drop map is still %.0f px across after fitting (%.2f scale)", 440 * dropScale, dropScale)

	PhoneLayout.Force = realForce
end

for _, section in ipairs({ { "compile", probeCompile }, { "signpost", probeSignpost }, { "defense", probeDefense }, { "swap", probeSwap }, { "swap", probeSwapPlanted }, { "ui", probeUi }, { "touch", probeTouch }, { "phone", probePhone } }) do
	if wanted(section[1]) then
		local ok, err = pcall(section[2])
		check(ok, "section %s ran%s", section[1], ok and "" or (" -> " .. tostring(err)))
	end
end
out("done: %d failures", failures)
