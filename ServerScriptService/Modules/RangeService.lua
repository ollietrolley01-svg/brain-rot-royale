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
	if not active[player] then
		return
	end
	active[player] = nil
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

	-- A fresh single-slot loadout each time, so the range can never be used to stock up for a
	-- match: whatever was in hand is replaced, and it all goes when you step off.
	WeaponService.Reset(player)
	local ok = WeaponService.GiveWeapon(player, weaponId)
	if not ok then
		return false, "Couldn't hand you that."
	end
	active[player] = true
	rangeState:FireClient(player, true)
	return true, "Range gun: " .. WeaponData.Get(weaponId).name .. ".  Walk off the terrace to hand it back."
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
	if now - loadout.lastShotAt < (1 / def.fireRate) * 0.9 then return end
	-- Real ammo, so reloading at the range behaves exactly like reloading in a match.
	if not WeaponService.ConsumeAmmo(player) then
		return
	end
	loadout.lastShotAt = now

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
