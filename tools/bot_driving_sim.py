#!/usr/bin/env python3
"""Bots at the wheel: does the REAL bot driving controller drive the REAL vehicle physics well?

Runs, in lupa, two pieces of the game's own source, unmodified apart from Luau's compound
assignments being spelled out for stock Lua:
  * ReplicatedStorage/Shared/VehicleDynamics.lua (Rig, Step): the handling every vehicle has;
  * ServerScriptService/Modules/BotNav.lua's DRIVING section (DriveRoute, NewDrive, DriveTo,
    DriveSense, DriveControl): the controller BotService drives with, cut out between its banner and
    `return BotNav`, with BotNav's own flat/flatDistance helpers cut out beside it.
Around them: a world (a terrain height field with a hill road, a river with a bridge, a cliff, and
axis-aligned boxes for buildings, trees, walls and parked cars), workspace:Raycast / Spherecast
against it, and a rigid-body integrator standing in for Roblox physics (240 Hz steps, the forces
Step sets held between 60 Hz frames, as tools/vehicle_stability_sim.py does) that also pushes a
chassis out of any box or other vehicle it runs into, and counts the impacts.

The controller is driven exactly as BotService drives it: DriveControl every frame, DriveSense on
the bot's think (every BotThinkInterval, 0.25 s), with BotService's reactions to what DriveSense
reports (plan again on the roads after a hazard, get out on stuck/lost/flipped/hazard).

Scenarios (each car model unless noted):
  lap        a road network (four curved bends, a tee and a spur, a hill with an 18% grade, a bridge
             over the river, a stalled car in the lane, parked cars and trees on the verges): drive a
             lap of five goals. Measures laps completed, impacts, time off the tarmac on road legs.
  field      straight across country through trees and round a building (no roads).
  river      a goal across the river with no road: must stop on the bank and never enter the water.
  bridge     the same goal with the roads: plans onto them after the hazard and crosses the bridge.
  cliff      a goal beyond a 20-stud drop: must stop short of the edge.
  pocket     starts nose-in to a dead-end pocket with the goal behind its end wall: must back out
             (stuck recovery) and get round. `boxed` is a pocket with no way out: must give the vehicle
             up ("stuck") rather than grind forever.
  teammates  teammates on foot crossing and standing in the lane: closest approach kept.
  meet       two bots meeting head-on along one road: both keep right and pass without touching.
  bike       a lap on the BrrStreetfighter, with the bike balance of tools/bike_balance_sim.py.

Planted faults (always run, each aimed at an invariant): steering sign, obstacle sweep ignored,
water not seen, drop not seen, no reverse recovery, teammates not guarded, no corner speed,
an extra query per look (the budget), the lane on the wrong side, the sweep lifted over bumper
height (a solid part at bumper height is always seen), every face met taken as beside the way (a
wall across the road is always seen), sweeps stopped by what nothing collides with (a solid part is
seen whatever stands in front of it). The run fails unless every one is caught by the check aimed at it.

Usage:  python3 tools/bot_driving_sim.py [--verbose] [--quick]
Exit 0 when the real source passes every scenario and every planted fault is caught.

Not modelled (say so): Roblox's own solver and friction (contacts here are springs), terrain as
voxels (it is a smooth height field; the wheel rays' behaviour on real voxels is what
vehicle_stability_sim covers), network ownership (a bot's vehicle is server-owned, as here),
pathfinding for the walk to the car, and the real map's road network (RoadNetwork's node/edge/curve
shape is reproduced, not its planner).
"""
import argparse
import math
import os
import re
import sys
import time

from lupa import lua54

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import vehicle_stability_sim as cars  # noqa: E402  (its Vector3/CFrame mocks and car geometry)
import bike_balance_sim as bikes  # noqa: E402  (bike geometry)

DYNAMICS = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleDynamics.lua")
BOTNAV = os.path.join(ROOT, "ServerScriptService", "Modules", "BotNav.lua")

DRIVE_START = "--------------------------------------------------------------------------------\n-- DRIVING (bot drivers)"


def luau_to_lua(src):
    return cars.luau_to_lua(src)


def driving_source(botnav):
    helpers = botnav[botnav.index("local function flat(v)"):botnav.index("--------------------------------------------------------------------------------\n-- Per-bot state")]
    section = botnav[botnav.index(DRIVE_START):botnav.rindex("return BotNav")]
    # BotService's ray budget, as BotNav is handed it: uncapped until BUDGET_OFF_AT (the "blind" run),
    # then spent for good.
    budget = (
        "function BotNav.CastRemaining() if BUDGET_OFF_AT and SIM_NOW and SIM_NOW >= BUDGET_OFF_AT then return 0 end return math.huge end\n"
        "function BotNav.CastSpend() return BotNav.CastRemaining() > 0 end\n"
        "function BotNav.CastRay(o, d, p) if BotNav.CastRemaining() <= 0 then return nil, false end return workspace:Raycast(o, d, p), true end\n"
    )
    return "local BotNav = {}\n" + budget + helpers + "\n" + section + "\nreturn BotNav\n"


