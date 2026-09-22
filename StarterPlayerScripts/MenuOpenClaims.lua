-- Who is holding the mouse free: the `MenuOpen` player attribute, owner-counted.
--
-- THE ATTRIBUTE IS ONE BOOLEAN WITH FOUR WRITERS, and a boolean cannot say "two things want this".
-- MenuCursor reads it and frees or re-locks the cursor; CombatClient reads it at five sites so a
-- click on a panel does not also fire the gun. Both of the ways that goes wrong are things Oliver
-- has reported, and both are a second writer clearing what a first writer still needs:
--
--   STUCK LOCKED. The menu is open (MenuClient set the attribute from its panel's `Visible`
--   change), something else opens and closes over the top of it and clears the attribute on the way
--   out. MenuClient never writes again — its handler only fires on a CHANGE of `Visible`, and the
--   panel never changed — so the menu is left on screen with the mouse locked to the middle of it.
--
--   STUCK FREE, AND CLICKS FIRE THE GUN. Something is holding the attribute, the player opens and
--   closes the menu, and the menu's close clears it. The holder thinks it still has it, so it never
--   re-asserts; the cursor comes unstuck from the panel it belongs to and the next click on that
--   panel goes through to the weapon.
--
-- So: claims, not writes. `Claim` hands back a release function, the attribute is true while any
-- claim is outstanding, and the last release clears it only if nobody unmigrated is still holding
-- it. Any writer that clears the attribute while claims are outstanding is corrected at once.
--
-- MIGRATION. HudClient's inventory, MenuClient's panel and the drop picker each write the attribute
-- directly today; the picker uses this module and the other two are one line each when their owners
-- take them. Until then `LegacyHolder` below is what keeps this module from clearing the attribute
-- out from under them, and the re-assert is what keeps them from clearing it out from under this.
-- When the last one migrates, delete `LegacyHolder` and the special case goes with it.

local Players = game:GetService("Players")

local MenuOpenClaims = {}

local ATTRIBUTE = "MenuOpen"

-- [token] = name. A strong table: these are claims, not a cache, and this project has lost live
-- entries out of weak ones before.
local claims = {}
local count = 0

-- True while this module is the one writing, so its own write does not come back through the
-- changed signal and re-enter the re-assert below.
local writing = false

local subject = nil
local connection = nil

-- Declared HERE, above the first reader, not next to Claim. Every public entry point binds through
-- it, because this module used to bind only on the first Claim() — so a caller that merely ASKED who
-- was holding the cursor, before anything had claimed, was answered from `subject == nil`: "nobody",
-- with no claim table and no PlayerGui to look at. The vote screen is exactly that caller, and it
-- would have read a wide-open main menu as an empty lobby and drawn straight over it.
-- Binding on a read is safe: `if subject then return end` means it only ever fires when nothing is
-- bound, and when nothing is bound there are no claims for Bind's table-clear to lose.
-- AND IT NEVER CALLS Bind(nil). `Bind` clears the claim table and zeroes the count, so binding to
-- nothing is DESTRUCTIVE: with no LocalPlayer — a server-side runtest, a gallery, a probe that has
-- not bound yet — every call would wipe claims that `Claim` had already booked (Claim can book one
-- while unbound: `apply` returns early, but the entry is on the books). A read would then silently
-- release screens it was only being asked about. With no subject the honest answer is "nobody is
-- holding it", which is what the readers below return without touching anything.
local function ensureBound()
	if subject then
		return
	end
	local player = Players.LocalPlayer
	if not player then
		return
	end
	MenuOpenClaims.Bind(player)
end

-- Whether an UNMIGRATED writer is holding the attribute right now, and WHICH ONE. The menu's own big
-- panel is the first: MenuClient sets the attribute from that panel's visibility and never writes
-- again until it changes, so clearing the attribute while it is up strands the cursor.
--
-- This is the same test HudClient's inventory already makes for the same reason (HudClient around
-- line 1548), deliberately rather than by coincidence: two different answers to "is the menu up"
-- would be a third bug of this exact shape. Replaced wholesale by a test.
--
-- IT RETURNS THE DETECTOR'S NAME AS A SECOND VALUE, and `Detectors` below says how many there are,
-- because a filter is a claim about what it matched: "no legacy holder" has to be distinguishable
-- from "nothing was looked at". `apply()` pcalls this and reads the first value only, so the second
-- costs it nothing.
--
-- KEYED ON GUI NAMES, WHICH IS A LISTED BUG PATTERN IN THIS PROJECT, and accepted here for exactly as
-- long as the migration lasts. Each detector is one line; when its owner takes the attribute through
-- Claim(), delete the line. When the list is empty, delete the function.
local LEGACY_DETECTORS = {
	-- MenuClient.client.lua:3373 — SetAttribute driven off the big panel's Visible.
	{
		name = "MenuClient/BrrMenu",
		held = function(playerGui)
			local menuGui = playerGui:FindFirstChild("BrrMenu")
			for _, child in ipairs(menuGui and menuGui:GetChildren() or {}) do
				if child:IsA("Frame") and child.Visible and child.AbsoluteSize.X > 500 then
					return true
				end
			end
			return false
		end,
	},
}

