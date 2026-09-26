# task/car-health (task 11: car health 700-800)

Cut from `origin/main` d1e4f73. Brief: `tasks/11-car-health-700-800.md` on `task/playtest-briefs` (PR #68).

## What changes from d1e4f73

Numbers only. No game logic moves.

- `ReplicatedStorage/Shared/VehicleArmor.lua`: the four cars go to 700-800 health (TralalaGT 700,
  Rotster 740, CrocodiloRanger 780, SahurVan 800). That is 0.491 of the old cars' average (755 against
  1537.5), and the bikes and the armoured pair are cut by the same 0.491 so each keeps its ratio to an
  average car: bikes 295 / 305 / 325, TartarugaScout 1520, CameloCarrier 1635. `DefaultHealth` (a model
  the table doesn't know) goes to car 700, bike 310. The header says what changed and why.
- `tools/vehicle_ttk_check.py`: new bands for the new health. CAR: 700-800 health, 5.5-7.5 s of the Rare
  rifle, exactly 2 rockets. BIKE: 0.35-0.5x the average car, quicker than any car, 1-2 rockets. ARMOUR:
  still 2-2.5x a car, now 4-5 rockets. GUNS and CRASH bands are unchanged. Planted faults 7 -> 12: a car at
  680, at 820, at its old 1600, a bike and an armoured car left at their old health.
- `coordination/messages/2026-09-26-0129-bimjom-task11-car-health-questions.md`: the brief's two questions
  for Oliver.

## Before / after (at CombatDamageScale 0.736)

| vehicle | health | Rare rifle | rockets |
|---|---|---|---|
| cars | 1400-1650 -> 700-800 | 12.1-13.6 s -> 6.0-6.7 s | 4 -> 2 |
| bikes | 600-660 -> 295-325 | 3.5-5.7 s -> 1.6-1.9 s | 2 -> 1 |
| armoured | 3100 / 3330 -> 1520 / 1635 | 50.9 / 58.8 s -> 24.1 / 29.1 s | 7 / 8 -> 4 / 4 |

Crash damage keeps its share of health (`CollisionScale` divides by `CrashBasis`), and bot bail and
retreat are shares of health, so neither needed a change.
