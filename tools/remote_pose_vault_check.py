"""Vault check (#132 / #115, "vaulting still doesn't work"), without Studio.

Runs the REAL Shared/Parkour.lua (Parkour.Find), the REAL MovementService panesAhead (the server's
glass box for a player's vault) and the REAL MovementClient arrivalSpeed in a Lua interpreter (lupa),
against a ground-floor window built from MapBuildings' own constants (read from its source: wall
thickness, sill, window top and width, floor height, pane overlap and thickness; the bands, piers and
pane placed the way buildWall and dressWall place them; trim is CanQuery = false there, so it is left
out here) and a default R15 body (HumanoidRootPart 2 x 2 x 1, HipHeight 2, head top 2.2 over the root).
Queries are answered by a small axis-aligned world: Raycast and Blockcast skip a part they start inside,
as Roblox does; GetPartBoundsInBox returns every overlapping part.

What must hold, forever:
  T  a body that SPRINTED at the window and pressed jump anywhere from 2.9 studs out to touching the
     wall gets a vault through it -- including the frame the wall has already stopped it.
  S  a body that has stood still for a second never vaults (the run-up must not outlive the run).
  G  the server's glass box takes the pane of a vault the client began, whether what the server sees
     of the body is up to 0.2 s late (sprinting, still in front) or already through the wall.
  F  a vault over a fence 3 studs in front of a window never takes that window's pane.
Also printed, not asserted: lateral offsets and heights into a jump that still vault.

    python tools/remote_pose_vault_check.py .           the checks
    python tools/remote_pose_vault_check.py . --plant   the planted faults; every one must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("remote_pose_vault_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a)]


def load(root):
    buildings = read(root, "ServerScriptService", "Modules", "MapBuildings.lua")
    consts = {}
    for name in ("WALL_THICKNESS", "SILL_HEIGHT", "WINDOW_TOP", "WINDOW_WIDTH", "FLOOR_HEIGHT",
                 "GLASS_OVERLAP", "GLASS_THICKNESS"):
        consts[name] = float(re.search(r"^local %s = ([\d.]+)" % name, buildings, re.M).group(1))
    service = read(root, "ServerScriptService", "Modules", "MovementService.lua")
    glass = between(service, "local function flatLook", "local function deployPad") + \
        between(service, "local GLASS_REACH", "-- `plan` (optional)")
    client = read(root, "StarterPlayerScripts", "MovementClient.client.lua")
    arrival = between(client, "local function arrivalSpeed", "-- Looks for a climb or vault")
    return {
        "consts": consts,
        "config": luau_to_lua(read(root, "ReplicatedStorage", "Shared", "MovementConfig.lua")),
        "parkour": luau_to_lua(read(root, "ReplicatedStorage", "Shared", "Parkour.lua")),
        "glass": luau_to_lua(glass),
        "arrival": luau_to_lua(arrival),
    }


HARNESS = r"""
local src, K = ...
local log = {}
local function check(ok, what) table.insert(log, { ok = ok and true or false, what = what }) end
local notes = {}
local function note(s) table.insert(notes, s) end

function math.clamp(x, a, b) return math.max(a, math.min(b, x)) end

-- Vector3
local V = {}
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) return Vector3.new(v.X / m, v.Y / m, v.Z / m) end
    return V[k]
