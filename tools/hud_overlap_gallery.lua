-- Visual companion to tools/hud_overlap_probe.lua: one full-screen mockup per owner viewport
-- (1920x1080, 844x390, 375x667), every HUD element outlined at its real measured rectangle,
-- overlapping pairs and the planted fault drawn in red. Numbers come from the same formulas as the
-- probe (PhoneLayout's real Rects()/Place() on the two phone sizes; the same transcribed desktop
-- literals otherwise) -- re-derived here rather than shared, the same way every other gallery/probe
-- pair in this project keeps its own copy (e.g. tools/phone_reach_gallery.lua's mode_scoreline view
-- next to ModeScoreHud.client.lua itself).
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/hud_overlap_gallery.lua -OutDir <dir> -Hold 1 [-PlaceFile <rbxlx>]

local StarterPlayer = game:GetService("StarterPlayer")
local GuiService = game:GetService("GuiService")
local ok_ps, PhoneLayout = pcall(require, StarterPlayer.StarterPlayerScripts:WaitForChild("PhoneLayout"))
assert(ok_ps, "PhoneLayout didn't load: " .. tostring(PhoneLayout))
local UiKit = require(StarterPlayer.StarterPlayerScripts:WaitForChild("UiKit"))

local create = UiKit.create
local INSET = GuiService:GetGuiInset().Y

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local VIEWPORTS = {
	{ name = "1920x1080", x = 1920, y = 1080, force = nil },
	{ name = "844x390", x = 844, y = 390, force = "handheld" },
	{ name = "375x667", x = 375, y = 667, force = "upright" },
}

local function udimRect(anchor, pos, size, vw)
	local w = size[1] * vw.x + size[2]
	local h = size[3] * vw.y + size[4]
	local px = pos[1] * vw.x + pos[2]
	local py = pos[3] * vw.y + pos[4]
	return { x = px - anchor[1] * w, y = py - anchor[2] * h, w = w, h = h }
end
local function offsetRect(x, y, w, h)
	return { x = x, y = y, w = w, h = h }
end
local function placeRect(spot, natural, fit)
	if not spot then
		return nil
	end
	local scale = spot.w / math.max(natural[1], 1)
	if fit and natural[2] * scale > spot.h + 0.5 then
		scale = spot.h / math.max(natural[2], 1)
	end
	return offsetRect(spot.x, spot.y, natural[1] * scale, natural[2] * scale)
end

local DESKTOP = {
	{ name = "Banner", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 10 }, size = { 0, 440, 0, 56 } },
	{ name = "Crosshair", anchor = { 0.5, 0.5 }, pos = { 0.5, 0, 0.5, 0 }, size = { 0, 64, 0, 64 }, group = "centre" },
	{ name = "Health", anchor = { 0, 0 }, pos = { 0, 16, 1, -96 }, size = { 0, 280, 0, 80 } },
	{ name = "Companion status", anchor = { 0, 0 }, pos = { 0, 16, 1, -166 }, size = { 0, 300, 0, 62 } },
	{ name = "Speed pill", anchor = { 0, 0 }, pos = { 0, 16, 1, -202 }, size = { 0, 150, 0, 28 } },
	{ name = "Hotbar", anchor = { 1, 1 }, pos = { 1, -16, 1, -16 }, size = { 0, 690, 0, 150 } },
	{ name = "Use prompt", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0.6, 0 }, size = { 0, 250, 0, 46 } },
	{ name = "Storm timer", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 72 }, size = { 0, 440, 0, 24 }, group = "stormSlot" },
	{ name = "Minimap", anchor = { 1, 0 }, pos = { 1, -16, 0, 108 }, size = { 0, 190, 0, 190 } },
	{ name = "Bounty", anchor = { 1, 0 }, pos = { 1, -16, 0, 304 }, size = { 0, 230, 0, 22 } },
	{ name = "Compass", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 100 }, size = { 0, 440, 0, 24 } },
	{ name = "Location", anchor = { 1, 0 }, pos = { 1, -16, 0, 332 }, size = { 0, 230, 0, 20 } },
	{ name = "Kill feed", anchor = { 1, 0 }, pos = { 1, -16, 0, 312 }, size = { 0, 300, 0, 200 } },
	{ name = "Toast", anchor = { 0.5, 1 }, pos = { 0.5, 0, 1, -120 }, size = { 0, 460, 0, 36 } },
	{ name = "Drop banner", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 128 }, size = { 0, 480, 0, 30 } },
	{ name = "Damage indicator", anchor = { 0.5, 0.5 }, pos = { 0.5, 0, 0.5, -170 }, size = { 0, 4, 0, 150 }, group = "centre" },
}
local MODE_SCORE = { anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 72 }, size = { 0, 420, 0, 44 }, group = "stormSlot" }
local CH_W, CH_ROW, CH_ROWS, CH_HEADER = 228, 22, 8, 44
local STACK_RIGHT, LEFT_STACK_TOP, HOTBAR_INSET, GAP = 316, 202, 706, 12
local function controlsHintDesktopRect(vw)
	local height = CH_HEADER + CH_ROW * CH_ROWS + 8
	local gutterX = STACK_RIGHT + GAP
	local fits = (vw.x - HOTBAR_INSET) - gutterX - GAP >= CH_W
	local x = fits and gutterX or 16
	local y = fits and GAP or (LEFT_STACK_TOP + GAP)
	return offsetRect(x, vw.y - y - height, CH_W, height)
