# Quality gate findings — claude/roblox-game-tasks-wv7n8k at 58db872 (2026-09-24)

Written by the quality-gate worker. Run `python3 tools/quality_gate.py` for the offline picture; this
file is what the gate cannot see. Severity-ranked. Each item names the owner (from the ownership list
of 09-24), the line, why it breaks in Roblox, and the fix. Items marked FIXED were in files nobody owns
and are landed in the same commit as this file.

## HIGH

### H1. Vehicle gun dies the moment a gunner's seat lands (cross-worker contract) — owner: bot driving (VehicleWeapons) + vehicle models
- Consumer side is already live: `StarterPlayerScripts/VehicleWeaponClient.client.lua:172-206`
  (`gunnerSeatOf`, `drivenVehicle`) and `StarterPlayerScripts/HudClient.client.lua:3030` treat a `Seat`
  named `GunnerSeat`, or any `Seat` with attribute `Gunner == true`, as THE gun position. When a
  vehicle has one, the driver's client returns nil (no binding, no reticle, no fire).
- Producer/authority side does not know it exists: `ServerScriptService/Modules/VehicleWeapons.lua:87-99`
  `DrivenBy` requires `seat:IsA("VehicleSeat")`. `VehicleWeaponFire`/`VehicleWeaponAim` (`:324`, `:373`)
  go through it, so a gunner's shots are refused. Nothing in VehicleModels builds such a seat yet
  (grep: 0 hits in ServerScriptService/ReplicatedStorage), so today it is latent.
- Result when VehicleModels adds the seat: nobody can fire the gun — the driver's client stands down,
  the gunner's server check fails. Silent; no error.
- Fix (VehicleWeapons.lua, `DrivenBy`):
  ```lua
  local seat = humanoid and humanoid.SeatPart
  if not seat or seat.Occupant ~= humanoid then return nil end
  local vehicle = seat.Parent
  local gunner = nil
  for _, child in ipairs(vehicle:GetChildren()) do
      if child:IsA("Seat") and (child.Name == "GunnerSeat" or child:GetAttribute("Gunner") == true) then
          gunner = child
          break
      end
  end
  if gunner then
      if seat ~= gunner then return nil end
  elseif not seat:IsA("VehicleSeat") then
      return nil
  end
  ```
  and BotService.lua:2490 (bots use `DrivenBy`) needs a bot to take the gunner seat, or bots in armed
  cars with a gunner seat stop firing. Note for VehicleModels: it must be a `Seat`, not a second
  `VehicleSeat` (a VehicleSeat is not `IsA("Seat")`, so the client would not find it).
  Land all three in ONE change (rule: a check/consumer arriving before its producer is the same red).

### H2. HudClient one local short of not compiling — FIXED (unowned)
- Luau refuses a function with more than 200 locals live at once ("Out of local registers"), and in
  Roblox that is the whole LocalScript dead: no HUD at all. verify.py counts TOP-LEVEL locals only
  (it read 194); the compiler counts what is live, and inside the do-block at
  `HudClient.client.lua:4512` that was **199**. One more top-level local anywhere above it and the
  HUD would have been gone in the next playtest with every offline check green.
- Fixed: the ambient-particles / match-state section (5 locals, all used only inside it) is wrapped
  in a do-block. Peak now 197, top level 189. New `tools/local_limit_check.py` (in the gate) measures
  the real per-function peak across every .lua file, with 4 planted faults. Busiest after the fix:
  HudClient 197, BotService 188 — both still tight; wrap new locals in `do` blocks.

### H3. Broken walls still end "faded to clear" — owner: cracking (DestructibleService / BreakFx)
- `ServerScriptService/Modules/DestructibleService.lua:598, 626, 632` destroy the broken part / pool
  members / model outright; the only thing left on screen is the client debris from
  `StarterPlayerScripts/BreakFxClient.client.lua:141-148` (`retire`), which tweens every piece to
  `Transparency = 1` and destroys it after `FADE_TIME`. So every break still ends with the wall gone
  and its rubble fading to nothing — exactly the playtest report. Nothing persistent (a cracked stub,
  settled rubble) is ever left.
- Fix direction: leave a server-side remains (a short cracked stub at the base of a wall, or 2-4
  anchored rubble parts per pool, CanCollide false, capped per map), and let `retire` only fade the
  small flying chips. Budget it: FX_PER_POOL already caps flying pieces; cap remains similarly.

