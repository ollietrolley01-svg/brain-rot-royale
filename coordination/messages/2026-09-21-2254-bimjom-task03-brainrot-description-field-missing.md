FROM: bimjom (Jacob Shadowen / snodes, outside clone)
ABOUT: task 03 — codex and flavour text
NEEDS: answer
BY:    blocking — no codex text can be written until this is settled

## The brief targets a field that does not exist

`tasks/claimed/03-codex-and-flavour-text.md` asks us to rewrite every brainrot's description, keep
the lines that are already good, and find the real UI length limit in the menu code. All three
assume a field that is not on this tree:

- `ReplicatedStorage/Shared/BrainrotData.lua` has exactly **seven** `description` mentions. Six are
  companion attacks (`"Fires a glob at one enemy"`), the seventh is the passthrough at line 446.
  **No brainrot entry has a description or flavour-text field.** Verified on `main`, on
  `origin/main`, and on every local branch.
- The codex UI (`StarterPlayerScripts/MenuClient.client.lua`, `codexRow` at line 363) renders a
  60px row: name, a one-line 12px subtitle reading `RARITY • from X crates` /
  `RARITY • N coins each` with `TextTruncate` AtEnd, and OWNED / NOT FOUND. **No label reads any
  per-brainrot text**, so there is no real length constraint in source to quote.
- `grep` finds no flavour, lore or blurb text for brainrots anywhere else in the repo.

So "rewrite the existing descriptions and keep the good ones" has nothing to rewrite or keep, and
doing the task as written means adding a new field to all 126 entries.

## Why we did not just add it

The brief says the diff must change nothing but text, and that a worker on your machine is
actively editing the structural parts of that same file. Adding a field to 126 entries is a
structural change to every entry, landing in a file someone else is restructuring. That is the one
option we were confident was wrong, so `BrainrotData.lua` is untouched — PR #4 was the claim
commit and nothing else.

## Two questions, neither of which we will answer for you

1. **Is a description field intended on brainrot entries, and is `description` the right field
   name?** If the structural work in flight already adds it, this brief should be re-issued against
   that shape rather than us guessing at it.
2. **A 60px row with a name and a truncated one-line subtitle has no room for a description.**
   Does the codex need a detail panel, or an expanded row? This is a design call, and it decides
   what length the text should be written to, so it has to come before the writing rather than
   after.

## What is ready regardless

Written to the voice the game already has — sampled from the companion attack descriptions, the
crate and gun descriptions, and the `TownKinds.lua` `blurb` fields, which are the closest thing to
codex voice in the repo (`"the copy-paste suburb: every house the same"`):

- a style note recording that voice, written before any drafting
- drafted descriptions for all 126 entries, keyed by id, as a plain Lua table you can drop in once
  the field exists
- the exact before/after for wiring a description into `codexRow`, as a proposal for you to route

These are held outside the repo rather than committed, because committing them means either
touching `BrainrotData.lua` or adding a file the brief does not name. Say which you want and where,
and they land in one commit.

**Caveat, stated plainly:** with no source constraint to read, the drafted text was written to a
pessimistic assumption of 5.2 px per character against the measured row geometry. That figure is an
assumption, not a measurement. If the answer to question 2 changes the row shape, the lengths need
revisiting.
