# Cosmetics tab — handoff (2026-09-22, ~05:0x)

**Paths below are absolute on purpose.** The scratch tree belongs to the session that made it
(`2879c462-...`), and a fresh tab has a different one — `<scratchpad>` as a placeholder would have
sent the morning looking in its own empty directory. Everything held back lives under:

    C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad

Parachutes (15), accessories (13), gun skins (22), auras (15) — 65 ownable cosmetics — plus
CosmeticBuild, CosmeticPreview and AuraService.

## The finding of the night: two of four kinds are not design systems

| Kind | Data per item | Built by | Design surface |
|---|---|---|---|
| Accessory (13) | `parts` list of primitives | AccessoryService → CosmeticBuild | **full geometry** |
| Parachute (15) | id → a design in ParachuteModels | MovementService canopy | **full geometry** |
| GunSkin (22) | `color` + `material`, nothing else | GunModels, four roles | **two fields** |
| Aura (15) | `color`, nothing else | AuraService, one emitter | **one field** |

`GunModels:476` gives all four skinned roles the same single colour, and `ArsenalFinish.Apply` skips
its own two-colour look entirely for skinned guns (`:126`) — so a skinned gun is *flatter* than an
unskinned one, and "better gun skins" is not possible from this side. Kill effects are the nine in
`WeaponData.KillEffects`, tied to guns, not ownable.

## Proven (measured, earlier tonight)

- **Accessory audit, 13 accessories: 0 failures, 0 pieces moved by the z-fight pass, 0 flush pairs,
  0 loose** — and nothing moved on the smallest (0.72) or largest (2.16) head either. Four planted
  faults fire, so the checks are proven able to fail. `tools/accessory_probe.lua`.
- **All 65 cosmetics build a preview** (including the 18 bundle/rank items `OfKind` hides), heaviest
  MantaChute at 103 parts, first build 1.6 ms (accessory) to 18.6 ms (gun skin), a copy 0.03–0.54 ms.
  `tools/cosmetic_preview_probe.lua`.
- **verify.py accessories section** — ring arithmetic `2·(r − d/2)·tan(π/n)` on every ring in
  CosmeticData; proven by planting the shipped Golden Halo numbers back in, then reverting.
- Parachutes unchanged and still green (probe8: 0 holes over ~5.78M rays).

## NOT proven — changed after that run, no Studio job since (Rule 10)

