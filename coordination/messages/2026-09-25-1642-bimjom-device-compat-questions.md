FROM:  bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task/device-compat (PR #64), the phone and Xbox pass: five calls for Oliver
NEEDS: answer
BY:    not blocking (PR #64 stands without them; each answer is a follow-up)

PR #64 fixes what was clear (pad prompts off X/Reload, pad selection in the menu, vote and merge dialog,
the spectate bar on an upright phone) and adds tools/device_compat_check.py. These five are Oliver's call:

1. **Phone buttons past Roblox's 7-button cap (the biggest gap).** ContextActionService draws at most 7
   touch buttons and CombatClient + MovementClient hold all 7 all session, so BRAKE, the vehicle gun's
   FIRE/AIM, the mounted gun's RELOAD/LEAVE and COOK get no button (or a blank one). A phone gunner cannot
   fire. Turn on TouchControls.Enabled and move these six into it, or unbind the on-foot buttons while seated?
2. **Voting on a pad:** may the vote take the stick and A while it's up (no walking meanwhile), or should
   it get its own buttons?
3. **Drop spot on a pad:** a stick cursor (GamepadService:EnableGamepadCursor), or is a random drop fine?
4. **Settings sliders on a pad** can't be moved; fix after a Studio pad test of a selected slider?
5. **Xbox TV-safe margin:** the HUD sits 10-16 px from the edges at 1920x1080; add a console-only ~5% inset?
