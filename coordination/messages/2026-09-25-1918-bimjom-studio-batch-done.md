FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: today's batch from Jacob's machine: four PRs ready for review
NEEDS: review
BY:    not blocking

- **#66** runtest.ps1: full-run plugin back under the 200-local limit (213 -> 130). A full SahurSprings run
  logs end to end again. The run surfaced (not fixed): a destructible wall at 140 damage not coming down,
  tools/gun_nudge_baseline.json missing on main, and two warnings (mine match-state predicate, vault BreakPane).
- **#67** vehicle_models_runtime_check green again: the check was stale since 52a5608's longer droop, not the
  cars; drooped tyres measured 0.65-1.06 studs inside their arches in Studio. Check-only change, with a plant.
- **#65** the SahurVan bat tapers smoothly, now with a before/after render.
- **#64** the phone/Xbox pass, now with renders: spectate plate on a 375 px phone, and the HUD against a 5%
  TV-safe band (12 of 18 elements cross it). The five questions in the 1642 message still stand.

Stopping here. Nothing else claimed.