WORLD = r"""
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local V = Vector3.new
local abs, floor, sqrt, max, min = math.abs, math.floor, math.sqrt, math.max, math.min

local function inst(name, props)
	local p = { __instance = true, Name = name, Anchored = true, CanCollide = true, Transparency = 0, Size = V(4, 4, 4) }
	for k, v in pairs(props or {}) do p[k] = v end
	p.IsA = function(self, class)
		if class == "Terrain" then return self.terrain == true end
		return class == "BasePart"
	end
	p.FindFirstAncestorOfClass = function() return nil end
	return p
end
TERRAIN = inst("Terrain", { terrain = true })
ROADPART = inst("Road", { CanCollide = false, Size = V(18, 0.4, 18), Material = "Asphalt" })

-- The height field: flat at 0, a hill the east road climbs, a plateau with a cliff, a river channel.
HILL = { x0 = 440, x1 = 560, z0 = 60, z1 = 340, top = 25 }
PLATEAU = { x0 = -420, x1 = -80, z0 = -300, z1 = 300, top = 20 }
RIVER = { x = 250, half = 14, z0 = 300, z1 = 1200, bed = -8, level = -1 }
BOXES = {}
BALLS = {}      -- rounded props (a rock, a bush, a pebble): { c = centre, r = radius, part }
ROADSEGS = {}   -- centre-line pieces { ax, az, bx, bz }
WATERON = true
-- A real bridge on the south road (scenario "crossing"): nil, or { x0, x1 (the deck's ends), z (the centre
-- line), half (the deck's half-width), grade, base (the road's ground at the span's middle) }. The road's
-- ground is a straight line across the deck and RUN either side (RoadNetwork's BRIDGE_RUN), easing back
-- to the plain at the same grade; the deck carries it over the river.
REALBRIDGE = nil
-- A slope for the prop course (scenario "props"): nil, or { x0, x1, z, half, grade, across }. Along x
-- (`across` false) the ground climbs `grade` from x0 to x1 and stays up, fading out over 20 studs past
-- `half` either side of z. Across (true) it is a bank between x0 and x1: level ground `half` either
-- side of z, the far side higher by `grade` all the way across.
RAMP = nil

function rampHeight(x, z)
	local R = RAMP
	if R.across then
		local ends = 1 - math.max(0, math.min(1, math.max(R.x0 - x, x - R.x1) / 20))
		return R.grade * (math.max(-R.half, math.min(R.half, R.z - z)) + R.half) * ends
	end
	local side = 1 - math.max(0, math.min(1, (math.abs(z - R.z) - R.half) / 20))
	return R.grade * (math.max(R.x0, math.min(R.x1, x)) - R.x0) * side
end

local function smooth(t) t = math.max(0, math.min(1, t)); return t * t * (3 - 2 * t) end

function bridgeRoad(x)
	local B = REALBRIDGE
	local mid = (B.x0 + B.x1) / 2
	local w, e = B.x0 - B.run, B.x1 + B.run
	local function line(at) return B.base + B.grade * (at - mid) end
	if x < w then return math.max(0, line(w) - 0.05 * (w - x)) end
	if x > e then return math.max(0, line(e) - 0.05 * (x - e)) end
	return line(x)
end

function terrainHeight(x, z)
	local B = REALBRIDGE
	if B and x >= B.x0 and x <= B.x1 and abs(z - B.z) <= B.half then
		return bridgeRoad(x)
	end
	local h = 0
	if B then
		h = bridgeRoad(x) * (1 - smooth((abs(z - B.z) - 13) / 20))
	end
	if RAMP then
		h = h + rampHeight(x, z)
	end
	if x >= HILL.x0 and x <= HILL.x1 then
		local t
		if z < 200 then t = (z - HILL.z0) / (200 - HILL.z0) else t = (HILL.z1 - z) / (HILL.z1 - 200) end
		h = h + HILL.top * math.max(0, math.min(1, t))
	end
	if x >= PLATEAU.x0 and x <= PLATEAU.x1 and z >= PLATEAU.z0 and z <= PLATEAU.z1 then
		-- A cliff: the last stud falls the whole height.
		h = h + PLATEAU.top * math.min(1, (PLATEAU.x1 - x))
	end
	if WATERON and z >= RIVER.z0 and z <= RIVER.z1 then
		local d = abs(x - RIVER.x)
		if d < RIVER.half + 6 then
			h = h + RIVER.bed * (1 - smooth((d - RIVER.half + 6) / 12))
		end
	end
	return h
end

local function roadDistance(x, z)
	local best = math.huge
	for _, s in ipairs(ROADSEGS) do
		local dx, dz = s[3] - s[1], s[4] - s[2]
		local l2 = dx * dx + dz * dz
		local t = l2 > 0 and math.max(0, math.min(1, ((x - s[1]) * dx + (z - s[2]) * dz) / l2)) or 0
		local px, pz = s[1] + dx * t - x, s[2] + dz * t - z
		local d = sqrt(px * px + pz * pz)
		if d < best then best = d end
	end
	return best
end
ROAD_HALF = 9
function onRoad(x, z) return roadDistance(x, z) <= ROAD_HALF end
ROAD_DISTANCE = roadDistance

local function terrainNormal(x, z)
	local e = 0.5
	local dx = (terrainHeight(x + e, z) - terrainHeight(x - e, z)) / (2 * e)
	local dz = (terrainHeight(x, z + e) - terrainHeight(x, z - e)) / (2 * e)
	return V(-dx, 1, -dz).Unit
end

local function excluded(part, params)
	if params and params.RespectCanCollide and part.CanCollide == false then return true end
	if not params or not params.FilterDescendantsInstances then return false end
	for _, x in ipairs(params.FilterDescendantsInstances) do
		if part == x or (part.model and part.model == x) then return true end
	end
	return false
end

-- Slab test of a ray against an axis-aligned box grown by `grow`; returns t in [0,1] and the face normal.
local function slab(o, d, bmin, bmax, grow)
	local tmin, tmax, normal = 0, 1, nil
	if type(grow) == "number" then grow = V(grow, grow, grow) end
	local axes = { { o.X, d.X, bmin.X - grow.X, bmax.X + grow.X, V(1, 0, 0) }, { o.Y, d.Y, bmin.Y - grow.Y, bmax.Y + grow.Y, V(0, 1, 0) },
		{ o.Z, d.Z, bmin.Z - grow.Z, bmax.Z + grow.Z, V(0, 0, 1) } }
	for _, a in ipairs(axes) do
		local oo, dd, lo, hi, axis = a[1], a[2], a[3], a[4], a[5]
		if abs(dd) < 1e-9 then
			if oo < lo or oo > hi then return nil end
		else
			local t1, t2 = (lo - oo) / dd, (hi - oo) / dd
			local enter, leave = math.min(t1, t2), math.max(t1, t2)
			if enter > tmin then
				tmin = enter
				normal = dd > 0 and axis * -1 or axis
			end
			if leave < tmax then tmax = leave end
			if tmin > tmax then return nil end
		end
	end
	if not normal then return nil end   -- started inside: a Roblox cast reports nothing there
	return tmin, normal
end

-- A ray (or a swept sphere, with `radius`) against another vehicle's box, in its own frame.
local function obbHit(o, d, car, grow)
	local c = car.chassis.CFrame
	local lo = c:PointToObjectSpace(o)
	local ld = c:VectorToObjectSpace(d)
	local s = car.chassis.Size
	local t, n = slab(lo, ld, V(-s.X / 2, -s.Y / 2, -s.Z / 2), V(s.X / 2, s.Y / 2, s.Z / 2), grow)
	if not t then return nil end
	return t, c:VectorToWorldSpace(n)
end

-- The cast's shape (a point, or a box of half extents `grow`) against a ball: the first t where the
-- ball's centre comes within its radius of the shape, marched then bisected, and the ball's surface
-- normal where they meet (from its centre toward the nearest point of the shape), as a Roblox cast
-- that meets a Ball part reports it. Started inside: nothing, as with a box.
local function ballGap(p, ball, grow)
	local d = ball.c - p
	local q = V(math.max(-grow.X, math.min(grow.X, d.X)), math.max(-grow.Y, math.min(grow.Y, d.Y)), math.max(-grow.Z, math.min(grow.Z, d.Z)))
	return (d - q).Magnitude - ball.r, p + q
end
function ballHit(o, dir, ball, grow)
	local len = dir.Magnitude
	-- Out of reach of the whole cast: skip the march.
	local mid = o + dir * 0.5
	if (ball.c - mid).Magnitude > len / 2 + ball.r + grow.Magnitude + 0.5 then return nil end
	if ballGap(o, ball, grow) <= 0 then return nil end
	local steps = math.max(8, math.ceil(len / 0.2))
	local prev = 0
	for i = 1, steps do
		local t = i / steps
		if ballGap(o + dir * t, ball, grow) <= 0 then
			local a, b = prev, t
			for _ = 1, 10 do
				local m = (a + b) / 2
				if ballGap(o + dir * m, ball, grow) <= 0 then b = m else a = m end
			end
			local _, near = ballGap(o + dir * b, ball, grow)
			local n = near - ball.c
			return b, n.Magnitude > 1e-6 and n.Unit or V(0, 1, 0)
		end
		prev = t
	end
	return nil
end

CARS = {}
RAYCASTS = 0

local function castWorld(origin, direction, params, radius, box, obb)
	RAYCASTS = RAYCASTS + 1
	local grow = box or V(radius or 0, radius or 0, radius or 0)
	local growMax = math.max(grow.X, grow.Z)
	local len = direction.Magnitude
	if len < 1e-6 then return nil end
	local best = nil
	local function offer(t, part, normal, material)
		if not best or t < best.t then best = { t = t, part = part, normal = normal, material = material } end
	end
	for _, box in ipairs(BOXES) do
		if not excluded(box.part, params) then
			local t, n = slab(origin, direction, box.min, box.max, grow)
			if t then offer(t, box.part, n, box.part.Material or "Concrete") end
		end
	end
	for _, car in ipairs(CARS) do
		if not excluded(car.model, params) then
			local t, n = obbHit(origin, direction, car, growMax)
			if t then offer(t, car.chassis, n, "Metal") end
		end
	end
	for _, ball in ipairs(BALLS) do
		if not excluded(ball.part, params) then
			local t, n = ballHit(origin, direction, ball, grow)
			if t then offer(t, ball.part, n, ball.part.Material) end
		end
	end
	-- Terrain: march, then bisect.
	local step = math.max(0.25, math.min(1.0, len / 12))
	local steps = math.ceil(len / step)
	local prevT = 0
	-- A turned box meets the ground where a corner of its underside does (`obb`: its half axes); a
	-- point or a ball, straight below it.
	local function below(t)
		local p = origin + direction * t
		if obb then
			for _, sx in ipairs({ -1, 1 }) do
				for _, sz in ipairs({ -1, 1 }) do
					local c = p - obb.u + obb.r * sx + obb.l * sz
					if c.Y <= terrainHeight(c.X, c.Z) then return true, c end
				end
			end
			return false
		end
		return p.Y - grow.Y <= terrainHeight(p.X, p.Z), p
	end
	if not below(0) then
		for i = 1, steps do
			local t = math.min(1, i / steps)
			if best and t > best.t then break end
			if below(t) then
				local a, b = prevT, t
				for _ = 1, 8 do
					local m = (a + b) / 2
					if below(m) then b = m else a = m end
				end
				local _, p = below(b)
				p = p or origin + direction * b
				local material = onRoad(p.X, p.Z) and "Asphalt" or "Grass"
				local part = TERRAIN
				if material == "Asphalt" and not radius and not box and not (params and params.RespectCanCollide) then part = ROADPART end
				offer(b, part, terrainNormal(p.X, p.Z), material)
				break
			end
			prevT = t
		end
	end
	-- Water: the surface of the river, for a query that does not ignore it.
	if WATERON and params and params.IgnoreWater == false and abs(direction.Y) > 1e-6 then
		local t = (RIVER.level + grow.Y - origin.Y) / direction.Y
		if t >= 0 and t <= 1 then
			local p = origin + direction * t
			if p.Z >= RIVER.z0 and p.Z <= RIVER.z1 and abs(p.X - RIVER.x) < RIVER.half + 6
				and terrainHeight(p.X, p.Z) < RIVER.level then
				-- A bridge deck over it is a box, and offered above.
				offer(t, TERRAIN, V(0, 1, 0), "Water")
			end
		end
	end
	if not best then return nil end
	local position = origin + direction * best.t
	return { Instance = best.part, Position = position, Normal = best.normal, Distance = best.t * len, Material = best.material }
end

workspace = { Gravity = 196.2 }
function workspace:Raycast(origin, direction, params) return castWorld(origin, direction, params, nil) end
function workspace:Spherecast(origin, radius, direction, params) return castWorld(origin, direction, params, radius) end
-- A turned box (a vehicle's sweep, tilted with the chassis): its half extents on the world axes.
function workspace:Blockcast(cf, size, direction, params)
	local look, right, up = cf.LookVector, cf.RightVector, cf.UpVector
	local hx = abs(right.X) * size.X / 2 + abs(up.X) * size.Y / 2 + abs(look.X) * size.Z / 2
	local hy = abs(right.Y) * size.X / 2 + abs(up.Y) * size.Y / 2 + abs(look.Y) * size.Z / 2
	local hz = abs(right.Z) * size.X / 2 + abs(up.Z) * size.Y / 2 + abs(look.Z) * size.Z / 2
	return castWorld(cf.Position, direction, params, nil, V(hx, hy, hz), { r = right * (size.X / 2), u = up * (size.Y / 2), l = look * (size.Z / 2) })
end
-- CFrame.lookAt with Roblox's optional up vector (the stability sim's takes the world's).
local lookAtLevel = CFrame.lookAt
CFrame.lookAt = function(at, target, up)
	if not up then return lookAtLevel(at, target) end
	local look = (target - at).Unit
	local x = look:Cross(up).Unit
	return CFrame.fromMatrix(at, x, x:Cross(look), -look)
end
RaycastParams = { new = function() return { FilterDescendantsInstances = {}, IgnoreWater = false } end }

function addBox(name, x0, y0, z0, x1, y1, z1, material)
	local part = inst(name, { Material = material or "Concrete", Size = V(x1 - x0, y1 - y0, z1 - z0),
		Position = V((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2) })
	table.insert(BOXES, { min = V(x0, y0, z0), max = V(x1, y1, z1), part = part, name = name })
	return part
end

-- A Ball part (Roblox makes a ball round whatever its size says: the smallest side is its diameter).
function addBall(name, cx, cy, cz, r, material)
	local part = inst(name, { Material = material or "Rock", Size = V(r * 2, r * 2, r * 2), Position = V(cx, cy, cz), Shape = "Ball" })
	table.insert(BALLS, { c = V(cx, cy, cz), r = r, part = part, name = name })
	return part
end

-- The real bridge (MapDecor.Bridge's sizes) on the south road: the deck is the height field (above),
-- the parapets (1 wide, 3 tall, the inner face `half` - 1 from the centre line) and the four lamp posts
-- (0.5 square, from the coping's top 3.35 over the deck to 7.85, at each end of each parapet, on its
-- line) are boxes, the parapets in 2-stud steps up the grade. The coping and the lamps are clutter
-- (nothing collides with them or casts meet them) and aren't built. The old flat box goes.
function buildRealBridge(B)
	REALBRIDGE = B
	for i = #BOXES, 1, -1 do
		if BOXES[i].name == "Bridge" then table.remove(BOXES, i) end
	end
	for _, side in ipairs({ -1, 1 }) do
		local z = B.z + side * (B.half - 0.5)
		local x = B.x0
		while x < B.x1 - 1e-6 do
			local x2 = math.min(B.x1, x + 2)
			local y = bridgeRoad((x + x2) / 2)
			addBox("BridgeParapet", x, y - 0.5, z - 0.5, x2, y + 3, z + 0.5, "Cobblestone")
			x = x2
		end
		for _, px in ipairs({ B.x0 + 2, B.x1 - 2 }) do
			local y = bridgeRoad(px)
			addBox("BridgeLampPost", px - 0.25, y + 3.35, z - 0.25, px + 0.25, y + 7.85, z + 0.25, "Metal")
		end
	end
end
"""

