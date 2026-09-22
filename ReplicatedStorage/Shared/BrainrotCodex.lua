-- Codex flavour text: one entry for every brainrot in BrainrotData.Types.
--
-- Kept in its own file rather than as a field on BrainrotData, because that file is being
-- restructured on the build machine and this is 126 lines of pure text that collides with nothing.
-- Nothing reads it yet; wiring it to a detail panel is the menu worker's call.
--
-- KEYED BY NAME, not by id. BrainrotData entries have no `id` field — `name` is the identity, and
-- the file says so ("saved collections store brainrots by name"). So does the profile, and so does
-- MenuClient's `counts[def.name]`. A codex keyed by anything else would need an id to exist first.
--
-- Provenance: the first two sentences of every entry are the drafts sent to the mailbox on
-- 2026-09-21 (`...-bimjom-task03-brainrot-descriptions-DRAFT.lua`), kept verbatim. They were
-- written to a 76-character Codex ROW. claude-43's reply moved the target to a detail panel with
-- room for "two or three sentences", so each entry gains a third sentence here and the limit goes
-- from 76 to 160. Nothing drafted was thrown away.
--
--------------------------------------------------------------------------------
-- The voice, so a later entry matches the ones already here
--------------------------------------------------------------------------------
--
-- Read the crate blurbs in CrateData.lua first: flat, declarative, third person, full stop at the
-- end, no exclamation marks. The codex is that house voice with a joke in it, not a louder one.
--
--   * Three sentences. What it looks like, what it does, then the deadpan consequence of both
--     being true. The third is the one that can be cut if a panel turns out tighter than this.
--   * Third person, present tense. The brainrot is the subject.
--   * Its own name never appears in its entry — the row above already shows it.
--   * No exclamation marks, no capitals for emphasis, no emoji.
--   * Every line is written from that entry's own `look` and `move` fields and nothing else.
--   * Playable for a young audience: nothing cruel, nothing gory, nobody dies.
--   * Original writing. Twelve entries carry a name that is also a known meme's; they get no
--     catchphrase and no borrowed lore, only the model THIS project builds. See the mailbox note
--     on those names — they were already in the data and renaming them is not ours to do.

local BrainrotCodex = {}

-- The longest line the UI can show, in characters.
--
-- The chain, all of it quoted from the tree:
--   UiKit.panelSize  ->  math.clamp(viewport.X - safe.Left - safe.Right, 320, 1180)
--   MenuClient:180   ->  "a portrait phone leaves about 296 px of content"
--   a content row    ->  UDim2.new(1, -8, ...), so 288 px of card
--   card padding     ->  14 px each side, as every stat row in MenuClient uses
--   = a 260 px text column on the narrowest screen the menu is drawn for.
--
-- ASSUMPTION, and it is the soft part of this number: Gotham's average advance is taken as
-- 0.5 x TextSize, so 6.5 px at the body size of 13. That gives 40 characters a line, and a detail
-- panel four lines tall gives 160. Nothing here has measured a real glyph — TextService only runs
-- inside Studio. When the detail panel exists and can be measured, re-derive this and trim; the
-- checker reports the longest entry against the limit every run, so the headroom is always visible.
BrainrotCodex.MaxLength = 160

