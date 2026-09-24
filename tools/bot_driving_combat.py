#!/usr/bin/env python3
"""Bots on a vehicle's gun: are they as good as a bot on foot, no better, and do they use the gun well?

Runs the real source, in lupa, with tools/vehicle_weapons_check.py's mocks of the world:
  * ServerScriptService/Modules/VehicleWeapons.lua whole (Fire, DrivenBy's who-works-the-gun rule,
    AmmoOf, InArc, BotAimPoint), with the real Shared/VehicleWeaponData.lua, Shared/Ballistics.lua,
    Shared/SafeValue.lua and CombatService's own shot budget;
  * BotService.lua's vehicle trigger and hit chance (Vehicles.vehicleTrigger, Vehicles.vehicleHitChance)
    with the real accuracyAt, AIM_SETTLE_DELAY and MatchConfig, cut out of the file as they stand;
  * BotService.lua's shootAt chance block (the lines tools/bot_aggression_check.py cuts out too), for
    the on-foot dial the vehicle gun must match.
A bot sits on the gun of a real mount (positions from VehicleModels.Mounts, as vehicle_weapons_check
reads them) and holds the trigger frame by frame at 60 Hz against a target built of spheres (legs,
root, torso, head) that a traced bullet can actually miss. Rounds are flown with Ballistics.RoundState
to where they pass or land.

Checks:
  DIAL      per shot, the roof gun's hits over its shots, at 20/60/150 studs, standing and strafing,
            against the on-foot dial at the same moments (the mean of shootAt's chance): within
            0.75x..1.2x of it. Not a laser, not a pushover.
  SAME      vehicleHitChance equals shootAt's chance at every range, moment and target speed, with the
            vehicle standing and no spread (the numbers are the on-foot dial, not a copy of it).
  ROUNDS    rocket pod and mortar: rolled hits pass within half a blast of the target (led, lobbed),
            rolled misses stay clear of the blast; the mortar holds fire inside its reach.
  BURSTS    a 30 s engagement: shots come in bursts with rests between, never a dry "ammo" refusal,
            the belt never run to empty, a round never fired into its own blast.
  ARC       a target in the rocket pod's blind arc (behind it) is not fired at.
  SEATS     the gun's own seat (GunnerSeat) fires; the driver is refused while it is manned and
            fires while it is empty (a solo player keeps a working gun); a passenger never fires.
Planted faults (always run), each aimed at one of those: every roll a hit (laser), the spread not
allowed for, the miss aimed at the target, no lead, no lob, no cooling, no burst rest, the arc
ignored, the gun seat ignored, the driver refused with the gun seat empty.

Usage:  python3 tools/bot_driving_combat.py [repo_root]
"""
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vehicle_weapons_check as vwc  # noqa: E402

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
vwc.ROOT = ROOT


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def luau(src):
    return vwc.luau_to_lua(src)


def between(text, start, end):
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


def bot_pieces(bot_src):
    acc = between(bot_src, "local function accuracyAt", "-- Magazines,")
    settle = re.search(r"^local AIM_SETTLE_DELAY = .*$", bot_src, re.M).group(0)
    body = re.search(r"^VEHICLE\.BODY_RADIUS = .*$", bot_src, re.M).group(0)
    chance = re.search(r"^function Vehicles\.vehicleHitChance.*?^end$", bot_src, re.M | re.S).group(0)
    trigger = re.search(r"^function Vehicles\.vehicleTrigger.*?^end$", bot_src, re.M | re.S).group(0)
    foot = between(bot_src, "\tlocal chance = accuracyAt(distance)", "\tlocal hit = math.random() < chance")
    return "\n".join([
        luau(acc), settle, "VEHICLE = {}", body, "Vehicles = {}", luau(chance), luau(trigger),
        "function footChance(bot, now, distance, targetRoot)\n" + luau(foot) + "\treturn chance\nend",
    ])


