# #97 hit registration: an independent check of what is on main

Jacob (bimjom), branch `task/prove-hitreg`. **Proved against main `7ddeb4a`, then re-run unchanged on main `ac22e5e`** (its only changes since are
TeamBattleground, road tools, STATUS and one mailbox message). Every file:line below holds on both. No game file or existing tool was edited. Three new files carry the evidence:
`tools/hitreg_firerate_sim.py`, `tools/hitreg_rewind_extra_plants.py` and this report.

The later commits I was asked to account for (a549527, 599130d, 7fab339) are all ancestors of my original
base 82968cb. None of the hit-registration files (`CombatService.lua`, `LagCompensation.lua`,
`CombatClient.client.lua`, `WeaponService.lua`, `VehicleWeapons.lua`, `VehicleWeaponClient.client.lua`,
`RangeService.lua`, the three hitreg tools) changed between 82968cb and 7ddeb4a
(`git diff --stat 82968cb 7ddeb4a` on those paths is empty). What each one does to the findings is covered
in section 6.

## Short answer

1. **Yes, both original faults are fixed on main, and they landed together.** They landed in one commit,
   **1e964ca** (09-22, "Fleet work, 2026-09-21 19:08 to 2026-09-22"), not in c102b7d or affa05e. The
   OLIVER_LIST row credits the rewind commits for this.
   - Client: `StarterPlayerScripts/CombatClient.client.lua:727-745`. `lastLocalShot += interval` (:741)
     replaced `lastLocalShot = now` (741042c :617).
   - Server: `ServerScriptService/Modules/CombatService.lua:1051-1065` (`FIRE_BURST = 2`, `ShotCredit`,
     `SpendShot`), called at :1101-1105 and :1118. This replaced `if now - loadout.lastShotAt < interval * 0.9
     then return end` (741042c :663-666).
   - Main's client gate and server budget are byte-identical to 1e964ca's. The only change since is an aim
     check moved ahead of `ConsumeAmmo`.
   - Measured, 5 ms mean network jitter, all 44 fire rates: main drops **0 of 13,076 shots** at every frame
     rate. Before the fix, 1.41% (30 fps) to 7.22% (240 fps) were dropped, and up to 29% on the worst gun.
2. **The rewind's own proof reproduces.** At c102b7d it gives 25 checks, 0 failed, and 11 of 11 plants
   caught. On main it gives 27 checks and 13 of 13. The plants are aimed at invariants. I planted 10
   faults of my own. The check catches 8. Two slip through because its victim only ever moves in a
   straight line and never turns. With a harness variant where the victim A-D strafes and turns, all 10
   are caught, and the unplanted module passes 8 of 8.
3. **The rewind's core is correct. Its gaps are at the edges:**
   - It uses one clock, and it uses GetNetworkPing as the round trip it is documented to be.
   - The interpolation, the ring depth, the cap, the headshot path and the shotgun path are all right.
     471149c's in-place writes can't tear.
   - There are four findings, below. The biggest (reasoning, not measured) is that the rewind leaves out
     Roblox's interpolation delay, so it likely still rules shots late.
4. **The live probe is not ready.** As written it would print nothing and report "ping unavailable". The
   reason is in section 5.

## 1. The two original faults on main

### Where the code is

| | Before (741042c) | Main (7ddeb4a) |
|---|---|---|
| Client, `CombatClient.client.lua` | :614 `if now - lastLocalShot < 1 / def.fireRate then return end`, :617 `lastLocalShot = now`: resets on the frame it fires, so the rate is quantised down to the frame rate | :728 `if now - lastLocalShot < interval`, :741 `lastLocalShot += interval`, :742-745 starts fresh after a hitch longer than one interval |
| Server, `CombatService.lua` | :664 `if now - loadout.lastShotAt < interval * 0.9 then return end`: silent drop, no `BroadcastShot` | :1051 `FIRE_BURST = 2`; :1055-1059 `ShotCredit` refills at exactly `fireRate` up to 2; :1102-1105 refuses at `credit < 1`; :1118 `SpendShot` |

