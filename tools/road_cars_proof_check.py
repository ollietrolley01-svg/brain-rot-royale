"""#51 proof: can every road car on a generated map be shot apart, through the game's real damage paths?

Builds whole maps with the REAL MapGenerator.Build (the world of tools/car_placement_map.py: real
MapGenerator, MapDecor, MapWilds, ParkingLots, VehicleModels ..., the ground a height function), then
swaps the REAL DestructibleService, CombatService and ProjectileService (with the real WeaponData and
every pack, Ballistics, ItemData, VehicleCover, VehicleArmor, MatchConfig, RateLimit, CollapseService)
into the same Lua runtime and shoots at every road car the map made.

What a "road car" is on main, and what the harness finds of each kind (the census):
  kerb       MapDecor.Town: a static real design (VehicleModels.BuildStatic) at a street's kerb
  driveway   MapDecor.Driveways: the same, nose-in beside a house
  bay        MapDecor.ParkBays: the same, in a car park bay (carries ParkStyle)
  drivable   VehicleService.Create (lot bays via ParkInTowns, or the country verge): a real vehicle
  wreck      MapWilds' burnt-out car (the "Wreck:W<n>" group), in the wilds, not on a road
(Team modes' battleground adds four more wrecks, "Wreck:bg<n>"; TeamBattleground is not built here.)

Checks, per car, through the real entry points:
  A  routing: every part a ray can hit resolves (DestructibleService.KeyOf / FromPart) to the car's one
     pool; the pool starts at the car's DestructibleHealth (240); parts that collide but can't be hit
     are counted
  B  bullets: CombatService.Fire (the server's own shot, firePellet -> DestructibleFromPart ->
     DamageDestructible) with the Crocodilo Rifle until the car is gone: every hit deals the gun's own
     damage, the car goes in exactly ceil(240 / damage) hits, and every part and the Model go with it
  C  no fading: 60 s of server time after the first hit, the pool's health is where the hit left it
  D  after: no pool entry outlives the car (DestructibleService's own `damaged` table, read through
     debug.getupvalue), a stale part deals 0, and a shot through where the car stood hurts nothing of it
  E  blasts (a sample per map): the Cappuccina rocket through ProjectileService.FireWeapon + Step until it
     bursts; a frag (CookedCoconut) through ProjectileService.Throw; each blast takes at most its
     wallDamage off a car, once
  F  drivables: with VehicleMaxHealth set as VehicleService.Create sets it (VehicleService.lua:1297), no
     part of one is DestructibleService's, anchored (the rest hold) or not, and a rocket-sized blast
     breaks none of it
  W  wilds wrecks: every hittable part routes to its one group pool, and bullets take it down whole

Plus, printed: the shotgun (every pellet), the sniper and the noclip AdminOverride on one car per map,
and the barrel's blast from HazardService's own numbers (its call is stood in: HazardService isn't loaded).

    python tools/road_cars_proof_check.py            5 maps, seed 1
    python tools/road_cars_proof_check.py --plant    the planted faults, on one map; each must be caught

Not covered: anything on a client (the break's debris, the cracks), a live server, lag compensation (no
rewind here), the navmesh (PathfindingService), and how it looks. Cylinders (wheels) are boxes to the
rays here, so a shot that grazes a tyre's corner counts as a hit that would miss in Roblox.
"""

import math
import re
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import car_placement_map as cpm  # noqa: E402
from car_placement_luau import luau_to_lua  # noqa: E402

try:
    from lupa import LuaRuntime
except ImportError:
    sys.exit("road_cars_proof_check: needs lupa (pip install lupa)")

# The damage side, loaded for real after the map is built.
DAMAGE_SERVER = ["DestructibleService", "CombatService", "ProjectileService", "RateLimit", "CollapseService"]
DAMAGE_SHARED = ["WeaponData", "ArsenalExpansion", "CreativeArsenal", "CreativeRounds", "WorkshopArsenal", "ItemData", "Ballistics",
                 "VehicleCover", "VehicleArmor", "MatchConfig", "MovementConfig"]

# Stand-ins for what CombatService and ProjectileService ask of the rest of the server: one shooter, a
# loadout that always has a round, and the present-time ray (no rewind).
STANDINS = r"""
local standins, mock, H = ...
standins.Remotes = function() return mock.RemotesModule end
standins.QuestService = function() return setmetatable({}, { __index = function() return function() end end }) end
standins.Combatants = function()
	local C = {}
	function C.FromCharacter(model) return H.shooter and model == H.shooter.Character and H.shooter or nil end
	function C.IsAlive(token) return token ~= nil and token == H.shooter end
	function C.GetCharacter(token) return type(token) == "table" and token.Character or nil end
	function C.GetRoot(token) local c = C.GetCharacter(token) return c and c:FindFirstChild("HumanoidRootPart") end
	function C.GetHumanoid(token) local c = C.GetCharacter(token) return c and c:FindFirstChild("Humanoid") end
	function C.IsPlayer(token) return token ~= nil and token == H.shooter end
	function C.IsBot() return false end
	function C.GetName(token) return type(token) == "table" and token.Name or nil end
	function C.Exists(token) return token ~= nil end
	function C.All() local out = {} if H.shooter then out[H.shooter.Character] = H.shooter end return out end
	return C
end
standins.LagCompensation = function()
	return {
		RewindTime = function() return nil end,
		Now = function() return mock.clock end,
		Raycast = function(origin, vector, params) return workspace:Raycast(origin, vector, params) end,
	}
end
standins.WeaponService = function()
	local W = { Shields = {} }
	function W.Get() return H.loadout end
	function W.GetEquipped() return H.def end
	function W.IsReady() return true end
	function W.ConsumeAmmo() return true end
	function W.AbsorbDamage(_, amount) return amount, 0 end
	function W.StartUse() return false end
	return W
end
"""

