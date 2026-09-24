"""The lobby between matches (findings C4, I4, I3): the vote is up all break, a break everyone has
readied out of is cut short, and the drop picker closes once every player has picked.

    python3 tools/lobby_flow_check.py .            the checks
    python3 tools/lobby_flow_check.py . --plant    the planted faults; every one must be caught

The REAL code, cut out of MatchService.lua and run in lupa against a mocked world, second by second:

  break     the Results -> Intermission step opens the next match's vote (VoteService.Open), so it is
            up for the whole break instead of only the countdown's last 8 seconds
  loop      MatchService.Start's 1 s loop body, driven through Intermission -> Waiting -> Countdown:
            the vote is never re-rolled while open (one Open per break, whoever readies when); a
            countdown everyone unreadies out of leaves it open (no Close, so no votes thrown away); a
            fresh server with no vote opens one at its first countdown; once every player present is
            ready the break drops to MatchConfig.IntermissionAllReady seconds and never below what is
            left; one unready player, or an empty server, waits the full break
  drop      startMatch's drop-select window ends a second after the last human participant picks, a
            leaver does not hold it open, and one player who never picks gets the full window

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("lobby_flow_check: needs lupa (pip install lupa)")

MATCH = "ServerScriptService/Modules/MatchService.lua"
CONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def between(src, start, stop):
    a = src.index(start)
    return src[a:src.index(stop, a)]


def number(src, key):
    return int(re.search(r"^MatchConfig\.%s = (\d+)" % key, src, re.M).group(1))


COMMON = r"""
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local players = {}
local function player(name, ready)
    local p = { Name = name, Parent = true, ready = ready }
    function p:GetAttribute(k) if k == "Ready" then return self.ready end end
    return p
end
local vote = { open = false, opens = 0, closes = 0 }
local VoteService = {
    Open = function() vote.open = true; vote.opens = vote.opens + 1 end,
    Close = function() vote.open = false; vote.closes = vote.closes + 1 end,
    IsOpen = function() return vote.open end,
}
local function readyPlayers()
    local list = {}
    for _, p in ipairs(players) do if p.ready then table.insert(list, p) end end
    return list
end
local starts = 0
local env = setmetatable({
    state = "Waiting", countdown = 0,
    Players = { GetPlayers = function() return players end },
    VoteService = VoteService,
    readyPlayers = readyPlayers,
    broadcast = function() end,
    startMatch = function() starts = starts + 1; env_state_after_start() end,
    currentMode = { respawn = false },
    participants = {},
    regen = { at = nil },
    afk = { tick = 0, every = 15 },
}, { __index = _G })
"""

LOOP = COMMON + r"""
local body, cfg = ...
env.MatchConfig = cfg
function env_state_after_start() env.state = "Loading" end
local tick = assert(load(body, "MatchService.Start loop", "t", env))
local function run(n) for _ = 1, n do tick() end end
local function reset(state, countdown, list, open)
    env.state, env.countdown = state, countdown
    players = list
    vote.open, vote.opens, vote.closes = open, 0, 0
    starts = 0
end

-- The break with the vote already open (the Results -> Intermission step opened it): two players, both
-- unready for 10 s, then both ready.
local a, b = player("A", false), player("B", false)
reset("Intermission", cfg.Intermission, { a, b }, true)
run(10)
check(env.state == "Intermission" and env.countdown == cfg.Intermission - 10,
    string.format("nobody ready: the break runs at its own pace (%s, %d s left)", env.state, env.countdown))
a.ready, b.ready = true, true
run(1)
check(env.countdown == cfg.IntermissionAllReady - 1,
    string.format("everyone ready: the break drops to IntermissionAllReady (%d s) at once (%d left after the tick)", cfg.IntermissionAllReady, env.countdown))
run(cfg.IntermissionAllReady - 1)
check(env.state == "Waiting", "...and ends when those seconds are up (" .. env.state .. ")")
run(1)
check(env.state == "Countdown" and vote.opens == 0 and vote.open,
    string.format("the countdown keeps the break's vote: not re-rolled (%d Open calls), still open", vote.opens))
a.ready, b.ready = false, false
run(1)
check(env.state == "Waiting" and vote.closes == 0 and vote.open,
    string.format("everyone unreadying out of the countdown leaves the vote open (%s, %d Close calls)", env.state, vote.closes))
a.ready = true
run(1)
check(env.state == "Countdown" and vote.opens == 0, "...and the next countdown still does not re-roll it")

-- One of two ready: the full break.
local c, d = player("C", true), player("D", false)
reset("Intermission", cfg.Intermission, { c, d }, true)
run(5)
check(env.countdown == cfg.Intermission - 5, "one player unready: no skip (" .. env.countdown .. " s left)")

-- Already under the minimum: never lengthened.
reset("Intermission", 3, { player("E", true) }, true)
run(1)
check(env.countdown == 2, "a break with 3 s left and everyone ready goes on at its own pace (" .. env.countdown .. " left)")

-- An empty server: nobody to be ready, nothing skipped.
reset("Intermission", cfg.Intermission, {}, true)
run(3)
check(env.countdown == cfg.Intermission - 3, "an empty server waits the break out (" .. env.countdown .. " left)")

-- A fresh server: no vote yet, someone readies.
reset("Waiting", 0, { player("F", true) }, false)
run(1)
check(env.state == "Countdown" and vote.opens == 1 and vote.open, string.format("a fresh server opens the vote at its first countdown (%d Open)", vote.opens))
return out
"""

BREAK = COMMON + r"""
local snippet = ...
env.MatchConfig = { Intermission = 35 }
env.state = "Results"
assert(load(snippet, "MatchService results->Intermission", "t", env))()
check(env.state == "Intermission" and vote.opens == 1 and vote.open,
    string.format("the break opens the next match's vote as it begins (%s, %d Open)", env.state, vote.opens))
