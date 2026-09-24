-- A live preview of any cosmetic, built from the same modules that put it on a player.
--
--   local handle = CosmeticPreview.Fill(frame, "CrownOfRot")   -- fills the frame you hand it
--   handle:Destroy()                                           -- or CosmeticPreview.Release(frame)
--
-- The caller owns layout: Fill reads the frame it is given and sizes itself to it, at 72 px or 102 px
-- or larger, and re-frames if that frame changes size. Nothing is positioned here.
--
-- What each kind shows:
--   Accessory  the real pieces, through Shared/CosmeticBuild, so it is the geometry a wearer gets
--   Parachute  the canopy, through Shared/ParachuteModels, the same build the drop-in opens
--   GunSkin    a pistol wearing the skin's colour and material, since a skin recolours any gun
--   Aura       an orb of the aura's colour with specks drifting round it, because a ViewportFrame
--              renders neither particles nor lights, and an aura is both
--   KillAnimation (a death effect) the real effect, LOOPING on a stand-in body: the same design from
--              Shared/DeathEffectDesigns the game plays, on the same engine (DeathEffectFx) in its
--              preview mode, where particles become little neon sparks and lights are left to the
--              flash parts. Model() gives it frozen at its peak; Fill() plays it. A row preview steps
--              twelve times a second and not at all while scrolled out of sight; the Death Effects
--              stage (`options.stage`) steps every frame and can play its sounds (`options.sound`) on
--              the first loop after a PREVIEW press
--
-- Two costs are managed here. Designs are built once and cloned after, and a preview does not build
-- until its frame has been laid out -- at most one build per frame, so opening a page of twenty rows
-- spreads the work rather than hitching on the first draw.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))

local CosmeticPreview = {}

-- The design modules are loaded the first time a preview of that kind is asked for, not on require:
-- a page showing only accessories should not pay for the gun builder. A module that fails to load
-- costs its own kind its preview, not the page.
local loaded = {}
local function soft(name)
	if loaded[name] == nil then
		local ok, module = pcall(require, Shared:WaitForChild(name))
		if not ok then
			warn(string.format("[CosmeticPreview] %s previews are off: %s", name, tostring(module)))
		end
		loaded[name] = ok and module or false
	end
	return loaded[name] or nil
end

-- Compact, reads at 72 px, and a pistol is what a new player is holding anyway.
local SKIN_GUN = { "SahurPistol", "RotSMG" }

local FIELD_OF_VIEW = 32

--------------------------------------------------------------------------------
-- Building the models
--------------------------------------------------------------------------------

local function anchor(model)
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	return model
end

-- A ViewportFrame draws no particles and no light, so an aura is previewed as an orb with specks
-- around it. When a design declares `aura.layers`, the first layer picks the speck count, size and
-- direction, so a sinking cloud of heavy puffs does not preview identically to a fast spit of
-- needles. An aura with no layers gets exactly what it got before: seven specks of 0.22.
local function auraLook(item)
	local layer = item.aura and item.aura.layers and item.aura.layers[1]
	if not layer then
		return { count = 7, size = 0.22, rise = 1, spin = 0.9, color = item.color }
	end
	local speed = layer.speed and layer.speed[2] or 3
	return {
		count = math.clamp(math.floor((layer.rate or 14) / 3), 4, 12),
		size = math.clamp((layer.size or 0.55) * 0.4, 0.1, 0.4),
		rise = (layer.rise or 2.5) >= 0 and 1 or -1,
		spin = math.clamp(speed / 3, 0.4, 2.4),
		color = layer.color or item.color,
	}
end

local function auraModel(item)
	local look = auraLook(item)
	local model = Instance.new("Model")
	model.Name = "Aura"

	local orb = Instance.new("Part")
	orb.Name = "Orb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(1.5, 1.5, 1.5)
	orb.CFrame = CFrame.new()
	orb.Color = item.color
	orb.Material = Enum.Material.Neon
	orb.Transparency = 0.25
	orb.Parent = model

	-- The specks the emitter would throw, as parts, since a ViewportFrame draws no particles. They are
	-- moved by the turn loop, which is also the only thing that makes an aura read as an aura. They
	-- start spread around the orb rather than stacked at one point, so a still of one -- a crate
	-- reveal's first frame, a render -- looks like an aura too.
	local SPECKS = look.count
	for index = 1, SPECKS do
		local speck = Instance.new("Part")
		speck.Name = "Speck" .. index
		speck.Shape = Enum.PartType.Ball
		speck.Size = Vector3.new(look.size, look.size, look.size)
		speck.Color = look.color
		speck.Material = Enum.Material.Neon
		speck.Transparency = 0.15
		local spin = index / SPECKS * math.pi * 2
		local rise = (index - 1) / SPECKS
		speck.CFrame = CFrame.new(math.cos(spin) * (0.95 - rise * 0.25), rise * 1.5 - 0.75, math.sin(spin) * (0.95 - rise * 0.25))
		speck.Parent = model
	end

	return anchor(model)
