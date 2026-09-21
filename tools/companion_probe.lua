-- Companion probe, for tools/runtest.ps1 -Probe (edit mode, a few minutes).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/companion_probe.lua -WaitSeconds 600
--
-- Checks the companion rig and the attack timing against the place's own modules:
--   rig        every brainrot built with { rig = true }: each visible part welded to exactly one
--              pivot (or the root), each pivot joined by a Motor6D named after a known group, no
--              nested parts, and the rest pose identical to a plain unanchored build
--   identical  with NORIG_EMBED set (the builder with its rig branch removed), plain builds from
--              both are fingerprinted part by part and must match exactly
--   clips      every clip is shorter than the cooldown of every brainrot that uses it
--   timing     broadcast-to-damage time per attack kind, for the current CompanionService and,
--              with OLD_SERVICE_EMBED set, the one before the windup
--   moving     how often each kind hits a target running across at sprint speed, old and new
--   Tier A (2026-09-18), each with its sample count, before the timing sections:
--   announce-last  a lethal hit whose ConfirmHit throws still downs the companion, which is already
--                  gone when the confirm fires; with OLD_SERVICE_EMBED set (the service before the
--                  fix) the same case must FAIL -- that is the check's permanent planted fault
--   point attacks  every kind fired with nobody in reach hits an enemy one stud past its reach on
--                  the line, and misses one clear of it (5 kinds x on/off)
--   practice       every kind lowers a lobby dummy's pool, and the splashing/forking kinds a second
--   chain LOS      a wall between the two enemies stops the fork; removing it lets it through
--   splash LOS     a wall inside a Shockwave's radius saves the enemy behind it; a Lob landing ON a
--                  wall splashes the enemy beside it and not the one behind (SplashRefused counted)
--   radius         the 19 Shockwave brainrots span 14-23 studs; a Zap's range is unchanged (55/79)
--   clock          os.clock against tick() across a 3 s yield (the cooldown runs on os.clock)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = ServerScriptService:WaitForChild("Modules")

local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))

local NORIG_EMBED = nil --[[EMBED:norig]]
local OLD_SERVICE_EMBED = nil --[[EMBED:oldservice]]
local TRIALS = 12
local SPRINT = 24

local function out(fmt, ...)
	print("[PROBE companions] " .. string.format(fmt, ...))
end

local stage = Instance.new("Folder")
stage.Name = "CompanionProbe"
stage.Parent = workspace

local GROUPS = { Body = true, Head = true, ArmL = true, ArmR = true, WingL = true, WingR = true, Tail = true, FootL = true, FootR = true }

--------------------------------------------------------------------------------
-- Rig integrity
--------------------------------------------------------------------------------

local function run(label, fn)
	local ok, err = pcall(fn)
	if not ok then
		out("%s FAILED: %s", label, tostring(err))
	end
end

