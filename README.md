# proof/sniper-rounds (never merge)

Proof images for task 17, "sniper rifles fire real rounds" (branch `task/sniper-rounds`). This branch is an
orphan that holds pictures and a log only. **Never merge it.** The task branch commits no images.

Rendered by `tools/sniper_round_gallery.lua` in Studio (Jacob's Linux harness, edit mode). The round is the
model clients draw (`ThrowableModels.Round("sniperRound")`), placed at positions from the real flight maths
(`Ballistics.RoundState`, live gravity 196.2).

- `sniper_round_leaving.png`: over the shooter's shoulder (their head is the block in the front left),
  the round 0.02 s after the shot, 18 studs out and 0.002 studs below the line. The target stands 300 studs
  down the plate.
- `sniper_round_arriving.png`: beside the target, 300 studs from the shooter. The round is where it is one
  server step (1/60 s, 15 studs) before it reaches the target's head, at head height. At 300 studs it has
  dropped 0.54 studs (the head is 1.2 tall), and the flight took 0.333 s.
- `sniper_round_probe_log.txt`: `tools/sniper_round_probe.lua` in Studio. The real ProjectileService and
  CombatService, stepped by hand. A body shot at 300 studs lands 0.333 s after firing for 70, a head-centre
  shot is a headshot for 175, and a 0.5-stud wall stepped at 0.1 s (90 studs a step) stops the round.
  After the body shot the round keeps going: the Larila Sniper pierces.

Not shown: the round in a live match with a client (edit mode runs no LocalScripts, so ProjectileClient's
own drawing isn't in these), and the feel of leading a moving target. Both need a Studio Play test.
