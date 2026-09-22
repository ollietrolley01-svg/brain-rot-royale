"""How legible a brainrot's rarity is from the model itself.

    python tools/brainrot_rarity_audit.py .

Pure text over BrainrotData and BrainrotModels -- no Studio, no render -- so the claim "a Legendary
does not look rarer than a Common" can be checked in a second and re-checked after any change.

What it measures, and why each one:

  * bodies shared with the low rarities. A top-rarity creature built on a body shape that Commons
    also use has nothing in its silhouette that says "rare" before you read the label.
  * distinct body+extras silhouettes per rarity, which is the counter-argument: extras may already
    be carrying the distinctiveness that the body shape does not.
  * `look.size` per rarity -- the size ladder, if there is one.
  * whether that ladder is VISIBLE where players actually look. `BrainrotModels.FrameViewport` pulls
    the camera back by exactly `size`, so a bigger creature fills the same fraction of a card. A
    ladder that is cancelled by its own framing is not a ladder; it only shows in the world, at the
    shoulder or on a podium.

It prints numbers and takes no view on what the ladder SHOULD be: that is Oliver's call.
"""
import collections
import io
import os
import re
import sys

ORDER = ["Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret"]
LOW = ("Common", "Uncommon")


def main(root):
    data = io.open(os.path.join(root, "ReplicatedStorage/Shared/BrainrotData.lua"), encoding="utf-8").read()
    models = io.open(os.path.join(root, "ReplicatedStorage/Shared/BrainrotModels.lua"), encoding="utf-8").read()

    entries = re.findall(
        r'\{ name = "([^"]+)", rarity = "(\w+)".*?\n\s*look = \{ body = "(\w+)"(.*?)\} \},', data, re.S)
    if not entries:
        print("no brainrots parsed -- the shape of BrainrotData.lua has changed; fix this audit")
        return 1
    by_rarity = collections.OrderedDict((r, []) for r in ORDER)
    for name, rarity, body, rest in entries:
        by_rarity.setdefault(rarity, []).append((name, body, rest))

    low_bodies = {b for r in LOW for _, b, _ in by_rarity.get(r, [])}
    print("%d brainrots parsed\n" % len(entries))
    print("rarity     |  n | bodies | shares a body with a Common/Uncommon | distinct body+extras")
    for rarity in ORDER:
        rows = by_rarity.get(rarity, [])
        if not rows:
            continue
        bodies = [b for _, b, _ in rows]
        shared = sum(1 for b in bodies if b in low_bodies)
        combos = set()
        for _, body, rest in rows:
            found = re.search(r"extras = \{([^}]*)\}", rest)
            combos.add((body, tuple(sorted(re.findall(r'"(\w+)"', found.group(1)))) if found else ()))
        print("%-10s | %2d | %6d | %2d of %-2d %-27s| %d of %d"
              % (rarity, len(rows), len(set(bodies)), shared, len(rows), "", len(combos), len(rows)))

    print("\nrarity     | creatures with look.size | min   mean  max")
    for rarity in ORDER:
        rows = by_rarity.get(rarity, [])
        if not rows:
            continue
        sizes = []
        have = 0
        for _, _, rest in rows:
            found = re.search(r"size = ([0-9.]+)", rest)
            if found:
                have += 1
                sizes.append(float(found.group(1)))
            else:
                sizes.append(1.0)
        print("%-10s | %2d of %-2d                | %.2f  %.3f %.2f"
              % (rarity, have, len(rows), min(sizes), sum(sizes) / len(sizes), max(sizes)))

    # Is the ladder visible on a card? Only if the framing does NOT scale with it.
    frame = re.search(r"function BrainrotModels\.FrameViewport.*?\nend", models, re.S)
    body = frame.group(0) if frame else ""
    cancels = bool(re.search(r"local d = .*\* size", body))
    print("\nFrameViewport pulls the camera back by `size`: %s" % ("YES" if cancels else "no"))
    if cancels:
        print("  -> every viewport framed by it (menu photos, podium, companion, crate reveal) shows")
        print("     the same apparent size whatever look.size says. The ladder only exists in world")
        print("     space, where the camera is not framed to the model.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
