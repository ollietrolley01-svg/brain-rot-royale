#!/usr/bin/env python3
"""Bots on a mounted gun (task 20): do they pick targets out to the gun's reach, lead them, hit them, and
fire at the gun's own rhythm? And (task 21's finding) does a bot walking to a seat still fight, and give the
walk up once an enemy has got into that vehicle? From the real source, before and after.

Runs, in lupa, cut out of the files as they stand (Luau's compound assignments spelled out for stock Lua):
  * ServerScriptService/Modules/VehicleWeapons.lua whole (Fire, Aim, DrivenBy, AmmoOf, InArc, BotAimPoint)
    with the real Shared/VehicleWeaponData.lua, Shared/Ballistics.lua and CombatService's shot budget, over
    tools/vehicle_weapons_check.py's world (every part a sphere a traced bullet can miss);
  * BotService.lua's sight and targeting block whole (hasLineOfSight, the combatant grid, sightOf,
    findTarget) and every `Vehicles.*` function of its BOT VEHICLES section (gunnerThink, noteFight, the
    trigger, the hit chance, and gunReach / gunnerTarget where the tree has them), with the real
    accuracyAt, AIM_SETTLE_DELAY and MatchConfig;
  * for WALK, tools/bot_driving_takeover.py's world (the whole BOT VEHICLES section, VehicleService's seats).
A bot sits on the gun of a real mount (the vehicles' positions from VehicleModels, as vehicle_weapons_check
reads them; the two emplacements' from MountedGunModels' builders) and thinks every 0.25 s (gunnerThink:
target, turret aim, trigger) while the servo pulls the trigger at 60 Hz. The target is a body of spheres
(feet, legs, root, torso, head), standing, or running across the gun's line at 16 studs/s, turning back
every 4 s. Bullets are traced; rounds are flown with Ballistics.RoundState to where they pass or come down
against the target's real path. A round counts as a hit when it comes within half its blast of the target
(bot_driving_combat's rule), and deals the spec's damage; a bullet deals what DealDamage was handed. Both
are scaled by MatchConfig.CombatDamageScale, and time to kill is to 100 health with no shield.

Checks (the working tree):
  REACH   a target in the open inside the gun's arc is picked at every range out to its reach (every
          gun: 100, 250 and 300 studs, and just inside the reach of the long guns), never past the reach,
          never one hidden behind a wall (near or far), never one outside a limited arc past vision range.
  ARC     a gun never fires at a target outside its mount's arc (the HMG emplacement, 110 degrees off).
  SPLASH  a launcher never fires a round at a target inside its own blast.
  LEAD    the turret, between shots, points where its shot will meet a running target: for a round, a round
          fired along the published aim comes within half a blast of it; for a bullet, the line passes
          through the body.
  HITS    a rolled-hit round lands within half a blast of a running target at 250 studs (rounds whose
          flight spans the runner turning back are counted and not judged).
  RHYTHM  bursts at the gun's own rate (shots in a burst 1/fireRate apart), rests of at most five shots'
          worth at that rate after the last shot's own interval, never a dry pull, a belt of ten or more never
          run empty.
  WALK    a bot walking to a seat shoots at whoever it sees within its gun's range, and gives the walk up
          once someone it does not share a vehicle with gets in.
Planted faults (always run), each aimed at one of those and never at the old behaviour: the arc ignored,
the splash ignored, the reach unbounded, the far look blind to walls, the turret aimed with no lead, rolled
hits aimed with no lead, a round led by only part of the run, the rest after a burst a flat 1.5 s, the belt fired dry, the walk kept with an enemy
aboard, the walk with no look.

Usage:  python3 tools/bot_gunner_engage_check.py [repo_root] [--before REV]
        (default REV: the commit before this tool's first commit; the before/after table is printed from it)
Not modelled: the network, lag compensation (a bot's shot traces the present), the real map's cover, a
moving gun platform, splash falloff (a round within half a blast counts its full damage), shields.
"""
import re
import subprocess
import sys
from pathlib import Path

from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vehicle_weapons_check as vwc  # noqa: E402
import bot_driving_combat as bdc  # noqa: E402
import bot_driving_takeover as btk  # noqa: E402

ARGS = [a for a in sys.argv[1:]]
BEFORE_REV = None
if "--before" in ARGS:
    i = ARGS.index("--before")
    BEFORE_REV = ARGS[i + 1]
    del ARGS[i:i + 2]
ROOT = Path(ARGS[0] if ARGS else ".").resolve()
vwc.ROOT = ROOT
bdc.ROOT = ROOT
btk.ROOT = ROOT

BOT = "ServerScriptService/Modules/BotService.lua"
VW = "ServerScriptService/Modules/VehicleWeapons.lua"
DATA = "ReplicatedStorage/Shared/VehicleWeaponData.lua"
GUNDATA = "ReplicatedStorage/Shared/MountedGunData.lua"
CFG = "ReplicatedStorage/Shared/MatchConfig.lua"
TOOL = "tools/bot_gunner_engage_check.py"


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def read_rev(rev, rel):
    return subprocess.run(["git", "-C", str(ROOT), "show", f"{rev}:{rel}"], capture_output=True, text=True,
                          check=True).stdout


