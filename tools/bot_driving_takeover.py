#!/usr/bin/env python3
"""Taking a bot's seat, and bots on armed vehicles waiting for a gunner, from the real source.

Runs, in lupa, the pieces of the game that decide these, cut out of the files as they stand (Luau's
compound assignments spelled out for stock Lua):
  * VehicleService.lua's "Seats and prompts" and "Occupants" sections whole: onSeatChanged (the
    prompts, VehicleRole, the exit), botHeld, takeOver, trySit, BotSit, SeatsOf, VehiclesNear;
  * BotService.lua's BOT VEHICLES section whole (the `Vehicles` functions: YieldSeat,
    TakeoverAllowed, refreshFoes, leaveRide, the servo, driverThink, gunnerThink, pickSeat...);
  * BotNav.lua's DRIVING section, for the drive a bot at the wheel holds;
  * VehicleClient.client.lua's mayTakeOver, the rule that hides a takeover prompt.
Around them: seats whose Occupant fires onSeatChanged as Roblox's does, humanoids, a car whose speed
answers the servo's throttle, task.wait/defer/delay on a frame clock, ModeTeams with or without teams.

TAKEOVER  a player asks for a seat a bot holds, by the seat's own prompt, through trySit:
    team mate / driving seat      allowed: the car is braked to under 4 studs/s before the bot gets
                                  out, the bot is out and back on foot, the player is in the seat
    enemy team / driving seat     refused, the bot keeps the wheel, the client hides the prompt
    no teams, not its fight       allowed
    no teams, its fight           refused (its target), the client hides the prompt
    gunner seat, team mate        allowed straight away, the player is on the gun
    a player's seat               never asked of anyone: refused
  The prompt of a bot's seat stays up reading "Take over", and reads "Drive" again once it is free;
  while a takeover is under way no other bot can sit in the seat. The client's rule and the server's
  agree on every case of a matrix (teams, foes, a player driver, a free seat).
GUNNER    a bot at the wheel of an armed vehicle with nobody on its gun holds it (drive.hold, no
  route), fires its gun only once shot at, gives it up after BotGunnerWait; with a gunner it drives.
  A bot on foot beside it (its teammate) takes the gun seat. In the battle royale no bot takes a
  vehicle's gun (Vehicles.botGunners), so the driver waits only while a player could come
  (Vehicles.gunnerMayCome): with nobody, a player 60 studs off, its own fight, a player at another
  wheel or a dead one, it gives the car up on its first think; a live player 12 studs off is waited for
  the full BotGunnerWait, and one walking over from 25 studs mans the gun and is driven. Shot at, it
  stays and fires whoever could come.
Planted faults, each aimed at one of those: the enemy let in, the car not stopped first, the prompt
hidden for a bot's seat, the client showing the prompt to the bot's target, the armed car driven off
unmanned, a wait for a gunner nobody can be, the bot's own fight counted as a gunner, a player by the
car not waited for, a team mode's wait cut short, the gun seat never picked, the seat not held during
a takeover.

Usage:  python3 tools/bot_driving_takeover.py [repo_root]
Not modelled: Roblox's own seat welding and the network (a prompt's Triggered is called directly), the
physics of the stop (a speed that answers the throttle at the brake's rate), streaming.
"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import bot_driving_sim as sim  # noqa: E402

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
VS = "ServerScriptService/Modules/VehicleService.lua"
BS = "ServerScriptService/Modules/BotService.lua"
NAV = "ServerScriptService/Modules/BotNav.lua"
VC = "StarterPlayerScripts/VehicleClient.client.lua"


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def luau(src):
    return sim.luau_to_lua(src)


def vs_section(src):
    a = src.index("-- Seats and prompts\n")
    a = src.rindex("\n----", 0, a) + 1
    b = src.index("-- Where a parked vehicle stands\n")
    b = src.rindex("\n----", 0, b) + 1
    return src[a:b]


def bs_section(src):
    a = src.index('local RunService = game:GetService("RunService")')
    m = re.search(r"^function Vehicles\.botVehicleThink.*?^end$", src[a:], re.M | re.S)
    return src[a:a + m.end()]


def vc_rule(src):
    return re.search(r"^local function mayTakeOver.*?^end$", src, re.M | re.S).group(0)


PRELUDE = r"""
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local V = Vector3.new
Vector3.xAxis = V(1, 0, 0); Vector3.yAxis = V(0, 1, 0); Vector3.zAxis = V(0, 0, 1)
CLOCK = 0
tick = function() return CLOCK end
os.clock = function() return CLOCK end
warnings = {}
warn = function(m) table.insert(warnings, tostring(m)) end

