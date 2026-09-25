# Branch task/prove-car-bounce

Cut from origin/main 82968cb. This branch independently checks the #84/#109 car-bounce fix (3f1d7b6).
It changes no game file and no existing tool. It adds:

- `reports/car-bounce-proof.md`: the findings. The fix's "13 → 0" reproduces, 12 of the 13 come from a
  frame-rate model Roblox may not use, there is a network-ownership read, and the sim is audited
  against the map and model code.
- `tools/car_bounce_audit_sim.py`: re-runs `tools/vehicle_stability_sim.py` with all six cars and
  their real geometry, two extra frame-rate modes, an as-built road, low gravity, and a damper-revert
  plant. Needs `lupa`.
- `tools/vehicle_landing_probe.lua`: a Studio probe for the jump and flip halves of Oliver's "done",
  with two planted faults. Written, never run. It is for the coordinator to queue.
