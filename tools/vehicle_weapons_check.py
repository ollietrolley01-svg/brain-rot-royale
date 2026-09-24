"""Mounted vehicle weapons: runs the real ServerScriptService/Modules/VehicleWeapons.lua (with the real
Shared/VehicleWeaponData.lua, Shared/SafeValue.lua and CombatService's own ShotCredit/SpendShot, cut
out of CombatService.lua) against mocks, and checks what the server must hold a shot to:

  * each seat works its own mount: the gunner's seat the turret, the driving seat the driver's gun
    (a lone driver never the turret); a passenger, a stale SeatPart, someone on foot are refused --
    for a Player and for a bot token alike;
  * the fire rate (CombatService's shot budget) and the magazine are enforced; the magazine recharges;
    a belt run dry overheats and holds fire until it has cooled back to its `overheat` share;
  * the mount's aim clamp holds (yaw arc, pitch limits, the launcher's front-arc floor), in the
    vehicle's own frame, from the mount's geometry as VehicleModels builds it;
  * a barrel pushed into a wall fires into the wall; a bullet that meets another vehicle goes through
    CombatService.DamageVehicle;
  * a bullet's damage goes through CombatService.DealDamage (and nothing else), a round goes through
    CombatService.LaunchProjectile (ProjectileService's launcher path);
  * the firing vehicle and its riders are excluded, from the bullet's trace and from the round's
    flight filter (the Ballistics onLaunch guard);
  * nothing fires with combat off (the lobby), or from a wrecked vehicle;
  * the models that carry a mount (VehicleModels.Mounts) are exactly the ones with a weapon, and no
    bike is among them.

Every check is then re-run against planted faults, each aimed at one of those invariants; the run
fails unless every fault is caught.

    python3 tools/vehicle_weapons_check.py [repo_root]
"""
import math
import re
import sys
from pathlib import Path

from lupa import LuaRuntime

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()


def luau_to_lua(src):
    # Compound assignment is the only Luau syntax these files use that Lua lacks.
    out = []
    for line in src.split("\n"):
        m = re.match(r"^(\s*)([\w.\[\]\"]+)\s*([+\-*/])=\s*(.+)$", line)
        if m:
            line = f"{m.group(1)}{m.group(2)} = {m.group(2)} {m.group(3)} ({m.group(4)})"
        out.append(line)
    return "\n".join(out)


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def shot_budget_source():
    src = read("ServerScriptService/Modules/CombatService.lua")
    burst = re.search(r"^local FIRE_BURST = .*$", src, re.M).group(0)
    credit = re.search(r"^function CombatService\.ShotCredit.*?^end$", src, re.M | re.S).group(0)
    spend = re.search(r"^function CombatService\.SpendShot.*?^end$", src, re.M | re.S).group(0)
    return "\n".join([burst, credit, spend])