-- A frame scheduler: task.wait yields the running coroutine until the clock has moved on.
local sleeping, deferred = {}, {}
task = {
  wait = function(dt) local co = coroutine.running(); table.insert(sleeping, { co = co, at = CLOCK + (dt or 1 / 60) }); return coroutine.yield() end,
  defer = function(fn, ...) table.insert(deferred, { fn = fn, args = { ... } }) end,
  delay = function(dt, fn, ...) table.insert(sleeping, { fn = fn, at = CLOCK + dt, args = { ... } }) end,
  spawn = function(fn, ...) local co = coroutine.create(fn); local ok, err = coroutine.resume(co, ...); if not ok then error(err) end end,
}
function runScheduler()
  local now = {}
  for i = #deferred, 1, -1 do table.insert(now, table.remove(deferred, i)) end
  for i = #now, 1, -1 do local d = now[i]; d.fn(table.unpack(d.args)) end
  for i = #sleeping, 1, -1 do
    local s = sleeping[i]
    if CLOCK >= s.at then
      table.remove(sleeping, i)
      if s.co then local ok, err = coroutine.resume(s.co); if not ok then error(err) end
      else s.fn(table.unpack(s.args or {})) end
    end
  end
end

-- Instances ------------------------------------------------------------------------------------
local Inst = {}
-- Methods, then a child by name (character.HumanoidRootPart), as an Instance answers.
Inst.__index = function(t, k)
  local method = Inst[k]
  if method ~= nil then return method end
  local children = rawget(t, "children")
  if children and type(k) == "string" then
    for _, c in ipairs(children) do if c.Name == k then return c end end
  end
  return nil
end
function newInst(className, name, props)
  local i = setmetatable({ __instance = true, ClassName = className, Name = name, attrs = {}, children = {} }, Inst)
  for k, v in pairs(props or {}) do i[k] = v end
  return i
end
function Inst:IsA(c)
  if c == "BasePart" then return self.ClassName == "Part" or self.ClassName == "Seat" or self.ClassName == "VehicleSeat" end
  return self.ClassName == c
end
function Inst:GetAttribute(k) return self.attrs[k] end
function Inst:SetAttribute(k, v) self.attrs[k] = v end
function Inst:FindFirstChild(n) for _, c in ipairs(self.children) do if c.Name == n then return c end end return nil end
function Inst:FindFirstChildOfClass(c) for _, ch in ipairs(self.children) do if ch.ClassName == c then return ch end end return nil end
function Inst:GetChildren() return self.children end
function Inst:GetDescendants()
  local out = {}
  local function walk(x) for _, c in ipairs(x.children or {}) do table.insert(out, c); walk(c) end end
  walk(self)
  return out
end
function Inst:IsDescendantOf(x) local p = self.Parent; while p do if p == x then return true end; p = p.Parent end; return false end
function Inst:GetPivot() return self.PrimaryPart and self.PrimaryPart.CFrame or CFrame.new(0, 0, 0) end
function Inst:Destroy() self.Parent = nil end
function Inst:GetPropertyChangedSignal() return { Connect = function() end } end
function adopt(parent, child) child.Parent = parent; table.insert(parent.children, child); return child end
workspace = newInst("Workspace", "Workspace")
function workspace:GetPartBoundsInBox() return {} end
function workspace:Raycast(origin, direction) return { Position = V(origin.X, 0, origin.Z), Normal = V(0, 1, 0), Distance = origin.Y } end
function workspace:Blockcast() return nil end
OverlapParams = { new = function() return {} end }
RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end }

-- Seats: Sit and Humanoid.Sit drive Occupant, and a change fires the watcher, as Roblox's signal does.
function makeSeatInst(className, name, model)
  local seat = newInst(className, name, { Position = V(0, 2, 0), CFrame = CFrame.new(0, 2, 0), ThrottleFloat = 0, SteerFloat = 0 })
  adopt(model, seat)
  seat.Sit = function(self, humanoid)
    if self.Occupant then return end
    self.Occupant = humanoid
    humanoid.SeatPart = self
    if self.onChanged then self.onChanged() end
  end
  return seat
end
function makeHumanoid(character)
  local h = newInst("Humanoid", "Humanoid", { Health = 100, MaxHealth = 100, Died = { Connect = function() return { Disconnect = function() end } end } })
  setmetatable(h, { __index = Inst, __newindex = function(t, k, v)
    if k == "Sit" and v == false and rawget(t, "SeatPart") then
      local seat = rawget(t, "SeatPart")
      rawset(t, "SeatPart", nil)
      seat.Occupant = nil
      if seat.onChanged then seat.onChanged() end
      return
    end
    rawset(t, k, v)
  end })
  adopt(character, h)
  return h
end

-- Players and bots ------------------------------------------------------------------------------
local playersByCharacter, tokenByCharacter = {}, {}
PLAYERS = {}
Players = { GetPlayerFromCharacter = function(_, c) return playersByCharacter[c] end,
  GetPlayers = function() return PLAYERS end }
