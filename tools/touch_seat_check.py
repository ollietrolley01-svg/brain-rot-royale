"""The phone's touch buttons in every state (the phone HUD polish, 2026-09-28).

ContextActionService draws at most SEVEN touch buttons, and one bound past that is drawn blank or not at
all and stays that way (Jacob's device-compat finding #1). The on-foot set is seven, so until this pass a
seat's buttons -- the driver's BRAKE and gun, the gunner's FIRE, AIM, RELOAD and LEAVE -- never showed on a
phone. PhoneLayout.TouchSet now says which buttons each state has, Settings takes the on-foot buttons away
and gives them back, and the seats' scripts bind through Settings.BindSeat. This checks all of it by
running the REAL Settings.lua and PhoneLayout.lua in lupa against a stand-in ContextActionService that
counts the touch buttons as they come and go:

  S1  every state has the buttons it needs, and no others: on foot the seven; with a coconut COOK in
      RELOAD's place; a driver BRAKE, the car's gun and LEAVE; a gunner the mount's FIRE, AIM, RELOAD and
      LEAVE; a passenger and a bike's rider their own FIRE, AIM, RELOAD and LEAVE (the rider BRAKE too);
      the lobby RUN and PET; the range the gun's three and RUN and PET; a spectator none.
  S2  never more than seven at once -- through every change of state, with the seat's own script and
      Settings' seat watcher running in either order.
  S3  every button at least a finger (44 px) on every phone and tablet size, both ways up.
  S4  none in Roblox's zones (the thumbstick's, the jump button, the top bar), none off the screen, none
      over the crosshair's box, no two on top of each other.
  S5  each button put on its square: the position ContextActionService is given is the slot's corner.
  S6  the source: every seat action is bound and unbound through Settings.BindSeat / UnbindSeat, and the
      on-foot actions through Settings.Bind / BindFixed, never straight to ContextActionService (which
      would put them back past the cap).
  S7  the emplacement gunner's panel (Rects().gunnerPanel) clear of the buttons, the stick, the jump
      button and the health row.

    python tools/touch_seat_check.py .           the checks
    python tools/touch_seat_check.py . --plant   the planted faults; every one must be caught

Needs lupa (`pip install lupa`).
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("touch_seat_check: needs lupa (pip install lupa)")

CLIENT = "StarterPlayerScripts"
CAP = 7
FINGER = 44

# (tag, width, height). Every touch screen PhoneLayout lays out: the phones on their side and upright, and
# the tablets.
SIZES = [("phone 667x375", 667, 375), ("phone 844x390", 844, 390), ("phone 932x430", 932, 430),
         ("phone upright 375x667", 375, 667), ("phone upright 390x844", 390, 844),
         ("tablet 1024x768", 1024, 768), ("tablet upright 768x1024", 768, 1024)]

# What each state must show, by label (the check's own list, not PhoneLayout's). Seat actions by name so
# the gunner's FIRE is the mount's, not the hand gun's.
NEED = {
    ("match", "foot", False): {"BRR_Fire", "BRR_Aim", "BRR_Reload", "BRR_Sprint", "BRR_Companion", "BRR_Crouch", "BRR_MovementItem"},
    ("match", "foot", True): {"BRR_Fire", "BRR_Aim", "BRR_Cook", "BRR_Sprint", "BRR_Companion", "BRR_Crouch", "BRR_MovementItem"},
    ("match", "driver", False): {"VehicleHandbrake", "BRR_VehicleFire", "BRR_SeatLeave"},
    ("match", "gunner", False): {"BRR_VehicleFire", "BRR_GunnerAim", "BRR_GunReload", "BRR_GunLeave"},
    ("match", "passenger", False): {"BRR_Fire", "BRR_Aim", "BRR_Reload", "BRR_SeatLeave"},
    ("match", "bike", False): {"BRR_Fire", "BRR_Aim", "BRR_Reload", "VehicleHandbrake", "BRR_SeatLeave"},
    ("lobby", "foot", False): {"BRR_Sprint", "BRR_Companion"},
    ("range", "foot", False): {"BRR_Fire", "BRR_Aim", "BRR_Reload", "BRR_Sprint", "BRR_Companion"},
    ("spectate", "foot", False): set(),
}

# Seat actions: who binds them.
SEAT_OWNERS = {"VehicleHandbrake": "VehicleClient.client.lua", "BRR_VehicleFire": "VehicleWeaponClient.client.lua",
               "BRR_GunnerAim": "VehicleWeaponClient.client.lua", "BRR_GunReload": "MountedGunClient.client.lua",
               "BRR_GunLeave": "MountedGunClient.client.lua", "BRR_Cook": "ProjectileClient.client.lua"}
ON_FOOT = ["BRR_Fire", "BRR_Aim", "BRR_Reload", "BRR_Sprint", "BRR_Companion", "BRR_Crouch", "BRR_MovementItem"]


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([-+*/]|\.\.)= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


# A small Roblox for Settings and PhoneLayout: services, signals, a player with a humanoid whose seat the
# sim changes, task with a clock the sim advances, and a ContextActionService that keeps count.
HARNESS = r"""
local sources = ...
local H = { log = {}, maxTouch = 0, violations = {}, now = 0, timers = {}, positions = {}, sizes = {} }

