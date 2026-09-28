FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: 6 bugs and 2 calls for Oliver from the #85 loot-spill harness (PR #47), on main d1e4f73
NEEDS: nothing, just telling you (the build machine owns the fixes; items 7-8 are Oliver's calls)
BY:    not blocking

For players, #85 holds: every container spills its whole roll on the ground. What doesn't hold, most
important first. Each item says measured (from `tools/loot_spill_proof_check.py`) or reasoned.

1. **Pads can end up inside a wall** (measured). `clearOfWalls` (`LootService.lua:851-862`) adds up the
   push from every side and never re-checks the result. At TowerBase, a pad 0.09 studs from a `TowerLeg`
   was pushed 2.1 studs into the perimeter `Wall`: 3-5 of about 2,960 pads per run. It affects every
   scattered drop. The `pc/teambase-v2` compound has none.
2. **Spilled pickups stack on one point** (measured). The jitter is whole studs, `math.random(-4, 4)`
   (`LootService.lua:881`). On flat ground, 13% of chest spills (47 of 352) put two pickups on the very
   same point. A throw over an edge falls back to the chest's own spot (`:890-898`): 26-27 of 60 roof
   spills and 56 of 60 gallery spills stacked, and 185-189 of 672 at the real team-base layout. Nothing
   is lost, but the prompts overlap.
3. **Bots take a spill during its settle second** (measured). The bot claims check `Claimed`, not
   `Settling` (`LootService.lua:1057`, `:1102`, `BotService.lua:5103`). A bot took a crate's gun, MedKit
   and Shield Potion 0.05 s after the spill landed. The real window is probably small (the 1 s loot
   snapshot plus the 0.3 s hold), but that part is reasoned.
4. **`Resettle` rebuilds a spill without the settle and outside the 50-drop cap** (measured,
   `LootService.lua:989`, `:995`).
5. **Pads sit inside the chest or crate while it stands** (measured, cosmetic). 6% of chest pads sit
   inside the chest for up to 2.2 s and can be taken from 1.0 s. 16-20% of crate pads sit under the crate
   for its 1.6 s.
6. **Dead code:** `LootService.GiveOrDrop` (`:1011`) has no callers.
7. **Oliver's call: bots skip the spill entirely** (measured). `LootService.ClaimForBot`
   (`:1057-1080`) and `SupplyDropService.ClaimForBot` (`SupplyDropService.lua:386-398`) hand the bot one
   gun, and 0 pickups land. The same chest opened by a player lands 2 guns and 1-5 items. Does #85 cover
   bots?
8. **Oliver's call: the pile-ups** (measured). The 50-drop cap removes an untouched spill, Legendary
   included, after 47 newer drops. Battleground gun spots count as taken only within 3 studs, but seeds
   scatter up to 5.7 (`TeamBattleground.lua:3649`, `:3683`), so the 14 spots grew to 17-39 guns over a
   480 s match.

Next from here: the bug tests on tonight's landings, starting with `pc/silly-explosions` (57fd4f0,
f9f0af6), then all-wheel drive (47200d3), then the +25% time-to-kill (0.736).
