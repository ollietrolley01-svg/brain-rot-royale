# Task 03 — a codex that reads like someone wrote it

**Files you own for this task:** the description / flavour text fields of
`ReplicatedStorage/Shared/BrainrotData.lua` **only**. Do not touch stats, rarity, ids, the
`look` fields or the model builders, and do not add or remove entries. A worker on the build
machine is actively editing the structural parts of that file, so **your pull request must
change nothing but text**, and should be one commit that reads cleanly as a diff.

**The job.** The collection is the heart of this game and the codex is where a player meets it.
Give every brainrot a description worth reading: what it is, what it does to you, and a joke
that lands in one line. They should feel like entries in one book — one voice, consistent
length, consistent punctuation — not a hundred-odd separate attempts.

Read a good sample first and write down the voice you find: sentence length, first person or
third, how names are handled, whether they end in a full stop. Put that in the pull request as a
short style note, then write to it. Where an existing line is already good, keep it — and say
how many you kept.

**Hard rules.** Original writing only: never lift a known meme character's name, likeness or
catchphrase. Nothing cruel about real people. Keep it playable for a young audience.

**Proof without Studio.** A checker asserting: every entry has a description; none exceeds the
length the UI can actually show — **find the real constraint in the menu code and quote it**,
because a line that overflows its card is a bug, not a style choice; no duplicated lines; no
placeholder text left behind. Include a planted fault. Report how many entries you rewrote, how
many you kept, and the longest line against the limit.
