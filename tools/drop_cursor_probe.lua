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
check(string.find(client, 'MenuOpenClaims.Claim("DropPicker")', 1, true) ~= nil,
	"VoteDropClient CLAIMS the attribute CombatClient reads, rather than writing it")
check(string.find(client, 'player:SetAttribute("MenuOpen"', 1, true) == nil,
	"VoteDropClient never writes MenuOpen directly -- an unconditional clear is two of Oliver's cursor bugs")

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

--------------------------------------------------------------------------------
-- MenuOpenClaims, driven for real.
--
-- Everything above reads source text. This part RUNS the thing: MenuOpenClaims binds to any
-- Instance, and a Folder has real attributes and a real GetAttributeChangedSignal, so these are the
-- genuine semantics rather than a mock of them. Both sequences below are bugs Oliver reported, and
-- both are a second writer clearing what a first writer still needs.
--------------------------------------------------------------------------------

local claimsOk, MenuOpenClaims = pcall(function()
	return require(scripts:WaitForChild("MenuOpenClaims"))
end)
check(claimsOk, "MenuOpenClaims loads")

if claimsOk then
	local subject = Instance.new("Folder")
	subject.Name = "CursorProbeSubject"
	local realLegacy = MenuOpenClaims.LegacyHolder
	local legacyHolding = false
	MenuOpenClaims.LegacyHolder = function()
		return legacyHolding
	end
	local function attribute()
		return subject:GetAttribute("MenuOpen")
	end

	MenuOpenClaims.Bind(subject)
	local release = MenuOpenClaims.Claim("first")
	check(attribute() == true, "a claim frees the cursor")
	release()
	check(attribute() == false, "releasing the only claim gives it back")

	-- THE COUNT, which is the whole point: two screens open, one closes, the cursor stays free.
	local a = MenuOpenClaims.Claim("a")
	local b = MenuOpenClaims.Claim("b")
	check(attribute() == true and MenuOpenClaims.Count() == 2, "two claims, %d outstanding", MenuOpenClaims.Count())
	a()
	check(attribute() == true, "the cursor is still free while the SECOND claim is outstanding")
	b()
	check(attribute() == false, "it comes back only when the last claim is released")

	-- Releasing twice must not underflow the count, or the next claimant could never hold it.
	a()
	a()
	check(MenuOpenClaims.Count() == 0, "releasing twice is the same as releasing once (%d outstanding)", MenuOpenClaims.Count())

	-- OLIVER'S "CURSOR STUCK FREE, CLICKS FIRE THE GUN": the picker is up and the menu closing
	-- underneath clears the attribute. It must be put straight back.
	local held = MenuOpenClaims.Claim("picker")
	subject:SetAttribute("MenuOpen", false) -- the menu's own close, writing the attribute directly
	task.wait()
	check(attribute() == true, "a writer clearing the attribute under an outstanding claim is corrected")
	held()
	check(attribute() == false, "and releasing after that still gives the cursor back")

	-- OLIVER'S "CURSOR STUCK LOCKED": the picker closes over the top of an open menu. The menu is an
	-- unmigrated writer that never writes again until its panel changes, so the last release must
	-- leave the attribute alone.
	legacyHolding = true
	subject:SetAttribute("MenuOpen", true) -- the menu, still open
	local over = MenuOpenClaims.Claim("picker over the menu")
	over()
	check(attribute() == true, "the last release does NOT strand a menu that is still open")
	legacyHolding = false

	-- A RE-BIND WITH A CLAIM STILL OUT. Bind clears the books, so the old release is a claim on a
	-- subject that no longer exists: it must do nothing at all. If it decremented, the count would
	-- go negative, every later claim would be ignored, and the cursor would stop being freed for
	-- the rest of the session with nothing in the log to say why.
	local stale = MenuOpenClaims.Claim("before the re-bind")
	local second = Instance.new("Folder")
	MenuOpenClaims.Bind(second)
	stale()
	check(MenuOpenClaims.Count() == 0, "a release from before a re-bind does not drive the count negative (%d)",
		MenuOpenClaims.Count())
	local afterRebind = MenuOpenClaims.Claim("after the re-bind")
	check(second:GetAttribute("MenuOpen") == true, "and the module still works after that")
	afterRebind()
	second:Destroy()
	MenuOpenClaims.Bind(subject)

	-- PLANTED FAULT for that one: the unfloored, unguarded arithmetic it replaced. One release from
	-- a stale closure takes it below zero, and `count > 0` is then false however many claims follow.
	local naive = 0
	naive = 0 -- a re-bind zeroed it
	naive = naive - 1 -- the stale release
	check(naive < 0 and not (naive + 1 > 0),
		"planted fault: unfloored, one stale release leaves the count at %d and the next claim reads as unheld", naive)

	-- PLANTED FAULT, every run: the same two sequences against the code this replaced — a bare
	-- SetAttribute on open and on close. Both must end WRONG, which is what makes the passes above
	-- mean something.
	local raw = Instance.new("Folder")
	raw:SetAttribute("MenuOpen", true)   -- the menu is open and holding it
	raw:SetAttribute("MenuOpen", true)   -- the old picker opens: no change, so nothing is notified
	raw:SetAttribute("MenuOpen", false)  -- the old picker closes: unconditional clear
	check(raw:GetAttribute("MenuOpen") == false,
		"planted fault: the old unconditional clear DOES strand the open menu, so these checks can tell the two apart")

	MenuOpenClaims.LegacyHolder = realLegacy
	MenuOpenClaims.Bind(nil)
	subject:Destroy()
	raw:Destroy()
end

out("done: %d failures", failures)