def default_before():
    log = subprocess.run(["git", "-C", str(ROOT), "log", "--format=%H", "--diff-filter=A", "--", TOOL],
                         capture_output=True, text=True).stdout.split()
    return (log[-1] + "~1") if log else "HEAD"


luau = vwc.luau_to_lua


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


def bot_pieces(src):
    """accuracyAt, AIM_SETTLE_DELAY, the sight and targeting block, the section's VEHICLE numbers and every
    Vehicles function, as definitions only (nothing runs until a scenario calls it)."""
    acc = between(src, "local function accuracyAt", "-- Magazines,")
    settle = re.search(r"^local AIM_SETTLE_DELAY = .*$", src, re.M).group(0)
    sight = between(src, "local function hasLineOfSight", "-- Where a target was last seen")
    section = src[src.index('local RunService = game:GetService("RunService")'):]
    numbers = "\n".join(re.findall(r"^VEHICLE\.\w+ = .*$", section, re.M))
    functions = "\n".join(m.group(0) for m in re.finditer(r"^function Vehicles\.\w+.*?^end$", section, re.M | re.S))
    return "\n".join([luau(acc), settle, luau(sight), "VEHICLE = {}", numbers, "Vehicles = {}", luau(functions),
                      "REFRESH = refreshCombatants"])


# The two emplacements' mounts, from MountedGunModels' builders (YAW, PITCH and L.muzzle of hmg() and
# cannon()): model space, front along -Z.
def emplacement_mounts():
    src = read("ReplicatedStorage/Shared/MountedGunModels.lua")
    out = {}
    for name, fn in (("MountedHMG", "local function hmg()"), ("MountedCannon", "local function cannon()")):
        body = src[src.index(fn):]
        body = body[:body.index("\nend\n")]
        yaw = float(re.search(r"local YAW = ([\d.]+)", body).group(1))
        pitch = float(re.search(r"local PITCH = ([\d.]+)", body).group(1))
        bore = pitch + float(re.search(r"local BORE = PITCH \+ ([\d.]+)", body).group(1))
        mz = float(re.search(r"L\.muzzle = \{ 0, BORE, (-?[\d.]+) \}", body).group(1))
        out[name] = {"yaw": (0, yaw, 0), "pitch": (0, pitch, 0), "muzzle": (0, bore, mz)}
    return out


WORLD_MOCKS = r"""
table.clear = table.clear or function(t) for k in pairs(t) do t[k] = nil end end
-- vehicle_weapons_check's sphere caster, with one fix for sight rays: a ray that ends inside a sphere
-- (hasLineOfSight casts to the root's centre) meets it, as a Roblox ray meets the part's surface first.
function workspace:Raycast(origin, direction, params)
  local len = direction.Magnitude
  local unit = direction.Unit
  local best, bestT = nil, math.huge
  local function excluded(part)
    for _, x in ipairs(params.FilterDescendantsInstances) do
      if part == x or part:IsDescendantOf(x) then return true end
    end
    return false
  end
  for _, part in ipairs(WORLD) do
    if part.radius and not excluded(part) then
      local rel = part.Position - origin
      local t = rel:Dot(unit)
      local miss = (rel - unit * t).Magnitude
      if miss <= part.radius then
        local enter = t - math.sqrt(part.radius * part.radius - miss * miss)
        if t >= 0 and enter <= len and enter < bestT then best, bestT = part, math.max(0, enter) end
      end
    end
  end
  RAYS = RAYS + 1
  if not best then return nil end
  return { Instance = best, Position = origin + unit * bestT }
end
BotService = { Tick = 0 }
BotService.RaycastBudget = {
  BeginFrame = function() end,
  Folders = function() return {} end,
  Filter = function(filter, first) table.clear(filter); filter[1] = first; return filter end,
  LosParams = { FilterDescendantsInstances = {} }, LosFilter = {}, CoverParams = { FilterDescendantsInstances = {} }, CoverFilter = {},
}
function castRay(origin, direction, params) return workspace:Raycast(origin, direction, params), true end
function flat(v) return Vector3.new(v.X, 0, v.Z) end
function flatLook() return Vector3.new(0, 0, -1) end
function hostile(bot, token) return token ~= bot end
function reportSighting() end
-- A tree with task 21's rider sight (PR #74) asks VehicleCover whether a target sits in a vehicle: here
-- every target is on foot.
VehicleCover = { SeatOf = function() return nil end }
StormService = { IsOutside = function() return false end }
ALL = {}
Combatants = MODULES.Combatants
Combatants.All = function() return ALL end
Combatants.IsPlayer = function(t) return type(t) == "table" and t.ClassName == "Player" end
Combatants.IsBot = function(t) return type(t) == "table" and t.isBot == true end
CombatService.GetLastAttacker = function() return nil end
function lazy(name) if name == "VehicleWeapons" then return VW end return nil end
"""

