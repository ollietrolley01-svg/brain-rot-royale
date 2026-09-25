"""findTarget before and after the crowd-cost change (#126/#131): the same decision on the same state,
for less work.

The change (task/lag-findtarget) stops findTarget building a row for every candidate and sorting them
all. It holds the few lowest scores instead and walks them in order. It must decide exactly what the
old one decided. This check runs the whole of BotService.lua (the working tree) in tools/
bot_archetype_sim.py's mock world, with the OLD findTarget loaded beside the new one and sharing every
helper and upvalue with it. The old one is REFERENCE_FT below, findTarget byte for byte as it was at
927bc44 (and on main until this change), so the check keeps working after the change lands; --old REV
reads it from git instead. Every call is made on one state twice: the old one
runs first, everything it touched is put back (the bot's sight and seen rows, its hostile cache, every
STATS counter, the ray budget's spend), then the new one runs and its result is kept. They must agree:

  E0  (with --base REV, and in --plant) the source outside findTarget's region is REV's: the only
      changes are findTarget itself, the pooled lists and the row helper in `scratch`, and comments, so
      the helpers both versions call are the ones they called before
  E1  what is returned: nil, or the same token, character, root, distance, score and throughCover
      (errors too: if one raises, both raise the same message)
  E2  the rays: every RaycastBudget.Cast in order (origin, direction, class, whether it was granted),
      and the budget's spend afterwards. So the candidates are sight-tested in the same order, and
      the rays per think cannot go up
  E3  what is left on the bot: every sight row (at, visible, cover) and every seen row (since, last)
  E4  every STATS counter the call moved, by the same amount
  E5  math.random draws during the call (none either way: the RNG stream is untouched)
  E6  the hostility hook (BotService.IsHostile): the same questions, in the same order
  C1  cost, packed-50: per call, the new one makes at most 1/4 of the rows the old one did, calls
      table.sort on at most 5% of calls (a walk past the held few, or a shared score), and runs at
      most 90% of the old one's BotService instructions (paired: the same calls on the same states;
      vector maths and the mock world's raycast are not counted, see CHECK_LUA)

States come from two places:
  WORLD  whole matches of BotService.updateBot in the sim's world: spread, packed and teams at 15, 30
         and 50 bots (mixed archetypes and guns, walls, two players, dummy shooters that make threats),
         8 s each, every findTarget call compared
  EDGE   built states, one think each, seeded: candidates on a lattice and on rings (exact score
         ties), at exactly vision range, just past it, past it but shooting us (inside and exactly at
         gun range), dead (0 and below), team-mates, a hook that errors, a shared ride, players,
         hurt and at exactly 40%, infinite health (a NaN score for a "weakest" bot), focus-fire rows,
         stale and fresh sight rows (hidden, seen, barricade, shot-down barricade), seen rows, smoke,
         a small ray cap so refusals land part way through a walk, and every archetype

    python tools/findtarget_equivalence_check.py .              the checks and the numbers
    python tools/findtarget_equivalence_check.py . --plant      planted faults; every one must be caught
    python tools/findtarget_equivalence_check.py . --base REV   also E0: nothing outside findTarget changed since REV
    python tools/findtarget_equivalence_check.py . --old REV    the old findTarget from git REV, not the reference copy

What this does NOT show: milliseconds in Roblox. The instruction counts are lupa's (Lua 5.4) with
mocked Vector3s, and Luau's table.sort is not Lua 5.4's. That does not weaken E1-E6: when two
candidates share a score, the new code hands the very list the old one sorted to the same
table.sort, so whatever the sort does with ties, it does for both.
"""

import os
import re
import subprocess
import sys
import importlib.util

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("bot_archetype_sim", os.path.join(HERE, "bot_archetype_sim.py"))
sim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(sim)

