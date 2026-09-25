"""Behaviour check for the acoustics of #120 (sound design closer to real life), without Studio.

Runs the real ReplicatedStorage/Shared/SoundConfig.lua and StarterPlayerScripts/Sfx.lua in a Lua
interpreter (lupa) with Instance, workspace, task.delay and time() mocked, plays cues through
Sfx, and reads back what was built and when each Sound started.

    python tools/sound_acoustics_check.py .            the checks
    python tools/sound_acoustics_check.py . --plant    the planted faults; every one must be caught

What it holds the code to:
  - every cue resolves, and every layer is one of the rbxasset files SoundConfig names (no guessed
    ids); every cue name the rest of the game plays by literal still resolves;
  - rolloff: start < reach <= the class cap; the air equaliser only ever cuts more with distance
    (High at least as much as Mid); foley never carries as far as any gun, suppressed never as
    far as any unsuppressed gun;
  - delay: a sound starts d / (343 m/s at 0.28 m a stud) after it was made, a supersonic crack
    arrives d / (900 m/s) after and ahead of its report, all worked out HERE from the physics,
    not from SoundConfig's own constants; a far blast brings its rumble in, late by the same;
  - enclosure: a roof within reach overhead is indoors, open sky, a high roof or a non-collidable
    canopy is not, and the answer is cached for its TTL; indoors the room reverb is on and the
    outdoor echo layers are silent, outdoors the reverse;
  - no Sound carries more than MAX_EFFECTS_PER_SOUND effects (a fixture cue with a full chain
    proves the cap holds), and no real cue loses its air or room effect to the cap.

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import math
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("sound_acoustics_check: needs lupa (pip install lupa)")

# The physics, independent of SoundConfig: Roblox's documented 0.28 m a stud.
STUD = 0.28
C = 343 / STUD
BULLET = 900 / STUD


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


HARNESS = r"""
local scSrc, sfxSrc = ...
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end

local clock = 0
local pending = {}
local plays = {}
local created = {}

local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    return V[k]
end
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b) return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
function V:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }

local Inst = {}
Inst.__index = function(t, k)
    local d = rawget(t, "_d")
    if d[k] ~= nil then return d[k] end
    return Inst[k]
end
Inst.__newindex = function(t, k, v)
    local d = rawget(t, "_d")
    if k == "Parent" then
        if d.Parent then d.Parent._d.children[t] = nil end
        if v then v._d.children[t] = true end
    end
    d[k] = v
end
function Inst:IsA(c) return self.ClassName == c end
function Inst:Play()
    self._d.IsPlaying = true
    table.insert(plays, { sound = self, t = clock, volume = self.Volume })
end
function Inst:Stop() self._d.IsPlaying = false end
function Inst:Destroy() self.Parent = nil end
function Inst:GetChildren()
    local out = {}
    for c in pairs(self._d.children) do table.insert(out, c) end
    return out
end
function Inst:WaitForChild(n) return self._d.children_by_name and self._d.children_by_name[n] end
local function new(className)
    local t = setmetatable({ _d = { ClassName = className, Name = className, children = {}, Enabled = true } }, Inst)
    table.insert(created, t)
    return t
end
Instance = { new = new }

typeof = function(v)
    if type(v) == "table" and getmetatable(v) == V then return "Vector3" end
    if type(v) == "table" and getmetatable(v) == Inst then return "Instance" end
    return type(v)
end
Enum = setmetatable({}, { __index = function(_, a) return setmetatable({}, { __index = function(_, b) return a .. "." .. b end }) end })
RaycastParams = { new = function() return {} end }
task = { delay = function(d, fn, ...) table.insert(pending, { at = clock + d, fn = fn, args = table.pack(...) }) end }
time = function() return clock end

local ceilings = {}
local beats = {}
workspace = new("Workspace")
workspace.Terrain = new("Terrain")
workspace.CurrentCamera = { CFrame = { Position = Vector3.new(0, 0, 0) } }
workspace.Raycast = function(_, origin, dir, params)
    local best = nil
    for _, c in ipairs(ceilings) do
        local lo, hi = math.min(origin.Y, origin.Y + dir.Y), math.max(origin.Y, origin.Y + dir.Y)
        if c.y >= lo and c.y <= hi and (c.collide or not params.RespectCanCollide) then
            best = { Instance = c, Position = Vector3.new(origin.X, c.y, origin.Z) }
        end
    end
    return best
end

-- Jitter off unless a check asks for it: the timings and levels below are exact.
local randomValue = nil
math.random = function(a, b)
    local r = randomValue and randomValue() or 0.5
    if a and b then return a + math.floor(r * (b - a + 1)) end
    if a then return 1 + math.floor(r * a) end
    return r
