#!/usr/bin/env python3
"""Bug test of all-wheel drive (47200d3: "All-wheel drive for every car; load-following centre split").

Runs the REAL ReplicatedStorage/Shared/VehicleDynamics.lua in lupa, the way the existing vehicle sims
do (tools/vehicle_stability_sim.py's Vector3/CFrame/ray mocks and 240 Hz rigid-body integrator,
tools/car_bounce_audit_sim.py's per-model geometry and density read from VehicleModels.lua,
tools/bike_balance_sim.py's bikes). Those tools are imported, not edited.

Three parts:

  split   The centre split and the per-wheel drive as pure functions. VehicleDynamics.DriveSplit and
          the drive lines of Step are cut out of the source text as they are and run over a grid of
          wheel loads, grounded patterns and drive requests, for a four-wheel car and a rear-drive bike.
          Invariants (any break fails the check):
            S1 DriveSplit stays in 0..1, is finite, never falls as the front takes more of the load,
               gives the front none when the front is up and all of it when only the front is down;
            S2 every wheel's drive is finite (loads as Step can produce them: 0..maxLoad);
            S3 no wheel pushes against the request (reverse stays reverse);
            S4 the drive handed out never exceeds the drive asked for (the split creates nothing);
            S5 no car wheel takes more than half the drive asked for (the fling guard);
            S6 a bike's front is never driven, and its rear takes all of it when down;
            S7 whenever a driven wheel is down with load, some drive reaches the ground.
          Reported, not failed: how often and how much drive is LOST (asked for, handed to nobody),
          and the jump in the split as the last rear wheel leaves the ground.

  step    Whole-step runs per model, main against the tree before AWD (47200d3^): flat 0-60% and
          0-95% times and the top speed reached, reverse, braking, parked rest (flat and a slope),
          turning (a power corner, a lift-off corner, a full-lock crawl like the bot's corners, a
          step steer at 90% of top), the steepest grass grade climbed from a standstill, and a jump
          landed on the throttle. Invariants:
            W1 flat 0-60% and 0-95% times and the top speed reached within 5% of before (the tolerance
               of tools/vehicle_awd_check.py); past 1%, the commit's own claim, is printed as a FINDING;
            W2 reverse speed and 0-90% reverse time, the same;
            W3 braking and parked rest identical to before (no drive is asked for, so AWD must not
               touch them);
            W4 bikes and scooters identical to before, every number of tools/bike_balance_sim.py.
          Everything else is reported as a before -> after table; the judgement is the report's.

  bot     (--bot) tools/bot_driving_sim.py's lap, run on this tree as it is, with the VehicleDynamics
          from before AWD, with only the split put back to the load share, and with only the fling
          guard off. Says which part of 47200d3 turns the lap red. Reported, not gated.

--plant runs the planted faults: each breaks one invariant in a copy of the main source and must
FAIL. They are aimed at what the drive split must refuse forever, not at any bug found here.

Usage:  python3 tools/awd_bugtest_check.py [--plant] [--bot] [--pre PATH] [--quick]
Exit 0 when every invariant holds on this tree (and, with --plant, every planted fault is caught).

Not modelled (say so): network ownership, tyre/body collision friction, Roblox's own solver. Every
number here is the lupa integrator's. tools/awd_bugtest_probe.lua runs the crawl, jump and drag runs
with Roblox's physics; it needs a real Play test with a client, which is the coordinator's to run.
"""
import argparse
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vehicle_stability_sim as vss  # noqa: E402
import car_bounce_audit_sim as cba  # noqa: E402  (read_cars / to_sim only)
import bike_balance_sim as bbs  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleDynamics.lua")
PRE_REF = "47200d3^"

# ---------------------------------------------------------------------------------------------
# Part 1: the split, cut out of the source
# ---------------------------------------------------------------------------------------------

SKIP_LINE = "if not wheel.grounded or wheel.load <= 0 then"


def cut_split(src):
    """The source's own DriveSplit and drive lines, wrapped as DISTRIBUTE(wheels, driveAccel, mass)."""
    consts = "\n".join(re.search(rf"^local {name} = [^\n]*", src, re.M).group(0)
                       for name in ("FRONT_SPLIT", "MAX_WHEEL_SHARE"))
    start = src.index("function VehicleDynamics.DriveSplit(")
    fn = src[start:src.index("\nend\n", start) + 5]
    b0 = src.index("\tlocal drivenGrounded, drivenCount")
    b1 = src.index("\n", src.index("local wheelCap", b0))
    block = src[b0:b1]
    assert SKIP_LINE in src, "Step's skip for a wheel off the ground moved: update cut_split"
    d = re.search(r"\n(\t+)if wheel\.drive and driveAccel ~= 0 and drivenGrounded > 0 then\n.*?\n\1end\n", src, re.S)
    assert d, "Step's drive lines moved: update cut_split"
    lua = (
        "local VehicleDynamics = {}\n" + consts + "\n" + fn + "\n"
        "function DISTRIBUTE(wheels, driveAccel, mass)\n" + block + "\n"
        "\tlocal out = {}\n"
        "\tfor i, wheel in ipairs(wheels) do\n"
        "\t\tlocal long = 0\n"
        "\t\tif not (not wheel.grounded or wheel.load <= 0) then\n" + d.group(0) + "\t\tend\n"
        "\t\tout[i] = long\n"
        "\tend\n"
        "\treturn out\n"
        "end\n"
        "return VehicleDynamics.DriveSplit, FRONT_SPLIT, MAX_WHEEL_SHARE\n")
    return vss.luau_to_lua(lua)


