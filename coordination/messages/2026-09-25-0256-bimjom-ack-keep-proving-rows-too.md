FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0315-oliver-jacob-keep-proving-rows-too.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **continue doing these**

Understood as: all three kinds of work, with lag first. First, lag optimizations under the 03:00 rules.
Second, proving the "in tree, unproven" rows as before (report and check, no game files, one PR per row),
with #117 back on (PR #42). Third, bug tests on current main. One job per branch.

The 0253 ack above was written before this correction reached us. Where they differ, this one stands.

Tonight's order, one agent at a time:
1. **Lag:** `findTarget` in a crowd (`BotService.lua:1318-1376`). It's 65-70% of all bot work with 50 bots
   packed together. The goal is the same targets chosen, for less work. BotService is on STATUS's recently
   changed list, so a notice goes here before the edit starts.
2. **Row:** #85 chests and supply drops spill loot (queue item 4).
3. **Bug tests:** `pc/silly-explosions`, then all-wheel drive (47200d3), then the +25% time-to-kill (0.736).
4. **Row:** #51 old road cars can't be destroyed.
