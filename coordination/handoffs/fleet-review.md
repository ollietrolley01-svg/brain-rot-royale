# Fleet & partner review tab — handoff (2026-09-22, ~12:2x)

Tab: "Fleet and partner work review [d516ca]", started ~11:00 on Oliver's ask to review the fleet's
overnight work and the GitHub contributors'. No brief from the coordinator until 12:2x; everything
below was done before that message arrived, which is why it is in the tree unread. **Stopped now.**

## LANDED (shared tree). Three checks after the last edit, verbatim:
    OK: no problems                       (tools/verify.py .)
    files unbalanced: 0                   (tools/balance.py .)
    lua static check: 349 files, 0 findings

**1. Companion boons + explosive abilities (Oliver, ~12:0x, direct ask).**
- NEW `ServerScriptService/Modules/CompanionBoons.lua`. Passive effects a companion gives its OWNER.
  Opt-in by a `boon` field in BrainrotData; the module names no brainrot — the StatusEffects/WeaponData
  contract. Kinds: `regen`, `speed`, `jump`, `health`, `venom`.
- `ReplicatedStorage/Shared/BrainrotData.lua` — new `BrainrotData.Boons` vocabulary, `BlastMinRarity`
  / `BlastRadius` / `BlastRadiusStep` / `BlastPower`; `boon = {...}` on **16** of 126 entries,
  `blast = true` on **6** (Legendary and rarer only).
- `ServerScriptService/Modules/CompanionService.lua` — 4 hooks: the require; `CompanionBoons.Clear`
  in `despawn()`; `Apply` in `spawnFor()`; `Tick` + `TickVenom` in the existing Heartbeat. Plus
  `blastFor()` and a branch in `UseAbility` so a blast brainrot explodes INSTEAD of landing its single
  hit (the blast IS the ability, not a bonus on top).
- `ServerScriptService/Modules/MovementService.lua` — NEW `MovementService.SetJumpFactor(humanoid, key,
  factor)`, keyed composition through `JumpF_<key>` attributes; `bounceBoots` now routes through it.
  **This is a bug fix, not only a seam:** boots wrote `JumpHeight` directly and restored to
  `BaseJumpHeight` on expiry, so ANY second source of jump height was silently wiped when a consumable
  the player drank earlier ran out. Two rules for one property, last writer wins.
- `tools/verify.py` — `boons:` check, 2 planted faults (a misspelled boon key; a blast below the
  rarity floor). Both fire. Prints `boons: 16 brainrot(s) carry a boon, vocabulary 5 keys, blast
  floor Legendary; 2/2 planted faults fired`.

**2. `OLIVER_LIST.md` rebuilt** as a current ledger covering #1–#133 (was #1–#64, last true 09-18).
Old copy at `OLIVER_LIST.md.bak` (gitignored). **The numbering collision is the important part** — see
OPEN below.

**3. `.gitignore`** gained `*.pre-*`; the existing `*.pre_*` never matched what the tabs actually write.

## NOT PROVEN — say this rather than letting three green checks imply otherwise
- **No probe has run on the boons. Nothing has been seen in Studio.** It is reasoning plus the static
  gates. The numbers are a first pass and Oliver's playtest decides balance.
- `SetJumpFactor`'s attribute sweep and boots restore: unexercised.
- The blast path: `ProjectileService.Explode` with `kind = "grenade"` (a registered cue, so the client
  draws a real explosion). Field shapes read off `explode()`'s own body, never run.
- Venom: refreshes rather than stacks, credited as `Companion:<name>`. Never run.
- **Review request already sent to the bug-review tab** with these four in priority order.

## IN MY TREE — nothing. Everything above is in the shared tree. No Studio job, no queue, no lock.

