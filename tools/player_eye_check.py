"""Behaviour check for the logic fixes from the player's-eye review (#86), without Studio.

Runs the REAL shared modules (VoteCursor, AchievementData, CrateData + Rarity, GamepassConfig,
MatchEvents) in a Lua interpreter (lupa) and asserts what a player would read or get:

  1. vote      an UNREADY player's vote screen never takes the cursor (the blocks-play site: taking it
               raised MenuOpen, which dropped the Ready key while a full-screen overlay covered the
               READY UP pill). Every (open, decided, ready) combination is examined.
  2. achieve   the rank-score achievements say "Prestige N / M" / "Rank N / M", never the raw rank
               score (a Rot Rank 37 player read "37 / 1,001" towards Eternal Rot).
  3. odds      every crate's disclosed odds name each rarity in full: no "Unco", "Lege", "Secr".
  4. bundle    no bundle line stacks two multipliers ("5x 2x Health Boost").
  5. events    Zone Rush's card quotes the storm speed it actually applies.

    python tools/player_eye_check.py .            the checks
    python tools/player_eye_check.py . --plant    each check run against a planted fault; all must fail

The planted faults are aimed at the invariants, not at the old bugs: a vote rule that ignores
readiness, a progress text that prints the raw score, an odds line that abbreviates, a bundle line
that puts the count beside a multiplier, and a description whose number disagrees with the field.

Needs `pip install lupa`. Luau's `x += y` is rewritten to plain Lua before loading.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("player_eye_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    # x op= y  ->  x = x op (y), for + - * / and .. (`continue` is Luau-only too; none of these modules
    # use it, and one that did would fail to load loudly rather than pass quietly).
    return re.sub(r"^(\s*)([\w.\[\]]+) (\+|-|\*|/|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def shared(root, name):
    path = os.path.join(root, "ReplicatedStorage", "Shared", name + ".lua")
    return luau_to_lua(open(path, encoding="utf-8").read())


PRELUDE = r"""
local sources = ...
local loaded = {}
local function color() return { R = 0, G = 0, B = 0, Lerp = function(self) return self end } end
Color3 = { fromRGB = color, new = color }
-- Luau's math extras these modules call.
math.clamp = function(x, lo, hi) return math.max(lo, math.min(hi, x)) end
math.round = function(x) return math.floor(x + 0.5) end
local function child(name)
    return { Name = name, WaitForChild = function(_, n) return child(n) end }
end
script = { Parent = child("Shared") }
game = { GetService = function(_, n) return child(n) end }
function require(inst)
    local name = inst.Name
    if loaded[name] == nil then
        local src = sources[name]
        if not src then error("no source for " .. tostring(name)) end
        local fn, err = load(src, name)
        if not fn then error(err) end
        loaded[name] = fn()
    end
    return loaded[name]
