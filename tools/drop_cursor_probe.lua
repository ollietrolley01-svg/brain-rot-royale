-- Does the drop-location picker free the mouse? (Oliver: "my mouse gets locked up on the drop
-- location checker too".)
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/drop_cursor_probe.lua
--
-- WHAT THIS CAN AND CANNOT PROVE, said plainly:
--
-- The MECHANISM is already proven elsewhere. tools/menu_cursor_probe.client.lua runs in a real
-- client, with a first-person camera relocking the mouse every frame and a competing camera writer,
-- and shows that a visible `Modal` GuiButton frees the cursor and that hiding it hands the lock
-- back. That is the engine behaviour this fix relies on and it does not need proving twice.
--
-- What was missing on the drop picker was the WIRING: the window had no modal overlay at all. This
-- checks the wiring in the built place's own source, and plants a fault to show the check can fail.
-- A server-side runtest has no cursor and no camera, so a picture of it would prove nothing;
-- Oliver's own mouse is the final word.
--
-- THE STRONGER CHECK IS THE GALLERY'S. tools/vote_drop_gallery.lua's `cursor` view builds a real
-- picker, reads `Modal`, `Size` and `Visible` off the real instance, counts the MenuOpen handover
-- both ways, and builds a second picker without an overlay that must fail the same checks. This
-- probe exists because a runtest can run in a build where no gallery has been run, and because the
-- wiring it reads — the LocalScript that owns the player attribute — is not something a gallery can
-- exercise: a module a gallery renders has no Player to set attributes on.

local StarterPlayer = game:GetService("StarterPlayer")

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

local scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local function sourceOf(name)
	local instance = scripts:FindFirstChild(name)
	return instance and instance.Source or ""
end

local picker = sourceOf("DropPicker")
local client = sourceOf("VoteDropClient")
check(picker ~= "", "DropPicker is in the place")
check(client ~= "", "VoteDropClient is in the place")

-- The overlay exists, is a button, and is modal. All three matter: a Frame would dim the screen and
-- free nothing, and a button without Modal is just a click target.
local from = string.find(picker, 'Name = "DropSelectOverlay"', 1, true)
local block = from and string.sub(picker, from - 400, from + 600) or ""
check(from ~= nil, "the picker builds an overlay of its own")
check(string.find(block, "TextButton", 1, true) ~= nil, "the overlay is a GuiButton, not a Frame")
check(string.find(block, "Modal = true", 1, true) ~= nil,
	"the overlay is Modal -- this is the line that frees the cursor")

-- It follows the window, both ways. An overlay that goes up and never comes down would leave the
-- cursor free for the whole match, which is the same bug pointing the other way.
check(string.find(picker, "self.modal.Visible = visible", 1, true) ~= nil,
	"the overlay's visibility follows the picker exactly")
check(string.find(picker, "self.menuOpenHeld = true", 1, true) ~= nil
	and string.find(picker, "self.menuOpenHeld = false", 1, true) ~= nil,
	"the picker claims MenuOpen once and releases it once")
check(string.find(client, 'player:SetAttribute("MenuOpen", open)', 1, true) ~= nil,
	"VoteDropClient writes the attribute CombatClient reads, so a click on the map does not fire the gun")

-- PLANTED FAULT, every run: the same checks against a copy of the source with `Modal = true`
-- removed must FAIL. Without this, a check that had stopped matching anything at all would report a
-- clean pass forever.
local planted = string.gsub(block, "Modal = true", "Modal = false")
check(string.find(planted, "Modal = true", 1, true) == nil,
	"planted fault: with Modal removed the overlay check fails, so the check is reading the real line")

-- And the screen this one replaced is genuinely stood down, not drawing underneath it.
local hud = sourceOf("HudClient")
check(hud == "" or string.find(hud, "local active = false", 1, true) ~= nil,
	"HudClient's old drop screen is stood down, so there is only one picker on screen")
check(hud == "" or string.find(hud, "votePanel.Visible = false", 1, true) ~= nil,
	"HudClient's old vote panel is stood down, so there is only one vote screen on screen")

out("done: %d failures", failures)