run("rig", function()
	local problems, groupCounts, joints = {}, {}, 0
	for index, def in ipairs(BrainrotData.Types) do
		local rigged = BrainrotModels.Build(def, { rig = true, anchored = false, scale = 0.55, flair = false })
		local plain = BrainrotModels.Build(def, { anchored = false, scale = 0.55, flair = false })
		local rest = {}
		for _, part in ipairs(plain:GetChildren()) do
			if part:IsA("BasePart") then
				table.insert(rest, part)
			end
		end
		local parts = {}
		for _, d in ipairs(rigged:GetDescendants()) do
			if d:IsA("BasePart") then
				if d.Parent ~= rigged then
					table.insert(problems, def.name .. ": nested " .. d.Name)
				end
				if string.sub(d.Name, 1, 5) == "Pivot" then
					local joint = d:FindFirstChildOfClass("Motor6D")
					if not joint or not GROUPS[joint.Name] or joint.Part1 ~= d or not joint.Part0 or joint.Part0.Parent ~= rigged then
						table.insert(problems, def.name .. ": bad joint on " .. d.Name)
					else
						joints += 1
						groupCounts[joint.Name] = (groupCounts[joint.Name] or 0) + 1
					end
				else
					table.insert(parts, d)
				end
			end
		end
		for _, part in ipairs(parts) do
			if part.Name ~= "Root" then
				local welds = 0
				for _, weld in ipairs(part:GetChildren()) do
					if weld:IsA("WeldConstraint") and weld.Part1 == part and weld.Part0 then
						welds += 1
					end
				end
				if welds ~= 1 then
					table.insert(problems, string.format("%s: %s has %d welds", def.name, part.Name, welds))
				end
			end
		end
		if #parts ~= #rest then
			table.insert(problems, string.format("%s: %d parts rigged vs %d plain", def.name, #parts, #rest))
		else
			for i, part in ipairs(parts) do
				local other = rest[i]
				if part.Name ~= other.Name or (part.Position - other.Position).Magnitude > 1e-4 or (part.Size - other.Size).Magnitude > 1e-4 then
					table.insert(problems, string.format("%s: rest pose differs at %s", def.name, part.Name))
					break
				end
			end
		end
		if not rigged:GetAttribute("RigBody") or not CompanionAnimations.Rig(rigged) then
			table.insert(problems, def.name .. ": CompanionAnimations.Rig can't read it")
		end
		rigged:Destroy()
		plain:Destroy()
		if index % 10 == 0 then
			task.wait()
		end
	end
	-- Self-test: the same weld count on a rig with one weld pulled out must report it.
	do
		local def = BrainrotData.Types[1]
		local broken = BrainrotModels.Build(def, { rig = true, anchored = false, scale = 0.55, flair = false })
		local victim = nil
		for _, part in ipairs(broken:GetChildren()) do
			if part:IsA("BasePart") and part.Name ~= "Root" and string.sub(part.Name, 1, 5) ~= "Pivot" then
				victim = part
				break
			end
		end
		local weld = victim and victim:FindFirstChildOfClass("WeldConstraint")
		if weld then
			weld:Destroy()
		end
		local welds = 0
		for _, child in ipairs(victim and victim:GetChildren() or {}) do
			if child:IsA("WeldConstraint") and child.Part1 == victim then
				welds += 1
			end
		end
		out("== rig self-test: a part with its weld removed counts %d welds -> %s", welds, welds ~= 1 and "PASS (would be reported)" or "FAIL")
		broken:Destroy()
	end
	local counts = {}
	for name, n in pairs(groupCounts) do
		table.insert(counts, name .. " " .. n)
	end
	table.sort(counts)
	out("== rig: %d models, %d joints (%s); problems %d", #BrainrotData.Types, joints, table.concat(counts, ", "), #problems)
	-- Every companion must carry the body joint the animator drives; a model with no pivots at all
	-- raises no "bad joint" of its own and would just quietly lower the total.
	out("== rig coverage: %d of %d models carry a Body joint -> %s", groupCounts.Body or 0, #BrainrotData.Types,
		(groupCounts.Body == #BrainrotData.Types) and "PASS" or "FAIL (those models can't be animated)")
	for i, line in ipairs(problems) do
		if i > 30 then
			out("  ... %d more", #problems - 30)
			break
		end
		out("  %s", line)
	end
end)

--------------------------------------------------------------------------------
-- Byte-identical plain builds
--------------------------------------------------------------------------------

local function fingerprint(model)
	local lines = {}
	local function r(x)
		return string.format("%.4f", x)
	end
	for _, d in ipairs(model:GetDescendants()) do
		local line = d.ClassName .. "|" .. d.Name
		if d:IsA("BasePart") then
			local cf = d.CFrame
			local c = { cf:GetComponents() }
			for i, v in ipairs(c) do
				c[i] = r(v)
			end
			line ..= "|" .. table.concat(c, ",") .. "|" .. r(d.Size.X) .. "," .. r(d.Size.Y) .. "," .. r(d.Size.Z)
				.. "|" .. d.Color:ToHex() .. "|" .. d.Material.Name .. "|" .. r(d.Transparency) .. "|" .. r(d.Reflectance)
				.. "|" .. tostring(d.Anchored) .. (d:IsA("Part") and ("|" .. d.Shape.Name) or "")
		elseif d:IsA("WeldConstraint") then
			line ..= "|" .. (d.Part0 and d.Part0.Name or "nil") .. ">" .. (d.Part1 and d.Part1.Name or "nil")
		elseif d:IsA("SpecialMesh") then
			line ..= "|" .. d.MeshType.Name
		end
		table.insert(lines, line)
	end
	for key, value in pairs(model:GetAttributes()) do
		table.insert(lines, "@" .. key .. "=" .. tostring(value))
	end
	return table.concat(lines, "\n")
end

run("fingerprint self-test", function()
	local model = BrainrotModels.Build(BrainrotData.Types[1], { flair = false })
	local same = model:Clone()
	local nudged = model:Clone()
	for _, part in ipairs(nudged:GetDescendants()) do
		if part:IsA("BasePart") and part.Name ~= "Root" then
			part.CFrame += Vector3.new(0.001, 0, 0)
			break
		end
	end
	local match = fingerprint(model) == fingerprint(same)
	local differs = fingerprint(model) ~= fingerprint(nudged)
	out("== fingerprint self-test: clone matches %s, 1 mm nudge differs %s -> %s", tostring(match), tostring(differs),
		(match and differs) and "PASS" or "FAIL")
	model:Destroy()
	same:Destroy()
	nudged:Destroy()
end)

run("identical", function()
	if not NORIG_EMBED then
		out("== identical: skipped (no NORIG_EMBED)")
		return
	end
	local NoRig = loadstring(NORIG_EMBED)()
	local variants = {
		{ label = "plain", options = {} },
		{ label = "unanchored", options = { anchored = false, scale = 0.55 } },
		{ label = "statue", options = { scale = 1.6, glow = Color3.new(1, 0.8, 0.2), cframe = CFrame.new(310.5, 42.25, -77.125) * CFrame.Angles(0, 1.1, 0) } },
	}
	local compared, mismatches = 0, {}
	for index, def in ipairs(BrainrotData.Types) do
		for _, variant in ipairs(variants) do
			local a = BrainrotModels.Build(def, table.clone(variant.options))
			local b = NoRig.Build(def, table.clone(variant.options))
			compared += 1
			if fingerprint(a) ~= fingerprint(b) then
				table.insert(mismatches, def.name .. " (" .. variant.label .. ")")
			end
			a:Destroy()
			b:Destroy()
		end
		if index % 10 == 0 then
			task.wait()
		end
	end
	out("== identical: %d builds compared against the builder without its rig branch; mismatches %d -> %s",
		compared, #mismatches, compared > 0 and (#mismatches == 0 and "PASS" or "FAIL") or "FAIL (nothing was compared)")
	for i, line in ipairs(mismatches) do
		if i > 20 then
			break
		end
		out("  %s", line)
	end
end)

--------------------------------------------------------------------------------
-- Clip lengths against cooldowns
--------------------------------------------------------------------------------

run("clips", function()
	local worst = {}
	for _, def in ipairs(BrainrotData.Types) do
		local stats = BrainrotData.Stats(def, 1, 0)
		-- The longest a travelling move can take: across its whole range.
		local travel = stats.kind == "Lob" and 0.7 or stats.kind == "Bonk" and 0.35 or stats.range / 90
		local duration = CompanionAnimations.Duration(stats.kind, travel) + CompanionAnimations.Duration("Cheer")
		local margin = stats.cooldown - duration
		if not worst[stats.kind] or margin < worst[stats.kind].margin then
			worst[stats.kind] = { margin = margin, name = def.name, cooldown = stats.cooldown, duration = duration }
		end
	end
	for kind, w in pairs(worst) do
		out("== clip %-9s longest %.2fs (with a cheer) vs shortest cooldown %.2fs (%s): margin %.2fs%s", kind, w.duration, w.cooldown, w.name,
			w.margin, w.margin <= 0 and "  <-- OVERLAPS" or "")
	end
	-- Every pose stays finite through every clip.
	local bad = 0
	for kind in pairs(worst) do
		for body in pairs(CompanionAnimations.Styles) do
			for step = 0, 40 do
				local pose = CompanionAnimations.IdlePose(body, step * 0.05, 0, 0.55)
				local t = step * 0.03
				CompanionAnimations.Layer(pose, body, { kind = kind, start = 0, target = Vector3.new(4, -1, -14), travel = 0.35 }, t, 0.55)
				for _, cf in pairs(CompanionAnimations.Transforms(pose)) do
					local p = cf.Position
					if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z or p.Magnitude > 60 then
						bad += 1
					end
				end
			end
		end
	end
	out("== clip poses: non-finite or runaway transforms %d", bad)
end)

--------------------------------------------------------------------------------
-- Timing and moving targets
--
-- Spit, Bonk, Zap and Chain home in on the target they picked, so they hit a moving target by
-- construction; only Lob (lands where aimed) and Shockwave (radius at the moment it lands) really
-- test anything here.
--------------------------------------------------------------------------------

local CombatService = require(modules:WaitForChild("CombatService"))
local Combatants = require(modules:WaitForChild("Combatants"))

local damageLog = {}
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount)
	table.insert(damageLog, { t = os.clock(), victim = victim, amount = amount })
	return amount
end
CombatService.SetEnabled(true)

local function character(name, position)
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CFrame = CFrame.new(position)
	root.Parent = model
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 3, 1)
	torso.Anchored = true
	torso.CFrame = CFrame.new(position)
	torso.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = stage
	return model, root
end

local BASE = Vector3.new(-4000, 900, 4000)
local ownerCharacter = character("ProbeOwner", BASE)
local owner = { isBot = true, name = "ProbeOwner", character = ownerCharacter }
Combatants.Register(ownerCharacter, owner)
local targetCharacter, targetRoot = character("ProbeTarget", BASE + Vector3.new(0, 0, -14))
local target = { isBot = true, name = "ProbeTarget", character = targetCharacter }
Combatants.Register(targetCharacter, target)

local byKind = {}
for _, def in ipairs(BrainrotData.Types) do
	byKind[def.attack] = byKind[def.attack] or def
end

local function measure(label, Service)
	Service.IsFighting = function()
		return true
	end
	local rows = {}
	for _, kind in ipairs({ "Spit", "Bonk", "Zap", "Chain", "Lob", "Shockwave" }) do
		local def = byKind[kind]
		Service.AttachBot(owner, def)
		local model = Service.ModelOf(owner)
		if not model then
			table.insert(rows, kind .. " no companion")
			continue
		end
		local companionRoot = model.PrimaryPart
		-- Standing still, straight ahead: the time from the broadcast to the damage.
		local stand = companionRoot.Position + Vector3.new(0, -1, -12)
		targetRoot.CFrame = CFrame.new(stand)
		targetRoot.AssemblyLinearVelocity = Vector3.zero
		table.clear(damageLog)
		Service.ResetStats()
		local started = os.clock()
		Service.UseAbility(owner, nil)
		local deadline = started + 2.5
		while #damageLog == 0 and os.clock() < deadline do
			task.wait()
		end
		local delay = #damageLog > 0 and damageLog[1].t - started or -1

		-- Running across at sprint speed from a random point in range: how often does it land? Then
		-- the same with the runner turning back 0.3 s in, which a well-capped lead should still miss.
		local hits, dodgeHits = 0, 0
		for trial = 1, TRIALS * 2 do
			local reverses = trial > TRIALS
			local angle = (trial / TRIALS) * math.pi * 2
			local distance = 8 + (trial % 4) * 3
			local start = companionRoot.Position + Vector3.new(math.sin(angle) * distance, -1, -math.cos(angle) * distance)
			local across = Vector3.new(math.cos(angle), 0, math.sin(angle)) * SPRINT * (trial % 2 == 0 and 1 or -1)
			targetRoot.CFrame = CFrame.new(start)
			targetRoot.AssemblyLinearVelocity = across
			table.clear(damageLog)
			Service.ResetStats()
			local t0 = os.clock()
			local moving = true
			task.spawn(function()
				local velocity = across
				while moving do
					local dt = task.wait()
					if reverses and os.clock() - t0 > 0.3 then
						velocity = -across
					end
					targetRoot.CFrame += velocity * dt
					targetRoot.AssemblyLinearVelocity = velocity
				end
			end)
			Service.UseAbility(owner, nil)
			while #damageLog == 0 and os.clock() < t0 + 1.6 do
				task.wait()
			end
			moving = false
			task.wait()
			if #damageLog > 0 then
				if reverses then
					dodgeHits += 1
				else
					hits += 1
				end
			end
		end
		table.insert(rows, string.format("%s %s: damage after %.3fs, moving-target hits %d/%d, turning back %d/%d", kind, def.name, delay,
			hits, TRIALS, dodgeHits, TRIALS))
	end
	Service.AttachBot(owner, nil)
	for _, row in ipairs(rows) do
		out("== %s %s", label, row)
	end
end

--------------------------------------------------------------------------------
-- Tier A behaviour (2026-09-18): announce-last, point attacks, practice parity, line of sight,
-- the Shockwave radius, and the clock the cooldown runs on. Every check prints its sample count,
-- and the announce-last check runs its planted fault every time: the service as it was before the
-- fix (OLD_SERVICE_EMBED) must FAIL it, or the check has not been shown to catch anything.
--------------------------------------------------------------------------------

local Service = require(modules:WaitForChild("CompanionService"))
Service.IsFighting = function()
	return true
end

local function loadOldService()
	if not OLD_SERVICE_EMBED then
		return nil
	end
	local source = "local script = game:GetService('ServerScriptService').Modules.CompanionService\n" .. OLD_SERVICE_EMBED
	return loadstring(source)()
end

local function findDef(kind, rarity)
	for _, def in ipairs(BrainrotData.Types) do
		if def.attack == kind and def.rarity == rarity then
			return def
		end
	end
	return byKind[kind]
end

-- A lethal hit whose ConfirmHit throws (the attacker on their way out). The companion must be
-- downed anyway, already gone by the time the confirm fires (state before news), and must stay
-- out until the match resets.
local function lethalWithThrowingConfirm(Svc)
	Svc.IsFighting = function()
		return true
	end
	Svc.ResetStats()
	Svc.AttachBot(owner, byKind.Spit)
	local model = Svc.ModelOf(owner)
	if not model then
		return nil, nil, nil
	end
	local realConfirm = CombatService.ConfirmHit
	local goneAtConfirm = nil
	CombatService.ConfirmHit = function()
		goneAtConfirm = Svc.ModelOf(owner) == nil
		error("planted: the attacker left mid-hit")
	end
	local returned = pcall(Svc.Damage, target, model, 1e6)
	CombatService.ConfirmHit = realConfirm
	local downed = Svc.ModelOf(owner) == nil
	Svc.AttachBot(owner, byKind.Spit)
	local staysOut = Svc.ModelOf(owner) == nil
	Svc.ResetStats()
	Svc.AttachBot(owner, nil)
	return downed and staysOut, goneAtConfirm, returned
end

run("announce-last", function()
	local ok, gone, returned = lethalWithThrowingConfirm(Service)
	out("== announce-last new: lethal hit with a throwing ConfirmHit -> downed and stays out %s, already gone when the confirm fired %s, Damage returned cleanly %s -> %s",
		tostring(ok), tostring(gone), tostring(returned), (ok and gone and returned) and "PASS" or "FAIL")
	local Old = loadOldService()
	if not Old then
		out("== announce-last old: SKIPPED (no OLD_SERVICE_EMBED) -- the planted fault did not run, so this check is unproven")
		return
	end
	local oldOk = lethalWithThrowingConfirm(Old)
	out("== announce-last old (planted fault: the order before the fix): downed %s -> %s", tostring(oldOk),
		(oldOk == false) and "PASS (the old order is caught)" or "FAIL (the check cannot tell the old order from the new)")
end)

-- Fires the move with the target standing still at `at`, aimed along -Z, and reports whether any
-- damage landed within `wait` seconds and on whom.
local function fireAt(at, aimPoint, wait)
	targetRoot.CFrame = CFrame.new(at)
	targetRoot.AssemblyLinearVelocity = Vector3.zero
	table.clear(damageLog)
	Service.ResetStats()
	local t0 = os.clock()
	Service.UseAbility(owner, aimPoint)
	while #damageLog == 0 and os.clock() < t0 + (wait or 1.8) do
		task.wait()
	end
	task.wait(0.15)
	local victims = {}
	for _, entry in ipairs(damageLog) do
		victims[entry.victim] = true
	end
	return #damageLog, victims
end

run("point attacks", function()
	local asExpected, samples, rows = 0, 0, {}
	for _, kind in ipairs({ "Spit", "Zap", "Chain", "Bonk", "Lob" }) do
		local def = byKind[kind]
		local stats = BrainrotData.Stats(def, 1, 0)
		Service.AttachBot(owner, def)
		local root = Service.ModelOf(owner).PrimaryPart
		local dir = Vector3.new(0, 0, -1)
		-- One stud past the move's reach, on the line: out of pickTarget's range, so the move fires at
		-- the point, and inside what the point version must catch. Then sideways, clear of it.
		local reach = root.Position + dir * stats.range
		local clear = (kind == "Bonk" or kind == "Lob") and stats.splash + 3 or 4
		for _, case in ipairs({ { label = "on the line", at = reach + dir, want = true }, { label = "clear of it", at = reach + dir + Vector3.new(clear, 0, 0), want = false } }) do
			local n = fireAt(case.at, root.Position + dir * 300)
			local landed = n > 0
			samples += 1
			if landed == case.want then
				asExpected += 1
			end
			table.insert(rows, string.format("%s, target %s (%d studs): %s (want %s)", kind, case.label, math.floor((case.at - root.Position).Magnitude + 0.5),
				landed and "HIT" or "missed", case.want and "hit" or "miss"))
		end
	end
	Service.AttachBot(owner, nil)
	for _, row in ipairs(rows) do
		out("   %s", row)
	end
	out("== point attacks: %d of %d cases as expected (5 kinds x on/off the line) -> %s", asExpected, samples,
		(samples == 10 and asExpected == 10) and "PASS" or "FAIL")
end)

run("practice parity", function()
	local PracticeDummy = require(modules:WaitForChild("PracticeDummy"))
	Service.IsFighting = function()
		return false
	end
	local range = Instance.new("Folder")
	range.Name = "ProbeRange"
	range.Parent = stage
	-- Two dummies 6 studs apart, ahead of the companion (which sits 2.8 right, 2.6 up, 2.4 back of
	-- the owner): the nearer is the target; the other is inside a Bonk's splash (7), a Lob's (11), a
	-- Chain's fork (22) and a Secret Shockwave (23), and outside a Spit's or a Zap's single hit.
	local first = PracticeDummy.Build(range, CFrame.new(BASE + Vector3.new(2.8, -3, -10)), "probe")
	local second = PracticeDummy.Build(range, CFrame.new(BASE + Vector3.new(8.8, -3, -10)), "probe")
	task.wait(0.2)
	local function pool(body)
		local health, shield = PracticeDummy.State(body)
		return health + shield
	end
	local rows, okKinds, samples = {}, 0, 0
	for _, kind in ipairs({ "Spit", "Zap", "Chain", "Bonk", "Lob", "Shockwave" }) do
		local def = kind == "Shockwave" and findDef("Shockwave", "Secret") or byKind[kind]
		Service.AttachBot(owner, def)
		Service.ResetStats()
		local before1, before2 = pool(first), pool(second)
		Service.UseAbility(owner, nil)
		local t0 = os.clock()
		while pool(first) == before1 and os.clock() < t0 + 1.8 do
			task.wait()
		end
		task.wait(0.15)
		local drop1, drop2 = before1 - pool(first), before2 - pool(second)
		local wantSecond = kind ~= "Spit" and kind ~= "Zap"
		local ok = drop1 > 0 and ((drop2 > 0) == wantSecond)
		samples += 1
		if ok then
			okKinds += 1
		end
		table.insert(rows, string.format("%s (%s): target dummy -%d, other dummy -%d (other expected %s)", kind, def.name, drop1, drop2,
			wantSecond and "hit" or "untouched"))
	end
	Service.AttachBot(owner, nil)
	Service.IsFighting = function()
		return true
	end
	range:Destroy()
	for _, row in ipairs(rows) do
		out("   %s", row)
	end
	out("== practice parity: %d of %d kinds land on the lobby dummies as they would in a match -> %s", okKinds, samples,
		(samples == 6 and okKinds == 6) and "PASS" or "FAIL")
end)

local function wallAt(position, size)
	local wall = Instance.new("Part")
	wall.Name = "ProbeWall"
	wall.Anchored = true
	wall.Size = size
	wall.CFrame = CFrame.new(position)
	wall.Parent = stage
	return wall
end

local function otherEnemy(name, position)
	local otherCharacter, otherRoot = character(name, position)
	local other = { isBot = true, name = name, character = otherCharacter }
	Combatants.Register(otherCharacter, other)
	return other, otherCharacter, otherRoot
end

run("chain line of sight", function()
	Service.AttachBot(owner, byKind.Chain)
	local base = Service.ModelOf(owner).PrimaryPart.Position
	local other, otherCharacter = otherEnemy("ProbeOther", base + Vector3.new(8, -1, -12))
	-- A wall between the first enemy (dead ahead) and the second (8 studs to its right).
	local wall = wallAt(base + Vector3.new(4, 0, -12), Vector3.new(1, 12, 16))
	local nWall, wallVictims = fireAt(base + Vector3.new(0, -1, -12), nil, 1.2)
	wall:Destroy()
	local nOpen, openVictims = fireAt(base + Vector3.new(0, -1, -12), nil, 1.2)
	task.wait(0.2)
	nOpen = #damageLog
	for _, entry in ipairs(damageLog) do
		openVictims[entry.victim] = true
	end
	Combatants.Unregister(otherCharacter)
	otherCharacter:Destroy()
	Service.AttachBot(owner, nil)
	local ok = nWall == 1 and wallVictims[target] and not wallVictims[other] and nOpen == 2 and openVictims[other]
	out("== chain line of sight: wall between the two enemies -> %d hit (first %s, second %s); wall gone -> %d hit (second %s) -> %s",
		nWall, tostring(wallVictims[target] == true), tostring(wallVictims[other] == true), nOpen, tostring(openVictims[other] == true), ok and "PASS" or "FAIL")
end)

run("splash line of sight", function()
	local refused0 = Service.SplashRefused
	-- Shockwave: two enemies inside the radius, one behind a wall.
	Service.AttachBot(owner, findDef("Shockwave", "Secret"))
	local base = Service.ModelOf(owner).PrimaryPart.Position
	local behind, behindCharacter = otherEnemy("ProbeBehind", base + Vector3.new(0, -1, 8))
	local wall = wallAt(base + Vector3.new(0, 0, 4), Vector3.new(12, 12, 1))
	local nWall, wallVictims = fireAt(base + Vector3.new(0, -1, -8), nil, 1.2)
	local refusedWall = Service.SplashRefused - refused0
	wall:Destroy()
	local nOpen, openVictims = fireAt(base + Vector3.new(0, -1, -8), nil, 1.2)
	task.wait(0.2)
	nOpen = #damageLog
	for _, entry in ipairs(damageLog) do
		openVictims[entry.victim] = true
	end
	Combatants.Unregister(behindCharacter)
	behindCharacter:Destroy()
	local shockOk = nWall == 1 and wallVictims[target] and not wallVictims[behind] and refusedWall == 1 and nOpen == 2 and openVictims[behind]
	out("== splash line of sight, Shockwave: wall inside the radius -> %d hit, %d refused by the wall; wall gone -> %d hit -> %s",
		nWall, refusedWall, nOpen, shockOk and "PASS" or "FAIL")

	-- Lob at a wall face: the glob lands ON the wall. The enemy behind it (4.5 studs from the landing)
	-- must not be splashed; the one beside it, out of the aim cone so the move fires at the point,
	-- must. A splash cast from the surface itself would pass through the wall (a ray never reports a
	-- part it starts inside) -- this is what the half-stud pull-back is for.
	Service.AttachBot(owner, byKind.Lob)
	base = Service.ModelOf(owner).PrimaryPart.Position
	local refused1 = Service.SplashRefused
	local far, farCharacter = otherEnemy("ProbeFar", base + Vector3.new(0, -1, -24))
	local face = wallAt(base + Vector3.new(0, 0, -20), Vector3.new(14, 12, 1))
	local nLob, lobVictims = fireAt(base + Vector3.new(-9, -1, -14), base + Vector3.new(0, 0, -19.5), 1.6)
	local refusedLob = Service.SplashRefused - refused1
	face:Destroy()
	Combatants.Unregister(farCharacter)
	farCharacter:Destroy()
	Service.AttachBot(owner, nil)
	local lobOk = nLob == 1 and lobVictims[target] and not lobVictims[far] and refusedLob == 1
	out("== splash line of sight, Lob landing on a wall: %d hit (beside %s, behind %s), %d refused -> %s",
		nLob, tostring(lobVictims[target] == true), tostring(lobVictims[far] == true), refusedLob, lobOk and "PASS" or "FAIL")
end)

run("shockwave radius", function()
	local n, minR, maxR = 0, math.huge, -math.huge
	local byRarityR = {}
	for _, def in ipairs(BrainrotData.Types) do
		if def.attack == "Shockwave" then
			local r = BrainrotData.Stats(def, 1, 0).range
			n += 1
			minR, maxR = math.min(minR, r), math.max(maxR, r)
			byRarityR[def.rarity] = r
		end
	end
	local zapCommon = BrainrotData.Stats(findDef("Zap", "Common"), 1, 0).range
	local zapSecret = BrainrotData.Stats(findDef("Zap", "Secret"), 1, 0).range
	local ok = n == 19 and minR == 14 and maxR == 23 and zapCommon == 55 and zapSecret == 79
	out("== shockwave radius: %d brainrots span %d-%d studs (Common %s, Secret %s); Zap range Common %d / Secret %d unchanged -> %s",
		n, minR, maxR, tostring(byRarityR.Common), tostring(byRarityR.Secret), zapCommon, zapSecret, ok and "PASS" or "FAIL")
end)

run("clock", function()
	local c0, t0 = os.clock(), tick()
	task.wait(3)
	local dc, dt = os.clock() - c0, tick() - t0
	out("== clock: across a 3 s yield os.clock advanced %.3f s and tick() advanced %.3f s (ratio %.3f); the cooldown runs on os.clock, so a ratio well under 1 means it runs long",
		dc, dt, dc / math.max(dt, 1e-6))
end)

run("timing old", function()
	if not OLD_SERVICE_EMBED then
		out("== timing old: skipped (no OLD_SERVICE_EMBED)")
		return
	end
	local source = "local script = game:GetService('ServerScriptService').Modules.CompanionService\n" .. OLD_SERVICE_EMBED
	local Old = loadstring(source)()
	measure("old", Old)
end)

run("timing new", function()
	local New = require(modules:WaitForChild("CompanionService"))
	measure("new", New)
end)

CombatService.DealDamage = realDeal
stage:Destroy()