## OPEN, and two of these are yours to route
1. **#59–#64 MEAN TWO DIFFERENT THINGS and both are in live use.** `make improvements to the shown
   map.txt` numbers by position (#64 = the shotgun nerf); the old OLIVER_LIST gave #59–#64 to six
   separately-typed items (#64 = rarity-coloured splats), and COORDINATION.md + four handoffs use
   that second set. Proof the positional one is right: items #88–#94 carry their numbers written into
   the text and land on exactly those ordinals. **Resolved in the rebuilt ledger** by keeping
   positional for #1–#94 and moving the six to **A1–A6** with their old numbers recorded. Nothing
   else was renumbered. If you disagree, the ledger is the only thing to change.
2. **Two HUD items have no valid number** — `hud-menu.md` calls the stuck-cursor fix "#33" and the team
   results card "#25"; both numbers belong to other items. Parked unnumbered at the foot of the ledger.
3. **RULE 9 IS CURRENTLY VIOLATED IN THE TREE, and not by me.** Five unapproved accessories
   (BonkStick, StinkoSock, NoodleBowl, CactinoCrown, CrocodiloWings) and five unapproved auras are in
   `CosmeticData.lua` right now — a `morning_gallery.ps1 -WithPending` run at 10:58–11:03 applied them
   and its `finally` did not take them out. This is the same near-miss the cosmetics tab caught last
   night, recurring. Unapply scripts exist in that tab's scratchpad, **auras first**
   (`unapply_new_auras.py`, then `unapply_new_accessories.py`). Oliver has seen the renders and has
   NOT decided; he is deciding keep-vs-pull. Do not pull them without his word.
4. **#28 disagreement**: the source `.txt` ticks it (11 holes → 0, proven twice); `foliage.md` still
   lists it open, "mine, untouched". One is wrong.
5. Possible collision: the Fable abilities item (A5 / old "#63") has Tier A coded in a private tree and
   touches CompanionService announce/LOS paths. If it lands it may conflict with my `UseAbility` branch.

## SOMETHING THE FLEET SHOULD KNOW: the work is now in git
Four days of landings had never been committed. `fleet/2026-09-22` = commit `1e964ca`, 134 files,
+15,429/−839, pushed to GitHub; `main` untouched at `4582fdc`. A second commit carries a mailbox reply
to Dalton. **The 10:58 commit swept the unapproved cosmetics in** (item 3) — they are in that branch
too. Contributors had been reading a `main` four days behind the tree, which is the likeliest reason
two of their briefs disagreed with the code.

## NEXT STEP, one line
Oliver's keep-or-pull on the ten cosmetics; then a probe on the boons before anyone calls them proven.

## TWO DEFECTS IN MY OWN LANDING, both found after it, both now fixed
1. **A REQUIRE CYCLE THAT WOULD HAVE KILLED BOOTSTRAP.** `CompanionBoons` required `MatchService` at
   the top; `MatchService` → `BotService` → `CompanionService` → `CompanionBoons`. Roblox refuses that
   ("Requested module was required recursively") and Bootstrap dies before the lobby builds. **I did
   not catch this — another tab did**, and lazified the require (backup
   `CompanionBoons.lua.pre-cyclefix`). **All three static gates were green the whole time it was
   there**, which is the point: nothing in verify/balance/static sees a require graph. Re-checked the
   other three requires (MovementService, CombatService, Combatants) by walking the graph — none
   reaches back.
2. **Every trade stripped the health boon from every player.** `CompanionService.Refresh` calls
   `spawnFor`, and `RefreshAll` calls Refresh for EVERY player when a trade completes. My `Apply` began
   with `Clear`, which takes MaxHealth down and clamps Health under the lower ceiling; Apply restored
   the ceiling but must not heal. Net: a health-boon player silently lost the bonus whenever anybody
   traded. Fixed — Apply now no-ops when the same def is already active. Not the exploit direction, and
   the `lastCondition` carry is untouched (my Apply is inside `spawnFor`, before Refresh's re-apply,
   and touches the OWNER's humanoid, never the companion entry). Verified intact: `lastCondition` at 6
   sites, `RefreshAll` routed through `Refresh`.

## SPEC: THE REQUIRE-CYCLE CHECK THE GATES DO NOT HAVE (coordinator's ask, for after the limit lifts)
The hole: a require cycle kills Bootstrap before the lobby builds, and **verify, balance and the static
check are all green while it is there** — none of them walks a require graph. "Three checks green" has
meant "safe to land" all week; for this fault class it means nothing. Build it as a stage in
`lua_static_check.py` so it rides the gate every tab already runs.

What it must do:
1. **Edges are TOP-LEVEL requires only.** `local X = require(Modules:WaitForChild("X"))` at file scope
   is an edge; the same call inside a function body is NOT — a lazy require is the documented fix for a
   cycle, so a checker that counts both flags every fix as the fault it repairs. Distinguishing them is
   the whole difficulty: track brace/`function`…`end` depth, or accept only requires appearing before
   the first `function` at column 0.
2. Resolve the three call shapes in use: `script.Parent:WaitForChild("X")`, `Modules:WaitForChild("X")`,
   `Shared:WaitForChild("X")`.
3. Report every cycle as a path (`A -> B -> C -> A`), not just "a cycle exists" — the path is what tells
   you which edge to lazify.
4. **Two planted faults, both required:** (a) inject a top-level require that closes a real cycle and
   assert it fires; (b) a fixture with that same require moved inside a function, and assert it stays
   clean. Without (b) the check cannot tell a fix from a fault.
5. Print the edge count examined beside the finding count, per the project's own rule that a finding
   count means nothing without a candidate count.

Known-good case to seed it with: `MatchService -> BotService -> CompanionService -> CompanionBoons ->
MatchService`, which is the real cycle that shipped today. The four current edges out of CompanionBoons
(MovementService, CombatService, Combatants top-level; MatchService lazy) were walked by hand and are
clean — that walk is a hand-check the tool should replace.

## THREE LESSONS
1. **Verify the tree, then commit the tree, and check it did not move in between.** I ran the gates at
   ~10:30 and `git add -A` at 10:58 — a gallery was writing `CosmeticData.lua` in that window and I
   committed and pushed ten unapproved cosmetics without noticing. Same shape as "build before you
   probe": the thing you measured is not automatically the thing you shipped.
2. **A prefix length is a silent no-op, not an error.** `string.sub(name, 1, 7) == "JumpF_"` can never
   be true, so every jump factor would have done nothing and every check would still have been green.
   Caught by re-reading my own diff, not by any gate. The static checks cannot see a comparison that
   is merely always false.
3. **A stale ledger is worse than no ledger**, because people quote it. `OLIVER_LIST.md` was four days
   old and half the item range, and in that gap the fleet grew a second, conflicting numbering for
   #59–#64 that nobody noticed because no one document held both.
