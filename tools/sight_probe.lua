-- Which guns actually have a sight you can aim down.
--
-- Run with: runtest.ps1 -Probe tools/sight_probe.lua
--
-- When you aim, the viewmodel lines one named part up with the centre of the screen: the first
-- of Scope / Sight / SlideSightRear / RearSight / Rail / Handle / Rib it finds on the gun, raised
-- by that entry's offset. A gun carrying none of them falls back to a fixed guess of 0.45 studs
-- above the grip, which is why some guns aim at nothing in particular. This builds all 27 and
-- reports, per gun, which anchor it matched and where that anchor sits relative to the receiver,
-- so the fix can be aimed at the guns that need it rather than at all of them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

-- Kept in the same order and with the same offsets as SIGHT_PARTS in CombatClient.
local SIGHT_PARTS = {
	{ "Scope", 0 }, { "Sight", 0.22 }, { "SlideSightRear", 0.08 }, { "RearSight", 0.1 },
	{ "Rail", 0.3 }, { "Handle", 0.35 }, { "Rib", 0.22 },
}

local function say(...)
	print(string.format("[BRR_Sight] " .. select(1, ...), select(2, ...)))
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local missing, frontOnly, rows = {}, {}, {}

for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model, receiver = pcall(WeaponService.BuildGunModel, def, Color3.fromRGB(200, 200, 200), Enum.Material.Metal)
	if not ok or not model then
		table.insert(rows, string.format("%-22s BUILD FAILED", id))
	else
		-- What the viewmodel would pick, and whether the gun has a front sight to line up with.
		local matched, matchedOffset, anchor = nil, 0, nil
		for _, entry in ipairs(SIGHT_PARTS) do
			if not matched then
				local part = model:FindFirstChild(entry[1], true)
				if part then
					matched, matchedOffset, anchor = entry[1], entry[2], part
				end
			end
		end
		local hasFront = model:FindFirstChild("FrontSight", true) ~= nil
			or model:FindFirstChild("SlideSightFront", true) ~= nil
			or model:FindFirstChild("MuzzleProng", true) ~= nil

		local where = "-"
		if anchor and receiver then
			local rel = receiver.CFrame:PointToObjectSpace(anchor.Position)
			where = string.format("(%.2f, %.2f, %.2f)", rel.X, rel.Y, rel.Z)
		end

		table.insert(rows, string.format("%-22s %-10s anchor %-16s lift %.2f  front=%s  style=%s",
			id, matched or "NONE", where, matchedOffset, tostring(hasFront), tostring(def.style)))

		-- A scoped gun is aimed through the scope, so it wants no front blade at all: counting it
		-- as missing one reported the Delulu Railgun as a fault when the builder was right to
		-- leave it off. The permanent check in runtest.ps1 excludes scopes for the same reason.
		if not matched then
			table.insert(missing, id)
		elseif matched ~= "Scope" and not hasFront then
			table.insert(frontOnly, id)
		end
		model:Destroy()
	end
end

for _, row in ipairs(rows) do
	say("%s", row)
end
say("guns %d; no rear anchor at all: %d%s", #ids, #missing, #missing > 0 and (" -> " .. table.concat(missing, ", ")) or "")
say("has a rear anchor but nothing up front to line it up with: %d%s",
	#frontOnly, #frontOnly > 0 and (" -> " .. table.concat(frontOnly, ", ")) or "")
say("done")