SWEEP_LUA = r"""
local function finite(x) return x == x and x ~= math.huge and x ~= -math.huge end

-- layout: { {front=bool}, ... } all driven (a car) or { front, rear } with only the rear driven (a bike).
function SWEEP(layout, loads, accels, mass, bike)
	local n = #layout
	local s = { cases = 0, nonfinite = 0, wrongsign = 0, created = 0, capbreach = 0, bikefront = 0,
		bikerear = 0, nonedelivered = 0, lost = 0, lost5 = 0, lost25 = 0, lostcap = 0, maxlost = 0, maxlostcase = "", examples = {} }
	local idx = {}
	local function example(kind, text)
		if not s.examples[kind] then s.examples[kind] = text end
	end
	local function visit()
		for mask = 0, (1 << n) - 1 do
			for _, accel in ipairs(accels) do
				local wheels, desc, anyLoaded = {}, {}, false
				for i = 1, n do
					local grounded = (mask >> (i - 1)) & 1 == 1
					local load = loads[idx[i]]
					wheels[i] = { front = layout[i].front, drive = layout[i].drive, grounded = grounded, load = grounded and load or 0 }
					if grounded and load > 0 and layout[i].drive then anyLoaded = true end
					desc[i] = (layout[i].front and "F" or "R") .. (grounded and string.format("%g", load) or "-")
				end
				local out = DISTRIBUTE(wheels, accel, mass)
				s.cases = s.cases + 1
				local asked = mass * accel
				local sum, bad = 0, false
				local text = table.concat(desc, " ") .. string.format(" accel %g", accel)
				for i = 1, n do
					local f = out[i]
					if not finite(f) then
						s.nonfinite = s.nonfinite + 1; bad = true; example("nonfinite", text)
					else
						if f * asked < 0 then s.wrongsign = s.wrongsign + 1; example("wrongsign", text) end
						sum = sum + math.abs(f)
						if not bike and math.abs(f) > 0.5 * math.abs(asked) * (1 + 1e-9) then
							s.capbreach = s.capbreach + 1; example("capbreach", text .. string.format(" wheel %d %.3f", i, f / asked))
						end
						if bike and wheels[i].front and f ~= 0 then s.bikefront = s.bikefront + 1; example("bikefront", text) end
						if bike and not wheels[i].front and wheels[i].grounded and wheels[i].load > 0
							and math.abs(f - asked) > 1e-9 * math.abs(asked) then
							s.bikerear = s.bikerear + 1; example("bikerear", text)
						end
					end
				end
				if not bad then
					if sum > math.abs(asked) * (1 + 1e-9) then s.created = s.created + 1; example("created", text .. string.format(" handed %.4f", sum / math.abs(asked))) end
					if anyLoaded and sum == 0 then s.nonedelivered = s.nonedelivered + 1; example("nonedelivered", text) end
					if anyLoaded and sum < math.abs(asked) * (1 - 1e-9) then
						local lost = 1 - sum / math.abs(asked)
						s.lost = s.lost + 1
						if lost > 0.05 then s.lost5 = s.lost5 + 1 end
						if lost > 0.25 then s.lost25 = s.lost25 + 1 end
						-- Was the fling guard what held it back? Re-run with no cap.
						local capped = false
						for i = 1, n do
							if math.abs(out[i]) >= 0.5 * math.abs(asked) * (1 - 1e-9) then capped = true end
						end
						if capped then s.lostcap = s.lostcap + 1 end
						if lost > s.maxlost then s.maxlost = lost; s.maxlostcase = text end
					end
				end
			end
		end
	end
	local function rec(i)
		if i > n then visit() return end
		for k = 1, #loads do idx[i] = k; rec(i + 1) end
	end
	rec(1)
	return s
end

-- The front's share along the front's load fraction, and the jump at each end.
function SPLITCURVE(split, totals, steps)
	local r = { cases = 0, nonfinite = 0, outofrange = 0, falls = 0, maxjump = 0, jumpat = 0, examples = {} }
	for _, total in ipairs(totals) do
		local last = nil
		for k = 0, steps do
			local f = k / steps
			local v = split(total * f, total * (1 - f))
			r.cases = r.cases + 1
			if not finite(v) then r.nonfinite = r.nonfinite + 1; r.examples.nonfinite = r.examples.nonfinite or string.format("total %g f %g", total, f)
			else
				if v < 0 or v > 1 then r.outofrange = r.outofrange + 1; r.examples.range = r.examples.range or string.format("total %g f %g -> %g", total, f, v) end
				if last and v < last - 1e-12 then r.falls = r.falls + 1; r.examples.falls = r.examples.falls or string.format("total %g f %g", total, f) end
				if last and v - last > r.maxjump then r.maxjump = v - last; r.jumpat = f end
				last = v
			end
		end
	end
	return r
end
"""

# Wheel loads as Step can produce them (clamped 0..maxLoad; the Ranger's maxLoad is ~22,000), and
# outside it (negative, huge, inf, NaN), which Step never produces but the function should survive.
LOADS_IN = [0, 1e-9, 0.5, 30, 400, 2500, 12000]
LOADS_OUT = LOADS_IN + [-50, 1e300, float("inf"), float("nan")]
ACCELS = [40.0, -30.0, 1e-6]          # forward, reverse, a whisper of throttle
CAR = [dict(front=True, drive=True), dict(front=True, drive=True), dict(front=False, drive=True), dict(front=False, drive=True)]
BIKE = [dict(front=True, drive=False), dict(front=False, drive=True)]
MASS = 1000.0


