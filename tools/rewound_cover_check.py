"""A rewound shot at a vehicle's rider gets the same cover as the same shot at 0 ping (#97 F2 and the
pc/hitreg-fixes finding at CombatService:995, "a rewound shot reads glass instead of body").

Runs, in lupa, the REAL:
  * ReplicatedStorage/Shared/VehicleModels.lua (every drivable model, armed and unarmed, with the real
    ZFight pass: vehicle_models_axis_check's mocks), seated the way VehicleService.makeSeat seats it
    (Seat parts, CanQuery off, at VehicleModels' seat frames);
  * ServerScriptService/Modules/LagCompensation.lua (the ring buffer, RewindTime, the rewound raycast);
  * CombatService's firePellet with riderBehind and bodyBetween, cut out of CombatService.lua (Luau's
    `continue` rewritten to a goto, as explosive_ammo_check does);
  * ReplicatedStorage/Shared/VehicleCover.lua (Share, CrossesGlass, SeatOf).

THE INVARIANT. A shooter aims at a rider where they SAW the car: at a ping, that is where the car was
(ping + LagCompensation.InterpolationDelay) ago. The same line fired at 0 ping, with the car standing
where the shooter saw it, is the reference. LagCompensation rewinds the rider (a character) but never
the car, so a rewound shot that reaches the rider has flown past where the car is NOW, and firePellet
works the cover out itself: it carries the line into the car's present frame and asks bodyBetween
(body) and CrossesGlass (glass). That answer must be what the 0-ping ray met. So:

  FAIL  a rewound shot whose rider, vehicle damage or headshot differs from the 0-ping shot, unless
        the one allowance below applies. b254eac asked glass before body, so a line through bodywork
        AND a pane read "glass": 3.25x the 0-ping damage on a car, 2.5x through the armed
        TartarugaScout's gun-shield glass (--plant, "glass before body").
  note  the one allowance, counted and printed, never failed: the PRESENT car met the shot first (the
        car drove into the line) and the rider took LESS than at 0 ping. That is riderBehind looking
        COVER_REACH studs past the present body for a rewound rider: a separate limit, not this path.

Candidates: every seat of every drivable model (armed builds add the gunner), a seated rider in it,
a ring of shooters round the car at several heights, aimed at points on the rider's head, torso, arms
and legs; each line fired at 0 ping and at every (speed, ping) in the grid. Only lines that reach the
rider at 0 ping or at some ping count as candidates. A limb that touches or straddles the bodywork's
surface is left out of the rig (a ray that starts inside a part doesn't report it, and riderBehind
starts just inside the body), counted in the last note; --clipped keeps them.

    python tools/rewound_cover_check.py .            the checks
    python tools/rewound_cover_check.py . --plant    the planted faults; every one must be caught
    python tools/rewound_cover_check.py . --list N   also print the first N mismatches
    python tools/rewound_cover_check.py . --dense    a finer grid of shooters, speeds and pings (minutes)
    python tools/rewound_cover_check.py . --clipped  keep the rider's limbs that touch the bodywork (a
                                                     separate question: see the note it prints)

What it cannot prove: a car that turns or bounces while the shot is in flight (only straight-line
motion is replayed; LagCompensation stores the root only, so a rider's lerped pose on a turn is not
rigid with the car); Roblox's own raycast (every part is tested as a box, a wedge and a wheel too, the
same in both worlds); real ping (a parameter here, as in hitreg_rewind_check).
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import vehicle_models_axis_check as V  # noqa: E402  (the VehicleModels mocks and loader)

# Speeds in studs a second (CombatService's rider-cover comment: cars run at 62-106), pings in
# seconds (all under LagCompensation.Cap), and the shooters: every `step` degrees round the car at
# `heights` degrees up, aimed at each rider part's middle and `offsets` points off it. The gate runs
# GATE; --dense runs DENSE (about 7x the shots, a few minutes).
GATE = {"speeds": (30, 106), "pings": (0.03, 0.1, 0.2), "step": 30, "heights": (-5, 15, 40, 70), "offsets": 1}
DENSE = {"speeds": (20, 62, 106), "pings": (0.03, 0.08, 0.14, 0.2), "step": 15, "heights": (-5, 8, 25, 45, 70), "offsets": 2}


def read(root, *parts):
    return open(os.path.join(root, *parts), encoding="utf-8").read()


def cut(src, head):
    """A top-level chunk from its header to the `end` at column 0."""
    a = src.index(head)
    b = src.index("\nend\n", a) + 5
    return src[a:b]


def pellet_source(src):
    parts = [
        cut(src, "local function buildRaycastParams("),
        cut(src, "local function fireAbility("),
        cut(src, "local PELLET_BLAST_RADIUS_SCALE"),
        cut(src, "local function bulletBlast("),
        cut(src, "local COVER_REACH"),  # COVER_REACH and riderBehind
        cut(src, "local function bodyBetween("),
        cut(src, "local function firePellet("),
    ]
    block = V.luau_to_lua("\n".join(parts))
    loop_end = "\t\tend\n\tend\n\n\tif stopped then"
    if loop_end not in block:
        sys.exit("rewound_cover_check: firePellet's loop end moved; update the harness")
    block = block.replace(loop_end, "\t\tend\n\t\t::continue_::\n\tend\n\n\tif stopped then")
    return re.sub(r"^(\s*)continue$", r"\1goto continue_", block, flags=re.M)


# What vehicle_models_axis_check's mocks lack for a shot: a parent walk, Seats as BaseParts, object
# space, a CFrame lerp, a world raycast over boxes, RaycastParams whose filter reads back as a COPY
# (Roblox's does; riderBehind appends to what it reads), and the clock.
EXTRA = r"""
local Inst = getmetatable(Instance.new("Part"))
function Inst.IsDescendantOf(i, a)
    local p = i.Parent
    while p do if p == a then return true end p = p.Parent end
    return false
