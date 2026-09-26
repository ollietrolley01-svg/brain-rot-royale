-- Bot gunner probe (task 20): a bot on a mounted gun against a moving target, in Run mode, with the real
-- BotService, VehicleService, MountedGuns and VehicleWeapons. tools/bot_gunner_engage_check.py proves the
-- same code in lupa against spheres; this is the real mounts, the real physics and the real ray casts.
--
--   python tools/linux/studio.py runtest -Probe tools/bot_gunner_probe.lua -WaitSeconds 300 -PlaceFile <build>
--   python tools/linux/studio.py gallery -Gallery tools/bot_gunner_probe.lua -OutDir <dir> -PlaceFile <build>
-- (or tools/runtest.ps1 / tools/gallery.ps1 on Windows). Under the gallery the same run is measured, then
-- the views put the camera behind each gun, looking down its line at the target.
--
-- Each case is a pad high over the void, 900 studs from the next (past every gun's reach): a parked
-- Rotster (roof gun, 320 studs) or a Rattlefang HMG emplacement (450 studs, +-60 degrees), a bot on foot
-- 8 studs from its gun seat, and a stand-in target running across the gun's line at 16 studs/s, turning
-- back every 4 s, at a range both builds engage (200) and one only a gun-sized reach does (300 for the car,
-- 400 for the emplacement). The bot gets on the gun by itself (BotService's own seat choice; a team mode is
-- patched in, as only a team mode puts bots on vehicle guns; until it is on, the runner counts as shooting at
-- it, so a bot too far to see the runner still goes for the gun rather than the wheel). Once it is on, for MEASURE seconds the probe
-- counts its mount's shots (VehicleWeapons.Fire), the hits on the target and the damage (counted, NOT
-- applied), and the thinks it had the target. Time to kill is to 100 health after the match's damage scale.
--
-- Lines start "[BRR_Gunner]". Not measured: a real player dodging, the gun on a moving car, lag.