end

local function gunModel(item)
	local GunModels, WeaponData = soft("GunModels"), soft("WeaponData")
	if not (GunModels and WeaponData) then
		return nil
	end
	for _, id in ipairs(SKIN_GUN) do
		local def = WeaponData.Get(id)
		if def then
			-- detail = "world" skips the micro detail: it is a 72 px thumbnail, and the parts it drops
			-- are the ones too small to see at that size anyway.
			local ok, model = pcall(GunModels.Build, def, item.color, item.material or Enum.Material.SmoothPlastic,
				{ skinned = true, detail = "world" })
			if ok and model then
				model:PivotTo(CFrame.Angles(0, math.rad(-90), 0) * CFrame.Angles(math.rad(-8), 0, 0))
				return anchor(model)
			end
		end
	end
	return nil
end

-- Death effects: a pause with the body back on its feet between loops, and how often a row steps.
local DEATH_REST = 0.7
local ROW_STEP = 1 / 12

-- A stand-in body with death effect `id` built on it, stepped to `t`. Returns the model (the body and
-- the effect's folder) and the effect, or nil. `sound` is passed to the effect.
local function deathScene(id, t, sound)
	local DeathEffectFx, Designs = soft("DeathEffectFx"), soft("DeathEffectDesigns")
	local design = Designs and Designs.Get(id)
	if not (DeathEffectFx and design) then
		return nil
	end
	local model = Instance.new("Model")
	model.Name = "DeathEffect"
	local dummy = DeathEffectFx.Dummy()
	dummy.Parent = model
	local fx = DeathEffectFx.new({
		parent = model,
		origin = DeathEffectFx.DummyRoot,
		ground = Vector3.zero,
		life = design.life,
		body = dummy,
		ownsBody = true,
		preview = true,
		seed = 7,
		sound = sound,
	})
	local ok, err = pcall(function()
		design.build(fx)
		fx:step(t or 0)
	end)
	if not ok then
		warn(string.format("[CosmeticPreview] %s failed to build: %s", tostring(id), tostring(err)))
		model:Destroy()
		return nil
	end
	return model, fx, design
end

local BUILDERS = {
	Accessory = function(id, item)
		local CosmeticBuild = soft("CosmeticBuild")
		if not CosmeticBuild then
			return nil
		end
		return anchor((CosmeticBuild.Model(item, CFrame.new(), 1, id)))
	end,
	Parachute = function(id)
		local ParachuteModels = soft("ParachuteModels")
		if not ParachuteModels then
			return nil
		end
		local ok, model = pcall(ParachuteModels.Build, id, { scale = ParachuteModels.WornScale })
		if not ok or not model then
			return nil
		end
		return anchor(model)
	end,
	GunSkin = function(_, item)
		return gunModel(item)
	end,
	Aura = function(_, item)
		return auraModel(item)
	end,
	-- Frozen at its peak (the burst): a still of the moment it is sold on.
	KillAnimation = function(id)
		local DeathEffectFx, Designs = soft("DeathEffectFx"), soft("DeathEffectDesigns")
		local design = DeathEffectFx and Designs and Designs.Get(id)
		if not design then
			return nil
		end
		return (deathScene(id, design.peak))
	end,
}

local templates = {}

-- The design itself, built once per id and kept. Auras are never cached: each one animates its own
-- specks, and a clone would share nothing but trouble.
local function templateFor(id)
	local item = CosmeticData.Get(id)
	if not item then
		return nil, nil
	end
	local builder = BUILDERS[item.kind]
	if not builder then
		return nil, item
	end
	if item.kind == "Aura" then
		return builder(id, item), item
	end
	local template = templates[id]
	if template == nil then
		local ok, built = pcall(builder, id, item)
		if not ok then
			warn(string.format("[CosmeticPreview] %s failed to build: %s", tostring(id), tostring(built)))
		end
		template = (ok and built) or false
		templates[id] = template
	end
	return template or nil, item
end

-- A fresh model of `id`, for callers placing it themselves (a crate reveal, a podium). Theirs to
-- parent, move and destroy.
function CosmeticPreview.Model(id)
	local template, item = templateFor(id)
	if not template then
		return nil
	end
	-- An aura is built fresh each time, so it is already the caller's; everything else is the kept
	-- template and must be cloned.
	return item.kind == "Aura" and template or template:Clone()
end

--------------------------------------------------------------------------------
-- Filling a frame
--------------------------------------------------------------------------------

local live = {}
local byFrame = {}
local connection
local swingClock = 0

-- Far enough back that the whole model stays in frame through the turn: the bounding sphere, rather
-- than the box, because the box's width changes as it rotates and the sphere's does not.
local function frameCamera(preview)
	local model = preview.model
	if not model then
		return
	end
	local box, size = model:GetBoundingBox()
	local aspect = preview.viewport.AbsoluteSize.X / math.max(preview.viewport.AbsoluteSize.Y, 1)
	local radius = size.Magnitude / 2
	local half = math.tan(math.rad(FIELD_OF_VIEW / 2))
	local distance = radius / (half * math.min(1, aspect)) * 1.06
	-- The turn orbits this point, not the world origin: a back-anchored item is authored a third of a
	-- stud off centre, and orbiting the origin would swing it across the frame instead of turning it.
	preview.pivot = box.Position
	preview.base = CFrame.lookAt(box.Position + Vector3.new(0, radius * 0.35, -distance), box.Position)
	preview.camera.CFrame = preview.base
end

-- The camera for a death effect: the design's own `view` (a focus and a radius the whole effect fits
-- in), because the effect's bounding box changes every frame. A row is cropped tighter, so the body
-- reads at 72 px; the stage shows all of it.
local function frameDeath(preview)
	local view = preview.death.design.view or { focus = Vector3.new(0, 3.5, 0), radius = 8 }
	local aspect = preview.viewport.AbsoluteSize.X / math.max(preview.viewport.AbsoluteSize.Y, 1)
	local radius = view.radius * (preview.stage and 1 or 0.7)
	local half = math.tan(math.rad(FIELD_OF_VIEW / 2))
	local distance = radius / (half * math.min(1, aspect)) * 1.05
	preview.pivot = view.focus
	preview.base = CFrame.lookAt(view.focus + Vector3.new(0.45, 0.28, -0.85).Unit * distance, view.focus)
	preview.camera.CFrame = preview.base
