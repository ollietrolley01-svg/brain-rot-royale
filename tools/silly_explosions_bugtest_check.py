"""Bug test of the silly-explosions work (2e1abc4, 57fd4f0, f9f0af6, 9fb4e83) on the tree it runs on.

Runs the REAL game modules under lupa (tools/destruct_mocks.lua + tools/silly_explosions_bugtest_world.lua)
and reads the rest from source. Each check is an invariant the code must keep:

  S1  HazardService: a barrel, its chain, a shot mine and a stepped-on mine make exactly the same damage,
      kill-credit, weapon (kill-feed) and splash calls on main as on BASE (main just before the silly
      merge, with its bare Explosions); BASE's Explosions had no physics (radius, pressure and joint
      break all 0); main makes no Explosion; the detonate cue's radius equals the radius the damage used.
  S2  MountedGuns.breakGun: same calls on main as on BASE; the cue sits where BASE's Explosion did.
  K1  every server "detonate" sender carries position/normal/kind/radius/weaponId; ProjectileClient
      handles "detonate"; every hazard weaponId has a WEAPON_CUE whose key SoundConfig defines.
  K2  no game file makes an Explosion or reads/writes BlastCue (the listener is gone, so one would be
      silent and unseen).
  K3  ProjectileService's detonate sends the same `radius` its damage loop uses.
  K4  every silly theme's sound key ("Explosion" .. sound) exists in SoundConfig.
  C1  every instance a blast makes (each realistic kind, the hazards, both wrecks, every silly theme, a
      plain hit) is gone once it's over; ExplosiveFx's liveBlasts and Silly.Active are back to 0.
  C2  a busy stretch of staggered blasts leaves both counters at 0 and the next blast full.
  C3  ExplosiveFx.Clear mid-blast (the "clear" action) leaves nothing and both counters at 0.
  C4a the crowd budget: with 3 blasts live, a 4th is drawn light (no chunks, no column).
  C4b hit-only rounds (no blast) never push a real blast into that light look.
  C5  the silly cap counts blasts only; MAX_BLASTS live silly blasts drop the next to FAR.
  C6  every silly weapon names a complete theme; hazard, wreck and junk ids get none.
  C7  a themed blast's own pieces stay within EXTRA_BUDGET (counted as made).
  C8  the danger ring ends at exactly the server radius; a hit-only round draws none.
  C9a a vehicle wrecked in sight gets one blast on the frame it happens, never a second.
  C9b a vehicle wrecked out of VehicleClient's range gets no blast when you later drive up to it.

KNOWN_FINDINGS are invariants that fail on main today (reports/bugtest-silly-explosions.md). They
print as FINDING and don't fail the run; if one starts passing, the run says so. Every other failure
is a problem. `--plant` breaks each invariant that holds today in a copy of the source and requires
its check to fail.

    /tmp/brr-venv/bin/python tools/silly_explosions_bugtest_check.py .
    /tmp/brr-venv/bin/python tools/silly_explosions_bugtest_check.py . --plant
"""

import os
import re
import subprocess
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else ".")
# Main just before the silly explosions merged (8ee9c9f^2, "Merge pc/ttk-plus-25"): HazardService and
# MountedGuns still made their bare Explosions there, and differ from main only by that change.
BASE = "25839e2"
DAMAGE_SCALE = 0.736  # MatchConfig.CombatDamageScale on main (CombatService.lua:454 applies it)

FILES = {
    "hazard": "ServerScriptService/Modules/HazardService.lua",
    "gun": "ServerScriptService/Modules/MountedGuns.lua",
    "service": "ServerScriptService/Modules/ProjectileService.lua",
    "fx": "StarterPlayerScripts/ExplosiveFx.lua",
    "silly": "StarterPlayerScripts/SillyExplosionFx.lua",
    "client": "StarterPlayerScripts/ProjectileClient.client.lua",
    "wreck": "ReplicatedStorage/Shared/VehicleWreckFx.lua",
    "sound": "ReplicatedStorage/Shared/SoundConfig.lua",
}
GAME_DIRS = ["ServerScriptService", "StarterPlayerScripts", "ReplicatedStorage", "StarterGui", "StarterCharacterScripts",
             "ReplicatedFirst", "ServerStorage", "Workspace"]

