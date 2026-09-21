-- HUD & UX gallery, for tools/gallery.ps1:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/hud_ux_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Set ONLY to one section's name, or a set of them ({ event = true, stack = true }), to render just those
-- (nil renders them all).
--
--   stack      the left stack (MENU, bundle, quests) tucked away and out, on the three screens, with the
--              collapsed tab's attention state and 2x close-ups of the tab
--   event      the match event banner on mock 1920x1080, 1366x768 and phone screens with the rest of
--              the HUD outlined: the card, half way through docking, the pill in a match and while
--              spectating; every event's card; every icon and pill
--   signpost   the real lobby's signpost: from where you spawn, close up from both sides, and from
--              overhead with a line run out along every finger to its destination (a ball in the
--              finger's colour where it's aimed, a white ball where the destination really is)
--   hotbar     HudClient's hotbar and its Inventory tab at the scale HudClient gives them, on 1920x1080,
--              1366x768, 1024x768 and a phone, with the bottom-left stack and the stamina bar outlined
--   inventory  the Inventory panel over that HUD: open, a slot picked, and a drag frozen part way
--   defense    the placement preview on a test ground: each structure on a good site, too steep, no room
--              (a building, a standing bunker), a throw past its range, a mine, and one from overhead
--   phone      the in-match HUD on a touch screen: what ships today (overlapping pairs in red) beside
--              what PhoneLayout lays out, at three phone sizes, plus the lobby and spectating
--   touch      the shared touch buttons drawn by TouchControls over the approved layout map, on five sizes
--              (the flag and the touch screen are forced on for the section and put back at the end)
--   grip       a MEASUREMENT: the same 72 throws under five kit physics options, reporting how far
--              each one leaves the kit from the aim point, at rest and at its first ground contact
--   landing    a MEASUREMENT, not pictures, and always last: switches to Run mode, builds a map and throws
--              real kits through DefenseService's own throw, then notes how far they come to rest from the
--              aim point and whether what went up matched the preview
--
-- Mock screens repeat a few HudClient numbers (the hotbar's scale rule, the tab) to draw what HudClient
-- draws inline; if those change there, change Mock.hotbarScale and Mock.hotbar here too.
--
-- HOLD TIMES: gallery.ps1 watches the log for a view's "ready" line, waits 700 ms and then captures the
-- window, so a view whose `hold` is about a second can be gone by the time the shutter opens and the
-- shot shows the NEXT view instead -- which is exactly what a run of these at 0.6/1.0 did. Nothing here
-- goes below settle 1.2 and hold 1.8.

local ONLY = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local views = {}
local function add(section, view)
	if ONLY == nil or ONLY == section or (type(ONLY) == "table" and ONLY[section]) then
		table.insert(views, view)
	end
end

--------------------------------------------------------------------------------
-- Mock screens: HUD modules drawn on a screen of a given size, shrunk to fit the viewport, over sky and
-- grass, with every other HUD element outlined where HudClient and MenuClient really put it.
--------------------------------------------------------------------------------

local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local UiKit = require(Scripts:WaitForChild("UiKit"))
local Colors = UiKit.Colors

local GUI_NAME = "BRR_HudUxGallery"

local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "1366x768", size = Vector2.new(1366, 768), touch = false },
	{ name = "phone_844x390", size = Vector2.new(844, 390), touch = true },
}

local Mock = {}

-- HudClient's hotbar scale for a viewport (the "Bottom-right: ammo + slots" do-block, repeated here).
function Mock.hotbarScale(viewport)
	local room = viewport.X - 16 - (404 + 12)
	return math.clamp(math.min(1, room / 690, viewport.Y * 0.3 / 150), 0.5, 1)
end

-- Takes the last section's screen away. The world sections (signpost, defense, landing) point the camera
-- at the map, and a leftover ScreenGui from the section before would sit right over it: every gui here
-- is a child of this one, so one Destroy clears the screen.
function Mock.clear()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
end

function Mock.gui()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.Parent = StarterGui
	return gui
end

function Mock.sky(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

function Mock.outline(parent, position, size, anchor, label, shape)
	local frame = UiKit.create("Frame", {
		AnchorPoint = anchor or Vector2.zero,
		Position = position,
		Size = size,
		BackgroundColor3 = Color3.fromRGB(20, 22, 30),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = parent,
	}, { UiKit.rounded(shape == "circle" and 999 or 10) })
	UiKit.create("UIStroke", { Color = Color3.fromRGB(120, 124, 140), Thickness = 1, Parent = frame })
	UiKit.create("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = label,
		TextColor3 = Color3.fromRGB(160, 164, 180),
		TextSize = 12,
		TextWrapped = true,
		Parent = frame,
	})
	return frame
end

-- `hud` options: inMatch (READY pill hidden, match HUD shown), menuStack (the left column), lobby.
function Mock.screen(gui, camera, spec, hud)
	hud = hud or {}
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.94 / spec.size.X, viewport.Y * 0.9 / spec.size.Y)
	local screen = UiKit.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = gui,
	})
	UiKit.create("UIScale", { Scale = fit, Parent = screen })
	UiKit.create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 226, 232)),
			ColorSequenceKeypoint.new(0.56, Color3.fromRGB(104, 150, 82)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
		}),
		Parent = screen,
	})
	UiKit.create("TextLabel", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -170),
		Size = UDim2.fromOffset(400, 24),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = spec.name,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.5,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = screen,
	})

	-- The top banner, drawn like the real one.
	local banner = UiKit.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(440, 56),
		BackgroundColor3 = Colors.Background,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		Parent = screen,
	}, { UiKit.rounded(12) })
	UiKit.create("TextLabel", {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = hud.inMatch and "37 ALIVE" or "BUILDING MAP…",
		TextColor3 = Colors.Text,
		TextSize = 20,
		Parent = banner,
	})
	UiKit.create("TextLabel", {
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = hud.inMatch and "Sahur Springs   •   12 bots" or "Generating terrain, towns and loot",
		TextColor3 = Colors.Muted,
		TextSize = 14,
		Parent = banner,
	})
	if not hud.inMatch then
		local ready = UiKit.create("Frame", {
			Position = UDim2.new(0.5, 232, 0, 8),
			Size = UDim2.fromOffset(230, 60),
			BackgroundColor3 = Colors.Accent,
			BorderSizePixel = 0,
			Parent = screen,
		}, { UiKit.rounded(14) })
		UiKit.create("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne,
			Text = "READY UP",
			TextColor3 = Color3.new(0, 0, 0),
			TextSize = 24,
			Parent = ready,
		})
	end
	if hud.inMatch then
		UiKit.create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 72),
			Size = UDim2.fromOffset(440, 24),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "Storm closing  42s   •   Zone 2/6   •   3 dmg/s",
			TextColor3 = Colors.Storm,
			TextSize = 15,
			Parent = screen,
		})
		Mock.outline(screen, UDim2.new(0.5, 0, 0, 100), UDim2.fromOffset(440, 24), Vector2.new(0.5, 0), "COMPASS")
		Mock.outline(screen, UDim2.new(1, -16, 0, 108), UDim2.fromOffset(190, 190), Vector2.new(1, 0), "MINIMAP", "circle")
		Mock.outline(screen, UDim2.new(1, -16, 0, 312), UDim2.fromOffset(300, 90), Vector2.new(1, 0), "KILL FEED")
		Mock.outline(screen, UDim2.new(0, 16, 1, -96), UDim2.fromOffset(280, 80), nil, "HEALTH")
		Mock.outline(screen, UDim2.new(0, 16, 1, -166), UDim2.fromOffset(300, 62), nil, "COMPANION")
		Mock.outline(screen, UDim2.new(0, 326, 1, -166), UDim2.fromOffset(72, 72), nil, "PET")
		if hud.hotbar ~= false then
			local scale = Mock.hotbarScale(spec.size)
			Mock.outline(screen, UDim2.new(1, -16, 1, -16), UDim2.fromOffset(690 * scale, 150 * scale), Vector2.new(1, 1),
				string.format("HOTBAR x%.2f", scale))
		end
		local okStamina, anchor, position, staminaScale = pcall(function()
			return require(Scripts:WaitForChild("StaminaBar")).Layout(spec.size)
		end)
		if okStamina then
			Mock.outline(screen, position, UDim2.fromOffset(368 * staminaScale, 50 * staminaScale), anchor, "STAMINA")
		end
		Mock.outline(screen, UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(10, 10), Vector2.new(0.5, 0.5), "")
	end
	if hud.menuStack ~= false then
		-- MenuClient's ScreenGui keeps the top-bar inset (58 px on the current Roblox top bar).
		local inset = 58
		Mock.outline(screen, UDim2.new(0, 16, 0, inset + 78), UDim2.fromOffset(210, 44), nil, "COINS")
		Mock.outline(screen, UDim2.new(0, 16, 0, inset + 130), UDim2.fromOffset(210, 42), nil, "MENU [M]")
		Mock.outline(screen, UDim2.new(0, 16, 0, inset + 180), UDim2.fromOffset(210, 34), nil, "BUNDLE")
		Mock.outline(screen, UDim2.new(0, 16, 0, inset + 224), UDim2.fromOffset(250, 128), nil, "DAILY QUESTS")
	end
	if spec.touch and hud.inMatch then
		-- Roblox's touch controls on a small screen (TouchJump: 70 px at (1, -95, 1, -90); the thumbstick 90 px).
		Mock.outline(screen, UDim2.new(0, 20, 1, -110), UDim2.fromOffset(90, 90), nil, "STICK", "circle")
		Mock.outline(screen, UDim2.new(1, -95, 1, -90), UDim2.fromOffset(70, 70), nil, "JUMP", "circle")
	end
	return screen
end

--------------------------------------------------------------------------------
-- stack: the left stack tucked away and back (StarterPlayerScripts/MenuStackToggle), with MenuClient's
-- coin chip, MENU button, bundle nudge and quest tracker rebuilt as MenuClient builds them
--------------------------------------------------------------------------------

