-- Window vault probe (Destruction tab; Oliver's #119 "glass still doesn't break when i jump through
-- windows" and #115 "make it easier to vault through windows").
--
-- Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/window_vault_probe.lua -OutDir <folder> -TimeoutSeconds 900
--
-- Everything is measured against REAL MapBuildings buildings (one of each archetype that gets windows:
-- house, tower, warehouse), never a stand-in wall: the stand-in that "proved" #23 put its pane straight
-- in front of the body with no wall under it, and a real window has 3.5 studs of wall under the pane.
--
--   A  a bot's TryParkour at every ground-floor pane: the pane must be gone afterwards, and no OTHER
--      pane of that building may go with it. Printed per vault: panes found in range, panes broken,
--      the building's pane count before and after.
--   B  a player's ClientParkour with the body standing where a client starts a vault (the server only
--      hears "I vaulted" and looks from the body), at 1.6 and 2.6 studs from the face. Same checks.
--   P1 planted fault, invariant "a vault through a window leaves no pane on its path": BreakPane swapped
--      for a no-op; the pane must SURVIVE, LastGlass must say found > 0 broken 0, and MovementService
--      must warn. A plant that does not fire is reported as such, not counted as a pass.
--   P2 planted fault, invariant "a vault breaks no pane it did not pass through": BreakPane swapped for
--      one that also breaks the next pane along; the building count check must catch the extra loss.
--   F  a fence 3 studs in front of a window, vaulted: the window is NOT on the path. The bot's plan
--      carries its own panes so it must leave the window alone; the player's band box reaches 5.7 studs
--      forward and may not. Measured and printed either way -- this is the box's known forward risk.
--   C  the trigger census for #115: Parkour.Find asked from a grid around every pane (distance, lateral
--      offset, angle, speed, feet-height-into-jump, inside-out), histogram of kinds and refusals.
--
-- Instrument self-test first (a ray at a known wall band must say Wall, through a pane must say that
-- pane, through the sky nothing), and a Bootstrap check: a plugin's require gets its OWN module
-- instance, so Bootstrap's wires are looked for by identity and re-made here when absent, and the
-- probe says which it found. Two renders follow, each with a camera->subject occlusion ray.

local LogService = game:GetService("LogService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local MapData = require(Shared:WaitForChild("MapData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local CFG = MovementConfig.Parkour
local ORIGIN = Vector3.new(4000, 1500, -3000)
local SPRINT = 18 * 1.45
local PRESET = MapData.Maps.SahurSprings
-- MapBuildings' own numbers (locals there): wall thickness, the sill and the window top above the floor.
local WALL_THICKNESS, SILL_HEIGHT = 1.4, 3.5
local GLASS_REACH = CFG.VaultMaxDepth + 2.5
local BAND_BOTTOM, BAND_TOP = CFG.VaultMinRise, CFG.VaultMaxRise + CFG.VaultClearance

local PLANS = {
	house = { archetype = "house", width = 32, depth = 30, floors = 2, dock = false },
	tower = { archetype = "tower", width = 30, depth = 30, floors = 3, dock = false },
	warehouse = { archetype = "warehouse", width = 44, depth = 38, floors = 1, dock = true },
}

local function note(fmt, ...)
	print("[BRR_Gallery] note " .. string.format(fmt, ...))
end

local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function block(parent, size, cframe, color, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color or Color3.fromRGB(120, 120, 130)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props or {}) do
		part[key] = value
	end
	part.Parent = parent
	return part
end

local template = nil
local function makeTemplate()
	for attempt = 1, 3 do
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
		end)
		if ok and model then
			return model
		end
		note("rig attempt %d failed: %s", attempt, tostring(model))
		task.wait(2)
	end
	return nil
end

local function drive(timeout, step)
	local started = os.clock()
	local finished = false
	local connection
	connection = RunService.Heartbeat:Connect(function(dt)
		if finished then
			return
		end
		local elapsed = os.clock() - started
		local ok, result = pcall(step, dt, elapsed)
		if not ok then
			note("step error: %s", tostring(result))
			finished = true
		elseif result or elapsed > timeout then
			finished = true
		end
	end)
	while not finished do
		task.wait()
	end
	connection:Disconnect()
end

local function ensureRunning()
	if not RunService:IsRunning() then
		RunService:Run()
		task.wait(4)
	end
end

--------------------------------------------------------------------------------
-- The Map root and the buildings
--------------------------------------------------------------------------------

local lastHolder = nil

local function freshHolder()
	if lastHolder then
		lastHolder:Destroy()
		lastHolder = nil
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		map = Instance.new("Folder")
		map.Name = "Map"
		map.Parent = workspace
	end
	local holder = Instance.new("Folder")
	holder.Name = "WindowProbe"
	holder.Parent = map
	lastHolder = holder
	return holder
end

local function requireModules()
	local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
	return {
		MapBuildings = require(modules:WaitForChild("MapBuildings")),
		MovementService = require(modules:WaitForChild("MovementService")),
		CombatService = require(modules:WaitForChild("CombatService")),
		Combatants = require(modules:WaitForChild("Combatants")),
		MatchService = require(modules:WaitForChild("MatchService")),
	}
end

