# Critic findings (bug and model checker), 2026-09-24

Reviewer: the critic worker. Scope: every commit on `origin/main..claude/roblox-game-tasks-wv7n8k`,
read against how real Roblox runs it, plus the models built from parts. Each finding: severity
(blocker / major / minor / polish), file:line (as of the branch tip named in the batch), why, and the
exact fix. **FIXED** means fixed in the critic's branch with a test; **ROUTE** means the file belongs to a
running worker and the fix is written out here for them.

Line numbers are at branch tip `7e61c81` unless a finding says otherwise.

---

## Batch 1

### C1 (major, FIXED) Vehicle gun cursor: a second writer of MouseIconEnabled brought back #112
- `StarterPlayerScripts/VehicleWeaponClient.client.lua:372-379` (d9257c2, "aim at the mouse") wrote
  `UserInputService.MouseIconEnabled` directly. `StarterPlayerScripts/MenuCursor.client.lua` is the sole
  owner of that property (its header, #112) and re-derives it on every MouseBehavior change.
- Real-Roblox effect: (a) a right-drag of the camera while driving flips MouseBehavior to
  LockCurrentPosition and back, MenuCursor reconciles the icon to `true`, and VehicleWeaponClient (which
  caches `hidCursor`) never hides it again: OS arrow on top of the aim mark. (b) Leaving the seat into
  first-person combat, VehicleWeaponClient's "give it back" writes `true` after MenuCursor has hidden it
  for LockCenter: the arrow sits over the FPS crosshair until the next MouseBehavior change, which is
  exactly Oliver's #112 "can still see my cursor in FPS".
- Fix (landed in the critic branch): VehicleWeaponClient sets a local `AimCursor` attribute on the player
  instead; MenuCursor's `desiredIcon` hides the arrow while it is set with a free mouse and listens for it.
- Test: `tools/cursor_owner_check.py` (static: only MenuCursor writes the property, 113 files scanned;
  MenuCursor itself driven through 10 steps in a signal-accurate mock; VehicleWeaponClient in the HUD
  mock world, 4 cases). 4/4 planted faults caught. `tools/vehicle_aim_check.py` still 0 problems.
- Untested: the real OS arrow; one Studio look while driving an armed car with a mouse, right-dragging,
  then leaving the seat into first person.

### C2 (major, ROUTE: ModeTeams owner) Base-vehicle bays read the compound's own walls as "occupied"
- `ServerScriptService/Modules/ModeTeams.lua:580-591` `bayOccupied` uses `workspace:GetPartBoundsInBox`,
  which tests each part's **world axis-aligned bounding box**, not its real shape. The compound is built
  at an arbitrary yaw (it faces the arena centre, `ruinFrame`), so every rotated wall, tyre, drum, barrier
  and gate leaf near a bay has an AABB far bigger than itself.
- Measured (the real TeamBaseRuins.Layout through `tools/team_base_ruins_check.py`'s Build, 10 yaws x 6
  bays = 60 cases; repro `tools/critic_bay_aabb_repro.py`): **29 of 60 bay-yaw cases are "occupied" by
  the compound's own parts**, none of them by real geometry (every hit is "aabb only"): at 30/45/60/120/
  135/160 degrees Bays 1, 2, 3 and 6 are taken (Tyre, Barrier, Drum, GateLeaf, Wall); only 0 and 90 are
  clean. Because `BaseVehicleSpot` returns nil (wait) whenever `BaseVehicleBays == RuinBays`, those slots
  never park: most matches get 2 of the 6 base vehicles Oliver asked for, retried every 5 s forever.
- Why the checks missed it: `team_base_ruins_modeteams_check.py` stubs TeamBaseRuins (no real parts) and
  its GetPartBoundsInBox mock tests exact boxes; `team_base_ruins_check.py` tests the bay with an exact
  OBB (`hits_obb`). Neither models the AABB semantics.
- Fix (ModeTeams): keep the broad-phase query but confirm each hit against its real box before calling
  the bay taken. Replace `bayOccupied` with:
  ```lua
  -- Exact test for one part against the bay box: GetPartBoundsInBox matches a part by its world-aligned
  -- bounding box, which for a wall turned to the compound's yaw covers half a bay it never touches.
  local function boxesOverlap(a, aSize, b, bSize)
  	local axes = { a.RightVector, a.UpVector, a.LookVector, b.RightVector, b.UpVector, b.LookVector }
  	for i = 1, 3 do
  		for j = 4, 6 do
  			local cross = axes[i]:Cross(axes[j])
  			if cross.Magnitude > 1e-4 then
  				table.insert(axes, cross.Unit)
  			end
  		end
  	end
  	local ha, hb = aSize / 2, bSize / 2
  	local offset = b.Position - a.Position
  	for _, axis in ipairs(axes) do
  		local ra = math.abs(a.RightVector:Dot(axis)) * ha.X + math.abs(a.UpVector:Dot(axis)) * ha.Y + math.abs(a.LookVector:Dot(axis)) * ha.Z
  		local rb = math.abs(b.RightVector:Dot(axis)) * hb.X + math.abs(b.UpVector:Dot(axis)) * hb.Y + math.abs(b.LookVector:Dot(axis)) * hb.Z
  		if math.abs(offset:Dot(axis)) > ra + rb then
  			return false
  		end
  	end
  	return true
  end

  local function bayOccupied(bay)
  	bayParams.FilterDescendantsInstances = { workspace.Terrain }
  	local look = bay.LookVector
  	local frame = CFrame.new(bay.Position + Vector3.new(0, 0.6 + BAY_CLEAR.Y / 2, 0)) * CFrame.Angles(0, math.atan2(-look.X, -look.Z), 0)
  	for _, part in ipairs(workspace:GetPartBoundsInBox(frame, BAY_CLEAR, bayParams)) do
  		-- A ball or cylinder is tested as its box: a little generous, never short.
  		if part.CanCollide and boxesOverlap(frame, BAY_CLEAR, part.CFrame, part.Size) then
  			return true
  		end
  	end
  	return false
  end
  ```
  (`footprintClear` at :614 has the same AABB over-reach for the open-ground spots, less harmful because it
  only rejects candidates; the same `boxesOverlap` filter fixes it.) Add to the modeteams check a mock
  GetPartBoundsInBox that returns parts by world AABB and a real compound at a 30-degree yaw.

### C3 (major, ROUTE: bot looting worker) Under-armed bots destroy every floor gun they reach, wanted or not
- `ServerScriptService/Modules/BotService.lua:1964-1978` `findLoot` sends an under-armed bot
  (`isUnderArmed`, :2431: any bot with a Common or Uncommon gun and no loadout weapon, i.e. about 82% of
  bots by WEAPON_ODDS) to the nearest GroundWeapon of ANY rarity; `holdLoot` (:2077) calls
  `LootService.ClaimForBot`, which **destroys the pickup** (`LootService.lua:1051`); then (:2112) the bot
  keeps it only if it is a rarity upgrade. A Common gun on the floor near an Uncommon-carrying bot is
  simply deleted.
- This is the most likely cause of Oliver's "no one's dropping loot in battle royale": a kill in a lobby of
  bots drops the victim's gun, and the nearest under-armed bot walks over and deletes it within about a
  second of the 0.3 s claim. 5e2ac79 made the drop itself robust but the drop is then eaten.
- Fix (BotService, in `findLoot`'s loop): only send a bot to a gun it would keep, as `FindBaseLoot` already
  does for team bases:
  ```lua
  if item.Name == "GroundWeapon" then
  	local id = item:GetAttribute("WeaponId")
  	local def = id and WeaponData.Get(id)
  	local myRank = bot.weapon and (Rarity.Index[bot.weapon.rarity] or 0) or -1
  	if not (def and (Rarity.Index[def.rarity] or 0) > myRank and not def.staged and not BOT_WEAPON_HOLD[def.id]
  		and (not def.projectile or BOT_PROJECTILE_KINDS[def.projectile])) then
  		continue
  	end
  end
  ```
  and, belt and braces, in `holdLoot`: read `local itemPosition = item.Position` before the claim (the
  claim destroys the item), and when a claimed GroundWeapon turns out not to be `usable` or not an
  upgrade, put it back with `LootService.DropWeapon(def.id, itemPosition)` instead of losing it.
  Test: a bot probe that kills a bot next to an under-armed bot and counts GroundWeapons at 1/10/30 s
  (tools/death_drop_probe.lua already has the counting).

### C4 (minor, ROUTE: VehicleService owner) ParkInTowns moves a car back into its bay at the step-aside's height
- `ServerScriptService/Modules/VehicleService.lua:1134-1137`: ParkInTowns checks the bay's own footing
  (bay w x d), then `Create` runs `parkOn` with the MODEL's extents (up to 17.4 long, more than a 16.6 bay),
  which can fail on a kerb and step the car up to FOOTING_REACH away and up to 4 studs up or down;
  `centreModel` then slides it back over the bay horizontally but keeps the step-aside's height. Result: a
  car hovering over, or sunk into, its bay by up to 4 studs (and parkOn's hardstanding left at the other
  spot).
- Fix: the bay's footing has just been verified, so park it exactly:
  `VehicleService.Create(parent, bay.cf.Position, yaw, kind, { rng = roll, exact = true })`.

### C5 (major, ROUTE: guns worker, CombatClient/Viewmodel) The "fps models missing" root cause is not proven, and nothing stops the next one
- ac4b982 says the viewmodel vanished because `Arms.LookOf` read `MeshPart.MeshId` and "a read the client
  is refused throws". Roblox's own API dump (tools/roblox_api_subset.json, from Full-API-Dump.json) gives `MeshPart.MeshId`
  Security Read **None**, Write NotAccessibleSecurity: any script may read it (only writing is barred). So the stated cause is very likely
  wrong, and if Oliver's next playtest still has no first-person gun the real fault is elsewhere in
  `Viewmodel.new` / `Arms.new` (61a001f's new arm copy is the only new code on that path).
- Whatever it is, one throw anywhere in `Viewmodel.new` still costs the whole gun: `CombatClient
  buildViewmodel` (`CombatClient.client.lua:1509-1525`) calls it unguarded inside the BRR_Viewmodel render
  step, so it throws every frame.
- Fix (CombatClient, buildViewmodel): build with the avatar's arms, and if that throws, warn ONCE with the
  error (so the Output names the real cause) and build with stand-in arms:
  ```lua
  local ok, vm = pcall(Viewmodel.new, def, { color = color, material = material, skinned = skinned,
  	character = source.Parent, onEvent = onViewmodelEvent })
  if not ok then
  	if not warnedViewmodel then
  		warnedViewmodel = true
  		warn("[CombatClient] viewmodel with your avatar's arms failed, using stand-in arms: " .. tostring(vm))
  	end
  	vm = Viewmodel.new(def, { color = color, material = material, skinned = skinned, onEvent = onViewmodelEvent })
  end
  ```
  (declare `local warnedViewmodel = false` above). The same for `buildItemView`'s `Viewmodel.Arms.new`.
  Ask Oliver for the Output line if the gun is still missing.

### C6 (process, for the coordinator) main is ahead of the working branch
- `origin/main` has 3 commits not on `claude/roblox-game-tasks-wv7n8k`: 3b593e6 "Bots take armed vehicles
  and fire them; parked cars stop bobbing", d4e1503 (third review pass: BotService, CombatService,
  GameMode, MatchService, StateSync...), 258530f (KOTH objectives fair). `git diff origin/main..branch`
  therefore shows them as REMOVED (e.g. BOT_DRIVERS_MAX 5 -> 3, the vehicle filter in hasLineOfSight gone).
  The bot-driving worker is re-doing "bots take armed vehicles" on the branch: merge main into the branch
  before that lands, or the two versions collide in BotService/VehicleService.
- LootService.lua on the branch is LF, on main CRLF: every line shows as changed in a plain diff (use
  `--ignore-cr-at-eol` to review it). Harmless, but it will make the main merge noisy.

---

## Batch 2 (tools)

- `tools/roblox_api_check.py` + `tools/roblox_api_subset.json`: the source against Roblox's real API dump
  (Enum items, Instance.new / GetService classes, members of Instance.new locals and UiKit create()
  tables, restricted-security access). 0 findings on the tree; 6/6 planted faults caught. Settles C5's
  premise: `MeshPart.MeshId` is Read=None.

## Batch 3 (at branch tip 22baf77 + the critic's commits)

### Verified: the coordinator's fixes for C2, C4, C5 (0e339d8)
- C2 `ModeTeams.bayOccupied`: exact SAT per hit, as proposed. `tools/critic_bay_aabb_repro.py --exact`
  0 of 60. Still open, minor: `footprintClear` (ModeTeams.lua, open-ground spots) has the same AABB
  over-reach; it only rejects candidate spots, so fewer spots are found, never a wrong one.
- C4 ParkInTowns `exact = true`: right.
- C5 CombatClient: guarded, falls back to stand-in arms and warns once. Still unguarded, minor:
  `buildItemView` (`CombatClient.client.lua` ~1759) calls `Viewmodel.Arms.new(model, character)` bare;
  the same pcall + stand-in fallback (`Viewmodel.Arms.new(model, nil)`) there.

### C8 (major, FIXED) Defense placement refused half of a turned team base
- `ReplicatedStorage/Shared/DefensePlacement.lua:630-639` (680118e) refuses a build inside
  `VehicleYard:GetBoundingBox()` + 12. The yard Model had no PrimaryPart, so Roblox returns that box on
  the WORLD axes; the compound faces the arena centre at any yaw. Measured on the real layout: at 20-60
  degrees the refused square grew from 43% of the base to 54-59% and covered 13-15 of the 37 pads, chest
  and loot spots (5 when square).
- Fix (landed, TeamBaseRuins.buildYard): the yard's PrimaryPart is a bay line, square to the compound.
  Test `tools/critic_yard_nobuild_repro.py --plant` (6 yaws; plant = no PrimaryPart, caught).
- For the defense worker (robustness, not required now): read the yard's box through its PrimaryPart
  explicitly, or tag the yard NoBuild with a part-per-lane, so no model's pivot decides it.
- Design question for Oliver: even square, the yard + lane margin is 43% of the base where no defense can
  go up (the courtyard in front of the yard included). If he wants defenders to fortify the base, shrink
  the refusal to the bays and their drive-out lanes (TeamBaseRuins knows both).

### C9 (minor, ROUTE: foundations/MapDecor owner) A shed on a slope can have its doorway in the hill
- `ServerScriptService/Modules/MapDecor.lua` `shed` (~1739-1773): the door's top is at the placement
  point's ground + 7 whatever the slope (base drops by SINK + drop, doorTop rises by the same), and the
  yaw is random. The door is 6 studs from the centre, so a door facing uphill on a slope of ~18 degrees or
  more (ground at the door > centre + 1.8) leaves less than an R15's 5.2 studs of opening, and on the
  steeper sites 22baf77 now keeps (drop up to 17) the doorway is under the terrain: the shed's loot spot
  (inside, on the ground) cannot be reached. Pre-existing; the foundation check does not measure hut doors
  (`foundation_measure.lua:387-440` marks sheds noBury and gives them no `door`).
- Fix: pick the yaw a quarter turn at a time so the door faces the lowest of the four wall midpoints (the
  same sampling as `drop`), and put the doorway's top at `groundAt(door) + 7` (lintel above it); or skip
  the site when the ground spread under the walls exceeds ~4 studs (the MapWilds shelters' rule, ddd4ba1).
  Then give decor:hut a `door = { half = 2.5 }` in foundation_measure so the sill/door rules cover it.

### C10 (polish, ROUTE: defense worker) A thrown structure kit is animated by the server every Heartbeat
- `ServerScriptService/Modules/DefenseService.lua` `throwStructure` (680118e) PivotTo's an anchored model
  from the server each Heartbeat. Anchored CFrame changes replicate unsmoothed at the network rate, so
  every other client sees the kit step along its arc (the old physics throw was interpolated).
- Fix: fire the arc (from, velocity, flightTime, spin) to clients and let each draw the kit locally
  (the defense preview already walks the same `DefensePlacement.ArcPoint`); the server keeps only the
  `task.delay(landTime, ...)` build. Or keep a server kit but TweenService it (still stepped, but one
  property stream).

### C11 (minor, ROUTE: companion FX) One faulty scheduled beat drops the whole frame's effects
- `StarterPlayerScripts/CompanionFxClient.client.lua` `step` (~1823-1829): `job.fn(t)` from `pending` is
  not pcalled (each effect's `update` is). A throw there stops that frame's walk of every live effect,
  `pruneParticles` and `stepVignette`. Fix: `local ok, err = pcall(job.fn, t) if not ok then
  warn("[CompanionFx] " .. tostring(err)) end`.

### C12 (minor, ROUTE: loot) The 1 s settle assumes the key is let go within a second
- `ServerScriptService/Modules/LootService.lua:211-226` (3441c0f). If the mechanism is right (prompts
  appearing under a held key), a player who keeps E held past 1 s after the 1.2 s crate hold gets the
  same result the fix is for. Unproven either way offline, and the server cannot see a key being let
  go. Ask Oliver whether the build with 3441c0f fixed it; if a held key still takes the spill, raise
  DROP_SETTLE to 2 s (the prompt reappearing a second later costs nothing) rather than build more on an
  unconfirmed mechanism.

### C13 (process) BotService local count with both bot branches
- On the tree: BotService peaks at 191 live locals (tools/local_limit_check.py), 9 under Luau's limit;
  the bot-driving branch (a75ab68) adds to the same file. Run local_limit_check after that merge.

### Visual notes (polish, for the ruins / Oliver's render pass)
- Team base ruin (offline sketch, top and quarter views): the spawn bunker's roof is one flat 40 x 34
  slab with a vent and a hatch, the largest plain surface in the compound and the first thing a spawning
  player sees from the watchtower or when dropping in. Suggest: roof rubble heaps and a sagging broken
  corner, a sandbag ring round the hatch, a toppled aerial, two or three puddle/soot decals, and a
  lip/parapet edge so its silhouette is not a box.
- Reworked guns (gunfun_lab renders of Sahur Pistol, Crocodilo Rifle, Tralala Shotgun, Lag Switch SMG,
  Sigma Scout, Aura Scattergun): read as distinct designs; the Crocodilo head reads well from the side.
  The Sahur Pistol's domed muzzle cap fills the lower third of the ADS picture (below the sight line, so
  the sight check passes); worth a Studio look at ADS.

### C14 (minor, ROUTE: foundations worker) foundation_check is red on the landed tree
- `python3 tools/foundation_check.py` at 22baf77 + critic commits: 3 violations over 15 map-seeds (exit
  1): `landmark:SahurAqueduct` buried (SahurSprings 303), `landmark:TurbineRidge` Turbine1 buried 2.10 at
  (-347,-618) (RotRidge 202), `wilds:slateShelter` sill 0.41 at (-646,-218) (RotRidge 202). ddd4ba1
  reported 0; a later landing (the main merge 58db872 or MapDecor's 22baf77 shifting the placement
  stream) changed those maps. Re-run and re-baseline before the gate is trusted.
