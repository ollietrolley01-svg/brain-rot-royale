-- HUD overlap audit (Oliver's #80/#86: "go over everything diligently and make sure the hud has
-- no buttons or parts that overlap eachother" / "make sure everything fits in its spot and isn't
-- too overcrowded"). Walks every visible HUD element with every state forced on at once, computes
-- its absolute pixel rectangle, and reports every intersecting pair with the overlap in pixels, at
-- the three owner viewports: 1920x1080, 844x390, 375x667.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/hud_overlap_probe.lua [-PlaceFile <rbxlx>]
--
-- WHY A NEW TOOL rather than tools/menu_hud_audit.py, which already does static overlap-by-rect
-- analysis: that tool reads ONLY HudClient.client.lua's own top-level `screenGui`. ControlsHint and
-- ModeScoreHud each build their OWN separate ScreenGui and were never in its FILES/clusters scan;
-- the companion ability tile's frame is built in CompanionAbilityIcon.lua from a formula, not a
-- literal in HudClient, so it was never picked up either; and MenuClient's quest tracker (the
-- LeftStack MenuStackToggle owns) lives in a different file and a different ScreenGui entirely.
-- That is almost certainly why the quests-panel/ControlsHint clash Oliver reported reached him
-- uncaught: the check that should have caught it could not see either participant. This tool
-- covers all of them, plus the phone/portrait layout (via the real PhoneLayout module, not a
-- hand reimplementation of its math) which the static tool doesn't attempt at all.
--
-- SOURCE OF THE NUMBERS. Two kinds:
--  (a) 1920x1080: every element's AnchorPoint/Position/Size is desktop-fixed, transcribed here
--      from its create({...}) call, cited by file:line. A change to one of those literals is a
--      prompt to re-check the transcription here.
--  (b) 844x390 / 375x667: PhoneLayout owns the whole HUD's layout there, so instead of
--      transcribing its ~300 lines of iterative fitting math a second time (and risking it drift
--      out of sync), this REQUIRES the real PhoneLayout module and calls its real Rects()/Place()
--      functions -- the exact numbers the game itself uses. Only the "how each piece maps onto a
--      Rects() slot" glue (HudClient.client.lua:2776-3065's PIECES/CENTRED tables and their scale
--      rules) is transcribed, because that glue is what's being audited.
--
-- COORDINATE FRAMES. HudClient's ScreenGui has IgnoreGuiInset = true (origin at the true top-left
-- corner of the screen). MenuClient's does not (PhoneLayout.lua's own comment), so its quest
-- tracker's Y is measured from below Roblox's own top bar. GuiService:GetGuiInset().Y is added to
-- every MenuClient-space rect below so both sets compare in one frame.
--
-- MUTUALLY EXCLUSIVE BY DESIGN, not bugs: the storm timer and the ModeScoreHud (TDM/KOTH) scoreline
-- share one screen slot on purpose (ModeScoreHud.client.lua:14-17 says so outright -- a battle
-- royale has a storm and no team score, a team mode has a score and no storm, never both at once),
-- and the crosshair/hitmarker overlap the damage-direction arrow on purpose (both mark the aim
-- point). Both pairs are excluded the same way tools/menu_hud_audit.py already excludes its own
-- CENTRE_STACK group, for the same reason.
--
-- PLANTED FAULT (permanent, per the project's proof-bar rule): a synthetic element is placed
-- exactly on the minimap at every viewport. It must appear in the overlap list every run; the probe
-- fails outright if it doesn't, because a check that can't fail proves nothing.

local GuiService = game:GetService("GuiService")
local StarterPlayer = game:GetService("StarterPlayer")
local Scripts = StarterPlayer.StarterPlayerScripts
local ok_ps, PhoneLayout = pcall(require, Scripts:WaitForChild("PhoneLayout"))
assert(ok_ps, "PhoneLayout didn't load: " .. tostring(PhoneLayout))
-- UiKit.panelSize/safeArea are the REAL functions MenuShell.lua:127-166 uses to size and place the
-- menu panel -- required live rather than hand-transcribed a second time, per the rule from the
-- Studio-launch fix tab: never pass an assumption into a geometry check.
local ok_uk, UiKit = pcall(require, Scripts:WaitForChild("UiKit"))
assert(ok_uk, "UiKit didn't load: " .. tostring(UiKit))

local INSET = GuiService:GetGuiInset().Y

-- `force` matches PhoneLayout.Force, the module's own test hook ("the probe and the gallery set
-- it; nothing in the game does" -- PhoneLayout.lua:33-35). Needed because PhoneLayout.Mode()
-- otherwise decides from UserInputService.TouchEnabled, which reads false in a server-Run probe
-- with no real input device -- without forcing it, every viewport would silently test as desktop.
local VIEWPORTS = {
	{ name = "1920x1080", x = 1920, y = 1080, force = nil },
	{ name = "844x390", x = 844, y = 390, force = "handheld" },
	{ name = "375x667", x = 375, y = 667, force = "upright" },
}

-- Resolves an {anchorX, anchorY}, {posSX, posOX, posSY, posOY}, {sizeSX, sizeOX, sizeSY, sizeOY}
-- triple (exactly what a UDim2 literal carries) into an absolute {x, y, w, h} rectangle, the same
-- arithmetic Roblox itself uses (menu_hud_audit.py's `rect()` does the identical sum).
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

-- PhoneLayout.Place's own formula (PhoneLayout.lua:388-400), applied to a rectangle instead of a
-- live Instance: natural size scaled to the slot's width, and (when `fit`) capped to the slot's
-- height too, top-left anchored at the slot.
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

-- Every element on HudClient's own ScreenGui, desktop literals as authored (file:line cited).
local DESKTOP = {
	{ name = "Event banner", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 10 }, size = { 0, 440, 0, 56 }, cite = "HudClient.client.lua:62-70" },
	{ name = "Crosshair", anchor = { 0.5, 0.5 }, pos = { 0.5, 0, 0.5, 0 }, size = { 0, 64, 0, 64 }, cite = "HudClient.client.lua:273-280", group = "centre" },
	{ name = "Health panel", anchor = { 0, 0 }, pos = { 0, 16, 1, -96 }, size = { 0, 280, 0, 80 }, cite = "HudClient.client.lua:794-802" },
	{ name = "Companion status", anchor = { 0, 0 }, pos = { 0, 16, 1, -166 }, size = { 0, 300, 0, 62 }, cite = "HudClient.client.lua:884-892" },
	{ name = "Speed boost pill", anchor = { 0, 0 }, pos = { 0, 16, 1, -202 }, size = { 0, 150, 0, 28 }, cite = "HudClient.client.lua:965-975" },
	{ name = "Hotbar (+ammo)", anchor = { 1, 1 }, pos = { 1, -16, 1, -16 }, size = { 0, 690, 0, 150 }, cite = "HudClient.client.lua:1092-1101" },
	{ name = "Use/interact prompt", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0.6, 0 }, size = { 0, 250, 0, 46 }, cite = "HudClient.client.lua:1379-1388" },
	{ name = "Storm timer", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 72 }, size = { 0, 440, 0, 24 }, cite = "HudClient.client.lua:1788-1797", group = "stormSlot" },
	{ name = "Minimap", anchor = { 1, 0 }, pos = { 1, -16, 0, 108 }, size = { 0, 190, 0, 190 }, cite = "HudClient.client.lua:1822-1830" },
	{ name = "Bounty label", anchor = { 1, 0 }, pos = { 1, -16, 0, 304 }, size = { 0, 230, 0, 22 }, cite = "HudClient.client.lua:2140-2150 (108+MAP_PX+6)" },
	{ name = "Compass", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 100 }, size = { 0, 440, 0, 24 }, cite = "HudClient.client.lua:2292-2300" },
	{ name = "Location label", anchor = { 1, 0 }, pos = { 1, -16, 0, 332 }, size = { 0, 230, 0, 20 }, cite = "HudClient.client.lua:2484-2492 (108+MAP_PX+34)" },
	{ name = "Kill feed", anchor = { 1, 0 }, pos = { 1, -16, 0, 312 }, size = { 0, 300, 0, 200 }, cite = "HudClient.client.lua:2631-2638" },
	{ name = "Toast", anchor = { 0.5, 1 }, pos = { 0.5, 0, 1, -120 }, size = { 0, 460, 0, 36 }, cite = "HudClient.client.lua:2686-2696" },
	{ name = "Drop pickup banner", anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 128 }, size = { 0, 480, 0, 30 }, cite = "HudClient.client.lua:546-554" },
	-- The damage-direction arc is dynamic (angle depends on the shot), always screen-centre anchored
	-- with a 170 px radial offset; "straight up" (attacker directly ahead) is the representative
	-- sample used here, the orientation most likely to interact with the top-centre cluster.
	{ name = "Damage indicator (sample: from ahead)", anchor = { 0.5, 0.5 }, pos = { 0.5, 0, 0.5, -170 }, size = { 0, 4, 0, 150 }, cite = "HudClient.client.lua:764-773", group = "centre" },
}

