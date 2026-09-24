-- Cracking by material (#71) gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crack_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- One row per material family (wood, stone, brick, metal, glass, foliage, plastic, cloth), six panels
-- each: 100% (untouched), 90% (the first hits: stage 0), 75%, 50%, 25%, and breaking (the debris
-- mid-flight, stepped by hand: edit mode runs no physics). Every panel is damaged through the REAL
-- DestructibleService (three hits at spread points on its front face, from a shooter 30 studs out),
-- and drawn by the REAL CrackFxClient and BreakFxClient, loaded here with local stand-ins for their
-- remotes. Views: an overview, then each row close up, then one frame of the hit bursts.
--
-- Notes (measurements, not pictures): per panel the DamageStage and DamageSites the server wrote,
-- the pieces drawn, and the part's Transparency before and after (must be equal: #71, never fade).
--
-- What to look at: cracks that read as cracks at play distance and aren't stickers; stone branching
-- and chipped, a crater at 25%; brick stepping along its courses (do they line up with the Brick
-- texture? BRICK_W/BRICK_H in CrackFxClient if not); wood split along the grain with splinters and a
-- loose board; metal dented ring by ring, scratched bright, a corner peeled; glass webbed; foliage
-- with drooping twigs and browned; plastic whitened; cloth torn with a flap. Nothing see-through.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")
local modules = ServerScriptService:WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local state = {}

local function service()
	state.ds = state.ds or require(modules:WaitForChild("DestructibleService"))
	return state.ds
end

-- A client script's source run here with its remote swapped for a local event and its sounds muted;
-- `export` (optional) is appended so the gallery can reach its functions.
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

local function crackFx()
	if not state.crackLoaded then
		state.crackLoaded = true
		loadClient("CrackFxClient", "DamageFx",
			"__export({ track = track, refresh = refresh, build = build, tracked = tracked, totals = totals, hitBurst = hitBurst, bits = bits, FACES = FACES })")
	end
	return state.CrackFxClient
end

local function breakFx()
	state.fireBreak = state.fireBreak or loadClient("BreakFxClient", "BreakFx")
	return state.fireBreak
end

-- Edit mode runs no physics: move loose pieces along their velocities by hand, with gravity.
local function stepLoose(folderName, names, seconds)
	local folder = workspace:FindFirstChild(folderName)
	local moved = 0
	local dt = 1 / 60
	for _, piece in ipairs(folder and folder:GetChildren() or {}) do
		if names[piece.Name] then
			moved += 1
			local v, w = piece.AssemblyLinearVelocity, piece.AssemblyAngularVelocity
			piece.Anchored = true
			for _ = 1, math.floor(seconds / dt) do
				v += Vector3.new(0, -workspace.Gravity * dt, 0)
				local turn = w * dt
				piece.CFrame = (piece.CFrame + v * dt) * CFrame.Angles(turn.X, turn.Y, turn.Z)
			end
		end
	end
	return moved
end

local FAMILIES = {
	{ "wood", Enum.Material.WoodPlanks, Color3.fromRGB(162, 122, 82) },
	{ "stone", Enum.Material.Concrete, Color3.fromRGB(165, 162, 154) },
	{ "brick", Enum.Material.Brick, Color3.fromRGB(152, 84, 62) },
	{ "metal", Enum.Material.Metal, Color3.fromRGB(122, 128, 134) },
	{ "glass", Enum.Material.Glass, Color3.fromRGB(170, 205, 225) },
	{ "foliage", Enum.Material.LeafyGrass, Color3.fromRGB(72, 122, 52) },
	{ "plastic", Enum.Material.Plastic, Color3.fromRGB(205, 62, 52) },
	{ "cloth", Enum.Material.Fabric, Color3.fromRGB(62, 92, 162) },
}
local PANELS = { { "100", 1 }, { "90", 0.9 }, { "75", 0.75 }, { "50", 0.5 }, { "25", 0.25 }, { "breaking", 0.25 } }
local HEALTH = 400
local ORIGIN = Vector3.new(0, 200, 0)
local ROW, COLUMN = 12, 11
-- Three hits, spread across the front face (-Z), from a shooter 30 studs out.
local HITS = { Vector3.new(-1.6, 1, 0), Vector3.new(1.8, -0.9, 0), Vector3.new(0.2, 2.1, 0) }

local function panelCFrame(row, column)
	return CFrame.new(ORIGIN + Vector3.new((column - 1) * COLUMN, -(row - 1) * ROW, 0))
end

local function buildScene()
	if state.scene then
		return state.scene
	end
	local ds = service()
	crackFx()
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = workspace
	end
	local holder = Instance.new("Model")
	holder.Name = "CrackGallery"
	holder.Parent = map
	local scene = { rows = {} }
	for row, family in ipairs(FAMILIES) do
		local name, material, color = family[1], family[2], family[3]
		local panels = {}
		for column, panel in ipairs(PANELS) do
			local part = Instance.new("Part")
			part.Name = name .. "_" .. panel[1]
			part.Anchored = true
			part.Material = material
			part.Color = color
			part.Size = name == "foliage" and Vector3.new(8, 7, 5) or (name == "glass" and Vector3.new(8, 7, 0.3) or Vector3.new(8, 7, 1))
			part.CFrame = panelCFrame(row, column)
			if name == "glass" then
				part.Transparency = 0.3
			end
			part:SetAttribute("DestructibleHealth", HEALTH)
			part.Parent = holder
			local before = part.Transparency
			local total = (1 - panel[2]) * HEALTH
			for _, offset in ipairs(HITS) do
				if total > 0 then
					local at = part.CFrame * (offset + Vector3.new(0, 0, -part.Size.Z / 2))
					ds.Damage(part, total / #HITS, nil, at + Vector3.new(0, 0, -30), at, Vector3.new(0, 0, -1))
				end
			end
			table.insert(panels, { part = part, fraction = panel[2], label = panel[1], before = before })
		end
		scene.rows[row] = { name = name, panels = panels }
	end
	-- Let the server's deferred hit flush run (it writes the sites), then draw every panel now.
	task.wait()
	task.wait()
	local crack = crackFx()
	for _, row in ipairs(scene.rows) do
		for _, panel in ipairs(row.panels) do
			local part = panel.part
			local record = crack and crack.track(part)
			if record then
				crack.refresh(part, record)
				if #record.sites > 0 then
					crack.build(part, record)
					record.dirty = false
				end
			end
			panel.pieces = record and #record.pieces or 0
			note(string.format("%s %s%%: stage %s, sites %q, %d pieces, transparency %.2f -> %.2f", row.name, panel.label,
				tostring(part:GetAttribute("DamageStage")), tostring(part:GetAttribute("DamageSites")), panel.pieces, panel.before,
				part.Transparency))
		end
		-- The last panel breaks: what the server would have sent, with its stage, and the debris a
		-- moment into its flight.
		local panel = row.panels[#row.panels]
		local part = panel.part
		local from = part.Position + Vector3.new(0, 0, -30)
		local batch = { { part.CFrame, part.Size, part.Color, part.Material, service().ClassOf(part.Material), from,
			part:GetAttribute("DamageStage") or 0 } }
		service().Damage(part, 1e6, nil, from)
		breakFx()(batch)
	end
	task.wait()
	stepLoose("BreakFx", { BreakPiece = true }, 0.3)
	local cracked = 0
	for _, piece in ipairs(workspace:FindFirstChild("BreakFx") and workspace.BreakFx:GetChildren() or {}) do
		if piece:FindFirstChild("Cracks") then
			cracked += 1
		end
	end
	note(string.format("breaking: %d debris pieces carry cracks; %d crack pieces drawn in all (cap %s)", cracked,
		crack and crack.totals.pieces or -1, "1800"))
	state.scene = scene
	return scene
end

local views = {}

local function add(name, fn, hold)
	table.insert(views, { name = name, settle = 1.4, hold = hold or 2, setup = fn })
end

add("overview", function(_, camera)
	buildScene()
	local centre = ORIGIN + Vector3.new(2.5 * COLUMN, -3.5 * ROW, 0)
	camera.CFrame = CFrame.lookAt(centre + Vector3.new(0, 10, -150), centre)
end)

for row, family in ipairs(FAMILIES) do
	add("row_" .. family[1], function(_, camera)
		buildScene()
		local centre = panelCFrame(row, 3.5).Position
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(6, 6, -46), centre)
	end)
	add("close_" .. family[1] .. "_25", function(_, camera)
		buildScene()
		local centre = panelCFrame(row, 5).Position
		camera.CFrame = CFrame.lookAt(centre + Vector3.new(4, 2, -13), centre)
	end)
end

add("hit_bursts", function(folder, camera)
	buildScene()
	local crack = crackFx()
	if not crack then
		note("hit bursts: CrackFxClient did not load")
		return
	end
	-- One hit on each family's 100% panel, the burst a tenth of a second on.
	for _, row in ipairs(state.scene.rows) do
		local part = row.panels[1].part
		local at = part.CFrame * Vector3.new(0, 0, -part.Size.Z / 2)
		crack.hitBurst(row.name, at, Vector3.new(0, 0, -1), part.Color, part.Material, 1)
	end
	local moved = stepLoose("CrackFx", { CrackBit = true }, 0.1)
	note(string.format("hit bursts: %d bits in flight", moved))
	local centre = ORIGIN + Vector3.new(0, -3.5 * ROW, 0)
	camera.CFrame = CFrame.lookAt(centre + Vector3.new(-30, 8, -70), centre)
end)

return views