AFTER_MOCKS = r"""
-- The section's own exits and bookkeeping, recorded rather than run (they reach the seat and the map).
EXITS = {}
Vehicles.leaveRide = function(bot, reason) table.insert(EXITS, reason); bot.ride = nil end
Vehicles.refreshFoes = function() end
Vehicles.botGunners = function() return true end
"""

SCENARIOS = r"""
local V = Vector3.new

-- An emplacement: a Model with the mount's parts, a GunnerSeat and the VehicleModel attribute, as
-- MountedGuns builds one (MOUNTS carries its positions). Front along -Z.
function makeGun(modelId, at)
  local g = new("Model", "MountedGun", workspace)
  g:SetAttribute("VehicleModel", modelId)
  local m = MOUNTS[modelId]
  for key, name in pairs({ yaw = "TurretYaw", pitch = "TurretPitch", muzzle = "TurretMuzzle" }) do
    new("Part", name, g, { Position = at + m[key], CFrame = frame(at + m[key], 0) })
  end
  local base = new("Part", "Base", g, { Position = at + V(0, 0.5, 0) })
  g.PrimaryPart = base
  local seat = new("Seat", "GunnerSeat", g, { Position = at + V(0, 2.5, 2) })
  return g, seat
end

local function path(p, t)
  -- Standing, or running across the line at `speed`, turning back every `turn` seconds.
  if p.speed == 0 then return p.base, V(0, 0, 0) end
  local period = 2 * p.turn
  local u = (t - p.t0) % period
  local leg = u < p.turn
  local along = leg and (u - p.turn / 2) or (p.turn / 2 - (u - p.turn))
  return p.base + p.across * (along * p.speed), p.across * (leg and p.speed or -p.speed)
end
PATH = path

-- One engagement. `kind` "vehicle" or "gun" (an emplacement). Returns what came of it.
function engage(kind, modelId, distance, bearing, speed, seconds, seed, wall)
  math.randomseed(seed)
  WORLD = {}
  LOG = {}
  ALL = {}
  EXITS = {}
  CLOCK = 5000 + seed * 97
  ENABLED = true
  local v, seat
  if kind == "gun" then
    v, seat = makeGun(modelId, V(0, 0, 0))
  else
    local _, _, _, gunner = makeVehicle(modelId, 0, V(0, 0, 0))
    v = gunner.Parent
    seat = gunner
  end
  v.PrimaryPart.AssemblyLinearVelocity = V(0, 0, 0)
  local pitchPart = v:FindFirstChild("TurretPitch")
  local bot, bh, bc = makeCharacter(true, "Gunner", pitchPart.Position + V(0, 0.4, 1.6))
  seat:Sit(bh)
  local head = bc:FindFirstChild("Head")
  ALL[bc] = bot
  bot.character, bot.humanoid = bc, bh
  bot.lastHurtAt, bot.sight, bot.seen = -math.huge, {}, {}
  bot.weapon = { range = 150 }
  local b = math.rad(bearing or 0)
  local base = V(-math.sin(b) * distance, 3, -math.cos(b) * distance)
  local p = { base = base, across = V(math.cos(b), 0, -math.sin(b)), speed = speed or 0, turn = 4, t0 = CLOCK }
  local target, character, parts = makeBody("Target", base)
  character:FindFirstChildOfClass("Humanoid").MaxHealth = 100
  ALL[character] = target
  if wall then
    -- A wall: a sphere across the line a third of the way out, too big to see round.
    local from = pitchPart.Position
    table.insert(WORLD, new("Part", "Wall", workspace, { Position = from + (base - from) * 0.33, radius = 12 }))
  end
  local ride = { role = "gunner", model = v, seat = seat, boardedAt = CLOCK, lastTargetAt = CLOCK, burstLeft = 0, nextShotAt = 0 }
  bot.ride = ride
  local out = { thinks = 0, picked = 0, shots = 0, hits = 0, damage = 0, ttk = -1, times = {}, rounds = {}, dry = 0,
    minAmmo = math.huge, aims = {}, rolled = {} }
  local fire = VW.Fire
  VW.Fire = function(token, aim)
    local ok, why = fire(token, aim)
    if why == "ammo" then out.dry = out.dry + 1 end
    return ok, why
  end
  local scale = MatchConfig.CombatDamageScale or 1
  local start = CLOCK
  local frames = math.floor(seconds * 60)
  for i = 1, frames do
    CLOCK = CLOCK + 1 / 60
    local at, vel = path(p, CLOCK)
    moveBody(parts, at, vel)
    if i % 15 == 1 then
      BotService.Tick = BotService.Tick + 1
      REFRESH()
      out.thinks = out.thinks + 1
      if bot.ride then
        Vehicles.gunnerThink(bot, head, head, ride, CLOCK)
      end
      if bot.ride and ride.trigger and ride.fight and ride.fight.token == target then
        out.picked = out.picked + 1
        -- The turret as published after the think (degrees, to half a degree).
        table.insert(out.aims, { yaw = v:GetAttribute("AimYaw"), pitch = v:GetAttribute("AimPitch"), at = CLOCK })
      end
    end
    local before = #LOG
    local rolledBefore = STATS.vehicleAimedHits
    if bot.ride and ride.trigger then
      Vehicles.vehicleTrigger(bot, ride, CLOCK)
    end
    for k = before + 1, #LOG do
      local e = LOG[k]
      if e.what == "shot" and #e.endPoints > 0 or e.what == "round" then
        out.shots = out.shots + 1
        table.insert(out.times, CLOCK)
      end
      if e.what == "round" then
        table.insert(out.rounds, { origin = e.origin, direction = e.direction, at = CLOCK, def = e.def,
          rolledHit = STATS.vehicleAimedHits > rolledBefore })
      end
      if e.what == "damage" and e.victim == target then
        out.hits = out.hits + 1
        out.damage = out.damage + e.amount * scale
        if out.ttk < 0 and out.damage >= 100 then out.ttk = CLOCK - start end
      end
    end
    local ammo = VW.AmmoOf(v)
    if ammo and ammo < out.minAmmo then out.minAmmo = ammo end
  end
  VW.Fire = fire
  out.path = p
  out.start = start
  out.vehicle = v
  out.exits = #EXITS
  return out
end

-- Where a round launched from `origin` along `direction` at time `at` passes nearest the target on its
-- path, and where it comes down on the ground (y = 0): the smaller of the two misses.
function flyRound(kind, origin, direction, at, p)
  local spec = MODULES.Ballistics.Rounds[kind]
  local best = math.huge
  local t = 0
  local landedAt = nil
  while t < (spec.maxTime or 5) do
    local pos = MODULES.Ballistics.RoundState(spec, origin, direction, workspace.Gravity, t)
    local tgt = PATH(p, at + t)
    local d = (pos - tgt).Magnitude
    if d < best then best = d; landedAt = at + t end
    if pos.Y <= 0 and t > 0.05 then
      local miss = (V(pos.X, 0, pos.Z) - V(tgt.X, 0, tgt.Z)).Magnitude
      if miss < best then best = miss; landedAt = at + t end
      break
    end
    t = t + 1 / 240
  end
  return best, landedAt
end

-- The muzzle and barrel direction for a published yaw and pitch (degrees), by VehicleWeaponData's own
-- pose (Turn), from the parts at rest as VehicleWeapons' solve reads them.
function barrel(v, yawDeg, pitchDeg)
  local yawPart, pitchPart, muzzle = v:FindFirstChild("TurretYaw"), v:FindFirstChild("TurretPitch"), v:FindFirstChild("TurretMuzzle")
  local f = yawPart.CFrame
  local pivot = f:PointToObjectSpace(pitchPart.Position)
  local mouth = f:VectorToObjectSpace(muzzle.Position - pitchPart.Position)
  local D = MODULES.VehicleWeaponData
  local yaw, pitch = math.rad(yawDeg), math.rad(pitchDeg)
  local origin = f:PointToWorldSpace(D.Turn(pivot, yaw, 0) + D.Turn(mouth, yaw, pitch))
  local direction = f:VectorToWorldSpace(D.Turn(V(0, 0, -1), yaw, pitch))
  return origin, direction
end

-- How far the line from `origin` along `direction` passes from `point`.
function lineMiss(origin, direction, point)
  local rel = point - origin
  local t = rel:Dot(direction)
  return (rel - direction * t).Magnitude
end
"""

