# task/rewound-glass

Cut from main `d1e4f73`. The coordinator's 0830 handoff (section 3) passed on a sweep finding against
`pc/hitreg-fixes`: "CombatService:995: a rewound shot reads glass instead of body on the armoured cabins,
so the rider takes 2.5x damage depending on ping". That line was b254eac's. **dd6cfb0 fixed it on the same
branch, and it is on main through the merge 3c0a18a**, so this branch proves the fix instead of fixing it
again. No game file is changed.

- `tools/rewound_cover_check.py` (new): runs the real VehicleModels, LagCompensation, VehicleCover and
  CombatService's `firePellet` (with `riderBehind` and `bodyBetween`) in lupa. It fires shots at a seated
  rider in every seat of every vehicle build, at 0 ping and at a spread of speeds and pings. Every shot that
  reaches the rewound rider must give the rider, the vehicle and the headshot flag the same result as at
  0 ping. On main: 146,304 rewound shots, 0 differ. It has 4 planted faults, all caught, including b254eac's
  glass-before-body order, which gives 7,124 differing shots (up to 3.25x the 0-ping damage).
