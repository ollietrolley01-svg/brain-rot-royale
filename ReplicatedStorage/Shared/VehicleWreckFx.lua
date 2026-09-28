-- What a vehicle's lamps and smoke do once it's wrecked (#53/#57's visible half). ModuleScript, on
-- the same footing as GunFx.lua/ExplosiveFx.lua: split out of VehicleClient.client.lua (a
-- LocalScript, which a gallery cannot require and drive) specifically so this can be proven the way
-- those already are, rather than asserted.
--
--   VehicleWreckFx.LampShare(role, wrecked, driven, braking) -> 0..1   pure, no Instances, unit-testable
--   VehicleWreckFx.LampBaseColor(part) -> Color3                       the part's TRUE original colour
--   VehicleWreckFx.SetSmoke(model, wrecked) -> ParticleEmitter or nil  creates once, toggles after
--   VehicleWreckFx.Watch(model)                                        OnWreck the moment it's wrecked
--
-- Reasons wrecked matters twice over: the driver's own HUD warning (VehicleClient's panel) is
-- rarely SEEN, because the same server frame that zeroes health also ejects them (VehicleService's
-- damageVehicle sets Sit = false), tearing the driving HUD down before the next Stepped tick. Dark
-- lamps and smoke are what actually reaches a bystander, or someone who walks up wondering why the
-- drive prompt vanished.

local VehicleWreckFx = {}

local DIM_PARKED = 0.34
local DIM_TAIL = 0.42
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds" -- already proven in ExplosiveFx.lua/GunFx.lua

-- The brightness share a lamp of `role` ("tail" or anything else) should show, given whether the
-- vehicle is wrecked, driven and braking. Pure function: no Instances touched, so a probe can hand
-- it every combination directly rather than building a model to find out.
function VehicleWreckFx.LampShare(role, wrecked, driven, braking)
	if wrecked then
		return 0
	end
	if role == "tail" then
		return braking and 1 or DIM_TAIL
	end
	return driven and 1 or DIM_PARKED
end

-- The part's TRUE original colour, read from a persisted attribute rather than from `.Color`
-- itself (bug-hunt B3-2, the defense-in-depth half; strong-keying VehicleClient's `lamps` cache is
-- the other half). `.Color` is what LampShare's result gets multiplied into every frame, so reading
-- it back as "the base" a second time is exactly how a rebuilt cache used to compound the darkening
-- forever. Set once, on the first call for a given part, and never written again by anything in
-- this module -- callable any number of times (a rebuilt cache, a repeated probe call) and always
-- recovers the same value.
local BASE_COLOR_ATTRIBUTE = "LampBaseColor"
function VehicleWreckFx.LampBaseColor(part)
	local base = part:GetAttribute(BASE_COLOR_ATTRIBUTE)
	if typeof(base) ~= "Color3" then
		base = part.Color
		part:SetAttribute(BASE_COLOR_ATTRIBUTE, base)
	end
	return base
end

-- One ParticleEmitter per vehicle, made once (lazily, only once `wrecked` is first true) and just
-- enabled/disabled after -- attached to the Chassis, which every registered kind has, rather than
-- any per-model part, so it works without per-model authoring. Returns the emitter (or nil if there
-- is no Chassis, or none has been made yet and `wrecked` is false) so a caller/probe can inspect it.
--
-- STRONG keys (bug-hunt B3-3a, 2026-09-21): this is called every frame, for every vehicle within
-- ANIMATE_DISTANCE, by VehicleClient's updateLamps. A weak `smoke` table meant a dropped-and-
-- recreated entry made a SECOND Attachment+ParticleEmitter while the first stayed parented and
-- enabled (nothing ever destroys the old one) -- duplicate emitters, compounding smoke rate, and a
-- leaked Instance per drop. Dropped explicitly on AncestryChanged, same shape as `lamps` above.
local smoke = {}

-- Called with the model when a vehicle this client is watching becomes wrecked (its blast:
-- ProjectileClient sets it). A wreck that was already a wreck when first seen stays silent.
VehicleWreckFx.OnWreck = nil
-- model -> its Wrecked connection. Strong keys, dropped when the model leaves the world.
local watched = {}

-- Watch one vehicle for the moment it's wrecked. VehicleClient's track() calls this for every
-- vehicle it finds, near or far, so the blast goes off when Wrecked turns true wherever the vehicle
-- is. It used to fire from SetSmoke, which only runs within VehicleClient's ANIMATE_DISTANCE (320):
-- a car wrecked further off blew up late, when you walked up to it. A vehicle that arrives already
-- wrecked (streamed in, joined late) never sees Wrecked change, so it stays silent. The server never
-- un-wrecks a vehicle and a respawn is a new model, so this fires once per wreck. Calling it again
-- for a model already watched does nothing.
function VehicleWreckFx.Watch(model)
	if watched[model] then
		return
	end
	watched[model] = model:GetAttributeChangedSignal("Wrecked"):Connect(function()
		if model:GetAttribute("Wrecked") == true and VehicleWreckFx.OnWreck then
			VehicleWreckFx.OnWreck(model)
		end
	end)
	local leave
	leave = model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) and watched[model] then
			watched[model]:Disconnect()
			watched[model] = nil
			leave:Disconnect()
		end
	end)
end

function VehicleWreckFx.SetSmoke(model, wrecked)
	local emitter = smoke[model]
	if not emitter then
		if not wrecked then
			return nil
		end
		local chassis = model:FindFirstChild("Chassis")
		if not chassis then
			return nil
		end
		local attachment = Instance.new("Attachment")
		attachment.Name = "WreckSmoke"
		attachment.Position = Vector3.new(0, chassis.Size.Y / 2, -chassis.Size.Z * 0.2)
		attachment.Parent = chassis
		emitter = Instance.new("ParticleEmitter")
		emitter.Texture = SMOKE_TEXTURE
		emitter.Color = ColorSequence.new(Color3.fromRGB(40, 40, 42))
		emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 2.2) })
		emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
		emitter.Lifetime = NumberRange.new(1.4, 2.2)
		emitter.Rate = 12
		emitter.Speed = NumberRange.new(1.5, 2.5)
		emitter.SpreadAngle = Vector2.new(12, 12)
		emitter.Enabled = false
		emitter.Parent = attachment
		smoke[model] = emitter
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				smoke[model] = nil
			end
		end)
	end
	emitter.Enabled = wrecked
	return emitter
end

return VehicleWreckFx
