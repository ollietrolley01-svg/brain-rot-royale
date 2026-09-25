# Branch `task/false-empty-reload`

Cut from `origin/main` at `d1e4f73`. Proof only: no game file changes.

## What changed from d1e4f73
- **New:** `tools/auto_reload_check.py`. It runs the real CombatClient auto-reload path (`roundTrip`, `roundsInHand`,
  `tryFire` and the loadout push lines) in lupa against a server model pinned to WeaponService's text. It checks
  five invariants: no false-empty reload, one ask per empty magazine, one ask per 0.6 s window, nothing asks with
  AutoReload off, and the local round count recovers. It carries 6 planted faults. `--client-rev <rev>` runs the
  same checks on another revision's client. b254eac is the control and fails I1.

## Why
The coordinator's 0830 handoff listed "CombatClient:755: a false-empty auto-reload" as open. The fault was on
`pc/hitreg-fixes` b254eac. dd6cfb0 fixed it, and 3c0a18a merged that fix into main, so this branch proves the fix
instead of making it again.