WALK = r"""
local V = Vector3.new
-- A bot on foot 40 studs from a free armed car in a team mode, set walking to its gun (pickSeat's
-- "fight" pick, as boarding is left by considerVehicle). Every think is botVehicleThink, as updateBot
-- calls it first. `enemyAt`: seconds in, an enemy player sits at the wheel. `shooter`: an enemy in view
-- 50 studs off (findTarget's answer) the whole walk.
function walk(enemyAt, shooter)
  freshWorld()
  local entry = makeCar(true, V(0, 0, 0))
  local bot, bh, root = makeBot("Walker", V(40, 3, 0))
  bot.weapon = { range = 150 }
  local enemy, eh = makePlayer("Enemy", 7301, V(-60, 3, 0))
  TEAMS = { [bot] = 1, [enemy] = 2 }
  MODULES.ModeTeams = { IsActive = function() return true end, TeamOf = function(t) return TEAMS[t] end,
    Arena = function() return nil end, BaseVehicleFolder = function() return nil end }
  TARGET = shooter and { token = enemy, root = enemy.Character.HumanoidRootPart, character = enemy.Character, distance = 50 } or nil
  SHOTS_BY_HAND = 0
  bot.boarding = { seat = entry.gunnerSeat, role = "gunner", purpose = "fight", giveUpAt = CLOCK + VEHICLE.WALK }
  local walking, enemyAboardWalking, thinks = 0, 0, 0
  for i = 1, 40 do
    CLOCK = CLOCK + 0.25
    if enemyAt and CLOCK >= 0 and i == math.floor(enemyAt / 0.25) then
      entry.seat:Sit(eh)
    end
    thinks = thinks + 1
    Vehicles.botVehicleThink(bot, bh, root, root, CLOCK)
    if bot.boarding then
      walking = walking + 1
      if entry.seat.Occupant == eh then enemyAboardWalking = enemyAboardWalking + 1 end
    end
  end
  TARGET = nil
  return { thinks = thinks, walking = walking, enemyAboard = enemyAboardWalking, shots = SHOTS_BY_HAND }
end
"""


