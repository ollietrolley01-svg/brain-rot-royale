"""HUD toast queue (findings C3/I2): toasts that arrive together are all seen.

HudClient had one toast label and no queue, so when the server sent two or three at once (a climb
record and its coins, a chest's contents and the quest it finished, the end-of-match quests) the last
overwrote the others in the same frame and nobody read them. HudClient now queues them.

This runs the REAL toast block, cut out of StarterPlayerScripts/HudClient.client.lua (from
`local showToast` to its do-block's `end`), in lupa against a mocked label, tween service and a
simulated task scheduler with its own clock, and checks:

  1. three toasts in one frame are each shown, in the order sent, each for at least 1 s before the
     next replaces it;
  2. identical lines sent together are shown once (merged), and the others still show;
  3. a toast sent when nothing is showing appears at once, and the last of a burst fades on its own;
  4. a burst larger than the queue keeps its newest lines (the backlog is bounded) and still ends
     with every kept line shown;
  5. the same line sent again while it is up, with nothing waiting, stays up for its full time again.

Then each planted fault (--plant, or always as a self-test) must be caught:
  * no gap (the old overwrite: every queued line shown in the same instant),
  * newest-first order,
  * no duplicate merging.

    python3 tools/toast_queue_check.py [repo_root]
    python3 tools/toast_queue_check.py [repo_root] --plant
"""
import re
import sys
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("toast_queue_check: needs lupa (pip install lupa)")

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
ROOT = Path(ARGS[0] if ARGS else ".").resolve()
HUD = ROOT / "StarterPlayerScripts" / "HudClient.client.lua"


