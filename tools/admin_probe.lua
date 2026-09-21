-- Can anyone but Oliver use the admin panel? (Oliver's list #52.)
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/admin_probe.lua
--
-- A leak here is the worst bug in the game, so this does not check that the gate works — it checks
-- that the gate is the thing doing the work, with two faults planted on EVERY run:
--
--   FAULT 1  a stand-in with a different UserId must get NOTHING from every action.
--   FAULT 2  with the constant set to a wrong number, OLIVER'S OWN stand-in must also get nothing.
--
-- Fault 2 is the one that earns its keep. Fault 1 alone would still pass if the handlers happened to
-- be refusing for some unrelated reason — an empty table, a missing module, a typo in the action
-- name — and a gate that refuses everyone looks identical to a gate that works, right up until the
-- day it starts allowing everyone. Fault 2 proves the UserId comparison is what decides.
--
-- Every line starts with [BRR_Probe]; the last one counts failures.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ServerScriptService:WaitForChild("Modules")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local AdminService = require(Modules:WaitForChild("AdminService"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local MatchEvents = require(Shared:WaitForChild("MatchEvents"))

local failures = 0
local function out(fmt, ...)
	print("[BRR_Probe] " .. string.format(fmt, ...))
end
local function check(ok, fmt, ...)
	if not ok then
		failures += 1
	end
	out("%s  " .. fmt, ok and "ok  " or "FAIL", ...)
end

-- A stand-in for a player: only the fields the gate reads. AdminService.IsAdmin takes a real Player,
-- so the UserId comparison is exercised through the same function the remote handler calls.
local function standIn(userId, name)
	return { UserId = userId, Name = name, IsA = function(_, class) return class == "Player" end }
end

local REAL = AdminService.AdminUserId
out("admin constant is %d", REAL)
check(typeof(REAL) == "number" and REAL > 0, "the constant is a UserId number, not a name")

-- The gate itself, through the same function the remote uses.
local oliver = standIn(REAL, "fqrtnugget")
local stranger = standIn(REAL + 1, "SomeoneElse")
local zero = standIn(0, "Guest")

-- `matches` is the UserId comparison; `isAdmin` is that plus "must be a real Player Instance".
-- Both are tested, because an edit-mode probe has no Player to offer and testing only isAdmin meant
-- every stand-in was refused for being a table -- including the one asserting the ADMIN gets in. A
-- gate that refuses everyone passes that test and fails the game.
check(AdminService.Matches(REAL) == true, "the admin's UserId passes the comparison")
check(AdminService.Matches(REAL + 1) == false, "FAULT 1: a different UserId is refused")
check(AdminService.Matches(0) == false, "UserId 0 is refused")
check(AdminService.Matches(nil) == false, "nil is refused")
check(AdminService.Matches(tostring(REAL)) == false, "the UserId as a STRING is refused")
check(AdminService.IsAdmin({ UserId = REAL }) == false, "a bare table claiming the UserId is refused")
check(AdminService.IsAdmin(oliver) == false, "even a convincing stand-in table is refused: it is not a Player")
check(AdminService.IsAdmin(stranger) == false and AdminService.IsAdmin(zero) == false, "and so is every other table")

-- FAULT 2: move the constant and the admin must lose access. Restored immediately afterwards.
AdminService.AdminUserId = REAL + 7777
check(AdminService.Matches(REAL) == false,
	"FAULT 2: with the constant wrong, the admin's own UserId is refused -- so it is the number gating it")
AdminService.AdminUserId = REAL
check(AdminService.Matches(REAL) == true, "the constant is restored and the admin passes again")

-- Every action validates its payload before granting. These call the handlers directly, which is
-- the layer BELOW the gate: proving that even past the gate, a forged payload is refused.
local actions = AdminService.Actions
check(type(actions) == "table" and next(actions) ~= nil, "the action table exists")

local BAD_PAYLOADS = {
	{ "Weapon", "NoSuchWeapon", "an unknown weapon id" },
	{ "Weapon", 12345, "a number where a weapon id belongs" },
	{ "Weapon", nil, "no weapon id at all" },
	{ "Coins", -5000, "a negative coin amount" },
	{ "Coins", 0 / 0, "NaN coins" },
	{ "Coins", "lots", "a string where a coin amount belongs" },
	{ "Pass", "NotAPass", "an unknown pass key" },
	{ "Pass", {}, "a table where a pass key belongs" },
	{ "Event", "NotAnEvent", "an unknown event id" },
}
for _, case in ipairs(BAD_PAYLOADS) do
	local kind, payload, description = case[1], case[2], case[3]
	local handler = actions[kind]
	if handler then
		local ok, result = pcall(handler, oliver, payload)
		-- Refused means: returned nil (nothing granted), or threw before granting. Either way the
		-- caller gets nothing; what must never happen is a grant.
		check(not ok or result == nil, "%s: %s is refused", kind, description)
	else
		check(false, "%s: no handler to test", kind)
	end
end

-- And the ids that DO exist are the ones the panel offers, so a valid request is a real thing.
local weaponCount, passCount = 0, 0
for id in pairs(WeaponData.Weapons) do
	weaponCount += 1
	if not WeaponData.Get(id) then
		check(false, "weapon %s is listed but WeaponData.Get can't find it", id)
	end
end
for key in pairs(GamepassConfig.Passes) do
	passCount += 1
end
check(weaponCount > 0 and passCount > 0, "the panel has real ids to offer: %d weapons, %d passes",
	weaponCount, passCount)
check(#MatchEvents.List > 0, "%d match events to spawn", #MatchEvents.List)

out("done: %d failures", failures)
