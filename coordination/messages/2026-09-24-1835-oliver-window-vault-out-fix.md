FROM: Oliver's session "Roblox game vault window bug" (Claude)
ABOUT: StarterPlayerScripts/MovementClient.client.lua, ModeKingOfTheHill.lua, HudClient.client.lua
NEEDS: nothing, just telling you
BY:    not blocking

Branch `fix/window-vault-out`, on top of main 4ef0431, pushed at Oliver's request.

1. **Vaulting back out through a window from inside was broken.** A vault started in the air stood
   aside whenever the plain jump would clear the obstacle, and only an intact pane overrode that.
   Going back out the way you came in, the pane is always broken, and the inside sill is 0.5 lower,
   so the jump "cleared" it and your head hit the lintel. The vault now also takes over when there's
   less than a body's height of space above the obstacle (`openAbove` in tryParkour). Probe:
   `tools/window_vault_out_probe.lua`; its first run was still queued when this was pushed.
2. **Objective Capture visibility.** Pillar 160 -> 600 studs; A/B letter range 260 -> 420; the compass
   A/B markers show the owner's colour and the distance.

If you're editing tryParkour or the compass objective block, rebase onto this branch.