MOCKS = r"""
-- Vector3 ------------------------------------------------------------------
local V3 = {}
V3.__index = function(v, k)
  if k == "Magnitude" then return math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z) end
  if k == "Unit" then local m = math.sqrt(v.X*v.X + v.Y*v.Y + v.Z*v.Z); return Vector3.new(v.X/m, v.Y/m, v.Z/m) end
  return V3[k]
end
V3.__add = function(a, b) return Vector3.new(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end
V3.__sub = function(a, b) return Vector3.new(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end
V3.__unm = function(a) return Vector3.new(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
  if type(a) == "number" then return Vector3.new(b.X*a, b.Y*a, b.Z*a) end
  return Vector3.new(a.X*b, a.Y*b, a.Z*b)
end
V3.__div = function(a, b) return Vector3.new(a.X/b, a.Y/b, a.Z/b) end
function V3.Cross(a, b) return Vector3.new(a.Y*b.Z - a.Z*b.Y, a.Z*b.X - a.X*b.Z, a.X*b.Y - a.Y*b.X) end
function V3.Dot(a, b) return a.X*b.X + a.Y*b.Y + a.Z*b.Z end
Vector3 = { new = function(x, y, z) return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0, __v3 = true }, V3) end }

-- A frame turned about Y only: all a vehicle on level ground needs.
local CF = {}
CF.__index = CF
function CF:VectorToWorldSpace(v)
  local c, s = math.cos(self.yaw), math.sin(self.yaw)
  return Vector3.new(v.X*c + v.Z*s, v.Y, -v.X*s + v.Z*c)
end
function CF:VectorToObjectSpace(v)
  local c, s = math.cos(-self.yaw), math.sin(-self.yaw)
  return Vector3.new(v.X*c + v.Z*s, v.Y, -v.X*s + v.Z*c)
end
function CF:PointToObjectSpace(p) return self:VectorToObjectSpace(p - self.Position) end
function CF:PointToWorldSpace(p) return self.Position + self:VectorToWorldSpace(p) end
function frame(pos, yaw) return setmetatable({ Position = pos, yaw = yaw, UpVector = Vector3.new(0, 1, 0) }, CF) end

function typeof(v)
  if type(v) == "table" and v.__v3 then return "Vector3" end
  if type(v) == "table" and v.__instance then return "Instance" end
  return type(v)
end
math.clamp = function(x, lo, hi) if x < lo then return lo elseif x > hi then return hi end return x end
math.sign = function(x) if x > 0 then return 1 elseif x < 0 then return -1 end return 0 end
math.atan2 = function(y, x) return math.atan(y, x) end
warnings = {}
function warn(msg) table.insert(warnings, tostring(msg)) end
Enum = { RaycastFilterType = { Exclude = "Exclude", Include = "Include" } }
RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end }

local function signal() local s = { fns = {} }; function s:Connect(fn) table.insert(self.fns, fn); return { Disconnect = function() end } end; return s end

-- Instances ------------------------------------------------------------------
local Inst = {}
Inst.__index = Inst
function new(className, name, parent, props)
  local i = setmetatable({ __instance = true, ClassName = className, Name = name, attrs = {}, children = {}, AncestryChanged = signal() }, Inst)
  for k, v in pairs(props or {}) do i[k] = v end
  if parent then i.Parent = parent; table.insert(parent.children, i) end
  return i
end
function Inst:IsA(c)
  if c == "Seat" then return self.ClassName == "Seat" end
  return self.ClassName == c or (c == "BasePart" and (self.ClassName == "Part" or self.ClassName == "Seat" or self.ClassName == "VehicleSeat"))
end
function Inst:GetAttribute(k) return self.attrs[k] end
function Inst:SetAttribute(k, v) self.attrs[k] = v end
function Inst:FindFirstChild(n) for _, c in ipairs(self.children) do if c.Name == n then return c end end return nil end
function Inst:FindFirstChildOfClass(c) for _, ch in ipairs(self.children) do if ch.ClassName == c then return ch end end return nil end
function Inst:GetChildren() return self.children end
function Inst:IsDescendantOf(x) local p = self.Parent; while p do if p == x then return true end; p = p.Parent end; return false end
function Inst:FindFirstAncestorOfClass(c) local p = self.Parent; while p do if p.ClassName == c then return p end; p = p.Parent end; return nil end
function Inst:Sit(h) self.Occupant = h; h.SeatPart = self end
game = new("DataModel", "game")
workspace = new("Workspace", "Workspace", game)

-- Raycast: every part is a sphere of `radius`; excluded if it or an ancestor is in the filter.
function workspace:Raycast(origin, direction, params)
  local len = direction.Magnitude
  local unit = direction.Unit
  local best, bestT = nil, math.huge
  local function excluded(part)
    for _, x in ipairs(params.FilterDescendantsInstances) do
      if part == x or part:IsDescendantOf(x) then return true end
    end
    return false
  end
  for _, part in ipairs(WORLD) do
    if part.radius and not excluded(part) then
      local rel = part.Position - origin
      local t = rel:Dot(unit)
      if t >= 0 and t <= len then
        local miss = (rel - unit * t).Magnitude
        if miss <= part.radius and t < bestT then best, bestT = part, t end
      end
    end
  end
  RAYS = RAYS + 1
  if not best then return nil end
  return { Instance = best, Position = origin + unit * bestT }
end
WORLD = {}
RAYS = 0

-- Services and modules -----------------------------------------------------------
local tagged = {}
local services = {
  Players = { PlayerRemoving = signal() },
  CollectionService = { GetTagged = function(_, tag) return tagged end },
  ReplicatedStorage = { WaitForChild = function(_, n) return { WaitForChild = function(_, m) return { __module = m } end } end },
}
function game:GetService(n) return services[n] end
MODULES = {}
function require(ref) return assert(MODULES[ref.__module], "no mock for " .. tostring(ref.__module)) end
script = { Parent = { WaitForChild = function(_, m) return { __module = m } end } }

local remotes = {}
MODULES.Remotes = { Event = function(name)
  remotes[name] = remotes[name] or { OnServerEvent = signal() }
  return remotes[name]
end }
REMOTES = remotes
MODULES.Ballistics = { Rounds = { rocket = {}, grenade = {} } }
MODULES.RateLimit = { Take = function() return true end }

-- Combatants: players and bot records are both tokens.
local byCharacter = {}
MODULES.Combatants = {
  GetCharacter = function(t) return t and t.Character end,
  GetHumanoid = function(t) return t and t.Character and t.Character:FindFirstChildOfClass("Humanoid") end,
  IsAlive = function(t) local h = t and t.Character and t.Character:FindFirstChildOfClass("Humanoid"); return h ~= nil and h.Health > 0 end,
  FromCharacter = function(c) return byCharacter[c] end,
}

-- CombatService: the real shot budget, recorders for everything else.
CombatService = { HeadshotScale = 1 }
LOG = {}
function CombatService.IsEnabled() return ENABLED end
-- The real one rewinds for lag (LagCompensation, #97); the mock traces the present, which is what a bot or a 0-ping shot gets.
function CombatService.Raycast(token, origin, vector, params) return workspace:Raycast(origin, vector, params) end
function CombatService.DealDamage(a, v, amount, weaponId, headshot)
  table.insert(LOG, { what = "damage", attacker = a, victim = v, amount = amount, weaponId = weaponId }); return amount
end
function CombatService.BroadcastShot(shooter, origin, endPoints, rarity)
  table.insert(LOG, { what = "shot", shooter = shooter, origin = origin, endPoints = endPoints })
end
function CombatService.LaunchProjectile(owner, def, origin, direction)
  -- ProjectileService.launchRound's shape: a filter of the owner's character, the def kept on the entry, then the kind's onLaunch.
  local entry = { owner = owner, def = def, filter = { owner.Character }, params = {} }
  entry.params.FilterDescendantsInstances = entry.filter
  local spec = MODULES.Ballistics.Rounds[def.projectile]
  if spec.onLaunch then spec.onLaunch(entry, {}) end
  table.insert(LOG, { what = "round", owner = owner, def = def, origin = origin, direction = direction, filter = entry.filter })
end
function CombatService.VehicleFromPart(part) return part.vehicleOf end
function CombatService.DamageVehicle(a, model, amount, class, weaponId)
  table.insert(LOG, { what = "vehicle", attacker = a, model = model, amount = amount, class = class, weaponId = weaponId }); return amount
end
MODULES.CombatService = CombatService

-- The world: a vehicle, its riders, a victim --------------------------------------------
function makeVehicle(modelId, heading, at)
  local v = new("Model", "Vehicle", workspace)
  v:SetAttribute("VehicleModel", modelId)
  local mount = MOUNTS[modelId]
  local function world(p) return at + frame(Vector3.new(), heading):VectorToWorldSpace(p) end
  local yawAt = mount.yaw; local pitchAt = mount.pitch; local muzzleAt = mount.muzzle
  new("Part", "TurretYaw", v, { Position = world(yawAt), CFrame = frame(world(yawAt), heading) })
  new("Part", "TurretPitch", v, { Position = world(pitchAt), CFrame = frame(world(pitchAt), heading) })
  new("Part", "TurretMuzzle", v, { Position = world(muzzleAt), CFrame = frame(world(muzzleAt), heading) })
  -- The driver's own gun (VehicleModels.DriverMounts).
  new("Part", "DriverGunYaw", v, { Position = world(mount.dyaw), CFrame = frame(world(mount.dyaw), heading) })
  new("Part", "DriverGunPitch", v, { Position = world(mount.dpitch), CFrame = frame(world(mount.dpitch), heading) })
  new("Part", "DriverGunMuzzle", v, { Position = world(mount.dmuzzle), CFrame = frame(world(mount.dmuzzle), heading) })
  -- Bodywork right in front of the muzzle, where a shot straight ahead would meet it.
  local hood = new("Part", "Chassis", v, { Position = world(muzzleAt + Vector3.new(0, 0, -2)), radius = 1.5 })
  table.insert(WORLD, hood)
  v.PrimaryPart = hood
  local seat = new("VehicleSeat", "DriverSeat", v, { Position = world(Vector3.new(-1.5, 2.6, 0.5)), CFrame = frame(at, heading) })
  local passenger = new("Seat", "PassengerSeat1", v, { Position = world(Vector3.new(1.5, 2.6, 0.5)) })
  local gunner = new("Seat", "GunnerSeat", v, { Position = world(yawAt + Vector3.new(0, 0, 1.5)) })
  gunner:SetAttribute("Gunner", true)
  table.insert(tagged, v)
  return v, seat, passenger, gunner
end

function makeCharacter(isBot, name, pos)
  local c = new("Model", name, workspace)
  local h = new("Humanoid", "Humanoid", c, { Health = 100 })
  local calls = 0
  h.TakeDamage = function(self, amount) TAKE_DAMAGE = TAKE_DAMAGE + 1 end
  local head = new("Part", "Head", c, { Position = pos, radius = 1.2 })
  table.insert(WORLD, head)
  local token = isBot and { name = name, Character = c, isBot = true } or new("Player", name, nil, { Character = c })
  byCharacter[c] = token
  return token, h, c
end
TAKE_DAMAGE = 0
"""

