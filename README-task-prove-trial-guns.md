# task/prove-trial-guns

Cut from main `f1bb3b4`, then merged with main `1c70de8` and run again with the same results. Line
references are to `1c70de8`. It proves OLIVER_LIST #117 (lobby trial guns change every pickup, commit
e666c61). New files only; no game file or existing tool changed.

- `reports/trial-guns-proof.md`: the proof. Fixed on main: a second podium gun adds to the hotbar, and
  range guns never reach a match or saved data. Two findings: retaking the gun in your hand mid-reload
  leaves the reload running, and so the Studio range probe (`tools/range_probe.server.lua:85-92`) should
  now fail. Plus three notes.
- `tools/trial_guns_proof_check.py`: runs RangeService and WeaponService whole in lupa, fires the real
  podium prompt handlers cut from LobbyService, and runs the real lobby respawn path cut from
  MatchService. 51 checks, 15/15 planted faults (`--plant`).
- `tools/trial_guns_proof_world.lua`: the check's Roblox stand-in world and its scenes.