do
	local MenuStackToggle = require(Scripts:WaitForChild("MenuStackToggle"))
	local create, rounded = UiKit.create, UiKit.rounded
	local C = Colors
	local TIER = { easy = C.Green, medium = C.Accent, hard = Color3.fromRGB(255, 110, 200), weekly = Color3.fromRGB(110, 210, 255) }

	-- MenuClient's ScreenGui keeps Roblox's top-bar inset, so its pixels start below it.
	local INSET = 58

	local function menuStack(space)
		local coinChip = create("Frame", {
			Position = UDim2.new(0, 16, 0, 78),
			Size = UDim2.new(0, 210, 0, 44),
			BackgroundColor3 = C.Background,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = space,
		}, { rounded(10), UiKit.padding(10) })
		local coin = create("Frame", {
			Size = UDim2.fromOffset(24, 24),
			Position = UDim2.new(0, 0, 0.5, -12),
			BackgroundColor3 = C.Accent,
			BorderSizePixel = 0,
			Parent = coinChip,
		}, { rounded(12) })
		create("TextLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = Enum.Font.FredokaOne, Text = "S",
			TextColor3 = Color3.fromRGB(90, 62, 0), TextSize = 15, Parent = coin })
		create("TextLabel", { Position = UDim2.new(0, 32, 0, 0), Size = UDim2.new(1, -32, 1, 0), BackgroundTransparency = 1,
			Font = Enum.Font.FredokaOne, Text = "48.2K", TextColor3 = C.Accent, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 22, Parent = coinChip })

		local menuButton = create("TextButton", {
			Position = UDim2.new(0, 16, 0, 130),
			Size = UDim2.new(0, 210, 0, 42),
			BackgroundColor3 = C.Accent,
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBold,
			Text = "MENU  [M]",
			TextColor3 = Color3.new(0, 0, 0),
			TextSize = 16,
			Parent = space,
		}, { rounded(10) })

		local bundleNudge = create("TextButton", {
			Position = UDim2.new(0, 16, 0, 180),
			Size = UDim2.new(0, 210, 0, 34),
			BackgroundColor3 = Color3.fromRGB(94, 214, 122),
			BorderSizePixel = 0,
			Font = Enum.Font.GothamBlack,
			Text = "STARTER BUNDLE  •  300 R$",
			TextColor3 = Color3.new(0, 0, 0),
			TextSize = 14,
			Parent = space,
		}, { rounded(10) })
		create("UIStroke", { Color = Color3.new(1, 1, 1), Thickness = 2, Transparency = 0.1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = bundleNudge })

		local tracker = create("TextButton", {
			Position = UDim2.new(0, 16, 0, 224),
			Size = UDim2.fromOffset(250, 40),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = C.Background,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
			AutoButtonColor = false,
			Text = "",
			Parent = space,
		}, {
			rounded(10),
			create("UIStroke", { Color = C.Panel, Thickness = 1.5 }),
			create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }),
			create("UIPadding", { PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8), PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }),
		})
		local header = create("Frame", { Size = UDim2.new(1, 0, 0, 18), BackgroundTransparency = 1, LayoutOrder = 0, Parent = tracker })
		create("TextLabel", { Size = UDim2.new(1, -60, 1, 0), BackgroundTransparency = 1, Font = Enum.Font.GothamBlack, Text = "DAILY QUESTS  [J]",
			TextColor3 = C.Accent, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12, Parent = header })
		create("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(60, 18), BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold, Text = "2 / 3", TextColor3 = C.Muted, TextXAlignment = Enum.TextXAlignment.Right, TextSize = 12, Parent = header })
		for index, quest in ipairs({ { "Open 6 chests", "easy", 6, 6 }, { "Deal 2,500 damage", "medium", 2500, 2500 }, { "Win a match", "hard", 0, 1 } }) do
			local done = quest[3] >= quest[4]
			local line = create("Frame", { Size = UDim2.new(1, 0, 0, 30), BackgroundTransparency = 1, LayoutOrder = index, Parent = tracker })
			create("Frame", { Position = UDim2.fromOffset(0, 5), Size = UDim2.fromOffset(6, 6), BackgroundColor3 = TIER[quest[2]], BorderSizePixel = 0, Parent = line }, { rounded(3) })
			create("TextLabel", { Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -70, 0, 16), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
				Text = quest[1], TextColor3 = done and C.Muted or C.Text, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 12, Parent = line })
			create("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 0), Size = UDim2.fromOffset(56, 16), BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold, Text = done and "DONE" or string.format("%d/%d", quest[3], quest[4]), TextColor3 = done and C.Green or C.Muted,
				TextXAlignment = Enum.TextXAlignment.Right, TextSize = 11, Parent = line })
			local track = create("Frame", { Position = UDim2.fromOffset(12, 20), Size = UDim2.new(1, -12, 0, 5), BackgroundColor3 = C.PanelAlt, BorderSizePixel = 0, Parent = line }, { rounded(3) })
			create("Frame", { Size = UDim2.fromScale(math.clamp(quest[3] / quest[4], 0, 1), 1), BackgroundColor3 = TIER[quest[2]], BorderSizePixel = 0, Parent = track }, { rounded(3) })
		end
		local weekly = create("Frame", { Size = UDim2.new(1, 0, 0, 16), BackgroundTransparency = 1, LayoutOrder = 4, Parent = tracker })
		create("TextLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Font = Enum.Font.GothamBold, Text = "WEEKLY CHALLENGES  1 / 2  •  3d 4h left",
			TextColor3 = TIER.weekly, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 11, Parent = weekly })
		return { menuButton, bundleNudge, tracker }
	end

	local STATES = {
		{ name = "expanded", collapsed = false },
		{ name = "collapsed", collapsed = true },
		{ name = "collapsed_attention", collapsed = true, attention = true },
	}
	for _, spec in ipairs(SCREENS) do
		for _, state in ipairs(STATES) do
			add("stack", {
				name = "stack_" .. spec.name .. "_" .. state.name,
				settle = 1.2,
				hold = 1.8,
				setup = function(_, camera)
					Mock.sky(camera)
					local gui = Mock.gui()
					local screen = Mock.screen(gui, camera, spec, { inMatch = true, menuStack = false })
					-- Roblox's own top-bar buttons, top left.
					Mock.outline(screen, UDim2.fromOffset(12, 10), UDim2.fromOffset(150, 44), nil, "ROBLOX TOP BAR")
					local space = create("Frame", {
						Position = UDim2.fromOffset(0, INSET),
						Size = UDim2.new(1, 0, 1, -INSET),
						BackgroundTransparency = 1,
						Parent = screen,
					})
					local toggle = MenuStackToggle.new(space, { items = menuStack(space) })
					toggle:SetSummary("2/3")
					toggle:SetCollapsed(state.collapsed, true)
					if state.attention then
						toggle:Attention()
					end
				end,
			})
		end
	end

	-- Close-ups at 2x: the tab expanded, collapsed, collapsed with something new, and hovered.
	add("stack", {
		name = "stack_tab_closeups_2x",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local page = create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(1230, 710),
				BackgroundColor3 = Color3.fromRGB(96, 120, 150),
				BorderSizePixel = 0,
				Parent = gui,
			})
			local viewport = camera.ViewportSize
			create("UIScale", { Scale = math.min(viewport.X * 0.95 / 1230, viewport.Y * 0.95 / 710), Parent = page })
			for index, state in ipairs({ { false }, { true }, { true, true }, { false, false, true } }) do
				local cell = create("Frame", {
					Position = UDim2.fromOffset(10 + ((index - 1) % 2) * 610, 10 + math.floor((index - 1) / 2) * 350),
					Size = UDim2.fromOffset(600, 340),
					BackgroundColor3 = Color3.fromRGB(150, 190, 225),
					BorderSizePixel = 0,
					ClipsDescendants = true,
					Parent = page,
				})
				-- Screen pixels 0..300 across and 110..280 down, drawn twice the size.
				local space = create("Frame", { Position = UDim2.fromOffset(0, -220), Size = UDim2.fromOffset(300, 700), BackgroundTransparency = 1, Parent = cell })
				create("UIScale", { Scale = 2, Parent = space })
				local toggle = MenuStackToggle.new(space, { items = menuStack(space) })
				toggle:SetSummary("2/3")
				toggle:SetCollapsed(state[1], true)
				if state[2] then
					toggle:Attention()
				end
				if state[3] then
					toggle.hovered = true
					toggle:_paintHover()
				end
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- event: the match event banner (StarterPlayerScripts/EventBanner)
--------------------------------------------------------------------------------

do
	local MatchEvents = require(Shared:WaitForChild("MatchEvents"))
	local EventBanner = require(Scripts:WaitForChild("EventBanner"))

	local function describe(id)
		for _, event in ipairs(MatchEvents.List) do
			if event.id == id then
				return MatchEvents.Describe(event)
			end
		end
		return MatchEvents.Describe(MatchEvents.List[1])
	end

	local PHASES = {
		{ name = "card", event = "LootFrenzy", phase = "card", inMatch = false, timer = { "building" } },
		{ name = "card_longtext", event = "NightOps", phase = "card", inMatch = true, timer = { "live", 42 } },
		{ name = "docking", event = "ZoneRush", phase = "docking", inMatch = true, timer = { "live", 3 } },
		{ name = "pill_in_match", event = "Headhunter", phase = "pill", inMatch = true, timer = { "live", 134 } },
		{ name = "pill_spectating", event = "RotRush", phase = "pill", inMatch = false, timer = { "live" } },
	}

	for _, spec in ipairs(SCREENS) do
		for _, entry in ipairs(PHASES) do
			add("event", {
				name = "event_" .. spec.name .. "_" .. entry.name,
				settle = 1.2,
				hold = 1.8,
				setup = function(_, camera)
					Mock.sky(camera)
					local gui = Mock.gui()
					local screen = Mock.screen(gui, camera, spec, { inMatch = entry.inMatch })
					local banner = EventBanner.new(screen)
					banner:SetViewport(spec.size)
					banner:SetDock(entry.inMatch and "slot" or "below")
					banner:SetTimer(entry.timer[1], entry.timer[2])
					banner:Snap(describe(entry.event), entry.phase)
				end,
			})
		end
	end

	-- Every event's card, at full size, a few to a sheet: names, icons, descriptions and wrapping.
	local ids = {}
	for _, event in ipairs(MatchEvents.List) do
		table.insert(ids, event.id)
	end
	for sheet = 1, math.ceil(#ids / 4) do
		add("event", {
			name = "event_cards_sheet_" .. sheet,
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				local page = UiKit.create("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(1000, 4 * 176 + 20),
					BackgroundColor3 = Color3.fromRGB(96, 120, 150),
					BorderSizePixel = 0,
					Parent = gui,
				})
				local viewport = camera.ViewportSize
				UiKit.create("UIScale", { Scale = math.min(viewport.X * 0.95 / 1000, viewport.Y * 0.95 / (4 * 176 + 20)), Parent = page })
				for slot = 1, 4 do
					local id = ids[(sheet - 1) * 4 + slot]
					if id then
						local row = UiKit.create("Frame", {
							Position = UDim2.fromOffset(0, 10 + (slot - 1) * 176),
							Size = UDim2.fromOffset(1000, 176),
							BackgroundTransparency = 1,
							Parent = page,
						})
						local banner = EventBanner.new(row)
						banner:SetViewport(Vector2.new(1000, 1080))
						banner:SetTimer(slot % 2 == 0 and "drop" or "live", slot % 2 == 0 and 12 or 95)
						banner:Snap(describe(id), "card")
						banner.card.Position = UDim2.new(0.5, 0, 0, 8)
						banner.cardScale.Scale = 1
						banner.pill.Visible = false
						banner.pillButton.Visible = false
					end
				end
			end,
		})
	end

	-- Every icon big, and every pill at its real size (then at 2x, to judge the detail).
	add("event", {
		name = "event_icons_and_pills",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local page = UiKit.create("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(1500, 840),
				BackgroundColor3 = Colors.Panel,
				BorderSizePixel = 0,
				Parent = gui,
			})
			local viewport = camera.ViewportSize
			UiKit.create("UIScale", { Scale = math.min(viewport.X * 0.96 / 1500, viewport.Y * 0.95 / 840), Parent = page })
			for index, event in ipairs(MatchEvents.List) do
				local column = (index - 1) % 6
				local rowIndex = math.floor((index - 1) / 6)
				local cell = UiKit.create("Frame", {
					Position = UDim2.fromOffset(20 + column * 245, 16 + rowIndex * 200),
					Size = UDim2.fromOffset(160, 160),
					BackgroundTransparency = 1,
					Parent = page,
				})
				EventBanner.Badge(cell, event.id, event.color, 140).Position = UDim2.fromOffset(10, 0)
				UiKit.create("TextLabel", {
					Position = UDim2.fromOffset(-20, 144),
					Size = UDim2.fromOffset(200, 20),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = event.name,
					TextColor3 = Colors.Text,
					TextSize = 15,
					Parent = cell,
				})
				local holder = UiKit.create("Frame", {
					Position = UDim2.fromOffset(20 + ((index - 1) % 4) * 370, 420 + math.floor((index - 1) / 4) * 110),
					Size = UDim2.fromOffset(472, 112),
					BackgroundTransparency = 1,
					Parent = page,
				})
				local banner = EventBanner.new(holder)
				banner:SetViewport(Vector2.new(1920, 1080))
				banner:SetTimer("live", 30 + index * 11)
				banner:Snap(MatchEvents.Describe(event), "pill")
				banner.card.Visible = false
				banner.pill.Position = UDim2.fromOffset(0, 0)
				banner.pillScale.Scale = 1.5
				banner.pillButton.Visible = false
			end
		end,
	})
end

--------------------------------------------------------------------------------
-- signpost
--------------------------------------------------------------------------------

do
	local BASE = Vector3.new(0, 2000, 0)
	local POST = BASE + Vector3.new(20, 0, 78)
	local lobby = nil

	local function ensureLobby()
		if lobby and lobby.Parent then
			return lobby
		end
		local LobbyService = require(Modules:WaitForChild("LobbyService"))
		lobby = Instance.new("Folder")
		lobby.Name = "HudUxLobby"
		lobby.Parent = workspace
		local ok, err = pcall(LobbyService.Build, lobby, BASE)
		note("signpost: lobby build " .. (ok and "ok" or tostring(err)))
		return lobby
	end

	local function shot(name, eye, target, fov)
		add("signpost", {
			name = "signpost_" .. name,
			settle = 1.5,
			hold = 1.8,
			setup = function(_, camera)
				Mock.clear()
				ensureLobby()
				camera.FieldOfView = fov or 60
				camera.CFrame = CFrame.lookAt(eye, target)
			end,
		})
	end

	-- A player's eye on the pier, walking in: the post is ahead and to the right.
	shot("from_spawn", BASE + Vector3.new(0, 5.5, 108), POST + Vector3.new(0, 7, 0), 70)
	shot("close_front", POST + Vector3.new(-9, 6.5, -12), POST + Vector3.new(0, 7.2, 0), 60)
	shot("close_back", POST + Vector3.new(10, 7.5, 12), POST + Vector3.new(0, 7.2, 0), 60)
	shot("close_west", POST + Vector3.new(-13, 8, 4), POST + Vector3.new(0, 7.2, 0), 60)
	shot("close_up_high", POST + Vector3.new(-3, 13.5, -7), POST + Vector3.new(0, 9, 0), 60)

	add("signpost", {
		name = "signpost_overhead_rays",
		settle = 1.5,
		hold = 2,
		setup = function(folder, camera)
			local built = ensureLobby()
			local function ball(position, color, size)
				local part = Instance.new("Part")
				part.Shape = Enum.PartType.Ball
				part.Size = Vector3.new(size, size, size)
				part.Position = position
				part.Color = color
				part.Material = Enum.Material.Neon
				part.Anchored = true
				part.CanCollide = false
				part.Parent = folder
			end
			for _, item in ipairs(built:GetDescendants()) do
				if item.Name == "SignpostArrow" and item:IsA("BasePart") then
					local target = item:GetAttribute("Target")
					local hub = Vector3.new(POST.X, BASE.Y + 30, POST.Z)
					local flat = Vector3.new(target.X - POST.X, 0, target.Z - POST.Z)
					local look = item.CFrame.LookVector
					local direction = Vector3.new(look.X, 0, look.Z).Unit
					local length = flat.Magnitude
					local tip = item.Parent and nil
					local color = Color3.fromRGB(255, 230, 120)
					for _, other in ipairs(built:GetDescendants()) do
						if other:IsA("WedgePart") and (other.Position - item.Position).Magnitude < 3.3 and math.abs(other.Position.Y - item.Position.Y) < 0.6 then
							color = other.Color
							tip = other
							break
						end
					end
					local ray = Instance.new("Part")
					ray.Size = Vector3.new(0.9, 0.9, length)
					ray.CFrame = CFrame.lookAt(hub + direction * length / 2, hub + direction * length)
					ray.Color = color
					ray.Material = Enum.Material.Neon
					ray.Anchored = true
					ray.CanCollide = false
					ray.Parent = folder
					ball(hub + direction * length, color, 5)
					ball(Vector3.new(target.X, BASE.Y + 30, target.Z), Color3.new(1, 1, 1), 2.6)
					note(string.format("signpost: %s ray %.0f studs, tip colour %s", tostring(item:GetAttribute("Destination")), length,
						tip and tostring(tip.Color) or "?"))
				end
			end
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(BASE + Vector3.new(0, 520, 20), BASE + Vector3.new(0, 0, 10))
		end,
	})
