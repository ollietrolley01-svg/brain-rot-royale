#!/usr/bin/env python3
"""Bots driving near enemies: does the REAL tactics layer (BotDriveTactics.lua) drive like a smart player?

Oliver, 2026-09-24: "the bots need to be more strategic about where and how they drive too, especially
when driving near enemies".

Runs, in lupa, three pieces of the game's own source (Luau's compound assignments spelled out):
  * ServerScriptService/Modules/BotDriveTactics.lua whole (Think, Apply, RamFavourable): where a bot
    at the wheel points the car and when it gets out;
  * BotNav.lua's DRIVING section and ReplicatedStorage/Shared/VehicleDynamics.lua, in
    tools/bot_driving_sim.py's world and rigid-body integrator (240 Hz, the forces held between 60 Hz
    frames). Nothing here moves a car but that physics: every run asserts the car covered ground and
    reached speed, so a harness that stopped stepping would fail rather than read "never exposed".
Around them: enemies on foot that shoot the car when they have a line to it (rays against the same
boxes and cars), rocket ambushers that hit in bursts, a manned mounted gun with an arc, a base yard.

Each scenario is run twice: AFTER (the tactics layer, applied as BotService's driverThink applies it)
and BEFORE (the rules driverThink had before it: straight to the goal, orbit only for an armed car
with a gunner, out at 15% health, out where the seat is when a foe is close and the car slow, out on
stuck and back in 20 s later), so the metrics below compare like with like.

  cover      an enemy beside the straight line, a building to one side: go round its reach, behind cover
  ambush     a rocket ambusher (a fifth of the car a hit): turn away and floor it, out before the hit
             that would wreck it
  lowhealth  a damaged car with an enemy ahead: retreat, and out on the far side if it comes to it
  ram        a lone enemy on foot, clear approach, healthy car: roadkill
  ramcross   the same, the enemy walking across the route (the ram is led)
  ramlow     the same with the car at 40%: no ram
  crowd      four enemies together on the route: never into them, no ram
  crowdnear  three enemies together close ahead (in ram reach): still no ram
  crowdgun   an armed car with its gunner and a crowd: circle at range, not among them
  gun        a manned gun whose arc crosses the route: stay out of its field of fire
  broadside  driving up to two enemies (no gun): stop side-on, out on the far side of the car
  stuck      a pocket with the goal beyond its end wall: never loop against it (BEFORE gets out and
             back in and grinds again)
  yard       out of a base yard along its drive-out lane past teammates on foot: no contact

Metrics (BEFORE -> AFTER, summed over the scenarios): seconds exposed (an enemy in range with a line
to the car), deaths in a vehicle, roadkills, seconds stuck.

Planted faults (always run), each aimed at one check: cover routing off, burst bail line off,
ram ignores a crowd, ram ignores health, stuck memory off, evasion off, dismount on the wrong side,
gun arcs ignored, a third sight ray per think. The run fails unless every one is caught.

Usage:  python tools/bot_driving_tactics_check.py [--verbose]
Not modelled: enemies' own movement beyond a walk, a gunner's shots, a real map's clutter (the sim's
boxes), a ram's contact with a body (a body within a stud of the front at 20+ studs/s counts as a
roadkill; tools/roadkill_momentum_* own that contact), and the sweep ignoring the rammed body
(BotService adds it to the sweep filter; here bodies are not in the sweep at all).
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import bot_driving_sim as sim  # noqa: E402

TACTICS = os.path.join(ROOT, "ServerScriptService", "Modules", "BotDriveTactics.lua")

HARNESS = r"""
local T, NAV = ...
local V = Vector3.new
local abs, max, min, sqrt = math.abs, math.max, math.min, math.sqrt

local function flat(v) return V(v.X, 0, v.Z) end

ENEMIES, GUNS = {}, {}
local S = {}  -- the scenario's run

local function eye(p) return V(p.X, 5, p.Z) end

-- A line from `from` to the car (the car itself is not in the way of a shot at it).
local function lineToCar(car, from)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { car.model }
	local to = car.chassis.Position + V(0, 1, 0)
	return workspace:Raycast(eye(from), to - eye(from), params) == nil