end

-- (Re)starts a death effect's loop at `t`. The first loop after Fill may carry sound; later ones don't.
local function startDeath(preview, t)
	local death = preview.death
	if death and death.model then
		death.fx:destroy()
		death.model:Destroy()
	end
	local sound = nil
	if preview.sound and not preview.soundPlayed then
		preview.soundPlayed = true
		local play = preview.sound
		sound = function(cue, _, jitter)
			play(cue, jitter)
		end
	end
	local model, fx, design = deathScene(preview.id, t, sound)
	if not model then
		preview.death = nil
		return
	end
	model.Parent = preview.viewport
	preview.model = model
	preview.death = { model = model, fx = fx, design = design, t = t, acc = 0 }
end

-- Whether a frame is inside the window of the scrolling list it's in (rows scrolled away don't step).
local function onScreen(viewport)
	local list = viewport:FindFirstAncestorWhichIsA("ScrollingFrame")
	if not list then
		return true
	end
	local a, b = viewport.AbsolutePosition, list.AbsolutePosition
	local aSize, bSize = viewport.AbsoluteSize, list.AbsoluteSize
	return a.Y + aSize.Y > b.Y and a.Y < b.Y + bSize.Y and a.X + aSize.X > b.X and a.X < b.X + bSize.X
end

local function stepDeath(entry, dt)
	local death = entry.death
	if not death then
		return
	end
	death.acc += dt
	if not entry.stage and (death.acc < ROW_STEP or not onScreen(entry.viewport)) then
		return
	end
	death.t += death.acc
	death.acc = 0
	local life = death.design.life
	if death.t >= life + DEATH_REST then
		startDeath(entry, 0)
	elseif death.t >= life then
		if not death.rested then
			-- The effect is over: take it down, which puts the body back on its feet for the pause.
			death.rested = true
			death.fx:destroy()
		end
	else
		local ok, err = pcall(death.fx.step, death.fx, death.t)
		if not ok then
			warn(string.format("[CosmeticPreview] %s: %s", tostring(entry.id), tostring(err)))
			entry.death = nil
		end
	end
end

