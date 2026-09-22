# Guns tab — handoff (2026-09-22)

`HITREG_DESIGN.md` at the project root is the centrepiece. Read it before touching the combat path.

## Landed this session (three checks green on each)

- **`WeaponService.GiveAmmo` reports whether rounds actually arrived.** It returned true for any live
  loadout, so `VendorService:105`'s "Nothing to reload." was unreachable and a player with no gun, or
  with every reserve at the cap, paid 150 SahurCoins for nothing. Boolean, not a count — `0` is truthy
  in Lua and a count sails through `if not GiveAmmo(...)`. The arithmetic is split into a pure
  `WeaponService.AmmoGrant` so it can be tested without a Player; `tools/ammo_grant_probe.lua` runs six
  cases with the OLD arithmetic planted as a control, which fails two of them.
- **`CombatClient` `BRR_NextSlot` also answers `ButtonR1`.** A controller could not change weapons at
  all. L1 was refused: it is the vehicle handbrake (`VehicleClient:327`).
- **`GunModels:750` scope post is `18 - 2 * FINE` deep.** Arsenal-wide written flush pairs 416 → 392;
  TouchGrassScout 11 → 7. See the warning below about how this was nearly lost.
- **Floor pickups name their tier** (`LootService:247`) and **the swap toast names both halves**
  (`WeaponService.GiveWeapon`: "Swapped Sahur Pistol for Larila Sniper"). The gun swapped out is
  dropped where the new one lay, so naming it is what lets a player find it again.

## Refuted by measurement — do not "fix" it

**`LootService:88-96` is NOT a controller blocker.** `ProximityPrompt.GamepadKeyCode` defaults to
`ButtonX`; measured on a prompt built exactly as `makePrompt` builds one, with a cleared prompt as the
plant (`tools/prompt_input_probe.lua`). A pad can pick loot up.

What is real: **`ButtonX` is bound twice.** The prompt answers to it, and `CombatClient:984` binds
reload to it returning `ContextActionResult.Pass`, which does not sink the input — so **on a pad,
picking a gun up also reloads the gun you are holding**, wasting a magazine while exposed. Sinking the
input is REJECTED: it would invert this into the blocker the row wrongly claimed. Moving either control
is a preference and is on Oliver's board with the binding counts (ButtonY 3, ButtonB 5, ButtonA 4,
ButtonR2 6, ButtonL2 3, DPadLeft 3, DPadRight 3 — none is free).

## Open, with the numbers

- **#97 rewind.** Unlanded on purpose; `HITREG_DESIGN.md` has the design, the cap, the
  server-clock-only rule and the cover trade Oliver must choose. **Its builder must read the
  headshot-by-name trap first**: a rewind resolving to a victim rather than a PART deletes every
  headshot and reads as a clean refactor.
- **Four scope survivors per scoped gun**, faces recorded:
  `n(0,0,1) ScopeStanchion[17.7..34.7]/ScopeRing[17.7..34.7]` and the same at `[-65.6..-48.6]`, plus
  mirrors. A ring part's extent TRACKS the post's through a change to the post, which
  `shell(..., 18, ...)` does not explain. **Do not nudge a dimension.** The probe that settles it dumps
  every part in one scope with size, orientation and extents — and would also answer
  `Stock/BufferTube` and `MagWellCap/Magazine`, the families keeping every scoped gun off the clean list.
- **The floor label's legibility is UNANSWERED and the render did not answer it.**
  `tools/floor_label_gallery.lua` shot the longest tiered name ("Legendary Scontrino Infinito Brrrrr",
  35 chars) and the shortest at 40 and 60 studs. **The gun renders and the BillboardGui does not appear
  at all** — so the frames prove nothing about text size, and I am not claiming they do. **The
  interesting candidate is ruled out by source**: `DropWeapon` → `spawnGroundWeapon` → `label()` at
  `:250`, so floor guns DO get a label and this is not a missing-label bug. That leaves the harness
  limit — a BillboardGui appears not to draw in an edit-mode viewport capture, which belongs beside
  no-Player, no-LocalScript, no-synthetic-input and no-fresh-terrain. **Anything whose proof is a
  BillboardGui cannot be proven by a gallery here.** The risk is
  real: the billboard is `TextScaled` at `UDim2.fromScale(3.2, 0.64)`, so a longer string shrinks rather
  than clipping, and the tier could be legible while the name is not. **Pre-decided fallback: the rarity
  moves to its own line in a taller billboard. It is not dropped** — colour-only meaning excludes anyone
  who cannot tell two of seven shades apart. Oliver's playtest is the instrument here.
- **Ammo-grant row, deliberately split out**: picking a gun up also grants 25 % reserve and nothing says
  so. An honest message must read the count from `GiveAmmo`'s return rather than assume it, now that the
  refill can legitimately give nothing.
- **Gun-skin contract proposal** from the cosmetics tab (body/furniture/accent with materials, today's
  single colour as the default): still mine to accept or refuse, untouched.

## How the scope line was nearly lost, because the shape recurs

Landed, pulled, re-landed. The pull was the error, and its cause was an instrument that printed numbers
which LOOKED comparable and were not: two parts both reporting `0.065` were measuring different
directions, because a shell segment is rotated and its local Z is not the ring's axis. The number that
settled it — the flush-pair count, 7 with the fix and 11 without — was in the same output, unread.

Two guards came out of it and both are permanent:
1. `tools/audit_guns_zfight.lua` now prints, per pair, the face NORMAL and both parts' face positions
   **in millimetres**, the unit the kit is authored in. `ScopeRing[16.1..36.3]/ScopeStanchion[16.1..36.3]`
   ends an argument; `a=(0.085,0.098,0.065)` started three.
2. **A headline that cannot move is not evidence.** "19 clean of 62" counts whole guns, so a four-pair
   improvement in one family is invisible in it by construction — and that is what I read as "the fix
   did nothing".

## Also worth carrying

- **`runtest.ps1` does not rebuild the place.** It snapshots the existing `BrainRotRoyale.rbxlx`. A
  probe run without a rebuild measures the last person's tree, and a stale pass looks exactly like a
  real one. (Now warned about in the harness.)
- **Land the feature before the check, never the check first.** Two transient red `verify` runs today
  came from a check landing minutes ahead of the code satisfying it; in that window the gate is red for
  every other tab and points at code nobody has written.
- **A plant built differently from the subject proves nothing about the subject** — the hat sweep's
  planted slab blocked shots only because the probe built it itself, queryable; the cosmetics it was
  testing set `CanQuery = false` and the zeros were true.