-- ModeScoreHud.client.lua's own ScreenGui ("Scoreline"), desktop literal.
local MODE_SCORE = { anchor = { 0.5, 0 }, pos = { 0.5, 0, 0, 72 }, size = { 0, 420, 0, 44 }, cite = "ModeScoreHud.client.lua:44-54", group = "stormSlot" }

-- ControlsHint.client.lua's own ScreenGui: root (open) and pill (collapsed) are mutually exclusive,
-- so the OPEN panel is used here as the more overlap-prone representative state. Desktop position
-- formula: gutter right of the bottom-left stack when it fits, else the old fallback spot -- off
-- STACK_RIGHT (316, the companion panel's edge, the widest of the stack), not HEALTH_RIGHT (296,
-- the health panel alone): this probe caught the gutter starting 8 px inside the companion panel
-- before UiKit.BottomRow.StackRight existed to fix it.
local CONTROLS_HINT_WIDTH, CONTROLS_HINT_ROW, CONTROLS_HINT_ROWS = 228, 22, 8
local CONTROLS_HINT_HEADER = 44
local STACK_RIGHT, LEFT_STACK_TOP, HOTBAR_INSET, ROW_GAP = 316, 202, 706, 12 -- UiKit.lua BottomRow

local function controlsHintDesktopRect(vw)
	local height = CONTROLS_HINT_HEADER + CONTROLS_HINT_ROW * CONTROLS_HINT_ROWS + 8
	local gutterX = STACK_RIGHT + ROW_GAP
	local fits = (vw.x - HOTBAR_INSET) - gutterX - ROW_GAP >= CONTROLS_HINT_WIDTH
	local x = fits and gutterX or 16
	local y = fits and ROW_GAP or (LEFT_STACK_TOP + ROW_GAP)
	return offsetRect(x, vw.y - y - height, CONTROLS_HINT_WIDTH, height)
