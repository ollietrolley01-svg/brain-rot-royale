"""#57 / #110 roadkill, end to end: does a car at speed hurt the person it drives into, and whom does it credit?

Runs the game's REAL modules whole in lupa (tools/roadkill_proof_world.lua): VehicleService, CombatService,
RoadkillPass, Combatants, RateLimit, Remotes, SafeValue, VehicleArmor, MatchConfig. Vehicles are made with
the real VehicleService.Create, sat in through the real drive prompt (trySit) or VehicleService.BotSit,
and stepped through the real loop VehicleService.Start connects to RunService.Stepped. A player's car is
swept by the driver's client exactly as VehicleClient does it: the two pieces of VehicleClient that do it
(the RoadkillPass it makes in startDriving, and the head of its Stepped loop up to the sweep) are cut from
the real file and run as the driver's machine, and their FireServer reaches the real VehicleRoadkill
handler. A death goes through the real CombatService.HandleDeath and MatchService's own
CombatService.OnElimination (cut from the real file) to the kill feed's `method`. Team mode's
DamageVeto, IsProtected and BreakProtection are cut from the real ModeTeams.

The invariants (each one has a planted fault aimed at it, see PLANTS):
  I1  every model, driven by a player at its top speed into an enemy player, hurts them by the formula,
      through the driver's client's report, and credits the driver (the "absent or silent" question);
  I2  the same for a bot at the wheel (the server sweeps its car), credited to the bot;
  I3  a rider of the car is never hurt by it, whichever path the hit comes by;
  I4  at or under 12 studs/s nothing is ever dealt, whichever path;
  I5  a team-mate, or an enemy under spawn protection, is never hurt;
  I6  a roadkill kill reaches the kill feed as "Roadkill" with the driver's name.
Oliver's rules of 2026-09-25 (report findings 2-4, each with a planted fault too):
  I7  a vetoed hit (a team-mate) does nothing to the body: no throw, no knock-down, no RoadkillThrow; the
      car still goes through. A hit that hurts and does not kill still throws;
  I8  a rider inside an armoured cabin is never run over (the sweep leaves them out, the server refuses
      them); a rider of an open car still is;
  I9  a car nobody drives deals the same CombatDamageScale'd hit as a driven one, credited to nobody;
  I10 no mode grants spawn protection (GameModes, "get rid of spawn prot").
Things it finds but does not fail on are printed as FINDING lines (the report says what they mean).

    python tools/roadkill_proof_check.py [root]            the checks
    python tools/roadkill_proof_check.py [root] --plant    the planted faults; every one must be caught

Not covered: Roblox's physics (whether a real contact happens, whether chassis.Touched fires on the server
for a client-owned car), network lag between the driver, the server and the victim (the world is one
machine), and anything a player sees drawn on screen.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("roadkill_proof_check: needs lupa (pip install lupa)")

HERE = os.path.dirname(os.path.abspath(__file__))

# The numbers the report's damage table was written from (VehicleService's ROADKILL_FLOOR and
# ROADKILL_DAMAGE_PER, MatchConfig.CombatDamageScale). They are pinned here, not read from the game, so a
# retune shows up as a failure and the table gets redone. The scale was 0.92 when the report was written;
# main moved it to 0.736 (pc/ttk-plus-25), so the report's numbers are these times 0.8.
PIN_FLOOR, PIN_PER, PIN_SCALE = 12, 1.8, 0.736


# ---------------------------------------------------------------------------------------------- Luau
# The converter is tools/explosive_dispatch_check.py's (branch task/prove-explosive-ammo): compound
# assignment, and `continue` as a goto to a label at the end of its loop.

def _strip(line, state):
    out, i, n = [], 0, len(line)
    while i < n:
        if state:
            j = line.find(state, i)
            if j < 0:
                return "".join(out), state
            i, state = j + len(state), None
            continue
        if line.startswith("--", i):
            m = re.match(r"--\[(=*)\[", line[i:])
            if not m:
                break
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            continue
        m = re.match(r"\[(=*)\[", line[i:])
        if m:
            state, i = "]" + m.group(1) + "]", i + len(m.group(0))
            out.append('""')
            continue
        c = line[i]
        if c in "\"'`":
            j = i + 1
            while j < n and line[j] != c:
                j += 2 if line[j] == "\\" else 1
            out.append('""')
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out), state


def luau_to_lua(src):
    src = re.sub(r"^(\s*)([\w.\[\]\"':()]+) ([+\-*/%^]|\.\.)= (.+?)(\s*--.*)?$",
                 lambda m: "%s%s = %s %s (%s)%s" % (m.group(1), m.group(2), m.group(2), m.group(3), m.group(4), m.group(5) or ""),
                 src, flags=re.M)
    stack, state, pending, count, out = [], None, 0, 0, []
    for line in src.split("\n"):
        code, state = _strip(line, state)
        new, closes = line, []
        for t in re.findall(r"[A-Za-z_]\w*", code):
            if t == "function" or t == "if":
                stack.append([t, None])
            elif t in ("while", "for"):
                stack.append(["loop", None])
                pending += 1
            elif t == "do":
                if pending:
                    pending -= 1
                else:
                    stack.append(["do", None])
            elif t == "repeat":
                stack.append(["repeat", None])
            elif t == "continue":
                loop = next(e for e in reversed(stack) if e[0] in ("loop", "repeat"))
                if loop[1] is None:
                    count += 1
                    loop[1] = "continue_%d" % count
                new = re.sub(r"\bcontinue\b", "goto " + loop[1], new, count=1)
            elif t in ("end", "until"):
                e = stack.pop()
                if e[1]:
                    closes.append(e[1])
        for label in closes:
            new = re.sub(r"\bend\b", "::%s:: end" % label, new, count=1)
        out.append(new)
    if stack:
        raise SyntaxError("unbalanced blocks")
    return "\n".join(out)


# ---------------------------------------------------------------------------------------------- tree

FILES = {
    "VehicleService": ("ServerScriptService", "Modules"), "CombatService": ("ServerScriptService", "Modules"),
    "Combatants": ("ServerScriptService", "Modules"), "RateLimit": ("ServerScriptService", "Modules"),
    "ModeTeams": ("ServerScriptService", "Modules"), "MatchService": ("ServerScriptService", "Modules"),
    "RoadkillPass": ("ReplicatedStorage", "Shared"), "Remotes": ("ReplicatedStorage", "Shared"),
    "SafeValue": ("ReplicatedStorage", "Shared"), "VehicleArmor": ("ReplicatedStorage", "Shared"),
    "VehicleCover": ("ReplicatedStorage", "Shared"), "MatchConfig": ("ReplicatedStorage", "Shared"),
    "MovementConfig": ("ReplicatedStorage", "Shared"), "VehicleDynamics": ("ReplicatedStorage", "Shared"),
    "VehicleModels": ("ReplicatedStorage", "Shared"), "GameModes": ("ReplicatedStorage", "Shared"),
}


class Tree:
    """The game's text, read from `root`, with in-memory replacements (the planted faults)."""

    def __init__(self, root, swaps=None):
        self.root, self.swaps = root, swaps or {}

    def text(self, name):
        if name == "VehicleClient":
            path = os.path.join(self.root, "StarterPlayerScripts", "VehicleClient.client.lua")
        elif name in FILES:
            path = os.path.join(self.root, *FILES[name], name + ".lua")
        else:
            return None
        text = open(path, encoding="utf-8").read()
        for before, after in self.swaps.get(name, []):
            if text.count(before) != 1:
                sys.exit("roadkill_proof_check: plant anchor missing or not unique in %s: %r" % (name, before[:80]))
            text = text.replace(before, after, 1)
        return text

    def lua(self, name):
        text = self.text(name)
        return luau_to_lua(text) if text is not None else None


