-- Probe for tools/runtest.ps1 -Probe: every terrain material's surface over flat ground written the
-- relief pass's way, at two heights off the whole-stud grid, and how far a rough or stepped material
-- disturbs a smooth strip beside it.
local terrain = workspace.Terrain
terrain:Clear()
task.wait(0.5)

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { terrain }
params.IgnoreWater = true

local LIFT = 2
local MATERIALS = { "Asphalt", "Basalt", "Brick", "Cobblestone", "Concrete", "CrackedLava", "Glacier", "Grass", "Ground", "Ice",
	"LeafyGrass", "Limestone", "Mud", "Pavement", "Rock", "Salt", "Sand", "Sandstone", "Slate", "Snow", "WoodPlanks" }
local HEIGHTS = { 9.49, 1.3, 5.75 }
local SIZE = 48

local function writeFlat(x0, z0, sizeX, sizeZ, height, materialAt)
	local region = Region3.new(Vector3.new(x0, -16, z0), Vector3.new(x0 + sizeX, 32, z0 + sizeZ))
	local size = region.Size / 4
	local materials, occupancies = {}, {}
	for ix = 1, size.X do
		materials[ix], occupancies[ix] = {}, {}
		for iy = 1, size.Y do
			materials[ix][iy], occupancies[ix][iy] = {}, {}
			local bottom = -16 + (iy - 1) * 4
			for iz = 1, size.Z do
				local occupancy = math.clamp((height - LIFT - bottom) / 4, 0, 1)
				occupancies[ix][iy][iz] = occupancy
				materials[ix][iy][iz] = occupancy > 0 and materialAt(x0 + (ix - 0.5) * 4) or Enum.Material.Air
			end
		end
	end
	terrain:WriteVoxels(region, 4, materials, occupancies)
end

local cases = {}
for row, height in ipairs(HEIGHTS) do
	for column, name in ipairs(MATERIALS) do
		local x0, z0 = (column - 1) * (SIZE + 16) - 672, (row - 1) * (SIZE + 16) - 96
		writeFlat(x0, z0, SIZE, SIZE, height, function()
			return Enum.Material[name]
		end)
		table.insert(cases, { name = name, height = height, x0 = x0, z0 = z0 })
	end
end
task.wait(2)

for _, case in ipairs(cases) do
	local low, high, sum, count = math.huge, -math.huge, 0, 0
	for dx = 12, SIZE - 12 do
		for dz = 12, SIZE - 12 do
			local hit = workspace:Raycast(Vector3.new(case.x0 + dx + 0.5, 100, case.z0 + dz + 0.5), Vector3.new(0, -200, 0), params)
			if hit then
				local error = hit.Position.Y - case.height
				low, high, sum, count = math.min(low, error), math.max(high, error), sum + error, count + 1
			end
		end
	end
	print(string.format("[PROBE] %-11s height %5.2f: surface - wanted %.3f..%.3f mean %.3f", case.name, case.height, low, high, sum / math.max(1, count)))
end

-- Bleed: a 64-wide Ground strip (x 0..64) between two 32-wide strips of the rough or stepped material,
-- at 9.49; the surface every stud across.
terrain:Clear()
task.wait(0.5)
local row = 0
for _, name in ipairs({ "Rock", "Basalt", "Slate", "Concrete", "Pavement" }) do
	local z0 = row * 64 - 160
	writeFlat(-32, z0, 128, 32, 9.49, function(x)
		return (x > 0 and x < 64) and Enum.Material.Ground or Enum.Material[name]
	end)
	row += 1
end
task.wait(2)
row = 0
for _, name in ipairs({ "Rock", "Basalt", "Slate", "Concrete", "Pavement" }) do
	local z = row * 64 - 160 + 16
	local worst = {}
	for x = -8, 72 do
		local low, high = math.huge, -math.huge
		for dz = -6, 6 do
			local hit = workspace:Raycast(Vector3.new(x + 0.5, 100, z + dz + 0.5), Vector3.new(0, -200, 0), params)
			if hit then
				low, high = math.min(low, hit.Position.Y - 9.49), math.max(high, hit.Position.Y - 9.49)
			end
		end
		if x % 2 == 0 then
			table.insert(worst, string.format("%d:%.2f/%.2f", x, low, high))
		end
	end
	print(string.format("[PROBE] bleed %s | Ground 0..64 | %s: %s", name, name, table.concat(worst, " ")))
	row += 1
end
terrain:Clear()
print("[PROBE] done")
