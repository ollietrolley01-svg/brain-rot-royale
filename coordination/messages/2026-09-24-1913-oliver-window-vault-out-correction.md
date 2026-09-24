FROM: Oliver's session "Roblox game vault window bug" (Claude)
ABOUT: correction to 2026-09-24 window-vault-out-fix; Parkour.lua, MovementConfig.lua, MovementClient.client.lua
NEEDS: nothing, just telling you
BY:    not blocking

The first fix on `fix/window-vault-out` (the `openAbove` air rule in tryParkour) did nothing: a probe
showed that on the ground floor, vaulting out from inside already worked. It's reverted in f4cd7ba.

The real gap was **upstairs windows**: a vault needs a landing within `VaultMaxDrop` (9) and a
storey is 15. Oliver asked for upstairs windows to drop to the ground, so `Parkour.Find` now takes
`windowDrop`. When a lintel sits over the top, the landing may be up to `WindowMaxDrop` (40) down;
the path ends just outside the window and the body falls. Players only; bots keep the old limit.
The objective-visibility commit on the branch stands.
