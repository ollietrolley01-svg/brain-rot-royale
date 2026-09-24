"""Check: a player who leaves while their profile is still loading never leaves a session lock behind.

Runs the real ServerScriptService/Modules/PlayerData.lua under lupa, twice in one Lua state (server A
and server B, each its own module instance on the same stub DataStore), on a virtual clock. The stub
store is SLOW: every UpdateAsync yields for STORE_DELAY virtual seconds and applies its transform at
the end, as a write landing late does. Bootstrap's two leave paths are driven the way it runs them:
PlayerRemoving calls Release, and the join coroutine calls Release again if the player left during
Load.

Scenarios:
  left mid-claim      P joins A; while A's claim is in flight P leaves (Release finds nothing to save).
                      Then P joins B. B must load them, not kick them with "still being saved".
  rejoin mid-claim    P joins A and, during the claim, leaves and rejoins A as a new Player object. The
                      first Load is an orphan; the second session's lock must survive everything.
  rejoin mid-release  P leaves mid-claim, and rejoins A while the orphan's lock release is in flight.
                      The release must not clear the new session's lock.
  left while held     B holds P's profile; P joins A, waits on the lock and leaves. A must stop there:
                      no claim after the leave.

INVARIANTS: after the dust settles, the key is locked exactly when some server holds a live session for
the player; a departed player's next join elsewhere loads; nobody is kicked who should not be.

PLANTED FAULTS (permanent): the orphan release removed (the original bug), the release ignoring a newer
session on this server, and the wait loop's leave check removed. Each must turn the check red.

Run: python3 tools/playerdata_lock_check.py   (exit 0 = clean pass and every fault caught)
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("playerdata_lock_check: needs lupa (pip install lupa)")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "ServerScriptService", "Modules", "PlayerData.lua")
STORE_DELAY = 1.0


def luau_to_lua(source):
    # x += y  ->  x = x + y   (the only Luau-only syntax this file uses)
    return re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + \3", source, flags=re.M)


HARNESS = r"""
local source, STORE_DELAY = ...

-- A virtual clock and a scheduler: task.wait yields the running coroutine until the clock reaches it.
local now = 0
local sleepers = {}
local function schedule(co, at) table.insert(sleepers, { co = co, at = at }) end
local function spawn(fn, ...)
    local co = coroutine.create(fn)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(debug.traceback(co, err)) end
    return co
end
task = {
    wait = function(t)
        schedule(coroutine.running(), now + (t or 0))
        coroutine.yield()
    end,
    spawn = spawn,
}
tick = function() return now end
os.time = function() return 1000000 + math.floor(now) end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
local warnings = {}
warn = function(msg) table.insert(warnings, msg) end

local api = { writes = 0, calls = 0, slow = {} }
-- Runs the scheduler up to the absolute virtual time `untilTime`.
function api.run(untilTime)
    while true do
        table.sort(sleepers, function(a, b) return a.at < b.at end)
        local s = sleepers[1]
        if not s or s.at > untilTime then break end
        table.remove(sleepers, 1)
        now = math.max(now, s.at)
        local ok, err = coroutine.resume(s.co)
        if not ok then error(debug.traceback(s.co, err)) end
    end
    now = math.max(now, untilTime)
end
function api.now() return now end

-- The slow DataStore: one value per key, a transform applied at the END of the delay. api.slow[n]
-- overrides the delay of the n-th call.
local data = {}
local store = {}
function store:UpdateAsync(key, fn)
    api.calls = api.calls + 1
    task.wait(api.slow[api.calls] or STORE_DELAY)
    local result = fn(data[key])
    if result ~= nil then
        data[key] = result
        api.writes = api.writes + 1
    end
    return result
end
function api.lock(userId)
    local v = data["user_" .. userId]
    return v and v.lock and v.lock.jobId or nil
end

local function child(name)
    return { Name = name, WaitForChild = function(_, n) return child(n) end }
end
game = { JobId = "", GetService = function(_, name)
    if name == "DataStoreService" then
        return { GetDataStore = function() error("no DataStores in the sim") end }
    end
    return child(name)
end }
local stubs = {
    BrainrotData = { ClampStars = function(n) return n end, Get = function() return nil end },
    ProgressionData = { Default = function() return {} end, Reconcile = function() return {} end },
}
require = function(inst) return stubs[inst.Name] end

function api.server(jobId)
    local PlayerData = load(source, "PlayerData")()
    PlayerData._SetStoreForTest(store, jobId, { stale = 150, wait = 16, retry = 2 })
    local server = { PlayerData = PlayerData }
    -- Bootstrap's join: Load, then Release straight away if they left during it.
    function server.join(player)
        player.Parent = true
        spawn(function()
            PlayerData.Load(player)
            if not player.Parent then PlayerData.Release(player) end
            player.loaded = true
        end)
    end
    -- Bootstrap's PlayerRemoving.
    function server.leave(player)
        player.Parent = nil
        spawn(function() PlayerData.Release(player) end)
    end
    function server.live(player)
        return PlayerData.Get(player) ~= nil and PlayerData.CanSave(player)
    end
    return server
