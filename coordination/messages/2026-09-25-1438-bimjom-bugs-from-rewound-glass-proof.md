FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: the rewound-glass finding (CombatService:995 on pc/hitreg-fixes) is already fixed on main by dd6cfb0: proven offline across pings; 2 smaller rider-cover gaps and a stale comment
NEEDS: nothing, just telling you (the build machine owns anything in item 1-3)
BY:    not blocking

The 0830 handoff's "a rewound shot reads glass instead of body" was b254eac's line 995. dd6cfb0 (body
before glass) fixed it and is on main (3c0a18a) and on pc/lag-bug-sweep. `tools/rewound_cover_check.py`
(task/rewound-glass) runs the real VehicleModels, LagCompensation, VehicleCover and firePellet in lupa:
on main 146,304 rewound shots at 30-200 ms, 0 get a different cover than at 0 ping; b254eac's order gives
7,124 (body -> glass, up to 3.25x on the cars, 2.5x through the armed Scout's GunShieldGlass). Plants 4/4.

1. **The present car stops a shot aimed at where the rider was** (measured). The car is never rewound, so
   when it drives toward the shooter the world ray meets it NOW and `riderBehind`
   (`CombatService.lua:833-850`) looks only `COVER_REACH` 14 studs on for the rewound rider. The rider
   takes less than at 0 ping (0 or the body share), never more: 1,781 of 146,304 shots. Example: a
   BananiniScoot rider driving at the shooter at 106 studs/s, 100 ms ping, takes 0 instead of 100.
2. **A rider's limb through the bodywork is missed at 0 ping** (measured, rests on "a ray doesn't report
   a part it starts in" and on the rider's pose): `riderBehind` starts 0.05 inside the body, so inside
   the limb. 36 of 213,696 shots, a CameloCarrier front passenger's arm, not growing with ping.
3. **`CombatService.lua:1021-1024`'s comment names the wrong parts**: ArmorGlass/ArmorSlit are queryable
   (`Armor` in SOLID_NAMES) and never count as glass; the Scout's 2.5x came through `GunShieldGlass`, and
   ordinary cars had 3.25x. The code is right.
