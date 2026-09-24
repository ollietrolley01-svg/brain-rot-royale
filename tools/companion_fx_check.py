"""Companion ability effects and animation check (OLIVER_LIST A5, the 2026-09-24 effects pass), without
Studio.

Runs the REAL StarterPlayerScripts/CompanionFxClient.client.lua, ReplicatedStorage/Shared/
CompanionAnimations.lua, BrainrotData.lua, Rarity.lua and SoundConfig.lua in a Lua interpreter (lupa)
inside a mocked world: a working Vector3/CFrame, an Instance tree that refuses a property its class
does not have (or a value of the wrong type -- Roblox throws on both), particle emitters that count
what they Emit, a frame clock the check owns. The client is handed that world through its harness
seam (`__companionFxHarness`), so every line that runs here is the line that ships. The server half
runs the REAL ServerScriptService/Modules/CompanionService.lua (tools/companion_ability_check.py's
mocks, with a clock that keeps time) to prove the timing the client is drawn to is the timing the
damage lands on.

What it holds the code to (every number here is written independently of the code's own constants):

  server     for every move, on every path (a target, a point, the lobby demo): the broadcast's
             `lands` is exactly when the damage lands (or the demo's job is due) after it is sent;
             `windup` is the windup; a blast brainrot's use is broadcast as a Blast with lands 0; the
             hit broadcast names its victims beside its positions and carries the style's real length
  timing     for every move x every style it can carry (41 pairs, plus the plain six and Blast): the
             client's strike lands on `windup` and its landing on `lands`, each within one frame
  signature  each move draws its own shapes; each style its signature (Slow's ice crown, Daze's
             stars, Burn's flames, Toxic's puddle, Leech's ribbon, Wide's wider wave, Quick's streaks,
             Long's aim line, Fork's arc) -- by the instances it builds
  caps       under a 40-companion stress run and a one-companion flood: at most 16 effects a
             companion and 64 in all, 600 live particles, 8 lights, 4 rim glows; no emitter left on
             a rate; no instance alive longer than 4.5 s; nothing drawn past 450 studs, no particles,
             lights or glows past 160 (unless it's your own companion)
  cleanup    once everything has played out: the effects folder is empty, and so are the client's
             live list, schedule and budgets
  owner      your own companion's strike and hits pulse the screen edge, never darker than 0.22;
             nobody else's ever does
  sounds     every cue the client can play is in SoundConfig
  brainrots  all 126 resolve to a move the client draws, a style it has a signature for, a body the
             animations know; every clip on every body starts and ends on the idle pose (no pop),
             never jumps more than a frame's worth, glows hardest on its strike, and is over before
             the shortest cooldown of any brainrot with that move

    python3 tools/companion_fx_check.py .            the checks
    python3 tools/companion_fx_check.py . --plant    planted faults; every one must be caught

Needs `pip install lupa`. Luau compound assignments are rewritten to plain Lua before loading.
"""

import importlib.util
import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("companion_fx_check: needs lupa (pip install lupa)")

CLIENT = "StarterPlayerScripts/CompanionFxClient.client.lua"
ANIM = "ReplicatedStorage/Shared/CompanionAnimations.lua"
DATA = "ReplicatedStorage/Shared/BrainrotData.lua"
RARITY = "ReplicatedStorage/Shared/Rarity.lua"
SOUNDS = "ReplicatedStorage/Shared/SoundConfig.lua"
SERVICE = "ServerScriptService/Modules/CompanionService.lua"

# The stated caps, written here and NOT read from the client: raising a constant there must fail.
CAP_PER_COMPANION = 16
CAP_EFFECTS = 64
CAP_PARTICLES = 600
CAP_LIGHTS = 8
CAP_HIGHLIGHTS = 4
CAP_LIFE = 4.5
CAP_VIGNETTE = 0.22
CULL = 450
DETAIL = 160
WINDUP = 0.15
FRAME = 1 / 60


def luau_to_lua(source):
    return re.sub(r"^(\s*)([\w.\[\]]+) ([+\-*/])= (.+)$", r"\1\2 = \2 \3 (\4)", source, flags=re.M)


def read(root, rel):
    return open(os.path.join(root, rel), encoding="utf-8").read()


# --------------------------------------------------------------------------------------------------
# The mocked world
# --------------------------------------------------------------------------------------------------

