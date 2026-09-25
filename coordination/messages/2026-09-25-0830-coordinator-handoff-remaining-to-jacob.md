FROM: Oliver (relayed by the PC coordinator tab's Claude)
ABOUT: handoff of the remaining work
NEEDS: you to pick these up
BY:    before the next playtest release

## For Jacob

Oliver's words: **"merge and finish all your work and send the remaining to jacob"**. The PC coordinator tab has
stopped. Everything it finished is on main at a7a6ae8 or later: sound polish, silly explosions, AWD, the team
kit, base-vehicle respawn, the battleground declutter, bots on mounted guns, the rock/fling fix, the crater grid
and Basalt scorch, the failing-checks fixes, and the vehicle visuals/suspension. The items below are what's left.

### 1. Vehicles (landed at a7a6ae8, partly unproven in Studio)
The offline checks pass: build, static 0, verify, parked_car, collision 7/7, aim, axis, stability sim,
team_vehicles, roadkill, ttk, suspension_standard. Still to do:
- **Studio-prove VehicleVisuals.** Wheels sit on the ground, spin matches ground speed, struts end inside the
  body (they used to end mid-air), and the lamps and engine note work. `vehicle_visuals_check.py` and
  `vehicle_awd_check.py` only read a Studio probe log. Run `tools/vehicle_visuals_gallery.lua` and the probes
  with a client, so LocalScripts run (runtest's Run mode runs none).
- **Armored raise to ~3.6 studs, plus load-shared drive within each axle.** Goal: on the rock fields at 65%,
  no Tartaruga or Camelo stall over 1 s across 3 reps. The last measurement was 1–2 stalls of 1–2 s.
- **Seams.** The SahurVan bat and the other tapered tubes show a ring at every joint (radius steps of
  0.06–0.08), which reads as see-through. Taper them smoothly and add a seam invariant to
  vehicle_models_axis_check.
- **SahurVan tail ramp** for the rocky climb (s 184–188); it stalled in 1 of 3 runs.
- **Wreck blast (VehicleWreckFx.OnWreck).** It fires from SetSmoke, which only runs within 320 studs, so a
  distant wreck blasts late, when you walk up to it. Fire it from GetAttributeChangedSignal("Wrecked"). Check
  whether the WIP already fixed this.

### 2. Owned by the "Roblox multi-agent lag optimization" session (pc/lag-bug-sweep)
- pc/teambase-v2: bases v2, access roads, terrain smoothing. It's held for the bug sweep, and that session is
  fixing its findings. The Studio road probe still failed 14 checks: 3 team sides with no access road, 27–47%
  unfairness on 4 of 10 map-seeds, and PatapimPlains seed 7 bots entering off-gateway.
- Base cars: 7 of 12 parked at match start in 1 of 3 runs. The likely cause is that RankBaseAxes has no outer
  limit, so the rear bays land past the arena rule.

### 3. Small follow-ups
- `ExplosiveFx.lua` `SCORCH_SINK = 5` skips deep craters; ~25 would cover them.
- `pc/hitreg-fixes` (not ours) has 2 findings from the sweep:
  - CombatService:995: a rewound shot reads glass instead of body on the armoured cabins, so the rider takes 2.5x
    damage depending on ping.
  - CombatClient:755: a false-empty auto-reload.
- The obby sounds in LobbyService bypass the volume sliders.

### 4. Then
Do the phone and Xbox compatibility pass. Then make a GitHub playtest release, marked **Latest**, not
Pre-release.

Rules Oliver set:
- RAM: at most 70% of free RAM, which is about 3 heavy map checks at once. Only one quality_gate at a time.
- Every Studio test points the camera at the thing under test.
- Pass -PlaceFile with your own build.
- Keep token use low.
