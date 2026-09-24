"""Cross-worker contracts, checked statically: what one file produces against what another consumes.

Several workers change the game at once, each in its own files, and they meet at names: an attribute
one side sets and another reads, a remote one side fires and the other listens for, a CollectionService
tag, a sound cue, a module function, a gun style that five lookup tables must know. A name that is
consumed but never produced fails silently in Roblox (GetAttribute returns nil, a client WaitForChild
on a remote the server never makes yields forever, Sfx.Play of an unknown cue plays nothing), so these
are the bugs a merge introduces without any single worker's own checks noticing.

Usage:
    python3 tools/contracts_check.py [root]            check the tree (exit 1 on a finding)
    python3 tools/contracts_check.py [root] --selftest  plant one fault per contract in a copy of the
                                                         tree and confirm each is caught

Contracts (see coordination/cloud_status.md, "Contracts", for who owns each side):
  C1 attributes      every GetAttribute / GetAttributeChangedSignal("X") has a SetAttribute("X") somewhere
                     (engine-set and Studio-set names are listed in ENGINE_ATTRIBUTES, with the reason)
  C2 remotes         a client FireServer / InvokeServer has a server OnServerEvent / OnServerInvoke, and
                     a client OnClientEvent has a server FireClient / FireAllClients, by remote name
  C3 tags            every tag read (GetTagged, HasTag, GetInstanceAddedSignal) is added somewhere
  C4 sound cues      every literal Sfx.Play / PlayAt / PlayDistant / Loop cue is a SoundConfig entry
  C5 module API      every Module.Name read from another file, for the modules in API_MODULES (the
                     cross-worker seams), is defined in that module; an optional hook read behind
                     `X.Name and X.Name(...)` is reported as a note, not a failure
  C6 gun styles      every WeaponData / Arsenal `style` has a word in LootService's and InventoryPanel's
                     type-word maps and a GunModels STYLES builder; BOT_WEAPON_HOLD ids are real guns
  C7 vehicle gunner  the gunner seat the HUD and VehicleWeaponClient look for ("GunnerSeat" / Gunner
                     attribute) is made by the server, and VehicleGunActive is only set by the client
                     that owns it
  C8 cosmetic kinds  every kind in CosmeticData has an equip slot in PlayerData's default Cosmetics, and
                     every crate's `kinds` list names kinds CosmeticData has items of
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

SRC_DIRS = ("ReplicatedStorage", "ServerScriptService", "StarterPlayerScripts")

# Attributes read in code that no script sets, with why that is fine. Keep the reason: a name added
# here without one is how a real break gets waved through.
ENGINE_ATTRIBUTES = {
    # Set in Studio / by build_place.py on authored instances, or by Roblox itself.
    "RBX_": "Roblox's own attributes",
}

# Modules whose public surface other workers call into. A read of Module.Name from another file must
# find Name defined in the module (function Module.Name, Module.Name = ..., or a method).
API_MODULES = [
    "BotService", "BotNav", "ModeTeams", "ModeKingOfTheHill", "ObjectiveZone", "LootService",
    "DefenseService", "DefensePlacement", "VehicleWeapons", "VehicleService", "RewardService",
    "DestructibleService", "MapGenerator", "CombatService", "StatusEffects", "TeamBattleground",
    "TeamBaseRuins", "SupplyDropService", "CosmeticData", "MatchConfig", "WeaponData", "SoundConfig",
    "VehicleModels", "VehicleWeaponData", "GameMode", "Sfx",
]


def strip_comments(src):
    """Lua source with comments blanked (line numbers kept) and string contents left alone."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith("--[[", i) or re.match(r"--\[=+\[", src[i:i + 8]):
            m = re.match(r"--\[(=*)\[", src[i:])
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(re.sub(r"[^\n]", " ", src[i:j]))
            i = j
        elif src.startswith("--", i):
            j = src.find("\n", i)
            j = n if j < 0 else j
            out.append(" " * (j - i))
            i = j
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("[[", i) or re.match(r"\[=+\[", src[i:i + 8]):
            m = re.match(r"\[(=*)\[", src[i:])
            close = "]" + m.group(1) + "]"
            j = src.find(close, i)
            j = n if j < 0 else j + len(close)
            out.append(src[i:j])
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def load(root):
    files = {}
    for top in SRC_DIRS:
        for dirpath, _, names in os.walk(os.path.join(root, top)):
            for name in names:
                if name.endswith(".lua"):
                    path = os.path.join(dirpath, name)
                    rel = os.path.relpath(path, root).replace(os.sep, "/")
                    with open(path, encoding="utf-8", errors="replace") as f:
                        files[rel] = strip_comments(f.read())
    return files


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def side(rel):
    if rel.startswith("StarterPlayerScripts/"):
        return "client"
    if rel.startswith("ServerScriptService/"):
        return "server"
    return "shared"


def module_name(rel):
    return os.path.basename(rel).split(".")[0]


# --- C1 attributes -----------------------------------------------------------------------------------

def check_attributes(files, problems, notes):
    set_names, read_sites = set(), {}
    for rel, text in files.items():
        for m in re.finditer(r':SetAttribute\(\s*"(\w+)"', text):
            set_names.add(m.group(1))
        # A name built at run time from a prefix ("Stat" .. key) produces the whole family.
        for m in re.finditer(r':SetAttribute\(\s*"(\w+)"\s*\.\.', text):
            set_names.add(m.group(1) + "*")
        for m in re.finditer(r':(?:GetAttribute|GetAttributeChangedSignal)\(\s*"(\w+)"\s*\)', text):
            read_sites.setdefault(m.group(1), []).append(f"{rel}:{line_of(text, m.start())}")
    # Attribute tables handed to a builder ({ Attributes = { Name = ... } }) and SetAttribute in a loop over
    # a literal list: count names that appear as keys of a table literal passed to a helper named *attr*.
    for rel, text in files.items():
        for m in re.finditer(r'(?i)attributes\s*=\s*\{([^{}]*)\}', text):
            set_names.update(re.findall(r'(\w+)\s*=', m.group(1)))
        # A file that sets attributes from a loop (`for name, value in pairs(attrs) do x:SetAttribute(name,
        # value)`) produces the CapitalCase keys of the small table literals it builds.
        if re.search(r':SetAttribute\(\s*[a-z]\w*\s*,', text):
            for m in re.finditer(r'\{\s*((?:[A-Z]\w*\s*=\s*[^,{}]+,?\s*)+)\}', text):
                set_names.update(re.findall(r'([A-Z]\w*)\s*=', m.group(1)))
    prefixes = [n[:-1] for n in set_names if n.endswith("*")]
    for name, sites in sorted(read_sites.items()):
        if name in set_names or any(name.startswith(p) for p in prefixes):
            continue
        if any(name.startswith(k) for k in ENGINE_ATTRIBUTES):
            continue
        problems.append(f"C1 attribute \"{name}\" is read but never set (read at {', '.join(sites[:3])})")


# --- C2 remotes --------------------------------------------------------------------------------------

REMOTE_ALIAS = re.compile(r'local\s+(\w+)\s*=\s*Remotes\.(Event|Function)\(\s*"(\w+)"\s*\)')


def remote_uses(text):
    """(name, member) for every Remotes.X("name"):Member and alias:Member in this file."""
    uses = []
    for m in re.finditer(r'Remotes\.(?:Event|Function)\(\s*"(\w+)"\s*\)\s*[.:]\s*(\w+)', text):
        uses.append((m.group(1), m.group(2)))
    for m in REMOTE_ALIAS.finditer(text):
        alias, name = m.group(1), m.group(3)
        for u in re.finditer(rf'(?<![\w.]){alias}\s*[.:]\s*(\w+)', text[m.end():]):
            uses.append((name, u.group(1)))
        # Handed to a helper (broadcast(companionHit, payload)): the helper's own :FireAllClients /
        # :FireClient in this file is what fires it.
        if re.search(rf'\w+\(\s*{alias}\s*[,)]', text[m.end():]):
            for member in ("FireAllClients", "FireClient"):
                if re.search(rf"[.:]\s*{member}\b", text):
                    uses.append((name, member))
    return uses


def check_remotes(files, problems, notes):
    server, client = {}, {}
    for rel, text in files.items():
        where = server if side(rel) == "server" else client if side(rel) == "client" else None
        if where is None:
            continue
        for name, member in remote_uses(text):
            where.setdefault(name, set()).add(member)
    pairs = [
        ("FireServer", "OnServerEvent", "the client fires it and no server script listens"),
        ("InvokeServer", "OnServerInvoke", "the client invokes it and no server script answers (it yields forever)"),
    ]
    for name, members in sorted(client.items()):
        for client_side, server_side, why in pairs:
            if client_side in members and server_side not in server.get(name, set()):
                problems.append(f"C2 remote \"{name}\": {why}")
        if "OnClientEvent" in members and not ({"FireClient", "FireAllClients"} & server.get(name, set())):
            # Fired from shared code (a module that runs on the server) is still a server fire.
            shared_fire = any(re.search(rf'Remotes\.Event\(\s*"{name}"\s*\)\s*:\s*Fire(?:All)?Client', t)
                              for r, t in files.items() if side(r) == "shared")
            if not shared_fire:
                problems.append(f"C2 remote \"{name}\": the client listens (OnClientEvent) and no server script fires it")
        if name not in server and not any(f'"{name}"' in t for r, t in files.items() if side(r) != "client"):
            problems.append(f"C2 remote \"{name}\": only the client names it, so its WaitForChild never returns")


# --- C3 tags -----------------------------------------------------------------------------------------

def check_tags(files, problems, notes):
    added, read = set(), {}
    for rel, text in files.items():
        for m in re.finditer(r'(?:CollectionService|CS|Collection)\s*:\s*AddTag\(\s*[\w.\[\]]+\s*,\s*"(\w+)"', text):
            added.add(m.group(1))
        for m in re.finditer(r':AddTag\(\s*"(\w+)"', text):  # instance:AddTag("X")
            added.add(m.group(1))
        for m in re.finditer(r'(?:GetTagged|GetInstanceAddedSignal|GetInstanceRemovedSignal)\(\s*"(\w+)"', text):
            read.setdefault(m.group(1), []).append(f"{rel}:{line_of(text, m.start())}")
        for m in re.finditer(r':HasTag\(\s*(?:[\w.\[\]]+\s*,\s*)?"(\w+)"', text):
            read.setdefault(m.group(1), []).append(f"{rel}:{line_of(text, m.start())}")
    # A tag held in a module constant (DestructibleService.Tags.Tree = "DestructibleTree") is added through
    # that constant; count the constant's string as added when some AddTag passes a non-literal.
    for rel, text in files.items():
        for m in re.finditer(r'(\w*[Tt]ags?\w*)\s*=\s*\{([^{}]*)\}', text):
            added.update(re.findall(r'=\s*"(\w+)"', m.group(2)))
        for m in re.finditer(r'(?:local\s+)?[\w.]*(?:TAG|Tag)\w*\s*=\s*"(\w+)"', text):
            added.add(m.group(1))
    for name, sites in sorted(read.items()):
        if name not in added:
            problems.append(f"C3 tag \"{name}\" is looked for but never added (at {', '.join(sites[:3])})")


# --- C4 sound cues -----------------------------------------------------------------------------------

def sound_cues(files):
    text = files.get("ReplicatedStorage/Shared/SoundConfig.lua", "")
    cues = set(re.findall(r'^\t(\w+)\s*=\s*\{', text, re.M))
    cues |= set(re.findall(r'^SoundConfig\.(\w+)\s*=', text, re.M))
    cues |= set(re.findall(r'^SoundConfig\[\s*"(\w+)"\s*\]\s*=', text, re.M))
    return cues


def check_sounds(files, problems, notes):
    cues = sound_cues(files)
    if len(cues) < 20:
        problems.append(f"C4 couldn't read SoundConfig's cues (found {len(cues)})")
        return
    for rel, text in files.items():
        for m in re.finditer(r'\bSfx\.(?:Play|PlayAt|PlayDistant|Loop)\(\s*"(\w+)"', text):
            if m.group(1) not in cues:
                problems.append(f"C4 {rel}:{line_of(text, m.start())} plays cue \"{m.group(1)}\", which SoundConfig doesn't define")


# --- C5 module API -----------------------------------------------------------------------------------

def defined_names(text, mod):
    names = set(re.findall(rf'^\s*function\s+{mod}[.:](\w+)', text, re.M))
    names |= set(re.findall(rf'^\s*{mod}\.(\w+)\s*=', text, re.M))
    # `local M = {}` modules that are returned under another local name
    ret = re.search(r'^return\s+(\w+)\s*$', text, re.M)
    if ret and ret.group(1) != mod:
        alias = ret.group(1)
        names |= set(re.findall(rf'^\s*function\s+{alias}[.:](\w+)', text, re.M))
        names |= set(re.findall(rf'^\s*{alias}\.(\w+)\s*=', text, re.M))
    # Keys of a table literal returned directly: `local M = { A = ..., B = ... }`
    m = re.search(rf'^local\s+{mod}\s*=\s*\{{', text, re.M)
    if m:
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        body = text[m.end():i]
        flat = re.sub(r'\{[^{}]*\}', '{}', body)
        for _ in range(4):
            flat = re.sub(r'\{[^{}]*\}', '{}', flat)
        names |= set(re.findall(r'(?:^|[,{\n])\s*(\w+)\s*=', flat))
    return names


def aliases_in(text, mod):
    """Local names this file uses for module `mod`."""
    out = set()
    for m in re.finditer(rf'local\s+(\w+)\s*=\s*require\([^()]*(?:\([^()]*\))?[^()]*"{mod}"\s*\)\s*\)', text):
        out.add(m.group(1))
    for m in re.finditer(rf'local\s+(\w+)\s*=\s*require\([^\n]*WaitForChild\(\s*"{mod}"\s*\)\s*\)', text):
        out.add(m.group(1))
    for m in re.finditer(rf'local\s+(\w+)\s*=\s*require\(\s*[\w.:]*\.{mod}\s*\)', text):
        out.add(m.group(1))
    for m in re.finditer(rf'local\s+(\w+)\s*=\s*(?:lazy|lazyRequire|getModule|tryRequire)\(\s*"{mod}"\s*\)', text):
        out.add(m.group(1))
    return out


def check_module_api(files, problems, notes):
    by_mod = {}
    for rel, text in files.items():
        by_mod.setdefault(module_name(rel), []).append(rel)
    for mod in API_MODULES:
        homes = [r for r in by_mod.get(mod, []) if not r.endswith(".client.lua") and not r.endswith(".server.lua")]
        if not homes:
            continue
        home = homes[0]
        defined = defined_names(files[home], mod)
        # Fields a module sets on ANOTHER module (ModeTeams sets BotNav.CoverHints) count as defined.
        for rel, text in files.items():
            for alias in aliases_in(text, mod) | ({mod} if rel != home else set()):
                defined |= set(re.findall(rf'(?<![\w.]){alias}\.(\w+)\s*=(?!=)', text))
        for rel, text in files.items():
            if rel == home:
                continue
            names = aliases_in(text, mod)
            if not names:
                continue
            for alias in names:
                for m in re.finditer(rf'(?<![\w.:]){alias}\s*[.:]\s*([A-Za-z_]\w*)', text):
                    field = m.group(1)
                    if field in defined:
                        continue
                    before = text[max(0, m.start() - 120):m.start()]
                    after = text[m.end():m.end() + 80]
                    optional = (re.search(rf'{alias}\.{field}\s+and\b', text[m.start():m.end() + 8])
                                or re.search(rf'(?:if|and|not|or)\s+(?:type\(\s*)?{alias}\.{field}\b', before + text[m.start():m.end()])
                                or re.search(rf'{alias}\.{field}\s*(?:~=|==)\s*nil', text[m.start():m.end() + 12]))
                    where = f"{rel}:{line_of(text, m.start())}"
                    if optional:
                        notes.append(f"C5 optional hook {mod}.{field} (guarded at {where}) is not provided yet")
                    else:
                        problems.append(f"C5 {where} uses {mod}.{field}, which {home} doesn't define")


# --- C6 gun styles -----------------------------------------------------------------------------------

def lua_map_keys(text, name):
    m = re.search(rf'(?:local\s+)?{name}\s*=\s*\{{', text)
    if not m:
        return None
    depth, i = 1, m.end()
    while i < len(text) and depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    body = text[m.end():i - 1]
    return set(re.findall(r'(?:^|[,{\s])(\w+)\s*=', body))


def check_gun_styles(files, problems, notes):
    styles, ids = set(), set()
    for rel, text in files.items():
        base = module_name(rel)
        if base in ("WeaponData", "ArsenalExpansion", "ArsenalFinish", "CreativeArsenal", "WorkshopArsenal"):
            styles |= set(re.findall(r'\bstyle\s*=\s*"(\w+)"', text))
            ids |= set(re.findall(r'\bid\s*=\s*"(\w+)"', text))
            ids |= set(re.findall(r'^\t(\w+)\s*=\s*\{', text, re.M))
    if not styles:
        problems.append("C6 couldn't read any gun styles from WeaponData / Arsenal*")
        return
    tables = [
        ("ServerScriptService/Modules/LootService.lua", None),
        ("StarterPlayerScripts/InventoryPanel.lua", "GUN_TYPE_WORDS"),
    ]
    for rel, name in tables:
        text = files.get(rel)
        if text is None:
            continue
        if name is None:
            # LootService's map is the one table carrying doublebarrel = "SHOTGUN"
            m = re.search(r'(\w+)\s*=\s*\{[^{}]*doublebarrel\s*=\s*"', text)
            name = m.group(1) if m else None
        keys = lua_map_keys(text, name) if name else None
        if not keys:
            problems.append(f"C6 couldn't read the gun type-word map in {rel}")
            continue
        for style in sorted(styles - keys):
            problems.append(f"C6 gun style \"{style}\" has no word in {rel} {name}")
    gm = files.get("ReplicatedStorage/Shared/GunModels.lua", "")
    builders = set(re.findall(r'^STYLES\.(\w+)\s*=', gm, re.M)) | set(re.findall(r'^function\s+STYLES\.(\w+)', gm, re.M))
    for style in sorted(styles - builders):
        problems.append(f"C6 gun style \"{style}\" has no GunModels STYLES builder (it would be drawn as a rifle)")
    bots = files.get("ServerScriptService/Modules/BotService.lua", "")
    hold = lua_map_keys(bots, "BOT_WEAPON_HOLD") or set()
    for gun in sorted(hold - ids):
        problems.append(f"C6 BOT_WEAPON_HOLD names \"{gun}\", which isn't a gun id")
    # Style-keyed tables in bot code (the archetype worker's ARCH.Classes, the looting worker's
    # LR.CLASS_OF_STYLE) must cover every style once they land.
    for name in ("ARCH.Classes", "LR.CLASS_OF_STYLE"):
        keys = lua_map_keys(bots, re.escape(name))
        if keys:
            for style in sorted(styles - keys - {"default", "none"}):
                problems.append(f"C6 gun style \"{style}\" missing from BotService {name}")


# --- C7 vehicle gunner -------------------------------------------------------------------------------

def check_vehicle_gunner(files, problems, notes):
    readers = [r for r, t in files.items() if re.search(r'"GunnerSeat"|GetAttribute\(\s*"Gunner"\s*\)', t)]
    makers = [r for r, t in files.items() if side(r) != "client"
              and (re.search(r'Name\s*=\s*"GunnerSeat"|"Seat"\s*,\s*"GunnerSeat"', t)
                   or re.search(r'SetAttribute\(\s*"Gunner"\s*,\s*true', t))]
    if readers and not makers:
        problems.append("C7 the gunner seat is looked for (" + ", ".join(sorted(readers)[:4])
                        + ") but no server/shared code makes a Seat named GunnerSeat or sets Gunner = true")
    for rel, text in files.items():
        if side(rel) != "client" and re.search(r'SetAttribute\(\s*"VehicleGunActive"', text):
            problems.append(f"C7 {rel} sets VehicleGunActive; it is the local client's own flag (HUD hand-off)")


# --- C8 cosmetic kinds -------------------------------------------------------------------------------

def check_cosmetic_kinds(files, problems, notes):
    cos = files.get("ReplicatedStorage/Shared/CosmeticData.lua", "")
    kinds = set(re.findall(r'\bkind\s*=\s*"(\w+)"', cos))
    if not kinds:
        problems.append("C8 couldn't read any cosmetic kinds")
        return
    pd = files.get("ServerScriptService/Modules/PlayerData.lua", "")
    equipped = re.search(r'Cosmetics\s*=\s*\{([^{}]*(?:\{\}[^{}]*)*)\}', pd)
    if equipped:
        # The save keeps one slot per kind, the kind's name with a lower-case first letter
        # (GunSkin -> gunSkin, KillAnimation -> killAnimation).
        slots = set(re.findall(r'(\w+)\s*=', equipped.group(1)))
        for kind in sorted(kinds):
            slot = kind[0].lower() + kind[1:]
            if slot not in slots:
                problems.append(f"C8 cosmetic kind \"{kind}\" has no \"{slot}\" slot in PlayerData's default Cosmetics")
    else:
        problems.append("C8 couldn't read PlayerData's default Cosmetics table")
    crate = files.get("ReplicatedStorage/Shared/CrateData.lua", "")
    for m in re.finditer(r'kinds\s*=\s*\{([^{}]*)\}', crate):
        for kind in re.findall(r'"(\w+)"', m.group(1)):
            if kind not in kinds:
                problems.append(f"C8 CrateData:{line_of(crate, m.start())} draws from cosmetic kind \"{kind}\", which CosmeticData has no item of")


CHECKS = [check_attributes, check_remotes, check_tags, check_sounds, check_module_api,
          check_gun_styles, check_vehicle_gunner, check_cosmetic_kinds]


# Findings that are true of the working branch today and already assigned, by the start of the message.
# They print as notes. When one stops matching anything the tool says so: the entry is stale, delete it.
KNOWN = {}


def run(root, known=True):
    files = load(root)
    problems, notes = [], []
    for check in CHECKS:
        check(files, problems, notes)
    if known:
        kept = []
        used = set()
        for p in problems:
            key = next((k for k in KNOWN if p.startswith(k)), None)
            if key:
                used.add(key)
                notes.append(f"known ({KNOWN[key]}): {p}")
            else:
                kept.append(p)
        for key in KNOWN:
            if key not in used:
                notes.append(f"stale KNOWN entry, the finding is gone (delete it): {key}")
        problems = kept
    return problems, notes


# --- self-test: one planted fault per contract -------------------------------------------------------

def plant(root, rel, pattern, replacement, count=1):
    path = os.path.join(root, rel)
    with open(path, encoding="utf-8") as f:
        text = f.read()
    new, n = re.subn(pattern, replacement, text, count=count)
    if n == 0:
        raise SystemExit(f"selftest: couldn't plant in {rel}: {pattern}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)


FAULTS = [
    ("C1 attribute", lambda r: plant(r, "StarterPlayerScripts/HudClient.client.lua",
                                     r'GetAttribute\("SightsUp"\)', 'GetAttribute("SightsUpp")'), "SightsUpp"),
    ("C2 remote", lambda r: plant(r, "StarterPlayerScripts/VehicleClient.client.lua",
                                  r'Remotes\.Event\("VehicleJolt"\):FireServer', 'Remotes.Event("VehicleJoltt"):FireServer'), "VehicleJoltt"),
    ("C3 tag", lambda r: plant(r, "ServerScriptService/Modules/VehicleService.lua",
                               r'(?s)\A', 'local _p = game:GetService("CollectionService"):GetTagged("NoSuchTagPlanted")\n'), "NoSuchTagPlanted"),
    ("C4 sound", lambda r: plant(r, "StarterPlayerScripts/VehicleClient.client.lua",
                                 r'Sfx\.(Play\w*)\("(\w+)"', r'Sfx.\1("\2Planted"'), "Planted\""),
    ("C5 module API", lambda r: plant(r, "ServerScriptService/Modules/ModeTeams.lua",
                                      r'function ModeTeams\.TeamOf\(', 'function ModeTeams.TeamOfRenamed('), "uses ModeTeams.TeamOf,"),
    ("C6 gun style", lambda r: plant(r, "StarterPlayerScripts/InventoryPanel.lua",
                                     r'doublebarrel = "SHOTGUN", ', ''), "\"doublebarrel\" has no word"),
    ("C6 bot hold", lambda r: plant(r, "ServerScriptService/Modules/BotService.lua",
                                    r'BOT_WEAPON_HOLD = \{', 'BOT_WEAPON_HOLD = { NotARealGunPlanted = true,'), "NotARealGunPlanted"),
    ("C7 gunner", lambda r: plant(r, "StarterPlayerScripts/VehicleWeaponClient.client.lua",
                                  r'(?s)\A', ''), "C7 the gunner seat"),
]


def selftest(root):
    base_problems, _ = run(root, known=False)
    base = set(base_problems)
    failures = 0
    for label, apply, needle in FAULTS:
        tmp = tempfile.mkdtemp(prefix="contracts_")
        try:
            for top in SRC_DIRS:
                shutil.copytree(os.path.join(root, top), os.path.join(tmp, top))
            apply(tmp)
            problems, _ = run(tmp, known=False)
            new = [p for p in problems if p not in base]
            if label.startswith("C7"):
                # The branch has no gunner-seat maker yet (the vehicles worker brings it), so C7 is
                # tested the other way round: plant a maker and confirm the finding goes away.
                plant(tmp, "ServerScriptService/Modules/VehicleService.lua", r'(?s)\A',
                      'local _g = Instance.new("Seat"); _g.Name = "GunnerSeat"\n')
                after, _ = run(tmp, known=False)
                had = any(needle in p for p in problems)
                gone = not any(needle in p for p in after)
                ok = had == any(needle in p for p in base_problems) and gone
            else:
                ok = any(needle in p for p in new)
            print(f"  {'caught' if ok else 'MISSED'}: {label}")
            failures += 0 if ok else 1
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return failures


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = os.path.abspath(args[0] if args else os.path.join(os.path.dirname(__file__), ".."))
    if "--selftest" in sys.argv:
        failures = selftest(root)
        print(f"contracts_check selftest: {len(FAULTS) - failures}/{len(FAULTS)} planted faults caught")
        sys.exit(1 if failures else 0)
    problems, notes = run(root)
    for n in notes:
        print("note:", n)
    for p in problems:
        print("PROBLEM:", p)
    print(f"contracts_check: {len(problems)} problem(s), {len(notes)} note(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
