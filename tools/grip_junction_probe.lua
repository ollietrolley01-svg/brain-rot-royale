-- Probe for tools/runtest.ps1 -Probe: does every grip meet what's above it, with no air between?
--
-- A raked grip under a level frame dips below the frame at its front edge, which leaves a wedge of air
-- you can see through (on PawnshopNine, since renamed Pistacchio Pum, with the magazine's top round
-- showing in it). This samples
-- every upward-facing surface of each gun's grip pieces (parts named Grip...), and from each sample that
-- isn't already buried in another part, looks straight up (the gun's +Y) for the next part within
-- REACH mm. A hit further than SEAM mm away is a gap under the frame; the report gives each grip's
-- largest gap, where it is, and what's above it. Samples with nothing above within REACH are open top
-- surfaces (a ledge standing out beside a narrower frame), counted but not flagged.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local MM = GunModels.StudsPerMillimetre
local EPS = 0.35 * MM
local SPACING = 1.5 * MM
local STEP = 0.5 * MM
local SEAM = 1.2 -- mm: closer than this reads as a seam, not a gap
local REACH = 15 -- mm

local function out(fmt, ...)
	-- A merged gallery run sets the prefix to "[BRR_Gallery] note " so its log echoes these.
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

-- _G.BRR_PROBE_BUILD swaps in another builder (an older GunModels.Build, to prove the probe fails the
-- gaps that were there), labelled _G.BRR_PROBE_LABEL.
local buildGun = _G.BRR_PROBE_BUILD or WeaponService.BuildGunModel
local label = _G.BRR_PROBE_LABEL or "current"

local function kindOf(part)
	if part:IsA("WedgePart") then
		return "wedge"
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		return "cyl"
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return "ball"
	end
	return "box"
end

local function contains(node, point, eps)
	local p = node.inverse * point
	local h = node.half
	local k = node.kind
	if k == "box" then
		return math.abs(p.X) <= h.X + eps and math.abs(p.Y) <= h.Y + eps and math.abs(p.Z) <= h.Z + eps
	elseif k == "cyl" then
		local r = math.min(h.Y, h.Z) + eps
		return math.abs(p.X) <= h.X + eps and p.Y * p.Y + p.Z * p.Z <= r * r
	elseif k == "ball" then
		return p.Magnitude <= math.min(h.X, h.Y, h.Z) + eps
	end
	if math.abs(p.X) > h.X + eps or p.Y < -h.Y - eps or p.Z > h.Z + eps then
		return false
	end
	return ((p.Y + h.Y) * h.Z - (p.Z + h.Z) * h.Y) / math.sqrt(h.Y * h.Y + h.Z * h.Z) <= eps
end

