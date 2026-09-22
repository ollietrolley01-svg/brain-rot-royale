"""Checks the Task 03 codex DRAFT against the brainrot names in BrainrotData.lua.

Usage: python brainrot-descriptions-check.py <repo-root> [draft.lua]

THIS CHECKS THE DRAFT FILE BESIDE IT. It proves nothing about BrainrotData.lua, which has no
description field on this tree; it only proves the draft is complete, in bounds and clean for the
day the field exists.

Asserts, for every brainrot name in BrainrotData.lua:
  - the draft has a description for it, and has no description for a name that is not in the data
  - the description is not empty, not a placeholder, and is a single line
  - it is at most LIMIT characters (derivation below)
  - no two descriptions are the same line (case- and whitespace-insensitive)
  - style: ends in a full stop, no exclamation mark, the name is not repeated in its own line

Permanent planted faults run every time, each a mutation of the REAL draft text fed through the
SAME parse-and-check pipeline as the real input. Each is aimed at an invariant the check must
refuse forever, not at any specific line.
"""
import re
import sys
import os

# The Codex subtitle slot, MenuClient.client.lua:398 (main e0b3aa6):
#   Size = UDim2.new(1, -220 - rightReserve, 0, 18), Font Gotham, TextSize 12, TextTruncate AtEnd
# On an 844x390 landscape phone the shell's content is 724 px (MenuShell.lua:219-221, :307), the
# row is content - 8 (:373), and an OWNED row reserves 100 (:371; the Robux button never shows in
# the live game because every BrainrotProductIds entry is 0, GamepassConfig.lua:286-288).
#   724 - 8 - 220 - 100 = 396 px.
# At a pessimistic 5.2 px per character for Gotham/Montserrat at TextSize 12 (an ASSUMPTION from
# font metrics, not a measurement; see the PR body): 396 / 5.2 = 76.15 -> 76 characters.
SLOT_PX = 396
PX_PER_CHAR = 5.2
LIMIT = int(SLOT_PX // PX_PER_CHAR)

PLACEHOLDERS = ("todo", "tbd", "tba", "lorem", "xxx", "???", "placeholder", "description here",
                "fixme", "wip")


def strip_comments(src):
    """Removes Lua comments and NOTHING else. String literals come through untouched, because
    the thing being checked IS the string. (verify.py's _strip_lua blanks every string, which is
    right for finding code and fatal here.)"""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'":
            q = c
            j = i + 1
            while j < n and src[j] != q:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
            continue
        m = re.match(r"--\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            i = n if j < 0 else j + len(close)
            continue
        if src.startswith("--", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_draft(text):
    """[(name, description)] in file order, duplicates of a key kept so they can be reported."""
    return [(m.group(1), m.group(2)) for m in
            re.finditer(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', strip_comments(text))]


def parse_names(text):
    """Every `{ name = "..."` entry in BrainrotData.Types, in order."""
    text = strip_comments(text)
    m = re.search(r"BrainrotData\.Types\s*=\s*\{(.*?)\n\}", text, re.S)
    body = m.group(1) if m else ""
    return re.findall(r'\{\s*name\s*=\s*"([^"]+)"\s*,\s*rarity\s*=', body)


def check(draft_text, data_text):
    """Returns (problems, stats). Everything, real or planted, goes through here."""
    names = parse_names(data_text)
    entries = parse_draft(draft_text)
    problems = []
    if not names:
        problems.append("no brainrot names found in the data file; the check has nothing to check")
    seen_keys = {}
    for name, desc in entries:
        if name in seen_keys:
            problems.append(f"{name}: described twice in the draft")
        seen_keys[name] = desc
    name_set = set(names)
    for name in names:
        if name not in seen_keys:
            problems.append(f"{name}: no description in the draft")
    for name in seen_keys:
        if name not in name_set:
            problems.append(f"{name}: in the draft but not in BrainrotData.Types")

    longest = (0, "")
    normalised = {}
    for name, desc in entries:
        d = desc.strip()
        if not d:
            problems.append(f"{name}: empty description")
            continue
        if "\n" in desc or "\\n" in desc or "\t" in desc:
            problems.append(f"{name}: description is not a single line")
        low = d.lower()
        for p in PLACEHOLDERS:
            # Whole words only: "tba" is inside "meatball" and "wip" is inside "wipe".
            if re.search(r"(?<![a-z])" + re.escape(p) + r"(?![a-z])", low):
                problems.append(f"{name}: placeholder text left behind ({p!r})")
                break
        if len(d) > LIMIT:
            problems.append(f"{name}: {len(d)} chars, over the {LIMIT} the Codex slot can show")
        if len(d) > longest[0]:
            longest = (len(d), name)
        key = re.sub(r"\s+", " ", low)
        if key in normalised:
            problems.append(f"{name}: duplicate of {normalised[key]}'s line")
        else:
            normalised[key] = name
        if not d.endswith("."):
            problems.append(f"{name}: does not end in a full stop")
        if "!" in d:
            problems.append(f"{name}: exclamation mark")
        if name.lower() in low:
            problems.append(f"{name}: repeats its own name in the line")
    stats = {"names": len(names), "described": sum(1 for n in names if n in seen_keys),
             "longest": longest}
    return problems, stats


# Planted faults: (label, mutate(draft_text) -> draft_text). Each mutates the real draft text and
# the result is parsed by the same parse_draft the real run uses. A needle handed to check() by
# any other route would prove a detector that works on a route nothing uses.
def _first_entry(text):
    m = re.search(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"((?:[^"\\]|\\.)*)"', strip_comments(text))
    return m.group(1), m.group(2)


def _replace_desc(text, name, new_desc):
    pat = r'(\["%s"\]\s*=\s*)"(?:[^"\\]|\\.)*"' % re.escape(name)
    out, n = re.subn(pat, lambda m: m.group(1) + '"' + new_desc + '"', text, count=1)
    assert n == 1, f"planted mutation found no entry for {name}"
    return out


def _plant_overlong(text):
    name, desc = _first_entry(text)
    return _replace_desc(text, name, desc[:-1] + " and then some more words to overflow the slot.")


def _plant_duplicate(text):
    entries = parse_draft(text)
    (a, da), (b, _) = entries[0], entries[1]
    return _replace_desc(text, b, da.upper())  # case-insensitive: must still be caught


def _plant_placeholder(text):
    name, _ = _first_entry(text)
    return _replace_desc(text, name, "TODO write this one.")


def _plant_empty(text):
    name, _ = _first_entry(text)
    return _replace_desc(text, name, "")


def _plant_missing(text):
    name, _ = _first_entry(text)
    return re.sub(r'\n\s*\["%s"\]\s*=\s*"(?:[^"\\]|\\.)*",' % re.escape(name), "", text, count=1)


def _plant_orphan(text):
    return text.replace("\nreturn {", '\nreturn {\n\t["Not A Brainrot"] = "An entry for a name that does not exist.",', 1)


def _plant_no_full_stop(text):
    name, desc = _first_entry(text)
    return _replace_desc(text, name, desc.rstrip("."))


def _plant_commented_out(text):
    # An entry hidden behind a comment must count as MISSING, not as present: this is the fault
    # a string-blanking stripper would never see and a comment-blind parser would wrongly accept.
    name, _ = _first_entry(text)
    return re.sub(r'\n(\s*\["%s"\])' % re.escape(name), r"\n\t-- \1", text, count=1)


PLANTED = [
    ("over the limit", _plant_overlong),
    ("duplicate line (case changed)", _plant_duplicate),
    ("placeholder text", _plant_placeholder),
    ("empty description", _plant_empty),
    ("entry missing", _plant_missing),
    ("entry for a name not in the data", _plant_orphan),
    ("no full stop", _plant_no_full_stop),
    ("entry commented out", _plant_commented_out),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    draft_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                      "brainrot-descriptions-DRAFT.lua")
    data_path = os.path.join(root, "ReplicatedStorage", "Shared", "BrainrotData.lua")
    with open(draft_path, encoding="utf-8") as f:
        draft_text = f.read()
    with open(data_path, encoding="utf-8") as f:
        data_text = f.read()

    problems, stats = check(draft_text, data_text)

    caught = 0
    for label, mutate in PLANTED:
        planted_problems, _ = check(mutate(draft_text), data_text)
        # The planted run must report MORE than the real run: a fault that adds nothing was missed.
        if len(planted_problems) > len(problems):
            caught += 1
        else:
            problems.append(f"planted fault NOT caught: {label}; the check is testing nothing")

    length, name = stats["longest"]
    print(f"codex draft: {stats['described']}/{stats['names']} brainrots described, "
          f"longest {length}/{LIMIT} chars ({name}), planted {caught}/{len(PLANTED)} caught")
    print("\n".join(problems) if problems else "OK: draft clean")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
