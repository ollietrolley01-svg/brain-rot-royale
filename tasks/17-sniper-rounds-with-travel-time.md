# Task 17: sniper shots fly, with travel time and drop

**Files you own for this task:** a new round in `ReplicatedStorage/Shared/Ballistics.lua`
(`Ballistics.RegisterRound`), the `projectile` field on the five sniper entries, and a new check under
`tools/`. **Read only:** `CombatService.lua`, `LagCompensation.lua`, `ProjectileService.lua`,
`ProjectileClient.client.lua`, `CombatClient.client.lua`, `BotService.lua`.

## What was reported

Snipers are hitscan. Jacob wants their shots to be real projectiles with travel time, and drop if the
game already has a way to do it. Playtest, 2026-09-25.

## What already exists

The projectile path is there and already carries non-explosive rounds:

- `CombatService.Fire` (line 1190) sends any weapon with a `projectile` field to
  `CombatService.LaunchProjectile`, which `ProjectileService.launchRound` (line 557) fills in. It skips
  the hitscan path (`firePellet`) completely.
- `ProjectileService.burst` (line 515) handles a round with `explosive = false`. It deals the direct
  hit only, with the gun's `headshotMultiplier`, and no blast.
- Three rounds already work this way: `mosquitoDart` (Ballistics line 524, speed 175, gravityScale
  0.05), `bananerang`, and `ricochetDisc` in `CreativeRounds.lua`.

So the minimal change is a `sniperRound` registered with `explosive = false`, a speed and a
`gravityScale`, and `projectile = "sniperRound"` on the five sniper-style guns: `LarilaSniper` and
Six-Seven Marksman in `WeaponData.lua`, Silenzio Sussurrone and Nanna Nanna Puff in
`ArsenalExpansion.lua`, and Hose Down in `WorkshopArsenal.lua`.

## What the hitscan path does that the projectile path does not

This is most of the task. List each item and decide it, with Oliver where it is a design call:

1. **Lag compensation.** `firePellet` rewinds victims to what the shooter saw
   (`LagCompensation.RewindTime`, `LagCompensation.Raycast`, CombatService line 1180). `ProjectileService`
   has no rewind at all: its `sweep` (line 202) hits present positions. A fast round flying for 0.2-0.5 s
   also needs a decision on where it is spawned (at the shooter's view time or now). Read
   `HITREG_DESIGN.md` and PR #33's hit-registration proof before choosing.
2. **Abilities.** `fireAbility` (CombatService line 744) runs from `firePellet` only. `LarilaSniper`
   has `ability = "freeze"` (WeaponData line 648), and pierce, chain and lifesteal are hitscan-only too.
3. **Vehicle riders and glass.** `riderBehind` (line 833) and `BreakGlassAlong` give a hitscan shot
   the cover rules riders get. PR #62 (`task/rewound-glass`) just proved those rules. A round needs the
   same answer.
4. **Speed and tunnelling.** `sweep` does at most 8 spherecasts per step. Check that the chosen speed
   can't pass through a thin wall or a body between steps.
5. **Bots.** `BotService`'s `shootAt` resolves a bot's shot with a hit chance. PR #35 found a bot's
   Golden Sahur Cannon never exploded because that path ignored `projectile`. Check how a bot's
   sniper shot goes after the change.
6. **The client.** `ProjectileClient` draws rounds, and CombatClient predicts tracers and hit markers
   for hitscan. The scope view and hit marker timing will change.

## Ask Oliver

The speed and drop are a feel decision. Send him two or three numbered options (for example 600,
900 and 1,200 studs a second, with how far the round drops at 300 studs for each). Work to the default below until he picks.

## Default

A round at 900 studs a second with a small drop (for example `gravityScale` 0.05), direct damage and headshots as today, the freeze kept. The round flies against present positions, and the PR says plainly what that costs a high-ping shooter compared with hitscan's rewind. Offer Oliver the speed options in the PR.

## Conflicts

`pc/lag-bug-sweep` changes `CombatService` (hunks at `DealDamage`, `combatantsInRadius`, `firePellet`
and others), `ProjectileService` and `WeaponData`. `task/blast-parachuters` and `task/bot-gunner-wait`
are stacked on it. PR #62 (`task/rewound-glass`) touches the rider-cover code. Cut from the sweep once
it merges. Oliver's 03:00 rule applies: an outside claimant writes the diagnosis, the check and the
exact before/after, and the build machine applies game-file changes unless Oliver says otherwise.

## Proof

Offline, with lupa: fly the real round through `Ballistics.RoundState` and the real
`ProjectileService.sweep` against mocked targets. Report the travel time and drop at 100, 300 and
600 studs; that a still target at 300 studs is hit with the right damage and headshot multiplier; that
the freeze still applies; and that a 0.5-stud wall between steps is not passed. Plant a fault aimed at
an invariant (a round never passes a solid part it crosses) and show it goes red.

**The feel cannot be proven offline.** It needs a Studio **Play** test with a client firing at a
moving bot at range, plus a ping test for the rewind. The coordinator runs it.

Status: ready to start
