-- Probe for tools/runtest.ps1 -Probe: where does Roblox's smooth terrain put its surface for
-- each kind of fill? Fills take a moment to become raycastable, so it waits before asking.
local terrain = workspace.Terrain
terrain:Clear()
task.wait(0.5)

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { terrain }
params.IgnoreWater = false

local function surfaceAt(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), params)
	return hit and string.format("%.3f %s", hit.Position.Y, tostring(hit.Material):gsub("Enum.Material.", "")) or "miss"
end

-- Blocks 40 wide, 16 tall, with their tops at different heights, well apart.
local tops = { -3, -2, -1, 0, 1, 2 }
for index, top in ipairs(tops) do
	local x = (index - 1) * 120 - 300
	terrain:FillBlock(CFrame.new(x, top - 8, 0), Vector3.new(40, 16, 40), Enum.Material.Grass)
end
-- A rotated block with its top at 0.
terrain:FillBlock(CFrame.new(0, -8, 300) * CFrame.Angles(0, 0.37, 0), Vector3.new(40, 16, 40), Enum.Material.Pavement)
-- A cylinder 0..10 and a ball whose top is at 10.
terrain:FillCylinder(CFrame.new(0, 5, 600), 10, 30, Enum.Material.Rock)
terrain:FillBall(Vector3.new(300, -20, 600), 30, Enum.Material.Rock)
-- Water block -7..-1 (the river's) and a water cylinder.
terrain:FillBlock(CFrame.new(600, -4, 600), Vector3.new(40, 6, 40), Enum.Material.Water)
task.wait(1.5)

for index, top in ipairs(tops) do
	local x = (index - 1) * 120 - 300
	print(string.format("[PROBE] block top %d -> surface %s", top, surfaceAt(x, 0)))
end
print("[PROBE] rotated block top 0 -> surface " .. surfaceAt(0, 300) .. " / edge " .. surfaceAt(15, 305))
print("[PROBE] cylinder 0..10 -> surface " .. surfaceAt(0, 600) .. " / near rim " .. surfaceAt(20, 600))
print("[PROBE] ball top 10 -> surface " .. surfaceAt(300, 600))
print("[PROBE] water block -7..-1 -> surface " .. surfaceAt(600, 600))

-- The levelSite sequence: base block top 0, then air from 2 up and a pad -2..6 (what a
-- landmark at y=2 does today), and the same pad done with tops 2 lower.
terrain:Clear()
task.wait(0.5)
terrain:FillBlock(CFrame.new(0, -8, 0), Vector3.new(400, 16, 400), Enum.Material.Grass)
terrain:FillBlock(CFrame.new(100, 27, 100), Vector3.new(60, 50, 60), Enum.Material.Air)
terrain:FillBlock(CFrame.new(100, -2, 100), Vector3.new(60, 8, 60), Enum.Material.Pavement)
terrain:FillBlock(CFrame.new(-100, 25, -100), Vector3.new(60, 50, 60), Enum.Material.Air)
terrain:FillBlock(CFrame.new(-100, -4, -100), Vector3.new(60, 8, 60), Enum.Material.Pavement)
task.wait(1.5)
print("[PROBE] ground -> " .. surfaceAt(0, 0))
print("[PROBE] levelSite at 2 (air 2.., pad -2..6) -> " .. surfaceAt(100, 100))
print("[PROBE] levelSite at 0 (air 0.., pad -8..0) -> " .. surfaceAt(-100, -100))
terrain:Clear()