KNOWN_FINDINGS = {
    "C4b": "ExplosiveFx counts every Impact (a hit with no blast) as a live blast, so a dart pistol's hits "
           "strip the next real blast's chunks and smoke column (ExplosiveFx.lua:623-627, :844-845)",
    "C9b": "VehicleWreckFx.OnWreck fires whenever a wreck first comes back into VehicleClient's 320-stud range, "
           "however long ago it was wrecked (VehicleWreckFx.lua:78-81 + VehicleClient.client.lua:748-762)",
}


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def git_show(ref, rel):
    out = subprocess.run(["git", "-C", str(ROOT), "show", f"{ref}:{rel}"], capture_output=True, check=True)
    return out.stdout.decode("utf-8").replace("\r\n", "\n")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w\.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def silly_to_lua(source):
    """Compound assignments, and Luau's `continue` (only in stepFlyers/stepRibbons) as a goto."""
    source = luau_to_lua(source)
    for head in ("local function stepFlyers(", "local function stepRibbons("):
        a = source.index(head)
        b = source.index("\n\tend\nend\n", a)
        body = re.sub(r"^(\s*)continue$", r"\1goto continue_", source[a:b], flags=re.M)
        source = source[:a] + body + "\n\t\t::continue_::" + source[b:]
    if re.search(r"^\s*continue$", source, re.M):
        raise SystemExit("SillyExplosionFx: a `continue` outside stepFlyers/stepRibbons; teach silly_to_lua")
    return source


def cut(src, head):
    a = src.index(head)
    return src[a:src.index("\nend\n", a) + 5]


def runtime():
    lua = LuaRuntime(unpack_returned_tuples=True)
    mock = lua.execute(read("tools/destruct_mocks.lua"))
    world = lua.execute(read("tools/silly_explosions_bugtest_world.lua"))
    return lua, mock, world


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


def sound_keys(srcs):
    return set(re.findall(r"^\t(\w+) = \{", srcs["sound"], re.M))


# ------------------------------------------------------------------------------------------ server

def hazard_run(src):
    lua, mock, world = runtime()
    s = world.hazard(mock, lua.compile(luau_to_lua(src)))
    log, sent, explosions = s.run()
    sent = [dict(x.items()) for x in lua_list(sent)]
    explosions = [dict(x.items()) for x in lua_list(explosions)]
    return lua_list(log), sent, explosions


def check_s1(srcs, base):
    old_log, old_sent, old_expl = hazard_run(base["hazard"])
    new_log, new_sent, new_expl = hazard_run(srcs["hazard"])
    lines, ok = [], True
    same = old_log == new_log
    ok &= same
    calls = [l for l in new_log if not l.startswith("--")]
    lines.append(f"  {len(calls)} server calls on main (InRadius, DealDamage, splash on companions/structures/walls, quests), "
                 f"{len([l for l in old_log if not l.startswith('--')])} on BASE: " + ("identical, in order" if same else "DIFFERENT"))
    if not same:
        for a, b in zip(old_log + [""] * 40, new_log + [""] * 40):
            if a != b:
                lines.append(f"    BASE: {a}\n    main: {b}")
                break
    for l in new_log:
        m = re.match(r"DealDamage by=(\S+) to=(\S+) amount=([\d.]+) weapon=(\S+)", l)
        if m:
            lines.append(f"    {m.group(1):>3} -> {m.group(2)}: {float(m.group(3)):6.2f} base, {float(m.group(3)) * DAMAGE_SCALE:6.2f} "
                         f"after CombatDamageScale {DAMAGE_SCALE}, weapon {m.group(4)}")
        elif l.startswith("--") or l.startswith("Quest") or l.startswith("Companions"):
            lines.append("    " + l)
    zero = all(e.get("BlastRadius") == 0 and e.get("BlastPressure") == 0 and e.get("DestroyJointRadiusPercent") == 0 for e in old_expl)
    ok &= zero and len(old_expl) == 4 and len(new_expl) == 0
    lines.append(f"  BASE made {len(old_expl)} Explosions, all radius/pressure/joint-break 0: {zero}; main makes {len(new_expl)}")
    hit = re.findall(r"\.Hit\b", base["hazard"])
    ok &= not hit
    lines.append(f"  BASE connects Explosion.Hit: {'yes' if hit else 'no'}")
    radii = [float(m) for m in re.findall(r"InRadius r=([\d.]+)", "\n".join(new_log)) if float(m) != 5.5]
    sent_r = [float(x["radius"]) for x in new_sent if x.get("action", "detonate") and x.get("radius") is not None]
    ids = [x.get("weaponId") for x in new_sent]
    match = radii == sent_r and ids == ["ExplosiveBarrel", "ExplosiveBarrel", "RotMine", "RotMine"]
    ok &= match
    lines.append(f"  detonate cues sent {sent_r} for {ids}; damage radii used {radii}: " + ("equal" if match else "DIFFERENT"))
    return ok, "\n".join(lines)


