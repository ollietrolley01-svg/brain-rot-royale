-- The admin panel's server half (Oliver's list #52).
--
-- Oliver: "make an admin hud menu that only appears for me, fqrtnugget. which can give me any
-- weapon get infinite money, get every gamepass for free, fly spawn events, etc. make sure only i
-- can see it and no other potential players."
--
-- THE WHOLE SECURITY MODEL IS HERE, and it is short on purpose:
--
--   1. ONE constant, one comparison. `ADMIN_USER_ID` is a UserId, never a display name — a name can
--      be released and bought by somebody else, and the panel would follow the name to them.
--   2. Every grant runs HERE. The client asks; this decides. A client-side check is decoration: a
--      player running a modified client simply skips it, so the gate has to be on the side the
--      player cannot edit.
--   3. Nothing from the client is believed. A weapon id is looked up in WeaponData, a pass key in
--      GamepassConfig, an event id in MatchEvents, and a coin amount is clamped. A forged request
--      for weapon "DoesNotExist" or 10^12 coins is refused, not honoured.
--   4. A refusal is SILENT and has no side effect. No error back, nothing different to measure, so
--      the remotes cannot be used to work out who is admin or whether an id exists.
--   5. Every action is logged with who, what and when, so no grant is invisible.
--
-- The panel itself is built on the client only after `AdminHello` arrives, and this only ever fires
-- it at the admin. For every other player the menu is not hidden, it is never created.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local WeaponData = require(Shared:WaitForChild("WeaponData"))
local GamepassConfig = require(Shared:WaitForChild("GamepassConfig"))
local MatchEvents = require(Shared:WaitForChild("MatchEvents"))
local CrateData = require(Shared:WaitForChild("CrateData"))

local Modules = ServerScriptService:WaitForChild("Modules")
local RateLimit = require(Modules:WaitForChild("RateLimit"))

local AdminService = {}

-- Oliver (fqrtnugget). The one number. Changing it is the only way to change who is admin, and the
-- probe's second planted fault checks that a WRONG number leaves Oliver with nothing — so a typo
-- here fails CLOSED (nobody is admin) rather than open (a stranger is).
AdminService.AdminUserId = 53193685

-- Coins are "infinite" in the sense that he can ask again; each grant is bounded so a malformed or
-- hostile amount cannot overflow the currency or a save.
local MAX_COINS_PER_GRANT = 1000000

local hello = Remotes.Event("AdminHello")
local action = Remotes.Event("AdminAction")

-- Split in two on purpose, and the reason is a test that could not fail.
--
-- `isAdmin` must demand a real Player Instance, so a forged table carrying the right UserId is
-- refused — that is the check that matters against a hostile client. But a probe in edit mode has
-- no Players to hand, so it could only ever feed it a table, which is always refused: every
-- assertion passed, including the one asserting the ADMIN gets in, and "refuses everyone" read
-- exactly like "works". The probe caught it only because it asserts the positive case too.
--
-- So the UserId comparison lives in `matches`, which a probe can call with a number, and `isAdmin`
-- is that plus the Instance requirement. Both are exercised: matches for who, isAdmin for what kind
-- of thing is asking.
local function matches(userId)
	return typeof(userId) == "number" and userId == AdminService.AdminUserId
end
AdminService.Matches = matches

local function isAdmin(player)
	return typeof(player) == "Instance" and player:IsA("Player") and matches(player.UserId)
end
AdminService.IsAdmin = isAdmin

local function log(player, what, detail)
	print(string.format("[Admin] %s (%d) %s%s", player.Name, player.UserId, what,
		detail and (" " .. detail) or ""))
end

-- Required lazily so this module can be required by a probe without dragging in the world.
local function modules()
	return {
		Weapon = require(Modules:WaitForChild("WeaponService")),
		Monetization = require(Modules:WaitForChild("Monetization")),
		PlayerData = require(Modules:WaitForChild("PlayerData")),
		Match = require(Modules:WaitForChild("MatchService")),
		Loot = require(Modules:WaitForChild("LootService")),
		Crate = require(Modules:WaitForChild("CrateService")),
		StateSync = require(Modules:WaitForChild("StateSync")),
	}
end

local godWatched = {}