def split_part(src):
    """Returns (problems, lines, facts)."""
    from lupa import lua54
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    split, front_split, max_share = lua.execute(cut_split(src))
    lua.execute(SWEEP_LUA)
    G = lua.globals()
    T = lua.table_from
    problems, lines, facts = [], [], {}

    # S1: the centre split.
    curve = G.SPLITCURVE(split, T([1e-9, 1.0, 5000.0, 1e12]), 2000)
    ends = {"front up (0, 500)": split(0, 500), "rear up (500, 0)": split(500, 0), "both up (0, 0)": split(0, 0),
            "even (500, 500)": split(500, 500)}
    odd = {"negative (-5, 500)": split(-5, 500), "negative (500, -5)": split(500, -5), "huge (1e300, 1e300)": split(1e300, 1e300),
           "inf (inf, 500)": split(float("inf"), 500), "nan (nan, 500)": split(float("nan"), 500)}
    lines.append(f"S1 DriveSplit: {curve.cases} load splits examined; nonfinite {curve.nonfinite}, out of 0..1 "
                 f"{curve.outofrange}, falling {curve.falls}")
    lines.append("   ends: " + ", ".join(f"{k} -> {v:g}" for k, v in ends.items()))
    lines.append("   off the domain Step feeds it: " + ", ".join(f"{k} -> {v:g}" for k, v in odd.items()))
    if curve.nonfinite or curve.outofrange or curve.falls:
        problems.append(f"S1 DriveSplit curve: nonfinite {curve.nonfinite}, out of range {curve.outofrange}, "
                        f"falls {curve.falls} ({dict(curve.examples)})")
    for key, want in (("front up (0, 500)", 0), ("rear up (500, 0)", 1), ("both up (0, 0)", 0)):
        v = ends[key]
        if not (v == v) or abs(v - want) > 1e-12:
            problems.append(f"S1 DriveSplit {key} gives {v}, not {want}")
    # The jump as the last rear load goes: a rear with a hair of load vs none at all.
    hair = split(500, 1e-9)
    facts["hair"] = hair
    facts["front_split"] = front_split
    lines.append(f"   rear with a hair of load (500, 1e-9) -> {hair:.4f}; rear up -> {ends['rear up (500, 0)']:g}: "
                 f"the front's share jumps {ends['rear up (500, 0)'] - hair:.3f} as the rear leaves the ground")
    facts["curve"] = [(f / 20, split(f / 20 * 1000, (1 - f / 20) * 1000)) for f in range(21)]

    # S2-S7: the per-wheel drive.
    for label, layout, bike in (("car (4 driven)", CAR, False), ("bike (rear driven)", BIKE, True)):
        for dom, loads in (("in", LOADS_IN), ("out", LOADS_OUT)):
            s = G.SWEEP(T([T(w) for w in layout]), T(loads), T(ACCELS), MASS, bike)
            ex = {k: v for k, v in s.examples.items()}
            lines.append(f"{'S2-S7' if dom == 'in' else '     '} {label}, loads {dom} Step's domain: {s.cases} cases; nonfinite "
                         f"{s.nonfinite}, wrong sign {s.wrongsign}, created {s.created}, over half {s.capbreach}, "
                         f"bike front driven {s.bikefront}, bike rear short {s.bikerear}, none delivered {s.nonedelivered}; "
                         f"LOST some drive {s.lost} (over 5%: {s.lost5}, over 25%: {s.lost25}; {s.lostcap} at the fling guard), worst {s.maxlost * 100:.0f}% "
                         f"({s.maxlostcase})")
            facts[f"{label} {dom}"] = dict(cases=s.cases, lost=s.lost, lost5=s.lost5, lost25=s.lost25, lostcap=s.lostcap, maxlost=s.maxlost)
            if dom == "in":
                for key, count in (("S2 nonfinite", s.nonfinite), ("S3 wrong sign", s.wrongsign), ("S4 created", s.created),
                                   ("S5 over half", s.capbreach), ("S6 bike front", s.bikefront),
                                   ("S6 bike rear short", s.bikerear), ("S7 none delivered", s.nonedelivered)):
                    if count:
                        kind = {"S2 nonfinite": "nonfinite", "S3 wrong sign": "wrongsign", "S4 created": "created",
                                "S5 over half": "capbreach", "S6 bike front": "bikefront", "S6 bike rear short": "bikerear",
                                "S7 none delivered": "nonedelivered"}[key]
                        problems.append(f"{key}: {count} of {s.cases} {label} cases (e.g. {ex.get(kind)})")
            elif s.nonfinite:
                facts[f"{label} nonfinite out"] = (s.nonfinite, ex.get("nonfinite"))

    # Named cases worth a sentence each.
    named = {
        "rear up, fronts even": [True, True, False, False, 500, 500, 0, 0],
        "rear up, fronts 70/30 (turning)": [True, True, False, False, 700, 300, 0, 0],
        "one front wheel down only": [True, False, False, False, 800, 0, 0, 0],
        "one wheel per axle (crossed up)": [True, False, False, True, 600, 0, 0, 600],
        "rear axle 5% of the load": [True, True, True, True, 475, 475, 25, 25],
        "flat, even": [True, True, True, True, 500, 500, 500, 500],
        "hard cornering, outside 90%": [True, True, True, True, 900, 100, 900, 100],
    }
    facts["named"] = {}
    for name, spec in named.items():
        wheels = T([T(dict(front=CAR[i]["front"], drive=True, grounded=spec[i], load=spec[4 + i] if spec[i] else 0)) for i in range(4)])
        out = G.DISTRIBUTE(wheels, 40.0, MASS)
        shares = [out[i + 1] / (MASS * 40.0) for i in range(4)]
        loads = spec[4:]
        total = sum(loads)
        facts["named"][name] = (shares, [x / total for x in loads])
    return problems, lines, facts


# ---------------------------------------------------------------------------------------------
# Part 2: whole-step runs
# ---------------------------------------------------------------------------------------------

