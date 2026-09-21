-- What audio the client actually ships.
--
-- Run with: runtest.ps1 -Probe tools/sound_probe.lua
--
-- SoundConfig's cues are built out of the Roblox client's own content/sounds folder. That folder
-- has shrunk over the years, and when it did, two cues pointed at files that no longer existed
-- and silently stopped playing. So this measures rather than trusts: every candidate path is
-- loaded and its length read back, the paths SoundConfig uses right now are checked as a
-- regression guard, and every SoundEffect class the layered cues rely on is instantiated.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(...)
	print(string.format("[BRR_Sound] " .. select(1, ...), select(2, ...)))
end

--------------------------------------------------------------------------------
-- Candidates
--------------------------------------------------------------------------------

-- The eleven SoundConfig's header claims are all that remain, plus paths this project (or
-- Roblox) used historically, to find anything still shipping that the cues could be using.
local CANDIDATES = {
	"rbxasset://sounds/action_falling.mp3",
	"rbxasset://sounds/action_footsteps_plastic.mp3",
	"rbxasset://sounds/action_get_up.mp3",
	"rbxasset://sounds/action_jump.mp3",
	"rbxasset://sounds/action_jump_land.mp3",
	"rbxasset://sounds/action_swim.mp3",
	"rbxasset://sounds/impact_explosion_03.mp3",
	"rbxasset://sounds/impact_water.mp3",
	"rbxasset://sounds/oof.ogg",
	"rbxasset://sounds/ouch.ogg",
	"rbxasset://sounds/volume_slider.ogg",
	-- Historical / speculative: present on some clients, gone from others.
	"rbxasset://sounds/electronicpingshort.wav",
	"rbxasset://sounds/switch.wav",
	"rbxasset://sounds/switch3.wav",
	"rbxasset://sounds/bass.wav",
	"rbxasset://sounds/clickfast.wav",
	"rbxasset://sounds/metal.ogg",
	"rbxasset://sounds/pop.mp3",
	"rbxasset://sounds/snap.mp3",
	"rbxasset://sounds/splash.mp3",
	"rbxasset://sounds/swoosh.wav",
	"rbxasset://sounds/hit.wav",
	"rbxasset://sounds/button.wav",
	"rbxasset://sounds/collide.wav",
	"rbxasset://sounds/uuhhh.mp3",
	"rbxasset://sounds/impact_explosion_02.mp3",
	"rbxasset://sounds/impact_generic.mp3",
	"rbxasset://sounds/action_swim_fast.mp3",
	"rbxasset://sounds/action_footsteps_grass.mp3",
	"rbxasset://sounds/getting_up.mp3",
}

local holder = Instance.new("Folder")
holder.Name = "BRR_SoundProbe"
holder.Parent = workspace

local sounds = {}
for _, path in ipairs(CANDIDATES) do
	local sound = Instance.new("Sound")
	sound.SoundId = path
	sound.Volume = 0
	sound.Parent = holder
	sounds[path] = sound
end

-- One batch preload; a missing asset doesn't throw, it just never loads.
local list = {}
for _, sound in pairs(sounds) do
	table.insert(list, sound)
end
local ok, err = pcall(function()
	ContentProvider:PreloadAsync(list)
end)
say("preload finished ok=%s%s", tostring(ok), ok and "" or (" err=" .. tostring(err)))

-- Length can land a moment after IsLoaded, so give it a few passes.
for _ = 1, 10 do
	local pending = 0
	for _, sound in pairs(sounds) do
		if sound.IsLoaded and sound.TimeLength <= 0 then
			pending += 1
		end
	end
	if pending == 0 then
		break
	end
	task.wait(0.3)
end

local present, missing = {}, {}
for _, path in ipairs(CANDIDATES) do
	local sound = sounds[path]
	local short = string.gsub(path, "rbxasset://sounds/", "")
	if sound.IsLoaded and sound.TimeLength > 0 then
		table.insert(present, string.format("%s %.2fs", short, sound.TimeLength))
	else
		table.insert(missing, string.format("%s(loaded=%s len=%.2f)", short, tostring(sound.IsLoaded), sound.TimeLength))
	end
end

say("PRESENT %d: %s", #present, table.concat(present, " | "))
say("MISSING %d: %s", #missing, table.concat(missing, " | "))

--------------------------------------------------------------------------------
-- Regression guard: every path SoundConfig uses today must be in PRESENT
--------------------------------------------------------------------------------

local SoundConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SoundConfig"))
local usedOk, usedBad, seen = 0, {}, {}
for name, cue in pairs(SoundConfig.Sounds) do
	local ids = {}
	if type(cue.id) == "string" then
		table.insert(ids, cue.id)
	end
	for _, layer in ipairs(cue.layers or {}) do
		if type(layer.id) == "string" then
			table.insert(ids, layer.id)
		end
	end
	if #ids == 0 then
		table.insert(usedBad, name .. "(no id)")
	end
	for _, id in ipairs(ids) do
		seen[id] = true
		local sound = sounds[id]
		if sound and sound.IsLoaded and sound.TimeLength > 0 then
			usedOk += 1
		else
			table.insert(usedBad, string.format("%s -> %s", name, id))
		end
	end
end
say("SoundConfig ids: %d resolve, %d broken%s", usedOk, #usedBad, #usedBad > 0 and (": " .. table.concat(usedBad, "; ")) or "")

local distinct = 0
for _ in pairs(seen) do
	distinct += 1
end
say("SoundConfig uses %d distinct source files across %d cues", distinct, (function()
	local n = 0
	for _ in pairs(SoundConfig.Sounds) do
		n += 1
	end
	return n
end)())

--------------------------------------------------------------------------------
-- Effect classes the layered cues want to use
--------------------------------------------------------------------------------

local carrier = Instance.new("Sound")
carrier.SoundId = CANDIDATES[7]
carrier.Parent = holder

local effectOk, effectBad = {}, {}
for _, className in ipairs({
	"PitchShiftSoundEffect", "DistortionSoundEffect", "EqualizerSoundEffect", "ReverbSoundEffect",
	"TremoloSoundEffect", "FlangeSoundEffect", "ChorusSoundEffect", "CompressorSoundEffect",
	"EchoSoundEffect",
}) do
	local created, effect = pcall(function()
		local instance = Instance.new(className)
		instance.Parent = carrier
		return instance
	end)
	if created and effect then
		table.insert(effectOk, className)
	else
		table.insert(effectBad, className)
	end
end
say("effects available %d: %s", #effectOk, table.concat(effectOk, ", "))
if #effectBad > 0 then
	say("effects UNAVAILABLE: %s", table.concat(effectBad, ", "))
end

holder:Destroy()
say("done")
