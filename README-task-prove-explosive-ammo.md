# task/prove-explosive-ammo

An independent proof of OLIVER_LIST #122 (explosive ammo, built in 6ef6a52) against main `fafed9c`. The
branch was cut from main `ac22e5e` and fast-forwarded to `fafed9c`. It adds new files only; no game
file or existing tool is changed.

- `reports/explosive-ammo-proof.md`: the findings. Every explosive gun (6 hand guns, 4 vehicle or
  emplacement guns, out of 77 examined) reaches the blast when a player fires it. Two problems: a bot's
  Golden Sahur Cannon never explodes, and `tools/explosive_ammo_check.py` has crashed on main since d370e62.
- `tools/explosive_dispatch_check.py`: loads the real CombatService, ProjectileService and VehicleWeapons
  in lupa and fires every flagged gun through its real entry point. `--plant` runs its 13 planted faults.
- `tools/explosive_dispatch_world.lua`: the stand-in Roblox world it runs them in.

Run with `python tools/explosive_dispatch_check.py .` (needs lupa).