end
function Inst.FindFirstAncestorOfClass(i, c)
    local p = i.Parent
    while p do if p.ClassName == c then return p end p = p.Parent end
end
function Inst.FindFirstAncestorWhichIsA(i, c)
    local p = i.Parent
    while p do if p:IsA(c) then return p end p = p.Parent end
end
function Inst.FindFirstChild(i, name)
    for _, k in ipairs(rawget(i, "kids")) do if k.Name == name then return k end end
end
local isA = Inst.IsA
local SEATS = { Seat = true, VehicleSeat = true }
function Inst.IsA(i, c)
    if c == "BasePart" and SEATS[i.ClassName] then return true end
    return isA(i, c)
end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
function CF.PointToObjectSpace(c, v) local d = v - c.p; return Vector3.new(d:Dot(c.r), d:Dot(c.u), d:Dot(c.b)) end
function CF.VectorToObjectSpace(c, v) return Vector3.new(v:Dot(c.r), v:Dot(c.u), v:Dot(c.b)) end
function CF.VectorToWorldSpace(c, v) return c.r * v.X + c.u * v.Y + c.b * v.Z end
function CF.Lerp(a, b, t)
    local function l(x, y) return x + (y - x) * t end
    return CFrame.fromMatrix(l(a.p, b.p), l(a.r, b.r), l(a.u, b.u), l(a.b, b.b))
end
Enum.RaycastFilterType = { Exclude = "Exclude", Include = "Include" }

local RP = {}
RP.__index = function(p, k)
    if k == "FilterDescendantsInstances" then return table.clone(rawget(p, "_filter")) end
    return rawget(p, "_" .. k)
end
RP.__newindex = function(p, k, v)
    if k == "FilterDescendantsInstances" then v = table.clone(v) end
    rawset(p, (k == "FilterDescendantsInstances") and "_filter" or ("_" .. k), v)
end
RaycastParams = { new = function() return setmetatable({ _filter = {}, _FilterType = "Exclude" }, RP) end }

WORLD = Instance.new("Workspace")
CLOCK = 0
SHOOTABLE = {}  -- { part, chain = its ancestors, radius }: every BasePart in the world, refreshed when it changes

