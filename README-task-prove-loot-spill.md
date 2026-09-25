# task/prove-loot-spill

Cut from main `d1e4f73`, and every run is on that commit. It proves OLIVER_LIST #85: chests and supply
drops put their contents on the ground, not in the inventory. New files only; no game file or existing
tool changed.

- `reports/loot-spill-proof.md`: the proof. For players it holds on main for every container: map,
  team-base, battleground and resettled chests, and the supply crate. The 1 s settle is enforced by the
  server, and nothing opens twice. Findings:
  - Bots open containers straight into their own stock and skip the settle.
  - Pickups stack on one point: the scatter's jitter is whole studs, and a throw over an edge falls back
    onto the chest's own spot.
  - `clearOfWalls` can push a pad into a wall (TowerBase).
  - `Resettle` bypasses the settle and the cap.
  - The battleground's gun spots pile up.
- `tools/loot_spill_proof_check.py`: runs LootService and SupplyDropService whole in lupa, with cuts of
  TeamBattleground's seeding and BotService's `claimConsumable`. It raycasts against the real compound
  and battleground layouts. 33 checks, `--plant` 14/14. Needs lupa and numpy.
- `tools/loot_spill_gallery.lua`: a Studio gallery for the coordinator. It shows how spills look on
  RotRidge's compound, the battleground gallery and a crate, and prints the same measurements. Not run.
