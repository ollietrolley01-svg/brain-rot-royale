FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: #114 proof (PR #54, task/prove-114, on main d1e4f73): the kit's pop-up structure and the two objectives both work; 1 low-impact fallback bug, 3 calls for Oliver
NEEDS: nothing, just telling you (the build machine owns the fix; items 2-4 are Oliver's calls)
BY:    not blocking (nothing here blocks a playtest)

The row holds on main. Every team-mode life spawns with one pop-up structure (2 of it, or 1 Fortress).
It throws, builds, takes damage and collapses through the shipped WeaponService and DefenseService.
Objective Capture builds two objectives that capture, hold, contest and score to 250: 125 s holding
both, 250 s holding one. A kit barricade is refused on an objective's centre and builds on its ring.
The check is `tools/koth_barricade_proof_check.py`: OK, 13/13 plants, and the same on
pc/lag-bug-sweep cf35aa3. What's left:

1. **The open-arena fallback puts the two objectives 210 apart and skips its own rules** (measured, 20/20
   seeds at arena 600). `ModeKingOfTheHill.lua:305-311` tries points 0.35 × arena from the centre site,
   which is 210 at arena 600, under `SITE_GAP` 220 (`:272`). All 20 tries fail, and try 21 is accepted
   with no gap or base-fairness check (`:276-285`). Arena 600 is every map with radius 909 or less
   (`ModeTeams.lua:236`). Low impact: it only runs when the battleground failed to build
   (`ModeTeams.lua:604-609`) and no landmark or drop spot passed.
2. **Oliver's call: a contested objective keeps scoring for its owner** (measured, 5 points in 5 s).
   That's the file's own rule (`ModeKingOfTheHill.lua:5-7`), listed here in case he expects a contest to
   stop the points.
3. **Oliver's call: a bot always builds a Rot Barricade, whatever structure its kit rolled** (from
   source). `BotService.lua:6342-6344` turns a Bunker or Fortress into generic charges, and `:2495`
   deploys `"RotBarricade"`. A bot with a Fortress kit also gets 2 charges where a player gets 1, because
   the stack cap is only in `GrantLoadout` (`ModeTeams.lua:1666`).
4. **Oliver's call: the Rot Barricade itself is in about a third of kits** (34/90), since the 09-25 "2 of
   one random type of portable defense" (1050d04). If the row meant the barricade every life, it no
   longer matches the kit.

Needs a look on Oliver's machine: the pop-up, the collapse, and the rings, beams and A/B markers in a
Play-mode Objective Capture match. Nothing I ran draws anything.
