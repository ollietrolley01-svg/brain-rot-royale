"""Proof harness for BrainrotCodex.lua (Task 03).

    python tools/codex_check.py .

BrainrotCodex is flavour text keyed by the name in BrainrotData.Types. Nothing reads it yet, so
the only things that can be proven about it from outside Studio are the ones that will still be
true after it is wired up:

  correspondence  every brainrot has exactly one entry, and the codex names no brainrot that
                  does not exist. This is the one that matters: the catalogue is edited by other
                  people, and an entry list that silently drifts from it is a blank panel in game.
  length          no entry exceeds BrainrotCodex.MaxLength, read from the Lua rather than typed
                  here, so moving the limit moves the check with it.
  no duplicates   two brainrots with the same line is a copy-paste, never a choice.
  no placeholders TODO / TBD / lorem / an empty string shipping as finished text.
  voice           one full stop at the end, no exclamation marks, and an entry never repeats the
                  name of its own brainrot (the row above it already shows that).

No Lua runtime is available outside Studio, so this is regex parsing over the source text, in the
same style tools/verify.py and tools/achievement_check.py already use in this repo.

Exit code is 0 only if every check passes AND all five planted faults fired. A green run where a
planted fault did not fire means the check stopped working, not that everything is fine.
"""
import re
import sys
import pathlib

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def catalogue_names():
    """Every brainrot name in BrainrotData.Types, in file order, with duplicates kept."""
    src = read("ReplicatedStorage/Shared/BrainrotData.lua")
    block = src.split("BrainrotData.Types = {", 1)[1]
    return re.findall(r'\{ name = "([^"]+)", rarity = "\w+"', block)


def parse_codex():
    """(entries, raw_count, max_length) from BrainrotCodex.lua.

    raw_count is counted separately from the parse so a regex that quietly misses a line is
    caught rather than reported as a smaller codex.
    """
    src = read("ReplicatedStorage/Shared/BrainrotCodex.lua")
    limit = int(re.search(r"BrainrotCodex\.MaxLength = (\d+)", src).group(1))
    block = src.split("BrainrotCodex.Entries = {", 1)[1].split("\n}\n", 1)[0]
    raw_count = len(re.findall(r'^\t\["', block, re.M))
    entries = re.findall(r'^\t\["([^"]+)"\] = "(.*)",$', block, re.M)
    return entries, raw_count, limit


# ---------------------------------------------------------------------------
# The checks. Each returns (examined, problems) so a clean sweep still reports
# how many candidates it looked at.
# ---------------------------------------------------------------------------

def check_correspondence(names, entries):
    keys = [k for k, _ in entries]
    seen = set(keys)
    problems = []
    for name in names:
        if name not in seen:
            problems.append(f"{name!r}: in BrainrotData.Types, no codex entry")
    catalogue = set(names)
    for key in keys:
        if key not in catalogue:
            problems.append(f"{key!r}: codex entry for a brainrot that is not in BrainrotData.Types")
    dupes = sorted({k for k in keys if keys.count(k) > 1})
    for key in dupes:
        problems.append(f"{key!r}: keyed twice in the codex")
    return len(names) + len(keys), problems


def check_length(entries, limit):
    problems = []
    for name, text in entries:
        if len(text) > limit:
            problems.append(f"{name!r}: {len(text)} characters, limit is {limit}")
    return len(entries), problems


def check_duplicates(entries):
    texts = [t for _, t in entries]
    problems = []
    for name, text in entries:
        if texts.count(text) > 1:
            problems.append(f"{name!r}: shares its line with another entry")
    return len(entries), problems


PLACEHOLDERS = ("todo", "tbd", "fixme", "lorem", "xxx", "placeholder", "write me", "tk tk")


