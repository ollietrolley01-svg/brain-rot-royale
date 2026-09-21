-- Z-fighting guard.
--
-- Two faces that lie in the same plane, point the same way and overlap flicker against each
-- other as the camera moves: a trim set flush with its wall, a floor ring whose top is exactly
-- the floor's own height, a badge sunk into a crate so its front is level with the body, a slab
-- whose top sits right at the ground's surface. Everything in the game is built from parts by
-- code, so rather than trusting every offset was typed right, each thing runs through this
-- once it's assembled: the map and the lobby after their build, and every gun, item, crate,
-- brainrot and accessory model before its welds go in.
--
-- Fix() finds the fighting pairs and nudges the smaller face out along the shared normal until
-- there's a clear gap. When a thin part pokes out of a body by the same hair on opposite sides
-- (a band round a crate) it grows the part instead, so both sides clear; when it's sunk just
-- under the surface on both sides it shrinks it further in, out of sight. Moves are a few
-- hundredths of a stud: invisible, and enough.
--
--   ZFight.Fix(roots, options)            -> { moved, resized, passes, remaining = { pair... } }
--   ZFight.Scan(roots, tolerance)         -> the pairs still fighting (the build check uses this)
--   ZFight.Report(roots, groupOf, limit)  -> what Fix had to touch, grouped, for the build check
--   ZFight.Describe(pairs, groupOf, limit)-> lines describing Scan's pairs
--
-- options: tolerance (faces closer than this along their normal count; default Tolerance), gap
-- (what Fix leaves; default Gap), passes (default Passes), yield (task.wait now and then, for
-- big builds), all (move unanchored parts too, for a model whose welds aren't in yet; by
-- default only anchored parts move), terrain (lift tops sitting at the ground's surface;
-- default on, and only for parts in the workspace).
--
-- Moved parts carry a ZFixed attribute (how far, summed) and ZFixedWith (what they fought),
-- so the build check can list the patterns worth tidying at source.

local ZFight = {}

-- Faces closer than Tolerance along their shared normal are reported as fighting; Fix goes
-- after anything closer than FixTolerance, a little wider, so a pair it leaves at Gap can't be
-- tipped back under Tolerance by float rounding out at the lobby's coordinates. MinOverlap
-- ignores faces that merely share an edge (tiles side by side) but not a sliver of overlap.
ZFight.Tolerance = 0.045
ZFight.FixTolerance = 0.055
ZFight.Gap = 0.06
ZFight.MinOverlap = 0.02
ZFight.FixMinOverlap = 0.01
ZFight.Passes = 8
-- Debugging aids for tools/runtest.ps1 probes: Enabled false makes Fix a no-op (to see raw
-- geometry), Trace prints every nudge.
ZFight.Enabled = true
ZFight.Trace = false

local PARALLEL = 0.9995
local HIDDEN = 0.98

--------------------------------------------------------------------------------
-- Parts and faces
--------------------------------------------------------------------------------

local function isPart(instance, includeHidden)
	return instance:IsA("BasePart") and not instance:IsA("Terrain") and (includeHidden or instance.Transparency < HIDDEN)
end

