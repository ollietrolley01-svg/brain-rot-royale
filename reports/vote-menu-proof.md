# #107 "the game-choosing menu pulls up randomly mid-match": a proof on current main

Jacob's branch `task/prove-vote-menu`, fast-forwarded to origin/main **fafed9c** before the last run.
Everything here was read from source or run outside Studio (Python + lupa). Nothing ran in Roblox. No
game file and no existing tool was edited. The new tool is `tools/vote_menu_proof.py`, in my branch.

## Verdict

- **On main, I found no path that opens the vote screen (the interactive vote or its winner reveal) or
  the team picker while a match is running.** That covers alive, dead, spectating, respawning in Team
  Deathmatch, back in the lobby after dying, and joining mid-match.
- **The open is guarded by two independent states, and each one is enough on its own:**
  1. **Server:** `VoteService`'s `open` flag is only true in Intermission, Waiting and Countdown. It
     opens at `MatchService.lua:1349` (the break) and `:2234` (a countdown with no vote), and closes
     at `:1796`, just after the Loading broadcast at `:1788-1789`. The only thing that fires
     VoteChanged, `VoteService.lua:151`, never runs during a match: every caller outside Open and Close
     is gated on `open` (`VoteService.lua:283`, `Bootstrap.server.lua:307`), and `CastVote` refuses
     before it broadcasts (`:215`).
  2. **Client:** `VoteReveal.View` (`VoteReveal.lua:89-96`) draws the interactive vote only when the
     match state from MatchChanged is Countdown, or is Intermission or Waiting for a player who is
     Ready. It draws the reveal only in Loading or Countdown, and never over the drop picker. So a
     snapshot that says `open` cannot put the vote over a match by itself.
- **One remaining latent path, for the drop picker, not the vote.** If `startMatch` throws during the
  battle royale's drop window, `dropSelect` is never cleared. The failed-start fallback
  (`MatchService.lua:2273-2296`) doesn't reset it, and the client's picker gate
  (`VoteDropClient.client.lua:294`) checks only `dropSelect` and Ready, not the match state. So the
  drop picker opens over the lobby and then over **every following Team Deathmatch or King of the Hill
  match, during live play**, for every Ready player. It stays until the next battle royale's drop
  window clears the flag. The harness reproduces this from the real code (section 4). **I don't think
  it's reachable in normal play**: the throw has to come from `broadcast()` itself, and I found nothing
  that makes it throw (section 4). Details and the exact sequence are below.
- **The failed-start close from 81c1263 no longer guards anything for #107.** With that line removed,
  all 168 throw points and the hostile replay still give 0 violations. Its only visible effect is a
  zero-length winner reveal for a match that never started (section 4).
- Every number in this report comes from `python3 tools/vote_menu_proof.py .` on fafed9c unless it
  says otherwise.

## 1. Every open path, and what guards it

**13 client paths examined** (11 live, 2 disabled), and every server emitter that feeds them.

