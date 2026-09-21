-- Are the iron sights actually lined up?
--
-- Run with: runtest.ps1 -Probe tools/sight_align_probe.lua
--
-- When you aim, the client places one named part -- the first of Scope / Sight / SlideSightRear /
-- RearSight / Rail / Handle / Rib it finds, raised by that entry's lift -- exactly on the centre of
-- the screen, and points the gun parallel to the view. So the REAR sight is always dead centre by
-- construction. What nothing has ever checked is whether the FRONT sight's top sits on that same
-- line. If it doesn't, you look through a perfectly centred rear notch and see the front post
-- floating above or below it, which is precisely what "the sights don't line up" looks like.
--
-- Guns are built at the origin facing -Z with the model pivot at identity, so a part's world
-- position IS its design-space position; no receiver transform is needed, and it would only add
-- error on the tube-bodied guns whose receiver is turned a quarter.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

-- Same order and lifts as SIGHT_PARTS in CombatClient.
local SIGHT_PARTS = {
	{ "AimPoint", 0 },
	{ "Scope", 0 }, { "Sight", 0.22 }, { "SlideSightRear", 0.08 }, { "RearSight", 0.1 },
	{ "Rail", 0.3 }, { "Handle", 0.35 }, { "Rib", 0.22 },
}
-- What you line the rear up against, in order of preference.
local FRONTS = { "FrontSight", "SlideSightFront", "MuzzleProng", "FrontBead" }

-- Tolerances. A twentieth of a stud vertically reads as aligned in first person; laterally it has
-- to be tighter, because a post off to one side is obvious against the rear notch.
local TOLERANCE_Y = 0.08
local TOLERANCE_X = 0.03

local function say(...)
	print(string.format("[BRR_Align] " .. select(1, ...), select(2, ...)))
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local off, checked = {}, 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, model = pcall(WeaponService.BuildGunModel, def, Color3.fromRGB(200, 200, 200), Enum.Material.Metal)
	if not ok or not model then
		say("%-22s BUILD FAILED: %s", id, tostring(model))
	else
		local anchorName, lift, anchor = nil, 0, nil
		for _, entry in ipairs(SIGHT_PARTS) do
			if not anchor then
				local part = model:FindFirstChild(entry[1], true)
				if part then
					anchorName, lift, anchor = entry[1], entry[2], part
				end
			end
		end
		local front, frontName = nil, nil
		for _, name in ipairs(FRONTS) do
			if not front then
				front = model:FindFirstChild(name, true)
				frontName = front and name or nil
			end
		end

		if model:FindFirstChild("Scope", true) then
			say("%-22s scope: aimed through the full-screen view, irons not used", id)
		elseif model:FindFirstChild("SightDot", true) then
			-- A red dot aims through the dot. The iron post below it is decoration, and holding it
			-- to the dot's height would mean hoisting a barrel sight to suit an optic.
			say("%-22s red dot: aimed through the dot, the post beneath it is decoration", id)
		elseif not anchor then
			say("%-22s NO ANCHOR AT ALL", id)
			table.insert(off, id)
		elseif not front then
			say("%-22s rear %-14s aim y=%.2f  NO FRONT SIGHT", id, anchorName, anchor.Position.Y + lift)
			table.insert(off, id)
		else
			checked += 1
			local aimY, aimX = anchor.Position.Y + lift, anchor.Position.X
			-- The front post's TOP is what you line up on; for a bead (a ball) that's its crown.
			local frontTop = front.Position.Y + front.Size.Y / 2
			local dy, dx = frontTop - aimY, front.Position.X - aimX
			local bad = math.abs(dy) > TOLERANCE_Y or math.abs(dx) > TOLERANCE_X
			if bad then
				table.insert(off, id)
			end
			say("%-22s rear %-14s aim y=%5.2f   front %-15s top y=%5.2f   dy=%+.2f dx=%+.2f%s",
				id, anchorName, aimY, frontName, frontTop, dy, dx, bad and "   <<< OFF" or "")
		end
		model:Destroy()
	end
end

say("iron-sighted guns checked: %d; misaligned or missing a sight: %d%s", checked, #off,
	#off > 0 and ("  ->  " .. table.concat(off, ", ")) or "")
say("done")