local function buildRow(M, holder, names, seed)
	local ground = block(holder, Vector3.new(560, 1, 300), CFrame.new(ORIGIN + Vector3.new(0, -0.5, 0)), Color3.fromRGB(96, 130, 78))
	ground.Name = "ProbeGround"
	ground.Material = Enum.Material.Grass
	local built = {}
	local x = -(#names - 1) * 80
	for _, name in ipairs(names) do
		math.randomseed(seed)
		local plan = table.clone(PLANS[name])
		local origin = ORIGIN + Vector3.new(x, 0, 0)
		local before = {}
		for _, child in ipairs(holder:GetChildren()) do
			before[child] = true
		end
		local ok, err = pcall(M.MapBuildings.BuildBuilding, holder, origin, PRESET, {}, { weapon = {}, heal = {}, item = {} }, plan, 0)
		if not ok then
			note("BuildBuilding %s FAILED: %s", name, tostring(err))
		end
		for _, child in ipairs(holder:GetChildren()) do
			if not before[child] and child:IsA("Model") then
				table.insert(built, { name = name, model = child, origin = origin, plan = plan })
			end
		end
		x += 160
	end
	return built
end

local function groundPanes(entry)
	local panes = {}
	for _, part in ipairs(entry.model:GetChildren()) do
		if part:IsA("BasePart") and part.Name == "WindowGlass" and part.Position.Y < entry.origin.Y + 12 then
			table.insert(panes, part)
		end
	end
	table.sort(panes, function(a, b)
		local na, nb = a.CFrame.LookVector, b.CFrame.LookVector
		local ka, kb = math.round(na.X) * 3 + math.round(na.Z), math.round(nb.X) * 3 + math.round(nb.Z)
		if ka ~= kb then
			return ka < kb
		end
		return a.Position.X + a.Position.Z < b.Position.X + b.Position.Z
	end)
	return panes
end

local function paneCount(model)
	local count = 0
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part.Name == "WindowGlass" and part.Parent then
			count += 1
		end
	end
	return count
end

-- The nearest OTHER pane on the same wall (same outward normal), or nil.
local function neighbourPane(model, pane)
	local best, bestDistance = nil, math.huge
	for _, part in ipairs(model:GetChildren()) do
		if part ~= pane and part:IsA("BasePart") and part.Name == "WindowGlass" and part.CFrame.LookVector:Dot(pane.CFrame.LookVector) > 0.9 then
			local distance = (part.Position - pane.Position).Magnitude
			if distance < bestDistance then
				best, bestDistance = part, distance
			end
		end
	end
	return best, bestDistance
end

local function wallName(normal)
	if math.abs(normal.Z) > 0.5 then
		return normal.Z > 0 and "back(+Z)" or "front(-Z)"
	end
	return normal.X > 0 and "side(+X)" or "side(-X)"
end

--------------------------------------------------------------------------------
-- The instrument
--------------------------------------------------------------------------------

local function firstHit(from, to)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return { name = "NO MAP" }
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map }
	local result = workspace:Raycast(from, to - from, params)
	if not result then
		return { name = "nothing" }
	end
	return { name = result.Instance.Name, instance = result.Instance, position = result.Position, distance = (result.Position - from).Magnitude }
end

local function selfTest(pane)
	local normal = pane.CFrame.LookVector
	local right = 0
	local apronY = pane.Position.Y - pane.Size.Y / 2 - 1.0
	local a = firstHit(Vector3.new(pane.Position.X, apronY, pane.Position.Z) + normal * 3, Vector3.new(pane.Position.X, apronY, pane.Position.Z) - normal * 2)
	if a.name == "Wall" then
		right += 1
	end
	local b = firstHit(pane.Position + normal * 3, pane.Position - normal * 2)
	if b.instance == pane then
		right += 1
	end
	local c = firstHit(pane.Position + Vector3.new(0, 60, 0) + normal * 3, pane.Position + Vector3.new(0, 60, 0) - normal * 2)
	if c.name == "nothing" then
		right += 1
	end
	note("instrument self-test: %d/3 named right (apron ray -> %s, pane ray -> %s, sky ray -> %s)", right, a.name, b.name, c.name)
	return right == 3
end

-- The break hook, wrapped: every call recorded. Wired here as Bootstrap wires it when this module
-- instance is not Bootstrap's (a plugin's require gets its own).
local breakCalls = {}
local realBreak = nil
local warnsSeen = 0

local function bootstrapWire(M)
	return function(token, pane, from)
		if not M.CombatService.DamageDestructible then
			return false
		end
		return M.CombatService.DamageDestructible(token, pane, 1, from) > 0
	end
end

local function installHook(M)
	if realBreak then
		return
	end
	local bootstrapInstance = M.MovementService.SpendStamina == M.MatchService.SpendStamina
		and M.MovementService.SetSpeedBoost == M.MatchService.ApplySpeedBoost
	local lobby = workspace:FindFirstChild("Lobby")
	note("module instance: Bootstrap's wires %s on the probe's MovementService (SpendStamina/SetSpeedBoost identity); a Lobby %s in workspace, so Bootstrap %s",
		bootstrapInstance and "PRESENT" or "ABSENT", lobby and "IS" or "is NOT", lobby and "ran" or "may not have run")
	if bootstrapInstance then
		realBreak = M.MovementService.BreakPane
		note("hook: using Bootstrap's own BreakPane")
	else
		realBreak = bootstrapWire(M)
		note("hook: BreakPane re-made here exactly as Bootstrap makes it (DamageDestructible per pane)")
	end
	M.MovementService.BreakPane = function(token, pane, from)
		table.insert(breakCalls, { pane = pane, from = from })
		return realBreak(token, pane, from)
	end
	LogService.MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageWarning and string.find(message, "a vault found", 1, true) then
			warnsSeen += 1
		end
	end)