game = { GetService = function(_, n)
  if n == "Players" then return Players end
  if n == "RunService" then return { Heartbeat = { Connect = function(_, fn) HEARTBEAT = fn; return {} end } } end
  if n == "CollectionService" then return { GetTagged = function() return {} end } end
  return {}
end }
function makeBody(name, at)
  local c = newInst("Model", name)
  adopt(workspace, c)
  local root = newInst("Part", "HumanoidRootPart", { Position = at, CFrame = CFrame.new(at.X, at.Y, at.Z), Size = V(2, 2, 1),
    AssemblyLinearVelocity = V(0, 0, 0) })
  adopt(c, root)
  local h = makeHumanoid(c)
  return c, h, root
end
function makePlayer(name, userId, at)
  local c, h, root = makeBody(name, at)
  local player = newInst("Player", name, { UserId = userId, Character = c })
  playersByCharacter[c] = player
  tokenByCharacter[c] = player
  table.insert(PLAYERS, player)
  return player, h, root
end
ALLBOTS = {}
function makeBot(name, at)
  local c, h, root = makeBody(name, at)
  local bot = { isBot = true, name = name, character = c, humanoid = h, nav = {} }
  tokenByCharacter[c] = bot
  table.insert(ALLBOTS, bot)
  return bot, h, root
end
-- A fresh start: every bot from an earlier scenario on its feet, the servo not yet started.
function freshWorld()
  for _, bot in ipairs(ALLBOTS) do
    if bot.humanoid.SeatPart then bot.humanoid.Sit = false end
    bot.ride = nil
  end
  active = {}; byModel = {}; HEARTBEAT = nil; Vehicles.servo = nil
  PLAYERS = {}
  CLOCK = CLOCK + 10
end
Combatants = {
  FromCharacter = function(c) return tokenByCharacter[c] end,
  GetCharacter = function(t) return t and (t.Character or t.character) end,
  IsPlayer = function(t) return type(t) == "table" and t.ClassName == "Player" end,
  IsBot = function(t) return type(t) == "table" and t.isBot == true end,
}
"""

# What the VehicleService section needs from the rest of VehicleService.lua.
VS_PRELUDE = r"""
VehicleService = {}
PROMPT_DISTANCE = 10
EXIT_BOX = Vector3.new(2.4, 4.6, 2.4)
BAIL_SPEED = 28
active = {}
byModel = {}
"""

# What the BotService section needs from the rest of BotService.lua.
BS_PRELUDE = r"""
BotService = {}
STATS = setmetatable({}, { __index = function() return 0 end })
MatchConfig = { BotDriversMax = 6, BotDriversPerTeam = 4, BotDriveMinTrip = 220, BotBoardReach = 60, BotGunnerWait = 25,
  BotBurstRest = 0.48, BotStormRotate = 0.6, BotThinkInterval = 0.25 }
FLEE_WINDOW = 3
AIM_SETTLE_DELAY = 0.28
combatantList = {}
function castRay(o, d, p) return workspace:Raycast(o, d, p), true end
function combatantsNear(p, r)
  local out = {}
  for _, e in ipairs(combatantList) do if (e.position - p).Magnitude <= r then table.insert(out, e) end end
  return out, #out
