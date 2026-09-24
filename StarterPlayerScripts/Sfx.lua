-- Client sound playback. ModuleScript, not a LocalScript.
--
-- A cue in SoundConfig is a recipe: one or more source files stacked at their own pitch, volume
-- and start delay, optionally run through a SoundEffect chain. This builds each recipe into real
-- Sound instances and plays them together.
--
-- Sounds are pooled per cue rather than created per play: spawning instances for every rifle shot
-- would churn hundreds a second. A pool entry holds one Sound per layer, so a three-layer gunshot
-- costs three instances per voice.
--
-- Every sound plays through a SoundGroup for its category (SoundConfig `category`), and the
-- groups follow the volume sliders in Settings, so changing a slider affects sounds already
-- playing too.
--
-- What changes with where a sound is heard from (#120: rolloff per class, the top end lost to
-- distance, travel time, a rifle's crack arriving before its report, reverb only under a roof)
-- is worked out by SoundConfig.Plan; this file only applies the plan. Two effects per Sound are
-- switched per play rather than rebuilt: an equaliser for the air (the cue's own one when it
-- has one, so the chain doesn't grow) and the room reverb.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))
local Settings = require(script.Parent:WaitForChild("Settings"))

local Acoustics = SoundConfig.Acoustics

local Sfx = {}

local POOL_SIZE = 4

local CATEGORY_SETTING = { Weapons = "WeaponVolume", Effects = "EffectsVolume", Interface = "InterfaceVolume" }

local groups = {}

local function applyVolumes()
	local master = Settings.Get("MasterVolume")
	for category, group in pairs(groups) do
		group.Volume = master * Settings.Get(CATEGORY_SETTING[category] or "EffectsVolume")
	end
end

local function groupFor(config)
	local category = CATEGORY_SETTING[config.category] and config.category or "Effects"
	local group = groups[category]
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = "BRR_" .. category
		group.Parent = SoundService
		groups[category] = group
		applyVolumes()
	end
	return group
end

Settings.Changed:Connect(function(id)
	if id == "*" or id == "MasterVolume" or id == "WeaponVolume" or id == "EffectsVolume" or id == "InterfaceVolume" then
		applyVolumes()
	end
end)

-- The SoundGroup a category's cues play through ("Weapons", "Effects" or "Interface"), created on
-- demand, for a Sound built outside the pools (a looping cue riding on a moving part): parented to
-- this group it follows the volume sliders from its first play, whether or not any pooled cue of
-- the category has played yet.
function Sfx.GroupFor(category)
	return groupFor({ category = category })
end

-- The cue's effect chain, rebuilt on each voice. Effects live on the Sound, so a cue with two
-- layers gets the chain twice; the alternative is a SoundGroup per cue, which can't be nested
-- under the category group that the volume sliders drive.
local function newEffect(sound, className, properties)
	local ok, effect = pcall(Instance.new, className)
	if not ok or not effect then
		return nil
	end
	for property, value in pairs(properties or {}) do
		pcall(function()
			effect[property] = value
		end)
	end
	effect.Parent = sound
	return effect
end

-- Builds the chain and returns what it made, each with the config entry it came from, so the
-- per-play code can find the cue's own reverb and equaliser and their authored settings.
local function applyEffects(sound, config)
	local made = {}
	if type(config.effects) ~= "table" then
		return made
	end
	for _, entry in ipairs(config.effects) do
		if #made >= Acoustics.MAX_EFFECTS_PER_SOUND then
			break
		end
		local effect = newEffect(sound, entry[1], entry[2])
		if effect then
			table.insert(made, { effect = effect, className = entry[1], properties = entry[2] or {} })
		end
	end
	return made
end

-- The per-play effects for one layer's Sound, within MAX_EFFECTS_PER_SOUND. The room reverb comes
-- first (it is what tells indoors from out); the air equaliser reuses the cue's own when it has
-- one. Its authored gains are kept from the CONFIG, never read back off the effect, because the
-- effect's gains are rewritten on every play.
local function addPerPlay(entry, sound, made, name, config, positional)
	if SoundConfig.RoomGated(name, config) then
		local rooms = {}
		for _, item in ipairs(made) do
			if item.className == "ReverbSoundEffect" then
				table.insert(rooms, item.effect)
			end
		end
		if #rooms == 0 and #made < Acoustics.MAX_EFFECTS_PER_SOUND then
			local room = newEffect(sound, "ReverbSoundEffect", Acoustics.ROOM)
			if room then
				room.Name = "BRR_Room"
				table.insert(made, { effect = room, className = "ReverbSoundEffect", properties = Acoustics.ROOM })
				table.insert(rooms, room)
			end
		end
		entry.rooms = rooms
	end
	if positional then
		for _, item in ipairs(made) do
			if item.className == "EqualizerSoundEffect" then
				local p = item.properties
				entry.air = item.effect
				entry.airBase = { p.LowGain or 0, p.MidGain or 0, p.HighGain or 0 }
				break
			end
		end
		if not entry.air and #made < Acoustics.MAX_EFFECTS_PER_SOUND then
			local air = newEffect(sound, "EqualizerSoundEffect", { LowGain = 0, MidGain = 0, HighGain = 0 })
			if air then
				air.Name = "BRR_Air"
				table.insert(made, { effect = air, className = "EqualizerSoundEffect", properties = {} })
				entry.air = air
				entry.airBase = { 0, 0, 0 }
			end
		end
	end
end

-- One voice of a cue: a Sound per layer, already pitched and mixed, parented to `parent`.
-- `perPlay` adds the switchable room and air effects (pools do; a loop is never re-planned).
local function buildVoice(name, config, layers, parent, positional, perPlay)
	local voice = {}
	local near, far = SoundConfig.Rolloff(name, config)
	for _, layer in ipairs(layers) do
		local sound = Instance.new("Sound")
		sound.SoundId = layer.id
		sound.Volume = layer.volume
		sound.PlaybackSpeed = layer.pitch
		sound.SoundGroup = groupFor(config)
		if positional then
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMinDistance = near
			sound.RollOffMaxDistance = far
		end
		local made = applyEffects(sound, config)
		local entry = { sound = sound, pitch = layer.pitch, delay = layer.delay, volume = layer.volume }
		if perPlay then
			addPerPlay(entry, sound, made, name, config, positional)
		end
		sound.Parent = parent
		table.insert(voice, entry)
	end
	return voice
end

-- Start every layer of a voice, honouring each layer's delay. `scale` multiplies the whole cue's
-- pitch (jitter, or a caller-supplied override), so the layers keep their relative tuning. `plan`
-- (SoundConfig.Plan) sets each layer's delay and gain, the room and the air; `gain` scales the
-- whole voice (a far rumble fading with distance).
local function playVoice(voice, scale, plan, gain)
	for index, layer in ipairs(voice) do
		local sound = layer.sound
		local shape = plan and plan.layers[index]
		local level = (shape and shape.gain or 1) * (gain or 1)
		sound.PlaybackSpeed = layer.pitch * scale
		sound.Volume = layer.volume * level
		if layer.rooms then
			local on = not plan or plan.room ~= false
			for _, room in ipairs(layer.rooms) do
				room.Enabled = on
			end
		end
		if layer.air then
			local base = layer.airBase
			layer.air.LowGain = base[1] + (plan and plan.low or 0)
			layer.air.MidGain = base[2] + (plan and plan.mid or 0)
			layer.air.HighGain = base[3] + (plan and plan.high or 0)
		end
		local delay = shape and shape.delay or layer.delay
		if level <= 0 then
			-- A layer for the other environment (an outdoor echo under a roof): silent this play,
			-- and cut short if the last play of this voice left it ringing.
			sound:Stop()
		elseif delay > 0 then
			task.delay(delay, function()
				if sound.Parent then
					sound.TimePosition = 0
					sound:Play()
				end
			end)
		else
			sound.TimePosition = 0
			sound:Play()
		end
	end
end

-- How much to multiply a cue's pitch by for this play: an explicit override, or the cue's own
-- tuning with optional jitter so repeats don't sound mechanical.
local function pitchScale(config, pitchJitter, pitch)
	local base = config.pitch or 1
	local wanted = pitch or base
	if pitchJitter then
		wanted += (math.random() - 0.5) * pitchJitter
	end
	if base == 0 then
		return 1
	end
	return wanted / base
end

--------------------------------------------------------------------------------
-- The room around the listener
--------------------------------------------------------------------------------

-- Whether the listener (the camera, which is where Roblox hears from) has a roof overhead: one
-- ray straight up, remembered for a quarter of a second so a 13-round burst costs one ray, not
-- thirteen. Only things you would bump your head on count (RespectCanCollide), so a canopy of
-- leaves or a smoke cloud is not a ceiling; your own character is left out.
local ENCLOSURE_TTL = 0.25
local enclosedAt = -math.huge
local enclosed = false

function Sfx.IsEnclosed()
	-- `time()` is game time. Not os.clock, which is CPU time in Roblox and runs slow under load.
	local now = time()
	if now - enclosedAt < ENCLOSURE_TTL then
		return enclosed
	end
	enclosedAt = now
	local camera = workspace.CurrentCamera
	if not camera then
		enclosed = false
		return enclosed
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	params.FilterDescendantsInstances = character and { character } or {}
	params.RespectCanCollide = true
	params.IgnoreWater = true
	enclosed = workspace:Raycast(camera.CFrame.Position, Vector3.new(0, Acoustics.CEILING_REACH, 0), params) ~= nil
	return enclosed
end

--------------------------------------------------------------------------------
-- Non-positional
--------------------------------------------------------------------------------

local pools = {}
local cursors = {}

local function ensurePool(name)
	if pools[name] then
		return pools[name]
	end

	local config = SoundConfig.Get(name)
	local layers = config and SoundConfig.LayersOf(config)
	if not layers then
		return nil
	end

	local pool = {}
	for _ = 1, POOL_SIZE do
		table.insert(pool, buildVoice(name, config, layers, SoundService, false, true))
	end

	pools[name] = pool
	cursors[name] = 1
	return pool
end

-- The next voice of a flat cue, played at distance 0 unless `plan` says otherwise.
local function playFlat(name, pitchJitter, pitch, plan, gain)
	local pool = ensurePool(name)
	if not pool then
		return
	end

	local config = SoundConfig.Get(name)
	local index = cursors[name]
	cursors[name] = (index % #pool) + 1
	playVoice(pool[index], pitchScale(config, pitchJitter, pitch), plan, gain)
end

-- `pitchJitter` keeps repeated cues from sounding mechanical. `pitch` overrides the cue's base
-- pitch, for rising sequences like the crate-opening tier climb. Your own gun indoors rings in
-- the room; outside it doesn't.
function Sfx.Play(name, pitchJitter, pitch)
	local config = SoundConfig.Get(name)
	if not config then
		return
	end
	playFlat(name, pitchJitter, pitch, SoundConfig.Plan(name, config, 0, Sfx.IsEnclosed()), 1)
end

-- A far-off event heard as a whole rather than from a direction (the ExplosionFar rumble): played
-- flat, at a level that fades with distance (SoundConfig.DistantGain), and late by the time the
-- sound takes to get here. `gain` scales it further.
function Sfx.PlayDistant(name, position, pitchJitter, gain)
	local config = SoundConfig.Get(name)
	local camera = workspace.CurrentCamera
	if not config or not camera then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	local level = SoundConfig.DistantGain(config, distance) * (gain or 1)
	if level <= 0 then
		return
	end
	local plan = SoundConfig.Plan(name, config, distance, Sfx.IsEnclosed())
	-- Flat: its top end is already gone in the recipe, so no air on top.
	plan.low, plan.mid, plan.high = 0, 0, 0
	task.delay(plan.start, playFlat, name, pitchJitter, nil, plan, level)
end

--------------------------------------------------------------------------------
-- Positional
--------------------------------------------------------------------------------

-- Other people's gunfire. Sounds under an Attachment play from that point in the world, so you
-- can hear which direction a fight is in — the main way anyone finds one in a battle royale.
-- Pooled the same way; the attachments are just moved to each new shot.
local POSITIONAL_POOL_SIZE = 8

local positionalPools = {}
local positionalCursors = {}

local function ensurePositionalPool(name)
	if positionalPools[name] then
		return positionalPools[name]
	end

	local config = SoundConfig.Get(name)
	local layers = config and SoundConfig.LayersOf(config)
	if not layers then
		return nil
	end

	local pool = {}
	for _ = 1, POSITIONAL_POOL_SIZE do
		local attachment = Instance.new("Attachment")
		attachment.Name = "Sfx_" .. name
		-- Terrain sits at the origin, so an attachment's Position under it is its world position.
		attachment.Parent = workspace.Terrain
		table.insert(pool, { attachment = attachment, voice = buildVoice(name, config, layers, attachment, true, true) })
	end

	positionalPools[name] = pool
	positionalCursors[name] = 1
	return pool
end

-- The voice is picked and moved when the sound ARRIVES, not when it was made: a far shot waits
-- for its travel time first, so a pool slot is never retargeted with a play still pending on it.
local function arriveAt(name, position, scale, plan)
	local pool = ensurePositionalPool(name)
	if not pool then
		return
	end
	local index = positionalCursors[name]
	positionalCursors[name] = (index % #pool) + 1

	local entry = pool[index]
	entry.attachment.Position = position
	playVoice(entry.voice, scale, plan, 1)
end

-- How far the listener is from the line a shot took, for whether its crack passes them.
local function missDistance(listener, from, to)
	local line = to - from
	local length = line.Magnitude
	if length < 1e-3 then
		return (listener - from).Magnitude
	end
	local along = math.clamp((listener - from):Dot(line) / (length * length), 0, 1)
	return (listener - (from + line * along)).Magnitude
end

-- `towards`, optional: where the shot went. A supersonic shot whose line passes within
-- CRACK_REACH of you cracks before its report arrives; one that doesn't is heard as a report.
-- Without it the shot is taken as passing near (the crack is the more telling sound).
function Sfx.PlayAt(name, position, pitchJitter, towards)
	local config = SoundConfig.Get(name)
	local camera = workspace.CurrentCamera
	if not config or not camera then
		return
	end

	-- Out of earshot: don't steal a pool slot from a shot that could actually be heard.
	local listener = camera.CFrame.Position
	local distance = (listener - position).Magnitude
	local _, far = SoundConfig.Rolloff(name, config)
	if distance > far then
		return
	end

	local nearPath = nil
	if typeof(towards) == "Vector3" then
		nearPath = missDistance(listener, position, towards) <= Acoustics.CRACK_REACH
	end
	local plan = SoundConfig.Plan(name, config, distance, Sfx.IsEnclosed(), nearPath)
	local scale = pitchScale(config, pitchJitter, nil)
	if plan.start > 0.005 then
		task.delay(plan.start, arriveAt, name, position, scale, plan)
	else
		arriveAt(name, position, scale, plan)
	end

	-- A big blast far enough off that its crack is fading gets its rumble underneath.
	if plan.distant > 0 and type(config.distant) == "table" and config.distant.cue then
		Sfx.PlayDistant(config.distant.cue, position, pitchJitter, plan.distant)
	end
end

--------------------------------------------------------------------------------
-- Loops
--------------------------------------------------------------------------------

-- A cue that runs until it is stopped, riding on an Attachment so it plays from that point in the
-- world and follows whatever the attachment is on: an engine, and anything else that hums.
--
--   local engine = Sfx.Loop("VehicleEngine", attachment)
--   engine:SetPitch(1.6)  engine:SetVolume(0.8)  engine:Stop()
--
-- A missing cue returns nil rather than erroring, so a caller can ship before its cue does. A loop
-- stops itself when its attachment (or the part under it) goes away, so nothing is ever left
-- humming in an empty world. Only the LOOP_LIMIT nearest the camera are audible at once: the rest
-- keep their handles but fall silent, so a queue of traffic can't stack thirty engines.
local LOOP_LIMIT = 6
local LOOP_TRIM_EVERY = 0.4

local loops = {}
local loopCount = 0
local trimConnection = nil

local Loop = {}
Loop.__index = Loop

local function loopDistance(handle)
	local camera = workspace.CurrentCamera
	local attachment = handle.attachment
	if not camera or not attachment.Parent then
		return math.huge
	end
	return (camera.CFrame.Position - attachment.WorldPosition).Magnitude
end

local function trimLoops()
	local ordered = {}
	for handle in pairs(loops) do
		table.insert(ordered, handle)
	end
	table.sort(ordered, function(a, b)
		return loopDistance(a) < loopDistance(b)
	end)
	for index, handle in ipairs(ordered) do
		handle:setAudible(index <= LOOP_LIMIT)
	end
end

function Loop:setAudible(on)
	if self.audible == on then
		return
	end
	self.audible = on
	for _, layer in ipairs(self.voice) do
		if layer.sound.Parent then
			if on then
				layer.sound:Play()
			else
				layer.sound:Stop()
			end
		end
	end
end

-- Multiplies the cue's own tuning, so its layers keep their relative pitch.
function Loop:SetPitch(scale)
	self.pitch = scale
	for _, layer in ipairs(self.voice) do
		layer.sound.PlaybackSpeed = layer.pitch * scale
	end
end

function Loop:SetVolume(scale)
	self.volume = scale
	for _, layer in ipairs(self.voice) do
		layer.sound.Volume = layer.volume * scale
	end
end

function Loop:Stop()
	if self.stopped then
		return
	end
	self.stopped = true
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
	for _, layer in ipairs(self.voice) do
		layer.sound:Destroy()
	end
	if loops[self] then
		loops[self] = nil
		loopCount -= 1
	end
	if loopCount == 0 and trimConnection then
		trimConnection:Disconnect()
		trimConnection = nil
	end
end

function Sfx.Loop(name, attachment)
	local config = SoundConfig.Get(name)
	local layers = config and SoundConfig.LayersOf(config)
	if not layers or typeof(attachment) ~= "Instance" or not attachment:IsA("Attachment") then
		return nil
	end

	local voice = buildVoice(name, config, layers, attachment, true, false)
	local handle = setmetatable({
		voice = voice,
		attachment = attachment,
		audible = true,
		pitch = 1,
		volume = 1,
	}, Loop)
	for _, layer in ipairs(voice) do
		layer.sound.Looped = true
		layer.sound:Play()
	end

	-- Covers the attachment being destroyed, its part being destroyed, and the whole model going.
	handle.connection = attachment.AncestryChanged:Connect(function()
		if not attachment:IsDescendantOf(workspace) and not attachment:IsDescendantOf(SoundService) then
			handle:Stop()
		end
	end)

	loops[handle] = true
	loopCount += 1
	if not trimConnection then
		local since = 0
		trimConnection = game:GetService("RunService").Heartbeat:Connect(function(dt)
			since += dt
			if since >= LOOP_TRIM_EVERY then
				since = 0
				trimLoops()
			end
		end)
	end
	trimLoops()
	return handle
end

-- How many loops are running, and how many of those can be heard: for the probe that proves the
-- cap and the clean-up.
function Sfx.LoopCount()
	local audible = 0
	for handle in pairs(loops) do
		if handle.audible then
			audible += 1
		end
	end
	return loopCount, audible, LOOP_LIMIT
end

return Sfx
