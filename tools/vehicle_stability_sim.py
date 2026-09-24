#!/usr/bin/env python3
"""#84 / #109: do the cars stay planted on roads, seams, a bridge deck and grass at top speed?

Runs the REAL ReplicatedStorage/Shared/VehicleDynamics.lua (Rig and Step, unmodified apart from
Luau's compound assignments being spelled out for stock Lua) inside lupa, against mocks of Vector3,
CFrame and workspace:Raycast, and a small rigid-body integrator standing in for Roblox physics:
240 Hz substeps with the VectorForces held between 60 Hz Step calls, the way the engine does it.

The ground is an exact profile along the direction of travel: terrain (Grass), road slabs laid
MapDecor.RoadLift (0.4) proud and not collidable, slab joins with a z-fight stagger and a hairline
gap, 0.07-proud stop lines (MapDecor.MarkRaise), a collidable bridge deck with a step at each end,
and grass off the end of the road. The ray test is exact, including the SIDE faces of every slab,
so a ray tilted by body pitch that meets a slab's edge reports the side face's normal, as Roblox does.

Courses, per car model (Rotster, CrocodiloRanger, TralalaGT, SahurVan):
  road   flat out along the whole profile        must stay planted: never airborne, no big jolts
  jump   off a 12-degree ramp's end at 60 st/s   must fly (airtime) and land without re-launching
  flip   a hard roll kick on the flat            must still roll past 90 degrees

The planted fault (always run): a pogo-stick bump stop and load cap. It must fail `road` for
every model, which proves the check can see a car leave the ground. Aimed at the invariant
("a car at top speed over road seams never leaves the ground"), not at the old bug, so it stays
valid after the fix.

Usage:  python3 tools/vehicle_stability_sim.py [--source PATH] [--verbose]
Exit 0 when the real source passes every course and the planted fault is caught.

Not modelled (say so, don't assume): bikes (their balance is an AlignOrientation; see
tools/bike_balance_sim.py, which reuses this file's mocks and ground), network ownership, tyre/body
collision friction, lateral steering.
"""
import argparse
import math
import os
import re
import sys

from lupa import lua54

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleDynamics.lua")

# Geometry from VehicleModels.lua (wheel radius r, half track, axle Z, chassis hull size and centre
# height above the ground the model is built on). The dynamics only ever see these through the rig.
MODELS = {
    "Rotster":         dict(r=1.3,  track=2.85, fz=-4.2,  rz=4.3,  size=(6.1, 2.1, 12.6), cy=2.3),
    "CrocodiloRanger": dict(r=1.75, track=3.2,  fz=-4.9,  rz=4.6,  size=(6.9, 2.5, 14.6), cy=3.35),
    "TralalaGT":       dict(r=1.35, track=2.93, fz=-4.45, rz=4.55, size=(6.7, 1.8, 14.2), cy=1.95),
    "SahurVan":        dict(r=1.45, track=3.0,  fz=-4.3,  rz=4.4,  size=(6.8, 3.2, 13.8), cy=3.1),
}

