# Task 14: the gunner's aim turns with the car

**Claimed by Jacob (bimjom), branch `task/gunner-aim-world`.** He started the fix before this brief
was written, so it goes straight into `claimed/`.

**Files the claimant owns:** `StarterPlayerScripts/GunnerView.lua` (`look`, `Update`, `Pure.clampLook`)
and a new check under `tools/`. **Read only:** `VehicleWeaponData.lua`, `VehicleWeapons.lua` (the
server clamps and fires from the aim point it is sent), `VehicleWeaponClient.client.lua`,
`VehicleModels.lua`.

## What was reported

The gunner's aim should stay on the same spot in the world when the car turns. Right now the hull
drags the aim round with it. Jacob relayed this from a 2026-09-25 playtest.

## Where to look

`GunnerView` stores the wanted look as `wantYaw` and `wantPitch` in degrees, **in mount space**, which
means relative to the hull. `look` (about line 490) adds the mouse, stick and touch input to them, and
`Pure.clampLook` holds them inside the arc. `Update` (line 540) follows them with `Pure.follow` and
writes the turret joints. Nothing in that path reads the hull's own rotation, so when the car turns
90 degrees, the turret and the camera turn 90 degrees with it.

The likely fix is to keep the wanted aim as a world direction. Each frame, convert it into mount
space against the hull's frame as it is now (the `rest` frame from `self:frames()`), then clamp it.
The aim sent to the server is already a world point along the barrel (`AimPoint`), so the server
side needs no change. Watch for these cases:

- A mount with less than 180 degrees of yaw pins at its arc edge while the hull turns away. Decide
  whether the stored aim follows the edge or waits there.
- Pitch should hold in the world too, so a car cresting a hill doesn't throw the aim at the sky.
- Mouse input still turns the aim relative to the view, as it does now.

## Conflicts

No unmerged branch touches `GunnerView.lua` (checked 2026-09-25). `pc/lag-bug-sweep`, with
`task/blast-parachuters` and `task/bot-gunner-wait` stacked on it, changes `VehicleWeaponClient`
(`aimPoint`, `swingMount`). That is the code that draws other players' mounts, and it reads the aim
attributes this view produces. Re-read it after the sweep merges. Task 08 changes the driver's aim in
the same client and does not overlap with this one.

## Proof

Offline, with lupa: run the real `GunnerView` look-and-follow maths against a mocked hull frame. Turn
the hull through 90 degrees and 180 degrees with no input, and pitch it 15 degrees. The barrel's
world direction must stay within a stated tolerance of where it started, except where the arc stops
it. Plant a fault aimed at that invariant, for example by dropping the hull-rotation term, and show
it goes red.

**The feel cannot be proven offline.** GunnerView runs from a LocalScript. It needs a Studio **Play**
test with a client, a gunner on a turret, and a driver turning hard. The coordinator runs it, with the
camera on the gunner's view.

Status: fixed in PR #69 (open, awaiting Oliver's merge)