-- The ray against one box: where it enters, or nil. A ray that starts inside a part does not report
-- it, as Roblox's does not.
local function enter(o, d, part)
    local c, s = part.CFrame, part.Size
    local lo, hi = 0, 1
    local rel = o - c.p
    for _, pair in ipairs({ { c.r, s.X }, { c.u, s.Y }, { c.b, s.Z } }) do
        local axis, half = pair[1], pair[2] / 2
        local start, step = rel:Dot(axis), d:Dot(axis)
        if math.abs(step) < 1e-9 then
            if math.abs(start) > half then return nil end
        else
            local a, b = (-half - start) / step, (half - start) / step
            if a > b then a, b = b, a end
            if a > lo then lo = a end
            if b < hi then hi = b end
            if lo > hi then return nil end
        end
    end
    -- Inside at the start: every axis's entry was behind the origin.
    local inside = true
    for _, pair in ipairs({ { c.r, s.X }, { c.u, s.Y }, { c.b, s.Z } }) do
        if math.abs(rel:Dot(pair[1])) > pair[2] / 2 then inside = false end
    end
    if inside then return nil end
    return lo
end

workspace = {
    GetServerTimeNow = function() return CLOCK end,
    FindFirstChild = function() return nil end,
    Raycast = function(_, origin, vector, params)
        local listed = {}
        for _, x in ipairs(params.FilterDescendantsInstances) do listed[x] = true end
        local include = params.FilterType == "Include"
        local length = vector.Magnitude
        local unit = vector / length
        local best, bestPart = math.huge, nil
        for _, entry in ipairs(SHOOTABLE) do
            local part = entry.part
            if part.Parent and part.CanQuery ~= false then
                local inList = false
                for _, a in ipairs(entry.chain) do if listed[a] then inList = true break end end
                if inList == include then
                    -- Bounding sphere first: most parts are nowhere near the line.
                    local rel = part.CFrame.p - origin
                    local along = math.max(0, math.min(length, rel:Dot(unit)))
                    if (rel - unit * along).Magnitude <= entry.radius then
                        local t = enter(origin, vector, part)
                        if t and t < best then best, bestPart = t, part end
                    end
                end
            end
        end
        if TRACE then print("  ray", include and "include" or "exclude", bestPart and bestPart:GetFullName() or "nothing", best) end
        if not bestPart then return nil end
        local position = origin + vector * best
        return { Instance = bestPart, Position = position, Normal = -vector.Unit, Material = bestPart.Material,
            Distance = (position - origin).Magnitude }
    end,
}
"""

HARNESS = r"""
local vm, lagSrc, coverSrc, pelletSrc, modelId, unarmed, speeds, pings, RIDER_ROOT, grid = ...

local registered = {}
local Combatants = {
    All = function() return registered end,
    IsPlayer = function(t) return type(t) == "table" and t.__player == true end,
    FromCharacter = function(c) return registered[c] end,
    IsAlive = function() return true end,
    GetRoot = function() return nil end,
    GetHumanoid = function() return nil end,
}
local script = { Parent = { WaitForChild = function() return Combatants end } }
local env = setmetatable({ script = script, require = function(m) return m end }, { __index = _G })
local Lag = assert(load(lagSrc, "LagCompensation", "t", env))()
local Cover = assert(load(coverSrc, "VehicleCover", "t", setmetatable({}, { __index = _G })))()

-- Which cover each hit was given: the last `via` VehicleCover.Share was asked for.
local lastVia
local share = Cover.Share
Cover.Share = function(id, seat, via) lastVia = via return share(id, seat, via) end

local model, info = vm.Build(modelId, nil, { scheme = 1, unarmed = unarmed })
model.Parent = WORLD
local isBike = info.kind == "bike"
local function seat(class, name, frame)
    local s = Instance.new(class)
    s.Name, s.CFrame, s.CanQuery = name, frame, false
    s.Size = isBike and Vector3.new(1.0, 0.3, 1.6) or Vector3.new(1.8, 0.3, 1.8)
    s.Parent = model
    return s
end
local seats = { seat("VehicleSeat", "DriverSeat", info.seats.driver) }
for i, frame in ipairs(info.seats.passengers or {}) do table.insert(seats, seat("Seat", "PassengerSeat" .. i, frame)) end
if info.seats.gunner then table.insert(seats, seat("Seat", "GunnerSeat", info.seats.gunner)) end

