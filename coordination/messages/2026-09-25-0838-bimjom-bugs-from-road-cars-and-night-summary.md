FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports from the #51 road-cars proof (PR #51), and a summary of tonight's PRs
NEEDS: nothing, just telling you (the build machine owns the fixes; items 3-4 are Oliver's calls)
BY:    not blocking

#51 holds on main d1e4f73: all 79 parked road cars on 5 maps break, and every hittable part reaches the
pool.

1. **A wrecked drivable is permanent, indestructible cover in a battle royale match.** Measured 10 s
   after the wreck; that it stays all match is reasoned (no code removes a wreck outside the team
   modes). `VehicleService.lua:1159-1162` returns 0 on a wreck, `DestructibleService.lua:416` refuses
   it, and the model stays, collides and stops bullets (`CombatService.lua:955-956`). Only team bases
   clear wrecks (`ModeTeams.lua:1151-1156`). Should a road wreck break, or go away?
2. **A noclip round double-hits a map pool at full damage** (measured: 8 hits from 4 shots).
   `CombatService.lua:930-939` counts the next part of the same car as the next wall, and map damage
   at `:920` uses `def.damage`, never the `through` scale that the player path applies (`:956`). This
   affects AdminOverride.
3. **Oliver's call: the parked and drivable cars of one design are far apart.** A parked car has 240
   health and takes raw damage: 9 rifle hits, 2 rockets (`MapDecor.lua:380`). The drivable version has
   1,400-1,650 at x0.736: 71-84 hits, 3-4 rockets (VehicleArmor). Since #16/#94 they look the same.
4. **Oliver's call: bots' bullets never damage map cover, parked cars included** (reasoned).
   `BotService.lua:1268-1297`. Only a bot's launcher rounds break cars or walls.

**Tonight's PRs** (all from this clone, all reviewed here before pushing, and all rerun on main):
- #42: #117 trial guns proof
- #43: bot-lag proof and harness
- #45: lag, `findTarget` (−20% at packed-50, same decisions)
- #47: #85 loot spill proof
- #48: silly-explosions bug test
- #49: all-wheel drive bug test (the red `bot_driving_sim` comes from the AWD split)
- #50: +25% time-to-kill bug test
- #51: #51 road cars proof

Mailbox PRs: #41, #44 and #46. We're stopping here for now. The 0830 handoff list waits for Jacob.
