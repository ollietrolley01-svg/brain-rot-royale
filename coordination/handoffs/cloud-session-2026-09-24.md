STATUS: IN PROGRESS (cloud session still landing work; wait for ALL DONE)

# Handoff: cloud session (Oliver's "do the tasks" run), 2026-09-24

Written by the cloud Claude session for a Claude tab on Oliver's PC. Read this, then `git fetch` and
work from branch `claude/roblox-game-tasks-wv7n8k`.

## Where things are
- **main** has PRs #15, #16, #17 (big OLIVER_LIST sweep, vehicle poles/bat, menu/kill anims/sound/roadkill/eggs)
  plus Oliver's review-session PRs up to #22.
- **claude/roblox-game-tasks-wv7n8k** is ahead of main with everything since (not merged yet on purpose
  until the 4 urgent fixes below are confirmed in a playtest). Oliver's instruction: merge to main when
  everything is done; build a final playtest; publish it as an update to his Roblox game.
- Offline proof: every feature has a lupa harness in `tools/*_check.py` / `*_sim.py` (pip install lupa).
  A single gate `tools/quality_gate.py` is being written (may land later). Repo checks: balance.py,
  lua_static_check.py, verify.py.

## Needs Oliver's machine (Studio) NOW
1. Playtest the latest build (`python build_place.py .` then open BrainRotRoyale.rbxlx). Confirm the 4
   urgent fixes: (a) first-person viewmodel shows with an R15 avatar (Viewmodel.lua LookOf no longer reads
   MeshId), (b) bots/other players animate (GunPoseClient only poses while aiming; bots back on
   WeldConstraint gun mounts), (c) supply-drop spill stays on the ground (1 s settle), (d) BR death drops
   appear — if not, run `tools/death_drop_probe.lua` in the server command bar during a BR match.
2. If all good: open a PR from the branch to main and merge (merge commits, as before).
3. Publish: `powershell -ExecutionPolicy Bypass -File tools/publish.ps1 -UniverseId <id> -PlaceId <id>`
   with `$env:ROBLOX_API_KEY` set (Open Cloud, Place Management: Write). The cloud session can't (network
   blocks apis.roblox.com, no key).
4. Galleries/probes worth running (each prints its own numbers): vehicle_stability_probe, hitreg_rewind_probe,
   perf_tick_probe, bot_aggression_ab, team_base_ruins_gallery (vehicle overlaps and hovering parts must be 0),
   crack_gallery, destruct_gallery, car_placement_gallery, vehicle_weapons_gallery, menu_screens_gallery,
   killanim_gallery, fps_arms_gallery, eggs_gallery.

## Still running in the cloud session (they finish and push to the branch on their own)
Building foundations/placement audit · bots drive all vehicles + gunner seat + player takeover · death effects
(15 effects + DEATH EFFECTS shop with live previews) · central team battleground · gun rework (20-30 guns: new
models + signature animations via Viewmodel `Flair`; signature effects on Epic+; 3-4 new guns) · brainrot
ability animations/VFX · roads audit (flush + connected) · quality gate + findings · foliage spread ·
team-mode rewards · companion one-shot cap by rarity (Secret exempt) · bot archetypes (fighting incl. per-gun,
throwables, defenses) · bot looting/rotation · bot optimization · defense placement anywhere.
If the cloud session ends before they land, their commits are on local worktree branches only and are lost:
check the branch history, and re-request any missing item from this list.

## Oliver's standing decisions (from this session)
Hitreg: option A, shooter wins. Shotgun nerf: no. Explosive ammo: small blast (Golden Sahur Cannon only).
Barricade click-to-place: not now (but "placement anywhere" is being built). Bot idle wander: parked.
Tom pearl: dropped. Bigger maps: no. Team arena: slightly smaller (done). Codex: A-Z. Controls legend: removed.
Storm text: "YOU'RE IN THE ROT - GET BACK IN". Lean: removed. Crosshair range greying: removed.
Every kerbside car is a real design (DETAILED_CARS_PER_TOWN = math.huge; watch part budget).