SIM = r"""
local VD, NAV = ...
local V = Vector3.new
local abs, sqrt, max, min = math.abs, math.sqrt, math.max, math.min

local function orthonormal(c)
	local y = c.y.Unit
	local x = y:Cross(c.z).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(c.p, x, y, z)
end

-- A car or a bike, built the way the stability and balance sims build them.
function makeVehicle(modelId, g, x, z, yaw)
	local chassis = { __instance = true, Name = "Chassis", Size = V(g.sx, g.sy, g.sz), children = {}, CanCollide = true, Anchored = false }
	chassis.FindFirstChild = function(self, name) return self.children[name] end
	chassis.IsA = function(_, c) return c == "BasePart" end
	chassis.FindFirstAncestorOfClass = function() return nil end
	local model = { __instance = true, PrimaryPart = chassis, Name = modelId }
	chassis.model = model
	chassis.Parent = model
	model.GetAttribute = function(_, k) if k == "VehicleModel" then return modelId end end
	local hubs = {}
	local wheels
	if g.bike then
		wheels = { { "Wheel_F", 0, g.fz, true, g.fr }, { "Wheel_R", 0, g.rz, false, g.rr } }
	else
		wheels = { { "WheelFL", -1, g.fz, true, g.r }, { "WheelFR", 1, g.fz, true, g.r }, { "WheelRL", -1, g.rz, false, g.r }, { "WheelRR", 1, g.rz, false, g.r } }
	end
	for _, spec in ipairs(wheels) do
		local mount = V(spec[2] * (g.track or 0), spec[5] - g.cy, spec[3] - (g.cz or 0))
		local joint = { C0 = CFrame.new(mount), C1 = CFrame.identity, Part0 = chassis }
		local hub = { __instance = true, Name = spec[1], attrs = { Radius = spec[5], Front = spec[4], Steer = spec[4] } }
		hub.IsA = function(_, c) return c == "BasePart" end
		hub.GetAttribute = function(self, k) return self.attrs[k] end
		hub.FindFirstChild = function(_, n) if n == "Joint" then return joint end end
		table.insert(hubs, hub)
	end
	model.GetChildren = function() return hubs end
	model.FindFirstChild = function(_, n) if n == "Chassis" then return chassis end end
	chassis.AssemblyMass = g.sx * g.sy * g.sz * (g.rho or 1.3)
	local h0 = terrainHeight(x, z)
	chassis.CFrame = CFrame.new(x, h0 + g.cy, z) * CFrame.Angles(0, yaw, 0)
	chassis.Position = chassis.CFrame.Position
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	chassis.GetVelocityAtPosition = function(self, p)
		return self.AssemblyLinearVelocity + self.AssemblyAngularVelocity:Cross(p - self.Position)
	end
	local rig = assert(VD.Rig(model), "Rig returned nil")
	local car = { model = model, chassis = chassis, rig = rig, g = g, contacts = {}, impacts = {}, inWater = false, fell = false,
		minUp = 1, offRoadTime = 0, roadTime = 0, maxOff = 0, startY = h0, lateral = {} }
	table.insert(CARS, car)
	return car
end

-- The engine's side of a bike's Balance AlignOrientation (as tools/bike_balance_sim.py models it).
local function balanceTorque(rig, c, w, I)
	local b = rig.balance
	if not b or b.Enabled == false or not b.Attachment0 then return Vector3.zero end
	local attach = b.Attachment0.CFrame
	local axis = c:VectorToWorldSpace(attach and attach.x or V(0, 1, 0))
	local goal = b.CFrame.x
	local turn = axis:Cross(goal)
	local s = turn.Magnitude
	local angle = math.atan2(s, axis:Dot(goal))
	local wanted = Vector3.zero
	if s > 1e-6 then wanted = turn.Unit * math.min(angle * b.Responsiveness, b.MaxAngularVelocity) end
	local free = axis * w:Dot(axis)
	local wPerp = w - free
	local alpha = c:VectorToObjectSpace((wanted - wPerp) * b.Responsiveness)
	local torque = c:VectorToWorldSpace(alpha * I)
	if torque.Magnitude > b.MaxTorque then torque = torque.Unit * b.MaxTorque end
	return torque
end

-- Corner points of a vehicle's collider, for the ground, boxes and other vehicles.
local function hullPoints(g)
	local pts = {}
	for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 0, 1 }) do
		table.insert(pts, V(sx * g.sx / 2, sy * g.sy / 2, sz * g.sz / 2))
	end end end
	return pts
end

-- One 1/240 s physics step for every vehicle.
local PHYS = 1 / 240
local function physics(now)
	local forces = {}
	for _, car in ipairs(CARS) do
		local ch = car.chassis
		local mass = ch.AssemblyMass
		local c = ch.CFrame
		local p = ch.Position
		local F = V(0, -workspace.Gravity * mass, 0) + car.rig.downforce.Force
		local T = car.rig.torque.Torque
		for _, wheel in ipairs(car.rig.wheels) do
			local at = c:PointToWorldSpace(wheel.mount)
			F = F + wheel.force.Force
			T = T + (at - p):Cross(wheel.force.Force)
		end
		forces[car] = { F = F, T = T }
	end
	for _, car in ipairs(CARS) do
		local ch = car.chassis
		local g = car.g
		local mass = ch.AssemblyMass
		local c = ch.CFrame
		local p, v, w = ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity
		local F, T = forces[car].F, forces[car].T
		local pts = car.pts or hullPoints(g)
		car.pts = pts
		local touching = {}
		for _, lp in ipairs(pts) do
			local at = c:PointToWorldSpace(lp)
			local pv = v + w:Cross(at - p)
			-- Ground.
			local gy = terrainHeight(at.X, at.Z)
			if at.Y < gy then
				local n = V(0, 1, 0)
				local push = max(0, mass * (2000 * (gy - at.Y) - 120 * pv.Y) / #pts)
				local fr = V(pv.X, 0, pv.Z) * (-mass * 4 / #pts)
				F = F + n * push + fr
				T = T + (at - p):Cross(n * push + fr)
			end
			-- Boxes: out along the shallowest side face (or up, onto a low box).
			for bi, box in ipairs(BOXES) do
				local mn, mx = box.min, box.max
				if box.part.CanCollide ~= false and at.X > mn.X and at.X < mx.X and at.Y > mn.Y and at.Y < mx.Y and at.Z > mn.Z and at.Z < mx.Z then
					local cands = { { at.X - mn.X, V(-1, 0, 0) }, { mx.X - at.X, V(1, 0, 0) }, { at.Z - mn.Z, V(0, 0, -1) },
						{ mx.Z - at.Z, V(0, 0, 1) }, { mx.Y - at.Y, V(0, 1, 0) } }
					table.sort(cands, function(a, b) return a[1] < b[1] end)
					local depth, n = cands[1][1], cands[1][2]
					local vn = pv:Dot(n)
					local push = max(0, mass * (3000 * depth - 150 * vn) / #pts)
					F = F + n * push
					T = T + (at - p):Cross(n * push)
					touching["b" .. bi] = max(touching["b" .. bi] or 0, -vn)
				end
			end
			-- Other vehicles: this point inside another's box.
			for _, other in ipairs(CARS) do
				if other ~= car then
					local oc = other.chassis.CFrame
					local rel = oc:PointToObjectSpace(at)
					local s = other.chassis.Size
					if abs(rel.X) < s.X / 2 and abs(rel.Y) < s.Y / 2 and abs(rel.Z) < s.Z / 2 then
						local dx, dz = s.X / 2 - abs(rel.X), s.Z / 2 - abs(rel.Z)
						local nl = dx < dz and V(rel.X > 0 and 1 or -1, 0, 0) or V(0, 0, rel.Z > 0 and 1 or -1)
						local n = oc:VectorToWorldSpace(nl)
						local depth = min(dx, dz)
						local ov = other.chassis:GetVelocityAtPosition(at)
						local vn = (pv - ov):Dot(n)
						local push = max(0, mass * (3000 * depth - 150 * vn) / #pts)
						F = F + n * push
						T = T + (at - p):Cross(n * push)
						local of = forces[other]
						of.F = of.F - n * push
						of.T = of.T + (at - other.chassis.Position):Cross(n * -push)
						touching["car" .. tostring(other.model.Name) .. tostring(other)] = max(touching["car" .. tostring(other.model.Name) .. tostring(other)] or 0, -vn)
					end
				end
			end
		end
		-- A box no hull point is inside (a post thinner than the gap between them): the chassis's footprint
		-- against the box's, seen from above, out along whichever axis (the box's or the car's) is shallowest,
		-- where they overlap in height.
		local right = V(c.RightVector.X, 0, c.RightVector.Z).Unit
		local fwd = V(c.LookVector.X, 0, c.LookVector.Z).Unit
		local hx, hz = g.sx / 2, g.sz / 2
		local flatP = V(p.X, 0, p.Z)
		for bi, box in ipairs(BOXES) do
			local mn, mx = box.min, box.max
			if box.part.CanCollide ~= false and not touching["b" .. bi] and p.Y - g.sy / 2 < mx.Y and p.Y + g.sy / 2 > mn.Y then
				local bc = V((mn.X + mx.X) / 2, 0, (mn.Z + mx.Z) / 2)
				local bx, bz = (mx.X - mn.X) / 2, (mx.Z - mn.Z) / 2
				if (bc - flatP).Magnitude < sqrt(bx * bx + bz * bz) + sqrt(hx * hx + hz * hz) then
					local depth, n = math.huge, nil
					for _, axis in ipairs({ V(1, 0, 0), V(0, 0, 1), right, fwd }) do
						local d = (flatP - bc):Dot(axis)
						local overlap = hx * abs(right:Dot(axis)) + hz * abs(fwd:Dot(axis)) + bx * abs(axis.X) + bz * abs(axis.Z) - abs(d)
						if overlap <= 0 then depth = nil; break end
						if overlap < depth then depth, n = overlap, d >= 0 and axis or axis * -1 end
					end
					if depth then
						local at = V(max(mn.X, min(mx.X, p.X)), p.Y, max(mn.Z, min(mx.Z, p.Z)))
						local pv = v + w:Cross(at - p)
						local vn = pv:Dot(n)
						local push = max(0, mass * (3000 * depth - 150 * vn) / 4)
						F = F + n * push
						T = T + (at - p):Cross(n * push)
						touching["b" .. bi] = max(touching["b" .. bi] or 0, -vn)
					end
				end
			end
		end
		-- Balls: the chassis box's nearest point to the ball's centre, pushed out along the ball's normal.
		for bi, ball in ipairs(BALLS) do
			if (ball.c - p).Magnitude < ball.r + g.sz then
				local s = ch.Size
				local lc = c:PointToObjectSpace(ball.c)
				local cl = V(max(-s.X / 2, min(s.X / 2, lc.X)), max(-s.Y / 2, min(s.Y / 2, lc.Y)), max(-s.Z / 2, min(s.Z / 2, lc.Z)))
				local d = (cl - lc).Magnitude
				if d < ball.r and d > 1e-6 then
					local at = c:PointToWorldSpace(cl)
					local n = (at - ball.c).Unit
					local pv = v + w:Cross(at - p)
					local vn = pv:Dot(n)
					local push = max(0, mass * (3000 * (ball.r - d) - 150 * vn) / 4)
					F = F + n * push
					T = T + (at - p):Cross(n * push)
					touching["ball" .. bi] = max(touching["ball" .. bi] or 0, -vn)
				end
			end
		end
		-- Impacts: a contact that begins with any real closing speed.
		for key, speed in pairs(touching) do
			if not car.contacts[key] and speed > 2 then
				table.insert(car.impacts, { key = key, speed = speed, at = now })
				if TRACE and car == CARS[1] then table.insert(TRACE, string.format("  IMPACT t%.2f %s %.1f", now, key, speed)) end
			end
			-- Every contact that starts, at any speed, by what it was with (a scrape along a parapet counts).
			if not car.contacts[key] then
				local name = key
				if key:sub(1, 4) == "ball" then name = BALLS[tonumber(key:sub(5))].name
				elseif key:sub(1, 1) == "b" then name = BOXES[tonumber(key:sub(2))].name end
				car.touches = car.touches or {}
				table.insert(car.touches, { name = name, speed = speed, at = now })
			end
		end
		car.contacts = touching
		forces[car].F, forces[car].T = F, T
	end
	for _, car in ipairs(CARS) do
		local ch = car.chassis
		local mass = ch.AssemblyMass
		local I = car.rig.inertiaShape * mass
		local c = ch.CFrame
		local p, v, w = ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity
		local F, T = forces[car].F, forces[car].T
		if car.rig.bike then T = T + balanceTorque(car.rig, c, w, I) end
		v = v + F * (PHYS / mass)
		local wb = c:VectorToObjectSpace(w)
		local tb = c:VectorToObjectSpace(T)
		local Iw = wb * I
		local dw = (tb - wb:Cross(Iw)) * V(1 / I.X, 1 / I.Y, 1 / I.Z)
		wb = wb + dw * PHYS
		w = c:VectorToWorldSpace(wb)
		local nc = c
		if w.Magnitude > 1e-9 then
			local rot = CFrame.fromAxisAngle(w, w.Magnitude * PHYS)
			nc = CFrame.fromMatrix(Vector3.zero, rot:VectorToWorldSpace(c.x), rot:VectorToWorldSpace(c.y), rot:VectorToWorldSpace(c.z))
		end
		nc = orthonormal(CFrame.fromMatrix(p + v * PHYS, nc.x, nc.y, nc.z))
		ch.CFrame, ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity = nc, nc.p, v, w
	end
end

-- A bot's drive, set up as BotService sets one up.
function makeDrive(car)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { car.model }
	params.IgnoreWater = true
	local probe = RaycastParams.new()
	probe.FilterDescendantsInstances = { car.model }
	probe.IgnoreWater = false
	local drive = NAV.NewDrive(car.chassis, car.rig.handling, { wheelbase = car.rig.wheelbase, params = params, probeParams = probe,
		rideHeight = car.g.cy })
	car.drive = drive
	return drive
end

-- Runs every vehicle for `seconds`. `plan(car, status, now)` is BotService's reaction to a look.
-- `guards` = list of { root = { Position, Parent }, hard = bool, update = function(now, dt) }.
function runWorld(seconds, plan, guards)
	local frame = 1 / 60
	local now = 0
	local nextSense = {}
	for i, car in ipairs(CARS) do nextSense[car] = 0.05 * i end
	local minGuard = math.huge
	local guardHits = 0
	-- Each bot's traffic, as BotService hands it over: every other vehicle's chassis.
	for _, car in ipairs(CARS) do
		if car.drive then
			car.drive.traffic = {}
			for _, other in ipairs(CARS) do
				if other ~= car then table.insert(car.drive.traffic, other.chassis) end
			end
		end
	end
	while now < seconds do
		now = now + frame
		SIM_NOW = now
		for _, g in ipairs(guards or {}) do g.update(now, frame) end
		for _, car in ipairs(CARS) do
			local drive = car.drive
			local input = { throttle = 0, steer = 0, parked = true }
			if drive and not car.out then
				if now >= nextSense[car] then
					nextSense[car] = nextSense[car] + 0.25
					local status = NAV.DriveSense(drive, now)
					car.lastStatus = status
					plan(car, status, now)
				end
				if not car.out then
					local throttle, steer, handbrake = NAV.DriveControl(drive, frame, now)
					input = { throttle = throttle, steer = steer, handbrake = handbrake }
					if TRACE and car == CARS[1] and math.floor(now * 8) ~= math.floor((now - frame) * 8) then
						local p = car.chassis.Position
						local v = car.chassis.AssemblyLinearVelocity
						table.insert(TRACE, string.format("t%.2f p(%.1f,%.1f,%.1f) v%.1f up%.2f thr%.2f st%.2f hb%s idx%d/%d cap%.1f %s",
							now, p.X, p.Y, p.Z, v.Magnitude, car.chassis.CFrame.UpVector.Y, throttle, steer, tostring(handbrake),
							drive.index, #drive.route, drive.wantedSpeed or -1, tostring(car.lastStatus))
							.. (drive.obstacle and now < drive.obstacle.untilTime and string.format(" OBS(%.0f,%.0f)", drive.obstacle.point.X, drive.obstacle.point.Z) or "")
							.. (drive.avoid and now < drive.avoid.untilTime and string.format(" AV%d(%.2f,%.2f)", drive.avoid.side, drive.avoid.dir.X, drive.avoid.dir.Z) or "")
							.. (drive.hazard and now < drive.hazard.untilTime and " HAZ" or "")
							.. (drive.front and now < drive.front.untilTime and string.format(" FRONT(%.0f,%.0f)", drive.front.point.X, drive.front.point.Z) or "")
							.. (drive.shift and string.format(" SHIFT%.1f@(%.0f,%.0f)", drive.shift.amount, drive.shift.point.X, drive.shift.point.Z) or "")
							.. string.format(" road%.1f%s", ROAD_DISTANCE(p.X, p.Z), drive.roadLeg[drive.index] and "R" or ""))
					end
					car.maxSpeed = max(car.maxSpeed or 0, car.chassis.AssemblyLinearVelocity.Magnitude)
				end
			end
			local tel = VD.Step(car.rig, input, frame)
			car.tel = tel
		end
		for _ = 1, 4 do physics(now) end
		for _, car in ipairs(CARS) do
			local p = car.chassis.Position
			car.minUp = min(car.minUp, car.chassis.CFrame.UpVector.Y)
			if WATERON and p.Z >= RIVER.z0 and p.Z <= RIVER.z1 and abs(p.X - RIVER.x) < RIVER.half + 6 and p.Y - car.g.cy < RIVER.level - 0.5 then
				car.inWater = true
			end
			if p.Y < car.startY - 8 and car.startY > 5 then car.fell = true end
			-- Off the tarmac while the route says road (a stud of slack either side of the edge).
			local drive = car.drive
			if drive and not car.out and drive.roadLeg[drive.index] and drive.index > 1 then
				local off = ROAD_DISTANCE(p.X, p.Z)
				car.roadTime = car.roadTime + frame
				if off > ROAD_HALF + 1 then car.offRoadTime = car.offRoadTime + frame end
				car.maxOff = max(car.maxOff, off)
				-- Which side of the centre line it keeps, signed by its own heading (+ right).
				table.insert(car.lateral, off)
			end
			-- People on foot: the clearance from the body to them anywhere IN FRONT of the car's middle
			-- (someone who runs into its flank or its back has run into it, not been run over), and
			-- any frame one of them is inside a stud of that front while the car is moving.
			for _, g in ipairs(guards or {}) do
				local rel = car.chassis.CFrame:PointToObjectSpace(g.root.Position)
				if rel.Z < 0 then
					local dx = max(0, abs(rel.X) - car.g.sx / 2)
					local dz = max(0, abs(rel.Z) - car.g.sz / 2)
					local d = sqrt(dx * dx + dz * dz)
					if d < minGuard then minGuard = d end
					if d < 1 and car.chassis.AssemblyLinearVelocity.Magnitude > 4 then guardHits = guardHits + 1 end
				end
			end
		end
		if #CARS == 2 then
			local pa, pb = CARS[1].chassis.Position, CARS[2].chassis.Position
			if math.abs(pa.X - pb.X) < 8 and not CARS[1].passZ then CARS[1].passZ = pa.Z; CARS[2].passZ = pb.Z end
		end
		local allDone = true
		for _, car in ipairs(CARS) do if not car.done and not car.out then allDone = false end end
		if allDone then break end
	end
	return now, minGuard, guardHits
end

function resetWorld()
	CARS = {}
	RAYCASTS = 0
end
"""