BOTSERVICE = "ServerScriptService/Modules/BotService.lua"
# findTarget before the crowd-cost change, byte for byte: BotService.lua at 927bc44 (unchanged on main
# through d1e4f73). Kept here, not read from git, so the check still has it after the change lands.
REFERENCE_FT = r'''local function findTarget(bot, root, head, now)
	local threat = now - bot.lastHurtAt < THREAT_WINDOW and CombatService.GetLastAttacker(bot) or nil
	local reach = math.max(MatchConfig.BotVisionRange, bot.weapon and bot.weapon.range or 0)
	local candidatePool, candidates = scratch.candidatePool, scratch.candidates
	table.clear(candidates)
	local count = 0

	local position = root.Position
	-- Only combatants within reach can qualify, so only they are looked at (the grid, not the list).
	local near, nearCount = combatantsNear(position, reach)
	STATS.candidatesExamined += nearCount
	for index = 1, nearCount do
		local entry = near[index]
		local token = entry.token
		if token ~= bot and entry.humanoid.Health > 0 and hostile(bot, token) then
			local distance = (entry.position - position).Magnitude
			-- Past vision range only whoever is shooting us, and only as far as our gun reaches.
			if distance <= MatchConfig.BotVisionRange or (token == threat and distance <= reach) then
				local humanoid = entry.humanoid
				local score = distance
				if entry.isPlayer then
					score /= MatchConfig.BotPlayerBias
				end
				if token == threat then
					score *= 0.45
				end
				if token == bot.target then
					score *= 0.7
				end
				if humanoid.Health < humanoid.MaxHealth * 0.4 then
					score *= 0.85
				end
				-- BOT ARCHETYPES: what the personality favours. "weakest" pulls the hurt closer in
				-- proportion to what they have lost; "threat" doubles down on whoever is shooting us;
				-- "engaged" (Flanker, Opportunist) prefers someone busy fighting somebody else. "closest"
				-- is the score as it stands. A team's focus target is pulled closer for everyone on it.
				local pick = bot.archetype and bot.archetype.targetPick
				if pick == "weakest" then
					score *= 0.45 + 0.55 * humanoid.Health / math.max(1, humanoid.MaxHealth)
				elseif pick == "threat" and token == threat then
					score *= 0.5
				elseif pick == "engaged" then
					local attacker, _, hitAt = CombatService.GetLastAttacker(token)
					if attacker and attacker ~= bot and hitAt and now - hitAt < THREAT_WINDOW then
						score *= 0.55
					end
				end
				local focus = bot.focusTeam and teamFocus[bot.focusTeam]
				if focus and focus.token == token and focus.by ~= bot and now - focus.at < THREAT_WINDOW then
					score *= 0.6
					STATS.focusFire += 1
				end
				count += 1
				local row = candidatePool[count]
				if not row then
					row = {}
					candidatePool[count] = row
				end
				row.token, row.character, row.root, row.distance, row.score = token, entry.character, entry.root, distance, score
				row.throughCover = nil
				candidates[count] = row
			end
		end
	end
	if count == 0 then
		return nil
	end
	table.sort(candidates, scratch.byScore)

	local look = flatLook(root)
	local fresh = 0
	for index, candidate in ipairs(candidates) do
		local visible, computed, entry = sightOf(bot, head, candidate.token, candidate.character, now, index == 1)
		if computed then
			fresh += 1
		end
		-- No `entry` means the ray budget refused the look: nothing is known, so nothing is decided.
		if not visible and entry and candidate.distance <= 120 then
			-- Hidden by a barricade rather than by the world: engage, and the shots go into the cover.
			-- The barricade ray is cast when the sight ray is (or once, for a row made while the
			-- target was out past 120), and its answer kept on the sight row for as long as that
			-- "can't see them" is (SIGHT_CACHE_SECONDS). It used to be cast again for every
			-- cached hidden candidate the loop passed, outside the LOS_CHECKS_PER_THINK budget: in a
			-- crowd (#126) up to 12 rays a think (3 sight, 3 barricade, 6 cached rows), now at most 6.
			-- tools/perf_bot_cost.py counts it (7.5 -> 6.0 a think on average, all hidden).
			local structure
			if computed or entry.cover == nil then
				structure = coverBetween(bot, head, candidate.root)
				entry.cover = structure or false
			else
				structure = entry.cover
			end
			-- A cached barricade that has since been shot down no longer hides anyone.
			if structure and structure.Parent then
				candidate.throughCover = structure
				visible = true
			end
		end
		if visible then
			local seen = bot.seen[candidate.token]
			if not seen or now - seen.last > 1 then
				seen = { since = now, last = now }
				bot.seen[candidate.token] = seen
			end
			seen.last = now
			local delay = 0
			if candidate.token ~= threat then
				local to = flat(candidate.root.Position - root.Position)
				if to.Magnitude > 1 and look:Dot(to.Unit) < FRONT_CONE_COS then
					delay = MatchConfig.BotRearNoticeTime
				end
			end
			if now - seen.since >= delay then
				return candidate
			end
		end
		if fresh >= LOS_CHECKS_PER_THINK then
			break
		end
	end
	return nil
end

'''
FT_START = "local function findTarget(bot, root, head, now)"
FT_END = "-- Where a target was last seen"
SCRATCH_START = "local scratch = {"


def read_rev(root, rev, path):
    r = subprocess.run(["git", "-C", root, "show", f"{rev}:{path}"], capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"findtarget_equivalence_check: can't read {rev}:{path}: {r.stderr.strip()}")
    return r.stdout


# --------------------------------------------------------------------------------------------
# E0: nothing outside findTarget changed
# --------------------------------------------------------------------------------------------

def strip_region(src):
    """The source with the findTarget region (the scratch table, its helpers and findTarget) cut out,
    and full-line comments dropped. What is left must match between the two revisions."""
    a = src.index(SCRATCH_START)
    b = src.index(FT_END)
    rest = src[:a] + src[b:]
    return [line for line in rest.split("\n") if not line.strip().startswith("--")]


def scratch_lines(src):
    """The lines of the scratch table literal (the pooled rows planCombatMove shares)."""
    a = src.index(SCRATCH_START)
    b = src.index("\n}\n", a)
    return [line for line in src[a:b].split("\n") if line.strip() and not line.strip().startswith("--")]


def e0(old_src, new_src):
    fails = []
    old_rest, new_rest = strip_region(old_src), strip_region(new_src)
    if old_rest != new_rest:
        for i, (x, y) in enumerate(zip(old_rest, new_rest)):
            if x != y:
                fails.append(f"E0: the source outside findTarget changed (first difference: {x.strip()!r} -> {y.strip()!r})")
                break
        else:
            fails.append(f"E0: the source outside findTarget changed ({len(old_rest)} -> {len(new_rest)} lines)")
    # Every line the old scratch table had is still there, in order.
    new_lines = iter(scratch_lines(new_src))
    for line in scratch_lines(old_src):
        if not any(line == other for other in new_lines):
            fails.append(f"E0: the scratch table lost or changed {line.strip()!r}")
            break
    return fails


