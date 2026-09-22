# Task 06 — the probes that cannot fail

An audit of this project's own test harness: every file under `tools/` that asserts anything, with
each check classified SOUND, CANNOT FAIL, STANDS IN WRONGLY or DEAD PLANT.

**Nothing in the game changed. Nothing in the harness changed.** This adds one tool
(`tools/probe_audit.py`) and this report.

---

## What was examined

| | files | checks |
| --- | --- | --- |
| Lua probes and galleries under `tools/` | 162 total, **109 assert something** | **943 check sites** + 36 that take no boolean to classify |
| Python checkers under `tools/` | **13** | **274 assertion sites**, and **228 regex sites executed and counted** over the real project |
| **Total read** | **122 asserting files** | **1,217 check sites** |

Counts are from `python tools/probe_audit.py .`, not estimated. The 36 unclassifiable sites are
calls to helpers with no boolean parameter (`checkWalks(folder)`, `checkTrunk(folder)`); they were
read by hand instead of by condition text, and they are counted separately rather than quietly
folded in.

Seven of the thirteen Python checkers were **executed** with an instrumented `re` module, so every
regex in them is reported with how many times it was tried, how often it matched, and how large the
input was. The other six write files into the tree (`menu_hud_audit.py` and `brainrot_asset_audit.py`
are generators; three are builders; one updates a baseline), so they were read rather than run.

**None of this needed Studio.** Every class in the brief is decidable by reading, and the three
findings below that are proved rather than argued were proved by planting a fault in a scratch copy
of the tree (`git archive HEAD | tar -x -C /tmp/...`) and running the real checker over it. The
repo was never written to.

---

## Findings, worst first

<!-- LUA GROUPS MERGE HERE -->

---

## The Python checkers

### 1. `tools/verify.py:436-439` — CANNOT FAIL, on the only route that matters

**Protects:** Beginner's Luck charges — free boosted crate opens, held in saved player data. The
comment above the check states the rule it enforces: *"Nothing may ever raise the charge count
outside the one-off grant."* A second grant is the paid Crate Luck pass given away for free, written
to the profile.

**Evidence:**

```
433  for _bl_rel, _bl_text in lua_files():
435      if _bl_rel.endswith(("PlayerData.lua", "ProgressionData.lua", "CrateData.lua")) or ...: continue
436      for _bl_write in re.findall(r"beginnerLuck[^\n]*", re.sub(r"--[^\n]*", "", _bl_text)):
438          if re.search(r"beginnerLuck\.left\s*(\+=|=[^=])", _bl_write) and "-= 1" not in _bl_write:
439              problems.append(f"{_bl_rel}: writes Beginner's Luck charges ...")
```

**Why it cannot fail:** line 436 only ever hands line 438 lines containing the literal text
`beginnerLuck`, so a write through a local alias is never examined. That is not a hypothetical
shape. It is how the legitimate grant itself writes the field, in a file this sweep **does** scan:

```
ServerScriptService/Modules/CrateService.lua
65      local beginner = progression.beginnerLuck
72      beginner.left = CrateData.BeginnerCrates
```

Line 65 reaches the guard and shows it the bare word `beginnerLuck` with nothing after it. Line 72
is the actual write and does not contain the string at all, so it is never looked at. **The check
passes on the one file in the project containing the write it exists to police**, and the shape it
is blind to is the shape any copy-paste of that grant would take.

Traced over the whole project, the site makes 3 attempts on strings of 12 to 23 bytes and matches
none of them, every run.

**Proved by planting, both routes, in a scratch copy:**

```
plant A, direct   data.Progression.beginnerLuck.left = 99
  -> RewardService.lua: writes Beginner's Luck charges (beginnerLuck.left = 99); only the
     one-off grant may, and opens may only spend one

plant B, aliased  local beginner = data.Progression.beginnerLuck
                  beginner.left = 99
  -> (nothing. verify.py stays green)
```

**To make it sound:** resolve the alias. Collect the names bound to the field, then look for writes
through those names in the same file:

```python
for _alias in re.findall(r"local (\w+)\s*=\s*[\w.]*\bbeginnerLuck\b", _bl_text):
    ... re.search(rf"\b{_alias}\.left\s*(\+=|=[^=])", _bl_text) ...
```

This will not catch every indirection and the comment should say so. It closes the one route the
real code demonstrates, which is the route a copy-paste would take.

### 2. `tools/balance.py` — the check works; its exit code cannot fail

**Protects:** Lua block balance across all 320 `.lua` files. This is one of the **three checks every
contributor is told to run before every commit and again before the pull request** (`HANDOFF.md` §2).

