# Task 09: players can't un-ready in the lobby

**Files you own for this task:** `ServerScriptService/Modules/LobbyService.lua`, `buildReadyPad` and
its debounce only; `ServerScriptService/Bootstrap.server.lua`, the `LobbyService.OnReadyPad` hook
(line 438) only. **Read only:** `MatchService.SetReady`, the ready pill in `HudClient.client.lua`,
`VoteService.lua`.

## What Oliver saw

"i cant unready up". He wrote it twice in one message. Playtest, 2026-09-25.

## Where to look

There are two ways to ready up, and only one of them can un-ready you:

- The ready pill and the Ready key. `HudClient.toggleReady` (line 240) fires `SetReady` with the
  opposite of the current state, which goes through `RateLimit.Latest` (Bootstrap line 694) to
  `MatchService.SetReady` (line 381).
- The ready pad on the balloon deck. `LobbyService.buildReadyPad` (line 595) connects `pad.Touched`,
  debounced by `PAD_COOLDOWN` (1.5 s), to `OnReadyPad`, which calls `SetReady(player, true)`.

The likely cause is the pad. `Touched` fires again and again while a character stands on a part and
its feet move. A player on the pad who presses un-ready is set back to ready within 1.5 s. Nothing
checks whether the player stepped onto the pad, only whether they are touching it. Find out where
lobby players stand and respawn relative to the pad (`LobbySpawn`, the deck) before settling on
this.

A weaker candidate: `MatchService.SetReady` silently refuses a toggle within 0.3 s of the last one,
and the pill's own throttle is 0.35 s, so a double press can leave the pill and the server disagreeing
for a moment. Rule it in or out.

## Conflicts

`pc/lag-bug-sweep` changes `LobbyService` (the comment above `readyPadLastTouch`, `buildPitch`, the
PlayerRemoving handler), `Bootstrap` and `MatchService`. PR #61 (`task/obby-sound-volume`) and PR #64
(`task/device-compat`) also change `LobbyService`. None of them change `buildReadyPad`'s body, but
merge main and check again before you push.

## Proof

Offline, with lupa: run the real `buildReadyPad` Touched handler and the real `MatchService.SetReady`
with a mock clock. Script it: a player readies on the pad and keeps standing on it (Touched every
0.2 s for 10 s), and presses un-ready at 3 s. `Ready` must be false at 10 s. A player who walks onto
the pad from off it must still be readied, so the pad keeps working. Plant a fault aimed at that
invariant (an un-ready overwritten while nothing new happened) and show it goes red.

The mock assumes that `Touched` repeats for a standing character. That is Roblox behaviour, not
this code's, so state it as an assumption. A Studio **Play** test with a client standing on the pad
would confirm it, and the coordinator can queue one.

Status: ready to start