local function Signal()
    local s = { handlers = {} }
    function s:Connect(fn) table.insert(self.handlers, fn) ; return { Disconnect = function() end } end
    function s:Fire(...) for _, fn in ipairs(self.handlers) do fn(...) end end
    return s
end
H.Signal = Signal

-- Enum: any Enum.A.B is one table, the same every time.
local enumCache = {}
Enum = setmetatable({}, { __index = function(_, typeName)
    enumCache[typeName] = enumCache[typeName] or setmetatable({}, { __index = function(t, name)
        local item = { Name = name, EnumType = typeName, Value = #name, __enum = true }
        rawset(t, name, item)
        return item
    end })
    return enumCache[typeName]
end })
function typeof(v)
    if type(v) == "table" and v.__enum then return "EnumItem" end
    if type(v) == "table" and v.__instance then return "Instance" end
    return type(v)
end
math.clamp = function(x, a, b) return math.max(a, math.min(b, x)) end
Vector2 = { new = function(x, y) return { X = x or 0, Y = y or 0 } end }
UDim2 = { new = function(xs, xo, ys, yo) return { xs = xs, xo = xo, ys = ys, yo = yo } end,
    fromOffset = function(x, y) return { xs = 0, xo = x, ys = 0, yo = y } end,
    fromScale = function(x, y) return { xs = x, xo = 0, ys = y, yo = 0 } end }
Instance = { new = function(class)
    local inst = { ClassName = class, __instance = true }
    if class == "BindableEvent" then inst.Event = Signal() ; function inst:Fire(...) self.Event:Fire(...) end end
    return inst
end }
function warn(...) table.insert(H.log, table.concat({ ... }, " ")) end

-- task: spawn runs now in a coroutine; wait yields it for good (the settings load loop); delay/defer queue.
task = {
    spawn = function(fn, ...) local co = coroutine.create(fn) ; local ok, err = coroutine.resume(co, ...) ; if not ok then table.insert(H.violations, "error: " .. tostring(err)) end end,
    wait = function() coroutine.yield() end,
    delay = function(t, fn) table.insert(H.timers, { at = H.now + t, fn = fn }) end,
    defer = function(fn, ...) local a = { ... } ; table.insert(H.timers, { at = H.now, fn = function() fn(table.unpack(a)) end }) end,
}
function H.advance(dt)
    H.now = H.now + dt
    local again = true
    while again do
        again = false
        for i, t in ipairs(H.timers) do
            if t.at <= H.now then
                table.remove(H.timers, i)
                t.fn()
                again = true
                break
            end
        end
    end
end

-- ContextActionService, counting the touch buttons.
local bound = {}
H.bound = bound
local function touchCount()
    local n = 0
    for _, b in pairs(bound) do if b.touch then n = n + 1 end end
    return n
end
local CAS = {}
local function bind(name, handler, touch)
    bound[name] = { touch = touch == true, handler = handler }
    local n = touchCount()
    if n > H.maxTouch then H.maxTouch = n end
    if n > 7 then table.insert(H.violations, string.format("S2 %d touch buttons bound at once (binding %s)", n, name)) end
end
function CAS:BindAction(name, handler, touch, ...) bind(name, handler, touch) end
function CAS:BindActionAtPriority(name, handler, touch, priority, ...) bind(name, handler, touch) end
function CAS:UnbindAction(name) bound[name] = nil ; H.positions[name] = nil end
function CAS:SetTitle(name, title) if bound[name] then bound[name].title = title end end
function CAS:SetPosition(name, pos)
    if not (bound[name] and bound[name].touch) then error("SetPosition on " .. name .. ", which has no touch button") end
    H.positions[name] = pos
end
function CAS:GetButton(name)
    local b = bound[name]
    if not (b and b.touch) then return nil end
    b.button = b.button or setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) ; if k == "Size" then H.sizes[name] = v end end })
    return b.button
