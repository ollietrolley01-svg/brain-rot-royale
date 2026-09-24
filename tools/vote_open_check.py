"""#107 check: the vote screen is never drawn over a match; and (findings C4) it is up in the lobby.

Runs the REAL ReplicatedStorage/Shared/VoteReveal.lua (ShouldReveal + View) under lupa, fed by
server timelines written in MatchService/VoteService's own order:

  - battle royale: countdown, Loading broadcast, VoteService.Close() (winner), map build, drop picker,
    InProgress, with the closed snapshot re-sent mid-match (the pre-gate Bootstrap join broadcast);
    then Results, and the break (Intermission) where MatchService opens the next vote, through Waiting
    and the next countdown into the next match
  - team deathmatch whose map builds in 1 s: no drop picker, so only the match-state gate hides the reveal
  - a countdown everyone unreadies out of (back to Waiting; the vote stays open, this client unready)
  - a start that fails before VoteService.Close()
  - a client whose FIRST snapshot is the closed one (joined mid-match)
  - the break watched by a player who readies up half way through it

The client glue (the timer and which snapshot counts as previous) is VoteDropClient's handler copied
in miniature below, because nothing here can run a LocalScript; the two decisions it calls are the
real module's.

INVARIANTS. A reveal starts exactly once per vote the client watched close on a winner (never for a
re-sent snapshot, a cancelled countdown or a mid-match joiner). And, checked at every half-second of
every timeline: outside the lobby (Intermission, Waiting, Countdown) and Loading neither the vote nor
its reveal is on screen; the interactive vote is only ever on screen in the lobby, and outside the
countdown only for a player who is ready; and an open vote IS on screen for a ready player anywhere in
the lobby (so the break's vote cannot quietly be hidden again).

PLANTED FAULTS (permanent, aimed at the invariant, not at the old bug): mutants of the real source -
reveal ungated by match state, vote ungated by match state, the vote over the break for the unready,
the vote back to the countdown only, and the old snapshot-content reveal rule - must each break it. If
a mutant passes, the check is blind and says so.

Run: python3 tools/vote_open_check.py   (exit 0 = clean pass and every fault caught)
"""
import os
import sys

from lupa import LuaRuntime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VoteReveal.lua")
REVEAL_SECONDS = 3.0
STEP = 0.5

# The client glue, as VoteDropClient runs it. `now` is passed in; tick() is wall time there.
GLUE = r"""
return function(VoteReveal)
	local c = { match = { state = "Waiting" }, vote = { open = false }, previous = nil,
		revealId = nil, revealUntil = 0, ready = true }
	function c.onVote(state, now)
		c.vote = state
		local should = VoteReveal.ShouldReveal(c.previous, state)
		c.previous = state
		if should then
			c.revealId = state.winner
			c.revealUntil = now + %s
			c.starts = (c.starts or 0) + 1
		elseif state.open then
			c.revealId = nil
		end
	end
	function c.onMatch(state) c.match = state end
	function c.onReady(ready) c.ready = ready end
	function c.view(now)
		local open, showReveal = VoteReveal.View(c.match, c.vote.open, c.revealId ~= nil and now < c.revealUntil, c.ready)
		return open, showReveal and c.revealId or nil
	end
	return c
end
""" % REVEAL_SECONDS


def open_snap():
    return {"open": True, "winner": None}


def closed_snap(winner):
    return {"open": False, "winner": winner}