def check_placeholders(entries):
    problems = []
    for name, text in entries:
        low = text.lower()
        if not text.strip():
            problems.append(f"{name!r}: empty")
            continue
        for marker in PLACEHOLDERS:
            if marker in low:
                problems.append(f"{name!r}: placeholder text ({marker!r})")
                break
    return len(entries), problems


def check_voice(entries):
    problems = []
    for name, text in entries:
        if not text.endswith("."):
            problems.append(f"{name!r}: does not end in a full stop")
        if "!" in text:
            problems.append(f"{name!r}: exclamation mark")
        if name.lower() in text.lower():
            problems.append(f"{name!r}: repeats its own name")
    return len(entries), problems


def run_all(names, entries, limit, label):
    print(f"== {label} ==")
    clean = True
    for title, (examined, problems) in (
        ("correspondence with BrainrotData.Types", check_correspondence(names, entries)),
        (f"length (limit {limit})", check_length(entries, limit)),
        ("duplicate lines", check_duplicates(entries)),
        ("placeholder text", check_placeholders(entries)),
        ("voice (full stop, no !, no self-naming)", check_voice(entries)),
    ):
        print(f"{title}: {examined} examined, {len(problems)} flagged")
        for p in problems[:10]:
            print("  " + p)
        if len(problems) > 10:
            print(f"  ... and {len(problems) - 10} more")
        clean = clean and not problems
    return clean


# Permanent planted faults. Each is aimed at an invariant this file must refuse forever, not at a
# bug that exists today, so none of them expires when the codex is finished. All five are
# fabricated in memory on every run — nothing on disk is touched.
def planted_faults(names, entries, limit):
    first = entries[0][0]
    return [
        ("a brainrot with no entry",
         names, [e for e in entries if e[0] != first], limit, check_correspondence_only),
        ("an entry for a brainrot that does not exist",
         names, entries + [("Brainrot That Does Not Exist", "A fabricated name.")], limit,
         check_correspondence_only),
        (f"an entry of {limit + 1} characters",
         names, entries + [(first, "A" * limit + ".")], limit, check_length_only),
        ("two brainrots sharing one line",
         names, entries + [("Second Copy", entries[0][1])], limit, check_duplicates_only),
        ("a TODO left in a line",
         names, entries + [("Unwritten", "TODO: write this one.")], limit, check_placeholders_only),
    ]


def check_correspondence_only(names, entries, limit):
    return check_correspondence(names, entries)


def check_length_only(names, entries, limit):
    return check_length(entries, limit)


def check_duplicates_only(names, entries, limit):
    return check_duplicates(entries)


def check_placeholders_only(names, entries, limit):
    return check_placeholders(entries)


def main():
    names = catalogue_names()
    entries, raw_count, limit = parse_codex()
    if len(entries) != raw_count:
        sys.exit(f"codex_check: parsed {len(entries)} entries but the file has {raw_count} "
                 f"'[\"' openers — the parser missed one, fix the regex before trusting this run")

    longest_name, longest = max(entries, key=lambda e: len(e[1]))
    print(f"catalogue: {len(names)} brainrots in BrainrotData.Types")
    print(f"codex: {len(entries)} entries, longest {len(longest)}/{limit} chars ({longest_name})")
    print()

    clean = run_all(names, entries, limit, f"real data: {len(entries)} codex entries")
    print()

    all_fired = True
    for label, f_names, f_entries, f_limit, check in planted_faults(names, entries, limit):
        _, problems = check(f_names, f_entries, f_limit)
        fired = bool(problems)
        all_fired = all_fired and fired
        print(f"planted fault [{label}]: fired: {fired}" + (f" — {problems[0]}" if problems else ""))
    print()

    if not all_fired:
        sys.exit("codex_check: FAIL — a planted fault did not fire; that check is not testing anything")
    if not clean:
        sys.exit("codex_check: FAIL — real data has a problem (see above)")
    print(f"codex_check: OK — {len(entries)} entries, 0 problems, 5 planted faults fired as expected")


if __name__ == "__main__":
    main()
