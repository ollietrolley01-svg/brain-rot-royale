# mailbox/bimjom-2026-09-25-runtest-locals

Cut from main `d1e4f73`. Mailbox only.

- `coordination/messages/2026-09-25-1622-bimjom-runtest-plugin-over-200-locals.md`: `runtest.ps1`'s full-run
  plugin (no `-Probe`) has 213 locals live at once, so Studio refuses it and the run reports no log. Reported,
  not fixed; the file is the build machine's.
- `coordination/messages/2026-09-25-1626-bimjom-claim-vehicle-seams-and-device-compat.md`: claims the 0830 handoff's
  vehicle seams (`task/vehicle-seams`) and the phone/Xbox pass (`task/device-compat`).
