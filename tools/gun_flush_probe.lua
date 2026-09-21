-- What z-fighting is LEFT on a finished gun, after GunModels' own nudge pass has done what it can.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/gun_flush_probe.lua -WaitSeconds 240
-- (rebuild the place first: the probe runs against BrainRotRoyale.rbxlx, not the .lua files)
--
-- tools/gun_nudge_probe.lua asks the opposite question -- what the pass HAS to fix, with the pass off --
-- which is the list to fix at source. This one builds each gun exactly as a player gets it and scans the
-- result, so what it prints is what a player could actually see shimmering: two faces within the pass's
-- tolerance that it could not separate (a detail ring lying on a lens, a stack of identical parts, a
-- collar landing exactly where a straw ends). tools/gun_gallery.lua prints the same number per gun as it
-- renders; this gets it in a probe run, in one list, grouped so the builder line can be found.
--
-- A pair shared by several guns comes from the kit (GunModels' redDot, holo, grip), not from one gun's
-- builder, so it is fixed once in the kit.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local MM = GunModels.StudsPerMillimetre
local TOLERANCE = GunModels.ZFightTolerance

local function say(fmt, ...)
	print(string.format("[BRR_Flush] " .. fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "BRR_FlushProbe"
folder.Parent = workspace

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

-- [PartA/PartB] = { count, guns = { [id] = count }, example }
local groups = {}
local guns, dirty, worst, worstGun = 0, 0, 0, nil

for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Rarity.Color(def.rarity), Enum.Material.Metal, { detail = "full" })
	if ok and model then
		guns += 1
		model.Parent = folder
		local flush = ZFight.Scan({ model }, TOLERANCE)
		if #flush > 0 then
			dirty += 1
			if #flush > worst then
				worst, worstGun = #flush, id
			end
			local origin = model:GetPivot()
			for _, pair in ipairs(flush) do
				local nameA, nameB = pair.a.Name, pair.b.Name
				if nameB < nameA then
					nameA, nameB = nameB, nameA
				end
				local key = nameA .. "/" .. nameB
				local group = groups[key]
				if not group then
					group = { count = 0, guns = {} }
					groups[key] = group
				end
				group.count += 1
				group.guns[id] = (group.guns[id] or 0) + 1
				if not group.example then
					local at = origin:Inverse() * pair.a.CFrame
					group.example = string.format("gap %.4f studs, normal (%.1f, %.1f, %.1f), at %.0f, %.0f, %.0f mm in %s",
						pair.gap, pair.normal.X, pair.normal.Y, pair.normal.Z, at.X / MM, at.Y / MM, at.Z / MM, id)
				end
			end
		end
		model:Destroy()
	else
		say("%-24s FAILED to build: %s", id, tostring(model))
	end
end

local keys = {}
for key in pairs(groups) do
	table.insert(keys, key)
end
table.sort(keys, function(a, b)
	if groups[a].count ~= groups[b].count then
		return groups[a].count > groups[b].count
	end
	return a < b
end)

for _, key in ipairs(keys) do
	local group = groups[key]
	local names = {}
	for id, count in pairs(group.guns) do
		table.insert(names, count > 1 and string.format("%s x%d", id, count) or id)
	end
	table.sort(names)
	say("%-38s %3d pairs in %d gun(s): %s", key, group.count, #names, table.concat(names, ", "))
	say("%-38s     %s", "", group.example)
end

folder:Destroy()
say("guns %d; with z-fighting left %d; worst %s (%d pairs); tolerance %.4f studs", guns, dirty, tostring(worstGun), worst, TOLERANCE)
say("done")
