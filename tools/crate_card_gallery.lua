-- Crate cards AND the crate open, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/crate_card_gallery.lua -OutDir <folder>
--
-- Two halves in one file on purpose: Studio runs one at a time behind a machine-wide lock with ten
-- sessions queued behind it, so a picture that could have shared a slot and didn't costs everyone
-- half an hour. The card views come first, then the open's film strips.
--
-- The Crates tab's card in both states, so the hidden Beginner's Luck boost can be judged by eye:
-- a normal card with its percentages, and a boosted card, which lists the rarities it can drop and
-- no percentages (a percentage there would be a number the roll doesn't use). Nothing on a boosted
-- card says why, which is the point: the feature is meant to be invisible.
--
-- The card is rebuilt here with MenuClient's own measurements (118-tall card, 102 icon at 8,8, text
-- column at x 124, rows at y 8 / 32 / 52, best drops at y 70, buttons 196x39 on the right, its fonts
-- and sizes) and its real contents: CrateModels.Crate for the icon, BrainrotModels for the best-drop
-- photos, and CrateData.OddsLine for the odds -- the same three functions the menu calls, so what
-- shows here is what shows in game. MenuClient is a LocalScript and can't be required, which is why
-- the frame around them is rebuilt rather than run.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CrateData = require(Shared:WaitForChild("CrateData"))
local CrateModels = require(Shared:WaitForChild("CrateModels"))
local CrateOpen = require(Shared:WaitForChild("CrateOpen"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local Rarity = require(Shared:WaitForChild("Rarity"))
local UiKit = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("UiKit"))
local UiParts = require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("UiParts"))

local create, rounded, formatNumber = UiKit.create, UiKit.rounded, UiKit.formatNumber
local C = UiKit.Colors
local BEST_DROPS_SHOWN = 5

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

-- MenuClient's crateIcon: the shared crate model in a ViewportFrame, so a card here carries the same
-- per-tier crate the player sees. A tier whose model fails to build is worth knowing about, so it
-- says so rather than quietly falling back.
local function crateIcon(parent, tier, color, size)
	local viewport = create("ViewportFrame", {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(160, 160, 172),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(10) })

	local ok, model = pcall(CrateModels.Crate, tier, { color = color })
	if not ok or not model then
		note("NO CRATE MODEL for %s: %s", tier, tostring(model))
		return viewport
	end
	model.Parent = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(4.5, 4, -9), Vector3.new(0, 0.4, 0))
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	return viewport
end

-- MenuClient's brainrotPhoto, for the best-drops strip.
local function brainrotPhoto(parent, def, size)
	local viewport = create("ViewportFrame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.PanelAlt,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 182),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.4, -1, 0.6),
		Parent = parent,
	}, { rounded(10) })
	local built, model = pcall(BrainrotModels.Build, def)
	if built and model then
		model.Parent = viewport
		pcall(BrainrotModels.FrameViewport, viewport, def)
	end
	return viewport
end

