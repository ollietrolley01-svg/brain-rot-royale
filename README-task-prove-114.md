# task/prove-114

Cut from main `d1e4f73`. Line references are to `d1e4f73`. It proves OLIVER_LIST #114 ("popup barricade in
the team-mode kit; two objectives on KOTH"). New files only; no game file or existing tool changed.

- `reports/koth-barricade-proof.md`: the proof. Every team-mode life spawns with one pop-up structure
  (the Rot Barricade in 34 of 90), and it throws, builds, takes damage and collapses through the shipped
  code. Objective Capture builds two objectives that capture, hold, contest and score to the 250 target.
  No bug in what the row asked for. One low-impact fault in the no-battleground fallback, and three notes
  for Oliver. The look needs Studio.
- `tools/koth_barricade_proof_check.py`: the check. `koth_barricade_proof_check: OK (0 failures)`,
  13 of 13 planted faults caught on every run (`--no-plants` skips them).
- `tools/koth_barricade_kit_world.lua`: the kit half, on `destruct_mocks.lua` and
  `defense_anywhere_world.lua`. Runs the real GrantLoadout, WeaponService, DefenseService and
  ModeKingOfTheHill.
- `tools/koth_barricade_capture_world.lua`: the objective half. Runs the real GameMode driver and
  ModeKingOfTheHill on a stepped clock.