# After the build: the real damage modules replace the stand-ins, and the harness's own tools.
HARNESS = r"""
local mock, standins, map, cfg = ...
local H = HARNESS_STATE
standins.DestructibleService = nil
mock.modules.DestructibleService = nil
standins.MovementService = function() return { Launch = function() end } end
mock.modules.MovementService = nil
game:GetService("RunService").IsRunning = function() return true end
local players = game:GetService("Players")
for _, name in ipairs({ "PlayerAdded", "PlayerRemoving" }) do players[name] = players[name] or mock.signal() end
workspace.GetServerTimeNow = function() return mock.clock end
if not workspace.Gravity then workspace.Gravity = 196.2 end
local instanceMeta = getmetatable(Instance.new("Part"))
instanceMeta.GetAttributeChangedSignal = instanceMeta.GetAttributeChangedSignal or function() return mock.signal() end
instanceMeta.FindFirstAncestorOfClass = instanceMeta.FindFirstAncestorOfClass or function(inst, class)
	local node = inst.Parent
	while node do
		if node.ClassName == class then return node end
		node = node.Parent
	end
	return nil
end
instanceMeta.FindFirstAncestorWhichIsA = instanceMeta.FindFirstAncestorWhichIsA or function(inst, class)
	local node = inst.Parent
	while node do
		if node:IsA(class) then return node end
		node = node.Parent
	end
	return nil
end
local DS = require("DestructibleService")
local CS = require("CombatService")
local PS = require("ProjectileService")
local WeaponData = require("WeaponData")
local VehicleArmor = require("VehicleArmor")
CS.SetEnabled(true)
PS.SetAutoStep(false)
H.DS, H.CS, H.PS = DS, CS, PS

-- DestructibleService's pool table, read where HealthOf reads it (for the leak check).
local damaged
for i = 1, 40 do
	local name, value = debug.getupvalue(DS.HealthOf, i)
	if not name then break end
	if name == "damaged" then damaged = value end
end
assert(damaged, "DestructibleService.HealthOf no longer holds `damaged`: update the leak check")

-- Every DamageDestructible call, recorded on the way through (the behaviour is untouched).
local calls = {}
local realDamageDestructible = CS.DamageDestructible
CS.DamageDestructible = function(token, part, amount, from, at, normal)
	local dealt = realDamageDestructible(token, part, amount, from, at, normal)
	table.insert(calls, { part = part, amount = amount, dealt = dealt })
	return dealt
end

--------------------------------------------------------------------------------
-- Rays against the map's parts (turned boxes) and the ground, for the shots and the rounds
--------------------------------------------------------------------------------
local all = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") then
		local lo, hi = mock.aabb(d.CFrame, d.Size)
		table.insert(all, { part = d, lo = lo, hi = hi })
	end
end
H.partCount = #all
local cand = all
-- Only what stands within `reach` of `centre` is looked at (speed); the shooter is always looked at.
local function region(centre, reach)
	cand = {}
	for _, e in ipairs(all) do
		if e.part.Parent and e.hi.X >= centre.X - reach and e.lo.X <= centre.X + reach
			and e.hi.Z >= centre.Z - reach and e.lo.Z <= centre.Z + reach then
			table.insert(cand, e)
		end
	end
end

local function inside(inst, set)
	local node = inst
	while node do
		if set[node] then return true end
		node = node.Parent
	end
	return false
end
local function filterOf(params)
	local set, include = {}, false
	if params then
		for _, inst in ipairs(params.FilterDescendantsInstances or {}) do set[inst] = true end
		include = params.FilterType == Enum.RaycastFilterType.Include
	end
	return set, include
end
-- Slab test of a ray against a turned box grown by `grow`: (t in 0..1, world normal) or nil. A ray that
-- starts inside the box doesn't hit it, as in Roblox.
local function rayBox(origin, dir, part, grow)
	local c = part.CFrame
	local h = part.Size / 2
	local o = c:PointToObjectSpace(origin)
	local d = c:VectorToObjectSpace(dir)
	local t0, t1, axis, sign = -math.huge, math.huge, nil, 0
	for _, k in ipairs({ "X", "Y", "Z" }) do
		local ok, dk, hk = o[k], d[k], h[k] + grow
		if math.abs(dk) < 1e-12 then
			if ok < -hk or ok > hk then return nil end
		else
			local a, b = (-hk - ok) / dk, (hk - ok) / dk
			local s = -1
			if a > b then a, b, s = b, a, 1 end
			if a > t0 then t0, axis, sign = a, k, s end
			if b < t1 then t1 = b end
			if t0 > t1 then return nil end
		end
	end
	if t0 < 0 or t0 > 1 or not axis then return nil end
	local n = Vector3.new(axis == "X" and sign or 0, axis == "Y" and sign or 0, axis == "Z" and sign or 0)
	return t0, c:VectorToWorldSpace(n)
end
local function cast(origin, dir, params, grow)
	local set, include = filterOf(params)
	local best, bestT, bestN = nil, math.huge, nil
	local function try(part)
		if part.Parent and part.CanQuery and (include and inside(part, set) or (not include and not inside(part, set))) then
			local t, n = rayBox(origin, dir, part, grow)
			if t and t < bestT then best, bestT, bestN = part, t, n end
		end
	end
	for _, e in ipairs(cand) do try(e.part) end
	for _, d in ipairs(H.extra) do if d:IsA("BasePart") then try(d) end end
	-- The ground, marched in 0.5-stud steps along the ray (unless an Include list leaves Terrain out).
	if not include or set[workspace.Terrain] then
		local length = dir.Magnitude
		local steps = math.max(1, math.ceil(length / 0.5))
		for i = 1, steps do
			local t = i / steps
			if t >= bestT then break end
			local p = origin + dir * t
			if p.Y <= GROUND(p.X, p.Z) then
				best, bestT, bestN = workspace.Terrain, t, Vector3.new(0, 1, 0)
				break
			end
		end
	end
	if not best then return nil end
	return { Instance = best, Position = origin + dir * bestT, Normal = bestN, Distance = dir.Magnitude * bestT,
		Material = best == workspace.Terrain and Enum.Material.Grass or best.Material }
end
mock.raycast = function(origin, direction, params) return cast(origin, direction, params, 0) end
workspace.Spherecast = function(_, origin, radius, direction, params) return cast(origin, direction, params, radius) end
workspace.Shapecast = function(_, part, direction, params) return cast(part.Position, direction, params, part.Size.X / 2) end
local realBounds = workspace.GetPartBoundsInRadius
workspace.GetPartBoundsInRadius = function(ws, centre, radius, params)
	local found = {}
	local set, include = filterOf(params)
	for _, e in ipairs(cand) do
		local d = e.part
		if d.Parent and d.CanQuery and (not include or inside(d, set)) then
			local l = d.CFrame:PointToObjectSpace(centre)
			local h = d.Size / 2
			local q = Vector3.new(math.clamp(l.X, -h.X, h.X), math.clamp(l.Y, -h.Y, h.Y), math.clamp(l.Z, -h.Z, h.Z))
			if (q - l).Magnitude <= radius then table.insert(found, d) end
		end
	end
	-- Tiles a blast cut from a big part (DestructibleService.Subdivide) are new parts: looked at too.
	for _, d in ipairs(map:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("Subdivided") and d.CanQuery then
			local l = d.CFrame:PointToObjectSpace(centre)
			local h = d.Size / 2
			local q = Vector3.new(math.clamp(l.X, -h.X, h.X), math.clamp(l.Y, -h.Y, h.Y), math.clamp(l.Z, -h.Z, h.Z))
			if (q - l).Magnitude <= radius and not table.find(found, d) then table.insert(found, d) end
		end
	end
	return found
end

--------------------------------------------------------------------------------
-- The shooter: one player with a head, a root and a humanoid, outside the Map
--------------------------------------------------------------------------------
H.extra = {}
local shooterModel = Instance.new("Model")
shooterModel.Name = "Shooter"
shooterModel.Parent = workspace
local function part(name, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Anchored = true
	p.Parent = shooterModel
	table.insert(H.extra, p)
	return p
end
local head = part("Head", Vector3.new(1, 1, 1))
local root = part("HumanoidRootPart", Vector3.new(2, 2, 1))
local humanoid = Instance.new("Humanoid")
humanoid.Health = 100
humanoid.MaxHealth = 100
humanoid.Parent = shooterModel
H.shooter = { Character = shooterModel, Name = "Tester", UserId = 1 }
H.loadout = { fireCredit = 2, lastShotAt = -1e9 }
CS.SetAiming(H.shooter, true)

local function standAt(position)
	head.CFrame = CFrame.new(position)
	root.CFrame = CFrame.new(position - Vector3.new(0, 1.5, 0))
end
local function settle(seconds)
	mock.advance(seconds or 0.05, 0.05)
end

--------------------------------------------------------------------------------
-- The census: every road car the build made, by kind
--------------------------------------------------------------------------------
local function within(part, point, margin)
	local l = part.CFrame:PointToObjectSpace(point)
	return math.abs(l.X) <= part.Size.X / 2 + margin and math.abs(l.Z) <= part.Size.Z / 2 + margin
end
local driveways, lots = {}, {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") and d.Name == "Driveway" then table.insert(driveways, d) end
	if d:IsA("BasePart") and d.Name == "LotSurface" then table.insert(lots, d) end
end
local cars = {}
local wreckParts = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("Model") and d.Name == "ParkedCar" then
		local at = d:GetAttribute("HarnessCF")
		local kind = "kerb"
		if d:GetAttribute("ParkStyle") then
			kind = "bay"
		else
			for _, w in ipairs(driveways) do
				if within(w, at.Position, 0.5) then kind = "driveway" break end
			end
		end
		table.insert(cars, { model = d, kind = kind, frame = at, design = d:GetAttribute("HarnessModel") })
	elseif d:IsA("Model") and d:GetAttribute("HarnessKind") then
		local pivot = d:GetPivot()
		local kind = "drivable-verge"
		for _, l in ipairs(lots) do
			if within(l, pivot.Position, 2) then kind = "drivable-lot" break end
		end
		table.insert(cars, { model = d, kind = kind, frame = pivot, design = d:GetAttribute("HarnessModel"),
			vehicleKind = d:GetAttribute("HarnessKind") })
	elseif d:IsA("BasePart") then
		local tag = d:GetAttribute("Destructible")
		if type(tag) == "string" and string.sub(tag, 1, 6) == "Wreck:" then
			wreckParts[tag] = wreckParts[tag] or {}
			table.insert(wreckParts[tag], d)
		end
	end
end
local wrecks = {}
for tag, parts in pairs(wreckParts) do table.insert(wrecks, { tag = tag, parts = parts, kind = "wreck" }) end
table.sort(wrecks, function(a, b) return a.tag < b.tag end)

local function boxOf(parts)
	local lo, hi
	for _, p in ipairs(parts) do
		if p.Parent and p.CanQuery then
			local a, b = mock.aabb(p.CFrame, p.Size)
			lo = lo and lo:Min(a) or a
			hi = hi and hi:Max(b) or b
		end
	end
	if not lo then return nil end
	return (lo + hi) / 2, hi - lo
end
local function partsOf(target)
	if target.list then return target.list end
	if target.model then
		local out = {}
		for _, d in ipairs(target.model:GetDescendants()) do if d:IsA("BasePart") then table.insert(out, d) end end
		target.list = out
		return out
	end
	return target.parts
end
-- Whether `inst` is one of the target's parts (as built: a part stays one after the car breaks).
local function isTarget(target, inst)
	if not inst or inst == workspace.Terrain then return false end
	if not target.members then
		target.members = {}
		for _, p in ipairs(partsOf(target)) do target.members[p] = true end
	end
	return target.members[inst] == true
end
local function gone(target)
	if target.model then return target.model.Parent == nil end
	for _, p in ipairs(target.parts) do if p.Parent then return false end end
	return true
end
local function poolKey(target)
	return target.model or target.tag
end

-- A: routing. Every part a ray can hit (CanQuery) must resolve to the one pool and be worth a shot.
local function routing(target)
	local r = { parts = 0, hittable = 0, routed = 0, collideOnly = 0, trim = 0, stray = {}, wrongKey = {} }
	local want = poolKey(target)
	for _, p in ipairs(partsOf(target)) do
		r.parts += 1
		if p.CanQuery then
			r.hittable += 1
			local key = DS.KeyOf(p)
			local from = DS.FromPart(p)
			if key == want and from == p then
				r.routed += 1
			else
				table.insert(r.stray, p.Name .. (p.Anchored and "" or "(unanchored)") .. "->" .. tostring(key == nil and "nothing" or (key == p and "itself" or key)))
			end
		elseif p.CanCollide then
			r.collideOnly += 1
		else
			r.trim += 1
		end
	end
	return r
end

-- Fires `weaponId` through the real CombatService.Fire from `from` at `aim`, once. Returns the calls made.
local function fire(weaponId, from, aim)
	H.def = WeaponData.Get(weaponId)
	H.loadout.fireCredit, H.loadout.lastShotAt = 2, -1e9
	standAt(from)
	calls = {}
	CS.Fire(H.shooter, aim)
	settle()
	return calls
end

-- A standing spot straight above the car with a clear line to it (roofs of trees or carports aside),
-- or one of four spots to the side at waist height. Returns (from, aim) or nil.
local function lineTo(target, sideways)
	local centre, size = boxOf(partsOf(target))
	if not centre then return nil end
	local tries = {}
	if sideways then
		for _, dir in ipairs({ Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }) do
			table.insert(tries, centre + dir * (math.max(size.X, size.Z) / 2 + 9) + Vector3.new(0, -size.Y * 0.15, 0))
		end
	else
		for _, off in ipairs({ Vector3.new(0, 0, 0), Vector3.new(1, 0, 0.5), Vector3.new(-1, 0, -0.5) }) do
			table.insert(tries, centre + off + Vector3.new(0, size.Y / 2 + 18, 0))
		end
	end
	for _, from in ipairs(tries) do
		local aim = sideways and Vector3.new(centre.X, from.Y, centre.Z) or centre
		standAt(from)
		local hit = cast(from, (aim - from).Unit * 60, { FilterType = Enum.RaycastFilterType.Exclude,
			FilterDescendantsInstances = { shooterModel } }, 0)
		if hit and isTarget(target, hit.Instance) then return from, aim end
	end
	return nil
end

local function healthOf(target)
	for _, p in ipairs(partsOf(target)) do
		if p.Parent and p.CanQuery then
			local h, m = DS.HealthOf(p)
			if h then return h, m end
		end
	end
	return nil
end
local function leftovers(target)
	local n = 0
	for _, p in ipairs(partsOf(target)) do if p.Parent then n += 1 end end
	return n
end
local function staleEntries()
	local n = 0
	for key, entry in pairs(damaged) do
		local anchor = type(key) == "string" and entry.members[1] or key
		if anchor and anchor.Parent == nil then n += 1 end
	end
	return n
end

-- B + C + D: bullets from above until it's gone.
local function shootDown(target, weaponId, maxShots, regen)
	local out = { shots = 0, hits = 0, onTarget = 0, dealt = {}, max = nil, fade = nil, other = 0 }
	local from, aim = lineTo(target, false)
	if not from then out.blocked = true return out end
	while not gone(target) and out.shots < maxShots do
		local got = fire(weaponId, from, aim)
		out.shots += 1
		for _, c in ipairs(got) do
			if isTarget(target, c.part) then
				out.onTarget += 1
				table.insert(out.dealt, c.dealt)
			else
				out.other += 1
			end
		end
		if out.shots == 1 then
			out.afterFirst, out.max = healthOf(target)
			if regen and out.afterFirst then
				settle(regen)
				local later = healthOf(target)
				out.fade = later and (later - out.afterFirst) or nil
			end
		end
	end
	out.gone = gone(target)
	out.leftovers = leftovers(target)
	-- D: one more shot through where it stood; nothing of the car may take it.
	if out.gone then
		local got = fire(weaponId, from, aim)
		out.after = 0
		for _, c in ipairs(got) do if isTarget(target, c.part) then out.after += 1 end end
		local stale = partsOf(target)[1]
		out.staleDealt = stale and DS.Damage(stale, 100, nil, from) or 0
	end
	return out
end

-- E: rounds and throws, stepped through ProjectileService until each has gone off.
local detonations = mock.remote("ProjectileFx")
local function countDetonations()
	local n = 0
	for _, f in ipairs(detonations.fired) do if f[1] == "detonate" then n += 1 end end
	return n
end
local function blastUntilGone(target, how, maxBlasts)
	local out = { blasts = 0, launched = 0, drops = {}, gone = false }
	local from, aim = lineTo(target, false)
	if not from then out.blocked = true return out end
	while not gone(target) and out.launched < maxBlasts do
		local before = healthOf(target) or out.max
		local _, m = healthOf(target)
		out.max = out.max or m
		local count = countDetonations()
		standAt(from)
		if how == "rocket" then
			PS.FireWeapon(H.shooter, "CappuccinaLauncher", from, aim)
		else
			PS.Throw(H.shooter, how, aim, nil)
		end
		out.launched += 1
		for _ = 1, 200 do
			PS.Step(1 / 30)
			settle(1 / 30)
			if countDetonations() > count then break end
		end
		out.blasts += countDetonations() - count
		local after, max = healthOf(target)
		out.max = out.max or max
		local was = before or out.max or cfg.health
		table.insert(out.drops, gone(target) and ("broke from " .. tostring(was)) or (after and (was - after) or 0))
	end
	out.gone = gone(target)
	out.leftovers = leftovers(target)
	return out
end

-- F: a drivable, marked as VehicleService.Create marks it, anchored or not.
local function drivable(target)
	local out = { parts = 0, breakable = 0, anchoredBreakable = 0, broken = 0 }
	local model = target.model
	model:SetAttribute("VehicleMaxHealth", VehicleArmor.HealthOf(target.design, target.vehicleKind))
	local list = partsOf(target)
	for _, p in ipairs(list) do
		out.parts += 1
		if DS.FromPart(p) ~= nil then out.breakable += 1 end
	end
	local was = {}
	for _, p in ipairs(list) do was[p] = p.Anchored p.Anchored = true end
	for _, p in ipairs(list) do
		if DS.FromPart(p) ~= nil then out.anchoredBreakable += 1 end
	end
	local centre = boxOf(list)
	if centre then
		DS.DamageInRadius(centre, 6, 150, H.shooter)
		settle()
	end
	for _, p in ipairs(list) do
		if p.Parent == nil then out.broken += 1 end
		p.Anchored = was[p]
	end
	return out
end

-- One level shot from the side, where a clear line exists: does the first thing it meets take it?
local function sideShot(target, weaponId)
	local from, aim = lineTo(target, true)
	if not from then return nil end
	local got = fire(weaponId, from, aim)
	local first = got[1]
	if first ~= nil and isTarget(target, first.part) then
		return first.dealt > 0, first.dealt
	end
	return false, 0
end
-- What the same design as a drivable takes from `weaponId`'s bullets: VehicleService.DamageVehicle's formula
-- (VehicleService.lua:1167-1170) over the real VehicleArmor and MatchConfig.
local MatchConfig = require("MatchConfig")
local function drivableHits(design, kind, weaponId)
	local def = WeaponData.Get(weaponId)
	local per = def.damage * VehicleArmor.Scale(design, "bullet") * (MatchConfig.CombatDamageScale or 1)
	local health = VehicleArmor.HealthOf(design, kind)
	return math.ceil(health / per - 1e-9), health, per
end
H.sideShot, H.drivableHits, H.scale = sideShot, drivableHits, MatchConfig.CombatDamageScale
H.region, H.cars, H.wrecks, H.routing, H.shootDown, H.blastUntilGone, H.drivable, H.fire, H.lineTo = region, cars, wrecks, routing, shootDown,
	blastUntilGone, drivable, fire, lineTo
H.boxOf, H.partsOf, H.staleEntries, H.gone, H.isTarget, H.healthOf = boxOf, partsOf, staleEntries, gone, isTarget, healthOf
H.damagedCount = function() local n = 0 for _ in pairs(damaged) do n += 1 end return n end
H.weapon = function(id) return WeaponData.Get(id) end
H.centre = function(target) local c = boxOf(partsOf(target)) return c end
return H
"""


