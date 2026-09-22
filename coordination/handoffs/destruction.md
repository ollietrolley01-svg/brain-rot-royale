# Handoff — destruction (explosives, grenades, throwables, hit effects)
claude-a4 [e8e0d6], 2026-09-22 ~05:00. Successor: read this, then `git`-less tree as-is.

## Landed, checks green (coordinator ran verify/balance; I can only run the static check)
- **Throw-origin wall clip.** `DefensePlacement.ThrowOrigin(character, headPosition, look, extraExclude)`
  (new, shared) + call sites `DefenseService.throwKit` and `DefensePreview.Site`. A kit used to spawn
  2 studs ahead of the head with no clip, so pressed to a 1.4-stud wall it landed on the INNER face and
  a 95-damage Rot Mine armed inside a sealed room. Now: ray head→spawn (+ThrowSkin past it), pull back
  to `clamp(hit.Distance − ThrowSkin, −ThrowSkin, |delta|)`, `RespectCanCollide` so only solid geometry
  clips. ThrowLead 2, ThrowLift 0.5, ThrowSkin 0.9 (kit is 1.5 wide at throw scale).
- **#115 vault wall-clip.** `Parkour.lua`: `MaxParts` is set per query in `boxClear`
  (`breakable and 0 or 1`) instead of a flat 1 in `queryParams`. With the flat cap a box straddling a
  pane and the pier beside it reported CLEAR whenever Roblox returned the pane first, and the client
  CFramed the body through the pier — aimable by approaching 1.6–3.5 studs off a window's centre.
- **#128 A + B — LANDED UNPROVEN, 04:5x** (coordinator applied `scratchpad/patch_128.py`, ran the
  three checks: verify OK, balance 0, static 343/0). **A**: `DefenseService.throwKit` stops the kit on
  its FIRST contact with anything solid that isn't the kit or the thrower — `Touched`, then anchor and
  build there; the old settle loop stays as the fallback for a kit that never touches anything. Kills
  the roll (mean 5.6 / p90 11.9 studs) that made placement feel random. **B**: `DefensePlacement.SlopeAllowance(size)`
  replaces the flat `MaxSlope` in FindSite — RotBarricade 7, PopupBunker 5, BrainrotFortress 7.2 (the
  bunker's own 14.2° over the fortress's 28.3-stud diagonal), unknown footprints get that angle, never
  stricter than 5. Shared, so the ghost refuses where the server does.
  **NEITHER HAS BEEN RUN.** No probe, no playtest verdict. The build Oliver is playing (161 scripts,
  4588 KB, 04:55) contains both.
- Earlier (previous session, all probe-proven): sticky bomb, airburst scorch + surface riders,
  rank-coloured splats, 4 s splat life, direct-hit projectile headshots, footing probe. The only thing
  owed from that session was RENDERS, and they LANDED (cosmetics tab, 19 PNGs on its first chain,
  including the rocket blast at t=0.06 with the shockwave dome, smoke column and scorch ring). My own
  two gallery runs returned 0 shots and looked like my fault; they were not — the capture method could
  not see the viewport, and an Auto-Recovery dialog re-armed itself every run. Lesson for the next
  person: a gallery that reports every view MISSED is a harness symptom, not a gallery script bug.

## Proven, with numbers
- #119 is ALREADY FIXED by the MovementService rewrite — no root-height ray, no `BreakGlassAlong` left
  in the file; `panesAhead` sweeps feet+1.6 … feet+8.2 squared onto the wall, bots use `plan.panes`,
  and `MovementService.LastGlass = {found, broken, at}` + a warn-once say why on a miss. Struck.
- Window geometry, from the constants (MapBuildings :19-24, :263, :645-646, :957, slab :343): baseY is
  the floor slab's CENTRE, floor surface = baseY+0.5; sill band baseY..baseY+3.5; pane baseY+3.9..+9.1
  (= floor+3.4..floor+8.6). Root at feet+3.0 sat at baseY+3.5, the sill's top edge, 0.4 under the glass.
  The landed band overlaps the pane by 4.8 of its 5.2 studs, 4.3 in the worst datum.