end
Vector3 = {}
function Vector3.new(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V) end
Vector3.zero = Vector3.new(0, 0, 0)
V.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__unm = function(a) return Vector3.new(-a.X, -a.Y, -a.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    return Vector3.new(a.X * b, a.Y * b, a.Z * b)
end
V.__div = function(a, b) return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function V.Lerp(a, b, t) return a + (b - a) * t end

-- CFrame: only lookAt is queried; the pose table at Parkour's foot just needs to build.
local CF = {}
CF.__index = CF
CF.__mul = function(a, b) return a end
CFrame = {}
function CFrame.new(...) return setmetatable({}, CF) end
function CFrame.Angles(...) return setmetatable({}, CF) end
function CFrame.lookAt(p, t) return setmetatable({ Position = p, LookVector = (t - p).Unit }, CF) end

local enumMeta = { __index = function(t, k) local v = { Name = k } rawset(t, k, v) return v end }
Enum = setmetatable({}, { __index = function(t, k) local v = setmetatable({}, enumMeta) rawset(t, k, v) return v end })
RaycastParams = { new = function() return {} end }
OverlapParams = { new = function() return {} end }

-- The world: axis-aligned parts.
local map = { Name = "Map" }
local parts = {}
local function part(name, x0, x1, y0, y1, z0, z1, collide)
    local p = { Name = name, lo = Vector3.new(x0, y0, z0), hi = Vector3.new(x1, y1, z1), CanCollide = collide ~= false,
        Anchored = true, Parent = map }
    p.Position = (p.lo + p.hi) / 2
    p.Size = p.hi - p.lo
    function p:GetAttribute() return nil end
    function p:IsA(c) return c == "BasePart" end
    function p:IsGrounded() return true end
    function p:FindFirstAncestorOfClass() return nil end
    table.insert(parts, p)
    return p
end
local function clear() for i = #parts, 1, -1 do parts[i] = nil end end

local function usable(p, params)
    if params and params.RespectCanCollide and not p.CanCollide then return false end
    return true
end

-- A box (half extents h) swept from c along d: first part it meets, skipping any it starts in.
local function sweep(c, h, d, params)
    local best, bestT, bestAxis, bestSign = nil, math.huge, nil, nil
    for _, p in ipairs(parts) do
        if usable(p, params) then
            local lo, hi = p.lo - h, p.hi + h
            local inside = c.X > lo.X and c.X < hi.X and c.Y > lo.Y and c.Y < hi.Y and c.Z > lo.Z and c.Z < hi.Z
            if not inside then
                local tmin, tmax, axis, sign = 0, 1, nil, nil
                local ok = true
                for _, a in ipairs({ "X", "Y", "Z" }) do
                    if math.abs(d[a]) < 1e-9 then
                        if c[a] <= lo[a] or c[a] >= hi[a] then ok = false end
                    else
                        local t1, t2 = (lo[a] - c[a]) / d[a], (hi[a] - c[a]) / d[a]
                        local s = -1
                        if t1 > t2 then t1, t2 = t2, t1; s = 1 end
                        if t1 > tmin then tmin, axis, sign = t1, a, s end
                        if t2 < tmax then tmax = t2 end
                    end
                end
                if ok and axis and tmin <= tmax and tmin < bestT then
                    best, bestT, bestAxis, bestSign = p, tmin, axis, sign
                end
            end
        end
    end
    if not best then return nil end
    local at = c + d * bestT
    local pos = Vector3.new(math.clamp(at.X, best.lo.X, best.hi.X), math.clamp(at.Y, best.lo.Y, best.hi.Y), math.clamp(at.Z, best.lo.Z, best.hi.Z))
    local n = { X = 0, Y = 0, Z = 0 }
    n[bestAxis] = bestSign
    return { Instance = best, Position = pos, Normal = Vector3.new(n.X, n.Y, n.Z), Distance = d.Magnitude * bestT }
end

-- Half extents in world axes of a box `size` oriented by lookAt (look along +-X or +-Z only).
local function halves(cf, size)
    local look = cf.LookVector
    if math.abs(look.X) > math.abs(look.Z) then
        return Vector3.new(size.Z / 2, size.Y / 2, size.X / 2)
    end
    return Vector3.new(size.X / 2, size.Y / 2, size.Z / 2)
end

workspace = { Gravity = 196.2 }
map.Parent = workspace
function map:GetAttribute() return nil end
function workspace:Raycast(o, d, params) return sweep(o, Vector3.zero, d, params) end
function workspace:Blockcast(cf, size, d, params) return sweep(cf.Position, halves(cf, size), d, params) end
function workspace:GetPartBoundsInBox(cf, size, params)
    local h = halves(cf, size)
    local lo, hi = cf.Position - h, cf.Position + h
    local out = {}
    for _, p in ipairs(parts) do
        if usable(p, params) and p.lo.X < hi.X and p.hi.X > lo.X and p.lo.Y < hi.Y and p.hi.Y > lo.Y
            and p.lo.Z < hi.Z and p.hi.Z > lo.Z then
            table.insert(out, p)
        end
    end
    return out
end
function workspace:FindFirstChild(n) if n == "Map" then return map end end

local modules = {}
local shared = { WaitForChild = function(_, n) return n end }
game = { GetService = function() return { WaitForChild = function() return shared end } end }
function require(name) return modules[name] end
modules.MovementConfig = assert(load(src.config))()
modules.Parkour = assert(load(src.parkour))()
local Parkour, MovementConfig = modules.Parkour, modules.MovementConfig
local CFG = MovementConfig.Parkour

-- The window: MapBuildings' ground floor, origin at grade 0, wall along X centred on z = 0, the body
-- outside at negative z running toward +z. buildWall's bands start at baseY + 0.5.
local T, S, TOP, W, FH = K.WALL_THICKNESS, K.SILL_HEIGHT, K.WINDOW_TOP, K.WINDOW_WIDTH, K.FLOOR_HEIGHT
local face = -T / 2
local function buildWindow()
    clear()
    part("Ground", -60, 60, -1, 0, -60, face)
    part("Floor", -12.3, 12.3, -0.5, 0.5, T / 2, 20)
    part("Wall", -13, 13, 0.5, 0.5 + S, -T / 2, T / 2)
    part("Wall", -13, -W / 2, 0.5 + S, 0.5 + TOP, -T / 2, T / 2)
    part("Wall", W / 2, 13, 0.5 + S, 0.5 + TOP, -T / 2, T / 2)
    part("Wall", -13, 13, 0.5 + TOP, 0.5 + FH, -T / 2, T / 2)
    local o, g = K.GLASS_OVERLAP, K.GLASS_THICKNESS
    return part("WindowGlass", -W / 2 - o, W / 2 + o, 0.5 + S - o, 0.5 + TOP + o, -g / 2, g / 2)
end

-- A default R15 body: root 2 x 2 x 1, HipHeight 2, head top 2.2 over the root centre.
local function body(x, feetY, z, velocity)
    local root = { Size = Vector3.new(2, 2, 1), Position = Vector3.new(x, feetY + 3, z),
        CFrame = { LookVector = Vector3.new(0, 0, 1) }, AssemblyLinearVelocity = velocity or Vector3.zero }
    local head = { Size = Vector3.new(1.2, 1.2, 1.2), Position = root.Position + Vector3.new(0, 1.6, 0) }
    local humanoid = { HipHeight = 2, Health = 100, Sit = false }
    function humanoid:GetState() return Enum.HumanoidStateType.Running end
    local c = {}
    function c:FindFirstChild(n) if n == "HumanoidRootPart" then return root elseif n == "Head" then return head end end
    function c:FindFirstChildOfClass(n) if n == "Humanoid" then return humanoid end end
    return c, root
end

local arrivalSpeed = assert(load(src.arrival .. "\nreturn arrivalSpeed"))()
local glassEnv = assert(load("local Parkour, MovementConfig = ...\n" .. src.glass .. "\nreturn panesAhead"))
local panesAhead = glassEnv(Parkour, MovementConfig)

local SPRINT = 18 * 1.45
local FWD = Vector3.new(0, 0, 1)
-- A run-up: sprinting until `stoppedFor` seconds ago, sampled every 1/60 s over 1.5 s, now = 10
-- (older than the window on purpose: a check that ages samples out must be given some to age out).
local function runUp(stoppedFor)
    local samples = {}
    for i = 0, 90 do
        local at = 10 - i / 60
        local moving = (10 - at) >= stoppedFor
        table.insert(samples, { at = at, velocity = moving and FWD * SPRINT or Vector3.zero })
    end
    return samples
end

-- The client's call, as tryParkour makes it.
local function clientFind(x, feetY, dist, velocityNow, samples, grounded)
    local c = body(x, feetY, face - dist)
    local speed = math.max(velocityNow, arrivalSpeed(samples, FWD, 10, 0.3))
    return Parkour.Find(c, FWD, { groundY = 0, speed = speed, grounded = grounded ~= false, allowVault = true })
end

-- T: pressed from 2.9 out to touching. Touching: root centre halfDepth (0.5) from the face, stopped
-- 0.05 s ago; nearer out, still at full speed.
buildWindow()
local tried, vaulted = 0, 0
for _, dist in ipairs({ 0.5, 0.6, 1.0, 1.5, 2.0, 2.4, 2.8 }) do
    local touching = dist <= 0.6
    local plan, why = clientFind(0, 0, dist, touching and 0 or SPRINT, runUp(touching and 0.05 or 0))
    tried = tried + 1
    local ok = plan and plan.kind == "vault" and plan.panes and #plan.panes == 1
    if ok then vaulted = vaulted + 1 end
    check(ok, string.format("T sprint at a window, jump at %.1f studs%s: %s", dist, touching and " (wall already stopped it)" or "",
        plan and (plan.kind .. " through " .. (plan.panes and #plan.panes or 0) .. " pane") or tostring(why)))
end
note(string.format("T: %d of %d press distances vault", vaulted, tried))

-- S: standing still at the window for a second.
local plan, why = clientFind(0, 0, 0.5, 0, runUp(1.0))
check(plan == nil or plan.kind ~= "vault", "S standing at the window a second never vaults (" .. (plan and plan.kind or tostring(why)) .. ")")

-- Printed only: lateral offsets and heights into a jump.
local row = {}
for _, x in ipairs({ 0, 0.8, 1.2, 1.6, 2.0 }) do
    local p = clientFind(x, 0, 1.5, SPRINT, runUp(0))
    table.insert(row, string.format("x=%.1f:%s", x, p and p.kind or "-"))
end
note("lateral: " .. table.concat(row, " "))
row = {}
for _, h in ipairs({ 0.5, 1.5, 2.5, 3.5, 4.5, 5.5 }) do
    local p = clientFind(0, h, 1.5, SPRINT, runUp(0), false)
    table.insert(row, string.format("feet+%.1f:%s", h, p and p.kind or "-"))
end
note("into a jump: " .. table.concat(row, " "))

-- G: the server's view of a vault the client began at 2.9 (face distance), `late` seconds old while
-- still sprinting, or already partway through with the velocity the move holds at zero.
local cases = {}
for _, late in ipairs({ 0, 0.05, 0.1, 0.15, 0.2 }) do
    table.insert(cases, { z = face - 2.9 - SPRINT * late, v = FWD * SPRINT, what = string.format("%.2f s late", late) })
end
for _, z in ipairs({ face - 0.6, face + 0.2, T / 2 + 0.3 }) do
    table.insert(cases, { z = z, v = Vector3.zero, what = string.format("already at z=%.1f (pane at 0)", z) })
end
local took = 0
for _, case in ipairs(cases) do
    local pane = buildWindow()
    local c = body(0, 0, case.z, case.v)
    local found = panesAhead(c, c:FindFirstChild("HumanoidRootPart"))
    local ok = #found == 1 and found[1] == pane
    if ok then took = took + 1 end
    check(ok, "G server box, body " .. case.what .. ": " .. #found .. " pane(s)")
end
note(string.format("G: %d of %d server views take the pane", took, #cases))

-- F: a fence 3 studs in front of the window, the body vaulting the fence from 2.9 out, at every lag.
local spared, fences = 0, 0
for _, late in ipairs({ 0, 0.1, 0.2 }) do
    buildWindow()
    local fenceFar = face - 3
    part("Fence", -3, 3, 0, 3.5, fenceFar - 0.4, fenceFar)
    local c = body(0, 0, fenceFar - 0.4 - 2.9 - SPRINT * late, FWD * SPRINT)
    local found = panesAhead(c, c:FindFirstChild("HumanoidRootPart"))
    fences = fences + 1
    if #found == 0 then spared = spared + 1 end
    check(#found == 0, string.format("F fence vault %.1f s late leaves the window behind it (%d pane(s) taken)", late, #found))
end
return log, notes
"""

PLANTS = [
    # The run-up is ignored: the speed on the frame jump was read is all there is (the old behaviour).
    ("run-up ignored", "arrival", "best = math.max(best, sample.velocity:Dot(direction))", "best = best"),
    # The run-up never expires: a standing body could vault forever after one sprint.
    ("run-up never expires", "arrival", "if now - sample.at <= window then", "if true then"),
    # The server's box forgets the lag (the old 5.7-stud reach).
    ("no lag lead", "glass", "local GLASS_LAG = 0.25", "local GLASS_LAG = 0"),
    # The server's box starts at the root: a body already through misses its pane.
    ("no back allowance", "glass", "local GLASS_BACK = 1.2", "local GLASS_BACK = 0"),
    # The box ignores the obstacle it found and reaches the full length: the fence takes the window.
    ("face cap dropped", "glass", "reach = math.min(GLASS_REACH + lead, face.Distance + MovementConfig.Parkour.VaultMaxDepth + 0.5)",
     "reach = GLASS_REACH + GLASS_MAX_LEAD"),
]


def run(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    log, notes = lua.execute(HARNESS, lua.table_from(src), lua.table_from(src["consts"]))
    results = [(bool(log[i]["ok"]), log[i]["what"]) for i in range(1, len(log) + 1)]
    return results, [notes[i] for i in range(1, len(notes) + 1)]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = load(root)
    if "--plant" in sys.argv:
        caught = 0
        for name, key, old, new in PLANTS:
            planted = dict(src)
            assert old in planted[key], name
            planted[key] = planted[key].replace(old, new, 1)
            try:
                failed = [w for ok, w in run(planted)[0] if not ok]
            except Exception as err:
                failed = ["crashed: %s" % err]
            print("%-24s %s" % (name, ("CAUGHT (" + failed[0] + ")") if failed else "MISSED"))
            caught += bool(failed)
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    results, notes = run(src)
    for ok, what in results:
        print(("PASS " if ok else "FAIL ") + what)
    for line in notes:
        print("  " + line)
    failed = sum(1 for ok, _ in results if not ok)
    print("vault check: %d checks, %d failed" % (len(results), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