end
function CAS:GetBoundActionInfo(name)
    local b = bound[name]
    if not b then return {} end
    return { createTouchButton = b.touch, title = b.title }
end

-- The player, their humanoid and the seats.
local humanoid = { Health = 100, SeatPart = nil, __instance = true }
local seatSignal = Signal()
function humanoid:GetPropertyChangedSignal(prop) return prop == "SeatPart" and seatSignal or Signal() end
local character = { __instance = true, Name = "Character" }
function character:FindFirstChildOfClass(class) return class == "Humanoid" and humanoid or nil end
function character:WaitForChild(name) return name == "Humanoid" and humanoid or nil end
local player = { Character = character, CharacterAdded = Signal(), CharacterRemoving = Signal(), UserId = 1 }
function player:GetAttribute() return nil end
function player:SetAttribute() end
H.humanoid, H.seatSignal = humanoid, seatSignal

local function seat(class, name, kind)
    local vehicle = { __instance = true }
    function vehicle:GetAttribute(a) return a == "VehicleKind" and kind or nil end
    local s = { __instance = true, Name = name, Parent = vehicle, ClassName = class }
    function s:IsA(c) return c == class or (c == "Seat" and class == "Seat") end
    function s:GetAttribute() return nil end
    return s
end
H.seats = {
    driver = seat("VehicleSeat", "DriverSeat", "car"),
    bike = seat("VehicleSeat", "DriverSeat", "bike"),
    gunner = seat("Seat", "GunnerSeat", "car"),
    passenger = seat("Seat", "PassengerSeat", "car"),
    pillion = seat("Seat", "PassengerSeat", "bike"),
}

-- Remotes.
local remotes = {}
local Remotes = {
    Event = function(name) remotes[name] = remotes[name] or { OnClientEvent = Signal(), FireServer = function() end } ; return remotes[name] end,
    Function = function(name) return { InvokeServer = function() return nil end } end,
}
H.remote = function(name, ...) Remotes.Event(name).OnClientEvent:Fire(...) end

-- The camera and the services.
H.viewport = Vector2.new(844, 390)
local camera = { __instance = true }
setmetatable(camera, { __index = function(_, k) if k == "ViewportSize" then return H.viewport end end })
function camera:GetPropertyChangedSignal() return Signal() end
workspace = { CurrentCamera = camera }
local UIS = { TouchEnabled = true, KeyboardEnabled = false }
function UIS:GetPropertyChangedSignal() return Signal() end
local services = {
    ContextActionService = CAS, UserInputService = UIS,
    Players = { LocalPlayer = player },
    GuiService = { GetGuiInset = function() return Vector2.new(0, 36), Vector2.new(0, 0) end },
    RunService = { IsStudio = function() return true end },
}
local folder = {}
local modules = {}
local function scriptFor(name) return { Name = name, Parent = folder } end
function folder:WaitForChild(name) return modules[name] or { Name = name, __missing = true } end
local shared = {}
function shared:WaitForChild(name) return name == "Remotes" and { __remotes = true } or {} end
services.ReplicatedStorage = { WaitForChild = function(_, name) return shared end }
game = { GetService = function(_, name) return services[name] end }
H.UIS = UIS

local loaded = {}
local realRequire = require
function require(target)
    if type(target) ~= "table" then return realRequire(target) end
    if target.__remotes then return Remotes end
    if target.__missing then error("no module " .. tostring(target.Name)) end
    if loaded[target] then return loaded[target] end
    local src = sources[target.Name]
    local env = setmetatable({ script = scriptFor(target.Name) }, { __index = _G })
    local fn = assert(load(src, "=" .. target.Name, "t", env))
    loaded[target] = fn()
    return loaded[target]