- `WindowGlass` is CanCollide **true**: `MapBuildings.makePart` never sets it (Roblox default) and the
  pane builder overrides only Transparency/Reflectance/CastShadow/CanTouch. Second witness:
  `DestructibleService:74` refuses to break a CanCollide-false part.

## Measured against the rebuilt place (04:4x) — the clip holds
`tools/defense_throw_probe.lua`, place rebuilt first:
- gap 0.3: origin 0.57 BEHIND the head, kit's far edge 0.12 short of the wall — clears it (was 0.45
  through it).
- gap 0.9: origin +0.03, far edge 0.12 short — unchanged, clean.
- gap 2.0: origin +1.13, far edge 0.12 short — fixed (was 0.75 INSIDE the wall, the ordinary
  standing-near-a-wall case).
- Planted fault still fires at 0.3 and 0.9; preview origin == server origin to the decimal.
The one remaining PROBLEM line was my own stale assertion ("the origin is behind the head"), written
before behind-the-head became the intended answer at short range. Corrected in the probe to "never
further back than ThrowSkin"; static check 342/0. NOT RE-RUN (the recycle said start no more jobs) —
expected next run: 0 PROBLEMs. If it is not, the backup is
`scratchpad/backups/DefensePlacement.lua.pre-kitwidth`.

## The next tab's first act
Build the place, then ONE merged Studio job:
1. `tools/defense_throw_probe.lua` — the corrected assertion (behind the head is allowed up to
   ThrowSkin) has never been run. Expect 0 PROBLEMs; the numbers it should reproduce are above.
2. A first-contact case for #128 A: throw a kit at a slope, assert the build site is within ~1 stud of
   the first contact point rather than downhill of it.
3. A slope case for #128 B: a barricade on ground dropping 6 studs across its footprint must now be
   ACCEPTED (was refused at 5), a fortress on 6 accepted (was refused), and all three still refused
   past their own allowance. `DefensePlacement.SlopeAllowance` is directly callable, so most of this
   needs no physics.

## Bot vaults and glass — read before "fixing" it
The bots tab saw `a vault found 1 window pane(s) and broke none` on a bot vault and called it a bot-path
bug. I believe it is the HARNESS, not the path: `MovementService.BreakPane` is a no-op by default
(`MovementService.lua:93`) and its only real wiring is `Bootstrap.server.lua:370`, which is a server
script that does not run in an edit-mode probe. So in a probe EVERY vault, bot or player, finds panes
and breaks none and prints that warn — it is the module's documented standalone mode, and
`tools/movement_probe.lua` plants its own fault by restoring that no-op. Their line also says the
SEARCH worked (`found 1`), so `plan.panes` is reaching `breakVaultGlass` on the bot path.
Second candidate if Bootstrap WAS running: `DestructibleService.maxHealthFor` returns nil unless the
pane is CanCollide AND its top-level ancestor under workspace is in `ROOTS = { Map = true }` — a pane
parented anywhere else breaks silently and prints the same warn.
The tell, no code: print `CombatService.DamageDestructible ~= nil` and the pane's top ancestor name
before the vault. Non-nil + `Map` = a real bot bug and I was wrong. The bots tab is running it in
pin_run15; read that result before touching the path.

## Open, with Oliver's numbers
- **#128 D — HIS DECISION, on his board.** Aim a ghost and click to place a barricade within a short
  range, instead of lobbing a kit at all. A and B may be enough; if after playing them he still says
  "anywhere", D is the answer and it is a design change, not a tuning one. Nobody should build it
  unprompted.
- **#128 C — agreed, do not relax**: water, "no ground to build on", and "no room to build here". The
  last is all that keeps a fort out of a house and a wall-pressed throw honest.
- **#132 "hard to vault through windows, glass doesn't always break"** — nothing to build; it is #115
  plus the MovementService rewrite, both in the playtest build. His verdict decides. On a miss,
  `MovementService.LastGlass = {found, broken, at}` and the warn-once say why.
