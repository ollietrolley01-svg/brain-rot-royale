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

local POOL_SIZE = Acoustics.VOICES.flat

local CATEGORY_SETTING = { Weapons = "WeaponVolume", Effects = "EffectsVolume", Interface = "InterfaceVolume" }

local groups = {}

local function applyVolumes()
	local master = Settings.Get("MasterVolume")
	for category, group in pairs(groups) do
		group.Volume = master * Settings.Get(CATEGORY_SETTING[category] or "EffectsVolume")
	end
end

-- The muffle a close blast puts on the world (Sfx.Duck): one equaliser per group, flat and
-- disabled until needed.
local duckers = {}

-- A group's own effects: the bus compressor, which hears the SUM of every voice in the group, so
-- a wall of full-auto or a chain of blasts is held together instead of clipping; and the ducker.
local function dressGroup(group, category)
	local bus = Acoustics.BUS[category]
	if bus then
		local compressor = Instance.new("CompressorSoundEffect")
		for property, value in pairs(bus) do
			compressor[property] = value
		end
		compressor.Name = "BRR_Bus"
		compressor.Parent = group
	end
	if category ~= "Interface" then
		local ducker = Instance.new("EqualizerSoundEffect")
		ducker.Name = "BRR_Duck"
		ducker.LowGain, ducker.MidGain, ducker.HighGain = 0, 0, 0
		ducker.Enabled = false
		ducker.Parent = group
		duckers[category] = ducker
	end
end

local function groupFor(config)
	local category = CATEGORY_SETTING[config.category] and config.category or "Effects"
	local group = groups[category]
	if not group then
		group = Instance.new("SoundGroup")
		group.Name = "BRR_" .. category
		dressGroup(group, category)
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

