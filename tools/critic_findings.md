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
