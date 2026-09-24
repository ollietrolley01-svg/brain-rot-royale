"""Player health regen (findings C1): Roblox's default 1%/s is off, and players heal by the bots' rule.

    python3 tools/regen_check.py .            the checks
    python3 tools/regen_check.py . --plant    the planted faults; every one must be caught

  override  StarterCharacterScripts holds a Script named "Health" with no code in it, in BOTH builds:
            build_place.py is run on a private copy of the tree and the .rbxlx it writes is read back,
            and default.project.json (Rojo) maps the folder that holds it. Without that Script Roblox
            copies its own regenerating one into every character.
  rule      MatchService's `regen` table, cut out of the source and run in lupa against mock humanoids:
            nothing for BotRegenDelay seconds after damage taken (a health loss of any kind), damage
            dealt, or a hit a shield soaked; then BotRegenPerSecond, scaled by the seconds that passed;
            never above MaxHealth and never pulling a boosted health down to it; nothing for the dead.
  gate      the 1 s loop steps regen only while the match is InProgress and only for players
            MatchService.IsPlaying (not the lobby, not Loading, not downed); startMatch and the leave
            path let go of the tables.

Needs `pip install lupa`.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("regen_check: needs lupa (pip install lupa)")

MATCH = "ServerScriptService/Modules/MatchService.lua"
CONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"
HEALTH = "StarterCharacterScripts/Health.server.lua"
PROJECT = "default.project.json"
BUILD = "build_place.py"
FILES = (MATCH, CONFIG, HEALTH, PROJECT, BUILD)


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def between(src, start, stop):
    a = src.index(start)
    return src[a:src.index(stop, a)]


def no_code(source):
    """True when a Lua source is only comments and whitespace."""
    stripped = re.sub(r"--\[(=*)\[.*?\]\1\]", "", source, flags=re.S)
    stripped = re.sub(r"--[^\n]*", "", stripped)
    return stripped.strip() == ""


# ------------------------------------------------------------------------------------------ override

def override_rows(sources):
    rows = []
    health = sources.get(HEALTH)
    rows.append((health is not None, "%s exists" % HEALTH))
    rows.append((health is not None and no_code(health), "...and has no code in it (an empty Script replaces the default regen)"))

    # Rojo: StarterPlayer.StarterCharacterScripts maps the folder the Health script lives in.
    import json
    try:
        tree = json.loads(sources[PROJECT])["tree"]
        node = tree.get("StarterPlayer", {}).get("StarterCharacterScripts", {})
        mapped = node.get("$className") == "StarterCharacterScripts" and node.get("$path") == os.path.dirname(HEALTH)
    except (ValueError, KeyError, AttributeError):
        mapped = False
    rows.append((mapped, "default.project.json maps StarterPlayer.StarterCharacterScripts to %s/" % os.path.dirname(HEALTH)))

    # build_place.py, run for real on a private copy, and its place file read back.
    work = tempfile.mkdtemp(prefix="brr_regen_")
    try:
        for rel in ("ReplicatedStorage/Shared", "ServerScriptService", "StarterPlayerScripts"):
            shutil.copytree(os.path.join(ROOT, rel), os.path.join(work, rel))
        os.makedirs(os.path.join(work, "StarterCharacterScripts"), exist_ok=True)
        if health is not None:
            with open(os.path.join(work, HEALTH), "w", encoding="utf-8") as f:
                f.write(health)
        with open(os.path.join(work, BUILD), "w", encoding="utf-8") as f:
            f.write(sources[BUILD])
        run = subprocess.run([sys.executable, BUILD, "."], cwd=work, capture_output=True, text=True)
        found = None
        if run.returncode == 0:
            root = ET.parse(os.path.join(work, "BrainRotRoyale.rbxlx")).getroot()
            for sp in root.iter("Item"):
                if sp.get("class") != "StarterPlayer":
                    continue
                for scs in sp.findall("Item"):
                    if scs.get("class") != "StarterCharacterScripts":
                        continue
                    for script in scs.findall("Item"):
                        props = script.find("Properties")
                        if script.get("class") == "Script" and props.find("string[@name='Name']").text == "Health":
                            source = props.find("ProtectedString[@name='Source']")
                            found = source.text if source is not None and source.text else ""
        rows.append((found is not None, "build_place.py puts a Script named Health in StarterPlayer.StarterCharacterScripts"
                     + ("" if run.returncode == 0 else " (build failed: %s)" % run.stderr.strip()[-160:])))
        rows.append((found is not None and no_code(found), "...with no code in it"))
    finally:
        shutil.rmtree(work, ignore_errors=True)
    return rows


# ------------------------------------------------------------------------------------------ rule

RULE = r"""
local src, delay, rate = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local listeners = {}
local function humanoid(health, max) return { Health = health, MaxHealth = max or 100 } end
local env = setmetatable({
    MatchConfig = { BotRegenDelay = delay, BotRegenPerSecond = rate },
    Combatants = {
        GetHumanoid = function(p) return p.humanoid end,
        IsPlayer = function(p) return type(p) == "table" and p.isPlayer == true end,
    },
    CombatService = { OnDamage = function(fn) table.insert(listeners, fn) end },
    tick = function() return 0 end,
}, { __index = _G })
local regen = assert(load(src .. "\nreturn regen", "MatchService.regen", "t", env))()
local function player(health, max) return { isPlayer = true, humanoid = humanoid(health, max) } end
local function hit(attacker, victim, dealt) for _, fn in ipairs(listeners) do fn(attacker, victim, dealt) end end

