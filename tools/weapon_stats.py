"""Read every weapon's stats out of the Lua data files and print what balance actually turns on.

Why this exists: the numbers were being pulled out with ad-hoc regexes of the form
`(\\w+) = \\{(.{0,900}?)\\n\\t\\}`, which stops at a fixed character count and at the first `\\n\\t}` it
meets. A weapon whose entry is long, or which contains a nested table, runs past that window and the
fields of the NEXT weapon get read as its own. That produced four wrong "before" figures in a shotgun
proposal, so the fix is a parser that matches braces instead of guessing a length.

    python tools/weapon_stats.py .                 every gun, by tier
    python tools/weapon_stats.py . --style shotgun only shotguns
    python tools/weapon_stats.py . --tier Secret   only one tier

Columns: burst is damage x pellets (one full hit), DPS is burst x fireRate, head is burst x
headshotMultiplier, and `hip@10` is roughly how much of a hip-fired burst lands on a two-stud torso at
ten studs, given the spread cone. The one-shot column is the gate that matters: health 100 plus shield
100 is a 200 pool, and `body`/`head` say which of those a single hit can end.
"""
import math
import pathlib
import re
import sys

FILES = [
    "ReplicatedStorage/Shared/WeaponData.lua",
    "ReplicatedStorage/Shared/ArsenalExpansion.lua",
    "ReplicatedStorage/Shared/CreativeArsenal.lua",
    "ReplicatedStorage/Shared/WorkshopArsenal.lua",
]
FULL_POOL = 200
FRESH = 100
TIERS = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]


def entries(src):
    """Every `\\n\\tName = {` table in a Lua source, brace-matched to its own closing brace."""
    found = {}
    for m in re.finditer(r"\n\t(\w+) = \{", src):
        depth, i = 1, m.end()
        while i < len(src) and depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        found.setdefault(m.group(1), src[m.end():i - 1])
    return found


def number(body, key, default=None):
    m = re.search(r"\b" + key + r" = (-?[\d.]+)", body)
    return float(m.group(1)) if m else default


def text(body, key, default=None):
    m = re.search(r"\b" + key + r' = "([^"]*)"', body)
    return m.group(1) if m else default


def on_target(damage, pellets, spread, distance, torso=1.0):
    """Roughly what a burst lands: pellets scatter in a cone, the torso is a disc of `torso` studs."""
    radius = distance * math.tan(math.radians(spread))
    share = 1.0 if radius <= torso else min(1.0, (torso / radius) ** 2)
    return damage * pellets * share


def guns(root):
    out = {}
    for name in FILES:
        path = pathlib.Path(root) / name
        if not path.exists():
            continue
        for gid, body in entries(path.read_text(encoding="utf-8")).items():
            damage, rate = number(body, "damage"), number(body, "fireRate")
            if damage is None or rate is None:
                continue
            out[gid] = {
                "file": name.rsplit("/", 1)[-1],
                "name": text(body, "name", gid),
                "tier": text(body, "rarity", "?"),
                "style": text(body, "style", "?"),
                "damage": damage,
                "rate": rate,
                "pellets": int(number(body, "pellets", 1)),
                "head": number(body, "headshotMultiplier", 1.0),
                "spread": number(body, "spread", 0.0),
                "range": number(body, "range", 0.0),
                "staged": "staged = true" in body,
            }
    return out


def self_test():
    """A planted table the old regex got wrong: a long entry with a nested table inside it."""
    planted = (
        '\n\tPlantedOne = {\n\t\tname = "Planted One",\n\t\trarity = "Rare",\n\t\tdamage = 11,\n'
        '\t\tpellets = 7,\n\t\tfireRate = 2,\n\t\tnested = {\n\t\t\tinner = 1,\n\t\t},\n'
        "\t\tspread = 5,\n\t},\n"
        '\n\tPlantedTwo = {\n\t\tname = "Planted Two",\n\t\tdamage = 99,\n\t\tfireRate = 1,\n\t},\n'
    )
    got = entries(planted)
    problems = []
    if set(got) != {"PlantedOne", "PlantedTwo"}:
        problems.append(f"expected both planted entries, got {sorted(got)}")
    else:
        one = got["PlantedOne"]
        if number(one, "damage") != 11:
            problems.append(f"PlantedOne damage read as {number(one, 'damage')}, want 11")
        if number(one, "spread") != 5:
            problems.append("PlantedOne's spread, written after a nested table, was not read")
        if "99" in one:
            problems.append("PlantedOne's body ran on into PlantedTwo -- the brace matching is wrong")
    return problems


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    args = sys.argv[1:]
    want_style = args[args.index("--style") + 1].lower() if "--style" in args else None
    want_tier = args[args.index("--tier") + 1].lower() if "--tier" in args else None

    problems = self_test()
    if problems:
        for line in problems:
            print("SELF-TEST FAILED: " + line)
        return 1
    print("self-test: nested tables and run-on entries both caught")

    rows = guns(root)
    print(f"{'gun':26} {'tier':10} {'style':10} {'dmg':>5} {'pel':>4} {'burst':>6} {'DPS':>7} "
          f"{'head':>6} {'spr':>5} {'rng':>5} {'hip@10':>7}  one-shot")
    for tier in TIERS + ["?"]:
        if want_tier and tier.lower() != want_tier:
            continue
        group = [(gid, g) for gid, g in rows.items() if g["tier"] == tier
                 and (not want_style or g["style"].lower() == want_style)]
        for gid, g in sorted(group, key=lambda kv: kv[1]["damage"] * kv[1]["pellets"] * kv[1]["rate"]):
            burst = g["damage"] * g["pellets"]
            head = burst * g["head"]
            shot = []
            if burst >= FULL_POOL:
                shot.append("body through shield")
            elif burst >= FRESH:
                shot.append("body")
            if head >= FULL_POOL:
                shot.append("head through shield")
            elif head >= FRESH:
                shot.append("head")
            hip = on_target(g["damage"], g["pellets"], g["spread"], 10) if g["spread"] else burst
            print(f"{gid:26} {g['tier']:10} {g['style']:10} {g['damage']:5.0f} {g['pellets']:4d} "
                  f"{burst:6.0f} {burst * g['rate']:7.1f} {head:6.0f} {g['spread']:5.1f} {g['range']:5.0f} "
                  f"{hip:7.0f}  {', '.join(shot) or '-'}{'  STAGED' if g['staged'] else ''}")
    print(f"{len(rows)} guns read from {len(FILES)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
