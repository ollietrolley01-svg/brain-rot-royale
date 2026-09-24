-- Draws companion attacks from the server's CompanionAttack broadcasts, and animates every nearby
-- companion (see CompanionAnimations).
--
--   Spit       rears back and snaps forward; a glob flies straight at the target
--   Bonk       the creature itself leaps at the target and slams down with a ring
--   Zap        shivers as it charges, then a beam and a recoil kick
--   Chain      the same with a spin, and the beam forks on to a second enemy
--   Lob        winds up with its arms high and tosses a shot that splashes where it lands
--   Shockwave  jumps and stomps (spinners spin), and a ring pulses out from it
--
-- Every move connects `windup` seconds after its broadcast, when the server applies the damage,
-- so beams, launches and stomps fire at that moment rather than at the broadcast. CompanionHit
-- marks where damage really landed with an impact, and makes the companion cheer.
--
-- A move's style (BrainrotData.AbilityStyles) rides both broadcasts as `style`, and adds a second,
-- tinted cue on each hit from the same parts: frost chips for a slow, a spinning halo for a daze,
-- rising embers for a burn, green puffs for poison, a red glob flying back to the companion for a
-- leech. Wide, Quick and Long change numbers only and show through the move's own ring and timing;
-- a Forking beam draws its extra jump (`to3`).
--
-- All local: nothing here replicates, and effects far from the camera are skipped. Companions
-- are posed through Motor6D.Transform, which is local too, so every client animates them itself.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local CompanionAnimations = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CompanionAnimations"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local companionAttack = Remotes.Event("CompanionAttack")
local companionHit = Remotes.Event("CompanionHit")

local EFFECT_DISTANCE = 450
-- Companions further than this from the camera hold their rest pose.
local ANIMATE_DISTANCE = 220
-- Impact effects per second at most, however many companions are landing hits.
local MAX_IMPACTS_PER_SECOND = 12

local folder = Instance.new("Folder")
folder.Name = "CompanionFx"
folder.Parent = workspace

local function neon(size, cframe, color, transparency, shape)
	local part = Instance.new("Part")
	if shape then
		part.Shape = shape
	end
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Transparency = transparency or 0
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = folder
	return part
end

local function fadeOut(part, time, goal)
	goal = goal or {}
	goal.Transparency = 1
	TweenService:Create(part, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	task.delay(time + 0.05, function()
		part:Destroy()
	end)
end

local function burst(position, color, size)
	local ball = neon(Vector3.new(size, size, size), CFrame.new(position), color, 0.2, Enum.PartType.Ball)
	fadeOut(ball, 0.25, { Size = Vector3.new(size, size, size) * 2.2 })
end

-- A flat ring expanding along the ground from `position`.
local function ring(position, radius, color, time)
	local disc = neon(Vector3.new(0.3, 2, 2), CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2), color, 0.45,
		Enum.PartType.Cylinder)
	fadeOut(disc, time, { Size = Vector3.new(0.3, radius * 2, radius * 2) })
end

local function beam(from, to, color, width, time)
	local distance = (to - from).Magnitude
	if distance < 0.5 then
		return
	end
	local part = neon(Vector3.new(width, width, distance), CFrame.lookAt(from, to) * CFrame.new(0, 0, -distance / 2), color, 0.1)
	fadeOut(part, time)
end

-- A ball from `from` to `to` over `travel` seconds, rising `arc` studs at its peak.
local function projectile(from, to, color, travel, arc, onArrive)
	local ball = neon(Vector3.new(0.9, 0.9, 0.9), CFrame.new(from), color, 0, Enum.PartType.Ball)
	local start = os.clock()
	local connection
	connection = RunService.RenderStepped:Connect(function()
		local alpha = math.clamp((os.clock() - start) / math.max(travel, 0.05), 0, 1)
		ball.CFrame = CFrame.new(from:Lerp(to, alpha) + Vector3.new(0, arc * 4 * alpha * (1 - alpha), 0))
		if alpha >= 1 then
			connection:Disconnect()
			ball:Destroy()
			onArrive()
		end
	end)
