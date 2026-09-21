-- Probe for tools/runtest.ps1 -Probe: PlayerData's session lock and forward compatibility, against a
-- stub DataStore with injected latency and failures, and TWO simulated servers.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/playerdata_probe.lua
--
-- Each "server" is the real PlayerData module source loaded again with its own job id, sharing one
-- stub store, so the two ends behave exactly as two Roblox servers would. The last case is a CONTROL:
-- the same server hop against the pre-lock behaviour, which must fail it. A test that passes on the old
-- code isn't testing the fix.
--
-- Nothing here touches a real DataStore: _SetStoreForTest refuses when one is available.

local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local modules = ServerScriptService:WaitForChild("Modules")
local source = modules:WaitForChild("PlayerData").Source

local failures, passes = 0, 0
local function expect(label, ok, detail)
	if ok then
		passes += 1
	else
		failures += 1
	end
	print(string.format("[PROBE] %s %s%s", ok and "PASS" or "FAIL", label, detail ~= nil and ("  (" .. tostring(detail) .. ")") or ""))
end

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value) do
		copy[key] = deepCopy(inner)
	end
	return copy
end

--------------------------------------------------------------------------------
-- Stub DataStore
--------------------------------------------------------------------------------

-- UpdateAsync is atomic on Roblox's side: the latency is the round trip, and the transform runs
-- against whatever is stored at that moment. `failNext` fails the next N calls, for outages.
local function newStore()
	local stub = { values = {}, latency = 0.05, failNext = 0, writes = 0, updates = 0 }
	function stub:GetAsync(key)
		task.wait(self.latency)
		return deepCopy(self.values[key])
	end
	function stub:UpdateAsync(key, transform)
		task.wait(self.latency)
		self.updates += 1
		if self.failNext > 0 then
			self.failNext -= 1
			error("stub store: DataStore is down")
		end
		local result = transform(deepCopy(self.values[key]))
		if result == nil then
			return deepCopy(self.values[key])
		end
		self.values[key] = deepCopy(result)
		self.writes += 1
		return deepCopy(result)
	end
	function stub:SetAsync(key, value)
		task.wait(self.latency)
		if self.failNext > 0 then
			self.failNext -= 1
			error("stub store: DataStore is down")
		end
		self.values[key] = deepCopy(value)
		self.writes += 1
	end
	return stub
end

local TIMINGS = { stale = 6, wait = 1.5, retry = 0.3 }

-- A server: its own copy of the module, its own job id, the shared stub.
local function newServer(jobId, stub)
	local module = loadstring(source, "PlayerData_" .. jobId)()
	module._SetStoreForTest(stub, jobId, TIMINGS)
	return module
end

-- The control: what this module did before locking — a plain read on load, a plain whole-value write on
-- save, no envelope, no lock, no version. Written out rather than patched out of the source, so it
-- can't silently fail to apply. It reuses the real Reconcile so only the storage behaviour differs.
local function oldServer(stub)
	local real = loadstring(source, "PlayerDataOldBase")()
	real._SetStoreForTest(stub, "old-" .. tostring(math.random(1, 1e6)), TIMINGS)
	local old = { held = {} }
	function old.Load(player)
		local saved = stub:GetAsync("user_" .. player.UserId)
		-- Reads a bare profile, and an envelope's profile, so the control works either way.
		local profile = type(saved) == "table" and saved.profile ~= nil and saved.profile or saved
		local data = real.Reconcile(profile)
		old.held[player.UserId] = data
		return data
	end
	function old.Save(player)
		stub:SetAsync("user_" .. player.UserId, old.held[player.UserId])
		return true
	end
	return old
end

local nextId = -8080000
local function fakePlayer(name)
	nextId -= 1
	local kicks = {}
	local player = { UserId = nextId, Name = name, DisplayName = name, Parent = game, kicks = kicks }
	function player:Kick(message)
		table.insert(kicks, message or "")
	end
	return player
end

--------------------------------------------------------------------------------
-- The cases
--------------------------------------------------------------------------------