def br_timeline():
    ev, t = [], 0.0
    for _ in range(3):
        ev.append((t, "match", {"state": "Waiting"})); t += 1
    ev.append((t, "match", {"state": "Countdown"})); ev.append((t, "vote", open_snap()))
    for _ in range(8):
        t += 1; ev.append((t, "match", {"state": "Countdown"}))
    ev.append((t, "match", {"state": "Loading"}))
    ev.append((t, "vote", closed_snap("BattleRoyale|Bay")))
    t += 1.0  # a quick build
    for _ in range(10):
        ev.append((t, "match", {"state": "Loading", "dropSelect": True})); t += 1
    ev.append((t, "match", {"state": "Loading", "dropSelect": False}))
    ev.append((t, "match", {"state": "InProgress"}))
    for k in range(60):
        t += 1
        if k % 10 == 5:  # somebody joins: the ungated re-broadcast of the standing snapshot
            ev.append((t, "vote", closed_snap("BattleRoyale|Bay")))
    ev.append((t, "match", {"state": "Results"}))
    # The break: MatchService opens the next match's vote as Intermission begins (findings C4).
    t += 5; ev.append((t, "match", {"state": "Intermission"})); ev.append((t, "vote", open_snap()))
    for _ in range(6):
        t += 1; ev.append((t, "match", {"state": "Intermission"}))
    t += 1; ev.append((t, "match", {"state": "Waiting"}))
    t += 1; ev.append((t, "match", {"state": "Countdown"}))
    t += 4; ev.append((t, "match", {"state": "Loading"})); ev.append((t, "vote", closed_snap("TeamDeathmatch|Bay")))
    t += 1; ev.append((t, "match", {"state": "InProgress"}))
    return ev, t + 3


def tdm_fast_build():
    ev, t = [], 0.0
    ev.append((t, "match", {"state": "Countdown"})); ev.append((t, "vote", open_snap()))
    t += 5; ev.append((t, "match", {"state": "Loading"}))
    ev.append((t, "vote", closed_snap("TeamDeathmatch|Arena")))
    t += 1.0; ev.append((t, "match", {"state": "InProgress"}))
    return ev, t + 10


def cancelled():
    # Everyone unreadies out of the countdown: back to Waiting, and the vote STAYS open (it belongs to the
    # lobby now); this client is one of the unready, so it must not be drawn for them outside the countdown.
    ev, t = [], 0.0
    ev.append((t, "match", {"state": "Countdown"})); ev.append((t, "vote", open_snap()))
    t += 3; ev.append((t, "ready", False)); ev.append((t, "match", {"state": "Waiting"}))
    return ev, t + 5


def unready_break():
    # The break after a match with the vote open, watched by a player who has not readied: the lobby is
    # theirs (crates, trading, the climb), so no vote panel until they ready up; then it is up.
    ev, t = [(0.0, "ready", False), (0.0, "match", {"state": "Intermission"}), (0.0, "vote", open_snap())], 0.0
    t += 6; ev.append((t, "ready", True))
    t += 4; ev.append((t, "match", {"state": "Waiting"}))
    return ev, t + 2


def start_failed_before_close():
    # startMatch throws between GameMode.Resolve and VoteService.Close (MatchService:1562-1585): the
    # pcall's fallback puts the state back to Waiting and nothing closes the vote, so the snapshot
    # still reads open while no countdown is running.
    ev, t = [], 0.0
    ev.append((t, "match", {"state": "Countdown"})); ev.append((t, "vote", open_snap()))
    t += 4; ev.append((t, "match", {"state": "Loading"}))
    t += 1; ev.append((t, "match", {"state": "Waiting"}))
    return ev, t + 5


def late_joiner():
    ev = [(0.0, "match", {"state": "InProgress"}), (0.0, "vote", closed_snap("KingOfTheHill|Bay")),
          (4.0, "vote", closed_snap("KingOfTheHill|Bay"))]
    return ev, 10.0


TIMELINES = {"br": br_timeline, "tdm_fast_build": tdm_fast_build, "cancelled": cancelled,
             "start_failed_before_close": start_failed_before_close, "late_joiner": late_joiner,
             "unready_break": unready_break}
# How many reveals each timeline must start: one per vote the client WATCHED close on a winner.
EXPECTED_REVEALS = {"br": 2, "tdm_fast_build": 1, "cancelled": 0, "start_failed_before_close": 0,
                    "late_joiner": 0, "unready_break": 0}
LOBBY = ("Intermission", "Waiting", "Countdown")


def to_lua(lua, value):
    if isinstance(value, dict):
        t = lua.table()
        for k, v in value.items():
            if v is not None:
                t[k] = v
        return t
    return value