def cut(text, head, tail="\nend\n"):
    a = text.index(head)
    return text[a:text.index(tail, a) + len(tail)]


def cuts(tree):
    vd = tree.text("VehicleDynamics")
    handling = cut(vd, "VehicleDynamics.Handling = {", "\n}\n")
    vm = tree.text("VehicleModels")
    models = []
    for m in re.finditer(r"^VehicleModels\.Models\.(\w+) = \{\n((?:\t[^\n]*\n){1,6})", vm, re.M):
        kind = re.search(r'\tkind = "(\w+)"', m.group(2)).group(1)
        name = re.search(r'\tdisplayName = "([^"]+)"', m.group(2)).group(1)
        models.append((m.group(1), kind, name))
    mt = tree.text("ModeTeams")
    veto = "\n".join([cut(mt, "local function protectionNowMs()"), cut(mt, "function ModeTeams.DamageVeto("),
                      cut(mt, "function ModeTeams.IsProtected("), cut(mt, "function ModeTeams.BreakProtection(")])
    ms = tree.text("MatchService")
    elimination = cut(ms, "CombatService.OnElimination = function(")
    vc = tree.text("VehicleClient")
    # startDriving's RoadkillPass, and the head of the drive loop: its guards, then the sweep.
    client_pass = cut(vc, "\tdriving.roadkill = RoadkillPass.new(", "\n\tend)\n")
    loop = cut(vc, "RunService.Stepped:Connect(function(_, dt)\n", "\tdriving.roadkill:Sweep(dt, tick())\n")
    loop = "return function(_, dt)\n" + loop[len("RunService.Stepped:Connect(function(_, dt)\n"):] + "end\n"
    return {
        "handling": luau_to_lua(handling),
        "models": models,
        "veto": luau_to_lua(veto),
        "elimination": luau_to_lua(elimination),
        "clientPass": luau_to_lua(client_pass),
        "clientLoop": luau_to_lua(loop),
    }


# ---------------------------------------------------------------------------------------------- scenes