WORLD = r"""
local world = {}
_G.world = world
world.t = 0
math.clamp = function(x, a, b) if x < a then return a elseif x > b then return b end return x end
-- Luau keeps atan2; Lua 5.4+ folded it into atan.
math.atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
table.clear = function(t) for k in pairs(t) do t[k] = nil end end
table.find = function(t, v) for i, x in ipairs(t) do if x == v then return i end end return nil end

-- Vector3 ---------------------------------------------------------------------------------------
local V = {}
local function vec(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, V) end
V.__index = function(v, k)
    if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
    if k == "Unit" then
        local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
        if m == 0 then return vec(0 / 0, 0 / 0, 0 / 0) end
        return vec(v.X / m, v.Y / m, v.Z / m)
    end
    return V[k]
end
V.__add = function(a, b) assert(getmetatable(a) == V and getmetatable(b) == V, "Vector3 + non-Vector3"); return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V.__sub = function(a, b) assert(getmetatable(a) == V and getmetatable(b) == V, "Vector3 - non-Vector3"); return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V.__mul = function(a, b)
    if type(a) == "number" then a, b = b, a end
    if type(b) == "number" then return vec(a.X * b, a.Y * b, a.Z * b) end
    return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V.__div = function(a, b)
    if type(b) == "number" then return vec(a.X / b, a.Y / b, a.Z / b) end
    return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V.__unm = function(a) return vec(-a.X, -a.Y, -a.Z) end
V.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V.__tostring = function(v) return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z) end
function V.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
function V.Cross(a, b) return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X) end
function V.Lerp(a, b, t) return vec(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t) end
Vector3 = { new = function(x, y, z) return vec(x or 0, y or 0, z or 0) end }
Vector3.zero = vec(0, 0, 0)
Vector3.one = vec(1, 1, 1)
Vector3.xAxis = vec(1, 0, 0)
Vector3.yAxis = vec(0, 1, 0)
Vector3.zAxis = vec(0, 0, 1)
world.V = V

-- CFrame: a rotation (rows) and a position ---------------------------------------------------------
local C = {}
local function cf(px, py, pz, r)
    return setmetatable({ px = px, py = py, pz = pz, r = r }, C)
end
local I3 = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
local function mulR(a, b)
    local o = {}
    for i = 0, 2 do
        for j = 0, 2 do
            o[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
        end
    end
    return o
end
local function applyR(r, x, y, z)
    return r[1] * x + r[2] * y + r[3] * z, r[4] * x + r[5] * y + r[6] * z, r[7] * x + r[8] * y + r[9] * z
end
local function transpose(r) return { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] } end
C.__index = function(c, k)
    if k == "Position" or k == "p" then return vec(c.px, c.py, c.pz) end
    if k == "X" then return c.px end
    if k == "Y" then return c.py end
    if k == "Z" then return c.pz end
    if k == "RightVector" then return vec(c.r[1], c.r[4], c.r[7]) end
    if k == "UpVector" then return vec(c.r[2], c.r[5], c.r[8]) end
    if k == "LookVector" then return vec(-c.r[3], -c.r[6], -c.r[9]) end
    if k == "Rotation" then return cf(0, 0, 0, c.r) end
    return C[k]
end
C.__mul = function(a, b)
    if getmetatable(b) == C then
        local x, y, z = applyR(a.r, b.px, b.py, b.pz)
        return cf(a.px + x, a.py + y, a.pz + z, mulR(a.r, b.r))
    end
    assert(getmetatable(b) == V, "CFrame * non-CFrame/Vector3")
    local x, y, z = applyR(a.r, b.X, b.Y, b.Z)
    return vec(a.px + x, a.py + y, a.pz + z)
end
C.__add = function(a, b) return cf(a.px + b.X, a.py + b.Y, a.pz + b.Z, a.r) end
C.__sub = function(a, b) return cf(a.px - b.X, a.py - b.Y, a.pz - b.Z, a.r) end
function C.Inverse(c)
    local t = transpose(c.r)
    local x, y, z = applyR(t, c.px, c.py, c.pz)
    return cf(-x, -y, -z, t)
end
function C.PointToObjectSpace(c, v) return c:Inverse() * v end
function C.PointToWorldSpace(c, v) return c * v end
function C.VectorToWorldSpace(c, v) local x, y, z = applyR(c.r, v.X, v.Y, v.Z); return vec(x, y, z) end
function C.VectorToObjectSpace(c, v) local x, y, z = applyR(transpose(c.r), v.X, v.Y, v.Z); return vec(x, y, z) end
function C.ToObjectSpace(c, o) return c:Inverse() * o end
local function axisAngles(rx, ry, rz)
    local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    local Rx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
    local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
    local Rz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
    return mulR(mulR(Rx, Ry), Rz)
end
local function columns(x, y, z)
    return { x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z }
end
CFrame = {
    new = function(a, b, c)
        if a == nil then return cf(0, 0, 0, I3) end
        if getmetatable(a) == V then return cf(a.X, a.Y, a.Z, I3) end
        return cf(a, b, c, I3)
    end,
    Angles = function(rx, ry, rz) return cf(0, 0, 0, axisAngles(rx, ry, rz)) end,
    lookAt = function(eye, target, up)
        up = up or vec(0, 1, 0)
        local look = (target - eye).Unit
        local right = look:Cross(up)
        if right.Magnitude < 1e-6 then right = vec(1, 0, 0) else right = right.Unit end
        local up2 = right:Cross(look)
        return cf(eye.X, eye.Y, eye.Z, columns(right, up2, -look))
    end,
    fromMatrix = function(p, x, y, z)
        z = z or x:Cross(y).Unit
        return cf(p.X, p.Y, p.Z, columns(x, y, z))
    end,
}
CFrame.identity = CFrame.new()
world.C = C

-- Colours and sequences --------------------------------------------------------------------------
local Col = {}
Col.__index = Col
local function col(r, g, b) return setmetatable({ R = r, G = g, B = b }, Col) end
function Col.Lerp(a, b, t) return col(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
Color3 = {
    new = function(r, g, b) return col(r or 0, g or 0, b or 0) end,
    fromRGB = function(r, g, b) return col(r / 255, g / 255, b / 255) end,
    fromHSV = function(h, s, v)
        local i = math.floor(h * 6)
        local f = h * 6 - i
        local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
        i = i % 6
        if i == 0 then return col(v, t, p) elseif i == 1 then return col(q, v, p) elseif i == 2 then return col(p, v, t)
        elseif i == 3 then return col(p, q, v) elseif i == 4 then return col(t, p, v) end
        return col(v, p, q)
    end,
}
world.Col = Col
local Seq = {}
Seq.__index = Seq
ColorSequenceKeypoint = { new = function(t, c) return { Time = t, Value = c } end }
NumberSequenceKeypoint = { new = function(t, v, e) return { Time = t, Value = v, Envelope = e or 0 } end }
ColorSequence = { new = function(a, b)
    assert(a ~= nil, "ColorSequence.new(nil)")
    if getmetatable(a) == Col then return setmetatable({ kind = "ColorSequence", Keypoints = { { Time = 0, Value = a }, { Time = 1, Value = b or a } } }, Seq) end
    return setmetatable({ kind = "ColorSequence", Keypoints = a }, Seq)
end }
NumberSequence = { new = function(a, b)
    if type(a) == "number" then
        assert(a == a, "NumberSequence of NaN")
        return setmetatable({ kind = "NumberSequence", Keypoints = { { Time = 0, Value = a }, { Time = 1, Value = b or a } } }, Seq)
    end
    return setmetatable({ kind = "NumberSequence", Keypoints = a }, Seq)
end }
NumberRange = { new = function(a, b) return { kind = "NumberRange", Min = a, Max = b or a } end }
Vector2 = { new = function(x, y) return { kind = "Vector2", X = x or 0, Y = y or 0 } end }
UDim2 = {
    new = function(a, b, c, d) return { kind = "UDim2" } end,
    fromScale = function() return { kind = "UDim2" } end,
    fromOffset = function() return { kind = "UDim2" } end,
}
UDim = { new = function() return { kind = "UDim" } end }

local EnumMT = {}
EnumMT.__index = function(t, k)
    local v = setmetatable({}, { __index = function(_, item) return "Enum." .. k .. "." .. item end })
    rawset(t, k, v)
    return v
end
Enum = setmetatable({}, EnumMT)

-- A deterministic Random.
Random = { new = function(seed)
    local state = seed or 12345
    local r = {}
    local function nxt()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
    function r:NextNumber(a, b) a = a or 0; b = b or 1; return a + (b - a) * nxt() end
    function r:NextInteger(a, b) return a + math.floor(nxt() * (b - a + 1)) end
    function r:NextUnitVector()
        local z = nxt() * 2 - 1
        local a = nxt() * math.pi * 2
        local s = math.sqrt(1 - z * z)
        return vec(math.cos(a) * s, z, math.sin(a) * s)
    end
    return r
end }

-- Signals ------------------------------------------------------------------------------------------
world.errors = {}
local function signal()
    local s = { fns = {} }
    function s:Connect(fn)
        local entry = { fn = fn }
        table.insert(self.fns, entry)
        return { Disconnect = function() entry.dead = true end }
    end
    function s:Fire(...)
        for _, entry in ipairs(self.fns) do
            if not entry.dead then
                -- Roblox logs an error in a connection and carries on; so does this, and the check fails on it.
                local ok, err = pcall(entry.fn, ...)
                if not ok then table.insert(world.errors, tostring(err)) end
            end
        end
    end
    return s
end
world.signal = signal

-- Instances ----------------------------------------------------------------------------------------
-- Properties each class may be given, and the type each must be. A name not listed is an error, as
-- it is in Roblox.
local T = function(name) return name end
local COMMON = { Name = "string", Parent = "any", Archivable = "boolean" }
local PROPS = {
    Part = { Size = "Vector3", Transparency = "number", Anchored = "boolean", CanCollide = "boolean", CanQuery = "boolean",
        CanTouch = "boolean", CastShadow = "boolean", CFrame = "CFrame", Position = "Vector3", Color = "Color3",
        Material = "string", Shape = "string", Massless = "boolean", Reflectance = "number" },
    Attachment = { Position = "Vector3", CFrame = "CFrame" },
    Beam = { Attachment0 = "Instance", Attachment1 = "Instance", Texture = "string", TextureMode = "string",
        TextureLength = "number", TextureSpeed = "number", Color = "ColorSequence", Transparency = "NumberSequence",
        Width0 = "number", Width1 = "number", LightEmission = "number", LightInfluence = "number", FaceCamera = "boolean",
        Segments = "number", CurveSize0 = "number", CurveSize1 = "number", ZOffset = "number", Enabled = "boolean", Brightness = "number" },
    Trail = { Attachment0 = "Instance", Attachment1 = "Instance", Texture = "string", Color = "ColorSequence",
        Transparency = "NumberSequence", WidthScale = "NumberSequence", Lifetime = "number", LightEmission = "number",
        LightInfluence = "number", FaceCamera = "boolean", MinLength = "number", MaxLength = "number", Enabled = "boolean" },
    ParticleEmitter = { Enabled = "boolean", Texture = "string", Color = "ColorSequence", Size = "NumberSequence",
        Transparency = "NumberSequence", Lifetime = "NumberRange", Speed = "NumberRange", SpreadAngle = "Vector2",
        Acceleration = "Vector3", Drag = "number", LightEmission = "number", LightInfluence = "number", Rotation = "NumberRange",
        RotSpeed = "NumberRange", EmissionDirection = "string", ZOffset = "number", Shape = "string", ShapeStyle = "string",
        ShapeInOut = "string", Rate = "number", LockedToPart = "boolean", Brightness = "number" },
    PointLight = { Color = "Color3", Range = "number", Brightness = "number", Shadows = "boolean", Enabled = "boolean" },
    Highlight = { Adornee = "Instance", FillColor = "Color3", OutlineColor = "Color3", FillTransparency = "number",
        OutlineTransparency = "number", DepthMode = "string", Enabled = "boolean" },
    BillboardGui = { Adornee = "Instance", Size = "UDim2", LightInfluence = "number", AlwaysOnTop = "boolean", StudsOffset = "Vector3", MaxDistance = "number" },
    ImageLabel = { BackgroundTransparency = "number", Size = "UDim2", Position = "UDim2", Image = "string", ImageColor3 = "Color3",
        ImageTransparency = "number", Rotation = "number" },
    ScreenGui = { ResetOnSpawn = "boolean", IgnoreGuiInset = "boolean", DisplayOrder = "number", Enabled = "boolean" },
    Frame = { Size = "UDim2", Position = "UDim2", BorderSizePixel = "number", BackgroundColor3 = "Color3",
        BackgroundTransparency = "number", Visible = "boolean", ZIndex = "number" },
    UIGradient = { Rotation = "number", Transparency = "NumberSequence", Color = "ColorSequence" },
    Folder = {},
    Model = { PrimaryPart = "Instance" },
    Motor6D = { Part0 = "Instance", Part1 = "Instance", C0 = "CFrame", C1 = "CFrame", Transform = "CFrame" },
    PlayerGui = {},
    Humanoid = {},
}
local IS = { Part = { BasePart = true, PVInstance = true }, Model = { PVInstance = true }, Motor6D = { JointInstance = true } }

local Inst = {}
world.instances = {}
world.liveSet = {}
world.named = {}
world.clientOwned = false
local function kindOf(v)
    local mt = getmetatable(v)
    if mt == V then return "Vector3" end
    if mt == C then return "CFrame" end
    if mt == Col then return "Color3" end
    if mt == Inst then return "Instance" end
    if type(v) == "table" and v.kind then return v.kind end
    return type(v)
end
world.kindOf = kindOf

local function new(className)
    assert(PROPS[className], "Instance.new: this check has no model of class " .. tostring(className))
    local o = setmetatable({ _p = { Name = className, ClassName = className }, _children = {}, _class = className, _attrs = {} }, Inst)
    table.insert(world.instances, o)
    world.liveSet[o] = true
    rawset(o, "_born", world.t)
    rawset(o, "_client", world.clientOwned)
    if className == "Part" then
        o._p.CFrame = CFrame.new()
        o._p.Size = Vector3.new(1, 1, 1)
        o._p.Transparency = 0
    elseif className == "Attachment" then
        o._p.CFrame = CFrame.new()
    elseif className == "ParticleEmitter" then
        o._p.Enabled = true
        o._p.Lifetime = NumberRange.new(5, 10)
        o._p.Rate = 20
    elseif className == "Motor6D" then
        o._p.C0 = CFrame.new()
        o._p.C1 = CFrame.new()
        o._p.Transform = CFrame.new()
    elseif className == "Frame" then
        o._p.Visible = true
        o._p.BackgroundTransparency = 0
    elseif className == "Trail" or className == "Beam" then
        o._p.Enabled = true
    end
    return o
end
Instance = { new = new }
world.new = new

Inst.__index = function(o, k)
    local p = rawget(o, "_p")
    if k == "Position" and o._class == "Part" then return p.CFrame.Position end
    if k == "Position" and o._class == "Attachment" then return p.CFrame.Position end
    if k == "ChildAdded" or k == "ChildRemoved" or k == "Destroying" then
        local s = rawget(o, "_sig_" .. k)
        if not s then s = signal(); rawset(o, "_sig_" .. k, s) end
        return s
    end
    local v = p[k]
    if v ~= nil then return v end
    return Inst[k]
end
Inst.__newindex = function(o, k, v)
    local p = rawget(o, "_p")
    local allowed = PROPS[o._class][k] or COMMON[k]
    if not allowed then error(o._class .. "." .. tostring(k) .. " is not a valid member", 2) end
    if allowed ~= "any" and v ~= nil and kindOf(v) ~= allowed then
        error(string.format("%s.%s = %s (wanted %s)", o._class, k, kindOf(v), allowed), 2)
    end
    if type(v) == "number" and v ~= v then error(o._class .. "." .. k .. " = NaN", 2) end
    if kindOf(v) == "Vector3" and (v.X ~= v.X or v.Y ~= v.Y or v.Z ~= v.Z) then error(o._class .. "." .. k .. " = NaN vector", 2) end
    if k == "Parent" then
        if rawget(o, "_destroyed") then error("The Parent property of " .. o._class .. " is locked", 2) end
        local old = p.Parent
        if old then
            old._children[o] = nil
            local s = rawget(old, "_sig_ChildRemoved"); if s then s:Fire(o) end
        end
        p.Parent = v
        if v then
            v._children[o] = true
            local s = rawget(v, "_sig_ChildAdded"); if s then s:Fire(o) end
        end
        return
    end
    if k == "Position" and o._class == "Part" then p.CFrame = CFrame.new(v) * p.CFrame.Rotation; return end
    if k == "Position" and o._class == "Attachment" then p.CFrame = CFrame.new(v) * p.CFrame.Rotation; return end
    if k == "Emit" then error("Emit is a method") end
    if k == "Name" and rawget(o, "_client") then world.named[v] = world.t end
    p[k] = v
end
function Inst:IsA(name) return self._class == name or name == "Instance" or (IS[self._class] and IS[self._class][name]) or false end
function Inst:GetChildren() local out = {} for c in pairs(self._children) do table.insert(out, c) end return out end
function Inst:GetDescendants()
    local out = {}
    local function walk(o) for c in pairs(o._children) do table.insert(out, c); walk(c) end end
    walk(self)
    return out
end
function Inst:FindFirstChild(name) for c in pairs(self._children) do if c._p.Name == name then return c end end return nil end
function Inst:WaitForChild(name) local c = self:FindFirstChild(name); assert(c, "WaitForChild would hang: " .. name); return c end
function Inst:FindFirstChildOfClass(name) for c in pairs(self._children) do if c._class == name then return c end end return nil end
function Inst:GetAttribute(k) return self._attrs[k] end
function Inst:SetAttribute(k, v) self._attrs[k] = v end
function Inst:Destroy()
    if rawget(self, "_destroyed") then return end
    for c in pairs(self._children) do c:Destroy() end
    local s = rawget(self, "_sig_Destroying"); if s then s:Fire() end
    local parent = self._p.Parent
    if parent then parent._children[self] = nil end
    self._p.Parent = nil
    rawset(self, "_destroyed", true)
    world.liveSet[self] = nil
    rawset(self, "_died", world.t)
end
world.emits = {}
function Inst:Emit(n)
    assert(self._class == "ParticleEmitter", "Emit on " .. self._class)
    assert(math.type(n) == "integer" or n == math.floor(n), "Emit of a fraction")
    table.insert(world.emits, { t = world.t, count = n, life = self._p.Lifetime.Max, emitter = self })
end

typeof = function(x)
    local k = kindOf(x)
    if k == "table" then return "table" end
    return k
end

-- The scene ---------------------------------------------------------------------------------------
local workspaceI = new("Folder")
workspaceI._p.Name = "Workspace"
workspace = workspaceI
world.camera = { CFrame = CFrame.new(0, 10, 30) }
-- workspace.CurrentCamera and :Raycast live outside the property check.
workspaceI._p.CurrentCamera = world.camera
-- A flat floor at Y = 0, and a figure standing on it at world.standing (a Model with a Humanoid, so
-- the client has to step past its legs to find the floor).
local floor = new("Part")
floor._p.Name = "Floor"
floor.Parent = workspaceI
local standing = new("Model")
standing._p.Name = "Standing"
local legs = new("Part")
legs._p.Name = "Legs"
legs.Parent = standing
local humanoid = new("Humanoid")
humanoid.Parent = standing
standing.Parent = workspaceI
world.standing = { position = vec(0, 3, -20), model = standing }
Inst.Raycast = function(self, origin, direction, params)
    local excluded = {}
    for _, o in ipairs(params and params.FilterDescendantsInstances or {}) do excluded[o] = true end
    if origin.Y >= 0 and origin.Y + direction.Y <= 0 then
        -- The standing figure's legs, 2 studs tall, under it.
        local s = world.standing.position
        if not excluded[standing] and math.abs(origin.X - s.X) < 1 and math.abs(origin.Z - s.Z) < 1 and origin.Y > 2 and origin.Y + direction.Y < 2 then
            return { Position = vec(origin.X, 2, origin.Z), Normal = vec(0, 1, 0), Instance = legs }
        end
        local a = origin.Y / -direction.Y
        return { Position = origin + direction * a, Normal = vec(0, 1, 0), Instance = floor }
    end
    return nil
end
function Inst:FindFirstAncestorOfClass(name)
    local p = self._p.Parent
    while p do
        if p._class == name then return p end
        p = p._p.Parent
    end
    return nil
end
RaycastParams = { new = function() return {} end }

local companions = new("Folder")
companions._p.Name = "Companions"
companions.Parent = workspaceI
world.companions = companions
local playerGui = new("PlayerGui")
world.playerGui = playerGui
world.player = { UserId = 1, Character = nil }
function world.player:FindFirstChildOfClass(name) if name == "PlayerGui" then return playerGui end return nil end

world.RunService = { RenderStepped = signal(), Stepped = signal(), Heartbeat = signal() }
world.remotes = {}
world.Remotes = { Event = function(name)
    local r = world.remotes[name]
    if not r then r = { OnClientEvent = signal() }; world.remotes[name] = r end
    return r
end }
world.sounds = {}
world.Sfx = { PlayAt = function(name, position, jitter, towards, gain) table.insert(world.sounds, { name = name, t = world.t }) end }
world.marks = {}

local modules = {}
world.modules = modules
local shared = new("Folder")
shared._p.Name = "Shared"
game = { GetService = function(_, name)
    if name == "ReplicatedStorage" then return { WaitForChild = function(_, n) assert(n == "Shared"); return shared end } end
    if name == "Players" then return { LocalPlayer = world.player } end
    return {}
end }
rawset(shared, "WaitForChild", function(_, name) return { Name = name } end)
require = function(m) local r = modules[m.Name]; assert(r ~= nil, "no module " .. tostring(m.Name)); return r end
task = { spawn = function(fn, ...) fn(...) end, delay = function() error("the client must schedule through its own frame, not task.delay") end }
warn = function(...) table.insert(world.errors, "warn: " .. table.concat({ ... }, " ")) end

-- A rigged companion: a root, and a pivot per joint with its Motor6D, the way BrainrotModels builds one.
function world.rig(name, position, body, scale, groups)
    -- The server builds these, not the client: they are not the client's to clean up.
    local owned = world.clientOwned
    world.clientOwned = false
    local model = new("Model")
    model._p.Name = name
    local root = new("Part")
    root._p.Name = "Root"
    root.CFrame = CFrame.new(position)
    root.Parent = model
    model.PrimaryPart = root
    for _, group in ipairs(groups or { "Body", "ArmL", "ArmR", "FootL", "FootR", "Tail" }) do
        local pivot = new("Part")
        pivot._p.Name = "Pivot" .. group
        local joint = new("Motor6D")
        joint._p.Name = group
        joint.Part0 = root
        joint.Part1 = pivot
        joint.C0 = group == "Body" and CFrame.new(0, -1 * (scale or 1), 0) or CFrame.new(0, 0.3, 0)
        joint.Parent = pivot
        pivot.Parent = model
    end
    model:SetAttribute("RigBody", body or "Blob")
    model:SetAttribute("RigScale", scale or 1)
    world.clientOwned = owned
    return model
end

-- One frame: the clock moves, then the frame's signals fire in Roblox's order.
function world.frame(dt)
    world.t = world.t + dt
    world.RunService.RenderStepped:Fire(dt)
    world.RunService.Stepped:Fire(world.t, dt)
    world.RunService.Heartbeat:Fire(dt)
end

-- The effects folder and the owner's screen-edge gui are meant to last; everything else is an effect.
function world.persistent(o)
    if o == world.fxFolder then return true end
    local p = o._p.Parent
    while p do
        if p == world.playerGui then return true end
        p = p._p.Parent
    end
    return o._class == "ScreenGui" or o._class == "Frame" or o._class == "UIGradient"
end

-- What is out right now.
function world.census()
    local c = { effects = 0, parts = 0, lights = 0, highlights = 0, emitters = 0, rated = 0, instances = 0, particles = 0, oldest = 0 }
    for o in pairs(world.liveSet) do
        if o._client and not world.persistent(o) then
            c.instances = c.instances + 1
            c.oldest = math.max(c.oldest, world.t - o._born)
            if o._class == "PointLight" then c.lights = c.lights + 1 end
            if o._class == "Highlight" then c.highlights = c.highlights + 1 end
            if o._class == "ParticleEmitter" then
                c.emitters = c.emitters + 1
                if o._p.Enabled then c.rated = c.rated + 1 end
            end
        end
    end
    c.turned = 0
    for child in pairs(world.fxFolder._children) do
        if child._class == "Part" and child._p.Name ~= "Fx" then
            c.effects = c.effects + 1
            -- Hosts are never turned: every attachment on one is placed by world offset.
            local r = child._p.CFrame.r
            if math.abs(r[1] - 1) > 1e-9 or math.abs(r[5] - 1) > 1e-9 or math.abs(r[9] - 1) > 1e-9 then c.turned = c.turned + 1 end
        end
    end
    local keep = {}
    for _, e in ipairs(world.emits) do
        if e.t + e.life > world.t then
            c.particles = c.particles + e.count
            table.insert(keep, e)
        end
    end
    world.emits = keep
    return c
end
return world
"""