# --------------------------------------------------------------------------------------------
# The loaded source: the new BotService with the old findTarget beside it
# --------------------------------------------------------------------------------------------

def old_function(src):
    """findTarget's text in a BotService source."""
    a = src.index(FT_START)
    b = src.find(FT_END, a)
    return src[a:] if b < 0 else src[a:b]


def injected_source(old_ft, new_src):
    old_ft = "_G.FT_OLD = function(bot, root, head, now)" + old_ft[len(FT_START):]
    b = new_src.index(FT_END)
    glue = (old_ft.rstrip() + "\n"
            "_G.FT_NEW, _G.FT_SCRATCH, _G.FT_TEAMFOCUS = findTarget, scratch, teamFocus\n"
            "findTarget = function(bot, root, head, now) return FT_WRAP(bot, root, head, now) end\n\n")
    src = new_src[:b] + glue + new_src[b:]
    # The ray budget: log every Cast, and let the check put the frame's spend back.
    cast = "\tfunction budget.Cast(origin, direction, params, priority)\n"
    assert src.count(cast) == 1
    src = src.replace(cast, cast + "\t\tif FT_RAYLOG then FT_LOGRAY(origin, direction, priority, spent) end\n")
    spent = "\tfunction budget.Spent()\n\t\treturn spent\n\tend\n"
    assert src.count(spent) == 1
    src = src.replace(spent, spent + "\tfunction budget.SetSpent(n)\n\t\tspent = n\n\tend\n")
    return src


# --------------------------------------------------------------------------------------------
# The comparison, in Lua
# --------------------------------------------------------------------------------------------