def build(map_id, seed, faults=None):
    """A map built by the real MapGenerator, with the real damage side loaded after it. Returns (lua, H, seconds)."""
    faults = faults or {}
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(HERE, "destruct_mocks.lua"), encoding="utf-8") as f:
        mock = lua.execute(f.read())
    sources = {}
    for name in cpm.REAL_MODULES + cpm.REAL_SHARED:
        if name == "MapTerrain":
            src = cpm.terrain_source(faults.get(name))
        else:
            src = cpm.apply(cpm.source_of(name), faults.get(name), name)
            if name == "MapDecor":
                src = cpm.apply(src, cpm.DECOR_PROBE, name)
        sources[name] = luau_to_lua(src)
    for name in DAMAGE_SERVER + DAMAGE_SHARED:
        sources[name] = luau_to_lua(cpm.apply(cpm.source_of(name), faults.get(name), name))
    lua.globals().VEHICLE_SOURCE = luau_to_lua(cpm.vehicle_source(faults.get("VehicleService")))
    standins = lua.execute(cpm.STANDINS)
    lua.execute("HARNESS_STATE = {}")
    lua.execute(STANDINS, standins, mock, lua.globals().HARNESS_STATE)
    lua.execute(cpm.WORLD, mock, lua.table_from(sources), standins)
    lua.execute("math.randomseed(...)", seed)
    started = time.time()
    result = lua.eval("function(mapId) return require('MapGenerator').Build(mapId) end")(map_id)
    seconds = time.time() - started
    H = lua.execute(luau_to_lua(HARNESS), mock, standins, result.map, lua.table_from({"health": 240}))
    return lua, H, seconds


