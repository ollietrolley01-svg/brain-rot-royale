# Brain Rot Royale

A 50-player battle royale FPS built around collecting, trading and selling brainrots. Win
the match, take home a Legendary Crate.

Everything is generated at runtime — the lobby, all five maps, every building and all the
loot. There is **no manual Workspace building** and nothing to install.

---

## Quick start

Open **`BrainRotRoyale.rbxlx`**, press **F5**, then click **READY UP** next to the banner at
the top of the screen.

The place file already contains every script in the right service as the right instance
type, plus Lighting and Workspace settings. `MinPlayers` is 1, so one readied player starts a
real match with 49 bots filling the lobby (`MaxPlayers` and `BotFillTarget` in
`Shared/MatchConfig.lua`). When you publish, set the place's **Max Players** to 50 in Game
Settings too — the file can't set that for you.

After editing any `.lua` in this folder, rebuild with:

```bash
python build_place.py .
```

Close the place in Studio **without saving** first — Studio holds its own copy in memory and
saving would write it back over your changes.

---

## Checking a build

Studio's edit mode never runs scripts, so three scripts in `tools/` do the checking:

```bash
python tools/verify.py .
```
Data and wiring consistency — brainrot looks against the model vocabulary, crate odds and
defaults, cosmetic rarities and prices, bundle contents, every client remote handled on the
server, no require cycles, no local function used above its definition. Exits non-zero on a
problem, so chain it before the build.

It also counts **locals in each script's main chunk**, because Luau allows only 200 per function
and a script's top level counts as one. Nothing else in the pipeline can see that limit: it isn't
a structural imbalance, so `balance.py` passes the file, and it only fails when Luau itself
compiles it — a seven-minute round trip through the harness, which reports it as a bare
`1 failed` unless you remember to grep for `SYNTAX`. `HudClient` reached 202 this way and stopped
compiling outright. The check flags anything at 195 or above, leaving a little headroom. The fix
when it fires is a `do ... end` block: locals declared inside one are released at its end, so only
what you deliberately expose survives into the main chunk.

```bash
python tools/balance.py .
```
Block balance (`do`/`end`, `function`/`end`…) per file.

```bash
powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -MapId SahurSprings
```
A runtime smoke test: installs a temporary local Studio plugin, opens the place, switches it into
Run mode, compiles every script, builds the map with loot, spawns ten bots with combat on, sets
off an explosive barrel beside one, arms a Rot Mine beside another and checks it stays inert for
its arming second and a half then goes off underfoot, drops three more bots in under canopies and
checks they land, builds the three portable defenses and shoots one down, has a bot throw up a barricade, kills
nine bots with nine different guns and checks each body did what its gun's kill effect says
(ragdoll joints released and the body down, the frozen one still, the floated one risen,
everything hidden afterwards), captures everything the Output window printed and removes the
plugin. Takes about seven minutes; the only way to see runtime errors without a manual playtest.

Every Studio-driving script (`runtest.ps1`, its `-Probe` mode, `gallery.ps1`) is safe to start
while Studio is open and while other sessions are working on the project. Each one waits for a
machine-wide lock (`tools/studio_lock.ps1`, a named mutex, so a killed run can't leave it stuck;
a waiting run prints who holds it). It then opens a private snapshot of the place
(`BRR_RunTest.rbxlx` / `BRR_Gallery.rbxlx`), and its plugin checks the place name and does nothing
in any other Studio window. At the end it closes only its own window. `build_place.py` writes to a
temp file and swaps it in, so two builds at once can't corrupt the place. Studio doesn't reload a
rebuilt file, so reopen the place to see a new build.

It also shoots a wall down — 40 damage leaves it standing, 100 more finishes it and the tracking
entry is dropped — and checks the firing range put a take prompt on each Legendary podium and
registered its remotes. Both assert the numbers rather than just that nothing threw: the wall's
second hit should report 60 dealt, not 100, because only 60 of its 100 was left.

Two more checks guard failures that are silent rather than loud, which are the ones worth
automating:

- **Sliding** sprints a bot, slides it, and reads the composed walk speed back. The burst is a
  factor inside the routine that builds speed from base, boost and sprint, so the only way to
  know it survived is to watch the number rise and fall back. It also confirms a second slide is
  refused while on cooldown.
- **Sights** builds every gun and checks each against the ADS contract (`KP_Sight`, `Optic`,
  `EyeRelief`): the contract is present, the sight hardware (front post top or bead, red-dot/holo
  dot, scope axis) sits within 0.5 mm of the aim line, the line runs within 0.05° of the bore,
  and nothing opaque stands in the line from the eye — including a rear sight with no notch, and
  including a scope's own glass. All three counts want zero, and a self-test makes a scoped gun's
  lens opaque to prove the check still catches one. The viewmodel puts that line on the crosshair
  by construction, so these are the only ways a gun can aim somewhere other than where you point.
  Rays are traced analytically because Roblox raycasts pad millimetre-sized parts by several
  millimetres. `tools/ads_align_probe.lua` is the per-gun version (with planted faults of its own),
  `tools/gun_gaps_probe.lua` finds parts floating off a gun's body, `tools/gun_flush_probe.lua`
  what z-fighting the model's nudge pass left behind, `tools/gun_anim_probe.lua` whether a gun
  carries the moving parts and keypoints its mechanism needs, `tools/ads_hands_probe.lua` whether
  the hands or the gun cross the crosshair, and `tools/ads_gallery.lua` renders every sight picture.
- **Bot animation** checks every track loaded and that bots carrying a gun are actually playing
  the hold pose. It carries a trap worth knowing before you add any check about bot *behaviour*:
  the harness spawns bots but does not start their think loop, so `updateBot` never runs and bots
  are static mannequins moved only by the harness's own direct calls. Animation, wandering,
  repathing and heal cadence are all driven from that loop, so all of them read as dead unless
  you call `BotService.Start()` first and wait a beat. Run that check **last**, after everything
  else in the run. A live loop keeps driving bots, which disturbs any check that moves them by
  hand (the mine and slide tests) and any check that measures them settling — starting it before
  the death effects dropped the ragdoll's head fall from 6.3 studs to 2.5 and failed its
  threshold. There is no `BotService.Stop()`; the only thing that clears the flag is
  `BotService.Clear()`, which also destroys every bot, so the loop cannot be paused once
  started. A pose that was
  simply never executed looks exactly like a pose that is broken, and that cost four wrong
  diagnoses before the loop turned out to be the answer.

It also audits placement, so "nothing clips" is measured rather than hoped:
- **Map clipping** — every solid part on the map is probed with a slightly shrunk copy of its
  own shape (`GetPartsInPart`, real geometry rather than bounding boxes) against the solid parts
  of every *other* thing (another building, a landmark, a prop, the river's bridges). Overlaps
  inside one thing are how it's built; across two they're mistakes, and the log lists each pair.
  A second pass lists solid parts whose top is under the terrain surface, with an example per
  owner.
- **Lobby clipping** — the same, between the island's set pieces (every part carries a `Group`
  attribute naming the piece it belongs to).
- **Z-fighting** — see below: how many parts the build's own pass had to nudge and in what
  patterns, and whether anything is *still* flush afterwards, for the map, the lobby, the loot,
  the defenses, every gun, every crate, every item, every brainrot and every accessory, plus
  every landmark and easter egg built in a row off the map's edge (`Landmarks.BuildAll`,
  `EasterEggs.BuildAll`) so the whole pool is checked in one run.

One thing to know about it: the plugin's `require` of a game module gets its own copy of that
module, separate from the one the running server scripts use. So hooks Bootstrap sets (like
`CombatService.OnDeathFx`) are unset in the plugin's copy, and the harness calls the services it
tests directly.

```bash
powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/zfight_probe.lua
```
The quick version: runs one Lua file inside the temporary plugin in edit mode (no Run mode,
about 75 seconds) with the same Output capture — for poking at a builder or a module without a
full run. `tools/zfight_probe.lua` builds a crate, a chest, two guns and two brainrots and
traces what the z-fight pass does to them; `tools/terrain_probe.lua` measures where Roblox
puts the terrain surface for each kind of fill; `tools/display_paths_probe.lua` builds every gun
through the real floor-pickup and lobby-podium code and measures each part against a reference
build (anything moved, turned, resized or missing).

The z-fight audits all measure the same way, because a builder's own pass hides its faults: the
model is built once with `ZFight.Enabled = false` (the geometry as written) and once as the game
builds it, and the two are diffed part by part — a clean model has no flush pairs as written and
nothing the pass had to move. `tools/audit_items_zfight.lua` does every item at every scale it
is built at and every crate CrateData sells; `tools/audit_guns_zfight.lua` every gun at both
detail levels, at the gun-scale tolerance; `tools/audit_defenses.lua` the three deployables,
plus a see-through ray grid for holes a bullet would pass through; and for the lobby, where
`LobbyService.Build` runs the pass over three thousand parts, a written-pairs probe builds it
with the pass off and prints BOTH parts of every fighting pair with sizes and positions — the
form a fix needs (`tools/audit_lobby.lua` counts what the pass moved). Every one runs a planted
fault on every run. The galleries that show rather than count are `tools/arena_gallery.lua`
(the practice dummies, their ragdoll — which needs Run mode, since edit mode runs no physics —
and the client effects driven by the real GunFx, ExplosiveFx, HitSplatClient and StormClient
with the server's remote swapped for a local event) and `tools/crate_gallery.lua` (every crate
from the card's angle, measured with the pass off as it is drawn).

Three more probes exist because this codebase fails silently at exactly one thing: loading
assets. Sound cues and bot animations are looked up by id or by name, and
every one of those lookups is wrapped in a pcall that drops failures without a word — a wrong id
is not an error, it is simply no sound and no animation. Two cues had been dead that way for
some time. So none of it is assumed:

- `tools/sound_probe.lua` loads every candidate `rbxasset://sounds/` file and reads its length
  back, then checks every id `SoundConfig` actually uses. It is what found that 23 files ship,
  not the 11 the code believed.
- `tools/anim_probe.lua` does the same for animation ids, with the three ids bots already use as
  controls — if those fail, the probe is wrong rather than the candidates.
- Gun sights used to be found the same way, by part name, and `tools/sight_probe.lua` reported
  which anchor each gun matched. Guns now carry their sight line on the model itself (see
  *Weapons → Sights*), so nothing is looked up. `tools/ads_align_probe.lua` measures it instead,
  and `verify.py` checks that every gun's flash, tracer and sound cues exist.

Merging has its own pair. `tools/merge_probe.lua` drives the real `RewardService` with a stand-in
player: every star step and what it costs, refusals (no spares, maxed, unknown name, mid-trade, a
stale second confirm), that the rest of the collection keeps its order, the SELL 1 / SELL ALL
guards, stars surviving a sale, and that a save from before merging existed loads with its coins,
brainrots, crates, XP and pity untouched. It never calls `PlayerData.Release`, which would save
the stand-in profile. `tools/merge_gallery.lua` (run through `gallery.ps1`) screenshots the real
confirmation card at several rarities and in its busy, refused and merged states, plus a glyph
sheet proving ★ ☆ • — ✓ × draw in GothamBold, Gotham, FredokaOne and rich text.

The map's parts are named for what they are (Wall, Floor, Sill, Cornice, Plinth, Kerb, Asphalt,
Dash, Paving…) rather than "Part", so both reports say which piece is at fault.

### Nothing flush: the z-fight pass

Two faces in the same plane, facing the same way, flicker against each other as the camera moves
(a trim set exactly level with its wall, a floor ring whose top is the floor's own height, a badge
sunk into a crate until its front is flush with the body, a slab whose top sits right at the
ground's surface). Everything here is built from parts by code, so instead of trusting every
offset, `Shared/ZFight.lua` checks the geometry itself: it finds every such pair among the
visible parts and settles them apart until there's a clear gap (`ZFight.Gap`, 0.06 studs —
invisible, and enough). Blocks and cylinders grow the fighting face outward rather than moving,
so a band round a body widens on both sides and a strap between a body and a lip clears both,
and because faces only ever move outward the pass can't shove a part back and forth between two
neighbours. Wedges grow across their width and otherwise move. A whole stack of coplanar plates
settles in one pass. Tops sitting at the terrain's surface are lifted off it. It acts on
anything closer than 0.055 studs (`FixTolerance`) so nothing it leaves can be tipped back under
the 0.045 the audit checks (`Tolerance`) by float rounding out at the lobby's coordinates.

It runs once over the whole map at the end of `MapGenerator.Build` (about two seconds for a
13,000-part map, inside the Loading state), once over the lobby after `LobbyService.Build`, and
inside every builder before its welds go in (guns, items, crates and chests, brainrots,
accessories, defenses, supply crates, launch pads, pickups, podiums), so it covers anything
those builders make later — a dropped gun, a companion, a crate opening in the menu. Parts it moved carry a `ZFixed` attribute (how far) and `ZFixedWith` (what they fought),
which is what the harness reports; the aim of that report is to keep tidying the sources so the
pass has less and less to do, and to prove nothing is left flush either way.

**Why the sources have to be tidied, and not just left to the pass.** A builder that leaves flush
faces doesn't produce flickering — it produces a model that isn't the one that was written, because
its own pass reshapes it on the way out, and the result still looks like a thing so nobody notices.
Measured with the pass switched off (`ZFight.Enabled = false`) and diffed against the built model:
the Speed Soda came out 0.22 studs taller than written with its ring pull ten times its own
thickness, every one of the Med Kit's thirteen parts was moved or resized, the map chest had 58
pairs of faces lying flush and all 56 of its parts were shifted, and the Daily Spin's wheel had 153
parts pushed apart, one of them by 0.63. So: **measure the diff, not the flush count.**

Two rules make the tidying tractable. Only faces pointing the SAME way fight, so a part resting
exactly on another (a rim on a can's end, a handle bar on its posts, a stave butted to the lid it
sits on) is free — and so are two coplanar parts that merely share an edge, because the overlap test
ignores anything under `MinOverlap`. That is why a cross is built as a bar with a stub butted on each
end rather than two bars crossing through each other, and why a hazard marking is a row of tiled
diagonal bars rather than two plates at the same depth. And the separation has to clear
`FixTolerance`, not `Tolerance`: 0.06 passes the audit and still gets moved by the pass. Everything
here is built to **0.07 at the smallest scale the model is ever built at** (items build from 1.0 up
to 3.0, so 0.07 at scale 1 holds everywhere).

---

## The loop

1. **Lobby** — a marble plaza ringed by display podiums. Nobody is pulled into a match until
   they hit **READY UP**; stay unreadied and you can hang out, trade and show off in the lobby
   for as long as you like. Once enough players are ready (`MinPlayers`, 1) a 15s countdown
   starts and three maps go up for a vote — and if everyone unreadies, it cancels. When every
   player in the server is ready, the countdown skips down to 5s. Who plays
   is locked in when loading begins, and your ready choice carries over between matches, so
   people who played re-queue automatically and lobby-stayers are never respawned or moved.
   Readied players get a green **READY** tag under their name while they're in the lobby.
2. **Choose your drop, then spawn** — once the map is built, a 15-second window puts the whole
   map on screen with its towns and landmarks named: click anywhere to pick where you land.
   Ignore it and you keep the spot the sunflower spiral gave you, spread across the whole map —
   on a 950-radius map that's ~250 studs between neighbours, so nobody opens the match already in
   a fight. Either way you come down *on the ground*, under a canopy.
3. **Loot** — Common and Uncommon guns lie on the ground; the Rare/Epic/Legendary guns with
   abilities are chest-only, inside buildings. Chests also hold ammo and heals.
4. **Fight** — the storm closes in five phases, scaled to the chosen map's size. Its wall is a
   hollow purple ring drawn client-side (`StormClient`), so the view inside the zone stays
   clear — no fog film over the ground — and it glides smoothly as it shrinks. There's no
   Atmosphere in the place either, and Bootstrap zeroes one at runtime if Studio adds it back.
5. **Place** — rank locks in the moment you die. Dying puts you in **spectator mode**, not
   back in the lobby.
6. **Cash out** — placement pays a **loot crate**, SahurCoins and Brainrot Pass XP. Take #1 and
   a **BRAINROT CHAMPION** banner pops up with confetti raining down the screen.
7. **Show off and trade** — back in the lobby, put your best brainrot on your podium and
   trade with anyone in the server.

The map's name (and the event, if any) sweeps across the screen as the match begins.

**Choosing where to drop.** The map is generated before anyone is placed, and that gap is the only
moment when a real map exists and nobody has a body yet — so the drop window sits exactly there,
at the end of the `Loading` state. It can't go in the lobby countdown instead, because the map
hasn't been built then and there'd be nothing to choose from. The server holds for
`DropSelectSeconds` (15), broadcasting a `dropSelect` flag and a countdown on the state it already
sends, then places everyone. Owning the countdown there is safe: the one-second ticker in
`MatchService.Start` has no branch for `Loading`, and `startMatch` runs synchronously on that very
thread, so nothing else touches it meanwhile.

The pick is validated server-side rather than trusted — the window has to be open, you have to be
someone the match is about to place, and the point has to be a real number inside the playable
disc, with an out-of-bounds click pulled back to the rim rather than refused. No new match state
was introduced for this: the phase stays `Loading` with an extra flag, because the HUD banner and
the client's combat check both gate on the state string and an unrecognised value would break them
quietly. Costs 15 seconds on match start, which is the trade the feature asks for.

**The drop.** A match opens with everyone 170 studs up over their spawn under a canopy, falling at
a steady 26 studs a second and steering with WASD — a view of the whole map and the landmarks
before you pick a doorstep. Touching down ends it. `DropHeight` is in `Shared/MatchConfig.lua`.
**Bots drop in too**: fifty canopies open across the sky at once, each bot steering for the
outskirts of the nearest town or landmark (the second nearest now and then), and its AI takes
over the moment its feet touch down (`MovementService.BotDrop`, steered from the server since a
bot's body is simulated there).

**Match events.** Seven matches in ten roll a modifier (`Shared/MatchEvents.lua`), announced on the
banner and in a toast when the map loads:

| Event | Effect |
|---|---|
| Loot Frenzy | three guns in every chest, a supply drop every minute |
| Bounty Rush | bounties from the first kill, paying double |
| Rot Rush | everyone moves 20% faster |
| Shield Up | everyone drops in with 50 shield |
| High Stakes | placement coins pay 1.5x |
| Night Ops | lights out: the map's time of day overridden to night, so street lamps, muzzle flashes and neon are what you see by |
| Low Gravity | half gravity for the match — higher jumps, slower falls, every rooftop reachable |
| Zone Rush | the storm's phases run half again as fast |
| Hot Drops | a supply drop every 45 seconds, the first 20 seconds in |
| Headhunter | every headshot deals double, on top of the gun's own multiplier (bots' too) |
| Aura Farm | every chest's first gun is rerolled until it's at least Epic |

**When you go down** a **death recap** sits under the banner while your body hits the floor: who
did it, with what, from how many studs, whether it was a headshot, how much health and shield
they had left, and where the last twelve seconds of damage came from (up to three sources).
The results card adds your accuracy (hits over shots, pellets counted), headshots, longest
elimination and damage taken.

New players see the basics rotating on the lobby banner until they've played a match.

**Streaks pay.** Rapid consecutive kills escalate — DOUBLE, TRIPLE, QUAD, RAMPAGE — and each step
pays 50 more coins than the last, up to 200 for a rampage.

**Bounties.** Once someone has three kills and leads the match, a bounty goes on their head:
everyone is told who and how much (200 coins + 75 per kill, rising as they keep killing, shown
under the minimap), and whoever eliminates them collects it. Bots never carry one.

Between matches there's more to grind than placements: **daily quests** and **weekly
challenges** (three a day plus two a week, with crates for the set and for every weekly), the
**Daily Spin**, goals on the lobby pitch and the Cloud Climb — see *The lobby* below — and, for the
long haul, **Rot Rank, prestige, gun mastery and the Rot Index** (see *Rot Rank, mastery and the Rot
Index*). Your Rot Rank shows in gold beside your name on your nameplate, led by a prestige star once
you have one, and the Pass tab opens with your record: level, wins, kills, matches, kills per match,
titles unlocked and collection value.

### Respawn modes: Team Deathmatch and King of the Hill

Every few matches the rotation (`Shared/GameModes.lua`, `GameModes.FromRotation`) runs a respawn
mode instead of the battle royale (`Modules/GameMode.lua`, `Modules/ModeTeams.lua`,
`Modules/ModeKingOfTheHill.lua`). **Team Deathmatch** is first to **100 team kills** or 8 minutes;
a death to the world (falling, the arena edge) pays the other side, so nobody stalls by dying to
it. **King of the Hill** scores a point a second for the side holding the hill, to 250. Nobody is
eliminated: a player who dies is back **5 seconds** later on one of their side's pads with a fresh
green kit and **3 seconds** of spawn protection; a bot that dies is replaced on its side 5 seconds
later. A death here drops no loot and pays nothing — deliberately, until the reward rate has been
measured against the battle royale's.