PRELUDE = r"""
local sqrt, abs, cos, sin = math.sqrt, math.abs, math.cos, math.sin
math.clamp = function(x, a, b) if x < a then return a elseif x > b then return b end return x end
table.clone = function(t) local c = {} for k, v in pairs(t) do c[k] = v end return c end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
SIM_TIME = 0
tick = function() return SIM_TIME end
typeof = function(v) if type(v) == "table" and v.__instance then return "Instance" end return type(v) end

local V3 = {}
V3.__index = function(v, k)
	if k == "X" then return v[1] elseif k == "Y" then return v[2] elseif k == "Z" then return v[3]
	elseif k == "Magnitude" then return sqrt(v[1]*v[1] + v[2]*v[2] + v[3]*v[3])
	elseif k == "Unit" then local m = sqrt(v[1]*v[1] + v[2]*v[2] + v[3]*v[3]); if m == 0 then return v end return setmetatable({v[1]/m, v[2]/m, v[3]/m}, V3)
	end
	return V3[k]
end
local function vec(x, y, z) return setmetatable({x, y, z}, V3) end
V3.__add = function(a, b) return vec(a[1]+b[1], a[2]+b[2], a[3]+b[3]) end
V3.__sub = function(a, b) return vec(a[1]-b[1], a[2]-b[2], a[3]-b[3]) end
V3.__unm = function(a) return vec(-a[1], -a[2], -a[3]) end
V3.__mul = function(a, b)
	if type(a) == "number" then return vec(a*b[1], a*b[2], a*b[3]) end
	if type(b) == "number" then return vec(a[1]*b, a[2]*b, a[3]*b) end
	return vec(a[1]*b[1], a[2]*b[2], a[3]*b[3])
end
V3.__div = function(a, b) return vec(a[1]/b, a[2]/b, a[3]/b) end
V3.Dot = function(a, b) return a[1]*b[1] + a[2]*b[2] + a[3]*b[3] end
V3.Cross = function(a, b) return vec(a[2]*b[3]-a[3]*b[2], a[3]*b[1]-a[1]*b[3], a[1]*b[2]-a[2]*b[1]) end
V3.Lerp = function(a, b, t) return a + (b - a) * t end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end, zero = vec(0, 0, 0) }

-- CFrame: position p and rotation columns x (right), y (up), z (back); LookVector = -z.
local CF = {}
local function cf(p, x, y, z) return setmetatable({p = p, x = x, y = y, z = z}, CF) end
CF.__index = function(c, k)
	if k == "Position" then return c.p elseif k == "UpVector" then return c.y
	elseif k == "LookVector" then return -c.z elseif k == "RightVector" then return c.x
	elseif k == "X" then return c.p[1] elseif k == "Y" then return c.p[2] elseif k == "Z" then return c.p[3] end
	return CF[k]
end
CF.VectorToWorldSpace = function(c, v) return c.x * v[1] + c.y * v[2] + c.z * v[3] end
CF.PointToWorldSpace = function(c, v) return c.p + c.x * v[1] + c.y * v[2] + c.z * v[3] end
CF.VectorToObjectSpace = function(c, v) return vec(c.x:Dot(v), c.y:Dot(v), c.z:Dot(v)) end
CF.PointToObjectSpace = function(c, v) return c:VectorToObjectSpace(v - c.p) end
CF.Inverse = function(c)
	local x, y, z = c.x, c.y, c.z
	local rx, ry, rz = vec(x[1], y[1], z[1]), vec(x[2], y[2], z[2]), vec(x[3], y[3], z[3])
	local inv = cf(vec(0, 0, 0), rx, ry, rz)
	inv.p = -inv:VectorToWorldSpace(c.p)
	return inv
end
CF.__mul = function(a, b)
	if getmetatable(b) == V3 then return a:PointToWorldSpace(b) end
	return cf(a:PointToWorldSpace(b.p), a:VectorToWorldSpace(b.x), a:VectorToWorldSpace(b.y), a:VectorToWorldSpace(b.z))
end
local function axisAngle(axis, angle)
	local u = axis.Unit
	local c, s, t = cos(angle), sin(angle), 1 - cos(angle)
	local function rot(v) return v * c + u:Cross(v) * s + u * (u:Dot(v) * t) end
	return cf(vec(0, 0, 0), rot(vec(1, 0, 0)), rot(vec(0, 1, 0)), rot(vec(0, 0, 1)))
end
CFrame = {
	identity = cf(vec(0, 0, 0), vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1)),
	new = function(a, b, c)
		local p = type(a) == "number" and vec(a, b, c) or a
		return cf(p, vec(1, 0, 0), vec(0, 1, 0), vec(0, 0, 1))
	end,
	fromAxisAngle = axisAngle,
	Angles = function(rx, ry, rz)
		return axisAngle(vec(1, 0, 0), rx) * axisAngle(vec(0, 1, 0), ry) * axisAngle(vec(0, 0, 1), rz)
	end,
	fromMatrix = function(p, x, y, z)
		z = z or x:Cross(y)
		return cf(p, x, y, z)
	end,
	lookAt = function(at, target)
		local look = (target - at).Unit
		local x = look:Cross(vec(0, 1, 0)).Unit
		local y = x:Cross(look)
		return cf(at, x, y, -look)
	end,
}

local enumMeta = { __index = function(t, k) return k end }
Enum = setmetatable({}, { __index = function(t, k) local e = setmetatable({}, enumMeta); rawset(t, k, e); return e end })
RaycastParams = { new = function() return {} end }
Instance = { new = function(className) return { __instance = true, ClassName = className } end }

-- The ground: pieces along s (= -Z, the direction of travel), each { s0, s1, h0, h1, part }.
GROUND = {}
-- The profile runs along U (horizontal, unit); U = (0, 0, -1) is straight down the road.
GROUND_U = vec(0, 0, -1)
function alongU(p) return p[1] * GROUND_U[1] + p[3] * GROUND_U[3] end
local function heightIn(piece, s) return piece[3] + (piece[4] - piece[3]) * (s - piece[1]) / (piece[2] - piece[1]) end
local function topNormal(piece)
	local slope = (piece[4] - piece[3]) / (piece[2] - piece[1])   -- dh/ds; s = -z
	return (vec(0, 1, 0) - GROUND_U * slope).Unit
end
function groundAt(s)
	for _, piece in ipairs(GROUND) do
		if s >= piece[1] and s < piece[2] then return heightIn(piece, s), piece end
	end
	return 0, nil
end

workspace = { Gravity = 196.2 }
function workspace:Raycast(origin, direction, params)
	local o_s, o_y = alongU(origin), origin[2]
	local d_s, d_y = alongU(direction), direction[2]
	local best = nil
	for _, piece in ipairs(GROUND) do
		local ta, tb
		if abs(d_s) < 1e-9 then
			if o_s >= piece[1] and o_s < piece[2] then ta, tb = 0, 1 end
		else
			local t0, t1 = (piece[1] - o_s) / d_s, (piece[2] - o_s) / d_s
			if t0 > t1 then t0, t1 = t1, t0 end
			ta, tb = math.max(t0, 0), math.min(t1, 1)
			if ta > tb then ta = nil end
		end
		if ta and (not best or ta < best.t) then
			local fa = (o_y + d_y * ta) - heightIn(piece, o_s + d_s * ta)
			local fb = (o_y + d_y * tb) - heightIn(piece, o_s + d_s * tb)
			local t, normal = nil, nil
			if fa <= 0 then
				t = ta
				-- Entered through a side face (or started inside: then call it the top).
				normal = ta > 0 and GROUND_U * (d_s > 0 and -1 or 1) or topNormal(piece)
			elseif fb <= 0 then
				t = ta + (tb - ta) * fa / (fa - fb)
				normal = topNormal(piece)
			end
			if t and (not best or t < best.t) then best = { t = t, normal = normal, part = piece[5] } end
		end
	end
	if not best then return nil end
	local len = direction.Magnitude
	return { Instance = best.part, Position = origin + direction * best.t, Normal = best.normal,
		Distance = best.t * len, Material = best.part.Material }
end

local function part(material, props)
	local p = { __instance = true, Material = material, CanCollide = props.collide, Anchored = true,
		Transparency = 0, Size = vec(40, props.thick or 0.4, 40), terrain = props.terrain }
	p.IsA = function(self, class) return (class == "Terrain" and self.terrain) or class == "BasePart" end
	p.FindFirstAncestorOfClass = function() return nil end
	return p
end
PARTS = {
	grass = part("Grass", { collide = true, terrain = true }),
	road = part("Asphalt", { collide = false }),
	line = part("SmoothPlastic", { collide = false, thick = 0.07 }),
	deck = part("Concrete", { collide = true, thick = 1.2 }),
}
"""

