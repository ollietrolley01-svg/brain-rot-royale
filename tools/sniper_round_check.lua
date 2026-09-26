-- The scenes tools/sniper_round_check.py runs (lupa, plain Lua 5.x), in the world of
-- tools/explosive_dispatch_world.lua: the REAL CombatService, ProjectileService, Ballistics, WeaponData and
-- VehicleCover, with boxes for walls and hitreg_mocks bodies for people. Not loaded by the game.
--
-- Called as harness(w, S). Every shot goes through the real CombatService.Fire, once as the gun is (its
-- `round` flies through ProjectileService) and once with `round` cleared for that shot only (the hitscan
-- firePellet it had before task 17), so the two can be compared on the same scene.

local w, S = ...
local M, W = w.M, w.W
local V3 = M.Vector3.new
local CS, PS, WD, B = S.CS, S.PS, S.WD, S.B
local VC = S.module("VehicleCover")
local H = { dealt = {}, wallHits = {}, vehicleHits = {} }

-- The mock's ray reports the normal as the ray reversed; a bank shot needs the box face's real normal.
local ws = rawget(M.workspace, "_props")
local baseRay = ws.Raycast
ws.Raycast = function(self, origin, vector, params)
	local r = baseRay(self, origin, vector, params)
	local inst = r and r.Instance
	local centre, half = inst and inst.centre, inst and inst.half
	if centre and half then
		local d = r.Position - centre
		local best, axis = -1, "X"
		for _, a in ipairs({ "X", "Y", "Z" }) do
			local q = math.abs(d[a]) / half[a]
			if q > best then
				best, axis = q, a
			end
		end
		local s = d[axis] >= 0 and 1 or -1
		r.Normal = V3(axis == "X" and s or 0, axis == "Y" and s or 0, axis == "Z" and s or 0)
	end
	return r
end

function H.reset()
	for k in pairs(M.walls) do M.walls[k] = nil end
	local kids = rawget(M.workspace, "_children")
	for k in pairs(kids) do kids[k] = nil end
	for k in pairs(W.tokens) do W.tokens[k] = nil end
	for k in pairs(W.humanoids) do W.humanoids[k] = nil end
	for k in pairs(w.recorders.fired) do w.recorders.fired[k] = nil end
	H.dealt, H.wallHits, H.vehicleHits = {}, {}, {}
	PS.Clear()
	CS.DestructibleFromPart = function(p) return p.destructible and p or nil end
	CS.DestructiblePassesThrough = function(p) return p.glass == true end
	CS.DamageDestructible = function(_, p, amount) table.insert(H.wallHits, { name = p.Name, amount = amount }) end
	CS.VehicleFromPart = function(p) return p.vehicleModel end
	CS.DamageVehicle = function(_, _, amount) table.insert(H.vehicleHits, amount) end
	CS.DamageVeto = function(a, v) return a ~= nil and a ~= v and a.team ~= nil and a.team == v.team end
	CS.SpreadFor = function() return 0 end
	CS.DamageListeners = { function(a, v, amount, weaponId, headshot)
		table.insert(H.dealt, { a = a, v = v, name = v and v.name, amount = amount, weaponId = weaponId, headshot = headshot, t = w.now.t })
	end }
	VC.CrossesGlass = function() return false end
	CS.SetEnabled(true)
	H.box("Ground", V3(0, -0.5, 0), V3(4000, 1, 4000))
end

function H.person(name, x, z, team, hp)
	local model, root = M.character(name, M.CFrame.new(x, 3, z))
	local token = { name = name, Character = model, team = team }
	W.tokens[model] = token
	W.humanoids[token] = M.instance("Humanoid", "Humanoid", model, { Health = hp or 100, MaxHealth = 100 })
	return token, model, root
end

function H.box(name, centre, size, props)
	local p = M.wall(name, centre, size)
	local raw = rawget(p, "_props")
	raw.centre, raw.half = centre, size / 2
	for k, v in pairs(props or {}) do raw[k] = v end
	return p
end

-- Sat in `vehicle` (a Model carrying VehicleModel = modelId) on a seat called `seatName`.
function H.seat(token, vehicle, seatName)
	local seat = M.instance("Seat", seatName, vehicle, {})
	W.humanoids[token].SeatPart = seat
	return seat
end

function H.vehicle(modelId)
	local model = M.instance("Model", "Car", M.workspace, {})
	model:SetAttribute("VehicleModel", modelId)
	return model
end

-- One shot through the real Fire. `hitscan`: with the gun's `round` cleared for this shot only.
function H.fire(shooter, defId, aim, hitscan)
	local def = WD.Get(defId)
	local saved = def.round
	if hitscan then
		def.round = nil
	end
	W.equipped = def
	w.loadout.fireCredit, w.loadout.lastShotAt, w.loadout.reloading = 2, 0, nil
	w.now.t = w.now.t + 10
	local at = w.now.t
	CS.Fire(shooter, aim)
	def.round = saved
	return at
end

-- Steps the real ProjectileService at `dt` until nothing is in flight (or `limit` seconds). `each(t)` runs
-- before each step, for things that move.
function H.run(dt, limit, each)
	local t = 0
	while t < (limit or 3) do
		local rounds, bodies = PS.Counts()
		if rounds == 0 and bodies == 0 then
			break
		end
		if each then each(t) end
		t = t + dt
		w.now.t = w.now.t + dt
		PS.Step(dt)
	end
	return t
end

function H.took(token)
	local sum, n, head, first = 0, 0, false, nil
	for _, d in ipairs(H.dealt) do
		if d.v == token then
			sum, n = sum + d.amount, n + 1
			head = head or d.headshot
			first = first or d.t
		end
	end
	return sum, n, head, first
end

function H.moveRoot(root, x, z)
	rawget(root, "_props").CFrame = M.CFrame.new(x, 3, z)
end

function H.setVelocity(root, v)
	rawget(root, "_props").AssemblyLinearVelocity = v
end

return H