-- SoundConfig's novelty-gun helpers, here so a busy client script needn't require SoundConfig too.
Sfx.FoleyFor = SoundConfig.FoleyFor
Sfx.IsNovelty = SoundConfig.IsNovelty

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
local function addPerPlay(entry, sound, made, name, config, positional, layer)
	if SoundConfig.RoomGated(name, config) then
		local rooms = {}
		for _, item in ipairs(made) do
			if item.className == "ReverbSoundEffect" then
				table.insert(rooms, item.effect)
			end
		end
		-- An outdoor-only layer (the terrain's echo) is silent whenever the room is on, so it never
		-- needs a room of its own.
		if #rooms == 0 and #made < Acoustics.MAX_EFFECTS_PER_SOUND and layer.where ~= "outdoor" then
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

-- Whether a layer can ever sound in a pool: your own flat plays never hear the far thump, and
-- nobody else's positional play ever hears your gun's action cycling.
local function audibleIn(layer, positional)
	if positional then
		return layer.who ~= "self"
	end
	return layer.range ~= "far"
end

-- One voice of a cue: a Sound per layer, already pitched and mixed, parented to `parent`.
-- `perPlay` adds the switchable room and air effects (pools do; a loop is never re-planned).
-- A layer that can't sound in this pool gets a placeholder, so the plan's indices still line up.
local function buildVoice(name, config, layers, parent, positional, perPlay)
	local voice = {}
	local near, far = SoundConfig.Rolloff(name, config)
	for _, layer in ipairs(layers) do
		if perPlay and not audibleIn(layer, positional) then
			table.insert(voice, { skip = true })
		else
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
				addPerPlay(entry, sound, made, name, config, positional, layer)
			end
			sound.Parent = parent
			table.insert(voice, entry)
		end
	end
	return voice
end

-- Start one layer of a voice at its planned delay and gain (see playVoice). A delayed start belongs to
-- the play that scheduled it (`id`): if the voice has been taken for a newer play by the time it is
-- due, it is dropped rather than restarting the Sound at the new shot's place and level.
local function playLayer(voice, id, layer, shape, plan, scale, gain)
	local sound = layer.sound
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
		-- A layer for the other environment (an outdoor echo under a roof, the near crack of a far
		-- blast): silent this play, and cut short if the last play of this voice left it ringing.
		sound:Stop()
	elseif delay > 0 then
		voice.pending = (voice.pending or 0) + 1
		task.delay(delay, function()
			voice.pending -= 1
			if sound.Parent and voice.playId == id then
				sound.TimePosition = 0
				sound:Play()
			end
		end)
	else
		sound.TimePosition = 0
		sound:Play()
	end
end

-- Start every layer of a voice, honouring each layer's delay. `scale` multiplies the whole cue's
-- pitch (jitter, or a caller-supplied override), so the layers keep their relative tuning. `plan`
-- (SoundConfig.Plan) sets each layer's delay and gain, the room and the air; `gain` scales the
-- whole voice (a far rumble fading with distance). A placeholder layer (`skip`) has no Sound.
local function playVoice(voice, scale, plan, gain)
	voice.playId = (voice.playId or 0) + 1
	for index, layer in ipairs(voice) do
		if not layer.skip then
			playLayer(voice, voice.playId, layer, plan and plan.layers[index], plan, scale, gain)
		end
	end
end

-- Whether a voice is still sounding: a layer playing, or one still due to start.
local function voiceBusy(voice)
	if (voice.pending or 0) > 0 then
		return true
	end
	for _, layer in ipairs(voice) do
		if layer.sound and layer.sound.IsPlaying then
			return true
		end
	end
	return false
end

-- A pool of voices for one cue. It starts with ONE voice and grows a voice at a time, only when
-- every voice it has is still sounding, up to `cap` -- so the first shot of a cue costs one voice's
-- Sounds, not the whole pool's, and a cue only ever heard alone never builds more. Full and busy,
-- the next voice in turn (the oldest) is cut and reused. `make()` builds a slot `{ voice = ... }`.
local function newPool(cap, make)
	return { slots = { make() }, cursor = 1, cap = cap, make = make }
end

local function takeSlot(pool)
	local count = #pool.slots
	for step = 0, count - 1 do
		local index = (pool.cursor + step - 1) % count + 1
		if not voiceBusy(pool.slots[index].voice) then
			pool.cursor = index % count + 1
			return pool.slots[index]
		end
	end
	if count < pool.cap then
		local slot = pool.make()
		table.insert(pool.slots, slot)
		pool.cursor = 1
		return slot
	end
	local slot = pool.slots[pool.cursor]
	pool.cursor = pool.cursor % count + 1
	return slot
end

-- How many voices each pool has built, for the check that proves they grow only on demand.
local poolSizes = {}

-- How much to multiply a cue's pitch by for this play: an explicit override, or the cue's own
-- tuning with jitter so repeats don't sound mechanical. A caller's `pitchJitter` wins; without one
-- the cue's own (SoundConfig.JitterOf) applies; 0 means exactly this pitch (a rising sequence).
local function pitchScale(name, config, pitchJitter, pitch)
	local base = config.pitch or 1
	local wanted = pitch or base
	-- An exact pitch asked for with no jitter (a rising sequence of clicks) stays exact.
	local span = pitchJitter
	if span == nil then
		span = pitch == nil and SoundConfig.JitterOf(name, config) or 0
	end
	if span > 0 then
		wanted += (math.random() - 0.5) * span
	end
	if base == 0 then
		return 1
	end
	return wanted / base
end

-- The level half of the jitter: every play a touch louder or softer, by the cue's own span.
local function levelJitter(name, config)
	return 1 + (math.random() - 0.5) * SoundConfig.JitterOf(name, config)
end

-- The burst cap (Acoustics.BURST): whether one more play of this cue's class (or its own `burst`
-- group) may start now. Your own flat plays are never capped: your trigger pull always has a report,
-- however many other guns went off this frame.
local bursts = {}
local function admit(name, config, own)
	if own then
		return true
	end
	local class = config.burst or SoundConfig.ClassOf(name, config)
	local cap = Acoustics.BURST[class]
	if not cap then
		return true
	end
	local now = time()
	local burst = bursts[class]
	if not burst or now - burst.at >= cap.window then
		burst = { at = now, count = 0 }
		bursts[class] = burst
	end
	if burst.count >= cap.max then
		return false
	end
	burst.count += 1
	return true
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

-- How open the country around the listener is, 0 (walls all round) to 1 (nothing within reach):
-- the share of OPEN.rays level rays that hit nothing. A street answers a shot fast; a field
-- answers late, off the tree line. Cached like the roof.
local openAt = -math.huge
local openness = 0

function Sfx.Openness()
	local now = time()
	local settings = Acoustics.OPEN
	if now - openAt < settings.ttl then
		return openness
	end
	openAt = now
	local camera = workspace.CurrentCamera
	if not camera then
		openness = 0
		return openness
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	params.FilterDescendantsInstances = character and { character } or {}
	params.RespectCanCollide = true
	params.IgnoreWater = true
	local origin = camera.CFrame.Position
	local clear = 0
	for index = 1, settings.rays do
		local angle = (index - 1) / settings.rays * math.pi * 2
		local direction = Vector3.new(math.cos(angle) * settings.reach, 0, math.sin(angle) * settings.reach)
		if workspace:Raycast(origin, direction, params) == nil then
			clear += 1
		end
	end
	openness = clear / settings.rays
	return openness
