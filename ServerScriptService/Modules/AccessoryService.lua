-- Wearable accessories: hats, glasses and backpacks.
--
-- Each one is a handful of primitive parts described in CosmeticData, welded to the head or
-- torso — no uploaded meshes, so they cost nothing to add and bots can wear them too. Every
-- piece is non-collidable, massless and non-queryable, so an accessory never changes anyone's
-- hitbox or stops a bullet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
-- The pieces themselves are built in Shared/CosmeticBuild, so the menu's previews are the same
-- geometry as the thing a player wears rather than a second copy of the recipe.
local CosmeticBuild = require(Shared:WaitForChild("CosmeticBuild"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local AccessoryService = {}

local ACCESSORY_NAME = "CosmeticAccessory"

-- Pieces are authored against an R15 head this tall; everything scales from it.
local REFERENCE_HEAD_HEIGHT = CosmeticBuild.ReferenceHeadHeight

-- Returns the part to weld to and the CFrame piece offsets are relative to.
local function anchorFor(character, anchor)
	local head = character:FindFirstChild("Head")
	if anchor == "Back" then
		local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
		if not torso then
			return nil
		end
		return torso, torso.CFrame * CFrame.new(0, 0, torso.Size.Z / 2)
	end

	if not head then
		return nil
	end
	if anchor == "Face" then
		return head, head.CFrame * CFrame.new(0, head.Size.Y * 0.08, -head.Size.Z / 2)
	end
	return head, head.CFrame * CFrame.new(0, head.Size.Y / 2, 0)
end

-- Puts `itemId` on `character`, replacing whatever accessory it had. nil just removes it.
-- Works on characters that aren't parented yet, which is how bots get theirs.
function AccessoryService.Attach(character, itemId)
	local existing = character:FindFirstChild(ACCESSORY_NAME)
	if existing then
		existing:Destroy()
	end

	local item = itemId and CosmeticData.Get(itemId)
	if not item or item.kind ~= "Accessory" then
		return
	end

	local attachTo, origin = anchorFor(character, item.anchor)
	if not attachTo then
		return
	end

	local head = character:FindFirstChild("Head")
	local scale = head and math.clamp(head.Size.Y / REFERENCE_HEAD_HEIGHT, 0.6, 1.8) or 1

	-- Built with no two faces left flush, then welded (after, so only the one part moved).
	local model, pieces = CosmeticBuild.Model(item, origin, scale, ACCESSORY_NAME)
	for _, part in ipairs(pieces) do
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = attachTo
		weld.Part1 = part
		weld.Parent = part
	end

	-- Parented last, fully welded, so it replicates as one piece.
	model.Parent = character
end

function AccessoryService.Apply(player, character)
	character = character or player.Character
	if not character then
		return
	end
	local data = PlayerData.Get(player)
	AccessoryService.Attach(character, data and data.Cosmetics.accessory or nil)
end

function AccessoryService.Start()
	local function hook(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 10)
			AccessoryService.Apply(player, character)
		end)
		-- Avatar appearance can swap body parts in after spawn, and a weld to a replaced head
		-- would drop the accessory on the floor. Re-attach once the appearance has settled.
		player.CharacterAppearanceLoaded:Connect(function(character)
			AccessoryService.Apply(player, character)
		end)
		if player.Character then
			AccessoryService.Apply(player, player.Character)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
end

return AccessoryService
