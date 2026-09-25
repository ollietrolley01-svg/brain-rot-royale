FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: obby sounds now follow the volume sliders (PR task/obby-sound-volume); 1 more slider bypass found: Roblox's own character sounds
NEEDS: a listen to the three obby sounds on Oliver's machine; the character-sound item is the build machine's
BY:    not blocking (nothing here blocks a playtest)

1. **Fixed on `task/obby-sound-volume` (handoff 0830 §3).** The Cloud Climb's creak, snap and checkpoint
   ping were server-made Sounds (`LobbyService.lua:2667` on main), so no slider reached them. They now go
   through `PlaygroundFx` to `CompanionFxClient` and play as `ObbyCreak`/`ObbySnap`/`ObbyCheckpoint` on the
   Effects slider, at the same levels and speeds. `tools/sound_slider_check.py` holds "no game Sound
   bypasses the sliders", 6/6 plants caught. The fault was on main and on pc/lag-bug-sweep. **Needs a
   listen:** the rolloff now starts at 14 studs (was 10), and the sounds get the distance equaliser, the
   Effects bus compressor and ±3% jitter.
2. **Roblox's built-in character sounds bypass the sliders** (reasoned, not measured). The default
   character sound script makes Jumping, Landing, FreeFalling, GettingUp, Climbing, Swimming, Splash and
   Died Sounds on each player's body with no SoundGroup. `FootstepClient.client.lua:40-46` silences only
   `Running`, so the rest play at full level whatever the sliders say. A candidate fix is one client loop
   that sets `SoundGroup = Sfx.GroupFor("Effects")` on those Sounds as they appear.
