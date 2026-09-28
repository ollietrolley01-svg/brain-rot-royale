-- Launcher rounds, grenades and smoke bombs on the client: the things you see fly, bounce and go
-- off, the arc that shows where your throw will land, cooking a frag, the warning when one lands
-- beside you, the grey-out inside a smoke cloud, and the kick a blast gives the camera.
--
-- The server (ProjectileService) owns every projectile and sends ProjectileFx events: "round" and
-- "throw" when something is launched, "state" at a bounce or a rest, "detonate", "impact",
-- "smoke", "remove", "cook" and "clear". Flight is replayed here with the same Ballistics maths
-- from the launch event, so nothing streams position by position: a straight round is exact from
-- its launch time; a bouncing one is stepped locally against the same world and nudged onto the
-- server's answer at each bounce, with the difference eased out over a few frames so it never pops.
--
-- Throwing: with a grenade in hand, this script takes the fire button ahead of CombatClient. Press
-- pulls the pin (the server starts the fuse), release throws it toward the crosshair through the
-- normal UseSelected use. A smoke bomb throws on the press. Hold a frag too long and the server sets
-- it off in your hand. The dotted arc runs the same simulation the server will, first bounce
-- included, and ends in a ring the size of the blast (or the cloud).

local ContextActionService = game:GetService("ContextActionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared:WaitForChild("Ballistics"))
local ItemData = require(Shared:WaitForChild("ItemData"))
local ItemModels = require(Shared:WaitForChild("ItemModels"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local ThrowableModels = require(Shared:WaitForChild("ThrowableModels"))
local VehicleWreckFx = require(Shared:WaitForChild("VehicleWreckFx"))
local ExplosiveFx = require(script.Parent:WaitForChild("ExplosiveFx"))
local Settings = require(script.Parent:WaitForChild("Settings"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local UP = Vector3.yAxis

local fx = Remotes.Event("ProjectileFx")
local cookRemote = Remotes.Event("ThrowCook")
local useRemote = Remotes.Event("UseSelected")
local loadoutChanged = Remotes.Event("LoadoutChanged")
local matchChanged = Remotes.Event("MatchChanged")

-- Rounds and grenades launched further than this from the camera aren't drawn; blasts further
-- than the second aren't either (their sound still carries).
local ROUND_CULL = 450
local BLAST_CULL = 650
-- How long a bounce correction takes to ease out, and the biggest one eased rather than snapped.
local SMOOTH_TIME = 0.08
local SMOOTH_LIMIT = 3
-- The sound cue and the visual kind for each blast.
-- The drum launcher's drumlets and the toaster's toast are toys going off, so they have toy blasts.
local BLAST_CUE = { rocket = "ExplosionRocket", grenade = "ExplosionGrenade", frag = "ExplosionFrag", impact = "ExplosionFrag", sticky = "ExplosionFrag",
	drumlet = "ExplosionDrum", lobbedToast = "ExplosionToast" }
-- The server's look-only blasts (HazardService, MountedGuns) arrive as "detonate" with their own cue.
local WEAPON_CUE = { RotMine = "ExplosionMine", ExplosiveBarrel = "ExplosionBarrel", MountedGunWreck = "ExplosionBarrel" }
local BLAST_LOOK = { rocket = "rocket", grenade = "grenade", frag = "frag", impact = "frag", sticky = "frag" }

local loadout = nil
local matchState = "Waiting"

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function inCombat()
	if matchState ~= "InProgress" or not loadout or player:GetAttribute("MenuOpen") then
		return false
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

-- The throwable in hand: its slot, item and Ballistics spec, or nil.
local function throwableInHand()
	local slot = loadout and loadout.equipped and loadout.slots[loadout.equipped]
	if not slot or slot.kind ~= "item" then
		return nil
	end
	local item = ItemData.Get(slot.id)
	local spec = Ballistics.Throwables[slot.id]
	if not item or item.kind ~= "throwable" or not spec then
		return nil
	end
	return slot, item, spec
end

--------------------------------------------------------------------------------
-- Aiming (the same ray CombatClient fires along, so the arc ends where the crosshair points)
--------------------------------------------------------------------------------

local aimParams = RaycastParams.new()
aimParams.FilterType = Enum.RaycastFilterType.Exclude

local function aimFilter(character)
	local filter = { ExplosiveFx.Folder() }
	if character then
		table.insert(filter, character)
	end
	for _, name in ipairs({ "Effects", "Loot", "BRR_GunFx", "DeathFx" }) do
		local instance = workspace:FindFirstChild(name)
		if instance then
			table.insert(filter, instance)
		end
	end
	local companions = workspace:FindFirstChild("Companions")
	if companions then
		for _, model in ipairs(companions:GetChildren()) do
			if model:GetAttribute("OwnerUserId") == player.UserId then
				table.insert(filter, model)
			end
		end
	end
	return filter
end

-- CombatClient's own crosshair point (AimState, its raycast and filters), so the arc, the throw and
-- the crosshair agree. The ray below is only the fallback for before CombatClient has started.
local AimState = nil
do
	local module = script.Parent:FindFirstChild("AimState")
	if module then
		local ok, loaded = pcall(require, module)
		if ok and type(loaded) == "table" and type(loaded.Get) == "function" then
			AimState = loaded
		end
	end
end

local function aimPoint()
	local character = player.Character
	if not character then
		return nil
	end
	if AimState then
		local point = AimState.Get()
		if typeof(point) == "Vector3" then
			return point
		end
	end
	local viewport = camera.ViewportSize
	local ray = camera:ViewportPointToRay(viewport.X / 2, viewport.Y / 2)
	aimParams.FilterDescendantsInstances = aimFilter(character)
	local result = workspace:Raycast(ray.Origin, ray.Direction * 1500, aimParams)
	return result and result.Position or ray.Origin + ray.Direction * 1500
end

--------------------------------------------------------------------------------
-- Sweeping thrown things against the world, the way the server does
--------------------------------------------------------------------------------

local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.IgnoreWater = true
local castFilter = {}

local function prepareCast(thrower)
	castFilter = aimFilter(thrower)
	castParams.FilterDescendantsInstances = castFilter
end

-- Glass is swept past: the server breaks it and flies on, and a pane still standing here for a
-- frame must not bounce the grenade back.
local function cast(origin, radius, displacement)
	for _ = 1, 3 do
		local result = workspace:Spherecast(origin, radius, displacement, castParams)
		if not result then
			return nil
		end
		if result.Instance.Name == "WindowGlass" then
			table.insert(castFilter, result.Instance)
			castParams.FilterDescendantsInstances = castFilter
		else
			return { Position = result.Position, Normal = result.Normal, Distance = result.Distance, Instance = result.Instance }
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Screen: the smoke grey-out, the blast flash, the fuse bar, the danger markers
--------------------------------------------------------------------------------

local screen = {}
do
	local playerGui = player:WaitForChild("PlayerGui")

	local underlay = Instance.new("ScreenGui")
	underlay.Name = "BRR_SmokeOverlay"
	underlay.IgnoreGuiInset = true
	underlay.ResetOnSpawn = false
	underlay.DisplayOrder = -5
	underlay.Parent = playerGui

	local grey = Instance.new("Frame")
	grey.Name = "Smoke"
	grey.Size = UDim2.fromScale(1, 1)
	grey.BackgroundColor3 = Color3.fromRGB(188, 190, 194)
	grey.BackgroundTransparency = 1
	grey.BorderSizePixel = 0
	grey.Parent = underlay

	local flash = Instance.new("Frame")
	flash.Name = "Flash"
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = Color3.fromRGB(255, 236, 200)
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Parent = underlay

	local overlay = Instance.new("ScreenGui")
	overlay.Name = "BRR_Throwables"
	overlay.IgnoreGuiInset = true
	overlay.ResetOnSpawn = false
	overlay.DisplayOrder = 5
	overlay.Parent = playerGui

	-- The fuse: a thin bar under the crosshair that empties as the fuse burns, reddening.
	local fuseBack = Instance.new("Frame")
	fuseBack.Name = "Fuse"
	fuseBack.AnchorPoint = Vector2.new(0.5, 0.5)
	fuseBack.Position = UDim2.new(0.5, 0, 0.5, 46)
	fuseBack.Size = UDim2.fromOffset(128, 7)
	fuseBack.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
	fuseBack.BackgroundTransparency = 0.35
	fuseBack.BorderSizePixel = 0
	fuseBack.Visible = false
	fuseBack.Parent = overlay
	local fuseCorner = Instance.new("UICorner")
	fuseCorner.CornerRadius = UDim.new(0, 4)
	fuseCorner.Parent = fuseBack
	local fuseFill = Instance.new("Frame")
	fuseFill.Size = UDim2.fromScale(1, 1)
	fuseFill.BackgroundColor3 = Color3.fromRGB(255, 140, 50)
	fuseFill.BorderSizePixel = 0
	fuseFill.Parent = fuseBack
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fuseFill
	local fuseLabel = Instance.new("TextLabel")
	fuseLabel.AnchorPoint = Vector2.new(0.5, 1)
	fuseLabel.Position = UDim2.new(0.5, 0, 0, -3)
	fuseLabel.Size = UDim2.fromOffset(160, 16)
	fuseLabel.BackgroundTransparency = 1
	fuseLabel.Font = Enum.Font.FredokaOne
	fuseLabel.TextSize = 14
	fuseLabel.TextColor3 = Color3.fromRGB(255, 220, 180)
	fuseLabel.TextStrokeTransparency = 0.5
	fuseLabel.Text = "COOKING"
	fuseLabel.Parent = fuseBack

	-- Danger markers: a red disc with "!" and an arrow that points at the grenade when it's off
	-- screen. A few, pooled.
	local markers = {}
	for _ = 1, 3 do
		local marker = Instance.new("Frame")
		marker.AnchorPoint = Vector2.new(0.5, 0.5)
		marker.Size = UDim2.fromOffset(34, 34)
		marker.BackgroundColor3 = Color3.fromRGB(225, 40, 36)
		marker.BorderSizePixel = 0
		marker.Visible = false
		marker.Parent = overlay
		local round = Instance.new("UICorner")
		round.CornerRadius = UDim.new(1, 0)
		round.Parent = marker
		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.fromRGB(255, 230, 230)
		stroke.Thickness = 2
		stroke.Parent = marker
		local bang = Instance.new("TextLabel")
		bang.Size = UDim2.fromScale(1, 1)
		bang.BackgroundTransparency = 1
		bang.Font = Enum.Font.FredokaOne
		bang.TextSize = 24
		bang.TextColor3 = Color3.fromRGB(255, 255, 255)
		bang.Text = "!"
		bang.Parent = marker
		local arrow = Instance.new("Frame")
		arrow.AnchorPoint = Vector2.new(0.5, 0.5)
		arrow.Size = UDim2.fromOffset(14, 14)
		arrow.Position = UDim2.new(0.5, 0, 0.5, -28)
		arrow.BackgroundColor3 = Color3.fromRGB(225, 40, 36)
		arrow.BorderSizePixel = 0
		arrow.Rotation = 45
		arrow.Visible = false
		arrow.Parent = marker
		table.insert(markers, { frame = marker, arrow = arrow })
	end

	local blur = Instance.new("BlurEffect")
	blur.Name = "BRR_SmokeBlur"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting

	screen.grey = grey
	screen.flash = flash
	screen.blur = blur
	screen.fuseBack = fuseBack
	screen.fuseFill = fuseFill
	screen.fuseLabel = fuseLabel
	screen.markers = markers
end

--------------------------------------------------------------------------------
-- Things in flight
--------------------------------------------------------------------------------

-- id -> entry. A round: { kind, spec, model, motion, origin, direction, gravity, t0, position,
-- velocity, whoosh }. A thrown item or a dud: those plus body { position, velocity, resting },
-- rotation, spin, fuseAt (server time), glows.
local flying = {}
-- Thrown models left lying where they stopped (a smoke bomb's cup in its cloud): { model, until }.
local props = {}

local function glowParts(model)
	local glows = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") and part.Name == "Glow" then
			table.insert(glows, part)
		end
	end
	return glows
end

local function dropEntry(entry)
	if entry.whoosh then
		entry.whoosh:Stop()
	end
	if entry.model then
		entry.model:Destroy()
	end
	flying[entry.id] = nil
end

-- What a steering round's own `steer` may ask of the client: the living characters near it, the way
-- the server's Combatants gives them (players and bots alike), each with its root part. The
-- shooter is left out, as the server leaves the owner out.
local clientApi = {}
-- The characters in the workspace, rescanned at most every 0.1 s and shared by every homing round in
-- flight: steer asks every frame, and a workspace scan per round per frame grows with the map.
local bodies, bodiesAt = {}, -math.huge
function clientApi.Targets(position, range, exceptCharacter)
	local now = os.clock()
	if now - bodiesAt > 0.1 then
		bodiesAt = now
		table.clear(bodies)
		for _, model in ipairs(workspace:GetChildren()) do
			local humanoid = model:IsA("Model") and model:FindFirstChildOfClass("Humanoid")
			local root = humanoid and model:FindFirstChild("HumanoidRootPart")
			if root then
				table.insert(bodies, { root = root, humanoid = humanoid, character = model })
			end
		end
	end
	local found = {}
	for _, body in ipairs(bodies) do
		if body.character ~= exceptCharacter and body.root.Parent and body.humanoid.Health > 0
			and (body.root.Position - position).Magnitude <= range then
			table.insert(found, body)
		end
	end
	table.sort(found, function(a, b)
		return (a.root.Position - position).Magnitude < (b.root.Position - position).Magnitude
	end)
	return found
end

local function onRound(info)
	local spec = Ballistics.Rounds[info.kind]
	if not spec or typeof(info.origin) ~= "Vector3" or typeof(info.direction) ~= "Vector3" then
		return
	end
	if (info.origin - camera.CFrame.Position).Magnitude > ROUND_CULL then
		return
	end
	-- Any registered kind: a hand-built model, its look, or a plain ball. Never nothing.
	local model = ThrowableModels.Round(info.kind, 1)
	model.Parent = ExplosiveFx.Folder()
	local spin = ThrowableModels.SpinOf(info.kind)
	local entry = {
		id = info.id,
		kind = info.kind,
		spec = spec,
		model = model,
		motion = info.motion or "line",
		origin = info.origin,
		direction = info.direction,
		gravity = info.gravity or workspace.Gravity,
		t0 = info.t or serverNow(),
		age = 0,
		position = info.origin,
		velocity = info.velocity or info.direction * spec.speed,
		smooth = Vector3.zero,
		shooter = info.shooter,
		owner = info.shooter,
		look = spin,
		spinAngle = 0,
		radius = type(info.radius) == "number" and info.radius or nil,
		rotation = CFrame.lookAt(Vector3.zero, info.direction),
	}
	if entry.motion == "body" then
		entry.body = { position = info.origin, velocity = entry.velocity, spec = spec, resting = false }
		entry.spin = Vector3.new(1, 0.3, 0).Unit
		entry.spinRate = spin == "tumble" and 8 or 0
	end
	if info.kind == "rocket" then
		ExplosiveFx.Trail(model.PrimaryPart, Vector3.new(0, 0, 1.5))
		entry.whoosh = ExplosiveFx.Loop("RocketWhoosh", model.PrimaryPart)
	end
	flying[info.id] = entry
	model:PivotTo(Ballistics.RoundOrientation(spin, info.origin, entry.velocity, 0))
end

local function onThrow(info)
	local spec = Ballistics.Throwables[info.item]
	local item = ItemData.Get(info.item)
	if not spec or not item or typeof(info.position) ~= "Vector3" or typeof(info.velocity) ~= "Vector3" then
		return
	end
	if (info.position - camera.CFrame.Position).Magnitude > ROUND_CULL then
		return
	end
	local model = ItemModels.Build(info.item, { name = "BRR_Thrown" })
	if not model then
		return
	end
	model.Parent = ExplosiveFx.Folder()
	local rng = Random.new()
	local entry = {
		id = info.id,
		kind = spec.kind,
		item = item,
		spec = spec,
		model = model,
		motion = "body",
		gravity = info.gravity or workspace.Gravity,
		t0 = info.t or serverNow(),
		body = { position = info.position, velocity = info.velocity, spec = spec, resting = false },
		smooth = Vector3.zero,
		rotation = CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6)),
		spin = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.4, 0.4), rng:NextNumber(-1, 1)).Unit,
		spinRate = rng:NextNumber(7, 11),
		fuseAt = info.fuseAt,
		thrower = info.thrower,
		glows = glowParts(model),
	}
	flying[info.id] = entry
	model:PivotTo(CFrame.new(info.position) * entry.rotation)
end

local function onState(info)
	local entry = flying[info.id]
	if not entry or typeof(info.position) ~= "Vector3" or typeof(info.velocity) ~= "Vector3" then
		return
	end
	local visual = entry.body and (entry.body.position + entry.smooth) or entry.position
	if info.body or entry.body then
		entry.motion = "body"
		entry.body = { position = info.position, velocity = info.velocity, spec = entry.spec, resting = info.resting == true }
		if not entry.spin then
			entry.spin = Vector3.new(1, 0.2, 0.3).Unit
			entry.spinRate = 9
			entry.rotation = entry.rotation or CFrame.identity
		end
		local offset = visual - info.position
		entry.smooth = offset.Magnitude <= SMOOTH_LIMIT and offset or Vector3.zero
		-- A dud round now has a fuse of its own.
		if type(info.fuseAt) == "number" then
			entry.fuseAt = info.fuseAt
		end
	else
		-- A steering round's periodic correction: eased out like a bounce, never snapped.
		local offset = visual - info.position
		entry.smooth = offset.Magnitude <= SMOOTH_LIMIT and offset or Vector3.zero
		entry.position = info.position
		entry.velocity = info.velocity
	end
	if info.bounce and info.bounce > 4 and (info.position - camera.CFrame.Position).Magnitude < 160 then
		Sfx.PlayAt("GrenadeBounce", info.position, 0.25)
	end
end

-- A sticky has stuck to something, or someone: from now on its model rides on that part with its
-- underside to the surface, and its timer blinks and beeps down to the blast.
local function onStuck(info)
	local entry = flying[info.id]
	if not entry or not entry.body or typeof(info.part) ~= "Instance" or not info.part:IsA("BasePart") then
		return
	end
	if typeof(info.position) ~= "Vector3" or typeof(info.normal) ~= "Vector3" then
		return
	end
	entry.stuck = { part = info.part, localPosition = info.position, localNormal = info.normal }
	-- Its timer lights now, not before: unlit, the one in your hand isn't mistaken for a detonator.
	if entry.model then
		entry.glows = ThrowableModels.Arm(entry.model)
	end
	entry.body.resting = true
	entry.body.velocity = Vector3.zero
	entry.smooth = Vector3.zero
	entry.spinRate = 0
	if type(info.fuseAt) == "number" then
		entry.fuseAt = info.fuseAt
	end
	entry.nextBeepAt = os.clock()
	if typeof(info.at) == "Vector3" and (info.at - camera.CFrame.Position).Magnitude < 160 then
		Sfx.PlayAt("StickySquelch", info.at, 0.15)
	end
end

-- The camera's kick from a blast, decaying; applied around Roblox's own camera update the way
-- CombatClient's recoil is (undone before it runs, put back after), so it never becomes aim.
local shake = 0
local appliedShake = nil
local shakeSeed = Random.new()

RunService:BindToRenderStep("BRR_BlastShakeUndo", Enum.RenderPriority.Camera.Value - 2, function()
	if appliedShake then
		camera.CFrame = camera.CFrame * appliedShake:Inverse()
		appliedShake = nil
	end
end)

RunService:BindToRenderStep("BRR_BlastShake", Enum.RenderPriority.Camera.Value + 3, function(delta)
	if shake <= 0.002 then
		shake = 0
		return
	end
	local offset = CFrame.new(
		shakeSeed:NextNumber(-1, 1) * shake * 0.35,
		shakeSeed:NextNumber(-1, 1) * shake * 0.35,
		0
	) * CFrame.Angles(shakeSeed:NextNumber(-1, 1) * shake * 0.045, shakeSeed:NextNumber(-1, 1) * shake * 0.045, shakeSeed:NextNumber(-1, 1) * shake * 0.025)
	camera.CFrame = camera.CFrame * offset
	appliedShake = offset
	shake -= shake * math.clamp(delta * 5, 0, 1)
end)

local flashUntil = 0
local flashStrength = 0

local function onDetonate(info)
	local entry = flying[info.id]
	if entry then
		dropEntry(entry)
	end
	if typeof(info.position) ~= "Vector3" then
		return
	end
	local position = info.position
	local normal = typeof(info.normal) == "Vector3" and info.normal or nil
	local radius = type(info.radius) == "number" and info.radius or 10
	local kind = info.kind or "frag"
	local distance = (position - camera.CFrame.Position).Magnitude

	if distance < BLAST_CULL then
		-- info.weaponId: a silly gun's blast is drawn in its own theme (SillyExplosionFx), same radius.
		ExplosiveFx.Explosion(position, normal, BLAST_LOOK[kind] or "frag", radius, info.weaponId)
	end

	-- The blast, its debris off whatever it hit and, right beside it, the muffle; past the cue's reach
	-- its ExplosionFar rumble carries on alone (Sfx.Blast, Sfx.PlayAt). A themed blast plays its themed
	-- cue when SoundConfig has one, and the plain one when it doesn't.
	local cue = ExplosiveFx.ThemeCue(info.weaponId) or WEAPON_CUE[info.weaponId] or BLAST_CUE[kind] or "ExplosionFrag"
	Sfx.Blast(cue, position, normal, radius)

	-- The kick: hard at point blank, nothing past a few radii. A smaller blast kicks less.
	local strength = math.clamp(1 - distance / (radius * 4.5), 0, 1) * (kind == "grenade" and 0.7 or 1)
	if strength > 0 and Settings.Get("ScreenShake") ~= false then
		shake = math.max(shake, strength)
	end
	if strength > 0.35 then
		flashStrength = math.max(flashStrength, (strength - 0.35) / 0.65 * 0.55)
		-- Wall time (and below where it fades), not os.clock: CPU time in Roblox.
		flashUntil = tick() + 0.3
	end
end

-- A vehicle goes up the moment it's wrecked: its fuel lights (VehicleWreckFx.Watch sees it happen,
-- at any distance). Drawn within BLAST_CULL like any other blast; Sfx.Blast does its own falloff.
VehicleWreckFx.OnWreck = function(model)
	local chassis = model:FindFirstChild("Chassis")
	if chassis and chassis:IsA("BasePart") then
		-- And is seen to: ExplosiveFx's grenade-standard blast (look only; the wreck did no blast damage).
		if (chassis.Position - camera.CFrame.Position).Magnitude < BLAST_CULL then
			ExplosiveFx.Explosion(chassis.Position, nil, "grenade", 12, "VehicleWreck")
		end
		Sfx.Blast("ExplosionVehicle", chassis.Position, nil, 16)
	end
end

local function onImpact(info)
	local entry = flying[info.id]
	if entry then
		dropEntry(entry)
	end
	if typeof(info.position) == "Vector3" and (info.position - camera.CFrame.Position).Magnitude < BLAST_CULL then
		ExplosiveFx.Impact(info.position, typeof(info.normal) == "Vector3" and info.normal or nil, info.weaponId)
		local themed = ExplosiveFx.ThemeCue(info.weaponId)
		Sfx.PlayAt(themed or "GrenadeBounce", info.position, 0.2)
	end
end

local function onSmoke(info)
	local spec = Ballistics.Throwables[info.item]
	if not spec or typeof(info.position) ~= "Vector3" then
		return
	end
	local startsAt = type(info.t) == "number" and info.t or serverNow()
	local elapsed = serverNow() - startsAt
	ExplosiveFx.Cloud(info.position, spec, elapsed)
	Sfx.PlayAt("SmokeHiss", info.position, 0.1)
	task.delay(math.max(0, -elapsed), function()
		Sfx.PlayAt("SmokeBillow", info.position, 0.1)
	end)
	-- The cup stays where it stopped, in its own cloud.
	local entry = flying[info.id]
	if entry then
		flying[info.id] = nil
		table.insert(props, { model = entry.model, expiresAt = os.clock() + spec.grow + spec.hold + spec.fade })
	end
end

local function onRemove(info)
	local entry = flying[info.id]
	if entry then
		dropEntry(entry)
	end
end

local function clearAll()
	for _, entry in pairs(flying) do
		dropEntry(entry)
	end
	for _, prop in ipairs(props) do
		prop.model:Destroy()
	end
	table.clear(props)
	ExplosiveFx.Clear()
end

--------------------------------------------------------------------------------
-- Cooking and throwing
--------------------------------------------------------------------------------

-- { slot, item, spec, index, startedAt, ticks, touch } while a frag's pin is out in our hand.
local cook = nil

-- The arc preview goes the moment a throw leaves the hand (#63). Without this it stayed drawn until
-- the server's LoadoutChanged came back -- a whole round trip, arc, ring and sticky ghost still up
-- while the thing flew -- and for a stack it never visibly went at all. So: hidden for a beat after
-- every throw, and past that beat for as long as the loadout it answers hasn't arrived, up to a
-- second (a refused throw sends no loadout, and must not blind the preview for good). Wall time,
-- not os.clock (CPU time on a client). The block between the markers is what
-- tools/throwable_preview_check.py runs.
-- BEGIN throwGate
local throwGate = {}
do
	local HIDE_MIN = 0.3
	local HIDE_MAX = 1
	local thrownAt = -math.huge
	local waiting = false
	function throwGate.Thrown(now)
		thrownAt = now
		waiting = true
	end
	function throwGate.LoadoutArrived()
		waiting = false
	end
	function throwGate.Hidden(now)
		local since = now - thrownAt
		return since < HIDE_MIN or (waiting and since < HIDE_MAX)
	end
end
-- END throwGate

local function stopCook()
	cook = nil
	screen.fuseBack.Visible = false
end

-- Stopping a cook without throwing it (a menu opened, out of combat, at the wheel): the server is told
-- to put the pin back in too, or its cook would still go off in our hand with no fuse bar up.
local function cancelCook()
	if cook then
		cookRemote:FireServer(false)
	end
	stopCook()
end

-- `touch`: started on the phone's COOK button. A finger has no state to poll (CombatClient's
-- stillHeld), so that cook throws on the button's End rather than on the frame loop's throwHeld().
local function startCook(slot, item, spec, touch)
	cook = { slot = slot, item = item, spec = spec, index = loadout.equipped, startedAt = os.clock(), ticks = 0, touch = touch }
	cookRemote:FireServer()
	Sfx.Play("CoconutPinPull", 0.05)
	screen.fuseFill.BackgroundColor3 = item.color
	screen.fuseFill.Size = UDim2.fromScale(1, 1)
	screen.fuseBack.Visible = true
end

local function throwNow()
	useRemote:FireServer(aimPoint())
	throwGate.Thrown(serverNow())
	stopCook()
end

local function throwHeld()
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2)
end