| # | Client path (file:line) | What it opens | Client guard | Server feed and its guard |
|---|---|---|---|---|
| 1 | `VoteDropClient.client.lua:191-218` VoteChanged handler, then `renderVote` (`:146`, `:160`) | interactive vote | `View`: snapshot `open` **and** state Countdown, or Intermission/Waiting + Ready; stands aside if another menu holds the cursor | `VoteService.lua:151`, reached from Open (`:197`), Close (`:204`), CastVote (`:226`, only while open, `:215`), Forget (`:284`, gated `if open` at `:283`), Bootstrap join (`Bootstrap.server.lua:307-309`, gated `IsOpen()`) |
| 2 | same handler, `VoteReveal.ShouldReveal` (`VoteReveal.lua:48-66`) | winner reveal (3 s) | the client must have **watched** open go to closed-with-winner; then `View`: state Loading/Countdown and not `dropSelect` | Close only: `MatchService.lua:1796` (after the Loading broadcast at `:1789`) and `:2288` (failed start) |
| 3 | `VoteDropClient.client.lua:306-310` MatchChanged, then `renderVote` | either face | same `View` | `broadcast()` `MatchService.lua:350-375`, 21 call sites |
| 4 | `:220` Ready attribute changed, then `renderVote` | interactive vote (lobby only) | same `View` | `MatchService.SetReady` `:381-399`, which refuses Ready during Loading (`:391-393`) |
| 5 | `:223` MenuOpen changed, then `renderVote` | the vote coming back after a menu closes | same `View` | client-side |
| 6 | `:208-213` reveal timer | nothing (it only ends the reveal) | n/a | n/a |
| 7 | `:293-310` MatchChanged, then `updateDrop` | **drop picker** | `dropSelect == true and Ready` **(no match-state check)** | `dropSelect` set at `MatchService.lua:1872`, cleared at `:1891`, inside Loading |
| 8 | `:228-251` keys 1-3 | nothing opens; casts a vote | `View(...)` must say open | CastVote validates server-side |
| 9 | `TeamPickerClient.client.lua:200-206` TeamPickerChanged, then `sync` | team picker | `isOpen` (`:128-140`): snapshot open, a team mode, **and** state Loading with a matching mode | `TeamPicker.lua:52-54` FireClient, to match members only (`:154-160`), from Open, Pick, Forget (gated `if open`, `:243`), Close, and a Pick refusal (only while open, `:190`) |
| 10 | `TeamPickerClient.client.lua:208-218` MatchChanged, then `sync` | team picker | same `isOpen` | as 3 |
| 11 | `:256-261` viewport change | re-shows only if already shown | `screen.shown` | n/a |
| 12 | `HudClient.client.lua:3675`, `:4527`, then legacy `renderVote` | old vote panel | **forced off**: `votePanel.Visible = false` at `:3645`, then return | n/a |
| 13 | `HudClient.client.lua:4505`, then `Drop.update` | old drop screen | **forced off**: `local active = false` at `:2293` | n/a |

No other client script listens to VoteChanged or TeamPickerChanged (grep over StarterPlayerScripts,
StarterGui, ReplicatedStorage). Nothing in `GameMode.lua` (respawns, team-mode deaths) touches
VoteService, TeamPicker or `dropSelect`. MatchService has one match at a time: `state` is a single
server value (`MatchService.lua:54`), and a lobby player sees the same InProgress state as a player in
the match.

**Which state guards the open, the coordinator's question:** the interactive vote needs both the
server's `open` flag and the client's MatchChanged `state`, with the player's `Ready` attribute also
required in Intermission and Waiting. The reveal needs an open-to-closed transition the client
watched, plus the Loading or Countdown state. The team picker needs its snapshot's `open`, and the
state Loading with the same mode. The drop picker needs `dropSelect` and `Ready`, and nothing else.

## 2. Races and ordering

- **Late remote after the match started.** The only VoteChanged the server sends near the start is the
  Close, and it is sent **after** the Loading broadcast (`MatchService.lua:1788-1789` then `:1796`).
  State goes out before the announcement. If the two ever arrived swapped, the reveal would start while
  the client still says Countdown, which `View` allows, and it would end with its timer. Measured:
  100 cross-channel swap variants (every adjacent pair of messages on two different remotes or the Ready
  attribute, for all 5 clients), **0 violations**. Roblox only documents ordering within a single
  RemoteEvent. Across two remotes it's staff wording ("sent reliably and ordered"), not a written
  guarantee, so the swaps are the conservative case.
