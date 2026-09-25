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

-- The emitter every aura had before designs could declare their own. Any aura without an `aura` field
-- is built from exactly this, so the fifteen that shipped are untouched by the layer system.
local DEFAULT_LAYER = {
	size = 0.55,
	transparency = 0.3,
	lifetime = { 0.8, 1.4 },
	rate = 14,
	speed = { 1.5, 3 },
	spread = 180,
	rise = 2.5,
}

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

	-- A dead player's body stays as player.Character, hidden by DeathFx, until the match respawns
	-- them. An equip while spectating must not hang a fresh glowing aura on that invisible corpse.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local data = PlayerData.Get(player)
	local auraId = data and data.Cosmetics.aura
	local item = auraId and CosmeticData.Get(auraId)
	if not item or item.kind ~= "Aura" then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = AURA_NAME

	-- An aura used to be one emitter driven by one colour, which made fifteen cosmetics that differed
	-- only in hue. A design may now declare `aura.layers`, each layer its own emitter, so an aura can
	-- be heavy puffs that sink, a fast spit of needles, or a trail with sparks in it. Layers are
	-- ParticleEmitters and nothing else -- no per-frame work, and the whole thing still replicates as
	-- one attachment. An entry with no `aura` field gets DEFAULT_LAYER, which is the emitter that
	-- shipped, value for value, so every existing aura renders exactly as it does today.
	local design = item.aura or {}
	for _, layer in ipairs(design.layers or { DEFAULT_LAYER }) do
		local emitter = Instance.new("ParticleEmitter")
		local tint = layer.color or item.color
		-- No Texture set: ParticleEmitter falls back to Roblox's built-in sparkle, so this needs
		-- no uploaded asset.
		if layer.fade then
			emitter.Color = ColorSequence.new(tint, layer.fade)
		else
			emitter.Color = ColorSequence.new(tint)
		end
		emitter.LightEmission = layer.lightEmission or 0.8
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, layer.size or 0.55),
			NumberSequenceKeypoint.new(1, layer.endSize or 0),
		})
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, layer.transparency or 0.3),
			NumberSequenceKeypoint.new(1, 1),
		})
		local life = layer.lifetime or { 0.8, 1.4 }
		emitter.Lifetime = NumberRange.new(life[1], life[2])
		emitter.Rate = layer.rate or 14
		local speed = layer.speed or { 1.5, 3 }
		emitter.Speed = NumberRange.new(speed[1], speed[2])
		local spread = layer.spread or 180
		emitter.SpreadAngle = Vector2.new(spread, spread)
		emitter.Acceleration = Vector3.new(0, layer.rise or 2.5, 0)
		emitter.Drag = layer.drag or 0
		emitter.Rotation = NumberRange.new(layer.rotation or 0, layer.rotation or 0)
		emitter.RotSpeed = NumberRange.new(-(layer.spin or 0), layer.spin or 0)
		emitter.Parent = attachment
	end

	local light = Instance.new("PointLight")
	light.Color = design.lightColor or item.color
	light.Range = design.lightRange or 10
	light.Brightness = design.lightBrightness or 1.2
	light.Shadows = true
	light.Parent = attachment

	-- Parented last, with every emitter and the light already on it, so the aura replicates as one
	-- piece rather than several steps onto a character that is already live.
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
