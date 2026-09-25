"""The os.clock ratchet (BUG HUNT tab, 2026-09-21). Oliver: "sweep EVERY GAME, and EVERY UPDATE."

    python tools/clock_ratchet.py .        -> clock ratchet: N files at baseline, 0 over, 0 new

WHY A RATCHET AND NOT A WALL. `lua_static_check.py`'s CLOCK_WALL_TIME rule (Jacob's, EXACT) finds
every os.clock() used as wall time: 34 files today. The rule is advisory, so a NEW one lands green;
made strict as-is it prints the whole backlog on its first run, and a linter whose first run
produces a hundred findings gets switched off. The ratchet makes the POPULATION strict without
making the backlog strict: today's count per file is recorded, and the count may only ever go DOWN.
A file that grows one fails. A file not on the list that gains one fails. A file that has been
burned down below its baseline ALSO fails, asking for the baseline to be lowered -- otherwise the
ratchet silently loosens as the work is done, which is the one way a ratchet stops ratcheting.

WHY THE COUNTS AND NOT THE LINES. Line numbers move on every edit, so a line-keyed baseline would
need rewriting for changes that have nothing to do with clocks and would be ignored within a day.
A per-file count is coarse -- converting one site and adding another in the same file passes -- and
that is stated rather than hidden. The units check in verify.py covers the deadlines that have
already been converted, so the two together are: nothing new, and nothing converted goes back.

WHAT IS *NOT* COUNTED. tools/ is excluded by the rule itself (158 uses): a probe measuring CPU cost
is the legitimate use. os.clock() building a unique string, as in PlayerData's studio JobId, is a
false positive of the rule and is carried in the baseline rather than pretended away.
"""
import os
import re
import subprocess
import sys

# file -> how many wall-clock os.clock() sites the CLOCK_WALL_TIME rule reports for it today.
# LOWER these as they are converted; never raise one. Measured 2026-09-21 22:4x; set to the counts
# after the 2026-09-24 bug-hunt conversions (LobbyService included, converted by the economy fixes).
CLOCK_BASELINE = {
    "ReplicatedStorage/Shared/CosmeticPreview.lua": 0,
    "ReplicatedStorage/Shared/ZFight.lua": 1,
    "ServerScriptService/Bootstrap.server.lua": 3,
    "ServerScriptService/Modules/BotNav.lua": 0,
    # Not deadlines: the think loop's CPU-cost readings (`started`, `began`), which is what os.clock is
    # for. The bot timeline itself is tick(), shared with BotNav and CombatService's hit stamps.
    "ServerScriptService/Modules/BotService.lua": 2,
    "ServerScriptService/Modules/BrainrotShopService.lua": 1,
    "ServerScriptService/Modules/CombatService.lua": 1,
    "ServerScriptService/Modules/CompanionService.lua": 0,
    "ServerScriptService/Modules/DefenseService.lua": 1,
    "ServerScriptService/Modules/GlobalBoardService.lua": 2,
    "ServerScriptService/Modules/HazardService.lua": 0,
    "ServerScriptService/Modules/Landmarks.lua": 1,
    "ServerScriptService/Modules/LobbyService.lua": 0,
    "ServerScriptService/Modules/MapWilds.lua": 0,
    "ServerScriptService/Modules/MatchService.lua": 13,
    "ServerScriptService/Modules/MovementSanity.lua": 6,
    "ServerScriptService/Modules/MovementService.lua": 4,
    # The one remaining site is `tostring(os.clock())` building a Studio JobId. Nothing waits on
    # it; the six deadlines this file used to carry are converted (see its `wallNow`).
    "ServerScriptService/Modules/PlayerData.lua": 1,
    "ServerScriptService/Modules/ProgressionService.lua": 1,
    "ServerScriptService/Modules/RangeService.lua": 1,
    "ServerScriptService/Modules/StatusEffects.lua": 0,
    "ServerScriptService/Modules/TownThemes.lua": 1,
    "ServerScriptService/Modules/TradeService.lua": 0,
    "ServerScriptService/Modules/WeaponService.lua": 4,
    "StarterPlayerScripts/AmbientClient.client.lua": 1,
    "StarterPlayerScripts/CombatClient.client.lua": 7,
    "StarterPlayerScripts/CompanionFxClient.client.lua": 0,
    "StarterPlayerScripts/DefensePreview.lua": 1,
    "StarterPlayerScripts/GlassFxClient.client.lua": 0,
    "StarterPlayerScripts/HudClient.client.lua": 6,
    "StarterPlayerScripts/MenuClient.client.lua": 8,
    # Not deadlines: the reload marker's bob and the not-ready shake, `math.sin(os.clock() * k)`. A
    # phase that drifts under load is harmless, so they are carried here rather than converted.
    "StarterPlayerScripts/MountedGunClient.client.lua": 2,
    "StarterPlayerScripts/MovementClient.client.lua": 19,
    "StarterPlayerScripts/ProgressionPanel.lua": 6,
    "StarterPlayerScripts/ProjectileClient.client.lua": 12,
}