end
for _, name in ipairs({ "PhoneLayout", "Settings" }) do
    modules[name] = { Name = name }
end
modules.TouchControls = { Name = "TouchControls" }
sources.TouchControls = "return { Enabled = false }"

H.PhoneLayout = require(modules.PhoneLayout)
H.Settings = require(modules.Settings)
return H
"""

SIM = r"""
local H, events = ...
local S, L = H.Settings, H.PhoneLayout
local noop = function() end

-- The on-foot binds, as CombatClient and MovementClient make them.
S.BindFixed("BRR_Fire", noop, { title = "FIRE", position = UDim2.new(1, -140, 1, -180) }, Enum.UserInputType.MouseButton1)
S.BindFixed("BRR_Aim", noop, { title = "AIM", position = UDim2.new(1, -250, 1, -180) }, Enum.UserInputType.MouseButton2)
S.Bind("BRR_Sprint", "Sprint", noop, { title = "RUN", position = UDim2.new(1, -250, 1, -280) })
S.Bind("BRR_Reload", "Reload", noop, { title = "RELOAD", position = UDim2.new(1, -140, 1, -280) })
S.Bind("BRR_Companion", "Companion", noop, { title = "PET", position = UDim2.new(1, -360, 1, -180) })
S.Bind("BRR_Crouch", "Crouch", noop, { title = "CROUCH", position = UDim2.new(1, -360, 1, -280), slot = "slide" })
S.Bind("BRR_MovementItem", "MovementItem", noop, { title = "MOVE", position = UDim2.new(1, -470, 1, -280) })
-- Keys that are not touch buttons.
S.Bind("BRR_Inspect", "Inspect", noop, nil)
H.advance(1)

local function touchSet()
    local out = {}
    for name, b in pairs(H.bound) do if b.touch then table.insert(out, name) end end
    table.sort(out)
    return table.concat(out, ",")
end

-- The seats' own scripts, as they bind (VehicleClient, VehicleWeaponClient, MountedGunClient).
local owners = {
    driver = function(on)
        if on then
            S.BindSeat("VehicleHandbrake", noop, { title = "BRAKE" }, 3000, Enum.KeyCode.LeftShift)
            S.BindSeat("BRR_VehicleFire", noop, { title = "FIRE" }, nil, Enum.UserInputType.MouseButton1)
        else
            S.UnbindSeat("VehicleHandbrake")
            S.UnbindSeat("BRR_VehicleFire")
            S.UnbindSeat("BRR_GunnerAim")
        end
    end,
    bike = function(on)
        if on then
            S.BindSeat("VehicleHandbrake", noop, { title = "BRAKE" }, 3000, Enum.KeyCode.LeftShift)
        else
            S.UnbindSeat("VehicleHandbrake")
        end
    end,
    gunner = function(on)
        if on then
            S.BindSeat("BRR_VehicleFire", noop, { title = "FIRE" }, nil, Enum.UserInputType.MouseButton1)
            S.BindSeat("BRR_GunnerAim", noop, { title = "AIM" }, nil, Enum.UserInputType.MouseButton2)
            S.BindSeat("BRR_GunReload", noop, { title = "RELOAD" }, 3000, Enum.KeyCode.R)
            S.BindSeat("BRR_GunLeave", noop, { title = "LEAVE" }, 3000, Enum.KeyCode.ButtonB)
        else
            S.UnbindSeat("BRR_VehicleFire")
            S.UnbindSeat("BRR_GunnerAim")
            S.UnbindSeat("BRR_GunReload")
            S.UnbindSeat("BRR_GunLeave")
        end
    end,
    passenger = function() end,
    pillion = function() end,
}

