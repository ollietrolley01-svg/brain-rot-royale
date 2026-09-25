"""What the sound polish (pc/sound-polish, 2026-09-25) set, held in place, without Studio.

Runs the real SoundConfig.lua and Sfx.lua under lupa through sound_acoustics_check's mocks and holds
them to:
  1. firearms: every weapon in the four arsenals is classified firearm or novelty here, and plays the
     cue its model/CombatClient says; a firearm's cue names a calibre, a novelty's says novelty;
  2. loudness by calibre: each firearm cue's direct level (volume x the RMS of its direct layers)
     sits in its calibre's band, and the tiers climb (suppressed < smg < pistol < revolver <
     rifle/rotary < lmg < shotgun/dmr < sniper < cannon) -- a pistol can't out-shout a rifle;
  3. distance by calibre: each firearm's reach is its tier's, the reaches climb, only rifle-and-up
     carry a DistantGunfire thump past their reach, and the sniper and cannon carry map-wide;
  4. every firearm has a transient, a body, an indoor room layer and an outdoor tail, and a far
     layer; the calibres with an action have a shooter-only action layer; every blast has a crack
     that fades with range, a boom, a sub thump, debris, both tails and a far layer, with level and
     reach climbing by size;
  5. novelty weapons and silly blasts carry no gunpowder: no explosion-file layers, no `snap` in the
     gun-crack band, no crack/echo/far/self layers, no calibre, no distant boom, no duck;
  6. jitter: every cue varies +-3..6% in pitch and level (a class default or its own), and 20
     plays of one SMG shot really do come out at 20 different pitches and levels within that;
  7. caps: 40 full-auto shots never build more voices than the pool, a chain of 10 blasts in one
     frame starts at most BURST.blast of them, and the Weapons group has its bus compressor; pools
     start at one voice and grow only while every voice is busy; your own shot is never dropped by
     the burst cap; ten far rifles start at most BURST.distant far thumps; a voice taken for a new
     shot drops the old shot's still-pending echo;
  8. range: close up the near layers sound and the far thump doesn't; far off the reverse; your
     own shot's action and chest play flat and never positionally; a sniper past its reach is
     heard as DistantGunfire, a pistol past its reach as nothing; a firearm round just missing you
     whizzes as it arrives, a far miss or a bubble does not;
  9. a big blast beside you ducks the world and rings; a small or silly one, or one far off, doesn't;
 10. categories are the three sliders' and the right one for each family; hit feedback sits under a
     rifle's report and no interface cue is louder than gunfire;
 11. every cue the code names (SHOT_CUE maps, BLAST_CUE, server BlastCue tags, debris, novelty
     foley, the Explosion<Theme> keys the silly-explosions visuals call) is defined.

    python tools/sound_polish_check.py .            the checks
    python tools/sound_polish_check.py . --plant    the planted faults; every one must be caught
"""
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from sound_acoustics_check import build, sources  # noqa: E402

