"""Task 18: how long the team matches can last, read from the real source.

    python tools/team_match_length_check.py .                   the report and the invariants; exits 1 on a failure
    python tools/team_match_length_check.py . --log FILE        also reads a team_match_length_probe.lua log
    python tools/team_match_length_check.py . --plant           the planted faults; exits 1 if any is missed

Reads GameModes.Modes (both team modes' scoreTarget and timeLimit), MatchConfig.TeamModeRewards.matchSeconds
and the objective count in ModeKingOfTheHill (LETTERS), and reports each team mode's target, clock and
fastest possible end. With git, the same numbers at origin/main are printed as BEFORE.

Invariants, each with a planted fault that must turn it red:
  1. SIZED      every team mode's timeLimit equals TeamModeRewards.matchSeconds, the clock the result pay and
                the per-match caps are sized for. A clock moved alone changes pay an hour.
  2. STEAMROLL  one side holding every objective cannot end Objective Capture in under STEAMROLL_SECONDS.
  3. REACHABLE  Objective Capture's target can be reached before the clock by a side holding every objective,
                and Team Deathmatch's within TDM_HEADROOM times what the measured leading side scores in the
                clock. Past that the target is decoration and nothing but the clock can end a match.
  4. EARLY      at the measured pace, Team Deathmatch runs its full clock: the target is more than the leading
                side scores in it. Otherwise the target is what cuts the match short, the bug in the report.
  5. STALE      no doc, comment or check stub still names the old length: "8 minutes", "8-minute", "8 of play",
                or a team-mode timeLimit stub that disagrees with the real one.
"""
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from economy_model import lua_table  # noqa: E402  (the same Lua table reader the economy model uses)

GAME_MODES = "ReplicatedStorage/Shared/GameModes.lua"
MATCH_CONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"
KOTH = "ServerScriptService/Modules/ModeKingOfTheHill.lua"
TEAM_MODES = ("TeamDeathmatch", "KingOfTheHill")
SHOWN = {"TeamDeathmatch": "TDM", "KingOfTheHill": "Objective Capture"}

# Swept for the old length (invariant 4): the docs, the reward config and its comments, the HUD comment, and
# the check that stubs the team modes.
STALE_FILES = (
    "README.md", "ECONOMY.md", MATCH_CONFIG, GAME_MODES, "StarterPlayerScripts/ModeScoreHud.client.lua",
    "StarterPlayerScripts/VoteScreen.lua", "tools/team_rewards_check.py", "tools/economy_model.py",
)
STALE_TEXT = re.compile(r"\b8[- ]minutes?\b|\b8 of play\b|\beight minutes\b", re.I)
STUB = re.compile(r'(TeamDeathmatch|KingOfTheHill) = \{ id = "\1".*?timeLimit = (\d+)')

# The shortest a steamroll may make Objective Capture: three minutes. Task 18 moved it from 125 s to 200 s.
STEAMROLL_SECONDS = 180

# Team Deathmatch's measured scoring rate: team kills a minute by the side that led at the end, 15 bots a
# side (BotFillTarget 30), no player, all shipped rules. Source: tools/team_match_length_probe.lua in the
# Linux Studio harness, 2026-09-26 03:00 UTC, this branch: 75-79 after the full 720 s, so 79 / 12 min.
# One match, bots only: a lobby with real players may score faster. --log replaces it with the log's own.
MEASURED_TDM_LEAD_KPM = 79 / 12
MEASURED_FROM = "one bots-only Studio match, 75-79 in 720 s (team_match_length_probe.lua, 2026-09-26)"
# How far past the measured pace the TDM target may sit and still be a target: a side scoring three times
# as fast as the bot lobby's leader must still be able to finish on score.
TDM_HEADROOM = 3


def read_texts(root, ref=None):
    """{path: text} of every file this check reads, from the working tree or from git `ref`."""
    out = {}
    for rel in (GAME_MODES, MATCH_CONFIG, KOTH) + STALE_FILES:
        if ref:
            r = subprocess.run(["git", "-C", str(root), "show", f"{ref}:{rel}"], capture_output=True, text=True)
            if r.returncode:
                continue
            out[rel] = r.stdout
        else:
            path = pathlib.Path(root) / rel
            if path.exists():
                out[rel] = path.read_text(encoding="utf-8")
    return out


def limits(texts):
    """{mode: (target, clock)}, the pay's matchSeconds, and the objective count."""
    modes = lua_table(texts[GAME_MODES], r"^GameModes\.Modes = \{", GAME_MODES)
    out = {m: (modes[m]["scoreTarget"], modes[m]["timeLimit"]) for m in TEAM_MODES}
    rewards = lua_table(texts[MATCH_CONFIG], r"^MatchConfig\.TeamModeRewards = \{", MATCH_CONFIG)
    letters = re.search(r"^local LETTERS = \{([^}]*)\}", texts[KOTH], re.M)
    objectives = len(re.findall(r'"[^"]*"', letters.group(1)))
    return out, rewards.get("matchSeconds"), objectives


