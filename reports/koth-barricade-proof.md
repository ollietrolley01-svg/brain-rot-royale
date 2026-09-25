# #114 "popup barricade in the team-mode kit; two objectives on KOTH": a proof on current main

Jacob's branch `task/prove-114`, cut from origin/main **d1e4f73**. Line references are to d1e4f73.
Everything here was run outside Studio (Python + lupa) or read from source. Nothing ran in Roblox. **No game
file and no existing tool was edited.** The new check is `tools/koth_barricade_proof_check.py` with two
world files, all in my branch.

The row, as Oliver gave it (list 2, 09-21): "popup barricade in the team-mode kit; TWO objectives on KOTH".
Commits: 7baed01 (the team kit check), 0a92f91 and 1050d04 (Oliver's 09-25 kit), 7ddb96e and 9ba0a79
(two objectives), b29019c and 2c8b760 (the battleground and its marked capture areas).

## Verdict

- **(a) On main, every team-mode life spawns with a pop-up structure, and it works.** The kit holds 2 of
  ONE random portable defense: the Rot Barricade, the Pop-up Bunker or the Brainrot Fortress (the
  Fortress stacks to 1, so it comes as 1). That's Oliver's own 09-25 change (1050d04, `GameModes.lua:141`).
  So the Rot Barricade itself is in about a third of lives (34 of 90 rolled), and some pop-up structure
  is in all 90. Through the shipped code, every kit use throws the kit, a structure pops up where it
  lands, and the stack goes down by one. Each structure has its full health and its owner, stands after a
  hit short of its health, and collapses and clears away past it.
- **(b) On main, Objective Capture has two objectives, and they capture and score as the file says.**
  If one team stands alone on an objective, it takes it within one 0.25 s tick. The objective stays
  theirs after they leave, and every owned objective scores 1 point a second. If the other side stands
  alone on it, they take it back. If both sides are on it, it's Contested and nothing changes hands.
  Dead and downed bodies don't hold anything. Holding one objective wins at 250 s and holding both wins
  at 125 s, exactly on 250 points. With no captures, the 480 s limit ends the match.
- **The two halves work together.** A kit barricade thrown at an objective's centre is refused and
  dropped back as a pickup. One thrown onto the ring away from the centre builds. Bots get the same kit.
- **No bug in what #114 asked for.** I found one small fault in a fallback path that main barely uses
  (Found, not fixed, 1). Three behaviours are worth Oliver knowing about (notes 2-4).
- **Needs a Studio look:** how the pop-up rise, the health bar, the collapse, the rings, the beams and
  the A/B markers look in a real match. None of that is a number.

`tools/koth_barricade_proof_check.py` on d1e4f73: `koth_barricade_proof_check: OK (0 failures)`,
planted faults **13 of 13 caught**. The same run on the lag/bug sweep (`origin/pc/lag-bug-sweep` cf35aa3):
also OK, 13 of 13.

## 1. How it was measured

Both halves run the shipped modules in lupa, through their real entry points.

**(a) The kit** (`tools/koth_barricade_kit_world.lua`). It reuses `tools/defense_anywhere_check.py`'s
world, `tools/defense_anywhere_world.lua` on `tools/destruct_mocks.lua`: the heightfield terrain, the
exact raycasts, and the real `DefensePlacement` and `DefenseService` already loaded there. It adds the
chain a spawned player goes through:

`GameModes.RollLoadout` → `ModeTeams.GrantLoadout` (the shipped function, cut out of `ModeTeams.lua:1654-1686`,
as `team_kit_check.py` does) → the **real** `WeaponService` inventory (`GiveConsumable`, `Equip`) →
`WeaponService.StartUse` (`:2015`, the click) → `applyItem`'s defense branch (`:1982-1983`) →
`WeaponService.DefenseEffect`, which is DefenseService's hook (`DefenseService.lua:682`) → `throwKit`
(`:586`) → `throwStructure` (`:570`) → the kit lands (`landKit`, `:539`) → `Deploy` (`:487`) → the
structure stands → `CombatService.DamageStructure` and `DamageStructuresInRadius`, DefenseService's hooks
(`:687`) → `Damage` (`:385`) → `collapse` (`:299`).

One seam, stated: DefenseService puts `DefenseEffect` on whatever WeaponService it requires. In the game
that's the one WeaponService. Here it's the defense world's stub, so the check copies the hook
unchanged onto the real WeaponService.

**(b) The objectives** (`tools/koth_barricade_capture_world.lua`). This runs the real `GameMode.lua`
match driver: the 0.25 s tick at `:765`, the once-a-second score at `:772`, `addScore` and the target at
`:162-170`, and the deadline at `:784`. It also runs the real `ModeKingOfTheHill.lua` and the shipped mode
numbers from `GameModes.lua`, `ObjectiveZone.lua` and `MatchConfig.lua`: radius 28, height 22,
6 below, target 250, limit 480. `task.wait` is a scheduler the check steps through time, so the loops
that run are the shipped ones. Players and bots are tables with a root position that the scenes move.

## 2. (a) The barricade in the kit

| What | Measured |
|---|---|
| Lives rolled through `GrantLoadout` into the real inventory | 90 |
| Lives with exactly one pop-up structure kind | **90 of 90** |
| Which kind | Rot Barricade 34, Pop-up Bunker 28, Brainrot Fortress 28 |
| Count carried | 2 each, Fortress 1 (its stack), in all 90 |
| Tagged `issued` (a death doesn't drop it, #124) | 90 of 90 |

**Using it:** for each kind, I held the kit's slot and clicked through the real `StartUse` until the stack
was spent, plus one more click.

| Kind | Kit | Clicks that threw | Structures standing | Stack left | The click after it's spent |
|---|---|---|---|---|---|
| Rot Barricade | x2 | 2 | 2 | 0 | threw nothing |
| Pop-up Bunker | x2 | 2 | 2 | 0 | threw nothing |
| Brainrot Fortress | x1 | 1 | 1 | 0 | threw nothing |

**Working:** each of the 5 structures had health = max health = 250, 1,250 or 2,500 (`DefenseService.lua:249-251`),
was owned by the thrower, and had parts that collide and can be hit. I hit each one for 40% of its
health through the CombatService hook. It dealt exactly that, the health read 60%, and the structure
stood. Then a blast through `DamageStructuresInRadius` (the path grenades, rockets and mines take)
finished it. It stopped being a structure, no part still collided, and it was gone 4 s later
(`COLLAPSE_LINGER` 3.5). **5 of 5 collapsed and cleared.**

**The kit on a KOTH objective.** The real `ModeKingOfTheHill.Start` builds its two objectives in the world.
Each objective model carries `HillX`, `HillZ` and `HillRadius` (`ModeKingOfTheHill.lua:192-194`), and
`DefensePlacement` reads them (`DefensePlacement.lua:602-607`). I threw a kit barricade at four spots,
through the full chain:

| Thrown at | Result |
|---|---|
| Objective A's centre | refused, "Not on the objective's centre. The kit's on the ground where it landed.", kit dropped as a pickup |
| Objective B's centre | refused, same |
| A's ring, 0.8 of its radius out | built |
| B's ring, 0.6 of its radius out | built |

The same four spots through `Deploy` (a bot's path, no throw) gave the same answers. The centre rule is
`ObjectiveCentreShare` 0.35 of the radius, so 9.8 studs of the 28 (`DefensePlacement.lua:278`). The rest
of the ring can be walled.

**Bots.** GameMode hands BotService a `SpawnLoadout` (`GameMode.lua:748-753`) that rolls the same kit. Run
60 times, **60 of 60** bot kits carried exactly one pop-up structure, and the bot's shield was set to 100.
From source: BotService counts all three structure ids as its defense (`BotService.lua:6342-6344`), with
a cap of 3 (`:2395`), which covers the kit's 2. See note 3 for what a bot then builds.

## 3. (b) Two objectives, capture and score

| Scene | Measured |
|---|---|
| Objectives built with the battleground standing | **2**, at the battleground's two points, floor heights kept |
| Team 1 alone on A for one tick | A is team 1's |
| t=10 s, A held | **10-0** |
| t=20 s, team 1 walked off at t=10 | A still team 1's, **20-0** (scores with nobody on it) |
| Team 2 alone on A | A is team 2's |
| Both sides on A for 5 s | owner stays team 2, status Contested; team 1 scored 0 on it, team 2 scored 5 |
| Team 2's body dead on A, team 1 alive on it | team 1 takes it (the dead don't count) |
| Team 1 downed on A, team 2 alive on it | team 2 takes it (the downed don't contest) |
| Ring edge: 27.5 in / 28.5 out / a diagonal at 27.5 / 23 above / 7 below | 5 of 5 answered as ObjectiveZone says |
| Team 1 holds both | 20 in 10 s; **finishes once at t=125.0 s, 250-0** |
| Team 1 holds A only | 10 in 10 s; **finishes once at t=250.0 s, 250-0** |
| Nobody captures | finishes once at t=480.0 s, 0-0 |

Nothing scored after the win: I ran 20 s past it and the score and the single finish didn't change.

The battleground's two points are fixed in the check: (37, 10.8, -21) and (-47, 10.3, 5), as printed
by `tools/team_battleground_modeteams_check.py`. That check proves KOTH takes the battleground's
objectives over 4 seeds, places and headings (21 of 21 plants on d1e4f73, rerun for this report). This
one proves what happens on them.

**The open-arena fallback** (no battleground standing; `ModeKingOfTheHill.lua:267-318`), 20 seeds each,
with no landmarks or drop spots:

| Arena radius | Seeds with 2 objectives | Gap between them |
|---|---|---|
| 600 | 20 of 20 | 210 every time (under `SITE_GAP` 220) |
| 700 | 20 of 20 | 245 |
| 875 | 20 of 20 | 306 |

See Found, not fixed, 1.

## 4. The planted faults (13 of 13 caught)

Each fault is planted in the shipped source on every run and must make the check fail. Each one targets
something the code must always do, not today's state:

| Planted | Caught by |
|---|---|
| the defense pool dropped from the kit (`kinds = 0`) | life 1 carries 0 pop-up structure kinds |
| a click on the kit spends it and throws nothing | "spent (1 left) but 0 built" |
| a structure never collapses | "shot out but still standing (25 parts still collide)" |
| the objective-centre rule gone | a barricade built on A's centre |
| KOTH stops writing `HillRadius` on its objectives | a barricade built on A's centre |
| a bot no longer counts the Pop-up Bunker | structures the kit rolls that a bot doesn't count |
| only objective A built | 1 objective, want 2 |
| an objective lost when its holder steps off | A's owner nil after team 1 walked off |
| a contest hands the objective to team 1 | owner 1, want 2 |
| scoring every tick instead of every second | 40-0 after 10 s |
| only objective A scores | holding both: 10 in 10 s, want 20 |
| the score target ignored | the match finished 0 times |
| dead bodies capture | team 2's dead body kept A |

**Candidates examined:** 90 player lives and 60 bot kits, 5 kit uses plus 3 clicks with the stack spent,
5 structures worn down, 4 KOTH throws plus 4 Deploys, 26 capture checks across 10 matches, 60 fallback
seeds on 3 arena sizes, and 13 plants.

## 5. Which tree

Everything above is **on main d1e4f73**. I ran the same check against `origin/pc/lag-bug-sweep` (cf35aa3,
not merged): **OK, 13 of 13**. The sweep changes one thing here. `ObjectiveZone.Contains` counts a body
up to 30 studs below the centre instead of 6 (`DigDepth` 24), so a crater dug into an objective doesn't
drop its holders. The check reads the lower edge from ObjectiveZone, so it holds on both trees. On
main, a holder more than 6 studs down a crater stops counting. The sweep fixes that. Its merge is
Oliver's call.

## 6. What this does NOT prove

- **How it looks.** The pop-up rise (0.6 s tween), the health bar, the battered darkening at half
  health, the collapse, the thrown kit's flight, the KOTH rings, beams, A/B letters and their team colours.
  Each needs a render or a playtest on Oliver's machine. `tools/defense_anywhere_gallery.lua` renders the
  structures, and `tools/team_battleground_gallery.lua` renders the battleground. Neither shows a live
  Objective Capture match with its rings and beams. A Play-mode KOTH match is the look test.
- **A real bullet finding the wall.** Damage entered at CombatService's hook, which is where
  `CombatService.lua:909-911` sends a hit on a structure. The ray that finds the wall wasn't run. Nor
  was a real player or bot walking onto an objective, or anything a client draws.
- **Real Roblox**: physics, terrain voxels (a heightfield stands in), the network, and TeamBattleground
  building the two points (taken from the check that proves it).
- **Whether it feels right**: 125 s to win holding both, a contested objective still scoring for its
  owner, and walls on the ring. Those are Oliver's to judge.

## Found, not fixed (for the build machine; nothing here was edited)

1. **The open-arena fallback puts the objectives 210 apart on the smallest arena, and ignores its own
   rules to do it** (measured). `ModeKingOfTheHill.lua:305-311`: once the arena's centre is taken, it
   tries random points 0.35 × arena from the centre. At arena 600, that's 210. `usable()` refuses anything
   nearer than `SITE_GAP` 220 (`:272`), so all 20 tries fail and try 21 accepts the next point anyway,
   `usable` or not. That means no gap check and no base-fairness check (`:276-285`). 600 is the arena's
   floor (`ModeTeams.lua:236`, radius × 0.66 clamped 600-875), so this is every map with radius 909 or
   less. **Low impact:** it runs only when the battleground didn't build (`ModeTeams.lua:604-609`) and no
   landmark or drop spot passed. In a normal team match the battleground's objectives are used.
2. **A contested objective keeps scoring for its owner** (measured: team 2 scored 5 in 5 s contested).
   That matches the file's own rule, "nothing changes hands" (`ModeKingOfTheHill.lua:5-7`). If Oliver
   expects a contest to stop the points, that's a design change.
3. **A bot always builds a Rot Barricade, whatever its kit rolled** (from source).
   `BotService.lua:6342-6344` turns a Bunker or Fortress in the kit into generic defense charges, and
   `placeBarricade` deploys `"RotBarricade"` (`:2495`). The comment says so on purpose. The result is that
   a bot with a Fortress kit puts up two 250-health walls where a player gets one 2,500-health fort. A
   bot's Fortress is also 2 charges against a player's 1, because the stack cap is applied in
   `GrantLoadout` (`ModeTeams.lua:1666`) and not on the bot's path. Oliver's call whether bots should use
   the real structure.
4. **The Rot Barricade itself is only in about a third of kits** (34 of 90). That follows from Oliver's
   09-25 "make it only 2 of one random type of portable defense" (1050d04). If the row's "popup
   barricade" meant the barricade every life, the row and the kit now disagree, and it's his call which
   one stands.
