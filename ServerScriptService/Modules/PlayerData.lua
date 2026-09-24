-- Profile load/save. A profile that fails to load is flagged unsaveable for the rest of the
-- session, so a DataStore outage can't overwrite someone's real progress with defaults.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BrainrotData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("BrainrotData"))
local ProgressionData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProgressionData"))

local PlayerData = {}

local LOAD_ATTEMPTS = 3
local SAVE_ATTEMPTS = 3

-- GetDataStore itself throws on an unpublished place — guarding only Get/SetAsync is not
-- enough. An unguarded call here kills this module at load time, which takes down every
-- module that requires it and, through Bootstrap, the entire server.
local store = nil
do
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore("BrainRotRoyale_v1")
	end)
	if ok then
		store = result
	else
		warn("[PlayerData] DataStores unavailable: " .. tostring(result))
		warn("[PlayerData] The game will run normally, but nothing will save. To fix: publish the place, then Game Settings -> Security -> Enable Studio Access to API Services.")
	end
end

local sessions = {}
local failedLoads = {}
-- UserId -> the Player this server's session belongs to. A rejoin on the same server makes a NEW
-- Player for the same UserId while the previous one's Release (or an orphaned Load) may still be in
-- flight; without this tag that old work wiped the new session's tables and left the rejoined
-- player profileless - "Profile still loading." on every menu, no autosave, no final save - for
-- the rest of the session. Every path that writes, reads or clears a session checks it owns it.
local owners = {}