end
return function(name) return require(child(name)) end
"""


def runtime(root, plant=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = lua.table()
    for name in ("VoteCursor", "AchievementData", "CrateData", "Rarity", "GamepassConfig", "MatchEvents"):
        text = shared(root, name)
        if plant == "vote" and name == "VoteCursor":
            text = text.replace("local wantsCursor = open == true and ready ~= false",
                                "local wantsCursor = open == true")
        if plant == "achieve" and name == "AchievementData":
            text = text.replace("progressText = AchievementData.ProgressText(achievement, progress),",
                                "progressText = tostring(progress) .. \" / \" .. tostring(achievement.target),")
        if plant == "odds" and name == "CrateData":
            text = text.replace('"%s %.1f%%", rarity, chance', '"%s %.1f%%", rarity:sub(1, 4), chance')
        if plant == "bundle" and name == "GamepassConfig":
            text = text.replace('"%d × one-match %s"', '"%dx %s"').replace(
                'HealthPro = "Pro Health Boost (2x max HP)"', 'HealthPro = "2x Health Boost (Pro)"')
        if plant == "events" and name == "MatchEvents":
            text = text.replace("stormSpeed = ZONE_RUSH_SPEED,", "stormSpeed = 1.75,")
        sources[name] = text
    return lua, lua.execute(PRELUDE, sources)


def check_vote(lua, req):
    screen = req("VoteCursor").Screen
    examined, bad = 0, []
    for open_ in (True, False):
        for decided in (None, "BR:Springs"):
            for ready in (True, False, None):
                examined += 1
                visible, wants = screen(open_, decided, ready)
                # The invariant: a player who is not ready never has the cursor taken for the vote.
                if ready is False and wants:
                    bad.append((open_, decided, ready))
                # And an open vote is always drawn, so the unready still see what they could vote on.
                if open_ and not visible:
                    bad.append(("hidden", open_, decided, ready))
    # The interactive case must still claim, or the check could pass on a vote nobody can click.
    _, wants_ready = screen(True, None, True)
    if not wants_ready:
        bad.append("ready player's open vote no longer takes the cursor")
    return examined, bad


def check_achieve(lua, req):
    data = req("AchievementData")
    examined, bad = 0, []
    # Rot Rank 37, no prestige (rank score 37), and Prestige 2 rank 5 (score 205).
    for score in (37, 205):
        profile = lua.eval("function(score) return { Achievements = {}, Title = nil, _score = score } end")(score)
        # Value(data, stat) is the module's own; feed the score through a stub for rankScore only.
        original = data.Value
        data.Value = lua.eval("function(orig) return function(d, stat) if stat == 'rankScore' then return d._score end return 0 end end")(original)
        snap = data.Snapshot(profile)
        data.Value = original
        for i in range(1, len(snap.list) + 1):
            row = snap.list[i]
            ach = next(a for a in (data.List[j] for j in range(1, len(data.List) + 1)) if a.id == row.id)
            if ach.stat != "rankScore":
                continue
            examined += 1
            text = row.progressText or ""
            if ach.target > 100:
                want = "Prestige %d / %d" % (min(score, ach.target) // 100, ach.target // 100)
            else:
                want = "Rank %d / %d" % (min(score, ach.target), ach.target)
            if text != want:
                bad.append((score, row.id, text, want))
            if "rank score" in (row.description or ""):
                bad.append((row.id, "formula in description"))
    return examined, bad


def check_odds(lua, req):
    crates = req("CrateData")
    rarity = req("Rarity")
    names = [rarity.Order[i] for i in range(1, len(rarity.Order) + 1)]
    examined, bad = 0, []
    order = crates.Order
    for i in range(1, len(order) + 1):
        tier = order[i]
        crate = crates.Get(tier)
        for boosted in (False, True):
            parts = crates.OddsLine(crate, 1, boosted)
            for j in range(1, len(parts) + 1):
                part = parts[j]
                examined += 1
                word = re.match(r"^(\w+)", part)
                if not word:
                    continue
                w = word.group(1)
                if w in ("up",):  # "up to N% an accessory instead"
                    continue
                if w not in names:
                    bad.append((tier, boosted, part))
    return examined, bad


def check_bundle(lua, req):
    gp = req("GamepassConfig")
    examined, bad = 0, []
    for key, product in gp.Products.items():
        grant = product.grant
        if not grant or grant.kind != "Bundle":
            continue
        lines = gp.DescribeContents(grant, None)
        for i in range(1, len(lines) + 1):
            line = lines[i]
            examined += 1
            if re.search(r"\d+x \d+(\.\d+)?x", line) or re.search(r"\d+x [\d.]+x", line):
                bad.append((key, line))
    return examined, bad


def check_events(lua, req):
    events = req("MatchEvents")
    examined, bad = 0, []
    for i in range(1, len(events.List) + 1):
        event = events.List[i]
        if event.stormSpeed is None:
            continue
        examined += 1
        m = re.search(r"(\d+)% faster", event.description or "")
        if not m or int(m.group(1)) != round((event.stormSpeed - 1) * 100):
            bad.append((event.id, event.description, event.stormSpeed))
    return examined, bad


CHECKS = [("vote", check_vote), ("achieve", check_achieve), ("odds", check_odds),
          ("bundle", check_bundle), ("events", check_events)]


def run(root, plant=None):
    failures = 0
    for name, fn in CHECKS:
        if plant and plant != name:
            continue
        lua, req = runtime(root, plant)
        examined, bad = fn(lua, req)
        status = "FAIL" if bad or examined == 0 else "ok"
        print("  %-8s %s  (%d candidates examined, %d bad)%s" % (
            name, status, examined, len(bad), ("  e.g. " + repr(bad[0])) if bad else ""))
        if status == "FAIL":
            failures += 1
    return failures


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else "."
    if "--plant" in sys.argv:
        print("player_eye_check: planted faults (every one must FAIL)")
        missed = 0
        for name, _ in CHECKS:
            if run(root, plant=name) == 0:
                print("  PLANT NOT CAUGHT: " + name)
                missed += 1
        print("planted: %d of %d caught" % (len(CHECKS) - missed, len(CHECKS)))
        sys.exit(1 if missed else 0)
    print("player_eye_check: real modules")
    failures = run(root)
    print("player_eye_check: %s" % ("OK" if failures == 0 else "%d check(s) failed" % failures))
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
