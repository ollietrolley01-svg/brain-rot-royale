FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: #57/#110 roadkill (PR #39): who fixes the four findings, and three product calls
NEEDS: decision
BY:    blocks the roadkill fixes only; everything else carries on

## First: PR #39 is ready

The roadkill proof is PR #39 (`task/prove-roadkill`). As you asked at 02:10, it's merged with main
**f1bb3b4** (after 05437cf and 52a5608), and every run was repeated there: `16 checks, 0 failed,
4 findings`, plants 11/11, and the same damage numbers. Line references are to f1bb3b4.
**Every damage number uses `CombatDamageScale` 0.92.** If `pc/ttk-plus-25` merges (0.736), multiply
them by 0.8. Short version: roadkill fires on main for player and bot drivers. The player-driven path
has never run in Roblox.

## Decision 1: who fixes findings 2, 4 and 6?

Jacob wants to work on the bugs from the report. STATUS says the build machine owns fixes, so we're
asking before touching `VehicleService.lua` or `CombatService.lua`.

- **A. The build machine fixes them**, as it did with the #97 F1-F4 fixes (`pc/hitreg-fixes`).
- **B. bimjom fixes them**, one at a time, in this order: 2, 4, 6. Each is its own branch and PR,
  touches only the lines named below, and comes with a check that has a planted fault.
  Nothing is pushed toward main until you've read it.

We'd pick **B**, because the proof harness already runs these paths. But A is fine, and if you pick
A we stop at this message. Either way, Decisions 2-4 are Oliver's.

## Decision 2: a vetoed hit still throws the body (finding 2)

`VehicleService.lua:1031-1052`. `roadkill()` launches a survivor whatever `DealDamage` returned. A
team-mate, or an enemy under spawn protection, takes 0 damage but is thrown at (26, 40, -40) studs/s
from an 84 studs/s car. A bot team-mate is knocked down first. A throw that size can put someone off a
ledge or into the storm, and a death from it is credited to nobody.

- **A. A vetoed hit does nothing to the body** (no throw, no knock-down, no ragdoll attribute). The car
  still passes through. `DealDamage` already returns 0 on a veto (`CombatService.lua:440`).
- **B. Spawn protection blocks the throw, but a team-mate still gets shoved.**
- **C. Leave it.**

We'd pick **A**. Throwing a spawn-protected player looks unintended, and a team-mate thrown into the
storm is a team kill in effect.

## Decision 3: riders of another vehicle can be run over, armour or not (finding 3)

`RoadkillPass.lua:196-202` leaves out only its own car's riders, and `roadkill()` checks neither
`VehicleService.CabinShield` nor the cover rules c8736d2 added for bullets and blasts. In the harness,
a car hitting a parked, armoured Tartaruga Scout side-on at 60 dealt 79.49 to its near-side driver.
The cars there are box stand-ins, so the distances are approximate.

- **A. An armoured cabin protects its riders** (the same rule bullets follow). Riders of an open car
  can still be hit.
- **B. No one sitting in any vehicle can be run over.** Car-on-car hits go through vehicle health only.
- **C. Leave it.**

We'd pick **A**. It matches what the armour already does against bullets.

## Decision 4: a car with nobody driving hits 8.7% harder (finding 4)

When the driver bails, the car credits nobody. That's intended (`VehicleService.lua:962-964`). But
with no attacker, `DealDamage` skips the 0.92 scale and the team check (`CombatService.lua:447-448`):
86.40 against 79.49 for the same car driven at 60.

- **A. Apply the time-to-kill scale to roadkill even with no attacker.** Crediting still goes to nobody.
- **B. Credit the driver who bailed for a few seconds.** They get the scale, the team check, the
  kill-feed name and the quest progress.
- **C. Leave it.**

We'd pick **A**. It's the smaller change. B also stops a bailed car killing its own team, if that
matters to you.

## Not a decision, just so you know

- **Finding 1 (the one that matters most):** a player-driven roadkill has never run in Roblox. If the
  server reads 0 for a client-owned car's speed, every player roadkill is silent
  (`VehicleService.lua:1091`). Please add this to the next playtest with two people: one drives at
  over 20 studs/s into the other. Expected: a damage number, a throw, and a `[Roadkill]` feed line on
  a kill. If nothing happens, that's the cause.
- **Finding 5 (balance):** a Sahur Van at 72 deals 99.36 and leaves 0.64 health. At 0.736, only the
  Streetfighter (135.13), Tralala GT (124.53) and Patapim Scrambler (103.33) one-shot at top speed.
  That's your call if it matters.
- **Finding 6:** the comment at `VehicleService.lua:119-125` still quotes 10.8/183.6. The right numbers
  are 9.94/168.91, and they move again with ttk-plus-25. If we get B above, we'd reword it without
  numbers, so it can't go stale.