end

-- A line from `from` to a point (a detour's cover, for the tactics' sight rays).
local function lineToPoint(from, point)
	local params = RaycastParams.new()
	local to = V(point.X, 3, point.Z)
	return workspace:Raycast(eye(from), to - eye(from), params) == nil
end

function addEnemy(x, z, spec)
	local e = { pos = V(x, 0, z), vel = V(0, 0, 0), alive = true, range = spec.range or 150, dps = spec.dps or 0.03,
		burst = spec.burst, every = spec.every or 2.5, nextBurst = 0, hidden = spec.hidden, known = false, walk = spec.walk }
	table.insert(ENEMIES, e)
	return e
end

function addGun(x, z, facing, arcDegrees, range, dps)
	table.insert(GUNS, { pos = V(x, 0, z), facing = facing.Unit, cosArc = math.cos(math.rad(arcDegrees)), range = range, dps = dps })
end

local function inGunArc(gun, p)
	local to = flat(p) - gun.pos
	local d = to.Magnitude
	return d <= gun.range and (d < 1 or gun.facing:Dot(to / d) >= gun.cosArc)
end

-- The world's tick for the scenario's car: shots, exposure, roadkills, stuck time.
local function worldTick(now, dt)
	local car = S.car
	if not car then return end
	for _, e in ipairs(ENEMIES) do
		if e.alive and e.walk then
			e.vel = e.walk
			e.pos = e.pos + e.walk * dt
		end
	end
	if car.out or car.done then return end
	local ch = car.chassis
	local speed = ch.AssemblyLinearVelocity.Magnitude
	S.moved = max(S.moved, (flat(ch.Position) - S.startPos).Magnitude)
	S.topSpeed = max(S.topSpeed, speed)
	if not car.benchUntil and speed < 2.5 then S.stuckTime = S.stuckTime + dt end
	-- Roadkill: a body inside a stud of the car's box, the car moving at 20+.
	for _, e in ipairs(ENEMIES) do
		if e.alive then
			local rel = ch.CFrame:PointToObjectSpace(V(e.pos.X, ch.Position.Y, e.pos.Z))
			if abs(rel.X) < car.g.sx / 2 + 1 and abs(rel.Z) < car.g.sz / 2 + 1 then
				if speed > 20 then
					e.alive = false
					S.roadkills = S.roadkills + 1
				end
			end
		end
	end
	S.acc = S.acc + dt
	if S.acc < 0.1 then return end
	local step = S.acc
	S.acc = 0
	if car.benchUntil then return end
	local exposed = false
	for _, e in ipairs(ENEMIES) do
		if e.alive and (flat(ch.Position) - e.pos).Magnitude <= e.range and lineToCar(car, e.pos) then
			exposed = true
			if not e.hidden or e.fired then e.known = true end
			if e.burst then
				if now >= e.nextBurst then
					e.nextBurst = now + e.every
					e.fired = true
					e.known = true
					car.health = car.health - e.burst
					S.lastShooter = e.pos
					S.firstHitAt = S.firstHitAt or now
					S.firstHitPos = S.firstHitPos or e.pos
					S.lastBurstAt, S.lastBurst = now, e.burst
				end
			else
				car.health = car.health - e.dps * step
				S.lastShooter = e.pos
			end
		end
	end
	for _, gun in ipairs(GUNS) do
		if inGunArc(gun, ch.Position) and lineToCar(car, gun.pos) then
			exposed = true
			car.health = car.health - gun.dps * step
			S.gunTime = S.gunTime + step
		end
	end
	if exposed then S.exposed = S.exposed + step end
	if car.health <= 0 then
		S.died = true
		car.out = "died"
	end
	if S.firstHitAt and not S.evadeRead and now >= S.firstHitAt + 1.5 then
		S.evadeRead = true
		S.awaySpeed = ch.AssemblyLinearVelocity:Dot((flat(ch.Position) - S.firstHitPos).Unit)
	end
end

