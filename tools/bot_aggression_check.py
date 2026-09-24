"""Bot reaction time, commitment and aim, before and after (#75/#81), from the real source.

No Studio, so this runs the real Luau of the paths that decide when a bot first shoots at someone,
in a Lua interpreter (lupa) with Roblox mocked, once from a git revision (the "before", default the
commit before this tool's first commit, pass --before REV) and once from the working tree:

  REACTION  BotService's think loop (its real period, THINK_SLICES waits rounded up to 60 Hz frames),
            findTarget (sight cache, rear notice) and quickFirstShot (the timed first shot), driven
            frame by frame for every phase of a bot's think against the moment the target appears.
            Three cases: appears 30 studs in front (tools/bot_probe.lua's S10 front), 30 behind a bot
            anchored so it can't turn (S10 behind), and steps out from behind a wall it was already
            hidden by (a peek). Each prints the true time to the first shot and the time S10 would
            report, since S10 samples every 0.2 s (the baseline 0.83 / 2.09 s is that figure).
  AIM       accuracyAt and shootAt's settle and moving-target lines, the hit chance at every range
            and moment of a fight. Must be IDENTICAL before and after (Oliver, #40: aim stays).
  COMMIT    the commitment dials and what they mean: how long a lost target is hunted, the range a
            rifle fights at (and the base hit chance there, the back door the ruling warns about),
            when a bot retreats, runs from an unseen shooter, and pushes a nearly dead target.

fight() itself is too wide to run with mocks. Its reaction gate is modelled (hold while
now - acquiredAt < BotReactionTime, calling quickFirstShot if the source does; shoot once past it),
and the harness fails if that gate's text is not in fight() as modelled.

    python tools/bot_aggression_check.py .              before/after and the checks
    python tools/bot_aggression_check.py . --plant      planted faults; every one must be caught
    python tools/bot_aggression_check.py . --before REV compare against another revision

Not measured: turning (a free bot turning to a rear target may fire earlier than the anchored case),
the probe's own overheads, and any feel. tools/bot_aggression_ab.lua measures those in Studio.
"""

import importlib.util
import os
import re
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("perf_bot_cost", os.path.join(HERE, "perf_bot_cost.py"))
perf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(perf)

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
MATCHCONFIG = "ReplicatedStorage/Shared/MatchConfig.lua"
PATHS = (BOTSERVICE, MATCHCONFIG)

# Targets (#75/#81 brief): first shot as S10 reports it.
FRONT_TARGET = 0.5
BEHIND_TARGET = 1.3