SIM = r"""
local VD = ...
local V = Vector3.new

function buildCar(modelId, g)
	local chassis = { __instance = true, Name = "Chassis", Size = V(g.sx, g.sy, g.sz), children = {} }
	chassis.FindFirstChild = function(self, name) return self.children[name] end
	local model = { __instance = true, PrimaryPart = chassis }
	model.GetAttribute = function(_, k) if k == "VehicleModel" then return modelId end end
	local hubs = {}
	for _, spec in ipairs({ { "WheelFL", -1, true }, { "WheelFR", 1, true }, { "WheelRL", -1, false }, { "WheelRR", 1, false } }) do
		local z = spec[3] and g.fz or g.rz
		local mount = V(spec[2] * g.track, g.r - g.cy, z)
		local joint = { C0 = CFrame.new(mount), C1 = CFrame.identity, Part0 = chassis }
		local hub = { __instance = true, Name = spec[1], attrs = { Radius = g.r, Front = spec[3], Steer = spec[3] } }
		hub.IsA = function(_, c) return c == "BasePart" end
		hub.GetAttribute = function(self, k) return self.attrs[k] end
		hub.FindFirstChild = function(_, n) if n == "Joint" then return joint end end
		table.insert(hubs, hub)
	end
	model.GetChildren = function() return hubs end
	model.FindFirstChild = function(_, n) if n == "Chassis" then return chassis end end
	chassis.AssemblyMass = g.sx * g.sy * g.sz * 1.3
	chassis.CFrame = CFrame.new(0, g.cy, 0)
	chassis.Position = chassis.CFrame.Position
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	chassis.GetVelocityAtPosition = function(self, p)
		return self.AssemblyLinearVelocity + self.AssemblyAngularVelocity:Cross(p - self.Position)
	end
	local rig = assert(VD.Rig(model), "Rig returned nil")
	return rig
end

local function orthonormal(c)
	local y = c.y.Unit
	local x = y:Cross(c.z).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(c.p, x, y, z)
end

-- One run. Returns per-frame samples in a table the Python side reduces.
function run(rig, g, opts)
	local ch = rig.chassis
	local mass = ch.AssemblyMass
	local I = rig.inertiaShape * mass
	local s0 = opts.start or 0
	local h0 = groundAt(s0)
	ch.CFrame = CFrame.new(0, h0 + g.cy + (opts.lift or 0), -s0)
	ch.Position = ch.CFrame.Position
	ch.AssemblyLinearVelocity = V(0, 0, -(opts.speed or 0))
	ch.AssemblyAngularVelocity = Vector3.zero
	local hullPts = {}
	for _, sx in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
		table.insert(hullPts, V(sx * g.sx / 2, -g.sy / 2, sz * g.sz / 2))
	end end
	local h = 1 / 240
	local out = { t = {}, s = {}, vy = {}, grounded = {}, up = {}, roll = {}, y = {}, hull = 0 }
	-- Frames: `fps` sets how many physics substeps (240 Hz) each frame spans; `jitter` varies it at
	-- random (a hitching client). Stepped hands Step the PREVIOUS frame's length, as Roblox does.
	-- Frames and physics steps are scheduled separately, as in Roblox: a frame lasts 1/fps (varied
	-- at random by `jitter`, a hitching client) and runs however many whole physics steps of
	-- 1/physHz have come due, which may be none at all when frames outpace the physics. Step sees
	-- the PREVIOUS frame's length, which is what Stepped hands it.
	h = 1 / (opts.physHz or 240)
	local frameLength = 1 / (opts.fps or 60)
	local seed, lastLength, frame, clock, due = 12345, frameLength, 0, 0, 0
	while clock < (opts.time or 4) do
		frame = frame + 1
		local length = frameLength
		if (opts.jitter or 0) > 0 then
			seed = (seed * 1103515245 + 12345) % 2147483648
			length = frameLength * math.max(0.25, 1 + (seed / 2147483648 - 0.5) * 2 * opts.jitter)
		end
		clock = clock + length
		SIM_TIME = clock
		local input = { throttle = opts.throttle or 1, steer = 0, handbrake = false }
		if opts.kick and frame == opts.kick then
			ch.AssemblyAngularVelocity = ch.AssemblyAngularVelocity + ch.CFrame.LookVector * opts.kickRate
			ch.AssemblyLinearVelocity = ch.AssemblyLinearVelocity + V(0, opts.kickUp or 0, 0)
		end
		local tel = VD.Step(rig, input, lastLength)
		lastLength = length
		due = due + length
		local steps = math.floor(due / h + 1e-9)
		due = due - steps * h
		for _ = 1, steps do
			local c = ch.CFrame
			local p, v, w = ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity
			local F = V(0, -workspace.Gravity * mass, 0) + rig.downforce.Force
			local T = rig.torque.Torque
			for _, wheel in ipairs(rig.wheels) do
				local at = c:PointToWorldSpace(wheel.mount)
				F = F + wheel.force.Force
				T = T + (at - p):Cross(wheel.force.Force)
			end
			-- Hull against collidable ground: a stiff, dead contact (elasticity 0), counted.
			for _, local_ in ipairs(hullPts) do
				local at = c:PointToWorldSpace(local_)
				local gy, piece = groundAt(alongU(at))
				if piece and piece[5].CanCollide and at.Y < gy then
					local pv = v + w:Cross(at - p)
					-- Elasticity 0 (VehicleModels' hull): damped hard both ways, so it never springs back.
					local push = math.max(0, mass * (2000 * (gy - at.Y) - 120 * pv.Y) / #hullPts)
					F = F + V(0, push, 0)
					T = T + (at - p):Cross(V(0, push, 0))
					out.hull = out.hull + 1
				end
			end
			v = v + F * (h / mass)
			local wb = c:VectorToObjectSpace(w)
			local tb = c:VectorToObjectSpace(T)
			local Iw = wb * I
			local dw = (tb - wb:Cross(Iw)) * V(1 / I.X, 1 / I.Y, 1 / I.Z)
			wb = wb + dw * h
			w = c:VectorToWorldSpace(wb)
			local nc = c
			if w.Magnitude > 1e-9 then
				local rot = CFrame.fromAxisAngle(w, w.Magnitude * h)
				nc = CFrame.fromMatrix(Vector3.zero, rot:VectorToWorldSpace(c.x), rot:VectorToWorldSpace(c.y), rot:VectorToWorldSpace(c.z))
			end
			nc = orthonormal(CFrame.fromMatrix(p + v * h, nc.x, nc.y, nc.z))
			ch.CFrame, ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity = nc, nc.p, v, w
		end
		out.t[frame] = SIM_TIME
		out.s[frame] = -ch.Position.Z
		out.vy[frame] = ch.AssemblyLinearVelocity.Y
		out.grounded[frame] = tel.grounded
		out.up[frame] = ch.CFrame.UpVector.Y
		out.roll[frame] = ch.CFrame.RightVector.Y
		out.y[frame] = ch.Position.Y
	end
	return out
end
"""


