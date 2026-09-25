"""Check for the silly explosions (StarterPlayerScripts/SillyExplosionFx.lua).

  A. Classification: every explosive in the data (launchers, explosive rounds, explosive ammo,
     collect blasts, throwables, mounted and vehicle guns, hazards) is listed here as SILLY (with its
     theme) or REALISTIC, and SillyExplosionFx.Weapons is exactly the SILLY list: every silly one has
     its theme, no realistic one has one. The two hit-only silly rounds (slipper, fidget) are themed
     hits, not blasts.
  B. Budget (lag, #131): per theme, parts (PieceCost x counts + the common parts + puffs) within
     PART_BUDGET and particles within PARTICLE_BUDGET; LIFE (every part's hard end) within 3 s;
     MAX_BLASTS and the LOD distances set; the runtime guards in place (make/ringOn refuse past the
     budget, the loop entry ends at LIFE, a crowd past MAX_BLASTS drops to FAR); no map queries
     (#71: nothing here fades or moves a wall or prop).
  C. Danger reads: every non-hit theme draws the dome to exactly the server radius and the ring to it.
  D. Wiring: ProjectileService sends weaponId on detonate/impact, ProjectileClient passes it on and
     plays ExplosiveFx.ThemeCue (falling back to the plain cue), ExplosiveFx hands themed blasts over.
  E. Gameplay identical to the base (default origin/main): the gameplay sources are byte-identical,
     and ProjectileService differs only by the weaponId fields on its two broadcasts.

    python tools/silly_explosion_check.py .            the checks
    python tools/silly_explosion_check.py . --plant    the planted faults; every one must be caught
    python tools/silly_explosion_check.py . --base REF compare gameplay against REF instead
"""

import os
import re
import subprocess
import sys

SILLY = {
    "CappuccinaLauncher": "coffee",
    "GoldenSahurCannon": "gold",
    "TamburoTungTung": "drum",
    "ToasterMortar": "toast",
    "GrandmasSlipperLauncher": "slipper",
    "FidgetDiscLauncher": "fidget",
}
HIT_ONLY = {"slipper", "fidget"}
# Explosives that stay realistic, and why (military hardware, the core grenades, hazards).
REALISTIC = {
    "TralalaThumper": "a plain six-shot grenade launcher",
    "FinalNotice": "an AK's collect blast",
    "CookedCoconut": "the core frag grenade",
    "ClingyCrumpet": "the core sticky grenade",
    "RotMine": "a landmine (server hazard fireball)",
    "ExplosiveBarrel": "a barrel (server hazard fireball)",
}
# Mounted and vehicle weapons are all realistic; they are found by file, not listed by id.
MILITARY_FILES = ("MountedGunData.lua", "VehicleWeaponData.lua")

MODULE = "StarterPlayerScripts/SillyExplosionFx.lua"
FX = "StarterPlayerScripts/ExplosiveFx.lua"
CLIENT = "StarterPlayerScripts/ProjectileClient.client.lua"
SERVICE = "ServerScriptService/Modules/ProjectileService.lua"
SHARED = "ReplicatedStorage/Shared/"
WEAPON_FILES = ["WeaponData.lua", "CreativeArsenal.lua", "WorkshopArsenal.lua", "ArsenalExpansion.lua"]
GAMEPLAY = [SHARED + f for f in WEAPON_FILES + ["CreativeRounds.lua", "Ballistics.lua", "ItemData.lua",
            "MountedGunData.lua", "VehicleWeaponData.lua"]] + [
    "ServerScriptService/Modules/HazardService.lua", "ServerScriptService/Modules/CombatService.lua",
    "ServerScriptService/Modules/DestructibleService.lua"]


def read(root, rel):
    path = os.path.join(root, rel)
    return open(path, encoding="utf-8").read() if os.path.exists(path) else None


def blocks(src):
    """Top-level `\tName = { ... \t}` entries of a data table (tab-indented, as every weapon file is)."""
    return {m.group(1): m.group(2) for m in re.finditer(r"^\t(\w+) = \{(.*?)^\t\},?$", src, re.M | re.S)}


def lua_table(src, name):
    m = re.search(r"^" + re.escape(name) + r" = \{(.*?)^\}", src, re.M | re.S)
    return m.group(1) if m else None


def number(src, name):
    m = re.search(r"^Silly\." + name + r" = ([\d.]+)", src, re.M)
    return float(m.group(1)) if m else None