The **arena** is a circle of half the map's radius, between 450 and 650 studs (it was 280–380,
one town's worth, and far too small for fifty combatants), centred on the first town; the storm
ring draws its edge and never shrinks. Each side's base sits on the opposite side of the centre,
0.72 of the radius out on an axis rolled per match, with five pads within 30 studs of it, each on
real ground, out of the river and clear of anything solid. A respawn takes the pad furthest from
the nearest enemy and refuses any pad with an enemy within 90 studs or in its line of sight —
and when every pad is refused it takes the least bad one **at once**, under protection, rather
than waiting: `LoadCharacter` stands a fresh body on the lobby's spawn pad, and the old one-second
retries left a player watching the lobby for up to four seconds. Two things `MatchService` does on
every match body, found the hard way: it arms the death watcher on the respawned body (nothing
did, so a respawned player's next death reached nobody and they stayed dead), and it builds a
respawn mode's arena before the first spawn, so the opening placement finds pads.

### Placement rewards (they do **not** stack — your bracket's crate only)

| Place | Crate | SahurCoins | Pass XP |
|---|---|---|---|
| 1st | **Legendary Crate** | 2,500 | 900 |
| 2nd – 5th | **Epic Crate** | 1,200 | 550 |
| 6th – 10th | **Rare Crate** | 600 | 340 |
| 11th – 20th | **Uncommon Crate** | 260 | 190 |
| 21st – 30th | **Common Crate** | 100 | 90 |
| 31st – 50th | **Common Crate** | 60 | 60 |

Paying a crate rather than a fixed brainrot means every placement ends on a roll — a
Legendary Crate is only 42% to produce a Legendary or better, and 8% to reach Mythic.

Kills pay 75 coins / 60 XP (40 / 32 for bots).

---

## Maps

Five presets, voted on in the lobby. Ground is real Roblox **Terrain** with rolling hills,
not a flat slab, and each preset has its own material palette.

| Map | Radius | Terrain | Character |
|---|---|---|---|
| Rot Ridge | 880 | Rock | Cramped rocky basin, heavy cover, fastest storm |
| Tralala Town | 950 | Ground | Dense downtown grid — tall, tight, rooftops matter |
| Patapim Plains | 1150 | Leafy grass | Farmland ringing one big central town |
| Sahur Springs | 1280 | Grass | Rolling grassland, six villages, long sightlines |
| Bombardiro Bay | 1480 | Sand | Sun-bleached coastal sprawl — sniper country |

Each map generates:

- **A continuous height field under everything** (`MapTerrain.Relief`): the map used to be a
  dead-flat slab with hills dropped onto it, so anywhere a hill hadn't landed read as a billiard
  table — which was most of it, and raising the hill count didn't change that. The ground is now
  three octaves of Perlin noise written straight into the voxels as fractional occupancy, in
  128-stud tiles, so the surface comes out smooth rather than stepped.

  **Tuning it is the part that went wrong twice.** Perlin noise almost never reaches its own
  extremes — a single octave typically lands within about a fifth of its nominal range — so the
  first attempt's 560-stud wavelength at nominal amplitude 22 produced real swells of roughly nine
  studs over five hundred. That is a two percent grade: genuinely rolling ground, and completely
  invisible from anywhere you stand. It now runs at 300/150/65-stud wavelengths and 30/10/4
  amplitude. The harness measures the result directly (`relief:` in a run) rather than counting
  features, because a feature count reads identically for real hills and for a billiard table.

  Two things shape it. It is
  biased upward so it almost never dips below y = 0, because the river, its bridges and the lakes
  all carve to fixed heights near zero and ground below them would leave water hanging in mid-air.
  And it fades to exactly flat over every town, so streets and buildings still meet level ground;
  towns end up sitting in shallow basins, which is where towns tend to be anyway. Writing
  occupancy still obeys `SurfaceLift`, and assuming otherwise cost a whole build. The reasoning
  that failed was that a linear occupancy ramp through the transition voxel lands the isosurface
  exactly on the target, so no correction is needed. It doesn't, because there isn't always a
  transition voxel: over a town the target is 0, which falls precisely on a voxel boundary, so the
  column is solid to the boundary and empty above — a hard cut, which is the very case the 2-stud
  lift describes. Town ground came out at 2 instead of 0 and the harness found 67 buried parts,
  mostly building steps sitting under their own ground. Every target is written the lift under the
  height it wants, like every other fill here. The base slab is 72 studs
  thick rather than 16, so a dip can't punch through it into the void
- **Real ground** (`Modules/MapTerrain.lua`): hills, ridges, craters and dunes on top of that
  height field — each one placed at the height of the ground actually under it rather than on a
  plane at zero — a quarter of them
  **ridges** (five domes in a line with a rock cap on the big ones), one in seven a **crater**
  with a pool of water in the bottom, **dunes** on sand, rock caps on anything tall, with a
  **snow line** over the highest ground, patches of other material painted across the open
  ground so it isn't one texture, and Terrain **clouds** overhead with a cover per map. All of
  it keeps clear of the towns, the roads and the plateaus — the gap allows for a hill's whole
  footprint, not just its centre, so no building or road ends up half-buried. Low mounds keep a
  much smaller distance from towns than ridges do, which is what stops the ground between and
  around towns running dead flat. One consequence worth knowing: `MapDecor.Prop` samples the
  ground once, at a prop's centre, and props are up to 16 studs across, so on a gentle slope the
  uphill side of a wide rock or bush sits slightly under the surface. The harness's buried check
  reports those, a few parts per map at most and not on every map. Making props sample the
  highest point under their footprint instead would clear the report but leave trees floating on
  their downhill side, which looks worse than a rock bedded into a hillside
- **A river** that winds from one edge of the map to the other (or ends in a pond where it
  can't get through), cut into the ground with real water, notched through any hill in its way,
  with **bridges** where the roads cross it, footbridges and stepping stones elsewhere, and loot
  along its banks. It's drawn on the minimap too (`RiverPath` attribute on the map). Its channel is
  carved to a **fixed** height while the ground around it is not, which is a trap worth knowing:
  the carve used to clear 68 studs, ample when every hill stood on a plane at zero, but the relief
  pass puts ground up to 60 *under* those hills and they stack on top of it. A map now measures
  about 127 at its ceiling, so the old carve left a lid of land over the water instead of a gorge
  through it wherever the river met high ground. It clears 180 now, and the harness counts how many
  river points are roofed over (`river cover:` in a run) — nothing else would notice, because the
  river reports its points, crossings and part count identically either way
- **Plateaus** — flat-topped tables of ground with loot on top and **ziplines** down off the
  edge
- **Ziplines** (`Modules/ZiplineService.lua`): hold **E** at the handle and you ride the line
  hanging under it at 54 studs a second; jump to let go early. Plateaus, Signal Hill, the Rot
  Bowl, the Beacon, the Farmstead's silos and the Sigma Spire's roof all have them
- **Roads** (`Modules/RoadNetwork.lua`) join every town into one network laid out on the same grid as
  the towns' own streets. A road leaves a town straight out along one of its four street ends — the
  street runs right out to meet it, and the road carries on at the same 18-stud width and the same
  height, asphalt butting asphalt, with the pavements tapering away beside it — runs on past the edge
  of town, crosses country in straight runs joined by square bends, and meets other roads at
  **T-junctions** and **crossroads**. Nothing ever joins at an angle, which is what lets every joint be
  exactly flush rather than nearly.

  **Planning.** Towns are joined nearest pair first until the network reaches all of them, then a
  few extra roads go in where the network sends two towns the long way round. Each road takes the
  cheapest route it can find (its length, plus a cost for each bend, less a little for crossing
  another road) out of every shape that fits: an L with one bend, a straight run or a Z with two, or
  a U round the back, from any free street end to any other. When a town's street ends are all
  taken, the road runs into an existing road at a T instead. Every route obeys the same rules: it
  stays 20 studs off every town's footprint and runs 40 clear of its own before it may turn; bends,
  junctions and crossings stay 80 studs apart, so each has room for its markings and furniture;
  parallel roads keep 110 apart where they overlap; and nothing leaves the map. Towns themselves are
  now placed with 140 studs of clear ground between their footprints: left to chance, two towns'
  streets and blocks overlapped on between a third and three quarters of maps.

  **Flat ground under every road.** Each road gets a height profile before any terrain is written:
  the ground along it averaged over a few dozen studs, held to a 10% grade and to a vertical curve of
  radius 1000 (about half a degree between neighbouring slabs, so no crease shows), dead level for
  26 studs past every junction box, and dead straight across every bridge (the river's course is
  planned before the ground is shaped for exactly this). Junction heights are relaxed against each
  other until every stretch between them, bridges included, can meet both limits exactly. The
  relief pass then writes the ground to the road in the same voxel pass as everything else: flat at
  the road's own ground height across the carriageway, a 3-stud shoulder and 8 more studs each side,
  blending back into the natural ground beyond as a cutting or an embankment whose width grows with
  the height it has to make up, with asphalt painted under the carriageway and gravel along the
  shoulders so grass never grows up through a road. The 8 studs matter: smooth terrain draws its
  surface through the neighbouring voxels too, so a bank starting right at the shoulder bent the
  shoulder up or down with it. So does the **material**, which is easy to miss: measured over
  flat voxels, Asphalt, Glacier, Grass, Ground, LeafyGrass, Limestone, Mud, Salt, Sand, Sandstone
  and Snow lie exactly where the voxels put them, but Rock (±1.1), Basalt, Ice, Slate and CrackedLava
  draw a rough surface over the same voxels, Pavement snaps it to whole studs, Concrete to twos,
  Brick and WoodPlanks down to the voxel below, and any of them disturbs smooth ground beside it for
  a few studs (`tools/road_terrain_probe.lua`). Only smooth materials go under a road, on its
  shoulders or on the flat beside it (`RoadNetwork.SmoothMaterials`): a Rock map's verges are
  earth, and patches or rock caps laid over a corridor are painted back. Hills, landmark sites and lakes go on after the relief pass, so that
  flat corridor is written again twice (`MapTerrain.RestoreRoadGround`): once the hills are down, and
  once everything else is, leaving the river's channel under each bridge alone. The road's top
  stands 0.4 over that ground, exactly as a town street does.

  **Flush joints.** A road is a run of slabs whose top faces meet edge to edge at every profile
  sample (stretches of the same grade merge into one slab), so a change of grade is a crease, never a
  step, gap or overlap. Where the grade changes the slabs' lower corners would share side and bottom
  planes, which the z-fight pass reads as a fight and "fixes" by growing faces — that is what used to
  fatten edge lines into raised white blocks — so every other slab is 0.07 narrower each side and
  shallower, and neighbours never share a plane. Junctions and bends are one level box of asphalt the
  arms butt against (`MapDecor.Junction`): a side with no arm gets its edge line (or in town its kerb
  and pavement) straight across, and the inside lines of a bend run on round to meet. Markings lie
  *on* the asphalt, never sunk into it, and are laid onto whichever slab they cross so they follow
  the surface exactly: unbroken edge lines, a dashed centre line, and at every controlled approach a
  stop line across the arriving lane and a solid double centre line.

  **Traffic lights and stop signs.** Crossroads get **traffic lights**: on the far right-hand corner
  as a driver arriving along each arm sees it, a pole with a mast arm hanging a signal head over that
  driver's lane, and a second head on the pole. Approaches along one axis get green for 9 seconds and
  amber for 2.5 while the other axis waits on red, with a 1.5-second all-red between; every junction
  has its own phase, so neighbours don't all change together. The lamps carry their timing and
  colours as attributes and `TrafficClient` lights them from the server clock, so every player sees
  the same light and the server replicates nothing. The stem of a T gets a **stop sign** on its near
  right — a red octagon (a band, two blocks and four wedge corners) with a white border and STOP
  across it. In town, the junctions where the back streets meet the cross street get lights when all
  four streets were built and an all-way stop when three were, with a zebra crossing and a stop line
  on every arm. Traffic drives on the right.

  **Bridges.** Where the river crosses a road the road lays its surface and markings straight across,
  and a stone bridge is built under that stretch at the road's own height and grade
  (`MapDecor.Bridge`): a deck, parapets with coping and lamps, and piers standing upright into the
  river bed. On high ground that is a bridge over a gorge, not a road dropping into it. Crossings of a
  winding river close together become one longer bridge, and the river keeps well clear of
  junctions and street ends. A bridge's height is fitted, not guessed: the first of a graded bridge
  with 20 studs of straight road either side, the same level, or level across the span alone, for
  which the road can climb from the junctions either side to the bridge's height and grade within the
  grade and curve limits, with the deck clear of the water (`roads:` in a run reports which each
  bridge got).

  **Around the roads.** Lamps down alternate verges, a fingerpost on a corner of every junction (a
  board per arm naming the nearest town that way) and just outside town on every road naming where
  it goes, and cars and bikes parked on the verges. Road parts don't collide — you walk and drive on
  the terrain shaped flat under them — but answer raycasts, so a supply crate lands on a road rather
  than in it.

  **Checks.** `RoadNetwork:Audit` measures a built map (`roads:` in a run, and every
  `tools/road_gallery.lua` view): it walks every road a stud at a time across both lanes, from
  junction centre to junction centre and on into the town street at each end, and reports **gaps**
  (points no surface covers) and **steps** (neighbours whose tops differ by more than the grade
  allows), the road top over the terrain (0.40 wanted; how many points have terrain poking through
  or the road floating), the steepest grade, the sharpest crease and how far slabs cross in the
  deepest dip, and every road, street or square part sharing volume with another.
  `tools/road_audit_all.lua` (a `runtest.ps1 -Probe`) builds five maps on two seeds each and holds the
  roads to three rules: every place two road, street or square surfaces touch is a planned joint
  (slabs along one road, an arm butting its junction piece square-on, arms meeting only at the
  corner of the junction piece between them, a road carrying straight on from its town street, a
  street into its square), with anything else counted as a failure; the terrain within 0.25 of the
  road's ground every 2 studs along and across the carriageway and shoulders; and no water under a
  road without a bridge deck over it. It also looks for open water off every lake's dock. `verify.py` checks
  the contracts between the files: the road and street widths match, the client reads exactly the
  attributes the lamps are given, the build runs in the order the roads depend on, markings are never
  sunk, and none of the old road builder comes back.
- **Three building archetypes** — houses (pitched roofs, gables), towers (3–5 floors with
  parapet rooftops you can fight on), warehouses (big open span)
- **Real window openings** — walls build as sill / pier / lintel bands, so windows are holes
  you can see and shoot through
- **Detailed facades:**
  - every window has a sill and a header, and every floor line has a cornice;
  - houses get window frames, coloured shutters and flower boxes;
  - every building stands on a plinth with corner pilasters, a front step and a lamp by the door;
  - towers and warehouses carry shop signs (Rot Mart, Lag Cafe, Noob Noodles and more);
  - pitched roofs have a ridge cap and gable vents, and flat roofs have parapet coping;
  - towers get a railed balcony you can climb out onto, and warehouses a loading dock;
  - inside, ceilings have light panels and houses have rugs.

  All the trim is decoration that never blocks movement or a shot through a window
- **Internal staircases** with a proper stairwell gap in the floor above, so upper floors are
  reachable, and a clear landing at the foot of each flight. The bottom step used to sit against
  the back wall with nowhere to stand behind it, so the only way onto a staircase was a sideways
  hop part-way up it. The flight now starts `STAIR_LANDING` studs clear of the wall and the well
  above grows by the same amount, so the top still comes out level with the floor edge rather
  than over the hole. The cost is that a building needs 28 studs of depth before it gets stairs
  instead of 25, so slightly fewer of the small ones are climbable
- **Interior cover** — crate stacks, barrels, tables, shelving, kept clear of the stairwell,
  the doorway, partition walls, the chest and each other
- **Scenery that suits the ground** — palms and cacti on sand, pines on rock, hay bales and
  orchards on farmland, round trees and bushes on grass (`Modules/MapDecor.lua`), at about a
  third again the density it used to be, so the ground between towns is furnished rather than bare
- **Sheds** — small plank huts standing anywhere on any ground, roughly one prop in twelve: four
  walls round a doorway you can walk through, a flat overhanging roof, and a crate inside with a
  gun or a heal on the floor beside it. Their parts are named `Wall`, `Roof` and `Crate`, which is
  all it takes to make them destructible, because `DestructibleService` keys its health table off
  part names and admits anything under the `Map` root. So a shed is real cover out in the open
  field that can be shot apart around you, rather than scenery that shrugs bullets off — which is
  the entire reason for putting them there
- **Set dressing** — street lamps along the roads; lamps and hydrants at the kerb, benches facing
  the road, bins and planters on the pavement (beach umbrellas on sand) and cars parked along the
  street edge in every town; door frames, awnings, chimneys, AC units,
  water tanks and antennas on buildings. Cars and rooftop clutter are solid cover; leaves,
  flowers and lamp arms don't collide or stop bullets
- **Drivable vehicles** (`Modules/VehicleService.lua`, `Shared/VehicleModels.lua`,
  `Shared/VehicleDynamics.lua`, `VehicleClient.client.lua`) — six to sixteen per map, parked along
  the roads, drawn from seven designs with five or six paint schemes each: the **Rotster** hot
  hatch, the **Crocodilo Ranger** 4x4 pickup (a crocodile grin, eye-pod lamps, two seats in the
  bed), the **Tralala GT** shark coupe, the **Sahur Van** (wood panels, a bat and a drum on the
  roof), and the **Patapim Scrambler** dirt bike, **Bananini Scoot** scooter and **Brr
  Streetfighter**. Walk up and press the prompt (**Drive**, **Ride**) to get in; **W A S D** or the
  triggers and stick to drive, **Shift** / **L1** for the handbrake, **Space** / **A** to get out,
  set down at the first clear spot beside the vehicle with room to stand and ground under it.
  Bodies are built from parts and every moving piece moves: wheels bob, steer and spin, a bike's
  fork turns and slides and its swingarm swings, steering wheels turn, and riders sit with their
  hands on the bars or the wheel. Lamps are dim on a parked vehicle, come up when someone is in it,
  and the brake lamps light when the driver brakes — which everyone nearby can see, not just the
  driver. A vehicle checks the ground under its own four corners as it is placed and steps aside to
  level ground, or lays a piece of hardstanding under itself, rather than being left tilted on a
  bank.
  Handling is simulated, arcade-style: each wheel samples the ground under its tyre, sits on a
  spring and damper, and grips sideways and along its heading within one friction circle set by its
  load and the surface (grass and sand cost road tyres more than the Ranger's). Cars pitch, squat
  and lean on their own; assists stop runaway downhill speed, damp spins, push back past a rollover
  and turn a vehicle wheels-down in the air, and a bike balances through an `AlignOrientation` so it
  leans into turns but can't topple or loop. The driver's own client simulates the vehicle so the
  controls answer at once, and the server watches it — sustained overspeed, a teleport or hanging in
  the air takes the physics back and puts it where it last was sane. Riders go massless so they
  can't tip it, blasts throw vehicles clear (`VehicleService.ApplyBlast`), and a vehicle left on its
  roof is set back on its wheels. An engine loop pitches with road speed, tyres at the limit hiss
  and a landing thumps. They're the only unanchored thing in a map, which is why the harness asserts
  they stayed that way. `tools/vehicle_probe.lua` measures handling on a fixed course and then
  drives every model along a real map's longest road; `tools/vehicle_gallery.lua` renders every
  model and measures flush faces with the z-fight pass off. Both check themselves with planted
  faults, and the probe says outright when a result is not a measurement
- **Town welcome signs** with meme names drawn per match — Aura Farms, Sigma Station, Oof
  Oasis, Six Seven Square, Grass Toucher's Rest and more — also labelled on the minimap, with a
  "NOW ENTERING" banner when you walk in
- **A Rot Vendor on every square** (`Modules/VendorService.lua`): a lit vending machine with
  three buttons — hold **E** on one to buy a **Med Kit (250 SahurCoins)**, a **Shield Potion
  (300)** or an **ammo refill (150**, 60% of every gun's reserve**)** mid-match. It only serves
  players alive in a running match, and only charges if the thing fits in your slots, so the
  coins a match pays out (kills, streaks, bounties) are worth something before it ends
- **Real streets** — every town is laid out around a central square (a fountain, benches,
  planters, and in most towns a giant statue of an Epic or Legendary brainrot):
  - a main street runs through the square, with a cross street and two back streets;
  - every street has kerbs, pavements on both sides and centre-line dashes, and zebra crossings
    where the streets leave the square;
  - buildings line both sides of each street, set back behind the pavement with alleys between
    them, every door turned to face the street;
  - towers crowd the blocks nearest the square, houses and warehouses spread toward the edge of
    town, and the streets only run as far out as the buildings do;
  - buildings sit on an exact front line — each lot is placed at `frontDistance + depth / 2` from
    the street centreline, so varying depths push the *backs* around and never the fronts — and
    the alley after each one tightens toward the square, so downtown blocks read as a terrace
    standing shoulder to shoulder and the gaps only open toward the edge of town;
  - roads between towns pick up where a town's own streets end, on the same axis, rather than
    running into the square themselves
- **Nature in clusters** — groves, rock fields and palm stands with open ground between them,
  rather than one tree every so often everywhere
- **Lakes** with sandy shores, reeds and a dock; **crop fields** with fences around farmland
  towns; a real **coastline** of water around the beach map
- **Sensible loot** — guns on doorsteps, beside benches and parked cars, along the roads and in
  forest clearings; heals indoors and in the square; movement items on rooftops, dock ends,
  beside easter eggs and on top of the obby. Two lists naming nearly the same spot (a river bank
  and a roadside, say) get one pickup, not two built through each other

Anything placed in the world probes terrain height first, so nothing floats or sinks, and
tree trunks start just underground so slopes never leave one hovering.

**Where the ground actually is.** Roblox draws a smooth-terrain surface two studs *above* the
top of a block fill (a block filled to y = 0 reads as ground at y = 2, exactly, for any top
height), rounds cylinder fills up to the 4-stud voxel grid, and puts water at its fill top. Every
fill here is written to that rule (`MapTerrain.SurfaceLift`): the base slab is filled to −2 so
the surface is at 0, where the towns and their streets are built; landmark sites are levelled
the same way; river banks and the pond and lake shores are repaints rather than fills, so they
never lift the ground; and plateaus read their real top back with a raycast after filling and
build the ramp, loot and zipline to that. The harness's "buried under terrain" check is what
found this — before it, every town sat two studs under the ground.

**Nothing clips.** Generation keeps a footprint map (`Modules/MapSpace.lua`): roads, streets,
the square, every building, lakes, fields, easter eggs, street furniture, back-yard crates and
each tree or rock claim the ground they use, and everything placed afterwards checks it first.
Inside buildings each floor keeps its own. Back-yard crates only appear where there's room.

**Solid floors and proper roofs.** The terrain under every street, square and building is
repainted as pavement: grass terrain grows blades up through anything thin laid on top of it, which
made ground floors and streets look like there was nothing there. Pitched roofs have real
triangular gable ends (built from wedges); the old rectangular ones stuck up past the slopes at
every corner.

Each map has its own time of day (`MapData.Lighting`): clear midday on Sahur Springs, golden hour
with long shadows down Tralala Town's streets, harsh noon on Bombardiro Bay, a cold dawn on Rot
Ridge and a warm late afternoon over Patapim Plains. The lobby goes back to the default when the
map is cleared. Each map also has ambient particles drifting around the camera (`MapData.Ambient`):
pollen over the grass, dust between the blocks, blown sand on the coast, mist at dawn in the
highlands and fireflies over the farms.

### Landmarks

Every map gets four or five big named set pieces out between the towns (`Modules/Landmarks.lua`),
each with its own chests and loot, marked in gold on the minimap, and a landing spot for supply
drops. **Each map has its own set** (`Landmarks.MapSets`): its signature landmark and its own
monuments always, then a top-up from a small pool that suits it, and nothing from one map's list
turns up on another's — docks in the highlands and a carnival among the crops are what the old
random pick gave. The monuments are in the table below the originals.

A site is chosen by trying 120 spots and keeping the flattest that is clear: every sample is taken
with two rays, one ignoring water and one not, so **water is never mistaken for flat ground** (it is
the flattest surface on any map, and a site search that scores flatness used to prefer it). The site
is then levelled — a round pad with terraced rings stepping down to the ground around it, whole-stud
heights, rough or stepped terrain materials swapped for smooth ones that lie flat — and the whole
terraced site is claimed, so nothing else is built through it. Each levelled landmark carries
`FootingBase`/`FootingSize` with its pivot at the site's centre, which is what `tools/footing_probe.lua`
measures against. Walking into a town or a landmark shows **ENTERING …** across the screen and keeps
the name under the minimap while you're there.

| Landmark | What it is | Loot |
|---|---|---|
| **Signal Hill** | A 72-stud radio mast on a concrete bunker, with a climbable truss to a platform halfway up and a blinking beacon on top | chest in the bunker, chest on the platform, a sniper perch |
| **Rot Docks** | A container yard: three rows of stacks with lanes between, a gantry crane over the middle, some containers stacked two high and some hanging open | chests inside the open containers, guns along the lanes, items on the stacks |
| **The Rot Bowl** | A stadium: tiered stands with striped seats round a marked pitch with goals, floodlight masts in every corner, a scoreboard reading 67–67 | chests in the four corner tunnels, guns on the pitch, items on the top tier |
| **Flight 67** | A crashed cargo plane: nose half buried, torn-open cabin with the seats still in, tail on its side, one wing torn off, cargo thrown clear, still smoking | two chests in the cabin, heals in the cockpit, items on the wing |
| **Sahur Ruins** | A stone circle of broken columns round an altar, torches that never go out, a fallen column as a ramp to the tallest, and a sunken chamber down a flight of steps | chest on the altar, chest in the chamber, an item on the tallest column |
| **The Beacon** | Coastal maps only: a red-and-white lighthouse on the map's edge with a sweeping lamp, a truss to the gallery, and a keeper's cottage | chest on the gallery, chest in the cottage |
| **Brainrot Carnival** | A fairground: a turning ferris wheel, a spinning carousel, game booths, bunting and an entrance arch | chests in the booths, items round the rides |
| **Sahur Farmstead** | A barn with a hayloft and gambrel roof, two silos joined by a catwalk with a zipline down, a windmill turning, a yard with a tractor and a scarecrow | chests in the barn and loft, loot in the yard |
| **The Sigma Spire** | An eight-floor tower with stairs the whole way up, a helipad roof with a beacon and two ziplines off it | chests on the way up and on the roof |
| **Sahur Hot Springs** | Steaming pools, a bath house, lanterns, a statue of a Rare brainrot, and a **geyser** whose vent throws anyone who steps on it 120 studs a second straight up — the quick way onto the roof, or out of a fight | chests in the bath house, items round the pools |

| **The Great Sundial** (Sahur Springs) | A bronze gnomon fifty studs long over a marble dial on a stepped plinth, ringed with hour stones; the slope is walkable to a perch at the top | chest on the dial, chest at the foot, items round the ring |
| **Aura Windmill** (Sahur Springs) | A tapered stone-and-timber mill, sails always turning, windows glowing aura-purple, a balcony round the third drum reached by a ladder | chest on the balcony, chest on the plinth, loot round the foot |
| **Sahur Aqueduct** (Sahur Springs) | A line of stone arches striding across the fields with water running along the top: cover to fight along, and a walkway to fight over. Built on the ground as it lies — every pier finds its own | chest on the deck, chest under an arch, loot along the channel |
| **Crane Yard** (Tralala Town) | A half-built tower and a climbable 92-stud tower crane, its jib out over the frame with a container on the hook, a zipline from the deck back to the street | chest on the top floor, loot up the frame |
| **The Tralala Arch** (Tralala Town) | A steel gateway over the road with TRALALA in pink neon on both faces and a walkway across the top | chest on the walkway, loot at the feet |
| **The Beached Galleon** (Bombardiro Bay) | A warship keeled over on the sand: walk into the stove-in hull, climb to the crow's nest, cannons and barrels spilled round it | chest on the aft deck, chest in the hold, item in the nest |
| **Sandcastle Citadel** (Bombardiro Bay) | A sandcastle built by something enormous: moat, curtain wall you can walk, four towers with pennants, a keep, and the bucket and spade it was made with | chest on the keep, loot round the walls |
| **The Stone Noggin** (Rot Ridge) | A colossal carved head in a knitted beanie with a pompom, glowing eyes, snow on top; its open mouth is a cave | chest in the mouth, item on the hat |
| **Turbine Ridge** (Rot Ridge) | Three wind turbines turning on the heights, a service ladder up one to the nacelle roof, and a zipline off it | chest in the hut, chest at a tower's foot, item on the nacelle |
| **The Giant Scarecrow** (Patapim Plains) | A forty-stud scarecrow in its own corn patch, crows on its arms and hat, hay bales at its foot | chests in the corn, item on the crossbar |
| **Patapim Water Tower** | A red-and-white tank on splayed legs with a railed catwalk, the name round the tank, and a zipline down | chest on the catwalk, chest at the foot |
| **Crop Circle** (Patapim Plains) | A crashed saucer in flattened rings of wheat, its pale beam climbing 170 studs — what you steer by from across the map | chest in the circle, loot in the rings |

Signal Hill, the Rot Bowl and the Beacon have ziplines down from their high points too, as do the
Sundial, the Windmill, the Crane Yard, the Arch, the Galleon, the Citadel, the Noggin, the Turbines,
the Scarecrow and the Water Tower.

### Easter eggs

Every map hides 3–6 original gags out between the towns, plus one **Obby of Rot** — a neon
rainbow parkour spiral up to a gold trophy, visible across the map. Hit **Inspect** on one for
a one-liner and, the first time each match, **+30 SahurCoins and 25 pass XP** (the obby pays
**+100 / 60 XP**). Several nod at what's big on Roblox right now, all without borrowing any
other game's characters:

| Egg | What it is |
|---|---|
| The Absolute Unit Carrot | A garden plot where one carrot didn't stop growing. "DO NOT WATER." |
| Night Counter Camp | Campfire, log seats and a tent. The tally board reads 97 nights |
| The Lost Guest | A statue with a question-mark face, holding "where is my spawn??" |
| The 67 Monument | A giant neon pixel "67" on a billboard |
| Outdoor Living Room | Couch, rug and a TV forever loading brainrot, in the middle of a field |
| Fridgehenge | A stone-circle of fridges around a floating, turning sandwich |
| Definitely A Normal Guy | A banana in a trench coat and fedora, swaying gently |
| Big Squeak | An 18-stud rubber duck bobbing in a pond |

Flames flicker, the duck bobs and the sandwich turns — all animated client-side via tags
(`AmbientBob` / `AmbientSpin`), so none of it costs replication. Your results card shows how
many of the map's eggs you found.

---

## Bots

When a match starts with fewer than 50 real players, bots fill the rest (`BotFillTarget`). They
play for real:

- **Carry actual weapons** from `WeaponData` and use their damage, fire rate and range
- **Pathfind** with `PathfindingService`, including jump links, with stuck detection that
  recomputes rather than grinding against a wall
- **Strafe and hold range** — push when too far, peel off when you're on top of them
- **Burst discipline** — 2–5 shots then a rest, with a reaction delay on first acquiring
- **Retreat** below 26 HP instead of trading to the death
- **Fight each other**, so the field thins on its own instead of 29 statues waiting to be farmed
- **Contest loot fairly** — while under-armed they path to nearby chests and floor guns and
  swap up in rarity. They have to stand and hold for as long as a player would, and they give
  way to anyone already mid-hold, so a bot can't snatch a chest out from under you
- **Land empty-handed and arm themselves**, like everyone else. Carrying nothing counts as
  under-armed, and an empty bot sweeps for loot every 1.5 seconds over a range half again as wide
  instead of idling five seconds at a time while defenceless. Two things have to be true for that
  to work, and both were originally wrong: nothing counts as a target without a gun to shoot it
  with, and **chasing is gated on actually being armed**. The chase returns before the looting
  code, and looting is the only place a bot can ever pick a gun up — so an unarmed bot that
  chased would run at whoever it could see, empty-handed, for as long as they stayed in vision
  range, and never arm itself. Falling through to loot instead reads as breaking off to find a
  weapon, which is what you want anyway

- **Use heals and shields like players** — Bandages, Med Kits and shield potions come from chests
  and supply drops at the same rates players get, get used once the bot has broken line of sight,
  and drop on death. A bot's shield takes damage first exactly like a player's.
  A hurt bot carrying nothing detours for a loose heal pickup; with none at all, it regenerates
  slowly out of combat
- **Dress up** — about a third spawn wearing a shop accessory (never a crate exclusive), and about
  a third wear a title under their name like a player who's earned one
- **Land headshots** — one hit in ten, with the gun's multiplier, so their fire spikes like a
  player's and you hear the crack
- **Throw up barricades** — they pick up Rot Barricades from chests (one in five) and supply
  drops, and a bot that's under 60% health and being hit throws one up between itself and the
  shooter, then holds behind it for four seconds patching up before it comes back out. Their
  kits drop when they die (`BOT_BUILD_*` and `BOT_COVER_TIME` in `BotService`)
- **Rocket out of a losing fight** — Rot Rockets come from every supply drop and one chest in
  four (two carried at most). A bot at retreat health with the shooter inside 55 studs fires one
  instead of backpedalling: the same launch a player gets (`MovementService.RocketVelocity`),
  aimed away from the shooter with up to 35° of random yaw so it isn't a straight line to
  follow, with everyone hearing the item-use cue. It heals as soon as it lands rather than
  waiting out the usual lull. One rocket per 18 seconds (`BOT_ROCKET_*` in `BotService`)
- **Die like players** — the same ragdoll and per-gun kill effects, then the body is cleared

Difficulty is mainly two dials in `MatchConfig`: `BotDamageScale` (0.8) and the accuracy
pair. Accuracy falls off with distance — `BotAccuracyNear` 0.66 at point blank down to
`BotAccuracyFar` 0.19 past 120 studs — so close fights are dangerous and long ones survivable.
They were raised from 0.72, 0.58 and 0.14, alongside a shorter reaction time (0.28), a shorter
rest between bursts (0.48) and a lower retreat threshold, which together make bots meaningfully
harder without making them twitch shooters.

They occupy placement ranks but never earn rewards, and when the last real player dies the
match ends rather than leaving bots to fight on an empty server.

---

## Supply drops

From 75 seconds into a match, and every 95 seconds after, a crate falls into the safe zone
with a rarity-coloured beacon visible across the map and a marker on your minimap. They roll
Rare 26% / Epic 46% / Legendary 28% — the only reliable source of Legendary weapons — so
they're built to be fought over. Once the first circle closes, players with good loot have
no reason to move; an announced, contested objective gives everyone a reason to.

Crates land on the surface they actually fall onto, so they never sink into a hillside, and a
spot that would put one on a roof or in a tree is re-rolled to open ground. The announcement names
the nearest town or landmark ("SUPPLY DROP INBOUND • LEGENDARY • near ROT DOCKS"), and landmarks
are landing sites in their own right. Claiming one (or
opening a chest) flips its lid open with a burst of light in the loot's rarity colour.

---

## Weapons

Rarity drives stats **and** an ability, which is what makes chest loot worth fighting over.

| Rarity | Guns | Ability |
|---|---|---|
| Common | Sahur Pistol, Pocket Popper, Rot SMG, Bubble Blaster, Crumbly Carbine | — |
| Uncommon | Crocodilo Rifle, Tralala Shotgun, Bonker Double Barrel, Sigma Revolver, Lag Switch SMG, Aura Crossbow | — |
| Rare | Bananini Burst, Larila Sniper, Grass Toucher DMR, Sigma Scout | **Pierce** — shoots through the first target |
| Rare | Aura Scattergun | **Lifesteal** — heals 15% of damage dealt |
| Rare | Bubble Burster | **Chain** — 30% arcs to a nearby enemy |
| Epic | Cappuccina Launcher, Tralala Thumper | **Explosive** — splash damage |
| Epic | Camelo Vampire LMG, Glitch SMG | **Lifesteal** — heals 22% / 10% of damage dealt |
| Epic | Six-Seven Marksman | **Pierce** |
| Legendary | Patapim Chaingun, Delulu Railgun | **Chain** — damage arcs to a second enemy |
| Legendary | Rizz Rifle | **Lifesteal** — heals 12% of damage dealt |
| Legendary | Golden Sahur Cannon, Nonna Double Barrel | **Gold Rush** — kills pay bonus SahurCoins |

Only Common and Uncommon spawn on the ground. Everything else is chest-only, and the chest pool
is weighted so the top tiers are genuinely scarce rather than merely less likely:

| Rarity | Share of chest guns |
|---|---|
| Common | 32.6% |
| Uncommon | 40.0% |
| Rare | 18.6% |
| Epic | 6.5% |
| Legendary | 2.3% |

Tune it with `chestWeight` per gun in `Shared/WeaponData.lua`; `groundWeight` is the separate
pool for what lies loose on the map. Supply drops and the Aura Farm event are the reliable routes
to a top-tier gun.

**Sights.** Every gun has real, working sights you aim through: iron sights (a front post in a
notch or an aperture), a red dot, a holographic sight or a scope. Each model carries its aiming
contract as attributes: `KP_Sight`, a CFrame on the line of sight looking down it; `Optic` (`iron`,
`reddot`, `holo` or `scope`); and `EyeRelief`, how far behind that point the eye sits. Aiming
puts the camera exactly there (the viewmodel's aim frame is
`camera * CFrame.new(0, 0, -EyeRelief) * KP_Sight:Inverse()`), so the line of sight lands on the
crosshair by construction. Nothing is searched for by part name or guessed.

What can still go wrong is the gun itself, and the build check measures that on all 27 (see
*Checking a build*): the front post's top, the bead's top or the dot has to sit on the line to half
a millimetre and parallel to the bore, and nothing opaque may stand between the eye and the target.
That rules out a rear blade with no notch, a heat shield, a top lever or a carry handle. Some
conventions follow from it:
- Iron sights put the front post (or bead) **top** level with the line, seen through a U notch or a
  clear aperture.
- The Tralala Shotgun's bead stands on a ramp and the double barrels' on a raised rib, so the line
  clears the receiver, heat shield and top lever. The cannon has a tall bead in a buckhorn.
- The M249's carry handle is folded down to the left, and the chaingun's handle stands on posts
  either side of its red dot.
- Red-dot and holo windows are 90% and 94% transparent plastic, not Glass, which darkens and warps
  the view.
- Scoped guns hand over to the full-screen scope once the gun is up.

While the sights are up, the HUD hides its crosshair (the player attribute `SightsUp`, set by
`CombatClient`). Sway and bob turn about the front sight (or the dot) instead of the grip, so it holds
on the target while the rest of the gun moves, and stride bob and landing dips all but stop. The kick
and the working of a bolt, pump or lever turn about the eye instead, softer and quicker to settle than
at the hip, so the front and rear sights stay in line while the whole picture tips and comes back (the
camera's own recoil carries the climb). The kick spring is stepped at 1/60 s at most, so a slow frame
can't throw the gun. Scope zoom and the third-person scope handoff follow the gun model's `Optic`
attribute, not its style.

The checks: `tools/ads_align_probe.lua` is the long form of the sight check and `tools/ads_gallery.lua`
renders every gun's sight picture. `tools/recoil_probe.lua` fires every gun aimed for a second and
measures where the front and rear sights go. `tools/gun_contact_probe.lua` measures, with the parts'
real shapes, how much every pair of parts touches and reports any group held on by nothing, a corner or
an edge (its self-test rebuilds the RPG's old floating optic mount, which must come out loose);
`tools/gun_gaps_probe.lua` is the quicker island check. `tools/grip_junction_probe.lua` looks up from
every grip for air under the frame, and `tools/mechanism_probe.lua` checks that cylinders and cranes
turn about axes along the bore (its self-test strips a revolver's pivots and must see it tumble).
`tools/mount_gallery.lua` and `tools/fix_gallery.lua` render close-ups, the latter before and after in
one run from a scratch place carrying the old `GunModels` as `GunModelsBefore`.

**Everyday-object guns** (`Shared/CreativeArsenal.lua`, models in `Shared/GunModelsCreative.lua`).
Fourteen guns, two at every rarity, in the spirit of the Bubble Blaster: a bath toy, a juice carton, a
boombox, a gumball machine, a microwave, a snow globe. Each borrows a stock mechanism (its `Action`),
so its reload, rack and fire clips are the ones already animated, and keeps the same ADS contract as
every other gun. Their stats sit inside their rarity's body-DPS band.

Some of them do something a bullet doesn't, off fields the gun itself carries
(`Modules/StatusEffects.lua`, a `CombatService` damage listener, so nothing in it names a gun):
`knockback` shoves the victim away at a speed in studs/s, `bleed` and `ignite` deal a total over a
number of seconds in half-second ticks credited to the shooter and the gun, and `chill` slows per hit
and freezes the victim solid on the hit past the last stack, with an immunity afterwards so a fast gun
can't lock anyone down. A death, or combat switching off at the end of a match, clears everything on
that combatant, the slows included. Three of the guns fire real rounds instead
(`Shared/CreativeRounds.lua`): a disc that glances off the first wall it meets, a slipper that curves
onto whoever is most nearly ahead of it, and a lobbed piece of toast that bursts where it lands.

**Shed-and-kitchen guns** (`Shared/WorkshopArsenal.lua`, models in `Shared/GunModelsWorkshop.lua`). Six
more in the same spirit, each on a different mechanism so they play as differently as they look: Rage
Quit is a mechanical keyboard that fires its own keycaps (semi), Clean Sweep two broom handles over a
dustpan that breaks open like a coach gun, Hose Down a hose reel with a brass nozzle and a jam-jar scope
whose water lance chills (bolt), Dust Devil a canister vacuum whose four hoses spin up and spit dust
bunnies (rotary), Yard Work a leaf blower fed from a leaf bag that blows a lane clear in a storm of
leaves (belt), and Party Foul a party popper the size of a cannon, cork and confetti and a shove (lever).
Their muzzle effects and projectiles are `GunFx` kinds of their own — leaves, spray, dust, confetti and
keycaps, throwing leaves, a water lance, bristles, streamers, dust bunnies and keycaps.

A gun still being finished carries `staged = true`, which keeps it out of ground loot, chests, bot
loadouts, supply drops and the lobby's range podiums at once; `verify.py` fails if a staged gun carries
a loot weight, or if one has neither. `tools/status_effects_probe.lua` drives the effects against two
stand-in combatants and measures each one.

**Holding the gun.** Each gun's hand keypoints (`KP_GripHand`, `KP_SupportHand`, and the ones a reload
uses) mark the middle of a palm against what it holds; the rig lands the palm's inner face `HAND_SINK`
(14.5 mm) past the keypoint, so a keypoint belongs that far outside the surface the hand rests on. The
hand itself is the avatar's own, scaled per axis to 29 mm thick, 53 mm long and 79 mm across — scaled by
the arm's width alone it came out 89 mm thick and 36 mm long, a stub that stopped short of every grip in
the game. Below the palm hang two finger segments hinged at the knuckles: the upper swings down the front
face of whatever the palm is on, the lower turns in under it by whatever room is left once the depth is
taken up, so the fingers close right round a thin rod and lie down the front of a fat handguard. How far
they close is the anchor's `CURL`, which until then was carried through the rig and ignored. What they
close on is measured from the parts' own shapes once per gun: how far material stands ahead of the
keypoint (looked for only as far as the knuckles reach, so a handguard running on to the muzzle doesn't
drag them out there) and how deep it is in the knuckles' own plane. A hand on nothing — reaching for a
magazine, or into a pocket — measures nothing and closes on itself.
`tools/hand_grip_probe.lua` poses the real viewmodel and measures, per hand and per pose, the
contact area with the gun, the gap under the palm, anything of the gun standing inside a hand, and the
cross-section of what the hand closes on (18–60 mm is holdable); with a `ViewmodelBefore` module beside
`Viewmodel` it measures both rigs in one run.

**Explosive barrels** (`Modules/HazardService.lua`). Red drums with a yellow band stand in
warehouses and houses (nearly half the barrels indoors), in one back yard in four, beside every
loading dock and along the lanes of the Rot Docks. Sixty damage of gunfire (or any explosive
splash) sets one off: a fireball, a scorch mark that smokes for a while, fragments, and up to 78
damage to everyone within 15 studs, falling off with distance — credited to whoever shot it, so a
bot standing beside one is a kill for you. Anything it knocks down includes defenses and
companions in reach, and any other barrel within range goes up a beat later, so a stack chains.
Bots don't aim for them. Setting one off counts toward the barrel quests and the Powder Keg
achievement; an elimination by barrel (or mine) counts toward the hazard-kill ones.

**Rot Mines** are the same system as a carried trap (`HazardService.Mine`, thrown through
`DefenseService`). A Rare defense item — throw it like a barricade kit and it arms wherever it
comes to rest, on the ground under the landing spot (a mine that lands on a barricade settles
beneath it). It flickers red for a second and a half while it arms, then blinks green, and goes
off under the first enemy to come within 5.5 studs on the same level: 95 damage within 10 studs,
falling off with distance, credited to you. It never triggers on you and the blast spares you,
so you can drop one and stand on it. Bots set them off (they don't look for them), and anyone
can shoot a mine to clear it — 30 damage, and it still blows, so stand back. Its blast sets off
barrels and other mines in reach like a barrel's does. One nobody steps on fizzles after two
minutes. Mines sit in the defense pool (about a third of it) alongside the barricade, and count
as a build for the build quests. They're not structures, so they don't take up any of your three
standing builds — what limits them is the stack of three and the two-minute fuse. They live in
the same `Defenses` folder, so they're cleared with everything else when a match ends.

**The map breaks** (`Modules/DestructibleService.lua`). Walls, floors, roofs, stairs and the
furniture inside buildings take gunfire and come apart, so cover is something you wear down
rather than something permanent. A **wall section is 100 health**, and walls are built as bands,
so each band is its own pool rather than the whole wall sharing one. Structure is tougher than the
dressing hanging off it, and loose props give way quickly. Anything past half health darkens and goes
slightly translucent so you can read what is nearly through, and a part that breaks throws a few
chunks of itself out before it goes. Explosions do it too: a barrel going up beside a wall takes
a hole out of it.

Two details matter if you tune it. Health is tracked **per part, not per model** — a building is
a single Model, so a model-keyed pool would give a whole house 100 health between it rather than
100 for every wall band. And parts are registered **lazily, on the first hit**: a map carries thousands of
wall parts, so registering them all up front would cost real time at match start and need
clearing between matches, whereas an entry made on damage simply dies with its part. The list of
what breaks and for how much is the `HEALTH` table at the top of the module; a name that isn't in
it is scenery and stays put.

**Windows** are the one thing that breaks at a touch. Any bullet or blast shatters a pane and the
shot carries straight on through it, so a window is never cover. The server only removes the pane;
every client draws its own burst of shards (`GlassFxClient`), which fly away from where the shot
came from, land on the floor under them and fade, so a rocket through a row of windows costs a
bounded number of local parts and nothing at all on the wire. Anyone joining later just sees an
open window. When a wall, floor or roof breaks, whatever hung on it goes too: its panes shatter and
its trim (sills, shutters, frames, cornices, signs) is removed rather than left floating, but only
where nothing solid still holds it up.

**Nothing is left hanging.** When a part breaks, anything standing on it comes down:
loose loot and chests are rebuilt on the surface below (clients turn a pickup around the frame it
arrived at, so they can't simply be moved), and supply-drop crates, vendors and players' deployed
defenses are put down on whatever is under them now.

**Hitting cover reads as cover.** A hit on a wall, a window, a barricade or a barrel gives a small
grey tick and nothing else — no damage number, no hit cue — so chipping the wall in front of someone
never sounds or looks like hitting the player behind it. Damage numbers mean a person.

**Headshots** use each gun's `headshotMultiplier` (1.3× on scatterguns up to 2.5× on the Larila
Sniper), and you hear them: the shooter gets a high ding over a crack, a gold hit marker
(**HEADSHOT** on the killing shot) and a gold damage number with a `!`; whoever took it hears a
heavier ouch. Bots land one hit in ten on the head (`BOT_HEADSHOT_CHANCE` in `BotService`), so
their fire spikes the way a player's does.

**Kill effects.** Nobody just falls over. Every character ragdolls at death — each rig joint
becomes a ball socket, the limbs go solid, and the killing shot shoves the body the way it was
going, harder from harder-hitting guns and hardest from shotguns. Guns with a `killEffect`
(`WeaponData.KillEffects`, run by `Modules/DeathFxService.lua`) do something else with the body:

| Effect | What happens | Guns |
|---|---|---|
| ragdoll | drops, shoved along the shot, fades after 4s | everything not listed below |
| float | drifts up into the sky in one piece, turning slowly, glowing, and fades out | Bubble Blaster, Aura Crossbow, Bubble Burster, Rizz Rifle |
| ash | drops, greys to ash over a second, then blows away in a puff | Crumbly Carbine, Camelo Vampire LMG, Patapim Chaingun |
| burn | drops burning — flames on every limb, blackening, smoke — and the fire gutters out | Cappuccina Launcher, Tralala Thumper, Nonna Double Barrel |
| freeze | freezes solid mid-pose in pale blue ice, then shatters | Larila Sniper, Six-Seven Marksman |
| shock | drops twitching: neon flicker, sparks, jolts through the limbs | Lag Switch SMG, Aura Scattergun, Glitch SMG |
| confetti | pops into a burst of thirty bits of confetti and is gone | Pocket Popper, Bananini Burst |
| vaporize | a white-hot flash and the body is vapour | Delulu Railgun |
| gold | turns to a gold statue where it stands, then topples and crumbles into coins | Golden Sahur Cannon |

Each plays a sound at the body (`SoundConfig`: `BodyFall`, `FloatAway`, `Burn`, `Shatter` and
so on). Storm deaths and companion kills ragdoll. Every effect ends with the body hidden; bot
bodies are removed a few seconds later and a player's stays hidden until the match respawns
them. Player characters are simulated by their own client, so the shove for those goes over the
`DeathFx` remote and `DeathFxClient` applies it; bots are pushed directly. Deaths in the lobby
(falling off the Cloud Climb) ragdoll too.

**The models** (`Shared/GunModels.lua`) are built to the measurements of real guns, compared
against photographs, in millimetres (`GunModels.StudsPerMillimetre`, 0.0038 studs). Each design has
the bore at y = 0 above the trigger at z = 0, facing −Z with the ejection side to +X. Fifteen
silhouettes, each patterned on a real gun:

| Style | Patterned on | Guns |
|---|---|---|
| pistol | Glock 17 | Sahur Pistol, Pocket Popper |
| revolver | S&W 686 | Sigma Revolver |
| smg | MP5 (the SD suppressor, a claw-mount holo) | Rot SMG, Lag Switch SMG, Glitch SMG |
| rifle | M4 carbine; AKM | Crumbly Carbine, Bananini Burst, Rizz Rifle; Crocodilo Rifle |
| dmr | M14; AR-10 with an LPVO | Grass Toucher DMR; Sigma Scout |
| sniper | AWM-style bolt action; AR-10 precision rifle | Larila Sniper; Six-Seven Marksman |
| shotgun | Remington 870; a 12-gauge AR | Tralala Shotgun; Aura Scattergun |
| doublebarrel | side-by-side coach gun | Bonker Double Barrel (sawn off), Nonna Double Barrel |
| lmg | M249 | Camelo Vampire LMG |
| minigun | a hand-carried M134 | Patapim Chaingun |
| launcher | RPG-7; MGL six-shot | Cappuccina Launcher; Tralala Thumper |
| crossbow | compound hunting crossbow | Aura Crossbow |
| blaster | a brass-and-glass pneumatic rifle | Bubble Blaster, Bubble Burster |
| cannon | a gold, engraved 1887-pattern lever gun | Golden Sahur Cannon |
| railgun | a bullpup coil rifle | Delulu Railgun |

Finishes are real ones: nitride and anodised aluminium, blued and stainless steel, polymer, FDE
and OD furniture, walnut, rubber, brass and copper. Rarity shows as an accent (the colour of small
controls from Rare, cerakote on the receiver at Epic, gold trim on Legendaries) rather than
painting the gun. A gun skin recolours the receiver, handguard, slide and furniture. The only
things that glow are things that would: tritium and fibre-optic sight inserts, a red dot's dot, a
holo reticle, lasers and torches, the railgun's coils and the blaster's tank.

Up close they carry what the real ones do: serrations, ejection ports, forward assists, M-LOK
slots, magazines with feed lips and the rounds in them, witness holes, pinned trigger groups,
bolt handles, heat shields and their clamps, bipods, belts of linked rounds and ghillie wraps.
Detail finer than a few millimetres is tidied by GunModels' own z-fight pass at gun scale
(`GunModels.ZFightOptions`); a map-scale pass must never run over a gun (see *The same gun
everywhere*, below).

**No two guns of a kind look the same.** `VARIANTS` in `Shared/GunModels.lua` gives each
weapon its own fittings on top of its silhouette:

| Gun | What sets it apart |
|---|---|
| Sahur Pistol | a torch under the rail |
| Pocket Popper | a snub compact slide and a laser |
| Rot SMG | a skeleton stock and a suppressor |
| Lag Switch SMG | a drum magazine and a laser |
| Glitch SMG | drum, holographic sight, camo bands |
| Crocodilo Rifle | wooden furniture and a bayonet |
| Crumbly Carbine | a shortened carbine with camo bands |
| Bananini Burst | vertical foregrip, holo sight, camo |
| Sigma Revolver | a long barrel with gold engraving |
| Tralala Shotgun | a perforated heat shield |
| Aura Scattergun | drum-fed, heat shield, foregrip |
| Bonker Double Barrel | sawn off: short barrels, a taped bird's-head grip, no stock |
| Nonna Double Barrel | gold engraving |
| Larila Sniper | a long fluted barrel wrapped in ghillie rags |
| Six-Seven Marksman | fluted barrel, camo |
| Grass Toucher DMR | wooden furniture and a laser |
| Sigma Scout | vertical foregrip and a torch |
| Tralala Thumper | a six-tube revolving launcher that turns a tube per shot |
| Bubble Burster | a bigger tank with a gauge |
| Rizz Rifle | a holo sight, gold engraving and a vertical foregrip on a lifestealing rifle (it used to be a rotary; the id `RizzRotary` stayed so saved loadouts still work) |

A **laser** is real in first person: aim, and a red beam runs from the emitter to the point under
the crosshair, with a dot there.

**The same gun everywhere.** The gun in your hands, the one on your character in third person,
a bot's, one lying on the floor and one on a lobby podium are all built by `GunModels.Build`, at
the same detail. Guns that sit still in the world (floor pickups in `LootService`, the arena's
podium guns in `LobbyService`) go through `WeaponService.BuildStaticGun`, which anchors every part
and moves it onto the pickup or display part that `AmbientClient` turns. Two things broke that and
must stay fixed:
- **A map-scale z-fight pass wrecks a gun.** `ZFight.Fix` at the map's tolerance (0.055 studs,
  about 14 mm) reads a gun's millimetre detail as fighting and grows it into black blocks. The
  podium guns therefore live in their own `GunDisplays` folder, outside the lobby and
  `StageDisplay`, and floor pickups run the pass on their pad only.
- **Streaming delivers a pickup's parts in pieces.** `AmbientClient` spins each pickup or display
  as one group with a single `BulkMoveTo` a frame. It adds parts that stream in after their base,
  and it measures every part against the base's rest frame, never its turned one, so a gun that
  streams out and back in turns in one piece.

`tools/display_paths_probe.lua` measures every part of every gun on the floor and the podium
against a reference build, and `tools/display_gallery.lua` photographs the pairs.

**First-person animations** (`StarterPlayerScripts/Viewmodel.lua`). In a match your gun is drawn
in front of the camera, held in gloved hands on sleeved arms: two-bone arms reaching each hand to
its place on the gun, with fingers that curl round what they hold. Nothing is guessed from part
names. Each model carries an animation contract: which parts move together (the `Anim` attribute:
slide, bolt, charging handle, pump, magazine, cylinder, hinge, feed cover, lever, hammer, trigger,
rounds), where each hand goes (`KP_GripHand`, `KP_SupportHand`, `KP_MagHand`, `KP_ChargeHand`,
`KP_BoltHand` and more), and where hinges turn and how far slides travel (`Pivot_`, `Swing_`,
`Travel_`). Animations are keyframed clips laid over the action's real duration, with sounds and
events on their keys:
- **Draw** — raised from below, and **racked** the first time that gun comes out of that slot:
  a pistol's slide pulled and released, a rifle's charging handle, a pump or bolt worked.
- **Movement** — bobs with your stride, breathes at rest, lags behind the mouse, rolls into a
  strafe, lifts on a jump and dips when you land or slide.
- **Sprint** — swung low and across the body. **Aim** — see *Sights*; scoped guns switch to a
  full-screen scope with a duplex reticle and zoom further (sniper 0.3x FOV, railgun 0.4x, DMR 0.45x).
- **Fire** — spring recoil sized to the gun (a handgun flips, a rifle pushes back), and the
  mechanism cycles: the slide or bolt carrier runs back and forward, the pistol's slide locks back
  on an empty magazine, a pump is racked and a bolt worked by hand between shots, the hammer and
  cylinder turn, the minigun's barrels spin up and wind down, and a crossbow's string and bolt are
  gone until the reload.
- **Reload**, one clip per mechanism, each with its own sounds. A box magazine is swapped: the old
  one pulled and dropped, falling away and bouncing off the floor, and on an empty gun the
  charging handle or slide release follows. A revolver swings its cylinder out, the empties go
  over your shoulder and a speedloader goes in. Pump guns and lever guns are fed a shell at a
  time. The double barrel is broken open, its empties thrown and two shells loaded. Bolt guns work
  the bolt round a magazine change. The M249 opens its feed cover, and the chaingun swaps its box.
  An RPG round is slid in from the muzzle, the MGL's cylinder swings out and is fed grenades, and the
  crossbow is cocked and a bolt laid on the rail. The bubble guns take a canister and pump up, and
  the railgun takes a cell and charges.
- **Inspect** — press **V** to turn the gun over and look at both sides of it.

Spent cases (rifle brass, pistol brass, shotgun shells) are thrown from the ejection port with a
spin, bounce and settle, and are capped so a long fight can't pile them up.

Third-person arm posing (`GunPoseClient`) works on both rig formats — classic Motor6D and the
physics rigs every bot uses — so bots hold their guns up too.

**Muzzle flash, tracers and reports** (`StarterPlayerScripts/GunFx.lua`, driven by
`CombatClient`'s ShotFired handler). Every shot, yours or anyone's, bots' included, comes out of the
gun you can see: your viewmodel's muzzle in first person, the gun on the character otherwise. Each
model names its kind of flash (the `Flash` attribute), and each kind has its own flash, tracer and
report:

| Flash | Guns | Flash | Tracer | Report |
|---|---|---|---|---|
| pistol, revolver, smg | handguns and SMGs | small star and flame (the revolver's with a side blast) | bullet | `GunshotPistol` |
| rifle | the rifles, the DMRs, the LMG | star, flame and smoke | bullet | `GunshotRifle` |
| brake | bolt-action and precision rifles | sideways blast out of the brake | bullet | `GunshotSniper` |
| suppressed | the Rot SMG | a faint puff | bullet | `GunshotSuppressed` |
| shotgun | shotguns, double barrels | big flame | a spray of pellets | `GunshotShotgun` |
| rotary | the chaingun | rapid flame | heavy | `GunshotHeavy` |
| cannon | the Golden Sahur Cannon | flame and smoke | heavy | `GunshotCannon` |
| rocket, launcher | the RPG, the MGL | flash and heavy smoke, and the RPG's back-blast | a rocket with a smoke trail; a lobbed grenade | `GunshotRocket` |
| rail | the railgun | a cyan flash | an instant energy beam | `GunshotRail` |
| bubble | the bubble guns | a burst of bubbles | a floating bubble | `GunshotBubble` |
| crossbow | the crossbow | none | the bolt itself | `GunshotCrossbow` |

A bullet is a short, bright, camera-facing streak that *travels* (950 studs a second, so it reads as
instant across a room and visibly flies across a field), and its impact lands when it arrives. It
used to be a neon part stretched across the whole distance, tinted by rarity, which is a laser beam
by construction. The flash is textured particles on pooled emitters, with a short point light,
using textures the Roblox client ships (`rbxasset://textures/...`). Everyone else's shots are only
drawn within 450 studs of either end, and flashes, tracers, cases and dropped magazines are all
pooled or capped, so a firefight between forty bots doesn't become thousands of instances.

Every hit leaves a **bullet mark**, a dark chip on whatever it hit (walls, ground, roofs; never
bodies or pickups) with a puff of dust and sparks, sitting a hair off the surface, fading after
fourteen seconds and capped at eighty. Bubbles, rockets and grenades leave no chip.

**Third-person camera.** Scroll the mouse wheel out and the camera backs out of your head into
an over-the-shoulder view; keep scrolling to back it off further (2 studs a notch, 5 to 17), and
scroll in past the closest step to go back to first person. **T** (or the toggle in Settings →
Gameplay) flips it too. The camera hangs behind and to the right, the mouse stays locked to the
centre, and your character turns to face wherever you look, so the crosshair means what it means
in first person and aiming still zooms. The camera pulls in over your shoulder whenever a wall
would get between them, so it never clips into buildings. Your own gun, held item and accessory
are visible, tracers leave the real gun's muzzle, and scoped guns drop into first person while you
aim so the scope view works the same. The choice is saved to your profile. Tune the distances in
`THIRD_PERSON_DISTANCE` and the `SHOULDER_*` constants in `CombatClient.client.lua`.

**Third-person pose.** Everyone holding a gun (players and bots) raises their arms to hold it:
right hand on the grip, left hand reaching forward. Each gun is mounted with its grip exactly
where that right hand is. Launchers and cannons point forward again too: their tube-shaped
bodies used to mount the whole gun sideways.

### Inventory, shields and items

You carry **eight slots**, and any slot holds anything: one gun, or a stack of one item. Press
**1–8** (or **Q** for the next filled slot) to hold a slot, then **click to use** an item. Using takes the
item's use time, shown as a bar under the crosshair and filling up its hotbar cell. Switching
slots cancels it, and the item is only spent once the use finishes. Picking something up fills
matching stacks first, then empty slots; whatever doesn't fit stays on the floor. With every slot
full, a pickup **swaps with what's in your hands**: a gun or an item stack goes into the held
slot and what was there goes down on the pad in its place (the only refusal is picking up an item
you're already holding). Chests and supply drops leave what doesn't fit on the floor rather than
swapping. Right-click a hotbar cell to drop what's in it at your feet. Everything you carry drops
when you die.

**Shields** sit above health as a blue bar (max 100) and take damage first; hit markers turn blue
while you're still breaking someone's shield, and everyone's nameplate shows a thin blue shield
bar over their health bar. Everyone drops in with none. The storm ignores shields.

| Item | Stack | Use time | Effect |
|---|---|---|---|
| Bandage | 10 | 2.5s | +30 health, up to 75 |
| Med Kit | 3 | 5s | Full health |
| Mini Shield Potion | 6 | 2s | +25 shield, up to 50 |
| Shield Potion | 3 | 4.5s | +50 shield, up to 100 |
| Speed Soda | 3 | 0.5s | +65% movement speed for 10s, stacking with sprint, and a **RUSH**: stamina stays full and sprinting, slides, vaults and climbs cost nothing |
| Rot Rocket | 3 | instant | Blasts you high and far and **keeps its speed all the way down**; look up for height, level for distance |
| Launch Pad | 2 | instant | Drops a pad that throws anyone who steps on it high into the air, along the way they're running, for 30s |
| Blink Bean | 4 | instant | A lightning-fast 44-stud dash the way you're facing, stopping short of walls; you come out still moving and any fall is cancelled |
| Bounce Boots | 2 | 0.6s | Nearly triple-height jumps plus one mid-air **double jump**, for 18s |
| Rot Glider | 2 | instant | A real wing opens over your head and you **sail where you look** for 16s, falling slowly — opened near the ground an **updraft** throws you ~36 studs up first. The same canopy as the match drop |

Movement items are meant to be worth a slot (`Modules/MovementService.lua`). They weren't: a
player's character runs Roblox's humanoid controller, whose air control brakes any sideways speed
toward walking pace within a fraction of a second, so a launch lost almost all of its forward speed
the moment it left the ground. `tools/movement_probe.lua` measured it on a real rig — a Rot Rocket
landed **19 studs** away with no key held and 31 holding forward at a sprint, a Launch Pad 6 and 36,
and a glider opened 80 studs up sailed 4 studs with nothing held, 141 holding forward at a walk and 203
at a sprint (the air control was doing the work the item was supposed to). Launches now carry their speed:
the client holds the horizontal velocity it was thrown with until you land (you can steer it and
pull back to brake), so the same rocket lands **62 studs** out either way and the pad **48**, and the
glider holds its own sailing speed rather than blending from the braked body, so from 80 studs up it
sails **245 studs** whatever you hold (a fifth further than the 203 a sprinting player used to get), and
120 after an updraft from the ground. A
rocket re-aims along your camera from the same launch speed: level 62 studs out and 20 high, looking
up 40° 35 out and 30 high, looking down 25° 61 out and 12 high. Launches with no kind (the Hot
Springs' geyser) are applied exactly as before, and an explosion's knockback (`"blast"`) is a plain
capped velocity (60 sideways, 70 up) that also knocks you out of a climb or slide.

**Stamina** (the bar at the bottom of the screen during a match). Sprinting drains 9 a second of
100, only while you're actually moving; it refills at 25 a second after a 0.8s pause. A slide costs
18, a vault 8, a climb 12 (hopping onto anything 4.5 studs or lower is free). Hit zero and you're
**exhausted**: the sprint drops, slides and vaults are refused, the refill waits 1.4s, and you can't
sprint again until you're back to 30 (the sprint comes back by itself if you're still holding the
key). Climbs are never refused — you can't be trapped — they just take 1.6x as long. In the lobby,
on the Cloud Climb and at the firing range stamina never drains. The server keeps the real ledger
(`MatchService`, per combatant, bots included) and takes the sprint off itself when you run out; the
client predicts it for the bar and is corrected over `StaminaSync`. Riding in a vehicle never
drains it.

**Sliding** costs no slot. Press **C** while sprinting on the ground and you drop into a slide: a
burst to 1.6x your sprint speed that bleeds off over about a second, faster down a slope and slower
up one, steerable with A/D, with the view and the gun dropping. Jump out of it and the speed carries
through the air (a slide-jump). The server's part is a ceiling: `MatchService.applySpeed` multiplies
walk speed by 1.75 while a slide is on, and the client shapes the real speed underneath it each frame
through the humanoid's move vector (a shorter move vector walks proportionally slower: measured 40.9,
20.3 and 10.2 studs/s for 1, 0.5 and 0.25 at a walk speed of 40), then tells the server when the slide
ends so the ceiling comes off. Bots have no client, so theirs is a flat 0.65s burst at the ceiling.
There's no slide on NoMantle ground (the Cloud Climb, obby towers), where a slide-jump would skip
measured jumps. Tuning: `MovementConfig.Slide`.

**Climbing and vaulting.** Hold jump into a ledge and you climb onto it; run at something low and thin
(a fence, a rail, a low wall, a window sill) and jump, and you vault over it without losing speed.
`Shared/Parkour.lua` finds the move — a body-wide slab swept forward finds the face, a ray down just
inside it finds the top, short rays across the top measure its depth (thin is a vault, deep is a
climb), and boxes check the body fits everywhere it's about to go — and the root follows a short path
over it. Limits (`MovementConfig.Parkour`): a ledge has to be within hand reach, 7.2 above your feet
right now (so a jump reaches higher), **and** no more than **9.5** above the last thing you stood on.
That cap was set against the towns with `tools/roof_access_probe.lua`, which floods every surface a
player could reach around each building: any cap from 7.8 to 11 reaches the same 2 of 59 roofs on
Sahur Springs (both already reachable with plain jumps), and 12 opens 19 via shop awnings, so 9.5
changes no rooftop access. A vault needs a thin obstacle at most 4.8 high and 3.2 deep, taken at 9
studs/s or faster, with ground within 9 below its far side and a 3.4-tall gap to dive through —
exactly enough for a ground-floor window **once its pane is broken**; an intact pane is solid, so the
vault is refused. Nothing carrying `NoMantle = true` on itself or an ancestor is ever climbed or
vaulted (the Cloud Climb, the Easter-egg obby tower), and neither are other characters or loose
parts. `tools/parkour_probe.lua` checks all of that against 35 built cases, and in real physics a
climbed 6 or 9 wall leaves the rig standing on top and a vaulted fence, low wall or broken window
keeps its full sprint. Bots use the same rules through `MovementService.CanParkour` / `TryParkour`.
Everyone else sees you slide, climb and vault: the server sets a `Parkour` attribute on the body and
every client poses it (lower body only, so the gun pose stays).

**Portable defenses** are items too — hold one and click to throw the kit along your aim (up to
60 studs, in an arc). Wherever it comes to rest, the structure pops up out of the ground in half a
second, its front facing the way you were looking when you threw it, with its own health bar. It
stops bullets, takes gunfire and explosions, darkens at half health and collapses in a tumble of
parts at zero. The landing spot needs ground under the whole footprint, nothing too steep and
nothing solid already in the box; if it can't go up there, the kit lies where it landed as a
pickup, so a bad throw costs a walk, not the item. You can keep three standing; a fourth knocks
your oldest down. They're rare, and rarer up the tiers, and each tier takes a lot more shooting
down than the last:

| Defense | Rarity | Stack | HP | What you get |
|---|---|---|---|---|
| Rot Barricade | Rare | 3 | 250 | a 12-stud sandbag wall between posts |
| Rot Mine | Rare | 3 | 30 | a trap, not a structure: arms where it lands and blows up under the next enemy near it (see Combat → Rot Mines) |
| Pop-up Bunker | Epic | 2 | 1,250 | a roofed bunker: parapet with a firing slot in front, a door at the back, a crate to stand on |
| Brainrot Fortress | Legendary | 1 | 2,500 | two floors: windows on three sides, a back door, a hatch with a truss ladder, battlements and a banner up top |

One chest in five holds one (`CHEST_DEFENSE_CHANCE`), about one in seven ground item spots
(`GROUND_DEFENSE_SHARE`), and every supply drop comes with a Pop-up Bunker. Within the pool the
barricade is eight times as common as the fortress and the mine six (`weight` in `ItemData`). Sizes, health, throw
range and the builders are in `Modules/DefenseService.lua`. Bots carry barricades too and throw
them up when a fight goes badly (see Bots); every build, yours or a bot's, goes through
`DefenseService.Deploy`, so the same site rules and the same three-standing cap apply.

Heals and shields spawn indoors, and movement items on rooftops, at junctions and on docks.
Every chest gives at least one recovery item, often a second, and has a 45% chance of a movement
item. Supply drops add a Med Kit and a Shield Potion. Every item has its own model: on the floor
it sits on a glowing pad, in third person it's held out in your hand, and in your hotbar it's a
3D icon. The glider is two models in one (`Shared/ItemModels.lua`): packed, a rolled wing on a
light frame with straps and a pull handle; open, an eleven-cell arced wing with a rib over every
seam and lines down to a harness bar — scaled up over your head when it deploys. (No glowing
leading edge: Oliver asked for the canopy without one.)

In first person each item has its own animation. Potions and soda are tipped up to drink, a
bandage is wound with both hands, a med kit is held open and worked on, and boots are pulled on
low. Instant items punch forward as they go off, and glowing parts pulse while a use is under
way. Other players see a burst in the item's colour when you finish using one.

### Explosives, grenades and smoke

The Cappuccina Launcher and the Tralala Thumper fire real rounds, not hitscan shots
(`Modules/ProjectileService.lua`, with the flight and blast maths in `Shared/Ballistics.lua`,
shared with the client so what you see is what the server computes). The rocket leaves the tube at
120 studs/s, is at 260 after a third of a second, and barely drops (2.7 studs at 150, 16 at 400);
it bursts on whatever it meets or in the air after 2.2 s. The 40mm flies at 140 with almost half
gravity (8 studs of drop at 60, 22 at 100, about 220 studs of reach), and it only arms after
0.12 s: fired into a wall at your feet it bounces back as a dud and pops 0.8 s later, on you.
Bots can fire launchers through the same rounds (`ProjectileService.FireWeapon`, aimed with
`LeadAim`); `BotService` doesn't yet, so a bot's launcher shot is still an instant roll.

A blast does full damage inside its inner radius and falls off in a straight line to a fifth at
the edge, with a body allowance so a rocket at your feet counts as touching you. Three lines are
traced from the blast to a victim's head, chest and legs: each one a wall stops takes a third off,
and all three stopped means nothing at all, so cover is real cover (a window isn't; it shatters).
Your own blasts hurt you at half strength and can kill you. A blast also shoves whoever it reaches
(a small rocket jump is possible), wears down barricades and companions, sets off barrels within
reach, holes walls, floors and roofs within half its radius, breaks every pane in it, kicks any
grenade lying nearby and rocks vehicles. A round that strikes someone's head in flight is a
headshot: the direct part of its damage (the impact bonus, 25 for the rocket and 12 for the 40mm,
or all of it for a round with no blast) takes the gun's `headshotMultiplier`, the blast part never
does, and it stays one hit (one gold marker, one stat).

Two throwables (`ItemData` kind `throwable`, models in `Shared/ThrowableModels.lua`): the
**Cooked Coconut** is a frag, a hairy coconut with a fuse screwed into one of its eyes, a spoon
lever, a pull ring and a glowing crack across it. Hold the click to cook it (the fuse runs, the
crack burns brighter, a bar under the crosshair empties) and let go to throw; hold it past 3.2 s
and it goes off in your hand. It bounces, rolls and settles, and does up to 100 damage over 13
studs. The **Lowkey Latte** is a smoke bomb in a takeaway cup: it lands, hisses, and pours out a
cloud 32 studs across that holds for 14 s and thins over 4. The cloud is opaque geometry inside a
see-through shell, so it hides nameplates and bodies at every graphics setting, and bots lose line
of sight through it too (`ProjectileService.SmokeBlocks`, wired into their `hasLineOfSight`).
While a throwable is in hand a dotted arc runs the same simulation the server will, first bounce
included, ending in a ring the size of the blast or the cloud; a live grenade that can reach you
puts a red ring under it and a marker on your screen. A vehicle's driver can't throw (passengers
can). Chests hold one 30% of the time (Coconut 14 : Latte 10, two at a time) and 22% of ground
item spots carry one; bots get the same odds and throw them at people behind cover, at bunched
pairs, and as smoke when retreating (`ProjectileService.Throw`, `Dangers`, `ProjectileInfo`).

The third throwable is the **Clingy Crumpet**, a sticky bomb (`Ballistics.Throwables` kind `sticky`):
a toasted crumpet with a blob of jam underneath and a brass timer on top. It sticks to the first
thing it touches — a wall, a roof, a vehicle, a player — and rides with it, jam side to the surface
(`Ballistics.StuckFrame`); the timer's ring blinks and beeps faster over the 2.5 s to the blast, up
to 110 damage over 12 studs, the wearer taking the full direct hit. While one is in hand the dotted
arc ends in a translucent ghost of the crumpet standing where the throw will stick
(`StarterPlayerScripts/StickyPreview.lua`): green on something it can hold, red where the throw
meets nothing. No text on it, the same as the barricade preview. `tools/projectile_probe.lua`
STICKY measures the stick, the ride, the fuse and the wearer's hit; the gallery renders it stuck,
armed and as the ghost.

Every bullet that lands on someone leaves a small red splat where it hit, seen by everyone
(`Modules/HitSplatService.lua` batches each frame's hits into one event; `HitSplatClient` traces
the spot on the body and `ExplosiveFx.Splat` draws it, bigger for a headshot, blue chips for a
hit the shield took). Explosions, smoke clouds and splats are all built from parts and particles in
`StarterPlayerScripts/ExplosiveFx.lua` as functions of their age, so `tools/throwables_gallery.lua`
renders them frozen at any moment. `tools/projectile_probe.lua` measures flight against the formula,
falloff, cover, walls and barrels, duds, bounces, smoke line of sight, the driver refusal and the
cost of a step with 200 rounds in flight; the runtest fires a rocket, drops a frag and puts a cloud
between two stand-ins on a plate above the map.

---

## The lobby: Rot Island

A floating island high above the maps (`Modules/LobbyService.lua`, everything built from parts):
a round marble plaza on a grass rim, a rock underside tapering to a point and hung with glowing
crystals, and four **waterfalls** pouring off the edge into the sky with mist at the bottom. A
low rail runs round the rim with trees between the set pieces, lamp posts ring the plaza,
lanterns float overhead, fireflies drift over the grass, and every twenty seconds or so a
**firework** goes up over the tree.

**The pier.** You spawn on a wooden pier laid over the grass rim — plank lines, kerbs along both
edges, railings, lamps — that runs out to the island's edge under a "WELCOME TO ROT ISLAND"
arch, next to a **signpost** whose arrows each point straight at what they name.

**The Rot Express.** An airship moored just off the rim beyond the pier's end — a wooden hull
with a cabin, a ship's wheel and lit windows, a banded red balloon with its name on both sides,
rigging, two propellers turning at the stern, a lantern at the bow. The gangway runs flush from
the pier's end up to the bow; walk up it onto the deck and stand on the **ready pad** there to
ready up (the READY UP button and **F** still work from anywhere). It's where you board for the
next drop.

**The Rot Tree.** A giant tree in the middle of the plaza: eight curved roots flaring out down
the gaps in the bench ring and diving into the paving, a trunk 78 studs tall tapering in thirteen
stacked lengths with bark ridges and burls, the Cloud Climb's branches (smooth curves of short
segments, darkening toward the trunk, swelling where they leave it), a canopy of leaf balls
broken up by lighter clumps on top and darker ones underneath, hung with pink and gold blossom
and jointed leafy vines, and a bench ring round the base facing out across the plaza, each bench
a real `Seat` you can sit on. All the canopy scenery keeps clear of the climb's limbs and of the
air every jump flies through. Every leaf ball is scenery you fall through, and the trunk's steps
are a sixth of a stud, too narrow to stand on (measured: a rig pressed against them falls, while
one on the old trunk's 1-stud ledge stands). The old trunk's ledges went right round it, and its
solid centre ball could be walked up to the summit: both were ways to skip the climb. The roots'
shapes live in `CloudClimbCourse` with the course, because their tops are ramps up to the trunk
and the skip check has to know them. In front of it the **Golden Sahur** stands on
a lit plinth. The **display podiums** — one per player, glowing in the rarity colour of the
brainrot on it — ring the tree at r44 (`ShowcaseService.RING_RADIUS`).

**Cloud Climb.** The obby up the tree, built of nothing but its branches: 26 jumps from a root
breaking up through the paving to a summit on the tree's leader 122 studs up, in four stages
with a checkpoint between each. Where every limb goes is `Modules/CloudClimbCourse.lua`, which
**`tools/climb_design.py` generates and checks** (edit the script and rerun it, never the module;
`verify.py` reruns it in `--check` mode and fails if either is out of step).

1. **The forks.** A fork is a pair of limbs leaving the trunk from one knot and splaying into a V.
   You land on the tip of one limb, walk it in to the knot, walk the other out as it climbs seven
   studs, and jump from its tip to the next fork's. The V is what keeps it honest: neighbouring
   forks are only close at their tips, so the tip jump is the one on offer, and knots sit eight
   studs apart, beyond the 7.9-stud step a jump can make. The third fork's climbing limb is
   **deadwood**. Checkpoint 1 is **the Great Fork**, a fork of thick limbs.
2. **Under the leaves.** The **Thorn Fork** has a thorn wheel turning round the trunk just over its
   knot, so crossing the knot is a matter of timing; the **Leap Fork** is a sprint leap away and
   the limb you land on flaps; then **the Long Bough** sags out from under the leaves to the rim of
   the canopy, with a thorn rotor turning across it on a side twig and a springy outer third.
   Checkpoint 2, **Leafbreak**, is the first limb out of the leaves.
3. **The crown.** Limbs poke out of the canopy and spiral up round it, thinner as you go (1.6
   studs across down to under 1), through deadwood, springy tips, rotors and two more sprint
   leaps. Checkpoint 3, **Crow's Rest**, is halfway.
4. **Over the top.** Two twigs up through the top of the leaves, each ending in a knot you land
   on, and a last jump up onto the golden summit with the Golden Sahur trophy.

The hazards are all wood. **Deadwood** is pale; it creaks and reddens the moment you land and
snaps 1.1 s later on a fork (long enough to run the limb out) or 0.7 s later up in the crown
(land and go), a copy tumbling away while the limb grows back 3.2 s after. **Springy limbs** flap
up and down about where they leave the trunk or the leaves. **Thorn rotors** are thorny arms on
a knot turning across the route; the thorns stick out sideways only, so what you see sweeping is
no taller than what can hit you. Springy limbs and rotors move on the client (`AmbientSway`),
timed off the server's clock so everyone sees a branch in the same place, and each is built
whole before it's parented, in an atomic-streaming model, so no client gets a hinge without its
limb.

**How hard, measured rather than guessed.** `tools/jump_probe.lua` has an R15 rig with the
player's jump settings run off one block onto another and binary-searches the widest gap for
each rise: walking (18) it clears 10.6 studs flat, 9.8 rising 3 and 8.4 rising 6; sprinting
(26.1) 15.6, 14.2 and 12.4; the highest step it makes is 7.9. Those are perfect-timing ceilings,
so the course is laid out as shares of them. `climb_design.py` turns each element round the tree
until the **easiest** crossing onto it, not just the obvious tip-to-tip one, is the share asked
for: 0.72 to 0.83 of walking reach for ordinary jumps (0.39 for the on-ramp), and for each
sprint leap more than walking can make (1.09 of walking reach) but only 0.74 to 0.75 of sprinting
reach. Then it checks:
- every jump is possible and a real jump, with no crossing under 1.8 studs
- **nothing skips ahead**: from any limb, bench or root, nothing two or more elements on is within
  sprinting reach, with reach overestimated for this check
- no limb clips another limb, the roots, the benches, the statue or the trunk, or runs through a
  body standing on another limb
- every rotor clears every limb through its whole turn and actually sweeps over standing spots
- every walkable stretch has a standing body's head out of the leaves (under a leaf ball's bulge
  a limb leaves the leaves well before a body on it does, so that stretch is scenery)

`tools/climb_gallery.lua` then checks the lobby the game actually builds, in Studio (run it with
`tools/gallery.ps1`):
- z-fighting and clipping against every other lobby piece
- **clutter**: leaves, twigs or knots in the space a body takes up above a walkable part of any
  limb. This one is worked out from the parts' shapes, because scenery is `CanQuery` false and
  spatial queries can't see it at all
- every rotor and springy limb swept through its whole motion against the other solid parts
- whether a rig pressed against the trunk can stand on its steps, with a control: the same rig on
  the old 1-stud ledge, which it does stand on
- a rig **walking every limb** end to end, and **making every jump** with the player's jump
  settings, sprinting where the jump needs it, from three takeoff spots on the limb (its centre,
  and a quarter and half of the way to its edge; most takeoffs are sideways off a narrow limb with
  no run-up, and a sprinting rig covers 0.4 studs a frame, so the very edge isn't a fair test). The rotors are taken out for these:
  the server never turns them, so on the server each arm is frozen in one pose, possibly right
  over a takeoff, where in play it's a timing hazard sweeping past

It also checks that every solid part of the climb, the trunk and the roots carries `NoMantle`
(ledge-grabbing would skip the measured jumps). Last run: 0 flush pairs, 0 overlaps, 0 parts
missing `NoMantle`, 0 bits of scenery in the way, 0 collisions through the motions, 0 of 10 rigs
standing on the trunk (the control stands), 14 of 14 limbs walked, and 26 of 26 jumps made from
all three takeoff spots. The whole run takes most of an hour: give `gallery.ps1` a 3600-second
timeout. It ends with
pictures of the tree from round the plaza, up the course and close up.

**Runs.** Stepping onto the start root starts the clock, unless your run already has a checkpoint
(walking back over it mustn't throw that away). Reach a checkpoint and its sap knot sparks; fall,
and the **Sap Lantern** beside the sign at the foot of the climb puts you back on your last
checkpoint while the clock keeps running, or, held, starts you over. The summit pad stops the
clock. The sign shows the server's best time, and your first clear each server pays 250
SahurCoins.

**Market Row.** The booths along the far side of the plaza — plank floors, striped awnings,
counters, hanging signs — and every one of them **works without
opening the menu**: hold **E** at its counter and the right tab opens, or the thing just happens.
- **Trading Hall** — a proper hall at the south-west of the plaza with a long trade counter.
  **E** at the counter opens the Trade tab. The six stools round the table and the benches down
  both side walls are real `Seat` parts, so walking into one sits you down
- **Cosmetics** — a mannequin on a turntable modelling a featured accessory that rotates daily;
  **E** at the counter opens the Cosmetics tab
- **Crate Altar** (in the middle, bigger) — a round dais up three steps between four pillars
  under a ring of lights, with a **console** across its front instead of a shelf of crate models:
  one lit key per tier on a panel tilted toward you, each in the tier's colour. **E** on a key
  opens one of yours of that tier right there, no menu. Whatever anyone in the server
  pulls appears on the dais for a few seconds — the brainrot itself, or a gem in the cosmetic's
  colour — turning under the spots with *"Name pulled X!"* over it and a burst of confetti. Pulls
  queue up; a Legendary or better stays longer and gets a bigger show. Between pulls a crate in a
  tier that changes with the day turns on the dais
- **Daily Spin** — the daily login reward as a real **wheel of nine prizes**, twice the size it
  used to be and standing in the open on its own dais between two posts rather than inside a
  booth, each segment labelled and coloured, with each prize's name written across the wedge it belongs to. Numbered
  wedges and a legend board beside the wheel meant reading the wheel and then hunting the same
  number down on a board before you knew what you'd won, which is not a prize wheel; names now
  wrap over up to three short lines so even PASS FOR A DAY comes out readable inside the wedge's
  arc, on an invisible plate so the wedge colour still shows and only the lettering reads. Hold **E**
  at the console in front of it:
  the server rolls the prize by weight, the wheel turns to it for everyone to see, and it's
  announced when it stops. Same spin as the DAILY SPIN button on the Pass tab, so once a day
  either way — see *SahurCoins, crates, cosmetics, pass* for what's on it

The Codex stall has been removed from the plaza. The codex itself is unchanged and still opens
from the menu's Brainrots tab.

**The Arena.** A raised stone terrace to the east, up two ramps: five **companion practice
targets** along the far edge, the outer two moving — press your companion key near one and your
companion shows off its move (visual only) — and three **Legendary guns** turning on lit
pedestals, a different three each day.

It is also a **firing range** (`Modules/RangeService.lua`). Take one of the Legendary guns straight
off its podium with **E** — the same three that turn on display there, so there is no separate rack
cluttering the terrace — and you can shoot the five **target dummies** along the far edge
(`Modules/PracticeDummy.lua`). Each is a burlap mannequin with exactly what a player brings into a
match: `MatchConfig.StartHealth` of health behind `MatchConfig.MaxShield` of shield, read from the
config rather than copied, taken shield-first the way a player's is, with the bars over its head to
show it. Damage numbers pop on every hit — blue while the shield is soaking, gold for the head,
which pays the gun's own headshot multiplier, and 1.5x for the painted bullseye on its chest — and
when the last of it goes the dummy collapses in a ragdoll (its limbs hung on limited ball sockets,
under physics) and a fresh one is standing on the stand five seconds later. A dummy is never a combatant, so
destroying one is not a kill: no feed, no rank, no quest, no stat. Your companion's practice move
lands on them too. It uses real ammo, so reloading behaves exactly as it does in a match. Walk off
the terrace and the gun is handed back automatically; so is starting a match.

Two things about how it is built, because they are the point. Match combat is off in the lobby
and `CombatService.Fire` returns immediately while it is — the range **does not touch that
guard**. Range shots go down a separate server path whose raycast filter *includes only* parts
tagged `PracticeDummy`, so shooting another player in the lobby isn't blocked by a condition that
could be bypassed or forgotten: no player is ever a candidate, because nothing but the targets is
in the filter. And the range always hands you a fresh single-slot loadout, so it can't be used to
walk into a match already armed.

**The Pitch.** Turf to the west with touchlines, a centre circle and floodlights. Six big
googly-eyed balls, from 4 to 8 studs across, roll free — three on the pitch, three on the plaza.
Run into one and it boots away from you, harder the faster you're going. Kick one into the
**goal** and it's a goal for whoever touched it last — confetti, a server-wide shout, **35
SahurCoins** (one paid goal per player every 20 seconds, the rest still celebrate) and progress
on the goals quest. An **invisible wall** runs round the rim and across the end of the pier that
only the balls collide with (collision groups `PlayBalls` / `BallWalls`), so they can't roll off
the island or onto the airship while players walk straight through it; balls that still end up
somewhere they shouldn't go back to where they started.

**Boards.** Two holo pylons either side of the pier: the server's **top ten** by wins, refreshed
every few seconds, and the **all-time most wins** across every server, from an OrderedDataStore
(`Modules/GlobalBoardService.lua`; it says so on the board until the place is published, since
Studio can't reach DataStores). On the west side, the **Walk of Fame**: gold, silver and bronze
laurelled statues of the top three all-time winners, their names on the plates. The statues stand
1.7 times life size (`FAME_SCALE`) and are spread wider apart than they were, under a bigger lit
sign. They get no platform of their own — at that radius one would overlap both the plaza disc
and the pitch.

The layout is described in `(angle, radius)` terms at the top of `LobbyService.lua`: plaza r100,
rim r132, stalls at r74, the Trading Hall at 225° r88, the altar at 270° r84, arena centred
(86, 0), pitch centred (-74, 0), the airship at z172 off the pier. The plaza's
paving tops out at 0.17 studs (0.29 inside the gold ring round the tree), and everything that
stands on the plaza — the pitch turf, the podium halos, the stall floors — is built to clear
that. Every part carries a `Group` attribute naming its set piece, which is what the harness's
lobby clipping audit groups by, and the whole island goes through the z-fight pass once it's
built.

Lobby text has a view limit so the plaza isn't a wall of labels from wherever you stand:
floating labels vanish beyond 55 studs, the big boards and signs beyond 120, and player
nameplates beyond 80 while in the lobby (full range again in a match). Tune them with
`LobbyLabelDistance`, `LobbySignDistance` and `LobbyNameplateDistance` in `Shared/MatchConfig.lua`.

The **READY UP** button next to the banner pulses until you ready up, turns green with a tick
once you have, shows how many are ready, and **F** (or whatever you rebind it to) toggles it.

**Intermission.** After every match's results there's a 35-second break in the lobby, with a
countdown on the banner, before the next match's countdown can begin. You can ready up during it.
The length is `Intermission` in `Shared/MatchConfig.lua`.

Hit **SHOW OFF** on any brainrot to put it on your podium, glowing in its rarity colour with
your name and its coin value.

A **SELL DUPES** row at the top of the Brainrots tab (only when you have doubles) sells every copy
beyond the first of each brainrot in one go, so cashing in never breaks a set.

The **CODEX** chip on the Brainrots tab lists every brainrot in the game grouped by rarity, with
a count per set: the ones you own with their coin value and an **EQUIP / UNEQUIP** button (so a
companion can be set from either view), the ones you haven't found as black silhouettes with
which crates can roll them. The rarity chips filter it the same way, and **BACK TO MY BRAINROTS**
returns to your collection. Equipping and unequipping always answers with a toast.

### Daily quests and weekly challenges

Three quests a day — one easy, one medium, one hard — and the same three for everyone, rolled
from the day number so every server agrees without talking. They reset at midnight UTC.

They're always on screen: a **quest tracker** under the menu button (lobby and match alike)
lists today's three with a progress bar each and the weekly count, and clicking it — or
pressing **J** — opens the full **Quests** tab with the rewards, the reset countdowns and the
weeklies. Nothing about quests lives in the lobby itself.

On top of those, **two weekly challenges** with big targets (win 3 matches, 100 eliminations,
10 top-10s, 80 chests, 20,000 damage, 10 eliminations by barrel or mine, 12 vendor buys…) each
pay 3,000–6,000 coins, up to 2,000 XP and a crate — Legendary for the hardest. They roll over
every seven days and share the same tab.

| Tier | Pays | Examples |
|---|---|---|
| Easy | 400 coins + 150 XP | eliminate 5, play 2 matches, open 6 chests, use 6 items, deal 800 damage, score 3 goals, open 2 crates, 3 landmark chests, build 3 defenses, blow up 2 barrels, buy 2 things from a Rot Vendor |
| Medium | 900 coins + 300 XP | eliminate 12, two top-10s, 15 chests, 2,500 damage, claim a supply drop, clear the Cloud Climb, 8 landmark chests, 2 eliminations by barrel or mine, blow up 6 barrels |
| Hard | 2,000 coins + 600 XP | win a match, eliminate 25, four top-10s, 5,000 damage, 30 chests, three Cloud Climb clears, 5 crates, 5 eliminations by barrel or mine |

A quest pays the moment it completes (coins respect the 2x pass), with a toast, and finishing all
three pays an **Epic Crate** on top.

**Achievements and titles.** Twenty-three lifetime milestones — first kill through 500 kills, 1/10/50
wins, 25/200 matches, 100 chests, 50,000 damage, ten Cloud Climb clears, 25 goals, ten bounties,
20 crates, 30 quests, one and four complete rarity sets, 50 barrels blown up, 25 eliminations by
barrel or mine, 30 vendor buys — each pay coins once and unlock a
**title** ("Rookie", "Champion", "Legend", "Cloud Climber", "Bounty Hunter", "Curator",
"Demolitionist", "Trapper", "Big Spender"…). The first
one you earn goes straight onto your nameplate, under your name in gold; pick any unlocked one
from the bottom of the Quests tab (`Shared/AchievementData.lua`, `Modules/AchievementService.lua`).
The biggest ones (Legend, Veteran, Curator) are announced to the whole server. Progress counts in any match on any server. The pool, targets
and rewards are `Shared/QuestData.lua`; `Modules/QuestService.lua` counts them, and everything
that counts calls `QuestService.Progress` — kills and placements from RewardService, chests from
LootService, item uses from WeaponService, damage from CombatService, barrels from HazardService,
vendor buys from VendorService, hazard kills from MatchService's elimination hook, and crates,
supply drops, obby clears and goals from where they happen. A new counter needs a default in
`PlayerData`'s `Lifetime` template and a name in `AchievementData.LifetimeStats`; old profiles
pick the default up on load.

### Trading

The **Trade** tab lists everyone in the server and what they're showing off. Both sides add
up to nine brainrots and both must confirm. Every row shows the brainrot's 3D photo, and each
side's offer header shows its total coin value, so a lopsided trade is obvious before you confirm.

- **Changing your offer clears both confirmations** — otherwise someone waits for you to
  confirm then swaps a Legendary for a Common
- **Ownership is re-verified at execution**, not when the item was added, so nothing can be
  traded away twice

Lobby-only, and any open trade is cancelled when a match starts.

---

## SahurCoins, crates, cosmetics, pass

Coins come from placements, kills and selling brainrots. They buy:

**Rotating stock.** The shop restocks every **5 minutes**, with a countdown at the top of the Crates
and Cosmetics tabs.
- **Cosmetics:** each rotation puts 3 gun skins, 2 auras, 4 accessories and 2 parachutes on sale,
  drawn by rarity weight — a Common is a hundred times as likely to show up as a Legendary.
  Parachutes are drawn last from a random stream of their own, so adding them left every other
  item's stock exactly as it was (`tools/parachute_shop_probe.lua` checks 2,000 rotations).
- **Crates:** each crate has its own chance of being in stock. Common and Uncommon always are,
  Rare 85%, Epic 60%, Legendary 25% and Mythic just 10%; the Accessory, Gun Skin and Aura crates
  are 70%, 75% and 50%.

Out of stock only stops buying: crates you own always open, and cosmetics you own always equip.
The stock is worked out from the shared server clock, so every server and every player sees the
same shelves, and the server refuses a purchase that isn't in the current stock.

**Rarity ladder.** Seven tiers: Common, Uncommon, Rare, Epic, Legendary, then **Mythic** (hot
pink) and **Secret** (glowing cyan). Mythic and Secret never drop loose — only from the top
crates, at small odds — which is what makes a full collection a real grind.

**Brainrot crates** — six tiers, and each can only roll the **four rarities nearest its own** (its
own tier, the one below and the two above; the top crates run out of ladder and stop at Secret),
so a crate's name tells you what's in it and buying up a tier always means something:

| Crate | Coins (Robux) | What it rolls | Extras |
|---|---|---|---|
| **Super** | **100 Robux only** | **Mythic 90%, Secret 10%** | 60% chance of a 50K–250K coin jackpot |
| Common | 500 | Common 62%, Uncommon 26%, Rare 9%, Epic 3% | 6% accessory |
| Uncommon | 1,500 | Common 30%, Uncommon 40%, Rare 22%, Epic 8% | 8% accessory |
| Rare | 5,000 (25 R$) | Uncommon 24%, Rare 45%, Epic 28%, Legendary 3% | 10% accessory |
| Epic | 20,000 (50 R$) | Rare 32%, Epic 54%, Legendary 12%, **Mythic 2%** | 14% accessory |
| Legendary | 75,000 (75 R$) | Epic 58%, Legendary 34%, **Mythic 7%, Secret 1%** | 18% accessory, 25% chance of a 5K–25K coin jackpot |
| Mythic | 250,000 | Legendary 80%, **Mythic 17%, Secret 3%** | always Legendary or better, 40% chance of a 20K–100K jackpot |

**Legendary and up are scarce on purpose.** Every crate that can roll them does so at low odds —
the Legendary Crate is more often an Epic than anything else — and the pity guarantees for those
tiers are long enough to be a backstop rather than a schedule. Before this tuning a Legendary
Crate was 68% Legendary-or-better and 22% Mythic-or-better; it is now 42% and 8%. The Rare Crate's
Legendary went from 8% to 3%, the Epic Crate's Legendary-or-better from 30% to 14%, and the
Mythic Crate's Secret from 8% to 3%.

Crates and the chests on the map are different objects, both from `Shared/CrateModels.lua`: a
crate is a dark capsule with rounded steel edges, tier-coloured caps and glowing seams, a badge
with the tier's letter on the front, a lid and a gold padlock (the menu opens this one, and it's
what sits on the Crate Altar). Each tier is its own silhouette, not just its own colour, so it
reads on a 72-pixel card (`CrateModels.Styles`): Common has a flat lid with a ridge and a neon
front strip; Uncommon the dome with its neon band; Rare adds studs down the corner columns; Epic
a peaked roof with a neon ridge; Legendary a crown of eight gold points round the dome and gold
fittings; Mythic a peaked roof, a brushed-metal shell and a halo of eight lights hung over it;
Secret a black glass shell with a glowing core and a "?" badge; the Super crate a crown, a halo
and gold; and the cosmetic crates are presents — a cloth shell in the crate's colour, a ribbon
each way over a flat lid, a knot, and no padlock. The lid's pivot is its hinge, so the open swings
it. A **chest** is a banded wooden treasure
chest standing on four brass feet, with brass corners and straps, a keyhole plate, a curved lid
and a warm glow waiting under it, which swings open when it's looted.

A brainrot crate's accessory roll pays out an accessory at the rolled rarity that you don't own
yet, so it's never a duplicate.

**Item crates** hold one kind of cosmetic, and only ones you don't own:

| Crate | Coins | Odds |
|---|---|---|
| Accessory | 10,000 | Common 40% → Legendary 3% |
| Gun Skin | 7,500 | Common 35% → Legendary 4%, Mythic 0.8%, Secret 0.2% |
| Aura | 20,000 | Common 25% → Legendary 6%, Mythic 1.6%, Secret 0.4% |
| Parachute | 15,000 | Common 25% → Legendary 6%, Mythic 1.6%, Secret 0.4% (in stock half the time; opens with the real canopy) |

If you already own everything at the rarity rolled, you get 35% of the price back instead of a
dead pull. The top skins and auras are crate exclusives with no shop price.

The Crates tab shows each crate as a card in its colour, with its odds. Brainrot crates also show
photos of the rarest brainrots inside; item crates show how much of that set you own.

**Opening one scales with what's inside:**
- The crate drops in and its bands climb the rarity ladder, one colour per beat with a rising
  click, and only stop at the prize's tier. A Common pops almost at once; a Secret keeps climbing
  while the crate shakes itself apart.
- Epic and up shout the tier and fire spinning light rays behind the prize.
- Legendary and up add a white flash, screen shake and a burst of confetti.
- Secret prizes cycle rainbow colours through the rays, name and shout.
- A jackpot rains coins on top.
- Gun skins come out as a toy blaster in the skin's colour, auras and accessories as a glowing
  orb, refunds as a stack of coins.

**Pity.** Every brainrot crate below Super carries a guarantee: open enough of it without rolling
its pity rarity or better and the next one is forced up to it — Common: Rare+ within 20,
Uncommon and Rare: Epic+ within 15 / 12, Epic: Legendary+ within 25, Legendary: Mythic+ within 40,
Mythic: Secret within 50. The counter (per player, per crate) shows on each crate card and resets
whenever you roll at or above the guaranteed rarity, so luck never stacks with it.

**Cosmetics** — four slots, all equipped independently:

- **Gun skins** recolour and re-texture whatever gun you're holding, so one purchase is always
  useful. Shop: Rust Bucket, Bananini (Common); Crocodilo Camo, Cappuccina, Diamond Tread
  (Uncommon); Void Rot, Frostbite (Rare); Gold Sahur (Epic). Crate exclusives: Magma Core
  (Legendary), Glitch (Mythic), Prismatic (Secret).
- **Auras** are a tinted glow with drifting particles; the light casts shadows so they never
  reveal someone behind cover. Shop: Mint (Common), Ember (Uncommon), Rot and Frost (Rare), Sahur
  (Epic). Crate exclusives: Void (Legendary), Mythic Rose (Mythic), Starlight (Secret).
- **Accessories** — 13 original hats, glasses and backpacks built from parts, so no uploaded
  art is needed. They never change your hitbox or block a shot, and they hide from your own
  first-person view.

| Rarity | Accessories |
|---|---|
| Common | Party Cone, Rot Shades, Propeller Beanie |
| Uncommon | Chef of Rot, Traffic Cone, Pizza Backpack |
| Rare | Viking Helm, Exposed Brain, Duck Buddy |
| Epic | Toaster Pack, Crown of Rot |
| Legendary | Golden Halo, Galaxy Brain — **crate exclusives**, no price, can't be bought |

- **Parachutes** replace the canopy that opens over you on the **match drop-in** and with the
  **Rot Glider**, so everyone in the sky sees yours. With none equipped you get the default Rot
  Glider wing. Each is built from parts in `Shared/ParachuteModels.lua`, at the default wing's size
  (within 12% of its span), and each shop row shows the real canopy swinging gently in a small 3D
  preview. Bots wear a random shop parachute about half the time, mostly the common ones.

| Rarity | Parachutes |
|---|---|
| Common | **Patchwork Sheet** 3,000 (a striped bedsheet with sewn-on patches and knotted corners), **Traffic Cone** 3,500 (orange with reflective bands, rubber stabilisers, a little cone on top), **Picnic Gingham** 4,000 (red and white gingham right through, napkin corners) |
| Uncommon | **Watermelon** 7,000 (striped rind underneath and round the leading edge, pink flesh with seeds on top), **Pizza Glider** 8,000 (cheese, pepperoni and basil over a crust leading edge, cheese dripping off the back), **Rainbow Arc** 9,000 (six bands along the arc, a cloud at each end) |
| Rare | **Round Classic** 14,000 (the one round parachute: a dome in red and white rings with a vent cap), **Sharkwing** 15,000 (dorsal fin, white belly, eyes and a toothy grin, tail fins), **Bomber Wing** 17,000 (olive over sky grey, roundels, riveted steel leading edge, a twin tail) |
| Epic | **Cotton Candy Cloud** 32,000 (a pink and blue wing lost in sugar puffs), **Dragonwing** 38,000 (a crimson membrane pointed at each clawed finger bone and scalloped between them, spines, horns) |
| Legendary | **Golden Sahur** (gold over velvet, foil trim, rubies, crossed bats), **Phoenix Plume** (flame colours, golden feather tips and a tail fan, plumes off the tips) — **crate exclusives** |
| Mythic | **Stormcaller** (a dark wing in rolling cloud with a lightning bolt along it, top and bottom) — crate exclusive |
| Secret | **Galaxy Manta** (a swept manta ray in deep space blue: stars above and below, sparkles, a ringed planet, head fins and a tail) — crate exclusive |

Every canopy is **solid**, with no gaps or see-through slits. A wing is a row of cells round an arc,
each exactly as wide as its slice of the arc along the top, so neighbours meet on top and overlap
underneath; the dome's gores and rows tile the same way. Trim and decoration sit on that skin,
never in place of it. None of them uses Neon or transparency. `tools/parachute_probe.lua` proves
this for every design: rays on a 0.05-stud grid from six sides and from the pilot's eye (misses
enclosed by hits are holes, narrow gaps found by a morphological closing are slits). It also checks
z-fighting, that every part reaches the harness, the part budget (110), the size against the
default wing, and head clearance. `tools/parachute_gallery.lua` renders each canopy against the sky
and hung over a character through the real drop-in path.

Changes apply instantly, and clicking **UNEQUIP** on anything equipped takes it off. The pass
hands out Party Cone, Chef of Rot, Viking Helm and Toaster Pack among its cosmetic tiers.

**Brainrot Pass** — 50 tiers across free and premium tracks. Tiers with rewards waiting are
marked READY, and **CLAIM ALL** collects every unlocked reward at once.

**Daily Spin** — once a day, from the booth in the lobby or the **DAILY SPIN** button on the Pass
tab (the same spin), a wheel of nine prizes (`Shared/DailySpinData.lua`). The server rolls the
segment by weight and the wheel turns to it. Weights add up to 100, so each one reads straight off
as a percentage:

| Segment | Weight | Prize |
|---|---|---|
| 1,200 C | 20 | 1,200 SahurCoins |
| RARE CRATE | 15 | a Rare Crate |
| 3,000 C | 14 | 3,000 SahurCoins |
| ACCESSORY | 10 | a shop accessory you don't own yet (Common 25 / Uncommon 30 / Rare 28 / Epic 17 by weight); 2,000 coins if you own them all |
| EPIC CRATE | 10 | an Epic Crate |
| BRAINROT | 10 | a Rare (55%), Epic (40%) or **Legendary (5%)** brainrot straight into your collection |
| PASS FOR A DAY | 11 | one of the four gamepasses you don't own, **for 24 hours** — a real temporary pass (`TempPasses` in the profile, honoured everywhere `Monetization.Owns` is asked, shown with its time left on the Pass tab); coins if you own them all |
| **LEGENDARY CRATE** | 5 | a Legendary Crate — the same crate a first-place finish pays |
| 15,000 C | 5 | the jackpot |

The old table paid 500 coins on nearly a quarter of all spins, in a game where finishing first pays
2,500 **and** a Legendary Crate. That made the likeliest outcome of your one daily spin a shrug.
Coin expected value per spin has gone from about 580 to about 1,410 before the streak multiplier,
the floor is now worth collecting, and the top of the wheel carries the same Legendary Crate a win
does — so there's a reason to come back and spin rather than a formality to click through.

Consecutive days build a **streak**: coin prizes pay 10% more per day beyond the first, up to
double at ten (`StreakBonus`, `StreakCap`). Miss a day and it starts over.

---

## Rot Rank, mastery and the Rot Index

The Brainrot Pass tops out at tier 50, 49,000 XP, and on the modelled earn rates that's 7 to 16
hours of play. That used to be the end of XP meaning anything. Progression is the long grind after
it, and it lives on the **Pass tab**: a `PASS | RANK | MASTERY | INDEX | CELL SHOP` toggle above the
pass, with your Brain Cells beside it. Numbers are in `Shared/ProgressionData.lua`; the server side is
`ProgressionService`, the pages are `StarterPlayerScripts/ProgressionPanel.lua`.

**Three versions.** `UiKit.form(viewport, contentWidth)` decides which one a device gets, and it is the
only thing that decides: the menu shell and these pages both call it, so they can't disagree about
which version a screen is in. The names say *which dimension ran out* — a 768x1024 tablet in portrait
has 728 px of panel and is `large`, because nothing has.

- **large** — untouched. Oliver's word on the desktop menu was that it looks good.
- **tall** — the width ran out (a phone in portrait: 296–350 px of content). The rank hero's lifetime
  numbers move under the rank instead of into a right-hand column; buttons drop to their own
  full-width row, which is also a better tap target than a 140 px button against the edge; mastery
  rows stack onto `UiParts.meterLine` with the next tier's reward wrapping rather than truncating;
  the Index explainer goes, because the page below it says the same thing; the five tabs share the
  width with short labels (MASTERY becomes GUNS — "CELL SHOP" clipped to "CELL S" reads as a
  different word, which is worse than either truncating or renaming).
- **short** — the height ran out (an 844x390 phone in landscape: desktop-wide, and 208 px of list).
  Pages drop what is *reference* and keep what is a *goal*: the rank hero loses its lifetime numbers,
  the COMING UP track moves below the prestige card, the mastery tier ladder goes, the shop's
  explaining sentence goes. PRESTIGE itself moves into the hero card — measured, the large Rank page
  needs 476 px of content before that button is reachable, and even the compacted short page put it
  at about 250, which is still below the fold on 208. In the hero it lands at about 156. The card
  below keeps the explanation and loses its own button: two buttons doing the same thing is worse
  than either.

Every fixed-width grid — Index tiles, mastery skins, the four daily offers — goes through
`UiParts.grid`, taking as many columns as fit and sharing the width between them. No row is sized
`UDim2.new(1, -N)` any more: that is right at 728 px and NEGATIVE at 296, and a negative width in
Roblox draws nothing at all, so a row goes blank with no sign of what happened. The panel redraws when
the version changes, so rotating a phone reshapes the page rather than stranding the old one.

**Rot Rank and Prestige.** Every point of XP you earn for the pass also counts toward Rot Rank, an
account level from 1 to 100. The pass itself is untouched. Rank 2 costs 170 XP; each rank after
costs 20 more, up to a flat 2,000, which is 113,360 XP from 1 to 100. Every rank pays **Brain
Cells**, with bigger payouts at every tenth and twenty-fifth rank. Ranks 20, 40, 60 and 80 pay a
Rare Crate and rank 100 an Epic Crate; these go into your crate inventory and open through the same
odds code as every other crate. At rank 100 you can **prestige**, up to ten times: rank goes back to
1, every rank reward pays again with +10% Cells per prestige, you get 1,000 Cells times the new
prestige on the spot, and your nameplate gains a star in that prestige's colour. PRESTIGE asks twice
before it goes through. XP earned while sitting at rank 100 isn't lost: every 25,000 of it pays 500
Cells (times the prestige bonus). Your rank, led by that star, is the gold number beside your name.

**Brain Cells** are progression's currency. They can't be bought with Robux and no gamepass multiplies
them; `tools/verify.py` fails if Monetization or GamepassConfig ever mention them, or if
ProgressionService touches coins. One indirect route is accepted as bounded: coins bought with Robux
can buy crates, and what those crates pull pays its Index discovery once, for about 55,000 Cells over a
whole collection.

**Gun mastery.** Every gun has its own mastery, counted from credited eliminations: 1 point for a
bot, 3 for a real player. Companion, barrel and mine eliminations don't count. The tiers are
Bronze 10, Silver 30, Gold 75, Platinum 150, Diamond 300 and **Rotmaster** 600, and each tier pays Cells
(20 up to 400) plus Rot Rank XP (150 up to 2,500). The gun list is built from `WeaponData` when the
game starts, so new guns, including the packs merged into it, get mastery with no extra work
(`python tools/progression_model.py .` prints the current count). Guns marked `staged` — in a pack but
not in loot yet — are left off, so the page never shows a goal nobody can reach; each appears the day
its flag comes off, with no migration, and a staged gun that somehow already has points is shown anyway
so earned mastery is never hidden. The MASTERY page lists every gun with its tier and progress,
filterable by rarity.

**The Rot Index** is a lifetime record of every brainrot you have ever owned. Selling or trading a
copy away never removes its entry. Each discovery is claimed once for Cells, by rarity: Common 10,
Uncommon 20, Rare 40, Epic 100, Legendary 250, Mythic 600, Secret 1,500. Claiming the last brainrot of
a rarity pays a page bonus, from 250 for Commons to 15,000 for Secrets. The INDEX page shows each
rarity as a page of portraits, with a claim button on anything new and CLAIM ALL. Robux purchases don't
pay Index Cells. A brainrot first found by buying it with Robux, or by opening a crate bought with Robux, is
logged as *Purchased*: it shows as discovered but pays nothing and completes no page, until the same
brainrot turns up in play (a crate you didn't pay Robux for, or the Cell Shop). The Robux grant
handler and `openCrateFor` in Bootstrap call `ProgressionService.RecordPurchased` before anything
can scan the collection, and verify.py checks both calls are there. A trade can't launder one either.
`TradeService.OnTradeMoved` runs right after the brainrots change hands, before the trade's saves
yield. A species the giver only has as Purchased arrives as Purchased for a receiver who has never
seen it. The hook is wrapped in a pcall, so a failure can never stop a trade from saving. A receipt
processed before the join hook is covered too: RecordPurchased overwrites the entry the one-time
backfill just made from that very copy.

**The Cell Shop** restocks at midnight UTC, the same for everyone. It sells one Common, one Uncommon,
one Rare and one Epic brainrot (60 / 150 / 450 / 1,500 Cells) and a **Companion Snack**: +400 XP,
which is a whole level, for the companion following you (350 Cells, two a day). Each brainrot sells
once a day. The shop never stocks Legendary or rarer and never sells crates (both checked by
verify.py), so the scarcity above is untouched. What Cells buy is choice: the exact Epic that
finishes a set or feeds a merge.

**Rank rewards you can show off.** Fifteen `rankOnly` cosmetics, in CosmeticData and listed in
`ProgressionData.RankCosmetics`. They never appear in crates, the coin shop, bot outfits or the Daily
Spin, because `CosmeticData.OfKind` leaves them out.
- One per prestige, alternating gun skins and auras in that prestige's colour: Bronze Rot, Silver Rot,
  Golden Rot, Jade, Sapphire, Amethyst, Ruby, Neon, Diamond, and the Eternal Rot aura at 10. Each is
  handed over the moment you prestige.
- Three mastery skins: Mastercraft (Gold on 5 guns), Diamond Cut (Diamond on any gun) and Rotmaster.
- Two permanent Cell Shop listings, the long-term thing to save Cells for: the Brain Cell Aura
  (15,000) and the Synapse skin (25,000).

Anything already earned is handed over when a profile loads, so a player who prestiged before these
existed still gets theirs. The Cosmetics tab lists the ones you don't have under RANK REWARDS, and
its HOW button opens the page that earns each.

**The results card** gains one line after the pass XP: `ROT RANK 47 → 48  •  +2.3K XP  •  +64 Cells`.
It's worked out from where you stood when the match began (`ProgressionService.BeginMatch` /
`MatchSummary`), so placement XP is included. It's one line on purpose, because the card is nearly
full; mastery tier-ups keep their own toasts.

**Titles.** Eleven new achievements hang off progression: Rot Rank 25 / 50 / 100, Prestige 1 / 5 / 10,
Gold mastery on 1 and 10 guns, a Rotmaster gun, and 60 / 120 brainrots in the Index. Rank titles
count a *rank score* of prestige × 100 + rank, so 101 is the first prestige.

| Hours to… (modelled) | casual | average | good |
|---|---|---|---|
| finish the Brainrot Pass | 16 | 11 | 7 |
| Rot Rank 100 (one prestige) | 38 | 24 | 16 |
| Gold on a gun (6 guns in rotation) | 35 | 20 | 10 |
| Rotmaster on a gun | 277 | 164 | 80 |

Rank rewards add about 0.26 Legendary-or-better pulls per prestige. That's +1.1% on a good player's
Legendary+ rate and +3.1% on an average one's; a casual player, whose base rate is 0.04 an hour, gets
+18%, which is one extra Legendary in about 140 hours.
`python tools/progression_model.py .` reads the live numbers and prints the full table, including
what a profile from before progression gets the first time it loads.

**Old saves.** Profiles from before progression existed gain a `Progression` table on load. The
first time one loads, its Rot Rank is set from the pass XP it had already earned, with the Cells for
those ranks but no crates. Its Index is filled from the brainrots it owns, plus any it has merge stars
or companion XP on. Nothing already on the profile is changed. `tools/progression_probe.lua` checks
the backfill, the curve, the shop's limits, the idempotent remotes (Prestige sends the prestige it
saw; the shop's day is checked against the server's) and Reconcile against corrupted saves. A
completely full `Progression` (every gun and every brainrot) measured 4,009 bytes of save data.

**Paying each rank once.** `paidRank` on the profile is the highest rank that has actually been paid
for. Rewards are paid for ranks above it, not merely for ranks crossed in a call, which is what makes
re-tuning the curve safe: when the curve got cheaper, stored XP suddenly reached higher ranks, and
without this every player would have been paid for them again. A dearer curve can't re-pay either, the
pass-XP backfill marks the ranks it paid, prestige resets it to 1 so the new climb pays, and a player
mid-rank when the curve changes keeps their XP and their progress into the current rank.

**Toasts are news, not part of the transaction.** Every progression message goes through one
`announce()` helper that pcalls `StateSync.Notify` and warns if it fails, and it is always sent *after*
the state it announces is written — the rank attribute the nameplate reads, the title counters, the
push to the client. The live-server probe below found the opposite order in the rank-up path: because
a toast fires a remote at the player, anything that made it throw left the Cells paid and everything
after it undone. State pushes go the same way, through `pushNow()`: a failed push must not tell a
player their claim failed after the profile has been written. `verify.py` fails if `StateSync.Notify`
or `StateSync.Push` is named anywhere in ProgressionService except inside those two helpers.

`tools/progression_width_probe.lua` guards all three: it renders every page at six widths, plus an
844x390 viewport for the short version, and fails on anything drawn at zero or less. It carries its
own planted fault — a row sized `1, -900` in a 296 px frame, asserted to come out non-positive and be
named — because a fault planted by hand proves the detector worked that day, while one that runs every
time proves it still works the day someone tidies the detector. It also checks that a page measured
the width it was *given* rather than falling back to the desktop default (rendering before layout runs
would otherwise draw the large version inside a 296 px frame and pass it), that it drew the version it
was supposed to, and that the short version is genuinely shorter than the large one — a version that
renders identically to another is not a version.

That probe runs against the modules in edit mode, where StateSync and the remotes are stand-ins.
`tools/progression_runtime_probe.lua` runs in a live server instead: it starts Run mode and injects a
Script into `ServerScriptService`, which shares the server's module cache, so it sees exactly what
Bootstrap wired — the `OnXp` hook, the three remotes, a real profile load, the real `StateSync` build
and the size of the snapshot a client receives. Run mode runs no client scripts, so the rank-up toast,
the results card and the Pass tab itself are not covered there and still want a hand playtest. The
probe refuses to run at all if that Studio has live DataStore access, so a test profile can never be
written to the real store.

---

## Brainrots and companions

**Body plan.** Every creature gets stubby arms and little feet unless its look already asks for
`Arms`, `Feet` or `Tentacles`, or sets `limbs = "None"`. This is the single biggest thing they were
missing. Almost every brainrot was a shape with a face bolted on and nothing underneath, which is
exactly why they read as props rather than characters — a silhouette needs limbs before it looks
like it could move. Arms sit on the shoulder rather than the widest point, pulled a quarter of the
way toward the front surface by the same `frontZ` helper the face and the blush use. Feet stay
inside the body's `bottom`, so nothing sinks when it's stood on the ground, and are set forward so
they show in front of a round underside instead of disappearing into it. Ghosts and clouds hover,
so they get arms and no feet.

**Rarity flair.** Legendary brainrots shed a few sparkles in their accent colour, Mythics shimmer
steadily and Secrets throw a shower of them — on companions, podiums and the crate stage alike, so
what someone has following them is obvious from across a street.

**Companion levels.** Every point of damage your companion deals for you is a point of XP for
that brainrot (400 per level, up to level 10), and each level adds 3% damage and health — a
level-10 companion hits and takes 27% more than a fresh copy, so the one you keep fighting with
pulls ahead. Level-ups land mid-match with a toast, the Brainrots tab shows each brainrot's level
and XP bar, and podiums show the level of what's on them. From level 5 a companion wears a silver
crown, gold at level 10. Bots' companions are level 1.

**Merging.** Spare copies of a brainrot can be fused into it for a **star**, and every star adds
**+10% damage and health**, up to five stars (+50%). The **MERGE** button under each card in the
Brainrots tab shows what the next star needs — spares per star are 1, 1, 2, 2 and 3, so all five
eat nine copies beyond the one you keep — and greys out with your progress ("MERGE 1 / 2 SPARES")
until you have them.

Nothing is spent on that click. It opens a confirmation card (`StarterPlayerScripts/MergeDialog.lua`)
with the creature's portrait and a now/after table — stars, damage, health and total bonus
(level and stars together), with the gain beside each — plus how many copies it uses, how many you
keep, and the sell value those copies would have fetched. Only **MERGE TO N STARS** sends the
request; the card shows MERGING... while it's out, then either pops, plays the gold chime and
closes, or shows the server's reason in red and hands the buttons back with nothing spent.
Closing the menu closes the card.

Stars stack with levels: a five-star, level-10 companion hits and takes
1.9× a fresh copy. Rarity still leads at equal investment: a five-star Epic hits only a little
harder than a fresh Legendary and well short of a fresh Mythic, and a five-star Common matches a
fresh Uncommon. So merging turns the doubles every collector piles up into power instead of only
coins, without letting a pile of Commons replace the rare pulls. (The bonus was +15% a star, +75%
at five, when merging first went in; it was toned down to +10% so merged companions don't
outclass rarity.)

Stars belong to your profile, the same way companion XP does (`Stars` in the profile, brainrot
name → stars). Selling or trading a copy never takes them away, a new copy of that brainrot
arrives at your star rank, and because they never travel with a trade, stars can't be farmed on
one account and handed to another. Two guards stop you stranding a merged brainrot with nothing
to equip: **SELL 1** refuses your last copy of one, and **SELL ALL** leaves one copy of each
behind. Merging while your companion is out updates it on the spot at the same fraction of its
health — a respawn would have doubled as a heal. Cards, the in-match companion panel and podiums
all show the stars (★★☆☆☆).

The server owns every merge (`RewardService.MergeBrainrot`) and can't be talked into a bad one:
- **Validated, then applied in one step.** It checks the brainrot exists, you own it, it isn't
  maxed and you have the spares, builds the new collection aside, checks exactly the right number
  of copies came out, and only then writes it and the star. Nothing in between yields, so no other
  request (a sale, a trade, a second merge) can run halfway through.
- **No double spends.** The request carries the star count the card was opened at. A second
  confirm for the same merge (a double-click, the menu open twice) arrives with a stale count and
  is refused instead of eating another batch of copies.
- **Not mid-trade.** A trade re-checks ownership when it executes, so merging couldn't duplicate
  anything anyway, but merging away copies you'd offered would quietly turn a trade you were about
  to confirm into a cancellation. So merging is refused while a trade is open.
- **Stars never trade, and trades never make stars.** A trade moves plain copies. The giver keeps
  the stars they paid for (their next copy of that brainrot comes back at that rank, exactly as
  companion XP works), the receiver's copy arrives at the receiver's own star count for it, and
  the total number of stars across both profiles is the same before and after. Nothing is gained
  by merging on one account and trading to another, and a receiver's stars are ones they paid for
  in their own copies. Selling never pays anything for stars either. The trade screen says this on
  every row — "your ★★★☆☆ stay with you" on what you offer, "arrives at your ★★☆☆☆" or "arrives
  unmerged for you" on what they offer — so a merged brainrot shown off on a podium can't be
  traded as if its stars came with it. `merge_probe.lua` asserts each part of this rule.
- **Old saves.** Profiles from before merging simply have no `Stars` and load with none, every
  other field untouched. On load only whole star counts from 1 to 5 are kept.

`tools/verify.py` checks the merge constants agree (`MergeCopies` has one entry per star), that
every stat readout passes stars, and that the remote, the confirmation card and the menu are wired.

There are **126 brainrots** — 26 Common, 24 Uncommon, 23 Rare, 21 Epic, 16 Legendary, 10 Mythic and
6 Secret — each an original little creature built from parts (`Shared/BrainrotModels.lua`):
- **14 body shapes** — blob, bean, cube, pear, disc, stack, egg, mushroom, cloud, can, cone,
  ghost, loaf and totem. Each is built as a form rather than as one or two bare primitives: a lit
  crown, a shaded underside and a seam or band where its masses meet, plus whatever that shape
  asks for — rounded edge beads and a soft face pad on the cube, a blended neck on the pear, a
  torn skirt and ribbed gills under the mushroom cap, a pull tab and a recessed base on the can,
  scoop lips and a swirl on the cone, scored slashes and end caps on the loaf, carved rings on
  the totem, a ragged hem of small wisps on the ghost, speckles on the egg, and a pale belly
  patch laid flush on the surface. All of it stays inside the body's envelope, because the
  `BODIES` metrics table is what statues stand on and what companions hover by — push past
  `top`, `bottom` or `halfW` and creatures sink into the ground or wear their hats crooked.
- **Placed on the real surface.** Once the body is built, the builder casts rays at the shapes it
  just made (ellipsoids, balls, cylinders and boxes, solved exactly) to find where the surface
  really is, so eyes, mouths, blush, limbs and anything worn sit on it instead of floating off a
  crown or sinking into a belly. Faces are mirrored across the centre line, so they stay symmetric
  on a lopsided body, and the mouth is kept on the same piece of the body as the eyes: on a saucer
  or a stack of tiers the lower half of the face used to land on the hull below and read as a second
  face. Two attributes mark what is deliberate so the audits' counts mean something —
  `IntentionalFloat` for parts that hover on purpose (orbiting motes, a halo, raindrops) and
  `IntentionalAsymmetry` for scatter that is deliberately not mirrored (sprinkles, quills, fries).
- **13 eye styles** — each a white eyeball with an iris and pupil lying on its front like lenses,
  and a glint (`look.iris` sets the colour; otherwise it comes from the accent). Sleepy eyes get a
  heavy lid, angry and worried ones rounded brows; also big, wink, hearts, five-point stars,
  goggles with a strap round the head, visors and three-eyed.
- **11 mouths**, drawn as curves: smiles and frowns, an open grin — one dark hollow with a lip
  round it, teeth under the top lip and a tongue — an O with a lip, beaks, fangs, buck teeth and
  tusks. A beard hangs below the mouth rather than over it, so the smile still reads.
- **Limbs.** Jointed arms (upper arm, elbow, forearm and a mitten hand with a thumb) posed by the
  companion's move — Bonk and Shockwave brainrots flex, Zap, Chain and Lob ones hold their hands
  ready, the rest let them hang — and feet with a darker sole and three toes, on a short leg
  wherever a round body stands clear of them. Nothing reaches below the base.
- **95 extras.** The general kit: antlers, fins, tentacles curling along the ground, top hats,
  headphones, capes, monocles, beards, petals, feathered wings, a teardrop flame, a smooth halo,
  floating gems, spots, stripes, blush, unicorn horns, whiskers, fishbowl helmets, lightning bolts,
  shells and ties. On top of that, **signature details** give the original-concept brainrots the
  thing they're named after: fries standing out of the carton, toaster slots with the toast popping
  up, a washing machine's glazed porthole and dials, a lighthouse lamp room, wizard and witch hats,
  a pharaoh's headdress, castle battlements, butterfly and bat wings, spider and insect legs, crab
  pincers, quills, a drum with its sticks and cord, a ninja headband, a graduation cap, a beret, a
  mane, ribs, a fish's tail fin, brain folds, an air tank and hose, a surfboard, box flaps, a bubble
  being blown, rising bubbles, raindrops, stink lines, noodles, a fork wound with them, umbrella
  ribs, an eggshell, tears, a nose, a stinger, a plume, camel humps, a fridge handle, a chest panel,
  exhaust pipes, sprinkles, a whale's spout, a cherry, seaweed and a topknot, glossy drips, a hair
  bun, a nightcap, pixel shards, an accretion ring and a rainbow arch. `look` fields also set the
  belly colour, a glowing carved face and a mirror-bright body. The meme-named brainrots keep the
  quality pass only — their designs stay original, as does the `BrainrotModelOverrides` route for
  your own models. The same builder draws all of it everywhere, so what you see in your inventory is
  exactly what follows you around.
- **Statue-safe.** Fine detail is made of balls and sphere-meshed parts, which have no flat faces,
  so the lobby-wide and map-wide z-fight passes every statue goes through have nothing to nudge.
  `tools/brainrot_models_probe.lua` builds all 126 at every statue scale, off-axis, runs that pass
  again and reports anything that moves (none do), along with part counts, anything below the
  base and the z-fight nudges at companion scale. `tools/brainrot_gallery.lua` photographs every
  brainrot in rarity sheets plus a front-and-back close-up of each body shape.

**Inventory.** The Brainrots tab shows every brainrot you own as a card with a live 3D photo,
its rarity and value, and its companion stats: move name and type, damage, cooldown, range
and health, all with its level and merge stars applied. Buttons: **EQUIP** / **UNEQUIP**,
**SHOW OFF**, **SELL 1**, **SELL ALL**, and a full-width **MERGE** under them. Below your
collection, every brainrot you haven't found yet appears as a mystery tile with only its
rarity showing. Rarity filter chips along the top narrow the list to one tier, and there the
undiscovered ones show as dark 3D silhouettes.

**Sets.** Owning every brainrot of a rarity at the same time pays a one-time bonus — 2K Common,
6K Uncommon, 20K Rare, 60K Epic, 200K Legendary, **1M Mythic** and **4M Secret** SahurCoins —
checked whenever a crate opens, a trade completes or you join. Progress for each rarity shows at
the top of the Brainrots tab, with the Legendary, Mythic and Secret sets on their own row.

**Companions.** Equip one and it bobs along at your shoulder — in the lobby, and in matches,
where it fights.
- **Its move fires on a hotkey** (**G** by default) and recharges between uses. It goes for the
  enemy nearest your crosshair that it can see and reach; with nobody in reach it still fires
  where you're looking, and every move still hurts whatever is there: a shockwave or a lob
  splashes, a bonk slams its splash down at the point, a spit hits anyone within a couple of
  studs of where the glob lands, and a zap or a chain hits the first enemy its beam passes
  through. Splashes and a chain's fork need line of sight from where they land — nothing reaches
  through a wall or a floor.
- **Try it at the range.** In the lobby the move is a demo on the practice dummies, and every
  kind lands on them the way it would in a match: the target takes the hit, a bonk, a shockwave
  or a lob splashes the dummies around it, and a chain forks on to the next one — with your hit
  marker, and nothing else (a dummy is not a kill).
- **Its kills count as yours.** The kill feed names the brainrot that landed the final hit, just
  as it names the gun for a shot, and your results card totals the damage it dealt.
- **It can be shot.** Enemy bullets, explosions and other companions' splash all hurt it (your own
  shots pass through), and a health bar floats over it during a match.
- **A downed companion bursts apart** and sits out the rest of the match. Both of you get a toast
  ("You downed …!"), and it comes back when the match ends, ready for the next one.
- **It acts out its move.** Everyone sees it perform: a spitter rears back and snaps forward, a
  bonker leaps on to its target itself and slams down, a zapper shivers as it charges and kicks
  back as the beam fires, a chainer spins, a lobber winds up with its arms high and tosses, and a
  shockwaver jumps and stomps (discs, clouds and ghosts spin instead). Each body moves its own way —
  cubes, cans and loaves tumble rigidly through a leap, stacked bodies nod their top half — and
  between moves they breathe, sway, flap their wings and wag their tails.
- **Hits land when the move connects.** Every move has a 0.15s windup
  (`CompanionAnimations.Windup`) and the server holds the damage for it, so the strike, the beam
  and the stomp line up with the hit. Aimed moves lead a moving target by the windup, so it costs
  no accuracy: `tools/companion_probe.lua` runs each move at a sprinting target and they all still
  hit 12 of 12. A **Lob** leads its target through its whole flight too, capped at 14 studs, so it
  lands on someone running straight away (0 of 12 before the lead, 12 of 12 with it) while a
  deliberate turn back still dodges it.
- **Hits you can see and hear.** Damage that lands comes back once per attack (`CompanionHit`): a
  white flash, a star of shards and a ring on whoever was hit, a thwack, and a little cheer from
  the companion. At most 12 impacts play a second however many companions are fighting. A lobby
  practice demo hurts nobody and so gets no report back, so aimed moves mark their own landing on
  the target instead (a shockwave, which has no target point, just rings out).

**How companions animate.** `BrainrotModels.Build(def, { rig = true })` — used only by
CompanionService — welds each part to an invisible pivot (Body, and on it Head for pear, stack and
totem bodies, both arms, both feet, both wings and the tail) joined to its parent by a Motor6D named
after the group, with the root at RootPriority 127. Motor6D.Transform is local to each machine and
never replicates, like a character's Animator, so CompanionFxClient poses every companion within 220
studs itself, bots' ones included, while the server keeps the rest pose for hit detection.
Companions stream in whole (ModelStreamingMode Atomic). Poses are pure functions of time in
`Shared/CompanionAnimations.lua`, which is how `tools/companion_gallery.lua` photographs every body
mid-move and the probe checks every clip is shorter than the cooldown. Every other caller builds
without `rig`; the probe fingerprints 378 of those builds against the builder with its rig branch
removed to prove they're unchanged.

During a match, a panel above your health shows your companion's move, a health bar, and either
**READY [G]** or the seconds left on the cooldown. It flashes in the companion's colour each time
it strikes and reads DOWNED if it's knocked out.

Beside that panel — in the lobby as well — sits the **ability tile**
(`StarterPlayerScripts/CompanionAbilityIcon.lua`): a round portrait of your companion with the key
that uses its move on a badge (whatever it's rebound to), and a ring in its rarity colour that
refills clockwise as the move recharges, with the seconds left over the portrait. It pops when
you use the move and again when it's ready, turns red with a cross while the companion is downed,
and hides while a menu is open. The ring is two clipped halves of a circle outline with a
hard-edged gradient turned round, so there's no image to upload. `tools/companion_icon_gallery.lua`
shows every state.

About a third of bots bring a companion of their own. Theirs use the move automatically, and
nearly all are Common or Uncommon, so a bot-filled lobby never out-damages the real players in it.

| Move | Plays out as | Base range | Base cooldown |
|---|---|---|---|
| Spit | A glob flies at one enemy | 60 | 5.6s |
| Bonk | Leaps in and slams, splashing anyone close | 36 | 6.65s |
| Zap | Instant beam | 55 | 4.7s |
| Lob | Arcing shot, led to where the target is running, that splashes where it lands (turn to dodge) | 70 | 7.7s |
| Shockwave | Pulse hitting every enemy it can see within its radius (14 studs, up to 23 with rarity) | 14 | 9.1s |
| Chain | Zap that arcs on to a second enemy | 55 | 6.3s |

Rarity sets the baseline:
- Damage per use is 10 / 15 / 21 / 30 / 41 / 53 / 66 from Common to Secret, before the move's
  own power.
- Health is 60 / 80 / 105 / 135 / 175 / 225 / 290.
- Cooldowns shrink and ranges grow with rarity, so a rarer companion always outclasses a lesser
  one.

Numbers live in `Shared/BrainrotData.lua` (`RarityDamage`, `RarityHealth`, `AbilityPower`,
`AbilityCooldown`, and for merging `MaxStars`, `BonusPerStar`, `MergeCopies`). Selling or trading away your equipped companion sends it home.

**Podiums** in the lobby show the real 3D brainrot you're showing off, on a rarity-lit plinth.

---

## Making Robux

`ReplicatedStorage/Shared/GamepassConfig.lua` is the money file. Every `id = 0` is a
placeholder, and anything still at 0 is hidden from the shop in a live game — the game runs fine
before you set any of it up. **In Studio the whole shop shows anyway**, with unset prices greyed
out, so you can see how it looks.

**Featured deals** sit at the top of the Robux Shop tab as big pulsing cards:

| Deal | Price | What's inside |
|---|---|---|
| **Starter Bundle** (one time only) | 300 R$ | 25,000 coins, Legendary + Epic + 2 Rare Crates, 2 one-match **1.5x health** boosts, exclusive *Starter Spark* gun skin |
| **Pro Bundle** | 800 R$ | 150,000 coins, **5 Super Crates, 10 Mythic Crates**, 3 Legendary Crates, 5 one-match **2x health** and 5 one-match **1.5x speed** Pro boosts, exclusive *Pro Plating* skin and *Pro Aura* |
| **Super Crate** (always in stock) | 100 R$ | Mythic or Secret brainrot every time, 60% chance of a 50K–250K jackpot |

A pulsing button under **MENU** points at the Starter Bundle until it's bought, then the Pro
Bundle. Buying a bundle pops up a card listing everything it gave. Bundle exclusives never come
from crates or the shop; if a player already owns one (buying the Pro Bundle twice), it becomes
coins instead (`duplicateCoins`). Bundles are `kind = "Bundle"` products with a `contents` list —
add your own the same way, and set `limit` to make one a one-time offer.

**Gamepasses:** Iron Sahur (+50 HP, 50 R$), Rot Runner (+4 speed, 50 R$), Brainrot Pass Premium
(**450 R$** — it unlocks a whole season's premium track, so it's priced as a season pass),
**2x SahurCoins (350 R$)** and **2x Crate Luck (350 R$)**. The Daily Spin can also hand
any of them out **for a day**, so everyone gets a taste before they buy. All prices here are the
`suggestedPrice` shown in the shop; the real price is whatever you set on the Creator Dashboard.
The step-by-step setup is at the top of `GamepassConfig.lua`.

**2x SahurCoins** doubles every coin *earned by playing*: placements, kills, bounties, kill
streaks, match events, daily quests and weekly challenges, achievements, Brainrot Pass coin
rewards, Daily Spin coins, set bonuses, the obby, goals and easter eggs. All of those pay through
one function, `Monetization.EarnCoins`, so a new coin source gets the pass by using it (verify.py
fails the build if a server file adds coins any other way). Not doubled: coins bought with Robux
(coin packs, bundles), crate jackpots and duplicate refunds (they're part of what a crate says it
holds), and **coins from selling brainrots**. That last one is deliberate: with selling doubled, an
owner of both passes could buy Common Crates with coins and sell the pulls for about 794 coins
per 500 spent, an endless coin loop that would devalue every coin pack. `doublesSelling` in
`GamepassConfig` turns it back on, and `tools/verify.py` then fails unless the crates are re-priced
so none of them can be bought and sold back at a profit.

**2x Crate Luck** makes every crate open roll twice and keep the rarer result. The odds are
transformed exactly rather than rolled twice: the chance of a rarity *or better* becomes
1 − (1 − base)², so no chance can pass 100%, a crate can still only roll the rarities it lists, and the
rare end gains the most. Pity counters and guarantees work exactly as before. Owners see their real
odds on every crate card, under a "2x CRATE LUCK ACTIVE" header, because the cards and the roll
both call `CrateData.EffectiveOdds` with the same luck value from the server. Roblox requires the
odds shown for paid random items to be the ones players actually get, and verify.py checks that
the roll, the snapshot and the cards all go through that one function.

| Crate | Base odds | With 2x Crate Luck |
|---|---|---|
| Common | Common 62, Uncommon 26, Rare 9, Epic 3 | Common 38.44, Uncommon 39.00, Rare 16.65, Epic 5.91 |
| Uncommon | Common 30, Uncommon 40, Rare 22, Epic 8 | Common 9.00, Uncommon 40.00, Rare 35.64, Epic 15.36 |
| Rare | Uncommon 24, Rare 45, Epic 28, Legendary 3 | Uncommon 5.76, Rare 41.85, Epic 46.48, Legendary 5.91 |
| Epic | Rare 32, Epic 54, Legendary 12, Mythic 2 | Rare 10.24, Epic 63.72, Legendary 22.08, Mythic 3.96 |
| Legendary | Epic 58, Legendary 34, Mythic 7, Secret 1 | Epic 33.64, Legendary 51.00, Mythic 13.37, Secret 1.99 |
| Mythic | Legendary 80, Mythic 17, Secret 3 | Legendary 64.00, Mythic 30.09, Secret 5.91 |
| Super | Mythic 90, Secret 10 | Mythic 81.00, Secret 19.00 |

**Beginner's Luck** (not mentioned anywhere in the game, by design). A profile's first
`CrateData.BeginnerCrates` (4) **free** brainrot crates roll at `CrateData.BeginnerLuck` (4x), on top
of any pass, so a 2x Crate Luck owner rolls those four at 8x (the ceiling, `CrateData.MaxLuck`).
Nothing labels it, announces it or appears in the reveal.

The rules that keep it honest, all enforced by verify.py:

- **Free crates only.** Crates the game hands out (placements, the Daily Spin, quests, the pass,
  rank rewards) are counted in `FreeCrates` by `CrateService.Give`; Robux crates go to `PaidCrates`,
  and coin purchases are the unmarked remainder. Open spends paid first, then free, then coin. A
  crate anyone paid for — Robux or coins — is never boosted and never spends a charge, because a
  paid random item has to roll the odds its card shows.
- **No wrong number is ever displayed.** While the next crate of a tier is boosted, its card lists
  the rarities it can drop and *no percentages* (`StateSync.crateBoosted` says which tiers, and the
  menu sends no shown-luck for those, so the mismatch check stays consistent). The percentages come
  back by themselves when the charges run out.
- **One charge per boosted open**, spent where the crate itself is spent, after every refusal check,
  with nothing yielding in between; a refused open spends neither. Item crates are never boosted.
- Charges live in the profile (`Progression.beginnerLuck`), are granted once behind an explicit
  marker, and nothing refills them. `tools/beginner_probe.lua` measures all of it, including that the
  observed shares over thousands of opens match `EffectiveOdds` at the luck actually rolled.

**Opening one.** A crate opens by swinging its lid up and over on its hinge — the middle of the
lid's back edge, which `CrateModels` sets as the lid's pivot and repeats as its `Hinge` attribute —
after pressing down a moment first, and overshooting a little before it settles. It used to be
launched into the air on a tumble, which read as the crate coming apart rather than opening.

The curve is one function, `Shared/CrateOpen`, played by the menu reveal and rendered frame by frame
by `tools/crate_open_gallery.lua`: a picture of an animation is only evidence if it is a picture of
*that* animation. The tiers open with their own quality rather than one speed for all — a Common
crate snaps open in 0.34 s with a light settle, a Prestige Style crate takes 0.62 s and lands
heavily — and the gallery measures the ladder as well as drawing it (the hinge must not travel while
the lid swings, the lid must end up open and behind its hinge, and no tier may open faster or lighter
than a cheaper one). The old fly-off is kept in that file as a planted failure: measured the same
way, it has to fail the hinge check, or the check is measuring nothing.

**Buy any brainrot outright.** Every brainrot can be bought with Robux from its card in the Codex
(the Brainrots tab's CODEX view), and the Robux Shop has a **BRAINROTS** section whose CHOOSE
buttons open the Codex at that rarity. Prices, one table in `GamepassConfig.BrainrotPrices`:

| Rarity | Secret | Mythic | Legendary | Epic | Rare | Uncommon | Common |
|---|---|---|---|---|---|---|---|
| Robux | 2000 | 1100 | 600 | 300 | 150 | 75 | 35 |

There are seven developer products, one per rarity, rather than 126, so the purchase alone can't
say *which* brainrot was bought. `BrainrotShopService` ties the pick to the purchase: the server
stores the chosen brainrot in the profile (`PendingBrainrot`) and only then opens the prompt, and the
receipt grants exactly that brainrot. It can't be gamed or lost:
- the same receipt delivered twice grants once (the `PurchaseId` is recorded with the grant and
  saved before the purchase is confirmed);
- a second pick for the same rarity is refused while that rarity's prompt is open, so the choice
  can't change under a purchase, and closing the prompt without buying clears it;
- the pick is part of the saved profile, so paying and disconnecting still delivers that brainrot
  when Roblox re-sends the receipt on the next join;
- if the pick was somehow lost too (a DataStore outage), the receipt still pays out: a brainrot of
  the rarity paid for, one the player doesn't own yet if there is one.

A bought brainrot arrives through the crate reveal, in its rarity's colours, and can complete a set.
It's recorded in the Rot Index as discovered but pays no Brain Cells (`ProgressionService.RecordPurchased`),
and the same goes for anything pulled from a crate bought with Robux: those crates are counted in the
profile's `PaidCrates` when a crate product or bundle grants them, opened first, and their pull is
marked `purchased`. Crates owned before that tracking existed count as earned.
`tools/monetization_probe.lua` opens thousands of crates through the real code with and without the
pass and checks the results against the shown odds, checks pity still guarantees with luck, and
drives receipts through `Monetization.HandleReceipt` (duplicates, disconnects, lost picks, old saves).

**Developer products:**
- the **Super Crate** (100 R$), which is the best crate in the game and is Robux-only: a Mythic or
  Secret brainrot every time, plus a 60% chance of a 50K–250K coin jackpot;
- one-match versions of the health and speed boosts (35 each); the bundles' 1.5x / 2x health and
  1.5x speed boosts are `Health`, `HealthPro` and `SpeedPro` consumables, spent when a match starts;
- the brainrot crates: Common 49, Uncommon 99, **Rare 25, Epic 50, Legendary 75**;
- 10k / 50k coin packs.

The Mythic crate and the item crates are coins-only. The Super Crate sits at the top of the Crates
tab with a Robux button, which works once its product ID (`CrateSuper`) is set, and it's never out
of stock.

Create them at **create.roblox.com → your experience → Monetization**, then paste each
numeric ID into `GamepassConfig.lua`. Benefit logic, ownership caching, receipt handling and
shop UI are already written. Purchases are deduplicated by `PurchaseId` and saved *before*
the receipt is confirmed, so a crash can't swallow something a player paid for.

**The receipt rules** (`Monetization.HandleReceipt`), each one a way a purchase used to be lost or
handed out twice. `tools/receipt_probe.lua` drives all of them with a stand-in player and an
injectable save failure:

- nothing is granted into a profile that can't be saved (still loading, or running on defaults after
  a failed load): that grant would die with the session, so the receipt waits instead;
- `PurchaseGranted` only ever follows a **successful save** of a profile holding both the grant and
  its `PurchaseId` — including for a receipt granted earlier in the same session, whose save may have
  failed;
- a `PurchaseId` is granted once, in this session or any later one (the ids are saved, 500 of them);
- a grant handler that fails *after* changing the profile has already granted it, so it's recorded
  like any grant: answering "not processed" there would grant the whole thing again on the retry;
- handlers only change the profile and hand back an `announce` function for toasts, reveals and state
  pushes, which runs after the save, in its own `pcall`. A failing toast can't cost anyone a purchase.

**Passes** are cached per session. A pass bought in-game counts from the moment Roblox says the
purchase finished, even though `UserOwnsGamePassAsync` often keeps saying "no" for a while after; an
ownership check that errors at join is retried rather than taken as "doesn't own it"; and the cache is
only ever cleared when the player leaves (clearing it mid-session switched off everything they'd paid
for until they rejoined).

**Crate odds you see are the odds you get.** The menu sends the crate luck its card was drawn with,
and `CrateService.Open` refuses the open — spending nothing, and saying why — if that isn't the
player's luck any more, so a boost expiring mid-menu can never roll at odds other than the ones on
screen.

Single-use boosts are spent when a match actually starts, so buying one and leaving doesn't
burn it, and permanent passes take priority so a consumable is never wasted.

---

## Controls

| Input | Action |
|---|---|
| Left mouse | Fire (hold for automatics), or use the item in your hand |
| Right mouse | Aim down sights — zooms FOV and cuts spread to ~a third |
| Left Shift | Sprint (1.45x your base speed) — cancels aiming; drains stamina in a match |
| R | Reload — pulling the trigger on an empty magazine reloads too (the Auto-reload setting) |
| C | Slide — only out of a sprint, on the ground; 18 stamina, 0.6s after the last one ends |
| X | Use your first movement item without putting your gun away (the Quick Movement key) |
| Space (held) | Jump; into a ledge, climb it; running at something low and thin, vault it; in the air with Bounce Boots, double jump |
| G | Companion move |
| V | Inspect your gun |
| Mouse wheel | Zoom: scroll out of first person into third, keep scrolling to back off (up to 17 studs), scroll in past the closest step to return to first person |
| T | Toggle first / third person (saved to your profile) |
| 1 – 8 | Hold an inventory slot (tap a hotbar cell works too); **Q** steps to the next filled slot |
| W A S D | Drive, once you're in a vehicle's seat — **Space** gets you out |
| E | Open chest / pick up — **or** next target while spectating |
| F | Ready up / stay in the lobby (outside a match) |
| M | Open the menu |
| J | Quests and weekly challenges (also: click the tracker under the menu button) |

Every keyboard key except fire and aim can be rebound in **Menu → Settings**. Mobile gets
on-screen Fire, Aim, Run, Reload, Pet, Slide and Move buttons; gamepads use R2 fire, L2 aim, L3 sprint,
X reload, Y companion, B slide and D-pad down for the Quick Movement key. On a phone the RUN button and on
a gamepad the L3 click **toggle** sprint (a thumb can't hold RUN and press SLIDE at once); on a keyboard
Shift is held. A toggled sprint switches off on death, respawn, sitting in a vehicle and opening the menu.

**Why fire and aim ignore `Cancel`.** ContextActionService sends `Cancel` to an action whenever
something binds the same input above it, and Roblox's own camera module rebinds its controls every
time the camera mode changes — which is exactly what aiming a scoped gun does, since scoped guns
drop into first person. Reading that `Cancel` as "you let go" is what made full auto cut out part
way through a burst and stopped ADS being holdable at all: aiming cancelled its own binding a frame
after it started. Both now ignore `Cancel` and poll the real button state instead
(`UserInputService:IsMouseButtonPressed` / `IsGamepadButtonDown`, with touch trusting the `End` it
will actually get). The polling isn't optional — a cancelled action never delivers its `End`
either, so without it the trigger would simply stick on.

### Settings

The **Settings** tab in the menu, saved to your profile so it follows you between servers:

- **Controls** — click any action and press a new key. Taking a key another action uses swaps the
  two, so nothing is ever left unbound. Movement, chat, Tab and Escape can't be taken. Every
  on-screen hint (the ready pill, the menu button, the companion panel, the spectate bar)
  follows your bindings.
- **Audio** — master volume plus separate sliders for weapons and hits, effects and pickups, and
  menus and crates. Each cue plays through a SoundGroup for its category, so a change applies
  immediately, even to sounds already playing.
- **Camera** — field of view (60–95; aiming zooms to about two thirds of it), look sensitivity
  and a separate aiming sensitivity.
- **Gameplay** — third-person camera, screen shake, damage numbers, gun sway and bob, the
  ambient map particles, auto-reload on an empty magazine, and the compass strip.

Each section has a RESET button. Defaults and ranges live in `StarterPlayerScripts/Settings.lua`.

---

## HUD and interface extras

Each of these is a ModuleScript, so `tools/hud_ux_gallery.lua` can render it on mock 1920x1080,
1366x768 and phone screens with the rest of the HUD outlined, and `tools/hud_ux_probe.lua`
(`runtest.ps1 -Probe`) can check it without a person watching.

**Match event banner** (`StarterPlayerScripts/EventBanner.lua`). A match's event no longer arrives as a
one-line toast. It lands as a big card under the compass: a round badge with the event's own icon (all
eleven drawn from frames, no image assets), a MATCH EVENT tag, the name, what it does, and a timer —
DROP IN 0:12 during the drop, then how long it has been live. The card sits above the crosshair and holds
for 3.2 seconds, then shrinks and flies into a compact pill beside the top banner (under the READY pill
while you spectate), which stays for the match. Tap or click the pill for the card again. It gets out of
the way at once when the drop screen opens.

**Tucking the menu stack away** (`StarterPlayerScripts/MenuStackToggle.lua`). A tab beside MENU slides
MENU, the bundle nudge and the quest tracker off to the left, leaving a tab with a menu icon and today's
quest count ("2/3"); tap it and they slide back. The choice is saved (the *Tuck the menu, bundle and
quest buttons behind a tab* setting under Gameplay). Tucked away, the tab lights up with a pulsing dot
when anything new comes in — a quest or weekly challenge done, the daily spin ready, a pass reward to
claim, a bundle delivered — until you open the stack again. **M** and **J** work either way.

**Inventory** (`StarterPlayerScripts/InventoryPanel.lua`). **B** (rebindable, through the same Settings
key list as every other bind) opens a panel of your eight slots — two rows of four, or four rows of two
on a narrow upright screen, where that panel is the hotbar — each with the gun or
item itself, its ammo on a chip over the icon, and its rarity and spare rounds underneath. Drag one onto
another to swap them (onto an empty slot, it moves), or tap one and then the other — both work with a
mouse and on touch; a gamepad taps with A. The swap shows at once and the server confirms it: the `SwapSlots` remote (whole
numbers 1-8 through `SafeValue`, at most 8 in a row refilling 6 a second) calls `WeaponService.SwapSlots`.
**What's in your hand stays in your hand**: the held slot's number moves with it, so there's no re-raise,
a reload in progress still finishes on that gun, and ammo moves with its gun. A timed item use (a bandage)
on a slot that moves is cancelled and nothing is spent, the same as switching slots. While the panel is
open the mouse is free and clicks don't fire: the panel's own full-screen overlay is a `Modal` button,
which unlocks the cursor for as long as it is up whatever the camera does that frame, so the panel can
never end up on screen and unusable. On a touch screen the hotbar keeps a small INVENTORY button as
well (a plain HUD button, so it costs nothing from ContextActionService's seven-button limit); on a
desktop screen there is no button, because the mouse is locked to the middle in a match and a button
you cannot click is worse than none.

**Placing defenses** (`StarterPlayerScripts/DefensePreview.lua`, `Shared/DefensePlacement.lua`). Hold a
Rot Barricade, Pop-up Bunker or Brainrot Fortress and a see-through copy of what will go up stands where
your throw will put it, its footprint outlined on the ground with a chevron at its front: green when the
site is good, red with the reason (NO GROUND THERE, TOO STEEP, NO ROOM) when it isn't, and REPLACES YOUR
OLDEST when a fourth would knock your first one down. The preview is the server's own maths, not a copy
of it: the placement rules (`FindSite`, the sizes, the throw's range and facing) moved out of
`DefenseService` into `Shared/DefensePlacement`, which both use, and the ghost is a clone of a structure
`DefenseService` builds with its real builders into `ReplicatedStorage.DefenseTemplates` (inert: nothing
in it collides, is queried or has a health bar). The aim is CombatClient's own crosshair point
(`AimState`). What the preview cannot assume is that the kit arrives where you aimed. A kit is lobbed on
an arc (`DefensePlacement.ThrowArc`, the one `DefenseService` throws it with) flat enough to clip a rising
hill, and measuring 72 real throws on SahurSprings (the gallery's `grip` section, in Run mode with
physics) put the first ground contact a median 10 studs from the aim point and the resting place 21 —
and no amount of friction, weight or bounce on the kit changed that, because most of the error happens in
the air. So the preview walks the same arc with a raycast per segment, stands the ghost where the throw
will really land, says *lands N studs short of your aim* when the arc is going to clip something, and
stops the dotted lob there instead of drawing through the hillside. The roll afterwards is the part
nothing can predict, and that is what the ring round the landing spot is for. The Rot Mine gets the lob
and the ring only.

**The lobby signpost** at the head of the pier has a finger for every place on the island: ROT EXPRESS,
CLOUD CLIMB, CRATE ALTAR, DAILY SPIN, TRADING HALL, COSMETICS, THE ARENA, THE PITCH and WALK OF FAME,
each a plank with a pointed end in that place's colour. Where each points is measured from the lobby as
it's built (the place's own sign, or for the pitch the biggest part of it), so moving a set piece moves
its finger, and a place that's been taken out loses its finger with a warning instead of pointing at
nothing — which is how the old signpost kept pointing at a disco and a market row that were gone.

**Three HUDs, not one that stretches** (`StarterPlayerScripts/PhoneLayout.lua`). A phone is not a small
desktop: drawn at desktop sizes on an 844x390 screen the HUD covered the middle of the screen and itself
(27 overlapping pairs, 44 at 667x375, 43 on a 320x568 phone held upright). `PhoneLayout.Mode(viewport)` is
the one place that decides which of three versions a device gets — **desktop** (the big HUD, unchanged),
**handheld** (a touch screen on its side) and **upright** (a touch screen held upright) — and every piece
asks it where to sit.

*Handheld*: the banner, storm line and compass shrink into a thin strip at the top; the minimap moves to
the left edge under Roblox's bar at 96 px, with the coin chip and a one-line companion strip under it; the
event pill, kill feed, bounty and location and the MENU, quest and camera icons run down the right; the
hotbar becomes four slots across and two down in the band between the thumbstick's zone and the buttons,
with the health row (rearranged into a single row) and the Inventory icon above it.

*Upright*: Roblox owns the lower half of that screen, so there is no band for a hotbar at all. This
version is deliberately smaller — no compass, kill feed, bounty, location or speed pill — and the hotbar
keeps only the slots that fit above the buttons and clear of the crosshair: four on a tall handset, three
at 375x667, and **none** at 320x568, where the Inventory button stands alone and the panel holds all
eight. The minimap, coin chip, companion strip, health and stamina all stay, small.

The rules every version keeps: nothing over the crosshair's box, nothing tappable inside the thumbstick's
zone, nothing under Roblox's own jump button or top bar, hotbar cells at least 44 pixels (40 on phones
under 700 across), and no two pieces overlapping — checked by the probe at seven named sizes and swept
over every landscape and portrait size in steps. The same numbers are swept in Python by
`scratchpad/phone_layout_map.py`, and the probe compares the two implementations rect by rect.

`PhoneLayout.Mode` is not `UiKit.form`, and the two are meant to disagree: `form` asks what shape a screen
is (for the menu's panel), `Mode` asks what the device is (for a HUD that must dodge Roblox's own
controls). A tablet held upright at 768x1024 is `large` to one and `upright` to the other. They share no
words on purpose.

The centred panels get the same treatment through `PhoneLayout.FitPanel`: the menu (760x480), the drop
screen (480x536), the results card, the map vote and the match recap each carry a UIScale that keeps them
inside the screen with a 16-pixel margin and never grows them, so a phone shows the whole menu and the
whole landing map (0.62 and 0.67 of their size at 844x390) while a desktop screen is left at exactly 1.

`StarterPlayerScripts/TouchControls.lua` is the companion piece for the buttons themselves — one owner
for the FIRE / AIM / RELOAD / RUN / PET / SLIDE / MOVE cluster, in the slots PhoneLayout gives them,
instead of ContextActionService's own set (which draws at most seven, so the eighth binding used to
vanish). It is finished but **off** (`TouchControls.Enabled = false`), and while it is off `Settings.Bind`
behaves exactly as it always did; turning it on is a deliberate change after a phone playtest.

---

## Publishing and playing on a phone

Two ways to get the current build onto Roblox so it can be played from the app:

1. **From Studio** — with the place open, `File → Publish to Roblox As…`, pick a name, and it's
   live under your account. Later builds: `File → Publish to Roblox` (Alt+P) after rebuilding
   and reopening. Then `Game Settings → Security → Enable Studio Access to API Services` so
   saving works, and `Game Settings → Permissions → Private/Friends` while testing.
2. **From the terminal** — `tools/publish.ps1` uploads `BrainRotRoyale.rbxlx` through the Open
   Cloud API without opening Studio. One-time setup: create the experience once (route 1 or the
   Creator Dashboard), create an Open Cloud API key with *Place Management: Write* scoped to it,
   and set it in your shell as `$env:ROBLOX_API_KEY`. Then:

```bash
powershell -ExecutionPolicy Bypass -File tools/publish.ps1 -UniverseId <universeId> -PlaceId <placeId>
```

Either way, open the Roblox app on your phone, go to your creations (or search the name) and
Play. The game is touch-ready: on-screen FIRE, AIM, RUN, RELOAD, PET and CAM buttons, tap the
hotbar to hold a slot, tap the screen to use an item, drag to look, and the CAM button switches to
third person. A private experience is playable by its owner from the app.

---

## What the server trusts

Everything a client sends is a request, never a fact. Two rules cover the remote surface:

- **Values.** Anything a client sends goes through `Shared/SafeValue.lua` before it reaches physics,
  a raycast or a broadcast. NaN fails every comparison, so a plain size check lets it through; each
  component is tested on its own.
- **Rates.** `Modules/RateLimit.lua` holds one named budget per remote, with the legit peak each is
  sized against. Calls that can be dropped (a shot, a reload, a click) are dropped over budget;
  calls that set a state (equip a slot, aim, ready, spectate, settings) keep the newest value and
  apply it once a token frees, so the server always ends up in the state the client last asked for.
  Nothing kicks, nothing warns the player, and the budgets sit well above real play: the fastest gun
  fires 14 shots a second against a budget of 20. `RequestProfile` answers from a one-second cached
  snapshot instead of rebuilding, and a trade invite has a ten-second cooldown per target.

`tools/verify.py` fails if any client remote is neither limited nor listed in `RateLimit.Exempt` with
a reason, and if a new gun ever fires faster than the Fire budget allows.
`tools/ratelimit_probe.lua` measures both halves: real client patterns lose nothing, floods are cut
to the budget.

---

## Saving

DataStores need a published place. Until then the game runs normally but nothing persists —
`PlayerData` catches the failure, warns once in Output, and hands out temporary profiles.

To enable saving: `File → Publish to Roblox As...`, then
`File → Game Settings → Security → Enable Studio Access to API Services`.

**One server at a time owns a profile.** The key holds an envelope —
`{ v = 2, profile = …, lock = { jobId, at }, version = n }` — written with `UpdateAsync`, so reading and
writing are one atomic step. Joining takes the lock; every save refreshes it and bumps `version`, and a
save whose `version` is behind what's stored is refused, so an older write can never land on a newer
one. Only one save per player runs at a time: a save asked for while one is in flight sets a flag and
the running save goes round again with the newest state.

Without this, a player who left server A and joined server B before A's save landed was loaded from a
stale copy, and whichever server saved last won — duplicating or destroying coins, crates, Brain Cells
and traded brainrots. Now B waits (`LOCK_WAIT_SECONDS`, 16 s), and if the profile really is still open
elsewhere it asks the player to rejoin rather than opening a second copy. A lock is only taken over
once it has gone stale (`LOCK_STALE_SECONDS`, 150 s), which is two and a half autosaves: a live server
that simply hasn't saved lately looks exactly like a crashed one, and stealing from it would hand out
the second live copy this is meant to prevent. So a crashed server's profiles are locked for up to
150 s, which is the price of never running two copies. Shutdown releases every profile in parallel
(`PlayerData.ReleaseAll`), clearing the locks so the next server loads at once.

A **DataStore outage is never a lockout**: errors give the old behaviour — a temporary profile that
doesn't save, a warning, and no kick.

**Trades** refuse to run if either side's profile can't be written (a temporary profile, or a lock lost
to another server), because the brainrots would move in memory and die with the session. A completed
trade is never rolled back: both profiles are saved right after the swap and retried by autosave, since
undoing one side after the other has saved is what creates and destroys items. The remaining window is a
hard server crash in the few hundred milliseconds between the swap and both saves; closing that needs a
two-phase journal, which isn't built.

**Adding a field to a profile** is additive: give it a default in `defaultData()` and clean it in
`reconcile`. A field this version doesn't know is carried through untouched rather than dropped, so a
server still running older code during a rolling update can't silently delete newer data. That only
covers whole top-level fields — a new key inside a known table is still cleaned away — so new data
belongs in its own top-level field. `tools/playerdata_probe.lua` proves all of this against a stub
DataStore with injected latency and failures and two simulated servers, each case alongside a control
that recreates the old behaviour and fails.

---

## Tuning

| What | Where |
|---|---|
| Placement rewards, storm schedule, spawn spread, bot difficulty | `Shared/MatchConfig.lua` |
| Players per match and how many bots fill it | `MaxPlayers`, `BotFillTarget` in `Shared/MatchConfig.lua` (and the place's Max Players in Game Settings) |
| Z-fight tolerance and the gap the pass leaves | `ZFight.Tolerance`, `ZFight.Gap` in `Shared/ZFight.lua` |
| Daily Spin prizes, weights, streak bonus | `Shared/DailySpinData.lua`; prizes paid in `BattlePassService.applySpinPrize` |
| Crate and chest models | `Shared/CrateModels.lua` |
| Hills, ridges, craters, dunes, river, plateaus, patches, snow, clouds | `Modules/MapTerrain.lua` |
| How far above a fill's top the terrain surface sits | `MapTerrain.SurfaceLift` (2; measured, not a preference) |
| Ziplines (reach, speed, hang height) | `REACH`, `RIDE_SPEED`, `HANG` in `Modules/ZiplineService.lua` |
| Landmark pool and each map's signature landmark | `LANDMARKS`, `SIGNATURE` in `Modules/Landmarks.lua` |
| Movement item strengths (soda, rocket, pad, blink, boots, glider) | constants atop `Modules/MovementService.lua` |
| Stamina, slide curve, air momentum, climb and vault limits and timings | `Shared/MovementConfig.lua` (read by the server, the client, the HUD bar and the probes) |
| Rocket aim, double-jump strength, glider handling | top of their sections in `StarterPlayerScripts/MovementClient.client.lua` |
| Bots' drop-in (fall speed, drift, timeout) and where they steer | `BOT_DROP_*` in `Modules/MovementService.lua`; `pickDropTarget` in `Modules/BotService.lua` |
| Explosive barrels (health, blast radius and damage, chain delay) and where they stand | constants atop `Modules/HazardService.lua`; the barrel odds in `buildInterior`, `buildCrate` and `addLoadingDock` in `Modules/MapGenerator.lua` |
| Rot Mines (arm time, trigger reach, blast, lifetime, size) | `MINE_*` in `Modules/HazardService.lua`; loot weight in `Shared/ItemData.lua` |
| Bots' rockets (how many, cooldown, when they fire one) | `BOT_ROCKET_*` in `Modules/BotService.lua` |
| Compass strip (size, degrees of view) | `COMPASS_*` in `StarterPlayerScripts/HudClient.client.lua` |
| Rot Vendor products and prices | `VendorService.Products` in `Modules/VendorService.lua` |
| Match events and their odds | `Shared/MatchEvents.lua` (`NoneChance`) |
| Map sizes, terrain, density, material palettes, time of day per map | `Shared/MapData.lua` (`MapData.Lighting`) |
| Gun stats and abilities | `Shared/WeaponData.lua` |
| Which gun does what to a body, and the effects themselves | `WeaponData.KillEffects`; `Modules/DeathFxService.lua` (`RAGDOLL_LINGER`, the `EFFECTS` table); sounds in `Shared/SoundConfig.lua`; the body sounds and self-shove in `StarterPlayerScripts/DeathFxClient.client.lua` |
| Bot headshot rate | `BOT_HEADSHOT_CHANCE` in `Modules/BotService.lua` |
| Heals, shield potions, movement items (amounts, caps, use times, stacks, loot weights) | `Shared/ItemData.lua`; models in `Shared/ItemModels.lua`; effects in `Modules/MovementService.lua` |
| Portable defenses (health, size, per-player cap, builders) and their loot chances | `Modules/DefenseService.lua`; `CHEST_DEFENSE_CHANCE`, `GROUND_DEFENSE_SHARE` in `Modules/LootService.lua` |
| Max shield | `MaxShield` in `Shared/MatchConfig.lua` |
| Robux bundles and featured deals | `Shared/GamepassConfig.lua` |
| Brainrot rarities and sell values | `Shared/BrainrotData.lua` |
| Crate prices and odds | `Shared/CrateData.lua` |
| Pass curve and daily rewards | `Shared/BattlePassData.lua` |
| Audio cues | `Shared/SoundConfig.lua` |
| Chest / ground / heal density | constants atop `Modules/LootService.lua` |
| Ammo from pickups | `WeaponService.GiveAmmo` — grants a *fraction of each gun's own reserve* (floor gun 25%, chest 40–90%, supply drop 100%), capped at 2× reserve |
| Building shape, windows, stairs, roofs | constants atop `Modules/MapGenerator.lua` |
| Street furniture, vegetation, town names | `Modules/MapDecor.lua` |
| Easter eggs, their lines and rewards | `Modules/EasterEggs.lua` (`EGG_COINS`, `EGG_XP`, `OBBY`) |
| Accessory shapes, prices, rarities | `Shared/CosmeticData.lua` — pieces are plain data, scaled to the wearer |
| Accessory drop chance per crate | `accessoryChance` in `Shared/CrateData.lua` |
| Bot heal behaviour | `BotHeal*` in `Shared/MatchConfig.lua` |
| Rarity tiers and colours | `Shared/Rarity.lua` |
| Companion health, ability power and cooldown | `RarityHealth`, `AbilityPower`, `AbilityCooldown` in `Shared/BrainrotData.lua` |
| Companion levelling (XP per level, max level, bonus per level) | `MaxLevel`, `XpPerLevel`, `BonusPerLevel` in `Shared/BrainrotData.lua` |
| Crate pity guarantees | `pity` per crate in `Shared/CrateData.lua` |
| Achievements and titles | `Shared/AchievementData.lua` |
| Item crates, jackpots, duplicate refunds | `category`, `jackpot`, `duplicateRefund` in `Shared/CrateData.lua` |
| Shop rotation length, cosmetic slots, rarity weights, crate stock chances | `Shared/ShopRotation.lua` |
| Default keybinds, volumes, camera and toggles | `StarterPlayerScripts/Settings.lua` |
| First-person gun placement and motion | `VIEW_HIP`, `VIEW_ADS_DISTANCE` and the viewmodel block in `StarterPlayerScripts/CombatClient.client.lua` |
| Third-person arm pose | `StarterPlayerScripts/GunPoseClient.client.lua`; grip position in `HAND_OFFSET` in `Modules/WeaponService.lua` |
| Scope zoom per gun | `SCOPE_ZOOM` in `StarterPlayerScripts/CombatClient.client.lua` |
| Gun model detail | `WeaponService.BuildGunModel` — the moving parts are found by name |
| Building facade detail | `dressWall`, `dressGround`, `addBalcony`, `addLoadingDock` and `SHOP_NAMES` in `Modules/MapGenerator.lua` |
| Lobby layout, play balls, goal, altar, wheel, disco, Cloud Climb | `PLAZA_RADIUS`, `RIM_RADIUS`, `STALL_RADIUS`, `BALLS`, `GOAL_PAY_COOLDOWN`, `STAGE_TIME`, `CANOPY` and the builders in `Modules/LobbyService.lua`; the podium ring in `ShowcaseService.RING_RADIUS`; goal and Cloud Climb rewards in `Bootstrap.server.lua` |
| Daily quest pool, targets, rewards, bonus crate | `Shared/QuestData.lua` |
| How much room things need on the map | footprint radii in `Modules/MapDecor.lua` (`MapDecor.Prop`, `MapDecor.Town`) and `FURNITURE_RADIUS` in `Modules/MapGenerator.lua` |

---

## Known gaps

- **No uploaded audio.** Every cue is built from the sound files the Roblox client itself ships.
  That used to mean one stand-in file per cue, on the belief that only 11 remained; measuring it
  with `tools/sound_probe.lua` found **23**, and the cues are now layered recipes over 21 of them
  — a gunshot is a sharp transient, an explosion body and a mechanical tick, compressed and
  lightly distorted, rather than a single sped-up explosion. Reloads are a catch, a mag seating
  and a click, spaced by real delays. Effects are used where they earn it: flange on the zipline,
  tremolo on the shock death, reverb on a crate opening. It is still not recorded audio, and it
  won't sound like a shipped game, but it is composed rather than improvised. Your own shots play
  flat; everyone else's are positional (audible out to 420 studs), so gunfire tells you where
  fights are. To use real audio, put Creator Marketplace ids in a cue's layers — nothing outside
  `SoundConfig` needs to change. Re-run the probe before trusting any claim about what ships;
  two cues once pointed at files that had been removed and silently played nothing.
- **Built from parts, not meshes.** Guns, pickups, brainrots and accessories are all assembled
  from primitive parts with textured materials. To use uploaded meshes instead, swap
  `WeaponService.BuildGunModel` and `BrainrotModels.Build`; everything else reads from those.
  For brainrots there's a shortcut: put a Model in a `ReplicatedStorage/BrainrotModelOverrides`
  folder, named exactly after a brainrot, and it's used everywhere instead of the built one
  (menu photos, podiums, companions, crate reveals). It's scaled to a standard height and
  anchored automatically. Only use models you made or have the rights to.
- **Bots use only one movement item.** They drop in under canopies and fire Rot Rockets to get
  out of a losing fight, but never use Speed Sodas, pads, beans, boots or gliders. They carry
  and use Bandages, Med Kits and shield potions — looted from chests and supply drops at the
  same rates players get, used once they've broken line of sight and dropped on death — and
  regenerate slowly when they have none. They contest supply drops too, holding for the same
  1.2s a player must and giving way to anyone already mid-hold. Loose shield pickups they walk
  past, they never buy from a Rot Vendor or aim at an explosive barrel, and they don't throw or
  avoid Rot Mines (they do set them off).
- **Bots hold their weapons, but have no aim stance.** They used to carry exactly three stock R15
  animations — idle, walk and run, picked on speed alone — so a bot holding a rifle played the
  same cycle as one holding nothing. They now also carry jump and fall tracks, so they stop
  walking through the air, and the stock tool pose at Action priority so it layers *over* the
  movement track instead of replacing it. Every id was checked with `tools/anim_probe.lua` first,
  because `setupAnimations` wraps each load in a pcall and drops failures silently: a wrong id is
  not an error, it is simply no animation. The harness confirms it: every living gun-carrying bot
  is playing the hold pose. The count it prints is the survivors, not the spawn total, because the
  check runs after the death-effect tests have killed nine of them.

  Getting there was instructive. The pose read as dead for several runs and was written up here as
  broken, which was wrong: `BotService.Start()` spawns the tick that calls `updateBot`, which is
  what drives animation, and the harness only ever called `Spawn`, `GetAll` and `Count`. Bots under
  test were static mannequins, `bot.currentTrack` read nil for all of them, and no bot animation had
  ever run in a check — including the three tracks that predate this. A behaviour that is never
  executed looks identical to one that is broken.

  What is still missing is an **aiming** stance. None of the stock animations that resolve is one,
  so a bot lining up a shot looks like one walking with a gun. A real aim pose would need uploaded
  animation, and their rigs are physics rigs driven by animation constraints rather than Motor6D
  joints, so hand-posing the arms is not an alternative.
- **The current build has not been hand-playtested.** `tools/runtest.ps1` compiles every script
  and boots the server (lobby, map, loot, bots, defenses, death effects) clean, but the client
  side — the third-person camera and scroll zoom, item viewmodels, the eight-slot hotbar on a
  phone screen, menus, the thrown defense kits, the glider's sailing, zipline rides, the new gun
  models in first person, the Crate Altar's prompts, the wheel landing on its announced prize,
  and how a *player's* own body ragdolls, floats or freezes (bots are verified; players are shoved
  through `DeathFxClient`) — has only been checked statically. Expect to tune camera offsets,
  item hand positions, the drop-in fall speed, effect timings and the lobby set-piece placements
  once someone plays it.

  Everything added recently lands on that same list, and some of it is feel rather than
  correctness, which no harness can judge: whether a **slide** is worth pressing and whether its
  camera dip reads as coasting or as a stumble; whether the **firing range** is fun and whether
  losing the gun on leaving the terrace is obvious or annoying; whether **walls breaking** changes
  fights for the better or just removes cover; whether the rebuilt **brainrot bodies** read better
  at inventory size, not just in a part count; whether the **layered audio** is an improvement or
  merely busier; and whether the **compass**, the **auto-reload** and the enlarged **Daily Spin
  wheel** sit right on screen. The server side of all of it is measured — wall health, sound ids,
  clipping, z-fighting — but measured is not the same as good.
- **Bots don't shoot companions.** Bot gunfire resolves straight against its target character,
  so only players' bullets, explosions and other companions' splash can down a companion. Bots'
  own companions can be downed like anyone's.
- **No anti-cheat beyond server authority.** The server owns raycasts, damage, ammo and fire
  rate, which covers the obvious exploits, but there's no movement validation.
- **Untested at 50 real players.** Everything has been verified statically and the structure
  is sound, but the only live runs have been solo-with-bots. The place's own Max Players (Game
  Settings) has to be raised to 50 by hand when publishing.
