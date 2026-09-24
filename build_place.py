"""Compile the brain-rot-royale source tree into a Roblox .rbxlx place file.

.rbxlx is Roblox's XML place format. Writing it directly avoids needing Rojo or any
other third-party binary — the output opens in Studio with every script already in the
right service, as the right instance type.
"""
import os
import pathlib
import sys
import time
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
OUT = ROOT / "BrainRotRoyale.rbxlx"

_referent = 0


def next_referent():
    global _referent
    _referent += 1
    return f"RBX{_referent}"


def item(parent, class_name, name):
    node = ET.SubElement(parent, "Item", {"class": class_name, "referent": next_referent()})
    props = ET.SubElement(node, "Properties")
    ET.SubElement(props, "string", {"name": "Name"}).text = name
    return node


def script_item(parent, class_name, name, source):
    node = item(parent, class_name, name)
    props = node.find("Properties")
    # ElementTree escapes &, < and > in text, which is exactly what ProtectedString needs.
    ET.SubElement(props, "ProtectedString", {"name": "Source"}).text = source
    return node


def class_for(path):
    if path.name.endswith(".server.lua"):
        return "Script"
    if path.name.endswith(".client.lua"):
        return "LocalScript"
    return "ModuleScript"


def instance_name(path):
    return path.name.replace(".server.lua", "").replace(".client.lua", "").replace(".lua", "")


def add_scripts(parent, directory):
    """Add every .lua directly inside `directory`, sorted for stable output."""
    count = 0
    for path in sorted(directory.glob("*.lua")):
        script_item(parent, class_for(path), instance_name(path), path.read_text(encoding="utf-8"))
        count += 1
    return count


roblox = ET.Element("roblox", {
    "xmlns:xsi": "http://www.w3.org/2001/XMLSchema-instance",
    "xsi:noNamespaceSchemaLocation": "http://www.roblox.com/roblox.xsd",
    "version": "4",
})

total = 0

# Studio recreates any service we leave out, so only the ones holding code are needed.
workspace_node = item(roblox, "Workspace", "Workspace")


def prop(node, kind, name, value):
    ET.SubElement(node.find("Properties"), kind, {"name": name}).text = value


# Maps run to several thousand parts plus 29 bot rigs. Streaming keeps clients from loading
# all of it at once. Safe here because every raycast happens on the server, so no client
# logic depends on distant parts being present.
prop(workspace_node, "bool", "StreamingEnabled", "true")
prop(workspace_node, "int", "StreamingMinRadius", "256")
prop(workspace_node, "int", "StreamingTargetRadius", "1024")


# Default Lighting renders flat and washed out, which makes even textured materials read
# as untextured. Future lighting + atmosphere is most of the visual difference.
lighting = item(roblox, "Lighting", "Lighting")
prop(lighting, "token", "Technology", "4")          # Future
prop(lighting, "float", "Brightness", "2.4")
prop(lighting, "float", "ClockTime", "14.5")
prop(lighting, "float", "GeographicLatitude", "22")
prop(lighting, "float", "ExposureCompensation", "0.35")
prop(lighting, "float", "EnvironmentDiffuseScale", "1")
prop(lighting, "float", "EnvironmentSpecularScale", "1")
prop(lighting, "bool", "GlobalShadows", "true")

# No fog and no Atmosphere. Even a light Atmosphere (density 0.08) lays a grey film along the
# ground across maps 900–1500 studs wide; Bootstrap also clears one at runtime in case Studio
# or a plugin adds it back.
prop(lighting, "float", "FogStart", "0")
prop(lighting, "float", "FogEnd", "100000")

replicated = item(roblox, "ReplicatedStorage", "ReplicatedStorage")
shared = item(replicated, "Folder", "Shared")
total += add_scripts(shared, ROOT / "ReplicatedStorage" / "Shared")

server = item(roblox, "ServerScriptService", "ServerScriptService")
total += add_scripts(server, ROOT / "ServerScriptService")
modules = item(server, "Folder", "Modules")
total += add_scripts(modules, ROOT / "ServerScriptService" / "Modules")

starter_player = item(roblox, "StarterPlayer", "StarterPlayer")
player_scripts = item(starter_player, "StarterPlayerScripts", "StarterPlayerScripts")
total += add_scripts(player_scripts, ROOT / "StarterPlayerScripts")
# Only the empty "Health" Script, which replaces Roblox's default 1%/s character regen (MatchService
# heals players out of combat instead). Leave it out and every player regenerates all match.
character_scripts = item(starter_player, "StarterCharacterScripts", "StarterCharacterScripts")
total += add_scripts(character_scripts, ROOT / "StarterCharacterScripts")

# Several sessions build at once: write a private temp file and swap it in atomically, so two
# builds can't interleave and a harness snapshotting the place never copies a half-written file.
tmp = OUT.with_name(f"{OUT.name}.{os.getpid()}.tmp")
ET.ElementTree(roblox).write(tmp, encoding="utf-8", xml_declaration=True)
for attempt in range(50):
    try:
        os.replace(tmp, OUT)
        break
    except PermissionError:
        time.sleep(0.2)  # a snapshot copy is reading the old file; it takes well under a second
else:
    os.remove(tmp)
    sys.exit(f"could not replace {OUT}: it is held open by another process")

print(f"wrote {OUT}")
print(f"scripts embedded: {total}")
print(f"size: {OUT.stat().st_size / 1024:.0f} KB")