RUN_LUA = r"""
local VD = ...
local V = Vector3.new
TARMAC = { __instance = true, Material = "Asphalt", CanCollide = true, Anchored = true, Transparency = 0,
	Size = V(40, 1, 40) }
TARMAC.IsA = function(self, class) return class == "BasePart" end
TARMAC.FindFirstAncestorOfClass = function() return nil end

local function orthonormal(c)
	local y = c.y.Unit
	local x = y:Cross(c.z).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(c.p, x, y, z)
end

-- opts: start, speed, time, throttle(t), steer(t), parked, stopBelow (end once forward speed < it),
--       pitchKick (rad/s about the right axis on the first frame airborne after takeoff)
function run2(rig, g, opts)
	local ch = rig.chassis
	local mass = ch.AssemblyMass
	local I = rig.inertiaShape * mass
	local s0 = opts.start or 0
	local h0 = groundAt(s0)
	ch.CFrame = CFrame.new(0, h0 + g.cy, -s0)
	ch.Position = ch.CFrame.Position
	ch.AssemblyLinearVelocity = V(0, 0, -(opts.speed or 0))
	ch.AssemblyAngularVelocity = Vector3.zero
	rig.steerAngle = 0
	local hullPts = {}
	for _, sx in ipairs({ -1, 1 }) do for _, sz in ipairs({ -1, 1 }) do
		table.insert(hullPts, V(sx * g.sx / 2, -g.sy / 2, sz * g.sz / 2))
	end end
	local h = 1 / 240
	local frameLength = 1 / 60
	local lastLength, frame, clock, due = frameLength, 0, 0, 0
	local out = { t = {}, fwd = {}, lat = {}, x = {}, s = {}, y = {}, yaw = {}, yawRate = {}, up = {}, pitchRate = {},
		grounded = {}, maxLong = {}, vy = {}, frontShare = {}, handed = {} }
	local wasAir, kicked = false, false
	while clock < (opts.time or 4) do
		frame = frame + 1
		clock = clock + frameLength
		SIM_TIME = clock
		local input = { throttle = opts.throttle(clock), steer = opts.steer and opts.steer(clock) or 0,
			handbrake = false, parked = opts.parked or false }
		local tel = VD.Step(rig, input, lastLength)
		if opts.pitchKick and not kicked and tel.grounded == 0 and clock > 0.2 then
			kicked = true
			ch.AssemblyAngularVelocity = ch.AssemblyAngularVelocity + ch.CFrame.RightVector * opts.pitchKick
		end
		lastLength = frameLength
		due = due + frameLength
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
			for _, local_ in ipairs(hullPts) do
				local at = c:PointToWorldSpace(local_)
				local gy, piece = groundAt(alongU(at))
				if piece and piece[5].CanCollide and at.Y < gy then
					local pv = v + w:Cross(at - p)
					local push = math.max(0, mass * (2000 * (gy - at.Y) - 120 * pv.Y) / #hullPts)
					F = F + V(0, push, 0)
					T = T + (at - p):Cross(V(0, push, 0))
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
		local vel, ang = ch.AssemblyLinearVelocity, ch.AssemblyAngularVelocity
		local look = c.LookVector
		local maxLong, fl, rl = 0, 0, 0
		for _, wheel in ipairs(rig.wheels) do
			local l = wheel.grounded and math.abs(wheel.long or 0) or 0
			if l > maxLong then maxLong = l end
			if wheel.grounded then if wheel.front then fl = fl + wheel.load else rl = rl + wheel.load end end
		end
		out.t[frame] = clock
		out.fwd[frame] = vel:Dot(look)
		out.lat[frame] = vel:Dot(c.RightVector)
		out.x[frame] = ch.Position.X
		out.s[frame] = -ch.Position.Z
		out.y[frame] = ch.Position.Y
		out.vy[frame] = vel.Y
		out.yaw[frame] = math.atan(look.X, -look.Z)
		out.yawRate[frame] = ang:Dot(c.UpVector)
		out.pitchRate[frame] = ang:Dot(c.RightVector)
		out.up[frame] = c.UpVector.Y
		out.grounded[frame] = tel.grounded
		out.maxLong[frame] = maxLong / (mass / #rig.wheels * workspace.Gravity)
		out.frontShare[frame] = (fl + rl) > 0 and fl / (fl + rl) or -1
		-- The share of a unit of drive this frame's wheel states hand out, by the source's own lines
		-- (DISTRIBUTE, cut out by cut_split); -1 with the throttle off or no driven wheel loaded.
		out.handed[frame] = -1
		if DISTRIBUTE and input.throttle > 0.02 then
			local loaded = false
			for _, wheel in ipairs(rig.wheels) do
				if wheel.drive and wheel.grounded and wheel.load > 0 then loaded = true end
			end
			if loaded then
				local sum = 0
				for _, f in ipairs(DISTRIBUTE(rig.wheels, 1, 1)) do sum = sum + math.abs(f) end
				out.handed[frame] = sum
			end
		end
		if opts.stopBelow and clock > 0.3 and out.fwd[frame] < opts.stopBelow then break end
	end
	return out
end
"""


def load_cars():
    entries, cars, skipped = cba.read_cars(os.path.join(ROOT, "ReplicatedStorage", "Shared", "VehicleModels.lua"))
    return cars


def load_world(src, cars):
    from lupa import lua54
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    table = ", ".join(f"{name} = {car['density']}" for name, car in cars.items())
    lua.execute(vss.PRELUDE + f"\nDENSITY = {{ {table} }}\n")
    vd = lua.execute(vss.luau_to_lua(src))
    sim = vss.SIM.replace("chassis.AssemblyMass = g.sx * g.sy * g.sz * 1.3",
                          "chassis.AssemblyMass = g.sx * g.sy * g.sz * (DENSITY[modelId] or 1.3)")
    assert sim != vss.SIM, "vehicle_stability_sim.py's mass line changed: update awd_bugtest_check"
    lua.execute(sim, vd)
    lua.execute(RUN_LUA, vd)
    return lua, vd


