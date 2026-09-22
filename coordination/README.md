> ## Hello from Oliver
>
> Oliver owns this game. He asked us to pass this on, in his words: **"tell jacob to pick up more
> tasks, and tell him i said hello."** He has been reading the pull requests as they come in.
>
> Three heavier tasks are open in `tasks/`: 05, 06 and 07. Take whichever you like.

# The mailbox

There is no live channel between the Claude on this machine (**claude-43**, the coordinator) and
a Claude working on a clone. Different machines, different accounts, no shared process. What we
have instead is this repository, so we use it as the channel deliberately rather than pretending
a conversation is happening.

**The rule that makes it work: one message is one new file.** Never edit someone else's message,
and never append to a shared message file. Two people appending to one file is a merge conflict
every single time; two people adding differently-named files is never a conflict. This costs you
nothing and it is the whole reason the mailbox is a directory.

## Writing a message

Create `coordination/messages/YYYY-MM-DD-HHMM-<who>-<subject>.md`, commit it on your branch, and
push. Example: `2026-09-22-0930-bimjom-task01-triage-question.md`.

Start the file with these four lines, then write whatever you need:

```
FROM: <your name>
ABOUT: <task id, file, or "general">
NEEDS: <answer | review | nothing, just telling you>
BY:    <when this blocks you, or "not blocking">
```

`NEEDS` matters more than it looks. A question that blocks you gets answered first. A report that
needs nothing gets read but does not stall behind a decision.

## Reading replies

claude-43 replies as a new file in the same directory. Pull before you start work, every time:
the answer to something you asked may be sitting there, and so may a note saying the file you
were about to touch now has an owner.

## What claude-43 keeps current

`coordination/STATUS.md` — what is claimed, what is free, and what changed since you last looked.
**Read it before you pick anything up.** A task in `tasks/` that STATUS says is claimed is claimed,
and the task file will not have been updated.

## What to send without being asked

- **Before you start a task**, a one-liner saying which one. That is what stops two people
  building the same thing, and it is the single most valuable message in this directory.
- **A question about intent**, the moment you have one. Guessing what Oliver wants and building it
  is how work gets thrown away here. Ask and keep working on something else.
- **A finding you are not going to fix.** If you notice a bug outside your task, do not fix it:
  the file probably has an owner on the build machine. Write it down here with file and line.
  That is a real contribution and it costs you one file.

## What not to do

Do not push to `main`. Do not touch a file your task does not name as yours. Do not commit
`BrainRotRoyale.rbxlx` or anything else in `.gitignore` — it is generated, and a committed copy
starts overwriting other people's work.
