-- Is every gun still a gun when it is lying on the ground, and does it still READ as one from where a
-- player stands?
--
-- Oliver, playtesting build 0442: "all the gun models on the ground are now messed up" -- pickups
-- rendering as black tangles of parts rather than a gun lying down.
--
-- This file runs under BOTH harnesses, so one Studio slot buys the numbers and the pictures:
--   powershell -File tools/runtest.ps1 -Probe tools/ground_gun_probe.lua      (numbers only)
--   powershell -File tools/gallery.ps1 -Gallery tools/ground_gun_probe.lua -OutDir <dir>   (numbers + renders)
-- Under the gallery it returns the view list; under runtest the same `return` just ends the probe.
--
-- WHAT IT MEASURES, and why each one is here rather than an opinion:
--
--  1. HELD vs GROUND, part by part. Ground pickups do not use the model the viewmodel uses:
--     WeaponService.BuildStaticGun builds the gun, pivots it, destroys its welds, anchors every part
--     and reparents the parts loose under the pickup base. So the same gun is built BOTH ways and the
--     two are compared in the pivot frame -- part count, the multiset of names, each part's size and
--     its position. This is the measurement that separates "the ground path breaks the gun" from
--     "the gun is fine on the ground and something else is wrong", and nothing else can.
--  2. SHAPE: parts, overall length, mean spread from the centre, drift from where it was put.
--     A tangle is short and clustered; a gun is long and spread out.
--  3. COLOUR AND SIZE AS SEEN: a grid of rays fired from a STANDING PLAYER'S EYE at the pickup,
--     counting what fraction of the gun a player actually sees is near-black, and how many of its
--     parts are small enough to alias into a crawling line at that distance (the file's own lesson
--     about sub-pixel geometry). "Black tangle" is a statement about a picture, so it is measured
--     against a picture-shaped question, not against the part list.
--  4. THE REAL PICKUP, through LootService.DropWeapon -- the whole shipped path including
--     snapToGround, the pad, the label and ZFight.Fix(pad) -- measured against the surface it was
--     snapped to: how far the lowest part of the gun sits above that surface, and how many parts are
--     BELOW it. A gun half-sunk in the road is a black shape sticking out of the ground, and it is a
--     one-line fix, so it gets measured rather than assumed. If LootService cannot be required here
--     the run says so loudly instead of quietly measuring a stand-in.
--
-- PLANTED FAULTS (permanent, every run): a stack of parts must read as a tangle; a line of parts must
-- read as a gun; a part moved 0.5 studs must be caught by the held/ground compare; an all-black gun
-- must be reported dark; a pickup pushed under the surface must be reported sunk. Sample counts are
-- printed everywhere. A green line here with no fault caught is not a result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

-- The gallery echoes lines that start "[BRR_Gallery] note "; runtest dumps the whole log.
local IN_GALLERY = string.find(game.Name, "BRR_Gallery", 1, true) ~= nil
local PREFIX = IN_GALLERY and "[BRR_Gallery] note " or (_G.BRR_PROBE_PREFIX or "[PROBE] ")
local function out(fmt, ...)
	print(PREFIX .. string.format(fmt, ...))
end

--------------------------------------------------------------------------------
-- Limits
--------------------------------------------------------------------------------

-- A gun is at least this long once it is on the ground; anything shorter has collapsed.
local MIN_LENGTH = 1.2
-- Parts this close to each other on average have stacked rather than spread along a gun.
local MIN_SPREAD = 0.25
local MIN_PARTS = 8
-- A part this far from where the held model puts it has not survived the ground path.
local MAX_DRIFT = 0.004
-- Luminance below this is "near black" to the eye.
local DARK = 0.14
-- More of the gun than this looking black from a standing eye is what Oliver is describing.
local DARK_FRACTION = 0.7
-- A part whose largest dimension subtends less than this at the viewing distance cannot hold an edge
-- and aliases into a crawling line (COORDINATION: sub-pixel geometry, 0.14 studs, thickened to 0.19).
-- One 1080p pixel across a 70-degree view is about 0.036 degrees; this is two of them.
local SUB_PIXEL_DEGREES = 0.072

-- Where a player's eye is when he walks up to a pickup: R15 eye height, one pace back.
local EYE_HEIGHT = 4.6
local EYE_BACK = 4.5

--------------------------------------------------------------------------------
-- Geometry helpers
--------------------------------------------------------------------------------

local function luminance(c)
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
end

-- Where a ray (origin + t * direction, t in 0..1) first enters a part's real shape, or nil. Traced by
-- hand rather than with workspace:Raycast, which pads small parts by millimetres -- and a gun IS
-- millimetres.
local function interval(part, origin, direction)
	local cf = part.CFrame
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local h = part.Size / 2
	local tmin, tmax = 0, 1
	local function slab(oi, di, hi)
		if math.abs(di) < 1e-9 then
			return math.abs(oi) <= hi
		end
		local a, b = (-hi - oi) / di, (hi - oi) / di
		tmin, tmax = math.max(tmin, math.min(a, b)), math.min(tmax, math.max(a, b))
		return tmin <= tmax
	end
	local function quadratic(a, b, c)
		if a < 1e-9 then
			return c <= 0
		end
		local disc = b * b - 4 * a * c
		if disc < 0 then
			return false
		end
		local root = math.sqrt(disc)
		tmin, tmax = math.max(tmin, (-b - root) / (2 * a)), math.min(tmax, (-b + root) / (2 * a))
		return tmin <= tmax
	end
	local shape = part:IsA("Part") and part.Shape or nil
	if shape == Enum.PartType.Ball then
		local r = math.min(h.X, h.Y, h.Z)
		if not quadratic(d:Dot(d), 2 * o:Dot(d), o:Dot(o) - r * r) then
			return nil
		end
	elseif shape == Enum.PartType.Cylinder then
		local r = math.min(h.Y, h.Z)
		if not (slab(o.X, d.X, h.X) and quadratic(d.Y * d.Y + d.Z * d.Z, 2 * (o.Y * d.Y + o.Z * d.Z), o.Y * o.Y + o.Z * o.Z - r * r)) then
			return nil
		end
	elseif not (slab(o.X, d.X, h.X) and slab(o.Y, d.Y, h.Y) and slab(o.Z, d.Z, h.Z)) then
		return nil
	end
	return tmin
