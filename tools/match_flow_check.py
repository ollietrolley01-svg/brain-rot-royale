"""Behaviour check for the match's edges, without Studio: spectating, the battle royale's AFK rule, the
Loading window, a player leaving and a retired bot.

    python3 tools/match_flow_check.py .            the checks
    python3 tools/match_flow_check.py . --plant    the planted faults; every one must be caught

Each part is the REAL function cut out of the source and run in lupa against a small mocked world:

  spectate  MatchService.IsSpectating / LeaveSpectate / FocusTarget: leaving ENDS spectating -- the
            second LEAVE is refused (no second body at the pier), the arena can no longer be streamed
            through FocusTarget -- and the next match's reset lets them spectate again.
  afk       MatchService's battle royale AFK rule (the `afk` table): a player who never moves is paid the
            `afk` line only, not their placement; moving or hurting someone is playing; a player killed
            before their first check is not idle. finishMatch and the leave path both pay through it,
            and the 1 s loop checks only living participants.
  loading   MatchService.IsPlaying is false while the match is Loading (everyone is already alive to
            IsAlive then), and Bootstrap's DropSlot and UseSelected ask it.
  leave     Bootstrap's invite-cooldown cleanup matches a leaving UserId exactly (it used a substring, so
            UserId 12 cleared 3120>77); MatchService.OnPlayerRemoving lets go of the ready-toggle stamp.
  retire    BotService.Forget takes a bot out of the think list, its ride, its nav and its loot claims,
            once (a second call is a no-op); GameMode.retireBot calls it.

Needs `pip install lupa`.
"""
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("match_flow_check: needs lupa (pip install lupa)")

MATCH = "ServerScriptService/Modules/MatchService.lua"
BOOT = "ServerScriptService/Bootstrap.server.lua"
BOTS = "ServerScriptService/Modules/BotService.lua"
GAMEMODE = "ServerScriptService/Modules/GameMode.lua"


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/])= (.+)$", r"\1\2 = \2 \3 \4", source, flags=re.M)


def cut(src, head):
    """A function from its header to the `end` at its own indentation (column 0 or one tab)."""
    a = src.index(head)
    line_start = src.rfind("\n", 0, a) + 1
    indent = src[line_start:a]
    b = src.index("\n" + indent + "end\n", a) + len(indent) + 5
    return src[line_start:b]


def between(src, start, stop):
    a = src.index(start)
    return src[a:src.index(stop, a)]


# ------------------------------------------------------------------------------------------ spectate

SPECTATE = r"""
local src = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local fired, loads = {}, 0
local env = setmetatable({
    participants = {}, alive = {}, leftSpectate = {},
    currentMode = { respawn = false },
    spectate = { FireClient = function(_, p, v) table.insert(fired, v) end },
    Combatants = { FromCharacter = function(c) return c.token end },
    typeof = function(x) return type(x) == "table" and "Instance" or type(x) end,
    MatchService = {},
}, { __index = _G })
local fns = assert(load(src .. "\nreturn function(p, a, l) participants, alive, leftSpectate = p, a, l end", "MatchService.spectate", "t", env))
local reset = fns()
local MS = env.MatchService
local player = { attrs = {} }
function player:SetAttribute(k, v) self.attrs[k] = v end
function player:LoadCharacter() loads = loads + 1 end
local enemy = {}
local root = { Name = "HumanoidRootPart", Parent = { token = enemy } }
function root:IsA(c) return c == "BasePart" end
local function newMatch() reset({ [player] = true, [enemy] = true }, { [enemy] = true }, {}) end
newMatch()
check(MS.IsSpectating(player) == true, "an eliminated participant is spectating")
check(MS.FocusTarget(player, root) == root, "...and may stream a living combatant")
check(MS.LeaveSpectate(player) == true and loads == 1, "LEAVE drops them to the lobby (one body loaded)")
check(MS.IsSpectating(player) == false, "after LEAVE they are no longer spectating")
check(MS.FocusTarget(player, root) == nil, "...and can no longer stream the arena through FocusTarget")
check(MS.LeaveSpectate(player) == false and loads == 1, "a second LEAVE is refused: no second body at the pier (" .. loads .. " loaded)")
newMatch()
check(MS.IsSpectating(player) == true, "the next match's reset lets them spectate again")
return out
"""


