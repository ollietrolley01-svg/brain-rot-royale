"""#117: the lobby range podiums. Runs the REAL RangeService.lua (lupa) against a stand-in
WeaponService that keeps loadouts the way the real one does (Reset installs a new table,
GiveWeapon fills the first empty slot and only selects it when the hands were empty, Equip
selects a filled slot, CancelReload ends a reload).

Invariants checked:
  1. Taking each of the three podium guns in turn leaves all three in the hotbar, the last one
     in hand (the bug: every take Reset the loadout, so you only ever had the last gun).
  2. Taking a gun you already hold does not add a second copy; it is in hand and topped up.
  3. The range only ever adds to a loadout IT made. If the player's loadout is some other table
     (a match's, #106), a take starts a fresh one and never writes into the other.
  4. Walking off hands everything back (the loadout is cleared).

Planted faults (each must make the check fail, run every time):
  A. the identity check `WeaponService.Get(player) == ours` replaced by `true`  -> invariant 3
  B. Give always Resets first (the old behaviour)                               -> invariant 1

Usage: python3 tools/range_give_check.py [repo_root]
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
SOURCE = (ROOT / "ServerScriptService/Modules/RangeService.lua").read_text(encoding="utf-8")

HARNESS = r"""
local source, weaponIds = ...
local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x, y, z) return setmetatable({ X = x, Y = y, Z = z }, Vector3) end
Vector3.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
Vector3.__index = function(v, k)
  if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z) end
  return rawget(Vector3, k)
end

local defs = {}
for i, id in ipairs(weaponIds) do defs[id] = { id = id, name = id, magSize = 5 + i, reserveAmmo = 20 + i } end
local WeaponData = { Get = function(id) return defs[id] end }

local loadouts, SLOT_COUNT = {}, 8
local WS = { SlotCount = SLOT_COUNT }
function WS.Get(p) return loadouts[p] end
function WS.Reset(p) loadouts[p] = { slots = {}, equipped = nil } end
function WS.Clear(p) loadouts[p] = nil end
function WS.Push() end
function WS.GiveWeapon(p, id)
  local l, def = loadouts[p], defs[id]
  if not l or not def then return false, "Not in a match." end
  local wasEmpty = not (l.equipped and l.slots[l.equipped])
  for i = 1, SLOT_COUNT do
    if not l.slots[i] then
      l.slots[i] = { kind = "weapon", id = id, mag = def.magSize, reserve = def.reserveAmmo }
      if wasEmpty then l.equipped = i end
      return true
    end
  end
  local t = l.equipped or 1
  l.slots[t] = { kind = "weapon", id = id, mag = def.magSize, reserve = def.reserveAmmo }
  l.equipped = t
  return true
end
function WS.Equip(p, i)
  local l = loadouts[p]
  if l and l.slots[i] then l.equipped = i end
end
function WS.CancelReload(p)
  local l = loadouts[p]
  if l then l.reloading = false end
end

local function event() return { FireClient = function() end, OnServerEvent = { Connect = function() end } } end
local modules = {
  Remotes = { Event = function() return event() end },
  SafeValue = {}, WeaponData = WeaponData,
  CombatService = { IsEnabled = function() return false end },
  PracticeDummy = {}, RateLimit = {}, StateSync = { Notify = function() end },
  WeaponService = WS,
}
local function node(name)
  return { Name = name, WaitForChild = function(_, child) return node(child) end }
end
local services = {
  CollectionService = {}, ReplicatedStorage = node("ReplicatedStorage"),
  Players = { PlayerRemoving = { Connect = function() end } },
}
local env = setmetatable({
  game = { GetService = function(_, n) return services[n] end },
  script = { Parent = node("Modules") },
  require = function(m) return modules[m.Name] end,
  task = { spawn = function() end, wait = function() end },
  Vector3 = Vector3,
}, { __index = _G })
local chunk = assert(load(source, "RangeService", "t", env))
local Range = chunk()

local player = { Parent = true, Character = { FindFirstChild = function(_, n)
  if n == "HumanoidRootPart" then return { Position = Vector3.new(0, 0, 0) } end
end } }
Range.SetArea(Vector3.new(0, 0, 0), 32)

local function ids(l)
  local out = {}
  for i = 1, SLOT_COUNT do if l.slots[i] then table.insert(out, l.slots[i].id) end end
  return table.concat(out, ",")
end
local failures, checks = {}, 0
local function check(ok, msg) checks = checks + 1; if not ok then table.insert(failures, msg) end end

-- 1. three podiums in turn
local A, B, C = weaponIds[1], weaponIds[2], weaponIds[3]
for _, id in ipairs({ A, B, C }) do assert(Range.Give(player, id)) end
local l = WS.Get(player)
check(ids(l) == A .. "," .. B .. "," .. C, "1: after taking A, B, C the hotbar is " .. ids(l))
check(l.slots[l.equipped].id == C, "1: last gun taken is not the one in hand")

-- 2. the same gun again
l.slots[1].mag, l.slots[1].reserve = 0, 0
assert(Range.Give(player, A))
l = WS.Get(player)
check(ids(l) == A .. "," .. B .. "," .. C, "2: taking A again changed the hotbar to " .. ids(l))
check(l.slots[l.equipped].id == A, "2: A is not in hand after taking it again")
check(l.slots[1].mag == defs[A].magSize and l.slots[1].reserve == defs[A].reserveAmmo, "2: A was not topped up")

-- 3. a loadout the range did not make
local matchLoadout = { slots = { { kind = "weapon", id = B, mag = 1, reserve = 1 } }, equipped = 1 }
loadouts[player] = matchLoadout
assert(Range.Give(player, C))
check(WS.Get(player) ~= matchLoadout, "3: the range wrote into a loadout it did not make")
check(ids(matchLoadout) == B, "3: the other loadout was changed to " .. ids(matchLoadout))
check(ids(WS.Get(player)) == C, "3: the fresh range loadout holds " .. ids(WS.Get(player)))

-- 4. walking off
Range.Stop(player)
check(WS.Get(player) == nil, "4: stepping off did not hand the guns back")

return checks, table.concat(failures, "\n")
"""

IDS = ["GunA", "GunB", "GunC"]


def run(source):
    lua = LuaRuntime(unpack_returned_tuples=True)
    fn = lua.execute("return function(...) " + HARNESS + " end")
    return fn(source, lua.table(*IDS))


def mutate(old, new):
    assert SOURCE.count(old) == 1, "planted fault anchor missing: " + old
    return SOURCE.replace(old, new)


checks, failures = run(SOURCE)
print(f"range give check: {checks} checks on the real RangeService.lua")
if failures:
    print("FAIL\n" + failures)
    sys.exit(1)

faults = {
    "A (identity check removed)": mutate("if ours and WeaponService.Get(player) == ours then", "if ours and true then"),
    "B (always Reset, the old behaviour)": mutate("if ours and WeaponService.Get(player) == ours then", "if false then"),
}
bad = 0
for name, source in faults.items():
    _, failures = run(source)
    caught = bool(failures)
    print(f"  planted fault {name}: {'caught' if caught else 'NOT CAUGHT'}" + (f" -- {failures.splitlines()[0]}" if caught else ""))
    bad += not caught
if bad:
    print("FAIL: a planted fault went uncaught")
    sys.exit(1)
print("OK")
