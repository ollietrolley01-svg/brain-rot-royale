FROM:  Oliver's lag/bug sweep session (build machine)
ABOUT: pc/lag-bug-sweep (live as Roblox version 8): review it, then the open bugs below
NEEDS: review, then fixes. Oliver: "leave all reviewing to jacob"
BY:    not blocking, but the HIGH items are live bugs

Pull `pc/lag-bug-sweep`. It has the latest origin/main merged in (merge faeedab). Oliver published it as **Roblox version 8**.
It isn't on main yet, because the build machine can't push to main without Oliver's sign-off.

## 1. Review the sweep (Oliver's call: all reviewing is yours)
`coordination/handoffs/2026-09-25-lag-bug-sweep-review.md` lists all 139 fixes, one row each:
severity, file:line, defect and change. Two independent verifiers confirmed each defect, but **no fix has had a
second look**. It also has 107 cross-file notes the fixers left unacted, the critic's 12 round-2
hunts (never run), and 1 disputed finding. Review high and medium first. Behaviour changes to look at hardest:
- **WeaponService:** GiveAmmo now always returns false under infinite ammo. The vendor's AMMO REFILL, loot and
  chest "+ammo" and the supply drop ammo are dead now; see the cross notes.
- **CombatService:** DealDamage is gated on `enabled`. `tools/roadkill_check.py` (14/25) and
  `roadkill_proof_check.py` need `enabled = true` / `CS.SetEnabled(true)` added (see the cross notes). VehicleService's roadkill
  report validation (F118) also breaks `roadkill_check`.
- **The bot gunner fix (VehicleService.setMassless):** a riding bot's AnimationConstraints go kinematic, then get
  restored when it gets out. Not proven in Studio.
- `tools/clock_ratchet.py` fails, because ModeTeams has a new os.clock() deadline (RankBaseAxes now yields).
  `silly_explosion_check` rule E flags the HazardService and MountedGuns lines.
- `base_vehicle_respawn_check` fails at seed 9 ("abandoned vehicle replaced early", "8 replacements, want 7").
  This was already failing before the sweep; the new arena-edge case and its plant pass.

## 2. HIGH, Oliver's playtest reports (still open)
- **Bike models are broken** (Patapim Scrambler): parts scattered and sticking out of the body. **The Sahur Van's
  bat has the same problem.**
- **Improve the sights and first-person alignment of every mounted weapon, car guns included.**
- **Wall crack animations only show on one side of a wall.**

## 3. Also open
- **Base cars 7/12:** most likely cause, not proven: a wood or orchard (radius 30..56 > ClearableSpan 70)
  left standing inside one team's motor pool. ClearSite and ClearMoved keep anything that wide, and bayOccupied then
  refuses those bays for that team only. Fix idea: split FootingSkip groups into pieces in ClearSite, ClearMoved
  and SiteCost. Also zipline posts in bays. Check a bad run's Output first ("parked X of Y", map, "not built").
- **tools/base_vehicle_respawn_check.py judge_probe** still assumes 6 slots (it's 7 now).
- **Companions:** Blast-brainrot explosions (ProjectileService.Explode) can still hit parachuters; only
  direct companion attacks were fixed.
- **Battle royale:** a bot driving an armed car still waits up to 25 s for a gunner that now can only be a player.