# Mount geometry per model: the pivots and muzzles of both mounts, model space, read off the REAL
# VehicleModels build (the axis check's mock runs it), so a mount's shape is never restated here.
def mounts_from_source():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import vehicle_models_axis_check as ax
    rt = ax.Runtime(ax.load_sources(ROOT))
    names = {"yaw": "TurretYaw", "pitch": "TurretPitch", "muzzle": "TurretMuzzle",
             "dyaw": "DriverGunYaw", "dpitch": "DriverGunPitch", "dmuzzle": "DriverGunMuzzle"}
    out = {}
    for model in sorted(rt.mounts):
        parts = {q["name"]: q for q in rt.build(model, "drive")}
        out[model] = {key: tuple(parts[name]["pos"]) for key, name in names.items() if name in parts}
    return out, read("ReplicatedStorage/Shared/VehicleModels.lua")


def build_runtime(vw_src, data_src):
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute(MOCKS)
    mounts, models_src = mounts_from_source()
    lua.execute("MOUNTS = {}")
    for model, m in mounts.items():
        lua.execute(
            f'MOUNTS["{model}"] = {{ yaw = Vector3.new({m["yaw"][0]}, {m["yaw"][1]}, {m["yaw"][2]}), '
            f'pitch = Vector3.new({m["pitch"][0]}, {m["pitch"][1]}, {m["pitch"][2]}), '
            f'muzzle = Vector3.new({m["muzzle"][0]}, {m["muzzle"][1]}, {m["muzzle"][2]}), '
            f'dyaw = Vector3.new({m["dyaw"][0]}, {m["dyaw"][1]}, {m["dyaw"][2]}), '
            f'dpitch = Vector3.new({m["dpitch"][0]}, {m["dpitch"][1]}, {m["dpitch"][2]}), '
            f'dmuzzle = Vector3.new({m["dmuzzle"][0]}, {m["dmuzzle"][1]}, {m["dmuzzle"][2]}) }}'
        )
    lua.execute("MODULES.SafeValue = (function() " + luau_to_lua(read("ReplicatedStorage/Shared/SafeValue.lua")) + " end)()")
    lua.execute("MODULES.VehicleWeaponData = (function() " + luau_to_lua(data_src) + " end)()")
    lua.execute(luau_to_lua(shot_budget_source()))
    lua.execute("VW = (function() " + luau_to_lua(vw_src) + " end)()")
    lua.execute("CLOCK = 1000; VW.Now = function() return CLOCK end; VW.Start()")
    return lua, mounts, models_src