-- Each handler returns a short string for the log, or nil if it did nothing. None of them trusts
-- its argument: every one is a lookup in a real table before anything is granted.
local HANDLERS = {
	Weapon = function(player, payload)
		local id = typeof(payload) == "string" and payload or nil
		-- WeaponData.Get is the accessor; GiveWeapon validates again on its own side and refuses
		-- when the player isn't in a match, so a forged id is rejected twice and silently.
		local def = id and WeaponData.Get(id)
		if not def then
			return nil
		end
		-- A full inventory swaps the equipped slot rather than refusing (WeaponService.GiveWeapon's
		-- own contract, shared with the normal ground-pickup path). Loot pickup never deletes what it
		-- replaces (LootService.lua ~257-265: "puts whatever was held down... instead of deleting
		-- it") -- an admin grant shouldn't either, since Oliver will use this while holding something
		-- he cares about. Drop it at his own feet the same way a pickup would.
		local _, _, replaced = modules().Weapon.GiveWeapon(player, id)
		if replaced then
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root then
				modules().Loot.DropSlot(replaced, root.Position)
			end
		end
		return "weapon " .. id
	end,

	Coins = function(player, payload)
		local amount = tonumber(payload)
		if not amount or amount ~= amount or amount <= 0 then
			return nil
		end
		amount = math.min(math.floor(amount), MAX_COINS_PER_GRANT)
		modules().Monetization.EarnCoins(player, amount, "admin")
		return "coins " .. amount
	end,

	Pass = function(player, payload)
		local key = typeof(payload) == "string" and payload or nil
		if not key or not GamepassConfig.Passes[key] then
			return nil
		end
		local data = modules().PlayerData.Get(player)
		if not data then
			return nil
		end
		data.TempPasses = data.TempPasses or {}
		-- A long grant rather than a forever one: it goes through the same TempPasses path the
		-- battle pass already uses, so nothing new has to be trusted by the code that reads passes.
		data.TempPasses[key] = os.time() + 365 * 24 * 3600
		modules().Monetization.Refresh(player)
		return "pass " .. key
	end,

	Event = function(player, payload)
		local id = typeof(payload) == "string" and payload or nil
		local event = id and MatchEvents.Get(id)
		if not event then
			return nil
		end
		local Match = modules().Match
		if typeof(Match.SetEvent) ~= "function" then
			-- MatchService has no admin entry point; refused rather than reached into, so this never
			-- writes another module's state behind its back.
			return nil
		end
		-- SetEvent answers true, or false and a reason ("No match running.", "No such event.", "That
		-- event can't run in this mode."). The reason is logged rather than dropped: a button that
		-- silently does nothing is the thing this panel is least allowed to be.
		local ok, reason = Match.SetEvent(id)
		if not ok then
			return "event " .. id .. " REFUSED: " .. tostring(reason)
		end
		return "event " .. id
	end,

	-- Any crate in CrateData, one at a time (Oliver, 2026-09-22: "add all crates to the admin menu").
	-- The tier is looked up in CrateData like every other id here, and handed over through
	-- CrateService.Give, the same path placements and quests use.
	Crate = function(player, payload)
		local tier = typeof(payload) == "string" and payload or nil
		if not tier or not CrateData.Get(tier) then
			return nil
		end
		local m = modules()
		if not m.Crate.Give(player, tier, 1) then
			return nil
		end
		pcall(m.StateSync.Push, player)
		return "crate " .. tier
	end,

	-- God mode (Oliver, 2026-09-22). An invisible ForceField on the character: Humanoid:TakeDamage does
	-- nothing while one is present, and every damage path in the game goes through TakeDamage
	-- (CombatService.DealDamage for guns, blasts, companions and hazards; StormService for the storm).
	-- The `AdminGod` attribute carries it across respawns until it's switched off.
	God = function(player, payload)
		local on = payload == true
		player:SetAttribute("AdminGod", on or nil)
		local function apply(character)
			if not character then
				return
			end
			local existing = character:FindFirstChild("AdminGod")
			if player:GetAttribute("AdminGod") then
				if not existing then
					local field = Instance.new("ForceField")
					field.Name = "AdminGod"
					field.Visible = false
					field.Parent = character
				end
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					humanoid.Health = humanoid.MaxHealth
				end
			elseif existing then
				existing:Destroy()
			end
		end
		apply(player.Character)
		if not godWatched[player] then
			godWatched[player] = true
			player.CharacterAdded:Connect(function(character)
				character:WaitForChild("Humanoid", 5)
				apply(character)
			end)
		end
		return "god " .. tostring(on)
	end,

	Fly = function(player, payload)
		local on = payload == true
		-- The attribute is the contract with the movement tab: MovementSanity would otherwise read
		-- flight as a speed hack and act on it. Set server-side so the client cannot award itself
		-- the exemption; claude-af [0bccf5] honours it in the sanity check.
		player:SetAttribute("AdminFly", on or nil)
		return "fly " .. tostring(on)
	end,
}

action.OnServerEvent:Connect(function(player, kind, payload)
	-- The gate. Everything below it has already proved who is asking.
	if not isAdmin(player) then
		return
	end
	-- Rate-limited even for the admin: the gate says who may ask, this says how often, so a stuck
	-- button cannot flood the server.
	if not RateLimit.Take(player, "AdminAction") then
		return
	end
	local handler = typeof(kind) == "string" and HANDLERS[kind]
	if not handler then
		return
	end
	local ok, detail = pcall(handler, player, payload)
	if not ok then
		log(player, "FAILED " .. kind, tostring(detail))
		return
	end
	if detail then
		log(player, "granted", detail)
	end
end)

-- The client is TOLD it is admin; it never asks. Nothing answers a "am I admin?" question, so there
-- is no remote a normal player can call to find out, and no timing difference to measure.
local function greet(player)
	if isAdmin(player) then
		hello:FireClient(player)
		log(player, "panel enabled")
	end
end

Players.PlayerAdded:Connect(greet)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(greet, player)
end

-- Flight does not outlive the session it was granted in. The attribute would vanish with the Player
-- Instance anyway, but clearing it explicitly means nothing that cached a reference to this Player
-- (a probe, another system) can read a stale "still flying" after this fires.
Players.PlayerRemoving:Connect(function(player)
	if isAdmin(player) then
		player:SetAttribute("AdminFly", nil)
	end
end)

AdminService.Actions = HANDLERS

return AdminService