end
local function controlsHintPhoneRect(spot)
	if not spot then
		return nil
	end
	local height = CH_HEADER + CH_ROW * 2 + 8
	return offsetRect(spot.x1 - CH_W, spot.y1 + 6, CH_W, height)
end
local ABILITY_SIZE = 72
local function abilityTileRect(vw)
	return offsetRect(vw.x - (HOTBAR_INSET + GAP) - ABILITY_SIZE, vw.y - 16 - ABILITY_SIZE, ABILITY_SIZE, ABILITY_SIZE)
end
local STACK_TOP, STACK_W, STACK_H = 124, 300, 460
local function questTrackerRect(vw)
	return offsetRect(0, STACK_TOP + INSET, STACK_W, STACK_H)
end
local function menuPanelRect(vw, touch)
	local viewport = Vector2.new(vw.x, vw.y)
	local size = UiKit.panelSize(viewport, touch)
	local safe = UiKit.safeArea(viewport, touch)
	local cy = vw.y / 2 + math.floor((safe.Top - safe.Bottom) / 2)
	return offsetRect(vw.x / 2 - size.X / 2, cy - size.Y / 2 + INSET, size.X, size.Y)
end
local function plantedFaultRect(vw)
	local mm = udimRect({ 1, 0 }, { 1, -16, 0, 108 }, { 0, 190, 0, 190 }, vw)
	return offsetRect(mm.x + 20, mm.y + 20, 60, 60)
end

