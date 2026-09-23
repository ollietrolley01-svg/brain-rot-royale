-- Loot on the map: chests inside buildings (good guns, heals, movement items), loose weapons,
-- heal pickups and movement items.
--
-- Every pickup is a small real model — the actual gun on a glowing rarity pad, a med kit with
-- its cross, a soda can — resting on an invisible base part. The base carries the name,
-- attributes and prompt that players and bots interact with, and AmbientClient turns the whole
-- model as one piece. Chests have a hinged lid that LootFxClient swings open when claimed.
--
-- Where things go comes from MapGenerator's `lootSpots`: weapons at doorways, porches and
-- street corners, heals indoors, movement items on rooftops and junctions.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local DestructibleService = require(script.Parent:WaitForChild("DestructibleService"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local LootService = {}

-- Guns per chest. MatchService raises it for a Loot Frenzy match.
LootService.ChestGuns = 2
-- When set (an Aura Farm match), every chest's first gun is rerolled until it's at least this
-- rarity.
LootService.ChestRarityFloor = nil

-- This map's landmarks ({ X, Y, Z, name }), so a chest opened inside one counts toward the
-- landmark quests. Set by Populate.
local landmarkSpots = {}
local LANDMARK_REACH = 72

local function nearLandmark(position)
	for _, spot in ipairs(landmarkSpots) do
		if Vector2.new(spot.X - position.X, spot.Z - position.Z).Magnitude <= LANDMARK_REACH then
			return true
		end
	end
	return false
end

local CHEST_FRACTION = 0.55
local WEAPON_FRACTION = 0.75
local HEAL_FRACTION = 0.7
local ITEM_FRACTION = 0.6
local CHEST_ITEM_CHANCE = 0.45
-- Portable defenses: a chest's chance of one, and the share of ground item spots that hold one
-- instead of a movement item.
local CHEST_DEFENSE_CHANCE = 0.2
local GROUND_DEFENSE_SHARE = 0.15
-- Grenades and smoke: a chest's chance of one, and the share of ground item spots that hold one.
local CHEST_THROWABLE_CHANCE = 0.3
local GROUND_THROWABLE_SHARE = 0.22
local OPENED_LINGER = 2.2

-- Fallback for a map that doesn't provide categorised spots.
local GROUND_FRACTION = 0.7
local HEAL_SPOTS = 70
local ITEM_SPOTS = 30

local container = nil
local spinConnection = nil

-- Populate yields between batches; Clear() bumps this so a populate in progress stops rather
-- than spawning on into loot that's already been torn down.
local POPULATE_BATCH = 25
local populateGeneration = 0

local METAL = Color3.fromRGB(60, 58, 56)
local GOLD = Color3.fromRGB(255, 200, 60)

local function ensureContainer()
	if container and container.Parent then
		return container
	end
	container = Instance.new("Folder")
	container.Name = "Loot"
	container.Parent = workspace
	return container
end

local function makePrompt(parent, actionText, objectText)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent

	-- Bots read this so they give way to a player who's already mid-hold, instead of taking
	-- the loot out from under them.
	prompt.PromptButtonHoldBegan:Connect(function()
		parent:SetAttribute("PlayerHolding", true)
	end)
	prompt.PromptButtonHoldEnded:Connect(function()
		parent:SetAttribute("PlayerHolding", false)
	end)

	return prompt
end

-- The name over a pickup. Sized against the pickup, not against the sky: at 7 studs wide it was more
-- than ten times the length of the Pocket Popper it was naming, so from a standing eye the banner was
-- the pickup and the gun was a smudge under it (measured in scratchpad/guns_f0_out/ground2). TextScaled
-- keeps it legible at the smaller size, and it still fades out at MaxDistance the way it always did.
local function label(parent, text, color, height)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(3.2, 0.64)
	billboard.StudsOffset = Vector3.new(0, height or 2.1, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 60

	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.GothamBold
	textLabel.Text = text
	textLabel.TextColor3 = color
	textLabel.TextStrokeTransparency = 0.3
	textLabel.TextScaled = true
	textLabel.Parent = billboard

	-- Parented last, matching the other builders, so it's safe whether or not `parent` is live yet.
	billboard.Parent = parent
end

-- Decorative piece: anchored, and neither collides, blocks shots nor fires touches.
local function detail(parent, size, cframe, color, material, shape, transparency)
	local part = Instance.new("Part")
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = part.Material ~= Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Upright cylinder centred at `cframe`.
local function column(parent, diameter, height, cframe, color, material, transparency)
	return detail(parent, Vector3.new(height, diameter, diameter), cframe * CFrame.Angles(0, 0, math.pi / 2), color,
		material, Enum.PartType.Cylinder, transparency)
end

-- The part players and bots interact with. Invisible and upright, so the model on it turns
-- around the vertical when AmbientClient spins it.
-- The newest pickup base made, so the Drop* functions below can hand what they just spawned to the
-- dropped-item cap without every spawner having to return it.
local lastPickup = nil

-- Oliver, 2026-09-22 15:26: at most 50 DROPPED items on the ground at once (death drops, chest spills,
-- thrown-away slots); past that the oldest is deleted. Loot the map spawns at the start is not counted.
local MAX_DROPPED = 50
local dropped = {}

local function trackDrop(base)
	if not base or not base.Parent then
		return
	end
	table.insert(dropped, base)
	-- Forget ones already picked up or cleared, then trim the oldest down to the cap.
	local live = {}
	for _, item in ipairs(dropped) do
		if item.Parent then
			table.insert(live, item)
		end
	end
	dropped = live
	while #dropped > MAX_DROPPED do
		local oldest = table.remove(dropped, 1)
		oldest:Destroy()
	end
end

local function pickupBase(name, position)
	local base = Instance.new("Part")
	lastPickup = base
	base.Name = name
	base.Size = Vector3.new(2.4, 0.4, 2.4)
	base.Transparency = 1
	base.Anchored = true
	base.CanCollide = false
	base.CFrame = CFrame.new(position + Vector3.new(0, 0.3, 0))
	return base
end

-- Drops (from bodies, chests, swaps) start at waist height; put them on whatever is beneath.
local function snapToGround(position)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include = { workspace.Terrain }
	local map = workspace:FindFirstChild("Map")
	if map then
		table.insert(include, map)
	end
	params.FilterDescendantsInstances = include

	local result = workspace:Raycast(position + Vector3.new(0, 3, 0), Vector3.new(0, -40, 0), params)
	return result and result.Position or position - Vector3.new(0, 2, 0)
end

--------------------------------------------------------------------------------
-- Pickups
--------------------------------------------------------------------------------

local function spawnGroundWeapon(position, forcedDef, ammo)
	local def = forcedDef or WeaponData.RollGroundWeapon()
	local color = Rarity.Color(def.rarity)

	-- On whatever is really under the spot, the way a chest is. Spots arrive at the height their
	-- generator assumed (a plaza's paving top, a street's pavement top, a floor slab plus a step),
	-- and where that surface isn't there the pad hung in the air: measured on SahurSprings seed
	-- 101, 135 of 448 spots were 0.46 to 3.9 studs above the ground, and two were sunk into it.
	position = snapToGround(position)
	local base = pickupBase("GroundWeapon", position)

	-- Bots read this to know what they'd be picking up without needing the closure.
	base:SetAttribute("WeaponId", def.id)

	-- A dropped gun remembers its ammo. Map spawns carry none and come full.
	if ammo then
		base:SetAttribute("Mag", ammo.mag or 0)
		base:SetAttribute("Reserve", ammo.reserve or 0)
	end

	-- The pad: a dark disc on the ground with the rarity ring standing a clear step proud of it.
	--
	-- Sized against the GUN rather than against nothing. At 2.8 studs with a 2.4-stud neon ring it was
	-- 7.5x the on-screen area of the thing it was advertising -- measured from a standing eye, the gun
	-- was 0.95% of the screen and the pad 7.10%, and the pad is 2.8x brighter -- so a pickup read as a
	-- glowing plate with a dark smudge over it. The ring still has to be findable from down the street,
	-- which is its whole job, so it keeps its colour and its neon and simply stops shouting up close.
	local pad = {
		column(base, 1.9, 0.18, base.CFrame * CFrame.new(0, -0.1, 0), Color3.fromRGB(30, 32, 38), Enum.Material.DiamondPlate),
		column(base, 1.5, 0.22, base.CFrame * CFrame.new(0, -0.02, 0), color, Enum.Material.Neon, 0.45),
	}

	-- The real gun, the same model players carry, tilted low over its pad -- centred on the pad by its
	-- BOUNDING BOX, not by its design origin (the bore above the trigger), which used to leave most of
	-- the gun hanging off one side of the disc.
	WeaponService.BuildStaticGun(def, color, Enum.Material.Metal,
		base.CFrame * CFrame.new(0, 0.85, 0) * CFrame.Angles(0, math.pi / 2, math.rad(-10)), base, { centre = true })

	if (Rarity.Index[def.rarity] or 1) >= 3 then
		local light = Instance.new("PointLight")
		light.Color = color
		light.Range = 9
		light.Brightness = 1.5
		light.Parent = base
	end
	-- A Legendary on the floor — from a supply drop, or off whoever just died holding it — throws a
	-- beam up so it can be seen from down the street. Nobody should walk past one.
	if (Rarity.Index[def.rarity] or 1) >= 5 then
		local beam = column(base, 0.5, 14, base.CFrame * CFrame.new(0, 7.5, 0), color, Enum.Material.Neon, 0.65)
		beam.CanCollide = false
	end

	-- The tier in words, not only in the colour. A player deciding whether a gun on the floor beats the
	-- one in their hands reads this from a distance, and colour alone asks them to have learnt seven
	-- shades -- and excludes anyone who cannot tell two of them apart.
	label(base, string.format("%s %s", def.rarity, def.name), color)
	local prompt = makePrompt(base, "Pick Up", string.format("%s %s", def.rarity, def.name))

	-- Parented once everything is attached, so the pickup replicates as one piece; the z-fight
	-- pass runs after, in the world, so a pad whose top meets the ground on a slope is lifted.
	-- Only the pad goes through it. The gun already ran GunModels' own pass at its millimetre
	-- tolerance, and the map's tolerance read its fine detail as fighting and grew rails and
	-- serrations by whole studs: the gun on the floor stopped looking like the gun you pick up.
	base.Parent = ensureContainer()
	ZFight.Fix(pad)

	prompt.Triggered:Connect(function(player)
		if not base.Parent then
			return
		end
		-- A gun someone dropped keeps the ammo it had. Refilling it — or topping up every
		-- slot's reserve on each pickup — would let swapping two guns back and forth on the
		-- floor mint unlimited ammo.
		local carried = nil
		if base:GetAttribute("Mag") ~= nil then
			carried = { mag = base:GetAttribute("Mag"), reserve = base:GetAttribute("Reserve") }
		end

		local ok, message, replaced = WeaponService.GiveWeapon(player, def.id, carried)
		if ok then
			if not carried then
				WeaponService.GiveAmmo(player, 0.25)
			end
			-- Swapping puts whatever was held down where the new gun was, instead of deleting it.
			if replaced then
				LootService.DropSlot(replaced, base.Position)
			end
			StateSync.Notify(player, message)
			base:Destroy()
		elseif message then
			-- Never fail silently: a pickup that does nothing reads as a broken prompt.
			StateSync.Notify(player, "Couldn't pick that up: " .. message, true)
		end
	end)
end

-- A stack of one item on a glowing pad: the same model you hold, turning slowly. Heals and
-- shields are "HealPickup"s and movement items "ItemPickup"s (AmbientClient spins both). Only
-- real heals carry HealId, which is how bots find something they can use.
--
-- Taking it fills your slots as far as they go; whatever doesn't fit stays on the pad. With all
-- eight slots full it swaps with what you're holding, which goes down on the pad in its place.
local function spawnConsumable(position, itemId, amount)
	local item = ItemData.Get(itemId)
	if not item then
		return
	end
	amount = amount or item.pickup

	local recovery = item.kind == "heal" or item.kind == "shield"
	-- On the real surface under the spot (see spawnGroundWeapon).
	position = snapToGround(position)
	local base = pickupBase(recovery and "HealPickup" or "ItemPickup", position)
	base:SetAttribute("ItemId", itemId)
	base:SetAttribute("Amount", amount)
	if item.kind == "heal" then
		base:SetAttribute("HealId", itemId)
	end

	local frame = base.CFrame
	local pad = {
		column(base, 2.4, 0.16, frame * CFrame.new(0, -0.1, 0), Color3.fromRGB(30, 32, 38), Enum.Material.DiamondPlate),
		column(base, 2.0, 0.18, frame * CFrame.new(0, -0.01, 0), item.color, Enum.Material.Neon, 0.35),
	}

	local model = ItemModels.Build(itemId, { scale = 1.25 })
	model:PivotTo(frame * CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.rad(-12)))
	-- Descendants, not children: the item builders lay their parts out flat today, but a pickup that
	-- silently dropped any part nested a level down would be a pickup that doesn't look like the item
	-- it gives you. BuildStaticGun walks descendants for the same reason.
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Parent = base
		end
	end
	model:Destroy()

	if (Rarity.Index[item.rarity] or 1) >= 3 then
		local light = Instance.new("PointLight")
		light.Color = item.color
		light.Range = 8
		light.Brightness = 1.4
		light.Parent = base
	end

	local function caption()
		return amount > 1 and string.format("%s x%d", item.name, amount) or item.name
	end

	label(base, caption(), item.color, 2.8)
	local prompt = makePrompt(base, "Take", caption())

	-- Parented once everything is attached, so the pickup replicates as one piece; the z-fight
	-- pass runs after, in the world, so the ground counts. Pad only: the item model ran its own
	-- pass in ItemModels, and anything moved here after replication is undone on clients, which
	-- spin the pickup from the offsets it arrived with.
	base.Parent = ensureContainer()
	ZFight.Fix(pad)

	local function leaveRest(taken)
		amount -= taken
		base:SetAttribute("Amount", amount)
		prompt.ObjectText = caption()
		local billboard = base:FindFirstChildOfClass("BillboardGui")
		local text = billboard and billboard:FindFirstChildOfClass("TextLabel")
		if text then
			text.Text = caption()
		end
	end

	prompt.Triggered:Connect(function(player)
		if not base.Parent or base:GetAttribute("Claimed") then
			return
		end
		local added = WeaponService.GiveConsumable(player, itemId, amount)
		if added >= amount then
			base:SetAttribute("Claimed", true)
			StateSync.Notify(player, "Picked up " .. caption())
			base:Destroy()
		elseif added > 0 then
			leaveRest(added)
			StateSync.Notify(player, string.format("Took %d %s. No room for the rest.", added, item.name))
		elseif WeaponService.Get(player) then
			-- All eight slots full: it goes into the hand, and what was held goes down on the pad.
			local replaced, taken = WeaponService.SwapHeldForItem(player, itemId, amount)
			if replaced then
				local pickedUp = taken > 1 and string.format("%s x%d", item.name, taken) or item.name
				StateSync.Notify(player, "Swapped to " .. pickedUp)
				if taken >= amount then
					base:SetAttribute("Claimed", true)
					base:Destroy()
				else
					leaveRest(taken)
				end
				LootService.DropSlot(replaced, position)
			else
				StateSync.Notify(player, "No room: you're already holding " .. item.name .. ".", true)
			end
		else
			StateSync.Notify(player, "Couldn't pick that up right now.", true)
		end
	end)
end

--------------------------------------------------------------------------------
-- Chests
--------------------------------------------------------------------------------

-- Marks a chest opened so clients play the lid swing, then removes it once that's had time
-- to play. `Claimed` stops anyone else looting it in the meantime.
local function openChest(chest, rarity)
	chest:SetAttribute("Claimed", true)
	chest:SetAttribute("LootRarity", rarity)
	chest:SetAttribute("Opened", true)
	local prompt = chest:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
	task.delay(OPENED_LINGER, function()
		if chest.Parent then
			chest:Destroy()
		end
	end)
end

local function spawnChest(cframe)
	local floor = snapToGround(cframe.Position)

	-- The treasure chest (CrateModels), turned the way the spot faces, on the ground.
	local chest = CrateModels.Chest(CFrame.new(floor) * cframe.Rotation)

	label(chest, "Chest", Color3.fromRGB(255, 206, 110), 2.8)

	local prompt = makePrompt(chest, "Open", "Chest")
	prompt.HoldDuration = 0.8

	-- Parented once everything is attached, so the whole chest replicates as one piece; the
	-- z-fight pass runs after, in the world, so the ground counts.
	chest.Parent = ensureContainer()
	ZFight.Fix({ chest })

	prompt.Triggered:Connect(function(player)
		if chest:GetAttribute("Claimed") or not chest.Parent then
			return
		end
		-- Claimed before anything is handed over, so neither a second player in the same moment nor a
		-- fault partway through can open it twice.
		chest:SetAttribute("Claimed", true)

		-- Oliver, 2026-09-22 14:37: chests spill their loot onto the ground instead of straight into the
		-- inventory. Everything lands in front of the chest, toward whoever opened it, and is picked up
		-- the normal way. Ammo still goes straight to the opener: there is no ground pickup for ammo.
		local opener = player.Character and player.Character.PrimaryPart
		local toward = opener and (opener.Position - chest.Position) * Vector3.new(1, 0, 1) or Vector3.zero
		local spill = chest.Position + (toward.Magnitude > 0.1 and toward.Unit * 4 or Vector3.new(0, 0, 4))
		local dropped = {}
		local best = "Common"
		for gunIndex = 1, LootService.ChestGuns do
			local def = WeaponData.RollChestWeapon()
			local floor = gunIndex == 1 and LootService.ChestRarityFloor or nil
			if floor then
				for _ = 1, 12 do
					if (Rarity.Index[def.rarity] or 0) >= (Rarity.Index[floor] or 0) then
						break
					end
					def = WeaponData.RollChestWeapon()
				end
			end
			if (Rarity.Index[def.rarity] or 0) > (Rarity.Index[best] or 0) then
				best = def.rarity
			end
			LootService.DropWeapon(def.id, spill, nil, chest.Position)
			table.insert(dropped, def.name)
		end

		WeaponService.GiveAmmo(player, 0.4 + math.random() * 0.5)

		local function giveItem(item)
			LootService.DropItem(item.id, spill, item.pickup, chest.Position)
			table.insert(dropped, item.name)
		end

		-- Always some recovery, often a second, a fair chance of a movement item, and now and
		-- then a portable defense.
		giveItem(ItemData.RollRecovery())
		if math.random() < 0.45 then
			giveItem(ItemData.RollRecovery())
		end
		if math.random() < CHEST_ITEM_CHANCE then
			giveItem(ItemData.RollMovement())
		end
		if math.random() < CHEST_DEFENSE_CHANCE then
			giveItem(ItemData.RollDefense())
		end
		if math.random() < CHEST_THROWABLE_CHANCE then
			giveItem(ItemData.RollThrowable())
		end

		StateSync.Notify(player, "Chest: " .. table.concat(dropped, ", ") .. " on the ground")
		QuestService.Progress(player, "chests", 1)
		if nearLandmark(chest.Position) then
			QuestService.Progress(player, "landmarkChests", 1)
		end

		openChest(chest, best)
	end)
end

--------------------------------------------------------------------------------

-- What a ground item spot holds: now and then a portable defense, fairly often a grenade or smoke
-- bomb, otherwise a movement item.
local function rollGroundItem()
	local roll = math.random()
	if roll < GROUND_DEFENSE_SHARE then
		return ItemData.RollDefense()
	elseif roll < GROUND_DEFENSE_SHARE + GROUND_THROWABLE_SHARE then
		return ItemData.RollThrowable()
	end
	return ItemData.RollMovement()
end

local function shuffled(list)
	local copy = table.clone(list)
	for index = #copy, 2, -1 do
		local swap = math.random(1, index)
		copy[index], copy[swap] = copy[swap], copy[index]
	end
	return copy
end

function LootService.Populate(mapInfo)
	LootService.Clear()
	ensureContainer()
	landmarkSpots = mapInfo.landmarks or {}

	-- Hundreds of pickups — each a small model with a label, a prompt and its connections —
	-- would otherwise be created in a single server frame right as players spawn. Yield between
	-- batches, and stop if the loot is cleared during a yield so spawning can't carry on into a
	-- torn-down match. Captured after Clear() above, which has already bumped the generation.
	local generation = populateGeneration
	local spawned = 0

	local function pace()
		spawned += 1
		if spawned % POPULATE_BATCH == 0 then
			task.wait()
		end
		return generation == populateGeneration
	end

	local chestSpots = shuffled(mapInfo.chestSpots or {})
	for index = 1, math.floor(#chestSpots * CHEST_FRACTION) do
		spawnChest(chestSpots[index])
		if not pace() then
			return
		end
	end

	local spots = mapInfo.lootSpots
	if spots then
		-- Two lists can name nearly the same spot (a bank and a roadside, say); one pickup there
		-- is plenty, and two would be built through each other.
		local taken = {}
		local function crowded(position)
			for _, other in ipairs(taken) do
				if (other - position).Magnitude < 3 then
					return true
				end
			end
			table.insert(taken, position)
			return false
		end
		local function place(list, fraction, spawner)
			local ordered = shuffled(list or {})
			for index = 1, math.floor(#ordered * fraction) do
				if not crowded(ordered[index]) then
					spawner(ordered[index])
					if not pace() then
						return false
					end
				end
			end
			return true
		end

		if not place(spots.weapon, WEAPON_FRACTION, function(position)
			spawnGroundWeapon(position)
		end) then
			return
		end
		if not place(spots.heal, HEAL_FRACTION, function(position)
			spawnConsumable(position, ItemData.RollRecovery().id)
		end) then
			return
		end
		place(spots.item, ITEM_FRACTION, function(position)
			spawnConsumable(position, rollGroundItem().id)
		end)
		return
	end

	-- No categorised spots: the old even spread over ground spots.
	local groundSpots = shuffled(mapInfo.groundSpots or {})
	local groundCount = math.floor(#groundSpots * GROUND_FRACTION)
	for index = 1, groundCount do
		spawnGroundWeapon(groundSpots[index])
		if not pace() then
			return
		end
	end

	local used = groundCount
	for index = 1, math.min(HEAL_SPOTS, #groundSpots - used) do
		spawnConsumable(groundSpots[used + index], ItemData.RollRecovery().id)
		if not pace() then
			return
		end
	end
	used += math.min(HEAL_SPOTS, #groundSpots - used)

	for index = 1, math.min(ITEM_SPOTS, #groundSpots - used) do
		spawnConsumable(groundSpots[used + index], rollGroundItem().id)
		if not pace() then
			return
		end
	end

	-- Pickups are spun client-side in AmbientClient. Doing it here meant rewriting the CFrame
	-- of every pickup on the server each frame, and every one of those writes replicated to
	-- every client — thousands of network updates a second for a decoration.
end

--------------------------------------------------------------------------------
-- Drops
--------------------------------------------------------------------------------

-- How far a drop is thrown from where it fell, how close its pad may come to a wall, and how far
-- down a drop looks for a floor.
local SCATTER = 4
local PAD_CLEARANCE = 1.6
local FLOOR_REACH = 400
local STEP_TOLERANCE = 2.5
local AROUND = {}
for index = 0, 7 do
	local angle = index / 8 * math.pi * 2
	table.insert(AROUND, Vector3.new(math.cos(angle), 0, math.sin(angle)))
end

local function dropParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	local include = { workspace.Terrain }
	local map = workspace:FindFirstChild("Map")
	if map then
		table.insert(include, map)
	end
	params.FilterDescendantsInstances = include
	return params
end

-- Nudges a floor point away from any wall within a pad's reach, traced at knee height.
local function clearOfWalls(point, params)
	local knee = point + Vector3.new(0, 1, 0)
	local push = Vector3.zero
	for _, direction in ipairs(AROUND) do
		local hit = workspace:Raycast(knee, direction * PAD_CLEARANCE, params)
		if hit then
			push -= direction * (PAD_CLEARANCE - (hit.Position - knee).Magnitude)
		end
	end
	return point + push
end

-- Where a drop comes to rest: thrown a few studs from `position`, but never through a wall, off a
-- roof or down a stairwell. It used to be a straight random offset snapped down with a 40-stud
-- ray, which put a drop by a wall on the far side of it, and one by a parapet in mid-air beside
-- the tower (the ray fell short of the street and the fallback left it hanging).
--
-- `from`, when given, is where the drop was thrown from (a player dropping a slot in front of
-- them), so a wall between the two stops it as well.
local function scatter(position, from)
	local params = dropParams()
	local origin = from or position
	local below = workspace:Raycast(origin + Vector3.new(0, 1, 0), Vector3.new(0, -FLOOR_REACH, 0), params)
	if not below then
		return position - Vector3.new(0, 2, 0)
	end
	local floor = below.Position
	local knee = floor + Vector3.new(0, 1, 0)

	-- The throw, traced at knee height, stops a pad's width short of whatever it meets.
	local throw = Vector3.new(position.X - origin.X + math.random(-SCATTER, SCATTER), 0, position.Z - origin.Z + math.random(-SCATTER, SCATTER))
	local spot = floor
	if throw.Magnitude > 0.05 then
		local hit = workspace:Raycast(knee, throw.Unit * (throw.Magnitude + PAD_CLEARANCE), params)
		local reach = hit and math.max(0, (hit.Position - knee).Magnitude - PAD_CLEARANCE) or throw.Magnitude
		spot = floor + throw.Unit * math.min(reach, throw.Magnitude)
	end

	-- Settle on the floor under the spot. Anything more than a step above or below the floor it
	-- was thrown from is over an edge, so the drop stays where it fell instead.
	for _, candidate in ipairs({ spot, floor }) do
		local cleared = clearOfWalls(candidate, params)
		local land = workspace:Raycast(cleared + Vector3.new(0, STEP_TOLERANCE + 0.5, 0), Vector3.new(0, -(STEP_TOLERANCE * 2 + 0.5), 0), params)
		if land and math.abs(land.Position.Y - floor.Y) <= STEP_TOLERANCE then
			return land.Position
		end
	end
	return floor
end

-- Death drops. Killing someone should put their gun back into circulation — otherwise
-- every Legendary that reaches the midgame is permanently removed from the map.
function LootService.DropWeapon(weaponId, position, ammo, from)
	local def = WeaponData.Get(weaponId)
	if not def or not position then
		return
	end
	ensureContainer()
	lastPickup = nil
	spawnGroundWeapon(scatter(position, from), def, ammo)
	trackDrop(lastPickup)
end

-- A random heal or shield, for bots' death drops.
function LootService.DropHeal(position)
	if not position then
		return
	end
	ensureContainer()
	lastPickup = nil
	spawnConsumable(scatter(position), ItemData.RollRecovery().id)
	trackDrop(lastPickup)
end

function LootService.DropItem(itemId, position, amount, from)
	if not position or not ItemData.Get(itemId) or (amount and amount <= 0) then
		return
	end
	ensureContainer()
	lastPickup = nil
	spawnConsumable(scatter(position, from), itemId, amount)
	trackDrop(lastPickup)
end

-- Whatever was in an inventory slot, back on the floor: a gun with its ammo, or the whole stack.
-- `from` (optional) is where it was thrown from, so it can't pass through a wall on the way.
function LootService.DropSlot(slot, position, from)
	if not slot then
		return
	end
	if slot.kind == "item" then
		LootService.DropItem(slot.id, position, slot.count, from)
	else
		LootService.DropWeapon(slot.id, position, { mag = slot.mag, reserve = slot.reserve }, from)
	end
end

-- Loot left standing on nothing after the part under it broke (DestructibleService.OnPartBroken):
-- every pickup and unopened chest resting on that part's top comes down to whatever is below it
-- now. Each is rebuilt there with what it held, not moved: clients turn a pickup from the frame it
-- arrived at, so moving one on the server would leave it hanging on everyone's screen.
local RESTING_REACH = 3

function LootService.Resettle(cframe, size)
	local loot = container and container.Parent and container
	if not loot then
		return
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { loot }
	local resting = {}
	local over = cframe * CFrame.new(0, size.Y / 2 + RESTING_REACH / 2, 0)
	for _, hit in ipairs(workspace:GetPartBoundsInBox(over, Vector3.new(size.X, RESTING_REACH, size.Z), params)) do
		local node = hit
		while node.Parent and node.Parent ~= loot do
			node = node.Parent
		end
		if node.Parent == loot then
			resting[node] = true
		end
	end
	if not next(resting) then
		return
	end
	-- After the part has gone, so the floor found below is the one that's left.
	task.defer(function()
		for node in pairs(resting) do
			if node.Parent == loot and node:IsA("BasePart") and not node:GetAttribute("Claimed") then
				local at = node.Position
				if node.Name == "GroundWeapon" then
					local def = WeaponData.Get(node:GetAttribute("WeaponId"))
					if def then
						local ammo = nil
						if node:GetAttribute("Mag") ~= nil then
							ammo = { mag = node:GetAttribute("Mag"), reserve = node:GetAttribute("Reserve") }
						end
						node:Destroy()
						spawnGroundWeapon(scatter(at), def, ammo)
					end
				elseif node.Name == "HealPickup" or node.Name == "ItemPickup" then
					local itemId, amount = node:GetAttribute("ItemId"), node:GetAttribute("Amount")
					if ItemData.Get(itemId) and type(amount) == "number" and amount > 0 then
						node:Destroy()
						spawnConsumable(scatter(at), itemId, amount)
					end
				elseif node.Name == "Chest" then
					local rotation = node.CFrame.Rotation
					node:Destroy()
					spawnChest(CFrame.new(scatter(at)) * rotation)
				end
			end
		end
	end)
end

DestructibleService.OnPartBroken(LootService.Resettle)

-- Hands over as much of an item as fits and leaves the rest on the floor at `position`. Returns
-- how many were taken.
function LootService.GiveOrDrop(player, itemId, amount, position)
	local added = WeaponService.GiveConsumable(player, itemId, amount)
	if added < amount then
		LootService.DropItem(itemId, position, amount - added)
	end
	return added
end

--------------------------------------------------------------------------------
-- Bot access
--
-- Bots can't use ProximityPrompts, so they get a direct read/claim path. Claiming is
-- single-shot, which is what keeps two bots from looting the same chest.
--------------------------------------------------------------------------------

function LootService.FindNearest(position, radius)
	if not container or not container.Parent then
		return nil
	end

	local best, bestDistance = nil, radius

	for _, item in ipairs(container:GetChildren()) do
		if item:IsA("BasePart") and (item.Name == "GroundWeapon" or item.Name == "Chest") then
			if not item:GetAttribute("Claimed") then
				local distance = (item.Position - position).Magnitude
				if distance < bestDistance then
					best, bestDistance = item, distance
				end
			end
		end
	end

	return best, bestDistance
end

-- How long a bot must stand at loot before taking it: the same hold a player needs, with a
-- floor so even zero-hold pickups aren't frame-perfect. Bots used to claim instantly and
-- won every contested chest.
function LootService.ClaimTime(item)
	local prompt = item and item:FindFirstChildOfClass("ProximityPrompt")
	local hold = prompt and prompt.HoldDuration or 0
	return math.max(0.3, hold)
end

-- Returns the WeaponData def the bot gets, or nil if the loot was already taken.
function LootService.ClaimForBot(item)
	if not item or not item.Parent or item:GetAttribute("Claimed") then
		return nil
	end

	-- A player is holding this prompt right now; it's theirs.
	if item:GetAttribute("PlayerHolding") then
		return nil
	end

	local def
	if item.Name == "Chest" then
		def = WeaponData.RollChestWeapon()
		-- Opens visibly for anyone nearby, just like a player's chest.
		openChest(item, def.rarity)
	else
		item:SetAttribute("Claimed", true)
		local id = item:GetAttribute("WeaponId")
		def = id and WeaponData.Get(id) or nil
		item:Destroy()
	end

	return def
end

-- Heal pickups are kept out of FindNearest on purpose: bots only want them when they're
-- hurt and carrying nothing, which is a different decision from gearing up.
function LootService.FindNearestHeal(position, radius)
	if not container or not container.Parent then
		return nil
	end

	local best, bestDistance = nil, radius
	for _, item in ipairs(container:GetChildren()) do
		if item.Name == "HealPickup" and item:GetAttribute("HealId") and not item:GetAttribute("Claimed") then
			local distance = (item.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = item, distance
			end
		end
	end
	return best, bestDistance
end

-- Returns (healId, amount), or nil if the pickup isn't available to the bot.
function LootService.ClaimHealForBot(item)
	if not item or not item.Parent or item:GetAttribute("Claimed") or item:GetAttribute("PlayerHolding") then
		return nil
	end

	local healId = item:GetAttribute("HealId")
	local amount = item:GetAttribute("Amount")
	if not healId or not amount then
		return nil
	end

	item:SetAttribute("Claimed", true)
	item:Destroy()
	return healId, amount
end

function LootService.Clear()
	populateGeneration += 1
	if spinConnection then
		spinConnection:Disconnect()
		spinConnection = nil
	end
	if container then
		container:Destroy()
		container = nil
	end
end

return LootService
