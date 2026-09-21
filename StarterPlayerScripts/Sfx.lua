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

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))
local Settings = require(script.Parent:WaitForChild("Settings"))

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
local function applyEffects(sound, config)
	if type(config.effects) ~= "table" then
		return
	end
	for _, entry in ipairs(config.effects) do
		local className = entry[1]
		local ok, effect = pcall(Instance.new, className)
		if ok and effect then
			for property, value in pairs(entry[2] or {}) do
				pcall(function()
					effect[property] = value
				end)
			end
			effect.Parent = sound
		end
	end
end

-- One voice of a cue: a Sound per layer, already pitched and mixed, parented to `parent`.
local function buildVoice(config, layers, parent, positional)
	local voice = {}
	for _, layer in ipairs(layers) do
		local sound = Instance.new("Sound")
		sound.SoundId = layer.id
		sound.Volume = layer.volume
		sound.PlaybackSpeed = layer.pitch
		sound.SoundGroup = groupFor(config)
		if positional then
			sound.RollOffMode = Enum.RollOffMode.InverseTapered
			sound.RollOffMinDistance = 14
			sound.RollOffMaxDistance = config.maxDistance or 400
		end
		applyEffects(sound, config)
		sound.Parent = parent
		table.insert(voice, { sound = sound, pitch = layer.pitch, delay = layer.delay })
	end
	return voice
end

-- Start every layer of a voice, honouring each layer's delay. `scale` multiplies the whole cue's
-- pitch (jitter, or a caller-supplied override), so the layers keep their relative tuning.
local function playVoice(voice, scale)
	for _, layer in ipairs(voice) do
		local sound = layer.sound
		sound.PlaybackSpeed = layer.pitch * scale
		if layer.delay > 0 then
			task.delay(layer.delay, function()
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
		table.insert(pool, buildVoice(config, layers, SoundService, false))
	end

	pools[name] = pool
	cursors[name] = 1
	return pool
end

-- `pitchJitter` keeps repeated cues from sounding mechanical. `pitch` overrides the cue's base
-- pitch, for rising sequences like the crate-opening tier climb.
function Sfx.Play(name, pitchJitter, pitch)
	local pool = ensurePool(name)
	if not pool then
		return
	end

	local config = SoundConfig.Get(name)
	local index = cursors[name]
	cursors[name] = (index % #pool) + 1
	playVoice(pool[index], pitchScale(config, pitchJitter, pitch))
end

--------------------------------------------------------------------------------
-- Positional
--------------------------------------------------------------------------------

-- Other people's gunfire. Sounds under an Attachment play from that point in the world, so you
-- can hear which direction a fight is in — the main way anyone finds one in a battle royale.
-- Pooled the same way; the attachments are just moved to each new shot.
local POSITIONAL_POOL_SIZE = 8
local DEFAULT_MAX_DISTANCE = 400

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
		table.insert(pool, { attachment = attachment, voice = buildVoice(config, layers, attachment, true) })
	end

	positionalPools[name] = pool
	positionalCursors[name] = 1
	return pool
end

function Sfx.PlayAt(name, position, pitchJitter)
	local config = SoundConfig.Get(name)
	local camera = workspace.CurrentCamera
	if not config or not camera then
		return
	end

	-- Out of earshot: don't steal a pool slot from a shot that could actually be heard.
	if (camera.CFrame.Position - position).Magnitude > (config.maxDistance or DEFAULT_MAX_DISTANCE) then
		return
	end

	local pool = ensurePositionalPool(name)
	if not pool then
		return
	end

	local index = positionalCursors[name]
	positionalCursors[name] = (index % #pool) + 1

	local entry = pool[index]
	entry.attachment.Position = position
	playVoice(entry.voice, pitchScale(config, pitchJitter, nil))
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

	local voice = buildVoice(config, layers, attachment, true)
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
