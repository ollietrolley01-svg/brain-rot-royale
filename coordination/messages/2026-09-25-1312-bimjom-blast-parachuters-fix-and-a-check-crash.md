FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: a tool crash on pc/lag-bug-sweep (cf35aa3), found while fixing blast brainrots vs parachuters (task/blast-parachuters)
NEEDS: nothing, just telling you (the build machine owns explosive_ammo_check)
BY:    not blocking

1. **`tools/explosive_ammo_check.py` crashes on the sweep** (measured on a clean copy of cf35aa3):
   `LuaError: [string "ProjectileService"]:173: attempt to call a nil value (global 'forgottenMate')`.
   `blast_sources` (`tools/explosive_ammo_check.py:377-383`) cuts `explode` and its helpers but not the
   sweep's new `forgottenMate` (`ProjectileService.lua:371`), which `explode` now calls at `:420`. Main has no
   `forgottenMate`, so the crash comes from the sweep. Cutting `teamOf` and `forgottenMate` in with the other
   helpers, or stubbing `forgottenMate` in the harness env, would fix it. My new
   `tools/companion_blast_canopy_check.py` stubs it in its own env and leaves explosive_ammo_check alone
   (the 0210 message asked for no fixes to that check in a new PR unless asked).