-- How many unmigrated writers this module knows how to see. Printed by the probes next to what they
-- found, so a green "nobody else is holding it" can never be a measurement of nothing.
MenuOpenClaims.Detectors = #LEGACY_DETECTORS

function MenuOpenClaims.LegacyHolder()
	ensureBound()
	local player = subject
	if not player or not player.FindFirstChild then
		return false
	end
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		return false
	end
	for _, detector in ipairs(LEGACY_DETECTORS) do
		-- pcall per detector: one gui shape this does not expect must not blind the others.
		local ok, held = pcall(detector.held, playerGui)
		if ok and held == true then
			return true, detector.name
		end
	end
	return false
end

-- Is anybody OTHER THAN `name` holding the cursor right now?
--
-- ANSWERED FROM THE HOLDER SET, NEVER FROM `Count()` MINUS ONE. A count is a snapshot, and a
-- count-based test fails in the direction that LOCKS THE MOUSE: a screen that claims twice, or that
-- misses a release on one of its exit paths, would read as "somebody else is holding" forever, with
-- nothing in the log and no probe able to see it. Excluding by name is idempotent — our own claim can
-- be outstanding once, twice, or leaked, and the answer does not change.
function MenuOpenClaims.HeldByOthers(name)
	for _, held in pairs(claims) do
		if held ~= name then
			return true
		end
	end
	local ok, legacy = pcall(MenuOpenClaims.LegacyHolder)
	return ok and legacy == true
end

local function apply()
	if not subject then
		return
	end
	local wanted = count > 0
	if not wanted then
		-- Only the LAST release consults this: while anything is claimed the answer is true anyway.
		local ok, held = pcall(MenuOpenClaims.LegacyHolder)
		wanted = ok and held == true
	end
	writing = true
	subject:SetAttribute(ATTRIBUTE, wanted)
	writing = false
end

-- The thing the attribute lives on. `Players.LocalPlayer` in the game; a probe or a gallery binds
-- any Instance instead — a Folder has real attributes and a real `GetAttributeChangedSignal`, so
-- the tests drive the genuine article rather than a mock of it. Neither a runtest nor a gallery has
-- a LocalPlayer, and a helper that cannot be exercised is a helper nobody has tested.
function MenuOpenClaims.Bind(instance)
	if connection then
		connection:Disconnect()
		connection = nil
	end
	subject = instance
	table.clear(claims)
	count = 0
	if not subject then
		return
	end
	-- THE RE-ASSERT. Somebody else clearing the attribute while a claim is outstanding is the
	-- "stuck free, clicks fire the gun" bug; it is put back the moment it happens.
	connection = subject:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
		if writing or count == 0 then
			return
		end
		if subject:GetAttribute(ATTRIBUTE) ~= true then
			apply()
		end
	end)
	apply()
end

-- Claims the cursor for `name` and returns the release. Releasing twice is the same as releasing
-- once: a screen that closes on both a button and a key would otherwise drop the count below zero
-- and leave the next claimant unable to hold it at all.
function MenuOpenClaims.Claim(name)
	ensureBound()
	local token = {}
	claims[token] = name or "unnamed"
	count += 1
	apply()

	local released = false
	return function()
		if released then
			return
		end
		released = true
		-- A release whose claim is not on the books any more does NOTHING. `Bind` clears the table
		-- and zeroes the count, so a closure handed out before a re-bind is a claim on a subject
		-- that no longer exists; letting it decrement would take a claim off the NEW binding that
		-- was never added to it. The count would go negative, `wanted = count > 0` would be false
		-- for the rest of the session, and the cursor would simply stop being freed — silently,
		-- with nothing in the log. Production only re-binds through `ensureBound` and so cannot
		-- reach this today; the probe binds twice, and one refactor would be enough.
		if claims[token] == nil then
			return
		end
		claims[token] = nil
		-- Floored as well as guarded. Belt and braces on the one value whose going negative is
		-- invisible and permanent.
		count = math.max(0, count - 1)
		apply()
	end
end

-- How many claims are outstanding, and who holds them. For probes and for anyone debugging a
-- cursor that will not come back: the names are the answer to "what is holding this".
function MenuOpenClaims.Count()
	ensureBound()
	return count
end

function MenuOpenClaims.Holders()
	ensureBound()
	local names = {}
	for _, name in pairs(claims) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return MenuOpenClaims