end

-- Landscape/handheld phone: anchored off PhoneLayout's own controlsHint icon (added alongside
-- menu/stackTab/cam -- PhoneLayout.lua's Rects()), growing down-left from its bottom-right corner
-- so it never climbs back into the icon row or the banner above it. Portrait/upright has no slot
-- (spots.controlsHint is nil there) -- ControlsHint.client.lua hides it entirely on that shape.
local function controlsHintPhoneRect(spot)
	if not spot then
		return nil
	end
	local TOUCH_ROWS_COUNT = 2
	local height = CONTROLS_HINT_HEADER + CONTROLS_HINT_ROW * TOUCH_ROWS_COUNT + 8
	return offsetRect(spot.x1 - CONTROLS_HINT_WIDTH, spot.y1 + 6, CONTROLS_HINT_WIDTH, height)
end

-- The menu panel (MenuShell.lua), sourced live from the SAME UiKit functions MenuShell itself
-- calls (MenuShell.lua:127-141): natural size, then centred with the top/bottom safe-area nudge.
-- `touch` matches what MenuClient passes for the two phone viewports. Oliver's screenshot: the
-- ControlsHint pill sat across this panel's own bottom edge -- a HUD element and a menu element
-- neither audit could see at once, since one lived in each file's own scan.
local function menuPanelRect(vw, touch)
	local viewport = Vector2.new(vw.x, vw.y)
	local size = UiKit.panelSize(viewport, touch)
	local safe = UiKit.safeArea(viewport, touch)
	local cy = vw.y / 2 + math.floor((safe.Top - safe.Bottom) / 2)
	-- MenuClient's ScreenGui does not ignore the inset (PhoneLayout.lua's own comment); INSET
	-- lands this in HudClient's frame the same way the quest tracker's rect does above.
	return offsetRect(vw.x / 2 - size.X / 2, cy - size.Y / 2 + INSET, size.X, size.Y)
