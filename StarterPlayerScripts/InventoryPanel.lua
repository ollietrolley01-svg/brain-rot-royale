-- The Inventory panel: rearrange the hotbar. A ModuleScript so HudClient can open it and
-- tools/hud_ux_gallery.lua can render it without a match.
--
--   local panel = InventoryPanel.new(screenGui, {
--       onSwap = function(a, b) end,          -- ask the server to swap slots a and b (SwapSlots remote)
--       onClose = function() end,             -- the panel closed itself (overlay click, close button)
--       keyLabel = function(index) end,       -- "1".."8", or whatever each slot is bound to
--       closeKeyLabel = function() end,       -- the key that toggles the panel, for the hint
--   })
--   panel:SetViewport(camera.ViewportSize)
--   panel:Open(loadout) / panel:Close() / panel:SetLoadout(loadout) / panel:IsOpen()
--
-- Eight slots in two rows of four, in hotbar order. Two ways to move things, both on mouse and touch:
--   * drag a slot onto another and let go: they swap (onto an empty slot, it moves);
--   * tap a slot, then tap another: they swap. Tap the same one again to put it down.
-- The swap shows at once, and the server's loadout push confirms it; if no push comes (the server
-- refused), the panel goes back to what the server last said. What's in your hand stays in your hand:
-- its IN HAND tag moves with it, the same as on the server (WeaponService.SwapSlots).
--
-- The panel's pointer maths expects its ScreenGui to keep the top-bar inset (IgnoreGuiInset false),
-- where InputObject positions and GUI AbsolutePositions share one origin.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GunModels = require(Shared:WaitForChild("GunModels"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))

local UiKit = require(script.Parent:WaitForChild("UiKit"))

local create, rounded = UiKit.create, UiKit.rounded
local C = UiKit.Colors

local InventoryPanel = {}
InventoryPanel.__index = InventoryPanel

local SLOT_COUNT = 8
local COLUMNS = 4
local CARD_W, CARD_H = 156, 146
local GAP = 14
local PAD = 26
local HEADER_H = 84
local FOOTER_H = 50
-- The panel is four cards across on a screen with the room, and two across four down on an upright one:
-- 718 px of panel does not fit a 320-wide phone at any scale a finger can use, and on those screens the
-- panel IS the hotbar -- PhoneLayout's upright version has no room for slots on screen at all.
local function panelSize(columns)
	local rows = math.ceil(SLOT_COUNT / columns)
	return Vector2.new(PAD * 2 + columns * CARD_W + (columns - 1) * GAP,
		HEADER_H + rows * CARD_H + (rows - 1) * GAP + FOOTER_H + 18)
end

local PANEL_W = panelSize(COLUMNS).X
local PANEL_H = panelSize(COLUMNS).Y
InventoryPanel.Size = Vector2.new(PANEL_W, PANEL_H)

--------------------------------------------------------------------------------
-- What a slot is, in words (#86 C14, C39, C40, M13)
--------------------------------------------------------------------------------

-- A gun's name carries no type: "Scrolla Scrolla Brrrap" could be anything, and whether it is an SMG or a
-- sniper is the first thing a player needs to know. The word comes from the gun's `style` (the silhouette
-- WeaponService builds), so it cannot disagree with the model in the player's hands. LootService keeps a
-- copy of this table for the floor label -- the server cannot require a StarterPlayerScripts module --
-- and tools/player_eye_check.py ("gunword") fails the moment the two differ or a style has no word.
local GUN_TYPE_WORDS = {
	pistol = "PISTOL", revolver = "REVOLVER", smg = "SMG", rifle = "RIFLE", dmr = "MARKSMAN",
	shotgun = "SHOTGUN", doublebarrel = "SHOTGUN", crossbow = "CROSSBOW", sniper = "SNIPER",
	blaster = "BLASTER", launcher = "LAUNCHER", lmg = "MACHINE GUN", minigun = "MINIGUN",
	cannon = "CANNON", railgun = "RAILGUN",
}