-- Hurt at t=1000 (health 100 -> 40: a storm tick or a fall, nothing through the damage listener), then
-- one step a second.
local hurt = player(100)
regen.step(hurt, 999, 1)
hurt.humanoid.Health = 40
local healedAt
for t = 1000, 1030 do
    local before = hurt.humanoid.Health
    regen.step(hurt, t, 1)
    if not healedAt and hurt.humanoid.Health > before then healedAt = t end
end
check(healedAt ~= nil and healedAt - 1000 > delay and healedAt - 1000 <= delay + 1,
    string.format("a health loss holds regen for %s s (first heal at t=%s, hurt at 1000)", delay, tostring(healedAt)))
check(math.abs(hurt.humanoid.Health - math.min(100, 40 + rate * (1030 - healedAt + 1))) < 1e-6,
    string.format("...then %s HP a second (%.1f at t=1030)", rate, hurt.humanoid.Health))

-- Topped out: never above MaxHealth.
local near = player(99, 100)
regen.step(near, 50, 1)
check(near.humanoid.Health == 100, "never above MaxHealth (99 -> " .. near.humanoid.Health .. ")")
-- A boosted MaxHealth is healed to, and health above MaxHealth is never pulled down.
local boosted = player(120, 150)
regen.step(boosted, 50, 1)
check(boosted.humanoid.Health == 120 + rate, "a Health Boost's max (150) is healed toward like any other")
local over = player(130, 100)
regen.step(over, 50, 1)
check(over.humanoid.Health == 130, "health above MaxHealth is left alone, not capped down")

-- Dealing damage is combat.
local shooter = player(50)
regen.step(shooter, 100, 1)
local base = shooter.humanoid.Health
env.tick = function() return 100 end
hit(shooter, player(100), 20)
for t = 101, 100 + delay do regen.step(shooter, t, 1) end
check(shooter.humanoid.Health == base, "dealing damage holds regen too (" .. base .. " -> " .. shooter.humanoid.Health .. ")")
regen.step(shooter, 100 + delay + 1, 1)
check(shooter.humanoid.Health > base, "...and regen resumes after the lull")

-- A hit a shield soaked (health never moved) is combat.
local shielded = player(60)
regen.step(shielded, 200, 1)
local held = shielded.humanoid.Health
env.tick = function() return 200 end
hit({ isPlayer = false }, shielded, 30)
for t = 201, 200 + delay do regen.step(shielded, t, 1) end
check(shielded.humanoid.Health == held, "a hit the shield soaked holds regen")

-- A late loop heals for the time that passed.
local late = player(10)
regen.step(late, 300, 2)
check(late.humanoid.Health == 10 + rate * 2, "the step scales with the seconds that passed")