def lua_list(t):
    return [t[i] for i in range(1, len(t) + 1)] if t is not None else []


def ceil_div(a, b):
    return int(math.ceil(a / b - 1e-9))


RIFLE, SHOTGUN, SNIPER, NOCLIP = "CrocodiloRifle", "TralalaShotgun", "LarilaSniper", "AdminOverride"
# Blasts: what the source says each one takes off a wall (Ballistics.Rounds.rocket, Ballistics.Throwables).
BLASTS = [("rocket", "rocket", 150), ("frag", "CookedCoconut", 120), ("sticky", "ClingyCrumpet", 130)]
STATIC_KINDS = ("kerb", "driveway", "bay")
MAPS_DEFAULT = cpm.map_ids()


def hazard_barrel():
    """The barrel's radius and what it hands DamageDestructiblesInRadius, read from HazardService's source."""
    text = cpm.source_of("HazardService")
    radius = float(re.search(r"\nlocal BLAST_RADIUS = ([\d.]+)", text).group(1))
    damage = float(re.search(r"\nlocal BLAST_DAMAGE = ([\d.]+)", text).group(1))
    scale = float(re.search(r"DamageDestructiblesInRadius\(position, radius, baseDamage \* ([\d.]+)", text).group(1))
    return radius, damage * scale