end

--------------------------------------------------------------------------------
-- hotbar + inventory: HudClient's hotbar rebuilt as HudClient builds it (cells, ammo, the Inventory tab)
-- at the scale HudClient gives it, and the Inventory panel (StarterPlayerScripts/InventoryPanel) over it
--------------------------------------------------------------------------------

local Loadouts = {}
do
	local WeaponData = require(Shared:WaitForChild("WeaponData"))
	local ItemData = require(Shared:WaitForChild("ItemData"))
	local function gun(id, mag, reserve)
		local def = WeaponData.Get(id)
		return { kind = "weapon", id = id, name = def.name, rarity = def.rarity, mag = mag or def.magSize, magSize = def.magSize, reserve = reserve or def.reserveAmmo }
	end
	local function item(id, count)
		local def = ItemData.Get(id)
		return { kind = "item", id = id, name = def.name, rarity = def.rarity, itemKind = def.kind, count = count, stack = def.stack, useTime = def.useTime }
	end
	Loadouts.full = {
		slots = { gun("CrocodiloRifle", 18), gun("LarilaSniper", 3), item("ShieldPotion", 2), item("Bandage", 7), false, item("RotBarricade", 2),
			item("BlinkBean", 3), gun("PatapimChaingun", 0, 40) },
		equipped = 1,
		shield = 40,
		maxShield = 100,
	}
end

do
	local create, rounded, padding = UiKit.create, UiKit.rounded, UiKit.padding
	local C = Colors
	local Rarity = require(Shared:WaitForChild("Rarity"))

	-- HudClient's weaponFrame, slot cells and Inventory tab, with the same sizes, colours and scale.
	function Mock.hotbar(screen, spec, loadout)
		-- On a touch screen HudClient's phone block reshapes this: four cells across and two down in
		-- PhoneLayout's band, the ammo lines off (the held cell carries its own count), a 6-pixel plate
		-- and an icon-only Inventory tab. Same numbers here, so the shot is what the game draws.
		local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
		local phone = nil
		if spec.touch then
			local realForce = PhoneLayout.Force
			PhoneLayout.Force = "handheld"
			phone = PhoneLayout.Rects(spec.size)
			PhoneLayout.Force = realForce
		end
		-- A vertical screen keeps only the slots PhoneLayout says fit there -- sometimes none at all, and
		-- then there is no hotbar to draw: the Inventory button stands on its own and the panel holds
		-- the eight.
		if phone and phone.hotbarSlots == 0 then
			return nil
		end
		local columns = phone and phone.hotbarSlots and phone.hotbarSlots > 0 and math.min(phone.hotbarSlots, 4) or 4
		local rows = phone and phone.hotbarSlots and phone.hotbarSlots > 0 and phone.hotbarSlots <= 4 and 1 or 2
		local pad = phone and 6 or 12
		local weaponFrame = create("Frame", {
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -16),
			Size = UDim2.new(0, 690, 0, 150),
			BackgroundColor3 = C.Background,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			Parent = screen,
		}, { rounded(12), padding(pad) })
		local hotbarScale = Mock.hotbarScale(spec.size)
		if phone then
			local naturalW, naturalH = columns * 78 + (columns - 1) * 6 + 2 * pad, rows * 64 + (rows - 1) * 6 + 2 * pad
			hotbarScale = phone.hotbar.w / (naturalW - 2 * pad)
			weaponFrame.Size = UDim2.fromOffset(naturalW, naturalH)
			weaponFrame.Position = UDim2.fromOffset(phone.hotbar.x1 + pad * hotbarScale, phone.hotbar.y1 + pad * hotbarScale)
		end
		create("UIScale", { Scale = hotbarScale, Parent = weaponFrame })
		local held = loadout.slots[loadout.equipped]
		create("TextLabel", { Size = UDim2.new(1, 0, 0, 32), BackgroundTransparency = 1, Font = Enum.Font.FredokaOne, Visible = phone == nil,
			Text = held and held.kind == "weapon" and string.format("%d / %d", held.mag, held.reserve) or "--", TextColor3 = C.Text,
			TextXAlignment = Enum.TextXAlignment.Right, TextSize = 30, Parent = weaponFrame })
		create("TextLabel", { Position = UDim2.new(0, 0, 0, 32), Size = UDim2.new(1, 0, 0, 20), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
			Text = held and held.name or "Unarmed", TextColor3 = held and Rarity.Color(held.rarity) or C.Muted, TextXAlignment = Enum.TextXAlignment.Right,
			TextSize = 15, Visible = phone == nil, Parent = weaponFrame })
		local row = create("Frame", { Position = UDim2.new(0, 0, 0, phone and 0 or 58),
			Size = UDim2.new(1, 0, 0, phone and (rows * 64 + (rows - 1) * 6) or 64),
			BackgroundTransparency = 1, Parent = weaponFrame }, {
			phone and create("UIGridLayout", { CellSize = UDim2.fromOffset(78, 64), CellPadding = UDim2.fromOffset(6, 6),
				FillDirectionMaxCells = columns, HorizontalAlignment = Enum.HorizontalAlignment.Right, SortOrder = Enum.SortOrder.LayoutOrder })
				or create("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right,
					Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
		})
		for index = 1, (phone and phone.hotbarSlots and phone.hotbarSlots > 0 and phone.hotbarSlots or 8) do
			local slot = loadout.slots[index]
			local isHeld = slot and loadout.equipped == index
			local cell = create("Frame", { Size = UDim2.fromOffset(78, 64), BackgroundColor3 = isHeld and C.Panel or C.Background,
				BackgroundTransparency = isHeld and 0 or (slot and 0.35 or 0.6), BorderSizePixel = 0, LayoutOrder = index, Parent = row }, { rounded(8) })
			create("UIStroke", { Color = C.Accent, Thickness = 2, Enabled = isHeld and true or false, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = cell })
			create("TextLabel", { Position = UDim2.fromOffset(5, 2), Size = UDim2.fromOffset(30, 14), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
				Text = tostring(index), TextColor3 = C.Muted, TextXAlignment = Enum.TextXAlignment.Left, TextSize = 11, Parent = cell })
			if slot then
				create("TextLabel", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -5, 0, 2), Size = UDim2.fromOffset(44, 16), BackgroundTransparency = 1,
					Font = Enum.Font.FredokaOne, Text = slot.kind == "item" and ("x" .. slot.count) or tostring(slot.mag), TextColor3 = C.Text,
					TextXAlignment = Enum.TextXAlignment.Right, TextSize = 14, Parent = cell })
				create("TextLabel", { Position = UDim2.new(0, 4, 0, 16), Size = UDim2.new(1, -8, 0, 30), BackgroundTransparency = 1, Font = Enum.Font.GothamBold,
					Text = slot.name, TextColor3 = Rarity.Color(slot.rarity), TextWrapped = true, TextSize = 11, Parent = cell })
				create("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 3),
					BackgroundColor3 = Rarity.Color(slot.rarity), BorderSizePixel = 0, Parent = cell })
			end
		end
		-- The Inventory tab, exactly as HudClient's inventory section builds it: on a phone an icon on
		-- the grid's top-right corner, elsewhere the wide tab on the hotbar's top-left.
		local tab = create("TextButton", { Name = "InventoryTab",
			AnchorPoint = phone and Vector2.new(1, 1) or Vector2.new(0, 1),
			Position = phone and UDim2.new(1, 0, 0, -10 / math.max(hotbarScale, 0.01)) or UDim2.new(0, -12, 0, -12 - 4),
			Size = phone and UDim2.fromOffset(34, 25) or UDim2.fromOffset(176, 32),
			BackgroundColor3 = C.Background, BackgroundTransparency = 0.15, AutoButtonColor = false, Text = "",
			Parent = weaponFrame }, { rounded(10) })
		create("UIScale", { Scale = phone and math.max(1, 1.3 / hotbarScale) or math.max(1, (spec.touch and 1 or 0.8) / hotbarScale), Parent = tab })
		create("UIStroke", { Color = C.Panel, Thickness = 1.5, ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Parent = tab })
		for r = 0, 1 do
			for c = 0, 1 do
				create("Frame", { Position = UDim2.fromOffset(11 + c * 8, 8 + r * 8), Size = UDim2.fromOffset(6, 6), BackgroundColor3 = C.Accent,
					BorderSizePixel = 0, Parent = tab }, { rounded(2) })
			end
		end
		-- The wording goes on a phone (the icon is the whole tab there), and the key badge only exists
		-- where there's a keyboard to press it (HudClient's fitTabKey and its phone block).
		create("TextLabel", { Position = UDim2.fromOffset(34, 0), Size = UDim2.new(1, spec.touch and -44 or -76, 1, 0), BackgroundTransparency = 1,
			Visible = phone == nil, Font = Enum.Font.GothamBlack, Text = "INVENTORY", TextColor3 = C.Text, TextSize = 13,
			TextXAlignment = Enum.TextXAlignment.Left, Parent = tab })
		create("TextLabel", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(30, 20),
			Visible = not spec.touch and phone == nil,
			BackgroundColor3 = C.PanelAlt, Font = Enum.Font.GothamBold, Text = "B", TextColor3 = C.Muted, TextSize = 12, Parent = tab }, { rounded(6) })
		return weaponFrame
	end

	local HOTBAR_SCREENS = {
		SCREENS[1], SCREENS[2], { name = "1024x768", size = Vector2.new(1024, 768), touch = false }, SCREENS[3],
	}
	for _, spec in ipairs(HOTBAR_SCREENS) do
		add("hotbar", {
			name = "hotbar_" .. spec.name,
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				local screen = Mock.screen(gui, camera, spec, { inMatch = true, hotbar = false })
				Mock.hotbar(screen, spec, Loadouts.full)
			end,
		})
	end

	local InventoryPanel = require(Scripts:WaitForChild("InventoryPanel"))
	local STATES = {
		{ name = "open" },
		{ name = "selected", selected = 3 },
		{ name = "dragging", dragFrom = 6, dragOver = 2 },
	}
	for _, spec in ipairs(SCREENS) do
		for _, state in ipairs(STATES) do
			add("inventory", {
				name = "inventory_" .. spec.name .. "_" .. state.name,
				settle = 1.2,
				hold = 1.8,
				setup = function(_, camera)
					Mock.sky(camera)
					local gui = Mock.gui()
					local screen = Mock.screen(gui, camera, spec, { inMatch = true, hotbar = false })
					Mock.hotbar(screen, spec, Loadouts.full)
					local panel = InventoryPanel.new(screen, {
						keyLabel = function(index)
							return tostring(index)
						end,
						closeKeyLabel = function()
							return "B"
						end,
					})
					panel:SetViewport(spec.size)
					local pointer = nil
					if state.dragFrom then
						-- Frozen part way across, just short of the card it's over.
						panel:Snap(Loadouts.full, {})
						task.wait()
						local over = panel.cards[state.dragOver].card
						pointer = over.AbsolutePosition + over.AbsoluteSize * Vector2.new(0.62, 0.42)
					end
					panel:Snap(Loadouts.full, { selected = state.selected, dragFrom = state.dragFrom, dragOver = state.dragOver, pointer = pointer })
				end,
			})
		end
	end
end

--------------------------------------------------------------------------------
-- defense: the placement preview (StarterPlayerScripts/DefensePreview) on a test ground: flat grass, a
-- steep bank, a building, and a bunker already standing
--------------------------------------------------------------------------------

