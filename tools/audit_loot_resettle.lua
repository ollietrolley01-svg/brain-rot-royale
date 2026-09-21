-- Probe for tools/runtest.ps1 -Probe: loot left floating when the floor under it breaks.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_loot_resettle.lua
--
-- Builds a map with its loot, then finds pickups and chests standing on breakable parts (floors,
-- roofs, stairs, furniture). Two rounds on different samples:
--   planted  LootService's hook (DestructibleService.OnPartBroken) switched off: the part under each
--            sample is broken, and the floating counter must find those samples hanging. This proves
--            the counter can fail.
--   real     the hook as the game has it: the same break, and every sample must come down onto
--            something (a new pickup of the same kind with the same weapon/item, standing within
--            FLOAT of a surface), with nothing left hanging where the old one was.
-- One map per run (edit MAP_ID and SEED).

local MAP_ID, SEED = "SahurSprings", 101
local SAMPLES = 6
local FLOAT = 1.2

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local LootService = require(modules:WaitForChild("LootService"))
local DestructibleService = require(modules:WaitForChild("DestructibleService"))

local function out(fmt, ...)
	print("[AUDIT resettle] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

math.randomseed(SEED)
local info = MapGenerator.Build(MAP_ID)
task.wait(1)
-- Populate yields between batches and returns when it's done, as MatchService uses it.
local okPopulate, errPopulate = pcall(LootService.Populate, info)
if not okPopulate then
	out("LootService.Populate failed: %s", tostring(errPopulate))
end
task.wait(2)

local loot = workspace:FindFirstChild("Loot")
local map = workspace:FindFirstChild("Map")
if not loot or not map then
	out("no %s on the map: can't measure", not loot and "Loot folder" or "Map")
	pcall(flush)
	return
end

local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include
surfaceParams.FilterDescendantsInstances = { map, workspace.Terrain }

-- How far a loot node's underside hangs over the nearest surface below it.
--
-- Measured from the real underside, not a guess per name. Assuming 0.3 under the centre reported a
-- settled Rot Mine as floating 0.24 and a settled barrel as floating 1.36: both models hang a carry
-- strap (and the barrel a good deal of barrel) below the part the guess was measuring from, and
-- DestructibleService.SettleDown lands a model on its BOUNDING BOX, which is the right thing for it
-- to do. A part that is a whole loot node (a pickup, the chest) is measured from its own box.
local function bottomOf(node)
	if node:IsA("Model") then
		local box, size = node:GetBoundingBox()
		return box.Position.Y - size.Y / 2
	end
	local frame, size = node.CFrame, node.Size
	local reach = math.abs(frame.RightVector.Y) * size.X + math.abs(frame.UpVector.Y) * size.Y + math.abs(frame.LookVector.Y) * size.Z
	local lowest = node.Position.Y - reach / 2
	-- The chest part carries its planks, straps, feet and lid as children.
	for _, child in ipairs(node:GetDescendants()) do
		if child:IsA("BasePart") then
			local cf, cs = child.CFrame, child.Size
			local childReach = math.abs(cf.RightVector.Y) * cs.X + math.abs(cf.UpVector.Y) * cs.Y + math.abs(cf.LookVector.Y) * cs.Z
			lowest = math.min(lowest, child.Position.Y - childReach / 2)
		end
	end
	return lowest
end
-- Takes a part or a whole model: a barrel and a mine are models whose lowest piece is not the part
-- the model pivots on, and measuring from that part reported both as floating when they were down.
local function gapUnder(node)
	local position = node:IsA("Model") and node:GetBoundingBox().Position or node.Position
	local bottom = bottomOf(node)
	local hit = workspace:Raycast(Vector3.new(position.X, bottom + 0.5, position.Z), Vector3.new(0, -300, 0), surfaceParams)
	return hit and (bottom - hit.Position.Y) or math.huge, hit
end

-- Loot nodes whose surface below is a breakable part.
local candidates = {}
local kinds = {}
for _, node in ipairs(loot:GetChildren()) do
	if node:IsA("BasePart") and (node.Name == "GroundWeapon" or node.Name == "HealPickup" or node.Name == "ItemPickup" or node.Name == "Chest") then
		kinds[node.Name] = (kinds[node.Name] or 0) + 1
		local gap, hit = gapUnder(node)
		if hit and hit.Instance and gap < FLOAT and DestructibleService.FromPart(hit.Instance) and hit.Instance.Name ~= DestructibleService.GlassName then
			table.insert(candidates, { node = node, part = hit.Instance })
		end
	end
end
local kindList = {}
for name, count in pairs(kinds) do
	table.insert(kindList, name .. " " .. count)
end
out("%s seed %d: loot %s; %d on breakable parts", MAP_ID, SEED, table.concat(kindList, ", "), #candidates)
if #candidates < 2 then
	out("RESULT INCONCLUSIVE: fewer than 2 samples on breakable parts")
	pcall(flush)
	return
end

-- Distinct parts only, split between the two rounds.
local used = {}
local rounds = { planted = {}, real = {} }
for _, candidate in ipairs(candidates) do
	if not used[candidate.part] then
		used[candidate.part] = true
		local round = #rounds.planted <= #rounds.real and "planted" or "real"
		if #rounds[round] < SAMPLES then
			table.insert(rounds[round], candidate)
		end
	end
end

local function describe(node)
	return node.Name .. ":" .. tostring(node:GetAttribute("WeaponId") or node:GetAttribute("ItemId") or "")
end

local function runRound(name, samples, hookOn)
	-- The listeners are a private list now, so the planted round switches them off at the source.
	DestructibleService.PartBrokenEnabled = hookOn
	local before = {}
	for index, sample in ipairs(samples) do
		before[index] = { at = sample.node.Position, what = describe(sample.node), node = sample.node }
		DestructibleService.Damage(sample.part, 1e6, nil, nil)
	end
	task.wait(0.5)
	DestructibleService.PartBrokenEnabled = true

	local hanging, landed, missing = 0, 0, 0
	for index, info in ipairs(before) do
		local old = info.node
		if old.Parent then
			local gap = gapUnder(old)
			if gap > FLOAT then
				hanging += 1
				out("  %s: %s still at %s, hanging %.1f over the surface below", name, info.what, v3(info.at), gap)
			else
				landed += 1
			end
		else
			-- Rebuilt: the nearest node of the same kind within 12 studs across, below where it was.
			local best, bestDistance = nil, math.huge
			for _, node in ipairs(loot:GetChildren()) do
				if node:IsA("BasePart") and describe(node) == info.what then
					local flat = Vector3.new(node.Position.X - info.at.X, 0, node.Position.Z - info.at.Z).Magnitude
					-- At or below where it was, not "at least half a stud below": a chest standing on a
					-- ground-floor slab falls only that slab's thickness, which put it exactly on the old
					-- threshold and had three settled chests counted as lost.
					if flat < 12 and node.Position.Y <= info.at.Y + 0.1 and flat < bestDistance then
						best, bestDistance = node, flat
					end
				end
			end
			if best then
				local gap = gapUnder(best)
				if gap <= FLOAT then
					landed += 1
				else
					hanging += 1
					out("  %s: %s rebuilt at %s but hanging %.1f", name, info.what, v3(best.Position), gap)
				end
			else
				missing += 1
				out("  %s: %s from %s is gone with nothing rebuilt below", name, info.what, v3(info.at))
			end
		end
	end
	out("%s round (hook %s): %d samples, %d hanging, %d down on a surface, %d lost", name, hookOn and "on" or "off", #samples, hanging, landed, missing)
	return hanging, landed, missing
end

-- Barrels and mines are checked after the loot rounds below.
local HazardService = require(modules:WaitForChild("HazardService"))

local plantedHanging = runRound("planted", rounds.planted, false)
local realHanging, realLanded, realMissing = runRound("real", rounds.real, true)
local counterWorks = plantedHanging > 0
local fixed = realHanging == 0 and realMissing == 0 and realLanded == #rounds.real
out("RESULT counter self-test %s (planted hanging %d of %d); resettle %s", counterWorks and "PASS" or "FAIL", plantedHanging, #rounds.planted,
	fixed and "PASS" or "FAIL")

-- A mine laid on a breakable floor: it must land, stay armed, and its trigger must follow it down.
local mineFloor, mineAt = nil, nil
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") and d.CanCollide and (d.Name == "Floor" or d.Name == "Roof") and DestructibleService.FromPart(d) then
		mineFloor = d
		mineAt = d.Position + Vector3.new(0, d.Size.Y / 2 + 0.2, 0)
		break
	end
end
-- A barrel standing on a breakable part must land too (MapBuildings puts them on every storey).
local barrel, barrelPart = nil, nil
for _, model in ipairs(map:GetDescendants()) do
	if model:IsA("Model") and model.Name == "ExplosiveBarrel" and model.PrimaryPart then
		local gap, hit = gapUnder(model.PrimaryPart)
		if hit and hit.Instance and gap < 2 and DestructibleService.FromPart(hit.Instance)
			and hit.Instance.Name ~= DestructibleService.GlassName then
			barrel, barrelPart = model, hit.Instance
			break
		end
	end
end
if not barrel then
	out("barrel: none standing on a breakable part; skipped")
else
	local was = barrel:GetPivot().Position
	DestructibleService.Damage(barrelPart, 1e6, nil, nil)
	task.wait(0.6)
	if not barrel.Parent then
		out("barrel: it went with the part (its own blast or the clean-up); skipped")
	else
		local gap = gapUnder(barrel)
		out("barrel: %s -> %s, now %.2f over what's below it -> %s", v3(was), v3(barrel:GetPivot().Position), gap, gap <= FLOAT and "PASS" or "FAIL")
	end
end

if not mineFloor then
	out("mine: no breakable floor found; skipped")
else
	local folder = Instance.new("Folder")
	folder.Name = "ResettleProbeHazards"
	folder.Parent = workspace
	local mine = HazardService.Mine(folder, mineAt, nil)
	if not mine then
		out("mine: HazardService.Mine returned nothing; skipped")
	else
		task.wait(2)
		local armedBefore = HazardService.IsArmed(mine)
		local before = mine:GetPivot().Position
		DestructibleService.Damage(mineFloor, 1e6, nil, nil)
		task.wait(0.6)
		local after = mine.Parent and mine:GetPivot().Position or nil
		local armedAfter = mine.Parent and HazardService.IsArmed(mine) or false
		local gap = mine.Parent and gapUnder(mine) or math.huge
		out("mine: armed before %s, after %s; %s -> %s; now %.2f over what's below it",
			tostring(armedBefore), tostring(armedAfter), v3(before), after and v3(after) or "gone", gap)
		-- Still there, still armed, and resting on what's under it now. Not "it fell half a stud":
		-- a mine laid on a thin floor has only that floor's thickness to fall.
		local minePass = armedBefore and armedAfter and after ~= nil and after.Y <= before.Y + 0.05 and gap <= FLOAT
		out("RESULT mine settle %s", minePass and "PASS" or "FAIL")
	end
	folder:Destroy()
end
MapGenerator.Clear()
pcall(function()
	LootService.Clear()
end)
pcall(flush)
