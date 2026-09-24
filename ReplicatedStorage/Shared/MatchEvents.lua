-- Match events: a modifier rolled when a match starts, so two matches on the same map don't play
-- the same. Announced on the banner and in a toast. Some matches (NoneChance) have none.
--
--   chestGuns            guns per chest (normally 2)
--   chestRarityFloor     every chest's first gun is at least this rarity
--   dropInterval         seconds between supply drops (normally 95)
--   firstDrop            seconds before the first supply drop (normally 75)
--   speedMultiplier      every player's base walk speed
--   startShield          shield everyone drops in with
--   placementMultiplier  placement coins
--   bountyMinKills       kills before a bounty goes on the leader (normally 3)
--   bountyMultiplier     bounty rewards
--   headshotMultiplier   scales every headshot on top of the gun's own multiplier
--   stormSpeed           how much faster the storm's phases run
--   gravity              workspace gravity, as a fraction of normal
--   lighting             overrides laid over the map's own time of day

local MatchEvents = {}

-- Zone Rush's storm speed, named once so its card can quote it: "half again as fast" was an idiom
-- many players would not read as 1.5x (#86), and a typed "50%" would drift from the number.
local ZONE_RUSH_SPEED = 1.5

MatchEvents.NoneChance = 0.3

MatchEvents.List = {
	{
		id = "LootFrenzy",
		name = "Loot Frenzy",
		description = "Three guns in every chest and a supply drop every minute.",
		color = Color3.fromRGB(255, 196, 64),
		chestGuns = 3,
		dropInterval = 60,
	},
	{
		id = "BountyRush",
		name = "Bounty Rush",
		description = "Bounties from the first kill, and they pay double.",
		color = Color3.fromRGB(255, 110, 110),
		bountyMinKills = 1,
		bountyMultiplier = 2,
	},
	{
		id = "RotRush",
		name = "Rot Rush",
		description = "Everyone moves 20% faster. Fights come to you.",
		color = Color3.fromRGB(80, 220, 255),
		speedMultiplier = 1.2,
	},
	{
		id = "ShieldUp",
		name = "Shield Up",
		description = "Everyone starts with 50 shield.",
		color = Color3.fromRGB(80, 170, 255),
		startShield = 50,
	},
	{
		id = "HighStakes",
		name = "High Stakes",
		description = "Placement coins pay 1.5x. Placing matters more than ever.",
		color = Color3.fromRGB(94, 214, 122),
		placementMultiplier = 1.5,
	},
	{
		id = "NightOps",
		name = "Night Ops",
		description = "Lights out. Street lamps, muzzle flashes and neon are all you've got.",
		color = Color3.fromRGB(120, 130, 220),
		lighting = { clockTime = 0.3, brightness = 0.35, ambient = Color3.fromRGB(16, 18, 30), outdoorAmbient = Color3.fromRGB(34, 38, 60) },
	},
	{
		id = "LowGravity",
		name = "Low Gravity",
		description = "Half gravity: jump higher, fall slower, and every rooftop is reachable.",
		color = Color3.fromRGB(200, 150, 255),
		gravity = 0.5,
	},
	{
		id = "ZoneRush",
		name = "Zone Rush",
		description = string.format("The storm closes %d%% faster. Keep moving.", math.floor((ZONE_RUSH_SPEED - 1) * 100 + 0.5)),
		color = Color3.fromRGB(190, 90, 255),
		stormSpeed = ZONE_RUSH_SPEED,
	},
	{
		id = "HotDrops",
		name = "Hot Drops",
		description = "A supply drop every 45 seconds, the first before the storm even starts.",
		color = Color3.fromRGB(255, 150, 60),
		dropInterval = 45,
		firstDrop = 20,
	},
	{
		id = "Headhunter",
		name = "Headhunter",
		description = "Headshots deal double. Aim high.",
		color = Color3.fromRGB(255, 220, 90),
		headshotMultiplier = 2,
	},
	{
		id = "AuraFarm",
		name = "Aura Farm",
		description = "Every chest holds at least one Epic gun.",
		color = Color3.fromRGB(190, 120, 255),
		chestRarityFloor = "Epic",
	},
}

local byId = {}
for _, event in ipairs(MatchEvents.List) do
	byId[event.id] = event
end

function MatchEvents.Get(id)
	return byId[id]
end

-- nil for a plain match, otherwise one event at random.
function MatchEvents.Roll()
	if math.random() < MatchEvents.NoneChance then
		return nil
	end
	return MatchEvents.List[math.random(1, #MatchEvents.List)]
end

-- What clients are told: enough to announce it, nothing they could use to cheat.
function MatchEvents.Describe(event)
	if not event then
		return nil
	end
	return { id = event.id, name = event.name, description = event.description, color = event.color }
end

return MatchEvents