def build(sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(vwc.MOCKS)
    lua.execute("BYCHAR = {}; local fc = MODULES.Combatants.FromCharacter; MODULES.Combatants.FromCharacter = function(c) return BYCHAR[c] or fc(c) end")
    lua.execute(bdc.EXTRA_MOCKS)
    mounts, _ = vwc.mounts_from_source()
    lua.execute("MOUNTS = {}")
    vec = lambda t: f"Vector3.new({t[0]}, {t[1]}, {t[2]})"  # noqa: E731
    for model, m in mounts.items():
        lua.execute(f'MOUNTS["{model}"] = {{ yaw = {vec(m["yaw"])}, pitch = {vec(m["pitch"])}, muzzle = {vec(m["muzzle"])}, '
                    f'dyaw = {vec(m["dyaw"])}, dpitch = {vec(m["dpitch"])}, dmuzzle = {vec(m["dmuzzle"])} }}')
    for model, m in emplacement_mounts().items():
        lua.execute(f'MOUNTS["{model}"] = {{ yaw = {vec(m["yaw"])}, pitch = {vec(m["pitch"])}, muzzle = {vec(m["muzzle"])} }}')
    lua.execute("Color3 = { fromRGB = function() return {} end, new = function() return {} end }")
    lua.execute("MODULES.SafeValue = (function() " + luau(read("ReplicatedStorage/Shared/SafeValue.lua")) + " end)()")
    lua.execute("MODULES.Ballistics = (function() " + luau(read("ReplicatedStorage/Shared/Ballistics.lua")) + " end)()")
    lua.execute("MODULES.VehicleWeaponData = (function() " + luau(sources[DATA]) + " end)()")
    # The emplacements' weapons, merged as VehicleWeaponData's own tail does in Roblox.
    lua.execute("local G = (function() " + luau(sources[GUNDATA]) + " end)()\n"
                "for k, s in pairs(G.Weapons) do MODULES.VehicleWeaponData.Weapons[k] = MODULES.VehicleWeaponData.Weapons[k] or s end\n"
                "for m, k in pairs(G.ByModel) do MODULES.VehicleWeaponData.ByModel[m] = MODULES.VehicleWeaponData.ByModel[m] or k end")
    lua.execute(luau(vwc.shot_budget_source()))
    lua.execute("VW = (function() " + luau(sources[VW]) + " end)()")
    lua.execute("CLOCK = 1000; VW.Now = function() return CLOCK end; VW.Start()")
    lua.execute("MatchConfig = (function() " + luau(sources[CFG]) + " end)()")
    lua.execute(WORLD_MOCKS)
    lua.execute(bot_pieces(sources[BOT]))
    lua.execute(AFTER_MOCKS)
    lua.execute(SCENARIOS)
    return lua


def build_walk(sources):
    tk = {p: read(p) for p in (btk.VS, btk.NAV, btk.VC)}
    tk[btk.BS] = sources[BOT]
    lua = btk.build(tk)
    lua.execute(WALK)
    return lua


# The guns: (label, kind, model id, projectile or None, reach). Every mount bots can sit at.
GUNS = [
    ("Rotster Roof Gun", "vehicle", "Rotster"),
    ("Tartaruga HMG", "vehicle", "TartarugaScout"),
    ("Ranger Rocket Pod", "vehicle", "CrocodiloRanger"),
    ("Sahur Van Mortar", "vehicle", "SahurVan"),
    ("Camelo Grenade Launcher", "vehicle", "CameloCarrier"),
    ("Rattlefang HMG (emplacement)", "gun", "MountedHMG"),
    ("Boomba Cannon (emplacement)", "gun", "MountedCannon"),
]
# The pod's rockets and the Camelo's grenades straight ahead pass over the cab's front floor: the cars'
# targets stand 60 degrees off the nose (bot_driving_combat does the same); the emplacements' dead ahead.
BEARING = {"vehicle": 60, "gun": 0}
SEEDS = (3, 17, 41)
TABLE_SEEDS = (3, 17, 41, 59, 83, 97)  # the before/after table: a launcher fires ~35 rounds a run, so more runs


def spec_of(G, model):
    D = G.MODULES.VehicleWeaponData
    return D.Weapons[D.ByModel[model]]


def reach_of(spec, cfg_vision):
    return max(cfg_vision, spec.range or 0)


def measure(sources, ranges_for, seconds=20):
    """Per gun, range and speed: picked share, shots, hits, damage a second and time to kill, over SEEDS."""
    lua = build(sources)
    G = lua.globals()
    vision = G.MatchConfig.BotVisionRange
    rows = []
    for label, kind, model in GUNS:
        spec = spec_of(G, model)
        for distance in ranges_for(spec, vision):
            for speed in (0, 16):
                agg = {"thinks": 0, "picked": 0, "shots": 0, "hits": 0, "damage": 0.0, "ttk": []}
                for seed in TABLE_SEEDS:
                    o = G.engage(kind, model, distance, BEARING[kind], speed, seconds, seed, False)
                    hits, damage, ttk = o.hits, o.damage, o.ttk
                    if spec.kind == "round":
                        hits, damage, ttk = round_hits(G, spec, o)
                    agg["thinks"] += o.thinks
                    agg["picked"] += o.picked
                    agg["shots"] += o.shots
                    agg["hits"] += hits
                    agg["damage"] += damage
                    agg["ttk"].append(ttk)
                rows.append((label, distance, speed, agg))
    return rows


def round_hits(G, spec, o):
    scale = G.MatchConfig.CombatDamageScale or 1
    hits, damage, ttk = 0, 0.0, -1
    for r in o.rounds.values():
        miss, landed = G.flyRound(spec.projectile, r.origin, r.direction, r.at, o.path)
        if miss <= spec.splashRadius * 0.5:
            hits += 1
            damage += spec.damage * scale
            if ttk < 0 and damage >= 100:
                ttk = landed - o.start
    return hits, damage, ttk


def fmt_ttk(ttks):
    done = [t for t in ttks if t >= 0]
    if not done:
        return "   never"
    return f"{sum(done) / len(done):5.1f} s" + (f" ({len(done)}/{len(ttks)})" if len(done) < len(ttks) else "")


def table_ranges(spec, vision):
    reach = reach_of(spec, vision)
    return sorted({100, 250, 300, max(300, int(reach) - 20)})


def checks(sources):
    """The working tree's checks; returns (report lines, problems)."""
    lua = build(sources)
    G = lua.globals()
    vision = G.MatchConfig.BotVisionRange
    P, lines = [], []
    examined = 0

    # REACH: picked out to the reach, never past it, never through a wall, never outside a limited arc far off.
    for label, kind, model in GUNS:
        spec = spec_of(G, model)
        reach = reach_of(spec, vision)
        for distance in sorted({100, 250, min(300, reach - 10), reach - 10}):
            examined += 1
            o = G.engage(kind, model, distance, BEARING[kind], 0, 3, 5, False)
            if o.picked < o.thinks - 2:
                P.append(f"REACH {label}: a target in the open at {distance} studs (reach {reach:.0f}) picked on {o.picked}/{o.thinks} thinks")
        examined += 1
        o = G.engage(kind, model, reach + 30, BEARING[kind], 0, 3, 5, False)
        if o.picked > 0:
            P.append(f"REACH {label}: a target at {reach + 30:.0f} studs, past its reach {reach:.0f}, picked on {o.picked} thinks")
        for distance in sorted({150, max(vision, reach) - 10}):
            examined += 1
            o = G.engage(kind, model, distance, BEARING[kind], 0, 3, 5, True)
            if o.picked > 0 or o.shots > 0:
                P.append(f"REACH {label}: a target behind a wall at {distance} studs picked on {o.picked} thinks, {o.shots} shots")
    o = G.engage("gun", "MountedHMG", 400, 110, 0, 3, 5, False)
    examined += 1
    if o.picked > 0:
        P.append(f"REACH the HMG emplacement picked a target at 400 studs 110 degrees off its front on {o.picked} thinks")
    lines.append(f"REACH: {examined} placements over {len(GUNS)} guns examined")

    # ARC: the HMG emplacement turns 60 degrees either way; a target 110 degrees off at 100 studs.
    o = G.engage("gun", "MountedHMG", 100, 110, 0, 8, 7, False)
    lines.append(f"ARC: HMG emplacement, target 110 degrees off at 100 studs: picked {o.picked}/{o.thinks} thinks, {o.shots} shots")
    if o.shots > 0:
        P.append(f"ARC: {o.shots} shots at a target outside the HMG emplacement's arc")

    # SPLASH: every launcher, a target inside its own blast.
    for label, kind, model in GUNS:
        spec = spec_of(G, model)
        if spec.kind == "round":
            o = G.engage(kind, model, spec.splashRadius, BEARING[kind], 0, 5, 9, False)
            lines.append(f"SPLASH: {label}, target {spec.splashRadius} studs off: {o.shots} rounds")
            if o.shots > 0:
                P.append(f"SPLASH: {label} fired {o.shots} rounds at a target inside its own blast")

    # LEAD and HITS: a runner at 250 studs (the emplacements' 200: the cannon's lob tops out near there).
    for label, kind, model in GUNS:
        spec = spec_of(G, model)
        distance = 250 if kind == "vehicle" else 200
        misses, rolled_near, rolled, turned = [], 0, 0, 0
        for seed in SEEDS + (59, 83):
            o = G.engage(kind, model, distance, BEARING[kind], 16, 20, seed, False)
            for a in o.aims.values():
                if a.yaw is None:
                    continue
                origin, direction = G.barrel(o.vehicle, a.yaw, a.pitch)
                if spec.kind == "round":
                    miss, _ = G.flyRound(spec.projectile, origin, direction, a.at, o.path)
                else:
                    miss = G.lineMiss(origin, direction, G.PATH(o.path, a.at)[0])
                misses.append(miss)
            if spec.kind == "round":
                for r in o.rounds.values():
                    if r.rolledHit:
                        miss, landed = G.flyRound(spec.projectile, r.origin, r.direction, r.at, o.path)
                        # Only a round whose flight stays inside one leg of the run: nobody can lead a
                        # runner who turns back while the round is in the air.
                        turn, t0 = o.path.turn, o.path.t0
                        if landed is not None and (r.at - t0) // turn == (landed - t0) // turn:
                            rolled += 1
                            rolled_near += miss <= spec.splashRadius * 0.5
                        else:
                            turned += 1
        misses.sort()
        med = misses[len(misses) // 2] if misses else float("inf")
        bound = spec.splashRadius * 0.5 if spec.kind == "round" else 1.5
        lines.append(f"LEAD: {label}, runner at {distance} studs: turret aim misses by {med:.1f} studs (median of {len(misses)} thinks; bound {bound:.1f})"
                     + (f"; rolled hits within half a blast {rolled_near}/{rolled} ({turned} more landed after the runner turned back, not judged)"
                        if spec.kind == "round" else ""))
        if not misses or med > bound:
            P.append(f"LEAD: {label}'s turret aim at a runner {distance} studs off misses by {med:.1f} studs (median), over {bound:.1f}")
        if spec.kind == "round" and (rolled < 3 or rolled_near < rolled * 0.8):
            P.append(f"HITS: {label}: {rolled_near}/{rolled} rolled hits came within half a blast of a runner at {distance} studs")

    # RHYTHM: 30 s standing, at 100 studs (a launcher at 200: the mortar's lob can't come down nearer).
    for label, kind, model in GUNS:
        spec = spec_of(G, model)
        o = G.engage(kind, model, 200 if spec.kind == "round" else 100, BEARING[kind], 0, 30, 5, False)
        times = list(o.times.values())
        gaps = [b - a for a, b in zip(times, times[1:])]
        step = 1 / spec.fireRate
        inburst = sum(1 for g in gaps if g <= step * 1.6)
        rests = [g for g in gaps if step * 1.6 < g < 2.0 + spec.rechargeDelay]
        longest = max(rests) if rests else 0
        lines.append(f"RHYTHM: {label}: {o.shots} shots in 30 s ({o.shots / 30:.1f}/s of {spec.fireRate}/s), {inburst} in bursts, "
                     f"{len(rests)} rests up to {longest:.2f} s ({longest * spec.fireRate:.1f} shots' worth), {o.dry} dry pulls, belt low {o.minAmmo:.1f}")
        # Past the belt's cooling pauses (longer than any rest), most shots come at the gun's rate.
        if inburst < (inburst + len(rests)) * 0.5:
            P.append(f"RHYTHM: {label}: only {inburst} shots came at the gun's rate, against {len(rests)} rests")
        # A rest starts once the burst's last shot's own interval is up: at most five shots' worth after that.
        if longest > 6.2 * step + 0.02:
            P.append(f"RHYTHM: {label}: a rest of {longest:.2f} s, {longest * spec.fireRate:.1f} shots' worth at its rate (at most 6)")
        # A belt of ten or more is never run empty (it cools at 15%); a launcher's smaller load is fired out
        # and reloads, but never with a pull the gun refuses.
        if o.dry > 0 or (spec.magazine >= 10 and o.minAmmo < 1):
            P.append(f"RHYTHM: {label}: {o.dry} dry pulls, belt down to {o.minAmmo:.1f}: fired it empty")

    # WALK (task 21's finding).
    W = build_walk(sources).globals()
    aboard = W.walk(1.0, False)
    looks = W.walk(None, True)
    lines.append(f"WALK: enemy at the wheel 1 s into the walk: walked on {aboard.walking}/{aboard.thinks} thinks, "
                 f"{aboard.enemyAboard} of them with the enemy aboard")
    lines.append(f"WALK: an enemy in view 50 studs off the whole walk: {looks.shots} shots on {looks.walking} thinks walking")
    if aboard.enemyAboard > 1:
        P.append(f"WALK: kept walking to the gun {aboard.enemyAboard} thinks with an enemy at the wheel")
    if looks.walking > 0 and looks.shots < looks.walking * 0.5:
        P.append(f"WALK: {looks.shots} shots over {looks.walking} thinks walking past an enemy in view")
    return lines, P


PLANTS = [
    ("the arc ignored", BOT, "\tif not VehicleWeapons.InArc(vehicle, targetRoot.Position, mount) then\n\t\treturn\n\tend\n", ""),
    ("the splash ignored", BOT, "\tif spec.kind == \"round\" and distance < (spec.splashRadius or 12) + 6 then\n\t\treturn\n\tend\n", ""),
    ("the reach unbounded", BOT, "\treturn math.max(MatchConfig.BotVisionRange, spec and spec.range or 0)", "\treturn 5000"),
    ("the far look blind to walls", BOT, "\t\tlocal visible, computed = sightOf(bot, head, row.token, row.character, now, false)",
     "\t\tlocal visible, computed = true, true"),
    ("the turret aimed with no lead", BOT, "\t\t\t\ttargetRoot.AssemblyLinearVelocity, true, mount))", "\t\t\t\tVector3.zero, true, mount))"),
    ("rolled hits aimed with no lead", BOT,
     "local aim = VehicleWeapons.BotAimPoint(vehicle, targetRoot.Position, targetRoot.AssemblyLinearVelocity, hit, mount)",
     "local aim = VehicleWeapons.BotAimPoint(vehicle, targetRoot.Position, Vector3.zero, hit, mount)"),
    ("a flat 1.5 s rest after every burst", BOT,
     "\t\tride.nextShotAt = now + (rounds and 1.5 + math.random() or 3 + math.random() * 2) / spec.fireRate",
     "\t\tride.nextShotAt = now + 1.5"),
    ("a round led by only part of the run", VW, "local BOT_LEAD = 1", "local BOT_LEAD = 0.7"),
    ("the belt fired dry", BOT, "\tif ammo < 1 or (spec.magazine >= 10 and ammo < spec.magazine * 0.15) then", "\tif ammo < 0 then"),
    ("the walk kept with an enemy aboard", BOT, "\t\t\tor (seats and Vehicles.strangerAboard(Vehicles.teamOf(bot), seats)) then",
     "\t\t\tthen"),
    ("the walk with no look", BOT, "\t\tVehicles.fightOnTheWay(bot, root, head, now)\n", ""),
]


def main():
    names = (BOT, VW, DATA, GUNDATA, CFG)
    after = {p: read(p) for p in names}
    rev = BEFORE_REV or default_before()
    rev = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", rev], capture_output=True, text=True).stdout.strip() or rev
    try:
        before = {p: read_rev(rev, p) for p in names}
    except subprocess.CalledProcessError as err:
        print(f"NOTE: no before revision {rev} ({err}); before/after skipped")
        before = None

    lines, problems = checks(after)
    for line in lines:
        print(line)
    for p in problems:
        print("PROBLEM", p)

    if before is not None:
        print(f"\nBEFORE ({rev}) / AFTER (working tree), {len(TABLE_SEEDS)} seeds x 20 s each, target 60 degrees off a car's nose "
              "(dead ahead of an emplacement); speed 0 standing, 16 running:")
        rb = measure(before, table_ranges)
        ra = measure(after, table_ranges)
        print(f"  {'gun':30} {'range':>5} {'spd':>3} | {'picked':>7} {'shots':>5} {'hits':>5} {'dmg/s':>6} {'ttk':>13} | "
              f"{'picked':>7} {'shots':>5} {'hits':>5} {'dmg/s':>6} {'ttk':>13}")
        for (label, d, s, b), (_, _, _, a) in zip(rb, ra):
            def cols(x):
                return (f"{x['picked'] / max(1, x['thinks']):6.0%} {x['shots']:5d} {x['hits']:5d} "
                        f"{x['damage'] / (20 * len(TABLE_SEEDS)):6.1f} {fmt_ttk(x['ttk']):>13}")
            print(f"  {label:30} {d:5d} {s:3d} | {cols(b)} | {cols(a)}")

    caught = 0
    for label, path, old, new in PLANTS:
        text = after[path]
        if text.count(old) != 1:
            print(f"  PLANT NOT APPLIED ({label}): text found {text.count(old)} times")
            continue
        planted = dict(after)
        planted[path] = text.replace(old, new)
        try:
            found = checks(planted)[1]
        except Exception as err:  # an error is a failed check, not a pass
            found = [f"error: {str(err).splitlines()[0]}"]
        caught += bool(found)
        print(f"  plant {'CAUGHT' if found else 'MISSED'}: {label} -> {found[0] if found else 'passed'}")
    print(f"planted faults: {caught}/{len(PLANTS)} caught")
    ok = not problems and caught == len(PLANTS)
    print("bot gunner engage check: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
