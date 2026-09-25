# task/prove-bot-lag

A proof of OLIVER_LIST #113, #126, #131 and #99 (bot lag, and movement that looks low-fps) against main `f1bb3b4`, rerun after merging main `68bb8de` with the same results,
the commit this branch was cut from. It adds new files only; no game file or existing tool is changed.

- `reports/bot-lag-proof.md`: the verdict, the findings ranked, the numbers, and what is not proven.
- `tools/bot_lag_proof_check.py`: runs the whole of `BotService.lua` and `BotNav.lua` in lupa through
  `BotService.Start`'s own think loop at 60 Hz, with 15/30/50 bots spread, packed and in teams. It counts thinks,
  rays (and who cast them), route starts, LOD deferrals, physics re-claims and Lua work per frame, and checks
  11 invariants. `--plant` runs 11 planted faults; `--rev REV` runs another revision's BotService/BotNav.
- `tools/bot_lag_proof_world.lua`: the stand-in world it adds to `tools/bot_archetype_sim.py`'s (the real BotNav,
  a PathfindingService, a raycast with normals and a floor, Heartbeat and a thread scheduler, the counters).
- `tools/bot_lag_worst_tick_probe.lua`: a Studio probe, never run, that breaks main's worst think slices into their
  parts and measures bots stopping and mis-animating between thinks. Needs the coordinator's Studio.

Run with `python tools/bot_lag_proof_check.py .` (needs lupa).