do
	local ORIGIN = Vector3.new(3000, 800, -3000)
	local scene = nil
	local rig = nil
	local preview = nil

	local function block(parent, size, cframe, color, material)
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = size
		part.CFrame = cframe
		part.Color = color
		part.Material = material or Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.Parent = parent
		return part
	end

	local function ensureScene()
		if scene and scene.Parent then
			return
		end
		scene = Instance.new("Folder")
		scene.Name = "HudUxDefenseScene"
		scene.Parent = workspace
		block(scene, Vector3.new(260, 2, 260), CFrame.new(ORIGIN - Vector3.new(0, 1, 0)), Color3.fromRGB(92, 150, 78), Enum.Material.Grass)
		-- A steep bank to the right, a building ahead-left.
		local bank = Instance.new("WedgePart")
		bank.Anchored = true
		bank.Size = Vector3.new(40, 16, 30)
		bank.CFrame = CFrame.new(ORIGIN + Vector3.new(38, 8, -40)) * CFrame.Angles(0, math.rad(-90), 0)
		bank.Color = Color3.fromRGB(110, 140, 80)
		bank.Material = Enum.Material.Grass
		bank.Parent = scene
		block(scene, Vector3.new(26, 18, 22), CFrame.new(ORIGIN + Vector3.new(-34, 9, -52)), Color3.fromRGB(196, 170, 140), Enum.Material.Brick)
		block(scene, Vector3.new(28, 1, 24), CFrame.new(ORIGIN + Vector3.new(-34, 18.5, -52)), Color3.fromRGB(90, 70, 60), Enum.Material.Slate)

		local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
		local DefenseService = require(modules:WaitForChild("DefenseService"))
		DefenseService.PublishTemplates()
		pcall(DefenseService.Build, "PopupBunker", CFrame.new(ORIGIN + Vector3.new(26, 0, -6)) * CFrame.Angles(0, math.rad(20), 0), nil)

		local ok, model = pcall(function()
			return game:GetService("Players"):CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			rig = model
			for _, part in ipairs(rig:GetDescendants()) do
				if part:IsA("BasePart") then
					part.Anchored = true
				end
			end
		else
			rig = Instance.new("Model")
			local root = block(rig, Vector3.new(2, 2, 1), CFrame.new(), Color3.fromRGB(80, 90, 200))
			root.Name = "HumanoidRootPart"
			local head = block(rig, Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 1.6, 0), Color3.fromRGB(240, 200, 160))
			head.Name = "Head"
			rig.PrimaryPart = root
		end
		rig.Name = "PreviewRig"
		rig.Parent = scene
		rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 3, 30)))
	end

	local SHOTS = {
		{ name = "barricade_valid", item = "RotBarricade", aim = Vector3.new(-6, 0, 6) },
		{ name = "bunker_valid", item = "PopupBunker", aim = Vector3.new(-8, 0, -4) },
		{ name = "fortress_valid", item = "BrainrotFortress", aim = Vector3.new(-6, 0, -14) },
		{ name = "fortress_too_steep", item = "BrainrotFortress", aim = Vector3.new(34, 7, -40) },
		-- The aim is inside the building's 15-stud bunker box, so the site slides clear of it: the ghost
		-- lands off the aim point on purpose, which is worth seeing.
		{ name = "bunker_slides_off_building", item = "PopupBunker", aim = Vector3.new(-30, 0, -38) },
		{ name = "barricade_no_room_bunker", item = "RotBarricade", aim = Vector3.new(24, 0, -6) },
		-- Past the 60-stud throw range: the throw clamps, so the ghost stops at the range, not at the aim.
		{ name = "barricade_clamped_to_range", item = "RotBarricade", aim = Vector3.new(-20, 0, -110) },
		-- Aimed over the bank: the lob clips the slope on the way, so the ghost stands on the bank and
		-- the label says how far short of the aim that is.
		{ name = "bunker_lands_short_on_the_bank", item = "PopupBunker", aim = Vector3.new(34, 0, -62) },
		{ name = "mine", item = "RotMine", aim = Vector3.new(4, 0, 4) },
	}
	for _, shot in ipairs(SHOTS) do
		add("defense", {
			name = "defense_" .. shot.name,
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.clear()
				ensureScene()
				if preview then
					preview:Destroy()
				end
				local DefensePreview = require(Scripts:WaitForChild("DefensePreview"))
				preview = DefensePreview.new()
				local aim = ORIGIN + shot.aim
				local standAt = ORIGIN + Vector3.new(0, 3, 30)
				rig:PivotTo(CFrame.lookAt(standAt, Vector3.new(aim.X, standAt.Y, aim.Z)))
				preview:Update(rig, shot.item, aim, {})
				local site = preview.site
				-- A mine has no structure box, so it has no origin either: that isn't a refusal.
				local outcome = "no ghost"
				if site and not site.size then
					outcome = "mine (arc and ring only)"
				elseif site and site.origin then
					outcome = string.format("valid, %.1f studs from the aim",
						(Vector3.new(site.origin.Position.X, 0, site.origin.Position.Z) - Vector3.new(aim.X, 0, aim.Z)).Magnitude)
				elseif site then
					outcome = "refused"
				end
				note(string.format("defense %s: %s%s%s", shot.name, outcome,
					site and site.short and site.short > 1 and string.format(", %.1f short of the aim", site.short) or "",
					site and site.reason and (" (" .. site.reason .. ")") or ""))
				-- Over the shoulder, a little high, looking at where it lands. Far enough back and high
				-- enough that the whole landing ring (16 studs of radius) is in shot.
				local look = (Vector3.new(aim.X, standAt.Y, aim.Z) - standAt).Unit
				local eye = standAt - look * 22 + Vector3.new(0, 16, 0) + look:Cross(Vector3.yAxis) * -6
				camera.FieldOfView = 70
				camera.CFrame = CFrame.lookAt(eye, aim + Vector3.new(0, 3, 0))
			end,
		})
	end
	add("defense", {
		name = "defense_overhead_fortress",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.clear()
			ensureScene()
			if preview then
				preview:Destroy()
			end
			local DefensePreview = require(Scripts:WaitForChild("DefensePreview"))
			preview = DefensePreview.new()
			local aim = ORIGIN + Vector3.new(-6, 0, -14)
			local standAt = ORIGIN + Vector3.new(0, 3, 30)
			rig:PivotTo(CFrame.lookAt(standAt, Vector3.new(aim.X, standAt.Y, aim.Z)))
			preview:Update(rig, "BrainrotFortress", aim, {})
			camera.FieldOfView = 60
			camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 95, 40), ORIGIN + Vector3.new(0, 0, -8))
		end,
	})
end

--------------------------------------------------------------------------------
-- landing: a MEASUREMENT in Run mode (run it on its own, ONLY = "landing"; it switches the gallery copy
-- into Run mode). Real kits thrown by DefenseService's own throw on a real map, with physics: how far
-- a kit really comes to rest from the aim point, and whether what went up is what the preview showed.
--------------------------------------------------------------------------------

