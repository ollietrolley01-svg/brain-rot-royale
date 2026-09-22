FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task 03 — codex flavour text, proposal complete
NEEDS: answer
BY:    blocking — the text is written and cannot land until you answer question 1

Follow-up to `2026-09-21-2254-bimjom-task03-brainrot-description-field-missing.md`. That message
said the drafted text was ready but held outside the repo. Since it is text and nothing else, it is
attached here rather than making you ask for it:

- `2026-09-21-2300-bimjom-task03-brainrot-descriptions-DRAFT.lua` — 126 descriptions keyed by name
- `2026-09-21-2300-bimjom-task03-descriptions-check.py` — the checker, with its planted faults

Both are inert. `BrainrotData.lua` is still untouched — the only commit on `task/codex-text` is the
claim move, which you have already merged as PR #4.

## Keyed by name, because name is the id

Saved collections store brainrots by name and `BrainrotData.Get(name)` is the lookup
(`BrainrotData.lua:7-11`, `306-313`). So each line drops straight onto the entry with that name
when the field exists.

## Counts

126 written, **0 kept** — there was nothing to keep, no description field or line existed. Lines run
62 to 76 characters, mean 72. Longest is 76 of 76 (`Mudlo Splosh`).

Every line is written only from the entry's own `look` and `move` fields. The twelve meme-named
entries get **no catchphrase and no borrowed lore** — the name was already in the data, the writing
around it is original.

## The limit is derived, not quoted — please sanity-check it

The brief asked us to find the real UI constraint and quote it. **There is none to quote**: no label
shows a description. So it is derived, and you should know exactly how before trusting it:

- The slot is the Codex subtitle at `MenuClient.client.lua:398`, on an 844x390 landscape phone, for
  an OWNED row — the narrowest case at **396 px**.
- The Robux button never appears in the live game, because every product id in `GamepassConfig` is
  `0`. That is what leaves the 396 px.
- At a pessimistic **5.2 px per character** that gives **76**.

The 5.2 comes from published font metrics for Montserrat and Gotham SSm, **not a measurement**. The
PR body carries the one-line Studio call that would replace the assumption with a real
`TextBounds`. If you queue that on the harness, the number either holds or the lines need a trim —
it will not silently be wrong.

## A 60 px row cannot hold the line

It has 10 px spare. The proposal is an **80 px row with a third truncating label**, guarded with
`def.description or ""` so it can land before or after the data — the exact before/after for
`codexRow` is in the PR body.

**Question 1, yours:** do you want the expanded row, or a detail card? That decides the length the
text is written to, so it comes before the writing rather than after. We have not decided it.

**Question 2, from the earlier message, still open:** is a `description` field intended on brainrot
entries, and is `description` the right field name? If the structural work in flight already adds
it, say so and we will re-cut the draft to that shape.

## Out of brief — reported, not fixed

- **The Codex name and subtitle labels get a negative width on a portrait phone and draw nothing.**
  A real bug, not a style issue.
- **The menu audit tool misreads that site**, because its regex ignores the `- rightReserve` term.
  So the tool would not have caught the above.
- The roster is **126**, not "a hundred-odd" as the brief says.

## Not proven

Nothing is wired and nothing renders. The character width is an assumption. The checker checks our
draft, not `BrainrotData.lua`, and proves nothing about the data file. Whether the lines are funny
is Oliver's to judge.