**Evidence:** the file contains no `sys.exit` anywhere. It ends:

```python
print(f'{delta:+3d}  {p.relative_to(sys.argv[1])}{flag}')
print('\nfiles unbalanced:', bad)
```

**Why it cannot fail:** proved by planting a Lua file with a missing `end` into a scratch copy.

```
files unbalanced: 1      exit code: 0
files unbalanced: 0      exit code: 0     (plant removed)
```

The detection is correct — it found the planted imbalance and named it. Only a human reading the
printed line can act on it. Anything gating on the exit code — a CI step, or an agent chaining the
three checks with `&&` — reads success on a broken tree.

**To make it sound:** `sys.exit(1 if bad else 0)`. `verify.py` ends `sys.exit(1 if problems else 0)`
and `keybind_check.py` returns `1 if findings else 0`. `balance.py` is the odd one out of the three
mandatory checks.

**Two more things in this file, neither a finding:** `opens` is computed, corrected for `elseif`,
then recomputed from scratch on line 47, discarding the correction. The recompute is the correct one
— Luau tokenises `elseif` as a single token, so no correction is needed — and the two comments
either side of it contradict each other. Separately, `balance.py` carries no planted fault of any
kind, so its exit path is not the only part of it that has never been shown able to fail.

### 3. `tools/keybind_check.py:20` — no parse-completeness guard

**Protects:** two actions defaulting to the same key. Its header explains that Studio cannot catch
this, because Settings is a client module and client scripts never run in the harness. This file is
the only thing between a collision and a player finding it.

**Evidence:**

```python
20  ROW = re.compile(r'\{\s*id\s*=\s*"([A-Za-z0-9_]+)"[^}]*?default\s*=\s*"([A-Za-z0-9]+)"[^}]*?\}')
```

**Why it could stop failing:** `[^}]*?` requires `id` before `default` and cannot cross a nested
brace. A row written `{ default = "K", id = "Vault", ... }` parses as nothing, and **nothing anywhere
compares rows parsed against rows present**. The printed count would drop from 22 to 21 and the run
would stay green.

It is **not** proving nothing today. Settings.lua has 38 `id` fields, 22 of them with a string
`default` — the other 16 are the toggles and sliders the code deliberately skips — and the tool
reports 22 bound keys across 22 actions. The parse is currently complete.

**To make it sound:** the guard this project already uses, two files away.
`tools/achievement_check.py:31` counts rows with a cheap independent pattern, and line 132 exits when
the two disagree:

```python
31   raw_count = len(re.findall(r'\{ id = "', block))
132  if len(entries) != raw_count:
133      sys.exit(f"achievement_check: parsed {len(entries)} entries but the file has {raw_count} ...")
```

### 4. `tools/progression_model.py:49,53,55,63,70` — empty parses accepted silently

**Protects:** the model of the rank and prestige curve — tiers, cosmetic slots, the brainrot
catalogue, the weapon count. Its output is numbers other work quotes.

**Evidence:** the file defines a fail-loud reader and uses it 19 times —

```python
25  def need(pattern, text, what, flags=0):
27      if not m:
28          sys.exit(f"progression_model: couldn't read {what}")
```

— then reads five of its inputs with bare `re.findall`, for which an empty result is a valid value:

```python
49  TIERS = [... for n, p, c, x in re.findall(r'name = "(\w+)", points = (\d+), ...', prog)]
53  SLOTS = re.findall(r'\{ id = "(\w+)", kind = "(\w+)", ... \}', prog)
55  CATALOGUE = {r: len(re.findall(rf'rarity = "{r}", coinValue', brainrots)) for r in RARITIES}
```

**Why it could stop failing:** a format change in `ProgressionData.lua` empties `TIERS` or `SLOTS`
and the model reports a curve over nothing. All five match today (traced: 1 attempt, 1 hit each).

**To make it sound:** route them through `need`, or assert the counts non-zero. The file already
knows how; it stops doing it five times.

### The pattern behind the one real find

`verify.py` carries six permanent planted-needle assertions — lines 647, 648, 671, 690, 958 and 1158
— guarding five detectors. **All five fire.** Proved by breaking each detector in a scratch copy and
rerunning the real checker:

```
break _gun_staging          -> staging: the check missed a planted loot weight on a staged gun; it isn't testing anything
break _kill_effects         -> kill effects: the check missed a planted typo ("confettti"); it isn't testing anything
break _duplicate_ids        -> weapon ids: the duplicate check missed a planted clash; it isn't testing anything
break _projectile_contract  -> explosives: the projectile-kind check missed a planted typo ("rockett"); it isn't testing anything
break _gm_description_drift -> game modes: the description-drift check did NOT catch a planted 50-vs-100 disagreement — it is testing nothing
```

