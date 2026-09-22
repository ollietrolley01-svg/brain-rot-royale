# Fixtures for the PATTERN stage of `tools/lua_static_check.py`

Each of the eight rules owns a pair:

| file | must |
| --- | --- |
| `<rule>_bad.lua.fixture` | be flagged by its rule |
| `<rule>_good.lua.fixture` | **not** be flagged by its rule |

The `_bad` file is that rule's **permanent planted fault**. It runs on every invocation of
`lua_static_check.py`, and a rule that stops flagging its own fault fails the run — a rule that
has quietly stopped matching anything is indistinguishable from a clean codebase, and the only
way to tell them apart is to keep something in front of it that must always match.

Each fault is aimed at the rule's **invariant**, not at the bug that prompted the rule. "The admin
Fly attribute is still unread" would have expired the moment somebody added the reader, and the
reader has since been added — that plant would now be proving nothing while still printing
green-adjacent output. "An attribute written and never read must be reported" cannot expire.

The `_good` file matters more than the `_bad` one. It is the correct version of the same shape, and
it is what stops the rule being switched off by the first person it annoys.

## Why `.lua.fixture` and not `.lua`

`tools/balance.py` globs `**/*.lua` from the project root and `tools/verify.py` walks every `.lua`
under it, so a deliberately-wrong `.lua` file here would turn up in two other people's checks.
The extension keeps these files out of those sweeps. They still travel this stage's own
`open()` → `ScanFile` → rule route, which is the route real input takes: `lua_static_check.py .
<path>` reads explicit paths exactly the same way. A needle fed by a different route proves a
detector that works on a route nothing uses, which is the mistake that already passed a green
self-test on this project (`tools/verify.py:1133`).

## Running them alone

```
python tools/lua_static_check.py . --patterns-only
```

prints every rule's candidate counts, the findings, the notes, and the self-test line.
