-- The lobby firing range: pick a gun off the rack on the arena terrace, shoot the practice
-- targets, and lose the gun the moment you walk off the terrace.
--
--   RangeService.SetArea(center, radius)   where the range is (LobbyService, when it builds it)
--   RangeService.Give(player, weaponId)    the rack's prompts
--   RangeService.Fire(player, aimPoint)    a shot, from the client's range remote
--
-- Safety here is structural rather than conditional. Match combat is off in the lobby and
-- `CombatService.Fire` returns immediately while it is, and this does not touch that guard.
-- Range shots go down their own path whose raycast filter *includes only* parts tagged
-- PracticeDummy, so a player is never a candidate target — not because a check says so, but
-- because nothing else is in the filter. Damage numbers come back through the same ConfirmHit
-- the real game uses, so a hit on a target pops exactly like a hit in a match.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local SafeValue = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("SafeValue"))
local WeaponData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("WeaponData"))

local CombatService = require(script.Parent:WaitForChild("CombatService"))
local PracticeDummy = require(script.Parent:WaitForChild("PracticeDummy"))
local RateLimit = require(script.Parent:WaitForChild("RateLimit"))
local StateSync = require(script.Parent:WaitForChild("StateSync"))
local WeaponService = require(script.Parent:WaitForChild("WeaponService"))

local RangeService = {}

-- How far outside the terrace you get before the gun is taken off you. A little slack so
-- standing on the very edge doesn't flicker the gun in and out.
local LEAVE_SLACK = 6
local CHECK_INTERVAL = 0.4

local rangeState = Remotes.Event("RangeState")
local rangeFire = Remotes.Event("RangeFire")

local area = nil
local active = {}

function RangeService.SetArea(center, radius)
	area = { center = center, radius = radius }
end

local function insideArea(player, slack)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not area then
		return false
	end
	local flat = Vector3.new(root.Position.X - area.center.X, 0, root.Position.Z - area.center.Z)
	return flat.Magnitude <= area.radius + (slack or 0)
end

-- Takes the gun back and tells the client to leave range mode.
local function stop(player, message)
	local ours = active[player]
	if not ours then
		return
	end
	active[player] = nil

	-- ONLY TAKE BACK GEAR THE RANGE HANDED OUT -- #106, "players often can't pick weapons up,
	-- especially after holding a gun from the trial area in the lobby".
	--
	-- `WeaponService.Clear` does `loadouts[player] = nil`, and `GiveWeapon` then refuses outright
	-- with "Not in a match." -- a message LootService only ever shows on SUCCESS, so the player
	-- pressed a pickup prompt and watched absolutely nothing happen. This function is driven by the
	-- 0.4s poll at the bottom of this file, which cannot be sequenced against match start, and BOTH
	-- of its triggers (combat enabled; player no longer on the terrace) come true AFTER
	-- MatchService has created the match loadout. So it deleted the loadout the match had just
	-- made, and the player could not pick anything up for the rest of the match. Team modes hid it
	-- by calling Reset again on every respawn; battle royale has no respawn, which is why Oliver
	-- saw it as "often" rather than "always".
	--
	-- The guard is an IDENTITY check rather than an ordering fix, so it holds however the callers
	-- are later rearranged: Reset installs a NEW loadout table, so if the table the player holds is
	-- not the one the range created, the range does not own it and touches nothing -- not the
	-- loadout, and not the HeldGun welded to the character either.
	if WeaponService.Get(player) == ours then
		WeaponService.Clear(player)
		-- Clearing the loadout empties the inventory, which is not the same as taking the gun out of
		-- your hands: the mounted model is welded to the character and survives on its own. It is a
		-- child of the character named HeldGun, the same handle BotService uses when it swaps a bot's
		-- weapon. Without this the range gun stayed visible after the rack had taken it back.
		local character = player.Character
		local held = character and character:FindFirstChild("HeldGun")
		if held then
			held:Destroy()
		end
		WeaponService.Push(player)
	end

	if player.Parent then
		rangeState:FireClient(player, false)
		if message then
			StateSync.Notify(player, message)
		end
	end
end

RangeService.Stop = stop

