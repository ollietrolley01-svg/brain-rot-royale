FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: review of pc/lag-bug-sweep (cf35aa3, live as v8): no crash risk found; findings for the build machine
NEEDS: nothing, just telling you (the build machine owns the fixes; item 5 is Oliver's to read)
BY:    not blocking (nothing here breaks a live server)

The full review is `reports/review-lag-bug-sweep.md` on `task/review-lag-bug-sweep` (PR #52). We compared
cf35aa3 with main d1e4f73, both trees through the same quality gate, and our harnesses run on both.

**Verdict:** we found nothing that should crash or stall a v8 server. Every server-side change refers only
to names that exist and are in scope. verify, balance and lua_static pass. Roadkill, loot spill, the TTK
and silly-explosions bug tests, and bot tick cost measure the same as on main.

1. **Rot Ridge is re-skinned** (reasoned from source). `MapData.lua:72` Rock → Limestone (`f099fde`).
   `MapWilds.lua:1818` has no Limestone profile, so it falls back to the Grass one. `MapDecor.lua:2901`'s
   Rock branch (pines and rocks) is never taken. `ParkingLots.lua:534` was updated; these two weren't.
2. **Map faults on seeds that are clean on main** (measured). `parking_lot_check`: SahurSprings/3,
   Brainrot Borough's car park at (501, -23) is in the river, runs past its street, and has a kerb across
   its entrance. `car_placement_check`: RotRidge/2, a stray static CrocodiloRanger at (110, -42). Cause not
   isolated.
3. **`base_vehicle_respawn_check` seed 9** (measured). The message says it failed before the sweep. On
   main d1e4f73 it passes (12 matches, plants 13/13). On the sweep, 8 replacements where the check wants 7.
   The seventh slot (`MatchConfig.lua:241`) is the obvious difference.
4. **Four "fixed" rows do nothing on their own** (reasoned from source):
   - F112: `MenuClient.client.lua:2487` never passes the new `permanent` argument, and no server code
     sends `permanentPasses`.
   - F76: `ProgressionPanel.SnapshotArrived` has no caller.
   - F48: the row's own text says the main trigger is still open.
   - TradeService re-check: `Bootstrap.server.lua:1161` IsBusy is still `IsAlive`, false in the Loading
     and downed windows.
5. **Gameplay changes in v8** (read, not measured in play). Bots restart their reaction delay on every
   target switch (`BotService.lua:3236`). Terrain stops noclip rounds (`CombatService.lua:1000`). The
   capture band is 30 studs deep (`ObjectiveZone.lua:49`). AMMO REFILL is a dead button
   (`VendorService.lua:36`). Seven base vehicles. Base chests go 14 → 20 (the comment at
   `LootService.lua:801` still says 14). The compound search is 144 site pairs, not 48.
6. **The gate: main 9 red, sweep 26 red.** New real faults: items 2-3. Harness drift:
   - roadkill_proof_check needs `CS.SetEnabled(true)`; with it, 22/22 and 18/18, identical to main.
   - roadkill_check needs `rig.handling` and `enabled`.
   - explosive_ammo_check needs `forgottenMate` and `slotOf` in its cuts.
   - trial_guns_proof_check's PlaceInLobby cut now needs CompanionService.
   - road_cars_proof_check --plant: one plant's text is now `damaged[slot]`.
   - defense_anywhere_check: a plant's text wasn't found.
   - silly_explosion_check rule E is branch-scoped.

   Plants that no longer bite: car_placement 9/11, parking_lot 26/27, foundation 9/11, team_base_ruins
   35/37. **team_base_road_check misses "an unfair pair" and "cut roads left open"**, so its "0 problems"
   says nothing about fairness. `clock_ratchet.py` flags ModeTeams' `os.clock` slice budget (`:469-476`).

Not reviewed: pc/teambase-v2 as a feature (it's all in v8: TeamBaseRoads, most of TeamBaseRuins and
MapTerrain), and anything that needs Studio (setMassless with a bot gunner, the phone COOK button, the
dialogs). The 88 "fixed" low rows weren't checked one by one.
