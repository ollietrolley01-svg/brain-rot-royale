"""Behaviour check for the sprint that other players see (#89, #13), without Studio.

Runs the real "Sprinting, for everyone else to see" block of ServerScriptService/Modules/MovementService.lua
and the real sprintingNow of StarterPlayerScripts/GunPoseClient.client.lua in a Lua interpreter (lupa),
with humanoids, characters and their signals mocked, and walks the sprint through start, stop, death,
a vehicle seat, a respawn and a repeated call.

The invariant: the `Sprinting` attribute is on exactly while MatchService says sprint AND the body is
alive and not seated, and nothing is left watching a humanoid that has died or gone.

    python tools/remote_pose_check.py .            the checks
    python tools/remote_pose_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("remote_pose_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + \3", source, flags=re.M)


def between(path, start, end):
    text = open(path, encoding="utf-8").read()
    a = text.index(start)
    b = text.index(end, a)
    return luau_to_lua(text[a:b])


def sources(root):
    service = between(os.path.join(root, "ServerScriptService", "Modules", "MovementService.lua"),
                      "local sprintWatched = {}", "-- Parkour: the pose attribute")
    service = service[:service.rindex("\n--------")]
    gun = between(os.path.join(root, "StarterPlayerScripts", "GunPoseClient.client.lua"),
                  "local function sprintingNow", "local function blend")
    return service, gun


HARNESS = r"""
local serviceSrc, gunSrc = ...
local log = {}
local function check(ok, what) table.insert(log, { ok = ok and true or false, what = what }) end

local function signal()
    local s = { handlers = {} }
    function s:Connect(fn)
        local c = { fn = fn, live = true }
        function c:Disconnect() self.live = false end
        table.insert(s.handlers, c)
        return c
    end
    function s:Fire(...)
        for _, c in ipairs(s.handlers) do if c.live then c.fn(...) end end
    end
    function s:Live()
        local n = 0
        for _, c in ipairs(s.handlers) do if c.live then n = n + 1 end end
        return n
    end
    return s
end

local writes = 0
local function newBody()
    local character = { attrs = {}, inGame = true }
    function character:GetAttribute(k) return self.attrs[k] end
    function character:SetAttribute(k, v) writes = writes + 1; self.attrs[k] = v end
    local humanoid = { Health = 100, Sit = false, Parent = character,
        Died = signal(), Seated = signal(), AncestryChanged = signal() }
    function humanoid:IsDescendantOf() return character.inGame end
    return character, humanoid
end

local MovementService = {}
local game = {}
local chunk = assert(load("local MovementService, game = ...\n" .. serviceSrc ..
    "\nreturn function() local n = 0 for _ in pairs(sprintWatched) do n = n + 1 end return n end"))
local watching = chunk(MovementService, game)

-- 1. start and stop
local c, h = newBody()
check(MovementService.SetSprintPose(h, true) == true and c.attrs.Sprinting == true, "sprint on sets the attribute")
MovementService.SetSprintPose(h, false)
check(c.attrs.Sprinting == nil, "sprint off clears it")

-- 2. a repeated verdict writes nothing (applySpeed runs on every boost and toggle)
MovementService.SetSprintPose(h, true)
local before = writes
for _ = 1, 10 do MovementService.SetSprintPose(h, true) end
check(writes == before, "ten repeats of the same verdict write the attribute 0 times (wrote " .. (writes - before) .. ")")
check(h.Died:Live() == 1 and h.Seated:Live() == 1, "one watcher per humanoid, however often it is set")

-- 3. seated in a vehicle mid-sprint: applySpeed is not called, the signal must clear it
h.Sit = true
h.Seated:Fire(true)
check(c.attrs.Sprinting == nil, "taking a seat mid-sprint clears it")
check(MovementService.SetSprintPose(h, true) == false and c.attrs.Sprinting == nil, "a seated body is never set sprinting")
h.Sit = false
h.Seated:Fire(false)
check(MovementService.SetSprintPose(h, true) == true and c.attrs.Sprinting == true, "out of the seat, sprint comes back")