## MEDIUM

### M1. explosive_ammo_check's pane plant now plants the wrong line (gate: 8/9 caught) — owner: guns
- `tools/explosive_ammo_check.py:386` removes the FIRST `"\t\t\t\tstopped = nil\n"` in CombatService.
  Since main's "teammate companion lets the shot through" (CombatService.lua:668) that is the
  companion branch, not the window pane (`:695`). The code is right; the plant no longer tests it.
- Fix: anchor on the pane branch, e.g.
  `swap(cs, "DestructiblePassesThrough(result.Instance) then\n\t\t\t\tlocal filter = params.FilterDescendantsInstances\n\t\t\t\ttable.insert(filter, result.Instance)\n\t\t\t\tparams.FilterDescendantsInstances = filter\n\t\t\t\tcurrentOrigin = result.Position + direction * 0.05\n\t\t\t\tstopped = nil\n", <same without the stopped line>)`.

### M2. Driveway slab and its car float on sloped lots — owner: roads (MapDecor)
- `ServerScriptService/Modules/MapDecor.lua` `MapDecor.Driveways` (~1447-1495) reads the ground once at
  the slab centre (`groundHeightAt(slab.X, slab.Z)`) and lays one flat 0.3-stud strip and a parked car
  at that height. The only test is `rectClear` (space claims). On a lot with any fall across a
  ~10x20 slab the downhill end hangs in the air and the uphill end is buried — the "floating props"
  class. The verge parking in MapGenerator got a `levelAt` test in the same commit; driveways did not.
- Fix: sample the four slab corners and the car footprint corners; skip the house (try the other side)
  if max-min > 0.5, the same threshold as `MapGenerator` `levelAt`; or flatten with FlattenPad and
  build at its returned height.

### M3. Harness drift: vehicle_place_check crashed on a62a419 — FIXED (unowned harness)
- `tools/vehicle_place_check.py` extracts VehicleService's parking block; the block now publishes
  `VehicleService.FootingAt` and wraps parkOn in `if not options.exact then ... end`, so the extract
  indexed a nil global and then lost the `end`. Harness updated (mock module table; regex keeps the
  `end`). Both planted faults still caught.

## LOW / notes

- Local vs merged main: branch had not merged main's #22/#23 at d9257c2; `git merge-tree` showed one
  conflict (GameMode.lua: `CombatService.RespawnDelay` vs `CombatService.OnShot` at start/stopWorld,
  keep both lines). a62a419 has since merged main — resolved.
- `ServerScriptService/Modules/MatchService.lua` uses `os.clock()` as an OpeningSpawn stamp. Only an
  identity token, compared for equality per player — harmless, but `workspace:GetServerTimeNow()` says
  what it means and does not trip the os.clock rule.
- Ranger "poles": the remaining diagonal rods on CrocodiloRanger are `RollBrace` L/R
  (`ReplicatedStorage/Shared/VehicleModels.lua` ~1257, 0.32 across, from the roll-bar shoulder out and
  back to the bed rail) and the snorkel pipe. If the playtest pole is at the bed, it is RollBrace;
  owner vehicle models — render `tools/vehicle_gallery.lua` rear-quarter to confirm.
- Enum sweep over every .lua: all Enum.X.Y names valid (incl. newer `BorderStrokePosition`,
  `PreferredInput`, `ScreenInsets`). No server code touches PlayerGui; no client code references
  ServerScriptService/ServerStorage. Every `while true do` loop yields or has a bounded exit.

## What the gate itself found
Run 2 (a62a419 + fixes, load ~25 on 4 cores, wall 55 min): 76 checks, 68 pass, planted faults 301/302.
- `explosive_ammo_check --plant` 8/9 (M1) — still 8/9 at 58db872.
- `vehicle_place_check` crash (M3, fixed).
- `killanim_check` "an old save loads differently from the working branch": compared against a moved
  branch ref; passes (0 failures) after rebasing onto 58db872. Not a defect.
- Timeouts only, under the load: car_placement_check (both, 1800 s; 6/6 map-seeds were clean before
  the cut), fps_arms_check (both), gun_tube_check, verify.py (passes standalone: "OK: no problems").
  On a busy machine use `--timeout-scale 2`, or `-k` to run a subset.