def luau_to_lua(src):
    """Spell out Luau's compound assignments (x += y) for stock Lua."""
    out = []
    for line in src.splitlines():
        m = re.match(r"^(\s*)([\w\.\[\]\"]+)\s*(\+|-|\*|/)=\s*(.+)$", line)
        if m and not line.strip().startswith("--"):
            indent, target, op, rest = m.groups()
            line = f"{indent}{target} = {target} {op} ({rest})"
        out.append(line)
    return "\n".join(out)


def courses(lua):
    set_ground = lua.eval("function(t, ux, uz) GROUND = t; GROUND_U = Vector3.new(ux or 0, 0, uz or -1) end")
    P = lua.globals().PARTS
    T = lua.table

    def piece(s0, s1, h0, h1, p):
        return T(s0, s1, h0, h1, p)

    road = []
    s = -40.0
    road.append(piece(-200, s, 0, 0, P.grass))
    # 8-stud slabs, z-fight stagger of 0.01 between neighbours, a 0.05 hairline gap every third join.
    index = 0
    while s < 120:
        top = 0.4 + (0.01 if index % 2 else 0)
        end = s + 8
        road.append(piece(s, end, top, top, P.road))
        s = end
        if index % 3 == 2:
            road.append(piece(s, s + 0.05, 0, 0, P.grass))
            s += 0.05
        index += 1
    # Two stop lines, 0.07 proud, a stud wide.
    for at in (40, 88):
        for i, p_ in enumerate(road):
            if p_[1] <= at < p_[2] and p_[5] == P.road:
                top = p_[3]
                a, b = p_[1], p_[2]
                road[i:i + 1] = [piece(a, at, top, top, P.road), piece(at, at + 1, top + 0.07, top + 0.07, P.line),
                                 piece(at + 1, b, top, top, P.road)]
                break
    # Bridge deck: a collidable deck whose top stands 0.3 proud of the road, 40 long.
    road.append(piece(s, s + 40, 0.7, 0.7, P.deck))
    s += 40
    road.append(piece(s, s + 60, 0.4, 0.4, P.road))
    s += 60
    # Off the end of the road onto grass, then back up onto a road.
    road.append(piece(s, s + 80, 0, 0, P.grass))
    s += 80
    road.append(piece(s, s + 400, 0.4, 0.4, P.road))

    jump = [piece(-200, 30, 0, 0, P.grass),
            piece(30, 44, 0, 14 * math.tan(math.radians(20)), P.grass),
            piece(44, 900, 0, 0, P.grass)]
    flat = [piece(-200, 800, 0, 0, P.grass)]
    edge = [piece(-400, 15, 0, 0, P.grass), piece(15, 39, 0.4, 0.4, P.road), piece(39, 60, 0, 0, P.grass),
            piece(60, 84, 0.4, 0.4, P.road), piece(84, 800, 0, 0, P.grass)]
    return set_ground, T, {"road": road, "jump": jump, "flat": flat, "edge": edge}


