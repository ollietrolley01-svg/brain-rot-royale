"""Roblox API check: the source against the real engine API, without Studio.

The lupa mocks accept anything: a property no class has, an Enum item that does not exist, a
PluginSecurity read from a LocalScript. Roblox does not -- each of those throws at run time and stops
the script (ac4b982 blamed a MeshPart.MeshId read, which the API in fact allows; the API was never
asked). This asks it. tools/roblox_api_subset.json is cut from Roblox's own API dump
(MaximumADHD/Roblox-Client-Tracker, Full-API-Dump.json: every class, its superclass, its members with
their read/write security, every Enum and its items).

Rules, over every .lua file under ServerScriptService, StarterPlayerScripts and ReplicatedStorage
(comments and strings' insides stripped before matching, so prose never counts):
  enum      Enum.<Type>.<Item>: the type exists and has that item
  new       Instance.new("<Class>"): a class that can be created
  service   game:GetService("<Class>"): a class that exists
  member    `local x = Instance.new("<Class>")`, then x.<Prop> = ... / x:<Method>( / x.<Event>: the
            class (or a superclass) has that member, until x is assigned again. A write to a
            read-only property counts too.
  member    also UiKit's create("<Class>", { Key = value }): every key but Parent is a writable property
  security  any `.Prop` read or `.Prop =` write where EVERY class that has a property of that name
            restricts that access (PluginSecurity and up): a game script cannot do it anywhere

Printed: files, sites examined per rule, findings. Exit 1 on any finding not listed in ALLOW below
(each ALLOW entry says why it is not a bug).

    python3 tools/roblox_api_check.py [repo]            the check
    python3 tools/roblox_api_check.py [repo] --plant    planted faults (one per rule); every one caught
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FOLDERS = ("ServerScriptService", "StarterPlayerScripts", "ReplicatedStorage")
OPEN = ("None",)
# The instance families whose restricted properties the security rule watches.
WATCHED = {"BasePart", "SurfaceAppearance", "Humanoid", "HumanoidDescription", "Player", "Model", "Sound",
           "Decal", "Camera", "Lighting", "Accessory", "Clothing", "Animator", "AnimationTrack", "Workspace",
           "GuiObject", "LayerCollector", "Constraint", "JointInstance", "Attachment", "ParticleEmitter", "Light"}
# Names this project uses as plain Lua table fields far more than as the restricted property of the same
# name (MenuShell's `shell.Content` frame, not AnimatedImage.Content).
PLAIN_FIELDS = {"Content", "Sink"}
SURFACE_MAPS = {"ColorMap", "NormalMap", "MetalnessMap", "RoughnessMap"}

# (file basename, rule, text in the finding) -> why it is not a bug.
ALLOW = {
}


def load_api():
    with open(os.path.join(HERE, "roblox_api_subset.json"), encoding="utf-8") as f:
        return json.load(f)


def strip(text):
    """Comments out, string contents blanked (quotes kept, so `Instance.new("Part")` keeps its word via
    a separate pass), line numbers preserved."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if text.startswith("--[", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                end = text.find("]" + m.group(1) + "]", i)
                end = n if end < 0 else end + len(m.group(1)) + 2
                out.append(re.sub(r"[^\n]", " ", text[i:end]))
                i = end
                continue
        if text.startswith("--", i):
            end = text.find("\n", i)
            end = n if end < 0 else end
            out.append(" " * (end - i))
            i = end
            continue
        if c == "[" and re.match(r"\[=*\[", text[i:]):
            m = re.match(r"\[(=*)\[", text[i:])
            end = text.find("]" + m.group(1) + "]", i)
            end = n if end < 0 else end + len(m.group(1)) + 2
            out.append(re.sub(r"[^\n]", " ", text[i:end]))
            i = end
            continue
        if c in "\"'`":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            body = text[i + 1:j]
            # Keep short identifier-like literals (class and service names); blank the rest.
            keep = body if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", body or "-") else re.sub(r"[^\n]", " ", body)
            out.append(c + keep + (c if j < n else ""))
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