BOOT = r"""
local animSrc, rioritySrc, raritySrc, soundSrc, clientSrc = ...
local world = _G.world
local anim = load(animSrc, "CompanionAnimations")()
world.modules.CompanionAnimations = anim
world.modules.Rarity = load(raritySrc, "Rarity")()
local seam = {
    RunService = world.RunService, Remotes = world.Remotes, Sfx = world.Sfx, LocalPlayer = world.player,
    companions = world.companions, parent = workspace,
    clock = function() return world.t end,
    mark = function(what, key, t, extra) table.insert(world.marks, { what = what, key = key, t = t, extra = extra }) end,
}
__companionFxHarness = seam
world.clientOwned = true
local chunk, err = load(clientSrc, "CompanionFxClient")
assert(chunk, err)
chunk()
world.api = seam.api
world.fxFolder = seam.api.folder
return world
"""


def new_world(root, sources):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(WORLD)
    boot = lua.eval("function(src, ...) return load(src, 'boot')(...) end")
    world = boot(BOOT, sources[ANIM], None, sources[RARITY], sources[SOUNDS], sources[CLIENT])
    return lua, world


# --------------------------------------------------------------------------------------------------
# Client scenarios, in Lua against the world
# --------------------------------------------------------------------------------------------------

SCENARIOS = r"""
local world = _G.world
local api = world.api
local anim = world.modules.CompanionAnimations
local out = { fails = {}, facts = {} }
local function fail(msg) table.insert(out.fails, msg) end
local function fact(msg) table.insert(out.facts, msg) end
local FRAME = 1 / 60
local P = ...  -- the stated caps and numbers, from Python

local function run(seconds, watch)
    local frames = math.ceil(seconds / FRAME)
    for _ = 1, frames do
        world.frame(FRAME)
        if watch then watch() end
    end
end

-- Everything played out and gone.
local function settle()
    run(P.life + 1.2)
end

local function clean(label)
    settle()
    local c = world.census()
    local left = {}
    for child in pairs(world.fxFolder._children) do table.insert(left, child._p.Name) end
    if #left > 0 then fail(label .. ": " .. #left .. " instance(s) left in the effects folder: " .. table.concat(left, ", ", 1, math.min(#left, 6))) end
    if #api.live > 0 then fail(label .. ": the client still lists " .. #api.live .. " live effect(s)") end
    if #api.pending > 0 then fail(label .. ": " .. #api.pending .. " scheduled beat(s) never ran") end
    if api.budget.effects ~= 0 or api.budget.lights ~= 0 or api.budget.highlights ~= 0 then
        fail(string.format("%s: budgets not back to 0 (effects %d, lights %d, highlights %d)", label, api.budget.effects, api.budget.lights, api.budget.highlights))
    end
    if c.lights > 0 or c.highlights > 0 or c.emitters > 0 then fail(label .. ": lights/glows/emitters still alive after the effects ended") end
end

-- Companions on stage.
local companions = {}
local function companion(name, position, body)
    local model = world.rig(name, position, body or "Blob", 1)
    model.Parent = world.companions
    companions[name] = model
    return model
end
local near = companion("Near", Vector3.new(0, 3, 0))

local function payload(kind, style, o)
    o = o or {}
    local travel = (kind == "Lob" and 0.7) or (kind == "Bonk" and 0.35) or (kind == "Spit" and 20 / 90) or (20 / 90)
    local p = {
        kind = kind == "Blast" and "Shockwave" or kind, style = style, companion = o.companion or near,
        from = o.from or Vector3.new(0, 3, 0), to = o.to or Vector3.new(0, 3, -20),
        color = Color3.fromRGB(240, 120, 60), rarity = o.rarity or "Epic", range = 20, splash = (kind == "Lob" and 11) or 7,
        windup = P.windup, travel = travel, owner = o.owner,
    }
    p.lands = ((kind == "Spit" or kind == "Bonk" or kind == "Lob") and P.windup + travel) or P.windup
    if kind == "Blast" then p.blast = true; p.windup = 0; p.lands = 0 end
    if (kind == "Zap" or kind == "Chain") then
        local forks = (kind == "Chain" and 1 or 0) + (style == "Fork" and 1 or 0)
        if forks >= 1 then p.to2 = Vector3.new(8, 3, -26) end
        if forks >= 2 then p.to3 = Vector3.new(16, 3, -30) end
    end
    return p
end

local function named(name)
    return (world.named[name] or -1) >= world.stageStart
end
-- How many of a class the client has built since instance number `from`.
local function classBuilt(className, from)
    local n = 0
    for index = from + 1, #world.instances do
        local o = world.instances[index]
        if o._client and o._class == className then n = n + 1 end
    end
    return n
end

-- Which shapes each move must draw, and which each style must.
local MOVE_SHAPES = {
    Spit = { "Charge", "Muzzle", "Glob", "Splat" }, Zap = { "Charge", "Muzzle", "Bolt" }, Chain = { "Charge", "Muzzle", "Bolt" },
    Lob = { "Charge", "Muzzle", "Glob", "Telegraph", "Splash", "Dome" }, Bonk = { "Charge", "Muzzle", "LaunchDust", "Streak", "Slam" },
    Shockwave = { "Charge", "Quake" }, Blast = { "Muzzle", "Recoil" },
}
local STYLE_SHAPE = { Slow = "Style_Slow", Daze = "Style_Daze", Burn = "Style_Burn", Toxic = "Style_Toxic", Leech = "Style_Leech",
    Quick = "Style_Quick", Long = "Style_Long", Fork = "ForkArc", Wide = "WideWave" }
local STYLE_TIME = { Slow = 1.6, Daze = 0.6, Burn = 2, Toxic = 4 }

-- 1. Every move x every style it can carry: timing, shapes, signature, cleanup.
local pairsRun, timed = 0, 0
local worstStrike, worstLand = 0, 0
for _, combo in ipairs(P.combos) do
    local kind, style = combo[1], combo[2]
    local label = kind .. "/" .. (style or "plain")
    world.marks = {}
    world.sounds = {}
    world.stageStart = world.t
    local p = payload(kind, style)
    local t0 = world.t
    world.remotes.CompanionAttack.OnClientEvent:Fire(p)
    -- The hit comes back a moment after the damage lands, as it would over the network.
    local hitAt = p.lands + 0.05
    local hitSent = false
    run(math.max(p.lands, 0) + 0.8, function()
        if not hitSent and world.t - t0 >= hitAt and kind ~= "Blast" then
            hitSent = true
            world.remotes.CompanionHit.OnClientEvent:Fire({
                companion = near, positions = { p.to, Vector3.new(3, 3, -21) }, victims = { false, false }, killed = false,
                color = p.color, style = style, styleTime = STYLE_TIME[style], rarity = "Epic", owner = nil,
            })
        end
    end)
    pairsRun = pairsRun + 1
    -- Timing.
    local strikeAt, landAt
    for _, m in ipairs(world.marks) do
        if m.what == "strike" and not strikeAt then strikeAt = m.t - t0 end
        if m.what == "lands" and not landAt then landAt = m.t - t0 end
    end
    if not strikeAt then fail(label .. ": never struck") else
        local late = strikeAt - p.windup
        worstStrike = math.max(worstStrike, math.abs(late))
        if late < -1e-9 or late > FRAME + 1e-6 then fail(string.format("%s: struck %.3fs in, the server's windup is %.3fs", label, strikeAt, p.windup)) end
    end
    if kind ~= "Blast" then
        if not landAt then fail(label .. ": never landed") else
            local late = landAt - p.lands
            worstLand = math.max(worstLand, math.abs(late))
            if late < -1e-9 or late > FRAME + 1e-6 then fail(string.format("%s: landed %.3fs in, the server lands the damage at %.3fs", label, landAt, p.lands)) else timed = timed + 1 end
        end
    else
        timed = timed + 1
    end
    for _, shapeName in ipairs(MOVE_SHAPES[kind]) do
        if not named(shapeName) then fail(label .. ": the move drew no " .. shapeName) end
    end
    if style then
        local want = STYLE_SHAPE[style]
        local applies = not (style == "Wide" and not (kind == "Bonk" or kind == "Lob" or kind == "Shockwave"))
        if applies and not named(want) then fail(label .. ": no " .. want .. " signature") end
    end
    -- Sounds: the move's strike cue at the strike.
    local cue = api.moves[kind].cue
    local heard = false
    for _, s in ipairs(world.sounds) do
        if s.name == cue and strikeAt and math.abs((s.t - t0) - strikeAt) < 1e-6 then heard = true end
    end
    if not heard then fail(label .. ": " .. cue .. " did not play on the strike") end
    clean(label)
end
fact(string.format("move x style pairs run %d; strike and landing on the server's beat for %d (worst off by %.4fs / %.4fs, one frame is %.4fs)",
    pairsRun, timed, worstStrike, worstLand, FRAME))

-- 2. Distance: nothing past the cull, only core shapes past the detail distance.
world.stageStart = world.t
world.camera.CFrame = CFrame.new(0, 10, P.cull + 60)
local before = #world.instances
world.remotes.CompanionAttack.OnClientEvent:Fire(payload("Lob", "Burn"))
run(1.5)
local made = 0
for index = before + 1, #world.instances do if world.instances[index]._client then made = made + 1 end end
if made > 0 then fail(string.format("cull: a Lob %d studs away built %d instance(s); nothing should be drawn past %d", P.cull + 60, made, P.cull)) end
clean("cull")
local since = #world.instances
world.camera.CFrame = CFrame.new(0, 10, P.detail + 60)
world.remotes.CompanionAttack.OnClientEvent:Fire(payload("Lob", "Burn"))
run(1.2)
local lite = classBuilt("ParticleEmitter", since) + classBuilt("PointLight", since) + classBuilt("Highlight", since)
if lite > 0 then fail(string.format("detail: a Lob %d studs away built %d emitter/light/glow(s); none past %d", P.detail + 60, lite, P.detail)) end
if classBuilt("Part", since) == 0 then fail("detail: a Lob just past the detail distance drew nothing at all (the core shapes should stay)") end
clean("detail")
-- Your own companion keeps its detail at any drawn distance.
since = #world.instances
world.remotes.CompanionAttack.OnClientEvent:Fire(payload("Lob", "Burn", { owner = 1 }))
run(1.2)
if classBuilt("ParticleEmitter", since) == 0 then fail("detail: your own companion's Lob lost its particles past the detail distance") end
clean("detail own")
world.camera.CFrame = CFrame.new(0, 10, 30)

-- 3. Owner feedback: yours pulses (never past the cap), others' never do.
local darkest = 0
local function watchVignette()
    local v = api.vignette()
    if v then
        for _, frame in ipairs(v.edges) do
            if frame._p.Visible then darkest = math.max(darkest, 1 - frame._p.BackgroundTransparency) end
        end
    end
end
for _, kind in ipairs({ "Spit", "Shockwave", "Zap" }) do
    local p = payload(kind, "Leech")
    world.remotes.CompanionAttack.OnClientEvent:Fire(p)
    run(0.5, watchVignette)
    world.remotes.CompanionHit.OnClientEvent:Fire({ companion = near, positions = { p.to }, victims = { false }, killed = true,
        color = p.color, style = "Leech", rarity = "Secret" })
    run(1, watchVignette)
end
if darkest > 0 then fail(string.format("owner: someone else's companion pulsed your screen edge (to %.2f)", darkest)) end
darkest = 0
for _, kind in ipairs({ "Spit", "Shockwave", "Zap" }) do
    local p = payload(kind, "Leech", { owner = 1 })
    world.remotes.CompanionAttack.OnClientEvent:Fire(p)
    run(0.5, watchVignette)
    world.remotes.CompanionHit.OnClientEvent:Fire({ companion = near, positions = { p.to }, victims = { false }, killed = true,
        color = p.color, style = "Leech", rarity = "Secret", owner = 1 })
    run(1, watchVignette)
end
if darkest <= 0 then fail("owner: your own companion's strikes and hits never pulsed the screen edge") end
if darkest > P.vignette + 1e-6 then fail(string.format("owner: the screen-edge pulse reached %.3f, over the %.2f cap", darkest, P.vignette)) end
fact(string.format("owner pulse: darkest %.3f (cap %.2f); others' companions: 0", darkest, P.vignette))
clean("owner")

-- 4. Stress: 40 companions using their moves together, again and again, all with hits and styles.
local worst = { effects = 0, particles = 0, lights = 0, highlights = 0, rated = 0, oldest = 0, instances = 0, perCompanion = 0, turned = 0 }
local function watchCaps()
    local c = world.census()
    for k in pairs(worst) do if c[k] and c[k] > worst[k] then worst[k] = c[k] end end
    local per = {}
    for _, fx in ipairs(api.live) do if not fx.done then per[fx.key] = (per[fx.key] or 0) + 1 end end
    for _, n in pairs(per) do if n > worst.perCompanion then worst.perCompanion = n end end
end
local crowd = {}
for index = 1, 40 do
    local angle = index / 40 * math.pi * 2
    table.insert(crowd, companion("Crowd" .. index, Vector3.new(math.cos(angle) * 30, 3, math.sin(angle) * 30)))
end
local kinds = { "Spit", "Zap", "Chain", "Lob", "Bonk", "Shockwave", "Blast" }
local styles = { "Slow", "Daze", "Burn", "Toxic", "Leech", "Wide", "Quick", "Long", "Fork" }
for round = 1, 6 do
    for index, model in ipairs(crowd) do
        local kind = kinds[(index + round) % #kinds + 1]
        local style = styles[(index * 3 + round) % #styles + 1]
        local from = model.PrimaryPart.Position
        local p = payload(kind, style, { companion = model, from = from, to = from + Vector3.new(0, 0, -18), owner = index == 1 and 1 or nil, rarity = "Secret" })
        world.remotes.CompanionAttack.OnClientEvent:Fire(p)
    end
    run(0.5, watchCaps)
    for index, model in ipairs(crowd) do
        local from = model.PrimaryPart.Position
        world.remotes.CompanionHit.OnClientEvent:Fire({ companion = model, positions = { from + Vector3.new(0, 0, -18), from + Vector3.new(2, 0, -18),
            from + Vector3.new(-2, 0, -18), from + Vector3.new(0, 0, -20) }, victims = { false, false, false, false }, killed = index % 5 == 0,
            color = Color3.new(1, 0.5, 0.2), style = styles[(index + round) % #styles + 1], styleTime = 4, rarity = "Mythic" })
    end
    run(0.9, watchCaps)
end
-- A flood from one companion (a move every 0.1 s, hits and all): its own cap must hold.
for _ = 1, 30 do
    local p = payload("Lob", "Wide", { companion = crowd[1], rarity = "Secret", owner = 1 })
    world.remotes.CompanionAttack.OnClientEvent:Fire(p)
    world.remotes.CompanionHit.OnClientEvent:Fire({ companion = crowd[1], positions = { p.to, p.to + Vector3.new(2, 0, 0) }, victims = { false, false },
        color = p.color, style = "Toxic", styleTime = 4, rarity = "Secret", owner = 1 })
    run(0.1, watchCaps)
end
run(1, watchCaps)
fact(string.format("stress (40 companions x 6 rounds, then a 30-move flood from one): worst live effects %d (cap %d), per companion %d (cap %d), particles %d (cap %d), lights %d (cap %d), rim glows %d (cap %d), instances %d, emitters left on a rate %d, oldest instance %.2fs (cap %.1f)",
    worst.effects, P.effects, worst.perCompanion, P.perCompanion, worst.particles, P.particles, worst.lights, P.lights, worst.highlights, P.highlights,
    worst.instances, worst.rated, worst.oldest, P.life))
if worst.effects > P.effects then fail(string.format("caps: %d live effects, over %d", worst.effects, P.effects)) end
if worst.perCompanion > P.perCompanion then fail(string.format("caps: one companion had %d live effects, over %d", worst.perCompanion, P.perCompanion)) end
if worst.particles > P.particles then fail(string.format("caps: %d live particles, over %d", worst.particles, P.particles)) end
if worst.lights > P.lights then fail(string.format("caps: %d lights, over %d", worst.lights, P.lights)) end
if worst.highlights > P.highlights then fail(string.format("caps: %d rim glows, over %d", worst.highlights, P.highlights)) end
if worst.rated > 0 then fail(string.format("caps: %d particle emitter(s) left running on a rate", worst.rated)) end
if worst.turned > 0 then fail(string.format("hosts: %d effect host(s) turned (their attachments are placed by world offset, so they would land in the wrong place)", worst.turned)) end
if worst.oldest > P.life + FRAME + 1e-6 then fail(string.format("caps: an instance lived %.2fs, over %.1fs", worst.oldest, P.life)) end
if worst.particles < P.particles * 0.5 then fail(string.format("stress: only %d particles at the worst -- the stress run never pressed the %d budget, so it proves nothing", worst.particles, P.particles)) end
if worst.effects < P.effects then fail(string.format("stress: only %d live effects at the worst -- never reached the %d cap", worst.effects, P.effects)) end
if worst.perCompanion < P.perCompanion then fail(string.format("stress: one companion peaked at %d effects -- never reached its %d cap", worst.perCompanion, P.perCompanion)) end
clean("stress")

-- 5. A status that claims to last far longer than any effect may.
world.remotes.CompanionHit.OnClientEvent:Fire({ companion = near, positions = { Vector3.new(0, 3, -10) }, victims = { false }, color = Color3.new(0, 1, 0),
    style = "Toxic", styleTime = 30, rarity = "Rare" })
local longest = 0
run(P.life + 1, function() local c = world.census(); if c.oldest > longest then longest = c.oldest end end)
if longest > P.life + FRAME + 1e-6 then fail(string.format("life: a 30 s poison's cue lived %.2fs, over %.1fs", longest, P.life)) end
clean("life")

-- 6. A Lob at someone standing: its rings go on the floor under them, not on their legs.
world.stageStart = world.t
local atFigure = payload("Lob", nil, { to = world.standing.position })
world.remotes.CompanionAttack.OnClientEvent:Fire(atFigure)
run(atFigure.windup + 0.05)
local telegraph = nil
for child in pairs(world.fxFolder._children) do if child._p.Name == "Telegraph" then telegraph = child end end
if not telegraph then fail("ground: no telegraph drawn for a Lob at a standing figure")
elseif math.abs(telegraph.Position.Y - 0.1) > 0.05 then
    fail(string.format("ground: a Lob's ring under a standing figure sits at height %.2f, not on the floor (0.1)", telegraph.Position.Y))
end
clean("ground")

-- 7. Nothing threw, anywhere (each distinct error once, with how often).
local seen, order = {}, {}
for _, e in ipairs(world.errors) do
    if not seen[e] then seen[e] = 0; table.insert(order, e) end
    seen[e] = seen[e] + 1
end
for _, e in ipairs(order) do fail(string.format("error (x%d): %s", seen[e], e)) end
local examined = 0
for _, o in ipairs(world.instances) do if o._client then examined = examined + 1 end end
fact(string.format("instances built by the client and examined: %d (every property set on each checked against its class)", examined))
out.cues = api.cues
return out
"""