local out = {}
for _, ev in ipairs(events) do
    local kind, a, b = ev[1], ev[2], ev[3]
    if kind == "remote" then
        H.remote(a, b)
    elseif kind == "sit" then
        -- a: which seat; b: "watcher" (Settings' SeatPart listener hears first) or "owner" (the seat's script)
        H.humanoid.SeatPart = H.seats[a]
        if b == "watcher" then H.seatSignal:Fire() ; owners[a](true) else owners[a](true) ; H.seatSignal:Fire() end
        H.current = a
    elseif kind == "stand" then
        local was = H.current
        H.humanoid.SeatPart = nil
        if a == "watcher" then H.seatSignal:Fire() ; owners[was](false) else owners[was](false) ; H.seatSignal:Fire() end
        H.current = nil
    elseif kind == "cook" then
        if a then
            S.SetTouchFlag("cook", true)
            S.BindSeat("BRR_Cook", noop, { title = "COOK" }, 3000, Enum.KeyCode.World95)
        else
            S.UnbindSeat("BRR_Cook")
            S.SetTouchFlag("cook", false)
        end
    elseif kind == "snap" then
        H.advance(3)
        local positions = {}
        for name, pos in pairs(H.positions) do
            local size = H.sizes[name]
            positions[name] = { pos.xo + H.viewport.X, pos.yo + H.viewport.Y, size and size.xo or -1 }
        end
        table.insert(out, { label = a, set = touchSet(), positions = positions, state = L.TouchState.context .. "/" .. L.TouchState.seat })
    end
    H.advance(0.05)
