-- One pure decision, kept out of CombatClient so it can be tested: when a match-state broadcast
-- arrives, does the client have to leave its combat state?
--
-- It exists because of Oliver's #82 ("my sprinting in the lobby doesn't stay on, it keeps
-- canceling"). `MatchService`'s lobby ticker broadcasts the match state UNCONDITIONALLY about once a
-- second in Waiting, Intermission and Countdown, and again on every ready toggle, join and leave.
-- CombatClient treated each arrival as a fresh transition and ran leaveCombatState() every time, so
-- in the lobby a held sprint was turned off once a second -- and because the key was still HELD,
-- ContextActionService sent no second Begin, so it stayed off until he released and pressed again.
-- A held aim went the same way.
--
-- THE CLASS OF BUG, worth more than the fix: A BROADCAST IS A STATE SNAPSHOT, NOT AN EVENT. Anything
-- that reacts to one has to compare it with what it already had. The decision was four words inline
-- in an event handler, where nothing could test it and a once-a-second call went unnoticed; as a
-- function it carries a truth table (tools/combat_state_probe.lua) with a planted fault.
local CombatState = {}

-- `previous` is the state the client last held (nil before the first broadcast), `next` the state
-- just received, `rangeActive` whether the shooting range is holding the player's gun up.
--
-- Leave only on a real transition OUT of a match. In particular:
--   InProgress -> anything else   leave (the match ended, or the player left it)
--   x -> InProgress               stay: the match started
--   Waiting -> Waiting            STAY. This is the once-a-second lobby repeat (#82).
--   nil -> anything               stay: nothing to leave; joining mid-lobby is not an ending
--   anything, range active        stay: the range hands out a gun outside a match on purpose
function CombatState.ShouldLeaveCombat(previous, next, rangeActive)
	if rangeActive then
		return false
	end
	if next == "InProgress" then
		return false
	end
	return previous == "InProgress"
end

return CombatState