def spectate_rows(src):
    code = "\n".join([
        cut(src, "function MatchService.IsSpectating("),
        cut(src, "function MatchService.LeaveSpectate("),
        cut(src, "function MatchService.FocusTarget("),
    ])
    rows = run_lua(SPECTATE, luau_to_lua(code))
    # The table is cleared everywhere the match's tables are: the results reset, startMatch, and the
    # failed-start fallback.
    resets = src.count("table.clear(leftSpectate)")
    rows.append((resets >= 3, "leftSpectate is cleared with the match's tables (%d site(s), want 3)" % resets))
    leave = cut(src, "function MatchService.OnPlayerRemoving(")
    rows.append(("leftSpectate[player] = nil" in leave, "OnPlayerRemoving lets go of a leaver's leftSpectate entry"))
    return rows


# ------------------------------------------------------------------------------------------ afk

AFK = r"""
local src, afkLine = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local V = {}
V.__index = V
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V) end
V.__sub = function(a, b) return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__index = function(v, k) if k == "Magnitude" then return math.sqrt(v.X ^ 2 + v.Y ^ 2 + v.Z ^ 2) end end
local placements, xp, listeners = {}, {}, {}
local env = setmetatable({
    state = "InProgress",
    participants = {},
    MatchConfig = { TeamModeRewards = { participation = { sampleSeconds = 15, minActiveShare = 0.5 }, afk = afkLine } },
    Shared = { WaitForChild = function(_, n) return { Name = n } end },
    script = { Parent = { WaitForChild = function(_, n) return { Name = n } end } },
    require = function(m)
        if m.Name == "ProgressionData" then return { Playtime = { MoveStuds = 4 } } end
        if m.Name == "BattlePassService" then return { AddXp = function(p, n) xp[p] = (xp[p] or 0) + n end } end
        error("no mock for " .. tostring(m.Name))
    end,
    Combatants = {
        GetRoot = function(p) return p.root end,
        IsPlayer = function(p) return type(p) == "table" and p.isPlayer == true end,
    },
    RewardService = {
        AwardPlacement = function(p, rank) placements[p] = rank; return { rank = rank, crate = "Rare", coins = 900 } end,
        AddCoins = function(_, n) return n end,
    },
    StateSync = { Push = function() end },
    CombatService = { OnDamage = function(fn) table.insert(listeners, fn) end },
}, { __index = _G })
local afk = assert(load(src .. "\nreturn afk", "MatchService.afk", "t", env))()
local function player(name) return { Name = name, isPlayer = true, root = { Position = vec(0, 0, 0) } } end
local idle, runner, camper, early = player("Idle"), player("Runner"), player("Camper"), player("Early")
for _, p in ipairs({ idle, runner, camper, early }) do env.participants[p] = true end
for i = 1, 20 do
    runner.root.Position = vec(i * 10, 0, 0)
    if i % 2 == 0 then for _, fn in ipairs(listeners) do fn(camper, {}, 12) end end
    for _, p in ipairs({ idle, runner, camper }) do afk.sample(p) end
end
check(afk.isIdle(idle) == true, "a player who never moved or hurt anyone in 20 checks is idle")
check(afk.isIdle(runner) == false, "a player who moved is not")
check(afk.isIdle(camper) == false, "a player who stood still but kept hitting people is not")
check(afk.isIdle(early) == false, "a player killed before their first check is not")
local card = afk.award(idle, 3)
check(placements[idle] == nil and card.afk == true and card.crate == nil and card.coins == afkLine.coins and xp[idle] == afkLine.xp,
    string.format("the idle player is paid the afk line only (%s coins, %s XP, crate %s), not their #3 placement", tostring(card.coins), tostring(xp[idle]), tostring(card.crate)))
check(type(card.lines) == "table" and card.lines[1] and card.lines[1].id == "result", "...on a card the results screen lists")
card = afk.award(runner, 1)
check(placements[runner] == 1 and card.crate == "Rare", "the runner is paid their placement")
afk.award(early, 20)
check(placements[early] == 20, "the early death is paid their placement")
return out
"""


def afk_rows(src):
    block = between(src, "local afk = {", "\n-- Hurting someone is playing")
    listener = between(src, "-- Hurting someone is playing", "\nend)\n") + "\nend)\n"
    cfg = open(os.path.join(ROOT, "ReplicatedStorage/Shared/MatchConfig.lua"), encoding="utf-8").read()
    m = re.search(r"afk = \{ coins = (\d+), xp = (\d+) \}", cfg)
    rows = run_lua(AFK, luau_to_lua(block + "\n" + listener), {"coins": int(m.group(1)), "xp": int(m.group(2))})
    finish = between(src, "local function finishMatch()", "\nend\n")
    rows.append(("or afk.award(token, rank)" in finish and "RewardService.AwardPlacement(" not in finish,
                 "finishMatch pays a battle royale placement through the AFK rule"))
    leave = cut(src, "function MatchService.OnPlayerRemoving(")
    rows.append(("pcall(afk.award, player, placements[player])" in leave and "RewardService.AwardPlacement" not in leave,
                 "a spectator who leaves is paid through the AFK rule too"))
    loop = between(src, "afk.tick += 1", "\n\t\t\tif state == \"Waiting\" then")
    rows.append(("Combatants.IsPlayer(token) and alive[token]" in loop and "pcall(afk.sample, token)" in loop,
                 "the 1 s loop checks living participants only (dead and spectating time is not sampled)"))
    return rows