`RangeService.lua:206-212` and `VehicleWeapons.lua:387/407` call the same `ShotCredit`/`SpendShot`.

### Measured: `tools/hitreg_firerate_sim.py`

The sim cuts the real gate code out of each revision with `git show` and runs it in lupa:

- Client: tryFire from `local now = os.clock()` to `local target = aimPoint()`.
- Server: Fire from `local now = os.clock()` to the line that commits the shot, plus `ShotCredit`,
  `SpendShot` and `FIRE_BURST` when the revision has them.

The model:

- The trigger is held for 60 s.
- Client frames run at 30/60/144/240 fps, each ±10% of nominal.
- Each send gets 50 ms plus exponential jitter. Remotes are reliable and ordered, so a packet never
  overtakes the one ahead of it.
- The server handles each remote at the start of the 60 Hz frame after it arrives.
- The magazine never runs dry, so only the rate gate is measured.

Fire rates come from `WeaponData.Weapons`, which the sim loads with its ArsenalExpansion, CreativeArsenal
and WorkshopArsenal packs: **65 guns, 44 distinct fire rates**.

It runs four pairings: before/before, the client fix alone, the server fix alone, and main/main.

**Shots dropped as a share of shots sent, all 44 fire rates together.** The worst single gun is in brackets.

| Net jitter (mean) | Pairing | 30 fps | 60 fps | 144 fps | 240 fps |
|---|---|---|---|---|---|
| 0 ms | before | 0.26% (5.1%) | 0.67% (4.4%) | 1.83% (15.2%) | 3.00% (25.2%) |
| 0 ms | **main** | **0.00%** | **0.00%** | **0.00%** | **0.00%** |
| 5 ms | before | 1.41% (15.7%) | 3.85% (15.9%) | 5.27% (22.6%) | 7.22% (29.0%) |
| 5 ms | client fix only | 18.99% (38.3%) | 12.17% (35.4%) | 10.74% (36.2%) | 10.47% (35.4%) |
| 5 ms | server fix only | 0.00% | 0.00% | 0.00% | 0.00% |
| 5 ms | **main** | **0.00%** | **0.00%** | **0.00%** | **0.00%** |
| 20 ms | before | 11.20% (27.0%) | 16.31% (29.9%) | 19.63% (33.4%) | 21.13% (34.5%) |
| 20 ms | client fix only | 24.88% | 23.34% | 22.50% | 23.20% |
| 20 ms | **main** | **1.31% (4.6%)** | **0.78% (2.9%)** | **0.65% (2.6%)** | **0.79% (2.7%)** |

**Delivered rate against `fireRate`, zero jitter.** Before the fix the worst gun loses 27.7% at 30 fps
(Glitch SMG, 14/s), 14.3% at 60 fps, 19.2% at 144 fps and 27.2% at 240 fps. On main no gun is more than
0.76% off at any frame rate.

The sim agrees with the project's earlier hand numbers. COORDINATION says the Glitch SMG delivered
"12.00/s at 60 fps (-14.3%) and 10.00/s at 30 fps (-28.6%)". The sim gives -14.3% and -27.7%; the ±10%
frame jitter accounts for the 30 fps difference.

What the numbers say:

- **The masking-bug lesson holds.** The client fix alone is worse than before at every frame rate and
  jitter level: 1.41% becomes 18.99% at 30 fps with 5 ms jitter.
- The server fix alone stops the drops but keeps the quantised rate.
- Only the pair on main gets both right.
- The before drops at 0 ms jitter come from the server's 60 Hz frame: two sends 77 ms apart can be
  handled 66.7 ms apart, which is inside 0.9 × 76.9 ms. That depends on my assumption about when remotes
  are handled, and the report does not rest on it.

**Main is not drop-proof under bad jitter.** At 20 ms mean exponential jitter, the 14/s Glitch SMG still
loses 2.6-4.6%. `FIRE_BURST = 2` absorbs a delay spike of up to about one fire interval (71 ms at 14/s).
A longer spike releases a bunch of queued shots, and the bucket turns away the excess silently. That is
the cost of the chosen burst size, not a bug. Whether 20 ms mean jitter is realistic for Oliver's players
is unknown.