# --------------------------------------------------------------------------------------------------
# Every brainrot, every clip, every body
# --------------------------------------------------------------------------------------------------

ANIMATION = r"""
local world = _G.world
local anim = world.modules.CompanionAnimations
local api = world.api
local data, P = ...
local out = { fails = {}, facts = {} }
local function fail(msg) table.insert(out.fails, msg) end
local FRAME = 1 / 60

-- Transforms of a pose, as positions and rotation matrices.
local function snapshot(pose)
    return anim.Transforms(pose)
end
local function differ(a, b)
    local dp, dr = 0, 0
    for name, cfa in pairs(a) do
        local cfb = b[name]
        local d = (cfa.Position - cfb.Position).Magnitude
        if d > dp then dp = d end
        for i = 1, 9 do
            local x = math.abs(cfa.r[i] - cfb.r[i])
            if x > dr then dr = x end
        end
    end
    return dp, dr
end

local bodies = {}
for body in pairs(anim.Styles) do table.insert(bodies, body) end
table.sort(bodies)

local maxTravel = { Spit = 1.7, Bonk = 0.35, Lob = 0.7 }
local clipsChecked, samples = 0, 0
local shortest = {}
local resolved = 0
for _, def in ipairs(data.Types) do
    local stats = data.Stats(def, 1, 0)
    local kind = def.blast and "Blast" or stats.kind
    local style = stats.style
    local body = def.look and def.look.body
    local ok = true
    if not api.moves[kind] then fail(def.name .. ": move " .. tostring(kind) .. " has no drawing"); ok = false end
    if style and not (api.styles[style] and api.signatures[style]) then fail(def.name .. ": style " .. style .. " has no signature"); ok = false end
    if not anim.Styles[body or "?"] then fail(def.name .. ": body " .. tostring(body) .. " is not one the animations know (it would move as a Blob)"); ok = false end
    if ok then resolved = resolved + 1 end
    shortest[kind] = shortest[kind] or {}
    local key = style or "plain"
    if not shortest[kind][key] or stats.cooldown < shortest[kind][key].cooldown then
        shortest[kind][key] = { cooldown = stats.cooldown, name = def.name, body = body }
    end
end
out.facts[#out.facts + 1] = string.format("brainrots %d, resolved to a drawn move, a signature and a known body: %d", #data.Types, resolved)

for kind, byStyle in pairs(shortest) do
    for styleKey, row in pairs(byStyle) do
        local style = styleKey ~= "plain" and styleKey or nil
        local travel = maxTravel[kind] or 0.2
        local duration = anim.Duration(kind, travel, style)
        -- Over before the move can be used again.
        if duration >= row.cooldown then
            fail(string.format("%s/%s: the clip runs %.2fs but %s's cooldown is %.2fs", kind, styleKey, duration, row.name, row.cooldown))
        end
        local strike = anim.Phases(kind, travel, style).strike
        if kind ~= "Blast" and math.abs(strike - P.windup) > 1e-9 then fail(string.format("%s: strike at %.3f, the server's windup is %.3f", kind, strike, P.windup)) end
        -- Glows hardest on the strike (Blast has no windup to build over).
        if kind ~= "Blast" then
            local peak = anim.Glow(kind, strike, travel, style)
            if peak < 0.999 then fail(string.format("%s/%s: glow %.2f on the strike, not its peak", kind, styleKey, peak)) end
            for step = 1, 8 do
                local t = strike * step / 9
                if anim.Glow(kind, t, travel, style) > peak + 1e-9 then fail(string.format("%s/%s: glows harder in the windup (%.2fs) than on the strike", kind, styleKey, t)) break end
            end
            -- A Bonk's creature IS the shot, and glows on through its flight.
            local settleFrom = kind == "Bonk" and strike + travel or strike
            local after = anim.Glow(kind, settleFrom + 0.25, travel, style)
            if after > 0.6 then fail(string.format("%s/%s: still glowing %.2f a quarter second after the strike", kind, styleKey, after)) end
        end
        for _, body in ipairs(bodies) do
            clipsChecked = clipsChecked + 1
            local target = Vector3.new(4, -1, -14)
            local clip = { kind = kind, start = 0, target = target, travel = travel, style = style }
            local rest = snapshot(anim.Blank())
            -- Starts on the idle pose.
            local pose = anim.Blank()
            anim.Layer(pose, body, clip, 0, 1)
            local dp, dr = differ(snapshot(pose), rest)
            if dp > 1e-6 or dr > 1e-6 then fail(string.format("%s/%s on %s: pops at the start (%.3f studs, %.3f rotation)", kind, styleKey, body, dp, dr)) end
            -- Ends on it.
            pose = anim.Blank()
            if not anim.Layer(pose, body, clip, duration, 1) then fail(string.format("%s/%s on %s: finished before its Duration", kind, styleKey, body)) end
            dp, dr = differ(snapshot(pose), rest)
            if dp > 1e-4 or dr > 1e-4 then fail(string.format("%s/%s on %s: pops at the end (%.3f studs, %.3f rotation off the idle)", kind, styleKey, body, dp, dr)) end
            pose = anim.Blank()
            if anim.Layer(pose, body, clip, duration + 0.02, 1) then fail(string.format("%s/%s on %s: still playing after its Duration", kind, styleKey, body)) end
            -- No frame-to-frame jump bigger than the move itself moves.
            local previous = rest
            local flight = kind == "Bonk" and (target.Magnitude / travel + 20) * FRAME or 0
            local steps = math.ceil(duration / FRAME)
            for step = 0, steps do
                local t = math.min(step * FRAME, duration)
                pose = anim.Blank()
                anim.Layer(pose, body, clip, t, 1)
                local snap = snapshot(pose)
                for _, cf in pairs(snap) do
                    local p = cf.Position
                    if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then fail(kind .. " on " .. body .. ": NaN in a joint") end
                end
                local jump, turn = differ(snap, previous)
                samples = samples + 1
                if jump > math.max(1.5, flight + 0.5) then fail(string.format("%s/%s on %s: moves %.2f studs in one frame at %.2fs", kind, styleKey, body, jump, t)) break end
                if turn > 0.7 then fail(string.format("%s/%s on %s: turns %.2f in one frame at %.2fs", kind, styleKey, body, turn, t)) break end
                -- A pop, however fast the move: the pose a tenth of a millisecond on must be nearly the same.
                local nudged = anim.Blank()
                anim.Layer(nudged, body, clip, math.min(t + 1e-4, duration), 1)
                local pop, spin = differ(anim.Transforms(nudged), snap)
                if pop > 0.02 or spin > 0.02 then fail(string.format("%s/%s on %s: pops (%.3f studs, %.3f rotation) at %.3fs", kind, styleKey, body, pop, spin, t)) break end
                previous = snap
            end
        end
    end
end
out.facts[#out.facts + 1] = string.format("clips checked (move x style in use x %d bodies): %d, %d frames sampled", #bodies, clipsChecked, samples)
return out
"""

