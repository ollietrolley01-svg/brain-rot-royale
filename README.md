# Proof for roadkill

Proof-only branch for the PR from task/roadkill. **Never merge it**: the repo commits no images.

- `roadkill-before-after.gif`: Real Studio physics (Run mode), replayed frame by frame: a bot's Streetfighter at 171 studs/s (1.5x its top speed) into a bot with 100 health and 100 shield. Look at the bars over its head: BEFORE (pc/lag-bug-sweep cf35aa3) both go to 0 and it reads DEAD; AFTER (task/roadkill) the shield goes and health stops at 50, and the body is thrown alive.
