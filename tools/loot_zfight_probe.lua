-- Probe for tools/runtest.ps1 -Probe: proves the harness's loot z-fight scan still catches real faults
-- after it stopped scanning the guns on weapon pickups (they're covered at gun tolerance elsewhere).
--
-- Drops a few weapon and consumable pickups, selects roots exactly as runtest.ps1's "zfight loot" block
-- does, and scans: once as built, then with a deliberately flush pair planted on a weapon pickup's pad
-- (a copy of the pad at the same CFrame) and on a consumable pickup (a copy of one of its parts), and
-- reports whether each planted pair is found. The planted parts are removed afterwards.
--
-- Run with: powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/loot_zfight_probe.lua

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local ZFight = require(Shared:WaitForChild("ZFight"))
local LootService = require(modules:WaitForChild("LootService"))

local function out(text)
	print("[PROBE] " .. text)
end

for index, id in ipairs({ "CrocodiloRifle", "SahurPistol", "PatapimChaingun" }) do
	LootService.DropWeapon(id, Vector3.new(index * 20, 3000, 6000))
end
for index = 1, 3 do
	LootService.DropHeal(Vector3.new(index * 20, 3000, 6100))
end
local loot = workspace:WaitForChild("Loot")

-- The same selection runtest.ps1 makes.
local function roots()
	local lootRoots, weaponRoots, otherRoots = {}, 0, 0
	for _, child in ipairs(loot:GetChildren()) do
		if child:GetAttribute("WeaponId") then
			for _, piece in ipairs(child:GetChildren()) do
				if piece:IsA("BasePart") and piece.Name == "Part" then
					table.insert(lootRoots, piece)
					weaponRoots += 1
				end
			end
		else
			table.insert(lootRoots, child)
			otherRoots += 1
		end
	end
	return lootRoots, weaponRoots, otherRoots
end

local function involving(pairs_, part)
	local n = 0
	for _, pair in ipairs(pairs_) do
		if pair.a == part or pair.b == part then
			n += 1
		end
	end
	return n
end

local lootRoots, weaponRoots, otherRoots = roots()
local baseline = ZFight.Scan(lootRoots)
local oldWhole = ZFight.Scan({ loot })
out(string.format("as built: %d weapon dressing parts + %d other pickups; flush %d (the old whole-folder scan: %d)",
	weaponRoots, otherRoots, #baseline, #oldWhole))

-- Plant the pairs.
local weaponPickup, consumable
for _, child in ipairs(loot:GetChildren()) do
	if child:GetAttribute("WeaponId") and not weaponPickup then
		weaponPickup = child
	elseif not child:GetAttribute("WeaponId") and not consumable then
		consumable = child
	end
end
local planted = {}
local weaponPad = weaponPickup and weaponPickup:FindFirstChild("Part")
if weaponPad then
	local copy = weaponPad:Clone()
	copy.Parent = weaponPickup
	table.insert(planted, { label = "weapon pickup pad", part = copy })
end
local consumablePart
for _, descendant in ipairs(consumable and consumable:GetDescendants() or {}) do
	if descendant:IsA("BasePart") and descendant.Transparency < 0.5 and not consumablePart then
		consumablePart = descendant
	end
end
if consumablePart then
	local copy = consumablePart:Clone()
	copy.Parent = consumablePart.Parent
	table.insert(planted, { label = "consumable pickup part " .. consumablePart.Name, part = copy })
end

lootRoots = roots()
local withPlanted = ZFight.Scan(lootRoots)
out(string.format("with %d planted pairs: flush %d (was %d)", #planted, #withPlanted, #baseline))
for _, entry in ipairs(planted) do
	out(string.format("  %s: %d fighting pairs found (want > 0)", entry.label, involving(withPlanted, entry.part)))
end

for _, entry in ipairs(planted) do
	entry.part:Destroy()
end
lootRoots = roots()
out(string.format("planted parts removed: flush %d (want %d)", #ZFight.Scan(lootRoots), #baseline))
loot:Destroy()
out("done")
