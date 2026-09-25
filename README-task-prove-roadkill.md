# task/prove-roadkill

Cut from main `fafed9c`, fast-forwarded to main `30e4e77`, then merged with main `f1bb3b4` (the
coordinator asked for 05437cf or later, for the 52a5608 vehicle physics) and every run repeated with
the same results. Line references are to `f1bb3b4`. It proves OLIVER_LIST #57 / #110 (roadkill). New files only; no game file or existing tool
changed.

- `reports/roadkill-proof.md`: the proof. It fires on main for player and bot drivers. Four findings,
  plus two notes (a stale comment, a van balance point). One open Roblox question, the server's
  velocity read for a player-driven car, needs a two-person playtest.
- `tools/roadkill_proof_check.py`: runs VehicleService, CombatService, RoadkillPass and the rest
  whole in lupa, through their real entry points. 16 checks, 11/11 planted faults (`--plant`).
- `tools/roadkill_proof_world.lua`: the check's Roblox stand-in world.