do
	local stub = newStore()
	local A = newServer("serverA", stub)
	local B = newServer("serverB", stub)

	-- 1. A player hopping servers: B must not load while A still holds the profile.
	local player = fakePlayer("Hopper")
	local dataA = A.Load(player)
	dataA.SahurCoins = 1234
	expect("server A loaded and can save", A.CanSave(player))

	local dataB = B.Load(player)
	expect("server B is locked out while A holds the profile", #player.kicks == 1 and not B.CanSave(player) and dataB.SahurCoins == 0,
		#player.kicks .. " kicks")
	expect("the kick says it isn't their fault and what to do", string.find(player.kicks[1] or "", "rejoin", 1, true) ~= nil
		and string.find(player.kicks[1] or "", "Nothing is lost", 1, true) ~= nil, player.kicks[1])
	expect("the lockout is counted for the logs", B.LockedOutKicks == 1, B.LockedOutKicks)

	-- 2. After A releases, B loads A's latest state.
	A.Release(player)
	local dataB2 = B.Load(player)
	expect("after A releases, B loads and sees A's last write", B.CanSave(player) and dataB2.SahurCoins == 1234, dataB2.SahurCoins)

	-- 3. Saves for one player never overlap: the second is coalesced and the newest state wins.
	dataB2.SahurCoins = 10
	local firstDone = false
	task.spawn(function()
		B.Save(player)
		firstDone = true
	end)
	task.wait(0.01)
	dataB2.SahurCoins = 20
	B.Save(player)
	while not firstDone do
		task.wait(0.02)
	end
	task.wait(0.2)
	local stored = stub.values["user_" .. player.UserId]
	expect("two saves at once leave the newest state stored", stored and stored.profile and stored.profile.SahurCoins == 20,
		stored and stored.profile and stored.profile.SahurCoins)
	expect("the stored value is an envelope with a lock and a version", stored.v == 2 and stored.lock ~= nil and stored.version >= 1,
		HttpService:JSONEncode({ stored.v, stored.lock and stored.lock.jobId, stored.version }))
	B.Release(player)
end

do
	-- 4. A DataStore outage must never kick: the player gets a temporary profile, as before.
	local stub = newStore()
	stub.failNext = 99
	local A = newServer("serverOutage", stub)
	local player = fakePlayer("Outage")
	local data = A.Load(player)
	expect("an outage gives a temporary profile, no kick", #player.kicks == 0 and not A.CanSave(player) and type(data) == "table",
		#player.kicks .. " kicks")
	expect("an outage doesn't count as a lockout", A.LockedOutKicks == 0)
end

do
	-- 5. A lock left behind by a crashed server is taken over once it stops moving.
	local stub = newStore()
	local A = newServer("serverCrashed", stub)
	local B = newServer("serverNew", stub)
	local player = fakePlayer("Crashed")
	local dataA = A.Load(player)
	dataA.SahurCoins = 77
	A.Save(player)
	-- A vanishes without releasing. Its lock is only taken over once it has gone stale: a live server
	-- that simply hasn't saved lately must never be stolen from.
	task.wait(TIMINGS.stale + 0.2)
	local dataB = B.Load(player)
	expect("a lock nobody is refreshing is taken over", B.CanSave(player) and dataB.SahurCoins == 77 and #player.kicks == 0,
		dataB.SahurCoins .. ", " .. #player.kicks .. " kicks")
	B.Release(player)
end

do
	-- 6. A save that failed doesn't hand the profile over: the lock is still A's, and A recovers.
	local stub = newStore()
	local A = newServer("serverFailing", stub)
	local player = fakePlayer("FailedSave")
	local data = A.Load(player)
	data.SahurCoins = 500
	stub.failNext = 99
	local saved = A.Save(player)
	stub.failNext = 0
	expect("a failing save reports failure and keeps the session saveable", not saved and A.CanSave(player))
	expect("a later save recovers the same state", A.Save(player)
		and stub.values["user_" .. player.UserId].profile.SahurCoins == 500)
	A.Release(player)
end

do
	-- 7. Losing the lock stops this server writing at all, so it can't overwrite the new holder.
	local stub = newStore()
	local A = newServer("serverLoser", stub)
	local B = newServer("serverWinner", stub)
	local player = fakePlayer("Stolen")
	local dataA = A.Load(player)
	dataA.SahurCoins = 1
	A.Save(player)
	-- B takes over as if A had crashed (A stops refreshing while B waits it out).
	task.wait(TIMINGS.stale + 0.2)
	local dataB = B.Load(player)
	dataB.SahurCoins = 999
	B.Save(player)
	dataA.SahurCoins = 5
	local lateSave = A.Save(player)
	expect("the old server's late save is refused once the lock has moved", not lateSave and not A.CanSave(player))
	expect("the new holder's data is what's stored", stub.values["user_" .. player.UserId].profile.SahurCoins == 999,
		stub.values["user_" .. player.UserId].profile.SahurCoins)
	B.Release(player)
end

do
	-- 8. Rejoining the SAME server takes its own lock back without waiting or kicking.
	local stub = newStore()
	local A = newServer("serverSame", stub)
	local player = fakePlayer("Rejoiner")
	local data = A.Load(player)
	data.SahurCoins = 42
	A.Save(player)
	-- They drop out without a clean release (a timeout), then come back to the same server.
	local again = A.Load(player)
	expect("rejoining the same server takes its own lock straight back", A.CanSave(player) and again.SahurCoins == 42 and #player.kicks == 0,
		again.SahurCoins .. ", " .. #player.kicks .. " kicks")
	A.Release(player)
	expect("Release clears the lock so the next server never waits", stub.values["user_" .. player.UserId].lock == nil)
end

do
	-- 9. A profile saved before locking existed (a bare table) still loads, and is rewritten as an envelope.
	local stub = newStore()
	local A = newServer("serverLegacy", stub)
	local player = fakePlayer("Legacy")
	stub.values["user_" .. player.UserId] = { SahurCoins = 321, Brainrots = { "Trippi Troppi" }, FutureField = { keep = true } }
	local data = A.Load(player)
	expect("a pre-lock save loads", data.SahurCoins == 321 and #data.Brainrots == 1, data.SahurCoins)
	A.Save(player)
	local stored = stub.values["user_" .. player.UserId]
	expect("it is rewritten as an envelope, keeping unknown fields", stored.v == 2 and stored.profile.SahurCoins == 321
		and stored.profile.FutureField ~= nil and stored.profile.FutureField.keep == true)
	A.Release(player)
end

do
	-- 10. Shutdown: every profile is released in parallel, well inside the time Roblox allows.
	local stub = newStore()
	stub.latency = 0.2
	local A = newServer("serverClosing", stub)
	local players = {}
	for index = 1, 12 do
		local player = fakePlayer("Closing" .. index)
		table.insert(players, player)
		A.Load(player).SahurCoins = index
	end
	local started = os.clock()
	local released = A.ReleaseAll(players, 20)
	local took = os.clock() - started
	local allClear = true
	for _, player in ipairs(players) do
		local stored = stub.values["user_" .. player.UserId]
		if not stored or stored.lock ~= nil then
			allClear = false
		end
	end
	expect("shutdown releases every profile, in parallel, inside the budget", released == #players and allClear and took < 6,
		string.format("%d released in %.1fs", released, took))
end

do
	-- 11. Telling a brand-new profile apart from an existing one and from a failed load. Anything that
	-- hands out a one-time bonus (Beginner's Luck) has to trust this, so a failed load must never look new.
	local stub = newStore()
	local A = newServer("serverNew1", stub)
	local newcomer = fakePlayer("Newcomer")
	A.Load(newcomer)
	expect("a player with nothing stored reads as new", A.IsNewProfile(newcomer))
	A.Get(newcomer).SahurCoins = 10
	A.Release(newcomer)
	A.Load(newcomer)
	expect("the same player is not new the second time", not A.IsNewProfile(newcomer) and A.Get(newcomer).SahurCoins == 10)
	A.Release(newcomer)

	stub.failNext = 99
	local failed = fakePlayer("FailedLoad")
	A.Load(failed)
	expect("a failed load never reads as new", not A.IsNewProfile(failed) and not A.CanSave(failed))
	stub.failNext = 0

	local B = newServer("serverNew2", stub)
	local held = fakePlayer("HeldOut")
	A.Load(held)
	B.Load(held)
	expect("a player locked out of this server never reads as new there", not B.IsNewProfile(held))
	A.Release(held)
end

do
	-- 12. A trade must not run when either side's profile can't be written: the brainrots would move in
	-- memory and die with the session. This uses the REAL TradeService, so it drives the plugin's own
	-- PlayerData singleton (that's the copy TradeService required), with the stub store installed.
	local stub = newStore()
	local singleton = require(modules:WaitForChild("PlayerData"))
	singleton._SetStoreForTest(stub, "tradeServer", TIMINGS)
	local TradeService = require(modules:WaitForChild("TradeService"))
	local StateSync = require(modules:WaitForChild("StateSync"))
	StateSync.Push = function() end
	StateSync.Notify = function() end
	local saves = 0
	local realSave = singleton.Save
	singleton.Save = function(player)
		saves += 1
		return realSave(player)
	end

	local giver, taker = fakePlayer("TradeGiver"), fakePlayer("TradeTaker")
	singleton.Load(giver).Brainrots = { "Trippi Troppi" }
	-- The taker's load fails, so their profile can't be written: exactly the case that used to destroy
	-- the giver's brainrot.
	stub.failNext = 99
	singleton.Load(taker)
	stub.failNext = 0
	expect("the taker's profile can't save after a failed load", singleton.HasStore() and not singleton.CanSave(taker))

	local function runTrade(a, b, offer)
		a.Parent, b.Parent = game, game
		pcall(TradeService.Request, a, b)
		pcall(TradeService.Respond, b, true)
		a.Parent, b.Parent = nil, nil
		for _, name in ipairs(offer) do
			TradeService.Offer(a, name, true)
		end
		TradeService.Confirm(a, true)
		TradeService.Confirm(b, true)
	end
	saves = 0
	runTrade(giver, taker, { "Trippi Troppi" })
	expect("a trade with an unsaveable side is refused, and nothing moves",
		#singleton.Get(giver).Brainrots == 1 and #singleton.Get(taker).Brainrots == 0 and saves == 0,
		string.format("giver %d, taker %d, %d saves", #singleton.Get(giver).Brainrots, #singleton.Get(taker).Brainrots, saves))

	-- With both sides saveable the same trade goes through and both profiles are written.
	singleton.Load(taker)
	saves = 0
	runTrade(giver, taker, { "Trippi Troppi" })
	expect("the same trade works once both sides can save", #singleton.Get(giver).Brainrots == 0
		and #singleton.Get(taker).Brainrots == 1 and saves >= 2,
		string.format("giver %d, taker %d, %d saves", #singleton.Get(giver).Brainrots, #singleton.Get(taker).Brainrots, saves))
	singleton.Save = realSave
	singleton.Release(giver)
	singleton.Release(taker)
	-- Put the shared module back the way it was: anything running after this (the progression probe, in
	-- the merged run) expects the plugin's PlayerData to have no store, as it does in edit mode.
	singleton._SetStoreForTest(nil, "restored")
	expect("the shared PlayerData is left with no store, as the next probe expects", not singleton.HasStore())
end

do
	-- 13. Free and paid crate counts are each clamped to the crates actually held, and unknown tiers go.
	local stub = newStore()
	local A = newServer("serverCrates", stub)
	local player = fakePlayer("CrateCounts")
	stub.values["user_" .. player.UserId] = {
		Crates = { Rare = 2 },
		PaidCrates = { Rare = 5, NotACrate = 3 },
		FreeCrates = { Rare = 1.7, Epic = 4, Bogus = 2 },
	}
	local data = A.Load(player)
	expect("paid and free crate counts clamp to the crates held, and unknown tiers are dropped",
		data.PaidCrates.Rare == 2 and data.PaidCrates.NotACrate == nil
		and data.FreeCrates.Rare == 1 and data.FreeCrates.Epic == nil and data.FreeCrates.Bogus == nil,
		HttpService:JSONEncode({ data.PaidCrates, data.FreeCrates }))
	A.Release(player)
end

do
	-- 14. Leaving while an autosave is in flight: the release must still clear the lock and store the
	-- newest state, or the player is locked out of their next server until the lock goes stale.
	local stub = newStore()
	stub.latency = 0.35
	local A = newServer("serverLeaving", stub)
	local B = newServer("serverNext", stub)
	local player = fakePlayer("LeavingMidSave")
	local data = A.Load(player)
	data.SahurCoins = 100
	task.spawn(function()
		A.Save(player)
	end)
	task.wait(0.05)
	data.SahurCoins = 250
	A.Release(player)
	local stored = stub.values["user_" .. player.UserId]
	expect("releasing during a save still clears the lock and stores the newest state",
		stored ~= nil and stored.lock == nil and stored.profile.SahurCoins == 250,
		stored and string.format("lock %s, coins %s", tostring(stored.lock), tostring(stored.profile and stored.profile.SahurCoins)))
	local next = B.Load(player)
	expect("the next server loads them straight away, with no wait and no kick",
		B.CanSave(player) and next.SahurCoins == 250 and #player.kicks == 0, next.SahurCoins .. ", " .. #player.kicks .. " kicks")
	B.Release(player)
end

do
	-- 15. A save that failed, then the player hops. While A still holds the lock B is turned away; once
	-- the lock goes stale B takes over and gets A's last SUCCESSFUL write. The unsaved change is lost,
	-- which is the documented cost of a save that never landed — but nothing is duplicated, and no two
	-- servers ever hold the profile.
	local stub = newStore()
	local A = newServer("serverLostWrite", stub)
	local B = newServer("serverAfter", stub)
	local player = fakePlayer("FailedThenHopped")
	local data = A.Load(player)
	data.SahurCoins = 300
	expect("the first save lands", A.Save(player))
	data.SahurCoins = 900
	stub.failNext = 99
	expect("the second save fails on every attempt", not A.Save(player))
	stub.failNext = 0

	-- The retries with their backoff take longer than this probe's short stale window, so the lock's age
	-- is set explicitly rather than left to timing: first as a server that is alive and holding.
	local key = "user_" .. player.UserId
	stub.values[key].lock.at = os.time()
	B.Load(player)
	expect("the hop is refused while the failed server still holds the lock", not B.CanSave(player) and #player.kicks == 1,
		string.format("canSave %s, %d kicks", tostring(B.CanSave(player)), #player.kicks))

	-- Now as a server that is gone: the lock is older than the stale window.
	stub.values[key].lock.at = os.time() - (TIMINGS.stale + 60)
	local recovered = B.Load(player)
	expect("after the lock goes stale the new server takes over with the last saved state",
		B.CanSave(player) and recovered.SahurCoins == 300, recovered.SahurCoins)
	expect("the takeover was counted", B.StaleLockTakeovers >= 1, B.StaleLockTakeovers)
	B.Release(player)
end

do
	-- The control: the same hop, against the pre-lock behaviour, which must FAIL both ways.
	local stub = newStore()
	local A = oldServer(stub)
	local B = oldServer(stub)
	local player = fakePlayer("OldHopper")
	local dataA = A.Load(player)
	dataA.SahurCoins = 1234
	local dataB = B.Load(player)
	expect("CONTROL: the old code let a second server load the same profile, with no kick",
		#player.kicks == 0 and dataB ~= nil, #player.kicks .. " kicks")
	dataB.SahurCoins = 7
	B.Save(player)
	A.Save(player)
	local stored = stub.values["user_" .. player.UserId]
	local coins = stored and (stored.SahurCoins or (stored.profile and stored.profile.SahurCoins))
	expect("CONTROL: the old code let the stale server overwrite the newer save", coins == 1234, coins)
end

print(string.format("[PROBE] playerdata: %d passed, %d failed", passes, failures))
