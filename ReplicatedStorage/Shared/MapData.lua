-- Map presets. Ground is real Roblox Terrain rather than a flat Part, and every preset
-- carries its own material palette so towns don't all read as the same grey boxes.

local MapData = {}

MapData.Maps = {
	SahurSprings = {
		name = "Sahur Springs",
		description = "Rolling grassland with five spread-out villages. Long sightlines.",
		radius = 1280,
		towns = 6,
		buildingsPerTown = { 5, 9 },
		terrainMaterial = Enum.Material.Grass,
		propDensity = 1.0,
		wallMaterials = { Enum.Material.Brick, Enum.Material.WoodPlanks, Enum.Material.Concrete },
		wallColors = {
			Color3.fromRGB(188, 140, 118),
			Color3.fromRGB(206, 192, 170),
			Color3.fromRGB(158, 148, 136),
			Color3.fromRGB(172, 124, 104),
		},
		roofMaterial = Enum.Material.Slate,
		roofColors = { Color3.fromRGB(96, 74, 66), Color3.fromRGB(72, 82, 94), Color3.fromRGB(110, 64, 56) },
		floorMaterial = Enum.Material.WoodPlanks,
	},
	TralalaTown = {
		name = "Tralala Town",
		description = "A dense downtown grid. Tall, tight and vertical — rooftops matter.",
		radius = 950,
		towns = 4,
		buildingsPerTown = { 9, 13 },
		terrainMaterial = Enum.Material.Ground,
		propDensity = 0.4,
		wallMaterials = { Enum.Material.Concrete, Enum.Material.Brick, Enum.Material.Marble },
		wallColors = {
			Color3.fromRGB(150, 156, 172),
			Color3.fromRGB(118, 122, 138),
			Color3.fromRGB(176, 172, 166),
			Color3.fromRGB(132, 108, 100),
		},
		roofMaterial = Enum.Material.Concrete,
		roofColors = { Color3.fromRGB(84, 88, 100), Color3.fromRGB(66, 70, 82) },
		floorMaterial = Enum.Material.Concrete,
	},
	BombardiroBay = {
		name = "Bombardiro Bay",
		description = "Sun-bleached coastal town on open sand. Sniper country.",
		radius = 1480,
		towns = 7,
		buildingsPerTown = { 4, 7 },
		terrainMaterial = Enum.Material.Sand,
		propDensity = 0.7,
		wallMaterials = { Enum.Material.Sandstone, Enum.Material.Concrete, Enum.Material.Brick },
		wallColors = {
			Color3.fromRGB(226, 208, 176),
			Color3.fromRGB(206, 182, 148),
			Color3.fromRGB(188, 166, 142),
			Color3.fromRGB(224, 190, 152),
		},
		roofMaterial = Enum.Material.WoodPlanks,
		roofColors = { Color3.fromRGB(150, 104, 76), Color3.fromRGB(122, 88, 68) },
		floorMaterial = Enum.Material.Sandstone,
	},
	RotRidge = {
		name = "Rot Ridge",
		description = "Rocky highland basin. Cover everywhere, fastest storm on the rotation.",
		radius = 880,
		towns = 5,
		buildingsPerTown = { 4, 8 },
		terrainMaterial = Enum.Material.Rock,
		propDensity = 1.4,
		wallMaterials = { Enum.Material.Cobblestone, Enum.Material.Slate, Enum.Material.Concrete },
		wallColors = {
			Color3.fromRGB(140, 132, 124),
			Color3.fromRGB(112, 106, 102),
			Color3.fromRGB(128, 118, 110),
			Color3.fromRGB(98, 100, 96),
		},
		roofMaterial = Enum.Material.Slate,
		roofColors = { Color3.fromRGB(70, 74, 78), Color3.fromRGB(88, 82, 78) },
		floorMaterial = Enum.Material.Wood,
	},
	PatapimPlains = {
		name = "Patapim Plains",
		description = "Farmland ringing one big central town. Hot drop guaranteed.",
		radius = 1150,
		towns = 5,
		buildingsPerTown = { 6, 10 },
		terrainMaterial = Enum.Material.LeafyGrass,
		propDensity = 1.6,
		wallMaterials = { Enum.Material.WoodPlanks, Enum.Material.Brick, Enum.Material.Wood },
		wallColors = {
			Color3.fromRGB(172, 126, 92),
			Color3.fromRGB(198, 160, 122),
			Color3.fromRGB(150, 112, 84),
			Color3.fromRGB(186, 178, 158),
		},
		roofMaterial = Enum.Material.Slate,
		roofColors = { Color3.fromRGB(118, 62, 54), Color3.fromRGB(92, 70, 60) },
		floorMaterial = Enum.Material.WoodPlanks,
	},
}