-- One card, as the Crates tab draws it in the normal (not narrow) layout.
local function card(parent, tier, luck, boosted, owned, order)
	local crate = CrateData.Get(tier)
	local color = crate.color or Rarity.Color(tier)
	local odds = CrateData.OddsLine(crate, luck, boosted)

	local frame = create("Frame", {
		Size = UDim2.new(1, -8, 0, 118),
		BackgroundColor3 = C.Panel,
		BorderSizePixel = 0,
		LayoutOrder = order,
		Parent = parent,
	}, { rounded(10) })
	create("UIStroke", { Color = color, Thickness = 1.5, Transparency = 0.4, Parent = frame })

	crateIcon(frame, tier, color, 102)

	local function line(y, text, colour, font, size)
		create("TextLabel", {
			Position = UDim2.new(0, 124, 0, y),
			Size = UDim2.new(1, -340, 0, size + 6),
			BackgroundTransparency = 1,
			Font = font,
			Text = text,
			TextColor3 = colour,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextSize = size,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		})
	end

	local stockNote = crate.robuxOnly and "  •  ALWAYS IN STOCK" or ""
	line(8, string.format("%s  (owned: %d)%s", crate.name, owned, stockNote), color, Enum.Font.GothamBold, 17)
	-- The odds row. On a boosted card this is rarity names only -- no pity counter above it either
	-- (Oliver, 2026-09-17), though the guarantee itself still fires in CrateService.
	line(32, table.concat(odds, "   "), C.Text, Enum.Font.GothamBold, 12)
	line(52, (crate.description or "") .. "  Best possible drops:", C.Muted, Enum.Font.Gotham, 12)

	-- The rarest brainrots this crate can actually roll, as photos, exactly as the tab picks them.
	local best = {}
	for rarityIndex = #Rarity.Order, 1, -1 do
		local rarityName = Rarity.Order[rarityIndex]
		if (crate.odds[rarityName] or 0) > 0 then
			for _, def in ipairs(BrainrotData.OfRarity(rarityName)) do
				if #best < BEST_DROPS_SHOWN then
					table.insert(best, def)
				end
			end
		end
	end
	for position, def in ipairs(best) do
		brainrotPhoto(frame, def, 42).Position = UDim2.fromOffset(124 + (position - 1) * 46, 70)
	end

	-- The price and OPEN buttons, in the tab's 196x39 grid on the right.
	local buttons = create("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(196, 39),
		BackgroundTransparency = 1,
		Parent = frame,
	}, {
		create("UIGridLayout", {
			CellSize = UDim2.fromOffset(95, 39),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local function button(order2, text, colour)
		create("TextButton", {
			BackgroundColor3 = colour,
			LayoutOrder = order2,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = C.Text,
			TextSize = 14,
			Parent = buttons,
		}, { rounded(8) })
	end
	if crate.robuxOnly then
		local product = crate.productKey and GamepassConfig.Products[crate.productKey]
		button(1, ((product and product.suggestedPrice) or 0) .. " R$", C.Accent)
	else
		button(1, formatNumber(crate.coinPrice or 0) .. " C", C.Accent)
	end
	button(2, "OPEN", C.Green)

	note("%s luck %d boosted=%s -> %s", tier, luck, tostring(boosted), table.concat(odds, "  "))
	return frame
end

-- A panel of cards with a caption, laid out like the Crates tab's list.
local GUI_NAME = "BRR_CrateCards"

-- A ScreenGui under StarterGui: that is what Studio draws over the 3D view, which is what the
-- gallery captures. (Parenting it to the view's own folder drew nothing at all.)
local function panel(_folder, caption, rows)
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = create("ScreenGui", { Name = GUI_NAME, IgnoreGuiInset = true, Parent = StarterGui })
	local shell = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 150 + #rows * 126),
		BackgroundColor3 = C.Bg,
		BorderSizePixel = 0,
		Parent = gui,
	}, { rounded(14) })
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 14),
		Size = UDim2.new(1, -40, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "CRATES",
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 20,
		Parent = shell,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 44),
		Size = UDim2.new(1, -40, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = caption,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		Parent = shell,
	})
	local list = create("Frame", {
		Position = UDim2.fromOffset(16, 76),
		Size = UDim2.new(1, -32, 1, -92),
		BackgroundTransparency = 1,
		Parent = shell,
	}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })
	for index, row in ipairs(rows) do
		card(list, row[1], row[2], row[3], row[4] or 1, index)
	end
	return gui
end