-- What the bot knows, as BotService gathers it: enemies within 300 it has seen (or been shot by).
local function context(car, now)
	local ch = car.chassis
	local pos = flat(ch.Position)
	local look = flat(ch.CFrame.LookVector).Unit
	local enemies, target, targetDistance = {}, nil, math.huge
	for _, e in ipairs(ENEMIES) do
		if e.alive and (e.pos - pos).Magnitude < 300 then
			local seen = (not e.hidden or e.fired) and lineToCar(car, e.pos)
			if seen then e.known = true end
			if e.known then
				local row = { pos = e.pos, vel = e.vel, onFoot = true, token = e, seen = seen }
				table.insert(enemies, row)
				local d = (e.pos - pos).Magnitude
				if seen and d < 150 and d < targetDistance then target, targetDistance = row, d end
			end
		end
	end
	local guns = {}
	for _, gun in ipairs(GUNS) do table.insert(guns, gun) end
	S.thinkSights = 0
	return {
		now = now, pos = pos, look = look, speed = ch.AssemblyLinearVelocity.Magnitude, health = car.health,
		halfWidth = car.g.sx / 2, armed = S.armed, gunner = S.gunner, gunKind = "hitscan",
		goal = S.goal, arrive = 22, enemies = enemies, target = target, guns = guns,
		threatPos = S.lastShooter, status = car.lastStatus,
		sight = function(from, to)
			S.thinkSights = S.thinkSights + 1
			S.sights = S.sights + 1
			return lineToPoint(from, to)
		end,
		random = function() return 0.25 end,
	}
end

-- Out on the side of the car that faces an enemy within 150 studs. (The sim's chassis is a 1.8-stud
-- slab, lower than a real body, so which side of the car is judged, not a ray over the slab.)
local function dismountExposed(point)
	local car = flat(S.car.chassis.Position)
	for _, e in ipairs(ENEMIES) do
		if e.alive and (e.pos - car).Magnitude <= 150 and (flat(point) - car):Dot(e.pos - car) > 0 then return true end
	end
	return false
end

local function getOut(car, reason, point, now)
	car.out = reason
	S.leave = reason
	if point then
		S.dismountExposed = dismountExposed(point)
	end
end

-- AFTER: the tactics layer, applied as driverThink applies it.
local function afterPolicy(car, status, now)
	if status == "arrived" then car.done = true; S.reached = true; return end
	if status == "hazard" then getOut(car, "hazard", nil, now); return end
	local ctx = context(car, now)
	local plan = T.Think(S.state, ctx)
	S.maxSights = max(S.maxSights, S.thinkSights)
	S.modes[plan.mode] = (S.modes[plan.mode] or 0) + 1
	if status == "stuck" or status == "lost" then S.stuckEvents = S.stuckEvents + 1 end
	if plan.mode ~= "leave" and S.lastBurstAt and now - S.lastBurstAt < 6 and car.health <= S.lastBurst then
		S.riskyStay = true
	end
	if plan.mode == "leave" then
		S.shun = plan.shun
		getOut(car, plan.leave, plan.dismount, now)
		return
	end
	T.Apply(S.state, car.drive, plan, NAV, S.route)
end

-- BEFORE: driverThink's rules as they stood.
local function beforePolicy(car, status, now)
	if car.benchUntil then
		if now < car.benchUntil then return end
		car.benchUntil = nil
		car.drive.hold = false
		car.drive.stuck.tries = 0
		NAV.DriveTo(car.drive, S.goal, { arrive = 22 })
		S.oldGoal = S.goal
		return
	end
	if status == "arrived" then car.done = true; S.reached = true; return end
	local ctx = context(car, now)
	local ch = car.chassis
	local seatSide = flat(ch.Position) - flat(ch.CFrame.RightVector) * (car.g.sx / 2 + 2.5)
	if car.health < 0.15 then getOut(car, "wrecked", seatSide, now); return end
	if status == "hazard" or status == "flipped" then getOut(car, status, seatSide, now); return end
	if status == "stuck" or status == "lost" then
		S.stuckEvents = S.stuckEvents + 1
		-- Out, and (the same car where it stands) back in REBOARD seconds later.
		car.benchUntil = now + 20
		car.drive.hold = true
		S.benches = S.benches + 1
		return
	end
	local goal, options = S.goal, { arrive = 22 }
	local target = ctx.target
	if target and S.armed and S.gunner then
		local away = (ctx.pos - target.pos).Unit
		if car.health < 0.35 then
			goal, options = target.pos + away * 220, { arrive = 25 }
		else
			local turn = math.rad(35) * (S.oldOrbit or 1)
			local c, s = math.cos(turn), math.sin(turn)
			goal = target.pos + V(away.X * c - away.Z * s, 0, away.Z * c + away.X * s) * 70
			options = { arrive = 8, maxSpeed = 40, loiter = true }
		end
	elseif target and not S.armed and (target.pos - ctx.pos).Magnitude < 45 and ctx.speed < 8 then
		getOut(car, "fight", seatSide, now)
		return
	end
	local moved = S.oldGoal and (S.oldGoal - goal).Magnitude or math.huge
	if moved > (options.loiter and 12 or 40) or S.oldLoiter ~= (options.loiter == true) then
		NAV.DriveTo(car.drive, goal, options)
		S.oldGoal, S.oldLoiter = goal, options.loiter == true
	end