# --------------------------------------------------------------------------------------------------
# The server half: when does the damage really land?
# --------------------------------------------------------------------------------------------------


def load_ability_check(root):
    path = os.path.join(root, "tools", "companion_ability_check.py")
    spec = importlib.util.spec_from_file_location("companion_ability_check", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def timed_harness(ability):
    """companion_ability_check's service harness, with a clock that keeps time: task.delay queues at
    now + t and flush runs jobs in time order, moving the clock to each. Damage and broadcasts are
    stamped with the time they happen."""
    h = ability.SERVICE_HARNESS
    swaps = [
        ("delay = function(t, fn, ...) table.insert(queue, { fn = fn, args = { ... } }) end,",
         "delay = function(t, fn, ...) table.insert(queue, { at = now + t, fn = fn, args = { ... } }); table.insert(log.delays, now + t) end,"),
        ("""    while #queue > 0 do
        local job = table.remove(queue, 1)""",
         """    while #queue > 0 do
        local best = 1
        for i = 2, #queue do if queue[i].at < queue[best].at then best = i end end
        local job = table.remove(queue, best)
        if job.at > now then now = job.at end"""),
        ("table.insert(log.deals, { who = token.Name, amount = amount })", "table.insert(log.deals, { who = token.Name, amount = amount, t = now })"),
        ("if name == \"CompanionAttack\" then table.insert(log.attacks, payload)", "if name == \"CompanionAttack\" then payload.__sent = now; table.insert(log.attacks, payload)"),
        ("elseif name == \"CompanionHit\" then table.insert(log.hits, payload) end", "elseif name == \"CompanionHit\" then payload.__sent = now; table.insert(log.hits, payload) end"),
        ("mods.CompanionAnimations = { Windup = 0.3 }", "mods.CompanionAnimations = { Windup = %WINDUP% }\nmods.ProjectileService = { Explode = function(o) table.insert(log.blasts, { t = now, position = o.position }) end }\nmods.PracticeDummy = { BodyOf = function() return nil end, Hit = function() return 0, false, false end }"),
        ("local log = { attacks = {}, downs = {}, hits = {}, slows = {}, venoms = {}, warns = {}, deals = {} }",
         "local log = { attacks = {}, downs = {}, hits = {}, slows = {}, venoms = {}, warns = {}, deals = {}, delays = {}, blasts = {} }"),
    ]
    for old, new in swaps:
        if old not in h:
            raise SystemExit("companion_fx_check: companion_ability_check's harness changed; cannot find: " + old[:60])
        h = h.replace(old, new)
    return h.replace("%WINDUP%", repr(WINDUP))


SERVER = r"""
local CS = _G.CS
local log = _G.log
local BrainrotData = _G.BrainrotData
local out = { fails = {}, facts = {} }
local function fail(msg) table.insert(out.fails, msg) end
local W = ...

local owner = _G.makeCombatant("Owner", true, 0, "A")
local enemy = _G.makeCombatant("Enemy", true, 20, "B")
local second = _G.makeCombatant("Second", true, 30, "B")
local function reset() for k in pairs(log) do log[k] = {} end end
local function equip(name)
    owner.data = { Companion = name, Brainrots = { name }, CompanionXp = {}, Stars = {} }
    CS.Refresh(owner)
    CS.ResetStats()
end

-- One brainrot per move (plain where there is one), found by move.
local byKind = {}
for _, def in ipairs(BrainrotData.Types) do
    local kind = def.attack or "Spit"
    if not def.blast and (not byKind[kind] or (BrainrotData.StyleOf(def) == nil)) then byKind[kind] = def.name end
    if def.blast and not byKind.Blast then byKind.Blast = def.name end
end

local examined = 0
for _, kind in ipairs({ "Spit", "Bonk", "Zap", "Chain", "Lob", "Shockwave" }) do
    local name = byKind[kind]
    -- A target in reach; then a point with nobody on it; then the lobby demo.
    for _, path in ipairs({ "target", "point", "practice" }) do
        CS.ReviveAll(); equip(name); _G.advance(10)
        enemy.humanoid.Health = 100
        second.humanoid.Health = 100
        enemy.root.Position = path == "target" and Vector3.new(20, 0, 0) or Vector3.new(0, 0, 900)
        second.root.Position = path == "target" and Vector3.new(30, 0, 0) or Vector3.new(0, 0, -900)
        CS.IsFighting = function() return path ~= "practice" end
        reset()
        local aim = path == "point" and Vector3.new(12, 0, 0) or enemy.root.Position
        CS.UseAbility(owner, aim)
        _G.flush()
        local p = log.attacks[1]
        examined = examined + 1
        local label = kind .. " (" .. path .. ")"
        if not p then fail(label .. ": no broadcast") else
            if p.windup ~= W then fail(string.format("%s: windup %s, the move's windup is %s", label, tostring(p.windup), tostring(W))) end
            if type(p.lands) ~= "number" then fail(label .. ": the broadcast carries no `lands`") else
                local due = p.__sent + p.lands
                -- The damage (or the demo's job) is due exactly then.
                local found = false
                for _, at in ipairs(log.delays) do if math.abs(at - due) < 1e-9 then found = true end end
                if not found then fail(string.format("%s: lands %.3f, but nothing the server scheduled is due then", label, p.lands)) end
                -- A point with nobody on it hurts nobody: its scheduled landing above is the proof.
                if path == "target" then
                    local first = log.deals[1]
                    if not first then fail(label .. ": dealt no damage") elseif math.abs((first.t - p.__sent) - p.lands) > 1e-9 then
                        fail(string.format("%s: the damage landed %.3fs after the broadcast, the broadcast said %.3fs", label, first.t - p.__sent, p.lands))
                    end
                    local hit = log.hits[1]
                    if hit then
                        local victims = hit.victims or {}
                        for i = 1, #hit.positions do
                            if victims[i] == nil then fail(label .. ": the hit broadcast has a position with no victim beside it") end
                        end
                    end
                end
            end
            if p.rarity == nil then fail(label .. ": the broadcast carries no rarity") end
        end
    end
end
CS.IsFighting = function() return true end

-- A blast brainrot: its use is broadcast as a Blast, with no windup, as the explosion goes off.
local blast = byKind.Blast
if not blast then fail("no blast brainrot found to check") else
    CS.ReviveAll(); equip(blast); _G.advance(10)
    enemy.root.Position = Vector3.new(20, 0, 0)
    enemy.humanoid.Health = 100
    reset()
    CS.UseAbility(owner, enemy.root.Position)
    _G.flush()
    local p = log.attacks[1]
    examined = examined + 1
    if #log.blasts ~= 1 then fail("blast: the explosion did not go off once") end
    if not p then fail("blast: a blast brainrot's use is not broadcast (no recoil, and its owner's HUD never starts the cooldown)")
    else
        if p.blast ~= true or p.windup ~= 0 or p.lands ~= 0 then fail("blast: the broadcast is not a zero-windup Blast") end
        if log.blasts[1] and math.abs(log.blasts[1].t - p.__sent) > 1e-9 then fail("blast: broadcast and explosion at different times") end
    end
end

-- A styled hit carries how long its status really lasts.
for _, name in ipairs({ "Bubblo Gummo", "Cactino Pokko" }) do
    CS.ReviveAll(); equip(name); _G.advance(10)
    enemy.root.Position = Vector3.new(20, 0, 0)
    enemy.humanoid.Health = 100
    reset()
    CS.UseAbility(owner, enemy.root.Position)
    _G.flush()
    local stats = BrainrotData.Stats(BrainrotData.Get(name), 1, 0)
    local hit = log.hits[1]
    if not hit then fail(name .. ": no hit broadcast") else
        local want = stats.slowTime or stats.dotTime
        if hit.styleTime ~= want then fail(string.format("%s: the hit says the %s lasts %s, it lasts %s", name, tostring(stats.style), tostring(hit.styleTime), tostring(want))) end
        if hit.owner ~= owner.UserId then fail(name .. ": the hit does not name its owner (their screen pulse)") end
    end
end
out.facts[#out.facts + 1] = string.format("server broadcasts examined: %d (6 moves x target/point/lobby, and a blast)", examined)
return out
"""


def run_server(root, sources, ability):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(ability.PRELUDE)
    lua.execute("function _run(h, a, b) return load(h, 'harness')(a, b) end")
    lua.globals()._run(timed_harness(ability), sources[DATA], sources[SERVICE])
    return lua.execute(SERVER, WINDUP)


def lua_list(lua, items):
    table = lua.table()
    for index, item in enumerate(items, 1):
        table[index] = item
    return table


def check(root, sources, parts=("server", "client", "animation")):
    fails, facts = [], []
    ability = load_ability_check(root)

    # The server half.
    try:
        if "server" not in parts:
            raise StopIteration
        server = run_server(root, sources, ability)
        fails += [f"server: {m}" for m in server.fails.values()]
        facts += list(server.facts.values())
    except StopIteration:
        pass
    except Exception as exc:  # a crash is a failure, not a pass
        fails.append(f"server: harness crashed: {exc}")
    if parts == ("server",):
        return fails, facts

    # The client half.
    try:
        lua, world = new_world(root, sources)
    except Exception as exc:
        fails.append(f"client: did not load: {exc}")
        return fails, facts
    data = lua.eval("function(src) return load(src, 'BrainrotData')() end")(sources[DATA])
    sound = lua.eval("function(src) return load(src, 'SoundConfig')() end")(sources[SOUNDS])

    styles = list(data.AbilityStyles.keys())
    combos = []
    for kind in ["Spit", "Zap", "Chain", "Lob", "Bonk", "Shockwave"]:
        combos.append(lua_list(lua, [kind]))
        for style in styles:
            kinds = data.AbilityStyles[style].kinds
            if kinds is None or kinds[kind]:
                combos.append(lua_list(lua, [kind, style]))
    combos.append(lua_list(lua, ["Blast"]))
    params = lua.table_from({
        "windup": WINDUP, "cull": CULL, "detail": DETAIL, "life": CAP_LIFE, "vignette": CAP_VIGNETTE, "effects": CAP_EFFECTS,
        "perCompanion": CAP_PER_COMPANION, "particles": CAP_PARTICLES, "lights": CAP_LIGHTS, "highlights": CAP_HIGHLIGHTS,
        "combos": lua_list(lua, combos),
    })
    try:
        if "client" not in parts:
            raise StopIteration
        out = lua.execute(SCENARIOS, params)
        fails += [f"client: {m}" for m in out.fails.values()]
        facts += list(out.facts.values())
        cues = list(out.cues.values())
        missing = [c for c in cues if sound.Sounds[c] is None]
        for c in missing:
            fails.append(f"sounds: the client plays {c}, which SoundConfig does not have")
        facts.append(f"sound cues the client can play: {len(cues)}, all in SoundConfig: {not missing}")
    except StopIteration:
        pass
    except Exception as exc:
        fails.append(f"client: scenarios crashed: {exc}")

    try:
        if "animation" not in parts:
            raise StopIteration
        anim = lua.execute(ANIMATION, data, params)
        fails += [f"animation: {m}" for m in anim.fails.values()]
        facts += list(anim.facts.values())
    except StopIteration:
        pass
    except Exception as exc:
        fails.append(f"animation: crashed: {exc}")
    return fails, facts


def sources_of(root):
    out = {}
    for rel in (CLIENT, ANIM, DATA, RARITY, SOUNDS):
        out[rel] = luau_to_lua(read(root, rel))
    # The server source goes through companion_ability_check's own rewrite, as that check runs it.
    out[SERVICE] = read(root, SERVICE)
    return out


def prepare(root, raw):
    ability = load_ability_check(root)
    src = dict(raw)
    src[SERVICE] = ability.luau_to_lua(raw[SERVICE])
    src[DATA] = ability.luau_to_lua(read(root, DATA))
    for rel in (CLIENT, ANIM, RARITY, SOUNDS):
        src[rel] = luau_to_lua(raw[rel])
    return src


# Each plant breaks an invariant the code must hold forever, not a bug that was once there.
PLANTS = [
    ("effects never destroy their host", CLIENT, "\tfx.host:Destroy()\n\tbudget.lights -= fx.lights", "\tbudget.lights -= fx.lights"),
    ("per-companion cap raised to 160", CLIENT, "\tEFFECTS_PER_COMPANION = 16,", "\tEFFECTS_PER_COMPANION = 160,"),
    ("total effect cap raised to 640", CLIENT, "\tEFFECTS = 64,", "\tEFFECTS = 640,"),
    ("particle budget ignored", CLIENT, "local allowed = math.min(math.floor(count), CAPS.PARTICLES - budget.particles)",
     "local allowed = math.floor(count)"),
    ("rim glow cap ignored", CLIENT, "\tif budget.highlights >= room then\n\t\treturn nil\n\tend\n", ""),
    ("light cap ignored", CLIENT, "if not fx.detail or budget.lights >= CAPS.LIGHTS then", "if not fx.detail then"),
    ("landing drawn on the windup, not on `lands`", CLIENT, "\t\tschedule(lands, function()", "\t\tschedule(windup, function()"),
    ("strike a frame late (scheduled after the windup)", CLIENT, "\tschedule(windup, function()\n\t\tmark(\"strike\", ctx)",
     "\tschedule(windup + 0.05, function()\n\t\tmark(\"strike\", ctx)"),
    ("no distance cull on a move", CLIENT, "\tif distance > CAPS.CULL_DISTANCE then\n\t\treturn\n\tend\n\tlocal own", "\tlocal own"),
    ("particles built past the detail distance", CLIENT, "\tif not fx.detail then\n\t\treturn nil\n\tend\n\tlocal e = Instance.new(\"ParticleEmitter\")",
     "\tlocal e = Instance.new(\"ParticleEmitter\")"),
    ("an emitter left running on a rate", CLIENT, "\te.Enabled = false\n", "\te.Enabled = true\n"),
    ("Burn's signature lost", CLIENT, "SIGNATURE.Burn = function", "SIGNATURE.Burnt = function"),
    ("Fork's arc drawn as a plain bolt", CLIENT, "name = forked and \"ForkArc\" or \"Bolt\"", "name = \"Bolt\""),
    ("everyone's hits pulse your screen", CLIENT, "\tlocal own = player ~= nil and info.owner ~= nil and info.owner == player.UserId\n\tlocal style = STYLE[info.style]",
     "\tlocal own = true\n\tlocal style = STYLE[info.style]"),
    ("the screen pulse turned up to 0.6", CLIENT, "\tVIGNETTE = 0.22,", "\tVIGNETTE = 0.6,"),
    # Both guards on an effect's life go (the per-effect cap and the style-length clamp): one alone is
    # covered by the other, so removing one is not a fault the game would show.
    ("no lifetime cap (a 30 s poison lives 30 s)", CLIENT, [("\t\tlife = math.min(life, CAPS.EFFECT_LIFE),", "\t\tlife = life,"),
     ("math.clamp(tonumber(info.styleTime) or 1, 0.3, CAPS.EFFECT_LIFE - 0.5)", "math.max(tonumber(info.styleTime) or 1, 0.3)")], None),
    ("a cue SoundConfig doesn't have", CLIENT, "\tcue = \"CompanionFxQuake\",", "\tcue = \"CompanionFxQuack\","),
    ("the ground found on a target's legs", CLIENT, "\t\t\ttable.insert(exclude, model)\n", "\t\t\treturn result.Position + UP * 0.1\n"),
    ("an effect host turned toward its target", CLIENT, "\tnozzle.Parent = fx.host\n",
     "\tnozzle.Parent = fx.host\n\tfx.host.CFrame = CFrame.lookAt(from, from + (look.Magnitude > 0.1 and look or Vector3.new(0, 0, -1)))\n"),
    ("a property the class doesn't have", CLIENT, "\tl.Shadows = false\n", "\tl.CastShadows = false\n"),
    ("a clip that doesn't return to rest", ANIM, "{ W + 0.34, -0.04 }, { D.Spit, 0 } },", "{ W + 0.34, -0.04 }, { D.Spit, 0.2 } },"),
    ("a glow that peaks after the strike", ANIM, "glow = { { 0, 0 }, { W, 1, \"in\" }, { W + 0.08, 0.2 }, { D.Zap, 0 } },",
     "glow = { { 0, 0 }, { W + 0.05, 1, \"in\" }, { W + 0.08, 0.2 }, { D.Zap, 0 } },"),
    ("a Quick tail that stops before its clip is back at rest", ANIM, "\treturn strike + (t - strike) / QUICK_TAIL", "\treturn t"),
    ("a clip longer than its cooldown", ANIM, "\tShockwave = 0.85,", "\tShockwave = 4.5,"),
    ("the server's `lands` for a travelling move left at the windup", SERVICE,
     "\t\tpayload.travel = travel\n\t\tpayload.lands = WINDUP + travel\n", "\t\tpayload.travel = travel\n"),
    ("a blast brainrot's use not broadcast", SERVICE, "\t\t\tbroadcast(companionAttack, payload)\n\t\telseif token then", "\t\telseif token then"),
    ("hit victims not reported", SERVICE, "\t\t\treport.victims[#report.positions] = Combatants.GetCharacter(token) or false\n", ""),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    raw = {rel: read(root, rel) for rel in (CLIENT, ANIM, DATA, RARITY, SOUNDS, SERVICE)}

    if "--plant" not in sys.argv:
        fails, facts = check(root, prepare(root, raw))
        for f in facts:
            print("  " + f)
        for f in fails:
            print("FAIL " + f)
        print(f"companion_fx_check: {'PASS' if not fails else 'FAIL'} ({len(fails)} failures)")
        sys.exit(1 if fails else 0)

    # A plant only needs the half of the check that reads its file (the client's scenarios also run
    # the animation module, but a clip fault is judged by the animation half, which is its subject).
    parts_for = {CLIENT: ("client",), ANIM: ("animation",), SERVICE: ("server",)}
    missed = 0
    for label, rel, old, new in PLANTS:
        planted = dict(raw)
        swaps = old if isinstance(old, list) else [(old, new)]
        stale = [a for a, _ in swaps if planted[rel].count(a) != 1]
        if stale:
            print(f"  plant [{label}]: STALE -- its text is not in {rel} exactly once")
            missed += 1
            continue
        for a, b in swaps:
            planted[rel] = planted[rel].replace(a, b)
        fails, _ = check(root, prepare(root, planted), parts_for[rel])
        print(f"  plant [{label}]: {'CAUGHT' if fails else 'MISSED'}" + (f" -- {fails[0][:150]}" if fails else ""))
        missed += 0 if fails else 1
    print(f"companion_fx_check --plant: {len(PLANTS) - missed}/{len(PLANTS)} caught")
    sys.exit(1 if missed else 0)


if __name__ == "__main__":
    main()