# `<file>:<line>: CLOCK_WALL_TIME os.clock (<n> wall-clock use(s) ...)`. The count is the number in
# the parenthesis, NOT the number of rows: the rule reports one row per file listing every line.
_ROW = re.compile(
    r"^(?P<file>[^\s:]+\.lua):\d+:\s+CLOCK_WALL_TIME\s+\S+\s+\((?P<count>\d+)\s+wall-clock")


def parse(output):
    """Output text in, {file: count} out. Its own guard: see `compare`, which refuses an empty
    parse against a non-empty baseline rather than reporting a clean codebase."""
    counts = {}
    for line in output.split("\n"):
        row = _ROW.match(line.strip())
        if row:
            counts[row.group("file").replace("\\", "/")] = int(row.group("count"))
    return counts


def compare(counts, baseline):
    """The whole judgement, in one function, so the planted needles below travel exactly the route
    the real input travels."""
    problems = []
    # THE PARSE GUARD. A regex that stops matching reports zero findings, and zero findings against
    # a real baseline reads as "every clock was converted" -- a check passing by reading nothing,
    # which is how a broken file once passed `2 sites, 0 findings`. Refuse it instead.
    if baseline and not counts:
        problems.append(
            "clock ratchet: parsed ZERO CLOCK_WALL_TIME rows while the baseline holds %d files. "
            "Either the rule's output format changed or it did not run -- this is NOT a clean "
            "codebase. Fix the parse before trusting this check." % len(baseline))
        return problems
    for path in sorted(set(counts) | set(baseline)):
        now, was = counts.get(path, 0), baseline.get(path, 0)
        if path not in baseline:
            problems.append(
                "clock ratchet: %s is NOT on the baseline and now has %d os.clock() deadline(s). "
                "os.clock() is CPU time in Roblox; a deadline on it runs long under load. Use "
                "tick(), or workspace:GetServerTimeNow() for a time sent to a client." % (path, now))
        elif now > was:
            problems.append(
                "clock ratchet: %s accepted %d os.clock() deadline(s) and now has %d. The backlog "
                "may only shrink. Convert the new one to tick() rather than adding to the pile."
                % (path, was, now))
        elif now < was:
            problems.append(
                "clock ratchet: %s accepted %d os.clock() deadline(s) and now has %d -- good, but "
                "lower its baseline in tools/clock_ratchet.py to %d so the ground stays won. A "
                "ratchet that is not tightened is a ratchet that has stopped."
                % (path, was, now, now))
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    checker = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lua_static_check.py")
    run = subprocess.run([sys.executable, checker, root, "--patterns-only"],
                         capture_output=True, text=True, errors="replace")
    counts = parse(run.stdout)
    problems = compare(counts, CLOCK_BASELINE)

    # PERMANENT PLANTED NEEDLES, all fed through `compare`, the function the real run uses. Written
    # against the invariant ("the backlog may only shrink"), not against any bug that a fix retires.
    base = {"A.lua": 2, "B.lua": 1}
    needles = [
        ("a file over its baseline", True, compare({"A.lua": 3, "B.lua": 1}, base)),
        ("a brand-new file with a deadline", True, compare({"A.lua": 2, "B.lua": 1, "C.lua": 1}, base)),
        ("a file burned down, baseline not lowered", True, compare({"A.lua": 1, "B.lua": 1}, base)),
        ("exactly the baseline (must NOT be flagged)", False, compare({"A.lua": 2, "B.lua": 1}, base)),
        # The podium needle: the parse breaks and the check must refuse, not report a clean tree.
        ("the parse returning nothing", True, compare({}, base)),
    ]
    caught = 0
    for label, must_flag, hits in needles:
        if bool(hits) == must_flag:
            caught += 1
        else:
            problems.append("clock ratchet: planted needle NOT behaving -- %s: expected %s, got %d."
                            % (label, "a finding" if must_flag else "no finding", len(hits)))
    # Name what entered the comparison, not just how many: a sample count alone is satisfied by the
    # wrong sample.
    print("clock ratchet: %d files on the baseline (%d sites), %d files parsed from the rule, "
          "%d/%d planted needles behaved"
          % (len(CLOCK_BASELINE), sum(CLOCK_BASELINE.values()), len(counts), caught, len(needles)))
    print("\n".join(problems) if problems else "OK: no problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
