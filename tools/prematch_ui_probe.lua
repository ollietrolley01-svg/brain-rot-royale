-- The truth tables for the pre-match UI's cursor and reveal decisions, with four planted faults.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/prematch_ui_probe.lua
--
-- Oliver's #100 ("my mouse doesn't unlock anymore when vote menus pull up") and #107 ("sometimes game
-- choosing menu pulls up randomly mid match") are ONE incident. #107 puts the vote screen on top of a
-- running match; a running match holds the cursor with CameraMode.LockFirstPerson; and the vote
-- screen could not free it, because its own visibility predicate required MenuOpen to be FALSE while
-- MenuOpen was the only thing that frees the mouse. The two sets never intersected.
--
-- THREE SECTIONS, EACH IN ITS OWN pcall, so one failure cannot take the other tables' numbers with
-- it. Every planted fault is aimed at an INVARIANT, not at "the broken thing is still broken" — a
-- plant written against a bug dies the day the bug is fixed and leaves a check that proves nothing.
-- Each plant SAYS whether it fired; a plant that did not fire is reported as a dead check.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local VoteCursor = require(Shared:WaitForChild("VoteCursor"))
local VoteReveal = require(Shared:WaitForChild("VoteReveal"))

local function say(fmt, ...)
	print("[BRR_PreMatchUi] " .. string.format(fmt, ...))
end

local totalFailures = 0

--------------------------------------------------------------------------------
-- 1. VoteReveal.ShouldReveal -- #107
--------------------------------------------------------------------------------

