# Task 10: the elbow looks wrong on longer guns

**Files you own for this task:** `StarterPlayerScripts/GunPoseClient.client.lua` (the third-person arm
pose) and `tools/fps_arms_body_check.py`. **Read only:** `StarterPlayerScripts/Viewmodel.lua` (the
first-person arms; GunPoseClient reads its reload tables, so a change there moves both views),
`GunModels.lua`, `WeaponService.MountGun`.

## What Oliver saw

"elbow animation looks messed up for longer guns". Playtest, 2026-09-25.

## First: which view

He doesn't say whether it's first person or third person, and they are different code. Ask him
through the mailbox which view, and which gun, before changing anything. A screenshot would be better.

- **First person** is `Viewmodel.lua`. It solves each arm as two bones reaching the hand, brings the
  shoulder forward for long guns (`REACH_COMFORT`, `SHOULDER_TRAVEL`), and swings the elbow toward a
  straight wrist (`WRIST_FOLLOW`, `ELBOW_CEILING`). `tools/fps_arms_check.py` already holds joints,
  stretch and wrist bend on all 62 guns, so a fault here would have to be something that check does
  not measure.
- **Third person** is `GunPoseClient.client.lua`, and it is the likely one. The held pose uses one
  fixed set of angles for every gun (`RIGHT_SHOULDER`, `LEFT_SHOULDER`, `RIGHT_ELBOW`, `LEFT_ELBOW`,
  lines 29-33). The left hand never reaches for the gun's `SupportHand` keypoint, and a longer gun
  puts that keypoint further forward. The aimed pose (`aimPoseFor`, `reachTo`) keeps "whatever
  relation the held pose gives", so it carries the same gap up to the eye line.
  `fps_arms_body_check.py`'s own docstring records this: "The held pose's fixed angles leave hands
  short of their keypoints anyway, 0.4 studs and more on some guns; that is not this check's to
  judge."

## Conflicts

No unmerged branch touches `GunPoseClient.client.lua`, `Viewmodel.lua` or
`fps_arms_body_check.py` (checked against `git branch -r` on 2026-09-25).

## Proof

The numbers can be proven offline. `fps_arms_body_check.py` already runs the real GunPoseClient on a
mock R15 with each gun's real model. Add an invariant: in the held pose, the sprint pose and the
aimed pose, each hand is within a stated distance of its keypoint on every gun. Report the worst
case per gun, sorted by gun length, before and after. Plant a fault on the invariant.

**The look cannot be proven offline.** "The elbow looks right" is a picture, and GunPoseClient is a
LocalScript, so a gallery cannot require it and runtest's Run mode does not run it. It needs a Studio
**Play** test with a client, looking at another body (a bot will do) holding the three longest guns
at the hip, aimed and sprinting. The coordinator runs it, with the camera on the arms. Oliver judges
the result.