return out
"""

DROP = r"""
local block, seconds = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local function scenario(label, picks, leavers, want)
    local clock = 0
    local joining, participants, chosenDrop = {}, {}, {}
    for name in pairs(picks) do
        local p = { Name = name, Parent = true }
        table.insert(joining, p); participants[p] = true
    end
    local env = setmetatable({
        currentMode = { dropSelect = true }, dropSelect = false, countdown = 0,
        MatchConfig = { DropSelectSeconds = seconds },
        joining = joining, participants = participants, chosenDrop = chosenDrop,
        broadcast = function() end,
        task = { wait = function(d)
            clock = clock + (d or 0)
            for _, p in ipairs(joining) do
                local at = picks[p.Name]
                if at and clock >= at then chosenDrop[p] = true end
                if leavers[p.Name] and clock >= leavers[p.Name] then p.Parent = nil end
            end
        end },
    }, { __index = _G })
    env.table = { clear = function(t) for k in pairs(t) do t[k] = nil end end }
    assert(load(block, "startMatch drop window", "t", env))()
    check(clock == want and env.dropSelect == false, string.format("%s: the window lasts %d s (want %d)", label, clock, want))
end
scenario("two players pick at 3 s and 6 s", { A = 3, B = 6 }, {}, 6)
scenario("one player picks at 1 s", { A = 0.5 }, {}, 1)
scenario("one picks at 2 s, the other never", { A = 2, B = false }, {}, seconds)
scenario("one picks at 2 s, the other leaves at 4 s without picking", { A = 2, B = false }, { B = 4 }, 4)
return out
"""


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua_args = [lua.table_from(a) if isinstance(a, dict) else a for a in args]
    try:
        result = lua.execute(code, *lua_args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def all_rows(sources):
    src, cfg_src = sources[MATCH], sources[CONFIG]
    rows = []
    cfg = {k: number(cfg_src, k) for k in ("Intermission", "IntermissionAllReady", "LobbyCountdown",
                                            "AllReadyCountdown", "MinPlayers", "DropSelectSeconds")}
    try:
        start = between(src, "function MatchService.Start()", "\nreturn MatchService")
        body = between(start, "\t\t\ttask.wait(1)\n", "\n\t\tend\n\tend)\nend") \
            .replace("\t\t\ttask.wait(1)\n", "", 1)
        # The regen / participation parts of the loop need a match; the lobby states never reach them.
        rows += run_lua(LOOP, luau_to_lua(body), cfg)
    except ValueError as exc:
        rows.append((False, "loop: source shape changed: %s" % exc))
    try:
        snippet = between(src, "\t\tstate = \"Intermission\"\n", "\n\t\tfor _, player in ipairs(Players:GetPlayers()) do")
        rows += run_lua(BREAK, luau_to_lua(snippet))
    except ValueError as exc:
        rows.append((False, "break: source shape changed: %s" % exc))
    try:
        begin = between(src, "local function startMatch()", "\nend\n")
        block = between(begin, "\tif currentMode.dropSelect then\n", "\n\tlocal thisMatch = matchId")
        rows += run_lua(DROP, luau_to_lua(block), cfg["DropSelectSeconds"])
    except ValueError as exc:
        rows.append((False, "drop: source shape changed: %s" % exc))
    return rows


PLANTS = [
    ("the break doesn't open the vote (the old code)", MATCH,
     "once everyone was ready.\n\t\tVoteService.Open()\n", "once everyone was ready.\n"),
    ("the countdown re-rolls an open vote", MATCH,
     "\t\t\t\t\tif not VoteService.IsOpen() then\n\t\t\t\t\t\tVoteService.Open()\n\t\t\t\t\tend\n",
     "\t\t\t\t\tVoteService.Open()\n"),
    ("a cancelled countdown closes the vote again", MATCH,
     "\t\t\t\t\tstate = \"Waiting\"\n\t\t\t\t\tcountdown = 0\n\t\t\t\telse",
     "\t\t\t\t\tstate = \"Waiting\"\n\t\t\t\t\tcountdown = 0\n\t\t\t\t\tVoteService.Close()\n\t\t\t\telse"),
    ("the break never skipped", CONFIG, "MatchConfig.IntermissionAllReady = 5", "MatchConfig.IntermissionAllReady = 35"),
    ("the break skipped to nothing", MATCH, "\t\t\t\t\tcountdown = MatchConfig.IntermissionAllReady\n", "\t\t\t\t\tcountdown = 1\n"),
    ("skipped when anyone is ready", MATCH, "present > 0 and #readyPlayers() >= present", "#readyPlayers() > 0"),
    ("the drop window never ends early", MATCH, "\t\t\tif not waiting then\n\t\t\t\tbreak\n", "\t\t\tif false then\n\t\t\t\tbreak\n"),
    ("a leaver holds the drop window open", MATCH,
     "if player.Parent and participants[player] and not chosenDrop[player] then", "if not chosenDrop[player] then"),
    ("the drop window ends on the first pick", MATCH,
     "\t\t\t\t\twaiting = true\n\t\t\t\t\tbreak\n", "\t\t\t\t\twaiting = next(chosenDrop) == nil\n\t\t\t\t\tbreak\n"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: open(os.path.join(root, rel), encoding="utf-8").read() for rel in (MATCH, CONFIG)}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in all_rows(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"lobby_flow_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"lobby_flow_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
