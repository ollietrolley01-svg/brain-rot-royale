"""Offline security audit + bake readout for Creator Store models exported from Studio as .rbxmx.

    python tools/brainrot_asset_audit.py <folder-or-file.rbxmx> [...]   audit every export
    python tools/brainrot_asset_audit.py --selftest                      planted-backdoor proof only

Why offline: InsertService:LoadAsset from the harness fails with "User is not authorized to access
Asset." (Studio log 2026-09-19T20:14Z, 16/16), so a candidate is inserted by Oliver in his own logged-in
Studio, saved with "Save to File..." as <id>.rbxmx into a review folder OUTSIDE the game tree, and
audited here. rbxmx is XML: every Script's Source, its Disabled flag, every Remote, every StringValue
and every mesh/texture id is readable without running anything.

For each file it prints, and writes beside the input as <name>.audit.txt / <name>.stripped.rbxmx /
<name>.bake.json:
  EXAMINED  every Item in the file (all depths), beside FLAGGED
  scripts   Script / LocalScript / ModuleScript, Disabled or not, depth, Source length, suspicious hits
  remotes   RemoteEvent / RemoteFunction / BindableEvent / BindableFunction / Actor
  strings   suspicious patterns in Source, Name, StringValue.Value, attributes, Text
  other     every class that is not geometry / mesh / texture / weld / attachment / plain value
  strip     what was removed, by class; then the RE-SCAN of the stripped tree (that is the evidence)
  bake      the data a shipped module would carry: per BasePart class, name, size, CFrame, colour,
            material, transparency, mesh id, texture id (MeshSize is NOT serialised in rbxmx, so a
            SpecialMesh bake needs it measured once in Studio; MeshPart bakes carry Size only)
The self-test runs first every time: a Disabled Script holding require(123456) four containers deep,
a RemoteEvent beside it and a base64-looking StringValue must all be flagged, and the strip must leave
the re-scan at zero. If it fails, nothing else is audited.
"""
import json
import pathlib
import re
import sys
import xml.etree.ElementTree as ET

SUSPICIOUS = [
    ("require by id", re.compile(r"require\s*\(\s*\d")),
    ("getfenv", re.compile(r"getfenv")),
    ("setfenv", re.compile(r"setfenv")),
    ("loadstring", re.compile(r"loadstring")),
    ("HttpService", re.compile(r"HttpService")),
    ("GetAsync", re.compile(r"GetAsync")),
    ("PostAsync", re.compile(r"PostAsync")),
    ("MarketplaceService", re.compile(r"MarketplaceService")),
    ("TeleportService", re.compile(r"TeleportService")),
    ("InsertService", re.compile(r"InsertService")),
    ("\\x escape", re.compile(r"\\x[0-9a-fA-F]{2}")),
    ("string.char chain", re.compile(r"string\.char\s*\(")),
    ("base64-looking blob", re.compile(r"[A-Za-z0-9+/=]{60,}")),
]
SCRIPT_CLASSES = {"Script", "LocalScript", "ModuleScript"}
REMOTE_CLASSES = {"RemoteEvent", "RemoteFunction", "BindableEvent", "BindableFunction", "Actor"}
GEOMETRY = {"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart", "UnionOperation", "NegateOperation",
            "IntersectOperation", "SpecialMesh", "SurfaceAppearance", "Decal", "Texture", "Attachment", "Weld",
            "WeldConstraint", "Motor6D", "Snap", "ManualWeld", "Model", "Folder", "Accessory",
            "Vector3Value", "Color3Value", "CFrameValue", "NumberValue", "IntValue", "BoolValue"}
BASEPARTS = {"Part", "MeshPart", "WedgePart", "CornerWedgePart", "TrussPart", "UnionOperation", "NegateOperation",
             "IntersectOperation"}
MAX_VALUE_LEN = 64