def plain(obj):
    out = {}
    for key in list(obj.keys()):
        value = obj[key]
        out[key] = lua_list(value) if hasattr(value, "keys") else value
    return out


def run_map(map_id, seed, faults=None, out=print):
    """Every road car on one map, through every check. Returns (stats, fails, findings)."""
    lua, H, seconds = build(map_id, seed, faults)
    fails, findings = [], []
    stats = {"map": map_id, "seed": seed, "build": seconds, "parts": H.partCount, "kinds": {}, "static_parts": [],
             "hittable": [], "routed": 0, "hittable_total": 0, "stray": 0, "collide_only": 0, "rifle_hits": [],
             "wreck_hits": [], "blocked": 0, "side": [0, 0], "drivable_parts": 0, "samples": {}, "designs": {},
             "static_shot": 0, "wreck_shot": 0, "blasts": {}, "noclip_per_bullet": None}

    def fail(tag, text):
        fails.append("%s %s seed %d: %s" % (tag, map_id, seed, text))

    cars = lua_list(H.cars)
    wrecks = lua_list(H.wrecks)
    for c in cars:
        stats["kinds"][c.kind] = stats["kinds"].get(c.kind, 0) + 1
    stats["kinds"]["wreck"] = len(wrecks)
    statics = [c for c in cars if c.kind in STATIC_KINDS]
    drivables = [c for c in cars if c.kind.startswith("drivable")]
    rifle = H.weapon(RIFLE).damage

    # A on every static car and wreck, before anything is shot.
    for target in statics + wrecks:
        H.region(H.centre(target), 60)
        r = H.routing(target)
        stray = lua_list(r.stray)
        if target.kind != "wreck":
            stats["static_parts"].append(r.parts)
            stats["hittable"].append(r.hittable)
            stats["designs"][target.design] = stats["designs"].get(target.design, 0) + 1
        stats["hittable_total"] += r.hittable
        stats["routed"] += r.routed
        stats["stray"] += len(stray)
        stats["collide_only"] += r.collideOnly
        if stray:
            fail("A", "%s %s: %d of %d hittable parts don't reach its pool: %s" % (
                target.kind, target.design or target.tag, len(stray), r.hittable, ", ".join(stray[:6])))
        if r.hittable == 0:
            fail("A", "%s %s: nothing on it can be hit" % (target.kind, target.design or target.tag))

    # The sample: one car each for the shotgun, the sniper, the noclip gun, the three blasts and the barrel.
    pool = list(statics)
    def take():
        return pool.pop(0) if pool else None

    for weapon in (SHOTGUN, SNIPER, NOCLIP):
        target = take()
        if not target:
            break
        H.region(H.centre(target), 60)
        o = plain(H.shootDown(target, weapon, 40, None))
        stats["samples"][weapon] = (target.kind, o)
        if o.get("blocked"):
            stats["blocked"] += 1
            continue
        stats["static_shot"] += 1
        if not o["gone"] or o["leftovers"]:
            fail("B", "%s left a %s standing after %d shots (%d parts left)" % (weapon, target.kind, o["shots"], o["leftovers"]))
        elif abs(sum(o["dealt"]) - o["max"]) > 1e-6:
            fail("B", "%s: the %s broke after %.0f of its %.0f" % (weapon, target.kind, sum(o["dealt"]), o["max"]))
        if weapon == NOCLIP and o["shots"]:
            stats["noclip_per_bullet"] = o["onTarget"] / o["shots"]
    for label, how, wall in BLASTS:
        target = take()
        if not target:
            break
        H.region(H.centre(target), 60)
        o = plain(H.blastUntilGone(target, how, 8))
        stats["blasts"][label] = (target.kind, o)
        if o.get("blocked"):
            stats["blocked"] += 1
            continue
        stats["static_shot"] += 1
        for drop in o["drops"]:
            took = float(drop.split()[-1]) if isinstance(drop, str) else drop
            if took > wall + 1e-6:
                fail("E", "one %s took %.1f off a %s (its wallDamage is %d)" % (label, took, target.kind, wall))
        if not o["gone"] or o["leftovers"]:
            fail("E", "%d %ss left a %s standing (%d parts left)" % (o["launched"], label, target.kind, o["leftovers"]))
    barrel = take()
    if barrel:
        radius, amount = hazard_barrel()
        H.region(H.centre(barrel), 60)
        centre = H.centre(barrel)
        n = 0
        while not H.gone(barrel) and n < 10:
            H.DS.DamageInRadius(centre, radius, amount, None)
            n += 1
        stats["blasts"]["barrel"] = (barrel.kind, {"launched": n, "gone": H.gone(barrel), "amount": amount})
        stats["static_shot"] += 1

    # B, C, D: the rifle on every static car left, and on every wreck.
    for target in pool + wrecks:
        # A blast on the car next door can reach this one first (a rocket's reach is half its radius).
        if H.gone(target):
            stats["collateral_gone"] = stats.get("collateral_gone", 0) + 1
            continue
        start = H.healthOf(target)
        start = start[0] if start else None
        if start is not None:
            stats["collateral_hurt"] = stats.get("collateral_hurt", 0) + 1
        H.region(H.centre(target), 60)
        side, pre = H.sideShot(target, RIFLE)
        pre = pre or 0
        if side is not None:
            stats["side"][1] += 1
            stats["side"][0] += 1 if side else 0
            if not side:
                fail("A", "a level shot at a %s %s met it and took nothing" % (target.kind, target.design or target.tag))
        o = plain(H.shootDown(target, RIFLE, 60, 60))
        if o.get("blocked"):
            stats["blocked"] += 1
            continue
        name = "%s %s" % (target.kind, target.design or target.tag)
        if target.kind == "wreck":
            stats["wreck_shot"] += 1
        else:
            stats["static_shot"] += 1
        if not o["gone"] or o["leftovers"]:
            fail("B", "%s stands after %d rifle shots (%d parts left)" % (name, o["shots"], o["leftovers"]))
            continue
        if target.kind != "wreck" and o["max"] != 240:
            fail("A", "%s: its pool is %s, not its DestructibleHealth 240" % (name, o["max"]))
        # Every hit (the level one first, if it had a line) is the gun's own damage, and the pool breaks
        # exactly when it is spent.
        dealt = ([pre] if pre else []) + o["dealt"]
        pool_left = start if start is not None else o["max"]
        if any(d != rifle for d in dealt[:-1]) or abs(sum(dealt) - pool_left) > 1e-6:
            fail("B", "%s: the rifle dealt %s against a pool of %s" % (name, dealt, pool_left))
        if start is None:
            (stats["wreck_hits"] if target.kind == "wreck" else stats["rifle_hits"]).append(len(dealt))
        if o.get("fade"):
            fail("C", "%s: %+.1f health back 60 s after the first hit" % (name, o["fade"]))
        if o.get("after"):
            fail("D", "%s: a shot through where it stood hit it again" % name)
        if o.get("staleDealt"):
            fail("D", "%s: a part of it, broken, still took %s" % (name, o["staleDealt"]))
    stale = H.staleEntries()
    stats["stale"] = stale
    if stale:
        fail("D", "%d pool entries outlive what they were for" % stale)

    # F: every drivable.
    for target in drivables:
        H.region(H.centre(target), 60)
        o = plain(H.drivable(target))
        stats["drivable_parts"] += o["parts"]
        if o["breakable"] or o["anchoredBreakable"] or o["broken"]:
            fail("F", "drivable %s: %d parts DestructibleService's, %d when anchored, %d broken by a blast" % (
                target.design, o["breakable"], o["anchoredBreakable"], o["broken"]))
    # The same design as a drivable, for the static-against-drivable comparison (every design parked static).
    stats["drivable_compare"] = {}
    for design in stats["designs"]:
        if design and design != "plain":
            hits, health, per = H.drivableHits(design, "car", RIFLE)
            stats["drivable_compare"][design] = (hits, health, per)
    stats["scale"] = H.scale
    stats["rifle_damage"] = rifle
    return stats, fails, findings


