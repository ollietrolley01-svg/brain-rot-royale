-- Probe for tools/runtest.ps1: parts that move on the client but still block on the server.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_animated_collision.lua
--
-- AmbientClient spins, bobs and sways parts tagged AmbientSpin / AmbientBob / AmbientSway. That is a
-- CLIENT animation: the server's copy never moves, so its collision box and its raycast box stay
-- exactly where the part was built. A tagged part left CanCollide on is therefore an invisible wall
-- standing where the part only LOOKS like it is, and one left CanQuery on is an invisible wall for
-- bullets — you shoot at the vane you can see and hit nothing, or hit nothing you can see.
--
-- Reported per source (each map, then the lobby) and per model, with what the part is and where, so
-- an owner can tell a decoration (make it CanCollide false) from something meant to be stood on or
-- shot (animate it on the server, or don't animate it).
--
-- The self-test plants both faults on a part of its own and requires the counter to find them, so a
-- clean map can't be a broken counter.

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local modules = ServerScriptService:WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local LobbyService = require(modules:WaitForChild("LobbyService"))

-- One map per run keeps Studio well under the memory ceiling; RotRidge is where the finding was.
local MAPS = { "RotRidge" }
local SEED = 101
local TAGS = { "AmbientSpin", "AmbientBob", "AmbientSway" }

local function out(fmt, ...)
	print("[AUDIT animated] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.0f,%.0f,%.0f)", v.X, v.Y, v.Z)
end

-- The model a part belongs to, for a name an owner can search for.
local function ownerOf(part, root)
	local node = part
	while node and node.Parent and node.Parent ~= root and node.Parent ~= workspace do
		node = node.Parent
	end
	return node and node.Name or "?"
end

local function sweep(label, root)
	if not root then
		out("%s: nothing built", label)
		return 0, 0
	end
	local tagged, solid, queryable = 0, {}, {}
	for _, tag in ipairs(TAGS) do
		for _, part in ipairs(CollectionService:GetTagged(tag)) do
			if part:IsA("BasePart") and part:IsDescendantOf(root) then
				tagged += 1
				if part.CanCollide then
					table.insert(solid, string.format("%s in %s at %s (%s)", part.Name, ownerOf(part, root), v3(part.Position), tag))
				elseif part.CanQuery then
					table.insert(queryable, string.format("%s in %s at %s (%s)", part.Name, ownerOf(part, root), v3(part.Position), tag))
				end
			end
		end
	end
	out("%s: %d animated parts; %d still collide, %d still hit by raycasts", label, tagged, #solid, #queryable)
	for index, text in ipairs(solid) do
		if index <= 12 then
			out("    collides: %s", text)
		end
	end
	for index, text in ipairs(queryable) do
		if index <= 12 then
			out("    raycast:  %s", text)
		end
	end
	return #solid, #queryable
end

-- Self-test: a part of our own, animated and left solid, must be counted.
local stage = Instance.new("Folder")
stage.Name = "AnimatedProbeStage"
stage.Parent = workspace
local planted = Instance.new("Part")
planted.Name = "PlantedVane"
planted.Size = Vector3.new(2, 2, 2)
planted.Position = Vector3.new(0, 3000, 0)
planted.Anchored = true
planted.CanCollide = true
planted.CanQuery = true
planted.Parent = stage
CollectionService:AddTag(planted, "AmbientSpin")
local plantedSolid = sweep("self-test (one planted solid spinner)", stage)
out("self-test: %s", plantedSolid == 1 and "PASS" or "FAIL (the counts below prove nothing)")
CollectionService:RemoveTag(planted, "AmbientSpin")
stage:Destroy()

local totalSolid, totalQuery = 0, 0
-- Reuse a lobby another section of a merged run already built; otherwise build one, into the same
-- folder and at the same base tools/audit_lobby.lua uses.
local lobbyFolder = workspace:FindFirstChild("Lobby")
if not lobbyFolder then
	lobbyFolder = Instance.new("Folder")
	lobbyFolder.Name = "Lobby"
	lobbyFolder.Parent = workspace
	local okLobby, errLobby = pcall(LobbyService.Build, lobbyFolder, Vector3.new(0, 2000, 0))
	if not okLobby then
		out("lobby build failed: %s", tostring(errLobby))
	end
	task.wait(1)
end
local lobbySolid, lobbyQuery = sweep("lobby", lobbyFolder)
totalSolid += lobbySolid
totalQuery += lobbyQuery

for _, mapId in ipairs(MAPS) do
	math.randomseed(SEED)
	MapGenerator.Build(mapId)
	task.wait(1)
	local solid, query = sweep(mapId, workspace:FindFirstChild("Map"))
	totalSolid += solid
	totalQuery += query
	MapGenerator.Clear()
	task.wait(0.5)
end

out("RESULT %s: %d animated parts still collide, %d still stop a raycast",
	(totalSolid == 0 and totalQuery == 0) and "PASS" or "FAIL", totalSolid, totalQuery)
pcall(flush)
