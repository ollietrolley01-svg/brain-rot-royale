-- Per-player token buckets for the remote surface.
--
-- A RemoteEvent argument is whatever a modified client chooses to send, and so is how OFTEN it sends.
-- Every handler already validates its arguments; this bounds the rate, so a client firing a remote
-- every frame can't make the server rebuild gun models, push profile snapshots or run raycasts sixty
-- times a second for everyone else's expense.
--
--   RateLimit.Take(player, key) -> boolean
--     For calls that can simply be dropped (a shot, a reload, a click). False means over budget: the
--     handler returns without doing the work. Silently: a dropped call is never a kick, and the
--     budgets are far above what the game's own clients send.
--
--   RateLimit.Latest(player, key, value, apply)
--     For calls that SET A STATE (equip this slot, aiming on/off, ready, spectator focus, settings).
--     Over budget the NEWEST value is kept and applied once when a token frees, so the server ends in
--     the state the client last asked for. Dropping the last event of a weapon-wheel spin would leave
--     the held gun out of step with the client's own prediction, which is worse than being late.
--
-- Budgets live in one table below, with the legit peak each one is sized against, so tools/verify.py
-- can check that every client remote is either limited or on the Exempt list, and that the Fire
-- budget still clears the fastest gun in the game.
--
-- Buckets are keyed by player in a strong table and cleared on PlayerRemoving, together with any
-- pending Latest, so nothing applies after someone leaves. (Never a weak table keyed by an Instance:
-- entries for live players have been lost that way in this project before.)

local Players = game:GetService("Players")

local RateLimit = {}

-- burst: how many can arrive at once. rate: tokens refilled per second (the sustained ceiling).
RateLimit.Budgets = {
	-- Combat. The client self-limits to the weapon's fireRate; the fastest gun in any pack is 14/s,
	-- so this is a 1.4x margin over the fastest legitimate fire, with room for network bunching.
	Fire = { burst = 20, rate = 20, peak = "14/s, the fastest gun's fireRate" },
	RangeFire = { burst = 20, rate = 20, peak = "same as Fire, on the lobby range" },
	Reload = { burst = 5, rate = 4, peak = "key presses; auto-reload asks at most every 0.6s" },
	UseSelected = { burst = 10, rate = 6, peak = "clicks, the quick-movement key, uncooked throws" },
	Cook = { burst = 6, rate = 3, peak = "one per cooked throw" },
	DropSlot = { burst = 6, rate = 4, peak = "right-click on a hotbar cell" },
	-- Admin-only, and still limited: the gate decides WHO may ask, this decides how often. A held
	-- mouse button on a list of grant buttons shouldn't be able to flood the server, and the limit
	-- costs the admin nothing at a human tapping rate.
	AdminAction = { burst = 10, rate = 5, peak = "tapping down a list of admin grants" },
	CompanionAbility = { burst = 5, rate = 3, peak = "hotkey; the ability has its own cooldown" },
	Slide = { burst = 10, rate = 10, peak = "slide start/end; both gated by the slide cooldown" },
	Parkour = { burst = 10, rate = 10, peak = "vaults and mantles; MovementService allows one per 0.3s" },
	-- State setters (Latest).
	EquipSlot = { burst = 8, rate = 8, peak = "number keys and wheel/bumper spins; each switch rebuilds the held gun" },
	SetAiming = { burst = 10, rate = 10, peak = "aim toggles" },
	SetSprinting = { burst = 10, rate = 10, peak = "sprint toggles" },
	-- Its own budget rather than sprint's: crouch is a hold-or-toggle on a key that repeats.
	SetCrouching = { burst = 10, rate = 10, peak = "crouch toggles, including a held key repeating" },
	SetReady = { burst = 5, rate = 2, peak = "the lobby ready button" },
	SetReplicationFocus = { burst = 6, rate = 4, peak = "cycling spectator targets" },
	-- Take, not Latest: this is a door, not a state. A dropped press costs one more press, whereas
	-- a queued one would fire a respawn after the player had already given up and the match moved on.
	LeaveSpectate = { burst = 3, rate = 1, peak = "the LEAVE button on the spectator hud, pressed once" },
	ChooseDrop = { burst = 5, rate = 3, peak = "picking a landing spot on the drop map" },
	-- One request per player per match, plus a retry if the first lands in the moment between
	-- the window opening and the map existing. The answer is the largest payload any remote here
	-- sends -- 38.0 KB measured on SahurSprings (16384 class + 16384 height bytes, 309 road
	-- segments, a 51-point river) -- so this is deliberately tight.
	DropMap = { burst = 3, rate = 0.2, peak = "opening the drop picker at the start of a match" },
	SaveSettings = { burst = 5, rate = 1, peak = "the settings menu, already debounced client-side" },
	-- Menu calls. One shared bucket: each ends in a profile push and a leaderstats refresh, which is
	-- the cost being capped. A human clicking OPEN as fast as they can manages about 8 in a second.
	Menu = { burst = 15, rate = 5, peak = "menu buttons: buy, sell, open, merge, claim, equip, vote" },
	-- Trade invites, on top of the Menu bucket and the per-target cooldown in Bootstrap.
	TradeInvite = { burst = 3, rate = 0.2, peak = "inviting someone to trade" },
	-- Progression: these were behind ProgressionService's own 0.35s limiter, and one limiter is
	-- better than two. Each writes the profile, so they're sized for deliberate presses, not holds.
	Prestige = { burst = 3, rate = 0.5, peak = "a prestige is a once-in-a-while decision behind a confirm" },
	ClaimIndex = { burst = 8, rate = 3, peak = "claiming Rot Index rewards, several in a row" },
	BuyCellOffer = { burst = 6, rate = 2, peak = "buying from the Cell Shop" },
	-- #84: Oliver may still feel bumpiness once the road-joint fixes land, and the one remaining
	-- suspect (network ownership handoff) has no harness that can see it -- only a real driving
	-- client can. VehicleClient self-limits to about once a second already; this is the floor under
	-- that, not the real limiter.
	VehicleJolt = { burst = 6, rate = 1, peak = "one per genuine jolt while driving, client-detected" },
	-- A driver's client going through someone at speed (RoadkillPass): one per body, and a crowd is
	-- several at once. The server judges each against its own view (VehicleService.onRoadkillReport).
	VehicleRoadkill = { burst = 8, rate = 4, peak = "driving through a crowd, one per body" },
}