# ------------------------------------------------------------------------------------------ loading / leave

PLAYING = r"""
local src = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local env = setmetatable({ state = "Loading", MatchService = { IsAlive = function() return true end } }, { __index = _G })
assert(load(src, "MatchService.IsPlaying", "t", env))()
check(env.MatchService.IsPlaying({}) == false, "alive during Loading is not playing")
env.state = "InProgress"
check(env.MatchService.IsPlaying({}) == true, "alive in a running match is playing")
env.MatchService.IsAlive = function() return false end
check(env.MatchService.IsPlaying({}) == false, "dead in a running match is not")
return out
"""

INVITES = r"""
local src = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local tradeInviteAt = { ["12>77"] = 1, ["77>12"] = 1, ["3120>77"] = 1, ["77>3120"] = 1, ["120>5"] = 1, ["-12>9"] = 1 }
local env = setmetatable({ tradeInviteAt = tradeInviteAt }, { __index = _G })
local clean = assert(load("local player = ...\n" .. src, "Bootstrap.invites", "t", env))
clean({ UserId = 12 })
check(tradeInviteAt["12>77"] == nil and tradeInviteAt["77>12"] == nil, "a leaver's own pairs, both ways, are cleared")
check(tradeInviteAt["3120>77"] and tradeInviteAt["77>3120"] and tradeInviteAt["120>5"] and tradeInviteAt["-12>9"],
    "pairs whose ids merely CONTAIN the leaver's id are kept (3120, 120, -12)")
return out
"""


def edge_rows(match_src, boot_src):
    rows = run_lua(PLAYING, luau_to_lua(cut(match_src, "function MatchService.IsPlaying(")))
    for remote in ("DropSlot", "UseSelected"):
        handler = between(boot_src, 'Remotes.Event("%s").OnServerEvent' % remote, "\nend)\n")
        rows.append(("MatchService.IsPlaying(player)" in handler and "MatchService.IsAlive(player)" not in handler,
                     "Bootstrap's %s asks IsPlaying, not IsAlive" % remote))
    leave = cut(boot_src, "local function onPlayerRemoving(")
    loop = between(leave, "\tlocal leaving = tostring(player.UserId)", "\tPlayerData.Release(player)") \
        if "\tlocal leaving = tostring(player.UserId)" in leave else between(leave, "\tfor pair in pairs(tradeInviteAt) do", "\tPlayerData.Release(player)")
    rows += run_lua(INVITES, luau_to_lua(loop))
    ms_leave = cut(match_src, "function MatchService.OnPlayerRemoving(")
    rows.append(("lastReadyToggle[player.UserId] = nil" in ms_leave, "MatchService.OnPlayerRemoving lets go of the ready-toggle stamp"))
    return rows


# ------------------------------------------------------------------------------------------ retire

RETIRE = r"""
local src = ...
local out = {}
local function check(ok, line) table.insert(out, { ok = ok and true or false, line = line }) end
local a, b, c = { name = "A" }, { name = "B" }, { name = "C" }
local left, dropped = {}, {}
local env = setmetatable({
    bots = { a, b, c },
    riders = { [b] = { role = "driver" } },
    lootClaims = { crate1 = b, crate2 = a },
    Vehicles = { leaveRide = function(bot) left[bot] = true end },
    BotNav = { Drop = function(bot) dropped[bot] = true end },
    setSprint = function() end, setCrouch = function() end,
    BotService = {},
}, { __index = _G })
table.find = table.find or function(t, v) for i, x in ipairs(t) do if x == v then return i end end end
assert(load(src, "BotService.Forget", "t", env))()
local BS = env.BotService
check(BS.Forget(b) == true, "Forget answers true for a listed bot")
check(#env.bots == 2 and env.bots[1] == a and env.bots[2] == c, "...and takes it out of the think list, the others kept in order")
check(left[b] and dropped[b], "...out of its ride and its nav")
check(env.lootClaims.crate1 == nil and env.lootClaims.crate2 == a, "...and its loot claims, nobody else's")
check(BS.Forget(b) == false and #env.bots == 2, "a second Forget is a no-op")
return out
"""