-- Every part of the car, in the car's own frame (it is built at the origin), so it can be driven.
local rigid = {}
for _, p in ipairs(model:GetDescendants()) do
    if p:IsA("BasePart") then table.insert(rigid, { p, p.CFrame }) end
end

local report = { candidates = 0, mismatches = 0, shots = 0, rows = {}, kinds = {}, worst = 0, clipped = 0, parts = 0,
    intercepts = 0, interceptKinds = {}, interceptRows = {}, bySetting = {} }

-- The car's shootable parts (fixed once built: nothing here changes CanQuery).
local bodywork = {}
for _, v in ipairs(model:GetDescendants()) do
    if v:IsA("BasePart") and v.CanQuery ~= false then table.insert(bodywork, v) end
end

-- Whether `point` is inside any of them.
local function inBody(point)
    for _, v in ipairs(bodywork) do
        local o, h = v.CFrame:PointToObjectSpace(point), v.Size / 2
        if math.abs(o.X) < h.X and math.abs(o.Y) < h.Y and math.abs(o.Z) < h.Z then return true end
    end
    return false
end

-- The point of the box (cframe, half) nearest `point`.
local function clampInto(cframe, half, point)
    local o = cframe:PointToObjectSpace(point)
    return cframe * Vector3.new(math.clamp(o.X, -half.X, half.X), math.clamp(o.Y, -half.Y, half.Y), math.clamp(o.Z, -half.Z, half.Z))
end

-- A point inside both boxes, or nil: alternating projections (they converge when the two overlap).
local function common(ca, ha, cb, hb)
    local point = ca.p
    for _ = 1, 30 do point = clampInto(ca, ha, clampInto(cb, hb, point)) end
    local o = cb:PointToObjectSpace(point)
    if math.abs(o.X) <= hb.X + 1e-4 and math.abs(o.Y) <= hb.Y + 1e-4 and math.abs(o.Z) <= hb.Z + 1e-4 then
        return point
    end
end

