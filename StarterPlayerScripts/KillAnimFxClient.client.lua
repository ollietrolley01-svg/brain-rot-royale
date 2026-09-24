-- The client half of KillAnimService (#24): the kill animation a player has equipped, played where
-- their victim fell. The server sends { id, position }; everything here is local-only parts that
-- nobody else can see or touch, and every one is gone within MAX_LIFETIME.
--
-- Budgets, because a grenade can drop five bodies in one frame and every client builds every
-- animation it's near enough to see:
--   * at most MAX_LIVE animations at once; one past that is skipped, not queued
--   * at most MAX_PARTS parts and MAX_PARTICLES particles each (ctx:part / ctx:burst refuse past it)
--   * nothing further than CULL_DISTANCE studs from the camera is built at all
--   * each animation is torn down whole after its `life`, which is never over MAX_LIFETIME
-- tools/killanim_check.py runs this file against every CosmeticData kill animation and checks all
-- four, and that no tween or delay is still running when the folder is destroyed.
--
-- Cylinders run along their X axis, so every upright one here is turned a quarter about Z.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local killAnimFx = Remotes.Event("KillAnimFx")

local MAX_LIVE = 4
local MAX_PARTS = 24
local MAX_PARTICLES = 40
local MAX_LIFETIME = 3
local CULL_DISTANCE = 260

-- How far below the body's root the ground usually is (root half-height plus hip height), used
-- when the ray down finds nothing but bodies.
local ROOT_TO_GROUND = 3

local V = Vector3.new
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)
local FLAT = UPRIGHT -- a flat disc is the same quarter turn: the cylinder's X axis points up
local CYLINDER = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic
local WOOD = Enum.Material.Wood

local live = 0

--------------------------------------------------------------------------------
-- One animation's budget and its folder
--------------------------------------------------------------------------------

local Ctx = {}
Ctx.__index = Ctx

local function newCtx(position, ground)
	local folder = Instance.new("Folder")
	folder.Name = "KillAnimFx"
	folder.Parent = workspace
	return setmetatable({ folder = folder, parts = 0, particles = 0, alive = true, position = position, ground = ground }, Ctx)
end

-- An anchored, untouchable part, or nil once the budget is spent (every caller copes with nil).
function Ctx:part(size, cframe, color, material, shape, transparency)
	if not self.alive or self.parts >= MAX_PARTS then
		return nil
	end
	self.parts += 1
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or SMOOTH
	part.Transparency = transparency or 0
	part.Parent = self.folder
	return part
end

function Ctx:tween(instance, seconds, goal, style, direction)
	if not instance or not self.alive then
		return
	end
	local info = TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	TweenService:Create(instance, info, goal):Play()
end

-- Calls `step(alpha)` as alpha runs 0 to 1 over `seconds`, for pieces that have to move together
-- (two parts tweened separately drift apart mid-turn, since each lerps its own position).
function Ctx:drive(seconds, step)
	if not self.alive then
		return
	end
	local value = Instance.new("NumberValue")
	value.Value = 0
	value.Parent = self.folder
	step(0)
	value.Changed:Connect(function(alpha)
		if self.alive then
			step(alpha)
		end
	end)
	self:tween(value, seconds, { Value = 1 }, Enum.EasingStyle.Linear)
end

function Ctx:after(seconds, fn)
	task.delay(seconds, function()
		if self.alive then
			fn()
		end
	end)
end

-- A one-off burst of particles from `at`. Costs one (invisible) part and `count` particles, cut
-- down to what's left of the budget.
function Ctx:burst(at, color, count, speed, size, lifetime)
	count = math.min(count, MAX_PARTICLES - self.particles)
	if count <= 0 then
		return
	end
	local anchor = self:part(V(0.2, 0.2, 0.2), CFrame.new(at), color, SMOOTH, nil, 1)
	if not anchor then
		return
	end
	self.particles += count
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.4
	emitter.Size = NumberSequence.new(size or 0.5, 0)
	emitter.Transparency = NumberSequence.new(0, 1)
	emitter.Lifetime = NumberRange.new(0.4, math.min(lifetime or 1, 1.5))
	emitter.Speed = NumberRange.new((speed or 12) * 0.5, speed or 12)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = V(0, -20, 0)
	emitter.Parent = anchor
	emitter:Emit(count)
