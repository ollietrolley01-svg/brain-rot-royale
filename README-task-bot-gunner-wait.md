# task/bot-gunner-wait

Cut from `origin/pc/lag-bug-sweep` at `cf35aa3`; the PR targets `pc/lag-bug-sweep`. In the battle
royale the sweep (2e6d846, `Vehicles.botGunners`) stopped bots taking a vehicle's gun, but a bot at
the wheel of an armed car still held it for `BotGunnerWait` (25 s) waiting for a gunner. Only a
player could come, and usually none was about.

- `ServerScriptService/Modules/BotService.lua`: new `Vehicles.gunnerMayCome`. In a team mode it is
  always true (the wait is unchanged). In the battle royale it is true only while a live player the
  bot isn't fighting is on foot within `VEHICLE.RIDE_REACH` (30 studs) of the car, or riding in it.
  `driverThink` gives the car up through its existing "no gunner" exit when it is false. It still
  won't do that while under fire.
- `tools/bot_driving_takeover.py`: the GUNNER wait scenarios now cover the battle royale with nobody
  about, and with a player who is far, fighting the bot, at another wheel, or dead. They also cover a
  player nearby, a player walking over to take the gun, and a team mode. There are four new planted
  faults (11 in all).

Run with `python tools/bot_driving_takeover.py .` (needs lupa).
