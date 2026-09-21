-- Wall-scan diagnostic for tools/runtest.ps1 -Probe: why audit_buildings' wall scan reports
-- "windows 0, wallHoles 0" on a building full of windows, and why its planted-fault self-test
-- (take a wall panel out, expect a hole) did not fire.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wallscan_probe.lua
--
-- One house, built by the real MapBuildings, scanned with the audit's own ray geometry. It reports
-- WHAT EACH BLOCKED RAY HIT rather than just that it was blocked, in four states:
--   as built                         what the audit sees today
--   glass hidden                     what the audit intends to see (it sets WindowGlass CanQuery false)
--   glass hidden + a panel removed   the planted fault: this MUST open a hole
--   glass hidden + trim removed      to tell trim apart from structure as the blocker
-- A scan whose planted fault doesn't fire proves nothing, so this exists to find the blocker by name.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapBuildings = require(modules:WaitForChild("MapBuildings"))
local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))

local FLOOR_HEIGHT, WH = 15, 0.7
local STEP_A, STEP_H = 0.25, 0.5

local function out(fmt, ...)
	print("[WALLSCAN] " .. string.format(fmt, ...))
end

local folder = Instance.new("Folder")
folder.Name = "WallScanProbe"
folder.Parent = workspace

local origin = Vector3.new(0, 500, 0)
math.randomseed(11)
local plan = { archetype = "house", width = 32, depth = 30, floors = 2, dock = false }
MapBuildings.BuildBuilding(folder, origin, MapData.Maps.SahurSprings, {}, { weapon = {}, heal = {}, item = {} }, table.clone(plan), 0)
local model = folder:FindFirstChild("house")
local halfW, halfD = plan.width / 2, plan.depth / 2

-- Everything the front face of the ground floor could possibly contain, so a blocker can be named.
local counts = {}
for _, part in ipairs(model:GetDescendants()) do
	if part:IsA("BasePart") then
		local key = string.format("%s canQuery=%s", part.Name, tostring(part.CanQuery))
		counts[key] = (counts[key] or 0) + 1
	end
end
local names = {}
for key in pairs(counts) do
	table.insert(names, key)
end
table.sort(names)
for _, key in ipairs(names) do
	out("parts: %-34s x%d", key, counts[key])
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { model }

-- The audit's own ray, through a chosen face. THE FRONT GROUND FLOOR HAS NO WINDOWS — buildWall gives
-- that wall a door gap instead — so scanning it says nothing about windows or glass, which is why the
-- first run of this probe learned nothing. The side faces are where the ground-floor windows are.
local function scanFace(label, face)
	local open, blocked, hits = 0, 0, {}
	local span = (face == "front" and halfW or halfD) + WH
	for i = 0, math.floor(2 * span / STEP_A) do
		local a = -span + 0.013 + i * STEP_A
		-- The ground floor's window band only: sill 4.0 to head 9.0 above the floor.
		for j = 0, math.floor((9.4 - 0.63) / STEP_H) do
			local h = 0.63 + j * STEP_H
			local from, to
			if face == "front" then
				from = origin + Vector3.new(a, h, -(halfD + 0.75))
				to = origin + Vector3.new(a, h, -(halfD - 0.95))
			else
				from = origin + Vector3.new(-(halfW + 0.75), h, a)
				to = origin + Vector3.new(-(halfW - 0.95), h, a)
			end
			local result = workspace:Raycast(from, to - from, params)
			if result then
				blocked += 1
				local key = string.format("%s (%s)", result.Instance.Name, result.Instance.ClassName)
				hits[key] = (hits[key] or 0) + 1
			else
				open += 1
			end
		end
	end
	local list = {}
	for key, n in pairs(hits) do
		table.insert(list, string.format("%s x%d", key, n))
	end
	table.sort(list)
	out("%-42s open %4d, blocked %4d   blockers: %s", label, open, blocked, table.concat(list, ", "))
	return open
end

local asBuiltFront = scanFace("as built [front: door, no windows]", "front")
local asBuilt = scanFace("as built [left wall: windows]", "left")

-- What the audit does: take the panes out of the rays' way.
local panes = {}
for _, part in ipairs(model:GetDescendants()) do
	if part:IsA("BasePart") and part.Name == "WindowGlass" then
		table.insert(panes, { part = part, was = part.CanQuery })
		part.CanQuery = false
	end
end
out("panes found: %d", #panes)
local glassHidden = scanFace("glass hidden, as the audit does [left]", "left")

-- The planted fault: take out one ground-floor wall panel of the front face. A scan that can't see
-- THIS hole can't see a real one either.
local removed = nil
for _, part in ipairs(model:GetDescendants()) do
	if part:IsA("BasePart") and part.Name == "Wall" and not removed then
		local local_ = part.Position - origin
		-- A pier between two windows on the LEFT wall's ground floor. (The first version of this filter
		-- looked on the front face and matched nothing, so the "planted fault" removed no panel and the
		-- self-test could not have fired whatever the scan did.)
		if math.abs(local_.X + halfW) < 1 and local_.Y > 3 and local_.Y < FLOOR_HEIGHT and part.Size.Z < 12 then
			removed = { part = part, size = part.Size, cframe = part.CFrame }
			out("planted fault: removing left-wall panel size %s at local %s", tostring(part.Size), tostring(local_))
			part.Parent = nil
		end
	end
end
local planted = removed and scanFace("glass hidden + panel removed [left]", "left") or glassHidden
if removed then
	removed.part.Parent = model
end

-- And with every non-collidable decoration out of the way, to tell trim from structure.
local trimHidden = {}
for _, part in ipairs(model:GetDescendants()) do
	if part:IsA("BasePart") and part.CanQuery and not part.CanCollide then
		table.insert(trimHidden, part)
		part.CanQuery = false
	end
end
out("non-collidable but queryable parts hidden: %d", #trimHidden)
scanFace("glass hidden + queryable trim hidden [left]", "left")

out("SUMMARY as-built open %d, glass-hidden open %d, planted-fault open %d -> the self-test %s",
	asBuilt, glassHidden, planted, planted > glassHidden and "FIRES" or "DOES NOT FIRE (the scan is blind)")
folder:Destroy()