def explosives(srcs):
    """Every explosive weapon/item id found in the data: {id: how}."""
    found = {}
    ball = srcs[SHARED + "Ballistics.lua"] + "\n" + srcs[SHARED + "CreativeRounds.lua"]
    rounds = {"rocket": True, "grenade": True}
    for m in re.finditer(r'RegisterRound\("(\w+)", \{(.*?)^\}\)', ball, re.M | re.S):
        rounds[m.group(1)] = "explosive = false" not in m.group(2)
    for f in WEAPON_FILES:
        for wid, body in blocks(srcs[SHARED + f]).items():
            proj = re.search(r'projectile = "(\w+)"', body)
            if proj:
                found[wid] = "round " + proj.group(1) if rounds.get(proj.group(1), True) else "hit-only round " + proj.group(1)
            elif "explosiveAmmo" in body:
                found[wid] = "explosive ammo"
            elif re.search(r'ability = "explosive"', body):
                found[wid] = "explosive bullets"
            elif re.search(r"\bcollect = \{", body):
                found[wid] = "collect blast"
    throw = srcs[SHARED + "Ballistics.lua"].split("Ballistics.Throwables = {", 1)[-1].split("\n}", 1)[0]
    for tid, body in re.findall(r"^\t(\w+) = \{(.*?)^\t\},?$", throw, re.M | re.S):
        if "blastDamage" in body:
            found[tid] = "throwable"
    for hazard in ("RotMine", "ExplosiveBarrel"):
        found[hazard] = "hazard"
    return found


