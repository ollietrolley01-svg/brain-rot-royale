"""Behaviour check for #97 hit registration: the server rewind (HITREG_DESIGN.md option A).

Runs the real ServerScriptService/Modules/LagCompensation.lua in lupa against tools/hitreg_mocks.lua
(Vector3, CFrame, a character rig, and a world raycast written independently of the module), and
reads CombatService.lua's source for the parts that can't run here (it uses Luau's `continue`).

    python tools/hitreg_rewind_check.py .            the checks
    python tools/hitreg_rewind_check.py . --plant    the planted faults; every one must be caught

What it proves: a victim strafing at BaseWalkSpeed, aimed at dead centre by a shooter whose ping is
0-200 ms, is struck at the shooter's aim point (the torso, or the Head when the head was aimed at);
a ping over the cap is ruled on the present and misses; the rewind is computed from the server's own
GetNetworkPing and nothing else on the Player is read; a bot shooter is never rewound; a body a
piercing shot has passed is never struck again; the shooter-wins cover trade holds; a player's own
Roblox hat no longer swallows a headshot; the ring buffer writes over its entries once full instead
of allocating one per body per step; and CombatService's shot budget is untouched.

What it cannot prove: real ping. GetNetworkPing is a parameter here; tools/hitreg_rewind_probe.lua
measures it in a live session.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("hitreg_rewind_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


HARNESS = r"""
local M, lagSrc, walkSpeed = ...
local Vector3, CFrame = M.Vector3, M.CFrame
_G.Vector3, _G.CFrame, _G.Enum, _G.RaycastParams, _G.workspace = Vector3, CFrame, M.Enum, M.RaycastParams, M.workspace
table.clone = function(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
_G.task = { spawn = function(fn, ...) fn(...) end }

local registered = {}
local Combatants = {
    All = function() return registered end,
    IsPlayer = function(token) return type(token) == "table" and token.__player == true end,
}
local heartbeat
_G.game = { GetService = function(_, name)
    return { Heartbeat = { Connect = function(_, fn) heartbeat = fn end } }
end }
local script = { Parent = { WaitForChild = function(_, name) return Combatants end } }
local chunk = assert(load(lagSrc, "LagCompensation", "t", setmetatable({ script = script, require = function(m) return m end }, { __index = _G })))
local Lag = chunk()
assert(heartbeat, "LagCompensation never hooked Heartbeat")

-- A Player stand-in that records every key read off it: only GetNetworkPing may be.
local reads = {}
local function player(ping)
    local fields = { __player = true, GetNetworkPing = function() return ping end }
    return setmetatable({}, { __index = function(_, key)
        if key ~= "__player" then reads[key] = true end
        return fields[key]
    end })
end

local out = {}
local function note(ok, line) table.insert(out, { ok = ok, line = line }) end

local EYE = Vector3.new(0, 1.5, 0)
local SHOOTER = Vector3.new(0, 3, 0)
local STEP = 1 / 60

-- One run: a victim 40 studs downrange crossing square on at `speed`, sampled at 60 Hz for half a
-- second. The shooter fires at `fireAt` at whatever `aim` names on the victim AS IT WAS THEN; the
-- shot arrives `ping` later. Returns the struck part's name (or nil) and the result.
local function run(opts)
    for k in pairs(registered) do registered[k] = nil end
    for i = #M.workspace._children, 1, -1 do table.remove(M.workspace._children, i) end
    M.walls = {}
    Lag.Clear()
    local shooterChar = M.character("Shooter", CFrame.new(SHOOTER.X, SHOOTER.Y, SHOOTER.Z))
    local victim, root = M.character("Victim", CFrame.new(-6, 3, -40))
    -- A bot record that even answers GetNetworkPing: bots are ruled on the present because they are
    -- bots, not because they happen to have no ping.
    local token = opts.bot and { isBot = true, GetNetworkPing = function() return opts.ping or 0 end } or player(opts.ping)
    registered[shooterChar] = token
    registered[victim] = { isBot = true }
    if opts.wall then M.wall("Cover", opts.wall.centre, opts.wall.size) end

    local fireAt, aimPoint = opts.fireAt or 0.25, nil
    local t = 0
    local arrival = fireAt + (opts.ping or 0)
    while t <= arrival + 1e-9 do
        M.clock = t
        rawget(root, "_props").CFrame = CFrame.new(-6 + opts.speed * t, 3, -40)
        heartbeat()
        if not aimPoint and t >= fireAt - 1e-9 then
            if opts.aim == "HeadTop" then
                -- the top of the head, where a hat sits over it
                aimPoint = victim:FindFirstChild("Head").CFrame.Position + Vector3.new(0, 0.5, 0)
            else
                aimPoint = victim:FindFirstChild(opts.aim or "UpperTorso").CFrame.Position
            end
        end
        t = t + STEP
    end
    M.clock = arrival
    local origin = SHOOTER + EYE
    local vector = (aimPoint - origin).Unit * 300
    local params = M.RaycastParams.new()
    params.FilterDescendantsInstances = { shooterChar }
    if opts.pierced then table.insert(params.FilterDescendantsInstances, victim) end
    local at = Lag.RewindTime(token, arrival)
    local result = Lag.Raycast(origin, vector, params, at)
    -- How far the rewound root is from where the victim really stood when the shot was fired.
    local error = nil
    if at then
        error = (Lag.RootAt(victim, at, arrival).Position - Vector3.new(-6 + opts.speed * fireAt, 3, -40)).Magnitude
    end
    return result and result.Instance.Name or nil, result, at, arrival, error
end

local SPEED = walkSpeed
-- A torso shot lands on the body: the torso, or the root box inside it (Roblox's HumanoidRootPart is
-- queryable, and CombatService pays it as a body hit).
local BODY = { UpperTorso = true, LowerTorso = true, HumanoidRootPart = true }

-- 1. Geometry: pings 0..200 ms land on the part aimed at.
for _, ms in ipairs({ 0, 30, 60, 100, 150, 200 }) do
    local name, _, _, _, err = run({ speed = SPEED, ping = ms / 1000 })
    local placed = ms == 0 or (err ~= nil and err < 0.05)
    note(BODY[name] == true and placed, string.format("strafing %d studs/s, ping %3d ms, aimed at torso -> %s (victim put back within %s studs of where they were)", SPEED, ms, tostring(name), err and string.format("%.3f", err) or "- (no rewind at 0 ms)"))
end
for _, ms in ipairs({ 60, 150 }) do
    local name = run({ speed = SPEED, ping = ms / 1000, aim = "Head" })
    note(name == "Head", string.format("strafing, ping %3d ms, aimed at head -> %s (the part, not just the victim)", ms, tostring(name)))
end

-- 2. The same shots WITHOUT the rewind miss (the instrument can fail): ruled on the present.
local miss = 0
for _, ms in ipairs({ 150, 200 }) do
    -- a bot token is ruled on the present, so this is the same shot with no rewind
    if run({ speed = SPEED, ping = ms / 1000, bot = true }) == nil then miss = miss + 1 end
end
note(miss == 2, string.format("control: the same 150/200 ms shots ruled on the present miss %d of 2", miss))

-- 3. The cap: 250 ms is ruled on the present, not rewound to 200 and not extrapolated.
do
    local name, _, at = run({ speed = SPEED, ping = 0.25 })
    note(at == nil and name == nil, string.format("ping 250 ms (over the 200 ms cap) -> rewind %s, struck %s (present: a miss)", tostring(at), tostring(name)))
    local name2, _, at2 = run({ speed = 0, ping = 0.25 })
    note(at2 == nil and BODY[name2] == true, "ping 250 ms at a STANDING victim still lands (present rules, the shot isn't thrown away)")
end

-- 4. The interval is the server's reading and nothing else: only GetNetworkPing was read.
do
    for k in pairs(reads) do reads[k] = nil end
    run({ speed = SPEED, ping = 0.1 })
    local other = {}
    for k in pairs(reads) do if k ~= "GetNetworkPing" then table.insert(other, k) end end
    table.sort(other)
    note(reads.GetNetworkPing == true and #other == 0, "keys read off the shooting Player: GetNetworkPing" .. (#other > 0 and (" AND " .. table.concat(other, ", ")) or " only"))
    local _, _, at, arrival = run({ speed = SPEED, ping = 0.1 })
    note(at and math.abs((arrival - at) - 0.1) < 1e-9, string.format("rewind = arrival - ping exactly (%.3f s)", at and (arrival - at) or -1))
end

-- 5. Bots are never rewound.
do
    local _, _, at = run({ speed = SPEED, ping = 0.1, bot = true })
    note(at == nil, "a bot shooter's shot is ruled on the present")
end

-- 6. A body a piercing shot already passed is never struck again.
do
    local name = run({ speed = SPEED, ping = 0.1, pierced = true })
    note(name == nil, "a victim already in the shot's filter (pierced) is not struck: " .. tostring(name))
end

-- 7. Cover trade, shooter wins: a wall now between the shooter and where the victim IS doesn't save
--    them from a shot fired while they were in the open.
do
    local ping = 0.15
    local arrival = 0.25 + ping
    local nowX = -6 + SPEED * arrival
    local wall = { centre = Vector3.new(nowX * 0.5 + 0.2, 3, -20), size = Vector3.new(1, 10, 1) }
    local name = run({ speed = SPEED, ping = ping, wall = wall })
    note(BODY[name] == true, "victim behind cover at arrival, in the open when shot (150 ms): struck " .. tostring(name))
    -- and a wall that stood between them WHEN THE SHOT WAS FIRED still stops it
    local thenX = -6 + SPEED * 0.25
    local wall2 = { centre = Vector3.new(thenX * 0.5, 3, -20), size = Vector3.new(1, 10, 1) }
    local name2, result = run({ speed = SPEED, ping = ping, wall = wall2 })
    note(name2 == "Cover", "a wall between them when the shot was fired stops it: struck " .. tostring(name2))
end

-- 8. A player's own Roblox hat doesn't swallow a rewound headshot aimed through it.
do
    local name = run({ speed = SPEED, ping = 0.1, aim = "HeadTop" })
    note(name == "Head", "rewound shot at the top of the head, a queryable hat Handle over it: " .. tostring(name))
end

-- 9. The ring buffer reuses its entries once full (findings I10): after the first lap, Record allocates
--    no sample tables, and every rewind above (1-8; a run past 20 steps reads reused entries) is unchanged.
do
    local history
    for i = 1, 20 do
        local name, value = debug.getupvalue(Lag.Record, i)
        if name == nil then break end
        if name == "history" then history = value end
    end
    Lag.Clear()
    for k in pairs(registered) do registered[k] = nil end
    local body, root = M.character("Ring", CFrame.new(0, 3, 0))
    registered[body] = { isBot = true }
    local n = Lag.Samples
    for i = 1, n do M.clock = i * STEP; heartbeat() end
    local first = {}
    local entry = history and history[body]
    for i = 1, n do first[i] = entry and entry.samples[i] end
    for i = n + 1, 3 * n + 7 do
        M.clock = i * STEP
        rawget(root, "_props").CFrame = CFrame.new(i, 3, 0)
        heartbeat()
    end
    local same = entry ~= nil and #entry.samples == n
    for i = 1, n do same = same and entry.samples[i] == first[i] end
    note(history ~= nil and same, string.format("after one lap the ring's %d sample tables are written over, not replaced", n))
    local at = (3 * n + 2.5) * STEP
    local p = Lag.RootAt(body, at, (3 * n + 7) * STEP).Position
    note(math.abs(p.X - (3 * n + 2.5)) < 1e-6, string.format("...and a rewind into the reused entries is exact (x %.3f, want %.1f)", p.X, 3 * n + 2.5))
end

return out
"""


def load_lag(root, plant=None):
    src = read(root, "ServerScriptService", "Modules", "LagCompensation.lua")
    for before, after in plant or []:
        if before not in src:
            sys.exit("hitreg_rewind_check: plant target missing: " + before)
        src = src.replace(before, after, 1)
    return luau_to_lua(src)


def walk_speed(root):
    m = re.search(r"MatchConfig\.BaseWalkSpeed\s*=\s*([\d.]+)", read(root, "ReplicatedStorage", "Shared", "MatchConfig.lua"))
    return float(m.group(1)) if m else 18.0


def dynamic(root, plant=None):
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools", "hitreg_mocks.lua"))
    run = lua.execute("return function(...) " + HARNESS + " end")
    rows = run(mocks, load_lag(root, plant), walk_speed(root))
    return [(bool(r["ok"]), r["line"]) for r in rows.values()]


def budget(root, source=None):
    """ShotCredit/SpendShot: the budget #97's first half landed. Run as written, against the rule."""
    src = source or read(root, "ServerScriptService", "Modules", "CombatService.lua")
    lines = []
    burst = re.search(r"^local FIRE_BURST = (\d+)", src, re.M)
    a = src.index("function CombatService.ShotCredit")
    b = src.index("\nend\n", src.index("function CombatService.SpendShot")) + 5
    lua = LuaRuntime()
    block = "local CombatService = {}\nlocal FIRE_BURST = " + burst.group(1) + "\n" + luau_to_lua(src[a:b]) + "\nreturn CombatService"
    cs = lua.execute(block)
    loadout = lua.table()
    fired = 0
    t = 0.0
    step = 0.001
    def_ = lua.table_from({"fireRate": 10})
    while t < 2.0 - 1e-9:
        credit = cs.ShotCredit(loadout, def_, t)
        if credit >= 1:
            cs.SpendShot(loadout, credit, t)
            fired += 1
        t += step
    # A held trigger at 1 kHz for 2 s at fireRate 10: the burst (2) then one per 0.1 s.
    ok = fired == 2 + 19
    lines.append((ok, "shot budget, 1 kHz spam for 2 s at fireRate 10: %d shots (burst %s, then fireRate)" % (fired, burst.group(1))))
    fire = src[src.index("function CombatService.Fire("):]
    fire = fire[: fire.index("\nend\n")]
    spend = fire.index("CombatService.SpendShot(")
    rewind = fire.index("LagCompensation.RewindTime(")
    credit = fire.index("CombatService.ShotCredit(")
    lines.append((credit < spend < rewind, "Fire settles the budget (ShotCredit, SpendShot) before it works out the rewind"))
    sig = re.search(r"function CombatService\.Fire\(([^)]*)\)", src).group(1)
    lines.append((sig.replace(" ", "") == "player,aimPoint", "Fire takes (%s): no client time can reach the rewind" % sig))
    pellet = src[src.index("local function firePellet("):]
    pellet = pellet[: pellet.index("\nend\n")]
    lines.append(("workspace:Raycast" not in pellet and "LagCompensation.Raycast(" in pellet and "rewindTo)" in pellet,
                  "firePellet raycasts only through LagCompensation.Raycast(..., rewindTo)"))
    lines.append(("firePellet(player, character, origin, pelletDirection, def, rewindTo)" in fire,
                  "every pellet of a shot is handed the same rewindTo"))
    lines.extend(accessories(root, src))
    return lines


ACCESSORY_HARNESS = r"""
local M, block = ...
local later
local character = M.character("Wearer", M.CFrame.new(0, 3, 0))
rawset(character._props, "DescendantAdded", { Connect = function(_, fn) later = fn end })
local CombatService = assert(load("local CombatService = {}\n" .. block .. "\nreturn CombatService"))()
CombatService.WatchAccessories(character)
-- A hat that loads after the character spawned, as Roblox's avatar accessories do.
local hair = M.instance("Accessory", "Hair", character)
local strand = M.instance("Part", "Handle", hair, { CanQuery = true, Size = M.Vector3.new(1, 1, 1) })
if later then later(hair) later(strand) end
local handles, off, body, bodyOn = 0, 0, 0, 0
for _, part in ipairs(character:GetDescendants()) do
    if part:IsA("BasePart") then
        if part:FindFirstAncestorWhichIsA("Accessory") then
            handles = handles + 1
            if part.CanQuery == false then off = off + 1 end
        else
            body = body + 1
            if part.CanQuery then bodyOn = bodyOn + 1 end
        end
    end
end
return handles, off, body, bodyOn
"""


def accessories(root, src):
    a = src.index("local function unqueryable(")
    b = src.index("\nend\n", src.index("function CombatService.WatchAccessories")) + 5
    lua = LuaRuntime(unpack_returned_tuples=True)
    mocks = lua.execute(read(root, "tools", "hitreg_mocks.lua"))
    run = lua.execute("return function(...) " + ACCESSORY_HARNESS + " end")
    handles, off, body, on = run(mocks, src[a:b])
    watched = "CombatService.WatchAccessories(character)" in src[src.index("local function characterAdded("):]
    return [
        (handles == 2 and off == 2 and body == on and body > 0,
         "a player's own accessories: %d of %d Handles made unqueryable (one arrived late); body parts still queryable %d of %d" % (off, handles, on, body)),
        (watched, "every player's character is watched for accessories at spawn (characterAdded)"),
    ]


PLANTS = [
    ("rewind the wrong way", [("return arrival - ping", "return arrival + ping")]),
    ("no cap", [("ping > LagCompensation.Cap", "ping > 10")]),
    ("rewind to the cap instead of the present", [("or ping > LagCompensation.Cap then\n\t\treturn nil", "then\n\t\treturn nil\n\telseif ping > LagCompensation.Cap then\n\t\treturn arrival - LagCompensation.Cap")]),
    ("resolve to the victim, not the part (headshots lost)", [("best, bestPart, bestNormal = t, part, normal", "best, bestPart, bestNormal = t, root, normal")]),
    ("read a client timestamp", [("return arrival - ping", "return (shooterToken.ShotSentAt or arrival) - ping")]),
    ("rewind bots too", [("if not Combatants.IsPlayer(shooterToken) then\n\t\treturn nil\n\tend", "if false then end")]),
    ("ignore the shot's filter", [("if character.Parent and not excluded[character] then", "if character.Parent then"), ("if not skip then", "if true then")]),
    ("hats swallow headshots", [("part.CanQuery and part:FindFirstAncestorWhichIsA(\"Accessory\") == nil", "part.CanQuery")]),
    ("no rewind at all", [("sample.t <= at", "sample.t <= math.huge")]),
    ("a new sample table every step (the old Record)", [("\t\t\tif sample then\n\t\t\t\tsample.cframe, sample.t = root.CFrame, now\n\t\t\telse",
                                                          "\t\t\tif false then\n\t\t\telse")]),
    ("a reused entry keeps its old time", [("sample.cframe, sample.t = root.CFrame, now", "sample.cframe = root.CFrame")]),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        caught = 0
        for name, plant in PLANTS:
            rows = dynamic(root, plant)
            failed = [line for ok, line in rows if not ok]
            print(("CAUGHT  " if failed else "MISSED  ") + name + (("  <- " + failed[0]) if failed else ""))
            caught += bool(failed)
        src = read(root, "ServerScriptService", "Modules", "CombatService.lua")
        source_plants = [
            ("shot budget loosened (FIRE_BURST 3)", "local FIRE_BURST = 2", "local FIRE_BURST = 3"),
            ("late accessories missed", "\tcharacter.DescendantAdded:Connect(unqueryable)\n", ""),
        ]
        for name, before, after in source_plants:
            if before not in src:
                sys.exit("hitreg_rewind_check: plant target missing: " + before)
            bad = budget(root, src.replace(before, after, 1))
            hit = any(not ok for ok, _ in bad)
            print(("CAUGHT  " if hit else "MISSED  ") + name)
            caught += hit
        total = len(PLANTS) + len(source_plants)
        print("hitreg_rewind_check plants: %d of %d caught" % (caught, total))
        sys.exit(0 if caught == total else 1)
    rows = [r for r in dynamic(root) if r[1]] + budget(root)
    for ok, line in rows:
        print(("ok    " if ok else "FAIL  ") + line)
    failed = sum(1 for ok, _ in rows if not ok)
    print("hitreg_rewind_check: %d checks, %d failed" % (len(rows), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
