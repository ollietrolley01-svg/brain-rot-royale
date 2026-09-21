-- Portable defenses: the Rot Barricade, Pop-up Bunker and Brainrot Fortress (ItemData, kind
-- "defense"). Holding one and clicking throws the kit along your aim in an arc; wherever it
-- lands, the structure pops up out of the ground over half a second, its front facing the way
-- you were looking when you threw it, with its own health bar. Gunfire and explosions wear it down
-- (CombatService calls in here), and at zero it collapses — every part unanchored, tumbling,
-- gone a few seconds later.
--
-- The landing spot is checked before anything is built: there has to be ground under the whole
-- footprint, it can't be too steep, and nothing solid (walls, players, another fort) may already
-- be in the box. If it can't go up there, the kit lies where it landed as a pickup, so a bad
-- throw costs a walk rather than the item. Each player keeps at most MAX_PER_PLAYER standing;
-- building past that knocks their oldest down. Everything is cleared with the match.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
-- The placement rules, shared with the client's translucent preview (StarterPlayerScripts/DefensePreview).
local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))
local HazardService = require(script.Parent:WaitForChild("HazardService"))
local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local LootService = require(script.Parent:WaitForChild("LootService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local DefenseService = {}

local MAX_PER_PLAYER = 3
local RISE_TIME = 0.6
local COLLAPSE_LINGER = 3.5
-- How long a kit may fly or roll before it builds where it is. The steepest site allowed and how far a
-- kit can be thrown are DefensePlacement.MaxSlope and DefensePlacement.ThrowRange.
local THROW_TIMEOUT = 4

local buildFx = Remotes.Event("PlaygroundFx")

local IRON = Color3.fromRGB(58, 60, 68)
local STEEL = Color3.fromRGB(160, 164, 172)
local CONCRETE = Color3.fromRGB(140, 140, 136)
local SAND = Color3.fromRGB(206, 182, 138)
local STONE = Color3.fromRGB(176, 168, 150)

local folder = nil
-- model -> { owner, health, max, fill, spec }
local structures = {}
-- player -> { model, ... } oldest first
local owned = {}

local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = "Defenses"
	folder.Parent = workspace
	return folder
end

--------------------------------------------------------------------------------
-- Builders. `origin` sits on the ground at the structure's centre with -Z pointing the way the
-- thrower was looking, so a barricade's front faces the enemy and a bunker's door faces its owner.
--------------------------------------------------------------------------------

local function piece(model, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function decor(part)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	return part
end

local function buildBarricade(model, origin, color)
	-- Two posts and a top rail, four rows of sandbags between them, a neon strip on the rail.
	-- The posts run into the ground rather than starting at the sandbags' own base plane, and the
	-- rail runs past them rather than ending exactly level with their outsides: both were flush,
	-- and the z-fight pass had to pull them apart on every deploy.
	for _, x in ipairs({ -5.75, 5.75 }) do
		piece(model, Vector3.new(0.5, 7.2, 0.5), origin * CFrame.new(x, 3.4, 0), IRON, Enum.Material.Metal)
	end
	piece(model, Vector3.new(12.4, 0.4, 0.7), origin * CFrame.new(0, 7.1, 0), IRON, Enum.Material.Metal)
	decor(piece(model, Vector3.new(12, 0.12, 0.2), origin * CFrame.new(0, 7.35, 0), color, Enum.Material.Neon))
	for row = 0, 3 do
		local offset = row % 2 == 0 and 0 or 1.05
		for index = 0, 5 do
			local x = -5.25 + index * 2.1 + offset
			if math.abs(x) <= 5.4 then
				local bag = piece(model, Vector3.new(2.05, 1.7, 1.5), origin * CFrame.new(x, 0.85 + row * 1.7, 0),
					(row + index) % 3 == 0 and SAND:Lerp(color, 0.35) or SAND, Enum.Material.Fabric)
				bag.TopSurface = Enum.SurfaceType.Smooth
			end
		end
	end
end

local function buildBunker(model, origin, color)
	local wall = Enum.Material.Concrete
	-- Every piece stands ON the pad rather than starting at its underside, and the front and back
	-- walls span BETWEEN the side walls rather than through them. Built the other way — everything
	-- sharing y = 0 and the pad's own +-7 edges, with the walls overlapping in all four corners —
	-- fifty pairs of faces lay in the same planes, and DefenseService's z-fight pass reshaped the
	-- bunker on every single deploy.
	piece(model, Vector3.new(14.4, 0.4, 14.4), origin * CFrame.new(0, 0.2, 0), IRON, Enum.Material.DiamondPlate)
	-- Side walls.
	for _, x in ipairs({ -6.6, 6.6 }) do
		piece(model, Vector3.new(0.8, 7.1, 14), origin * CFrame.new(x, 3.95, 0), CONCRETE, wall)
	end
	-- Front: a parapet to shoot over, a header above the slot.
	piece(model, Vector3.new(12.4, 3.1, 0.8), origin * CFrame.new(0, 1.95, -6.6), CONCRETE, wall)
	piece(model, Vector3.new(12.4, 2, 0.8), origin * CFrame.new(0, 6.5, -6.6), CONCRETE, wall)
	-- Back: a doorway between two segments.
	for _, x in ipairs({ -4.35, 4.35 }) do
		piece(model, Vector3.new(3.7, 7.1, 0.8), origin * CFrame.new(x, 3.95, 6.6), CONCRETE, wall)
	end
	piece(model, Vector3.new(5, 1.5, 0.8), origin * CFrame.new(0, 6.75, 6.6), CONCRETE, wall)
	-- Roof and corner posts. The posts run down INTO the pad, so their undersides aren't in its
	-- plane or the walls'.
	piece(model, Vector3.new(14.6, 0.6, 14.6), origin * CFrame.new(0, 7.8, 0), Color3.fromRGB(96, 96, 100), wall)
	for _, x in ipairs({ -7, 7 }) do
		for _, z in ipairs({ -7, 7 }) do
			piece(model, Vector3.new(1, 8.2, 1), origin * CFrame.new(x, 4.3, z), IRON, Enum.Material.Metal)
		end
	end
	decor(piece(model, Vector3.new(14.8, 0.15, 14.8), origin * CFrame.new(0, 8.15, 0), color, Enum.Material.Neon))
	-- Sandbags along the parapet's outside and a crate to stand on inside.
	for index = 0, 5 do
		-- Their undersides 0.07 above the pad's, not in it.
		decor(piece(model, Vector3.new(2.05, 1.2, 1.2), origin * CFrame.new(-5.25 + index * 2.1, 0.67, -7.6), SAND, Enum.Material.Fabric))
	end
	piece(model, Vector3.new(3, 1.6, 3), origin * CFrame.new(-4.5, 1.2, -4), Color3.fromRGB(150, 108, 62), Enum.Material.WoodPlanks)
end

local function buildFortress(model, origin, color)
	local wall = Enum.Material.Cobblestone
	piece(model, Vector3.new(20, 0.5, 20), origin * CFrame.new(0, 0.25, 0), Color3.fromRGB(96, 96, 100), Enum.Material.Concrete)

	-- Everything stands ON the pad, and the front and back walls span BETWEEN the side walls rather
	-- than through them. Built the other way — every wall 20 long at +-9.5, so all four overlapped in
	-- all four corners, and every piece starting at the pad's own underside — eighty-six pairs of
	-- faces lay in the same planes and the z-fight pass reshaped the whole fort on every deploy.
	-- The footprint is unchanged at 20 x 20 (DefensePlacement.Sizes, which the client's preview
	-- checks): the walls moved IN to 9.4 rather than the pad growing.
	local SIDE = 9.4

	-- Ground floor: each side is a low band, an upper band, and pillars between three windows.
	local function windowedWall(frame, span, pillars)
		piece(model, Vector3.new(span, 3, 1), frame * CFrame.new(0, 2, 0), STONE, wall)
		piece(model, Vector3.new(span, 2, 1), frame * CFrame.new(0, 7, 0), STONE, wall)
		for _, x in ipairs(pillars) do
			piece(model, Vector3.new(2, 2.5, 1), frame * CFrame.new(x, 4.75, 0), STONE, wall)
		end
	end
	windowedWall(origin * CFrame.new(0, 0, -SIDE), 17.8, { -7.9, -3.75, 3.75, 7.9 })
	windowedWall(origin * CFrame.new(SIDE, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), 19.8, { -8.9, -3.75, 3.75, 8.9 })
	windowedWall(origin * CFrame.new(-SIDE, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), 19.8, { -8.9, -3.75, 3.75, 8.9 })
	-- Back wall with the door, between the side walls.
	for _, x in ipairs({ -5.95, 5.95 }) do
		piece(model, Vector3.new(5.9, 7.5, 1), origin * CFrame.new(x, 4.25, SIDE), STONE, wall)
	end
	piece(model, Vector3.new(6, 2, 1), origin * CFrame.new(0, 7, SIDE), STONE, wall)

	-- Second floor with a hatch and a truss up through it, fitted inside the walls. The hatch is
	-- 5.8 x 3.8 with the truss against its +X edge, so the face a climber is on (-X) has 3.8 studs
	-- of clear opening in front of it: a body on a truss stands about a stud off the rungs, and the
	-- old 3.8 x 3.8 hatch with the truss in its middle left 0.9 either side, which the floor edge
	-- stopped at the top every time ("the roof is inaccessible", Oliver, 2026-09-18).
	for _, x in ipairs({ -5.9, 5.9 }) do
		piece(model, Vector3.new(6, 0.6, 17.8), origin * CFrame.new(x, 8.3, 0), Color3.fromRGB(120, 86, 52), Enum.Material.WoodPlanks)
	end
	for _, z in ipairs({ -5.4, 5.4 }) do
		piece(model, Vector3.new(5.8, 0.6, 7), origin * CFrame.new(0, 8.3, z), Color3.fromRGB(120, 86, 52), Enum.Material.WoodPlanks)
	end
	local truss = Instance.new("TrussPart")
	truss.Size = Vector3.new(2, 8, 2)
	truss.CFrame = origin * CFrame.new(1.9, 4.5, 0)
	truss.Anchored = true
	truss.Color = IRON
	truss.Material = Enum.Material.Metal
	truss.Parent = model

	-- Battlements round the roof: a low wall and merlons. The sides run the full depth and the
	-- front and back sit between them, the same way the walls below do.
	for _, side in ipairs({
		{ CFrame.new(0, 0, -SIDE), 17.8, -7.25, 6 },
		{ CFrame.new(0, 0, SIDE), 17.8, -7.25, 6 },
		{ CFrame.new(-SIDE, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), 19.8, -8.7, 7 },
		{ CFrame.new(SIDE, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), 19.8, -8.7, 7 },
	}) do
		local frame = origin * side[1]
		piece(model, Vector3.new(side[2], 1.6, 1), frame * CFrame.new(0, 9.4, 0), STONE, wall)
		for index = 0, side[4] - 1 do
			piece(model, Vector3.new(1.6, 1.4, 1), frame * CFrame.new(side[3] + index * 2.9, 10.9, 0), STONE, wall)
		end
	end
	-- Corner towers, running down into the pad so their undersides aren't in its plane.
	for _, x in ipairs({ -SIDE, SIDE }) do
		for _, z in ipairs({ -SIDE, SIDE }) do
			piece(model, Vector3.new(1.4, 12, 1.4), origin * CFrame.new(x, 6.2, z), Color3.fromRGB(132, 126, 112), wall)
		end
	end
	-- Gold trim and a banner. The trim is a rim: four strips round the OUTSIDE of the battlement
	-- walls at the second-floor line, running between the corner towers. It used to be one 20.4 x
	-- 20.4 neon slab over the whole floor, which from the roof was a solid yellow square and from
	-- below a yellow plug in the hatch: passable (decor) but no visible way up or down. The strips
	-- share no plane with anything: outside the walls' outer face (9.9), under the battlements, ending
	-- on the towers' inner faces.
	for _, z in ipairs({ -10.15, 10.15 }) do
		decor(piece(model, Vector3.new(17.4, 0.15, 0.5), origin * CFrame.new(0, 8.445, z), color, Enum.Material.Neon))
	end
	for _, x in ipairs({ -10.15, 10.15 }) do
		decor(piece(model, Vector3.new(0.5, 0.15, 17.4), origin * CFrame.new(x, 8.445, 0), color, Enum.Material.Neon))
	end
	decor(piece(model, Vector3.new(0.3, 7, 0.3), origin * CFrame.new(9, 15, -9), IRON, Enum.Material.Metal))
	decor(piece(model, Vector3.new(0.1, 2.2, 3.2), origin * CFrame.new(9, 17.2, -7.4), color, Enum.Material.Fabric))
end

-- Sizes live in DefensePlacement, so the client's preview checks the same box.
local STRUCTURES = {
	RotBarricade = { health = 250, size = DefensePlacement.Sizes.RotBarricade, build = buildBarricade },
	PopupBunker = { health = 1250, size = DefensePlacement.Sizes.PopupBunker, build = buildBunker },
	BrainrotFortress = { health = 2500, size = DefensePlacement.Sizes.BrainrotFortress, build = buildFortress },
}

-- Defense items that are thrown the same way but arm a hazard where they land instead of
-- building anything (HazardService owns them from there).
local MINES = { RotMine = true }

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

-- The site rules (and the ground raycast's filter) live in Shared/DefensePlacement, moved there
-- unchanged, so the client's preview runs the very same checks. Built defenses in this module's folder
-- never count as ground.

-- Whether a structure can stand centred on `centre` with its front toward `flat` (a unit
-- direction on the ground plane): the ground-level origin to build at, or nil and why not.
local function findSite(character, spec, centre, flat)
	return DefensePlacement.FindSite(character, spec.size, centre, flat, ensureFolder())
end

--------------------------------------------------------------------------------
-- Health, damage and collapse
--------------------------------------------------------------------------------

local function collapse(model)
	local entry = structures[model]
	structures[model] = nil
	if entry and entry.owner then
		local mine = owned[entry.owner]
		if mine then
			local index = table.find(mine, model)
			if index then
				table.remove(mine, index)
			end
		end
	end
	if not model.Parent then
		return
	end
	local core = model.PrimaryPart
	if core then
		local gui = core:FindFirstChildOfClass("BillboardGui")
		if gui then
			gui:Destroy()
		end
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = false
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.AssemblyLinearVelocity = Vector3.new(math.random(-8, 8), math.random(6, 14), math.random(-8, 8))
			part.AssemblyAngularVelocity = Vector3.new(math.random(-4, 4), math.random(-4, 4), math.random(-4, 4))
		end
	end
	Debris:AddItem(model, COLLAPSE_LINGER)
end

local function buildHealthBar(core, name, color, maxHealth)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(8, 1.5)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2, 0)
	gui.MaxDistance = 140
	gui.LightInfluence = 0

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.55)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = name
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.4
	label.TextScaled = true
	label.Parent = gui
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 20
	cap.Parent = label

	local back = Instance.new("Frame")
	back.Position = UDim2.fromScale(0.1, 0.62)
	back.Size = UDim2.fromScale(0.8, 0.22)
	back.BackgroundColor3 = Color3.fromRGB(26, 28, 36)
	back.BackgroundTransparency = 0.25
	back.BorderSizePixel = 0
	back.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = back

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = color
	fill.BorderSizePixel = 0
	fill.Parent = back
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = fill

	gui.Parent = core
	return fill
end

-- The structure a hit part belongs to, or nil.
function DefenseService.StructureFromPart(part)
	local model = part and part:FindFirstAncestorOfClass("Model")
	return model and structures[model] and model or nil
end

-- Returns the damage actually taken.
function DefenseService.Damage(model, amount)
	local entry = structures[model]
	if not entry or amount <= 0 then
		return 0
	end
	local dealt = math.min(entry.health, amount)
	entry.health -= dealt
	model:SetAttribute("Health", math.ceil(entry.health))
	if entry.fill then
		entry.fill.Size = UDim2.fromScale(math.clamp(entry.health / entry.max, 0, 1), 1)
	end
	-- Half gone: it starts to look it.
	if entry.health <= entry.max * 0.5 and not entry.battered then
		entry.battered = true
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") and part.Material ~= Enum.Material.Neon then
				part.Color = part.Color:Lerp(Color3.new(0, 0, 0), 0.3)
			end
		end
	end
	if entry.health <= 0 then
		collapse(model)
	end
	return dealt
end

function DefenseService.DamageInRadius(position, radius, amount)
	for model in pairs(structures) do
		local core = model.PrimaryPart
		if core and (core.Position - position).Magnitude <= radius + 6 then
			DefenseService.Damage(model, amount)
		end
	end
end

--------------------------------------------------------------------------------
-- Deploying
--------------------------------------------------------------------------------

-- Builds a structure at `origin` (a ground-level CFrame, -Z its front) for `owner` (a Player, or
-- Who deployed a structure (the owner token given to Build), or nil for one nobody owns or a model
-- that isn't a defense. BotService asks so a bot never shoots through its own side's barricade.
function DefenseService.OwnerOf(model)
	local entry = structures[model]
	return entry and entry.owner or nil
end

-- nil for one nobody owns) and returns the model. Deploying goes through here after the
-- placement checks; it's also how anything else can put a defense in the world.
function DefenseService.Build(itemId, origin, owner)
	local spec = STRUCTURES[itemId]
	local item = ItemData.Get(itemId)
	if not spec or not item then
		return nil
	end

	local model = Instance.new("Model")
	model.Name = itemId
	if owner and owner.UserId then
		model:SetAttribute("OwnerUserId", owner.UserId)
	end
	model:SetAttribute("MaxHealth", spec.health)
	model:SetAttribute("Health", spec.health)
	spec.build(model, origin, item.color)
	-- Before the rise tween takes its targets: no two faces left flush.
	ZFight.Fix({ model }, { all = true })

	-- An invisible core at the top carries the health bar and marks the centre for splash checks.
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Size = Vector3.new(1, 1, 1)
	core.Transparency = 1
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.CFrame = origin * CFrame.new(0, spec.size.Y + 0.5, 0)
	core.Parent = model
	model.PrimaryPart = core
	local fill = buildHealthBar(core, item.name, item.color, spec.health)

	-- Rise out of the ground.
	local info = TweenInfo.new(RISE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part ~= core then
			local final = part.CFrame
			part.CFrame = final - Vector3.new(0, spec.size.Y, 0)
			TweenService:Create(part, info, { CFrame = final }):Play()
		end
	end

	model.Parent = ensureFolder()
	structures[model] = { owner = owner, health = spec.health, max = spec.health, fill = fill, spec = spec }
	return model
end

-- Puts a structure up for `owner` — a Player, or a bot (BotService throws barricades up under
-- fire) — centred on `centre` with its front toward `facing`, if the site allows. Returns the
-- model, or nil and the reason. `character` is left out of the site checks so the owner's own
-- body can't block the build. Past MAX_PER_PLAYER, the owner's oldest comes down first.
function DefenseService.Deploy(owner, character, itemId, centre, facing)
	local spec = STRUCTURES[itemId]
	local item = ItemData.Get(itemId)
	if not spec or not item then
		return nil, "Unknown defense."
	end
	local origin, reason = findSite(character, spec, centre, facing)
	if not origin then
		return nil, reason
	end

	local mine = owned[owner]
	if not mine then
		mine = {}
		owned[owner] = mine
	end
	while #mine >= MAX_PER_PLAYER do
		collapse(mine[1])
	end

	local model = DefenseService.Build(itemId, origin, owner)
	if not model then
		return nil, "Couldn't build that."
	end
	table.insert(mine, model)
	buildFx:FireAllClients({ kind = "build", position = origin.Position + Vector3.new(0, 3, 0), color = item.color })
	return model
end

-- The kit has landed: build there, facing the way the thrower was looking, or leave it lying as
-- a pickup.
local function landKit(player, itemId, landed, facing)
	if MINES[itemId] then
		-- A mine arms wherever it stops; there's no site to find.
		local mine = HazardService.Mine(ensureFolder(), landed, player)
		if not mine then
			LootService.DropItem(itemId, landed, 1)
			return
		end
		local item = ItemData.Get(itemId)
		buildFx:FireAllClients({ kind = "mine", position = mine:GetPivot().Position, color = item and item.color or nil })
		QuestService.Progress(player, "builds", 1)
		return
	end

	local model, reason = DefenseService.Deploy(player, player.Character, itemId, landed + Vector3.new(0, 1, 0), facing)
	if not model then
		LootService.DropItem(itemId, landed, 1)
		StateSync.Notify(player, (reason or "No room to build there.") .. "  The kit's on the ground where it landed.", true)
		return
	end
	QuestService.Progress(player, "builds", 1)
end

-- The click: throw the kit along the aim in an arc and watch it until it comes to rest. Spending
-- the item happens on the throw (WeaponService), so a bad landing drops it back as a pickup.
local function throwKit(player, itemId, aimPoint)
	local spec = STRUCTURES[itemId]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not (spec or MINES[itemId]) or not root then
		return false
	end
	local head = character:FindFirstChild("Head") or root
	local look = root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)

	local from = head.Position + flatLook * 2 + Vector3.new(0, 0.5, 0)
	-- A client's aim can be NaN or infinite in any component, and either would become a NaN velocity
	-- on a server-owned physics body below; anything but a sane point throws straight ahead instead.
	-- Guarded here rather than only at the remote, so every caller is covered.
	local target = SafeValue.Vector3(aimPoint) and aimPoint or (from + look * 30)
	-- Clamped to the throw range, facing the way you're looking, and lobbed to land on the aim point:
	-- all of it in DefensePlacement, so the client's preview can walk the very same arc to show where
	-- the kit will really arrive (it is thrown flat enough to clip a hill on the way).
	local velocity, _flightTime, _target, facing = DefensePlacement.ThrowArc(from, look, target)

	local kit, body = ItemModels.Build(itemId, { anchored = false, scale = 1.5, name = itemId .. "Kit" })
	if not kit then
		return false
	end
	kit:PivotTo(CFrame.new(from) * root.CFrame.Rotation)
	body.CanCollide = true
	body.CanQuery = false
	body.Massless = false
	kit.Parent = ensureFolder()
	pcall(function()
		body:SetNetworkOwner(nil)
	end)
	body.AssemblyLinearVelocity = velocity
	body.AssemblyAngularVelocity = Vector3.new(math.random(-6, 6), math.random(-6, 6), math.random(-6, 6))

	task.spawn(function()
		local started = os.clock()
		repeat
			task.wait(0.1)
			local flying = os.clock() - started
		until not body.Parent or (flying > 0.4 and body.AssemblyLinearVelocity.Magnitude < 3) or flying > THROW_TIMEOUT
		if not body.Parent then
			return
		end
		local landed = body.Position
		kit:Destroy()
		if not player.Parent then
			LootService.DropItem(itemId, landed, 1)
			return
		end
		landKit(player, itemId, landed, facing)
	end)
	return true
end

function DefenseService.Clear()
	structures = {}
	owned = {}
	if folder then
		folder:Destroy()
		folder = nil
	end
end

-- Hooks: the use flow throws through here, and combat wears structures down through here.
WeaponService.DefenseEffect = function(player, itemId, aimPoint)
	return throwKit(player, itemId, aimPoint)
end

CombatService.StructureFromPart = DefenseService.StructureFromPart
CombatService.DamageStructure = function(shooterToken, model, amount)
	local dealt = DefenseService.Damage(model, amount)
	local core = model.PrimaryPart
	CombatService.ConfirmHit(shooterToken, dealt, false, core and core.Position or nil, "structure")
	return dealt
end
CombatService.DamageStructuresInRadius = DefenseService.DamageInRadius

Players.PlayerRemoving:Connect(function(player)
	owned[player] = nil
end)

-- Inert copies of each structure for the client's placement preview (StarterPlayerScripts/DefensePreview),
-- so the ghost a player sees is exactly what goes up. Each is built by the real builder at the origin,
-- with the same z-fight pass Build runs, straight into ReplicatedStorage.DefenseTemplates: never in the
-- workspace, never in `structures` or `owned`, no health bar, and nothing in it can collide, be queried or
-- be touched. Anything else a builder might add (a script, a prompt, a GUI) is stripped. Runs once; a
-- second call leaves the published copies as they are.
function DefenseService.PublishTemplates()
	if ReplicatedStorage:FindFirstChild("DefenseTemplates") then
		return ReplicatedStorage.DefenseTemplates
	end
	local templates = Instance.new("Folder")
	templates.Name = "DefenseTemplates"
	for itemId, spec in pairs(STRUCTURES) do
		local item = ItemData.Get(itemId)
		local model = Instance.new("Model")
		model.Name = itemId
		spec.build(model, CFrame.new(), item and item.color or Color3.new(1, 1, 1))
		ZFight.Fix({ model }, { all = true })
		for _, descendant in ipairs(model:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			elseif descendant:IsA("LuaSourceContainer") or descendant:IsA("ProximityPrompt") or descendant:IsA("GuiBase")
				or descendant:IsA("ClickDetector") or descendant:IsA("Light") or descendant:IsA("ParticleEmitter") then
				descendant:Destroy()
			end
		end
		model:SetAttribute("Size", spec.size)
		model.Parent = templates
	end
	templates.Parent = ReplicatedStorage
	return templates
end

-- Published as the server starts. Edit-mode tools that require this module publish them themselves.
if game:GetService("RunService"):IsRunning() then
	task.defer(DefenseService.PublishTemplates)
end

-- A barricade, bunker or fortress deployed on a floor or roof that then breaks: it goes down onto
-- whatever is under it rather than hanging in the air (DestructibleService.OnPartBroken).
DestructibleService.OnPartBroken(function(cframe, size)
	local models = {}
	for model in pairs(structures) do
		table.insert(models, model)
	end
	local resting = DestructibleService.RestingOn(cframe, size, models)
	if #resting == 0 then
		return
	end
	task.defer(function()
		for _, model in ipairs(resting) do
			if structures[model] then
				DestructibleService.SettleDown(model)
			end
		end
	end)
end)

return DefenseService