-- 4. death mid-sprint: applySpeed returns early for a dead humanoid, so Died must clear it
h.Health = 0
h.Died:Fire()
check(c.attrs.Sprinting == nil, "dying mid-sprint clears it")
check(MovementService.SetSprintPose(h, true) == false and c.attrs.Sprinting == nil, "a dead body is never set sprinting")
check(watching() == 0, "nothing left watching a dead humanoid (watching " .. watching() .. ")")

-- 5. a body that leaves without dying (respawn, round reset) is let go
local c2, h2 = newBody()
MovementService.SetSprintPose(h2, true)
c2.inGame = false
h2.AncestryChanged:Fire()
check(watching() == 0 and h2.Died:Live() == 0, "a removed humanoid is let go")

-- 6. a humanoid with no character does nothing
check(MovementService.SetSprintPose({ Parent = nil }, true) == false, "no character, no attribute")

-- 7. the client: drawn sprinting only when told, moving, and not mid-slide/climb/vault
local SPRINT_MIN_SPEED = 4
local Vector3 = { new = function(x, y, z) return { Magnitude = math.sqrt(x * x + y * y + z * z) } end }
local sprintingNow = assert(load("local SPRINT_MIN_SPEED, Vector3 = ...\n" .. gunSrc .. "\nreturn sprintingNow"))(SPRINT_MIN_SPEED, Vector3)
local function char(attrs) return { GetAttribute = function(_, k) return attrs[k] end } end
local function root(x, y, z) return { AssemblyLinearVelocity = { X = x, Y = y, Z = z } } end
local cases = {
    { char({ Sprinting = true }), root(20, 0, 0), true, "told and running" },
    { char({ Sprinting = true }), root(0, -50, 0), false, "told but only falling" },
    { char({ Sprinting = true }), root(1, 0, 1), false, "told but standing still" },
    { char({}), root(20, 0, 0), false, "running fast but not sprinting" },
    { char({ Sprinting = true, Parkour = "slide" }), root(30, 0, 0), false, "sliding: the slide owns the body" },
}
for _, case in ipairs(cases) do
    check(sprintingNow(case[1], case[2]) == case[3], "client: " .. case[4])
end

return log
"""

PLANTS = [
    ("Died handler forgets to clear", "service",
     "humanoid.Died:Connect(function()\n\t\t\t\tclearSprintPose(humanoid)", "humanoid.Died:Connect(function()\n\t\t\t\tlocal _ = humanoid"),
    ("Sit ignored", "service", "and not humanoid.Sit", ""),
    ("seat signal ignored", "service", "if active then\n\t\t\t\t\tclearSprintPose(humanoid)", "if false then\n\t\t\t\t\tclearSprintPose(humanoid)"),
    ("watchers never let go", "service", "sprintWatched[humanoid] = nil", "local _ = nil"),
    ("rewrite every call", "service", "if (character:GetAttribute(\"Sprinting\") == true) ~= wanted then", "if true then"),
    ("client ignores the slide", "gun", " or character:GetAttribute(\"Parkour\") ~= nil", ""),
]


def run(service, gun):
    lua = LuaRuntime(unpack_returned_tuples=True)
    log = lua.execute(HARNESS, service, gun)
    return [(bool(log[i]["ok"]), log[i]["what"]) for i in range(1, len(log) + 1)]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    service, gun = sources(root)
    if "--plant" in sys.argv:
        caught = 0
        for name, target, old, new in PLANTS:
            s, g = service, gun
            if target == "service":
                assert old in s, name
                s = s.replace(old, new, 1)
            else:
                assert old in g, name
                g = g.replace(old, new, 1)
            try:
                failed = [w for ok, w in run(s, g) if not ok]
            except Exception as err:  # a fault that crashes is caught too
                failed = ["crashed: %s" % err]
            print("%-32s %s" % (name, ("CAUGHT (" + failed[0] + ")") if failed else "MISSED"))
            caught += bool(failed)
        print("planted faults caught: %d of %d" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    results = run(service, gun)
    for ok, what in results:
        print(("PASS " if ok else "FAIL ") + what)
    failed = sum(1 for ok, _ in results if not ok)
    print("remote pose check: %d checks, %d failed" % (len(results), failed))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
