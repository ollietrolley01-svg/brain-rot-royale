-- Easter egg placement audit, for tools/runtest.ps1 -Probe (one map per run: edit MAP_ID and SEED).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_eggs.lua
--
-- Builds the map and, for every easter egg (the obby included), measures how it meets the ground:
--   * buried: parts whose top is more than 1.5 under the terrain at their centre (the build
--     check's own test), with the worst;
--   * the base: the parts standing on the ground (bottom within 0.6 of the egg's lowest point),
--     sampled at the centre and the four corners of their underside: how far the terrain rises
--     over their bottom (sunk) and falls away under it (floating), worst of each;
--   * the ground under the egg's footprint: the spread of terrain heights across it.

local MAP_ID, SEED = "SahurSprings", 101

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))

local function out(fmt, ...)
	print("[AUDIT eggs] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

math.randomseed(SEED)
local started = os.clock()
MapGenerator.Build(MAP_ID)
task.wait(1.5)
local map = workspace.Map
out("%s seed %d built in %.1fs", MAP_ID, SEED, os.clock() - started)

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }
params.IgnoreWater = true

local function groundAt(position)
	local hit = workspace:Raycast(Vector3.new(position.X, position.Y + 300, position.Z), Vector3.new(0, -600, 0), params)
	return hit and hit.Position.Y or nil
end

-- Water under an egg. The site search picks a spot by how level the ground is, and water is the
-- most level surface on a map, so before EasterEggs vetoed it the search was drawn to the river and
-- to the sea on the sand maps, and levelling the site plugged it with a disc of dirt.
local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include
surfaceParams.FilterDescendantsInstances = { workspace.Terrain }
surfaceParams.IgnoreWater = false

local function waterDepthAt(position)
	local from, down = Vector3.new(position.X, position.Y + 300, position.Z), Vector3.new(0, -600, 0)
	local surface = workspace:Raycast(from, down, surfaceParams)
	if not surface then
		return 0
	end
	local bed = workspace:Raycast(from, down, params)
	if not bed then
		return math.huge
	end
	return surface.Position.Y - bed.Position.Y
end

-- The detector has to be able to fire, or "no egg over water" means nothing. A puddle is filled
-- well away from everything, measured, and taken away again.
local probeAt = Vector3.new(1800, 0, 1800)
local before = waterDepthAt(Vector3.new(probeAt.X, 40, probeAt.Z))
workspace.Terrain:FillCylinder(CFrame.new(probeAt.X, 10, probeAt.Z) * CFrame.Angles(0, 0, math.pi / 2), 12, 20, Enum.Material.Rock)
workspace.Terrain:FillCylinder(CFrame.new(probeAt.X, 18, probeAt.Z) * CFrame.Angles(0, 0, math.pi / 2), 8, 16, Enum.Material.Water)
task.wait()
local planted = waterDepthAt(Vector3.new(probeAt.X, 40, probeAt.Z))
workspace.Terrain:FillCylinder(CFrame.new(probeAt.X, 14, probeAt.Z) * CFrame.Angles(0, 0, math.pi / 2), 40, 30, Enum.Material.Air)
out("water detector self-test: %.2f deep over dry ground, %.2f over a planted pool -> %s",
	before, planted, (before < 0.5 and planted > 1) and "PASS" or "FAIL (the water counts below prove nothing)")

local eggs = map:FindFirstChild("EasterEggs", true)
if not eggs then
	out("no EasterEggs on the map")
else
	out("container %s: FootingGroup %s", eggs.Name, tostring(eggs:GetAttribute("FootingGroup")))
	local totals = { eggs = 0, buried = 0, sunkWorst = 0, floatWorst = 0, wet = 0 }
	for _, egg in ipairs(eggs:GetChildren()) do
		local parts = {}
		local lowest = math.huge
		for _, d in ipairs(egg:GetDescendants()) do
			if d:IsA("BasePart") and d.Transparency < 0.98 then
				table.insert(parts, d)
				-- The underside's height, from the box's lowest corner.
				local _, size = d.CFrame, d.Size
				local extent = math.abs(d.CFrame.UpVector.Y) * size.Y + math.abs(d.CFrame.RightVector.Y) * size.X + math.abs(d.CFrame.LookVector.Y) * size.Z
				lowest = math.min(lowest, d.Position.Y - extent / 2)
			end
		end
		totals.eggs += 1
		local buried, worstBuried, worstBuriedText = 0, 0, "-"
		local sunk, sunkText, floating, floatText = 0, "-", 0, "-"
		local groundLow, groundHigh = math.huge, -math.huge
		local baseCount = 0
		for _, part in ipairs(parts) do
			local ground = groundAt(part.Position)
			local top = part.Position.Y + part.Size.Y / 2
			if ground and ground > top + 1.5 then
				buried += 1
				if ground - top > worstBuried then
					worstBuried = ground - top
					worstBuriedText = string.format("%s top %.1f under ground %.1f", part.Name, top, ground)
				end
			end
			local extent = math.abs(part.CFrame.UpVector.Y) * part.Size.Y + math.abs(part.CFrame.RightVector.Y) * part.Size.X
				+ math.abs(part.CFrame.LookVector.Y) * part.Size.Z
			local bottom = part.Position.Y - extent / 2
			if bottom <= lowest + 0.6 then
				baseCount += 1
				local half = part.Size / 2
				for _, corner in ipairs({ { 0, 0 }, { 1, 1 }, { -1, 1 }, { 1, -1 }, { -1, -1 } }) do
					local at = part.CFrame * Vector3.new(corner[1] * half.X, 0, corner[2] * half.Z)
					local height = groundAt(at)
					if height then
						groundLow, groundHigh = math.min(groundLow, height), math.max(groundHigh, height)
						if height - bottom > sunk then
							sunk = height - bottom
							sunkText = string.format("%s by %.2f at %s", part.Name, sunk, v3(at))
						end
						if bottom - height > floating then
							floating = bottom - height
							floatText = string.format("%s by %.2f at %s", part.Name, floating, v3(at))
						end
					end
				end
			end
		end
		totals.buried += buried
		totals.sunkWorst = math.max(totals.sunkWorst, sunk)
		totals.floatWorst = math.max(totals.floatWorst, floating)
		-- Big Squeak fills his own pond and floats in it; everything else standing in water is a
		-- site that shouldn't have been picked.
		local water = egg.Name ~= "Squeak" and waterDepthAt(egg:GetPivot().Position) or 0
		if water > 0.5 then
			totals.wet += 1
			out("  %s stands over %.2f of water", egg.Name, water)
		end
		out("%s at %s: %d parts, %d base; buried %d (worst %s); base sunk worst %s; base floating worst %s; ground under the base %.2f to %.2f (spread %.2f); FootingBase %s FootingSize %s",
			egg.Name, v3(egg:GetPivot().Position), #parts, baseCount, buried, worstBuriedText, sunkText, floatText, groundLow, groundHigh,
			groundHigh - groundLow, tostring(egg:GetAttribute("FootingBase")), tostring(egg:GetAttribute("FootingSize")))
	end
	out("SUMMARY %s seed %d: %d eggs, %d buried parts, worst base sink %.2f, worst base float %.2f, %d over water",
		MAP_ID, SEED, totals.eggs, totals.buried, totals.sunkWorst, totals.floatWorst, totals.wet)
end
MapGenerator.Clear()
pcall(flush)