def load(source_text):
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(PRELUDE)
    vd = lua.execute(luau_to_lua(source_text))
    lua.execute(SIM, vd)
    return lua, vd


def measure(source_text, verbose=False, modes=None):
    lua, vd = load(source_text)
    set_ground, T, grounds = courses(lua)
    G = lua.globals()
    results = {}
    for model, g in MODELS.items():
        top = vd.Handling[model].topSpeed
        gt = lua.table_from(dict(r=g["r"], track=g["track"], fz=g["fz"], rz=g["rz"],
                                 sx=g["size"][0], sy=g["size"][1], sz=g["size"][2], cy=g["cy"]))
        r = {}

        def flat_out(course, mode, ux=0.0, uz=-1.0):
            fps, jitter, phys = mode
            set_ground(T(*grounds[course]), ux, uz)
            rig = G.buildCar(model, gt)
            out = G.run(rig, gt, lua.table_from(dict(start=-30, speed=top * 0.97, time=5.5, throttle=1,
                                                     fps=fps, jitter=jitter, physHz=phys)))
            n = len(out.t)
            settle = next(i for i in range(1, n + 1) if out.t[i] >= 0.75)  # the car finding its ride height
            span = range(settle + 1, n + 1)
            # A jolt is the change in vertical speed over a 60th of a second, whatever the frame rate.
            jolt = max(abs(out.vy[i] - out.vy[i - 1]) / max(out.t[i] - out.t[i - 1], 1 / 60) / 60 for i in span)
            return dict(max_vy=max(abs(out.vy[i]) for i in span), max_jolt=jolt,
                        airborne=sum(out.t[i] - out.t[i - 1] for i in span if out.grounded[i] == 0),
                        wheel_off=sum(1 for i in span if out.grounded[i] < 4) / len(span),
                        dist=out.s[n] - out.s[settle + 1], hull=out.hull)

        for mode in modes or MODES:
            tag = "%d/%d%s" % (mode[0], mode[2], "j" if mode[1] else "")
            # Flat out along the road: seams, a hairline gap, stop lines, the bridge deck, off onto
            # grass and back up onto a road.
            r[f"road {tag}"] = flat_out("road", mode)
            # Across road edges at a shallow angle (on and off a 24-wide road twice): one side's tyres
            # climb the 0.4 edge before the other's, and a ray tilted by the roll can meet the edge's side.
            for deg in EDGE_ANGLES:
                a = math.radians(deg)
                r[f"edge{deg} {tag}"] = flat_out("edge", mode, -math.cos(a), -math.sin(a))

        # A real jump: off the end of a 20-degree kicker at 70 studs/s.
        set_ground(T(*grounds["jump"]))
        rig = G.buildCar(model, gt)
        out = G.run(rig, gt, lua.table_from(dict(start=0, speed=70, time=4, throttle=0.5)))
        n = len(out.t)
        runs, cur = [], 0
        for i in range(1, n + 1):
            if out.grounded[i] == 0:
                cur += 1
            elif cur:
                runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
        r["jump"] = dict(air=(runs[0] if runs else 0) / 60, relaunch=(max(runs[1:]) if len(runs) > 1 else 0) / 60,
                         landed=out.grounded[n] == 4, min_up=min(out.up[i] for i in range(1, n + 1)))

        # A hard flip: a blast's worth of lift and roll on the flat. It must still go over.
        set_ground(T(*grounds["flat"]))
        rig = G.buildCar(model, gt)
        out = G.run(rig, gt, lua.table_from(dict(start=0, speed=30, time=3, throttle=0, kick=30, kickRate=-40, kickUp=40)))
        r["flip"] = dict(min_up=min(out.up[i] for i in range(1, len(out.t) + 1)))
        results[model] = r
        if verbose:
            print(model, r)
    return results