-- A seated rider, an R15's boxes round a root RIDER_ROOT over the seat's centre (VehicleModels), thighs
-- forward. A limb that straddles or touches the bodywork's surface (part inside it, part out) is a separate
-- question (riderBehind starts its ray just inside the body, and a ray that starts inside a part
-- doesn't report it): it is taken out of the rig unless CLIPPED says to keep it, and counted.
local function box(name, parent, frame, size)
    local p = Instance.new("Part")
    p.Name, p.CFrame, p.Size, p.CanQuery = name, frame, size, true
    p.Parent = parent
    return p
end
local function rider(s)
    local c = Instance.new("Model")
    c.Name = "Rider"
    c.Parent = WORLD
    local root = s.CFrame * CFrame.new(0, RIDER_ROOT, 0)
    local hrp = box("HumanoidRootPart", c, root, Vector3.new(2, 2, 1))
    hrp.CanQuery = false
    box("UpperTorso", c, root * CFrame.new(0, 0.4, 0), Vector3.new(2, 1.6, 1))
    box("LowerTorso", c, root * CFrame.new(0, -0.6, 0), Vector3.new(2, 0.4, 1))
    box("Head", c, root * CFrame.new(0, 1.8, 0), Vector3.new(1.2, 1.2, 1.2))
    box("LeftUpperArm", c, root * CFrame.new(-1.5, 0.4, 0), Vector3.new(1, 1.6, 1))
    box("RightUpperArm", c, root * CFrame.new(1.5, 0.4, 0), Vector3.new(1, 1.6, 1))
    box("LeftUpperLeg", c, root * CFrame.new(-0.5, -1.2, -0.8), Vector3.new(1, 1, 2))
    box("RightUpperLeg", c, root * CFrame.new(0.5, -1.2, -0.8), Vector3.new(1, 1, 2))
    local h = Instance.new("Humanoid")
    h.SeatPart = s
    h.Parent = c
    for _, p in ipairs(c:GetChildren()) do
        if p:IsA("BasePart") and p.CanQuery then
            -- Grown past each face by more than riderBehind's 0.05 nudge: a limb that close to a panel
            -- can hold the point riderBehind starts from (or tie with the panel's face). Sampled on a
            -- grid, plus a point inside each panel that reaches into it (so a thin plate through the
            -- middle of an arm counts): some samples in the bodywork and some out is a clipped limb.
            local half = p.Size / 2 + Vector3.new(0.06, 0.06, 0.06)
            local inside, outside = 0, 0
            for x = -1, 1 do for y = -1, 1 do for z = -1, 1 do
                if inBody(p.CFrame * (half * Vector3.new(x, y, z))) then inside = inside + 1 else outside = outside + 1 end
            end end end
            for _, v in ipairs(bodywork) do
                if common(p.CFrame, half, v.CFrame, v.Size / 2) then inside = inside + 1 end
            end
            if inside > 0 and outside > 0 then
                report.clipped = report.clipped + 1
                if not CLIPPED then p.CanQuery = false end
            end
            report.parts = report.parts + 1
        end
    end
    return c
end

local dealt, vehicleHits, metCar
local CombatService = {
    HeadshotScale = 1,
    VehicleFromPart = function(p)
        local m = p and p:FindFirstAncestorOfClass("Model")
        if m == model then metCar = true end
        return m == model and m or nil
    end,
    DamageVehicle = function(_, m, amount) vehicleHits = vehicleHits + amount end,
    DealDamage = function(_, token, amount, _, headshot) table.insert(dealt, { token = token, amount = amount, headshot = headshot }) return amount end,
    DamageVeto = function() return false end,
}
local penv = setmetatable({
    PIERCE_TARGETS = 2, CombatService = CombatService, Combatants = Combatants,
    VehicleCover = Cover, LagCompensation = Lag, RaycastParams = RaycastParams, Enum = Enum, workspace = workspace,
}, { __index = _G })
local firePellet = assert(load(pelletSrc .. "\nreturn firePellet", "CombatService", "t", penv))()

local shooterChar = Instance.new("Model")
shooterChar.Name = "Shooter"
local shooter = { __player = true, ping = 0, GetNetworkPing = function(self) return self.ping end }
local def = { id = "Rifle", damage = 100, range = 600, headshotMultiplier = 1.5 }

local function refresh()
    local list = {}
    for _, p in ipairs(WORLD:GetDescendants()) do
        if p:IsA("BasePart") then
            local chain, a = {}, p
            while a and a ~= WORLD do table.insert(chain, a) a = a.Parent end
            table.insert(list, { part = p, chain = chain, radius = p.Size.Magnitude / 2 + 0.01 })
        end
    end
    SHOOTABLE = list
end

-- The car and its rider at `frame`.
local riderParts = {}
local function pose(frame)
    for _, e in ipairs(rigid) do e[1].CFrame = frame * e[2] end
    for _, e in ipairs(riderParts) do e[1].CFrame = frame * e[2] end
end

-- The lines: shooters on a ring 45 studs out every `grid.step` degrees at `grid.heights` (degrees up),
-- each aimed at the middle of every shootable part of the rider and at `grid.offsets` points off it.
local function lines(character)
    local aims = {}
    local offsets = { Vector3.new(0.3, 0.3, 0), Vector3.new(-0.3, -0.3, 0.3) }
    for _, p in ipairs(character:GetChildren()) do
        if p:IsA("BasePart") and p.CanQuery then
            local c, s = p.CFrame, p.Size
            table.insert(aims, c.p)
            for i = 1, grid.offsets do table.insert(aims, c * (s * offsets[i])) end
        end
    end
    local out = {}
    local centre = character:FindFirstChild("HumanoidRootPart").CFrame.p
    for az = 0, 359, grid.step do
        for _, el in ipairs(grid.heights) do
            local a, e = math.rad(az), math.rad(el)
            local from = centre + Vector3.new(math.cos(e) * math.sin(a), math.sin(e), math.cos(e) * math.cos(a)) * 45
            for _, aim in ipairs(aims) do table.insert(out, { from, aim }) end
        end
    end
    return out
end

local function fire(line, token, rewindTo)
    dealt, vehicleHits, lastVia, metCar = {}, 0, nil, false
    local from, to = line[1], line[2]
    firePellet(shooter, shooterChar, from, (to - from).Unit, def, rewindTo)
    local mine, head = 0, false
    for _, d in ipairs(dealt) do if d.token == token then mine = mine + d.amount head = head or d.headshot end end
    return { rider = mine, vehicle = vehicleHits, via = mine > 0 and lastVia or "-", head = head, car = metCar }
end

for _, s in ipairs(seats) do
    pose(CFrame.new())
    local character = rider(s)
    local token = { name = s.Name }
    registered = { [character] = token }
    riderParts = {}
    for _, p in ipairs(character:GetChildren()) do
        if p:IsA("BasePart") then table.insert(riderParts, { p, p.CFrame }) end
    end
    refresh()
    local shots = LINES and LINES(character, s) or lines(character)
    -- 0 ping: the car stands where the shooter saw it.
    pose(CFrame.new())
    Lag.Clear()
    local reference = {}
    for i, line in ipairs(shots) do reference[i] = fire(line, token, nil) end
    local hitAtAll = {}
    for i, r in ipairs(reference) do hitAtAll[i] = r.rider > 0 end
    for _, speed in ipairs(speeds) do
        for _, ping in ipairs(pings) do
            -- Driving forward (-Z) at `speed`, recorded every server step for 0.4 s; the shot arrives
            -- `now`, and the shooter saw the car at the origin (at the rewind instant).
            shooter.ping = ping
            local now = 100
            CLOCK = now
            local at = Lag.RewindTime(shooter, now)
            Lag.Clear()
            for step = 24, 0, -1 do
                local t = now - step / 60
                CLOCK = t
                pose(CFrame.new(0, 0, -speed * (t - at)))
                Lag.Record(t)
            end
            CLOCK = now
            pose(CFrame.new(0, 0, -speed * (now - at)))
            for i, line in ipairs(shots) do
                local r = fire(line, token, at)
                report.shots = report.shots + 1
                local ref = reference[i]
                if r.rider > 0 then hitAtAll[i] = true end
                local same = math.abs(r.rider - ref.rider) < 1e-6 and math.abs(r.vehicle - ref.vehicle) < 1e-6 and r.head == ref.head
                if not same then
                    local kind = ref.via .. " -> " .. r.via
                    local f, a = line[1], line[2]
                    local row = string.format("%s %s speed %d ping %dms: rider %.1f (%s) vehicle %.1f, at 0 ping rider %.1f (%s) vehicle %.1f; from (%.1f, %.1f, %.1f) at (%.2f, %.2f, %.2f)",
                        modelId, s.Name, speed, ping * 1000, r.rider, r.via, r.vehicle, ref.rider, ref.via, ref.vehicle, f.X, f.Y, f.Z, a.X, a.Y, a.Z)
                    if r.car and r.rider <= ref.rider + 1e-6 then
                        -- The present car met the shot first (it isn't rewound) and the rider took less
                        -- than at 0 ping: the known limit in riderBehind, counted, not failed.
                        report.intercepts = report.intercepts + 1
                        report.interceptKinds[kind] = (report.interceptKinds[kind] or 0) + 1
                        if #report.interceptRows < 20 then table.insert(report.interceptRows, row) end
                    else
                        report.mismatches = report.mismatches + 1
                        local key = string.format("%d studs/s, %d ms", speed, ping * 1000)
                        report.bySetting[key] = (report.bySetting[key] or 0) + 1
                        report.kinds[kind] = (report.kinds[kind] or 0) + 1
                        local ratio = ref.rider > 0 and r.rider / ref.rider or math.huge
                        if ratio > report.worst then report.worst = ratio end
                        if #report.rows < 400 then table.insert(report.rows, row) end
                    end
                end
            end
        end
    end
    for _, h in pairs(hitAtAll) do if h then report.candidates = report.candidates + 1 end end
    character.Parent = nil
end
report.seats = #seats
return report
"""


def models(root):
    """(modelId, unarmed) for every drivable model, and its unarmed build too where it has a mount."""
    rt = V.Runtime(V.load_sources(root))
    out = []
    for model_id in rt.ids:
        out.append((model_id, False))
        if model_id in rt.mounts:
            out.append((model_id, True))
    return out


def run(root, combat_src=None, lag_src=None, cover_src=None, only=None, grid=GATE, first=False, clipped=False):
    """One result per build. `first`: stop at the first build with a shot that differs (a planted fault
    only needs one); `clipped`: keep the limbs that touch the bodywork in the rig."""
    sources = V.load_sources(root)
    combat = pellet_source(combat_src or read(root, "ServerScriptService", "Modules", "CombatService.lua"))
    lag = V.luau_to_lua(lag_src or read(root, "ServerScriptService", "Modules", "LagCompensation.lua"))
    cover = V.luau_to_lua(cover_src or read(root, "ReplicatedStorage", "Shared", "VehicleCover.lua"))
    m = re.search(r"^local RIDER_ROOT = ([\d.]+)", read(root, "ReplicatedStorage", "Shared", "VehicleModels.lua"), re.M)
    if not m:
        sys.exit("rewound_cover_check: VehicleModels' RIDER_ROOT moved; update the harness")
    rider_root = float(m.group(1))
    results = []
    for model_id, unarmed in models(root):
        if only and model_id not in only:
            continue
        rt = V.Runtime(sources)
        rt.lua.execute(EXTRA)
        rt.lua.globals().CLIPPED = clipped
        go = rt.lua.execute("return function(...) " + HARNESS + " end")
        lua_grid = rt.lua.table_from({"step": grid["step"], "offsets": grid["offsets"],
                                      "heights": rt.lua.table_from(grid["heights"])})
        rep = go(rt.vm, lag, cover, combat, model_id, unarmed, rt.lua.table_from(grid["speeds"]),
                 rt.lua.table_from(grid["pings"]), rider_root, lua_grid)

        def listed(t):
            return [t[i] for i in range(1, len(t) + 1)]
        results.append({
            "model": model_id + (" (unarmed)" if unarmed else ""), "seats": rep["seats"], "shots": rep["shots"],
            "candidates": rep["candidates"], "mismatches": rep["mismatches"], "kinds": dict(rep["kinds"].items()),
            "rows": listed(rep["rows"]), "worst": rep["worst"], "clipped": rep["clipped"], "parts": rep["parts"],
            "intercepts": rep["intercepts"], "interceptKinds": dict(rep["interceptKinds"].items()),
            "interceptRows": listed(rep["interceptRows"]), "bySetting": dict(rep["bySetting"].items()),
        })
        if first and rep["mismatches"]:
            break
    return results


def summarize(results, show=0, quiet=False, clipped=False):
    shots = sum(r["shots"] for r in results)
    candidates = sum(r["candidates"] for r in results)
    bad = sum(r["mismatches"] for r in results)
    if quiet:
        return shots, candidates, bad
    for r in results:
        kinds = ", ".join("%s %d" % kv for kv in sorted(r["kinds"].items())) or "-"
        worst = ""
        if r["mismatches"]:
            worst = ", worst rider damage %s the 0-ping hit" % (
                "%.2fx" % r["worst"] if r["worst"] < 1e9 else "above nothing at")
        print(("ok    " if r["mismatches"] == 0 else "FAIL  ") + "%-28s %d seats, %5d candidate lines, %6d rewound shots: %d differ (%s)%s" % (
            r["model"], r["seats"], r["candidates"], r["shots"], r["mismatches"], kinds, worst))
    if bad:
        settings = {}
        for r in results:
            for k, v in r["bySetting"].items():
                settings[k] = settings.get(k, 0) + v
        order = sorted(settings, key=lambda k: tuple(int(x) for x in re.findall(r"\d+", k)))
        print("      differ by speed and ping: " + ", ".join("%s: %d" % (k, settings[k]) for k in order))
    for row in [row for r in results for row in r["rows"]][:show]:
        print("      " + row)
    # The known limit, reported, never failed: a shot the present car stopped first, the rider taking less.
    intercepts = sum(r["intercepts"] for r in results)
    kinds = {}
    for r in results:
        for k, v in r["interceptKinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    print("note  %d rewound shots met the PRESENT car first and the rider took less than at 0 ping (%s)" % (
        intercepts, ", ".join("%s %d" % kv for kv in sorted(kinds.items())) or "-"))
    for row in [row for r in results for row in r["interceptRows"]][:min(show, 5)]:
        print("      " + row)
    clipped_parts, parts = sum(r["clipped"] for r in results), sum(r["parts"] for r in results)
    print("note  %d of %d rider parts touch or straddle the bodywork's surface and are %s" % (
        clipped_parts, parts, "kept (--clipped)" if clipped else "left out of the rig"))
    return shots, candidates, bad


# Each plant breaks the invariant a different way; the check must fail on every one.
BODY_FIRST = (
    "\t\t\tlocal via\n"
    "\t\t\tif result.Rewound and result.Carry and bodyBetween(coverModel, from, to, params) then\n"
    "\t\t\t\t-- The world ray never met this car's body (it was somewhere else by now), so it's asked here.\n"
    "\t\t\t\tvia = \"body\"\n"
    "\t\t\telseif VehicleCover.CrossesGlass(coverModel, from, to) then\n"
    "\t\t\t\tvia = \"glass\"\n"
    "\t\t\telse\n"
    "\t\t\t\tvia = \"open\"\n"
    "\t\t\tend\n"
)
PLANTS = [
    # b254eac's order: glass asked before body.
    ("glass before body (b254eac)", "combat", BODY_FIRST,
     "\t\t\tlocal via = VehicleCover.CrossesGlass(coverModel, from, to) and \"glass\" or \"open\"\n"
     "\t\t\tif via == \"open\" and result.Rewound and result.Carry and bodyBetween(coverModel, from, to, params) then\n"
     "\t\t\t\tvia = \"body\"\n"
     "\t\t\tend\n"),
    # #97 F2 before b254eac: a rewound rider tested against the car where it is NOW.
    ("rewound shot not carried into the car's present frame", "combat",
     "\t\t\tif result.Rewound and result.Carry then\n\t\t\t\tlocal back = result.Carry:Inverse()",
     "\t\t\tif false then\n\t\t\t\tlocal back = result.Carry:Inverse()"),
    ("no body test for a rewound rider", "combat",
     "if result.Rewound and result.Carry and bodyBetween(coverModel, from, to, params) then",
     "if false then"),
    ("the carry the wrong way round", "lag",
     "local carry = past * root.CFrame:Inverse()", "local carry = root.CFrame * past:Inverse()"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    show = int(sys.argv[sys.argv.index("--list") + 1]) if "--list" in sys.argv else 0
    grid = DENSE if "--dense" in sys.argv else GATE
    if "--plant" in sys.argv:
        combat = read(root, "ServerScriptService", "Modules", "CombatService.lua")
        lag = read(root, "ServerScriptService", "Modules", "LagCompensation.lua")
        caught = 0
        for name, where, before, after in PLANTS:
            src = combat if where == "combat" else lag
            if before not in src:
                sys.exit("rewound_cover_check: plant target missing: " + name)
            planted = src.replace(before, after, 1)
            results = run(root, combat_src=planted if where == "combat" else None,
                          lag_src=planted if where == "lag" else None, grid=grid, first=True)
            _, _, bad = summarize(results, quiet=True)
            first = next((r["rows"][0] for r in results if r["rows"]), "")
            print(("CAUGHT  " if bad else "MISSED  ") + name + ("  <- %d shots differ, e.g. %s" % (bad, first) if bad else ""))
            caught += bool(bad)
        print("rewound_cover_check plants: %d of %d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    results = run(root, grid=grid, clipped="--clipped" in sys.argv)
    shots, candidates, bad = summarize(results, show, clipped="--clipped" in sys.argv)
    print("rewound_cover_check: %d builds, %d candidate lines, %d rewound shots, %d differ from 0 ping" % (
        len(results), candidates, shots, bad))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