CHECK_LUA = r"""
FT = { calls = 0, fails = {}, failCount = 0, cov = {}, cost = {} }
local budget = BotService.RaycastBudget
local fmt = string.format

-- Stable names for tables within one call (addresses are the same objects on both sides).
local function id(v)
    if v == nil then return "nil" end
    if type(v) == "table" then
        local name = rawget(v, "name") or rawget(v, "Name")
        if name then return tostring(name) .. "@" .. tostring(v):sub(8) end
    end
    return tostring(v)
end
local function num(x) return fmt("%a", x) end

-- Logs, active only inside a compared call.
FT_RAYLOG = nil
function FT_LOGRAY(origin, direction, priority, spent)
    local cap = budget.FrameCap * (budget.Share[priority or "navigation"] or budget.Share.navigation)
    FT_RAYLOG[#FT_RAYLOG + 1] = fmt("%s,%s,%s>%s,%s,%s:%s:%s", num(origin.X), num(origin.Y), num(origin.Z),
        num(direction.X), num(direction.Y), num(direction.Z), tostring(priority), spent >= cap and "refused" or "granted")
end
local hookLog, rng, sorts = nil, 0, 0
local realRandom, realSort = math.random, table.sort
math.random = function(...) rng = rng + 1 return realRandom(...) end
table.sort = function(t, f) sorts = sorts + 1 return realSort(t, f) end
local rowCalls = 0
local realRow = FT_SCRATCH.row
if realRow then
    FT_SCRATCH.row = function(...) rowCalls = rowCalls + 1 return realRow(...) end
end

local function snapshot(bot)
    local s = { sight = {}, seen = {}, stats = {}, spent = budget.Spent(), tick = bot.hostileTick }
    for token, e in pairs(bot.sight) do s.sight[token] = { e, e.at, e.visible, e.cover } end
    for token, e in pairs(bot.seen) do s.seen[token] = { e, e.since, e.last } end
    for k, v in pairs(STATS) do if type(v) == "number" then s.stats[k] = v end end
    if bot.hostileCache then
        s.cache = {}
        for k, v in pairs(bot.hostileCache) do s.cache[k] = v end
    end
    return s
end

local function restore(bot, s)
    for k in pairs(bot.sight) do bot.sight[k] = nil end
    for token, r in pairs(s.sight) do r[1].at, r[1].visible, r[1].cover = r[2], r[3], r[4]; bot.sight[token] = r[1] end
    for k in pairs(bot.seen) do bot.seen[k] = nil end
    for token, r in pairs(s.seen) do r[1].since, r[1].last = r[2], r[3]; bot.seen[token] = r[1] end
    for k, v in pairs(STATS) do if type(v) == "number" then STATS[k] = s.stats[k] or 0 end end
    budget.SetSpent(s.spent)
    if s.cache then
        for k in pairs(bot.hostileCache) do bot.hostileCache[k] = nil end
        for k, v in pairs(s.cache) do bot.hostileCache[k] = v end
    else
        bot.hostileCache = nil
    end
    bot.hostileTick = s.tick
end

local function sortedKeys(t, name)
    local list = {}
    for k, v in pairs(t) do list[#list + 1] = name(k, v) end
    table.sort(list)
    return table.concat(list, ";")
end

local function describe(bot, ok, ret, before)
    local d = {}
    if not ok then
        d.ret = "error " .. tostring(ret):gsub("^[^:]*:%d+: ", "")
    elseif ret == nil then
        d.ret = "nil"
    else
        d.ret = fmt("%s|%s|%s|%s|%s|%s", id(ret.token), id(ret.character), id(ret.root), num(ret.distance), num(ret.score), id(ret.throughCover))
    end
    d.sight = sortedKeys(bot.sight, function(k, e) return fmt("%s=%s,%s,%s", id(k), num(e.at), tostring(e.visible), id(e.cover)) end)
    d.seen = sortedKeys(bot.seen, function(k, e) return fmt("%s=%s,%s", id(k), num(e.since), num(e.last)) end)
    local moved = {}
    for k, v in pairs(STATS) do
        if type(v) == "number" and v ~= (before.stats[k] or 0) then moved[#moved + 1] = fmt("%s+%s", k, num(v - (before.stats[k] or 0))) end
    end
    table.sort(moved)
    d.stats = table.concat(moved, ";")
    d.spent = budget.Spent()
    return d
end

local function fail(msg)
    FT.failCount = FT.failCount + 1
    if #FT.fails < 12 then FT.fails[#FT.fails + 1] = msg end
end

-- Instructions: a count hook every 10 VM instructions, paused inside the mock raycast (it walks every
-- wall and character of the sim's world, which Roblox's engine does not do in Lua).
-- Only BotService's own code is counted: a Luau Vector3 is a native value, not the Lua tables the
-- mock world builds, and the sim's other mocks are not game code. (Sampled: each tick is charged to
-- the function running.)
local instr, counted = 0, false
local getinfo = debug.getinfo
local function tick()
    if getinfo(2, "S").source == "BotService" then instr = instr + 10 end
end
local function counting(on)
    counted = on
    if on then debug.sethook(tick, "", 10) else debug.sethook() end
end
-- The hook log is the check's own work: not counted either.
function FT_HOOKED(bot, other)
    if not hookLog then return end
    if counted then debug.sethook() end
    hookLog[#hookLog + 1] = id(bot) .. ">" .. id(other)
    if counted then debug.sethook(tick, "", 10) end
end
local realRaycast = workspace.Raycast
workspace.Raycast = function(...)
    if not counted then return realRaycast(...) end
    debug.sethook()
    local r = realRaycast(...)
    debug.sethook(tick, "", 10)
    return r
end

FT.scenario = "?"
local function bump(t, k, v) t[k] = (t[k] or 0) + (v or 1) end

function FT_WRAP(bot, root, head, now)
    local before = snapshot(bot)
    local scen = FT.scenario
    -- Old.
    FT_RAYLOG, hookLog, rng, sorts, instr = {}, {}, 0, 0, 0
    counting(true)
    local okA, retA = pcall(FT_OLD, bot, root, head, now)
    counting(false)
    local instrA, sortsA, rngA, raysA, hooksA = instr, sorts, rng, FT_RAYLOG, hookLog
    local rowsA = okA and #FT_SCRATCH.candidates or 0
    local a = describe(bot, okA, retA, before)
    local oldList = {}
    for i, row in ipairs(FT_SCRATCH.candidates) do oldList[i] = row.score end
    restore(bot, before)
    -- New.
    FT_RAYLOG, hookLog, rng, sorts, instr, rowCalls = {}, {}, 0, 0, 0, 0
    counting(true)
    local okB, retB = pcall(FT_NEW, bot, root, head, now)
    counting(false)
    local instrB, sortsB, rngB = instr, sorts, rng
    local b = describe(bot, okB, retB, before)
    local raysB, hooksB = FT_RAYLOG, hookLog
    FT_RAYLOG, hookLog = nil, nil
    FT.calls = FT.calls + 1

    local where = fmt("%s call %d (%s)", scen, FT.calls, bot.character and bot.character.Name or "?")
    if a.ret ~= b.ret then fail(fmt("E1 %s: returned %s, the old one %s", where, b.ret, a.ret)) end
    local ra, rb = table.concat(raysA, " "), table.concat(raysB, " ")
    if ra ~= rb or a.spent ~= b.spent then
        fail(fmt("E2 %s: rays differ (%d against the old %d; spend %d against %d)", where, #raysB, #raysA, b.spent, a.spent))
    end
    if a.sight ~= b.sight then fail(fmt("E3 %s: sight rows differ", where)) end
    if a.seen ~= b.seen then fail(fmt("E3 %s: seen rows differ", where)) end
    if a.stats ~= b.stats then fail(fmt("E4 %s: STATS moved %s, the old one %s", where, b.stats, a.stats)) end
    if rngB ~= rngA then fail(fmt("E5 %s: %d math.random draws, the old one %d", where, rngB, rngA)) end
    if table.concat(hooksA, " ") ~= table.concat(hooksB, " ") then
        fail(fmt("E6 %s: the hook was asked %d questions, not the old one's %d in the same order", where, #hooksB, #hooksA))
    end

    -- Cost, paired.
    local c = FT.cost[scen]
    if not c then c = { calls = 0, instrOld = 0, instrNew = 0, rowsOld = 0, rowsNew = 0, sortsOld = 0, sortsNew = 0, hooksOld = 0, hooksNew = 0, rays = 0 } FT.cost[scen] = c end
    c.calls = c.calls + 1
    c.instrOld, c.instrNew = c.instrOld + instrA, c.instrNew + instrB
    c.rowsOld, c.rowsNew = c.rowsOld + rowsA, c.rowsNew + rowCalls
    c.sortsOld, c.sortsNew = c.sortsOld + sortsA, c.sortsNew + sortsB
    c.hooksOld, c.hooksNew = c.hooksOld + #hooksA, c.hooksNew + #hooksB
    c.rays = c.rays + #raysB

    -- What was examined.
    local cov = FT.cov
    bump(cov, "calls")
    if not okA then bump(cov, "errors") end
    if okA and retA ~= nil then bump(cov, "returned a target") end
    if okA and retA ~= nil and retA.throughCover then bump(cov, "through a barricade") end
    if #raysA > 0 then bump(cov, "cast rays") end
    for _, r in ipairs(raysA) do if r:find("refused") then bump(cov, "had a ray refused") break end end
    if sortsB > 0 then bump(cov, "new code fell back to the full sort") end
    local tie = false
    for i = 2, #oldList do if oldList[i] == oldList[i - 1] then tie = true break end end
    if tie then bump(cov, "old list had an exact score tie") end
    if rowsA >= 20 then bump(cov, "20+ candidates") end
    for _, s in ipairs(oldList) do if s ~= s then bump(cov, "a NaN score in the list") break end end
    -- Who was in reach: the classes findTarget must keep or drop.
    local vision = MatchConfig.BotVisionRange
    local reach = math.max(vision, bot.weapon and bot.weapon.range or 0)
    local threat = now - bot.lastHurtAt < THREAT_WINDOW and CombatService.GetLastAttacker(bot) or nil
    local seen = {}
    for character, token in pairs(Combatants.All()) do
        if token ~= bot and character.root then
            local d = (character.root.Position - root.Position).Magnitude
            if d <= reach then
                if d == vision then seen["a candidate at exactly vision range"] = true end
                if token == threat and d > vision then seen["whoever shot us, past vision range"] = true end
                if token == threat and d == reach then seen["whoever shot us, at exactly gun range"] = true end
                if character.humanoid.Health <= 0 then seen["a dead one in reach"] = true end
                if not SIM.hostile(bot, token) then seen["a team-mate in reach"] = true end
                if token.isPlayer then seen["a player in reach"] = true end
            end
        end
    end
    for k in pairs(seen) do bump(cov, k) end
    if okB and retB ~= nil then return retB end
    if not okB then error(retB, 0) end
    return nil
end
"""