-- The visible parts under `roots` (parts themselves count too), each once.
function ZFight.Parts(roots, includeHidden)
	local parts, seen = {}, {}
	local function add(instance)
		if not seen[instance] and isPart(instance, includeHidden) then
			seen[instance] = true
			parts[#parts + 1] = instance
		end
	end
	-- pairs, not ipairs: callers pass FindFirstChild results that may be nil.
	for _, root in pairs(roots) do
		if typeof(root) == "Instance" then
			add(root)
			for _, descendant in ipairs(root:GetDescendants()) do
				add(descendant)
			end
		end
	end
	return parts
end

-- A part's flat faces: normal, centre, the two in-plane axes and half extents. Balls have none;
-- cylinders have their two ends (squared off a little inside the circle); wedges their bottom,
-- back, the rectangle that fits inside each triangular side, and the slope; corner wedges just
-- the bottom; meshes nothing.
local function facesOf(part)
	local faces = {}
	local cf, size = part.CFrame, part.Size
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local X, Y, Z = cf.XVector, cf.YVector, cf.ZVector
	local p = cf.Position
	local function add(n, c, u, v, hu, hv)
		faces[#faces + 1] = { n = n, c = c, u = u, v = v, hu = hu, hv = hv, area = 4 * hu * hv }
	end

	local class = part.ClassName
	if class == "Part" then
		local shape = part.Shape
		if shape == Enum.PartType.Ball then
			return faces
		elseif shape == Enum.PartType.Cylinder then
			local r = math.min(hy, hz) * 0.8
			add(X, p + X * hx, Y, Z, r, r)
			add(-X, p - X * hx, Y, Z, r, r)
			return faces
		end
		local mesh = part:FindFirstChildOfClass("SpecialMesh")
		if mesh and mesh.MeshType ~= Enum.MeshType.Brick then
			return faces
		end
	elseif class == "WedgePart" then
		add(-Y, p - Y * hy, X, Z, hx, hz)
		add(Z, p + Z * hz, X, Y, hx, hy)
		local sideCentre = Z * (hz / 2) - Y * (hy / 2)
		add(X, p + X * hx + sideCentre, Y, Z, hy / 2, hz / 2)
		add(-X, p - X * hx + sideCentre, Y, Z, hy / 2, hz / 2)
		local along = Y * hy + Z * hz
		local slope = Y * hz - Z * hy
		if slope.Magnitude > 1e-4 then
			add(slope.Unit, p, X, along.Unit, hx, along.Magnitude)
		end
		return faces
	elseif class == "CornerWedgePart" then
		add(-Y, p - Y * hy, X, Z, hx, hz)
		return faces
	else
		return faces
	end

	add(X, p + X * hx, Y, Z, hy, hz)
	add(-X, p - X * hx, Y, Z, hy, hz)
	add(Y, p + Y * hy, X, Z, hx, hz)
	add(-Y, p - Y * hy, X, Z, hx, hz)
	add(Z, p + Z * hz, X, Y, hx, hy)
	add(-Z, p - Z * hz, X, Y, hx, hy)
	return faces
end

-- Whether a part can be grown along `axis` (its local X/Y/Z) without changing its shape: blocks
-- and cylinders on any axis, a wedge only across its width (its profile lives in Y and Z).
local function resizable(part, axis)
	local class = part.ClassName
	if class == "WedgePart" then
		return axis == "X"
	elseif class ~= "Part" then
		return false
	end
	local shape = part.Shape
	return shape == Enum.PartType.Block or shape == Enum.PartType.Cylinder
end

local function refresh(entry)
	local part = entry.part
	local cf, size = part.CFrame, part.Size
	local xv, yv, zv = cf.XVector, cf.YVector, cf.ZVector
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local ex = math.abs(xv.X) * hx + math.abs(yv.X) * hy + math.abs(zv.X) * hz
	local ey = math.abs(xv.Y) * hx + math.abs(yv.Y) * hy + math.abs(zv.Y) * hz
	local ez = math.abs(xv.Z) * hx + math.abs(yv.Z) * hy + math.abs(zv.Z) * hz
	local p = cf.Position
	entry.x0, entry.x1 = p.X - ex, p.X + ex
	entry.y0, entry.y1 = p.Y - ey, p.Y + ey
	entry.z0, entry.z1 = p.Z - ez, p.Z + ez
	entry.faces = nil
end

local function entriesFor(parts)
	local entries = table.create(#parts)
	for index, part in ipairs(parts) do
		local entry = { part = part }
		refresh(entry)
		entries[index] = entry
	end
	return entries
end

--------------------------------------------------------------------------------
-- Finding fighting faces
--------------------------------------------------------------------------------

-- How much two coplanar rectangles overlap, in the plane, or nil if they don't (or only touch
-- along an edge). Separating-axis test on the four edge directions, in `fa`'s frame.
local function overlap2D(fa, fb, minOverlap)
	local d = fb.c - fa.c
	local bx, by = d:Dot(fa.u), d:Dot(fa.v)
	local bu = Vector2.new(fb.u:Dot(fa.u), fb.u:Dot(fa.v))
	local bv = Vector2.new(fb.v:Dot(fa.u), fb.v:Dot(fa.v))
	local smallest = math.huge
	for _, axis in ipairs({ Vector2.new(1, 0), Vector2.new(0, 1), bu, bv }) do
		if axis.Magnitude > 1e-4 then
			axis = axis.Unit
			local ra = fa.hu * math.abs(axis.X) + fa.hv * math.abs(axis.Y)
			local rb = fb.hu * math.abs(bu:Dot(axis)) + fb.hv * math.abs(bv:Dot(axis))
			local centre = bx * axis.X + by * axis.Y
			local overlap = (ra + rb) - math.abs(centre)
			if overlap < minOverlap then
				return nil
			end
			smallest = math.min(smallest, overlap)
		end
	end
	return smallest
end

-- Every pair of coplanar, same-facing, overlapping faces among `entries`. Sort-and-sweep along
-- X for the candidates, then the face test.
local function sweep(entries, opts)
	table.sort(entries, function(a, b)
		return a.x0 < b.x0
	end)
	local pad = opts.tolerance + 0.02
	local found = {}
	local count = #entries
	for i = 1, count do
		local a = entries[i]
		local limit = a.x1 + pad
		for j = i + 1, count do
			local b = entries[j]
			if b.x0 > limit then
				break
			end
			if b.y0 <= a.y1 + pad and a.y0 <= b.y1 + pad and b.z0 <= a.z1 + pad and a.z0 <= b.z1 + pad then
				if not a.faces then
					a.faces = facesOf(a.part)
				end
				if not b.faces then
					b.faces = facesOf(b.part)
				end
				for _, fa in ipairs(a.faces) do
					for _, fb in ipairs(b.faces) do
						if fa.n:Dot(fb.n) > PARALLEL then
							local gap = (fb.c - fa.c):Dot(fa.n)
							if math.abs(gap) < opts.tolerance then
								local overlap = overlap2D(fa, fb, opts.minOverlap)
								if overlap then
									found[#found + 1] = { a = a, b = b, fa = fa, fb = fb, gap = gap, overlap = overlap }
								end
							end
						end
					end
				end
			end
		end
		if opts.yield and i % 1500 == 0 then
			task.wait()
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- Terrain
--------------------------------------------------------------------------------

local function terrainParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = false
	return params
end

-- Points across an upward face to test the ground under: the centre, and a spread on big faces.
local function samplePoints(face)
	local points = { face.c }
	if face.hu > 6 or face.hv > 6 then
		for _, s in ipairs({ { 0.6, 0.6 }, { -0.6, 0.6 }, { 0.6, -0.6 }, { -0.6, -0.6 } }) do
			points[#points + 1] = face.c + face.u * (face.hu * s[1]) + face.v * (face.hv * s[2])
		end
	end
	return points
end

-- How far a part's upward face sits from the ground surface when it's within tolerance of it,
-- as the lift that would clear it; nil when it's clear already.
local function terrainLift(entry, params, opts)
	local part = entry.part
	if not part:IsDescendantOf(workspace) then
		return nil
	end
	if not entry.faces then
		entry.faces = facesOf(part)
	end
	local lift = nil
	for _, face in ipairs(entry.faces) do
		if face.n.Y > 0.999 then
			for _, point in ipairs(samplePoints(face)) do
				local hit = workspace:Raycast(point + Vector3.new(0, 0.5, 0), Vector3.new(0, -1, 0), params)
				if hit then
					local above = point.Y - hit.Position.Y
					if math.abs(above) < opts.tolerance then
						lift = math.max(lift or 0, opts.gap - above)
					end
				end
			end
		end
	end
	return lift
end

--------------------------------------------------------------------------------
-- Fixing
--------------------------------------------------------------------------------

-- Which of a part's local axes a world direction runs along, and which way (+1 / -1).
local function faceKey(cf, n)
	local dx, dy, dz = n:Dot(cf.XVector), n:Dot(cf.YVector), n:Dot(cf.ZVector)
	local ax, ay, az = math.abs(dx), math.abs(dy), math.abs(dz)
	if ax >= ay and ax >= az then
		return "X", dx >= 0 and 1 or -1
	elseif ay >= az then
		return "Y", dy >= 0 and 1 or -1
	end
	return "Z", dz >= 0 and 1 or -1
end

local function axisVector(cf, axis)
	if axis == "X" then
		return cf.XVector
	elseif axis == "Y" then
		return cf.YVector
	end
	return cf.ZVector
end

local function withAxis(size, axis, length)
	if axis == "X" then
		return Vector3.new(length, size.Y, size.Z)
	elseif axis == "Y" then
		return Vector3.new(size.X, length, size.Z)
	end
	return Vector3.new(size.X, size.Y, length)
end

local ROUNDS = 12

-- Works out and applies one pass of nudges for `found`. Returns how many parts changed and the
-- pairs nothing could be done about.
--
-- Each pair is a record: the front (the smaller face, which stays in front), the back, and how
-- far the front's face already stands in front of the back's along the shared normal. The
-- front is the mover; a front that can't move has its back back off instead. Nothing is touched
-- until the end: the records are settled in rounds against a planned offset (and planned face
-- growth) per part, so a stack of five coplanar plates spreads out in one pass instead of one
-- layer per pass. Blocks and cylinders grow the fighting face outward rather than moving, so a
-- band round a body widens on both sides and a strap between a body and a lip clears both.
local function applyPass(found, opts, stats)
	local gap = opts.gap
	local function movable(entry)
		return opts.all or entry.part.Anchored
	end

	local state = {}
	local function stateFor(entry)
		local s = state[entry]
		if not s then
			s = { offset = Vector3.zero, shift = {}, cf = entry.part.CFrame, size = entry.part.Size, grown = false, with = nil }
			state[entry] = s
		end
		return s
	end

	local records, stuck = {}, {}
	for _, hit in ipairs(found) do
		local frontIsA = hit.fa.area <= hit.fb.area
		local front = frontIsA and hit.a or hit.b
		local back = frontIsA and hit.b or hit.a
		local n = frontIsA and hit.fa.n or hit.fb.n
		local gap0 = frontIsA and -hit.gap or hit.gap
		local frontMoves = movable(front)
		if frontMoves or movable(back) then
			local sf, sb = stateFor(front), stateFor(back)
			local fAxis, fSign = faceKey(sf.cf, n)
			local bAxis, bSign = faceKey(sb.cf, n)
			records[#records + 1] = {
				front = front, back = back, n = n, gap0 = gap0, hit = hit, frontMoves = frontMoves,
				fKey = fAxis .. fSign, fAxis = fAxis, fSign = fSign, bKey = bAxis .. bSign,
			}
		else
			stuck[#stuck + 1] = hit
		end
	end

	local function faceOffset(s, key, n)
		return s.offset:Dot(n) + (s.shift[key] or 0)
	end

	for _ = 1, ROUNDS do
		-- What each mover's faces still need, given everything planned so far.
		local needs = {}
		local any = false
		for _, r in ipairs(records) do
			local sf, sb = state[r.front], state[r.back]
			local sep = r.gap0 + faceOffset(sf, r.fKey, r.n) - faceOffset(sb, r.bKey, r.n)
			if sep < gap - 1e-4 and sep > -gap + 1e-4 then
				any = true
				if r.frontMoves then
					local list = needs[r.front]
					if not list then
						list = {}
						needs[r.front] = list
					end
					local slot = list[r.fKey]
					if not slot then
						slot = { out = 0, front = true, axis = r.fAxis, sign = r.fSign, n = r.n }
						list[r.fKey] = slot
					end
					slot.out = math.max(slot.out, gap - sep)
					sf.with = sf.with or r.back.part.Name
				else
					local list = needs[r.back]
					if not list then
						list = {}
						needs[r.back] = list
					end
					local key = "back" .. r.bKey
					local slot = list[key]
					if not slot then
						slot = { out = 0, front = false, n = -r.n }
						list[key] = slot
					end
					slot.out = math.max(slot.out, gap - sep)
					sb.with = sb.with or r.front.part.Name
				end
			end
		end
		if not any then
			break
		end

		for entry, list in pairs(needs) do
			local s = state[entry]
			for key, slot in pairs(list) do
				if slot.front and resizable(entry.part, slot.axis) then
					-- A block or cylinder grows the one face that's fighting, outward, and nothing
					-- else about it changes. Faces only ever go outward, so a part squeezed between
					-- two others (a strap under a lip, a seam between a body and a lid) settles
					-- instead of being shoved back and forth between passes.
					s.shift[key] = (s.shift[key] or 0) + slot.out
					s.grown = true
				else
					s.offset += slot.n * slot.out
				end
			end
		end
	end

	local changed = 0
	for entry, s in pairs(state) do
		local part = entry.part
		local move = s.offset
		local size = s.size
		local distance = s.offset.Magnitude
		if s.grown then
			for _, axis in ipairs({ "X", "Y", "Z" }) do
				local plus, minus = s.shift[axis .. "1"] or 0, s.shift[axis .. "-1"] or 0
				if plus ~= 0 or minus ~= 0 then
					local length = size[axis] + plus + minus
					if length >= 0.05 then
						size = withAxis(size, axis, length)
						move += axisVector(s.cf, axis) * ((plus - minus) / 2)
						distance += math.abs(plus) + math.abs(minus)
						stats.resized += 1
					end
				end
			end
		end
		if distance > 1e-5 then
			if size ~= s.size then
				part.Size = size
			end
			part.CFrame = s.cf + move
			changed += 1
			stats.moved += 1
			part:SetAttribute("ZFixed", (part:GetAttribute("ZFixed") or 0) + distance)
			part:SetAttribute("ZFixedWith", s.with)
			if ZFight.Trace then
				print(string.format("[ZFight] %s: move %s size %s -> %s (vs %s)", part:GetFullName(), tostring(move), tostring(s.size), tostring(size), tostring(s.with)))
			end
			refresh(entry)
		end
	end
	return changed, stuck
end

local function round(v)
	return string.format("%.1f, %.1f, %.1f", v.X, v.Y, v.Z)
end

local function pairsOf(found)
	local list = table.create(#found)
	for index, hit in ipairs(found) do
		list[index] = { a = hit.a.part, b = hit.b.part, normal = hit.fa.n, gap = hit.gap, overlap = hit.overlap }
	end
	return list
end

local function options(given, fixing)
	given = given or {}
	return {
		tolerance = given.tolerance or (fixing and ZFight.FixTolerance or ZFight.Tolerance),
		gap = given.gap or ZFight.Gap,
		minOverlap = fixing and ZFight.FixMinOverlap or ZFight.MinOverlap,
		passes = given.passes or ZFight.Passes,
		yield = given.yield or false,
		all = given.all or false,
		terrain = given.terrain ~= false,
	}
end

-- A top flush with the terrain's surface comes up off it. Returns how many were lifted.
local function liftOffGround(entries, opts, stats)
	if not (opts.terrain and entries[1].part:IsDescendantOf(workspace)) then
		return 0
	end
	local params = terrainParams()
	local lifted = 0
	for index, entry in ipairs(entries) do
		if opts.all or entry.part.Anchored then
			local lift = terrainLift(entry, params, opts)
			if lift then
				local part = entry.part
				part.CFrame += Vector3.new(0, lift, 0)
				part:SetAttribute("ZFixed", (part:GetAttribute("ZFixed") or 0) + lift)
				part:SetAttribute("ZFixedWith", "Terrain")
				lifted += 1
				stats.lifted += 1
				stats.moved += 1
				refresh(entry)
			end
		end
		if opts.yield and index % 1500 == 0 then
			task.wait()
		end
	end
	return lifted
end

-- Nudges the visible parts under `roots` apart wherever their faces fight.
function ZFight.Fix(roots, given)
	local opts = options(given, true)
	local started = os.clock()
	local stats = { moved = 0, resized = 0, lifted = 0, passes = 0, remaining = {}, parts = 0, seconds = 0 }
	if not ZFight.Enabled then
		return stats
	end
	local entries = entriesFor(ZFight.Parts(roots))
	stats.parts = #entries
	if #entries == 0 then
		return stats
	end

	local needScan = true
	for pass = 1, opts.passes do
		stats.passes = pass
		-- Ground first each pass: a nudge can put a top back at the surface.
		local lifted = liftOffGround(entries, opts, stats)
		local found = sweep(entries, opts)
		needScan = false
		if ZFight.Trace then
			print(string.format("[ZFight] pass %d: lifted %d, fighting pairs %d", pass, lifted, #found))
			if #found <= 24 then
				for _, hit in ipairs(found) do
					print(string.format("[ZFight]   %s/%s gap %.3f n(%s) areas %.2f/%.2f", hit.a.part.Name, hit.b.part.Name, hit.gap,
						round(hit.fa.n), hit.fa.area, hit.fb.area))
				end
			end
		end
		if #found == 0 then
			break
		end
		local changed, remaining = applyPass(found, opts, stats)
		needScan = true
		if changed == 0 then
			stats.remaining = pairsOf(remaining)
			needScan = false
			break
		end
		if opts.yield then
			task.wait()
		end
	end
	if needScan then
		stats.remaining = pairsOf(sweep(entries, opts))
	end
	stats.seconds = os.clock() - started
	return stats
end

-- The pairs of faces fighting among the visible parts under `roots`, without touching anything.
-- Includes parts whose tops sit at the ground's surface, as pairs with the Terrain.
function ZFight.Scan(roots, tolerance)
	local opts = options({ tolerance = tolerance })
	local entries = entriesFor(ZFight.Parts(roots))
	if #entries == 0 then
		return {}
	end
	local list = pairsOf(sweep(entries, opts))
	if entries[1].part:IsDescendantOf(workspace) then
		local params = terrainParams()
		for _, entry in ipairs(entries) do
			local lift = terrainLift(entry, params, opts)
			if lift then
				list[#list + 1] = { a = entry.part, b = workspace.Terrain, normal = Vector3.yAxis, gap = opts.gap - lift, overlap = 0 }
			end
		end
	end
	return list
end

--------------------------------------------------------------------------------
-- Reporting (the build check)
--------------------------------------------------------------------------------

-- What Fix moved under `roots`, grouped by `groupOf(part)`, the part's name and what it fought.
-- Returns the number of parts touched, the busiest patterns as lines, and how many patterns.
function ZFight.Report(roots, groupOf, limit)
	local counts, examples = {}, {}
	local total = 0
	for _, part in ipairs(ZFight.Parts(roots, true)) do
		local fixed = part:GetAttribute("ZFixed")
		if fixed then
			total += 1
			local key = string.format("%s %s/%s", groupOf and groupOf(part) or "?", part.Name, tostring(part:GetAttribute("ZFixedWith") or "?"))
			counts[key] = (counts[key] or 0) + 1
			examples[key] = examples[key] or string.format("%.3f @ %s", fixed, round(part.Position))
		end
	end
	local rows = {}
	for key, n in pairs(counts) do
		rows[#rows + 1] = { key = key, n = n }
	end
	table.sort(rows, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.key < b.key
	end)
	local lines = {}
	for index = 1, math.min(limit or 40, #rows) do
		lines[#lines + 1] = string.format("%s x%d (%s)", rows[index].key, rows[index].n, examples[rows[index].key])
	end
	return total, lines, #rows
end

-- Lines describing pairs from Scan (or Fix's `remaining`), grouped the same way.
function ZFight.Describe(pairList, groupOf, limit)
	local counts, examples = {}, {}
	for _, pair in ipairs(pairList) do
		local key = string.format("%s %s/%s", groupOf and groupOf(pair.a) or "?", pair.a.Name, pair.b.Name)
		counts[key] = (counts[key] or 0) + 1
		examples[key] = examples[key] or string.format("gap %.3f n(%s) @ %s", pair.gap, round(pair.normal), round(pair.a.Position))
	end
	local rows = {}
	for key, n in pairs(counts) do
		rows[#rows + 1] = { key = key, n = n }
	end
	table.sort(rows, function(a, b)
		if a.n ~= b.n then
			return a.n > b.n
		end
		return a.key < b.key
	end)
	local lines = {}
	for index = 1, math.min(limit or 40, #rows) do
		lines[#lines + 1] = string.format("%s x%d (%s)", rows[index].key, rows[index].n, examples[rows[index].key])
	end
	return lines, #rows
end

return ZFight