end

local function lastGlass(M)
	local record = M.MovementService.LastGlass
	if not record then
		return "LastGlass nil"
	end
	return string.format("found %d broke %d", record.found, record.broken)
end

--------------------------------------------------------------------------------
-- Trials
--------------------------------------------------------------------------------

local function botVault(M, L, pane, faceOverride)
	local normal = pane.CFrame.LookVector
	local face = faceOverride or (pane.Position + normal * (WALL_THICKNESS / 2))
	local start = Vector3.new(face.X, ORIGIN.Y + L.stand, face.Z) + normal * 8
	L.rig:PivotTo(CFrame.lookAt(start, start - normal))
	L.root.AssemblyLinearVelocity = Vector3.zero
	task.wait(0.5)
	local kind, why, startedAt = nil, nil, nil
	local callsBefore = #breakCalls
	M.MovementService.LastGlass = nil
	drive(6, function(_, elapsed)
		if not kind then
			L.humanoid.WalkSpeed = SPRINT
			L.humanoid:Move(-normal, false)
			local dist = (L.root.Position - face):Dot(normal)
			if dist <= 1.6 and elapsed > 0.2 then
				kind, why = M.MovementService.TryParkour(L.rig, -normal, {
					speed = math.max(0, flat(L.root.AssemblyLinearVelocity):Dot(-normal)), groundY = ORIGIN.Y,
				})
				startedAt = elapsed
				if not kind then
					return true
				end
			end
			return elapsed > 4
		end
		return elapsed - startedAt > 1.2
	end)
	L.humanoid:Move(Vector3.zero, false)
	return {
		kind = kind, why = why, past = -((L.root.Position - face):Dot(normal)), survived = pane.Parent ~= nil,
		calls = #breakCalls - callsBefore, glass = lastGlass(M),
	}
end

local function playerVault(M, L, pane, distance, faceOverride)
	local normal = pane.CFrame.LookVector
	local face = faceOverride or (pane.Position + normal * (WALL_THICKNESS / 2))
	local spot = Vector3.new(face.X, ORIGIN.Y + L.stand, face.Z) + normal * distance
	L.rig:PivotTo(CFrame.lookAt(spot, spot - normal))
	L.root.AssemblyLinearVelocity = Vector3.zero
	task.wait(0.5)
	local plan, reason = Parkour.Find(L.rig, -normal, { groundY = ORIGIN.Y, speed = SPRINT, grounded = true })
	local callsBefore = #breakCalls
	M.MovementService.LastGlass = nil
	local paid = M.MovementService.ClientParkour(L.fakePlayer, "vault", plan and plan.rise or SILL_HEIGHT, plan and plan.duration or 0.5)
	task.wait(0.3)
	return {
		plan = plan and plan.kind or ("no plan: " .. tostring(reason)), paid = paid, survived = pane.Parent ~= nil,
		calls = #breakCalls - callsBefore, glass = lastGlass(M),
	}
end

--------------------------------------------------------------------------------
-- The trigger census
--------------------------------------------------------------------------------

