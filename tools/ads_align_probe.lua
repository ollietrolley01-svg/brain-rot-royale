-- Does every gun's sight actually sit on its own aim line, and can you see through it?
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/ads_align_probe.lua -WaitSeconds 180
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- The ADS contract (GunModels.lua header): every gun carries KP_Sight, a model-space CFrame whose
-- position is on the sight line and whose look vector runs down it, plus Optic and EyeRelief. The
-- viewmodel puts the camera EyeRelief studs behind KP_Sight looking along it, so KP_Sight's line
-- lands on the crosshair by construction. Everything that can still go wrong is in the model:
--
--   * the sight hardware not being on that line (front post top, red-dot dot, scope axis);
--   * the line not running parallel to the bore;
--   * something opaque in the way of the eye (a hood, a post that's too tall, a turret);
--   * the gun cutting the camera's near plane, or the eye sitting inside a part.
--
-- Every measurement is made on the gun exactly as GunModels.Build returns it, after its z-fight
-- pass, with rays traced against the parts' real shapes (boxes, cylinders, balls, wedges).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local MM = GunModels.StudsPerMillimetre
-- Tolerances: sight hardware off the line, in millimetres, and the line off the bore, in degrees.
local TOL_MM = 0.5
local TOL_DEG = 0.05
-- The game's view: Settings' default FieldOfView (70) times ADS_ZOOM (0.64), on a 16:9 screen.
local ADS_VFOV = 70 * 0.64
local ASPECT = 16 / 9
-- Roblox's camera near clip plane, in studs: read off the engine's own camera (NearPlaneZ is negative,
-- in front of the camera along -Z), with the long-standing 0.1 only if no camera answers.
local NEAR, NEAR_SOURCE = 0.1, "fallback"
do
	local ok, z = pcall(function()
		return workspace.CurrentCamera.NearPlaneZ
	end)
	if ok and type(z) == "number" and z < 0 then
		NEAR, NEAR_SOURCE = -z, "Camera.NearPlaneZ"
	end
end
print(string.format("[BRR_ADS] near plane %.3f studs (%s)", NEAR, NEAR_SOURCE))
-- Parts at least this transparent count as glass you look through rather than as an obstruction.
local SEE_THROUGH = 0.5
-- More see-through layers than this stacked on the eye line reads as fog, however clear each is.
local MAX_LAYERS = 4
-- Parts that are meant to sit on the line: dots, and any reticle (a scope's crosshair wires).
local RETICLE = { SightDot = true, SightReticle = true }
local function isReticle(part)
	return RETICLE[part.Name] or string.find(part.Name, "Reticle", 1, true) ~= nil
end

local function say(fmt, ...)
	print(string.format("[BRR_ADS] " .. fmt, ...))
end

local function startsWith(text, prefix)
	return string.sub(text, 1, #prefix) == prefix
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- Is a world point inside a part's real shape?
local function inside(part, point)
	local p = part.CFrame:PointToObjectSpace(point)
	local h = part.Size / 2
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return p.Magnitude <= math.min(h.X, h.Y, h.Z)
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		return math.abs(p.X) <= h.X and Vector2.new(p.Y, p.Z).Magnitude <= math.min(h.Y, h.Z)
	end
	local inBox = math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z
	if inBox and (part:IsA("WedgePart") or (part:IsA("Part") and part.Shape == Enum.PartType.Wedge)) then
		-- Under the slope: tall at the back (+Z), nothing at the front.
		return p.Y * h.Z - p.Z * h.Y <= 0
	end
	return inBox
end

-- The centre of the face of a part that looks most along `up`: the top of a post, the crown of a bead.
local function topCentre(part, up)
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return part.Position + up * math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2
	end
	local cf = part.CFrame
	local best, bestDot, half = nil, -math.huge, 0
	for _, axis in ipairs({
		{ cf.RightVector, part.Size.X }, { -cf.RightVector, part.Size.X },
		{ cf.UpVector, part.Size.Y }, { -cf.UpVector, part.Size.Y },
		{ cf.LookVector, part.Size.Z }, { -cf.LookVector, part.Size.Z },
	}) do
		local d = axis[1]:Dot(up)
		if d > bestDot then
			best, bestDot, half = axis[1], d, axis[2] / 2
		end
	end
	return part.Position + best * half
end

-- Highest and lowest point of a part's box, and its lateral extent, in a frame's local space.
local function extents(part, frame)
	local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local h = part.Size / 2
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				local p = frame:PointToObjectSpace(part.CFrame * Vector3.new(sx * h.X, sy * h.Y, sz * h.Z))
				lo = Vector3.new(math.min(lo.X, p.X), math.min(lo.Y, p.Y), math.min(lo.Z, p.Z))
				hi = Vector3.new(math.max(hi.X, p.X), math.max(hi.Y, p.Y), math.max(hi.Z, p.Z))
			end
		end
	end
	return lo, hi
end

local function angleDeg(a, b)
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
end

-- Where a ray (origin + t * direction, t in 0..1) is inside a part's real shape, as an interval of t,
-- or nil. Done by hand rather than with workspace:Raycast: gun parts are a few millimetres across,
-- and Roblox's query geometry for parts that small comes back padded by several millimetres (every
-- front-sight hit landed 7 mm early and a sight base 3.5 mm under the line read as blocking it), so
-- raycasts can't tell a post that's on the line from one that's in the way.
local EPS = 1e-9
local function interval(part, origin, direction)
	local cf = part.CFrame
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local h = part.Size / 2
	local tmin, tmax = 0, 1
	local shape = part:IsA("Part") and part.Shape or nil
	local function slab(oi, di, hi)
		if math.abs(di) < EPS then
			return math.abs(oi) <= hi
		end
		local t1, t2 = (-hi - oi) / di, (hi - oi) / di
		if t1 > t2 then
			t1, t2 = t2, t1
		end
		tmin, tmax = math.max(tmin, t1), math.min(tmax, t2)
		return tmin <= tmax
	end
	local function quadratic(a, b, c)
		if a < EPS then
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
	if shape == Enum.PartType.Ball then
		local r = math.min(h.X, h.Y, h.Z)
		if not quadratic(d:Dot(d), 2 * o:Dot(d), o:Dot(o) - r * r) then
			return nil
		end
	elseif shape == Enum.PartType.Cylinder then
		local r = math.min(h.Y, h.Z)
		if not slab(o.X, d.X, h.X) then
			return nil
		end
		if not quadratic(d.Y * d.Y + d.Z * d.Z, 2 * (o.Y * d.Y + o.Z * d.Z), o.Y * o.Y + o.Z * o.Z - r * r) then
			return nil
		end
	else
		if not (slab(o.X, d.X, h.X) and slab(o.Y, d.Y, h.Y) and slab(o.Z, d.Z, h.Z)) then
			return nil
		end
		-- A wedge is the box cut by its slope: tall at the back (+Z), down to nothing at the front.
		if part:IsA("WedgePart") or shape == Enum.PartType.Wedge then
			local f = o.Y * h.Z - o.Z * h.Y
			local g = d.Y * h.Z - d.Z * h.Y
			if math.abs(g) < EPS then
				if f > 0 then
					return nil
				end
			elseif g > 0 then
				tmax = math.min(tmax, -f / g)
			else
				tmin = math.max(tmin, -f / g)
			end
			if tmin > tmax then
				return nil
			end
		end
	end
	return tmin, tmax
end

-- Everything a ray passes through, nearest first. `stop(part)` ends the walk at the first part it
-- accepts.
local function allHits(model, origin, direction, stop)
	local hits = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local t = interval(d, origin, direction)
			if t then
				table.insert(hits, { part = d, t = t, position = origin + direction * t })
			end
		end
	end
	table.sort(hits, function(a, b)
		return a.t < b.t
	end)
	if stop then
		for index, hit in ipairs(hits) do
			if stop(hit.part) then
				return { table.unpack(hits, 1, index) }
			end
		end
	end
	return hits
end

--------------------------------------------------------------------------------
-- Build every gun somewhere empty
--------------------------------------------------------------------------------

local folder = Instance.new("Folder")
folder.Name = "BRR_AdsProbe"
folder.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids, function(a, b)
	local sa, sb = WeaponData.Get(a).style or "", WeaponData.Get(b).style or ""
	if sa ~= sb then
		return sa < sb
	end
	return a < b
end)

local guns = {}
for index, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if not ok or not model then
		say("%-20s BUILD FAILED: %s", id, tostring(model))
	else
		-- Read the design-space pivot before moving anything; everything is measured relative to it.
		local designPivot = model:GetPivot()
		local base = CFrame.new(index * 30, 4000, 0)
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		model:PivotTo(base)
		model.Parent = folder
		table.insert(guns, { id = id, def = def, model = model, base = base * designPivot:Inverse(), designPivot = designPivot })
	end
end

--------------------------------------------------------------------------------
-- Measure
--------------------------------------------------------------------------------

local problems = {}
local function problem(id, text)
	table.insert(problems, id .. ": " .. text)
end

local tanV = math.tan(math.rad(ADS_VFOV / 2))
local tanH = tanV * ASPECT

local function measure(gun)
	local id, model, base = gun.id, gun.model, gun.base
	local kpLocal = model:GetAttribute("KP_Sight")
	local optic = model:GetAttribute("Optic")
	local relief = model:GetAttribute("EyeRelief")
	local style = gun.def.style or "?"
	local pivotOff = gun.designPivot.Position.Magnitude + angleDeg(gun.designPivot.LookVector, Vector3.new(0, 0, -1))

	if typeof(kpLocal) ~= "CFrame" or type(optic) ~= "string" or type(relief) ~= "number" then
		say("%-20s %-12s MISSING CONTRACT: KP_Sight=%s Optic=%s EyeRelief=%s", id, style,
			typeof(kpLocal), tostring(optic), tostring(relief))
		problem(id, "missing KP_Sight/Optic/EyeRelief")
		return
	end
	if pivotOff > 1e-3 then
		problem(id, string.format("model pivot is not the design origin (off by %.4f)", pivotOff))
	end

	local kp = base * kpLocal
	local look, up, right = kp.LookVector, kp.UpVector, kp.RightVector
	local function onLine(point)
		local p = kp:PointToObjectSpace(point)
		return p.X / MM, p.Y / MM, -p.Z / MM -- right, up (mm), and distance ahead of KP_Sight (mm)
	end

	-- 1. The line against the gun's own axis and bore.
	local tiltDeg = angleDeg(kpLocal.LookVector, Vector3.new(0, 0, -1))
	local rollDeg = angleDeg(kpLocal.UpVector - kpLocal.UpVector:Dot(kpLocal.LookVector) * kpLocal.LookVector, Vector3.new(0, 1, 0))
	local receiver = model.PrimaryPart
	local muzzleAttachment = receiver and receiver:FindFirstChild("Muzzle")
	local boreDeg, boreX, boreY = nil, nil, nil
	if muzzleAttachment then
		boreDeg = angleDeg(muzzleAttachment.WorldCFrame.LookVector, look)
		local mx, my = onLine(muzzleAttachment.WorldPosition)
		boreX, boreY = mx, my
	else
		problem(id, "no Muzzle attachment on the receiver")
	end
	if tiltDeg > TOL_DEG then
		problem(id, string.format("KP_Sight look is %.3f deg off the model's -Z", tiltDeg))
	end
	if rollDeg > 0.5 then
		problem(id, string.format("KP_Sight is rolled %.2f deg (its up isn't the gun's up)", rollDeg))
	end
	if boreDeg and boreDeg > TOL_DEG then
		problem(id, string.format("sight line is %.3f deg off the bore (Muzzle attachment)", boreDeg))
	end
	if boreX and math.abs(boreX) > TOL_MM then
		problem(id, string.format("sight line is %.1f mm to the side of the bore", boreX))
	end

	-- 2. The optic's own reference against the line.
	local refText, refOff = "-", nil
	local beadOnly, beadCentred = false, {}
	if optic == "iron" then
		-- A post is aimed with its top edge. A bead has no edge: it's either held with its crown on
		-- the line or centred on it, so both are measured and whichever is on the line is taken.
		local best = nil
		local haveSight = false
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and (d.Name == "FrontSight" or d.Name == "FrontBead") then
				local candidates = { { "top", topCentre(d, up) } }
				if d.Name == "FrontBead" then
					table.insert(candidates, { "centre", d.Position })
				else
					haveSight = true
				end
				for _, c in ipairs(candidates) do
					local x, y, z = onLine(c[2])
					if not best or math.abs(y) + math.abs(x) < math.abs(best.y) + math.abs(best.x) then
						best = { name = d.Name .. " " .. c[1], x = x, y = y, z = z }
					end
					if d.Name == "FrontBead" and c[1] == "centre" and math.abs(x) <= TOL_MM and math.abs(y) <= TOL_MM then
						beadCentred[d] = true
					end
				end
			end
		end
		beadOnly = best ~= nil and not haveSight
		if not best then
			refText = "NO FrontSight/FrontBead"
			problem(id, "iron-sighted but has no part named FrontSight or FrontBead")
		else
			refOff = math.max(math.abs(best.x), math.abs(best.y))
			refText = string.format("%s dx=%+.2f dy=%+.2f mm, %.0f mm ahead", best.name, best.x, best.y, best.z)
			if best.z <= 0 then
				problem(id, "the front sight is not in front of KP_Sight")
			end
		end
		-- The rear has to frame the line: its top at or above the line, and material on both sides.
		local rearTop, rearLeft, rearRight, rearCount = -math.huge, false, false, 0
		local blades = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and startsWith(d.Name, "RearSight") then
				local lo, hi = extents(d, kp)
				-- Only the pieces the line actually passes between (not the base under it).
				if hi.Y / MM > -3 then
					rearCount += 1
					rearTop = math.max(rearTop, hi.Y / MM)
					if hi.X < 0.5 * MM then
						rearLeft = true
					end
					if lo.X > -0.5 * MM then
						rearRight = true
					end
					-- A piece straight across the line whose top reaches it: there's no notch, so it
					-- covers the whole front post and the post's tip is all you get to aim with.
					if lo.X < -0.5 * MM and hi.X > 0.5 * MM and lo.Y < 0 and hi.Y > -1 * MM then
						table.insert(blades, string.format("%s(top %+.1fmm)", d.Name, hi.Y / MM))
					end
				end
			end
		end
		if #blades > 0 then
			problem(id, "rear sight has no notch where the line crosses it, so it hides the front post: "
				.. table.concat(blades, ", "))
		end
		if rearCount == 0 then
			-- A bead shotgun has no rear sight: you look along the rib. That's the design, not a gap.
			refText ..= beadOnly and "; bead only, no rear" or "; NO rear sight pieces near the line"
			if not beadOnly then
				problem(id, "iron-sighted but nothing named RearSight* rises to the line")
			end
		else
			refText ..= string.format("; rear top %+.2f mm%s", rearTop, (rearLeft and rearRight) and "" or " ONE-SIDED")
			if rearTop < -TOL_MM then
				problem(id, string.format("the line runs %.1f mm above the rear sight", -rearTop))
			end
			if not (rearLeft and rearRight) then
				problem(id, "the rear sight doesn't reach both sides of the line")
			end
		end
	elseif optic == "reddot" or optic == "holo" then
		local dot = model:FindFirstChild("SightDot", true)
		if not dot then
			refText = "NO SightDot"
			problem(id, optic .. " without a SightDot")
		else
			local x, y, z = onLine(dot.Position)
			refOff = math.max(math.abs(x), math.abs(y))
			refText = string.format("SightDot dx=%+.2f dy=%+.2f mm, %.0f mm ahead", x, y, z)
		end
	elseif optic == "scope" then
		local tube = model:FindFirstChild("Scope", true)
		if not tube then
			refText = "NO part named Scope"
			problem(id, "scope optic without a part named Scope")
		else
			local x, y, z = onLine(tube.Position)
			local axis = (tube:IsA("Part") and tube.Shape == Enum.PartType.Cylinder) and tube.CFrame.RightVector or tube.CFrame.LookVector
			local axisDeg = math.min(angleDeg(axis, look), angleDeg(-axis, look))
			refOff = math.max(math.abs(x), math.abs(y))
			refText = string.format("Scope axis dx=%+.2f dy=%+.2f mm, %.3f deg", x, y, axisDeg)
			if axisDeg > TOL_DEG then
				problem(id, string.format("scope tube is %.3f deg off the sight line", axisDeg))
			end
		end
		-- The client zooms scopes by style; a scoped gun of an unlisted style gets iron-sight zoom.
		if not ({ sniper = true, dmr = true, railgun = true })[style] then
			problem(id, "scoped (Optic=scope) but style '" .. style .. "' is not in CombatClient SCOPE_ZOOM")
		end
	else
		refText = "UNKNOWN OPTIC " .. tostring(optic)
		problem(id, "unknown Optic " .. tostring(optic))
	end
	if refOff and refOff > TOL_MM then
		problem(id, string.format("%s reference is %.2f mm off the sight line (%s)", optic, refOff, refText))
	end
	-- Scoped styles without a scope still get scope zoom in CombatClient.
	if optic ~= "scope" and ({ sniper = true, dmr = true, railgun = true })[style] then
		problem(id, string.format("style '%s' gets scope zoom in CombatClient SCOPE_ZOOM but Optic=%s (no scope view)", style, optic))
	end
	if model:FindFirstChild("Scope", true) and optic ~= "scope" then
		problem(id, "has a part named Scope (CombatClient's 'scoped' test) but Optic=" .. optic)
	end

	-- 3. What the eye sees down the line.
	local eye = kp * CFrame.new(0, 0, relief)
	local eyeInside = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 and inside(d, eye.Position) then
			table.insert(eyeInside, d.Name)
		end
	end
	if #eyeInside > 0 then
		problem(id, "the eye is inside " .. table.concat(eyeInside, ", "))
	end

	-- Iron sights are aimed OVER: the front post's top and a notch's shoulders lie exactly on the
	-- line, where a ray only grazes them. Casting a hair above the line (well inside the tolerance)
	-- makes a graze a miss, so anything that still hits genuinely stands above the line.
	local lift = optic == "iron" and up * (0.3 * MM) or Vector3.zero
	local hits = allHits(model, eye.Position + lift, look * 40)
	local transmit, glass, blockers = 1, {}, {}
	for _, hit in ipairs(hits) do
		local part = hit.part
		local x, y, z = onLine(hit.position)
		if part.Transparency >= 1 then
			-- AimPoint and other invisible markers.
		elseif isReticle(part) or beadCentred[part] then
			-- Meant to be there: a dot, or a bead held centred over the target.
		elseif part.Transparency >= SEE_THROUGH then
			transmit *= part.Transparency
			table.insert(glass, string.format("%s(%s %.2f)", part.Name, part.Material.Name, part.Transparency))
		else
			table.insert(blockers, string.format("%s@%.0fmm", part.Name, z))
		end
	end
	-- The glass on the line is listed for reference only. Multiplying transparencies says a red dot
	-- shows 29% of the world (0.82 x 0.35), but rendered ADS views (tools/ads_gallery.lua) show the
	-- world through Roblox Glass barely dimmed, so it isn't counted as a problem.
	-- Every optic, scopes included, has to be see-through down the eye line: Oliver aimed down the
	-- railgun's scope and saw a solid tube. Solid parts are problems; so is glass stacked so deep it
	-- fogs the view.
	local sightText = string.format("%d see-through layer%s [%s]; solid [%s]", #glass, #glass == 1 and "" or "s",
		table.concat(glass, " "), table.concat(blockers, " "))
	if #blockers > 0 then
		problem(id, (optic == "scope" and "scope is opaque down the eye line: " or "line of sight blocked by ")
			.. table.concat(blockers, ", "))
	end
	if #glass > MAX_LAYERS then
		problem(id, string.format("%d transparent layers stacked on the eye line (%s)", #glass, table.concat(glass, ", ")))
	end

	-- How much of a small ring round the aim point is hidden by opaque hardware (not scopes).
	local ringText = ""
	if optic ~= "scope" then
		local parts = {}
		for _, degrees in ipairs({ 1, 3, 6 }) do
			local blocked, samples = 0, 16
			for step = 0, samples - 1 do
				local a = step / samples * math.pi * 2
				local dir = (eye * CFrame.Angles(0, 0, a) * CFrame.Angles(math.rad(degrees), 0, 0)).LookVector
				local opaque = function(p)
					return p.Transparency < SEE_THROUGH and not isReticle(p)
				end
				local hits = allHits(model, eye.Position, dir * 40, opaque)
				if #hits > 0 and opaque(hits[#hits].part) then
					blocked += 1
				end
			end
			table.insert(parts, string.format("%d°:%d%%", degrees, math.floor(blocked / samples * 100 + 0.5)))
		end
		ringText = " ring " .. table.concat(parts, " ")
	end

	-- 4. The camera's near plane: sample it inside the ADS frustum and see if any part cuts it.
	local clipped = {}
	for gx = -4, 4 do
		for gy = -2, 2 do
			local point = (eye * CFrame.new(gx / 4 * NEAR * tanH, gy / 2 * NEAR * tanV, -NEAR)).Position
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") and d.Transparency < 1 and not clipped[d.Name] and inside(d, point) then
					clipped[d.Name] = true
				end
			end
		end
	end
	local clippedNames = {}
	for name in pairs(clipped) do
		table.insert(clippedNames, name)
	end
	if #clippedNames > 0 then
		problem(id, "the near plane cuts " .. table.concat(clippedNames, ", "))
	end

	-- 5. Every other copy of the gun aims the same way. A skin repaints the gun and "world" detail
	-- (bots' guns) drops the smallest fittings, but neither may move the sight: the header promises
	-- one set of shapes. Compared in design space, part by part, for everything the aim depends on.
	local function sightParts(m)
		local list = {}
		for _, d in ipairs(m:GetDescendants()) do
			if d:IsA("BasePart") and (d.Name == "FrontSight" or d.Name == "FrontBead" or d.Name == "SightDot"
				or d.Name == "Scope" or startsWith(d.Name, "RearSight")) then
				table.insert(list, string.format("%s@%.1f,%.1f,%.1f/%.1f,%.1f,%.1f", d.Name,
					d.Position.X / MM, d.Position.Y / MM, d.Position.Z / MM, d.Size.X / MM, d.Size.Y / MM, d.Size.Z / MM))
			end
		end
		table.sort(list)
		return list
	end
	local ok0, reference = pcall(WeaponService.BuildGunModel, gun.def, Rarity.Color(gun.def.rarity), Enum.Material.Metal, { detail = "full" })
	local variantNotes = {}
	if ok0 and reference then
		local want = sightParts(reference)
		for _, variant in ipairs({
			{ "world", Rarity.Color(gun.def.rarity), Enum.Material.Metal, { detail = "world" } },
			{ "skinned", Color3.fromRGB(255, 80, 200), Enum.Material.Neon, { skinned = true } },
		}) do
			local okV, other = pcall(WeaponService.BuildGunModel, gun.def, variant[2], variant[3], variant[4])
			if not okV or not other then
				problem(id, variant[1] .. " copy failed to build: " .. tostring(other))
			else
				local otherKp = other:GetAttribute("KP_Sight")
				if typeof(otherKp) ~= "CFrame" or (otherKp.Position - kpLocal.Position).Magnitude > 1e-4
					or otherKp.LookVector:Dot(kpLocal.LookVector) < 0.99999
					or other:GetAttribute("Optic") ~= optic or other:GetAttribute("EyeRelief") ~= relief then
					problem(id, variant[1] .. " copy has a different KP_Sight/Optic/EyeRelief")
				end
				local got = sightParts(other)
				local missing, extra = {}, {}
				local have = {}
				for _, key in ipairs(got) do
					have[key] = (have[key] or 0) + 1
				end
				for _, key in ipairs(want) do
					if (have[key] or 0) > 0 then
						have[key] -= 1
					else
						table.insert(missing, key)
					end
				end
				for key, n in pairs(have) do
					if n > 0 then
						table.insert(extra, key)
					end
				end
				if #missing > 0 or #extra > 0 then
					-- A bot's copy (world detail) is never aimed down, so a difference there is only
					-- worth knowing; on a skinned copy, which players do aim, it's a problem.
					local text = string.format("%s copy's sight parts differ: missing [%s] extra [%s]", variant[1],
						table.concat(missing, " "), table.concat(extra, " "))
					if variant[1] == "skinned" then
						problem(id, text)
					else
						table.insert(variantNotes, text)
					end
				end
				other:Destroy()
			end
		end
		reference:Destroy()
	end

	say("%-20s %-12s %-6s relief %.2f  tilt %.3f bore %s  | %s | %s%s%s", id, style, optic, relief, tiltDeg,
		boreDeg and string.format("%.3f deg, %.0f mm below", boreDeg, -boreY) or "?", refText, sightText, ringText,
		#variantNotes > 0 and (" | note: " .. table.concat(variantNotes, "; ")) or "")
end


for _, gun in ipairs(guns) do
	measure(gun)
end

-- Self-test: plant the faults this probe exists to catch, each on a fresh copy of a real gun, and check
-- each one is reported -- so "problems: 0" above is known not to be vacuous. The planted problems are
-- taken back out of the list afterwards.
do
	local function stage(id, index)
		local def = WeaponData.Get(id)
		local model = WeaponService.BuildGunModel(def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
		local designPivot = model:GetPivot()
		local base = CFrame.new(index * 30, 4400, 0)
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		model:PivotTo(base)
		model.Parent = folder
		return { id = "selftest:" .. id, def = def, model = model, base = base * designPivot:Inverse(), designPivot = designPivot }
	end
	local function box(gun, name, sizeMm, designCFrame, transparency)
		local part = Instance.new("Part")
		part.Name = name
		part.Anchored = true
		part.Size = sizeMm * MM
		part.CFrame = gun.base * designCFrame
		part.Transparency = transparency or 0
		part.Parent = gun.model
		return part
	end
	local cases = {
		{ "sight 2 mm off its line", "off the sight line", "SahurPistol", function(gun)
			gun.model:SetAttribute("KP_Sight", gun.model:GetAttribute("KP_Sight") * CFrame.new(0, 2 * MM, 0))
		end },
		{ "line tilted 1 degree off the bore", "off the model's -Z", "CrocodiloRifle", function(gun)
			gun.model:SetAttribute("KP_Sight", gun.model:GetAttribute("KP_Sight") * CFrame.Angles(math.rad(1), 0, 0))
		end },
		{ "a block standing in the line", "line of sight blocked", "BananiniBurst", function(gun)
			local kp = gun.model:GetAttribute("KP_Sight")
			box(gun, "PlantedBlock", Vector3.new(20, 20, 5), kp * CFrame.new(0, 0, -150 * MM))
		end },
		{ "an opaque scope lens", "scope is opaque", "LarilaSniper", function(gun)
			for _, d in ipairs(gun.model:GetDescendants()) do
				if d:IsA("BasePart") and d.Name == "ScopeLens" then
					d.Transparency = 0
				end
			end
		end },
		{ "a part cutting the near plane", "near plane cuts", "SahurPistol", function(gun)
			local kp = gun.model:GetAttribute("KP_Sight")
			local relief = gun.model:GetAttribute("EyeRelief")
			box(gun, "PlantedNearPlane", Vector3.new(80, 80, 10), kp * CFrame.new(0, 0, relief - NEAR))
		end },
	}
	local caught = 0
	for index, case in ipairs(cases) do
		local before = #problems
		local ok, err = pcall(function()
			local gun = stage(case[3], index)
			case[4](gun)
			measure(gun)
		end)
		local found = false
		for k = before + 1, #problems do
			if string.find(problems[k], case[2], 1, true) then
				found = true
			end
		end
		for k = #problems, before + 1, -1 do
			table.remove(problems, k)
		end
		if found then
			caught += 1
		end
		say("selftest: %-36s %s%s", case[1], found and "caught" or "MISSED", ok and "" or (" (error: " .. tostring(err) .. ")"))
	end
	say("selftest: caught %d of %d planted faults (want %d)", caught, #cases, #cases)
end

folder:Destroy()

say("guns measured: %d of %d; problems: %d", #guns, #ids, #problems)
for _, text in ipairs(problems) do
	say("  PROBLEM %s", text)
end
say("done")
