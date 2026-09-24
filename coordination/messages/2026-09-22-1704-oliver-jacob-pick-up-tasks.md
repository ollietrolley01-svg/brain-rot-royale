FROM: Oliver (relayed by his Claude)
ABOUT: general -- tasks for Jacob
NEEDS: nothing, just telling you (a one-line claim back before you start, please)
BY:    not blocking

## From Oliver

> **tell jacob to do some of the tasks that you have not started on**

So, Jacob: here are items from `OLIVER_LIST.md` that nobody has started and that don't touch what
Oliver's sessions are working in today. Pick any, and drop a one-line message in this folder saying
which before you start, so two people don't build the same thing.

## Please stay out of these today (being changed right now)

Map and terrain (`MapGenerator`, `MapTerrain`, `MapDecor`, `MapWilds`, `Landmarks`, `TownThemes`,
`TownKinds`), the HUD (`HudClient`, `ModeScoreHud`, `ResultsScreen`, `MenuStackToggle`), bots
(`BotService`), match flow (`GameMode`, `ModeKingOfTheHill`, `MatchService`), and `MenuClient`.
If an item below turns out to need one of those files, say so here instead of editing it.

## Good self-contained picks

**Guns and first-person**
- #11 Arm joints look disconnected on long rifles in first person.
- #26 Hands: bend the fingers so they don't block the crosshair.
- #30 Make gun tracers more visible.
- #72 Random floating text on some gun textures in first person.
- #87 Make the grenade launcher throw grenades further.
- #7 The potion-drinking animation clips into your face.

**Vehicles (looks, not physics)**
- #61 The Ranger still has random poles sticking out.
- #116 Bat parts still sideways on the Sahur RV and the Ranger.
- #51 Old road cars can't be destroyed (cause is known: their parts are literally named "Part").

**Throwables and destruction**
- #63 The throwable preview stays around after the throw.
- #69 The sticky bomb's remote detonator stays in your hand.

**Other**
- #45 Make the storm brainrot-themed.
- #42 Revamp the other low-quality easter eggs.
- #67 Move the companion to the character's left side.
- #76 Compounding playtime awards, and #77 daily streak awards (`ProgressionData` is free).
- #103 People can jump off the edge in the lobby.
- #117 Lobby trial guns change on every pickup.

## Needs Oliver's answer first, so leave these

#64 and #111 (shotgun nerf / time-to-kill: balance calls), #91 (tom pearl: the concept goes to Oliver
before it's built), #56 (whole map destructible: a big design job), #121 (bigger maps: part-count limits).

## The usual rules

Work on a branch and open a pull request; don't push to `main`. One idea per pull request, name every
file you touched, and say what you couldn't test. Full version: `coordination/README.md`.