end

local function begin(car, goal, after, opts)
	opts = opts or {}
	S = { car = car, goal = goal, state = T.new(), route = { lane = opts.lane }, modes = {}, exposed = 0, gunTime = 0,
		stuckTime = 0, roadkills = 0, stuckEvents = 0, benches = 0, sights = 0, maxSights = 0, thinkSights = 0,
		moved = 0, topSpeed = 0, acc = 0, startPos = flat(car.chassis.Position), armed = opts.armed, gunner = opts.gunner }
	car.health = opts.health or 1
	makeDrive(car)
	NAV.DriveTo(car.drive, goal, { arrive = 22, via = opts.lane and { opts.lane } or nil })
	S.oldGoal = goal
	return after and afterPolicy or beforePolicy
end

local function finish(out, car)
	out.exposed, out.gunTime, out.stuckTime, out.roadkills = S.exposed, S.gunTime, S.stuckTime, S.roadkills
	out.died, out.reached, out.leave, out.dismountExposed = S.died == true, S.reached == true, S.leave, S.dismountExposed
	out.stuckEvents, out.benches, out.maxSights, out.moved, out.topSpeed = S.stuckEvents, S.benches, S.maxSights, S.moved, S.topSpeed
	out.rams = S.state.rams or 0
	out.evades = S.state.evadeCount or 0
	out.shun = S.shun
	out.riskyStay = S.riskyStay == true
	out.health = car.health
	out.awaySpeed = S.awaySpeed
	local worst, n = 0, 0
	for _, i in ipairs(car.impacts) do if i.speed > 4 then n = n + 1 end worst = max(worst, i.speed) end
	out.impacts = n
	local modes = {}
	for k, v in pairs(S.modes) do table.insert(modes, k .. "=" .. v) end
	table.sort(modes)
	out.modes = table.concat(modes, " ")
	return out
end