-- The type word, or nil when the name already says it ("Rot SMG", "Bonker Double Barrel", "Grass
-- Toucher DMR"): "Rot SMG · SMG" is noise. Compared without case or spaces, against the word and the
-- style both, so "Double Barrel" matches "doublebarrel".
function InventoryPanel.GunTypeWord(name, style)
	local word = style and GUN_TYPE_WORDS[style]
	if not word then
		return nil
	end
	local flat = string.gsub(string.lower(name or ""), "%s", "")
	local wordFlat = string.gsub(string.lower(word), "%s", "")
	if string.find(flat, wordFlat, 1, true) or string.find(flat, style, 1, true) then
		return nil
	end
	return word
end

-- The longer text a card shows while it is hovered or selected, and the HUD's line under a held item:
-- an item's description and its standing rule (the structure cap, M13), or a gun's type, reach and hit.
function InventoryPanel.Describe(slot)
	if type(slot) ~= "table" then
		return ""
	end
	if slot.kind == "item" then
		local item = ItemData.Get(slot.id)
		if not item then
			return ""
		end
		local text = item.description or ""
		if item.capRule then
			text = text .. " " .. item.capRule
		end
		return text
	end
	local def = WeaponData.Get(slot.id)
	if not def then
		return ""
	end
	local parts = {}
	local word = GUN_TYPE_WORDS[slot.style or def.style]
	if word then
		table.insert(parts, word)
	end
	-- Range is where a hitscan shot stops doing anything at all (WeaponData's header: no falloff, nothing
	-- beyond it), so it is the number that explains a miss. A launcher's round flies until it lands.
	if def.range and not def.projectile then
		table.insert(parts, string.format("reach %d studs", def.range))
	end
	table.insert(parts, string.format("%d dmg%s", def.damage or 0, (def.pellets or 1) > 1 and (" x" .. def.pellets) or ""))
	return table.concat(parts, "  •  ")
end

-- Two columns on a narrow upright screen, four everywhere else.
function InventoryPanel.ColumnsFor(viewport)
	return (viewport.Y > viewport.X and viewport.X < 520) and 2 or COLUMNS
end

local DRAG_START = 10
local CONFIRM_WAIT = 0.9
local ZINDEX = 50

local GOLD = C.Accent
local SELECT = Color3.fromRGB(255, 214, 90)
local TARGET = C.Green
local SHADOW = Color3.fromRGB(10, 11, 16)

-- The panel's UIScale for a viewport: full size on a 1080p screen, a little bigger above it, and on a
-- phone as big as fits (about 0.75 at 844x390, where the cards are still over 110 px across).
function InventoryPanel.ScaleFor(viewport)
	local size = panelSize(InventoryPanel.ColumnsFor(viewport))
	-- Half size is the floor, unless the screen cannot even fit that: then it is whatever does fit.
	local fit = math.min(viewport.X * 0.94 / size.X, viewport.Y * 0.92 / size.Y)
	return math.clamp(math.min(viewport.Y / 1080 * 1.1, fit), math.min(0.5, fit), 1.15)
end

local function tween(instance, seconds, goal, style, direction)
	local t = TweenService:Create(instance, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), goal)
	t:Play()
	return t
end

--------------------------------------------------------------------------------
-- Icons: the item or gun itself in a ViewportFrame, framed to fit. Guns are slow to build, so each is
-- built once and cloned after that.
--------------------------------------------------------------------------------

local gunTemplates = {}

local function modelFor(slot)
	if slot.kind == "item" then
		local model = ItemModels.Build(slot.id)
		if model then
			model:PivotTo(CFrame.Angles(0, math.rad(35), 0))
		end
		return model
	end
	local template = gunTemplates[slot.id]
	if template == nil then
		local def = WeaponData.Get(slot.id)
		local ok, model = pcall(function()
			return def and GunModels.Build(def, Rarity.Color(def.rarity), Enum.Material.Metal)
		end)
		template = ok and model or false
		gunTemplates[slot.id] = template
	end
	if not template then
		return nil
	end
	local model = template:Clone()
	-- Side on, muzzle to the right, tipped a touch toward the camera.
	model:PivotTo(CFrame.Angles(0, math.rad(-90), 0) * CFrame.Angles(math.rad(-8), 0, 0))
	return model
end

local function setIcon(refs, slot)
	local key = slot and (slot.kind .. ":" .. slot.id) or nil
	if refs.iconKey == key then
		return
	end
	refs.iconKey = key
	refs.icon:ClearAllChildren()
	refs.icon.Visible = false
	if not slot then
		return
	end
	local model = modelFor(slot)
	if not model then
		return
	end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
		end
	end
	model.Parent = refs.icon
	local box, size = model:GetBoundingBox()
	local camera = Instance.new("Camera")
	camera.FieldOfView = 30
	local wide = slot.kind ~= "item"
	-- Fit the longest side: guns are long and flat, items roughly round.
	local reach = wide and math.max(size.X, size.Z) * 0.62 or size.Magnitude / 2
	local distance = reach / math.tan(math.rad(15)) * (wide and 0.92 or 1.05)
	camera.CFrame = CFrame.lookAt(box.Position + Vector3.new(0, distance * (wide and 0.12 or 0.3), -distance), box.Position)
	camera.Parent = refs.icon
	refs.icon.CurrentCamera = camera
	refs.icon.Visible = true
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

