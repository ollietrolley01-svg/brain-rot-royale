# #97 hit registration — measured state, and the options for the half that is left

Written by the guns tab, 2026-09-22. **Nothing here is landed.** The instrument is
`tools/hitreg_probe.lua`; its numbers are quoted below and it re-checks its own replica raycast
against `CombatService`'s source on every run.

## What is already fixed

The fire-rate half landed 2026-09-21 23:03. `CombatService` budgets shots (`FIRE_BURST = 2`, refill
at exactly `fireRate`) instead of spacing them, and the client's fire rate was made accurate in the
same change — deliberately together, because the client's frame-rate quantisation was the slack that
kept the old 10 % tolerance from eating shots. Not reopened here.

## What is not fixed: nobody rewinds the target

`rewind`, `positionHistory`, `snapshotAt`, `lagComp` appear nowhere in the project, and nothing reads
a ping. `CombatService.Fire` raycasts against live positions at the instant the packet arrives.

The client sends **`aimPoint`, a world POINT** under its crosshair; the server derives the direction
itself. A world point is a place, not a target — when the victim moves, the ray goes to the place they
have left and passes through the air behind them. **This is why a bigger hitbox is the wrong shape of
fix: it widens a hole that is in the wrong place.**

### Measured (probe, both planted faults firing)

Torso half-width 1.00 stud. Victim crossing the shot square on at `BaseWalkSpeed` 18:

| round trip | miss distance at arrival | result |
|---|---|---|
| 30 ms | 0.54 | lands |
| 60 ms | 1.08 | **misses** |
| 100 ms | 1.80 | **misses** |
| 150 ms | 2.70 | **misses** |

At 9 studs/s the break is between 100 and 150 ms; at 45° and full speed, between 60 and 100 ms. Every
one of those shots was **dead centre when it was fired**. The break-even is about **55 ms of round
trip** — an ordinary connection, not a bad one.

**Caveat, stated rather than buried:** the probe aims at the victim's centre with no lead, so this
measures *the server's error*, not a skilled player's experience; someone who leads the shot
compensates for part of it. The server is still ruling on the wrong instant either way.

**Not measured, and cannot be here:** real ping. No `Player` object exists in either harness mode, so
`GetNetworkPing` cannot be called; latency above is a swept **parameter**. The live half is written
into the probe as `HitReg.LogShot`, unwired, and prints "ping unavailable" rather than 0 ms when the
reading is missing — a zero from an instrument that measured nothing looks exactly like a fast pinger.

## Options

Each answers the three questions that decide it: the **cap**, where the rewind interval **comes from**,
and what it does to the **victim who reached cover**.

### A. Server-side rewind (the real fix)

Every server step, push each combatant's root CFrame and the server clock into a small ring buffer
(~20 samples covers 300 ms at 60 Hz; 16 players ≈ 320 CFrames, negligible). On a shot, rewind each
candidate victim to `arrival − interval` and raycast against those positions.

- **Cap:** 200 ms, and shots older than the cap are ruled on the present, not extrapolated. Justified
  by the table above — beyond 200 ms the displacement exceeds 3.6 studs, nearly two torsos, and
  honouring it would mean killing people who are nowhere near where the shooter claims.
- **Interval comes from:** the server's own arrival time and its own `GetNetworkPing` reading. **No
  client timestamp is read.** An option that needs the client to say *when* is disqualified outright,
  not mitigated: a forgeable time value is an aimbot alias.
- **Cover trade:** a player who rounds a corner can be killed up to one cap after they are safe on
  their own screen. This is the classic trade and it cannot be avoided, only chosen: either the
  shooter's shots land where they aimed, or the victim's cover is absolute. **Oliver picks.**
- **Cost:** a real change to the most safety-critical function in the game, interacting with the
  fire-rate budget landed on the 21st. Its decisive input (ping) is unmeasurable in this harness, so
  the geometry can be plant-proven and the timing cannot. **This is why it should not be landed at the
  edge of a credit window.**

### B. Client sends the victim it believes it hit

Rejected. It needs the server to trust a client-supplied *target*; validating that claim honestly
requires the rewind from option A anyway, so it is A plus a new trust boundary.

### C. Wider hitboxes or a forgiveness cone

Rejected on the measurement. At 100 ms the displacement is 1.80 studs against a 1.00-stud half-width:
a cone wide enough to cover it would also snap shots onto targets the player never aimed at, and it
does nothing about the ray going to a place the victim has left.

## Notes for whoever builds A

**Write cost per server step.** One CFrame read and one ring-slot write per combatant. At 60 Hz with
16 players plus bots (~20 combatants) that is ~20 writes a step, 1 200 a second, inside a Heartbeat
that already walks the player list. It is not a cost worth optimising before it is measured.

