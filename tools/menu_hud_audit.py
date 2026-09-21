"""Static audit of the menu and HUD layout. Usage: python tools/menu_hud_audit.py [project] [--md <file>]

Every screen in this game is built in code, so the layout can be read straight out of the source:
each `UiKit.create("Class", { ... })` call carries its Position, Size, Font, TextSize and colours as
literals. This walks those calls and reports what a design pass needs to know but can't count by eye:

  scale      elements sized or placed in raw pixels, and how many would fall off a phone screen
  type       every distinct Font and TextSize in use, and anything below the readable floor
  touch      buttons whose fixed size is under the 44 px touch target
  shape      every distinct corner radius, stroke and shadow
  colour     colours written as literals instead of taken from the UiKit palette
  motion     how many tweens, and every distinct duration and easing
  narrow     sizes written as `UDim2.new(1, -N, ...)` that go to zero or negative width on a narrow
             screen, where the label stops drawing entirely instead of truncating

It reports per file and per section (the `-- ---- / -- Title` banners the client scripts use), so
findings can be handed to whoever owns that section. It changes nothing: the numbers here are the
input to the design proposal, and the same run after a change shows what moved.
"""
import os
import re
import sys

ROOT = "."
MD = None
LUA = None
_args = sys.argv[1:]
_skip = False
for index, arg in enumerate(_args):
    if _skip:
        _skip = False
        continue
    if arg == "--md" and index + 1 < len(_args):
        MD = _args[index + 1]
        _skip = True
    elif arg == "--lua" and index + 1 < len(_args):
        # A Lua table of the HUD's clusters, for tools/menu_hud_gallery.lua to draw the layout maps
        # from the same numbers this audit reports.
        LUA = _args[index + 1]
        _skip = True
    elif not arg.startswith("--"):
        ROOT = arg

FILES = [
    "StarterPlayerScripts/HudClient.client.lua",
    "StarterPlayerScripts/MenuClient.client.lua",
    "StarterPlayerScripts/UiKit.lua",
    "StarterPlayerScripts/StaminaBar.lua",
    "StarterPlayerScripts/ProgressionPanel.lua",
    "StarterPlayerScripts/MergeDialog.lua",
    "StarterPlayerScripts/EventBanner.lua",
    "StarterPlayerScripts/MenuStackToggle.lua",
    "StarterPlayerScripts/InventoryPanel.lua",
    "StarterPlayerScripts/DefensePreview.lua",
    "StarterPlayerScripts/TouchControls.lua",
    "StarterPlayerScripts/CompanionAbilityIcon.lua",
]

# The smallest screens the game has to work on (the phone map the HUD & UX worker measured).
PHONE = (844, 390)
SMALLEST = (667, 360)
# Roblox's own top bar, and the thumb zones a phone player's hands cover.
TOP_BAR = 52
TOUCH_TARGET = 44
TEXT_FLOOR = 14


def read(rel):
    path = os.path.join(ROOT, rel)
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def sections(source):
    """Line number -> the section banner it falls under."""
    marks = []
    lines = source.split("\n")
    for index, line in enumerate(lines):
        if re.match(r"^-{10,}$", line.strip()) and index + 1 < len(lines):
            title = lines[index + 1].strip()
            if title.startswith("-- "):
                marks.append((index + 1, title[3:].strip()))
    return marks


def section_at(marks, line):
    name = "(top of file)"
    for at, title in marks:
        if at <= line:
            name = title
        else:
            break
    return name


def blocks(source):
    """Every create("Class", { ... }) call: (line, class, properties text)."""
    found = []
    for match in re.finditer(r'create\(\s*"(\w+)"\s*,\s*\{', source):
        start = match.end() - 1
        depth, index = 0, start
        while index < len(source):
            char = source[index]
            if char in "{([":
                depth += 1
            elif char in "})]":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        found.append((source.count("\n", 0, match.start()) + 1, match.group(1), source[start:index + 1]))
    return found