end

-- What SoundConfig.Plan needs to know about the listener beyond the roof.
local function listening(own)
	return { own = own, open = Sfx.Openness() }
end

--------------------------------------------------------------------------------
-- Non-positional
--------------------------------------------------------------------------------

local pools = {}

local function ensurePool(name)
	if pools[name] then
		return pools[name]
	end

	local config = SoundConfig.Get(name)
	local layers = config and SoundConfig.LayersOf(config)
	if not layers then
		return nil
	end

	pools[name] = newPool(config.voices or POOL_SIZE, function()
		poolSizes["flat:" .. name] = (poolSizes["flat:" .. name] or 0) + 1
		return { voice = buildVoice(name, config, layers, SoundService, false, true) }
	end)
	return pools[name]
end

-- The next voice of a flat cue, played at distance 0 unless `plan` says otherwise. `own`: your own
-- play (Sfx.Play), which the burst cap never drops.
local function playFlat(name, pitchJitter, pitch, plan, gain, own)
	local config = SoundConfig.Get(name)
	if not config or not admit(name, config, own) then
		return
	end
	local pool = ensurePool(name)
	if not pool then
		return
	end
	local slot = takeSlot(pool)
	playVoice(slot.voice, pitchScale(name, config, pitchJitter, pitch), plan, gain * levelJitter(name, config))
end

-- `pitchJitter` keeps repeated cues from sounding mechanical. `pitch` overrides the cue's base
-- pitch, for rising sequences like the crate-opening tier climb. Your own gun indoors rings in
-- the room; outside it doesn't. `gain`, optional, scales this one play (a crouched step).
function Sfx.Play(name, pitchJitter, pitch, gain)
	local config = SoundConfig.Get(name)
	if not config then
		return
	end
	playFlat(name, pitchJitter, pitch, SoundConfig.Plan(name, config, 0, Sfx.IsEnclosed(), nil, listening(true)), gain or 1, true)
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
	local plan = SoundConfig.Plan(name, config, distance, Sfx.IsEnclosed(), nil, listening(false))
	-- Flat: its top end is already gone in the recipe, so no air on top.
	plan.low, plan.mid, plan.high = 0, 0, 0
	task.delay(plan.start, playFlat, name, pitchJitter, nil, plan, level, false)
end

--------------------------------------------------------------------------------
-- Positional
--------------------------------------------------------------------------------

-- Other people's gunfire. Sounds under an Attachment play from that point in the world, so you
-- can hear which direction a fight is in — the main way anyone finds one in a battle royale.
-- Pooled the same way; the attachments are just moved to each new shot.
local POSITIONAL_POOL_SIZE = Acoustics.VOICES.positional

local positionalPools = {}

local function ensurePositionalPool(name)
	if positionalPools[name] then
		return positionalPools[name]
	end

	local config = SoundConfig.Get(name)
	local layers = config and SoundConfig.LayersOf(config)
	if not layers then
		return nil
	end

	positionalPools[name] = newPool(config.voices or POSITIONAL_POOL_SIZE, function()
		poolSizes["positional:" .. name] = (poolSizes["positional:" .. name] or 0) + 1
		local attachment = Instance.new("Attachment")
		attachment.Name = "Sfx_" .. name
		-- Terrain sits at the origin, so an attachment's Position under it is its world position.
		attachment.Parent = workspace.Terrain
		return { attachment = attachment, voice = buildVoice(name, config, layers, attachment, true, true) }
	end)
	return positionalPools[name]
end