local function census(rig, panes)
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	local root = rig.HumanoidRootPart
	local stand = humanoid.HipHeight + root.Size.Y / 2
	humanoid.AutoRotate = false

	local function try(pane, d, lateral, angleDeg, speed, lift, inside)
		local normal = pane.CFrame.LookVector
		local tangent = normal:Cross(Vector3.yAxis).Unit
		local outward = inside and -normal or normal
		local faceSide = pane.Position + outward * (WALL_THICKNESS / 2)
		local groundY = inside and (ORIGIN.Y + 0.5) or ORIGIN.Y
		local pos = Vector3.new(faceSide.X, groundY + stand + lift + 0.02, faceSide.Z) + outward * d + tangent * lateral
		local dir = CFrame.Angles(0, math.rad(angleDeg), 0):VectorToWorldSpace(-outward)
		rig:PivotTo(CFrame.lookAt(pos, pos + dir))
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait()
		local plan, reason = Parkour.Find(rig, dir, { groundY = groundY, speed = speed, grounded = lift == 0 })
		return plan and plan.kind or reason
	end

	local function sweep(label, values, config)
		for _, value in ipairs(values) do
			local counts, n = {}, 0
			for _, pane in ipairs(panes) do
				local c = config(value)
				local outcome = try(pane, c.d, c.lateral, c.angle, c.speed, c.lift, c.inside)
				counts[outcome] = (counts[outcome] or 0) + 1
				n += 1
			end
			local list = {}
			for outcome, count in pairs(counts) do
				table.insert(list, { outcome = outcome, count = count })
			end
			table.sort(list, function(a, b)
				return a.count > b.count
			end)
			local shown = {}
			for index = 1, math.min(3, #list) do
				table.insert(shown, string.format("%s %d", list[index].outcome, list[index].count))
			end
			note("census %-8s %-5s: vault %2d/%d | %s", label, tostring(value), counts.vault or 0, n, table.concat(shown, ", "))
		end
	end

	local base = { d = 1.6, lateral = 0, angle = 0, speed = SPRINT, lift = 0, inside = false }
	local function with(key)
		return function(value)
			local c = table.clone(base)
			c[key] = value
			return c
		end
	end
	sweep("distance", { 1.0, 1.4, 1.8, 2.2, 2.6, 2.9, 3.2, 3.6, 4.0 }, with("d"))
	sweep("lateral", { 0, 0.5, 1.0, 1.5, 1.7, 2.0, 2.5 }, with("lateral"))
	sweep("angle", { 0, 20, 40, 50, 55, 60, 70 }, with("angle"))
	sweep("speed", { 5, 8, 9, 12, 18, 26.1 }, with("speed"))
	sweep("feetUp", { 0, 0.5, 1.0, 1.5, 1.9, 2.5, 3.5, 5.0 }, with("lift"))
	sweep("inside", { "d1.6" }, function()
		local c = table.clone(base)
		c.inside = true
		return c
	end)
	note("census stand %.2f; base d %.1f lateral 0 angle 0 speed %.1f feet on ground, outside", stand, base.d, base.speed)
end

--------------------------------------------------------------------------------
-- The measurement view
--------------------------------------------------------------------------------

local function stubLedger(M)
	local saved = { SpendStamina = M.MovementService.SpendStamina, GetStamina = M.MovementService.GetStamina, SetCrouching = M.MovementService.SetCrouching }
	M.MovementService.SpendStamina = function()
		return true
	end
	M.MovementService.GetStamina = function()
		return 1, false
	end
	M.MovementService.SetCrouching = function()
		return false
	end
	return saved
end

local function restoreLedger(M, saved)
	M.MovementService.SpendStamina = saved.SpendStamina
	M.MovementService.GetStamina = saved.GetStamina
	M.MovementService.SetCrouching = saved.SetCrouching
end

local function collectPanes(built)
	local all = {}
	for _, entry in ipairs(built) do
		for _, pane in ipairs(groundPanes(entry)) do
			table.insert(all, { pane = pane, entry = entry })
		end
	end
	return all
end

local measurement = {
	name = "window_vault_probe",
	settle = 1,
	hold = 1,
	setup = function(folder, camera)
		ensureRunning()
		local M = requireModules()
		template = template or makeTemplate()
		if not template then
			note("no rig, giving up")
			return
		end
		local g = workspace.Gravity
		local v = StarterPlayer.CharacterUseJumpPower and StarterPlayer.CharacterJumpPower or math.sqrt(2 * g * StarterPlayer.CharacterJumpHeight)
		local killOutside = (0.5 + SILL_HEIGHT) - CFG.VaultMinRise
		local disc = v * v - 2 * g * killOutside
		note("jump v %.1f, gravity %.1f: feet pass %.2f studs (vault from outside dies) at t = %.3fs; reach %.1f at sprint %.1f = %.3fs window",
			v, g, killOutside, disc >= 0 and (v - math.sqrt(disc)) / g or -1, CFG.Reach, SPRINT, CFG.Reach / SPRINT)
		note("band box: feet+%.1f to feet+%.1f, forward %.1f, body width x1.8; sill top is %.1f above the floor slab (ground outside 0.5 lower)",
			BAND_BOTTOM, BAND_TOP, GLASS_REACH, SILL_HEIGHT)

		local saved = stubLedger(M)
		installHook(M)

		local holder = freshHolder()
		local built = buildRow(M, holder, { "house", "tower", "warehouse" }, 7)
		task.wait(0.5)
		local allPanes = collectPanes(built)
		for _, entry in ipairs(built) do
			note("built %s %dx%d x%d floors: %d parts, %d panes, %d on the ground floor", entry.name, entry.plan.width, entry.plan.depth,
				entry.plan.floors, #entry.model:GetDescendants(), paneCount(entry.model), #groundPanes(entry))
		end
		if #allPanes == 0 then
			note("NO GROUND-FLOOR PANES BUILT, giving up")
			return
		end
		if not selfTest(allPanes[1].pane) then
			note("INSTRUMENT SELF-TEST FAILED: the hit classifier below cannot be trusted")
		end

		local rig = template:Clone()
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
		humanoid.JumpPower = StarterPlayer.CharacterJumpPower
		humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
		humanoid.MaxSlopeAngle = StarterPlayer.CharacterMaxSlopeAngle
		humanoid.WalkSpeed = SPRINT
		local root = rig.HumanoidRootPart
		local stand = humanoid.HipHeight + root.Size.Y / 2
		rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, stand, 120)))
		rig.Parent = folder
		M.Combatants.Register(rig, { isBot = true, name = "ProbeVaulter", character = rig })
		local fakePlayer = { isBot = true, name = "ProbePlayer", character = rig, Character = rig, Name = "ProbePlayer" }
		local L = { rig = rig, humanoid = humanoid, root = root, stand = stand, fakePlayer = fakePlayer }
		task.wait(1)
		note("rig: hip %.2f, stand %.2f -> root centre %.2f below the sill top outside, %.2f inside", humanoid.HipHeight, stand,
			(0.5 + SILL_HEIGHT) - stand, SILL_HEIGHT - stand)

		-- A: bots.
		local A = { examined = 0, vaulted = 0, gone = 0, survived = 0, othersLost = 0, found = 0, calls = 0 }
		for _, item in ipairs(allPanes) do
			local pane, model = item.pane, item.entry.model
			local before = paneCount(model)
			local neighbour, gap = neighbourPane(model, pane)
			A.examined += 1
			local r = botVault(M, L, pane)
			local after = paneCount(model)
			if r.kind == "vault" then
				A.vaulted += 1
				A.calls += r.calls
				local record = M.MovementService.LastGlass
				A.found += record and record.found or 0
				if r.survived then
					A.survived += 1
				else
					A.gone += 1
				end
				local expected = r.survived and before or before - 1
				if after < expected then
					A.othersLost += expected - after
				end
			end
			note("A bot %-9s %-9s: %s%s; pane %s; %s; calls %d; building panes %d -> %d; next pane along (%.1f studs) %s", item.entry.name,
				wallName(pane.CFrame.LookVector), tostring(r.kind), r.kind and "" or (" (" .. tostring(r.why) .. ")"),
				r.survived and "SURVIVED" or "gone", r.glass, r.calls, before, after, gap or -1,
				neighbour and (neighbour.Parent and "stands" or "GONE") or "none")
			task.wait(0.3)
		end
		note("A SUMMARY: %d panes examined, %d vaulted, %d gone, %d SURVIVED; panes in range %d, break calls %d; other panes lost %d",
			A.examined, A.vaulted, A.gone, A.survived, A.found, A.calls, A.othersLost)
		note("A VERDICT (a vault leaves no pane on its path AND breaks no other): %s",
			(A.vaulted > 0 and A.survived == 0 and A.othersLost == 0) and "PASS" or "FAIL")

		-- B: players.
		holder = freshHolder()
		built = buildRow(M, holder, { "house", "tower", "warehouse" }, 7)
		task.wait(0.5)
		allPanes = collectPanes(built)
		local B = { examined = 0, planned = 0, gone = 0, survived = 0, othersLost = 0, found = 0, calls = 0 }
		for index, item in ipairs(allPanes) do
			local pane, model = item.pane, item.entry.model
			local distance = index % 2 == 0 and 2.6 or 1.6
			local before = paneCount(model)
			local neighbour, gap = neighbourPane(model, pane)
			B.examined += 1
			local r = playerVault(M, L, pane, distance)
			local after = paneCount(model)
			if r.plan == "vault" then
				B.planned += 1
			end
			B.calls += r.calls
			local record = M.MovementService.LastGlass
			B.found += record and record.found or 0
			if r.survived then
				B.survived += 1
			else
				B.gone += 1
			end
			local expected = r.survived and before or before - 1
			if after < expected then
				B.othersLost += expected - after
			end
			note("B player %-9s %-9s d %.1f: client would plan %s; pane %s; %s; calls %d; building panes %d -> %d; next pane along (%.1f) %s",
				item.entry.name, wallName(pane.CFrame.LookVector), distance, r.plan, r.survived and "SURVIVED" or "gone", r.glass, r.calls,
				before, after, gap or -1, neighbour and (neighbour.Parent and "stands" or "GONE") or "none")
			task.wait(0.4)
		end
		note("B SUMMARY: %d panes examined, client would vault %d, %d gone, %d SURVIVED; panes in range %d, break calls %d; other panes lost %d",
			B.examined, B.planned, B.gone, B.survived, B.found, B.calls, B.othersLost)
		note("B VERDICT (a player's vault leaves no pane in front of the body AND breaks no other): %s",
			(B.survived == 0 and B.othersLost == 0) and "PASS" or "FAIL")

		-- P1: the break hook a no-op. The pane must survive, and the module must say so.
		holder = freshHolder()
		built = buildRow(M, holder, { "house" }, 7)
		task.wait(0.5)
		local house = built[1]
		local panes = house and groundPanes(house) or {}
		if #panes >= 2 then
			local wrapped = M.MovementService.BreakPane
			M.MovementService.BreakPane = function()
				return false
			end
			local warnsBefore = warnsSeen
			local r = playerVault(M, L, panes[1], 1.6)
			task.wait(0.2)
			M.MovementService.BreakPane = wrapped
			local record = M.MovementService.LastGlass
			local fired = r.survived and record and record.found > 0 and record.broken == 0
			note("P1 plant (BreakPane = no-op): pane %s; %s; warned %s -> plant %s", r.survived and "SURVIVED (correct)" or "GONE (wrong)",
				r.glass, warnsSeen > warnsBefore and "yes" or "NO", fired and "FIRED" or "DID NOT FIRE")
			if warnsSeen == warnsBefore then
				note("P1: MovementService did not warn about panes found and none broken -- the refusal is not surfaced")
			end

			-- P2: the hook breaks the next pane along as well; the count check must catch it.
			task.wait(0.4)
			local victim = panes[2]
			local neighbour = neighbourPane(house.model, victim)
			if neighbour then
				local before = paneCount(house.model)
				M.MovementService.BreakPane = function(token, pane, from)
					local ok = wrapped(token, pane, from)
					if neighbour.Parent then
						realBreak(token, neighbour, from)
					end
					return ok
				end
				local r2 = playerVault(M, L, victim, 1.6)
				M.MovementService.BreakPane = wrapped
				local after = paneCount(house.model)
				local expected = r2.survived and before or before - 1
				local caught = after < expected
				note("P2 plant (hook also breaks the next pane along): building panes %d -> %d (expected %d) -> other-pane check %s; plant %s",
					before, after, expected, caught and "CAUGHT IT" or "MISSED IT", caught and "FIRED" or "DID NOT FIRE")
			else
				note("P2: no neighbouring pane on that wall, plant not run")
			end
		else
			note("P1/P2: fewer than two ground-floor panes on the house, plants not run")
		end

		-- F: a fence in front of a window. The window is not on the path.
		holder = freshHolder()
		built = buildRow(M, holder, { "house" }, 7)
		task.wait(0.5)
		house = built[1]
		panes = house and groundPanes(house) or {}
		local target = nil
		for _, pane in ipairs(panes) do
			if pane.CFrame.LookVector.Z > 0.5 then
				target = pane
				break
			end
		end
		if target then
			local normal = target.CFrame.LookVector
			local face = target.Position + normal * (WALL_THICKNESS / 2)
			local fenceFace = face + normal * 3.0
			local fence = block(holder, Vector3.new(14, 2.5, 0.4), CFrame.lookAt(Vector3.new(fenceFace.X, ORIGIN.Y + 1.25, fenceFace.Z) + normal * 0.2, Vector3.new(fenceFace.X, ORIGIN.Y + 1.25, fenceFace.Z) + normal * 2),
				Color3.fromRGB(150, 110, 70))
			fence.Name = "ProbeFence"
			-- Bot: the plan carries the fence's own (no) panes.
			local rb = botVault(M, L, target, fenceFace)
			local survivedBot = target.Parent ~= nil
			note("F fence 3.0 in front of a window, BOT: %s%s; ended %+.1f past the fence; window pane %s; %s", tostring(rb.kind),
				rb.kind and "" or (" (" .. tostring(rb.why) .. ")"), rb.past, survivedBot and "stands (correct)" or "GONE (broke a pane it never passed)", rb.glass)
			-- Player: the band box reaches GLASS_REACH forward of the body.
			if target.Parent then
				local rp = playerVault(M, L, target, 1.6, fenceFace)
				note("F fence, PLAYER at 1.6 before the fence (%.1f before the pane): client would plan %s; window pane %s; %s", 1.6 + 3.0 + WALL_THICKNESS / 2,
					rp.plan, target.Parent and "stands (correct)" or "GONE (the box's forward risk, measured)", rp.glass)
			end
		else
			note("F: no back-wall pane on the house, fence case not run")
		end

		-- C: the census, on its own unanchored rig, one frame per placement.
		holder = freshHolder()
		built = buildRow(M, holder, { "house", "tower", "warehouse" }, 7)
		task.wait(0.5)
		local censusPanes = {}
		for _, item in ipairs(collectPanes(built)) do
			table.insert(censusPanes, item.pane)
		end
		rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, stand, 130)))
		local censusRig = template:Clone()
		censusRig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 3.2, 140)))
		censusRig.Parent = folder
		task.wait(0.5)
		note("census: %d ground-floor panes across %d buildings", #censusPanes, #built)
		local okCensus, err = pcall(census, censusRig, censusPanes)
		if not okCensus then
			note("census FAILED: %s", tostring(err))
		end

		M.Combatants.Unregister(rig)
		restoreLedger(M, saved)
		if lastHolder then
			lastHolder:Destroy()
			lastHolder = nil
		end
		camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 40, 200), ORIGIN)
	end,
}