def check_s2(srcs, base):
    def run(src):
        lua, mock, world = runtime()
        chunk = lua.compile("local life, release, CombatService, Remotes = ...\n" + luau_to_lua(cut(src, "local function breakGun(model, attacker)")) + "\nreturn breakGun")
        s = world.gun(mock, chunk)
        log, sent, expl = s.run()
        return lua_list(log), [dict(x.items()) for x in lua_list(sent)], [dict(x.items()) for x in lua_list(expl)]
    old_log, _, old_expl = run(base["gun"])
    new_log, new_sent, new_expl = run(srcs["gun"])
    ok = old_log == new_log
    lines = [f"  breakGun twice (the second must do nothing): {len(new_log)} calls, " + ("identical to BASE" if ok else "DIFFERENT from BASE")]
    lines += ["    " + l for l in new_log]
    zero = len(old_expl) == 1 and all(e.get("BlastRadius") == 0 and e.get("BlastPressure") == 0 and e.get("DestroyJointRadiusPercent") == 0 for e in old_expl)
    at = len(new_sent) == 1 and len(old_expl) == 1 and abs(new_sent[0]["position"].X - old_expl[0]["Position"].X) + abs(new_sent[0]["position"].Y - old_expl[0]["Position"].Y) + abs(new_sent[0]["position"].Z - old_expl[0]["Position"].Z) < 1e-9
    cue = len(new_sent) == 1 and new_sent[0]["kind"] == "grenade" and new_sent[0]["weaponId"] == "MountedGunWreck"
    ok = ok and zero and at and cue and not new_expl
    lines.append(f"  BASE: {len(old_expl)} Explosion, no physics: {zero}; main: {len(new_expl)} Explosions, {len(new_sent)} detonate "
                 f"cue ({new_sent[0]['kind'] if new_sent else '-'}, radius {new_sent[0]['radius'] if new_sent else '-'}, "
                 f"{new_sent[0]['weaponId'] if new_sent else '-'}) where the Explosion was: {at}")
    return ok, "\n".join(lines)


# -------------------------------------------------------------------------------------- contracts

def game_files():
    for d in GAME_DIRS:
        for p in sorted((ROOT / d).rglob("*.lua")) if (ROOT / d).exists() else []:
            yield p.relative_to(ROOT).as_posix()


def lua_table_body(src, name):
    m = re.search(r"^local " + name + r" = \{(.*?)\}\s*$", src, re.M | re.S)
    return m.group(1) if m else ""


