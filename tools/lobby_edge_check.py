"""#103: the lobby's safety net. Pulls the REAL `LobbyService.HasFallen` and its constants out of
LobbyService.lua, runs them (lupa), and checks three invariants against the island's real
numbers (MatchConfig.LobbyPosition, MatchConfig.DropHeight):

  1. Nobody standing anywhere on or above the island is caught: every point from 1 stud under the
     plaza up to 300 over it, out to the net's radius.
  2. Nobody in a match is ever caught: every point at or under match altitude (DropHeight plus
     MAP_TOP of terrain, generous) anywhere on a 1500-stud square round the island.
  3. Anyone who steps off the rim is caught before falling through the net: a free fall from the
     plaza's height (and from 200 over it, the Cloud Climb) at Roblox gravity, sampled at the
     loop's interval with the worst phase, at every 5 degrees round the rim.

Planted faults (each must fail the check, run every time):
  A. NET_BOTTOM 220 -> 480   (the net reaches down into the match)       -> invariant 2
  B. NET_TOP 30 -> -2        (the net covers the plaza itself)            -> invariant 1
  C. NET_INTERVAL 0.2 -> 3   (checked too rarely to catch a fall)         -> invariant 3

Candidates examined are printed. Usage: python3 tools/lobby_edge_check.py [repo_root]
"""
import math
import re
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
LOBBY = (ROOT / "ServerScriptService/Modules/LobbyService.lua").read_text(encoding="utf-8")
CONFIG = (ROOT / "ReplicatedStorage/Shared/MatchConfig.lua").read_text(encoding="utf-8")

lobby_y = float(re.search(r"LobbyPosition = Vector3\.new\([^,]+,\s*([\d.]+)", CONFIG).group(1))
drop = float(re.search(r"DropHeight = ([\d.]+)", CONFIG).group(1))
rim = float(re.search(r"local RIM_RADIUS = ([\d.]+)", LOBBY).group(1))
MAP_TOP = 80  # tallest terrain a map puts a spawn on, generous
GRAVITY = 196.2


def section(source):
    start = source.index("local NET_TOP")
    end = source.index("local function catchFallers")
    return source[start:end]


LUA = r"""
local src = ...
local Vector3 = {}
function Vector3.new(x, y, z)
  return setmetatable({ X = x, Y = y, Z = z }, { __index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
  end })
end
local LobbyService = {}
local env = setmetatable({ Vector3 = Vector3, LobbyService = LobbyService }, { __index = _G })
local fn = assert(load("local LobbyService = LobbyService\n" .. src .. "\nreturn NET_INTERVAL, NET_RADIUS", "edge", "t", env))
local interval, radius = fn()
return function(x, y, z, bx, by, bz)
  return LobbyService.HasFallen(Vector3.new(x, y, z), Vector3.new(bx, by, bz))
end, interval, radius
"""


def check(source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    fallen, interval, radius = lua.execute(LUA, section(source))
    base = (0.0, lobby_y, 0.0)
    fails, examined = [], [0, 0, 0]

    def f(x, y, z):
        return fallen(x, y, z, *base)

    # 1. on or above the island
    for r in range(0, int(radius) + 1, 10):
        for deg in range(0, 360, 15):
            a = math.radians(deg)
            for dy in range(-1, 301, 10):
                examined[0] += 1
                if f(r * math.cos(a), lobby_y + dy, r * math.sin(a)):
                    fails.append(f"1: caught at r{r} {deg}deg {dy:+} (on/above the island)")
    # 2. anywhere a match puts anyone
    for x in range(-750, 751, 50):
        for z in range(-750, 751, 50):
            for y in range(-50, int(drop + MAP_TOP) + 1, 10):
                examined[1] += 1
                if f(x, y, z):
                    fails.append(f"2: caught a match player at ({x}, {y}, {z})")
    # 3. a fall off the rim, worst phase of the loop
    for start in (0.0, 200.0):
        for deg in range(0, 360, 5):
            a = math.radians(deg)
            x, z = (rim + 3) * math.cos(a), (rim + 3) * math.sin(a)
            for phase in (0.0, 0.5, 0.99):
                examined[2] += 1
                t, caught = interval * phase, False
                while t < 20:
                    y = lobby_y + start - 0.5 * GRAVITY * t * t
                    if f(x, y, z):
                        caught = True
                        break
                    if y < drop + MAP_TOP:
                        break
                    t += interval
                if not caught:
                    fails.append(f"3: fell off the rim at {deg}deg from {start:+} and was never caught (phase {phase})")
    return fails, examined


fails, examined = check(LOBBY)
print(f"lobby edge check: island y{lobby_y:g}, rim r{rim:g}, drop {drop:g}; examined "
      f"{examined[0]} island points, {examined[1]} match points, {examined[2]} falls")
if fails:
    print("FAIL (%d)\n" % len(fails) + "\n".join(fails[:10]))
    sys.exit(1)


def mutate(old, new):
    assert LOBBY.count(old) == 1, "planted fault anchor missing: " + old
    return LOBBY.replace(old, new)


faults = {
    "A (net reaches the match)": mutate("local NET_BOTTOM = 220", "local NET_BOTTOM = 480"),
    "B (net covers the plaza)": mutate("local NET_TOP = 30", "local NET_TOP = -2"),
    "C (checked too rarely)": mutate("local NET_INTERVAL = 0.2", "local NET_INTERVAL = 3"),
}
bad = 0
for name, source in faults.items():
    got, _ = check(source)
    print(f"  planted fault {name}: {'caught -- ' + got[0] if got else 'NOT CAUGHT'}")
    bad += not got
if bad:
    print("FAIL: a planted fault went uncaught")
    sys.exit(1)
print("OK")
