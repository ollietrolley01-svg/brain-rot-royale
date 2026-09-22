# Fixtures for tools/census.py

Two of them, and the second is the important one.

`must flag` — a module nothing names, and an exported function nothing references. If the census
stops flagging these it has stopped working.

`must NOT flag` — the two shapes that produced wrong answers while the census was being written,
kept here so they cannot come back:

* **A module required through a name held in a table.** `AliasedModule` is never written as
  `require(Shared.AliasedModule)`; its name only ever appears as a bare string. Real cases in this
  project: the remote dispatcher, and every `FindFirstChild(someVariable)` load.
* **A function referenced only as a value.** `LiveModule.CalledAsValue` is assigned to a hook and
  invoked through that, so it is never written as `.CalledAsValue(`. The real case is
  `CombatService.DestructiblePassesThrough = DestructibleService.PassesThrough`, which has five
  live call sites and none of them name the function.

This census becomes a delete list, so a false positive costs more than a miss. That is why the
must-not-flag fixture exists and why it is the one to add to when a new guard is written.
