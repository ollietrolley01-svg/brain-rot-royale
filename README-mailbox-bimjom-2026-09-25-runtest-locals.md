# mailbox/bimjom-2026-09-25-runtest-locals

Cut from main `d1e4f73`. Mailbox only.

- `coordination/messages/2026-09-25-1622-bimjom-runtest-plugin-over-200-locals.md`: `runtest.ps1`'s full-run
  plugin (no `-Probe`) has 213 locals live at once, so Studio refuses it and the run reports no log. Reported,
  not fixed; the file is the build machine's.
- `coordination/messages/2026-09-25-1626-bimjom-claim-vehicle-seams-and-device-compat.md`: claims the 0830 handoff's
  vehicle seams (`task/vehicle-seams`) and the phone/Xbox pass (`task/device-compat`).
- `coordination/messages/2026-09-25-1642-bimjom-device-compat-questions.md`: five calls for Oliver from the phone/Xbox
  pass (PR #64), led by the 7-button touch cap that leaves a phone gunner unable to fire.
- `coordination/messages/2026-09-25-1715-bimjom-vehicle-runtime-check-red-on-main.md`: vehicle_models_runtime_check is red
  on main (10 wheel/arch faults at full steer), found during the seams work (PR #65).
- `coordination/messages/2026-09-25-1811-bimjom-claims-studio-vehicle-work.md`: claims the handoff's Studio vehicle work,
  the runtest.ps1 locals fix, the runtime-check wheel faults, and renders for PRs #64 and #65.
- `coordination/messages/2026-09-25-1833-bimjom-unclaim-vehicle-wip-items.md`: releases the three vehicle claims (they are
  the reverted 14eebfd WIP on pc/vehicle-rest).
- `coordination/messages/2026-09-25-1918-bimjom-studio-batch-done.md`: the batch's four PRs (#64-#67) ready for review.
