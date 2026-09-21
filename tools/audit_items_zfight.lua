-- Probe for tools/runtest.ps1 -Probe: what the z-fight pass does to every item model.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_items_zfight.lua
--
-- The glider's canopy cells were being stretched into a staircase by ItemModels.Build's own
-- ZFight.Fix, invisibly to any audit that only looks at the finished model (the pass had already
-- removed every flush pair it reports). This catches that whole class for every item: each is built
-- with ZFight switched off (the geometry as written) and as the game builds it, at the scales items
-- are really built at, and the two are diffed part by part (matched by build order). Reported per
-- item: the flush pairs in the written geometry (what the pass reacts to), every part the pass moved
-- or resized and by how much, and whether a SECOND pass (the world passes kits and mines get again)
-- still changes anything. Clean means: 0 written pairs, 0 parts changed, 0 on the second pass.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ItemData = require(Shared:WaitForChild("ItemData"))

local CrateModels = require(Shared:WaitForChild("CrateModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local SCALES = { 1, 1.25 }
-- Items that are also built bigger in the world (kits deployed, the mine armed, the canopy).
local EXTRA_SCALES = { RotBarricade = { 1.5 }, PopupBunker = { 1.5 }, BrainrotFortress = { 1.5 }, RotMine = { 1.5, 3 } }

local function out(fmt, ...)
	print("[AUDIT itemzfight] " .. string.format(fmt, ...))
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

local ids = {}
for id in pairs(ItemData.Items or {}) do
	table.insert(ids, id)
end
table.sort(ids)
if #ids == 0 then
	out("ItemData.Items is empty or named differently; nothing to measure")
end

local clean, dirty = 0, 0
local function measure(label, build)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local okRaw, raw = pcall(build)
	ZFight.Enabled = wasEnabled
	local okFixed, fixed = pcall(build)
	if not (okRaw and raw and okFixed and fixed) then
		out("%s: build failed (%s / %s)", label, tostring(raw), tostring(fixed))
		return
	end
	local a, b = partsOf(raw), partsOf(fixed)
	local written = ZFight.Scan({ raw }, ZFight.FixTolerance)
	local rawOrigin = raw.PrimaryPart and raw.PrimaryPart.CFrame or CFrame.new()
	local fixedOrigin = fixed.PrimaryPart and fixed.PrimaryPart.CFrame or CFrame.new()
	local changes = {}
	for index = 1, math.min(#a, #b) do
		local pa, pb = a[index], b[index]
		local ra, rb = rawOrigin:ToObjectSpace(pa.CFrame), fixedOrigin:ToObjectSpace(pb.CFrame)
		local shift = (ra.Position - rb.Position).Magnitude
		local grow = pb.Size - pa.Size
		if shift > 0.001 or grow.Magnitude > 0.001 then
			table.insert(changes, string.format("%s moved %.3f resized %s", pa.Name, shift, v3(grow)))
		end
	end
	local again = ZFight.Fix({ fixed }, { all = true })
	local secondPass = again.moved + again.resized
	if #written == 0 and #changes == 0 and secondPass == 0 then
		clean += 1
	else
		dirty += 1
		local pairNames = {}
		for index = 1, math.min(#written, 10) do
			local pair = written[index]
			table.insert(pairNames, string.format("%s/%s gap %.3f", pair.a.Name, pair.b.Name, pair.gap or -1))
		end
		out("%s: %d parts; written flush pairs %d [%s]; build pass changed %d parts [%s]; second pass moved %d resized %d",
			label, #a, #written, table.concat(pairNames, "; "), #changes, table.concat(changes, "; ", 1, math.min(#changes, 12)),
			again.moved, again.resized)
	end
	raw:Destroy()
	fixed:Destroy()
end

for index, id in ipairs(ids) do
	local scales = table.clone(SCALES)
	for _, extra in ipairs(EXTRA_SCALES[id] or {}) do
		table.insert(scales, extra)
	end
	for _, scale in ipairs(scales) do
		measure(string.format("%s x%.2f", id, scale), function()
			return ItemModels.Build(id, { scale = scale })
		end)
	end
	if id == "RotGlider" then
		for _, scale in ipairs({ 1, 3 }) do
			measure(string.format("%s (open) x%.2f", id, scale), function()
				return ItemModels.Build(id, { scale = scale, open = true })
			end)
		end
	end
	if index % 5 == 0 then
		task.wait()
	end
end
-- The crates and the map chest, built the same way (each runs ZFight.Fix inside its builder too).
-- Every crate CrateData sells, not the rarity ladder: the cosmetic crates have their own shapes.
local CrateData = require(Shared:WaitForChild("CrateData"))
for _, tier in ipairs(CrateData.Order or Rarity.Order) do
	measure("Crate " .. tier, function()
		return (CrateModels.Crate(tier))
	end)
end
measure("Chest", function()
	local chest = CrateModels.Chest(CFrame.new())
	-- Chest returns a part, not a model: wrap it so the diff walks it the same way.
	local holder = Instance.new("Model")
	chest.Parent = holder
	holder.PrimaryPart = chest
	return holder
end)

out("SUMMARY %d builds clean, %d with written flush pairs or pass changes", clean, dirty)
pcall(flush)