def prop(text, name):
    match = re.search(rf"\b{name}\s*=\s*([^\n,]+(?:,[^\n]*)?)", text)
    return match.group(1).strip().rstrip(",") if match else None


def udim2_offsets(text):
    """The pixel part of a UDim2: (x scale, x offset, y scale, y offset), or None."""
    if not text:
        return None
    match = re.match(r"UDim2\.fromOffset\(\s*([-\d.]+)\s*,\s*([-\d.]+)", text)
    if match:
        return (0.0, float(match.group(1)), 0.0, float(match.group(2)))
    match = re.match(r"UDim2\.fromScale\(\s*([-\d.]+)\s*,\s*([-\d.]+)", text)
    if match:
        return (float(match.group(1)), 0.0, float(match.group(2)), 0.0)
    match = re.match(r"UDim2\.new\(\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)\s*,\s*([-\d.]+)", text)
    if match:
        return (float(match.group(1)), float(match.group(2)), float(match.group(3)), float(match.group(4)))
    return None


findings = []
counts = {"elements": 0, "buttons": 0, "text": 0}
fonts, text_sizes, radii, strokes, literal_colors, tween_times, easings = {}, {}, {}, {}, {}, {}, {}
per_file = {}


def note(kind, rel, line, section, message):
    findings.append({"kind": kind, "file": rel, "line": line, "section": section, "message": message})


for rel in FILES:
    source = read(rel)
    if source is None:
        continue
    marks = sections(source)
    stats = per_file.setdefault(rel, {"elements": 0, "fixed": 0, "buttons": 0, "small_touch": 0, "small_text": 0})

    for line, class_name, text in blocks(source):
        where = section_at(marks, line)
        counts["elements"] += 1
        stats["elements"] += 1

        size = udim2_offsets(prop(text, "Size"))
        position = udim2_offsets(prop(text, "Position"))
        is_button = class_name.endswith("Button")
        if is_button:
            counts["buttons"] += 1
            stats["buttons"] += 1

        if size:
            sx, ox, sy, oy = size
            if sx == 0 and sy == 0 and (ox > 0 or oy > 0):
                stats["fixed"] += 1
                if ox > SMALLEST[0] * 0.95 or oy > SMALLEST[1] * 0.95:
                    note("scale", rel, line, where,
                         f"{class_name} is a fixed {ox:.0f}x{oy:.0f}, which doesn't fit {SMALLEST[0]}x{SMALLEST[1]}")
                elif ox > PHONE[0] * 0.95 or oy > PHONE[1] * 0.95:
                    note("scale", rel, line, where,
                         f"{class_name} is a fixed {ox:.0f}x{oy:.0f}, nearly the whole {PHONE[0]}x{PHONE[1]} phone screen")
            if is_button and sx == 0 and sy == 0 and ox > 0 and oy > 0 and min(ox, oy) < TOUCH_TARGET:
                stats["small_touch"] += 1
                note("touch", rel, line, where, f"{class_name} is {ox:.0f}x{oy:.0f}, under the {TOUCH_TARGET} px touch target")

        if position and size:
            _, px, _, py = position
            _, ox, _, oy = size
            if position[0] == 0 and position[2] == 0 and py + oy > SMALLEST[1] and py > 0:
                note("scale", rel, line, where,
                     f"{class_name} sits at a fixed y {py:.0f}..{py + oy:.0f}, past the bottom of a {SMALLEST[1]} px screen")

        font = prop(text, "Font")
        if font:
            fonts[font] = fonts.get(font, 0) + 1
        raw_size = prop(text, "TextSize")
        if raw_size and re.match(r"^\d+$", raw_size):
            value = int(raw_size)
            counts["text"] += 1
            text_sizes[value] = text_sizes.get(value, 0) + 1
            if value < TEXT_FLOOR:
                stats["small_text"] += 1
                note("type", rel, line, where, f"{class_name} text is {value} px, under the {TEXT_FLOOR} px floor")

        for colour in re.findall(r"Color3\.fromRGB\(\s*\d+\s*,\s*\d+\s*,\s*\d+\s*\)", text):
            literal_colors[colour] = literal_colors.get(colour, 0) + 1

    for match in re.finditer(r"rounded\(\s*(\d+)", source):
        radius = int(match.group(1))
        radii[radius] = radii.get(radius, 0) + 1
    for match in re.finditer(r"UICorner[^\n]*CornerRadius\s*=\s*UDim\.new\(\s*[\d.]+\s*,\s*(\d+)", source):
        radius = int(match.group(1))
        radii[radius] = radii.get(radius, 0) + 1
    for match in re.finditer(r'create\(\s*"UIStroke"[^\n]*Thickness\s*=\s*([\d.]+)', source):
        strokes[match.group(1)] = strokes.get(match.group(1), 0) + 1
    for match in re.finditer(r"TweenInfo\.new\(\s*([\d.]+)\s*(?:,\s*Enum\.EasingStyle\.(\w+))?", source):
        tween_times[match.group(1)] = tween_times.get(match.group(1), 0) + 1
        easing = match.group(2) or "(default Quad)"
        easings[easing] = easings.get(easing, 0) + 1


