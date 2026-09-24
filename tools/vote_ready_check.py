"""Check: a player who votes and then un-readies no longer picks the match.

Runs the real ServerScriptService/Modules/VoteService.lua under lupa with Players, Remotes, GameModes,
MapData and Random stubbed. Stand-in players carry a server-side "Ready" attribute and fire its
changed signal the way a Player does.

Scenarios:
  signal     A and B vote card 1, C votes card 2, then A and B un-ready. Resolve() must pick card 2,
             and the clients must have been told (a broadcast after the un-ready shows card 1 at 0).
  no signal  The same, but the attribute changes without its signal firing (the tally has to hold on
             its own, as it does for a probe's stand-in).
  control    Nobody un-readies: card 1 wins 2-1.

PLANTED FAULTS (permanent): the tally's readiness check removed, and the un-ready watcher removed.
Each must turn the check red.

Run: python3 tools/vote_ready_check.py   (exit 0 = clean pass and every fault caught)
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("vote_ready_check: needs lupa (pip install lupa)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "ServerScriptService", "Modules", "VoteService.lua")


def luau_to_lua(source):
    # x += y  ->  x = x + y   (the only Luau-only syntax this file uses)
    return re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + \3", source, flags=re.M)


HARNESS = r"""
local source = ...
local function signal()
    local fns = {}
    return { Connect = function(_, fn) table.insert(fns, fn) end,
             Fire = function(_, ...) for _, fn in ipairs(fns) do fn(...) end end }
end
local playerAdded, playerRemoving = signal(), signal()
local Players = { PlayerAdded = playerAdded, PlayerRemoving = playerRemoving,
    GetPlayers = function() return {} end }
local function child(name)
    return { Name = name, WaitForChild = function(_, n) return child(n) end }
end
game = { GetService = function(_, name) if name == "Players" then return Players end return child(name) end }
table.clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
Random = { new = function() return { NextInteger = function(_, a, b) return a end } end }

local broadcasts = {}
local stubs = {
    GameModes = {
        Get = function(id) return { name = id } end,
        Describe = function(mode) return { name = mode.name } end,
    },
    MapData = { Order = { "Bay", "Hills", "Docks" },
        Get = function(id) return { name = id, description = "", radius = 1 } end },
    Remotes = { Event = function() return { FireAllClients = function(_, snap) table.insert(broadcasts, snap) end } end },
}
require = function(inst) return stubs[inst.Name] end

local VoteService = load(source, "VoteService")()
local api = { Vote = VoteService }
function api.player(userId)
    local attrs = { Ready = true }
    local changed = signal()
    local p = { UserId = userId, Name = "P" .. userId }
    function p:GetAttribute(k) return attrs[k] end
    function p:GetAttributeChangedSignal(k) return changed end
    function p:SetReady(value, fire)
        attrs.Ready = value
        if fire then changed:Fire() end
    end
    playerAdded:Fire(p)
    return p
end
-- The votes card `id` shows in the latest broadcast.
function api.shown(id)
    local last = broadcasts[#broadcasts]
    for _, c in ipairs(last.candidates) do if c.id == id then return c.votes end end
end
return api
"""


def scenarios(source):
    violations, notes = [], []
    for label, unready, fire in (("signal", True, True), ("no signal", True, False), ("control", False, False)):
        lua = LuaRuntime(unpack_returned_tuples=True)
        api = lua.execute(HARNESS, source)
        a, b, c = api.player(1), api.player(2), api.player(3)
        api.Vote.Open()
        cards = api.Vote.GetCandidates()
        one, two = cards[1], cards[2]
        for p, card in ((a, one), (b, one), (c, two)):
            ok, msg = api.Vote.CastVote(p, card.id)
            if not ok:
                violations.append(f"{label}: a readied vote was refused ({msg})")
        if unready:
            a.SetReady(a, False, fire)
            b.SetReady(b, False, fire)
        _, mode = api.Vote.Resolve()
        want = one.modeId if not unready else two.modeId
        notes.append(f"{label}: resolved {mode} (want {want}); card 1 shows {api.shown(one.id)} in the last broadcast")
        if mode != want:
            violations.append(f"{label}: the match went to {mode}, want {want}"
                              + (" -- un-readied votes still counted" if unready else ""))
        if fire and api.shown(one.id) != 0:
            violations.append(f"{label}: the clients still show {api.shown(one.id)} vote(s) on card 1 after its voters un-readied")
    return violations, notes


MUTANTS = {
    "tally's readiness check removed": ("if counts[id] and isReady(token) then", "if counts[id] then"),
    "un-ready watcher removed": ("\t\tif not isReady(player) then\n\t\t\tVoteService.Forget(player)\n\t\tend\n", ""),
}


def main():
    with open(SOURCE, encoding="utf-8") as f:
        source = luau_to_lua(f.read())
    violations, notes = scenarios(source)
    for n in notes:
        print("  " + n)
    print(f"clean: {len(violations)} violations")
    for v in violations:
        print("  " + v)
    ok = not violations
    for label, (old, new) in MUTANTS.items():
        if old not in source:
            print(f"FAIL: planted fault '{label}' could not be applied (source changed; update the mutant)")
            ok = False
            continue
        bad, _ = scenarios(source.replace(old, new, 1))
        caught = len(bad) > 0
        print(f"planted fault '{label}': {'CAUGHT' if caught else 'MISSED'}" + (f", first: {bad[0]}" if bad else ""))
        ok = ok and caught
    print("vote_ready_check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