end
function api.player(userId, name)
    local p = { UserId = userId, Name = name, DisplayName = name }
    function p:Kick(msg) self.kicked = msg end
    return p
end
return api
"""


def scenarios(source):
    violations, notes = [], []

    def world():
        lua = LuaRuntime(unpack_returned_tuples=True)
        return lua.execute(HARNESS, source, STORE_DELAY)

    # 1. Left mid-claim, then joins another server.
    api = world()
    a, b = api.server("A"), api.server("B")
    p = api.player(1, "Leaver")
    a.join(p)
    api.run(0.5)          # A's claim is in flight
    a.leave(p)
    api.run(10)
    notes.append(f"left mid-claim: lock after A settles = {api.lock(1)}")
    if api.lock(1) is not None:
        violations.append(f"left mid-claim: server A left the lock on the key ({api.lock(1)}) for a player who is gone")
    p2 = api.player(1, "Leaver")
    b.join(p2)
    api.run(60)
    notes.append(f"  ...joins B: loaded={bool(p2.loaded)} live={b.live(p2)} kicked={p2.kicked!r}")
    if p2.kicked or not b.live(p2):
        violations.append(f"left mid-claim: B couldn't load them afterwards (kicked: {p2.kicked!r})")

    # 2. Leaves and rejoins the same server during the claim.
    api = world()
    a = api.server("A")
    p1, p2 = api.player(1, "Rejoiner"), api.player(1, "Rejoiner")
    a.join(p1)
    api.run(0.5)
    a.leave(p1)
    a.join(p2)
    api.run(30)
    notes.append(f"rejoin mid-claim: lock={api.lock(1)} live={a.live(p2)}")
    if not a.live(p2) or api.lock(1) != "A":
        violations.append(f"rejoin mid-claim: the new session is live={a.live(p2)}, lock={api.lock(1)} (want live and A)")

    # 3. Rejoins while the orphan's release is in flight.
    api = world()
    a = api.server("A")
    p1, p2 = api.player(1, "Bouncer"), api.player(1, "Bouncer")
    api.slow[2] = 3.0     # the orphan's release is slow to land: 1.0 -> 4.0
    a.join(p1)
    api.run(0.5)
    a.leave(p1)
    api.run(1.2)          # the claim has landed; the orphan's release is in flight
    a.join(p2)            # ...and this claim lands (2.2) before it does
    api.run(30)
    notes.append(f"rejoin mid-release: lock={api.lock(1)} live={a.live(p2)}")
    if not a.live(p2) or api.lock(1) != "A":
        violations.append(f"rejoin mid-release: the new session is live={a.live(p2)}, lock={api.lock(1)} (want live and A)")

    # 4. Leaves while waiting on a lock another server holds.
    api = world()
    a, b = api.server("A"), api.server("B")
    holder = api.player(1, "Waiter")
    b.join(holder)
    api.run(5)
    p = api.player(1, "Waiter")
    a.join(p)
    api.run(9.5)          # A is between retries against B's live lock (next one at 11)
    a.leave(p)
    writes = api.writes
    b.leave(holder)       # B releases: a claim now would succeed
    api.run(60)
    extra = api.writes - writes - 1  # B's release is one write
    notes.append(f"left while held: writes by A after the leave = {extra}, lock={api.lock(1)}")
    if extra != 0:
        violations.append(f"left while held: A kept going after the player left and wrote {extra} time(s)")
    if api.lock(1) is not None:
        violations.append(f"left while held: the key is still locked by {api.lock(1)}")
    return violations, notes


RELEASE_CALL = "\t\t\t\t\treleaseOrphanClaim(key, player.UserId, version)\n"
MUTANTS = {
    "orphan release removed (the original bug)": (RELEASE_CALL, ""),
    "release ignores a newer session here": (
        "if owners[userId] ~= nil or not lock", "if not lock"),
    "wait loop's leave check removed": (
        "\t\t\tif owners[player.UserId] ~= player then\n\t\t\t\treturn reconcile(nil)\n\t\t\tend\n\t\t\t-- tryClaim", "\t\t\t-- tryClaim"),
}


def main():
    with open(SOURCE, encoding="utf-8") as f:
        source = luau_to_lua(f.read())
    violations, notes = scenarios(source)
    for n in notes:
        print("  " + n)
    print(f"clean: {len(violations)} violations")
    for v in violations:
        print("  " + v)
    ok = not violations
    for label, (old, new) in MUTANTS.items():
        if old not in source:
            print(f"FAIL: planted fault '{label}' could not be applied (source changed; update the mutant)")
            ok = False
            continue
        bad, _ = scenarios(source.replace(old, new, 1))
        caught = len(bad) > 0
        print(f"planted fault '{label}': {'CAUGHT' if caught else 'MISSED'}" + (f", first: {bad[0]}" if bad else ""))
        ok = ok and caught
    print("playerdata_lock_check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