def check_k1(srcs):
    lines, ok = [], True
    senders = 0
    required = ["position", "normal", "kind", "radius", "weaponId"]
    cue = dict(re.findall(r'(\w+) = "(\w+)"', lua_table_body(srcs["client"], "WEAPON_CUE")))
    look = set(re.findall(r"(\w+) = \"", lua_table_body(srcs["client"], "BLAST_LOOK")))
    keys = sound_keys(srcs)
    hazard_ids = dict(re.findall(r'^HazardService\.(WeaponId|MineWeaponId) = "(\w+)"', srcs["hazard"], re.M))
    for rel in game_files():
        src = srcs.get(rel) or read(rel)
        for m in re.finditer(r'(?:FireAllClients|FireClient|broadcast)\((?:[^()"]*,\s*)?"detonate",\s*\{(.*?)\n\t*\}\)', src, re.S):
            senders += 1
            body = m.group(1)
            fields = dict(re.findall(r"^\s*(\w+) = (.+?),?\s*$", body, re.M))
            line = src[:m.start()].count("\n") + 1
            missing = [k for k in required if k not in fields]
            ids = re.findall(r'"(\w+)"', fields.get("weaponId", ""))
            if fields.get("weaponId") == "weaponId" and rel == FILES["hazard"]:
                ids = list(hazard_ids.values())
            kind = re.findall(r'"(\w+)"', fields.get("kind", ""))
            bad = [i for i in ids if i not in cue or cue[i] not in keys]
            badkind = [k for k in kind if k not in look]
            ok &= not missing and not bad and not badkind
            lines.append(f"  {rel}:{line}: fields {'all there' if not missing else 'MISSING ' + str(missing)}"
                         + (f"; weaponIds {ids} -> cues {[cue.get(i) for i in ids]}" if ids else "; weaponId per round")
                         + (f", kind {kind}" if kind else "") + (f" PROBLEM {bad or ''}{badkind or ''}" if bad or badkind else ""))
    handler = re.search(r'action == "detonate" then\s*\n\s*onDetonate\(info\)', srcs["client"]) is not None
    reads = all(f"info.{k}" in cut(srcs["client"], "local function onDetonate(info)") for k in required)
    ok &= handler and reads and senders >= 3
    lines.insert(0, f"  {senders} detonate senders; ProjectileClient routes \"detonate\" to onDetonate: {handler}, which reads all five fields: {reads}; "
                    f"WEAPON_CUE {cue}")
    return ok, "\n".join(lines)


def check_k2(srcs):
    found, n = [], 0
    for rel in game_files():
        n += 1
        src = srcs.get(rel) or read(rel)
        for pat in (r'Instance\.new\("Explosion"', r"BlastCue", r'IsA\("Explosion"\)'):
            for m in re.finditer(pat, src):
                found.append(f"{rel}:{src[:m.start()].count(chr(10)) + 1} {pat}")
    return not found, f"  {n} game files read; Explosion made / BlastCue / IsA(\"Explosion\"): {found or 'none'}"


def check_k3(srcs):
    body = cut(srcs["service"], "local function explode(blast)")
    local = re.search(r"^\tlocal radius = blast\.radius$", body, re.M) is not None
    sent = re.search(r'broadcast\("detonate", \{[^}]*?\n\t\tradius = radius,', body, re.S) is not None
    used = "CombatService.InRadius(centre, radius + Ballistics.BodyAllowance" in body and "Ballistics.BlastScale(distance, blast.innerRadius or 0, radius)" in body
    ok = local and sent and used
    return ok, (f"  ProjectileService explode(): local radius = blast.radius: {local}; detonate sends that radius: {sent}; "
                f"InRadius/BlastScale use it: {used}")


def check_k4(srcs):
    keys = sound_keys(srcs)
    sounds = re.findall(r'^\t\tsound = "(\w+)"', srcs["silly"], re.M)
    missing = ["Explosion" + s for s in sounds if "Explosion" + s not in keys]
    return not missing and len(sounds) >= 6, f"  {len(sounds)} theme sounds {sounds}; missing SoundConfig keys: {missing or 'none'}"


# ----------------------------------------------------------------------------------------- client

def client_check(name, srcs):
    lua, mock, world = runtime()
    keys = lua.table_from({k: True for k in sound_keys(srcs)})
    s = world.client(mock, lua.compile(luau_to_lua(srcs["fx"])), lua.compile(silly_to_lua(srcs["silly"])), keys)
    r = s[name]()
    return bool(r.ok), r.text


def wreck_check(name, srcs):
    lua, mock, world = runtime()
    s = world.wreck(mock, lua.compile(luau_to_lua(srcs["wreck"])))
    r = s[name]()
    return bool(r.ok), r.text


