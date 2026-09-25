"""Behaviour check for the death effects (#24; "kill animations" in the code and the save), without Studio.

Runs the REAL source, in a Lua interpreter (lupa), of every file below, against tools/deathfx_mocks.lua:
stand-ins for Roblox with real arithmetic (Vector3, CFrame with rotations, Color3), logged Instances and
a virtual clock with a Heartbeat. The checks themselves are tools/deathfx_check.lua.

  * CosmeticData       15 death effects: every rarity has one; Common to Epic sold, priced inside the band
                       the other kinds use for that rarity; Legendary and up price-less crate exclusives,
                       and only while a crate draws the kind; names unique
  * CrateData          the Death Effect Crate: odds add to 100, every rarity it rolls has a death effect,
                       it can roll Legendary to Secret, it's last in Order, its card shows every rarity
  * RewardService      EquipCosmetic: equip, re-equip takes it off, unowned refused, nil clears it
  * PlayerData         reconcile(): an old save loads exactly as the working branch's does
  * StateSync, Bootstrap  the slot is sent; the service is chained onto OnKillCredited
  * ShopRotation       2000 rotations: every other kind's stock AND every existing crate's stock identical
                       to the working branch's; exactly KillAnimationSlots (4) on sale; every buyable one
                       turns up; no crate exclusive is ever on sale
  * KillAnimService    plays only an owned, equipped death effect for a real player; sends the body only
                       when DeathFxService.Claim took it, for longer than the effect lives; Chain passes
                       the kill on even when it fails
  * DeathFxService     Claim: a plain ragdoll only, once, anchored and untouchable, hidden when time is up;
                       Apply sends the body and the ragdoll's linger
  * DeathEffectFx, DeathEffectDesigns
                       every cosmetic has a design and every design a cosmetic; easing runs 0 to 1; the
                       caps are what the report states; per design, in PREVIEW mode: no emitter, light or
                       highlight (a ViewportFrame draws none), sparks capped, every part counted, nothing
                       timed past the life, the body gone at the end, the stand-in body put back exactly
                       by Destroy; a still at each gallery moment and the peak is the same frame stepping
                       at 60 fps gives (stills and thumbnails ARE the game's frames); geometry never
                       written to an unanchored body part
  * KillAnimFxClient   per design, in the WORLD: parts / particles / lights under the caps, at least one
                       light, one burst and one sound; every sound a SoundConfig cue the design lists, and
                       every listed cue played; textures only the built-in five; the body touched by the
                       burst and invisible by the end; no particle alive and nothing written after the
                       folder goes; the Heartbeat let go; a greedy design cut off at every cap; at most
                       MAX_LIVE at once, the skipped bodies faded; far, unknown and malformed ones built
                       not at all
  * DeathFxClient      the plain death's dressing: one Highlight on the body, the puff when the ragdoll
                       starts to fade, never a write to the ragdoll, none on a claimed body, capped

    python tools/killanim_check.py .            the checks
    python tools/killanim_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("killanim_check: needs lupa (pip install lupa)")

BASE_BRANCH = "claude/roblox-game-tasks-wv7n8k"

FILES = {
    "cosmetic": "ReplicatedStorage/Shared/CosmeticData.lua",
    "crate": "ReplicatedStorage/Shared/CrateData.lua",
    "rarity": "ReplicatedStorage/Shared/Rarity.lua",
    "rotation": "ReplicatedStorage/Shared/ShopRotation.lua",
    "engine": "ReplicatedStorage/Shared/DeathEffectFx.lua",
    "designs": "ReplicatedStorage/Shared/DeathEffectDesigns.lua",
    "soundconfig": "ReplicatedStorage/Shared/SoundConfig.lua",
    "safevalue": "ReplicatedStorage/Shared/SafeValue.lua",
    "service": "ServerScriptService/Modules/KillAnimService.lua",
    "deathservice": "ServerScriptService/Modules/DeathFxService.lua",
    "statesync": "ServerScriptService/Modules/StateSync.lua",
    "bootstrap": "ServerScriptService/Bootstrap.server.lua",
    "client": "StarterPlayerScripts/KillAnimFxClient.client.lua",
    "deathclient": "StarterPlayerScripts/DeathFxClient.client.lua",
}
PLAYERDATA = "ServerScriptService/Modules/PlayerData.lua"
REWARD = "ServerScriptService/Modules/RewardService.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/]|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def read(root, path):
    return open(os.path.join(root, path), encoding="utf-8").read()


def base_version(root, path):
    # A fresh worktree or clone has the base only as a remote-tracking branch: without the origin/
    # fallback the old-save comparison was skipped silently (and its plant missed).
    for ref in (BASE_BRANCH, "origin/" + BASE_BRANCH):
        try:
            return subprocess.run(["git", "-C", root, "show", f"{ref}:{path}"], capture_output=True,
                                  text=True, check=True).stdout
        except (subprocess.CalledProcessError, FileNotFoundError):
            continue
    print(f"killanim_check: WARNING: {BASE_BRANCH} not found (nor origin/); old-save checks skipped")
    return None


def reconcile_block(text):
    start = text.index("local function defaultData()")
    rec = text.index("local function reconcile(saved)", start)
    end = text.index("\nend\n", rec) + 5
    return "local PlayerData = {}\n" + text[start:end] + "return reconcile\n"


def equip_block(text):
    start = text.index("function RewardService.EquipCosmetic")
    end = text.index("\nend\n", start) + 5
    return "local RewardService = {}\n" + text[start:end] + "return RewardService\n"


def run(root, mutate=None, report=False):
    sources = {key: read(root, path) for key, path in FILES.items()}
    sources["reconcile"] = reconcile_block(read(root, PLAYERDATA))
    sources["equip"] = equip_block(read(root, REWARD))
    if mutate:
        mutate(sources)
    sources = {k: luau_to_lua(v) for k, v in sources.items()}
    base_pd, base_rot, base_crate = (base_version(root, p) for p in (PLAYERDATA, FILES["rotation"], FILES["crate"]))
    sources["baseReconcile"] = luau_to_lua(reconcile_block(base_pd)) if base_pd else None
    sources["baseRotation"] = luau_to_lua(base_rot) if base_rot else None
    sources["baseCrate"] = luau_to_lua(base_crate) if base_crate else None
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools/deathfx_mocks.lua"))
    check = lua.eval("function(source) return load(source, '=deathfx_check') end")(read(root, "tools/deathfx_check.lua"))
    try:
        out = check(mocks, lua.table_from(sources))
    except Exception as err:  # a crash counts as caught for a plant, a failure otherwise
        return [f"harness error: {err}"]
    if report:
        for line in out.report.values():
            print("  " + line)
    return list(out.fails.values())


def swap(key, old, new, count=1):
    def mutate(sources):
        if sources[key].count(old) < 1:
            raise SystemExit(f"killanim_check: plant text not found in {key}: {old!r}")
        sources[key] = sources[key].replace(old, new, count)
    return mutate


# Each aimed at something the code must refuse forever, not at a bug that has since been fixed.
PLANTS = [
    ("death effect priced out of band", swap("cosmetic", "price = 7000,\n\t\tcolor = Color3.fromRGB(168, 122, 72)", "price = 70000,\n\t\tcolor = Color3.fromRGB(168, 122, 72)")),
    ("a Legendary one sold in the shop", swap("cosmetic", 'rarity = "Legendary",\n\t\tcrateOnly = true,\n\t\tcolor = Color3.fromRGB(150, 226, 255)', 'rarity = "Legendary",\n\t\tprice = 30000,\n\t\tcolor = Color3.fromRGB(150, 226, 255)')),
    ("no crate draws the kind", swap("crate", 'category = "KillAnimation",', 'category = "Parachute",')),
    ("the crate moved up CrateData.Order", swap("crate", '"Skin", "Aura", "Parachute", "DeathEffect" }', '"Skin", "Aura", "DeathEffect", "Parachute" }')),
    ("EquipCosmetic without the slot", swap("equip", ', KillAnimation = "killAnimation"', "")),
    ("PlayerData forgets to load it", swap("reconcile", "data.Cosmetics.killAnimation = saved.Cosmetics.killAnimation", "")),
    ("an old save gains a non-empty default", swap("reconcile", "Consumables = { Health = 0,", "Consumables = { Health = 1,")),
    ("StateSync doesn't send it", swap("statesync", "killAnimation = data.Cosmetics.killAnimation,", "")),
    ("shop draws them with the main Random", swap("rotation", '{ kind = "GunSkin", count = 3 },', '{ kind = "KillAnimation", count = 2 },\n\t{ kind = "GunSkin", count = 3 },')),
    ("slots left at 2", swap("rotation", "ShopRotation.KillAnimationSlots = 4", "ShopRotation.KillAnimationSlots = 2")),
    ("server skips the ownership check", swap("service", "or not data.Cosmetics.owned[id] then", "then")),
    ("server sends a body it didn't claim", swap("service", "if design and character and DeathFxService.Claim(character, design.life + CLAIM_MARGIN) then", "if design and character then")),
    ("claimed for less than the effect lives", swap("service", "local CLAIM_MARGIN = 0.4", "local CLAIM_MARGIN = -1")),
    ("Chain lets an error through", swap("service", "local ok, err = pcall(KillAnimService.Play, killer, victim)", "local ok, err = true, KillAnimService.Play(killer, victim)")),
    ("Claim takes a gun effect's body", swap("deathservice", 'character:GetAttribute("DeathFx") ~= "ragdoll"\n\t\tor ', "")),
    ("Claim never hides the body", swap("deathservice", "\ttask.delay(seconds, function()\n\t\thideBody(character)\n\tend)\n\treturn true", "\treturn true")),
    ("engine part cap removed", swap("engine", "if not self.alive or self.parts >= DeathEffectFx.MAX_PARTS then", "if not self.alive then")),
    ("engine particle cap removed", swap("engine", "local count = math.min(spec.count or 10, DeathEffectFx.MAX_PARTICLES - self.particles)", "local count = spec.count or 10")),
    ("engine light cap removed", swap("engine", "if self.lights >= DeathEffectFx.MAX_LIGHTS then", "if false then")),
    ("particles outlive the effect", swap("engine", "math.min((spec.life or { 0.6, 1.2 })[2], self.life - t - 0.05)", "(spec.life or { 0.6, 1.2 })[2] + 2")),
    ("a still isn't a real frame (landing order)", swap("engine", "if not track.done and track.t1 <= t then", "if false then")),
    ("preview emits real particles", swap("engine", "\t\tif self.preview then\n\t\t\tself:sparks(t, position, spec)\n\t\t\treturn\n\t\tend\n", "")),
    ("preview doesn't put the body back", swap("engine", "\tif self.preview and self.pieces then", "\tif false then")),
    ("geometry written to a loose body", swap("engine", "if not part.Parent or not part.Anchored then\n\t\treturn", "if not part.Parent then\n\t\treturn")),
    ("texture outside the built-ins", swap("engine", 'glow = "rbxasset://textures/glow.png",', 'glow = "rbxassetid://1234567",')),
    ("easing that overshoots its end", swap("engine", "return 1 + C3 * (a - 1) ^ 3 + C1 * (a - 1) ^ 2", "return 1.02 + C3 * (a - 1) ^ 3 + C1 * (a - 1) ^ 2")),
    ("a design runs past its life", swap("designs", "fx:tween(2.1, 0.6, function(e)\n\t\t\tif puddle then", "fx:tween(2.5, 0.6, function(e)\n\t\t\tif puddle then")),
    ("a design leaves the body standing", swap("designs", "\t\tfx:tween(1.8, 0.45, function(e)\n\t\t\tfx:bodyPose({ fade = e })\n\t\tend)\n\tend,\n}\n\n-- They shiver", "\tend,\n}\n\n-- They shiver")),
    ("a cue that isn't in SoundConfig", swap("designs", 'fx:sound(HIT, "DeathBonk", 0.1)', 'fx:sound(HIT, "DeathBonkk", 0.1)')),
    ("a cosmetic with no design", swap("designs", "Designs.KillDrumStamp = {", "Designs.KillDrumStampTypo = {")),
    ("client live cap removed", swap("client", "if far or liveCount() >= MAX_LIVE then", "if far then")),
    ("client culling removed", swap("client", "local far = camera and (camera.CFrame.Position - position).Magnitude > CULL_DISTANCE", "local far = false")),
    ("client never tears down", swap("client", "\t\tif entry.t >= entry.life then\n\t\t\tentry.fx:destroy()", "\t\tif entry.t >= entry.life then\n\t\t\tlocal _ = nil")),
    ("skipped body left frozen", swap("client", "\t\tif body then\n\t\t\tfadeBody(body, position)\n\t\tend\n\t\treturn\n\tend\n\n\tlocal life", "\t\treturn\n\tend\n\n\tlocal life")),
    ("dressing plays on a claimed body", swap("deathclient", "if not body.Parent or claimed(body) or #dressing >= MAX_DRESSED then", "if not body.Parent or #dressing >= MAX_DRESSED then")),
    ("dressing never puffs at the fade", swap("deathclient", "\t\ttask.delay(linger, function()", "\t\ttask.delay(linger + 3, function()")),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, mutate in PLANTS:
            fails = run(root, mutate)
            print(("caught  " if fails else "MISSED  ") + name + (f"  ({fails[0][:120]})" if fails else ""))
            missed += 0 if fails else 1
        print(f"killanim_check: {len(PLANTS) - missed}/{len(PLANTS)} planted faults caught")
        sys.exit(1 if missed else 0)
    fails = run(root, report=True)
    for line in fails:
        print("FAIL " + line)
    print(f"killanim_check: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