class Api:
    def __init__(self, data):
        self.enums = {k: set(v) for k, v in data["enums"].items()}
        self.classes = data["classes"]
        by_name = {}
        for cname, c in self.classes.items():
            for m, code in c["m"].items():
                by_name.setdefault(m, []).append((cname, code))
        self.by_name = by_name

    def is_a(self, cls, bases):
        while cls and cls in self.classes:
            if cls in bases:
                return True
            cls = self.classes[cls]["super"]
        return False

    def member(self, cls, name):
        while cls and cls in self.classes:
            code = self.classes[cls]["m"].get(name)
            if code is not None:
                return code
            cls = self.classes[cls]["super"]
        return None

    @staticmethod
    def security(code):
        parts = code.split("|")
        return (parts[1], parts[2]) if len(parts) == 3 else ("None", "None")


def lineno(text, pos):
    return text.count("\n", 0, pos) + 1


def check_file(api, name, raw):
    text = strip(raw)
    found, counts = [], {"enum": 0, "new": 0, "service": 0, "member": 0, "security": 0}

    for m in re.finditer(r"\bEnum\.(\w+)\.(\w+)", text):
        counts["enum"] += 1
        kind, item = m.group(1), m.group(2)
        if kind not in api.enums:
            found.append(("enum", lineno(text, m.start()), "Enum.%s does not exist" % kind))
        elif item not in api.enums[kind] and item not in ("GetEnumItems", "FromName", "FromValue"):
            found.append(("enum", lineno(text, m.start()), "Enum.%s has no item %s" % (kind, item)))

    for m in re.finditer(r"\bInstance\.new\(\s*[\"'](\w+)[\"']", text):
        counts["new"] += 1
        c = api.classes.get(m.group(1))
        if not c or not c["creatable"]:
            found.append(("new", lineno(text, m.start()), "Instance.new(\"%s\"): %s" % (
                m.group(1), "no such class" if not c else "not creatable")))

    for m in re.finditer(r":GetService\(\s*[\"'](\w+)[\"']", text):
        counts["service"] += 1
        if m.group(1) not in api.classes:
            found.append(("service", lineno(text, m.start()), "GetService(\"%s\"): no such class" % m.group(1)))

    # Members of locals created by Instance.new, until the name is assigned again.
    for m in re.finditer(r"\blocal\s+(\w+)\s*=\s*Instance\.new\(\s*[\"'](\w+)[\"']", text):
        var, cls = m.group(1), m.group(2)
        if cls not in api.classes:
            continue
        start = m.end()
        again = re.compile(r"(?:\blocal\s+%s\b|(?<![\w.:])%s\s*=[^=])" % (var, var))
        stop = again.search(text, start)
        # Also stop where the enclosing function ends at the declaration's indentation or less.
        indent = len(text[text.rfind("\n", 0, m.start()) + 1:m.start()]) - len(text[text.rfind("\n", 0, m.start()) + 1:m.start()].lstrip())
        end_block = re.compile(r"\n([ \t]{0,%d})end\b" % max(indent - 1, 0)) if indent > 0 else None
        stop_at = stop.start() if stop else len(text)
        if end_block:
            e = end_block.search(text, start)
            if e and e.start() < stop_at:
                stop_at = e.start()
        region = text[start:stop_at]
        for use in re.finditer(r"(?<![\w.:])%s([.:])(\w+)(\s*=(?!=))?" % var, region):
            counts["member"] += 1
            sep, prop, assign = use.group(1), use.group(2), use.group(3)
            code = api.member(cls, prop)
            at = lineno(text, start + use.start())
            if code is None:
                found.append(("member", at, "%s (a %s) has no member %s" % (var, cls, prop)))
            elif assign and sep == "." and code[0] == "P" and "r" in code.split("|")[0][1:]:
                found.append(("member", at, "%s.%s is read-only on %s" % (var, prop, cls)))
            elif assign and sep == "." and code[0] != "P":
                found.append(("member", at, "%s.%s = ...: %s on %s is not a property" % (var, prop, prop, cls)))

    # UiKit.create("<Class>", { Key = value, ... }): every key but Parent is set as a property.
    for m in re.finditer(r"\bcreate\(\s*[\"'](\w+)[\"']\s*,\s*\{", text):
        cls = m.group(1)
        if cls not in api.classes:
            continue
        depth, i = 1, m.end()
        keys = []
        while i < len(text) and depth > 0:
            ch = text[i]
            if ch in "{([":
                depth += 1
            elif ch in "})]":
                depth -= 1
            elif depth == 1:
                k = re.match(r"(?<![\w.])([A-Za-z_]\w*)\s*=(?!=)", text[i:])
                if k and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] in "_.")):
                    keys.append((k.group(1), i))
                    i += k.end()
                    continue
            i += 1
        for key, at in keys:
            if key == "Parent":
                continue
            counts["member"] += 1
            code = api.member(cls, key)
            if code is None:
                found.append(("member", lineno(text, at), "create(\"%s\") sets %s, which it does not have" % (cls, key)))
            elif code[0] != "P":
                found.append(("member", lineno(text, at), "create(\"%s\") sets %s, which is not a property" % (cls, key)))
            elif "r" in code.split("|")[0][1:]:
                found.append(("member", lineno(text, at), "create(\"%s\") sets read-only %s" % (cls, key)))

    # Accesses no game script may make, whatever the object. Untyped, so only names that belong to the
    # instance classes this game handles (a `.B` on a Color3 is not a ParabolaAdornment's).
    for m in re.finditer(r"[.](\w+)\b(\s*=(?!=))?", text):
        prop, write = m.group(1), bool(m.group(2))
        owners = [(c, code) for c, code in api.by_name.get(prop, []) if code[0] == "P"]
        watched = [(c, code) for c, code in owners if api.is_a(c, WATCHED)]
        if not watched or prop in PLAIN_FIELDS:
            continue
        counts["security"] += 1
        side = 1 if write else 0
        # Restricted on every class that has it -- or one of SurfaceAppearance's maps, which a MaterialVariant
        # also has, openly, but which is what a body's arms carry.
        if all(api.security(code)[side] not in OPEN for _, code in owners) or (prop in SURFACE_MAPS and not write):
            what = "write" if write else "read"
            level = sorted({api.security(code)[side] for _, code in owners})
            found.append(("security", lineno(text, m.start()), "%s of .%s needs %s (%s)" % (
                what, prop, "/".join(level), ", ".join(sorted(c for c, _ in owners))[:80])))
    return found, counts


