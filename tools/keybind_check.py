"""Keybinds: no two actions may default to the same key.

    python tools/keybind_check.py .

Several tabs add entries to StarterPlayerScripts/Settings.lua, and a default that collides with another
one is invisible until a player presses it and two things happen. Studio can't catch this: Settings is a
client module and client scripts never run in the harness, so this reads the table as text.

It also reports every key still free, which is what you actually want when adding an action.

Exit code 1 on a collision, so it can sit in the same pass as the other static checks.
"""

import re
import sys
from pathlib import Path

SETTINGS = Path("StarterPlayerScripts/Settings.lua")
# The rows look like: { id = "Crouch", label = "...", default = "C", group = "Combat" },
ROW = re.compile(r'\{\s*id\s*=\s*"([A-Za-z0-9_]+)"[^}]*?default\s*=\s*"([A-Za-z0-9]+)"[^}]*?\}')

# Keys the game binds outside the Settings table, which an action must not default onto either.
RESERVED = {
    "Space": "jump (the humanoid's own)",
    "W": "move", "A": "move", "S": "move", "D": "move",
    "Tab": "Roblox's player list",
    "Escape": "Roblox's menu",
    "Slash": "Roblox's chat",
}


def main(root: str) -> int:
    path = Path(root) / SETTINGS
    if not path.exists():
        print(f"keybind check: {SETTINGS} not found")
        return 1
    text = path.read_text(encoding="utf-8")

    seen: dict[str, list[str]] = {}
    for action, key in ROW.findall(text):
        # Only keyboard defaults: the toggles and sliders in the same file use booleans and numbers.
        if key in ("true", "false") or key.isdigit():
            continue
        seen.setdefault(key, []).append(action)

    findings = []
    for key, actions in sorted(seen.items()):
        if len(actions) > 1:
            findings.append(f"{key} is the default for {len(actions)} actions: {', '.join(actions)}")
        if key in RESERVED:
            findings.append(f"{key} is taken by {RESERVED[key]}, but {', '.join(actions)} defaults to it")

    for line in findings:
        print(f"keybind COLLISION: {line}")

    letters = [chr(c) for c in range(ord("A"), ord("Z") + 1)]
    free = [k for k in letters if k not in seen and k not in RESERVED]
    print(f"keybind check: {len(seen)} bound keys across {sum(len(a) for a in seen.values())} actions, "
          f"{len(findings)} collisions")
    print(f"  free letters: {' '.join(free) if free else '(none)'}")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
