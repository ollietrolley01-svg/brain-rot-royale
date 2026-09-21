"""Isolated Studio Play fixture using production modules, with no profile saving."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET
import build_cursor_test as base

root, doc, scripts = base.root, base.doc, base.scripts
for node in list(scripts):
    if node.tag == "Item" and node.find("Properties/string").text == "CursorProbe":
        scripts.remove(node)

def script(parent, path):
    cls = "LocalScript" if path.name.endswith(".client.lua") else "Script" if path.name.endswith(".server.lua") else "ModuleScript"
    name = path.name.replace(".client.lua", "").replace(".server.lua", "").replace(".lua", "")
    node = base.item(parent, cls, name)
    ET.SubElement(node.find("Properties"), "ProtectedString", name="Source").text = path.read_text(encoding="utf-8")

rep = base.item(doc, "ReplicatedStorage", "ReplicatedStorage")
shared = base.item(rep, "Folder", "Shared")
server = base.item(doc, "ServerScriptService", "ServerScriptService")
modules = base.item(server, "Folder", "Modules")
for folder, parent in [("ReplicatedStorage/Shared", shared), ("ServerScriptService/Modules", modules)]:
    for path in sorted((root / folder).glob("*.lua")):
        script(parent, path)
for path in sorted((root / "StarterPlayerScripts").glob("*.lua")):
    if not path.name.endswith(".client.lua") or path.name == "CombatClient.client.lua":
        script(scripts, path)
script(scripts, root / "tools/range_probe.client.lua")
script(server, root / "tools/range_probe.server.lua")
remotes = base.item(rep, "Folder", "Remotes")
found = set()
for folder in ("ReplicatedStorage/Shared", "ServerScriptService/Modules", "StarterPlayerScripts", "tools"):
    for path in (root / folder).glob("*.lua"):
        found.update(re.findall(r'Remotes\.(Event|Function)\("([^"]+)"\)', path.read_text(encoding="utf-8")))
for kind, name in sorted(found):
    base.item(remotes, "RemoteEvent" if kind == "Event" else "RemoteFunction", name)
out = root.parent / "brain-rot-royale-playtest/Range_Test.rbxlx"
ET.ElementTree(doc).write(out, encoding="utf-8", xml_declaration=True)
print(out)