# A world run: N bots, mixed archetypes and guns, two players, walls; 8 s of updateBot.
WORLD_LUA = r"""
local ARCHES = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }
local GUNS = { "CrocodiloRifle", "CrocodiloRifle", "RotSMG", "TralalaShotgun", "GrassToucherDMR", "LarilaSniper" }
function FT_WORLD(layout, n, seconds, seed)
    SIM.reset(seed)
    FT.scenario = layout .. "-" .. n
    local teams = layout == "teams"
    SIM.teamMode = teams
    SIM.modeId = teams and "TeamDeathmatch" or "BattleRoyale"
    local spread = layout == "spread"
    local extent = spread and 600 or 32
    for i = 1, spread and 30 or 8 do
        local p = Vector3.new((math.random() * 2 - 1) * extent, 2.5, (math.random() * 2 - 1) * extent)
        SIM.addWall(p, Vector3.new(4 + math.random() * 8, 5, 1.5 + math.random() * 6))
    end
    for i = 1, n do
        local team = teams and (i % 2 + 1) or nil
        local x, z
        if teams then
            x, z = (math.random() * 2 - 1) * 30, (team == 1 and -40 or 40) + (math.random() * 2 - 1) * 12
        else
            x, z = (math.random() * 2 - 1) * extent, (math.random() * 2 - 1) * extent
        end
        local bot = SIM.makeBot("B" .. i, ARCHES[(i - 1) % #ARCHES + 1], GUNS[(i - 1) % #GUNS + 1], Vector3.new(x, 3, z), team,
            { maxHealth = 400, bandages = 1 })
        bot.character.root.CFrame.LookVector = Vector3.new(math.random() * 2 - 1, 0, math.random() * 2 - 1).Unit
    end
    -- Two players (BotPlayerBias) who plink back, and a dummy shooter: threats and hurt rows.
    for i = 1, 2 do
        local p = SIM.makeDummy("P" .. i, Vector3.new((math.random() * 2 - 1) * extent, 3, (math.random() * 2 - 1) * extent), teams and i or nil,
            { shooter = 8, invulnerable = true })
        p.isPlayer = true
    end
    SIM.makeDummy("D", Vector3.new(0, 3, 0), nil, { shooter = 12, invulnerable = true })
    SIM.run(seconds)
    return #SIM.errors
end
"""