def config(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    table = lua.execute(perf.PRELUDE + "\nColor3 = { fromRGB = function() return {} end, new = function() return {} end }\n"
                        + perf.luau_to_lua(src))
    return {k: table[k] for k in table if isinstance(k, str) and k.startswith("Bot")}


def think_period(bot_src, cfg):
    src = perf.between(bot_src, "-- Bots think every BotThinkInterval", "function BotService.Clear()")
    harness = perf.THINK_HARNESS.replace("MatchConfig = { BotThinkInterval = 0.25 }",
                                         f"MatchConfig = {{ BotThinkInterval = {cfg['BotThinkInterval']} }}")
    lua = LuaRuntime(unpack_returned_tuples=True)
    _, pmin, pmax, _, _, _ = lua.execute(harness, perf.luau_to_lua(src), 8, 10.0)
    assert abs(pmax - pmin) < 1e-6, f"uneven think period {pmin}-{pmax}"
    return pmin


# --------------------------------------------------------------------------------------------
# REACTION
# --------------------------------------------------------------------------------------------

GATE = "if now - bot.acquiredAt < MatchConfig.BotReactionTime then\n\t\tholdStill(bot, humanoid, root, now)\n\t\tfaceTarget(bot, humanoid, root, targetRoot)\n"
QUICK_CALL = "quickFirstShot(bot, candidate, head, now)"

REACTION_HARNESS = perf.PRELUDE + r"""
local src, cfg, scenario, thinkFrames, phase = ...
MatchConfig = {}
for k, v in pairs(cfg) do MatchConfig[k] = v end
STATS = setmetatable({}, { __index = function() return 0 end })
running = true
hostile = function() return true end
flat = function(v) return Vector3.new(v.X, 0, v.Z) end
flatLook = function(root) return root.CFrame.LookVector end
local DT = 1 / 60
local timers, delays = {}, 0
task.delay = function(d, fn) delays = delays + 1; timers[#timers + 1] = { at = CLOCK + d, fn = fn } end
local appearAt = 3.0
local wall = { IsDescendantOf = function() return false end }
local targetPart = { IsDescendantOf = function() return true end }
local visibleNow = false
workspace = {
    FindFirstChild = function() return nil end,
    Raycast = function() return { Instance = visibleNow and targetPart or wall } end,
}
CombatService = { GetLastAttacker = function() return nil end, StructureFromPart = function() return nil end,
    DamageStructure = function() end }
DefenseService = {}
local all = {}
Combatants = { All = function() return all end, IsPlayer = function() return false end }
local function makeCharacter(position)
    local root = { Position = position, Parent = true, CFrame = { LookVector = Vector3.new(0, 0, 1) } }
    local humanoid = { Health = 100, MaxHealth = 100 }
    local character = { Parent = true }
    character.FindFirstChild = function(_, name) if name == "HumanoidRootPart" then return root end end
    character.FindFirstChildOfClass = function() return humanoid end
    return character, root, humanoid
end
local botChar, botRoot, botHumanoid = makeCharacter(Vector3.new(0, 0, 0))
local bot = { character = botChar, humanoid = botHumanoid, lastHurtAt = -math.huge, weapon = { range = 300 },
    sight = {}, seen = {}, ownStructures = {}, acquiredAt = 0 }
local head = { Position = Vector3.new(0, 1.5, 0), Parent = true }
local z = scenario == "behind" and -30 or 30
local targetChar, targetRoot = makeCharacter(Vector3.new(0, 0, z))
local target = { character = targetChar }
if scenario == "peek" then all[targetChar] = target end  -- there all along, behind a wall

local firstShot, quickShots, facingAway = nil, 0, 0
shootAt = function(b, t, root, distance, h, quick)
    if not firstShot then firstShot = CLOCK - appearAt end
end
local chunk = assert(load(src, "reaction", "t", _ENV))
local findTarget, refreshCombatants, quickFirstShot = chunk()
local realShoot = shootAt
if quickFirstShot then
    -- Only a timed shot comes through here with the bot still in its reaction hold.
    shootAt = function(b, t, root, distance, h)
        quickShots = quickShots + 1
        local to = flat(root.Position - botRoot.Position).Unit
        if to:Dot(botRoot.CFrame.LookVector) < 0.25 then facingAway = facingAway + 1 end
        return realShoot(b, t, root, distance, h)
    end
end

local frame = 0
local perAcquisition, acquisitions = 0, 0
while CLOCK < appearAt + (scenario == "duck" and 1 or 4) and not firstShot do
    frame = frame + 1
    CLOCK = frame * DT
    if CLOCK >= appearAt - 1e-9 then
        visibleNow = not (scenario == "duck" and bot.acquiredAt > 0 and CLOCK >= bot.acquiredAt + 0.05)
        all[targetChar] = target
    end
    local due = {}
    for i = #timers, 1, -1 do
        if CLOCK >= timers[i].at - 1e-9 then due[#due + 1] = table.remove(timers, i) end
    end
    for _, t in ipairs(due) do t.fn() end
    if (frame - phase) % thinkFrames == 0 and not firstShot then
        local now = CLOCK
        refreshCombatants()
        local candidate = findTarget(bot, botRoot, head, now)
        if candidate then
            bot.target = candidate.token
            if bot.acquiredAt == 0 then bot.acquiredAt = now; acquisitions = acquisitions + 1 end
            if now - bot.acquiredAt < MatchConfig.BotReactionTime then
                if HAS_QUICK and quickFirstShot then
                    quickFirstShot(bot, candidate, head, now)
                    -- Bound: a second call for the same acquisition must schedule nothing more.
                    quickFirstShot(bot, candidate, head, now)
                end
            else
                realShoot(bot, candidate.token, candidate.root, candidate.distance, head)
            end
        else
            bot.acquiredAt = 0
            bot.target = nil
        end
    end
end
return firstShot or -1, quickShots, facingAway, delays, acquisitions
"""


def reaction_source(bot_src):
    src = perf.between(bot_src, "local function hasLineOfSight", "-- Where a target was last seen")
    quick = "nil"
    if "local function quickFirstShot" in bot_src:
        src += "\n" + perf.between(bot_src, "local function quickFirstShot", "local function fight(")
        quick = "quickFirstShot"
    return perf.luau_to_lua(src) + f"\nreturn findTarget, refreshCombatants, {quick}\n"


def fight_source(bot_src):
    return perf.between(bot_src, "local function fight(", "-- Out of time against the storm")


def reaction(bot_src, cfg, period):
    fails = []
    fight = fight_source(bot_src)
    if GATE not in fight:
        fails.append("REACTION: fight()'s reaction hold is not the gate this harness models")
    has_quick = QUICK_CALL in fight
    frames = round(period * 60)
    src = reaction_source(bot_src)
    out = {}
    for scenario in ("front", "behind", "peek", "duck"):
        true_times, s10_times = [], []
        quick = away = extra = 0
        for phase in range(frames):
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().HAS_QUICK = has_quick
            shot, q, f, delays, acq = lua.execute(REACTION_HARNESS, src, lua.table_from(cfg), scenario, frames, phase)
            if scenario == "duck":
                # Seen, then behind a wall 0.05 s later, inside the reaction: no timed shot may fire.
                quick += q
                extra += max(0, delays - acq)
                continue
            if shot < 0:
                fails.append(f"REACTION {scenario}: never shot (phase {phase})")
                continue
            true_times.append(shot)
            # S10 samples every 0.2 s from the moment the dummy appears.
            s10_times.append(-(-round(shot * 60) // 12) * 0.2)
            quick += q
            away += f
            extra += max(0, delays - acq)
        if scenario == "duck" and quick:
            fails.append(f"REACTION duck: {quick} timed first shots at a target that went behind a wall")
        if scenario == "duck" and extra:
            fails.append(f"REACTION duck: {extra} extra timed shots scheduled beyond one per acquisition")
        if not true_times:
            continue
        mean = sum(true_times) / len(true_times)
        s10 = sum(s10_times) / len(s10_times)
        out[scenario] = (mean, max(true_times), s10, quick, away)
        if away:
            fails.append(f"REACTION {scenario}: {away} timed first shots at a target outside the front cone")
        if extra:
            fails.append(f"REACTION {scenario}: {extra} extra timed shots scheduled beyond one per acquisition")
    return out, has_quick, fails


# --------------------------------------------------------------------------------------------
# AIM
# --------------------------------------------------------------------------------------------

AIM_HARNESS = perf.PRELUDE + r"""
local src, cfg, settleDelay = ...
MatchConfig = {}
for k, v in pairs(cfg) do MatchConfig[k] = v end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
AIM_SETTLE_DELAY = settleDelay
local accuracyAt, chanceAt = assert(load(src, "aim", "t", _ENV))()
local rows = {}
for _, distance in ipairs({ 5, 20, 45, 55, 60, 70, 100, 150, 250 }) do
    for _, since in ipairs({ 0, 0.1, 0.12, 0.2, 0.28, 0.4, 0.8, 1.2, 1.78, 2.5, 4 }) do
        for _, speed in ipairs({ 0, 25 }) do
            local bot = { acquiredAt = 10 }
            local root = { AssemblyLinearVelocity = Vector3.new(speed, 0, 0) }
            rows[#rows + 1] = string.format("%g/%g/%g=%.6f", distance, since, speed, chanceAt(bot, 10 + since, distance, root))
        end
    end
end
return table.concat(rows, " ")
"""


def aim_table(bot_src, cfg):
    acc = perf.between(bot_src, "local function accuracyAt", "-- Magazines,")
    chance = perf.between(bot_src, "\tlocal chance = accuracyAt(distance)", "\tlocal hit = math.random() < chance")
    src = (perf.luau_to_lua(acc) + "\nlocal function chanceAt(bot, now, distance, targetRoot)\n"
           + perf.luau_to_lua(chance) + "\treturn chance\nend\nreturn accuracyAt, chanceAt\n")
    m = re.search(r"^local AIM_SETTLE_DELAY = ([\d.]+)", bot_src, flags=re.M)
    lua = LuaRuntime(unpack_returned_tuples=True)
    table = lua.execute(AIM_HARNESS, src, lua.table_from(cfg), float(m.group(1)) if m else 0.0)
    head = re.search(r"^local BOT_HEADSHOT_CHANCE = ([\d.]+)", bot_src, flags=re.M)
    lethal = {k: cfg.get(k) for k in ("BotAccuracyNear", "BotAccuracyFar", "BotAccuracyFalloff", "BotDamageScale",
                                      "BotBurstRest")}
    lethal["BOT_HEADSHOT_CHANCE"] = head and head.group(1)
    return table, lethal


# --------------------------------------------------------------------------------------------
# COMMIT
# --------------------------------------------------------------------------------------------

def base_chance(cfg, d):
    t = min(max(d / cfg["BotAccuracyFalloff"], 0), 1)
    return cfg["BotAccuracyFar"] + (cfg["BotAccuracyNear"] - cfg["BotAccuracyFar"]) * (1 - t)


def commitment(bot_src, cfg):
    # The literals these replaced, for a before revision that had no dial.
    push = re.search(r"bot\.pushing = .*?Health < targetHumanoid\.MaxHealth \* ([\w.]+)\s*and humanoid\.Health > "
                     r"humanoid\.MaxHealth \* ([\w.]+)", bot_src, flags=re.S)
    flee = re.search(r"local low = humanoid\.Health <= humanoid\.MaxHealth \* MatchConfig\.(\w+)", bot_src)

    def val(text):
        return cfg[text.split(".")[-1]] if text.startswith("MatchConfig.") else float(text)

    rifle = 380  # CrocodiloRifle's reach (WeaponData); preferred = min(BotEngagePreferred, reach * 0.6)
    preferred = min(cfg["BotEngagePreferred"], rifle * 0.6)
    return {
        "hunt a target lost 40 studs off (s)": round(cfg["BotMemorySeconds"] + 40 / cfg["BotWalkSpeed"], 1),
        "hunt a target lost 120 studs off (s)": round(cfg["BotMemorySeconds"] + 120 / cfg["BotWalkSpeed"], 1),
        "rifle fights at (studs)": preferred,
        "base hit chance there": round(base_chance(cfg, preferred), 3),
        "retreats at hp": cfg["BotRetreatHealth"],
        "cover in a fight below": cfg["BotCoverHealth"],
        "runs from an unseen shooter below": cfg[flee.group(1)] if flee else None,
        "pushes a target below": val(push.group(1)) if push else None,
        "while its own health is over": val(push.group(2)) if push else None,
    }


# Which way "more committed" is for each row: +1 higher is more, -1 lower is more, 0 report only.
DIRECTION = {
    "hunt a target lost 40 studs off (s)": +1, "hunt a target lost 120 studs off (s)": +1,
    "rifle fights at (studs)": -1, "base hit chance there": 0, "retreats at hp": -1,
    "cover in a fight below": 0, "runs from an unseen shooter below": -1,
    "pushes a target below": +1, "while its own health is over": -1,
}


# --------------------------------------------------------------------------------------------

def run(tree, before, verbose=True):
    fails = []
    cfg_a, cfg_b = config(tree[MATCHCONFIG]), config(before[MATCHCONFIG])
    period_a, period_b = think_period(tree[BOTSERVICE], cfg_a), think_period(before[BOTSERVICE], cfg_b)
    ra, quick_a, f = reaction(tree[BOTSERVICE], cfg_a, period_a)
    fails += f
    rb, quick_b, _ = reaction(before[BOTSERVICE], cfg_b, period_b)
    aim_a, lethal_a = aim_table(tree[BOTSERVICE], cfg_a)
    aim_b, lethal_b = aim_table(before[BOTSERVICE], cfg_b)
    com_a, com_b = commitment(tree[BOTSERVICE], cfg_a), commitment(before[BOTSERVICE], cfg_b)

    if verbose:
        print(f"think period: before {period_b:.3f} s, after {period_a:.3f} s; "
              f"reaction {cfg_b['BotReactionTime']} -> {cfg_a['BotReactionTime']}, "
              f"rear notice {cfg_b['BotRearNoticeTime']} -> {cfg_a['BotRearNoticeTime']}; "
              f"timed first shot: before {quick_b}, after {quick_a}")
        print("REACTION (time from the target appearing to the first shot; mean / worst; as S10 reports it)")
        for s in ("front", "behind", "peek"):
            b, a = rb.get(s), ra.get(s)
            if b and a:
                print(f"  {s:6}  before {b[0]:.2f} / {b[1]:.2f} s, S10 {b[2]:.2f}   after {a[0]:.2f} / {a[1]:.2f} s, "
                      f"S10 {a[2]:.2f}   (timed shots {a[3]})")
        print("  calibration: S10 run 15a measured the before as 0.83 front / 2.09 behind")
        print("COMMIT (before -> after)")
        for k in com_a:
            print(f"  {k:36} {com_b[k]} -> {com_a[k]}")
        print(f"AIM: {aim_a.count('=')} (range, moment, speed) hit chances, "
              f"{'IDENTICAL' if aim_a == aim_b else 'CHANGED'}; lethality dials {lethal_a}")

    if "front" in ra and ra["front"][2] > FRONT_TARGET:
        fails.append(f"REACTION front: {ra['front'][2]:.2f} s as S10 reports it, target <= {FRONT_TARGET}")
    if "behind" in ra and ra["behind"][2] > BEHIND_TARGET:
        fails.append(f"REACTION behind: {ra['behind'][2]:.2f} s as S10 reports it, target <= {BEHIND_TARGET}")
    # The reaction is a time, not rounded up to a think: from appearing to the first shot takes the
    # wait for the next think (half a period on average) plus BotReactionTime, and a frame or two.
    if "front" in ra and ra["front"][0] > period_a / 2 + cfg_a["BotReactionTime"] + 0.05:
        fails.append(f"REACTION front: {ra['front'][0]:.2f} s, want <= half a think + BotReactionTime + 0.05 = "
                     f"{period_a / 2 + cfg_a['BotReactionTime'] + 0.05:.2f}: the reaction is rounded up to whole thinks")
    if "peek" in ra and "front" in ra and ra["peek"][0] > ra["front"][0] + 0.05:
        fails.append(f"REACTION peek: {ra['peek'][0]:.2f} s against {ra['front'][0]:.2f} for a fresh target: "
                     "the sight cache is holding back a target stepping out")
    if aim_a != aim_b:
        diff = [(x, y) for x, y in zip(aim_b.split(), aim_a.split()) if x != y]
        fails.append(f"AIM changed at {len(diff)} points, e.g. {diff[0][0]} -> {diff[0][1].split('=')[1]}")
    if lethal_a != lethal_b:
        fails.append(f"AIM: lethality dials changed {lethal_b} -> {lethal_a}")
    for k, d in DIRECTION.items():
        a, b = com_a[k], com_b[k]
        if d and (a is None or b is None or (a - b) * d < 0):
            fails.append(f"COMMIT: {k} went {b} -> {a}, the less committed way")
    return fails


PLANTS = [
    (BOTSERVICE, "- AIM_SETTLE_DELAY) / 1.5", "- MatchConfig.BotReactionTime) / 1.5",
     "aim: settle reads the (faster) reaction time again"),
    (MATCHCONFIG, "MatchConfig.BotAccuracyNear = 0.71", "MatchConfig.BotAccuracyNear = 0.75",
     "aim: near accuracy nudged up"),
    (MATCHCONFIG, "MatchConfig.BotDamageScale = 0.8", "MatchConfig.BotDamageScale = 0.9",
     "lethality: damage scale nudged up"),
    (BOTSERVICE, "\t\tquickFirstShot(bot, candidate, head, now)\n", "\n",
     "reaction: the timed first shot is never scheduled"),
    (BOTSERVICE, "\t\tif to.Magnitude > 1 and flatLook(root):Dot(to.Unit) < FRONT_CONE_COS then\n\t\t\treturn\n\t\tend\n",
     "", "bound: timed shot fires at a target behind the bot"),
    (BOTSERVICE, "\tbot.quickShotFor = acquiredAt\n", "", "bound: timed shot scheduled on every call in the hold"),
    (BOTSERVICE, "\t\tif not hasLineOfSight(head, targetCharacter, character) then\n\t\t\treturn\n\t\tend\n", "",
     "bound: timed shot fires at a target that ducked behind a wall"),
    (BOTSERVICE, "candidate.character, now, index == 1)", "candidate.character, now, false)",
     "reaction: the sight cache holds back the best candidate again"),
    (MATCHCONFIG, "MatchConfig.BotRearNoticeTime = 0.7", "MatchConfig.BotRearNoticeTime = 1.2",
     "reaction: rear notice back to 1.2"),
    (MATCHCONFIG, "MatchConfig.BotMemorySeconds = 10", "MatchConfig.BotMemorySeconds = 4",
     "commitment: hunts shorter than before"),
    (MATCHCONFIG, "MatchConfig.BotPushTargetBelow = 0.5", "MatchConfig.BotPushTargetBelow = 0.3",
     "commitment: pushes later than before"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    tree = {p: perf.read_tree(root, p) for p in PATHS}
    rev = args[args.index("--before") + 1] if "--before" in args else None
    if rev is None:
        rev = perf.default_before(root, "tools/bot_aggression_check.py")
    try:
        before = {p: perf.read_rev(root, rev, p) for p in PATHS}
    except perf.NoRevision as err:
        # No git: the working tree is its own "before", so the absolute reaction targets are still
        # checked and a planted fault is still measured against the unplanted tree; only the
        # comparison with the stock revision is lost.
        perf.no_before_note("bot_aggression_check", err)
        rev, before = "working tree: no git", dict(tree)

    if "--plant" in args:
        caught = 0
        for path, old, new, what in PLANTS:
            assert tree[path].count(old) == 1, f"plant text not found once in {path}: {old!r}"
            planted = dict(tree)
            planted[path] = tree[path].replace(old, new)
            try:
                fails = run(planted, before, verbose=False)
            except Exception as err:  # a plant that breaks the harness counts as caught, loudly
                fails = [f"harness error: {err}"]
            caught += bool(fails)
            print(f"plant [{'CAUGHT' if fails else 'MISSED'}] {what}: {fails[0] if fails else 'no check failed'}")
        print(f"bot_aggression_check plants: {caught}/{len(PLANTS)} caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    print(f"--- before {rev}, after the working tree")
    fails = run(tree, before)
    for f in fails:
        print("FAIL", f)
    print(f"bot_aggression_check: {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