--------------------------------------------------------------------------------
-- Render views
--------------------------------------------------------------------------------

local function occlusion(camera, target, label, allow)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local from = camera.CFrame.Position
	local result = workspace:Raycast(from, target - from, params)
	if not result then
		note("view %s: camera -> target clear (%.1f studs)", label, (target - from).Magnitude)
		return
	end
	local blocker = result.Instance
	if allow and (blocker == allow or blocker:IsDescendantOf(allow)) then
		note("view %s: camera -> target reaches %s first (the subject itself)", label, blocker:GetFullName())
	else
		note("view %s: camera -> target OCCLUDED by %s at %.1f studs", label, blocker:GetFullName(), result.Distance)
	end
end

local function firstBackPane(entry)
	for _, pane in ipairs(groundPanes(entry)) do
		if pane.CFrame.LookVector.Z > 0.5 then
			return pane
		end
	end
	return groundPanes(entry)[1]
end

local boxView = {
	name = "window_band_box",
	settle = 1.5,
	setup = function(folder, camera)
		ensureRunning()
		local M = requireModules()
		template = template or makeTemplate()
		if not template then
			return
		end
		local holder = freshHolder()
		local built = buildRow(M, holder, { "house" }, 7)
		local entry = built[1]
		local pane = entry and firstBackPane(entry)
		if not pane then
			note("view box: no pane")
			return
		end
		local normal = pane.CFrame.LookVector
		local tangent = normal:Cross(Vector3.yAxis).Unit
		local face = pane.Position + normal * (WALL_THICKNESS / 2)
		local rig = template:Clone()
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local root = rig.HumanoidRootPart
		local stand = humanoid.HipHeight + root.Size.Y / 2
		local spot = Vector3.new(face.X, ORIGIN.Y + stand, face.Z) + normal * 1.6
		rig:PivotTo(CFrame.lookAt(spot, spot - normal))
		root.Anchored = true
		rig.Parent = folder
		-- The old ray (red, from the root centre) and the new band box (green), both as the server casts them.
		local from = root.Position
		local hit = firstHit(from, from - normal * GLASS_REACH)
		local beamEnd = hit.position or (from - normal * GLASS_REACH)
		block(folder, Vector3.new(0.15, 0.15, (beamEnd - from).Magnitude), CFrame.lookAt((from + beamEnd) / 2, beamEnd), Color3.fromRGB(255, 40, 40),
			{ Material = Enum.Material.Neon, CanCollide = false, CanQuery = false })
		local feetY = root.Position.Y - stand
		local bottom, top = feetY + BAND_BOTTOM, feetY + BAND_TOP
		local centre = Vector3.new(from.X, (bottom + top) / 2, from.Z) - normal * (GLASS_REACH / 2)
		block(folder, Vector3.new(1.8, top - bottom, GLASS_REACH), CFrame.lookAt(centre, centre - normal), Color3.fromRGB(60, 255, 90),
			{ Material = Enum.Material.Neon, Transparency = 0.75, CanCollide = false, CanQuery = false })
		local inBox = 0
		local overlap = OverlapParams.new()
		overlap.FilterType = Enum.RaycastFilterType.Include
		overlap.FilterDescendantsInstances = { workspace.Map }
		for _, part in ipairs(workspace:GetPartBoundsInBox(CFrame.lookAt(centre, centre - normal), Vector3.new(1.8, top - bottom, GLASS_REACH), overlap)) do
			if part.Name == "WindowGlass" then
				inBox += 1
			end
		end
		note("view box: old ray from y %.2f hits %s; band box y %.2f..%.2f holds %d pane(s); sill top y %.2f", from.Y - ORIGIN.Y, hit.name,
			bottom - ORIGIN.Y, top - ORIGIN.Y, inBox, pane.Position.Y - pane.Size.Y / 2 + 0.1 - ORIGIN.Y)
		local target = Vector3.new(face.X, ORIGIN.Y + 5, face.Z) + normal * 0.8
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(target + normal * 11 + tangent * 9 + Vector3.new(0, 3, 0), target)
		occlusion(camera, root.Position, "box/body", rig)
		occlusion(camera, pane.Position, "box/pane", pane)
	end,
}