end

--------------------------------------------------------------------------------
-- Rigs
--------------------------------------------------------------------------------

-- model -> rig, for every rigged companion in workspace.Companions. They stream in whole
-- (ModelStreamingMode Atomic), but a model can still show up a moment before its last parts.
local rigs = {}

local function track(model)
	if rigs[model] or not model:IsA("Model") then
		return
	end
	local rig = CompanionAnimations.Rig(model)
	if rig then
		rigs[model] = rig
	end
end

task.spawn(function()
	local companions = workspace:WaitForChild("Companions")
	for _, model in ipairs(companions:GetChildren()) do
		track(model)
	end
	companions.ChildAdded:Connect(function(model)
		track(model)
		if not rigs[model] then
			task.delay(0.5, function()
				if model.Parent then
					track(model)
				end
			end)
		end
	end)
	companions.ChildRemoved:Connect(function(model)
		rigs[model] = nil
	end)
end)

-- Where a rig's Body joint rests in the world: the creature's base, the frame its poses are in.
local function restFrame(rig)
	local joint = rig.joints.Body
	return rig.root.CFrame * joint.C0
end

local function rigFor(info)
	local model = info and info.companion
	if typeof(model) ~= "Instance" then
		return nil
	end
	track(model)
	return rigs[model]
end

-- Posed in Stepped, the same slot the gun poses use: after physics has placed the root and
-- before the frame renders.
RunService.Stepped:Connect(function()
	local camera = workspace.CurrentCamera
	local eye = camera and camera.CFrame.Position
	local now = os.clock()
	for model, rig in pairs(rigs) do
		if not model.Parent or not rig.root or not rig.root.Parent then
			rigs[model] = nil
		elseif eye and (rig.root.Position - eye).Magnitude >= ANIMATE_DISTANCE then
			-- Out of range: settle into the rest pose once, rather than freezing mid-move (a Bonk
			-- caught mid-leap would otherwise hang in the air until it came back into range).
			if not rig.resting then
				rig.resting = true
				rig.clip, rig.cheer = nil, nil
				CompanionAnimations.Rest(rig)
			end
		else
			rig.resting = false
			local pose = CompanionAnimations.Idle(rig, now)
			for _, key in ipairs({ "clip", "cheer" }) do
				local clip = rig[key]
				if clip then
					if clip.world then
						-- The target in the frame the pose is in, redone every frame because the
						-- companion keeps following its owner through the move.
						clip.target = restFrame(rig):PointToObjectSpace(clip.world)
					end
					if not CompanionAnimations.Layer(pose, rig.body, clip, now - clip.start, rig.scale) then
						rig[key] = nil
					end
				end
			end
			CompanionAnimations.Apply(rig, pose)
		end
	end
end)

local impactWindow, impactsInWindow = 0, 0

-- Where a companion's move really hurt someone: a white flash, a star of shards flying out and a
-- ring; bigger for a knockout.
-- The tint and shape of each style's hit cue. Plain colours, not the brainrot's, so a slow reads as a
-- slow on any companion.
local STYLE_CUE = {
	Slow = { color = Color3.fromRGB(150, 220, 255) },
	Daze = { color = Color3.fromRGB(255, 240, 120) },
	Burn = { color = Color3.fromRGB(255, 130, 40) },
	Toxic = { color = Color3.fromRGB(120, 230, 70) },
	Leech = { color = Color3.fromRGB(230, 40, 70) },
}