-- Surface points of a part with the way each one faces, in model space. The normal comes from the face
-- the point was made on, never guessed from the shape afterwards: a point on a vertical side, moved up,
-- is still on that side to within a rounding error, so "does it leave the part" can't tell a top from a
-- flank. Only points facing upward are worth looking up from.
local function surface(node)
	local h = node.half
	local samples = {}
	local axes = { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis }
	local function add(localPoint, localNormal)
		table.insert(samples, { node.cframe * localPoint, node.cframe:VectorToWorldSpace(localNormal) })
	end
	-- A box's six faces; for a cylinder its two ends; for a wedge the box faces it does have.
	local faces = node.kind == "cyl" and { 1 } or { 1, 2, 3 }
	for _, a in ipairs(faces) do
		local u, v = axes[a % 3 + 1], axes[(a + 1) % 3 + 1]
		local hu, hv = math.abs(h:Dot(u)), math.abs(h:Dot(v))
		local nu, nv = math.max(1, math.ceil(2 * hu / SPACING)), math.max(1, math.ceil(2 * hv / SPACING))
		for _, s in ipairs({ 1, -1 }) do
			for i = 0, nu - 1 do
				for j = 0, nv - 1 do
					local p = axes[a] * s * math.abs(h:Dot(axes[a])) + u * ((i + 0.5) / nu * 2 - 1) * hu + v * ((j + 0.5) / nv * 2 - 1) * hv
					-- A cylinder's end disc is round: keep the grid points that fall on it.
					if node.kind ~= "cyl" or (p.Y * p.Y + p.Z * p.Z) <= math.min(h.Y, h.Z) ^ 2 then
						add(p, axes[a] * s)
					end
				end
			end
		end
	end
	-- Cylinders: their round side, facing out from the axis.
	if node.kind == "cyl" then
		local r = math.min(h.Y, h.Z)
		local around = math.max(12, math.ceil(2 * math.pi * r / SPACING))
		local along = math.max(1, math.ceil(2 * h.X / SPACING))
		for i = 0, around - 1 do
			local t = (i + 0.5) / around * math.pi * 2
			local out = Vector3.new(0, math.cos(t), math.sin(t))
			for j = 0, along - 1 do
				add(Vector3.new(((j + 0.5) / along * 2 - 1) * h.X, out.Y * r, out.Z * r), out)
			end
		end
	end
	return samples
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local flagged = {}
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(buildGun, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if not ok or not model then
		out("%-24s BUILD FAILED: %s", id, tostring(model))
		continue
	end
	local pivot = model:GetPivot()
	local nodes, grips = {}, {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") and d.Transparency < 1 then
			local cframe = pivot:ToObjectSpace(d.CFrame)
			local node = { part = d, name = d.Name, cframe = cframe, inverse = cframe:Inverse(), half = d.Size / 2, kind = kindOf(d) }
			table.insert(nodes, node)
			if string.sub(d.Name, 1, 4) == "Grip" and d.Name ~= "GripScrew" and d.Name ~= "GripMedallion" and d.Name ~= "GripFrame" then
				table.insert(grips, node)
			end
		end
	end
	local worst, worstAt, worstAbove, worstPart = 0, nil, nil, nil
	local gapSamples, openSamples = 0, 0
	for _, grip in ipairs(grips) do
		for _, sample in ipairs(surface(grip)) do
			local point, normal = sample[1], sample[2]
			-- Upward-facing surfaces only: a grip's flanks and back face out, and the air beside them is
			-- meant to be there.
			if normal.Y > 0.25 then
				local lifted = point + Vector3.yAxis * 0.8 * MM
				if not contains(grip, lifted, 0.2 * MM) then
					local buried = false
					for _, other in ipairs(nodes) do
						if other ~= grip and contains(other, lifted, EPS) then
							buried = true
							break
						end
					end
					if not buried then
						local hit, above = nil, nil
						local distance = 0.8 * MM
						while distance <= REACH * MM do
							local probe = point + Vector3.yAxis * distance
							for _, other in ipairs(nodes) do
								if other ~= grip and contains(other, probe, 0) then
									hit, above = distance, other
									break
								end
							end
							if hit then
								break
							end
							distance += STEP
						end
						if hit then
							local gap = hit / MM
							if gap > SEAM then
								gapSamples += 1
								if gap > worst then
									worst, worstAt, worstAbove, worstPart = gap, point / MM, above.name, grip.name
								end
							end
						else
							openSamples += 1
						end
					end
				end
			end
		end
		task.wait()
	end
	if worst > 0 then
		table.insert(flagged, string.format("%s(%.1f)", id, worst))
		out("GAP  %-24s largest %.1f mm under %s above %s at (%.0f, %.0f, %.0f); %d gap samples, %d open-top samples",
			id, worst, worstAbove, worstPart, worstAt.X, worstAt.Y, worstAt.Z, gapSamples, openSamples)
	else
		out("ok   %-24s %d grip parts, no gap over %.1f mm; %d open-top samples", id, #grips, SEAM, openSamples)
	end
	model:Destroy()
end
out("grip junctions (%s build): %d guns with a gap%s", label, #flagged, #flagged > 0 and (": " .. table.concat(flagged, ", ")) or "")
out("done")