def table(counter, label):
    rows = sorted(counter.items(), key=lambda item: (-item[1], str(item[0])))
    return ", ".join(f"{label}{value} x{count}" for value, count in rows)


lines = ["# Menu and HUD layout audit", ""]
lines.append(f"{counts['elements']} UI elements, {counts['buttons']} buttons, {counts['text']} text labels "
             f"across {len(per_file)} files.")
lines.append("")
lines.append("## Per file")
lines.append("")
lines.append("| file | elements | fixed-pixel sizes | buttons | under 44 px | text under 14 px |")
lines.append("|---|---|---|---|---|---|")
for rel, stats in sorted(per_file.items()):
    lines.append(f"| {os.path.basename(rel)} | {stats['elements']} | {stats['fixed']} | {stats['buttons']} "
                 f"| {stats['small_touch']} | {stats['small_text']} |")
lines.append("")
lines.append("## Design system spread")
lines.append("")
lines.append(f"- **Fonts**: {len(fonts)} in use — {table(fonts, '')}")
lines.append(f"- **Text sizes**: {len(text_sizes)} distinct — {table(text_sizes, '')}")
lines.append(f"- **Corner radii**: {len(radii)} distinct — {table(radii, 'r')}")
lines.append(f"- **Stroke thicknesses**: {len(strokes)} distinct — {table(strokes, '')}")
lines.append(f"- **Literal colours** (not from the UiKit palette): {len(literal_colors)} distinct, "
             f"{sum(literal_colors.values())} uses")
lines.append(f"- **Tween durations**: {len(tween_times)} distinct — {table(tween_times, '')}")
lines.append(f"- **Easing styles**: {table(easings, '')}")
lines.append("")

by_kind = {}
# A width written as the parent minus a fixed number reads perfectly at 780 px of content and is a
# NEGATIVE width at 296. A negative width doesn't truncate the text, it draws nothing, so the failure
# is invisible in review and invisible in a landscape phone test — which is how the crate card's odds
# line came to vanish in portrait while reading fine everywhere anyone had looked. This finds them
# all, with the width each one would actually have.
#
# NARROWEST is the content area the menu shell gives inside a 320x568 portrait panel:
# clamp(320 - 40, 320, 1180) - 24.
NARROWEST = 296
for rel in FILES:
    source = read(rel)
    if source is None:
        continue
    marks = sections(source)
    for index, line_text in enumerate(source.split("\n"), start=1):
        for offset in re.findall(r"UDim2\.new\(\s*1\s*,\s*-(\d+)", line_text):
            remaining = NARROWEST - int(offset)
            if remaining > 100:
                continue
            verdict = "draws nothing" if remaining <= 0 else "unreadable"
            note("narrow", rel, index, section_at(marks, index),
                 f"width is parent - {offset}, which is {remaining} px at {NARROWEST} px of content ({verdict})")