local okReveal, revealErr = pcall(function()
	local OPEN = { open = true }
	local CLOSED = { open = false, winner = "BattleRoyale|Dust" }
	local CLOSED_OTHER = { open = false, winner = "TeamDeathmatch|Rift" }
	local CANCELLED = { open = false }

	-- previous, next, expected, what it is
	local CASES = {
		{ OPEN, CLOSED, true, "THE ONE REAL REVEAL: the countdown ran out on a winner" },
		{ CLOSED, CLOSED, false, "THE MID-MATCH JOIN RE-BROADCAST -- #107" },
		{ CLOSED, CLOSED_OTHER, false, "a later snapshot naming a different winner is still not a close we watched" },
		{ OPEN, OPEN, false, "the vote is still open" },
		{ CLOSED, OPEN, false, "the NEXT vote opening is not a reveal" },
		{ OPEN, CANCELLED, false, "everyone unreadied: closed with no winner" },
		{ CANCELLED, CANCELLED, false, "a repeat of a cancelled countdown" },
		{ nil, CLOSED, false, "joining mid-match: history, not a transition we saw" },
		{ nil, OPEN, false, "joining mid-countdown" },
		{ OPEN, { winner = "BattleRoyale|Dust" }, true, "a closed snapshot with `open` omitted" },
		{ OPEN, nil, false, "a nil payload" },
		{ OPEN, "not a table", false, "a payload that is not a table at all" },
		{ "not a table", CLOSED, false, "a previous that is not a table" },
	}

	-- THE BUG ITSELF. The rule this replaced tested the CONTENT of a snapshot, not a change.
	-- INVARIANT: a snapshot identical to the one we already hold never starts a reveal.
	local function oldContentRule(_, next)
		return type(next) == "table" and next.winner ~= nil and next.open ~= true
	end
	-- THE MIRROR, and the more dangerous direction: a rule that drops a GENUINE close.
	-- INVARIANT: every close we watched starts exactly one reveal, including the first of the session.
	local function missesTheFirstRule(previous, next)
		if type(next) ~= "table" or type(previous) ~= "table" then
			return false
		end
		return previous.open == true and next.open ~= true and next.winner ~= nil and previous.winner ~= nil
	end

	local failures, oldFired, mirrorFired = 0, 0, 0
	for _, case in ipairs(CASES) do
		local previous, next, expected, what = case[1], case[2], case[3], case[4]
		local got = VoteReveal.ShouldReveal(previous, next)
		if got ~= expected then
			failures += 1
			say("FAIL  reveal  want %-5s got %-5s  (%s)", tostring(expected), tostring(got), what)
		end
		if oldContentRule(previous, next) ~= expected then
			oldFired += 1
		end
		if missesTheFirstRule(previous, next) ~= expected then
			mirrorFired += 1
		end
	end

	totalFailures += failures
	say("reveal: %d cases examined, %d failures", #CASES, failures)
	say("  plant A %-46s %s (%d of %d cases)", "a repeated snapshot must never reveal",
		oldFired > 0 and "FIRED" or "DEAD CHECK -- THIS TABLE PROVES NOTHING", oldFired, #CASES)
	say("  plant B %-46s %s (%d of %d cases)", "a close we watched must always reveal",
		mirrorFired > 0 and "FIRED" or "DEAD CHECK -- THIS TABLE PROVES NOTHING", mirrorFired, #CASES)
end)
if not okReveal then
	totalFailures += 1
	say("reveal section ERRORED: %s", tostring(revealErr))
end

--------------------------------------------------------------------------------
-- 2. VoteCursor.ShouldStandAside -- #100
--------------------------------------------------------------------------------

local okAside, asideErr = pcall(function()
	local ME = VoteCursor.ClaimName

	-- holders, legacyHeld, expected, what it is
	local CASES = {
		{ {}, false, false, "nobody holds the cursor" },
		{ { ME }, false, false, "OUR OWN CLAIM -- #100: read as somebody else's, the screen hid itself" },
		{ { ME, ME }, false, false, "claimed twice: still only us (a COUNT would say otherwise)" },
		{ { "DropPicker" }, false, true, "the drop picker is up" },
		{ { ME, "DropPicker" }, false, true, "ours and the picker's" },
		{ { "DropPicker", ME }, false, true, "same, in the other order" },
		{ {}, true, true, "an unmigrated direct writer: the main menu or the inventory" },
		{ { ME }, true, true, "our claim AND the menu: still stand aside" },
		{ nil, false, false, "no holder list at all" },
		{ nil, true, true, "no holder list, menu up" },
	}

	-- THE BUG ITSELF: the raw attribute, which is true for our own claim too.
	-- INVARIANT: a screen's own claim never makes it stand aside.
	local function rawAttributeRule(holders, legacy)
		return (type(holders) == "table" and #holders > 0) or legacy == true
	end
	-- THE ONE claude-43 CALLED: count minus our own, which breaks in the direction that LOCKS the
	-- mouse the moment we hold two claims or leak one.
	-- INVARIANT: the answer does not depend on HOW MANY times we claimed.
	local function countRule(holders, legacy, me)
		local mine, others = 0, 0
		for _, name in ipairs(holders or {}) do
			if name == me then mine += 1 else others += 1 end
		end
		return (mine + others - math.min(mine, 1)) > 0 or legacy == true
	end

	local failures, rawFired, countFired = 0, 0, 0
	for _, case in ipairs(CASES) do
		local holders, legacy, expected, what = case[1], case[2], case[3], case[4]
		local got = VoteCursor.ShouldStandAside(holders, legacy, ME)
		if got ~= expected then
			failures += 1
			say("FAIL  standAside  want %-5s got %-5s  (%s)", tostring(expected), tostring(got), what)
		end
		if rawAttributeRule(holders, legacy) ~= expected then
			rawFired += 1
		end
		if countRule(holders, legacy, ME) ~= expected then
			countFired += 1
		end
	end

	totalFailures += failures
	say("standAside: %d cases examined, %d failures", #CASES, failures)
	say("  plant C %-46s %s (%d of %d cases)", "our own claim must never hide us",
		rawFired > 0 and "FIRED" or "DEAD CHECK -- THIS TABLE PROVES NOTHING", rawFired, #CASES)
	say("  plant D %-46s %s (%d of %d cases)", "the answer must not depend on claim COUNT",
		countFired > 0 and "FIRED" or "DEAD CHECK -- THIS TABLE PROVES NOTHING", countFired, #CASES)
end)
if not okAside then
	totalFailures += 1
	say("standAside section ERRORED: %s", tostring(asideErr))
end

--------------------------------------------------------------------------------
-- 3. VoteCursor.Screen -- drawn is not the same as interactive
--------------------------------------------------------------------------------

local okScreen, screenErr = pcall(function()
	-- open, decided, ready, expectVisible, expectCursor, what it is
	local CASES = {
		{ true, nil, true, true, true, "the interactive vote, readied: drawn AND holds the mouse" },
		{ false, "BattleRoyale|Dust", true, true, false, "THE REVEAL: drawn, inert, must NOT claim the cursor" },
		{ false, nil, true, false, false, "nothing on screen" },
		{ true, "BattleRoyale|Dust", true, true, true, "both set: the interactive vote wins" },
		{ nil, nil, nil, false, false, "no state at all" },
		-- THE READY-UP LOOP (#29): the screen that says "ready up to vote" must leave the READY pill
		-- and the Ready key reachable, so an unready player's vote is drawn but takes nothing.
		{ true, nil, false, true, false, "UNREADY: drawn greyed, must NOT take the cursor or the overlay" },
		{ true, nil, nil, true, true, "readiness not given: counts as ready, older callers keep the vote" },
		{ false, "BattleRoyale|Dust", false, true, false, "the reveal for an unready player: drawn, inert" },
	}

	-- INVARIANT: a screen nobody can click never claims the cursor. Claiming raises MenuOpen, which
	-- CombatClient reads at five sites in inCombat(), so a reveal that claimed would switch combat off
	-- for its three seconds.
	local function claimsForTheRevealRule(open, decided)
		return open == true or decided ~= nil
	end

	-- INVARIANT: the pre-#29 rule -- "open alone decides the cursor" -- must FAIL the unready row, or
	-- the readiness column is decoration.
	local function claimsRegardlessOfReadiness(open)
		return open == true
	end

	local failures, revealPlantFired, readyPlantFired = 0, 0, 0
	for _, case in ipairs(CASES) do
		local open, decided, ready, wantVisible, wantCursor, what = case[1], case[2], case[3], case[4], case[5], case[6]
		local visible, cursor = VoteCursor.Screen(open, decided, ready)
		if visible ~= wantVisible or cursor ~= wantCursor then
			failures += 1
			say("FAIL  screen  want visible=%-5s cursor=%-5s got visible=%-5s cursor=%-5s  (%s)",
				tostring(wantVisible), tostring(wantCursor), tostring(visible), tostring(cursor), what)
		end
		if claimsForTheRevealRule(open, decided) ~= wantCursor then
			revealPlantFired += 1
		end
		if claimsRegardlessOfReadiness(open) ~= wantCursor then
			readyPlantFired += 1
		end
	end
	if readyPlantFired == 0 then
		failures += 1
	end

	totalFailures += failures
	say("screen: %d cases examined, %d failures", #CASES, failures)
	say("  plant E %-46s %s (%d of %d cases)", "an inert screen must not claim the cursor",
		revealPlantFired > 0 and "FIRED" or "DEAD CHECK -- THIS TABLE PROVES NOTHING", revealPlantFired, #CASES)
	say("  plant G %-46s %s (%d of %d cases)", "the pre-#29 rule must fail the unready row",
		readyPlantFired > 0 and "FIRED" or "DEAD CHECK -- THE READINESS COLUMN PROVES NOTHING", readyPlantFired, #CASES)
end)
if not okScreen then
	totalFailures += 1
	say("screen section ERRORED: %s", tostring(screenErr))
end

--------------------------------------------------------------------------------
-- 4. MenuOpenClaims against a REAL Instance
--------------------------------------------------------------------------------

-- StarterPlayerScripts is not replicated to a server-side runtest, so the module is loaded from the
-- source tree the place was built from when it is not reachable as an instance. If neither works the
-- section says so rather than passing quietly.
local okClaims, claimsErr = pcall(function()
	local StarterPlayer = game:GetService("StarterPlayer")
	local scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local module = scripts and scripts:FindFirstChild("MenuOpenClaims")
	if not module then
		say("claims: INCONCLUSIVE -- MenuOpenClaims is not reachable from a server runtest")
		return
	end
	local MenuOpenClaims = require(module)

	-- A Folder has real attributes and a real GetAttributeChangedSignal, so this drives the genuine
	-- article rather than a mock of it.
	local subject = Instance.new("Folder")
	MenuOpenClaims.Bind(subject)

	local failures = 0
	local function check(what, got, expected)
		if got ~= expected then
			failures += 1
			say("FAIL  claims  %-52s want %s got %s", what, tostring(expected), tostring(got))
		end
	end

	check("no claims -> attribute false", subject:GetAttribute("MenuOpen"), false)
	check("no claims -> HeldByOthers(VoteScreen)", MenuOpenClaims.HeldByOthers("VoteScreen"), false)

	local releaseVote = MenuOpenClaims.Claim("VoteScreen")
	check("our claim -> attribute true", subject:GetAttribute("MenuOpen"), true)
	check("our claim -> HeldByOthers(VoteScreen)", MenuOpenClaims.HeldByOthers("VoteScreen"), false)
	check("our claim -> HeldByOthers(DropPicker)", MenuOpenClaims.HeldByOthers("DropPicker"), true)

	-- THE INVARIANT THE COUNT PLANT IS ABOUT: claiming twice under one name must not read as
	-- somebody else holding it.
	local releaseVoteTwice = MenuOpenClaims.Claim("VoteScreen")
	check("claimed twice -> HeldByOthers(VoteScreen)", MenuOpenClaims.HeldByOthers("VoteScreen"), false)
	releaseVoteTwice()

	local releasePicker = MenuOpenClaims.Claim("DropPicker")
	check("both claimed -> HeldByOthers(VoteScreen)", MenuOpenClaims.HeldByOthers("VoteScreen"), true)
	releasePicker()
	check("picker released -> HeldByOthers(VoteScreen)", MenuOpenClaims.HeldByOthers("VoteScreen"), false)

	-- THE RE-ASSERT: somebody else clearing the attribute while a claim is outstanding is the
	-- "stuck free, clicks fire the gun" bug. It must be put back.
	subject:SetAttribute("MenuOpen", false)
	task.wait()
	check("cleared under an outstanding claim -> re-asserted", subject:GetAttribute("MenuOpen"), true)

	releaseVote()
	check("last release -> attribute false", subject:GetAttribute("MenuOpen"), false)
	-- Releasing twice is the same as releasing once: otherwise the count goes negative and the cursor
	-- silently stops being freed for the rest of the session.
	releaseVote()
	check("released twice -> still false, not negative", subject:GetAttribute("MenuOpen"), false)
	local releaseAfter = MenuOpenClaims.Claim("VoteScreen")
	check("a claim still works after a double release", subject:GetAttribute("MenuOpen"), true)
	releaseAfter()

	subject:Destroy()
	totalFailures += failures
	say("claims: 11 assertions, %d failures, %d legacy detectors compiled in",
		failures, MenuOpenClaims.Detectors or -1)
end)
if not okClaims then
	totalFailures += 1
	say("claims section ERRORED: %s", tostring(claimsErr))
end

--------------------------------------------------------------------------------
-- 5. A REAL VoteScreen, with its properties read off the real instances
--------------------------------------------------------------------------------

-- Source text would only prove the line was typed. This builds the screen the game builds and reads
-- `Modal`, `Visible` and `Size` off the actual overlay, then builds a SECOND one with `noModal` that
-- must fail the same checks — because a check that cannot fail is not a check.
local okScreenWiring, screenWiringErr = pcall(function()
	local StarterPlayer = game:GetService("StarterPlayer")
	local scripts = StarterPlayer:FindFirstChild("StarterPlayerScripts")
	local module = scripts and scripts:FindFirstChild("VoteScreen")
	if not module then
		say("wiring: INCONCLUSIVE -- VoteScreen is not reachable from a server runtest")
		return
	end
	local VoteScreen = require(module)
	VoteScreen.ViewportForTest = Vector2.new(1280, 720)

	local failures = 0
	local function check(what, got, expected)
		if got ~= expected then
			failures += 1
			say("FAIL  wiring  %-54s want %s got %s", what, tostring(expected), tostring(got))
		end
	end

	local holder = Instance.new("Folder")
	holder.Name = "PreMatchProbeHolder"
	holder.Parent = ReplicatedStorage
	local gui = Instance.new("ScreenGui")
	gui.Parent = holder

	local events = {}
	local screen = VoteScreen.new({
		parent = gui,
		zIndex = 36,
		onVote = function() end,
		onMenuOpen = function(open)
			table.insert(events, open)
		end,
	})

	local CANDIDATES = {
		{ id = "BattleRoyale|Dust", mode = { id = "BattleRoyale", name = "Battle Royale" }, map = { id = "Dust", name = "Dust", radius = 1200 }, votes = 0 },
	}

	local overlay = gui:FindFirstChild("VoteOverlay")
	check("the screen builds an overlay of its own", overlay ~= nil, true)
	if overlay then
		check("the overlay is a GuiButton, not a Frame", overlay:IsA("GuiButton"), true)
		-- THE LINE THAT FREES THE CURSOR. A Frame here would dim the screen and unlock nothing.
		check("the overlay is Modal", overlay.Modal, true)
		check("the overlay covers the screen", tostring(overlay.Size), tostring(UDim2.fromScale(1, 1)))
		check("the overlay starts hidden", overlay.Visible, false)
	end

	-- THE INTERACTIVE VOTE: drawn, and it takes the cursor.
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 10, ready = true })
	check("interactive vote: the panel is drawn", screen.root.Visible, true)
	check("interactive vote: the overlay is up", overlay ~= nil and overlay.Visible, true)
	check("interactive vote: claimed once", #events, 1)
	check("interactive vote: claimed, not released", events[1], true)

	-- A REDRAW IS NOT A TRANSITION. A snapshot arrives every time anyone in the lobby taps a card.
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 9, ready = true })
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 8, ready = true })
	check("three renders of the same state still claimed ONCE", #events, 1)

	-- THE REVEAL: drawn, inert, and it must HAND THE CURSOR BACK — claiming here would raise
	-- MenuOpen and switch combat off for its three seconds.
	screen:Render({ open = false, decided = "BattleRoyale|Dust", candidates = CANDIDATES, seconds = 0, ready = true })
	check("reveal: the panel is still drawn", screen.root.Visible, true)
	check("reveal: the overlay is DOWN", overlay ~= nil and overlay.Visible, false)
	check("reveal: released", events[2], false)
	check("reveal: exactly two events so far", #events, 2)

	-- Closed entirely.
	screen:Render({ open = false, candidates = CANDIDATES, seconds = 0, ready = true })
	check("closed: the panel is gone", screen.root.Visible, false)
	check("closed: no extra release", #events, 2)

	-- Destroy while holding must release, or the claim outlives everything able to release it.
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 10, ready = true })
	check("re-opened: claimed again", #events, 3)

	-- THE READY-UP LOOP (player's-eye review; logic review #29). An unready player still sees the vote
	-- but keeps the cursor, the READY UP pill and the Ready key: the overlay goes DOWN and the claim
	-- is released; readying up mid-vote brings both back. The hint must say how, naming the live key.
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 10, ready = false, readyKey = "F" })
	check("unready: the panel is still drawn", screen.root.Visible, true)
	check("unready: the overlay is DOWN", overlay ~= nil and overlay.Visible, false)
	check("unready: released", events[4], false)
	local hintSaysHow = false
	for _, label in ipairs(screen.root:GetDescendants()) do
		if label:IsA("TextLabel") and string.find(label.Text, "READY UP", 1, true)
			and string.find(label.Text, "[F]", 1, true) then
			hintSaysHow = true
		end
	end
	check("unready: the hint names the pill AND the key", hintSaysHow, true)
	-- The same screen in a pad player's hands: no key named, the ready pad and the pill are.
	screen.forcedInputKind = "gamepad"
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 10, ready = false, readyKey = "F" })
	local padNamesPad, padNamesKey = false, false
	for _, label in ipairs(screen.root:GetDescendants()) do
		if label:IsA("TextLabel") and string.find(label.Text, "Not in the next match yet", 1, true) then
			padNamesPad = string.find(label.Text, "ready pad", 1, true) ~= nil
			padNamesKey = string.find(label.Text, "[F]", 1, true) ~= nil
		end
	end
	check("unready on a pad: the hint names the ready pad", padNamesPad, true)
	check("unready on a pad: no keyboard key is named", padNamesKey, false)
	screen.forcedInputKind = nil
	screen:Render({ open = true, candidates = CANDIDATES, seconds = 9, ready = true, readyKey = "F" })
	check("readied up mid-vote: the overlay is back", overlay ~= nil and overlay.Visible, true)
	check("readied up mid-vote: claimed again", events[5], true)
	check("readied up mid-vote: five events so far", #events, 5)

	screen:Destroy()
	check("destroyed while holding: released", events[6], false)
	check("destroyed while holding: six events", #events, 6)

	-- PLANTED FAULT, every run: the same overlay checks against a screen built WITHOUT one. Every
	-- assertion above that matters must fail here, or none of them were reading anything.
	local brokenEvents = {}
	local broken = VoteScreen.new({
		parent = gui,
		zIndex = 36,
		noModal = true,
		onVote = function() end,
		onMenuOpen = function(open)
			table.insert(brokenEvents, open)
		end,
	})
	broken:Render({ open = true, candidates = CANDIDATES, seconds = 10, ready = true })
	local brokenOverlay = nil
	for _, child in ipairs(gui:GetChildren()) do
		if child.Name == "VoteOverlay" then
			brokenOverlay = child
		end
	end
	local plantFired = brokenOverlay == nil
	say("  plant F %-46s %s", "a screen with no overlay must fail the overlay checks",
		plantFired and "FIRED" or "DEAD CHECK -- THE OVERLAY CHECKS PROVE NOTHING")
	if not plantFired then
		failures += 1
	end
	-- ...and the MenuOpen half must still work without the overlay, so the two halves are genuinely
	-- independent and a failure of one is not silently covered by the other.
	check("no overlay: the MenuOpen claim still happens", brokenEvents[1], true)
	broken:Destroy()

	gui:Destroy()
	holder:Destroy()
	totalFailures += failures
	say("wiring: 31 assertions on real instances, %d failures", failures)
end)
if not okScreenWiring then
	totalFailures += 1
	say("wiring section ERRORED: %s", tostring(screenWiringErr))
end

--------------------------------------------------------------------------------

say("TOTAL failures: %d", totalFailures)
-- WHICH HALF THIS PROVES, said plainly rather than left to be assumed. It proves the DECISIONS: the
-- value that goes in the handler slot, the predicate, the claim bookkeeping. It does NOT prove the
-- WIRING -- that VoteScreen's Modal overlay actually unlocks a first-person cursor, or that a click
-- on a card no longer fires the gun. No probe in this harness can synthesise input or run a
-- LocalScript, so the wiring's proof is Oliver readying up in the lobby holding a trial gun and
-- finding his mouse free over the vote.
say("scope: the DECISION half. The wiring half is Oliver's playtest -- a trial gun in the lobby, then a vote.")
say("done")