def smells(text):
    hits = []
    if not text:
        return hits
    for label, pattern in SUSPICIOUS:
        m = pattern.search(text)
        if m:
            hits.append(f"{label} ({len(m.group(0))} chars)" if label == "base64-looking blob" else label)
    return hits


def prop(item, name):
    props = item.find("Properties")
    if props is None:
        return None
    for child in props:
        if child.get("name") == name:
            return child
    return None


def prop_text(item, name):
    node = prop(item, name)
    if node is None:
        return None
    if node.tag == "Content":
        url = node.find("url")
        return (url.text or "") if url is not None else (node.text or "")
    return node.text or ""


def item_name(item):
    return prop_text(item, "Name") or "?"


def walk(node, depth=0, path=()):
    """Yields (item, depth, path) for every <Item> under node, root items at depth 1."""
    for child in node.findall("Item"):
        p = path + (item_name(child),)
        yield child, depth + 1, p
        yield from walk(child, depth + 1, p)


def scan(root):
    report = {"examined": 0, "classes": {}, "scripts": [], "remotes": [], "values": [], "strings": [], "other": []}
    for item, depth, path in walk(root):
        report["examined"] += 1
        cls = item.get("class", "?")
        report["classes"][cls] = report["classes"].get(cls, 0) + 1
        joined = "/".join(path)
        here = [f"Name:{h}" for h in smells(item_name(item))]
        # Attributes are serialised as a binary blob; a long one is itself worth a look.
        attrs = prop(item, "AttributesSerialize")
        if attrs is not None and attrs.text and len(attrs.text.strip()) > MAX_VALUE_LEN:
            here.append(f"attributes blob ({len(attrs.text.strip())} chars)")
        text = prop_text(item, "Text")
        here += [f"Text:{h}" for h in smells(text)]
        if cls in SCRIPT_CLASSES:
            source = prop_text(item, "Source") or ""
            disabled = (prop_text(item, "Disabled") or "false").strip() == "true"
            hits = smells(source)
            here += [f"Source:{h}" for h in hits]
            report["scripts"].append({"class": cls, "path": joined, "depth": depth, "disabled": disabled,
                                      "length": len(source), "hits": hits})
        elif cls in REMOTE_CLASSES:
            report["remotes"].append({"class": cls, "path": joined, "depth": depth})
        elif cls == "StringValue":
            value = prop_text(item, "Value") or ""
            hits = smells(value)
            here += [f"Value:{h}" for h in hits]
            report["values"].append({"class": cls, "path": joined, "depth": depth, "length": len(value), "hits": hits})
        elif cls == "ObjectValue":
            report["values"].append({"class": cls, "path": joined, "depth": depth, "length": 0, "hits": ["ObjectValue"]})
        elif cls not in GEOMETRY:
            report["other"].append({"class": cls, "path": joined, "depth": depth})
        if here:
            report["strings"].append({"class": cls, "path": joined, "depth": depth, "hits": here})
    report["flagged"] = (len(report["scripts"]) + len(report["remotes"]) + len(report["other"]) + len(report["strings"])
                        + sum(1 for v in report["values"] if v["hits"] or v["length"] > MAX_VALUE_LEN))
    return report


def strip(root):
    """Removes everything that is not inert geometry. Returns {class: count} of what went."""
    removed = {}

    def drop(parent, item):
        cls = item.get("class", "?")
        removed[cls] = removed.get(cls, 0) + 1
        parent.remove(item)

    def visit(parent):
        for item in list(parent.findall("Item")):
            cls = item.get("class", "?")
            if cls in SCRIPT_CLASSES or cls in REMOTE_CLASSES:
                drop(parent, item)
            elif cls == "StringValue":
                value = prop_text(item, "Value") or ""
                if len(value) > MAX_VALUE_LEN or smells(value):
                    drop(parent, item)
                else:
                    visit(item)
            elif cls in BASEPARTS:
                for name, text in (("Anchored", "true"), ("CanCollide", "false"), ("CanTouch", "false"), ("CanQuery", "false")):
                    node = prop(item, name)
                    if node is not None:
                        node.text = text
                visit(item)
            elif cls not in GEOMETRY:
                drop(parent, item)
            else:
                visit(item)
        # Containers left holding nothing are debris.
        for item in list(parent.findall("Item")):
            if item.get("class") in ("Folder", "Model") and not item.findall("Item"):
                drop(parent, item)

    visit(root)
    return removed