def read_log(path):
    """Per team mode in the probe log: ticks [(elapsed, a, b)], and the end line's fields."""
    runs = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.search(r"\[TML\] start mode=(\w+) target=(\d+) timeLimit=(\d+)", line)
        if m:
            runs[m.group(1)] = {"target": int(m.group(2)), "clock": int(m.group(3)), "ticks": [], "end": None}
            continue
        m = re.search(r"\[TML\] tick mode=(\w+) scores=(\d+)-(\d+) secondsLeft=(-?[\d.]+)", line)
        if m and m.group(1) in runs:
            r = runs[m.group(1)]
            r["ticks"].append((r["clock"] - float(m.group(4)), int(m.group(2)), int(m.group(3))))
            continue
        m = re.search(r"\[TML\] end mode=(\w+) scores=(\d+)-(\d+) target=(\d+) timeLimit=(\d+) secondsLeft=(-?[\d.]+)", line)
        if m and m.group(1) in runs:
            r = runs[m.group(1)]
            a, b, target, left = int(m.group(2)), int(m.group(3)), int(m.group(4)), float(m.group(6))
            r["end"] = {"a": a, "b": b, "elapsed": r["clock"] - max(left, 0),
                        "reason": "score" if max(a, b) >= target else ("time" if left <= 1 else "other")}
    return runs


def evaluate(texts, lead_kpm):
    """(report lines, failures)."""
    rows, sized, objectives = limits(texts)
    report, failures = [], []
    for mode, (target, clock) in rows.items():
        if mode == "KingOfTheHill":
            fastest = target / objectives
            how = f"{fastest:.0f} s, one side holding all {objectives} objectives"
            if fastest < STEAMROLL_SECONDS:
                failures.append(f"STEAMROLL: {SHOWN[mode]} can end in {fastest:.0f} s (< {STEAMROLL_SECONDS})")
            if fastest > clock:
                failures.append(f"REACHABLE: {SHOWN[mode]} needs {fastest:.0f} s holding everything; the clock is {clock}")
        else:
            need = target / clock * 60
            if lead_kpm:
                at = target / lead_kpm * 60
                paced = lead_kpm * clock / 60
                how = (f"{at:.0f} s at the measured {lead_kpm:.1f} kills/min, so the clock ends it near"
                       f" {paced:.0f} kills (needs {need:.1f}/min to finish on score)")
                if target <= paced:
                    failures.append(f"EARLY: {SHOWN[mode]} reaches {target} in {at:.0f} s at the measured"
                                    f" {lead_kpm:.1f} kills/min, before the {clock} s clock")
                if target > TDM_HEADROOM * paced:
                    failures.append(f"REACHABLE: {SHOWN[mode]} target {target} is over {TDM_HEADROOM}x the {paced:.0f}"
                                    f" the measured leader scores in {clock} s")
            else:
                how = f"when one side reaches {target} ({need:.1f} kills/min to beat the clock)"
        report.append(f"  {SHOWN[mode]:18} target {target:>4}  clock {clock:>4} s ({clock / 60:.0f} min)  fastest end: {how}")
        if sized != clock:
            failures.append(f"SIZED: {mode} timeLimit {clock}, TeamModeRewards.matchSeconds {sized}")
    report.append(f"  TeamModeRewards.matchSeconds = {sized}")

    lines = hits = 0
    for rel in STALE_FILES:
        text = texts.get(rel, "")
        for n, line in enumerate(text.splitlines(), 1):
            lines += 1
            if STALE_TEXT.search(line):
                hits += 1
                failures.append(f"STALE: {rel}:{n}: {line.strip()[:110]}")
        for m in STUB.finditer(text):
            if int(m.group(2)) != rows[m.group(1)][1]:
                hits += 1
                failures.append(f"STALE: {rel}: stub {m.group(1)} timeLimit {m.group(2)}, the real one {rows[m.group(1)][1]}")
    report.append(f"  stale-length sweep: {len(STALE_FILES)} files, {lines} lines examined, {hits} flagged")
    return report, failures


