"""Check: a player standing on the lobby ready pad can un-ready, and the pad still readies whoever steps on.

    python3 tools/ready_pad_check.py            the scenarios, then the planted faults (exit 0 = all good)
    python3 tools/ready_pad_check.py --lobby F  run the scenarios against another LobbyService.lua (e.g. main's)

Cuts the real LobbyService buildReadyPad (with its PAD_ constants and readyPadLastTouch), the real
Bootstrap LobbyService.OnReadyPad hook and the real MatchService.SetReady (with isReady and
lastReadyToggle) out of the source and runs them in lupa. Clock (wallNow, tick), task.spawn/task.wait
and the character's position are mocked; time moves in 0.05 s steps.

ASSUMPTION (Roblox behaviour, not this code's): pad.Touched fires again and again while a character
stands on the pad, here every 0.2 s. A Studio Play test with a client standing on the pad would confirm it.

Scenarios (each 10 s, one player):
  stand       walks on at 0.5 s, stands on the pad with touches every 0.2 s, presses un-ready at 3 s. Ready
              must be false at 10 s.
  walk on     starts off the pad, not ready, walks on at 2 s. Ready must be true.
  revisit     readies on the pad, un-readies at 3 s, walks off at 5 s, walks back on at 7 s. Ready must be
              true at 10 s: a second visit readies again.
  walk off    readies on the pad, un-readies at 3 s, walks off at 5 s: for 0.6 s the root is past PAD_REACH
              while a foot still touches the rim, then off. Ready must be false.
  jump        readies on the pad, un-readies at 3 s, jumps on the spot at 5 s (no touches for 1 s, the root
              stays over the pad). Ready must be false.
  pill only   never on the pad; presses at 1.0, 1.25 (inside SetReady's 0.3 s throttle) and 2.0 s. The
              throttled press is dropped, the next one works: the throttle alone never strands anyone ready.

INVARIANT checked in every scenario: Ready goes false -> true only on a step where something new happened
(the root arrived on the pad from off it, or the player pressed ready). An un-ready is never overwritten
while nothing new happened.

PLANTED FAULTS (permanent), each must turn a scenario red:
  old debounce    the pre-fix handler: ready on any touch 1.5 s after the last one.
  visit never ends  the watcher never clears the visit, so the pad stops working after one visit.
  visit always ends the watcher ends the visit on its first look, so standing re-readies.
  no linger       the visit ends as soon as the root is off the pad, so the last foot on the rim re-readies.
  pad not wired   OnReadyPad no longer calls SetReady.
"""
import os
import re
import subprocess
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("ready_pad_check: needs lupa (pip install lupa)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOBBY = os.path.join(ROOT, "ServerScriptService", "Modules", "LobbyService.lua")
MATCH = os.path.join(ROOT, "ServerScriptService", "Modules", "MatchService.lua")
BOOT = os.path.join(ROOT, "ServerScriptService", "Bootstrap.server.lua")


def cut(src, head):
    """The block that starts on the line holding `head` and ends at the first `end` at its indent."""
    a = src.index(head)
    line_start = src.rfind("\n", 0, a) + 1
    indent = src[line_start:a]
    b = src.index("\n" + indent + "end", a) + len(indent) + 4
    return src[line_start:b] + "\n"


def lobby_source(lobby):
    consts = "\n".join(re.findall(r"^local PAD_\w+ = .*$", lobby, flags=re.M))
    return (consts + "\nlocal readyPadLastTouch = {}\n" + cut(lobby, "local function buildReadyPad(")
            + "return buildReadyPad\n")


def match_source(match):
    return ("local lastReadyToggle = {}\n" + cut(match, "local function isReady(")
            + cut(match, "function MatchService.SetReady(") + "return MatchService\n")


def boot_source(boot):
    return cut(boot, "LobbyService.OnReadyPad = function(") + "return LobbyService\n"


HARNESS = r"""
local lobbySrc, matchSrc, bootSrc, scenario = ...

-- Mocks ---------------------------------------------------------------------------------------
local now = 0
local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({ X = a.X + b.X, Y = a.Y + b.Y, Z = a.Z + b.Z }, V) end
V.__sub = function(a, b) return setmetatable({ X = a.X - b.X, Y = a.Y - b.Y, Z = a.Z - b.Z }, V) end
local Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end }
local CF = {}
CF.__mul = function(a) return a end
local CFrame = { new = function(p) return setmetatable({ p = p }, CF) end,
    Angles = function() return setmetatable({}, CF) end }

local threads = {}
local task = {
    spawn = function(fn) local co = coroutine.create(fn); table.insert(threads, { co = co, at = now }) end,
    wait = function(s) coroutine.yield(s or 0) end,
}
local function runThreads()
    local i = 1
    while i <= #threads do
        local t = threads[i]
        if t.at <= now + 1e-9 then
            local ok, delay = coroutine.resume(t.co)
            assert(ok, delay)
            if coroutine.status(t.co) == "dead" then
                table.remove(threads, i)
            else
                t.at = now + (delay or 0)
                i = i + 1
            end
        else
            i = i + 1
        end
    end
end

local touched = {}
local pad
local function disc(_, diameter, thickness, position)
    local p = { Name = "", Position = position + Vector3.new(0, thickness / 2, 0),
        Touched = { Connect = function(_, fn) table.insert(touched, fn) end } }
    pad = p
    return p
end
local function stub(x) return x end

local root = { Position = Vector3.new(0, 0, 40) }
local character = { FindFirstChild = function(_, name) if name == "HumanoidRootPart" then return root end end }
local attrs = {}
local player = { UserId = 1, Parent = {}, Character = character,
    GetAttribute = function(_, k) return attrs[k] end,
    SetAttribute = function(_, k, v) attrs[k] = v end }
character.Parent = nil
local Players = { GetPlayerFromCharacter = function(_, c) if c == character then return player end end }

local LobbyService, MatchService = {}, {}
local env = setmetatable({ Vector3 = Vector3, CFrame = CFrame, task = task, Players = Players,
    Color3 = { fromRGB = function() return {} end }, Enum = setmetatable({}, { __index = function() return {} end }),
    LobbyService = LobbyService, MatchService = MatchService,
    wallNow = function() return now end, tick = function() return now end,
    disc = disc, decor = stub, part = function() return {} end, pointLight = stub,
    billboard = function() return {} end, keyHint = stub, GREEN = {}, WHITE = {},
    state = "Lobby", broadcast = function() end }, { __index = _G })

local buildReadyPad = assert(load(lobbySrc, "buildReadyPad", "t", env))()
assert(load(matchSrc, "SetReady", "t", env))()
assert(load(bootSrc, "OnReadyPad", "t", env))()
local center = Vector3.new(0, 4.4, 0)
buildReadyPad({}, center)

-- Scenario script ----------------------------------------------------------------------------
-- where(t) -> "on" | "off" | "edge" (edge: root off the footprint, feet still touching the rim)
-- touching(t) -> whether Touched fires this 0.2 s beat; press(t) -> true/false/nil for the pill.
local on = Vector3.new(0, 7.4, 1)          -- root 3 studs over the pad, a stud off centre
local edge = Vector3.new(0, 7.4, 7.6)     -- walking off: root past PAD_REACH, a foot on the rim
local off = Vector3.new(0, 7.4, 40)
local scripts = {
    stand = { start = false,
        where = function(t) return t >= 0.5 and "on" or "off" end,
        press = { [3.0] = false }, expect = false },
    ["walk on"] = { start = false,
        where = function(t) return t >= 2 and "on" or "off" end,
        press = {}, expect = true },
    revisit = { start = false,
        where = function(t) return (t >= 0.5 and t < 5) and "on" or (t >= 7) and "on" or "off" end,
        press = { [3.0] = false }, expect = true },
    ["walk off"] = { start = false,
        where = function(t) return t < 0.5 and "off" or t < 5 and "on" or t < 5.6 and "edge" or "off" end,
        press = { [3.0] = false }, expect = false },
    jump = { start = false,
        where = function(t) return t >= 0.5 and "on" or "off" end,
        silent = function(t) return t >= 5 and t < 6 end,
        press = { [3.0] = false }, expect = false },
    ["pill only"] = { start = false,
        where = function() return "off" end,
        press = { [1.0] = true, [1.25] = false, [2.0] = false }, expect = false, dropped = 1.25 },
}
local s = assert(scripts[scenario], scenario)
attrs.Ready = s.start

local out = { violations = {} }
local prevWhere = "off"
local step = 0
local newSinceUnready = false   -- an arrival or a ready press since Ready last went false
while now <= 10 + 1e-9 do
    local w = s.where(now)
    root.Position = (w == "on" and on) or (w == "edge" and edge) or off
    if w == "on" and prevWhere == "off" then newSinceUnready = true end
    local before = attrs.Ready == true
    for at, value in pairs(s.press) do
        if math.abs(now - at) < 1e-6 then
            if value then newSinceUnready = true end
            MatchService.SetReady(player, value)
            if s.dropped and math.abs(at - s.dropped) < 1e-6 then
                out.droppedHeld = (attrs.Ready == true) ~= value
            end
        end
    end
    local beat = step % 4 == 0   -- every 0.2 s
    if beat and w ~= "off" and not (s.silent and s.silent(now)) then
        for _, fn in ipairs(touched) do fn({ Parent = character }) end
    end
    runThreads()
    if not before and attrs.Ready == true and not newSinceUnready then
        table.insert(out.violations, string.format("%.2f", now))
    end
    if before and attrs.Ready ~= true then newSinceUnready = false end
    prevWhere = w
    step = step + 1
    now = math.floor(step * 5 + 0.5) / 100
end
out.ready = attrs.Ready == true
out.expect = s.expect
return out
"""

SCENARIOS = ["stand", "walk on", "revisit", "walk off", "jump", "pill only"]


def run(lobby, match, boot, scenario):
    lua = LuaRuntime(unpack_returned_tuples=True)
    res = lua.execute(HARNESS, lobby_source(lobby), match_source(match), boot_source(boot), scenario)
    return {"ready": res["ready"], "expect": res["expect"],
            "violations": list(res["violations"].values()), "droppedHeld": res["droppedHeld"]}


def suite(lobby, match, boot, quiet=False):
    """Run every scenario; returns the names that failed."""
    failed = []
    for name in SCENARIOS:
        try:
            r = run(lobby, match, boot, name)
        except Exception as e:  # a fault that breaks the harness counts as caught
            failed.append(name)
            if not quiet:
                print(f"  {name:10} ERROR {str(e).splitlines()[0]}")
            continue
        ok = r["ready"] == r["expect"] and not r["violations"]
        extra = ""
        if name == "pill only":
            ok = ok and r["droppedHeld"] is True
            extra = f", press at 1.25 s dropped by the 0.3 s throttle: {r['droppedHeld']}"
        if not ok:
            failed.append(name)
        if not quiet:
            v = ", re-readied with nothing new at " + ", ".join(r["violations"][:5]) if r["violations"] else ""
            print(f"  {name:10} {'ok  ' if ok else 'FAIL'} Ready at 10 s = {str(r['ready']).lower()} "
                  f"(want {str(r['expect']).lower()}){v}{extra}")
    return failed


OLD_HANDLER = """\t\tlocal now = wallNow()
\t\tif readyPadLastTouch[player] and now - readyPadLastTouch[player] < 1.5 then
\t\t\treturn
\t\tend
\t\treadyPadLastTouch[player] = now
\t\tLobbyService.OnReadyPad(player)
\tend)"""


def faults(lobby, boot):
    body = re.search(r"\t\tlocal visiting = readyPadLastTouch\[player\] ~= nil\n.*?\n\tend\)", lobby, flags=re.S)
    assert body, "ready_pad_check: the visit handler moved; update the planted faults"
    return [
        ("old debounce", lobby.replace(body.group(0), OLD_HANDLER), boot),
        ("visit never ends", lobby.replace("until visitOver(player)", "until false"), boot),
        ("visit always ends", lobby.replace("until visitOver(player)", "until true"), boot),
        ("no linger", lobby.replace("return wallNow() - last >= PAD_LINGER", "return true"), boot),
        ("pad not wired", lobby, boot.replace("MatchService.SetReady(player, true)", "local _ = player")),
    ]


def main():
    args = sys.argv[1:]
    lobby_path = args[args.index("--lobby") + 1] if "--lobby" in args else LOBBY
    lobby, match, boot = (open(p, encoding="utf-8").read() for p in (lobby_path, MATCH, BOOT))
    print(f"ready pad: {len(SCENARIOS)} scenarios, Touched every 0.2 s while on the pad (assumed), "
          f"source {os.path.relpath(lobby_path, ROOT)}")
    failed = suite(lobby, match, boot)
    if "--lobby" in args:
        print(f"ready pad: {len(failed)} of {len(SCENARIOS)} scenarios failed")
        return 1 if failed else 0
    caught = 0
    fs = faults(lobby, boot)
    for name, l, b in fs:
        if l == lobby and b == boot:
            print(f"  planted {name}: the fault did not apply")
            continue
        red = suite(l, match, b, quiet=True)
        caught += bool(red)
        print(f"  planted {name:17} {'caught' if red else 'MISSED'} ({', '.join(red) or 'all scenarios passed'})")
    print(f"ready pad: {len(SCENARIOS) - len(failed)}/{len(SCENARIOS)} scenarios pass, {caught}/{len(fs)} planted faults caught")
    return 0 if not failed and caught == len(fs) else 1


if __name__ == "__main__":
    sys.exit(main())