-- The rack's prompts. A range gun only exists in the lobby, so this refuses outright once a
-- match is running rather than handing someone a loadout mid-countdown.
function RangeService.Give(player, weaponId)
	if CombatService.IsEnabled() then
		return false, "The range is closed once a match starts."
	end
	if not WeaponData.Get(weaponId) then
		return false, "No such gun."
	end
	if not insideArea(player, LEAVE_SLACK) then
		return false, "Stand on the arena terrace to take a gun."
	end

	local def = WeaponData.Get(weaponId)
	local message = "Range gun: " .. def.name .. ".  Walk off the terrace to hand it back."

	-- ALREADY HOLDING RANGE GUNS: ADD THIS ONE, DON'T SWAP -- #117, "lobby trial guns change every
	-- pickup". Every take used to start with `WeaponService.Reset`, which throws the whole loadout
	-- away, so taking the second podium's gun silently took the first one off you: whatever you
	-- picked up, you only ever had the last gun, and it looked as if the guns were changing under
	-- you. (Nothing else moves: each podium's gun is fixed when the lobby is built, its prompt
	-- captures that one entry, and the display is built from the same entry.) The loadout here is
	-- the range's own -- the identity check is the same one `stop` makes -- so adding to it cannot
	-- stock anyone up for a match: it all goes when you step off the terrace, and a match makes a
	-- new loadout of its own anyway. There are three podiums and eight slots, so it never fills.
	local ours = active[player]
	if ours and WeaponService.Get(player) == ours then
		for index = 1, WeaponService.SlotCount do
			local slot = ours.slots[index]
			if slot and slot.kind == "weapon" and slot.id == weaponId then
				-- The same gun again: hold it and top it up, rather than a second copy of it.
				slot.mag = def.magSize
				slot.reserve = def.reserveAmmo
				WeaponService.Equip(player, index)
				WeaponService.Push(player)
				rangeState:FireClient(player, true)
				return true, message
			end
		end
		if not WeaponService.GiveWeapon(player, weaponId) then
			return false, "Couldn't hand you that."
		end
		-- GiveWeapon only puts a gun in your hands when they were empty; this is the gun you just
		-- reached for, so hold it. If it isn't in the range loadout after all (the loadout was swapped
		-- underneath us), say so rather than telling the player they got a gun they can't see.
		local held = false
		for index = 1, WeaponService.SlotCount do
			local slot = ours.slots[index]
			if slot and slot.kind == "weapon" and slot.id == weaponId then
				WeaponService.Equip(player, index)
				held = true
				break
			end
		end
		if not held then
			return false, "Couldn't hand you that."
		end
		rangeState:FireClient(player, true)
		return true, message
	end

	-- The first gun off the podiums: a fresh loadout, so whatever the player had is replaced and
	-- the range can never be used to stock up for a match. It all goes when you step off.
	WeaponService.Reset(player)
	local ok = WeaponService.GiveWeapon(player, weaponId)
	if not ok then
		return false, "Couldn't hand you that."
	end
	-- The loadout TABLE we just created, not a bare flag: `stop` compares it against whatever the
	-- player holds later, so a loadout MatchService has since replaced is never mistaken for ours
	-- and deleted out from under the match. #106
	active[player] = WeaponService.Get(player)
	rangeState:FireClient(player, true)
	return true, message
end

-- A range shot. Only tagged targets are in the raycast filter, so this cannot reach a player.
function RangeService.Fire(player, aimPoint)
	-- NaN/inf in any component is refused (SafeValue explains why a size check alone isn't enough).
	if not active[player] or CombatService.IsEnabled() or not SafeValue.Vector3(aimPoint) then
		return
	end
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not head or not humanoid or humanoid.Health <= 0 or not insideArea(player, LEAVE_SLACK) then
		return
	end

	local loadout = WeaponService.Get(player)
	local def = WeaponService.GetEquipped(player)
	if not loadout or not def or loadout.reloading or not WeaponService.IsReady(player) then
		return
	end
	if CombatService.IsDriving(player) then return end
	local origin = head.Position
	local direction = aimPoint - origin
	if direction.Magnitude < 0.5 then return end
	local now = os.clock()
	-- The SAME budget the match path uses (CombatService.ShotCredit), not a second copy of the rule:
	-- the range is where a player learns how a gun feels, so it has to feel identical. #97
	local credit = CombatService.ShotCredit(loadout, def, now)
	if credit < 1 then return end
	-- Real ammo, so reloading at the range behaves exactly like reloading in a match.
	if not WeaponService.ConsumeAmmo(player) then
		return
	end
	CombatService.SpendShot(loadout, credit, now)

	local targets = CollectionService:GetTagged("PracticeDummy")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = targets

	CombatService.WatchCrouch(character)
	local spread = CombatService.SpreadFor(player, def)
	local base = CFrame.lookAt(Vector3.zero, direction.Unit)
	local endPoints = {}
	for _ = 1, def.pellets or 1 do
		local spin = math.random() * math.pi * 2
		local tilt = math.random() * math.rad(spread)
		local ray = (base * CFrame.Angles(0, 0, spin) * CFrame.Angles(tilt, 0, 0)).LookVector * def.range
		local result = workspace:Raycast(origin, ray, params)
		table.insert(endPoints, result and result.Position or origin + ray)
		if result then
			-- Each shotgun pellet can score, just as it does in a match. The targets are dummies with
			-- a player's health and shield (PracticeDummy): a hit comes off those, the head pays the
			-- gun's own headshot multiplier and the painted target its bullseye bonus, and the marker
			-- is blue or gold as it would be on a person.
			local dealt, killed, hitShield, headshot = PracticeDummy.Hit(result.Instance, def.damage, def.headshotMultiplier)
			CombatService.ConfirmHit(player, dealt, killed, result.Position, nil, hitShield, headshot)
		end
	end
	-- Hits AND misses need the normal report, muzzle flash and tracers. These
	-- cosmetic events do not enable match damage or hit anything outside targets.
	CombatService.BroadcastShot(player, origin, endPoints, def.rarity)
end

rangeFire.OnServerEvent:Connect(function(player, aimPoint)
	-- Same budget as the match Fire remote (claude-f5's rate limits, 2026-09-17).
	if not RateLimit.Take(player, "RangeFire") then
		return
	end
	RangeService.Fire(player, aimPoint)
end)

-- Walking off the terrace hands the gun back. Checked on a slow loop rather than per frame:
-- nothing here is time-critical and there are only ever a handful of people on the range.
task.spawn(function()
	while true do
		task.wait(CHECK_INTERVAL)
		for player in pairs(active) do
			if not player.Parent then
				active[player] = nil
			elseif CombatService.IsEnabled() then
				stop(player)
			elseif not insideArea(player, LEAVE_SLACK) then
				stop(player, "Range gun handed back.")
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	active[player] = nil
end)

return RangeService
