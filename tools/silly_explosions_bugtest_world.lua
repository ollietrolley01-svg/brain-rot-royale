-- The stand-in world for tools/silly_explosions_bugtest_check.py. Plain Lua under lupa, on top of
-- tools/destruct_mocks.lua (values, not rendering; time moves only when a scenario advances it).
--
-- Two halves:
--   client(mock, fxChunk, sillyChunk, soundKeys)  runs the REAL ExplosiveFx and SillyExplosionFx, flat
--                                              ground at y = 0, the camera at the origin; returns the
--                                              client scenarios (C*)
--   wreck(mock, wreckChunk)                    runs the REAL VehicleWreckFx; returns scenarios C9a/C9b
--   hazard(mock, hazardChunk)                  runs a HazardService (main or the pre-change
--                                              one) with CombatService and friends recording every
--                                              call; returns the server scenarios (S1)
--   gun(mock, breakGunChunk)                   one breakGun cut from MountedGuns (S2)
-- A chunk is the module's source compiled by the Python side (lupa), after its Luau-only syntax is
-- rewritten; calling it runs the module body.
--
-- Every scenario returns { ok = bool, text = "what was measured" }. Nothing here judges a finding:
-- the Python side knows which invariants are known to fail on main.

local W = {}

local function fmt(...)
	return string.format(...)
end

--------------------------------------------------------------------------------
-- Client: ExplosiveFx + SillyExplosionFx
--------------------------------------------------------------------------------

-- The shared particle hosts (made once per kind or theme, kept for good) and the effects folder itself.
local HOSTS = { BRR_BlastHost = true, BRR_SillyHost = true, BRR_SplatHost = true }

local function alive(inst)
	if rawget(inst, "__destroyed") then
		return false
	end
	local node = inst.Parent
	while node do
		if node == workspace then
			return true
		end
		node = node.Parent
	end
	return false
end

local function underHost(inst)
	if inst.Name == "BRR_ExplosiveFx" then
		return true
	end
	local node = inst
	while node do
		if HOSTS[node.Name] then
			return true
		end
		node = node.Parent
	end
	return false
end

