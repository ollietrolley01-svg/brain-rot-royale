-- The crate-open lid swing, in one place.
--
-- A crate opens by swinging its lid up and over on its hinge -- CrateModels puts that hinge at the
-- middle of the lid's back edge, as the lid's PivotOffset and as its "Hinge" attribute -- with a
-- moment of press-down first and a little overshoot at the end, so the lid reads as having weight.
--
-- The swing is not the same for every crate (Oliver's #60: the tiers want their own quality of
-- animation). A Common crate snaps open; the further up the ladder, the longer the press-down, the
-- slower the swing and the heavier the settle, so a Prestige Style crate opens like something that
-- cost sixty thousand coins. It is one curve with per-tier numbers rather than a different animation
-- each, because every one of them still has to read as the same crate opening.
--
-- It lives here rather than in MenuClient because two things play it and a third measures it: the
-- crate reveal in the menu, the world containers in LootFxClient, and tools/crate_open_gallery.lua,
-- which renders the swing frame by frame. A gallery that reproduced the curve instead of calling it
-- would drift from the animation it claims to be a picture of.
local CrateOpen = {}

-- Past upright, so the lid comes to rest against the back of the crate the way a chest lid does.
CrateOpen.OpenAngle = math.rad(112)

-- duration: how long the swing takes, in seconds. overshoot: how far past the rest angle it throws
-- before settling, as a share of the open angle. anticipation: the share of the swing spent pressing
-- down before the lid gives. Anything not listed opens on Default -- the kind crates (Accessory,
-- Skin, Aura, Parachute) sit mid-ladder deliberately.
CrateOpen.Default = { duration = 0.46, overshoot = 0.12, anticipation = 0.16 }
CrateOpen.Tiers = {
	Common = { duration = 0.34, overshoot = 0.06, anticipation = 0.10 },
	Uncommon = { duration = 0.38, overshoot = 0.08, anticipation = 0.12 },
	Rare = { duration = 0.42, overshoot = 0.10, anticipation = 0.14 },
	Epic = { duration = 0.46, overshoot = 0.12, anticipation = 0.16 },
	Legendary = { duration = 0.52, overshoot = 0.15, anticipation = 0.18 },
	Mythic = { duration = 0.58, overshoot = 0.17, anticipation = 0.20 },
	Secret = { duration = 0.62, overshoot = 0.19, anticipation = 0.22 },
	Super = { duration = 0.58, overshoot = 0.17, anticipation = 0.20 },
	-- The cosmetic ladder, in step with the brainrot one it is priced against.
	Style = { duration = 0.42, overshoot = 0.10, anticipation = 0.14 },
	DeluxeStyle = { duration = 0.52, overshoot = 0.15, anticipation = 0.18 },
	PrestigeStyle = { duration = 0.62, overshoot = 0.20, anticipation = 0.22 },
}

-- The numbers for one crate tier, every field filled in from Default.
function CrateOpen.For(tier)
	local style = tier and CrateOpen.Tiers[tier] or nil
	if not style then
		return CrateOpen.Default
	end
	return {
		duration = style.duration or CrateOpen.Default.duration,
		overshoot = style.overshoot or CrateOpen.Default.overshoot,
		anticipation = style.anticipation or CrateOpen.Default.anticipation,
	}
end

-- How long this tier's swing lasts. Callers time the rest of the reveal off this.
function CrateOpen.Duration(tier)
	return CrateOpen.For(tier).duration
end

-- The lid's angle, in radians, `since` seconds into the open of a crate of this tier. Negative while
-- it presses down, then rising to OpenAngle with a half-sine overshoot that is gone by the end.
function CrateOpen.Angle(since, tier)
	local style = CrateOpen.For(tier)
	local t = math.clamp((since or 0) / style.duration, 0, 1)
	if t < style.anticipation then
		-- Shallow on purpose: the lid rests on the body, so a press is the front edge biting into it.
		-- 0.05 rad over a 3.2-stud lid is about 0.16 studs, which reads as weight, not as clipping.
		return -0.05 * math.sin(t / style.anticipation * math.pi)
	end
	local s = (t - style.anticipation) / (1 - style.anticipation)
	return CrateOpen.OpenAngle * ((1 - (1 - s) ^ 3) + math.sin(s * math.pi) * style.overshoot)
end

-- Where the lid sits at that angle, given where it started and where its hinge is in its own space.
-- `lidStart * hinge * R * hinge:Inverse()` turns the lid about the hinge without moving the hinge;
-- anything riding on the lid keeps its own offset from this.
--
-- The angle is POSITIVE about X. A crate faces -Z and its hinge is the back edge at +Z, so the front
-- edge sits at -Z from the hinge, and a positive X rotation is the one that lifts it: rotating a
-- point (0, 0, -d) by θ about X sends it to y = d·sinθ, which rises only while θ is positive. The
-- note in CrateModels suggests `CFrame.Angles(-angle, 0, 0)`, which swings the front DOWN into the
-- crate; LootFxClient's world-crate swing, which has been on screen since before this module, uses
-- the positive angle. Measured either way by tools/crate_open_gallery.lua, which fails the sign.
function CrateOpen.LidCFrame(lidStart, hinge, angle)
	return lidStart * hinge * CFrame.Angles(angle, 0, 0) * hinge:Inverse()
end

-- The hinge of a lid part, from the attribute CrateModels writes, falling back to its pivot.
function CrateOpen.Hinge(lid)
	local attribute = lid:GetAttribute("Hinge")
	return typeof(attribute) == "CFrame" and attribute or lid.PivotOffset
end

return CrateOpen