SCENES = r"""
local w, C, pins = ...
local V3, CF = w.Vector3.new, w.CFrame.new
local W = w.W
local now = w.now
local DT = 1 / 60

-- The real handling and the model list, then the real services.
w.chunk(C.handling, "Handling", { VehicleDynamics = w.VehicleDynamics })
for i = 1, #C.models do
    local m = C.models[i]
    w.VehicleModels.Models[m[1]] = { kind = m[2], displayName = m[3] }
end
local VS = w.module("VehicleService")
local CS = w.module("CombatService")
local Combatants = w.module("Combatants")
local RoadkillPass = w.module("RoadkillPass")
VS.Start()

-- Team mode's rules, cut from the real ModeTeams: `mt.active`, `mt.teamOf`, `mt.protectedUntil` are
-- the file's own upvalues.
local mt = { ModeTeams = {}, active = false, teamOf = {}, protectedUntil = {}, Combatants = Combatants }
w.chunk(C.veto, "ModeTeams(veto)", mt)
local function teamMode(on)
    mt.active = on
    -- GameMode.lua:733 hangs the veto on in a team mode, and :818 takes it off again.
    CS.DamageVeto = on and mt.ModeTeams.DamageVeto or nil
end

-- MatchService's OnElimination, cut from the real file; `eliminate` records what the feed is sent.
local feed = {}
w.chunk(C.elimination, "OnElimination", {
    CombatService = CS,
    ItemData = { Get = function() return nil end },
    RewardService = w.proxy("RewardService"),
    QuestService = w.proxy("QuestService"),
    Combatants = Combatants,
    eliminate = function(victim, killer, method, weaponId)
        -- MatchService.eliminate sends `method = killerToken and method or nil` (MatchService.lua:1577).
        table.insert(feed, { victim = victim, killer = killer, method = killer and method or nil, weaponId = weaponId })
    end,
})

--------------------------------------------------------------------------------
-- People
--------------------------------------------------------------------------------
local userId = 0
local function body(name, at)
    local model = w.Instance.new("Model", w.workspace)
    model.Name = name
    local root = w.Instance.new("Part", model)
    root.Name = "HumanoidRootPart"
    root.Size = V3(2, 2, 1)
    root.CFrame = CF(at)
    local torso = w.Instance.new("Part", model)
    torso.Name = "Torso"
    torso.Size = V3(2, 2, 1)
    torso.CFrame = CF(at)
    local head = w.Instance.new("Part", model)
    head.Name = "Head"
    head.Size = V3(1, 1, 1)
    head.CFrame = CF(at + V3(0, 1.5, 0))
    local humanoid = w.Instance.new("Humanoid", model)
    humanoid.RootPart = root
    model.PrimaryPart = root
    return model, humanoid
end
local function watchDeath(token, humanoid)
    -- MatchService.watchDeath (MatchService.lua:1680): a death is CombatService.HandleDeath.
    humanoid.Died:Connect(function()
        CS.HandleDeath(token)
    end)
end
local function player(name, at, health)
    local p = w.Instance.new("Player", w.players)
    userId = userId + 1
    p.Name, p.DisplayName, p.UserId = name, name, userId
    local model, humanoid = body(name, at)
    p.Character = model
    if health then
        humanoid.MaxHealth = health
        humanoid.Health = health
    end
    watchDeath(p, humanoid)
    return p, model, humanoid
end
local function bot(name, at, health)
    local model, humanoid = body(name, at)
    local token = { isBot = true, name = name, character = model }
    Combatants.Register(model, token)
    if health then
        humanoid.MaxHealth = health
        humanoid.Health = health
    end
    watchDeath(token, humanoid)
    return token, model, humanoid
end
local function moveBody(model, offset)
    -- The root carries the rest (the world's HumanoidRootPart does, as its Motor6Ds do in Roblox).
    model.HumanoidRootPart.CFrame = model.HumanoidRootPart.CFrame + offset
end
local function placeAt(model, at)
    moveBody(model, at - model.HumanoidRootPart.Position)
end

--------------------------------------------------------------------------------
-- Vehicles, and the machines that drive them
--------------------------------------------------------------------------------
local cars = {}
local function vehicle(modelId, at, yaw)
    local kind = w.VehicleModels.Models[modelId].kind
    local model = VS.Create(w.workspace, at, yaw or 0, kind, { model = modelId, exact = true })
    local entry = VS.Get(model)
    table.insert(cars, entry)
    return entry
end

-- The driver's machine: what VehicleClient does once its player is in the driving seat. Its remote
-- calls are queued and delivered to the server's real handler before the server's step.
local clients, outbox = {}, {}
local function clientRemotes(p)
    return { Event = function(name)
        return { FireServer = function(_, ...)
            table.insert(outbox, { player = p, name = name, args = table.pack(...) })
        end }
    end }
end
local function startDriving(p, entry)
    local driving = { model = entry.model, rig = { chassis = entry.rig.chassis }, seat = entry.seat }
    w.chunk(C.clientPass, "VehicleClient(startDriving)", { driving = driving, model = entry.model, rig = driving.rig,
        RoadkillPass = RoadkillPass, Remotes = clientRemotes(p) })
    local loop = w.chunk(C.clientLoop, "VehicleClient(Stepped)", { driving = driving, player = p,
        stopDriving = function() driving.stopped = true end, VehicleDynamics = { SetIgnore = function() end } })
    local client = { player = p, driving = driving, loop = loop }
    table.insert(clients, client)
    return client
end
local function deliver()
    local list = outbox
    outbox = {}
    for _, m in ipairs(list) do
        local remote = w.replicatedStorage.Remotes:FindFirstChild(m.name)
        remote.OnServerEvent:Fire(m.player, table.unpack(m.args, 1, m.args.n))
    end
end

local function sitPlayer(p, entry, seat)
    local humanoid = p.Character:FindFirstChildOfClass("Humanoid")
    placeAt(p.Character, seat.Position + V3(-3, 0, 0))
    -- The drive / ride prompt, as a player presses it (the real trySit).
    entry.prompts[seat].Triggered:Fire(p)
    placeAt(p.Character, seat.Position)
    return humanoid.SeatPart == seat
end
local function sitBot(token, entry, seat)
    local humanoid = token.character:FindFirstChildOfClass("Humanoid")
    placeAt(token.character, seat.Position + V3(-3, 0, 0))
    local ok = VS.BotSit(humanoid, seat)
    placeAt(token.character, seat.Position)
    return ok
end

-- One frame: every driver's client sweeps, their reports reach the server, the server steps, and then
-- "physics" moves every vehicle (and whoever sits in it) by its velocity.
local function frame()
    for _, client in ipairs(clients) do
        local character = client.player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if not client.driving.stopped and humanoid and humanoid.SeatPart == client.driving.seat then
            client.loop(nil, DT)
        end
    end
    deliver()
    w.runService.Stepped:Fire(now.t, DT)
    for _, entry in ipairs(cars) do
        local chassis = entry.rig.chassis
        local step = chassis.AssemblyLinearVelocity * DT
        -- `stopAtZ`: a hull in the way (the nose, half the chassis ahead, stops on it dead).
        if entry.stopAtZ and chassis.Position.Z - chassis.Size.Z / 2 + step.Z <= entry.stopAtZ then
            step = V3(0, 0, entry.stopAtZ - (chassis.Position.Z - chassis.Size.Z / 2))
            chassis.AssemblyLinearVelocity = V3(0, 0, 0)
            entry.stopped = true
        end
        if step.Magnitude > 0 and entry.model.Parent then
            entry.model:PivotTo(entry.model:GetPivot() + step)
            for _, humanoid in pairs(entry.occupants) do
                moveBody(humanoid.Parent, step)
            end
        end
    end
    now.t = now.t + DT
    w.runTimers()
    w.runService.Heartbeat:Fire(DT)
end
local function run(seconds, stop)
    for _ = 1, math.floor(seconds / DT + 0.5) do
        frame()
        if stop and stop() then
            return true
        end
    end
    return false
end
-- Between scenes: every vehicle and body goes (the service's loop drops the vehicles' entries itself),
-- so one scene's cars never sweep the next scene's people, and the world stays small.
local function clear()
    clients, outbox = {}, {}
    for _, child in ipairs(w.workspace:GetChildren()) do
        if child:IsA("Model") then
            child:Destroy()
        end
    end
    frame()
    cars, clients, outbox = {}, {}, {}
    now.t = now.t + 5
end
local function drive(entry, speed)
    entry.rig.chassis.AssemblyLinearVelocity = V3(0, 0, -speed)
end
local function ahead(entry, distance)
    local p = entry.rig.chassis.Position
    return V3(p.X, 3, p.Z - distance)
end

--------------------------------------------------------------------------------
-- What the clients were sent
--------------------------------------------------------------------------------
local function sentTo(p, remote)
    local out = {}
    for _, s in ipairs(w.world.sent) do
        if s.remote == remote and s.player == p then
            table.insert(out, s.args)
        end
    end
    return out
end
local function expected(speed)
    if speed <= pins.floor then
        return 0
    end
    return (speed - pins.floor) * pins.per * pins.scale
end

local results, findings, rows = {}, {}, {}
local function check(name, ok, detail)
    table.insert(results, { name, ok and true or false, detail or "" })
end
local function finding(name, detail)
    table.insert(findings, { name, detail or "" })
end
local function near(a, b)
    return math.abs(a - b) < 1e-6
end
local function f(x)
    return string.format("%.2f", x)
end
local function place(i)
    return V3(400 * i, 2, 0)
end
local slot = 0
local function nextPlace()
    slot = slot + 1
    return place(slot)
end

--------------------------------------------------------------------------------
-- I1: a player at the wheel, every model at its top speed, into an enemy player
--------------------------------------------------------------------------------
local ids = {}
for i = 1, #C.models do
    table.insert(ids, C.models[i][1])
end
table.sort(ids)
local i1ok, i1detail, i1viaServer = true, {}, 0
for _, id in ipairs(ids) do
    local top = w.VehicleDynamics.Handling[id].topSpeed
    local entry = vehicle(id, nextPlace())
    local driver = player("driver_" .. id, entry.seat.Position + V3(-4, 1, 0))
    local sat = sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    local owner = entry.owner
    local victim, victimModel, victimHum = player("victim_" .. id, ahead(entry, 30), 1000)
    drive(entry, top)
    run(2, function() return victimHum.Health < 1000 end)
    local dealt = 1000 - victimHum.Health
    local who, weapon = CS.GetLastAttacker(victim)
    local marks = sentTo(driver, "DamageDealt")
    local taken = sentTo(victim, "DamageTaken")
    local serverSwept = entry.roadkillPass.lastVelocity ~= nil
    local ok = sat and owner == driver and near(dealt, expected(top)) and who == driver and weapon == "Roadkill"
        and #marks == 1 and #taken == 1 and not serverSwept
    if serverSwept then
        i1viaServer = i1viaServer + 1
    end
    i1ok = i1ok and ok
    table.insert(i1detail, string.format("%s %s->%s", id, f(top), f(dealt)))
    table.insert(rows, { id = id, top = top, dealt = dealt, marker = marks[1] and marks[1][1] or -1 })
    if not ok then
        table.insert(i1detail, string.format("[%s: sat %s owner %s who %s weapon %s marks %d taken %d serverSwept %s]", id,
            tostring(sat), tostring(owner), tostring(who), tostring(weapon), #marks, #taken, tostring(serverSwept)))
    end
    clear()
end
check("I1 every model, player driver at top speed into an enemy player: the driver's client reports it, the server deals (top-12)*1.8*CombatDamageScale, credits the driver, marks the driver's HUD and the victim's",
    i1ok, #ids .. " models: " .. table.concat(i1detail, ", "))

-- The same into a bot.
do
    local entry = vehicle("Rotster", nextPlace())
    local driver = player("driver_botvictim", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    local victim, victimModel, hum = bot("botvictim", ahead(entry, 30), 1000)
    local launchesBefore = #W.launches
    drive(entry, 60)
    run(2, function() return hum.Health < 1000 end)
    local who = CS.GetLastAttacker(victim)
    check("I1 a player driver into a bot: dealt and credited", near(1000 - hum.Health, expected(60)) and who == driver,
        "dealt " .. f(1000 - hum.Health) .. " want " .. f(expected(60)) .. ", credited " .. tostring(who and who.Name))
    local thrown = false
    for index = launchesBefore + 1, #W.launches do
        if W.launches[index].character == victimModel then
            thrown = W.launches[index].velocity
        end
    end
    local down = w.raw(hum).states[1] ~= nil
    check("I7 a hit that hurts and does not kill still throws the body (a bot knocked down first)", thrown and down and hum.Health > 0,
        "thrown " .. tostring(thrown) .. ", knocked down " .. tostring(down))
    clear()
end

--------------------------------------------------------------------------------
-- I2: a bot at the wheel (the server simulates and sweeps its car)
--------------------------------------------------------------------------------
local i2ok, i2detail = true, {}
for _, id in ipairs(ids) do
    local top = w.VehicleDynamics.Handling[id].topSpeed
    local entry = vehicle(id, nextPlace())
    local driver = bot("botdriver_" .. id, entry.seat.Position)
    local sat = sitBot(driver, entry, entry.seat)
    run(0.1)
    local victim, _, hum = player("botvictim_" .. id, ahead(entry, 30), 1000)
    drive(entry, top)
    run(2, function() return hum.Health < 1000 end)
    local who, weapon = CS.GetLastAttacker(victim)
    local ok = sat and entry.owner == false and near(1000 - hum.Health, expected(top)) and who == driver and weapon == "Roadkill"
        and entry.roadkillPass.lastVelocity ~= nil
    i2ok = i2ok and ok
    if not ok then
        table.insert(i2detail, string.format("%s: sat %s owner %s dealt %s who %s", id, tostring(sat), tostring(entry.owner),
            f(1000 - hum.Health), tostring(who and who.name)))
    end
    clear()
end
check("I2 every model, bot driver at top speed into a player: the server's own sweep deals it and credits the bot",
    i2ok, #i2detail == 0 and (#ids .. " models") or table.concat(i2detail, "; "))

--------------------------------------------------------------------------------
-- I6: a roadkill kill in the kill feed, and what each side is sent
--------------------------------------------------------------------------------
do
    -- A Tralala GT at its top speed: one hit kills 100 health (a Rotster no longer does at 0.736).
    local entry = vehicle("TralalaGT", nextPlace())
    local driver = player("feed_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    local victim, _, hum = player("feed_victim", ahead(entry, 30))
    local before = #feed
    drive(entry, 106)
    run(2, function() return hum.Health <= 0 end)
    local row = feed[before + 1]
    local marks = sentTo(driver, "DamageDealt")
    local recap = sentTo(victim, "DeathRecap")[1]
    check("I6 a player's roadkill kill: the feed row names the driver and \"Roadkill\"; the driver gets an ELIM marker, the victim a recap naming Roadkill",
        hum.Health <= 0 and row ~= nil and row.victim == victim and row.killer == driver and row.method == "Roadkill"
            and marks[1] ~= nil and marks[1][2] == true and recap ~= nil and recap[1].weapon == "Roadkill"
            and recap[1].killer == "feed_driver",
        row and string.format("feed: %s -> %s [%s]; marker kill=%s; recap weapon %s", tostring(row.killer and row.killer.Name),
            tostring(row.victim and row.victim.Name), tostring(row.method), tostring(marks[1] and marks[1][2]),
            tostring(recap and recap[1].weapon)) or ("no feed row; health " .. f(hum.Health)))

    local entry2 = vehicle("TralalaGT", nextPlace())
    local driverBot = bot("feed_bot", entry2.seat.Position)
    sitBot(driverBot, entry2, entry2.seat)
    run(0.1)
    local victim2, _, hum2 = bot("feed_botvictim", ahead(entry2, 30))
    before = #feed
    drive(entry2, 106)
    run(2, function() return hum2.Health <= 0 end)
    row = feed[before + 1]
    check("I6 a bot's roadkill kill: the feed row names the bot and \"Roadkill\"",
        row ~= nil and row.killer == driverBot and row.method == "Roadkill",
        row and (tostring(row.killer and row.killer.name) .. " [" .. tostring(row.method) .. "]") or "no feed row")
    clear()
end

--------------------------------------------------------------------------------
-- I3: never the car's own riders, by any path
--------------------------------------------------------------------------------
do
    local entry = vehicle("Rotster", nextPlace())
    local driver, driverModel, driverHum = player("rider_driver", entry.seat.Position, 1000)
    local mate, mateModel, mateHum = player("rider_passenger", entry.passengers[1].Position, 1000)
    sitPlayer(driver, entry, entry.seat)
    sitPlayer(mate, entry, entry.passengers[1])
    startDriving(driver, entry)
    run(0.1)
    drive(entry, 84)
    run(1)
    -- Every path by hand, at full speed: the server's Touched with each rider's part, and the driver's
    -- client reporting each rider.
    entry.rig.chassis.Touched:Fire(mateModel.Torso)
    entry.rig.chassis.Touched:Fire(driverModel.Torso)
    local remote = w.replicatedStorage.Remotes:FindFirstChild("VehicleRoadkill")
    now.t = now.t + 1
    remote.OnServerEvent:Fire(driver, entry.model, mateModel, 84)
    remote.OnServerEvent:Fire(driver, entry.model, driverModel, 84)
    local botEntry = vehicle("SahurVan", nextPlace())
    local botDriver, _, botDriverHum = bot("rider_botdriver", botEntry.seat.Position, 1000)
    local passenger, passengerModel, passengerHum = player("rider_botpassenger", botEntry.passengers[1].Position, 1000)
    sitBot(botDriver, botEntry, botEntry.seat)
    sitPlayer(passenger, botEntry, botEntry.passengers[1])
    drive(botEntry, 72)
    run(1)
    botEntry.rig.chassis.Touched:Fire(passengerModel.Torso)
    check("I3 riders are never hurt by their own car (player-driven and bot-driven, client sweep, server sweep, Touched, a report naming them)",
        driverHum.Health == 1000 and mateHum.Health == 1000 and botDriverHum.Health == 1000 and passengerHum.Health == 1000,
        string.format("driver %s passenger %s bot driver %s bot's passenger %s", f(driverHum.Health), f(mateHum.Health),
            f(botDriverHum.Health), f(passengerHum.Health)))
    clear()
end

--------------------------------------------------------------------------------
-- I4: at or under the floor, nothing, by any path; just over it, the formula
--------------------------------------------------------------------------------
do
    local under = { 0, 4, 8, 11.9, 12 }
    local worst, let = 0, 0
    local launchesBefore = #W.launches
    for _, speed in ipairs(under) do
        -- The client path, a player at the wheel.
        local entry = vehicle("Rotster", nextPlace())
        local driver = player("slow_driver_" .. speed, entry.seat.Position)
        sitPlayer(driver, entry, entry.seat)
        startDriving(driver, entry)
        run(0.1)
        local _, victimModel, hum = player("slow_victim_" .. speed, ahead(entry, 6), 1000)
        drive(entry, speed)
        run(1.2)
        -- The server's Touched and a report at that speed, by hand.
        now.t = now.t + 1
        entry.rig.chassis.Touched:Fire(victimModel.Torso)
        now.t = now.t + 1
        w.replicatedStorage.Remotes:FindFirstChild("VehicleRoadkill").OnServerEvent:Fire(driver, entry.model, victimModel, speed)
        -- The server path, a bot at the wheel.
        local botEntry = vehicle("Rotster", nextPlace())
        local botDriver = bot("slow_bot_" .. speed, botEntry.seat.Position)
        sitBot(botDriver, botEntry, botEntry.seat)
        local _, _, hum2 = player("slow_botvictim_" .. speed, ahead(botEntry, 6), 1000)
        drive(botEntry, speed)
        run(1.2)
        worst = math.max(worst, 1000 - hum.Health, 1000 - hum2.Health)
        -- And the body still collides: nobody is let through the car (the server's pass on either car).
        for _, e in ipairs({ entry, botEntry }) do
            for _ in pairs(e.roadkillPass.passed) do
                let = let + 1
            end
        end
    end
    -- Nothing at all: no damage, and no throw either (a nudge stays a nudge).
    local thrown = #W.launches - launchesBefore
    check("I4 at or under 12 studs/s nothing happens: no damage, no throw, not let through (0, 4, 8, 11.9, 12; client report, Touched, forged report, server sweep)",
        worst == 0 and thrown == 0 and let == 0, "most dealt " .. f(worst) .. ", thrown " .. thrown .. ", let through " .. let)
    local over, bad = { 12.5, 18, 18 * 1.45 }, {}
    for _, speed in ipairs(over) do
        local entry = vehicle("Rotster", nextPlace())
        local driver = player("walk_driver_" .. speed, entry.seat.Position)
        sitPlayer(driver, entry, entry.seat)
        startDriving(driver, entry)
        run(0.1)
        local _, _, hum = player("walk_victim_" .. speed, ahead(entry, 6), 1000)
        drive(entry, speed)
        run(1.5, function() return hum.Health < 1000 end)
        local dealt = 1000 - hum.Health
        table.insert(bad, f(speed) .. " -> " .. f(dealt))
        if not near(dealt, expected(speed)) then
            bad.failed = true
        end
    end
    check("I4 just over the floor the formula holds: 12.5, walking pace 18, sprinting 26.1 studs/s", not bad.failed, table.concat(bad, ", "))
    clear()
end

--------------------------------------------------------------------------------
-- I5: team-mates and spawn protection (team mode)
--------------------------------------------------------------------------------
do
    teamMode(true)
    local entry = vehicle("Rotster", nextPlace())
    local driver = player("team_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    local mate, mateModel, mateHum = player("team_mate", ahead(entry, 25), 1000)
    local enemy, _, enemyHum = player("team_enemy", ahead(entry, 60) + V3(0, 0, 0), 1000)
    mt.teamOf[driver], mt.teamOf[mate], mt.teamOf[enemy] = 1, 1, 2
    local launchesBefore = #W.launches
    drive(entry, 84)
    run(2, function() return enemyHum.Health < 1000 end)
    local mateLaunched = false
    for index = launchesBefore + 1, #W.launches do
        if W.launches[index].character == mateModel then
            mateLaunched = W.launches[index].velocity
        end
    end
    local mateMarked = mateModel:GetAttribute("RoadkillThrow") ~= nil
    local marks = sentTo(driver, "DamageDealt")
    local grey = false
    for _, m in ipairs(marks) do
        if m[6] == "structure" then
            grey = true
        end
    end

    local botEntry = vehicle("SahurVan", nextPlace())
    local botDriver = bot("team_botdriver", botEntry.seat.Position)
    sitBot(botDriver, botEntry, botEntry.seat)
    local botMate, botMateModel, botMateHum = bot("team_botmate", ahead(botEntry, 25), 1000)
    mt.teamOf[botDriver], mt.teamOf[botMate] = 2, 2
    local botLaunchesBefore = #W.launches
    drive(botEntry, 72)
    run(1)
    local botMateLaunched = false
    for index = botLaunchesBefore + 1, #W.launches do
        if W.launches[index].character == botMateModel then
            botMateLaunched = W.launches[index].velocity
        end
    end
    -- The van went through its team-mate (the body was let through), not stopped on it.
    local botMatePassed = botEntry.roadkillPass.passed[botMateModel] ~= nil

    local protectedEntry = vehicle("Rotster", nextPlace())
    local pDriver = player("prot_driver", protectedEntry.seat.Position)
    sitPlayer(pDriver, protectedEntry, protectedEntry.seat)
    startDriving(pDriver, protectedEntry)
    run(0.1)
    local fresh, freshModel, freshHum = player("prot_enemy", ahead(protectedEntry, 25), 1000)
    mt.teamOf[pDriver], mt.teamOf[fresh] = 1, 2
    mt.protectedUntil[fresh] = math.floor(now.t * 1000) + 60000
    local freshLaunchedBefore = #W.launches
    drive(protectedEntry, 84)
    run(1)
    local freshLaunched = false
    for index = freshLaunchedBefore + 1, #W.launches do
        if W.launches[index].character == freshModel then
            freshLaunched = W.launches[index].velocity
        end
    end
    teamMode(false)

    check("I5 team mode: a team-mate is never hurt (player driver, bot driver), an enemy behind them is",
        mateHum.Health == 1000 and botMateHum.Health == 1000 and near(1000 - enemyHum.Health, expected(84 * (1 - 0.025))),
        string.format("mate %s, bot's mate %s, enemy dealt %s (want %s: the car paid the 2.5%% toll going through the mate)",
            f(mateHum.Health), f(botMateHum.Health), f(1000 - enemyHum.Health), f(expected(84 * (1 - 0.025)))))
    -- No mode grants spawn protection since 09-25 (I10); the veto is still held here, should one again.
    check("I5 team mode: an enemy under spawn protection is never hurt", freshHum.Health == 1000, "health " .. f(freshHum.Health))
    check("the vetoed hit gives the driver the grey \"+\" (#86), not silence", grey, grey and "kind structure" or "no grey marker")
    local botMateDown = w.raw(botMateHum).states[1] ~= nil
    check("I7 a vetoed hit does nothing to the body: a team-mate (player driver, bot driver) and a protected enemy are not thrown, not knocked down, not marked RoadkillThrow; the car still goes through",
        not mateLaunched and not mateMarked and not botMateLaunched and not botMateDown and not freshLaunched
            and freshModel:GetAttribute("RoadkillThrow") == nil and botMatePassed,
        string.format("mate thrown %s marked %s; bot's mate thrown %s knocked down %s, let through %s; protected enemy thrown %s",
            tostring(mateLaunched), tostring(mateMarked), tostring(botMateLaunched), tostring(botMateDown),
            tostring(botMatePassed), tostring(freshLaunched)))
    clear()
end

--------------------------------------------------------------------------------
-- Paths the others don't reach: Touched, reports refused, the bail, a parked car shoved
--------------------------------------------------------------------------------
do
    local entry = vehicle("Rotster", nextPlace())
    local driver = player("touch_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    run(0.1)
    drive(entry, 50)
    local _, victimModel, hum = player("touch_victim", ahead(entry, 200), 1000)
    run(0.1)
    placeAt(victimModel, ahead(entry, 4))
    entry.rig.chassis.Touched:Fire(victimModel.Torso)
    local once = 1000 - hum.Health
    w.replicatedStorage.Remotes:FindFirstChild("VehicleRoadkill").OnServerEvent:Fire(driver, entry.model, victimModel, 50)
    local twice = 1000 - hum.Health
    check("the server's chassis.Touched (Create connects it) deals the hit on its own, and a report of the same body inside 0.5 s adds nothing",
        near(once, expected(50)) and near(twice, once), "Touched " .. f(once) .. ", then report " .. f(twice))

    local remote = w.replicatedStorage.Remotes:FindFirstChild("VehicleRoadkill")
    local rider = player("touch_rider", entry.passengers[1].Position)
    sitPlayer(rider, entry, entry.passengers[1])
    local _, farModel, farHum = player("far_victim", ahead(entry, 200), 1000)
    local _, sideModel, sideHum = player("side_victim", ahead(entry, 3), 1000)
    now.t = now.t + 1
    remote.OnServerEvent:Fire(rider, entry.model, sideModel, 50)
    remote.OnServerEvent:Fire(driver, entry.model, farModel, 50)
    check("reports refused: from a passenger, and of a body 200 studs off", sideHum.Health == 1000 and farHum.Health == 1000,
        "side " .. f(sideHum.Health) .. ", far " .. f(farHum.Health))
    remote.OnServerEvent:Fire(driver, entry.model, sideModel, 900)
    local seen = 50
    check("a report's speed is held to what the server saw (50 -> at most 50*1.15+4)",
        near(1000 - sideHum.Health, expected(seen * 1.15 + 4)), "dealt " .. f(1000 - sideHum.Health) .. " want " .. f(expected(seen * 1.15 + 4)))
    clear()
end

do
    -- The bail: out of the seat at speed, the car rolls on (the server takes its physics back).
    local entry = vehicle("TralalaGT", nextPlace())
    local driver = player("bail_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    drive(entry, 60)
    run(0.1)
    local driverHum = driver.Character:FindFirstChildOfClass("Humanoid")
    driverHum.Sit = false
    -- The exit spot is set in a task.defer (onSeatChanged), which Roblox runs before the next frame.
    w.runTimers()
    run(0.1)
    local victim, _, hum = player("bail_victim", ahead(entry, 20), 1000)
    run(1.5, function() return hum.Health < 1000 end)
    local who = CS.GetLastAttacker(victim)
    check("I9 a car its driver bailed out of still hurts, credited to nobody, at the same scale as a driven car",
        near(1000 - hum.Health, expected(60)) and who == nil and driverHum.Health == 100,
        string.format("dealt %s (want %s), credited %s, owner %s; the driver kept %s health", f(1000 - hum.Health),
            f(expected(60)), tostring(who), tostring(entry.owner), f(driverHum.Health)))
    clear()
end

do
    -- a1eb7a8: a parked car is held off the dynamics. Shoved into someone, the sweep still runs first.
    local entry = vehicle("CrocodiloRanger", nextPlace())
    run(1)
    local held = entry.restHold ~= nil
    local victim, _, hum = player("parked_victim", ahead(entry, 15), 1000)
    drive(entry, 40)
    run(1, function() return hum.Health < 1000 end)
    -- Nobody drives it, so nobody is credited; VehicleService scales the hit itself (DealDamage scales only
    -- a hit with an attacker), so it is the driven formula (I9).
    check("a1eb7a8: a parked car is held at rest, and one shoved into someone at 40 still hits (the sweep runs before the hold), scaled and credited to nobody",
        held and near(1000 - hum.Health, expected(40)) and CS.GetLastAttacker(victim) == nil,
        "held " .. tostring(held) .. ", dealt " .. f(1000 - hum.Health))
    clear()
end

do
    -- The code's own claim (VehicleService's vehicle-health comment): a full-health, full-shield player survives
    -- even the fastest bike at its top speed.
    local entry = vehicle("BrrStreetfighter", nextPlace())
    local driver = player("shield_driver", entry.seat.Position)
    sitPlayer(driver, entry, entry.seat)
    startDriving(driver, entry)
    run(0.1)
    local victim, _, hum = player("shield_victim", ahead(entry, 30))
    W.shield[victim] = 100
    drive(entry, 114)
    run(2, function() return (W.shield[victim] or 0) < 100 end)
    check("a full-health, full-shield player survives the fastest bike at its top speed (114)",
        hum.Health > 0 and W.shield[victim] == 0, string.format("health left %s, shield left %s", f(hum.Health), f(W.shield[victim])))
    clear()
end

do
    -- Someone sitting in ANOTHER vehicle, T-boned at speed: an armoured car parked side-on (yaw 90, its
    -- driver on the near side), a bot's car driving into its flank and stopped dead by the hull.
    local parked = vehicle("TartarugaScout", nextPlace(), math.pi / 2)
    local seated, seatedModel, seatedHum = player("seated_enemy", parked.seat.Position, 1000)
    sitPlayer(seated, parked, parked.seat)
    local far, farModel, farHum = player("seated_far", parked.passengers[1].Position, 1000)
    sitPlayer(far, parked, parked.passengers[1])
    local side = parked.rig.chassis.Position.Z + parked.rig.chassis.Size.X / 2
    local rammer = vehicle("Rotster", V3(parked.rig.chassis.Position.X, 2, side + 40))
    rammer.stopAtZ = side
    local botDriver = bot("ram_bot", rammer.seat.Position)
    sitBot(botDriver, rammer, rammer.seat)
    local launchesBefore = #W.launches
    drive(rammer, 60)
    local let = false
    run(1.2, function()
        let = let or rammer.roadkillPass.passed[seatedModel] ~= nil or rammer.roadkillPass.passed[farModel] ~= nil
        return rammer.stopped
    end)
    local thrown = #W.launches - launchesBefore
    -- The server path on its own: a moving car's Touched with the armoured driver's own part.
    local mover = vehicle("Rotster", nextPlace())
    local moverBot = bot("touch_bot", mover.seat.Position)
    sitBot(moverBot, mover, mover.seat)
    drive(mover, 60)
    run(0.1)
    mover.rig.chassis.Touched:Fire(seatedModel.Torso)
    check("I8 riders inside an armoured cabin are never run over: a car T-boning a parked Tartaruga Scout at 60, and a moving car's Touched on its driver",
        seatedHum.Health == 1000 and farHum.Health == 1000 and thrown == 0 and not let,
        string.format("near-side driver %s, far-side passenger %s, thrown %d, let through the rammer %s", f(seatedHum.Health),
            f(farHum.Health), thrown, tostring(let)))
    clear()

    -- The same T-bone into an open car (a Rotster): its near-side driver is still roadkill.
    local open = vehicle("Rotster", nextPlace(), math.pi / 2)
    local exposed, _, exposedHum = player("seated_open", open.seat.Position, 1000)
    sitPlayer(exposed, open, open.seat)
    local openSide = open.rig.chassis.Position.Z + open.rig.chassis.Size.X / 2
    local openRammer = vehicle("Rotster", V3(open.rig.chassis.Position.X, 2, openSide + 40))
    openRammer.stopAtZ = openSide
    local openBot = bot("ram_open_bot", openRammer.seat.Position)
    sitBot(openBot, openRammer, openRammer.seat)
    drive(openRammer, 60)
    run(1.2, function() return openRammer.stopped end)
    check("I8 a rider of an open car can still be run over (a Rotster T-boned at 60)", exposedHum.Health < 1000,
        "near-side driver dealt " .. f(1000 - exposedHum.Health))
    clear()
end

for _, warning in ipairs(w.warnings) do
    finding("a module warned", warning)
end

return results, findings, rows
"""