local function buildElements(vw, menuOpen)
	local elements = {}
	local function add(name, r, group)
		if r then
			table.insert(elements, { name = name, r = r, group = group })
		end
	end
	PhoneLayout.Force = vw.force
	local touch = vw.force ~= nil
	if menuOpen then
		add("Menu panel", menuPanelRect(vw, touch))
	end
	if not vw.force then
		for _, d in ipairs(DESKTOP) do
			add(d.name, udimRect(d.anchor, d.pos, d.size, vw), d.group)
		end
		add("Mode score HUD", udimRect(MODE_SCORE.anchor, MODE_SCORE.pos, MODE_SCORE.size, vw), MODE_SCORE.group)
		if not menuOpen then
			add("Controls hint", controlsHintDesktopRect(vw))
			add("Ability tile", abilityTileRect(vw))
		else
			add("Controls hint [OLD pre-fix]", controlsHintDesktopRect(vw), "preFixDemo")
			add("Ability tile [OLD pre-fix]", abilityTileRect(vw), "preFixDemo")
		end
		add("Quest tracker", questTrackerRect(vw))
	else
		local spots = PhoneLayout.Rects(Vector2.new(vw.x, vw.y))
		add("Banner", placeRect(spots.banner, { 440, 56 }, true))
		add("Storm timer", placeRect(spots.stormLine, { 440, 24 }, true), "stormSlot")
		add("Mode score HUD", placeRect(spots.stormLine, { 420, 44 }, true), "stormSlot")
		add("Compass", placeRect(spots.compass, { 440, 24 }, true))
		add("Minimap", placeRect(spots.minimap, { 190, 190 }, true))
		add("Bounty", placeRect(spots.bounty, { 230, 22 }, true))
		add("Location", placeRect(spots.location, { 230, 20 }, true))
		add("Kill feed", placeRect(spots.killFeed, { 300, 200 }, false))
		add("Health", placeRect(spots.health, { 280, 48 }, true))
		add("Speed pill", placeRect(spots.speedPill, { 150, 28 }, true))
		add("Companion status", placeRect(spots.companion, { 300, 56 }, true))
		if not menuOpen then
			add("Ability tile", placeRect(spots.petIcon, { 72, 72 }, true))
			add("Controls hint", controlsHintPhoneRect(spots.controlsHint))
		else
			add("Ability tile [OLD pre-fix]", placeRect(spots.petIcon, { 72, 72 }, true), "preFixDemo")
			add("Controls hint [OLD pre-fix]", controlsHintPhoneRect(spots.controlsHint), "preFixDemo")
		end
		add("Ability tile [OLD desktop formula]", abilityTileRect(vw), "preFixDemo")
		add("Controls hint [OLD desktop formula]", controlsHintDesktopRect(vw), "preFixDemo")
		if spots.useBar then
			add("Use prompt", offsetRect(vw.x / 2 - 100, spots.useBar.y, 200, 36.8))
		end
		if spots.toast then
			add("Toast", offsetRect(vw.x / 2 - 142.6, spots.toast.y, 285.2, 22.32))
		end
		add("Drop banner", offsetRect(vw.x / 2 - 148.8, 128 * 0.62, 297.6, 18.6))
		local hbSpot = spots.hotbar
		if hbSpot then
			local pad = 6
			local columns = (spots.hotbarSlots and spots.hotbarSlots > 0) and math.min(spots.hotbarSlots, 4) or 4
			local rows = (spots.hotbarSlots and spots.hotbarSlots > 0) and 1 or 2
			local naturalW = columns * 78 + (columns - 1) * 6 + 2 * pad
			local naturalH = rows * 64 + (rows - 1) * 6 + 2 * pad
			local scale = hbSpot.w / (naturalW - 2 * pad)
			add("Hotbar", offsetRect(hbSpot.x1 - naturalW * scale, hbSpot.y1 - naturalH * scale, naturalW * scale, naturalH * scale))
		elseif spots.inventory then
			add("Hotbar (Inventory only)", offsetRect(spots.inventory.x, spots.inventory.y, spots.inventory.w, spots.inventory.h))
		end
		if spots.ready then
			add("Ready pill", offsetRect(spots.ready.x, spots.ready.y, spots.ready.w, 60 * spots.ready.w / 230))
		end
		if spots.stackTab then
			add("Quest tracker", offsetRect(spots.stackTab.x + spots.stackTab.w - STACK_W * 0.8, spots.stackTab.y1 + 6, STACK_W * 0.8, STACK_H * 0.8))
			add("Stack tab", offsetRect(spots.stackTab.x, spots.stackTab.y, spots.stackTab.w, spots.stackTab.h))
		end
		if spots.menu then
			add("Menu icon", offsetRect(spots.menu.x, spots.menu.y, spots.menu.w, spots.menu.h))
		end
		if spots.cam then
			add("Cam icon", offsetRect(spots.cam.x, spots.cam.y, spots.cam.w, spots.cam.h))
		end
		add("Crosshair", udimRect({ 0.5, 0.5 }, { 0.5, 0, 0.5, 0 }, { 0, 64, 0, 64 }, vw), "centre")
		add("Damage indicator", udimRect({ 0.5, 0.5 }, { 0.5, 0, 0.5, -170 }, { 0, 4, 0, 150 }, vw), "centre")
		for _, key in ipairs({ "jump", "stick", "fire", "aim", "reload", "run", "pet", "slide", "move" }) do
			local s = spots[key]
			if s then
				add("Roblox: " .. key, offsetRect(s.x, s.y, s.w, s.h), "reserved")
			end
		end
	end
	add("PLANTED FAULT", plantedFaultRect(vw), "fault")
	return elements
end

