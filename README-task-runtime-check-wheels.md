# task/runtime-check-wheels

Cut from main at d1e4f73.

`tools/vehicle_models_runtime_check.py` was red on main: 10 faults, "Wheel_XX comes away from what
carries it at steer +N deg, suspension extended" on every wheel of the SahurVan and TartarugaScout and
the TralalaGT's two front wheels. Rear wheels failing shows steer isn't the cause. The failing pose is
full droop.

**What turned it red:** 52a5608 ("Rough ground"), which raised `travelDown` (1.0 TralalaGT, 1.15
SahurVan, 1.35 TartarugaScout, up from 0.3-0.65) and added `rideLift`. The check run against 52a5608's
parent gives 0 faults; against 52a5608 it gives these 10. The revert 9c44f4b and the merge a7a6ae8
(mailbox files only) don't touch it. At 52a5608 itself the check couldn't even run (its Lua shim had
no `table.find`, which `belly()` calls), so the red only showed up once d51c083 fixed the shim.

**Why the check was wrong, not the cars:** the check requires a moving assembly to keep touching
(within 0.06) the parts it touched at rest. A car wheel's rest contacts are the upper arch panels
beside the tyre. That held while droop was under ~0.5 stud. With 1.0-1.35 of droop the tyre hangs
below those panels, but it's still in its arch: the tyre top sits 0.65 (van), 0.89 (Scout) and 1.06
(GT) studs above the bottom of the arch's lip/well liner, and the renders show it framed by the arch
with the dark well behind.

**Change (check only, no game code):**
- `tools/vehicle_models_runtime_check.py`: in a pose that drops the wheels, a car wheel that lost its
  rest contacts still counts as carried if its tyre overlaps its own corner's arch (`ArchPanel<c>N`,
  `Lip<c>N`, `Well<c>`) seen from the side. The tyre is slid along the chassis X onto each arch part
  and tested there. Compressed poses, bikes and every other assembly keep the strict test. New plant:
  van `travelDown` 2.0 drops the tyre top below the lip and well, and it is caught.
- `tools/wheel_droop_gallery.lua`: close renders of the front-left wheel of all three cars at ride
  height and at full droop on full lock, plus the planted 2.0 droop on the van, with measured
  tyre-top and arch-bottom heights.

**How far it stretches:** extra droop before the rule fires: van 1.75 passes, 1.95 fails; Scout 1.75
passes, 1.95 fails; GT still passes at 2.0 (its well liner reaches down to 0.64).

**Evidence:** runtime check OK (0 faults, 9/9 plants caught); parked_car, vehicle_collision,
vehicle_aim, vehicle_cover, vehicle_stability_sim `--source` and vehicle_models_axis_check green;
verify/balance/lua_static clean.