**The sim's checks:** 8 checks, 0 failed.

- Main drops nothing at 0 and 5 ms jitter.
- Main delivers within 2% of `fireRate`.
- A 1 kHz spamming client is held to `fireRate × 10 s + 2` at 14, 4 and 0.75/s.
- The control: before drops 11,470 shots across the grid.
- Main's gates equal 1e964ca's.

**Its planted faults: 4 of 4 caught.** Each is aimed at an invariant, not at the old bug:

- A client that resets to `now` is caught by the delivered-rate row (14.29% off).
- `FIRE_BURST = 1` is caught by the no-drop row (49% drop).
- A budget that never refuses is caught by the spam cap (10,000 accepted against a cap of 142).
- A budget refilling 10% slow is caught by the no-drop row (9.3%).

## 2. The rewind's own proof

`python tools/hitreg_rewind_check.py .`:

- At c102b7d (a `git archive` into /tmp): `hitreg_rewind_check: 25 checks, 0 failed`, and with `--plant`,
  `hitreg_rewind_check plants: 11 of 11 caught`. **The commit message's claim holds.**
- On main: `hitreg_rewind_check: 27 checks, 0 failed` and `hitreg_rewind_check plants: 13 of 13 caught`.
  471149c added 2 rows and 2 plants.

**Are its plants aimed at invariants?** Yes, all 13:

- Rewind direction, the cap, "present, not cap" over the cap, and part-not-victim (headshots).
- No client timestamp is read, and bots are never rewound.
- The shot's filter is respected, hats never swallow headshots, and there is a no-rewind control.
- The ring reuses its tables, and a reused entry takes its new time.
- The budget's burst, and late accessories.

None of them says "the old bug is still there". The control rows (section 2 of its harness) show the
instrument can fail: the same 150/200 ms shots, ruled on the present, miss 2 of 2.

**My plants: `tools/hitreg_rewind_extra_plants.py`.** It breaks `LagCompensation.lua` in memory only and
runs the check's own dynamic rows. It then runs a variant of the check's harness where the victim A-D
strafes (reversing every 0.15 s) and turns at 3 rad/s.

| Plant | The check as written | The variant |
|---|---|---|
| rewind by half the ping (ping read as one-way) | caught | caught |
| walk the ring the wrong way | **MISSED** | caught (0.337 studs off) |
| no interpolation (older sample as-is) | caught (only by the ring-reuse row) | missed |
| interpolation fraction reversed | caught | caught |
| ring shorter than the cap (6 samples) | caught | caught |
| record on a different clock (os.clock) | caught | caught |
| carry composed in the wrong order | **MISSED** | caught (struck LeftUpperArm) |
| boxes tested at the live pose | caught | caught |
| reach too small for the head (1 stud) | caught | caught |
| cap in the wrong unit (200 for 0.2) | caught | missed (the variant keeps only the strafing rows) |

Together the two harnesses catch 10 of 10. The unplanted module passes the variant 8 of 8.

**What the two misses mean for the check.** A victim moving in a straight line at constant speed
interpolates exactly between *any* two samples. A victim who never turns makes `past * now:Inverse()` and
`now:Inverse() * past` the same transform. So the check as written cannot see a ring read in the wrong
order or a carry composed the wrong way round. The code on main has neither fault, as the variant shows.
But the check wouldn't catch a regression in either one. I'd suggest folding a turning, reversing victim
into `hitreg_rewind_check.py`; that is the owner's call. The "no interpolation" plant is caught only
because the ring-reuse row rewinds to half a step; every other row rewinds exactly onto a sample.

## 3. Audit of the rewind: 21 candidates examined

### Findings (bugs and gaps first)

**F1. The rewind probably under-rewinds by Roblox's interpolation delay. This is reasoning, not a
measurement.**

