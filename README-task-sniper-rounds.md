# task/sniper-rounds

Cut from main at d1e4f73. Task 17 (brief on PR #68): sniper rifles fire real rounds with travel time and a
little drop, for players and bots, instead of hitscan.

- `ReplicatedStorage/Shared/Ballistics.lua`: a new round kind, `sniperRound` (900 studs/s, gravityScale
  0.05, not explosive). Its `onContact` hands each contact to the hitscan rules and carries pierce (flies
  on through bodies up to PIERCE_TARGETS) and ricochet (banks off the map as a new round) itself.
  `Ballistics.SniperRound` holds its constants.
- `WeaponData.lua`, `ArsenalExpansion.lua`, `WorkshopArsenal.lua`: `round = "sniperRound"` on Larila
  Sniper, Six-Seven Marksman, Silenzio Sussurrone, Nanna Nanna Puff and Hose Down. The field is `round`,
  not `projectile`, so bots, the reach readout and the hit splats keep treating these guns as guns.
- `CombatService.lua`: `Fire` launches a `round` gun's bullet the way it launches a launcher's round;
  new `CombatService.RuleBullet` runs the existing `firePellet` over the short stretch where a round
  landed (walls, glass, vehicles and rider cover, headshots, lifesteal, explosive ammo, as hitscan).
- `ProjectileService.lua`: `launchRound` and `LeadAim` accept `def.round`; `api.RuleBullet` and
  `api.Launch` for the round's callbacks.
- `BotService.lua` (`shootAt`): a bot's sniper shot flies too. The accuracy roll still picks the aim
  (a hit leads the target, a miss goes where the roll put it); damage keeps `BotDamageScale`.
- `tools/sniper_round_check.py` + `.lua`: the offline proof (45 checks, 10 planted faults).
- `tools/sniper_round_probe.lua`, `tools/sniper_round_gallery.lua`: the Studio probe and render.
- `tools/verify.py`: the Fire hook needle follows the new line; the round-kind contract covers `round`, and
  the five snipers must keep it.
