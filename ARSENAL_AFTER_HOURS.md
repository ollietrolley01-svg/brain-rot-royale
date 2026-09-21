# After Hours: 15 new weapons

The local source and rebuilt `BrainRotRoyale.rbxlx` include this additive pack. Existing weapon IDs, saves, mechanics and animations remain compatible. These guns use the same server-authoritative combat and loot system as the original 27, bringing the roster to 42.

| Tier | Weapon | Design and role | Reload / action |
|---|---|---|---|
| Common | Pistacchio Pum | Two-tone compact pistol, pawnshop stamp, inexpensive starter | Magazine swap, slide rack and empty slide lock |
| Common | Sceriffo Sgrunf | Short working revolver, walnut grips, star insignia | Swing-out cylinder, speedloader, hammer cock |
| Common | Ciabatta Clonk | Charcoal security shotgun, amber identification plate | Shell feed and moving pump |
| Uncommon | Scrolla Scrolla Brrrap | Midnight-blue folding-stock SMG, holo and laser, ONE MORE MAG stamp | Magazine swap and charging handle |
| Uncommon | Scarponcino Trotto Trotto | Short olive ranger rifle, iron sights and light | Magazine swap and charging handle |
| Rare | Prato Prato Pium | Green scoped scout, grass insignia, penetrating shots | Magazine swap and charging handle |
| Rare | Silenzio Sussurrone | Slate bolt rifle, fluted barrel, NO SIGNAL stamp | Magazine swap and hand-worked bolt |
| Epic | Piccolino Ratatatà | Berry suppressor-equipped drum SMG, L + RATIO stamp, modest lifesteal | Drum swap and charging handle |
| Epic | Porta Porta Bonk | Yellow semi-auto drum shotgun, EXIT stamp, modest lifesteal | Drum swap and charging handle |
| Legendary | Scontrino Infinito Brrrrr | Cream-and-charcoal belt-fed gun, ammo-box receipt, coin bonus | Feed-cover opening, belt/box replacement, charging handle |
| Legendary | Pranzo Della Nonna Bum | Walnut-and-brass heirloom lever rifle, coin bonus | Individual rounds and lever cycle |
| Mythic | Occhietto Pium Pium | Ivory-and-titanium evaluation rifle, holo, light, foregrip, small chain arc | Magazine swap and charging handle |
| Mythic | Nanna Nanna Puff | Long plum-finished bolt rifle, moon detail, modest lifesteal | Magazine swap and hand-worked bolt |
| Secret | Capo Supremo Bonkolone | Black/mint prototype pistol, laser and light, penetrating shots | Magazine swap, slide rack and empty slide lock |
| Secret | Ultimo Bum | Burgundy wooden AK furniture, stamped receiver, coin bonus | Curved magazine swap and side charging handle |

All fifteen inherit the actual first-person Viewmodel system: gloved hands, ADS aligned to their sight keypoint, recoil, reload sounds, moving action groups, equip/rack, running, and reload cancellation. Revolvers cock their hammer instead of pretending to have a slide. The original third-person holding/pose system remains in use; this pack does not add uploaded third-person animation assets.

The visual variants change furniture, barrel/stock/optic/accessory combinations and individual finishes. Small printed markings sit on real surfaces. Identification plates retain their host's animation group. Player skins remain authoritative over the finish; no giant props obstruct the sights.

## Obtaining the guns

Common and Uncommon additions enter floor loot and chests. All higher tiers are chest-only through the existing weighted weapon roll. Mythic and Secret are newly represented in the weapon pool; they were previously collection rarities only. Their weights are intentionally very low: 0.18 per Mythic and 0.045 per Secret, versus 0.65 for each new Legendary. These are relative weights, not percentages. Adding weapons changes the normalized odds of individual guns.

Rare tiers emphasize identity and utility, not automatic victories: each new single-bullet body shot stays below 100 damage, Secret guns have small magazines, and heavier guns pay for capacity with reload time. Balance figures need player feedback; they are initial tuning, not a claim of competitive validation.

## Files and verification

- `ReplicatedStorage/Shared/ArsenalExpansion.lua`: roster, stats, supported variants and expected mechanisms.
- `ReplicatedStorage/Shared/ArsenalFinish.lua`: finishes, markings and small attached serial plates.
- `WeaponData.lua`: additive registration before the loot pools are created.
- `GunModels.lua`: variant registration and finish hook; existing animation contracts remain the authority.
- `tools/arsenal_probe.lua`: Roblox runtime checks for both model detail levels, ADS alignment, running/aim transitions, rack movement, empty and partial reloads, cancellation, equip, firing, sounds and casings. Afterwards it displays all 15 guns for review.

Run the project's `python tools/balance.py .` and `python tools/verify.py .`, then `python build_place.py .`. The probe can be run with the existing `tools/runtest.ps1 -Probe tools/arsenal_probe.lua -WaitSeconds 240` where Windows has a working Roblox place-file association, or pasted into Studio's Lua command bar. The preview temporarily adds a selected review folder; use Studio's Zoom To selection to view it. Do not save that temporary scene over the game source build.

The runtime animation probe passed 593 checks with zero failures against the current weapon modules. Later concurrent work added 20 staged weapons, so the current full catalog contains 62 IDs while 42 remain in live loot.

## Inventory cursor and lobby range repairs

`StarterPlayerScripts/MenuCursor.client.lua` keeps the cursor visible and free while the shared `MenuOpen` flag is set, including when the first-person camera tries to relock it. It releases ownership when menus close so combat, vehicles and spectating can choose the correct current mode. Its isolated Studio client test passed 282 checked frames, including repeated open/close cycles and a competing camera lock writer.

`CombatClient.client.lua` now refreshes camera mode when the rack sends `RangeState`. Waiting/countdown updates no longer clear held range ADS or firing. `RangeService.lua` broadcasts normal shot feedback on hits and misses, uses each weapon's pellet count and ADS spread, and enforces equip readiness, fire rate, ammo and reload restrictions. Raycasts still include only practice targets.

`tools/build_cursor_test.py` and `tools/build_range_test.py` create isolated Play fixtures in the sibling `brain-rot-royale-playtest` directory. Their probes use production scripts without running the full match or saving player profiles.

The range fixture passed 231 server/client checks across all 15 additions: valid hits, pellet counts, misses, shot broadcasts, ammo, empty magazines, reload and fire-rate guards, invalid vectors, menu/camera transitions, range cleanup and match/area gates. The client received all 30 expected shot events. Production animation checks cover ADS alignment and running/reloading/racking; sustained physical mouse-input feel still benefits from human playtesting.

Backups of the two edited original modules and the previous place are in `../brain-rot-royale-backups/codex-arsenal-20260917/`.

The changes are local. No experience has been published.
