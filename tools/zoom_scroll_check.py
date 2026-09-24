"""Behaviour check for #25 (zoom on Z, the mouse wheel switches hotbar items), without Studio.

Cuts the real slot-selection and wheel region out of StarterPlayerScripts/CombatClient.client.lua
(from `local SLOT_COUNT` to the Z binding) and runs it in a Lua interpreter (lupa) with Settings,
the player, the remotes and the input services mocked. Then it scrolls the wheel and presses Q and
checks which slot the server is asked to equip.

    python tools/zoom_scroll_check.py .            the checks
    python tools/zoom_scroll_check.py . --plant    the planted faults; every one must be caught

What it proves: the wheel wraps round both ways, skips empty slots, and does nothing with a menu
open, while driving, out of combat, or when a GUI took the scroll. What it cannot prove: that
Roblox reports the wheel as InputChanged with Position.Z = +/-1 (documented, not run here), and
that the camera pin stops the stock camera zooming on the same scroll -- that needs a playtest.
"""

import os
import re
import sys

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("zoom_scroll_check: needs lupa (pip install lupa)")

START = "local SLOT_COUNT = 8"
END = "-- Z steps the camera OUT"


def region(root):
    path = os.path.join(root, "StarterPlayerScripts", "CombatClient.client.lua")
    text = open(path, encoding="utf-8").read()
    start = text.index(START)
    return text[start:text.index(END, start)]


PRELUDE = r"""
local Enum = {
    UserInputState = { Begin = "Begin", End = "End" },
    ContextActionResult = { Pass = "Pass" },
    UserInputType = { MouseWheel = "MouseWheel", MouseMovement = "MouseMovement" },
    KeyCode = { ButtonR1 = "ButtonR1" },
}
local binds, inputChanged, equipped = {}, nil, {}
local attrs = {}
local combat = true
local player = {
    CameraMinZoomDistance = 0.5, CameraMaxZoomDistance = 20,
    GetAttribute = function(_, name) return attrs[name] end,
}
local Settings = { Bind = function(name, _, handler) binds[name] = handler end }
local RunService = { Heartbeat = { Connect = function() end } }
local UserInputService = { InputChanged = { Connect = function(_, f) inputChanged = f end } }
local equipRemote = { FireServer = function(_, index) table.insert(equipped, index) end }
local MatchConfig = { EquipTime = 0.3 }
local localEquipReadyAt = 0
local zoomDistance = 9
local loadout = nil
local function inCombat() return combat and loadout ~= nil and not attrs.MenuOpen end
"""

EPILOGUE = r"""
return {
    setLoadout = function(l) loadout = l end,
    setCombat = function(c) combat = c end,
    setAttr = function(k, v) attrs[k] = v end,
    wheel = function(z, processed)
        inputChanged({ UserInputType = Enum.UserInputType.MouseWheel, Position = { Z = z } }, processed or false)
    end,
    nextSlot = function() binds.BRR_NextSlot(nil, Enum.UserInputState.Begin) end,
    drain = function()
        local out = equipped
        equipped = {}
        return out
    end,
}
"""


def loadout_of(lua, equipped, filled):
    slots = lua.table_from({i: "gun%d" % i for i in filled})
    return lua.table_from({"equipped": equipped, "slots": slots})


def run(src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    env = lua.execute(PRELUDE + src + EPILOGUE)
    fails = []

    def scroll(z, equipped, filled, processed=False):
        env.setLoadout(loadout_of(lua, equipped, filled))
        env.wheel(z, processed)
        return list(env.drain().values())

    def expect(name, got, want):
        if got != want:
            fails.append("%s: got %r, want %r" % (name, got, want))

    full = range(1, 9)
    expect("wheel down steps forward", scroll(-1, 2, full), [3])
    expect("wheel up steps back", scroll(1, 2, full), [1])
    expect("wheel down wraps 8 -> 1", scroll(-1, 8, full), [1])
    expect("wheel up wraps 1 -> 8", scroll(1, 1, full), [8])
    expect("down skips empty slots", scroll(-1, 1, [1, 4, 6]), [4])
    expect("up skips empties and wraps", scroll(1, 1, [1, 4, 6]), [6])
    expect("lone item: no re-equip", scroll(-1, 3, [3]), [])
    expect("GUI took the scroll", scroll(-1, 2, full, processed=True), [])

    env.setAttr("MenuOpen", True)
    expect("menu open", scroll(-1, 2, full), [])
    env.setAttr("MenuOpen", None)

    env.setAttr("InVehicle", True)
    expect("driving (wheel is the vehicle camera's)", scroll(-1, 2, full), [])
    env.setAttr("InVehicle", None)

    env.setCombat(False)
    expect("out of combat (lobby zooms)", scroll(-1, 2, full), [])
    env.setCombat(True)

    # Q and the wheel must agree on "next".
    env.setLoadout(loadout_of(lua, 1, [1, 4, 6]))
    env.nextSlot()
    expect("Q matches wheel-down", list(env.drain().values()), [4])
    return fails


PLANTS = [
    ("wheel ignores the vehicle gate",
     'or player:GetAttribute("MenuOpen") or player:GetAttribute("InVehicle") then',
     'or player:GetAttribute("MenuOpen") then'),
    ("cycle does not skip empty slots",
     "local index = (current - 1 + step * offset) % SLOT_COUNT + 1\n\t\tif loadout.slots[index] then",
     "local index = (current - 1 + step * offset) % SLOT_COUNT + 1\n\t\tif true then"),
    ("cycle does not wrap",
     "local index = (current - 1 + step * offset) % SLOT_COUNT + 1",
     "local index = math.max(1, math.min(SLOT_COUNT, current + step * offset))"),
    ("wheel direction flipped",
     "cycleSlot(input.Position.Z > 0 and -1 or 1)",
     "cycleSlot(input.Position.Z > 0 and 1 or -1)"),
    ("processed scroll not ignored",
     "if processed or input.UserInputType",
     "if input.UserInputType"),
]


def main():
    root = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") else "."
    src = region(root)
    if "--plant" in sys.argv:
        missed = 0
        for name, before, after in PLANTS:
            if before not in src:
                print("PLANT TEXT NOT FOUND (source moved): " + name)
                missed += 1
                continue
            fails = run(src.replace(before, after, 1))
            print(("caught  " if fails else "MISSED  ") + name + (" -- " + fails[0] if fails else ""))
            missed += 0 if fails else 1
        sys.exit(1 if missed else 0)
    fails = run(src)
    for f in fails:
        print("FAIL " + f)
    print("zoom_scroll_check: %d failure(s)" % len(fails))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