def run(root, swaps=None):
    tree = Tree(root, swaps)
    lua = LuaRuntime(unpack_returned_tuples=True)
    world_text = open(os.path.join(HERE, "roadkill_proof_world.lua"), encoding="utf-8").read()
    compile_ = lua.eval("load")
    world = compile_(world_text, "roadkill_proof_world")(lambda name: tree.lua(name), compile_)
    c = cuts(tree)
    ctable = lua.table_from({k: v for k, v in c.items() if k != "models"})
    ctable["models"] = lua.table_from([lua.table_from(list(m)) for m in c["models"]])
    pins = lua.table_from({"floor": PIN_FLOOR, "per": PIN_PER, "scale": PIN_SCALE})
    results, findings, rows = lua.execute(SCENES, world, ctable, pins)
    out = [(r[1], bool(r[2]), r[3]) for r in results.values()]
    # I10: GameModes grants nobody spawn protection (ModeTeams.grantProtection does nothing at 0).
    granted = [m.group(0) for m in re.finditer(r"spawnProtection = ([\d.]+)", tree.text("GameModes"))
               if float(m.group(1)) > 0]
    out.append(("I10 no mode grants spawn protection (GameModes spawnProtection 0 everywhere)", not granted,
                "; ".join(granted) if granted else "none granted"))
    return out, [(x[1], x[2]) for x in findings.values()], [dict(r) for r in rows.values()]


