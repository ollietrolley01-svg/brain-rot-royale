# Task 16: the gunner's own gun blocks the view when not aiming

**Claimed by Jacob (bimjom), branch `task/gunner-view-clear`.** He started the fix before this brief
was written, so it goes straight into `claimed/`.

**Files the claimant owns:** `StarterPlayerScripts/GunnerView.lua` (the hip view in `Update`, about
lines 575-600). **Read only:** `VehicleModels.lua` (the `GunnerEye` markers), `Viewmodel.lua`,
`VehicleWeaponData.lua`.

## What was reported

At the hip, not aiming down the sight, the gunner's own gun covers too much of the screen. Jacob
relayed this from a 2026-09-25 playtest.

## Where to look

The hip camera sits at the mount's `GunnerEye` marker and looks along the barrel (`hipView`, line 590).
`VehicleModels` places the markers only 1.05-1.62 studs above the turret's yaw or pitch point and
0.25-1.35 studs behind it (lines 2860, 2976, 3065, 3119, 3208). So the eye sits right behind the gun's
receiver and grips, looking straight down it, and the gun fills the lower middle of the view. The arms
on the grips add to it. `GunnerView` hides parts only when scoped in (`scopeParts`, `arms:SetHidden`,
lines 624-631), never at the hip.

Possible fixes, in rough order of how little they change:

- Raise the hip eye in `GunnerView`, or tip the hip view down relative to the barrel, so the gun sits
  lower. This keeps `VehicleModels` untouched.
- Fade parts of the gun at the hip, as the scope's glass is faded now.

Moving the markers in `VehicleModels` is outside this brief's files. Write the exact before/after in
the PR if that turns out to be the fix. The sight ring and the cross must still line up at range, and
`GunnerView`'s header says why they part close in (the eye is above the bore).

## Conflicts

No unmerged branch touches `GunnerView.lua`. `VehicleModels.lua` is changed by `pc/lag-bug-sweep`
(with `task/blast-parachuters` and `task/bot-gunner-wait` stacked on it) and by PR #65, but none of
them change a `GunnerEye` line. Task 14 (`task/gunner-aim-world`) changes `look` and the follow code in
`Update` in the same file. Merge whichever lands first before pushing the other.

## Proof

Offline, the numbers: project the gun's visible parts through the hip camera for each armed model at
the widest field of view (95 degrees), and report how much of the screen they cover before and after,
and whether any of them covers the middle. Plant a fault (the eye moved back down into the receiver)
and show the check goes red.

**Whether the view looks clear cannot be proven offline.** It needs a render. The coordinator runs
`tools/gunner_fp_gallery.lua` (`_fp_rest` and `_fp_swung`) for every armed model, and Oliver judges it.

Status: fixed in PR #70 (open, awaiting Oliver's merge)
