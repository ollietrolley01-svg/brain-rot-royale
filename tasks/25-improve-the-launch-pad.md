# Task 25: improve the Launch Pad

**Files you own for this task:** `MovementService.deployPad` (line 172) and its `PAD_*` constants
(lines 56-59), the `LaunchPad` entry in `ItemData.lua` (line 92), and a new check under `tools/`.
**Read only:** `MovementClient.client.lua`, `MovementSanity.lua`, `ItemModels.lua`, `BotService.lua`.

## What was asked for

Oliver first said "get rid of it or improve it", then "improve it". Relayed by Jacob.

## What it is now

The Launch Pad is an Uncommon movement item, 2 to a stack. Using it drops a 7-stud pad on the ground 6
studs ahead of the player. For 30 s (`PAD_LIFETIME`), anyone who touches it is thrown 135 studs a
second up and 38 forward (`PAD_UP`, `PAD_FORWARD`), about 46 studs high, with a 1.2 s cooldown per
body. The throw goes the way the pad faces, turned by a player's client toward where they are running.

Likely reasons it feels bad, to check rather than assume:

- Using it doesn't move you. You have to walk 6 studs forward onto it, so it is slower than a Rot
  Rocket, which launches at once.
- It launches enemies as readily as the owner, and nothing marks whose pad it is.
- No bot ever uses it (`BotService` has no Launch Pad code).
- The 6-studs-ahead drop can land on a roof, a slope or a ledge, since the ground ray starts 4 studs up.

## Default

Deploy the pad under the player's feet and launch them at once. The pad then stays for 30 s for anyone
else, including teammates, to use. Show whose pad it is with the team colour in team modes. Leave the
launch strength alone unless a measurement says otherwise. Bot use is out of scope here. Say in the PR
what bots would need.

## Conflicts

`pc/lag-bug-sweep` changes `MovementService` (the Rot Rocket now goes through `launchCharacter`, next to
the `LaunchPad` branch at line 727, plus `bounceBoots` and `TryParkour`). Merge main before pushing.
Oliver's 03:00 rule applies to game-file edits.

## Proof

Offline, with lupa: run the real `deployPad` and the `MovementEffect` branch against a mocked character
and ground. Show that the owner leaves the ground within one frame of use, and that a second body on
the pad later is thrown. Show the pad never sits on a surface more than a stated height from the
owner's feet. Plant a fault aimed at an invariant (a pad never spawns inside a wall or over water) and
show it goes red.

**The feel cannot be proven offline.** It needs a Studio **Play** test with a client using the pad on
flat ground, a slope and next to a wall. The coordinator runs it, and Oliver judges it.

Status: ready to start