def census(counts):
    return ", ".join(f"{k} {counts[k]}" for k in sorted(counts)) or "(none)"


def describe(tag, report, out):
    out(f"{tag}: EXAMINED {report['examined']} items, FLAGGED {report['flagged']}; classes: {census(report['classes'])}")
    for s in report["scripts"]:
        out(f"{tag}:   SCRIPT {s['class']} {s['path']} depth {s['depth']} {'DISABLED' if s['disabled'] else 'enabled'} "
            f"len {s['length']} hits [{', '.join(s['hits'])}]")
    for r in report["remotes"]:
        out(f"{tag}:   REMOTE/BINDABLE/ACTOR {r['class']} {r['path']} depth {r['depth']}")
    for v in report["values"]:
        out(f"{tag}:   VALUE {v['class']} {v['path']} depth {v['depth']} len {v['length']} hits [{', '.join(v['hits'])}]")
    for s in report["strings"]:
        out(f"{tag}:   STRING HIT {s['class']} {s['path']} depth {s['depth']} [{', '.join(s['hits'])}]")
    others = {}
    for o in report["other"]:
        others[o["class"]] = others.get(o["class"], 0) + 1
    out(f"{tag}:   non-geometry classes: {census(others)}")


def vec3(item, name):
    node = prop(item, name)
    if node is None:
        return None
    return [float(node.findtext(axis) or 0) for axis in ("X", "Y", "Z")]


def cframe(item):
    node = prop(item, "CFrame")
    if node is None:
        return None
    keys = ["X", "Y", "Z", "R00", "R01", "R02", "R10", "R11", "R12", "R20", "R21", "R22"]
    return [float(node.findtext(k) or 0) for k in keys]


def color(item):
    node = prop(item, "Color3uint8")
    if node is None or not node.text:
        return None
    packed = int(node.text) & 0xFFFFFF
    return [(packed >> 16) & 255, (packed >> 8) & 255, packed & 255]


def bake(root):
    parts = []
    mesh_ids, texture_ids = set(), set()
    for item, depth, path in walk(root):
        cls = item.get("class", "?")
        if cls in BASEPARTS:
            entry = {"class": cls, "name": item_name(item), "path": "/".join(path), "size": vec3(item, "size"),
                     "cframe": cframe(item), "color": color(item), "material": prop_text(item, "Material"),
                     "transparency": prop_text(item, "Transparency")}
            if cls == "MeshPart":
                entry["meshId"] = prop_text(item, "MeshId") or ""
                entry["textureId"] = prop_text(item, "TextureID") or ""
                mesh_ids.add(entry["meshId"])
                if entry["textureId"]:
                    texture_ids.add(entry["textureId"])
            for child in item.findall("Item"):
                ccls = child.get("class")
                if ccls == "SpecialMesh":
                    entry["specialMesh"] = {"meshType": prop_text(child, "MeshType"), "meshId": prop_text(child, "MeshId") or "",
                                            "textureId": prop_text(child, "TextureId") or "", "scale": vec3(child, "Scale")}
                    if entry["specialMesh"]["meshId"]:
                        mesh_ids.add(entry["specialMesh"]["meshId"])
                    if entry["specialMesh"]["textureId"]:
                        texture_ids.add(entry["specialMesh"]["textureId"])
                elif ccls == "SurfaceAppearance":
                    entry["surfaceAppearance"] = {k: prop_text(child, k) or "" for k in ("ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap")}
                    if entry["surfaceAppearance"]["ColorMap"]:
                        texture_ids.add(entry["surfaceAppearance"]["ColorMap"])
                elif ccls in ("Decal", "Texture"):
                    entry.setdefault("decals", []).append(prop_text(child, "Texture") or "")
                    if prop_text(child, "Texture"):
                        texture_ids.add(prop_text(child, "Texture"))
            parts.append(entry)
    return {"parts": parts, "meshIds": sorted(mesh_ids), "textureIds": sorted(texture_ids)}


