-- PhoneLayout: where every HUD element goes on a touch screen, in screen pixels.
--
-- Phones and small tablets are not small desktops. At 844x390 the desktop HUD draws a 440-wide banner,
-- a 190 minimap, a 690 hotbar and a 300 kill feed at full size on a screen a third the height, so the
-- pieces cover the middle of the screen and each other: measured, 27 overlapping pairs at 844x390 and 44
-- at 667x375. This module is the one place that decides the touch layout, so the pieces cannot drift
-- apart again, and it is a straight port of scratchpad/phone_layout_map.py, which sweeps 2395 landscape
-- sizes looking for overlaps, anything off screen, anything tappable inside the thumbstick's zone,
-- anything over the crosshair, and hotbar cells too small for a finger.
--
-- The rules behind the numbers:
--   * Roblox owns the lower-left (the dynamic thumbstick's zone is the left 40% below a third of the
--     way down) and the lower-right (the jump button), and the top-left (its own bar). Nothing of ours
--     goes in any of them, and nothing tappable of ours goes in the thumbstick's zone at all.
--   * The game's touch buttons are the right thumb's cluster built up from Roblox's jump button (fire,
--     aim, reload, run, pet, slide, move below). TouchControls draws them there when its flag is on; while
--     it is off, ContextActionService draws them and PlaceTouchButton puts each on its square, and
--     TouchSet decides which of them a state has (the seats' buttons swap in for the on-foot ones: see
--     THE TOUCH BUTTONS, BY WHAT THE PLAYER IS DOING). The bottom band keeps out of the cluster.
--   * A phone on its side (short side 500 or less) drops the compass, the location line and the driving
--     hint, stops the hotbar's cells at a little over a finger, and has no hotbar in a driver's or a
--     gunner's seat (the phone HUD polish, 2026-09-28: reports/phone-hud-polish/AUDIT.md).
--   * The middle of the screen is for aiming: the crosshair's box stays clear, and the bottom stack
--     (hotbar, health, stamina) sits below it.
--   * A finger is 44 pixels wherever it is, so that minimum never scales with the screen (40 on phones
--     under 700 across, where nothing else fits, which is about Roblox's own 45-pixel buttons).
--
-- Every rect is in SCREEN pixels from the top-left of the viewport, the same frame ScreenGui offsets use
-- when IgnoreGuiInset is true. HudClient's own ScreenGui does ignore the inset; MenuClient's does not, so
-- MenuClient subtracts the inset itself (Rects().inset carries it).

local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local PhoneLayout = {}

-- Test hook: "desktop", "handheld" or "upright" forces the version whatever the device says (the probe
-- and the gallery set it; nothing in the game does).
PhoneLayout.Force = nil

-- WHICH VERSION A DEVICE GETS -- the one decision, in one place.
--
-- There are three HUDs, not one that stretches: the owner asked for separate versions after seeing the
-- big one work and the small ones not.
--   "desktop"   the big HUD, as it has always been drawn. Untouched by this module.
--   "handheld"  a touch screen held on its side: everything smaller, and laid out round Roblox's own
--               thumbstick, jump button and top bar. Phones and tablets alike; `k` scales it up on a
--               tablet, which is the one place a size still matters inside a version.
--   "upright"   a touch screen held upright, where the lower half belongs to Roblox's controls and there
--               is no band for a hotbar: a deliberately smaller HUD (see portraitRects).
--
-- A laptop with a touch screen stays "desktop": it has a keyboard and a mouse, and its viewport is not the
-- problem this module solves. Studio's device emulator is the exception -- it reports a keyboard while
-- pretending to be a phone -- or the whole thing could only be tested on a real handset.
--
-- NOT THE SAME AS UiKit.form, AND DELIBERATELY SO. There are two of these in the project and they are
-- meant to disagree:
--   * `UiKit.form(viewport)` (large / short / tall) asks WHAT SHAPE THE SCREEN IS, because the menu draws
--     into a panel and what matters is which dimension has run out.
--   * `PhoneLayout.Mode(viewport)` (desktop / handheld / upright) asks WHAT THE DEVICE IS, because the HUD
--     has to dodge Roblox's thumbstick zone, jump button and touch buttons, and those only exist on a
--     touch screen at all. No word is shared with the menu's three, on purpose.
-- Worked example, the one that catches people: a tablet held upright at 768x1024 is "large" to
-- UiKit.form -- 728 pixels of panel is not a small screen -- and "upright" here, because the bottom half
-- of that screen belongs to Roblox's thumbstick and buttons and the HUD has to be a different, smaller
-- one. A laptop with a touch screen is the mirror image: "tall" or "short" to the menu when its window is
-- small, always "desktop" here because it has a mouse and a keyboard.
-- Do not unify them. Using the same words would imply they agree, and both surfaces break when they are
-- made to.
function PhoneLayout.Mode(viewport)
	if PhoneLayout.Force then
		return PhoneLayout.Force
	end
	if not UserInputService.TouchEnabled then
		return "desktop"
	end
	if UserInputService.KeyboardEnabled and not RunService:IsStudio() then
		return "desktop"
	end
	if viewport.Y > viewport.X then
		return "upright"
	end
	return math.min(viewport.X, viewport.Y) <= 1100 and "handheld" or "desktop"
end

function PhoneLayout.Active(viewport)
	return PhoneLayout.Mode(viewport) ~= "desktop"
end

local function rect(x, y, w, h)
	return { x = x, y = y, w = w, h = h, x1 = x + w, y1 = y + h }
end

-- The driving HUD, laid out inside a region: VehicleClient's speed panel (250x78 as drawn on a desktop)
-- and VehicleWeaponClient's gun panel (150x78) side by side, or the gun panel under the speed panel when
-- that lets both be bigger; the damage line (260x20) above them and the controls hint (300x18, which the
-- touch wording needs) below. `vehicleScale` is the panels' scale. On a desktop screen those pieces sit
-- above the hotbar at their own literals; on a touch screen those literals put them over the crosshair
-- (844x390) and across the hotbar (upright) (#80, tools/hud_layout_check.py).
local function vehicleRects(out, x, y, w, h)
	local beside = math.min(w / 408, (h - 4) / 116)
	local stacked = math.min(w / 250, (h - 6) / 194)
	local k = math.min(math.max(beside, stacked), 1)
	local kw, kh = math.min(k, w / 260), math.min(k, w / 300)
	out.vehicleScale = k
	out.vehicleWarning = rect(x, y, 260 * kw, 20 * kw)
	local panelY = out.vehicleWarning.y1 + 2
	out.vehicle = rect(x, panelY, 250 * k, 78 * k)
	if beside >= stacked then
		out.vehicleGun = rect(x + 258 * k, panelY, 150 * k, 78 * k)
	else
		out.vehicleGun = rect(x, out.vehicle.y1 + 2, 150 * k, 78 * k)
	end
	out.vehicleHint = rect(x, math.max(out.vehicle.y1, out.vehicleGun.y1) + 2, 300 * kh, 18 * kh)
end

-- Portrait is not the landscape layout turned on its side. Roblox owns the lower half of a portrait
-- screen -- the thumbstick's zone is the left 40% below a third of the way down, and the fire buttons
-- climb the right side from the jump button -- so there is no band between them for a hotbar, and
-- anything a finger presses has to be above that zone or to the right of it. The owner's answer to
-- "portrait doesn't fit" was to simplify the HUD until it does, so this is a smaller HUD, not a second
-- full one: no compass, no kill feed, no bounty or location line, no speed pill; the hotbar keeps the
-- slots that fit (and on the shortest screens none at all, just the button that opens the panel); and
-- the minimap, the coin chip and the companion strip are all still here, small.
local function portraitRects(W, H)
	local g = 8
	local out = { k = 1, small = true, portrait = true }
	local jumpX, jumpY, jumpSize = W - 95, H - 90, 70
	local stickX, stickY, stickD = 66, H - 56, 74
	-- Roblox's controls go by the short side, whichever way up (TouchJump: 70 px when it is 500 or less,
	-- else 120 at W-170, H-210): an upright tablet has the big jump button, and the touch buttons, which
	-- are laid out from it (TouchButtons), sat on top of it when this assumed the phone's.
	local bigControls = math.min(W, H) > 500
	if bigControls then
		jumpX, jumpY, jumpSize = W - 170, H - 210, 120
		stickX, stickY, stickD = 132, H - 112, 148
	end
	out.jump = rect(jumpX, jumpY, jumpSize, jumpSize)
	out.stick = rect(stickX - stickD / 2, stickY - stickD / 2, stickD, stickD)
	out.topBar = rect(0, 0, 200, 52)
	out.moveZone = rect(0, H / 3, 0.4 * W, H * 2 / 3)

	local B, F = 48, 72
	local fireX, fireY = jumpX - g - F, jumpY + jumpSize - F
	out.fire = rect(fireX, fireY, F, F)
	local colA, colB = fireX + (F - B) / 2, jumpX + (jumpSize - B) / 2
	local row = math.min(fireY, jumpY)
	for _, pair in ipairs({ { "aim", "reload" }, { "run", "pet" }, { "slide", "move" } }) do
		row = row - g - B
		out[pair[1]] = rect(colA, row, B, B)
		out[pair[2]] = rect(colB, row, B, B)
	end
	local clusterLeft, clusterTop = fireX, row

	local m, iconsY, mm = 44, 58, 72
	out.menu = rect(W - g - m, iconsY, m, m)
	out.stackTab = rect(W - g - m - 6 - 52, iconsY, 52, m)
	local camX = W - g - m - 6 - 52 - 6 - m
	out.cam = rect(camX, iconsY, m, m)
	out.minimap = rect(16, iconsY, mm, mm)
	local bannerY = iconsY + mm + 4
	out.banner = rect(16, bannerY, W - 32, 42)
	local stormY = bannerY + 42 + 2
	out.stormLine = rect(16, stormY, W - 32, 18)
	out.compass = nil

	local pillW, pillH = 236 * 0.62, 56 * 0.62
	local pillY = stormY + 18 + 6
	out.eventPill = rect(W - g - pillW, pillY, pillW, pillH)
	out.ready = rect(W - g - math.max(pillW, 169), pillY, math.max(pillW, 169), 44)
	out.eventPillBelow = rect(W - g - pillW, out.ready.y1 + 6, pillW, pillH)
	out.coins = rect(16, pillY, 120, 28)
	local compY = pillY + 28
	out.companion = rect(16, compY, math.clamp(W - g - pillW - 6 - 16, 96, 138), 24)
	out.petIcon = rect(16, compY + 28, 56, 56)
	-- The toast and the use prompt are full-width-ish strips, and the top of an upright screen has no such
	-- row left under the coin chip, the companion strip, the pet tile and the event pills: at the old
	-- spots the toast lay across the companion strip and the pet tile, and the prompt across the coin chip
	-- and the event pill (#80, measured by tools/hud_layout_check.py). They go under the crosshair's box
	-- instead, where nothing else of ours is drawn on an upright screen. The prompt's rect is what
	-- HudClient actually draws there (250x46 at 0.8), not a guess.
	local crossBottom = H / 2 + 32 + 12
	out.toast = rect(16, crossBottom, W - 32, 22)
	out.useBar = rect(W / 2 - 100, crossBottom + 22 + 4, 200, 37)

	-- The hotbar row: the Inventory button and as many slots as fit between the thumbstick's zone and
	-- the right edge, above the buttons and clear of the crosshair's band.
	local cell, gap, inv = 44, 3, 44
	local room = (W - g) - (0.4 * W + 4) - inv - 6
	local cells = math.clamp(math.floor((room + gap) / (cell + gap)), 2, 4)
	local gridW = cells * cell + (cells - 1) * gap
	local hotY = clusterTop - 6 - cell
	local hotX = W - g - gridW - 6 - inv
	local rowClear = hotY > H / 2 + 12 or hotY + cell < H / 2 - 12 or hotX > W / 2 + 12
	local rowBelowPill = hotY > pillY + pillH or hotX > W - g - pillW
	if rowClear and rowBelowPill then
		out.hotbar = rect(hotX + inv + 6, hotY, gridW, cell)
		out.inventory = rect(hotX, hotY, inv, cell)
		out.hotbarSlots = cells
	else
		-- The shortest portrait screens have nowhere for a row: between the top strip and the buttons
		-- there is only the crosshair's own band. The slots live in the panel and the screen keeps the
		-- button that opens it.
		out.hotbarSlots = 0
		local fallbackY = pillY + pillH + 6
		if fallbackY + inv > clusterTop - 6 then
			out.inventory = rect(camX - 6 - inv, iconsY, inv, m)
		else
			out.inventory = rect(W - g - inv, fallbackY, inv, inv)
		end
	end
	out.hotbarCell, out.hotbarGap, out.hotbarTight = cell, gap, false

	-- Health and stamina are readouts, not buttons, so they can sit in the thumbstick's corner where a
	-- player already looks for them.
	local stickTop = out.stick.y
	local healthY = stickTop - 6 - 30
	local readoutW = math.clamp(clusterLeft - 6 - 16, 96, 138)
	out.health = rect(16, healthY, readoutW, 30)
	out.stamina = rect(16, healthY - 4 - 14, readoutW, 14)
	-- Driving: the left-hand block between the use prompt (and the hotbar row, when it is there) and the
	-- health readout, left of the buttons. The stamina bar that sits in it is hidden in a vehicle.
	local driveTop = out.useBar.y1 + 6
	if out.hotbar then
		driveTop = math.max(driveTop, out.inventory.y1 + 6)
	end
	vehicleRects(out, 16, driveTop, clusterLeft - 6 - 16, math.max(out.health.y - 6 - driveTop, 40))
	-- No driving hint on an upright phone, as on its side (Rects).
	if not bigControls then
		out.vehicleHint = nil
	end
	-- An emplacement's gunner panel (MountedGunClient, 240x46): at the use prompt's height, under the
	-- crosshair (nothing is used from a gun's seat, and the top of an upright screen has no room for it),
	-- from the left edge and short of the buttons, whose top row reaches that high on a short screen.
	local gunW = math.min(240, clusterLeft - 6 - 16)
	out.gunnerPanel = rect(16, out.useBar.y, gunW, 46 * gunW / 240)
	-- The companion-buffs panel (BoonHud): down the left edge under the pet tile, narrow enough to stay
	-- left of the crosshair's box, and no lower than the toast. A readout, so the thumbstick's zone is
	-- allowed; BoonHud scales it down to fit the height when there are many buffs.
	local boonsY = out.petIcon.y1 + 6
	out.boons = rect(16, boonsY, math.min(152, W / 2 - 44 - 16), math.max(crossBottom - 6 - boonsY, 40))
	out.inset = GuiService:GetGuiInset().Y
	return out
end

-- The whole layout for a viewport: a table of rects by name, plus the numbers the callers need (the
-- scale k, the hotbar's cell size, and the Roblox inset). Cheap enough to call on every viewport change.
function PhoneLayout.Rects(viewport)
	local W, H = viewport.X, viewport.Y
	if H > W then
		return portraitRects(W, H)
	end
	local small = math.min(W, H) <= 500
	-- Clamped at 1 below, not just 1.5 above, so the 500-to-512 band matches TouchControls.Layout,
	-- which works the same numbers out for itself (the probe compares the two).
	local k = small and 1 or math.clamp(math.min(W, H) / 512, 1, 1.5)
	local g = 8 * k
	local out = { k = k, small = small }

	-- Roblox's own controls, from its CoreScripts (TouchJump, DynamicThumbstick).
	local jumpX, jumpY, jumpSize, stickX, stickY, stickD
	if small then
		jumpX, jumpY, jumpSize = W - 95, H - 90, 70
		stickX, stickY, stickD = 66, H - 56, 74
	else
		jumpX, jumpY, jumpSize = W - 170, H - 210, 120
		stickX, stickY, stickD = 132, H - 112, 148
	end
	out.jump = rect(jumpX, jumpY, jumpSize, jumpSize)
	out.stick = rect(stickX - stickD / 2, stickY - stickD / 2, stickD, stickD)
	out.topBar = rect(0, 0, 200 * (small and 1 or 1.1), 52)
	out.moveZone = rect(0, H / 3, 0.4 * W, H * 2 / 3)

	-- The right thumb cluster, two columns built up from the jump button (TouchControls draws these).
	local B, F = 48 * k, 72 * k
	local fireX = jumpX - g - F
	local fireY = jumpY + jumpSize - F
	out.fire = rect(fireX, fireY, F, F)
	local colA = fireX + (F - B) / 2
	local colB = jumpX + (jumpSize - B) / 2
	local row = math.min(fireY, jumpY)
	local PAIRS = { { "aim", "reload" }, { "run", "pet" }, { "slide", "move" } }
	for _, pair in ipairs(PAIRS) do
		row = row - g - B
		out[pair[1]] = rect(colA, row, B, B)
		out[pair[2]] = rect(colB, row, B, B)
	end
	local clusterLeft, clusterTop = fireX, row

	-- Top strip: the banner and compass centred in what's left between Roblox's bar and the icons.
	local sTop = small and 0.75 or 1
	local m = 44 * k
	local camLeft = W - g - m - 6 - 52 * k - 6 - m
	local roomLeft, roomRight = out.topBar.x1 + 8, camLeft - 8
	local bw = math.min(440 * sTop, roomRight - roomLeft)
	local bx = math.min(math.max(W / 2 - bw / 2, roomLeft), roomRight - bw)
	-- Banner, then the storm line, then the compass: one thin stack at the top, in the order they have on
	-- a desktop screen, with the storm line pulled up under the banner so the right-hand column (the
	-- event pill and the kill feed) can start below the whole strip. The storm line is narrower than the
	-- banner because it is one centred line of text.
	out.banner = rect(bx, 4, bw, 56 * sTop)
	local stormY = 4 + 56 * sTop + 2
	local stormW = math.min(250 * k, bw)
	out.stormLine = rect(bx + (bw - stormW) / 2, stormY, stormW, 18 * sTop)
	local compassY = stormY + 18 * sTop + 2
	out.compass = rect(bx, compassY, bw, 24 * sTop)
	local topStripBottom = compassY + 24 * sTop
	-- A phone drops the compass (the phone HUD polish, 2026-09-28): at 844x390 it was a third strip across
	-- the top middle, 18 px of bearings nobody reads at that size, and the minimap under Roblox's bar
	-- already says which way is which. What was under it moves up into the room it leaves.
	if small then
		out.compass = nil
		topStripBottom = stormY + 18 * sTop
	end
	out.menu = rect(W - g - m, 6, m, m)
	out.stackTab = rect(W - g - m - 6 - 52 * k, 6, 52 * k, m)
	out.cam = rect(camLeft, 6, m, m)

	local pillW, pillH = 236 * 0.62 * (small and 1 or 1.3), 56 * 0.62 * (small and 1 or 1.3)
	local underTop = math.max(6 + m + 6, topStripBottom + 4)
	local mm = small and 96 * k or 150
	local feedH = 2 * 18 * k
	-- The pill sits under the icons, unless the button cluster reaches that high on a short screen: then
	-- it ends just left of the cluster instead.
	local pillRight = W - g
	if clusterTop < underTop + math.max(pillH, feedH) + g then
		pillRight = clusterLeft - g
	end
	out.eventPill = rect(pillRight - pillW, underTop, pillW, pillH)
	-- The lobby's READY pill takes the same corner (there is no event pill in a match at the same time
	-- as a READY pill), at a finger's height, and the event pill drops below it while it is there.
	local readyW, readyH = math.max(pillW, 169), 44
	out.ready = rect(pillRight - readyW, underTop, readyW, readyH)
	out.eventPillBelow = rect(pillRight - pillW, out.ready.y1 + 6, pillW, pillH)
	-- Left of the READY pill's width, not just the event pill's: the lobby's pill is 169 wide to the event
	-- pill's 146, and the feed's box sat 17 px into it (measured once hud_layout_check had a lobby).
	local cornerW = math.max(pillW, readyW)
	local feedW = math.min(200 * k, pillRight - cornerW - 6 - (16 + mm + g))
	local feedBottom
	if feedW >= 140 then
		out.killFeed = rect(pillRight - cornerW - 6 - feedW, underTop, feedW, feedH)
		feedBottom = underTop + math.max(feedH, pillH)
	else
		feedW = math.min(200 * k, W - 2 * g - (16 + mm + g))
		out.killFeed = rect(pillRight - feedW, underTop + pillH + 4, feedW, feedH)
		feedBottom = underTop + pillH + 4 + feedH
	end
	out.useBar = rect(W / 2 - 110 * k, topStripBottom + 6, 220 * k, 30 * k)
	-- Below the kill feed's slot too: the toast is centred and 286 wide, and reaches into the right-hand
	-- column the feed starts (#80: 3 px into its second row at 844x390, 5 px at 1024x768).
	out.toast = rect(W / 2 - 143 * k, math.max(topStripBottom + 6 + 30 * k, out.killFeed.y1 + 4), 286 * k, 22 * k)
	-- The bounty and location lines, right-aligned under the kill feed, never under the button cluster
	-- and never back into the left column.
	local textRight = math.min(pillRight, clusterLeft - g)
	local leftColumnRight = 16 + math.max(mm, 120 * k + 6 + 160 * k) + 8
	local textW = math.max(textRight - math.max(textRight - 200 * k, leftColumnRight), 120)
	-- Below the toast as well as the feed: the toast is centred and 286 wide, and on a phone its right
	-- end reaches into this column (#80: 104x14 px over the bounty line at 844x390, the very moment the
	-- bounty's own toast is up).
	local textY = math.max(feedBottom, out.toast.y1) + 4
	out.bounty = rect(textRight - textW, textY, textW, 19 * k)
	out.location = rect(textRight - textW, textY + 19 * k + 2, textW, 17 * k)
	-- The location line goes on a phone as well: the town's name is announced in the middle of the screen
	-- on the way in (HudClient's entering label), and under the bounty it was the fourth line of text in
	-- that corner. The bounty line stays: it is a target.
	if small then
		out.location = nil
	end

	-- Left edge: the minimap under Roblox's bar, then the two things the owner asked to keep but shrink
	-- (the coin chip and the companion strip) sharing one row, then the pet tile above the thumbstick's
	-- rest. The bounty and location lines move to the right column: this is the tightest column on the
	-- screen and those two are the least urgent things in it.
	out.minimap = rect(16, 58, mm, mm)
	local pt = 56 * k
	out.petIcon = rect(16, out.stick.y - g - pt, pt, pt)
	-- Sized so the text inside is still readable once it is scaled: the chip is drawn at 210 wide and the
	-- companion strip at 300, so 120 and 160 keep them at about 0.55 -- 12 to 14 pixel text, not 8.
	local statusH = 32 * k
	local statusY = 58 + mm + 4
	if statusY + statusH > out.petIcon.y - 4 then
		statusY = out.petIcon.y - 4 - statusH
	end
	out.coins = rect(16, statusY, 120 * k, 28 * k)
	out.companion = rect(16 + 120 * k + 6, statusY, 160 * k, statusH)

	-- The bottom band, between the thumbstick's zone and the buttons: hotbar, health row, stamina.
	local bandLeft = math.max(out.stick.x1 + 10, 0.4 * W + 4)
	local bandRight = math.min(clusterLeft, 0.7 * W) - 6
	local bandW = bandRight - bandLeft
	local cellGap = small and 3 * k or 4 * k
	local bottom = H - 8
	local inv, invH = 44 * k, 32 * k
	local cellMin = W >= 700 and 44 or 40
	-- The crosshair's own 24-pixel box is in the middle of the screen; the stack's top stays below it.
	local topLimit = H / 2 + 14
	-- On a phone the cells stop a little over the finger minimum instead of growing to fill the band:
	-- anything bigger only pushes the health row and the stamina bar up against the crosshair (at 844x390
	-- the stack's top was 4 px under the crosshair's box). A tablet keeps the room it has.
	local cell = math.min((bandW - 3 * cellGap) / 4, small and cellMin + 4 or 60 * k)
	local healthH, gridW = 0, 0
	while true do
		gridW = 4 * cell + 3 * cellGap
		-- The health row is the real block scaled to the width it gets, so its height follows its shape
		-- (280x48 in the phone arrangement HudClient switches to) rather than a guessed number.
		healthH = 48 * (gridW - inv - 6) / 280
		-- 10 above the grid, not 6: the hotbar's plate has its own padding round the cells, and that gap
		-- is what keeps the plate's edge off the health row.
		local stack = 2 * cell + cellGap + 10 + math.max(healthH, invH) + 4 + 14 * k
		if bottom - stack >= topLimit or cell <= cellMin + 0.01 then
			break
		end
		cell -= 1
	end
	-- A band too narrow for a finger (a portrait screen, where the game has no layout of its own yet)
	-- gets cells at the minimum anyway, overflowing the band rather than drawing eight 10-pixel slots
	-- nobody can hit. `hotbarTight` says so, and the probe's sweep treats it as a problem.
	out.hotbarTight = cell < cellMin - 0.01
	cell = math.max(cell, cellMin)
	local gridH = 2 * cell + cellGap
	local row2H = math.max(healthH, invH)
	local x0 = bandLeft + (bandW - gridW) / 2
	out.hotbar = rect(x0, bottom - gridH, gridW, gridH)
	out.hotbarCell, out.hotbarGap = cell, cellGap
	local hy = bottom - gridH - 10 - row2H
	out.inventory = rect(x0 + gridW - inv, hy + row2H - invH, inv, invH)
	out.health = rect(x0, hy + row2H - healthH, gridW - inv - 6, healthH)
	local sy = hy - 4 - 14 * k
	local pill = 84 * k
	out.stamina = rect(x0, sy, gridW - pill - 6, 14 * k)
	out.speedPill = rect(x0 + gridW - pill, sy - 6 * k, pill, 20 * k)
	-- The companion-buffs panel (BoonHud): right of the pet tile, under the coin chip and the companion
	-- strip, and clear of the thumbstick's rest and of the health row. A readout, so the thumbstick's zone
	-- is allowed; BoonHud scales it down to fit the height when there are many buffs.
	local boonsX, boonsY = out.petIcon.x1 + 6, statusY + statusH + 6
	out.boons = rect(boonsX, boonsY, math.min(152 * k, out.health.x - 6 - boonsX), math.max(out.stick.y - 6 - boonsY, 40))
	-- Driving: the block right of the pet tile, from under the coin chip and companion strip down to the
	-- thumbstick's rest, left of the health row. The buffs panel that shares it hides in a vehicle
	-- (BoonHud), which is why the block can be this big.
	vehicleRects(out, boonsX, boonsY, out.health.x - 6 - boonsX, math.max(out.stick.y - 6 - boonsY, 40))
	-- A phone drops the driving hint ("JUMP get out  BRAKE handbrake"): scaled into this block it was 6 px
	-- text, and the BRAKE and LEAVE buttons say the same thing on themselves now.
	if small then
		out.vehicleHint = nil
	end
	-- An emplacement's gunner panel (MountedGunClient: the arc gauge, the range, the way off; 240x46 as
	-- drawn): at the foot of the bottom band, where the hotbar is on foot -- a gunner has none
	-- (SeatHidesHotbar). Its desktop-era touch spot, top middle, lay across the banner and the storm line.
	local gunW = math.min(240, bandW)
	out.gunnerPanel = rect(bandLeft + (bandW - gunW) / 2, bottom - 46 * gunW / 240, gunW, 46 * gunW / 240)

	out.inset = GuiService:GetGuiInset().Y
	return out
end

--------------------------------------------------------------------------------
-- THE TOUCH BUTTONS, BY WHAT THE PLAYER IS DOING
--------------------------------------------------------------------------------
-- ContextActionService draws at most SEVEN touch buttons, and a slot only frees when its action is
-- unbound. The on-foot set (FIRE, AIM, RELOAD, RUN, PET, CROUCH, MOVE) is seven on its own and used to
-- stay bound all session, so every button a seat binds later -- the driver's BRAKE and gun, the gunner's
-- FIRE, AIM, RELOAD and LEAVE, the coconut's COOK -- got no button at all: a phone gunner could not fire
-- (Jacob's device-compat finding #1). And the seven sat at positions each script picked for itself, which
-- is not where this layout keeps the button cluster: MOVE landed 30 px above the crosshair on an 844x390
-- screen and inside the thumbstick's zone on a 667x375 one, PET across the health row, RUN and CROUCH
-- across the kill feed. They also stayed up in the lobby and while spectating, where none of them does
-- anything.
--
-- So the set of buttons follows what the player is doing, and every one of them sits in this layout's
-- cluster (Rects().fire, .aim, .reload, .run, .pet, .slide, .move; the same squares TouchControls draws).
-- The table below is the ONE decision; Settings applies it to the bindings it owns (it drops the touch
-- button from an on-foot binding the state has no place for, and puts it back after), and each seat's
-- own script asks `TouchWanted` before it binds, so a state never asks for more than seven.
--   context  "match" (alive, with a loadout, in a match), "range" (the firing range), "lobby",
--            "spectate". Anything unknown counts as a match, so nobody is left in one without FIRE.
--   seat     "foot", "driver" (a car's driving seat), "gunner" (a vehicle's turret or an emplacement),
--            "passenger" (any other seat, a bike's pillion too), "bike" (a bike's rider).
-- A driver has nothing in hand (CombatService.SeatBarsWeapons), so the on-foot set goes and the car's
-- come in. Passengers and bike riders shoot from the seat (the same rule), so they keep FIRE, AIM and
-- RELOAD, and the rider gets BRAKE. Everyone in a seat gets LEAVE: Roblox's jump button gets you out too,
-- but a jump icon does not say so, and the gunner's LEAVE (MountedGunClient) was already the answer there.
PhoneLayout.TouchLabels = {
	BRR_Fire = "FIRE", BRR_Aim = "AIM", BRR_Reload = "RELOAD", BRR_Sprint = "RUN", BRR_Companion = "PET",
	BRR_Crouch = "CROUCH", BRR_MovementItem = "MOVE", BRR_Cook = "COOK",
	VehicleHandbrake = "BRAKE", BRR_VehicleFire = "FIRE", BRR_GunnerAim = "AIM", BRR_GunReload = "RELOAD",
	BRR_GunLeave = "LEAVE", BRR_SeatLeave = "LEAVE",
}

-- Action -> slot, per state. FIRE is always the big button by the jump button; LEAVE is always at the
-- top of the cluster, the square furthest from the thumb's rest, so it is not pressed by accident.
local ON_FOOT = {
	{ "BRR_Fire", "fire" }, { "BRR_Aim", "aim" }, { "BRR_Reload", "reload" }, { "BRR_Sprint", "run" },
	{ "BRR_Companion", "pet" }, { "BRR_Crouch", "slide" }, { "BRR_MovementItem", "move" },
}
-- The on-foot actions by name: the ones Settings owns and takes the button from when a state drops them.
PhoneLayout.OnFoot = {}
for _, entry in ipairs(ON_FOOT) do
	PhoneLayout.OnFoot[entry[1]] = true
end
PhoneLayout.TouchSets = {
	foot = ON_FOOT,
	-- BRAKE above the gas thumb's rest (the thumbstick drives), the driver's gun on the big button.
	driver = { { "BRR_VehicleFire", "fire", armed = true }, { "VehicleHandbrake", "aim" }, { "BRR_SeatLeave", "move" } },
	-- VehicleWeaponClient's FIRE and AIM, MountedGunClient's RELOAD and LEAVE.
	gunner = { { "BRR_VehicleFire", "fire" }, { "BRR_GunnerAim", "aim" }, { "BRR_GunReload", "reload" }, { "BRR_GunLeave", "move" } },
	passenger = { { "BRR_Fire", "fire" }, { "BRR_Aim", "aim" }, { "BRR_Reload", "reload" }, { "BRR_SeatLeave", "move" } },
	bike = { { "BRR_Fire", "fire" }, { "BRR_Aim", "aim" }, { "BRR_Reload", "reload" }, { "VehicleHandbrake", "run" }, { "BRR_SeatLeave", "move" } },
}
-- Out of a match: the lobby keeps what works there (sprint, the companion's move), the range what its
-- guns need, and a spectator none (CombatClient draws its own NEXT and LEAVE).
PhoneLayout.TouchContexts = {
	lobby = { BRR_Sprint = true, BRR_Companion = true },
	range = { BRR_Fire = true, BRR_Aim = true, BRR_Reload = true, BRR_Sprint = true, BRR_Companion = true },
	spectate = {},
}
-- ContextActionService's cap, which no state may go over.
PhoneLayout.TouchCap = 7

-- The seats a phone's hotbar steps out of (HudClient): a driver's hands are on the wheel and a gunner's
-- on the mount, so nothing in it can be used, and it was the biggest thing in the bottom middle of the
-- screen. A passenger and a bike's rider shoot their own guns, so they keep it.
PhoneLayout.SeatHidesHotbar = { driver = true, gunner = true }

-- Which seat a humanoid is in, by the same rules the scripts that own the seats use: VehicleWeaponClient's
-- gunner seat (a Seat named GunnerSeat, or with a true Gunner attribute), a VehicleSeat on a model whose
-- VehicleKind is "bike" for the rider (CombatService.SeatBarsWeapons), any other VehicleSeat for a driver.
function PhoneLayout.SeatOf(humanoid)
	local seat = humanoid and humanoid.SeatPart
	if not seat then
		return "foot"
	end
	local vehicle = seat.Parent
	local bike = vehicle ~= nil and vehicle:GetAttribute("VehicleKind") == "bike"
	if seat:IsA("VehicleSeat") then
		return bike and "bike" or "driver"
	end
	if seat.Name == "GunnerSeat" or seat:GetAttribute("Gunner") == true then
		return "gunner"
	end
	return "passenger"
end

-- The buttons a state shows, in order: { action, slot, label }. `flags.cook`: a cookable throwable in
-- hand, so COOK takes RELOAD's square (nothing reloads a coconut). `flags.armed`: the driver's car has
-- a gun (it is left out of an unarmed car's set, where nothing binds it).
function PhoneLayout.TouchSet(context, seat, flags)
	flags = flags or {}
	local set = PhoneLayout.TouchSets[seat] or ON_FOOT
	local allowed = PhoneLayout.TouchContexts[context]
	local out = {}
	for _, entry in ipairs(set) do
		local action, slot = entry[1], entry[2]
		if entry.armed and flags.armed == false then
			action = nil
		elseif action == "BRR_Reload" and flags.cook and seat == "foot" then
			action = "BRR_Cook"
		end
		-- A seat's own buttons show wherever the seat is; the on-foot ones only where the context has them
		-- (COOK where RELOAD is).
		local gate = action == "BRR_Cook" and "BRR_Reload" or action
		if action and (not allowed or not PhoneLayout.OnFoot[gate] or allowed[gate]) then
			table.insert(out, { action = action, slot = slot, label = PhoneLayout.TouchLabels[action] })
		end
	end
	return out
end

-- The same with each button's square on a viewport (screen pixels), for the checks and the gallery.
function PhoneLayout.TouchButtons(viewport, context, seat, flags)
	local spots = PhoneLayout.Rects(viewport)
	local out = {}
	for _, entry in ipairs(PhoneLayout.TouchSet(context, seat, flags)) do
		local r = spots[entry.slot]
		table.insert(out, { action = entry.action, slot = entry.slot, label = entry.label, x = r.x, y = r.y, w = r.w, h = r.h })
	end
	return out
end

-- The state right now. Settings keeps it current (the match remotes, the character's seat) and the seats'
-- scripts read it through TouchWanted. `flags` carries cook and armed.
PhoneLayout.TouchState = { context = "match", seat = "foot", flags = {} }

-- Whether `action` should have a touch button right now: a touch screen, and the action in the state's set.
function PhoneLayout.TouchWanted(action)
	if not UserInputService.TouchEnabled then
		return false
	end
	local state = PhoneLayout.TouchState
	for _, entry in ipairs(PhoneLayout.TouchSet(state.context, state.seat, state.flags)) do
		if entry.action == action then
			return true, entry.slot
		end
	end
	return false
end

-- Puts a bound action's ContextActionService button on its square in the cluster, at the square's size
-- (FIRE 72, the rest 48 on a phone; ContextActionService makes them all 45). The button is the
-- CoreScript's, made a moment after the bind, so the size is set when it turns up; the position goes
-- through SetPosition at once. Re-placed on a viewport change (a tablet's size follows its short side).
local ContextActionService = game:GetService("ContextActionService")
local placed = {}
local placing = false
local function placeNow(action)
	local wanted, slot = PhoneLayout.TouchWanted(action)
	if not wanted then
		return true
	end
	local camera = workspace.CurrentCamera
	local viewport = camera and camera.ViewportSize or Vector2.new(844, 390)
	local r = PhoneLayout.Rects(viewport)[slot]
	if not r then
		return true
	end
	local ok, button = pcall(ContextActionService.GetButton, ContextActionService, action)
	local size = r.w
	if not (ok and button) then
		-- Not drawn yet: the 45 px button it will be, centred on the square meanwhile.
		size = math.min(45, r.w)
	end
	local x, y = r.x + (r.w - size) / 2, r.y + (r.h - size) / 2
	pcall(ContextActionService.SetPosition, ContextActionService, action, UDim2.new(1, x - viewport.X, 1, y - viewport.Y))
	if ok and button then
		pcall(function()
			button.Size = UDim2.fromOffset(size, size)
		end)
		return true
	end
	return false
end
function PhoneLayout.PlaceTouchButton(action)
	if not UserInputService.TouchEnabled then
		return
	end
	placed[action] = true
	if placeNow(action) then
		return
	end
	task.spawn(function()
		for _ = 1, 20 do
			task.wait(0.1)
			if placeNow(action) then
				return
			end
		end
	end)
	if not placing then
		placing = true
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				for name in pairs(placed) do
					placeNow(name)
				end
			end)
		end
	end
end

-- A centred panel (the menu, the drop screen, the results card) is authored at one size in pixels, and
-- several of them are taller than a phone screen: the menu's 760x480 hangs 90 px off a 390-tall screen
-- and the drop screen's 480x536 loses its map and its CONFIRM row. This gives the panel a UIScale that
-- keeps it inside the viewport with a margin, and never grows it: on any screen big enough the scale is
-- exactly 1, so nothing changes on a desktop. `natural` is the size the panel is authored at; `inset` is
-- true for a ScreenGui that keeps Roblox's top bar (MenuClient's does, HudClient's does not).
-- Returns the function it connected, so a caller can re-fit after changing the panel.
-- The scale on its own, so it can be checked without a screen: 1 whenever the panel already fits.
function PhoneLayout.PanelScale(natural, viewport, options)
	options = options or {}
	local margin = options.margin or 16
	local inset = options.inset and (options.insetY or GuiService:GetGuiInset().Y) or 0
	local room = Vector2.new(viewport.X - 2 * margin, viewport.Y - inset - 2 * margin)
	return math.clamp(math.min(1, room.X / math.max(natural.X, 1), room.Y / math.max(natural.Y, 1)), 0.2, 1)
end

function PhoneLayout.FitPanel(panel, natural, options)
	options = options or {}
	local scaleObject = panel:FindFirstChildOfClass("UIScale")
	if not scaleObject then
		scaleObject = Instance.new("UIScale")
		scaleObject.Parent = panel
	end
	local camera = workspace.CurrentCamera
	local function fit()
		local viewport = camera and camera.ViewportSize or Vector2.new(1920, 1080)
		scaleObject.Scale = PhoneLayout.PanelScale(natural, viewport, options)
	end
	fit()
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	end
	return fit
end

-- Puts `instance` in `spot`, scaling it by `scaleObject` so that its natural width fills the rect. The
-- element keeps its own drawing: only where it sits and how big it is change. Returns the scale used.
-- `fit` also holds it inside the rect's height; leave it off for a frame that is a container taller than
-- what it draws (the kill feed's box is 200 tall and holds two 18-pixel lines).
function PhoneLayout.Place(instance, spot, natural, scaleObject, insetY, fit)
	if not (instance and spot and natural and scaleObject) then
		return 1
	end
	local scale = math.max(spot.w / math.max(natural.X, 1), 0.05)
	if fit and natural.Y * scale > spot.h + 0.5 then
		scale = spot.h / math.max(natural.Y, 1)
	end
	scaleObject.Scale = scale
	instance.AnchorPoint = Vector2.new(0, 0)
	instance.Position = UDim2.fromOffset(spot.x, spot.y - (insetY or 0))
	return scale
end

return PhoneLayout