end

-- CompanionAbilityIcon.lua's static formula (desktop) and its readout label above-right of it.
local ABILITY_SIZE = 72
local function abilityTileRect(vw)
	local x = vw.x - (HOTBAR_INSET + ROW_GAP) - ABILITY_SIZE
	local y = vw.y - 16 - ABILITY_SIZE
	return offsetRect(x, y, ABILITY_SIZE, ABILITY_SIZE)
end
local function abilityReadoutRect(tileRect)
	-- Readout: AnchorPoint(1,1), Position (1, 0, 0, -6), Size (230, 32) inside the tile's own frame.
	return offsetRect(tileRect.x + tileRect.w - 230, tileRect.y - 6 - 32, 230, 32)
end

-- MenuClient's quest tracker / menu stack (MenuStackToggle.lua). Its LeftStack container holds the
-- MENU button, the bundle nudge AND the quest tracker together (MenuClient.client.lua:3629's
-- `items = { menuButton, bundleNudge, tracker }`), so this one box covers all three. MenuClient's
-- ScreenGui does NOT ignore the inset, so INSET is added back to land in HudClient's frame.
local STACK_TOP, STACK_W, STACK_H = 124, 300, 460
local function questTrackerRect(vw)
	return offsetRect(0, STACK_TOP + INSET, STACK_W, STACK_H)
end

-- Planted fault: parked exactly on the minimap. Must be reported every run.
local function plantedFaultRect(vw)
	local mm = udimRect({ 1, 0 }, { 1, -16, 0, 108 }, { 0, 190, 0, 190 }, vw)
	return offsetRect(mm.x + 20, mm.y + 20, 60, 60)
end

