"""One owner for the OS mouse arrow (MouseIconEnabled), checked without Studio.

MenuCursor.client.lua is the only script that may write UserInputService.MouseIconEnabled (#112, "can
still see my cursor in FPS": two writers left the arrow on whatever the last one wrote). The vehicle
gun's aim-at-the-mouse (d9257c2) added a second writer: VehicleWeaponClient hid the arrow while its
aim mark was the cursor and "gave it back" (true) on leaving the seat. MenuCursor re-derives the icon
on every MouseBehavior change, so a right-drag of the camera put the arrow back beside the mark; and
leaving the seat into first-person combat set it visible over the crosshair. Now VehicleWeaponClient
only sets the local `AimCursor` attribute and MenuCursor folds it in.

  A  static: no Luau file under StarterPlayerScripts or ReplicatedStorage but MenuCursor assigns
     MouseIconEnabled (comments stripped, so a mention in prose doesn't count); files examined printed
  B  MenuCursor.client.lua itself, in a small mock (Players, UserInputService, RunService, GUI
     instances with real property-changed and attribute-changed signals), driven through sequences:
     the icon must be hidden while AimCursor is set with a free mouse, STAY hidden across a
     MouseBehavior change, hidden in FPS (LockCenter) whatever AimCursor says, shown whenever a menu
     is open, and shown again with a free mouse once AimCursor clears
  C  VehicleWeaponClient in tools/hud_mock_world.lua (the HUD check's client), driving an armed car
     with a mouse: AimCursor is set while seated, cleared on leaving the seat, and MouseIconEnabled is
     never written by it

    python3 tools/cursor_owner_check.py [repo]            the checks
    python3 tools/cursor_owner_check.py [repo] --plant    the planted faults; every one must be caught
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lupa import LuaRuntime  # noqa: E402

OWNER = "MenuCursor.client.lua"
VWC = "VehicleWeaponClient.client.lua"


def strip_comments(text):
    text = re.sub(r"--\[(=*)\[.*?\]\1\]", "", text, flags=re.S)
    return re.sub(r"--[^\n]*", "", text)


def check_static(root, override=None):
    problems, examined = [], 0
    for folder in ("StarterPlayerScripts", "ReplicatedStorage"):
        for dirpath, _, files in os.walk(os.path.join(root, folder)):
            for name in files:
                if not name.endswith(".lua"):
                    continue
                examined += 1
                text = (override or {}).get(name)
                if text is None:
                    text = open(os.path.join(dirpath, name), encoding="utf-8").read()
                code = strip_comments(text)
                for m in re.finditer(r"MouseIconEnabled\s*=(?!=)", code):
                    if name != OWNER:
                        line = code[:m.start()].count("\n") + 1
                        problems.append("A: %s writes MouseIconEnabled (line %d of the comment-stripped source); only %s may"
                                        % (name, line, OWNER))
    return problems, examined


MENU_MOCK = r"""
local Signal = {}
Signal.__index = Signal
function Signal.new() return setmetatable({ list = {} }, Signal) end
function Signal:Connect(fn) table.insert(self.list, fn); return { Disconnect = function() end } end
function Signal:Fire(...) for _, fn in ipairs(self.list) do fn(...) end end

Enum = { MouseBehavior = { Default = "Default", LockCenter = "LockCenter", LockCurrentPosition = "LockCurrentPosition" },
    RenderPriority = { Last = { Value = 2000 } } }

local function object(props)
    local o = props or {}
    o.__attrs, o.__attrSignals, o.__propSignals = {}, {}, {}
    return o
end
local function setProp(o, key, value)
    local old = rawget(o, key)
    rawset(o, key, value)
    if old ~= value and o.__propSignals[key] then o.__propSignals[key]:Fire() end
end
local Methods = {}
function Methods.GetAttribute(self, k) return self.__attrs[k] end
function Methods.SetAttribute(self, k, v)
    local old = self.__attrs[k]
    self.__attrs[k] = v
    if old ~= v and self.__attrSignals[k] then self.__attrSignals[k]:Fire() end
