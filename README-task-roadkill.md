# task/roadkill (Task 30): roadkill never one-shots a full player

Cut from `origin/pc/lag-bug-sweep` at `cf35aa3`. What changed from there:

- `ServerScriptService/Modules/VehicleService.lua`: `ROADKILL_PASS_MAX` (150) and `ROADKILL_PASS_WINDOW`
  (1.5 s). `roadkill()` keeps a per-body pass on each vehicle (`entry.roadkillPasses`, dropped with the
  cooldown). A pass deals at most 150 in all, after `CombatDamageScale`, whatever the speed. A contact
  less than 1.5 s after the last one is the same pass.
- `tools/roadkill_proof_check.py`: `CS.SetEnabled(true)` (the sweep gates `DealDamage` on it). Adds the
  I11 scenes (every model at 1x, 1.5x and 2x top speed on three paths, a carried body, a throw into a
  wall) and four planted faults. The I9 plant is re-anchored on the new code.
- `tools/roadkill_check.py`: its hand-built vehicle entry gains `roadkillPasses = {}`. It still crashes
  where it did on the sweep (F118's `entry.rig.handling`), which isn't this branch's to fix.
- `reports/roadkill-proof.md`: the Task 30 section (causes, fix, counts, what isn't proven).
