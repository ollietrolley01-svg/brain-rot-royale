-- Probe for tools/runtest.ps1 -Probe: supply drops never hand out a `staged` gun.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_supplydrop_staged.lua
--
-- Supply drops roll straight over WeaponData rather than the loot weights, so a gun still being
-- tested (staged = true, kept out of loot) could reach players through a crate. This marks one real
-- gun of each rarity as staged, takes SAMPLES rolls, and requires none of them. Then it clears the
-- flag and rolls again: the same guns must now turn up, so the test can actually fail.

local SAMPLES = 10000

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local SupplyDropService = require(modules:WaitForChild("SupplyDropService"))

local function out(fmt, ...)
	print("[AUDIT staged] " .. string.format(fmt, ...))
end

if not SupplyDropService.RollWeapon then
	out("RESULT INCONCLUSIVE: SupplyDropService.RollWeapon isn't exposed")
	pcall(flush)
	return
end

-- One gun per rarity, so whatever the drop odds roll there is a staged candidate to avoid.
local picked = {}
for id, def in pairs(WeaponData.Weapons) do
	if not picked[def.rarity] and not def.staged then
		picked[def.rarity] = id
	end
end
local marked = {}
for rarity, id in pairs(picked) do
	WeaponData.Weapons[id].staged = true
	marked[id] = rarity
end
local markedList = {}
for id, rarity in pairs(marked) do
	table.insert(markedList, id .. " (" .. rarity .. ")")
end
table.sort(markedList)
out("marked staged for the test: %s", table.concat(markedList, ", "))

local function sample(count)
	local hits, rolled = 0, {}
	for index = 1, count do
		local def = SupplyDropService.RollWeapon()
		local id = def and def.id
		rolled[id] = (rolled[id] or 0) + 1
		if id and marked[id] then
			hits += 1
		end
		if index % 2000 == 0 then
			task.wait()
		end
	end
	local distinct = 0
	for _ in pairs(rolled) do
		distinct += 1
	end
	return hits, distinct
end

local withFlag, distinctWith = sample(SAMPLES)
for id in pairs(marked) do
	WeaponData.Weapons[id].staged = nil
end
local withoutFlag, distinctWithout = sample(SAMPLES)

out("with staged set: %d of %d rolls were staged guns (%d distinct guns rolled)", withFlag, SAMPLES, distinctWith)
out("with it cleared: %d of %d rolls were those same guns (%d distinct) — the control", withoutFlag, SAMPLES, distinctWithout)
local pass = withFlag == 0 and withoutFlag > 0
out("RESULT %s", pass and "PASS" or "FAIL")
pcall(flush)
