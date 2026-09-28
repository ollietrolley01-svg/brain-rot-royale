-- #85 loot spills on a real map, photographed and measured (for the coordinator's Studio).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/loot_spill_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- tools/loot_spill_proof_check.py measured the spill offline, over the compound's and the battleground's
-- real layouts as boxes (every roll lands, nothing in the bag, the 1 s settle, on the floor it was
-- thrown from). What it cannot say is how a spill LOOKS: pads stacked on one point (the scatter's
-- offsets are whole studs), pads inside the chest or the crate while it still stands, a pad inside a
-- wall by the watchtower. This builds RotRidge, runs the real ModeTeams.Setup for a Team Deathmatch,
-- seeds team 1's chests through ModeTeams.BaseLootSpots and LootService.SeedAt (GameMode's call), and
-- spills every chest.
--
-- A gallery cannot press a prompt, so the spill is made the way the chest's prompt makes it
-- (LootService spawnChest, prompt.Triggered): the same spill point, 4 studs from the chest toward the
-- opener (here: toward the compound's centre, where the pads are), and the same LootService.DropWeapon /
-- DropItem calls with `from` = the chest. Every chest gets a full-size spill: 2 guns and 4 items. The
-- chest is left standing (a real one goes 2.2 s after it opens), so the views show the first two
-- seconds. The supply crate is a stand-in block of the crate's size (9 x 8 x 9, like the real one it is
-- not in the Map, so the throw doesn't see it), spilled 7 studs toward the opener as SupplyDropService
-- does.
--
-- Notes, per chest: pads, the highest and lowest pad against the chest's floor, pairs under 0.5 apart
-- (stacked) and under 2.4 (pads overlapping), pads within 1.3 of the chest's centre (inside it while it
-- stands), and pads whose centre is inside a solid Map part. Planted: a block put on one pad must read
-- as "inside".
--
-- Views: 01-04 team 1's chest spills (by name where the compound has it: the supply-room alcoves, the
-- watchtower's base, the yard workbench, the bunker armoury); 05 the battleground's gallery chest; 06 a
-- supply crate standing over its spill; 07 the same spill once the crate has gone.

local MAP_ID, SEED = "RotRidge", 101

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function look(camera, from, target, fov)
	camera.FieldOfView = fov or 60
	camera.CFrame = CFrame.lookAt(from, target)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function lootChildren()
	local loot = workspace:FindFirstChild("Loot")
	return loot and loot:GetChildren() or {}
end

local function isPickup(item)
	return item.Name == "GroundWeapon" or item.Name == "HealPickup" or item.Name == "ItemPickup"
end

-- Solid Map parts round a pad's centre (a small ball 0.6 over the pad).
local function solidAt(position)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace:FindFirstChild("Map") or workspace.Terrain }
	local names = {}
	for _, part in ipairs(workspace:GetPartBoundsInRadius(position + Vector3.new(0, 0.3, 0), 0.25, params)) do
		if part.CanCollide then
			table.insert(names, part.Name)
		end
	end
	return names
end

-- The spill a chest's prompt makes, from `opener`: returns the new pickups.
local function spillChest(chest, opener)
	local LootService, WeaponData, ItemData = state.LootService, state.WeaponData, state.ItemData
	local seen = {}
	for _, item in ipairs(lootChildren()) do
		seen[item] = true
	end
	local toward = (opener - chest.Position) * Vector3.new(1, 0, 1)
	local spill = chest.Position + (toward.Magnitude > 0.1 and toward.Unit * 4 or Vector3.new(0, 0, 4))
	for _ = 1, 2 do
		LootService.DropWeapon(WeaponData.RollChestWeapon().id, spill, nil, chest.Position)
	end
	for _, roll in ipairs({ ItemData.RollRecovery, ItemData.RollRecovery, ItemData.RollMovement, ItemData.RollThrowable }) do
		local item = roll()
		LootService.DropItem(item.id, spill, item.pickup, chest.Position)
	end
	local out = {}
	for _, item in ipairs(lootChildren()) do
		if not seen[item] and isPickup(item) then
			table.insert(out, item)
		end
	end
	return out, spill
end