end
return out, H.maxTouch, H.violations, H.log
"""

# The walk through the states: each "snap" names the state the buttons must match at that point.
WALK = [
    ("remote", "MatchChanged", "lobby-state"), ("snap", "lobby"),
    ("remote", "MatchChanged", "InProgress"), ("remote", "LoadoutChanged", True), ("snap", "match/foot"),
    ("cook", True), ("snap", "match/foot/cook"), ("cook", False), ("snap", "match/foot"),
    ("sit", "driver", "watcher"), ("snap", "match/driver"), ("stand", "watcher"), ("snap", "match/foot"),
    ("sit", "driver", "owner"), ("snap", "match/driver"), ("stand", "owner"), ("snap", "match/foot"),
    ("sit", "gunner", "watcher"), ("snap", "match/gunner"), ("stand", "watcher"), ("snap", "match/foot"),
    ("sit", "gunner", "owner"), ("snap", "match/gunner"), ("stand", "owner"), ("snap", "match/foot"),
    ("sit", "passenger", "watcher"), ("snap", "match/passenger"), ("stand", "watcher"), ("snap", "match/foot"),
    ("sit", "pillion", "watcher"), ("snap", "match/passenger"), ("stand", "watcher"), ("snap", "match/foot"),
    ("sit", "bike", "watcher"), ("snap", "match/bike"), ("stand", "watcher"), ("snap", "match/foot"),
    ("sit", "bike", "owner"), ("snap", "match/bike"), ("stand", "owner"), ("snap", "match/foot"),
    ("remote", "Spectate", True), ("snap", "spectate"), ("remote", "Spectate", False),
    ("remote", "LoadoutChanged", None), ("remote", "MatchChanged", "Waiting"), ("snap", "lobby"),
    ("remote", "RangeState", True), ("snap", "range"), ("remote", "RangeState", False), ("snap", "lobby"),
]
SNAP_NEED = {"lobby": ("lobby", "foot", False), "match/foot": ("match", "foot", False),
             "match/foot/cook": ("match", "foot", True), "match/driver": ("match", "driver", False),
             "match/gunner": ("match", "gunner", False), "match/passenger": ("match", "passenger", False),
             "match/bike": ("match", "bike", False), "spectate": ("spectate", "foot", False),
             "range": ("range", "foot", False)}


def load_sources(root, overrides=None):
    src = {}
    for name in ("PhoneLayout", "Settings"):
        src[name] = open(os.path.join(root, CLIENT, name + ".lua"), encoding="utf-8").read()
    src.update(overrides or {})
    return {k: luau_to_lua(v) for k, v in src.items()}


def to_lua_events(lua, walk):
    table = lua.table()
    for i, ev in enumerate(walk, 1):
        row = lua.table()
        for j, v in enumerate(ev, 1):
            if ev[0] == "remote" and ev[1] == "MatchChanged" and j == 3:
                v = lua.table_from({"state": "Waiting" if v == "lobby-state" else v})
            row[j] = v
        table[i] = row
    return table


def overlap(a, b):
    w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
    h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
    return w > 0.5 and h > 0.5


def run_sim(root, overrides=None, verbose=False):
    """S1, S2, S5: the real Settings and PhoneLayout through the walk."""
    problems = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = lua.table_from(load_sources(root, overrides))
    try:
        H = lua.execute(HARNESS, sources)
        snaps, max_touch, violations, log = lua.execute(SIM, H, to_lua_events(lua, WALK))
    except Exception as err:  # a planted fault can break the load itself
        return [f"S0 the harness did not run: {str(err)[:300]}"]
    for i in range(1, len(violations) + 1):
        problems.append(violations[i])
    L = H.PhoneLayout
    rects = L.Rects(lua.eval("function(x, y) return Vector2.new(x, y) end")(844, 390))
    for i in range(1, len(snaps) + 1):
        snap = snaps[i]
        need = SNAP_NEED[snap.label]
        got = set(filter(None, snap.set.split(",")))
        want = NEED[need]
        if got != want:
            problems.append(f"S1 {snap.label} (step {i}, state {snap.state}): buttons {sorted(got)}, needs {sorted(want)}")
        # S5: each on its slot's square at 844x390, sized to it once the button turns up.
        slots = {}
        for entry in L.TouchSet(need[0], need[1], lua.table_from({"cook": need[2] or None})).values():
            slots[entry.action] = entry.slot
        for name in got:
            pos = snap.positions[name]
            slot = slots.get(name)
            if pos is None or slot is None:
                problems.append(f"S5 {snap.label}: {name} was never placed" if pos is None else f"S5 {snap.label}: {name} has no slot")
                continue
            r = rects[slot]
            if abs(pos[1] - r.x) > 0.5 or abs(pos[2] - r.y) > 0.5 or abs(pos[3] - r.w) > 0.5:
                problems.append(f"S5 {snap.label}: {name} placed at ({pos[1]:.0f}, {pos[2]:.0f}) size {pos[3]:.0f}, "
                                f"its square {slot} is ({r.x:.0f}, {r.y:.0f}) size {r.w:.0f}")
    if max_touch > CAP:
        problems.append(f"S2 {max_touch} touch buttons were up at once (the cap is {CAP})")
    if verbose:
        print(f"touch_seat_check: walked {len(WALK)} steps, {len(snaps)} states compared; most touch buttons at once: {max_touch}")
        for i in range(1, len(log) + 1):
            print("   log:", log[i])
    return problems


def run_layout(root, overrides=None, verbose=False):
    """S3, S4, S7: every state's buttons on every size."""
    problems = []
    lua = LuaRuntime(unpack_returned_tuples=True)
    sources = lua.table_from(load_sources(root, overrides))
    try:
        H = lua.execute(HARNESS, sources)
    except Exception as err:
        return [f"S0 the harness did not run: {str(err)[:300]}"]
    L = H.PhoneLayout
    V = lua.eval("function(x, y) return Vector2.new(x, y) end")
    checked = 0
    for tag, w, h in SIZES:
        spots = L.Rects(V(w, h))
        R = lambda name: (spots[name].x, spots[name].y, spots[name].w, spots[name].h) if spots[name] else None
        zones = {"the thumbstick's zone": R("moveZone"), "the jump button": R("jump"), "Roblox's top bar": R("topBar")}
        cross = (w / 2 - 12 - 6, h / 2 - 12 - 6, 36, 36)
        for (context, seat, cook), want in NEED.items():
            flags = lua.table_from({"cook": True if cook else None, "armed": True})
            buttons = [(b.label, b.action, (b.x, b.y, b.w, b.h)) for b in L.TouchButtons(V(w, h), context, seat, flags).values()]
            state = f"{context}/{seat}{'/cook' if cook else ''}"
            if len(buttons) > CAP:
                problems.append(f"S2 [{tag}] {state}: {len(buttons)} buttons, over the cap of {CAP}")
            for label, action, r in buttons:
                checked += 1
                if min(r[2], r[3]) < FINGER - 0.01:
                    problems.append(f"S3 [{tag}] {state}: {label} is {min(r[2], r[3]):.0f} px, under a finger ({FINGER})")
                for zone, z in zones.items():
                    if z and overlap(r, z):
                        problems.append(f"S4 [{tag}] {state}: {label} {tuple(round(v) for v in r)} is in {zone}")
                if r[0] < -0.5 or r[1] < -0.5 or r[0] + r[2] > w + 0.5 or r[1] + r[3] > h + 0.5:
                    problems.append(f"S4 [{tag}] {state}: {label} {tuple(round(v) for v in r)} is off the screen")
                if overlap(r, cross):
                    problems.append(f"S4 [{tag}] {state}: {label} is over the crosshair's box")
            for i in range(len(buttons)):
                for j in range(i + 1, len(buttons)):
                    if overlap(buttons[i][2], buttons[j][2]):
                        problems.append(f"S4 [{tag}] {state}: {buttons[i][0]} and {buttons[j][0]} overlap")
        # S7: the emplacement gunner's panel.
        panel = R("gunnerPanel")
        if panel is None:
            problems.append(f"S7 [{tag}] no gunnerPanel slot")
        else:
            gunner = [(b.label, (b.x, b.y, b.w, b.h)) for b in L.TouchButtons(V(w, h), "match", "gunner", None).values()]
            others = gunner + [("the stick", R("stick")), ("the jump button", R("jump")), ("the health row", R("health")),
                               ("the crosshair's box", cross)]
            for name, r in others:
                if r and overlap(panel, r):
                    problems.append(f"S7 [{tag}] the gunner's panel {tuple(round(v) for v in panel)} overlaps {name}")
            if panel[0] < -0.5 or panel[1] < -0.5 or panel[0] + panel[2] > w + 0.5 or panel[1] + panel[3] > h + 0.5:
                problems.append(f"S7 [{tag}] the gunner's panel is off the screen")
    if verbose:
        print(f"touch_seat_check: {len(SIZES)} sizes x {len(NEED)} states, {checked} buttons placed")
    return problems


