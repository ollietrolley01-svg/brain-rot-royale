-- The truth table for CombatState.ShouldLeaveCombat, with a planted fault.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/combat_state_probe.lua
--
-- Oliver's #82 ("my sprinting in the lobby doesn't stay on, it keeps canceling") was four words
-- inline in a remote handler -- `if matchState ~= "InProgress"` -- where nothing could test it, and
-- the lobby ticker's once-a-second repeat turned his sprint off once a second for a day. The rule it
-- broke is that A BROADCAST IS A STATE SNAPSHOT, NOT AN EVENT, so the decision now takes the previous
-- state as well and lives where a table of cases can be run over it.
--
-- THE PLANTED FAULT IS THE BUG ITSELF: the old rule is run over the same table every time, and it
-- MUST fail the lobby-repeat rows. A table that the old code would also have passed would be a table
-- that could not have caught this.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatState = require(Shared:WaitForChild("CombatState"))

local function say(fmt, ...)
	print("[BRR_CombatState] " .. string.format(fmt, ...))
end

-- previous, next, rangeActive, expected, what it is
local CASES = {
	{ "InProgress", "Ended", false, true, "the match ended: drop fire and aim" },
	{ "InProgress", "Waiting", false, true, "back to the lobby: drop fire and aim" },
	{ "InProgress", "Intermission", false, true, "match over, intermission" },
	{ "InProgress", "InProgress", false, false, "a repeat while playing changes nothing" },
	{ "Waiting", "Waiting", false, false, "THE LOBBY TICKER REPEAT -- #82" },
	{ "Intermission", "Intermission", false, false, "the lobby ticker repeat, intermission" },
	{ "Countdown", "Countdown", false, false, "the lobby ticker repeat, countdown" },
	{ "Waiting", "Countdown", false, false, "lobby to countdown is not an ending" },
	{ "Countdown", "InProgress", false, false, "the match starting is not an ending" },
	{ "Ended", "Waiting", false, false, "the lobby after a match is not a second ending" },
	{ nil, "Waiting", false, false, "the first broadcast after joining" },
	{ nil, "InProgress", false, false, "joining a match in progress" },
	{ "InProgress", "Waiting", true, false, "on the range: the range owns the gun" },
	{ "Waiting", "Waiting", true, false, "on the range, lobby repeat" },
}

-- What the code did before #82 was found: leave whenever the new state is not InProgress.
local function oldRule(_, next, rangeActive)
	return next ~= "InProgress" and not rangeActive
end

local failures, oldFailures = 0, 0
for _, case in ipairs(CASES) do
	local previous, next, rangeActive, expected, what = case[1], case[2], case[3], case[4], case[5]
	local got = CombatState.ShouldLeaveCombat(previous, next, rangeActive)
	if got ~= expected then
		failures += 1
		say("FAIL  %-12s -> %-12s range=%-5s want %-5s got %-5s  (%s)", tostring(previous), tostring(next),
			tostring(rangeActive), tostring(expected), tostring(got), what)
	end
	if oldRule(previous, next, rangeActive) ~= expected then
		oldFailures += 1
	end
end

say("%d cases, %d failures", #CASES, failures)
say("planted fault %-44s %s (%d of %d cases)", "the rule this replaced must fail this table",
	oldFailures > 0 and "CAUGHT" or "MISSED -- THIS TABLE PROVES NOTHING", oldFailures, #CASES)

-- What this probe does NOT prove, said plainly rather than left for someone to assume: it proves the
-- DECISION, not the WIRING. That CombatClient passes the previous state, and that a held sprint now
-- survives a lobby broadcast, is a ContextActionService input sequence a server-only runtest window
-- cannot produce. The final proof of #82 is Oliver holding shift in the lobby for ten seconds.
say("scope: the decision only; the wiring's proof is Oliver holding shift in the lobby")
say("done")
