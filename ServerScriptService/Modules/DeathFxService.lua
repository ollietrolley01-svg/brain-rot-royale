-- What happens to a body. Every character, player or bot, has BreakJointsOnDeath off, so at
-- death it stays in one piece and this decides what it does. The plain death is a ragdoll:
-- every rig joint becomes a ball socket, the limbs collide, and the killing shot shoves the body
-- the way it was going. A gun with a `killEffect` (WeaponData.KillEffects) does something else:
--
--   ragdoll   (default) drops, shoved along the shot
--   float     drifts up into the sky, turning slowly, and fades out
--   ash       drops, turns to ash and blows away
--   burn      drops burning, blackens, and the fire gutters out
--   freeze    freezes solid where it stands, then shatters
--   shock     drops twitching, sparking, flickering neon
--   confetti  pops into a burst of confetti
--   vaporize  a white flash and it's gone
--   gold      turns to a gold statue that topples and crumbles into coins
--
-- Every effect ends with the body hidden (invisible, anchored, no collision or queries). Bot
-- bodies are removed by MatchService a little after that; a player's stays hidden until the
-- match respawns them, so nothing still holding player.Character breaks. Player characters are
-- simulated by their own client, so shoves for those go through the DeathFx remote and the
-- client applies them (DeathFxClient); bots are server-owned and shoved directly. The same
-- remote carries each effect to every client for its sound.

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local Combatants = require(script.Parent:WaitForChild("Combatants"))

local DeathFxService = {}

local deathFx = Remotes.Event("DeathFx")

local RAGDOLL_LINGER = 4 -- seconds a plain ragdoll lies there before it fades
local FADE_TIME = 1.2

local ASH = Color3.fromRGB(58, 56, 54)
local CHAR = Color3.fromRGB(26, 22, 20)
local ICE = Color3.fromRGB(170, 222, 255)
local GOLD = Color3.fromRGB(240, 190, 60)
local SHOCK = Color3.fromRGB(120, 225, 255)
local WHITE_HOT = Color3.fromRGB(255, 244, 214)

local CONFETTI = {
	Color3.fromRGB(255, 90, 120), Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 220, 140),
	Color3.fromRGB(80, 170, 255), Color3.fromRGB(200, 110, 255), Color3.fromRGB(255, 140, 60),
}

local folder

local function ensureFolder()
	if folder and folder.Parent then
		return folder
	end
	folder = workspace:FindFirstChild("DeathFx")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DeathFx"
		folder.Parent = workspace
	end
	return folder
end

--------------------------------------------------------------------------------
-- Body helpers
--------------------------------------------------------------------------------

local function bodyParts(character)
	local parts = {}
	for _, part in ipairs(character:GetDescendants()) do
		if part:IsA("BasePart") then
			table.insert(parts, part)
		end
	end
	return parts
end

local function torsoOf(character)
	return character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
		or character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
end

local function positionOf(character)
	local torso = torsoOf(character)
	return torso and torso.Position or character:GetPivot().Position
end

-- The server can't move parts a client simulates, so a player's own body is shoved by their
-- client (DeathFxClient). Bots are ours to push directly.
local function shove(character, velocity, scatter, angular)
	local player = Players:GetPlayerFromCharacter(character)
	if player then
		deathFx:FireClient(player, { kind = "shove", velocity = velocity, scatter = scatter or 0, angular = angular or 0 })
	end
	for _, part in ipairs(bodyParts(character)) do
		if not part.Anchored then
			pcall(function()
				part:SetNetworkOwner(nil)
			end)
			local spread = scatter or 0
			part.AssemblyLinearVelocity = velocity + Vector3.new((math.random() - 0.5) * spread, math.random() * spread * 0.6, (math.random() - 0.5) * spread)
			if angular and angular > 0 then
				part.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8)) * angular
			end
		end
	end
end

-- The part an attachment sits on. Rig attachments can nest (a shoulder socket hangs off the
-- shoulder rig attachment), so this walks up to the first part.
local function partOf(attachment)
	return attachment and attachment:FindFirstAncestorWhichIsA("BasePart") or nil
end