def run_source(root, overrides=None, verbose=False):
    """S6: every seat action through BindSeat/UnbindSeat; the on-foot ones through Settings."""
    problems = []
    files = {}
    for name in sorted(os.listdir(os.path.join(root, CLIENT))):
        if name.endswith(".lua"):
            files[name] = open(os.path.join(root, CLIENT, name), encoding="utf-8").read()
    files.update(overrides or {})
    raw = re.compile(r'ContextActionService:(BindAction|BindActionAtPriority|UnbindAction)\(\s*"(\w+)"')
    for name, text in files.items():
        if name in ("TouchControls.lua", "Settings.lua"):
            continue
        for m in raw.finditer(text):
            if m.group(2) in SEAT_OWNERS or m.group(2) in ON_FOOT:
                line = text.count("\n", 0, m.start()) + 1
                problems.append(f"S6 {name}:{line}: {m.group(2)} goes straight to ContextActionService:{m.group(1)}; "
                                "it must go through Settings (BindSeat / UnbindSeat, Bind / BindFixed) or it comes back past the cap")
    for action, owner in SEAT_OWNERS.items():
        text = files.get(owner, "")
        needle = action if action in text else None
        if action in ("BRR_GunReload", "BRR_GunLeave"):
            ok = f'"{action}"' in text and "Settings.BindSeat(reload.action" in text and "Settings.BindSeat(leave.action" in text
        elif action == "BRR_Cook":
            ok = "Settings.BindSeat(COOK_ACTION" in text and "Settings.UnbindSeat(COOK_ACTION" in text
        else:
            ok = needle is not None and f'Settings.BindSeat("{action}"' in text and f'Settings.UnbindSeat("{action}"' in text
        if not ok:
            problems.append(f"S6 {owner}: {action} is not bound and unbound through Settings.BindSeat / UnbindSeat")
    combat = files.get("CombatClient.client.lua", "")
    for action in ("BRR_Fire", "BRR_Aim"):
        if f'Settings.BindFixed("{action}"' not in combat:
            problems.append(f"S6 CombatClient.client.lua: {action} is not bound through Settings.BindFixed")
    if verbose:
        print(f"touch_seat_check: {len(files)} client files read for raw ContextActionService binds of {len(SEAT_OWNERS) + len(ON_FOOT)} actions")
    return problems


def check(root, overrides=None, verbose=True):
    layout_over = {k: v for k, v in (overrides or {}).items() if k in ("PhoneLayout", "Settings")}
    source_over = {k: v for k, v in (overrides or {}).items() if k.endswith(".lua")}
    return (run_sim(root, layout_over, verbose) + run_layout(root, layout_over, verbose)
            + run_source(root, source_over, verbose))