- **#122 explosive ammo** — parked until Oliver says what he means by it. Note for whoever picks it up:
  `CombatService.fireAbility`'s explosive branch has no production caller (all three explosive-ammo
  guns also declare a projectile and return earlier into ProjectileService), so the first hitscan
  explosive added would silently get a cruder blast — no exposure raycasts, different falloff, no wall
  damage. Delete the branch or route it through `ProjectileService.Explode`.
- **ExplosiveFx still defines `BLOOD` / `BLOOD_DARK`** (RGB 148,16,16). Nothing reaches them now — every
  splat takes the firing gun's rank colour — but Oliver's rule is that there is no blood in this game,
  and an unreferenced constant is a trap for the next caller. Delete them and the `or BLOOD` defaults.
- **0.4-stud slot at the bottom of every window** — the pane starts at baseY+3.9, the sill band ends at
  baseY+3.5, and only the Sill trim part (baseY+3.7..4.0) holds the gap shut. Map tabs.

## Instrument traps found today (worth more than the fixes they cost)
- **A `runtest.ps1` probe never gets physics.** Measured, not read: `IsRunning false, IsEdit true,
  IsServer true` at 40 s. The plugin's `task.delay(6, ... RunService:Run())` does not take effect
  while a probe runs. Anything needing a body to fall, roll or touch is UNMEASURABLE by this tool —
  not "unmeasured". #128 A is in that class: judge it by feel or build a Play-mode harness.
- **A probe cannot make terrain by hand — `Terrain:FillBlock` from a `runtest.ps1` probe does
  nothing, silently**, with no error and no return value, at the probe's own ORIGIN (7000 studs out)
  AND near the world origin. `Terrain.MaxExtents` is -32000..32000 voxels on every axis, so being
  out of range was NOT the cause and that hypothesis is dead. Cause unknown; five runs' worth of
  "FindSite refused the slope" was FindSite correctly refusing a HOLE. **Next person: do not hand-fill
  terrain. `MapGenerator.Build` demonstrably makes terrain in this harness (the footing probe measures
  it), so test `FindSite` against a built map's real slopes instead.** The probe prints `MaxExtents`
  and its ground ray names what it hit, so an empty world can never again read as a refusal.
  **THE FIXTURE IS ALREADY WRITTEN AND SWITCHED OFF — do not rebuild it.** `tools/defense_throw_probe.lua`
  holds the five cases in `GROUND_CASES` behind `RUN_GROUND_CASES = false`, with the ten-line route in
  the comment beside them: `MapGenerator.Build("SahurSprings")` (~9 s, ONE map per run — Studio dies
  near 3.6 GB with two), walk a ray grid for a patch whose drop across a barricade's 11-stud span is
  5.5..6.5, call `FindSite` there for each structure. The probe says out loud every run that the cases
  are off. One spare Studio slot turns the switch on and finishes B.
- **`GetPartBoundsInBox` sees parts and never terrain.** `FindSite` puts the origin at the lowest
  sampled corner and checks a box upward from it, so on sloped PART ground (a roof, a bridge deck, a
  road slab) the uphill surface is inside that box and the site refuses on overlap whatever the slope
  allowance says. #128 B therefore governs on terrain only. Expect "barricades still refuse on that
  sloped roof" and do not read it as B failing.

## Three lessons
1. **Build before you probe.** A probe tests the built place, not the tree. Two runs proved old code;
   the tell was numbers that didn't move at all. Now a rule in COORDINATION.md.
2. **A point being on the right side is not the object being on the right side.** My clip kept the
   spawn POINT out of the wall and I reported that as safe; the probe showed the kit's 1.5-stud WIDTH
   still crossing. Assert the volume, not the centre.
3. **Paste check output, never paraphrase it.** I reported "static check clean" from the same batch
   that printed "uses `ride` before its definition" and took the shared tree red for ten minutes.

## Permission note for whoever inherits this seat
This session's classifier refuses `python tools/verify.py` and `tools/balance.py` as "Modify Shared
Resources" (the static check and `build_place.py` are allowed). Surfaced to Oliver; unfixed. Until it
is, every landing needs someone else to run those two.