end
function Methods.GetAttributeChangedSignal(self, k)
    self.__attrSignals[k] = self.__attrSignals[k] or Signal.new()
    return self.__attrSignals[k]
end
function Methods.GetPropertyChangedSignal(self, k)
    self.__propSignals[k] = self.__propSignals[k] or Signal.new()
    return self.__propSignals[k]
end
function Methods.WaitForChild(self, name) return self[name] end
local meta = { __index = Methods }

UIS = setmetatable(object({ MouseBehavior = "Default", MouseIconEnabled = true }), meta)
ICON_WRITES = 0
-- Every write to the icon is counted; property writes go through setProp so signals fire.
local uisRaw = UIS
local playerGui = setmetatable(object({}), meta)
PLAYER = setmetatable(object({ PlayerGui = playerGui }), meta)
local Players = { LocalPlayer = PLAYER }
BOUND = {}
local RunService = {
    BindToRenderStep = function(_, name, _, fn) BOUND[name] = fn end,
    UnbindFromRenderStep = function(_, name) BOUND[name] = nil end,
}
function game_GetService(_, name)
    if name == "Players" then return Players end
    if name == "RunService" then return RunService end
    if name == "UserInputService" then return UIS_PROXY end
    error("no service " .. name)
end
game = { GetService = game_GetService }
-- A proxy so writes to MouseBehavior / MouseIconEnabled fire the property-changed signal.
UIS_PROXY = setmetatable({}, {
    __index = function(_, k)
        local v = rawget(uisRaw, k)
        if v ~= nil then return v end
        local m = Methods[k]
        if m then return function(_, ...) return m(uisRaw, ...) end end
        return nil
    end,
    __newindex = function(_, k, v)
        if k == "MouseIconEnabled" then ICON_WRITES = ICON_WRITES + 1 end
        setProp(uisRaw, k, v)
    end,
})
Instance = { new = function(class)
    local o = setmetatable(object({ ClassName = class }), meta)
    return o
end }
UDim2 = { fromOffset = function() return {} end }
script = { Destroying = Signal.new() }