# The design classification (from each weapon's name, look and description): what it is, and the
# report it fires. A new gun fails check 1 until it is added here.
FIREARM = {
    "SahurPistol": "GunshotTung", "RotSMG": "GunshotRot", "CrumblyCarbine": "GunshotCrumb",
    "PocketPopper": "GunshotPopcorn", "CrocodiloRifle": "GunshotCroc", "TralalaShotgun": "GunshotShark",
    "SigmaRevolver": "GunshotRevolver", "LagSwitchSMG": "GunshotLag", "BonkerDoubleBarrel": "GunshotShotgun",
    "BananiniBurst": "GunshotBanana", "LarilaSniper": "GunshotSniper", "GrassToucherDMR": "GunshotLawn",
    "AuraScattergun": "GunshotAura", "SigmaScout": "GunshotSigma", "CappuccinaLauncher": "GunshotRocket",
    "CameloLMG": "GunshotVampire", "SixSevenMarksman": "GunshotBank", "TralalaThumper": "GunshotRocket",
    "GlitchSMG": "GunshotGlitch", "NonnaDoubleBarrel": "GunshotNonna", "PatapimChaingun": "GunshotForest",
    "GoldenSahurCannon": "GunshotCannon", "RizzRotary": "GunshotRizz", "PawnshopNine": "GunshotPistachio",
    "RustbeltMarshal": "GunshotRevolver", "NightShiftPump": "GunshotClonk", "DoomscrollSMG": "GunshotScroll",
    "TrailheadCarbine": "GunshotTrail", "TouchGrassScout": "GunshotMeadow", "DeadAirPrecision": "GunshotSniper",
    "RatioPDW": "GunshotRatio", "BackroomsBreacher": "GunshotBreach", "ReceiptPrinterLMG": "GunshotReceipt",
    "SundaySpecial": "GunshotCannon", "AuraAuditRifle": "GunshotAudit", "QuietHours": "GunshotSniper",
    "AdminOverride": "GunshotAdmin", "FinalNotice": "GunshotCollect",
}
NOVELTY = {
    "BubbleBlaster": "GunshotBubble", "BubbleBurster": "GunshotBubble", "ZanzarinoPikpik": "GunshotPikpik",
    "AuraCrossbow": "GunshotCrossbow", "TamburoTungTung": "GunshotTamburo", "Bananerang": "GunshotBoomerang",
    "DeluluRailgun": "GunshotRail", "SqueakyDuckPopper": "GunshotSqueak", "JuiceBoxSquirter": "GunshotSquirt",
    "SpaghettiSlinger": "GunshotNoodle", "BoomboxBassline": "GunshotBassDrop", "GumballGatling": "GunshotGumball",
    "FidgetDiscLauncher": "GunshotFidget", "MicrowaveZapper": "GunshotZap", "PizzaCutterCrossbow": "GunshotPizza",
    "DiscoBallDeleter": "GunshotDisco", "ToasterMortar": "GunshotToaster", "RubberChickenRailgun": "GunshotChicken",
    "LavaLampLancer": "GunshotLavaLamp", "SnowGlobeSingularity": "GunshotSnow",
    "GrandmasSlipperLauncher": "GunshotSlipper", "RageQuitCarbine": "GunshotKeycap",
    "CleanSweepDouble": "GunshotBroom", "HoseDownSniper": "GunshotHose", "DustDevilRotary": "GunshotVacuum",
    "YardWorkBlower": "GunshotBlower", "PartyFoulCannon": "GunshotPopper",
}
TIER_ORDER = ["suppressed", "smg", "pistol", "revolver", "rifle", "rotary", "lmg", "shotgun", "dmr", "sniper", "cannon"]
CARRY = {"rifle", "rotary", "lmg", "shotgun", "dmr", "sniper", "cannon", "launcher"}
BLAST_ORDER = ["grenade", "frag", "rocket", "vehicle"]
SILLY_BLASTS = ["ExplosionParty", "ExplosionSlipper", "ExplosionFidget", "ExplosionGold", "ExplosionCoffee",
                "ExplosionDrum", "ExplosionToast"]
GUNPOWDER_IDS = {"rbxasset://sounds/impact_explosion_02.mp3", "rbxasset://sounds/impact_explosion_03.mp3"}
SNAP_ID = "rbxasset://sounds/snap.mp3"
CRACK_BAND = (0.8, 2.3)  # every firearm's snap sits in here; a novelty snap must not
TRANSIENT_IDS = {SNAP_ID, "rbxasset://sounds/hit.wav", "rbxasset://sounds/clickfast.wav", "rbxasset://sounds/button.wav",
                 "rbxasset://sounds/electronicpingshort.wav"}
BODY_IDS = GUNPOWDER_IDS | {"rbxasset://sounds/bass.wav"}
POOL = {"flat": 4, "positional": 8}
BLAST_BURST = 3


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


def direct_level(cue, layers):
    total = sum(L.volume ** 2 for L in layers if not (L.where or L.who or L.range))
    return math.sqrt(total)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def weapon_ids(root):
    ids = []
    for f in ("WeaponData.lua", "ArsenalExpansion.lua", "CreativeArsenal.lua", "WorkshopArsenal.lua"):
        src = read(root, "ReplicatedStorage", "Shared", f)
        body = src[src.index("Weapons = {"):]
        ids += re.findall(r"^\t(\w+) = \{\n", body, flags=re.M)
    return ids