-- Scenarios, in the empty flat country east of the sim's roads (x 1000..2200, z -2200..-800).
function tactic(name, modelId, g, after)
	resetWorld()
	ENEMIES, GUNS = {}, {}
	local BOXES_BEFORE = #BOXES
	local out = { name = name, after = after }
	local east = -math.pi / 2
	local ticker = { root = { Position = V(1e5, 0, 1e5), Parent = true }, update = function(now, dt) worldTick(now, dt) end }
	local guards = { ticker }
	local seconds = 45
	local car, policy
	if name == "cover" then
		addBox("Cover", 1300, 0, -1575, 1420, 25, -1545, "Concrete")
		addEnemy(1350, -1440, { dps = 0.03 })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1750, 0, -1500), after)
	elseif name == "ambush" then
		addEnemy(1400, -1590, { burst = 0.2, every = 1.5, range = 160, hidden = true })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1800, 0, -1500), after, { health = 0.55 })
	elseif name == "lowhealth" then
		addEnemy(1250, -1500, { dps = 0.05, range = 170 })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1700, 0, -1500), after, { health = 0.3 })
	elseif name == "ramcross" then
		addEnemy(1150, -1570, { dps = 0.01, walk = V(0, 0, 6) })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1600, 0, -1500), after)
		seconds = 25
	elseif name == "crowdnear" then
		for i, dz in ipairs({ -20, 0, 20 }) do addEnemy(1080 + (i % 2) * 12, -1500 + dz, { dps = 0.02 }) end
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1800, 0, -1500), after)
		seconds = 30
	elseif name == "ram" or name == "ramlow" then
		addEnemy(1080, -1510, { dps = 0.01, walk = V(0, 0, 3) })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1600, 0, -1300), after, { health = name == "ram" and 1 or 0.4 })
		seconds = 25
	elseif name == "crowd" then
		for i, dz in ipairs({ -20, 0, 20, 10 }) do addEnemy(1350 + (i % 2) * 18, -1500 + dz, { dps = 0.03 }) end
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1800, 0, -1500), after)
	elseif name == "crowdgun" then
		for i, dz in ipairs({ -20, 0, 20 }) do addEnemy(1250 + (i % 2) * 18, -1500 + dz, { dps = 0.03 }) end
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1800, 0, -1500), after, { armed = true, gunner = true })
		seconds = 30
	elseif name == "gun" then
		addGun(1350, -1400, V(0, 0, -1), 50, 180, 0.08)
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1750, 0, -1500), after)
	elseif name == "mountedgun" then
		-- A manned stationary gun as BotService hands it over (BotGunner.Threats, set by
		-- tools/mounted_guns_check.py's BOTS section in MOUNTED_GUN): its own facing, arc and range.
		local m = MOUNTED_GUN
		addGun(m.x, m.z, V(m.fx, 0, m.fz), m.arc, m.range, 0.08)
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1750, 0, -1500), after)
	elseif name == "broadside" then
		addEnemy(1180, -1500, { dps = 0.01 })
		addEnemy(1190, -1470, { dps = 0.01 })
		car = makeVehicle(modelId, g, 1000, -1500, east)
		policy = begin(car, V(1185, 0, -1490), after)
		seconds = 20
	elseif name == "stuck" then
		-- A pocket open to the west, the car nose-in, the goal beyond its end wall.
		addBox("PocketN", 1000, 0, -1512, 1060, 10, -1508, "Concrete")
		addBox("PocketS", 1000, 0, -1492, 1060, 10, -1488, "Concrete")
		addBox("PocketE", 1060, 0, -1560, 1064, 10, -1440, "Concrete")
		car = makeVehicle(modelId, g, 1048 - g.sz / 2, -1500, east)
		policy = begin(car, V(1200, 0, -1500), after)
		seconds = 90
	elseif name == "yard" then
		-- A base yard: walls on three sides, the gate east; bays facing the gate; teammates on foot.
		addBox("YardN", 1000, 0, -1540, 1100, 12, -1536, "Concrete")
		addBox("YardS", 1000, 0, -1464, 1100, 12, -1460, "Concrete")
		addBox("YardW", 996, 0, -1540, 1000, 12, -1460, "Concrete")
		addBox("YardParked", 1030, 0, -1525, 1045, 6, -1518, "Metal")
		car = makeVehicle(modelId, g, 1030, -1500, east)
		local mates = {
			{ root = { Position = V(1070, 3, -1480), Parent = true }, hard = true, update = function() end },
			{ root = { Position = V(1085, 3, -1520), Parent = true }, hard = true, update = function() end },
		}
		for _, m in ipairs(mates) do table.insert(guards, m) end
		policy = begin(car, V(1400, 0, -1500), after, { lane = V(1070, 0, -1500) })
		car.drive.guard = { mates[1], mates[2] }
		seconds = 30
	end
	local t, minGuard = runWorld(seconds, policy, guards)
	out.time = t
	out.minGuard = minGuard
	local result = finish(out, car)
	-- The boxes a scenario added go again.
	for i = #BOXES, BOXES_BEFORE + 1, -1 do table.remove(BOXES, i) end
	return result
