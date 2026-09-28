# #85 loot spill: do chests and supply drops put their contents on the ground?

Jacob's branch `task/prove-loot-spill`, cut from main **`d1e4f73`**, with every run on that commit. Line
references are to `d1e4f73`. I measured things outside Studio (Python + lupa, running the game's own Lua)
or read them from source. Nothing was run in Roblox. No game file or existing tool was edited. No damage
is involved, so `CombatDamageScale` (0.736 on main) plays no part.

OLIVER_LIST #85: "Chests and supply drops should drop contents on the ground, not into inventory",
`[~]` "in tree, unproven (commit 3441c0f, d508889)". f316617 (09-22) made chests spill. d508889 (09-24)
made the supply crate spill. 3441c0f (09-24) made every dropped pickup wait 1 s before it can be taken.

## Verdict

**For players, it holds on main.** Every container a player can open puts its whole roll on the ground
as pickups, one pickup per rolled item, and none of it goes into the bag. That covers map chests,
team-base chests, the battleground's chest, a chest rebuilt after its floor broke, and the supply crate.
Only ammo goes straight to the opener, on purpose: there is no ammo pickup. The 1 s settle is enforced by
the server on both pickup prompts. No pickup takes itself when walked over. Two presses in the same frame
spill once. The spill outlives the chest, the crate and 600 s. **33 checks pass, and 14 of 14 planted
faults are caught.**

**Bots are not covered by #85.** A bot that opens a chest or a crate takes the loot straight to itself,
and nothing lands. Bots also ignore the settle second. Whether #85 should apply to bots is Oliver's call.

**How a spill looks has never been rendered.** Two pickups often land on exactly the same point. On a
ledge, most of a spill lands on one spot. A few pads end up inside a wall at one team-base chest. The
Studio gallery `tools/loot_spill_gallery.lua` settles those questions. It is the coordinator's to run.

**Why Oliver still saw "straight to inventory" on 09-24** (reasoning, not measured). d508889 is the commit
that made the crate spill. It landed at 22:08 EDT on 09-23. Every playtest tag up to
`playtest-2026-09-23-1615` still has the crate's `WeaponService.GiveWeapon` into the bag
(`SupplyDropService.lua:243` at `c48a2de`). No tag was made between 16:13 on 09-23 and 19:23 on 09-24,
and `playtest-2026-09-24` is the first tag that has both d508889 and 3441c0f. So the build Oliver played
most likely had no crate spill at all. 3441c0f's diagnosis was that the key held from the crate's 1.2 s
hold took the spill as it appeared. That is a theory, not a measurement. The settle covers that case
either way. `playtest-2026-09-24` is the first build where Oliver could see a supply crate spill.

## Problems found, most important first

1. **Bots open chests and crates straight into their own stock, and nothing lands.** (Measured, B1/B2.)
   `LootService.ClaimForBot` (`LootService.lua:1057-1080`) rolls **one** gun for a chest and opens it
   (`:1071`). It does not call the spill. `SupplyDropService.ClaimForBot` (`SupplyDropService.lua:386-398`)
   hands over the crate's gun. `holdLoot` then adds the bot-side extras: for a crate, a MedKit, a Shield
   Potion, a defense and a rocket; for a chest, bandages, sometimes a MedKit, shields, a defense, a
   throwable (`BotService.lua:3042-3070`, read). In the harness, pickups landed: **0** for the chest and
   **0** for the crate. The same chest opened by a player lands 2 guns and 1 to 5 items. The effect: a
   player arriving a moment after a bot finds nothing on the floor, and a bot's chest is worth one gun.
   Whether #85 applies to bots is Oliver's call.
2. **Pickups stack on the same point.** (Measured, P2/P4/P6.) Pads are 2.4 studs across.
   - `scatter` jitters a throw by `math.random(-SCATTER, SCATTER)` (`LootService.lua:881`). That returns
     a whole number, so there are only 81 possible offsets, and two items that draw the same one land
     on exactly the same point.
   - On flat ground, **47 of 352** chest spills (13%) had two pickups on the very same point, and 306 had
     pads overlapping.
   - A throw that would go over an edge falls back to the chest's own spot (`:890-898`). That is right,
     because nothing falls off the roof, but it piles items up. On a 12 x 12 roof, **26 to 27 of 60** spills
     stacked. On a 3-wide gallery, **56 of 60**.
   - In the team-base compound's real layout, **185 to 189 of 672** spills stacked (spots SupplyAlcove,
     MachineGunNest, LeanTo, BunkerArmoury). On the battleground's gallery chests, **21 to 24 of 96**.
   - Nothing is lost: each item keeps its own prompt. Roblox shows one prompt per key at a time, so a
     second pickup on the same point only appears once the first is taken (reasoning). With two labels
     on top of each other, a player may read it as one item. That is judged by looking: gallery views
     01-05.