local function styleCue(style, position, rig)
	local cue = STYLE_CUE[style]
	if not cue then
		return
	end
	local color = cue.color
	if style == "Slow" then
		-- Frost chips settling outward along the ground.
		ring(position - Vector3.new(0, 2, 0), 3.5, color, 0.6)
		for index = 1, 5 do
			local angle = index / 5 * math.pi * 2
			local chip = neon(Vector3.new(0.3, 0.3, 0.3), CFrame.new(position), color, 0.1)
			fadeOut(chip, 0.6, { CFrame = CFrame.new(position + Vector3.new(math.cos(angle) * 2.2, -1.6, math.sin(angle) * 2.2)) })
		end
	elseif style == "Daze" then
		-- A halo of little stars spinning over the head.
		local above = position + Vector3.new(0, 2.6, 0)
		for index = 1, 3 do
			local angle = index / 3 * math.pi * 2
			local star = neon(Vector3.new(0.35, 0.35, 0.35), CFrame.new(above + Vector3.new(math.cos(angle), 0, math.sin(angle))), color, 0)
			fadeOut(star, 0.6, { CFrame = CFrame.new(above + Vector3.new(math.cos(angle + 2.5), 0.3, math.sin(angle + 2.5))) })
		end
	elseif style == "Burn" or style == "Toxic" then
		-- Embers or puffs drifting up off the victim.
		for _ = 1, 4 do
			local start = position + Vector3.new(math.random() * 1.6 - 0.8, -0.5, math.random() * 1.6 - 0.8)
			local puff = neon(Vector3.new(0.45, 0.45, 0.45), CFrame.new(start), color, 0.2, Enum.PartType.Ball)
			fadeOut(puff, 0.7, { CFrame = CFrame.new(start + Vector3.new(0, 2.5, 0)), Size = Vector3.new(0.1, 0.1, 0.1) })
		end
	elseif style == "Leech" and rig and rig.root.Parent then
		-- A glob of health flying back from the victim to the companion.
		projectile(position, rig.root.Position, color, 0.35, 2, function() end)
	end
end

local function impact(position, color, killed)
	local size = killed and 2.6 or 1.6
	burst(position, Color3.new(1, 1, 1), size)
	ring(position - Vector3.new(0, 1, 0), killed and 7 or 4, color, 0.3)
	for index = 1, killed and 10 or 6 do
		local direction = Vector3.new(math.random() - 0.5, math.random() * 0.8 - 0.2, math.random() - 0.5)
		if direction.Magnitude < 0.05 then
			direction = Vector3.new(0, 1, 0)
		end
		direction = direction.Unit
		local shard = neon(Vector3.new(0.22, 0.22, 0.9), CFrame.lookAt(position, position + direction), index % 2 == 0 and color or Color3.new(1, 1, 1), 0)
		fadeOut(shard, 0.3, {
			CFrame = CFrame.lookAt(position + direction * 3.2, position + direction * 4),
			Size = Vector3.new(0.05, 0.05, 0.3),
		})
	end
end

--------------------------------------------------------------------------------
-- Attacks
--------------------------------------------------------------------------------