EXTRA_MOCKS = r"""
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)
workspace.Gravity = 196.2
STATS = setmetatable({}, { __index = function() return 0 end })
function lazy(name) if name == "VehicleWeapons" then return VW end return nil end

-- A body a bullet can miss: legs, root, torso, head, as spheres on one axis. The root carries the
-- velocity the bot reads.
function makeBody(name, at)
  local c = new("Model", name, workspace)
  local h = new("Humanoid", "Humanoid", c, { Health = 100 })
  local parts = {}
  for _, spec in ipairs({ { "LeftFoot", -2.5, 0.5 }, { "LeftLeg", -1.5, 0.55 }, { "HumanoidRootPart", 0, 1.0 },
      { "UpperTorso", 1.3, 0.95 }, { "Head", 2.6, 0.6 } }) do
    local p = new("Part", spec[1], c, { Position = at + Vector3.new(0, spec[2], 0), radius = spec[3], offset = spec[2],
      AssemblyLinearVelocity = Vector3.zero })
    table.insert(WORLD, p)
    table.insert(parts, p)
  end
  local token = new("Player", name, nil, { Character = c, UserId = 99 })
  BYCHAR[c] = token
  return token, c, parts
end
function moveBody(parts, at, velocity)
  for _, p in ipairs(parts) do
    p.Position = at + Vector3.new(0, p.offset, 0)
    p.AssemblyLinearVelocity = velocity
  end
end
-- The turret's seat (vehicle_weapons_check's makeVehicle gives every armed vehicle one).
function gunSeat(v)
  return v:FindFirstChild("GunnerSeat")
end
"""