def files(root):
    for folder in FOLDERS:
        for dirpath, _, names in os.walk(os.path.join(root, folder)):
            for name in sorted(names):
                if name.endswith(".lua"):
                    yield os.path.join(dirpath, name)


def run(root, override=None, quiet=False):
    api = Api(load_api())
    total = {"enum": 0, "new": 0, "service": 0, "member": 0, "security": 0}
    findings, nfiles = [], 0
    for path in files(root):
        nfiles += 1
        name = os.path.basename(path)
        raw = (override or {}).get(name) or open(path, encoding="utf-8").read()
        found, counts = check_file(api, name, raw)
        for k in total:
            total[k] += counts[k]
        for rule, line, text in found:
            key = (name, rule, text)
            if key in ALLOW:
                continue
            findings.append("%s:%d [%s] %s" % (os.path.relpath(path, root), line, rule, text))
    if not quiet:
        print("roblox_api_check: %d files; sites examined: %s" % (nfiles, ", ".join("%s %d" % kv for kv in total.items())))
    return findings


PLANTS = [
    ("enum", "DeathEffectFx.lua", "spark.Shape = Enum.PartType.Ball", "spark.Shape = Enum.PartType.Sphere"),
    ("new", "DeathEffectFx.lua", 'Instance.new("PointLight")', 'Instance.new("PointLamp")'),
    ("member", "DeathEffectFx.lua", "light.Range = range", "light.Radius = range"),
    ("security", "Viewmodel.lua", "tostring(part.Size))", "tostring(part.Size), part:IsA(\"SurfaceAppearance\") and part.ColorMap or \"\")"),
    ("member", "BoonHud.client.lua", "\tIgnoreGuiInset = true,", "\tIgnoreGuiInsets = true,"),
    ("service", "CrackFxClient.client.lua", 'game:GetService("CollectionService")', 'game:GetService("CollectionServices")'),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    findings = run(root)
    for f in findings:
        print("FINDING", f)
    print("findings: %d" % len(findings))
    ok = not findings
    if "--plant" in sys.argv:
        paths = {os.path.basename(p): p for p in files(root)}
        for rule, name, anchor, repl in PLANTS:
            raw = open(paths[name], encoding="utf-8").read()
            if anchor not in raw:
                print("plant %s: ANCHOR MISSING in %s" % (rule, name))
                ok = False
                continue
            got = run(root, {name: raw.replace(anchor, repl, 1)}, quiet=True)
            hit = [g for g in got if ("[%s]" % rule) in g and name in g]
            print("plant %-8s %s" % (rule, "caught" if hit else "MISSED"))
            ok &= bool(hit)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