MapData.Order = { "SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains" }

-- Time of day and light per map, so the five don't all look like the same afternoon. Applied by
-- MapGenerator when a map is built and put back to the lobby's default when it's cleared. No fog:
-- Bootstrap keeps that off for the whole game.
MapData.DefaultLighting = {
	clockTime = 14, brightness = 2, ambient = Color3.fromRGB(70, 70, 70), outdoorAmbient = Color3.fromRGB(128, 128, 128),
	shadowSoftness = 0.2,
}
-- Ambient particles drawn around the camera on each map (HudClient): pollen over the grass,
-- dust between the blocks, blown sand on the coast, mist at dawn in the highlands, fireflies
-- over the farms. Fields map onto a ParticleEmitter.
MapData.Ambient = {
	SahurSprings = { color = Color3.fromRGB(255, 240, 170), size = 0.35, rate = 14, speed = 1, lifetime = 7,
		transparency = 0.5, lightEmission = 0.4, acceleration = Vector3.new(0.4, 0.25, 0) },
	TralalaTown = { color = Color3.fromRGB(200, 200, 210), size = 0.3, rate = 10, speed = 0.8, lifetime = 8,
		transparency = 0.7, lightEmission = 0.1, acceleration = Vector3.new(0.3, -0.1, 0.2) },
	BombardiroBay = { color = Color3.fromRGB(230, 205, 150), size = 0.6, rate = 18, speed = 9, lifetime = 3,
		transparency = 0.75, lightEmission = 0, acceleration = Vector3.new(8, 0, 2) },
	RotRidge = { color = Color3.fromRGB(180, 195, 215), size = 7, rate = 3, speed = 0.6, lifetime = 9,
		transparency = 0.88, lightEmission = 0.05, acceleration = Vector3.new(0.5, 0.05, 0) },
	PatapimPlains = { color = Color3.fromRGB(220, 255, 120), size = 0.28, rate = 9, speed = 1.2, lifetime = 5,
		transparency = 0.1, lightEmission = 1, acceleration = Vector3.new(0, 0.2, 0) },
}

MapData.Lighting = {
	-- Clear midday over the grass.
	SahurSprings = { clockTime = 13.5, brightness = 2.2, ambient = Color3.fromRGB(72, 76, 70), outdoorAmbient = Color3.fromRGB(134, 138, 128) },
	-- Golden hour between the tall blocks, long shadows down the streets.
	TralalaTown = { clockTime = 17.4, brightness = 2.6, ambient = Color3.fromRGB(78, 64, 60), outdoorAmbient = Color3.fromRGB(150, 118, 96) },
	-- Harsh noon on the sand.
	BombardiroBay = { clockTime = 12.3, brightness = 2.8, ambient = Color3.fromRGB(84, 84, 80), outdoorAmbient = Color3.fromRGB(150, 146, 136) },
	-- Cold dawn in the highlands.
	RotRidge = { clockTime = 6.9, brightness = 1.8, ambient = Color3.fromRGB(56, 62, 76), outdoorAmbient = Color3.fromRGB(104, 114, 138) },
	-- Warm late afternoon over the farms.
	PatapimPlains = { clockTime = 16.2, brightness = 2.4, ambient = Color3.fromRGB(80, 74, 60), outdoorAmbient = Color3.fromRGB(148, 134, 108) },
}

for id, map in pairs(MapData.Maps) do
	map.id = id
end

function MapData.Get(id)
	return MapData.Maps[id]
end

function MapData.RandomCandidates(count)
	local pool = table.clone(MapData.Order)
	for index = #pool, 2, -1 do
		local swap = math.random(1, index)
		pool[index], pool[swap] = pool[swap], pool[index]
	end

	local picked = {}
	for index = 1, math.min(count, #pool) do
		table.insert(picked, pool[index])
	end
	return picked
end

return MapData