end

function Ctx:fade(part, delay, seconds)
	self:after(delay, function()
		self:tween(part, seconds, { Transparency = 1 })
	end)
end

--------------------------------------------------------------------------------
-- The animations, keyed by CosmeticData id
--------------------------------------------------------------------------------

local CONFETTI = {
	Color3.fromRGB(255, 120, 190), Color3.fromRGB(70, 214, 236), Color3.fromRGB(255, 214, 64),
	Color3.fromRGB(80, 220, 120), Color3.fromRGB(150, 80, 240), Color3.fromRGB(255, 132, 36),
}
local GOO = Color3.fromRGB(150, 196, 96)
local GOO_DARK = Color3.fromRGB(96, 140, 56)
local BAT = Color3.fromRGB(168, 122, 72)
local GRIP = Color3.fromRGB(60, 40, 30)
local STAR = Color3.fromRGB(255, 214, 64)
local DUST = Color3.fromRGB(200, 186, 160)
local GHOST = Color3.fromRGB(214, 236, 255)
local EYE = Color3.fromRGB(24, 24, 28)
local DRUM = Color3.fromRGB(206, 150, 80)
local RIM = Color3.fromRGB(206, 48, 48)
local STAMP = Color3.fromRGB(255, 132, 36)
local GOLD = Color3.fromRGB(255, 196, 64)
local BRAIN = Color3.fromRGB(255, 150, 176)
local BRAIN_DARK = Color3.fromRGB(206, 92, 124)