local function measure(label, centre, floorY, pads)
	local stacked, overlapping, insideChest, lo, hi = 0, 0, 0, math.huge, -math.huge
	local walls = {}
	for index, pad in ipairs(pads) do
		local p = pad.Position - Vector3.new(0, 0.3, 0)
		lo = math.min(lo, p.Y - floorY)
		hi = math.max(hi, p.Y - floorY)
		if (flat(p) - flat(centre)).Magnitude < 1.3 then
			insideChest += 1
		end
		local solid = solidAt(p)
		if #solid > 0 then
			table.insert(walls, pad.Name .. " in " .. table.concat(solid, "/"))
		end
		for other = index + 1, #pads do
			local d = (flat(pads[other].Position) - flat(pad.Position)).Magnitude
			if d < 0.5 then
				stacked += 1
			end
			if d < 2.4 then
				overlapping += 1
			end
		end
	end
	note(string.format("%s: %d pads, level %+.2f..%+.2f against the chest's floor, %d stacked pairs, %d overlapping pairs, %d inside the chest, %d inside a solid part%s",
		label, #pads, lo, hi, stacked, overlapping, insideChest, #walls, #walls > 0 and (" (" .. table.concat(walls, ", ") .. ")") or ""))
	return { stacked = stacked, walls = #walls }
end

local function setup()
	if state.ready then
		return
	end
	Lighting.ClockTime = 14.5
	math.randomseed(SEED)
	local modules = ServerScriptService:WaitForChild("Modules")
	local MapGenerator = require(modules:WaitForChild("MapGenerator"))
	local ModeTeams = require(modules:WaitForChild("ModeTeams"))
	local shared = ReplicatedStorage:WaitForChild("Shared")
	state.LootService = require(modules:WaitForChild("LootService"))
	state.WeaponData = require(shared:WaitForChild("WeaponData"))
	state.ItemData = require(shared:WaitForChild("ItemData"))
	local GameModes = require(shared:WaitForChild("GameModes"))

	local ok, info = pcall(MapGenerator.Build, MAP_ID)
	if not ok then
		note("MAP BUILD FAILED: " .. tostring(info))
		error(info)
	end
	Lighting.ClockTime = 14.5
	local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
	ModeTeams.Setup(mode, info)
	local ruin = ModeTeams.BaseRuin(1)
	if not ruin then
		note("team 1: NO COMPOUND")
		error("no compound")
	end
	state.ruin = ruin
	state.centre = ModeTeams.BaseOf(1) or ruin.frame.Position

	state.LootService.SeedAt(ModeTeams.BaseLootSpots(1, state.LootService.BaseStock.chest, 20, 80, 14, "chest"), "chest")
	task.wait(0.5)

	-- Every chest of team 1's, by the name of the spot it stands on.
	state.spills = {}
	local total = { stacked = 0, walls = 0, chests = 0 }
	for index, spot in ipairs(ruin.chestSpots or {}) do
		local name = ruin.names and ruin.names.chests and ruin.names.chests[index] or ("Chest" .. index)
		local chest = nil
		for _, item in ipairs(lootChildren()) do
			if item.Name == "Chest" and (flat(item.Position) - flat(spot.Position)).Magnitude < 3 then
				chest = item
			end
		end
		if chest then
			local toward = flat(state.centre) - flat(chest.Position)
			local opener = chest.Position + (toward.Magnitude > 0.1 and toward.Unit * 4 or Vector3.new(0, 0, 4))
			local pads, spill = spillChest(chest, opener)
			local m = measure(name, chest.Position, chest.Position.Y - 1.3, pads)
			total.stacked += m.stacked
			total.walls += m.walls
			total.chests += 1
			state.spills[name] = { chest = chest, spill = spill, opener = opener, pads = pads }
			table.insert(state.spills, name)
		else
			note(name .. ": no chest on the spot")
		end
	end
	note(string.format("team 1: %d chests spilled, %d stacked pairs, %d pads inside a solid part", total.chests, total.stacked, total.walls))

	-- Planted: a solid block on a pad must read as inside.
	local first = state.spills[1] and state.spills[state.spills[1]]
	if first and first.pads[1] then
		local block = Instance.new("Part")
		block.Anchored = true
		block.Size = Vector3.new(2, 2, 2)
		block.CFrame = CFrame.new(first.pads[1].Position)
		block.Name = "PlantedBlock"
		block.Parent = workspace:FindFirstChild("Map")
		local found = solidAt(first.pads[1].Position - Vector3.new(0, 0.3, 0))
		note("planted block on a pad: " .. (#found > 0 and "CAUGHT (" .. table.concat(found, "/") .. ")" or "MISSED"))
		block:Destroy()
	end

	-- The battleground's gallery chest (its own seeding put a chest there).
	local battleground = ModeTeams.Battleground()
	for _, spot in ipairs(battleground and battleground.lootSpots or {}) do
		if spot.kind == "chest" and not state.gallery then
			for _, item in ipairs(lootChildren()) do
				if item.Name == "Chest" and (flat(item.Position) - flat(spot.position)).Magnitude < 3 then
					local opener = item.Position + Vector3.new(4, 0, 0)
					local pads, spill = spillChest(item, opener)
					measure("battleground " .. spot.name, item.Position, item.Position.Y - 1.3, pads)
					state.gallery = { chest = item, spill = spill, opener = opener }
				end
			end
		end
	end

	-- A supply crate: a block the crate's size on open ground in front of the compound, and its spill.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain, workspace:FindFirstChild("Map") }
	local out = ruin.frame * Vector3.new(0, 0, -110)
	local hit = workspace:Raycast(out + Vector3.new(0, 600, 0), Vector3.new(0, -1200, 0), params)
	if hit then
		local crate = Instance.new("Part")
		crate.Name = "SupplyCrateStandIn"
		crate.Anchored = true
		crate.Size = Vector3.new(9, 8, 9)
		crate.Color = Color3.fromRGB(146, 112, 64)
		crate.Material = Enum.Material.WoodPlanks
		crate.CFrame = CFrame.new(hit.Position + Vector3.new(0, 4, 0))
		crate.Parent = workspace
		local opener = crate.Position + Vector3.new(0, 0, 10)
		local seen = {}
		for _, item in ipairs(lootChildren()) do
			seen[item] = true
		end
		local toward = (opener - crate.Position) * Vector3.new(1, 0, 1)
		local spill = crate.Position + toward.Unit * 7
		state.LootService.DropWeapon("CrocodiloRifle", spill, nil, crate.Position)
		for _, id in ipairs({ "MedKit", "ShieldPotion", "PopupBunker" }) do
			state.LootService.DropItem(id, spill, 1, crate.Position)
		end
		local pads = {}
		for _, item in ipairs(lootChildren()) do
			if not seen[item] and isPickup(item) then
				table.insert(pads, item)
			end
		end
		local inside = 0
		for _, pad in ipairs(pads) do
			local d = pad.Position - crate.Position
			if math.abs(d.X) < 4.5 and math.abs(d.Z) < 4.5 then
				inside += 1
			end
		end
		note(string.format("supply crate stand-in: %d pads, %d inside the 9x9 crate while it stands", #pads, inside))
		state.crate = { crate = crate, spill = spill, opener = opener }
	else
		note("supply crate: no ground in front of the compound")
	end
	state.ready = true
end

-- A chest's spill from the opener's side, a little above eye height.
local function chestView(slot, preferred)
	return {
		name = string.format("%02d_chest_%s", slot, preferred),
		settle = 3,
		setup = function(_, camera)
			setup()
			local name = state.spills[preferred] and preferred or state.spills[slot]
			local s = name and state.spills[name]
			if not s then
				note("view " .. slot .. ": no spill")
				return
			end
			note(string.format("view %02d: %s", slot, name))
			local away = flat(s.opener) - flat(s.chest.Position)
			away = away.Magnitude > 0.1 and away.Unit or Vector3.new(0, 0, 1)
			look(camera, s.spill + away * 7 + Vector3.new(0, 7, 0), s.spill, 65)
		end,
	}
end

local views = {
	chestView(1, "SupplyAlcove2"),
	chestView(2, "TowerBase"),
	chestView(3, "YardWorkbench"),
	chestView(4, "BunkerArmoury"),
	{
		name = "05_battleground_gallery_chest",
		settle = 3,
		setup = function(_, camera)
			setup()
			local g = state.gallery
			if not g then
				note("view 05: no battleground gallery chest")
				return
			end
			look(camera, g.spill + Vector3.new(8, 7, 0), g.spill, 65)
		end,
	},
	{
		name = "06_supply_crate_standing",
		settle = 3,
		setup = function(_, camera)
			setup()
			local c = state.crate
			if not c then
				return
			end
			c.crate.Parent = workspace
			look(camera, c.spill + Vector3.new(0, 9, 12), c.spill, 65)
		end,
	},
	{
		name = "07_supply_crate_gone",
		settle = 3,
		setup = function(_, camera)
			setup()
			local c = state.crate
			if not c then
				return
			end
			c.crate.Parent = nil
			look(camera, c.spill + Vector3.new(0, 9, 12), c.spill, 65)
		end,
	},
}

return views