def luau_to_lua(src):
    out = []
    for line in src.split("\n"):
        m = re.match(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", line)
        if m:
            line = f"{m.group(1)}{m.group(2)} = {m.group(2)} {m.group(3)} ({m.group(4)})"
        out.append(line)
    return "\n".join(out)


def toast_block(src):
    m = re.search(r"^local showToast\ndo\n.*?^end$", src, re.M | re.S)
    return m.group(0) if m else None


HARNESS = r"""
local clock = 0
local timers = {}   -- { at, seq, fn }
local seq = 0
local function schedule(at, fn)
  seq = seq + 1
  table.insert(timers, { at = at, seq = seq, fn = fn })
end
tick = function() return clock end
task = {
  spawn = function(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err) end
  end,
  delay = function(t, fn) schedule(clock + t, fn) end,
  wait = function(t)
    local co = coroutine.running()
    schedule(clock + (t or 0), function()
      local ok, err = coroutine.resume(co)
      if not ok then error(err) end
    end)
    return coroutine.yield()
  end,
}
-- Advance the clock to `untilT`, running every timer due on the way, in time order.
local function advance(untilT)
  while true do
    local best, bi = nil, nil
    for i, tm in ipairs(timers) do
      if tm.at <= untilT and (best == nil or tm.at < best.at or (tm.at == best.at and tm.seq < best.seq)) then
        best, bi = tm, i
      end
    end
    if not best then break end
    table.remove(timers, bi)
    if best.at > clock then clock = best.at end
    best.fn()
  end
  clock = untilT
end

local shows = {}   -- { t, text }
local fades = {}   -- t
local props = { AnchorPoint = { Y = 0 } }  -- a phone-placed toast: the vehicle branch is not exercised
local faded = true
-- A show is what a player SEES change: new text, or any text on a label that had faded. Writing the
-- same line onto a label that is still up (a repeat restarting its time) is not a second show.
local toast = setmetatable({}, {
  __index = props,
  __newindex = function(_, k, v)
    if k == "Text" and (v ~= props.Text or faded) then table.insert(shows, { t = clock, text = v }) end
    props[k] = v
  end,
})
local TweenService = { Create = function(_, _, _, goal)
  return { Play = function()
    if goal.TextTransparency == 1 then faded = true ; table.insert(fades, clock) else faded = false end
  end }
end }
local TweenInfo = { new = function() return {} end }
local C = { Red = "red", Text = "text" }
local player = { Character = nil, GetAttribute = function() return nil end }
local UDim2 = { new = function() return {} end }

__BLOCK__

return {
  send = function(m, e) showToast(m, e) end,
  advance = advance,
  shows = function() return shows end,
  fades = function() return fades end,
  now = function() return clock end,
}
"""


def run(block):
    """Returns (problems, examined)."""
    problems = []

    def fresh():
        lua = LuaRuntime(unpack_returned_tuples=True)
        return lua.execute(HARNESS.replace("__BLOCK__", luau_to_lua(block)))

    def shows_of(h):
        s = h.shows()
        return [(s[i].t, s[i].text) for i in range(1, len(s) + 1)]

    def fades_of(h):
        f = h.fades()
        return [f[i] for i in range(1, len(f) + 1)]

    def dwell_problems(tag, seen, want):
        texts = [t for _, t in seen]
        if texts != want:
            problems.append(f"{tag}: shown {texts}, want {want} in that order")
            return
        for (t0, a), (t1, _) in zip(seen, seen[1:]):
            if t1 - t0 < 1.0 - 1e-9:
                problems.append(f"{tag}: {a!r} was replaced after {t1 - t0:.2f} s (under 1 s: unreadable)")

    # 1. A burst of three.
    h = fresh()
    for m in ("Climb record: 42 m!", "+25 SahurCoins", "Quest done: Climber"):
        h.send(m)
    h.advance(20)
    dwell_problems("burst of three", shows_of(h), ["Climb record: 42 m!", "+25 SahurCoins", "Quest done: Climber"])
    if shows_of(h) and shows_of(h)[0][0] != 0:
        problems.append("burst of three: the first toast did not appear at once")
    if not fades_of(h) or fades_of(h)[-1] < (shows_of(h) or [(0, "")])[-1][0] + 2.5:
        problems.append(f"burst of three: the last toast did not stay its full time and fade (fades {fades_of(h)})")

    # 2. Duplicates merge.
    h = fresh()
    for m in ("Chest: Med Kit", "Chest: Med Kit", "Quest done: Looter", "Chest: Med Kit", "+10 SahurCoins",
              "Quest done: Looter"):
        h.send(m)
    h.advance(20)
    dwell_problems("duplicates", shows_of(h), ["Chest: Med Kit", "Quest done: Looter", "+10 SahurCoins"])

    # 3. A lone toast after a quiet spell shows at once and fades.
    h = fresh()
    h.advance(50)
    h.send("Third-person camera")
    if shows_of(h) != [(50, "Third-person camera")]:
        problems.append(f"lone toast: shown {shows_of(h)}, want it at once (t=50)")
    h.advance(60)
    if len(fades_of(h)) != 1 or not (52.5 <= fades_of(h)[0] <= 53):
        problems.append(f"lone toast: faded at {fades_of(h)}, want once, ~2.6 s after it appeared")

    # 4. A flood keeps its newest lines, bounded.
    h = fresh()
    flood = [f"Quest {i} complete" for i in range(1, 13)]
    for m in flood:
        h.send(m)
    h.advance(60)
    texts = [t for _, t in shows_of(h)]
    if texts[0] != flood[0] or texts[-1] != flood[-1] or len(texts) > 8 or texts[1:] != flood[len(flood) - len(texts) + 1:]:
        problems.append(f"flood of 12: shown {texts}; want the first at once, then the newest few in order, at most 8")
    dwell_problems("flood of 12", shows_of(h), texts)

    # 5. The same line again, nothing waiting: its time restarts.
    h = fresh()
    h.send("Bounty on YOU")
    h.advance(2)
    h.send("Bounty on YOU")
    h.advance(4)
    if fades_of(h):
        problems.append(f"repeat: the line faded at {fades_of(h)} although it was sent again at t=2")
    h.advance(10)
    if len(fades_of(h)) != 1:
        problems.append(f"repeat: faded {len(fades_of(h))} times, want once")

    return problems, 5


PLANTS = [
    ("no gap between toasts (the old overwrite)", "local TOAST_GAP = 1.2", "local TOAST_GAP = 0"),
    ("newest first", "local entry = table.remove(waiting, 1)", "local entry = table.remove(waiting)"),
    ("no duplicate merging", "if entry[1] == message then", "if false then"),
]


def main():
    src = HUD.read_text(encoding="utf-8")
    block = toast_block(src)
    if block is None:
        print("toast_queue_check: FAIL - could not find `local showToast` / `do` ... `end` in HudClient")
        return 1
    problems, examined = run(block)
    for p in problems:
        print("  FAIL", p)
    caught = 0
    for name, old, new in PLANTS:
        if old not in block:
            print(f"  plant {name!r}: its anchor {old!r} is gone from HudClient -- MISSED")
            continue
        planted, _ = run(block.replace(old, new, 1))
        if planted:
            caught += 1
            print(f"  plant {name!r}: CAUGHT ({planted[0]})")
        else:
            print(f"  plant {name!r}: MISSED")
    print(f"toast_queue_check: {examined} scenarios, {len(problems)} problem(s); planted faults caught: {caught} of {len(PLANTS)}")
    return 0 if not problems and caught == len(PLANTS) else 1


if __name__ == "__main__":
    sys.exit(main())