def declared_cues(root):
    """Weapon id -> cue where the code says it outright: a model's ShotCue, CombatClient's by-id map,
    and the creative/workshop models' flash kinds through SHOT_CUE."""
    combat = read(root, "StarterPlayerScripts", "CombatClient.client.lua")
    by_flash = dict(re.findall(r"(\w+) = \"(Gunshot\w+)\"", combat[combat.index("local SHOT_CUE = {"):combat.index("local SHOT_CUE_BY_ID")]))
    by_id = dict(re.findall(r"(\w+) = \"(Gunshot\w+)\"", combat[combat.index("local SHOT_CUE_BY_ID"):combat.index("local TRACER_KIND")]))
    out = {}
    for f in ("GunModelsSignature.lua", "GunModelsCreative.lua", "GunModelsWorkshop.lua"):
        src = read(root, "ReplicatedStorage", "Shared", f)
        for m in re.finditer(r"^Builders\.(\w+) = function(.*?)^end", src, flags=re.M | re.S):
            cue = re.search(r'SetAttribute\("ShotCue", "(\w+)"\)', m.group(2))
            flash = re.search(r'SetAttribute\("Flash", "(\w+)"\)', m.group(2))
            if cue:
                out[m.group(1)] = cue.group(1)
            elif m.group(1) in by_id:
                out[m.group(1)] = by_id[m.group(1)]
            elif flash and flash.group(1) in by_flash:
                out[m.group(1)] = by_flash[flash.group(1)]
    for wid, cue in by_id.items():
        out.setdefault(wid, cue)
    return out, by_flash, by_id


def named_keys(root):
    """Every cue name the code hands to Sfx by table or tag, beyond the literal Sfx.Play calls."""
    names = set()
    combat = read(root, "StarterPlayerScripts", "CombatClient.client.lua")
    names |= set(re.findall(r"\"(Gunshot\w+)\"", combat))
    proj = read(root, "StarterPlayerScripts", "ProjectileClient.client.lua")
    blast = proj[proj.index("local BLAST_CUE = {"):]
    names |= set(re.findall(r"\"(Explosion\w+)\"", blast[:blast.index("}") + 1]))
    names |= set(re.findall(r"Sfx\.Blast\(\"(\w+)\"", proj))
    for base, _, files in os.walk(os.path.join(root, "ServerScriptService")):
        for f in files:
            if f.endswith(".lua"):
                src = open(os.path.join(base, f), encoding="utf-8").read()
                for args in re.findall(r"SetAttribute\(\"BlastCue\", ([^)]*)\)", src):
                    names |= set(re.findall(r"\"(\w+)\"", args))
    names |= set(SILLY_BLASTS) | {"BlastRing", "DistantGunfire", "BulletWhiz"}
    names.discard("")
    return names


