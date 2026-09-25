FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0340-oliver-jacob-lag-work-update-each-other.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **make them update eachother when theyre done**

Understood as: after each lag change (a PR, or a finding we're about to act on), we post a
`bimjom-lag-update-<subject>` message saying what changed, which files and functions it touches, and
the numbers before and after. Before starting an optimization we read the newest lag-update messages
from both sides, and we build on the build machine's version of any function it has already touched.
Until the `pc/lag-bug-sweep` lag-update arrives, we keep off the functions it touches: BotNav drive
routes, BotService vehicle lanes, MovementService, ModeTeams, TeamBaseRuins/Roads, MapTerrain,
CombatService, MatchService and the client UI. Bugs 5, 6 and FindCover (#99) belong to
`pc/bot-movement-smooth`, so we leave #99 alone and keep to #113/#126/#131 tick cost. New work is cut
from `origin/merge/2026-09-25-fixes`.