-- The Style Crates tab's rows, which are not cards: the tab draws them with UiParts.splitRow (media,
-- three lines of text, and its prices and OPEN as actions), so the gallery draws them with the same
-- function rather than a lookalike. Both coin and Robux prices are on every tier, and the odds line
-- carries percentages -- these are sold, so they are never a boosted card.
local function stylePanel(caption)
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local tiers = { "Style", "DeluxeStyle", "PrestigeStyle" }
	local gui = create("ScreenGui", { Name = GUI_NAME, IgnoreGuiInset = true, Parent = StarterGui })
	local shell = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(820, 560),
		BackgroundColor3 = C.Bg,
		BorderSizePixel = 0,
		Parent = gui,
	}, { rounded(14) })
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 14),
		Size = UDim2.new(1, -40, 0, 26),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = "STYLE CRATES",
		TextColor3 = C.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 20,
		Parent = shell,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(20, 44),
		Size = UDim2.new(1, -40, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = caption,
		TextColor3 = C.Muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = 14,
		Parent = shell,
	})
	local width = 760
	local list = create("Frame", {
		Position = UDim2.fromOffset(20, 76),
		Size = UDim2.fromOffset(width, 460),
		BackgroundTransparency = 1,
		Parent = shell,
	}, { create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }) })

	for index, tier in ipairs(tiers) do
		local crate = CrateData.Get(tier)
		local color = crate.color or Rarity.Color(tier)
		local product = crate.productKey and GamepassConfig.Products[crate.productKey]
		local lineHeight = UiKit.Type.Caption.Size + 6
		local row = UiParts.splitRow(list, {
			width = width,
			mediaInstance = crateIcon(nil, tier, color, 102),
			textHeight = UiKit.Type.Heading.Size + 6 + lineHeight * 4,
			layoutOrder = index,
			actions = {
				{ kind = "primary", text = "OPEN", width = 92, enabled = true, onClick = function() end },
				{ kind = "secondary", text = formatNumber(crate.coinPrice) .. " C", width = 104, enabled = true, onClick = function() end },
				{ kind = "secondary", text = (product and product.suggestedPrice or 0) .. " R$", width = 96, enabled = true, onClick = function() end },
			},
		})
		row.Line({ text = string.format("%s  (owned: %d)", crate.name, 0), style = UiKit.Type.Heading, color = color })
		row.Line({ text = crate.description or "", style = UiKit.Type.Caption, color = UiKit.Role.TextMuted })
		-- The odds label, exactly as renderStyleCrates draws it: grown to fit, never truncated. This
		-- render is the reason it is that way -- a row.Line clipped "Myth 0.40%  Secr 0.10%" off the
		-- Style Crate's odds and the picture showed it.
		UiParts.text(row.Text, UiKit.Type.Caption, table.concat(CrateData.OddsLine(crate, 1, false), "   "),
			UiKit.Role.Text, {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				TextWrapped = true,
				TextTruncate = Enum.TextTruncate.None,
				TextYAlignment = Enum.TextYAlignment.Top,
				LayoutOrder = 3,
			})
		note("%s: %d C / %d R$ -> %s", tier, crate.coinPrice, product and product.suggestedPrice or 0,
			table.concat(CrateData.OddsLine(crate, 1, false), "  "))
	end
	return gui
end

local views = {}
local function view(name, fn)
	table.insert(views, { name = name, settle = 2, setup = function(folder, camera)
		camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(10), 0, 0)
		fn(folder)
	end })
end

view("crate_cards_normal", function(folder)
	panel(folder, "No Beginner's Luck: every card shows the odds it rolls.", {
		{ "Common", 1, false, 2 }, { "Rare", 1, false, 1 }, { "Legendary", 1, false, 1 },
	})
end)

view("crate_cards_boosted", function(folder)
	panel(folder, "Beginner's Luck active on these free crates: rarities, no percentages, nothing says why.", {
		{ "Common", 4, true, 2 }, { "Rare", 4, true, 1 }, { "Legendary", 4, true, 1 },
	})
end)

view("crate_cards_side_by_side", function(folder)
	panel(folder, "The same Common Crate: normal, then with the hidden boost.", {
		{ "Common", 1, false, 2 }, { "Common", 4, true, 2 },
	})
end)

view("crate_cards_pass_owner", function(folder)
	panel(folder, "A 2x Crate Luck owner: a bought crate shows its 2x odds; a boosted free one shows none (it rolls at 8x).", {
		{ "Legendary", 2, false, 1 }, { "Legendary", 8, true, 1 },
	})
end)

view("crate_cards_style_tiers", function()
	stylePanel("The three cosmetic tiers, as the Style Crates tab draws them: coins or Robux, real percentages on every one.")
end)

local BASE = Vector3.new(0, 1400, 0)
local SPACING = 7
-- Fractions of each tier's own swing. The last is the end of it.
local FRACTIONS = { 0, 0.16, 0.36, 0.56, 0.8, 1 }
local STRIPS = { "Common", "Legendary", "Secret", "Style", "DeluxeStyle", "PrestigeStyle" }
-- The ladder the per-tier numbers are meant to climb, cheapest first.
local LADDER = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }

local checks, failures = 0, 0
local function check(ok, text)
	checks += 1
	if not ok then
		failures += 1
	end
	note((ok and "PASS  " or "FAIL  ") .. text)
end

local stage = Instance.new("Folder")
stage.Name = "CrateOpenStage"
stage.Parent = workspace

