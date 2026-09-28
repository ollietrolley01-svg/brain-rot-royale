# Task 30: roadkill must not one-shot a player at full health and full shield

**Files you own for this task:** `tools/roadkill_proof_check.py` (from PR #39) and the report. The fix is
in `VehicleService.roadkill` (line 997) and the `ROADKILL_*` constants (lines 132-141). Oliver's roadkill
decision on 09-25 03:00 gave roadkill fixes to the build machine, so an outside claimant sends the exact
before/after text. **Read only:** `VehicleService.lua`, `RoadkillPass.lua`, `CombatService.lua`,
`VehicleDynamics.lua`.

## What was reported

Roadkill kills a player at full health and full shield in one hit. Oliver, relayed by Jacob.

## The numbers

A full player has 200: `MatchConfig.StartHealth` 100 and `MaxShield` 100. A roadkill hit is
`(flat speed - ROADKILL_FLOOR 12) x ROADKILL_DAMAGE_PER 1.8 x CombatDamageScale`, then `DealDamage`. The
debounce is 0.5 s per victim (`ROADKILL_DEBOUNCE`).

`reports/roadkill-proof.md` (PR #39) measured every model at top speed. The worst was the
BrrStreetfighter at 114 studs a second: 168.9 at the old 0.92 scale, about 135 at today's 0.736. A full
player survived with 31 health. So by the formula, one hit at top speed can't kill.

Likely causes, to find out which:

1. **The speed isn't capped at top speed.** The formula uses the car's actual flat speed. Downhill,
   off a ramp, or after a blast, a car can pass its top speed. At 0.736 anything over about 163 studs a
   second deals 200.
2. **Two hits in one pass.** The debounce is 0.5 s. A body carried along by the car (`RoadkillPass`,
   `ROADKILL_GRACE` 0.4) or thrown and landed on can be hit again, which reads as one hit to the player.
3. **Crash and throw damage on top.** The launch after the hit, then landing or striking a wall.

Oliver's earlier roadkill calls stand (the 09-25 03:00 message): spawn protection is removed; an
armoured cabin protects its riders; the damage scale applies with nobody driving, with no credit.

## Default

A single pass (the first contact and anything within a stated window after it) deals at most a stated
amount under 200, for example 150, whatever the speed. Cap the per-hit amount the same way.

## Conflicts

`pc/lag-bug-sweep` changes `roadkill` itself (a hull distance and reach test, `ROADKILL_LAG`) and 120
lines of `VehicleService`. Build on it. Task 11 changes car health, not roadkill. Crash damage to the
car is separate.

## Proof

Offline: `roadkill_proof_check.py` already runs the real `roadkill`. Add cases for a car at 1.5x and 2x
its top speed, a body carried through a second contact, and a throw into a wall. With a full player (100
and 100), the player must survive every single pass. Plant a fault aimed at that invariant (the cap
removed) and show it goes red. Report how many passes and models were examined.

Real physics: a Studio **Play** test with a client hit by a bot driver downhill at full speed. The
coordinator runs it.

Status: ready to start