local EFFECTS = {
	-- A popper tube kicks up and a dozen streamers fly out and flutter down.
	KillConfettiPop = {
		life = 2,
		cue = "Confetti",
		build = function(ctx)
			local base = ctx.ground + V(0, 0.8, 0)
			local tube = ctx:part(V(1.6, 0.9, 0.9), CFrame.new(base) * UPRIGHT, CONFETTI[1], SMOOTH, CYLINDER)
			ctx:tween(tube, 0.15, { Size = V(2.2, 1.3, 1.3) }, Enum.EasingStyle.Back)
			ctx:fade(tube, 1.2, 0.6)
			for index = 1, 12 do
				local angle = index / 12 * math.pi * 2
				local out = V(math.cos(angle), 0, math.sin(angle)) * (3 + (index % 3))
				local piece = ctx:part(V(0.5, 0.08, 0.3), CFrame.new(base + V(0, 1, 0)), CONFETTI[index % #CONFETTI + 1], NEON)
				ctx:tween(piece, 0.45, { CFrame = CFrame.new(base + out + V(0, 5 + (index % 4), 0)) * CFrame.Angles(index, index * 2, 0) })
				ctx:after(0.45, function()
					ctx:tween(piece, 1.1, { CFrame = CFrame.new(base + out * 1.3 + V(0, 0.2, 0)) * CFrame.Angles(index * 3, 0, index), Transparency = 1 }, Enum.EasingStyle.Sine, Enum.EasingDirection.In)
				end)
			end
			ctx:burst(base + V(0, 1.5, 0), CONFETTI[3], 24, 18, 0.4, 1.2)
		end,
	},

	-- A green puddle spreads where they stood and a few bubbles rise and pop.
	KillRotPuddle = {
		life = 2.6,
		cue = "StickySquelch",
		build = function(ctx)
			local puddle = ctx:part(V(0.15, 1, 1), CFrame.new(ctx.ground + V(0, 0.08, 0)) * FLAT, GOO, SMOOTH, CYLINDER, 0.1)
			ctx:tween(puddle, 0.6, { Size = V(0.15, 7, 7) }, Enum.EasingStyle.Back)
			ctx:fade(puddle, 1.8, 0.7)
			for index = 1, 5 do
				local angle = index * 2.4
				local at = ctx.ground + V(math.cos(angle) * (index % 3 + 0.6), 0.3, math.sin(angle) * (index % 3 + 0.6))
				local bubble = ctx:part(V(0.4, 0.4, 0.4), CFrame.new(at), index % 2 == 0 and GOO or GOO_DARK, SMOOTH, BALL, 0.2)
				local start = 0.2 + index * 0.22
				ctx:after(start, function()
					ctx:tween(bubble, 0.5, { Size = V(1.3, 1.3, 1.3), CFrame = CFrame.new(at + V(0, 1.4, 0)) }, Enum.EasingStyle.Sine)
				end)
				ctx:fade(bubble, start + 0.5, 0.1)
			end
			ctx:burst(ctx.ground + V(0, 0.5, 0), GOO, 18, 8, 0.35, 0.8)
		end,
	},

	-- A bat as long as a lamppost swings down from upright onto the spot, then stars circle it.
	KillBigBonk = {
		life = 1.8,
		cue = "BreakWood",
		build = function(ctx)
			local LENGTH = 14
			local hinge = CFrame.new(ctx.ground) * CFrame.Angles(0, math.random() * math.pi * 2, 0) * CFrame.new(-LENGTH, 1.2, 0)
			-- Along the bat: distance from the hinge, piece, and the piece's own turn.
			local pieces = {
				{ 0, ctx:part(V(1.4, 1.4, 1.4), hinge, GRIP, SMOOTH, BALL) },
				{ 2.5, ctx:part(V(5, 0.9, 0.9), hinge, GRIP, SMOOTH, CYLINDER) },
				{ 9.5, ctx:part(V(9, 2.4, 2.4), hinge, BAT, WOOD, CYLINDER) },
			}
			ctx:drive(0.28, function(alpha)
				-- Upright to flat, accelerating like a swing. Turning -theta about Z takes +Y to +X.
				local bat = hinge * CFrame.Angles(0, 0, -alpha * alpha * math.pi / 2)
				for _, piece in ipairs(pieces) do
					if piece[2] then
						piece[2].CFrame = bat * CFrame.new(0, piece[1], 0) * UPRIGHT
					end
				end
			end)
			ctx:after(0.28, function()
				ctx:burst(ctx.ground + V(0, 0.6, 0), DUST, 24, 14, 0.8, 0.9)
				for index = 1, 5 do
					local star = ctx:part(V(0.7, 0.7, 0.2), CFrame.new(ctx.ground + V(0, 3.5, 0)), STAR, NEON)
					ctx:drive(1.1, function(alpha)
						if star then
							local angle = index / 5 * math.pi * 2 + alpha * math.pi * 3
							star.CFrame = CFrame.new(ctx.ground + V(math.cos(angle) * 2, 3.5, math.sin(angle) * 2)) * CFrame.Angles(0, -angle, math.pi / 4)
						end
					end)
					ctx:fade(star, 0.8, 0.3)
				end
			end)
			for _, piece in ipairs(pieces) do
				ctx:fade(piece[2], 1.1, 0.4)
			end
		end,
	},

	-- A little ghost floats up out of the body, bobbing side to side, and fades.
	KillRotGhost = {
		life = 2.6,
		cue = "FloatAway",
		build = function(ctx)
			local start = ctx.position
			local shape = {
				{ V(0, 0, 0), V(2.6, 2.6, 2.6), GHOST, BALL },
				{ V(0, -1.3, 0), V(2.1, 2.1, 2.1), GHOST, BALL },
				{ V(0.2, -2.2, 0), V(1.4, 1.4, 1.4), GHOST, BALL },
				{ V(0.5, -2.9, 0), V(0.8, 0.8, 0.8), GHOST, BALL },
				{ V(-0.45, 0.3, -1.12), V(0.45, 0.6, 0.2), EYE, nil },
				{ V(0.45, 0.3, -1.12), V(0.45, 0.6, 0.2), EYE, nil },
			}
			local built = {}
			for _, piece in ipairs(shape) do
				local part = ctx:part(piece[2], CFrame.new(start + piece[1]), piece[3], piece[4] and NEON or SMOOTH, piece[4], piece[4] and 0.35 or 0)
				table.insert(built, { part, piece[1] })
				ctx:fade(part, 1.7, 0.7)
			end
			ctx:drive(2.4, function(alpha)
				local centre = CFrame.new(start + V(math.sin(alpha * math.pi * 4) * 0.8, 1 + alpha * 9, 0)) * CFrame.Angles(0, 0, math.sin(alpha * math.pi * 4) * 0.2)
				for _, piece in ipairs(built) do
					if piece[1] then
						piece[1].CFrame = centre * CFrame.new(piece[2])
					end
				end
			end)
			ctx:burst(start, GHOST, 16, 5, 0.4, 1.2)
		end,
	},

	-- A war drum drops out of the sky spinning, slams down, and leaves a glowing ring.
	KillDrumStamp = {
		life = 2.3,
		cue = "BodyFall",
		build = function(ctx)
			local ground = ctx.ground
			local pieces = {
				{ 0, ctx:part(V(3.4, 5, 5), CFrame.new(ground), DRUM, WOOD, CYLINDER) },
				{ 1.6, ctx:part(V(0.4, 5.3, 5.3), CFrame.new(ground), RIM, SMOOTH, CYLINDER) },
				{ -1.6, ctx:part(V(0.4, 5.3, 5.3), CFrame.new(ground), RIM, SMOOTH, CYLINDER) },
			}
			ctx:drive(0.35, function(alpha)
				local centre = CFrame.new(ground + V(0, 1.9 + (1 - alpha * alpha) * 16, 0)) * CFrame.Angles(0, alpha * math.pi * 3, 0)
				for _, piece in ipairs(pieces) do
					if piece[2] then
						piece[2].CFrame = centre * CFrame.new(0, piece[1], 0) * UPRIGHT
					end
				end
			end)
			ctx:after(0.35, function()
				ctx:burst(ground + V(0, 0.4, 0), DUST, 24, 16, 0.9, 0.8)
				for index = 1, 10 do
					local angle = index / 10 * math.pi * 2
					local tile = ctx:part(V(1.7, 0.12, 0.7), CFrame.new(ground + V(math.cos(angle) * 3.6, 0.06, math.sin(angle) * 3.6)) * CFrame.Angles(0, -angle, 0), STAMP, NEON)
					ctx:fade(tile, 0.9, 0.9)
				end
			end)
			for _, piece in ipairs(pieces) do
				ctx:fade(piece[2], 1.3, 0.6)
			end
		end,
	},

	-- A fountain of spinning coins arcs up and out and rains back down.
	KillCoinFountain = {
		life = 2.4,
		cue = "GoldCrumble",
		build = function(ctx)
			local base = ctx.ground + V(0, 1, 0)
			local coins = {}
			for index = 1, 14 do
				local angle = index * 2.4
				local spread = 3 + (index % 4)
				local coin = ctx:part(V(0.2, 1.2, 1.2), CFrame.new(base), GOLD, Enum.Material.Foil, CYLINDER)
				table.insert(coins, { coin, V(math.cos(angle) * spread, 14 + (index % 3) * 2, math.sin(angle) * spread), index * 0.03 })
				ctx:fade(coin, 1.8, 0.4)
			end
			ctx:drive(2.1, function(alpha)
				for _, entry in ipairs(coins) do
					if entry[1] then
						local t = math.max(0, alpha * 2.1 - entry[3])
						local height = entry[2].Y * t - 0.5 * 30 * t * t
						entry[1].CFrame = CFrame.new(base + V(entry[2].X * t, math.max(height, -0.6), entry[2].Z * t)) * CFrame.Angles(0, t * 12, 0)
					end
				end
			end)
			ctx:burst(base, GOLD, 20, 10, 0.4, 1)
		end,
	},

	-- A brain swells and wobbles over the body, then pops in a pink shockwave.
	KillBrainBlast = {
		life = 2.2,
		cue = "Vaporize",
		build = function(ctx)
			local centre = ctx.position + V(0, 1.5, 0)
			local lobes = {
				ctx:part(V(1, 1, 1), CFrame.new(centre), BRAIN, SMOOTH, BALL),
				ctx:part(V(1, 1, 1), CFrame.new(centre), BRAIN, SMOOTH, BALL),
			}
			local stem = ctx:part(V(1, 0.4, 0.4), CFrame.new(centre), BRAIN_DARK, SMOOTH, CYLINDER)
			ctx:drive(0.8, function(alpha)
				local size = 1 + alpha * 5
				local wobble = 1 + math.sin(alpha * math.pi * 6) * 0.08
				for side, lobe in ipairs(lobes) do
					if lobe then
						lobe.Size = V(size * 0.62 * wobble, size * 0.72, size)
						lobe.CFrame = CFrame.new(centre + V((side == 1 and -1 or 1) * size * 0.26, 0, 0))
					end
				end
				if stem then
					stem.Size = V(size * 0.5, size * 0.22, size * 0.22)
					stem.CFrame = CFrame.new(centre - V(0, size * 0.45, 0)) * UPRIGHT
				end
			end)
			ctx:after(0.8, function()
				for _, part in pairs({ lobes[1], lobes[2], stem }) do
					part.Transparency = 1
				end
				local ring = ctx:part(V(0.2, 2, 2), CFrame.new(centre) * FLAT, BRAIN, NEON, CYLINDER, 0.2)
				ctx:tween(ring, 0.5, { Size = V(0.2, 22, 22), Transparency = 1 })
				for index = 1, 8 do
					local angle = index / 8 * math.pi * 2
					local chunk = ctx:part(V(0.9, 0.9, 0.9), CFrame.new(centre), index % 2 == 0 and BRAIN or BRAIN_DARK, SMOOTH, BALL)
					ctx:tween(chunk, 0.7, { CFrame = CFrame.new(centre + V(math.cos(angle) * 7, 2 - (index % 3), math.sin(angle) * 7)) })
					ctx:fade(chunk, 0.6, 0.5)
				end
				ctx:burst(centre, BRAIN, 40, 22, 0.6, 1)
			end)
		end,
	},
}

--------------------------------------------------------------------------------
-- Playing one
--------------------------------------------------------------------------------

-- The ground under the body. The ray skips every character; if it still lands on something with
-- a Humanoid (a bot's body), or nothing, assume the usual height.
local function groundUnder(position)
	local skip = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other.Character then
			table.insert(skip, other.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = skip
	local hit = workspace:Raycast(position, V(0, -12, 0), params)
	if hit and not (hit.Instance.Parent and hit.Instance.Parent:FindFirstChildOfClass("Humanoid")) then
		return hit.Position
	end
	return position - V(0, ROOT_TO_GROUND, 0)
end

local function play(id, position)
	local effect = EFFECTS[id]
	if not effect or live >= MAX_LIVE then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - position).Magnitude > CULL_DISTANCE then
		return
	end

	live += 1
	local ctx = newCtx(position, groundUnder(position))
	local life = math.min(effect.life, MAX_LIFETIME)
	task.delay(life, function()
		ctx.alive = false
		ctx.folder:Destroy()
		live -= 1
	end)
	if effect.cue then
		Sfx.PlayAt(effect.cue, position, 0.15)
	end
	local ok, err = pcall(effect.build, ctx)
	if not ok then
		warn("[KillAnimFxClient] " .. id .. ": " .. tostring(err))
	end
end

killAnimFx.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or type(data.id) ~= "string" or typeof(data.position) ~= "Vector3" then
		return
	end
	play(data.id, data.position)
end)