for finding in findings:
    by_kind.setdefault(finding["kind"], []).append(finding)
for kind in sorted(by_kind):
    group = by_kind[kind]
    lines.append(f"## {kind} ({len(group)})")
    lines.append("")
    for finding in group:
        lines.append(f"- `{os.path.basename(finding['file'])}:{finding['line']}` "
                     f"({finding['section']}) — {finding['message']}")
    lines.append("")

# --- Where the top-level HUD elements actually land, and what overlaps what ----------------------
# Everything parented straight to the HUD's ScreenGui is a cluster the player sees at once. Their
# Position/Size are literals, so their rectangles can be worked out for any screen. The phone map
# (the HUD & UX worker's) covers phones; this covers the sizes nobody has measured.
SCREENS = [("1920x1080", 1920, 1080), ("1366x768", 1366, 768), ("1280x720", 1280, 720),
           ("tablet 1024x768", 1024, 768), ("phone 844x390", 844, 390)]


def rect(position, size, anchor, viewport):
    px = position[0] * viewport[0] + position[1]
    py = position[2] * viewport[1] + position[3]
    w = size[0] * viewport[0] + size[1]
    h = size[2] * viewport[1] + size[3]
    return (px - anchor[0] * w, py - anchor[1] * h, w, h)


def anchor_of(text):
    raw = prop(text, "AnchorPoint")
    if not raw:
        return (0.0, 0.0)
    match = re.match(r"Vector2\.new\(\s*([\d.]+)\s*,\s*([\d.]+)", raw)
    if match:
        return (float(match.group(1)), float(match.group(2)))
    return (0.0, 0.0)


hud_source = read("StarterPlayerScripts/HudClient.client.lua")
clusters = []
if hud_source:
    marks = sections(hud_source)
    for line, class_name, text in blocks(hud_source):
        if re.search(r"Parent\s*=\s*screenGui\b", text) and class_name in ("Frame", "TextLabel", "TextButton", "ImageLabel"):
            position = udim2_offsets(prop(text, "Position"))
            size = udim2_offsets(prop(text, "Size"))
            if position and size:
                name = prop(text, "Name") or f"{class_name}@{line}"
                clusters.append({"name": name.strip('"'), "line": line, "section": section_at(marks, line),
                                 "position": position, "size": size, "anchor": anchor_of(text)})

# Only elements that can be on screen at the same time are worth comparing: the results card, the
# map vote, the drop screen, the death recap and the winner banner are modal and take the screen
# on their own.
MODAL = ("Results card", "Map vote", "Drop selection", "Death recap", "Winner celebration", "Crate reveal")
# Lies over the whole screen on purpose, in pieces rather than as one frame.
OVERLAY = ("Screen-edge state",)
# One visual group at the centre of the screen; its members are meant to sit on each other.
CENTRE_STACK = ("Crosshair + hitmarker", "Damage direction indicator")


def concurrent(cluster):
    return not any(cluster["section"].startswith(name) for name in MODAL)


lines_overlap = ["## HUD clusters and overlaps", "",
                 f"{len(clusters)} elements are parented straight to the HUD's ScreenGui; "
                 f"{sum(1 for c in clusters if concurrent(c))} of them can be on screen together "
                 "(the rest are modal screens). Overlaps among the concurrent ones:", ""]