def checks(sc, sfx, root):
    lua, api = build(sc, sfx)
    SC, Sfx = api.SC, api.Sfx
    A = SC.Acoustics
    names = sorted(SC.Sounds.keys())
    results = []
    layers_of = {n: lua_list(SC.LayersOf(SC.Sounds[n])) for n in names}

    # 1. Classification.
    ids = weapon_ids(root)
    declared, by_flash, by_id = declared_cues(root)
    bad = [w for w in ids if w not in FIREARM and w not in NOVELTY]
    bad += [f"{w}: declared {declared[w]} vs table {(FIREARM.get(w) or NOVELTY.get(w))}" for w in ids
            if w in declared and declared[w] != (FIREARM.get(w) or NOVELTY.get(w))]
    for w, cue in FIREARM.items():
        c = SC.Sounds[cue]
        if c is None or not c.calibre or c.novelty:
            bad.append(f"{w}: {cue} is not a calibre cue")
    for w, cue in NOVELTY.items():
        c = SC.Sounds[cue]
        if c is None or not c.novelty or c.calibre:
            bad.append(f"{w}: {cue} is not a novelty cue")
    results.append(("every weapon classified; firearms fire calibre cues, novelty guns novelty cues", not bad,
                    f"{len(ids)} weapons ({len([w for w in ids if w in FIREARM])} firearm, "
                    f"{len([w for w in ids if w in NOVELTY])} novelty), {len(declared)} cross-checked; {bad[:3]}"))

    firearms = [n for n in names if SC.Sounds[n].calibre]
    F = SC.Firearms

    # 2. Loudness by calibre.
    bad, by_tier = [], {}
    for n in firearms:
        cal = SC.Sounds[n].calibre
        fam = F[cal]
        if not fam.level:
            continue
        level = direct_level(SC.Sounds[n], layers_of[n])
        by_tier.setdefault(fam.tier, []).append((level, n))
        if not (fam.level[1] - 1e-9 <= level <= fam.level[2] + 1e-9):
            bad.append(f"{n} ({cal}) {level:.3f} outside {fam.level[1]}..{fam.level[2]}")
    tiers = sorted(by_tier)
    for lo, hi in zip(tiers, tiers[1:]):
        if max(by_tier[lo])[0] > min(by_tier[hi])[0] + 1e-9:
            bad.append(f"tier {lo} {max(by_tier[lo])[1]} louder than tier {hi} {min(by_tier[hi])[1]}")
    order = [F[c].tier for c in TIER_ORDER]
    if order != sorted(order):
        bad.append(f"calibre tiers out of order {order}")
    results.append(("firearm loudness sits in its calibre band and climbs with calibre", not bad,
                    f"{len(firearms)} firearm cues over {len(tiers)} tiers; {bad[:3]}"))

    # 3. Distance by calibre.
    bad = []
    reaches = [F[c].reach for c in TIER_ORDER]
    if reaches != sorted(reaches):
        bad.append(f"reach out of calibre order {reaches}")
    for n in firearms:
        cue = SC.Sounds[n]
        fam = F[cue.calibre]
        far = SC.Rolloff(n, cue)[1]
        if far != min(fam.reach, A.CLASSES[SC.ClassOf(n, cue)].maxCap):
            bad.append(f"{n} reach {far} != {fam.reach}")
        carries = cue.distant is not None and cue.distant.cue == "DistantGunfire"
        if carries != (cue.calibre in CARRY):
            bad.append(f"{n} ({cue.calibre}) distant={carries}")
    for cal in ("sniper", "cannon"):
        if F[cal].distant != 1:
            bad.append(f"{cal} distant gain {F[cal].distant}")
    if SC.Sounds.DistantGunfire.maxDistance < 1500:
        bad.append("DistantGunfire short of map-wide")
    results.append(("firearm reach is its calibre tier's; only rifle-and-up carry past it, sniper/cannon map-wide",
                    not bad, f"reaches {reaches}; {bad[:3]}"))

    # 4. Layers present.
    bad = []
    for n in firearms:
        cue, L = SC.Sounds[n], layers_of[n]
        fam = F[cue.calibre]
        direct = [x for x in L if not (x.where or x.who or x.range)]
        need = {
            "transient": any(x.id in TRANSIENT_IDS for x in direct),
            "body": any(x.id in BODY_IDS for x in direct),
            "room": any(x.where == "indoor" for x in L),
            "tail": any(x.where == "outdoor" for x in L) or cue.calibre == "suppressed",
            "far": any(x.range == "far" for x in L),
            "chest": any(x.who == "self" and x.role == "chest" for x in L),
            "action": (fam.action is None) or any(x.who == "self" and x.role == "action" for x in L),
        }
        missing = [k for k, ok in need.items() if not ok]
        if missing:
            bad.append(f"{n}: no {missing}")
    B = SC.Blasts
    blasts = [n for n in names if SC.Sounds[n].blast]
    blast_levels = {}
    for n in blasts:
        cue, L = SC.Sounds[n], layers_of[n]
        need = {
            "crack": any(x.id == SNAP_ID and x.range == "near" for x in L),
            "boom": any(x.id in GUNPOWDER_IDS and not (x.where or x.range) for x in L),
            "sub": any(x.role == "sub" and x.range == "near" for x in L),
            "debris": any(x.role == "debris" and x.delay >= 0.1 for x in L),
            "room": any(x.where == "indoor" for x in L),
            "tail": any(x.where == "outdoor" for x in L),
            "far": any(x.range == "far" for x in L),
            "rumble": cue.distant is not None and cue.distant.cue == "ExplosionFar",
            "duck": cue.duck is True,
        }
        missing = [k for k, ok in need.items() if not ok]
        if missing:
            bad.append(f"{n}: no {missing}")
        level = direct_level(cue, L)
        fam = B[cue.blast]
        blast_levels.setdefault(fam.tier, []).append(level)
        if not (fam.level[1] <= level <= fam.level[2]):
            bad.append(f"{n} ({cue.blast}) level {level:.2f} outside {fam.level[1]}..{fam.level[2]}")
    breach = [B[b].reach for b in BLAST_ORDER]
    btier = sorted(blast_levels)
    if breach != sorted(breach) or any(max(blast_levels[a]) > min(blast_levels[b]) for a, b in zip(btier, btier[1:])):
        bad.append(f"blast size order broken: reach {breach}")
    results.append(("every firearm: transient, body, room, tail, far (+ your action/chest); every blast: crack, boom, sub, debris, tails, far",
                    not bad, f"{len(firearms)} firearm cues, {len(blasts)} blasts; {bad[:3]}"))

    # 5. No gunpowder on novelty.
    bad = []
    novelty = [n for n in names if SC.Sounds[n].novelty]
    for n in novelty:
        cue = SC.Sounds[n]
        for x in layers_of[n]:
            if x.id in GUNPOWDER_IDS:
                bad.append(f"{n}: explosion-file layer")
            if x.id == SNAP_ID and CRACK_BAND[0] <= x.pitch <= CRACK_BAND[1]:
                bad.append(f"{n}: gun-crack snap @{x.pitch:.2f}")
            if x.crack or x.where or x.range or x.who:
                bad.append(f"{n}: gunpowder-style layer tag")
        if cue.calibre or cue.blast or cue.distant or cue.duck:
            bad.append(f"{n}: calibre/blast/distant/duck")
    for n in SILLY_BLASTS:
        cue = SC.Sounds[n]
        if cue is None or not cue.novelty:
            bad.append(f"{n}: missing or not novelty")
        elif SC.Rolloff(n, cue)[1] < 400 or direct_level(cue, layers_of[n]) < 0.9:
            bad.append(f"{n}: too quiet or short to warn")
    results.append(("novelty guns and silly blasts carry no gunpowder, but still warn", not bad,
                    f"{len(novelty)} novelty cues; {bad[:3]}"))

    # 6. Jitter.
    bad = [f"{n} {SC.JitterOf(n, SC.Sounds[n]):.3f}" for n in names
           if not (0.06 - 1e-9 <= SC.JitterOf(n, SC.Sounds[n]) <= 0.12 + 1e-9)]
    seq = iter([(i * 0.618034) % 1 for i in range(1, 400)])
    api.setRandom(lambda: next(seq))
    api.setClock(5000)
    api.takePlays()
    pitches, levels = [], []
    base = layers_of["GunshotSMG"][0]
    for i in range(20):
        api.setClock(5000 + i * 0.09)
        Sfx.Play("GunshotSMG", None, None)
        api.flush()
        for p in api.takePlays().values():
            if p.sound.SoundId == base.id and abs(p.sound.PlaybackSpeed / base.pitch - 1) < 0.2:
                pitches.append(round(p.sound.PlaybackSpeed / base.pitch, 5))
                levels.append(round(p.volume / base.volume, 5))
    api.setRandom(None)
    if len(set(pitches)) < 18 or len(set(levels)) < 18:
        bad.append(f"20 SMG shots: {len(set(pitches))} pitches, {len(set(levels))} levels")
    if pitches and (max(abs(x - 1) for x in pitches) > 0.061 or max(abs(x - 1) for x in levels) > 0.061):
        bad.append(f"jitter beyond 6%: {max(pitches)} {max(levels)}")
    results.append(("every cue varies +-3..6%; 20 SMG shots really differ, within it", not bad,
                    f"{len(names)} cues; SMG pitch {min(pitches or [0]):.3f}..{max(pitches or [0]):.3f}; {bad[:3]}"))

    # 7. Caps.
    bad = []
    before = api.createdCount()
    for i in range(40):
        api.setClock(6000 + i / 13)
        Sfx.PlayAt("GunshotHeavy", api.v(60, 0, 0), None)
        Sfx.Play("GunshotHeavy", None, None)
        api.flush()
    api.takePlays()
    made = [s for s in api.createdSince(before).values() if s.ClassName == "Sound"]
    n_layers = len(layers_of["GunshotHeavy"])
    if len(made) > (POOL["flat"] + POOL["positional"]) * n_layers:
        bad.append(f"40 full-auto shots built {len(made)} Sounds (cap {(POOL['flat'] + POOL['positional']) * n_layers})")
    api.setClock(7000)
    api.takePlays()
    for i in range(10):
        Sfx.PlayAt("ExplosionFrag", api.v(100 + i, 0, 0), None)
    api.flush()
    frag0 = layers_of["ExplosionFrag"][1].id  # the boom, never range-gated
    starts = sum(1 for p in api.takePlays().values() if p.sound.SoundId == frag0 and abs(p.sound.PlaybackSpeed - layers_of["ExplosionFrag"][1].pitch) < 0.2)
    if starts > BLAST_BURST:
        bad.append(f"10 blasts in one frame started {starts}")
    groups = api.groups()
    weapons = groups["BRR_Weapons"]
    if not weapons or not any(c.ClassName == "CompressorSoundEffect" for c in weapons.GetChildren(weapons).values()):
        bad.append("no bus compressor on the Weapons group")
    # Pools grow on demand: one shot of a fresh cue builds one voice; shots that each finish before
    # the next reuse it; only overlapping ones grow the pool, never past its cap.
    sizes = Sfx.PoolSizes()
    api.silence()
    for i in range(12):
        api.setClock(6500 + i)
        Sfx.PlayAt("GunshotCannon", api.v(50, 0, 0), None)
        api.flush()
        api.silence()
    if sizes["positional:GunshotCannon"] != 1:
        bad.append(f"12 separate cannon shots built {sizes['positional:GunshotCannon']} voices, want 1")
    if sizes["positional:GunshotHeavy"] != POOL["positional"] or sizes["flat:GunshotHeavy"] != POOL["flat"]:
        bad.append(f"sustained fire grew the pools to {sizes['positional:GunshotHeavy']}/{sizes['flat:GunshotHeavy']}")
    # Your own shot is never dropped by the burst cap, however many others went off this frame.
    api.setClock(7100)
    api.takePlays()
    for i in range(10):
        Sfx.PlayAt("GunshotRifle", api.v(2 + i * 0.1, 0, 0), None)
    Sfx.Play("GunshotPistol", None, None)
    api.flush()
    own = [p for p in api.takePlays().values() if p.sound.Parent.ClassName != "Attachment"]
    if not own:
        bad.append("your own shot was dropped by the burst cap")
    # Ten rifles at 1000 studs in one frame: the flat far thump starts at most BURST.distant times.
    api.setClock(7200)
    api.takePlays()
    for i in range(10):
        Sfx.PlayAt("GunshotRifle", api.v(1000, 0, i), None)
    api.flush()
    dg0 = layers_of["DistantGunfire"][0]
    thumps = sum(1 for p in api.takePlays().values() if p.sound.SoundId == dg0.id and abs(p.sound.PlaybackSpeed - dg0.pitch) < 0.2)
    if thumps > A.BURST.distant.max:
        bad.append(f"10 far rifles started {thumps} far thumps")
    # A reused voice drops the old shot's delayed echo: two sniper shots 0.05 s apart into a one-voice
    # pool; the outdoor echo plays once, for the second shot, at its time.
    SC.Sounds.GunshotSniper.voices = 1
    api.setClock(7300)
    api.takePlays()
    Sfx.PlayAt("GunshotSniper", api.v(30, 0, 0), None)
    api.setClock(7300.05)
    Sfx.PlayAt("GunshotSniper", api.v(-30, 0, 0), None)
    api.flush()
    SC.Sounds.GunshotSniper.voices = None
    echo = [x for x in layers_of["GunshotSniper"] if x.where == "outdoor"][0]
    echoes = [p for p in api.takePlays().values() if p.sound.SoundId == echo.id and abs(p.sound.PlaybackSpeed - echo.pitch) < 1e-6
              and p.sound.Parent.ClassName == "Attachment"]
    if len(echoes) != 1 or echoes[0].sound.Parent.Position.X != -30:
        bad.append(f"reused voice: {len(echoes)} echoes of the first sniper shot's slot "
                   f"{[e.sound.Parent.Position.X for e in echoes]}")
    results.append(("pools grow only on demand and cap; your shot beats the burst cap; far thumps capped; a reused voice drops stale echoes",
                    not bad, f"{len(made)} Sounds for 80 shots, {starts} of 10 blasts, {thumps} far thumps; {bad[:3]}"))

    # 8. Range: near/far cross-fade, yours vs theirs, past reach.
    bad = []
    def plays_at(name, d, flat=False):
        api.setClock(api.clock() + 5)
        api.takePlays()
        if flat:
            Sfx.Play(name, None, None)
        else:
            Sfx.PlayAt(name, api.v(d, 0, 0), None)
        api.flush()
        return list(api.takePlays().values())
    for name in ("GunshotRifle", "GunshotSniper", "ExplosionRocket"):
        L = layers_of[name]
        far_ids = {(x.id, round(x.pitch, 4)) for x in L if x.range == "far"}
        near_ids = {(x.id, round(x.pitch, 4)) for x in L if x.range == "near"}
        def tagged(ps, ids):
            return [p for p in ps if p.sound.Parent.ClassName == "Attachment" and (p.sound.SoundId, round(p.sound.PlaybackSpeed, 4)) in ids]
        close, distant = plays_at(name, 20), plays_at(name, 400)
        if tagged(close, far_ids) or (near_ids and not tagged(close, near_ids)):
            bad.append(f"{name}@20: far layer on or near layer off")
        if not tagged(distant, far_ids) or tagged(distant, near_ids):
            bad.append(f"{name}@400: far layer off or near layer on")
    self_ids = {(x.id, round(x.pitch, 4)) for x in layers_of["GunshotRifle"] if x.who == "self"}
    mine = plays_at("GunshotRifle", 0, flat=True)
    theirs = plays_at("GunshotRifle", 10)
    if not any((p.sound.SoundId, round(p.sound.PlaybackSpeed, 4)) in self_ids for p in mine):
        bad.append("your own rifle shot has no action/chest")
    if any((p.sound.SoundId, round(p.sound.PlaybackSpeed, 4)) in self_ids for p in theirs):
        bad.append("someone else's rifle shot plays your action/chest")
    far_sniper = plays_at("GunshotSniper", 1200)
    dg = {x.id for x in layers_of["DistantGunfire"]}
    if not far_sniper or any(p.sound.Parent.ClassName == "Attachment" for p in far_sniper) or not all(p.sound.SoundId in dg for p in far_sniper):
        bad.append(f"sniper at 1200: {len(far_sniper)} plays, not the flat DistantGunfire")
    if plays_at("GunshotPistol", 1200):
        bad.append("pistol heard at 1200")
    # The whizz: a rifle round passing 3 studs off your head from 300 away, one passing 50 off, a bubble.
    whiz_ids = {x.id for x in layers_of["BulletWhiz"]}
    for name, miss, want in (("GunshotRifle", 3, True), ("GunshotRifle", 50, False), ("GunshotBubble", 3, False)):
        api.setClock(api.clock() + 5)
        api.takePlays()
        t0 = api.clock()
        Sfx.PlayAt(name, api.v(300, 0, 0), None, api.v(-300, 0, miss))
        api.flush()
        got = [p.t - t0 for p in api.takePlays().values() if p.sound.SoundId in whiz_ids and p.sound.Parent.ClassName != "Attachment"]
        arrive = 300 / (900 / 0.28)
        if want and not (got and all(abs(t - arrive) < 1e-6 for t in got)):
            bad.append(f"{name} missing by {miss}: whizz at {got}, want {arrive:.3f}s")
        if not want and got:
            bad.append(f"{name} missing by {miss}: whizzed")
    results.append(("near layers close, far thump far; your action only yours; past reach only big guns carry; near misses whizz",
                    not bad, f"3 cues x 2 ranges, own vs theirs, sniper/pistol at 1200; {bad[:3]}"))

    # 9. The duck.
    bad = []
    def duck_after(name, d, radius):
        api.setClock(api.clock() + 10)
        api.resetDuck()
        Sfx.Blast(name, api.v(d, 0, 0), None, radius)
        api.flush()
        return Sfx.DuckLevel()
    if not duck_after("ExplosionRocket", 5, 14) > 0.5:
        bad.append("rocket at 5 studs didn't duck")
    ring = [p for p in api.takePlays().values() if p.sound.SoundId in {x.id for x in layers_of["BlastRing"]}]
    for label, args in (("rocket at 40", ("ExplosionRocket", 40, 14)), ("drumlet at 3", ("ExplosionFrag", 3, 7)),
                        ("party at 2", ("ExplosionParty", 2, 14))):
        if duck_after(*args) > 0:
            bad.append(f"{label} ducked")
    results.append(("a big blast beside you ducks and rings; far, small or silly ones don't", not bad and len(ring) > 0,
                    f"{len(ring)} ring plays; {bad[:3]}"))

    # 10. Categories and relative loudness.
    bad = []
    level = {n: SC.Sounds[n].volume * math.sqrt(sum(x.volume ** 2 for x in layers_of[n])) / (SC.Sounds[n].volume or 1)
             for n in names}
    for n in names:
        cue = SC.Sounds[n]
        if cue.category not in ("Weapons", "Effects", "Interface"):
            bad.append(f"{n}: category {cue.category}")
        if (cue.calibre or cue.blast or n.startswith("Gunshot") or n.startswith("Explosion")) and cue.category != "Weapons":
            bad.append(f"{n}: a weapon on the {cue.category} slider")
        world = n.startswith("Footstep") or n.startswith("Debris") or (n.startswith("Break") and SC.ClassOf(n, cue) == "world")
        if world and cue.category != "Effects":
            bad.append(f"{n}: world sound on the {cue.category} slider")
        if cue.category == "Interface" and direct_level(cue, layers_of[n]) > 0.6:
            bad.append(f"{n}: interface louder than gunfire")
    rifle_min = SC.Firearms.rifle.level[1]
    for n in ("HitConfirm", "Headshot", "HeadshotCrack"):
        if direct_level(SC.Sounds[n], layers_of[n]) >= rifle_min:
            bad.append(f"{n} louder than a rifle")
    results.append(("categories are the sliders'; hit feedback under a rifle, interface under gunfire", not bad,
                    f"{len(names)} cues; {bad[:3]}"))

    # 11. Every named key defined.
    wanted = named_keys(root)
    wanted |= {str(v) for v in SC.Debris.MATERIAL.values()} | {str(SC.Debris.DEFAULT)}
    for stage in ("MagOut", "MagIn", "PumpBack"):
        for n in novelty:
            wanted.add(SC.FoleyFor(n, stage))
    for n in names:
        if SC.Sounds[n].distant:
            wanted.add(SC.Sounds[n].distant.cue)
    missing = sorted(k for k in wanted if not SC.Get(k))
    results.append(("every cue the code names by table, tag or foley is defined", not missing,
                    f"{len(wanted)} names; missing {missing[:4]}"))
    return results