class World:
    """One Lua state with one VehicleDynamics source, the mock world, and run2."""

    def __init__(self, src, cars):
        self.lua, self.vd = load_world(src, cars)
        self.G = self.lua.globals()
        self.T = self.lua.table
        self.P = self.G.PARTS
        self.set_ground = self.lua.eval("function(t, ux, uz) GROUND = t; GROUND_U = Vector3.new(ux, 0, uz) end")
        self.cars = cars
        self.has_split = "function VehicleDynamics.DriveSplit(" in src
        if self.has_split:
            self.lua.execute(cut_split(src))

    def ground(self, pieces, u=(0.0, -1.0)):
        self.set_ground(self.T(*[self.T(*p) for p in pieces]), u[0], u[1])

    def fn(self, code):
        return self.lua.eval(code)

    def run(self, model, pieces, u=(0.0, -1.0), **opts):
        self.ground(pieces, u)
        car = cba.to_sim(self.cars[model])
        g = self.lua.table_from(dict(r=car["r"], track=car["track"], fz=car["fz"], rz=car["rz"],
                                     sx=car["size"][0], sy=car["size"][1], sz=car["size"][2], cy=car["cy"]))
        rig = self.G.buildCar(model, g)
        for key in ("throttle", "steer"):
            if isinstance(opts.get(key), str):
                code = opts[key]
                opts[key] = self.fn(code if code.startswith("function") else f"function(t) return {code} end")
        out = self.G.run2(rig, g, self.lua.table_from(opts))
        n = len(out.t)
        return {k: [out[k][i] for i in range(1, n + 1)] for k in ("t", "fwd", "lat", "x", "s", "y", "vy", "yaw", "yawRate", "up",
                                                                  "pitchRate", "grounded", "maxLong", "frontShare", "handed")}, rig


def first(ts, xs, pred):
    for t, x in zip(ts, xs):
        if pred(x):
            return t
    return None


def guard(o):
    """(share of throttle-on frames whose wheel states hand out under 99% of the drive, the least handed out)."""
    hs = [x for x in o["handed"] if x >= 0]
    if not hs:
        return 0.0, 1.0
    return sum(1 for x in hs if x < 0.99) / len(hs), min(hs)


def model_runs(world, model, quick=False):
    """Every whole-step measurement for one car model on one source. A dict of numbers."""
    h = world.vd.Handling[model]
    top, rev = h.topSpeed, h.reverseSpeed
    P = world.P
    TAR = world.G.TARMAC
    flat = [(-2000, 4000, 0, 0, TAR)]
    grass = [(-2000, 4000, 0, 0, P.grass)]
    r = {}

    # Flat acceleration, from a standstill, full throttle.
    o, _ = world.run(model, flat, start=0, speed=0, time=30, throttle="1")
    r["t60"] = first(o["t"], o["fwd"], lambda v: v >= 0.6 * top)
    r["t95"] = first(o["t"], o["fwd"], lambda v: v >= 0.95 * top)
    r["top"] = max(o["fwd"])
    r["top_share"] = r["top"] / top
    r["flat_trace"] = (o["t"], o["fwd"])

    # Part throttle (the bot's 0.15) in a straight line from 12 studs/s, and the body's tilt at rest: a car
    # that sits nose-up has its springs, which push along the body's up, pushing it backward too.
    o, _ = world.run(model, flat, start=0, speed=12, time=6, throttle="0.15")
    r["creep"] = o["fwd"][-1]
    o, _ = world.run(model, flat, start=0, speed=0, time=6, throttle="0")
    r["tilt"] = math.degrees(math.acos(min(1.0, o["up"][-1])))

    # Reverse from a standstill.
    o, _ = world.run(model, flat, start=0, speed=0, time=12, throttle="-1")
    r["rev"] = -min(o["fwd"])
    r["trev90"] = first(o["t"], o["fwd"], lambda v: v <= -0.9 * rev)

    # Braking from 90% of top.
    o, _ = world.run(model, flat, start=0, speed=0.9 * top, time=10, throttle="-1", stopBelow=1.5)
    r["brake_dist"] = o["s"][-1] - o["s"][0]
    r["brake_trace"] = (tuple(round(v, 9) for v in o["fwd"]), tuple(round(v, 9) for v in o["s"]))

    # Parked rest: flat tarmac and a 10-degree grass slope.
    slope = [(-2000, -20, 0, 0, P.grass), (-20, 200, 0, 220 * math.tan(math.radians(10)), P.grass), (200, 4000, 220 * math.tan(math.radians(10)), 220 * math.tan(math.radians(10)), P.grass)]
    for name, pieces, start in (("park_flat", flat, 0), ("park_slope", slope, 60)):
        o, _ = world.run(model, pieces, start=start, speed=0, time=8, throttle="0", parked=True)
        i1 = next(i for i, t in enumerate(o["t"]) if t >= 1.0)
        r[name] = math.hypot(o["x"][-1] - o["x"][i1], o["s"][-1] - o["s"][i1])
        r[name + "_trace"] = tuple(round(v, 9) for v in o["s"])

    # Turning on flat tarmac.
    corners = [
        ("power", 0.6 * top, "1", "function(t) return math.min(1, t / 0.5) end", 4),
        ("lift", 0.6 * top, "0", "function(t) return math.min(1, t / 0.5) end", 4),
        ("crawl", 12, "0.15", "1", 5),       # the bot's full-lock corners (bot_driving_sim trace)
        ("step", 0.9 * top, "1", "1", 3),
    ]
    for name, v0, thr, st, tm in corners:
        o, _ = world.run(model, flat, start=0, speed=v0, time=tm, throttle=thr, steer=st)
        slip = [math.degrees(math.atan2(abs(la), max(abs(f), 1e-6))) for la, f in zip(o["lat"], o["fwd"])]
        tail = [i for i, t in enumerate(o["t"]) if t >= tm - 2]
        yr = sum(abs(o["yawRate"][i]) for i in tail) / len(tail)
        sp = sum(math.hypot(o["fwd"][i], o["lat"][i]) for i in tail) / len(tail)
        # Total heading turned (unwrapped).
        turned = 0.0
        for a, b in zip(o["yaw"], o["yaw"][1:]):
            d = b - a
            d = (d + math.pi) % (2 * math.pi) - math.pi
            turned += d
        r[f"{name}_slip"] = max(slip)
        r[f"{name}_radius"] = sp / yr if yr > 1e-6 else float("inf")
        r[f"{name}_speed"] = sp
        r[f"{name}_minup"] = min(o["up"])
        r[f"{name}_turned"] = abs(math.degrees(turned))
        r[f"{name}_spun"] = max(slip) > 60
        r[f"{name}_guard"], r[f"{name}_handed"] = guard(o)

    # Across road edges at 10 and 30 degrees (vehicle_stability_sim's "edge" course): one side's tyres
    # climb a 0.4 edge before the other's, the wheel loads go lopsided for a moment.
    edge = [(-400, 15, 0, 0, P.grass), (15, 39, 0.4, 0.4, P.road), (39, 60, 0, 0, P.grass),
            (60, 84, 0.4, 0.4, P.road), (84, 800, 0, 0, P.grass)]
    for deg in (10, 30):
        a = math.radians(deg)
        o, _ = world.run(model, edge, u=(-math.cos(a), -math.sin(a)), start=-30, speed=0.6 * top, time=4, throttle="1")
        r[f"edge{deg}_guard"], r[f"edge{deg}_handed"] = guard(o)

    # Climb: the steepest grass grade taken from a standstill at its foot, bisected to 1 degree.
    def climbs(deg):
        L = 90.0
        hgt = L * math.tan(math.radians(deg))
        pieces = [(-2000, 0, 0, 0, P.grass), (0, L, 0, hgt, P.grass), (L, 4000, hgt, hgt, P.grass)]
        o, _ = world.run(model, pieces, start=-9, speed=0, time=14, throttle="1")
        return max(o["s"]) > L + 3 and min(o["up"]) > 0.3

    L = 90.0
    hgt = L * math.tan(math.radians(40))
    o, _ = world.run(model, [(-2000, 0, 0, 0, P.grass), (0, L, 0, hgt, P.grass), (L, 4000, hgt, hgt, P.grass)],
                     start=-9, speed=0, time=14, throttle="1")
    r["climb40_guard"], r["climb40_handed"] = guard(o)

    lo, hi = 10, 75
    if not climbs(lo):
        r["climb"] = 0
    else:
        while hi - lo > 1:
            mid = (lo + hi) // 2
            if climbs(mid):
                lo = mid
            else:
                hi = mid
        r["climb"] = lo

    # Jumps landed on the throttle: vehicle_stability_sim's 20-degree kicker at 70, and the same with a
    # nose-down pitch in the air (front lands first, rear light: DriveSplit hands the front it all).
    kicker = [(-200, 30, 0, 0, P.grass), (30, 44, 0, 14 * math.tan(math.radians(20)), P.grass), (44, 4000, 0, 0, P.grass)]
    for name, kick in (("jump", None), ("nosedown", -1.2)):
        opts = dict(start=0, speed=70, time=4, throttle="1")
        if kick is not None:
            opts["pitchKick"] = kick
        o, _ = world.run(model, kicker, **opts)
        g = o["grounded"]
        # First landing: first grounded frame after an airborne run of at least 0.1 s.
        land, air = None, 0
        for i, n in enumerate(g):
            if n == 0:
                air += 1
            else:
                if air >= 6:
                    land = i
                    break
                air = 0
        if land is None:
            r[f"{name}_landed"] = False
            continue
        after = [i for i in range(land, len(g)) if o["t"][i] <= o["t"][land] + 1.0]
        runs, cur = [], 0
        for i in range(land, len(g)):
            if g[i] == 0:
                cur += 1
            elif cur:
                runs.append(cur)
                cur = 0
        r[f"{name}_landed"] = True
        r[f"{name}_air"] = air / 60
        r[f"{name}_relaunch"] = (max(runs) if runs else 0) / 60
        r[f"{name}_pitch"] = max(abs(o["pitchRate"][i]) for i in after)
        r[f"{name}_long"] = max(o["maxLong"][i] for i in after)
        r[f"{name}_minup"] = min(o["up"][i] for i in range(land, len(g)))
        r[f"{name}_speed_after"] = o["fwd"][after[-1]]
        r[f"{name}_front_at_land"] = o["frontShare"][land]
        r[f"{name}_guard"], r[f"{name}_handed"] = guard(o)
    return r