# Planted faults, each aimed at something the code must refuse forever, applied to the source and required
# to fail the check. (module, old, new, letter the check must fail with, what it breaks)
PLANTS = [
    ("DestructibleService", "\tlocal model = taggedModel(part)\n\tif model then",
     "\tlocal model = taggedModel(part)\n\tif model and part.Name ~= \"Chassis\" and string.sub(part.Name, 1, 5) ~= \"Hull_\" then",
     "A", "the pool looked up by part name again (#51's old cause): the chassis and hull stop reaching the car"),
    ("MapDecor", "\tcar:SetAttribute(\"DestructibleHealth\", 240)\n",
     "\tif not (design and design.id) then car:SetAttribute(\"DestructibleHealth\", 240) end\n",
     "A", "a real design parked without its DestructibleHealth (the #51 fix undone for the #16/#94 cars)"),
    ("CombatService", "local destructible = CombatService.DestructibleFromPart and CombatService.DestructibleFromPart(result.Instance)",
     "local destructible = nil", "B", "a bullet that stops on a car never reaches its pool"),
    ("DestructibleService", "\tif entry.health <= 0 then\n\t\tentry.broken = true",
     "\tif entry.health <= entry.max * 0.2 then\n\t\tentry.broken = true",
     "B", "a car breaks before its pool is spent"),
    ("DestructibleService", "\t\telseif member.Parent then\n\t\t\tmember:Destroy()",
     "\t\telseif member.Parent and member.CanCollide then\n\t\t\tmember:Destroy()",
     "B", "a broken car leaves pieces behind"),
    ("DestructibleService", "CombatService.DestructibleFromPart = DestructibleService.FromPart\n",
     "game:GetService(\"RunService\").Heartbeat:Connect(function(dt) for _, e in pairs(damaged) do if not e.broken then "
     "e.health = math.min(e.max, e.health + dt * 2) end end end)\n"
     "CombatService.DestructibleFromPart = DestructibleService.FromPart\n",
     "C", "damage fades (2 health a second back)"),
    ("DestructibleService", "\t\tif damaged[key] == entry then\n\t\t\tdamaged[key] = nil\n\t\tend\n", "",
     "D", "a broken car's pool entry is never dropped"),
    ("DestructibleService", "if key and not seen[key] then", "if key then",
     "E", "a blast hurts a car once per part it reaches"),
    ("DestructibleService", "\t\tif node:GetAttribute(\"VehicleMaxHealth\") ~= nil then\n\t\t\treturn \"vehicle (VehicleService)\"",
     "\t\tif false then\n\t\t\treturn \"vehicle (VehicleService)\"",
     "F", "a drivable's parts become map scenery"),
]