-- What an unknown budget falls back to. A remote asking for a key that doesn't exist is a wiring
-- mistake, not a reason to throw inside a remote handler and drop the call on the floor with an
-- error: it warns once per key and limits it sensibly meanwhile.
RateLimit.DefaultBudget = { burst = 10, rate = 5, peak = "fallback for an unknown budget" }

-- Remotes that are deliberately unlimited, and why. tools/verify.py checks this list covers every
-- client remote that isn't limited.
RateLimit.Exempt = {
	RequestProfile = "never refused: within a second of the last one it answers from the cached snapshot",
	GetSettings = "one waiting call per player; a second returns whatever has loaded by then",
}

-- The clock, as a field so tools/ratelimit_probe.lua can run a 30-second stream in an instant.
--
-- `tick` rather than `os.clock`, and the reason is INTENT, not a bug — said carefully, because the
-- obvious-sounding version of this comment turned out to be false when it was measured. Every
-- budget in the table above is written in wall-clock terms (`Fire` is sized as a margin over the
-- fastest gun's rounds per SECOND) and the refill below is `(now - bucket.at) * rate`, so the clock
-- this reads should be the wall clock by construction rather than by luck. `tick()` is that;
-- `os.clock()` is defined as CPU time and only happens to track the wall here.
--
-- MEASURED, in a runtest, over a real second spent yielding in `task.wait` (ratelimit_probe's clock
-- section prints this every run): `tick` advanced 1.017s over 1.013s of wall, ratio 1.004;
-- `os.clock` advanced 1.033s over 1.030s, ratio 1.003. THEY AGREE. So this change moves nothing
-- that anyone could feel, no shot was ever being dropped by it, and anybody reading this later
-- should not go looking for a fix that landed here. What it removes is the question.
RateLimit.Now = tick

-- [player] = { [key] = { tokens, at, pending, hasPending, thread } }
local buckets = {}

local warnedKeys = {}

local function bucketFor(player, key)
	local budget = RateLimit.Budgets[key]
	if not budget then
		if not warnedKeys[key] then
			warnedKeys[key] = true
			warn(string.format("[RateLimit] no budget named %s; using the fallback (burst %d, %g/s). Add one to RateLimit.Budgets.",
				tostring(key), RateLimit.DefaultBudget.burst, RateLimit.DefaultBudget.rate))
		end
		budget = RateLimit.DefaultBudget
	end
	local forPlayer = buckets[player]
	if not forPlayer then
		forPlayer = {}
		buckets[player] = forPlayer
	end
	local bucket = forPlayer[key]
	if not bucket then
		bucket = { tokens = budget.burst, at = RateLimit.Now() }
		forPlayer[key] = bucket
	end
	local now = RateLimit.Now()
	bucket.tokens = math.min(budget.burst, bucket.tokens + (now - bucket.at) * budget.rate)
	bucket.at = now
	return bucket, budget
end

function RateLimit.Take(player, key)
	local bucket = bucketFor(player, key)
	if bucket.tokens < 1 then
		return false
	end
	bucket.tokens -= 1
	return true
end

function RateLimit.Latest(player, key, value, apply)
	local bucket, budget = bucketFor(player, key)
	-- A pending value is always the newest one, and it always goes first: applying now while one waits
	-- would put an older value after a newer one.
	if bucket.tokens >= 1 and not bucket.thread then
		bucket.tokens -= 1
		apply(value)
		return true
	end
	bucket.pending = value
	bucket.hasPending = true
	if not bucket.thread then
		bucket.thread = task.delay(math.max(0, (1 - bucket.tokens) / budget.rate), function()
			bucket.thread = nil
			if not bucket.hasPending or not buckets[player] then
				return
			end
			-- Never apply anything for a player who has left.
			if typeof(player) == "Instance" and not player.Parent then
				return
			end
			local pending = bucket.pending
			bucket.hasPending, bucket.pending = false, nil
			local fresh = bucketFor(player, key)
			fresh.tokens = math.max(0, fresh.tokens - 1)
			apply(pending)
		end)
	end
	return false
end

-- Everything held for a player, including a pending Latest that hasn't fired yet.
function RateLimit.Clear(player)
	local forPlayer = buckets[player]
	if not forPlayer then
		return
	end
	for _, bucket in pairs(forPlayer) do
		if bucket.thread then
			task.cancel(bucket.thread)
			bucket.thread = nil
		end
		bucket.hasPending, bucket.pending = false, nil
	end
	buckets[player] = nil
end

Players.PlayerRemoving:Connect(RateLimit.Clear)

return RateLimit
