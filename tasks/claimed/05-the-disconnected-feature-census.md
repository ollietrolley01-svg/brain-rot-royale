# Task 05 — find everything that was built and never switched on

**Files you own for this task:** none. You change nothing. The deliverable is a table.

## Why this is now the most valuable task on the list

In one evening this project found, by accident, five separate pieces of finished work that no
production code ever calls:

* `TownThemes.lua` (4,856 lines), `TownKinds.lua` (484) and `MapWilds.lua` (2,553) — roughly 7,900
  lines of towns and foliage with **no requirer outside `tools/`**. The owner has asked for more
  foliage three times, and every answer went into a module nothing runs.
* `VehicleService.ParkInTowns` — no production caller at all. It returns zero before its loop on
  every map and every seed, so a warning it was criticised for can never fire.
* `BrainrotModelsRemake.lua` (567 lines) — a complete replacement art set, deliberately unwired,
  waiting on an approval that was given tonight.
* `CombatService.fireAbility`'s explosive branch — every weapon that could reach it takes an
  earlier return. The first hitscan explosive anyone adds silently gets a cruder blast, with
  different falloff and no wall damage, and nothing would flag the divergence.
* A reserved touch-control slot for spectating that nothing ever binds, and a defined sound cue
  with no play site.

**Every one of these was found by somebody looking for something else.** Nobody has ever swept for
them. That is the job.

## The job

Sweep the whole project for finished work that cannot run, and produce one routable table. Four
shapes, and they are not the same:

1. **A module with no production requirer.** Required only from `tools/`, or not at all.
2. **An exported function with no production caller.** The module is wired, the function is not.
3. **A branch that cannot be reached**, because every input that would select it takes an earlier
   return, or because its condition cannot be true given the data.
4. **A declared thing with no consumer** — a sound cue with no play site, a control slot nothing
   binds, a config field nothing reads, a data field written and never used.

For each finding give the file and line, which of the four shapes it is, how many lines it is,
**what it was apparently for**, and — the part that makes this routable — **whether it looks
abandoned or merely unfinished**. Those get opposite treatment: abandoned work should be deleted,
unfinished work should be finished, and telling them apart is a judgement you must make explicitly
rather than leave to the reader.

## The trap, and it is the whole difficulty

**A thing reached only by a name built at run time looks dead and is not.** `"KP_" .. name`,
`workspace:FindFirstChild(someVariable)`, a remote named from a table, a function looked up by a
string key. Our own linter reports these separately for exactly this reason. **Report them as a
separate list you could not settle, never as findings.** A census that gets something live deleted
is worth less than no census at all.

The same goes for anything wired by hand in `Bootstrap`, and anything a place file might reference
that the Lua never names.

## Proof without Studio

Report **how many modules, exported functions and branches you examined** beside how many you
flagged. A count of findings alone says nothing about coverage. Include a fixture that must be
flagged and one that must not — the false positive matters more here than the true one, because
this table becomes a delete list.

State plainly which findings you are confident in and which are candidates. Twenty certain ones
and a list of maybes beats sixty you are not sure about.
