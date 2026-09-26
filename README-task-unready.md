# task/unready: players can un-ready in the lobby (task 09)

Cut from `origin/main` at d1e4f73.

## What changed

- `ServerScriptService/Modules/LobbyService.lua`: the ready pad readies a player once per visit, not on
  every `Touched` 1.5 s apart. A visit lasts while the character's root is within 7 studs of the pad's
  centre (horizontally), or a touch came in within the last second. A watcher checks every 0.25 s and ends
  the visit. `PAD_COOLDOWN` is gone; `PAD_REACH`, `PAD_LINGER` and `PAD_POLL` replace it.
  `readyPadLastTouch` keeps its name, its module scope and its PlayerRemoving clear.
- `tools/ready_pad_check.py` (new): runs the real `buildReadyPad` Touched handler, the real Bootstrap
  `OnReadyPad` hook and the real `MatchService.SetReady` in lupa with a mock clock. Six scenarios, five
  planted faults. `--lobby FILE` runs the scenarios against another copy (main's fails 4 of 6).

## Why

Oliver, playtest 2026-09-25: "i cant unready up". A player who walked onto the pad and pressed un-ready
while standing there was readied again by the pad's next touch, 0.8 s later in the check.

## Not proven

That `Touched` repeats for a standing character is Roblox behaviour, assumed in the check (every 0.2 s).
A Studio Play test with a client on the pad would confirm it.
