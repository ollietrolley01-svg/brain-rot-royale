-- Loot pickup audit, for tools/runtest.ps1 -Probe (one map per run: edit MAP_ID and SEED below).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_loot.lua
--
-- Measures, through the real LootService code paths:
--   world pass   what the z-fight pass run after a pickup is parented changes on it (clients spin a
--                pickup from the offsets it arrives with, so any later change is half-undone there,
--                and a map-tolerance pass over gun detail warps the gun). Every weapon and every item
--                is dropped once on a flat plate, then a gun is dropped at SPOTS real weapon spots.
--                Reference before the fix (2026-09-16, SahurSprings 101, full Populate): 496 of 632
--                pickups changed, 48,985 parts moved, 49,643 resized.
--   drops        a death 1.5 studs inside a flat roof's parapet (8 per building) and 1 stud inside a
--                back wall (6 per building): where the pickup ends up. Reference before the fix:
--                SahurSprings 101 roof drops 128 -> 30 in mid-air; wall drops 180 -> 38 outside the
--                building, 55 with the pad through the wall.
-- A full LootService.Populate isn't run: with full-detail floor guns it outgrows Studio's memory.

local MAP_ID, SEED = "SahurSprings", 101
local SPOTS = 50

local RS = game:GetService("ReplicatedStorage")
local Shared = RS:WaitForChild("Shared")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local LootService = require(modules:WaitForChild("LootService"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local function out(fmt, ...)
	print("[AUDIT loot] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

-- The pass is handed either the pickup's base (old code) or the pad parts under it (new code).
local world = { calls = 0, pickups = 0, changed = 0, moved = 0, resized = 0, examples = {} }
do
	local original = ZFight.Fix
	ZFight.Fix = function(roots, options)
		local first = type(roots) == "table" and roots[1] or nil
		local base = nil
		if typeof(first) == "Instance" and first:IsA("BasePart") and first.Parent then
			if first.Parent.Name == "Loot" then
				base = first
			elseif first.Parent.Parent and first.Parent.Parent.Name == "Loot" then
				base = first.Parent
			end
		end
		local watch = base and (base.Name == "GroundWeapon" or base.Name == "HealPickup" or base.Name == "ItemPickup")
		local before = nil
		if watch then
			before = {}
			for _, d in ipairs(base:GetDescendants()) do
				if d:IsA("BasePart") then
					before[d] = { d.CFrame, d.Size }
				end
			end
		end
		local result = original(roots, options)
		if watch then
			world.calls += 1
			local any = false
			for d, s in pairs(before) do
				local moved = (d.CFrame.Position - s[1].Position).Magnitude
				local resized = (d.Size - s[2]).Magnitude
				if moved > 1e-4 then
					world.moved += 1
					any = true
				end
				if resized > 1e-4 then
					world.resized += 1
					any = true
				end
				if (moved > 1e-4 or resized > 1e-4) and #world.examples < 8 then
					table.insert(world.examples, string.format("%s %s: %s moved %.3f resized %.3f", base.Name,
						tostring(base:GetAttribute("WeaponId") or base:GetAttribute("ItemId")), d.Name, moved, resized))
				end
			end
			if any then
				world.changed += 1
			end
		end
		return result
	end
end

math.randomseed(SEED)
local info = MapGenerator.Build(MAP_ID)
task.wait(1.5)
out("%s seed %d built: %d weapon spots", MAP_ID, SEED, #info.lootSpots.weapon)

-- Every weapon and item on a plate.
local plate = Instance.new("Part")
plate.Name = "AuditPlate"
plate.Anchored = true
plate.Size = Vector3.new(300, 1, 300)
plate.Position = Vector3.new(0, 899.5, 3000)
plate.Parent = workspace.Map
local weaponIds = {}
for id in pairs(WeaponData.Weapons) do
	table.insert(weaponIds, id)
end
table.sort(weaponIds)
for index, id in ipairs(weaponIds) do
	LootService.DropWeapon(id, Vector3.new(-120 + index * 10, 903, 3000))
	if index % 5 == 0 then
		task.wait()
	end
end
for index, id in ipairs(ItemData.Order) do
	LootService.DropItem(id, Vector3.new(-120 + index * 10, 903, 3040), 1)
end
out("plate: %d weapons and %d items dropped; world pass on them: %d calls, %d pickups changed, %d parts moved, %d resized",
	#weaponIds, #ItemData.Order, world.calls, world.changed, world.moved, world.resized)
local plateWorld = { calls = world.calls, changed = world.changed }
LootService.Clear()

-- Guns at real spots (terrain slopes, floors, pavements).
local spots = info.lootSpots.weapon
local step = math.max(1, math.floor(#spots / SPOTS))
local dropped = 0
for index = 1, #spots, step do
	if dropped >= SPOTS then
		break
	end
	dropped += 1
	LootService.DropWeapon(weaponIds[(dropped % #weaponIds) + 1], spots[index] + Vector3.new(0, 3, 0))
	if dropped % 5 == 0 then
		task.wait()
	end
end
out("map spots: %d guns dropped; world pass on them: %d calls, %d pickups changed (all pickups so far: %d changed, %d parts moved, %d resized)",
	dropped, world.calls - plateWorld.calls, world.changed - plateWorld.changed, world.changed, world.moved, world.resized)
for _, text in ipairs(world.examples) do
	out("  world pass: %s", text)
end
LootService.Clear()

-- Drops by roof parapets and back walls.
local FLOOR_HEIGHT = 15
local function frameOf(model)
	local ground, area, levels = nil, -1, {}
	local fh = model.Name == "warehouse" and FLOOR_HEIGHT * 1.6 or FLOOR_HEIGHT
	for _, p in ipairs(model:GetChildren()) do
		if p:IsA("BasePart") and p.Name == "Floor" then
			levels[math.floor(p.Position.Y / fh + 0.5)] = true
			if math.abs(p.Position.Y) < 0.3 and p.Size.X * p.Size.Z > area then
				ground, area = p, p.Size.X * p.Size.Z
			end
		end
	end
	if not ground then
		return nil
	end
	local floors = 0
	for _ in pairs(levels) do
		floors += 1
	end
	local width, depth = math.floor(ground.Size.X + 1.4 + 0.5), math.floor(ground.Size.Z + 1.4 + 0.5)
	return { model = model, frame = CFrame.new(ground.Position.X, 0, ground.Position.Z) * ground.CFrame.Rotation,
		halfW = width / 2, halfD = depth / 2, floors = floors, topY = floors * fh }
end
local buildings = {}
for _, town in ipairs(workspace.Map:GetChildren()) do
	if town.Name == "Town" then
		for _, child in ipairs(town:GetChildren()) do
			if child:IsA("Model") and (child.Name == "house" or child.Name == "tower" or child.Name == "warehouse") then
				local b = frameOf(child)
				if b then
					table.insert(buildings, b)
				end
			end
		end
	end
end
local function newest(before)
	local folder = workspace:FindFirstChild("Loot")
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		if not before[child] then
			return child
		end
	end
end
local function snapshot()
	local set = {}
	local folder = workspace:FindFirstChild("Loot")
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		set[child] = true
	end
	return set
end
local roofTried, roofAir, roofGround, roofOnRoof = 0, 0, 0, 0
local wallTried, wallOutside, wallInWall = 0, 0, 0
for index, b in ipairs(buildings) do
	if index > 30 then
		break
	end
	if b.model.Name ~= "house" then
		for _ = 1, 8 do
			local before = snapshot()
			LootService.DropItem("Bandage", b.frame * Vector3.new(0, b.topY + 3.5, -b.halfD + 1.5), 1)
			local pickup = newest(before)
			if pickup then
				roofTried += 1
				local l = b.frame:PointToObjectSpace(pickup.Position)
				if math.abs(l.X) > b.halfW + 0.5 or math.abs(l.Z) > b.halfD + 0.5 then
					if pickup.Position.Y > 3 then
						roofAir += 1
					else
						roofGround += 1
					end
				elseif pickup.Position.Y > b.topY - 1 then
					roofOnRoof += 1
				end
				pickup:Destroy()
			end
		end
	end
	for _ = 1, 6 do
		local before = snapshot()
		LootService.DropItem("Bandage", b.frame * Vector3.new(0, 3.5, b.halfD - 0.7 - 1), 1)
		local pickup = newest(before)
		if pickup then
			wallTried += 1
			local l = b.frame:PointToObjectSpace(pickup.Position)
			if math.abs(l.Z) > b.halfD + 0.7 or math.abs(l.X) > b.halfW + 0.7 then
				wallOutside += 1
				out("  wall drop outside at %s", v3(pickup.Position))
			elseif math.abs(l.Z) > b.halfD - 0.7 - 1.4 or math.abs(l.X) > b.halfW - 0.7 - 1.4 then
				wallInWall += 1
			end
			pickup:Destroy()
		end
	end
	task.wait()
end
out("roof drops: %d, stayed on the roof %d, in mid-air outside %d, on the ground outside %d", roofTried, roofOnRoof, roofAir, roofGround)
out("wall drops: %d, outside the building %d, pad through the wall %d", wallTried, wallOutside, wallInWall)
LootService.Clear()
MapGenerator.Clear()
pcall(flush)