-- The dead are left alone.
local dead = player(0)
regen.step(dead, 400, 1)
check(dead.humanoid.Health == 0, "a dead body does not regenerate")
return out
"""


def number(src, key):
    return float(re.search(r"^MatchConfig\.%s = ([\d.]+)" % key, src, re.M).group(1))


def rule_rows(sources):
    src = sources[MATCH]
    block = between(src, "local regen = {", "\nlocal aliveCount")
    delay, rate = number(sources[CONFIG], "BotRegenDelay"), number(sources[CONFIG], "BotRegenPerSecond")
    return run_lua(RULE, luau_to_lua(block), delay, rate)


# ------------------------------------------------------------------------------------------ gate

def gate_rows(sources):
    src = sources[MATCH]
    rows = []
    start = between(src, "function MatchService.Start()", "\nreturn MatchService")
    m = re.search(r"\n\t\t\tif state == \"InProgress\" then\n(.*?)\n\t\t\telse\n\t\t\t\tregen\.at = nil", start, re.S)
    body = m.group(1) if m else ""
    rows.append((m is not None and "regen.step" in body, "the 1 s loop steps regen only inside `if state == \"InProgress\"`"))
    rows.append(("Combatants.IsPlayer(token) and MatchService.IsPlaying(token)" in body,
                 "...and only for a player who IsPlaying (not downed, not the lobby)"))
    rows.append(("for token in pairs(participants)" in body, "...among this match's participants"))
    rows.append(("regen.step" not in start.replace(body, ""), "regen is stepped nowhere else in the loop"))
    begin = between(src, "local function startMatch()", "\nend\n")
    rows.append(("table.clear(regen.lastCombat)" in begin and "table.clear(regen.lastHealth)" in begin,
                 "startMatch clears the regen tables"))
    leave = between(src, "function MatchService.OnPlayerRemoving(", "\nend\n")
    rows.append(("regen.forget(player)" in leave, "a leaver's regen entries are let go"))
    return rows


# ------------------------------------------------------------------------------------------ runner

ROOT = "."


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    try:
        result = lua.execute(code, *args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def all_rows(sources):
    rows = []
    for name, fn in (("override", override_rows), ("rule", rule_rows), ("gate", gate_rows)):
        try:
            rows += fn(sources)
        except (ValueError, AttributeError, KeyError) as exc:
            rows.append((False, "%s: source shape changed: %s" % (name, exc)))
    return rows


PLANTS = [
    ("no Health override in the Rojo project", PROJECT, '"$path": "StarterCharacterScripts"', '"$path": "StarterCharacterScriptz"'),
    ("build_place.py leaves StarterCharacterScripts out", BUILD,
     'total += add_scripts(character_scripts, ROOT / "StarterCharacterScripts")\n', ""),
    ("the Health override grows code", HEALTH, "-- Deliberately empty.", "while task.wait(1) do end\n-- Deliberately empty."),
    ("regen ignores the lull", MATCH, "now - (regen.lastCombat[player] or 0) > MatchConfig.BotRegenDelay", "true"),
    ("regen past MaxHealth", MATCH, "health = math.min(humanoid.MaxHealth, health + MatchConfig.BotRegenPerSecond * seconds)",
     "health = health + MatchConfig.BotRegenPerSecond * seconds"),
    ("a health loss is not combat", MATCH, "\tif before and health < before then\n\t\tregen.lastCombat[player] = now\n",
     "\tif false then\n\t\tregen.lastCombat[player] = now\n"),
    ("dealing damage is not combat", MATCH, "\t\t\tregen.lastCombat[token] = now\n", ""),
    ("regen in every state (the lobby)", MATCH, '\t\t\tif state == "InProgress" then\n\t\t\t\tlocal now = tick()',
     '\t\t\tif true then\n\t\t\t\tlocal now = tick()'),
    ("regen for the downed", MATCH, "Combatants.IsPlayer(token) and MatchService.IsPlaying(token)", "Combatants.IsPlayer(token)"),
]


def main():
    global ROOT
    ROOT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {}
    for rel in FILES:
        path = os.path.join(ROOT, rel)
        sources[rel] = open(path, encoding="utf-8").read() if os.path.isfile(path) else None
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if not sources[rel] or sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in all_rows(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"regen_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"regen_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
