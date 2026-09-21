-- Proves each admin power's real EFFECT, not just that the gate lets it through
-- (tools/admin_probe.lua already proves the gate exhaustively). Oliver, verbatim: "test the admin
-- menu powers in the playtest" -- this is the half a probe CAN reach; Fly's key-driven feel and
-- Event's live match-state change are his (see the notes at the bottom of this file).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/admin_powers_probe.lua
--
-- Calls AdminService.Actions[kind] directly -- the SAME handler the gate calls once isAdmin passes,
-- so this exercises the exact code path Oliver's own click runs, just skipping the remote hop edit
-- mode has no real Player to receive.
--
-- Stand-in player + stubs follow the project's established pattern (tools/monetization_probe.lua):
-- PlayerData.Save/CanSave/HasStore stubbed so nothing touches a real DataStore, StateSync stubbed so
-- a profile push doesn't try to fire a remote at a stand-in. Every section runs in its own pcall,
-- measurements read off real state and asserted individually.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Modules = ServerScriptService:WaitForChild("Modules")
local Shared = ReplicatedStorage:WaitForChild("Shared")

local AdminService = require(Modules:WaitForChild("AdminService"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local MatchEvents = require(Shared:WaitForChild("MatchEvents"))
local BattlePassData = require(Shared:WaitForChild("BattlePassData"))
local PlayerData = require(Modules:WaitForChild("PlayerData"))
local StateSync = require(Modules:WaitForChild("StateSync"))
local Monetization = require(Modules:WaitForChild("Monetization"))
local WeaponService = require(Modules:WaitForChild("WeaponService"))
local MatchService = require(Modules:WaitForChild("MatchService"))
local BattlePassService = require(Modules:WaitForChild("BattlePassService"))
local LootService = require(Modules:WaitForChild("LootService"))

StateSync.Push = function() end
StateSync.Notify = function() end
-- WeaponService.GiveWeapon calls WeaponService.Push(player) as its LAST step (through the table, not
-- a captured local -- confirmed by reading it -- so overwriting the table field here really does
-- redirect the call), and Push's only job is firing `loadoutChanged` at the player. For a stand-in
-- table (not a real Player) that FireClient throws "Unable to cast value to Object" -- which is what
-- was ACTUALLY behind the "displaced weapon vanishes" failure below, not LootService: the throw
-- happens INSIDE GiveWeapon, before it ever returns to AdminService's handler, so the drop-forward
-- code a few lines later in AdminService.lua never even ran. No slot state is written inside Push
-- itself (read it end to end: it only builds a client-facing view table), so stubbing it changes
-- nothing this probe measures.
WeaponService.Push = function() end
local saves = 0
PlayerData.Save = function()
	saves += 1
	return true
end
PlayerData.CanSave = function()
	return true
end
PlayerData.HasStore = function()
	return true
end
-- DropSlot's real path builds a full ground pickup (static gun model, pad, rarity ring) in a bare
-- probe scene with no built map around it. Not what THIS probe is proving -- it's proving
-- AdminService captures the displaced slot and forwards it, not that LootService can build a pickup
-- with no world around it (that's LootService's own concern, tested elsewhere). Stub it to just
-- RECORD the call, the same shape as PlayerData.Save above and monetization_probe.lua's established
-- pattern -- `require` caches the module, so this replaces the exact table AdminService's own
-- `modules().Loot` resolves to.
local dropCalls = {}
LootService.DropSlot = function(slot, position, from)
	table.insert(dropCalls, { slot = slot, position = position, from = from })
end

local failures, samples = 0, 0
local function out(fmt, ...)
	print("[BRR_Probe] " .. string.format(fmt, ...))
end
local function check(ok, fmt, ...)
	samples += 1
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
end
local function section(name, fn)
	local ok, err = pcall(fn)
	if not ok then
		failures += 1
		out("FAIL  section %s threw: %s", name, tostring(err))
	end
end
local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local out_ = {}
	for k, v in pairs(value) do
		out_[k] = deepCopy(v)
	end
	return out_
end

local admin = { UserId = AdminService.AdminUserId, Name = "ProbeAdmin", DisplayName = "ProbeAdmin" }
local data = PlayerData.Load(admin)
local Actions = AdminService.Actions

--------------------------------------------------------------------------------
-- WEAPON
--------------------------------------------------------------------------------

section("weapon: every id arrives with a full magazine and reserve", function()
	local tried, arrived, wrongAmmo = 0, 0, {}
	for id, def in pairs(WeaponData.Weapons) do
		tried += 1
		pcall(WeaponService.Reset, admin) -- fresh empty loadout each try
		pcall(Actions.Weapon, admin, id)
		local loadout = WeaponService.Get(admin)
		local found = nil
		for _, slot in pairs(loadout.slots) do
			if slot and slot.kind == "weapon" and slot.id == id then
				found = slot
				break
			end
		end
		if found then
			arrived += 1
			if found.mag ~= def.magSize or found.reserve ~= def.reserveAmmo then
				table.insert(wrongAmmo, id)
			end
		end
	end
	check(arrived == tried, "every weapon tried arrives in the loadout: %d/%d", arrived, tried)
	check(#wrongAmmo == 0, "every arrived weapon has a full magazine and reserve (%d wrong: %s)",
		#wrongAmmo, table.concat(wrongAmmo, ", "))
end)

section("weapon edge cases", function()
	-- Already holding it: asking twice adds a second copy (guns don't stack) rather than being
	-- refused or silently overwriting the first.
	pcall(WeaponService.Reset, admin)
	local anyId = next(WeaponData.Weapons)
	pcall(Actions.Weapon, admin, anyId)
	pcall(Actions.Weapon, admin, anyId)
	local loadout = WeaponService.Get(admin)
	local count = 0
	for _, slot in pairs(loadout.slots) do
		if slot and slot.kind == "weapon" and slot.id == anyId then
			count += 1
		end
	end
	check(count == 2, "asking for a weapon already held adds a second copy (%d in slots)", count)

	-- Full inventory: fill all 8 with distinct weapons, then ask for a 9th -- must swap the equipped
	-- slot rather than silently refusing.
	pcall(WeaponService.Reset, admin)
	local ids = {}
	for id in pairs(WeaponData.Weapons) do
		table.insert(ids, id)
		if #ids >= WeaponService.SlotCount then
			break
		end
	end
	for _, id in ipairs(ids) do
		pcall(WeaponService.GiveWeapon, admin, id)
	end
	local filledCount = 0
	for _, slot in pairs(WeaponService.Get(admin).slots) do
		if slot then
			filledCount += 1
		end
	end
	check(filledCount == WeaponService.SlotCount, "setup: all %d slots filled before the swap test (%d)",
		WeaponService.SlotCount, filledCount)
	local ninthId
	for id in pairs(WeaponData.Weapons) do
		local held = false
		for _, used in ipairs(ids) do
			if used == id then
				held = true
				break
			end
		end
		if not held then
			ninthId = id
			break
		end
	end
	-- What's about to be bumped out (the equipped slot, per GiveWeapon's own contract) -- so the drop
	-- check below knows which weapon id to look for on the ground, not just that SOMETHING dropped.
	local loadoutBefore = WeaponService.Get(admin)
	local displacedId = loadoutBefore.equipped and loadoutBefore.slots[loadoutBefore.equipped]
		and loadoutBefore.slots[loadoutBefore.equipped].id
	-- A real character this time: AdminService's swap-drop fix reads player.Character, which the
	-- stand-in doesn't have unless given one.
	admin.Character = admin.Character or Instance.new("Model")
	if not admin.Character:FindFirstChild("HumanoidRootPart") then
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.CFrame = CFrame.new(500, 50, 500) -- well clear of anything else on the stage
		root.Anchored = true
		root.Parent = admin.Character
	end
	local dropsBefore = #dropCalls
	local dropOk, dropErr = pcall(Actions.Weapon, admin, ninthId)
	if not dropOk then
		out("note  Actions.Weapon threw while dropping the displaced weapon: %s", tostring(dropErr))
	end
	local swappedIn = false
	for _, slot in pairs(WeaponService.Get(admin).slots) do
		if slot and slot.kind == "weapon" and slot.id == ninthId then
			swappedIn = true
		end
	end
	check(swappedIn, "a full inventory swaps the equipped slot for the new weapon (%s) instead of refusing it", tostring(ninthId))
	check(displacedId ~= nil, "setup: there was something in the equipped slot to displace (%s)", tostring(displacedId))
	local newDrop = dropCalls[#dropCalls]
	local droppedMatch = #dropCalls == dropsBefore + 1 and newDrop and newDrop.slot and newDrop.slot.id == displacedId
	check(droppedMatch, "the displaced weapon (%s) is forwarded to LootService.DropSlot instead of vanishing (%d -> %d drop calls, last id %s at %s)",
		tostring(displacedId), dropsBefore, #dropCalls, newDrop and tostring(newDrop.slot and newDrop.slot.id) or "none",
		newDrop and tostring(newDrop.position) or "?")

	-- No-ammo weapon: does one exist in the data at all?
	local noAmmoId
	for id, def in pairs(WeaponData.Weapons) do
		if (def.magSize or 0) == 0 or (def.reserveAmmo or 0) == 0 then
			noAmmoId = id
			break
		end
	end
	if noAmmoId then
		pcall(WeaponService.Reset, admin)
		pcall(Actions.Weapon, admin, noAmmoId)
		local found
		for _, slot in pairs(WeaponService.Get(admin).slots) do
			if slot and slot.kind == "weapon" and slot.id == noAmmoId then
				found = slot
			end
		end
		check(found ~= nil, "the one weapon with no ammo type (%s) still arrives", noAmmoId)
	else
		out("note  no weapon in WeaponData has a zero magSize/reserveAmmo -- this edge case does not exist in the data (not skipped, absent)")
	end
end)

--------------------------------------------------------------------------------
-- COINS
--------------------------------------------------------------------------------

section("coins: balance rises exactly, survives reload, refuses negative/NaN without side effect", function()
	data.SahurCoins = 0
	pcall(Actions.Coins, admin, 10000)
	check(data.SahurCoins == 10000, "asking for 10,000 raises the stored balance by exactly that (%d)", data.SahurCoins)
	pcall(Actions.Coins, admin, 100000)
	check(data.SahurCoins == 110000, "a second grant adds on top rather than replacing (%d)", data.SahurCoins)

	local reloaded = PlayerData.Reconcile(deepCopy(data))
	check(reloaded.SahurCoins == 110000, "balance survives a save/load round trip (%d)", reloaded.SahurCoins)

	local before = data.SahurCoins
	local resultNeg = Actions.Coins(admin, -500)
	local resultNaN = Actions.Coins(admin, 0 / 0)
	check(resultNeg == nil and resultNaN == nil, "negative and NaN requests are refused (return nil), not granted")
	check(data.SahurCoins == before, "the balance is unchanged after both refused requests (%d)", data.SahurCoins)
end)

--------------------------------------------------------------------------------
-- PASS
--------------------------------------------------------------------------------

section("pass: Owns() is true for every pass, and a REAL Owns() consumer actually opens", function()
	local total, owned = 0, 0
	for key in pairs(GamepassConfig.Passes) do
		total += 1
		pcall(Actions.Pass, admin, key)
		if Monetization.Owns(admin, key) then
			owned += 1
		end
	end
	check(owned == total, "granting every pass makes Monetization.Owns true for all of them: %d/%d", owned, total)

	-- The real consumer, not the flag: BattlePassService.ClaimTier refuses the premium track without
	-- BrainrotPassPremium (BattlePassService.lua ~98: "Premium track requires..."). Push enough XP to
	-- reach tier 1 through the real AddXp path, then claim premium for real.
	pcall(BattlePassService.AddXp, admin, 1000000)
	local reachedTier = BattlePassData.TierForXp(data.Pass.xp)
	check(reachedTier >= 1, "setup: AddXp pushed the profile past tier 1 (xp %d, tier %d)", data.Pass.xp, reachedTier)
	table.clear(data.Pass.claimedPremium)
	local ok, message = BattlePassService.ClaimTier(admin, 1, "premium")
	check(ok == true, "BattlePassService.ClaimTier(premium) -- a real Owns() consumer, not the flag itself -- now succeeds: %s",
		tostring(message))
end)

--------------------------------------------------------------------------------
-- EVENT -- see the note at the bottom of this file for what this section does NOT prove.
--------------------------------------------------------------------------------

section("event: ids are real, and a refusal reason is surfaced rather than swallowed", function()
	check(#MatchEvents.List > 0, "%d match events exist to offer", #MatchEvents.List)
	local realIds, missingEffects = 0, {}
	for _, event in ipairs(MatchEvents.List) do
		local got = MatchEvents.Get(event.id)
		if got == event then
			realIds += 1
		end
		-- speedMultiplier and startShield aren't turned by applyEventKnobs -- they're read straight
		-- off currentEvent at spawn time (MatchService.lua:349,432,715,1464-1465), so they belong in
		-- this list too. (First run of this probe missed them and flagged RotRush/ShieldUp as
		-- no-op events; they aren't -- the probe's knob list was incomplete, not the game.)
		local hasAnyEffect = event.bountyMultiplier or event.chestGuns or event.dropInterval
			or event.placementMultiplier or event.headshotMultiplier or event.stormSpeed
			or event.gravity or event.lighting or event.chestRarityFloor
			or event.speedMultiplier or event.startShield
		if not hasAnyEffect then
			table.insert(missingEffects, event.id)
		end
	end
	check(realIds == #MatchEvents.List, "every listed event resolves through MatchEvents.Get (%d/%d)", realIds, #MatchEvents.List)
	check(#missingEffects == 0, "every event turns at least one real knob (%d with none: %s)",
		#missingEffects, table.concat(missingEffects, ", "))

	-- No match is running in edit mode (MatchService's state is a private local with no exposed
	-- setter -- confirmed by reading the module, not guessed). AdminService's Event handler does NOT
	-- swallow that refusal: it returns a STRING with the reason rather than nil, so it still logs.
	local sample = MatchEvents.List[1]
	local resultDuringRefusal = Actions.Event(admin, sample.id)
	check(type(resultDuringRefusal) == "string" and resultDuringRefusal:find("REFUSED", 1, true) ~= nil,
		"with no match running, the handler reports the refusal reason instead of doing nothing silently: %s",
		tostring(resultDuringRefusal))
end)

out("done: %d failures, %d checks (%d stubbed saves)", failures, samples, saves)

--[[
NOT PROVEN HERE, and not faked:

- Event's SUCCESS path (the match's state actually changing, its objects existing) needs
  `MatchService`'s `state` local to be "InProgress", which has no exposed setter -- that file is
  owned by the Match flow tab, not this job. What IS proven above: every offered event id is real
  data with real effects, and a refusal is surfaced rather than swallowed. The success path needs
  either a MatchService test seam (their call) or Oliver's own playtest.
- Fly's FEEL (holding Space actually rises) needs a human: the runtest plugin sandbox refuses
  synthetic input (VirtualInputManager throws "lacking capability RobloxScript"). Its state machine
  is proven in admin_fly_probe.lua.
- The client-side gate that keeps a non-admin's client from ever wiring up Fly (or seeing the HUD at
  all) is a structural fact -- every bit of it lives inside AdminHud.client.lua's `build()`, which
  only runs after a real `AdminHello`, itself gated by the exhaustively-probed `isAdmin` -- not a
  dynamic one: LocalScripts don't execute under a headless server-side probe, and this harness has no
  second simulated client to prove it against at runtime.
]]
