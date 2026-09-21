-- Probe for tools/runtest.ps1 -Probe: what the finger rig was told about each gun, and how far the
-- fingers are therefore allowed to close.
--
-- The rig measures each hand anchor when a gun is built and keeps three numbers on the viewmodel:
-- `knuckle` (how far ahead of the keypoint the knuckle line sits), `turn` (how far the fingertips come in
-- under what they hold) and `cap` (how far the gun lets the hand close at all, swept against the parts).
-- A render showed fingers standing straight out on some guns, which means a cap near zero -- this reads
-- the numbers themselves rather than guessing from pictures, per anchor, for every gun.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/finger_reach_probe.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local Viewmodel = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Viewmodel"))

local MM = GunModels.StudsPerMillimetre
-- Below this the hand is not closing in any way a player would call closed.
local OPEN = 0.3
local ANCHORS = { "GripHand", "SupportHand", "MagHand", "ChargeHand", "BoltHand", "CoverHand" }

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local ids = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(ids, id)
end
table.sort(ids)

local folder = Instance.new("Folder")
folder.Name = "BRR_FingerReach"
folder.Parent = workspace

local counts = {}
local straight, measured = 0, 0
for _, id in ipairs(ids) do
	local def = WeaponData.Get(id)
	local ok, vm = pcall(Viewmodel.new, def, { color = Rarity.Color(def.rarity), material = Enum.Material.Metal })
	if not ok or not vm then
		out("%s: Viewmodel.new failed: %s", id, tostring(vm))
	else
		vm.model.Parent = folder
		for _, name in ipairs(ANCHORS) do
			local shape = vm.gripShapes and vm.gripShapes[name]
			if shape == nil then
				-- no such anchor on this gun; nothing to say
			elseif shape == false then
				counts.fist = (counts.fist or 0) + 1
				out("%-22s %-12s on nothing -> closes on itself", id, name)
			else
				measured += 1
				-- Each finger is capped on its own, so the hand's state is how many of the four close --
				-- one finger held out along a trigger guard is a trigger finger, all four held out is the
				-- fault this probe exists to catch.
				local closing = 0
				local caps, knuckles = {}, {}
				for _, finger in ipairs(shape.fingers) do
					if finger.cap >= OPEN then
						closing += 1
					end
					table.insert(caps, string.format("%.2f", finger.cap))
					table.insert(knuckles, string.format("%.0f", finger.knuckle / MM))
				end
				if closing == 0 then
					straight += 1
					counts.straight = (counts.straight or 0) + 1
				end
				local blockers = {}
				for _, finger in ipairs(shape.fingers) do
					if finger.blocker then
						blockers[finger.blocker] = (blockers[finger.blocker] or 0) + 1
					end
				end
				local why = {}
				for part, count in pairs(blockers) do
					table.insert(why, string.format("%s x%d", part, count))
				end
				table.sort(why)
				out("%-22s %-12s knuckles %s mm, caps %s, %d of %d close%s%s", id, name,
					table.concat(knuckles, "/"), table.concat(caps, "/"), closing, #shape.fingers,
					#why > 0 and ("  blocked by " .. table.concat(why, ", ")) or "",
					closing == 0 and "  <- WHOLE HAND STANDS STRAIGHT" or "")
			end
		end
		vm:Destroy()
	end
	task.wait()
end

folder:Destroy()
out("%d anchors measured on %d guns: %d stand straight (cap < %.2f), %d rest on nothing",
	measured, #ids, straight, OPEN, counts.fist or 0)
out("done")
