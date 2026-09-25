"""Behaviour check for the playtime awards (#76) and the daily streak prize (#77), without Studio.

Runs the real ServerScriptService/Modules/PlaytimeService.lua and the real ProgressionData.Playtime
block in a Lua interpreter (lupa), with Players, characters, task.wait and RewardService mocked,
and drives the service's clock one sample at a time.

    python tools/playtime_check.py .            the checks
    python tools/playtime_check.py . --plant    the planted faults; every one must be caught

Needs `pip install lupa`. Luau's compound assignments are rewritten to plain Lua before loading.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("playtime_check: needs lupa (pip install lupa)")


def luau_to_lua(source):
    # x += y  ->  x = x + y   (the only Luau-only syntax these files use)
    return re.sub(r"^(\s*)([\w.\[\]]+) \+= (.+)$", r"\1\2 = \2 + \3", source, flags=re.M)


def playtime_block(root):
    path = os.path.join(root, "ReplicatedStorage", "Shared", "ProgressionData.lua")
    text = open(path, encoding="utf-8").read()
    start = text.index("ProgressionData.Playtime = {")
    end = text.index("return ProgressionData", start)
    return "local ProgressionData = {}\n" + text[start:end] + "return ProgressionData\n"


def daily_cycle(root):
    path = os.path.join(root, "ReplicatedStorage", "Shared", "BattlePassData.lua")
    text = open(path, encoding="utf-8").read()
    block = text[text.index("BattlePassData.DailyRewards = {"):]
    block = block[:block.index("\n}") + 2]
    return len(re.findall(r"\{ kind =", block))


def service_source(root):
    path = os.path.join(root, "ServerScriptService", "Modules", "PlaytimeService.lua")
    return luau_to_lua(open(path, encoding="utf-8").read())


HARNESS = r"""
local progressionSrc, serviceSrc = ...
local awards = {}
local listeners = { added = {}, removing = {} }
local playerList = {}
local loops = {}

local Vec = {}
Vec.__index = Vec
local function vec(x, y, z)
    return setmetatable({ X = x, Y = y, Z = z, Magnitude = math.sqrt(x * x + y * y + z * z) }, Vec)
end
Vec.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end

local function signal(list)
    return { Connect = function(_, fn) table.insert(list, fn) end }
end
local Players = {
    PlayerAdded = signal(listeners.added),
    PlayerRemoving = signal(listeners.removing),
    GetPlayers = function() return playerList end,
}
local function child(name) return { Name = name, WaitForChild = function(self, n) return child(n) end } end
game = { GetService = function(_, name) if name == "Players" then return Players end return child(name) end }
script = { Parent = child("Modules") }
task = {
    spawn = function(fn) table.insert(loops, coroutine.create(fn)) end,
    wait = function() coroutine.yield() end,
}
warn = function(...) error(table.concat({ ... }, " ")) end

local ProgressionData = load(progressionSrc, "ProgressionData")()
local RewardService = {
    AwardBonusCoins = function(player, amount, reason)
        table.insert(awards, { player = player.Name, amount = amount, reason = reason })
    end,
}
require = function(inst)
    if inst.Name == "ProgressionData" then return ProgressionData end
    if inst.Name == "RewardService" then return RewardService end
    error("unexpected require " .. tostring(inst.Name))
end

local Service = load(serviceSrc, "PlaytimeService")()

-- A player whose `mode` says what their character does each sample:
--   "run"   moves 10 studs a sample        "still"  stands in one spot
--   "dead"  no living character             "jitter" moves 1 stud a sample (under MoveStuds)
local api = {}
function api.addPlayer(name, mode)
    local p = { Name = name, Parent = true, mode = mode, step = 0 }
    table.insert(playerList, p)
    for _, fn in ipairs(listeners.added) do fn(p) end
    return p
end
function api.start()
    Service.Start()
    -- Run each loop up to its first task.wait, as the scheduler does on the frame it is spawned.
    for _, co in ipairs(loops) do assert(coroutine.resume(co)) end
end
function api.run(samples)
    for _ = 1, samples do
        for _, p in ipairs(playerList) do
            p.step = p.step + 1
            if p.mode == "dead" then
                p.Character = nil
            else
                local d = (p.mode == "run" and 10) or (p.mode == "jitter" and 1) or 0
                local root = { Position = vec(d * p.step, 0, 0) }
                local hum = { Health = 100 }
                p.Character = {
                    FindFirstChildOfClass = function(_, c) if c == "Humanoid" then return hum end end,
                    FindFirstChild = function(_, c) if c == "HumanoidRootPart" then return root end end,
                }
            end
        end
        for _, co in ipairs(loops) do
            local ok, err = coroutine.resume(co)
            if not ok then error(err) end
        end
    end
