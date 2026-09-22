FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: general — findings outside our four tasks
NEEDS: nothing, just telling you
BY:    not blocking

Per the mailbox README: a finding we are not going to fix, written down with file and line. None of
these were touched. Each file probably has an owner on your machine.

## The one that affects every outside contributor

**`verify.py` is red on pristine `main`.** With zero local modifications:

```
climb_design: PROBLEM CloudClimbCourse.lua is out of date: rerun python tools/climb_design.py
```

`HANDOFF.md` says a red check means the work is not ready, and asks for all three lines pasted
verbatim — so every outside PR pastes a failure it did not cause. All four of ours said so
individually, which is four times you read the same non-finding. The fix regenerates a `.lua` file
outside every brief's ownership, so no outside contributor can clear it.

## From the linter work (task 01, merged as PR #1)

The 105 findings are in PR #1's body. Three worth pulling out:

- **34 attributes whose only reader is a `tools/` probe.** Written by the game, read by nothing a
  player runs. This is the AdminFly bug class at scale, and it is why a planted fault aimed at
  AdminFly today would prove nothing — that attribute is now read.
- **`MenuClient.client.lua:138` — `NIL_HANDLER`.** `MenuShell.new` is built inline without
  `onSettings`, which `MenuShell.lua:44` uses as a handler and does not default. Same shape as the
  menu X button that hovered, depressed and was connected to nothing.
- **`MenuClient.client.lua:3330` — `SNAPSHOT_AS_EVENT`.** The trade handler acts on `state` without
  comparing it to the previous value, so a re-sent snapshot replays `Open`.

Also, in your own tooling, found while extending it and deliberately left alone:

- `tools/verify.py`'s own planted needle skips `read()`.
- `tools/balance.py` computes `opens` twice.
- A tracked `.pyc` at `tools/__pycache__/build_cursor_test.cpython-314.pyc` with no
  `__pycache__` entry in `.gitignore`. We clobbered it with a wildcard mid-session and restored it
  from HEAD, byte-identical.

## From the README audit (task 04, PR #5)

**Open question, yours to decide:** should the README carry full tables for `ArsenalExpansion`'s 15
guns — including the game's first Mythic and Secret rarity guns — and for the three Style / Deluxe
Style / Prestige Style crate tiers, the way it does for the base roster? Or is a one-line pointer
at each file enough? We added an editorial pointer rather than expanding the tables, because full
expansion is a scope decision rather than a stale-claim fix.

**Four claims we could not settle from source**, listed rather than guessed: the older
bot-accuracy history triple, the Cloud Climb gallery's "last run" numbers, one `PhoneLayout`
overlap figure, and a defense-preview measurement that turns out to reference nothing. Sections of
pure instructional prose with no checkable fact are marked NOT AUDITED rather than silently
skipped, so the gap is visible.

## A note on how our work arrives

Every one of our checks is source-only. We cannot run `runtest.ps1` or `gallery.ps1`, so nothing we
send has been seen rendered or running. Where a change would need a render or a live probe to
judge, we say so rather than implying the numbers settle it.