end

local function firstHit(parts, origin, direction)
	local best, bestT = nil, math.huge
	for _, part in ipairs(parts) do
		if part.Transparency < 0.95 then
			local t = interval(part, origin, direction)
			if t and t < bestT then
				best, bestT = part, t
			end
		end
	end
	return best, bestT
end

-- How far a part's own shape reaches below its centre, in world Y (a laid-over gun is all rotation, so
-- the box's half-height is not the answer).
local function reachDown(part)
	local f, half = part.CFrame, part.Size / 2
	return math.abs(f.RightVector.Y) * half.X + math.abs(f.UpVector.Y) * half.Y + math.abs(f.LookVector.Y) * half.Z
end

-- Shape and colour of a set of parts about a frame: longest axis, mean distance from their centre, how
-- many are near black, how far their centre drifted from `at`, and the lowest point any of them reaches.
local function measure(parts, at)
	if #parts == 0 then
		return { parts = 0, length = 0, spread = 0, black = 0, drift = 0, lowest = 0 }
	end
	local min, max = nil, nil
	local sum, black = Vector3.zero, 0
	local lowest = math.huge
	for _, part in ipairs(parts) do
		local p = part.Position
		min = min and Vector3.new(math.min(min.X, p.X), math.min(min.Y, p.Y), math.min(min.Z, p.Z)) or p
		max = max and Vector3.new(math.max(max.X, p.X), math.max(max.Y, p.Y), math.max(max.Z, p.Z)) or p
		sum += p
		if luminance(part.Color) < DARK and part.Transparency < 0.95 then
			black += 1
		end
		lowest = math.min(lowest, p.Y - reachDown(part))
	end
	local size = max - min
	local centre = sum / #parts
	local spread = 0
	for _, part in ipairs(parts) do
		spread += (part.Position - centre).Magnitude
	end
	return {
		parts = #parts,
		length = math.max(size.X, size.Y, size.Z),
		spread = spread / #parts,
		black = black,
		drift = (centre - at.Position).Magnitude,
		lowest = lowest,
		centre = centre,
		size = size,
	}
end

-- What a standing player sees: rays from the eye across the gun's own bounding box. Returns how many
-- rays hit it, what fraction of those hits landed on a near-black part, how wide it is on screen, and
-- how many of its parts are too small to hold an edge at that distance.
local function eyeView(parts, focus, span)
	local eye = focus + Vector3.new(0, EYE_HEIGHT, EYE_BACK)
	local forward = (focus - eye)
	local distance = forward.Magnitude
	local look = CFrame.lookAt(eye, focus)
	local hits, dark = 0, 0
	-- The grid covers the whole gun, not a fixed window: a 3-stud rifle sampled through a 2-stud
	-- window would report the dark fraction of its middle and call it the gun.
	local SPAN = math.max(span or 1.1, 0.6)
	local STEPS = 26
	for gx = 0, STEPS - 1 do
		for gy = 0, STEPS - 1 do
			local sx = ((gx + 0.5) / STEPS * 2 - 1) * SPAN
			local sy = ((gy + 0.5) / STEPS * 2 - 1) * SPAN
			local point = focus + look:VectorToWorldSpace(Vector3.new(sx, sy, 0))
			local part = firstHit(parts, eye, (point - eye) * 1.5)
			if part then
				hits += 1
				if luminance(part.Color) < DARK then
					dark += 1
				end
			end
		end
	end
	local sub = 0
	for _, part in ipairs(parts) do
		local biggest = math.max(part.Size.X, part.Size.Y, part.Size.Z)
		if part.Transparency < 0.95 and math.deg(math.atan(biggest / math.max(distance, 0.1))) < SUB_PIXEL_DEGREES then
			sub += 1
		end
	end
	return {
		rays = STEPS * STEPS,
		hits = hits,
		dark = dark,
		darkFraction = hits > 0 and dark / hits or 0,
		distance = distance,
		subPixel = sub,
		eye = eye,
	}
end

-- Every part of a model or a list, in the frame of `at`, bucketed by name and size so the same part in
-- two builds of the same gun lands in the same bucket. Colour is carried but NOT part of the key: a
-- recoloured part must show up as a colour difference on a matched pair, not as one part lost and
-- another gained, or the black-gun case would hide inside the lost/gained counts.
local function fingerprint(parts, at)
	local buckets = {}
	local total = 0
	for _, part in ipairs(parts) do
		local size = part.Size
		local key = string.format("%s|%.3f|%.3f|%.3f", part.Name, size.X, size.Y, size.Z)
		local list = buckets[key]
		if not list then
			list = {}
			buckets[key] = list
		end
		table.insert(list, { frame = at:ToObjectSpace(part.CFrame), colour = part.Color, transparency = part.Transparency })
		total += 1
	end
	return { buckets = buckets, total = total }
end

local function colourGap(a, b)
	return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B))
end