BrainrotCodex.Entries = {
	--------------------------------------------------------------------------------
	-- Common
	--------------------------------------------------------------------------------
	["Tung Tung Tung Sahur"] = "A wooden bean with two arms and one plan. The plan is a very big bonk. It has never needed a second plan.",
	["Bombardiro Crocodilo"] = "A green blob with wings, fangs and no brakes. Drops things from above. Nobody ever taught it to land.",
	["Trippi Troppi"] = "A teal stack with ears and no plan. Pops bubbles at whoever is near. It hums one note the entire time.",
	["Pizzarino Blobbo"] = "A pizza that grew a face and a cap. Spits pepperoni, which is a waste. It privately agrees with you.",
	["Sockolino Stinko"] = "A lone sock that never found its pair. Lobs a smell that arrives first. Standing downwind counts as a hit.",
	["Toastini Crunchi"] = "Toast with arms and opinions. Slams crust-first, so mind the crumbs. It was set one notch too dark and kept the grudge.",
	["Bubblo Gummo"] = "A chewed pink blob with a bow. Spits gum that sticks to everyone. It blows a bubble first, out of politeness.",
	["Noodlo Wobblo"] = "A wobbling stack with noodles for hair. Whips with them, and it stings. Nothing with no bones should move that fast.",
	["Cactino Pokko"] = "A small cactus with a flower and a grudge. Fires needles, looks innocent. Compliment the flower and it may hold off.",
	["Mudlo Splosh"] = "A puddle that learned to walk. Lobs mud and leaves footprints on the carpet. It has no solid parts to argue with.",
	["Spaghettino Twirlo"] = "A ball of spaghetti with a fork still in it. Lashes with a noodle, twirled. It is somehow always still warm.",
	["Gommino Rimbalzo"] = "A rubbery green stack on two feet. Bounces once into you and once away. It has never come to a complete stop.",
	["Pomodorino Schizzo"] = "A blushing tomato with its tongue out. Squirts sauce that never washes out. It considers the tablecloth afterwards.",
	["Biscottino Crumbo"] = "A chocolate chip cookie with a small smile. Crashes down, leaves crumbs. It was baked hard enough to count as masonry.",
	["Lumachina Lenta"] = "A snail in no hurry at all. Lobs slime in a slow arc that still gets there. It set off when the match started.",
	["Ombrellino Pioggia"] = "A blushing umbrella with a face. Its drizzle beam is wet and mildly rude. It would rather make rain than stop it.",
	["Patatina Fritta"] = "A carton of fries with big eyes. Fires salt, and the salt finds your eyes. Cold, hard and deeply resentful.",
	["Mattoncino Blocco"] = "A brick with a frown. Drops on you, which is all a brick can really do. One move, and it has never needed a second.",
	["Nuvoletta Pioviggina"] = "A small sleepy cloud, blushing. Rains on one person only, and it is you. Too small to matter, too stubborn to go.",
	["Pulcinello Piumino"] = "A chick still wearing half its shell. Flicks feathers, and feathers do hurt. Hatched early and entirely unbothered.",
	["Gelatino Tremolo"] = "A green jelly that cannot stop shaking. The wobble is catching. It never fully set and has made peace with that.",
	["Salsiccia Saltella"] = "A sausage on two feet, still sizzling. Hops on you, and now you sizzle too. It left the pan some time ago.",
	["Cipollina Lacrima"] = "A worried little onion, already crying. Its tear beam makes you cry as well. The beam is thin and entirely unfair.",
	["Formichina Operaia"] = "A hard-working ant on six legs. Its zap is passed along like a heavy crumb. It has never once dropped the crumb.",
	["Bottoncino Cucito"] = "A pink button with four holes and a smile. Zaps along a thread nobody sees. The coat it came off is long gone.",
	["Radicchio Rotolo"] = "A purple lettuce with teeth and a bad attitude. Tosses leaves, bitterly. It grows them back by teatime.",

	--------------------------------------------------------------------------------
	-- Uncommon
	--------------------------------------------------------------------------------
	["Tralalero Tralala"] = "A blue disc on two feet, grinning. Fires a wave beam and keeps walking. The beam is on the beat, which does not help.",
	["Chimpanzini Bananini"] = "A smiling banana with ears. Tosses peels, and peels do what peels do. It keeps the rest of itself for later.",
	["Boneca Ambalabu"] = "A red cube on two feet, scowling. Hops up, comes down, repeats. The hop is the only warning you get.",
	["Cappellino Fizzolo"] = "A fizzy bean in a cap and visor. Its beam tingles like fizz up the nose. The visor is for the glare, it says, indoors.",
	["Lamponi Brillo"] = "A glossy raspberry with a leaf on top. Lobs berries that burst on arrival. It has more segments than it needs.",
	["Frullato Vortini"] = "A one-eyed blender with a propeller. Spins, and anyone nearby is smoothie. The lid went missing years ago.",
	["Gnocco Grumpini"] = "A grey lump with horns and no patience. Stomps because talking never worked. It waits for the ground to apologise.",
	["Pinguino Scivolo"] = "A penguin in a scarf, in a hurry. Belly slides into anyone in the way. It arrives faster than it can stop.",
	["Zucchero Scintilla"] = "A sugar cube gone slightly pixelated. Sparks when excited, which is always. It is banned from the kitchen.",
	["Lanternino Lucciola"] = "A sleepy firefly with a lamp for a tail. Flickers, and the flicker zaps. The flicker is a countdown to something.",
	["Cuscino Pisolone"] = "A pillow in a nightcap, very comfy. Its nap wave makes everyone drowsy. Comfort at this level had to be classified.",
	["Pesciolino Bolla"] = "A striped orange fish with big eyes. Blasts bubbles that pop in your face. It carries its own water everywhere.",
	["Cavolfiore Cervello"] = "A cauliflower that looks like a brain and knows it. Its brain wave is a zap. It thinks at people from across the road.",
	["Ghiacciolo Sorbetto"] = "A striped ice lolly, melting slowly. Bursts cold in every direction at once. It refuses to finish, out of spite.",
	["Ragnetto Tessitore"] = "A purple spider with three eyes. Its web links two victims together. It has never once explained the plan.",
	["Tamburino Bum Bum"] = "A red drum with arms, playing itself. Its drum roll shakes everyone nearby. The roll builds, then the floor disagrees.",
	["Pantofolina Morbida"] = "A fluffy pink slipper with ears, half asleep. Smacks softly, but it counts. The contradiction is the whole point.",
	["Cactusello Danzante"] = "A tall dancing cactus with a flower. Pops prickles while doing the steps. It has lost neighbours to the hobby.",
	["Zucchina Lanterna"] = "A carved gourd with a glowing face. Lobs light heavier than it looks. It was carved by somebody in a hurry.",
	["Koalino Pennichella"] = "A grey koala mid-nap. Slams without waking up, then sleeps on you. Asleep twenty-two hours, a menace for the rest.",
	["Fornellino Fiammella"] = "A little stove with knobs and a pilot light. Its zap is a small blue flame. It has waited years to be useful.",
	["Biscione Arrotolato"] = "A coiled green snake with yellow stripes. Spits, then coils back up. It is far longer than the coil suggests.",
	["Nocciolino Ninja"] = "A hazelnut in a cape and headband. Its tap from the shadows is a bonk. You are tapped, then you are on the floor.",
	["Pinna Surfista"] = "A fin in sunglasses with a surfboard. Tosses waves, and that is the trick. There is no shark attached to it.",

	--------------------------------------------------------------------------------
	-- Rare
	--------------------------------------------------------------------------------
	["Lirili Larila"] = "A sleepy green bean covered in spikes. Fires thorns with its eyes shut. It goes straight back to sleep afterwards.",
	["Ballerina Cappuccina"] = "A coffee-coloured stack with a bow. Spins fast enough to knock you over. It has not spilled a single drop.",
	["Brr Brr Patapim"] = "A leafy green blob with a moustache and feet. Stomps twice, never once. That is how it keeps itself warm.",
	["Robottino Bip Bop"] = "A metal box with an antenna and a laser. Beeps before it fires, politely. It was built in the wrong decade.",
	["Draghetto Tostato"] = "A red dragon the size of a kettle. Breathes just enough fire to burn toast. It is sensitive about this.",
	["Polpetta Orbitale"] = "A meatball with orbiting sauce. Lobs itself, which ends badly for you. It does come back down eventually.",
	["Nuvolino Tuono"] = "A sleepy cloud carrying one bolt. Zaps one, then the next, without waking. The bolt picks whoever stood nearest.",
	["Fungo Saltarello"] = "A blushing mushroom on two feet. Stomps, and everyone breathes spores. It should stay put, and it will not.",
	["Tartarughino Turbo"] = "A turtle with an exhaust pipe on its shell. Rushes in, a first for turtles. Steering was left out of the design.",
	["Sirenetta Bollicina"] = "A small mermaid with a bow. Fires bubbles by the dozen, never one at a time. It sings the whole way through.",
	["Magnetino Attrazione"] = "A red horseshoe magnet with a visor. Pulls in one enemy, then a second. It has collected every loose screw here.",
	["Gufetto Professore"] = "A small owl in a monocle and mortarboard. Its lecture beam goes on a while. There is no interrupting it.",
	["Polipo Pittore"] = "An octopus in a beret, tentacles in paint. Splashes ink and calls it art. Every piece is a direct hit.",
	["Cervo Neon"] = "A brown deer with mint glowing antlers. Its zap arcs from one to the next. It is wired for night use.",
	["Pipistrello Bollente"] = "A bat that runs hot, with big ears. Its screech comes out as spit, somehow. The screech arrives first, mercifully.",
	["Scatolone Robusto"] = "A cardboard box in a tie. Crushes you flat and stacks neatly afterwards. It calls falling over a technique.",
	["Cucciolo Cometa"] = "A see-through puppy with a comet for a tail. Zaps you, then wants a cuddle. Nobody has measured it sitting still.",
	["Riccio Rotante"] = "A blushing hedgehog on two feet. Spins, and the quills go everywhere. It curls up for safety and keeps going.",
	["Barattolo Miele"] = "A sleepy honey jar with wings, dripping. Drops honey, and it stays dropped. The lid has been loose for years.",
	["Tricheco Baffone"] = "A walrus with a huge moustache, mostly asleep. One tusk thump, then done. It lets the tusks do the explaining.",
	["Faro Guardiano"] = "A striped lighthouse with a lamp on top. The beam sweeps round, finds you. It walked off its cliff and kept working.",
	["Ape Operosa"] = "A busy bee with a stinger and big eyes. Its buzz zaps one, then the next. It files a short report after each.",
	["Granchio Tenaglia"] = "A red crab with big claws and a worried look. Pinches first, worries later. Sideways has always been enough.",

	--------------------------------------------------------------------------------
	-- Epic
	--------------------------------------------------------------------------------
	["Frigo Camelo"] = "A fridge with humps and arms. Its frost ray is colder than the leftovers. It crossed a desert and never lost its cool.",
	["Bombombini Gusini"] = "A grey goose with wings, a tail and a temper. Its honks land as bombs. The honk arrives a moment before the bang.",
	["Vulcanino Brontolo"] = "A small grumbling volcano with cracks in it. Pulses magma when annoyed. It is annoyed shortly after meeting you.",
	["Specchio Riflesso"] = "A mirrored cube with an orbiting spark. Its zap bounces to whoever looks. It gives back more than it was shown.",
	["Gufo Mezzanotte"] = "A navy owl with very large eyes. Fires a night beam and sees you blink. It only exists between midnight and four.",
	["Serpentino Zigzag"] = "A lime snake with a purple zigzag. Spits darts, never in a straight line. The darts go straight, which is the problem.",
	["Astronauta Pisolino"] = "An astronaut napping on the job. Lobs moon rocks in its sleep. It pocketed them up there and declared none.",
	["Cavaliere Croissant"] = "A croissant in a plumed helmet, flaky and brave. Charges, leaving butter. The armour shatters beautifully.",
	["Stregonella Zucca"] = "A fanged pumpkin in a witch's hat. Lobs a hex, and the hex is a pumpkin. The whole spellbook is gourds.",
	["Nebbiolina Specchio"] = "A one-eyed disc of mist. Its beam is hard to see and harder to dodge. You aim at the reflection and hit nothing.",
	["Mago Merendina"] = "A bearded wizard with a snack in his hat. The snack is the spell. Every spell is filling and none are good for you.",
	["Cavaliere Lattina"] = "A tin can in a cape and plumed helmet. Charges, and both of you dent. The helmet fitted, so it kept the helmet.",
	["Medusa Lucente"] = "A glowing lilac jellyfish, dozy. Its sting hops from one enemy to the next. It glows at a depth where nothing should.",
	["Unicorno Frizzante"] = "A unicorn with heart eyes and a pink mane. Zaps sparkles, sincerely. It runs on fizzy drink and refuses water.",
	["Tuba Tuonante"] = "A gold tuba in headphones, furious. One note, and everyone nearby feels it. Windows go before ears do.",
	["Scheletrino Ballerino"] = "A skeleton in a bow tie, all ribs and rhythm. Bonks you, on the beat. It has not stopped dancing in years.",
	["Astronave Formaggio"] = "A flying saucer made of cheese. Lobs cheese from orbit, holes and all. Nobody briefed the crew on the mission.",
	["Drago Pantofola"] = "A dragon shaped like a fuzzy slipper. Its cosy flame is still fire. It is warm, and the burn is not gentle.",
	["Lupo Lunare"] = "A grey wolf with a moon gem on its forehead. Howls, and the howl is a beam. The answer comes from somewhere else.",
	["Ciclope Cioccolato"] = "A one-eyed chocolate giant, melting a little. Its quake is warm and sticky. The ground goes soft where it stamps.",
	["Nuvola Temporale"] = "A dark storm cloud holding a bolt. Its fork lightning takes two at a time. A full storm packed into a personal size.",

	--------------------------------------------------------------------------------
	-- Legendary
	--------------------------------------------------------------------------------
	["La Vacca Saturno Saturnita"] = "A spotted cow with a ring round its middle. Its quake rattles the ring. It will not say where the ring came from.",
	["Golden Sahur"] = "A solid gold bean in a crown. Bonks like the wooden one, only shinier. It hits considerably harder and knows it.",
	["Re Formaggione"] = "A king made of cheese, holes and all. Its royal wave is a smell you bow to. The court left several years ago.",
	["Galassia Sognante"] = "A glowing purple disc with a halo and one eye. Its zap hops between stars. It is having a slow dream about coins.",
	["Drago Arcobaleno"] = "A pink dragon breathing every colour at once. Prism breath, no refunds. Each colour hurts a different way.",
	["Fantasmino Eterno"] = "A see-through ghost with a halo. Its ray goes through you, and so does it. It forgot what it was haunting.",
	["Imperatore Gelato"] = "An ice cream emperor in a crown and scarf. Brain freeze, no spoon needed. The kingdom keeps melting under it.",
	["Titano Tostapane"] = "A fridge-sized toaster with arms. Lobs burnt toast until the room smells. It is still set one notch too dark.",
	["Imperatrice Farfalla"] = "A pink butterfly empress in a crown. Zaps one subject, then the next. Her smallest movement moves the weather.",
	["Faraone Fagiolino"] = "A golden bean in a pharaoh's headdress. Buries everyone nearby in sand. It was dug back up in a bad mood.",
	["Balena Cantante"] = "A blue whale in headphones, humming. Lobs a song, and the song lands hard. The note started before the match did.",
	["Titano Tuttifrutti"] = "A giant fruit cube with a cherry on top. Its fruit punch is a real punch. It was assembled from the whole bowl.",
	["Stregone Stellato"] = "A navy wizard with stars for eyes. Calls down a star, aimed at you. He borrows the light and never returns it.",
	["Leone Lampadina"] = "A lion with a lightbulb mane and a bolt. Its roar is bright enough to spit. It lights the field and blinds it too.",
	["Castello Ambulante"] = "A stone castle on two feet, with three eyes. Stomps, and the walls join in. It left its hill without notice.",
	["Capitano Calamaro"] = "A squid captain in a top hat, winking. Its ink broadside hits two ships. There is no ship under the gun deck.",

	--------------------------------------------------------------------------------
	-- Mythic
	--------------------------------------------------------------------------------
	["Fenice Pixelata"] = "A phoenix at a very low resolution. Burns down, reloads, burns again. It is currently on version nine.",
	["Kraken Caramello"] = "A caramel kraken, still dripping. Its tentacles link one enemy to the next. Once it has hold, it has hold of both.",
	["Oracolo Lavatrice"] = "A washing machine with a halo. It knows your future and puts it on a spin. It has been right enough times to worry.",
	["Drago Gelatina"] = "A see-through jelly dragon with wings. Lobs wobbles that go off on impact. It never quite set overnight.",
	["Samurai Sushi"] = "A sushi roll with a topknot and moustache. One slash, then the wasabi. Assembled at the counter, served at once.",
	["Grifone Glassato"] = "A griffin with a sugar glaze, still dripping. Dives beak-first, frosts you. The party it was iced for was called off.",
	["Golem Gorgonzola"] = "A colossus of blue cheese with three eyes. Its bonk is heavy and lingers. It was left too long in the dark.",
	["Sfinge Sussurrante"] = "A golden sphinx with stars for eyes. Its beam is a riddle you get wrong. It lowered its voice a century ago.",
	["Leviatano Limonata"] = "A sea monster made of lemonade. Its fizz chains from one enemy to the next. The fizz reaches the shore first.",
	["Mecha Mortadella"] = "A pink deli meat in a robot suit. Overdrives, and the whole deli shakes. It runs hot and smells incredible.",

	--------------------------------------------------------------------------------
	-- Secret
	--------------------------------------------------------------------------------
	["Il Glitch Primordiale"] = "The first bug there ever was, with a halo. Its zap tears reality a little. What it touches stops being where it was.",
	["Cosmo Nonno Stellare"] = "A bearded grandpa in a nightcap, ringed by stars. His nap began everything. He is older than the light, and tired.",
	["Arcobalenissimo"] = "A winged disc of every colour, with a halo. Its beam never runs out. Looking at it is a decision you make once.",
	["L'Ultimo Pixel"] = "The very last pixel, with a halo. Renders one enemy, then the next. It works down the list and does not hurry.",
	["Nonna Nebulosa"] = "A blushing nebula with a bun and goggles. Her gravity pulls you in for tea. Declining is not one of the options.",
	["Il Buco Nero Bello"] = "A black hole with one eye and petals. Its hug is a beam nothing escapes. It only ever wanted the hug.",
}

-- The entry for `name`, or nil if there is none. Callers should treat nil as "no text yet" and draw
-- the panel without it rather than substituting a placeholder — a placeholder that ships reads as
-- finished text, and the checker cannot tell one from a real line.
function BrainrotCodex.Get(name)
	return BrainrotCodex.Entries[name]
end

return BrainrotCodex
