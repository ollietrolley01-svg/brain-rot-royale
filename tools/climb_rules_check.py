"""Check: the Cloud Climb summit pays only a climb, never a teleport.

Pulls the REAL clear rules out of LobbyService.lua (the block from `local CLIMB_TOP_SPEED` to the
ClearClimb comment: climbFloors, climbCheckpointCounts, climbSummitVerdict), runs them under lupa on
the REAL CloudClimbCourse.lua and MatchConfig's speeds, and drives them with runs:

  honest       an impossibly good climber: straight lines through every jump's easiest crossing at
               plain sprint speed, touching each element as it lands. Must clear.
  top speed    the same at a hair under CLIMB_TOP_SPEED (the floor's own speed). Must clear.
  to summit    starts a run, teleports onto the summit disc. Must not clear.
  quick chain  starts a run, teleports onto each checkpoint half a second apart, then the summit.
  slow summit  teleports through the checkpoints at once, waits out the summit's floor, then the summit.
  summit rush  reaches every checkpoint at top speed, then teleports from the last onto the summit.
  skip one     reaches checkpoints 2 and 3 at honest times but never 1, then the summit at an honest time.

PLANTED FAULTS (permanent): the summit's checkpoint rule, the summit's floor, the checkpoint order and
the checkpoint floor, each removed. Each must turn the check red.

Run: python3 tools/climb_rules_check.py   (exit 0 = clean pass and every fault caught)
"""
import math
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("climb_rules_check: needs lupa (pip install lupa)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOBBY = os.path.join(ROOT, "ServerScriptService", "Modules", "LobbyService.lua")
COURSE = os.path.join(ROOT, "ServerScriptService", "Modules", "CloudClimbCourse.lua")
CONFIG = os.path.join(ROOT, "ReplicatedStorage", "Shared", "MatchConfig.lua")


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def luau_to_lua(source):
    # x += y  ->  x = x + (y)   (the only Luau-only syntax the block uses)
    return re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + (\3)", source, flags=re.M)


def section(source):
    start = source.index("local CLIMB_TOP_SPEED")
    end = source.index("-- A match ends a climb run")
    return source[start:end]


def speeds():
    text = read(CONFIG)
    walk = float(re.search(r"MatchConfig\.BaseWalkSpeed = ([\d.]+)", text).group(1))
    sprint = float(re.search(r"MatchConfig\.SprintMultiplier = ([\d.]+)", text).group(1))
    return walk, sprint


LOADER = r"""
local block, course, walk, sprint = ...
local env = setmetatable({ MatchConfig = { BaseWalkSpeed = walk, SprintMultiplier = sprint } }, { __index = _G })
local fn = assert(load(block .. "\nreturn climbFloors, climbCheckpointCounts, climbSummitVerdict, CLIMB_TOP_SPEED", "rules", "t", env))
local floors, counts, verdict, top = fn()
local courseTable = assert(load(course, "course"))()
local api = { floors = floors(courseTable), top = top, course = courseTable }
-- One touch at a time. `run` is a Lua table so the rules can write to it as the game's do.
function api.newRun(started) return { started = started } end
function api.checkpoint(run, number, name, now)
    if counts(run, number, api.floors[name], now) then
        run.checkpoint = number
        return true
    end
    return false
end
function api.summit(run, checkpoints, now)
    local seconds, why = verdict(run, checkpoints, api.floors.Summit, now)
    return { seconds = seconds, why = why }
end
return api
"""


def arrivals(course, speed):
    """Element name -> when a straight-line climber at `speed` lands on it, from the first fork's takeoff."""
    out, t, last = {}, 0.0, None
    jumps = [course.jumps[i] for i in range(1, len(course.jumps) + 1)]
    for index, jump in enumerate(jumps):
        if index == 0:
            continue
        a, b = jump["from"], jump["to"]
        if last is not None:
            t += math.hypot(a[1] - last[1], a[3] - last[3]) / speed
        t += math.hypot(b[1] - a[1], b[3] - a[3]) / speed
        last = b
        out[jump.name.split(" -> ")[1]] = t
    return out


def scenarios(lobby_src):
    walk, sprint = speeds()
    lua = LuaRuntime(unpack_returned_tuples=True)
    api = lua.execute(LOADER, luau_to_lua(section(lobby_src)), read(COURSE), walk, sprint)
    course = api.course
    checkpoints = []
    for i in range(1, len(course.elements) + 1):
        e = course.elements[i]
        if e.checkpoint:
            checkpoints.append((e.checkpoint, e.name))
    total = len(checkpoints)
    violations, notes = [], []
    notes.append(f"{total} checkpoints; floors: " + ", ".join(
        f"{name} {api.floors[name]:.1f}s" for _, name in checkpoints) + f", Summit {api.floors['Summit']:.1f}s"
        f" (CLIMB_TOP_SPEED {api.top:.1f})")
    if total < 1 or api.floors["Summit"] is None or api.floors["Summit"] <= 0:
        violations.append("the floors are empty: the block read nothing from the course")

    def climb(label, touches, summit_at, want_clear):
        run = api.newRun(0.0)
        for number, name, at in touches:
            api.checkpoint(run, number, name, at)
        result = api.summit(run, total, summit_at)
        seconds, why = result.seconds, result.why
        cleared = seconds is not None
        notes.append(f"{label}: {'CLEARED in %.1fs' % seconds if cleared else 'refused (skipped %s)' % why}")
        if cleared != want_clear:
            violations.append(f"{label}: {'cleared' if cleared else 'refused'}, want {'a clear' if want_clear else 'refused'}")

    # A hair under the floor's own speed: at exactly CLIMB_TOP_SPEED the result hangs on rounding.
    for label, speed in (("honest", walk * sprint), ("top speed", api.top * 0.999)):
        at = arrivals(course, speed)
        climb(label, [(n, name, at[name]) for n, name in checkpoints], at["Summit"], True)
    climb("to summit", [], 0.5, False)
    climb("quick chain", [(n, name, 0.5 * i) for i, (n, name) in enumerate(checkpoints, 1)], 0.5 * (total + 1), False)
    climb("slow summit", [(n, name, 0.1) for n, name in checkpoints], api.floors["Summit"] + 1, False)
    at = arrivals(course, walk * sprint)
    top = arrivals(course, api.top * 0.999)
    last = checkpoints[-1][1]
    climb("summit rush", [(n, name, top[name]) for n, name in checkpoints], top[last] + 0.5, False)
    climb("skip one", [(n, name, at[name]) for n, name in checkpoints[1:]], at["Summit"], False)
    return violations, notes


MUTANTS = {
    "summit ignores checkpoints": ("if (run.checkpoint or 0) < checkpoints then", "if false then"),
    "summit floor removed": ("if seconds < (floor or 0) then", "if false then"),
    "checkpoint order removed": ("number == (run.checkpoint or 0) + 1", "number > (run.checkpoint or 0)"),
    "checkpoint floor removed": ("and now - run.started >= (floor or 0)", ""),
}


def main():
    source = read(LOBBY)
    violations, notes = scenarios(source)
    for n in notes:
        print("  " + n)
    print(f"clean: {len(violations)} violations")
    for v in violations:
        print("  " + v)
    ok = not violations
    for label, (old, new) in MUTANTS.items():
        if old not in section(source):
            print(f"FAIL: planted fault '{label}' could not be applied (source changed; update the mutant)")
            ok = False
            continue
        bad, _ = scenarios(source.replace(old, new, 1))
        caught = len(bad) > 0
        print(f"planted fault '{label}': {'CAUGHT' if caught else 'MISSED'}" + (f", first: {bad[0]}" if bad else ""))
        ok = ok and caught
    print("climb_rules_check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
