-- Wall fade repro (Oliver 2026-09-24: "make walls not slowly turn clear before they break"), for
-- tools/runtest.ps1 -Probe (edit mode):
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/wall_fade_probe.lua -PlaceFile <copy of the build>
--
-- Builds a real-shaped building wall per material (a "Wall" in Map/Town/House, 24 x 12 x 1, so the
-- first hit cuts it into tiles exactly as in a match, with a Texture on it like the town's walls),
-- damages it through the REAL DestructibleService to 20%, 50% and 80% of its health (bullet-sized
-- hits at spread points), and lets the REAL CrackFxClient draw it with its own Heartbeat running
-- (animations, flicker, LOD) with the camera 20 studs out. At each step it reads, for the hit tile
-- and every overlay piece on it:
--
--   host    Transparency, LocalTransparencyModifier, and each Texture/Decal child's Transparency
--   overlay pieces over the host's face whose Transparency > 0 or whose material is see-through
--           (Glass, ForceField), with the share of the face they cover
--
-- (Pieces fully clear, Transparency 1, are not drawn at all and are left out.)
-- One summary line per material and step; FADE lines name whatever lost opacity. Want 0 FADE.
-- Also prints the shots to break that tile for a rifle round (18, 27) and a rocket (150 in reach).

local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local RunService = game:GetService("RunService")
local modules = ServerScriptService:WaitForChild("Modules")

local function out(fmt, ...)
	print("[AUDIT wallfade] " .. string.format(fmt, ...))
end

local DS = require(modules:WaitForChild("DestructibleService"))

local state = {}
local function loadClient(name, remote, export)
	local script = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild(name)
	local source = script.Source
	source = source:gsub('Remotes%.Event%("' .. remote .. '"%)', "__remote")
	source = source:gsub('require%(script%.Parent:WaitForChild%("Sfx"%)%)', "{ PlayAt = function() end }")
	if export then
		source ..= "\n" .. export .. "\n"
	end
	local fn, err = loadstring(source, name)
	assert(fn, err)
	local bindable = Instance.new("BindableEvent")
	local env = setmetatable({
		script = script,
		-- Edit mode's time() stands still; the client's animations run on it.
		time = function()
			return os.clock()
		end,
		__remote = { OnClientEvent = bindable.Event },
		__export = function(api)
			state[name] = api
		end,
	}, { __index = getfenv() })
	setfenv(fn, env)
	task.spawn(fn)
	return function(...)
		bindable:Fire(...)
	end
end
loadClient("CrackFxClient", "DamageFx", "__export({ track = track, refresh = refresh, build = build, tracked = tracked, totals = totals })")
local crack = state.CrackFxClient
assert(crack, "CrackFxClient did not export")

local M = Enum.Material
local MATERIALS = {
	{ M.Glass, Color3.fromRGB(170, 205, 225) }, { M.Fabric, Color3.fromRGB(62, 92, 162) },
	{ M.WoodPlanks, Color3.fromRGB(162, 122, 82) }, { M.Plaster, Color3.fromRGB(230, 222, 204) },
	{ M.SmoothPlastic, Color3.fromRGB(205, 62, 52) }, { M.Brick, Color3.fromRGB(152, 84, 62) },
	{ M.Cobblestone, Color3.fromRGB(150, 146, 140) }, { M.Concrete, Color3.fromRGB(165, 162, 154) },
	{ M.Metal, Color3.fromRGB(122, 128, 134) }, { M.DiamondPlate, Color3.fromRGB(140, 144, 150) },
	{ M.Neon, Color3.fromRGB(90, 220, 255) },
}
local STEPS = { 0.2, 0.5, 0.8 }
local SEE_THROUGH = { [M.Glass] = true, [M.ForceField] = true }

local map = workspace:FindFirstChild("Map") or Instance.new("Folder")
map.Name = "Map"
map.Parent = workspace
local town = Instance.new("Folder")
town.Name = "Town"
town.Parent = map
local camera = workspace.CurrentCamera

local function faceShare(host, piece)
	-- The share of the host's front face (-Z) a piece covers, if it lies on that face.
	local l = host.CFrame:PointToObjectSpace(piece.Position)
	if math.abs(math.abs(l.Z) - host.Size.Z / 2) > 0.6 then
		return 0
	end
	local s = piece.Size
	local area = math.max(s.X * s.Y, s.X * s.Z, s.Y * s.Z)
	return area / (host.Size.X * host.Size.Y)
end

local function readHost(host)
	local worst = math.max(host.Transparency, host.LocalTransparencyModifier)
	for _, child in ipairs(host:GetChildren()) do
		if child:IsA("Texture") or child:IsA("Decal") then
			worst = math.max(worst, child.Transparency, child.LocalTransparencyModifier)
		end
	end
	return worst
end

local fadeLines, total = 0, 0
for index, entry in ipairs(MATERIALS) do
	local material, color = entry[1], entry[2]
	local house = Instance.new("Model")
	house.Name = "House"
	house.Parent = town
	local wall = Instance.new("Part")
	wall.Name = "Wall"
	wall.Anchored = true
	wall.Material = material
	wall.Color = color
	wall.Size = Vector3.new(24, 12, 1)
	wall.CFrame = CFrame.new((index - 1) * 30, 300, 0)
	local texture = Instance.new("Texture")
	texture.Face = Enum.NormalId.Front
	texture.Texture = "rbxassetid://6372755229"
	texture.Parent = wall
	wall.Parent = house
	local baseT = wall.Transparency
	local tiles = DS.Subdivide(wall) or { wall }
	local host = tiles[math.ceil(#tiles / 2)]
	local startOpacity = readHost(host)
	camera.CFrame = CFrame.lookAt(host.Position + Vector3.new(0, 0, -20), host.Position)
	-- The first hit sizes the pool.
	local front = host.CFrame * Vector3.new(0, 0, -host.Size.Z / 2)
	DS.Damage(host, 1, nil, front + Vector3.new(0, 0, -30), front, Vector3.new(0, 0, -1))
	local health, max = DS.HealthOf(host)
	local line = {}
	local dealtSoFar = 1
	for step, fraction in ipairs(STEPS) do
		local want = fraction * max
		local spots = { Vector3.new(-1.5, 2, 0), Vector3.new(1.8, -1.5, 0), Vector3.new(0.3, 0.4, 0), Vector3.new(-2.5, -3, 0) }
		local hits = 6
		for h = 1, hits do
			local amount = (want - dealtSoFar) / (hits - h + 1)
			if amount > 0 then
				local at = host.CFrame * (spots[(h + step) % #spots + 1] + Vector3.new(0, 0, -host.Size.Z / 2))
				dealtSoFar += DS.Damage(host, amount, nil, at + Vector3.new(0, 0, -30), at, Vector3.new(0, 0, -1))
			end
		end
		-- Let the server's hit flush run, then the client draw and animate for a second and a half.
		task.wait()
		task.wait()
		local record = crack.track(host)
		if record then
			crack.refresh(host, record)
		end
		local t0 = os.clock()
		local hostOpacityLoss = 0
		while os.clock() - t0 < 1.5 do
			RunService.Heartbeat:Wait()
			hostOpacityLoss = math.max(hostOpacityLoss, readHost(host) - startOpacity)
		end
		local clearShare, clearCount, pieces, worstPiece = 0, 0, 0, ""
		local overlay = {}
		for _, folderName in ipairs({ "CrackFx", "BreakFx" }) do
			local folder = workspace:FindFirstChild(folderName)
			for _, piece in ipairs(folder and folder:GetDescendants() or {}) do
				-- (Flying bits and dust holders are debris in the air, not marks on the face.)
				if piece:IsA("BasePart") and piece.Transparency < 1 - 1e-3 and piece.Name ~= "CrackBit" and piece.Name ~= "CrackPuff" then
					table.insert(overlay, piece)
				end
			end
		end
		for _, piece in ipairs(overlay) do
			if piece.Parent then
				pieces += 1
				local seeThrough = piece.Transparency > 0.01 or SEE_THROUGH[piece.Material]
				local share = faceShare(host, piece)
				if seeThrough and share > 0 then
					clearCount += 1
					clearShare += share
					if worstPiece == "" or share > 0.02 then
						worstPiece = string.format("%s T%.2f %s %.0f%%", piece.Name, piece.Transparency, piece.Material.Name, share * 100)
					end
				end
			end
		end
		total += 1
		-- A see-through wall (glass) may carry see-through marks; its own opacity must still hold.
		local clearHost = material == M.Glass or material == M.Ice or material == M.Glacier or material == M.ForceField
		local fade = hostOpacityLoss > 0.001 or host.Transparency ~= baseT or (not clearHost and clearShare > 0.001)
		if fade then
			fadeLines += 1
		end
		table.insert(line, string.format("%d%%: stage %s host dT %.2f, %d pieces, %d see-through over %.0f%% of face%s",
			fraction * 100, tostring(host:GetAttribute("DamageStage")), hostOpacityLoss, pieces, clearCount, clearShare * 100,
			fade and (" FADE [" .. worstPiece .. "]") or ""))
	end
	out("%-13s max %4d | %s", material.Name, max, table.concat(line, " | "))
	-- Shots to break this tile, from its health (a fresh tile of the same wall).
	local rifleA, rifleB = math.ceil(max / 18), math.ceil(max / 27)
	local rocket = DS.StructureBlast and math.ceil(max / (150 * DS.StructureBlast)) or math.ceil(max / 150)
	out("shots %-13s max %4d  carbine(18) %d  rifle(27) %d  rocket(150) %d", material.Name, max, rifleA, rifleB, rocket)
	house:Destroy()
end
out("fade: %d of %d material-steps lost opacity before the break (want 0)", fadeLines, total)
out("done")