SCENARIOS = r"""
local R = {}
math.randomseed(7)
local function reset() LOG = {}; TAKE_DAMAGE = 0; ENABLED = true end
local function count(what) local n = 0; for _, e in ipairs(LOG) do if e.what == what then n = n + 1 end end; return n end
local function last(what) for i = #LOG, 1, -1 do if LOG[i].what == what then return LOG[i] end end end
local function contains(list, x) for _, v in ipairs(list) do if v == x then return true end end return false end
local specs = MODULES.VehicleWeaponData.Weapons

-- A Rotster facing -Z at the origin; its driver, gunner and a passenger, a walker, and victims ahead:
-- one on the roof gun's line, one low on the nose gun's.
local car, seat, pseat, gseat = makeVehicle("Rotster", 0, Vector3.new(0, 0, 0))
local driver, dh = makeCharacter(false, "Driver", Vector3.new(-1.5, 4.5, 0.5))
local gunner, gh = makeCharacter(false, "Gunner", MOUNTS.Rotster.yaw + Vector3.new(0, 1.2, 1.5))
local passenger, ph = makeCharacter(false, "Passenger", Vector3.new(1.5, 4.5, 0.5))
local walker = makeCharacter(false, "Walker", Vector3.new(30, 3, 0))
-- 30 studs out: the roof gun's 1.6 degree cone stays inside a 1.2 stud head, so no shot is left to chance.
local victim = makeCharacter(false, "Victim", Vector3.new(0, 6.9, -30))
local low = makeCharacter(false, "LowVictim", Vector3.new(0, MOUNTS.Rotster.dmuzzle.Y, -34))
local aim = Vector3.new(0, 6.9, -30)
local lowAim = Vector3.new(0, MOUNTS.Rotster.dmuzzle.Y, -34)
seat:Sit(dh); pseat:Sit(ph)

-- A lone driver: the driving seat works the driver's gun, never the turret (the gun's seat is empty).
reset(); CLOCK = 900
local okd = VW.Fire(driver, lowAim)
local dd = last("damage")
R.driver_fires_driver_gun = okd == true and dd ~= nil and dd.weaponId == "Rotster Nose Gun" and dd.victim.Character.Name == "LowVictim"
R.lone_driver_not_turret = car:GetAttribute("WeaponAmmo") == nil and car:GetAttribute("DriverGunAmmo") ~= nil
local dshot = last("shot")
R.driver_shot_from_its_muzzle = dshot ~= nil and (dshot.origin - MOUNTS.Rotster.dmuzzle).Magnitude < 0.05
-- The driver's gun's arc (20 degrees): aimed square to the side it stops at the edge.
reset(); CLOCK = 950
VW.Fire(driver, Vector3.new(-60, MOUNTS.Rotster.dmuzzle.Y, 0))
R.driver_yaw_clamp = math.abs((car:GetAttribute("DriverAimYaw") or 0) - 20) < 0.01

-- The gunner works the turret.
gseat:Sit(gh)
reset(); CLOCK = 1000
local ok, why = VW.Fire(gunner, aim)
local dmg = last("damage")
R.gunner_fires = ok == true
R.hitscan_through_dealdamage = dmg ~= nil and dmg.attacker == gunner and dmg.victim ~= nil and dmg.victim.Character ~= nil
  and dmg.victim.Character.Name == "Victim" and dmg.weaponId == "Rotster Roof Gun" and TAKE_DAMAGE == 0
-- The hood sits right in the line of fire and the riders beside it: neither may stop the shot.
R.self_excluded_bullet = dmg ~= nil and dmg.victim.Character.Name == "Victim"
local shot = last("shot")
R.shot_broadcast_from_muzzle = shot ~= nil and shot.shooter == nil and (shot.origin - MOUNTS.Rotster.muzzle).Magnitude < 0.05

reset(); CLOCK = 2000
R.passenger_refused = select(2, VW.Fire(passenger, aim)) == "not driving" and count("damage") == 0
R.walker_refused = select(2, VW.Fire(walker, aim)) == "not driving"
-- A stale SeatPart: the humanoid thinks it is seated, the seat says someone else is.
local stale, sh = makeCharacter(false, "Stale", Vector3.new(-1.5, 4.5, 0.5))
sh.SeatPart = gseat
R.stale_seat_refused = select(2, VW.Fire(stale, aim)) == "not driving"

-- Lobby: combat off.
reset(); ENABLED = false; CLOCK = 3000
R.lobby_refused = select(2, VW.Fire(gunner, aim)) == "disabled" and count("damage") == 0

-- Fire rate: the budget allows two back-to-back (CombatService's FIRE_BURST), then one per interval.
reset(); CLOCK = 5000
local burst = 0
for _ = 1, 5 do if VW.Fire(gunner, aim) then burst = burst + 1 end end
CLOCK = CLOCK + 0.1
local after = VW.Fire(gunner, aim)
R.fire_rate = burst == 2 and after == true and select(2, VW.Fire(gunner, aim)) == "rate"

-- Magazine: 40 rounds at the full rate, then dry (the gaps are inside the recharge delay).
reset(); CLOCK = 10000
local spec = specs.RotsterRoofGun
local fired, firedAt = 0, nil
for _ = 1, spec.magazine + 3 do
  CLOCK = CLOCK + 1 / spec.fireRate
  if VW.Fire(gunner, aim) then fired = fired + 1; firedAt = CLOCK end
end
CLOCK = CLOCK + 1 / spec.fireRate
local _, dryWhy = VW.Fire(gunner, aim)
R.magazine_limit = fired == spec.magazine and dryWhy == "ammo" and car:GetAttribute("WeaponAmmo") < 1
R.overheats_when_dry = car:GetAttribute("WeaponHot") == true

-- Overheat: run dry, it holds fire until the belt has cooled back to `overheat` of the magazine; one
-- round short of that it is still refused, just past it it fires.
local need = spec.magazine * spec.overheat
CLOCK = firedAt + spec.rechargeDelay + (need - 1) / spec.recharge
local _, hotWhy = VW.Fire(gunner, aim)
CLOCK = firedAt + spec.rechargeDelay + (need + 0.2) / spec.recharge
local cooled = VW.Fire(gunner, aim)
R.overheat_holds = hotWhy == "ammo" and cooled == true and car:GetAttribute("WeaponHot") == nil

-- Recharge: after the delay plus one second, exactly `recharge` rounds are back (worked out here
-- from the spec, and read through AmmoOf, the count bots see).
reset(); CLOCK = 15000
local nose = specs.RotsterNoseGun
local nfired, nAt = 0, nil
for _ = 1, 20 do
  CLOCK = CLOCK + 1 / nose.fireRate
  if VW.Fire(driver, lowAim) then nfired = nfired + 1; nAt = CLOCK end
end
local have = nose.magazine - nfired
CLOCK = nAt + nose.rechargeDelay + 1
R.recharge = nfired >= 2 and math.abs(VW.AmmoOf(car, "driver") - (have + nose.recharge)) < 1e-6
RECHARGED = VW.AmmoOf(car, "driver"); RECHARGE_EXPECTED = have + nose.recharge

-- Wrecked vehicles don't fire.
reset(); CLOCK = 20000
car:SetAttribute("Wrecked", true)
R.wrecked_refused = select(2, VW.Fire(gunner, aim)) == "wrecked"
car:SetAttribute("Wrecked", nil)

-- A bullet that strikes another vehicle goes through CombatService.DamageVehicle, with its class.
local other = new("Part", "Chassis", workspace, { Position = Vector3.new(0, 6.9, -20), radius = 2, vehicleOf = "OtherCar" })
table.insert(WORLD, other)
reset(); CLOCK = 21000
VW.Fire(gunner, aim)
local vhit = last("vehicle")
R.vehicle_hit_through_damagevehicle = vhit ~= nil and vhit.model == "OtherCar" and vhit.class == "bullet"
  and vhit.weaponId == "Rotster Roof Gun" and count("damage") == 0
other.radius = nil

-- A barrel pushed into a wall fires into the wall: the shot leaves where the barrel meets it.
local wall = new("Part", "Wall", workspace, { Position = MOUNTS.Rotster.muzzle + Vector3.new(0, 0, 1.2), radius = 0.5, CanCollide = true })
table.insert(WORLD, wall)
reset(); CLOCK = 22000
VW.Fire(gunner, aim)
local blocked = last("shot")
R.muzzle_blocked = blocked ~= nil and (blocked.origin - MOUNTS.Rotster.muzzle).Magnitude > 0.5 and count("damage") == 0
wall.radius = nil

-- A bot gunner on the van's mortar and a bot at its wheel: the same function, the same checks.
local van, vseat, vpseat, vgseat = makeVehicle("SahurVan", math.rad(90), Vector3.new(200, 0, 0))
local bot, bh = makeCharacter(true, "BotGunner", Vector3.new(200, 9.5, -6.5))
local botDriver, bdh = makeCharacter(true, "BotDriver", Vector3.new(200, 4.5, 1.5))
local botRider, brh = makeCharacter(true, "BotRider", Vector3.new(200, 4.5, -1.5))
vgseat:Sit(bh); vseat:Sit(bdh); vpseat:Sit(brh)
reset(); CLOCK = 30000
-- The van faces world -X (heading +90). Aim at a point far ahead of it and a little below level.
local ok2 = VW.Fire(bot, Vector3.new(100, 0, 0))
local round = last("round")
R.bot_gunner_fires = ok2 == true
R.explosive_through_launch = round ~= nil and round.owner == bot and round.def.projectile == "grenade"
  and round.def.id == "Sahur Van Mortar" and count("damage") == 0
R.bot_passenger_refused = select(2, VW.Fire(botRider, Vector3.new(100, 0, 0))) == "not driving"
-- Round flight filter: the vehicle and every rider, alongside the owner the launcher path adds itself.
R.self_excluded_round = round ~= nil and contains(round.filter, van) and contains(round.filter, bot.Character)
  and contains(round.filter, botRider.Character) and contains(round.filter, botDriver.Character)
-- Mortar pitch floor (10 deg): aimed below level, it still leaves at +10, and toward the van's front (-X).
R.pitch_clamp = round ~= nil and math.abs(van:GetAttribute("AimPitch") - 10) < 0.01
  and round.direction.X < -0.9 and math.abs(math.deg(math.asin(round.direction.Y)) - 10) < 0.6
reset(); CLOCK = 30500
local okb = VW.Fire(botDriver, Vector3.new(100, 2, 0))
local bd = last("shot")
local vanMuzzle = Vector3.new(200, 0, 0) + frame(Vector3.new(), math.rad(90)):VectorToWorldSpace(MOUNTS.SahurVan.dmuzzle)
R.bot_driver_fires_driver_gun = okb == true and count("round") == 0 and bd ~= nil and (bd.origin - vanMuzzle).Magnitude < 0.05

-- The rocket launcher's front-arc floor (4 deg inside 40 of ahead): aimed low straight ahead, it
-- leaves at 4 up; turned 90 degrees to the side it may go down to its -8.
local ranger, rseat, _, rgseat = makeVehicle("CrocodiloRanger", 0, Vector3.new(-200, 0, 0))
local rg, rgh = makeCharacter(false, "RangerGunner", Vector3.new(-200, 8, 5))
rgseat:Sit(rgh)
reset(); CLOCK = 40000
VW.Fire(rg, Vector3.new(-200, 0, -60))
local front = ranger:GetAttribute("AimPitch")
CLOCK = CLOCK + 1
VW.Fire(rg, Vector3.new(-260, 0, MOUNTS.CrocodiloRanger.yaw.Z))
local side = ranger:GetAttribute("AimPitch")
R.front_guard = front ~= nil and side ~= nil and math.abs(front - 4) < 0.01 and side < -3
-- A magazine with no overheat to fall back on: four rockets at the full rate, and the fifth refused.
reset(); CLOCK = 45000
local pod = specs.RangerRocketPod
local rockets = 0
for _ = 1, pod.magazine + 1 do
  CLOCK = CLOCK + 1 / pod.fireRate
  if VW.Fire(rg, Vector3.new(-260, 0, MOUNTS.CrocodiloRanger.yaw.Z)) then rockets = rockets + 1 end
end
R.magazine_limit = R.magazine_limit and rockets == pod.magazine

-- The remote path: a client's fire reaches the same function.
reset(); CLOCK = 50000
for _, fn in ipairs(REMOTES.VehicleWeaponFire.OnServerEvent.fns) do fn(gunner, aim) end
R.remote_fires = count("damage") == 1
for _, fn in ipairs(REMOTES.VehicleWeaponFire.OnServerEvent.fns) do fn(gunner, Vector3.new(0/0, 0, 0)) end
R.remote_rejects_nan = count("damage") == 1 and count("shot") == 1
return R
"""