`RewindTime` puts victims back by `GetNetworkPing()` (`LagCompensation.lua:139-149`). Roblox's docs:
"Returns the round-trip, isolated network latency of the player in seconds … It doesn't involve data
deserialization or processing"
([Player:GetNetworkPing](https://create.roblox.com/docs/reference/engine/classes/Player#GetNetworkPing)).
So the code reads the unit and the round trip correctly.

What the shooter saw is older than that. Roblox renders other players' replicated physics behind real
time, so a client can draw them smoothly. A Roblox staff announcement confirms the delay: "the CFrames of
physically simulated parts are delayed and interpolated"
([DevForum 4298561](https://devforum.roblox.com/t/4298561)). **No official number exists.** Community
figures run from about 50 ms to "250-500ms (dynamic)"
([DevForum 4689669](https://devforum.roblox.com/t/4689669/6)).

Two DevForum users measured GetNetworkPing at about half the Shift+F3 ping
([1544599](https://devforum.roblox.com/t/1544599), [3049248](https://devforum.roblox.com/t/3049248/5)).
No staff post explains the gap; the panel likely includes frame and processing time.

At `BaseWalkSpeed` 18, each 50 ms the rewind leaves out is 0.9 studs, against a torso half-width of about
1 stud. So the rewind may recover only part of HITREG_DESIGN's table. The fix is a product and engineering
choice, and I don't pick it:

- (a) Add a fixed allowance.
- (b) Measure the delay live and add it.
- (c) Leave it and accept the remaining miss distance.

Any added allowance also lengthens the cover trade.

**F2. Riders are rewound, but the vehicle they sit in is not. This is reasoning from source, not measured.**

- `LagCompensation.Raycast` rewinds only characters in `Combatants.All()` (`LagCompensation.lua:220-228`).
- A vehicle's body is tested where it is now, by the world ray.
- `VehicleCover.CrossesGlass` also tests the car's present glass (`CombatService.lua:975`).
- Car top speeds are 62-106 studs/s (`VehicleDynamics.lua:71-125`). At 100 ms that is 6-10 studs, about
  a car's length.

So at ordinary pings, a shot at a rider in a moving car finds the rewound rider where the car no longer
is. `CrossesGlass` then says no, the hit is scored "open", and `VehicleCover.Share` returns 1
(`VehicleCover.lua:116`). The rider takes full damage instead of the glass share (0.65 for a car) or the
body share (0.2). Shots at the car body itself get the pre-rewind miss.

Options:

- (a) Rewind vehicles too: record the vehicle root and carry its parts, as for characters.
- (b) Rule seated riders on the present.
- (c) For rewound rider hits, use the directional roll the bots already get (`VehicleCover.Roll`).

Each changes what cover means in a car, so it needs a decision.

**F3. Phantom shots at the end of every magazine, on main.** This isn't one of the two original faults; it
has the same shape and predates them.

- The client never counts its own rounds. `slot.mag` changes only when a server push lands
  (`CombatClient.client.lua:2227`), and tryFire refuses at `slot.mag <= 0` (:713).
- So for about one round trip after the last round, the client keeps sending shots. It also kicks and
  flashes each one locally (`addRecoil`/`kickViewmodel`, :755-756).
- The server refuses those shots at `if not WeaponService.ConsumeAmmo(player) then return end`
  (`CombatService.lua:1115`), with no `BroadcastShot` and no tracer.

Measured in the sim (60 fps, 5 ms jitter, mean of 200 magazines): **phantom shots per magazine**:

| Gun | RTT 50 ms | 100 ms | 150 ms |
|---|---|---|---|
| Glitch SMG (14/s) | 0.67 | 1.08 | 2.00 |
| Patapim Chaingun (13/s) | 0.46 | 1.01 | 1.99 |
| Lag Switch SMG (12/s) | 0.24 | 1.00 | 1.88 |
| Yard Work Blower (10/s) | 0.03 | 1.00 | 1.01 |
| Tralala Thumper (1.4/s) | 0.00 | 0.00 | 0.00 |

The fix would be a client-side count of rounds, predicted locally and corrected by the push. It sits in a
file the build machine owns, so I'm reporting it, not fixing it.

**F4. The vehicle-gun client still has fault 1.** `VehicleWeaponClient.client.lua:564-565`:
`if firing and now - lastShotAt >= 1 / spec.fireRate and ready then lastShotAt = now`. That resets to
`now` on RenderStepped, the pattern 1e964ca removed from hand guns.

The server side uses the new budget, so **no shots are dropped**. But vehicle guns fire slower than
their `fireRate`:

- 10/s guns deliver -14.0% at 30 fps, -7.7% at 60, -3.7% at 144 and -2.0% at 240.
- 9/s guns deliver -16.7% at 30 fps and -4.8% at 60.

The sim models this line by hand and exits if the source text no longer matches it. The fix is the same
three lines as `CombatClient.client.lua:741-745`.

### Checked and clean

1. **Timebase.** `Record` stamps with `LagCompensation.Now()` = `workspace:GetServerTimeNow()` (:67-68,
   :285-287). `RewindTime` gets `arrival` from the same call (`CombatService.lua:1122`, :1019), and so do
   `RootAt` and `Raycast` (:113, :213). One clock throughout. The docs don't say what GetServerTimeNow
   returns on the server
   ([Workspace:GetServerTimeNow](https://create.roblox.com/docs/reference/engine/classes/Workspace#GetServerTimeNow)),
   but since every stamp and every read uses it, only its rate matters. The "record on os.clock" plant is
   caught.
2. **GetNetworkPing's unit and direction.** Seconds, round trip, subtracted from arrival (:148). Correct
   per the docs. F1 is about what the ping leaves out, not how it is used.
3. **Interpolation.** :108-135 walks from the newest sample back to the first one at or before `at`, and
   blends it with the next newer one (or the live root at `now`). It is exact under an A-D strafe and a
   turn (the variant, 0.000 studs at every ping).
4. **Ring walk direction and wrap** (:133): exact on the variant; the reversed walk is caught there.
5. **The 200 ms cap** (:53, :146): over the cap the shot is ruled on the present, not the cap and not an
   extrapolation. Proven by the check's rows and plants.
6. **Ring depth against the cap.** 20 samples at the server's 60 Hz Heartbeat is 19 gaps × 16.7 ms =
   316.7 ms between the oldest and newest sample, plus up to one frame to `now`. That is more than the
   200 ms cap. It would only fall short if Heartbeat ran above 95 Hz, and a Roblox server doesn't.
7. **Bots.** A bot shooter is never rewound (:140). A bot victim IS rewound, which is right: the shooter
   sees a bot through the same replication delay as a player.
8. **Headshots.** The result's `Instance` is the real part (:270-277). The headshot tests read its name
   (`CombatService.lua:966`, and the rider path). The plant is caught.
9. **Shotguns.** Every pellet gets the same `rewindTo` (`CombatService.lua:1146`). So do ricochets
   (firePellet's recursive call) and `riderBehind` (:814). There is one `RewindTime` call per shot (:1122).
10. **471149c's in-place ring writes.** The write `sample.cframe, sample.t = root.CFrame, now` (:92) is a
    single statement with no yield. `RootAt` copies into locals and returns a CFrame, which is an immutable
    value and never the sample table. `Raycast` does not yield between the ring read and its return; the
    Observer gets only the result table. Nothing can hold a sample across a Record, so a torn or aliased
    read is impossible. The "reused entry keeps its old time" plant is caught.
11. **Carry transform** `past * root.CFrame:Inverse()` (:244): exact for a turning victim (the variant).
    The reversed order is caught there.
12. **Reach** = 8 studs (:56), from the rewound root to the ray. The mock rig's farthest part is 3 studs
    out (its Handle). A default Roblox avatar stands about 5 studs tall, so its parts are within about
    3 studs of the root. 8 leaves room for scaled avatars; a 1-stud plant is caught.
13. **Accessories.** They are excluded from the box test by `shootable` (:202-204) and from the world by
    `WatchAccessories`. The two paths agree.
14. **Filter.** A pierced body or teammate put in the filter is excluded from candidates and parts (:217-253).
15. **The first shot after a weapon swap.** The server pushes the loadout right after equip
    (`WeaponService.lua:1848-1849`). The client then extends its raise to the server's remaining time
    (`CombatClient.client.lua:2264`). So the client can't fire before the server's raise has ended unless
    the round trip exceeds `EquipTime` (0.35 s).
16. **Launchers** fly real rounds (ProjectileService) and are not hitscan, so they are rightly not rewound.
17. **The practice range** (`RangeService.lua:227`) raycasts with `workspace:Raycast`, so it is not
    rewound. It shares the budget (:206). I noted this and didn't dig further: range dummies are not
    combatants either way.

That is 21 examined: 4 findings, 17 clean.

### Per-part boxes against real part sizes: not a finding, but a difference to know

The rewound test uses each part's `Size` box (:255). A present-time `workspace:Raycast` tests the part's
collision geometry, and for R15 MeshParts that is a hull or mesh inside that box. So a rewound shot can
land on the corner of a box where the same shot ruled on the present would pass by. Rewound shots are
therefore slightly *more* generous than unrewound ones. On R6 rigs (a Head Part with a SpecialMesh) the
two agree.

The size of this depends on each avatar's CollisionFidelity, and I can't measure that here. The mock rig
in `tools/hitreg_mocks.lua:227-248` uses made-up sizes. The check doesn't depend on exact sizes, and
doesn't claim to.

## 4. Outside-brief findings

- **`COORDINATION.md:560` says "`os.clock()` is process CPU TIME in Roblox, not wall clock". Roblox's
  docs and Luau's source say otherwise.**
  - Docs: "Returns elapsed time in seconds since an arbitrary baseline with sub-microsecond precision …
    adjustments to the system clock … do not cause time to jump"
    ([os.clock](https://create.roblox.com/docs/reference/engine/libraries/os#clock)).
  - Luau's `os_clock` reads `QueryPerformanceCounter` / `mach_absolute_time` / `CLOCK_MONOTONIC`
    ([loslib.cpp](https://github.com/luau-lang/luau/blob/master/VM/src/loslib.cpp),
    [lperf.cpp](https://github.com/luau-lang/luau/blob/master/VM/src/lperf.cpp)).
  - So it is a monotonic wall timer. The lesson underpins `tools/clock_ratchet.py` and the
    CLOCK_WALL_TIME rule. I have not edited COORDINATION.md. Whether the lesson is struck, or re-grounded
    on another reason (os.clock's arbitrary per-process baseline makes it unusable across servers or for
    saved timestamps), is the coordinator's call.
  - For this report: `CombatService.Fire`'s budget runs on `os.clock()` (:1101), and on the documented
    behaviour that is fine.
- **OLIVER_LIST #97's row is stale.** It says "Rewind deliberately unbuilt"; c102b7d built it. It credits
  c102b7d and affa05e; the fire-rate pair is 1e964ca. HITREG_DESIGN.md still opens "Nothing here is
  landed". The cover-trade decision ("option A, shooter wins") is recorded only in
  `coordination/handoffs/cloud-session-2026-09-24.md:44` and the LagCompensation header.
  OLIVER_LIST.md:110 still asks Oliver for it.

## 5. The live probe, `tools/hitreg_rewind_probe.lua`: not ready

**Blocking.** Its header says to paste it into the server's command bar during a play test. Roblox's
docs: "return values from ModuleScripts are independent with regards to Scripts and LocalScripts, and
other environments like the Command Bar"
([ModuleScript](https://create.roblox.com/docs/reference/engine/classes/ModuleScript)).

So the probe's `require(LagCompensation)` (:32) gets a fresh copy. Setting `.Observer` on that copy never
reaches the module `CombatService` uses. Its `RootAt` reads an empty ring. It would print nothing, and
`stop()` would then print "ping unavailable: no shot was rewound", which reads as a network result when
it is a wiring one. This is the same family as COORDINATION's "a plugin's require gets its own module
instance".

To run, it has to be a server **Script** placed in ServerScriptService before pressing Play, so it shares
the game's module cache. That is a small change to the probe, and it belongs to the probe's owner; the
build machine can make it.

**Also needs:**

- A real network gap. In a local Studio test the ping is near 0, so nothing is rewound (`ping <= 0` →
  present) and nothing prints. The probe itself says Studio's Incoming Replication Lag may not show up in
  GetNetworkPing. A team test or a published test place with a remote player is the reliable setup.
- It has no planted fault. For a measurement tool that is defensible, but the "prints nothing" failure
  above shows why it needs a way to tell "no shots" from "not wired". For example, print on install
  whether `LagCompensation.Observer` is still set after `CombatService` has fired once.

**What it would show once running:**

- Real GetNetworkPing values: this settles the "half of Shift+F3" question for Oliver's connection.
- That rewound == ping per shot. It reads the ping a second time, so expect small differences, not
  equality.
- That Head appears among struck parts.
- How far victims moved per hit, meaning how much the rewind made up.

**What it would not show:**

- Whether the rewind went back **far enough** (F1). It never sees what the shooter's screen showed. A
  cheap addition: for each shot, search the ring for the instant the ray passed closest to the struck (or
  nearest) victim's root, and print `(now − that instant) − ping`. A positive median across many shots at
  a strafing target is the interpolation delay the rewind leaves out.
- Anything about feel, and nothing about vehicles (F2), because `shooterAt` only matches a head within
  4 studs of the ray origin, and vehicle-gun rays start at the muzzle.

## 6. The three later commits

- **a549527** (loadout pushes coalesced): `ConsumeAmmo` now calls `PushSoon`, which uses `task.defer`
  (`WeaponService.lua:1879`). The push leaves at the end of the same server frame instead of immediately.
  That delay is well under a frame, so the rate gate is untouched. F3's phantom count depends on it only
  through that sub-frame delay; the sim models the push at the end of the frame.
- **599130d** (infinite ammo pool): only `Reload` changes. The magazine still empties, so F3 still
  applies every magazine. It matters more now, because players never run out of reserve and so empty far
  more magazines. No effect on the rate gate or the rewind.
- **7fab339** (vehicle guns): added `VehicleWeapons` and `VehicleWeaponClient`. The server uses the new
  budget (`VehicleWeapons.lua:387/407`); the client carries F4. affa05e then routed its bullets through
  the rewind (`VehicleWeapons.lua:272`).

## What this does NOT prove

- **Feel.** Nothing here says the game now feels right. That is Oliver's call in a playtest.
- **Real network behaviour.** Ping, jitter, packet loss and Roblox's interpolation delay are swept or
  reasoned about, never measured. The sim's network model (exponential jitter, server handling at 60 Hz
  frame starts, no client-side batching) is mine. The before drops at 0 ms jitter depend on the
  frame-start assumption. The main result (0 drops at 0 and 5 ms, and a few percent on the fastest guns
  at 20 ms) is what I'd expect to survive other reasonable models, but I haven't shown that.
- **F1 and F2 are reasoning.** No number here shows the size of the interpolation delay or of the
  vehicle mismatch in a real session.
- **The rewind's geometry on real avatars.** Every rewind result runs against `tools/hitreg_mocks.lua`'s
  rig and world raycast, not Roblox's.
- **The probe.** I haven't run it, and can't. Its blocking problem is established from Roblox's docs, not
  observed.

## Checks, run from the repo root on main ac22e5e plus this branch's new files

```
python tools/verify.py .            -> OK: no problems
python tools/balance.py .           -> files unbalanced: 0
python tools/lua_static_check.py .  -> lua static check: 437 files, 0 findings
```

Plus: `tools/hitreg_firerate_sim.py`: `hitreg_firerate_sim: 8 checks, 0 failed (44 fire rates, 65 guns)`;
`--plant`: `hitreg_firerate_sim plants: 4 of 4 caught`. `tools/hitreg_rewind_extra_plants.py`: 8 of 10
on the check as written, and 8 of 10 on the variant (10 of 10 together). The unplanted module passes the
variant 8 of 8.
