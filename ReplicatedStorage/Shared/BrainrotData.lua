-- Every collectible brainrot.
--
--   coinValue  what selling one pays in SahurCoins
--   attack     how it fights as a companion (see Attacks below)
--   move       the name shown for that attack
--   power      optional per-brainrot damage tweak on top of the rarity baseline
--   look       how BrainrotModels builds it: body shape, colours, face and extras
--
-- Rarity sets the baseline damage, cooldown and range, so a Legendary always hits harder than
-- an Epic regardless of attack type. Names are kept exactly as they were for the original set
-- — saved collections store brainrots by name.

local BrainrotData = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local FOIL = Enum.Material.Foil
local NEON = Enum.Material.Neon
local GLASS = Enum.Material.Glass

--------------------------------------------------------------------------------
-- Companion attacks
--------------------------------------------------------------------------------

BrainrotData.Attacks = {
	Spit = { label = "Spit", range = 60, cooldown = 1.6, power = 1.0, splash = 0,
		description = "Fires a glob at one enemy" },
	Bonk = { label = "Bonk", range = 36, cooldown = 1.9, power = 1.3, splash = 7,
		description = "Leaps in and slams, splashing anyone close" },
	Zap = { label = "Zap", range = 55, cooldown = 1.35, power = 0.85, splash = 0,
		description = "Instant beam — never misses" },
	Lob = { label = "Lob", range = 70, cooldown = 2.2, power = 1.1, splash = 11,
		description = "Arcing shot that splashes on landing" },
	-- A radial move's range is the radius it hits, and it grows by `radiusStep` a rarity step (14
	-- to 23 studs) rather than by RarityRange. It was 26 + RarityRange, 26 to 50: a Secret hit
	-- everyone in a 50-stud circle, through walls, every 6.8 s, against a Lob's 11-stud splash.
	-- Brought down on 2026-09-18 with the damage unchanged.
	Shockwave = { label = "Shockwave", range = 14, radiusStep = 1.5, cooldown = 2.6, power = 0.95, radial = true,
		description = "Pulse that hits every enemy nearby" },
	Chain = { label = "Chain", range = 55, cooldown = 1.8, power = 0.8, chain = 2,
		description = "Zap that arcs on to a second enemy" },
}

BrainrotData.RarityDamage = { Common = 6, Uncommon = 9, Rare = 13, Epic = 18, Legendary = 25, Mythic = 32, Secret = 40 }
BrainrotData.RarityCooldown = { Common = 1.15, Uncommon = 1.05, Rare = 1.0, Epic = 0.92, Legendary = 0.85, Mythic = 0.8, Secret = 0.75 }
BrainrotData.RarityRange = { Common = 0, Uncommon = 4, Rare = 8, Epic = 12, Legendary = 16, Mythic = 20, Secret = 24 }
-- 0 for Common up to 6 for Secret: the step a radial move's radius grows by.
BrainrotData.RarityIndex = { Common = 0, Uncommon = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5, Secret = 6 }
-- Companions can be shot. A downed companion sits out the rest of the match.
BrainrotData.RarityHealth = { Common = 60, Uncommon = 80, Rare = 105, Epic = 135, Legendary = 175, Mythic = 225, Secret = 290 }

-- The companion's move is used on a hotkey, not automatically, so each use hits harder and
-- recharges for longer than the old auto-attack did.
BrainrotData.AbilityPower = 1.65
BrainrotData.AbilityCooldown = 3.5

--------------------------------------------------------------------------------
-- The collection
--------------------------------------------------------------------------------