-- Compares two fingerprints of the same gun: the worst positional difference on a matched pair, the
-- worst turn, how many parts are missing from B, how many B has that A does not, and how many matched
-- pairs disagree about colour.
local function compare(a, b)
	local worst, worstKey, worstAngle = 0, "", 0
	local missing, extra, recoloured = 0, 0, 0
	for key, listA in pairs(a.buckets) do
		local listB = b.buckets[key]
		if not listB then
			missing += #listA
		else
			local taken = {}
			for _, pa in ipairs(listA) do
				local bestIndex, bestDistance = nil, math.huge
				for index, pb in ipairs(listB) do
					if not taken[index] then
						local d = (pa.frame.Position - pb.frame.Position).Magnitude
						if d < bestDistance then
							bestIndex, bestDistance = index, d
						end
					end
				end
				if bestIndex then
					local pb = listB[bestIndex]
					taken[bestIndex] = true
					if bestDistance > worst then
						worst, worstKey = bestDistance, key
					end
					local dot = math.clamp(pa.frame.LookVector:Dot(pb.frame.LookVector), -1, 1)
					worstAngle = math.max(worstAngle, math.deg(math.acos(dot)))
					if colourGap(pa.colour, pb.colour) > 0.02 then
						recoloured += 1
					end
				else
					missing += 1
				end
			end
			if #listB > #listA then
				extra += #listB - #listA
			end
		end
	end
	for key, listB in pairs(b.buckets) do
		if not a.buckets[key] then
			extra += #listB
		end
	end
	return { worst = worst, worstKey = worstKey, worstAngle = worstAngle, missing = missing, extra = extra, recoloured = recoloured }
end

--------------------------------------------------------------------------------
-- Stage
--------------------------------------------------------------------------------

local stage = Instance.new("Folder")
stage.Name = "BRR_GroundGuns"
stage.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

--------------------------------------------------------------------------------
-- Planted faults. Every one of these runs on every run.
--------------------------------------------------------------------------------

local plantedRun, plantedCaught = 0, 0
local function planted(name, caught, detail)
	plantedRun += 1
	if caught then
		plantedCaught += 1
	end
	out("planted fault %-34s %s%s", name, caught and "CAUGHT" or "MISSED -- THIS CHECK PROVES NOTHING",
		detail and (" (" .. detail .. ")") or "")
end