# --------------------------------------------------------------------------------------------
# The road network, in RoadNetwork's shape: nodes { position, arms, index, curve } and edges
# { a, b, length }. Bends carry a curve { centre, radius, a1, sweep } built as RoadNetwork's curveFor.
# --------------------------------------------------------------------------------------------

AXIS = {"E": (1, 0), "W": (-1, 0), "N": (0, -1), "S": (0, 1)}


def network():
    nodes = {
        "SW": (0, 400), "SE": (500, 400), "NE": (500, 0), "NW": (0, 0), "T": (250, 0), "SPUR": (250, -260),
    }
    links = [("NW", "T"), ("T", "NE"), ("NE", "SE"), ("SE", "SW"), ("SW", "NW"), ("T", "SPUR")]
    curves = {"NW": 45, "NE": 45, "SE": 40, "SW": 40}
    return nodes, links, curves


def dirname(a, b):
    dx, dz = b[0] - a[0], b[1] - a[1]
    if abs(dx) > abs(dz):
        return "E" if dx > 0 else "W"
    return "S" if dz > 0 else "N"


def network_lua():
    nodes, links, curves = network()
    arms = {k: {} for k in nodes}
    for a, b in links:
        arms[a][dirname(nodes[a], nodes[b])] = b
        arms[b][dirname(nodes[b], nodes[a])] = a
    lines = ["ROADS = { nodes = {}, edges = {} }", "local N = {}"]
    for index, (name, (x, z)) in enumerate(nodes.items(), start=1):
        lines.append(f'N["{name}"] = {{ position = Vector3.new({x}, 0, {z}), arms = {{}}, index = {index} }}')
        lines.append(f'table.insert(ROADS.nodes, N["{name}"])')
        if name in curves:
            r = curves[name]
            names = list(arms[name].keys())
            d1, d2 = AXIS[names[0]], AXIS[names[1]]
            cx, cz = x + (d1[0] + d2[0]) * r, z + (d1[1] + d2[1]) * r
            fx, fz = x + d1[0] * r, z + d1[1] * r
            sx, sz = x + d2[0] * r, z + d2[1] * r
            a1 = math.atan2(fz - cz, fx - cx)
            a2 = math.atan2(sz - cz, sx - cx)
            sweep = a2 - a1
            while sweep > math.pi:
                sweep -= 2 * math.pi
            while sweep < -math.pi:
                sweep += 2 * math.pi
            lines.append(f'N["{name}"].curve = {{ centre = Vector3.new({cx}, 0, {cz}), radius = {r}, a1 = {a1}, sweep = {sweep} }}')
    for a, b in links:
        ax, az = nodes[a]
        bx, bz = nodes[b]
        length = math.hypot(bx - ax, bz - az)
        bridges = ""
        if (a, b) == ("SE", "SW"):
            # The deck spans x 228..272 on this edge, which runs from x 500 toward x 0.
            bridges = ", bridges = { { s0 = 228, s1 = 272 } }"
        lines.append(f'do local e = {{ a = N["{a}"], b = N["{b}"], length = {length}{bridges} }}; table.insert(ROADS.edges, e);'
                     f' N["{a}"].arms["{dirname(nodes[a], nodes[b])}"] = e; N["{b}"].arms["{dirname(nodes[b], nodes[a])}"] = e end')
    # The tarmac: each edge trimmed back to its curves' tangents, and each curve as short chords.
    segs = []
    for a, b in links:
        (ax, az), (bx, bz) = nodes[a], nodes[b]
        ux, uz = (bx - ax), (bz - az)
        length = math.hypot(ux, uz)
        ux, uz = ux / length, uz / length
        ta = curves.get(a, 0)
        tb = curves.get(b, 0)
        segs.append((ax + ux * ta, az + uz * ta, bx - ux * tb, bz - uz * tb))
    for name, r in curves.items():
        x, z = nodes[name]
        names = list(arms[name].keys())
        d1, d2 = AXIS[names[0]], AXIS[names[1]]
        cx, cz = x + (d1[0] + d2[0]) * r, z + (d1[1] + d2[1]) * r
        a1 = math.atan2(z + d1[1] * r - cz, x + d1[0] * r - cx)
        a2 = math.atan2(z + d2[1] * r - cz, x + d2[0] * r - cx)
        sweep = a2 - a1
        while sweep > math.pi:
            sweep -= 2 * math.pi
        while sweep < -math.pi:
            sweep += 2 * math.pi
        steps = 12
        pts = [(cx + r * math.cos(a1 + sweep * k / steps), cz + r * math.sin(a1 + sweep * k / steps)) for k in range(steps + 1)]
        for p, q in zip(pts, pts[1:]):
            segs.append((p[0], p[1], q[0], q[1]))
    for s in segs:
        lines.append("table.insert(ROADSEGS, { %f, %f, %f, %f })" % s)
    return "\n".join(lines)