3. **`clearOfWalls` can push a pad into a wall.** (Measured, P7.) `clearOfWalls` (`LootService.lua:851-862`)
   pushes a drop away from anything within 1.6 studs at knee height. It adds the pushes from all eight
   directions and never checks the result again.
   - At the compound's TowerBase chest, one landing point was 0.09 studs from a `TowerLeg`, with the
     perimeter `Wall` 1.31 studs behind it. The push was 2.1 studs, into the wall.
   - The ray down that follows starts inside the wall. Roblox rays ignore the part they start in, so it
     found the foundation, and the pad was left inside the wall. Both parts are Blocks, so the boxes are
     exact there.
   - **3 to 5 of about 2,960 pads per run** (0.1 to 0.2%), always at TowerBase: two perimeter walls and
     the `TowerLadder`.
   - The prompt still works through a wall (`RequiresLineOfSight = false`), so the item can be taken
     (reasoning). It is hidden, though.
   - This affects every drop that uses `scatter`: death drops and dropped slots as well as spills.
   - The compound on `pc/teambase-v2` has no TowerBase chest: **0 of 4,007** there.
4. **Bots skip the settle second.** (Measured, B3.) `LootService.ClaimForBot` (`:1057`),
   `ClaimHealForBot` (`:1102`) and `BotService.Loot.claimConsumable` (`BotService.lua:5103`) check
   `Claimed` and `PlayerHolding`, not `Settling`. 0.05 s after a crate spill landed, all three handed
   the gun, the MedKit and the Shield Potion to a bot while the players' prompts were still off. In
   practice the window is small. A bot only sees new pickups when its loot snapshot refreshes, once a
   second (`BotService.lua:2886`), and it must then stand at the item for `ClaimTime` (0.3 s,
   `LootService.lua:1050`). That part is reasoning, not measured.
5. **Pads inside the chest or the crate while it stands.** (Measured, P2.)
   - 106 of 1,719 chest-spill pads (6%) lie within 1.3 studs of the chest's centre, which is inside the
     3.6 x 2.6 chest at any angle. The chest goes after 2.2 s (`OPENED_LINGER`, `:61`), and the settle
     ends at 1.0 s, so for 1.2 s a pickup that can be taken is hidden inside the chest.
   - 39 to 48 of 240 crate-spill pads (16 to 20%) lie under the 9 x 9 crate for its 1.6 s
     (`SupplyDropService.lua:180`). The crate spill lands 7 studs out with up to 4 studs of jitter each
     way.
   - Cosmetic. Gallery views 06 and 07.
6. **A spill whose floor breaks is rebuilt without the settle and outside the cap.** (Measured, R6.)
   `LootService.Resettle` (`:954-1000`) rebuilds a pickup with `spawnGroundWeapon` and `spawnConsumable`
   directly (`:989`, `:995`), not through `DropWeapon` and `DropItem`. So the rebuilt pickup was takeable
   0.05 s after the spill, and it survived 60 newer drops that the 50-drop cap should have thrown it out
   for. Minor.
7. **The 50-drop cap removes spills too.** (Measured, R5. This is Oliver's rule, 09-22 15:26, and it names
   chest spills.) An untouched crate spill started losing pieces after **47** newer drops anywhere on the
   map. A bot's death drops 1 to 5 items, so that is roughly 10 to 45 deaths. The cap takes the oldest
   first, whatever the rarity, so a supply drop's Legendary can go. Reported for Oliver, not a bug.
8. **Battleground floor-weapon spots pile up guns.** (Measured, R7. This is not #85, but it runs through the
   same drop code.)
   - 14 floor-weapon spots seed with `LootService.DropWeapon(..., spot.position, nil, spot.position)`
     (`TeamBattleground.lua:3683`). That scatters the gun up to 5.7 studs off the spot.
   - The restock treats a spot as free unless a pickup lies within 3 studs (`:3649`), so 69% of seeds
     leave their spot "free".
   - With nobody taking anything, the guns near those spots grew from 14 to **17 to 39** over one 480 s
     match (5 matches).
   - Those guns count toward the 50-drop cap. A chest spill left on the gallery was not lost to it in any
     of the 5.
9. **Dead code.** `LootService.GiveOrDrop` (`:1011`) has no callers since f316617 and d508889.

## 1. Every way loot comes out of a container (on main d1e4f73)

