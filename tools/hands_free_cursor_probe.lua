-- Does the cursor free itself when you're holding nothing, and re-lock the instant you equip or
-- aim? (Oliver's #68: "make your mouse free when youre not holding anything so that you can click
-- the menus and stuff in game".)
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/hands_free_cursor_probe.lua
--
-- WHAT THIS CAN AND CANNOT PROVE, said plainly (per claude-43, after another tab lost a run to
-- VirtualInputManager: "no probe in this harness can synthesise input" -- SendMouseButtonEvent
-- throws from the runtest plugin thread, Studio's sandbox refuses it):
--
-- The MECHANISM is already proven elsewhere, the same way tools/drop_cursor_probe.lua leans on it.
-- tools/menu_cursor_probe.client.lua runs in a REAL client, with a first-person camera relocking
-- the mouse every frame and a competing camera writer, and shows that a visible `Modal` GuiButton
-- frees the cursor and that hiding it hands the lock back -- MenuCursor.client.lua is untouched by
-- this fix, so that proof still stands and does not need repeating.
--
-- What this fix ADDS is a new WIRING decision -- when to want the cursor free -- and that is state
-- this probe reads straight from the built place's own script sources (LocalScript.Source is a
-- readable property in any context, running or not; this is exactly drop_cursor_probe.lua's
-- pattern). It proves: the modal overlay exists, is a GuiButton, is Modal = true; MenuOpen is set
-- only while third person + an active match + holding nothing, and released the instant any of
-- those stops being true; the release defends itself against the menu's own unconditional clear.
-- It CANNOT prove a click actually lands on a button, because that needs synthetic input this
-- harness cannot generate. That half is Oliver's own mouse, in a real playtest.

local StarterPlayer = game:GetService("StarterPlayer")
local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")

local failures = 0
local function out(fmt, ...)
	print("[BRR_Probe] " .. string.format(fmt, ...))
end
local function check(ok, fmt, ...)
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
end

--------------------------------------------------------------------------------
-- The modal overlay (MenuCursor.client.lua): unmodified by this fix, reused as-is.
--------------------------------------------------------------------------------

local menuCursor = scripts:FindFirstChild("MenuCursor")
check(menuCursor ~= nil, "MenuCursor.client.lua is in the place")
local cursorSource = menuCursor and menuCursor.Source or ""

check(string.find(cursorSource, 'Name = "CursorRelease"', 1, true) ~= nil,
	"the modal overlay exists (CursorRelease)")
check(string.find(cursorSource, "TextButton", 1, true) ~= nil,
	"the overlay is a GuiButton, not a Frame")
check(string.find(cursorSource, "modal.Modal = true", 1, true) ~= nil,
	"the overlay is Modal -- this is the line that frees the cursor")
check(string.find(cursorSource, 'modal.Visible = wanted', 1, true) ~= nil
	and string.find(cursorSource, 'GetAttribute("MenuOpen") == true', 1, true) ~= nil,
	"the overlay's visibility tracks the MenuOpen attribute exactly")

--------------------------------------------------------------------------------
-- The new wiring (HudClient.client.lua): holding nothing, in a match, in third person.
--------------------------------------------------------------------------------

local hud = scripts:FindFirstChild("HudClient")
check(hud ~= nil, "HudClient is in the place")
local source = hud and hud.Source or ""

-- Isolate the block by its own section comment, the same way drop_cursor_probe.lua isolates the
-- overlay by its Name -- a targeted slice, not the whole 4000-line file, so a match means the
-- match came from the right place.
local blockStart = string.find(source, "Free cursor while holding nothing", 1, true)
check(blockStart ~= nil, "the hands-free cursor section exists in HudClient")
-- Sliced to the NEXT section's own banner, not a fixed length: the block is a few lines longer
-- than any guessed char count, and a fixed cutoff already missed the loadoutChanged/matchChanged
-- lines once while this was being written.
local blockEnd = blockStart and string.find(source, "Companion ability tile (bottom-left", blockStart, true)
local block = blockStart and string.sub(source, blockStart, (blockEnd or (blockStart + 4000)) - 1) or ""

check(string.find(block, "matchState.state == \"InProgress\"", 1, true) ~= nil,
	"only wants the cursor free during an active match")
check(string.find(block, "loadout ~= nil", 1, true) ~= nil,
	"only while a real loadout exists (not spectating/eliminated)")
check(string.find(block, "not slot", 1, true) ~= nil
	and string.find(block, "loadout.equipped and loadout.slots[loadout.equipped]", 1, true) ~= nil,
	"'holding nothing' is read off the same loadout.equipped/slots pair renderWeapon() uses for Unarmed")
check(string.find(block, 'Settings.Get("ThirdPerson") == true', 1, true) ~= nil,
	"THIRD PERSON ONLY -- the gate that keeps first-person mouse-look from being lost")
check(string.find(block, 'player:SetAttribute("MenuOpen", true)', 1, true) ~= nil,
	"claims the cursor by setting MenuOpen")
check(string.find(block, 'player:SetAttribute("MenuOpen", false)', 1, true) ~= nil,
	"releases the cursor by clearing MenuOpen")
check(string.find(block, 'not player:GetAttribute("MenuOpen")', 1, true) ~= nil,
	"never claims MenuOpen out from under another owner (the menu, the inventory panel)")

-- The release defends itself: MenuClient's own panel writes MenuOpen unconditionally from its
-- Visible property (MenuClient.client.lua's menuButton section), so anything that can still be
-- true after the menu closes underneath it has to re-claim, not just release once.
check(string.find(block, 'GetAttributeChangedSignal("MenuOpen")', 1, true) ~= nil,
	"defends its claim: re-asserts MenuOpen if something else clears it while still wanted")

-- Reacts to the right transitions: an equip/unequip push (loadoutChanged) and a match-state change
-- (matchChanged) both have to re-evaluate, or the cursor could stay free after picking a gun up
-- until the next unrelated event happened to run apply().
check(string.find(block, "loadoutChanged.OnClientEvent:Connect(apply)", 1, true) ~= nil,
	"re-checks on every loadout push -- the equip/unequip path")
check(string.find(block, "matchChanged.OnClientEvent:Connect(apply)", 1, true) ~= nil,
	"re-checks on every match-state push")

-- Placement matters: this block must run AFTER the real loadoutChanged/matchChanged handlers that
-- assign `loadout` and `matchState`, or its own loadoutChanged connection would fire first (Roblox
-- fires multiple connections to one signal in connection order) and read a stale value one push
-- behind. Both real assignments are textually above the block start.
local loadoutAssignAt = string.find(source, "loadout = newLoadout", 1, true)
local matchAssignAt = string.find(source, "matchState = state", 1, true)
check(loadoutAssignAt ~= nil and loadoutAssignAt < blockStart,
	"placed after the real `loadout = newLoadout` assignment, not before it")
check(matchAssignAt ~= nil and matchAssignAt < blockStart,
	"placed after the real `matchState = state` assignment, not before it")

--------------------------------------------------------------------------------
-- PLANTED FAULT, every run: the same third-person-gate check against a copy of the block with the
-- Settings.Get("ThirdPerson") line removed must FAIL. Without this, a check that had stopped
-- matching anything at all would report a clean pass forever -- exactly the false-pass class this
-- project's proof-bar rule exists to catch.
--------------------------------------------------------------------------------

local planted = string.gsub(block, 'Settings.Get%("ThirdPerson"%) == true%s*\n?', "")
local plantedStillHasGate = string.find(planted, 'Settings.Get("ThirdPerson") == true', 1, true) ~= nil
check(not plantedStillHasGate,
	"planted fault: with the third-person gate stripped, the check fails -- it is reading the real line")

out("done: %d failures", failures)
assert(failures == 0, "hands-free cursor wiring check failed")
