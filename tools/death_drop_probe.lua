-- Studio probe for "no one's dropping loot in battle royale" (Oliver, 2026-09-24).
--
-- Run in the server command bar during a live battle-royale match (Play, then switch to the server
-- view). It kills the nearest living bot to the first player, then counts the pickups in workspace.Loot
-- within 20 studs of where it died at 1, 10 and 60 s, and prints any death-drop / death-effect warnings
-- the server raised meanwhile (MatchService "death drop failed", CombatService "death effect failed").
-- tools/loot_drop_check.py covers everything from MatchService's dropLoot down; this covers the Died ->
-- HandleDeath -> eliminate hop above it, and replication, on a real map.

local Players = game:GetService("Players")
local LogService = game:GetService("LogService")

local player = Players:GetPlayers()[1]
local anchor = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
if not anchor then
	warn("[death_drop_probe] no player character")
	return
end

local best, bestDistance = nil, math.huge
for _, model in ipairs(workspace:GetDescendants()) do
	if model:IsA("Model") and model ~= player.Character then
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and root and humanoid.Health > 0 and not Players:GetPlayerFromCharacter(model) then
			local distance = (root.Position - anchor.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = model, distance
			end
		end
	end
end
if not best then
	warn("[death_drop_probe] no living bot")
	return
end

local warnings = {}
local logConnection = LogService.MessageOut:Connect(function(message)
	if string.find(message, "death drop failed", 1, true) or string.find(message, "death effect failed", 1, true) then
		table.insert(warnings, message)
	end
end)

local at = best.HumanoidRootPart.Position
print(string.format("[death_drop_probe] killing %s at %s (%.0f studs away)", best.Name, tostring(at), bestDistance))
best:FindFirstChildOfClass("Humanoid").Health = 0

local function count()
	local loot = workspace:FindFirstChild("Loot")
	local found = {}
	for _, item in ipairs(loot and loot:GetChildren() or {}) do
		if item:IsA("BasePart") and (item.Position - at).Magnitude < 20 then
			table.insert(found, item.Name .. ":" .. tostring(item:GetAttribute("WeaponId") or item:GetAttribute("ItemId")))
		end
	end
	return found
end

local elapsed = 0
for _, mark in ipairs({ 1, 10, 60 }) do
	task.wait(mark - elapsed)
	elapsed = mark
	local found = count()
	print(string.format("[death_drop_probe] %d s: %d pickup(s) by the body: %s", mark, #found, table.concat(found, ", ")))
end
logConnection:Disconnect()
print("[death_drop_probe] warnings: " .. (#warnings > 0 and table.concat(warnings, " | ") or "none"))
