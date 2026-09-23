-- Movement tuning: stamina, the slide, ledge climbing (mantle) and vaulting.
--
-- One table read by every side of it, so the numbers can never disagree:
--   * MatchService keeps the stamina ledger and the slide window on the server,
--   * Shared/Parkour finds ledges and obstacles and builds the path a climb or vault follows,
--   * StarterPlayerScripts/MovementClient runs the local player's moves and predicts stamina,
--   * HudClient draws the stamina bar,
--   * MovementService runs the same moves for bots on the server,
--   * tools/movement_probe.lua measures all of it in real physics.
--
-- Heights are in studs above the character's FEET (root height minus HipHeight minus half the root),
-- so a scaled avatar gets the same rules as a default one.

local MovementConfig = {}

--------------------------------------------------------------------------------
-- Stamina
--------------------------------------------------------------------------------

MovementConfig.Stamina = {
	Max = 100,
	-- Sprinting only drains while you're actually moving faster than this (studs/s, horizontal), so
	-- holding sprint against a wall or standing still costs nothing.
	MovingSpeed = 6,
	-- 100 stamina at 5.5 a second is 18.2 seconds of continuous sprinting, up from 11.1 at the old 9.
	-- Long enough to cross open ground and still be able to slide at the other end.
	SprintDrainPerSecond = 5.5,
	-- Regeneration waits this long after the last drain or cost, then refills at RegenPerSecond.
	RegenDelay = 0.8,
	RegenPerSecond = 25,
	-- Hitting zero exhausts you: sprint drops, and it can't start again until stamina is back to this.
	-- Exhausted, the refill also waits longer before it starts.
	ExhaustedUntil = 30,
	ExhaustedRegenDelay = 1.4,
	-- One-off costs.
	SlideCost = 18,
	VaultCost = 8,
	MantleCost = 12,
	-- A hop onto something no higher than this costs nothing.
	FreeMantleRise = 4.5,
	-- Stamina only matters in a match: in the lobby, the Cloud Climb and the firing range it is pinned
	-- full and you can sprint forever. That rule is MatchService's staminaApplies (and the client's
	-- stepStamina), not a number here — there used to be a LobbyDrains key in this table that nothing
	-- read, which is worse than no key at all.
}

--------------------------------------------------------------------------------
-- Slide
--------------------------------------------------------------------------------