local function defaultData()
	return {
		SahurCoins = 0,
		Brainrots = {},
		Crates = {
			Common = 0, Uncommon = 0, Rare = 0, Epic = 0, Legendary = 0, Mythic = 0,
			Accessory = 0, Skin = 0, Aura = 0, Super = 0, Parachute = 0,
			-- The Style Crate tiers (2026-09-18). Additive: an older save simply has none of them.
			Style = 0, DeluxeStyle = 0, PrestigeStyle = 0,
		},
		-- `parachute` (the canopy worn on the drop-in and the Rot Glider) was added 2026-09-17; older
		-- saves have none and keep the default canopy. `killAnimation` (what plays on a body when
		-- this player gets the kill, #24) was added 2026-09-24; older saves have none and play nothing.
		Cosmetics = { owned = {}, gunSkin = nil, aura = nil, accessory = nil, parachute = nil, killAnimation = nil },
		Pass = { xp = 0, claimedFree = {}, claimedPremium = {} },
		Daily = { lastClaimDay = 0, streak = 0 },
		Stats = { wins = 0, kills = 0, matches = 0 },
		-- One-match boosts: Health/Speed from the shop and the Starter Bundle, the Pro pair
		-- (2x health, 1.5x speed) from the Pro Bundle.
		Consumables = { Health = 0, Speed = 0, HealthPro = 0, SpeedPro = 0 },
		-- Gamepass key -> os.time() it runs out, for passes won on the Daily Spin.
		TempPasses = {},
		Showcase = nil,
		Companion = nil,
		-- Rarity name -> true once that full set's one-time bonus has been paid.
		Collections = {},
		-- Keybinds, volumes and toggles from the Settings menu. Only ids the client knows are
		-- read back; this just stores what it sends, cleaned.
		Settings = { keys = {}, numbers = {}, toggles = {} },
		-- Product key -> how many times that Robux bundle has been bought.
		Bundles = {},
		-- Today's quest progress (QuestData): the day it belongs to, quest id -> count, quest id ->
		-- true once paid, and whether the all-done bonus crate has gone out.
		Quests = { day = 0, progress = {}, done = {}, bonus = false, week = 0, weekProgress = {}, weekDone = {} },
		-- Lifetime counters for achievements (AchievementData), the unlocked ones, and the title worn.
		Lifetime = {
			top10 = 0, chests = 0, items = 0, damage = 0, crates = 0, supply = 0, obby = 0, goals = 0,
			bounties = 0, questsDone = 0, sets = 0, landmarkChests = 0, builds = 0, barrels = 0, hazardKills = 0, vendor = 0,
			-- Progression titles (ProgressionService): prestige * 100 + rank, guns at Gold mastery or
			-- better, guns at Rotmaster, and brainrots in the Rot Index.
			rankScore = 0, mastered = 0, rotmasters = 0, discovered = 0,
		},
		Achievements = {},
		Title = nil,
		-- Crate tier -> opens since the last roll at or above that crate's pity rarity.
		Pity = {},
		-- Brainrot name -> companion XP (1 per point of damage it has dealt for you).
		CompanionXp = {},
		-- Brainrot name -> merge stars (BrainrotData.MaxStars at most).
		Stars = {},
		-- Rot Rank, Brain Cells, gun mastery, the Rot Index and the Cell Shop (Shared/ProgressionData).
		Progression = ProgressionData.Default(),
		PurchaseIds = {},
		-- Rarity -> { name, at }: the brainrot a player picked to buy with Robux, stored before the
		-- purchase prompt opens so the receipt grants exactly that one even after a disconnect
		-- (BrainrotShopService). Added 2026-09-17; older saves have none.
		PendingBrainrot = {},
		-- Crate tier -> how many of the crates in `Crates` were bought with Robux (a crate product or a
		-- bundle). Opening uses these up first and marks the pull as purchased, so the Rot Index records
		-- it without Brain Cells (ProgressionService.RecordPurchased). Added 2026-09-17; crates owned
		-- before then have no provenance and count as earned.
		PaidCrates = {},
		-- Crate tier -> how many of the crates in `Crates` the game handed out free (CrateService.Give).
		-- Stored the same way as PaidCrates so opening can tell a free crate from a bought or coin-bought one;
		-- what that changes is CrateData's business, not this module's. Added 2026-09-17.
		FreeCrates = {},
	}
end

-- Every top-level field this version of the game understands. Fields defaulted to nil (Showcase,
-- Companion, Title) aren't keys of defaultData(), so they're named here too.
local KNOWN_FIELDS = { Showcase = true, Companion = true, Title = true }
for field in pairs(defaultData()) do
	KNOWN_FIELDS[field] = true
end

local SETTINGS_LIMIT = 48

-- Settings come straight from the client, so keep only short identifier keys and plain values.
function PlayerData.SanitizeSettings(raw)
	local clean = { keys = {}, numbers = {}, toggles = {} }
	if type(raw) ~= "table" then
		return clean
	end

	local function copy(source, target, accept)
		if type(source) ~= "table" then
			return
		end
		local count = 0
		for id, value in pairs(source) do
			if type(id) == "string" and #id <= 32 and string.match(id, "^%a%w*$") and accept(value) then
				count += 1
				if count > SETTINGS_LIMIT then
					return
				end
				target[id] = value
			end
		end
	end

	copy(raw.keys, clean.keys, function(value)
		return type(value) == "string" and #value <= 24 and string.match(value, "^%a%w*$") ~= nil
	end)
	copy(raw.numbers, clean.numbers, function(value)
		return type(value) == "number" and value == value and math.abs(value) <= 1000
	end)
	copy(raw.toggles, clean.toggles, function(value)
		return type(value) == "boolean"
	end)
	return clean
end

local function copyNumbers(target, source)
	if type(source) ~= "table" then
		return
	end
	for key in pairs(target) do
		if type(source[key]) == "number" then
			target[key] = math.max(0, source[key])
		end
	end
end

local function copyBoolMap(target, source)
	if type(source) ~= "table" then
		return
	end
	for key, value in pairs(source) do
		if value == true and (type(key) == "string" or type(key) == "number") then
			target[key] = true
		end
	end
end

local function reconcile(saved)
	local data = defaultData()
	if type(saved) ~= "table" then
		return data
	end

	if type(saved.SahurCoins) == "number" then
		data.SahurCoins = math.max(0, saved.SahurCoins)
	end

	if type(saved.Brainrots) == "table" then
		for _, name in ipairs(saved.Brainrots) do
			if type(name) == "string" then
				table.insert(data.Brainrots, name)
			end
		end
	end

	copyNumbers(data.Crates, saved.Crates)
	copyNumbers(data.Stats, saved.Stats)
	copyNumbers(data.Consumables, saved.Consumables)

	if type(saved.Cosmetics) == "table" then
		copyBoolMap(data.Cosmetics.owned, saved.Cosmetics.owned)
		if type(saved.Cosmetics.gunSkin) == "string" then
			data.Cosmetics.gunSkin = saved.Cosmetics.gunSkin
		end
		if type(saved.Cosmetics.aura) == "string" then
			data.Cosmetics.aura = saved.Cosmetics.aura
		end
		if type(saved.Cosmetics.parachute) == "string" then
			data.Cosmetics.parachute = saved.Cosmetics.parachute
		end
		if type(saved.Cosmetics.accessory) == "string" then
			data.Cosmetics.accessory = saved.Cosmetics.accessory
		end
		if type(saved.Cosmetics.killAnimation) == "string" then
			data.Cosmetics.killAnimation = saved.Cosmetics.killAnimation
		end
	end

	if type(saved.Pass) == "table" then
		if type(saved.Pass.xp) == "number" then
			data.Pass.xp = math.max(0, saved.Pass.xp)
		end
		copyBoolMap(data.Pass.claimedFree, saved.Pass.claimedFree)
		copyBoolMap(data.Pass.claimedPremium, saved.Pass.claimedPremium)
	end

	if type(saved.Daily) == "table" then
		copyNumbers(data.Daily, saved.Daily)
	end

	if type(saved.Showcase) == "string" then
		data.Showcase = saved.Showcase
	end

	if type(saved.Companion) == "string" then
		data.Companion = saved.Companion
	end

	copyBoolMap(data.Collections, saved.Collections)
	data.Settings = PlayerData.SanitizeSettings(saved.Settings)

	if type(saved.Bundles) == "table" then
		for key, count in pairs(saved.Bundles) do
			if type(key) == "string" and type(count) == "number" then
				data.Bundles[key] = math.max(0, math.floor(count))
			end
		end
	end

	if type(saved.Quests) == "table" then
		if type(saved.Quests.day) == "number" then
			data.Quests.day = math.floor(saved.Quests.day)
		end
		if type(saved.Quests.progress) == "table" then
			for id, value in pairs(saved.Quests.progress) do
				if type(id) == "string" and type(value) == "number" then
					data.Quests.progress[id] = math.max(0, value)
				end
			end
		end
		copyBoolMap(data.Quests.done, saved.Quests.done)
		data.Quests.bonus = saved.Quests.bonus == true
		if type(saved.Quests.week) == "number" then
			data.Quests.week = math.floor(saved.Quests.week)
		end
		if type(saved.Quests.weekProgress) == "table" then
			for id, value in pairs(saved.Quests.weekProgress) do
				if type(id) == "string" and type(value) == "number" then
					data.Quests.weekProgress[id] = math.max(0, value)
				end
			end
		end
		copyBoolMap(data.Quests.weekDone, saved.Quests.weekDone)
	end

	copyNumbers(data.Lifetime, saved.Lifetime)
	copyBoolMap(data.Achievements, saved.Achievements)
	if type(saved.Title) == "string" then
		data.Title = saved.Title
	end
	for _, field in ipairs({ "Pity", "CompanionXp", "TempPasses" }) do
		if type(saved[field]) == "table" then
			for key, value in pairs(saved[field]) do
				if type(key) == "string" and type(value) == "number" then
					data[field][key] = math.max(0, value)
				end
			end
		end
	end

	-- Merge stars, added 2026-09-16. Saves from before then have no Stars and load with none.
	-- Only whole star counts from 1 to MaxStars are kept; anything else could only come from a
	-- bad write, and zero is the same as no entry.
	if type(saved.Stars) == "table" then
		for name, stars in pairs(saved.Stars) do
			if type(name) == "string" and type(stars) == "number" and stars == stars then
				local clean = BrainrotData.ClampStars(stars)
				if clean > 0 then
					data.Stars[name] = clean
				end
			end
		end
	end

	-- Progression, added 2026-09-17. Saves from before then have none and load with the default,
	-- whose version 0 makes ProgressionService backfill it once from the pass XP and brainrots the
	-- profile already holds. Reconcile keeps only clean, bounded values.
	data.Progression = ProgressionData.Reconcile(saved.Progression)

	if type(saved.PurchaseIds) == "table" then
		for _, id in ipairs(saved.PurchaseIds) do
			if type(id) == "string" then
				table.insert(data.PurchaseIds, id)
			end
		end
	end

	-- Only a known brainrot of the rarity it's filed under survives a load; anything else could only
	-- be a bad write, and dropping it just means the receipt falls back to a brainrot of that rarity.
	if type(saved.PendingBrainrot) == "table" then
		-- A rarity can hold more than one pick: a player who buys again before the first receipt is
		-- processed has both waiting, and both were paid for. They are stored oldest-first with the
		-- oldest in the slot's own fields and the rest in `more` (BrainrotShopService explains why),
		-- so every one of them has to survive a rejoin -- dropping `more` here would hand the later
		-- receipts a random brainrot each.
		local PENDING_LIMIT = 5
		local function cleanEntry(rarity, entry)
			if type(entry) ~= "table" or type(entry.name) ~= "string" then
				return nil
			end
			local def = BrainrotData.Get(entry.name)
			if not def or def.rarity ~= rarity then
				return nil
			end
			return {
				name = def.name,
				at = type(entry.at) == "number" and entry.at or 0,
				-- `paid` means its prompt reported a completed purchase; only ever true or absent.
				paid = entry.paid == true or nil,
			}
		end
		for rarity, pending in pairs(saved.PendingBrainrot) do
			if type(rarity) == "string" and type(pending) == "table" then
				-- Every pick this rarity holds, head and tail together, cleaned as one list. Cleaning
				-- the head on its own would have been wrong: a head naming a brainrot that no longer
				-- exists would have taken the paid picks behind it down with it, and those are the
				-- ones somebody is owed.
				local list = {}
				local function add(entry)
					local clean = cleanEntry(rarity, entry)
					-- Bounded on load as well as on write: a corrupt profile must not be able to hand
					-- a player an unbounded queue of free brainrots.
					if clean and #list < PENDING_LIMIT then
						table.insert(list, clean)
					end
				end
				add(pending)
				if type(pending.more) == "table" then
					for _, entry in ipairs(pending.more) do
						add(entry)
					end
				end
				if #list > 0 then
					local slot = list[1]
					if #list > 1 then
						slot.more = {}
						for index = 2, #list do
							table.insert(slot.more, list[index])
						end
					end
					data.PendingBrainrot[rarity] = slot
				end
			end
		end
	end

	-- Paid crates: whole counts for known crate tiers, never more than the crates actually held.
	if type(saved.PaidCrates) == "table" then
		for tier, count in pairs(saved.PaidCrates) do
			if type(tier) == "string" and data.Crates[tier] ~= nil and type(count) == "number" and count == count then
				local clean = math.clamp(math.floor(count), 0, data.Crates[tier])
				if clean > 0 then
					data.PaidCrates[tier] = clean
				end
			end
		end
	end

	-- Free crates: the same treatment. Paid and free are counted separately and never add up to more
	-- than the crates actually held, each on its own.
	if type(saved.FreeCrates) == "table" then
		for tier, count in pairs(saved.FreeCrates) do
			if type(tier) == "string" and data.Crates[tier] ~= nil and type(count) == "number" and count == count then
				local clean = math.clamp(math.floor(count), 0, data.Crates[tier])
				if clean > 0 then
					data.FreeCrates[tier] = clean
				end
			end
		end
	end

	-- Forward compatibility, added 2026-09-17. A top-level field this version doesn't know is carried
	-- through untouched instead of dropped. During a rolling update, a server still on older code can
	-- load and save a profile a newer server wrote; before this, that save silently deleted every newer
	-- field (a newer server then saw the profile as never having had them, and re-migrated it). Only
	-- whole unknown top-level fields are kept: a new key INSIDE a known table is still cleaned away, so
	-- new data belongs in its own top-level field. The value came out of the DataStore, so it can go
	-- back in as it is.
	for field, value in pairs(saved) do
		if type(field) == "string" and not KNOWN_FIELDS[field] and data[field] == nil then
			data[field] = value
		end
	end

	-- A showcase pointing at a brainrot the player does not own does not survive a load. Done here,
	-- after Brainrots is filled, because it is the only place that can heal a profile that ALREADY
	-- holds one: the sell paths stop new orphans, but every player who hit that bug before it was
	-- fixed still has a podium in the lobby showing a brainrot they sold, and it is in other people's
	-- showcase and trade lists too. `Companion` already self-heals this way in CompanionService's
	-- spawnFor; the showcase had nothing doing it.
	if data.Showcase and not table.find(data.Brainrots, data.Showcase) then
		data.Showcase = nil
	end

	return data
end

-- Read-only use by tools/merge_probe.lua, to check that saves from before a new field load
-- unchanged. Takes a saved table and returns a fresh profile; touches no session or store.
PlayerData.Reconcile = reconcile

--------------------------------------------------------------------------------
-- Session locking
--------------------------------------------------------------------------------
--
-- One server at a time may hold a profile. Without this, a player who leaves server A and joins
-- server B before A's save lands is loaded from a stale copy: whichever server saves last wins, and
-- coins, crates, Brain Cells and traded brainrots are duplicated or lost.
--
-- The key holds an envelope, written with UpdateAsync so read and write are one atomic step:
--   { v = 2, profile = <the table reconcile cleans>, lock = { jobId, at }, version = <counter> }
-- A value saved before this (a bare profile, no `profile` field) still loads, and is rewritten as an
-- envelope on the first save. `version` only ever goes up, so an older in-flight write can never land
-- on top of a newer one: the transform refuses and the save is reported as failed.
--
-- Taking the lock on join: if another job holds it and its `at` is fresh, wait and retry. If `at`
-- never moves while we wait, that server is gone (a crash, or a shutdown that couldn't release), so
-- the lock is taken over. If `at` does move, the holder is alive and the player is asked to rejoin
-- rather than being given a second live copy of their profile.
--
-- Write budget: every live session refreshes `at` on each save, and Bootstrap autosaves every 60 s.
-- At a full 50-player server that's about 50 writes a minute against a budget of 60 + 10 per player
-- (560), and each key is written once a minute against a 6 s per-key cooldown. Joins, leaves and
-- shutdown saves add a handful more.
--
-- A DataStore OUTAGE is never treated as a held lock: on errors the player keeps today's behaviour, a
-- temporary profile that doesn't save, and is never kicked.

local ENVELOPE_VERSION = 2
-- A lock this old is treated as abandoned. Comfortably more than two autosave intervals.
local LOCK_STALE_SECONDS = 150
-- How long a join waits for a live holder to release before giving up.
local LOCK_WAIT_SECONDS = 16
local LOCK_RETRY_SECONDS = 2

-- THE CLOCK EVERY DEADLINE IN THIS FILE IS WAITED OUT ON. tick(), never os.clock().
--
-- os.clock() is process CPU TIME in Roblox. Every wait below is a `task.wait` loop that YIELDS --
-- on a DataStore round trip, which is network latency, not computation -- so almost no CPU time
-- accrues while the wall clock runs. That makes the divergence largest here of anywhere in the
-- project, and this is the one place it costs a player their saved progress rather than a few
-- frames: `ReleaseAll` is called from BindToClose, whose ~30 seconds are WALL seconds Roblox will
-- not extend. A 20-CPU-second budget can outlast them with saves still in flight, and the process
-- is killed mid-write.
--
-- The units are the check: a tick() deadline is this machine's epoch (~1.7e9); an
-- `os.clock() + seconds` deadline is single digits since process start. Under an idle window the
-- two behave identically, so no timing test can separate them -- the magnitude always can.
-- Same reasoning and same clock as RateLimit.Now and VoteDropClient's reveal deadline.
local function wallNow()
	return tick()
end

-- Studio has no JobId; a per-run id keeps the two ends of a test apart. os.clock() is deliberate
-- and correct here: this is a unique suffix for a string, not a deadline, and nothing waits on it.
local JOB_ID = game.JobId ~= "" and game.JobId or ("studio-" .. tostring(os.clock()))
-- Set only by _SetStoreForTest.
local testMode = false

-- Per UserId: { data, version, saving, dirty, lost }.
local state = {}
-- How many players have been asked to rejoin because another server held their profile. A rising
-- count in the logs means locks aren't being released.
PlayerData.LockedOutKicks = 0
-- How many locks left behind by a server that never released have been taken over. Both counters only
-- go up in a live server; a rising one is a signal worth looking at.
PlayerData.StaleLockTakeovers = 0

local function keyFor(player)
	return "user_" .. player.UserId
end

-- The profile, its lock and its version out of whatever the key holds: an envelope, a bare profile
-- from before locking, or nothing at all.
local function unpackEnvelope(saved)
	if type(saved) ~= "table" then
		return nil, nil, 0
	end
	if saved.v == ENVELOPE_VERSION or saved.profile ~= nil or saved.lock ~= nil then
		return saved.profile, saved.lock, type(saved.version) == "number" and saved.version or 0
	end
	return saved, nil, 0
end

local function envelope(profile, version, holdLock)
	return {
		v = ENVELOPE_VERSION,
		profile = profile,
		lock = holdLock and { jobId = JOB_ID, at = os.time() } or nil,
		version = version,
	}
end

local function lockIsLive(lock)
	return lock ~= nil and lock.jobId ~= JOB_ID and (os.time() - (type(lock.at) == "number" and lock.at or 0)) < LOCK_STALE_SECONDS
end

-- One attempt at taking the lock. Returns "ok" with the stored profile and version, "held" with the
-- holder's `at` (nothing was written), or "error" with the message.
local function tryClaim(key)
	local held, heldAt, profileOut, versionOut, tookOver = false, 0, nil, 0, nil
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(saved)
			local profile, lock, version = unpackEnvelope(saved)
			if lockIsLive(lock) then
				held, heldAt = true, type(lock.at) == "number" and lock.at or 0
				-- Returning nil cancels the write, so a held profile is never touched.
				return nil
			end
			-- A lock from another job that has gone stale: that server is gone (a crash, or a shutdown
			-- that couldn't release). Worth naming in the log — a run of these means servers are dying
			-- without releasing, and every such join pays the wait first.
			if lock and lock.jobId ~= JOB_ID then
				tookOver = os.time() - (type(lock.at) == "number" and lock.at or 0)
			end
			profileOut, versionOut = profile, version
			return envelope(profile, version, true)
		end)
	end)
	if not ok then
		return "error", nil, 0, err
	end
	if held then
		return "held", nil, heldAt
	end
	return "ok", profileOut, versionOut, nil, tookOver
end

function PlayerData.Load(player)
	local key = keyFor(player)
	local saved, loaded, lockedOut = nil, false, false
	-- This session owns the UserId from here on. If the previous session on this server is still
	-- writing its release, let it finish (it clears state[] when done) rather than pulling its tables
	-- out from under it; bounded, so a stuck save cannot hold a join forever.
	-- The UserId is only handed over AFTER that wait: writeOnce refuses any write once owners[] names
	-- someone else, so claiming it first would make the previous session's release fail every retry
	-- and the new session would load a profile missing everything since the last autosave.
	local previous = state[player.UserId]
	if previous and previous.saving then
		local waitUntil = wallNow() + LOCK_WAIT_SECONDS
		while state[player.UserId] == previous and previous.saving and wallNow() < waitUntil do
			task.wait(0.1)
		end
	end
	owners[player.UserId] = player
	-- A fresh load starts clean: an earlier attempt for this user id (a failed load, or a lockout that
	-- asked them to rejoin) must not leave this session marked unsaveable for good.
	failedLoads[player.UserId] = nil
	state[player.UserId] = nil

	if store then
		local deadline = wallNow() + LOCK_WAIT_SECONDS
		local errors = 0
		while true do
			-- tryClaim already takes over a lock older than LOCK_STALE_SECONDS: a live server refreshes
			-- `at` on every autosave (60 s), so anything that old belongs to a server that is gone. It is
			-- NOT enough that the holder wrote nothing while we waited — a live server with nothing to
			-- save looks exactly the same, and stealing from it would give the player two live copies.
			local status, profile, version, err, tookOver = tryClaim(key)
			if owners[player.UserId] ~= player then
				-- A newer session for this UserId took over while we waited (the player left and rejoined
				-- this server): this load is an orphan. Hand back a throwaway profile and register
				-- nothing, so nothing of ours can touch the new session. A lock we may have just claimed
				-- is this server's own, which the new session's claim takes over.
				return reconcile(nil)
			end
			if status == "ok" then
				if tookOver then
					PlayerData.StaleLockTakeovers += 1
					warn(string.format("[PlayerData] Took over %s's profile, locked by a server that left %d s ago (%d so far)",
						player.Name, tookOver, PlayerData.StaleLockTakeovers))
				end
				saved, loaded = profile, true
				-- `isNew` only where the load worked and the key held nothing: a genuinely new player.
				state[player.UserId] = { version = version, saving = false, dirty = false, lost = false, isNew = profile == nil }
				break
			elseif status == "held" then
				if wallNow() >= deadline then
					-- Still held by a server that is refreshing it: ask the player to come back rather
					-- than open a second copy. A crashed holder is taken over once its lock goes stale.
					lockedOut = true
					break
				end
				task.wait(LOCK_RETRY_SECONDS)
			else
				-- An outage: never a lockout. Retry a few times, then fall through to a temporary profile.
				errors += 1
				warn(string.format("[PlayerData] Load %d failed for %s: %s", errors, player.Name, tostring(err)))
				if errors >= LOAD_ATTEMPTS then
					break
				end
				task.wait(math.min(3, 2 ^ errors))
			end
		end
	end

	if lockedOut then
		PlayerData.LockedOutKicks += 1
		warn(string.format("[PlayerData] %s is still open on another server; asked them to rejoin (%d so far)",
			player.Name, PlayerData.LockedOutKicks))
		state[player.UserId] = nil
		pcall(function()
			player:Kick("Your progress is still being saved on another server. Nothing is lost — rejoin in a few seconds.")
		end)
		-- A profile is still returned so anything already running has a table to read; it can't save.
		failedLoads[player.UserId] = true
		local data = reconcile(nil)
		sessions[player.UserId] = data
		return data
	end

	if not loaded then
		failedLoads[player.UserId] = true
		-- When there's no store at all we already said why at startup; don't repeat it per player.
		if store then
			warn("[PlayerData] " .. player.Name .. " is on a temporary profile; saving is off this session.")
		end
	end

	local data = reconcile(saved)
	sessions[player.UserId] = data
	return data
end

function PlayerData.Get(player)
	if owners[player.UserId] ~= player then
		return nil
	end
	return sessions[player.UserId]
end

-- True only for a player whose profile loaded successfully AND had nothing stored: their first time
-- playing. False for an existing save, false when the load failed or the DataStore is down, and false in
-- Studio, so nothing can be minted by forcing a failure. Read-only.
function PlayerData.IsNewProfile(player)
	local session = state[player.UserId]
	return session ~= nil and session.isNew == true
end

-- Whether this server has a DataStore at all (false in Studio and in an unpublished place). Read-only.
-- CanSave answers a different question — whether THIS player's profile may be written — and a live
-- server with a failed load must keep saying no there, which is why callers that only want to know
-- "is this a no-DataStore environment" ask here instead.
function PlayerData.HasStore()
	return store ~= nil
end

function PlayerData.CanSave(player)
	local session = state[player.UserId]
	return store ~= nil and owners[player.UserId] == player and sessions[player.UserId] ~= nil
		and not failedLoads[player.UserId] and session ~= nil and not session.lost
end

-- One write. Returns true on success; false means the write failed, and `lost` says the lock is gone
-- (another server has the profile), which ends saving for this session.
local function writeOnce(player, releaseLock)
	local session = state[player.UserId]
	local data = sessions[player.UserId]
	if not session or not data or owners[player.UserId] ~= player then
		return false, false
	end

	local lost, newVersion = false, nil
	local ok, err = pcall(function()
		store:UpdateAsync(keyFor(player), function(saved)
			local profile, lock, version = unpackEnvelope(saved)
			if lockIsLive(lock) then
				lost = true
				return nil
			end
			if version > session.version then
				-- Someone else wrote while we held it: our copy is no longer the newest.
				lost = true
				return nil
			end
			newVersion = version + 1
			return envelope(data, newVersion, not releaseLock)
		end)
	end)

	if ok and not lost then
		session.version = newVersion or session.version
		return true, false
	end
	if lost then
		session.lost = true
		warn(string.format("[PlayerData] Lost the session lock for %s; this server stopped saving their profile", player.Name))
		return false, true
	end
	warn(string.format("[PlayerData] Save failed for %s: %s", player.Name, tostring(err)))
	return false, false
end

-- Saves the live table. Only one save per player runs at a time: a save asked for while one is in
-- flight sets a flag and the running save goes round again, so writes can never cross and the last
-- write always carries the newest state.
local function saveInternal(player, releaseLock)
	if not PlayerData.CanSave(player) then
		return false
	end
	local session = state[player.UserId]
	if session.saving then
		-- A save is already running; it will go round again with the newest state. A RELEASE can't be
		-- coalesced like that, though — it has to clear the lock — so it waits for the running save
		-- below instead of returning here.
		if not releaseLock then
			session.dirty = true
			return true
		end
		-- Long enough to cover a save that is mid-retry (three attempts with a capped backoff), and still
		-- well inside the per-player share of BindToClose's ~30 s.
		local deadline = wallNow() + 8
		while session.saving and wallNow() < deadline do
			task.wait(0.1)
		end
		if session.saving then
			warn(string.format("[PlayerData] %s's save is still running at release; the lock will clear when it goes stale", player.Name))
			return false
		end
	end

	session.saving = true
	local success = false
	repeat
		session.dirty = false
		for attempt = 1, SAVE_ATTEMPTS do
			local ok, lost = writeOnce(player, releaseLock)
			success = ok
			if ok or lost then
				break
			end
			-- Capped backoff: an uncapped 2^attempt reaches 16s on the last try.
			task.wait(math.min(3, 2 ^ attempt))
		end
	until not session.dirty or not success
	session.saving = false
	return success
end

function PlayerData.Save(player)
	return saveInternal(player, false)
end

-- A save whose true means written. PlayerData.Save coalesces into a save already in flight and
-- answers true at once, which is fine for autosaves but not for a Robux receipt: PurchaseGranted
-- must only go back once the grant is really in the store. So wait out the running save, then write.
function PlayerData.SaveAndWait(player)
	local session = state[player.UserId]
	if session and session.saving then
		local deadline = wallNow() + 15
		while session.saving and wallNow() < deadline do
			task.wait(0.1)
		end
		if session.saving then
			return false
		end
	end
	return saveInternal(player, false)
end

function PlayerData.Release(player)
	if owners[player.UserId] ~= player then return end -- a superseded session's release touches nothing
	-- The final write clears the lock in the same operation, so the next server can load at once. If an
	-- autosave is in flight, saveInternal waits for it rather than coalescing: a coalesced release would
	-- leave the lock held until it went stale, and the player would be turned away from their next
	-- server for up to LOCK_STALE_SECONDS.
	saveInternal(player, true)
	-- Checked again: the save above yields, and a rejoin during it hands the UserId to a new session
	-- whose tables these now are.
	if owners[player.UserId] ~= player then return end -- superseded during the final save
	sessions[player.UserId] = nil
	failedLoads[player.UserId] = nil
	state[player.UserId] = nil
	owners[player.UserId] = nil
end

-- Every player at once, for BindToClose, which Roblox gives about 30 seconds. Returns how many were
-- released before the deadline.
function PlayerData.ReleaseAll(players, timeout)
	local remaining = 0
	local done = 0
	for _, player in ipairs(players) do
		remaining += 1
		task.spawn(function()
			PlayerData.Release(player)
			done += 1
		end)
	end
	local deadline = wallNow() + (timeout or 20)
	while done < remaining and wallNow() < deadline do
		task.wait(0.2)
	end
	return done
end

-- Probe-only seam (tools/playerdata_probe.lua): swaps in a stub store and a job id. It refuses when
-- real DataStores are available, so it can only ever run in Studio or the harness, never in a live
-- server. Game code never calls it.
function PlayerData._SetStoreForTest(testStore, jobId, timings)
	if store ~= nil and not testMode then
		error("[PlayerData] _SetStoreForTest refused: DataStores are available, so this is a live server.")
	end
	testMode = true
	store = testStore
	JOB_ID = jobId or JOB_ID
	-- A probe can't sit through the real waits; the behaviour under test is the same.
	if timings then
		LOCK_STALE_SECONDS = timings.stale or LOCK_STALE_SECONDS
		LOCK_WAIT_SECONDS = timings.wait or LOCK_WAIT_SECONDS
		LOCK_RETRY_SECONDS = timings.retry or LOCK_RETRY_SECONDS
	end
	table.clear(sessions)
	table.clear(failedLoads)
	table.clear(state)
	table.clear(owners)
	PlayerData.LockedOutKicks = 0
	PlayerData.StaleLockTakeovers = 0
	return JOB_ID
end

return PlayerData
