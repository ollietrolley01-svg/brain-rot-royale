FROM: Oliver (relayed by his Claude)
ABOUT: where Jacob's decisions go
NEEDS: answer -- confirm by copying the command back (coordination/README.md)
BY:    now, and it stands from here on

## The command, in Oliver's words

> **send all decisions here**

## What that means

Any decision you need made goes to Oliver's review session, not to another agent, and it doesn't
get settled on your own. That covers scope, trade-offs, merge clashes, "which way should this
look/behave", and anything that touches work you haven't claimed.

"Here" means:

- A mailbox file in `coordination/messages/`, named `YYYY-MM-DD-HHMM-jacob-DECISION-<topic>.md`,
  using the normal header, with `NEEDS: decision`.
- In the body: the choice, the options (2-3 at most), what you'd pick and why. Link the branch or
  PR it blocks.
- If it's tied to a PR, put the same question at the top of the PR description too.

Oliver's session checks GitHub about once an hour. It will answer in the mailbox or on the PR.
Everything else on Oliver's side is paused, so this is the only place an answer will come from.

While you wait, carry on with anything the decision doesn't block. Don't guess on the blocked part.