-- The two parts a rig joint holds together, for a Motor6D or an AnimationConstraint.
local function jointParts(joint)
	if joint:IsA("Motor6D") then
		return joint.Part0, joint.Part1
	end
	return partOf(joint.Attachment0), partOf(joint.Attachment1)
end

-- Keeps the HumanoidRootPart with the torso. Physics rigs drop their root joint at death, and
-- the root part — which never collides — then falls straight through the floor, taking a dead
-- player's camera with it. A weld holds it where it is for as long as the body lasts.
local function pinRoot(character)
	local root = character:FindFirstChild("HumanoidRootPart")
	local torso = character:FindFirstChild("LowerTorso") or character:FindFirstChild("Torso")
	if root and torso and not root:FindFirstChild("RootPin") then
		local weld = Instance.new("WeldConstraint")
		weld.Name = "RootPin"
		weld.Part0 = torso
		weld.Part1 = root
		weld.Parent = root
	end
end

-- Turns the rig joints off. With `sockets`, each is replaced by a ball socket so the body hangs
-- together as a ragdoll; without, the pieces simply come apart. The root joint is kept either
-- way so the HumanoidRootPart (which never collides) rides with the torso instead of dropping
-- through the floor, taking a dead player's camera with it.
--
-- Two rig formats turn up. Classic rigs hold their pose with Motor6Ds and get sockets built
-- for them here. Current physics rigs (what CreateHumanoidModelFromDescription returns, so
-- every bot) hold it with an AnimationConstraint per joint and already carry a ball socket
-- beside each one, inert while the constraint drives: those sockets are reused — enabled for
-- a ragdoll, disabled for a shatter — and only joints without one get a new socket.
local function releaseJoints(character, sockets)
	local existing = {}
	for _, socket in ipairs(character:GetDescendants()) do
		if socket:IsA("BallSocketConstraint") and socket.Attachment0 and socket.Attachment1 then
			local p0, p1 = partOf(socket.Attachment0), partOf(socket.Attachment1)
			if p0 and p1 then
				existing[p0] = existing[p0] or {}
				existing[p0][p1] = socket
				existing[p1] = existing[p1] or {}
				existing[p1][p0] = socket
			end
			socket.Enabled = sockets
		end
	end

	local count = 0
	for _, joint in ipairs(character:GetDescendants()) do
		if (joint:IsA("Motor6D") or joint:IsA("AnimationConstraint")) and joint.Enabled then
			local p0, p1 = jointParts(joint)
			if p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart")
				and p0.Parent == character and p1.Parent == character
				and p0.Name ~= "HumanoidRootPart" and p1.Name ~= "HumanoidRootPart" then
				if sockets and not (existing[p0] and existing[p0][p1]) then
					local a0, a1
					if joint:IsA("Motor6D") then
						a0 = Instance.new("Attachment")
						a0.Name = "RagdollA0"
						a0.CFrame = joint.C0
						a0.Parent = p0
						a1 = Instance.new("Attachment")
						a1.Name = "RagdollA1"
						a1.CFrame = joint.C1
						a1.Parent = p1
					else
						a0, a1 = joint.Attachment0, joint.Attachment1
					end

					local socket = Instance.new("BallSocketConstraint")
					socket.Name = "Ragdoll"
					socket.Attachment0 = a0
					socket.Attachment1 = a1
					socket.LimitsEnabled = true
					socket.TwistLimitsEnabled = true
					socket.UpperAngle = 45
					socket.TwistLowerAngle = -40
					socket.TwistUpperAngle = 40
					socket.Parent = p0
				end
				joint.Enabled = false
				count += 1
			end
		end
	end
	return count
end

local function setCollisions(character, collide)
	for _, part in ipairs(bodyParts(character)) do
		part.Anchored = false
		part.CanCollide = collide and part.Name ~= "HumanoidRootPart"
	end
end

