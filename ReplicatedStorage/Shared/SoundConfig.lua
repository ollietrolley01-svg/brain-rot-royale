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
			{ id = SNAP, volume = 1, pitch = 1.4 },
			{ id = BOOM2, volume = 0.65, pitch = 2.2 },
			{ id = BASS, volume = 0.35, pitch = 2.4 },
			{ id = METAL, volume = 0.12, pitch = 2.6, delay = 0.02 },
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
			{ id = SNAP, volume = 1, pitch = 1.2 },
			{ id = BOOM2, volume = 0.8, pitch = 1.7 },
			{ id = BASS, volume = 0.5, pitch = 1.5 },
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
			{ id = SNAP, volume = 0.95, pitch = 1.3 },
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
			{ id = SNAP, volume = 0.85, pitch = 1.3 },
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
		volume = 0.42,
		pitch = 1,
		maxDistance = 440,
		category = "Weapons",
		layers = {
			{ id = BOOM3, volume = 1, pitch = 1.65 },
			{ id = SNAP, volume = 0.75, pitch = 0.95 },
			{ id = BASS, volume = 0.65, pitch = 1.3 },
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
			{ id = SNAP, volume = 1, pitch = 1.1 },
			{ id = BOOM2, volume = 0.95, pitch = 1.4 },
			{ id = BASS, volume = 0.7, pitch = 1.0 },
			{ id = BOOM3, volume = 0.3, pitch = 0.9, delay = 0.08 },
		},
		effects = {
			{ "DistortionSoundEffect", { Level = 0.18 } },
			{ "ReverbSoundEffect", { DecayTime = 2.4, WetLevel = -6, DryLevel = 0 } },
		},
	},
	GunshotSuppressed = {
		-- A cough, not a crack: a thin high tick, the action cycling, a hiss of gas; lows cut.
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
	ExplosionRocket = {
		volume = 0.8,
		pitch = 1,
		maxDistance = 900,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.5 },
			{ id = BOOM2, volume = 1, pitch = 1.1 },
			{ id = BOOM3, volume = 1, pitch = 0.72 },
			{ id = BASS, volume = 0.9, pitch = 0.55 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.4, WetLevel = -8, DryLevel = 0 } } },
	},
	-- A 40mm: smaller and sharper, less tail.
	ExplosionGrenade = {
		volume = 0.7,
		pitch = 1,
		maxDistance = 750,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.8, pitch = 0.65 },
			{ id = BOOM2, volume = 1, pitch = 1.3 },
			{ id = BASS, volume = 0.7, pitch = 0.75 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 1.5, WetLevel = -9, DryLevel = 0 } } },
	},
	-- A frag: the body of the rocket's blast with a metallic ring over it for the fragments.
	ExplosionFrag = {
		volume = 0.8,
		pitch = 1,
		maxDistance = 850,
		category = "Weapons",
		layers = {
			{ id = SNAP, volume = 0.9, pitch = 0.55 },
			{ id = BOOM3, volume = 1, pitch = 0.9 },
			{ id = BOOM2, volume = 0.8, pitch = 1.25 },
			{ id = METAL, volume = 0.5, pitch = 0.8, delay = 0.05 },
			{ id = BASS, volume = 0.8, pitch = 0.6 },
		},
		effects = { { "ReverbSoundEffect", { DecayTime = 2.0, WetLevel = -8, DryLevel = 0 } } },
	},
	-- The same blast heard from across the map: a rumble with the top taken off, played flat (not
	-- positional) at a volume set by distance, so a fight far away still reads as thunder.
	ExplosionFar = {
		volume = 0.5,
		pitch = 1,
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
