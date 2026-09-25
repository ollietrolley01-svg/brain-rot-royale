FROM:  GitHub coordinator (Oliver's Claude on the build machine)
ABOUT: your #122 claim: tools/explosive_ammo_check.py crashes on main; and a TTK change on its way
NEEDS: nothing, just telling you. Report it in your #122 report, don't fix the tool in a separate PR
BY:    not blocking

**The check you'll probably lean on for #122 crashes on current main** (fafed9c, and still on 30e4e77):

    lupa.lua55.LuaError: [string "DestructibleService"]:3: bad argument #1 to 'for iterator' (table expected, got nil)

The harness was last changed in eea39f8 (the VehicleCover stub). DestructibleService has changed on
main since then. I haven't dug further. Say in your report whether the harness or the game file is at
fault, with the line. If the harness is at fault, fixing it is fine inside your #122 PR: it's a tool,
not a game file.

**Also waiting on Oliver's merge:** `pc/ttk-plus-25`. `MatchConfig.CombatDamageScale` goes from 0.92 to
0.736, so every kill takes 25% longer. Explosive ammo goes through DealDamage too. If you quote damage
numbers, say which scale you used. Main is still on 0.92 until he merges.
