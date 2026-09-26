# Task 27: less clutter in the team bases and the battleground

**Files you own for this task:** `ServerScriptService/Modules/TeamBattleground.lua` (its dressing, not
its layout, spawns, lanes or capture zones) and `tools/team_battleground_check.py`. The bases
(`TeamBaseRuins.lua`) are owned by the lag-bug-sweep session's `pc/teambase-v2`. **Read only:**
`ModeTeams.lua`, `TeamBaseRuins.lua`, `MapGenerator.lua`.

## What was reported

The team bases and battleground have too much clutter, and it is too laggy. Oliver, relayed by Jacob.

## Counts on main today (d1e4f73)

From the checks' own counts:

- **Battleground:** 2,222 parts (`team_battleground_check.py`; 2,214-2,230 across 6 seeds). The largest
  sections are Keep 300, Market 200, ScrapyardCut 190, Pit 156, ScrapYard 142 and Gatehouse 140. It has
  1,281 breakable parts. The check's budget is 900-3,000.
- **Bases:** 701 parts each (`team_base_ruins_check.py`; 679-708 across 25 seeds), 1,402 for the two.
  The largest sections are VehicleYard 141, Perimeter 139, Spawn 128 and SupplyRoom 124.

The coordinator already decluttered the battleground on 09-25 (60829ef): loose props from 554 to 390,
parts from 2,378 to 2,222, with sightlines and cover held. The arena also sits inside a real town, and
those parts count too.

Parts may not be the cause of the lag. Before cutting anything, measure where the frame time goes in a
team match on a client: part count, breakable parts (physics when they break), lights, the swaying
banners and the bots. Say which one it is.

## Default

Start with the battleground's biggest dressing sections, keep every sightline and cover rule the check
holds, and aim for a stated cut (say 25%). Leave the bases until `pc/teambase-v2` merges. That branch
rewrites `TeamBaseRuins.lua` (about 1,500 lines changed), and so does `pc/lag-bug-sweep`.

## Conflicts

`TeamBaseRuins.lua`, `ModeTeams.lua` and `MapGenerator.lua` are changed on `pc/teambase-v2` and
`pc/lag-bug-sweep`. `TeamBattleground.lua` is on no unmerged branch. Post a claim in the mailbox
addressed to the lag-bug-sweep session before starting. Oliver's 03:00 rule allows game-file edits for
lag work, one change per PR, with before and after numbers.

## Proof

Offline: the parts, sections and breakable counts from `team_battleground_check.py`, before and after,
over its seeds. The sightline and cover lines must still pass, and its planted faults must still fire.

Lag: a Studio **Play** test with a client in a team match with bots, reporting the frame time and
physics step time over a minute before and after, over 3 reps. The coordinator runs it. Oliver judges
whether it looks bare.

Status: ready to start on the battleground; the bases half is waiting on pc/teambase-v2 merging