local MEASURE = 40
local BOARD_WAIT = 45
local PAD_Y = 1600
local PAD_X = -9000
local RUN_SPEED = 16
local TURN = 4

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local function say(fmt, ...)
	print(string.format("[BRR_Gunner] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local function mod(name)
	return require(modules:WaitForChild(name))
end
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CombatService = mod("CombatService")
local Combatants = mod("Combatants")
local VehicleService = mod("VehicleService")
local VehicleWeapons = mod("VehicleWeapons")
local MountedGuns = mod("MountedGuns")
local ModeTeams = mod("ModeTeams")
local StormService = mod("StormService")
local BotService = mod("BotService")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local MountedGunData = require(Shared:WaitForChild("MountedGunData"))

-- No match runs, so: a team mode for the probe's own tokens (team 1 the bots, 2 the targets), and no storm
-- (with no match its radius is 0, so everywhere is "outside" and a gunner with no driver would get down).
local teamOf = {}
ModeTeams.IsActive = function()
	return true
end
ModeTeams.TeamOf = function(token)
	return teamOf[token]
end
ModeTeams.BaseOf = function()
	return nil
end
StormService.IsOutside = function()
	return false
end

VehicleService.Start()
MountedGuns.Start()
MountedGuns.OnMapBuilt(nil, { teams = true })
CombatService.SetEnabled(true)

local arena = Instance.new("Model")
arena.Name = "BRR_GunnerProbeArena"
arena.Parent = workspace
local function block(name, size, cframe)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = Enum.Material.Concrete
	part.Parent = arena
	return part
end

local rows = {}
local byBot = {}
local scale = MatchConfig.CombatDamageScale or 1

-- For the pictures: no client runs in Run mode, so the game's tracers and the turret's swing (both drawn by
-- clients) never show. The probe draws its own: a yellow line from the gun's muzzle to where each shot was
-- aimed (a rolled miss is aimed off to the side), and the target's torso flashes white on a hit. Neither can
-- be hit or cast against (CanQuery off).
local function drawShot(row, aim)
	local from = row.muzzle and row.muzzle.Position
	if not from then
		return
	end
	local length = (aim - from).Magnitude
	local line = Instance.new("Part")
	line.Anchored, line.CanCollide, line.CanQuery, line.CanTouch = true, false, false, false
	line.Material = Enum.Material.Neon
	line.Color = Color3.fromRGB(255, 220, 60)
	line.Size = Vector3.new(0.35, 0.35, length)
	line.CFrame = CFrame.lookAt((from + aim) / 2, aim)
	line.Parent = arena
	task.delay(0.12, function()
		line:Destroy()
	end)
end
local function flashHit(row)
	local torso = row.parts.torso
	torso.Color = Color3.new(1, 1, 1)
	torso.Material = Enum.Material.Neon
	task.delay(0.15, function()
		torso.Color = Color3.fromRGB(220, 60, 60)
		torso.Material = Enum.Material.Plastic
	end)
end

-- Taps: the mount's shots, and damage to the probe's targets (counted, not applied).
local realFire = VehicleWeapons.Fire
VehicleWeapons.Fire = function(token, aim, ...)
	local ok, why = realFire(token, aim, ...)
	local row = byBot[token]
	if row and ok then
		if row.measuring then
			row.shots += 1
		end
		drawShot(row, aim)
	end
	return ok, why
end
local realDeal = CombatService.DealDamage
CombatService.DealDamage = function(attacker, victim, amount, ...)
	local row = byBot[attacker]
	if row and victim == row.token then
		flashHit(row)
		if row.measuring and row.onGun then
			row.hits += 1
			row.damage += amount * scale
			if not row.ttk and row.damage >= 100 then
				row.ttk = tick() - row.since
			end
		end
		return amount
	end
	return realDeal(attacker, victim, amount, ...)
end

-- A stand-in target: root, torso, head and a humanoid, registered as a combatant, moved by the probe.
local function standIn(name, position)
	local model = Instance.new("Model")
	model.Name = name
	local function limb(partName, size, offset)
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.CFrame = CFrame.new(position + offset)
		p.Anchored = true
		p.Parent = model
		return p
	end
	local root = limb("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.zero)
	root.Transparency = 1
	local torso = limb("Torso", Vector3.new(2, 2, 1), Vector3.zero)
	torso.Color = Color3.fromRGB(220, 60, 60)
	local head = limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0))
	local legs = limb("Legs", Vector3.new(2, 2, 1), Vector3.new(0, -2, 0))
	local humanoid = Instance.new("Humanoid")
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth, humanoid.Health = 1e6, 1e6
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = arena
	local token = { name = name, character = model }
	Combatants.Register(model, token)
	return token, model, { root = root, torso = torso, head = head, legs = legs }
end

local CASES = {
	{ name = "Rotster roof gun, runner at 200", kind = "car", range = 200 },
	{ name = "Rotster roof gun, runner at 300", kind = "car", range = 300 },
	{ name = "Rattlefang HMG emplacement, runner at 200", kind = "hmg", range = 200 },
	{ name = "Rattlefang HMG emplacement, runner at 400", kind = "hmg", range = 400 },
}
local VIEWS = {}

for index, case in ipairs(CASES) do
	local ok, err = pcall(function()
		local c = Vector3.new(PAD_X - index * 900, PAD_Y, 0)
		block("Pad" .. index, Vector3.new(160, 2, 900), CFrame.new(c + Vector3.new(0, -1, -380)))
		local row = { case = case, shots = 0, hits = 0, damage = 0, thinks = 0, targeted = 0 }
		local gun, seat, facing
		if case.kind == "car" then
			gun = VehicleService.Create(arena, c + Vector3.new(0, 3, 0), 0, "car", { model = "Rotster" })
			assert(gun, "no Rotster")
			seat = gun:FindFirstChild("GunnerSeat")
		else
			local spot = Instance.new("Part")
			spot.Name = "GunEmplacement"
			spot.Anchored, spot.Transparency, spot.CanCollide, spot.CanQuery = true, 1, false, false
			spot.Size = Vector3.new(1, 1, 1)
			spot.CFrame = CFrame.new(c)
			spot:SetAttribute("Kind", "hmg")
			spot.Parent = arena
			CollectionService:AddTag(spot, MountedGunData.EmplacementTag)
			task.wait(0.5)
			for _, model in ipairs(CollectionService:GetTagged(MountedGunData.Tag)) do
				if model.PrimaryPart and (model.PrimaryPart.Position - c).Magnitude < 10 then
					gun = model
				end
			end
			assert(gun, "no emplacement built")
			-- It covers the lanes (a team battleground's own mark), so a bot may take it with nobody in sight yet.
			gun:SetAttribute("BotCovers", true)
			seat = gun:FindFirstChild("GunnerSeat", true)
		end
		assert(seat, "no GunnerSeat")
		task.wait(1)
		-- Down the gun's front (-Z), across it: the car's roof gun turns all the way round, the emplacement +-60.
		local base = c + Vector3.new(0, 3, -case.range)
		local token, model, parts = standIn("Target" .. index, base)
		teamOf[token] = 2
		row.token, row.parts, row.base, row.gun = token, parts, base, gun
		row.muzzle = gun:FindFirstChild("TurretMuzzle", true)
		local at = seat.Position + Vector3.new(6, 1, 6)
		local bot = BotService.Spawn(1, function()
			return CFrame.lookAt(at, Vector3.new(base.X, at.Y, base.Z))
		end, function() end)[1]
		assert(bot, "no bot")
		teamOf[bot] = 1
		bot.weapon = WeaponData.Get("CrocodiloRifle")
		bot.noVehicleUntil = 0
		row.bot = bot
		byBot[bot] = row
		rows[index] = row
		table.insert(VIEWS, { index = index, gun = gun, base = base, name = case.kind .. "_" .. case.range })
	end)
	if not ok then
		say("case %s SETUP FAILED: %s", case.name, tostring(err))
	end
end

-- The runners: across the line, turning back every TURN seconds, velocity published for the aim to read.
local t0 = tick()
RunService.Heartbeat:Connect(function()
	local t = tick() - t0
	local u = t % (2 * TURN)
	local leg = u < TURN
	local along = leg and (u - TURN / 2) or (TURN / 2 - (u - TURN))
	local velocity = Vector3.new(leg and RUN_SPEED or -RUN_SPEED, 0, 0)
	for _, row in pairs(rows) do
		local at = row.base + Vector3.new(along * RUN_SPEED, 0, 0)
		row.parts.root.CFrame = CFrame.new(at)
		row.parts.torso.CFrame = CFrame.new(at)
		row.parts.head.CFrame = CFrame.new(at + Vector3.new(0, 1.6, 0))
		row.parts.legs.CFrame = CFrame.new(at - Vector3.new(0, 2, 0))
		row.parts.root.AssemblyLinearVelocity = velocity
	end
end)

BotService.Start()
local start = tick()
while tick() - start < BOARD_WAIT do
	task.wait(0.25)
	local waiting = false
	for _, row in pairs(rows) do
		local ride = row.bot.ride
		if ride and ride.role == "gunner" and not row.boardedAt then
			row.boardedAt = tick() - start
		end
		if not row.boardedAt then
			-- Past a bot's vision on foot it can't see the runner, so nothing makes it "in a fight" and it may take
			-- the wheel instead: until it is on the gun, the runner is marked as the one shooting at it (bot.threat,
			-- what a real hit leaves), which is pickSeat's fight branch, the gun seat first.
			row.bot.threat = { token = row.token, position = row.parts.root.Position, at = tick() }
		end
		waiting = waiting or not row.boardedAt
	end
	if not waiting then
		break
	end
end
for _, row in pairs(rows) do
	row.measuring = true
	row.since = tick()
end
local mstart = tick()
while tick() - mstart < MEASURE do
	task.wait(0.25)
	for _, row in pairs(rows) do
		local ride = row.bot.ride
		row.onGun = ride ~= nil and ride.role == "gunner"
		if row.onGun then
			row.thinks += 1
			if row.bot.target == row.token then
				row.targeted += 1
			end
		end
	end
end
for _, row in pairs(rows) do
	row.measuring = false
end

for index, case in ipairs(CASES) do
	local row = rows[index]
	if row then
		local ride = row.bot.ride
		say("%s: on the gun after %s s, still on at the end %s (last exit %s); target held %d/%d samples on the gun; mount shots %d, hits %d (%.0f%%), damage %.0f in %d s (%.1f/s); time to kill %s",
			case.name, row.boardedAt and string.format("%.1f", row.boardedAt) or "NEVER", tostring(ride ~= nil and ride.role == "gunner"),
			tostring(row.bot.lastVehicleExit), row.targeted, row.thinks, row.shots, row.hits,
			100 * row.hits / math.max(1, row.shots), row.damage, MEASURE, row.damage / MEASURE,
			row.ttk and string.format("%.1f s", row.ttk) or "never")
	end
end
say("done")

-- Under the gallery: the camera behind each gun, down its line at the runner; then CLIP_FRAMES frames in a
-- row of the two cases past the old 260-stud look (tools stitch them into a GIF), about 0.4 s apart.
local CLIP_FRAMES = 36
local views = {}
for _, v in ipairs(VIEWS) do
	table.insert(views, {
		name = "gunner_" .. v.name,
		settle = 1,
		hold = 1.5,
		setup = function(_, camera)
			local pivot = v.gun:GetPivot().Position
			local eye = pivot + Vector3.new(9, 11, 24)
			camera.FieldOfView = 50
			camera.CFrame = CFrame.lookAt(eye, v.base)
		end,
	})
end
for _, key in ipairs({ "hmg_400", "car_300" }) do
	for _, v in ipairs(VIEWS) do
		if v.name == key then
			for frame = 1, CLIP_FRAMES do
				table.insert(views, {
					name = string.format("clip_%s_%03d", key, frame),
					settle = 0.05,
					hold = 0.35,
					setup = function(_, camera)
						local pivot = v.gun:GetPivot().Position
						if key == "car_300" then
							-- Behind and above the car's gunner, so their head sits under the line rather than on it,
							-- looking a little way down the line so the car and the runner are both in frame.
							local down = Vector3.new(v.base.X - pivot.X, 0, v.base.Z - pivot.Z).Unit
							camera.FieldOfView = 55
							camera.CFrame = CFrame.lookAt(pivot + Vector3.new(0, 13, 20), pivot + down * 60 + Vector3.new(0, 2, 0))
						else
							camera.FieldOfView = 30
							camera.CFrame = CFrame.lookAt(pivot + Vector3.new(4, 9, 22), v.base)
						end
					end,
				})
			end
		end
	end
end
return views