-- The voice is picked and moved when the sound ARRIVES, not when it was made: a far shot waits
-- for its travel time first, so a voice is taken only once its play is due.
local function arriveAt(name, position, scale, plan, gain)
	local config = SoundConfig.Get(name)
	if not config or not admit(name, config, false) then
		return
	end
	local pool = ensurePositionalPool(name)
	if not pool then
		return
	end
	local entry = takeSlot(pool)
	entry.attachment.Position = position
	playVoice(entry.voice, scale, plan, (gain or 1) * levelJitter(name, config))
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
-- `gain`, optional, scales this one play (a crouched or sprinting step).
function Sfx.PlayAt(name, position, pitchJitter, towards, gain)
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
		-- A big gun or blast past its own reach is still heard, as its far thump, flat.
		if type(config.distant) == "table" and config.distant.cue then
			Sfx.PlayDistant(config.distant.cue, position, pitchJitter, config.distant.gain or 1)
		end
		return
	end

	local nearPath = nil
	if typeof(towards) == "Vector3" then
		local miss = missDistance(listener, position, towards)
		nearPath = miss <= Acoustics.CRACK_REACH
		-- A real bullet that only just misses you whizzes past your ear as it arrives: a firearm's
		-- (not a bubble's), from far enough off that the report isn't already on top of it.
		local whiz = Acoustics.WHIZ
		if config.calibre and miss <= whiz.reach and distance >= whiz.minRange then
			task.delay(distance / Acoustics.BULLET_SPEED, Sfx.Play, "BulletWhiz")
		end
	end
	local plan = SoundConfig.Plan(name, config, distance, Sfx.IsEnclosed(), nearPath, listening(false))
	local scale = pitchScale(name, config, pitchJitter, nil)
	if plan.start > 0.005 then
		task.delay(plan.start, arriveAt, name, position, scale, plan, gain)
	else
		arriveAt(name, position, scale, plan, gain)
	end

	-- A big blast far enough off that its crack is fading gets its rumble underneath.
	if plan.distant > 0 and type(config.distant) == "table" and config.distant.cue then
		Sfx.PlayDistant(config.distant.cue, position, pitchJitter, plan.distant)
	end
end

--------------------------------------------------------------------------------
-- The ear after a close blast
--------------------------------------------------------------------------------

-- A big blast close by muffles everything for a moment: the top end of the Weapons and Effects
-- groups drops by up to Acoustics.DUCK's gains and eases back over its `hold`. `strength` 0..1
-- (1 = at the blast). A second blast while ducked only ever deepens it. The interface is left alone.
local duckStrength = 0
local duckConnection = nil

local function applyDuck(level)
	local duck = Acoustics.DUCK
	for _, ducker in pairs(duckers) do
		ducker.Enabled = level > 0
		ducker.MidGain = duck.mid * level
		ducker.HighGain = duck.high * level
	end
end

function Sfx.Duck(strength)
	strength = math.clamp(tonumber(strength) or 0, 0, 1)
	groupFor({ category = "Weapons" })
	groupFor({ category = "Effects" })
	if strength <= duckStrength then
		return
	end
	duckStrength = strength
	applyDuck(duckStrength)
	if not duckConnection then
		duckConnection = game:GetService("RunService").Heartbeat:Connect(function(dt)
			duckStrength = math.max(0, duckStrength - dt / Acoustics.DUCK.hold)
			applyDuck(duckStrength)
			if duckStrength <= 0 and duckConnection then
				duckConnection:Disconnect()
				duckConnection = nil
			end
		end)
	end
end

function Sfx.DuckLevel()
	return duckStrength
end

-- Debris is only worth a voice this close to the blast.
local DEBRIS_REACH = 200

-- A whole explosion: the blast cue itself (with its far rumble past its reach), what it throws down
-- off the surface it went off against (SoundConfig.DebrisCue), and, right beside a big one, the
-- muffle and ring (Acoustics.DUCK). A novelty blast (a party popper, a slipper) is only its own cue.
-- `normal` is the surface's (up if unknown); `radius` the blast's, in studs.
function Sfx.Blast(name, position, normal, radius)
	local config = SoundConfig.Get(name)
	local camera = workspace.CurrentCamera
	if not config or not camera or typeof(position) ~= "Vector3" then
		return
	end
	Sfx.PlayAt(name, position, SoundConfig.JitterOf(name, config))
	if config.novelty then
		return
	end
	local distance = (camera.CFrame.Position - position).Magnitude
	if config.blast and distance <= DEBRIS_REACH then
		local up = typeof(normal) == "Vector3" and normal or Vector3.new(0, 1, 0)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {}
		params.IgnoreWater = false
		local hit = workspace:Raycast(position + up * 2, up * -6, params)
		local debris = hit and SoundConfig.DebrisCue(hit.Material and hit.Material.Name or "Concrete")
		if debris then
			Sfx.PlayAt(debris, position, nil)
		end
	end
	local duck = Acoustics.DUCK
	radius = tonumber(radius) or 0
	if config.duck and radius >= duck.minRadius and distance < radius * duck.reach then
		local strength = 1 - distance / (radius * duck.reach)
		Sfx.Duck(strength)
		Sfx.Play("BlastRing", 0, nil, strength)
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
function Sfx.PoolSizes()
	return poolSizes
end

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