SCENARIOS = r"""
local R = {}
local function count(what, victim)
  local n = 0
  for _, e in ipairs(LOG) do
    if e.what == what and (victim == nil or e.victim == victim) then n = n + 1 end
  end
  return n
end

-- One engagement: `model` at the origin facing -Z (heading 0), a bot on its gun, a body `distance`
-- off at `bearing` degrees (0 straight ahead), strafing across at `strafe` studs/s. Returns what came of it.
function engage(model, distance, bearing, strafe, seconds, seed)
  math.randomseed(seed or 11)
  WORLD = {}
  LOG = {}
  CLOCK = 5000
  ENABLED = true
  local v, driverSeat = makeVehicle(model, 0, Vector3.new(0, 0, 0))
  v.PrimaryPart.AssemblyLinearVelocity = Vector3.zero
  local seat = gunSeat(v)
  local bot, bh = makeCharacter(true, "BotGunner", Vector3.new(0, 4.5, 1))
  seat:Sit(bh)
  local b = math.rad(bearing or 0)
  local base = Vector3.new(-math.sin(b) * distance, 3, -math.cos(b) * distance)
  local across = Vector3.new(math.cos(b), 0, -math.sin(b))
  local target, character, parts = makeBody("Target", base)
  local ride = { model = v, fight = { token = target, root = parts[3], acquiredAt = CLOCK }, burstLeft = 0, nextShotAt = 0 }
  local out = { shots = 0, hits = 0, dial = 0, rounds = {}, gaps = {}, dry = 0, minAmmo = math.huge, rolled = 0 }
  local lastShot = nil
  local frame = 1 / 60
  local fire = VW.Fire
  VW.Fire = function(token, aim)
    local ok, why = fire(token, aim)
    if why == "ammo" then out.dry = out.dry + 1 end
    return ok, why
  end
  for i = 1, math.floor(seconds * 60) do
    CLOCK = CLOCK + frame
    local swing = strafe and strafe > 0 and math.sin(CLOCK * 1.3) or 0
    local velocity = across * (strafe or 0) * (swing >= 0 and 1 or -1)
    moveBody(parts, base + across * (strafe or 0) * 0.77 * -math.cos(CLOCK * 1.3), velocity)
    local before = #LOG
    local rolledBefore = STATS.vehicleAimedHits
    Vehicles.vehicleTrigger(bot, ride, CLOCK)
    for k = before + 1, #LOG do
      local e = LOG[k]
      if e.what == "shot" or e.what == "round" then
        if e.what == "round" or #e.endPoints > 0 then
          out.shots = out.shots + 1
          out.dial = out.dial + footChance({ acquiredAt = ride.fight.acquiredAt }, CLOCK, (parts[3].Position - v.PrimaryPart.Position).Magnitude, parts[3])
          if lastShot then table.insert(out.gaps, CLOCK - lastShot) end
          lastShot = CLOCK
        end
        if e.what == "round" then
          table.insert(out.rounds, { origin = e.origin, direction = e.direction, at = CLOCK,
            rolledHit = STATS.vehicleAimedHits > rolledBefore, target = parts[3].Position, velocity = parts[3].AssemblyLinearVelocity })
        end
      end
    end
    local ammo = VW.AmmoOf(v)
    if ammo < out.minAmmo then out.minAmmo = ammo end
  end
  VW.Fire = fire
  out.hits = count("damage", target)
  out.rolled = STATS.vehicleAimedHits
  return out
end

-- Where a launched round passes nearest a target moving from `target` at `velocity`, and where it
-- comes down on the ground (y = 0).
function flyRound(kind, round, ground)
  local spec = MODULES.Ballistics.Rounds[kind]
  local best, landed = math.huge, nil
  local t = 0
  while t < (spec.maxTime or 5) do
    local p = MODULES.Ballistics.RoundState(spec, round.origin, round.direction, workspace.Gravity, t)
    local at = round.target + round.velocity * t
    local d = (p - at).Magnitude
    if d < best then best = d end
    if p.Y <= (ground or 0) and t > 0.05 then
      landed = p
      local miss = (Vector3.new(p.X, 0, p.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
      if miss < best then best = miss end
      break
    end
    t = t + 1 / 240
  end
  return best, landed
end

function landMiss(round, landed)
  local at = round.target
  return (Vector3.new(landed.X, 0, landed.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude
end

-- The chance, both ways, over a grid of ranges, moments and target speeds (vehicle standing, no spread).
function sameGrid()
  local worst = 0
  local rows = 0
  for _, distance in ipairs({ 5, 20, 45, 60, 100, 150, 250 }) do
    for _, since in ipairs({ 0, 0.2, 0.28, 0.5, 1, 1.78, 3 }) do
      for _, speed in ipairs({ 0, 10, 25 }) do
        local root = { AssemblyLinearVelocity = Vector3.new(speed, 0, 0) }
        local ride = { fight = { acquiredAt = 10 }, model = { PrimaryPart = { AssemblyLinearVelocity = Vector3.zero } } }
        local a = Vehicles.vehicleHitChance(ride, 10 + since, distance, root, { kind = "hitscan", spread = 0 })
        local b = footChance({ acquiredAt = 10 }, 10 + since, distance, root)
        worst = math.max(worst, math.abs(a - b))
        rows = rows + 1
      end
    end
  end
  return worst, rows
end

-- Who may fire what, by seat, straight through VW.Fire: the gunner's seat the turret, the driving seat
-- the driver's gun (whether or not the turret is manned), a passenger nothing, a lone driver never the
-- turret.
function seatRules()
  WORLD = {}
  LOG = {}
  CLOCK = 90000
  ENABLED = true
  local v, driverSeat, passengerSeat = makeVehicle("Rotster", 0, Vector3.new(500, 0, 0))
  local gun = gunSeat(v)
  local target = makeBody("SeatTarget", Vector3.new(500, 3, -40))
  local driver, dh = makeCharacter(false, "SeatDriver", Vector3.new(498.5, 4.5, 0.5))
  local gunner, gh = makeCharacter(true, "SeatGunner", Vector3.new(500, 5, 1))
  local rider, rh = makeCharacter(false, "SeatRider", Vector3.new(501.5, 4.5, 0.5))
  driverSeat:Sit(dh); passengerSeat:Sit(rh)
  local aim = Vector3.new(500, 3, -40)
  local r = {}
  -- The client's own rule (VehicleWeaponClient's drivenVehicle, which decides which mount's controls
  -- and HUD come up) must agree with the server's DrivenBy at every step, mount and all.
  r.clientAgrees = true
  local function client(humanoid, token)
    if CLIENT_DRIVEN then
      CLIENT_PLAYER.Character = { FindFirstChildOfClass = function() return humanoid end }
      local _, _, clientMount = CLIENT_DRIVEN()
      local _, _, _, _, serverMount = VW.DrivenBy(token)
      if clientMount ~= serverMount then r.clientAgrees = false end
    end
  end
  CLOCK = CLOCK + 1
  r.driverSolo = VW.Fire(driver, aim) == true and v:GetAttribute("DriverGunAmmo") ~= nil
  r.driverNeverTurret = v:GetAttribute("WeaponAmmo") == nil
  client(dh, driver)
  gun:Sit(gh)
  CLOCK = CLOCK + 1
  r.gunnerFires = VW.Fire(gunner, aim) == true and v:GetAttribute("WeaponAmmo") ~= nil
  client(gh, gunner)
  CLOCK = CLOCK + 1
  local before = v:GetAttribute("WeaponAmmo")
  r.driverKeepsOwnGun = VW.Fire(driver, aim) == true and v:GetAttribute("WeaponAmmo") == before
  client(dh, driver)
  CLOCK = CLOCK + 1
  r.passengerRefused = select(2, VW.Fire(rider, aim)) == "not driving"
  client(rh, rider)
  gun.Occupant = nil; gh.SeatPart = nil
  CLOCK = CLOCK + 1
  before = v:GetAttribute("WeaponAmmo")
  r.driverAgain = VW.Fire(driver, aim) == true and v:GetAttribute("WeaponAmmo") == before
  client(dh, driver)
  return r
end
"""