-- A slide is entered from the CROUCH key while sprinting; it has no control of its own. It lowers the
-- body by exactly as much as a crouch does (Crouch.HipScale, applied by MatchService's one height rule),
-- so you can take one under a gap you couldn't walk through: measured at 4.6 studs and up, against 5.4
-- for a standing body.
MovementConfig.Slide = {
	-- The server's ceiling: while a slide is active, applySpeed multiplies walk speed by this.
	-- The client shapes the real speed underneath it (see MovementClient), so this is the fastest a
	-- slide can ever go, downhill included.
	PeakMultiplier = 1.75,
	-- The client's curve: the slide starts at StartMultiplier x the speed you were sprinting at and
	-- bleeds toward FloorSpeed at Friction per second (exponential), plus or minus the slope.
	StartMultiplier = 1.6,
	FloorSpeed = 14,
	Friction = 1.1,
	-- Downhill adds SlopeGain x gravity x sin(slope) per second; uphill takes the same away.
	SlopeGain = 0.55,
	-- It ends below EndSpeed, after MaxTime, or when you've been airborne longer than AirGrace.
	EndSpeed = 17,
	MaxTime = 1.1,
	AirGrace = 0.3,
	-- You need to be sprinting at this fraction of full sprint speed to start one.
	MinEntryFraction = 0.75,
	-- After a slide ends, the next can start this much later. The server enforces it (with the
	-- window below), the client predicts it.
	Cooldown = 0.6,
	-- How long the server keeps the slide factor on if the client never says it ended.
	ServerWindow = 1.3,
	-- A bot has no client to shape its slide, so it gets a flat burst at the ceiling for this long.
	BotWindow = 0.65,
	-- Steering: how fast A/D can turn a slide, degrees per second.
	TurnRate = 50,
	-- The camera drops this far, and the field of view widens by FovKick degrees.
	CameraDrop = 1.6,
	FovKick = 7,
}

--------------------------------------------------------------------------------
-- Crouch
--------------------------------------------------------------------------------

MovementConfig.Crouch = {
	-- A factor inside applySpeed, like everything else: 18 x 0.45 = 8.1 studs/s.
	SpeedMultiplier = 0.45,
	-- The body really goes down: HipHeight is scaled to this, which lowers the whole rig (the fold in the
	-- legs is drawn per client by Shared/CrouchAnimation). Measured against gaps and a hit-profile grid by
	-- tools/crouch_probe.lua.
	HipScale = 0.53,
	-- Never below this, whatever a scaled avatar's HipHeight is.
	MinHipHeight = 0.8,
	-- The camera and the gun follow the body down by this much (studs), eased, never snapped.
	CameraDrop = 1.0,
	GunDip = 0.25,
	-- How loud a crouched body's footsteps are, as a fraction of normal. Roblox's own character sounds do
	-- the stepping; every client turns the volume down on any body it can see crouching, so crouching is
	-- quiet for the people listening, not just for you. Not silent: crouch is cover, not invisibility.
	StepVolume = 0.35,
	-- Sprinting and crouching cancel each other; a slide settles into a crouch if the input is still held.
	-- After standing up, this long before a crouch can start again (stops a per-shot crouch flicker).
	Cooldown = 0.15,
	-- Crouched and barely moving, the gun is steadier: spread and recoil scale by these. The server
	-- owns the spread (CombatService.SpreadFor, which is what Fire shoots with); the camera kick is
	-- the shooter's own client, so it reads the same numbers from here rather than keeping a second
	-- copy of them. Both fade in over SteadyFade and out over the same, so a crouch tapped for the
	-- instant of a shot pays nothing, and standing up ends it at once with no trailing grace.
	-- "Barely moving" is SteadyMoveFraction of base walk speed: crouch-walking is 45% of base, above
	-- it, so this is for holding still rather than for holding the key.
	SteadySpread = 0.75,
	SteadyRecoil = 0.85,
	SteadyFade = 0.2,
	SteadyMoveFraction = 0.4,
}

--------------------------------------------------------------------------------
-- Air momentum
--------------------------------------------------------------------------------

-- Leaving the ground faster than you could run (a slide-jump, a Rot Rocket, a Launch Pad, a Blink
-- Bean) keeps that speed through the air instead of the humanoid's air control braking it to walking
-- pace in a fraction of a second. You can steer it, and pulling back slows it.
MovementConfig.AirMomentum = {
	-- Only kicks in when the horizontal speed at takeoff beats walk speed by this much.
	MinExcess = 3,
	-- Degrees per second the held momentum turns toward where you're pushing.
	TurnRate = 110,
	-- Studs/s lost per second when pushing against it, and fractional drag per second otherwise.
	Brake = 38,
	Drag = 0.06,
}

--------------------------------------------------------------------------------
-- Ledges and obstacles
--------------------------------------------------------------------------------

MovementConfig.Parkour = {
	-- A ledge needs at least this rise; anything lower you just walk or hop onto.
	MinRise = 1.6,
	-- How far in front of the body a wall can be and still be grabbed.
	Reach = 2.4,
	-- Hands overhead: the highest ledge above the feet you can get a grip on right now (jumping
	-- raises the feet, so a jump reaches higher).
	HandReach = 7.2,
	-- The design cap, measured from the last thing you stood on, so no chain of jumps and grabs gets
	-- further than one real climb. Set against town roofs with tools/roof_access_probe.lua.
	MaxRiseFromGround = 9.5,
	-- Vaulting: a thin obstacle (fence, rail, low wall, window sill) no higher than VaultMaxRise and no
	-- deeper than VaultMaxDepth, with somewhere to land within VaultMaxDrop below its top.
	VaultMinRise = 1.6,
	VaultMaxRise = 4.8,
	VaultMaxDepth = 3.2,
	VaultMaxDrop = 9,
	-- Room needed over the top to get through: a vault is a tucked dive, so a 5-stud window works.
	VaultClearance = 3.4,
	-- You have to be moving at least this fast (studs/s) toward it to vault; slower and it's a climb.
	VaultMinSpeed = 9,
	-- In the air within this much of the ground last stood on (a plain jump's apex is 6.4), a vault is
	-- measured from THAT ground rather than from the rising feet: a body that jumped at a sill meant to
	-- vault it, and measured from its feet the same sill read lower every frame until it vanished
	-- (tools/vault_jump_probe.lua). Beyond it (a Bounce Boots jump, a launch) the feet are the reference.
	JumpGrace = 6.5,
	-- A surface counts as a ledge top when its normal is at least this upright.
	TopNormal = 0.72,
	-- A wall counts as a wall when its normal is at most this upright.
	WallNormal = 0.4,
	-- Timings. A mantle's pull-up scales with the height it covers.
	MantleBaseTime = 0.16,
	MantlePerStud = 0.028,
	MantleMaxTime = 0.44,
	MantleOverTime = 0.17,
	-- A vault covers its path at the speed you arrived with, never slower than this.
	VaultMinPathSpeed = 17,
	-- Out of stamina, climbs still happen (you can't be trapped) but take this much longer.
	ExhaustedTimeScale = 1.6,
	-- After a climb or vault lands, a new one can't start for this long.
	Recovery = 0.25,
}

--------------------------------------------------------------------------------
-- Lean (#79)
--------------------------------------------------------------------------------

-- Leaning round cover in first person: the camera slides sideways and rolls a few degrees. Held on
-- the keyboard; on a phone the two buttons only exist while a scope is up (thumbs are busy otherwise).
-- The server fires from the head moved by the same clamped offset, so what you can see round a
-- corner is what you can hit, and the clamp below is what stops the shot starting inside a wall.
MovementConfig.Lean = {
	-- Studs sideways at a full lean, in the body's frame.
	Offset = 1.4,
	-- Degrees of camera roll at a full lean.
	Roll = 8,
	-- How quickly the lean follows the input (1/s, eased).
	Rate = 12,
	-- The swept sphere that finds the wall: the camera's near plane plus room, so the view never
	-- clips into a surface even at an angle to it.
	Radius = 0.3,
	-- Kept back from whatever the sphere touched, so a lean pressed flat to a wall shows the wall
	-- and not its inside.
	Margin = 0.1,
}

-- The one clamp both sides use. `wanted` is the signed lean in studs (positive = right); `cast` is
-- called with the signed reach to test and returns how far the sphere got before it touched
-- something (studs, unsigned), or nil if the way was clear. The result keeps the sign, never passes
-- Offset, and never passes the touch point less the margin, so the segment from the head to the
-- leaned eye is always clear: a shot can only start where a sphere could have moved to.
function MovementConfig.ClampLean(wanted, cast)
	local lean = MovementConfig.Lean
	if type(wanted) ~= "number" or wanted ~= wanted then
		return 0
	end
	wanted = math.clamp(wanted, -lean.Offset, lean.Offset)
	local size = math.abs(wanted)
	if size < 0.001 then
		return 0
	end
	local sign = wanted > 0 and 1 or -1
	local hit = cast(sign * (size + lean.Margin))
	if hit then
		size = math.clamp(hit - lean.Margin, 0, size)
	end
	return sign * size
end

return MovementConfig