All five are aimed at invariants ("an unregistered round kind must be caught"), not at past bugs, so
none can expire. The comment at `verify.py:1131-1135` is the best writing in this harness on why: an
earlier version of that needle was handed a raw string while the real input was stripped source, so
the needle went green while the check saw an empty description and passed forever.

**Every one of those five plants guards a parser** — a check that reads source, builds a model and
judges it. **Not one guards a negative detector**, the `if re.search(BAD_THING): problems.append(...)`
shape. Tracing found 12 regex sites in `verify.py` that match nothing across the whole project.
Eleven are negative detectors, silent because the project is genuinely clean, over inputs of 7 KB to
169 KB — which the tracer records, so an empty haystack cannot hide behind a zero:

| site | looks for | haystack |
| --- | --- | --- |
| 285, 287, 289 | building code pasted back into MapGenerator | 38 KB, 38 KB, 67 KB |
| 342 | CrateService rolling raw `crate.odds` | 11 KB |
| 422 | BattlePassService calling `Monetization.Clear` | 7 KB |
| 511 | a Vector3 guarded by type alone | 48,857 attempts |
| 553 | a local used before its definition | 1,057,917 attempts |
| 753, 754 | Cells sold, or ProgressionService touching coins | 12–22 KB |
| 851 | Neon, glass or transparency on a parachute | 62 KB |
| 1033 | road markings sunk into the asphalt | 169 KB |

None of the twelve carries a needle, so none has ever been shown able to fire. The twelfth is the
Beginner's Luck guard in finding 1 — the one negative detector I did plant into, and it was blind on
the route the real code uses.

**That is the shape worth carrying forward: in this harness the plants are on the parsers, and the
unproven half is the detectors.**

### Python checkers read and found sound

* **`tools/achievement_check.py`** — the model to copy. A permanent plant (an achievement asking for
  more brainrots than exist) fabricated fresh each run, aimed at the invariant and stated to be, and
  it gates the exit code at line 160 *before* the exit for real problems. Plus the
  parse-completeness guard at 31/132. 9 regex sites, all matching.
* **`tools/climb_design.py`** — a two-sided plant at 919-926: a synthetic limb in clear air must be
  reported, and a buried one must not. Both sides, invariant-aimed, every run. 23 assertion sites.
  It is the source of the pre-existing `verify.py` red — float rounding on a two-decimal boundary,
  diagnosed in the 2026-09-21 mailbox message — not a check fault.
* **`tools/lua_static_check.py`** — every pattern rule owns a `_bad` and a `_good` fixture under
  `tools/patterns/`; they run on every invocation, they gate the exit code, and the header explains
  both why they are aimed at invariants and why they are named `.lua.fixture` (so `balance.py`'s
  `**/*.lua` and `verify.py`'s walk do not eat them). It reports 3,170 candidate sites beside its
  105 findings — it states its denominator without being asked.
* **`tools/weapon_stats.py`** — `self_test()` at line 92 plants a two-entry table and asserts three
  separate things about the parse: both entries found, a field written *after* a nested table still
  read, and the first entry's body not running on into the second. Aimed at the parser's invariant,
  not at the regex that once got it wrong.
* **`tools/brainrot_asset_audit.py`** — `--selftest` proves the backdoor detector against a planted
  backdoor. Not traced here because it writes three files per input; read instead.
* **`tools/menu_hud_audit.py`, `build_cursor_test.py`, `build_range_test.py`,
  `update_gun_nudge_baseline.py`** — generators and builders, not checkers. One assertion site
  between the four. Listed so the file count is honest.

---

## What this audit did not prove

* **The harness was never run.** Every finding is from reading, and the three proved ones were
  proved against the Python checkers, which run without Studio. No Lua probe in this report was
  executed. Where a finding says a probe's sample would be empty, that is read from the filter and
  the source it filters, not observed.
* **`tools/probe_audit.py` decides three shapes, not four.** It cannot tell a stand-in body from a
  real one, and it cannot tell a live plant from an expired one. Both need the probe read beside the
  code it stands in for, which is what the written findings above are.
* **NEVER MATCHED is a site to read, not a verdict.** Eleven of the twelve it found are healthy. The
  tool reports the haystack size precisely so a reader can tell the two apart; it does not claim to.
* **No judgement about whether any of these probes tests the right thing.** This asks only whether
  each check can fail. A probe that soundly measures something nobody needs is out of scope here.