CHECKS = [
    "driver_fires_driver_gun", "lone_driver_not_turret", "driver_shot_from_its_muzzle", "driver_yaw_clamp",
    "gunner_fires", "hitscan_through_dealdamage", "self_excluded_bullet", "shot_broadcast_from_muzzle",
    "passenger_refused", "walker_refused", "stale_seat_refused", "lobby_refused", "fire_rate",
    "magazine_limit", "overheats_when_dry", "overheat_holds", "recharge", "wrecked_refused",
    "vehicle_hit_through_damagevehicle", "muzzle_blocked", "bot_gunner_fires", "explosive_through_launch",
    "bot_passenger_refused", "self_excluded_round", "pitch_clamp", "bot_driver_fires_driver_gun",
    "front_guard", "remote_fires", "remote_rejects_nan",
]


def run(vw_src, data_src):
    lua, mounts, models_src = build_runtime(vw_src, data_src)
    results = lua.execute(SCENARIOS)
    out = {name: bool(results[name]) for name in CHECKS}
    # Data agreement: mounts and weapons name the same models, and no bike is armed.
    def table_keys(name):
        return set(re.findall(r"^\t(\w+) = \"\w+\",$", re.search(r"\nVehicleWeaponData\." + name + r" = \{(.*?)\n\}", data_src, re.S).group(1), re.M))
    weapons, drivers = table_keys("ByModel"), table_keys("DriverByModel")
    bikes = set(re.findall(r"VehicleModels\.Models\.(\w+) = \{\n\tkind = \"bike\"", models_src))
    out["mounts_match_weapons"] = weapons == set(mounts) and len(weapons) >= 5
    out["driver_guns_match"] = drivers == {m for m, g in mounts.items() if "dyaw" in g} and drivers == weapons
    out["no_bike_armed"] = not (weapons & bikes) and len(bikes) >= 1
    return out, len(bikes), len(mounts)