# G: a drivable wrecked, through the real VehicleService in tools/roadkill_proof_world.lua (the world
# tools/roadkill_proof_check.py runs it in). Measured, not held: printed as a finding.
WRECK_SCENE = r"""
local w, C = ...
local V3 = w.Vector3.new
w.chunk(C.handling, "Handling", { VehicleDynamics = w.VehicleDynamics })
for i = 1, #C.models do
    local m = C.models[i]
    w.VehicleModels.Models[m[1]] = { kind = m[2], displayName = m[3] }
end
local VS = w.module("VehicleService")
local CS = w.module("CombatService")
VS.Start()
local model = VS.Create(w.workspace, V3(0, 3, 0), 0, "car", { model = "TralalaGT", exact = true })
local entry = VS.Get(model)
local out = { health = entry.health }
out.dealt, out.wrecked = VS.DamageVehicle(nil, model, 1e6, "bullet")
for _ = 1, 600 do
    w.now.t = w.now.t + 1 / 60
    w.runTimers()
    w.runService.Heartbeat:Fire(1 / 60)
end
out.parented = model.Parent ~= nil
out.flag = model:GetAttribute("Wrecked") == true
out.struck = CS.VehicleFromPart(entry.rig.chassis) == model
out.again = VS.DamageVehicle(nil, model, 500, "bullet")
out.collides = entry.rig.chassis.CanCollide == true
return out
"""


def wrecked_drivable():
    import roadkill_proof_check as rk
    tree = rk.Tree(os.path.dirname(HERE))
    lua = LuaRuntime(unpack_returned_tuples=True)
    with open(os.path.join(HERE, "roadkill_proof_world.lua"), encoding="utf-8") as f:
        world_text = f.read()
    compile_ = lua.eval("load")
    world = compile_(world_text, "roadkill_proof_world")(lambda name: tree.lua(name), compile_)
    c = rk.cuts(tree)
    ctable = lua.table_from({k: v for k, v in c.items() if k != "models"})
    ctable["models"] = lua.table_from([lua.table_from(list(m)) for m in c["models"]])
    return plain(lua.execute(WRECK_SCENE, world, ctable))


