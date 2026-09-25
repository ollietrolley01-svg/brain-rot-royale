FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: claim -- #114 plus eight items from the 0830 and 1000 handoffs; the 1140 pause is over
NEEDS: nothing, just telling you (say so if you'd rather any of these went to someone else)
BY:    not blocking

Jacob is un-pausing. We're taking the nine items below that can be done without Studio, one at a time,
one PR each, in this order. Each fix is cut from `origin/main` unless the fault is only on
`pc/lag-bug-sweep`, and the PR will say which. Oliver reads every diff before it lands, as always.

Items 2-9 edit game files. We read the handoffs ("send the remaining to jacob", 0830; "review, then
fixes", 1000) as Oliver lifting the 03:00 lag-only rule for these items. If that's wrong, say so and
we'll stop at the proof.

1. #114 proof: popup barricade in the team kit, two KOTH objectives (7baed01). Proof only, no game files.
2. `tools/base_vehicle_respawn_check.py` `judge_probe` still assumes 6 slots; it's 7 (1000, section 3).
3. `ExplosiveFx.lua` `SCORCH_SINK = 5` skips deep craters; ~25 (0830, section 3).
4. Blast-brainrot explosions (`ProjectileService.Explode`) still hit parachuters (1000, section 3).
5. `CombatService:995`: a rewound shot reads glass instead of body on armoured cabins (0830, section 3).
6. A bot driving an armed car in battle royale waits up to 25 s for a gunner that can only be a
   player now (1000, section 3; `MatchConfig.BotGunnerWait`, `BotService` ride wait).
7. `CombatClient:755`: a false-empty auto-reload (0830, section 3).
8. Wreck blast: fire `VehicleWreckFx.OnWreck` from the `Wrecked` attribute signal, not `SetSmoke`,
   so a distant wreck doesn't blast late (0830, section 1).
9. The obby sounds in `LobbyService` bypass the volume sliders (0830, section 3).

Not taken, because each needs Studio or a device: the vehicle visuals proof, the armored stalls, the
seams, the SahurVan tail ramp, the bike models and the SahurVan bat, the mounted-weapon sights, the
one-sided wall cracks, the base cars 7/12, the phone/Xbox pass, and the release.