# Things beside and in the road, and the field. Boxes are x0, y0, z0, x1, y1, z1.
def furniture_lua(field=True):
    boxes = [
        # Parked cars on the south verge, clear of the carriageway.
        ("Parked", 100, 0, 413, 115, 5, 420), ("Parked", 360, 0, 413, 375, 5, 420),
        # Trees on the verges of the west road and the hill.
        ("Tree", -16, 0, 150, -13, 22, 153), ("Tree", 513, 0, 120, 516, 22, 123), ("Tree", 13, 0, 260, 16, 22, 263),
        # A building on the inside of the north-east bend, and a lamp post by the tee.
        ("Building", 420, 0, 40, 450, 25, 80), ("Lamp", 262, 0, 12, 263, 14, 13),
        # The bridge deck over the river on the south road: collidable, its top level with the road.
        ("Bridge", 228, -1.2, 391, 272, 0, 409),
    ]
    if field:
        boxes += [
            ("Building", 230, 0, 170, 270, 25, 230),
            ("Tree", 150, 0, 190, 153, 22, 193), ("Tree", 180, 0, 215, 183, 22, 218), ("Tree", 320, 0, 195, 323, 22, 198),
            ("Tree", 350, 0, 205, 353, 22, 208), ("Tree", 300, 0, 225, 303, 22, 228), ("Tree", 200, 0, 180, 203, 22, 183),
        ]
    out = []
    for b in boxes:
        name, x0, y0, z0, x1, y1, z1 = b
        out.append(f'addBox("{name}", {x0}, {y0}, {z0}, {x1}, {y1}, {z1}, "{"Concrete" if name == "Bridge" else "Wood"}")')
    return "\n".join(out)


def stalled_box():
    # A stalled car standing across the eastbound lane of the north road (centre line z = 0, the bot
    # keeps 3.5 to its right, which heading east is +Z).
    return 'addBox("Stalled", 150, 0, 0.5, 165, 5, 7.5, "Metal")'


