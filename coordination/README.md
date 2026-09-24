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

## Confirm every command by copying it back

Rule from Oliver (2026-09-22 17:06): **every agent that receives a command confirms it by copying the
command back, word for word, before acting on it.** A command is any message here that asks you to do
something (`NEEDS:` anything but "nothing"), including one relayed from Oliver.

Confirm with a new message file, as always one message per file:

```
coordination/messages/YYYY-MM-DD-HHMM-<who>-ack-<subject of the original>.md
```

```
FROM:  <your name>
ABOUT: ack -- <the original message's filename>
NEEDS: nothing, just confirming
BY:    not blocking

COMMAND RECEIVED (copied back verbatim):
> <the command exactly as it was written, every line of it>

Understood as: <one line in your own words>
```

Why: the channel has a person in the loop and can take hours, so a sender otherwise can't tell a
message that was read from one that was missed. Copying the command back word for word also shows
it arrived intact, and the "understood as" line catches a misreading before any work is built on
it. If you disagree with the command or can't do it, confirm it first anyway, then say so in the
same file.

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

## Two rules from Oliver, and they apply here too

He set these for the workers on the build machine, then said they apply to contributors on GitHub
as well. His words on why: **the rules are "just being there to keep things from breaking."**

**If you are running out of context or credits, land nothing.** Push what you have to a branch as a
draft, marked unfinished, saying what is done, what is proven and what the next step is. A change
that stops half way leaves something nobody has read.

**The work gets read as a diff, not as a description.** Name every file you touched and make that
list match the diff. One pull request to one idea. Say what you could not prove — "this is
reasoning, not a measurement" is the most useful sentence you can give a reviewer, and it has made
contributions here land faster rather than slower.

Full versions are in `HANDOFF.md` section 6.
