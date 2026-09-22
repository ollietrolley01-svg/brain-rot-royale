-- One pure decision, kept out of VoteDropClient so it can be tested: a VoteChanged snapshot has
-- arrived — does the winner reveal start?
--
-- It exists because of Oliver's #107 ("sometimes game choosing menu pulls up randomly mid match").
-- VoteService caches its `resolved` pick until the NEXT Open() (VoteService.lua:190), and Snapshot()
-- emits `winner = (not open and resolved) and resolved.id` (VoteService.lua:137). So for the WHOLE of
-- a running match every snapshot carries a winner — it is a standing FIELD, not an announcement. And
-- Bootstrap.server.lua:282 re-broadcasts that snapshot to EVERY client whenever anybody joins.
--
-- The rule this replaces was `state.winner and not state.open`, inline in the remote handler. That is
-- a test on the CONTENT of a snapshot, not on a change, so every mid-match join replayed a
-- three-second winner reveal on every player's screen — over a running match, where the cursor is
-- locked to the middle of it, which is the other half of Oliver's #100.
--
-- THE CLASS OF BUG: A BROADCAST IS A STATE SNAPSHOT, NOT AN EVENT. The same rule Shared/CombatState
-- was written for after #82, in the same session, on a different remote.
--
-- PURE AND TOTAL. No upvalues, no services, no Instances: every answer is a function of the two
-- arguments, and every input shape has an answer, so tools/prematch_ui_probe.lua can run a table over
-- it. Anything left inline in VoteDropClient is logic no probe in this harness can ever reach — it is
-- a LocalScript, and nothing here can run one.
local VoteReveal = {}

-- `previous` is the last VoteChanged snapshot this client held (nil before the first one), `next` the
-- one just received. True only for the transition "the vote I was watching has just closed on a
-- winner".
--
--   open=true  -> open=false, winner set    REVEAL. The countdown ran out; this is the announcement.
--   open=false -> open=false, same winner   NO. The mid-match join re-broadcast — #107.
--   open=false -> open=false, other winner  NO. Still not a close we watched; the next Open() clears
--                                           `winner` to nil, so a real second match always passes
--                                           through an open snapshot first.
--   anything   -> open=true                 NO. The vote is still running.
--   anything   -> winner=nil                NO. A cancelled countdown closes with no winner.
--   nil        -> open=false, winner set    NO, AND THIS IS A DELIBERATE CHOICE, NOT AN OVERSIGHT.
--
-- ON THE nil PREVIOUS, because it is the case a reader will assume was written carelessly. A reveal
-- is a TRANSITION, and a client holding no previous snapshot has not observed one — it is seeing
-- history. The only way a client's first-ever snapshot can carry a winner is that it arrived after
-- the vote had already resolved: that client joined during the match (or during the map build). That
-- is the same population as #107, so "reveal on a nil previous" and "#107" cannot be separated — you
-- cannot have one without the other.
--
-- The costs are not symmetric either. A missed reveal costs one player who joined in the same second
-- the vote resolved a three-second informational panel about a match they are being dropped into
-- anyway, and the HUD names the mode. A spurious reveal puts a full-screen panel over live gameplay
-- with the mouse locked to the middle of it. So an unobservable transition answers "no".
function VoteReveal.ShouldReveal(previous, next)
	if type(next) ~= "table" then
		return false
	end
	-- Still open: whatever else is in the snapshot, nothing has been decided yet.
	if next.open == true then
		return false
	end
	-- A countdown cancelled by everyone unreadying closes with no Resolve and so no winner.
	if next.winner == nil then
		return false
	end
	if type(previous) ~= "table" then
		return false
	end
	-- The whole rule: we watched it open, and now it is closed on a winner. EXACTLY ONCE — the very
	-- next snapshot has `previous.open == false` and answers no, which is what makes the repeat safe.
	return previous.open == true
end

return VoteReveal