def summarise(all_stats, out=print):
    kinds = {}
    for st in all_stats:
        for k, v in st["kinds"].items():
            kinds[k] = kinds.get(k, 0) + v
    out("census over %d map builds: %s" % (len(all_stats), ", ".join("%s %d" % (k, kinds[k]) for k in sorted(kinds))))
    parts = [p for st in all_stats for p in st["static_parts"]]
    hittable = [p for st in all_stats for p in st["hittable"]]
    if parts:
        out("  static cars: %d, %d-%d parts each (%d in all), %d-%d a ray can hit" % (
            len(parts), min(parts), max(parts), sum(parts), min(hittable), max(hittable)))
    designs = {}
    for st in all_stats:
        for k, v in st["designs"].items():
            designs[k] = designs.get(k, 0) + v
    out("  static designs: %s" % ", ".join("%s %d" % (k, designs[k]) for k in sorted(designs)))
    out("A routing: %d hittable parts on static cars and wrecks, %d reach their car's pool, %d don't; %d collide but can't be hit" % (
        sum(st["hittable_total"] for st in all_stats), sum(st["routed"] for st in all_stats),
        sum(st["stray"] for st in all_stats), sum(st["collide_only"] for st in all_stats)))
    side = [sum(st["side"][i] for st in all_stats) for i in (0, 1)]
    out("  level shots from the side with a clear line: %d, %d took it" % (side[1], side[0]))
    rifle = [h for st in all_stats for h in st["rifle_hits"]]
    wreck = [h for st in all_stats for h in st["wreck_hits"]]
    if rifle:
        out("B rifle (%s, %s a hit, CombatDamageScale %s not applied to the map): %d static cars shot down, "
            "hits to break %d-%d; %d wilds wrecks, %d-%d hits" % (
                RIFLE, all_stats[0]["rifle_damage"], all_stats[0]["scale"], len(rifle), min(rifle), max(rifle), len(wreck),
                min(wreck) if wreck else 0, max(wreck) if wreck else 0))
    out("  blocked (no clear line from above): %d; already hurt by a blast next door: %d; already broken by one: %d" % (
        sum(st["blocked"] for st in all_stats), sum(st.get("collateral_hurt", 0) for st in all_stats),
        sum(st.get("collateral_gone", 0) for st in all_stats)))
    for st in all_stats:
        s = st["samples"]
        bits = []
        for weapon in (SHOTGUN, SNIPER, NOCLIP):
            if weapon in s and not s[weapon][1].get("blocked"):
                o = s[weapon][1]
                bits.append("%s %d shots/%d hits" % (weapon, o["shots"], o["onTarget"]))
        for label in ("rocket", "frag", "sticky", "barrel"):
            if label in st["blasts"] and not st["blasts"][label][1].get("blocked"):
                o = st["blasts"][label][1]
                bits.append("%s %d%s" % (label, o["launched"], "" if o["gone"] else " (standing)"))
        out("  %s seed %d: %s" % (st["map"], st["seed"], "; ".join(bits)))
    out("C fading: health 60 s after the first rifle hit, every car: unchanged unless a C failure is listed")
    out("D after: stale pool entries %d; shots through where a car stood that hit it %s" % (
        sum(st["stale"] for st in all_stats), "0 unless a D failure is listed"))
    out("F drivables: %d parts over %d vehicles, none DestructibleService's (anchored or not) unless an F failure is listed" % (
        sum(st["drivable_parts"] for st in all_stats), sum(v for st in all_stats for k, v in st["kinds"].items() if k.startswith("drivable"))))
    compare = {}
    for st in all_stats:
        compare.update(st["drivable_compare"])
    for design in sorted(compare):
        hits, health, per = compare[design]
        parked = ceil_div(240, all_stats[0]["rifle_damage"])
        out("  FINDING same design, parked vs drivable: %s parked 240 = %d rifle hits; drivable %d at %.2f a hit = %d hits (%.1fx)" % (
            design, parked, health, per, hits, hits / parked))
    noclip = [st["noclip_per_bullet"] for st in all_stats if st["noclip_per_bullet"]]
    if noclip:
        out("  FINDING %s (noclip one wall): %.2f hits on the same car per bullet (measured on %d cars)" % (
            NOCLIP, sum(noclip) / len(noclip), len(noclip)))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    plant = "--plant" in sys.argv
    if plant:
        caught = 0
        for module, old, new, letter, what in PLANTS:
            _, fails, _ = run_map("TralalaTown", 1, {module: [(old, new)]}, out=lambda *_: None)
            hit = [f for f in fails if f.startswith(letter + " ")]
            caught += 1 if hit else 0
            print("planted %s (%s): %s%s" % (letter, what, "caught" if hit else "MISSED",
                                             (" -- " + hit[0][:150]) if hit else ""))
        print("road_cars_proof_check --plant: %d/%d caught" % (caught, len(PLANTS)))
        sys.exit(0 if caught == len(PLANTS) else 1)
    maps = args or MAPS_DEFAULT
    seeds = [1]
    all_stats, all_fails = [], []
    for map_id in maps:
        for seed in seeds:
            st, fails, _ = run_map(map_id, seed)
            all_stats.append(st)
            all_fails += fails
            print("%s seed %d: built in %.1fs, %d parts, cars %s" % (map_id, seed, st["build"], st["parts"],
                  ", ".join("%s %d" % (k, v) for k, v in sorted(st["kinds"].items()))))
    summarise(all_stats)
    g = wrecked_drivable()
    print("G a drivable TralalaGT (%s health) wrecked by the real VehicleService: dealt %s, wrecked %s; 10 s later still in "
          "the map %s, Wrecked %s, bullets still stop on it (VehicleFromPart) %s, chassis collides %s, a later hit deals %s" % (
              g["health"], g["dealt"], g["wrecked"], g["parented"], g["flag"], g["struck"], g["collides"], g["again"]))
    if g["parented"] and g["struck"] and not g["again"]:
        print("  FINDING a wrecked drivable stays for the rest of a battle royale match: solid, takes bullets, can't be hurt")
    for f in all_fails:
        print("FAIL", f)
    print("road_cars_proof_check: %s (%d failures)" % ("OK" if not all_fails else "FAILED", len(all_fails)))
    sys.exit(0 if not all_fails else 1)


if __name__ == "__main__":
    main()
