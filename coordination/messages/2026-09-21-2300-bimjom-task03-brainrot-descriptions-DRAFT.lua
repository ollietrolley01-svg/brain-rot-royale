-- Task 03 draft: a codex description for every brainrot, keyed by name.
--
-- The name IS the brainrot's id: saved collections store brainrots by name, and
-- BrainrotData.Get(name) is the lookup (BrainrotData.lua:7-11, 306-313 on main e0b3aa6).
--
-- This file lives OUTSIDE the repo on purpose. BrainrotData.lua has no description field and a
-- worker on the build machine is restructuring it, so nothing here is applied. When the field
-- exists, each line drops in as `description = "..."` on the entry with that name.
--
-- Voice (from the PR style note): third person, present tense. Two sentences: what it is, then a
-- flat closer. The name never appears in its own line. Ends in a full stop. No exclamation marks.
-- Hard cap 76 characters: the Codex subtitle slot on an 844x390 landscape phone for an OWNED row,
-- 396 px at a pessimistic 5.2 px per character (derivation in the PR body).
--
-- Checked by brainrot-descriptions-check.py beside this file. That checker checks THIS draft
-- against the names in BrainrotData.lua and proves nothing about BrainrotData.lua itself.

return {
	-- Common ------------------------------------------------------------------
	["Tung Tung Tung Sahur"] = "A wooden bean with two arms and one plan. The plan is a very big bonk.",
	["Bombardiro Crocodilo"] = "A green blob with wings, fangs and no brakes. Drops things from above.",
	["Trippi Troppi"] = "A teal stack with ears and no plan. Pops bubbles at whoever is near.",
	["Pizzarino Blobbo"] = "A pizza that grew a face and a cap. Spits pepperoni, which is a waste.",
	["Sockolino Stinko"] = "A lone sock that never found its pair. Lobs a smell that arrives first.",
	["Toastini Crunchi"] = "Toast with arms and opinions. Slams crust-first, so mind the crumbs.",
	["Bubblo Gummo"] = "A chewed pink blob with a bow. Spits gum that sticks to everyone.",
	["Noodlo Wobblo"] = "A wobbling stack with noodles for hair. Whips with them, and it stings.",
	["Cactino Pokko"] = "A small cactus with a flower and a grudge. Fires needles, looks innocent.",
	["Mudlo Splosh"] = "A puddle that learned to walk. Lobs mud and leaves footprints on the carpet.",

	-- Uncommon ----------------------------------------------------------------
	["Tralalero Tralala"] = "A blue disc on two feet, grinning. Fires a wave beam and keeps walking.",
	["Chimpanzini Bananini"] = "A smiling banana with ears. Tosses peels, and peels do what peels do.",
	["Boneca Ambalabu"] = "A red cube on two feet, scowling. Hops up, comes down, repeats.",
	["Cappellino Fizzolo"] = "A fizzy bean in a cap and visor. Its beam tingles like fizz up the nose.",
	["Lamponi Brillo"] = "A glossy raspberry with a leaf on top. Lobs berries that burst on arrival.",
	["Frullato Vortini"] = "A one-eyed blender with a propeller. Spins, and anyone nearby is smoothie.",
	["Gnocco Grumpini"] = "A grey lump with horns and no patience. Stomps because talking never worked.",
	["Pinguino Scivolo"] = "A penguin in a scarf, in a hurry. Belly slides into anyone in the way.",
	["Zucchero Scintilla"] = "A sugar cube gone slightly pixelated. Sparks when excited, which is always.",

	-- Rare --------------------------------------------------------------------
	["Lirili Larila"] = "A sleepy green bean covered in spikes. Fires thorns with its eyes shut.",
	["Ballerina Cappuccina"] = "A coffee-coloured stack with a bow. Spins fast enough to knock you over.",
	["Brr Brr Patapim"] = "A leafy green blob with a moustache and feet. Stomps twice, never once.",
	["Robottino Bip Bop"] = "A metal box with an antenna and a laser. Beeps before it fires, politely.",
	["Draghetto Tostato"] = "A red dragon the size of a kettle. Breathes just enough fire to burn toast.",
	["Polpetta Orbitale"] = "A meatball with orbiting sauce. Lobs itself, which ends badly for you.",
	["Nuvolino Tuono"] = "A sleepy cloud carrying one bolt. Zaps one, then the next, without waking.",
	["Fungo Saltarello"] = "A blushing mushroom on two feet. Stomps, and everyone breathes spores.",

	-- Epic --------------------------------------------------------------------
	["Frigo Camelo"] = "A fridge with humps and arms. Its frost ray is colder than the leftovers.",
	["Bombombini Gusini"] = "A grey goose with wings, a tail and a temper. Its honks land as bombs.",
	["Vulcanino Brontolo"] = "A small grumbling volcano with cracks in it. Pulses magma when annoyed.",
	["Specchio Riflesso"] = "A mirrored cube with an orbiting spark. Its zap bounces to whoever looks.",
	["Gufo Mezzanotte"] = "A navy owl with very large eyes. Fires a night beam and sees you blink.",
	["Serpentino Zigzag"] = "A lime snake with a purple zigzag. Spits darts, never in a straight line.",
	["Astronauta Pisolino"] = "An astronaut napping on the job. Lobs moon rocks in its sleep.",

	-- Legendary ---------------------------------------------------------------
	["La Vacca Saturno Saturnita"] = "A spotted cow with a ring round its middle. Its quake rattles the ring.",
	["Golden Sahur"] = "A solid gold bean in a crown. Bonks like the wooden one, only shinier.",
	["Re Formaggione"] = "A king made of cheese, holes and all. Its royal wave is a smell you bow to.",
	["Galassia Sognante"] = "A glowing purple disc with a halo and one eye. Its zap hops between stars.",
	["Drago Arcobaleno"] = "A pink dragon breathing every colour at once. Prism breath, no refunds.",
	["Fantasmino Eterno"] = "A see-through ghost with a halo. Its ray goes through you, and so does it.",

	-- Second wave -------------------------------------------------------------
	["Spaghettino Twirlo"] = "A ball of spaghetti with a fork still in it. Lashes with a noodle, twirled.",
	["Gommino Rimbalzo"] = "A rubbery green stack on two feet. Bounces once into you and once away.",
	["Lanternino Lucciola"] = "A sleepy firefly with a lamp for a tail. Flickers, and the flicker zaps.",
	["Cuscino Pisolone"] = "A pillow in a nightcap, very comfy. Its nap wave makes everyone drowsy.",
	["Tartarughino Turbo"] = "A turtle with an exhaust pipe on its shell. Rushes in, a first for turtles.",
	["Sirenetta Bollicina"] = "A small mermaid with a bow. Fires bubbles by the dozen, never one at a time.",
	["Magnetino Attrazione"] = "A red horseshoe magnet with a visor. Pulls in one enemy, then a second.",
	["Cavaliere Croissant"] = "A croissant in a plumed helmet, flaky and brave. Charges, leaving butter.",
	["Stregonella Zucca"] = "A fanged pumpkin in a witch's hat. Lobs a hex, and the hex is a pumpkin.",
	["Nebbiolina Specchio"] = "A one-eyed disc of mist. Its beam is hard to see and harder to dodge.",
	["Imperatore Gelato"] = "An ice cream emperor in a crown and scarf. Brain freeze, no spoon needed.",
	["Titano Tostapane"] = "A fridge-sized toaster with arms. Lobs burnt toast until the room smells.",

	-- Mythic ------------------------------------------------------------------
	["Fenice Pixelata"] = "A phoenix at a very low resolution. Burns down, reloads, burns again.",
	["Kraken Caramello"] = "A caramel kraken, still dripping. Its tentacles link one enemy to the next.",
	["Oracolo Lavatrice"] = "A washing machine with a halo. It knows your future and puts it on a spin.",
	["Drago Gelatina"] = "A see-through jelly dragon with wings. Lobs wobbles that go off on impact.",
	["Samurai Sushi"] = "A sushi roll with a topknot and moustache. One slash, then the wasabi.",

	-- Secret ------------------------------------------------------------------
	["Il Glitch Primordiale"] = "The first bug there ever was, with a halo. Its zap tears reality a little.",
	["Cosmo Nonno Stellare"] = "A bearded grandpa in a nightcap, ringed by stars. His nap began everything.",
	["Arcobalenissimo"] = "A winged disc of every colour, with a halo. Its beam never runs out.",

	-- Third wave: Common ------------------------------------------------------
	["Pomodorino Schizzo"] = "A blushing tomato with its tongue out. Squirts sauce that never washes out.",
	["Biscottino Crumbo"] = "A chocolate chip cookie with a small smile. Crashes down, leaves crumbs.",
	["Lumachina Lenta"] = "A snail in no hurry at all. Lobs slime in a slow arc that still gets there.",
	["Ombrellino Pioggia"] = "A blushing umbrella with a face. Its drizzle beam is wet and mildly rude.",
	["Patatina Fritta"] = "A carton of fries with big eyes. Fires salt, and the salt finds your eyes.",
	["Mattoncino Blocco"] = "A brick with a frown. Drops on you, which is all a brick can really do.",
	["Nuvoletta Pioviggina"] = "A small sleepy cloud, blushing. Rains on one person only, and it is you.",
	["Pulcinello Piumino"] = "A chick still wearing half its shell. Flicks feathers, and feathers do hurt.",
	["Gelatino Tremolo"] = "A green jelly that cannot stop shaking. The wobble is catching.",
	["Salsiccia Saltella"] = "A sausage on two feet, still sizzling. Hops on you, and now you sizzle too.",
	["Cipollina Lacrima"] = "A worried little onion, already crying. Its tear beam makes you cry as well.",
	["Formichina Operaia"] = "A hard-working ant on six legs. Its zap is passed along like a heavy crumb.",
	["Bottoncino Cucito"] = "A pink button with four holes and a smile. Zaps along a thread nobody sees.",
	["Radicchio Rotolo"] = "A purple lettuce with teeth and a bad attitude. Tosses leaves, bitterly.",

	-- Third wave: Uncommon ----------------------------------------------------
	["Pesciolino Bolla"] = "A striped orange fish with big eyes. Blasts bubbles that pop in your face.",
	["Cavolfiore Cervello"] = "A cauliflower that looks like a brain and knows it. Its brain wave is a zap.",
	["Ghiacciolo Sorbetto"] = "A striped ice lolly, melting slowly. Bursts cold in every direction at once.",
	["Ragnetto Tessitore"] = "A purple spider with three eyes. Its web links two victims together.",
	["Tamburino Bum Bum"] = "A red drum with arms, playing itself. Its drum roll shakes everyone nearby.",
	["Pantofolina Morbida"] = "A fluffy pink slipper with ears, half asleep. Smacks softly, but it counts.",
	["Cactusello Danzante"] = "A tall dancing cactus with a flower. Pops prickles while doing the steps.",
	["Zucchina Lanterna"] = "A carved gourd with a glowing face. Lobs light heavier than it looks.",
	["Koalino Pennichella"] = "A grey koala mid-nap. Slams without waking up, then sleeps on you.",
	["Fornellino Fiammella"] = "A little stove with knobs and a pilot light. Its zap is a small blue flame.",
	["Biscione Arrotolato"] = "A coiled green snake with yellow stripes. Spits, then coils back up.",
	["Nocciolino Ninja"] = "A hazelnut in a cape and headband. Its tap from the shadows is a bonk.",
	["Pinna Surfista"] = "A fin in sunglasses with a surfboard. Tosses waves, and that is the trick.",

	-- Third wave: Rare --------------------------------------------------------
	["Gufetto Professore"] = "A small owl in a monocle and mortarboard. Its lecture beam goes on a while.",
	["Polipo Pittore"] = "An octopus in a beret, tentacles in paint. Splashes ink and calls it art.",
	["Cervo Neon"] = "A brown deer with mint glowing antlers. Its zap arcs from one to the next.",
	["Pipistrello Bollente"] = "A bat that runs hot, with big ears. Its screech comes out as spit, somehow.",
	["Scatolone Robusto"] = "A cardboard box in a tie. Crushes you flat and stacks neatly afterwards.",
	["Cucciolo Cometa"] = "A see-through puppy with a comet for a tail. Zaps you, then wants a cuddle.",
	["Riccio Rotante"] = "A blushing hedgehog on two feet. Spins, and the quills go everywhere.",
	["Barattolo Miele"] = "A sleepy honey jar with wings, dripping. Drops honey, and it stays dropped.",
	["Tricheco Baffone"] = "A walrus with a huge moustache, mostly asleep. One tusk thump, then done.",
	["Faro Guardiano"] = "A striped lighthouse with a lamp on top. The beam sweeps round, finds you.",
	["Ape Operosa"] = "A busy bee with a stinger and big eyes. Its buzz zaps one, then the next.",
	["Granchio Tenaglia"] = "A red crab with big claws and a worried look. Pinches first, worries later.",

	-- Third wave: Epic --------------------------------------------------------
	["Mago Merendina"] = "A bearded wizard with a snack in his hat. The snack is the spell.",
	["Cavaliere Lattina"] = "A tin can in a cape and plumed helmet. Charges, and both of you dent.",
	["Medusa Lucente"] = "A glowing lilac jellyfish, dozy. Its sting hops from one enemy to the next.",
	["Unicorno Frizzante"] = "A unicorn with heart eyes and a pink mane. Zaps sparkles, sincerely.",
	["Tuba Tuonante"] = "A gold tuba in headphones, furious. One note, and everyone nearby feels it.",
	["Scheletrino Ballerino"] = "A skeleton in a bow tie, all ribs and rhythm. Bonks you, on the beat.",
	["Astronave Formaggio"] = "A flying saucer made of cheese. Lobs cheese from orbit, holes and all.",
	["Drago Pantofola"] = "A dragon shaped like a fuzzy slipper. Its cosy flame is still fire.",
	["Lupo Lunare"] = "A grey wolf with a moon gem on its forehead. Howls, and the howl is a beam.",
	["Ciclope Cioccolato"] = "A one-eyed chocolate giant, melting a little. Its quake is warm and sticky.",
	["Nuvola Temporale"] = "A dark storm cloud holding a bolt. Its fork lightning takes two at a time.",

	-- Third wave: Legendary ---------------------------------------------------
	["Imperatrice Farfalla"] = "A pink butterfly empress in a crown. Zaps one subject, then the next.",
	["Faraone Fagiolino"] = "A golden bean in a pharaoh's headdress. Buries everyone nearby in sand.",
	["Balena Cantante"] = "A blue whale in headphones, humming. Lobs a song, and the song lands hard.",
	["Titano Tuttifrutti"] = "A giant fruit cube with a cherry on top. Its fruit punch is a real punch.",
	["Stregone Stellato"] = "A navy wizard with stars for eyes. Calls down a star, aimed at you.",
	["Leone Lampadina"] = "A lion with a lightbulb mane and a bolt. Its roar is bright enough to spit.",
	["Castello Ambulante"] = "A stone castle on two feet, with three eyes. Stomps, and the walls join in.",
	["Capitano Calamaro"] = "A squid captain in a top hat, winking. Its ink broadside hits two ships.",

	-- Third wave: Mythic ------------------------------------------------------
	["Grifone Glassato"] = "A griffin with a sugar glaze, still dripping. Dives beak-first, frosts you.",
	["Golem Gorgonzola"] = "A colossus of blue cheese with three eyes. Its bonk is heavy and lingers.",
	["Sfinge Sussurrante"] = "A golden sphinx with stars for eyes. Its beam is a riddle you get wrong.",
	["Leviatano Limonata"] = "A sea monster made of lemonade. Its fizz chains from one enemy to the next.",
	["Mecha Mortadella"] = "A pink deli meat in a robot suit. Overdrives, and the whole deli shakes.",

	-- Third wave: Secret ------------------------------------------------------
	["L'Ultimo Pixel"] = "The very last pixel, with a halo. Renders one enemy, then the next.",
	["Nonna Nebulosa"] = "A blushing nebula with a bun and goggles. Her gravity pulls you in for tea.",
	["Il Buco Nero Bello"] = "A black hole with one eye and petals. Its hug is a beam nothing escapes.",
}
