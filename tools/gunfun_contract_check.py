"""Contract check for the gun rework (2026-09-24): every string a signature gun hands the rest of the game
names something that exists. No Studio.

A signature gun (GunModelsSignature) carries its identity as model attributes, read by code in other files:
  Flair    -> Viewmodel's FLAIR table (inspect, draw and reload flourishes); an unknown one silently plays
              the stock clips
  ShotCue  -> a SoundConfig cue (CombatClient plays it for every shot); an unknown one is silence
  Tracer   -> a GunFx TRACER kind; an unknown one draws nothing
  Flash    -> a GunFx FLASH kind
and every "sound" event a FLAIR clip fires names a SoundConfig cue. tools/verify.py holds the same line for
the stock guns' Flash kinds and CombatClient's maps, but never sees attributes set in a module it does not
read, so this is the half it cannot do.

It builds EVERY gun (the real GunModels under the gunfun_lab mock), prints how many attributes it examined
beside how many it flagged, and runs planted faults: a Flair, a ShotCue and a Tracer that do not exist, and
a flair sound event naming a missing cue, each written into the real module source; all four must be caught.

    python3 tools/gunfun_contract_check.py [repo]
"""

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gun_tube_check import load_sources  # noqa: E402
from gunfun_lab import Lab  # noqa: E402


def table_keys(src, name):
    m = re.search(rf"^local {name} = \{{\n(.*?)^\}}", src, re.M | re.S)
    return set(re.findall(r"^\t(\w+) = ", m.group(1), re.M)) if m else set()


def read(repo, rel):
    return (Path(repo) / rel).read_text(encoding="utf-8")


def contract(repo, sources=None, vm=None, sc=None):
    vm = vm if vm is not None else read(repo, "StarterPlayerScripts/Viewmodel.lua")
    fx = read(repo, "StarterPlayerScripts/GunFx.lua")
    sc = sc if sc is not None else read(repo, "ReplicatedStorage/Shared/SoundConfig.lua")
    flairs = set(re.findall(r"^FLAIR\.(\w+) = \{", vm, re.M))
    cues = set(re.findall(r"^\t(\w+) = \{", sc, re.M))
    tracers, flashes = table_keys(fx, "TRACER"), table_keys(fx, "FLASH")
    problems, examined = [], 0
    # Every sound a flair clip fires. The FLAIR block runs from its first definition to `Viewmodel.Flair = FLAIR`.
    start, end = vm.find("local FLAIR = {}"), vm.find("Viewmodel.Flair = FLAIR")
    block = vm[start:end] if start >= 0 and end > start else ""
    # Every capitalised string literal in the block is a sound or a hand anchor; the anchors are keypoints.
    anchors = {"SupportHand", "ChargeHand", "MagHand", "GripHand", "BoltHand", "CoverHand", "Load", "Pocket", "Slap"}
    for cue in sorted(set(re.findall(r'"([A-Z]\w+)"', block)) - anchors):
        examined += 1
        if cue not in cues:
            problems.append(f"a FLAIR clip plays sound {cue}, which SoundConfig has no cue for")
    lab = Lab(repo, sources)
    signature = 0
    for gid in lab.ids():
        attrs = lab.gun(gid)["attrs"]
        if attrs.get("Signature"):
            signature += 1
        for key, known, where in (("Flair", flairs, "Viewmodel FLAIR"), ("ShotCue", cues, "SoundConfig"),
                                  ("Tracer", tracers, "GunFx TRACER"), ("Flash", flashes, "GunFx FLASH")):
            value = attrs.get(key)
            if value is None:
                continue
            examined += 1
            if value not in known:
                problems.append(f"{gid}: {key} \"{value}\" is not in {where}")
        if attrs.get("Signature") and not (attrs.get("Flair") and attrs.get("ShotCue")):
            problems.append(f"{gid}: a signature gun without its Flair and ShotCue")
    return problems, examined, signature, len(lab.ids())


def main(argv):
    repo = argv[1] if len(argv) > 1 else "."
    problems, examined, signature, guns = contract(repo)
    for line in problems:
        print(line)
    print(f"gunfun contract: {guns} guns built, {signature} signature guns, {examined} names examined, {len(problems)} flagged")
    # Planted faults, through the same path: the module source edited and every gun rebuilt.
    sources = load_sources(repo)
    sig = sources["GunModelsSignature"]
    caught = 0
    plants = [
        ("an unknown Flair", {"GunModelsSignature": sig.replace('SetAttribute("Flair", "drum")', 'SetAttribute("Flair", "drumm")', 1)}, None, None, "Flair \"drumm\""),
        ("an unknown ShotCue", {"GunModelsSignature": sig.replace('"ShotCue", "GunshotTung"', '"ShotCue", "GunshotTungg"', 1)}, None, None, "ShotCue \"GunshotTungg\""),
        ("an unknown Tracer", {"GunModelsSignature": sig.replace('SetAttribute("Flair", "drum")', 'SetAttribute("Flair", "drum")\n\tg.model:SetAttribute("Tracer", "nosuchtracer")', 1)}, None, None, "Tracer \"nosuchtracer\""),
        ("a flair sound with no cue", {}, read(repo, "StarterPlayerScripts/Viewmodel.lua").replace('"FlairTap")', '"FlairTapp")', 1), None, "sound FlairTapp"),
    ]
    for name, edits, vm, sc, want in plants:
        src = dict(sources)
        src.update(edits)
        found = contract(repo, src, vm, sc)[0]
        hit = any(want in line for line in found)
        caught += hit
        print(f"planted {name}: {'caught' if hit else 'MISSED'}")
    print(f"planted faults caught: {caught} of {len(plants)}")
    return 0 if not problems and caught == len(plants) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