def bounds(parts):
    lo = [float("inf")] * 3
    hi = [float("-inf")] * 3
    for p in parts:
        if not p["size"] or not p["cframe"]:
            continue
        cx, cy, cz = p["cframe"][0:3]
        r = p["cframe"][3:12]
        sx, sy, sz = [s / 2 for s in p["size"]]
        # Axis-aligned extent of an oriented box: |R| * half-size.
        ex = abs(r[0]) * sx + abs(r[1]) * sy + abs(r[2]) * sz
        ey = abs(r[3]) * sx + abs(r[4]) * sy + abs(r[5]) * sz
        ez = abs(r[6]) * sx + abs(r[7]) * sy + abs(r[8]) * sz
        for i, (c, e) in enumerate(((cx, ex), (cy, ey), (cz, ez))):
            lo[i] = min(lo[i], c - e)
            hi[i] = max(hi[i], c + e)
    if lo[0] == float("inf"):
        return None
    return [hi[i] - lo[i] for i in range(3)]


def audit_tree(root, tag, out):
    before = scan(root)
    describe(f"{tag} PRE-STRIP", before, out)
    removed = strip(root)
    after = scan(root)
    describe(f"{tag} POST-STRIP (the kept tree)", after, out)
    clean = not after["scripts"] and not after["remotes"] and not after["other"] and not any(
        v["hits"] or v["length"] > MAX_VALUE_LEN for v in after["values"])
    baked = bake(root)
    mesh_parts = sum(1 for p in baked["parts"] if p["class"] == "MeshPart")
    unions = sum(1 for p in baked["parts"] if p["class"] in ("UnionOperation", "NegateOperation", "IntersectOperation"))
    box = bounds(baked["parts"])
    out(f"{tag}: stripped {census(removed)}; kept CLEAN = {clean}")
    out(f"{tag}: BAKE parts {len(baked['parts'])} (MeshParts {mesh_parts}, unions {unions}), unique meshes {len(baked['meshIds'])}, "
        f"unique textures {len(baked['textureIds'])}, bbox {box and ' x '.join(f'{v:.2f}' for v in box)}, "
        f"single-mesh {mesh_parts == 1 and len(baked['parts']) <= 2}")
    out(f"{tag}: BAKE mesh ids: {' '.join(baked['meshIds'])}")
    out(f"{tag}: BAKE texture ids: {' '.join(baked['textureIds'])}")
    return before, after, removed, clean, baked