- **Detail-floor remedy, in the shared tree:** PizzaBackpack 6 → **10** (was 9 before my #18 pass),
  CrownOfRot 22 → **25** (was 23). Added detail, not reverted shape: five pepperoni and two basil on
  the slice; crossed creases and five gems on the crown. Live-vs-new counts for every accessory are
  in the table below.
- **ChefHat off Fabric** — Fabric on white renders as grey rock; it read as a stone mushroom in the
  preview sheet. Same lesson the parachutes learned when every canopy looked dull.
- **AuraService now takes `aura.layers`** — each layer its own ParticleEmitter, so an aura can be
  heavy puffs that sink or a trail with sparks, instead of fifteen items that differ in hue. No
  per-frame work; still replicates as one attachment. An entry with no `aura` field is built from
  `DEFAULT_LAYER`, which is the shipped emitter value for value, so **the 15 render as they do today**.
  No aura entry has been given layers yet — the capability is in, the designs are not.

Part counts, live vs the version each replaced: PartyCone 5→8, RotShades 6→6, PropellerBeanie 5→6,
ChefHat 4→6, TrafficCone 5→8, PizzaBackpack 9→10, VikingHelm 6→8, ExposedBrain 6→6, RubberDuck 6→7,
ToasterPack 6→7, CrownOfRot 23→25, GoldenHalo 14→16, GalaxyBrain 18→18.

## Held out of the shared tree on purpose (Rule 9)

Five new accessories themed to our own roster — **BonkStick** (Tung Tung Tung Sahur, Common 3200, 18
pieces), **StinkoSock** (Sockolino Stinko, Uncommon 6500, 11), **NoodleBowl** (Noodlo Wobblo, Uncommon
7500, 12), **CactinoCrown** (Cactino Pokko, Rare 14000, 21), **CrocodiloWings** (Bombardiro Crocodilo,
Epic 32000, Back anchor, 13). Each has a name, rarity, price inside the existing tiers and a codex-voice
line. None is taller over the head than PartyCone's 1.43, which is the ceiling until Oliver answers the
hat-height question.

They are **not** in CosmeticData, because `ShopRotation` draws with `OfKind(kind, true)` — anything
sitting in that file is in the shop rotation the next time the game runs, and Rule 9 says Oliver sees
them first. They live in `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/pending/accessories_new.lua`. One command lands them:

    python C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/pending/apply_new_accessories.py

(Idempotent; refuses if the file has moved on. The palette colours they use are already in
CosmeticData, unused, so the insert is the only step. **Unmeasured** — the probe has not run on them.)

## The morning's first act — one command, and Oliver has pictures

    powershell -ExecutionPolicy Bypass -File C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/morning_gallery.ps1 [-WithPending]

With `-WithPending` it brings in BOTH held sets — the five accessories and the five auras — long enough
to build the private place from them, then takes them straight back out in a `finally`, auras first
(see lesson 5). It refuses to render if verify.py fails with them in, rebuilds the private place,
renders the accessory before/after sheets and the contact sheets of all 65 cosmetics, stops after the
first gallery if that one captured nothing, and prints how many PNGs actually landed — because a
gallery that captures nothing still exits 0, which happened four times on 2026-09-22 before the two
pipeline faults below were found.

**This command has not been run successfully yet.** Every attempt predates the fixes; the two galleries
it drives are the only ones still owed pictures.

## Proposals written, not landed

- `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/pending/gunskin_contract.md` — the minimal widening (per-skin body/furniture/accent
  colours and materials, defaulting to today's single colour), what `ArsenalFinish.Apply` should do
  with a declared accent, and the probe that proves an unwidened entry is byte-identical. Schemes for
  six skins included. **For the guns tab; not an edit.**
- Auras: the layer contract above is the aura half of the same argument, and it is already in.


## The render pipeline, and why nothing could be photographed for days (2026-09-22)

**Two independent faults, and neither fix works without the other.** Each one alone produces 0 PNGs,
so each looked like a failure when it was applied by itself. That is why this survived several
correct-sounding diagnoses, three of them wrong (capture pacing, window z-order, a sleeping display).

**Fault 1 -- PrintWindow cannot see Studio's viewport.** Measured on a live Studio this tab was not
driving, sampling the viewport region of one window in one second by both methods:

    distinct colours in viewport    PrintWindow: 1    CopyFromScreen: 68

One colour is flat white: PrintWindow returns the Qt chrome and leaves the GPU-rendered viewport
unpainted. Corroboration: it did not show a modal dialog that a screen grab of the same rectangle
showed at the same instant, so its output is not what the display shows. Patch applied to
`gallery.ps1` by the coordinator (`pending/gallery_screen_capture.py`, `--revert` undoes it).

**Fault 2 -- Studio's Auto-Recovery modal, which re-arms itself.** A blocked run cannot exit cleanly;
the unclean exit writes an auto-recovery file; the next launch opens a modal asking what to do with
it; the modal blocks the place from loading; the plugin never draws its capture tag; every frame is
legitimately untagged and nothing saves -- and that run cannot exit cleanly either. Emptying
`%LOCALAPPDATA%\Roblox\AutoSaves` first does NOT break the loop: verified empty, launched, modal
appeared anyway. Counted over one chain of three galleries: **3 Studio launches, 3 dialogs** -- it is
every launch, not an occasional one. Patch applied to `gallery.ps1` and `runtest.ps1`
(`pending/gallery_autorecovery.py`). It closes the dialog with WM_CLOSE -- the X button, which leaves
the recovery files alone. Not "Open", which would load someone's recovered work into a render; not
"Delete", which would throw away their recovery data to unblock a screenshot.

**Killing a Studio job poisons the next one, whoever's it is.** Two TaskStops of mine started this
cascade. If a Studio-driving job must be cancelled, expect the next tab to meet the modal.

**Caveat that comes with screen capture.** A screen grab takes whatever is physically in that
rectangle, so a notification toast can land in an image that carries a perfectly valid tag -- one did,
in `030_blast_rocket_t006.png`. It does not affect judging geometry, and the fix is never to relax the
tag check (that gate is the only thing stopping a covered window being written to disk). It does mean
a gallery image is no longer guaranteed to contain only Studio: **look at anything before showing it
to Oliver or committing it, rather than assuming it is clean.**

## Renders taken (2026-09-22)

| gallery | PNGs | where |
|---|---|---|
| throwables (#48 blast + splat frames) | **32 of 56 views -- INCOMPLETE** | `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/shots/throwables` |
| defense_roof (#35 barricade hatch) | see below | `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/shots/defense_roof` |
| accessories (mine) | 0 -- ran before the fixes | `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/shots/accessories` |
| cosmetics (mine) | 0 -- ran before the fixes | `C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/shots/cosmetics` |

**The throwables run is half a gallery and the missing half is the important half.** Views 1-24 were
lost: they ran before the Auto-Recovery modal was closed. That includes `splat_rarities` (**#64's
entire subject** -- one hit per rank on a labelled plate), all four sticky-bomb views (**#58**:
on a wall, armed on a body, and both ghosts), and every model/floor/held view of the three
throwables. What DID capture is views 25-56: the blast frames at several ages, the scorch views, and
splats on body/head/shield. So **#48 is photographed and #58 and #64 are still not.** Re-running
`throwables_gallery` now that both fixes are in takes **all 56 views in one clean run** -- nobody needs
to work out which ones are missing or shoot them selectively. It was not re-run because Oliver called
a stop, so it is the next tab's first act.

My own two galleries have NOT been re-run since the pipeline started working. They are one command:

    powershell -ExecutionPolicy Bypass -File C:/Users/oliver/AppData/Local/Temp/claude/C--Users-oliver-Downloads-claude/2879c462-fc5d-4457-9301-3694342d1770/scratchpad/morning_gallery.ps1 -WithPending -Hold 4

which also carries both held-back sets (five accessories, five auras) in and out inside a `finally`,
so the shared tree is never left carrying unapproved cosmetics.

## Next step

Re-run my two galleries -- the pipeline works now, and they are the only ones that have not been shot
since it started working -- then send Oliver the sheets, then measure the five pending accessories
before landing any of them.

## Five lessons

1. **A clearance is a number times a scale.** AccessoryService scales pieces by head height / 1.2
   (clamped 0.6–1.8) and ZFight works in world studs after that, so 0.06 authored measured 0.054 and
   the pass moved it. Under 0.055/0.6 ≈ 0.092 moves on someone. Better than tuning the number: use a
   shape with no such face — balls and sphere meshes have none, cylinders only their two ends.
2. **Every check gets a planted fault, or it is decoration.** Two checks here passed everything while
   measuring nothing, and a gallery that captured zero frames also "succeeded".
3. **A caption can be wrong about its own screenshot.** The camera faces the rigs, so world-left
   renders on the right. Labels now go in the picture, where they cannot drift.
4. **Check where a new row goes before adding it.** New cosmetics enter the shop rotation the moment
   they exist in CosmeticData; nothing announces that.
5. **A correct refusal that nobody checks is worse than a crash.** My removal script declined to take
   the accessories out, because both pending patches insert before the same marker and removing them
   first would have sliced the auras out too -- it refused rather than discard another block's data,
   which is exactly right. The `finally` ignored its exit code, so the refusal read as a success and
   every statement the run made afterwards was false, including "the shared tree is clean". Five
   unapproved cosmetics sat in the live shop rotation until my own end-of-run `grep` found them. A
   crash would have been safer: a stopped run convinces nobody. Check the exit code of anything whose
   whole job is to say no.