# Built states: one think each.
EDGE_LUA = r"""
local budget = BotService.RaycastBudget
local ARCHES = { "Rusher", "Marksman", "Flanker", "Anchor", "Opportunist", "Survivor" }
local function pick(list) return list[math.random(#list)] end
function FT_EDGE(trials, seed, family)
    local vision = MatchConfig.BotVisionRange
    local errors = 0
    for trial = 1, trials do
        SIM.reset(seed + trial)
        FT.scenario = "edge-" .. family
        local teams = family == "teams" or (family == "mixed" and math.random() < 0.4)
        SIM.teamMode = teams
        local cap = math.random() < 0.3 and math.random(1, 8) or 240
        budget.FrameCap = cap
        local gun = pick({ "CrocodiloRifle", "RotSMG", "TralalaShotgun", "LarilaSniper", "SahurPistol" })
        local bot = SIM.makeBot("B", pick(ARCHES), gun, Vector3.new(0, 3, 0), teams and 1 or nil)
        if math.random() < 0.15 then bot.archetype = nil end
        local look = Vector3.new(math.random() * 2 - 1, 0, math.random() * 2 - 1)
        bot.character.root.CFrame.LookVector = look.Magnitude > 0.01 and look.Unit or Vector3.new(0, 0, 1)
        local reach = math.max(vision, bot.weapon.range or 0)
        local n = family == "packed" and math.random(15, 50) or math.random(2, 50)
        local step = pick({ 1, 2, 5, 10 })
        local others = {}
        for i = 1, n do
            local kind = math.random()
            local p
            if family == "packed" or kind < 0.45 then
                -- A lattice: many exact distance ties.
                p = Vector3.new(math.random(-4, 4) * step, 3, math.random(-4, 4) * step)
            elseif kind < 0.6 then
                -- A ring at one of a few radii, on the axes: exact ties at a larger distance.
                local r = pick({ 20, 40, 80 })
                local axis = math.random(4)
                p = Vector3.new(axis == 1 and r or axis == 2 and -r or 0, 3, axis == 3 and r or axis == 4 and -r or 0)
            elseif kind < 0.72 then
                -- The reach edges: exactly vision range, just past it, exactly gun range, just past it.
                local r = pick({ vision, vision + 1e-9 * vision, vision + 0.5, reach, reach + 0.5, (vision + reach) / 2 })
                p = Vector3.new(r, 3, 0)
                if math.random() < 0.5 then p = Vector3.new(0, 3, -r) end
            else
                p = Vector3.new((math.random() * 2 - 1) * 120, 3, (math.random() * 2 - 1) * 120)
            end
            local team = teams and math.random(1, 2) or nil
            local token
            local role = math.random()
            if role < 0.55 then
                token = SIM.makeBot("O" .. i, pick(ARCHES), "CrocodiloRifle", p, team)
            else
                token = SIM.makeDummy("O" .. i, p, team, {})
                if role < 0.75 then token.isPlayer = true end
            end
            local h = token.character.humanoid
            local hp = math.random()
            if hp < 0.08 then h.Health = 0
            elseif hp < 0.12 then h.Health = -5
            elseif hp < 0.3 then h.Health = h.MaxHealth * math.random() * 0.4
            elseif hp < 0.36 then h.Health = h.MaxHealth * 0.4
            elseif hp < 0.40 then h.MaxHealth = 0; h.Health = 1
            elseif hp < 0.42 then h.MaxHealth = math.huge; h.Health = math.huge
            end
            others[#others + 1] = token
        end
        local now = CLOCK
        -- Threats: shot at recently by one of them (sometimes one past vision range).
        if math.random() < 0.6 then
            local shooter = pick(others)
            if math.random() < 0.4 then
                shooter.character.root.Position = Vector3.new(pick({ vision + 0.5, (vision + reach) / 2, reach, reach + 0.5 }), 3, 0)
            end
            SIM.lastAttacker[bot] = { attacker = shooter, at = now - math.random() * 4 }
            bot.lastHurtAt = now - math.random() * 4
        end
        -- "Engaged": others busy with somebody (sometimes with us).
        for _, o in ipairs(others) do
            if math.random() < 0.3 then
                SIM.lastAttacker[o] = { attacker = math.random() < 0.2 and bot or pick(others), at = now - math.random() * 4 }
            end
        end
        if math.random() < 0.5 then bot.target = pick(others) end
        -- Focus fire.
        if teams and math.random() < 0.5 then
            bot.focusTeam = 1
            FT_TEAMFOCUS[1] = { token = pick(others), by = math.random() < 0.2 and bot or pick(others), at = now - math.random() * 4 }
        end
        -- The hook: sometimes it errors (the pcall's failure counts as hostile).
        if math.random() < 0.15 then
            local real = BotService.IsHostile
            local bad = pick(others)
            BotService.IsHostile = function(a, b) if b == bad then error("hook failed") end return real(a, b) end
        end
        -- A shared ride: whoever sits in our vehicle is no target.
        if math.random() < 0.1 then
            local model = { Name = "Car" }
            bot.ride = { model = model }
            for _, o in ipairs(others) do
                if math.random() < 0.3 then o.character.humanoid.SeatPart = { Parent = model } end
            end
        end
        -- Walls, barricades (some shot down), smoke.
        for i = 1, math.random(0, 8) do
            local c = Vector3.new((math.random() * 2 - 1) * 40, 2.5, (math.random() * 2 - 1) * 40)
            if math.random() < 0.4 then
                local owner = math.random() < 0.2 and bot or pick(others)
                local model = { Name = "RotBarricade", __isStructure = true, Parent = workspace, owner = owner, health = 250 }
                local wall = SIM.addWall(c, Vector3.new(8, 5, 1.5), model)
                model.wall = wall
                if math.random() < 0.3 then bot.ownStructures[model] = true end
                if math.random() < 0.2 then model.Parent = nil end
            else
                SIM.addWall(c, Vector3.new(2 + math.random() * 8, 5, 1.5))
            end
        end
        if math.random() < 0.2 then
            SIM.smokes[1] = { position = Vector3.new((math.random() * 2 - 1) * 20, 3, (math.random() * 2 - 1) * 20), radius = 6, untilTime = now + 5 }
        end
        -- Sight and seen rows left from earlier thinks: stale, fresh, hidden, seen, behind cover.
        for _, o in ipairs(others) do
            if math.random() < 0.5 then
                local cover = nil
                local r = math.random()
                if r < 0.3 then cover = false elseif r < 0.5 then
                    local model = { Name = "RotBarricade", Parent = math.random() < 0.7 and workspace or nil }
                    cover = model
                end
                bot.sight[o] = { at = now - math.random() * 0.8, visible = math.random() < 0.3, cover = cover }
            end
            if math.random() < 0.4 then
                local since = now - math.random() * 2
                bot.seen[o] = { since = since, last = since + math.random() * (now - since) }
            end
        end
        refreshCombatants()
        budget.BeginFrame()
        if cap < 240 and math.random() < 0.7 then budget.SetSpent(math.random(0, cap)) end
        local root, head = bot.character.root, bot.character.head
        local ok = pcall(FT_WRAP, bot, root, head, now)
        if not ok then errors = errors + 1 end
        budget.FrameCap = 240
    end
    return errors
end
"""

