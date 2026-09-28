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
- `tools/ready_pad_probe.lua` (new): the Studio render. Run mode, the real handler and `SetReady`, real
  physics touches from an animated R15 rig on the pad; draws the Ready state in the frame. Run it on a build
  of main and one of this branch for a before/after.

## Why

Oliver, playtest 2026-09-25: "i cant unready up". A player who walked onto the pad and pressed un-ready
while standing there was readied again by the pad's next touch, 0.8 s later in the check and 1.66 s later
in Studio.

`MatchService.SetReady`'s 0.3 s throttle is ruled out as the cause: the pill sends the opposite of the
server's `Ready` attribute, so a dropped press leaves the pill showing the truth and the next press works
("pill only" scenario). On main the pad's `SetReady(true)` calls did stamp that throttle, so an un-ready
pressed within 0.3 s of a pad touch was also dropped; the fix stops those calls while standing.

## Not proven

That `Touched` repeats for a real client's character is Roblox behaviour, assumed in the check (every 0.2 s).
In Studio a server-run rig re-touched the pad only while its feet moved (0 touches standing still with the
idle animation, 50-57 in 10 s shuffling). A Studio Play test with a client on the pad would confirm it.

A player who steps on the pad while the match is `Loading` isn't readied (`SetReady` refuses then, as on
main) and, unlike main, isn't readied later while still standing there: they step off and on, or press Ready.
