-- Probe for tools/runtest.ps1 -Probe: what ZFight's build pass does to the open Rot Glider.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_glider_zfight.lua
--
-- Builds the open RotGlider (ItemModels) at scale 1 and 3 twice: once with ZFight switched off
-- (the geometry as written) and once as the game builds it. Parts are matched by build order, and
-- every part the pass moved or resized is listed with how far. Also lists the flush pairs the
-- written geometry has (what the pass reacts to) and the pairs left after it. The same for the
-- default ParachuteModels canopy, if that module exists.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))

local function out(fmt, ...)
	print("[AUDIT glider] " .. string.format(fmt, ...))
end

local function v3(v)
	return string.format("(%.3f,%.3f,%.3f)", v.X, v.Y, v.Z)
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

local function compare(label, build)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local okRaw, raw = pcall(build)
	ZFight.Enabled = wasEnabled
	local okFixed, fixed = pcall(build)
	if not (okRaw and raw and okFixed and fixed) then
		out("%s: build failed: %s / %s", label, tostring(raw), tostring(fixed))
		return
	end
	-- Left out of the workspace, so the scans don't pair anything with the Terrain.
	local a, b = partsOf(raw), partsOf(fixed)
	out("%s: %d parts written, %d built", label, #a, #b)
	local flushRaw = ZFight.Scan({ raw }, ZFight.FixTolerance)
	out("%s: flush pairs in the written geometry: %d", label, #flushRaw)
	for index = 1, math.min(#flushRaw, 16) do
		local pair = flushRaw[index]
		local pa, pb = pair.a or pair[1], pair.b or pair[2]
		out("    %s / %s", pa and pa.Name or "?", pb and pb.Name or "?")
	end
	local rawOrigin = raw.PrimaryPart and raw.PrimaryPart.CFrame or CFrame.new()
	local fixedOrigin = fixed.PrimaryPart and fixed.PrimaryPart.CFrame or CFrame.new()
	local moved, worst, worstName = 0, 0, "-"
	for index = 1, math.min(#a, #b) do
		local pa, pb = a[index], b[index]
		local ra = rawOrigin:ToObjectSpace(pa.CFrame)
		local rb = fixedOrigin:ToObjectSpace(pb.CFrame)
		local shift = (ra.Position - rb.Position).Magnitude
		local grow = (pa.Size - pb.Size).Magnitude
		if shift > 0.001 or grow > 0.001 then
			moved += 1
			local localShift = ra:VectorToObjectSpace(rb.Position - ra.Position)
			out("    changed #%d %s: moved %.3f %s (in its own axes), size %s -> %s", index, pa.Name, shift, v3(localShift), v3(pa.Size), v3(pb.Size))
			if shift > worst then
				worst, worstName = shift, pa.Name
			end
		end
	end
	out("%s: the build pass changed %d parts; largest move %.3f (%s); flush pairs left after it: %d", label, moved, worst, worstName,
		#ZFight.Scan({ fixed }))
	raw:Destroy()
	fixed:Destroy()
end

for _, scale in ipairs({ 1, 3 }) do
	compare(string.format("ItemModels RotGlider open, scale %d", scale), function()
		local model = ItemModels.Build("RotGlider", { scale = scale, open = true })
		return model
	end)
	task.wait()
end

local parachuteModule = Shared:FindFirstChild("ParachuteModels")
if parachuteModule then
	local ok, ParachuteModels = pcall(require, parachuteModule)
	if ok and ParachuteModels and ParachuteModels.Build then
		compare("ParachuteModels default, scale 3", function()
			local model = ParachuteModels.Build(nil, { scale = 3 })
			return model
		end)
	else
		out("ParachuteModels didn't load: %s", tostring(ParachuteModels))
	end
else
	out("no Shared.ParachuteModels")
end
out("done")
pcall(flush)
