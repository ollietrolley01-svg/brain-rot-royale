-- Does an ammo refill know when it gave nothing?
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/ammo_grant_probe.lua
--
-- The bug: `WeaponService.GiveAmmo` returned true for any live loadout, so VendorService's
-- "Nothing to reload." refusal (VendorService:105) could never fire, and a player holding no gun -- or
-- with every reserve already at the 2x cap -- paid 150 SahurCoins for nothing and was toasted success.
--
-- WHICH HALF THIS PROVES. Nothing in this harness can hold a loadout: `WeaponService.Reset` pushes to
-- the client and there is no Player object here (COORDINATION hard limit 3). So this proves the
-- DECISION -- `WeaponService.AmmoGrant`, the pure function GiveAmmo now asks -- for every case the
-- vendor can present. The WIRING (coins actually staying in the player's balance) is Oliver's
-- playtest: walk to a vendor with no gun, or with full reserves, and the purchase must refuse.
--
-- PLANTED FAULT: the same cases are run against a copy of the OLD arithmetic, which must report rounds
-- arriving in the capped case. If the old version passes these checks too, the checks are not testing
-- anything and the run says so.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local WeaponService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("WeaponService"))

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

local grant = WeaponService.AmmoGrant
if type(grant) ~= "function" then
	out("ERROR WeaponService.AmmoGrant is missing -- nothing below ran")
	return
end

-- A gun to test against, read from the data rather than named, so this survives a rename.
local gunId, gunDef
for id, def in pairs(WeaponData.Weapons) do
	if def.reserveAmmo and def.reserveAmmo > 0 and (not gunDef or id < gunId) then
		gunId, gunDef = id, def
	end
end
local reserve = gunDef.reserveAmmo
local cap = reserve * 2 -- AMMO_CAP_MULTIPLIER

-- The old arithmetic, kept here as the planted fault: it never reported how much it added.
local function oldGrant(slot, fraction)
	local def = slot and slot.kind == "weapon" and WeaponData.Get(slot.id)
	if not def then
		return 0
	end
	-- The old code assigned and returned nothing; "did it add?" was answered by "is there a loadout?",
	-- which is what this stands in for: any live weapon slot counted as a successful refill.
	return 1
end

local cases = {
	{ "empty reserve, half refill", { kind = "weapon", id = gunId, reserve = 0 }, 0.5, true },
	{ "already at the cap", { kind = "weapon", id = gunId, reserve = cap }, 1, false },
	{ "past the cap", { kind = "weapon", id = gunId, reserve = cap + 25 }, 1, false },
	{ "one round under the cap", { kind = "weapon", id = gunId, reserve = cap - 1 }, 1, true },
	{ "an item, not a gun", { kind = "item", id = "Bandage", reserve = 0 }, 1, false },
	{ "an empty slot", nil, 1, false },
}

local failures, caught = 0, 0
for _, case in ipairs(cases) do
	local label, slot, fraction, shouldGive = case[1], case[2], case[3], case[4]
	local added = grant(slot, fraction)
	local gave = added > 0
	local ok = gave == shouldGive
	if not ok then
		failures += 1
	end
	-- The planted fault: does the old arithmetic disagree here? If it never does, these cases are not
	-- testing the thing that was broken.
	local oldGave = oldGrant(slot, fraction) > 0
	if oldGave ~= shouldGive then
		caught += 1
	end
	out("%-28s grants %4d -> %-5s (want %-5s) %s%s", label, added, tostring(gave), tostring(shouldGive),
		ok and "ok" or "FAIL", (oldGave ~= shouldGive) and "   [old code got this wrong]" or "")
end

out("cap for %s is %d rounds (reserveAmmo %d x2)", gunId, cap, reserve)
out("%d of %d cases wrong; the old arithmetic was wrong on %d of them", failures, #cases, caught)
if caught == 0 then
	out("ERROR the planted old version passed every case -- these checks are not testing the bug")
end
out("done")