- **Joining mid-match.** Bootstrap re-broadcasts the vote only while it's open (`Bootstrap.server.lua:307`).
  A joiner's client starts at `state = "Waiting"`, vote closed (`VoteDropClient.client.lua:58-59`), and
  keeps that belief until its first MatchChanged. During that gap nothing can open, because no open
  snapshot is ever sent in a match, and a first snapshot with no previous one never reveals
  (`VoteReveal.lua:60-62`). Measured: real joiners J (battle royale) and K (Team Deathmatch) had 0
  violations. The late-join variants (A's stream started at each of 173 points) also had **0**.
- **A vote for a different group on the same server.** It can't happen: the server runs one match
  and one vote at a time, and the vote is closed for the whole match. Measured: B, back in the lobby,
  votes 14 s into the battle royale and the server answers `Voting is closed.` (the scenario timeline).
- **Failed start (81c1263).** See section 4: 115 failed starts driven through the real fallback, and
  none puts the vote or the team picker over a match.
- **Respawning in a team mode.** The client scripts live in StarterPlayerScripts with
  `ResetOnSpawn = false` (`VoteDropClient.client.lua:51`, `TeamPickerClient.client.lua:43`), so a
  respawn reruns nothing. The only thing a respawn sends is MatchChanged with state InProgress.
  Measured in the scenario (A dies and respawns in Team Deathmatch): 0 violations.
- **Spectator exit (a2ba3b4).** The real `LeaveSpectate` ran (it returned true) and sends only
  Spectate and LoadCharacter, nothing the vote listens to. 0 violations for B.
- **Dying and going back to the lobby mid-match.** B dies, leaves spectating, un-readies and re-readies
  (which exercises the Forget path, gated on `open`), and votes. L, never in the match, readies
  mid-match. 0 violations.
- **Announce-before-state, the class to check.** In three places a message goes out before the
  state it depends on:
  1. The fresh-server countdown opens the vote (`:2234`) before broadcasting Countdown (`:2237`). The
     client still says Waiting, a lobby state, so this is harmless.
  2. The failed-start fallback closes the vote (`:2288`) before broadcasting Waiting (`:2298`).
     Measured effect: the winner reveal of a match that never started can be drawn for 0.00 s of
     virtual time, in 41 of the 168 throw runs.
  3. The same ordering leaves a drop picker up for one message after a failed start that threw at
     the window's last broadcast (points 72-74, 2 client moments at 0.00 s).

  None of the three is in a match.
- **Attributes against remotes.** Only `Ready` is read, and it only affects lobby faces and the drop
  picker. A Roblox staff post says attribute ordering against remotes is not guaranteed under
  NextGenerationReplication. `build_place.py` and `default.project.json` don't set that property, so
  I don't know its value in the published place.

## 3. What the harness runs, and how far it can be trusted

`tools/vote_menu_proof.py` (new, in my branch) runs the **real** code under lupa:

- **Server:** `VoteService.lua` and `TeamPicker.lua` whole, with the real `GameModes`, `Rarity`,
  `MatchConfig` and `TeamPickerRules`. From MatchService's own text it cuts `isReady`, `readyPlayers`,
  `countKeys`, `broadcast`, `SetReady`, `IsSpectating`, `LeaveSpectate`, the whole of `startMatch`, the
  whole body of `Start`'s 1 s loop (the failed-start fallback included), and the Results-to-Intermission
  step. It also cuts Bootstrap's join-time re-broadcast. Every other service is an auto-stub that
  returns nil.
- **Client:** `VoteDropClient.client.lua` and `TeamPickerClient.client.lua` whole, with the real
  `VoteReveal`, `VoteCursor`, `GameModes`, `TeamPickerRules` and `MenuOpenClaims`. The three screens are
  recording mocks that copy the real visibility lines (`VoteScreen.lua:217`, `DropPicker.lua` SetVisible,
  `TeamPickerScreen.lua` Show/Hide). A shape guard fails the run if those lines change.
- **Scenario:** A and B ready up on a fresh server and vote battle royale. In the match, B dies, leaves
  spectating, re-readies and votes; J joins; L readies. The match ends and the break reopens the vote.
  Everyone votes Team Deathmatch, the team picker runs (A picks side 1, B side 2, L stays on AUTO), A
  dies and respawns, K joins, and the match ends into the next countdown. That's 188 messages on the
  wire (156 MatchChanged, 13 VoteChanged, 12 TeamPickerChanged, 7 Ready), 191 loop ticks and 2 matches.
- **Invariants.** On the client: V1, the vote screen (either face) never drawn in InProgress or
  Results; V2, the drop picker drawn only in Loading and only for a participant; V3, the same for the
  team picker. On the server: S1, the vote never open in a match; S2-S4, `dropSelect`, the team picker
  and `teamSelect` only in Loading; S5, no VoteChanged or TeamPickerChanged fired in a match.

Results on fafed9c, verbatim:
```
clean, in order: 5 clients, 702 client moments examined; drawn: interactive vote 358, reveal 14, drop picker 34, team picker 45; 0 V violations, 0 S violations
hostile (client guards alone): 912 client moments, 0 V violations
cross-channel swaps: 100 variants (every adjacent pair on two channels, every client), 0 with a V violation
late joins: 173 variants (A's stream started at every message), 0 with a V violation
```
The drawn counts are there so a pass can't be vacuous: every face was on screen somewhere legitimate.
The **hostile** replay tests the client on its own. At each of the client's moments while the server
is InProgress or Results, it hands the client a late copy of an open vote snapshot, a fresh
open-to-closed transition with a winner, and an open team-picker snapshot, none of which the server
ever sends in a match. The client drew none of them.

**Planted faults** (permanent, in the tool, applied to the real source in memory, aimed at the
invariants). **9/9 caught**:
```
planted fault 'client: the vote drawn whatever the match state (VoteReveal.View)': CAUGHT (V1 A t=31.00 server=InProgress: the interactive vote is drawn (hostile: a late open vote snapshot))
planted fault 'client: the winner reveal allowed over a running match (VoteReveal.View)': CAUGHT (V1 A t=31.00 server=InProgress: the winner reveal is drawn (hostile: an open->closed transition with a winner))
planted fault 'client: VoteDropClient bypasses View for the open face': CAUGHT (V1 A t=31.00 server=InProgress: the interactive vote is drawn (hostile: a late open vote snapshot))
planted fault 'client: the team picker's match-state gate removed (TeamPickerClient.isOpen)': CAUGHT (V3 A t=141.50 server=InProgress: the team picker is drawn (hostile: an open team-picker snapshot))
planted fault 'server: startMatch no longer closes the vote': CAUGHT (S1 t=31.00 state=InProgress: the vote is open (send MatchChanged))
planted fault 'server: Bootstrap re-broadcasts the vote on every join': CAUGHT (S5 t=46.00 state=InProgress: VoteChanged fired during a match)
planted fault 'server: the drop window never clears dropSelect': CAUGHT (S2 t=31.00 state=InProgress: dropSelect is set (send MatchChanged))
planted fault 'server: TeamPicker.Close leaves the window open': CAUGHT (S3 t=141.50 state=InProgress: the team picker is open (send MatchChanged))
planted fault 'the Close broadcast lost (point 12) AND View ungated, real server only': CAUGHT (V1 A t=31.00 server=InProgress: the interactive vote is drawn (MatchChanged))
```
The last row is the two layers together, with only what the real server sent. VoteService's
`announce` swallows a throw, so if the Close broadcast is lost the clients keep an open snapshot for
the whole match. Only the client's state gate then keeps the vote off screen. With that gate removed,
the vote appears over the match.

**My own fault, in a temp copy of the game code** (`/tmp/vmp-copy`, not committed): I added
`InProgress = true` to `LOBBY_VOTE` in `VoteReveal.lua:87`, which is a plausible future edit ("let ready
players vote during the match"). `vote_menu_proof.py` **caught it** (hostile: 32 V1 violations, exit 1).
The existing `tools/vote_open_check.py` **missed it** (`vote_open_check: OK`, exit 0; section 5).

## 4. The throw sweep: failed starts, and the one remaining path

Every stubbed call and every remote send inside `startMatch` is an injection point: **168 points
across both matches**. The scenario is re-run once per point, with that one call throwing.
```
throw sweep: 168 injection points inside startMatch (both matches)
  115 of 168 throws became a failed start (the rest are swallowed by a pcall); 51 broke an invariant; 0 killed the 1 s loop
  info: 41 failed starts drew the winner reveal after the server was back in the lobby (a winner for a match that never started); longest on screen 0.00 s of virtual time, points 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15
  FINDING points 24-71 (48 points: BotService.Count(), MatchChanged:FireAllClients, MatchEvents.Describe()): 323 S + 379 V violations each; first: S2 t=16.00 state=Waiting: dropSelect is set (send VoteChanged)
  FINDING points 72-74 (3 points: BotService.Count(), MatchChanged:FireAllClients, MatchEvents.Describe()): 0 S + 2 V violations each; first: V2 A t=31.00 server=Waiting: the drop picker is drawn for a non-participant (VoteChanged)
```
- **Failed starts at every point outside the drop window (117 points, 64 of which became a failed start), including before and after
  `VoteService.Close()`, the map build, the team picker and ModeTeams.SetPicks: 0 violations.** A lost
  vote-close broadcast (points 12 and 95) or team-picker broadcast (107-109, 113-115, 119-121, 153-155)
  is also covered: the client's match-state gates hide the stale open snapshot.
- **The remaining path: points 24-71 are the three calls inside `broadcast()` (`BotService.Count()`,
  `MatchEvents.Describe()` and `FireAllClients`) at each of the drop window's 16 per-second broadcasts.**
  Exact sequence (`--trace 24` prints it):
  1. Battle royale, Loading. `dropSelect = true` (`MatchService.lua:1872`), then `broadcast()` (`:1874`)
     or a per-second `broadcast()` (`:1878`) throws.
  2. `startMatch` unwinds past `dropSelect = false` (`:1891`). The fallback (`:2273-2296`) resets the
     state to Waiting, the tables, the map and the vote, **but not `dropSelect`**. Its `broadcast()`
     (`:2298`) sends `state = "Waiting", dropSelect = true`.
  3. Every Ready client opens the drop picker in the lobby (`VoteDropClient.client.lua:294` checks only
     `dropSelect` and Ready), and it takes the cursor claim.
  4. The next match is Team Deathmatch or King of the Hill. Their `startMatch` never touches
     `dropSelect` (`:1870`, `if currentMode.dropSelect`), so every broadcast of that match carries
     `dropSelect = true`. **The drop picker is drawn over live play** for each Ready participant: A and
     B in the trace, 11 InProgress moments each. It is also drawn for L, a Ready lobby player (7). It
     keeps the MenuOpen claim, which CombatClient reads to stand combat input down.
  5. It clears only at the end of the next battle royale's drop window (`:1891`).
- **Reachability, reasoning not measurement:** the throw has to come from `broadcast()` during the
  drop window. `BotService.Count()` walks `bots` (`BotService.lua:6039-6047`), and the list is empty
  in that window because `BotService.Clear()` runs at `MatchService.lua:1811` and bots spawn after it.
  `MatchEvents.Describe` handles nil safely (`MatchEvents.lua:127-132`). The payload has no mixed
  table (the battle royale's `Broadcast` returns nil). What's left is `FireAllClients` itself. The
  project's own comment says it can throw for a player on the way out (`VoteService.lua:48-49`); a
  community test says it doesn't, and Roblox's docs say nothing either way. So **I don't know of a
  way to reach this in normal play**. It is a missing reset that turns one throw into several matches
  of a picker over live play.
- **Points 72-74** are the broadcast right after the window. This is the one-message lag from the
  close-before-state order in item 2 of section 2's announce-before-state list. It lasts 0.00 s and
  happens in the lobby.
- **81c1263 on current main.** I removed the failure-path `VoteService.Close()` (`MatchService.lua:2288`)
  in memory and re-ran everything. Clean plus hostile gave 0 S and 0 V. The sweep gave 115 failed
  starts and 0 violations outside the drop window, the same as with the line. The failed-start reveal
  rows went from 41 to 0. Since findings C4 (51b9847), an open vote in Waiting is normal lobby
  behaviour, so the line doesn't protect #107 any more. What it still does, by reasoning, is make the
  retry countdown re-open the vote. `Open()` clears the cached `Resolve()` pick
  (`VoteService.lua:195`), so votes cast after a failed start count. Without the line, the retry would
  replay the failed start's cached mode and map.

## 5. Are the existing checks honest?

- **`tools/verify.py` "vote rebroadcast"**: it reads text, it doesn't run code. It examines every
  `VoteService.Broadcast(` call outside VoteService after stripping comments and strings. On main it
  prints `vote rebroadcast: 1 file(s) outside VoteService call Broadcast, 1 call site(s) examined, 0 ungated; planted pair 1/1 caught`.
  **It can fail.** It carries a two-sided planted pair, and it requires Bootstrap's call to be one of
  the sites examined. In a temp copy with Bootstrap's gate removed it flagged it. My tool flagged the
  same copy through S5 (2 VoteChanged fired mid-match) and showed 0 V violations: with today's
  `ShouldReveal` and `View`, that ungated re-broadcast would no longer reach a screen. **What it
  misses:** in a temp copy I kept the gate and added
  `Remotes.Event("VoteChanged"):FireAllClients(VoteService.Snapshot())` under it. verify.py said
  `OK: no problems`, and my tool flagged S5. Its scope is one call spelling, not "VoteChanged during a
  match".
- **`tools/vote_open_check.py`**: it runs the real `VoteReveal.lua` (ShouldReveal and View), but the
  client glue is a copy of VoteDropClient's handler, and the six timelines are hand-written, not taken
  from MatchService. It can fail: 5/5 of its own planted faults are caught. Two problems:
  - **None of its timelines sends an open snapshot while a match is running**, so the "interactive
    vote over a match" half of its invariant can never fire. Its "vote ungated by match state" plant
    is caught only by the unready-in-the-lobby clause. It passed the `LOBBY_VOTE += InProgress` fault
    above.
  - **Its `start_failed_before_close` timeline is stale.** Its comment says "nothing closes the vote"
    and cites `MatchService:1562-1585`, but since 81c1263 the fallback does close it (`:2288`), and
    the timeline sends no Close.
- Also run on fafed9c: `vote_ready_check: OK`; `lobby_flow_check: 15 checks, 0 failed`, planted
  9/9 caught.

## 6. For Oliver: product calls, not bugs

- **Should the drop picker have its own match-state gate, and should the failed-start fallback reset
  `dropSelect`?** Either one closes the section 4 path. This is the build machine's call. I haven't
  changed anything.
- **What the report might really be.** Since 51b9847 the vote opens as soon as the break starts, for
  every player whose `Ready` is still set, and nothing clears Ready when a match ends: its only writer
  is `SetReady`, `MatchService.lua:398`. So a player who finishes a match is respawned into the lobby
  with the full vote panel already up. That's the intended design (findings C4), and it isn't
  mid-match. But if players are describing this, the vote showing up "on its own" right after a match
  would fit. Reasoning only, not measured.

## What this does NOT prove

- **Nothing ran in Roblox.** The engine is mocked. Remote ordering, deferred signals and attribute
  replication are modelled, not observed. Cross-channel ordering is covered by the swap variants, but
  only one adjacent swap at a time, not arbitrary reordering or loss.
- **The three screens are mocks.** The logic that decides visibility is real; the drawing isn't.
  Whether a panel looks as if it's over the match is a render question, and renders are the
  coordinator's to run.
- **`finishMatch`'s head and the eliminations are stand-ins** (set Results and broadcast; clear
  `alive` and broadcast). The Results-to-Intermission step, SetReady, LeaveSpectate and all of
  `startMatch` are real. Placement tasks (`task.spawn` inside `startMatch`) are skipped. The team
  picker's picks go through the real `TeamPicker.Pick`; the drop pick is a stand-in for `ChooseDrop`.
- **Only one scenario shape**: 3-5 humans, battle royale and then Team Deathmatch. King of the Hill
  wasn't run; it takes the same `teams`/`respawn` branches as Team Deathmatch in `startMatch`.
- **The throw sweep only injects at calls the harness stubs, plus remote sends.** Throws inside the
  real functions (VoteService, TeamPicker, `readyPlayers`) and a throw in `broadcast()` inside the
  1 s loop itself (outside the pcall, `:2298`, which would kill the loop) weren't injected.
- **Virtual time.** "0.00 s on screen" means the same server step. It says nothing about frames on a
  real client.
- **I haven't proved that the old symptom is gone for players.** I proved the paths I could find
  are closed in source. Proving it for players needs a playtest.