local afterView = {
	name = "window_after_bot_vault",
	settle = 1.5,
	setup = function(folder, camera)
		ensureRunning()
		local M = requireModules()
		template = template or makeTemplate()
		if not template then
			return
		end
		local saved = stubLedger(M)
		installHook(M)
		local holder = freshHolder()
		local built = buildRow(M, holder, { "house" }, 7)
		local entry = built[1]
		local pane = entry and firstBackPane(entry)
		if not pane then
			note("view after: no pane")
			return
		end
		local neighbour = neighbourPane(entry.model, pane)
		local rig = template:Clone()
		local humanoid = rig:FindFirstChildOfClass("Humanoid")
		local root = rig.HumanoidRootPart
		humanoid.WalkSpeed = SPRINT
		rig:PivotTo(CFrame.new(ORIGIN + Vector3.new(0, 5, 60)))
		rig.Parent = folder
		local stand = humanoid.HipHeight + root.Size.Y / 2
		M.Combatants.Register(rig, { isBot = true, name = "ProbeVaulter2", character = rig })
		task.wait(1)
		local panePosition, paneNormal = pane.Position, pane.CFrame.LookVector
		local r = botVault(M, { rig = rig, humanoid = humanoid, root = root, stand = stand }, pane)
		root.Anchored = true
		M.Combatants.Unregister(rig)
		restoreLedger(M, saved)
		note("view after: bot %s, ended %+.1f past the face, pane %s, next pane along %s; %s", tostring(r.kind), r.past,
			r.survived and "SURVIVED" or "gone", neighbour and (neighbour.Parent and "stands" or "GONE") or "none", r.glass)
		camera.FieldOfView = 60
		camera.CFrame = CFrame.lookAt(panePosition + paneNormal * 9 + Vector3.new(0, 1.5, 0), panePosition - paneNormal * 2)
		occlusion(camera, root.Position, "after/body", rig)
	end,
}

