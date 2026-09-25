-- Audio cues.
--
-- There is no uploaded audio in this project, so every cue is built out of the sound files the
-- Roblox client itself ships, under `rbxasset://sounds/`. `tools/sound_probe.lua` loads each
-- candidate and reads its length back, which is how this list is known rather than guessed —
-- an earlier version of this file believed only eleven files survived and pointed two cues at
-- paths that no longer existed, so they silently played nothing. Twenty-three resolve today:
--
--   action_falling 10.00  action_footsteps_plastic 2.48  action_get_up 0.57  action_jump 0.34
--   action_jump_land 0.26  action_swim 4.88  impact_explosion_02 2.12  impact_explosion_03 2.59
--   impact_water 2.38  oof 0.33  ouch 0.33  volume_slider 0.85  electronicpingshort 0.72
--   switch 0.24  switch3 0.37  bass 1.01  clickfast 0.29  metal 0.60  snap 0.42  hit 0.84
--   button 0.58  collide 1.20  uuhhh 0.33
--
-- A cue is a recipe, not a file: `layers` stack several of those sources at their own pitch,
-- volume and start delay, and `effects` runs the result through Roblox's SoundEffect chain. That
-- is what turns a stock click into a gunshot with a transient and a body, or a mag change into
-- two distinct mechanical noises a beat apart. A single-file cue can still be written the old
-- way with `id`.
--
-- To use real audio instead, put a Creator Marketplace id ("rbxassetid://123456") in a layer's
-- `id` and drop the extra layers; nothing outside this file needs to change. `maxDistance` only
-- applies to positional playback (Sfx.PlayAt), which is how you hear other people's gunfire.
-- How distance, travel time and indoors/outdoors change a cue is in the Acoustics section at the
-- bottom (#120); `tools/sound_acoustics_check.py` holds it to its rules.

local SoundConfig = {}

local FALL = "rbxasset://sounds/action_falling.mp3"
local STEPS = "rbxasset://sounds/action_footsteps_plastic.mp3"
local GETUP = "rbxasset://sounds/action_get_up.mp3"
local JUMP = "rbxasset://sounds/action_jump.mp3"
local LAND = "rbxasset://sounds/action_jump_land.mp3"
local SWIM = "rbxasset://sounds/action_swim.mp3"
local BOOM2 = "rbxasset://sounds/impact_explosion_02.mp3"
local BOOM3 = "rbxasset://sounds/impact_explosion_03.mp3"
local WATER = "rbxasset://sounds/impact_water.mp3"
local OOF = "rbxasset://sounds/oof.ogg"
local OUCH = "rbxasset://sounds/ouch.ogg"
local SLIDER = "rbxasset://sounds/volume_slider.ogg"
local PING = "rbxasset://sounds/electronicpingshort.wav"
local SWITCH = "rbxasset://sounds/switch.wav"
local SWITCH3 = "rbxasset://sounds/switch3.wav"
local BASS = "rbxasset://sounds/bass.wav"
local CLICK = "rbxasset://sounds/clickfast.wav"
local METAL = "rbxasset://sounds/metal.ogg"
local SNAP = "rbxasset://sounds/snap.mp3"
local HIT = "rbxasset://sounds/hit.wav"
local BUTTON = "rbxasset://sounds/button.wav"
local COLLIDE = "rbxasset://sounds/collide.wav"
local UUH = "rbxasset://sounds/uuhhh.mp3"

-- `category` picks the volume slider in Settings that controls the cue: Weapons, Effects or
-- Interface (each also scaled by Master).
SoundConfig.Sounds = {
	--------------------------------------------------------------------------------
	-- Guns
	--------------------------------------------------------------------------------

	-- A shot is a crack and a body: a sharp transient off the top of `snap`, then a short burst
	-- of explosion under it for weight. Compressed so it stays punchy at a distance, with enough
	-- distortion to give it teeth without turning to mush.
	-- UNUSED: nothing plays "Gunshot" any more. Every gun plays a family report below
	-- (CombatClient's SHOT_CUE / SHOT_CUE_BY_ID), and the fallback for an unmapped gun is
	-- GunshotRifle. Kept as the original recipe for reference.
	Gunshot = {
		calibre = "rifle",
		volume = 0.415,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.45 },
			{ id = BOOM2, volume = 0.55, pitch = 2.4 },
			{ id = CLICK, volume = 0.35, pitch = 0.8, delay = 0.02 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.16 } },
			{ "CompressorSoundEffect", { Threshold = -22, Ratio = 5, Attack = 0.002, Release = 0.12 } },
		},
	},

	-- Your shot landed: a short high tick, deliberately thin so it cuts through the shot itself -- and
	-- quieter than the shot (tools/sound_polish_check.py: hit feedback sits under a rifle's report).
	HitConfirm = {
		volume = 0.36,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 1, pitch = 1.9 },
			{ id = SWITCH, volume = 0.5, pitch = 1.6 },
		},
	},

	-- A headshot, for the shooter: the hit tick with a bell over it so it reads as better.
	Headshot = {
		volume = 0.4,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 1, pitch = 1.75 },
			{ id = CLICK, volume = 0.6, pitch = 2 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 6, MidGain = -2, LowGain = -14 } } },
	},

	-- The crack everyone near it hears on a headshot.
	HeadshotCrack = {
		volume = 0.38,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 1, pitch = 1.35 },
			{ id = SNAP, volume = 0.7, pitch = 1.7 },
		},
	},

	-- And what it sounds like from the wrong end.
	HeadshotTaken = {
		volume = 0.8,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = OUCH, volume = 1, pitch = 0.82 },
			{ id = HIT, volume = 0.6, pitch = 0.7 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 6, MidGain = 0, HighGain = -6 } } },
	},

	-- A magazine change: the catch, then the fresh mag seating a beat later.
	Reload = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH, volume = 1, pitch = 0.85 },
			{ id = METAL, volume = 0.7, pitch = 1.3, delay = 0.14 },
			{ id = CLICK, volume = 0.8, pitch = 0.75, delay = 0.3 },
		},
	},

	-- Each kind of gun's report. Every one is built from the same four jobs, weighted differently so
	-- the families are told apart by ear -- positionally, that's how you know what is shooting at you:
	--   crack  the transient: `snap` pitched up (higher = smaller, snappier gun), with `hit` or `click`
	--          under it for a punchier edge;
	--   body   an explosion file pitched up hard. PlaybackSpeed shortens as well as raises it, so the
	--          pitch sets how long the boom lasts: ~3x is a pistol's pop, ~1x a cannon's roll;
	--   weight `bass` -- how much chest the shot has;
	--   tail   reverb, or a late quiet layer, for the big guns that should ring out.
	-- Rapid-fire families (SMG, rotary) keep short bodies and less low end so a long burst stays a
	-- rattle instead of turning to mush; single-shot heavies get the longest tails.
	GunshotPistol = {
		calibre = "pistol",
		-- Crisp and dry: a bright crack, a short pop of body, almost no tail.
		volume = 0.34,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.75 },
			{ id = HIT, volume = 0.35, pitch = 1.6 },
			{ id = BOOM2, volume = 0.35, pitch = 3.0 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.12 } },
			{ "CompressorSoundEffect", { Threshold = -22, Ratio = 5, Attack = 0.002, Release = 0.08 } },
			{ "EqualizerSoundEffect", { LowGain = -3, MidGain = 1, HighGain = 3 } },
		},
	},
	-- The SMGs: the lightest, shortest report in the game, so 11-14 rounds a second reads as a
	-- chatter rather than a smear.
	GunshotSMG = {
		calibre = "smg",
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.95 },
			{ id = CLICK, volume = 0.35, pitch = 1.5 },
			{ id = BOOM2, volume = 0.28, pitch = 3.4 },
		},
		effects = {
			{ "CompressorSoundEffect", { Threshold = -22, Ratio = 5, Attack = 0.002, Release = 0.06 } },
			{ "EqualizerSoundEffect", { LowGain = -6, MidGain = 0, HighGain = 2 } },
		},
	},
	-- A revolver is a big round from a short barrel: a hand-cannon boom with a short room ring.
	GunshotRevolver = {
		calibre = "revolver",
		volume = 0.342,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.25 },
			{ id = BOOM2, volume = 0.7, pitch = 1.9 },
			{ id = BASS, volume = 0.45, pitch = 1.7 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.18 } },
			{ "ReverbSoundEffect", { DecayTime = 0.9, WetLevel = -13, DryLevel = 0 } },
		},
	},
	GunshotRifle = {
		calibre = "rifle",
		-- Crack plus a mid body and a little chest, and a faint metallic ring off the receiver.
		volume = 0.396,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.4, crack = true },
			{ id = BOOM2, volume = 0.65, pitch = 2.2 },
			{ id = BASS, volume = 0.35, pitch = 2.4 },
			{ id = METAL, volume = 0.12, pitch = 2.6, delay = 0.02 },
			-- Out in the open the report comes back off the terrain a quarter of a second later.
			{ id = BOOM3, volume = 0.12, pitch = 0.95, delay = 0.25, where = "outdoor" },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.2 } },
			{ "CompressorSoundEffect", { Threshold = -22, Ratio = 5, Attack = 0.002, Release = 0.12 } },
		},
	},
	-- A battle-rifle round from a long barrel: more body than a rifle, a room-sized tail.
	GunshotDMR = {
		calibre = "dmr",
		volume = 0.442,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.2, crack = true },
			{ id = BOOM2, volume = 0.8, pitch = 1.7 },
			{ id = BASS, volume = 0.5, pitch = 1.5 },
			{ id = BOOM3, volume = 0.18, pitch = 0.8, delay = 0.3, where = "outdoor" },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.2 } },
			{ "ReverbSoundEffect", { DecayTime = 1.3, WetLevel = -10, DryLevel = 0 } },
		},
	},
	-- Belt-fed: a rifle's crack over more weight, dirtier, for long bursts at a steadier rate.
	GunshotLMG = {
		calibre = "lmg",
		volume = 0.43,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.95, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 1.9 },
			{ id = BASS, volume = 0.45, pitch = 1.9 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.26 } },
			{ "CompressorSoundEffect", { Threshold = -21, Ratio = 5, Attack = 0.002, Release = 0.1 } },
		},
	},
	-- Squeezing the trigger on an empty gun: the hammer or striker falling on nothing.
	DryFire = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 0.9, pitch = 1.25 },
			{ id = SWITCH, volume = 0.3, pitch = 1.9 },
		},
	},
	GunshotHeavy = {
		calibre = "rotary",
		-- The chaingun at 13 a second: each shot short and tight so the stream is a buzz-saw roar, the
		-- weight carried by the bass rather than a long body, the top end shaved so it doesn't tire you.
		volume = 0.465,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.85, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.5, pitch = 2.8 },
			{ id = BASS, volume = 0.4, pitch = 2.6 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.28 } },
			{ "EqualizerSoundEffect", { LowGain = 2, MidGain = 0, HighGain = -2 } },
		},
	},
	GunshotShotgun = {
		calibre = "shotgun",
		-- Mostly boom: a wide explosion body, a lower crack, a thump of bass and a short room tail.
		-- Pitched lower than any rifle: a 12-bore's muzzle blast comes out of a wide bore at low
		-- pressure, so its energy sits an octave or so under a rifle's, and the shot is subsonic, so
		-- there is no separate crack.
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.45 },
			{ id = SNAP, volume = 0.75, pitch = 0.85 },
			{ id = BASS, volume = 0.7, pitch = 1.1 },
			{ id = COLLIDE, volume = 0.25, pitch = 1.6 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.26 } },
			{ "CompressorSoundEffect", { Threshold = -20, Ratio = 6, Attack = 0.003, Release = 0.18 } },
			{ "ReverbSoundEffect", { DecayTime = 0.7, WetLevel = -16, DryLevel = 0 } },
		},
	},
	GunshotSniper = {
		calibre = "sniper",
		-- The loudest single crack in the game, a heavy body, and a long outdoor roll: a quiet, slow
		-- second explosion a beat later, under a long reverb, so it is heard across the map.
		volume = 0.44,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.1, crack = true },
			{ id = BOOM2, volume = 0.95, pitch = 1.4 },
			{ id = BASS, volume = 0.7, pitch = 0.8 },
			-- Outdoors the roll is the terrain answering: a slow second boom, then a fainter echo
			-- off something further away. Indoors the room reverb below replaces both.
			{ id = BOOM3, volume = 0.3, pitch = 0.9, delay = 0.08, where = "outdoor" },
			{ id = BOOM3, volume = 0.2, pitch = 0.7, delay = 0.5, where = "outdoor" },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.18 } },
			{ "ReverbSoundEffect", { DecayTime = 1.6, WetLevel = -6, DryLevel = 0 } },
		},
	},
	GunshotSuppressed = {
		calibre = "suppressed",
		-- A cough, not a crack: a thin high tick, the action cycling, a hiss of gas; lows cut.
		acoustic = "suppressed",
		volume = 0.38,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.35, pitch = 2.9 },
			{ id = CLICK, volume = 0.55, pitch = 1.4 },
			{ id = SLIDER, volume = 0.18, pitch = 2.6 },
			{ id = BUTTON, volume = 0.2, pitch = 1.2 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -12, MidGain = -3, HighGain = -2 } } },
	},
	GunshotRocket = {
		calibre = "launcher",
		-- A launch, not a bang: a deep whoomp out of the tube, the motor's whoosh, a thump and a tail.
		volume = 0.46,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 0.4, pitch = 0.7 },
			{ id = BOOM3, volume = 0.8, pitch = 1.2 },
			{ id = JUMP, volume = 0.85, pitch = 0.5 },
			{ id = FALL, volume = 0.3, pitch = 2.2 },
			{ id = BASS, volume = 0.65, pitch = 0.8 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.4, WetLevel = -9, DryLevel = 0 } } },
	},
	GunshotRail = {
		-- Delulu Railgun: electric, not gunpowder. A descending ping, a hard bright zap off the rails,
		-- a thump of discharge and a zip of charge, flanged so it shimmers. Loud: it carries.
		novelty = true,
		acoustic = "energy",
		volume = 0.44,
		pitch = 1,
		maxDistance = 700,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.85, pitch = 0.4 },
			{ id = SNAP, volume = 0.55, pitch = 2.6 },
			{ id = BASS, volume = 0.55, pitch = 2.0 },
			{ id = HIT, volume = 0.3, pitch = 2.2 },
			{ id = SLIDER, volume = 0.15, pitch = 3.0 },
		},
		effects = {
			{ "FlangeSoundEffect", { Depth = 0.6, Mix = 0.45, Rate = 9 } },
			{ "EqualizerSoundEffect", { LowGain = 0, MidGain = 0, HighGain = 3 } },
		},
	},
	GunshotBubble = {
		-- Bubble Blaster / Burster: bubbles, not bullets. A soft pop, a wet blorp, a springy wobble and
		-- a soapy whoosh, chorused so it shimmers. No crack, no echo tail, no casing.
		novelty = true,
		foley = "water",
		volume = 0.4,
		pitch = 1,
		maxDistance = 220,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.45, pitch = 2.2 },
			{ id = WATER, volume = 0.55, pitch = 2.5 },
			{ id = JUMP, volume = 0.3, pitch = 2.1 },
			{ id = SLIDER, volume = 0.18, pitch = 1.6, delay = 0.02 },
			{ id = SNAP, volume = 0.2, pitch = 3.3 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.2, Mix = 0.4, Rate = 3 } } },
	},
	GunshotCrossbow = {
		novelty = true,
		-- A twang: a slow low snap for the string, a buzz as it settles, the thunk of the stock.
		-- A bow has no muzzle blast, so it carries like a suppressed gun, not a loud one.
		acoustic = "suppressed",
		volume = 0.45,
		pitch = 1,
		maxDistance = 160,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.95, pitch = 0.55 },
			{ id = SLIDER, volume = 0.35, pitch = 0.75, delay = 0.02 },
			{ id = COLLIDE, volume = 0.35, pitch = 2.1 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 3, MidGain = 0, HighGain = -2 } } },
	},
	GunshotCannon = {
		calibre = "cannon",
		-- The biggest report there is: a slow full-length explosion, a low crack, heavy bass, a second
		-- boom a beat behind for the muzzle blast, and a long tail.
		volume = 0.48,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 0.95 },
			{ id = SNAP, volume = 0.85, pitch = 0.85 },
			{ id = BASS, volume = 0.8, pitch = 0.72 },
			{ id = BOOM2, volume = 0.4, pitch = 1.1, delay = 0.04 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.2 } },
			{ "ReverbSoundEffect", { DecayTime = 2.0, WetLevel = -7, DryLevel = 0 } },
		},
	},

	-- The creative guns (CreativeArsenal): each report is its object first and a gun second, but
	-- still short and loud enough to place positionally in a fight.
	GunshotSqueak = {
		-- Squeaky Duck Popper: a rubber squeak (a voice pitched right up) on a small plastic pop.
		novelty = true,
		foley = "toy",
		volume = 0.4,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = OOF, volume = 0.4, pitch = 2.6 },
			{ id = BUTTON, volume = 0.4, pitch = 2.4 },
			{ id = CLICK, volume = 0.35, pitch = 1.4 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.15, Mix = 0.35, Rate = 5 } } },
	},
	GunshotSquirt = {
		novelty = true,
		foley = "water",
		-- Juice Box Squirter: a pressurised psst and a short splash, no bang at all.
		volume = 0.36,
		pitch = 1,
		maxDistance = 220,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.5, pitch = 3.0 },
			{ id = SLIDER, volume = 0.2, pitch = 3.0 },
			{ id = CLICK, volume = 0.3, pitch = 1.8 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -8, MidGain = 0, HighGain = 2 } } },
	},
	GunshotNoodle = {
		-- Spaghetti Slinger: a colander of wet noodles flung hard. A sloppy splat, the thwap of a
		-- handful landing, a plop and a swish; heavy enough to place, but no bang in it.
		novelty = true,
		foley = "toy",
		volume = 0.42,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.6, pitch = 1.4 },
			{ id = LAND, volume = 0.55, pitch = 0.8 },
			{ id = HIT, volume = 0.35, pitch = 0.9 },
			{ id = SLIDER, volume = 0.2, pitch = 1.2 },
			{ id = BASS, volume = 0.25, pitch = 1.6 },
		},
	},
	GunshotBassDrop = {
		-- Boombox Bassline: the drop. A distorted sub thump, a kick drum, a tape clunk, a quick echo.
		novelty = true,
		foley = "toy",
		volume = 0.46,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.6 },
			{ id = HIT, volume = 0.45, pitch = 0.5 },
			{ id = JUMP, volume = 0.6, pitch = 0.5 },
			{ id = SWITCH3, volume = 0.3, pitch = 0.5 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.35 } },
			{ "EqualizerSoundEffect", { LowGain = 6, MidGain = 0, HighGain = -4 } },
			{ "EchoSoundEffect", { Delay = 0.12, Feedback = 0.3, WetLevel = -8, DryLevel = 0 } },
		},
	},
	GunshotGumball = {
		-- Gumball Gatling: the crank's plastic clack, a gumball bouncing off, fast and light for 12 a second.
		novelty = true,
		foley = "toy",
		volume = 0.32,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.6, pitch = 1.2 },
			{ id = COLLIDE, volume = 0.4, pitch = 2.4 },
			{ id = HIT, volume = 0.3, pitch = 2.0 },
			{ id = CLICK, volume = 0.3, pitch = 1.0 },
		},
	},
	GunshotFidget = {
		-- Fidget Disc Launcher: a whirr spinning up, a ping, the flick of the disc leaving, flanged.
		novelty = true,
		foley = "toy",
		volume = 0.42,
		pitch = 1,
		maxDistance = 400,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.5, pitch = 2.0 },
			{ id = PING, volume = 0.3, pitch = 1.8 },
			{ id = CLICK, volume = 0.4, pitch = 2.2 },
			{ id = SWITCH3, volume = 0.25, pitch = 1.6 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.4, Rate = 12 } } },
	},
	GunshotZap = {
		novelty = true,
		foley = "toy",
		-- Microwave Zapper: an electric buzz (a tremolo at mains-hum speed), a beep, a zap.
		acoustic = "energy",
		volume = 0.36,
		pitch = 1,
		maxDistance = 340,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.7, pitch = 0.55 },
			{ id = BASS, volume = 0.4, pitch = 2.6 },
			{ id = SLIDER, volume = 0.25, pitch = 2.8 },
			{ id = BUTTON, volume = 0.2, pitch = 2.8 },
		},
		effects = { { "TremoloSoundEffect", { Depth = 0.6, Duty = 0.5, Frequency = 30 } } },
	},
	GunshotPizza = {
		novelty = true,
		-- Pizza Cutter Crossbow: the crossbow's twang with a blade ringing off it.
		volume = 0.45,
		pitch = 1,
		maxDistance = 180,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.95, pitch = 0.55 },
			{ id = SLIDER, volume = 0.35, pitch = 0.75, delay = 0.02 },
			{ id = METAL, volume = 0.35, pitch = 2.4 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 2, MidGain = 0, HighGain = 1 } } },
	},
	GunshotDisco = {
		-- Disco Ball Deleter: a bright ping and a bass hit, shimmering (chorus and a slow flange).
		novelty = true,
		foley = "toy",
		volume = 0.36,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.6, pitch = 1.2 },
			{ id = BASS, volume = 0.5, pitch = 1.4 },
			{ id = SNAP, volume = 0.35, pitch = 2.8 },
		},
		effects = {
			{ "ChorusSoundEffect", { Depth = 0.3, Mix = 0.5, Rate = 2 } },
			{ "FlangeSoundEffect", { Depth = 0.4, Mix = 0.3, Rate = 4 } },
		},
	},
	GunshotToaster = {
		-- Toaster Mortar: the pop-up spring, the thunk of the toast leaving the tube, and a "ding".
		novelty = true,
		foley = "toy",
		volume = 0.46,
		pitch = 1,
		maxDistance = 520,
		category = "Weapons",
		layers = {
			{ id = JUMP, volume = 0.8, pitch = 0.45 },
			{ id = SWITCH3, volume = 0.6, pitch = 0.6 },
			{ id = LAND, volume = 0.5, pitch = 0.6 },
			{ id = BASS, volume = 0.3, pitch = 1.2 },
			{ id = PING, volume = 0.3, pitch = 1.6, delay = 0.1 },
		},
	},
	GunshotChicken = {
		-- Rubber Chicken Railgun: the rail's electric zap, and the chicken screaming over it.
		novelty = true,
		foley = "toy",
		volume = 0.46,
		pitch = 1,
		maxDistance = 700,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.8, pitch = 0.4 },
			{ id = SNAP, volume = 0.5, pitch = 2.8 },
			{ id = BASS, volume = 0.5, pitch = 2.0 },
			{ id = UUH, volume = 0.55, pitch = 1.7, delay = 0.02 },
			{ id = OOF, volume = 0.3, pitch = 2.2, delay = 0.02 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.35, Rate = 9 } } },
	},
	GunshotLavaLamp = {
		-- Lava Lamp Lancer: a lamp, not a rifle. A deep liquid bloop of wax, a glassy thunk from the
		-- globe and a warm hum under it. Its reverb is part of the bloop, not a room.
		novelty = true,
		foley = "water",
		tail = "always",
		volume = 0.42,
		pitch = 1,
		maxDistance = 450,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.5, pitch = 0.8 },
			{ id = HIT, volume = 0.5, pitch = 0.7 },
			{ id = BASS, volume = 0.5, pitch = 0.8 },
			{ id = JUMP, volume = 0.3, pitch = 0.6 },
			{ id = PING, volume = 0.12, pitch = 0.9 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.1, WetLevel = -11, DryLevel = 0 } } },
	},
	GunshotSnow = {
		novelty = true,
		foley = "water",
		-- Snow Globe Singularity: a soft crack, a glassy tinkle and a hush of snow, bright and cold.
		tail = "always",
		volume = 0.38,
		pitch = 1,
		maxDistance = 380,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.35, pitch = 2.6 },
			{ id = PING, volume = 0.3, pitch = 2.8 },
			{ id = WATER, volume = 0.25, pitch = 1.8 },
			{ id = SLIDER, volume = 0.15, pitch = 1.8 },
		},
		effects = {
			{ "EqualizerSoundEffect", { LowGain = -6, MidGain = 0, HighGain = 3 } },
			{ "ReverbSoundEffect", { DecayTime = 0.8, WetLevel = -12, DryLevel = 0 } },
		},
	},
	GunshotSlipper = {
		novelty = true,
		foley = "toy",
		-- Grandma's Slipper Launcher: a spring twang and a soft thwap, with a disapproving grunt.
		volume = 0.44,
		pitch = 1,
		maxDistance = 200,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.5 },
			{ id = COLLIDE, volume = 0.5, pitch = 1.2 },
			{ id = SLIDER, volume = 0.3, pitch = 0.6 },
			{ id = UUH, volume = 0.3, pitch = 1.2, delay = 0.05 },
		},
	},

	-- The signature guns (GunModelsSignature, the gun rework): the older arsenal rebuilt with its own looks, and
	-- a report to match each one. Every report keeps its family's weight -- a pistol stays a pistol's crack, a
	-- shotgun a shotgun's boom -- so positional hearing still tells you what is shooting; the object is laid
	-- over the top. The model names its cue (attribute ShotCue), so CombatClient needs no entry per gun.
	GunshotTung = {
		calibre = "pistol",
		-- Sahur Pistol: a pistol's crack with a hollow wooden knock in it, the drummer's "tok".
		volume = 0.36,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.6 },
			{ id = HIT, volume = 0.55, pitch = 0.62 },
			{ id = COLLIDE, volume = 0.35, pitch = 0.8 },
			{ id = BOOM2, volume = 0.3, pitch = 3.0 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 2, MidGain = 2, HighGain = -1 } } },
	},
	GunshotPopcorn = {
		calibre = "pistol",
		-- Pocket Popper: a bright pop with a kernel bursting a beat behind it.
		volume = 0.329,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.9 },
			{ id = BUTTON, volume = 0.45, pitch = 1.7 },
			{ id = BOOM2, volume = 0.28, pitch = 3.2 },
			{ id = SNAP, volume = 0.35, pitch = 2.6, delay = 0.05 },
		},
		effects = { { "CompressorSoundEffect", { Threshold = -22, Ratio = 5, Attack = 0.002, Release = 0.08 } } },
	},
	GunshotPistachio = {
		calibre = "pistol",
		-- Pistacchio Pum: a dry pistol shot with a shell cracking open in the transient.
		volume = 0.35,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.45 },
			{ id = CLICK, volume = 0.5, pitch = 0.9 },
			{ id = BOOM2, volume = 0.35, pitch = 2.8 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.1 } } },
	},
	GunshotRot = {
		calibre = "suppressed",
		-- Rot SMG: the can suppressor's cough, and something wet in it.
		acoustic = "suppressed",
		volume = 0.38,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.3, pitch = 2.6 },
			{ id = CLICK, volume = 0.5, pitch = 1.2 },
			{ id = WATER, volume = 0.22, pitch = 1.6 },
			{ id = SLIDER, volume = 0.14, pitch = 2.2 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -10, MidGain = -2, HighGain = -3 } } },
	},
	GunshotCrumb = {
		calibre = "rifle",
		-- Crumbly Carbine: a light rifle crack with a crunch through the middle of it.
		volume = 0.409,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.5, crack = true },
			{ id = COLLIDE, volume = 0.4, pitch = 2.2 },
			{ id = BOOM2, volume = 0.55, pitch = 2.4 },
			{ id = BOOM3, volume = 0.1, pitch = 0.95, delay = 0.25, where = "outdoor" },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.16 } } },
	},
	GunshotClonk = {
		calibre = "shotgun",
		-- Ciabatta Clonk: a shotgun's boom with the heavy metal clonk of the old security action under it.
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.4 },
			{ id = SNAP, volume = 0.7, pitch = 0.8 },
			{ id = METAL, volume = 0.35, pitch = 0.7, delay = 0.03 },
			{ id = BASS, volume = 0.6, pitch = 1.05 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.24 } },
			{ "ReverbSoundEffect", { DecayTime = 0.7, WetLevel = -16, DryLevel = 0 } },
		},
	},
	GunshotCroc = {
		calibre = "rifle",
		-- Crocodilo Rifle: an AK's heavy crack, and the jaws snapping shut on it.
		volume = 0.38,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 2.0 },
			{ id = COLLIDE, volume = 0.45, pitch = 1.3, delay = 0.02 },
			{ id = BOOM3, volume = 0.12, pitch = 0.9, delay = 0.25, where = "outdoor" },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.22 } } },
	},
	GunshotShark = {
		calibre = "shotgun",
		-- Tralala Shotgun: the pump's boom with a splash through it.
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.45 },
			{ id = SNAP, volume = 0.7, pitch = 0.85 },
			{ id = WATER, volume = 0.4, pitch = 1.2 },
			{ id = BASS, volume = 0.6, pitch = 1.1 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.24 } } },
	},
	GunshotLag = {
		calibre = "smg",
		-- Lag Switch SMG: a light SMG crack with a digital blip that stutters behind it.
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.95 },
			{ id = PING, volume = 0.18, pitch = 2.2 },
			{ id = BOOM2, volume = 0.26, pitch = 3.4 },
			{ id = PING, volume = 0.1, pitch = 2.2, delay = 0.04 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -6, MidGain = 0, HighGain = 2 } } },
	},
	GunshotScroll = {
		calibre = "smg",
		-- Scrolla Scrolla Brrrap: an SMG's chatter with a screen-tap click on every round.
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.9 },
			{ id = BUTTON, volume = 0.3, pitch = 2.2 },
			{ id = BOOM2, volume = 0.26, pitch = 3.3 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -6, MidGain = 0, HighGain = 2 } } },
	},
	GunshotTrail = {
		calibre = "rifle",
		-- Scarponcino Trotto Trotto: a carbine's crack that carries, and the valley answering.
		volume = 0.411,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.4, crack = true },
			{ id = BOOM2, volume = 0.6, pitch = 2.2 },
			{ id = BASS, volume = 0.3, pitch = 2.3 },
			{ id = BOOM3, volume = 0.2, pitch = 0.9, delay = 0.3, where = "outdoor" },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.18 } } },
	},
	GunshotBanana = {
		calibre = "rifle",
		-- Bananini Burst: a rifle's crack with a soft, squashy thump under it.
		volume = 0.402,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.45, crack = true },
			{ id = BOOM2, volume = 0.55, pitch = 2.3 },
			{ id = JUMP, volume = 0.35, pitch = 0.8 },
			{ id = BASS, volume = 0.3, pitch = 2.0 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.18 } } },
	},
	GunshotLawn = {
		calibre = "dmr",
		-- Grass Toucher DMR: a battle rifle's report, and the sprinkler's hiss after it.
		volume = 0.469,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.2, crack = true },
			{ id = BOOM2, volume = 0.8, pitch = 1.7 },
			{ id = SLIDER, volume = 0.2, pitch = 1.4, delay = 0.03 },
			{ id = BOOM3, volume = 0.18, pitch = 0.8, delay = 0.3, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.3, WetLevel = -10, DryLevel = 0 } } },
	},
	GunshotSigma = {
		calibre = "dmr",
		-- Sigma Scout: a marksman's report with the plates clanking on the bar.
		volume = 0.433,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.2, crack = true },
			{ id = BOOM2, volume = 0.8, pitch = 1.7 },
			{ id = METAL, volume = 0.35, pitch = 1.1, delay = 0.03 },
			{ id = BASS, volume = 0.45, pitch = 1.5 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.2, WetLevel = -11, DryLevel = 0 } } },
	},
	GunshotMeadow = {
		calibre = "dmr",
		-- Prato Prato Pium: a marksman's report, lighter, with a bright chime in its tail.
		volume = 0.494,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.25, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 1.8 },
			{ id = PING, volume = 0.14, pitch = 2.6, delay = 0.05 },
			{ id = BOOM3, volume = 0.16, pitch = 0.85, delay = 0.3, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.2, WetLevel = -11, DryLevel = 0 } } },
	},
	GunshotAura = {
		calibre = "shotgun",
		-- Aura Scattergun: a shotgun's boom with a shimmer of light ringing off it.
		volume = 0.448,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.45 },
			{ id = SNAP, volume = 0.7, pitch = 0.9 },
			{ id = PING, volume = 0.22, pitch = 1.5 },
			{ id = BASS, volume = 0.55, pitch = 1.1 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.22 } },
			{ "ChorusSoundEffect", { Depth = 0.25, Mix = 0.35, Rate = 3 } },
		},
	},
	GunshotGlitch = {
		calibre = "smg",
		-- Glitch SMG: an SMG's chatter that stutters -- a digital blip, then the shot again, smaller.
		volume = 0.33,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.9 },
			{ id = PING, volume = 0.2, pitch = 1.3 },
			{ id = BOOM2, volume = 0.26, pitch = 3.4 },
			{ id = SNAP, volume = 0.3, pitch = 2.3, delay = 0.03 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.35 } } },
	},
	GunshotVampire = {
		calibre = "lmg",
		-- Camelo Vampire LMG: a belt-fed's heavy report with a leathery wing-beat in its tail.
		volume = 0.414,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 2.0 },
			{ id = BASS, volume = 0.45, pitch = 1.6 },
			{ id = SLIDER, volume = 0.16, pitch = 0.5, delay = 0.04 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.24 } } },
	},
	GunshotBank = {
		calibre = "dmr",
		-- Six-Seven Marksman: a marksman's report with a hollow court-floor bounce under it.
		volume = 0.462,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.2, crack = true },
			{ id = BOOM2, volume = 0.8, pitch = 1.7 },
			{ id = JUMP, volume = 0.3, pitch = 0.7, delay = 0.03 },
			{ id = BOOM3, volume = 0.18, pitch = 0.8, delay = 0.3, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.3, WetLevel = -10, DryLevel = 0 } } },
	},
	GunshotRatio = {
		calibre = "suppressed",
		-- Piccolino Ratatatà: the suppressed cough and a phone's send-swoosh.
		acoustic = "suppressed",
		volume = 0.36,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.35, pitch = 2.9 },
			{ id = CLICK, volume = 0.5, pitch = 1.4 },
			{ id = SLIDER, volume = 0.22, pitch = 2.0 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -12, MidGain = -3, HighGain = -2 } } },
	},
	GunshotBreach = {
		calibre = "shotgun",
		-- Porta Porta Bonk: a shotgun's boom and a door slamming into the frame.
		volume = 0.457,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.4 },
			{ id = HIT, volume = 0.5, pitch = 0.5 },
			{ id = COLLIDE, volume = 0.4, pitch = 0.7, delay = 0.02 },
			{ id = BASS, volume = 0.6, pitch = 1.0 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.26 } } },
	},
	Ricochet = {
		-- A round glancing off a wall: a bright whine that falls away.
		volume = 0.34,
		pitch = 1,
		maxDistance = 260,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.5, pitch = 1.9 },
			{ id = SLIDER, volume = 0.3, pitch = 2.6 },
			{ id = METAL, volume = 0.2, pitch = 2.2 },
		},
	},
	GunshotRizz = {
		calibre = "rifle",
		-- Rizz Rifle: a rifle's crack with a bright, sweet ring behind it.
		volume = 0.419,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.45, crack = true },
			{ id = BOOM2, volume = 0.6, pitch = 2.2 },
			{ id = PING, volume = 0.18, pitch = 1.8, delay = 0.03 },
			{ id = BOOM3, volume = 0.12, pitch = 0.95, delay = 0.25, where = "outdoor" },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.2, Mix = 0.3, Rate = 3 } } },
	},
	GunshotReceipt = {
		calibre = "lmg",
		-- Scontrino Infinito: a belt-fed's report with the printer's chatter in every round.
		volume = 0.411,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 2.0 },
			{ id = CLICK, volume = 0.3, pitch = 2.6 },
			{ id = BASS, volume = 0.4, pitch = 1.6 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.22 } } },
	},
	GunshotForest = {
		calibre = "rotary",
		-- Patapim Chaingun: the rotary's roar with a rustle of leaves through it.
		volume = 0.45,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.6 },
			{ id = BOOM2, volume = 0.5, pitch = 2.6 },
			{ id = STEPS, volume = 0.25, pitch = 1.6 },
			{ id = BASS, volume = 0.3, pitch = 2.0 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -3, MidGain = 0, HighGain = 1 } } },
	},
	GunshotNonna = {
		calibre = "shotgun",
		-- Nonna Double Barrel: a big old boom and a disapproving click of the tongue.
		volume = 0.44,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.3 },
			{ id = SNAP, volume = 0.75, pitch = 0.8 },
			{ id = BASS, volume = 0.7, pitch = 1.0 },
			{ id = CLICK, volume = 0.3, pitch = 1.2, delay = 0.12 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 0.9, WetLevel = -14, DryLevel = 0 } } },
	},
	GunshotAudit = {
		calibre = "rifle",
		-- Occhietto Pium Pium: a clean rifle crack and a stamp coming down.
		volume = 0.411,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.45, crack = true },
			{ id = BOOM2, volume = 0.6, pitch = 2.2 },
			{ id = HIT, volume = 0.3, pitch = 0.8, delay = 0.02 },
			{ id = BOOM3, volume = 0.12, pitch = 0.95, delay = 0.25, where = "outdoor" },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.18 } } },
	},
	GunshotAdmin = {
		calibre = "pistol",
		-- Capo Supremo Bonkolone: a pistol's crack, bit-crushed, with a console blip.
		volume = 0.35,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.7 },
			{ id = PING, volume = 0.22, pitch = 2.0 },
			{ id = BOOM2, volume = 0.34, pitch = 3.0 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.4 } } },
	},
	GunshotCollect = {
		calibre = "rifle",
		-- Ultimo Bum: an AK's crack with a cash register's clunk.
		volume = 0.38,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.3, crack = true },
			{ id = BOOM2, volume = 0.7, pitch = 2.0 },
			{ id = METAL, volume = 0.3, pitch = 1.4, delay = 0.02 },
			{ id = BOOM3, volume = 0.12, pitch = 0.9, delay = 0.25, where = "outdoor" },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.22 } } },
	},
	GunshotPikpik = {
		novelty = true,
		-- Zanzarino Pikpik: a thin air-gun pfft and a mosquito's whine going away.
		acoustic = "suppressed",
		volume = 0.34,
		pitch = 1,
		maxDistance = 170,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.5, pitch = 2.6 },
			{ id = CLICK, volume = 0.25, pitch = 1.8 },
			{ id = SLIDER, volume = 0.22, pitch = 3.4, delay = 0.02 },
			{ id = PING, volume = 0.06, pitch = 3.8, delay = 0.04 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -8, MidGain = -2, HighGain = 2 } } },
	},
	GunshotTamburo = {
		-- Tamburo Tung Tung: the big bass drum -- a deep skin thump, the shell's boom, the snares' rattle.
		novelty = true,
		foley = "toy",
		volume = 0.44,
		pitch = 1,
		maxDistance = 420,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 0.9, pitch = 0.42 },
			{ id = BASS, volume = 0.8, pitch = 0.7 },
			{ id = LAND, volume = 0.45, pitch = 0.5 },
			{ id = SLIDER, volume = 0.18, pitch = 2.4, delay = 0.03 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 0.8, WetLevel = -12, DryLevel = 0 } } },
	},
	GunshotBoomerang = {
		novelty = true,
		-- Bananerang: a crossbow's twang, and the whup-whup of a boomerang cutting the air.
		acoustic = "suppressed",
		volume = 0.45,
		pitch = 1,
		maxDistance = 170,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.6 },
			{ id = SLIDER, volume = 0.4, pitch = 0.8, delay = 0.02 },
			{ id = SWIM, volume = 0.3, pitch = 1.6, delay = 0.05 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 2, MidGain = 0, HighGain = -1 } } },
	},

	-- The workshop guns (WorkshopArsenal): household things, not firearms, so each fires what it is.
	GunshotKeycap = {
		-- Rage Quit Carbine: a mechanical keyboard. One hard clack per keycap, the spring under it.
		novelty = true,
		foley = "toy",
		volume = 0.4,
		pitch = 1,
		maxDistance = 260,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 0.7, pitch = 1.1 },
			{ id = BUTTON, volume = 0.5, pitch = 1.4 },
			{ id = SWITCH, volume = 0.3, pitch = 1.8 },
			{ id = COLLIDE, volume = 0.15, pitch = 2.6 },
		},
	},
	GunshotBroom = {
		-- Clean Sweep Double: both barrels of bristles -- a hard swish and the thwack of the head.
		novelty = true,
		foley = "toy",
		volume = 0.45,
		pitch = 1,
		maxDistance = 280,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.45, pitch = 0.7 },
			{ id = LAND, volume = 0.6, pitch = 0.9 },
			{ id = STEPS, volume = 0.25, pitch = 1.6 },
			{ id = BASS, volume = 0.25, pitch = 1.4 },
		},
	},
	GunshotHose = {
		-- Hose Down Sniper: a lance of cold water -- the nozzle clicking open, a gush and a hiss.
		novelty = true,
		foley = "water",
		volume = 0.45,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.7, pitch = 1.1 },
			{ id = SLIDER, volume = 0.3, pitch = 1.3 },
			{ id = CLICK, volume = 0.3, pitch = 0.8 },
			{ id = SWIM, volume = 0.25, pitch = 1.8, delay = 0.03 },
		},
	},
	GunshotVacuum = {
		-- Dust Devil Rotary: a canister vacuum spitting dust bunnies, 12 a second -- a whirr of air and
		-- a soft thup per bunny, short so the stream stays a whine, not a smear.
		novelty = true,
		foley = "toy",
		volume = 0.45,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = FALL, volume = 0.25, pitch = 2.4 },
			{ id = BUTTON, volume = 0.4, pitch = 0.9 },
			{ id = SLIDER, volume = 0.2, pitch = 2.2 },
			{ id = LAND, volume = 0.25, pitch = 1.8 },
		},
	},
	GunshotBlower = {
		-- Yard Work Blower: a leaf blower's rush of air and a scatter of leaves, 10 a second.
		novelty = true,
		foley = "toy",
		volume = 0.45,
		pitch = 1,
		maxDistance = 320,
		category = "Weapons",
		layers = {
			{ id = FALL, volume = 0.35, pitch = 1.6 },
			{ id = STEPS, volume = 0.25, pitch = 2.0 },
			{ id = BASS, volume = 0.2, pitch = 2.4 },
			{ id = CLICK, volume = 0.2, pitch = 0.7 },
		},
	},
	GunshotPopper = {
		-- Party Foul Cannon: a party popper the size of a cannon -- a big cork POP, streamers
		-- ripping out and confetti pattering down.
		novelty = true,
		foley = "toy",
		volume = 0.46,
		pitch = 1,
		maxDistance = 420,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.7, pitch = 0.8 },
			{ id = HIT, volume = 0.5, pitch = 1.2 },
			{ id = JUMP, volume = 0.3, pitch = 1.3 },
			{ id = SWITCH3, volume = 0.3, pitch = 1.9 },
			{ id = STEPS, volume = 0.25, pitch = 2.4, delay = 0.04 },
		},
	},
	-- A far-off gun, heard from past its report's reach (Sfx.PlayAt hands over to this): the dull
	-- thump and roll that is all that crosses the map, flat, fading by distance, late by the time
	-- it takes to get here. Only the calibres with a `distant` in SoundConfig.Firearms reach it.
	DistantGunfire = {
		burst = "distant",
		volume = 0.35,
		pitch = 1,
		maxDistance = 1600,
		tail = "always",
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 0.8, pitch = 0.7 },
			{ id = BASS, volume = 0.6, pitch = 0.6 },
			{ id = BOOM2, volume = 0.3, pitch = 0.9, delay = 0.03 },
		},
		effects = {
			{ "EqualizerSoundEffect", { HighGain = -18, MidGain = -8, LowGain = 3 } },
			{ "ReverbSoundEffect", { DecayTime = 2.2, WetLevel = -6, DryLevel = -2 } },
		},
	},
	-- A bullet only just missing you (Sfx.PlayAt): a short high tearing whizz past the ear, heard flat
	-- because it is right at your head. Capped (`burst`) so a burst of near misses stays a few whizzes.
	BulletWhiz = {
		burst = "whiz",
		volume = 0.4,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.6, pitch = 3.2 },
			{ id = FALL, volume = 0.25, pitch = 3.0 },
			{ id = SNAP, volume = 0.2, pitch = 2.9 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -14, MidGain = 0, HighGain = 3 } } },
	},
	-- A novelty gun's reload (SoundConfig.FoleyFor): a toy's plastic snaps and a water gun's slosh and
	-- squeaky pump stand in for the mag, bolt and slide of a real one.
	ToyOut = {
		volume = 0.4,
		pitch = 1,
		category = "Weapons",
		layers = { { id = BUTTON, volume = 0.6, pitch = 1.6 }, { id = SWITCH3, volume = 0.35, pitch = 1.9 } },
	},
	ToyIn = {
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = { { id = CLICK, volume = 0.6, pitch = 1.5 }, { id = BUTTON, volume = 0.4, pitch = 2.0, delay = 0.05 } },
	},
	ToyRack = {
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.55, pitch = 1.4 },
			{ id = OOF, volume = 0.1, pitch = 3.0, delay = 0.06 },
			{ id = CLICK, volume = 0.35, pitch = 1.8, delay = 0.1 },
		},
	},
	WaterOut = {
		volume = 0.4,
		pitch = 1,
		category = "Weapons",
		layers = { { id = WATER, volume = 0.45, pitch = 2.2 }, { id = BUTTON, volume = 0.35, pitch = 1.4 } },
	},
	WaterIn = {
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = { { id = WATER, volume = 0.5, pitch = 1.6 }, { id = CLICK, volume = 0.35, pitch = 1.6, delay = 0.08 } },
	},
	WaterRack = {
		-- The squeaky pump: plastic sliding, a rubber squeak at the end of the stroke, a puff of air.
		volume = 0.42,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.5, pitch = 1.2 },
			{ id = OOF, volume = 0.12, pitch = 3.2, delay = 0.04 },
			{ id = SLIDER, volume = 0.25, pitch = 2.4, delay = 0.05 },
		},
	},
	-- Flair: the little noises of a signature gun being shown off (Viewmodel's FLAIR clips).
	FlairBuzz = {
		-- A mosquito's whine, close to the ear.
		volume = 0.22,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SLIDER, volume = 0.4, pitch = 3.4 }, { id = PING, volume = 0.08, pitch = 3.6, delay = 0.05 } },
	},
	FlairSwat = {
		-- A flat hand slapping down.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SNAP, volume = 0.5, pitch = 1.2 }, { id = HIT, volume = 0.25, pitch = 1.6 } },
	},
	FlairDrum = {
		-- A drum tapped with the fingers.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = { { id = HIT, volume = 0.5, pitch = 0.7 }, { id = BASS, volume = 0.25, pitch = 1.4 } },
	},
	FlairKiss = {
		-- A blown kiss: a soft smack.
		volume = 0.22,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SNAP, volume = 0.3, pitch = 2.4 }, { id = BUTTON, volume = 0.2, pitch = 2.2 } },
	},
	FlairTear = {
		-- Paper torn off a roll.
		volume = 0.26,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SLIDER, volume = 0.4, pitch = 2.8 }, { id = CLICK, volume = 0.2, pitch = 2.6 } },
	},
	FlairWhir = {
		-- Barrels spinning up and winding down.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SLIDER, volume = 0.5, pitch = 0.9 }, { id = METAL, volume = 0.15, pitch = 1.2, delay = 0.1 } },
	},
	FlairStamp = {
		-- A rubber stamp slammed down.
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = { { id = HIT, volume = 0.6, pitch = 0.6 }, { id = COLLIDE, volume = 0.2, pitch = 0.9 } },
	},
	FlairBat = {
		-- A bat's wings, a flurry of them.
		volume = 0.24,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.3, pitch = 1.4 },
			{ id = SLIDER, volume = 0.2, pitch = 1.6, delay = 0.05 },
		},
	},
	FlairBounce = {
		-- A ball on a court floor.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = { { id = JUMP, volume = 0.5, pitch = 0.9 }, { id = HIT, volume = 0.25, pitch = 0.9 } },
	},
	FlairKnock = {
		-- Knuckles on a wooden door.
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = { { id = HIT, volume = 0.6, pitch = 0.55 }, { id = COLLIDE, volume = 0.3, pitch = 0.6 } },
	},
	FlairChomp = {
		-- Jaws snapping shut.
		volume = 0.32,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = COLLIDE, volume = 0.5, pitch = 1.4 },
			{ id = SNAP, volume = 0.35, pitch = 0.7 },
		},
	},
	FlairSqueak = {
		-- A sneaker sole on a gym floor.
		volume = 0.26,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = OOF, volume = 0.3, pitch = 2.8 },
			{ id = SLIDER, volume = 0.2, pitch = 2.4 },
		},
	},
	FlairBeep = {
		-- A status light blinking.
		volume = 0.22,
		pitch = 1,
		category = "Weapons",
		layers = { { id = PING, volume = 0.4, pitch = 2.4 } },
	},
	FlairSwipe = {
		-- A thumb dragged across something.
		volume = 0.24,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.4, pitch = 1.3 },
			{ id = CLICK, volume = 0.15, pitch = 2.2 },
		},
	},
	FlairWhoosh = {
		-- A slow breath of air.
		volume = 0.22,
		pitch = 1,
		category = "Weapons",
		layers = { { id = SLIDER, volume = 0.35, pitch = 0.6 } },
	},
	FlairClank = {
		-- Iron plates knocking together.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = METAL, volume = 0.5, pitch = 0.9 },
			{ id = HIT, volume = 0.3, pitch = 0.7 },
		},
	},
	FlairChime = {
		-- A bright, soft chime.
		volume = 0.22,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.35, pitch = 1.6 },
			{ id = PING, volume = 0.2, pitch = 2.4, delay = 0.06 },
		},
	},
	FlairTap = {
		-- A knuckle on wood or polymer.
		volume = 0.3,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 0.6, pitch = 1.1 },
			{ id = CLICK, volume = 0.3, pitch = 0.7 },
		},
	},
	FlairPop = {
		-- A flick: a small pop and a whoosh of air.
		volume = 0.28,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.5, pitch = 1.6 },
			{ id = SLIDER, volume = 0.2, pitch = 1.8 },
		},
	},
	FlairRattle = {
		-- Loose parts rattling in a shaken gun.
		volume = 0.28,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = COLLIDE, volume = 0.4, pitch = 2.4 },
			{ id = CLICK, volume = 0.3, pitch = 1.9, delay = 0.03 },
			{ id = METAL, volume = 0.15, pitch = 2.8, delay = 0.05 },
		},
	},

	-- The mechanism, one cue a movement, fired by the viewmodel's animation clips at the moment the
	-- part moves: a magazine leaving and seating, a charging handle drawn and let go, a pump, a bolt, a
	-- cylinder, a break, a lever, a feed cover. Two or three stock files each, pitched apart so a click
	-- and the metal behind it read as one mechanical noise.
	Equip = {
		-- Cloth moving, the gun's weight settling into the hands with a light metal knock, a click.
		volume = 0.35,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = GETUP, volume = 0.45, pitch = 1.4 },
			{ id = METAL, volume = 0.25, pitch = 1.8, delay = 0.08 },
			{ id = CLICK, volume = 0.35, pitch = 0.8, delay = 0.15 },
		},
	},
	-- Out and in are different motions, so they are different sounds rather than one pitched two ways:
	-- out is a button, a scrape and a light tick as it leaves; in is a thud, the latch, and a knock.
	MagOut = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.5, pitch = 1.5 },
			{ id = SLIDER, volume = 0.4, pitch = 1.7, delay = 0.03 },
			{ id = METAL, volume = 0.25, pitch = 2.2, delay = 0.06 },
		},
	},
	-- A magazine seating has weight. Every reload cue here was built from button, slider, metal, click and
	-- snap, all pitched up and all mid or high: measured against the gunshots, which each carry a boom or
	-- a bass under the crack, not one reload beat had anything below pitch 1. The closing beats -- a mag
	-- seating, a bolt going home, a cylinder or a break shutting -- now carry a low layer of their own, so
	-- they land instead of ticking.
	MagIn = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = COLLIDE, volume = 0.45, pitch = 2.3 },
			{ id = CLICK, volume = 0.9, pitch = 0.7, delay = 0.03 },
			{ id = METAL, volume = 0.45, pitch = 1.25, delay = 0.03 },
			{ id = BASS, volume = 0.3, pitch = 0.75, delay = 0.02 },
		},
	},
	ChargeBack = {
		-- A spring-loaded drag: the slide of metal on metal, the catch, a thin ring.
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.6, pitch = 1.5 },
			{ id = SWITCH3, volume = 0.75, pitch = 0.62, delay = 0.02 },
			{ id = METAL, volume = 0.2, pitch = 1.9 },
		},
	},
	ChargeRelease = {
		-- The bolt slamming home: a hard snap, metal, a low click and a knock through the gun.
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.25 },
			{ id = METAL, volume = 0.6, pitch = 1.35 },
			{ id = CLICK, volume = 0.55, pitch = 0.55 },
			{ id = COLLIDE, volume = 0.2, pitch = 2.6 },
			{ id = BASS, volume = 0.24, pitch = 0.85, delay = 0.01 },
		},
	},
	SlideRelease = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.35 },
			{ id = METAL, volume = 0.5, pitch = 1.7 },
			{ id = BASS, volume = 0.2, pitch = 0.95, delay = 0.01 },
		},
	},
	PumpBack = {
		-- "Chk": the fore-end drawn back, the action unlocking, a metal clack at the end of travel.
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.7, pitch = 1.05 },
			{ id = SWITCH3, volume = 0.8, pitch = 0.52 },
			{ id = METAL, volume = 0.35, pitch = 0.85, delay = 0.05 },
		},
	},
	PumpForward = {
		-- "Chak": driven home, a heavier snap and a chunk through the stock.
		volume = 0.6,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.95 },
			{ id = METAL, volume = 0.6, pitch = 1.0 },
			{ id = COLLIDE, volume = 0.35, pitch = 2.0 },
			{ id = BASS, volume = 0.28, pitch = 0.78, delay = 0.01 },
		},
	},
	ShellIn = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 0.8, pitch = 0.8 },
			{ id = METAL, volume = 0.35, pitch = 2.0 },
		},
	},
	BoltBack = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.9, pitch = 0.7 },
			{ id = SLIDER, volume = 0.5, pitch = 1.4, delay = 0.05 },
		},
	},
	BoltForward = {
		-- Pushed forward and turned down to lock: a glide, the snap of the lugs, a metal seat.
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.45, pitch = 1.6 },
			{ id = SNAP, volume = 0.85, pitch = 1.05, delay = 0.06 },
			{ id = METAL, volume = 0.35, pitch = 1.2, delay = 0.07 },
			{ id = BASS, volume = 0.26, pitch = 0.8, delay = 0.06 },
		},
	},
	CylinderOpen = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH, volume = 0.9, pitch = 0.9 },
			{ id = METAL, volume = 0.5, pitch = 1.9 },
		},
	},
	CylinderClose = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 1.5 },
			{ id = METAL, volume = 0.5, pitch = 2.2 },
			{ id = BASS, volume = 0.22, pitch = 0.9, delay = 0.01 },
		},
	},
	HammerCock = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 1, pitch = 0.9 },
			{ id = SWITCH, volume = 0.5, pitch = 1.3 },
		},
	},
	BreakOpen = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.9, pitch = 0.6 },
			{ id = METAL, volume = 0.6, pitch = 0.9 },
		},
	},
	BreakClose = {
		volume = 0.6,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 0.9 },
			{ id = METAL, volume = 0.7, pitch = 0.8 },
			{ id = LAND, volume = 0.4, pitch = 1.4 },
			{ id = BASS, volume = 0.3, pitch = 0.7, delay = 0.02 },
		},
	},
	LeverOpen = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.9, pitch = 0.75 },
			{ id = SLIDER, volume = 0.5, pitch = 1.3 },
		},
	},
	LeverClose = {
		volume = 0.6,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.95 },
			{ id = METAL, volume = 0.6, pitch = 1.0 },
		},
	},
	CoverOpen = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SWITCH3, volume = 0.9, pitch = 0.5 },
			{ id = METAL, volume = 0.5, pitch = 0.8 },
		},
	},
	CoverClose = {
		volume = 0.6,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.8 },
			{ id = METAL, volume = 0.7, pitch = 0.75 },
			{ id = LAND, volume = 0.4, pitch = 1.2 },
		},
	},
	RocketSeat = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = COLLIDE, volume = 0.6, pitch = 1.4 },
			{ id = CLICK, volume = 0.8, pitch = 0.5, delay = 0.1 },
		},
	},
	StringCock = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.7, pitch = 0.7 },
			{ id = SNAP, volume = 0.8, pitch = 0.8, delay = 0.18 },
		},
	},
	BoltSeat = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 0.7, pitch = 1.1 },
			{ id = SWITCH, volume = 0.4, pitch = 1.5 },
		},
	},
	EnergyCharge = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.6, pitch = 0.6 },
			{ id = SLIDER, volume = 0.4, pitch = 2.2 },
			{ id = BASS, volume = 0.4, pitch = 1.6 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.4, Rate = 5 } } },
	},
	-- A spent case hitting the floor.
	CasingTink = {
		volume = 0.3,
		pitch = 1,
		maxDistance = 40,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 0.6, pitch = 2.6 },
			{ id = CLICK, volume = 0.5, pitch = 2.2 },
		},
	},

	-- You got the kill: a bright ping over a low thump. KillFeedback plays it twice, a step apart, and
	-- raises the pitch with each kill in a chain, so a double or triple kill climbs (Oliver, 2026-09-22:
	-- "make it more satisfying to get a kill").
	KillConfirm = {
		volume = 0.55,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 1, pitch = 1.3 },
			{ id = SWITCH3, volume = 0.5, pitch = 1.1 },
			{ id = BASS, volume = 0.5, pitch = 0.7 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 3, MidGain = 0, LowGain = 2 } } },
	},

	-- Someone went down.
	Elimination = {
		volume = 0.6,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = OOF, volume = 1, pitch = 1 },
			{ id = BASS, volume = 0.45, pitch = 0.8, delay = 0.04 },
		},
	},

	--------------------------------------------------------------------------------
	-- World and pickups
	--------------------------------------------------------------------------------

	Pickup = {
		volume = 0.5,
		pitch = 1,
		category = "Effects",
		layers = {
			{ id = SWITCH3, volume = 1, pitch = 1.2 },
			{ id = PING, volume = 0.5, pitch = 1.5, delay = 0.03 },
		},
	},

	-- A crate or chest coming open: a heavy latch, then a rising shine.
	CrateOpen = {
		volume = 0.42,
		pitch = 1,
		category = "Interface",
		layers = {
			{ id = SWITCH, volume = 0.9, pitch = 0.6 },
			{ id = BASS, volume = 0.7, pitch = 0.9, delay = 0.05 },
			{ id = PING, volume = 0.8, pitch = 1.25, delay = 0.16 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.1, WetLevel = -9, DryLevel = 0 } } },
	},

	-- A click is a tenth of a second: `clickfast` pitched up for the tick, a whisper of `switch` for
	-- the release. (#120: this was `button` at 1.1 -- 0.53 s per click at 24 sites, so every menu in
	-- the game felt sluggish at once.) Audible length 0.15 s.
	UiClick = {
		volume = 0.4,
		pitch = 1,
		category = "Interface",
		layers = {
			{ id = CLICK, volume = 1, pitch = 2.0 },
			{ id = SWITCH, volume = 0.35, pitch = 1.8, delay = 0.02 },
		},
	},

	-- A boot on a ball: one short thump with a little body under it. (#120: this was `collide`, the
	-- brick-collision crash, 0.96 s for a kick.) Audible length 0.56 s.
	BallKick = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.75 },
			{ id = BASS, volume = 0.55, pitch = 1.8 },
		},
	},

	-- Grabbing and riding a zipline: metal running on a wire.
	Zipline = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 1, pitch = 1.15 },
			{ id = SWITCH3, volume = 0.5, pitch = 1.4 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.6, Mix = 0.4, Rate = 3 } } },
	},

	--------------------------------------------------------------------------------
	-- Explosives (ProjectileClient, HitSplatClient): launcher rounds, grenades, smoke, splats
	--------------------------------------------------------------------------------

	-- Every real blast is built the same way, sized by `blast` (SoundConfig.Blasts adds the shared
	-- layers when this module loads):
	--   crack    `snap` slowed right down, the pressure wave's edge; tagged `range = "near"`, so past
	--            the blast class's XFADE band it drops out and only the low end is left;
	--   boom     the explosion files, slowed for size: a grenade's is short, a vehicle's rolls;
	--   sub      (shared) a bass thump felt in the chest close up, gone with distance;
	--   debris   (shared) rubble and dirt coming down 0.15-0.6 s after; ProjectileClient adds a second
	--            debris cue for what the blast went off against (SoundConfig.Debris);
	--   tail     indoors the room reverb and a short boomy bloom (shared); outdoors a late, slowed echo
	--            off the terrain, stretched in open country (Sfx.Openness);
	--   far      (shared) a delayed low thump that fades in with range, and past `distant.from` the flat
	--            ExplosionFar rumble, which carries on alone out to 1800 studs.
	-- `duck = true`: close enough (Acoustics.DUCK), it muffles the world for a second (Sfx.Duck).
	ExplosionRocket = {
		blast = "rocket",
		duck = true,
		volume = 0.8,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.5, range = "near" },
			{ id = BOOM2, volume = 1, pitch = 1.1 },
			{ id = BOOM3, volume = 1, pitch = 0.72 },
			{ id = BASS, volume = 0.9, pitch = 0.55 },
			{ id = BOOM3, volume = 0.35, pitch = 0.5, delay = 0.45, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.4, WetLevel = -8, DryLevel = 0 } } },
	},
	-- A 40mm: smaller and sharper, less tail.
	ExplosionGrenade = {
		blast = "grenade",
		duck = true,
		volume = 0.7,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.65, range = "near" },
			{ id = BOOM2, volume = 1, pitch = 1.3 },
			{ id = BASS, volume = 0.7, pitch = 0.75 },
			{ id = BOOM3, volume = 0.25, pitch = 0.6, delay = 0.4, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.5, WetLevel = -9, DryLevel = 0 } } },
	},
	-- A frag: the body of the rocket's blast with a metallic ring over it for the fragments.
	ExplosionFrag = {
		blast = "frag",
		duck = true,
		volume = 0.71,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.55, range = "near" },
			{ id = BOOM3, volume = 1, pitch = 0.9 },
			{ id = BOOM2, volume = 0.8, pitch = 1.25 },
			{ id = METAL, volume = 0.5, pitch = 0.8, delay = 0.05 },
			{ id = BASS, volume = 0.8, pitch = 0.6 },
			{ id = BOOM3, volume = 0.3, pitch = 0.5, delay = 0.45, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.0, WetLevel = -8, DryLevel = 0 } } },
	},
	-- A Rot Mine going off underfoot (HazardService): a buried charge, so more earth than air -- a
	-- dull heavy thud of dirt thrown up over the crack.
	ExplosionMine = {
		blast = "frag",
		duck = true,
		volume = 0.75,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.6, range = "near" },
			{ id = BOOM3, volume = 1, pitch = 0.85 },
			{ id = BOOM2, volume = 0.7, pitch = 1.2 },
			{ id = BASS, volume = 0.8, pitch = 0.55 },
			{ id = LAND, volume = 0.5, pitch = 0.5, delay = 0.03 },
			{ id = BOOM3, volume = 0.3, pitch = 0.5, delay = 0.42, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.8, WetLevel = -9, DryLevel = 0 } } },
	},
	-- A fuel barrel (HazardService): the fuel lighting first -- a rushing whoomph -- then the drum
	-- bursting, a plate of it ringing off.
	ExplosionBarrel = {
		blast = "rocket",
		duck = true,
		volume = 0.82,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.5, range = "near" },
			{ id = FALL, volume = 0.5, pitch = 0.55 },
			{ id = BOOM3, volume = 1, pitch = 0.7 },
			{ id = BOOM2, volume = 0.8, pitch = 1.0, delay = 0.04 },
			{ id = METAL, volume = 0.4, pitch = 0.6, delay = 0.06 },
			{ id = BASS, volume = 0.8, pitch = 0.5 },
			{ id = BOOM3, volume = 0.35, pitch = 0.45, delay = 0.5, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.4, WetLevel = -8, DryLevel = 0 } } },
	},
	-- A vehicle going up when it is wrecked (VehicleWreckFx): the biggest blast in the game. The
	-- tank's fuel lights with a long rushing whoomph under the crack, the body rolls, and the wreck
	-- rains metal (the vehicle size's debris is metal, not rubble).
	ExplosionVehicle = {
		blast = "vehicle",
		duck = true,
		volume = 1.05,
		pitch = 1,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 300 },
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.45, range = "near" },
			{ id = FALL, volume = 0.6, pitch = 0.45, delay = 0.03 },
			{ id = BOOM3, volume = 1, pitch = 0.6 },
			{ id = BOOM2, volume = 0.8, pitch = 0.9 },
			{ id = BASS, volume = 0.7, pitch = 0.5 },
			{ id = BOOM3, volume = 0.4, pitch = 0.42, delay = 0.55, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.8, WetLevel = -7, DryLevel = 0 } } },
	},
	-- The same blast heard from across the map: a rumble with the top taken off, played flat (not
	-- positional) at a volume set by distance, so a fight far away still reads as thunder. Its reverb
	-- is the roll of distance, not a room, so it plays under a roof or not. `maxDistance` here is
	-- where Sfx.PlayDistant fades it to nothing; Sfx.PlayAt hands a blast over to it past the blast's reach.
	ExplosionFar = {
		burst = "rumble",
		volume = 0.5,
		pitch = 1,
		maxDistance = 1800,
		tail = "always",
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 0.45 },
			{ id = BASS, volume = 0.9, pitch = 0.35 },
		},
		effects = {
			{ "EqualizerSoundEffect", { HighGain = -18, MidGain = -8, LowGain = 4 } },
			{ "ReverbSoundEffect", { DecayTime = 3.5, WetLevel = -4, DryLevel = -2 } },
		},
	},
	-- The ringing after a blast right beside you: a faint high tone that hangs for a second or two
	-- under the muffle (Sfx.Duck). Quiet on purpose -- felt more than heard.
	BlastRing = {
		volume = 0.05,
		pitch = 1,
		tail = "always",
		category = "Effects",
		layers = { { id = PING, volume = 1, pitch = 1.9 } },
		effects = {
			{ "EqualizerSoundEffect", { HighGain = 2, MidGain = 0, LowGain = -20 } },
			{ "ReverbSoundEffect", { DecayTime = 2.5, WetLevel = 0, DryLevel = -6 } },
		},
	},

	-- What comes down after a blast, by what it went off against (SoundConfig.Debris). Each is a
	-- scatter of small impacts spread over half a second, quiet, and heard only near the blast.
	-- `burst` shares one cap between them, so a chain of blasts can't bury the mix in gravel.
	DebrisDirt = {
		burst = "debris",
		volume = 0.5,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = STEPS, volume = 0.6, pitch = 0.55, delay = 0.15 },
			{ id = LAND, volume = 0.5, pitch = 0.5, delay = 0.26 },
			{ id = STEPS, volume = 0.35, pitch = 0.8, delay = 0.45 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 2, MidGain = 0, HighGain = -6 } } },
	},
	DebrisRubble = {
		burst = "debris",
		volume = 0.5,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = COLLIDE, volume = 0.6, pitch = 0.5, delay = 0.15 },
			{ id = HIT, volume = 0.45, pitch = 0.45, delay = 0.28 },
			{ id = COLLIDE, volume = 0.35, pitch = 0.7, delay = 0.46 },
		},
	},
	DebrisWood = {
		burst = "debris",
		volume = 0.5,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = COLLIDE, volume = 0.55, pitch = 0.8, delay = 0.14 },
			{ id = SNAP, volume = 0.5, pitch = 0.7, delay = 0.2 },
			{ id = LAND, volume = 0.35, pitch = 0.9, delay = 0.4 },
		},
	},
	DebrisMetal = {
		burst = "debris",
		volume = 0.5,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 0.55, pitch = 0.7, delay = 0.16 },
			{ id = METAL, volume = 0.35, pitch = 1.1, delay = 0.36 },
			{ id = COLLIDE, volume = 0.25, pitch = 1.2, delay = 0.52 },
		},
	},
	DebrisGlass = {
		burst = "debris",
		volume = 0.5,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 0.45, pitch = 2.2, delay = 0.12 },
			{ id = SNAP, volume = 0.35, pitch = 2.6, delay = 0.18 },
			{ id = METAL, volume = 0.3, pitch = 2.8, delay = 0.34 },
			{ id = PING, volume = 0.1, pitch = 2.4, delay = 0.3 },
		},
	},
	DebrisWater = {
		burst = "debris",
		volume = 0.55,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 0.8, pitch = 0.7, delay = 0.12 },
			{ id = WATER, volume = 0.45, pitch = 1.1, delay = 0.4 },
		},
	},

	-- The silly explosives' own blasts (Oliver: "give the silly explosives their own silly
	-- explosion"). ExplosiveFx plays Explosion<Theme> for a themed weapon. Cartoon sounds, no real
	-- boom, no debris, no ear-ring -- but loud and far-carrying, because they still hurt.
	ExplosionParty = {
		-- Party Foul Cannon: a huge cork pop, a party horn squealing, confetti rustling down.
		novelty = true,
		volume = 0.9,
		pitch = 1,
		maxDistance = 520,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.9, pitch = 0.7 },
			{ id = HIT, volume = 0.6, pitch = 1.0 },
			{ id = BASS, volume = 0.5, pitch = 1.1 },
			{ id = UUH, volume = 0.35, pitch = 2.4, delay = 0.05 },
			{ id = SLIDER, volume = 0.3, pitch = 2.6, delay = 0.05 },
			{ id = STEPS, volume = 0.35, pitch = 2.6, delay = 0.14 },
			{ id = SWITCH3, volume = 0.2, pitch = 2.2, delay = 0.18 },
		},
	},
	ExplosionSlipper = {
		-- Grandma's Slipper Launcher: one enormous comedy THWACK and a boing as it bounces off.
		novelty = true,
		volume = 0.9,
		pitch = 1,
		maxDistance = 480,
		category = "Weapons",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.7 },
			{ id = HIT, volume = 0.7, pitch = 0.6 },
			{ id = BASS, volume = 0.5, pitch = 0.9 },
			{ id = JUMP, volume = 0.7, pitch = 0.55, delay = 0.06 },
			{ id = OOF, volume = 0.25, pitch = 0.8, delay = 0.12 },
		},
	},
	ExplosionFidget = {
		-- Fidget Disc Launcher: a whirring spin-up that flies apart in a clatter of bearings.
		novelty = true,
		volume = 0.9,
		pitch = 1,
		maxDistance = 480,
		category = "Weapons",
		layers = {
			{ id = FALL, volume = 0.4, pitch = 2.8 },
			{ id = SLIDER, volume = 0.4, pitch = 2.2 },
			{ id = BASS, volume = 0.45, pitch = 1.2, delay = 0.1 },
			{ id = COLLIDE, volume = 0.6, pitch = 1.8, delay = 0.12 },
			{ id = CLICK, volume = 0.5, pitch = 1.2, delay = 0.14 },
			{ id = METAL, volume = 0.3, pitch = 1.6, delay = 0.2 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.45, Mix = 0.35, Rate = 10 } } },
	},
	ExplosionGold = {
		-- Golden Sahur Cannon: a cash register's cha-ching and a shower of coins.
		novelty = true,
		volume = 0.9,
		pitch = 1,
		maxDistance = 480,
		category = "Weapons",
		layers = {
			{ id = SWITCH, volume = 0.6, pitch = 0.9 },
			{ id = PING, volume = 0.8, pitch = 1.3, delay = 0.04 },
			{ id = BASS, volume = 0.45, pitch = 1.0 },
			{ id = METAL, volume = 0.35, pitch = 2.4, delay = 0.1 },
			{ id = METAL, volume = 0.25, pitch = 2.9, delay = 0.22 },
			{ id = CLICK, volume = 0.25, pitch = 2.6, delay = 0.3 },
		},
	},
	ExplosionCoffee = {
		-- Cappuccina Launcher: a big splash of coffee, a slurp, and the hiss of it steaming.
		novelty = true,
		volume = 0.9,
		pitch = 1,
		maxDistance = 480,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 1, pitch = 0.6 },
			{ id = LAND, volume = 0.5, pitch = 0.6 },
			{ id = BASS, volume = 0.5, pitch = 0.8 },
			{ id = SWIM, volume = 0.4, pitch = 0.7, delay = 0.15 },
			{ id = SWIM, volume = 0.3, pitch = 2.2, delay = 0.25 },
		},
	},
	ExplosionDrum = {
		-- Tamburo Tung Tung's drumlets going off: TUNG -- a bass drum hit as a blast, snares rattling.
		novelty = true,
		volume = 0.8,
		pitch = 1,
		maxDistance = 420,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 1, pitch = 0.4 },
			{ id = BASS, volume = 0.8, pitch = 0.6 },
			{ id = LAND, volume = 0.6, pitch = 0.45 },
			{ id = SLIDER, volume = 0.2, pitch = 2.4, delay = 0.03 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 0.9, WetLevel = -11, DryLevel = 0 } } },
	},
	ExplosionToast = {
		-- Toaster Mortar's toast landing hot: the spring's twang, a crusty thump, crumbs, a "ding".
		novelty = true,
		volume = 0.85,
		pitch = 1,
		maxDistance = 460,
		category = "Weapons",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.55 },
			{ id = BASS, volume = 0.6, pitch = 0.9 },
			{ id = SWITCH3, volume = 0.5, pitch = 0.7 },
			{ id = STEPS, volume = 0.35, pitch = 1.8, delay = 0.1 },
			{ id = PING, volume = 0.35, pitch = 1.6, delay = 0.18 },
		},
	},
	-- A rocket in flight: the falling-wind file, sped up, looped on the round itself
	-- (ProjectileClient builds this one by hand so it can follow the round and loop).
	RocketWhoosh = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 260,
		category = "Weapons",
		layers = {
			{ id = FALL, volume = 1, pitch = 1.7 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -4, MidGain = 2, LowGain = -6 } } },
	},
	-- A grenade or 40mm knocking off something: a short knock, pitched by how hard it landed.
	-- The Clingy Crumpet landing jam-first, and its timer's beeps, which quicken toward the blast.
	StickySquelch = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 100,
		category = "Effects",
		layers = {
			{ id = SWIM, volume = 0.9, pitch = 1.35 },
			{ id = WATER, volume = 0.5, pitch = 1.6, delay = 0.03 },
		},
	},
	StickyBeep = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = PING, volume = 0.8, pitch = 1.6 },
		},
	},
	GrenadeBounce = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = COLLIDE, volume = 0.8, pitch = 1.7 },
			{ id = CLICK, volume = 0.5, pitch = 1.1 },
		},
	},
	-- The pin coming out of a Cooked Coconut: a click and a ring of steel.
	CoconutPinPull = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 60,
		category = "Effects",
		layers = {
			{ id = SWITCH, volume = 0.9, pitch = 1.3 },
			{ id = METAL, volume = 0.5, pitch = 1.9, delay = 0.04 },
		},
	},
	-- The fuse ticking while it's held: one tick a second, rising as it runs out.
	CoconutCook = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 40,
		category = "Effects",
		layers = {
			{ id = CLICK, volume = 1, pitch = 2.1 },
		},
	},
	-- A Lowkey Latte starting to pour: a hiss. The swim file with its low end taken away.
	SmokeHiss = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = SWIM, volume = 0.9, pitch = 0.8 },
			{ id = FALL, volume = 0.5, pitch = 2.0 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 6, MidGain = -2, LowGain = -14 } } },
	},
	-- The cloud rolling out: a soft, slow whump.
	SmokeBillow = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = BOOM2, volume = 0.6, pitch = 0.35 },
			{ id = WATER, volume = 0.5, pitch = 0.6 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -10, MidGain = -3, LowGain = 2 } } },
	},
	-- A bullet landing on someone, heard at the body: a soft wet tick under the hit.
	HitSplat = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = HIT, volume = 0.7, pitch = 1.5 },
			{ id = WATER, volume = 0.35, pitch = 2.6 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -3, MidGain = 2, LowGain = -8 } } },
	},

	--------------------------------------------------------------------------------
	-- Companions
	--------------------------------------------------------------------------------

	CompanionAttack = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 200,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 1, pitch = 0.75 },
			{ id = SWITCH3, volume = 0.5, pitch = 0.6 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.4, Mix = 0.35, Rate = 4 } } },
	},

	CompanionDown = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 220,
		category = "Weapons",
		layers = {
			{ id = UUH, volume = 1, pitch = 1.3 },
			{ id = BOOM2, volume = 0.5, pitch = 1.9 },
		},
	},

	-- A companion's move landing on someone: a punchy thwack with a bright snap on top.
	CompanionHit = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Weapons",
		layers = {
			{ id = HIT, volume = 1, pitch = 1.15 },
			{ id = SNAP, volume = 0.6, pitch = 0.75 },
			{ id = BASS, volume = 0.35, pitch = 1.6 },
		},
	},

	--------------------------------------------------------------------------------
	-- Companion abilities (CompanionFxClient; OLIVER_LIST A5 effects pass, 2026-09-24)
	--
	-- One cue per move for its strike (and its landing, for the moves that travel), and one per
	-- ability style, on the beat that style shows: a chill, daze, burn, poison or leech when its hit
	-- lands (the server only applies a style on a hit that did damage); Quick, Long and Fork on the
	-- strike; Wide on the landing. CompanionHit above still marks the hit itself. All "world" class
	-- (SoundConfig.ClassOf) at companion ranges, so a fight's worth of them never carries like a gun.
	-- Kept to their own section: the death-effect and gun cues are another tab's.
	--------------------------------------------------------------------------------

	-- The windup: a soft rising charge under the anticipation pose, quiet enough to stack.
	CompanionFxCharge = {
		volume = 0.3,
		pitch = 1,
		maxDistance = 90,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.8, pitch = 1.7 },
			{ id = PING, volume = 0.3, pitch = 0.55 },
		},
	},

	-- Spit: a wet pop out of the mouth; the splat where it lands.
	CompanionFxSpit = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 150,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.7, pitch = 2.4 },
			{ id = SNAP, volume = 0.5, pitch = 1.3 },
			{ id = JUMP, volume = 0.3, pitch = 1.8 },
		},
	},

	CompanionFxSplat = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 140,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.8, pitch = 1.5 },
			{ id = HIT, volume = 0.5, pitch = 0.9 },
		},
	},

	-- Zap: a hard electric crack. Chain: the crack, and a second and third as it jumps.
	CompanionFxZap = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 170,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 2 },
			{ id = PING, volume = 0.6, pitch = 1.6 },
			{ id = SWITCH3, volume = 0.4, pitch = 0.5 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.5 } } },
	},

	CompanionFxChain = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 170,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 2.2 },
			{ id = SNAP, volume = 0.55, pitch = 1.8, delay = 0.06 },
			{ id = SNAP, volume = 0.35, pitch = 1.6, delay = 0.12 },
			{ id = PING, volume = 0.5, pitch = 1.3 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.45 } } },
	},

	-- Lob: the toss (a throw's whoosh); the splash, wet with a low thump under it.
	CompanionFxLob = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 150,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.7, pitch = 0.8 },
			{ id = JUMP, volume = 0.5, pitch = 0.8 },
		},
	},

	CompanionFxLobSplash = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 180,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.8, pitch = 1.1 },
			{ id = BOOM2, volume = 0.3, pitch = 2.4 },
		},
	},

	-- Bonk: the leap; the slam, a landing thud with a crack of the ground.
	CompanionFxLeap = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 140,
		category = "Weapons",
		layers = {
			{ id = JUMP, volume = 0.8, pitch = 0.9 },
			{ id = SLIDER, volume = 0.3, pitch = 1.3 },
		},
	},

	CompanionFxSlam = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 190,
		category = "Weapons",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.6 },
			{ id = BOOM3, volume = 0.45, pitch = 1.7 },
			{ id = COLLIDE, volume = 0.4, pitch = 0.7 },
		},
	},

	-- Shockwave: the stomp, a low boom that rolls out with the ring.
	CompanionFxQuake = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 200,
		category = "Weapons",
		layers = {
			{ id = BOOM2, volume = 0.6, pitch = 1.2 },
			{ id = BASS, volume = 0.7, pitch = 0.6 },
			{ id = LAND, volume = 0.8, pitch = 0.5 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -4, MidGain = 0, LowGain = 4 } } },
	},

	-- A blast brainrot's kick as it lets go (the explosion itself is ProjectileService's cue).
	CompanionFxBlast = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 160,
		category = "Weapons",
		layers = {
			{ id = BASS, volume = 0.6, pitch = 0.9 },
			{ id = SNAP, volume = 0.6, pitch = 0.9 },
		},
	},

	-- Styles: a chill's icy ring, a daze's cartoon tweet, a burn's crackle, a poison's gloop, a
	-- leech's slurp and the ding of the heal, a wide wave's rumble, a quick move's flick, a long
	-- shot's scope glint, a fork's extra crack.
	CompanionFxChill = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 130,
		category = "Weapons",
		layers = {
			{ id = METAL, volume = 0.5, pitch = 2.2 },
			{ id = SLIDER, volume = 0.4, pitch = 0.5 },
		},
	},

	CompanionFxDaze = {
		volume = 0.35,
		pitch = 1,
		maxDistance = 120,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.5, pitch = 2 },
			{ id = PING, volume = 0.35, pitch = 2.5, delay = 0.08 },
			{ id = BUTTON, volume = 0.3, pitch = 1.4 },
		},
	},

	CompanionFxBurn = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 130,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 0.35, pitch = 2 },
			{ id = SNAP, volume = 0.3, pitch = 2.4, delay = 0.05 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.3 } } },
	},

	CompanionFxToxic = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 120,
		category = "Weapons",
		layers = {
			{ id = WATER, volume = 0.6, pitch = 0.7 },
			{ id = UUH, volume = 0.2, pitch = 0.6 },
		},
	},

	CompanionFxLeech = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 130,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.5, pitch = 0.6 },
			{ id = PING, volume = 0.35, pitch = 0.9, delay = 0.3 },
		},
	},

	CompanionFxWide = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 180,
		category = "Weapons",
		layers = {
			{ id = BOOM2, volume = 0.5, pitch = 0.8 },
			{ id = BASS, volume = 0.6, pitch = 0.5 },
		},
	},

	CompanionFxQuick = {
		volume = 0.35,
		pitch = 1,
		maxDistance = 110,
		category = "Weapons",
		layers = {
			{ id = SWITCH, volume = 0.6, pitch = 1.6 },
			{ id = CLICK, volume = 0.4, pitch = 1.4 },
		},
	},

	CompanionFxLong = {
		volume = 0.35,
		pitch = 1,
		maxDistance = 150,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.5, pitch = 2.2 },
			{ id = SWITCH3, volume = 0.3, pitch = 1.2 },
		},
	},

	CompanionFxFork = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 160,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.6, pitch = 2.6, delay = 0.04 },
			{ id = PING, volume = 0.4, pitch = 1.9 },
		},
	},

	--------------------------------------------------------------------------------
	-- Death effects, positional at the body (DeathFxService picks one per gun)
	--------------------------------------------------------------------------------

	-- A body meeting the floor: the landing thud with a short low body. (#120: the bass layer ran at
	-- 0.55, a 1.84 s drum for a thud.) Audible length 0.78 s.
	BodyFall = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.62 },
			{ id = BASS, volume = 0.45, pitch = 1.3 },
		},
	},

	FloatAway = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = GETUP, volume = 1, pitch = 1.4 },
			{ id = PING, volume = 0.5, pitch = 1.6, delay = 0.1 },
		},
		effects = { { "PitchShiftSoundEffect", { Octave = 1.4 } } },
	},

	AshAway = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = FALL, volume = 1, pitch = 0.7 },
			{ id = SWIM, volume = 0.4, pitch = 1.3 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 4, MidGain = -4, LowGain = -12 } } },
	},

	Burn = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 0.55 },
			{ id = SWIM, volume = 0.45, pitch = 0.8, delay = 0.12 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.2 } } },
	},

	Freeze = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = SLIDER, volume = 1, pitch = 0.4 },
			{ id = METAL, volume = 0.5, pitch = 1.8 },
		},
		effects = { { "PitchShiftSoundEffect", { Octave = 0.6 } } },
	},

	Shatter = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 1, pitch = 1.9 },
			{ id = SNAP, volume = 0.7, pitch = 1.8 },
			{ id = METAL, volume = 0.5, pitch = 2.1, delay = 0.05 },
		},
	},

	-- Things breaking, by material (BreakFxClient, #71): wood snaps and knocks, stone thuds and
	-- crumbles, metal clangs twice, foliage rustles.
	BreakWood = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.7 },
			{ id = COLLIDE, volume = 0.6, pitch = 0.8, delay = 0.04 },
		},
	},
	BreakStone = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = BOOM3, volume = 0.35, pitch = 1.8 },
			{ id = COLLIDE, volume = 0.7, pitch = 0.6 },
		},
	},
	BreakMetal = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 180,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 0.9, pitch = 0.8 },
			{ id = METAL, volume = 0.5, pitch = 1.4, delay = 0.06 },
		},
	},
	BreakFoliage = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 0.6, pitch = 2.2 },
			{ id = SNAP, volume = 0.4, pitch = 1.3 },
		},
	},

	-- Crossing the storm edge (StormClient, #45): a low rotten groan going out, a bright ping coming back.
	StormEnter = {
		volume = 0.5,
		pitch = 1,
		category = "Effects",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.6 },
			{ id = UUH, volume = 0.35, pitch = 0.7, delay = 0.05 },
		},
	},
	StormLeave = {
		volume = 0.4,
		pitch = 1,
		category = "Effects",
		layers = {
			{ id = PING, volume = 0.8, pitch = 1.3 },
		},
	},

	Shock = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = PING, volume = 1, pitch = 2.2 },
			{ id = SLIDER, volume = 0.5, pitch = 2.6 },
		},
		effects = { { "TremoloSoundEffect", { Depth = 0.8, Frequency = 18 } } },
	},

	Confetti = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 1.7 },
			{ id = SWITCH3, volume = 0.7, pitch = 1.9, delay = 0.04 },
			{ id = PING, volume = 0.6, pitch = 1.8, delay = 0.1 },
		},
	},

	Vaporize = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 220,
		category = "Effects",
		layers = {
			{ id = BOOM2, volume = 1, pitch = 1.8 },
			{ id = PING, volume = 0.6, pitch = 0.9, delay = 0.06 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.8, Mix = 0.5, Rate = 6 } } },
	},

	Gold = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = PING, volume = 1, pitch = 1.1 },
			{ id = BASS, volume = 0.5, pitch = 1.2, delay = 0.08 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.4, WetLevel = -6, DryLevel = 0 } } },
	},

	GoldCrumble = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 1, pitch = 1.35 },
			{ id = METAL, volume = 0.6, pitch = 1.5 },
		},
	},

	--------------------------------------------------------------------------------
	-- Death effects (#24, Shared/DeathEffectDesigns): the moments the existing cues above don't cover.
	-- Each design lists the cues it plays in its `cues`, and tools/killanim_check.py holds every one to
	-- a cue here. Built from the same stock files as everything else. Audible lengths are given where a
	-- slowed layer could run long; none outlasts the effect it belongs to.
	--------------------------------------------------------------------------------

	-- A party popper's fuse: a short bright fizz and a click (slider 0.85 s / 2.4 = 0.35 s).
	DeathFuse = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = SLIDER, volume = 0.8, pitch = 2.4 },
			{ id = CLICK, volume = 0.6, pitch = 1.6, delay = 0.12 },
		},
	},

	-- A goo bubble popping: a wet little plip.
	DeathBubble = {
		volume = 0.35,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = CLICK, volume = 0.8, pitch = 2.4 },
			{ id = WATER, volume = 0.4, pitch = 2.8 },
		},
	},

	-- Air rushing into three balloons (slider 0.85 s / 1.5 = 0.57 s), and a squeak of rubber.
	DeathBalloonInflate = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = SLIDER, volume = 0.9, pitch = 1.5 },
			{ id = SWITCH, volume = 0.4, pitch = 1.9, delay = 0.3 },
		},
	},

	-- A balloon going pop: a sharp snap with a click on top.
	DeathBalloonPop = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.8 },
			{ id = CLICK, volume = 0.5, pitch = 1.2 },
		},
	},

	-- Something big coming down through the air: the bat's swing, the drum's drop (0.85 s / 1.2).
	DeathWhoosh = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = SLIDER, volume = 1, pitch = 1.2 },
			{ id = WATER, volume = 0.3, pitch = 2.6 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 2, MidGain = 0, LowGain = -6 } } },
	},

	-- A cartoon bonk: a hollow thunk with weight under it.
	DeathBonk = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = HIT, volume = 1, pitch = 0.6 },
			{ id = COLLIDE, volume = 0.5, pitch = 0.75, delay = 0.02 },
			{ id = BASS, volume = 0.5, pitch = 0.9 },
		},
	},

	-- A small ghost's woo: a high "uuh" through a flanger.
	DeathGhostWail = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = UUH, volume = 1, pitch = 1.6 },
			{ id = SLIDER, volume = 0.25, pitch = 1.4, delay = 0.05 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.6, Mix = 0.6, Rate = 3 } } },
	},

	-- A wet splat: a low slap of water and a thud (impact_water 2.38 s / 1.1 = 2.2 s, mostly tail).
	DeathInkSplat = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 170,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 0.9, pitch = 1.1 },
			{ id = HIT, volume = 0.6, pitch = 0.5 },
			{ id = LAND, volume = 0.5, pitch = 0.6 },
		},
	},

	-- A war drum landing: one deep boom (bass 1.01 s / 0.55 = 1.8 s) with a thump on top.
	DeathDrumBoom = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 240,
		category = "Effects",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.55 },
			{ id = BOOM3, volume = 0.35, pitch = 1.5 },
			{ id = HIT, volume = 0.6, pitch = 0.8, delay = 0.03 },
		},
	},

	-- Coins raining: bright pings a beat apart and a jingle of metal.
	DeathCoinJingle = {
		volume = 0.4,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = PING, volume = 0.8, pitch = 2.2 },
			{ id = METAL, volume = 0.6, pitch = 2.1, delay = 0.06 },
			{ id = PING, volume = 0.6, pitch = 2.6, delay = 0.14 },
		},
	},

	-- A digital glitch: clicks chopped by a fast tremolo, and a high blip.
	DeathGlitch = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 150,
		category = "Effects",
		layers = {
			{ id = CLICK, volume = 1, pitch = 0.7 },
			{ id = SWITCH3, volume = 0.7, pitch = 0.6, delay = 0.05 },
			{ id = PING, volume = 0.4, pitch = 2.8, delay = 0.08 },
		},
		effects = { { "TremoloSoundEffect", { Depth = 1, Frequency = 24 } } },
	},

	-- A brain swelling: a low throb rising under a stretched squeal (bass 1.01 s / 0.8 = 1.26 s).
	DeathBrainSwell = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 170,
		category = "Effects",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.8 },
			{ id = SLIDER, volume = 0.5, pitch = 0.9, delay = 0.1 },
			{ id = UUH, volume = 0.3, pitch = 1.3, delay = 0.35 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.4, Rate = 5 } } },
	},

	-- Thunder right overhead: a crack, then the roll (impact_explosion_02 2.12 s / 0.7 = 3.0 s).
	DeathThunder = {
		volume = 0.6,
		pitch = 1,
		maxDistance = 400,
		category = "Effects",
		layers = {
			{ id = SNAP, volume = 1, pitch = 0.5 },
			{ id = BOOM2, volume = 0.7, pitch = 0.7, delay = 0.04 },
			{ id = BASS, volume = 0.5, pitch = 0.5, delay = 0.06 },
		},
	},

	-- A vortex winding up: rushing water slowed right down, through a flanger (2.38 s / 0.9 = 2.6 s).
	DeathVortex = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 200,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 0.9, pitch = 0.9 },
			{ id = SLIDER, volume = 0.6, pitch = 0.55 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.9, Mix = 0.6, Rate = 2 } } },
	},

	-- A meteor coming in: a long falling scream of air (slider 0.85 s / 1.0).
	DeathMeteorFall = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 300,
		category = "Effects",
		layers = {
			{ id = SLIDER, volume = 1, pitch = 1 },
			{ id = WATER, volume = 0.3, pitch = 1.6 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 3, MidGain = 0, LowGain = -4 } } },
	},

	-- The meteor landing: a blast, so it carries and rolls off like the grenades do.
	DeathMeteorImpact = {
		volume = 0.65,
		pitch = 1,
		maxDistance = 500,
		category = "Effects",
		acoustic = "blast",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 0.8 },
			{ id = BOOM2, volume = 0.6, pitch = 0.6, delay = 0.05 },
			{ id = COLLIDE, volume = 0.5, pitch = 0.5 },
		},
	},

	-- A singularity opening: a deep hum and a groan, pulled out of shape (bass 1.01 s / 0.45 = 2.2 s).
	DeathSingularity = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 220,
		category = "Effects",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.45 },
			{ id = UUH, volume = 0.4, pitch = 0.5, delay = 0.1 },
			{ id = SLIDER, volume = 0.4, pitch = 0.4, delay = 0.2 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 1, Mix = 0.7, Rate = 1.5 } } },
	},

	--------------------------------------------------------------------------------
	-- Movement (StarterPlayerScripts/MovementClient): slides, climbs, vaults, stamina, item launches.
	-- Played for yourself with Sfx.Play and at other people's bodies with Sfx.PlayAt.
	--------------------------------------------------------------------------------

	-- Dropping into a slide: a skid. A light footfall as the body drops, then the drag itself — the
	-- slider file (a scrape) over cloth and grit, with a short hiss of gravel — and nothing under it.
	-- The lows are cut, not boosted. (#62: the old recipe was three IMPACT files all pitched DOWN —
	-- collide, Roblox's brick-crash bang, at 0.7; footsteps at 0.62; a landing at 0.8 — through
	-- distortion with the bass raised, which is exactly how the explosion cues are built, so every
	-- slide went off like a grenade; and the slowed footsteps ran 4.0 s against a 1.1 s slide, so it
	-- rumbled on long after the slide had ended.) Longest layer here: impact_water 2.38 s / 2.2 +
	-- 0.08 = 1.16 s, so the cue ends with the slide (MovementConfig.Slide.MaxTime 1.1).
	SlideStart = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 110,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 0.4, pitch = 1.15 },
			{ id = SLIDER, volume = 0.9, pitch = 0.9 },
			{ id = GETUP, volume = 0.7, pitch = 0.85, delay = 0.05 },
			{ id = WATER, volume = 0.3, pitch = 2.2, delay = 0.08 },
		},
		effects = {
			{ "EqualizerSoundEffect", { HighGain = 3, MidGain = 0, LowGain = -8 } },
		},
	},

	-- Hands slapping onto a ledge, then the heave up.
	Mantle = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 100,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 1.3 },
			{ id = GETUP, volume = 0.8, pitch = 1.15, delay = 0.06 },
		},
	},

	-- A quick hop over something: a light push-off, cloth over the sill, a thump on the far side.
	-- (#120: the middle layer was `collide`, the brick-collision crash, 1.09 s for a hop; a vault is
	-- about half a second.) Audible length 0.51 s.
	Vault = {
		volume = 0.48,
		pitch = 1,
		maxDistance = 100,
		category = "Effects",
		layers = {
			{ id = JUMP, volume = 0.9, pitch = 1.2 },
			{ id = GETUP, volume = 0.5, pitch = 1.4, delay = 0.03 },
			{ id = LAND, volume = 0.7, pitch = 0.95, delay = 0.24 },
		},
	},

	-- Out of breath: a short, low exhale.
	StaminaEmpty = {
		volume = 0.42,
		pitch = 1,
		category = "Effects",
		layers = {
			{ id = UUH, volume = 1, pitch = 0.72 },
			{ id = BASS, volume = 0.25, pitch = 0.6 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -10, MidGain = 0, LowGain = 2 } } },
	},

	-- Bounce Boots' second jump: a springy twang.
	DoubleJump = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 120,
		category = "Effects",
		layers = {
			{ id = JUMP, volume = 1, pitch = 1.45 },
			{ id = SWITCH3, volume = 0.5, pitch = 1.8 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.3, Mix = 0.4, Rate = 4 } } },
	},

	--------------------------------------------------------------------------------
	-- Footsteps (FootstepClient): one step each, picked by the ground under the body
	--------------------------------------------------------------------------------

	-- Every step is built on `action_jump_land`, the one short soft-impact file there is (0.26 s):
	-- a heel strike. What the ground adds goes on top: a gritty scuff for hard floors, a hollow
	-- knock for boards, a ring for metal, a splash for water, and for grass and sand the top end
	-- taken off because soft ground swallows the click of the strike. Quiet and short range: a
	-- footstep is heard across a room, not across a field.
	FootstepConcrete = {
		volume = 0.34,
		pitch = 1,
		maxDistance = 80,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 1.45 },
			{ id = CLICK, volume = 0.22, pitch = 0.6 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -4, MidGain = 0, HighGain = 2 } } },
	},
	FootstepGrass = {
		volume = 0.3,
		pitch = 1,
		maxDistance = 60,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 1.1 },
			{ id = SNAP, volume = 0.08, pitch = 0.45 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -2, MidGain = -2, HighGain = -9 } } },
	},
	FootstepWood = {
		volume = 0.36,
		pitch = 1,
		maxDistance = 80,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.95 },
			{ id = HIT, volume = 0.28, pitch = 0.55 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 1, MidGain = 3, HighGain = -3 } } },
	},
	FootstepMetal = {
		volume = 0.34,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 0.9, pitch = 1.3 },
			{ id = METAL, volume = 0.2, pitch = 1.9 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -3, MidGain = 1, HighGain = 3 } } },
	},
	FootstepWater = {
		volume = 0.34,
		pitch = 1,
		maxDistance = 80,
		category = "Effects",
		layers = {
			{ id = WATER, volume = 0.45, pitch = 2.2 },
			{ id = LAND, volume = 0.35, pitch = 1.2 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = -4, MidGain = 0, HighGain = 0 } } },
	},
	FootstepSand = {
		volume = 0.3,
		pitch = 1,
		maxDistance = 60,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.85 },
			{ id = SNAP, volume = 0.12, pitch = 0.35 },
		},
		effects = { { "EqualizerSoundEffect", { LowGain = 0, MidGain = -2, HighGain = -6 } } },
	},

	--------------------------------------------------------------------------------
	-- Vehicles
	--------------------------------------------------------------------------------

	-- The engine, played as a loop (Sfx.Loop) with its pitch driven by road speed: `bass` for the
	-- body of it, `action_falling` for a soft air rumble underneath (an 18 s loop, so its own seam
	-- is never heard), `clickfast` as the putter that beats with the pitch like an idle RPM. At a
	-- standstill the driver hears it at pitch 1; flat out it is pitched up about two and a half
	-- times. NOT `collide` (Roblox's brick-crash bang): a one-shot impact sample looped continuously
	-- is a car that keeps hitting something, not an engine -- that was #83 ("the cars sound is
	-- messed up") and #49 ("improve the sound of the carts running"), confirmed independently
	-- (loop periods re-derived from the files' own measured lengths above) and adopted 2026-09-21.
	VehicleEngine = {
		volume = 0.34,
		pitch = 1,
		maxDistance = 150,
		category = "Effects",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.5 },
			{ id = FALL, volume = 0.35, pitch = 0.55 },
			{ id = CLICK, volume = 0.25, pitch = 0.9 },
		},
		effects = {
			{ "EqualizerSoundEffect", { HighGain = -10, MidGain = -2, LowGain = 5 } },
			{ "DistortionSoundEffect", { Level = 0.12 } },
		},
	},

	-- Tyres at the limit: a thin screech that rides on top of the engine while a wheel is sliding.
	VehicleSkid = {
		volume = 0.26,
		pitch = 1,
		maxDistance = 140,
		category = "Effects",
		layers = {
			{ id = METAL, volume = 0.8, pitch = 1.7 },
			{ id = SWIM, volume = 0.35, pitch = 1.3 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 4, MidGain = -2, LowGain = -12 } } },
	},

	-- Landing a jump, or bottoming the suspension out on a bump: a dull thump with a body shake.
	VehicleLand = {
		volume = 0.55,
		pitch = 1,
		maxDistance = 150,
		category = "Effects",
		layers = {
			{ id = LAND, volume = 1, pitch = 0.55 },
			{ id = COLLIDE, volume = 0.5, pitch = 0.45, delay = 0.02 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = -6, MidGain = 0, LowGain = 5 } } },
	},

	-- Taking the seat: the starter catching.
	VehicleStart = {
		volume = 0.45,
		pitch = 1,
		maxDistance = 90,
		category = "Effects",
		layers = {
			{ id = SWITCH, volume = 0.9, pitch = 0.8 },
			{ id = BASS, volume = 0.5, pitch = 0.55, delay = 0.06 },
			{ id = COLLIDE, volume = 0.3, pitch = 0.4, delay = 0.1 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.15 } } },
	},

	-- A rocket, pad, glider updraft or blink throwing you: a whoomp with rushing air behind it.
	LaunchWhoosh = {
		volume = 0.5,
		pitch = 1,
		maxDistance = 160,
		category = "Effects",
		layers = {
			{ id = BOOM3, volume = 0.45, pitch = 1.6 },
			{ id = JUMP, volume = 0.8, pitch = 0.75, delay = 0.02 },
			{ id = SNAP, volume = 0.3, pitch = 0.7 },
		},
		effects = { { "EqualizerSoundEffect", { HighGain = 2, MidGain = -3, LowGain = 0 } } },
	},
}

