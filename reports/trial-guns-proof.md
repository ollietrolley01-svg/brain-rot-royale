# #117 lobby trial guns: does a second podium gun add to your hotbar?

Jacob's branch `task/prove-trial-guns`, cut from main `f1bb3b4`, then merged with main **`1c70de8`** (after
Oliver merged `pc/ttk-plus-25`, `pc/mounted-guns-powerful` and `pc/hitreg-fixes`) and run again: the same 51
checks and the same 15/15 plants. Every line reference below is to `1c70de8`. Of the files this report cites,
those merges changed only `MatchService.lua` (a spawn shield is never lowered) and `CombatClient.client.lua`
(the client counts its own rounds). Neither touches the range; they only move line numbers. I measured things outside Studio (Python + lupa, running the game's own Lua) or read them
from source. Nothing was run in Roblox, and no game file or existing tool was edited.

OLIVER_LIST #117 says "Lobby trial guns change every pickup". The row is marked "in tree, unproven (commit
e666c61; merged to main)". e666c61 is "#117: lobby range guns add to your hotbar instead of replacing each
other". 3f4823f (09-24) changed one thing in the same function since then: a take the range can't find
afterwards now says "Couldn't hand you that.". Lobby v2 (`pc/lobby-v2`, on main) added a "FIRING RANGE"
sign on the road (`LobbyService.lua:3490`) and changed the podium's second label to "LEGENDARY • take
it and shoot the targets". It did not change the podiums, their prompts or RangeService.

## Verdict

**Fixed on main, in the code.** Taking podium gun A and then podium gun B leaves you holding both, B in
hand, with A's ammo untouched. I checked every order of the three podiums, every retake, a double press,
a lobby death and respawn, walking off and a match starting. I ran the real RangeService and
WeaponService whole, fired the real podium prompt handlers cut from LobbyService, and ran the real lobby
respawn path cut from MatchService. **51 checks pass and 15 of 15 planted faults are caught.** Range guns
never reach a match loadout or saved data. On the tree before e666c61 the same check fails 10 checks, the
first being "take 2: hotbar 1:PatapimChaingun, expected 1:NonnaDoubleBarrel 2:PatapimChaingun". That is
the bug Oliver saw.

**Problems found, most important first:**

1. **Retaking the gun in your hand during its reload fills the magazine but does not end the reload.**
   (On main, `RangeService.lua:132-142`.) A repeat take tops the magazine up and calls
   `WeaponService.Equip` on the gun's slot. Equip does nothing for the slot already held
   (`WeaponService.lua:1844`), so it never runs `selectSlot`, the function that cancels a reload. The
   reload timer runs on (`WeaponService.lua:1903-1921`), and `RangeService.Fire` refuses every shot while
   `loadout.reloading` is set (`RangeService.lua:196`). Measured: Golden Sahur Cannon, retaken just after
   a reload started, sat on a full 6/6 magazine, still reloading, for **3.00 s** (its whole
   `reloadTime`), and the HUD was told `reloading = true` for that time. Minor. The player sees a full
   magazine they can't fire for up to one reload. Before e666c61 a retake started a fresh loadout, which
   ended the reload. (The build machine owns the fix. One way: in the repeat path, when the gun is
   already in hand, clear `reloading` and bump `reloadToken` the way `selectSlot` does.)
2. **The Studio range regression should now fail on its first gun.** (On main,
   `tools/range_probe.server.lua:85-92`, built by `tools/build_range_test.py`.) Line 85 says "Cancel
   this test reload with a fresh rack loadout". It retakes the same gun mid-reload, waits 0.6 s and
   expects a shot at line 91 to broadcast. Since e666c61 a retake keeps the reload running (finding 1).
   All 15 guns the probe walks reload in 1.45 s or more (the first, PawnshopNine, in 1.45), so the shot is
   refused and the `check` at line 92 asserts. **Reasoning, not measured**: I can't run Studio, and the
   probe stops at its first failure. The probe was written for the old one-gun-at-a-time range and
   hasn't changed since the initial commit (741042c). Whoever runs it next will see
   `[RANGE] FAIL PawnshopNine miss still broadcasts`.
