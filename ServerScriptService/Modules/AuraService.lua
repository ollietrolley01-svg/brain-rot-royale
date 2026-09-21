-- Renders equipped aura cosmetics on characters.
--
-- Auras were purchasable — and handed out by the Brainrot Pass — but nothing ever drew them,
-- so buying one did nothing at all. They're a soft tinted glow plus drifting particles,
-- visible to everyone. The light casts shadows and particles don't render through geometry,
-- so an aura never doubles as a way to spot someone hiding behind cover.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CosmeticData = require(Shared:WaitForChild("CosmeticData"))

local PlayerData = require(script.Parent:WaitForChild("PlayerData"))

local AuraService = {}

local AURA_NAME = "CosmeticAura"

function AuraService.Apply(player, character)
	character = character or player.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local existing = root:FindFirstChild(AURA_NAME)
	if existing then
		existing:Destroy()
	end

	local data = PlayerData.Get(player)
	local auraId = data and data.Cosmetics.aura
	local item = auraId and CosmeticData.Get(auraId)
	if not item or item.kind ~= "Aura" then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = AURA_NAME

	-- No Texture set: ParticleEmitter falls back to Roblox's built-in sparkle, so this needs
	-- no uploaded asset.
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(item.color)
	emitter.LightEmission = 0.8
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.8, 1.4)
	emitter.Rate = 14
	emitter.Speed = NumberRange.new(1.5, 3)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = Vector3.new(0, 2.5, 0)
	emitter.Parent = attachment

	local light = Instance.new("PointLight")
	light.Color = item.color
	light.Range = 10
	light.Brightness = 1.2
	light.Shadows = true
	light.Parent = attachment

	-- Parented last, with emitter and light attached, so the aura replicates as one piece
	-- rather than three steps onto a character that's already live.
	attachment.Parent = root
end

function AuraService.Start()
	local function hook(player)
		player.CharacterAdded:Connect(function(character)
			character:WaitForChild("HumanoidRootPart", 10)
			AuraService.Apply(player, character)
		end)
		if player.Character then
			AuraService.Apply(player, player.Character)
		end
	end

	for _, player in ipairs(Players:GetPlayers()) do
		hook(player)
	end
	Players.PlayerAdded:Connect(hook)
end

return AuraService