-- One crate, posed `since` seconds into its open. `pose` is how to move the lid: the real swing, or
-- the old fly-off, which is here only so the measurement below can be shown to fail.
local function posed(tier, since, at, pose)
	local model, lid = CrateModels.Crate(tier, {})
	model.Parent = stage
	model:PivotTo(CFrame.new(at))
	-- Read the lid's pose AFTER the model is placed: the riders' offsets are taken from it.
	local lidStart = lid.CFrame
	local riders = { { part = lid, offset = CFrame.identity } }
	for _, part in ipairs(lid:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(riders, { part = part, offset = lidStart:ToObjectSpace(part.CFrame) })
		end
	end
	local lidNow = pose(lidStart, lid, since, tier)
	for _, rider in ipairs(riders) do
		rider.part.CFrame = lidNow * rider.offset
	end
	return model, lid, lidStart
end

local function hingedPose(lidStart, lid, since, tier)
	return CrateOpen.LidCFrame(lidStart, CrateOpen.Hinge(lid), CrateOpen.Angle(since, tier))
end

-- The old behaviour, for the planted-failure check only: lifted into the air and spun about its own
-- centre, which takes the hinge with it.
local function flyOffPose(lidStart, _lid, since)
	local t = math.clamp(since / 0.6, 0, 1)
	return CFrame.new(0, t * 9, t * 4) * lidStart * CFrame.Angles(t * 2.5, 0, t * 0.8)
end

-- Where the hinge and the lid's front edge are, in the world, for a lid posed by `pose`. Built off
-- to one side and thrown away: this is measurement, not the picture.
local function measureAt(tier, since, pose)
	local model, lid = posed(tier, since, BASE + Vector3.new(0, -400, 0), pose)
	local hinge = CrateOpen.Hinge(lid)
	local hingeWorld = (lid.CFrame * hinge).Position
	-- The hinge is at the middle of the BACK edge, so the front edge is one lid-length forward of it
	-- along the lid's own -Z.
	local frontWorld = (lid.CFrame * hinge * CFrame.new(0, 0, -lid.Size.Z)).Position
	local pivotY = model:GetPivot().Position.Y
	model:Destroy()
	return hingeWorld, frontWorld, pivotY
end

-- Measurement, before anything is rendered --------------------------------------------------------
do
	for _, tier in ipairs({ "Legendary", "PrestigeStyle" }) do
		local swing = CrateOpen.Duration(tier)
		local startHinge, startFront, pivotY = measureAt(tier, 0, hingedPose)
		local worst = 0
		for _, fraction in ipairs(FRACTIONS) do
			local hingeWorld = measureAt(tier, fraction * swing, hingedPose)
			worst = math.max(worst, (hingeWorld - startHinge).Magnitude)
		end
		check(worst < 0.05, string.format("%s: the hinge holds still through the swing (worst drift %.3f studs)", tier, worst))

		local _, frontEnd = measureAt(tier, swing, hingedPose)
		check(frontEnd.Y > startFront.Y + 2, string.format("%s: the lid ends up open, not shut (front edge %.2f -> %.2f above a pivot at %.1f)",
			tier, startFront.Y - pivotY, frontEnd.Y - pivotY, pivotY))
		check(frontEnd.Z > startFront.Z + 1, string.format("%s: the lid swings BACK over its hinge, not down into the crate (front z %.2f -> %.2f)",
			tier, startFront.Z, frontEnd.Z))
	end

	-- Planted failure: the old fly-off, measured the same way, must move the hinge a long way.
	local startHinge = measureAt("Legendary", 0, hingedPose)
	local oldWorst = 0
	for _, fraction in ipairs(FRACTIONS) do
		local hingeWorld = measureAt("Legendary", fraction * 0.6, flyOffPose)
		oldWorst = math.max(oldWorst, (hingeWorld - startHinge).Magnitude)
	end
	check(oldWorst > 1, string.format("planted: the old fly-off moves the hinge and is caught (%.2f studs)", oldWorst))

	-- The ladder: each tier's swing has to be at least as slow and as heavy as the one below it, and
	-- the ends have to actually differ -- numbers that all came out the same would render six
	-- identical strips and look fine.
	local rising, lastDuration, lastOvershoot = true, 0, 0
	for _, tier in ipairs(LADDER) do
		local style = CrateOpen.For(tier)
		if style.duration < lastDuration - 1e-6 or style.overshoot < lastOvershoot - 1e-6 then
			rising = false
		end
		lastDuration, lastOvershoot = style.duration, style.overshoot
	end
	check(rising, "the brainrot ladder never opens faster or lighter as it gets rarer")
	local cheap, dear = CrateOpen.For("Common"), CrateOpen.For("PrestigeStyle")
	check(dear.duration > cheap.duration * 1.5, string.format("the top tier opens far slower than the bottom (%.2fs vs %.2fs)",
		dear.duration, cheap.duration))
	for _, tier in ipairs({ "Style", "DeluxeStyle", "PrestigeStyle" }) do
		local style = CrateOpen.For(tier)
		note("%s", string.format("%s: %.2fs swing, %.0f%% overshoot, %.0f%% press-down", tier, style.duration,
			style.overshoot * 100, style.anticipation * 100))
	end
end

-- A 3D view: the card GUI is taken down first, or it would sit over the crates.
local function add(name, fn)
	table.insert(views, { name = name, settle = 1.2, hold = 2, setup = function(folder, camera)
		local gui = StarterGui:FindFirstChild(GUI_NAME)
		if gui then
			gui:Destroy()
		end
		fn(folder, camera)
	end })
end

local function clearStage()
	for _, child in ipairs(stage:GetChildren()) do
		child:Destroy()
	end
end

-- The moment a frame is, floating over the crate it belongs to.
local function timeLabel(at, text)
	local anchor = Instance.new("Part")
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(at + Vector3.new(0, 7, 0))
	anchor.Anchored = true
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.Parent = stage
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(130, 34)
	billboard.AlwaysOnTop = true
	billboard.Parent = anchor
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.TextSize = 22
	label.Parent = billboard
end

-- A film strip: one tier, six moments of its own swing, left to right.
for _, tier in ipairs(STRIPS) do
	add("crate_open_" .. tier, function(_folder, camera)
		clearStage()
		local swing = CrateOpen.Duration(tier)
		local width = (#FRACTIONS - 1) * SPACING
		for index, fraction in ipairs(FRACTIONS) do
			-- Laid out along -X: the camera looks from -Z, so +X draws on the LEFT and a strip built
			-- the obvious way reads backwards in the picture.
			local at = BASE + Vector3.new(width / 2 - (index - 1) * SPACING, 0, 0)
			posed(tier, fraction * swing, at, hingedPose)
			timeLabel(at, string.format("%.2fs", fraction * swing))
		end
		camera.FieldOfView = 40
		camera.CFrame = CFrame.lookAt(BASE + Vector3.new(0, 5.5, -26), BASE + Vector3.new(0, 2.6, 0))
	end)
end

-- The three cosmetic tiers at the same moment of their own swings, stacked: the quality ladder in
-- one picture (#60).
add("crate_open_style_ladder", function(_folder, camera)
	clearStage()
	local tiers = { "Style", "DeluxeStyle", "PrestigeStyle" }
	local width = (#FRACTIONS - 1) * SPACING
	for row, tier in ipairs(tiers) do
		local swing = CrateOpen.Duration(tier)
		for index, fraction in ipairs(FRACTIONS) do
			local at = BASE + Vector3.new(width / 2 - (index - 1) * SPACING, (#tiers - row) * 11, 0)
			posed(tier, fraction * swing, at, hingedPose)
			if index == #FRACTIONS then
				timeLabel(at, string.format("%s  %.2fs", tier, swing))
			end
		end
	end
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(BASE + Vector3.new(0, 14, -40), BASE + Vector3.new(0, 11, 0))
end)

-- The old animation above the new one, on the same tier, so the change is visible rather than
-- described. Top row: the lid flying off. Bottom row: the lid swinging on its hinge.
add("crate_open_before_after", function(_folder, camera)
	clearStage()
	local swing = CrateOpen.Duration("Legendary")
	local width = (#FRACTIONS - 1) * SPACING
	for index, fraction in ipairs(FRACTIONS) do
		local x = width / 2 - (index - 1) * SPACING
		posed("Legendary", fraction * 0.6, BASE + Vector3.new(x, 12, 0), flyOffPose)
		posed("Legendary", fraction * swing, BASE + Vector3.new(x, 0, 0), hingedPose)
	end
	timeLabel(BASE + Vector3.new(width / 2, 12, 0), "before")
	timeLabel(BASE + Vector3.new(width / 2, 0, 0), "after")
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(BASE + Vector3.new(0, 11, -34), BASE + Vector3.new(0, 8, 0))
end)

note("%s", string.format("crate open: %d checks, %d failures", checks, failures))
print("[PROBE] crate open: " .. (failures == 0 and "OK" or (failures .. " FAILURES")))

return views
