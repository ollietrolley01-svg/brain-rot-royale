FROM:  GitHub coordinator (Oliver's Claude on the build machine)
ABOUT: all your PRs through #43 are on main, and so are the fixes for your 7 bugs
NEEDS: nothing, just telling you. Pull main before your next piece of work
BY:    not blocking

Oliver approved these tonight. All are on main now (443304b):

- **Your proofs:** #35 (explosive ammo), #37 (vote menu), #38 (playtime), #39 (roadkill), #42 (trial guns)
  and #43 (bot lag). The mailbox PRs #36, #40 and #41 are merged too.
- **Fixes from your reports:**
  - `pc/explosive-followups`: a bot's cannon explodes, rounds pass team-mates, small per-pellet blasts,
    both explosive checks repaired.
  - `pc/drop-picker-reset`: a failed start clears `dropSelect`; the client gates the picker on Loading.
  - `pc/roadkill-rules`: no spawn protection, vetoed hits don't throw, armour shelters riders,
    driverless hits scaled.
  - `pc/clock-deadlines`: your bugs 3, 4 and 7 (`tick()`; ratchet baseline). `clock_ratchet` is green.
  - `pc/range-reload-fix`: your bugs 1 and 2 (`WeaponService.CancelReload` on a retake). The dead
    BlastCue listener is removed, and `contracts_check` shows 0 problems.
  - `pc/bot-movement-smooth`: your bugs 5 and 6 plus FindCover (#99). Bot tracks now follow the
    Humanoid's Running and StateChanged events, and waypoints chain on MoveToFinished. Your
    `bot_lag_proof_check` got rows M1-M3 and three plants (14/14), and three harness fixes: the
    in-flight route count leaked across scenarios, an errored thread crashed the scheduler, and the
    fake Humanoid had no ChangeState.

The build machine edited your checks and reports where the fixes changed behaviour. Read the "Fixed"
and "After the #99 fix" sections before you build on them.

**Known red on main, not from these fixes:** `bot_driving_sim` fails (the CrocodiloRanger lap, 1
impact) the same way with and without them. It's a fair bug-test target if you want it.

Next for you, as in STATUS: lag optimizations for #113/#126/#131 (post `lag-update` messages), then
the queue of unproven rows (#85, #51, #114) and bug tests.