CHECKS = [
    ("S1", "HazardService: damage, credit and kill-feed unchanged; no Explosion; cue radius = damage radius", lambda s, b: check_s1(s, b)),
    ("S2", "MountedGuns.breakGun unchanged but for the cue", lambda s, b: check_s2(s, b)),
    ("K1", "detonate senders and the client's handler agree", lambda s, b: check_k1(s)),
    ("K2", "no bare Explosion or BlastCue left anywhere", lambda s, b: check_k2(s)),
    ("K3", "ProjectileService sends the radius it damages with", lambda s, b: check_k3(s)),
    ("K4", "every theme's sound key exists", lambda s, b: check_k4(s)),
    ("C1", "every blast cleans up after itself; counters back to 0", lambda s, b: client_check("C1", s)),
    ("C2", "a busy stretch leaves no count behind", lambda s, b: client_check("C2", s)),
    ("C3", "Clear mid-blast leaves nothing, counters 0", lambda s, b: client_check("C3", s)),
    ("C4a", "the crowd budget draws the 4th live blast light", lambda s, b: client_check("C4a", s)),
    ("C4b", "hit-only rounds never crowd a real blast", lambda s, b: client_check("C4b", s)),
    ("C5", "the silly cap counts blasts only", lambda s, b: client_check("C5", s)),
    ("C6", "theme lookup: complete for silly ids, none for the rest", lambda s, b: client_check("C6", s)),
    ("C7", "a theme's pieces stay in EXTRA_BUDGET", lambda s, b: client_check("C7", s)),
    ("C8", "danger ring at exactly the server radius", lambda s, b: client_check("C8", s)),
    ("C9a", "a wreck in sight gets one blast, on time", lambda s, b: wreck_check("C9a", s)),
    ("C9b", "a wreck out of range gets no late blast", lambda s, b: wreck_check("C9b", s)),
]

# Each breaks an invariant that holds on main today; its check must then fail.
PLANTS = [
    ("barrel falloff changed", "hazard", "math.clamp(0.35 + falloff * 0.65, 0, 1)", "math.clamp(0.4 + falloff * 0.6, 0, 1)", "S1"),
    ("hazard cue radius off the damage radius", "hazard", "\t\tradius = radius,\n\t\tweaponId = weaponId,", "\t\tradius = radius * 1.2,\n\t\tweaponId = weaponId,", "S1"),
    ("hazard kill-feed weapon changed", "hazard", "CombatService.DealDamage(attackerToken, victim.token, damage, weaponId)",
     'CombatService.DealDamage(attackerToken, victim.token, damage, "Explosion")', "S1"),
    ("hazard kill credit dropped", "hazard", "CombatService.DealDamage(attackerToken, victim.token, damage, weaponId)",
     "CombatService.DealDamage(entry.owner, victim.token, damage, weaponId)", "S1"),
    ("broken gun's hit marker moved", "gun", 'CombatService.ConfirmHit(attacker, 0, true, flash.Position, "vehicle")',
     'CombatService.ConfirmHit(attacker, 0, true, flash.Position + Vector3.new(0, 5, 0), "vehicle")', "S2"),
    ("a hazard's cue dropped from WEAPON_CUE", "client", 'RotMine = "ExplosionMine", ', "", "K1"),
    ("a bare tagged Explosion back in", "hazard", "\tlocal parent = model.Parent or workspace\n",
     '\tlocal parent = model.Parent or workspace\n\tlocal blast = Instance.new("Explosion")\n\tblast:SetAttribute("BlastCue", "ExplosionBarrel")\n\tblast.Parent = workspace\n', "K2"),
    ("projectile cue radius halved", "service", "\t\tradius = radius,\n\t\t-- Which gun", "\t\tradius = radius * 0.5,\n\t\t-- Which gun", "K3"),
    ("a theme's sound key renamed", "silly", 'sound = "Coffee",', 'sound = "Latte",', "K4"),
    ("liveBlasts never counted down", "fx", "liveBlasts = math.max(0, liveBlasts - 1)", "liveBlasts = math.max(0, liveBlasts - 0)", "C2"),
    ("Silly.Active never counted down", "silly", "Silly.Active = math.max(0, Silly.Active - 1)", "Silly.Active = math.max(0, Silly.Active - 0)", "C2"),
    ("a blast's fireballs never destroyed (leak in the effects folder)", "fx", "\t\tdestroy = function(entry)\n\t\t\tdestroyParts(entry)\n\t\t\tliveBlasts",
     "\t\tdestroy = function(entry)\n\t\t\tliveBlasts", "C1"),
    ("a ring adornment not tracked (leak)", "silly", "\tring.Parent = workspace.Terrain\n\ttable.insert(b.parts, ring)\n", "\tring.Parent = workspace.Terrain\n", "C1"),
    ("Clear forgets the destroy callbacks", "fx", "\t\tlive[index].destroy(live[index])\n\t\tlive[index] = nil", "\t\tlive[index] = nil", "C3"),
    ("crowd budget off", "fx", "local crowded = liveBlasts >= LIVE_BLASTS", "local crowded = false", "C4a"),
    ("hit-only rounds counted in the silly cap", "silly", "local counted = not theme.hit", "local counted = true", "C5"),
    ("a silly weapon names a missing theme", "silly", 'CappuccinaLauncher = "coffee",', 'CappuccinaLauncher = "latte",', "C6"),
    ("make() stops refusing past the budget, party throws 30 confetti", "silly", [
        ("\tif b.count >= Silly.EXTRA_BUDGET then\n\t\treturn nil\n\tend\n\tb.count += 1\n\tlocal instance", "\tb.count += 1\n\tlocal instance"),
        ("pieces = { confetti = 14, streamer = 3 },", "pieces = { confetti = 30, streamer = 3 },")], None, "C7"),
    ("danger ring short of the radius", "silly", "local r = math.max(2, radius)", "local r = math.max(2, radius * 0.8)", "C8"),
    ("wreck blast on every frame", "wreck", "seenWrecked[model] = wrecked == true", "seenWrecked[model] = false", "C9a"),
]


