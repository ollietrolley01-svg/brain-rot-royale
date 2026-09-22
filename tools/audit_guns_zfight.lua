-- Probe for tools/runtest.ps1 -Probe: what the z-fight pass does to every gun model.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_guns_zfight.lua -WaitSeconds 600
--
-- GunModels.Build runs ZFight.Fix on every gun at its own millimetre tolerance
-- (GunModels.ZFightOptions), so a gun whose source has flush faces is silently reshaped on every
-- build — invisibly to anything that only looks at the finished model, the way the glider's canopy
-- and eleven items were until tools/audit_items_zfight.lua diffed them. This is that audit for guns:
-- every weapon GunModels supports is built with the pass switched off (the geometry as written) and
-- as the game builds it, at both detail levels the game uses (full, and "world" for the guns bots
-- carry), and the two are diffed part by part in build order. Reported per gun: the flush pairs in
-- the written geometry at the gun tolerance, every part the pass moved or resized and by how much,
-- and whether a second pass still finds anything. Clean means 0 / 0 / 0.
--
-- Two faults are planted every run on the first gun: a part duplicated in place (a perfectly flush
-- pair the scan must report) and a part nudged after the build (a change the diff must report).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local DETAILS = { { label = "full", options = {} }, { label = "world", options = { detail = "world" } } }
local TOLERANCE = GunModels.ZFightOptions.tolerance
-- Guns are authored in millimetres; face positions are reported in them, not in studs, so a number
-- here can be compared against the source without converting in your head.
local MM = GunModels.StudsPerMillimetre

local function out(fmt, ...)
	print("[AUDIT gunzfight] " .. string.format(fmt, ...))
end

local function v3(v)
	return string.format("(%.4f,%.4f,%.4f)", v.X, v.Y, v.Z)
end

local function partsOf(model)
	local list = {}
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

local ids = {}
for id, def in pairs(WeaponData.Weapons) do
	if GunModels.Supports(def.style) then
		table.insert(ids, id)
	end
end
table.sort(ids)

local function build(def, options)
	local model = GunModels.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal, options)
	return model
end

-- Written pairs, parts the build pass changed, and what a second pass still does.
local function compare(raw, fixed)
	local a, b = partsOf(raw), partsOf(fixed)
	local written = ZFight.Scan({ raw }, TOLERANCE)
	local rawOrigin = raw.PrimaryPart and raw.PrimaryPart.CFrame or CFrame.new()
	local fixedOrigin = fixed.PrimaryPart and fixed.PrimaryPart.CFrame or CFrame.new()
	local changes = {}
	for index = 1, math.min(#a, #b) do
		local pa, pb = a[index], b[index]
		local ra, rb = rawOrigin:ToObjectSpace(pa.CFrame), fixedOrigin:ToObjectSpace(pb.CFrame)
		local shift = (ra.Position - rb.Position).Magnitude
		local grow = pb.Size - pa.Size
		if shift > 0.0005 or grow.Magnitude > 0.0005 then
			table.insert(changes, string.format("%s moved %.4f resized %s", pa.Name, shift, v3(grow)))
		end
	end
	local again = ZFight.Fix({ fixed }, GunModels.ZFightOptions)
	return #a, written, changes, again.moved + again.resized, #a ~= #b
end

local clean, dirty, failed = 0, 0, 0
local function measure(label, def, options)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local okRaw, raw = pcall(build, def, options)
	ZFight.Enabled = wasEnabled
	local okFixed, fixed = pcall(build, def, options)
	if not (okRaw and raw and okFixed and fixed) then
		failed += 1
		out("%s: build failed (%s / %s)", label, tostring(raw), tostring(fixed))
		return
	end
	local count, written, changes, secondPass, mismatch = compare(raw, fixed)
	if #written == 0 and #changes == 0 and secondPass == 0 and not mismatch then
		clean += 1
	else
		dirty += 1
		local pairNames = {}
		for index = 1, math.min(#written, 8) do
			local pair = written[index]
			-- The face normal and both parts' sizes, not just the names: a pair says WHICH faces are
			-- flush and how big the parts are, which is the difference between fixing the fault and
			-- changing a dimension that was never the one touching. (A fix aimed at the wrong axis
			-- passed review on its arithmetic and changed nothing measurable.)
			-- The face normal, and where each part's two faces ALONG that normal actually sit, in the
			-- millimetres this kit builds in. Sizes alone were not enough: a shell segment is rotated,
			-- so its local Z is not the ring's axis, and comparing local sizes sent a fix to the wrong
			-- dimension twice. What settles it is the world position of the touching planes.
			local n = pair.normal
			local function faces(part)
				if not n then
					return "?"
				end
				local half = math.abs(n:Dot(part.CFrame.RightVector)) * part.Size.X / 2
					+ math.abs(n:Dot(part.CFrame.UpVector)) * part.Size.Y / 2
					+ math.abs(n:Dot(part.CFrame.LookVector)) * part.Size.Z / 2
				local centre = n:Dot(part.Position)
				return string.format("%.1f..%.1f", (centre - half) / MM, (centre + half) / MM)
			end
			table.insert(pairNames, string.format("%s %s[%s]/%s[%s] gap %.4f",
				n and string.format("n(%.0f,%.0f,%.0f)", n.X, n.Y, n.Z) or "n?",
				pair.a.Name, faces(pair.a), pair.b.Name, faces(pair.b), pair.gap or -1))
		end
		out("%s: %d parts%s; written flush pairs %d [%s]; build pass changed %d parts [%s]; second pass %d",
			label, count, mismatch and " (part counts differ between builds!)" or "", #written, table.concat(pairNames, "; "),
			#changes, table.concat(changes, "; ", 1, math.min(#changes, 10)), secondPass)
	end
	raw:Destroy()
	fixed:Destroy()
end

-- Self-test on the first gun: the scan and the diff both have to be able to fire.
do
	local def = WeaponData.Get(ids[1])
	if def then
		local wasEnabled = ZFight.Enabled
		ZFight.Enabled = false
		local raw = build(def, {})
		ZFight.Enabled = wasEnabled
		local fixed = build(def, {})
		local parts = partsOf(raw)
		local victim = parts[math.max(1, math.floor(#parts / 2))]
		local twin = victim:Clone()
		twin.Parent = victim.Parent
		local plantedScan = #ZFight.Scan({ raw }, TOLERANCE)
		twin:Destroy()
		local fixedParts = partsOf(fixed)
		local nudged = fixedParts[math.max(1, math.floor(#fixedParts / 2))]
		nudged.CFrame = nudged.CFrame + Vector3.new(0, 0.01, 0)
		local _, _, changes = compare(raw, fixed)
		out("self-test on %s: a part duplicated in place reads %d flush pairs (want > 0); a part nudged 0.01 reads %d changes (want > 0) -> %s",
			ids[1], plantedScan, #changes, (plantedScan > 0 and #changes > 0) and "PASS" or "FAIL (the numbers below prove nothing)")
		raw:Destroy()
		fixed:Destroy()
	end
end

for index, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	for _, detail in ipairs(DETAILS) do
		measure(string.format("%s (%s)", id, detail.label), def, detail.options)
	end
	if index % 4 == 0 then
		task.wait()
	end
end

out("SUMMARY %d guns supported; %d builds clean, %d with written flush pairs or pass changes, %d failed to build", #ids, clean, dirty, failed)
out("RESULT %s", (dirty == 0 and failed == 0) and "PASS" or "FAIL")
pcall(flush)
