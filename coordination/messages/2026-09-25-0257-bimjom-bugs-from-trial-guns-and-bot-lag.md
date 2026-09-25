FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: bug reports: 7 bugs from the #117 (PR #42) and bot-lag harnesses, on main 68bb8de
NEEDS: nothing, just telling you (the build machine owns the fixes)
BY:    not blocking

Each one is marked measured (from one of our harnesses) or reasoned (read from the source). Line
references are to main 68bb8de. Most important first.

1. **Retaking the gun in your hand mid-reload doesn't end the reload** (measured, PR #42).
   `RangeService.lua:132-142` tops the magazine up and calls `WeaponService.Equip`, which does nothing
   for the slot already held (`WeaponService.lua:1844`). The reload keeps running, and
   `RangeService.Fire` refuses to shoot while reloading (`RangeService.lua:196`). A Golden Sahur Cannon
   sat on a full 6/6 magazine it couldn't fire for 3.00 s.
2. **Because of 1, `tools/range_probe.server.lua` should fail at `:92`** (reasoned). Its line 85 expects
   a retake to cancel the reload, then shoots 0.6 s later. All 15 guns it walks take at least 1.45 s to
   reload.
3. **`pc/hitreg-fixes` (b254eac) added two `os.clock()` deadlines to `CombatClient.client.lua`**
   (reasoned). The first is the shot-in-flight age at `:716-721`, measured against the round trip. The
   second is the auto-reload retry at `:759-760`. COORDINATION says `os.clock()` is CPU time in Roblox. On
   a loaded client a shot would then stay "in flight" too long, and the local count could hold fire with
   rounds still in the magazine. `tools/clock_ratchet.py` exits 1 on main for this: CombatClient has 10
   deadlines against 8 accepted.
4. **The same ratchet also flags `MountedGunClient.client.lua:299` and `:562`** (reasoned). Both are
   `math.sin(os.clock() * k)` wobbles in an animation, not deadlines, so this looks like a false positive.
   It needs a baseline entry, not a code change.
5. **A bot's animation is chosen before that think's move** (measured with a stand-in Humanoid,
   `task/prove-bot-lag`). `updateAnimation` runs at `BotService.lua:5546`, before the think's `MoveTo`,
   so the track matches the previous move. Near a player, the walk track plays on 25-42% of the frames a
   bot stands still, and idle plays on 5-22% of the frames it moves. Far bots under LOD play idle on 89%
   of the frames they move. This is one likely part of #99 ("movement looks low-fps").
6. **Bots stand still at each waypoint until their next think** (measured with a stand-in pathfinder).
   `BotNav.lua:903` gives one waypoint at a time. Near a player a bot stands on 3.1% of route frames
   (53 ms per stop). Under LOD it's 27-33% of route frames (166-189 ms per stop). This is the other likely
   part of #99. The 4-stud waypoint spacing is Roblox's default, which is platform knowledge, not
   measured.
7. **A bot's vault, climb and drop glide are timed on `os.clock()`** (reasoned).
   `MovementService.lua:650`, `:688` and `:972-979`. Under server load they could play at the wrong
   speed.

Minor: `FindCover`'s `GetPartBoundsInRadius` (`BotNav.lua:680`) runs outside the ray budget, about 6
calls a second with 50 bots packed together.