SCENARIOS = r"""
local NAV = ...
local R = {}
local V = Vector3.new
local abs = math.abs

-- BotService's reaction to a look, for a travelling bot: next goal on arrival, the roads after a
-- hazard, out on anything it cannot drive through.
local function traveller(goals, useRoads, bounds)
	return function(car, status, now)
		car.statuses = car.statuses or {}
		car.statuses[status] = (car.statuses[status] or 0) + 1
		if status == "arrived" then
			car.reached = (car.reached or 0) + 1
			car.goalIndex = (car.goalIndex or 1) + 1
			if car.goalIndex > #goals then car.done = true; return end
			NAV.DriveTo(car.drive, goals[car.goalIndex], { roads = useRoads and ROADS or nil, bounds = bounds, arrive = 22 })
		elseif status == "hazard" and useRoads and not car.drive.preferred then
			car.drive.preferred = true
			car.replans = (car.replans or 0) + 1
			NAV.DriveTo(car.drive, goals[car.goalIndex or 1], { roads = ROADS, arrive = 22, preferRoads = true })
			car.drive.preferred = true
		elseif status == "hazard" or status == "stuck" or status == "lost" or status == "flipped" then
			car.out = status
		end
	end
end

local function start(car, goals, useRoads)
	car.goalIndex = 1
	NAV.DriveTo(car.drive, goals[1], { roads = useRoads and ROADS or nil, arrive = 22 })
end

local function impacts(car, floor)
	local n, worst = 0, 0
	for _, i in ipairs(car.impacts) do
		if i.speed > (floor or 4) then n = n + 1 end
		worst = math.max(worst, i.speed)
	end
	return n, worst
end

-- What a car did round a stretch of the world, from BotService's side (each look): stops (from moving
-- to under 2.5 studs/s), reverses (from going forward to backing), and the statuses. `near(p)` says
-- whether a position is on the stretch that counts.
local function watcher(base, near)
	local w = { stops = 0, reverses = 0, stuck = 0, hazards = 0, fronts = 0, avoids = 0, looks = 0 }
	w.plan = function(car, status, now)
		local ch = car.chassis
		local p = ch.Position
		local along = ch.AssemblyLinearVelocity:Dot(ch.CFrame.LookVector)
		if near(p) then
			w.looks = w.looks + 1
			if along < 2.5 and (w.lastAlong or 0) >= 6 and status ~= "arrived" and status ~= "stopping" then w.stops = w.stops + 1 end
			if along < -1 and (w.lastAlong or 0) >= -1 then w.reverses = w.reverses + 1 end
			if status == "stuck" then w.stuck = w.stuck + 1 end
			if status == "hazard" then w.hazards = w.hazards + 1 end
			local d = car.drive
			if d.front then w.fronts = w.fronts + 1 end
			if d.avoid and now < d.avoid.untilTime then w.avoids = w.avoids + 1 end
		end
		w.lastAlong = along
		base(car, status, now)
	end
	return w
end

-- Contacts that started with parts named in `names` (any speed), and all contacts.
local function touchesOf(car, names)
	local n, all = 0, 0
	for _, t in ipairs(car.touches or {}) do
		if not t.name:find("^car") then
			all = all + 1
			if names[t.name] then n = n + 1 end
		end
	end
	return n, all
end

function scenario(name, modelId, g, seed, variant)
	resetWorld()
	BUDGET_OFF_AT = nil
	math.randomseed(seed or 1)
	local out = { name = name, model = modelId }
	local useRoads = true
	if name == "crossing" then
		-- The real bridge on the south road, crossed along the road from 100-120 studs before one end to
		-- 150 past the other, starting a little off the lane's line and a little askew (the seed).
		local B = { x0 = 220, x1 = 280, z = 400, half = 10.5, grade = BRIDGE_GRADE or 0.05, base = 3.1, run = 20 }
		buildRealBridge(B)
		for _, e in ipairs(ROADS.edges) do
			-- The SE-SW edge runs from x 500 toward x 0.
			if e.bridges then e.bridges = { { s0 = 500 - B.x1, s1 = 500 - B.x0 } } end
		end
		local dir = variant == "west" and -1 or 1
		if variant == "wall" then
			-- The invariant: a wall across the whole road at mid-span, parapet to parapet, 3 tall.
			local y = bridgeRoad(250)
			addBox("RoadWall", 249.5, y - 0.5, B.z - B.half + 1, 250.5, y + 3, B.z + B.half - 1, "Concrete")
		end
		local lane = B.z + dir * 3.5
		local startX = (dir > 0 and B.x0 - 100 or B.x1 + 100) - dir * math.random() * 20
		local car = makeVehicle(modelId, g, startX, lane + (math.random() - 0.5) * 2.4,
			-dir * math.pi / 2 + math.rad((math.random() - 0.5) * 12))
		makeDrive(car)
		local goals = { V(dir > 0 and B.x1 + 150 or B.x0 - 150, 0, lane) }
		start(car, goals, true)
		local enter, exit = dir > 0 and B.x0 or B.x1, dir > 0 and B.x1 or B.x0
		local w = watcher(traveller(goals, true), function(p) return abs(p.Z - B.z) < 30 and p.X > B.x0 - 40 and p.X < B.x1 + 40 end)
		local enteredAt, leftAt
		local t = runWorld(50, function(c, status, now)
			local x = c.chassis.Position.X
			if not enteredAt and (x - enter) * dir > 0 then enteredAt = now end
			if enteredAt and not leftAt and (x - exit) * dir > 0 then leftAt = now end
			w.plan(c, status, now)
		end)
		out.crossed = leftAt ~= nil
		out.deckTime = leftAt and enteredAt and (leftAt - enteredAt) or -1
		out.reached = car.reached or 0
		out.stops, out.reverses, out.stuck, out.hazards = w.stops, w.reverses, w.stuck, w.hazards
		out.fronts, out.avoids, out.looks = w.fronts, w.avoids, w.looks
		out.parapet, out.contacts = touchesOf(car, { BridgeParapet = true, BridgeLampPost = true })
		out.wallHits = touchesOf(car, { RoadWall = true })
		out.impacts, out.worst = impacts(car)
		out.inWater = car.inWater
		out.out = car.out
		out.time = t
	elseif name == "props" then
		-- Open ground west of everything: across country from x -1000 to a goal at -700 (z 800), with one of
		-- the things the maps' logged stops were against (tools/bot_driving_maps_probe.lua) 150 studs on,
		-- at its logged size. The seed moves the start across and askew, and the prop across the line.
		local z0, X = 800, -850
		local off = (math.random() - 0.5) * 3
		local z = z0 + off
		local kind = variant or "post"
		local names = {}
		local function solid(label, x0, y0, z0_, x1, y1, z1)
			names[label] = true
			return addBox(label, x0, y0, z0_, x1, y1, z1, "Concrete")
		end
		if kind == "slope" then
			RAMP = { x0 = -930, x1 = -760, z = z0, half = 60, grade = 0.15 }
		elseif kind == "bank" then
			RAMP = { x0 = -1200, x1 = -500, z = z0, half = 40, grade = 0.3, across = true }
		end
		local y = RAMP and rampHeight(X, z) or 0
		if kind == "post" then
			-- LampPost (Town/ParkingLot): a Cylinder 0.7 across, 15.5 tall.
			solid("LampPost", X - 0.35, 0, z - 0.35, X + 0.35, 15.5, z + 0.35)
		elseif kind == "hedge" then
			-- Hedge (Town/ParkingLot): 14.3 x 3.4 x 1.5, across the way.
			solid("Hedge", X - 0.75, 0, z - 7.15, X + 0.75, 3.4, z + 7.15)
		elseif kind == "fence" then
			-- A lot's post-and-rail fence across the way: FencePost 0.6 across and 3.8 tall every 6 studs, a
			-- rail along the tops.
			for k = -2, 3 do solid("FencePost", X - 0.3, 0, z + k * 6 - 0.3, X + 0.3, 3.8, z + k * 6 + 0.3) end
			solid("FenceRail", X - 0.2, 3.0, z - 12.3, X + 0.2, 3.4, z + 18.3)
		elseif kind == "sign" then
			-- SignPost (0.4 across, 5 tall) behind its ParkingSign plate, which nothing collides with.
			solid("SignPost", X - 0.2, 0, z - 0.2, X + 0.2, 5.0, z + 0.2)
			addBox("ParkingSign", X - 0.35, 2.4, z - 1.3, X - 0.25, 4.6, z + 1.3, "Metal").CanCollide = false
		elseif kind == "rock" then
			-- A rock (MapDecor's, size 12): a Ball 9.6 across, its centre 3 up.
			names.Rock = true
			addBall("Rock", X, 3, z, 4.8, "Rock")
		elseif kind == "pebble" then
			-- A rock's pebble (size 8): a Ball 1.96 across, centre 0.56 up, top 1.5: under the sweep's floor,
			-- which meets it on its shoulder, a face turned up.
			names.Pebble = true
			addBall("Pebble", X, 0.56, z, 0.98, "Rock")
		elseif kind == "low" then
			-- A low wall across the way, 1.0 tall (a bus shelter's base wall is 1.02): under the sweep.
			solid("LowWall", X - 0.15, 0, z - 4.8, X + 0.15, 1.0, z + 4.8)
		elseif kind == "bumper" then
			-- The invariant: a solid block at bumper height square in the way.
			solid("Block", X - 0.75, 0, z - 0.75, X + 0.75, 2.5, z + 0.75)
		elseif kind == "clutter" then
			-- A car park's or a town square's clutter across the way, at the logged sizes: on a 16-stud grid
			-- jittered by the seed (a car's width free between any two), lamp posts (0.7), bollards (0.7 by
			-- 3.2), fence posts (0.6 by 3.8), shrubs (Balls 2.1 across, top 2.5), parked cars (6.5 x 5 x 14).
			for gx = 0, 5 do
				for gz = -3, 3 do
					local px, pz = X - 40 + gx * 16 + (math.random() - 0.5) * 5, z0 + gz * 16 + (math.random() - 0.5) * 5
					local pick = math.random(1, 5)
					if pick == 1 then
						solid("LampPost", px - 0.35, 0, pz - 0.35, px + 0.35, 15.5, pz + 0.35)
					elseif pick == 2 then
						solid("Bollard", px - 0.35, 0, pz - 0.35, px + 0.35, 3.2, pz + 0.35)
					elseif pick == 3 then
						solid("FencePost", px - 0.3, 0, pz - 0.3, px + 0.3, 3.8, pz + 0.3)
					elseif pick == 4 then
						names.Shrub = true
						addBall("Shrub", px, 1.45, pz, 1.05, "Grass")
					elseif gx % 2 == 0 then
						solid("ParkedCar", px - 7, 0, pz - 3.25, px + 7, 5, pz + 3.25)
					end
				end
			end
		elseif kind == "slope" or kind == "bank" then
			-- A tree's trunk (the Props trees', 2.6 across) standing on the slope.
			solid("Trunk", X - 1.3, y - 1, z - 1.3, X + 1.3, y + 14, z + 1.3)
		end
		local car = makeVehicle(modelId, g, -1000, z0 + (math.random() - 0.5) * 6, -math.pi / 2 + math.rad((math.random() - 0.5) * 16))
		makeDrive(car)
		local goals = { V(-700, 0, z0) }
		start(car, goals, false)
		local w = watcher(traveller(goals, false), function() return true end)
		out.time = runWorld(40, w.plan)
		out.reached = car.reached or 0
		out.stops, out.reverses, out.stuck, out.hazards = w.stops, w.reverses, w.stuck, w.hazards
		out.fronts, out.avoids = w.fronts, w.avoids
		out.parapet, out.contacts = touchesOf(car, names)
		out.touched = out.parapet
		out.impacts, out.worst = impacts(car)
		out.recoveries = car.drive.stats.recoveries
		out.out = car.out
	elseif name == "lap" or name == "bike" then
		-- Start on the west road heading north, then a lap: the tee, the hill, the bridge, home.
		local car = makeVehicle(modelId, g, 3.5, 300, 0)
		makeDrive(car)
		local goals = { V(250, 0, -150), V(500, 0, 200), V(250, 0, 403.5), V(3.5, 0, 200), V(250, 0, 3.5) }
		start(car, goals, true)
		local t = runWorld(170, traveller(goals, true))
		out.reached, out.goals = car.reached or 0, #goals
		out.time = t
		out.impacts, out.worst = impacts(car)
		out.offShare = car.roadTime > 0 and car.offRoadTime / car.roadTime or 0
		out.maxOff = car.maxOff
		out.out = car.out
		out.minUp = car.minUp
		out.recoveries = car.drive.stats.recoveries
		out.maxCasts = car.drive.stats.maxCasts
		out.senses = car.drive.stats.senses
		out.inWater = car.inWater
	elseif name == "field" then
		local car = makeVehicle(modelId, g, 90, 200, -math.pi / 2)
		makeDrive(car)
		local goals = { V(420, 0, 205), V(90, 0, 195) }
		start(car, goals, false)
		runWorld(60, traveller(goals, false))
		out.reached, out.goals = car.reached or 0, #goals
		out.impacts, out.worst = impacts(car)
		out.out = car.out
	elseif name == "river" or name == "bridge" then
		-- West bank to east bank, well south of the road.
		local car = makeVehicle(modelId, g, 150, 520, -math.pi / 2)
		makeDrive(car)
		local goals = { V(350, 0, 520) }
		useRoads = name == "bridge"
		start(car, goals, false)
		runWorld(80, traveller(goals, useRoads))
		out.reached, out.goals = car.reached or 0, #goals
		out.inWater = car.inWater
		out.out = car.out
		out.replans = car.replans or 0
		out.impacts = impacts(car)
	elseif name == "cliff" then
		local car = makeVehicle(modelId, g, -250, 0, -math.pi / 2)
		makeDrive(car)
		local goals = { V(60, 0, 0) }
		start(car, goals, false)
		runWorld(40, traveller(goals, false))
		out.fell = car.fell
		out.out = car.out
		out.x = car.chassis.Position.X
	elseif name == "wedge" then
		-- Nose up to a long wall, too close to turn away from it going forward; the goal beyond it.
		addBox("Wall", -240, 0, 560, -160, 10, 564, "Concrete")
		local car = makeVehicle(modelId, g, -196, 564 + g.sz / 2 + 1.2, math.rad(-12))
		makeDrive(car)
		local goals = { V(-200, 0, 470) }
		start(car, goals, false)
		runWorld(60, traveller(goals, false))
		out.reached = car.reached or 0
		out.out = car.out
		out.recoveries = car.drive.stats.recoveries
		out.impacts, out.worst = impacts(car, 12)
	elseif name == "boxed" then
		-- Walled in on every side: nothing to do but give the vehicle up.
		addBox("BoxN", -222, 0, 556, -178, 10, 560, "Concrete")
		addBox("BoxW", -222, 0, 560, -218, 10, 600, "Concrete")
		addBox("BoxE", -182, 0, 560, -178, 10, 600, "Concrete")
		addBox("BoxS", -222, 0, 600, -178, 10, 604, "Concrete")
		local car = makeVehicle(modelId, g, -200, 580, 0)
		makeDrive(car)
		local goals = { V(-200, 0, 470) }
		start(car, goals, false)
		local t = runWorld(60, traveller(goals, false))
		out.out = car.out
		out.time = t
		out.recoveries = car.drive.stats.recoveries
		out.impacts, out.worst = impacts(car, 12)
	elseif name == "blind" then
		-- Under way toward a wall when the frame's ray budget runs out for good: with nothing looked
		-- at, it must not drive on into what it has not seen.
		addBox("BlindWall", -260, 0, 500, -140, 10, 504, "Concrete")
		local car = makeVehicle(modelId, g, -200, 640, 0)
		makeDrive(car)
		local goals = { V(-200, 0, 420) }
		start(car, goals, false)
		BUDGET_OFF_AT = 2.5
		runWorld(14, traveller(goals, false))
		BUDGET_OFF_AT = nil
		out.impacts, out.worst = impacts(car)
		out.z = car.chassis.Position.Z
		out.speed = car.chassis.AssemblyLinearVelocity.Magnitude
		out.blind = car.drive.stats.senses
		out.out = car.out
	elseif name == "teammates" then
		-- The north road, heading east from the west bend; one teammate crosses, one stands in the lane.
		local car = makeVehicle(modelId, g, 60, 3.5, -math.pi / 2)
		makeDrive(car)
		local goals = { V(230, 0, 3.5) }
		start(car, goals, true)
		local crosser = { Position = V(120, 3, -20), Parent = true, AssemblyLinearVelocity = Vector3.zero }
		local stander = { Position = V(190, 3, 4), Parent = true, AssemblyLinearVelocity = Vector3.zero }
		local guards = {
			{ root = crosser, hard = true, update = function(now, dt)
				-- Runs across the road, into the car's path, as it arrives.
				local v = (now > 0.4 and crosser.Position.Z < 25) and V(0, 0, 16) or Vector3.zero
				crosser.AssemblyLinearVelocity = v
				crosser.Position = crosser.Position + v * dt
			end },
			{ root = stander, hard = true, update = function(now, dt)
				-- Stands in the lane for a while, then steps off.
				local v = (now > 14 and stander.Position.Z < 20) and V(0, 0, 8) or Vector3.zero
				stander.AssemblyLinearVelocity = v
				stander.Position = stander.Position + v * dt
			end },
		}
		for _, guard in ipairs(guards) do table.insert(car.drive.guard, guard) end
		local t, minGuard, hits = runWorld(45, traveller(goals, true), guards)
		out.reached = car.reached or 0
		out.minGuard = minGuard
		out.guardHits = hits
		out.out = car.out
	elseif name == "meet" then
		-- Two bots on the north road, driving at each other.
		local a = makeVehicle(modelId, g, 60, 3.5, -math.pi / 2)
		local b = makeVehicle(modelId, g, 440, -3.5, math.pi / 2)
		a.model.Name = "A"; b.model.Name = "B"
		makeDrive(a); makeDrive(b)
		start(a, { V(440, 0, 0) }, true)
		start(b, { V(60, 0, 0) }, true)
		runWorld(40, function(car, status, now)
			if status == "arrived" then car.done = true; car.reached = 1 elseif status ~= "driving" and status ~= "stopping" then car.out = status end
		end)
		out.reached = (a.reached or 0) + (b.reached or 0)
		local ia = impacts(a, 1)
		local ib = impacts(b, 1)
		out.impacts = ia + ib
		-- Each keeps to its own right: A (eastbound) on +Z of the centre line, B (westbound) on -Z.
		out.sideA = a.sideSum or 0
		out.aZ, out.bZ = a.passZ, b.passZ
	end
	out.rays = RAYCASTS
	return out
end
"""


