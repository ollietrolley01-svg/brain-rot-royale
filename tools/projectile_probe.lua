-- Projectile probe: measures what ProjectileService and Ballistics actually do, in edit mode.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/projectile_probe.lua -WaitSeconds 300
--
-- Everything is stepped by hand (SetAutoStep(false)) in a lane of test geometry high above the map, with
-- stand-in combatants (anchored rigs registered with Combatants). It prints:
--   FLIGHT   the server's round positions against an independent fine-step integration of the spec
--   DROP     rocket and 40mm drop at range, 40mm and throw max range
--   FALLOFF  damage by distance from a rocket blast in the open
--   COVER    a full wall, a low wall and a window between blast and victim
--   WORLD    walls holed near the blast, glass shattered, barrels chained, self-damage
--   IMPACT   a rocket fired at a wall bursts on its face; a direct hit gets the bonus
--   DUD      a 40mm into a wall at point blank bounces and pops late
--   BOUNCE   a frag dropped on a floor: bounce heights against restitution, rest time, fuse
--   SMOKE    line-of-sight through a cloud over its life
--   COST     step time with 200 rounds in flight and 100 grenades bouncing
--   DRIVER   a vehicle's driver can't throw, a passenger can
--   MODELS   the throwable and round models: part counts, grip, parts touching nothing
-- Lines starting "PROBLEM" are failures.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))
local Combatants = require(Modules:WaitForChild("Combatants"))
local ProjectileService = require(Modules:WaitForChild("ProjectileService"))
local HazardService = require(Modules:WaitForChild("HazardService"))
require(Modules:WaitForChild("HitSplatService"))

ProjectileService.SetAutoStep(false)

local V = Vector3.new
local ORIGIN = V(9000, 3000, 9000)
local DT = 1 / 60
local GRAVITY = workspace.Gravity
local problems = 0

local function say(text)
	print("[projectile_probe] " .. text)
end
local function problem(text)
	problems += 1
	say("PROBLEM " .. text)
end
local function fmt(n)
	return string.format("%.2f", n)
end

-- Test geometry lives under a Model named Map, so DestructibleService and the blast cover checks treat
-- it as the map.
local map = workspace:FindFirstChild("Map")
local ownMap = false
if not map then
	map = Instance.new("Model")
	map.Name = "Map"
	map.Parent = workspace
	ownMap = true
end
local lane = Instance.new("Model")
lane.Name = "ProjectileProbe"
lane.Parent = map

local function block(name, size, cframe, props)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = typeof(cframe) == "Vector3" and CFrame.new(cframe) or cframe
	part.Anchored = true
	part.Color = Color3.fromRGB(150, 150, 156)
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = lane
	return part
end

-- A stand-in combatant: root, torso, head and legs, anchored, with a humanoid, registered as a bot.
local dummies = {}
local function dummy(position, name)
	local model = Instance.new("Model")
	model.Name = name
	local function limb(limbName, size, offset)
		local part = Instance.new("Part")
		part.Name = limbName
		part.Size = size
		part.CFrame = CFrame.new(position + offset)
		part.Anchored = true
		part.CanCollide = false
		part.Parent = model
		return part
	end
	local root = limb("HumanoidRootPart", V(2, 2, 1), V(0, 0, 0))
	root.Transparency = 1
	limb("UpperTorso", V(2, 1.6, 1), V(0, 0.2, 0))
	limb("Head", V(1.2, 1.2, 1.2), V(0, 1.6, 0))
	limb("LowerTorso", V(1.8, 2, 1), V(0, -2, 0))
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = lane
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	local token = { isBot = true, name = name, character = model }
	Combatants.Register(model, token)
	table.insert(dummies, model)
	return token, model, humanoid
end