do
	local bench = Instance.new("Folder")
	bench.Name = "BRR_GroundSelfTest"
	bench.Parent = stage
	local function plant(step, colour)
		local parts = {}
		for i = 1, 12 do
			local part = Instance.new("Part")
			part.Anchored = true
			part.Size = Vector3.new(0.2, 0.2, 0.2)
			part.Color = colour or Color3.fromRGB(170, 170, 170)
			part.CFrame = CFrame.new(0, 3000, i * step)
			part.Parent = bench
			table.insert(parts, part)
		end
		return parts
	end

	local at = CFrame.new(0, 3000, 0)
	local stacked = measure(plant(0.002), at)
	planted("a stack of parts reads as a tangle", stacked.length < MIN_LENGTH and stacked.spread < MIN_SPREAD,
		string.format("%.2f long, spread %.2f, %d parts", stacked.length, stacked.spread, stacked.parts))
	local line = measure(plant(0.25), at)
	planted("a line of parts reads as a gun", line.length >= MIN_LENGTH and line.spread >= MIN_SPREAD,
		string.format("%.2f long, spread %.2f, %d parts", line.length, line.spread, line.parts))

	local black = measure(plant(0.25, Color3.fromRGB(8, 8, 9)), at)
	planted("an all-black gun reads as black", black.black == black.parts,
		string.format("%d of %d parts", black.black, black.parts))

	-- The compare must catch a part that moved. Build one gun twice and shift a single part.
	local okA, modelA = pcall(WeaponService.BuildGunModel, WeaponData.Get(ids[1]), Color3.new(1, 1, 1), Enum.Material.Metal)
	local okB, modelB = pcall(WeaponService.BuildGunModel, WeaponData.Get(ids[1]), Color3.new(1, 1, 1), Enum.Material.Metal)
	if okA and okB and modelA and modelB then
		modelA.Parent, modelB.Parent = bench, bench
		modelA:PivotTo(at)
		modelB:PivotTo(at)
		local listA, listB = {}, {}
		for _, d in ipairs(modelA:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(listA, d)
			end
		end
		for _, d in ipairs(modelB:GetDescendants()) do
			if d:IsA("BasePart") then
				table.insert(listB, d)
			end
		end
		local clean = compare(fingerprint(listA, at), fingerprint(listB, at))
		planted("two clean builds compare equal", clean.worst <= MAX_DRIFT and clean.missing == 0 and clean.extra == 0
			and clean.recoloured == 0,
			string.format("worst %.4f, %d lost, %d gained, %d recoloured, %d parts", clean.worst, clean.missing,
				clean.extra, clean.recoloured, #listA))
		local victim = listB[math.max(1, math.floor(#listB / 2))]
		victim.CFrame = victim.CFrame * CFrame.new(0.5, 0, 0)
		local shifted = compare(fingerprint(listA, at), fingerprint(listB, at))
		planted("a part moved 0.5 studs is caught", shifted.worst > MAX_DRIFT,
			string.format("worst %.4f on %s", shifted.worst, shifted.worstKey))
		victim.CFrame = victim.CFrame * CFrame.new(-0.5, 0, 0)
		-- And the black case, which is the one Oliver is reporting: every part painted near-black must
		-- come back as a colour difference on a matched pair, not as parts lost and gained.
		for _, part in ipairs(listB) do
			part.Color = Color3.fromRGB(8, 8, 9)
		end
		local blackened = compare(fingerprint(listA, at), fingerprint(listB, at))
		planted("a gun repainted black is caught", blackened.recoloured > #listB * 0.8 and blackened.missing == 0,
			string.format("%d of %d pairs recoloured, %d lost", blackened.recoloured, #listB, blackened.missing))
	else
		planted("two clean builds compare equal", false, "could not build " .. tostring(ids[1]))
		planted("a part moved 0.5 studs is caught", false, "could not build " .. tostring(ids[1]))
		planted("a gun repainted black is caught", false, "could not build " .. tostring(ids[1]))
	end
	bench:Destroy()
end

--------------------------------------------------------------------------------
-- Every gun, built the held way and the ground way, compared and measured
--------------------------------------------------------------------------------

out("--- every gun: the held model vs the ground model (%d guns) ---", #ids)

local rows = {}
local checked, broken = 0, 0
local worstDrift, worstDriftId = 0, "-"
local darkest, darkestId = 0, "-"

for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local colour = Rarity.Color(def.rarity)
	local holder = Instance.new("Folder")
	holder.Name = id
	holder.Parent = stage
	local at = CFrame.new(0, 2000, 0)
	-- The reference stands 50 studs away from the ground copy so the ray grid below can only see one
	-- of them; each is fingerprinted against its OWN frame, so the comparison is unaffected.
	local referenceAt = CFrame.new(50, 2000, 0)

	-- The reference: the model the player holds, pivoted and anchored (unanchored parts fall in a
	-- runtest window, which runs real physics, and a fallen reference would read as a drift).
	local reference, referenceParts = nil, {}
	local okRef, modelRef = pcall(WeaponService.BuildGunModel, def, colour, Enum.Material.Metal)
	if okRef and modelRef then
		modelRef.Parent = holder
		modelRef:PivotTo(referenceAt)
		for _, d in ipairs(modelRef:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
				table.insert(referenceParts, d)
			end
		end
		reference = fingerprint(referenceParts, referenceAt)
	end

	local ok, receiver, parts = pcall(WeaponService.BuildStaticGun, def, colour, Enum.Material.Metal, at, holder)
	if not ok then
		broken += 1
		out("%-22s BuildStaticGun FAILED: %s", id, tostring(receiver))
	elseif not parts or #parts == 0 then
		broken += 1
		out("%-22s no parts at all", id)
	else
		checked += 1
		local shape = measure(parts, at)
		local view = eyeView(parts, at.Position, math.max(shape.size.X, shape.size.Y, shape.size.Z) * 0.6 + 0.3)
		local diff = reference and compare(reference, fingerprint(parts, at)) or nil
		local problems = {}
		if shape.parts < MIN_PARTS then
			table.insert(problems, string.format("only %d parts", shape.parts))
		end
		if shape.length < MIN_LENGTH then
			table.insert(problems, string.format("%.2f studs long", shape.length))
		end
		if shape.spread < MIN_SPREAD then
			table.insert(problems, string.format("parts %.2f apart on average", shape.spread))
		end
		if shape.black > shape.parts * 0.8 then
			table.insert(problems, string.format("%d of %d parts black", shape.black, shape.parts))
		end
		if shape.drift > 6 then
			table.insert(problems, string.format("%.1f studs from where it was put", shape.drift))
		end
		if diff then
			if diff.missing > 0 or diff.extra > 0 then
				table.insert(problems, string.format("%d parts lost, %d gained vs the held model", diff.missing, diff.extra))
			end
			if diff.worst > MAX_DRIFT then
				table.insert(problems, string.format("a part is %.3f studs off the held model (%s)", diff.worst, diff.worstKey))
			end
			if diff.worstAngle > 0.5 then
				table.insert(problems, string.format("a part is turned %.1f deg off the held model", diff.worstAngle))
			end
			if diff.recoloured > 0 then
				table.insert(problems, string.format("%d parts a different colour from the held model", diff.recoloured))
			end
			if diff.worst > worstDrift then
				worstDrift, worstDriftId = diff.worst, id
			end
		end
		if view.darkFraction > DARK_FRACTION and view.hits > 0 then
			table.insert(problems, string.format("%.0f%% of what the eye sees is near-black", view.darkFraction * 100))
		end
		if view.darkFraction > darkest then
			darkest, darkestId = view.darkFraction, id
		end
		if #problems > 0 then
			broken += 1
		end
		table.insert(rows, {
			id = id, parts = shape.parts, length = shape.length, dark = view.darkFraction,
			hits = view.hits, sub = view.subPixel, problems = #problems,
		})
		out("%-22s %3d parts %5.2f long spread %.2f | held-vs-ground: %s | eye at %.1f studs: %d/%d rays hit, %.0f%% near-black, %d sub-pixel parts%s",
			id, shape.parts, shape.length, shape.spread,
			diff and string.format("worst %.4f studs / %.2f deg, %d lost, %d gained, %d recoloured", diff.worst,
				diff.worstAngle, diff.missing, diff.extra, diff.recoloured) or "no reference built",
			view.distance, view.hits, view.rays, view.darkFraction * 100, view.subPixel,
			#problems > 0 and ("  -> MESSED UP: " .. table.concat(problems, ", ")) or "  -> ok")
	end
	holder:Destroy()
	task.wait()
end

out("%d guns built the way a ground pickup builds them, %d with a problem; worst held-vs-ground drift %.4f studs (%s); darkest to the eye %.0f%% (%s)",
	checked, broken, worstDrift, worstDriftId, darkest * 100, darkestId)

--------------------------------------------------------------------------------
-- The real pickup: LootService's own path, on a real surface
--------------------------------------------------------------------------------

local SHOWCASE = { "TralalaShotgun", "PocketPopper", "CrumblyCarbine" }

-- snapToGround only counts workspace.Terrain and workspace.Map, so the test floor has to be a real
-- Map the way the game's is, or the snap falls back to "two studs below the spot" and the whole
-- measurement would be of the fallback rather than of the path.
local function buildGround(parent, centre)
	local map = parent:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = parent
	end
	local road = Instance.new("Part")
	road.Name = "BRR_TestGround"
	road.Anchored = true
	road.Size = Vector3.new(60, 2, 60)
	road.CFrame = CFrame.new(centre - Vector3.new(0, 1, 0))
	road.Color = Color3.fromRGB(104, 102, 98)
	road.Material = Enum.Material.Concrete
	road.Parent = map
	return road, map
end

local GROUND = Vector3.new(0, 1000, 0)
local testRoad, testMap = buildGround(workspace, GROUND)

local LootService
do
	local ok, module = pcall(function()
		return require(ServerScriptService:WaitForChild("Modules"):WaitForChild("LootService"))
	end)
	if ok then
		LootService = module
	else
		out("LootService COULD NOT BE REQUIRED here (%s) -- the pickup section below is NOT the shipped path", tostring(module))
	end
end

local pickups = {}
if LootService then
	out("--- the real pickup path (LootService.DropWeapon), on ground whose surface is y = %.2f ---", GROUND.Y)
	for _, id in ipairs(SHOWCASE) do
		local before = {}
		local loot = workspace:FindFirstChild("Loot")
		if loot then
			for _, child in ipairs(loot:GetChildren()) do
				before[child] = true
			end
		end
		local okDrop, err = pcall(LootService.DropWeapon, id, GROUND + Vector3.new(0, 0.5, 0))
		loot = workspace:FindFirstChild("Loot")
		local base = nil
		if okDrop and loot then
			for _, child in ipairs(loot:GetChildren()) do
				if not before[child] and child:GetAttribute("WeaponId") == id then
					base = child
				end
			end
		end
		if not base then
			out("%-22s DropWeapon produced no pickup (%s)", id, tostring(err))
		else
			local gunParts, padParts = {}, {}
			for _, child in ipairs(base:GetChildren()) do
				if child:IsA("BasePart") then
					-- The pad discs (and a Legendary's beam) are built by LootService's own `detail`,
					-- which never names them, so they arrive as plain "Part"; every gun piece carries
					-- the name its builder gave it. Sorting them by SIZE instead got this wrong -- a
					-- cylinder's length is its X, so the flat discs are 0.18 x 2.8 x 2.8, not the other
					-- way round -- and the "lowest point above the surface" below was really the pad's.
					if child.Name == "Part" then
						table.insert(padParts, child)
					else
						table.insert(gunParts, child)
					end
				end
			end
			local shape = measure(gunParts, base.CFrame)
			local view = eyeView(gunParts, base.Position, math.max(shape.size.X, shape.size.Y, shape.size.Z) * 0.6 + 0.3)
			local surface = testRoad.Position.Y + testRoad.Size.Y / 2
			local below = 0
			for _, part in ipairs(gunParts) do
				if part.Position.Y - reachDown(part) < surface - 0.01 then
					below += 1
				end
			end
			table.insert(pickups, { id = id, base = base, gunParts = gunParts, surface = surface })
			out("%-22s %3d gun parts + %d pad, lowest point %.2f studs above the surface, %d parts BELOW it; eye at %.1f studs: %d/%d rays hit, %.0f%% near-black, %d sub-pixel",
				id, #gunParts, #padParts, shape.lowest - surface, below, view.distance, view.hits, view.rays,
				view.darkFraction * 100, view.subPixel)
		end
		task.wait()
	end

	-- Planted: a pickup pushed under the surface must be reported sunk, or the measurement above could
	-- not have found a sunk one either.
	if #pickups > 0 then
		local victim = pickups[1]
		local sunkBefore = 0
		for _, part in ipairs(victim.gunParts) do
			if part.Position.Y - reachDown(part) < victim.surface - 0.01 then
				sunkBefore += 1
			end
		end
		for _, part in ipairs(victim.gunParts) do
			part.CFrame = part.CFrame - Vector3.new(0, 3, 0)
		end
		local sunkAfter = 0
		for _, part in ipairs(victim.gunParts) do
			if part.Position.Y - reachDown(part) < victim.surface - 0.01 then
				sunkAfter += 1
			end
		end
		for _, part in ipairs(victim.gunParts) do
			part.CFrame = part.CFrame + Vector3.new(0, 3, 0)
		end
		planted("a pickup pushed 3 studs under is sunk", sunkBefore == 0 and sunkAfter == #victim.gunParts,
			string.format("%d of %d parts below the surface before, %d after", sunkBefore, #victim.gunParts, sunkAfter))
	else
		planted("a pickup pushed 3 studs under is sunk", false, "no pickup was made to push")
	end
else
	planted("a pickup pushed 3 studs under is sunk", false, "LootService not available")
end

--------------------------------------------------------------------------------
-- The one link nothing else here can see: the client-side spin
--------------------------------------------------------------------------------

-- A ground pickup does not sit still. `AmbientClient` turns it, on each client, by measuring every
-- part's offset from the base's REST frame once and then writing `rest * yaw * offset` every frame.
-- That is a LocalScript, so it does not run in a runtest window or an edit-mode gallery at all -- which
-- makes it the only part of the chain that has never been checked, and a spin that measured its
-- offsets from an already-turned frame would smear the gun a little further every revolution. That is
-- what a "tangle" would look like.
--
-- So the same arithmetic is run here, by hand, against a real pickup, and the gun's SHAPE is measured
-- at a series of angles. A rigid turn cannot change the distances between parts; anything that does is
-- the bug. The planted fault re-measures the offsets while the gun is turned, which is precisely the
-- mistake the real code is written to avoid -- and it must come out worse.
local function spinShape(parts, restFrame, angle, remeasure)
	if #parts == 0 then
		return 0, 0
	end
	local offsets = {}
	for index, part in ipairs(parts) do
		offsets[index] = restFrame:ToObjectSpace(part.CFrame)
	end
	local frame = restFrame * CFrame.Angles(0, angle, 0)
	local spread, longest = 0, 0
	local centre = Vector3.zero
	local placed = {}
	for index, part in ipairs(parts) do
		local at = (frame * offsets[index]).Position
		placed[index] = at
		centre += at
	end
	centre /= #parts
	for _, at in ipairs(placed) do
		local d = (at - centre).Magnitude
		spread += d
		longest = math.max(longest, d)
	end
	if remeasure then
		-- The mistake: move the parts to the turned pose and let the NEXT measurement be taken from
		-- there, so the error compounds. The real code puts everything back to rest first.
		for index, part in ipairs(parts) do
			part.CFrame = frame * offsets[index]
		end
	end
	return spread / #parts, longest
end

if LootService and #pickups > 0 then
	local victim = pickups[1]
	local parts = victim.gunParts
	local rest = victim.base.CFrame
	local baseSpread, baseLongest = spinShape(parts, rest, 0)
	local worst, worstAngle = 0, 0
	for step = 1, 12 do
		local angle = step / 12 * math.pi * 2
		local spread = spinShape(parts, rest, angle)
		local drift = math.abs(spread - baseSpread)
		if drift > worst then
			worst, worstAngle = drift, math.deg(angle)
		end
	end
	out("spin: %s turned through a full revolution in 12 steps -- mean spread %.4f studs at rest, worst change %.6f studs (at %.0f deg), longest arm %.3f",
		victim.id, baseSpread, worst, worstAngle, baseLongest)
	-- The fault this must be able to catch is NOT "the rotation is wrong". A rotation is rigid, and no
	-- composition of rotations can change the distances between parts -- which is why the twelve-angle
	-- result above is a proof that the spin cannot tangle a pickup, rather than merely a pass. (An
	-- earlier version of this planted fault re-measured from a turned pose and expected a smear; it
	-- could never have fired, for exactly that reason, and a check that cannot fail is the thing this
	-- project keeps catching itself doing.)
	-- The fault that IS reachable is per-part divergence: `addToGroup` stores a late-arriving part's
	-- offset against the base's rest frame, and if that part has already been moved by an earlier turn
	-- its stored offset silently carries that turn, so it rides one more revolution than its
	-- neighbours. The gun then comes apart a part at a time. Half the parts are given that extra turn.
	local half = math.floor(#parts / 2)
	local extra = CFrame.Angles(0, math.pi / 3, 0)
	local saved = {}
	for index = 1, half do
		saved[index] = parts[index].CFrame
		parts[index].CFrame = rest * extra * rest:ToObjectSpace(parts[index].CFrame)
	end
	local smeared = spinShape(parts, rest, 0)
	for index = 1, half do
		parts[index].CFrame = saved[index]
	end
	planted("half the parts riding an extra turn smears", math.abs(smeared - baseSpread) > 0.002,
		string.format("mean spread %.4f -> %.4f studs with %d of %d parts one turn ahead",
			baseSpread, smeared, half, #parts))
else
	planted("half the parts riding an extra turn smears", false, "no pickup to turn")
end

--------------------------------------------------------------------------------
-- Shadows: how many of a pickup's parts cast one
--------------------------------------------------------------------------------

-- A hypothesis this run is here to kill or confirm. A ground pickup is a hundred-odd parts a few
-- millimetres across, and GunModels' builder never touches `CastShadow`, so every one of them casts a
-- real shadow onto its neighbours. The FIRST-PERSON copy does not: `Viewmodel.localOnly` sets
-- `CastShadow = false` on every part it makes, and LootService's own `detail` decides it per part too.
-- So the world copy is the only one left self-shadowing, and a hundred sub-centimetre parts shadowing
-- each other under a real sun is a very good way to turn a gun into a dark mass -- which would also
-- have got steadily worse through a day of adding detail, matching "they are messed up NOW".
-- This counts it; the renders below photograph it both ways under the same sun.
do
	local counted, casters, total = 0, 0, 0
	local worst, worstId = 0, "-"
	for _, id in ipairs(ids) do
		local def = WeaponData.Get(id)
		local holder = Instance.new("Folder")
		holder.Parent = stage
		local ok, _, parts = pcall(WeaponService.BuildStaticGun, def, Rarity.Color(def.rarity), Enum.Material.Metal,
			CFrame.new(0, 2500, 0), holder)
		if ok and parts then
			local shadowing = 0
			for _, part in ipairs(parts) do
				total += 1
				if part.CastShadow and part.Transparency < 0.95 then
					shadowing += 1
					casters += 1
				end
			end
			counted += 1
			if shadowing > worst then
				worst, worstId = shadowing, id
			end
		end
		holder:Destroy()
	end
	out("shadows: %d of %d parts on %d ground guns cast a shadow (%.0f%%); the worst single pickup is %s with %d shadow casters",
		casters, total, counted, total > 0 and casters / total * 100 or 0, worstId, worst)
	out("shadows: for comparison the first-person copy casts NONE -- Viewmodel.localOnly sets CastShadow false on every part it builds")
end

out("planted faults: %d of %d caught (want %d of %d)", plantedCaught, plantedRun, plantedRun, plantedRun)

-- The measured pickups go before anything is rendered: the renders drop their own.
if LootService then
	pcall(LootService.Clear)
end

if not IN_GALLERY then
	stage:Destroy()
	if testRoad then
		testRoad:Destroy()
	end
	if testMap then
		testMap:Destroy()
	end
	out("done")
	return {}
end

--------------------------------------------------------------------------------
-- Renders (gallery only): the pickups from where a player stands
--------------------------------------------------------------------------------

-- Daylight with REAL shadows, and the sun off to one side rather than overhead: a pickup photographed
-- at noon under a flat studio light is a pickup whose self-shadowing you cannot see, and that is the
-- thing being tested. Nothing here is a game setting; it is this gallery's own scene.
Lighting.ClockTime = 15.5
Lighting.Brightness = 2.6
Lighting.ExposureCompensation = 0.1
Lighting.Ambient = Color3.fromRGB(78, 78, 84)
Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 136)
Lighting.GlobalShadows = true

-- Everything already built for the measurements is thrown away: the gallery clears its own folder
-- between views, and each view rebuilds what it needs there instead.
stage:Destroy()
if testRoad then
	testRoad:Destroy()
end
if testMap then
	testMap:Destroy()
end

local VIEW_ORIGIN = Vector3.new(0, 1200, 0)

-- The ground has to live in `workspace.Map`, NOT in the gallery's own folder: `LootService`'s
-- `snapToGround` and `scatter` only raycast against `workspace.Terrain` and `workspace.Map`, and with
-- neither of them there BOTH fall back to "two studs below the spot" -- so every pickup in the first
-- run of this gallery buried itself four studs under the floor and photographed as bare ground. The
-- frame check passed anyway, because being inside the camera's cone is not the same as being VISIBLE.
-- That is why there is an occlusion test below as well.
local function scene(folder)
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = workspace
	end
	local old = map:FindFirstChild("GalleryGround")
	if old then
		old:Destroy()
	end
	local road = Instance.new("Part")
	road.Name = "GalleryGround"
	road.Anchored = true
	road.Size = Vector3.new(90, 2, 90)
	road.CFrame = CFrame.new(VIEW_ORIGIN - Vector3.new(0, 1, 0))
	road.Color = Color3.fromRGB(104, 102, 98)
	road.Material = Enum.Material.Concrete
	road.Parent = map
	-- Something upright to judge the gun's size against, a pace behind it.
	local post = Instance.new("Part")
	post.Anchored = true
	post.Size = Vector3.new(0.6, 5, 0.6)
	post.CFrame = CFrame.new(VIEW_ORIGIN + Vector3.new(6, 2.5, -6))
	post.Color = Color3.fromRGB(150, 148, 142)
	post.Material = Enum.Material.Concrete
	post.Parent = folder
	return road
end

-- Puts a pickup down through the shipped path when it is available, and says in the log which path it
-- used, so a render of a stand-in can never be mistaken for a render of the game.
local function drop(folder, id, offset)
	local at = VIEW_ORIGIN + offset
	if LootService then
		local loot = workspace:FindFirstChild("Loot")
		local before = {}
		if loot then
			for _, child in ipairs(loot:GetChildren()) do
				before[child] = true
			end
		end
		pcall(LootService.DropWeapon, id, at + Vector3.new(0, 0.5, 0))
		loot = workspace:FindFirstChild("Loot")
		if loot then
			for _, child in ipairs(loot:GetChildren()) do
				if not before[child] and child:GetAttribute("WeaponId") == id then
					-- Moved under the gallery folder so the next view clears it.
					child.Parent = folder
					return child
				end
			end
		end
	end
	-- Stand-in: the same arithmetic spawnGroundWeapon uses, said out loud.
	out("render of %s uses the STAND-IN pickup, not LootService", id)
	local base = Instance.new("Part")
	base.Name = "GroundWeapon"
	base.Size = Vector3.new(2.4, 0.4, 2.4)
	base.Transparency = 1
	base.Anchored = true
	base.CanCollide = false
	base.CFrame = CFrame.new(at + Vector3.new(0, 0.3, 0))
	base.Parent = folder
	local def = WeaponData.Get(id)
	WeaponService.BuildStaticGun(def, Rarity.Color(def.rarity), Enum.Material.Metal,
		base.CFrame * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, math.pi / 2, math.rad(-10)), base)
	return base
end

-- Every render view says whether its target is IN FRAME: the target in camera space, the distance and
-- the angle off centre. A camera helper that frames nothing produces a photograph of empty sky and the
-- note under it still reads fine (COORDINATION, claude-0d).
-- IN FRAME is not VISIBLE. The first run of this gallery reported every view IN FRAME and photographed
-- bare ground, because the pickups were under the floor: inside the camera's cone, behind a part. So
-- this also casts from the camera to the target and says what it meets on the way.
local function frameCheck(name, camera, target, subject)
	local point = camera.CFrame:PointToObjectSpace(target)
	local forward = -point.Z
	local off = math.deg(math.atan2(math.sqrt(point.X * point.X + point.Y * point.Y), math.max(forward, 1e-6)))
	local inFrame = forward > 0 and off < camera.FieldOfView / 2
	local blocker = nil
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = subject and { subject } or {}
	local hit = workspace:Raycast(camera.CFrame.Position, (target - camera.CFrame.Position) * 0.995, params)
	if hit then
		blocker = hit.Instance:GetFullName()
	end
	out("view %-28s target %s and %s: %.2f studs ahead, %.1f deg off centre (fov %.0f)%s", name,
		inFrame and "IN FRAME" or "NOT IN FRAME", blocker and "BLOCKED" or "in the open",
		forward, off, camera.FieldOfView, blocker and ("  blocked by " .. blocker) or "")
end

local views = {
	{
		name = "warmup",
		setup = function(folder, camera)
			scene(folder)
			camera.FieldOfView = 70
			camera.CFrame = CFrame.new(VIEW_ORIGIN + Vector3.new(0, EYE_HEIGHT, 12), VIEW_ORIGIN)
		end,
	},
}

-- The shot Oliver is owed: three pickups lying in front of him, seen from standing height.
table.insert(views, {
	name = "three_pickups_standing",
	settle = 1.4,
	hold = 2,
	setup = function(folder, camera)
		scene(folder)
		local made = {}
		for index, id in ipairs(SHOWCASE) do
			table.insert(made, drop(folder, id, Vector3.new((index - 2) * 4.5, 0, 0)))
		end
		local centre = VIEW_ORIGIN
		-- Where each one actually landed, against the surface it was dropped on: a pickup that snapped
		-- itself underground is a number here, not only a disappointing photograph.
		local surface = VIEW_ORIGIN.Y
		for index, base in ipairs(made) do
			if base then
				out("pickup %d (%s) sits %.2f studs above the surface at %s", index, SHOWCASE[index] or "?",
					base.Position.Y - surface, tostring(base.Position))
			end
		end
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(0, EYE_HEIGHT, 9), centre + Vector3.new(0, 1.4, 0))
		frameCheck("three_pickups_standing", camera, made[2] and (made[2].Position + Vector3.new(0, 1.5, 0)) or centre, made[2])
	end,
})

-- One at a time, from a pace away, which is where the prompt appears and where he is looking when he
-- picks it up.
for _, id in ipairs(SHOWCASE) do
	table.insert(views, {
		name = "pickup_" .. id,
		settle = 1.4,
		hold = 2,
		setup = function(folder, camera)
			scene(folder)
			local base = drop(folder, id, Vector3.zero)
			local focus = base and base.Position + Vector3.new(0, 1.5, 0) or VIEW_ORIGIN
			camera.FieldOfView = 70
			camera.CFrame = CFrame.lookAt((base and base.Position or VIEW_ORIGIN) + Vector3.new(0, EYE_HEIGHT, EYE_BACK), focus)
			frameCheck("pickup_" .. id, camera, focus, base)
		end,
	})
	table.insert(views, {
		name = "pickup_close_" .. id,
		settle = 1.4,
		hold = 2,
		setup = function(folder, camera)
			scene(folder)
			local base = drop(folder, id, Vector3.zero)
			local focus = base and base.Position + Vector3.new(0, 1.5, 0) or VIEW_ORIGIN
			camera.FieldOfView = 40
			camera.CFrame = CFrame.lookAt(focus + Vector3.new(2.6, 0.9, 2.6), focus)
			frameCheck("pickup_close_" .. id, camera, focus, base)
		end,
	})
end

-- The same pickup twice under the same sun, once as it ships (every part casting a shadow onto its
-- neighbours) and once with the shadows off. If the shipped one reads as a dark mass and the other
-- reads as a gun, that is the answer; if they look the same, the hypothesis is dead and says so.
for _, id in ipairs({ "TralalaShotgun", "PocketPopper" }) do
	for _, case in ipairs({ { "asshipped", true }, { "noselfshadow", false } }) do
		table.insert(views, {
			name = "shadow_" .. case[1] .. "_" .. id,
			settle = 1.4,
			hold = 2,
			setup = function(folder, camera)
				scene(folder)
				local base = drop(folder, id, Vector3.zero)
				local changed = 0
				if base and not case[2] then
					for _, child in ipairs(base:GetChildren()) do
						if child:IsA("BasePart") and child.Name ~= "Part" then
							child.CastShadow = false
							changed += 1
						end
					end
				end
				local focus = base and base.Position + Vector3.new(0, 1.5, 0) or VIEW_ORIGIN
				out("view shadow_%s_%s: %d parts had their shadow turned off", case[1], id, changed)
				camera.FieldOfView = 45
				camera.CFrame = CFrame.lookAt((base and base.Position or VIEW_ORIGIN) + Vector3.new(0, 3.2, 5.5), focus)
				frameCheck("shadow_" .. case[1] .. "_" .. id, camera, focus, base)
			end,
		})
	end
end

-- Oliver: "get rid of the pad ... just make them glow the colour of their tier instead."
-- The questions that decide it are all "can you see it", so they are all pictures.
--
-- NOTE, said out loud because it would otherwise be a stand-in: the rim is created `Enabled = false`
-- and AmbientClient lights it as the camera comes near. AmbientClient is a LocalScript and does not
-- run in an edit-mode gallery, so these views switch it on by hand -- which is what the client does
-- at close range. What is photographed is the real Highlight on the real pickup; what is NOT proven
-- here is the client's distance gate, which needs a play test.
local function lightGlow(base, on)
	local glow = base and base:FindFirstChild("RarityGlow")
	if glow then
		glow.Enabled = on
	end
	return glow ~= nil
end

for _, distance in ipairs({ 10, 25, 60 }) do
	for _, case in ipairs({ { "glow", true }, { "noglow", false } }) do
		table.insert(views, {
			name = string.format("glow_%dstud_%s", distance, case[1]),
			settle = 1.4,
			hold = 2,
			setup = function(folder, camera)
				scene(folder)
				local made = {}
				-- One Common and one Uncommon, which is all the map itself ever drops loose, plus a
				-- Legendary to show a high tier (it reaches the floor only from a death drop).
				for index, id in ipairs({ "PocketPopper", "TralalaShotgun", "GoldenSahurCannon" }) do
					local base = drop(folder, id, Vector3.new((index - 2) * 4.5, 0, 0))
					if base then
						lightGlow(base, case[2])
						table.insert(made, base)
					end
				end
				local focus = VIEW_ORIGIN + Vector3.new(0, 1.2, 0)
				camera.FieldOfView = 70
				camera.CFrame = CFrame.lookAt(VIEW_ORIGIN + Vector3.new(0, EYE_HEIGHT, distance), focus)
				out("view glow_%dstud_%s: %d pickups, rim %s", distance, case[1], #made, case[2] and "lit" or "off")
				frameCheck(string.format("glow_%dstud_%s", distance, case[1]), camera, focus, made[1])
			end,
		})
	end
end

-- How many Highlights actually render at once. Roblox drops the surplus silently, and a map carries
-- far more pickups than the cap, so this is the measurement that decides whether the glow can ever be
-- always-on: forty pickups in a grid, all lit, all the same distance away. Count the rims in the
-- picture. If fewer than forty glow, the distance gate is not an optimisation, it is the only version
-- that works.
table.insert(views, {
	name = "glow_fortypickups_cap",
	settle = 2,
	hold = 2.5,
	setup = function(folder, camera)
		scene(folder)
		local lit = 0
		for index = 1, 40 do
			local row, column_ = math.floor((index - 1) / 8), (index - 1) % 8
			local base = drop(folder, index % 2 == 0 and "PocketPopper" or "TralalaShotgun",
				Vector3.new((column_ - 3.5) * 3.2, 0, -row * 3.2))
			if base and lightGlow(base, true) then
				lit += 1
			end
		end
		out("view glow_fortypickups_cap: %d rims switched on; count how many the picture actually shows", lit)
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(VIEW_ORIGIN + Vector3.new(0, 9, 16), VIEW_ORIGIN + Vector3.new(0, 0, -6))
		frameCheck("glow_fortypickups_cap", camera, VIEW_ORIGIN + Vector3.new(0, 0, -6))
	end,
})

out("gallery: %d views", #views)
return views