function InventoryPanel.new(parent, options)
	options = options or {}
	local self = setmetatable({}, InventoryPanel)
	self.options = options
	self.open = false
	self.loadout = nil
	self.shownSlots = nil
	self.selected = nil
	self.drag = nil
	self.token = 0

	-- The dim behind the panel; clicking it closes. It is also what frees the mouse: `Modal` on a
	-- VISIBLE GuiButton unlocks the cursor for as long as it is up, which is the one thing that beats a
	-- first-person camera relocking it every frame. The panel carries its own rather than relying on
	-- another script watching an attribute, because a panel you cannot click is a panel you cannot use --
	-- and this button is already alive for exactly the panel's lifetime. (HudClient still sets the
	-- MenuOpen attribute as well: CombatClient reads it to stop clicks firing the gun.)
	self.overlay = create("TextButton", {
		Name = "InventoryOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 1,
		AutoButtonColor = false,
		Modal = true,
		Selectable = false,
		Text = "",
		Visible = false,
		ZIndex = ZINDEX,
		Parent = parent,
	})
	self.overlay.Activated:Connect(function()
		if self.open and not self.drag then
			self:Close(true)
		end
	end)

	local root = create("CanvasGroup", {
		Name = "InventoryPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(PANEL_W, PANEL_H),
		BackgroundTransparency = 1,
		GroupTransparency = 1,
		Visible = false,
		ZIndex = ZINDEX + 1,
		Parent = parent,
	})
	self.root = root
	self.scale = create("UIScale", { Parent = root })

	-- The panel's own clicks shouldn't fall through to the overlay.
	local plate = create("TextButton", {
		Name = "Plate",
		Position = UDim2.fromOffset(3, 3),
		Size = UDim2.new(1, -6, 1, -6),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.03,
		AutoButtonColor = false,
		Text = "",
		ZIndex = ZINDEX + 1,
		Parent = root,
	}, { rounded(18) })
	create("UIStroke", { Color = C.PanelAlt, Thickness = 2, Parent = plate })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(205, 208, 220)),
		Parent = plate,
	})

	-- Header: a bag-of-slots mark, the title, how to use it, and the close button.
	local mark = create("Frame", {
		Name = "Mark",
		Position = UDim2.fromOffset(PAD, 22),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 2,
		Parent = root,
	}, { rounded(10) })
	for row = 0, 1 do
		for column = 0, 1 do
			create("Frame", {
				Position = UDim2.fromOffset(9 + column * 12, 9 + row * 12),
				Size = UDim2.fromOffset(10, 10),
				BackgroundColor3 = SHADOW,
				BorderSizePixel = 0,
				ZIndex = ZINDEX + 3,
				Parent = mark,
			}, { rounded(3) })
		end
	end
	create("TextLabel", {
		Name = "Title",
		Position = UDim2.fromOffset(PAD + 54, 16),
		Size = UDim2.fromOffset(300, 34),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = "INVENTORY",
		TextColor3 = C.Text,
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = ZINDEX + 2,
		Parent = root,
	})
	self.hint = create("TextLabel", {
		Name = "Hint",
		Position = UDim2.fromOffset(PAD + 54, 50),
		Size = UDim2.fromOffset(PANEL_W - PAD * 2 - 54 - 60, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "Drag a slot onto another to swap them, or tap one and then the other.",
		TextColor3 = C.Muted,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 2,
		Parent = root,
	})
	-- DROP (Oliver's list #36). The server has been able to drop a slot all along -- Bootstrap's
	-- DropSlot behind a rate limit, WeaponService.TakeSlot, LootService putting a real pickup on the
	-- ground -- and the only way to ask for it was a RIGHT-CLICK on a hotbar cell. A phone has no
	-- right-click at all, so on touch the feature was unreachable, and on a desktop it was
	-- undiscoverable: nothing anywhere said it existed. This is the affordance, not the feature.
	--
	-- It appears only while a slot is selected, so it cannot be hit by accident: dropping a gun in a
	-- match is not something to put one stray tap away.
	self.dropButton = create("TextButton", {
		Name = "Drop",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD - 48, 0, 20),
		Size = UDim2.fromOffset(96, 44),
		BackgroundColor3 = C.Red,
		AutoButtonColor = false,
		Font = Enum.Font.GothamBold,
		Text = "DROP",
		TextColor3 = C.Text,
		TextSize = 15,
		Visible = false,
		ZIndex = ZINDEX + 2,
		Parent = root,
	}, { rounded(12) })
	self.dropButton.Activated:Connect(function()
		local index = self.selected
		if not index then
			return
		end
		self.selected = nil
		if self.options.onDrop then
			self.options.onDrop(index)
		end
		self:_refresh()
	end)

	local close = create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PAD + 4, 0, 20),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = C.Panel,
		AutoButtonColor = false,
		Text = "",
		ZIndex = ZINDEX + 2,
		Parent = root,
	}, { rounded(12) })
	self.closeStroke = create("UIStroke", { Color = C.PanelAlt, Thickness = 1.5, Parent = close })
	for _, angle in ipairs({ 45, -45 }) do
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(20, 3),
			BackgroundColor3 = C.Text,
			BorderSizePixel = 0,
			Rotation = angle,
			ZIndex = ZINDEX + 3,
			Parent = close,
		}, { rounded(2) })
	end
	close.Activated:Connect(function()
		self:Close(true)
	end)
	close.MouseEnter:Connect(function()
		close.BackgroundColor3 = C.Red
	end)
	close.MouseLeave:Connect(function()
		close.BackgroundColor3 = C.Panel
	end)

	-- The two rows.
	self.grid = create("Frame", {
		Name = "Grid",
		Position = UDim2.fromOffset(PAD, HEADER_H),
		Size = UDim2.fromOffset(PANEL_W - PAD * 2, 2 * CARD_H + GAP),
		BackgroundTransparency = 1,
		ZIndex = ZINDEX + 2,
		Parent = root,
	})
	self.cards = {}
	for index = 1, SLOT_COUNT do
		self.cards[index] = self:_buildCard(index)
	end

	-- Footer.
	self.footLeft = create("TextLabel", {
		Name = "FootLeft",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, PAD, 1, -18),
		Size = UDim2.fromOffset(420, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "What's in your hand stays in your hand.",
		TextColor3 = C.Muted,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = ZINDEX + 2,
		Parent = root,
	})
	self.footRight = create("TextLabel", {
		Name = "FootRight",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -PAD, 1, -18),
		Size = UDim2.fromOffset(240, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		RichText = true,
		Text = "",
		TextColor3 = C.Muted,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = ZINDEX + 2,
		Parent = root,
	})

	-- The card that follows the pointer while dragging, drawn over everything.
	self.lifted = self:_buildCard(0, parent)
	self.lifted.card.Visible = false
	self.lifted.card.AnchorPoint = Vector2.new(0.5, 0.5)
	self.lifted.card.ZIndex = ZINDEX + 20
	self.liftedScale = create("UIScale", { Parent = self.lifted.card })
	for _, item in ipairs(self.lifted.card:GetDescendants()) do
		if item:IsA("GuiObject") then
			item.ZIndex += 20
		end
	end

	self:_connectPointer()
	return self