end
"""

SCENARIOS = ["cover", "ambush", "lowhealth", "ram", "ramcross", "ramlow", "crowd", "crowdnear", "crowdgun", "gun", "broadside", "stuck", "yard"]
MODEL = "TralalaGT"


def load(tactics_src):
    lua, _vd = sim.load(open(sim.DYNAMICS, encoding="utf-8").read(), open(sim.BOTNAV, encoding="utf-8").read())
    tactics = lua.execute(sim.luau_to_lua(tactics_src))
    # The driving section the sim loaded (the same one its scenarios use).
    botnav = open(sim.BOTNAV, encoding="utf-8").read()
    nav = lua.execute(sim.luau_to_lua(sim.driving_source(botnav)))
    lua.execute(HARNESS, tactics, nav)
    return lua


def run(lua, name, after):
    g = sim.geometry(lua, MODEL)
    r = lua.globals().tactic(name, MODEL, g, after)
    out = {k: r[k] for k in r}
    for key in ("leave", "dismountExposed", "shun", "awaySpeed"):
        out.setdefault(key, None)
    return out


# What AFTER must show in each scenario (BEFORE is only measured).
def judge(name, r):
    p = []
    if name != "stuck" and name != "yard" and (r["moved"] < 20 or r["topSpeed"] < 10):
        p.append(f"physics not stepping? moved {r['moved']:.0f} studs, top speed {r['topSpeed']:.1f}")
    if r["maxSights"] > 2:
        p.append(f"{r['maxSights']} sight rays in one think (budget 2)")
    if r["died"]:
        p.append("died in the vehicle")
    if name == "cover":
        if not r["reached"]:
            p.append(f"did not reach the goal (out: {r['leave']})")
        if r["exposed"] > 2.0:
            p.append(f"exposed {r['exposed']:.1f} s going past a known enemy (want <= 2)")
    elif name == "ambush":
        if r["riskyStay"]:
            p.append("stayed in under fire with less health left than the last hit took")
        if r["dismountExposed"]:
            p.append("got out in the shooter's view")
        if r["awaySpeed"] is None or r["awaySpeed"] < 5:
            p.append(f"not turning away from the shooter 1.5 s after the first hit (speed away {r['awaySpeed']})")
    elif name == "lowhealth":
        if r["dismountExposed"]:
            p.append("got out in the shooter's view")
        if r["exposed"] > 4:
            p.append(f"exposed {r['exposed']:.1f} s with a damaged car (want <= 4)")
    elif name in ("ram", "ramcross"):
        if r["roadkills"] < 1:
            p.append("no roadkill on a lone enemy on foot with a clear approach")
    elif name == "ramlow":
        if r["rams"] > 0:
            p.append("rammed with a car at 40%")
    elif name == "crowd":
        if r["rams"] > 0:
            p.append("rammed into a crowd")
        if r["exposed"] > 4:
            p.append(f"exposed {r['exposed']:.1f} s to a crowd (want <= 4)")
        if not r["reached"]:
            p.append(f"did not reach the goal (out: {r['leave']})")
    elif name == "crowdnear":
        if r["rams"] > 0:
            p.append("rammed into a crowd")
    elif name == "crowdgun":
        if r["exposed"] > 20:
            p.append(f"exposed {r['exposed']:.1f} s circling a crowd")
    elif name == "gun":
        if r["gunTime"] > 0.5:
            p.append(f"{r['gunTime']:.1f} s in a manned gun's field of fire")
        if not r["reached"]:
            p.append(f"did not reach the goal (out: {r['leave']})")
    elif name == "broadside":
        if r["leave"] != "fight":
            p.append(f"did not get out to fight (out: {r['leave']})")
        if r["dismountExposed"]:
            p.append("got out on the enemy's side of the car")
    elif name == "stuck":
        if r["stuckEvents"] > 2:
            p.append(f"stuck {r['stuckEvents']} times at one obstacle (a loop)")
        if not r["reached"] and not r["shun"]:
            p.append(f"neither got round nor gave the car up (out: {r['leave']})")
    elif name == "yard":
        if not r["reached"]:
            p.append(f"did not get out of the yard (out: {r['leave']})")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} impacts leaving the yard")
        if r["minGuard"] < 2:
            p.append(f"came within {r['minGuard']:.1f} studs of a teammate")
    return p


PLANTS = [
    ("cover routing off", "local threat = firstThreat(ctx, ctx.pos, goal, crowd)", "local threat = nil", "cover"),
    ("burst bail line off", "bailLine = math.max(bailLine, math.min(T.BURST_CAP, state.bigHit * T.BURST_MARGIN))",
     "bailLine = bailLine", "ambush"),
    ("ram ignores a crowd", "if enemy ~= target then", "if false then", "crowdnear"),
    ("ram ignores health", "if not target or not target.onFoot or ctx.health < T.RAM_HEALTH then",
     "if not target or not target.onFoot then", "ramlow"),
    ("stuck memory off", "if (spot.pos - ctx.pos).Magnitude < T.STUCK_SAME then", "if false then", "stuck"),
    ("evasion off", "T.EVADE_FOR = 2.5", "T.EVADE_FOR = 0", "ambush"),
    ("dismount on the wrong side", "local away = unit(ctx.pos - flat(threat), -ctx.look)",
     "local away = unit(flat(threat) - ctx.pos, ctx.look)", "broadside"),
    ("gun arcs ignored", "if gunCovers(gun, point, T.GUN_MARGIN) and t < bestT then", "if false then", "gun"),
    ("a third sight per think", "\tif ctx.sight then\n",
     "\tif ctx.sight then ctx.sight(threat.eye, first) ctx.sight(threat.eye, first)\n", "cover"),
]


def fmt(r):
    return (f"exposed {r['exposed']:5.1f}s gun {r['gunTime']:4.1f}s stuck {r['stuckTime']:5.1f}s kills {r['roadkills']} "
            f"died {'Y' if r['died'] else '-'} reached {'Y' if r['reached'] else '-'} out {r['leave'] or '-'} "
            f"hp {r['health']:.2f} [{r['modes']}]")


def main():
    verbose = "--verbose" in sys.argv
    src = open(TACTICS, encoding="utf-8").read()
    lua = load(src)
    totals = {"before": dict(exposed=0.0, died=0, kills=0, crowdKills=0, stuck=0.0),
              "after": dict(exposed=0.0, died=0, kills=0, crowdKills=0, stuck=0.0)}
    failures = []
    for name in SCENARIOS:
        for after in (False, True):
            r = run(lua, name, after)
            key = "after" if after else "before"
            t = totals[key]
            t["exposed"] += r["exposed"]
            t["died"] += 1 if r["died"] else 0
            # A roadkill chosen (a lone body on foot) apart from one made driving through a group.
            t["kills" if name in ("ram", "ramcross") else "crowdKills"] += r["roadkills"]
            t["stuck"] += r["stuckTime"]
            if after:
                problems = judge(name, r)
                failures += [f"{name}: {p}" for p in problems]
                print(f"  {name:10s} AFTER  {fmt(r)}" + ("  <-- " + "; ".join(problems) if problems else ""))
            elif verbose:
                print(f"  {name:10s} BEFORE {fmt(r)}")
    b, a = totals["before"], totals["after"]
    print(f"METRICS  exposed {b['exposed']:.1f}s -> {a['exposed']:.1f}s | deaths in vehicle {b['died']} -> {a['died']} | "
          f"roadkills of a lone target {b['kills']} -> {a['kills']} (driving through groups {b['crowdKills']} -> {a['crowdKills']}) | stuck {b['stuck']:.1f}s -> {a['stuck']:.1f}s")

    caught = 0
    for label, old, new, scenario in PLANTS:
        if old not in src:
            failures.append(f"plant '{label}': anchor not found in BotDriveTactics.lua")
            continue
        planted = load(src.replace(old, new, 1))
        r = run(planted, scenario, True)
        problems = judge(scenario, r)
        if problems:
            caught += 1
            if verbose:
                print(f"  plant '{label}' caught by {scenario}: {problems[0]}")
        else:
            failures.append(f"plant '{label}' NOT caught by {scenario} ({fmt(r)})")
    print(f"PLANTS   {caught}/{len(PLANTS)} caught")
    if failures:
        print("FAIL")
        for f in failures:
            print("  " + f)
        return 1
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
