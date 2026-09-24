#!/usr/bin/env python3
"""Oliver: "the two wheeled vehicles are broken" / "the bikes fall over when you drive them".

Runs the REAL ReplicatedStorage/Shared/VehicleDynamics.lua (Rig and Step) for the three bikes in lupa,
on tools/vehicle_stability_sim.py's mocks and ground (road seams, stop lines, bridge deck, grass), with
a rigid body standing in for Roblox physics and the one thing that sim leaves out: the bike's
`Balance` AlignOrientation. That is modelled as Roblox documents it -- PrimaryAxisOnly, OneAttachment:
the attachment's X axis is turned toward the goal CFrame's X axis at a rate set by Responsiveness,
never faster than MaxAngularVelocity, with no more than MaxTorque -- and ONLY while the constraint is
Enabled and has an Attachment0, as in the engine.

Courses, per bike (BananiniScoot, PatapimScrambler, BrrStreetfighter), at 60/240 and 144/60 Hz:
  pull     from rest, full throttle down the road profile
  road     flat out over the road profile
  carve    full lock one way at speed, then the other (a slalom), then straight
  circle   held full lock for four seconds at a middling speed
  crawl    walking pace with the bars swinging, then stop dead
A bike passes when it never leans past its handling's own lean limit plus a margin, never has its
body's up below FLIP_UP_DOT, keeps a wheel on the ground on the road, and gets somewhere.

The planted fault (always run): the balance goal leans the wrong way (targetUp tipped with -lean).
It must fail on every bike, which proves the check can see a bike go over.

Usage:  python3 tools/bike_balance_sim.py [--source PATH] [--verbose]
Exit 0 when the source passes and the planted fault is caught.

Not modelled: the rider's own mass (VehicleService makes riders Massless), tyre/body friction against
the ground beyond a stiff dead contact under the collider box, network ownership (on the client the
same constraint is stepped by the driver's machine), and the exact solver behind Responsiveness.
"""
import argparse
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vehicle_stability_sim as cars  # noqa: E402

# Geometry from VehicleModels.lua: wheel radii and axle Z, and the Chassis hull (size, centre, density),
# the only part with mass. Mounts are the hubs' positions relative to the chassis centre.
BIKES = {
    "BananiniScoot":    dict(fr=0.95, rr=0.95, fz=-2.35, rz=2.15, size=(1.2, 1.5, 4.2), c=(2.05, 0.1), rho=1.6),
    "PatapimScrambler": dict(fr=1.45, rr=1.42, fz=-3.3,  rz=3.05, size=(1.0, 1.6, 5.0), c=(2.6, -0.05), rho=1.5),
    "BrrStreetfighter": dict(fr=1.3,  rr=1.3,  fz=-3.03, rz=2.75, size=(1.1, 1.4, 4.6), c=(2.45, -0.1), rho=1.6),
}