def build(vw_src, data_src, bot_src, cfg_src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(vwc.MOCKS)
    lua.execute("BYCHAR = {}; local fc = MODULES.Combatants.FromCharacter; MODULES.Combatants.FromCharacter = function(c) return BYCHAR[c] or fc(c) end")
    lua.execute(EXTRA_MOCKS)
    mounts, _ = vwc.mounts_from_source()
    lua.execute("MOUNTS = {}")
    for model, m in mounts.items():
        lua.execute(
            f'MOUNTS["{model}"] = {{ yaw = Vector3.new({m["yaw"][0]}, {m["yaw"][1]}, {m["yaw"][2]}), '
            f'pitch = Vector3.new({m["pitch"][0]}, {m["pitch"][1]}, {m["pitch"][2]}), '
            f'muzzle = Vector3.new({m["muzzle"][0]}, {m["muzzle"][1]}, {m["muzzle"][2]}), '
            f'dyaw = Vector3.new({m["dyaw"][0]}, {m["dyaw"][1]}, {m["dyaw"][2]}), '
            f'dpitch = Vector3.new({m["dpitch"][0]}, {m["dpitch"][1]}, {m["dpitch"][2]}), '
            f'dmuzzle = Vector3.new({m["dmuzzle"][0]}, {m["dmuzzle"][1]}, {m["dmuzzle"][2]}) }}')
    # Before Ballistics: its throwable specs build Color3 values at load time.
    lua.execute("Color3 = { fromRGB = function() return {} end, new = function() return {} end }")
    lua.execute("MODULES.SafeValue = (function() " + luau(read("ReplicatedStorage/Shared/SafeValue.lua")) + " end)()")
    lua.execute("MODULES.Ballistics = (function() " + luau(read("ReplicatedStorage/Shared/Ballistics.lua")) + " end)()")
    lua.execute("MODULES.VehicleWeaponData = (function() " + luau(data_src) + " end)()")
    lua.execute(luau(vwc.shot_budget_source()))
    lua.execute("VW = (function() " + luau(vw_src) + " end)()")
    lua.execute("CLOCK = 1000; VW.Now = function() return CLOCK end; VW.Start()")
    lua.execute("MatchConfig = (function() " + luau(cfg_src) + " end)()")
    lua.execute(bot_pieces(bot_src))
    lua.execute(SCENARIOS)
    lua.execute(client_rule(CLIENT_SOURCE[0] or read(CLIENT)))
    return lua


DIAL_CASES = [(20, 0), (60, 0), (150, 0), (20, 20), (60, 20), (150, 20)]


def run(vw_src, data_src, bot_src, cfg_src):
    lua = build(vw_src, data_src, bot_src, cfg_src)
    G = lua.globals()
    res = {"dial": [], "problems": []}
    P = res["problems"]

    # DIAL: the roof gun, long enough for a few hundred shots each.
    for distance, strafe in DIAL_CASES:
        shots = hits = 0
        dial = 0.0
        for seed in range(4):
            o = G.engage("Rotster", distance, 0, strafe, 30, 101 + seed)
            shots += o.shots
            hits += o.hits
            dial += o.dial
        rate = hits / max(1, shots)
        expect = dial / max(1, shots)
        ratio = rate / expect if expect else 0
        res["dial"].append((distance, strafe, shots, rate, expect, ratio))
        if shots < 100:
            P.append(f"DIAL {distance} studs strafe {strafe}: only {shots} shots in 2 minutes")
        if not (0.75 <= ratio <= 1.2):
            P.append(f"DIAL {distance} studs strafe {strafe}: hit rate {rate:.3f} is {ratio:.2f}x the on-foot dial {expect:.3f}")

    # SAME: the chance itself.
    worst, rows = G.sameGrid()
    res["same"] = (worst, rows)
    if worst > 1e-9:
        P.append(f"SAME: vehicleHitChance differs from shootAt's chance by up to {worst:.4f} over {rows} cases")

    # ROUNDS: rockets, standing and running; the mortar at range and inside its reach.
    rounds = {}
    for label, model, kind, distance, strafe, radius in [
            ("rocket", "CrocodiloRanger", "rocket", 70, 0, 12), ("rocket running", "CrocodiloRanger", "rocket", 90, 18, 12),
            ("mortar", "SahurVan", "grenade", 220, 0, 13), ("mortar far", "SahurVan", "grenade", 300, 0, 13)]:
        hitsNear = hitsTotal = missClear = missTotal = 0
        for seed in range(3):
            # The pod's rockets off to the side (60 degrees): straight ahead over the cab it holds a 4-degree
            # floor, which a body 70 studs out on level ground is under.
            o = G.engage(model, distance, 60 if model == "CrocodiloRanger" else 0, strafe, 20, 31 + seed)
            for r in o.rounds.values():
                best, landed = G.flyRound(kind, r, 0)
                if kind == "grenade":
                    # A lob is judged where it comes down, not where it passes over.
                    best = G.landMiss(r, landed) if landed else float("inf")
                if r.rolledHit:
                    hitsTotal += 1
                    hitsNear += best <= radius * 0.5
                else:
                    missTotal += 1
                    missClear += best > radius
        rounds[label] = (hitsNear, hitsTotal, missClear, missTotal)
        if hitsTotal < 3 or hitsNear < hitsTotal * 0.8:
            P.append(f"ROUNDS {label}: {hitsNear}/{hitsTotal} rolled hits came within half a blast of the target")
        if missTotal and missClear < missTotal * 0.9:
            P.append(f"ROUNDS {label}: only {missClear}/{missTotal} rolled misses stayed clear of the blast")
    near = G.engage("SahurVan", 60, 0, 0, 10, 7)
    rounds["mortar too near"] = near.shots
    if near.shots > 0:
        P.append(f"ROUNDS: the mortar fired {near.shots} rounds at a target inside its reach (60 studs)")
    res["rounds"] = rounds

    # BURSTS: 30 s on the roof gun.
    o = G.engage("Rotster", 60, 0, 0, 30, 5)
    gaps = sorted(o.gaps.values())
    rests = sum(1 for g in gaps if g >= 0.4)
    fast = sum(1 for g in gaps if g < 0.2)
    res["bursts"] = (o.shots, rests, fast, o.dry, o.minAmmo)
    # A burst is 6 to 10 shots, so a rest at least every 12 (the belt's own cool-downs alone are far fewer).
    if rests < max(5, o.shots / 12) or fast < rests:
        P.append(f"BURSTS: {o.shots} shots, {rests} rests of 0.4 s or more, {fast} shots back to back: not bursts")
    if o.dry > 0 or o.minAmmo < 1:
        P.append(f"BURSTS: {o.dry} dry pulls, the belt down to {o.minAmmo:.1f}: fired it empty")
    o = G.engage("CrocodiloRanger", 10, 0, 0, 5, 3)
    if o.shots > 0:
        P.append(f"BURSTS: {o.shots} rockets fired at a target inside their own blast (10 studs)")

    # ARC: the pod turns all the way round now, but over the cab it never tips below its front floor
    # (4 degrees up): a target straight ahead and 10 degrees down, 25 studs out, is outside its arc.
    o = G.engage("CrocodiloRanger", 25, 0, 0, 8, 9)
    res["arc"] = o.shots
    if o.shots > 0:
        P.append(f"ARC: {o.shots} rockets fired at a target under the pod's front floor, outside its arc")

    # SEATS
    seats = G.seatRules()
    res["seats"] = {k: bool(seats[k]) for k in ("driverSolo", "driverNeverTurret", "gunnerFires", "driverKeepsOwnGun", "passengerRefused", "driverAgain", "clientAgrees")}
    for key, ok in res["seats"].items():
        if not ok:
            P.append(f"SEATS: {key} failed")
    return res


BOT = "ServerScriptService/Modules/BotService.lua"
CLIENT = "StarterPlayerScripts/VehicleWeaponClient.client.lua"
CLIENT_SOURCE = [None]  # a planted copy of the client, while a plant runs


def client_rule(src):
    # gunnerSeatOf and drivenVehicle, as the client has them, over a mock player.
    a = src.index("local function gunnerSeatOf(vehicle)")
    b = src.index("-- What's under the aim point on the screen")
    return ("CLIENT_PLAYER = {}\nlocal player = CLIENT_PLAYER\nlocal VehicleWeaponData = MODULES.VehicleWeaponData\n"
            + luau(src[a:b]) + "\nCLIENT_DRIVEN = drivenVehicle\n")
VW = "ServerScriptService/Modules/VehicleWeapons.lua"
PLANTS = [
    ("laser: every roll a hit", BOT, "local hit = math.random() < Vehicles.vehicleHitChance(ride, now, distance, targetRoot, spec)",
     "local hit = true"),
    ("the mount's spread not allowed for", BOT, "chance = math.min(1, chance / ((w + integral * 2 / math.pi) / cone))",
     "chance = chance"),
    ("a miss aimed at the target", VW, "\tif not hit then\n\t\tlocal off", "\tif false then\n\t\tlocal off"),
    ("no lead on a running target", VW, "point += (targetVelocity or Vector3.zero) * flight * BOT_LEAD", "point += Vector3.zero"),
    ("no lob: the mortar aimed straight", VW, "\t\tlocal angle = round.speed and lobAngle(spec, round, origin, point)", "\t\tlocal angle = nil"),
    ("the belt fired dry", BOT, "\tif ammo < 1 or (spec.magazine >= 10 and ammo < spec.magazine * 0.15) then", "\tif ammo < 0 then"),
    ("no rest between bursts", BOT, "ride.nextShotAt = now + (rounds and 1.0 + math.random() * 0.8 or MatchConfig.BotBurstRest + math.random() * 0.35)",
     "ride.nextShotAt = now"),
    ("the arc ignored", BOT, "\tif not VehicleWeapons.InArc(vehicle, targetRoot.Position, mount) then\n\t\treturn\n\tend\n", ""),
    ("the gun seat ignored", VW, 'if child:IsA("Seat") and (child.Name == "GunnerSeat" or child:GetAttribute("Gunner") == true) then',
     "if false then"),
    ("the client gives a lone driver the turret", CLIENT, "\tif seat == gunnerSeatOf(vehicle) then",
     "\tif seat == gunnerSeatOf(vehicle) or seat:IsA(\"VehicleSeat\") then"),
    ("a lone driver works the turret", VW, "if seat == VehicleWeapons.GunnerSeatOf(vehicle) then",
     "if seat == VehicleWeapons.GunnerSeatOf(vehicle) or seat:IsA(\"VehicleSeat\") then"),
]


def main():
    vw_src = read(VW)
    data_src = read("ReplicatedStorage/Shared/VehicleWeaponData.lua")
    bot_src = read(BOT)
    cfg_src = read("ReplicatedStorage/Shared/MatchConfig.lua")
    res = run(vw_src, data_src, bot_src, cfg_src)
    print("DIAL (roof gun, per shot, 4 x 30 s each):")
    for distance, strafe, shots, rate, expect, ratio in res["dial"]:
        print(f"  {distance:4d} studs  strafe {strafe:2d}: {shots:4d} shots, hit rate {rate:.3f}, on-foot dial {expect:.3f}, ratio {ratio:.2f}")
    worst, rows = res["same"]
    print(f"SAME: vehicleHitChance vs shootAt's chance over {rows} cases, worst difference {worst:.2e}")
    for label, value in res["rounds"].items():
        if label != "mortar too near":
            hn, ht, mc, mt = value
            print(f"ROUNDS {label:15}: rolled hits within half a blast {hn}/{ht}, rolled misses clear of the blast {mc}/{mt}")
    print(f"ROUNDS mortar at 60 studs (inside its reach): {res['rounds']['mortar too near']} shots")
    shots, rests, fast, dry, min_ammo = res["bursts"]
    print(f"BURSTS: {shots} shots in 30 s, {rests} rests, {fast} back-to-back, {dry} dry pulls, belt low point {min_ammo:.1f}")
    print(f"ARC: {res['arc']} shots at a target under the rocket pod's front floor")
    print(f"SEATS: {res['seats']}")
    for p in res["problems"]:
        print("PROBLEM", p)

    sources = {BOT: bot_src, VW: vw_src, CLIENT: read(CLIENT)}
    caught = 0
    for label, path, before, after in PLANTS:
        text = sources[path]
        if text.count(before) != 1:
            print(f"  PLANT NOT APPLIED ({label}): text found {text.count(before)} times")
            continue
        planted = dict(sources)
        planted[path] = text.replace(before, after)
        CLIENT_SOURCE[0] = planted[CLIENT]
        try:
            found = run(planted[VW], data_src, planted[BOT], cfg_src)["problems"]
        except Exception as err:  # an error is a failed check, not a pass
            found = [f"error: {str(err).splitlines()[0]}"]
        CLIENT_SOURCE[0] = None
        caught += bool(found)
        print(f"  plant {'CAUGHT' if found else 'MISSED'}: {label} -> {found[0] if found else 'passed'}")
    print(f"planted faults: {caught}/{len(PLANTS)} caught")
    ok = not res["problems"] and caught == len(PLANTS)
    print("bot driving combat: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