def check(srcs, base):
    problems = []
    mod = srcs[MODULE]
    if mod is None:
        return [f"{MODULE} is missing"], {}

    # A. Classification.
    weapons = dict(re.findall(r"^\t(\w+) = \"(\w+)\",", lua_table(mod, "Silly.Weapons") or "", re.M))
    for wid, theme in SILLY.items():
        if weapons.get(wid) != theme:
            problems.append(f"A: silly {wid} must have theme {theme!r}, has {weapons.get(wid)!r}")
    for wid in weapons:
        if wid in REALISTIC:
            problems.append(f"A: realistic {wid} ({REALISTIC[wid]}) must not have a silly theme")
        elif wid not in SILLY:
            problems.append(f"A: {wid} has a theme but isn't in this check's SILLY list")
    found = explosives(srcs)
    military = set()
    for f in MILITARY_FILES:
        military |= set(blocks(srcs[SHARED + f]))
    for wid, how in sorted(found.items()):
        if wid not in SILLY and wid not in REALISTIC and wid not in military and not how.startswith("hit-only"):
            problems.append(f"A: explosive {wid} ({how}) is neither SILLY nor REALISTIC here: classify it")
    for wid in SILLY:
        if wid not in found:
            problems.append(f"A: silly {wid} isn't an explosive or themed round in the data any more")

    # B. Budget.
    part_budget, particle_budget = number(mod, "PART_BUDGET"), number(mod, "PARTICLE_BUDGET")
    life, max_blasts = number(mod, "LIFE"), number(mod, "MAX_BLASTS")
    lod_full, lod_mid = number(mod, "LOD_FULL"), number(mod, "LOD_MID")
    if not part_budget or part_budget > 30:
        problems.append(f"B: PART_BUDGET {part_budget} must be set and at most 30")
    if not particle_budget or particle_budget > 60:
        problems.append(f"B: PARTICLE_BUDGET {particle_budget} must be set and at most 60")
    if not life or life > 3:
        problems.append(f"B: LIFE {life} must be set and at most 3 s (short-lived parts gone within 3 s)")
    if not max_blasts or not 1 <= max_blasts <= 8:
        problems.append(f"B: MAX_BLASTS {max_blasts} must be 1-8")
    if not lod_full or not lod_mid or not lod_full < lod_mid <= 650:
        problems.append(f"B: LOD_FULL {lod_full} < LOD_MID {lod_mid} <= 650 (the client's cull)")
    cost = dict((k, int(v)) for k, v in re.findall(r"(\w+) = (\d+)", (re.search(r"Silly\.PieceCost = \{(.*?)\}", mod) or [None, ""])[1]))
    common = dict((k, int(v)) for k, v in re.findall(r"(\w+) = (\d+)", (re.search(r"Silly\.CommonCost = \{(.*?)\}", mod) or [None, ""])[1]))
    themes_src = lua_table(mod, "Silly.Themes") or ""
    themes = blocks(themes_src)
    per_theme = {}
    for theme in sorted(set(SILLY.values())):
        body = themes.get(theme)
        if body is None:
            problems.append(f"B: theme {theme} has no entry in Silly.Themes")
            continue
        hit = "hit = true" in body
        if hit != (theme in HIT_ONLY):
            problems.append(f"B: theme {theme} hit = {hit}, but it should be {theme in HIT_ONLY}")
        if not re.search(r'sound = "[A-Z]\w+"', body) or not re.search(r'word = "[^"]+"', body):
            problems.append(f"B: theme {theme} needs a sound key and a word")
        pieces = dict((k, int(v)) for k, v in re.findall(r"(\w+) = (\d+)", (re.search(r"pieces = \{(.*?)\}", body) or [None, ""])[1]))
        particles = sum(int(v) for v in re.findall(r"= (\d+)", (re.search(r"particles = \{(.*?)\}", body) or [None, ""])[1]))
        puffs = int((re.search(r"puffs = (\d+)", body) or [None, 0])[1])
        if not pieces:
            problems.append(f"B: theme {theme} throws no pieces of its own")
        unknown = [p for p in pieces if p not in cost or not re.search(r"^function BUILD\." + p + r"\(", mod, re.M)]
        if unknown:
            problems.append(f"B: theme {theme} uses pieces with no PieceCost or BUILD: {unknown}")
        parts = sum(cost.get(p, 99) * n for p, n in pieces.items()) + puffs + common.get("flash", 1) + common.get("word", 1)
        if not hit:
            parts += common.get("dome", 1) + common.get("ring", 1)
        per_theme[theme] = (parts, particles)
        if part_budget and parts > part_budget:
            problems.append(f"B: theme {theme} costs {parts} parts, over PART_BUDGET {part_budget:.0f}")
        if particle_budget and particles > particle_budget:
            problems.append(f"B: theme {theme} emits {particles} particles, over PARTICLE_BUDGET {particle_budget:.0f}")
    guards = {
        "make() refuses past PART_BUDGET": r"local function make\(.*?\n\tif b\.count >= Silly\.PART_BUDGET then\n\t\treturn nil",
        "ringOn() refuses past PART_BUDGET": r"local function ringOn\(.*?\n\tif b\.count >= Silly\.PART_BUDGET then\n\t\treturn nil",
        "the blast's loop entry ends at LIFE": r"api\.add\(\{\n\t\tlife = Silly\.LIFE,",
        "a piece's life is capped under LIFE": r"life = math\.min\(options\.life or [\d.]+, Silly\.LIFE",
        "particles capped at PARTICLE_BUDGET": r"local left = Silly\.PARTICLE_BUDGET",
        "a crowd past MAX_BLASTS drops to FAR": r"if Silly\.Active >= Silly\.MAX_BLASTS then\n\t\treturn \"far\"",
        "the active count comes down on destroy": r"Silly\.Active = math\.max\(0, Silly\.Active - 1\)",
    }
    for what, pattern in guards.items():
        if not re.search(pattern, mod, re.S):
            problems.append(f"B: guard missing: {what}")
    if re.search(r'Instance\.new\("(Part|MeshPart|WedgePart)"\)', mod):
        problems.append("B: parts must come through make() (the budget), not Instance.new")
    if len(re.findall(r"(?<!b\.)\bapi\.part\(", mod)) != 1 or len(re.findall(r"\bb\.api\.part\(", mod)) != 1:
        problems.append("B: api.part is called outside make() and the particle host")
    for banned in ("GetDescendants", "GetPartBoundsInRadius", "GetPartBoundsInBox", "GetPartsInPart", "FindPartsInRegion", "Raycast", "TweenService"):
        if banned in mod:
            problems.append(f"B: {banned} in SillyExplosionFx: it draws its own pieces only and never touches the map (#71)")

    # C. Danger reads.
    if not re.search(r"if not theme\.hit then\n\t\tdome = make\(", mod):
        problems.append("C: a non-hit theme must always get the dome")
    if "local size = r * 2 * easeOut(" not in mod:
        problems.append("C: the dome must swell to exactly the blast radius (diameter r * 2)")
    if "local reach = 0.5 + (r - 0.5) * easeOut(" not in mod:
        problems.append("C: the danger ring must race out to exactly the blast radius")
    if "local r = math.max(2, radius)" not in mod:
        problems.append("C: the blast radius r must be the server's radius (math.max(2, radius))")

    # D. Wiring.
    fx, client, service = srcs[FX], srcs[CLIENT], srcs[SERVICE]
    wiring = {
        FX: [(fx, r"local theme = SillyExplosionFx\.ThemeFor\(weaponId\)\n\tif theme then\n\t\tSillyExplosionFx\.Blast\(sillyApi, theme, position, [^\n]*, radius or 12, ground\)")],
        CLIENT: [(client, r"ExplosiveFx\.Explosion\(position, normal, BLAST_LOOK\[kind\] or \"frag\", radius, info\.weaponId\)"),
                 (client, r"local cue = ExplosiveFx\.ThemeCue\(info\.weaponId\) or BLAST_CUE\[kind\]"),
                 (client, r"ExplosiveFx\.Impact\([^\n]*, info\.weaponId\)")],
        SERVICE: [(service, r"broadcast\(\"detonate\", \{[^}]*weaponId = blast\.weaponId,"),
                  (service, r"broadcast\(\"impact\", \{[^}]*weaponId = entry\.weaponId \}\)")],
        MODULE: [(mod, r'local key = "Explosion" \.\. theme\.sound'), (mod, r"pcall\(SoundConfig\.Get, key\)")],
    }
    for path, rules in wiring.items():
        for src, pattern in rules:
            if not src or not re.search(pattern, src):
                problems.append(f"D: {path} lacks {pattern[:70]}")

    # E. Gameplay identical to the base.
    if base is None:
        problems.append("E: no base to compare gameplay against (git show failed)")
    else:
        for path in GAMEPLAY:
            if path in base and srcs.get(path) != base[path]:
                problems.append(f"E: {path} differs from the base: gameplay must be unchanged")

        def strip(text):
            text = re.sub(r"^\t+-- [^\n]*themed blast[^\n]*\n", "", text, flags=re.M)
            text = re.sub(r"^\t+weaponId = blast\.weaponId,\n", "", text, flags=re.M)
            return text.replace(", weaponId = entry.weaponId }", " }")
        if SERVICE in base and strip(service) != strip(base[SERVICE]):
            problems.append(f"E: {SERVICE} differs from the base by more than the weaponId look fields")
    return problems, per_theme


