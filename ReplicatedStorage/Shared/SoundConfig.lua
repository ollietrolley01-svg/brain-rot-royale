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
		volume = 0.34,
		pitch = 1,
		maxDistance = 420,
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

	-- Your shot landed: a short high tick, deliberately thin so it cuts through the shot itself.
	HitConfirm = {
		volume = 0.5,
		pitch = 1,
		category = "Weapons",
		layers = {
			{ id = CLICK, volume = 1, pitch = 1.9 },
			{ id = SWITCH, volume = 0.5, pitch = 1.6 },
		},
	},

	-- A headshot, for the shooter: the hit tick with a bell over it so it reads as better.
	Headshot = {
		volume = 0.62,
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
		volume = 0.5,
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
		-- Crisp and dry: a bright crack, a short pop of body, almost no tail.
		volume = 0.34,
		pitch = 1,
		maxDistance = 360,
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
		volume = 0.32,
		pitch = 1,
		maxDistance = 320,
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
		volume = 0.4,
		pitch = 1,
		maxDistance = 420,
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
		-- Crack plus a mid body and a little chest, and a faint metallic ring off the receiver.
		volume = 0.36,
		pitch = 1,
		maxDistance = 460,
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
		volume = 0.4,
		pitch = 1,
		maxDistance = 620,
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
		volume = 0.38,
		pitch = 1,
		maxDistance = 520,
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
		-- The chaingun at 13 a second: each shot short and tight so the stream is a buzz-saw roar, the
		-- weight carried by the bass rather than a long body, the top end shaved so it doesn't tire you.
		volume = 0.34,
		pitch = 1,
		maxDistance = 500,
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
		-- Mostly boom: a wide explosion body, a lower crack, a thump of bass and a short room tail.
		-- Pitched lower than any rifle: a 12-bore's muzzle blast comes out of a wide bore at low
		-- pressure, so its energy sits an octave or so under a rifle's, and the shot is subsonic, so
		-- there is no separate crack.
		volume = 0.42,
		pitch = 1,
		maxDistance = 440,
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
		-- The loudest single crack in the game, a heavy body, and a long outdoor roll: a quiet, slow
		-- second explosion a beat later, under a long reverb, so it is heard across the map.
		volume = 0.44,
		pitch = 1,
		maxDistance = 800,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.1, crack = true },
			{ id = BOOM2, volume = 0.95, pitch = 1.4 },
			{ id = BASS, volume = 0.7, pitch = 1.0 },
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
		-- A cough, not a crack: a thin high tick, the action cycling, a hiss of gas; lows cut.
		acoustic = "suppressed",
		volume = 0.38,
		pitch = 1,
		maxDistance = 140,
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
		-- A launch, not a bang: a deep whoomp out of the tube, the motor's whoosh, a thump and a tail.
		volume = 0.46,
		pitch = 1,
		maxDistance = 650,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 0.8, pitch = 1.2 },
			{ id = JUMP, volume = 0.85, pitch = 0.5 },
			{ id = FALL, volume = 0.3, pitch = 2.2 },
			{ id = BASS, volume = 0.65, pitch = 0.8 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.4, WetLevel = -9, DryLevel = 0 } } },
	},
	GunshotRail = {
		-- Electric: a descending ping, a hard bright crack, a zip of charge, flanged so it shimmers.
		acoustic = "energy",
		volume = 0.44,
		pitch = 1,
		maxDistance = 700,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.85, pitch = 0.4 },
			{ id = SNAP, volume = 0.6, pitch = 2.3 },
			{ id = BASS, volume = 0.55, pitch = 2.0 },
			{ id = BOOM2, volume = 0.3, pitch = 3.0 },
			{ id = SLIDER, volume = 0.15, pitch = 3.0 },
		},
		effects = {
			{ "FlangeSoundEffect", { Depth = 0.6, Mix = 0.45, Rate = 9 } },
			{ "EqualizerSoundEffect", { LowGain = 0, MidGain = 0, HighGain = 3 } },
		},
	},
	GunshotBubble = {
		-- A pop and a blub: a tiny high snap, water, a springy bounce, a soft click, chorused wet.
		volume = 0.4,
		pitch = 1,
		maxDistance = 220,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.3, pitch = 3.3 },
			{ id = WATER, volume = 0.55, pitch = 2.5 },
			{ id = JUMP, volume = 0.35, pitch = 2.1 },
			{ id = BUTTON, volume = 0.25, pitch = 2.0 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.2, Mix = 0.4, Rate = 3 } } },
	},
	GunshotCrossbow = {
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
		-- The biggest report there is: a slow full-length explosion, a low crack, heavy bass, a second
		-- boom a beat behind for the muzzle blast, and a long tail.
		volume = 0.48,
		pitch = 1,
		maxDistance = 700,
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
		volume = 0.4,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = OOF, volume = 0.35, pitch = 2.6 },
			{ id = SNAP, volume = 0.5, pitch = 2.0 },
			{ id = BUTTON, volume = 0.3, pitch = 2.4 },
		},
		effects = { { "ChorusSoundEffect", { Depth = 0.15, Mix = 0.35, Rate = 5 } } },
	},
	GunshotSquirt = {
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
		-- Spaghetti Slinger: a shotgun's boom with a wet splat in it.
		volume = 0.42,
		pitch = 1,
		maxDistance = 420,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 0.8, pitch = 1.9 },
			{ id = WATER, volume = 0.4, pitch = 1.4 },
			{ id = SNAP, volume = 0.6, pitch = 1.0 },
			{ id = BASS, volume = 0.4, pitch = 1.4 },
		},
		effects = { { "DistortionSoundEffect", { Level = 0.2 } } },
	},
	GunshotBassDrop = {
		-- Boombox Bassline: the drop. A distorted sub thump, a tape clunk, and a quick echo.
		volume = 0.46,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = BASS, volume = 1, pitch = 0.6 },
			{ id = BOOM2, volume = 0.5, pitch = 1.2 },
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
		-- Gumball Gatling: plastic clacks and a bounce, fast and light for 12 a second.
		volume = 0.32,
		pitch = 1,
		maxDistance = 300,
		category = "Weapons",
		layers = {
			{ id = BUTTON, volume = 0.6, pitch = 1.2 },
			{ id = COLLIDE, volume = 0.4, pitch = 2.4 },
			{ id = SNAP, volume = 0.4, pitch = 1.6 },
			{ id = CLICK, volume = 0.3, pitch = 1.0 },
		},
	},
	GunshotFidget = {
		-- Fidget Disc Launcher: a whirr spinning up, a ping, a flat launch snap, flanged.
		volume = 0.42,
		pitch = 1,
		maxDistance = 400,
		category = "Weapons",
		layers = {
			{ id = SLIDER, volume = 0.5, pitch = 2.0 },
			{ id = PING, volume = 0.3, pitch = 1.8 },
			{ id = SNAP, volume = 0.5, pitch = 1.5 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.4, Rate = 12 } } },
	},
	GunshotZap = {
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
		volume = 0.36,
		pitch = 1,
		maxDistance = 360,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.6, pitch = 1.2 },
			{ id = BASS, volume = 0.5, pitch = 1.4 },
			{ id = SNAP, volume = 0.4, pitch = 2.2 },
		},
		effects = {
			{ "ChorusSoundEffect", { Depth = 0.3, Mix = 0.5, Rate = 2 } },
			{ "FlangeSoundEffect", { Depth = 0.4, Mix = 0.3, Rate = 4 } },
		},
	},
	GunshotToaster = {
		-- Toaster Mortar: the pop-up spring, a launch whoomp, and a "ding" a beat later.
		volume = 0.46,
		pitch = 1,
		maxDistance = 520,
		category = "Weapons",
		layers = {
			{ id = JUMP, volume = 0.8, pitch = 0.45 },
			{ id = SWITCH3, volume = 0.6, pitch = 0.6 },
			{ id = BOOM3, volume = 0.5, pitch = 1.5 },
			{ id = PING, volume = 0.3, pitch = 1.6, delay = 0.1 },
		},
	},
	GunshotChicken = {
		-- Rubber Chicken Railgun: the rail's electric crack, and the chicken screaming over it.
		volume = 0.46,
		pitch = 1,
		maxDistance = 700,
		category = "Weapons",
		layers = {
			{ id = PING, volume = 0.8, pitch = 0.4 },
			{ id = SNAP, volume = 0.6, pitch = 2.3 },
			{ id = BASS, volume = 0.5, pitch = 2.0 },
			{ id = UUH, volume = 0.55, pitch = 1.7, delay = 0.02 },
			{ id = OOF, volume = 0.3, pitch = 2.2, delay = 0.02 },
		},
		effects = { { "FlangeSoundEffect", { Depth = 0.5, Mix = 0.35, Rate = 9 } } },
	},
	GunshotLavaLamp = {
		-- Lava Lamp Lancer: a marksman rifle's report with a deep, liquid bloop under it.
		-- Its reverb is part of the bloop, not a room, so it plays indoors and out.
		tail = "always",
		volume = 0.4,
		pitch = 1,
		maxDistance = 600,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 1, pitch = 1.2 },
			{ id = BOOM2, volume = 0.7, pitch = 1.8 },
			{ id = BASS, volume = 0.3, pitch = 0.8 },
			{ id = WATER, volume = 0.2, pitch = 0.8 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.1, WetLevel = -11, DryLevel = 0 } } },
	},
	GunshotSnow = {
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
		volume = 0.62,
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

	-- A rocket going off: a sharp crack off `snap`, the two explosion files under it, one slowed
	-- for the deep body, and a sub thump. A long room tail, because a blast fills a street.
	-- Every blast: the reverb is the room when the listener is under a roof; out in the open the tail
	-- is a late, slowed echo off the terrain instead, and past `distant.from` studs the ExplosionFar
	-- rumble is layered in underneath as the crack and the top end fall away.
	ExplosionRocket = {
		volume = 0.8,
		pitch = 1,
		maxDistance = 900,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.5 },
			{ id = BOOM2, volume = 1, pitch = 1.1 },
			{ id = BOOM3, volume = 1, pitch = 0.72 },
			{ id = BASS, volume = 0.9, pitch = 0.55 },
			{ id = BOOM3, volume = 0.35, pitch = 0.5, delay = 0.45, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.4, WetLevel = -8, DryLevel = 0 } } },
	},
	-- A 40mm: smaller and sharper, less tail.
	ExplosionGrenade = {
		volume = 0.7,
		pitch = 1,
		maxDistance = 750,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.65 },
			{ id = BOOM2, volume = 1, pitch = 1.3 },
			{ id = BASS, volume = 0.7, pitch = 0.75 },
			{ id = BOOM3, volume = 0.25, pitch = 0.6, delay = 0.4, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.5, WetLevel = -9, DryLevel = 0 } } },
	},
	-- A frag: the body of the rocket's blast with a metallic ring over it for the fragments.
	ExplosionFrag = {
		volume = 0.8,
		pitch = 1,
		maxDistance = 850,
		category = "Weapons",
		distant = { cue = "ExplosionFar", from = 250 },
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.55 },
			{ id = BOOM3, volume = 1, pitch = 0.9 },
			{ id = BOOM2, volume = 0.8, pitch = 1.25 },
			{ id = METAL, volume = 0.5, pitch = 0.8, delay = 0.05 },
			{ id = BASS, volume = 0.8, pitch = 0.6 },
			{ id = BOOM3, volume = 0.3, pitch = 0.5, delay = 0.45, where = "outdoor" },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.0, WetLevel = -8, DryLevel = 0 } } },
	},
	-- The same blast heard from across the map: a rumble with the top taken off, played flat (not
	-- positional) at a volume set by distance, so a fight far away still reads as thunder. Its reverb
	-- is the roll of distance, not a room, so it plays under a roof or not. `maxDistance` here is
	-- where Sfx.PlayDistant fades it to nothing (ProjectileClient's FAR_RUMBLE).
	ExplosionFar = {
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
-- Layer tags: `crack = true` marks the bullet's crack; `where = "outdoor"` / `"indoor"` plays a
-- layer only there. Cue fields: `acoustic` names the class outright; `distant = { cue, from }`
-- layers a far rumble in past `from` studs.

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
	-- Where a cue with no `maxDistance` fades out (before the class cap).
	DEFAULT_MAX_DISTANCE = 400,
	-- Effects on one Sound: the cue's own chain plus the per-play air and room effects. Every
	-- effect runs on every playing voice, so this is a performance cap as much as a tidy one.
	MAX_EFFECTS_PER_SOUND = 4,
	-- A roof within this many studs above the listener counts as being indoors.
	CEILING_REACH = 40,
	-- The room reverb given to a gun or blast cue that has none of its own.
	ROOM = { DecayTime = 0.9, WetLevel = -9, DryLevel = 0 },

	CLASSES = {
		gun = { rollMin = 24, maxCap = 900, room = true, air = { low = 0, mid = -6, high = -20 } },
		blast = { rollMin = 40, maxCap = 1000, room = true, air = { low = 3, mid = -8, high = -24 } },
		energy = { rollMin = 18, maxCap = 800, room = true, air = { low = 0, mid = -4, high = -14 } },
		suppressed = { rollMin = 8, maxCap = 200, room = true, air = { low = 0, mid = -3, high = -10 } },
		-- Hands and feet: reloads, bolts, pickups, vaults. Short range in real life, short here.
		foley = { rollMin = 6, maxCap = 160, room = false, air = { low = 0, mid = -2, high = -8 } },
		-- Everything else in the world: breaks, companions, vehicles. Keeps the old 14-stud start.
		world = { rollMin = 14, maxCap = 900, room = false, air = { low = 0, mid = -3, high = -10 } },
	},

	FOLEY = {
		Reload = true, DryFire = true, Equip = true, MagOut = true, MagIn = true, ChargeBack = true,
		ChargeRelease = true, SlideRelease = true, PumpBack = true, PumpForward = true, ShellIn = true,
		BoltBack = true, BoltForward = true, CylinderOpen = true, CylinderClose = true, HammerCock = true,
		BreakOpen = true, BreakClose = true, LeverOpen = true, LeverClose = true, CoverOpen = true,
		CoverClose = true, RocketSeat = true, StringCock = true, BoltSeat = true, EnergyCharge = true,
		CasingTink = true, Pickup = true, SlideStart = true, Mantle = true, Vault = true,
		DoubleJump = true, StaminaEmpty = true,
	},
}

local Acoustics = SoundConfig.Acoustics

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
function SoundConfig.Plan(name, cue, distance, enclosed, nearPath)
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

	local plan = { start = first, layers = {}, room = nil, distant = 0 }
	for index, layer in ipairs(layers) do
		local gain = 1
		if (layer.where == "outdoor" and enclosed) or (layer.where == "indoor" and not enclosed) then
			gain = 0
		elseif layer.crack and nearPath == false then
			gain = Acoustics.CRACK_OFF_PATH
		end
		local arrives = layer.crack and first or report
		plan.layers[index] = { delay = layer.delay + (arrives - first), gain = gain }
	end
	if SoundConfig.RoomGated(name, cue) then
		plan.room = enclosed == true
	end
	plan.low, plan.mid, plan.high = SoundConfig.AirAt(name, cue, distance)
	if type(cue.distant) == "table" then
		local _, far = SoundConfig.Rolloff(name, cue)
		local from = cue.distant.from or 0
		plan.distant = math.clamp((distance - from) / math.max(far - from, 1), 0, 1)
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