BrainrotData.Types = {
	-- Common ------------------------------------------------------------------
	{ name = "Tung Tung Tung Sahur", rarity = "Common", coinValue = 50, attack = "Bonk", move = "Big Bonk",
		look = { body = "Bean", color = rgb(196, 150, 104), accent = rgb(120, 84, 52), eyes = "Round", mouth = "Grin", extras = { "Arms" } } },
	{ name = "Bombardiro Crocodilo", rarity = "Common", coinValue = 65, attack = "Lob", move = "Air Drop",
		look = { body = "Blob", color = rgb(92, 150, 80), accent = rgb(150, 160, 170), eyes = "Angry", mouth = "Fangs", extras = { "Wings" } } },
	{ name = "Trippi Troppi", rarity = "Common", coinValue = 80, attack = "Spit", move = "Bubble Pop",
		look = { body = "Stack", color = rgb(100, 200, 210), accent = rgb(60, 140, 160), eyes = "Round", mouth = "O", extras = { "Ears" } } },
	{ name = "Pizzarino Blobbo", rarity = "Common", coinValue = 55, attack = "Spit", move = "Pepperoni Spit",
		look = { body = "Blob", color = rgb(250, 190, 80), accent = rgb(210, 50, 40), eyes = "Round", mouth = "Grin", extras = { "Cap", "Spots" } } },
	{ name = "Sockolino Stinko", rarity = "Common", coinValue = 60, attack = "Lob", move = "Stink Cloud",
		look = { body = "Bean", color = rgb(190, 214, 150), accent = rgb(120, 170, 60), eyes = "Sleepy", mouth = "O", extras = { "Stink" } } },
	{ name = "Toastini Crunchi", rarity = "Common", coinValue = 58, attack = "Bonk", move = "Crust Slam",
		look = { body = "Cube", color = rgb(222, 176, 110), accent = rgb(150, 100, 50), eyes = "Dots", mouth = "Smile", extras = { "Arms" } } },
	{ name = "Bubblo Gummo", rarity = "Common", coinValue = 62, attack = "Spit", move = "Gum Glob",
		look = { body = "Blob", color = rgb(255, 150, 200), accent = rgb(230, 80, 150), eyes = "Round", mouth = "O", extras = { "Bow", "GumBubble" } } },
	{ name = "Noodlo Wobblo", rarity = "Common", coinValue = 70, attack = "Zap", move = "Noodle Whip",
		look = { body = "Stack", color = rgb(250, 226, 130), accent = rgb(230, 140, 60), eyes = "Round", mouth = "Smile", extras = { "Arms", "Noodles" } } },
	{ name = "Cactino Pokko", rarity = "Common", coinValue = 66, attack = "Spit", move = "Needle Shot",
		look = { body = "Bean", color = rgb(90, 170, 90), accent = rgb(240, 230, 180), eyes = "Angry", mouth = "Smile", extras = { "Spikes", "Flower" } } },
	{ name = "Mudlo Splosh", rarity = "Common", coinValue = 52, attack = "Lob", move = "Mud Splat",
		look = { body = "Blob", color = rgb(130, 96, 70), accent = rgb(90, 64, 44), eyes = "Sleepy", mouth = "Grin", extras = { "Feet", "Drips" } } },

	-- Uncommon ----------------------------------------------------------------
	{ name = "Tralalero Tralala", rarity = "Uncommon", coinValue = 180, attack = "Zap", move = "Wave Beam",
		look = { body = "Disc", color = rgb(90, 150, 230), accent = rgb(230, 240, 255), eyes = "Round", mouth = "Grin", extras = { "Feet" } } },
	{ name = "Chimpanzini Bananini", rarity = "Uncommon", coinValue = 220, attack = "Lob", move = "Peel Toss",
		look = { body = "Pear", color = rgb(250, 220, 80), accent = rgb(130, 90, 60), eyes = "Round", mouth = "Smile", extras = { "Ears", "Arms" } } },
	{ name = "Boneca Ambalabu", rarity = "Uncommon", coinValue = 260, attack = "Bonk", move = "Hop Slam",
		look = { body = "Cube", color = rgb(210, 70, 70), accent = rgb(250, 200, 70), eyes = "Angry", mouth = "Grin", extras = { "Feet" } } },
	{ name = "Cappellino Fizzolo", rarity = "Uncommon", coinValue = 190, attack = "Zap", move = "Fizz Beam",
		look = { body = "Bean", color = rgb(80, 190, 180), accent = rgb(180, 255, 240), eyes = "Visor", mouth = "Smile", extras = { "Cap", "Bubbles" } } },
	{ name = "Lamponi Brillo", rarity = "Uncommon", coinValue = 200, attack = "Lob", move = "Berry Bomb",
		look = { body = "Pear", color = rgb(150, 70, 180), accent = rgb(220, 120, 240), eyes = "Round", mouth = "O", extras = { "Leaf", "Drupelets" } } },
	{ name = "Frullato Vortini", rarity = "Uncommon", coinValue = 240, attack = "Shockwave", move = "Blender Spin",
		look = { body = "Disc", color = rgb(160, 210, 250), accent = rgb(60, 110, 200), eyes = "Cyclops", mouth = "O", extras = { "Propeller" } } },
	{ name = "Gnocco Grumpini", rarity = "Uncommon", coinValue = 210, attack = "Bonk", move = "Grump Stomp",
		look = { body = "Cube", color = rgb(160, 160, 170), accent = rgb(90, 90, 100), eyes = "Angry", mouth = "Fangs", extras = { "Horns" } } },
	{ name = "Pinguino Scivolo", rarity = "Uncommon", coinValue = 230, attack = "Bonk", move = "Belly Slide",
		look = { body = "Stack", color = rgb(40, 44, 56), accent = rgb(255, 170, 40), belly = rgb(250, 250, 250), eyes = "Round", mouth = "Beak", extras = { "Feet", "Scarf" } } },
	{ name = "Zucchero Scintilla", rarity = "Uncommon", coinValue = 250, attack = "Zap", move = "Sugar Spark",
		look = { body = "Blob", color = rgb(250, 246, 240), accent = rgb(120, 220, 255), eyes = "Dots", mouth = "Smile", extras = { "Pixels" } } },

	-- Rare --------------------------------------------------------------------
	{ name = "Lirili Larila", rarity = "Rare", coinValue = 600, attack = "Spit", move = "Thorn Volley",
		look = { body = "Bean", color = rgb(110, 160, 100), accent = rgb(230, 220, 140), eyes = "Sleepy", mouth = "O", extras = { "Spikes" } } },
	{ name = "Ballerina Cappuccina", rarity = "Rare", coinValue = 750, attack = "Shockwave", move = "Spin Pulse",
		look = { body = "Stack", color = rgb(236, 206, 180), accent = rgb(250, 140, 190), eyes = "Dots", mouth = "Smile", extras = { "Bow" } } },
	{ name = "Brr Brr Patapim", rarity = "Rare", coinValue = 900, attack = "Bonk", move = "Stomp Stomp",
		look = { body = "Blob", color = rgb(70, 120, 70), accent = rgb(130, 90, 60), eyes = "Round", mouth = "Smile", extras = { "Mustache", "Leaf", "Feet" } } },
	{ name = "Robottino Bip Bop", rarity = "Rare", coinValue = 700, attack = "Zap", move = "Laser Bip",
		look = { body = "Cube", color = rgb(180, 190, 200), accent = rgb(80, 220, 255), material = Enum.Material.Metal, eyes = "Visor", mouth = "None", extras = { "Antenna", "Arms", "Panel" } } },
	{ name = "Draghetto Tostato", rarity = "Rare", coinValue = 820, attack = "Spit", move = "Toast Flame",
		look = { body = "Pear", color = rgb(210, 70, 50), accent = rgb(255, 170, 60), eyes = "Angry", mouth = "Fangs", extras = { "Horns", "Wings", "Tail" } } },
	{ name = "Polpetta Orbitale", rarity = "Rare", coinValue = 760, attack = "Lob", move = "Meatball Meteor",
		look = { body = "Blob", color = rgb(150, 90, 60), accent = rgb(255, 120, 60), eyes = "Cyclops", mouth = "Grin", extras = { "Orbit", "Drips" } } },
	{ name = "Nuvolino Tuono", rarity = "Rare", coinValue = 880, attack = "Chain", move = "Storm Zap",
		look = { body = "Cloud", color = rgb(210, 214, 226), accent = rgb(255, 230, 80), eyes = "Sleepy", mouth = "O", extras = { "Bolt" } } },
	{ name = "Fungo Saltarello", rarity = "Rare", coinValue = 690, attack = "Bonk", move = "Spore Stomp",
		look = { body = "Mushroom", color = rgb(240, 230, 214), accent = rgb(220, 50, 50), spotColor = rgb(255, 255, 255), eyes = "Round", mouth = "Smile", extras = { "Spots", "Feet", "Blush" } } },

	-- Epic --------------------------------------------------------------------
	{ name = "Frigo Camelo", rarity = "Epic", coinValue = 2400, attack = "Zap", move = "Frost Ray",
		look = { body = "Cube", color = rgb(226, 240, 250), accent = rgb(120, 200, 255), eyes = "Visor", mouth = "None", extras = { "Arms", "Humps", "Handle" } } },
	{ name = "Bombombini Gusini", rarity = "Epic", coinValue = 3000, attack = "Lob", move = "Honk Bomb",
		look = { body = "Pear", color = rgb(170, 176, 186), accent = rgb(255, 150, 40), eyes = "Angry", mouth = "Beak", extras = { "Wings", "Tail" } } },
	{ name = "Vulcanino Brontolo", rarity = "Epic", coinValue = 2600, attack = "Shockwave", move = "Magma Pulse",
		look = { body = "Pear", color = rgb(110, 40, 36), accent = rgb(255, 120, 30), eyes = "Angry", mouth = "Grin", extras = { "Flame", "Cracks" } } },
	{ name = "Specchio Riflesso", rarity = "Epic", coinValue = 2800, attack = "Chain", move = "Mirror Arc",
		look = { body = "Cube", color = rgb(210, 220, 235), accent = rgb(180, 120, 255), material = FOIL, reflectance = 0.45, eyes = "Visor", mouth = "None", extras = { "Orbit" } } },
	{ name = "Gufo Mezzanotte", rarity = "Epic", coinValue = 2700, attack = "Zap", move = "Night Beam",
		look = { body = "Blob", color = rgb(40, 50, 100), accent = rgb(255, 214, 90), belly = rgb(118, 128, 176), eyes = "Big", mouth = "Beak", extras = { "Ears", "Wings" } } },
	{ name = "Serpentino Zigzag", rarity = "Epic", coinValue = 2500, attack = "Spit", move = "Venom Dart",
		look = { body = "Bean", color = rgb(150, 220, 70), accent = rgb(80, 40, 120), eyes = "Angry", mouth = "Fangs", extras = { "Tail", "Zigzag" } } },
	{ name = "Astronauta Pisolino", rarity = "Epic", coinValue = 3200, attack = "Lob", move = "Moon Rock",
		look = { body = "Stack", color = rgb(240, 242, 246), accent = rgb(80, 160, 255), eyes = "Visor", mouth = "None", extras = { "Helmet", "Antenna", "Backpack" } } },

	-- Legendary ---------------------------------------------------------------
	{ name = "La Vacca Saturno Saturnita", rarity = "Legendary", coinValue = 12000, attack = "Shockwave", move = "Ring Quake",
		look = { body = "Blob", color = rgb(246, 246, 240), accent = rgb(60, 60, 70), eyes = "Round", mouth = "Grin", extras = { "Horns", "Orbit", "Spots" } } },
	{ name = "Golden Sahur", rarity = "Legendary", coinValue = 18000, attack = "Bonk", move = "Golden Bonk",
		look = { body = "Bean", color = rgb(255, 196, 60), accent = rgb(255, 240, 160), material = FOIL, eyes = "Round", mouth = "Grin", extras = { "Crown", "Arms" } } },
	{ name = "Re Formaggione", rarity = "Legendary", coinValue = 15000, attack = "Shockwave", move = "Royal Stink Wave",
		look = { body = "Cube", color = rgb(255, 214, 90), accent = rgb(200, 150, 40), spotColor = rgb(220, 170, 50), eyes = "Round", mouth = "Grin", extras = { "Crown", "Mustache", "Spots" } } },
	{ name = "Galassia Sognante", rarity = "Legendary", coinValue = 16000, attack = "Chain", move = "Cosmic Chain",
		look = { body = "Disc", color = rgb(120, 60, 200), accent = rgb(120, 240, 255), material = NEON, eyes = "Cyclops", mouth = "O", extras = { "Orbit", "Halo" } } },
	{ name = "Drago Arcobaleno", rarity = "Legendary", coinValue = 20000, attack = "Spit", move = "Prism Breath", power = 1.08,
		look = { body = "Pear", color = rgb(230, 70, 160), accent = rgb(80, 230, 230), eyes = "Angry", mouth = "Fangs", extras = { "Horns", "Wings", "Tail", "Flame" } } },
	{ name = "Fantasmino Eterno", rarity = "Legendary", coinValue = 14000, attack = "Zap", move = "Ghost Ray",
		look = { body = "Ghost", color = rgb(230, 236, 255), accent = rgb(160, 220, 255), material = GLASS, eyes = "Sleepy", mouth = "O", extras = { "Halo", "Wings" } } },

	-- Second wave -------------------------------------------------------------
	{ name = "Spaghettino Twirlo", rarity = "Common", coinValue = 64, attack = "Zap", move = "Noodle Lash",
		look = { body = "Blob", color = rgb(245, 214, 120), accent = rgb(210, 60, 50), eyes = "Round", mouth = "Grin", extras = { "Fork" } } },
	{ name = "Gommino Rimbalzo", rarity = "Common", coinValue = 58, attack = "Bonk", move = "Bouncy Bop",
		look = { body = "Stack", color = rgb(120, 220, 140), accent = rgb(60, 160, 90), eyes = "Dots", mouth = "O", extras = { "Feet" } } },
	{ name = "Lanternino Lucciola", rarity = "Uncommon", coinValue = 235, attack = "Zap", move = "Glow Flicker",
		look = { body = "Pear", color = rgb(255, 226, 120), accent = rgb(255, 170, 40), eyes = "Sleepy", mouth = "Smile", extras = { "Wings", "Lamp" } } },
	{ name = "Cuscino Pisolone", rarity = "Uncommon", coinValue = 205, attack = "Shockwave", move = "Nap Wave",
		look = { body = "Cube", color = rgb(190, 170, 240), accent = rgb(250, 250, 255), eyes = "Sleepy", mouth = "O", extras = { "Nightcap" } } },
	{ name = "Tartarughino Turbo", rarity = "Rare", coinValue = 840, attack = "Bonk", move = "Shell Rush",
		look = { body = "Disc", color = rgb(90, 170, 90), accent = rgb(200, 160, 80), eyes = "Angry", mouth = "Grin", extras = { "Feet", "Shell", "Exhaust" } } },
	{ name = "Sirenetta Bollicina", rarity = "Rare", coinValue = 780, attack = "Spit", move = "Bubble Barrage",
		look = { body = "Bean", color = rgb(120, 200, 230), accent = rgb(240, 120, 200), eyes = "Round", mouth = "Smile", extras = { "TailFin", "Fins", "Bow", "Bubbles" } } },
	{ name = "Magnetino Attrazione", rarity = "Rare", coinValue = 910, attack = "Chain", move = "Magnet Arc",
		look = { body = "Cube", color = rgb(210, 60, 60), accent = rgb(160, 170, 190), material = Enum.Material.Metal, eyes = "Visor", mouth = "None", extras = { "Horns" } } },
	{ name = "Cavaliere Croissant", rarity = "Epic", coinValue = 2900, attack = "Bonk", move = "Buttery Charge",
		look = { body = "Pear", color = rgb(226, 170, 90), accent = rgb(180, 180, 196), eyes = "Angry", mouth = "Grin", extras = { "Plume", "Arms" } } },
	{ name = "Stregonella Zucca", rarity = "Epic", coinValue = 3100, attack = "Lob", move = "Pumpkin Hex",
		look = { body = "Blob", color = rgb(240, 130, 40), accent = rgb(110, 60, 150), eyes = "Angry", mouth = "Fangs", extras = { "WizardHat" } } },
	{ name = "Nebbiolina Specchio", rarity = "Epic", coinValue = 3300, attack = "Zap", move = "Mist Beam",
		look = { body = "Disc", color = rgb(200, 210, 230), accent = rgb(140, 220, 255), material = GLASS, reflectance = 0.35, eyes = "Cyclops", mouth = "O", extras = { "Orbit" } } },
	{ name = "Imperatore Gelato", rarity = "Legendary", coinValue = 17000, attack = "Shockwave", move = "Brain Freeze",
		look = { body = "Stack", color = rgb(250, 220, 230), accent = rgb(120, 210, 250), eyes = "Round", mouth = "Grin", extras = { "Crown", "Scarf", "Sprinkles" } } },
	{ name = "Titano Tostapane", rarity = "Legendary", coinValue = 19000, attack = "Lob", move = "Burnt Toast Barrage",
		look = { body = "Cube", color = rgb(196, 200, 210), accent = rgb(255, 140, 40), material = Enum.Material.Metal, eyes = "Visor", mouth = "Grin", extras = { "Arms", "ToastSlots" } } },

	-- Mythic ------------------------------------------------------------------
	-- Only from the Legendary and Mythic crates. A little bigger than everything below them.
	{ name = "Fenice Pixelata", rarity = "Mythic", coinValue = 65000, attack = "Spit", move = "Pixel Inferno",
		look = { body = "Pear", size = 1.1, color = rgb(255, 90, 60), accent = rgb(255, 220, 80), eyes = "Angry", mouth = "Fangs", extras = { "Wings", "Tail", "Flame", "Pixels" } } },
	{ name = "Kraken Caramello", rarity = "Mythic", coinValue = 72000, attack = "Chain", move = "Caramel Tentacles",
		look = { body = "Blob", size = 1.1, color = rgb(200, 120, 60), accent = rgb(255, 200, 120), eyes = "Cyclops", mouth = "Grin", extras = { "Tentacles", "Drips", "Orbit" } } },
	{ name = "Oracolo Lavatrice", rarity = "Mythic", coinValue = 80000, attack = "Shockwave", move = "Spin Cycle Prophecy",
		look = { body = "Cube", size = 1.1, color = rgb(236, 240, 246), accent = rgb(80, 200, 255), eyes = "Cyclops", mouth = "O", extras = { "Porthole", "Halo", "Antenna" } } },
	{ name = "Drago Gelatina", rarity = "Mythic", coinValue = 68000, attack = "Lob", move = "Wobble Bomb",
		look = { body = "Bean", size = 1.1, color = rgb(120, 255, 160), accent = rgb(255, 90, 200), material = GLASS, eyes = "Round", mouth = "Fangs", extras = { "Horns", "Wings", "Tail" } } },
	{ name = "Samurai Sushi", rarity = "Mythic", coinValue = 76000, attack = "Bonk", move = "Wasabi Slash",
		look = { body = "Stack", size = 1.1, color = rgb(250, 250, 245), accent = rgb(240, 110, 90), eyes = "Angry", mouth = "Smile", extras = { "Nori", "Topknot", "Arms", "Mustache" } } },

	-- Secret ------------------------------------------------------------------
	-- The rarest things in the game: a fraction of a percent from the top crates.
	{ name = "Il Glitch Primordiale", rarity = "Secret", coinValue = 300000, attack = "Chain", move = "Reality Tear",
		look = { body = "Cube", size = 1.2, color = rgb(24, 24, 34), accent = rgb(0, 255, 200), eyes = "Visor", mouth = "None", extras = { "Pixels", "Halo", "Spikes" } } },
	{ name = "Cosmo Nonno Stellare", rarity = "Secret", coinValue = 420000, attack = "Shockwave", move = "Big Bang Nap",
		look = { body = "Pear", size = 1.2, color = rgb(40, 30, 90), accent = rgb(255, 240, 150), eyes = "Sleepy", mouth = "Grin", extras = { "Mustache", "Beard", "Nightcap", "Orbit" } } },
	{ name = "Arcobalenissimo", rarity = "Secret", coinValue = 500000, attack = "Zap", move = "Infinite Prism",
		look = { body = "Disc", size = 1.2, color = rgb(255, 120, 220), accent = rgb(120, 255, 250), material = FOIL, eyes = "Cyclops", mouth = "O", extras = { "Rainbow", "Halo", "Wings" } } },

	-- Third wave: the roster doubled ---------------------------------------------
	-- Common
	{ name = "Pomodorino Schizzo", rarity = "Common", coinValue = 60, attack = "Spit", move = "Sauce Squirt",
		look = { body = "Blob", color = rgb(230, 60, 50), accent = rgb(80, 160, 60), eyes = "Round", mouth = "Tongue", extras = { "Leaf", "Blush" } } },
	{ name = "Biscottino Crumbo", rarity = "Common", coinValue = 56, attack = "Bonk", move = "Crumb Crash",
		look = { body = "Loaf", color = rgb(214, 160, 90), accent = rgb(120, 70, 30), spotColor = rgb(84, 50, 30), eyes = "Dots", mouth = "Smile", extras = { "Spots" } } },
	{ name = "Lumachina Lenta", rarity = "Common", coinValue = 54, attack = "Lob", move = "Slime Arc",
		look = { body = "Blob", color = rgb(190, 210, 120), accent = rgb(170, 110, 70), eyes = "Sleepy", mouth = "Smile", extras = { "Shell", "Antenna" } } },
	{ name = "Ombrellino Pioggia", rarity = "Common", coinValue = 68, attack = "Zap", move = "Drizzle Beam",
		look = { body = "Mushroom", color = rgb(240, 240, 250), accent = rgb(80, 140, 230), eyes = "Round", mouth = "O", extras = { "Blush", "Umbrella" } } },
	{ name = "Patatina Fritta", rarity = "Common", coinValue = 62, attack = "Spit", move = "Salt Shot",
		look = { body = "Can", color = rgb(250, 210, 90), accent = rgb(220, 50, 50), eyes = "Big", mouth = "Grin", extras = { "Stripes", "Fries" } } },
	{ name = "Mattoncino Blocco", rarity = "Common", coinValue = 58, attack = "Bonk", move = "Brick Drop",
		look = { body = "Cube", color = rgb(190, 80, 60), accent = rgb(230, 220, 210), eyes = "Angry", mouth = "Frown", extras = { "Stripes" } } },
	{ name = "Nuvoletta Pioviggina", rarity = "Common", coinValue = 64, attack = "Lob", move = "Rain Lob",
		look = { body = "Cloud", color = rgb(220, 228, 240), accent = rgb(100, 160, 240), eyes = "Sleepy", mouth = "O", extras = { "Blush", "Raindrops" } } },
	{ name = "Pulcinello Piumino", rarity = "Common", coinValue = 66, attack = "Spit", move = "Feather Flick",
		look = { body = "Egg", color = rgb(255, 230, 90), accent = rgb(255, 150, 40), eyes = "Round", mouth = "Beak", extras = { "Feet", "Wings", "Eggshell" } } },
	{ name = "Gelatino Tremolo", rarity = "Common", coinValue = 72, attack = "Shockwave", move = "Wobble Wave",
		look = { body = "Ghost", color = rgb(120, 230, 160), accent = rgb(60, 180, 110), material = GLASS, eyes = "Big", mouth = "Wavy", extras = { "Bubbles" } } },
	{ name = "Salsiccia Saltella", rarity = "Common", coinValue = 57, attack = "Bonk", move = "Sizzle Hop",
		look = { body = "Bean", color = rgb(190, 90, 70), accent = rgb(120, 50, 40), eyes = "Round", mouth = "Grin", extras = { "Feet", "Stripes" } } },
	{ name = "Cipollina Lacrima", rarity = "Common", coinValue = 61, attack = "Zap", move = "Tear Beam",
		look = { body = "Egg", color = rgb(230, 220, 240), accent = rgb(150, 90, 170), eyes = "Worried", mouth = "Frown", extras = { "Leaf", "Tears" } } },
	{ name = "Formichina Operaia", rarity = "Common", coinValue = 75, attack = "Chain", move = "Ant Relay",
		look = { body = "Totem", color = rgb(70, 46, 44), accent = rgb(200, 80, 60), eyes = "Dots", mouth = "Smile", extras = { "Antenna", "Arms", "InsectLegs" } } },
	{ name = "Bottoncino Cucito", rarity = "Common", coinValue = 59, attack = "Zap", move = "Thread Zap",
		look = { body = "Disc", color = rgb(230, 120, 160), accent = rgb(250, 230, 240), eyes = "Dots", mouth = "Smile", extras = { "Buttonholes" } } },
	{ name = "Radicchio Rotolo", rarity = "Common", coinValue = 63, attack = "Lob", move = "Leaf Toss",
		look = { body = "Blob", color = rgb(150, 40, 80), accent = rgb(240, 230, 240), eyes = "Angry", mouth = "Teeth", extras = { "Leaf", "Stripes" } } },

	-- Uncommon
	{ name = "Pesciolino Bolla", rarity = "Uncommon", coinValue = 215, attack = "Spit", move = "Bubble Blast",
		look = { body = "Egg", color = rgb(255, 140, 60), accent = rgb(255, 250, 245), eyes = "Big", mouth = "O", extras = { "Fins", "Stripes", "Bubbles", "TailFin" } } },
	{ name = "Cavolfiore Cervello", rarity = "Uncommon", coinValue = 245, attack = "Zap", move = "Brain Wave",
		look = { body = "Cloud", color = rgb(240, 236, 220), accent = rgb(120, 180, 90), eyes = "Round", mouth = "Smile", extras = { "Leaf", "Folds" } } },
	{ name = "Ghiacciolo Sorbetto", rarity = "Uncommon", coinValue = 225, attack = "Shockwave", move = "Chill Burst",
		look = { body = "Can", color = rgb(140, 200, 255), accent = rgb(255, 140, 200), eyes = "Sleepy", mouth = "Tongue", extras = { "Stripes", "Drips" } } },
	{ name = "Ragnetto Tessitore", rarity = "Uncommon", coinValue = 270, attack = "Chain", move = "Web Link",
		look = { body = "Blob", color = rgb(60, 50, 70), accent = rgb(200, 60, 200), eyes = "Triple", mouth = "Fangs", extras = { "SpiderLegs" } } },
	{ name = "Tamburino Bum Bum", rarity = "Uncommon", coinValue = 255, attack = "Shockwave", move = "Drum Roll",
		look = { body = "Can", color = rgb(220, 60, 60), accent = rgb(250, 220, 120), eyes = "Angry", mouth = "Grin", extras = { "Arms", "Drum" } } },
	{ name = "Pantofolina Morbida", rarity = "Uncommon", coinValue = 195, attack = "Bonk", move = "Slipper Smack",
		look = { body = "Loaf", color = rgb(250, 190, 210), accent = rgb(255, 255, 255), eyes = "Sleepy", mouth = "Smile", extras = { "Ears", "Blush" } } },
	{ name = "Cactusello Danzante", rarity = "Uncommon", coinValue = 230, attack = "Spit", move = "Prickle Pop",
		look = { body = "Totem", color = rgb(100, 170, 90), accent = rgb(255, 120, 170), eyes = "Round", mouth = "Grin", extras = { "Spikes", "Arms", "Flower" } } },
	{ name = "Zucchina Lanterna", rarity = "Uncommon", coinValue = 240, attack = "Lob", move = "Gourd Glow",
		look = { body = "Egg", color = rgb(240, 140, 40), accent = rgb(255, 230, 120), faceGlow = rgb(255, 196, 60), eyes = "Angry", mouth = "Wavy", extras = { "Leaf", "Gem" } } },
	{ name = "Koalino Pennichella", rarity = "Uncommon", coinValue = 210, attack = "Bonk", move = "Sleepy Slam",
		look = { body = "Blob", color = rgb(160, 160, 170), accent = rgb(60, 60, 70), eyes = "Sleepy", mouth = "Smile", extras = { "Ears", "Nose" } } },
	{ name = "Fornellino Fiammella", rarity = "Uncommon", coinValue = 265, attack = "Zap", move = "Pilot Light",
		look = { body = "Cube", color = rgb(200, 200, 210), accent = rgb(255, 120, 40), material = Enum.Material.Metal, eyes = "Visor", mouth = "None", extras = { "Flame", "Knobs" } } },
	{ name = "Biscione Arrotolato", rarity = "Uncommon", coinValue = 220, attack = "Spit", move = "Coil Spit",
		look = { body = "Bean", color = rgb(90, 200, 120), accent = rgb(250, 220, 80), eyes = "Angry", mouth = "Tongue", extras = { "Tail", "Stripes" } } },
	{ name = "Nocciolino Ninja", rarity = "Uncommon", coinValue = 275, attack = "Bonk", move = "Shadow Tap",
		look = { body = "Egg", color = rgb(140, 90, 60), accent = rgb(30, 30, 34), eyes = "Angry", mouth = "None", extras = { "Cape", "NinjaBand" } } },
	{ name = "Pinna Surfista", rarity = "Uncommon", coinValue = 250, attack = "Lob", move = "Wave Toss",
		look = { body = "Disc", color = rgb(80, 180, 220), accent = rgb(250, 240, 200), eyes = "Round", mouth = "Grin", extras = { "Fins", "Shades", "Surfboard" } } },

	-- Rare
	{ name = "Gufetto Professore", rarity = "Rare", coinValue = 820, attack = "Zap", move = "Lecture Beam",
		look = { body = "Egg", color = rgb(150, 110, 70), accent = rgb(240, 220, 160), eyes = "Big", mouth = "Beak", extras = { "Monocle", "Mortarboard" } } },
	{ name = "Polipo Pittore", rarity = "Rare", coinValue = 790, attack = "Lob", move = "Ink Splash",
		look = { body = "Blob", color = rgb(200, 90, 150), accent = rgb(110, 50, 140), eyes = "Round", mouth = "O", extras = { "Tentacles", "Beret" } } },
	{ name = "Cervo Neon", rarity = "Rare", coinValue = 880, attack = "Chain", move = "Antler Arc",
		look = { body = "Bean", color = rgb(170, 120, 80), accent = rgb(120, 255, 220), eyes = "Round", mouth = "Smile", extras = { "Antlers", "Gem" } } },
	{ name = "Pipistrello Bollente", rarity = "Rare", coinValue = 760, attack = "Spit", move = "Screech Spit",
		look = { body = "Blob", color = rgb(70, 60, 80), accent = rgb(255, 90, 60), eyes = "Angry", mouth = "Fangs", extras = { "BatWings", "Ears" } } },
	{ name = "Scatolone Robusto", rarity = "Rare", coinValue = 700, attack = "Bonk", move = "Box Crush",
		look = { body = "Cube", color = rgb(190, 150, 100), accent = rgb(120, 90, 60), eyes = "Dots", mouth = "Frown", extras = { "Arms", "Feet", "Tie", "Flaps" } } },
	{ name = "Cucciolo Cometa", rarity = "Rare", coinValue = 930, attack = "Zap", move = "Comet Tail",
		look = { body = "Ghost", color = rgb(220, 240, 255), accent = rgb(120, 200, 255), material = GLASS, eyes = "Big", mouth = "Smile", extras = { "Tail", "Orbit" } } },
	{ name = "Riccio Rotante", rarity = "Rare", coinValue = 740, attack = "Shockwave", move = "Quill Spin",
		look = { body = "Blob", color = rgb(140, 100, 70), accent = rgb(60, 40, 30), eyes = "Round", mouth = "Smile", extras = { "Quills", "Feet", "Blush" } } },
	{ name = "Barattolo Miele", rarity = "Rare", coinValue = 810, attack = "Lob", move = "Honey Drop",
		look = { body = "Can", color = rgb(250, 190, 40), accent = rgb(180, 110, 30), eyes = "Sleepy", mouth = "Tongue", extras = { "Wings", "Drips" } } },
	{ name = "Tricheco Baffone", rarity = "Rare", coinValue = 860, attack = "Bonk", move = "Tusk Thump",
		look = { body = "Loaf", color = rgb(140, 110, 100), accent = rgb(250, 250, 240), eyes = "Sleepy", mouth = "Tusks", extras = { "Whiskers" } } },
	{ name = "Faro Guardiano", rarity = "Rare", coinValue = 900, attack = "Zap", move = "Lighthouse Sweep",
		look = { body = "Totem", color = rgb(240, 240, 240), accent = rgb(230, 60, 60), eyes = "Visor", mouth = "None", extras = { "Stripes", "Lamp" } } },
	{ name = "Ape Operosa", rarity = "Rare", coinValue = 770, attack = "Chain", move = "Buzz Link",
		look = { body = "Egg", color = rgb(250, 210, 50), accent = rgb(30, 30, 34), eyes = "Big", mouth = "Smile", extras = { "Stripes", "Wings", "Antenna", "Stinger" } } },
	{ name = "Granchio Tenaglia", rarity = "Rare", coinValue = 840, attack = "Bonk", move = "Pincer Pinch",
		look = { body = "Disc", color = rgb(230, 80, 60), accent = rgb(250, 200, 180), eyes = "Worried", mouth = "Teeth", extras = { "Arms", "Claws", "Antenna" } } },

	-- Epic
	{ name = "Mago Merendina", rarity = "Epic", coinValue = 3050, attack = "Lob", move = "Snack Spell",
		look = { body = "Cone", color = rgb(90, 70, 190), accent = rgb(255, 220, 90), eyes = "Round", mouth = "Smile", extras = { "Beard", "WizardHat" } } },
	{ name = "Cavaliere Lattina", rarity = "Epic", coinValue = 2850, attack = "Bonk", move = "Tin Charge",
		look = { body = "Can", color = rgb(200, 205, 215), accent = rgb(230, 60, 60), material = Enum.Material.Metal, eyes = "Visor", mouth = "None", extras = { "Cape", "Arms", "Plume" } } },
	{ name = "Medusa Lucente", rarity = "Epic", coinValue = 3150, attack = "Chain", move = "Sting Chain",
		look = { body = "Mushroom", color = rgb(220, 190, 255), accent = rgb(255, 120, 220), material = GLASS, eyes = "Sleepy", mouth = "O", extras = { "Tentacles" } } },
	{ name = "Unicorno Frizzante", rarity = "Epic", coinValue = 3400, attack = "Zap", move = "Sparkle Horn",
		look = { body = "Bean", color = rgb(250, 240, 250), accent = rgb(255, 120, 220), eyes = "Hearts", mouth = "Smile", extras = { "Unicorn", "Mane", "Blush" } } },
	{ name = "Tuba Tuonante", rarity = "Epic", coinValue = 2700, attack = "Shockwave", move = "Brass Boom",
		look = { body = "Cone", color = rgb(240, 190, 60), accent = rgb(180, 120, 40), material = FOIL, eyes = "Angry", mouth = "O", extras = { "Headphones" } } },
	{ name = "Scheletrino Ballerino", rarity = "Epic", coinValue = 2950, attack = "Bonk", move = "Bone Bop",
		look = { body = "Totem", color = rgb(240, 236, 220), accent = rgb(40, 40, 50), eyes = "Big", mouth = "Teeth", extras = { "Bow", "Arms", "Ribs" } } },
	{ name = "Astronave Formaggio", rarity = "Epic", coinValue = 3350, attack = "Lob", move = "Cheese Meteor",
		look = { body = "Disc", color = rgb(255, 210, 80), accent = rgb(140, 220, 255), spotColor = rgb(220, 160, 40), eyes = "Cyclops", mouth = "None", extras = { "Helmet", "Antenna", "Spots" } } },
	{ name = "Drago Pantofola", rarity = "Epic", coinValue = 3200, attack = "Spit", move = "Cozy Flame",
		look = { body = "Loaf", color = rgb(120, 200, 140), accent = rgb(255, 160, 190), eyes = "Sleepy", mouth = "Fangs", extras = { "Horns", "Tail", "Flame" } } },
	{ name = "Lupo Lunare", rarity = "Epic", coinValue = 3100, attack = "Zap", move = "Moon Howl",
		look = { body = "Egg", color = rgb(110, 120, 150), accent = rgb(255, 250, 200), eyes = "Angry", mouth = "Fangs", extras = { "Ears", "Nose", "Gem" } } },
	{ name = "Ciclope Cioccolato", rarity = "Epic", coinValue = 2800, attack = "Shockwave", move = "Cocoa Quake",
		look = { body = "Blob", color = rgb(110, 70, 40), accent = rgb(250, 230, 200), eyes = "Cyclops", mouth = "Tusks", extras = { "Horns", "Drips" } } },
	{ name = "Nuvola Temporale", rarity = "Epic", coinValue = 3250, attack = "Chain", move = "Thunder Fork",
		look = { body = "Cloud", color = rgb(90, 100, 130), accent = rgb(255, 240, 80), eyes = "Angry", mouth = "Wavy", extras = { "Bolt", "Raindrops" } } },

	-- Legendary
	{ name = "Imperatrice Farfalla", rarity = "Legendary", coinValue = 18500, attack = "Chain", move = "Wing Storm",
		look = { body = "Egg", color = rgb(250, 160, 220), accent = rgb(120, 230, 255), eyes = "Big", mouth = "Smile", extras = { "ButterflyWings", "Crown", "Antenna", "Blush" } } },
	{ name = "Faraone Fagiolino", rarity = "Legendary", coinValue = 16500, attack = "Shockwave", move = "Sand Pulse",
		look = { body = "Totem", color = rgb(230, 200, 120), accent = rgb(60, 100, 200), material = FOIL, eyes = "Round", mouth = "Grin", extras = { "Nemes", "Stripes" } } },
	{ name = "Balena Cantante", rarity = "Legendary", coinValue = 15500, attack = "Lob", move = "Whale Song",
		look = { body = "Loaf", color = rgb(60, 110, 190), accent = rgb(230, 240, 255), eyes = "Sleepy", mouth = "Smile", extras = { "Fins", "Headphones", "Spout" } } },
	{ name = "Titano Tuttifrutti", rarity = "Legendary", coinValue = 17500, attack = "Bonk", move = "Fruit Punch",
		look = { body = "Cube", color = rgb(255, 120, 90), accent = rgb(120, 220, 90), eyes = "Angry", mouth = "Grin", extras = { "Arms", "Cherry", "Spots" } } },
	{ name = "Stregone Stellato", rarity = "Legendary", coinValue = 19500, attack = "Zap", move = "Starfall Ray",
		look = { body = "Cone", color = rgb(40, 40, 110), accent = rgb(255, 230, 120), eyes = "Stars", mouth = "None", extras = { "Beard", "Orbit", "WizardHat" } } },
	{ name = "Leone Lampadina", rarity = "Legendary", coinValue = 16000, attack = "Spit", move = "Bright Roar",
		look = { body = "Blob", color = rgb(255, 230, 120), accent = rgb(255, 160, 40), eyes = "Round", mouth = "Fangs", extras = { "Petals", "Bolt" } } },
	{ name = "Castello Ambulante", rarity = "Legendary", coinValue = 20500, attack = "Shockwave", move = "Rampart Quake",
		look = { body = "Can", color = rgb(170, 170, 180), accent = rgb(120, 70, 50), material = Enum.Material.Slate, eyes = "Triple", mouth = "Teeth", extras = { "Battlements", "Feet" } } },
	{ name = "Capitano Calamaro", rarity = "Legendary", coinValue = 18000, attack = "Chain", move = "Ink Broadside",
		look = { body = "Mushroom", color = rgb(230, 110, 90), accent = rgb(40, 40, 50), eyes = "Wink", mouth = "Grin", extras = { "TopHat", "Tentacles" } } },

	-- Mythic
	{ name = "Grifone Glassato", rarity = "Mythic", coinValue = 70000, attack = "Spit", move = "Frosted Dive",
		look = { body = "Egg", size = 1.1, color = rgb(250, 220, 160), accent = rgb(120, 200, 255), eyes = "Angry", mouth = "Beak", extras = { "Wings", "Tail", "Drips" } } },
	{ name = "Golem Gorgonzola", rarity = "Mythic", coinValue = 74000, attack = "Bonk", move = "Moldy Colossus",
		look = { body = "Cube", size = 1.15, color = rgb(240, 230, 190), accent = rgb(90, 150, 200), material = Enum.Material.Slate, eyes = "Triple", mouth = "Tusks", extras = { "Spots", "Arms", "Feet" } } },
	{ name = "Sfinge Sussurrante", rarity = "Mythic", coinValue = 82000, attack = "Zap", move = "Riddle Beam",
		look = { body = "Totem", size = 1.1, color = rgb(220, 180, 110), accent = rgb(60, 200, 200), material = FOIL, eyes = "Stars", mouth = "None", extras = { "Nemes", "Gem", "Halo" } } },
	{ name = "Leviatano Limonata", rarity = "Mythic", coinValue = 78000, attack = "Chain", move = "Fizz Tsunami",
		look = { body = "Ghost", size = 1.1, color = rgb(250, 240, 120), accent = rgb(120, 240, 140), material = GLASS, eyes = "Big", mouth = "Wavy", extras = { "Fins", "Tentacles", "Orbit" } } },
	{ name = "Mecha Mortadella", rarity = "Mythic", coinValue = 69000, attack = "Shockwave", move = "Deli Overdrive",
		look = { body = "Can", size = 1.1, color = rgb(240, 150, 160), accent = rgb(80, 220, 255), material = Enum.Material.Metal, eyes = "Goggles", mouth = "Teeth", extras = { "Arms", "Panel", "Bolt" } } },

	-- Secret
	{ name = "L'Ultimo Pixel", rarity = "Secret", coinValue = 450000, attack = "Chain", move = "Final Render",
		look = { body = "Cube", size = 1.2, color = rgb(30, 28, 44), accent = rgb(255, 60, 220), eyes = "Visor", mouth = "None", extras = { "Gem", "Pixels", "Halo", "Bolt" } } },
	{ name = "Nonna Nebulosa", rarity = "Secret", coinValue = 380000, attack = "Shockwave", move = "Grandma Gravity",
		look = { body = "Cloud", size = 1.2, color = rgb(170, 120, 230), accent = rgb(255, 220, 250), eyes = "Goggles", mouth = "Smile", extras = { "Bun", "Orbit", "Blush" } } },
	{ name = "Il Buco Nero Bello", rarity = "Secret", coinValue = 600000, attack = "Zap", move = "Event Horizon Hug",
		look = { body = "Disc", size = 1.25, color = rgb(14, 10, 26), accent = rgb(255, 150, 60), eyes = "Cyclops", mouth = "O", extras = { "Accretion", "Halo", "Petals" } } },
}

