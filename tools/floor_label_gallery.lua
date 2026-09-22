-- Can you still read a floor gun's name now that its tier is in front of it?
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/floor_label_gallery.lua -OutDir <dir>
--
-- The label carries the rarity in words as well as in colour, because colour alone asked a player to
-- have learnt seven shades and excluded anyone who cannot tell two of them apart. The billboard is
-- `UDim2.fromScale(3.2, 0.64)` with `TextScaled = true` and `MaxDistance = 60`, so a longer string
-- cannot clip -- it SHRINKS. That turns a clipping risk into a legibility one, which is the same shape
-- as the fault being fixed: information present but unreadable.
--
-- So this photographs the worst case at the range a player decides from. Longest tiered name in the
-- arsenal against the shortest, at 40 and 60 studs, through the shipped spawn path
-- (`LootService.DropWeapon`) rather than a stand-in label -- what is photographed is what spawns.
--
-- If the name reads too small: the rarity goes on its own line in a taller billboard. It does not get
-- dropped -- the reason it was added is the one that matters.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Lighting = game:GetService("Lighting")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local LootService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("LootService"))

local ORIGIN = Vector3.new(0, 300, 0)
Lighting.ClockTime = 14
Lighting.Brightness = 2.4

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

-- Longest and shortest "<Rarity> <Name>" in the arsenal, measured rather than chosen by eye.
local longest, shortest
for id, def in pairs(WeaponData.Weapons) do
	local text = string.format("%s %s", def.rarity, def.name)
	if not longest or #text > #longest.text then
		longest = { id = id, text = text }
	end
	if not shortest or #text < #shortest.text then
		shortest = { id = id, text = text }
	end
end
note(string.format("longest label %d chars: %q (%s)", #longest.text, longest.text, longest.id))
note(string.format("shortest label %d chars: %q (%s)", #shortest.text, shortest.text, shortest.id))
note("billboard is UDim2.fromScale(3.2, 0.64), TextScaled true, MaxDistance 60 -- long names shrink, they do not clip")

local function ground(folder, at)
	local pad = Instance.new("Part")
	pad.Anchored = true
	pad.Size = Vector3.new(120, 1, 120)
	pad.CFrame = CFrame.new(at - Vector3.new(0, 3, 0))
	pad.Color = Color3.fromRGB(104, 112, 104)
	pad.Material = Enum.Material.Grass
	pad.Parent = folder
end

local function shot(which, distance)
	return function(folder, camera)
		ground(folder, ORIGIN)
		-- The shipped path, so the label under test is the one the game builds.
		local ok = pcall(LootService.DropWeapon, which.id, ORIGIN, nil, nil)
		if not ok then
			note("DropWeapon failed for " .. which.id .. " -- this frame proves nothing")
		end
		-- Move whatever it spawned into this view's folder so the gallery cleans up after itself.
		local loot = workspace:FindFirstChild("Loot")
		if loot then
			for _, child in ipairs(loot:GetChildren()) do
				child.Parent = folder
			end
		end
		local eye = ORIGIN + Vector3.new(0, 4.6, distance)
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(eye, ORIGIN + Vector3.new(0, 2.5, 0))
		note(string.format("%s at %d studs: %q", which.id, distance, which.text))
	end
end

local views = {}
for _, distance in ipairs({ 40, 60 }) do
	table.insert(views, { name = string.format("longest_%dstuds", distance), setup = shot(longest, distance) })
	table.insert(views, { name = string.format("shortest_%dstuds", distance), setup = shot(shortest, distance) })
end

return views