STEP_ROWS = [
    ("t60", "0-60% s", "%.3f"), ("t95", "0-95% of Handling top s", "%.3f"),
    ("t95reached", "0-95% of the top reached before s", "%.3f"), ("top", "top speed reached", "%.2f"),
    ("top_share", "top reached / Handling topSpeed", "%.3f"),
    ("creep", "throttle 0.15 from 12, speed after 6 s", "%.2f"), ("tilt", "body tilt at rest, deg", "%.2f"),
    ("rev", "reverse top", "%.2f"), ("trev90", "0-90% reverse s", "%.3f"), ("brake_dist", "brake 90%->0 studs", "%.2f"),
    ("park_flat", "parked drift flat", "%.4f"), ("park_slope", "parked drift 10deg", "%.4f"),
    ("power_slip", "power corner max slip deg", "%.1f"), ("power_radius", "power corner radius", "%.1f"),
    ("power_speed", "power corner speed", "%.1f"),
    ("lift_slip", "lift corner max slip deg", "%.1f"), ("lift_radius", "lift corner radius", "%.1f"),
    ("crawl_radius", "full-lock crawl radius", "%.2f"), ("crawl_speed", "full-lock crawl speed", "%.2f"),
    ("crawl_slip", "full-lock crawl slip deg", "%.1f"),
    ("step_slip", "step steer 90% max slip", "%.1f"), ("step_radius", "step steer radius", "%.1f"),
    ("step_minup", "step steer min up", "%.3f"),
    ("climb", "grass climb deg", "%d"),
    ("jump_relaunch", "jump relaunch s", "%.3f"), ("jump_pitch", "jump pitch rate after", "%.2f"),
    ("jump_long", "jump peak wheel long /wheel weight", "%.2f"), ("jump_minup", "jump min up", "%.3f"),
    ("nosedown_relaunch", "nose-down relaunch s", "%.3f"), ("nosedown_pitch", "nose-down pitch rate after", "%.2f"),
    ("nosedown_long", "nose-down peak wheel long /wheel weight", "%.2f"), ("nosedown_minup", "nose-down min up", "%.3f"),
    ("nosedown_front_at_land", "nose-down front load share at touch", "%.2f"),
    # Drive thrown away at the fling guard (main only: before AWD there was no guard, so always 0 / 1).
    ("power_guard", "power corner: frames under 99% handed", "%.3f"), ("power_handed", "power corner: least handed", "%.3f"),
    ("crawl_guard", "crawl: frames under 99% handed", "%.3f"), ("crawl_handed", "crawl: least handed", "%.3f"),
    ("step_guard", "step steer: frames under 99% handed", "%.3f"), ("step_handed", "step steer: least handed", "%.3f"),
    ("edge10_guard", "edges 10deg: frames under 99% handed", "%.3f"), ("edge10_handed", "edges 10deg: least handed", "%.3f"),
    ("edge30_guard", "edges 30deg: frames under 99% handed", "%.3f"), ("edge30_handed", "edges 30deg: least handed", "%.3f"),
    ("climb40_guard", "40deg climb: frames under 99% handed", "%.3f"), ("climb40_handed", "40deg climb: least handed", "%.3f"),
    ("jump_guard", "jump: frames under 99% handed", "%.3f"), ("jump_handed", "jump: least handed", "%.3f"),
    ("nosedown_guard", "nose-down: frames under 99% handed", "%.3f"), ("nosedown_handed", "nose-down: least handed", "%.3f"),
]