function W.client(mock, fxChunk, sillyChunk, soundKeys)
	mock.raycast = mock.flatWorld(0, -20)
	local rs = game:GetService("ReplicatedStorage")
	local shared = Instance.new("Folder", rs)
	shared.Name = "Shared"
	for _, n in ipairs({ "Ballistics", "SoundConfig" }) do
		Instance.new("ModuleScript", shared).Name = n
	end
	local scripts = Instance.new("Folder")
	Instance.new("ModuleScript", scripts).Name = "SillyExplosionFx"
	local SoundConfig = {
		Get = function(key)
			return soundKeys[key] and {} or nil
		end,
	}
	local silly
	require = function(m)
		if m.Name == "SillyExplosionFx" then
			return silly
		elseif m.Name == "SoundConfig" then
			return SoundConfig
		end
		return setmetatable({}, { __index = function() return function() return 0 end end })
	end
	silly = sillyChunk()
	script = { Parent = scripts }
	local fx = fxChunk()
	fx.Paused = true
	workspace.CurrentCamera = { CFrame = CFrame.new() }

	-- ExplosiveFx's crowd counter is a local; read it through the upvalue Explosion closes over.
	local function liveBlasts()
		for i = 1, 60 do
			local name, value = debug.getupvalue(fx.Explosion, i)
			if name == nil then
				break
			end
			if name == "liveBlasts" then
				return value
			end
		end
		return nil
	end

	local function mark()
		return #mock.created
	end
	-- What one call made: instances by name, particles emitted.
	local function made(from, emittedBefore)
		local names = {}
		for i = from + 1, #mock.created do
			local n = mock.created[i].Name
			names[n] = (names[n] or 0) + 1
		end
		return names, (mock.emitted or 0) - emittedBefore
	end
	local function leftovers(from)
		local count, names = 0, {}
		for i = from + 1, #mock.created do
			local inst = mock.created[i]
			if alive(inst) and not underHost(inst) then
				count = count + 1
				names[inst.Name] = (names[inst.Name] or 0) + 1
			end
		end
		local list = {}
		for n, c in pairs(names) do
			table.insert(list, n .. " x" .. c)
		end
		table.sort(list)
		return count, table.concat(list, ", ")
	end
	local function run(seconds)
		local steps = math.floor(seconds * 30 + 0.5)
		for _ = 1, steps do
			fx.Advance(1 / 30)
		end
	end
	-- One blast the way ProjectileClient's onDetonate/onImpact/OnWreck draw it.
	local function blast(case, at)
		at = at or Vector3.new(0, 0.3, 0)
		if case.hit then
			fx.Impact(at, Vector3.yAxis, case.weaponId)
		else
			fx.Explosion(at, case.normal == false and nil or Vector3.yAxis, case.kind, case.radius, case.weaponId)
		end
	end
	-- Crowded = drawn light: no rock chunks, no smoke column (ExplosiveFx.Explosion's crowd budget).
	local function probe(at)
		local m, e = mark(), mock.emitted or 0
		fx.Explosion(at or Vector3.new(0, 0.3, 0), Vector3.yAxis, "grenade", 15, "ExplosiveBarrel")
		local names, particles = made(m, e)
		return { debris = names.Debris or 0, column = names.SmokeColumn or 0, particles = particles }
	end

	local S = {}

	-- The blasts every scenario draws from. Radii are the server's: a barrel 15, a mine 10, a
	-- mounted gun's wreck 8, a vehicle wreck 12; a silly launcher's own (any; 11.5 here).
	S.CASES = {
		{ label = "grenade (realistic)", kind = "grenade", radius = 12 },
		{ label = "rocket (realistic)", kind = "rocket", radius = 14 },
		{ label = "frag (realistic)", kind = "frag", radius = 10 },
		{ label = "barrel", kind = "grenade", radius = 15, weaponId = "ExplosiveBarrel" },
		{ label = "mine", kind = "grenade", radius = 10, weaponId = "RotMine" },
		{ label = "mounted gun wreck", kind = "grenade", radius = 8, weaponId = "MountedGunWreck" },
		{ label = "vehicle wreck", kind = "grenade", radius = 12, weaponId = "VehicleWreck", normal = false },
		{ label = "dart hit (Zanzarino)", hit = true, weaponId = "ZanzarinoPikpik" },
	}
	for weaponId, theme in pairs(silly.Weapons) do
		local t = silly.Themes[theme]
		if t and t.hit then
			table.insert(S.CASES, { label = theme .. " hit", hit = true, weaponId = weaponId, theme = theme })
		else
			table.insert(S.CASES, { label = theme .. " blast", kind = "frag", radius = 11.5, weaponId = weaponId, theme = theme })
		end
	end
	table.sort(S.CASES, function(a, b) return a.label < b.label end)

	-- C1: every instance a blast makes is gone once it's over, and both counters are back to 0.
	function S.C1()
		local lines, ok = {}, true
		for _, case in ipairs(S.CASES) do
			local m, e = mark(), mock.emitted or 0
			local good, err = pcall(blast, case)
			if not good then
				ok = false
				table.insert(lines, fmt("  %-22s ERROR %s", case.label, tostring(err)))
			else
				local _, particles = made(m, e)
				-- The blast's own instances; a shared particle host made on a kind's first use isn't one.
				local total = 0
				for i = m + 1, #mock.created do
					if not underHost(mock.created[i]) then
						total = total + 1
					end
				end
				run(40)
				local left, which = leftovers(m)
				local lb, active = liveBlasts(), silly.Active
				if left > 0 or lb ~= 0 or active ~= 0 then
					ok = false
				end
				table.insert(lines, fmt("  %-22s %3d instances, %3d particles; after 40 s: %d left%s, liveBlasts %s, Silly.Active %s",
					case.label, total, particles, left, which ~= "" and (" (" .. which .. ")") or "", tostring(lb), tostring(active)))
			end
		end
		return { ok = ok, text = table.concat(lines, "\n") }
	end

	-- C2: a busy minute (every case, staggered) leaves no count behind, and the next blast is full.
	function S.C2()
		local m = mark()
		for round = 1, 3 do
			for index, case in ipairs(S.CASES) do
				blast(case, Vector3.new(index * 3, 0.3, round * 5))
				run(0.1)
			end
		end
		local peak = liveBlasts()
		run(40)
		local lb, active = liveBlasts(), silly.Active
		local left = leftovers(m)
		local p = probe()
		run(40)
		local ok = lb == 0 and active == 0 and left == 0 and p.debris > 0 and p.column > 0
		return { ok = ok, text = fmt("  %d blasts over %.1f s (liveBlasts peaked at %d); 40 s later: liveBlasts %s, Silly.Active %s, %d instances left; next barrel blast: %d chunks, %d column",
			3 * #S.CASES, 3 * #S.CASES * 0.1, peak, tostring(lb), tostring(active), left, p.debris, p.column) }
	end

	-- C3: interrupted (ProjectileClient's "clear" -> ExplosiveFx.Clear) mid-blast: nothing left,
	-- both counters back to 0.
	function S.C3()
		local m = mark()
		for index, case in ipairs(S.CASES) do
			blast(case, Vector3.new(index * 3, 0.3, 0))
		end
		run(0.3)
		local before, active = liveBlasts(), silly.Active
		fx.Clear()
		local left, which = leftovers(m)
		local lb, activeAfter = liveBlasts(), silly.Active
		local ok = left == 0 and lb == 0 and activeAfter == 0
		return { ok = ok, text = fmt("  %d blasts, 0.3 s in: liveBlasts %d, Silly.Active %d; after Clear: liveBlasts %s, Silly.Active %s, %d instances left%s",
			#S.CASES, before, active, tostring(lb), tostring(activeAfter), left, which ~= "" and (" (" .. which .. ")") or "") }
	end

	-- C4a: the crowd budget works: three real blasts live, the fourth is drawn light.
	function S.C4a()
		local first = probe(Vector3.new(0, 0.3, 0))
		probe(Vector3.new(20, 0.3, 0))
		probe(Vector3.new(40, 0.3, 0))
		local fourth = probe(Vector3.new(60, 0.3, 0))
		run(40)
		local ok = first.debris > 0 and first.column > 0 and fourth.debris == 0 and fourth.column == 0
			and fourth.particles < first.particles
		return { ok = ok, text = fmt("  barrel blast alone: %d chunks, %d column, %d particles; 4th of 4 at once: %d chunks, %d column, %d particles",
			first.debris, first.column, first.particles, fourth.debris, fourth.column, fourth.particles) }
	end

	-- C4b: hit-only rounds (no blast: a dart, a fidget disc, a slipper) never push a real blast into
	-- the crowd look. The Zanzarino Pikpik fires 4.2 darts a second; three land within 0.72 s.
	function S.C4b()
		local base = probe(Vector3.new(0, 0.3, 0))
		run(40)
		local lines, ok = { fmt("  barrel blast, nothing else live: %d chunks, %d column, %d particles", base.debris, base.column, base.particles) }, true
		for _, weaponId in ipairs({ "ZanzarinoPikpik", "FidgetDiscLauncher", "GrandmasSlipperLauncher" }) do
			for shot = 1, 3 do
				fx.Impact(Vector3.new(30 + shot, 1, 0), Vector3.yAxis, weaponId)
				run(1 / 4.2)
			end
			local lb = liveBlasts()
			local p = probe(Vector3.new(0, 0.3, 0))
			if p.debris ~= base.debris or p.column ~= base.column then
				ok = false
			end
			table.insert(lines, fmt("  3 %s hits (0.71 s), then the barrel: liveBlasts was %d -> %d chunks, %d column, %d particles",
				weaponId, lb, p.debris, p.column, p.particles))
			run(40)
		end
		return { ok = ok, text = table.concat(lines, "\n") }
	end

	-- C5: the silly cap (MAX_BLASTS) counts blasts only: any number of hit-only rounds leave the next
	-- silly blast at full detail; MAX_BLASTS live silly blasts drop the next to FAR.
	function S.C5()
		for shot = 1, 10 do
			fx.Impact(Vector3.new(shot, 1, 0), Vector3.yAxis, shot % 2 == 0 and "FidgetDiscLauncher" or "GrandmasSlipperLauncher")
		end
		local afterHits = silly.Active
		local lodHits = silly.LookFor("coffee", Vector3.new(0, 0, 0)).lod
		run(40)
		for index = 1, silly.MAX_BLASTS do
			fx.Explosion(Vector3.new(index * 4, 0.3, 0), Vector3.yAxis, "frag", 11.5, "CappuccinaLauncher")
		end
		local afterBlasts = silly.Active
		local lodFull = silly.LookFor("coffee", Vector3.new(0, 0, 0)).lod
		run(40)
		local ok = afterHits == 0 and lodHits == "full" and afterBlasts == silly.MAX_BLASTS and lodFull == "far"
		return { ok = ok, text = fmt("  10 slipper/fidget hits: Silly.Active %d, next coffee blast's look '%s'; %d coffee blasts live: Silly.Active %d, next '%s'",
			afterHits, lodHits, silly.MAX_BLASTS, afterBlasts, lodFull) }
	end

	-- C6: the theme lookup. Every silly weapon names a theme that exists and is complete; everything
	-- else (the server's hazard ids, junk) gets no theme.
	function S.C6()
		local lines, ok, count = {}, true, 0
		for weaponId, name in pairs(silly.Weapons) do
			count = count + 1
			local theme = silly.Themes[name]
			local complete = theme ~= nil and type(theme.look) == "table" and type(theme.pieces) == "table"
				and type(theme.particles) == "table" and type(theme.sound) == "string" and theme.look.key == name
			if not complete or silly.ThemeFor(weaponId) ~= name then
				ok = false
				table.insert(lines, fmt("  %s -> '%s': theme %s", weaponId, tostring(name), theme and "incomplete" or "MISSING"))
			end
			for piece in pairs(theme and theme.pieces or {}) do
				if not silly.PieceCost[piece] then
					ok = false
					table.insert(lines, fmt("  %s: piece '%s' has no cost", name, piece))
				end
			end
		end
		local others = { "ExplosiveBarrel", "RotMine", "MountedGunWreck", "VehicleWreck", "TralalaThumper", "ZanzarinoPikpik", "", 42, false }
		for _, id in ipairs(others) do
			if silly.ThemeFor(id) ~= nil then
				ok = false
				table.insert(lines, fmt("  %s has a theme", tostring(id)))
			end
		end
		table.insert(lines, 1, fmt("  %d silly weapons resolve to complete themes; %d other ids (hazards, wrecks, junk, nil-ish) resolve to none",
			count, #others + 1))
		if silly.ThemeFor(nil) ~= nil then
			ok = false
		end
		return { ok = ok, text = table.concat(lines, "\n") }
	end

	-- C7: a themed blast's own pieces stay inside EXTRA_BUDGET at full detail (counted as made).
	local PIECE_NAMES = { CoffeeSheet = true, CoffeeDrop = true, MugRing = true, GoldCoin = true, Confetti = true, Ribbon = true,
		ToastCrust = true, ToastFace = true, Butter = true, Slipper = true, SlipperStrap = true, SlipperPom = true,
		SpinnerHub = true, SpinnerLobe = true, DangerRing = true }
	function S.C7()
		local lines, ok = {}, true
		for _, case in ipairs(S.CASES) do
			if case.theme then
				local m = mark()
				blast(case)
				local names = made(m, 0)
				local pieces = 0
				for n, c in pairs(names) do
					if PIECE_NAMES[n] then
						pieces = pieces + c
					end
				end
				if pieces > silly.EXTRA_BUDGET then
					ok = false
				end
				table.insert(lines, fmt("  %-14s %2d pieces made (budget %d), %d meshes on top", case.label, pieces, silly.EXTRA_BUDGET, names.SpecialMesh or 0))
				run(40)
			end
		end
		return { ok = ok, text = table.concat(lines, "\n") }
	end

	-- C8: the danger ring reaches exactly the radius the server sent, and a hit-only round has none.
	function S.C8()
		local lines, ok = {}, true
		for _, case in ipairs(S.CASES) do
			if case.theme then
				local m = mark()
				blast(case)
				run(0.3)
				local ring
				for i = m + 1, #mock.created do
					if mock.created[i].Name == "DangerRing" then
						ring = mock.created[i]
					end
				end
				local want = not case.hit
				if want and (not ring or math.abs(ring.Radius - case.radius) > 1e-6) then
					ok = false
				elseif not want and ring then
					ok = false
				end
				table.insert(lines, fmt("  %-14s %s", case.label, ring and fmt("ring radius %.3f at 0.3 s (server radius %.3f)", ring.Radius, case.radius) or "no danger ring"))
				run(40)
			end
		end
		return { ok = ok, text = table.concat(lines, "\n") }
	end

	S.fx, S.silly, S.liveBlasts = fx, silly, liveBlasts
	return S
end

--------------------------------------------------------------------------------
-- Client: VehicleWreckFx.OnWreck (the vehicle wreck blast on the client)
--------------------------------------------------------------------------------

function W.wreck(mock, wreckChunk)
	local Wreck = wreckChunk()
	local fired = {}
	Wreck.OnWreck = function(model)
		table.insert(fired, { model = model, at = mock.clock })
	end
	local function vehicle(name)
		local model = Instance.new("Model")
		model.Name = name
		rawget(model, "__props").AncestryChanged = mock.signal()
		local chassis = Instance.new("Part", model)
		chassis.Name = "Chassis"
		chassis.Size = Vector3.new(6, 2, 12)
		model.Parent = workspace
		return model
	end
	local S = {}
	-- C9a: seen whole, wrecked in sight (VehicleClient calls SetSmoke every frame within 320 studs):
	-- the blast fires once, on the frame it happens, and never again while it stays a wreck.
	function S.C9a()
		table.clear(fired)
		local car = vehicle("CarInSight")
		for frame = 1, 30 do
			mock.clock = mock.clock + 1 / 30
			Wreck.SetSmoke(car, frame > 10)
		end
		local ok = #fired == 1 and math.abs(fired[1].at - 11 / 30) < 1e-6
		local already = vehicle("AlreadyWrecked")
		Wreck.SetSmoke(already, true)
		Wreck.SetSmoke(already, true)
		ok = ok and #fired == 1
		return { ok = ok, text = fmt("  wrecked in sight on frame 11: %d blast(s)%s; one already a wreck when first seen: %d more",
			#fired, fired[1] and fmt(" at %.3f s", fired[1].at) or "", #fired - 1) }
	end
	-- C9b: seen whole, then out of VehicleClient's 320-stud range (no calls), wrecked out there at
	-- t = 10 s, and driven up to at t = 130 s: does the blast go off two minutes late?
	function S.C9b()
		table.clear(fired)
		mock.clock = 0
		local car = vehicle("CarWreckedFarAway")
		Wreck.SetSmoke(car, false)
		-- 10 s: wrecked, 900 studs away; no SetSmoke calls (VehicleClient.client.lua:748 gates them).
		car:SetAttribute("Wrecked", true)
		mock.clock = 130
		Wreck.SetSmoke(car, true)
		local ok = #fired == 0
		return { ok = ok, text = fmt("  seen whole at 0 s, wrecked out of range at 10 s, back in range at 130 s: %d blast(s)%s",
			#fired, fired[1] and fmt(", at %.0f s (120 s after the wreck)", fired[1].at) or "") }
	end
	return S
end

--------------------------------------------------------------------------------
-- Server: HazardService.explode, main against the pre-change source
--------------------------------------------------------------------------------

function W.hazard(mock, hazardChunk)
	local log = {}
	local function note(line)
		table.insert(log, line)
	end
	local function r3(v)
		return fmt("%.3f", v)
	end
	local victims = {}
	local function root(position)
		return { Position = position }
	end
	local CombatService = {
		InRadius = function(position, radius, exclude)
			note(fmt("InRadius r=%s exclude=%s", r3(radius), tostring(exclude)))
			local found = {}
			for _, v in ipairs(victims) do
				if v.token ~= exclude and (v.root.Position - position).Magnitude <= radius then
					table.insert(found, v)
				end
			end
			return found
		end,
		DealDamage = function(attacker, victim, amount, weaponId, headshot)
			note(fmt("DealDamage by=%s to=%s amount=%s weapon=%s headshot=%s", tostring(attacker), tostring(victim), r3(amount), tostring(weaponId), tostring(headshot)))
		end,
		DamageCompanionsInRadius = function(attacker, position, radius, amount)
			note(fmt("Companions by=%s r=%s amount=%s", tostring(attacker), r3(radius), r3(amount)))
		end,
		DamageStructuresInRadius = function(position, radius, amount)
			note(fmt("Structures r=%s amount=%s", r3(radius), r3(amount)))
		end,
		DamageDestructiblesInRadius = function(position, radius, amount, attacker)
			note(fmt("Destructibles r=%s amount=%s by=%s", r3(radius), r3(amount), tostring(attacker)))
		end,
	}
	local Combatants = { IsPlayer = function(token) return type(token) == "string" and token:sub(1, 1) == "P" end }
	local QuestService = { Progress = function(token, quest, n) note(fmt("Quest %s %s %d", tostring(token), quest, n)) end }
	local ItemModels = {
		Build = function(id)
			local model = Instance.new("Model")
			model.Name = id
			local body = Instance.new("Part", model)
			body.Name = "Body"
			body.CanCollide = false
			local glow = Instance.new("Part", model)
			glow.Name = "Glow"
			return model
		end,
	}
	local stubs = {
		ItemModels = ItemModels, ZFight = { Fix = function() end }, Remotes = mock.RemotesModule,
		-- Required by pc/lag-bug-sweep's HazardService (a mine's ground ray passes through bodies); no body here.
		DefensePlacement = { BodyOf = function() return nil end },
		Combatants = Combatants, CombatService = CombatService, QuestService = QuestService,
		-- Settling hazards on a broken floor: registered at load, not part of a blast.
		DestructibleService = { OnPartBroken = function() end, RestingOn = function() return {} end, SettleDown = function() return false end },
	}
	local rs = game:GetService("ReplicatedStorage")
	local shared = Instance.new("Folder", rs)
	shared.Name = "Shared"
	local modules = Instance.new("Folder")
	for name in pairs(stubs) do
		Instance.new("ModuleScript", shared).Name = name
		Instance.new("ModuleScript", modules).Name = name
	end
	require = function(m)
		return stubs[m.Name] or error("no stub for " .. tostring(m.Name))
	end
	script = { Parent = modules }
	workspace.GetServerTimeNow = function() return mock.clock end
	-- The mine poll: kept, not run (the mock's task.spawn would spin its `while true` forever).
	local poll
	local spawn = task.spawn
	task.spawn = function(fn)
		poll = fn
	end
	math.randomseed(7)
	local Hazard = hazardChunk()
	task.spawn = spawn
	local function pollOnce()
		local wait = task.wait
		local calls = 0
		task.wait = function()
			calls = calls + 1
			if calls > 1 then
				error("stop-poll")
			end
			return 0
		end
		local ok, err = pcall(poll)
		task.wait = wait
		if not ok and not tostring(err):find("stop-poll", 1, true) then
			error(err)
		end
	end
	local map = Instance.new("Folder", workspace)
	map.Name = "Map"

	-- The scene: P1 shoots a barrel at the origin with five people round it (0, 5, 10, 14.9 and
	-- 15.1 studs; the radius is 15) and a second barrel 12 studs off, which goes up in the chain.
	-- Then P2's mine, set off two ways: shot by P3 (P3's kill), and stepped on by B1 (P2's kill,
	-- sparing P2, who stands on it too).
	local S = { log = log }
	function S.run()
		victims = {
			{ token = "B1", root = root(Vector3.new(0, 2.3, 0)) },
			{ token = "P4", root = root(Vector3.new(5, 2.3, 0)) },
			{ token = "B2", root = root(Vector3.new(0, 2.3, 10)) },
			{ token = "P5", root = root(Vector3.new(-14.9, 2.3, 0)) },
			{ token = "P6", root = root(Vector3.new(0, 2.3, -15.1)) },
		}
		local a = Hazard.Barrel(map, CFrame.new(0, 0, 0))
		Hazard.Barrel(map, CFrame.new(12, 0, 0))
		note("-- P1 shoots barrel A")
		Hazard.Damage(a, 60, "P1")
		mock.advance(1)
		note("-- P3 shoots P2's mine")
		local mine = Hazard.Mine(map, Vector3.new(100, 0, 0), "P2")
		mine.Body.CFrame = mine:GetPivot()
		victims = { { token = "P2", root = root(Vector3.new(100, 2.3, 0)) }, { token = "B3", root = root(Vector3.new(104, 2.3, 0)) } }
		Hazard.Damage(mine, 30, "P3")
		mock.advance(1)
		note("-- B1 steps on P2's mine")
		local stepped = Hazard.Mine(map, Vector3.new(200, 0, 0), "P2")
		stepped.Body.CFrame = stepped:GetPivot()
		victims = { { token = "P2", root = root(Vector3.new(200, 2.3, 0)) }, { token = "B1", root = root(Vector3.new(202, 2.3, 0)) } }
		mock.clock = mock.clock + 5
		pollOnce()
		mock.advance(1)
		-- What went to the clients, and what bare Explosions were made.
		local sent = {}
		for _, call in ipairs((mock.remotes.ProjectileFx or { fired = {} }).fired) do
			local info = call[2]
			table.insert(sent, { action = call[1], radius = info.radius, kind = info.kind, weaponId = info.weaponId, position = info.position })
		end
		local explosions = {}
		for _, inst in ipairs(mock.created) do
			if inst.ClassName == "Explosion" then
				table.insert(explosions, { BlastRadius = inst.BlastRadius, BlastPressure = inst.BlastPressure,
					DestroyJointRadiusPercent = inst.DestroyJointRadiusPercent, Position = inst.Position })
			end
		end
		return log, sent, explosions
	end
	return S
end

--------------------------------------------------------------------------------
-- Server: MountedGuns' breakGun, main against the pre-change source
--------------------------------------------------------------------------------

function W.gun(mock, breakGunChunk)
	local log = {}
	local CombatService = {
		ConfirmHit = function(attacker, amount, killed, position, class)
			table.insert(log, fmt("ConfirmHit by=%s amount=%s killed=%s at=(%.2f, %.2f, %.2f) class=%s", tostring(attacker), tostring(amount),
				tostring(killed), position.X, position.Y, position.Z, tostring(class)))
		end,
	}
	local function release(model, why)
		table.insert(log, fmt("release %s %s", model.Name, why))
	end
	local breakGun = breakGunChunk(nil, release, CombatService, mock.RemotesModule)
	local model = Instance.new("Model")
	model.Name = "MountedGun_hmg"
	model.CFrame = CFrame.new(50, 0, 50)
	local base = Instance.new("Part", model)
	base.Name = "BasePlate"
	base.CFrame = CFrame.new(50, 0.1, 50)
	model.PrimaryPart = base
	local prompt = Instance.new("ProximityPrompt", base)
	prompt.Name = "GunnerPrompt"
	prompt.Enabled = true
	local pitch = Instance.new("Part", model)
	pitch.Name = "TurretPitch"
	local joint = Instance.new("Motor6D", pitch)
	joint.Name = "Joint"
	joint.C0 = CFrame.new()
	model.Parent = workspace
	local S = {}
	function S.run()
		breakGun(model, "P1")
		breakGun(model, "P1")
		table.insert(log, fmt("Wrecked=%s VehicleHealth=%s prompt=%s smoke=%d", tostring(model:GetAttribute("Wrecked")),
			tostring(model:GetAttribute("VehicleHealth")), tostring(prompt.Enabled), #pitch:GetChildren() - 1))
		local sent = {}
		for _, call in ipairs((mock.remotes.ProjectileFx or { fired = {} }).fired) do
			local info = call[2]
			table.insert(sent, { action = call[1], radius = info.radius, kind = info.kind, weaponId = info.weaponId, position = info.position })
		end
		local explosions = {}
		for _, inst in ipairs(mock.created) do
			if inst.ClassName == "Explosion" then
				table.insert(explosions, { BlastRadius = inst.BlastRadius, BlastPressure = inst.BlastPressure,
					DestroyJointRadiusPercent = inst.DestroyJointRadiusPercent, Position = inst.Position })
			end
		end
		return log, sent, explosions
	end
	return S
end

return W