companionAttack.OnClientEvent:Connect(function(info)
	local camera = workspace.CurrentCamera
	if type(info) ~= "table" or typeof(info.from) ~= "Vector3" or typeof(info.to) ~= "Vector3" then
		return
	end
	if camera and (info.from - camera.CFrame.Position).Magnitude > EFFECT_DISTANCE then
		return
	end

	local color = typeof(info.color) == "Color3" and info.color or Color3.new(1, 1, 1)
	local to = info.to
	local windup = math.clamp(tonumber(info.windup) or 0, 0, 1)
	local travel = math.clamp(tonumber(info.travel) or 0, 0, 3)
	local rig = rigFor(info)

	if rig then
		-- A Bonk leaps its body on to the target: land it a little above the target's feet.
		local aim = info.kind == "Bonk" and to - Vector3.new(0, 1.5, 0) or to
		rig.clip = { kind = info.kind, start = os.clock(), world = aim, travel = travel }
	end

	-- Where the move leaves from once the windup is over: the creature as it is by then.
	local function origin()
		if rig and rig.root.Parent then
			return rig.root.Position
		end
		return info.from
	end

	-- A lobby demo on a practice target hurts nobody, so no CompanionHit comes back; mark the landing
	-- here instead, when the move would have connected.
	if info.practice and info.kind ~= "Shockwave" then
		local lands = windup + ((info.kind == "Zap" or info.kind == "Chain") and 0 or travel)
		task.delay(lands, function()
			impact(to, color, false)
			Sfx.PlayAt("CompanionHit", to, 0.12)
		end)
	end

	task.delay(windup, function()
		local from = origin()
		Sfx.PlayAt("CompanionAttack", from, 0.15)
		if info.kind == "Zap" or info.kind == "Chain" then
			beam(from, to, color, info.kind == "Zap" and 0.35 or 0.3, info.kind == "Zap" and 0.18 or 0.2)
			burst(to, color, 1.4)
			-- The forks: a Chain's own, and a Forking style's extra jump, each a beat after the last.
			if typeof(info.to2) == "Vector3" then
				task.delay(0.08, function()
					beam(to, info.to2, color, 0.25, 0.2)
					burst(info.to2, color, 1.2)
					if typeof(info.to3) == "Vector3" then
						task.delay(0.08, function()
							beam(info.to2, info.to3, color, 0.2, 0.2)
							burst(info.to3, color, 1)
						end)
					end
				end)
			end
		elseif info.kind == "Shockwave" then
			local base = rig and rig.root.Parent and restFrame(rig).Position or from - Vector3.new(0, 1.5, 0)
			ring(base, info.range or 20, color, 0.45)
			burst(from, color, 2)
		elseif info.kind == "Lob" then
			projectile(from + Vector3.new(0, 1, 0), to, color, travel > 0 and travel or 0.7, 10, function()
				ring(to, math.max(4, info.splash or 8), color, 0.35)
				burst(to, color, 2)
			end)
		elseif info.kind == "Bonk" then
			if rig then
				-- The creature is the projectile; the slam lands when it does.
				task.delay(travel, function()
					ring(to - Vector3.new(0, 1.5, 0), math.max(6, info.splash or 6), color, 0.3)
					burst(to, color, 2.4)
				end)
			else
				projectile(from, to, color, travel > 0 and travel or 0.35, 6, function()
					ring(to, math.max(6, info.splash or 6), color, 0.3)
					burst(to, color, 2.4)
				end)
			end
		else
			projectile(from, to, color, travel > 0 and travel or 0.5, 1, function()
				burst(to, color, 1.6)
			end)
		end
	end)
end)

--------------------------------------------------------------------------------
-- Hits
--------------------------------------------------------------------------------

companionHit.OnClientEvent:Connect(function(info)
	if type(info) ~= "table" or type(info.positions) ~= "table" then
		return
	end
	local camera = workspace.CurrentCamera
	local now = os.clock()
	if now - impactWindow > 1 then
		impactWindow, impactsInWindow = now, 0
	end
	local color = typeof(info.color) == "Color3" and info.color or Color3.new(1, 1, 1)
	for index, position in ipairs(info.positions) do
		if index > 4 or impactsInWindow >= MAX_IMPACTS_PER_SECOND then
			break
		end
		if typeof(position) == "Vector3" and (not camera or (position - camera.CFrame.Position).Magnitude <= EFFECT_DISTANCE) then
			impactsInWindow += 1
			impact(position, color, info.killed == true)
			if type(info.style) == "string" then
				styleCue(info.style, position, rigFor(info))
			end
			if index == 1 then
				Sfx.PlayAt("CompanionHit", position, 0.12)
			end
		end
	end

	local rig = rigFor(info)
	if rig and (not rig.cheer or now - rig.cheer.start > 0.3) then
		rig.cheer = { kind = "Cheer", start = now }
	end
end)

