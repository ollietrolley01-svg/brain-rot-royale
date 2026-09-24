# Handoff: ditch fix + results screen (Oliver's session, 2026-09-22 16:10)

Worked alongside the bot/HUD session; did not touch BotService, BotNav, ModeScoreHud, or HudClient's banner/compass code.

- `ServerScriptService/Modules/Landmarks.lua` - `levelSite` rewritten. The terrace rings used to step DOWN a voxel
  per ring on every side and cut everything above them, which dug a 4-stud ditch round every levelled landmark (and a
  trench under a cliff on the uphill side). Rings now only move ground toward the pad: fill in steps where it's lower,
  cut in steps where it's higher, untouched where it's already level. Oliver: "there's this ditch around them that looks bad".
- `StarterPlayerScripts/ResultsScreen.client.lua` - NEW end-of-match screen (ScreenGui `BrrResults`): mode chip,
  BRAINROT CHAMPION / #N of M in BR, VICTORY / DEFEAT / DRAW + team scoreline in team modes, count-up stat tiles,
  reward chips (zero values hidden), countdown + Continue, confetti on wins, scales to phones.
- `StarterPlayerScripts/HudClient.client.lua` - ONE change: the MatchResults handler returns early when `BrrResults`
  exists, so the old card + champion banner stay as the fallback. Anyone editing HudClient: keep that guard.

All three compile (luau-compile). Not yet run in Studio. On GitHub main and on the PC.

## 16:2x - rivers (Oliver: "fix riverbanks and their steep cliffs and untextured beaches ... nothing left floating")
- `MapTerrain.lua` `River`: the vertical 180-stud box carve + buried 2-stud bank strip is replaced by a per-column
  profile of distance from the centre line (constants RIVER_* at the top): sand bed at -6, shore shelving through the
  waterline, a Sand beach out to width/2+14 rising to 1.5, then banks graded back to the natural ground (0.55 grade for
  20 studs, never steeper than 1:1). Pond end uses the same profile. Written in 128-stud tiles near the river only.
- Kept on their ground: road corridors outside bridge decks (verges blend into the valley via roads:GroundAt), the
  channel under each deck capped at road - 2.4, plateaus + ramps, and zipline landings (`plateau.landing`, new field set
  in Plateaus). Footbridge notch floor raised to +2.5 so it no longer trenches the beach.
- `MapWilds.lua`: bank grass patches moved out past the beach (width/2 + 16..26).
Compiles; not run in Studio.