WORLDS = [("spread", 15), ("spread", 30), ("spread", 50), ("packed", 15), ("packed", 30), ("packed", 50),
          ("teams", 15), ("teams", 30), ("teams", 50)]
EDGES = [("mixed", 2500), ("packed", 800), ("teams", 800)]
WORLD_SECONDS = 8

# C1's bounds (packed-50, paired): new/old.
ROWS_BOUND = 0.25
SORTS_BOUND = 0.05
INSTR_BOUND = 0.90


class Check:
    def __init__(self, root, old_ft, new_src):
        src = injected_source(old_ft, new_src)
        self.rt = sim.Runtime(root, src, new_src)
        lua, g = self.rt.lua, self.rt.g
        # The hook log: SIM.reset installs BotService.IsHostile -> SIM.hostile; log every ask.
        lua.execute("local real = SIM.hostile; SIM.hostile = function(a, b) FT_HOOKED(a, b) return real(a, b) end")
        lua.execute(CHECK_LUA)
        lua.execute(WORLD_LUA)
        lua.execute(EDGE_LUA)
        self.g = g

    def run(self, worlds=WORLDS, edges=EDGES, seconds=WORLD_SECONDS):
        g = self.g
        errors = {}
        for layout, n in worlds:
            e = g.FT_WORLD(layout, n, seconds, 7 + n)
            errors[f"{layout}-{n}"] = int(e)
        for family, trials in edges:
            errors[f"edge-{family}"] = int(g.FT_EDGE(trials, 1000 * len(family), family))
        ft = g.FT
        cost = {}
        for k in ft.cost.keys():
            c = ft.cost[k]
            cost[k] = {f: c[f] for f in c.keys()}
        return {"calls": int(ft.calls), "failCount": int(ft.failCount), "fails": list(ft.fails.values()),
                "cov": {k: int(ft.cov[k]) for k in ft.cov.keys()}, "cost": cost, "simErrors": errors}


def c1(cost):
    c = cost.get("packed-50")
    if not c or c["calls"] == 0:
        return ["C1: no packed-50 calls to measure"]
    fails = []
    rows = c["rowsNew"] / max(1, c["rowsOld"])
    sorts = c["sortsNew"] / c["calls"]
    instr = c["instrNew"] / max(1, c["instrOld"])
    if rows > ROWS_BOUND:
        fails.append(f"C1: packed-50 made {rows:.2f} of the old rows per call (bound {ROWS_BOUND})")
    if sorts > SORTS_BOUND:
        fails.append(f"C1: packed-50 sorted on {sorts:.1%} of calls (bound {SORTS_BOUND:.0%})")
    if instr > INSTR_BOUND:
        fails.append(f"C1: packed-50 ran {instr:.2f} of the old instructions (bound {INSTR_BOUND})")
    return fails


