"""Record the guns' per-gun z-fight nudge counts as the new baseline, deliberately.

tools/runtest.ps1 builds every gun and counts the parts the gun builder's own z-fight pass had to nudge
("nudged at build"). The flush count after that pass can't show a design that gained coplanar faces, because
the pass hides them, so the run also compares each gun's count with tools/gun_nudge_baseline.json and
reports every gun that grew past it (and every gun with no recorded count). The run only reads that file.

After reviewing a run, and agreeing that a gun's growth is intended or that a drop should be locked in,
record its counts with:

    python tools/update_gun_nudge_baseline.py <runtest output file> --note "why"

This reads the "[BRR_AutoRun] zfight guns nudged per gun: id=n,..." line from that output (the last one, if
there are several) and rewrites tools/gun_nudge_baseline.json with those counts, the date, the source file
and the note. Commit to the change on purpose: never point this at a run you haven't read.
"""
import datetime
import json
import pathlib
import re
import sys

LINE = re.compile(r"\[BRR_AutoRun\] zfight guns nudged per gun: ([^\r\n]*)")


def main(argv):
    args = list(argv)
    note = ""
    if "--note" in args:
        index = args.index("--note")
        if index + 1 >= len(args):
            print("--note needs a reason")
            return 2
        note = args[index + 1]
        del args[index:index + 2]
    if len(args) != 1:
        print(__doc__)
        return 2
    source = pathlib.Path(args[0])
    text = source.read_text(encoding="utf-8", errors="replace")
    found = LINE.findall(text)
    if not found:
        print(f"no per-gun nudge line in {source}")
        return 1
    guns = {}
    for item in found[-1].split(","):
        item = item.strip()
        if not item:
            continue
        name, _, value = item.partition("=")
        if not re.fullmatch(r"[A-Za-z0-9_]+", name) or not value.strip().isdigit():
            print(f"unreadable entry {item!r}; nothing written")
            return 1
        guns[name] = int(value)
    if not guns:
        print("the per-gun line was empty; nothing written")
        return 1
    target = pathlib.Path(__file__).with_name("gun_nudge_baseline.json")
    previous = {}
    if target.exists():
        previous = json.loads(target.read_text(encoding="utf-8")).get("guns", {})
    data = {
        "about": "Parts each gun's build z-fight pass nudges, as last recorded on purpose. Read by tools/runtest.ps1; "
                 "written only by tools/update_gun_nudge_baseline.py.",
        "recorded": datetime.date.today().isoformat(),
        "source": str(source),
        "note": note,
        "guns": dict(sorted(guns.items())),
    }
    target.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    changed = sorted(name for name in set(guns) | set(previous) if guns.get(name) != previous.get(name))
    print(f"wrote {target}: {len(guns)} guns, {len(changed)} changed from the previous record")
    for name in changed:
        print(f"  {name}: {previous.get(name)} -> {guns.get(name)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