-- One-time bonus for owning every brainrot of a rarity at once. The sets doubled in size in the
-- third wave, and the bonuses doubled with them.
BrainrotData.CollectionBonus = {
	Common = 2000, Uncommon = 6000, Rare = 20000, Epic = 60000, Legendary = 200000, Mythic = 1000000, Secret = 4000000,
}

local byName = {}
local byRarity = {}

for _, def in ipairs(BrainrotData.Types) do
	byName[def.name] = def
	byRarity[def.rarity] = byRarity[def.rarity] or {}
	table.insert(byRarity[def.rarity], def)
end

function BrainrotData.Get(name)
	return byName[name]
end

function BrainrotData.OfRarity(rarity)
	return byRarity[rarity] or {}
end

function BrainrotData.RandomOfRarity(rarity)
	local pool = byRarity[rarity]
	if not pool or #pool == 0 then
		return BrainrotData.Types[1]
	end
	return pool[math.random(1, #pool)]
end

-- Companion levels. A brainrot earns 1 XP per point of damage it deals for you (CompanionService),
-- and every level adds a little damage and health, so the one you keep fighting with pulls ahead
-- of a fresh copy.
BrainrotData.MaxLevel = 10
BrainrotData.XpPerLevel = 400
BrainrotData.BonusPerLevel = 0.03

function BrainrotData.LevelForXp(xp)
	return math.min(BrainrotData.MaxLevel, math.floor((xp or 0) / BrainrotData.XpPerLevel) + 1)
end

function BrainrotData.XpIntoLevel(xp)
	return (xp or 0) % BrainrotData.XpPerLevel
end

function BrainrotData.LevelBonus(level)
	return 1 + BrainrotData.BonusPerLevel * (math.clamp(level or 1, 1, BrainrotData.MaxLevel) - 1)
end

-- Merging. Spare copies of a brainrot fuse into it and give it a star; every star adds
-- `BonusPerStar` damage and health on top of its level bonus. `MergeCopies[n]` is how many spare
-- copies (beyond the one you keep) it takes to reach star n, so a full five stars eats nine.
-- Stars belong to your profile per brainrot, the same way companion XP does: selling or trading
-- a copy never takes them away, and a new copy of that brainrot arrives at your star rank. That
-- also means stars can't be moved to another account through a trade.
BrainrotData.MaxStars = 5
-- Was 0.15 (+75% at five stars) when merging first went in; toned down to +50% on request.
BrainrotData.BonusPerStar = 0.10
BrainrotData.MergeCopies = { 1, 1, 2, 2, 3 }

function BrainrotData.ClampStars(stars)
	return math.clamp(math.floor(tonumber(stars) or 0), 0, BrainrotData.MaxStars)
end

function BrainrotData.StarBonus(stars)
	return 1 + BrainrotData.BonusPerStar * BrainrotData.ClampStars(stars)
end

-- Spare copies needed for the next star, or nil once it's maxed.
function BrainrotData.MergeCost(stars)
	return BrainrotData.MergeCopies[BrainrotData.ClampStars(stars) + 1]
end

-- "★★☆☆☆", or "" for an unmerged brainrot so plain cards stay plain.
function BrainrotData.StarText(stars)
	stars = BrainrotData.ClampStars(stars)
	if stars == 0 then
		return ""
	end
	return string.rep("★", stars) .. string.rep("☆", BrainrotData.MaxStars - stars)
end

-- Companion numbers for a brainrot, with the rarity baseline, its level and its merge stars
-- applied. Used by the server to fight and by the inventory to show the same numbers the server
-- uses.
function BrainrotData.Stats(def, level, stars)
	local attack = BrainrotData.Attacks[def.attack] or BrainrotData.Attacks.Spit
	local bonus = BrainrotData.LevelBonus(level or 1) * BrainrotData.StarBonus(stars)
	local damage = math.floor((BrainrotData.RarityDamage[def.rarity] or 6) * attack.power * (def.power or 1)
		* BrainrotData.AbilityPower * bonus + 0.5)
	local cooldown = attack.cooldown * (BrainrotData.RarityCooldown[def.rarity] or 1) * BrainrotData.AbilityCooldown

	return {
		kind = def.attack or "Spit",
		move = def.move or attack.label,
		description = attack.description,
		damage = damage,
		cooldown = math.floor(cooldown * 100 + 0.5) / 100,
		-- A radial move's range is its radius, in whole studs (14, 16, 17, 19, 20, 22, 23).
		range = attack.radial and math.floor(attack.range + (attack.radiusStep or 0) * (BrainrotData.RarityIndex[def.rarity] or 0) + 0.5)
			or (attack.range + (BrainrotData.RarityRange[def.rarity] or 0)),
		splash = attack.splash or 0,
		radial = attack.radial == true,
		chain = attack.chain,
		dps = math.floor(damage / cooldown * 10 + 0.5) / 10,
		health = math.floor((BrainrotData.RarityHealth[def.rarity] or 60) * bonus + 0.5),
		level = level or 1,
		stars = BrainrotData.ClampStars(stars),
		color = def.look and def.look.accent or Color3.fromRGB(255, 255, 255),
	}
end

return BrainrotData