FAULTS = [
    ("VW", "seat.Occupant ~= humanoid", "false", "stale_seat_refused", "seat check ignores who the seat holds"),
    ("VW", 'elseif seat:IsA("VehicleSeat") then', "elseif true then", "passenger_refused", "any seat works the driver's gun"),
    ("VW", "if seat == VehicleWeapons.GunnerSeatOf(vehicle) then", 'if seat == VehicleWeapons.GunnerSeatOf(vehicle) or seat:IsA("VehicleSeat") then', "driver_fires_driver_gun", "a lone driver works the turret again"),
    ("VW", "if credit < 1 then", "if credit < -1 then", "fire_rate", "shot budget not enforced"),
    ("DATA", "if ammo < 1 then", "if ammo < -1000 then", "magazine_limit", "magazine not enforced"),
    ("DATA", "ammo + idle * spec.recharge", "ammo", "recharge", "magazine never recharges"),
    ("DATA", "if hot and spec.overheat and ammo < spec.magazine * spec.overheat then", "if false then", "overheat_holds", "an overheated belt fires again at once"),
    ("DATA", "\tyaw = math.clamp(yaw, -yawLimit, yawLimit)\n\tpitch = math.clamp(pitch, VehicleWeaponData.PitchFloor(spec, yaw), math.rad(spec.pitchMax))\n\tlocal origin", "\tpitch = math.clamp(pitch, VehicleWeaponData.PitchFloor(spec, yaw), math.rad(spec.pitchMax))\n\tlocal origin", "driver_yaw_clamp", "yaw arc not clamped"),
    ("DATA", "\tpitch = math.clamp(pitch, VehicleWeaponData.PitchFloor(spec, yaw), math.rad(spec.pitchMax))\n\tlocal origin", "\tlocal origin", "pitch_clamp", "pitch not clamped"),
    ("DATA", "if guard and math.abs(yaw) < math.rad(guard.arc) then", "if false then", "front_guard", "the launcher fires into its own cab"),
    ("VW", "local list = { vehicle }", "local list = {}", "self_excluded_bullet", "bullet trace hits its own vehicle"),
    ("VW", "table.insert(entry.filter, instance)", "local _ = instance", "self_excluded_round", "round flight hits its own vehicle"),
    ("VW", "CombatService.DealDamage(token, victim, amount, spec.id, headshot)", "Combatants.GetHumanoid(victim):TakeDamage(amount)", "hitscan_through_dealdamage", "bullet damage bypasses CombatService.DealDamage"),
    ("VW", "local struck = CombatService.VehicleFromPart and CombatService.VehicleFromPart(part)", "local struck = nil", "vehicle_hit_through_damagevehicle", "a bullet goes through the car it hits"),
    ("VW", "origin = clearMuzzle(token, vehicle, pivotWorld, origin)", "origin = origin", "muzzle_blocked", "a barrel in a wall fires through it"),
    ("VW", "pcall(CombatService.LaunchProjectile, token,", "pcall(CombatService.DealDamage, token,", "explosive_through_launch", "rounds bypass ProjectileService's launcher path"),
    ("VW", "if not CombatService.IsEnabled() then", "if false then", "lobby_refused", "fires in the lobby"),
    ("VW", "if not SafeValue.Vector3(aimPoint) then\n\t\treturn false, \"aim\"", "if false then\n\t\treturn false, \"aim\"", "remote_rejects_nan", "NaN aim accepted"),
    ("VW", 'if vehicle:GetAttribute("Wrecked") then', "if false then", "wrecked_refused", "a wreck still fires"),
]


