local Rarity = {}

-- Mythic and Secret sit above Legendary. Nothing drops them loose: they come only from the top
-- crates, at small odds, which is what makes a full collection a long grind.
Rarity.Order = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret" }

Rarity.Index = {}
for index, name in ipairs(Rarity.Order) do
	Rarity.Index[name] = index
end

Rarity.Colors = {
	Common = Color3.fromRGB(178, 184, 196),
	Uncommon = Color3.fromRGB(94, 214, 122),
	Rare = Color3.fromRGB(74, 156, 255),
	Epic = Color3.fromRGB(186, 104, 255),
	Legendary = Color3.fromRGB(255, 184, 48),
	Mythic = Color3.fromRGB(255, 70, 140),
	Secret = Color3.fromRGB(120, 255, 235),
}

function Rarity.Color(name)
	return Rarity.Colors[name] or Rarity.Colors.Common
end

function Rarity.IsAtLeast(name, threshold)
	return (Rarity.Index[name] or 0) >= (Rarity.Index[threshold] or 0)
end

-- Picks a rarity from a {Common = 70, Rare = 30, ...} weight map.
function Rarity.Roll(weights)
	local total = 0
	for _, weight in pairs(weights) do
		total += weight
	end
	if total <= 0 then
		return "Common"
	end

	local roll = math.random() * total
	local cumulative = 0
	for _, name in ipairs(Rarity.Order) do
		local weight = weights[name]
		if weight and weight > 0 then
			cumulative += weight
			if roll <= cumulative then
				return name
			end
		end
	end
	return "Common"
end

return Rarity
