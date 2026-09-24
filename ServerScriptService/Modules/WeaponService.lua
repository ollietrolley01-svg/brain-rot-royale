-- Per-player loadout: eight slots that each hold a gun or a stack of one item, a shield, ammo, and
-- whatever is held in hand.
--
-- Select a slot to hold what's in it. A gun fires; an item is used with a click, which takes the
-- item's `useTime` (ItemData). Switching slots cancels a use in progress, and the item is only
-- spent once the use finishes and actually did something.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local GunModels = require(Shared:WaitForChild("GunModels"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))
local QuestService = require(script.Parent:WaitForChild("QuestService"))

local WeaponService = {}

local SLOT_COUNT = 8
WeaponService.SlotCount = SLOT_COUNT

local MAX_SHIELD = MatchConfig.MaxShield

-- Instant items (rockets, blink beans) can't be chained faster than this.
local INSTANT_COOLDOWN = 0.45

-- Without a raise time, cycling slots is a free way to ignore fire rate: swap, shoot, swap
-- back, shoot again, all faster than either weapon allows on its own.
local EQUIP_TIME = MatchConfig.EquipTime

-- Bots and older callers look heals and movement items up here. Built from ItemData, so there's
-- one source of truth. `Items` and `ItemOrder` hold the movement items only, despite the plain names:
-- heals and shields sit beside them in their own tables, and BotService reads all three.
WeaponService.Heals = {}
WeaponService.Shields = {}
WeaponService.Items = {}
WeaponService.ItemOrder = {}
for _, id in ipairs(ItemData.Order) do
	local item = ItemData.Items[id]
	if item.kind == "heal" then
		WeaponService.Heals[id] = { name = item.name, amount = item.amount, cap = item.cap, max = item.stack }
	elseif item.kind == "shield" then
		WeaponService.Shields[id] = { name = item.name, amount = item.amount, cap = item.cap, max = item.stack }
	elseif item.kind == "movement" then
		WeaponService.Items[id] = { name = item.name, max = item.stack, color = item.color }
		table.insert(WeaponService.ItemOrder, id)
	end
end

