"""Proof harness for AchievementData.lua (Task 02).

    python tools/achievement_check.py .

Parses ReplicatedStorage/Shared/AchievementData.lua's List directly, plus the live totals a
lifetime achievement must never exceed: Rarity.Order (how many rarity sets exist), BrainrotData's
full catalogue size, and WeaponData's masterable weapon count (every merged arsenal pack, minus
guns still `staged = true`). Nothing here is hand-typed: if any of those source tables grow or
shrink, the bounds this script checks against move with them.

No Lua runtime is available outside Studio, so this is regex parsing over the source text, in the
same style tools/verify.py already uses elsewhere in this repo.

Exit code is 0 only if every check passes AND the planted-fault self-test actually fired — a
green run where the self-test didn't fire means the check stopped working, not that everything
is fine.
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def parse_achievements(src):
    block = re.search(r"AchievementData\.List = \{\n(.*?)\n\}\n", src, re.S).group(1)
    raw_count = len(re.findall(r'\{ id = "', block))
    entries = []
    for m in re.finditer(
        r'\{ id = "(\w+)", name = "([^"]+)", title = "([^"]+)", stat = "(\w+)", '
        r'target = (\d+), coins = (\d+),\s*description = "([^"]*)" \},',
        block, re.S,
    ):
        id_, name, title, stat, target, coins, desc = m.groups()
        entries.append({
            "id": id_, "name": name, "title": title, "stat": stat,
            "target": int(target), "coins": int(coins), "description": desc,
        })
    return entries, raw_count


def rarity_count():
    src = read("ReplicatedStorage/Shared/Rarity.lua")
    order = re.search(r"Rarity\.Order = \{([^}]*)\}", src).group(1)
    return len(re.findall(r'"(\w+)"', order))


def brainrot_total():
    src = read("ReplicatedStorage/Shared/BrainrotData.lua")
    return len(re.findall(r'\{ name = "[^"]+", rarity = "\w+"', src))


def masterable_weapon_count():
    base = read("ReplicatedStorage/Shared/WeaponData.lua")
    own = re.search(r"WeaponData\.Weapons = \{\n(.*?)\n\}", base, re.S)
    total = len(re.findall(r"^\t\w+ = \{", own.group(1), re.M)) if own else 0
    for pack in ("ArsenalExpansion", "CreativeArsenal", "WorkshopArsenal"):
        text = read(f"ReplicatedStorage/Shared/{pack}.lua")
        block = re.search(r"Pack\.Weapons = \{\n(.*?)\n\}\n", text, re.S)
        if not block:
            continue
        segments = re.split(r"^\t(\w+) = \{\n", block.group(1), flags=re.M)[1:]
        for i in range(0, len(segments), 2):
            entry_body = segments[i + 1]
            if "staged = true" not in entry_body:
                total += 1
    return total


# Stats whose target is bounded by a real, countable total elsewhere in the game. A target above
# the bound asks a player to do something the game currently has no way to satisfy — the
# invariant this whole harness exists to catch, not any one achievement's specific number.
def bounded_stats():
    rarities, brainrots, weapons = rarity_count(), brainrot_total(), masterable_weapon_count()
    return {
        "sets": ("rarity sets", rarities),
        "discovered": ("brainrots in the catalogue", brainrots),
        "mastered": ("masterable weapons", weapons),
        "rotmasters": ("masterable weapons", weapons),
    }


def check_duplicate_ids(entries):
    ids = [e["id"] for e in entries]
    dupes = sorted({i for i in ids if ids.count(i) > 1})
    return len(entries), dupes


def check_reward_currency(entries):
    problems = []
    for e in entries:
        if not isinstance(e["coins"], int) or e["coins"] <= 0:
            problems.append(f"{e['id']}: coins reward {e['coins']!r} is not a positive integer")
    return len(entries), problems


def check_reachable(entries, bounds):
    examined, problems = 0, []
    for e in entries:
        bound = bounds.get(e["stat"])
        if not bound:
            continue
        examined += 1
        label, total = bound
        if e["target"] > total:
            problems.append(f"{e['id']}: target {e['target']} exceeds {total} {label} — unreachable")
    return examined, problems


def run_all(entries, bounds, label):
    print(f"== {label} ==")
    n, dupes = check_duplicate_ids(entries)
    print(f"duplicate ids: {n} examined, {len(dupes)} flagged" + (f" {dupes}" if dupes else ""))
    n, bad_rewards = check_reward_currency(entries)
    print(f"reward currency: {n} examined, {len(bad_rewards)} flagged")
    for p in bad_rewards:
        print("  " + p)
    n, unreachable = check_reachable(entries, bounds)
    print(f"reachability (bounded stats): {n} examined, {len(unreachable)} flagged")
    for p in unreachable:
        print("  " + p)
    return not dupes and not bad_rewards and not unreachable


def main():
    src = read("ReplicatedStorage/Shared/AchievementData.lua")
    entries, raw_count = parse_achievements(src)
    if len(entries) != raw_count:
        sys.exit(f"achievement_check: parsed {len(entries)} entries but the file has {raw_count} "
                  f"'{{ id = ' openers — the parser missed one, fix the regex before trusting this run")

    bounds = bounded_stats()
    print(f"live bounds: {bounds['sets'][1]} rarities, {bounds['discovered'][1]} brainrots, "
          f"{bounds['mastered'][1]} masterable weapons")
    print()

    clean = run_all(entries, bounds, f"real data: {len(entries)} achievements")
    print()

    # Permanent planted fault. This must never pass: an achievement asking to discover more
    # brainrots than the game currently has. Aimed at the invariant ("a target may never exceed
    # what the game can produce"), not at any specific past bug, so it can't expire when a bug is
    # fixed — the synthetic entry is fabricated fresh on every run.
    planted = dict(entries[0])
    planted.update(id="__planted_fault__", stat="discovered", target=bounds["discovered"][1] + 50)
    faulty_entries = entries + [planted]
    print(f"== planted fault: discovered target set to {planted['target']} (bound is {bounds['discovered'][1]}) ==")
    n, unreachable = check_reachable(faulty_entries, bounds)
    fired = any("__planted_fault__" in p for p in unreachable)
    print(f"reachability (bounded stats): {n} examined, {len(unreachable)} flagged, planted fault fired: {fired}")
    for p in unreachable:
        print("  " + p)
    print()

    if not fired:
        sys.exit("achievement_check: FAIL — the planted fault did not fire; the reachability check is not testing anything")
    if not clean:
        sys.exit("achievement_check: FAIL — real data has a problem (see above)")
    print(f"achievement_check: OK — {len(entries)} achievements, 0 problems, planted fault fired as expected")


if __name__ == "__main__":
    main()