3. **Each take sends the client two loadout snapshots, and the first has the old gun in hand.**
   (On main, `RangeService.lua:144-158`.) Measured: a first take sends 2 (the empty loadout from Reset,
   then the gun), an adding take sends 2, and a retake of the gun in hand sends 1. On an adding take, the
   first snapshot (from `GiveWeapon`) shows the new gun in the hotbar with the old gun still held, and
   the second (from `Equip`) moves the held slot. The last one always matches the server (checked at 43
   moments). Both are sent in the same server step, one after the other. Whether a client ever draws the
   in-between state for a frame is **reasoning, not measured**: I expect not. The pickup sound plays once
   (CombatClient only plays it when the item count goes up, `CombatClient.client.lua:2296-2298`).
4. **A full hotbar can't happen from the podiums; if it did, the gun in hand would be replaced.**
   (Measured.) There are 3 podiums and 8 slots. The podiums are the only thing in the lobby that gives a
   gun: `RangeService.Give` has one caller (`LobbyService.lua:2218`), LobbyService has no other gun
   prompt, and nothing else in the lobby gives weapons. With 8 guns forced into a range loadout and
   slot 5 held, a new podium gun replaced **slot 5 only**. The gun that was there is gone, not dropped
   (the range ignores `GiveWeapon`'s third return value). That is the same rule as a floor pickup in a
   match (`WeaponService.lua:1572-1575`). Retaking a gun already in a full hotbar replaced nothing. #117
   didn't ask about a full hotbar, and the podiums can't cause one.
5. **The first take discards any loadout the range didn't make.** (Measured, not reachable.)
   `RangeService.lua:168` resets before the first gun. In the lobby there is never another loadout to
   lose: `PlaceInLobby` clears it (`MatchService.lua:320`), and a take is refused while a match is on.
   Noted only because the identity rule (#106) means "never write into it". It still replaces it.

**Why Oliver saw guns "change every pickup".** Before e666c61 every take started with
`WeaponService.Reset`, so you only ever held the last podium's gun. The prompts also reached 12 studs
with podiums 18 apart. That left a 6-stud band between each pair where either prompt could fire, and
which one fired depended on where you looked. e666c61 fixed both (reach 8). Both were first shipped in
`playtest-2026-09-24-2000` (main 8f16a5f, which contains e666c61 and 3f4823f).

## The path, end to end

1. **The podiums.** `LobbyService.lua:2168-2242` (in `buildArena`) collects the unstaged Legendaries
   (8 today, out of 65 guns), sorts them by name and stands three on podiums 18 studs apart
   (`z = -18, 0, 18`). Podium *i* shows gun `(day + i) mod 8`, where `day` is the UTC day number
   (`:2197`). Each podium's prompt captures its own entry, reaches 8 studs (`:2214`), and on `Triggered`
   calls `RangeService.Give(player, entry.id)` (`:2218`). The lobby is built once per server
   (`MatchService.lua:2186`), so the podiums don't change while it runs. Today's (09-25) three are
   Golden Sahur Cannon, Nonna Double Barrel and Patapim Chaingun.
2. **A take.** `RangeService.Give` (`RangeService.lua:107-179`) refuses during a match (`:108`), for an
   unknown gun, and off the terrace (radius 32 + 6 slack). If the player holds a loadout the range made
   (`active[player]` is the very table `WeaponService.Get` returns, `:130-131`), it:
   - looks for the same gun, and if found tops up its magazine, holds it and pushes (`:132-143`);
   - otherwise adds it with `WeaponService.GiveWeapon`, which fills the first empty slot
     (`WeaponService.lua:1561-1570`), and then holds it with `Equip` (`RangeService.lua:144-163`).
   The first take, or any take when the loadout isn't the range's, resets and gives one gun (`:166-178`).
3. **What the client is told.** Every change goes out as a whole `LoadoutChanged` snapshot
   (`WeaponService.Push`, `:162-226`), with `equipped`. HudClient (`HudClient.client.lua:4534`) and
   CombatClient (`:2292`) replace their copy with each one, and the hotbar highlights
   `loadout.equipped == index` (`HudClient.client.lua:1470`). No client script reads `slots[1]` as the
   gun in hand or sets its own held slot (62 client files searched). Choosing a slot sends `EquipSlot` and
   waits for the server's snapshot (`CombatClient.client.lua:1176-1182`, `HudClient.client.lua:1418-1420`).
   `RangeState true` follows every successful take.
4. **The gun on the character.** `selectSlot` asks for a rebuild, and the next Heartbeat builds whatever
   slot is held (`WeaponService.lua:1457-1512`).
5. **Letting go.** RangeService polls every 0.4 s (`:253-266`). It lets go when you step 6 studs past
   the terrace's rim, or when combat turns on. `stop` (`:57-101`) clears the loadout only if it is still
   the range's, destroys the welded `HeldGun`, pushes, and sends `RangeState false`.
6. **Death in the lobby.** `humanoid.Died` → `LoadCharacter` → `OnCharacterAdded`'s lobby branch →
   `PlaceInLobby`, which clears and pushes (`MatchService.lua:300-322, 2131-2145`). The range's entry is
   left stale until the poll, and the identity check means the next take starts fresh.
7. **A match.** `startMatch` reloads each joining player and gives them a new loadout with
   `WeaponService.Reset` (`MatchService.lua:1987`) before it turns combat on (`:2077`). Because the new
   loadout is a new table, the range's identity check never touches it. Loadouts are never saved:
   `PlayerData.lua` never names a loadout, slots, WeaponService or RangeService, and the only `PlayerData`
   call either module makes is reading the gun skin (`WeaponService.lua:249`). A slot can't be dropped
   on the lobby floor: `DropSlot` is gated on `MatchService.IsPlaying` (`Bootstrap.server.lua:533-542`).

## Evidence

`python tools/trial_guns_proof_check.py .` loads RangeService, WeaponService, WeaponData (with
ArsenalExpansion, CreativeArsenal, WorkshopArsenal), ItemData, MatchConfig, Rarity and SafeValue whole,
into a Roblox stand-in world (`tools/trial_guns_proof_world.lua`). It cuts and runs the range block of
`buildArena` (SetArea and the podium loop), plus `lobbyCFrame`, `PlaceInLobby` and `OnCharacterAdded` from
MatchService. A take is the podium prompt's own `Triggered` handler firing for a player standing on it.
The range's 0.4 s poll is the module's own loop, resumed by hand. The client is the last `LoadoutChanged`
and `RangeState` it was sent. Stand-ins: CombatService (only `IsEnabled`), StateSync, PlayerData (logs
every call), Remotes, and the gun models (an empty `HeldGun` carrying its id).

What it examined: **65 guns, 8 eligible Legendaries, 3 podiums, all 8 days of the rotation, 12,853
half-stud spots on the terrace, 202 podium takes, and 43 client-sync moments.**

| Invariant | Scenes | Result on main |
|---|---|---|
| I1 a take adds, nothing else moves, new gun in hand | S1: all 6 orders, a round spent before each take | holds |
| I2 no second copy of a held gun | S2: 3 guns × in hand or not; a double take from empty and holding one; a retake after a slot swap; S0: 5 takes per podium per day | holds |
| I3 range guns never reach a match | S5: both orders of poll and Reset; a floor pickup afterwards; a lobby player on the terrace; a take during a match | holds |
| I4 walk-off and lobby respawn hand it all back | S3 (and the 6-stud slack), S4 (poll before and after the next take) | holds |
| I5 client and character match the server | 43 moments across S1-S8 | holds |
| I6 each podium hands out the gun it shows; no spot reaches two prompts | S0: 8 days × 3 podiums × 5 takes; worst spot reaches 1 prompt at 8 studs | holds |
| I7 saved data only read | 43 `PlayerData.Get` calls, nothing else, 0 profiles changed | holds |

On the tree before e666c61 (`e666c61^`) the same check fails 10: S0 (reach 12, a spot in reach of 2),
S1, S2, S3, S4 ×2, S6, S7 ×2, and the DropSlot gate (added later, unrelated).

Planted faults (`--plant`), each aimed at an invariant, each caught:

```
  CAUGHT: I1: a take starts a fresh loadout every time (the pre-e666c61 behaviour)
  CAUGHT: I1: a pickup fills the slot in hand even with free slots (WeaponService.GiveWeapon)
  CAUGHT: I1: the gun just taken is not put in hand
  CAUGHT: I2: no look for a gun already held (a repeat take adds a copy)
  CAUGHT: I3/I4: the range writes into a loadout it did not make (identity check gone)
  CAUGHT: I3: the poll ignores a match starting
  CAUGHT: I3: the range hands guns out while a match runs
  CAUGHT: I4: walking off keeps the guns (stop never clears)
  CAUGHT: I4: walking off leaves the gun welded in hand
  CAUGHT: I4: a lobby respawn keeps the old loadout (PlaceInLobby never clears)
  CAUGHT: I5: a retake tops up without telling the client
  CAUGHT: I5: switching the held slot doesn't tell the client (WeaponService.Equip)
  CAUGHT: I6: a podium hands out a different gun from the one it shows
  CAUGHT: I6: podium prompts reach 12 studs again (two in reach at once)
  CAUGHT: I7: the inventory writes to saved data
trial_guns_proof_check planted faults: 15/15 caught
```

The existing `tools/range_give_check.py` (from e666c61) still passes. It runs RangeService against a
hand-written WeaponService. This check runs the real one, plus the prompts, the respawn path and the
match start.

No damage was measured, so `CombatDamageScale` plays no part.

## Other branches

- Merged into main since `f1bb3b4`, and included in the run above: `pc/hitreg-fixes` changes
  `CombatClient.client.lua` (the client counts its own rounds) and `CombatService.lua`. It reads
  `loadout.equipped` but still adopts each `LoadoutChanged` snapshot whole. `pc/ttk-plus-25` changes the
  damage scale, and `pc/mounted-guns-powerful` changes vehicle and mounted-gun data. None of them change
  the range path.
- Still unmerged: `pc/teambase-v2` changes `MatchConfig.lua` (vehicle slots) and team-mode files. It
  doesn't touch the range, the inventory, the lobby or MatchService.

## What was NOT proven

- **Roblox's own prompt choice.** The geometry says no spot on the terrace is within 8 studs of two
  podiums. It uses horizontal distance, which can only over-count. I did not run a real ProximityPrompt.
- **How it looks and feels.** The hotbar is drawn by the same HudClient code matches use, from the
  snapshot the check compares. I did not see it drawn. The real test is Oliver taking all three guns in
  a playtest and seeing three in the hotbar with the last one highlighted. It needs no probe or render.
- **Network order.** The two snapshots of one take are assumed to arrive in order and together.
  Whether a client ever shows the in-between frame is reasoning, not measured.
- **Finding 2** (the Studio range probe) is reasoned from its source. It was not run.
- **The start-of-match race** (a take between a player's `Reset` and combat turning on) was not run
  with real timing. It needs the player's new body within 8 studs of a podium, and that body appears
  on the pier, about 140 studs away. If it did happen, the range would replace the match's empty
  loadout, and the poll would clear it once combat turned on.

## For the coordinator

- Finding 1 is a small fix in `RangeService.lua` (build machine). Finding 2 is the matching change to
  `tools/range_probe.server.lua:85-92`: after a retake, wait out the reload, or take a different gun.
- No Studio run is needed to prove #117. A playtest look confirms it.