-- Builds the full element list for one viewport and one game state: desktop literals under
-- 1920x1080, PhoneLayout's real Rects()/Place() under the two phone sizes. `menuOpen` swaps in the
-- MenuClient state: the menu panel is added, and ControlsHint + the ability tile are left OUT
-- because that is what they now do when MenuOpen fires (ControlsHint.client.lua's apply(),
-- HudClient.client.lua's ability-tile hidden param) -- their absence here IS the fix, not a gap in
-- the audit; the "OLD, pre-fix" demo entries below prove what used to happen instead.
local function buildElements(vw, menuOpen)
	local elements = {}
	local function add(name, r, group)
		if r then
			table.insert(elements, { name = name, r = r, group = group })
		end
	end

	PhoneLayout.Force = vw.force
	local phone = vw.force ~= nil
	local touch = phone -- PhoneLayout.Active and MenuShell's own `touch` agree at these two sizes.

	if menuOpen then
		add("Menu panel", menuPanelRect(vw, touch))
	end

	if not phone then
		for _, d in ipairs(DESKTOP) do
			add(d.name, udimRect(d.anchor, d.pos, d.size, vw), d.group)
		end
		add("Mode score HUD (TDM/KOTH)", udimRect(MODE_SCORE.anchor, MODE_SCORE.pos, MODE_SCORE.size, vw), MODE_SCORE.group)
		if not menuOpen then
			add("Controls hint (open)", controlsHintDesktopRect(vw))
			local tile = abilityTileRect(vw)
			add("Companion ability tile", tile)
			add("Companion ability readout", abilityReadoutRect(tile))
		else
			add("Controls hint [OLD, would have shown pre-fix]", controlsHintDesktopRect(vw), "preFixDemo")
			add("Companion ability tile [OLD, would have shown pre-fix]", abilityTileRect(vw), "preFixDemo")
		end
		add("Quest tracker / menu stack", questTrackerRect(vw))
	else
		local spots = PhoneLayout.Rects(Vector2.new(vw.x, vw.y))
		add("Event banner", placeRect(spots.banner, { 440, 56 }, true))
		add("Storm timer", placeRect(spots.stormLine, { 440, 24 }, true), "stormSlot")
		add("Mode score HUD (TDM/KOTH)", placeRect(spots.stormLine, { 420, 44 }, true), "stormSlot")
		add("Compass", placeRect(spots.compass, { 440, 24 }, true))
		add("Minimap", placeRect(spots.minimap, { 190, 190 }, true))
		add("Bounty label", placeRect(spots.bounty, { 230, 22 }, true))
		add("Location label", placeRect(spots.location, { 230, 20 }, true))
		add("Kill feed", placeRect(spots.killFeed, { 300, 200 }, false))
		add("Health panel", placeRect(spots.health, { 280, 48 }, true))
		add("Speed boost pill", placeRect(spots.speedPill, { 150, 28 }, true))
		add("Companion status", placeRect(spots.companion, { 300, 56 }, true))
		if not menuOpen then
			add("Companion ability tile", placeRect(spots.petIcon, { 72, 72 }, true))
			add("Controls hint", controlsHintPhoneRect(spots.controlsHint))
		else
			add("Companion ability tile [OLD, would have shown pre-fix]", placeRect(spots.petIcon, { 72, 72 }, true), "preFixDemo")
			add("Controls hint [OLD, would have shown pre-fix]", controlsHintPhoneRect(spots.controlsHint), "preFixDemo")
		end
		-- BEFORE/AFTER, in one run: the desktop-formula position nothing moved on a phone before
		-- this fix (the ability tile wasn't in HudClient's PIECES table; ControlsHint never asked
		-- PhoneLayout anything). Always shown, menu open or not, since this demonstrates the PHONE
		-- fix specifically, not the menu one.
		add("Companion ability tile [OLD desktop formula, pre-fix]", abilityTileRect(vw), "preFixDemo")
		add("Controls hint [OLD desktop formula, pre-fix]", controlsHintDesktopRect(vw), "preFixDemo")
		-- CENTRED-style pieces: fixed scale (not spot-width-fitted), centred on X, anchored at spot.y.
		if spots.useBar then
			add("Use/interact prompt", offsetRect(vw.x / 2 - 250 * 0.8 / 2, spots.useBar.y, 250 * 0.8, 46 * 0.8))
		end
		if spots.toast then
			add("Toast", offsetRect(vw.x / 2 - 460 * 0.62 / 2, spots.toast.y, 460 * 0.62, 36 * 0.62))
		end
		add("Drop pickup banner", offsetRect(vw.x / 2 - 480 * 0.62 / 2, 128 * 0.62, 480 * 0.62, 30 * 0.62))
		-- Hotbar: HudClient.client.lua:2854-2918's setHotbarShape, no-slots screens fall back to the
		-- Inventory button alone.
		local hbSpot = spots.hotbar
		if hbSpot then
			-- HudClient.client.lua:2854-2918 setHotbarShape: landscape has no hotbarSlots key (nil ->
			-- 4 columns, 2 rows); portrait sets it to the number of slots that fit (1 row) or 0 (no row
			-- at all, handled below by falling back to spots.inventory).
			local pad = 6
			local columns = (spots.hotbarSlots and spots.hotbarSlots > 0) and math.min(spots.hotbarSlots, 4) or 4
			local rows = (spots.hotbarSlots and spots.hotbarSlots > 0) and 1 or 2
			local naturalW = columns * 78 + (columns - 1) * 6 + 2 * pad
			local naturalH = rows * 64 + (rows - 1) * 6 + 2 * pad
			local scale = hbSpot.w / (naturalW - 2 * pad)
			add("Hotbar (+ammo)", offsetRect(hbSpot.x1 - naturalW * scale, hbSpot.y1 - naturalH * scale, naturalW * scale, naturalH * scale))
		elseif spots.inventory then
			add("Hotbar (+ammo, Inventory button only)", offsetRect(spots.inventory.x, spots.inventory.y, spots.inventory.w, spots.inventory.h))
		end
		if spots.ready then
			add("Ready pill", offsetRect(spots.ready.x, spots.ready.y, spots.ready.w, 60 * spots.ready.w / 230))
		end
		-- Quest tracker: MenuStackToggle:SetPhone's phoneStack formula (MenuStackToggle.lua:231-247),
		-- `first` (the topmost visible item's own offset) assumed 0 -- a representative case.
		if spots.stackTab then
			add("Quest tracker / menu stack", offsetRect(spots.stackTab.x + spots.stackTab.w - STACK_W * 0.8, spots.stackTab.y1 + 6, STACK_W * 0.8, STACK_H * 0.8))
			add("Stack toggle tab", offsetRect(spots.stackTab.x, spots.stackTab.y, spots.stackTab.w, spots.stackTab.h))
		end
		if spots.menu then
			add("Menu icon", offsetRect(spots.menu.x, spots.menu.y, spots.menu.w, spots.menu.h))
		end
		if spots.cam then
			add("Camera toggle icon", offsetRect(spots.cam.x, spots.cam.y, spots.cam.w, spots.cam.h))
		end
		-- Crosshair and the damage indicator stay screen-centre anchored on every viewport (no
		-- PhoneLayout entry moves them).
		add("Crosshair", udimRect({ 0.5, 0.5 }, { 0.5, 0, 0.5, 0 }, { 0, 64, 0, 64 }, vw), "centre")
		add("Damage indicator (sample: from ahead)", udimRect({ 0.5, 0.5 }, { 0.5, 0, 0.5, -170 }, { 0, 4, 0, 150 }, vw), "centre")
		-- Roblox's own reserved zones: nothing of ours may sit in them.
		for _, key in ipairs({ "jump", "stick", "fire", "aim", "reload", "run", "pet", "slide", "move" }) do
			local s = spots[key]
			if s then
				add("Reserved (Roblox/TouchControls): " .. key, offsetRect(s.x, s.y, s.w, s.h), "reserved")
			end
		end
	end

	add("PLANTED FAULT (must be reported)", plantedFaultRect(vw), "fault")
	return elements
end

-- Exclusions: same-group pairs that are either the SAME visual cluster on purpose (screen-centre
-- reticle group) or two states that can never both be on screen at once (the shared storm/score
-- slot). Reserved Roblox zones are checked against real HUD elements but not against each other.
local EXCLUDE_GROUPS = { centre = true, stormSlot = true }

-- Two passes per viewport: the ordinary HUD (menu closed) and the menu-open state the coordinator
-- asked to add (Oliver's screenshot: the controls pill sitting across the menu panel's bottom
-- edge). Each pass runs in ITS OWN pcall, geometry computed first, so a failure in one viewport or
-- one state can't take out the measurements that were the point of the run -- the rule from the
-- tab that found VirtualInputManager blocked mid-probe.
local totalPairs, totalElements, totalRuns = 0, 0, 0
local faultSeen = {}
local reportLines = {}
local hardFailures = {}

local PASSES = { { menuOpen = false, label = "HUD" }, { menuOpen = true, label = "menu open" } }

for _, vw in ipairs(VIEWPORTS) do
	for _, pass in ipairs(PASSES) do
		local passKey = vw.name .. " / " .. pass.label
		local ok, err = pcall(function()
			-- Geometry first: every rectangle is computed before any pairwise check runs, so a
			-- crash here still leaves nothing half-measured to misreport.
			local elements = buildElements(vw, pass.menuOpen)

			local liveCount = 0
			for _, e in ipairs(elements) do
				if e.group ~= "preFixDemo" then
					liveCount += 1
				end
			end

			local pairs_found, demo_pairs = {}, {}
			local faultHit = false
			for i = 1, #elements do
				for j = i + 1, #elements do
					local a, b = elements[i], elements[j]
					local bothReserved = a.group == "reserved" and b.group == "reserved"
					local sameExcludedGroup = a.group and a.group == b.group and EXCLUDE_GROUPS[a.group]
					if not bothReserved and not sameExcludedGroup then
						local ox = math.min(a.r.x + a.r.w, b.r.x + b.r.w) - math.max(a.r.x, b.r.x)
						local oy = math.min(a.r.y + a.r.h, b.r.y + b.r.h) - math.max(a.r.y, b.r.y)
						if ox > 0 and oy > 0 then
							local isDemo = a.group == "preFixDemo" or b.group == "preFixDemo"
							table.insert(isDemo and demo_pairs or pairs_found, { a.name, b.name, math.floor(ox), math.floor(oy) })
							if a.name:find("PLANTED FAULT") or b.name:find("PLANTED FAULT") then
								faultHit = true
							end
						end
					end
				end
			end

			totalElements += liveCount
			totalPairs += #pairs_found
			totalRuns += 1
			faultSeen[passKey] = faultHit
			table.insert(reportLines, string.format("[HUD_OVERLAP] %s: %d elements, %d overlapping pairs", passKey, liveCount, #pairs_found))
			for _, p in ipairs(pairs_found) do
				table.insert(reportLines, string.format("[HUD_OVERLAP]   %s over %s by %dx%d px", p[1], p[2], p[3], p[4]))
			end
			for _, p in ipairs(demo_pairs) do
				table.insert(reportLines, string.format("[HUD_OVERLAP]   [historical, fixed] %s over %s by %dx%d px", p[1], p[2], p[3], p[4]))
			end
		end)
		if not ok then
			table.insert(hardFailures, passKey .. ": " .. tostring(err))
		end
	end
end

for _, line in ipairs(reportLines) do
	print(line)
end
print(string.format("[HUD_OVERLAP] TOTAL sample counts: %d elements checked across %d viewport/state passes, %d overlapping pairs",
	totalElements, totalRuns, totalPairs))

for _, failure in ipairs(hardFailures) do
	warn("[HUD_OVERLAP] PASS CRASHED: " .. failure)
end
assert(#hardFailures == 0, string.format("[HUD_OVERLAP] %d of %d passes crashed before they could be measured", #hardFailures, #VIEWPORTS * #PASSES))

for _, vw in ipairs(VIEWPORTS) do
	for _, pass in ipairs(PASSES) do
		local passKey = vw.name .. " / " .. pass.label
		assert(faultSeen[passKey], "[HUD_OVERLAP] planted fault NOT reported at " .. passKey .. " -- the checker is blind")
	end
end
print(string.format("[HUD_OVERLAP] planted fault reported at all %d viewport/state passes (checker proven able to fail)", #VIEWPORTS * #PASSES))