**Memory per combatant.** A `{cframe, t}` sample is roughly 80 bytes with table overhead; 20 samples
covers 300 ms at 60 Hz, so ~1.6 KB per combatant and ~32 KB for a full lobby. Negligible. Store the
root only — per-limb history multiplies this by 15 and buys nothing the notes below do not.

**YOU CANNOT RAYCAST THE PAST, and this is the part that decides the shape of the work.**
`workspace:Raycast` tests the world as it is now. There are two honest ways round it:

1. *Move the parts back, raycast, restore, all inside one server frame with no yield.* Replication is
   batched at frame end, so a same-frame move-and-restore normally never reaches a client. The risks
   are real and must be written into the code, not the commit message: **any** yield (a `task.wait`, a
   remote, a pcall that yields) between the move and the restore replicates a teleport to every
   client, and it mutates physics state on parts the server may not own.
2. *Test the ray against rewound volumes arithmetically* — no world mutation, nothing to restore, no
   yield hazard. Costs an OBB-per-part intersection routine, which this project already has in probe
   form (`tools/hitreg_probe.lua`'s `missDistance`, and `ground_gun_probe`'s `interval` does true
   box/cylinder/ball ray tests).

Option 2 is the safer build and the one I would start from.

**THE TRAP, and it is the same bug as the hats.** A headshot is decided by NAME —
`result.Instance.Name == "Head"` (`CombatService.lua:602`, `ProjectileService.lua:659`). Any rewind
that resolves a hit to *a victim* rather than to *a part* silently deletes every headshot in the game,
and it would look like a clean refactor. Whichever route is taken, the rewound test must return the
part it struck, and the probe must plant a rewound headshot and fail if it comes back as a body hit.

## Second cause: hats, and what is NOT wrong

**`CanQuery = false` is this project's established pattern for everything it hangs on a character**,
and it is already applied everywhere: `CosmeticBuild.lua:35` (shop cosmetics), `WeaponService.lua:286`
and `:321` with `GunModels.lua:271` and `:3341` (the held gun), `MovementService.lua:194` and `:208`.
Shots pass straight through all of them. A sweep of eight head cosmetics found **0 % swallowed**, with
a planted slab — built by the probe itself, therefore queryable — swallowing 100 %. The zeros were a
measurement, not a broken instrument; the plant was simply built differently from the subject. The
corrected sweep in `tools/hitreg_probe.lua` now aims up the whole visible silhouette at each item's own
anchor, so a future cosmetic that forgets `CanQuery = false` is caught.

**But the corrected sweep found a third thing, and it is a real complaint.** With the grid aiming up
the whole visible silhouette, the tall head items pass **24 of 40 rays straight through to nothing**
(ChefHat, PartyCone, TrafficCone: 16 rays reach the Head, 24 hit empty air; VikingHelm, PropellerBeanie,
ExposedBrain, RubberDuck: 24 reach the Head, 16 hit nothing; RotShades, a Face item, 40/40 reach the
Head). Those are the shots aimed at the upper half of what the player can SEE. A cosmetic makes an
enemy taller on screen without making them any bigger to shoot — so aiming at the visible top of a
cone-wearing player is a clean miss, with no hit marker and nothing to explain it.

That is not a fault in the combat path, and `CanQuery = false` is the right setting — the alternative
is hats that soak bullets. It is a **silhouette-versus-hitbox mismatch**, and the options are design
ones, not engineering ones: keep it (players learn to aim at bodies), cap how far a cosmetic may
extend above the head, or accept hat hits as body hits. Worth putting to Oliver as a preference,
with these numbers, rather than being decided quietly by whoever touches it next.

**What is wrong is the one class of attachment this project does not own: a player's own Roblox
accessories.** Those Handles are queryable by Roblox default and nothing here touches them. Their
hierarchy also differs from ours — a Handle's parent is an `Accessory`, which is not a Model, so
`FindFirstAncestorOfClass("Model")` at `CombatService.lua:594` walks up to the **character** and the
shot is paid as **body damage with the headshot lost**, silently, for every player wearing a hat or
hair. (Ours would have resolved to the cosmetic Model, returned no victim and hit the `break` — no
damage at all — which is exactly why it matters that ours are already excluded.)

The fix is this project's own pattern applied at spawn: set `CanQuery = false` on each character's
Accessory handles. One place, no combat-path change, no new trust boundary.

**It was not landed here because it cannot be measured here.** `CreateHumanoidModelFromDescription`
in offline Studio may return a rig with no accessories at all, and an empty rig reads exactly like a
pass. Land it with a real avatar in front of you, and measure the before and after with the sweep.

## Recommendation

Land **nothing** of A in a window that cannot also playtest it. The accessory fix above is small and
correct but needs a real avatar to prove, so it waits too. Start the next session from this note, the
probe, and a decision from Oliver on the cover trade — that decision is the only part that cannot be
measured.