add("landing", {
	name = "landing_measure",
	settle = 1.2,
	hold = 1.8,
	setup = function(_, camera)
		-- The earlier sections' lobby and test ground are no use here; free the memory before a whole map.
		Mock.clear()
		for _, name in ipairs({ "HudUxLobby", "HudUxDefenseScene", "StageDisplay" }) do
			local leftover = workspace:FindFirstChild(name)
			if leftover then
				leftover:Destroy()
			end
		end
		local RunService = game:GetService("RunService")
		if not RunService:IsRunning() then
			RunService:Run()
		end
		task.wait(4)
		local MapGenerator = require(Modules:WaitForChild("MapGenerator"))
		local DefenseService = require(Modules:WaitForChild("DefenseService"))
		local WeaponService = require(Modules:WaitForChild("WeaponService"))
		local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
		local DefensePreview = require(Scripts:WaitForChild("DefensePreview"))
		math.randomseed(20260917)
		local okMap, info = pcall(MapGenerator.Build, "SahurSprings")
		note("landing: map " .. (okMap and "built" or tostring(info)))
		if not okMap then
			return
		end
		task.wait(3)
		DefenseService.PublishTemplates()

		local spots = {}
		for _, spot in ipairs(info.lootSpots.weapon or {}) do
			table.insert(spots, spot)
		end
		local random = Random.new(4711)
		local ids = { "RotBarricade", "PopupBunker", "BrainrotFortress", "RotMine" }
		local results = {}
		local LANES, PER_LANE = 6, 12

		-- Lanes at spots far apart, so one lane's builds never land in another's.
		local laneSpots = {}
		for _ = 1, 400 do
			if #laneSpots >= LANES then
				break
			end
			local candidate = spots[random:NextInteger(1, #spots)]
			local clear = true
			for _, other in ipairs(laneSpots) do
				if (other - candidate).Magnitude < 160 then
					clear = false
				end
			end
			if clear then
				table.insert(laneSpots, candidate)
			end
		end
		note(string.format("landing: %d lanes", #laneSpots))

		local function makeRig(position)
			local rig = Instance.new("Model")
			rig.Name = "LandingRig"
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Size = Vector3.new(2, 2, 1)
			root.Anchored = true
			root.CanCollide = false
			root.Parent = rig
			local head = Instance.new("Part")
			head.Name = "Head"
			head.Size = Vector3.new(1.2, 1.2, 1.2)
			head.Anchored = true
			head.CanCollide = false
			head.Parent = rig
			rig.PrimaryPart = root
			rig.Parent = workspace
			return rig, root, head
		end

		local finished = 0
		for lane, laneSpot in ipairs(laneSpots) do
			task.spawn(function()
				local rig, root, head = makeRig(laneSpot)
				for throw = 1, PER_LANE do
					local id = ids[((lane + throw) % #ids) + 1]
					local yaw = random:NextNumber(0, math.pi * 2)
					root.CFrame = CFrame.new(laneSpot + Vector3.new(0, 3, 0)) * CFrame.Angles(0, yaw, 0)
					head.CFrame = root.CFrame * CFrame.new(0, 1.6, 0)
					local ahead = laneSpot + CFrame.Angles(0, yaw + random:NextNumber(-0.5, 0.5), 0).LookVector * random:NextNumber(8, 55)
					local params = RaycastParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { rig, workspace:FindFirstChild("Defenses") }
					local hit = workspace:Raycast(ahead + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
					local aim = hit and hit.Position or ahead
					local predicted = DefensePreview.Site(rig, id, aim, {})
					local fake = { Name = "LandingProbe", UserId = -7000 - lane * 100 - throw, Character = rig, Parent = workspace }
					local defenses = workspace:FindFirstChild("Defenses")
					local known = {}
					for _, child in ipairs(defenses and defenses:GetChildren() or {}) do
						known[child] = true
					end
					local okThrow = pcall(WeaponService.DefenseEffect, fake, id, aim)
					-- Follow the kit until it's gone, keeping its last position: where it came to rest.
					local kit, landed = nil, nil
					defenses = workspace:FindFirstChild("Defenses")
					for _, child in ipairs(defenses and defenses:GetChildren() or {}) do
						if not known[child] and child.Name == id .. "Kit" then
							kit = child
						end
					end
					local started = os.clock()
					while kit and kit.Parent and os.clock() - started < 8 do
						local body = kit.PrimaryPart or kit:FindFirstChildWhichIsA("BasePart", true)
						if body then
							landed = body.Position
						end
						task.wait(0.03)
					end
					task.wait(0.3)
					local built = nil
					defenses = workspace:FindFirstChild("Defenses")
					for _, child in ipairs(defenses and defenses:GetChildren() or {}) do
						if child:GetAttribute("OwnerUserId") == fake.UserId and child.PrimaryPart then
							built = child.PrimaryPart.CFrame * CFrame.new(0, -((DefensePlacement.Sizes[id] and DefensePlacement.Sizes[id].Y or 0) + 0.5), 0)
							child:Destroy()
						end
					end
					table.insert(results, {
						id = id,
						ok = okThrow,
						predicted = predicted,
						landed = landed,
						built = built,
						-- Kept so the drift can be split into "past or short of the aim" and "off to the side".
						from = laneSpot,
						aim = aim,
					})
					task.wait(0.2)
				end
				rig:Destroy()
				finished += 1
			end)
		end
		local waited = 0
		while finished < #laneSpots and waited < 600 do
			task.wait(1)
			waited += 1
		end

		-- The numbers.
		local spreads, agreeValid, structures, originGaps, flips = {}, 0, 0, {}, {}
		-- Split the same drift into "past (+) or short (-) of the aim" and "off to either side", and keep
		-- one list per kit: a ring is only the honest shape if the drift has no strong direction to it.
		local along, across, perItem = {}, {}, {}
		for _, r in ipairs(results) do
			local target = r.predicted and r.predicted.target
			if r.landed and target then
				local drift = Vector3.new(r.landed.X - target.X, 0, r.landed.Z - target.Z)
				table.insert(spreads, drift.Magnitude)
				perItem[r.id] = perItem[r.id] or {}
				table.insert(perItem[r.id], drift.Magnitude)
				local throwLine = Vector3.new(target.X - r.from.X, 0, target.Z - r.from.Z)
				if throwLine.Magnitude > 0.01 then
					local unit = throwLine.Unit
					table.insert(along, drift:Dot(unit))
					table.insert(across, math.abs(drift:Dot(Vector3.new(-unit.Z, 0, unit.X))))
				end
			end
			if DefensePlacement.Sizes[r.id] and r.predicted then
				structures += 1
				local predictedValid = r.predicted.origin ~= nil
				local builtValid = r.built ~= nil
				if predictedValid == builtValid then
					agreeValid += 1
				else
					table.insert(flips, string.format("%s preview %s, built %s", r.id, predictedValid and "yes" or ("no: " .. tostring(r.predicted.reason)),
						builtValid and "yes" or "no"))
				end
				if predictedValid and builtValid then
					local a, b = r.predicted.origin.Position, r.built.Position
					table.insert(originGaps, (Vector3.new(a.X, 0, a.Z) - Vector3.new(b.X, 0, b.Z)).Magnitude)
				end
			end
		end
		local function stats(list)
			table.sort(list)
			local n = #list
			if n == 0 then
				return "none"
			end
			local sum = 0
			for _, value in ipairs(list) do
				sum += value
			end
			local function at(p)
				return list[math.clamp(math.ceil(n * p), 1, n)]
			end
			return string.format("n %d, mean %.2f, p50 %.2f, p75 %.2f, p90 %.2f, max %.2f", n, sum / n, at(0.5), at(0.75), at(0.9), list[n])
		end
		note("landing: kits thrown " .. #results)
		note("landing: rest distance from the aim point (studs): " .. stats(spreads))
		note("landing: along the throw, + past the aim (studs): " .. stats(along))
		note("landing: off to the side, either way (studs): " .. stats(across))
		for _, id in ipairs(ids) do
			if perItem[id] then
				note(string.format("landing: %s rest distance (studs): %s", id, stats(perItem[id])))
			end
		end
		note(string.format("landing: preview valid/invalid matched what happened on %d of %d structure throws", agreeValid, structures))
		note("landing: preview origin vs real build, both built (studs): " .. stats(originGaps))
		for index = 1, math.min(8, #flips) do
			note("landing: differs: " .. flips[index])
		end
		camera.CFrame = CFrame.lookAt(laneSpots[1] + Vector3.new(0, 90, 60), laneSpots[1])
	end,
})

--------------------------------------------------------------------------------
-- phone: the in-match HUD on a touch screen, before and after
--------------------------------------------------------------------------------

-- Two pictures of the same screen: what a phone player sees today (measured from the code, with every
-- overlapping pair marked in red), and what PhoneLayout puts there instead, drawn from the live module.
-- The event pill on the "after" shots is the real one, so those shots also prove the banner and the
-- layout agree about where its slot is.

-- The layout that ships today, measured from the code by scratchpad/phone_layout.py.
local CURRENT = {
	["844x390"] = { w = 844, h = 390, rects = {
		{ "TOP BANNER", "hud", 202.0, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 654.0, 10.0, 182.0, 43.2 },
		{ "STORM TEXT", "hud", 202.0, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", 202.0, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 638.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 598.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 528.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 294.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 224.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 188.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 218.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 133.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", 416.0, 284.4, 412.0, 89.6 },
		{ "INVENTORY TAB", "hud", 416.0, 250.0, 176.0, 32.0 },
		{ "TOAST", "transient", 192.0, 234.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 297.0, 234.0, 250.0, 46.0 },
		{ "btn FIRE", "touch", 704.0, 210.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 594.0, 210.0, 45.0, 45.0 },
		{ "btn PET", "touch", 484.0, 210.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", 374.0, 210.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 704.0, 110.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 594.0, 110.0, 45.0, 45.0 },
		{ "btn CAM", "touch", 484.0, 110.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", 374.0, 110.0, 45.0, 45.0 },
		{ "JUMP", "touch", 749.0, 300.0, 70.0, 70.0 },
		{ "THUMBSTICK rest", "touch", 29.0, 297.0, 74.0, 74.0 },
		{ "MOVE ZONE", "zone", 0.0, 130.0, 337.6, 260.0 },
	} },
	["667x375"] = { w = 667, h = 375, rects = {
		{ "TOP BANNER", "hud", 113.5, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 517.4, 10.0, 141.6, 33.6 },
		{ "STORM TEXT", "hud", 113.5, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", 113.5, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 461.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 421.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 351.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 279.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 209.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 173.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 203.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 118.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", 306.0, 284.0, 345.0, 75.0 },
		{ "INVENTORY TAB", "hud", 306.0, 250.0, 176.0, 32.0 },
		{ "TOAST", "transient", 103.5, 219.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 208.5, 225.0, 250.0, 46.0 },
		{ "btn FIRE", "touch", 527.0, 195.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 417.0, 195.0, 45.0, 45.0 },
		{ "btn PET", "touch", 307.0, 195.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", 197.0, 195.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 527.0, 95.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 417.0, 95.0, 45.0, 45.0 },
		{ "btn CAM", "touch", 307.0, 95.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", 197.0, 95.0, 45.0, 45.0 },
		{ "JUMP", "touch", 572.0, 285.0, 70.0, 70.0 },
		{ "THUMBSTICK rest", "touch", 29.0, 282.0, 74.0, 74.0 },
		{ "MOVE ZONE", "zone", 0.0, 125.0, 266.8, 250.0 },
	} },
	["740x360"] = { w = 740, h = 360, rects = {
		{ "TOP BANNER", "hud", 150.0, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 590.4, 10.0, 141.6, 33.6 },
		{ "STORM TEXT", "hud", 150.0, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", 150.0, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 534.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 494.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 424.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 264.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 194.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 158.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 188.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 103.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", 379.0, 269.0, 345.0, 75.0 },
		{ "INVENTORY TAB", "hud", 379.0, 235.0, 176.0, 32.0 },
		{ "TOAST", "transient", 140.0, 204.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 245.0, 216.0, 250.0, 46.0 },
		{ "btn FIRE", "touch", 600.0, 180.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 490.0, 180.0, 45.0, 45.0 },
		{ "btn PET", "touch", 380.0, 180.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", 270.0, 180.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 600.0, 80.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 490.0, 80.0, 45.0, 45.0 },
		{ "btn CAM", "touch", 380.0, 80.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", 270.0, 80.0, 45.0, 45.0 },
		{ "JUMP", "touch", 645.0, 270.0, 70.0, 70.0 },
		{ "THUMBSTICK rest", "touch", 29.0, 267.0, 74.0, 74.0 },
		{ "MOVE ZONE", "zone", 0.0, 120.0, 296.0, 240.0 },
	} },
	["1024x768"] = { w = 1024, h = 768, rects = {
		{ "TOP BANNER", "hud", 292.0, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 744.0, 10.0, 236.0, 56.0 },
		{ "STORM TEXT", "hud", 292.0, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", 292.0, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 818.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 778.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 708.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 672.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 602.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 566.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 596.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 511.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", 416.0, 623.3, 592.0, 128.7 },
		{ "INVENTORY TAB", "hud", 416.0, 587.9, 176.0, 32.0 },
		{ "TOAST", "transient", 282.0, 612.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 387.0, 460.8, 250.0, 46.0 },
		{ "btn FIRE", "touch", 884.0, 588.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 774.0, 588.0, 45.0, 45.0 },
		{ "btn PET", "touch", 664.0, 588.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", 554.0, 588.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 884.0, 488.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 774.0, 488.0, 45.0, 45.0 },
		{ "btn CAM", "touch", 664.0, 488.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", 554.0, 488.0, 45.0, 45.0 },
		{ "JUMP", "touch", 854.0, 558.0, 120.0, 120.0 },
		{ "THUMBSTICK rest", "touch", 58.0, 582.0, 148.0, 148.0 },
		{ "MOVE ZONE", "zone", 0.0, 256.0, 409.6, 512.0 },
	} },
	["320x568"] = { w = 320, h = 568, rects = {
		{ "TOP BANNER", "hud", -60.0, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 170.4, 10.0, 141.6, 33.6 },
		{ "STORM TEXT", "hud", -60.0, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", -60.0, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 114.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 74.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 4.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 472.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 402.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 366.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 396.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 311.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", -41.0, 477.0, 345.0, 75.0 },
		{ "INVENTORY TAB", "hud", -41.0, 443.0, 176.0, 32.0 },
		{ "TOAST", "transient", -70.0, 412.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 35.0, 340.8, 250.0, 46.0 },
		{ "btn FIRE", "touch", 180.0, 388.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 70.0, 388.0, 45.0, 45.0 },
		{ "btn PET", "touch", -40.0, 388.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", -150.0, 388.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 180.0, 288.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 70.0, 288.0, 45.0, 45.0 },
		{ "btn CAM", "touch", -40.0, 288.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", -150.0, 288.0, 45.0, 45.0 },
		{ "JUMP", "touch", 225.0, 478.0, 70.0, 70.0 },
		{ "THUMBSTICK rest", "touch", 29.0, 475.0, 74.0, 74.0 },
		{ "MOVE ZONE", "zone", 0.0, 189.3, 128.0, 378.7 },
	} },
	["375x667"] = { w = 375, h = 667, rects = {
		{ "TOP BANNER", "hud", -32.5, 10.0, 440.0, 56.0 },
		{ "EVENT PILL", "hud", 225.4, 10.0, 141.6, 33.6 },
		{ "STORM TEXT", "hud", -32.5, 72.0, 440.0, 24.0 },
		{ "COMPASS", "hud", -32.5, 100.0, 440.0, 24.0 },
		{ "MINIMAP", "hud", 169.0, 108.0, 190.0, 190.0 },
		{ "BOUNTY/LOCATION", "hud", 129.0, 304.0, 230.0, 50.0 },
		{ "KILL FEED", "hud", 59.0, 312.0, 300.0, 120.0 },
		{ "COINS", "menu", 16.0, 136.0, 210.0, 44.0 },
		{ "MENU [M]", "menu", 16.0, 188.0, 210.0, 42.0 },
		{ "STACK TAB", "menu", 232.0, 188.0, 30.0, 42.0 },
		{ "BUNDLE", "menu", 16.0, 238.0, 210.0, 34.0 },
		{ "QUEST TRACKER", "menu", 16.0, 282.0, 250.0, 132.0 },
		{ "HEALTH", "hud", 16.0, 571.0, 280.0, 80.0 },
		{ "COMPANION", "hud", 16.0, 501.0, 300.0, 62.0 },
		{ "SPEED PILL", "hud", 16.0, 465.0, 150.0, 28.0 },
		{ "PET ICON", "hud", 326.0, 495.0, 78.0, 78.0 },
		{ "STAMINA", "hud", 16.0, 410.0, 331.2, 45.0 },
		{ "HOTBAR", "hud", 14.0, 576.0, 345.0, 75.0 },
		{ "INVENTORY TAB", "hud", 14.0, 542.0, 176.0, 32.0 },
		{ "TOAST", "transient", -42.5, 511.0, 460.0, 36.0 },
		{ "USE BAR", "transient", 62.5, 400.2, 250.0, 46.0 },
		{ "btn FIRE", "touch", 235.0, 487.0, 45.0, 45.0 },
		{ "btn AIM", "touch", 125.0, 487.0, 45.0, 45.0 },
		{ "btn PET", "touch", 15.0, 487.0, 45.0, 45.0 },
		{ "btn SLIDE", "touch", -95.0, 487.0, 45.0, 45.0 },
		{ "btn RELOAD", "touch", 235.0, 387.0, 45.0, 45.0 },
		{ "btn RUN", "touch", 125.0, 387.0, 45.0, 45.0 },
		{ "btn CAM", "touch", 15.0, 387.0, 45.0, 45.0 },
		{ "btn MOVE", "touch", -95.0, 387.0, 45.0, 45.0 },
		{ "JUMP", "touch", 280.0, 577.0, 70.0, 70.0 },
		{ "THUMBSTICK rest", "touch", 29.0, 574.0, 74.0, 74.0 },
		{ "MOVE ZONE", "zone", 0.0, 222.3, 150.0, 444.7 },
	} },
}

do
	local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
	local EventBanner = require(Scripts:WaitForChild("EventBanner"))
	local create = UiKit.create
	local C = Colors
	local KIND_COLOR = {
		hud = Color3.fromRGB(96, 170, 240),
		menu = Color3.fromRGB(240, 186, 74),
		touch = Color3.fromRGB(150, 150, 160),
		reserved = Color3.fromRGB(120, 120, 130),
		tap = Color3.fromRGB(120, 226, 150),
	}
	-- Which of PhoneLayout's rects to draw, what to call them, and what they count as.
	local AFTER = {
		{ "banner", "TOP BANNER", "hud" }, { "stormLine", "STORM", "hud" }, { "compass", "COMPASS", "hud" },
		{ "menu", "MENU", "menu" }, { "stackTab", "2/3", "menu" }, { "cam", "CAM", "menu" },
		{ "eventPill", "EVENT", "tap" }, { "killFeed", "KILL FEED", "hud" }, { "minimap", "MINIMAP", "hud" },
		{ "bounty", "BOUNTY", "hud" }, { "location", "LOCATION", "hud" }, { "petIcon", "PET", "hud" },
		{ "hotbar", "HOTBAR 2x4", "tap" }, { "inventory", "INV", "tap" }, { "health", "HEALTH + SHIELD", "hud" },
		{ "stamina", "STAMINA", "hud" }, { "speedPill", "SPEED", "hud" },
		{ "coins", "COINS", "hud" }, { "companion", "COMPANION", "hud" },
		{ "jump", "JUMP", "touch" }, { "stick", "STICK", "touch" }, { "topBar", "ROBLOX", "reserved" },
		{ "fire", "FIRE", "touch" }, { "aim", "AIM", "touch" }, { "reload", "RELOAD", "touch" },
		{ "run", "RUN", "touch" }, { "pet", "PET*", "touch" }, { "slide", "SLIDE", "touch" }, { "move", "MOVE", "touch" },
	}
	local LOBBY_OUT = { minimap = true, hotbar = true, inventory = true, health = true, stamina = true, speedPill = true,
		killFeed = true, bounty = true, location = true, petIcon = true, fire = true, aim = true, reload = true, run = true,
		pet = true, slide = true, move = true, stormLine = true, compass = true, cam = true }
	local SPECTATE_OUT = { hotbar = true, inventory = true, health = true, stamina = true, speedPill = true, petIcon = true,
		fire = true, aim = true, reload = true, run = true, pet = true, slide = true, move = true, jump = true, stick = true }

	local function screenFor(gui, camera, w, h, caption)
		local viewport = camera.ViewportSize
		local fit = math.min(viewport.X * 0.94 / w, viewport.Y * 0.86 / h)
		local screen = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.54),
			Size = UDim2.fromOffset(w, h),
			BackgroundColor3 = Color3.fromRGB(26, 30, 40),
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Parent = gui,
		})
		create("UIScale", { Scale = fit, Parent = screen })
		create("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, Color3.fromRGB(58, 74, 96)),
				ColorSequenceKeypoint.new(0.55, Color3.fromRGB(70, 84, 88)),
				ColorSequenceKeypoint.new(0.56, Color3.fromRGB(46, 62, 44)),
				ColorSequenceKeypoint.new(1, Color3.fromRGB(34, 48, 34)),
			}),
			Parent = screen,
		})
		-- The crosshair, and so the middle of the screen, which is what all of this is about.
		create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(24, 24),
			BackgroundTransparency = 1,
			ZIndex = 20,
			Parent = screen,
		}, { create("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 2, Transparency = 0.2 }) })
		create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(w, 20),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBlack,
			Text = caption,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.4,
			TextSize = 15,
			ZIndex = 20,
			Parent = screen,
		})
		return screen
	end

	-- Draws one set of boxes and counts the pairs that overlap; those are drawn red.
	local function drawBoxes(screen, boxes)
		local clash = {}
		local count = 0
		for index, a in ipairs(boxes) do
			for other = index + 1, #boxes do
				local b = boxes[other]
				local x = math.min(a.x + a.w, b.x + b.w) - math.max(a.x, b.x)
				local y = math.min(a.y + a.h, b.y + b.h) - math.max(a.y, b.y)
				if x > 0.5 and y > 0.5 then
					count += 1
					clash[a], clash[b] = true, true
				end
			end
		end
		for _, box in ipairs(boxes) do
			local color = KIND_COLOR[box.kind] or C.Muted
			local bad = clash[box] == true
			local frame = create("Frame", {
				Position = UDim2.fromOffset(box.x, box.y),
				Size = UDim2.fromOffset(box.w, box.h),
				BackgroundColor3 = bad and Color3.fromRGB(226, 78, 78) or color,
				BackgroundTransparency = bad and 0.5 or 0.72,
				BorderSizePixel = 0,
				Parent = screen,
			}, { create("UIStroke", { Color = bad and Color3.fromRGB(255, 140, 140) or color, Thickness = bad and 2 or 1 }) })
			create("TextLabel", {
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = box.label,
				TextColor3 = Color3.new(1, 1, 1),
				TextStrokeTransparency = 0.45,
				TextSize = math.clamp(math.min(box.w / 5.5, box.h * 0.55), 8, 13),
				TextWrapped = true,
				Parent = frame,
			})
		end
		return count
	end

	-- The thumbstick's zone and the two transient strips are not counted as clashes (the sweep in
	-- scratchpad/phone_layout.py leaves them out too), so the number on the shot is the same 27/44/35.
	local NOT_SOLID = { zone = true, transient = true }
	local function currentBoxes(key)
		local boxes = {}
		for _, entry in ipairs(CURRENT[key].rects) do
			if not NOT_SOLID[entry[2]] then
				table.insert(boxes, { label = entry[1], kind = entry[2], x = entry[3], y = entry[4], w = entry[5], h = entry[6] })
			end
		end
		return boxes
	end

	local function afterBoxes(w, h, drop)
		local spots = PhoneLayout.Rects(Vector2.new(w, h))
		local boxes = {}
		for _, entry in ipairs(AFTER) do
			local spot = spots[entry[1]]
			if spot and not (drop and drop[entry[1]]) then
				table.insert(boxes, { label = entry[2], kind = entry[3], x = spot.x, y = spot.y, w = spot.w, h = spot.h })
			end
		end
		return boxes, spots
	end

	-- The three versions, side by side: two small landscape screens, a tablet, and the two vertical
	-- sizes the vertical version was designed for.
	local SIZES = { { "844x390", 844, 390 }, { "667x375", 667, 375 }, { "740x360", 740, 360 }, { "1024x768", 1024, 768 },
		{ "320x568", 320, 568 }, { "375x667", 375, 667 } }
	for _, size in ipairs(SIZES) do
		local key, w, h = size[1], size[2], size[3]
		add("phone", {
			name = "phone_before_" .. key,
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				local screen = screenFor(gui, camera, w, h, "BEFORE  " .. key .. "  (the desktop HUD on a phone, measured)")
				note(string.format("phone %s before: %d overlapping pairs", key, drawBoxes(screen, currentBoxes(key))))
			end,
		})
		add("phone", {
			name = "phone_after_" .. key,
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				-- The grey buttons are TouchControls' slots. That flag is off today, so what a player
				-- actually has now is Roblox's own set in a box down the right-hand side -- which is why
				-- the band below keeps clear of the right 30% either way.
				local screen = screenFor(gui, camera, w, h, "AFTER  " .. key .. "  (PhoneLayout; grey = touch buttons' slots)")
				local boxes, spots = afterBoxes(w, h)
				local count = drawBoxes(screen, boxes)
				-- The hotbar is drawn for real over its box: the same four-across-two-down grid with the
				-- real gun icons that HudClient builds on a phone, so the slots can be judged by eye.
				Mock.hotbar(screen, { name = key, size = Vector2.new(w, h), touch = true }, Loadouts.full)
				-- The real pill, placed by the module itself.
				local realForce = PhoneLayout.Force
				PhoneLayout.Force = "handheld"
				local banner = EventBanner.new(screen)
				banner:SetViewport(Vector2.new(w, h))
				banner:SetTimer("live", 96)
				banner:Snap({ id = "LootFrenzy", name = "Loot Frenzy", description = "Three guns in every chest.",
					color = Color3.fromRGB(240, 186, 74) }, "pill")
				PhoneLayout.Force = realForce
				note(string.format("phone %s after: %d overlapping pairs, hotbar cells %.0f px", key, count, spots.hotbarCell))
			end,
		})
	end

	-- The lobby and a spectator's screen, both after.
	add("phone", {
		name = "phone_after_lobby_844x390",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = screenFor(gui, camera, 844, 390, "AFTER  lobby  (no match HUD: coins and the stack are out)")
			local boxes, spots = afterBoxes(844, 390, LOBBY_OUT)
			-- The lobby's own pieces, at the slots the modules really use: READY takes the corner the
			-- event pill has in a match (PhoneLayout.ready), the event pill drops under it, and the menu
			-- stack hangs from its tab at 0.8 with MENU out of it (MenuStackToggle.SetPhone).
			table.insert(boxes, { label = "COINS", kind = "menu", x = 16, y = 58, w = 151, h = 32 })
			table.insert(boxes, { label = "READY UP", kind = "tap", x = spots.ready.x, y = spots.ready.y, w = spots.ready.w, h = spots.ready.h })
			table.insert(boxes, { label = "EVENT", kind = "tap", x = spots.eventPillBelow.x, y = spots.eventPillBelow.y,
				w = spots.eventPillBelow.w, h = spots.eventPillBelow.h })
			local stackTop = spots.eventPillBelow.y1 + 6
			table.insert(boxes, { label = "MENU STACK (out): bundle, quest tracker", kind = "menu",
				x = spots.stackTab.x1 - 240, y = stackTop, w = 240, h = math.min(150, spots.jump.y - 6 - stackTop) })
			note(string.format("phone lobby: %d overlapping pairs", drawBoxes(screen, boxes)))
		end,
	})
	-- The centred panels, before and after PhoneLayout.FitPanel: the menu and the drop screen are
	-- authored taller than a phone screen, so their bottoms -- every tab's buttons, the landing map --
	-- used to be off the edge. Drawn at 844x390 with the screen clipping, which is what a player sees.
	-- One panel, drawn big: three side by side on an 844-wide screen only overlap each other. The menu
	-- is the one that matters most (it is every tab in the game) and the worst offender; the other two
	-- are in the note this view prints.
	local PANELS = {
		{ "MENU (760x480): every tab in the game", 760, 480, true },
	}
	for _, fitted in ipairs({ false, true }) do
		add("phone", {
			name = "phone_panels_" .. (fitted and "after" or "before") .. "_844x390",
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				local screen = screenFor(gui, camera, 844, 390, (fitted and "AFTER" or "BEFORE")
					.. "  844x390  (centred panels" .. (fitted and ", PhoneLayout.FitPanel)" or ", as authored: the part outside the frame is off the screen)"))
				-- Not clipped, and the screen gets a bright edge: a panel taller than the screen then
				-- reads as "this much hangs off", instead of vanishing at the crop like a broken shot.
				screen.ClipsDescendants = false
				create("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromScale(1, 1),
					BackgroundTransparency = 1,
					ZIndex = 30,
					Parent = screen,
				}, { create("UIStroke", { Color = Color3.fromRGB(255, 255, 255), Thickness = 3, Transparency = 0.15 }) })
				local spread = { 0 }
				for index, panel in ipairs(PANELS) do
					local natural = Vector2.new(panel[2], panel[3])
					local scale = fitted and PhoneLayout.PanelScale(natural, Vector2.new(844, 390), { inset = panel[4], insetY = 58 }) or 1
					local w, h = natural.X * scale, natural.Y * scale
					local box = create("Frame", {
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.new(0.5, spread[index], 0.5, panel[4] and 29 or 0),
						Size = UDim2.fromOffset(w, h),
						BackgroundColor3 = C.Background,
						BackgroundTransparency = 0.1,
						BorderSizePixel = 0,
						Parent = screen,
					}, { UiKit.rounded(12), create("UIStroke", { Color = fitted and Color3.fromRGB(120, 226, 150) or Color3.fromRGB(226, 78, 78), Thickness = 2 }) })
					create("TextLabel", {
						Position = UDim2.fromOffset(8, 6),
						Size = UDim2.new(1, -16, 0, 16),
						BackgroundTransparency = 1,
						Font = Enum.Font.GothamBold,
						Text = panel[1],
						TextColor3 = C.Text,
						TextSize = 12,
						TextXAlignment = Enum.TextXAlignment.Left,
						Parent = box,
					})
					-- The bottom row of the panel: the part that falls off the screen when it isn't fitted.
					create("Frame", {
						AnchorPoint = Vector2.new(0.5, 1),
						Position = UDim2.new(0.5, 0, 1, -10 * scale),
						Size = UDim2.fromOffset(w - 40 * scale, 30 * scale),
						BackgroundColor3 = C.Accent,
						BorderSizePixel = 0,
						Parent = box,
					}, { UiKit.rounded(8) })
				end
				note(string.format("phone panels %s: menu %.2f, drop %.2f, results %.2f", fitted and "after" or "before",
					fitted and PhoneLayout.PanelScale(Vector2.new(760, 480), Vector2.new(844, 390), { inset = true, insetY = 58 }) or 1,
					fitted and PhoneLayout.PanelScale(Vector2.new(480, 536), Vector2.new(844, 390)) or 1,
					fitted and PhoneLayout.PanelScale(Vector2.new(460, 410), Vector2.new(844, 390)) or 1))
			end,
		})
	end

	add("phone", {
		name = "phone_after_spectating_844x390",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			local screen = screenFor(gui, camera, 844, 390, "AFTER  spectating  (no controls, no hotbar)")
			local boxes = afterBoxes(844, 390, SPECTATE_OUT)
			-- CombatClient's spectate label, at the size and place it really has (460x44, bottom centre).
			table.insert(boxes, { label = "SPECTATING   <  NAME  >", kind = "hud", x = 844 / 2 - 230, y = 390 - 24 - 44, w = 460, h = 44 })
			note(string.format("phone spectating: %d overlapping pairs", drawBoxes(screen, boxes)))
		end,
	})
end

--------------------------------------------------------------------------------
-- grip: a MEASUREMENT, not pictures. Why does a thrown defense kit end up so far from the aim point,
-- and what would fix it? Run it on its own (ONLY = "grip"); like `landing` it switches to Run mode.
--------------------------------------------------------------------------------

-- The first run of this section answered the first question, and ruled out the obvious fix. Five sets of
-- kit physics -- bouncy as it is now, no bounce, no bounce and no tumble, gripping, heavy -- all left the
-- kit a median 19 to 23 studs from the aim point, and the FIRST ground contact was already 10 to 15
-- studs out. So the kit is not rolling away from the aim: the lob is not arriving there. On the hills of
-- SahurSprings a flat throw clips the rising ground well short of where it was aimed.
--
-- So this measures the throw itself. Every option is the same lob solved for a different flight time
-- (the arc's height), thrown here rather than through DefenseService, so nothing in the game changes to
-- measure it -- the first option reproduces DefenseService.throwKit exactly, and its numbers can be
-- checked against the real throw's (p50 21 at rest, 10.5 at first contact).
--
-- Each throw records where it was aimed, where the kit FIRST touched the ground, and where it stopped,
-- and how far short or past the aim that first contact was along the throw's own line.

add("grip", {
	name = "grip_measure",
	settle = 1.2,
	hold = 1.8,
	setup = function(_, camera)
		Mock.clear()
		for _, name in ipairs({ "HudUxLobby", "HudUxDefenseScene", "StageDisplay" }) do
			local leftover = workspace:FindFirstChild(name)
			if leftover then
				leftover:Destroy()
			end
		end
		local RunService = game:GetService("RunService")
		if not RunService:IsRunning() then
			RunService:Run()
		end
		task.wait(4)
		local MapGenerator = require(Modules:WaitForChild("MapGenerator"))
		local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
		local ItemModels = require(Shared:WaitForChild("ItemModels"))
		math.randomseed(20260917)
		local okMap, info = pcall(MapGenerator.Build, "SahurSprings")
		note("grip: map " .. (okMap and "built" or tostring(info)))
		if not okMap then
			return
		end
		task.wait(3)

		-- The options. `speed` is the studs-per-second the flight time is worked out from: the smaller it
		-- is, the longer the kit is in the air and the steeper it comes down. `props` is what would go on
		-- the kit's part; `spin` false takes the random tumble off.
		local OPTIONS = {
			{ name = "as it is now", speed = 40, min = 0.5, max = 1.6, spin = true },
			{ name = "no bounce (every part)", speed = 40, min = 0.5, max = 1.6, spin = true,
				props = PhysicalProperties.new(0.7, 0.6, 0, 1, 1) },
			{ name = "no bounce, no spin", speed = 40, min = 0.5, max = 1.6, spin = false,
				props = PhysicalProperties.new(0.7, 0.6, 0, 1, 1) },
			{ name = "no bounce, gripping, no spin", speed = 40, min = 0.5, max = 1.6, spin = false,
				props = PhysicalProperties.new(0.7, 2, 0, 10, 10) },
			{ name = "steeper", speed = 25, min = 0.7, max = 2.2, spin = true },
			{ name = "steeper, no bounce, gripping, no spin", speed = 25, min = 0.7, max = 2.2, spin = false,
				props = PhysicalProperties.new(0.7, 2, 0, 10, 10) },
		}

		local spots = {}
		for _, spot in ipairs(info.lootSpots.weapon or {}) do
			table.insert(spots, spot)
		end
		local random = Random.new(4711)
		local ids = { "RotBarricade", "PopupBunker", "BrainrotFortress", "RotMine" }
		local LANES, PER_LANE = 6, 12

		local laneSpots = {}
		for _ = 1, 400 do
			if #laneSpots >= LANES then
				break
			end
			local candidate = spots[random:NextInteger(1, #spots)]
			local clear = true
			for _, other in ipairs(laneSpots) do
				if (other - candidate).Magnitude < 160 then
					clear = false
				end
			end
			if clear then
				table.insert(laneSpots, candidate)
			end
		end
		note(string.format("grip: %d lanes", #laneSpots))

		local folder = Instance.new("Folder")
		folder.Name = "GripKits"
		folder.Parent = workspace

		local function makeRig(position)
			local rig = Instance.new("Model")
			rig.Name = "GripRig"
			local root = Instance.new("Part")
			root.Name = "HumanoidRootPart"
			root.Size = Vector3.new(2, 2, 1)
			root.Anchored = true
			root.CanCollide = false
			root.Parent = rig
			local head = Instance.new("Part")
			head.Name = "Head"
			head.Size = Vector3.new(1.2, 1.2, 1.2)
			head.Anchored = true
			head.CanCollide = false
			head.Parent = rig
			rig.PrimaryPart = root
			rig.Parent = workspace
			return rig, root, head
		end

		local function stats(list)
			table.sort(list)
			local n = #list
			if n == 0 then
				return "none"
			end
			local sum = 0
			for _, value in ipairs(list) do
				sum += value
			end
			local function at(p)
				return list[math.clamp(math.ceil(n * p), 1, n)]
			end
			return string.format("n %d, mean %.1f, p50 %.1f, p75 %.1f, p90 %.1f, max %.1f", n, sum / n, at(0.5), at(0.75), at(0.9), list[n])
		end

		-- DefenseService.throwKit's own lob, with the flight time as the knob. Returns the kit and the
		-- point it was aimed at, so the drift is measured against the same target the server would use.
		local function throwKit(option, rig, root, head, itemId, aimPoint)
			local look = root.CFrame.LookVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			flatLook = flatLook.Magnitude > 0.01 and flatLook.Unit or Vector3.new(0, 0, -1)
			local from = head.Position + flatLook * 2 + Vector3.new(0, 0.5, 0)
			local target, _, offset = DefensePlacement.ThrowTarget(from, look, aimPoint)
			local flightTime = math.clamp(offset.Magnitude / option.speed, option.min, option.max)
			local velocity = Vector3.new(offset.X / flightTime, offset.Y / flightTime + 0.5 * workspace.Gravity * flightTime, offset.Z / flightTime)
			local kit, body = ItemModels.Build(itemId, { anchored = false, scale = 1.5, name = itemId .. "Kit" })
			if not kit then
				return nil, target
			end
			kit:PivotTo(CFrame.new(from) * root.CFrame.Rotation)
			body.CanCollide = true
			body.CanQuery = false
			body.Massless = false
			if option.props then
				-- EVERY part, not just the assembly's root: a kit is a model of several welded parts and
				-- the one that meets the ground is rarely the primary. The first run of this study set
				-- the properties on the primary alone, which is why "no bounce" looked like it did
				-- nothing at all.
				for _, part in ipairs(kit:GetDescendants()) do
					if part:IsA("BasePart") then
						part.CustomPhysicalProperties = option.props
					end
				end
			end
			kit.Parent = folder
			pcall(function()
				body:SetNetworkOwner(nil)
			end)
			body.AssemblyLinearVelocity = velocity
			if option.spin then
				body.AssemblyAngularVelocity = Vector3.new(math.random(-6, 6), math.random(-6, 6), math.random(-6, 6))
			end
			return kit, target, flightTime
		end

		-- One option, start to finish. The same 72 throws every time: the plan is worked out up front.
		local function measure(option)
			local laneRandom = Random.new(4711)
			local plan = {}
			for lane = 1, #laneSpots do
				plan[lane] = {}
				for throw = 1, PER_LANE do
					plan[lane][throw] = {
						id = ids[((lane + throw) % #ids) + 1],
						yaw = laneRandom:NextNumber(0, math.pi * 2),
						spread = laneRandom:NextNumber(-0.5, 0.5),
						distance = laneRandom:NextNumber(8, 55),
					}
				end
			end
			local results = {}
			local finished = 0
			for lane, laneSpot in ipairs(laneSpots) do
				task.spawn(function()
					local rig, root, head = makeRig(laneSpot)
					for throw = 1, PER_LANE do
						local shot = plan[lane][throw]
						root.CFrame = CFrame.new(laneSpot + Vector3.new(0, 3, 0)) * CFrame.Angles(0, shot.yaw, 0)
						head.CFrame = root.CFrame * CFrame.new(0, 1.6, 0)
						local ahead = laneSpot + CFrame.Angles(0, shot.yaw + shot.spread, 0).LookVector * shot.distance
						local params = RaycastParams.new()
						params.FilterType = Enum.RaycastFilterType.Exclude
						params.FilterDescendantsInstances = { rig, folder }
						local hit = workspace:Raycast(ahead + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
						local aim = hit and hit.Position or ahead
						local kit, target = throwKit(option, rig, root, head, shot.id, aim)
						-- First contact is a CHANGE IN THE FLIGHT, not a proximity test: a kit passing low
						-- over a hilltop is still flying, and an earlier version of this counted that as
						-- landing and made the throw look far worse than it is. What counts is the frame
						-- where a falling kit stops falling (a bounce or a stop), or where its horizontal
						-- speed suddenly drops (it hit something).
						local landed, firstTouch, falling, lastFlat = nil, nil, false, nil
						local started = os.clock()
						while kit and kit.Parent and os.clock() - started < 8 do
							local body = kit.PrimaryPart or kit:FindFirstChildWhichIsA("BasePart", true)
							if body then
								local position = body.Position
								local speed = body.AssemblyLinearVelocity
								local flat = Vector3.new(speed.X, 0, speed.Z).Magnitude
								landed = position
								if not firstTouch then
									if falling and speed.Y > -1 then
										firstTouch = position
									elseif lastFlat and lastFlat > 8 and flat < lastFlat * 0.6 then
										firstTouch = position
									end
									falling = speed.Y < -5 or falling
									lastFlat = flat
								end
								if os.clock() - started > 0.6 and speed.Magnitude < 3 then
									break
								end
							end
							task.wait(0.03)
						end
						if kit then
							kit:Destroy()
						end
						table.insert(results, { id = shot.id, target = target, from = laneSpot, landed = landed, firstTouch = firstTouch })
						task.wait(0.05)
					end
					rig:Destroy()
					finished += 1
				end)
			end
			local waited = 0
			while finished < #laneSpots and waited < 600 do
				task.wait(1)
				waited += 1
			end

			local rest, first, along, onTarget = {}, {}, {}, 0
			-- The roll on its own: first contact to where it stopped. That is what the preview's ring
			-- has to cover once the arc itself is traced, so it is the number that sizes the ring.
			local roll = {}
			for _, r in ipairs(results) do
				local target = r.target
				if target then
					if r.landed then
						table.insert(rest, (Vector3.new(r.landed.X, 0, r.landed.Z) - Vector3.new(target.X, 0, target.Z)).Magnitude)
					end
					if r.firstTouch then
						local drift = Vector3.new(r.firstTouch.X - target.X, 0, r.firstTouch.Z - target.Z)
						table.insert(first, drift.Magnitude)
						if drift.Magnitude <= 4 then
							onTarget += 1
						end
						local line = Vector3.new(target.X - r.from.X, 0, target.Z - r.from.Z)
						if line.Magnitude > 0.01 then
							table.insert(along, drift:Dot(line.Unit))
						end
						if r.landed then
							table.insert(roll, (Vector3.new(r.landed.X, 0, r.landed.Z) - Vector3.new(r.firstTouch.X, 0, r.firstTouch.Z)).Magnitude)
						end
					end
				end
			end
			note(string.format("grip [%s]: kits %d", option.name, #results))
			note(string.format("grip [%s]: first contact from the aim (studs): %s", option.name, stats(first)))
			note(string.format("grip [%s]: short (-) or past (+) the aim at first contact: %s", option.name, stats(along)))
			note(string.format("grip [%s]: first contact within 4 studs of the aim: %d of %d", option.name, onTarget, #first))
			note(string.format("grip [%s]: rest distance from the aim (studs): %s", option.name, stats(rest)))
			note(string.format("grip [%s]: roll after the first contact (studs): %s", option.name, stats(roll)))
		end

		for _, option in ipairs(OPTIONS) do
			measure(option)
		end
		folder:Destroy()
		camera.CFrame = CFrame.lookAt(laneSpots[1] + Vector3.new(0, 90, 60), laneSpots[1])
	end,
})

--------------------------------------------------------------------------------
-- touch: the shared touch buttons (StarterPlayerScripts/TouchControls) over the approved layout map
--------------------------------------------------------------------------------

do
	local TouchControls = require(Scripts:WaitForChild("TouchControls"))
	local create = UiKit.create
	local C = Colors
	-- The rest of the map (everything but the buttons), drawn faintly behind, from scratchpad/phone_layout_map.py.
	local MAP = {
		["phone 844x390"] = {
			{ "JUMP (Roblox)", "touch", 749.0, 300.0, 819.0, 370.0 },
			{ "THUMBSTICK rest (Roblox)", "touch", 29.0, 297.0, 103.0, 371.0 },
			{ "ROBLOX TOP BAR", "reserved", 0.0, 0.0, 200.0, 52.0 },
			{ "TOP BANNER", "hud", 257.0, 4.0, 587.0, 46.0 },
			{ "STORM LINE", "hud", 297.0, 48.0, 547.0, 61.5 },
			{ "COMPASS", "hud", 257.0, 63.5, 587.0, 81.5 },
			{ "MENU (icon)", "menu", 792.0, 6.0, 836.0, 50.0 },
			{ "STACK TAB (2/3)", "menu", 734.0, 6.0, 786.0, 50.0 },
			{ "EVENT PILL", "tap", 689.7, 85.5, 836.0, 120.2 },
			{ "KILL FEED (2 lines)", "hud", 483.7, 85.5, 683.7, 121.5 },
			{ "TOAST", "transient", 279.0, 117.5, 565.0, 139.5 },
			{ "MINIMAP", "hud", 16.0, 58.0, 112.0, 154.0 },
			{ "BOUNTY", "hud", 16.0, 158.0, 216.0, 177.0 },
			{ "LOCATION", "hud", 16.0, 179.0, 216.0, 196.0 },
			{ "PET ICON", "hud", 16.0, 233.0, 72.0, 289.0 },
			{ "HOTBAR (held cell shows the ammo)", "tap", 349.6, 269.9, 576.8, 382.0 },
			{ "INVENTORY btn", "tap", 532.8, 227.9, 576.8, 259.9 },
			{ "HEALTH + SHIELD (one row)", "hud", 349.6, 229.5, 526.8, 259.9 },
			{ "STAMINA (thin)", "hud", 349.6, 209.9, 486.8, 223.9 },
			{ "SPEED PILL", "hud", 492.8, 203.9, 576.8, 223.9 },
			{ "USE BAR", "transient", 312.0, 87.5, 532.0, 117.5 },
		},
		["phone 667x375"] = {
			{ "JUMP (Roblox)", "touch", 572.0, 285.0, 642.0, 355.0 },
			{ "THUMBSTICK rest (Roblox)", "touch", 29.0, 282.0, 103.0, 356.0 },
			{ "ROBLOX TOP BAR", "reserved", 0.0, 0.0, 200.0, 52.0 },
			{ "TOP BANNER", "hud", 208.0, 4.0, 499.0, 46.0 },
			{ "STORM LINE", "hud", 228.5, 48.0, 478.5, 61.5 },
			{ "COMPASS", "hud", 208.0, 63.5, 499.0, 81.5 },
			{ "MENU (icon)", "menu", 615.0, 6.0, 659.0, 50.0 },
			{ "STACK TAB (2/3)", "menu", 557.0, 6.0, 609.0, 50.0 },
			{ "EVENT PILL", "tap", 337.7, 85.5, 484.0, 120.2 },
			{ "KILL FEED (2 lines)", "hud", 131.7, 85.5, 331.7, 121.5 },
			{ "TOAST", "transient", 190.5, 117.5, 476.5, 139.5 },
			{ "MINIMAP", "hud", 16.0, 58.0, 112.0, 154.0 },
			{ "BOUNTY", "hud", 16.0, 158.0, 216.0, 177.0 },
			{ "LOCATION", "hud", 16.0, 179.0, 216.0, 196.0 },
			{ "PET ICON", "hud", 16.0, 218.0, 72.0, 274.0 },
			{ "HOTBAR (held cell shows the ammo)", "tap", 270.8, 273.5, 460.9, 367.0 },
			{ "INVENTORY btn", "tap", 416.9, 231.5, 460.9, 263.5 },
			{ "HEALTH + SHIELD (one row)", "hud", 270.8, 239.4, 410.9, 263.5 },
			{ "STAMINA (thin)", "hud", 270.8, 213.5, 370.9, 227.5 },
			{ "SPEED PILL", "hud", 376.9, 207.5, 460.9, 227.5 },
			{ "USE BAR", "transient", 223.5, 87.5, 443.5, 117.5 },
		},
		["phone 740x360"] = {
			{ "JUMP (Roblox)", "touch", 645.0, 270.0, 715.0, 340.0 },
			{ "THUMBSTICK rest (Roblox)", "touch", 29.0, 267.0, 103.0, 341.0 },
			{ "ROBLOX TOP BAR", "reserved", 0.0, 0.0, 200.0, 52.0 },
			{ "TOP BANNER", "hud", 208.0, 4.0, 538.0, 46.0 },
			{ "STORM LINE", "hud", 248.0, 48.0, 498.0, 61.5 },
			{ "COMPASS", "hud", 208.0, 63.5, 538.0, 81.5 },
			{ "MENU (icon)", "menu", 688.0, 6.0, 732.0, 50.0 },
			{ "STACK TAB (2/3)", "menu", 630.0, 6.0, 682.0, 50.0 },
			{ "EVENT PILL", "tap", 410.7, 85.5, 557.0, 120.2 },
			{ "KILL FEED (2 lines)", "hud", 204.7, 85.5, 404.7, 121.5 },
			{ "TOAST", "transient", 227.0, 117.5, 513.0, 139.5 },
			{ "MINIMAP", "hud", 16.0, 58.0, 112.0, 154.0 },
			{ "BOUNTY", "hud", 16.0, 158.0, 216.0, 177.0 },
			{ "LOCATION", "hud", 16.0, 179.0, 216.0, 196.0 },
			{ "PET ICON", "hud", 16.0, 203.0, 72.0, 259.0 },
			{ "HOTBAR (held cell shows the ammo)", "tap", 308.0, 255.5, 504.0, 352.0 },
			{ "INVENTORY btn", "tap", 460.0, 213.5, 504.0, 245.5 },
			{ "HEALTH + SHIELD (one row)", "hud", 308.0, 220.5, 454.0, 245.5 },
			{ "STAMINA (thin)", "hud", 308.0, 195.5, 414.0, 209.5 },
			{ "SPEED PILL", "hud", 420.0, 189.5, 504.0, 209.5 },
			{ "USE BAR", "transient", 260.0, 87.5, 480.0, 117.5 },
		},
		["tablet 1024x768"] = {
			{ "JUMP (Roblox)", "touch", 854.0, 558.0, 974.0, 678.0 },
			{ "THUMBSTICK rest (Roblox)", "touch", 58.0, 582.0, 206.0, 730.0 },
			{ "ROBLOX TOP BAR", "reserved", 0.0, 0.0, 220.0, 52.0 },
			{ "TOP BANNER", "hud", 292.0, 4.0, 732.0, 60.0 },
			{ "STORM LINE", "hud", 324.5, 62.0, 699.5, 80.0 },
			{ "COMPASS", "hud", 292.0, 82.0, 732.0, 106.0 },
			{ "MENU (icon)", "menu", 946.0, 6.0, 1012.0, 72.0 },
			{ "STACK TAB (2/3)", "menu", 862.0, 6.0, 940.0, 72.0 },
			{ "EVENT PILL", "tap", 821.8, 110.0, 1012.0, 155.1 },
			{ "KILL FEED (2 lines)", "hud", 515.8, 110.0, 815.8, 164.0 },
			{ "TOAST", "transient", 297.5, 157.0, 726.5, 190.0 },
			{ "MINIMAP", "hud", 16.0, 58.0, 166.0, 208.0 },
			{ "BOUNTY", "hud", 16.0, 212.0, 316.0, 240.5 },
			{ "LOCATION", "hud", 16.0, 242.5, 316.0, 268.0 },
			{ "PET ICON", "hud", 16.0, 486.0, 100.0, 570.0 },
			{ "HOTBAR (held cell shows the ammo)", "tap", 413.6, 614.4, 710.8, 760.0 },
			{ "INVENTORY btn", "tap", 644.8, 556.4, 710.8, 604.4 },
			{ "HEALTH + SHIELD (one row)", "hud", 413.6, 565.8, 638.8, 604.4 },
			{ "STAMINA (thin)", "hud", 413.6, 531.4, 578.8, 552.4 },
			{ "SPEED PILL", "hud", 584.8, 522.4, 710.8, 552.4 },
			{ "USE BAR", "transient", 347.0, 112.0, 677.0, 157.0 },
		},
		["tablet 1180x820"] = {
			{ "JUMP (Roblox)", "touch", 1010.0, 610.0, 1130.0, 730.0 },
			{ "THUMBSTICK rest (Roblox)", "touch", 58.0, 634.0, 206.0, 782.0 },
			{ "ROBLOX TOP BAR", "reserved", 0.0, 0.0, 220.0, 52.0 },
			{ "TOP BANNER", "hud", 370.0, 4.0, 810.0, 60.0 },
			{ "STORM LINE", "hud", 402.5, 62.0, 777.5, 80.0 },
			{ "COMPASS", "hud", 370.0, 82.0, 810.0, 106.0 },
			{ "MENU (icon)", "menu", 1102.0, 6.0, 1168.0, 72.0 },
			{ "STACK TAB (2/3)", "menu", 1018.0, 6.0, 1096.0, 72.0 },
			{ "EVENT PILL", "tap", 977.8, 110.0, 1168.0, 155.1 },
			{ "KILL FEED (2 lines)", "hud", 671.8, 110.0, 971.8, 164.0 },
			{ "TOAST", "transient", 375.5, 157.0, 804.5, 190.0 },
			{ "MINIMAP", "hud", 16.0, 58.0, 166.0, 208.0 },
			{ "BOUNTY", "hud", 16.0, 212.0, 316.0, 240.5 },
			{ "LOCATION", "hud", 16.0, 242.5, 316.0, 268.0 },
			{ "PET ICON", "hud", 16.0, 538.0, 100.0, 622.0 },
			{ "HOTBAR (held cell shows the ammo)", "tap", 476.0, 643.0, 820.0, 812.0 },
			{ "INVENTORY btn", "tap", 754.0, 585.0, 820.0, 633.0 },
			{ "HEALTH + SHIELD (one row)", "hud", 476.0, 586.4, 748.0, 633.0 },
			{ "STAMINA (thin)", "hud", 476.0, 560.0, 688.0, 581.0 },
			{ "SPEED PILL", "hud", 694.0, 551.0, 820.0, 581.0 },
			{ "USE BAR", "transient", 425.0, 112.0, 755.0, 157.0 },
		},
	}
	local SIZES = {
		{ name = "phone 844x390", size = Vector2.new(844, 390) },
		{ name = "phone 667x375", size = Vector2.new(667, 375) },
		{ name = "phone 740x360", size = Vector2.new(740, 360) },
		{ name = "tablet 1024x768", size = Vector2.new(1024, 768) },
		{ name = "tablet 1180x820", size = Vector2.new(1180, 820) },
	}
	local BINDS = {
		{ "BRR_Fire", "FIRE" }, { "BRR_Aim", "AIM" }, { "BRR_Sprint", "RUN" }, { "BRR_Slide", "SLIDE" },
		{ "BRR_Reload", "RELOAD" }, { "BRR_Companion", "PET" }, { "BRR_MovementItem", "MOVE" }, { "BRR_ToggleCamera", "CAM" },
	}

	for _, spec in ipairs(SIZES) do
		add("touch", {
			name = "touch_" .. string.gsub(spec.name, "[^%w]", "_"),
			settle = 1.2,
			hold = 1.8,
			setup = function(_, camera)
				Mock.sky(camera)
				local gui = Mock.gui()
				local viewport = camera.ViewportSize
				local fit = math.min(viewport.X * 0.94 / spec.size.X, viewport.Y * 0.9 / spec.size.Y)
				local screen = create("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
					BackgroundColor3 = Color3.fromRGB(104, 150, 104),
					BorderSizePixel = 0,
					ClipsDescendants = true,
					Parent = gui,
				})
				create("UIScale", { Scale = fit, Parent = screen })
				create("UIGradient", {
					Rotation = 90,
					Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
						ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 226, 232)),
						ColorSequenceKeypoint.new(0.56, Color3.fromRGB(104, 150, 82)),
						ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
					}),
					Parent = screen,
				})
				create("TextLabel", {
					Position = UDim2.fromOffset(12, 8),
					Size = UDim2.fromOffset(500, 22),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = spec.name .. "   •   TouchControls over the layout map",
					TextColor3 = Color3.new(1, 1, 1),
					TextStrokeTransparency = 0.5,
					TextSize = 16,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = screen,
				})
				for _, entry in ipairs(MAP[spec.name] or {}) do
					local name, kind, x0, y0, x1, y1 = entry[1], entry[2], entry[3], entry[4], entry[5], entry[6]
					local round = name == "THUMBSTICK rest (Roblox)" or name == "JUMP (Roblox)"
					local frame = create("Frame", {
						Position = UDim2.fromOffset(x0, y0),
						Size = UDim2.fromOffset(x1 - x0, y1 - y0),
						BackgroundColor3 = kind == "touch" and Color3.fromRGB(90, 90, 240) or Color3.fromRGB(20, 22, 30),
						BackgroundTransparency = kind == "touch" and 0.4 or 0.55,
						BorderSizePixel = 0,
						Parent = screen,
					}, { UiKit.rounded(round and 999 or 8) })
					create("TextLabel", {
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						Font = Enum.Font.Gotham,
						Text = name,
						TextColor3 = Color3.fromRGB(190, 194, 210),
						TextSize = 11,
						TextWrapped = true,
						Parent = frame,
					})
				end

				-- The real buttons, drawn by the module, with the flag and the touch screen forced on here.
				TouchControls._Reset()
				TouchControls.Enabled = true
				TouchControls.ForceTouch = true
				TouchControls.TestParent = screen
				TouchControls.TestViewport = spec.size
				TouchControls._ContextOverride = function()
					return { match = true }, false
				end
				for _, bind in ipairs(BINDS) do
					TouchControls.Bind(bind[1], { label = bind[2], handler = function() end })
				end
				TouchControls.SetState("BRR_Sprint", { lit = true })
				TouchControls.SetState("BRR_Companion", { cooldown = 0.45 })
				TouchControls.Refresh()
			end,
		})
	end

	-- Everything back the way it ships, after the last view of this section.
	add("touch", {
		name = "touch_flag_off_again",
		settle = 1.2,
		hold = 1.8,
		setup = function(_, camera)
			Mock.sky(camera)
			local gui = Mock.gui()
			TouchControls._Reset()
			TouchControls.Enabled = false
			TouchControls.ForceTouch = false
			TouchControls.TestParent = nil
			TouchControls.TestViewport = nil
			create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(700, 60),
				BackgroundColor3 = Colors.Background,
				Font = Enum.Font.GothamBold,
				Text = "TouchControls.Enabled is back to false (it ships off)",
				TextColor3 = Colors.Text,
				TextSize = 20,
				Parent = gui,
			})
		end,
	})
end

return views