def run(source):
    """Returns (violations, ticks examined, reveals seen, votes seen, votes seen in the break)."""
    violations, ticks, reveals, votes, break_votes = [], 0, 0, 0, 0
    for name, build in TIMELINES.items():
        lua = LuaRuntime(unpack_returned_tuples=True)
        module = lua.execute(source)
        client = lua.execute(GLUE)(module)
        events, end = build()
        events.sort(key=lambda e: e[0])
        i, now = 0, 0.0
        while now <= end:
            while i < len(events) and events[i][0] <= now:
                _, kind, payload = events[i]
                if kind == "match":
                    client.onMatch(to_lua(lua, payload))
                elif kind == "ready":
                    client.onReady(payload)
                else:
                    client.onVote(to_lua(lua, payload), now)
                i += 1
            is_open, decided = client.view(now)
            state = client.match.state
            ticks += 1
            reveals += decided is not None
            votes += bool(is_open)
            break_votes += bool(is_open) and state == "Intermission"
            if state not in LOBBY + ("Loading",) and (is_open or decided is not None):
                violations.append(f"{name} t={now}: drawn during {state} (open={is_open}, reveal={decided})")
            elif is_open and state not in LOBBY:
                violations.append(f"{name} t={now}: interactive vote during {state}")
            elif is_open and state != "Countdown" and not client.ready:
                violations.append(f"{name} t={now}: vote over the lobby during {state} for a player who is not ready")
            elif client.vote.open and client.ready and state in LOBBY and not is_open and decided is None:
                violations.append(f"{name} t={now}: the vote is open and this player is ready, but it is not drawn during {state}")
            now += STEP
        starts = client.starts or 0
        if starts != EXPECTED_REVEALS[name]:
            violations.append(f"{name}: {starts} reveals started, expected {EXPECTED_REVEALS[name]}")
    return violations, ticks, reveals, votes, break_votes


MUTANTS = {
    "reveal ungated by match state": (
        'and (state == "Loading" or state == "Countdown")', 'and true'),
    "vote ungated by match state": (
        'local open = voteOpen == true and (state == "Countdown" or (LOBBY_VOTE[state] == true and ready == true))',
        'local open = voteOpen == true'),
    "vote over the break for the unready": (
        '(LOBBY_VOTE[state] == true and ready == true)', '(LOBBY_VOTE[state] == true)'),
    "vote only in the countdown again (the old rule)": (
        'local open = voteOpen == true and (state == "Countdown" or (LOBBY_VOTE[state] == true and ready == true))',
        'local open = voteOpen == true and state == "Countdown"'),
    "old snapshot-content reveal rule": (
        'return previous.open == true', 'return true'),
}


def main():
    with open(SOURCE, encoding="utf-8") as f:
        source = f.read()
    ok = True
    violations, ticks, reveals, votes, break_votes = run(source)
    print(f"clean: {len(TIMELINES)} timelines, {ticks} ticks examined, "
          f"{votes} with the vote up ({break_votes} in the break), {reveals} with the reveal up, {len(violations)} violations")
    for v in violations[:5]:
        print("  " + v)
    if violations:
        ok = False
    # The pass must not be vacuous: the vote and the reveal each have to have been drawn somewhere.
    if votes == 0 or reveals == 0 or break_votes == 0:
        print("FAIL: the clean run never drew the vote, the vote in the break, or the reveal; the timelines are not exercising it")
        ok = False
    for label, (old, new) in MUTANTS.items():
        if old not in source:
            print(f"FAIL: planted fault '{label}' could not be applied (source changed; update the mutant)")
            ok = False
            continue
        bad, _, _, _, _ = run(source.replace(old, new, 1))
        caught = len(bad) > 0
        print(f"planted fault '{label}': {'CAUGHT' if caught else 'MISSED'} ({len(bad)} violations)"
              + (f", first: {bad[0]}" if bad else ""))
        ok = ok and caught
    print("vote_open_check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