local EXCLUDE_GROUPS = { centre = true, stormSlot = true }
local function overlappers(elements)
	local hit = {}
	for i = 1, #elements do
		for j = i + 1, #elements do
			local a, b = elements[i], elements[j]
			local bothReserved = a.group == "reserved" and b.group == "reserved"
			local sameExcludedGroup = a.group and a.group == b.group and EXCLUDE_GROUPS[a.group]
			if not bothReserved and not sameExcludedGroup then
				local ox = math.min(a.r.x + a.r.w, b.r.x + b.r.w) - math.max(a.r.x, b.r.x)
				local oy = math.min(a.r.y + a.r.h, b.r.y + b.r.h) - math.max(a.r.y, b.r.y)
				if ox > 0 and oy > 0 then
					hit[a], hit[b] = true, true
				end
			end
		end
	end
	return hit
end

local views = {}
table.insert(views, {
	name = "hud_overlap_all_three",
	settle = 1.2,
	setup = function(_, camera)
		local root = Instance.new("ScreenGui")
		root.IgnoreGuiInset = true
		root.ResetOnSpawn = false
		root.Parent = game:GetService("CoreGui")
		local sheet = create("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(1880, 900),
			BackgroundColor3 = Color3.fromRGB(18, 19, 24),
			BorderSizePixel = 0,
			Parent = root,
		}, { UiKit.rounded(16) })
		create("UIScale", {
			Scale = math.min(camera.ViewportSize.X * 0.96 / 1880, camera.ViewportSize.Y * 0.92 / 900),
			Parent = sheet,
		})
		create("TextLabel", {
			Position = UDim2.fromOffset(20, 8),
			Size = UDim2.fromOffset(1800, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "HUD overlap audit -- every state on -- green = clear, red = overlaps something, yellow = planted fault. Top row: HUD. Bottom row: menu open.",
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = sheet,
		})

		local SCALE = 0.36
		local ROWS = { { menuOpen = false, label = "HUD", y = 46 }, { menuOpen = true, label = "menu open", y = 46 + 390 * SCALE + 60 } }
		for _, row in ipairs(ROWS) do
			local x = 20
			for _, vw in ipairs(VIEWPORTS) do
				local elements = buildElements(vw, row.menuOpen)
				local hit = overlappers(elements)
				local w, h = vw.x * SCALE, vw.y * SCALE
				local screen = create("Frame", {
					Position = UDim2.fromOffset(x, row.y),
					Size = UDim2.fromOffset(w, h),
					BackgroundColor3 = Color3.fromRGB(30, 32, 40),
					BorderSizePixel = 0,
					ClipsDescendants = true,
					Parent = sheet,
				})
				create("UIStroke", { Color = Color3.fromRGB(90, 95, 110), Thickness = 1, Parent = screen })
				create("TextLabel", {
					Position = UDim2.fromOffset(0, -20),
					Size = UDim2.fromOffset(w, 18),
					BackgroundTransparency = 1,
					Font = Enum.Font.GothamBold,
					Text = vw.name .. " -- " .. row.label,
					TextColor3 = Color3.new(1, 1, 1),
					TextSize = 13,
					TextXAlignment = Enum.TextXAlignment.Left,
					Parent = screen,
				})
				local overlapCount = 0
				for e in pairs(hit) do
					overlapCount += 1
				end
				for _, e in ipairs(elements) do
					local isFault = e.group == "fault"
					local color = hit[e] and (isFault and Color3.fromRGB(255, 220, 60) or Color3.fromRGB(240, 70, 70))
						or (e.group == "reserved" and Color3.fromRGB(100, 100, 110) or Color3.fromRGB(90, 220, 130))
					create("Frame", {
						Position = UDim2.fromOffset(e.r.x * SCALE, e.r.y * SCALE),
						Size = UDim2.fromOffset(math.max(e.r.w * SCALE, 1), math.max(e.r.h * SCALE, 1)),
						BackgroundTransparency = e.group == "preFixDemo" and 1 or (isFault and 0.55 or 0.75),
						BackgroundColor3 = color,
						BorderSizePixel = 0,
						Parent = screen,
					}, {
						create("UIStroke", {
							Color = color,
							Thickness = e.group == "preFixDemo" and 2 or 1,
							Transparency = e.group == "preFixDemo" and 0 or 0.2,
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						}),
					})
				end
				note(string.format("%s / %s: %d elements, %d flagged red/yellow (overlapping)", vw.name, row.label, #elements, overlapCount))
				x += w + 40
			end
		end
	end,
})

return views