# Frame rate / physics rate pairs the flat-out courses run at: a steady 60 Hz client, a slow 30 Hz
# one, a hitching one, and a fast screen over 60 Hz physics (a frame with no physics step under it).
MODES = [(60, 0, 240), (30, 0, 240), (60, 0.6, 240), (144, 0, 60)]
EDGE_ANGLES = (10, 30)
# The bar for "stays planted". VehicleClient reports a jolt past 20 studs/s in a frame; a car on a
# road should be nowhere near it. Measured after the fix, worst of every model and mode: jolt 3.3,
# vertical speed 4.2, no airborne time at all.
MAX_JOLT = 6.0
MAX_VY = 7.0


def judge(results):
    problems = []
    examined = 0
    for model, r in results.items():
        for key, c in r.items():
            if not key.startswith(("road", "edge")):
                continue
            examined += 1
            if c["airborne"] > 0:
                problems.append(f"{model} {key}: all four wheels off the ground for {c['airborne']:.2f} s")
            if c["max_jolt"] > MAX_JOLT:
                problems.append(f"{model} {key}: vertical jolt {c['max_jolt']:.2f} studs/s per 60th > {MAX_JOLT}")
            if c["max_vy"] > MAX_VY:
                problems.append(f"{model} {key}: vertical speed {c['max_vy']:.2f} > {MAX_VY}")
            if c["dist"] < 200:
                problems.append(f"{model} {key}: only covered {c['dist']:.0f} studs")
        jump = r["jump"]
        examined += 2
        if jump["air"] < 0.2:
            problems.append(f"{model} jump: only {jump['air']:.2f} s of air off a real kicker")
        if jump["relaunch"] > 0.1:
            problems.append(f"{model} jump: thrown back into the air for {jump['relaunch']:.2f} s after landing")
        if not jump["landed"] or jump["min_up"] < 0.5:
            problems.append(f"{model} jump: did not land wheels-down (min up {jump['min_up']:.2f})")
        if r["flip"]["min_up"] > 0:
            problems.append(f"{model} flip: a hard blast no longer rolls it (min up {r['flip']['min_up']:.2f})")
    return problems, examined