-- A companion was downed: it bursts into a puff of its colour and a scatter of chunks.
Remotes.Event("CompanionDown").OnClientEvent:Connect(function(info)
	local camera = workspace.CurrentCamera
	if not info or typeof(info.position) ~= "Vector3" then
		return
	end
	if camera and (info.position - camera.CFrame.Position).Magnitude > EFFECT_DISTANCE then
		return
	end

	local color = typeof(info.color) == "Color3" and info.color or Color3.new(1, 1, 1)
	local position = info.position
	Sfx.PlayAt("CompanionDown", position, 0.2)
	burst(position, color, 3)
	burst(position, Color3.new(1, 1, 1), 1.6)
	ring(position - Vector3.new(0, 1, 0), 9, color, 0.5)

	for _ = 1, 10 do
		local chunk = neon(Vector3.new(0.5, 0.5, 0.5), CFrame.new(position), color, 0)
		chunk.Material = Enum.Material.SmoothPlastic
		local target = position + Vector3.new(math.random(-6, 6), math.random(-2, 3), math.random(-6, 6))
		fadeOut(chunk, 0.7, { CFrame = CFrame.new(target) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
			Size = Vector3.new(0.15, 0.15, 0.15) })
	end
end)

-- Lobby playground: ball kicks, goals and Cloud Climb clears.
Remotes.Event("PlaygroundFx").OnClientEvent:Connect(function(info)
	local camera = workspace.CurrentCamera
	if type(info) ~= "table" or typeof(info.position) ~= "Vector3" then
		return
	end
	if camera and (info.position - camera.CFrame.Position).Magnitude > EFFECT_DISTANCE then
		return
	end

	local position = info.position
	local color = typeof(info.color) == "Color3" and info.color or Color3.fromRGB(255, 214, 110)
	if info.kind == "kick" then
		Sfx.PlayAt("BallKick", position, 0.25)
		return
	end
	if info.kind == "mine" then
		-- A Rot Mine landing and arming: a small flash and a ring on the ground, nothing more.
		Sfx.PlayAt("CompanionAttack", position, 0.2)
		burst(position, color, 1.4)
		ring(position - Vector3.new(0, 0.2, 0), 4, color, 0.45)
		return
	end

	Sfx.PlayAt("CrateOpen", position, 0.1)
	burst(position, color, info.kind == "goal" and 5 or 3)
	ring(position - Vector3.new(0, 2, 0), info.kind == "goal" and 14 or 9, color, 0.6)
	for _ = 1, info.kind == "goal" and 24 or 14 do
		local chunk = neon(Vector3.new(0.5, 0.5, 0.5), CFrame.new(position), Color3.fromHSV(math.random(), 0.6, 1), 0)
		local target = position + Vector3.new(math.random(-10, 10), math.random(4, 14), math.random(-10, 10))
		fadeOut(chunk, 1.1, { CFrame = CFrame.new(target) * CFrame.Angles(math.random() * 6, math.random() * 6, 0),
			Size = Vector3.new(0.2, 0.2, 0.2) })
	end
end)

--------------------------------------------------------------------------------
-- Idle bob
--
-- Your companion is simulated by this client, pulled toward an anchor attachment on your
-- character. Nudging that anchor up and down (and a little side to side) here makes the
-- creature float and sway instead of sitting rigidly at your shoulder — and because this client
-- owns the simulation, everyone else sees the bob too. The server set the anchor's resting
-- position and never touches it again, so the local change isn't overwritten.
--------------------------------------------------------------------------------

local player = Players.LocalPlayer
-- Each anchor's resting spot, dropped when the anchor goes. Strongly keyed: a weak-keyed table
-- lost the entry now and then, and re-reading the rest mid-bob walked the anchor upward.
local anchorRest = {}

RunService.Heartbeat:Connect(function()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local anchor = root and root:FindFirstChild("CompanionAnchor")
	if not anchor then
		return
	end

	local rest = anchorRest[anchor]
	if not rest then
		-- Only this character's anchor matters: a new one means the old body is gone, even if its
		-- Destroying never reached this client.
		table.clear(anchorRest)
		rest = anchor.Position
		anchorRest[anchor] = rest
		anchor.Destroying:Connect(function()
			anchorRest[anchor] = nil
		end)
	end

	local t = os.clock()
	anchor.Position = rest + Vector3.new(math.sin(t * 1.3) * 0.25, math.sin(t * 2.2) * 0.4, 0)
end)