local function heal(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	humanoid.Health = humanoid.MaxHealth
	humanoid:SetAttribute("Shield", 0)
end

local rocketDef = { id = "CappuccinaLauncher", projectile = "rocket", damage = 68, splashRadius = 14 }
local grenadeDef = { id = "TralalaThumper", projectile = "grenade", damage = 58, splashRadius = 11 }

--------------------------------------------------------------------------------
-- FLIGHT: server path vs an independent fine-step integration
--------------------------------------------------------------------------------
do
	for _, def in ipairs({ rocketDef, grenadeDef }) do
		local spec = Ballistics.Rounds[def.projectile]
		local start = ORIGIN + V(0, 400, 0)
		local direction = V(1, 0.25, 0).Unit
		local entry = ProjectileService.LaunchRound(nil, def, start, direction)
		-- Independent: integrate the distance along the line and the drop as plain (double) numbers
		-- with a 1/4000 s step, and only build a Vector3 to compare. (Summing Vector3s here piled up
		-- float32 rounding at x = 9000 into studs of "drift" that was the probe's, not the server's.)
		local fine = 1 / 4000
		local along, speed, drop, vertical, t = 0, spec.speed, 0, 0, 0
		local accel = (spec.boostTime or 0) > 0 and (spec.maxSpeed - spec.speed) / spec.boostTime or 0
		local worst, samples = 0, 0
		for step = 1, math.floor(math.min(spec.maxTime, 2) / DT) - 2 do
			ProjectileService.Step(DT)
			local target = step * DT
			while t < target - 1e-9 do
				local h = math.min(fine, target - t)
				local a = t < (spec.boostTime or 0) and accel or 0
				local g = GRAVITY * spec.gravityScale
				along += speed * h + 0.5 * a * h * h
				speed += a * h
				drop += vertical * h + 0.5 * g * h * h
				vertical += g * h
				t += h
			end
			local position = start + direction * along - Vector3.yAxis * drop
			local live = ProjectileService.Peek(entry.id)
			if not live then
				problem("FLIGHT " .. def.projectile .. " ended early at " .. fmt(target) .. " s")
				break
			end
			worst = math.max(worst, (live.position - position).Magnitude)
			samples += 1
		end
		say(string.format("FLIGHT %s: %d samples, worst difference from fine integration %.4f studs", def.projectile, samples, worst))
		if worst > 0.05 then
			problem("FLIGHT " .. def.projectile .. " drifts " .. fmt(worst) .. " studs from the formula")
		end
		ProjectileService.Clear()
	end
end

--------------------------------------------------------------------------------
-- DROP: how far below the line of fire a round is at a range, and max ranges
--------------------------------------------------------------------------------
do
	for _, spec in ipairs({ { "rocket", { 50, 150, 300, 400, 500 } }, { "grenade", { 30, 60, 100, 150 } } }) do
		local round = Ballistics.Rounds[spec[1]]
		local parts = {}
		for _, range in ipairs(spec[2]) do
			local t = Ballistics.RoundTimeFor(round, range)
			local position = Ballistics.RoundState(round, Vector3.zero, Vector3.xAxis, GRAVITY, t)
			table.insert(parts, string.format("%d studs: %.2fs, drop %.1f", range, t, -position.Y))
		end
		say("DROP " .. spec[1] .. ": " .. table.concat(parts, " | "))
	end
	-- Max range on the flat, by firing angle.
	local function rangeOf(spec, angle, speedOverride, gravityScale)
		local g = GRAVITY * gravityScale
		local v = speedOverride
		return v * v * math.sin(2 * angle) / g
	end
	local grenade = Ballistics.Rounds.grenade
	say(string.format("DROP 40mm max flat range at 45 deg: %.0f studs", rangeOf(grenade, math.rad(45), grenade.speed, grenade.gravityScale)))
	local frag = Ballistics.Throwables.CookedCoconut
	-- A throw has lift, so aim 45 deg is a little over; report aimed angles.
	for _, aim in ipairs({ 0, 15, 30, 45 }) do
		local head = V(0, 5, 0)
		local aimPoint = head + V(math.cos(math.rad(aim)), math.sin(math.rad(aim)), 0) * 100
		local velocity = Ballistics.ThrowVelocity(frag, head, aimPoint, nil)
		local origin = Ballistics.ThrowOrigin(head, velocity.Unit)
		-- Land at y = 0.42 (radius off a floor at 0).
		local g = GRAVITY * frag.gravityScale
		local a, b, c = -0.5 * g, velocity.Y, origin.Y - frag.radius
		local t = (-b - math.sqrt(b * b - 4 * a * c)) / (2 * a)
		say(string.format("DROP throw aimed %d deg from a standing head: lands %.1f studs out after %.2fs", aim, origin.X + velocity.X * t, t))
	end
end

--------------------------------------------------------------------------------
-- FALLOFF: damage by distance in the open (one rocket blast, dummies on a spiral)
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(0, 0, 200)
	block("ProbeGround", V(80, 1, 80), centre - V(0, 3.5, 0))
	local byToken = {}
	local distances = { 0, 1.5, 3, 4.5, 6, 8, 10, 12, 14, 15, 16 }
	for index, distance in ipairs(distances) do
		local angle = index / #distances * math.pi * 2
		-- Root offset includes the body allowance, so `distance` is what the falloff sees.
		local reach = distance + Ballistics.BodyAllowance
		local token = dummy(centre + V(math.cos(angle) * reach, 0, math.sin(angle) * reach), "Falloff" .. distance)
		byToken[token] = distance
	end
	local dealt = ProjectileService.Explode({
		id = -1, kind = "rocket", owner = nil, weaponId = "CappuccinaLauncher", position = centre, normal = nil,
		damage = 68, radius = 14, innerRadius = 3.5, wallDamage = 0,
	})
	local got = {}
	for _, hit in ipairs(dealt) do
		got[byToken[hit.token]] = hit.amount
	end
	local row = {}
	for _, distance in ipairs(distances) do
		local expected = 68 * Ballistics.BlastScale(distance, 3.5, 14)
		local amount = got[distance] or 0
		table.insert(row, string.format("%s:%s", fmt(distance), fmt(amount)))
		if math.abs(amount - expected) > 0.6 then
			problem(string.format("FALLOFF at %.1f studs dealt %.2f, formula says %.2f", distance, amount, expected))
		end
	end
	say("FALLOFF rocket 68 dmg r14 inner 3.5 (distance past body allowance : damage) " .. table.concat(row, "  "))
end

--------------------------------------------------------------------------------
-- COVER and WORLD
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(200, 0, 0)
	block("ProbeGround", V(120, 1, 120), centre - V(0, 3.5, 0))
	local blastAt = centre + V(0, -1, 0)

	-- Each victim stands 7 studs out in its own direction; cover goes at 3.5 studs.
	local cases = {
		{ "open", nil },
		{ "full wall", function(at, facing) return block("Wall", V(8, 12, 1), CFrame.lookAt(at, at + facing) * CFrame.new(0, 3, 0)) end },
		{ "low wall", function(at, facing) return block("Wall", V(8, 2.4, 1), CFrame.lookAt(at, at + facing) * CFrame.new(0, -1.9, 0)) end },
		{ "window", function(at, facing) return block("WindowGlass", V(8, 12, 0.2), CFrame.lookAt(at, at + facing) * CFrame.new(0, 3, 0), { Transparency = 0.6 }) end },
	}
	local tokens = {}
	local covers = {}
	for index, case in ipairs(cases) do
		local angle = (index - 1) / #cases * math.pi * 2
		local facing = V(math.cos(angle), 0, math.sin(angle))
		local token = dummy(centre + facing * 7, "Cover_" .. case[1])
		tokens[token] = case[1]
		if case[2] then
			covers[case[1]] = case[2](centre + facing * 3.5, facing)
		end
	end
	-- A wall 5 studs out breaks (within half of r14); one 10 studs out doesn't.
	local nearWall = block("Wall", V(4, 6, 1), CFrame.new(centre + V(3.5, 0, 3.5)) * CFrame.Angles(0, math.rad(45), 0))
	local farWall = block("Wall", V(4, 6, 1), CFrame.new(centre + V(-7, 0, -7)) * CFrame.Angles(0, math.rad(45), 0))
	-- Barrels: one in reach, one chained from it.
	local barrelA = HazardService.Barrel(lane, CFrame.new(centre + V(-9, -3, 6)))
	local barrelB = HazardService.Barrel(lane, CFrame.new(centre + V(-20, -3, 12)))
	local owner, ownerModel = dummy(centre + V(0, 0, -3), "Owner")

	local dealt = ProjectileService.Explode({
		id = -2, kind = "rocket", owner = owner, weaponId = "CappuccinaLauncher", position = blastAt, normal = Vector3.yAxis,
		damage = 68, radius = 14, innerRadius = 3.5, wallDamage = 150,
	})
	local results = {}
	local selfTaken = nil
	for _, hit in ipairs(dealt) do
		if tokens[hit.token] then
			results[tokens[hit.token]] = hit
		elseif hit.token == owner then
			selfTaken = hit
		end
	end
	local line = {}
	for _, case in ipairs(cases) do
		local hit = results[case[1]]
		table.insert(line, string.format("%s: %s (reach %s)", case[1], hit and fmt(hit.amount) or "0", hit and fmt(hit.reach) or "0"))
	end
	say("COVER victims 7 studs out, cover at 3.5: " .. table.concat(line, " | "))
	if results["full wall"] then
		problem("COVER a full wall let " .. fmt(results["full wall"].amount) .. " damage through")
	end
	if not results["low wall"] or results["low wall"].reach >= 1 or results["low wall"].reach <= 0 then
		problem("COVER a low wall should leave head and body exposed but not legs")
	end
	if not results.window or results.window.reach < 1 then
		problem("COVER a window should not protect anyone")
	end
	if not results.open then
		problem("COVER the open victim took nothing")
	end
	say(string.format("WORLD self-damage at 3 studs: %s (open victim at 7: %s)", selfTaken and fmt(selfTaken.amount) or "none",
		results.open and fmt(results.open.amount) or "none"))
	if not selfTaken then
		problem("WORLD the owner took no self-damage")
	end
	say("WORLD near wall broken: " .. tostring(nearWall.Parent == nil) .. ", far wall standing: " .. tostring(farWall.Parent ~= nil)
		.. ", window pane gone: " .. tostring(covers.window and covers.window.Parent == nil))
	if nearWall.Parent ~= nil then
		problem("WORLD a wall 5 studs from a rocket blast survived")
	end
	if farWall.Parent == nil then
		problem("WORLD a wall 10 studs from a rocket blast broke")
	end
	if covers.window and covers.window.Parent ~= nil then
		problem("WORLD the window in the blast survived")
	end
	task.wait(1)
	say("WORLD barrels: near one gone " .. tostring(barrelA.Parent == nil) .. ", chained one gone " .. tostring(barrelB.Parent == nil))
	if barrelA.Parent ~= nil then
		problem("WORLD a barrel 11 studs from the blast didn't go up")
	end
	heal(ownerModel)
end

--------------------------------------------------------------------------------
-- IMPACT: a rocket at a wall and a rocket at a body
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(-200, 0, 0)
	local wall = block("ProbeWall", V(1, 20, 20), CFrame.new(centre + V(60, 0, 0)))
	local entry = ProjectileService.LaunchRound(nil, rocketDef, centre, Vector3.xAxis)
	local steps = 0
	repeat
		ProjectileService.Step(DT)
		steps += 1
	until not ProjectileService.Peek(entry.id) or steps > 200
	local last = entry.position
	say(string.format("IMPACT rocket at a wall 60 studs away burst after %.2fs, last centre x=%.2f (wall face at %.2f)", entry.age, last.X - centre.X, 59.5))
	if entry.age > 0.5 or last.X - centre.X > 59.5 then
		problem("IMPACT the rocket passed the wall face or flew too long")
	end
	wall:Destroy()

	-- Every hit the service deals, for the one-event and headshot checks below.
	local CombatService = require(Modules:WaitForChild("CombatService"))
	local events = {}
	CombatService.OnDamage(function(_, victim, dealt, _, headshot)
		table.insert(events, { victim = victim, dealt = dealt, headshot = headshot })
	end)
	local function eventsFor(victim)
		local count, dealt, headshot = 0, 0, false
		for _, event in ipairs(events) do
			if event.victim == victim then
				count += 1
				dealt += event.dealt
				headshot = headshot or event.headshot
			end
		end
		return count, dealt, headshot
	end
	local function fly(entry)
		steps = 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
		until not ProjectileService.Peek(entry.id) or steps > 200
	end

	local token, model, humanoid = dummy(centre + V(40, 0, 30), "Direct")
	heal(model)
	fly(ProjectileService.LaunchRound(nil, rocketDef, centre + V(0, 0, 30), Vector3.xAxis))
	local count, dealt, headshot = eventsFor(token)
	say(string.format("IMPACT direct hit on a body: health 100 -> took %s in %d event(s), headshot=%s (blast 68 + bonus 25 = 93 expected, one event, no headshot)", fmt(100 - humanoid.Health), count, tostring(headshot)))
	if math.abs((100 - humanoid.Health) - 93) > 1 or count ~= 1 or headshot then
		problem("IMPACT a direct rocket hit dealt " .. fmt(100 - humanoid.Health) .. " in " .. count .. " event(s), headshot=" .. tostring(headshot))
	end

	-- Headshots: the round itself striking the Head part. The direct part of the damage (the impact
	-- bonus, or all of it for a non-explosive round) takes the gun's headshotMultiplier, the blast
	-- stays flat, and it is still exactly one damage event, flagged. The stand-ins are registered as
	-- bots, so this is also bots suffering it. Shield 100 so nothing is capped by health.
	local headDef = { id = "CappuccinaLauncher", projectile = "rocket", damage = 68, splashRadius = 14, headshotMultiplier = 1.6 }
	local headToken, headModel, headHumanoid = dummy(centre + V(40, 0, 60), "Headshot")
	heal(headModel)
	headHumanoid:SetAttribute("Shield", 100)
	fly(ProjectileService.LaunchRound(nil, headDef, centre + V(0, 1.75, 60), Vector3.xAxis))
	count, dealt, headshot = eventsFor(headToken)
	say(string.format("IMPACT rocket to the Head (multiplier 1.6): dealt %s in %d event(s), headshot=%s (blast 68 + bonus 25 x 1.6 = 108 expected, one event, headshot)", fmt(dealt), count, tostring(headshot)))
	if math.abs(dealt - 108) > 1 or count ~= 1 or not headshot then
		problem("IMPACT a rocket to the Head dealt " .. fmt(dealt) .. " in " .. count .. " event(s), headshot=" .. tostring(headshot))
	end

	-- A non-explosive round: all of its damage is direct, so all of it takes the multiplier.
	local Ballistics = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Ballistics"))
	Ballistics.RegisterRound("probeDart", { speed = 200, maxSpeed = 200, boostTime = 0, gravityScale = 0, radius = 0.25, maxTime = 1, armTime = 0, explosive = false, impactBonus = 5 })
	local dartDef = { id = "ProbeDart", projectile = "probeDart", damage = 40, splashRadius = 0, headshotMultiplier = 2 }
	for _, case in ipairs({ { name = "Head", y = 1.75, z = 90, want = 90, headshot = true }, { name = "body", y = 0, z = 120, want = 45, headshot = false } }) do
		local dartToken, dartModel, dartHumanoid = dummy(centre + V(40, 0, case.z), "Dart" .. case.name)
		heal(dartModel)
		dartHumanoid:SetAttribute("Shield", 100)
		fly(ProjectileService.LaunchRound(nil, dartDef, centre + V(0, case.y, case.z), Vector3.xAxis))
		count, dealt, headshot = eventsFor(dartToken)
		say(string.format("IMPACT non-explosive dart to the %s (multiplier 2): dealt %s in %d event(s), headshot=%s (want %d, one event, headshot=%s)", case.name, fmt(dealt), count, tostring(headshot), case.want, tostring(case.headshot)))
		if math.abs(dealt - case.want) > 1 or count ~= 1 or headshot ~= case.headshot then
			problem("IMPACT the dart to the " .. case.name .. " dealt " .. fmt(dealt) .. " in " .. count .. " event(s), headshot=" .. tostring(headshot))
		end
	end

	-- Homing (a balance decision of claude-f0's rests on this): the slipper steers at the ROOT, so on
	-- a standing target it strikes the torso even when aimed at the head. The same shot with the
	-- steer off meets the head (so the aim, not the drop, is what's being measured), and a planted
	-- fault, a steer that aims at heads, must read as a headshot, or this line proves nothing. A
	-- peeker whose head is all that shows takes a headshot only because the round meets it first;
	-- from range the homing round follows the root into the cover.
	local homing = Ballistics.Rounds.homingSlipper
	if homing then
		local homingDef = { id = "GrandmasSlipperLauncher", projectile = "homingSlipper", damage = 90, splashRadius = 0, headshotMultiplier = 2 }
		local function shoot(name, from, at)
			local tokenH, modelH, humanoidH = dummy(at, name)
			heal(modelH)
			humanoidH:SetAttribute("Shield", 400)
			-- Aimed at the head centre, raised by the drop over the range, so a shot that isn't
			-- steered arrives at head height.
			local range = (at - from).Magnitude
			local drop = 0.5 * GRAVITY * (homing.gravityScale or 0) * (range / homing.speed) ^ 2
			fly(ProjectileService.LaunchRound(nil, homingDef, from, (at + V(0, 1.6 + drop, 0) - from).Unit))
			return eventsFor(tokenH)
		end
		local homingCases = {}
		local function homingCase(label, wantCount, wantHeadshot, count, dealt, headshot)
			local ok = count == wantCount and (wantCount == 0 or headshot == wantHeadshot)
			say(string.format("IMPACT homing %s: %d event(s), dealt %s, headshot=%s (want %d event(s)%s)", label, count, fmt(dealt), tostring(headshot),
				wantCount, wantCount > 0 and (", headshot=" .. tostring(wantHeadshot)) or ""))
			if not ok then
				problem("IMPACT homing " .. label .. " came out wrong (see its line)")
			end
			table.insert(homingCases, ok)
		end
		local lane2 = centre + V(0, 0, 150)
		homingCase("slipper at a standing target from 60 studs, aimed at the head", 1, false, shoot("HomingBody", lane2 + V(-60, 3, 0), lane2))
		local steer = homing.steer
		homing.steer = nil
		homingCase("the same shot with the steer OFF (control: the path meets the head)", 1, true, shoot("HomingNoSteer", lane2 + V(-60, 3, 30), lane2 + V(0, 0, 30)))
		-- The planted fault: the real steer, fed roots lifted to head height.
		homing.steer = function(entry, dt, api)
			return steer(entry, dt, {
				Targets = function(position, range, except)
					local lifted = {}
					for _, target in ipairs(api.Targets(position, range, except)) do
						table.insert(lifted, { root = { Position = target.root.Position + V(0, 1.6, 0) }, humanoid = target.humanoid })
					end
					return lifted
				end,
			})
		end
		homingCase("the same shot with a steer that aims at HEADS (planted fault: must be caught)", 1, true, shoot("HomingFault", lane2 + V(-60, 3, 60), lane2 + V(0, 0, 60)))
		homing.steer = steer
		-- A peeker: a wall to the neck in front of the target.
		block("PeekWall", V(1, 2, 6), lane2 + V(-1.5, 0, 90))
		homingCase("peeker (wall to the neck), head shot from 9 studs", 1, true, shoot("HomingPeekerNear", lane2 + V(-9, 1.6, 90), lane2 + V(0, 0, 90)))
		block("PeekWall", V(1, 2, 6), lane2 + V(-1.5, 0, 120))
		homingCase("peeker (wall to the neck), homing shot from 60 studs (follows the root into the wall)", 0, false, shoot("HomingPeekerFar", lane2 + V(-60, 3, 120), lane2 + V(0, 0, 120)))
	else
		say("IMPACT homing: homingSlipper not registered, homing cases skipped")
	end
end

--------------------------------------------------------------------------------
-- DUD: a 40mm into a wall at point blank
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(-200, 0, 200)
	block("ProbeGround", V(60, 1, 60), centre - V(0, 3.5, 0))
	block("ProbeWall", V(1, 12, 20), CFrame.new(centre + V(5, 0, 0)))
	local entry = ProjectileService.LaunchRound(nil, grenadeDef, centre, Vector3.xAxis)
	local becameBody, burstAt, steps = nil, nil, 0
	repeat
		ProjectileService.Step(DT)
		steps += 1
		if entry.body and not becameBody then
			becameBody = entry.age
		end
	until not ProjectileService.Peek(entry.id) or steps > 300
	burstAt = entry.age
	local where = entry.body and entry.body.position or entry.position
	say(string.format("DUD 40mm 5 studs from a wall: became a dud at %.2fs, burst at %.2fs, %.1f studs back from the wall",
		becameBody or -1, burstAt, 5 - (where.X - centre.X)))
	if not becameBody then
		problem("DUD the unarmed 40mm burst on contact")
	elseif burstAt < becameBody + 0.7 then
		problem("DUD the dud popped too soon")
	end

	local armed = ProjectileService.LaunchRound(nil, grenadeDef, centre + V(-30, 0, 0), Vector3.xAxis)
	steps = 0
	repeat
		ProjectileService.Step(DT)
		steps += 1
	until not ProjectileService.Peek(armed.id) or steps > 300
	say(string.format("DUD armed 40mm from 35 studs: burst at %.2fs, dud=%s", armed.age, tostring(armed.body ~= nil)))
	if armed.body then
		problem("DUD an armed 40mm bounced instead of bursting")
	end
end

--------------------------------------------------------------------------------
-- BOUNCE: a frag dropped and thrown on a floor
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(0, 0, -200)
	block("ProbeGround", V(200, 2, 200), centre - V(0, 1, 0))
	local spec = Ballistics.Throwables.CookedCoconut
	-- Dropped from 10 studs up: the first bounce should reach about restitution^2 of the drop.
	local drop = ProjectileService.SpawnThrown(nil, nil, "CookedCoconut", spec, centre + V(0, 10 + spec.radius, 0), Vector3.zero, 0)
	local apex, bounced, lowest, restAt = 0, false, math.huge, nil
	local lastY = drop.body.position.Y
	local rising = false
	local firstApex = nil
	for _ = 1, math.floor(3 / DT) do
		ProjectileService.Step(DT)
		if not ProjectileService.Peek(drop.id) then
			break
		end
		local y = drop.body.position.Y - spec.radius - centre.Y
		lowest = math.min(lowest, y)
		if y > lastY - spec.radius - centre.Y + 1e-4 then
			rising = true
		elseif rising and not firstApex then
			firstApex = lastY - spec.radius - centre.Y
		end
		lastY = drop.body.position.Y
		if drop.body.resting and not restAt then
			restAt = drop.age
		end
	end
	local expected = 10 * spec.restitution * spec.restitution
	say(string.format("BOUNCE frag dropped 10 studs: first bounce apex %s (restitution^2 predicts %.2f), lowest %.3f, rested at %s",
		firstApex and fmt(firstApex) or "none", expected, lowest, restAt and fmt(restAt) .. "s" or "never"))
	if not firstApex or math.abs(firstApex - expected) > 0.25 then
		problem("BOUNCE first bounce apex doesn't match restitution")
	end
	if lowest < -0.05 then
		problem("BOUNCE the frag sank " .. fmt(-lowest) .. " into the floor")
	end
	ProjectileService.Clear()

	-- Thrown flat along the floor from head height: where it rests and when it goes off.
	local head = centre + V(-40, 5, 0)
	local velocity = Ballistics.ThrowVelocity(spec, head, head + V(100, 12, 0), nil)
	local thrown = ProjectileService.SpawnThrown(nil, nil, "CookedCoconut", spec, Ballistics.ThrowOrigin(head, velocity.Unit), velocity, 0)
	local contacts, restAt2, steps = 0, nil, 0
	repeat
		ProjectileService.Step(DT)
		steps += 1
		if thrown.body.resting and not restAt2 then
			restAt2 = thrown.age
		end
	until not ProjectileService.Peek(thrown.id) or steps > 600
	contacts = thrown.contacts
	say(string.format("BOUNCE frag thrown: %d contacts, rested at %s, %.1f studs out, burst at %.2fs (fuse %.2f)", contacts,
		restAt2 and fmt(restAt2) .. "s" or "never", thrown.body.position.X - head.X, thrown.age, spec.fuse))
	if math.abs(thrown.age - spec.fuse) > DT * 1.5 then
		problem("BOUNCE the frag's fuse ran " .. fmt(thrown.age) .. "s")
	end
	if not restAt2 then
		problem("BOUNCE the thrown frag never came to rest before its fuse")
	end
end

--------------------------------------------------------------------------------
-- SMOKE: line of sight through a cloud over its life
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(200, 0, 200)
	local spec = Ballistics.Throwables.LowkeyLatte
	local startClock = ProjectileService.Clock()
	ProjectileService.AddCloud(centre, "LowkeyLatte", startClock)
	local across = { centre - V(40, 0, 0), centre + V(40, 0, 0) }
	local edge = { centre - V(40, 0, spec.smokeRadius - 1), centre + V(40, 0, spec.smokeRadius - 1) }
	local inside = { centre, centre + V(4, 0, 0) }
	local out = { centre, centre + V(40, 0, 0) }
	local rows = {}
	local elapsed = 0
	for _, at in ipairs({ 0.3, 1.0, 2.2, 8, 16.5, 18.5, 19.5, 21 }) do
		while elapsed < at do
			ProjectileService.Step(0.1)
			elapsed += 0.1
		end
		table.insert(rows, string.format("t=%.1f across=%s edge=%s near-inside=%s inside-out=%s", at,
			tostring(ProjectileService.SmokeBlocks(across[1], across[2])), tostring(ProjectileService.SmokeBlocks(edge[1], edge[2])),
			tostring(ProjectileService.SmokeBlocks(inside[1], inside[2])), tostring(ProjectileService.SmokeBlocks(out[1], out[2]))))
	end
	for _, row in ipairs(rows) do
		say("SMOKE " .. row)
	end
	local blockedMid = rows[4]:find("across=true", 1, true) ~= nil
	local clearLate = rows[8]:find("across=false", 1, true) ~= nil
	if not blockedMid then
		problem("SMOKE a full cloud didn't hide a line straight through it")
	end
	if not clearLate then
		problem("SMOKE a finished cloud still hides things")
	end
	ProjectileService.Clear()
end

--------------------------------------------------------------------------------
-- COST
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(0, 600, 0)
	local rng = Random.new(7)
	for _ = 1, 200 do
		local direction = V(rng:NextNumber(-1, 1), rng:NextNumber(-0.2, 0.4), rng:NextNumber(-1, 1)).Unit
		ProjectileService.LaunchRound(nil, rocketDef, centre, direction)
	end
	local started = os.clock()
	for _ = 1, 60 do
		ProjectileService.Step(DT)
	end
	local roundsMs = (os.clock() - started) / 60 * 1000
	ProjectileService.Clear()

	local floorAt = ORIGIN + V(-400, 0, -400)
	block("ProbeGround", V(300, 2, 300), floorAt - V(0, 1, 0))
	local frag = Ballistics.Throwables.CookedCoconut
	for index = 1, 100 do
		local velocity = V(rng:NextNumber(-40, 40), rng:NextNumber(10, 40), rng:NextNumber(-40, 40))
		local entry = ProjectileService.SpawnThrown(nil, nil, "CookedCoconut", frag, floorAt + V(rng:NextNumber(-60, 60), 5, rng:NextNumber(-60, 60)), velocity, 0)
		entry.fuseAt = 99
	end
	started = os.clock()
	for _ = 1, 120 do
		ProjectileService.Step(DT)
	end
	local bodiesMs = (os.clock() - started) / 120 * 1000
	local _, bodies = ProjectileService.Counts()
	ProjectileService.Clear()
	say(string.format("COST 200 rockets in flight: %.3f ms/step | 100 bouncing grenades (%d still live): %.3f ms/step", roundsMs, bodies, bodiesMs))
	if roundsMs > 4 or bodiesMs > 4 then
		problem("COST a step costs more than 4 ms")
	end
end

--------------------------------------------------------------------------------
-- DRIVER: nobody throws from the wheel; a passenger can
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(600, 0, 600)
	block("ProbeGround", V(60, 2, 60), centre - V(0, 1, 0))
	local CombatService = require(Modules:WaitForChild("CombatService"))
	-- A stand-in with both spellings: `Character` is what a Player has (CombatService.IsDriving
	-- reads it), `character` what a bot record has (Combatants reads it).
	local function rider(name, seatClass, offset)
		local token, model = dummy(centre + offset, name)
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") then
				part.Anchored = false
			end
		end
		token.Character = model
		local seat = Instance.new(seatClass)
		seat.Size = V(2, 1, 2)
		seat.CFrame = CFrame.new(centre + offset - V(0, 2, 0))
		seat.Anchored = true
		seat.Parent = lane
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local ok, err = pcall(function()
			seat:Sit(humanoid)
		end)
		task.wait(0.2)
		local seated = humanoid.SeatPart == seat
		return token, seated, ok and "" or tostring(err)
	end
	local driver, driverSeated, driverErr = rider("Driver", "VehicleSeat", V(-10, 5, 0))
	local passenger, passengerSeated = rider("Passenger", "Seat", V(10, 5, 0))
	say(string.format("DRIVER seats taken in edit mode: driver %s, passenger %s %s", tostring(driverSeated), tostring(passengerSeated), driverErr))
	if driverSeated and passengerSeated then
		local driverThrew = ProjectileService.ThrowFromPlayer(driver, "CookedCoconut", centre + V(0, 0, 20))
		local passengerThrew = ProjectileService.ThrowFromPlayer(passenger, "CookedCoconut", centre + V(0, 0, 20))
		say(string.format("DRIVER IsDriving driver=%s passenger=%s; throw allowed: driver=%s passenger=%s",
			tostring(CombatService.IsDriving(driver)), tostring(CombatService.IsDriving(passenger)), tostring(driverThrew), tostring(passengerThrew)))
		if driverThrew then
			problem("DRIVER a vehicle's driver could throw a grenade")
		end
		if not passengerThrew then
			problem("DRIVER a passenger couldn't throw a grenade")
		end
	else
		say("DRIVER Seat:Sit didn't take in edit mode; the driver refusal is checked by the client and server code paths only")
	end
	ProjectileService.Clear()
end

--------------------------------------------------------------------------------
-- CREATIVE: the creative arsenal's kinds fly as designed, and a client replay follows the server
--------------------------------------------------------------------------------
do
	require(Shared:WaitForChild("WeaponData"))
	local centre = ORIGIN + V(600, 0, -600)
	block("ProbeGround", V(160, 2, 160), centre - V(0, 1, 0))

	-- Toast: the launch velocity carries the upward kick, and it bursts on the first thing it touches.
	local toast = Ballistics.Rounds.lobbedToast
	if toast then
		local direction = V(1, 0.2, 0).Unit
		local entry = ProjectileService.LaunchRound(nil, { id = "ProbeToast", projectile = "lobbedToast", damage = 40, splashRadius = 9 }, centre + V(-40, 4, 0), direction)
		local lift = entry.body and (entry.body.velocity.Y - direction.Y * toast.speed) or 0
		local steps = 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
		until not ProjectileService.Peek(entry.id) or steps > 400
		say(string.format("CREATIVE lobbedToast: launch lift %.1f studs/s (want 22), body motion=%s, gone after %.2fs with %d contacts (want 1: it bursts on the first touch)",
			lift, tostring(entry.body ~= nil), entry.age, entry.contacts))
		if math.abs(lift - 22) > 0.5 or entry.contacts ~= 1 then
			problem("CREATIVE lobbedToast didn't lift 22 or didn't burst on its first contact")
		end
	else
		say("CREATIVE lobbedToast: kind not registered")
	end

	-- Disc: glances off the first wall (becoming a bouncing body), then cuts the next body it meets.
	local disc = Ballistics.Rounds.ricochetDisc
	if disc then
		-- Fired at the wall at an angle from 2.5 studs up, so the glance (velocity mirrored in x, then
		-- x0.6) sends it back across at head height to a stand-in placed on the reflected line, 0.3 s
		-- after the bounce. (Launched from 1 stud up it skimmed the plate first and stopped there.)
		block("ProbeWall", V(1, 12, 40), CFrame.new(centre + V(20, 4, 30)))
		local victimToken, victimModel, victimHumanoid = dummy(centre + V(6, 0, 47), "DiscVictim")
		heal(victimModel)
		local entry = ProjectileService.LaunchRound(nil, { id = "ProbeDisc", projectile = "ricochetDisc", damage = 55, splashRadius = 0 }, centre + V(-10, 2.5, 20), V(1, 0, 0.5).Unit)
		local bounced, steps = nil, 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
			if entry.body and not bounced then
				bounced = entry.age
			end
		until not ProjectileService.Peek(entry.id) or steps > 300
		say(string.format("CREATIVE ricochetDisc: became a bouncing body at %s (want after hitting the wall ~0.27s), gone after %.2fs, victim behind the bounce 100 -> %.0f HP",
			bounced and fmt(bounced) .. "s" or "never", entry.age, victimHumanoid.Health))
		if not bounced then
			problem("CREATIVE ricochetDisc didn't glance off the wall")
		end
		if victimHumanoid.Health >= 100 then
			problem("CREATIVE ricochetDisc didn't cut the stand-in on its reflected line")
		end
	else
		say("CREATIVE ricochetDisc: kind not registered")
	end

	-- Slipper: the server's steer and a client replay (Ballistics.FreeStep with a client-style
	-- Targets over the same characters) stepped side by side with the same dt: how far apart.
	local slipper = Ballistics.Rounds.homingSlipper
	if slipper then
		local start = centre + V(-30, 6, -40)
		local targetToken, targetModel = dummy(start + V(50, 0, 9), "SlipperTarget")
		local direction = Vector3.xAxis
		local entry = ProjectileService.LaunchRound(nil, { id = "ProbeSlipper", projectile = "homingSlipper", damage = 60, splashRadius = 0 }, start, direction)
		local replay = { spec = slipper, age = 0, position = start, velocity = direction * slipper.speed, owner = nil }
		local clientApi = {}
		function clientApi.Targets(position, range, except)
			local found = {}
			for _, model in ipairs(lane:GetChildren()) do
				if model:IsA("Model") and model ~= except then
					local humanoid = model:FindFirstChildOfClass("Humanoid")
					local root = humanoid and humanoid.Health > 0 and model:FindFirstChild("HumanoidRootPart")
					if root and (root.Position - position).Magnitude <= range then
						table.insert(found, { root = root, humanoid = humanoid })
					end
				end
			end
			table.sort(found, function(a, b)
				return (a.root.Position - position).Magnitude < (b.root.Position - position).Magnitude
			end)
			return found
		end
		local worst, samples, turned = 0, 0, 0
		for _ = 1, 60 do
			ProjectileService.Step(DT)
			local live = ProjectileService.Peek(entry.id)
			if not live then
				break
			end
			replay.age += DT
			replay.position, replay.velocity = Ballistics.FreeStep(replay, DT, GRAVITY, clientApi)
			worst = math.max(worst, (live.position - replay.position).Magnitude)
			samples += 1
			turned = math.deg(live.turned or 0)
		end
		say(string.format("CREATIVE homingSlipper: server vs client replay over %d steps: worst gap %.3f studs (want < 0.5), server turned %.1f deg toward a target 10 deg off its line (cap 20)",
			samples, worst, turned))
		if worst > 0.5 then
			problem("CREATIVE homingSlipper replay diverges " .. fmt(worst) .. " studs from the server")
		end
		if turned < 3 then
			problem("CREATIVE homingSlipper didn't turn toward the target")
		end
		heal(targetModel)
		ProjectileService.Clear()
	else
		say("CREATIVE homingSlipper: kind not registered")
	end

	-- Every registered kind has a model: never nil, always at least one part.
	local kinds = {}
	for kind in pairs(Ballistics.Rounds) do
		local model = ThrowableModels.Round(kind, 1)
		local parts = model and #model:GetChildren() or 0
		table.insert(kinds, string.format("%s:%d parts, spin %s", kind, parts, ThrowableModels.SpinOf(kind)))
		if not model or parts == 0 then
			problem("CREATIVE round kind " .. kind .. " has no model")
		end
		if model then
			model:Destroy()
		end
	end
	table.sort(kinds)
	say("CREATIVE models for every kind: " .. table.concat(kinds, " | "))
end

--------------------------------------------------------------------------------
-- LOOT: a throwable dropped on the floor is a real pickup with the item's model on its pad
--------------------------------------------------------------------------------
do
	local LootService = require(Modules:WaitForChild("LootService"))
	local centre = ORIGIN + V(-600, 0, 600)
	block("ProbeGround", V(40, 2, 40), centre - V(0, 1, 0))
	for _, id in ipairs({ "CookedCoconut", "LowkeyLatte" }) do
		local ok, err = pcall(function()
			LootService.DropItem(id, centre + V(0, 1, 0), 2)
		end)
		local loot = workspace:FindFirstChild("Loot")
		local found, parts, amount = nil, 0, nil
		if loot then
			for _, d in ipairs(loot:GetDescendants()) do
				if d:IsA("BasePart") and d:GetAttribute("ItemId") == id then
					found = d
					amount = d:GetAttribute("Amount")
					for _, child in ipairs(d:GetChildren()) do
						if child:IsA("BasePart") then
							parts += 1
						end
					end
					break
				end
			end
		end
		say(string.format("LOOT %s dropped: ok=%s%s, pickup found=%s, amount=%s, model parts on the pad %d", id, tostring(ok), ok and "" or (" (" .. tostring(err) .. ")"),
			tostring(found ~= nil), tostring(amount), parts))
		if not ok or not found or parts < 5 then
			problem("LOOT " .. id .. " didn't become a pickup with its model")
		end
		if found then
			found:Destroy()
		end
	end
	pcall(LootService.Clear)
end

--------------------------------------------------------------------------------
-- SPLATCOLOR: a hit's splat carries the rank of the gun that dealt it, decided on the server
--------------------------------------------------------------------------------
do
	local HitSplatService = require(Modules:WaitForChild("HitSplatService"))
	local ItemData = require(Shared:WaitForChild("ItemData"))
	local WeaponData = require(Shared:WaitForChild("WeaponData"))
	local sample = { "PawnshopNine", "RustbeltMarshal", "DoomscrollSMG", "TouchGrassScout", "RatioPDW", "CappuccinaLauncher",
		"ReceiptPrinterLMG", "QuietHours", "AdminOverride" }
	local function check(label, lookup)
		local wrong = {}
		local seen = {}
		for _, id in ipairs(sample) do
			local def = WeaponData.Get(id)
			if def then
				local got = lookup(id)
				seen[#seen + 1] = string.format("%s=%s", id, tostring(got))
				if got ~= def.rarity then
					table.insert(wrong, string.format("%s: payload %s, gun %s", id, tostring(got), tostring(def.rarity)))
				end
			end
		end
		return wrong, seen
	end
	local wrong, seen = check("real", HitSplatService.RarityOf)
	say(string.format("SPLATCOLOR %d guns sampled: %s; %d wrong", #seen, table.concat(seen, " "), #wrong))
	if #wrong > 0 then
		problem("SPLATCOLOR payload rarity differs from the gun's: " .. table.concat(wrong, "; "))
	end
	local coconut = HitSplatService.RarityOf("CookedCoconut")
	local nothing = HitSplatService.RarityOf("NoSuchThing")
	say(string.format("SPLATCOLOR a thrown item: CookedCoconut=%s (ItemData says %s); an unknown id: %s (want nil, drawn plain red)",
		tostring(coconut), tostring(ItemData.Get("CookedCoconut") and ItemData.Get("CookedCoconut").rarity), tostring(nothing)))
	if coconut ~= (ItemData.Get("CookedCoconut") and ItemData.Get("CookedCoconut").rarity) or nothing ~= nil then
		problem("SPLATCOLOR item or unknown-id rarity is wrong")
	end
	-- The payload as sent: rarity in slot 5, false when unknown.
	local payload = HitSplatService.Payload(workspace, nil, true, false, "QuietHours")
	local blank = HitSplatService.Payload(workspace, nil, false, false, "NoSuchThing")
	say(string.format("SPLATCOLOR payload slot 5: QuietHours -> %s, unknown -> %s", tostring(payload[5]), tostring(blank[5])))
	if payload[5] ~= WeaponData.Get("QuietHours").rarity or blank[5] ~= false then
		problem("SPLATCOLOR the payload doesn't carry the rarity in slot 5")
	end
	-- Planted fault: a lookup that says Rare for everything must be caught by the same comparison.
	local planted = check("planted", function()
		return "Rare"
	end)
	say(string.format("SPLATCOLOR planted fault (everything Rare): %d of %d flagged (must be caught)", #planted, #seen))
	if #planted < #seen - 1 then
		problem("SPLATCOLOR the planted wrong rarity wasn't caught")
	end
end

--------------------------------------------------------------------------------
-- SCORCH: the mark a blast leaves lies on its surface and stays with it (client ExplosiveFx)
--------------------------------------------------------------------------------
do
	local okFx, ExplosiveFx = pcall(function()
		return require(game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("ExplosiveFx"))
	end)
	if not okFx or type(ExplosiveFx) ~= "table" then
		say("SCORCH ExplosiveFx couldn't be required here (" .. tostring(ExplosiveFx) .. "); not checked")
	else
		ExplosiveFx.Paused = true
		local centre = ORIGIN + V(1000, 0, 1000)
		block("ScorchGround", V(60, 2, 60), centre - V(0, 1, 0))
		local function marks()
			local list = {}
			for _, child in ipairs(ExplosiveFx.Folder():GetChildren()) do
				if child.Name == "Scorch" then
					table.insert(list, child)
				end
			end
			return list
		end
		-- A mark is floating when nothing solid lies within 0.6 under it along its own normal (the
		-- scorch is a thin cylinder whose axis, its X, is the surface normal).
		local floatParams = RaycastParams.new()
		floatParams.FilterType = Enum.RaycastFilterType.Exclude
		floatParams.FilterDescendantsInstances = { ExplosiveFx.Folder() }
		local function floating(mark)
			return workspace:Raycast(mark.Position, -mark.CFrame.RightVector * 0.6, floatParams) == nil
		end

		-- 1. A blast on a floor 12 up: one mark, on that floor, not on the ground below.
		local floor = block("UpperFloor", V(24, 1, 24), centre + V(0, 12, 0))
		ExplosiveFx.Clear()
		ExplosiveFx.Explosion(centre + V(0, 12.5, 0), Vector3.yAxis, "rocket", 14)
		ExplosiveFx.Advance(0.1)
		local list = marks()
		local height = list[1] and (list[1].Position.Y - centre.Y) or -1
		say(string.format("SCORCH blast on a floor 12 up: %d mark(s), at y %.2f (floor top 12.5), floating=%s", #list, height, tostring(list[1] ~= nil and floating(list[1]))))
		if #list ~= 1 or math.abs(height - 12.5) > 0.2 or floating(list[1]) then
			problem("SCORCH the upper-floor mark isn't lying on that floor")
		end

		-- 2. The floor breaks: the mark goes with it, the same frame.
		floor:Destroy()
		ExplosiveFx.Advance(1 / 60)
		list = marks()
		say(string.format("SCORCH the floor destroyed: %d mark(s) left", #list))
		if #list ~= 0 then
			problem("SCORCH the mark outlived the floor it lay on")
		end

		-- 3. Planted fault: marks that don't follow their surface. The same blast then leaves a mark
		-- hanging where the floor was, and this check has to say so, or it proves nothing.
		ExplosiveFx.Clear()
		local floor2 = block("UpperFloor2", V(24, 1, 24), centre + V(40, 12, 0))
		ExplosiveFx.MarksFollow = false
		ExplosiveFx.Explosion(centre + V(40, 12.5, 0), Vector3.yAxis, "rocket", 14)
		ExplosiveFx.MarksFollow = true
		ExplosiveFx.Advance(0.1)
		floor2:Destroy()
		ExplosiveFx.Advance(1 / 60)
		list = marks()
		local caught = #list == 1 and floating(list[1])
		say(string.format("SCORCH planted fault (marks not following their surface): %d mark(s) left, floating=%s (must be caught)", #list, tostring(list[1] ~= nil and floating(list[1]))))
		if not caught then
			problem("SCORCH the planted floating mark wasn't caught")
		end

		-- 4. On a wide moving part (a vehicle's body): the mark rides with it.
		ExplosiveFx.Clear()
		local body = block("VehicleBody", V(12, 2, 6), centre + V(-40, 3, 0))
		ExplosiveFx.Explosion(centre + V(-40, 4, 0), Vector3.yAxis, "grenade", 11)
		ExplosiveFx.Advance(0.1)
		local first = marks()[1]
		local before = first and first.Position or nil
		body.CFrame = body.CFrame + V(0, 0, 20)
		ExplosiveFx.Advance(1 / 60)
		local after = marks()[1] and marks()[1].Position or nil
		local moved = (before and after) and (after - before) or Vector3.zero
		say(string.format("SCORCH on a vehicle body that then moved (0, 0, 20): the mark moved (%.1f, %.1f, %.1f)", moved.X, moved.Y, moved.Z))
		if (moved - V(0, 0, 20)).Magnitude > 0.05 then
			problem("SCORCH the mark didn't ride with the part it lies on")
		end
		ExplosiveFx.Clear()
		ExplosiveFx.Paused = false
	end
end

--------------------------------------------------------------------------------
-- STICKY: the Clingy Crumpet sticks to what it hits, rides with it, and blows after its fuse
--------------------------------------------------------------------------------
do
	local centre = ORIGIN + V(800, 0, 800)
	local spec = Ballistics.Throwables.ClingyCrumpet
	if not spec then
		problem("STICKY no Ballistics.Throwables.ClingyCrumpet")
	else
		local CombatService = require(Modules:WaitForChild("CombatService"))
		block("StickyGround", V(80, 2, 80), centre - V(0, 1, 0))

		-- 1. Into a wall: it sticks where it hit, a radius off the face, and its fuse starts then.
		local wall = block("StickyWall", V(1, 12, 12), CFrame.new(centre + V(20, 6, 0)))
		local entry = ProjectileService.SpawnThrown(nil, nil, "ClingyCrumpet", spec, centre + V(0, 4, 0), V(90, 6, 0), 0)
		local steps = 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
		until entry.stuck or entry.done or steps > 180
		local stuckTo = entry.stuck and entry.stuck.part
		local gap = entry.stuck and ((wall.Position.X - 0.5) - entry.body.position.X) or math.huge
		local fuseIn = entry.fuseAt and (entry.fuseAt - entry.age) or -1
		say(string.format("STICKY thrown at a wall: stuck after %d steps to %s, centre %.2f off the wall face (radius %.2f), fuse in %.2fs (want %.1f)",
			steps, stuckTo and stuckTo.Name or "nothing", gap, spec.radius, fuseIn, spec.fuse))
		if stuckTo ~= wall or math.abs(gap - spec.radius) > 0.15 or math.abs(fuseIn - spec.fuse) > 0.05 then
			problem("STICKY didn't stick to the wall the way it should")
		end

		-- 2. The wall moves: the crumpet goes with it.
		local before = entry.body.position
		wall.CFrame = wall.CFrame + V(0, 3, 5)
		ProjectileService.Step(DT)
		local delta = entry.body.position - before
		say(string.format("STICKY the wall moved by (0, 3, 5): the crumpet moved by (%.2f, %.2f, %.2f)", delta.X, delta.Y, delta.Z))
		if (delta - V(0, 3, 5)).Magnitude > 0.05 then
			problem("STICKY didn't ride with the part it stuck to")
		end

		-- 3. Stuck to a body: it comes along as the body moves, the fuse ends in a blast, and whoever
		-- wears it takes the full direct hit in one event.
		-- The stand-in stands with its root 3 up, legs above the plate; the throw is flat at root height.
		local wearerToken, wearerModel, wearerHumanoid = dummy(centre + V(20, 3, 40), "StickyWearer")
		heal(wearerModel)
		wearerHumanoid:SetAttribute("Shield", 400)
		local dealtList = {}
		CombatService.OnDamage(function(_, victim, dealt)
			if victim == wearerToken then
				table.insert(dealtList, dealt)
			end
		end)
		local onBody = ProjectileService.SpawnThrown(nil, nil, "ClingyCrumpet", spec, centre + V(0, 3.5, 40), V(90, 8, 0), 0)
		steps = 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
		until onBody.stuck or onBody.done or steps > 180
		local limb = onBody.stuck and onBody.stuck.part
		local wornBy = limb and limb:FindFirstAncestorOfClass("Model")
		local ageAtStick = onBody.age
		for _ = 1, 30 do
			for _, part in ipairs(wearerModel:GetChildren()) do
				if part:IsA("BasePart") then
					part.CFrame = part.CFrame + V(0, 0, 0.2)
				end
			end
			ProjectileService.Step(DT)
		end
		local carried = onBody.stuck and (onBody.body.position.Z - (centre.Z + 40)) or 0
		steps = 0
		repeat
			ProjectileService.Step(DT)
			steps += 1
		until onBody.done or steps > 400
		local total = 0
		for _, dealt in ipairs(dealtList) do
			total += dealt
		end
		say(string.format("STICKY on a body: stuck to %s of %s, carried %.1f studs as the body walked 6, went off %.2fs after sticking; the wearer took %s in %d event(s) (want %d in one)",
			limb and limb.Name or "nothing", wornBy and wornBy.Name or "?", carried, onBody.age - ageAtStick, fmt(total), #dealtList, spec.blastDamage))
		if wornBy ~= wearerModel or carried < 5.5 or #dealtList ~= 1 or math.abs(total - spec.blastDamage) > 1 or math.abs((onBody.age - ageAtStick) - spec.fuse) > 0.05 then
			problem("STICKY on a body came out wrong (see its line)")
		end

		-- 4. The stuck frame the client and the ghost use: +Y along the normal, origin stickOffset off.
		local frame = Ballistics.StuckFrame(V(0, 0, 0), V(1, 0, 0), spec.stickOffset)
		say(string.format("STICKY stuck frame on an X-facing wall: up (%.2f, %.2f, %.2f), origin %.2f off the surface (want %.2f)",
			frame.UpVector.X, frame.UpVector.Y, frame.UpVector.Z, frame.Position.X, spec.stickOffset))
		if (frame.UpVector - V(1, 0, 0)).Magnitude > 0.01 or math.abs(frame.Position.X - spec.stickOffset) > 0.01 then
			problem("STICKY StuckFrame is not upright on the surface")
		end
	end
end

--------------------------------------------------------------------------------
-- MODELS
--------------------------------------------------------------------------------
do
	local function audit(label, model, body)
		local parts = {}
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				table.insert(parts, part)
			end
		end
		-- A part touches another if their world-aligned boxes overlap (expanded by a hair); balls and
		-- cylinders are judged by their boxes, which is generous, so anything reported here is truly
		-- off on its own. (An earlier version read the other part's size along this part's axes, which
		-- called a jam blob against a rotated cylinder lonely.)
		local function bounds(part)
			local cframe, half = part.CFrame, part.Size / 2
			local r = cframe.Rotation
			local extent = V(
				math.abs(r.XVector.X) * half.X + math.abs(r.YVector.X) * half.Y + math.abs(r.ZVector.X) * half.Z,
				math.abs(r.XVector.Y) * half.X + math.abs(r.YVector.Y) * half.Y + math.abs(r.ZVector.Y) * half.Z,
				math.abs(r.XVector.Z) * half.X + math.abs(r.YVector.Z) * half.Y + math.abs(r.ZVector.Z) * half.Z
			)
			return cframe.Position - extent, cframe.Position + extent
		end
		local boxes = {}
		for _, part in ipairs(parts) do
			local low, high = bounds(part)
			boxes[part] = { low = low, high = high }
		end
		local lonely = {}
		for _, part in ipairs(parts) do
			if part.Name ~= "Grip" then
				local touching = false
				local a = boxes[part]
				for _, other in ipairs(parts) do
					if other ~= part and other.Name ~= "Grip" then
						local b = boxes[other]
						if a.low.X <= b.high.X + 0.02 and b.low.X <= a.high.X + 0.02
							and a.low.Y <= b.high.Y + 0.02 and b.low.Y <= a.high.Y + 0.02
							and a.low.Z <= b.high.Z + 0.02 and b.low.Z <= a.high.Z + 0.02 then
							touching = true
							break
						end
					end
				end
				if not touching then
					table.insert(lonely, part.Name)
				end
			end
		end
		local cf, size = model:GetBoundingBox()
		say(string.format("MODELS %s: %d parts, body %s, grip %s, bounds %.2f x %.2f x %.2f, lonely: %s", label, #parts,
			body and body.Name or "none", tostring(model:FindFirstChild("Grip") ~= nil), size.X, size.Y, size.Z,
			#lonely > 0 and table.concat(lonely, ",") or "none"))
		if #lonely > 0 then
			problem("MODELS " .. label .. " has parts touching nothing: " .. table.concat(lonely, ","))
		end
		model:Destroy()
	end
	local ZFight = require(Shared:WaitForChild("ZFight"))

	-- Raw geometry first (ZFight.Enabled = false makes the builder's own pass a no-op): the written
	-- flush pairs at the build check's tolerance and at the pass's wider one, then what the pass would
	-- move or resize on that raw model. All of it must be zero: the models are right by construction,
	-- and the pass inside the builder is a net that must have nothing to do. (The crack's glow strip
	-- once sat 0.048 from its seam: past the 0.045 scan, inside the 0.055 pass, ten parts reshaped.)
	local function rawCheck(label, build)
		ZFight.Enabled = false
		local ok, model = pcall(build)
		ZFight.Enabled = true
		if not ok or not model then
			problem("MODELS " .. label .. " didn't build with the pass off: " .. tostring(model))
			return
		end
		local flush = ZFight.Scan({ model })
		local near = ZFight.Scan({ model }, ZFight.FixTolerance)
		local stats = ZFight.Fix({ model }, { all = true })
		say(string.format("MODELS %s pass off/on: %d flush pairs at %.3f, %d at the pass's %.3f; the pass then moved %d and resized %d of %d parts%s",
			label, #flush, ZFight.Tolerance, #near, ZFight.FixTolerance, stats.moved, stats.resized, stats.parts,
			#near > 0 and (" | " .. table.concat(ZFight.Describe(near, function() return label end, 6), " ; ")) or ""))
		if #flush > 0 or #near > 0 or stats.moved > 0 or stats.resized > 0 then
			problem("MODELS " .. label .. " is not clean by construction (see its pass off/on line)")
		end
		model:Destroy()
	end
	for id in pairs(ThrowableModels.Builders) do
		rawCheck(id, function()
			return (ThrowableModels.Build(id, { anchored = true }))
		end)
	end
	for _, kind in ipairs({ "rocket", "grenade", "ricochetDisc", "homingSlipper", "lobbedToast" }) do
		rawCheck("round " .. kind, function()
			return (ThrowableModels.Round(kind, 1))
		end)
	end

	for id in pairs(ThrowableModels.Builders) do
		local model, body = ThrowableModels.Build(id, { anchored = true })
		if not model then
			problem("MODELS " .. id .. " didn't build")
		else
			-- The build check's own z-fight scan, at its default tolerance: flush pairs on a pickup
			-- flicker, and the loot pass would move parts to fix them, distorting the detail.
			local flush = ZFight.Scan({ model })
			say(string.format("MODELS %s z-fight scan: %d flush pairs%s", id, #flush,
				#flush > 0 and (" | " .. table.concat(ZFight.Describe(flush, function() return id end, 6), " ; ")) or ""))
			if #flush > 0 then
				problem("MODELS " .. id .. " has " .. #flush .. " flush face pairs")
			end
			audit(id, model, body)
		end
		local loose, looseBody = ThrowableModels.Build(id, { anchored = false, scale = 1.25 })
		if loose then
			local welds = 0
			for _, weld in ipairs(loose:GetDescendants()) do
				if weld:IsA("WeldConstraint") and weld.Part0 == looseBody then
					welds += 1
				end
			end
			say("MODELS " .. id .. " unanchored at 1.25: " .. welds .. " welds to the body")
			loose:Destroy()
		end
	end
	for _, kind in ipairs({ "rocket", "grenade" }) do
		local model, body = ThrowableModels.Round(kind, 1)
		if not model then
			problem("MODELS round " .. kind .. " didn't build")
		else
			audit("round " .. kind, model, body)
		end
	end

	-- The rocket's looping whoosh rides on a Sound parented to the Weapons volume group. Sfx makes
	-- that group on demand, so the loop follows the slider even before any gunshot has played.
	local okSfx, sfxOrErr = pcall(function()
		return require(game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts"):WaitForChild("Sfx"))
	end)
	if okSfx and type(sfxOrErr) == "table" and type(sfxOrErr.GroupFor) == "function" then
		local group = sfxOrErr.GroupFor("Weapons")
		say(string.format("SOUND Sfx.GroupFor(\"Weapons\") -> %s (%s), volume %.2f (master x weapons slider)", group and group.Name or "nil",
			group and group.ClassName or "?", group and group.Volume or -1))
		if not (group and group:IsA("SoundGroup")) then
			problem("SOUND Sfx.GroupFor didn't return a SoundGroup")
		end
	else
		say("SOUND Sfx couldn't be required here (" .. tostring(sfxOrErr) .. "); GroupFor not checked")
	end
end

for _, model in ipairs(dummies) do
	Combatants.Unregister(model)
end
if ownMap then
	map:Destroy()
else
	lane:Destroy()
end
ProjectileService.Clear()
say(problems == 0 and "ALL CHECKS PASSED" or (problems .. " PROBLEM(S)"))