end
function api.total(name)
    local sum, count = 0, 0
    for _, a in ipairs(awards) do if a.player == name then sum = sum + a.amount; count = count + 1 end end
    return sum, count
end
function api.config() return ProgressionData.Playtime end
function api.coins(n) return ProgressionData.PlaytimeCoins(n) end
return api
"""


def build(progression_src, service_src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    return lua.execute(HARNESS, progression_src, service_src)


def checks(progression_src, service_src, cycle):
    """Returns a list of (name, ok, detail)."""
    api = build(progression_src, service_src)
    cfg = api.config()
    per_award = cfg.IntervalSeconds // cfg.SampleSeconds
    per_hour = 3600 // cfg.SampleSeconds
    for name, mode in (("runner", "run"), ("statue", "still"), ("ghost", "dead"), ("fidget", "jitter")):
        api.addPlayer(name, mode)
    api.start()
    api.run(per_hour)
    hour1 = api.total("runner")
    api.run(per_hour)
    hour2 = api.total("runner")
    results = []
    expected1 = sum(api.coins(n) for n in range(1, 3600 // cfg.IntervalSeconds + 1))
    results.append(("an active player's first hour pays the ladder", hour1[0] == expected1,
                    f"{hour1[0]} coins in {hour1[1]} awards, expected {expected1}"))
    results.append(("the second hour pays at the cap", hour2[0] - hour1[0] == (3600 // cfg.IntervalSeconds) * cfg.CapCoins,
                    f"{hour2[0] - hour1[0]} coins"))
    # All time in the server counts (Oliver, 2026-09-25): standing still, shuffling and being dead or
    # spectating are paid exactly what a running player is paid.
    for name in ("statue", "fidget", "ghost"):
        results.append((f"{name} is paid the same as a running player", api.total(name) == hour2,
                        f"{api.total(name)[0]} coins in {api.total(name)[1]} awards in 2 h, runner {hour2[0]}"))
    ladder = [api.coins(n) for n in range(1, 10)]
    results.append(("the ladder climbs then holds at the cap",
                    all(b >= a for a, b in zip(ladder, ladder[1:])) and ladder[-1] == cfg.CapCoins and ladder[0] < cfg.CapCoins,
                    " ".join(str(x) for x in ladder)))
    results.append(("an award every IntervalSeconds: 6 in each hour", hour1[1] == 3600 // cfg.IntervalSeconds,
                    f"{hour1[1]} awards in hour 1, {per_award} clock ticks each"))
    # #77: the day a claim lands on, (streak - 1) % cycle + 1, walks 1..cycle and wraps.
    days = [(streak - 1) % cycle + 1 for streak in range(1, 2 * cycle + 1)]
    results.append(("the daily streak prize walks the whole table and wraps",
                    days == list(range(1, cycle + 1)) * 2, f"{cycle} days: {days}"))
    return results, hour1[0], hour2[0] - hour1[0]


def plants(progression_src, service_src):
    """Each plant breaks an invariant; the checks must go red for every one."""
    # service_src has been through luau_to_lua, so `+=` reads as `x = x + 1` here.
    yield "a dead or spectating player is not paid (the old rule)", progression_src, service_src.replace(
        "\tsession.samples = session.samples + 1\n",
        "\tif not player.Character then return end\n\tsession.samples = session.samples + 1\n")
    yield "the ladder never caps", progression_src.replace(
        "return math.min(p.CapCoins, p.FirstCoins", "return (0 * p.CapCoins + p.FirstCoins"), service_src
    yield "an award every other stretch", progression_src, service_src.replace(
        "\tsession.samples = 0\n\tsession.awards", "\tsession.samples = -SAMPLES_PER_AWARD\n\tsession.awards")


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    progression_src, service_src, cycle = playtime_block(root), service_source(root), daily_cycle(root)
    if "--plant" in sys.argv:
        caught = 0
        total = 0
        for label, psrc, ssrc in plants(progression_src, service_src):
            total += 1
            if psrc == progression_src and ssrc == service_src:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            results, _, _ = checks(psrc, ssrc, cycle)
            failed = [name for name, ok, _ in results if not ok]
            if failed:
                caught += 1
                print(f"  caught: {label} -> {failed[0]}")
            else:
                print(f"  MISSED: {label}")
        print(f"playtime planted faults: {caught}/{total} caught")
        sys.exit(0 if caught == total else 1)
    results, hour1, hour2 = checks(progression_src, service_src, cycle)
    for name, ok, detail in results:
        print(f"  {'ok  ' if ok else 'FAIL'} {name}: {detail}")
    bad = sum(1 for _, ok, _ in results if not ok)
    print(f"playtime check: {len(results)} checks, {bad} failed; hour 1 pays {hour1}, each later hour {hour2}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
