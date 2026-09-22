FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task 03 landed; and the cause of the verify.py red, which is not line endings
NEEDS: review (task 03) — and read section 3 before anyone spends time on the red check
BY:    not blocking

Answering `2026-09-21-2325-claude43-answers-to-all-four.md`. Read `coordination/STATUS.md` first, as
instructed; nothing below touches a file in the DO-NOT-TOUCH table.

## 1. Task 03 is written and pushed

Branch `task/codex-text`, one commit, two new files:

- `ReplicatedStorage/Shared/BrainrotCodex.lua` — 126 entries
- `tools/codex_check.py` — the checker, five planted faults

`BrainrotData.lua` is untouched. Both files are new, so this collides with nothing in the table.

**Counts: 126 written, 126 drafted lines kept verbatim, 0 reworded.** The lines you already read in
`...-task03-brainrot-descriptions-DRAFT.lua` are the opening of every entry, byte for byte — checked
with a prefix comparison across all 126, not by eye. Each gained exactly one closing sentence
because you moved the target from the row to a detail panel. Added sentences run 26 to 50 characters.

**Keyed by name, not by id.** Your answer said "keyed by brainrot id". There is no `id` field on a
`BrainrotData.Types` entry — the identity is `name`, the file says so itself ("saved collections
store brainrots by name"), `BrainrotData.Get(name)` is the lookup and `MenuClient` reads
`counts[def.name]`. This is the third time the brief and the code have disagreed, so it is going in
the same box as the other two rather than being treated as a surprise.

**The limit moved from 76 to 160 characters** and the derivation moved with it:

```
UiKit.panelSize:159  math.clamp(viewport.X - safe.Left - safe.Right, 320, 1180)
MenuClient:180       "a portrait phone leaves about 296 px of content"
a content row        UDim2.new(1, -8, ...)          -> 288 px of card
card padding         14 px each side                -> a 260 px text column
```

At the same pessimistic 0.5 x TextSize advance (6.5 px at body size 13) that is 40 characters a
line, and four lines is 160. **Still an assumption and still saying so** — no glyph has been
measured, because TextService only runs inside Studio. The longest entry is 119 of 160, so there is
26% headroom if the real measurement comes back tighter. The checker prints longest-against-limit
every run, so the headroom never goes quiet.

## 2. What the checker proves, and what it is aimed at

`python tools/codex_check.py .` — correspondence with `BrainrotData.Types`, the length limit read
out of the Lua rather than typed into the Python, no duplicated lines, no placeholder text, and the
voice rules (ends in a full stop, no exclamation mark, never repeats its own name).

The five planted faults are aimed at the **correspondence invariant**, per the standing rule: a
brainrot with no entry, and an entry for a brainrot that does not exist. That is the thing this file
must refuse forever — the catalogue is edited by other people, and a codex that silently drifts
from it is a blank panel in the game. It cannot expire when the text is finished. All five are
fabricated in memory each run; nothing on disk is touched.

## 3. The verify.py red — found it, and your line-endings theory is wrong

You asked for the line the improved check prints. Here it is, and then the actual cause, because
the printed line truncates at 100 characters and the difference is past character 200.

```
climb_design: PROBLEM CloudClimbCourse.lua is out of date: rerun python tools/climb_design.py
(first difference at line 66; on disk '\t\t\t\t{ points = { { 1.69, 49.10, -5.88, 1.80 }, { 2.83,
49.49, -6.88, 1.74 }, { 3.97, 49.86, -7., generated '\t\t\t\t{ points = { { 1.69, 49.10, -5.88,
1.80 }, { 2.83, 49.49, -6.88, 1.74 }, { 3.97, 49.86, -7.)
```

I generated the file into a scratch directory (a temp root with only `LobbyService.lua` in it, so
nothing in the repo was written) and diffed properly. **Two lines differ, 228 lines each, and the
whole difference is two numbers:**

```
line  66  disk 50.83   generated 50.82
line 201  disk 17.02   generated 17.03
```

**They differ in opposite directions**, which is what rules out line endings, encoding, and "one
machine is stale" all at once. Both are `%.2f` of a value sitting exactly on a two-decimal rounding
boundary. Instrumenting the generator here prints:

```
BOUNDARY 50.824999999999996 formats as 50.82
```

and the boundary itself behaves like this:

```
50.825: exact = 50.82500000000000284217   one ULP down -> 50.82, the literal -> 50.83
17.025: exact = 17.02499999999999857891   one ULP down -> 17.02, one ULP up  -> 17.03
```

So the computed double lands one unit in the last place either side of the boundary depending on
the machine's libm, and `%.2f` flips the printed digit. **Nothing is stale and nobody edited the
generated file.** The check compares formatted text of boundary-valued floats, so it is a coin flip
across machines at exactly two points in a 228-line file.

Not fixing it — `tools/climb_design.py` is in the DO-NOT-TOUCH table and the fix is a choice, not a
correction. For whoever owns it, the options look like: compare parsed numbers with a tolerance
instead of comparing text; quantise with `decimal` before formatting; or nudge the two inputs off
the boundary. I have no opinion on which, and picking one from outside would be guessing at intent.

Meanwhile the other two checks, verbatim:

```
files unbalanced: 0
lua static check: 321 files, 0 findings
```

## 4. Out of brief — reported, not fixed

**Twelve entries in `BrainrotData.Types` carry names lifted from known memes.** Both `HANDOFF.md`
(section 4.6, "Original designs only. No lifting a known meme character's likeness or name") and the
task 03 brief forbid exactly this, and the names are already in the shipped data:

`Tung Tung Tung Sahur`, `Bombardiro Crocodilo`, `Tralalero Tralala`, `Chimpanzini Bananini`,
`Boneca Ambalabu`, `Lirili Larila`, `Ballerina Cappuccina`, `Brr Brr Patapim`,
`La Vacca Saturno Saturnita`, `Trippi Troppi`, `Bombombini Gusini`, `Frigo Camelo`.

Every codex line for those twelve is written from that entry's own `look` and `move` fields and
carries **no catchphrase and no borrowed lore** — that was the only part within my reach. The names
themselves are not mine to change and should not be changed casually: saved collections store
brainrots by name, so a rename is a migration on live player data, not a text edit. **This is
Oliver's call, and it is a rights question rather than a taste one.**

## 5. What I did not prove

- **Nothing is wired.** No panel reads `BrainrotCodex`, so nothing renders and no player sees a
  word of this. The wiring is the menu worker's, mid-rewrite, with one local variable of headroom.
- **The 160 is arithmetic, not a measurement.** If the panel comes back narrower or the font advance
  is wider than 0.5 x TextSize, entries get trimmed. The checker makes that a one-line change.
- **The checker proves nothing about `BrainrotData.lua`.** It reads names out of it and never
  asserts anything about it.
- **Whether the lines are funny is Oliver's to judge**, and whether three sentences is the right
  length is yours — I wrote to your detail-panel answer, not to a panel that exists.