# (what, file key, anchor, replacement). File key "PhoneLayout"/"Settings" for the modules the sim loads,
# or "<name>.lua" for the source check.
PLANTS = [
    ("the driver keeps the on-foot set as well (11 buttons asked for)", "PhoneLayout",
     'driver = { { "BRR_VehicleFire", "fire", armed = true },',
     'driver = { { "BRR_Fire", "fire" }, { "BRR_Aim", "aim" }, { "BRR_Reload", "reload" }, { "BRR_Sprint", "run" }, { "BRR_Companion", "pet" }, { "BRR_Crouch", "slide" }, { "BRR_MovementItem", "move" }, { "BRR_VehicleFire", "fire", armed = true },'),
    ("the on-foot buttons come back before the seat's have gone", "Settings",
     "and staleSeatButton(layout)", "and nil"),
    ("drops and gains in one pass (a gain can come before a drop)", "Settings",
     "\t\t\telseif want and not binding.buttonShown then\n\t\t\t\ttable.insert(gaining, binding)",
     "\t\t\telseif want and not binding.buttonShown then\n\t\t\t\tapplyBinding(binding)"),
    ("every button wanted in every state", "PhoneLayout",
     "\tif not UserInputService.TouchEnabled then\n\t\treturn false\n\tend\n\tlocal state = PhoneLayout.TouchState",
     "\tif not UserInputService.TouchEnabled then\n\t\treturn false\n\tend\n\tdo return true, 'fire' end\n\tlocal state = PhoneLayout.TouchState"),
    ("the lobby keeps FIRE", "PhoneLayout",
     "lobby = { BRR_Sprint = true, BRR_Companion = true },", "lobby = { BRR_Sprint = true, BRR_Companion = true, BRR_Fire = true },"),
    ("the gunner has no LEAVE", "PhoneLayout", ', { "BRR_GunLeave", "move" } },', " },"),
    ("buttons placed where they were, not on their squares", "PhoneLayout",
     "\tlocal x, y = r.x + (r.w - size) / 2, r.y + (r.h - size) / 2", "\tlocal x, y = r.x + 30, r.y"),
    ("a button 36 px across", "PhoneLayout", "\tlocal B, F = 48 * k, 72 * k", "\tlocal B, F = 36 * k, 72 * k"),
    ("the cluster slid into the thumbstick's zone", "PhoneLayout",
     "\tlocal fireX = jumpX - g - F\n", "\tlocal fireX = 0.3 * W\n"),
    ("the gunner's panel on the health row", "PhoneLayout",
     "\tout.gunnerPanel = rect(bandLeft + (bandW - gunW) / 2, bottom - 46 * gunW / 240, gunW, 46 * gunW / 240)",
     "\tout.gunnerPanel = rect(out.health.x, out.health.y, gunW, 46 * gunW / 240)"),
    ("BRAKE bound straight to ContextActionService", "VehicleClient.client.lua",
     'Settings.BindSeat("VehicleHandbrake", onHandbrake,',
     'ContextActionService:BindActionAtPriority("VehicleHandbrake", onHandbrake,'),
    ("FIRE bound straight to ContextActionService", "CombatClient.client.lua",
     'Settings.BindFixed("BRR_Fire", function', 'ContextActionService:BindAction("BRR_Fire", function'),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    if "--plant" in sys.argv:
        missed = 0
        for what, key, anchor, replacement in PLANTS:
            path = os.path.join(root, CLIENT, key if key.endswith(".lua") else key + ".lua")
            text = open(path, encoding="utf-8").read()
            if anchor not in text:
                print(f"PLANT ANCHOR MISSING ({what}): {anchor[:70]!r} not in {key}")
                missed += 1
                continue
            problems = check(root, {key: text.replace(anchor, replacement, 1)}, verbose=False)
            print(f"plant: {what}: {'CAUGHT' if problems else 'MISSED'} ({len(problems)} problems)")
            for p in problems[:2]:
                print("   ", p[:200])
            missed += 0 if problems else 1
        print(f"plants: {len(PLANTS) - missed}/{len(PLANTS)} caught")
        sys.exit(1 if missed else 0)
    problems = check(root)
    for p in problems:
        print("PROBLEM", p)
    print(f"problems: {len(problems)}")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
