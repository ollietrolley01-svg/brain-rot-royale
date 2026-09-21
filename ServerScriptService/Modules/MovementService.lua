-- Movement items: what happens when you use one. WeaponService owns the inventory and the use
-- timing and calls the effect here once an item has finished being used; the item is only spent
-- if the effect actually happened.
--
--   Speed Soda    +65% movement speed for 10 seconds, stacking with sprint, and a RUSH: stamina
--                 is full and nothing costs any while it lasts
--   Rot Rocket    blasts you high and far; aim up for height, level for distance, and the flight
--                 keeps its speed all the way down
--   Launch Pad    drops a pad that throws anyone who steps on it high into the air, along the way
--                 they were running, for 30 seconds
--   Blink Bean    an instant 44-stud dash the way you're facing, stopping short of walls, that
--                 comes out of the dash still moving at a sprint and cancels a fall
--   Bounce Boots  nearly triple-height jumps plus one mid-air double jump, for 18 seconds
--   Rot Glider    a wing over your head: opened near the ground an updraft throws you up first,
--                 then you sail where you look for 16 seconds, falling slowly
--
-- A player's character is simulated by their own client, so the server can't reliably shove it;
-- launches and glides are sent to that client to apply (StarterPlayerScripts/MovementClient, which
-- also keeps a launch's speed through the air instead of letting the humanoid's air control brake
-- it). Teleports and jump height the server can set directly.
--
-- This module also runs ledge climbs and vaults for bots on the server (CanParkour / TryParkour,
-- through Shared/Parkour, the same rules a player's client uses), takes a player's word that they
-- climbed or vaulted (ClientParkour: charges stamina, poses them for everyone else), and owns the
-- character attribute `Parkour` ("slide" | "mantle" | "vault") that other clients pose from.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local MovementConfig = require(Shared:WaitForChild("MovementConfig"))
local Parkour = require(Shared:WaitForChild("Parkour"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local SafeValue = require(Shared:WaitForChild("SafeValue"))
local ZFight = require(Shared:WaitForChild("ZFight"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))
local MovementSanity = require(script.Parent:WaitForChild("MovementSanity"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local MovementService = {}

local SODA_MULTIPLIER = 1.65
-- 10 s, as before the stamina rework: a can then covers 432 studs against a sprint's 262 over the same
-- time (measured), and RUSH is what pays for the stamina system rather than extra seconds. At 12 s it
-- was 518, the one item that outran everything else.
local SODA_DURATION = 10
local ROCKET_FORWARD = 72
local ROCKET_UP = 88
local PAD_UP = 135
local PAD_FORWARD = 38
local PAD_LIFETIME = 30
local PAD_COOLDOWN = 1.2
local BLINK_DISTANCE = 44
-- Coming out of a blink you're still moving the way you dashed, at least this fast.
local BLINK_CARRY = 30
local BOOTS_DURATION = 18
local BOOTS_JUMP_MULTIPLIER = 2.9
local GLIDE_DURATION = 16
-- While the Rot Glider is open you also sail forward at this speed the way you're looking.
local GLIDE_FORWARD = 34
-- Opened with ground this close underneath, the glider first throws you up at this speed (~37 studs).
local GLIDE_LIFT = 120
local GLIDE_LIFT_GROUND = 14

-- Set by Bootstrap to MatchService.ApplySpeedBoost, which owns walk speed.
MovementService.SetSpeedBoost = function() end
-- Set by Bootstrap to MatchService.SpendStamina / GetStamina, which own the stamina ledger. The
-- defaults let everything through, so this module still works on its own in a probe.
MovementService.SpendStamina = function()
	return true
end
MovementService.GetStamina = function()
	return 1, false
end
-- Set by Bootstrap to MatchService.SetCrouching, which owns the crouch. Climbing stands a body up, so
-- TryParkour needs to ask; on its own in a probe there is no crouch to end.
MovementService.SetCrouching = function()
	return false
end
-- Set by Bootstrap to CombatService.BreakGlassAlong (claude-4a's), which breaks the window panes on a
-- line and is what a bullet uses. Vaulting through a window takes the pane with it, with the same
-- shatter everyone else sees. A no-op by default so this module still runs standalone in a probe —
-- and tools/movement_probe.lua plants its fault by swapping this back to a no-op.
MovementService.BreakGlassAlong = function() end
-- Set by whoever owns equipped parachutes: the ParachuteModels design id a character's canopy should
-- use (the drop-in and the Rot Glider alike), or nil for the stock Rot Glider wing.
MovementService.ParachuteFor = function()
	return nil
end

-- Parachute designs, if that module is in the build; without it every canopy is the Rot Glider.
local ParachuteModels = nil
do
	local module = Shared:FindFirstChild("ParachuteModels")
	if module then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" and type(loaded.Build) == "function" then
			ParachuteModels = loaded
		else
			warn("[MovementService] ParachuteModels failed to load, using the Rot Glider: " .. tostring(loaded))
		end
	end
end

local launch = Remotes.Event("Launch")
local glide = Remotes.Event("Glide")

local folder = nil

local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	folder = Instance.new("Folder")
	folder.Name = "Deployables"
	folder.Parent = workspace
	return folder
end

-- `kind` tells a player's client what threw it: "rocket", "pad" and "blink" keep their speed through
-- the air (and a rocket is re-aimed along the camera). With no kind the client applies the velocity
-- exactly as it always has, so older callers (the geyser, bots) behave identically.
local function launchCharacter(character, velocity, kind)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		-- The monitor counts what the server didn't allow, so tell it what this launch allows: the
		-- horizontal speed, for about as long as the flight lasts.
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local flight = math.clamp(2 * math.max(velocity.Y, 0) / workspace.Gravity + 1.5, 1.5, 8)
		MovementSanity.Grant(player, math.max(horizontal, velocity.Y), flight)
		launch:FireClient(player, velocity, kind)
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		root.AssemblyLinearVelocity = velocity
	end
end

-- Sends any character flying (a player's own client applies it; a bot takes it directly). The
-- Hot Springs' geyser uses it. `kind` is optional; see launchCharacter.
function MovementService.Launch(character, velocity, kind)
	launchCharacter(character, velocity, kind)
end

-- What a Rot Rocket does: the launch velocity for a flat unit `direction`. Bots use it to get
-- out of a fight the same way players do.
function MovementService.RocketVelocity(direction)
	return direction * ROCKET_FORWARD + Vector3.new(0, ROCKET_UP, 0)
end

local function flatLook(root)
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	return flat.Magnitude > 0.01 and flat.Unit or Vector3.new(0, 0, -1)
end

local function deployPad(character, root)
	local forward = flatLook(root)
	local spot = root.Position + forward * 6

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, ensureFolder() }
	-- IgnoreWater defaults to FALSE, and a ray that stops at a river surface would stand the pad on the
	-- water. Every ground test in this file says so explicitly for that reason.
	params.IgnoreWater = true
	local ground = workspace:Raycast(spot + Vector3.new(0, 4, 0), Vector3.new(0, -40, 0), params)
	local y = ground and ground.Position.Y or root.Position.Y - 3

	local base = CFrame.lookAt(Vector3.new(spot.X, y + 0.3, spot.Z), Vector3.new(spot.X, y + 0.3, spot.Z) + forward)
	local color = ItemData.Get("LaunchPad").color

	local pad = Instance.new("Part")
	pad.Name = "LaunchPad"
	pad.Shape = Enum.PartType.Cylinder
	pad.Size = Vector3.new(0.6, 7, 7)
	pad.CFrame = base * CFrame.Angles(0, 0, math.pi / 2)
	pad.Color = Color3.fromRGB(40, 40, 50)
	pad.Material = Enum.Material.DiamondPlate
	pad.Anchored = true
	pad.CanQuery = false

	local function decor(size, cframe, partColor, material, shape, transparency)
		local part = Instance.new("Part")
		if shape then
			part.Shape = shape
		end
		part.Size = size
		part.CFrame = cframe
		part.Color = partColor
		part.Material = material
		part.Transparency = transparency or 0
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = pad
		return part
	end

	decor(Vector3.new(0.65, 5.6, 5.6), pad.CFrame, color, Enum.Material.Neon, Enum.PartType.Cylinder, 0.2)
	decor(Vector3.new(0.7, 3.2, 3.2), pad.CFrame, Color3.fromRGB(60, 60, 72), Enum.Material.DiamondPlate, Enum.PartType.Cylinder)
	decor(Vector3.new(1, 0.2, 2.6), base * CFrame.new(0, 0.42, 0.3), Color3.new(1, 1, 1), Enum.Material.Neon)
	decor(Vector3.new(0.7, 0.2, 0.7), base * CFrame.new(0, 0.42, -1.1) * CFrame.Angles(0, math.rad(45), 0), Color3.new(1, 1, 1),
		Enum.Material.Neon)
	-- Four springs peeking out from under the plate.
	for index = 0, 3 do
		local angle = index / 4 * math.pi * 2 + math.pi / 4
		decor(Vector3.new(0.5, 0.5, 0.5), base * CFrame.new(math.cos(angle) * 2.9, -0.05, math.sin(angle) * 2.9),
			Color3.fromRGB(180, 186, 196), Enum.Material.Metal, Enum.PartType.Ball)
	end

	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 2
	light.Parent = pad

	local lastLaunch = {}
	pad.Touched:Connect(function(hit)
		local model = hit:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			return
		end
		local now = os.clock()
		if lastLaunch[model] and now - lastLaunch[model] < PAD_COOLDOWN then
			return
		end
		lastLaunch[model] = now
		-- A player's client turns the forward part along the way they're running, if they are.
		launchCharacter(model, Vector3.new(0, PAD_UP, 0) + forward * PAD_FORWARD, "pad")
	end)

	ZFight.Fix({ pad })
	pad.Parent = ensureFolder()
	Debris:AddItem(pad, PAD_LIFETIME)
end

-- Casts at chest and knee height and stops short of whichever hits first, so a blink never ends
-- inside a wall or a fence. Too close to anything and nothing happens (and nothing is spent). Only
-- solid things stop it (an intact window pane is solid), not foliage and trim you could walk through.
-- A player comes out of it still moving the way they dashed, with any fall cancelled.
local function blink(character, root)
	local forward = flatLook(root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, ensureFolder() }
	params.RespectCanCollide = true
	-- Water is not an obstruction: without this a river surface stops the dash dead.
	params.IgnoreWater = true

	local distance = BLINK_DISTANCE
	for _, height in ipairs({ 1.2, -1.6 }) do
		local origin = root.Position + Vector3.new(0, height, 0)
		local hit = workspace:Raycast(origin, forward * BLINK_DISTANCE, params)
		if hit then
			distance = math.min(distance, (hit.Position - origin).Magnitude - 2.5)
		end
	end
	if distance < 4 then
		return false
	end

	local velocity = root.AssemblyLinearVelocity
	local carry = math.max(Vector3.new(velocity.X, 0, velocity.Z).Magnitude, BLINK_CARRY)
	local target = root.Position + forward * distance
	-- The server does this teleport itself, so the monitor shouldn't read it as one of the player's.
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		MovementSanity.Expect(player)
	end
	character:PivotTo(CFrame.lookAt(target, target + forward))
	launchCharacter(character, forward * carry, "blink")
	return true
end

local bootTokens = {}

local function bounceBoots(player, humanoid)
	local token = (bootTokens[player] or 0) + 1
	bootTokens[player] = token

	if humanoid:GetAttribute("BaseJumpHeight") == nil then
		humanoid:SetAttribute("BaseJumpHeight", humanoid.JumpHeight)
		humanoid:SetAttribute("BaseJumpPower", humanoid.JumpPower)
	end
	humanoid.JumpHeight = humanoid:GetAttribute("BaseJumpHeight") * BOOTS_JUMP_MULTIPLIER
	humanoid.JumpPower = humanoid:GetAttribute("BaseJumpPower") * math.sqrt(BOOTS_JUMP_MULTIPLIER)
	-- The client reads this for the HUD and to allow the double jump.
	player:SetAttribute("BounceBootsUntil", workspace:GetServerTimeNow() + BOOTS_DURATION)

	task.delay(BOOTS_DURATION, function()
		if bootTokens[player] ~= token then
			return
		end
		player:SetAttribute("BounceBootsUntil", nil)
		if humanoid.Parent then
			humanoid.JumpHeight = humanoid:GetAttribute("BaseJumpHeight")
			humanoid.JumpPower = humanoid:GetAttribute("BaseJumpPower")
		end
	end)
end

-- The canopy is the glider model scaled up and welded over the head, so everyone sees it open.
-- `duration`, `fallSpeed` and `forward` default to the Rot Glider's; the match drop-in uses its own.
-- The open canopy, welded over a character's head, gone after `duration`. Returns the model.
local function attachCanopy(character, head, root, duration)
	local existing = character:FindFirstChild("GliderCanopy")
	if existing then
		existing:Destroy()
	end
	local model, body
	if ParachuteModels then
		-- An unknown or missing id falls back to the Rot Glider inside Build.
		local ok, id = pcall(MovementService.ParachuteFor, character)
		model, body = ParachuteModels.Build(ok and id or nil, { scale = 3, anchored = false, name = "GliderCanopy" })
	else
		model, body = ItemModels.Build("RotGlider", { scale = 3, anchored = false, name = "GliderCanopy", open = true })
	end
	if not model then
		return nil
	end
	model:PivotTo(CFrame.new(head.Position + Vector3.new(0, 1.4, 0)) * root.CFrame.Rotation)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = body
	weld.Part1 = head
	weld.Parent = body
	model.Parent = character
	Debris:AddItem(model, duration)
	return model
end

-- A canopy comes off when the FEET ARE DOWN, not when a timer says so.
--
-- It used to come off only when its Debris timeout expired — 14 seconds for the match drop, 16 for a Rot
-- Glider — however early you landed. Land six seconds into a drop and the canopy hung over you for eight
-- more while you ran around, which is what "the parachute stays on for too long after you land" is. The
-- timeout stays as the backstop for a body that never lands at all (dies in the air, leaves, gets stuck).
--
-- Bots never had this problem: their drop loop is server-simulated and already cuts the canopy on
-- landing. This is the same rule for a player, whose FloorMaterial the server can't trust, so the ground
-- is found by a ray instead.
local groundUnderBody
local CANOPY_GRACE = 0.6
local CANOPY_SETTLE = 0.15
local CANOPY_RELEASE = 0.18

-- Exported because it is the one thing that can break the DEPLOY path: if this ever said "down" while a
-- body was still in the air, a canopy would come off the instant it opened and the drop would be a free
-- fall again. tools/crouch_probe.lua holds a rig 30 studs up and checks it says no.
function MovementService.FeetDown(character)
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root then
		return false
	end
	return groundUnderBody(character, humanoid, root)
end

function groundUnderBody(character, humanoid, root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, ensureFolder() }
	params.RespectCanCollide = true
	-- Water counts HERE, unlike every other ground test in this file: landing in a river is landing, and
	-- a canopy that stays open because you came down over water is the same bug in a different place.
	params.IgnoreWater = false
	local reach = humanoid.HipHeight + root.Size.Y / 2 + 1.2
	return workspace:Raycast(root.Position, Vector3.new(0, -reach, 0), params) ~= nil
end

-- Watches one canopy and takes it off shortly after the body settles on the ground.
local function releaseCanopyOnLanding(character, model, duration)
	task.spawn(function()
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or not root then
			return
		end
		local began = os.clock()
		local groundedSince = nil
		while model.Parent and character.Parent and humanoid.Health > 0 and root.Parent do
			local elapsed = os.clock() - began
			if elapsed > duration then
				return -- the Debris timeout owns it from here
			end
			-- Never in the first moments: the drop teleports the body to height, and for a frame or two
			-- the ray can still find the ground it left.
			if elapsed > CANOPY_GRACE and groundUnderBody(character, humanoid, root) then
				groundedSince = groundedSince or os.clock()
				if os.clock() - groundedSince >= CANOPY_SETTLE then
					break
				end
			else
				groundedSince = nil
			end
			task.wait(0.1)
		end
		if model.Parent then
			-- A short release rather than a vanish: the canopy fades over CANOPY_RELEASE as it comes off.
			for _, part in ipairs(model:GetDescendants()) do
				if part:IsA("BasePart") then
					TweenService:Create(part, TweenInfo.new(CANOPY_RELEASE), { Transparency = 1 }):Play()
				end
			end
			Debris:AddItem(model, CANOPY_RELEASE)
		end
	end)
end

-- Takes out the window panes a vault goes through.
--
-- THE SERVER FINDS THEM ITSELF. A player's vault is run by their own client, which only ever tells us
-- "I vaulted" — it never names a window, and it never could: this casts along the character's OWN facing
-- from where the body actually is, and breaks only panes physically in front of it inside a vault's
-- reach. So the worst a modified client can do is claim a vault while standing in front of a window it
-- was free to walk up to and shoot anyway.
local GLASS_REACH = MovementConfig.Parkour.VaultMaxDepth + 2.5

local function breakVaultGlass(token, character, from, to)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	if not from then
		from = root.Position
		to = from + flatLook(root) * GLASS_REACH
	end
	MovementService.BreakGlassAlong(token, from, to)
end

-- `lift` (optional): an upward speed the client applies first, for a glider opened near the ground.
-- `steer` (optional, the match drop-in): the client sails only where you push, not on its own, so
-- nobody drifts off the spot they picked on the drop map just by looking around.
local function openGlider(player, character, root, duration, fallSpeed, forward, lift, steer)
	duration = duration or GLIDE_DURATION
	-- The canopy is cosmetic; the fall cap, the sailing speed and the sanity grant are the gameplay. A
	-- model that fails to build (or a body with no head to hang it from) must never turn a drop from the
	-- drop height into a free fall with nothing on screen to explain it, so the glide is sent either way
	-- and the failure is warned about once.
	local head = character:FindFirstChild("Head")
	if head then
		local built, result = pcall(attachCanopy, character, head, root, duration)
		if built and result then
			releaseCanopyOnLanding(character, result, duration)
		end
		if not built or not result then
			warn(string.format("[MovementService] no canopy for %s, gliding without one: %s", player.Name,
				built and "the model built nothing" or tostring(result)))
		end
	else
		warn(string.format("[MovementService] no head to hang a canopy on for %s, gliding without one", player.Name))
	end
	-- A glide is a long flight: allow its sailing speed (or its updraft, whichever is faster) for as long
	-- as the canopy lasts.
	MovementSanity.Grant(player, math.max(forward or GLIDE_FORWARD, lift or 0), duration + 1)
	glide:FireClient(player, duration, fallSpeed, forward or GLIDE_FORWARD, lift, steer and "steer" or nil)
	return true
end

-- Whether there's ground within GLIDE_LIFT_GROUND under the character (so the glider needs an updraft).
local function nearGround(character, root)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	params.RespectCanCollide = true
	-- A river is not the ground to open a glider over.
	params.IgnoreWater = true
	return workspace:Raycast(root.Position, Vector3.new(0, -GLIDE_LIFT_GROUND, 0), params) ~= nil
end

--------------------------------------------------------------------------------
-- Bots' drop-in
--------------------------------------------------------------------------------

-- A bot's body is simulated by the server, so its glide is steered here: each frame it's given
-- a steady fall and a drift toward its landing spot until its feet find the ground. One loop
-- handles every bot that's dropping.
local BOT_DROP_FALL = 26
local BOT_DROP_FORWARD = 34
local BOT_DROP_TIMEOUT = 28
local dropping = {}
local dropLoop = nil

local function finishDrop(entry)
	if entry.canopy and entry.canopy.Parent then
		entry.canopy:Destroy()
	end
	if entry.onLanded then
		task.spawn(entry.onLanded)
	end
end

local function stepDrops()
	local now = os.clock()
	for index = #dropping, 1, -1 do
		local entry = dropping[index]
		local root, humanoid = entry.root, entry.humanoid
		local gone = not entry.character.Parent or not root.Parent or humanoid.Health <= 0
		local elapsed = now - entry.startedAt
		local landed = elapsed > 0.8 and humanoid.FloorMaterial ~= Enum.Material.Air
		if gone or landed or elapsed > BOT_DROP_TIMEOUT then
			table.remove(dropping, index)
			finishDrop(entry)
		else
			local flat = (entry.target - root.Position) * Vector3.new(1, 0, 1)
			local distance = flat.Magnitude
			local drift = Vector3.zero
			if distance > 4 then
				drift = flat.Unit * math.min(BOT_DROP_FORWARD, distance * 1.5)
			end
			root.AssemblyLinearVelocity = drift + Vector3.new(0, -BOT_DROP_FALL, 0)
		end
	end
	if #dropping == 0 and dropLoop then
		dropLoop:Disconnect()
		dropLoop = nil
	end
end

-- Opens a canopy over a bot and glides it to `target` (a ground point); `onLanded` runs when
-- it's down. Returns false if the character has no head to hang the canopy from.
function MovementService.BotDrop(character, target, onLanded)
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not root or not head or not humanoid then
		return false
	end
	local canopy = attachCanopy(character, head, root, BOT_DROP_TIMEOUT + 2)
	table.insert(dropping, {
		character = character, root = root, humanoid = humanoid, target = target, canopy = canopy,
		onLanded = onLanded, startedAt = os.clock(),
	})
	if not dropLoop then
		dropLoop = RunService.Heartbeat:Connect(stepDrops)
	end
	return true
end

-- How many bots are still in the air (for the build check).
function MovementService.DroppingCount()
	return #dropping
end

-- The drop-in at the start of a match: everyone opens a canopy high over their spawn and steers
-- down, so a match starts with a view of the whole map instead of a spawn on a doorstep.
local DROP_DURATION = 14
local DROP_FALL_SPEED = 26
local DROP_FORWARD = 40

function MovementService.DropIn(player, character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	return openGlider(player, character, root, DROP_DURATION, DROP_FALL_SPEED, DROP_FORWARD, nil, true)
end

WeaponService.MovementEffect = function(player, itemId)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return false
	end

	if itemId == "SpeedSoda" then
		MovementService.SetSpeedBoost(player, SODA_MULTIPLIER, SODA_DURATION, { rush = true })
	elseif itemId == "RotRocket" then
		launch:FireClient(player, MovementService.RocketVelocity(flatLook(root)), "rocket")
	elseif itemId == "LaunchPad" then
		deployPad(character, root)
	elseif itemId == "BlinkBean" then
		return blink(character, root)
	elseif itemId == "BounceBoots" then
		bounceBoots(player, humanoid)
	elseif itemId == "RotGlider" then
		return openGlider(player, character, root, nil, nil, nil, nearGround(character, root) and GLIDE_LIFT or nil)
	else
		return false
	end
	return true
end

-- Pads don't outlive the match they were placed in.
function MovementService.Clear()
	if folder then
		folder:Destroy()
		folder = nil
	end
end

--------------------------------------------------------------------------------
-- Parkour: the pose attribute, players' climbs and vaults, and bots'
--------------------------------------------------------------------------------

-- Sets character attribute Parkour to `kind` for `duration` seconds (nil clears it now). Every client
-- poses the body from it (StarterPlayerScripts/MovementClient). A newer call always wins over an
-- older one's timer.
local poseTokens = {}
function MovementService.SetParkourPose(character, kind, duration)
	if not character or not character.Parent then
		return
	end
	local poseToken = (poseTokens[character] or 0) + 1
	poseTokens[character] = poseToken
	character:SetAttribute("Parkour", kind)
	if kind == nil then
		poseTokens[character] = nil
		return
	end
	task.delay(math.clamp(duration or 0.5, 0.05, 3), function()
		if poseTokens[character] == poseToken then
			poseTokens[character] = nil
			if character.Parent then
				character:SetAttribute("Parkour", nil)
			end
		end
	end)
end

-- A player's client climbed or vaulted (it runs the move itself, since it simulates the body): charge
-- the stamina and pose them for everyone else. A vault the ledger refuses still happened on the
-- client; the refusal resyncs its stamina, which is what stops the next one. Rate-limited.
local lastClientMove = {}
function MovementService.ClientParkour(player, kind, rise, duration)
	if kind ~= "mantle" and kind ~= "vault" then
		return false
	end
	if not SafeValue.Number(rise, 50) or not SafeValue.Number(duration, 10) then
		return false
	end
	local now = os.clock()
	-- A real move lasts at least 0.18s and the client waits 0.25s after it, so 0.3s never refuses one; it
	-- caps how often a client can set the replicated pose attribute.
	if lastClientMove[player] and now - lastClientMove[player] < 0.3 then
		return false
	end
	lastClientMove[player] = now
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	local cost
	if kind == "vault" then
		cost = MovementConfig.Stamina.VaultCost
	else
		cost = rise <= MovementConfig.Stamina.FreeMantleRise and 0 or MovementConfig.Stamina.MantleCost
	end
	local paid = MovementService.SpendStamina(player, cost, kind == "mantle")
	MovementService.SetParkourPose(character, kind, math.clamp(duration, 0.1, 1.2) + 0.1)
	if kind == "vault" then
		breakVaultGlass(player, character)
	end
	return paid
end

Players.PlayerRemoving:Connect(function(player)
	lastClientMove[player] = nil
end)

-- Read-only: what a climb or vault from here, facing `forward`, would be. Returns the kind
-- ("mantle" | "vault") and the plan, or nil and why not. `options` as Parkour.Find: speed (toward
-- forward), groundY (feet height of the last surface stood on). Stamina is taken into account.
function MovementService.CanParkour(character, forward, options)
	if typeof(character) ~= "Instance" or not SafeValue.Vector3(forward) then
		return nil, "bad arguments"
	end
	local token = Combatants.FromCharacter(character)
	local _, exhausted = MovementService.GetStamina(token)
	local findOptions = {}
	if type(options) == "table" then
		findOptions.speed = SafeValue.Number(options.speed, 500) and options.speed or nil
		findOptions.groundY = SafeValue.Number(options.groundY) and options.groundY or nil
		findOptions.allowVault = options.allowVault
		findOptions.allowMantle = options.allowMantle
	end
	findOptions.exhausted = exhausted
	local plan, reason = Parkour.Find(character, forward, findOptions)
	if not plan then
		return nil, reason
	end
	return plan.kind, plan
end

-- Server-run moves (bots): character -> true while one is under way.
local running = {}

-- Climb or vault now, if there's one to do: the root follows the plan's path each Heartbeat with its
-- velocity held at zero, then leaves at the plan's exit velocity. Charges stamina (a vault the ledger
-- refuses falls back to a climb if there's one). Returns the kind, or nil. While it runs, character
-- attribute Parkour is set; don't steer the body until it clears (plan.duration).
-- Returns the kind, or nil AND WHY NOT - the same shape CanParkour has, because a caller that only
-- learns "no" cannot tell "wait a moment and retry" from "go round".
--
-- THE TRAP THIS SOLVES, for anyone calling CanParkour and then TryParkour: by default this runs its own
-- CanParkour, so a body that MOVED between the two calls is measured from its new position, and a plan
-- that was good a frame ago can be gone. That refusal used to be silent, and to a caller that had just
-- been told yes it looked like TryParkour failing for no reason at all. Pass the plan you already have
-- (options.kind and options.plan) and it is used as-is: no second look, no race.
function MovementService.TryParkour(character, forward, options)
	if typeof(character) ~= "Instance" then
		return nil, "no character"
	end
	if running[character] then
		return nil, "already moving"
	end
	local kind, plan
	if type(options) == "table" and options.plan and options.kind then
		kind, plan = options.kind, options.plan
	else
		kind, plan = MovementService.CanParkour(character, forward, options)
	end
	if not kind then
		-- CanParkour puts its reason where the plan would be.
		return nil, "nothing to climb now: " .. tostring(plan)
	end
	local token = Combatants.FromCharacter(character)
	if not MovementService.SpendStamina(token, plan.cost, plan.kind == "mantle") then
		local fallback = type(options) == "table" and table.clone(options) or {}
		fallback.allowVault = false
		fallback.plan, fallback.kind = nil, nil
		kind, plan = MovementService.CanParkour(character, forward, fallback)
		if not kind then
			return nil, "not enough stamina to vault, and nothing to climb instead: " .. tostring(plan)
		end
		if not MovementService.SpendStamina(token, plan.cost, true) then
			return nil, "not enough stamina"
		end
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	-- You stand to climb, exactly as a player does (MovementClient's startMove): the plan was measured
	-- from the feet, so it works either way, but a body that pulled itself onto a ledge still folded
	-- would land a stud low and be drawn crouching through the climb.
	MovementService.SetCrouching(token, false)
	running[character] = true
	if kind == "vault" then
		-- A bot's plan is ours, so the panes are broken along the path it will actually take.
		breakVaultGlass(token, character, plan.points[1], plan.points[#plan.points])
	end
	MovementService.SetParkourPose(character, kind, plan.duration + 0.1)
	local started = os.clock()
	local connection
	connection = RunService.Heartbeat:Connect(function()
		local finished = not root.Parent or not character.Parent or humanoid.Health <= 0
		if not finished then
			local position, done = Parkour.PositionAt(plan, os.clock() - started)
			root.CFrame = CFrame.lookAt(position, position + plan.forward)
			root.AssemblyLinearVelocity = done and plan.exitVelocity or Vector3.zero
			finished = done
		end
		if finished then
			connection:Disconnect()
			running[character] = nil
		end
	end)
	return kind
end

return MovementService
