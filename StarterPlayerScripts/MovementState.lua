-- What the local player's movement is doing right now, shared between client scripts. ModuleScript,
-- so CombatClient (the sprint and slide binds, the viewmodel dip), HudClient (the stamina bar) and
-- MovementClient (which runs everything and writes these fields) all see one table.
--
-- MovementClient owns the writes. Other scripts read the fields and call the two requests:
--   MovementState.SetSprintHeld(held)  the sprint key's state; MovementClient decides the real sprint
--   MovementState.RequestSlide()       the slide key was pressed
-- and can listen to:
--   MovementState.ExhaustedChanged     (exhausted: boolean)
--   MovementState.SprintAllowedChanged (allowed: boolean) — CombatClient turns the sprint on or off

local MovementState = {
	-- Stamina as the client predicts it (corrected by the server's StaminaSync).
	stamina = 100,
	maxStamina = 100,
	exhausted = false,
	-- A Speed Soda's rush: nothing costs stamina.
	rush = false,
	-- Stamina is only in play during a match; outside one the bar is hidden.
	inMatch = false,
	-- True while sprinting is actually draining (for the HUD).
	draining = false,
	-- The sprint key is held.
	sprintHeld = false,
	-- The sprint is actually on (written by CombatClient's setSprinting).
	sprinting = false,
	-- Crouching right now, and whether the crouch input is held (a slide settles back into a crouch when
	-- it ends if it is). MovementClient owns both.
	crouching = false,
	crouchHeld = false,
	-- "slide" | "mantle" | "vault" | nil
	move = nil,
	-- 0..1: how far the view and the gun are dipped (slide, climb, vault). CombatClient hands it to the
	-- viewmodel as slideDip.
	dip = 0,
	-- os.clock() of the last slide or vault refused for want of stamina (the bar flashes).
	refusedAt = 0,
}

local exhaustedEvent = Instance.new("BindableEvent")
MovementState.ExhaustedChanged = exhaustedEvent.Event
local sprintAllowedEvent = Instance.new("BindableEvent")
MovementState.SprintAllowedChanged = sprintAllowedEvent.Event
local slideRequestEvent = Instance.new("BindableEvent")
MovementState.SlideRequested = slideRequestEvent.Event
-- Fired when a toggled (or held) sprint must not survive: respawn, death, sitting down (a vehicle), the
-- menu opening. CombatClient's sprint block clears the request and turns the sprint off.
local sprintOffEvent = Instance.new("BindableEvent")
MovementState.SprintOffRequested = sprintOffEvent.Event

-- MovementClient only.
function MovementState._RequestSprintOff()
	MovementState.sprintHeld = false
	sprintOffEvent:Fire()
end

function MovementState.SetSprintHeld(held)
	MovementState.sprintHeld = held == true
end

-- Whether a sprint may run right now (not exhausted).
function MovementState.CanSprint()
	return not MovementState.exhausted
end

function MovementState.RequestSlide()
	slideRequestEvent:Fire()
end

-- MovementClient only.
function MovementState._SetExhausted(value)
	value = value == true
	if MovementState.exhausted == value then
		return
	end
	MovementState.exhausted = value
	exhaustedEvent:Fire(value)
	sprintAllowedEvent:Fire(not value)
end

return MovementState
