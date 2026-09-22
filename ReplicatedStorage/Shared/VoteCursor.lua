-- The vote screen's two cursor decisions, in one place, pure and total.
--
-- WHY THIS MODULE EXISTS — Oliver's #100, "my mouse doesn't unlock anymore when vote menus pull up".
-- It was never a regression. It was unreachable by construction and then became reachable:
--
--   VoteDropClient computed  open = voteState.open and state == "Countdown" and NOT MenuOpen,
--   and VoteScreen drew itself when  open == true or decided ~= nil,  with `decided` also nilled on
--   MenuOpen. So BOTH branches that make the vote screen visible required MenuOpen to be FALSE.
--   MenuCursor.client.lua raises its modal and writes MouseBehavior.Default per frame ONLY while
--   MenuOpen is TRUE. The two sets therefore never intersected: while a vote was on screen, nothing
--   in the project could free the mouse. The screen's own predicate excluded the only state in which
--   anything unlocks the cursor.
--
-- That cost nothing while the lobby left the mouse free anyway. It started costing Oliver the moment
-- something else held the lock during a vote — a lobby trial gun (RangeState -> rangeActive ->
-- CombatClient sets CameraMode.LockFirstPerson, and Roblox's own camera then relocks the mouse EVERY
-- FRAME), and the mid-match winner reveal of #107. MAKING A FORM REACHABLE MAKES ITS BUGS REACHABLE.
--
-- PURE AND TOTAL: no services, no Instances, no upvalues. tools/prematch_ui_probe.lua runs a table
-- over it. VoteDropClient is a LocalScript and nothing in this harness can run one, so no decision
-- may be left inside it.
local VoteCursor = {}

-- The name this screen claims the cursor under. One constant, so the claim and the exclusion below
-- cannot drift apart — a claim filed under one spelling and excluded under another would read as
-- "somebody else is holding the cursor" forever, and the screen would hide itself permanently.
VoteCursor.ClaimName = "VoteScreen"

-- What is on screen, and what wants the mouse. TWO ANSWERS FROM ONE INPUT SET, because the trap is
-- precisely that they differ, and because VoteScreen and VoteDropClient must not each decide it.
--
-- `visible` is the old VoteScreen rule, unchanged: the interactive vote, or the winner reveal.
-- `wantsCursor` is the INTERACTIVE vote ONLY. The reveal must NOT claim the cursor:
--   * there is nothing to click — every card is built with `Active = enabled and not decided` and
--     `enabled` is false whenever a winner is decided, so the reveal cannot take input at all; and
--   * claiming raises the MenuOpen attribute, which CombatClient reads in inCombat() at five sites.
--     A reveal that claimed would switch combat off for its three seconds. Today the reveal lands in
--     the "Loading" state while the map builds, so that is currently harmless — but "currently
--     harmless" is how the bug above was born, and a cursor claim on a screen nobody can click is
--     wrong on its own terms.
--
-- `ready` is the third input (the player's-eye review; logic review #29). An UNREADY player's vote is
-- drawn -- greyed cards under "ready up to vote" -- but must NOT take the cursor. Taking it raised
-- MenuOpen, which made HudClient drop the Ready key, while the full-screen overlay sat over the READY
-- UP pill in BrrHud (DisplayOrder 0, under this screen's 30): the one screen telling the player to
-- ready up had disabled both ways of doing it, and a player who was not yet in the match could only
-- reach the pad. The drop picker already gates on readiness; the vote now agrees with it. `nil`
-- counts as ready, so a caller that does not say (a gallery, an older probe row) keeps the
-- interactive vote.
function VoteCursor.Screen(open, decided, ready)
	local visible = open == true or decided ~= nil
	local wantsCursor = open == true and ready ~= false
	return visible, wantsCursor
end

-- Does the vote screen stand aside because somebody ELSE has the cursor?
--
-- The vote panel is drawn above the shop, the inventory and the merge dialog (DisplayOrder 30), so a
-- vote sitting on top of a menu the player opened is worse than a vote they close the menu to see.
-- That is the rule this preserves. What it must NOT do is count the screen's OWN claim as somebody
-- else's — that is the circularity that made the set empty.
--
-- ANSWERED FROM THE HOLDER SET, NEVER FROM A COUNT. A count is a snapshot, and a count-based test
-- ("more than one claim outstanding") breaks in the direction that locks the mouse: claim twice, or
-- miss a release on one exit path, and it reads as "somebody else is holding" forever, with nothing
-- in the log and no probe able to see it. Excluding by NAME is idempotent — our own claim can be
-- outstanding once, twice or leaked, and the answer is the same.
--
-- `holders` is MenuOpenClaims.Holders(); `legacyHeld` is MenuOpenClaims.LegacyHolder(), covering the
-- writers that still set the attribute directly instead of claiming.
function VoteCursor.ShouldStandAside(holders, legacyHeld, myName)
	if type(holders) == "table" then
		for _, name in ipairs(holders) do
			if name ~= myName then
				return true
			end
		end
	end
	return legacyHeld == true
end

return VoteCursor
