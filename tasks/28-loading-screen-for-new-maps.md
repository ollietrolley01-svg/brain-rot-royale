# Task 28: a loading screen when a new map loads

**Files you own for this task:** a new `StarterPlayerScripts/LoadingScreenClient.client.lua`, and a new
check under `tools/`. **Read only:** `MatchService.lua`, `MapGenerator.lua`, `HudClient.client.lua`,
`VoteDropClient.client.lua`, `TeamPickerClient.client.lua`, `MenuCursor.client.lua`.

## What was asked for

Loading screens when the game loads new maps. Oliver, relayed by Jacob.

## What happens now

`MatchService` (line 1788) sets `state = "Loading"`, broadcasts it, and calls `MapGenerator.Build`
(line 1800), which takes a few seconds. The same state then covers the drop picker (`dropSelect`) or
the team picker (`teamSelect`). The only loading feedback is the HUD banner's "BUILDING MAP…" text
(`HudClient` line 4095). Players stand in the lobby while the map builds.

The place has `StreamingEnabled` on (`build_place.py` line 80). So after spawning, the ground and
buildings around a player can still be streaming in. Nothing waits for that or hides it.

## Default

A full-screen loading screen, drawn by a new client script, while the state is `Loading` and neither
picker is up. Show the map's name and the mode. Keep it on after spawning until the area around the
character has streamed in (`Player:RequestStreamAroundAsync` on the server, or the client checking that
the ground under it exists), for at most a stated time. Never cover the drop picker, the team picker or
the vote. Read the mouse through `MenuCursor`'s rules (#112) and don't write `MouseBehavior`.

## Conflicts

`pc/lag-bug-sweep` changes `MatchService` and `HudClient`, but this adds a new file and changes
neither. PR #64 (`task/device-compat`) is the phone and pad pass, so check the screen on a phone layout.

## Proof

Offline, with lupa: run the new script's show and hide rules against a mocked match-state stream: lobby,
Loading while building, Loading with the drop picker, Loading with the team picker, InProgress while
streaming, and InProgress once streamed. It must show only in the first and the fifth. Plant a fault (it
covers the drop picker) and show it goes red.

**How it looks and whether it hides the pop-in can't be proven offline.** It needs a Studio **Play**
test with a client through a whole match start, in battle royale and a team mode. The coordinator runs
it.

Status: ready to start