-- At the wheel of a car (a VehicleSeat; passengers sit on plain Seats, and every bike seat is free):
-- no throwing. The server refuses it too (CombatService.SeatBarsWeapons); this just keeps the click from
-- doing anything.
local function driving()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local seat = humanoid and humanoid.SeatPart
	return seat ~= nil and seat:IsA("VehicleSeat") and not (seat.Parent ~= nil and seat.Parent:GetAttribute("VehicleKind") == "bike")
end

-- The phone's COOK button (see ON A PHONE below); declared here so the handler can tell its presses apart.
local COOK_ACTION = "BRR_Cook"

local function onThrowInput(actionName, inputState)
	local slot, item, spec = throwableInHand()
	if not slot or not inCombat() then
		return Enum.ContextActionResult.Pass
	end
	-- A vehicle gun that's ours (the gunner's seat, or the wheel of an armed vehicle) owns the click and
	-- R2: this binding sits above VehicleWeaponClient's, so they go down to it. A frag already cooking
	-- still throws on release; the phone's COOK button shares nothing with the gun and still works.
	if not cook and actionName ~= COOK_ACTION and player:GetAttribute("VehicleGunActive") then
		return Enum.ContextActionResult.Pass
	end
	if inputState == Enum.UserInputState.Begin then
		if cook or driving() then
			return Enum.ContextActionResult.Sink
		end
		if os.clock() < (loadout and loadout.equipReadyAt or 0) then
			return Enum.ContextActionResult.Sink
		end
		if spec.cookable then
			startCook(slot, item, spec, actionName == COOK_ACTION)
		else
			useRemote:FireServer(aimPoint())
			throwGate.Thrown(serverNow())
		end
		return Enum.ContextActionResult.Sink
	elseif inputState == Enum.UserInputState.End then
		if cook then
			throwNow()
		end
		return Enum.ContextActionResult.Sink
	elseif inputState == Enum.UserInputState.Cancel and actionName == COOK_ACTION and cook and cook.touch then
		-- A cancelled action never gets its End, and a finger can't be polled: throw it now rather than
		-- leave it cooking until it goes off in the hand.
		throwNow()
		return Enum.ContextActionResult.Sink
	end
	-- Cancel: the button may still be down; the frame loop watches it and throws on release.
	return Enum.ContextActionResult.Sink
