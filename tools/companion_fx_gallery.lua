-- Companion ability effects gallery (OLIVER_LIST A5, the 2026-09-24 effects pass): every move and
-- every style, each at its wind-up, its action and its impact, drawn by the REAL
-- StarterPlayerScripts/CompanionFxClient.client.lua on real rigged brainrots.
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/companion_fx_gallery.lua -OutDir <folder> -Hold 1 -TimeoutSeconds 900
--
-- Views (17):
--   move_<Kind>      Spit, Bonk, Zap, Chain, Lob, Shockwave, Blast: the plain move (no style) on a
--                    brainrot that has it. Left to right: WIND-UP, ACTION, IMPACT.
--   style_<Style>    Slow, Daze, Burn, Toxic, Leech, Wide, Quick, Long, Fork: the first brainrot that
--                    carries the style, on its own move. WIND-UP, ACTION, IMPACT (the impact a little
--                    later than a move view's, so the style's signature has grown in).
--   rarity_tint      one Zap at the same moment on a Common, an Epic and a Secret brainrot.
--
-- How it runs the client: the source is loaded with loadstring and `__companionFxHarness` set (the
-- client's own seam), so it gets this gallery's clock, frame signals and remotes. Each view is PLAYED
-- in real time -- every frame the client's own step runs, as in the game -- so particles and trails,
-- which Roblox ages in real time whatever this clock says, are the age they would be. At the capture
-- moment the scene is frozen: particle emitters' TimeScale set to 0, trails' lifetimes stretched,
-- and the client stops being stepped. Edit mode solves no joints, so each creature is posed by hand
-- from the pose the client computed (CompanionAnimations.Transforms), exactly as companion_gallery
-- does.
--
-- Notes printed per view: each copy IN FRAME / NOT IN FRAME with an occlusion ray to it (COORDINATION
-- "IN FRAME is not VISIBLE"), and how many effects, particles and lights were live at the capture.
--
-- What to look at: the wind-up reads as a wind-up (squashed, glowing, sparks gathering); the action
-- is the move's own shape (a glob and trail, a bolt, a leap streak, a ring racing out); the impact is
-- sized to the move (a Shockwave's ring IS its damage radius, a Lob's splash its splash); each style
-- is recognisable at a glance from its signature alone; and the tint follows the brainrot's colour
-- with its rarity colour on the rims and sparkles.
--
-- Not shown: the owner's screen-edge pulse (edit mode has no LocalPlayer, and it is screen space),
-- and sound.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local BrainrotData = require(Shared:WaitForChild("BrainrotData"))
local BrainrotModels = require(Shared:WaitForChild("BrainrotModels"))
local CompanionAnimations = require(Shared:WaitForChild("CompanionAnimations"))

local ORIGIN = Vector3.new(6000, 300, -6000)
local W = CompanionAnimations.Windup
-- CompanionService builds companions at this scale (its SCALE).
local COMPANION_SCALE = 0.55
local COMPANION_HEIGHT = 4.5
local TARGET_DISTANCE = 16
-- The server's flight times (CompanionService: LOB_TIME, BONK_TIME, SPIT_SPEED).
local LOB_TIME, BONK_TIME, SPIT_SPEED = 0.7, 0.35, 90

Lighting.ClockTime = 17.5
Lighting.Brightness = 1.6
Lighting.Ambient = Color3.fromRGB(70, 72, 84)
Lighting.OutdoorAmbient = Color3.fromRGB(110, 112, 124)

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

--------------------------------------------------------------------------------
-- The real client, on this gallery's clock
--------------------------------------------------------------------------------

local function fakeSignal()
	local s = { fns = {} }
	function s:Connect(fn)
		table.insert(self.fns, fn)
		return { Disconnect = function() end }
	end
	function s:Fire(...)
		for _, fn in ipairs(self.fns) do
			local ok, err = pcall(fn, ...)
			if not ok then
				note("client error: " .. tostring(err))
			end
		end
	end
	return s
end

local function loadClient(folder, companions, clock)
	local script = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("CompanionFxClient")
	local remotes = {}
	local seam = {
		RunService = { RenderStepped = fakeSignal(), Stepped = fakeSignal(), Heartbeat = fakeSignal() },
		Remotes = {
			Event = function(name)
				remotes[name] = remotes[name] or { OnClientEvent = fakeSignal() }
				return remotes[name]
			end,
		},
		Sfx = { PlayAt = function() end, Play = function() end },
		LocalPlayer = nil,
		companions = companions,
		parent = folder,
		clock = clock,
	}
	local fn, err = loadstring(script.Source, "CompanionFxClient")
	assert(fn, err)
	local env = setmetatable({ script = script, __companionFxHarness = seam }, { __index = getfenv() })
	setfenv(fn, env)
	fn()
	return seam, remotes
end

--------------------------------------------------------------------------------
-- The stage: a floor, rigged companions posed by hand, stand-in targets
--------------------------------------------------------------------------------

local function block(parent, size, cframe, color, material, shape)
	local part = Instance.new("Part")
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material or Enum.Material.SmoothPlastic
	if shape then
		part.Shape = shape
	end
	part.Parent = parent
	return part
end

-- A plain figure standing where a move is aimed: what it hits. Its root is named as a character's is,
-- so a style's cue can cling to it.
local function figure(parent, position, color)
	local model = Instance.new("Model")
	model.Name = "Target"
	local root = block(model, Vector3.new(2, 2, 1), CFrame.new(position), color or Color3.fromRGB(150, 150, 160))
	root.Name = "HumanoidRootPart"
	block(model, Vector3.new(1.3, 1.3, 1.3), CFrame.new(position + Vector3.new(0, 1.7, 0)), Color3.fromRGB(230, 200, 170), nil, Enum.PartType.Ball)
	block(model, Vector3.new(0.8, 2, 0.8), CFrame.new(position + Vector3.new(-0.5, -2, 0)), Color3.fromRGB(70, 80, 110))
	block(model, Vector3.new(0.8, 2, 0.8), CFrame.new(position + Vector3.new(0.5, -2, 0)), Color3.fromRGB(70, 80, 110))
	model.PrimaryPart = root
	-- A Humanoid, as a character has: the client steps past a body to find the floor under it.
	Instance.new("Humanoid").Parent = model
	model.Parent = parent
	return model, root
end

-- Builds a rigged companion the way CompanionService does, then unwelds and anchors it (edit mode
-- solves no joints) while keeping its Motor6Ds for the client's rig; `pose` re-places every part.
local function companion(parent, def, at)
	local model = BrainrotModels.Build(def, { scale = COMPANION_SCALE, anchored = false, rig = true, flair = false, cframe = CFrame.new(at) })
	local root = model.PrimaryPart
	local rest, pivotOf, joints = {}, {}, {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			rest[part] = part.CFrame
			local joint = part:FindFirstChildOfClass("Motor6D")
			if joint then
				joints[part] = { part0 = joint.Part0, c0 = joint.C0, c1 = joint.C1, name = joint.Name }
			end
			local weld = part:FindFirstChildOfClass("WeldConstraint")
			if weld then
				pivotOf[part] = weld.Part0
			end
		end
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("WeldConstraint") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
		end
	end
	model.Parent = parent
	local function pose(p)
		local transforms = CompanionAnimations.Transforms(p)
		local world = { [root] = rest[root] }
		local function solve(pivot)
			if world[pivot] then
				return world[pivot]
			end
			local joint = joints[pivot]
			if not joint then
				return rest[pivot]
			end
			world[pivot] = solve(joint.part0) * joint.c0 * (transforms[joint.name] or CFrame.new()) * joint.c1:Inverse()
			return world[pivot]
		end
		for part, cf in pairs(rest) do
			local pivot = pivotOf[part]
			if pivot then
				part.CFrame = solve(pivot) * rest[pivot]:ToObjectSpace(cf)
			end
		end
		for pivot in pairs(joints) do
			pivot.CFrame = solve(pivot)
		end
	end
	return model, root, pose
end

local function label(parent, position, text)
	local anchor = block(parent, Vector3.new(0.2, 0.2, 0.2), CFrame.new(position), Color3.new(1, 1, 1))
	anchor.Transparency = 1
	-- Out of the frame checks' occlusion rays.
	anchor.CanQuery = false
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 40)
	gui.AlwaysOnTop = true
	gui.Adornee = anchor
	local text_ = Instance.new("TextLabel")
	text_.Size = UDim2.fromScale(1, 1)
	text_.BackgroundTransparency = 1
	text_.TextColor3 = Color3.new(1, 1, 1)
	text_.TextStrokeTransparency = 0.3
	text_.Font = Enum.Font.GothamBold
	text_.TextScaled = true
	text_.Text = text
	text_.Parent = gui
	gui.Parent = anchor
end

local function frameCheck(name, camera, target, folder)
	local point = camera.CFrame:PointToObjectSpace(target)
	local forward = -point.Z
	local off = math.deg(math.atan2(math.sqrt(point.X * point.X + point.Y * point.Y), math.max(forward, 1e-6)))
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {}
	local from = camera.CFrame.Position
	local hit = workspace:Raycast(from, (target - from) * 0.97, params)
	note(string.format("%-26s %s: %.1f studs ahead, %.1f deg off centre (fov %.0f); ray to it hits %s", name,
		(forward > 0 and off < camera.FieldOfView / 2) and "IN FRAME" or "NOT IN FRAME", forward, off, camera.FieldOfView,
		hit and hit.Instance:GetFullName() or "nothing (clear)"))
end

--------------------------------------------------------------------------------
-- Payloads, as CompanionService builds them
--------------------------------------------------------------------------------

local function travelFor(kind, from, to)
	return (kind == "Lob" and LOB_TIME) or (kind == "Bonk" and BONK_TIME) or (to - from).Magnitude / SPIT_SPEED
end

local function payloadFor(def, kind, style, model, from, to, extra)
	local stats = BrainrotData.Stats(def, 1, 0)
	local travel = travelFor(kind == "Blast" and "Spit" or kind, from, to)
	local p = {
		kind = kind == "Blast" and stats.kind or kind,
		style = style,
		companion = model,
		from = from,
		to = to,
		color = stats.color,
		rarity = def.rarity,
		range = stats.range,
		splash = stats.splash,
		windup = W,
		travel = travel,
	}
	p.lands = CompanionAnimations.Travels[kind] and W + travel or W
	if kind == "Blast" then
		p.blast, p.windup, p.lands = true, 0, 0
	end
	for key, value in pairs(extra or {}) do
		p[key] = value
	end
	return p
end

-- The three moments of a move, in seconds from its broadcast.
local function moments(kind, travel, lateImpact)
	local phases = CompanionAnimations.Phases(kind, travel)
	local windup = kind == "Blast" and 0.02 or W * 0.85
	local action
	if kind == "Bonk" or kind == "Lob" then
		action = phases.strike + travel * 0.5
	elseif kind == "Spit" then
		action = phases.strike + math.max(travel * 0.45, 0.05)
	elseif kind == "Blast" then
		action = 0.09
	else
		action = phases.strike + 0.04
	end
	local impact = kind == "Blast" and 0.3 or phases.lands + (lateImpact and 0.3 or 0.1)
	return { { "WIND-UP", windup }, { "ACTION", action }, { "IMPACT", impact } }
end

--------------------------------------------------------------------------------
-- One view: three copies of a move, each caught at its own moment
--------------------------------------------------------------------------------

local function stageView(folder, camera, spec)
	block(folder, Vector3.new(260, 1, 140), CFrame.new(ORIGIN - Vector3.new(0, 0.5, 20)), Color3.fromRGB(96, 112, 88), Enum.Material.Grass)
	local companionsFolder = Instance.new("Folder")
	companionsFolder.Name = "Companions"
	companionsFolder.Parent = folder
	local fxParent = Instance.new("Folder")
	fxParent.Name = "FxParent"
	fxParent.Parent = folder

	local start = tick()
	local function clock()
		return tick() - start
	end
	local seam, remotes = loadClient(fxParent, companionsFolder, clock)
	local api = seam.api

	local radius = spec.kind == "Shockwave" and BrainrotData.Stats(spec.def, 1, 0).range or 8
	local spacing = math.max(28, radius * 2 + 8)
	local copies = {}
	for index = 1, #spec.copies do
		local x = (index - (#spec.copies + 1) / 2) * spacing
		local base = ORIGIN + Vector3.new(x, 0, 0)
		local def = spec.copies[index].def or spec.def
		local model, root, pose = companion(companionsFolder, def, base + Vector3.new(0, COMPANION_HEIGHT, 0))
		local targetAt = base + Vector3.new(0, 3, -TARGET_DISTANCE)
		local target = figure(folder, targetAt)
		local extra = {}
		if spec.kind == "Chain" or spec.kind == "Zap" then
			local forks = (spec.kind == "Chain" and 1 or 0) + (spec.style == "Fork" and 1 or 0)
			if forks >= 1 then
				extra.to2 = targetAt + Vector3.new(7, 0, -6)
				figure(folder, extra.to2)
			end
			if forks >= 2 then
				extra.to3 = targetAt + Vector3.new(-6, 0, -11)
				figure(folder, extra.to3)
			end
		end
		local ownerRoot = nil
		if spec.style == "Leech" then
			local _, r = figure(folder, base + Vector3.new(3, 3, 4), Color3.fromRGB(90, 160, 230))
			ownerRoot = r
		end
		local from = root.Position
		local p = payloadFor(def, spec.kind, spec.style, model, from, targetAt, extra)
		local moment = moments(spec.kind, p.travel, spec.lateImpact)[spec.copies[index].moment or index]
		if spec.copies[index].at then
			moment = { spec.copies[index].at[1], spec.copies[index].at[2] }
		end
		label(folder, base + Vector3.new(0, 10, -6), string.format("%s  %.2fs", moment[1], moment[2]))
		table.insert(copies, { model = model, pose = pose, payload = p, at = moment[2], target = target, targetAt = targetAt, ownerRoot = ownerRoot,
			fired = false, hit = false })
	end

	-- Play it: the copy caught latest starts first, so all three reach their moments together.
	local finish = 0
	for _, copy in ipairs(copies) do
		finish = math.max(finish, copy.at)
	end
	while true do
		local t = clock()
		for _, copy in ipairs(copies) do
			local fireAt = finish - copy.at
			if not copy.fired and t >= fireAt then
				copy.fired = true
				copy.firedAt = t
				remotes.CompanionAttack.OnClientEvent:Fire(copy.payload)
			end
			-- The hit comes back just after the damage lands, as it would from the server.
			if copy.fired and not copy.hit and copy.payload.kind ~= nil and not copy.payload.blast and t - copy.firedAt >= copy.payload.lands + 0.03 then
				copy.hit = true
				remotes.CompanionHit.OnClientEvent:Fire({
					companion = copy.model, positions = { copy.targetAt }, victims = { copy.target }, killed = false,
					color = copy.payload.color, style = copy.payload.style, rarity = copy.payload.rarity,
					styleTime = BrainrotData.Stats(spec.def, 1, 0).slowTime or BrainrotData.Stats(spec.def, 1, 0).dotTime,
					ownerRoot = copy.ownerRoot,
				})
			end
		end
		seam.RunService.RenderStepped:Fire(1 / 60)
		seam.RunService.Stepped:Fire(t, 1 / 60)
		if t >= finish then
			break
		end
		task.wait()
	end

	-- Freeze: particles stop where they are, trails stop fading, nothing is stepped again.
	for _, d in ipairs(fxParent:GetDescendants()) do
		if d:IsA("ParticleEmitter") then
			d.TimeScale = 0
		elseif d:IsA("Trail") then
			d.Lifetime = 30
		end
	end
	for _, copy in ipairs(copies) do
		local rig = api.rigs[copy.model]
		if rig and rig.pose then
			copy.pose(rig.pose)
		end
	end

	local backOff = spacing * #copies * 0.55 + 18
	camera.FieldOfView = 50
	camera.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, backOff * 0.45, backOff * 0.8), ORIGIN + Vector3.new(0, 2, -TARGET_DISTANCE * 0.5))
	for index, copy in ipairs(copies) do
		frameCheck(spec.name .. " copy " .. index .. " (" .. string.format("%.2fs", copy.at) .. ")", camera, copy.model.PrimaryPart.Position, folder)
	end
	local lights = 0
	for _, d in ipairs(fxParent:GetDescendants()) do
		if d:IsA("PointLight") then
			lights += 1
		end
	end
	note(string.format("%s: live effects %d, particles %d, lights %d, late by %.3fs of real time (frame granularity)", spec.name, #api.live,
		api.budget.particles, lights, clock() - finish))
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

local function firstWith(test)
	for _, def in ipairs(BrainrotData.Types) do
		if test(def) then
			return def
		end
	end
	return nil
end

local views = {}
local THREE = { {}, {}, {} }

for _, kind in ipairs({ "Spit", "Bonk", "Zap", "Chain", "Lob", "Shockwave", "Blast" }) do
	local def = kind == "Blast" and firstWith(function(d)
		return d.blast == true
	end) or firstWith(function(d)
		return not d.blast and (d.attack or "Spit") == kind
	end)
	if def then
		table.insert(views, {
			name = "move_" .. kind,
			settle = 0.3,
			setup = function(folder, camera)
				note(string.format("move_%s: %s (%s), plain -- no style", kind, def.name, def.rarity))
				stageView(folder, camera, { name = "move_" .. kind, def = def, kind = kind, copies = THREE })
			end,
		})
	end
end

for _, style in ipairs({ "Slow", "Daze", "Burn", "Toxic", "Leech", "Wide", "Quick", "Long", "Fork" }) do
	local def = firstWith(function(d)
		local _, name = BrainrotData.StyleOf(d)
		return name == style
	end)
	if def then
		local kind = def.attack or "Spit"
		table.insert(views, {
			name = "style_" .. style,
			settle = 0.3,
			setup = function(folder, camera)
				note(string.format("style_%s: %s (%s), a %s", style, def.name, def.rarity, kind))
				stageView(folder, camera, { name = "style_" .. style, def = def, kind = kind, style = style, copies = THREE, lateImpact = true })
			end,
		})
	end
end

do
	local tiers = {}
	for _, rarity in ipairs({ "Common", "Epic", "Secret" }) do
		local def = firstWith(function(d)
			return not d.blast and d.rarity == rarity and (d.attack or "Spit") == "Zap"
		end) or firstWith(function(d)
			return not d.blast and d.rarity == rarity
		end)
		table.insert(tiers, { def = def, at = { rarity, W + 0.04 } })
	end
	table.insert(views, {
		name = "rarity_tint",
		settle = 0.3,
		setup = function(folder, camera)
			for _, tier in ipairs(tiers) do
				note(string.format("rarity_tint: %s (%s, a %s)", tier.def.name, tier.def.rarity, tier.def.attack or "Spit"))
			end
			stageView(folder, camera, { name = "rarity_tint", def = tiers[1].def, kind = "Zap", copies = tiers })
		end,
	})
end

return views
