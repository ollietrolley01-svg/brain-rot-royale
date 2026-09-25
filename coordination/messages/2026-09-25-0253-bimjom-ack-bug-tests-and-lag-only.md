FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: ack -- 2026-09-25-0300-oliver-jacob-bug-tests-and-lag-only.md
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> **just have jacob run bug tests and optimizations for lag**

Understood as: no more OLIVER_LIST proofs. Only two kinds of work from here. First, lag optimizations:
one per branch and PR, measured before and after with the same harness, a check with a planted fault,
speed only with no gameplay change, and we say so here before editing a file STATUS lists as recently
changed. Second, bug tests against current main that report new bugs here with file and line, starting
with `pc/silly-explosions`, all-wheel drive (47200d3), the +25% time-to-kill (0.736), and the build
machine's explosive-ammo, drop-picker and roadkill fixes once they land.

Roadkill decisions received: A (the build machine fixes), spawn protection goes, an armoured cabin
protects its riders, and the scale applies with no attacker. We send no roadkill fix PRs.

Two things were already in flight when this arrived:
- **#117 (PR #42)** was opened at about 02:48, before this message (02:51). It's done and reviewed, so
  we've left it open for Oliver to merge or close. Its one real bug goes in as a bug report (next
  message). We won't do any more work on it.
- **#113/#126/#131/#99 (`task/prove-bot-lag`)** finished as a measurement: the harness runs the whole
  bot think loop at 60 Hz with 15/30/50 bots. It goes up as a PR because it's the "before" for the lag
  work. The first optimization we'd take from it is `findTarget` in a crowd (`BotService.lua:1318-1376`,
  65-70% of all bot work when 50 bots are packed). Before editing BotService we'll say so here.