end

ContextActionService:BindActionAtPriority("BRR_Throw", onThrowInput, false,
	Enum.ContextActionPriority.High.Value, Enum.UserInputType.MouseButton1, Enum.KeyCode.ButtonR2)

-- ON A PHONE. The binding above never sees a touch: it lists MouseButton1 and ButtonR2 and draws no
-- button, so the only thing a touch screen has is CombatClient's FIRE button, whose item branch fires
-- the use remote on press -- which throws a coconut with its whole fuse still on it. Cooking was
-- unreachable on the entire platform.
--
-- So while a COOKABLE throwable is in hand, and only then, a second binding of the same handler draws
-- its own button. Only then, because ContextActionService draws at most seven touch buttons and this
-- game already binds more than that (CombatClient's CAM note): a button that exists for the few
-- seconds a coconut is in your hand costs a slot nobody else is using at that moment. Held, exactly
-- like the mouse: press starts the fuse, release throws.
--
-- The real home for this is StarterPlayerScripts/TouchControls (it has "extra1"/"extra2" slots and
-- draws every touch button in one place), but its feature flag is off, so nothing it binds appears.
-- When that flag goes live this should move there and lose its own button.
local cookButtonBound = false

local function refreshCookButton()
	local _, _, spec = throwableInHand()
	local wanted = UserInputService.TouchEnabled and spec ~= nil and spec.cookable == true and inCombat()
	if wanted == cookButtonBound then
		return
	end
	cookButtonBound = wanted
	if wanted then
		-- Bound to a key nobody presses, so only the drawn button fires it. Bound to Touch it took every
		-- touch on the screen (a camera swipe, a tap on the world), cooking and throwing on each one and
		-- sinking the camera's drag. The "cook" flag first: it takes RELOAD's button away (nothing reloads a
		-- coconut) so COOK is the seventh, on RELOAD's square beside FIRE (PhoneLayout.TouchSet).
		Settings.SetTouchFlag("cook", true)
		Settings.BindSeat(COOK_ACTION, onThrowInput, { title = "COOK", position = UDim2.new(1, -140, 1, -400) },
			Enum.ContextActionPriority.High.Value, Enum.KeyCode.World95)
	else
		Settings.UnbindSeat(COOK_ACTION)
		Settings.SetTouchFlag("cook", false)
	end
end

local function onCook(info)
	if info.thrower == player.Character then
		return
	end
	if typeof(info.position) == "Vector3" and (info.position - camera.CFrame.Position).Magnitude < 60 then
		Sfx.PlayAt("CoconutPinPull", info.position, 0.05)
	end
end

--------------------------------------------------------------------------------
-- The arc preview and the danger rings
--------------------------------------------------------------------------------

local preview = {}
do
	-- The sticky's placement ghost (a translucent copy of the item where the throw will stick).
	local StickyPreview = require(script.Parent:WaitForChild("StickyPreview"))
	local DOTS = 40
	local dots = {}
	local ring = nil

	local function ensure()
		if ring and ring.Parent then
			return
		end
		ring = Instance.new("CylinderHandleAdornment")
		ring.Name = "BRR_LandingRing"
		ring.Adornee = workspace.Terrain
		ring.Height = 0.25
		ring.AlwaysOnTop = false
		ring.ZIndex = 1
		ring.Transparency = 0.4
		ring.Visible = false
		ring.Parent = workspace.Terrain
		for index = 1, DOTS do
			local dot = dots[index]
			if not dot or not dot.Parent then
				dot = Instance.new("Part")
				dot.Name = "ArcDot"
				dot.Shape = Enum.PartType.Ball
				dot.Size = Vector3.new(0.26, 0.26, 0.26)
				dot.Material = Enum.Material.Neon
				dot.Anchored = true
				dot.CanCollide = false
				dot.CanQuery = false
				dot.CanTouch = false
				dot.CastShadow = false
				dot.Transparency = 1
				dot.Parent = ExplosiveFx.Folder()
				dots[index] = dot
			end
		end
	end

	local shown = false
	local nextSimAt = 0
	local function hide()
		-- The ghost goes whatever `shown` says: it is placed before `shown` is set, so an error in
		-- between would otherwise leave it standing for good.
		StickyPreview.Hide()
		-- Re-simulated on the first frame it comes back, not up to a 30th later from a stale arc.
		nextSimAt = 0
		if not shown then
			return
		end
		shown = false
		if ring then
			ring.Visible = false
		end
		for _, dot in ipairs(dots) do
			dot.Transparency = 1
		end
	end

	-- Where a ring should sit: on the ground under `position`, or at the position itself in the air.
	local groundParams = RaycastParams.new()
	groundParams.FilterType = Enum.RaycastFilterType.Include
	local function groundUnder(position, reach)
		local include = { workspace.Terrain }
		for _, name in ipairs({ "Map", "Defenses", "Deployables" }) do
			local instance = workspace:FindFirstChild(name)
			if instance then
				table.insert(include, instance)
			end
		end
		groundParams.FilterDescendantsInstances = include
		local hit = workspace:Raycast(position + UP * 0.5, -UP * (reach + 0.5), groundParams)
		return hit and hit.Position + UP * 0.08 or position
	end
	preview.groundUnder = groundUnder

	-- The arc is re-simulated thirty times a second, not every frame: ninety sweeps a pass is plenty
	-- at that rate and nothing about it changes faster.
	function preview.update()
		local slot, item, spec = throwableInHand()
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not slot or not head or not root or not inCombat() or throwGate.Hidden(serverNow()) then
			hide()
			return
		end
		if os.clock() < nextSimAt then
			return
		end
		nextSimAt = os.clock() + 1 / 30
		ensure()

		local target = aimPoint() or head.Position + camera.CFrame.LookVector * 30
		local velocity = Ballistics.ThrowVelocity(spec, head.Position, target, root.AssemblyLinearVelocity)
		local direction = Ballistics.ThrowDirection(spec, head.Position, target)
		prepareCast(character)
		local origin = Ballistics.ThrowOrigin(head.Position, direction)
		local wall = workspace:Raycast(head.Position, origin - head.Position, castParams)
		if wall then
			origin = head.Position + direction * math.max(0, wall.Distance - spec.radius - 0.05)
		end

		-- The flight the server will compute, stepped the same way, until it rests or (cooking) the
		-- fuse runs out in the air.
		local body = { position = origin, velocity = velocity, spec = spec, resting = false }
		local remaining = cook and math.max(0, spec.fuse - (os.clock() - cook.startedAt)) or 3
		local path = { origin }
		local firstContact, stickHit = nil, nil
		-- A sticky's flight ends at its first touch: that is where it will be.
		local sticky = spec.kind == "sticky"
		local elapsed = 0
		local step = 1 / 30
		for _ = 1, 90 do
			local contact = Ballistics.StepBody(body, step, workspace.Gravity, cast)
			elapsed += step
			table.insert(path, body.position)
			if contact and not firstContact then
				firstContact = #path
				stickHit = contact
				if sticky then
					break
				end
			end
			if body.resting or elapsed >= remaining then
				break
			end
		end

		-- Dots every stud and a half along the path; the ones after the first bounce fainter.
		local spacing = 1.5
		local used = 0
		local carried = 0
		for index = 2, #path do
			local from, to = path[index - 1], path[index]
			local length = (to - from).Magnitude
			local at = spacing - carried
			while at <= length and used < DOTS do
				used += 1
				local dot = dots[used]
				dot.Position = from + (to - from) * (at / length)
				dot.Color = item.color
				local after = firstContact ~= nil and index > firstContact
				dot.Transparency = after and 0.65 or 0.15
				dot.Size = after and Vector3.new(0.18, 0.18, 0.18) or Vector3.new(0.26, 0.26, 0.26)
				at += spacing
			end
			carried = length - (at - spacing)
		end
		for index = used + 1, DOTS do
			dots[index].Transparency = 1
		end

		-- The ring: the blast (or the cloud) where it comes to rest or goes off.
		local landing = path[#path]
		local radius = spec.kind == "smoke" and spec.smokeRadius or (spec.blastRadius or 8)
		local onGround = body.resting or (cook == nil)
		-- The sticky's ghost: on the surface it will stick to, green; where the throw met nothing
		-- it could hold (out of range, over the edge), red, and the ring goes with it.
		if sticky then
			if stickHit then
				StickyPreview.Show(item.id, stickHit.position, stickHit.normal, true)
				landing = stickHit.position
			else
				StickyPreview.Show(item.id, landing, UP, false)
			end
			onGround = true
		else
			StickyPreview.Hide()
		end
		local centre = onGround and groundUnder(landing, 6) or landing
		ring.CFrame = CFrame.new(centre) * CFrame.Angles(math.pi / 2, 0, 0)
		ring.Radius = radius
		ring.InnerRadius = math.max(0, radius - 0.4)
		ring.Color3 = cook and Color3.fromRGB(255, 70, 50) or item.color
		ring.Transparency = cook and 0.25 + 0.15 * math.sin(os.clock() * 12) or 0.4
		ring.Visible = true
		shown = true
	end

	preview.hide = hide
end

-- Rings under live grenades that could reach us, and the screen markers pointing at them.
local danger = {}
do
	local rings = {}
	local MAX = 3

	local function ensure(index)
		local ring = rings[index]
		if ring and ring.Parent then
			return ring
		end
		ring = Instance.new("CylinderHandleAdornment")
		ring.Name = "BRR_DangerRing"
		ring.Adornee = workspace.Terrain
		ring.Height = 0.25
		ring.AlwaysOnTop = false
		ring.ZIndex = 1
		ring.Color3 = Color3.fromRGB(235, 40, 36)
		ring.Visible = false
		ring.Parent = workspace.Terrain
		rings[index] = ring
		return ring
	end

	function danger.update()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local shown = 0
		if root and inCombat() then
			for _, entry in pairs(flying) do
				if shown >= MAX then
					break
				end
				-- A thrown item's blast from its spec; a round's from its launch event (nil when it
				-- doesn't blow up).
				local radius = entry.spec.blastRadius or entry.radius
				if entry.body and entry.fuseAt and radius and entry.kind ~= "smoke" then
					local position = entry.body.position
					if (position - root.Position).Magnitude <= radius + 3 then
						shown += 1
						local left = entry.fuseAt - serverNow()
						local pulse = 0.35 + 0.3 * math.sin(os.clock() * (left < 1 and 22 or 10))
						local ring = ensure(shown)
						ring.CFrame = CFrame.new(preview.groundUnder(position, 8)) * CFrame.Angles(math.pi / 2, 0, 0)
						ring.Radius = radius
						ring.InnerRadius = radius - 0.5
						ring.Transparency = pulse
						ring.Visible = true

						local marker = screen.markers[shown]
						local viewport = camera.ViewportSize
						local point, onScreen = camera:WorldToViewportPoint(position + UP * 1.2)
						if onScreen and point.Z > 0 then
							marker.frame.Position = UDim2.fromOffset(point.X, point.Y)
							marker.arrow.Visible = false
						else
							-- Off screen: at the edge, in its direction, with the arrow pointing out.
							local centre = Vector2.new(viewport.X / 2, viewport.Y / 2)
							local direction = Vector2.new(point.X - centre.X, point.Y - centre.Y)
							if point.Z < 0 then
								direction = -direction
							end
							direction = direction.Magnitude > 1 and direction.Unit or Vector2.new(0, 1)
							local edge = centre + direction * (math.min(viewport.X, viewport.Y) / 2 - 60)
							marker.frame.Position = UDim2.fromOffset(edge.X, edge.Y)
							marker.arrow.Visible = true
							marker.arrow.Rotation = 45
							marker.arrow.Position = UDim2.new(0.5, direction.X * 28, 0.5, direction.Y * 28)
						end
						marker.frame.Visible = true
					end
				end
			end
		end
		for index = shown + 1, MAX do
			if rings[index] then
				rings[index].Visible = false
			end
			screen.markers[index].frame.Visible = false
		end
	end
end

--------------------------------------------------------------------------------
-- Per frame
--------------------------------------------------------------------------------

local function stepFlying(dt, now)
	for _, entry in pairs(flying) do
		local spec = entry.spec
		if entry.look == "flat" or entry.look == "roll" then
			entry.spinAngle += (Ballistics.SpinRate[entry.look] or 20) * dt
		end
		if entry.motion == "line" then
			local position, velocity = Ballistics.RoundState(spec, entry.origin, entry.direction, entry.gravity, now - entry.t0)
			entry.position = position
			entry.velocity = velocity
			entry.model:PivotTo(Ballistics.RoundOrientation(entry.look, position, velocity, entry.spinAngle))
		elseif entry.motion == "free" then
			-- The same step the server takes (its steer with our Targets), so the path curves here the
			-- way it curves there; the server's periodic state sends ease out whatever is left.
			entry.age += dt
			local position, velocity = Ballistics.FreeStep(entry, dt, entry.gravity, clientApi)
			entry.position = position
			entry.velocity = velocity
			entry.smooth *= math.max(0, 1 - dt / SMOOTH_TIME)
			entry.model:PivotTo(Ballistics.RoundOrientation(entry.look, position + entry.smooth, velocity, entry.spinAngle))
		else
			local body = entry.body
			if entry.stuck then
				-- Riding on the part it stuck to, underside to the surface.
				local part = entry.stuck.part
				if part.Parent then
					body.position = part.CFrame:PointToWorldSpace(entry.stuck.localPosition)
					local normal = part.CFrame:VectorToWorldSpace(entry.stuck.localNormal)
					entry.model:PivotTo(Ballistics.StuckFrame(body.position - normal * spec.radius, normal, spec.stickOffset or 0))
				end
				-- The timer: a neon blink and a beep, both quickening toward the blast.
				if entry.glows and entry.fuseAt then
					local left = math.max(0, entry.fuseAt - now)
					local period = math.clamp(left * 0.3, 0.08, 0.6)
					local on = (os.clock() % period) / period < 0.5
					local color = on and Color3.fromRGB(255, 250, 220) or entry.item.color
					for _, glow in ipairs(entry.glows) do
						glow.Color = color
					end
					if os.clock() >= (entry.nextBeepAt or 0) then
						entry.nextBeepAt = os.clock() + period
						if (body.position - camera.CFrame.Position).Magnitude < 90 then
							Sfx.PlayAt("StickyBeep", body.position, 0.02)
						end
					end
				end
			else
				if not body.resting then
					prepareCast(entry.thrower or entry.shooter)
					Ballistics.StepBody(body, dt, entry.gravity, cast)
					entry.rotation = entry.rotation * CFrame.fromAxisAngle(entry.spin, entry.spinRate * dt)
					if body.resting then
						entry.spinRate = 0
					end
				end
				entry.smooth *= math.max(0, 1 - dt / SMOOTH_TIME)
				entry.model:PivotTo(CFrame.new(body.position + entry.smooth) * entry.rotation)

				-- A frag's crack glows hotter as the fuse runs down; the last second flickers.
				if entry.glows and entry.fuseAt then
					local left = math.max(0, entry.fuseAt - now)
					local rate = left < 1 and 26 or (left < 2 and 12 or 6)
					local pulse = 0.5 + 0.5 * math.sin(os.clock() * rate)
					local heat = math.clamp(pulse * (1.25 - math.clamp(left / 3.2, 0, 1)), 0, 1)
					local color = entry.item.color:Lerp(Color3.fromRGB(255, 250, 220), heat)
					for _, glow in ipairs(entry.glows) do
						glow.Color = color
					end
				end
			end
		end
	end
	for index = #props, 1, -1 do
		local prop = props[index]
		if os.clock() >= prop.expiresAt or not prop.model.Parent then
			prop.model:Destroy()
			table.remove(props, index)
		end
	end
end

local function stepScreen(dt)
	-- Inside a cloud: the deeper in, the greyer and blurrier.
	local inside = 0
	local eye = camera.CFrame.Position
	for _, cloud in ipairs(ExplosiveFx.Clouds) do
		local depth = cloud.radius - (eye - cloud.position).Magnitude
		if depth > 0 then
			inside = math.max(inside, math.clamp(depth / 5, 0, 1) * cloud.density)
		end
	end
	screen.grey.BackgroundTransparency = 1 - 0.93 * inside
	screen.blur.Size = 30 * inside
	screen.blur.Enabled = inside > 0.01

	-- The blast flash.
	local flashNow = tick()
	if flashNow < flashUntil then
		screen.flash.BackgroundTransparency = 1 - flashStrength * ((flashUntil - flashNow) / 0.3)
	else
		screen.flash.BackgroundTransparency = 1
		flashStrength = 0
	end

	-- The fuse bar, and the tick each second.
	if cook then
		local elapsed = os.clock() - cook.startedAt
		local left = math.clamp(1 - elapsed / cook.spec.fuse, 0, 1)
		screen.fuseFill.Size = UDim2.fromScale(left, 1)
		screen.fuseFill.BackgroundColor3 = cook.item.color:Lerp(Color3.fromRGB(255, 50, 40), 1 - left)
		screen.fuseLabel.Text = left < 0.3 and "THROW IT" or "COOKING"
		if elapsed >= cook.ticks + 1 then
			cook.ticks += 1
			Sfx.Play("CoconutCook", nil, 1 + cook.ticks * 0.18)
		end
		-- The crack on the coconut in your hands (CombatClient's first-person item) burns hotter
		-- as the fuse runs down, flickering fast in the last second.
		local held = camera:FindFirstChild("BRR_ItemViewmodel")
		if held then
			local remaining = cook.spec.fuse - elapsed
			local rate = remaining < 1 and 26 or (remaining < 2 and 12 or 6)
			local pulse = 0.5 + 0.5 * math.sin(os.clock() * rate)
			local heat = math.clamp(pulse * (1.25 - left), 0, 1)
			local color = cook.item.color:Lerp(Color3.fromRGB(255, 250, 220), heat)
			for _, part in ipairs(held:GetDescendants()) do
				if part.Name == "Glow" and part:IsA("BasePart") then
					part.Color = color
				end
			end
		end
		if elapsed >= cook.spec.fuse then
			-- Too late: the server sets it off in our hand.
			stopCook()
		elseif not inCombat() or driving() then
			cancelCook()
		elseif not cook.touch and not throwHeld() then
			throwNow()
		end
	end
end

RunService.RenderStepped:Connect(function(dt)
	dt = math.min(dt, 0.1)
	local now = serverNow()
	stepFlying(dt, now)
	refreshCookButton()
	preview.update()
	danger.update()
	stepScreen(dt)
end)

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

fx.OnClientEvent:Connect(function(action, info)
	if type(info) ~= "table" then
		if action == "clear" then
			clearAll()
		end
		return
	end
	if action == "round" then
		onRound(info)
	elseif action == "throw" then
		onThrow(info)
	elseif action == "state" then
		onState(info)
	elseif action == "stuck" then
		onStuck(info)
	elseif action == "detonate" then
		onDetonate(info)
	elseif action == "impact" then
		onImpact(info)
	elseif action == "smoke" then
		onSmoke(info)
	elseif action == "remove" then
		onRemove(info)
	elseif action == "cook" then
		onCook(info)
	elseif action == "clear" then
		clearAll()
	end
end)

loadoutChanged.OnClientEvent:Connect(function(newLoadout)
	loadout = newLoadout
	throwGate.LoadoutArrived()
	if newLoadout and newLoadout.equipReadyIn then
		newLoadout.equipReadyAt = os.clock() + newLoadout.equipReadyIn
	end
	-- Swapping away from the frag puts the pin back (the server drops the cook too).
	if cook then
		local slot = newLoadout and newLoadout.equipped and newLoadout.slots[newLoadout.equipped]
		if not slot or newLoadout.equipped ~= cook.index or slot.id ~= cook.slot.id then
			stopCook()
		end
	end
end)

matchChanged.OnClientEvent:Connect(function(state)
	if type(state) == "table" and type(state.state) == "string" then
		matchState = state.state
		if matchState ~= "InProgress" then
			cancelCook()
			preview.hide()
		end
	end
end)

player:GetAttributeChangedSignal("MenuOpen"):Connect(function()
	if player:GetAttribute("MenuOpen") then
		cancelCook()
	end
end)