def selftest(out):
    """PERMANENT PLANTED BACKDOOR: must be flagged before the strip and gone after it."""
    xml = """<roblox version="4">
  <Item class="Model" referent="R1"><Properties><string name="Name">PlantedCopy</string></Properties>
    <Item class="Part" referent="R2"><Properties><string name="Name">Body</string><Vector3 name="size"><X>2</X><Y>2</Y><Z>2</Z></Vector3>
      <CoordinateFrame name="CFrame"><X>0</X><Y>1</Y><Z>0</Z><R00>1</R00><R01>0</R01><R02>0</R02><R10>0</R10><R11>1</R11><R12>0</R12><R20>0</R20><R21>0</R21><R22>1</R22></CoordinateFrame>
      <bool name="Anchored">false</bool></Properties></Item>
    <Item class="Model" referent="R3"><Properties><string name="Name">Head</string></Properties>
      <Item class="Folder" referent="R4"><Properties><string name="Name">Animate</string></Properties>
        <Item class="Folder" referent="R5"><Properties><string name="Name">Health</string></Properties>
          <Item class="StringValue" referent="R8"><Properties><string name="Name">Color</string><string name="Value">QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=</string></Properties></Item>
          <Item class="Folder" referent="R6"><Properties><string name="Name">Sound</string></Properties>
            <Item class="Script" referent="R7"><Properties><string name="Name">Humanoid</string><bool name="Disabled">true</bool><ProtectedString name="Source">require(123456)</ProtectedString></Properties></Item>
            <Item class="RemoteEvent" referent="R9"><Properties><string name="Name">Weld</string></Properties></Item>
          </Item>
        </Item>
      </Item>
    </Item>
  </Item>
</roblox>"""
    root = ET.fromstring(xml)
    before = scan(root)
    script_seen = any(s["disabled"] and s["depth"] >= 5 and "require by id" in s["hits"] for s in before["scripts"])
    remote_seen = any(r["class"] == "RemoteEvent" and r["depth"] >= 5 for r in before["remotes"])
    blob_seen = any(any("base64" in h for h in v["hits"]) for v in before["values"])
    removed = strip(root)
    after = scan(root)
    clean_after = not after["scripts"] and not after["remotes"] and not after["values"]
    body_kept = after["classes"].get("Part", 0) == 1
    caught = script_seen and remote_seen and blob_seen and clean_after and body_kept
    out(f"== PLANTED BACKDOOR: examined {before['examined']}, flagged {before['flagged']}; disabled Script with require-by-id at depth>=5 "
        f"seen {script_seen}; RemoteEvent seen {remote_seen}; blob seen {blob_seen}; stripped {census(removed)}; after: examined "
        f"{after['examined']} scripts {len(after['scripts'])} remotes {len(after['remotes'])} values {len(after['values'])} body kept {body_kept} "
        f"-> {'CAUGHT' if caught else 'MISSED (this audit proves nothing)'}")
    return caught


def main(argv):
    lines = []

    def out(text):
        print(text)
        lines.append(text)

    if not selftest(out):
        print("self-test FAILED; refusing to audit anything")
        return 2
    if len(argv) == 0 or argv == ["--selftest"]:
        return 0
    files = []
    for arg in argv:
        p = pathlib.Path(arg)
        if p.is_dir():
            files += sorted(p.glob("*.rbxmx")) + sorted(p.glob("*.rbxlx"))
        elif p.exists():
            files.append(p)
        else:
            out(f"no such file: {p}")
    if not files:
        out("no .rbxmx files to audit (sample count 0)")
        return 1
    table = []
    for path in files:
        try:
            tree = ET.parse(path)
        except ET.ParseError as err:
            out(f"{path.name}: NOT XML ({err}) — a binary .rbxm; re-save as .rbxmx")
            table.append((path.name, "-", "-", "-", "UNREADABLE"))
            continue
        root = tree.getroot()
        per_file = []
        before, after, removed, clean, baked = audit_tree(root, path.name, lambda t: (out(t), per_file.append(t)))
        suspicious = len(before["strings"])
        table.append((path.name, f"{path.stat().st_size / 1024:.0f} KB", before["examined"], len(before["scripts"]), suspicious,
                      len(baked["parts"]), len(baked["meshIds"]), len(baked["textureIds"]), "CLEAN" if clean else "DIRTY"))
        stem = path.with_suffix("")
        pathlib.Path(f"{stem}.audit.txt").write_text("\n".join(per_file) + "\n", encoding="utf-8")
        tree.write(f"{stem}.stripped.rbxmx", encoding="utf-8", xml_declaration=False)
        pathlib.Path(f"{stem}.bake.json").write_text(json.dumps(baked, indent=1), encoding="utf-8")
    out("== PER-ASSET TABLE: file | size | items examined | scripts removed | suspicious-string items | parts kept | mesh ids | texture ids | verdict")
    for row in table:
        out("   " + " | ".join(str(c) for c in row))
    out(f"== audited {len(table)} file(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