def retire_rows(bot_src, gm_src):
    rows = run_lua(RETIRE, luau_to_lua(cut(bot_src, "function BotService.Forget(")))
    retire = cut(gm_src, "local function retireBot(")
    rows.append(("BotService.Forget(bot)" in retire, "GameMode.retireBot takes the bot out of BotService's think list"))
    return rows


# ------------------------------------------------------------------------------------------ runner

ROOT = "."


def run_lua(code, *args):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua_args = [lua.table_from(a) if isinstance(a, dict) else a for a in args]
    try:
        result = lua.execute(code, *lua_args)
        return [(bool(r["ok"]), r["line"]) for r in result.values()]
    except Exception as exc:  # a crash is a failure, not a pass
        return [(False, "harness crashed: %s" % str(exc).splitlines()[0])]


def all_rows(sources):
    rows = []
    for name, fn in (
        ("spectate", lambda: spectate_rows(sources[MATCH])),
        ("afk", lambda: afk_rows(sources[MATCH])),
        ("edges", lambda: edge_rows(sources[MATCH], sources[BOOT])),
        ("retire", lambda: retire_rows(sources[BOTS], sources[GAMEMODE])),
    ):
        try:
            rows += fn()
        except (ValueError, AttributeError) as exc:  # a cut that no longer finds its function
            rows.append((False, "%s: source shape changed: %s" % (name, exc)))
    return rows


PLANTS = [
    ("LEAVE doesn't end spectating (the old code)", MATCH, "\tleftSpectate[player] = true\n", ""),
    ("IsSpectating ignores a leaver", MATCH, " and not leftSpectate[player]\nend", "\nend"),
    ("leftSpectate never cleared at the match reset", MATCH,
     "\t\taliveCount = 0\n\t\ttable.clear(leftSpectate)\n", "\t\taliveCount = 0\n"),
    ("an idle player paid their placement", MATCH, "\tif not afk.isIdle(player) then\n", "\tif true then\n"),
    ("hurting someone doesn't count as playing", MATCH, "\tif moved or record.busy then\n", "\tif moved then\n"),
    ("killed before the first check counts as idle", MATCH,
     "return record ~= nil and record.samples > 0 and record.active", "return record == nil or record.active"),
    ("finishMatch pays placements directly", MATCH, "or afk.award(token, rank)", "or RewardService.AwardPlacement(token, rank)"),
    ("IsPlaying true during Loading", MATCH, 'return state == "InProgress" and MatchService.IsAlive(player)',
     'return (state == "InProgress" or state == "Loading") and MatchService.IsAlive(player)'),
    ("DropSlot gated on IsAlive again", BOOT,
     'RateLimit.Take(player, "DropSlot") or not MatchService.IsPlaying(player)', 'RateLimit.Take(player, "DropSlot") or not MatchService.IsAlive(player)'),
    ("invite cleanup by substring again", BOOT, "if from == leaving or to == leaving then",
     "if string.find(pair, leaving, 1, true) then"),
    ("ready-toggle stamp kept after leaving", MATCH, "\tlastReadyToggle[player.UserId] = nil\n", ""),
    ("Forget leaves the bot in the list", BOTS, "\ttable.remove(bots, index)\n", ""),
    ("Forget leaves its loot claims", BOTS, "\t\tif holder == bot then\n\t\t\tlootClaims[item] = nil", "\t\tif false then\n\t\t\tlootClaims[item] = nil"),
]


def main():
    global ROOT
    ROOT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    sources = {rel: open(os.path.join(ROOT, rel), encoding="utf-8").read() for rel in (MATCH, BOOT, BOTS, GAMEMODE)}
    if "--plant" in sys.argv:
        caught = 0
        for label, rel, old, new in PLANTS:
            if sources[rel].count(old) != 1:
                print(f"  PLANT DID NOT APPLY: {label}")
                continue
            planted = dict(sources)
            planted[rel] = sources[rel].replace(old, new)
            failed = [line for ok, line in all_rows(planted) if not ok]
            caught += bool(failed)
            print(f"  {'CAUGHT' if failed else 'MISSED'}: {label}" + (f" -> {failed[0]}" if failed else ""))
        print(f"match_flow_check planted faults: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)
    rows = all_rows(sources)
    for ok, line in rows:
        print(f"  {'ok  ' if ok else 'FAIL'} {line}")
    bad = sum(1 for ok, _ in rows if not ok)
    print(f"match_flow_check: {len(rows)} checks, {bad} failed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
