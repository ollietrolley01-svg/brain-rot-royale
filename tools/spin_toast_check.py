"""The Daily Spin's "X spun Y" toast reaches the lobby only (findings C6).

    python3 tools/spin_toast_check.py .            the checks
    python3 tools/spin_toast_check.py . --plant    the planted faults; every one must be caught

LobbyService.SpinWitnesses is cut out of the source and run in lupa over a server of: the spinner, two
players in the lobby, a player in a match, a spectator (still InMatch), and a player whose InMatch was
never written. The broadcast site in buildDailySpin must notify exactly SpinWitnesses' list, and no
other Notify in that function may reach anyone but the spinner.

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("spin_toast_check: needs lupa (pip install lupa)")

LOBBY = "ServerScriptService/Modules/LobbyService.lua"


def cut(src, head):
    a = src.index(head)
    line_start = src.rfind("\n", 0, a) + 1
    indent = src[line_start:a]
    b = src.index("\n" + indent + "end\n", a) + len(indent) + 5
    return src[line_start:b]


HARNESS = r"""
local src = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local env = setmetatable({ LobbyService = {} }, { __index = _G })
assert(load(src, "LobbyService.SpinWitnesses", "t", env))()
local function player(name, inMatch)
    local p = { Name = name, attrs = { InMatch = inMatch } }
    function p:GetAttribute(k) return self.attrs[k] end
    return p
end
local spinner = player("Spinner", false)
local lobbyA, lobbyB = player("LobbyA", false), player("LobbyB", nil)
local fighter, spectator = player("Fighter", true), player("Spectator", true)
local got = env.LobbyService.SpinWitnesses(spinner, { spinner, lobbyA, fighter, lobbyB, spectator })
local names = {}
for _, p in ipairs(got) do names[p.Name] = true end
check(names.LobbyA and names.LobbyB, "players in the lobby hear it (InMatch false, or never written)")
check(not names.Fighter and not names.Spectator, "players in a match, spectators included, do not")
check(not names.Spinner, "the spinner gets their own message, not the broadcast")
check(#got == 2, "exactly the two lobby players (" .. #got .. ")")
return out
"""


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        result = lua.execute(code, *args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def all_rows(src):
    try:
        rows = run_lua(HARNESS, cut(src, "function LobbyService.SpinWitnesses("))
        spin = cut(src, "local function buildDailySpin(")
    except ValueError as exc:
        return [(False, "source shape changed: %s" % exc)]
    loops = re.findall(r"for _, (\w+) in ipairs\(([^\n]*)\) do\n\s*StateSync\.Notify\((\w+),", spin)
    rows.append((any(v == target and "LobbyService.SpinWitnesses(player, Players:GetPlayers())" in over
                     for v, over, target in loops),
                 "buildDailySpin broadcasts to SpinWitnesses' list"))
    others = [m for m in re.findall(r"StateSync\.Notify\((\w+)", spin) if m != "player"]
    rows.append((len(others) == 1, "...and nowhere else but the spinner (%d other Notify site(s))" % len(others)))
    rows.append(("FireAllClients" not in re.sub(r"playgroundFx:FireAllClients", "", spin),
                 "no other all-clients message from the wheel"))
    return rows


PLANTS = [
    ("everyone hears it (the old broadcast)", "if other ~= spinner and other:GetAttribute(\"InMatch\") ~= true then",
     "if other ~= spinner then"),
    ("the spinner hears it twice", "if other ~= spinner and other:GetAttribute(\"InMatch\") ~= true then",
     "if other:GetAttribute(\"InMatch\") ~= true then"),
    ("the broadcast goes round the helper", "ipairs(LobbyService.SpinWitnesses(player, Players:GetPlayers()))",
     "ipairs(Players:GetPlayers())"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = open(os.path.join(root, LOBBY), encoding="utf-8").read()
    if "--plant" in sys.argv:
        caught = 0
        for label, old, new in PLANTS:
            if src.count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            failed = [line for ok, line in all_rows(src.replace(old, new)) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"spin_toast_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(src)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"spin_toast_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