--------------------------------------------------------------------------------
-- Throwable model views (claude-43's three cosmetic findings; the latte wire and the crumpet holes)
--------------------------------------------------------------------------------

local function partsOf(model)
	local list = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(list, part)
		end
	end
	return list
end

-- The item z-fight audit's measurement (tools/audit_items_zfight.lua), for one item at scale 1: flush
-- pairs in the written geometry, parts the build's own pass moved or resized, and a second pass.
local function measureItem(id)
	local wasEnabled = ZFight.Enabled
	ZFight.Enabled = false
	local raw = ItemModels.Build(id, { scale = 1, anchored = true })
	ZFight.Enabled = wasEnabled
	local fixed = ItemModels.Build(id, { scale = 1, anchored = true })
	if not raw or not fixed then
		note("item %s: build failed", id)
		return nil
	end
	local written = ZFight.Scan({ raw }, ZFight.FixTolerance)
	local a, b = partsOf(raw), partsOf(fixed)
	local rawOrigin = raw.PrimaryPart and raw.PrimaryPart.CFrame or CFrame.new()
	local fixedOrigin = fixed.PrimaryPart and fixed.PrimaryPart.CFrame or CFrame.new()
	local changed = 0
	for index = 1, math.min(#a, #b) do
		local ra, rb = rawOrigin:ToObjectSpace(a[index].CFrame), fixedOrigin:ToObjectSpace(b[index].CFrame)
		if (ra.Position - rb.Position).Magnitude > 0.001 or (b[index].Size - a[index].Size).Magnitude > 0.001 then
			changed += 1
		end
	end
	local again = ZFight.Fix({ fixed }, { all = true })
	local pairNames = {}
	for index = 1, math.min(#written, 6) do
		table.insert(pairNames, string.format("%s/%s", written[index].a.Name, written[index].b.Name))
	end
	note("item %s x1: %d parts; written flush pairs %d [%s]; build pass changed %d; second pass moved %d resized %d -> %s", id, #a,
		#written, table.concat(pairNames, "; "), changed, again.moved, again.resized,
		(#written == 0 and changed == 0 and again.moved + again.resized == 0) and "CLEAN" or "DIRTY")
	raw:Destroy()
	return fixed
end

-- Whether a point lies inside a part (box or cylinder-along-X), in the part's own frame.
local function inside(part, point)
	local p = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	if part.Shape == Enum.PartType.Cylinder then
		return math.abs(p.X) <= half.X + 1e-3 and math.sqrt(p.Y * p.Y + p.Z * p.Z) <= half.Y + 1e-3
	end
	return math.abs(p.X) <= half.X + 1e-3 and math.abs(p.Y) <= half.Y + 1e-3 and math.abs(p.Z) <= half.Z + 1e-3
end

local function itemView(id, look)
	return {
		name = "item_" .. id,
		settle = 1.5,
		setup = function(folder, camera)
			local spot = ORIGIN + Vector3.new(0, 300, 0)
			block(folder, Vector3.new(6, 0.5, 6), CFrame.new(spot - Vector3.new(0, 0.75, 0)), Color3.fromRGB(70, 70, 76))
			local model = measureItem(id)
			if not model then
				return
			end
			model.Parent = folder
			model:PivotTo(CFrame.new(spot))
			local parts = partsOf(model)
			if id == "LowkeyLatte" then
				local rod, glow, tab = nil, nil, nil
				for _, part in ipairs(parts) do
					if part.Name == "TabWire" and part.Shape == Enum.PartType.Cylinder then
						rod = part
					elseif part.Name == "Glow" then
						glow = part
					elseif part.Name == "PullTab" then
						tab = part
					end
				end
				if rod and glow and tab then
					local axis = rod.CFrame.RightVector * (rod.Size.X / 2)
					local endA, endB = rod.Position - axis, rod.Position + axis
					local joinsGlow = inside(glow, endA) or inside(glow, endB)
					local joinsTab = inside(tab, endA) or inside(tab, endB)
					note("item LowkeyLatte wire: one end inside the glow %s, the other inside the tab %s -> %s",
						joinsGlow and "YES" or "NO", joinsTab and "YES" or "NO", (joinsGlow and joinsTab) and "JOINED" or "FLOATING")
				else
					note("item LowkeyLatte wire: parts not found (rod %s glow %s tab %s)", tostring(rod ~= nil), tostring(glow ~= nil), tostring(tab ~= nil))
				end
			elseif id == "ClingyCrumpet" then
				local body = model.PrimaryPart
				local bodyTop = body and (body.Position.Y + body.Size.X / 2) or 0
				local holes, tallest, widest, minProud, maxProud = 0, 0, 0, math.huge, -math.huge
				for _, part in ipairs(parts) do
					if part.Name == "Hole" then
						holes += 1
						local height, diameter = part.Size.X, part.Size.Y
						tallest = math.max(tallest, height)
						widest = math.max(widest, diameter)
						local proud = part.Position.Y + height / 2 - bodyTop
						minProud, maxProud = math.min(minProud, proud), math.max(maxProud, proud)
					end
				end
				note("item ClingyCrumpet holes: %d, tallest %.3f, widest %.3f (height/width %.2f), proud of the top %.3f..%.3f -> %s", holes,
					tallest, widest, widest > 0 and tallest / widest or 0, minProud, maxProud,
					(widest > 0 and tallest / widest <= 0.6) and "DISCS" or "PEGS")
			end
			local box, size = model:GetBoundingBox()
			local focus = box.Position + Vector3.new(0, size.Y * 0.25, 0)
			camera.FieldOfView = 30
			camera.CFrame = CFrame.lookAt(focus + look.Unit * (size.Magnitude * 2.2), focus)
			occlusion(camera, focus, "item " .. id, model)
		end,
	}
end

return { measurement, boxView, afterView, itemView("LowkeyLatte", Vector3.new(1.2, 0.9, -1.0)), itemView("ClingyCrumpet", Vector3.new(0.8, 1.4, -0.9)) }
