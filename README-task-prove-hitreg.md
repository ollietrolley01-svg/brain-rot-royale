# task/prove-hitreg

An independent proof of #97 (hit registration) against main `7ddeb4a`, re-run on `ac22e5e`. The branch was cut from
82968cb and fast-forwarded. It adds new files only; no game file or existing tool is changed.

- `reports/hitreg-proof.md`: the findings. Both original faults are fixed on main together (1e964ca).
  The rewind's proof reproduces. The report also covers four gaps (F1-F4), the probe's readiness, and
  what is not proven.
- `tools/hitreg_firerate_sim.py`: runs the real client and server fire gates from 741042c, 1e964ca and
  main in lupa. Counts shots sent against shots accepted per fire rate at 30/60/144/240 fps, and phantom
  shots at the end of a magazine. `--plant` runs its 4 planted faults.
- `tools/hitreg_rewind_extra_plants.py`: 10 more planted faults against `hitreg_rewind_check.py`, plus a
  harness variant with a strafing, turning victim.

Run both with `python tools/<name>.py .` (needs lupa).