def plant(texts, lead_kpm):
    """Each fault is aimed at an invariant and must fail; the unplanted tree must pass."""
    _, clean = evaluate(texts, lead_kpm)
    rows, _, _ = limits(texts)
    (tdm_t, tdm_c), (obj_t, obj_c) = rows["TeamDeathmatch"], rows["KingOfTheHill"]

    def swap(rel, old, new):
        if texts[rel].count(old) != 1:
            raise SystemExit(f"plant: {old!r} is not unique in {rel}")
        t = dict(texts)
        t[rel] = t[rel].replace(old, new)
        return t

    tdm = f"scoreTarget = {tdm_t},\n\t\ttimeLimit = {tdm_c},"
    obj = f"scoreTarget = {obj_t},\n\t\ttimeLimit = {obj_c},"
    faults = [
        ("SIZED", "TDM's clock doubled without its pay", swap(GAME_MODES, tdm, f"scoreTarget = {tdm_t},\n\t\ttimeLimit = {tdm_c * 2},")),
        ("STEAMROLL", "Objective Capture's target back to 250", swap(GAME_MODES, obj, f"scoreTarget = 250,\n\t\ttimeLimit = {obj_c},")),
        ("STEAMROLL", "a third objective at the same target", swap(KOTH, 'local LETTERS = { "A", "B" }', 'local LETTERS = { "A", "B", "C" }')),
        ("REACHABLE", "Objective Capture's target past two objectives' clock",
         swap(GAME_MODES, obj, f"scoreTarget = {obj_c * 2 + 2},\n\t\ttimeLimit = {obj_c},")),
        ("STALE", "README says 8 minutes again", swap("README.md", "or 12 minutes;", "or 8 minutes;")),
        ("STALE", "the rewards check's stub keeps the old clock",
         swap("tools/team_rewards_check.py", f'respawnDelay = 5, scoreTarget = 100000, timeLimit = {tdm_c},',
              "respawnDelay = 5, scoreTarget = 100000, timeLimit = 480,")),
    ]
    if lead_kpm:
        paced = lead_kpm * tdm_c / 60
        faults.append(("REACHABLE", "a TDM target the clock never reaches at the measured rate",
                       swap(GAME_MODES, tdm, f"scoreTarget = {int(paced * TDM_HEADROOM) + 1},\n\t\ttimeLimit = {tdm_c},")))
        faults.append(("EARLY", "a TDM target the measured pace reaches before the clock",
                       swap(GAME_MODES, tdm, f"scoreTarget = {int(paced * 0.8)},\n\t\ttimeLimit = {tdm_c},")))
    caught = 0
    for kind, label, t in faults:
        _, failures = evaluate(t, lead_kpm)
        hit = [f for f in failures if f.startswith(kind + ":")]
        caught += bool(hit)
        print(f"  {'CAUGHT' if hit else 'MISSED'}: {label} ({hit[0] if hit else 'nothing flagged'})")
    ok = caught == len(faults) and not clean
    print(f"team_match_length_check plant: {caught} of {len(faults)} planted faults caught; unplanted tree"
          f" {'clean' if not clean else 'NOT clean: ' + '; '.join(clean)}")
    return ok


def main():
    args = sys.argv[1:]
    log = args[args.index("--log") + 1] if "--log" in args else None
    root = next((a for a in args if not a.startswith("--") and a != log), ".")
    texts = read_texts(root)
    lead_kpm, source = MEASURED_TDM_LEAD_KPM, MEASURED_FROM
    if "--log" in args:
        runs = read_log(log)
        print("PROBE LOG (tools/team_match_length_probe.lua)")
        for mode, r in runs.items():
            e = r["end"]
            if not e:
                print(f"  {SHOWN.get(mode, mode)}: started, no end line")
                continue
            minutes = e["elapsed"] / 60
            print(f"  {SHOWN.get(mode, mode):18} ended on {e['reason'].upper()} after {e['elapsed']:.0f} s: {e['a']}-{e['b']}"
                  f" (target {r['target']}, clock {r['clock']} s); leader {max(e['a'], e['b']) / minutes:.1f}/min,"
                  f" both sides {(e['a'] + e['b']) / minutes:.1f}/min")
            for t, a, b in r["ticks"]:
                print(f"      {t:5.0f} s  {a:>3}-{b:<3}")
            if mode == "TeamDeathmatch":
                lead_kpm, source = max(e["a"], e["b"]) / minutes, "the log above"
    before = read_texts(root, "origin/main")
    if GAME_MODES in before and MATCH_CONFIG in before and KOTH in before:
        print("BEFORE (origin/main)")
        print("\n".join(evaluate(before, lead_kpm)[0][:len(TEAM_MODES) + 1]))
    print("AFTER (this tree)")
    report, failures = evaluate(texts, lead_kpm)
    print("\n".join(report))
    print(f"  TDM kill rate: {'%.1f kills/min by the leading side' % lead_kpm if lead_kpm else 'none'} ({source})")
    if "--plant" in args:
        sys.exit(0 if plant(texts, lead_kpm) else 1)
    for f in failures:
        print("  FAIL: " + f)
    print(f"team_match_length_check: {len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
