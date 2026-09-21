-- Probe for tools/runtest.ps1 -Probe: what GunModels' own z-fight pass has to nudge, found at source.
--
-- Builds every gun with the z-fight pass switched off, scans each at the pass's own tolerance, and
-- prints the fighting pairs grouped by part-name pattern: how many, in which guns, and one example
-- with its gap, face normal and model-space position (mm) so the builder line can be found and fixed.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_nudge_probe.lua -WaitSeconds 240

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))

local MM = GunModels.StudsPerMillimetre
local tolerance = GunModels.ZFightOptions.tolerance

local function out(text)
	print("[PROBE] " .. text)
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local patterns, total = {}, 0
ZFight.Enabled = false
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(GunModels.Build, def, Rarity.Color(def.rarity), Enum.Material.Metal)
	if ok and model then
		local pairs_ = ZFight.Scan({ model }, tolerance)
		total += #pairs_
		for _, pair in ipairs(pairs_) do
			local a, b = pair.a.Name, pair.b.Name
			if a > b then
				a, b = b, a
			end
			local key = a .. "/" .. b
			local entry = patterns[key]
			if not entry then
				local where = (pair.a.Position + pair.b.Position) / 2 / MM
				entry = { count = 0, guns = {}, example = string.format("%s gap %.2fmm n(%s) at (%.0f, %.0f, %.0f)mm",
					id, (pair.gap or 0) / MM, tostring(pair.normal or "?"), where.X, where.Y, where.Z) }
				patterns[key] = entry
			end
			entry.count += 1
			entry.guns[id] = true
		end
		model:Destroy()
	else
		out(id .. ": build failed: " .. tostring(model))
	end
end
ZFight.Enabled = true

local list = {}
for key, entry in pairs(patterns) do
	local guns = {}
	for id in pairs(entry.guns) do
		table.insert(guns, id)
	end
	table.sort(guns)
	table.insert(list, { key = key, count = entry.count, text = string.format("%s x%d in %d guns (%s) e.g. %s",
		key, entry.count, #guns, table.concat(guns, ","), entry.example) })
end
table.sort(list, function(x, y)
	return x.count > y.count
end)
out(string.format("%d fighting pairs across %d guns before the pass, %d patterns", total, #ids, #list))
for _, item in ipairs(list) do
	out(item.text)
end
out("done")