SIM = r"""
local VD = ...
local V = Vector3.new
-- Luau keeps math.atan2; stock Lua 5.4 folded it into math.atan.
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local function mockInstance(className)
	local instance = { __instance = true, ClassName = className, Enabled = true, children = {} }
	instance.FindFirstChild = function(self, name) return self.children[name] end
	return instance
end
Instance = { new = function(className) return mockInstance(className) end }

function buildBike(modelId, g)
	local chassis = mockInstance("Part")
	chassis.Name = "Chassis"
	chassis.Size = V(g.sx, g.sy, g.sz)
	-- findOrMake parents what it makes; keep a name index so a second Rig (the client's) finds them.
	local model = { __instance = true, PrimaryPart = chassis }
	model.GetAttribute = function(_, k) if k == "VehicleModel" then return modelId end end
	local hubs = {}
	for _, spec in ipairs({ { "Wheel_F", g.fr, g.fz, true }, { "Wheel_R", g.rr, g.rz, false } }) do
		local mount = V(0, spec[2] - g.cy, spec[3] - g.cz)
		local joint = { C0 = CFrame.new(mount), C1 = CFrame.identity, Part0 = chassis }
		local hub = { __instance = true, Name = spec[1], attrs = { Radius = spec[2], Front = spec[4], Steer = spec[4] } }
		hub.IsA = function(_, c) return c == "BasePart" end
		hub.GetAttribute = function(self, k) return self.attrs[k] end
		hub.FindFirstChild = function(_, n) if n == "Joint" then return joint end end
		table.insert(hubs, hub)
	end
	model.GetChildren = function() return hubs end
	model.FindFirstChild = function(_, n) if n == "Chassis" then return chassis end end
	chassis.AssemblyMass = g.sx * g.sy * g.sz * g.rho
	chassis.CFrame = CFrame.new(0, g.cy, 0)
	chassis.Position = chassis.CFrame.Position
	chassis.AssemblyLinearVelocity = Vector3.zero
	chassis.AssemblyAngularVelocity = Vector3.zero
	chassis.GetVelocityAtPosition = function(self, p)
		return self.AssemblyLinearVelocity + self.AssemblyAngularVelocity:Cross(p - self.Position)
	end
	local rig = assert(VD.Rig(model), "Rig returned nil")
	assert(rig.bike and rig.balance, "a bike rig without a balance constraint")
	return rig
end

local function orthonormal(c)
	local y = c.y.Unit
	local x = y:Cross(c.z).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(c.p, x, y, z)
end

-- The engine's side of the Balance AlignOrientation (PrimaryAxisOnly, OneAttachment): a torque that
-- turns the attachment's X axis toward the goal's, as a critically damped drive at Responsiveness,
-- toward an angular speed no higher than MaxAngularVelocity, capped at MaxTorque. Yaw about the
-- axis itself is left free.
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
	if s > 1e-6 then
		wanted = turn.Unit * math.min(angle * b.Responsiveness, b.MaxAngularVelocity)
	end
	local free = axis * w:Dot(axis)
	local wPerp = w - free
	local alphaWorld = (wanted - wPerp) * b.Responsiveness
	local alpha = c:VectorToObjectSpace(alphaWorld)
	local torque = c:VectorToWorldSpace(alpha * I)
	if torque.Magnitude > b.MaxTorque then torque = torque.Unit * b.MaxTorque end
	return torque
end

-- opts: speed, time, throttle(t), steer(t), fps, physHz, start
function run(rig, g, opts)
	local ch = rig.chassis
	local mass = ch.AssemblyMass
	local I = rig.inertiaShape * mass
	local s0 = opts.start or 0
	local h0 = groundAt(s0)
	ch.CFrame = CFrame.new(0, h0 + g.cy, -s0)
	ch.Position = ch.CFrame.Position
	ch.AssemblyLinearVelocity = V(0, 0, -(opts.speed or 0))
	ch.AssemblyAngularVelocity = Vector3.zero
	local hullPts = {}
	for _, sx in ipairs({ -1, 1 }) do for _, sy in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
		table.insert(hullPts, V(sx * g.sx / 2, sy * g.sy / 2, sz * g.sz / 2))
	end end end
	local h = 1 / (opts.physHz or 240)
	local frameLength = 1 / (opts.fps or 60)
	local lastLength, frame, clock, due = frameLength, 0, 0, 0
	local out = { t = {}, lean = {}, up = {}, grounded = {}, speed = {}, x = {}, s = {} }
	while clock < (opts.time or 4) do
		frame = frame + 1
		clock = clock + frameLength
		SIM_TIME = clock
		local input = { throttle = opts.throttle(clock), steer = opts.steer(clock), handbrake = false }
		local tel = VD.Step(rig, input, lastLength)
		lastLength = frameLength
		due = due + frameLength
		local steps = math.floor(due / h + 1e-9)
		due = due - steps * h
		for _ = 1, steps do
			local c = ch.CFrame
			local p, v, w = ch.Position, ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity
			local F = V(0, -workspace.Gravity * mass, 0) + rig.downforce.Force
			local T = rig.torque.Torque + balanceTorque(rig, c, w, I)
			for _, wheel in ipairs(rig.wheels) do
				local at = c:PointToWorldSpace(wheel.mount)
				F = F + wheel.force.Force
				T = T + (at - p):Cross(wheel.force.Force)
			end
			-- The collider box against the ground: stiff and dead, with some sliding friction, so a
			-- bike that goes over lies there rather than bouncing back up.
			for _, local_ in ipairs(hullPts) do
				local at = c:PointToWorldSpace(local_)
				local gy = groundAt(alongU(at))
				if at.Y < gy then
					local pv = v + w:Cross(at - p)
					local push = math.max(0, mass * (2000 * (gy - at.Y) - 120 * pv.Y) / 4)
					local flat = V(pv.X, 0, pv.Z)
					local rub = flat.Magnitude > 1e-6 and flat.Unit * -math.min(push * 0.3, flat.Magnitude * mass * 20) or Vector3.zero
					local f = V(0, push, 0) + rub
					F = F + f
					T = T + (at - p):Cross(f)
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
		local c = ch.CFrame
		out.t[frame] = clock
		out.lean[frame] = math.deg(math.asin(math.clamp(-c.x.Y, -1, 1)))
		out.up[frame] = c.y.Y
		out.grounded[frame] = tel.grounded
		out.speed[frame] = ch.AssemblyLinearVelocity:Dot(c.LookVector)
		out.x[frame] = ch.Position.X
		out.s[frame] = -ch.Position.Z
	end
	return out
end
"""

MODES = [(60, 240), (144, 60)]
LEAN_MARGIN = 12      # degrees past the handling's own lean limit that still counts as upright
FLIP_UP_DOT = 0.25    # VehicleDynamics' own "flipped" line


def load(source_text):
    lua = cars.lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(cars.PRELUDE)
    vd = lua.execute(cars.luau_to_lua(source_text))
    lua.execute(SIM, vd)
    return lua, vd