end
function accuracyAt(d) return 0.5 end
function flat(v) return Vector3.new(v.X, 0, v.Z) end
function flatDistance(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end
function safeCircle() return nil end
function stormPressure() return 0 end
function stormGoal(p) return p + Vector3.new(300, 0, 0) end
function insideCircle() return true end
StormService = { IsOutside = function() return false end }
OBJECTIVE = nil
function modeObjective() return OBJECTIVE, "push" end
MODESTATE = nil
function BotService.ModeState() return MODESTATE end
function reportSighting() end
function stopFacing() end
function finishReload() end
function shootAt() SHOTS_BY_HAND = (SHOTS_BY_HAND or 0) + 1 end
NAVIGATED = 0
function navigate() NAVIGATED = NAVIGATED + 1 end
TARGET = nil
function findTarget() return TARGET end
MODULES = {}
function lazy(name) return MODULES[name] end
"""

SCENARIOS = r"""
local V = Vector3.new
local R = {}
local function frames(seconds, each)
  local steps = math.floor(seconds * 60 + 0.5)
  for _ = 1, steps do
    CLOCK = CLOCK + 1 / 60
    runScheduler()
    if HEARTBEAT then HEARTBEAT(1 / 60) end
    if each then each() end
  end
end

-- A car the service made: DriverSeat, PassengerSeat1, GunnerSeat (armed), their prompts; speed answers
-- the servo's throttle and brake.
function makeCar(armed, at)
  local model = newInst("Model", "Vehicle")
  adopt(workspace, model)
  local chassis = newInst("Part", "Chassis", { Size = V(6, 2, 12), CFrame = CFrame.new(at.X, 2.5, at.Z), Position = V(at.X, 2.5, at.Z),
    AssemblyLinearVelocity = V(0, 0, 0), Anchored = false })
  adopt(model, chassis)
  model.PrimaryPart = chassis
  local seat = makeSeatInst("VehicleSeat", "DriverSeat", model)
  local passenger = makeSeatInst("Seat", "PassengerSeat1", model)
  local gunner = armed and makeSeatInst("Seat", "GunnerSeat", model) or nil
  if gunner then gunner:SetAttribute("Gunner", true) end
  local function prompt(text) return { Enabled = true, ActionText = text, MaxActivationDistance = 10 } end
  local entry = {
    model = model, info = { exits = { CFrame.new(-4, 0, 0), CFrame.new(4, 0, 0) }, kind = "car" },
    rig = { chassis = chassis, handling = VD.Handling.Rotster, wheelbase = 8.5, wheels = { {} } },
    seat = seat, passengers = { passenger }, gunnerSeat = gunner, takeover = nil, promptText = {},
    occupants = {}, riders = {}, switching = {}, prompts = {}, deaths = {}, savedMass = {}, wrecked = false,
  }
  entry.prompts[seat] = prompt("Drive")
  entry.prompts[passenger] = prompt("Ride")
  if gunner then entry.prompts[gunner] = prompt("Man the gun") end
  for s, p in pairs(entry.prompts) do
    entry.promptText[s] = p.ActionText
    s.onChanged = function() onSeatChanged(entry, s) end
  end
  table.insert(active, entry)
  byModel[model] = entry
  return entry
end
VehicleService.Get = function(model) return byModel[model] end

-- The car's speed answers the wheel: the brake takes it down at 60 studs/s^2, the throttle up.
function drivePhysics(entry)
  local seat = entry.seat
  local chassis = entry.rig.chassis
  local speed = chassis.AssemblyLinearVelocity.Magnitude
  local t = seat.ThrottleFloat or 0
  if t < 0 then speed = math.max(0, speed + t * 60 / 60) elseif t > 0 then speed = math.min(60, speed + t * 30 / 60) end
  chassis.AssemblyLinearVelocity = V(0, 0, -speed)
end

-- A bot sat at the wheel and driving at `speed`, as BotService's own startRide leaves it.
function seatBot(entry, seat, role, speed)
  local bot, h, root = makeBot("Bot" .. role, entry.rig.chassis.Position + V(-4, 0, 0))
  seat:Sit(h)
  local ride = Vehicles.startRide(bot, role, seat, "trip", CLOCK)
  entry.rig.chassis.AssemblyLinearVelocity = V(0, 0, -(speed or 0))
  if ride and ride.drive then
    BotNav.DriveTo(ride.drive, entry.rig.chassis.Position + V(0, 0, -500), {})
    ride.drive.senseCap = 60
  end
  return bot, h, ride
end

-- A player triggering the prompt of `seat` (trySit on its own coroutine, as a Triggered handler runs).
function trigger(entry, player, seat)
  local done = false
  task.spawn(function() trySit(entry, player, seat); done = true end)
  return function() return done end
end

-- 1: a team mate takes the wheel of a moving car.
function scenarioTakeover(teams, relation, seatKind, speed)
  freshWorld()
  local armed = seatKind == "gunner"
  local entry = makeCar(armed, V(0, 0, 0))
  local seat = seatKind == "gunner" and entry.gunnerSeat or entry.seat
  local bot, bh, ride = seatBot(entry, seat, seatKind == "gunner" and "gunner" or "driver", speed)
  if armed and seatKind ~= "gunner" then entry.gunnerSeat:Sit(makeBot("Gun", V(0, 0, 0)).humanoid) end
  local player, ph, proot = makePlayer("Player", 7001, V(-3, 3, 0))
  proot.Position = seat.Position + V(-3, 0, 0)
  TEAMS = {}
  MODULES.ModeTeams = { IsActive = function() return teams end, TeamOf = function(t) return TEAMS[t] end,
    Arena = function() return nil end, BaseVehicleFolder = function() return nil end }
  if teams then
    TEAMS[bot] = 1
    TEAMS[player] = relation == "mate" and 1 or 2
    player.Character:SetAttribute("Team", TEAMS[player])
    bot.character:SetAttribute("Team", 1)
  end
  if relation == "foe" then bot.target = player end
  if relation == "playerSeat" then
    -- A player at the wheel instead: nobody's seat to take.
    bh.Sit = false
    local other = makePlayer("Other", 7002, V(0, 0, 0))
    seat:Sit(other.Character:FindFirstChildOfClass("Humanoid"))
  end
  Vehicles.refreshFoes(bot, CLOCK)
  local out = {}
  out.promptUp = entry.prompts[seat].Enabled
  out.promptText = entry.prompts[seat].ActionText
  out.clientShows = CLIENT_MAY(seat, player.Character, player.UserId)
  -- Another bot tries for the seat the moment the takeover starts.
  local done = trigger(entry, player, seat)
  local interloper = makeBot("Interloper", seat.Position)
  interloper.character.HumanoidRootPart.Position = seat.Position
  local stolen = false
  local exitSpeed = nil
  local wasIn = true
  frames(3, function()
    drivePhysics(entry)
    if seat.Occupant == nil and not stolen then
      stolen = VehicleService.BotSit(interloper.humanoid, seat) and not done()
    end
    if wasIn and bh.SeatPart == nil then
      wasIn = false
      exitSpeed = entry.rig.chassis.AssemblyLinearVelocity.Magnitude
    end
  end)
  out.finished = done()
  out.playerSeated = ph.SeatPart == seat and seat.Occupant == ph
  out.botOut = bh.SeatPart == nil and bot.ride == nil
  out.exitSpeed = exitSpeed or -1
  out.stolen = stolen
  out.promptAfter = entry.prompts[seat].ActionText
  -- Back on foot: its next think is an on-foot one (no ride, not boarding straight back in).
  out.resumes = not Vehicles.botVehicleThink(bot, bh, bot.character.HumanoidRootPart, bot.character.HumanoidRootPart, CLOCK)
  return out
end

-- 2: an armed car at the wheel with nobody on the gun. `who` (optional) says who else is about:
--   teams = true      a team mode (bots may gun), nobody else about
--   player = "near"   the battle royale, a player standing 12 studs from the car, not the bot's fight
--   player = "far"    ...the same player 60 studs off
--   player = "foe"    ...12 studs off, but the one the bot is fighting
--   player = "seated" ...12 studs off, but at the wheel of another car
--   player = "dead"   ...12 studs off, dead
--   player = "coming" ...starts 25 studs off, walks over at 18 studs/s and mans the gun by its prompt
function scenarioWait(attacked, gunnerManned, seconds, who)
  freshWorld()
  who = who or {}
  MODULES.ModeTeams = { IsActive = function() return who.teams == true end, TeamOf = function() return who.teams and 1 or nil end,
    Arena = function() return nil end, BaseVehicleFolder = function() return nil end }
  local entry = makeCar(true, V(0, 0, 0))
  local bot, bh, ride = seatBot(entry, entry.seat, "driver", 0)
  if gunnerManned then
    local gunner = makeBot("Gunner", V(0, 0, 0))
    entry.gunnerSeat:Sit(gunner.humanoid)
  end
  local player, ph, proot
  if who.player then
    local start = ({ near = 12, far = 60, foe = 12, seated = 12, dead = 12, coming = 25 })[who.player]
    player, ph, proot = makePlayer("Walker", 8100, V(start, 3, 0))
    if who.player == "foe" then bot.target = player end
    if who.player == "dead" then ph.Health = 0 end
    if who.player == "seated" then makeSeatInst("VehicleSeat", "DriverSeat", newInst("Model", "OtherCar")):Sit(ph) end
  end
  local manned = nil
  OBJECTIVE = nil
  bot.wanderGoal = V(0, 0, -600)
  TARGET = attacked and { token = makePlayer("Shooter", 8001, V(0, 3, -60)), root = { Position = V(0, 3, -60),
    AssemblyLinearVelocity = V(0, 0, 0), Parent = true }, distance = 60 } or nil
  local planned = 0
  local drive = ride.drive
  local realDriveTo = BotNav.DriveTo
  BotNav.DriveTo = function(...) planned = planned + 1; return realDriveTo(...) end
  local held, triggered, heldFrames, thinks = 0, 0, 0, 0
  local left = nil
  local t0 = CLOCK
  frames(seconds, function()
    if attacked then bot.threat = { token = TARGET.token, position = TARGET.root.Position, at = CLOCK } end
    if who.player == "coming" and not manned and not ph.SeatPart then
      local to = entry.gunnerSeat.Position - proot.Position
      if to.Magnitude > 8 then
        proot.Position = proot.Position + to.Unit * (18 / 60)
      else
        trigger(entry, player, entry.gunnerSeat)
        manned = CLOCK - t0
      end
    end
    if math.floor(CLOCK * 4) ~= math.floor((CLOCK - 1 / 60) * 4) and bot.ride then
      thinks = thinks + 1
      Vehicles.botVehicleThink(bot, bh, bot.character.HumanoidRootPart, bot.character.HumanoidRootPart, CLOCK)
      if bot.ride then
        if bot.ride.drive.hold then held = held + 1 end
        if bot.ride.trigger then triggered = triggered + 1 end
      elseif not left then
        left = CLOCK - t0
      end
    end
  end)
  BotNav.DriveTo = realDriveTo
  TARGET = nil
  bot.target = nil
  return { thinks = thinks, held = held, triggered = triggered, planned = planned, left = left or -1,
    reason = bot.lastVehicleExit, manned = manned or -1, gunnerIsPlayer = ph ~= nil and ph.SeatPart == entry.gunnerSeat }
end

-- 3: a team mate (or, with no teams, another bot) on foot beside an armed car whose bot driver waits for a gunner.
function scenarioGunnerPick(teams)
  freshWorld()
  local entry = makeCar(true, V(0, 0, 0))
  local driver = seatBot(entry, entry.seat, "driver", 0)
  local mate, mh, mroot = makeBot("Mate", V(12, 3, 0))
  TEAMS = { [driver] = 1, [mate] = 1 }
  MODULES.ModeTeams = { IsActive = function() return teams end, TeamOf = function(t) return TEAMS[t] end,
    Arena = function() return nil end, BaseVehicleFolder = function() return nil end }
  VehicleService.VehiclesNear = VehicleService.VehiclesNear
  local seat, role, purpose = Vehicles.pickSeat(mate, mroot, CLOCK)
  return { picked = seat and seat.Name or "none", role = role or "none" }
end
"""


def build(sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(sim.cars.PRELUDE)
    lua.execute(PRELUDE)
    vd = lua.execute(luau(read("ReplicatedStorage/Shared/VehicleDynamics.lua")))
    lua.globals().VD = vd
    nav = lua.execute(luau(sim.driving_source(sources[NAV])))
    lua.globals().BotNav = nav
    nav_stub = "BotNav.Drop = function() end\nBotNav.Priority = { Loot = 3 }\n"
    lua.execute(nav_stub)
    lua.execute(VS_PRELUDE)
    lua.execute(BS_PRELUDE)
    lua.execute(luau(vs_section(sources[VS])).replace("local function ", "function "))
    lua.execute("MODULES.VehicleService = VehicleService; MODULES.VehicleWeapons = { GunnerSeatOf = function(m) return m:FindFirstChild('GunnerSeat') end, DrivenBy = function() return nil end, AmmoOf = function() return 40, { kind = 'hitscan', magazine = 40 } end }")
    # BotDriveTactics (where the wheel goes near enemies), whole, as BotService lazy-loads it.
    lua.globals().MODULES.BotDriveTactics = lua.execute(luau(read("ServerScriptService/Modules/BotDriveTactics.lua")))
    lua.execute("function hostile() return true end\nfunction flatLook() return Vector3.new(0, 0, -1) end")
    lua.execute(luau(bs_section(sources[BS])) +"\n_G.Vehicles = Vehicles\n_G.VEHICLE = VEHICLE\n")
    lua.execute(luau(vc_rule(sources[VC])).replace("local function mayTakeOver", "function CLIENT_MAY"))
    lua.execute(SCENARIOS)
    return lua


def server_rule(lua, teams, relation):
    """The server's answer and the client's for one case, through the real functions."""
    return lua.eval(r"""function(teams, relation)
      freshWorld()
      local entry = makeCar(false, Vector3.new(0, 0, 0))
      local bot, bh = makeBot("RuleBot", Vector3.new(0, 0, 0))
      entry.seat:Sit(bh)
      Vehicles.startRide(bot, "driver", entry.seat, "trip", CLOCK)
      local player = makePlayer("RulePlayer", 9001, Vector3.new(0, 0, 0))
      TEAMS = {}
      MODULES.ModeTeams = { IsActive = function() return teams end, TeamOf = function(t) return TEAMS[t] end }
      if teams then
        TEAMS[bot] = 1; bot.character:SetAttribute("Team", 1)
        TEAMS[player] = relation == "mate" and 1 or 2; player.Character:SetAttribute("Team", TEAMS[player])
      end
      bot.target = relation == "foe" and player or nil
      bot.threat = relation == "shotBy" and { token = player, at = CLOCK } or nil
      Vehicles.refreshFoes(bot, CLOCK)
      local server = BotService.TakeoverAllowed(bot, player)
      local client = CLIENT_MAY(entry.seat, player.Character, player.UserId)
      Vehicles.leaveRide(bot, "test")
      return server, client
    end""")(teams, relation)


def run(sources):
    lua = build(sources)
    G = lua.globals()
    P = []
    rows = []
    cases = [
        ("team mate takes the wheel", True, "mate", "driver", 40, True),
        ("enemy team asks for the wheel", True, "enemy", "driver", 40, False),
        ("no teams, not its fight", False, "neutral", "driver", 40, True),
        ("no teams, its target asks", False, "foe", "driver", 40, False),
        ("team mate takes the gun", True, "mate", "gunner", 30, True),
        ("a player's own seat", False, "playerSeat", "driver", 0, False),
    ]
    for label, teams, relation, seat_kind, speed, allowed in cases:
        o = G.scenarioTakeover(teams, relation, seat_kind, speed)
        o = {k: o[k] for k in o}
        rows.append((label, o))
        if relation == "playerSeat":
            if o["playerSeated"] or o["promptUp"]:
                P.append(f"{label}: a player's seat was offered or taken")
            continue
        if not o["promptUp"] or o["promptText"] != "Take over":
            P.append(f"{label}: the prompt of a bot's seat is not up as 'Take over' ({o['promptUp']}, {o['promptText']})")
        if o["clientShows"] != allowed:
            P.append(f"{label}: the client {'shows' if o['clientShows'] else 'hides'} the prompt")
        if allowed:
            if not (o["playerSeated"] and o["botOut"] and o["finished"]):
                P.append(f"{label}: not done (player seated {o['playerSeated']}, bot out {o['botOut']})")
            if seat_kind == "driver" and not (0 <= o["exitSpeed"] < 4):
                P.append(f"{label}: the bot got out at {o['exitSpeed']:.1f} studs/s, not stopped")
            if o["stolen"]:
                P.append(f"{label}: another bot sat in the seat during the takeover")
            if o["promptAfter"] == "Take over":
                P.append(f"{label}: the prompt still reads 'Take over' with a player in the seat")
            if not o["resumes"]:
                P.append(f"{label}: the bot did not go back to what it does on foot")
        else:
            if o["playerSeated"] or o["botOut"]:
                P.append(f"{label}: allowed (player seated {o['playerSeated']}, bot out {o['botOut']})")

    matrix = []
    for teams in (True, False):
        for relation in (("mate", "enemy") if teams else ("neutral", "foe", "shotBy")):
            server, client = server_rule(lua, teams, relation)
            matrix.append((teams, relation, server, client))
            expected = relation in ("mate", "neutral")
            if server != expected or client != server:
                P.append(f"RULE teams={teams} {relation}: server {server}, client {client}, expected {expected}")

    def wait_for(attacked, seconds, **who):
        o = G.scenarioWait(attacked, False, seconds, lua.table_from(who) if who else None)
        return {k: o[k] for k in o}

    # The invariant: a driver never waits for a gunner nobody can be. Nobody, in the battle royale, is
    # every case below but "near" (where no bot takes a vehicle's gun, Vehicles.botGunners): out on its
    # first think (0.25 s), never driven off unmanned.
    waits = {}
    for case, who in (("nobody", {}), ("far", {"player": "far"}), ("foe", {"player": "foe"}),
                      ("seated", {"player": "seated"}), ("dead", {"player": "dead"})):
        o = waits[case] = wait_for(False, 30, **who)
        if o["planned"] > 0:
            P.append(f"GUNNER battle royale, {case}: planned {o['planned']} routes unmanned")
        if not (0 <= o["left"] <= 1) or o["reason"] != "no gunner":
            P.append(f"GUNNER battle royale, {case}: waited {o['left']:.1f} s for a gunner nobody can be ({o['reason']})")
    # The guard: a gunner who can come is still waited for, BotGunnerWait (25 s) as before, held, not fired.
    for case, who in (("team mode", {"teams": True}), ("player near", {"player": "near"})):
        o = waits[case] = wait_for(False, 30, **who)
        if o["planned"] > 0 or o["held"] < o["thinks"] - 1 - (30 - 25) * 4 - 2:
            P.append(f"GUNNER {case}: planned {o['planned']} routes, held {o['held']} of {o['thinks']} thinks")
        if o["triggered"] > 0:
            P.append(f"GUNNER {case}, not attacked: fired {o['triggered']} thinks")
        if not (24 <= o["left"] <= 27):
            P.append(f"GUNNER {case}: gave the car up after {o['left']:.1f} s (want BotGunnerWait, 25)")
    # A player walking over from 25 studs mans the gun by its prompt: the bot is still at the wheel, and drives.
    o = waits["player coming"] = wait_for(False, 12, player="coming")
    if o["left"] >= 0 or not o["gunnerIsPlayer"] or o["planned"] < 1:
        P.append(f"GUNNER player coming: bot left at {o['left']:.1f} s, player on the gun {o['gunnerIsPlayer']}, "
                 f"planned {o['planned']} routes")
    # Shot at with nobody to come: the wait is kept (the attacked exit), the driver fires its own gun.
    attacked = wait_for(True, 8)
    if attacked["triggered"] < attacked["thinks"] - 2 or attacked["planned"] > 0 or attacked["left"] >= 0:
        P.append(f"GUNNER unmanned, attacked: fired on {attacked['triggered']} of {attacked['thinks']} thinks, "
                 f"planned {attacked['planned']}, left at {attacked['left']:.1f} s")
    manned = {k: v for k, v in G.scenarioWait(False, True, 8).items()}
    if manned["planned"] < 1 or manned["held"] > 0:
        P.append(f"GUNNER manned: planned {manned['planned']} routes, held {manned['held']} thinks (should drive)")
    pick = {k: v for k, v in G.scenarioGunnerPick(True).items()}
    if pick["picked"] != "GunnerSeat":
        P.append(f"GUNNER: a team mate beside a waiting driver picked {pick['picked']} ({pick['role']})")
    # Why nobody but a player can come in the battle royale (Vehicles.botGunners): a bot beside the waiting
    # driver does not take the gun. If that changes, Vehicles.gunnerMayCome must count bots again.
    br_pick = {k: v for k, v in G.scenarioGunnerPick(False).items()}
    pick["br"] = br_pick["picked"]
    if br_pick["picked"] == "GunnerSeat":
        P.append("GUNNER: in the battle royale a bot took a waiting driver's gun; gunnerMayCome counts only players")
    return rows, matrix, (waits, attacked, manned, pick), P


PLANTS = [
    ("the enemy let in", BS, "\t\treturn mine ~= nil and mine == theirs\n", "\t\treturn true\n"),
    ("the car not stopped first", BS, "\tif speed < 4 or now - yieldTo.at > VEHICLE.TAKEOVER_STOP then",
     "\tif true then"),
    ("the prompt hidden for a bot's seat", VS, "\t\t\tprompt.Enabled = promptSeat.Occupant == nil or held",
     "\t\t\tprompt.Enabled = promptSeat.Occupant == nil"),
    ("the client shows the prompt to the bot's target", VC,
     'return not (type(foes) == "string" and string.find(foes, "," .. tostring(userId) .. ",", 1, true) ~= nil)', "return true"),
    ("the armed car driven off unmanned", BS, "\tif gunnerSeat and not gunnerSeat.Occupant then", "\tif false then"),
    # Invariant: a driver never waits for a gunner nobody can be (the battle royale counted as a team mode).
    ("a wait for a gunner nobody can be", BS, "\tif Vehicles.botGunners() then\n\t\treturn true", "\tif true then\n\t\treturn true"),
    ("the bot's own fight counted as a gunner", BS, "not (bot.vehicleFoes and bot.vehicleFoes[player])", "true"),
    # Guards: a gunner who can come is still waited for.
    ("a player by the car not waited for", BS, "(root.Position - at).Magnitude <= VEHICLE.RIDE_REACH", "false"),
    ("a team mode's wait cut short", BS, "\tif Vehicles.botGunners() then\n\t\treturn true", "\tif false then\n\t\treturn true"),
    ("the gun seat never picked", BS, '\t\t\t\t\treturn seats.gunner, "gunner", "gunner"', '\t\t\t\t\treturn nil'),
    ("the seat not held during a takeover", VS, "\tif entry.wrecked or entry.takeover or entry.rig.chassis.CFrame.UpVector.Y < 0.4 then",
     "\tif entry.wrecked or entry.rig.chassis.CFrame.UpVector.Y < 0.4 then"),
]


def main():
    sources = {p: read(p) for p in (VS, BS, NAV, VC)}
    rows, matrix, gunner, problems = run(sources)
    print("TAKEOVER (trySit on the seat's prompt, a bot in the seat):")
    for label, o in rows:
        print(f"  {label:32} prompt {o['promptUp']!s:5} '{o['promptText']}'  client shows {o['clientShows']!s:5}  "
              f"player seated {o['playerSeated']!s:5}  bot out {o['botOut']!s:5}  bot got out at {o['exitSpeed']:.1f} studs/s  "
              f"back on foot {o['resumes']}")
    print("RULE (server TakeoverAllowed, client mayTakeOver):")
    for teams, relation, server, client in matrix:
        print(f"  teams {teams!s:5} {relation:8} server {server!s:5} client {client}")
    waits, attacked, manned, pick = gunner
    for case, wait in waits.items():
        got_out = f"got out after {wait['left']:.2f} s ({wait['reason']})" if wait["left"] >= 0 else "still at the wheel"
        extra = f", player manned the gun at {wait['manned']:.1f} s" if wait["manned"] >= 0 else ""
        print(f"GUNNER unmanned, {case:13}: held {wait['held']}/{wait['thinks']} thinks, {wait['planned']} routes, "
              f"fired {wait['triggered']}, {got_out}{extra}")
    print(f"GUNNER unmanned, shot at, 8 s, nobody to come: fired on {attacked['triggered']}/{attacked['thinks']} thinks, "
          f"{attacked['planned']} routes, {'got out' if attacked['left'] >= 0 else 'still at the wheel'}")
    print(f"GUNNER manned 8 s: {manned['planned']} routes planned, held {manned['held']} thinks")
    print(f"GUNNER team mate beside a waiting driver picks: {pick['picked']} as {pick['role']}; "
          f"in the battle royale another bot picks: {pick['br']}")
    for p in problems:
        print("PROBLEM", p)
    caught = 0
    for label, path, before, after in PLANTS:
        text = sources[path]
        if text.count(before) != 1:
            print(f"  PLANT NOT APPLIED ({label}): text found {text.count(before)} times")
            continue
        planted = dict(sources)
        planted[path] = text.replace(before, after)
        try:
            found = run(planted)[3]
        except Exception as err:  # an error is a failed check, not a pass
            found = [f"error: {str(err).splitlines()[0]}"]
        caught += bool(found)
        print(f"  plant {'CAUGHT' if found else 'MISSED'}: {label} -> {found[0] if found else 'passed'}")
    print(f"planted faults: {caught}/{len(PLANTS)} caught")
    ok = not problems and caught == len(PLANTS)
    print("bot driving takeover: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
