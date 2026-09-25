FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: all-wheel drive bug test (PR #49), on main d1e4f73: the red bot_driving_sim comes from the AWD split, plus 4 more
NEEDS: nothing, just telling you (the build machine owns the fixes; item 3 may be Oliver's call)
BY:    not blocking

The AWD split's own rules hold, over 115,248 wheel-load patterns. The 9c44f4b revert left AWD whole:
the three vehicle files are byte-identical to 47200d3.

1. **The known red `bot_driving_sim` is caused by 47200d3's centre split** (measured, reproduced twice).
   `ReplicatedStorage/Shared/VehicleDynamics.lua:556-569` (`DriveSplit`, used at `:743`, `:787`). On main
   with only the pre-AWD `VehicleDynamics.lua` put back, `bot driving sim: OK`. As main is,
   `PROBLEM lap CrocodiloRanger: 1 impacts (worst 5.4 studs/s)`: the lap takes 70.3 s with 2 recoveries,
   against 61.3 s with 0. Putting back only the old load-share split also passes; removing only the
   one-wheel cap stays red. The BotNav fix d400668 was verified without AWD.
2. **`vehicle_models_runtime_check` has been red on main since 52a5608 (ride lift)**, and STATUS doesn't
   list it (measured by bisecting). The SahurVan, TartarugaScout and TralalaGT wheels "come away" at full
   steer. Those are the three cars with `rideLift = 0.7` (`VehicleDynamics.lua:93`, `:100`, `:112`), but
   that link is reasoning.
3. **The one-wheel cap throws away the extra drive instead of passing it on** (measured, pure function).
   `VehicleDynamics.lua:744`, `:788`. With the rear in the air and the fronts at 70/30, 80% of the drive
   is delivered. With one front wheel down, 50%. With one wheel per axle, 90%. Before AWD all three were
   100%. It didn't happen on smooth ground; rocks are untested. Oliver's call if it's intended.
4. **The rear gets its load share plus 10% whenever the front carries more than half** (measured).
   `VehicleDynamics.lua:568`. An axle with 5% of the load gets 15% of the drive, and the front's share
   jumps from 0.9 to 1.0 as the last rear wheel lifts. The extra is wasted at the grip limit rather than
   flinging the car (reasoning).
5. **Not from AWD: the SahurVan sits 2.2° nose-up and drags** (measured in lupa; the cause is reasoning).
   Every spring carries an equal share of the weight (`VehicleDynamics.lua:669`, `:582`), and the van's
   centre sits toward the rear (`VehicleModels.lua:1633`). The springs push along the body's up (`:823`),
   so part of that push points backward. The van tops out at 63.8 of its 72 and rolls backward at 15%
   throttle, which is the bots' corner throttle. The Carrier tops out at 57.9 of 62. Studio's own
   BEFORE table (11.22 s to 95% of top, against 3.2-4.4 s for the other cars) agrees.

Note: the 0830 handoff was committed at 04:15, before the 04:28 revert. Its vehicle item names
`vehicle_visuals_check.py`, the visuals gallery and suspension_standard, none of which is on main.

Next: the +25% time-to-kill bug test (25839e2, 0.736), then #51.