def measure(source_text, verbose=False, modes=None):
    lua, vd = load(source_text)
    set_ground, T, grounds = cars.courses(lua)
    G = lua.globals()
    results = {}
    for model, g in BIKES.items():
        h = vd.Handling[model]
        top = h.topSpeed
        gt = lua.table_from(dict(fr=g["fr"], rr=g["rr"], fz=g["fz"], rz=g["rz"], sx=g["size"][0], sy=g["size"][1],
                                 sz=g["size"][2], cy=g["c"][0], cz=g["c"][1], rho=g["rho"]))
        steer_fns = {
            "straight": lua.eval("function(t) return 0 end"),
            "slalom": lua.eval("function(t) if t < 1 then return 0 elseif t < 2.5 then return 1 elseif t < 4 then return -1 elseif t < 5 then return 1 end return 0 end"),
            "circle": lua.eval("function(t) if t < 0.5 then return 0 end return 1 end"),
            "swing": lua.eval("function(t) return math.sin(t * 2.5) end"),
        }
        full = lua.eval("function(t) return 1 end")
        half = lua.eval("function(t) return 0.5 end")
        crawl = lua.eval("function(t) if t < 3 then return 0.15 end return -0.6 end")
        r = {}
        for fps, phys in modes or MODES:
            tag = f"{fps}/{phys}"
            plan = [
                ("pull", "road", dict(start=-30, speed=0, time=6, throttle=full, steer=steer_fns["straight"])),
                ("road", "road", dict(start=-30, speed=top * 0.97, time=5, throttle=full, steer=steer_fns["straight"])),
                ("carve", "flat", dict(start=0, speed=top * 0.6, time=6, throttle=half, steer=steer_fns["slalom"])),
                ("circle", "flat", dict(start=0, speed=35, time=4.5, throttle=half, steer=steer_fns["circle"])),
                ("crawl", "flat", dict(start=0, speed=0, time=5, throttle=crawl, steer=steer_fns["swing"])),
            ]
            for name, course, opts in plan:
                set_ground(T(*grounds[course]))
                rig = G.buildBike(model, gt)
                opts.update(fps=fps, physHz=phys)
                out = G.run(rig, gt, lua.table_from(opts))
                n = len(out.t)
                settle = next(i for i in range(1, n + 1) if out.t[i] >= 0.5)
                span = range(settle, n + 1)
                # Path length, not start-to-end: a circle ends where it began.
                dist = sum(math.hypot(out.x[i] - out.x[i - 1], out.s[i] - out.s[i - 1]) for i in range(2, n + 1))
                r[f"{name} {tag}"] = dict(
                    max_lean=max(abs(out.lean[i]) for i in span), min_up=min(out.up[i] for i in span),
                    airborne=sum(1 for i in span if out.grounded[i] == 0) / len(span),
                    dist=dist, top=max(out.speed[i] for i in span), limit=h.lean)
        results[model] = r
        if verbose:
            for key, c in r.items():
                print(model, key, {k: round(v, 2) if isinstance(v, float) else v for k, v in c.items()})
    return results


def judge(results):
    problems = []
    examined = 0
    for model, r in results.items():
        for key, c in r.items():
            examined += 1
            if c["min_up"] < FLIP_UP_DOT:
                problems.append(f"{model} {key}: fell over (body up {c['min_up']:.2f})")
            elif c["max_lean"] > c["limit"] + LEAN_MARGIN:
                problems.append(f"{model} {key}: leaned {c['max_lean']:.0f} deg, past its {c['limit']} deg limit")
            if key.startswith(("road", "pull")) and c["airborne"] > 0:
                problems.append(f"{model} {key}: both wheels off the road {c['airborne'] * 100:.0f}% of the time")
            if c["dist"] < (8 if key.startswith("crawl") else 60):
                problems.append(f"{model} {key}: only covered {c['dist']:.0f} studs")
    return problems, examined


def table(results):
    lines = []
    for model, r in results.items():
        lines.append(model)
        for key, c in r.items():
            lines.append(f"  {key:14} lean max {c['max_lean']:5.1f} (limit {c['limit']})  up min {c['min_up']:5.2f}  "
                         f"air {c['airborne'] * 100:4.1f}%  dist {c['dist']:6.0f}  top {c['top']:5.1f}")
    return "\n".join(lines)


# The planted fault: the balance goal tipped the wrong way, so the constraint leans a bike OUT of
# its turn. Aimed at the invariant ("a bike being ridden stays upright"), whatever computes the goal.
PLANT = [("local targetUp = CFrame.fromAxisAngle(flatForward, rig.lean):VectorToWorldSpace(rig.groundUp)",
          "local targetUp = CFrame.fromAxisAngle(flatForward, -rig.lean * 3):VectorToWorldSpace(rig.groundUp)")]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", default=cars.SOURCE)
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
    caught = sorted({p.split()[0] for p in planted_problems if "fell over" in p or "leaned" in p})
    print(f"planted fault (balance leaning the wrong way): caught on {len(caught)}/{len(BIKES)} bikes")
    ok = not problems and len(caught) == len(BIKES)
    print(f"{examined} runs examined ({len(BIKES)} bikes), {len(problems)} problems: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