def load(dynamics_src, botnav_src):
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(cars.PRELUDE)
    lua.execute(WORLD)
    vd = lua.execute(luau_to_lua(dynamics_src))
    nav = lua.execute(luau_to_lua(driving_source(botnav_src)))
    lua.execute(SIM, vd, nav)
    lua.execute(network_lua())
    lua.execute(furniture_lua())
    lua.execute(stalled_box())
    lua.execute(SCENARIOS, nav)
    return lua, vd


CAR_MODELS = ["Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan"]
ALL_SCENARIOS = ["lap", "field", "river", "bridge", "cliff", "wedge", "boxed", "blind", "teammates", "meet",
                 # The real bridge both ways, a wall across it, and the prop course (seed 1 of --measure's).
                 "crossing:east", "crossing:west", "crossing:wall"] + ["props:" + kind for kind in
                 ["post", "hedge", "fence", "sign", "rock", "pebble", "low", "bumper", "slope", "bank"]]


def geometry(lua, model):
    if model in cars.MODELS:
        g = cars.MODELS[model]
        return lua.table_from(dict(r=g["r"], track=g["track"], fz=g["fz"], rz=g["rz"], sx=g["size"][0], sy=g["size"][1],
                                   sz=g["size"][2], cy=g["cy"], rho=1.3))
    g = bikes.BIKES[model]
    return lua.table_from(dict(bike=True, fr=g["fr"], rr=g["rr"], fz=g["fz"], rz=g["rz"], sx=g["size"][0], sy=g["size"][1],
                               sz=g["size"][2], cy=g["c"][0], cz=g["c"][1], rho=g["rho"]))


def run_one(lua, scenario, model, seed=1, variant=None):
    g = geometry(lua, model)
    result = lua.globals().scenario(scenario, model, g, seed, variant)
    out = {k: result[k] for k in result}
    for key in ("out", "aZ", "bZ", "replans", "recoveries", "time", "worst", "minGuard"):
        out.setdefault(key, None)
    return out


# The bar each scenario is held to.
def judge(name, r):
    p = []
    if name == "crossing:wall":
        # Invariant: a wall across the road is always seen (stopped short of, never driven through).
        if r["wallHits"] > 0 or r["crossed"]:
            p.append(f"ran into a wall across the bridge ({r['wallHits']} contacts, crossed {r['crossed']})")
    elif name.startswith("crossing:"):
        if not r["crossed"] or r["reached"] < 1:
            p.append(f"never got across the bridge (out: {r['out']}, stuck {r['stuck']}, hazards {r['hazards']})")
        if r["parapet"] > 0 or r["impacts"] > 0:
            p.append(f"{r['parapet']} parapet or lamp post contacts, {r['impacts']} impacts")
        if r["stops"] > 0 or r["reverses"] > 0:
            p.append(f"{r['stops']} stops and {r['reverses']} reverses crossing")
    elif name.startswith("props:"):
        kind = name.split(":")[1]
        if r["reached"] < 1:
            p.append(f"never got past the {kind} (out: {r['out']}, recoveries {r['recoveries']})")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} impacts over 4 studs/s (worst {r['worst']:.1f})")
        # Invariant: a solid part in the car's path at bumper height is always seen, so never touched.
        if kind == "bumper" and r["touched"] > 0:
            p.append(f"touched a solid block at bumper height square in its path ({r['touched']} contacts)")
    elif name in ("lap", "bike"):
        if r["reached"] < r["goals"]:
            p.append(f"reached {r['reached']}/{r['goals']} goals (out: {r['out']})")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} impacts (worst {r['worst']:.1f} studs/s)")
        if r["offShare"] > 0.08:
            p.append(f"off the tarmac {r['offShare'] * 100:.1f}% of the time on road legs")
        if r["minUp"] < 0.5:
            p.append(f"nearly rolled (up {r['minUp']:.2f})")
        if r["maxCasts"] > 4:
            p.append(f"{r['maxCasts']} spatial queries in one look (budget 4)")
        if r["inWater"]:
            p.append("drove into the river")
    elif name == "field":
        if r["reached"] < r["goals"]:
            p.append(f"reached {r['reached']}/{r['goals']} (out: {r['out']})")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} impacts (worst {r['worst']:.1f})")
    elif name == "river":
        if r["inWater"]:
            p.append("drove into the river")
        if r.get("out") != "hazard":
            p.append(f"did not stop at the bank as a hazard (out: {r['out']}, reached {r['reached']})")
    elif name == "bridge":
        if r["inWater"]:
            p.append("drove into the river")
        if r["reached"] < 1:
            p.append(f"never got across on the bridge (out: {r['out']}, replans {r['replans']})")
    elif name == "cliff":
        if r["fell"]:
            p.append(f"drove off the cliff (x {r['x']:.1f})")
        if r.get("out") != "hazard":
            p.append(f"did not stop at the edge as a hazard (out: {r['out']})")
    elif name == "wedge":
        if r["reached"] < 1:
            p.append(f"never got round the wall to the goal (out: {r['out']}, recoveries {r['recoveries']})")
        if r["recoveries"] < 1:
            p.append("never backed off the wall (the scenario did not test recovery)")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} hard impacts over 12 studs/s (worst {r['worst']:.1f})")
    elif name == "blind":
        if r["impacts"] > 0:
            p.append(f"drove on blind: {r['impacts']} impacts (worst {r['worst']:.1f} studs/s) after the ray budget ran out")
        if r["speed"] > 3:
            p.append(f"still moving at {r['speed']:.1f} studs/s with nothing looked at for 11 s")
        if r.get("out"):
            # Nothing seen is not a drop or a wall: it waits for its rays, it doesn't give the car up.
            p.append(f"read a spent ray budget as '{r['out']}' and gave the vehicle up")
    elif name == "boxed":
        if r.get("out") not in ("stuck", "lost") or r["time"] > 30:
            p.append(f"boxed in, did not give the vehicle up within 30 s (out: {r['out']} at {r['time']:.1f} s)")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} hard impacts over 12 studs/s (worst {r['worst']:.1f})")
    elif name == "teammates":
        if r["guardHits"] > 0 or r["minGuard"] < 1.0:
            p.append(f"came within {r['minGuard']:.2f} studs of a teammate on foot in front ({r['guardHits']} frames touching on the move)")
        if r["reached"] < 1:
            p.append(f"never got past them (out: {r['out']})")
    elif name == "meet":
        if r["reached"] < 2:
            p.append(f"only {r['reached']}/2 bots got through")
        if r["impacts"] > 0:
            p.append(f"{r['impacts']} contacts between the two")
        if r["aZ"] is None or r["bZ"] is None or not (r["aZ"] > 0.5 and r["bZ"] < -0.5):
            p.append(f"did not keep right passing (eastbound z {r['aZ']}, westbound z {r['bZ']})")
    return p