def step_part(pre_src, main_src, quick=False, models=None):
    """Returns (problems, findings, lines, results) with results[model] = (pre, main)."""
    cars = load_cars()
    names = models or list(cars)
    pre_world, main_world = World(pre_src, cars), World(main_src, cars)
    results, problems, findings, lines = {}, [], [], []
    for model in names:
        b = model_runs(pre_world, model, quick)
        a = model_runs(main_world, model, quick)
        # W1 is timed to 95% of the top speed the car reached BEFORE AWD, the same mark for both runs: the
        # van and the carrier never reach 95% of their Handling topSpeed on the flat at all (see the report).
        mark = 0.95 * b["top"]
        for r in (b, a):
            r["t95reached"] = first(r["flat_trace"][0], r["flat_trace"][1], lambda v: v >= mark)
        results[model] = (b, a)
        pre_driven = pre_world.vd.Handling[model].driven
        main_driven = main_world.vd.Handling[model].driven
        lines.append(f"{model}  (driven: {pre_driven} -> {main_driven})")
        for key, label, fmt in STEP_ROWS:
            if key not in b or key not in a:
                continue
            bv, av = b[key], a[key]
            if bv is None or av is None:
                lines.append(f"  {label:40} {bv} -> {av}")
                continue
            d = (av - bv) / abs(bv) * 100 if bv not in (0, float("inf")) else float("nan")
            lines.append(f"  {label:40} {fmt % bv:>9} -> {fmt % av:>9}   {d:+6.1f}%")
        # W1-W2 at vehicle_awd_check's own DRAG_TOLERANCE (5%); past the commit's claim of 1% is a finding.
        for key, tag in (("t60", "W1 0-60%"), ("t95reached", "W1 0-95% of the top reached before"), ("top", "W1 top speed"),
                         ("rev", "W2 reverse"), ("trev90", "W2 0-90% reverse")):
            bv, av = b[key], a[key]
            if bv is None or av is None or abs(av - bv) > 0.05 * abs(bv):
                problems.append(f"{tag} {model}: {bv} -> {av} (more than 5%)")
            elif abs(av - bv) > 0.01 * abs(bv):
                findings.append(f"{tag} {model}: {bv:.3f} -> {av:.3f} ({(av - bv) / bv * 100:+.1f}%, past the commit's 'within 1%')")
        for key, tag in (("brake_trace", "W3 braking"), ("park_flat_trace", "W3 parked flat"), ("park_slope_trace", "W3 parked slope")):
            if b[key] != a[key]:
                problems.append(f"{tag} {model}: not identical to before AWD")
    return problems, findings, lines, results


def bike_part(pre_src, main_src):
    b = bbs.measure(pre_src, modes=[bbs.MODES[0]])
    a = bbs.measure(main_src, modes=[bbs.MODES[0]])
    count = sum(len(v) for v in b.values())
    diffs = [(m, k) for m in b for k in b[m] if b[m][k] != a[m].get(k)]
    problems = [f"W4 bike {m} {k}: {b[m][k]} -> {a[m][k]}" for m, k in diffs]
    return problems, f"W4 bikes: {count} bike_balance_sim runs x every number, {len(diffs)} differ from before AWD"


# ---------------------------------------------------------------------------------------------
# Part 3: the bot lap
# ---------------------------------------------------------------------------------------------

def bot_part(pre_src, main_src):
    botnav = os.path.join(ROOT, "ServerScriptService", "Modules", "BotNav.lua")
    load_split = main_src.replace("\tlocal front = frontLoad / (frontLoad + rearLoad)\n",
                                  "\tlocal front = frontLoad / (frontLoad + rearLoad)\n\tif true then return front end\n", 1)
    no_cap = main_src.replace("local wheelCap = drivenCount > 1 and MAX_WHEEL_SHARE or 1", "local wheelCap = 1", 1)
    assert load_split != main_src and no_cap != main_src, "the split lines moved: update bot_part"
    variants = [("main as is", main_src), ("main, VehicleDynamics from before AWD", pre_src),
                ("main, split = load share (the fling guard kept)", load_split), ("main, fling guard off (split kept)", no_cap)]
    lines = []
    for label, src in variants:
        with tempfile.TemporaryDirectory() as tmp:
            os.makedirs(os.path.join(tmp, "tools"))
            os.makedirs(os.path.join(tmp, "ReplicatedStorage", "Shared"))
            os.makedirs(os.path.join(tmp, "ServerScriptService", "Modules"))
            for name in ("bot_driving_sim.py", "vehicle_stability_sim.py", "bike_balance_sim.py"):
                shutil.copy(os.path.join(ROOT, "tools", name), os.path.join(tmp, "tools", name))
            shutil.copy(botnav, os.path.join(tmp, "ServerScriptService", "Modules", "BotNav.lua"))
            with open(os.path.join(tmp, "ReplicatedStorage", "Shared", "VehicleDynamics.lua"), "w", encoding="utf-8") as f:
                f.write(src)
            p = subprocess.run([sys.executable, os.path.join(tmp, "tools", "bot_driving_sim.py"), "--only", "lap"],
                               capture_output=True, text=True, timeout=1800)
            got = [ln for ln in p.stdout.splitlines() if ln.startswith(("  lap", "PROBLEM"))]
            lines.append(f"{label}: {'OK' if p.returncode == 0 else 'RED'}")
            lines.extend("    " + ln.strip() for ln in got)
    return lines