def table(results):
    lines = []
    for model, r in results.items():
        lines.append(f"{model}")
        for key, c in r.items():
            if key.startswith(("road", "edge")):
                lines.append(f"  {key:18} air {c['airborne']:.2f}s  wheel-off {c['wheel_off'] * 100:5.1f}%  "
                             f"max|vy| {c['max_vy']:6.2f}  jolt {c['max_jolt']:6.2f}  hull {c['hull']}")
        j = r["jump"]
        lines.append(f"  jump               air {j['air']:.2f}s  relaunch {j['relaunch']:.2f}s  landed {j['landed']}"
                     f"  | flip min up {r['flip']['min_up']:.2f}")
    return "\n".join(lines)


# The planted fault, always run: a damper that pushes the wrong way (feeds energy in instead of
# taking it out). Aimed at the invariant, "a car at top speed on a road never leaves the ground",
# not at the old bug, so it stays a valid test whatever the damper is computed from.
PLANT = [("load = preload + k * (wheel.compression - h.travelDown) + damper * compressionSpeed",
          "load = preload + k * (wheel.compression - h.travelDown) - damper * compressionSpeed")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()
    with open(args.source, encoding="utf-8") as handle:
        text = handle.read()

    print(f"source: {args.source}")
    results = measure(text, args.verbose)
    print(table(results))
    problems, examined = judge(results)
    for p in problems:
        print("PROBLEM", p)

    planted = text
    for before, after in PLANT:
        if before not in planted:
            print(f"PLANT could not be applied ({before!r} not in source): update the planted fault")
            return 1
        planted = planted.replace(before, after)
    planted_problems, _ = judge(measure(planted, modes=[MODES[0]]))
    caught = sorted({p.split()[0] for p in planted_problems if " road " in p or " edge" in p})
    print(f"planted fault (damper pushing the wrong way): caught on {len(caught)}/{len(MODELS)} models")
    ok = not problems and len(caught) == len(MODELS)
    print(f"{examined} runs examined ({len(MODELS)} models), {len(problems)} problems: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