end

-- One slot card. `index` 0 is the lifted copy used while dragging; `parent` defaults to the grid.
function InventoryPanel:_buildCard(index, parent)
	local columns = self.columns or COLUMNS
	local column = (math.max(index, 1) - 1) % columns
	local row = math.floor((math.max(index, 1) - 1) / columns)
	local card = create("TextButton", {
		Name = index > 0 and ("Slot" .. index) or "Lifted",
		Position = UDim2.fromOffset(column * (CARD_W + GAP) + CARD_W / 2, row * (CARD_H + GAP) + CARD_H / 2),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundColor3 = C.Panel,
		AutoButtonColor = false,
		Text = "",
		ZIndex = ZINDEX + 3,
		Parent = parent or self.grid,
	}, { rounded(14) })
	local refs = { index = index, card = card }
	refs.scale = index > 0 and create("UIScale", { Parent = card }) or nil
	refs.stroke = create("UIStroke", { Color = C.PanelAlt, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = card })
	refs.gradient = create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 194, 206)),
		Parent = card,
	})

	-- The rarity's colour pooling up from the bottom, under everything else.
	refs.glow = create("Frame", {
		Name = "Glow",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.7),
		BackgroundColor3 = C.Accent,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 3,
		Parent = card,
	}, {
		rounded(14),
		create("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.72) }),
		}),
	})

	refs.icon = create("ViewportFrame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 24),
		Size = UDim2.fromOffset(CARD_W - 20, 70),
		BackgroundTransparency = 1,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Visible = false,
		ZIndex = ZINDEX + 4,
		Parent = card,
	})

	refs.key = create("TextLabel", {
		Name = "Key",
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(26, 24),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.1,
		Font = Enum.Font.GothamBlack,
		Text = tostring(index),
		TextColor3 = C.Text,
		TextSize = 14,
		ZIndex = ZINDEX + 5,
		Parent = card,
	}, { rounded(7) })

	refs.tag = create("TextLabel", {
		Name = "Tag",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(62, 20),
		BackgroundColor3 = GOLD,
		Font = Enum.Font.GothamBlack,
		Text = "IN HAND",
		TextColor3 = SHADOW,
		TextSize = 10,
		Visible = false,
		ZIndex = ZINDEX + 5,
		Parent = card,
	}, { rounded(10) })

	refs.name = create("TextLabel", {
		Name = "ItemName",
		Position = UDim2.new(0, 10, 1, -46),
		Size = UDim2.new(1, -20, 0, 18),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = "",
		TextColor3 = C.Text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 5,
		Parent = card,
	})
	refs.sub = create("TextLabel", {
		Name = "Sub",
		Position = UDim2.new(0, 10, 1, -27),
		-- The whole width: the ammo count is a chip on the icon above, not on this line.
		Size = UDim2.new(1, -20, 0, 16),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Muted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = ZINDEX + 5,
		Parent = card,
	})
	-- The ammo (or the stack's count) is a chip on the icon's bottom-right corner, the way the hotbar
	-- cells show it, and NOT on the line below: "LEGENDARY  •  240 reserve" needs that whole line, and a
	-- magazine like 100/100 is wide enough to run under it wherever the two share a row.
	refs.count = create("TextLabel", {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -8, 1, -50),
		Size = UDim2.fromOffset(74, 22),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.3,
		Font = Enum.Font.FredokaOne,
		Text = "",
		TextColor3 = C.Text,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = ZINDEX + 5,
		Parent = card,
	}, {
		rounded(7),
		create("UIPadding", { PaddingRight = UDim.new(0, 6) }),
	})
	refs.bar = create("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, -24, 0, 4),
		BackgroundColor3 = C.Muted,
		BorderSizePixel = 0,
		ZIndex = ZINDEX + 5,
		Parent = card,
	}, { rounded(2) })
	-- The card's detail (Describe): over the icon and the ammo chip, which it hides, while the card is
	-- hovered or selected. The name and the tier line stay where they are, so the card still says what
	-- it is. Scaled into the box rather than truncated: an item's description is the whole point, and the
	-- longest (Sticky Bomb, or a fortress with its cap rule) is about 150 characters.
	refs.detail = create("TextLabel", {
		Name = "Detail",
		Position = UDim2.fromOffset(10, 36),
		Size = UDim2.new(1, -20, 1, -84),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = C.Text,
		TextScaled = true,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Visible = false,
		ZIndex = ZINDEX + 5,
		Parent = card,
	}, { create("UITextSizeConstraint", { MaxTextSize = 13 }) })
	refs.empty = create("TextLabel", {
		Name = "Empty",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(CARD_W - 20, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "EMPTY",
		TextColor3 = C.Muted,
		TextTransparency = 0.35,
		TextSize = 13,
		ZIndex = ZINDEX + 5,
		Parent = card,
	})
	return refs
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

-- Fills a card from a loadout slot (or `false` for empty) and its state.
function InventoryPanel:_paintCard(refs, slot, state)
	state = state or {}
	local filled = slot ~= nil and slot ~= false
	refs.key.Text = self.options.keyLabel and self.options.keyLabel(refs.index) or tostring(refs.index)
	refs.empty.Visible = not filled
	refs.name.Visible = filled
	refs.sub.Visible = filled
	refs.count.Visible = filled
	refs.bar.Visible = filled
	refs.glow.Visible = filled
	refs.tag.Visible = filled and state.held == true
	refs.card.BackgroundColor3 = filled and C.Panel or C.Background
	refs.card.BackgroundTransparency = filled and 0 or 0.25
	setIcon(refs, filled and slot or nil)

	-- Hovered or selected, and not being dragged: the words instead of the picture.
	local detailed = filled and state.detail == true and not state.source and not state.target
	refs.detail.Visible = detailed
	refs.detail.Text = detailed and InventoryPanel.Describe(slot) or ""
	if detailed then
		refs.icon.Visible = false
		refs.count.Visible = false
	end

	if filled then
		local color = Rarity.Color(slot.rarity)
		refs.name.Text = slot.name or slot.id
		refs.name.TextColor3 = color:Lerp(Color3.new(1, 1, 1), 0.15)
		refs.bar.BackgroundColor3 = color
		refs.glow.BackgroundColor3 = color
		if slot.kind == "item" then
			refs.sub.Text = string.upper(slot.rarity or "")
			refs.count.Text = "x" .. tostring(slot.count or 1)
			refs.count.TextColor3 = C.Text
		else
			refs.sub.Text = string.format("%s  •  %d reserve", string.upper(slot.rarity or ""), slot.reserve or 0)
			refs.count.Text = string.format("%d/%d", slot.mag or 0, slot.magSize or 0)
			refs.count.TextColor3 = (slot.mag or 0) == 0 and C.Red or C.Text
		end
	end

	-- The outline says what's going on with this card.
	local stroke = refs.stroke
	if state.target then
		stroke.Color, stroke.Thickness, stroke.Transparency = TARGET, 4, 0
	elseif state.selected then
		stroke.Color, stroke.Thickness, stroke.Transparency = SELECT, 4, 0
	elseif state.held then
		stroke.Color, stroke.Thickness, stroke.Transparency = GOLD, 2.5, 0.2
	elseif filled then
		stroke.Color, stroke.Thickness, stroke.Transparency = Rarity.Color(slot.rarity), 1.5, 0.45
	else
		stroke.Color, stroke.Thickness, stroke.Transparency = C.PanelAlt, 1.5, 0.3
	end
	for _, item in ipairs({ refs.icon, refs.name, refs.sub, refs.count, refs.key, refs.tag, refs.bar }) do
		if item:IsA("TextLabel") then
			item.TextTransparency = state.source and 0.6 or 0
		end
	end
	refs.card.BackgroundTransparency = state.source and 0.6 or refs.card.BackgroundTransparency
	refs.icon.ImageTransparency = state.source and 0.7 or 0
end

-- The slots as shown: the server's, or the local guess after a swap until the server confirms.
function InventoryPanel:_render()
	local slots = self.shownSlots or (self.loadout and self.loadout.slots) or {}
	local held = self.shownEquipped
	if held == nil and self.loadout then
		held = self.loadout.equipped
	end
	local used = 0
	for index = 1, SLOT_COUNT do
		local slot = slots[index]
		if slot then
			used += 1
		end
		local drag = self.drag
		self:_paintCard(self.cards[index], slot, {
			held = held == index,
			selected = self.selected == index,
			target = drag ~= nil and drag.active and drag.hover == index and drag.hover ~= drag.from,
			source = drag ~= nil and drag.active and drag.from == index,
			detail = (self.selected == index or self.hovered == index) and not (drag ~= nil and drag.active),
		})
	end
	local closeKey = self.options.closeKeyLabel and self.options.closeKeyLabel()
	self.footRight.Text = string.format("%d / %d slots used%s", used, SLOT_COUNT, closeKey and ("   •   [" .. closeKey .. "] close") or "")
	-- DROP is offered only for a selected slot that actually holds something: an empty slot has
	-- nothing to put on the ground, and a button that refuses is worse than one that isn't there.
	local canDrop = self.selected ~= nil and slots[self.selected] ~= nil
	if self.dropButton then
		self.dropButton.Visible = canDrop
	end

	if self.selected then
		self.hint.Text = string.format("Now tap where slot %s goes, or DROP to put it on the ground.",
			self.options.keyLabel and self.options.keyLabel(self.selected) or tostring(self.selected))
		self.hint.TextColor3 = SELECT
	else
		self.hint.Text = "Drag a slot onto another to swap them. Tap one to move or drop it."
		self.hint.TextColor3 = C.Muted
	end
end

--------------------------------------------------------------------------------
-- Swapping
--------------------------------------------------------------------------------

function InventoryPanel:_swap(a, b)
	if a == b or not self.loadout then
		return
	end
	local slots = table.clone(self.shownSlots or self.loadout.slots)
	if not slots[a] and not slots[b] then
		return
	end
	slots[a], slots[b] = slots[b], slots[a]
	local held = self.shownEquipped
	if held == nil then
		held = self.loadout.equipped
	end
	if held == a then
		held = b
	elseif held == b then
		held = a
	end
	self.shownSlots, self.shownEquipped = slots, held
	self.selected = nil
	self:_render()
	for _, index in ipairs({ a, b }) do
		local refs = self.cards[index]
		refs.scale.Scale = 0.86
		tween(refs.scale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	if self.options.onSwap then
		self.options.onSwap(a, b)
	end
	-- If the server doesn't answer with a new loadout, it refused: show what it last said.
	self.token += 1
	local token = self.token
	task.delay(CONFIRM_WAIT, function()
		if token == self.token and self.shownSlots then
			self.shownSlots, self.shownEquipped = nil, nil
			self:_render()
		end
	end)
end

function InventoryPanel:_tap(index)
	if not self.loadout then
		return
	end
	local slots = self.shownSlots or self.loadout.slots
	if self.selected == nil then
		if slots[index] then
			self.selected = index
		end
	elseif self.selected == index then
		self.selected = nil
	else
		self:_swap(self.selected, index)
		return
	end
	self:_render()
end

--------------------------------------------------------------------------------
-- Pointer: press, drag, release. Mouse and touch alike.
--------------------------------------------------------------------------------

function InventoryPanel:_cardAt(position)
	for index, refs in ipairs(self.cards) do
		local at, size = refs.card.AbsolutePosition, refs.card.AbsoluteSize
		if position.X >= at.X and position.X <= at.X + size.X and position.Y >= at.Y and position.Y <= at.Y + size.Y then
			return index
		end
	end
	return nil
end

-- `position` is in screen pixels. The lifted card lives in the panel's parent, which in a gallery is a
-- scaled mock screen rather than the ScreenGui itself, so undo that parent's scale too.
function InventoryPanel:_moveLifted(position)
	local parent = self.lifted.card.Parent
	local origin, scale = Vector2.zero, 1
	if parent:IsA("GuiObject") then
		origin = parent.AbsolutePosition
		if parent.Size.X.Offset > 0 then
			scale = parent.AbsoluteSize.X / parent.Size.X.Offset
		end
	end
	self.lifted.card.Position = UDim2.fromOffset((position.X - origin.X) / scale, (position.Y - origin.Y) / scale)
end

function InventoryPanel:_connectPointer()
	for index, refs in ipairs(self.cards) do
		refs.card.InputBegan:Connect(function(input)
			if not self.open then
				return
			end
			local kind = input.UserInputType
			if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
				return
			end
			if self.drag then
				return
			end
			self.drag = { from = index, start = Vector2.new(input.Position.X, input.Position.Y), input = input, active = false, hover = nil }
		end)
		-- Hovering a card shows its detail (#86 C14); a tap does too, by selecting it. A gamepad's
		-- selection counts as hovering, since it has no pointer.
		local function hover(on)
			if on then
				self.hovered = index
			elseif self.hovered == index then
				self.hovered = nil
			end
			if self.open then
				self:_render()
			end
		end
		refs.card.MouseEnter:Connect(function()
			hover(true)
		end)
		refs.card.MouseLeave:Connect(function()
			hover(false)
		end)
		refs.card.SelectionGained:Connect(function()
			hover(true)
		end)
		refs.card.SelectionLost:Connect(function()
			hover(false)
		end)
		-- A gamepad pressing A on a selected card taps it (there's no pointer to drag with).
		refs.card.Activated:Connect(function(input)
			if self.open and input and string.sub(input.UserInputType.Name, 1, 7) == "Gamepad" then
				self:_tap(index)
			end
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		local drag = self.drag
		if not drag or not self.open then
			return
		end
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.MouseMovement and not (kind == Enum.UserInputType.Touch and (input == drag.input or drag.input.UserInputType ~= Enum.UserInputType.Touch)) then
			return
		end
		local position = Vector2.new(input.Position.X, input.Position.Y)
		if not drag.active then
			local slots = self.shownSlots or (self.loadout and self.loadout.slots) or {}
			if (position - drag.start).Magnitude < DRAG_START or not slots[drag.from] then
				return
			end
			drag.active = true
			self.selected = nil
			local lifted = self.lifted
			self:_paintCard(lifted, slots[drag.from], { selected = true })
			lifted.key.Text = self.options.keyLabel and self.options.keyLabel(drag.from) or tostring(drag.from)
			lifted.card.Size = UDim2.fromOffset(CARD_W * self.scale.Scale, CARD_H * self.scale.Scale)
			self.liftedScale.Scale = 1
			lifted.card.Rotation = -4
			lifted.card.Visible = true
		end
		self:_moveLifted(position)
		local hover = self:_cardAt(position)
		if hover ~= drag.hover then
			drag.hover = hover
			self:_render()
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		local drag = self.drag
		if not drag then
			return
		end
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then
			return
		end
		if kind == Enum.UserInputType.Touch and drag.input.UserInputType == Enum.UserInputType.Touch and input ~= drag.input then
			return
		end
		self.drag = nil
		self.lifted.card.Visible = false
		if not self.open then
			return
		end
		if drag.active then
			local target = self:_cardAt(Vector2.new(input.Position.X, input.Position.Y))
			if target and target ~= drag.from then
				self:_swap(drag.from, target)
			else
				self:_render()
			end
		elseif self:_cardAt(Vector2.new(input.Position.X, input.Position.Y)) == drag.from then
			self:_tap(drag.from)
		end
	end)
end

--------------------------------------------------------------------------------
-- Opening, closing, updates
--------------------------------------------------------------------------------

-- The panel's size for a viewport. Kept as the target, so an open or a resize mid-animation always
-- settles at the right size rather than wherever the pop happened to be.
function InventoryPanel:SetViewport(viewport)
	self:_setColumns(InventoryPanel.ColumnsFor(viewport))
	self.targetScale = InventoryPanel.ScaleFor(viewport)
	self.scale.Scale = self.targetScale
end

-- Re-lays the same eight cards into a different grid when the shape of the screen changes.
function InventoryPanel:_setColumns(columns)
	if self.columns == columns then
		return
	end
	self.columns = columns
	local size = panelSize(columns)
	local rows = math.ceil(SLOT_COUNT / columns)
	self.root.Size = UDim2.fromOffset(size.X, size.Y)
	self.grid.Size = UDim2.fromOffset(size.X - PAD * 2, rows * CARD_H + (rows - 1) * GAP)
	for index, refs in ipairs(self.cards) do
		local column = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		refs.card.Position = UDim2.fromOffset(column * (CARD_W + GAP) + CARD_W / 2, row * (CARD_H + GAP) + CARD_H / 2)
	end
end

-- A fresh loadout from the server: it's the truth, so any local guess is dropped.
function InventoryPanel:SetLoadout(loadout)
	self.loadout = loadout
	self.shownSlots, self.shownEquipped = nil, nil
	self.token += 1
	if not loadout then
		self.selected = nil
	end
	if self.drag and loadout and not loadout.slots[self.drag.from] then
		self.drag = nil
		self.lifted.card.Visible = false
	end
	if self.open then
		self:_render()
	end
end

function InventoryPanel:IsOpen()
	return self.open
end

function InventoryPanel:Open(loadout)
	if loadout ~= nil then
		self.loadout = loadout
	end
	self.shownSlots, self.shownEquipped, self.selected, self.drag = nil, nil, nil, nil
	self.open = true
	self:_render()
	self.overlay.Visible = true
	self.root.Visible = true
	self.overlay.BackgroundTransparency = 1
	self.root.GroupTransparency = 1
	local scale = self.targetScale or self.scale.Scale
	tween(self.overlay, 0.2, { BackgroundTransparency = 0.45 })
	tween(self.root, 0.18, { GroupTransparency = 0 })
	self.scale.Scale = scale * 0.94
	tween(self.scale, 0.28, { Scale = scale }, Enum.EasingStyle.Back)
	-- A gamepad has no pointer: start its selection on the card in hand (or the first).
	if UserInputService.GamepadEnabled then
		local held = self.loadout and self.loadout.equipped
		GuiService.SelectedObject = self.cards[held or 1].card
	end
end

-- `byPanel` is true when the panel closed itself (overlay, close button), so the caller hears about it.
function InventoryPanel:Close(byPanel)
	if not self.open then
		return
	end
	self.open = false
	self.selected, self.drag, self.hovered = nil, nil, nil
	self.lifted.card.Visible = false
	local selected = GuiService.SelectedObject
	if selected and selected:IsDescendantOf(self.root) then
		GuiService.SelectedObject = nil
	end
	local token = self.token + 1
	self.token = token
	tween(self.overlay, 0.15, { BackgroundTransparency = 1 })
	tween(self.root, 0.15, { GroupTransparency = 1 })
	task.delay(0.16, function()
		if not self.open then
			self.overlay.Visible = false
			self.root.Visible = false
		end
	end)
	if byPanel and self.options.onClose then
		self.options.onClose()
	end
end

-- For galleries: open instantly, with a slot selected or a drag frozen part way (from, over, pointer).
function InventoryPanel:Snap(loadout, state)
	state = state or {}
	self.loadout = loadout
	self.open = true
	self.overlay.Visible = true
	self.overlay.BackgroundTransparency = 0.45
	self.root.Visible = true
	self.root.GroupTransparency = 0
	self.selected = state.selected
	self.drag = nil
	if state.dragFrom then
		self.drag = { from = state.dragFrom, active = true, hover = state.dragOver, start = Vector2.zero }
	end
	self:_render()
	if state.dragFrom and state.pointer then
		local lifted = self.lifted
		self:_paintCard(lifted, loadout.slots[state.dragFrom], { selected = true })
		lifted.key.Text = tostring(state.dragFrom)
		lifted.card.Size = UDim2.fromOffset(CARD_W * self.scale.Scale, CARD_H * self.scale.Scale)
		lifted.card.Rotation = -4
		lifted.card.Visible = true
		self:_moveLifted(state.pointer)
	end
end

InventoryPanel.CardAt = InventoryPanel._cardAt

return InventoryPanel
