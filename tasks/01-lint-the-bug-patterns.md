# Task 01 — teach the linter the bug patterns this project keeps hitting

**Files you own for this task:** `tools/lua_static_check.py` (add to it; do not restructure it),
plus a new `tools/patterns/` directory if you want one. Nothing else.

**Why this is the most valuable task on the list.** In one session this project found roughly a
dozen real bugs, and none were random — each belonged to a repeating pattern. They are written
up in `COORDINATION.md` under the 2026-09-21 sections, each with the real example that paid for
it. A pattern found by eye will be found again by eye, eventually, expensively. Encoded as a
check, it is found instantly and forever.

**Build a rule for each pattern below.** Some are exactly expressible; some can only be a
heuristic that flags candidates for review. **Say which is which** — a heuristic pretending to
be exact gets switched off by the first person it annoys.

1. **Ignored return value.** A function returning N values, called with fewer captured.
   *Real case:* `WeaponService.GiveWeapon` returns a third value naming the weapon it displaced;
   three callers ignored it and one silently deleted the player's held gun.
2. **A flag written and never read**, and the reverse. *Real case:* the admin Fly power set an
   attribute nothing in the project read, so the button did nothing at all. Sweep `SetAttribute`
   against `GetAttribute` / `GetAttributeChangedSignal`. **Beware names built by concatenation**
   (`"KP_" .. name`) — report those separately, not as findings.
3. **A state snapshot treated as an event.** A remote handler acting on a state value without
   comparing it with the previous one. *Real case:* the lobby broadcasts its state about once a
   second; a handler treated every repeat as a fresh transition and cancelled the player's
   sprint and aim every second.
4. **A weak-keyed table holding state rather than a cache** — and the sharper version,
   **a weak table whose VALUE was read off a property the same module later writes**
   (`.Color`, `.Size`, `.CFrame`, `.Transparency`, `.Position`). *Real case:* a lamp cache
   captured a part's original colour, the consumer overwrote that colour, and every rebuild
   re-primed from the already-dimmed value — headlights fading permanently towards black.
5. **`os.clock` used as wall time.** Exactly expressible. *Real case:* every rate-limit budget
   in the game was specified in wall-clock terms and counted in process CPU time.
6. **A handler slot filled with nil at construction** — a field read at build time from options
   that may not carry it, then used as a callback. *Real case:* the menu's X button, which
   hovered and depressed but was connected to nothing.
7. **A stale copy of a number defined elsewhere** — a digit in a description disagreeing with
   the constant beside it. *Real case:* a mode said "first to 50" while its target was 100.
   `tools/verify.py` has a narrow version of this; generalise it.
8. **A `warn`-and-return refusal in build code**, where the caller cannot tell "built" from
   "declined". *Real case:* a town yard refused to build and the feature simply appeared absent,
   with no reason anywhere a human would look.

**Proof.** For each rule: a fixture that must be flagged and a fixture that must **not** be —
the false-positive case matters more here than the true one. Report how many files and how many
candidate sites each rule examined, not only how many it flagged; a rule matching nothing
reports a clean codebase. Then run it over the real project and **triage before you send**: a
linter whose first run produces four hundred findings gets turned off.

**Do not fix anything it finds.** Report the list in the pull request.