**Examined: 5 ways a player opens a container, 2 ways a bot does, and 10 call sites that grant into an
inventory.** Every chest, of any kind, is built by one function, `spawnChest` (`LootService.lua:526`), and
opened by its prompt (`:542-607`). The supply crate is built in `SupplyDropService.lua` and opened by
`attachPrompt`'s prompt (`:240-271`).

| Container | Built by | Opened by a player | Measured |
|---|---|---|---|
| Map chest (battle royale) | `Populate`, `mapInfo.chestSpots` (`:653-655`) | `spawnChest` prompt, 0.8 s hold | 352 chests (2 guns, and Loot Frenzy's 3), 1,719 pickups, 0 mismatched, 0 in the bag; 22 more with an Aura Farm rarity floor |
| Team-base chest | `GameMode` restock through `LootService.SeedAt` (`GameMode.lua:715`, `LootService.lua:791`) | same | 60 chests, 0 mismatched, 0 in the bag |
| Battleground chest (keep gallery) | `TeamBattleground.SeedLoot` then `seedSpot` then `SeedAt` (`TeamBattleground.lua:3681-3725`) | same | 20 chests, 0 mismatched, 0 in the bag |
| Chest whose floor broke | `LootService.Resettle` then `spawnChest` (`:1000`) | same | 20 of 20 came down and spilled, 0 mismatched |
| Supply crate | `SupplyDropService.Start` then `dropOne` | crate prompt, 1.2 s hold | 60 crates: gun + MedKit + Shield Potion + Pop-up Bunker, one pickup each; 0 in the bag; 60/60 full ammo refills |
| A bot at a chest | `LootService.ClaimForBot` | (bots have no prompts) | 1 gun to the bot, 0 pickups (problem 1) |
| A bot at a crate | `SupplyDropService.ClaimForBot` | | the gun to the bot, 0 pickups (problem 1) |

Not containers: shed loot and team-base loose loot are ordinary ground pickups (`MapWilds` `lootSpots`,
`SeedAt`). The lobby's Crate Altar is cosmetic crates, not match loot. The Rot Vendor sells for coins
(`VendorService.Buy`, into the bag by design).

**"Every roll lands once"** is checked by recording what the real `WeaponData.RollChestWeapon` and
`ItemData.Roll*` return during the press, and comparing that list with the pickups that appeared. Guns
compare by id; items by id and amount.

**Q5, other paths into the inventory.** Every call to `GiveWeapon`, `GiveConsumable`, `GiveHeal`,
`GiveItem`, `SwapHeldForItem` or `GiveOrDrop` in `ServerScriptService` (10 call sites):

| Where | What |
|---|---|
| `LootService.lua:376` `spawnGroundWeapon` | a player takes a gun pickup |
| `LootService.lua:475`, `:485` `spawnConsumable` | a player takes an item pickup, or swaps for it |
| `LootService.lua:1012` `GiveOrDrop` | no callers |
| `ModeTeams.lua:1659`, `:1667` `GrantLoadout` | a team mode's spawn kit |
| `RangeService.lua:148`, `:173` | the practice range |
| `VendorService.lua:135` | a vendor purchase |
| `AdminService.lua:109` | the admin "Weapon" command |

None is in `spawnChest` or the crate's `attachPrompt`: the check reads both function bodies. The chest
and the crate still call `WeaponService.GiveAmmo` (`LootService.lua:576`, `SupplyDropService.lua:263`).
That is ammo only, by design. No remote other than `DropSlot` (`Bootstrap.server.lua:533`) reaches the
loot code, and that one drops a slot; it takes nothing.

## 2. The settle (3441c0f)

- **The delay is 1.00 s** (`DROP_SETTLE`, `LootService.lua:210`). I measured it in 10 ms steps. Every
  dropped pickup gets it through `trackDrop` (`:227-231`): spills, death drops, a dropped slot, and the
  battleground's seeded guns.
- **The server enforces it on both ways a player takes a pickup:** the gun's prompt (`:365`) and the
  item's prompt (`:472`). The check fires `Triggered` at 0, 0.5 and 0.95 s regardless of the prompt's
  `Enabled`. That stands in for a held key or a forged press. Nothing was taken, and all 4 pieces stayed
  on the ground (crate and chest). At 1.0 s every prompt was back on and one fresh press took each piece.
- **There is no auto-pickup.** No pickup or part of one has a `Touched` handler: 69 instances examined,
  0 handlers. Nothing else in the server takes a pickup for a player.
- **Bots:** not applied (problem 4).
- **Bypasses:** bots, and a floor breaking under a settling spill (problem 6). A player has none.

## 3. Where a spill lands

A chest spill aims 4 studs from the chest toward the opener. A crate spill aims 7 studs out. `scatter`
(`LootService.lua:870-899`) adds up to ±4 studs of whole-number jitter on each axis, then does four
things:

1. It traces the throw at knee height and stops 1.6 studs short of anything it hits.
2. It moves the pad clear of walls (`clearOfWalls`).
3. It puts the pad on the floor under that point.
4. If that floor is more than 2.5 studs above or below the one it was thrown from, it uses the chest's
   own spot instead.

| Scene | Spills | Pads | On the floor it was thrown from | Inside a solid part | Reachable | Stacked pair (< 0.5) |
|---|---|---|---|---|---|---|
| Flat ground, chests | 352 | 1,719 | all | 0 | n/a | 47 (all on the very same point) |
| Flat ground, crates | 60 | 240 | all | 0 | n/a | 4 |
| 6-wide corridor | 60 | 278 | all, all between the walls | 0 | n/a | |
| 12 x 12 roof, 12 up | 60 | 270 | all on the roof | 0 | n/a | 26 to 27 |
| 3-wide gallery, 11 up | 60 | 256 | all on the gallery | 0 | n/a | 56 |
| Team-base compound (`TeamBaseRuins.Layout`, 14 chest spots x 4 openers x 12) | 672 | ~2,960 | all | **3 to 5** (TowerBase, problem 3) | all in prompt reach; 31 to 33 on ground no body stands on (behind a chest, under the workbench) | 185 to 189 |
| Battleground (`TeamBattleground.Layout`, KeepGallery S/N) | 96 | ~414 | all | 0 | n/a | 21 to 24 |
| `pc/teambase-v2`'s compound (20 chest spots) | 912 | 4,007 | all | 0 | all in prompt reach; 376 no body stands on | 170 |

"Reachable" uses the compound's own walk grid from `tools/team_base_ruins_check.py`: an R15 body, steps
of 1.5. A pad counts as in prompt reach when a player can stand within 9 studs of it on its own level,
somewhere walkable from the spawn pads. Openers are picked where a body fits, 2.5 to 6.5 studs from the
chest, with nothing solid between them at knee height. Roofs: a chest on a roof keeps its whole spill on
the roof. Nothing was thrown down to the street in any scene.

## 4. The check: `tools/loot_spill_proof_check.py` (new, in my branch)

It loads **LootService and SupplyDropService whole**, with the real `ItemData`, `Rarity`, `WeaponData` and
the shared modules they pull in. It cuts two pieces from real files and runs them as they are:

- **TeamBattleground's loot:** `spotFree`, `RollWeapon`, `seedSpot`, and `SeedLoot` with its restock
  loop.
- **`BotService.Loot.claimConsumable`.**

The stand-ins:

- `WeaponService`: a bag that records every grant.
- `CrateModels.Chest`: a part the chest's size.
- `QuestService`, `StateSync`, `StormService`, `DestructibleService`, `Remotes`, `ZFight`, `ItemModels`.
- The world: instances with attributes and signals, a virtual clock, a ground plane, and a raycaster
  over oriented boxes.

The boxes come from three places:

- **Hand-made scenes:** the corridor, the roof and the gallery.
- **The compound's layout:** `TeamBaseRuins.Layout`, dumped by `tools/team_base_ruins_check.py`.
- **The battleground's layout:** `TeamBattleground.Layout`, dumped by
  `tools/team_battleground_check.py`, which needs `numpy`.

Containers are opened through their real prompts' `Triggered`. The crate comes from the real
`SupplyDropService.Start`: 75 s to the first drop, 9 s of fall.

Lua randomises string hashing, so `pairs()` order over the weapon tables differs between runs. The
counts below move slightly from run to run; the ranges in this report are from 10 runs of the final
version. The checks passed in all 10.

Verbatim, on main d1e4f73:

```
ok      A1 a map chest (Populate) spills every roll as exactly one pickup, 2 guns and Loot Frenzy's 3  (352 chests, 1719 pickups, 0 mismatched)
ok      A1 a map chest puts nothing in the opener's bag (ammo only), and the toast says on the ground  (0 bags touched; 352/352 toasts)
ok      A1 with a rarity floor (Aura Farm) a chest still spills its 2 guns, none in the bag  (22 chests, 0 wrong)
ok      A2 a team-base chest (LootService.SeedAt) spills every roll as one pickup, nothing in the bag  (60 chests, 263 pickups, 0 mismatched, 0 bags touched)
ok      A3 the battleground's chest (TeamBattleground.SeedLoot) spills every roll as one pickup, nothing in the bag  (20 chests, 90 pickups, 0 mismatched, 0 bags touched)
ok      A4 a chest rebuilt on the ground after its floor broke (Resettle) spills every roll as one pickup  (20 of 20 came down, 20 opened, 0 mismatched, 0 bags touched)
ok      A5 a supply crate (SupplyDropService.Start) spills its gun, MedKit, Shield Potion and Pop-up Bunker as one pickup each  (60 crates, 0 wrong)
ok      A5 a supply crate puts nothing in the bag; the opener gets a full ammo refill and a toast naming the spill  (0 bags touched, 60/60 refills, 60/60 toasts)
ok      A6 an opener with no character: the chest and the crate still spill (in front, +Z), nothing in the bag  (chest 5 of 5, crate 4 of 4)
FINDING B1 a bot opening a chest (LootService.ClaimForBot) takes ONE gun straight to itself; nothing lands  (got PocketPopper; pickups landed 0; chest opened true (a player's opening of the same chest lands 2 guns + 1-5 items))
FINDING B2 a bot opening a supply crate (SupplyDropService.ClaimForBot) takes the gun straight to itself; nothing lands  (got SundaySpecial (crate's SundaySpecial); pickups landed 0)
ok      S1 crate: every spilled pickup lands with its prompt off and Settling set  (4 pickups, 4 prompts off, 4 settling)
ok      S2 crate: presses at 0, 0.5 and 0.95 s take nothing (the server checks Settling, not only the prompt)  (taken 0, still on the ground 4 of 4)
ok      S3 crate: at 1.0 s every prompt is back on and a fresh press takes each pickup into the bag  (4 of 4 back on; bag item:MedKitx1,item:PopupBunkerx1,item:ShieldPotionx1,weapon:RatioPDW)
ok      S1 chest: every spilled pickup lands with its prompt off and Settling set  (5 pickups, 5 prompts off, 5 settling)
ok      S2 chest: presses at 0, 0.5 and 0.95 s take nothing (the server checks Settling, not only the prompt)  (taken 0, still on the ground 5 of 5)
ok      S3 chest: at 1.0 s every prompt is back on and a fresh press takes each pickup into the bag  (5 of 5 back on; bag item:LaunchPadx1,item:MedKitx1,item:MiniShieldx2,weapon:BonkerDoubleBarrel,weapon:PawnshopNine)
ok      S4 the settle lasts 1.00 s (DROP_SETTLE), measured in 10 ms steps  (1.00 s)
ok      S5 no pickup takes itself on touch: 0 Touched handlers on every spilled pickup and its parts  (54 instances examined, 0 with a Touched handler)
FINDING B3 bots skip the settle: 0.05 s after a crate spill lands a bot can claim its gun, MedKit and Shield Potion  (ClaimForBot -> CappuccinaLauncher, ClaimHealForBot -> MedKit, claimConsumable -> true (shield:ShieldPotion); the player's prompts are still off)
ok      R1 two presses in one frame spill once: a chest's roll lands once, a crate's 4 pieces once  (chest 5 pickups for 5 rolls, crate 4 pickups; second presser's toasts nil/nil)
ok      R2 a player and a bot never both open one container, in either order (chest and crate)  (bot after player: nil/nil; player after bot: 0/0 pickups)
ok      R3 two players pressing one spilled gun and one MedKit in the same frame: each goes to exactly one bag  (2 grants for 2 pickups (gun true, MedKit true))
ok      R4 the chest (2.2 s) and the crate (1.6 s) go, a late press spills nothing, and the spill outlives both, the drops' Stop and 600 s  (chest gone true, crate gone true, late press 0, 8 of 8 still there)
FINDING R5 the 50-drop cap: an untouched crate spill (a Legendary can be in it) starts going after this many newer drops anywhere  (47 newer drops (4-piece spill; a bot's death drops 1-5, a chest spill 3-8))
FINDING R6 a spill whose floor breaks inside its settle second is rebuilt (Resettle) takeable at once and outside the 50-drop cap  (5 of 5 spilled pickups came down; 5 of them with the prompt already on, 0.05 s after the spill; 5 of them still there after 60 newer drops)
ok      Q5 no grant (GiveWeapon, GiveConsumable, GiveHeal, GiveItem, SwapHeldForItem, GiveOrDrop) inside spawnChest or the crate's attachPrompt  (10 grant call sites in ServerScriptService; in the container code: none)
FINDING Q5 every grant call site in ServerScriptService, by function  (AdminService.lua Weapon: GiveWeapon@109; LootService.lua LootService.GiveOrDrop: GiveConsumable@1012; LootService.lua spawnConsumable: GiveConsumable@475, SwapHeldForItem@485; LootService.lua spawnGroundWeapon: GiveWeapon@376; ModeTeams.lua ModeTeams.GrantLoadout: GiveWeapon@1659, GiveConsumable@1667; RangeService.lua RangeService.Give: GiveWeapon@148, GiveWeapon@173; VendorService.lua VendorService.Buy: GiveConsumable@135)
ok      P1 flat ground, map chests: every pad on the floor, resting on it, inside nothing  (352 spills, 1719 pads; 0 level, 0 unsupported, 0 inside)
ok      P1 flat ground, supply crates: every pad on the floor, resting on it, inside nothing  (60 spills, 240 pads; 0 level, 0 unsupported, 0 inside)
FINDING P2 flat ground: how a spill lies (pads are 2.4 across; a stacked pair is under 0.5 apart)  (chests: 352 spills, 47 with a stacked pair (47 of them on the very same point), 306 with overlapping pads, 106 of 1719 pads inside the chest while it stands 2.2 s, furthest 9.7 from its centre; crates: 60 spills, 4 stacked (4 same point), 51 overlapping, 41 of 240 pads inside the 9x9 crate while it stands 1.6 s)
ok      P3 corridor: every pad between the walls, on the floor, inside nothing  (60 spills, 278 pads, 0 off)
ok      P3 roof: every pad on the roof, on the floor, inside nothing  (60 spills, 269 pads, 0 off)
FINDING P4 roof: pads thrown over the edge fall back onto the chest's own spot and stack there  (27 of 60 spills have a stacked pair, 52 overlapping; 79 of 269 pads inside the chest while it stands)
ok      P3 gallery: every pad on the gallery, on the floor, inside nothing  (60 spills, 254 pads, 0 off)
FINDING P4 gallery: pads thrown over the edge fall back onto the chest's own spot and stack there  (56 of 60 spills have a stacked pair, 60 overlapping; 182 of 254 pads inside the chest while it stands)
ok      P5 a team-base compound (TeamBaseRuins.Layout): every pad on the floor it was thrown from  (14 chest spots (56 openers), 672 spills, 2966 pads, 0 off)
ok      P5 a team-base compound (TeamBaseRuins.Layout): every pad resting on something  (14 chest spots (56 openers), 672 spills, 2966 pads, 0 off)
FINDING P7 a team-base compound (TeamBaseRuins.Layout): a pad pushed into a solid part  (4 of 2966 pads: TowerBase item:CookedCoconutx2 at (-36.9, 0.1, -40.9) in Wall; TowerBase weapon:AuraCrossbow at (-44.9, 0.1, -32.9) in Wall; TowerBase weapon:RustbeltMarshal at (-44.9, 0.1, -32.9) in Wall)
ok      P5 a team-base compound (TeamBaseRuins.Layout): every pad in prompt reach of ground walkable from the spawn pads  (14 chest spots (56 openers), 672 spills, 2966 pads, 0 off)
FINDING P6 a team-base compound (TeamBaseRuins.Layout): how the spills lie  (672 spills: 189 with a stacked pair (<0.5 apart), 592 with overlapping pads (<2.4); 225 of 2966 pads inside the chest while it stands; 31 pads no body can stand on (behind the chest, under a bench), all in prompt reach; worst spots: SupplyAlcove3 45/48 overlapping, 22 stacked, SupplyAlcove4 45/48 overlapping, 16 stacked, RuinCorner 44/48 overlapping, 20 stacked, SupplyAlcove1 43/48 overlapping, 14 stacked)
ok      P5 the battleground (TeamBattleground.Layout): every pad on the floor it was thrown from  (2 chest spots (8 openers), 96 spills, 411 pads, 0 off)
ok      P5 the battleground (TeamBattleground.Layout): every pad resting on something  (2 chest spots (8 openers), 96 spills, 411 pads, 0 off)
ok      P5 the battleground (TeamBattleground.Layout): every pad inside no solid part  (2 chest spots (8 openers), 96 spills, 411 pads, 0 off)
FINDING P6 the battleground (TeamBattleground.Layout): how the spills lie  (96 spills: 22 with a stacked pair (<0.5 apart), 79 with overlapping pads (<2.4); 36 of 411 pads inside the chest while it stands; 0 pads no body can stand on (behind the chest, under a bench), all in prompt reach; worst spots: KeepGalleryN 40/48 overlapping, 11 stacked, KeepGalleryS 39/48 overlapping, 11 stacked)
FINDING R7 battleground restock: a floor-weapon spot is seeded through DropWeapon, scattered up to 5.7 studs off, and counts as free unless a pickup lies within 3, so untouched spots pile up guns every 75 s  (14 floor-weapon spots seeded with 14 guns; nobody taking any, guns within 12 studs of them after each of the 6 restocks of a 480 s match: [18, 20, 22, 23, 24, 24]; at the end of 5 such matches: [24, 24, 26, 28, 28]; a player's chest spill left on the gallery lost a piece to the 50-drop cap in 0 of 5)
loot_spill proof: 33 checks, 0 failed, 13 findings
```

**Planted faults** (`--plant`). Each one edits the game's text in memory, aimed at something the code
must keep forever. A plant counts as caught only when the check it is aimed at fails. **14 of 14
caught:**

```
CAUGHT a chest hands its first gun straight to the opener -> A1 ..., A2 ..., A3 ..., A4 ..., Q5 ...
CAUGHT the crate hands its MedKit straight to the opener -> A5 ..., Q5 ...
CAUGHT a chest's spill loses its throwable -> A1 a map chest (Populate) spills every roll as exactly one pickup, 2 guns and Loot Frenzy's 3
CAUGHT drops never settle -> S1 crate ...; S1 chest ...
CAUGHT the server takes a gun while it settles -> S2 crate ...; S2 chest ...
CAUGHT the server takes an item while it settles -> S2 crate ...; S2 chest ...
CAUGHT the settle never ends -> S3 crate ...; S3 chest ...; S4 the settle lasts 1.00 s (DROP_SETTLE), measured in 10 ms steps
CAUGHT a pickup takes itself on touch -> S5 no pickup takes itself on touch: 0 Touched handlers on every spilled pickup and its parts
CAUGHT a chest opens twice -> R1 two presses in one frame spill once: a chest's roll lands once, a crate's 4 pieces once
CAUGHT a crate opens twice -> R1 two presses in one frame spill once: a chest's roll lands once, a crate's 4 pieces once
CAUGHT a bot claims an opened chest -> R2 a player and a bot never both open one container, in either order (chest and crate)
CAUGHT dropped loot expires after 60 s -> R4 the chest (2.2 s) and the crate (1.6 s) go, a late press spills nothing, and the spill outlives both, the drops' Stop and 600 s
CAUGHT a throw goes through walls -> P3 corridor: every pad between the walls, on the floor, inside nothing
CAUGHT a throw over an edge lands on whatever is below -> P3 roof ...; P3 gallery ...; P5 ... (compound and battleground)
loot_spill proof plants: 14/14 caught
```

(The tool prints the full check names; they are shortened here.) The first version of four plants was
"caught" only because the harness crashed on a missing pickup. I made the harness survive those, so each
is now caught by the check it is aimed at. A crash counts as caught only if the tool says so, and none
does now.

One thing is not held as a check: problem 3. A pad inside a solid part in the compound fails on main
(3 to 5 pads per run), so it is reported as FINDING P7. The same invariant is a check for the hand-made
scenes and the battleground.

## 5. The existing checks, honestly

`tools/loot_drop_check.py` (3441c0f) runs on main: `28 checks, 0 failed`, `--plant` 10/10. It runs the
real LootService and SupplyDropService and MatchService's `dropLoot`. It covers the crate claim, the
settle, and battle-royale death drops. It has **no chest at all**, no bot, and one flat ground plane.
`tools/scorch_check.py` (d508889) looks at whether the crate claim calls `GiveWeapon`.

I applied each of my 14 plants to a scratch copy of the tree (`git archive HEAD`) and ran both:

| Plant | `loot_drop_check` | `scorch_check` |
|---|---|---|
| a chest hands its first gun straight to the opener | missed | missed |
| the crate hands its MedKit straight to the opener | CAUGHT | CAUGHT |
| a chest's spill loses its throwable | missed | missed |
| drops never settle | CAUGHT | missed |
| the server takes a gun while it settles | CAUGHT | missed |
| the server takes an item while it settles | CAUGHT | missed |
| the settle never ends | CAUGHT | missed |
| a pickup takes itself on touch | missed | missed |
| a chest opens twice | missed | missed |
| a crate opens twice | missed | missed |
| a bot claims an opened chest | missed | missed |
| dropped loot expires after 60 s | CAUGHT | missed |
| a throw goes through walls | missed | missed |
| a throw over an edge lands on whatever is below | missed | missed |

**If a chest went back to handing its loot to the opener, neither existing check would notice.** That is
the other half of #85, and the gap `loot_spill_proof_check.py` fills.

## The `pc/*` branches

`pc/ttk-plus-25`, `pc/hitreg-fixes` and `pc/mounted-guns-powerful` are merged into main
(`git merge-base --is-ancestor`), and none of them touched the loot code. `pc/teambase-v2` is not merged.
It touches `LootService.lua` (one line: `BaseStock.chest` 14 → 20), `TeamBaseRuins.lua` (a new
compound), `ModeTeams.lua` and `BotService.lua`. The BotService change is to vehicle routes, not loot.
I ran the check on an extract of `origin/pc/teambase-v2` (`git archive`):

- `34 checks, 0 failed, 12 findings`, and `--plant` 14/14. It has one check more than main: with no pad
  inside a solid part, P5's "inside no solid part" stays a check instead of turning into FINDING P7.
- Its compound has 20 chest spots and 4,007 pads, and **none inside a solid part**: the TowerBase chest
  is gone.
- 376 pads lie on ground a body can't stand on, but all are in prompt reach.
- So if it merges, problem 3 goes away in the compound; the stacking stays.

## What this does NOT prove

- **Roblox's prompt input.** The check fires `Triggered` directly. Some Roblox questions it cannot
  answer:
  - Does a key held from the crate's 1.2 s hold fire a zero-hold prompt that appears under it? That was
    3441c0f's theory.
  - Does a disabled prompt ever fire?
  - Does `Exclusivity` show one prompt at a time over a stacked pair?

  The server refuses a take while `Settling` is set, so the settle holds either way.
- **Anything drawn.** Stacked labels, pads inside a chest or under a crate, a pad inside a wall, whether
  a spill reads as loot at all: that is judged by looking. `tools/loot_spill_gallery.lua` is written for
  it and has not been run.
- **Real shapes and terrain.** Wedges, cylinders and balls are boxes in the harness. The ground is a flat
  plane, not a real map's terrain. The compound and the battleground sit at the origin, not on a real
  map. The TowerBase finding involves only Block parts, so the boxes are exact there.
- **Bots end to end.** B1 to B3 call the bots' claim functions directly. `holdLoot`'s extras were read,
  not run, and so was the snapshot-and-hold timing that limits problem 4 in practice.
- **Which build Oliver played on 09-24.** The timeline above is from git tags, not from Oliver.
- **Replication and streaming** of pickups to clients.

## For Oliver (product calls, not bugs)

1. Should bots opening a chest or a supply crate spill it on the ground too (problem 1)? Today a bot takes
   one gun and its extras straight to itself, and nothing lands.
2. Should the 50-drop cap be allowed to remove a supply drop's spill, Legendary included (problem 7)?
3. Is a battleground gun spot slowly growing a pile of guns over a match fine (problem 8)?

## For the coordinator

- **Render:** `powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/loot_spill_gallery.lua -OutDir <folder> -TimeoutSeconds 900`.
  - It builds RotRidge, runs the real `ModeTeams.Setup` for Team Deathmatch, seeds team 1's chests
    through `BaseLootSpots`/`SeedAt`, and spills every chest the way its prompt does, with the same
    `DropWeapon`/`DropItem` calls.
  - It also spills the battleground's gallery chest, and a crate-sized block with its spill.
  - The notes give, per chest: pads, level, stacked and overlapping pairs, pads inside the chest, and
    pads inside a solid Map part. A planted block on a pad must read "CAUGHT".
  - Views 01-04 are compound chests (SupplyAlcove2, TowerBase, YardWorkbench, BunkerArmoury where they
    exist). 05 is the battleground gallery. 06-07 are the crate standing and gone.
- These are in game files and yours to fix if Oliver wants them, with source lines above. I have not
  touched them:
  - Problem 2: the whole-number jitter, `LootService.lua:881`.
  - Problem 3: `clearOfWalls` never checks the point it pushed to, `:851-862`.
  - Problem 4: the bot claims skip `Settling`, `:1057`, `:1102`, `BotService.lua:5103`.
  - Problem 6: `Resettle` bypasses `trackDrop`, `:989`, `:995`.
  - Problem 8: the spot seeds scatter wider than `spotFree`'s 3 studs, `TeamBattleground.lua:3649`,
    `:3683`.

## Files

- `reports/loot-spill-proof.md`: this report.
- `tools/loot_spill_proof_check.py`: the check (`--plant` for the planted faults). Needs lupa and numpy.
- `tools/loot_spill_gallery.lua`: the Studio gallery and measurement, for the coordinator.
- `README-task-prove-loot-spill.md`: what the branch adds.