for label, width, height in SCREENS:
    boxes = []
    for cluster in clusters:
        if not concurrent(cluster):
            continue
        x, y, w, h = rect(cluster["position"], cluster["size"], cluster["anchor"], (width, height))
        if w >= width * 0.98 and h >= height * 0.98:
            # Full-screen tints (the low-health vignette, scrims) lie over everything on purpose.
            continue
        if any(cluster["section"].startswith(name) for name in OVERLAY):
            # The low-health / storm vignette is four EDGE strips, not one full-screen frame (a
            # transparent middle would need a 9-slice image). Each strip is its own top-level
            # element, so the full-screen test above never catches them, and they were being
            # reported as covering the ammo panel, the kill feed and the damage arrow. They are a
            # tint over the whole screen by design. Counting them made the HUD look worse than it is.
            continue
        boxes.append((cluster, x, y, w, h))
    offscreen = [c for c, x, y, w, h in boxes if x < -1 or y < -1 or x + w > width + 1 or y + h > height + 1]
    pairs = []
    for i in range(len(boxes)):
        ci, xi, yi, wi, hi = boxes[i]
        for j in range(i + 1, len(boxes)):
            cj, xj, yj, wj, hj = boxes[j]
            if ci["section"] == cj["section"]:
                # Parts of one cluster (the crosshair's dot and ticks) sit on each other by design.
                continue
            if (any(ci["section"].startswith(n) for n in CENTRE_STACK)
                    and any(cj["section"].startswith(n) for n in CENTRE_STACK)):
                # The crosshair, the hitmarker and the damage arrow all live at the exact centre of
                # the screen because that is what they are for: the arrow radiates from the aim
                # point. Reporting them as covering each other is the check misreading the design.
                continue
            ox = min(xi + wi, xj + wj) - max(xi, xj)
            oy = min(yi + hi, yj + hj) - max(yi, yj)
            if ox > 2 and oy > 2:
                pairs.append((f"{ci['section']}", f"{cj['section']}", int(ox), int(oy)))
    lines_overlap.append(f"- **{label}**: {len(pairs)} overlapping pairs, {len(offscreen)} partly off screen"
                         + (f" ({', '.join(sorted(set(c['name'] for c in offscreen))[:6])})" if offscreen else ""))
    for a, b, ox, oy in pairs[:8]:
        lines_overlap.append(f"    - {a} over {b} by {ox}x{oy} px")
lines_overlap.append("")
lines[lines.index("## Design system spread"):lines.index("## Design system spread")] = lines_overlap

if LUA:
    out = ["-- GENERATED by tools/menu_hud_audit.py --lua; do not edit by hand.",
           "--",
           "-- Every element parented straight to HudClient's ScreenGui, with the Position, Size and",
           "-- AnchorPoint written in its source. tools/menu_hud_gallery.lua draws the layout maps from",
           "-- these, so the pictures and the audit can't drift apart.",
           "",
           "return {"]
    for cluster in clusters:
        out.append('\t{ name = "%s", line = %d, section = "%s", pos = { %.4f, %.1f, %.4f, %.1f }, '
                   'size = { %.4f, %.1f, %.4f, %.1f }, anchor = { %.2f, %.2f }, modal = %s },'
                   % (cluster["name"].replace('"', ""), cluster["line"], cluster["section"].replace('"', ""),
                      cluster["position"][0], cluster["position"][1], cluster["position"][2], cluster["position"][3],
                      cluster["size"][0], cluster["size"][1], cluster["size"][2], cluster["size"][3],
                      cluster["anchor"][0], cluster["anchor"][1],
                      "false" if concurrent(cluster) else "true"))
    out.append("}")
    out.append("")
    with open(LUA, "w", encoding="utf-8", newline="\n") as handle:
        handle.write("\n".join(out))
    print(f"wrote {LUA} ({len(clusters)} clusters)")

report = "\n".join(lines)
if MD:
    with open(MD, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(report + "\n")
    print(f"wrote {MD}")
print(f"{counts['elements']} elements, {counts['buttons']} buttons; "
      f"{len(fonts)} fonts, {len(text_sizes)} text sizes, {len(radii)} radii, "
      f"{len(literal_colors)} literal colours, {len(tween_times)} tween durations")
for kind in sorted(by_kind):
    print(f"  {kind}: {len(by_kind[kind])}")