def plants(sc, sfx):
    yield "a pistol shot louder than a rifle", sc.replace(
        'GunshotPistol = {\n\t\tcalibre = "pistol",\n\t\t-- Crisp and dry: a bright crack, a short pop of body, almost no tail.\n\t\tvolume = 0.34,',
        'GunshotPistol = {\n\t\tcalibre = "pistol",\n\t\t-- Crisp and dry: a bright crack, a short pop of body, almost no tail.\n\t\tvolume = 0.6,'), sfx
    yield "a bubble gun given a gunshot body", sc.replace(
        "\t\t\t{ id = BUTTON, volume = 0.45, pitch = 2.2 },\n\t\t\t{ id = WATER, volume = 0.55, pitch = 2.5 },",
        "\t\t\t{ id = BUTTON, volume = 0.45, pitch = 2.2 },\n\t\t\t{ id = BOOM2, volume = 0.55, pitch = 2.5 },"), sfx
    yield "gunfire jitter switched off", sc.replace(
        "xfade = { 60, 180 }, jitter = 0.08 },\n\t\tblast", "xfade = { 60, 180 }, jitter = 0 },\n\t\tblast"), sfx
    yield "the blast burst cap removed", sc, sfx.replace("\tif burst.count >= cap.max then\n\t\treturn false\n\tend\n", "")
    yield "your gun's action heard by everyone", sc.replace(
        '\t\telseif layer.who == "self" and not own then\n\t\t\tgain = 0\n', ""), sfx.replace(
        '\t\treturn layer.who ~= "self"\n', "\t\treturn true\n")
    yield "the near/far cross-fade inverted", sc.replace(
        "\t\tif layer.range == \"near\" then\n\t\t\tgain *= 1 - fade\n\t\telseif layer.range == \"far\" then\n\t\t\tgain *= fade",
        "\t\tif layer.range == \"near\" then\n\t\t\tgain *= fade\n\t\telseif layer.range == \"far\" then\n\t\t\tgain *= 1 - fade"), sfx
    yield "a pistol carrying map-wide", sc.replace(
        "pistol = { tier = 3, level = { 0.36, 0.42 }, reach = 360,", "pistol = { tier = 3, level = { 0.36, 0.42 }, reach = 360, distant = 1,"), sfx
    yield "a silly blast that ducks", sc.replace(
        "\tExplosionParty = {\n\t\t-- Party Foul Cannon: a huge cork pop, a party horn squealing, confetti rustling down.\n\t\tnovelty = true,",
        "\tExplosionParty = {\n\t\t-- Party Foul Cannon: a huge cork pop, a party horn squealing, confetti rustling down.\n\t\tnovelty = true,\n\t\tduck = true,"), sfx
    yield "a debris key that doesn't exist", sc.replace('DEFAULT = "DebrisRubble"', 'DEFAULT = "DebrisGravel"'), sfx
    yield "no bus compressor", sc, sfx.replace("\tlocal bus = Acoustics.BUS[category]\n", "\tlocal bus = nil\n")
    yield "a reused voice replays the old shot's delayed echo", sc, sfx.replace(
        "if sound.Parent and voice.playId == id then", "if sound.Parent then")
    yield "your own shot subject to everyone else's burst cap", sc, sfx.replace(
        "\tif own then\n\t\treturn true\n\tend\n\tlocal class", "\tlocal class")
    yield "far thumps uncapped", sc.replace('\tDistantGunfire = {\n\t\tburst = "distant",\n', "\tDistantGunfire = {\n"), sfx
    yield "pools grow on every play, busy or not", sc, sfx.replace(
        "\t\tif not voiceBusy(pool.slots[index].voice) then", "\t\tif false then")


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
                print(f"  caught: {label} -> {failed[0][:90]}")
            else:
                print(f"  MISSED: {label}")
        print(f"sound polish planted faults: {caught}/{total} caught")
        sys.exit(0 if caught == total else 1)
    results = checks(sc, sfx, root)
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    failed = sum(1 for _, ok, _ in results if not ok)
    print(f"sound polish: {len(results) - failed}/{len(results)} checks pass")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