--------------------------------------------------------------------------------
-- Acoustics (#120): distance, travel time and the room around the listener
--------------------------------------------------------------------------------
--
-- A cue's recipe is how it sounds at the source. These are the rules for what reaches your ear
-- from somewhere else, applied by Sfx on every positional play:
--
--   rolloff   each class of sound starts to fade at its own distance (RollOffMinDistance: a
--             gunshot is loud enough to still be at full level 24 studs off, a mag change is not)
--             and is gone by its `maxDistance`, clamped to the class's cap;
--   air       the top end goes first. Air and the ground soak up high frequencies far more than
--             low ones, which is why a distant gun is a dull thump and a distant blast is thunder:
--             an equaliser on each positional voice cuts High and Mid in proportion to distance;
--   travel    sound takes time to arrive. The scale is the one Roblox's own docs give, one stud =
--             0.28 m, so 343 m/s is 1225 studs/s: a blast 600 studs off is heard half a second
--             after it is seen, a shot across a 100-stud street 0.08 s after its flash;
--   crack     a rifle bullet outruns its own report (~900 m/s against 343), so a supersonic shot
--             that passes you is heard as a crack first and the muzzle's thump after it, the gap
--             growing with distance. Pistols, shotguns, suppressed and energy guns have no
--             separate crack;
--   room      reverb is a room. A gun or blast cue's reverb only plays when the listener has a
--             roof overhead (Sfx casts one ray up); out in the open its tail comes from layers
--             tagged `where = "outdoor"` instead: late, slowed copies of the boom, which is what
--             the terrain sends back. A cue whose reverb is part of its character, not a room,
--             says `tail = "always"`.
--
--   near/far  close up you hear the whole event; far off, only its low end. Layers tagged
--             `range = "near"` (the crack of a blast, its sub thump, its debris) fade out and
--             layers tagged `range = "far"` (a delayed, dull thump) fade in across the class's
--             XFADE band, so a shot 200 studs off is a different sound, not a quieter one;
--   yours     your own shot is heard from behind the gun, fuller and closer: layers tagged
--             `who = "self"` (the action cycling, the chest thump) play only on a flat Sfx.Play,
--             never on a positional one;
--   open      the outdoor slap-back comes from whatever is there to answer it: in a street the
--             walls answer fast, in open country the tree line and hills answer late and long.
--             Sfx casts OPEN.rays level rays from the listener; the share that hit nothing
--             stretches the outdoor layers' delay and lifts their level;
--   variety   every play is nudged in pitch and level by the class's `jitter` (a total span:
--             0.08 is +-4%), so automatic fire never repeats one identical sample;
--   caps      a cue plays through a fixed pool of voices (a new shot cuts the oldest tail), and
--             no more than BURST[class].max plays of a class start in one BURST window, so a
--             chain of blasts or a wall of full-auto can't stack into clipping. The Weapons and
--             Effects groups also run through a gentle bus compressor (BUS).
--
-- Layer tags: `crack = true` marks the bullet's crack; `where = "outdoor"` / `"indoor"` plays a
-- layer only there; `range` and `who` as above. Cue fields: `acoustic` names the class outright;
-- `distant = { cue, from, gain }` layers a far rumble in past `from` studs, and carries on alone
-- past the cue's own reach out to the rumble's; `calibre` (guns) and `blast` (explosives) pull in
-- the shared layers and reach of FIREARMS / BLASTS below; `novelty = true` marks a weapon that is
-- not a firearm (a bubble gun, a slipper launcher) and so gets none of the gunpowder.