end
local SoundConfig = load(scSrc, "SoundConfig")()
local SC_MARK, SETTINGS_MARK = {}, {}
local services = {
    SoundService = new("SoundService"),
    Players = { LocalPlayer = { Character = nil } },
    ReplicatedStorage = { WaitForChild = function() return { WaitForChild = function() return SC_MARK end } end },
    RunService = { Heartbeat = { Connect = function(_, fn)
        local conn = {}
        conn.Disconnect = function() beats[conn] = nil end
        beats[conn] = fn
        return conn
    end } },
}
game = { GetService = function(_, n) return services[n] end }
script = { Parent = { WaitForChild = function() return SETTINGS_MARK end } }
local Settings = { Get = function() return 1 end, Changed = { Connect = function() end } }
local realRequire = require
require = function(m)
    if m == SC_MARK then return SoundConfig end
    if m == SETTINGS_MARK then return Settings end
    return realRequire(m)
end
local Sfx = load(sfxSrc, "Sfx")()

local api = { SC = SoundConfig, Sfx = Sfx }
function api.flush()
    while #pending > 0 do
        table.sort(pending, function(a, b) return a.at < b.at end)
        local job = table.remove(pending, 1)
        clock = math.max(clock, job.at)
        job.fn(table.unpack(job.args, 1, job.args.n))
    end
end
function api.setClock(t) clock = t end
function api.setRandom(fn) randomValue = fn end
-- Step every Heartbeat connection (the duck easing back), then again until none is left.
function api.resetDuck()
    for _ = 1, 400 do
        if next(beats) == nil then break end
        local fns = {}
        for _, fn in pairs(beats) do table.insert(fns, fn) end
        for _, fn in ipairs(fns) do fn(0.05) end
    end
end
function api.groups()
    local out = {}
    for c in pairs(services.SoundService._d.children) do if c.ClassName == "SoundGroup" then out[c.Name] = c end end
    return out
end
function api.clock() return clock end
function api.setCeilings(list)
    ceilings = {}
    for _, c in ipairs(list) do table.insert(ceilings, { y = c[1], collide = c[2] }) end
end
function api.v(x, y, z) return Vector3.new(x, y, z) end
function api.takePlays()
    local out = plays
    plays = {}
    return out
end
function api.createdCount() return #created end
-- Every Sound finishes (the mock never ends one by itself).
function api.silence()
    for _, c in ipairs(created) do if c.ClassName == "Sound" then c._d.IsPlaying = false end end
end
function api.createdSince(n)
    local out = {}
    for i = n + 1, #created do table.insert(out, created[i]) end
    return out
end
function api.effectsOf(sound)
    local out = {}
    for c in pairs(sound._d.children) do
        if string.find(c.ClassName, "SoundEffect") then table.insert(out, c) end
    end
    return out