def load_sources():
    srcs = {k: read(v) for k, v in FILES.items()}
    base = {k: git_show(BASE, FILES[k]) for k in ("hazard", "gun")}
    # K1/K2 walk every game file; the loaded ones are served from `srcs` so a plant reaches them.
    for k, v in FILES.items():
        srcs[v] = srcs[k]
    return srcs, base


def run_check(check, srcs, base):
    try:
        return check[2](srcs, base)
    except Exception as err:  # a check that throws has failed
        return False, f"  ERROR {type(err).__name__}: {str(err)[:400]}"


def main():
    srcs, base = load_sources()
    print(f"tree: {subprocess.run(['git', '-C', str(ROOT), 'rev-parse', '--short', 'HEAD'], capture_output=True).stdout.decode().strip()}; "
          f"BASE {BASE} (main before the silly merge); damage quoted at CombatDamageScale {DAMAGE_SCALE}")
    problems, findings = 0, 0
    results = {}
    for check in CHECKS:
        ok, text = run_check(check, srcs, base)
        results[check[0]] = (ok, text)
        known = check[0] in KNOWN_FINDINGS
        if ok:
            status = "ok     " if not known else "FIXED? "
        else:
            status = "FINDING" if known else "PROBLEM"
        print(f"{status} {check[0]:<4} {check[1]}\n{text}")
        if not ok and known:
            findings += 1
            print(f"        -> {KNOWN_FINDINGS[check[0]]}")
        elif ok and known:
            print("        -> a known finding no longer reproduces: update KNOWN_FINDINGS and the report")
            problems += 1
        elif not ok:
            problems += 1
    if "--plant" in sys.argv:
        caught = 0
        by_id = {c[0]: c for c in CHECKS}
        for label, key, old, new, target in PLANTS:
            # A plant is one edit, or a list of (old, new) edits applied together.
            edits = old if isinstance(old, list) else [(old, new)]
            missing = [o for o, _ in edits if srcs[key].count(o) != 1]
            if missing:
                print(f"plant {label}: anchor not found once in {FILES[key]} -- PROBLEM")
                problems += 1
                continue
            planted = dict(srcs)
            for o, n in edits:
                planted[key] = planted[key].replace(o, n, 1)
            planted[FILES[key]] = planted[key]
            ok, text = run_check(by_id[target], planted, base)
            # Shown: the first line of the check's report that the plant changed.
            _, clean = results[target]
            clean_lines = set(clean.split("\n"))
            first = next((l.strip() for l in text.split("\n") if l.strip() and l not in clean_lines), text.strip().split("\n")[0])
            print(f"plant {label} -> {target}: {'CAUGHT' if not ok else 'NOT CAUGHT'} ({first[:150]})")
            caught += 0 if ok else 1
        print(f"plants: {caught}/{len(PLANTS)} caught")
        problems += len(PLANTS) - caught
    print(f"silly_explosions_bugtest_check: {len(CHECKS)} checks, {problems} problem(s), {findings} known finding(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