def sub(name, before, after):
    return {name: [(before, after)]}


PLANTS = [
    ("I1: the server drops every driver's report",
     sub("VehicleService", "\t\tonRoadkillReport(player, model, character, speed)\n\tend)",
         "\t\tlocal _ = onRoadkillReport\n\tend)")),
    ("I1: the driver's client never reports (VehicleClient's FireServer gone)",
     sub("VehicleClient", 'Remotes.Event("VehicleRoadkill"):FireServer(model, character, speed)', "local _ = speed")),
    ("I1: the server never hands the car to its driver (it sweeps it itself)",
     sub("VehicleService", "entry.rig.chassis:SetNetworkOwner(wantPlayer)", "error(\"no owner\")")),
    ("I1/I2: the driver's credit lost",
     sub("VehicleService", "return (character and Combatants.FromCharacter(character)) or entry.driverPlayer", "return nil")),
    ("I2: the server's step skips the sweep",
     sub("VehicleService", "\t\tentry.roadkillPass:Sweep(dt, now)\n", "\n")),
    ("I3: riders not excluded (server and sweep)",
     {"VehicleService": [("\t\tif occupant == humanoid then\n\t\t\treturn\n", "\t\tif false then\n\t\t\treturn\n")],
      "RoadkillPass": [("\t\tif seat.Occupant == humanoid then\n", "\t\tif false then\n")]}),
    ("I4: no server-side floor", sub("VehicleService", "\tif flat <= ROADKILL_FLOOR then\n", "\tif flat < 0 then\n")),
    ("I5: DealDamage skips the mode's veto",
     sub("CombatService", "if CombatService.DamageVeto and CombatService.DamageVeto(attackerToken, victimToken, weaponId) then",
         "if false then")),
    ("I6: the kill feed drops the Roadkill name",
     sub("MatchService", 'or ((hazard or weaponId == "Roadkill" or ItemData.Get(weaponId))', "or ((hazard or ItemData.Get(weaponId))")),
    ("Touched no longer connected", sub("VehicleService", "\tchassis.Touched:Connect(function(hit)\n\t\tonChassisTouched(entry, hit)\n",
                                        "\tchassis.Touched:Connect(function(hit)\n\t\tlocal _ = hit\n")),
    ("damage retuned (the report's table would be stale)", sub("VehicleService", "local ROADKILL_DAMAGE_PER = 1.8", "local ROADKILL_DAMAGE_PER = 2")),
    ("I7: a vetoed hit still throws the body", sub("VehicleService", "\tif throw and dealt <= 0 then\n", "\tif false then\n")),
    ("I7: every hit's throw dropped", sub("VehicleService", "\t\tlaunch(character, throw)\n", "\n")),
    ("I8: the server ignores the armoured cabin",
     sub("VehicleService", "\tif VehicleService.ShieldingVehicle(victimToken) then\n", "\tif false then\n")),
    ("I8: the sweep lets armoured riders through",
     sub("RoadkillPass", "\t\t\t\t\tand not RoadkillPass.Sheltered(humanoid) then", "\t\t\t\t\tthen")),
    ("I8: every seated rider sheltered", sub("VehicleService", "\tif VehicleService.ShieldingVehicle(victimToken) then\n",
                                             "\tif humanoid.SeatPart then\n")),
    ("I9: a driverless car unscaled", sub("VehicleService", "\tif driverToken == nil then\n\t\tamount *=", "\tif false then\n\t\tamount *=")),
    ("I10: a mode grants spawn protection again", sub("GameModes", "spawnProtection = 0, -- none", "spawnProtection = 3, -- none")),
]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = args[0] if args else "."
    if "--plant" in sys.argv:
        missed = 0
        for name, swaps in PLANTS:
            results, _, _ = run(root, swaps)
            failed = [r[0].split(":")[0] if len(r[0]) > 60 else r[0] for r in results if not r[1]]
            print(("CAUGHT " if failed else "MISSED ") + name + (" -> " + "; ".join(failed[:4]) if failed else ""))
            missed += 0 if failed else 1
        print(f"roadkill proof plants: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        sys.exit(1 if missed else 0)
    results, findings, rows = run(root)
    bad = 0
    for name, ok, detail in results:
        print(("ok    " if ok else "FAIL  ") + name + ("  (" + detail + ")" if detail else ""))
        bad += 0 if ok else 1
    for name, detail in findings:
        print("FINDING " + name + ("  (" + detail + ")" if detail else ""))
    print("table: model, top speed (studs/s), dealt at top speed, the driver's hit marker number")
    for r in sorted(rows, key=lambda r: -r["top"]):
        print("  %-18s %5.0f  %7.2f  %s" % (r["id"], r["top"], r["dealt"], r["marker"]))
    print(f"roadkill proof: {len(results)} checks, {bad} failed, {len(findings)} findings")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
