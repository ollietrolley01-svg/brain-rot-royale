"""No game Sound bypasses the volume sliders, without Studio.

The sliders (Settings: MasterVolume and the Weapons/Effects/Interface volumes) drive the SoundGroups
Sfx.lua makes on each client (SoundService.BRR_<category>). A Sound reaches a slider only by being
in one of those groups, and only a client can put it there: a Sound the server makes plays at one
level for everyone. So the invariant is: every Sound the game makes is made on a client and given
a SoundGroup, and a sound the server wants heard is a cue it asks the clients to play.

  S1  source sweep: every `Instance.new("Sound")` in the game's scripts is in a client folder
      (StarterPlayerScripts, StarterGui, StarterCharacterScripts; not a .server.lua) and sets
      `<sound>.SoundGroup` before it is parented or played. None on the server or in shared code.
  S2  the real CompanionFxClient (booted in lupa by companion_fx_check's world): each Cloud Climb
      sound the server fires on PlaygroundFx (LobbyService `climbSound("<kind>", ...)`) is played
      as its own Sfx cue (OBBY_CUE) and nothing else, and each of those cues is in SoundConfig.
  S3  the real Sfx and SoundConfig (sound_acoustics_check's harness, with a Settings stand-in whose
      values change): every Sound an obby cue builds is in its category's group, the group's volume
      is Master x the category slider, and moving a slider re-levels a Sound already built (0 = silent).

    python tools/sound_slider_check.py .            the checks
    python tools/sound_slider_check.py . --plant    the planted faults; every one must be caught
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import companion_fx_check as cfx  # noqa: E402
import sound_acoustics_check as sac  # noqa: E402

LOBBY = "ServerScriptService/Modules/LobbyService.lua"
CLIENT = cfx.CLIENT
SOUNDS = "ReplicatedStorage/Shared/SoundConfig.lua"
SFX = "StarterPlayerScripts/Sfx.lua"
GAME_FOLDERS = ("ServerScriptService", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "Workspace",
                "StarterPlayerScripts", "StarterGui", "StarterCharacterScripts", "StarterPack")
CLIENT_FOLDERS = ("StarterPlayerScripts", "StarterGui", "StarterCharacterScripts")
SLIDER = {"Weapons": "WeaponVolume", "Effects": "EffectsVolume", "Interface": "InterfaceVolume"}

# Each obby sound the server asks for, and the cue the client must play for it. A new kind fails S2
# until it is added here (an unknown kind falls through to the confetti's CrateOpen, a wrong sound).
OBBY_CUE = {"creak": "ObbyCreak", "snap": "ObbySnap", "checkpoint": "ObbyCheckpoint"}

SOUND_NEW = re.compile(r"""Instance\.new\(\s*["']Sound["']""")


def read(root, rel):
    with open(os.path.join(root, rel), encoding="utf-8", newline="") as f:
        return f.read()


def game_files(root):
    out = {}
    for folder in GAME_FOLDERS:
        for base, _, files in os.walk(os.path.join(root, folder)):
            for f in files:
                if f.endswith(".lua"):
                    rel = os.path.relpath(os.path.join(base, f), root).replace(os.sep, "/")
                    out[rel] = read(root, rel)
    return out


# S1. Each site: where it is, and whether it's a client Sound that gets a group before it sounds.
def sweep(files):
    sites, fails = [], []
    for rel, src in sorted(files.items()):
        lines = src.split("\n")
        for i, line in enumerate(lines):
            if not SOUND_NEW.search(line):
                continue
            where = f"{rel}:{i + 1}"
            sites.append(where)
            client = rel.split("/")[0] in CLIENT_FOLDERS and not rel.endswith(".server.lua")
            if not client:
                fails.append(f"{where}: a Sound made outside the client, which no player's slider can reach")
                continue
            m = re.match(r"\s*local (\w+) = Instance\.new", line)
            if not m:
                fails.append(f"{where}: a Sound not held in a local, so its SoundGroup can't be followed")
                continue
            var, grouped = m.group(1), False
            for later in lines[i + 1:]:
                if re.match(rf"\s*{var}\.SoundGroup = ", later):
                    grouped = True
                    break
                if re.match(rf"\s*{var}\.Parent = ", later) or f"{var}:Play(" in later or re.match(r"(end|function)\b", later):
                    break
            if not grouped:
                fails.append(f"{where}: `{var}` is parented or played before it's given a SoundGroup")
    return sites, fails


# S2. The obby's kinds, fired into the real client; returns (kind -> cues played, fails).
CLIENT_RUN = r"""
local world, kinds = ...
local out = {}
for _, kind in ipairs(kinds) do
    world.sounds = {}
    local ok, err = pcall(function()
        world.remotes.PlaygroundFx.OnClientEvent:Fire({ kind = kind, position = Vector3.new(0, 3, -20) })
    end)
    local names = {}
    for _, s in ipairs(world.sounds) do table.insert(names, s.name) end
    out[kind] = { ok = ok, err = tostring(err), cues = table.concat(names, ",") }
end
return out
"""


def obby_kinds(lobby):
    return sorted(set(re.findall(r'climbSound\("(\w+)"', lobby)))


def client_cues(root, raw, kinds):
    lua, world = cfx.new_world(root, cfx.prepare(root, raw))
    kinds_t = lua.table_from({i + 1: k for i, k in enumerate(kinds)})
    result = lua.eval("function(src, ...) return load(src, 'run')(...) end")(CLIENT_RUN, world, kinds_t)
    return {k: dict(result[k].items()) for k in kinds}


# S3. The real Sfx with Settings that move. Returns fails and facts.
SETTINGS_STUB = "local Settings = { Get = function() return 1 end, Changed = { Connect = function() end } }"
SETTINGS_LIVE = (
    "__settingsValues, __settingsListeners = {}, {}\n"
    "local Settings = { Get = function(id) local v = __settingsValues[id]; if v == nil then return 1 end; return v end,"
    " Changed = { Connect = function(_, fn) table.insert(__settingsListeners, fn) end } }"
)
SET = r"""
local id, v = ...
__settingsValues[id] = v
for _, fn in ipairs(__settingsListeners) do fn(id) end
"""


def slider_run(sc, sfx, cues):
    if sac.HARNESS.count(SETTINGS_STUB) != 1:
        return ["S3 harness: sound_acoustics_check's Settings stand-in changed shape"], []
    harness, sac.HARNESS = sac.HARNESS, sac.HARNESS.replace(SETTINGS_STUB, SETTINGS_LIVE)
    try:
        lua, api = sac.build(sc, sfx)
    finally:
        sac.HARNESS = harness
    set_value = lua.eval("function(src, ...) return load(src, 'set')(...) end")
    same = lua.eval("function(a, b) return a ~= nil and rawequal(a, b) end")
    fails, facts = [], []
    for cue in cues:
        config = api.SC.Get(cue)
        if config is None:
            fails.append(f"S3 {cue}: not a cue in SoundConfig")
            continue
        category = config.category if config.category in SLIDER else "Effects"
        slider = SLIDER[category]
        before = api.createdCount()
        api.Sfx.PlayAt(cue, api.v(0, 0, -20))
        api.flush()
        made = [s for s in api.createdSince(before).values() if s.ClassName == "Sound"]
        plays = api.takePlays()
        if not made or not len(plays):
            fails.append(f"S3 {cue}: playing it built {len(made)} Sound(s) and started {len(plays)}")
            continue
        group = api.groups()["BRR_" + category]
        loose = [s for s in made if not same(s.SoundGroup, group)]
        if loose or group is None:
            fails.append(f"S3 {cue}: {len(loose)}/{len(made)} Sound(s) outside SoundService.BRR_{category}")
            continue
        levels = []
        for master, level in ((1, 1), (1, 0.3), (0.5, 0.3), (1, 0)):
            set_value(SET, "MasterVolume", master)
            set_value(SET, slider, level)
            heard = [s.Volume * s.SoundGroup.Volume for s in made]
            levels.append(round(group.Volume, 3))
            if abs(group.Volume - master * level) > 1e-9:
                fails.append(f"S3 {cue}: Master {master} x {slider} {level} left BRR_{category} at {group.Volume}")
            if level == 0 and any(h > 0 for h in heard):
                fails.append(f"S3 {cue}: {slider} at 0 and a built Sound is still heard at {max(heard)}")
        set_value(SET, "MasterVolume", 1)
        set_value(SET, slider, 1)
        played = ", ".join(f"Volume {p.volume:.3f} speed {p.sound.PlaybackSpeed:.3f}" for p in plays.values())
        facts.append(f"{cue}: played at {played} (20 studs off); {len(made)} Sound(s), all in BRR_{category}; group volume at "
                     f"Master x {slider} (1x1, 1x0.3, 0.5x0.3, 1x0) = {levels}")
    return fails, facts


def check(root, raw):
    fails, facts = [], []
    sites, sweep_fails = sweep(raw["files"])
    fails += sweep_fails
    facts.append(f"S1 Sound creation sites in {len(raw['files'])} game scripts: {len(sites)} ({', '.join(sites)})")

    kinds = obby_kinds(raw["files"][LOBBY])
    if not kinds:
        fails.append("S2: LobbyService fires no climbSound kinds (the obby's sounds moved; point this check at them)")
    cues = []
    try:
        played = client_cues(root, raw["cfx"], kinds)
    except Exception as err:  # a client that won't boot is a failure, not a pass
        return fails + [f"S2: CompanionFxClient didn't boot: {str(err).splitlines()[0][:200]}"], facts
    sc_lua = sac.luau_to_lua(raw["cfx"][SOUNDS])
    defined = set(re.findall(r"^\t(\w+) = \{", raw["cfx"][SOUNDS], re.M))
    for kind in kinds:
        r = played[kind]
        names = [n for n in r["cues"].split(",") if n]
        if not r["ok"]:
            fails.append(f"S2 {kind}: the client's PlaygroundFx handler errored: {r['err'][:150]}")
        elif names != [OBBY_CUE.get(kind)]:
            fails.append(f"S2 {kind}: the client played {names} for it, not [{OBBY_CUE.get(kind, 'a cue listed in OBBY_CUE')}]")
        elif names[0] not in defined:
            fails.append(f"S2 {kind}: the client plays {names[0]}, which SoundConfig doesn't have")
        else:
            cues.append(names[0])
    facts.append(f"S2 obby kinds the server fires: {len(kinds)} {kinds} -> cues {cues}")

    s3_fails, s3_facts = slider_run(sc_lua, sac.luau_to_lua(raw["files"][SFX]), cues)
    return fails + s3_fails, facts + ["S3 " + f for f in s3_facts]


def load(root):
    files = game_files(root)
    raw_cfx = {rel: read(root, rel) for rel in (cfx.CLIENT, cfx.ANIM, cfx.DATA, cfx.RARITY, cfx.SOUNDS, cfx.SERVICE)}
    return {"files": files, "cfx": raw_cfx}


# Each plant breaks the invariant (no game Sound skips the sliders), not the bug that was fixed.
PLANTS = [
    ("a server script makes a Sound (an obby sound with no SoundGroup)", LOBBY,
     "local function climbSound(kind, at)\n\tplaygroundFx:FireAllClients({ kind = kind, position = at.Position })\nend",
     "local function climbSound(kind, at)\n\tlocal sound = Instance.new(\"Sound\")\n\tsound.SoundId = \"rbxasset://sounds/snap.mp3\"\n"
     "\tsound.Parent = at\n\tsound:Play()\nend"),
    ("a client Sound given no SoundGroup", SFX, "\t\t\tsound.SoundGroup = groupFor(config)\n", ""),
    ("an obby sound the client doesn't play", CLIENT, "\tif info.kind == \"creak\" then", "\tif info.kind == \"creek\" then"),
    ("an obby cue missing from SoundConfig", SOUNDS, "\tObbySnap = {", "\tObbySnapped = {"),
    ("the Effects group ignores its slider", SFX,
     "group.Volume = master * Settings.Get(CATEGORY_SETTING[category] or \"EffectsVolume\")", "group.Volume = master"),
    ("a slider change doesn't reach Sounds already built", SFX,
     "\tif id == \"*\" or id == \"MasterVolume\" or id == \"WeaponVolume\" or id == \"EffectsVolume\" or id == \"InterfaceVolume\" then\n\t\tapplyVolumes()",
     "\tif false then\n\t\tapplyVolumes()"),
]


def planted(raw, rel, old, new):
    out = {"files": dict(raw["files"]), "cfx": dict(raw["cfx"])}
    for bucket in ("files", "cfx"):
        if rel in out[bucket]:
            out[bucket][rel] = out[bucket][rel].replace(old, new)
    return out


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    raw = load(root)
    if "--plant" not in sys.argv:
        fails, facts = check(root, raw)
        for f in facts:
            print("  " + f)
        for f in fails:
            print("FAIL " + f)
        print(f"sound_slider_check: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures)")
        sys.exit(1 if fails else 0)

    missed = 0
    for label, rel, old, new in PLANTS:
        text = raw["files"].get(rel) or raw["cfx"].get(rel) or ""
        if text.count(old) != 1:
            print(f"  plant [{label}]: STALE -- its text is not in {rel} exactly once")
            missed += 1
            continue
        fails, _ = check(root, planted(raw, rel, old, new))
        print(f"  plant [{label}]: {'CAUGHT' if fails else 'MISSED'}" + (f" -- {fails[0][:160]}" if fails else ""))
        missed += 0 if fails else 1
    print(f"sound_slider_check --plant: {len(PLANTS) - missed}/{len(PLANTS)} caught")
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