-- Set by MovementService (which requires this module, so it can't be required back): performs a
-- movement item's effect and returns true if it happened. DefenseService does the same for the
-- portable defenses.
WeaponService.MovementEffect = function()
	return false
end
WeaponService.DefenseEffect = function()
	return false
end
-- Set by ProjectileService: throws a grenade or smoke bomb toward `aimPoint`.
WeaponService.ThrowEffect = function()
	return false
end

local loadouts = {}
local lastInstantAt = {}

local loadoutChanged = Remotes.Event("LoadoutChanged")
local itemUsed = Remotes.Event("ItemUsed")

local function blankLoadout()
	return {
		-- index -> { kind = "weapon", id, mag, reserve } or { kind = "item", id, count }
		slots = {},
		shield = 0,
		equipped = nil,
		reloading = false,
		lastShotAt = 0,
		equipReadyAt = 0,
		reloadToken = 0,
		-- The item being used right now: { index, id, startedAt, duration }.
		using = nil,
		useToken = 0,
	}
end

-- Mirrors the shield onto the humanoid as an attribute, which is what nameplates draw — the
-- same place bots keep theirs.
local function syncShield(player, value)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:SetAttribute("Shield", value)
	end
end

function WeaponService.Get(player)
	return loadouts[player]
end

function WeaponService.Reset(player)
	loadouts[player] = blankLoadout()
	lastInstantAt[player] = nil
	syncShield(player, 0)
	WeaponService.Push(player)
end

function WeaponService.Clear(player)
	loadouts[player] = nil
	lastInstantAt[player] = nil
	syncShield(player, 0)
end

-- A player alive in a match with no loadout can't pick anything up: GiveWeapon and GiveConsumable
-- refuse without one, and the pickup prompt said nothing, so the player pressed E and nothing
-- happened until a respawn made a new loadout (Oliver, 2026-09-22: "I sometimes also just cant pick
-- up items till i respawn"). Whatever cleared it, a living player who is in the match gets an empty
-- loadout back here instead, and the output log says so, so the cause can be found.
local warnedMissing = {}
local function loadoutFor(player)
	local loadout = loadouts[player]
	if loadout then
		return loadout
	end
	local character = typeof(player) == "Instance" and player:IsA("Player") and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 and player:GetAttribute("InMatch") == true then
		if not warnedMissing[player] then
			warnedMissing[player] = true
			warn(string.format("[WeaponService] %s was alive in the match with no loadout; made a fresh one.\n%s",
				player.Name, debug.traceback()))
		end
		loadouts[player] = blankLoadout()
		return loadouts[player]
	end
	return nil
end

function WeaponService.Push(player)
	local loadout = loadouts[player]
	if not loadout then
		loadoutChanged:FireClient(player, nil)
		return
	end

	-- Empty slots are `false`, not nil. A table with a nil hole is a sparse array, and a
	-- RemoteEvent truncates it at the gap — an empty slot 1 would hide the guns in 2 and 3.
	-- Clients only ever index this, and `false` reads as empty there just like nil.
	local slots = {}
	for index = 1, SLOT_COUNT do
		local slot = loadout.slots[index]
		slots[index] = false
		if slot and slot.kind == "item" then
			local item = ItemData.Get(slot.id)
			slots[index] = {
				kind = "item",
				id = slot.id,
				name = item.name,
				rarity = item.rarity,
				itemKind = item.kind,
				count = slot.count,
				stack = item.stack,
				useTime = item.useTime,
			}
		elseif slot then
			local def = WeaponData.Get(slot.id)
			slots[index] = {
				kind = "weapon",
				id = slot.id,
				name = def.name,
				rarity = def.rarity,
				ability = def.ability,
				mag = slot.mag,
				magSize = def.magSize,
				reserve = slot.reserve,
			}
		end
	end

	-- Durations, not timestamps: server and client clocks aren't comparable.
	local using = loadout.using
	loadoutChanged:FireClient(player, {
		slots = slots,
		equipped = loadout.equipped,
		shield = loadout.shield,
		maxShield = MAX_SHIELD,
		reloading = loadout.reloading,
		equipReadyIn = math.max(0, (loadout.equipReadyAt or 0) - os.clock()),
		using = using and {
			id = using.id,
			index = using.index,
			duration = using.duration,
			remaining = math.max(0, using.startedAt + using.duration - os.clock()),
		} or nil,
	})
end

--------------------------------------------------------------------------------
-- Held gun model
--------------------------------------------------------------------------------

-- The player's gun skin, if one is equipped: its colour and material, and true. Unskinned guns wear
-- their real finishes, with the rarity colour only as an accent.
local function skinColor(player, def)
	local data = PlayerData.Get(player)
	local skinId = data and data.Cosmetics.gunSkin
	local skin = skinId and CosmeticData.Get(skinId)
	if skin and skin.kind == "GunSkin" then
		return skin.color, skin.material, true
	end
	return Rarity.Color(def.rarity), Enum.Material.Metal, false
end

local function clearHeldGun(character)
	for _, name in ipairs({ "HeldGun", "HeldItem" }) do
		local existing = character:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end

local V = Vector3.new
local DARK = Color3.fromRGB(38, 40, 46)
local GRIP = Color3.fromRGB(34, 34, 38)
local WOOD = Color3.fromRGB(122, 82, 50)
local GOLD = Color3.fromRGB(255, 196, 64)
local LENS = Color3.fromRGB(90, 170, 230)

local BRASS = Color3.fromRGB(214, 170, 80)
local STEEL = Color3.fromRGB(150, 154, 162)
local SHADOW = Color3.fromRGB(14, 14, 18)
local DOT = Color3.fromRGB(255, 60, 60)
local LEATHER = Color3.fromRGB(64, 46, 34)
local RUBBER = Color3.fromRGB(28, 28, 30)
local CAMO = Color3.fromRGB(78, 92, 60)
local LASER = Color3.fromRGB(255, 40, 40)

-- What sets each gun apart from the others of its silhouette (BuildGunModel reads these):
--   compact        shorter barrel and furniture           drum           a drum magazine
--   suppressor     a can on the muzzle                    laser          a laser under the rail (a real beam when you aim)
--   light          a torch under the barrel               holo           a holographic sight instead of a red dot
--   camo           dark bands across the furniture        woodFurniture  wooden handguard and stock
--   bayonet        a blade under the muzzle               foregrip       a vertical foregrip
--   skeletonStock  a skeleton frame instead of a stock    engraved       gold filigree on the body
--   heatShield     a perforated shroud over the barrel    longBarrel     an extra length of barrel
--   sawnOff        barrels cut short, no stock            ghillie        rag wraps along the stock and barrel
--   sixShot        a six-tube revolving launcher          bigTank        a larger tank on a blaster
--   hearts         pink neon hearts on the ammo box       flutes         fluted barrel
local VARIANTS = {
	SahurPistol = { light = true },
	PocketPopper = { compact = true, laser = true },
	RotSMG = { skeletonStock = true, suppressor = true },
	LagSwitchSMG = { drum = true, laser = true },
	GlitchSMG = { drum = true, holo = true, camo = true },
	CrocodiloRifle = { woodFurniture = true, bayonet = true },
	CrumblyCarbine = { compact = true, camo = true },
	BananiniBurst = { foregrip = true, holo = true, camo = true },
	SigmaRevolver = { longBarrel = true, engraved = true },
	TralalaShotgun = { heatShield = true },
	AuraScattergun = { drum = true, heatShield = true, foregrip = true },
	BonkerDoubleBarrel = { sawnOff = true },
	NonnaDoubleBarrel = { engraved = true },
	LarilaSniper = { longBarrel = true, ghillie = true, flutes = true },
	SixSevenMarksman = { camo = true, flutes = true },
	GrassToucherDMR = { woodFurniture = true, laser = true },
	SigmaScout = { compact = true, foregrip = true, light = true },
	TralalaThumper = { sixShot = true },
	BubbleBurster = { bigTank = true },
	RizzRotary = { holo = true, engraved = true, foregrip = true },
}

-- Each weapon's `style` (WeaponData) picks a silhouette, assembled from parts with real surface
-- texture: DiamondPlate rails and magazines, Fabric grips, WoodPlanks furniture, CorrodedMetal
-- fittings on Common guns, glass optics, a neon rarity strip from Rare up, a glowing core from
-- Epic up and gold trim on Legendaries. `color` and `material` skin the main body, which is what
-- gun skins recolour.
--
-- The detail is what makes a gun read as a gun up close in first person: trigger guards, iron
-- sights, toothed rails and red-dot sights, scopes on rings, ejection ports, charging handles,
-- muzzle brakes, vented shrouds, magazine base plates, buttpads and cheek rests. Moving parts
-- are named so the viewmodel can animate them — "Slide…", "Pump…", "Bolt…", "Drum…",
-- "Barrel"/"BarrelClamp" on the rotary, and everything starting "Magazine" — and the
-- "EjectionPort" is where spent casings fly from.
function WeaponService.BuildGunModel(def, color, material, options)
	if GunModels.Supports(def.style) then
		return GunModels.Build(def, color, material, options)
	end
	local model = Instance.new("Model")
	model.Name = "HeldGun"

	local function piece(name, size, cframe, pieceColor, pieceMaterial, shape, transparency)
		local part = Instance.new("Part")
		part.Name = name
		if shape then
			part.Shape = shape
		end
		part.Size = size
		part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
		part.Color = pieceColor
		part.Material = pieceMaterial
		part.Transparency = transparency or 0
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	-- Cylinder running front-to-back, centred at `position`.
	local function tube(name, length, diameter, position, pieceColor, pieceMaterial, transparency)
		return piece(name, V(length, diameter, diameter), CFrame.new(position) * CFrame.Angles(0, math.pi / 2, 0),
			pieceColor, pieceMaterial, Enum.PartType.Cylinder, transparency)
	end

	-- Cylinder running across (along X), centred at `position`.
	local function axle(name, length, diameter, position, pieceColor, pieceMaterial, transparency)
		return piece(name, V(length, diameter, diameter), CFrame.new(position), pieceColor, pieceMaterial, Enum.PartType.Cylinder, transparency)
	end

	-- Grips and stocks rake back: a negative angle tips the top forward.
	local function tilted(position, degrees)
		return CFrame.new(position) * CFrame.Angles(math.rad(degrees), 0, 0)
	end

	-- A wedge: its vertical face at the back (+Z), sloping down to the front. `yaw` turns it (a
	-- half turn puts the slope at the back), `roll` lays it on its side for a chamfer along a rail.
	local function wedge(name, size, position, pieceColor, pieceMaterial, yaw, roll)
		local part = Instance.new("WedgePart")
		part.Name = name
		part.Size = size
		part.CFrame = CFrame.new(position) * CFrame.Angles(0, yaw or 0, roll or 0)
		part.Color = pieceColor
		part.Material = pieceMaterial
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Parent = model
		return part
	end

	local style = def.style or "rifle"
	local variant = VARIANTS[def.id] or {}
	local rarityColor = Rarity.Color(def.rarity)
	local rarityIndex = Rarity.Index[def.rarity] or 1
	local legendary = rarityIndex >= 5
	local metal = Enum.Material.Metal
	local plate = Enum.Material.DiamondPlate
	local planks = Enum.Material.WoodPlanks
	local glass = Enum.Material.Glass
	local neon = Enum.Material.Neon
	local leather = Enum.Material.Leather
	local rubber = Enum.Material.Rubber
	local plastic = Enum.Material.SmoothPlastic
	-- Commons are scuffed and plain; everything else is clean.
	local trim = def.rarity == "Common" and Enum.Material.CorrodedMetal or metal
	local accent = rarityColor
	local furnitureColor = variant.woodFurniture and WOOD or color
	local furnitureMaterial = variant.woodFurniture and planks or material

	----------------------------------------------------------------------------
	-- Rot-Tech fittings. Chunky, rounded, glowing: every gun is built from these.
	----------------------------------------------------------------------------

	-- A rounded block: a box with its four long edges (along Z) turned into cylinders, so the
	-- cross-section is a rounded rectangle. Returns the main box (the part that carries the name).
	local function pill(name, size, position, pieceColor, pieceMaterial)
		local r = math.min(size.X, size.Y) * 0.3
		local main = piece(name, V(size.X, size.Y - 2 * r, size.Z), position, pieceColor, pieceMaterial)
		-- The cross-piece stops a hair short of the main box's ends and the edge tubes run a hair
		-- past them, so the end cap is three faces on three planes rather than three flush ones
		-- flickering against each other (the rounded corners stand just proud of the cap).
		local inset = math.min(0.12, size.Z * 0.4)
		piece(name .. "Fill", V(size.X - 2 * r, size.Y, size.Z - inset), position, pieceColor, pieceMaterial)
		for _, x in ipairs({ -1, 1 }) do
			for _, y in ipairs({ -1, 1 }) do
				tube(name .. "Edge", size.Z + inset, 2 * r, position + V(x * (size.X / 2 - r), y * (size.Y / 2 - r), 0), pieceColor, pieceMaterial)
			end
		end
		return main
	end

	-- A raised spine along the top of a body with a strip of light down it.
	local function spine(z, length, y)
		piece("Spine", V(0.2, 0.12, length), V(0, y + 0.06, z), DARK, metal)
		piece("SpineLight", V(0.08, 0.05, length * 0.8), V(0, y + 0.13, z), accent, neon)
	end

	-- The core lens: a round window in each side of the body showing the glow inside. Rare up.
	local function coreLens(z, y, halfWidth, diameter)
		if rarityIndex < 3 then
			return
		end
		for _, side in ipairs({ -1, 1 }) do
			axle("CoreRing", 0.08, diameter, V(side * (halfWidth + 0.02), y, z), STEEL, metal)
			axle("Core", 0.1, diameter * 0.68, V(side * (halfWidth + 0.03), y, z), accent:Lerp(Color3.new(1, 1, 1), 0.2), neon)
		end
	end

	-- Bands of the skin colour and a darker tone alternating along a tube: the paint job.
	local function bands(z, length, diameter, y, count)
		for index = 0, count - 1 do
			tube("Band", 0.16, diameter + 0.04, V(0, y, z - length / 2 + (index + 0.5) * length / count), index % 2 == 0 and color or DARK,
				index % 2 == 0 and material or metal)
		end
	end

	-- A finned barrel shroud: a tube with three cooling fins and vent slots between them.
	local function finnedShroud(z, length, diameter, y, name)
		local shroud = tube(name or "Shroud", length, diameter, V(0, y, z), DARK, plate)
		-- Fins are thick enough (0.18) that the side fins' tops sit a clear step above the vents'
		-- rather than in the same plane.
		for _, fin in ipairs({ { 0, 1 }, { -1, 0 }, { 1, 0 } }) do
			piece("Fin", V(fin[1] == 0 and 0.18 or diameter * 0.45, fin[1] == 0 and diameter * 0.45 or 0.18, length * 0.7),
				V(fin[1] * diameter * 0.6, y + fin[2] * diameter * 0.6, z), DARK, metal)
		end
		for index = 0, math.floor(length / 0.3) - 1 do
			piece("Vent", V(diameter + 0.02, 0.06, 0.1), V(0, y, z - length / 2 + 0.15 + index * 0.3), DARK, metal, nil, 0.4)
		end
		if variant.camo then
			bands(z, length, diameter, y, 3)
		end
		return shroud
	end

	-- A crown muzzle: a brake with four prongs standing forward of it.
	local function crownMuzzle(z, y, diameter)
		tube("MuzzleBrake", 0.3, diameter, V(0, y, z), DARK, metal)
		for index = 0, 3 do
			local angle = index / 4 * math.pi * 2 + math.pi / 4
			piece("MuzzleProng", V(0.08, 0.08, 0.3), V(math.cos(angle) * diameter * 0.42, y + math.sin(angle) * diameter * 0.42, z - 0.25), STEEL, metal)
		end
		piece("MuzzleGlow", V(diameter * 0.55, diameter * 0.55, 0.04), V(0, y, z - 0.16), STEEL, metal)
	end

	-- A bell muzzle: three rings stepping out to a flared mouth.
	local function bellMuzzle(z, y, diameter)
		for index = 0, 2 do
			tube("MuzzleBrake", 0.14, diameter * (1 + index * 0.25), V(0, y, z - index * 0.14), index == 2 and accent or DARK, index == 2 and neon or metal)
		end
	end

	-- A suppressor can: a fat tube with a rubber grip band.
	local function suppressor(z, y, diameter)
		tube("Suppressor", 0.8, diameter, V(0, y, z), DARK, metal)
		tube("SuppressorBand", 0.2, diameter + 0.04, V(0, y, z + 0.2), RUBBER, rubber)
		tube("SuppressorBand", 0.06, diameter * 0.6, V(0, y, z - 0.42), STEEL, metal)
	end

	-- The rounded pistol grip: a block with a cylinder down its front edge for the fingers, a
	-- thumb rest, leather, and a cap.
	local function roundGrip(position, degrees, size, gripColor, gripMaterial)
		local frame = tilted(position, degrees)
		local gripSize = size or V(0.32, 0.72, 0.4)
		piece("Grip", V(gripSize.X, gripSize.Y, gripSize.Z * 0.6), frame * CFrame.new(0, 0, gripSize.Z * 0.2), gripColor or LEATHER, gripMaterial or leather)
		piece("GripFront", V(gripSize.X, gripSize.Y, gripSize.X), frame * CFrame.new(0, 0, -gripSize.Z / 2 + gripSize.X / 2) * CFrame.Angles(math.pi / 2, 0, 0),
			gripColor or LEATHER, gripMaterial or leather, Enum.PartType.Cylinder)
		for index = 0, 2 do
			piece("GripGroove", V(gripSize.X + 0.01, 0.03, 0.05), frame * CFrame.new(0, gripSize.Y * 0.22 - index * gripSize.Y * 0.24, -gripSize.Z / 2 + 0.02),
				SHADOW, metal)
		end
		piece("ThumbRest", V(gripSize.X + 0.12, 0.1, 0.24), frame * CFrame.new(0, gripSize.Y / 2 - 0.05, 0.02), DARK, metal)
		piece("GripCap", V(gripSize.X + 0.02, 0.06, gripSize.Z + 0.02), frame * CFrame.new(0, -gripSize.Y / 2 - 0.03, 0), DARK, metal)
	end

	-- A rounded foregrip knob under the front.
	local function knobGrip(position)
		piece("ForeGrip", V(0.26, 0.42, 0.26), tilted(position, -6), LEATHER, leather)
		piece("ForeGripKnob", V(0.32, 0.32, 0.32), tilted(position - V(0, 0.28, 0), -6), DARK, plastic, Enum.PartType.Ball)
	end

	-- A tube stock: two rails back to a rounded rubber pad, a cheek piece over the top.
	local function tubeStock(z, y, length, height)
		for _, dy in ipairs({ height * 0.3, -height * 0.3 }) do
			tube("Stock", length, 0.12, V(0, y + dy, z), DARK, metal)
		end
		piece("StockBrace", V(0.26, height * 0.6, 0.14), V(0, y, z), DARK, metal)
		piece("Buttpad", V(0.36, height + 0.1, 0.32), V(0, y, z + length / 2 + 0.12), RUBBER, rubber)
		piece("CheekRest", V(0.3, 0.14, length * 0.45), V(0, y + height * 0.3 + 0.12, z + length * 0.1), furnitureColor, furnitureMaterial == material and leather or furnitureMaterial)
		piece("SlingLoop", V(0.06, 0.14, 0.06), V(0, y - height * 0.3 - 0.12, z + length * 0.3), STEEL, metal)
		if variant.ghillie then
			for index = 0, 2 do
				piece("Rag", V(0.4, 0.09, 0.14), CFrame.new(0, y, z - length / 2 + 0.15 + index * length * 0.32) * CFrame.Angles(0, 0, 0.1 * (index - 1)), CAMO,
					Enum.Material.Fabric)
			end
		end
	end

	-- A solid stock for the wooden guns: the classic shape with a sloping comb.
	local function solidStock(z, y, length, height, stockColor, stockMaterial)
		piece("Stock", V(0.34, height * 0.72, length), V(0, y - height * 0.14, z), stockColor, stockMaterial)
		wedge("StockComb", V(0.34, height * 0.28, length), V(0, y + height * 0.36, z), stockColor, stockMaterial, math.pi)
		piece("Buttpad", V(0.36, height + 0.04, 0.14), V(0, y, z + length / 2 + 0.07), RUBBER, rubber)
	end

	-- A magazine. Energy guns carry a glowing cell; the rest a box with a window of brass rounds.
	-- Everything starts with "Magazine" so the reload drops it as one.
	local function magazine(size, position, degrees, energy)
		local frame = tilted(position, degrees)
		if variant.drum then
			local drumWidth = math.max(0.5, size.Z * 1.4)
			axle("Magazine", size.X + 0.16, drumWidth, (frame * CFrame.new(0, -size.Y * 0.1, 0)).Position, DARK, plate)
			piece("MagazineFeed", V(size.X, size.Y * 0.4, size.Z * 0.6), frame * CFrame.new(0, size.Y * 0.28, 0), DARK, metal)
			axle("MagazineRib", size.X + 0.2, drumWidth * 0.45, (frame * CFrame.new(0, -size.Y * 0.1, 0)).Position, accent, neon)
			return
		end
		piece("Magazine", size, frame, DARK, plate)
		if energy then
			piece("MagazineCell", V(size.X * 0.5, size.Y * 0.7, size.Z + 0.02), frame, accent, neon, nil, 0.2)
			piece("MagazineRib", V(size.X + 0.02, 0.04, size.Z + 0.02), frame * CFrame.new(0, size.Y * 0.3, 0), STEEL, metal)
		else
			piece("MagazineWindow", V(size.X + 0.02, size.Y * 0.5, size.Z * 0.3), frame * CFrame.new(0, 0, 0), Color3.fromRGB(180, 210, 230), glass, nil, 0.5)
			for index = 0, 2 do
				piece("MagazineRound", V(size.X * 0.6, 0.08, 0.08), frame * CFrame.new(0, -size.Y * 0.2 + index * 0.13, 0), BRASS, metal)
			end
		end
		piece("MagazinePlate", V(size.X + 0.06, 0.08, size.Z + 0.06), frame * CFrame.new(0, -size.Y / 2 - 0.04, 0), STEEL, metal)
	end

	-- The holo puck: a short cylinder standing on a base with a floating ring reticle. The lens
	-- centre sits 0.24 above the "Sight" base, where the viewmodel lines the eye up.
	local function holoPuck(z, y)
		-- The mount, and the window you look through. Both were far too big: the hood came out 0.56
		-- studs across on a receiver 0.44 wide, so the sight was wider than the gun carrying it. A
		-- real red dot's window is a fraction of the receiver, not larger than the whole thing.
		piece("Sight", V(0.14, 0.05, 0.26), V(0, y + 0.05, z), DARK, metal)
		local size = variant.holo and 0.24 or 0.19
		-- The frame is a ring of posts with an open middle. It used to be a solid cylinder, which
		-- meant aiming down the sight put an opaque plate across the centre of the screen: you
		-- were looking at the back of your own optic rather than through it.
		-- Alternating depth matters more than it looks. Every post's front face points along the
		-- sight's axis, and turning a part about that axis leaves its front face in exactly the
		-- same plane — so a ring of identical posts at one depth puts twelve coplanar faces on top
		-- of each other, which the z-fight pass cannot separate. Staggering neighbours apart in
		-- depth is what fixes it; rotating them is only for looks.
		-- A squared hood with an open middle, which is what a real holographic sight actually has.
		--
		-- This was a ring of twelve small cubes. Twelve posts 0.066 wide around a circle whose
		-- circumference is 1.38 cover barely half of it, so what it read as was a dozen floating
		-- squares in a circle rather than a sight -- and staggering their depths to stop them
		-- z-fighting only made the gaps more obvious. Four bars have no gaps to fall between, and
		-- cost eight fewer parts.
		--
		-- Top and bottom run the full outer width and the sides fit between them, so every joint is
		-- two faces butting in opposite directions rather than two lying in the same plane.
		local half = size / 2
		-- A thin fixed bar rather than a fraction of the window, so shrinking the window doesn't
		-- fatten the frame around it in proportion.
		local bar = 0.03
		local hoodDepth = 0.13
		-- Brought down along with the hood. Its half-height used to be 0.28, so a centre at 0.29 sat
		-- it on the mount; at this size that same centre would leave the hood floating 0.065 clear
		-- of its own mount. Lower also puts the dot nearer the bore, which is where it belongs.
		local centreY = y + 0.21
		for _, side in ipairs({ -1, 1 }) do
			piece("SightHood", V(size + bar * 2, bar, hoodDepth), V(0, centreY + side * (half + bar / 2), z), DARK, metal)
			piece("SightHood", V(bar, size, hoodDepth), V(side * (half + bar / 2), centreY, z), DARK, metal)
		end
		-- Glass you can genuinely see through, and a reticle the size of a reticle. The dot was
		-- drawn at 40% of the lens, which covered whatever you were aiming at.
		-- Glass set inside the hood, square to match it, and a dot the size of a dot: it used to be
		-- drawn at 40% of the lens, which covered whatever you were trying to shoot.
		piece("SightLens", V(size, size, 0.02), V(0, centreY, z - hoodDepth / 2 + 0.05),
			Color3.fromRGB(150, 220, 200), glass, nil, 0.86)
		piece("SightDot", V(size * 0.1, size * 0.1, 0.02), V(0, centreY, z - hoodDepth / 2 + 0.02), DOT, neon, nil, 0.1)
	end

	-- A fat scope: a stepped tube that widens through two shoulders into an objective bell at the
	-- front and a shorter ocular bell at the back, carried on two machined steel rings that wear
	-- the rarity accent as a slim band rather than as the whole hoop. Glowing neon hoops around a
	-- plain dark pipe, with one squashed knob on top, were what made this read as a toy.
	--
	-- The bore does not have to be see-through: aiming a scoped gun hands over to the full-screen
	-- scope view once the gun is up to the eye. The part named Scope is still exactly where and
	-- what it was, though, because that is what the sight line anchors on.
	--
	-- Every ring butts end to end against the next one facing the opposite way, which is the one
	-- arrangement that cannot produce the coplanar same-facing pair the z-fight pass resolves.
	local function fatScope(z, y, length, diameter, mountY)
		local body = diameter
		local front = z - length / 2
		local back = z + length / 2

		tube("Scope", length, body, V(0, y, z), DARK, metal)

		-- Forward: two shoulders, the bell, a steel rim standing slightly proud, then the glass.
		tube("ScopeShoulder", 0.16, body * 1.10, V(0, y, front - 0.08), DARK, metal)
		tube("ScopeShoulder", 0.16, body * 1.21, V(0, y, front - 0.24), DARK, metal)
		tube("ScopeBell", 0.34, body * 1.34, V(0, y, front - 0.49), DARK, metal)
		tube("ScopeRim", 0.06, body * 1.38, V(0, y, front - 0.69), STEEL, metal)
		tube("ScopeLens", 0.04, body * 1.24, V(0, y, front - 0.74), accent:Lerp(LENS, 0.65), glass, 0.55)

		-- Behind: the ocular bell, its rim and the eyepiece glass.
		tube("ScopeOcular", 0.14, body * 1.09, V(0, y, back + 0.07), DARK, metal)
		tube("ScopeEyepiece", 0.26, body * 1.19, V(0, y, back + 0.27), DARK, metal)
		tube("ScopeRim", 0.06, body * 1.23, V(0, y, back + 0.43), STEEL, metal)
		tube("ScopeLens", 0.04, body * 1.10, V(0, y, back + 0.48), LENS, glass, 0.6)

		-- Turrets: elevation standing on top, windage out the side, each a base and a knurled cap.
		-- PartType.Cylinder runs along X, so the upright one is turned a quarter about Z; the old
		-- one was left along X with unequal cross-section, which made it a squashed ellipse.
		local turretZ = z + length * 0.06
		local turret = body * 0.62
		piece("ScopeTurret", V(0.17, turret, turret), CFrame.new(0, y + body / 2 + 0.085, turretZ) * CFrame.Angles(0, 0, math.pi / 2), DARK, metal,
			Enum.PartType.Cylinder)
		piece("ScopeTurretCap", V(0.11, turret * 0.76, turret * 0.76), CFrame.new(0, y + body / 2 + 0.225, turretZ) * CFrame.Angles(0, 0, math.pi / 2),
			STEEL, metal, Enum.PartType.Cylinder)
		axle("ScopeTurret", 0.17, turret, V(body / 2 + 0.085, y, turretZ), DARK, metal)
		axle("ScopeTurretCap", 0.11, turret * 0.76, V(body / 2 + 0.225, y, turretZ), STEEL, metal)

		for _, offset in ipairs({ -length * 0.3, length * 0.3 }) do
			tube("ScopeRing", 0.2, body + 0.12, V(0, y, z + offset), STEEL, metal)
			tube("ScopeRingBand", 0.07, body + 0.17, V(0, y, z + offset), accent, neon)
			local height = math.max(0.05, y - body / 2 - mountY)
			piece("ScopeMount", V(0.2, height, 0.22), V(0, mountY + height / 2, z + offset), DARK, metal)
		end
	end

	-- A trigger in its guard, hanging under a receiver whose underside is at `y`.
	local function trigger(z, y)
		piece("TriggerGuard", V(0.07, 0.06, 0.6), V(0, y - 0.32, z - 0.06), DARK, metal)
		piece("TriggerGuard", V(0.07, 0.32, 0.06), V(0, y - 0.17, z - 0.36), DARK, metal)
		piece("Trigger", V(0.05, 0.2, 0.06), tilted(V(0, y - 0.13, z - 0.05), 20), STEEL, metal)
	end

	-- On the right-hand side of a receiver `halfWidth` across, with a brass round showing.
	local function ejectionPort(z, y, halfWidth)
		piece("EjectionPort", V(0.03, 0.15, 0.36), V(halfWidth + 0.015, y, z), SHADOW, metal)
		piece("PortRound", V(0.02, 0.06, 0.2), V(halfWidth + 0.03, y, z), BRASS, metal)
	end

	local function chargingHandle(z, y, halfWidth)
		piece("ChargingHandle", V(0.18, 0.09, 0.2), V(-(halfWidth + 0.06), y, z), DARK, metal)
		piece("ChargingKnob", V(0.12, 0.14, 0.12), V(-(halfWidth + 0.14), y, z), RUBBER, rubber)
	end

	local function bipod(z)
		piece("BipodMount", V(0.24, 0.08, 0.18), V(0, -0.08, z), DARK, metal)
		for _, side in ipairs({ -1, 1 }) do
			piece("Bipod", V(0.06, 0.8, 0.06), CFrame.new(side * 0.16, -0.45, z) * CFrame.Angles(0, 0, side * 0.35), DARK, metal)
			piece("BipodFoot", V(0.12, 0.08, 0.16), V(side * 0.3, -0.84, z), RUBBER, rubber)
		end
	end

	-- A belt of rounds running from an ammo box into the feed.
	local function belt(from, to, links)
		for index = 0, links - 1 do
			local position = from:Lerp(to, index / math.max(1, links - 1))
			piece("Belt", V(0.1, 0.1, 0.22), CFrame.lookAt(position, position + (to - from)) * CFrame.Angles(0, math.pi / 2, 0), BRASS, metal)
		end
	end

	-- Under-barrel extras: laser (the viewmodel throws a beam from "LaserEmitter" when you aim),
	-- torch, foregrip knob.
	local function underBarrel(z, y)
		if variant.laser then
			piece("LaserBody", V(0.16, 0.12, 0.34), V(0.06, y - 0.06, z), DARK, metal)
			piece("LaserEmitter", V(0.05, 0.05, 0.02), V(0.06, y - 0.06, z - 0.18), LASER, neon)
		end
		if variant.light then
			tube("Torch", 0.4, 0.2, V(-0.06, y - 0.1, z), DARK, metal)
			tube("TorchLens", 0.02, 0.17, V(-0.06, y - 0.1, z - 0.21), Color3.fromRGB(255, 244, 200), neon)
		end
		if variant.foregrip then
			knobGrip(V(0, y - 0.32, z + 0.2))
		end
	end

	local function bayonet(z, y)
		if not variant.bayonet then
			return
		end
		piece("BayonetMount", V(0.12, 0.12, 0.2), V(0, y - 0.14, z), DARK, metal)
		piece("Bayonet", V(0.03, 0.1, 0.9), V(0, y - 0.16, z - 0.5), STEEL, metal)
		wedge("BayonetTip", V(0.03, 0.1, 0.2), V(0, y - 0.16, z - 1.05), STEEL, metal, math.pi)
	end

	-- Gold filigree: thin foil lines along the body.
	local function engraving(halfWidth, y, length, z)
		if not variant.engraved and not legendary then
			return
		end
		for _, side in ipairs({ -1, 1 }) do
			for index = 0, 1 do
				piece("Engraving", V(0.015, 0.03, length * 0.7), V(side * (halfWidth + 0.01), y + 0.1 - index * 0.2, z), GOLD, Enum.Material.Foil)
			end
		end
	end

	-- Fluting: shallow grooves along a barrel.
	local function fluting(z, y, length, diameter)
		if not variant.flutes then
			return
		end
		for index = 0, 3 do
			local angle = index / 4 * math.pi * 2 + math.pi / 4
			piece("Flute", V(0.03, 0.03, length), V(math.cos(angle) * diameter / 2, y + math.sin(angle) * diameter / 2, z), SHADOW, metal)
		end
	end

	----------------------------------------------------------------------------
	-- Silhouettes
	----------------------------------------------------------------------------

	local receiver, muzzle

	if style == "pistol" then
		-- A compact blaster-pistol: a rounded frame, a fat slide with a glowing charge window, a
		-- short shrouded barrel, an energy cell in the grip.
		local slideLength = variant.compact and 1.2 or 1.45
		local slideZ = variant.compact and -0.08 or -0.2
		receiver = pill("Receiver", V(0.255, 0.26, variant.compact and 1.1 or 1.3), V(0, -0.02, variant.compact and -0.02 or -0.12), DARK, trim)
		pill("Slide", V(0.32, 0.3, slideLength), V(0, 0.24, slideZ), color, material)
		wedge("SlideNose", V(0.32, 0.14, 0.26), V(0, 0.46, slideZ - slideLength / 2 + 0.13), color, material, 0)
		for index = 0, 3 do
			piece("SlideSerration", V(0.33, 0.22, 0.03), V(0, 0.24, 0.32 + index * 0.08), SHADOW, metal)
		end
		piece("SlideWindow", V(0.34, 0.1, 0.5), V(0, 0.24, slideZ - 0.1), accent, neon, nil, 0.25)
		piece("SlideSightRear", V(0.18, 0.09, 0.08), V(0, 0.44, 0.42), DARK, metal)
		piece("SlideSightFront", V(0.05, 0.11, 0.06), V(0, 0.45, slideZ - slideLength / 2 + 0.1), STEEL, metal)
		tube("Barrel", 0.3, 0.16, V(0, 0.2, slideZ - slideLength / 2 - 0.1), DARK, metal)
		piece("Rail", V(0.22, 0.05, 0.4), V(0, -0.165, -0.5), DARK, plate)
		underBarrel(-0.62, -0.16)
		ejectionPort(-0.15, 0.3, 0.16)
		piece("SlideRelease", V(0.05, 0.05, 0.16), V(-0.17, 0.1, 0.2), DARK, metal)
		coreLens(0.15, -0.02, 0.15, 0.16)
		roundGrip(V(0, -0.5, 0.32), -16, V(0.3, 0.74, 0.42))
		wedge("Beavertail", V(0.28, 0.1, 0.18), V(0, -0.08, 0.6), DARK, trim, math.pi)
		magazine(V(0.2, 0.3, 0.28), V(0, -0.8, 0.4), -16, true)
		piece("Hammer", V(0.08, 0.14, 0.1), V(0, 0.3, 0.58), DARK, trim)
		engraving(0.15, -0.02, 1.0, -0.12)
		trigger(0.02, -0.15)
		muzzle = V(0, 0.2, slideZ - slideLength / 2 - 0.26)
	elseif style == "revolver" then
		-- A hand cannon: a heavy rounded frame, a big fluted cylinder with glowing chambers, a
		-- vented rib over a thick barrel, wood grips.
		local barrelLength = variant.longBarrel and 1.9 or 1.3
		receiver = pill("Receiver", V(0.306, 0.5, 0.95), V(0, 0.05, 0), color, material)
		tube("Drum", 0.56, 0.62, V(0, 0.05, -0.34), DARK, plate)
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			piece("DrumFlute", V(0.08, 0.08, 0.5), V(math.cos(angle) * 0.29, 0.05 + math.sin(angle) * 0.29, -0.34), SHADOW, metal)
			piece("DrumChamber", V(0.02, 0.11, 0.11), CFrame.new(math.cos(angle) * 0.18, 0.05 + math.sin(angle) * 0.18, -0.63) * CFrame.Angles(0, math.pi / 2, 0),
				accent, neon, Enum.PartType.Cylinder)
		end
		tube("Barrel", barrelLength, 0.24, V(0, 0.14, -0.6 - barrelLength / 2), DARK, metal)
		piece("Rib", V(0.12, 0.1, barrelLength - 0.05), V(0, 0.3, -0.55 - barrelLength / 2), color, material)
		for index = 0, math.floor(barrelLength / 0.3) - 1 do
			piece("RibVent", V(0.14, 0.04, 0.12), V(0, 0.36, -0.75 - index * 0.3), DARK, metal)
		end
		piece("EjectorRod", V(0.07, 0.07, barrelLength * 0.6), V(0, -0.03, -0.55 - barrelLength * 0.35), STEEL, metal)
		piece("FrontSight", V(0.06, 0.16, 0.1), V(0, 0.4, -0.55 - barrelLength + 0.1), STEEL, metal)
		piece("RearSight", V(0.16, 0.06, 0.1), V(0, 0.33, 0.32), DARK, metal)
		coreLens(0.15, 0.05, 0.18, 0.2)
		roundGrip(V(0, -0.56, 0.44), -20, V(0.3, 0.84, 0.42), WOOD, planks)
		piece("Hammer", V(0.1, 0.22, 0.16), V(0, 0.38, 0.4), DARK, trim)
		engraving(0.18, 0.05, 0.85, 0)
		trigger(0.12, -0.2)
		bellMuzzle(-0.6 - barrelLength - 0.02, 0.14, 0.24)
		muzzle = V(0, 0.14, -0.6 - barrelLength - 0.36)
	elseif style == "smg" then
		-- A bullpup-ish burst gun: a fat rounded body with the cell magazine behind the grip, a
		-- short finned shroud and a stubby stock.
		receiver = pill("Receiver", V(0.357, 0.52, 1.6), V(0, 0, 0), color, material)
		spine(-0.1, 1.3, 0.26)
		wedge("ReceiverNose", V(0.42, 0.16, 0.3), V(0, 0.34, -0.65), color, material, 0)
		finnedShroud(-1.1, 0.7, 0.32, 0.06)
		tube("Barrel", 0.35, 0.16, V(0, 0.06, -1.6), DARK, metal)
		if variant.suppressor then
			suppressor(-2.05, 0.06, 0.28)
			muzzle = V(0, 0.06, -2.5)
		else
			crownMuzzle(-1.9, 0.06, 0.24)
			muzzle = V(0, 0.06, -2.12)
		end
		magazine(V(0.24, 0.95, 0.34), V(0, -0.82, -0.3), 4, true)
		coreLens(0.35, 0, 0.21, 0.22)
		roundGrip(V(0, -0.62, 0.45), -12)
		knobGrip(V(0, -0.5, -0.95))
		if variant.skeletonStock then
			for _, y in ipairs({ 0.12, -0.28 }) do
				piece("StockRod", V(0.08, 0.08, 1.05), V(0, y, 1.22), DARK, metal)
			end
			piece("StockRod", V(0.08, 0.48, 0.08), V(0, -0.08, 1.7), DARK, metal)
			piece("Buttpad", V(0.3, 0.56, 0.14), V(0, -0.08, 1.8), RUBBER, rubber)
		else
			tubeStock(1.25, -0.05, 1.0, 0.5)
		end
		piece("Rail", V(0.24, 0.06, 1.0), V(0, 0.29, -0.15), DARK, plate)
		holoPuck(-0.1, 0.32)
		underBarrel(-0.62, -0.28)
		chargingHandle(0.35, 0.12, 0.21)
		piece("Selector", V(0.05, 0.05, 0.14), CFrame.new(-0.22, -0.2, 0.35) * CFrame.Angles(0.5, 0, 0), STEEL, metal)
		ejectionPort(0.1, 0.1, 0.21)
		engraving(0.21, 0, 1.2, 0)
		trigger(0.15, -0.44)
	elseif style == "dmr" then
		-- A long rounded rifle with a fat scope, a vented handguard and a working bolt.
		receiver = pill("Receiver", V(0.374, 0.58, 2.2), V(0, 0, 0), color, material)
		spine(-0.1, 1.6, 0.29)
		finnedShroud(-1.75, 1.3, 0.38, 0.05, "Handguard")
		tube("Barrel", 1.5, 0.2, V(0, 0.08, -3.0), DARK, metal)
		fluting(-3.0, 0.08, 1.3, 0.2)
		crownMuzzle(-3.85, 0.08, 0.28)
		fatScope(-0.25, 0.68, 1.3, 0.32, 0.29)
		tubeStock(1.7, -0.1, 1.2, 0.6)
		magazine(V(0.3, 0.5, 0.42), V(0, -0.74, -0.3), 6, false)
		coreLens(0.5, 0, 0.22, 0.24)
		roundGrip(V(0, -0.64, 0.55), -14)
		underBarrel(-1.3, -0.16)
		piece("Bolt", V(0.32, 0.08, 0.08), V(0.32, 0.2, 0.45), STEEL, metal)
		piece("BoltKnob", V(0.16, 0.16, 0.16), V(0.5, 0.2, 0.45), RUBBER, rubber, Enum.PartType.Ball)
		ejectionPort(0.2, 0.12, 0.22)
		engraving(0.22, 0, 1.6, 0)
		trigger(0.25, -0.48)
		muzzle = V(0, 0.08, -4.08)
	elseif style == "shotgun" then
		-- A chunky pump gun: a broad rounded body, a big barrel over a fat magazine tube, a
		-- ribbed pump, shells on the side.
		receiver = pill("Receiver", V(0.391, 0.54, 1.45), V(0, 0, 0), color, material)
		spine(0, 1.1, 0.27)
		tube("Barrel", 2.1, 0.3, V(0, 0.16, -1.8), DARK, metal)
		if variant.heatShield then
			finnedShroud(-1.5, 1.1, 0.4, 0.16, "Shroud")
		end
		if variant.drum then
			magazine(V(0.3, 0.5, 0.5), V(0, -0.58, -0.3), 0, false)
			tube("MagTube", 0.9, 0.24, V(0, -0.12, -1.98), DARK, trim)
		else
			tube("MagTube", 1.7, 0.24, V(0, -0.12, -1.6), DARK, trim)
		end
		tube("MagCap", 0.14, 0.28, V(0, -0.12, -2.5), STEEL, metal)
		pill("Pump", V(0.4, 0.36, 0.8), V(0, -0.12, -1.45), furnitureColor, furnitureMaterial)
		for index = 0, 3 do
			piece("PumpGroove", V(0.42, 0.32, 0.04), V(0, -0.12, -1.18 - index * 0.2), SHADOW, metal)
		end
		piece("FrontBead", V(0.08, 0.08, 0.08), V(0, 0.34, -2.8), BRASS, metal, Enum.PartType.Ball)
		piece("RearSight", V(0.16, 0.06, 0.1), V(0, 0.34, 0.5), DARK, metal)
		solidStock(1.35, -0.18, 1.3, 0.6, furnitureColor, furnitureMaterial)
		roundGrip(V(0, -0.46, 0.56), -14, V(0.32, 0.6, 0.4), furnitureColor, furnitureMaterial)
		piece("ShellSaddle", V(0.06, 0.26, 0.74), V(-0.26, 0.02, 0.1), DARK, metal)
		for index = 0, 3 do
			local z = -0.17 + index * 0.18
			piece("SpareShell", V(0.26, 0.12, 0.12), CFrame.new(-0.32, 0.02, z) * CFrame.Angles(0, 0, math.pi / 2), accent, plastic, Enum.PartType.Cylinder)
			piece("SpareShellCap", V(0.06, 0.13, 0.13), CFrame.new(-0.32, -0.13, z) * CFrame.Angles(0, 0, math.pi / 2), BRASS, metal, Enum.PartType.Cylinder)
		end
		coreLens(0.3, 0, 0.23, 0.22)
		underBarrel(-1.0, -0.26)
		ejectionPort(-0.05, 0.08, 0.23)
		engraving(0.23, 0, 1.1, 0)
		trigger(0.25, -0.27)
		muzzle = V(0, 0.16, -2.86)
	elseif style == "sniper" then
		-- The long gun: a slim rounded body, a very long fluted barrel with a crown, a big scope,
		-- bipod, and the bolt.
		local barrelLength = variant.longBarrel and 3.0 or 2.5
		receiver = pill("Receiver", V(0.357, 0.54, 2.0), V(0, 0, 0), color, material)
		spine(0, 1.5, 0.27)
		tube("Barrel", barrelLength, 0.22, V(0, 0.08, -1.0 - barrelLength / 2), DARK, metal)
		fluting(-1.0 - barrelLength / 2, 0.08, barrelLength - 0.4, 0.22)
		for index = 0, 2 do
			tube("BarrelRing", 0.08, 0.3, V(0, 0.08, -1.3 - index * 0.7), STEEL, metal)
		end
		if variant.ghillie then
			for index = 0, 2 do
				piece("Rag", V(0.34, 0.1, 0.16), CFrame.new(0, 0.08, -1.5 - index * 0.7) * CFrame.Angles(0, 0, 0.4 * (index - 1)), CAMO, Enum.Material.Fabric)
			end
		end
		crownMuzzle(-1.15 - barrelLength, 0.08, 0.32)
		fatScope(-0.2, 0.72, 1.7, 0.4, 0.27)
		tubeStock(1.8, -0.12, 1.6, 0.64)
		piece("Bolt", V(0.36, 0.08, 0.08), V(0.34, 0.2, 0.45), STEEL, metal)
		piece("BoltKnob", V(0.18, 0.18, 0.18), V(0.54, 0.2, 0.45), RUBBER, rubber, Enum.PartType.Ball)
		magazine(V(0.3, 0.4, 0.5), V(0, -0.48, -0.2), 0, false)
		coreLens(0.5, 0, 0.21, 0.22)
		roundGrip(V(0, -0.6, 0.6), -14)
		ejectionPort(0.1, 0.12, 0.21)
		bipod(-2.7)
		engraving(0.21, 0, 1.5, 0)
		trigger(0.3, -0.27)
		muzzle = V(0, 0.08, -1.35 - barrelLength)
	elseif style == "blaster" then
		-- A bubble gun: a ball body, a glass tank of bubbling liquid, a bell nozzle, fins.
		receiver = piece("Receiver", V(0.74, 0.74, 1.34), V(0, 0.05, -0.1), color, material)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = receiver
		local tankSize = variant.bigTank and 0.64 or 0.46
		tube("Tank", variant.bigTank and 0.84 or 0.62, tankSize, V(0, 0.42 + tankSize / 2, 0.1), Color3.fromRGB(120, 230, 255), glass, 0.3)
		for index = 1, 4 do
			piece("TankBubble", V(0.09, 0.09, 0.09), V((index - 2.5) * 0.08, 0.5 + index * 0.05, 0.1 + (index - 2) * 0.1), Color3.fromRGB(210, 250, 255), neon,
				Enum.PartType.Ball)
		end
		for _, z in ipairs({ -0.22, 0.42 }) do
			tube("TankCap", 0.1, tankSize + 0.04, V(0, 0.42 + tankSize / 2, z), STEEL, metal)
		end
		piece("TankGauge", V(0.03, 0.16, 0.16), CFrame.new(0, 0.3, -0.5) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(200, 250, 255), glass, Enum.PartType.Cylinder, 0.2)
		tube("NozzleRing", 0.1, 0.46, V(0, 0.05, -0.76), DARK, metal)
		tube("Nozzle", 0.32, 0.36, V(0, 0.05, -0.9), accent, neon)
		-- A dot forward of the tank: the blasters had no sight of any kind, so aiming fell back
		-- to a fixed guess above the grip and lined up with nothing.
		holoPuck(-0.45, 0.32)
		bellMuzzle(-1.08, 0.05, 0.36)
		for _, side in ipairs({ -1, 1 }) do
			wedge("Fin", V(0.06, 0.42, 0.5), V(side * 0.4, 0.22, 0.28), color, material, 0, -side * 0.5)
		end
		coreLens(-0.1, 0.05, 0.37, 0.3)
		roundGrip(V(0, -0.5, 0.3), -12, V(0.3, 0.66, 0.38))
		trigger(0.05, -0.3)
		muzzle = V(0, 0.05, -1.4)
	elseif style == "launcher" and variant.sixShot then
		-- A revolving six-tube launcher: a short body with the cylinder of tubes in front.
		receiver = tube("Receiver", 1.2, 0.54, V(0, 0.1, 0.5), color, material)
		tube("Drum", 1.1, 1.04, V(0, 0.1, -0.6), DARK, plate)
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			tube("DrumTube", 1.2, 0.3, V(math.cos(angle) * 0.33, 0.1 + math.sin(angle) * 0.33, -0.62), SHADOW, metal)
			tube("DrumTubeRim", 0.06, 0.34, V(math.cos(angle) * 0.33, 0.1 + math.sin(angle) * 0.33, -1.2), STEEL, metal)
		end
		tube("DrumAxle", 1.4, 0.12, V(0, 0.1, -0.6), STEEL, metal)
		tube("RearFlare", 0.3, 0.7, V(0, 0.1, 1.15), DARK, plate)
		tube("RocketBody", 0.3, 0.24, V(0, 0.43, -1.25), Color3.fromRGB(90, 110, 70), plastic)
		piece("RocketTip", V(0.24, 0.24, 0.24), V(0, 0.43, -1.42), Color3.fromRGB(220, 60, 50), plastic, Enum.PartType.Ball)
		roundGrip(V(0, -0.36, 0.5), -10, V(0.3, 0.6, 0.38))
		knobGrip(V(0, -0.72, -0.6))
		piece("ShoulderPad", V(0.2, 0.5, 0.7), V(-0.3, 0.1, 0.8), RUBBER, rubber)
		piece("Sight", V(0.18, 0.34, 0.2), V(0, 0.66, 0.3), DARK, trim)
		piece("SightLens", V(0.12, 0.12, 0.03), V(0, 0.74, 0.19), LENS, glass, nil, 0.3)
		trigger(0.3, -0.16)
		muzzle = V(0, 0.43, -1.5)
	elseif style == "launcher" then
		-- A rocket tube: a fat rounded tube with glowing rings and a warning band, the rocket's
		-- red nose out of the front, a shoulder rest and two grips.
		receiver = tube("Receiver", 2.6, 0.74, V(0, 0.1, -0.2), color, material)
		tube("FrontRing", 0.22, 0.86, V(0, 0.1, -1.5), STEEL, metal)
		tube("RearFlare", 0.32, 0.9, V(0, 0.1, 1.12), DARK, plate)
		for _, z in ipairs({ -0.6, 0.4 }) do
			tube("Band", 0.14, 0.78, V(0, 0.1, z), DARK, metal)
		end
		for index = 0, 2 do
			piece("Stripe", V(0.76, 0.06, 0.06), CFrame.new(0, 0.1, 0.7 - index * 0.14) * CFrame.Angles(0, 0, 0.5), Color3.fromRGB(240, 200, 40), plastic)
		end
		piece("Strap", V(0.05, 0.16, 1.4), V(0, -0.26, 0.1), LEATHER, leather)
		tube("RocketBody", 0.5, 0.48, V(0, 0.1, -1.62), Color3.fromRGB(90, 110, 70), plastic)
		piece("RocketTip", V(0.48, 0.48, 0.48), V(0, 0.1, -1.9), Color3.fromRGB(220, 60, 50), plastic, Enum.PartType.Ball)
		roundGrip(V(0, -0.52, 0.1), -10, V(0.3, 0.6, 0.38))
		knobGrip(V(0, -0.6, -0.8))
		piece("ShoulderPad", V(0.2, 0.5, 0.7), V(-0.42, 0.1, 0.5), RUBBER, rubber)
		piece("Sight", V(0.18, 0.34, 0.2), V(0.38, 0.52, -0.4), DARK, trim)
		piece("SightLens", V(0.12, 0.12, 0.03), V(0.38, 0.6, -0.51), LENS, glass, nil, 0.3)
		trigger(0.05, -0.27)
		muzzle = V(0, 0.1, -2.0)
	elseif style == "lmg" then
		-- The heavy: a broad rounded body with a feed cover, a long finned shroud, a belt from
		-- a box, carry handle, bipod.
		receiver = pill("Receiver", V(0.493, 0.64, 2.1), V(0, 0, 0), color, material)
		piece("FeedCover", V(0.52, 0.12, 0.9), V(0, 0.38, 0.2), DARK, plate)
		finnedShroud(-1.8, 1.4, 0.44, 0.08)
		tube("Barrel", 0.8, 0.2, V(0, 0.08, -2.9), DARK, metal)
		crownMuzzle(-3.4, 0.08, 0.3)
		piece("AmmoBox", V(0.52, 0.6, 0.64), V(0.26, -0.58, -0.25), DARK, plate)
		piece("AmmoBoxLid", V(0.54, 0.06, 0.66), V(0.26, -0.26, -0.25), STEEL, metal)
		piece("AmmoBoxGlow", V(0.1, 0.4, 0.5), V(0.53, -0.58, -0.25), accent, neon, nil, 0.3)
		belt(V(0.3, -0.2, -0.1), V(0.3, 0.2, 0.05), 5)
		piece("Handle", V(0.12, 0.12, 0.8), V(0, 0.66, -0.3), DARK, trim)
		for _, z in ipairs({ -0.62, 0.02 }) do
			piece("HandlePost", V(0.08, 0.26, 0.08), V(0, 0.52, z), DARK, trim)
		end
		tubeStock(1.6, -0.1, 1.1, 0.62)
		roundGrip(V(0, -0.66, 0.6), -14)
		bipod(-2.8)
		piece("Rail", V(0.24, 0.06, 0.6), V(0, 0.45, 0.5), DARK, plate)
		holoPuck(0.55, 0.48)
		coreLens(0.55, 0, 0.29, 0.26)
		ejectionPort(0.2, 0.05, 0.29)
		engraving(0.29, 0, 1.6, 0)
		trigger(0.3, -0.33)
		muzzle = V(0, 0.08, -3.6)
	elseif style == "minigun" then
		-- The rotary: a drum body, a motor, six barrels in clamps that spin, a box on the side.
		receiver = pill("Receiver", V(0.527, 0.72, 1.4), V(0, 0, 0), color, material)
		tube("Motor", 0.6, 0.7, V(0, 0.05, -0.95), DARK, metal)
		for index = 0, 5 do
			local angle = index / 6 * math.pi * 2
			tube("Barrel", 2.2, 0.15, V(math.cos(angle) * 0.21, 0.05 + math.sin(angle) * 0.21, -2.3), DARK, metal)
		end
		tube("BarrelClamp", 0.12, 0.66, V(0, 0.05, -1.6), DARK, trim)
		tube("BarrelClamp", 0.12, 0.66, V(0, 0.05, -2.6), STEEL, metal)
		tube("BarrelClamp", 0.14, 0.68, V(0, 0.05, -3.3), legendary and GOLD or DARK, legendary and Enum.Material.Foil or trim)
		tube("BarrelClampHub", 0.16, 0.24, V(0, 0.05, -3.4), STEEL, metal)
		piece("AmmoBox", V(0.4, 0.62, 0.72), V(0.52, -0.3, 0.2), DARK, plate)
		piece("AmmoBoxGlow", V(0.02, 0.4, 0.5), V(0.73, -0.3, 0.2), accent, neon, nil, 0.3)
		belt(V(0.5, 0.05, 0.1), V(0.3, 0.2, -0.4), 5)
		piece("Handle", V(0.12, 0.12, 0.7), V(0, 0.64, 0), DARK, trim)
		for _, z in ipairs({ -0.28, 0.28 }) do
			piece("HandlePost", V(0.08, 0.26, 0.08), V(0, 0.5, z), DARK, trim)
		end
		for index = 0, 2 do
			piece("MotorVent", V(0.66, 0.06, 0.08), V(0, 0.22 - index * 0.12, -0.95), DARK, metal)
		end
		coreLens(0.2, 0, 0.31, 0.28)
		roundGrip(V(0, -0.6, 0.4), -10)
		trigger(0.1, -0.36)
		muzzle = V(0, 0.05, -3.45)
	elseif style == "cannon" then
		-- The golden cannon: a rounded barrel in gold bands, a flared bell, a knob, a lit fuse.
		receiver = tube("Receiver", 2.0, 0.58, V(0, 0.1, -0.5), color, material)
		tube("Bell", 0.44, 0.86, V(0, 0.1, -1.6), GOLD, Enum.Material.Foil)
		tube("BellLip", 0.1, 0.94, V(0, 0.1, -1.84), GOLD, Enum.Material.Foil)
		tube("BellGlow", 0.04, 0.62, V(0, 0.1, -1.86), accent, neon)
		tube("RingFront", 0.12, 0.68, V(0, 0.1, -0.9), GOLD, Enum.Material.Foil)
		tube("RingMid", 0.1, 0.64, V(0, 0.1, -0.35), GOLD, Enum.Material.Foil)
		-- Sat between the middle and back bands, clear of both: the cannon had nothing to aim
		-- with at all.
		holoPuck(-0.05, 0.34)
		tube("RingBack", 0.12, 0.68, V(0, 0.1, 0.25), GOLD, Enum.Material.Foil)
		piece("Knob", V(0.44, 0.44, 0.44), V(0, 0.1, 0.62), GOLD, Enum.Material.Foil, Enum.PartType.Ball)
		piece("KnobCap", V(0.2, 0.2, 0.2), V(0, 0.1, 0.86), GOLD, Enum.Material.Foil, Enum.PartType.Ball)
		piece("Fuse", V(0.05, 0.3, 0.05), tilted(V(0, 0.48, 0.22), -25), Color3.fromRGB(120, 90, 60), Enum.Material.Fabric)
		piece("FuseSpark", V(0.14, 0.14, 0.14), V(0, 0.62, 0.3), Color3.fromRGB(255, 170, 40), neon, Enum.PartType.Ball)
		roundGrip(V(0, -0.5, 0.2), -16, V(0.32, 0.72, 0.42), WOOD, planks)
		trigger(0, -0.19)
		muzzle = V(0, 0.1, -1.94)
	elseif style == "railgun" then
		-- The railgun: a slim rounded body between two charge rails, coils glowing down the length,
		-- capacitors on the side, a fat scope.
		receiver = pill("Receiver", V(0.391, 0.56, 2.0), V(0, 0, 0), color, material)
		spine(0, 1.4, 0.28)
		for _, side in ipairs({ -1, 1 }) do
			piece("ChargeRail", V(0.12, 0.16, 2.4), V(side * 0.19, 0.1, -2.1), DARK, plate)
			piece("ChargeRailGlow", V(0.04, 0.06, 2.2), V(side * 0.26, 0.1, -2.1), accent, neon)
		end
		for _, z in ipairs({ -1.3, -1.8, -2.3, -2.8 }) do
			tube("Coil", 0.16, 0.54, V(0, 0.1, z), accent, neon)
		end
		for index = 0, 2 do
			piece("Capacitor", V(0.12, 0.22, 0.32), V(-0.3, 0.02, 0.5 - index * 0.38), accent, neon)
		end
		piece("Cable", V(0.05, 0.05, 1.2), CFrame.new(-0.27, -0.2, -0.6) * CFrame.Angles(0.2, 0, 0), DARK, Enum.Material.Fabric)
		fatScope(-0.2, 0.64, 1.0, 0.32, 0.28)
		tubeStock(1.55, -0.1, 1.2, 0.56)
		coreLens(0.45, 0, 0.23, 0.24)
		roundGrip(V(0, -0.6, 0.5), -14)
		ejectionPort(0.3, 0.1, 0.23)
		engraving(0.23, 0, 1.5, 0)
		trigger(0.2, -0.29)
		muzzle = V(0, 0.1, -3.35)
	elseif style == "crossbow" then
		-- The crossbow: a rounded stock-body, a riser with two swept limbs and a glowing string,
		-- the loaded bolt, a stirrup, holo puck.
		receiver = pill("Receiver", V(0.306, 0.38, 2.0), V(0, 0, -0.2), color, material)
		piece("Groove", V(0.12, 0.04, 1.8), V(0, 0.21, -0.4), SHADOW, metal)
		piece("Riser", V(0.5, 0.32, 0.28), V(0, 0.05, -1.25), DARK, metal)
		local latch = V(0, 0.14, -0.3)
		for _, side in ipairs({ -1, 1 }) do
			-- Set wide enough that a limb shares no footprint with the stock under it. At 0.72 its
			-- inner edge landed exactly on the stock's outer edge with their faces coplanar, and
			-- the z-fight pass had no room to grow either one apart.
			piece("Limb", V(1.1, 0.12, 0.16), CFrame.new(side * 0.85, 0.05, -1.1) * CFrame.Angles(0, side * math.rad(-18), 0), color:Lerp(DARK, 0.35), material)
			local tipPosition = V(side * 1.39, 0.1, -0.93)
			piece("LimbTip", V(0.12, 0.24, 0.12), tipPosition, STEEL, metal)
			piece("String", V(0.03, 0.03, (tipPosition - latch).Magnitude), CFrame.lookAt((tipPosition + latch) / 2, tipPosition), STEEL, metal)
		end
		piece("Latch", V(0.22, 0.14, 0.16), V(0, 0.23, -0.26), STEEL, metal)
		tube("RocketShaft", 1.3, 0.06, V(0, 0.28, -0.95), WOOD, planks)
		piece("RocketHead", V(0.12, 0.12, 0.22), V(0, 0.28, -1.66), STEEL, metal)
		for _, side in ipairs({ -1, 1 }) do
			piece("RocketFletch", V(0.02, 0.12, 0.24), V(side * 0.05, 0.31, -0.42), accent, Enum.Material.Fabric)
		end
		piece("Stirrup", V(0.5, 0.06, 0.06), V(0, -0.22, -1.55), DARK, metal)
		for _, side in ipairs({ -1, 1 }) do
			piece("Stirrup", V(0.06, 0.3, 0.06), V(side * 0.22, -0.08, -1.5), DARK, metal)
		end
		solidStock(1.25, -0.12, 0.9, 0.5, WOOD, planks)
		roundGrip(V(0, -0.46, 0.4), -14, nil, WOOD, planks)
		knobGrip(V(0, -0.36, -0.7))
		coreLens(0.3, 0, 0.18, 0.2)
		holoPuck(0.3, 0.19)
		trigger(0.15, -0.19)
		muzzle = V(0, 0.28, -1.8)
	elseif style == "doublebarrel" then
		-- Two big barrels side by side over a hinge, wood everywhere, brass and gold.
		local barrelLength = variant.sawnOff and 1.2 or 2.2
		receiver = pill("Receiver", V(0.408, 0.46, 0.92), V(0, 0, 0), color, material)
		for _, side in ipairs({ -1, 1 }) do
			tube("Barrel", barrelLength, 0.26, V(side * 0.135, 0.12, -0.4 - barrelLength / 2), DARK, metal)
			tube("BarrelMuzzle", 0.12, 0.3, V(side * 0.135, 0.12, -0.46 - barrelLength), STEEL, metal)
			piece("SidePlate", V(0.02, 0.3, 0.6), V(side * 0.25, 0, 0.05), legendary and GOLD or STEEL, legendary and Enum.Material.Foil or metal)
			piece("Hammer", V(0.07, 0.18, 0.12), tilted(V(side * 0.12, 0.28, 0.4), 25), DARK, trim)
		end
		piece("Rib", V(0.08, 0.06, barrelLength - 0.1), V(0, 0.27, -0.4 - barrelLength / 2), color, material)
		piece("FrontBead", V(0.07, 0.07, 0.07), V(0, 0.32, -0.4 - barrelLength), BRASS, metal, Enum.PartType.Ball)
		piece("Hinge", V(0.52, 0.16, 0.16), V(0, -0.05, -0.42), STEEL, metal, Enum.PartType.Cylinder)
		local foreLength = math.min(0.9, barrelLength * 0.45)
		pill("ForeGrip", V(0.44, 0.24, foreLength), V(0, -0.1, -0.45 - foreLength / 2 - 0.25), WOOD, planks)
		piece("TopLever", V(0.08, 0.06, 0.3), CFrame.new(0, 0.25, 0.28) * CFrame.Angles(0, math.rad(20), 0), STEEL, metal)
		if variant.sawnOff then
			roundGrip(V(0, -0.42, 0.58), -30, V(0.32, 0.62, 0.4), WOOD, planks)
			piece("Tape", V(0.36, 0.14, 0.44), tilted(V(0, -0.32, 0.55), -30), Color3.fromRGB(60, 60, 64), Enum.Material.Fabric)
		else
			solidStock(1.1, -0.22, 1.3, 0.55, WOOD, planks)
			roundGrip(V(0, -0.4, 0.52), -24, V(0.3, 0.55, 0.38), WOOD, planks)
		end
		engraving(0.24, 0.08, 0.8, 0.05)
		trigger(0.2, -0.23)
		muzzle = V(0, 0.12, -0.52 - barrelLength)
	else
		-- The rifle: a rounded body with a spine, a vented handguard, a windowed magazine, a
		-- tube stock and a holo puck.
		local handguardLength = variant.compact and 0.8 or 1.2
		local barrelLength = variant.compact and 0.6 or 0.9
		local handguardZ = -0.9 - handguardLength / 2
		receiver = pill("Receiver", V(0.374, 0.52, 1.9), V(0, 0.02, 0), color, material)
		spine(-0.1, 1.4, 0.28)
		wedge("ReceiverNose", V(0.44, 0.18, 0.34), V(0, 0.37, -0.78), color, material, 0)
		finnedShroud(handguardZ, handguardLength, 0.4, 0.02, "Handguard")
		local gasZ = handguardZ - handguardLength / 2 - 0.1
		piece("GasBlock", V(0.2, 0.28, 0.2), V(0, 0.1, gasZ), DARK, metal)
		piece("FrontSight", V(0.06, 0.34, 0.08), V(0, 0.34, gasZ), STEEL, metal)
		tube("Barrel", barrelLength, 0.18, V(0, 0.08, gasZ - 0.1 - barrelLength / 2), DARK, metal)
		fluting(gasZ - 0.1 - barrelLength / 2, 0.08, barrelLength - 0.2, 0.18)
		local brakeZ = gasZ - 0.2 - barrelLength - 0.1
		crownMuzzle(brakeZ, 0.08, 0.26)
		bayonet(brakeZ + 0.1, 0.08)
		magazine(V(0.28, 0.6, 0.42), V(0, -0.64, -0.35), 12, false)
		piece("MagRelease", V(0.06, 0.08, 0.1), V(0.23, -0.28, -0.05), DARK, metal)
		piece("Selector", V(0.05, 0.05, 0.16), CFrame.new(-0.23, -0.15, 0.45) * CFrame.Angles(0.6, 0, 0), STEEL, metal)
		coreLens(0.4, 0.02, 0.22, 0.24)
		roundGrip(V(0, -0.66, 0.5), -14, V(0.34, 0.75, 0.4))
		if variant.woodFurniture then
			solidStock(1.45, -0.08, 1.1, 0.55, WOOD, planks)
		else
			tubeStock(1.5, -0.08, 1.15, 0.56)
		end
		piece("Rail", V(0.26, 0.06, 1.3), V(0, 0.3, -0.25), DARK, plate)
		holoPuck(-0.2, 0.34)
		underBarrel(handguardZ - 0.2, -0.16)
		chargingHandle(0.85, 0.32, 0.22)
		piece("ForwardAssist", V(0.08, 0.1, 0.16), V(0.24, 0.12, 0.55), DARK, metal)
		engraving(0.22, 0.02, 1.6, 0)
		ejectionPort(0.15, 0.1, 0.22)
		trigger(0.2, -0.47)
		muzzle = V(0, 0.08, brakeZ - 0.3)
	end

	----------------------------------------------------------------------------
	-- Sights
	----------------------------------------------------------------------------

	-- Aiming lines a single named part up with the centre of the screen. That part is `AimPoint`,
	-- placed at the end of this section on the gun's own line of sight; the client keeps the old
	-- name list (Scope, Sight, SlideSightRear, RearSight, Rail, Handle, Rib) behind it only as a
	-- fallback. A gun with a rear sight but nothing up front gives you nothing to line it against,
	-- which is what the blocks below fix; `tools/sight_probe.lua` found three guns with no anchor
	-- at all and ten with a rear sight and no front one.
	local function hasPiece(...)
		for _, name in ipairs({ ... }) do
			if model:FindFirstChild(name, true) then
				return true
			end
		end
		return false
	end

	-- Scoped guns are aimed through the scope, so a blade would be useless there and would sit
	-- in front of the glass.
	if muzzle and not hasPiece("Scope") and not hasPiece("FrontSight", "SlideSightFront", "MuzzleProng") then
		piece("FrontSightPost", V(0.05, 0.13, 0.07), V(muzzle.X, muzzle.Y + 0.09, muzzle.Z + 0.34), DARK, metal)
		piece("FrontSight", V(0.07, 0.11, 0.09), V(muzzle.X, muzzle.Y + 0.2, muzzle.Z + 0.34), STEEL, metal)
	end

	-- One anchor per gun, sitting exactly on that gun's own line of sight.
	--
	-- Aiming used to take the first of Scope/Sight/SlideSightRear/RearSight/Rail/Handle/Rib it
	-- found and raise it by a constant chosen per NAME. One constant cannot be right across
	-- fifteen silhouettes, and measuring all 27 showed 18 of the 22 iron-sighted guns off: the
	-- chaingun aimed through its carry handle, 0.68 studs above its own front post, and the
	-- launcher was 0.38 out sideways as well. Only the two pistols and the two shotguns lined up.
	--
	-- So the builder marks the line instead of the client guessing at it. AimPoint is invisible,
	-- costs one part, and is what the viewmodel puts on the crosshair.
	-- The line is taken FROM the gun, never imposed on it. A red dot aims through its dot, a scope
	-- down its tube, and everything else over its own front sight, exactly where that sight was
	-- authored. Nothing on the barrel moves.
	--
	-- An earlier version did the opposite: it computed a line from the bore and then dragged every
	-- sight onto it, which hoisted the LMG's muzzle prong half a stud clear of its own barrel and
	-- propped it up on a post. The numbers lined up perfectly and the silhouettes were ruined. If
	-- the geometry and the aim disagree, move the aim.
	local aimX, aimY
	local dot = model:FindFirstChild("SightDot", true)
	local scopeTube = model:FindFirstChild("Scope", true)
	local front
	for _, name in ipairs({ "FrontSight", "SlideSightFront", "MuzzleProng", "FrontBead" }) do
		front = front or model:FindFirstChild(name, true)
	end
	if dot then
		aimX, aimY = dot.Position.X, dot.Position.Y
	elseif scopeTube then
		aimX, aimY = scopeTube.Position.X, scopeTube.Position.Y
	elseif front then
		aimX, aimY = front.Position.X, front.Position.Y + front.Size.Y / 2
	else
		aimX = muzzle and muzzle.X or 0
		aimY = (muzzle and muzzle.Y or 0.08) + 0.26
	end

	-- Only the rear notch is nudged to agree. It is a few hundredths of a stud across and sits on
	-- the receiver, so moving it costs nothing you can see -- unlike a front post on a barrel.
	if not scopeTube and not dot then
		for _, name in ipairs({ "SlideSightRear", "RearSight" }) do
			local part = model:FindFirstChild(name, true)
			if part then
				local top = part.Position.Y + part.Size.Y / 2
				part.CFrame = part.CFrame + Vector3.new(aimX - part.Position.X, aimY - top, 0)
			end
		end
	end

	piece("AimPoint", V(0.04, 0.04, 0.04), V(aimX, aimY, 0), DARK, metal, nil, 1)

	----------------------------------------------------------------------------
	-- Rarity marks
	----------------------------------------------------------------------------

	-- A neon accent strip under block bodies from Rare up (tube-bodied guns carry their rings),
	-- and gold trim at both ends of a Legendary's body.
	local blockBody = receiver.Shape == Enum.PartType.Block
	if rarityIndex >= 3 and blockBody then
		piece("Accent", V(receiver.Size.X + 0.04, 0.07, receiver.Size.Z * 0.6), receiver.CFrame * CFrame.new(0, -receiver.Size.Y / 2 - 0.02, 0), accent, neon)
	end
	if legendary and blockBody then
		for _, z in ipairs({ -1, 1 }) do
			piece("GoldTrim", V(receiver.Size.X + 0.08, receiver.Size.Y + 0.14, 0.07), receiver.CFrame * CFrame.new(0, 0, z * (receiver.Size.Z / 2 - 0.05)), GOLD,
				Enum.Material.Foil)
		end
	end

	-- No two faces flush anywhere on it (a plate level with the body it sits on would flicker in
	-- first person). Done before the welds, so only the one part moves.
	ZFight.Fix({ model }, { all = true })

	model.PrimaryPart = receiver
	-- Pivot on the design origin, facing -Z, rather than on the receiver itself. Tube-bodied
	-- receivers (launcher, cannon) are turned a quarter so their length runs front to back, and
	-- pivoting on them mounted the whole gun turned sideways.
	receiver.PivotOffset = receiver.CFrame:Inverse()

	-- Weld every piece to the receiver so the whole thing moves as one.
	for _, part in ipairs(model:GetChildren()) do
		if part ~= receiver then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = receiver
			weld.Part1 = part
			weld.Parent = part
		end
	end

	local muzzleAttachment = Instance.new("Attachment")
	muzzleAttachment.Name = "Muzzle"
	muzzleAttachment.Position = receiver.CFrame:PointToObjectSpace(muzzle)
	muzzleAttachment.Parent = receiver

	return model, receiver
end

-- A gun that sits still in the world, on the floor or on a podium: the same model the player holds,
-- pivoted to `cframe`, its welds gone (nothing on it is physical), and every part at any depth anchored,
-- untouchable and moved onto `parent`, the pickup base or display part that AmbientClient turns with
-- everything on it.
--
-- The gun has had GunModels' z-fight pass at its millimetre tolerance. It must never go through a
-- map-scale pass afterwards: ZFight.Fix over a folder holding it (the lobby's, at 0.055 studs) reads
-- its fine detail as fighting and grows and shoves it into black blocks. Keep `parent` out of any
-- folder such a pass covers.
--
-- Returns the receiver, the parts, and how far the gun's highest point stands above `cframe`, in
-- studs, which doesn't change as the gun turns about the vertical (for placing labels over it).
-- `options.centre` puts the MIDDLE of the gun at `cframe` instead of its design origin. A gun's pivot
-- is the bore above the trigger, which is nowhere near the middle of the model, so a pickup built at
-- its pad's centre hung most of its body off one side: measured from a standing eye, the gun was 0.95%
-- of the screen against its pad's 7.10%, and the two read as a bright disc with a dark blob over it
-- rather than as a gun lying on a pad. Only the loose ground pickups ask for this; podium and display
-- guns are placed by their design origin on purpose and are unaffected.
function WeaponService.BuildStaticGun(def, color, material, cframe, parent, options)
	local model, receiver = WeaponService.BuildGunModel(def, color, material)
	if options and options.centre then
		local box = model:GetBoundingBox()
		model:PivotTo(cframe * CFrame.new(-model:GetPivot():PointToObjectSpace(box.Position)))
	else
		model:PivotTo(cframe)
	end
	local parts, top = {}, 0
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("WeldConstraint") then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanTouch = false
			table.insert(parts, descendant)
			local frame, half = descendant.CFrame, descendant.Size / 2
			local reach = math.abs(frame.RightVector.Y) * half.X + math.abs(frame.UpVector.Y) * half.Y + math.abs(frame.LookVector.Y) * half.Z
			top = math.max(top, descendant.Position.Y + reach - cframe.Position.Y)
		end
	end
	for _, part in ipairs(parts) do
		part.Parent = parent
	end
	model:Destroy()
	return receiver, parts, top
end

-- Where the right hand is, relative to the upper torso, when GunPoseClient raises the arms to
-- aim. The gun is mounted with its grip there, so posed arms hold it and unposed ones (an R6 rig,
-- say) still see it held out at chest height rather than hanging at the hip.
local HAND_OFFSET = Vector3.new(0.72, 0.28, -1.8)

-- Mounted to the torso rather than welded to the hand: default animations swing the arm, which
-- waved the gun around and pointed it at the floor. Shared by players and bots.
function WeaponService.MountGun(character, model, receiver)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not torso or not root then
		model:Destroy()
		return false
	end

	local grip = model:FindFirstChild("Grip")
	local gripOffset = grip and model:GetPivot():PointToObjectSpace(grip.Position) or V(0, -0.55, 0.45)
	local facing = root.CFrame - root.CFrame.Position
	model:PivotTo(CFrame.new(torso.Position) * facing * CFrame.new(HAND_OFFSET - gripOffset))

	-- Weld before parenting: the gun then arrives already attached, instead of existing
	-- unwelded on a live character for a replication step.
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = receiver
	weld.Part1 = torso
	weld.Parent = receiver

	model.Parent = character
	return true
end

local function buildHeldGun(player, def)
	local character = player.Character
	if not character then
		return
	end

	local color, material, skinned = skinColor(player, def)
	-- The same gun in the same finish already in hand: nothing to rebuild (a refresh after a slot move, or
	-- a second refresh in a respawn). The finish compares by what the held model was marked with.
	local current = character:FindFirstChild("HeldGun")
	if current and not character:FindFirstChild("HeldItem") and current:GetAttribute("WeaponId") == def.id
		and (current:GetAttribute("Skinned") == true) == skinned
		and (not skinned or (current:GetAttribute("SkinColor") == color and current:GetAttribute("SkinMaterial") == material.Name)) then
		return
	end

	clearHeldGun(character)
	local model, receiver = WeaponService.BuildGunModel(def, color, material, { skinned = skinned })
	-- The first-person viewmodel builds its own copy of this gun, so it reads the skin from here.
	if skinned then
		model:SetAttribute("Skinned", true)
		model:SetAttribute("SkinColor", color)
		model:SetAttribute("SkinMaterial", material.Name)
	end
	WeaponService.MountGun(character, model, receiver)
end

local function refreshHeldGunNow(player)
	local loadout = loadouts[player]
	local character = player.Character
	if not character then
		return
	end

	if not loadout or not loadout.equipped then
		clearHeldGun(character)
		return
	end

	local slot = loadout.slots[loadout.equipped]
	if not slot then
		clearHeldGun(character)
		return
	end

	-- Items are held out the same way guns are, by their grip.
	if slot.kind == "item" then
		clearHeldGun(character)
		local model, body = ItemModels.Build(slot.id, { anchored = false, name = "HeldItem" })
		if model then
			WeaponService.MountGun(character, model, body)
		end
		return
	end

	buildHeldGun(player, WeaponData.Get(slot.id))
end

-- What's in a player's hands is rebuilt at most once a frame, however often the held slot changes: a
-- refresh marks the player, and the next Heartbeat builds whatever is held by then. A client flipping
-- slots every frame can't make the server build, replicate and destroy a gun model per flip, and a
-- normal switch still shows on the next frame. Each rebuild runs in its own pcall, so one player's
-- failure is logged and the others still get theirs.
local heldRefreshDue = {}
function WeaponService.RefreshHeldGun(player)
	heldRefreshDue[player] = true
end

game:GetService("RunService").Heartbeat:Connect(function()
	if next(heldRefreshDue) == nil then
		return
	end
	local due = heldRefreshDue
	heldRefreshDue = {}
	for player in pairs(due) do
		if player.Parent then
			local ok, err = pcall(refreshHeldGunNow, player)
			if not ok then
				warn("[WeaponService] held gun refresh failed for " .. player.Name .. ": " .. tostring(err))
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Inventory
--------------------------------------------------------------------------------

local function firstEmptySlot(loadout)
	for index = 1, SLOT_COUNT do
		if not loadout.slots[index] then
			return index
		end
	end
	return nil
end

-- Holding a slot. Cancels a reload or a use in progress on whatever was held before.
local function selectSlot(player, loadout, index)
	loadout.reloading = false
	loadout.reloadToken += 1
	loadout.useToken += 1
	loadout.using = nil
	loadout.equipped = index
	loadout.equipReadyAt = os.clock() + EQUIP_TIME
	WeaponService.RefreshHeldGun(player)
end

-- True when nothing is in hand: no slot selected, or the selected one has been used up.
local function emptyHanded(loadout)
	return not (loadout.equipped and loadout.slots[loadout.equipped])
end

-- Fills the first empty slot; if every slot is taken, swaps out whatever is held and returns it
-- (a gun or an item stack) as the third value so the caller can put it back on the floor.
-- `ammo` ({ mag, reserve }) restores a dropped gun's real ammo; without it the gun is full.
function WeaponService.GiveWeapon(player, weaponId, ammo)
	local def = WeaponData.Get(weaponId)
	local loadout = loadoutFor(player)
	if not def or not loadout then
		return false, "Not in a match."
	end

	local newSlot = {
		kind = "weapon",
		id = weaponId,
		mag = ammo and math.clamp(ammo.mag or 0, 0, def.magSize) or def.magSize,
		reserve = ammo and math.max(0, ammo.reserve or 0) or def.reserveAmmo,
	}

	local index = firstEmptySlot(loadout)
	if index then
		local wasEmptyHanded = emptyHanded(loadout)
		loadout.slots[index] = newSlot
		if wasEmptyHanded then
			selectSlot(player, loadout, index)
		end
		WeaponService.Push(player)
		return true, "Picked up " .. def.name, nil
	end

	local target = loadout.equipped or 1
	local replaced = loadout.slots[target]
	loadout.slots[target] = newSlot
	selectSlot(player, loadout, target)
	WeaponService.Push(player)
	-- Names what was given up, not just what was taken: the old gun is dropped where the new one lay
	-- (LootService.DropSlot, from the caller), and a player who swapped by accident otherwise has to
	-- work out what is missing from an empty hotbar slot.
	local old = replaced and replaced.kind == "weapon" and WeaponData.Get(replaced.id)
	if old then
		return true, string.format("Swapped %s for %s", old.name, def.name), replaced
	end
	return true, "Swapped to " .. def.name, replaced
end

function WeaponService.HasFreeSlot(player)
	local loadout = loadouts[player]
	return loadout ~= nil and firstEmptySlot(loadout) ~= nil
end

-- Takes a slot out of the loadout and returns what was in it, so the caller can put it on the
-- floor. Dropping what's in hand leaves the player holding whatever the next filled slot is.
function WeaponService.TakeSlot(player, slotIndex)
	local loadout = loadouts[player]
	if not loadout or type(slotIndex) ~= "number" or slotIndex % 1 ~= 0 then
		return nil
	end
	local slot = loadout.slots[slotIndex]
	if not slot then
		return nil
	end
	loadout.slots[slotIndex] = nil

	if loadout.equipped == slotIndex then
		loadout.reloading = false
		loadout.reloadToken += 1
		loadout.useToken += 1
		loadout.using = nil
		local next = nil
		for index = 1, SLOT_COUNT do
			if loadout.slots[index] then
				next = index
				break
			end
		end
		if next then
			selectSlot(player, loadout, next)
		else
			loadout.equipped = nil
			WeaponService.RefreshHeldGun(player)
		end
	end
	WeaponService.Push(player)
	return slot
end

-- Rearranging the hotbar (the Inventory panel): swaps what's in slots `a` and `b`, or moves one into
-- the other when it's empty. Returns true, or false and why not.
--
-- What's in your hands stays in your hands. The held slot's number moves with its contents, so there
-- is no re-raise, and a reload in progress carries on and finishes: Reload's timer checks that the
-- slot table it started on is still the equipped one, and that table moves together with `equipped`.
-- Ammo lives in the slot table, so it moves with its gun. A timed item use on either slot is
-- cancelled, the same as switching slots: StartUse's timer only finishes a use whose slot number
-- hasn't changed, so otherwise the bar would keep filling for a use that was already lost.
function WeaponService.SwapSlots(player, a, b)
	local loadout = loadouts[player]
	if not loadout then
		return false, "Not in a match."
	end
	-- The remote checks these too (SafeValue); repeated so no other caller can pass a bad index. Each
	-- is checked on its own: a list like { a, b } stops at a nil, and a nil `a` would slip past.
	local function slotNumber(index)
		return type(index) == "number" and index == index and index % 1 == 0 and index >= 1 and index <= SLOT_COUNT
	end
	if not slotNumber(a) or not slotNumber(b) then
		return false, "No such slot."
	end
	if a == b then
		return false, "That's the same slot."
	end
	local slotA, slotB = loadout.slots[a], loadout.slots[b]
	if not slotA and not slotB then
		return false, "Both slots are empty."
	end

	local using = loadout.using
	if using and (using.index == a or using.index == b) then
		loadout.useToken += 1
		loadout.using = nil
	end

	loadout.slots[a], loadout.slots[b] = slotB, slotA
	if loadout.equipped == a then
		loadout.equipped = b
	elseif loadout.equipped == b then
		loadout.equipped = a
	end
	WeaponService.Push(player)
	return true
end

-- Adds up to `amount` of an item: topping up stacks already carried first, then filling empty
-- slots. Returns how many fit (0 when there's no room), so the rest can stay on the floor.
function WeaponService.GiveConsumable(player, itemId, amount)
	local item = ItemData.Get(itemId)
	local loadout = loadoutFor(player)
	if not item or not loadout then
		return 0
	end
	amount = math.max(0, math.floor(amount or item.pickup))
	local left = amount

	for index = 1, SLOT_COUNT do
		local slot = loadout.slots[index]
		if left > 0 and slot and slot.kind == "item" and slot.id == itemId and slot.count < item.stack then
			local add = math.min(left, item.stack - slot.count)
			slot.count += add
			left -= add
		end
	end

	while left > 0 do
		local index = firstEmptySlot(loadout)
		if not index then
			break
		end
		local wasEmptyHanded = emptyHanded(loadout)
		local add = math.min(left, item.stack)
		loadout.slots[index] = { kind = "item", id = itemId, count = add }
		left -= add
		if wasEmptyHanded then
			selectSlot(player, loadout, index)
		end
	end

	local added = amount - left
	if added > 0 then
		WeaponService.Push(player)
	end
	return added
end

-- Every slot taken: the pickup goes into the slot in hand and what was there comes out, for the
-- caller to put on the floor. Returns the replaced slot and how many were taken, or nil when the
-- hand already holds that item (a full stack of it — there'd be nothing to gain).
function WeaponService.SwapHeldForItem(player, itemId, amount)
	local item = ItemData.Get(itemId)
	local loadout = loadouts[player]
	if not item or not loadout then
		return nil, 0
	end
	local target = loadout.equipped or 1
	local replaced = loadout.slots[target]
	if replaced and replaced.kind == "item" and replaced.id == itemId then
		return nil, 0
	end
	local take = math.min(math.max(1, math.floor(amount or item.pickup)), item.stack)

	-- Whatever was being done with the old slot stops with it.
	loadout.reloading = false
	loadout.reloadToken += 1
	loadout.useToken += 1
	loadout.using = nil
	loadout.slots[target] = { kind = "item", id = itemId, count = take }
	selectSlot(player, loadout, target)
	WeaponService.Push(player)
	return replaced, take
end

-- Kept for callers that only care whether anything was taken.
function WeaponService.GiveHeal(player, healId, amount)
	return WeaponService.GiveConsumable(player, healId, amount) > 0
end

function WeaponService.GiveItem(player, itemId, amount)
	return WeaponService.GiveConsumable(player, itemId, amount) > 0
end

--------------------------------------------------------------------------------
-- Shield
--------------------------------------------------------------------------------

function WeaponService.GetShield(player)
	local loadout = loadouts[player]
	return loadout and loadout.shield or 0
end

-- Sets the shield outright (a Shield Up match starts everyone with some).
function WeaponService.SetShield(player, value)
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	loadout.shield = math.clamp(value, 0, MAX_SHIELD)
	syncShield(player, loadout.shield)
	WeaponService.Push(player)
end

-- Damage comes off the shield first. Returns what's left for health, and what the shield took.
-- The storm deals its damage directly, so it goes straight through shields.
function WeaponService.AbsorbDamage(player, amount)
	local loadout = loadouts[player]
	if not loadout or loadout.shield <= 0 or amount <= 0 then
		return amount, 0
	end
	local absorbed = math.min(loadout.shield, amount)
	loadout.shield -= absorbed
	syncShield(player, loadout.shield)
	WeaponService.Push(player)
	return amount - absorbed, absorbed
end

-- `fraction` is a share of each weapon's own reserve capacity, not a raw round count. A flat
-- amount ignored scale: reserves run from 16 rockets to 300 chaingun rounds, so the same +100
-- was nine reloads of explosives for the launcher and a rounding error for the chaingun —
-- inflating exactly the ammo meant to be scarcest. Each slot is capped at twice its capacity
-- so pickups can't stockpile forever, and a pickup never reduces ammo already held.
local AMMO_CAP_MULTIPLIER = 2

-- How many rounds a refill of `fraction` would actually add to one slot: zero when the slot holds no
-- gun, and zero when its reserve is already at (or above) the cap. Pure and exported as
-- `WeaponService.AmmoGrant` so the decision can be tested directly -- nothing in the Studio harness can
-- hold a loadout, since that needs a real Player to push to.
local function ammoGrant(slot, fraction)
	local def = slot and slot.kind == "weapon" and WeaponData.Get(slot.id)
	if not def then
		return 0
	end
	local grant = math.ceil(def.reserveAmmo * fraction)
	local cap = def.reserveAmmo * AMMO_CAP_MULTIPLIER
	-- Never takes rounds away: a reserve already past the cap stays where it is and grants nothing.
	return math.max(0, math.min(cap, slot.reserve + grant) - slot.reserve)
end
WeaponService.AmmoGrant = ammoGrant

-- Returns true only if rounds actually arrived. It used to return true for any live loadout, so
-- VendorService's "Nothing to reload." refusal (VendorService:105) was unreachable and a player with no
-- gun -- or with every reserve already at the cap -- was charged 150 SahurCoins for nothing and toasted
-- success. Callers that charge money read this, so it must describe what happened, not that it ran.
-- Deliberately true/false rather than the count: 0 is truthy in Lua, so a count would walk straight
-- through the `if not WeaponService.GiveAmmo(...)` at the call site that matters.
function WeaponService.GiveAmmo(player, fraction)
	local loadout = loadouts[player]
	if not loadout then
		return false
	end
	local added = 0
	for _, slot in pairs(loadout.slots) do
		local grant = ammoGrant(slot, fraction)
		if grant > 0 then
			slot.reserve += grant
			added += grant
		end
	end
	if added <= 0 then
		return false
	end
	WeaponService.Push(player)
	return true
end

function WeaponService.Equip(player, slotIndex)
	local loadout = loadouts[player]
	if not loadout then
		return
	end
	if type(slotIndex) ~= "number" or slotIndex % 1 ~= 0 or slotIndex < 1 or slotIndex > SLOT_COUNT then
		return
	end
	if not loadout.slots[slotIndex] or loadout.equipped == slotIndex then
		return
	end

	selectSlot(player, loadout, slotIndex)
	WeaponService.Push(player)
end

function WeaponService.IsReady(player)
	local loadout = loadouts[player]
	if not loadout then
		return false
	end
	return os.clock() >= (loadout.equipReadyAt or 0)
end

function WeaponService.GetEquipped(player)
	local loadout = loadouts[player]
	if not loadout or not loadout.equipped then
		return nil, nil
	end
	local slot = loadout.slots[loadout.equipped]
	if not slot or slot.kind ~= "weapon" then
		return nil, nil
	end
	return WeaponData.Get(slot.id), slot
end

function WeaponService.ConsumeAmmo(player)
	local loadout = loadouts[player]
	local _, slot = WeaponService.GetEquipped(player)
	if not loadout or not slot or slot.mag <= 0 then
		return false
	end
	slot.mag -= 1
	WeaponService.Push(player)
	return true
end

function WeaponService.Reload(player)
	local loadout = loadouts[player]
	local def, slot = WeaponService.GetEquipped(player)
	if not loadout or not def or loadout.reloading then
		return
	end
	if slot.mag >= def.magSize or slot.reserve <= 0 then
		return
	end

	loadout.reloading = true
	loadout.reloadToken += 1
	local token = loadout.reloadToken
	WeaponService.Push(player)

	task.delay(def.reloadTime, function()
		-- Only the reload that is still current may finish. Checking just the equipped slot
		-- index wasn't enough: swapping away and back left the index unchanged, so a
		-- "cancelled" timer completed anyway — and could clear `reloading` early on top of
		-- a second reload started after the swap. A pickup replacing the gun mid-reload is
		-- caught by the slot-identity check.
		if loadouts[player] ~= loadout or loadout.reloadToken ~= token then
			return
		end
		if loadout.slots[loadout.equipped] ~= slot then
			return
		end
		local needed = def.magSize - slot.mag
		local moved = math.min(needed, slot.reserve)
		slot.mag += moved
		slot.reserve -= moved
		loadout.reloading = false
		WeaponService.Push(player)
	end)
end

--------------------------------------------------------------------------------
-- Using items
--------------------------------------------------------------------------------

-- A heal's cap is authored against 100 health and scales with max health, so the extra-health
-- pass doesn't make a Bandage worse.
local function healCap(humanoid, item)
	return math.min(humanoid.MaxHealth, item.cap * humanoid.MaxHealth / 100)
end

local function livingHumanoid(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid.Health > 0 and humanoid or nil
end

-- Why using this item right now would do nothing, or nil if it's fine to use.
local function refusal(player, loadout, item)
	local humanoid = livingHumanoid(player)
	if not humanoid then
		return ""
	end
	if item.kind == "heal" and humanoid.Health >= healCap(humanoid, item) then
		return item.cap < 100 and string.format("%s only heals up to %d.", item.name, item.cap) or "You're already at full health."
	elseif item.kind == "shield" and loadout.shield >= item.cap then
		return item.cap < MAX_SHIELD and string.format("%s only fills shield up to %d.", item.name, item.cap) or "Your shield is already full."
	end
	return nil
end

-- `aimPoint` is where the player was aiming when they clicked (thrown items go there).
local function applyItem(player, loadout, item, aimPoint)
	local humanoid = livingHumanoid(player)
	if not humanoid or refusal(player, loadout, item) then
		return false
	end
	if item.kind == "heal" then
		humanoid.Health = math.min(healCap(humanoid, item), humanoid.Health + item.amount)
	elseif item.kind == "shield" then
		loadout.shield = math.min(item.cap, loadout.shield + item.amount)
		syncShield(player, loadout.shield)
	elseif item.kind == "defense" then
		return WeaponService.DefenseEffect(player, item.id, aimPoint) == true
	elseif item.kind == "throwable" then
		return WeaponService.ThrowEffect(player, item.id, aimPoint) == true
	else
		return WeaponService.MovementEffect(player, item.id) == true
	end
	return true
end

-- Spend one from a slot, clear the slot when it runs out, and tell everyone nearby it was used
-- (clients play the sound and the burst).
local function spendAndFinish(player, loadout, index, item)
	local slot = loadout.slots[index]
	slot.count -= 1
	if slot.count <= 0 then
		loadout.slots[index] = nil
		WeaponService.RefreshHeldGun(player)
	end
	WeaponService.Push(player)
	if player.Character then
		itemUsed:FireAllClients(player.Character, item.id)
	end
	QuestService.Progress(player, "items", 1)
end

-- A click with an item in hand. Instant items go off straight away (thrown ones toward
-- `aimPoint`); the rest take `useTime`, and switching slots in the meantime cancels. Returns
-- false and a reason when it can't start.
-- `slotIndex` (optional): the Quick Movement key, using a movement item from that slot without
-- switching to it. Only movement items; nothing is raised, so the raise time after a swap doesn't hold it.
function WeaponService.StartUse(player, aimPoint, slotIndex)
	local loadout = loadouts[player]
	local index = loadout and loadout.equipped
	local quick = false
	if slotIndex ~= nil then
		if not loadout or not SafeValue.Number(slotIndex, 64) or slotIndex % 1 ~= 0 then
			return false
		end
		local quickSlot = loadout.slots[slotIndex]
		local quickItem = quickSlot and quickSlot.kind == "item" and ItemData.Get(quickSlot.id)
		if not quickItem or quickItem.kind ~= "movement" then
			return false
		end
		index, quick = slotIndex, true
	end
	local slot = index and loadout.slots[index]
	if not slot or slot.kind ~= "item" or loadout.using then
		return false
	end
	local item = ItemData.Get(slot.id)
	if not item or (not quick and os.clock() < (loadout.equipReadyAt or 0)) then
		return false
	end

	local reason = refusal(player, loadout, item)
	if reason then
		return false, reason ~= "" and reason or nil
	end

	if item.useTime <= 0 then
		local now = os.clock()
		if lastInstantAt[player] and now - lastInstantAt[player] < INSTANT_COOLDOWN then
			return false
		end
		if not applyItem(player, loadout, item, aimPoint) then
			return false
		end
		lastInstantAt[player] = now
		spendAndFinish(player, loadout, index, item)
		return true
	end

	loadout.useToken += 1
	local token = loadout.useToken
	loadout.using = { index = index, id = item.id, startedAt = os.clock(), duration = item.useTime }
	WeaponService.Push(player)

	task.delay(item.useTime, function()
		-- Only the use that's still current finishes: a swap, a new match or a replaced stack
		-- all invalidate it.
		if loadouts[player] ~= loadout or loadout.useToken ~= token then
			return
		end
		loadout.using = nil
		if loadout.slots[index] == slot and (loadout.equipped == index or quick) and applyItem(player, loadout, item) then
			spendAndFinish(player, loadout, index, item)
		else
			WeaponService.Push(player)
		end
	end)
	return true
end

function WeaponService.CancelUse(player)
	local loadout = loadouts[player]
	if loadout and loadout.using then
		loadout.useToken += 1
		loadout.using = nil
		WeaponService.Push(player)
	end
end

-- No PlayerRemoving hook here on purpose. Bootstrap clears the loadout after
-- MatchService.OnPlayerRemoving has eliminated the player and dropped their guns. A
-- module-level connection could fire first — signal order isn't guaranteed — wiping the
-- loadout before it's read, so anyone who quit mid-match took their weapons with them.

return WeaponService