local function build(preview)
	local item = CosmeticData.Get(preview.id)
	if item and item.kind == "KillAnimation" then
		preview.built = true
		preview.specks = {}
		-- A row opens on the effect's peak so a page of them isn't a page of people standing still;
		-- the stage starts from the top, so the PREVIEW press plays it through.
		local design = soft("DeathEffectDesigns") and soft("DeathEffectDesigns").Get(preview.id)
		startDeath(preview, (not preview.stage and design) and design.peak or 0)
		if preview.death then
			frameDeath(preview)
		end
		return
	end
	local template
	template, item = templateFor(preview.id)
	preview.built = true
	if not template then
		return
	end
	local model = item.kind == "Aura" and template or template:Clone()
	model.Parent = preview.viewport
	preview.model = model
	preview.specks = {}
	if item.kind == "Aura" then
		preview.look = auraLook(item)
		for _, part in ipairs(model:GetChildren()) do
			if part.Name:match("^Speck") then
				table.insert(preview.specks, part)
			end
		end
	end
	frameCamera(preview)
end

-- Fills `frame` with a preview of the cosmetic `id`. Returns a handle with :Destroy(); the preview
-- also tears itself down if the frame leaves the tree, so a page that rebuilds its rows leaks nothing.
-- `options.background` sets the backdrop colour, `options.turn` how far it swings (0 for still).
-- Death effects only: `options.stage` steps every frame rather than twelve times a second, and
-- `options.sound(cue, pitchJitter)` plays the first loop's sounds.
function CosmeticPreview.Fill(frame, id, options)
	options = options or {}
	CosmeticPreview.Release(frame)

	local viewport = Instance.new("ViewportFrame")
	viewport.Name = "CosmeticPreview"
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundColor3 = options.background or Color3.fromRGB(28, 30, 38)
	viewport.BackgroundTransparency = options.backgroundTransparency or 0
	viewport.BorderSizePixel = 0
	viewport.Ambient = Color3.fromRGB(170, 170, 182)
	viewport.LightColor = Color3.fromRGB(255, 250, 240)
	viewport.LightDirection = Vector3.new(-0.4, -1, 0.6)
	viewport.ZIndex = frame.ZIndex

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	viewport.Parent = frame

	local preview = {
		id = id,
		frame = frame,
		viewport = viewport,
		camera = camera,
		turn = options.turn or 0.55,
		phase = #live * 0.9,
		stage = options.stage == true,
		sound = options.sound,
		base = CFrame.new(),
		built = false,
		size = Vector2.new(),
	}

	function preview:Destroy()
		for index = #live, 1, -1 do
			if live[index] == self then
				table.remove(live, index)
			end
		end
		if byFrame[self.frame] == self then
			byFrame[self.frame] = nil
		end
		if self.death then
			self.death.fx:destroy()
			self.death = nil
		end
		if self.viewport then
			self.viewport:Destroy()
			self.viewport = nil
		end
	end

	frame.AncestryChanged:Connect(function()
		if not frame:IsDescendantOf(game) then
			preview:Destroy()
		end
	end)

	table.insert(live, preview)
	byFrame[frame] = preview

	if not connection then
		connection = RunService.Heartbeat:Connect(function(dt)
			-- The swing's clock: frame time added up, not os.clock (CPU time in Roblox).
			swingClock += dt
			local now = swingClock
			local builtOne = false
			for index = #live, 1, -1 do
				local entry = live[index]
				if not entry.viewport or not entry.viewport:IsDescendantOf(game) then
					entry:Destroy()
				else
					local size = entry.viewport.AbsoluteSize
					if size.X > 0 and size.Y > 0 then
						-- One build per frame: twenty rows of real parts all at once is a visible hitch.
						if not entry.built and not builtOne then
							builtOne = true
							build(entry)
						elseif entry.built and (size - entry.size).Magnitude > 0.5 then
							if entry.death then
								frameDeath(entry)
							else
								frameCamera(entry)
							end
						end
						stepDeath(entry, dt)
						entry.size = size

						if entry.model then
							if entry.turn > 0 then
								local swing = math.sin(now * 0.6 + entry.phase) * entry.turn
								local pivot = entry.pivot or Vector3.zero
								entry.camera.CFrame = CFrame.new(pivot) * CFrame.Angles(0, swing, 0) * CFrame.new(-pivot) * entry.base
							end
							local look = entry.look
							for n, speck in ipairs(entry.specks) do
								local spin = now * (look and look.spin or 0.9) + n * (math.pi * 2 / #entry.specks)
								local rise = ((now * 0.35 + n * 0.17) % 1)
								if look and look.rise < 0 then
									rise = 1 - rise
								end
								local radius = 0.95 - rise * 0.25
								speck.CFrame = CFrame.new(math.cos(spin) * radius, rise * 1.5 - 0.75, math.sin(spin) * radius)
								speck.Transparency = 0.15 + rise * 0.7
							end
						end
					end
				end
			end
		end)
	end

	return preview
end

-- Tears down whatever Fill put in `frame`.
function CosmeticPreview.Release(frame)
	local preview = byFrame[frame]
	if preview then
		preview:Destroy()
	end
end

return CosmeticPreview