local METRES_PER_STUD = 0.28

SoundConfig.Acoustics = {
	METRES_PER_STUD = METRES_PER_STUD,
	SPEED_OF_SOUND = 343 / METRES_PER_STUD, -- studs a second
	BULLET_SPEED = 900 / METRES_PER_STUD,
	-- The longest any sound is held back for travel. 1800 studs (the far rumble's reach) is 1.47 s.
	MAX_TRAVEL_DELAY = 1.6,
	-- A supersonic shot whose line misses the listener by more than this many studs is heard as a
	-- report only: its crack arrives with the report, at this fraction.
	CRACK_REACH = 40,
	CRACK_OFF_PATH = 0.5,
	-- A shot whose line passes within `reach` studs of the listener, fired from at least `minRange`
	-- away, whizzes past (BulletWhiz) as the bullet arrives.
	WHIZ = { reach = 6, minRange = 20 },
	-- Where a cue with no `maxDistance` fades out (before the class cap).
	DEFAULT_MAX_DISTANCE = 400,
	-- Effects on one Sound: the cue's own chain plus the per-play air and room effects. Every
	-- effect runs on every playing voice, so this is a performance cap as much as a tidy one.
	MAX_EFFECTS_PER_SOUND = 4,
	-- A roof within this many studs above the listener counts as being indoors.
	CEILING_REACH = 40,
	-- The room reverb given to a gun or blast cue that has none of its own.
	ROOM = { DecayTime = 0.9, WetLevel = -9, DryLevel = 0 },

	-- `xfade` is the near/far band in studs; `jitter` the per-play pitch and level span.
	CLASSES = {
		gun = { rollMin = 24, maxCap = 900, room = true, air = { low = 0, mid = -6, high = -20 }, xfade = { 60, 180 }, jitter = 0.08 },
		blast = { rollMin = 40, maxCap = 1000, room = true, air = { low = 3, mid = -8, high = -24 }, xfade = { 80, 260 }, jitter = 0.1 },
		energy = { rollMin = 18, maxCap = 800, room = true, air = { low = 0, mid = -4, high = -14 }, xfade = { 60, 180 }, jitter = 0.08 },
		suppressed = { rollMin = 8, maxCap = 200, room = true, air = { low = 0, mid = -3, high = -10 }, xfade = { 30, 90 }, jitter = 0.08 },
		-- Hands and feet: reloads, bolts, pickups, vaults. Short range in real life, short here.
		foley = { rollMin = 6, maxCap = 160, room = false, air = { low = 0, mid = -2, high = -8 }, xfade = { 20, 60 }, jitter = 0.08 },
		-- Everything else in the world: breaks, companions, vehicles. Keeps the old 14-stud start.
		world = { rollMin = 14, maxCap = 900, room = false, air = { low = 0, mid = -3, high = -10 }, xfade = { 40, 140 }, jitter = 0.06 },
	},

	-- No more than `max` plays of a class start inside one `window` (seconds): the rest of a chain of
	-- blasts, or of twenty guns firing in one frame, are dropped rather than stacked into clipping.
	BURST = {
		gun = { window = 1 / 30, max = 6 },
		blast = { window = 0.1, max = 3 },
		debris = { window = 0.1, max = 2 },
		whiz = { window = 0.08, max = 2 },
		distant = { window = 0.15, max = 2 },
		rumble = { window = 0.15, max = 2 },
	},
	-- Voices per cue: flat (your own) and positional (everyone else's). A new play takes the oldest
	-- voice and cuts its tail, which is what keeps full-auto from piling up.
	VOICES = { flat = 4, positional = 8 },
	-- Level rays for how open the country around the listener is, and how far an open sky
	-- stretches the outdoor echo's delay (x1 + stretch) and lifts it (x lift).
	OPEN = { rays = 4, reach = 90, ttl = 0.5, stretch = 0.8, lift = 0.35 },
	-- The bus compressor on each category's group: catches the sum of many voices, not one.
	BUS = {
		Weapons = { Threshold = -12, Ratio = 3, Attack = 0.004, Release = 0.2 },
		Effects = { Threshold = -14, Ratio = 3, Attack = 0.005, Release = 0.25 },
	},
	-- A big blast close by muffles the world for a moment (Sfx.Duck): the top end of every group
	-- drops by up to `high` dB and comes back over `hold` seconds. Only a blast whose cue says
	-- `duck = true`, only inside `reach` x its radius, and never for one smaller than `minRadius`.
	DUCK = { high = -16, mid = -5, hold = 1.0, reach = 1.5, minRadius = 9 },

	FOLEY = {
		Reload = true, DryFire = true, Equip = true, MagOut = true, MagIn = true, ChargeBack = true,
		ChargeRelease = true, SlideRelease = true, PumpBack = true, PumpForward = true, ShellIn = true,
		BoltBack = true, BoltForward = true, CylinderOpen = true, CylinderClose = true, HammerCock = true,
		BreakOpen = true, BreakClose = true, LeverOpen = true, LeverClose = true, CoverOpen = true,
		CoverClose = true, RocketSeat = true, StringCock = true, BoltSeat = true, EnergyCharge = true,
		CasingTink = true, Pickup = true, SlideStart = true, Mantle = true, Vault = true,
		DoubleJump = true, StaminaEmpty = true,
		ToyOut = true, ToyIn = true, ToyRack = true, WaterOut = true, WaterIn = true, WaterRack = true,
		-- A signature gun being shown off (Viewmodel's FLAIR clips) is handling noise too.
		FlairTap = true, FlairPop = true, FlairRattle = true, FlairChomp = true, FlairSqueak = true, FlairBeep = true,
		FlairSwipe = true, FlairWhoosh = true, FlairClank = true, FlairChime = true, FlairBat = true, FlairBounce = true,
		FlairKnock = true, FlairKiss = true, FlairTear = true, FlairWhir = true, FlairStamp = true,
		FlairBuzz = true, FlairSwat = true, FlairDrum = true,
	},
}

local Acoustics = SoundConfig.Acoustics

--------------------------------------------------------------------------------
-- Firearms and blasts: what every real gun and every real explosive shares, by size
--------------------------------------------------------------------------------
--
-- A cue's own layers are its character (the crack and body of THIS gun). What a gunshot is made of
-- in real life beyond that is the same for every gun of a calibre, so it lives here once and is
-- added to each cue that names a `calibre` (or a `blast` size) when this module loads:
--   body     (suppressed only) the muffled thump of the gas behind the can, which is most of what a
--            suppressed shot is;
--   action   the bolt or slide cycling just after the shot; only you, holding it, hear it;
--   chest    the low thump you feel behind your own gun and not from anyone else's;
--   room     indoors, a short boomy low bloom as the walls hand the blast straight back;
--   slap     outdoors, the report answered off the terrain (only when the cue has no echo of its
--            own); Sfx stretches it in open country;
--   far      from past the XFADE band, a delayed dull thump: all that's left of a shot at range;
--   reach    how far the report carries positionally, and `distant` how loud the flat far thump
--            (DistantGunfire) is out beyond that. Only the bigger calibres carry across the map.
-- `level` is the band the cue's own direct loudness must sit in (tools/sound_polish_check.py):
-- the tiers go up with calibre, so a pistol can never be louder than a rifle, nor a rifle than a
-- sniper. Layer volumes here are absolute (they are divided by the cue's own volume when added).
-- Tiers: 1 suppressed, 2 smg, 3 pistol, 4 revolver, 5 rifle/rotary, 6 lmg, 7 shotgun/dmr, 8 sniper,
-- 9 cannon. A launcher is a launch, not a report, so it has no tier.
SoundConfig.Firearms = {
	suppressed = { tier = 1, level = { 0.18, 0.28 }, reach = 140, body = { BASS, 0.07, 1.6 },
		chest = { BASS, 0.08, 1.8 }, room = { BASS, 0.07, 1.5 }, far = { BASS, 0.1, 1.7 } },
	smg = { tier = 2, level = { 0.29, 0.35 }, reach = 320,
		action = { CLICK, 0.1, 1.7, 0.03 }, chest = { BASS, 0.1, 2.2 }, room = { BASS, 0.1, 1.6 },
		slap = { BOOM3, 0.035, 1.0, 0.2 }, far = { BOOM3, 0.08, 0.95 } },
	pistol = { tier = 3, level = { 0.36, 0.42 }, reach = 360,
		action = { SWITCH, 0.1, 1.5, 0.045 }, chest = { BASS, 0.12, 2.0 }, room = { BASS, 0.12, 1.4 },
		slap = { BOOM3, 0.04, 0.95, 0.22 }, far = { BOOM3, 0.09, 0.9 } },
	revolver = { tier = 4, level = { 0.43, 0.46 }, reach = 420,
		action = { CLICK, 0.09, 1.05, 0.06 }, chest = { BASS, 0.16, 1.5 }, room = { BASS, 0.16, 1.2 },
		slap = { BOOM3, 0.05, 0.9, 0.24 }, far = { BOOM3, 0.11, 0.8 } },
	rifle = { tier = 5, level = { 0.47, 0.52 }, reach = 480, distant = 0.5,
		action = { CLICK, 0.09, 1.3, 0.04 }, chest = { BASS, 0.14, 1.8 }, room = { BASS, 0.15, 1.3 },
		slap = { BOOM3, 0.05, 0.95, 0.25 }, far = { BOOM3, 0.12, 0.8 } },
	rotary = { tier = 5, level = { 0.47, 0.52 }, reach = 480, distant = 0.5,
		chest = { BASS, 0.1, 2.2 }, room = { BASS, 0.1, 1.6 },
		slap = { BOOM3, 0.035, 1.0, 0.25 }, far = { BOOM3, 0.1, 0.9 } },
	lmg = { tier = 6, level = { 0.52, 0.565 }, reach = 520, distant = 0.6,
		action = { CLICK, 0.1, 1.1, 0.04 }, chest = { BASS, 0.16, 1.6 }, room = { BASS, 0.16, 1.2 },
		slap = { BOOM3, 0.055, 0.9, 0.26 }, far = { BOOM3, 0.13, 0.75 } },
	shotgun = { tier = 7, level = { 0.57, 0.645 }, reach = 600, distant = 0.6,
		chest = { BASS, 0.22, 0.9 }, room = { BASS, 0.2, 0.9 },
		slap = { BOOM3, 0.07, 0.75, 0.28 }, far = { BOOM3, 0.15, 0.6 } },
	dmr = { tier = 7, level = { 0.57, 0.645 }, reach = 600, distant = 0.75,
		action = { SWITCH, 0.1, 1.1, 0.05 }, chest = { BASS, 0.2, 1.3 }, room = { BASS, 0.18, 1.1 },
		slap = { BOOM3, 0.07, 0.8, 0.3 }, far = { BOOM3, 0.15, 0.7 } },
	sniper = { tier = 8, level = { 0.66, 0.74 }, reach = 900, distant = 1,
		chest = { BASS, 0.3, 0.7 }, room = { BASS, 0.25, 0.8 },
		slap = { BOOM3, 0.09, 0.7, 0.35 }, far = { BOOM3, 0.2, 0.55 } },
	cannon = { tier = 9, level = { 0.75, 0.86 }, reach = 900, distant = 1,
		chest = { BASS, 0.32, 0.6 }, room = { BASS, 0.3, 0.7 },
		slap = { BOOM3, 0.1, 0.6, 0.4 }, far = { BOOM3, 0.22, 0.5 } },
	launcher = { reach = 650, distant = 0.6,
		chest = { BASS, 0.25, 0.7 }, room = { BASS, 0.22, 0.8 },
		slap = { BOOM3, 0.08, 0.7, 0.3 }, far = { BOOM3, 0.15, 0.6 } },
}

-- Explosives by size. Every real blast has a crack (the cue's own, fading out with distance), a
-- body, a sub thump you feel up close, debris coming down after it, and a tail; `level` bands go up
-- with size (grenade < frag/mine < rocket/barrel < a vehicle going up) and so does `reach`.
SoundConfig.Blasts = {
	grenade = { tier = 1, level = { 0.8, 0.95 }, reach = 750,
		sub = { BASS, 0.5, 0.5 }, room = { BASS, 0.35, 0.7 },
		debris = { { COLLIDE, 0.16, 0.55, 0.16 }, { STEPS, 0.14, 0.7, 0.3 } }, far = { BOOM3, 0.3, 0.45, 0.1 } },
	frag = { tier = 2, level = { 1.05, 1.25 }, reach = 850,
		sub = { BASS, 0.6, 0.45 }, room = { BASS, 0.4, 0.65 },
		debris = { { COLLIDE, 0.2, 0.5, 0.18 }, { STEPS, 0.16, 0.6, 0.34 } }, far = { BOOM3, 0.35, 0.42, 0.1 } },
	rocket = { tier = 3, level = { 1.3, 1.5 }, reach = 900,
		sub = { BASS, 0.7, 0.42 }, room = { BASS, 0.45, 0.6 },
		debris = { { COLLIDE, 0.24, 0.45, 0.2 }, { STEPS, 0.18, 0.55, 0.38 } }, far = { BOOM3, 0.4, 0.4, 0.12 } },
	vehicle = { tier = 4, level = { 1.55, 1.85 }, reach = 1000,
		sub = { BASS, 0.8, 0.38 }, room = { BASS, 0.5, 0.55 },
		debris = { { METAL, 0.3, 0.55, 0.22 }, { COLLIDE, 0.26, 0.4, 0.4 }, { METAL, 0.16, 0.8, 0.58 } },
		far = { BOOM3, 0.45, 0.36, 0.12 } },
}

-- What an explosion throws down depends on what it went off against (ProjectileClient reads the
-- surface under the blast): a patter of earth, a rattle of rubble, splinters, a clang, glass, a
-- splash. Enum.Material names to debris cues; anything else is rubble.
SoundConfig.Debris = {
	MATERIAL = {
		Grass = "DebrisDirt", LeafyGrass = "DebrisDirt", Ground = "DebrisDirt", Mud = "DebrisDirt", Sand = "DebrisDirt",
		Snow = "DebrisDirt", Fabric = "DebrisDirt",
		Wood = "DebrisWood", WoodPlanks = "DebrisWood", Cardboard = "DebrisWood",
		Metal = "DebrisMetal", CorrodedMetal = "DebrisMetal", DiamondPlate = "DebrisMetal", Foil = "DebrisMetal",
		Glass = "DebrisGlass", Ice = "DebrisGlass", Water = "DebrisWater",
	},
	DEFAULT = "DebrisRubble",
}

-- A novelty gun's reload: each mechanical stage the viewmodel plays (Viewmodel's "sound" events)
-- becomes its toy or water-gun stand-in, by the shot cue's `foley`. A firearm keeps the real thing.
SoundConfig.NoveltyFoley = {
	STAGE = {
		MagOut = "Out", CylinderOpen = "Out", BreakOpen = "Out", CoverOpen = "Out", LeverOpen = "Out", BoltBack = "Out",
		MagIn = "In", ShellIn = "In", CylinderClose = "In", BreakClose = "In", CoverClose = "In", RocketSeat = "In",
		BoltSeat = "In",
		ChargeBack = "Rack", ChargeRelease = "Rack", SlideRelease = "Rack", PumpBack = "Rack", PumpForward = "Rack",
		BoltForward = "Rack", LeverClose = "Rack", HammerCock = "Rack",
	},
	KIND = { toy = "Toy", water = "Water" },
}

function SoundConfig.FoleyFor(shotCue, stageCue)
	local cue = SoundConfig.Sounds[shotCue or ""]
	local kind = cue and cue.novelty and SoundConfig.NoveltyFoley.KIND[cue.foley or ""]
	local stage = SoundConfig.NoveltyFoley.STAGE[stageCue or ""]
	if kind and stage then
		return kind .. stage
	end
	return stageCue
end

-- Whether a shot cue is a novelty gun's (no gunpowder, no brass).
function SoundConfig.IsNovelty(shotCue)
	local cue = SoundConfig.Sounds[shotCue or ""]
	return cue ~= nil and cue.novelty == true
end

function SoundConfig.DebrisCue(materialName)
	if materialName == nil or materialName == "Air" then
		return nil
	end
	return SoundConfig.Debris.MATERIAL[materialName] or SoundConfig.Debris.DEFAULT
end

-- A shared layer spec { id, absolute volume, pitch, delay } as a layer of `cue`.
local function sharedLayer(cue, spec, tags)
	local layer = { id = spec[1], volume = spec[2] / (cue.volume or 1), pitch = spec[3] / (cue.pitch or 1), delay = spec[4] or 0 }
	for key, value in pairs(tags) do
		layer[key] = value
	end
	return layer
end

local function hasLayer(cue, key, value)
	for _, layer in ipairs(cue.layers) do
		if layer[key] == value then
			return true
		end
	end
	return false
end

local function addShared(cue, family)
	if type(cue.layers) ~= "table" then
		cue.layers = { { id = cue.id } }
		cue.id = nil
	end
	cue.maxDistance = family.reach
	if family.body then
		table.insert(cue.layers, sharedLayer(cue, family.body, { role = "body" }))
	end
	if family.action then
		table.insert(cue.layers, sharedLayer(cue, family.action, { who = "self", role = "action" }))
	end
	if family.chest then
		table.insert(cue.layers, sharedLayer(cue, family.chest, { who = "self", role = "chest" }))
	end
	if family.sub then
		table.insert(cue.layers, sharedLayer(cue, family.sub, { range = "near", role = "sub" }))
	end
	for _, spec in ipairs(family.debris or {}) do
		table.insert(cue.layers, sharedLayer(cue, spec, { range = "near", role = "debris" }))
	end
	table.insert(cue.layers, sharedLayer(cue, family.room, { where = "indoor", role = "room" }))
	if family.slap and not hasLayer(cue, "where", "outdoor") then
		table.insert(cue.layers, sharedLayer(cue, family.slap, { where = "outdoor", role = "slap" }))
	end
	table.insert(cue.layers, sharedLayer(cue, family.far, { range = "far", role = "far" }))
end

for _, cue in pairs(SoundConfig.Sounds) do
	local firearm = cue.calibre and SoundConfig.Firearms[cue.calibre]
	local blast = cue.blast and SoundConfig.Blasts[cue.blast]
	if firearm then
		addShared(cue, firearm)
		if firearm.distant then
			cue.distant = { cue = "DistantGunfire", from = math.floor(firearm.reach * 0.6), gain = firearm.distant }
		end
	elseif blast then
		addShared(cue, blast)
	end
end

function SoundConfig.ClassOf(name, cue)
	if cue and Acoustics.CLASSES[cue.acoustic or ""] then
		return cue.acoustic
	end
	if Acoustics.FOLEY[name] or (type(name) == "string" and string.sub(name, 1, 8) == "Footstep") then
		return "foley"
	end
	if type(name) == "string" and string.sub(name, 1, 7) == "Gunshot" then
		return "gun"
	end
	if type(name) == "string" and string.sub(name, 1, 9) == "Explosion" then
		return "blast"
	end
	return "world"
end

-- The per-play pitch and level span for a cue (0.08 is +-4%): its own `jitter`, else its class's.
function SoundConfig.JitterOf(name, cue)
	if cue and type(cue.jitter) == "number" then
		return cue.jitter
	end
	return Acoustics.CLASSES[SoundConfig.ClassOf(name, cue)].jitter or 0
end

-- RollOffMinDistance and RollOffMaxDistance for a cue played in the world.
function SoundConfig.Rolloff(name, cue)
	local class = Acoustics.CLASSES[SoundConfig.ClassOf(name, cue)]
	local far = (cue and cue.maxDistance) or Acoustics.DEFAULT_MAX_DISTANCE
	return class.rollMin, math.clamp(far, class.rollMin + 1, class.maxCap)
end

-- Whether this cue's reverb is a room (played only under a roof) rather than part of the sound.
function SoundConfig.RoomGated(name, cue)
	return Acoustics.CLASSES[SoundConfig.ClassOf(name, cue)].room and not (cue and cue.tail == "always")
end

-- The equaliser gains (dB) that air and ground take off a cue heard `distance` studs away: none
-- inside the rolloff's start, the class's full cut at its far edge, linear between (absorption in
-- dB grows in proportion to the path length).
function SoundConfig.AirAt(name, cue, distance)
	local class = Acoustics.CLASSES[SoundConfig.ClassOf(name, cue)]
	local near, far = SoundConfig.Rolloff(name, cue)
	local t = math.clamp((distance - near) / (far - near), 0, 1)
	return class.air.low * t, class.air.mid * t, class.air.high * t
end

-- How loud a far rumble cue (ExplosionFar) is `distance` studs off: full out to half its reach,
-- then fading to nothing at its `maxDistance`.
function SoundConfig.DistantGain(cue, distance)
	local reach = (cue and cue.maxDistance) or Acoustics.DEFAULT_MAX_DISTANCE
	return math.clamp((reach - distance) / (reach * 0.5), 0, 1)
end

-- Everything about one play of a cue that depends on where it is heard from. `nearPath` is false
-- when the shot's line is known to miss the listener; nil means not known, taken as near.
--   start          seconds before the voice starts (whatever arrives first)
--   layers         per layer { delay = seconds after start, gain = volume multiplier }
--   room           the room reverb on or off, or nil when this cue's reverb is not a room
--   low/mid/high   the air equaliser's gains
--   distant        the gain for the cue's `distant` rumble, 0 when there is none
-- `listen`, optional: { own = true } for your own flat play (the `who = "self"` layers sound, the
-- far ones never do), and `open` 0..1, how open the country is (Sfx.Openness), for the slap-back.
function SoundConfig.Plan(name, cue, distance, enclosed, nearPath, listen)
	local layers = SoundConfig.LayersOf(cue)
	if not layers then
		return nil
	end
	distance = math.max(distance or 0, 0)
	local supersonic = false
	for _, layer in ipairs(layers) do
		if layer.crack then
			supersonic = true
		end
	end
	local report = distance / Acoustics.SPEED_OF_SOUND
	local first = report
	if supersonic and nearPath ~= false then
		first = distance / Acoustics.BULLET_SPEED
	end
	if report > Acoustics.MAX_TRAVEL_DELAY then
		local squeeze = Acoustics.MAX_TRAVEL_DELAY / report
		report *= squeeze
		first *= squeeze
	end

	local own = type(listen) == "table" and listen.own == true
	local open = type(listen) == "table" and math.clamp(tonumber(listen.open) or 0, 0, 1) or 0
	local band = Acoustics.CLASSES[SoundConfig.ClassOf(name, cue)].xfade
	local fade = own and 0 or math.clamp((distance - band[1]) / (band[2] - band[1]), 0, 1)
	local openness = Acoustics.OPEN

	local plan = { start = first, layers = {}, room = nil, distant = 0 }
	for index, layer in ipairs(layers) do
		local gain = 1
		local delay = layer.delay
		if (layer.where == "outdoor" and enclosed) or (layer.where == "indoor" and not enclosed) then
			gain = 0
		elseif layer.who == "self" and not own then
			gain = 0
		elseif layer.crack and nearPath == false then
			gain = Acoustics.CRACK_OFF_PATH
		end
		if layer.range == "near" then
			gain *= 1 - fade
		elseif layer.range == "far" then
			gain *= fade
		end
		if layer.where == "outdoor" then
			delay *= 1 + openness.stretch * open
			gain *= 1 + openness.lift * (open - 0.5)
		end
		local arrives = layer.crack and first or report
		plan.layers[index] = { delay = delay + (arrives - first), gain = gain }
	end
	if SoundConfig.RoomGated(name, cue) then
		plan.room = enclosed == true
	end
	plan.low, plan.mid, plan.high = SoundConfig.AirAt(name, cue, distance)
	if type(cue.distant) == "table" then
		local _, far = SoundConfig.Rolloff(name, cue)
		local from = cue.distant.from or 0
		plan.distant = math.clamp((distance - from) / math.max(far - from, 1), 0, 1) * (cue.distant.gain or 1)
	end
	return plan
end

--------------------------------------------------------------------------------
-- Footsteps: which step cue a floor gets, and how often a body at a given speed steps
--------------------------------------------------------------------------------

SoundConfig.Footsteps = {
	-- Enum.Material names to step cues. Anything missing sounds like a hard floor; Air never steps.
	MATERIAL = {
		Grass = "FootstepGrass", LeafyGrass = "FootstepGrass", Ground = "FootstepGrass", Mud = "FootstepGrass",
		Fabric = "FootstepGrass",
		Sand = "FootstepSand", Snow = "FootstepSand", Salt = "FootstepSand", Sandstone = "FootstepSand",
		Wood = "FootstepWood", WoodPlanks = "FootstepWood", Cardboard = "FootstepWood",
		Metal = "FootstepMetal", CorrodedMetal = "FootstepMetal", DiamondPlate = "FootstepMetal",
		Foil = "FootstepMetal",
		Water = "FootstepWater",
	},
	DEFAULT = "FootstepConcrete",
	-- Cadence, from how people actually walk and run: about 1.8 steps a second at a 1.4 m/s walk,
	-- 2.75 at a 4.5 m/s jog (the default 16 studs/s), topping out near 3.4 at a sprint. Linear in
	-- speed in metres a second (SoundConfig.Acoustics.METRES_PER_STUD), clamped.
	CADENCE_BASE = 1.4,
	CADENCE_PER_MPS = 0.3,
	CADENCE_MIN = 1.6,
	CADENCE_MAX = 3.4,
	-- Slower than this (studs/s, across the ground) is standing, not walking.
	MIN_SPEED = 2,
	-- Only bodies this close to the camera step, and only the nearest few of those.
	REACH = 90,
	MAX_BODIES = 8,
	-- Your own steps, played flat, sit under everything else rather than on top of it.
	SELF_GAIN = 0.55,
	-- A jog is the reference; a sprint lands harder, a walk softer.
	GAIN_MIN = 0.7,
	GAIN_MAX = 1.25,
}

-- The step cue for a floor, by Enum.Material name; nil in the air.
function SoundConfig.FootstepCue(materialName)
	if materialName == nil or materialName == "Air" then
		return nil
	end
	return SoundConfig.Footsteps.MATERIAL[materialName] or SoundConfig.Footsteps.DEFAULT
end

-- Steps a second at `speed` studs a second across the ground; 0 when standing.
function SoundConfig.StepRate(speed)
	local steps = SoundConfig.Footsteps
	if speed < steps.MIN_SPEED then
		return 0
	end
	local metres = speed * Acoustics.METRES_PER_STUD
	return math.clamp(steps.CADENCE_BASE + steps.CADENCE_PER_MPS * metres, steps.CADENCE_MIN, steps.CADENCE_MAX)
end

-- How hard a step at `speed` lands, 1 at the default 16 studs/s.
function SoundConfig.StepGain(speed)
	local steps = SoundConfig.Footsteps
	return math.clamp(speed / 16, steps.GAIN_MIN, steps.GAIN_MAX)
end

-- Every cue as a list of layers, whether it was written as one file or several. Each layer is
-- `{ id, volume, pitch, delay }` with the cue's own volume and pitch already folded in, so a
-- caller only has to apply its own jitter on top.
function SoundConfig.LayersOf(cue)
	if not cue then
		return nil
	end
	local base = cue.volume or 1
	local basePitch = cue.pitch or 1
	local layers = {}
	if type(cue.layers) == "table" and #cue.layers > 0 then
		for _, layer in ipairs(cue.layers) do
			if type(layer.id) == "string" and layer.id ~= "" then
				table.insert(layers, {
					id = layer.id,
					volume = base * (layer.volume or 1),
					pitch = basePitch * (layer.pitch or 1),
					delay = layer.delay or 0,
					crack = layer.crack == true,
					where = layer.where,
					who = layer.who,
					range = layer.range,
					role = layer.role,
				})
			end
		end
	elseif type(cue.id) == "string" and cue.id ~= "" then
		table.insert(layers, { id = cue.id, volume = base, pitch = basePitch, delay = 0 })
	end
	if #layers == 0 then
		return nil
	end
	return layers
end

function SoundConfig.Get(name)
	local sound = SoundConfig.Sounds[name]
	if not sound or not SoundConfig.LayersOf(sound) then
		return nil
	end
	return sound
end

return SoundConfig
