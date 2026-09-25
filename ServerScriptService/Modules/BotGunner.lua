-- BotGunner: when a bot on foot mans a stationary gun (MountedGuns), and when it gets off again.
-- Oliver, 2026-09-25: "make the bots use the mounted guns too".
--
-- BotService asks two things, both at think rate (never per frame), over a gun list cached as guns come
-- and go (CollectionService signals on MountedGunData.Tag: no scans of the workspace):
--   BotGunner.Choose(bot, root, now, ctx) -> seat or nil   a free, whole, unlocked gun within SeekRange
--       whose arc holds a known enemy (or, in a team mode, which covers the battleground's lanes), not
--       one this bot left lately, and only while its team is under the cap on manned guns; a team
--       mode prefers guns on the bot's own half. The bot then walks over and mounts by MountedGuns.BotSit,
--       which holds a bot to the checks a player's prompt goes through (cooldown, reach, live, whole).
--   BotGunner.Leave(bot, ride, candidate, foes, now) -> reason or nil   while it is on one: off when
--       nothing has been in the arc for IdleLeave seconds, when flanked (shot from outside the shield's
--       arc, or an enemy close behind), when the gun is broken, or when the bot is hurt. BotService
--       gets it off (Vehicles.leaveRide) and it may not take that gun again for Cooldown seconds.
-- Firing is BotService's gunner branch as for a vehicle turret: VehicleWeapons.Fire along the gun's own
-- barrel, with the bot's hit chance, holding off while the belt is low or hot (it reloads itself).
-- BotGunner.Threats(position, range, isHostile) hands a driving bot the manned guns about with their
-- facing and arc, for BotDriveTactics to route round.
--
-- The decisions are the PURE block below (plain Lua, tables of numbers), run by
-- tools/mounted_guns_check.py's BOTS section.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MountedGunData = require(Shared:WaitForChild("MountedGunData"))
local Combatants = require(script.Parent:WaitForChild("Combatants"))

local BotGunner = {}

-- PURE BEGIN
local Pure = {}

Pure.Params = {
	SeekRange = 40,      -- studs: a gun this close to a bot on foot may be taken
	IdleLeave = 12,      -- seconds with nothing in the arc before getting off
	FlankBehind = 15,    -- studs: an enemy this close outside the shield's arc is behind the gunner
	ShieldHalf = 70,     -- degrees either side of the gun's front the shield covers
	FlankMemory = 2.5,   -- seconds a hit from outside the shield's arc counts
	LowHealth = 0.35,    -- share of the bot's health under which it neither takes a gun nor stays on one
	Cooldown = 45,       -- seconds before a bot takes a gun it left again
	TeamCap = 3,         -- manned guns per team in a team mode
	RoyaleShare = 0.25,  -- the share of the map's guns bots man at once in a battle royale
	HalfBonus = 15,      -- studs of walking a gun on the bot's own half is worth (team modes)
	FoeBonus = 10,       -- the same for each known enemy in the gun's arc
	ThreatRange = 200,   -- the most of a manned gun's range a driving bot keeps out of
	ThreatMargin = 10,   -- degrees added to a gun's arc for a driving bot
}

local function dot2(ax, az, bx, bz)
	return ax * bx + az * bz
end

-- How many guns bots may man at once on one side (or, with no teams, in all).
function Pure.cap(teamMode, gunCount, P)
	P = P or Pure.Params
	if teamMode then
		return P.TeamCap
	end
	return math.max(1, math.floor(gunCount * P.RoyaleShare + 0.5))
end

-- A gun: { id, x, z, fx, fz (its front, flat, unit), yawLimit (degrees), range, manned, broken, locked,
-- covers }. Whether (x, z) is inside its field of fire, `slack` degrees wider.
function Pure.inArc(gun, x, z, slack)
	local dx, dz = x - gun.x, z - gun.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d > gun.range then
		return false
	end
	if d < 1 then
		return true
	end
	local limit = math.min(180, gun.yawLimit + (slack or 0))
	return dot2(gun.fx, gun.fz, dx / d, dz / d) >= math.cos(math.rad(limit))
end

-- Whether (x, z) is round the gunner's side or back, out of the shield's cover.
function Pure.outsideShield(gun, x, z, P)
	P = P or Pure.Params
	local dx, dz = x - gun.x, z - gun.z
	local d = math.sqrt(dx * dx + dz * dz)
	if d < 0.5 then
		return true
	end
	return dot2(gun.fx, gun.fz, dx / d, dz / d) < math.cos(math.rad(P.ShieldHalf))
end

-- The gun a bot should take, or nil and why not. `bot`: { x, z, team, busy, health (0-1), now,
-- cooldowns = { [gun id] = until }, foes = { { x, z }, ... }, teamMode, home = { x, z } (its base) and
-- away = { x, z } (the other's), manned = { [team or "all"] = guns its side's bots are on }, gunCount }.
function Pure.pick(bot, guns, P)
	P = P or Pure.Params
	if bot.busy then
		return nil, "busy"
	end
	if (bot.health or 1) < P.LowHealth then
		return nil, "hurt"
	end
	local side = bot.teamMode and bot.team or "all"
	if ((bot.manned or {})[side] or 0) >= Pure.cap(bot.teamMode, bot.gunCount or #guns, P) then
		return nil, "cap"
	end
	local best, bestScore, why = nil, math.huge, "none near"
	for _, gun in ipairs(guns) do
		local dx, dz = gun.x - bot.x, gun.z - bot.z
		local d = math.sqrt(dx * dx + dz * dz)
		if d <= P.SeekRange and not gun.manned and not gun.broken and not gun.locked
			and ((bot.cooldowns or {})[gun.id] or 0) <= bot.now then
			local foes = 0
			for _, foe in ipairs(bot.foes or {}) do
				if Pure.inArc(gun, foe.x, foe.z) then
					foes = foes + 1
				end
			end
			if foes > 0 or (bot.teamMode and gun.covers) then
				local score = d - foes * P.FoeBonus
				if bot.teamMode and bot.home and bot.away then
					local mine = (gun.x - bot.home.x) ^ 2 + (gun.z - bot.home.z) ^ 2
					local theirs = (gun.x - bot.away.x) ^ 2 + (gun.z - bot.away.z) ^ 2
					if mine < theirs then
						score = score - P.HalfBonus
					end
				end
				if score < bestScore then
					best, bestScore = gun, score
				end
			else
				why = "nothing to cover"
			end
		end
	end
	if best then
		return best, nil
	end
	return nil, why
end

-- Whether a bot on `gun` should get off, and why. `s`: { now, arcTargetAt (last time a target was in
-- the arc), hitFrom = { x, z, at } (the last shot at it, or nil), foes = { { x, z }, ... } (enemies
-- about), health (0-1) }.
function Pure.leave(gun, s, P)
	P = P or Pure.Params
	if gun.broken then
		return "broken"
	end
	if (s.health or 1) < P.LowHealth then
		return "hurt"
	end
	local hit = s.hitFrom
	if hit and s.now - hit.at <= P.FlankMemory and Pure.outsideShield(gun, hit.x, hit.z, P) then
		return "flanked"
	end
	for _, foe in ipairs(s.foes or {}) do
		local dx, dz = foe.x - gun.x, foe.z - gun.z
		if dx * dx + dz * dz <= P.FlankBehind * P.FlankBehind and Pure.outsideShield(gun, foe.x, foe.z, P) then
			return "flanked"
		end
	end
	if s.now - (s.arcTargetAt or s.now) > P.IdleLeave then
		return "idle"
	end
	return nil
end

-- A manned gun as a driving bot sees it: { x, z, fx, fz, cosArc, range } for BotDriveTactics (which
-- routes a car out of the arc, out to the range).
function Pure.threat(gun, P)
	P = P or Pure.Params
	local limit = math.min(180, gun.yawLimit + P.ThreatMargin)
	return { x = gun.x, z = gun.z, fx = gun.fx, fz = gun.fz, cosArc = math.cos(math.rad(limit)),
		range = math.min(P.ThreatRange, gun.range) }
end
-- PURE END

BotGunner.Pure = Pure
BotGunner.Params = Pure.Params

--------------------------------------------------------------------------------
-- The gun list (per match: guns are tagged when built and untagged when destroyed)
--------------------------------------------------------------------------------

local guns = {}
local watching = false

local function watch()
	if watching then
		return
	end
	watching = true
	for _, model in ipairs(CollectionService:GetTagged(MountedGunData.Tag)) do
		guns[model] = true
	end
	CollectionService:GetInstanceAddedSignal(MountedGunData.Tag):Connect(function(model)
		guns[model] = true
	end)
	CollectionService:GetInstanceRemovedSignal(MountedGunData.Tag):Connect(function(model)
		guns[model] = nil
	end)
end

local function seatOf(model)
	local seat = model:FindFirstChild("GunnerSeat", true)
	return seat and seat:IsA("Seat") and seat or nil
end

-- A gun model as the PURE block reads it, or nil when it is not standing.
local function describe(model, now)
	local root = model.PrimaryPart
	local seat = seatOf(model)
	if not root or not seat or not model:IsDescendantOf(workspace) then
		return nil
	end
	local spec = MountedGunData.SpecOf(model:GetAttribute("MountedGun"))
	local look = model:GetAttribute("BotFacing") or root.CFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	flatLook = flatLook.Magnitude > 1e-3 and flatLook.Unit or Vector3.new(0, 0, -1)
	local lockedUntil = model:GetAttribute("LockedUntil")
	return {
		id = model, model = model, seat = seat, x = root.Position.X, z = root.Position.Z, y = root.Position.Y,
		fx = flatLook.X, fz = flatLook.Z,
		yawLimit = spec and spec.yawLimit or 60, range = spec and spec.range or 300,
		manned = seat.Occupant ~= nil, broken = model:GetAttribute("Wrecked") == true,
		locked = lockedUntil ~= nil and workspace:GetServerTimeNow() < lockedUntil, covers = model:GetAttribute("BotCovers") == true,
	}
end

local function occupantToken(seat)
	local occupant = seat.Occupant
	return occupant and occupant.Parent and Combatants.FromCharacter(occupant.Parent) or nil
end

--------------------------------------------------------------------------------
-- The bot's side
--------------------------------------------------------------------------------

local function flatPos(token)
	local root = Combatants.GetRoot(token)
	return root and { x = root.Position.X, z = root.Position.Z } or nil
end

-- ctx (from BotService): { team, teamMode, busy, health, foes = { token, ... }, home, away (Vector3 or nil) }
function BotGunner.Choose(bot, root, now, ctx)
	watch()
	local list, manned, count = {}, {}, 0
	for model in pairs(guns) do
		local gun = describe(model, now)
		if gun then
			count += 1
			table.insert(list, gun)
			local holder = gun.manned and occupantToken(gun.seat)
			if holder and Combatants.IsBot(holder) then
				local side = ctx.teamMode and ctx.teamOf and ctx.teamOf(holder) or "all"
				if side then
					manned[side] = (manned[side] or 0) + 1
				end
			end
		end
	end
	if count == 0 then
		return nil
	end
	local foes = {}
	for _, token in ipairs(ctx.foes or {}) do
		local at = flatPos(token)
		if at then
			table.insert(foes, at)
		end
	end
	bot.gunCooldowns = bot.gunCooldowns or {}
	local picked = Pure.pick({
		x = root.Position.X, z = root.Position.Z, team = ctx.team, teamMode = ctx.teamMode, busy = ctx.busy,
		health = ctx.health, now = now, cooldowns = bot.gunCooldowns, foes = foes, manned = manned, gunCount = count,
		home = ctx.home and { x = ctx.home.X, z = ctx.home.Z } or nil,
		away = ctx.away and { x = ctx.away.X, z = ctx.away.Z } or nil,
	}, list)
	return picked and picked.seat or nil
end

-- Whether the bot on this gun should get off: the reason, or nil. Tracks the last time a target was in
-- the arc on the ride. `candidate` is the gunner branch's target this think ({ root } or nil); `foes`
-- tokens it knows of.
function BotGunner.Leave(bot, ride, candidate, foes, now)
	local gun = describe(ride.model, now)
	if not gun then
		return "broken"
	end
	if candidate and candidate.root and Pure.inArc(gun, candidate.root.Position.X, candidate.root.Position.Z) then
		ride.arcTargetAt = now
	end
	local near = {}
	for _, token in ipairs(foes or {}) do
		local at = flatPos(token)
		if at then
			table.insert(near, at)
		end
	end
	local threat = bot.threat
	local humanoid = bot.humanoid
	return Pure.leave(gun, {
		now = now, arcTargetAt = ride.arcTargetAt or ride.boardedAt,
		hitFrom = threat and threat.position and { x = threat.position.X, z = threat.position.Z, at = threat.at } or nil,
		foes = near, health = humanoid and humanoid.Health / math.max(1, humanoid.MaxHealth) or 1,
	})
end

-- A bot left `model` (for any reason): not that one again for a while.
function BotGunner.Left(bot, model, now)
	bot.gunCooldowns = bot.gunCooldowns or {}
	bot.gunCooldowns[model] = now + Pure.Params.Cooldown
	for key, untilAt in pairs(bot.gunCooldowns) do
		if untilAt <= now then
			bot.gunCooldowns[key] = nil
		end
	end
end

function BotGunner.IsGun(model)
	return model ~= nil and model:GetAttribute("MountedGun") ~= nil
end

-- The manned guns within `range` of `position` whose gunner `isHostile(token)`, as BotDriveTactics'
-- gun entries: { pos, facing, cosArc, range }.
function BotGunner.Threats(position, range, isHostile)
	watch()
	local out = {}
	for model in pairs(guns) do
		local seat = seatOf(model)
		local holder = seat and seat.Occupant and occupantToken(seat)
		if holder and isHostile(holder) then
			local gun = describe(model, 0)
			if gun and (Vector3.new(gun.x, 0, gun.z) - Vector3.new(position.X, 0, position.Z)).Magnitude <= range + gun.range then
				local t = Pure.threat(gun)
				table.insert(out, { pos = Vector3.new(t.x, 0, t.z), facing = Vector3.new(t.fx, 0, t.fz), cosArc = t.cosArc,
					range = t.range })
			end
		end
	end
	return out
end

return BotGunner