def evaluate(old_ft, new_src, root, base_src=None, quick=False):
    fails = e0(base_src, new_src) if base_src is not None else []
    check = Check(root, old_ft, new_src)
    if quick:
        r = check.run(worlds=[("packed", 50), ("teams", 30), ("spread", 30)], edges=[(f, n // 2) for f, n in EDGES], seconds=5)
    else:
        r = check.run()
    fails += r["fails"]
    if r["failCount"] > len(r["fails"]):
        fails.append(f"... {r['failCount'] - len(r['fails'])} more E1-E6 differences")
    for name, n in r["simErrors"].items():
        if n and not name.startswith("edge"):
            fails.append(f"{name}: {n} bot think errors in the sim")
    fails += c1(r["cost"])
    return fails, r


def report(r):
    print("--- cost per findTarget call, old -> new (paired: the same calls on the same states)")
    order = [f"{l}-{n}" for l, n in WORLDS] + [f"edge-{f}" for f, _ in EDGES]
    for name in order:
        c = r["cost"].get(name)
        if not c:
            continue
        n = max(1, c["calls"])
        print(f"  {name:12s} {int(c['calls']):6d} calls  instructions {c['instrOld'] / n:7.0f} -> {c['instrNew'] / n:7.0f} "
              f"({c['instrNew'] / max(1, c['instrOld']):.2f})  rows {c['rowsOld'] / n:5.1f} -> {c['rowsNew'] / n:4.2f}  "
              f"sorts {c['sortsOld'] / n:4.2f} -> {c['sortsNew'] / n:4.3f}  hook asks {c['hooksOld'] / n:5.1f} -> {c['hooksNew'] / n:5.1f}  "
              f"rays {c['rays'] / n:4.2f} (both)")
    print("--- what the compared calls covered")
    for k, v in sorted(r["cov"].items()):
        print(f"  {k}: {v}")


PLANTS = [
    ("tie-break: equal scores taken in grid order, not table.sort's",
     "or (cursor < held and lowScores[cursor + 1] == lowScores[cursor]) then",
     "then"),
    ("dropped class: whoever shoots us from past vision range",
     "if distance <= vision or (token == threat and distance <= reach) then",
     "if distance <= vision then"),
    ("dropped class: players",
     "if token ~= bot and entry.humanoid.Health > 0 and hostile(bot, token) then",
     "if token ~= bot and entry.humanoid.Health > 0 and hostile(bot, token) and not entry.isPlayer then"),
    ("dead ones kept (Health 0 counts as alive)",
     "entry.humanoid.Health > 0 and hostile(bot, token) then",
     "entry.humanoid.Health >= 0 and hostile(bot, token) then"),
    ("team-mates kept (the hook still asked)",
     "entry.humanoid.Health > 0 and hostile(bot, token) then",
     "entry.humanoid.Health > 0 and (hostile(bot, token) or true) then"),
    ("skipped threat preference (the 0.45 for whoever shot us)",
     "\t\t\t\tif token == threat then\n\t\t\t\t\tscore *= 0.45\n",
     "\t\t\t\tif token == threat then\n\t\t\t\t\tscore *= 1\n"),
    ("reach off by one: vision range exclusive",
     "if distance <= vision or (token", "if distance < vision or (token"),
    ("reach off by one: gun range exclusive",
     "(token == threat and distance <= reach) then", "(token == threat and distance < reach) then"),
    ("ray reorder: the first two candidates swapped",
     "\t\t\t\tlocal at = lowAt[cursor]\n",
     "\t\t\t\tlocal at = lowAt[(cursor == 1 and held >= 3) and 2 or (cursor == 2 and held >= 3) and 1 or cursor]\n"),
    ("the every-think recheck given to the second candidate",
     "candidate.character, now, index == 1)", "candidate.character, now, index == 2)"),
    ("the held list keeps the highest scores, not the lowest",
     "elseif held < keep or score < lowScores[keep] then", "elseif held < keep or score > lowScores[keep] then"),
    ("the walk stops at the held few (no sort past them)",
     "if unordered or (cursor == keep and held == keep) or", "if unordered or"),
    ("after the sort the walk starts again from the top",
     "\t\t\t\tsorted = true\n", "\t\t\t\tsorted = true\n\t\t\t\tindex = 0\n"),
    ("NaN guard dropped",
     "\t\t\t\tif score ~= score then\n\t\t\t\t\tunordered = true\n",
     "\t\t\t\tif false then\n\t\t\t\t\tunordered = true\n"),
    ("cost regression: every think builds and sorts the whole list again",
     "if unordered or (cursor == keep", "if true or unordered or (cursor == keep"),
    ("a change outside findTarget (LOS_CHECKS_PER_THINK 3 -> 4)",
     "local LOS_CHECKS_PER_THINK = 3", "local LOS_CHECKS_PER_THINK = 4"),
]


def main():
    args = sys.argv[1:]
    root = args[0] if args and not args[0].startswith("--") else "."
    new_src = open(os.path.join(root, BOTSERVICE), encoding="utf-8").read()
    if "--old" in args:
        rev = args[args.index("--old") + 1]
        old_ft, old_from = old_function(read_rev(root, rev, BOTSERVICE)), rev
    else:
        old_ft, old_from = REFERENCE_FT, "the reference copy (927bc44)"
    base = args[args.index("--base") + 1] if "--base" in args else None
    try:
        head = subprocess.run(["git", "-C", root, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    except OSError:
        head = "?"
    print(f"findtarget_equivalence_check: old findTarget from {old_from}, new from the working tree (HEAD {head})")

    if "--plant" in args:
        # E0 for the plants: against the unplanted working tree.
        caught = 0
        for name, a, b in PLANTS:
            if new_src.count(a) != 1:
                print(f"  PLANT NOT APPLIED ({new_src.count(a)} matches): {name}")
                continue
            fails, _ = evaluate(old_ft, new_src.replace(a, b), root, base_src=new_src, quick=True)
            if fails:
                caught += 1
                print(f"  caught: {name}\n      {fails[0]}")
            else:
                print(f"  MISSED: {name}")
        print(f"findtarget_equivalence_check --plant: {caught}/{len(PLANTS)} planted faults caught")
        sys.exit(0 if caught == len(PLANTS) else 1)

    if base:
        base_src = read_rev(root, base, BOTSERVICE)
        print(f"E0 against {base}: outside findTarget's region the source must be {base}'s")
    else:
        base_src = None
        print("E0 not run (it needs --base REV, the revision the change was cut from)")
    fails, r = evaluate(old_ft, new_src, root, base_src=base_src)
    report(r)
    for f in fails:
        print("FAIL " + f)
    print(f"findtarget_equivalence_check: {r['calls']} findTarget calls compared "
          f"({len(WORLDS)} world runs, {sum(n for _, n in EDGES)} built states); {len(fails)} failures")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