end
return api
"""

GROUND = [(-3, True)]


def sources(root):
    sc = open(os.path.join(root, "ReplicatedStorage", "Shared", "SoundConfig.lua"), encoding="utf-8").read()
    sfx = open(os.path.join(root, "StarterPlayerScripts", "Sfx.lua"), encoding="utf-8").read()
    return sc, sfx


def called_cues(root):
    names = set()
    # Literal plays, plus the cue tables other scripts pick from (SHOT_CUE, BLAST_CUE, HEAR_CUES...).
    pattern = re.compile(r'Sfx\.(?:Play|PlayAt|PlayDistant|Loop)\(\s*"(\w+)"|ExplosiveFx\.Loop\(\s*"(\w+)"'
                         r'|"((?:Gunshot|Explosion)\w+)"')
    for folder in ("StarterPlayerScripts", "StarterGui", "ReplicatedStorage", "ServerScriptService"):
        for base, _, files in os.walk(os.path.join(root, folder)):
            for f in files:
                if f.endswith(".lua"):
                    for m in pattern.finditer(open(os.path.join(base, f), encoding="utf-8").read()):
                        names.add(m.group(1) or m.group(2) or m.group(3))
    return names


def build(sc, sfx):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua, lua.execute(HARNESS, luau_to_lua(sc), luau_to_lua(sfx))


def checks(sc, sfx, root):
    lua, api = build(sc, sfx)
    SC, Sfx = api.SC, api.Sfx
    A = SC.Acoustics
    results = []
    names = sorted(SC.Sounds.keys())

    # Assets: the constants at the top of SoundConfig, each one a file its header lists as measured.
    header = sc[: sc.index("local SoundConfig = {}")]
    consts = dict(re.findall(r'^local (\w+) = "(rbxasset://sounds/[^"]+)"', sc, flags=re.M))
    measured = set(re.findall(r"([a-z_0-9]+) \d+\.\d\d", header))
    unmeasured = [p for p in consts.values() if os.path.splitext(os.path.basename(p))[0] not in measured]
    known = set(consts.values())
    bad = []
    for n in names:
        cue = SC.Sounds[n]
        layers = SC.LayersOf(cue)
        if not layers:
            bad.append(f"{n}: no layers")
            continue
        for i in range(1, len(layers) + 1):
            if layers[i].id not in known:
                bad.append(f"{n}: {layers[i].id}")
        if cue.distant and not SC.Get(cue.distant.cue):
            bad.append(f"{n}: distant {cue.distant.cue}")
    results.append(("every cue's layers are measured rbxasset files", not bad and not unmeasured and len(known) == 23,
                    f"{len(names)} cues, {len(known)} files; bad {bad[:3]} unmeasured {unmeasured}"))
    missing = sorted(c for c in called_cues(root) if not SC.Get(c))
    results.append(("every cue the game plays by name resolves", not missing,
                    f"{len(called_cues(root))} literal call names, missing {missing}"))

    # Rolloff and air.
    reach, broken = {}, []
    for n in names:
        cue = SC.Sounds[n]
        cls = SC.ClassOf(n, cue)
        near, far = SC.Rolloff(n, cue)
        reach[n] = (cls, far)
        if not (1 <= near < far <= A.CLASSES[cls].maxCap):
            broken.append(f"{n} {near}..{far}")
        last = (0, 0, 0)
        for step in range(0, 41):
            low, mid, high = SC.AirAt(n, cue, far * step / 40)
            if high > last[2] + 1e-9 or mid > last[1] + 1e-9 or high > mid + 1e-9 or mid > 0 or low > 3:
                broken.append(f"{n} air at {far * step / 40:.0f}: {low:.1f}/{mid:.1f}/{high:.1f}")
                break
            last = (low, mid, high)
        if SC.AirAt(n, cue, far)[2] >= 0:
            broken.append(f"{n}: no top-end loss at its reach")
    results.append(("rolloff within caps; air only cuts more with distance, top end first", not broken,
                    f"{len(names)} cues x 41 distances; {broken[:3]}"))
    guns = [f for c, f in reach.values() if c == "gun"]
    foley = [f for c, f in reach.values() if c == "foley"]
    supp = [f for c, f in reach.values() if c == "suppressed"]
    results.append(("hands and feet never carry as far as any gun; suppressed shorter than any gun",
                    max(foley) < min(guns) and max(supp) < min(guns),
                    f"foley <= {max(foley)}, suppressed <= {max(supp)}, guns >= {min(guns)} ({len(guns)} guns)"))

    # Delay: plays timed against the physics.
    errors = []
    for name, d in (("GunshotPistol", 300), ("GunshotRifle", 400), ("GunshotSniper", 700), ("ExplosionFrag", 600)):
        cue = SC.Sounds[name]
        layers = SC.LayersOf(cue)
        api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND]))
        api.setClock(1000)
        api.takePlays()
        Sfx.PlayAt(name, api.v(d, 0, 0), None)
        api.flush()
        played = list(api.takePlays().values())
        got = [(p.sound.SoundId, p.t - 1000) for p in played if p.sound.Parent.ClassName == "Attachment"]
        flat = [(p.sound.SoundId, p.t - 1000, p.volume) for p in played if p.sound.Parent.ClassName != "Attachment"]
        crack = any(layers[i].crack for i in range(1, len(layers) + 1))
        want = []
        # Which layers sound at this range is the near/far cross-fade's business (checked in
        # sound_polish_check); WHEN each one arrives is physics, worked out here. An outdoor echo
        # comes back later in open country, by the OPEN stretch.
        plan = SC.Plan(name, cue, d, False, None, lua.table_from({"own": False, "open": Sfx.Openness()}))
        stretch = 1 + SC.Acoustics.OPEN.stretch * Sfx.Openness()
        for i in range(1, len(layers) + 1):
            L = layers[i]
            if L.where == "indoor" or plan.layers[i].gain <= 0:
                continue
            echo = stretch if L.where == "outdoor" else 1
            want.append((L.id, (d / BULLET if L.crack else d / C) + L.delay * echo))
        for wid, wt in want:
            if not any(g[0] == wid and abs(g[1] - wt) < 1e-6 for g in got):
                errors.append(f"{name}@{d}: {os.path.basename(wid)} want {wt:.3f}s got {[round(g[1], 3) for g in got if g[0] == wid]}")
        if crack:
            first = min(g[1] for g in got)
            if not first < d / C - 0.05:
                errors.append(f"{name}: crack not ahead of report ({first:.3f} vs {d / C:.3f})")
        if len(got) != len(want):
            errors.append(f"{name}@{d}: {len(got)} positional plays, want {len(want)}")
        if name == "ExplosionFrag":
            # The rumble fades in from distant.from to the blast's reach: (600 - 250) / (850 - 250).
            far = SC.LayersOf(SC.Sounds.ExplosionFar)
            ramp = (d - cue.distant["from"]) / (SC.Rolloff(name, cue)[1] - cue.distant["from"])
            ok = len(flat) == len(far) and all(abs(t - d / C) < 1e-6 for _, t, _ in flat)
            ok = ok and all(abs(v - far[i + 1].volume * ramp) < 1e-6 for i, (_, _, v) in enumerate(flat))
            if not ok:
                errors.append(f"ExplosionFrag@600: rumble not layered in at {d / C:.3f}s x{ramp:.2f}: {flat}")
    # Close blast: no rumble. Off-path shot: report only.
    api.setClock(2000); api.takePlays()
    Sfx.PlayAt("ExplosionFrag", api.v(150, 0, 0), None); api.flush()
    near_plays = len(api.takePlays())
    frag = SC.LayersOf(SC.Sounds.ExplosionFrag)
    frag_plan = SC.Plan("ExplosionFrag", SC.Sounds.ExplosionFrag, 150, False, None, lua.table_from({"own": False, "open": 1}))
    if near_plays != sum(1 for i in range(1, len(frag) + 1) if frag_plan.layers[i].gain > 0):
        errors.append(f"ExplosionFrag@150 played {near_plays} sounds (a rumble at close range?)")
    api.setClock(3000); api.takePlays()
    Sfx.PlayAt("GunshotRifle", api.v(400, 0, 0), None, api.v(400, 0, 400)); api.flush()
    off = [p.t - 3000 for p in api.takePlays().values()]
    if min(off) < 400 / C - 1e-6:
        errors.append(f"off-path rifle cracked early at {min(off):.3f}s")
    results.append(("sound arrives at d/343 m/s; a supersonic crack at d/900 m/s, ahead; a far blast brings its rumble",
                     not errors, f"4 cues timed layer by layer + 2 edge cases; {errors[:2]}"))

    # Enclosure.
    enc = []
    for label, ceil, want in (("open sky", [], False), ("roof 12 up", [(12, True)], True),
                              ("roof 60 up", [(60, True)], False), ("leafy canopy", [(10, False)], False)):
        api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND + ceil]))
        api.setClock(api.clock() + 10)
        got = Sfx.IsEnclosed()
        if got != want:
            enc.append(f"{label}: {got}")
    api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND]))
    if Sfx.IsEnclosed() is not False:
        enc.append("cache: re-cast inside its TTL")
    api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND + [(12, True)]]))
    cached = Sfx.IsEnclosed()
    api.setClock(api.clock() + 1)
    if cached is not False or Sfx.IsEnclosed() is not True:
        enc.append("cache: TTL not honoured")
    # Room vs outdoor echo on your own sniper shot.
    for indoors in (True, False):
        api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND + ([(12, True)] if indoors else [])]))
        api.setClock(api.clock() + 1)
        Sfx.Play("GunshotSniper", None, None)
        api.flush()
        ps = list(api.takePlays().values())
        reverbs = [e for p in ps for e in api.effectsOf(p.sound).values() if e.ClassName == "ReverbSoundEffect"]
        sl = SC.LayersOf(SC.Sounds.GunshotSniper)
        # Your own shot: every layer but the far thump, and only the room or the echo layers.
        want_plays = sum(1 for i in range(1, len(sl) + 1) if sl[i].range != "far"
                         and sl[i].where != ("outdoor" if indoors else "indoor"))
        if len(ps) != want_plays or not reverbs or any(r.Enabled != indoors for r in reverbs):
            enc.append(f"sniper {'in' if indoors else 'out'}doors: {len(ps)} plays, reverb {[r.Enabled for r in reverbs][:2]}")
    results.append(("a roof overhead is indoors; room reverb only indoors, echo layers only outdoors", not enc,
                    f"4 skies, TTL, 2 sniper shots; {enc[:2]}"))

    # Effect counts, with a fixture cue whose own chain already fills the cap.
    SC.Sounds.GunshotZZFixture = lua.eval(
        '{ category = "Weapons", layers = { { id = "rbxasset://sounds/snap.mp3" } }, effects = {'
        ' { "DistortionSoundEffect", {} }, { "CompressorSoundEffect", {} }, { "ChorusSoundEffect", {} },'
        ' { "FlangeSoundEffect", {} }, { "TremoloSoundEffect", {} } } }')
    cap = A.MAX_EFFECTS_PER_SOUND
    worst, total, starved, sounds = 0, 0, [], 0
    for n in names + ["GunshotZZFixture"]:
        cue = SC.Sounds[n]
        before = api.createdCount()
        api.setCeilings(lua.table_from([lua.table_from(list(c)) for c in GROUND]))
        Sfx.Play(n, None, None)
        Sfx.PlayAt(n, api.v(5, 0, 0), None)
        api.flush()
        api.takePlays()
        for s in api.createdSince(before).values():
            if s.ClassName != "Sound":
                continue
            sounds += 1
            effs = list(api.effectsOf(s).values())
            worst = max(worst, len(effs))
            total += len(effs)
            if n == "GunshotZZFixture":
                continue
            kinds = [e.ClassName for e in effs]
            positional = s.Parent is not None and s.Parent.ClassName == "Attachment"
            ls = SC.LayersOf(cue)
            outdoor = any(ls[i].where == "outdoor" and ls[i].id == s.SoundId and abs(ls[i].pitch - s.PlaybackSpeed) < 1e-9
                          for i in range(1, len(ls) + 1))
            # An outdoor-only echo is silent whenever the room would be on, so it carries none.
            if SC.RoomGated(n, cue) and "ReverbSoundEffect" not in kinds and not outdoor:
                starved.append(f"{n} room")
            if positional and "EqualizerSoundEffect" not in kinds:
                starved.append(f"{n} air")
    results.append((f"no Sound carries more than {cap} effects (fixture cue included)", worst <= cap,
                    f"{sounds} Sounds, {total} effects, worst {worst}"))
    results.append(("no real cue loses its air or room effect to the cap", not starved, f"{sorted(set(starved))[:4]}"))
    return results


def plants(sc, sfx):
    yield "speed of sound in the wrong units", sc.replace("343 / METRES_PER_STUD", "343 * METRES_PER_STUD"), sfx
    yield "a layer on an unmeasured asset", sc.replace("{ id = SNAP, volume = 1, pitch = 1.75 }",
                                                       '{ id = "rbxasset://sounds/boing.mp3", volume = 1, pitch = 1.75 }'), sfx
    yield "air cut shrinks with distance", sc.replace(
        "local t = math.clamp((distance - near) / (far - near), 0, 1)",
        "local t = 1 - math.clamp((distance - near) / (far - near), 0, 1)"), sfx
    yield "the crack no longer leads the report", sc.replace(
        "first = distance / Acoustics.BULLET_SPEED", "first = report"), sfx
    yield "foley allowed gun range", sc.replace("foley = { rollMin = 6, maxCap = 160", "foley = { rollMin = 6, maxCap = 900"), sfx
    yield "the air equaliser ignores the cap", sc, sfx.replace(
        "if not entry.air and #made < Acoustics.MAX_EFFECTS_PER_SOUND then", "if not entry.air then")
    yield "leaves count as a roof", sc, sfx.replace("params.RespectCanCollide = true", "params.RespectCanCollide = false")
    yield "the ceiling ray points down", sc, sfx.replace(
        "Vector3.new(0, Acoustics.CEILING_REACH, 0)", "Vector3.new(0, -Acoustics.CEILING_REACH, 0)")
    yield "room reverb always on", sc, sfx.replace("local on = not plan or plan.room ~= false", "local on = true")
    yield "positional plays ignore travel time", sc, sfx.replace("if plan.start > 0.005 then", "if false then")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sc, sfx = sources(root)
    if "--plant" in sys.argv:
        caught = total = 0
        for label, psc, psfx in plants(sc, sfx):
            total += 1
            if psc == sc and psfx == sfx:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            try:
                failed = [name for name, ok, _ in checks(psc, psfx, root) if not ok]
            except Exception as err:  # a plant that crashes the module is caught too, but say so
                failed = [f"crashed: {str(err).splitlines()[0][:80]}"]
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"sound acoustics planted faults: {caught}/{total} caught")
        sys.exit(0 if caught == total else 1)
    results = checks(sc, sfx, root)
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    failed = sum(1 for _, ok, _ in results if not ok)
    print(f"sound acoustics: {len(results) - failed}/{len(results)} checks pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