function setBehaviour(b) UIS_PROXY.MouseBehavior = b end
function icon() return rawget(uisRaw, "MouseIconEnabled") end
function renderFrame() for _, fn in pairs(BOUND) do fn() end end
"""

# (what happens, then the icon it must leave). Each step is Lua run against the mock.
SEQUENCE = [
    ("start: free mouse, no menu, no vehicle gun", "", True),
    ("seated at a vehicle gun with a free mouse (AimCursor set)", "PLAYER:SetAttribute('AimCursor', true)", False),
    ("right-drag of the camera: MouseBehavior to LockCurrentPosition", "setBehaviour('LockCurrentPosition')", False),
    ("drag released: MouseBehavior back to Default", "setBehaviour('Default')", False),
    ("a menu opens over the vehicle gun", "PLAYER:SetAttribute('MenuOpen', true); renderFrame()", True),
    ("the menu closes", "PLAYER:SetAttribute('MenuOpen', nil)", False),
    ("out of the seat into first-person combat: LockCenter first", "setBehaviour('LockCenter')", False),
    ("AimCursor cleared while in FPS", "PLAYER:SetAttribute('AimCursor', nil)", False),
    ("FPS left: free mouse again", "setBehaviour('Default')", True),
    ("seated again, then leaving on foot (AimCursor cleared, mouse free)",
     "PLAYER:SetAttribute('AimCursor', true); PLAYER:SetAttribute('AimCursor', nil)", True),
]


def check_menu_cursor(owner_src):
    problems, examined = [], 0
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MENU_MOCK)
    lua.execute(owner_src)
    for what, code, want in SEQUENCE:
        examined += 1
        if code:
            lua.execute(code)
        got = lua.eval("icon()")
        if got != want:
            problems.append("B: after '%s' the OS arrow is %s, want %s" % (what, "shown" if got else "hidden",
                                                                             "shown" if want else "hidden"))
    return problems, examined


def check_vehicle_client(root, sources):
    import hud_layout_check as hud
    problems, examined = [], 0
    world = hud.World(root, ("1366x768", 1366, 768, False), sources)
    world.play("BattleRoyale", "driver")
    got = world.run("""
        W.UserInputService.MouseIconEnabled = 'untouched'
        W.lastInput = 'MouseMovement'
        W.mouse = W.Vector2.new(400, 300)
        W.frame(2)
        local seated = W.player:GetAttribute('AimCursor')
        W.lastInput = 'Gamepad1'
        W.frame(2)
        local pad = W.player:GetAttribute('AimCursor')
        W.lastInput = 'MouseMovement'
        W.frame(2)
        W.special(W.character.Humanoid).SeatPart = nil
        W.frame(2)
        local left = W.player:GetAttribute('AimCursor')
        return string.format('%s %s %s %s', tostring(seated), tostring(pad), tostring(left),
            tostring(W.UserInputService.MouseIconEnabled))
    """)
    seated, pad, left, iconv = got.split()
    examined += 4
    if seated != "true":
        problems.append("C: seated at the gun with a free mouse, AimCursor is %s, want true" % seated)
    if pad != "nil":
        problems.append("C: on a pad (the mark is in the middle, not the cursor), AimCursor is %s, want nil" % pad)
    if left != "nil":
        problems.append("C: after leaving the seat AimCursor is %s, want nil (the arrow would stay hidden)" % left)
    if iconv != "untouched":
        problems.append("C: VehicleWeaponClient wrote MouseIconEnabled (%s); only MenuCursor may" % iconv)
    return problems, examined


def run(root, override=None):
    import hud_layout_check as hud
    sources = {n: hud.read(root, n) for n in hud.SCRIPTS}
    for m in hud.MODULES:
        sources[m + ".lua"] = hud.read(root, m + ".lua")
    owner = hud.read(root, OWNER)
    for name, text in (override or {}).items():
        if name in sources:
            sources[name] = text
        if name == OWNER:
            owner = text
    a, na = check_static(root, override)
    b, nb = check_menu_cursor(owner)
    c, nc = check_vehicle_client(root, sources)
    return a + b + c, (na, nb, nc)


PLANTS = [
    ("the vehicle gun writes the icon again", VWC,
     'player:SetAttribute("AimCursor", hide or nil)', "UserInputService.MouseIconEnabled = not hide"),
    ("MenuCursor ignores AimCursor", OWNER,
     'and player:GetAttribute("AimCursor") ~= true', ""),
    ("MenuCursor does not listen for AimCursor", OWNER,
     'player:GetAttributeChangedSignal("AimCursor"):Connect(function()', 'player:GetAttributeChangedSignal("AimCursorX"):Connect(function()'),
    ("the vehicle gun never clears AimCursor", VWC,
     "\telse\n\t\tsetCursorHidden(false)\n", "\telse\n"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    problems, (na, nb, nc) = run(root)
    print("cursor_owner_check: %d Luau files scanned, %d MenuCursor steps, %d vehicle-gun cases" % (na, nb, nc))
    for p in problems:
        print("PROBLEM", p)
    print("problems: %d" % len(problems))
    ok = not problems
    if "--plant" in sys.argv:
        for what, name, anchor, replacement in PLANTS:
            folder = "StarterPlayerScripts"
            text = open(os.path.join(root, folder, name), encoding="utf-8").read()
            if anchor not in text:
                print("plant %s: ANCHOR MISSING" % what)
                ok = False
                continue
            found, _ = run(root, {name: text.replace(anchor, replacement, 1)})
            print("plant %-45s %s (%d problems)" % (what + ":", "caught" if found else "MISSED", len(found)))
            ok &= bool(found)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
