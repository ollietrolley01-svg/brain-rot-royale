"""Build an isolated local client test without running the full battle royale.

HARNESS LIMIT, MEASURED (HUD tab, 09-21): the place this builds cannot be exercised by
runtest.ps1 -- see the header of tools/menu_cursor_probe.client.lua for the confirmed reason
(no automated Studio mode this project has ever gives a LocalScript a real Players.LocalPlayer).
This builder still has manual-Play-test value (F5 in Studio against the .rbxlx it writes), but
running it through runtest.ps1 -Probe or a full run wastes a queued run for a result that was
never going to prove anything.
"""
from pathlib import Path
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
doc = ET.Element("roblox", version="4")

def item(parent, cls, name):
    node = ET.SubElement(parent, "Item", {"class": cls})
    props = ET.SubElement(node, "Properties")
    ET.SubElement(props, "string", name="Name").text = name
    return node

world = item(doc, "Workspace", "Workspace")
spawn = item(world, "SpawnLocation", "CursorTestSpawn")
ET.SubElement(spawn.find("Properties"), "bool", name="Anchored").text = "true"
size = ET.SubElement(spawn.find("Properties"), "Vector3", name="size")
for axis, value in zip("XYZ", (40, 1, 40)):
    ET.SubElement(size, axis).text = str(value)
starter = item(doc, "StarterPlayer", "StarterPlayer")
scripts = item(starter, "StarterPlayerScripts", "StarterPlayerScripts")
for name, source in (
    ("MenuCursor", root / "StarterPlayerScripts/MenuCursor.client.lua"),
    ("CursorProbe", root / "tools/menu_cursor_probe.client.lua"),
):
    node = item(scripts, "LocalScript", name)
    ET.SubElement(node.find("Properties"), "ProtectedString", name="Source").text = source.read_text(encoding="utf-8")
out = root.parent / "hud_tab_playtest/MenuCursor_Test.rbxlx"
ET.ElementTree(doc).write(out, encoding="utf-8", xml_declaration=True)
print(out)