def load(root):
    paths = GAMEPLAY + [MODULE, FX, CLIENT, SERVICE]
    return {p: read(root, p) for p in paths}


def load_base(root, ref):
    base = {}
    for p in GAMEPLAY + [SERVICE]:
        try:
            out = subprocess.run(["git", "-C", root, "show", f"{ref}:{p}"], capture_output=True, check=True)
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
        base[p] = out.stdout.decode("utf-8").replace("\r\n", "\n")
    return base or None


def plant(srcs, path, old, new):
    changed = dict(srcs)
    assert old in changed[path], f"plant anchor missing in {path}: {old!r}"
    changed[path] = changed[path].replace(old, new, 1)
    return changed


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    ref = sys.argv[sys.argv.index("--base") + 1] if "--base" in sys.argv else "origin/main"
    srcs = {p: (s.replace("\r\n", "\n") if s else s) for p, s in load(root).items()}
    base = load_base(root, ref)
    if "--plant" in sys.argv:
        plants = [
            ("silly weapon loses its theme", MODULE, '\tToasterMortar = "toast",\n', ""),
            ("realistic weapon given a theme", MODULE, '\tFidgetDiscLauncher = "fidget",\n', '\tFidgetDiscLauncher = "fidget",\n\tTralalaThumper = "coffee",\n'),
            ("part budget blown", MODULE, "pieces = { coin = 10 }", "pieces = { coin = 30 }"),
            ("cleanup past 3 s", MODULE, "Silly.LIFE = 2.5", "Silly.LIFE = 4"),
            ("gameplay changed (damage)", SHARED + "WeaponData.lua", "damage = 68,", "damage = 70,"),
            ("danger dome dropped", MODULE, "\tif not theme.hit then\n\t\tdome = make(", "\tif false then\n\t\tdome = make("),
        ]
        caught = 0
        clean, _ = check(srcs, base)
        for name, path, old, new in plants:
            found, _ = check(plant(srcs, path, old, new), base)
            fresh = [p for p in found if p not in clean]
            print(f"plant {name}: {'CAUGHT' if fresh else 'MISSED'}" + (f" ({fresh[0]})" if fresh else ""))
            caught += bool(fresh)
        print(f"silly explosion plants: {caught}/{len(plants)} caught")
        sys.exit(0 if caught == len(plants) else 1)
    problems, per_theme = check(srcs, base)
    for theme, (parts, particles) in per_theme.items():
        print(f"  {theme:8s} {parts:2d} parts, {particles:2d} particles")
    for p in problems:
        print("PROBLEM", p)
    print(f"silly explosion check: {len(SILLY)} silly, {len(REALISTIC)} realistic + mounted/vehicle, {len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
