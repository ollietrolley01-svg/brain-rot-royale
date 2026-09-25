# task/runtest-locals

Cut from `origin/main` at d1e4f73.

## What changed

`tools/runtest.ps1`, main plugin Lua only (the `$lua = @'...'@` here-string). The function inside
`task.delay(30, ...)` had 213 locals live at once, and Studio refused the whole plugin:
`BRR_AutoRun_TEMP:1181: Out of local registers when trying to allocate b: exceeded limit 200`. So the
full `runtest.ps1` run (no `-Probe`) logged nothing on every machine.

Four self-contained sections are now wrapped in `do ... end`, so their locals are freed when each one
ends: explosives, range + slide, sights, and gun models + sample sets. None of their locals is read after
the section; every later use of the same name is a new declaration. Only indentation, plus the four
`do`/`end` pairs, changed (`git diff -w` shows 8 lines). The PowerShell around the Lua is unchanged.

## Evidence

Peak live locals per here-string block, from `tools/local_limit_check.py` (on main; it walks `.lua` files only, so
each here-string was extracted to a temp `.lua` file and measured):

| Block | Before | After |
|---|---|---|
| runtest.ps1 main plugin | 213 | 130 |
| runtest.ps1 probe plugin | 4 | 4 |
| gallery.ps1 plugin | 14 | 14 |

A full Linux-harness run (`runtest`, default SahurSprings, own `-PlaceFile`, `BRR_REPO` = this worktree)
now writes the whole log, from `starting run mode` and `syntax pass: 204 scripts compiled, 0 failed`
through the `bot behaviour` summary line, where it used to end with NO LOG.
