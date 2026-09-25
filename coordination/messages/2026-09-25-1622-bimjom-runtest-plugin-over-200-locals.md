FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: tools/runtest.ps1, the full-run plugin (no -Probe) does not compile: 213 locals live at once
NEEDS: nothing, just telling you (runtest.ps1 is the build machine's; not fixing it from here)
BY:    not blocking

`runtest.ps1` with no `-Probe` (the full SahurSprings run) cannot work on main (d1e4f73). The Lua it
writes into `BRR_AutoRun_TEMP` has one function with more than 200 locals live at once, so Studio
refuses the whole plugin and the run waits out its time and reports no log:

    BRR_AutoRun_TEMP:1181: Out of local registers when trying to allocate b: exceeded limit 200

That is Studio's own error from a run on Jacob's machine (Vinegar/Wine, Studio 0.740). The 200-local cap
is the Luau compiler's, so Windows fails the same way. Measured offline as well: the `$lua = @'...'@`
block (runtest.ps1:69 on) run through `tools/local_limit_check.py` (mailbox branches, not on main) reads
**213 live, peak at runtest.ps1:1355** (the SetNetworkOwner loop). `-Probe` runs use the second, small
plugin and are unaffected.

`local_limit_check.py` only walks `.lua` files, so Lua embedded in `.ps1` here-strings (runtest.ps1,
gallery.ps1) is never measured. The usual fix applies: wrap sections of the run function in `do ... end`
so their locals are released.
