-- Task 26 filmed live: a Team Deathmatch's opening at team 1's base, from above, as the bots spawn.
-- Each team-1 bot carries a label: what it is doing (LOOTING <chest/gun/heal> when its loot target is
-- inside its own base, GEARING UP while in the gear-up phase, HEADING OUT otherwise) and what it carries.
-- A sign over the base counts them. Before task 26 they detour to the chests; after, they leave with the kit.
--
--   studio.py gallery -Gallery tools/bot_kit_gallery.lua -OutDir <dir> -PlaceFile <build> -Record <dir>/x.mp4
--
-- The match is real (this VM's MatchService, MinPlayers 0, Team Deathmatch on SahurSprings), kept open
-- by one player-shaped token parked over the arena (tools/bot_kit_probe.lua says why). Lines start "[BOTKITFILM]".

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local function out(fmt, ...)
	print("[BOTKITFILM] " .. string.format(fmt, ...))
end

local FILM_SECONDS = 55
local MAP = "SahurSprings"

if not RunService:IsRunning() then
	RunService:Run()
end
task.wait(4)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Modules = ServerScriptService:WaitForChild("Modules")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local VoteService = require(Modules:WaitForChild("VoteService"))
local BotService = require(Modules:WaitForChild("BotService"))
local ModeTeams = require(Modules:WaitForChild("ModeTeams"))
local LootService = require(Modules:WaitForChild("LootService"))
local Combatants = require(Modules:WaitForChild("Combatants"))

MatchConfig.MinPlayers = 0
MatchConfig.LobbyCountdown = 2
MatchConfig.AllReadyCountdown = 2
VoteService.Resolve = function()
	return MAP, "TeamDeathmatch"
end

-- The keep-alive token, as in tools/bot_kit_probe.lua.
local keepAlive = {}
local realIsPlayer = Combatants.IsPlayer
Combatants.IsPlayer = function(token)
	if keepAlive[token] and debug.info(2, "n") == "realPlayersAlive" then
		return true
	end
	return realIsPlayer(token)
end
local spawnedAt
local realSpawn = BotService.Spawn
BotService.Spawn = function(count, cframeFor, onSpawned, options)
	if count >= 4 and type(onSpawned) == "function" and not spawnedAt then
		local model = Instance.new("Model")
		model.Name = "BotKitFilmKeepAlive"
		for _, name in ipairs({ "HumanoidRootPart", "Head" }) do
			local part = Instance.new("Part")
			part.Name = name
			part.Size = Vector3.new(2, 2, 1)
			part.Anchored, part.CanCollide, part.CanQuery, part.Transparency = true, false, false, 1
			part.Parent = model
		end
		local humanoid = Instance.new("Humanoid")
		humanoid.MaxHealth, humanoid.Health = 1e9, 1e9
		humanoid.RequiresNeck, humanoid.BreakJointsOnDeath = false, false
		humanoid.Parent = model
		model.PrimaryPart = model.HumanoidRootPart
		local sky = (ModeTeams.Arena() or Vector3.zero) + Vector3.new(0, 400, 0)
		model.Parent = workspace
		model:PivotTo(CFrame.new(sky))
		local token = { isBot = false, name = "BotKitFilmKeepAlive", character = model, humanoid = humanoid }
		keepAlive[token] = true
		Combatants.Register(model, token)
		pcall(onSpawned, token, humanoid)
		task.spawn(function()
			while model.Parent do
				model:PivotTo(CFrame.new(sky))
				task.wait(1)
			end
		end)
		spawnedAt = tick()
	end
	return realSpawn(count, cframeFor, onSpawned, options)
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

local folder = Instance.new("Folder")
folder.Name = "BotKitFilm"
folder.Parent = workspace

local function label(adornee, width, height, offset)
	local board = Instance.new("BillboardGui")
	board.Size = UDim2.fromOffset(width, height)
	board.StudsOffset = offset
	board.AlwaysOnTop = true
	board.Adornee = adornee
	board.Parent = folder
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
	text.BackgroundTransparency = 0.25
	text.TextColor3 = Color3.new(1, 1, 1)
	text.TextStrokeTransparency = 0.4
	text.Font = Enum.Font.GothamBold
	text.TextScaled = true
	text.RichText = true
	text.Parent = board
	return text
end

local function kitText(bot)
	local gun = bot.weapon and (bot.weapon.name or bot.weapon.id) or "no gun"
	local throw = 0
	for _, n in pairs(bot.throwables or {}) do
		throw += n
	end
	local heals = ((bot.heals and bot.heals.Bandage) or 0) + ((bot.heals and bot.heals.MedKit) or 0)
	return string.format("%s  %dH %dX %dD %dR", gun, heals, throw, bot.defenses or 0, bot.rockets or 0)
end

MatchService.Start()
-- The base exists once ModeTeams.Setup has run (just before the bots spawn).
local base
local deadline = tick() + 400
while tick() < deadline do
	base = ModeTeams.BaseOf(1)
	if base then
		break
	end
	task.wait(0.2)
end
if not base then
	out("FAIL no team base after 400 s (state %s)", tostring(MatchService.GetState()))
	return {}
end
local centre = ModeTeams.Arena() or Vector3.zero
local baseRadius = (LootService.BaseRadius or 85) + 10
local toMiddle = Vector3.new(centre.X - base.X, 0, centre.Z - base.Z).Unit
local eye = base - toMiddle * 95 + Vector3.new(0, 150, 0)
local look = base + toMiddle * 45
local camera = workspace.CurrentCamera
camera.CameraType = Enum.CameraType.Scriptable
camera.FieldOfView = 70
out("base 1 at %s, %.0f studs from the middle", tostring(base), flat(base - centre))

local signPart = Instance.new("Part")
signPart.Anchored, signPart.CanCollide, signPart.CanQuery, signPart.Transparency = true, false, false, 1
signPart.Position = base + toMiddle * 45 + Vector3.new(0, 45, 0)
signPart.Parent = folder
local sign = label(signPart, 560, 90, Vector3.zero)

local labels = {}
local counts = { looting = 0, gearing = 0, out = 0 }
local film = RunService.Heartbeat:Connect(function()
	camera.CFrame = CFrame.lookAt(eye, look)
end)
local stats = { lootingLives = 0, lives = 0 }
local seen = {}
while not spawnedAt or tick() - spawnedAt < FILM_SECONDS do
	counts.looting, counts.gearing, counts.out = 0, 0, 0
	for _, bot in ipairs(BotService.GetAll()) do
		local character = bot.character
		local head = character and character.Parent and character:FindFirstChild("Head")
		local state = BotService.ModeState(bot)
		if head and bot.humanoid.Health > 0 and state and state.team == 1 then
			local text = labels[character]
			if not text then
				text = label(head, 170, 40, Vector3.new(0, 3.5, 0))
				labels[character] = text
			end
			if not seen[character] then
				seen[character] = true
				stats.lives += 1
			end
			local target = bot.lootTarget
			local what
			if target and target.Parent and flat(target.Position - base) <= baseRadius then
				what = target.Name == "Chest" and "CHEST" or target.Name == "GroundWeapon" and "GUN" or "HEAL"
				counts.looting += 1
				if seen[character] ~= "looted" then
					seen[character] = "looted"
					stats.lootingLives += 1
				end
				text.Text = string.format('<font color="#FF8A3D">LOOTING %s</font>\n%s', what, kitText(bot))
			elseif bot.gearUntil and tick() < bot.gearUntil then
				counts.gearing += 1
				text.Text = string.format('<font color="#FFD84A">GEARING UP</font>\n%s', kitText(bot))
			else
				counts.out += 1
				text.Text = string.format('<font color="#6BE36B">HEADING OUT</font>\n%s', kitText(bot))
			end
		end
	end
	for character, text in pairs(labels) do
		if not character.Parent then
			text.Parent.Parent = nil
			labels[character] = nil
		end
	end
	sign.Text = string.format('Team 1 base, %s s after spawn\n<font color="#FF8A3D">%d looting</font>   <font color="#FFD84A">%d gearing up</font>   <font color="#6BE36B">%d heading out</font>\nkit: gun  H heals  X explosives  D defenses  R rockets',
		spawnedAt and string.format("%.0f", tick() - spawnedAt) or "-", counts.looting, counts.gearing, counts.out)
	task.wait(0.1)
	if tick() > deadline + 200 then
		break
	end
end
out("filmed: %d team-1 lives, %d of them targeted base loot", stats.lives, stats.lootingLives)
film:Disconnect()
return { { name = "end_state", settle = 0.2, hold = 0.5, setup = function(_, cam) cam.CFrame = CFrame.lookAt(eye, look) end } }
