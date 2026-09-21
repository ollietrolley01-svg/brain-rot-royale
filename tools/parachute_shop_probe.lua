-- Parachute shop probe, for tools/runtest.ps1 (run it in the background: it waits on the Studio lock):
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/parachute_shop_probe.lua [-PlaceFile <rbxlx>]
--
-- Parachutes joined the shop rotation on 2026-09-17. This proves they changed nothing else:
--   * the draw exactly as ShopRotation made it before (copied below) and the module as it is now
--     agree on every gun skin, aura, accessory and crate for 2,000 rotations
--   * every rotation puts exactly ShopRotation.ParachuteSlots parachutes on sale, never a crate
--     exclusive, and how often each one comes up follows its rarity
-- and checks the parachute cosmetics against Shared/ParachuteModels: every Parachute item has a
-- design and every design has an item.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local ParachuteModels = require(Shared:WaitForChild("ParachuteModels"))
local ShopRotation = require(Shared:WaitForChild("ShopRotation"))

local ROTATIONS = 2000
local FIRST = 5920000

local failures = 0
local function out(format, ...)
	print("[ParachuteShop] " .. string.format(format, ...))
end
local function fail(format, ...)
	failures += 1
	out("FAIL " .. format, ...)
end

-- ShopRotation's stockFor as it was before parachutes, word for word apart from the cache.
local function oldStock(window)
	local random = Random.new(window * 7919 + 17)
	local cosmetics = {}
	for _, slot in ipairs(ShopRotation.Slots) do
		local pool = {}
		for _, id in ipairs(CosmeticData.OfKind(slot.kind, true)) do
			local item = CosmeticData.Get(id)
			if item.price then
				table.insert(pool, { id = id, weight = ShopRotation.RarityWeight[item.rarity] or 1 })
			end
		end
		for _ = 1, math.min(slot.count, #pool) do
			local total = 0
			for _, entry in ipairs(pool) do
				total += entry.weight
			end
			local roll = random:NextNumber() * total
			for index, entry in ipairs(pool) do
				roll -= entry.weight
				if roll <= 0 or index == #pool then
					cosmetics[entry.id] = true
					table.remove(pool, index)
					break
				end
			end
		end
	end
	local crates = {}
	for _, id in ipairs(CrateData.Order) do
		crates[id] = random:NextNumber() < (ShopRotation.CrateChance[id] or 1)
	end
	crates.Common = true
	crates.Super = true
	return cosmetics, crates
end

-- Every script the parachute work touched still compiles (a LocalScript or server Script can't be
-- required here, but its source can be compiled).
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayerScripts = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
for _, script in ipairs({
	StarterPlayerScripts:FindFirstChild("MenuClient"),
	ServerScriptService:FindFirstChild("Bootstrap"),
	ServerScriptService.Modules:FindFirstChild("RewardService"),
	ServerScriptService.Modules:FindFirstChild("StateSync"),
	ServerScriptService.Modules:FindFirstChild("PlayerData"),
	ServerScriptService.Modules:FindFirstChild("MovementService"),
	Shared:FindFirstChild("ShopRotation"),
	Shared:FindFirstChild("CosmeticData"),
	Shared:FindFirstChild("ParachuteModels"),
}) do
	if not script then
		fail("a touched script is missing from the place")
	else
		local compiled, err = loadstring(script.Source, script.Name)
		if compiled then
			out("compiles: %s", script.Name)
		else
			fail("%s doesn't compile: %s", script.Name, tostring(err))
		end
	end
end

-- Every item and design lines up.
local parachuteIds = CosmeticData.OfKind("Parachute")
for _, id in ipairs(parachuteIds) do
	if not ParachuteModels.Has(id) then
		fail("cosmetic %s has no design in ParachuteModels", id)
	end
end
for _, id in ipairs(ParachuteModels.Order) do
	local item = CosmeticData.Get(id)
	if not item or item.kind ~= "Parachute" then
		fail("design %s has no Parachute cosmetic", id)
	end
end
out("%d parachute cosmetics, %d designs", #parachuteIds, #ParachuteModels.Order)

local others = {}
for id, item in pairs(CosmeticData.Items) do
	if item.kind ~= "Parachute" then
		table.insert(others, id)
	end
end
table.sort(others)

local mismatches = 0
local seen = {}
local badCounts = 0
-- How many different selections the old draw made: if it made one, every rotation looked the
-- same and agreeing on it would prove little.
local selections = {}
local selectionCount = 0
for window = FIRST, FIRST + ROTATIONS - 1 do
	local at = window * ShopRotation.RotationSeconds + 1
	local cosmetics, crates = oldStock(window)
	local picked = {}
	for id in pairs(cosmetics) do
		table.insert(picked, id)
	end
	table.sort(picked)
	local signature = table.concat(picked, ",")
	if not selections[signature] then
		selections[signature] = true
		selectionCount += 1
	end
	for _, id in ipairs(others) do
		if (cosmetics[id] == true) ~= ShopRotation.IsCosmeticInStock(id, at) then
			mismatches += 1
			if mismatches <= 5 then
				fail("rotation %d: %s was %s before, %s now", window, id, tostring(cosmetics[id] == true), tostring(ShopRotation.IsCosmeticInStock(id, at)))
			end
		end
	end
	for _, id in ipairs(CrateData.Order) do
		if (crates[id] == true) ~= ShopRotation.IsCrateInStock(id, at) then
			mismatches += 1
			if mismatches <= 5 then
				fail("rotation %d: crate %s was %s before, %s now", window, id, tostring(crates[id] == true), tostring(ShopRotation.IsCrateInStock(id, at)))
			end
		end
	end
	local onSale = 0
	for _, id in ipairs(parachuteIds) do
		if ShopRotation.IsCosmeticInStock(id, at) then
			onSale += 1
			seen[id] = (seen[id] or 0) + 1
			if CosmeticData.Get(id).crateOnly then
				fail("rotation %d puts crate exclusive %s on sale", window, id)
			end
		end
	end
	if onSale ~= ShopRotation.ParachuteSlots then
		badCounts += 1
	end
	if window % 200 == 0 then
		task.wait()
	end
end
-- Self-test: the obvious wrong way to add parachutes (drawing them from the same Random, between the
-- cosmetics and the crates) must show up as differences, or the comparison above can't catch one.
do
	local planted = 0
	for window = FIRST, FIRST + 199 do
		local random = Random.new(window * 7919 + 17)
		for _, slot in ipairs(ShopRotation.Slots) do
			for _ = 1, slot.count do
				random:NextNumber()
			end
		end
		for _ = 1, ShopRotation.ParachuteSlots do
			random:NextNumber()
		end
		local _, crates = oldStock(window)
		for _, id in ipairs(CrateData.Order) do
			local wrong = random:NextNumber() < (ShopRotation.CrateChance[id] or 1) or id == "Common" or id == "Super"
			if wrong ~= (crates[id] == true) then
				planted += 1
			end
		end
	end
	if planted == 0 then
		fail("self-test: drawing parachutes from the shared Random changed no crate stock in 200 rotations, so the comparison proves nothing")
	else
		out("self-test: drawing parachutes from the shared Random would change %d crate stock entries in 200 rotations (caught)", planted)
	end
end

if mismatches > 0 then
	fail("%d differences from the old rotation in %d rotations", mismatches, ROTATIONS)
elseif selectionCount < ROTATIONS / 4 or #others == 0 then
	fail("the comparison can't show much: %d different selections in %d rotations over %d cosmetics", selectionCount, ROTATIONS, #others)
else
	out("old and new rotations agree on every skin, aura, accessory and crate: %d rotations (%d different selections), %d cosmetics, %d crates",
		ROTATIONS, selectionCount, #others, #CrateData.Order)
end
if badCounts > 0 then
	fail("%d rotations didn't have exactly %d parachutes on sale", badCounts, ShopRotation.ParachuteSlots)
end

for _, id in ipairs(ParachuteModels.Order) do
	local item = CosmeticData.Get(id)
	if item then
		out("  %-15s %-9s %s: on sale in %d of %d rotations", id, item.rarity, item.crateOnly and "crate only" or (item.price .. " coins"),
			seen[id] or 0, ROTATIONS)
	end
end
out("SUMMARY: %d failures", failures)