def sweep(dynamics_src, botnav_src, models, scenarios, verbose=False):
    results = {}
    for scenario in scenarios:
        name, _, variant = scenario.partition(":")
        for model in (["BrrStreetfighter"] if scenario == "bike" else models):
            lua, _ = load(dynamics_src, botnav_src)
            t0 = time.time()
            r = run_one(lua, name, model, 1, variant or None)
            r["wall"] = time.time() - t0
            results[(scenario, model)] = r
            if verbose:
                print(scenario, model, {k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items()}, flush=True)
    return results


def report(results):
    problems = []
    for (scenario, model), r in results.items():
        found = judge(scenario, r)
        for f in found:
            problems.append(f"{scenario} {model}: {f}")
    return problems


def row(scenario, model, r):
    bits = []
    for key in ("reached", "goals", "time", "impacts", "offShare", "maxOff", "recoveries", "maxCasts", "minGuard", "out",
                "inWater", "fell", "replans", "aZ", "bZ", "z", "speed", "crossed", "stops", "reverses", "stuck", "parapet", "wallHits", "touched"):
        if key in r and r[key] is not None:
            v = r[key]
            if key == "offShare":
                v = f"{v * 100:.1f}%"
            elif isinstance(v, float):
                v = f"{v:.1f}"
            bits.append(f"{key} {v}")
    return f"  {scenario:14} {model:17} " + "  ".join(bits)


# Planted faults, each aimed at an invariant, and the scenario whose check must catch it.
PLANTS = [
    ("steering sign", "local steer = math.clamp(wheel / maxSteer, -1, 1)", "local steer = math.clamp(-wheel / maxSteer, -1, 1)", ("lap", "Rotster")),
    ("obstacles never seen", "local function blocking(hit)\n\tif not hit then", "local function blocking(hit)\n\tif true then", ("field", "Rotster")),
    ("water not seen", "if not below or below.Material == WATER then", "if not below then", ("river", "Rotster")),
    ("drop not seen", "if drop > math.max(DRIVE_DROP, probeDistance * DRIVE_DROP_GRADE) then", "if false then", ("cliff", "Rotster")),
    ("no reverse recovery", "drive.reverseUntil = now + DRIVE_REVERSE_FOR", "drive.reverseUntil = now", ("wedge", "Rotster")),
    ("teammates not guarded", "for _, guard in ipairs(drive.guard) do", "for _, guard in ipairs({}) do", ("teammates", "Rotster")),
    ("no corner speed", "cap = math.min(cap, cornerCap(drive, position, math.abs(speed), decel))", "cap = cap", ("lap", "TralalaGT")),
    ("ray budget ignored", "\tif BotNav.CastRemaining(\"navigation\") < DRIVE_CASTS_PER_SENSE then", "\tif false then", ("blind", "Rotster")),
    ("query budget", "\t-- 2: the way it would like to go.", "\tcast(drive, position, nil, look, drive.params)\n\t-- 2: the way it would like to go.", ("lap", "Rotster")),
    ("lane on the wrong side", "local DRIVE_LANE = 3.5", "local DRIVE_LANE = -3.5", ("meet", "Rotster")),
    # A solid part in the car's path at bumper height is always seen: the sweep lifted clear of it.
    ("sweep over bumper height", "local boxAt = position + up * (2.6 - drive.rideHeight)", "local boxAt = position + up * (4.6 - drive.rideHeight)",
     ("props:bumper", "Rotster")),
    # A wall across the road is always seen: the side-on rule taking anything met as beside the way.
    ("a face in the way taken as beside", "if normal.Magnitude > 0.3 and math.abs(normal.Unit:Dot(steering)) < DRIVE_SIDE_ON and besideBy(front.Position) > DRIVE_BESIDE then",
     "if true then", ("crossing:wall", "Rotster")),
    # A solid part in the path is seen whatever nothing-collides part stands in front of it (a sign's plate).
    ("sweeps stop at what nothing collides with", "options.params.RespectCanCollide = true", "options.params.RespectCanCollide = false",
     ("props:sign", "Rotster")),
]


# Scenarios measured over seeds (each model, each variant, seeds 1..N) and reported as counts, before
# against after: --measure NAME --seeds N [--botnav OTHER_BOTNAV.lua]. For each: its variants, the counts
# summed, and what the totals are grouped by.
PROP_KINDS = ["post", "hedge", "fence", "sign", "rock", "pebble", "low", "bumper", "slope", "bank", "clutter"]
MEASURED = {
    "crossing": (["east", "west"], ["crossed", "reached", "stops", "reverses", "stuck", "hazards", "parapet", "contacts", "impacts",
                                    "fronts", "avoids"], ("model", "variant")),
    "props": (PROP_KINDS, ["reached", "stops", "reverses", "stuck", "hazards", "touched", "impacts", "fronts", "avoids"], ("variant", "model")),
}


def measure(dynamics_src, botnav_src, scenario, models, seeds, variants, grade=None, verbose=False):
    rows = {}
    keys = MEASURED[scenario][1]
    for model in models:
        for variant in variants:
            for seed in range(1, seeds + 1):
                lua, _ = load(dynamics_src, botnav_src)
                if grade is not None:
                    lua.globals().BRIDGE_GRADE = grade
                r = run_one(lua, scenario, model, seed, variant)
                rows[(model, variant, seed)] = r
                if verbose:
                    print("  ", model, variant, seed, {k: (round(v, 2) if isinstance(v, float) else v) for k, v in r.items()
                                                  if k in keys + ["deckTime", "out"]}, flush=True)
    return rows


def measure_report(rows, scenario):
    """Totals per group (MEASURED's grouping) and overall, as printed lines."""
    keys, by = MEASURED[scenario][1], MEASURED[scenario][2]
    lines = []
    groups = {}
    for (model, variant, seed), r in rows.items():
        names = {"model": model, "variant": variant}
        groups.setdefault((names[by[0]], names[by[1]]) if scenario == "crossing" else (names[by[0]], ""), []).append(r)
        if scenario != "crossing":
            groups.setdefault((names[by[1]], ""), []).append(r)
        groups.setdefault(("ALL", ""), []).append(r)
    for (a, b), rs in groups.items():
        total = {k: sum(int(bool(r.get(k))) if isinstance(r.get(k), bool) else (r.get(k) or 0) for r in rs) for k in keys}
        times = [r["deckTime"] for r in rs if r.get("deckTime", -1) > 0]
        outs = {}
        for r in rs:
            if r.get("out"):
                outs[r["out"]] = outs.get(r["out"], 0) + 1
        lines.append(f"  {a:16} {b:5} runs {len(rs):3}  " + "  ".join(f"{k} {total[k]}" for k in keys)
                     + ((f"  s/crossing {sum(times) / len(times):.1f}" if times else "  s/crossing -") if scenario == "crossing" else "")
                     + (f"  gave up: {outs}" if outs else ""))
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--quick", action="store_true", help="one car model, and the planted faults")
    parser.add_argument("--only", default=None)
    parser.add_argument("--trace", default=None, help="scenario:model[:seed[:variant]] to trace")
    parser.add_argument("--measure", default=None, help="a scenario in MEASURED, run over --seeds")
    parser.add_argument("--seeds", type=int, default=10)
    parser.add_argument("--grade", type=float, default=None, help="the crossing's bridge grade (default 0.05)")
    parser.add_argument("--models", default=None, help="comma-separated car models (default all four)")
    parser.add_argument("--botnav", default=None, help="run against this BotNav.lua instead (a before)")
    args = parser.parse_args()
    dynamics = open(DYNAMICS, encoding="utf-8").read()
    botnav = open(args.botnav or BOTNAV, encoding="utf-8").read()
    if args.measure:
        models = args.models.split(",") if args.models else CAR_MODELS
        t0 = time.time()
        rows = measure(dynamics, botnav, args.measure, models, args.seeds, MEASURED[args.measure][0], args.grade, args.verbose)
        print(f"bot driving sim, measured: {args.measure}, {len(rows)} runs ({args.seeds} seeds), {time.time() - t0:.0f} s")
        for line in measure_report(rows, args.measure):
            print(line)
        return 0
    models = ["Rotster"] if args.quick else CAR_MODELS
    scenarios = ALL_SCENARIOS + ["bike"]
    if args.only:
        scenarios = args.only.split(",")
    if args.trace:
        bits = args.trace.split(":")
        sc, md = bits[0], bits[1]
        lua, _ = load(dynamics, botnav)
        lua.execute("TRACE = {}")
        if args.grade is not None:
            lua.globals().BRIDGE_GRADE = args.grade
        r = run_one(lua, sc, md, int(bits[2]) if len(bits) > 2 else 1, bits[3] if len(bits) > 3 else None)
        for line in lua.globals().TRACE.values():
            print(line)
        print(r)
        return 0
    t0 = time.time()
    results = sweep(dynamics, botnav, models, scenarios, args.verbose)
    print(f"bot driving sim: {len(results)} runs ({len(models)} car models + a bike), {time.time() - t0:.0f} s")
    for (scenario, model), r in results.items():
        print(row(scenario, model, r))
    problems = report(results)
    for p in problems:
        print("PROBLEM", p)
    if args.only:
        return 0 if not problems else 1

    caught = 0
    for label, before, after, (scenario, model) in PLANTS:
        if botnav.count(before) != 1:
            print(f"  PLANT NOT APPLIED ({label}): text found {botnav.count(before)} times")
            continue
        planted = botnav.replace(before, after)
        try:
            r = sweep(dynamics, planted, [model], [scenario])[(scenario, model)]
            found = judge(scenario, r)
        except Exception as err:  # an error is a failed run, not a pass
            found = [f"error: {str(err).splitlines()[0]}"]
        caught += bool(found)
        print(f"  plant {'CAUGHT' if found else 'MISSED'}: {label} -> {scenario} {model}: {'; '.join(found) or 'passed'}")
    print(f"planted faults: {caught}/{len(PLANTS)} caught")
    ok = not problems and caught == len(PLANTS)
    print("bot driving sim: " + ("OK" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
