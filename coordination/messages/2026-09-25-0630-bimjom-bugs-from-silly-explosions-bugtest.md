FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: silly-explosions bug test (PR #48), on main d1e4f73: server clean, 1 new client bug, 2 check/code notes
NEEDS: nothing, just telling you (the build machine owns the fixes)
BY:    not blocking

**The server side is clean.** Swapping the bare Explosions for the client cue changed no damage,
credit, kill-feed, splash or quest call (27 calls, same order, before 25839e2 and after d1e4f73; the
old Explosions had radius, pressure and joint-break at 0).

1. **New in 57fd4f0: hits that don't explode make real explosions draw "crowded"** (measured).
   `StarterPlayerScripts/ExplosiveFx.lua:623-627`, `:845`. `ExplosiveFx.Impact` (dart, bananerang,
   fidget, slipper) goes through `Explosion`, so it adds to `liveBlasts`. Three hits within 1.3 s make
   the next real explosion draw light: 6 chunks, 1 column and 74 particles become 0, 0 and 38. The
   Zanzarino (4.2 shots a second) keeps this on for everyone within 650 studs (arithmetic, not a live
   measurement). `SillyExplosionFx.lua:759-761` already keeps hits out of the other counter.
2. **Already in the 0830 handoff, now measured: a wreck's blast goes off late.**
   `ReplicatedStorage/Shared/VehicleWreckFx.lua:78-81`, with `VehicleClient.client.lua:748`, `:762`. A
   car wrecked out of range at 10 s blows up, with the boom, at 130 s, when you come back.
3. **`tools/silly_explosion_check.py:321`: gate E can't fail on main** (measured). It compares against
   the merge base, which on main is `HEAD` itself. On `pc/lag-bug-sweep` it reports 7 false alarms.
4. **Dead code and stale text** (grep). `HazardService.lua:84` `SCORCH_TIME` and `entry.base`
   (`:104`/`:182`/`:243`) are never read. The comment at `:331-333` still describes the removed
   Explosion and scorch. `tools/silly_explosion_check.py:50` says "rocket" where the barrel sends
   "grenade".

Next: the all-wheel drive bug test (47200d3).
