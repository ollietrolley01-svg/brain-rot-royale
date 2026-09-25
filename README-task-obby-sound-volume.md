# Branch `task/obby-sound-volume`

Jacob's fix for the coordinator's 0830 handoff, section 3: "The obby sounds in LobbyService bypass
the volume sliders." Cut from origin/main d1e4f73.

What changed from d1e4f73:

- `ServerScriptService/Modules/LobbyService.lua`: the Cloud Climb's creak, snap and checkpoint ping
  were Sounds the server made, so no player's slider reached them. `climbSound` now fires the
  existing `PlaygroundFx` remote with the kind and the part's position instead of making a Sound.
- `StarterPlayerScripts/CompanionFxClient.client.lua`: the `PlaygroundFx` handler plays the three
  kinds as Sfx cues (sound only), the way it already plays the ball kick.
- `ReplicatedStorage/Shared/SoundConfig.lua`: the three cues `ObbyCreak`, `ObbySnap` and
  `ObbyCheckpoint` on the Effects slider, with the same files, volumes, speeds and 100-stud reach
  the server Sounds had.
- `tools/sound_slider_check.py` (new): no game Sound bypasses the sliders. It sweeps every Sound
  creation site, boots the real CompanionFxClient and Sfx under lupa, and carries 6 planted faults.
  Run `python3 tools/sound_slider_check.py .` and `... --plant` (needs lupa).

How it sounds (the reach and level with distance changed slightly, see the PR) needs a listen on
Oliver's machine.