def main():
    vw_src = read("ServerScriptService/Modules/VehicleWeapons.lua")
    data_src = read("ReplicatedStorage/Shared/VehicleWeaponData.lua")
    results, bikes, mounts = run(vw_src, data_src)
    failed = [k for k, v in results.items() if not v]
    for k, v in results.items():
        print(f"  {'PASS' if v else 'FAIL'}  {k}")
    print(f"clean run: {len(results) - len(failed)}/{len(results)} checks pass ({mounts} armed models, {bikes} bikes examined)")

    caught = 0
    for target, before, after, expect, label in FAULTS:
        src = vw_src if target == "VW" else data_src
        if src.count(before) != 1:
            print(f"  FAULT NOT PLANTED ({label}): text not found once")
            continue
        planted = src.replace(before, after)
        try:
            fr, _, _ = run(planted if target == "VW" else vw_src, planted if target == "DATA" else data_src)
            hit = not fr[expect]
            others = [k for k, v in fr.items() if not v]
        except Exception as err:  # an error is a failed check, not a pass
            hit, others = True, [f"error: {str(err).splitlines()[0]}"]
        caught += hit
        print(f"  {'caught' if hit else 'MISSED'}  {label}  -> failing: {', '.join(others) or 'none'}")
    print(f"planted faults: {caught}/{len(FAULTS)} caught")
    ok = not failed and caught == len(FAULTS)
    print("vehicle weapons check: " + ("OK" if ok else "FAILED"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
