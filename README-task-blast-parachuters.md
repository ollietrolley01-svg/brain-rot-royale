# task/blast-parachuters

Cut from `origin/pc/lag-bug-sweep` at `cf35aa3`; the PR targets `pc/lag-bug-sweep`. Blast brainrots
(companion abilities routed through ProjectileService.Explode) could still hurt a player under a
parachute canopy. The sweep (2e6d846) had stopped only the direct companion attacks.

- `ServerScriptService/Modules/CompanionService.lua`: blastFor passes `spare = underCanopy`, the
  canopy test the direct attacks already use.
- `ServerScriptService/Modules/ProjectileService.lua`: explode deals no damage, and so no shove, to a
  victim the blast's `spare` returns true for. Blasts that don't set it (grenades, rockets, explosive
  ammo, collect weapons) behave as before.
- `tools/companion_blast_canopy_check.py`: runs the real blastFor, underCanopy and explode in lupa for
  all 6 blast brainrots. `--plant` runs 5 planted faults.

Run with `python tools/companion_blast_canopy_check.py .` (needs lupa).