local function platformStand(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = true
	end
end

-- The standard ragdoll: joints to sockets, limbs solid, and a shove.
local function ragdoll(character, impulse)
	platformStand(character)
	releaseJoints(character, true)
	setCollisions(character, true)
	shove(character, impulse, 4, 0.4)
end

local function decorations(character)
	local found = {}
	for _, child in ipairs(character:GetDescendants()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			table.insert(found, child)
		end
	end
	return found
end

local function hideBody(character)
	if not character.Parent then
		return
	end
	for _, part in ipairs(bodyParts(character)) do
		part.Transparency = 1
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Anchored = true
	end
	for _, child in ipairs(character:GetDescendants()) do
		if child:IsA("Decal") or child:IsA("Texture") then
			child.Transparency = 1
		elseif child:IsA("BillboardGui") then
			child.Enabled = false
		elseif child:IsA("ParticleEmitter") or child:IsA("Fire") or child:IsA("Smoke") or child:IsA("Sparkles")
			or child:IsA("PointLight") or child:IsA("LinearVelocity") then
			child:Destroy()
		end
	end
end

-- Fades every part (and face) out after `delay`, then hides the body.
local function fadeOut(character, delay, duration)
	task.delay(delay, function()
		if not character.Parent then
			return
		end
		local info = TweenInfo.new(duration)
		for _, part in ipairs(bodyParts(character)) do
			TweenService:Create(part, info, { Transparency = 1 }):Play()
		end
		for _, decal in ipairs(decorations(character)) do
			TweenService:Create(decal, info, { Transparency = 1 }):Play()
		end
		for _, child in ipairs(character:GetDescendants()) do
			if child:IsA("ParticleEmitter") or child:IsA("Fire") or child:IsA("Smoke") or child:IsA("Sparkles") then
				child.Enabled = false
			elseif child:IsA("PointLight") then
				TweenService:Create(child, info, { Brightness = 0 }):Play()
			end
		end
		task.delay(duration, function()
			hideBody(character)
		end)
	end)
end

local function recolor(character, color, material, duration)
	local info = TweenInfo.new(duration or 0.3)
	for _, part in ipairs(bodyParts(character)) do
		if material then
			part.Material = material
		end
		TweenService:Create(part, info, { Color = color }):Play()
	end
	for _, decal in ipairs(decorations(character)) do
		TweenService:Create(decal, info, { Transparency = 1 }):Play()
	end
end

local function light(part, color, brightness, range)
	local point = Instance.new("PointLight")
	point.Color = color
	point.Brightness = brightness
	point.Range = range
	point.Shadows = false
	point.Parent = part
	return point
end

-- A one-shot emitter (Rate 0; call :Emit on it) with the look given.
local function emitter(part, spec)
	local particles = Instance.new("ParticleEmitter")
	particles.Rate = 0
	particles.Color = ColorSequence.new(spec.color, spec.colorEnd or spec.color)
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.size),
		NumberSequenceKeypoint.new(1, spec.sizeEnd or 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, spec.transparency or 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(spec.life, spec.life * 1.6)
	particles.Speed = NumberRange.new(spec.speed, spec.speed * 1.8)
	particles.SpreadAngle = Vector2.new(spec.spread or 180, spec.spread or 180)
	particles.Acceleration = spec.acceleration or Vector3.zero
	particles.Drag = spec.drag or 0
	particles.LightEmission = spec.glow or 0
	particles.RotSpeed = NumberRange.new(-120, 120)
	particles.Parent = part
	return particles
end

-- A neon ball that swells and vanishes: the flash of a pop or a vaporization.
local function flash(position, color, size, duration)
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(1, 1, 1)
	ball.Material = Enum.Material.Neon
	ball.Color = color
	ball.Transparency = 0.2
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.Position = position
	ball.Parent = ensureFolder()
	local point = light(ball, color, 6, size * 3)
	local info = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(ball, info, { Size = Vector3.new(size, size, size), Transparency = 1 }):Play()
	TweenService:Create(point, info, { Brightness = 0 }):Play()
	Debris:AddItem(ball, duration + 0.1)
end

--------------------------------------------------------------------------------
-- The effects
--------------------------------------------------------------------------------

local EFFECTS = {}

EFFECTS.ragdoll = function(character, ctx)
	ragdoll(character, ctx.impulse)
	fadeOut(character, RAGDOLL_LINGER, FADE_TIME)
end

local FLOAT_RISE = 5 -- studs per second

-- Rises like a balloon, still in one piece and turning slowly, glowing softly. Every part is
-- held to the same steady climb by its own velocity constraint, so it works whoever simulates
-- the body and on both rig formats: on a physics rig, where each limb is its own body held by
-- constraints, the limbs rise together instead of dangling from the torso.
EFFECTS.float = function(character, ctx)
	platformStand(character)
	for _, part in ipairs(bodyParts(character)) do
		part.Anchored = false
		part.CanCollide = false
		if part:GetMass() > 0 then
			local attachment = Instance.new("Attachment")
			attachment.Name = "FloatAttachment"
			attachment.Parent = part
			local lift = Instance.new("LinearVelocity")
			lift.Name = "FloatLift"
			lift.Attachment0 = attachment
			lift.RelativeTo = Enum.ActuatorRelativeTo.World
			lift.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
			lift.VectorVelocity = Vector3.new(0, FLOAT_RISE, 0)
			lift.MaxForce = 1e5
			lift.Parent = part
		end
	end
	shove(character, Vector3.new(0, FLOAT_RISE, 0), 0, 0.15)

	local torso = torsoOf(character)
	if torso then
		light(torso, Color3.fromRGB(200, 220, 255), 1.5, 14)
		local sparkle = emitter(torso, {
			color = Color3.fromRGB(230, 240, 255), size = 0.35, life = 1.4, speed = 1.5,
			acceleration = Vector3.new(0, -1, 0), glow = 0.8,
		})
		sparkle.Rate = 12
	end
	fadeOut(character, 3.6, 1.6)
end

-- Drops, greys to ash over a second, then blows away in a puff.
EFFECTS.ash = function(character, ctx)
	ragdoll(character, ctx.impulse * 0.5)
	recolor(character, ASH, Enum.Material.Slate, 1.1)
	task.delay(1.1, function()
		if not character.Parent then
			return
		end
		local info = TweenInfo.new(1.2)
		for _, part in ipairs(bodyParts(character)) do
			if part.Name ~= "HumanoidRootPart" then
				local puff = emitter(part, {
					color = Color3.fromRGB(120, 116, 110), colorEnd = ASH, size = 0.45, life = 1.3, speed = 2,
					acceleration = Vector3.new(3, 2.5, 0), drag = 1, transparency = 0.25,
				})
				puff:Emit(14)
			end
			TweenService:Create(part, info, { Size = part.Size * 0.25, Transparency = 1 }):Play()
		end
		task.delay(1.3, function()
			hideBody(character)
		end)
	end)
end

-- Drops burning: flames on every limb, the body blackening, smoke off the torso; the fire
-- gutters out before the body fades.
EFFECTS.burn = function(character, ctx)
	ragdoll(character, ctx.impulse)
	local fires = {}
	for _, part in ipairs(bodyParts(character)) do
		if part.Parent == character and part.Name ~= "HumanoidRootPart" then
			local fire = Instance.new("Fire")
			fire.Size = (part.Name:find("Torso") or part.Name == "Head") and 6 or 3.5
			fire.Heat = 12
			fire.Color = Color3.fromRGB(255, 150, 40)
			fire.SecondaryColor = Color3.fromRGB(220, 40, 20)
			fire.Parent = part
			table.insert(fires, fire)
		end
	end
	recolor(character, CHAR, Enum.Material.Slate, 2.4)
	local torso = torsoOf(character)
	if torso then
		light(torso, Color3.fromRGB(255, 140, 50), 2.5, 16)
		local smoke = emitter(torso, {
			color = Color3.fromRGB(60, 56, 52), colorEnd = Color3.fromRGB(30, 30, 30), size = 0.8, sizeEnd = 2.5,
			life = 1.8, speed = 3, spread = 30, acceleration = Vector3.new(0, 4, 0), transparency = 0.4,
		})
		smoke.Rate = 10
	end
	task.delay(2.6, function()
		for _, fire in ipairs(fires) do
			if fire.Parent then
				TweenService:Create(fire, TweenInfo.new(0.8), { Size = 0 }):Play()
			end
		end
	end)
	fadeOut(character, 3.3, 1.4)
end

-- Freezes solid mid-pose, glowing pale blue, then shatters into pieces.
EFFECTS.freeze = function(character, ctx)
	platformStand(character)
	for _, part in ipairs(bodyParts(character)) do
		part.Anchored = true
		if part.Name ~= "HumanoidRootPart" then
			part.Transparency = 0.12
		end
	end
	recolor(character, ICE, Enum.Material.Ice, 0.35)
	local torso = torsoOf(character)
	if torso then
		light(torso, ICE, 2, 14)
		emitter(torso, {
			color = Color3.fromRGB(235, 248, 255), size = 0.3, life = 1.2, speed = 3, glow = 0.5,
			acceleration = Vector3.new(0, -3, 0),
		}):Emit(24)
	end
	task.delay(2.2, function()
		if not character.Parent then
			return
		end
		releaseJoints(character, false)
		setCollisions(character, true)
		shove(character, ctx.impulse * 0.4 + Vector3.new(0, 8, 0), 18, 0.8)
		for _, part in ipairs(bodyParts(character)) do
			if part.Name ~= "HumanoidRootPart" then
				emitter(part, {
					color = ICE, colorEnd = Color3.fromRGB(235, 248, 255), size = 0.35, life = 0.9, speed = 6, glow = 0.4,
					acceleration = Vector3.new(0, -20, 0),
				}):Emit(8)
			end
		end
		deathFx:FireAllClients({ kind = "shatter", position = positionOf(character) })
		fadeOut(character, 0.5, 0.9)
	end)
end

-- Drops twitching: neon flickers, sparks, jolts through the limbs.
EFFECTS.shock = function(character, ctx)
	ragdoll(character, ctx.impulse)
	local parts = bodyParts(character)
	local originals = {}
	for _, part in ipairs(parts) do
		originals[part] = { color = part.Color, material = part.Material }
	end
	local torso = torsoOf(character)
	local sparks = torso and emitter(torso, {
		color = Color3.fromRGB(255, 250, 200), colorEnd = SHOCK, size = 0.25, life = 0.35, speed = 14, glow = 1,
		acceleration = Vector3.new(0, -30, 0),
	})
	local point = torso and light(torso, SHOCK, 0, 16)
	task.spawn(function()
		for step = 1, 6 do
			if not character.Parent then
				return
			end
			for _, part in ipairs(parts) do
				part.Material = Enum.Material.Neon
				part.Color = SHOCK
			end
			if sparks then
				sparks:Emit(12)
			end
			if point then
				point.Brightness = 4
			end
			shove(character, Vector3.new(0, 5, 0), 8, 0.3)
			task.wait(0.08)
			for part, original in pairs(originals) do
				part.Material = original.material
				part.Color = original.color
			end
			if point then
				point.Brightness = 0
			end
			task.wait(0.12 + step * 0.05)
		end
	end)
	fadeOut(character, 2.6, 1.2)
end

-- Pops into a burst of confetti and is gone.
EFFECTS.confetti = function(character, ctx)
	local origin = positionOf(character)
	hideBody(character)
	flash(origin, Color3.fromRGB(255, 230, 240), 7, 0.35)
	for index = 1, 30 do
		local piece = Instance.new("Part")
		piece.Size = Vector3.new(0.5, 0.08, 0.5)
		piece.Material = Enum.Material.Neon
		piece.Color = CONFETTI[(index % #CONFETTI) + 1]
		piece.Anchored = false
		piece.CanCollide = false
		piece.CanQuery = false
		piece.CanTouch = false
		piece.CFrame = CFrame.new(origin + Vector3.new(math.random(-15, 15) / 10, math.random(-10, 20) / 10, math.random(-15, 15) / 10))
			* CFrame.Angles(math.random() * 6.28, math.random() * 6.28, 0)
		local direction = Vector3.new(math.random(-10, 10), math.random(4, 12), math.random(-10, 10))
		piece.AssemblyLinearVelocity = ctx.impulse * 0.3 + direction.Unit * math.random(16, 32)
		piece.AssemblyAngularVelocity = Vector3.new(math.random(-12, 12), math.random(-12, 12), math.random(-12, 12))
		piece.Parent = ensureFolder()
		Debris:AddItem(piece, 3.2)
	end
end

-- A white-hot flash and the body is vapour.
EFFECTS.vaporize = function(character, ctx)
	local origin = positionOf(character)
	for _, part in ipairs(bodyParts(character)) do
		part.Anchored = true
		part.Material = Enum.Material.Neon
		part.Color = WHITE_HOT
		part.CanCollide = false
	end
	for _, decal in ipairs(decorations(character)) do
		decal.Transparency = 1
	end
	flash(origin, WHITE_HOT, 10, 0.4)
	local torso = torsoOf(character)
	if torso then
		emitter(torso, {
			color = WHITE_HOT, size = 0.5, life = 0.7, speed = 18, spread = 25, glow = 1,
			acceleration = Vector3.new(0, 30, 0),
		}):Emit(30)
	end
	local info = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, part in ipairs(bodyParts(character)) do
		TweenService:Create(part, info, { Transparency = 1, Size = part.Size * 1.3 }):Play()
	end
	task.delay(0.5, function()
		hideBody(character)
	end)
end

-- Turns to a gold statue where it stands; a beat later it topples and crumbles into coins.
EFFECTS.gold = function(character, ctx)
	platformStand(character)
	for _, part in ipairs(bodyParts(character)) do
		part.Anchored = true
		part.Reflectance = 0.35
	end
	recolor(character, GOLD, Enum.Material.Metal, 0.4)
	local torso = torsoOf(character)
	if torso then
		light(torso, Color3.fromRGB(255, 215, 120), 1.5, 14)
		emitter(torso, {
			color = Color3.fromRGB(255, 240, 170), size = 0.3, life = 1, speed = 4, glow = 0.9,
			acceleration = Vector3.new(0, -4, 0),
		}):Emit(20)
	end
	task.delay(2.4, function()
		if not character.Parent then
			return
		end
		ragdoll(character, ctx.impulse * 0.6 + Vector3.new(0, 4, 0))
		for _, part in ipairs(bodyParts(character)) do
			if part.Name ~= "HumanoidRootPart" then
				emitter(part, {
					color = GOLD, colorEnd = Color3.fromRGB(255, 240, 170), size = 0.3, life = 1.1, speed = 7, glow = 0.6,
					acceleration = Vector3.new(0, -25, 0), transparency = 0,
				}):Emit(8)
			end
		end
		deathFx:FireAllClients({ kind = "goldCrumble", position = positionOf(character) })
		fadeOut(character, 1.4, 1.2)
	end)
end

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------

DeathFxService.Effects = EFFECTS

-- Call on every new character so death leaves the body in one piece for us.
function DeathFxService.Prepare(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid then
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
	end
end

-- Runs `effect` on a body. `impulse` is the shove, defaulting to a small hop. Once per body.
function DeathFxService.Apply(character, effect, impulse)
	if not character or not character.Parent or character:GetAttribute("DeathFx") then
		return false
	end
	local run = EFFECTS[effect] or EFFECTS.ragdoll
	effect = EFFECTS[effect] and effect or "ragdoll"
	character:SetAttribute("DeathFx", effect)
	pinRoot(character)
	local position = positionOf(character)
	local ok, err = pcall(run, character, { impulse = impulse or Vector3.new(0, 12, 0), position = position })
	if not ok then
		warn("[DeathFxService] " .. effect .. ": " .. tostring(err))
		hideBody(character)
		return false
	end
	deathFx:FireAllClients({ kind = effect, position = position })
	return true
end

-- CombatService.HandleDeath: the victim, whoever landed the last hit, and the gun they did it
-- with (nil for storm deaths and companion kills, which ragdoll).
function DeathFxService.OnDeath(victimToken, killerToken, def)
	local character = Combatants.GetCharacter(victimToken)
	if not character then
		return
	end
	local impulse = Vector3.new(0, 14, 0)
	local killerRoot = killerToken and killerToken ~= victimToken and Combatants.GetRoot(killerToken) or nil
	if killerRoot then
		local away = positionOf(character) - killerRoot.Position
		local flat = Vector3.new(away.X, 0, away.Z)
		if flat.Magnitude > 0.5 then
			-- Harder-hitting guns shove harder; shotguns hardest.
			local power = 18 + math.min(def and def.damage or 30, 100) * 0.35 + ((def and (def.pellets or 1) > 1) and 12 or 0)
			impulse = flat.Unit * power + Vector3.new(0, 16, 0)
		end
	end
	DeathFxService.Apply(character, def and def.killEffect or "ragdoll", impulse)
end

return DeathFxService