# ---------------------------------------------------------------------------------------------
# Planted faults
# ---------------------------------------------------------------------------------------------

PLANTS = [
    ("the front is handed more than all of it with the rear up (S1)",
     "\t\treturn frontLoad > 0 and 1 or 0\n", "\t\treturn frontLoad > 0 and 1.25 or 0\n", "split"),
    ("the fling guard off (S5)",
     "local wheelCap = drivenCount > 1 and MAX_WHEEL_SHARE or 1", "local wheelCap = 1", "split"),
    ("a bike's drive split to its undriven front (S6)",
     "\telseif frontLoad <= 0 then\n\t\treturn 0\n", "\telseif frontLoad <= 0 then\n\t\treturn FRONT_SPLIT\n", "split"),
    ("reverse throttle drives forward (S3)",
     "long += mass * driveAccel * math.min(share, wheelCap)", "long += mass * math.abs(driveAccel) * math.min(share, wheelCap)", "split"),
    ("the zero-load guards loosened: 0/0 (S1/S2)",
     "\tif rearLoad <= 0 then\n", "\tif rearLoad < 0 then\n", "split+"),
    ("the split hands out 10% more than asked (S4, W1)",
     "long += mass * driveAccel * math.min(share, wheelCap)", "long += mass * driveAccel * math.min(share, wheelCap) * 1.1", "split"),
    ("the brakes go through the split (W3)",
     "local resist = brakeAccel + coastAccel + governorAccel",
     "local resist = (brakeAccel + coastAccel + governorAccel) * (wheel.front and 0.8 or 1.2)", "step"),
]


def apply_plant(src, before, after, extra=False):
    assert src.count(before) == 1, f"plant text found {src.count(before)} times: {before!r}"
    out = src.replace(before, after)
    if extra:
        out = out.replace("\telseif frontLoad <= 0 then\n", "\telseif frontLoad < 0 then\n", 1)
    return out


def read_pre(path):
    if path:
        return open(path, encoding="utf-8").read()
    return subprocess.run(["git", "-C", ROOT, "show", f"{PRE_REF}:ReplicatedStorage/Shared/VehicleDynamics.lua"],
                          capture_output=True, text=True, check=True).stdout


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plant", action="store_true")
    parser.add_argument("--bot", action="store_true")
    parser.add_argument("--pre", default=None, help="VehicleDynamics.lua from before AWD (default: git show 47200d3^:...)")
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--quick", action="store_true", help="step part on Rotster and CrocodiloRanger only")
    args = parser.parse_args()
    main_src = open(args.source, encoding="utf-8").read()
    pre_src = read_pre(args.pre)
    sha = subprocess.run(["git", "-C", ROOT, "rev-parse", "--short", "HEAD"], capture_output=True, text=True).stdout.strip()
    print(f"tree {sha}; before-AWD source {args.pre or PRE_REF}")

    problems = []
    print("== split: DriveSplit and the per-wheel drive, cut from the source")
    p, lines, facts = split_part(main_src)
    problems += p
    print("\n".join(lines))
    print("   front share along the front's load fraction: " +
          " ".join(f"{f:.2f}:{v:.2f}" for f, v in facts["curve"][::2]))
    for name, (shares, loads) in facts["named"].items():
        print(f"   {name:34} loads {' '.join(f'{x:.2f}' for x in loads)} -> drive {' '.join(f'{x:.2f}' for x in shares)}"
              f"  (handed out {sum(shares) * 100:.0f}%)")

    print("== step: whole-step runs, before AWD -> main")
    models = ["Rotster", "CrocodiloRanger"] if args.quick else None
    p, findings, lines, _ = step_part(pre_src, main_src, args.quick, models)
    problems += p
    print("\n".join(lines))
    for f in findings:
        print("FINDING", f)
    p, line = bike_part(pre_src, main_src)
    problems += p
    print(line)

    if args.bot:
        print("== bot: tools/bot_driving_sim.py --only lap")
        print("\n".join(bot_part(pre_src, main_src)))

    for p in problems:
        print("PROBLEM", p)
    ok = not problems

    if args.plant:
        caught = 0
        for label, before, after, part in PLANTS:
            planted = apply_plant(main_src, before, after, extra=part == "split+")
            found = []
            try:
                if part.startswith("split"):
                    found += split_part(planted)[0]
                if part == "step" or "W1" in label:
                    found += step_part(pre_src, planted, True, ["Rotster"])[0]
            except Exception as err:  # an error is a failed run, not a pass
                found.append(f"error: {str(err).splitlines()[0]}")
            caught += bool(found)
            print(f"  plant {'CAUGHT' if found else 'MISSED'}: {label}: {found[0] if found else 'passed'}"
                  + (f" (+{len(found) - 1} more)" if len(found) > 1 else ""))
        print(f"planted faults: {caught}/{len(PLANTS)} caught")
        ok = ok and caught == len(PLANTS)
    print(f"awd bugtest check: {len(problems)} problems: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
