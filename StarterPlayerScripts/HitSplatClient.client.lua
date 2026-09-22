-- The little red splat where a bullet lands on someone, for everyone watching.
--
-- HitSplatService sends each frame's hits as one HitSplat batch: { victim character, attacker
-- character or false, headshot, shield } each. The server only knows who hit whom; the spot on the
-- body is found here, by tracing from the shooter's head to the part that was hit (the head for a
-- headshot, the torso otherwise, with a little scatter) against the victim alone. The splat goes on
-- when the tracer would arrive, so it lands with the shot rather than ahead of it (ExplosiveFx.Splat
-- draws it and keeps it on the limb as the body moves). Far-off hits aren't drawn at all.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local Rarity = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Rarity"))
local ExplosiveFx = require(script.Parent:WaitForChild("ExplosiveFx"))
local Sfx = require(script.Parent:WaitForChild("Sfx"))

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Beyond this from the camera nothing is drawn; a splat is a stud wide.
local CULL_DISTANCE = 350
-- GunFx's bullets fly at about this, so the splat waits for them.
local TRACER_SPEED = 900
local TORSO_NAMES = { "UpperTorso", "Torso", "HumanoidRootPart" }

local victimParams = RaycastParams.new()
victimParams.FilterType = Enum.RaycastFilterType.Include

local function bodyPart(character, headshot)
	if headshot then
		local head = character:FindFirstChild("Head")
		if head then
			return head
		end
	end
	for _, name in ipairs(TORSO_NAMES) do
		local part = character:FindFirstChild(name)
		if part then
			return part
		end
	end
	return nil
end

-- `rarity` is the rank of the gun that dealt the hit (the server's word): the splat is drawn in
-- that rank's colour.
--
-- HARD RULE: no red fallback, anywhere. The old code here was
-- `type(rarity) == "string" and Rarity.Colors[rarity] and Rarity.Color(rarity) or nil`, and passing
-- that `nil` on to ExplosiveFx.Splat hit a fallback in THAT module literally named BLOOD
-- (Color3.fromRGB(148, 16, 16)) -- ExplosiveFx.Splat is called from nowhere else in the project, so
-- that constant is reachable only through this one call. Every WeaponData entry carries a rarity
-- today (checked: 27/27, ReplicatedStorage/Shared/WeaponData.lua), so the path was dormant rather
-- than firing on live data, but `rarity` also arrives as literal `false` for a non-gunfire hit
-- (HitSplatService.Payload) and would have taken the same nil branch. `Rarity.Color` already
-- defaults unmatched input to Common's grey (ReplicatedStorage/Shared/Rarity.lua:22-24) and is safe
-- to call directly with a string, `false`, or `nil` alike -- a plain Lua table read on any of those
-- keys returns nil, never an error -- so routing through it directly removes the red branch
-- entirely instead of relying on every future caller to remember not to take it.
local function splat(victim, attacker, headshot, shield, rarity)
	local color = Rarity.Color(rarity)
	local target = bodyPart(victim, headshot)
	if not target then
		return
	end
	if (target.Position - camera.CFrame.Position).Magnitude > CULL_DISTANCE then
		return
	end

	local shooterHead = attacker and attacker:FindFirstChild("Head")
	local from = shooterHead and shooterHead.Position
	if not from then
		-- No shooter to trace from (a companion, a bot that's gone): from somewhere off to the side.
		local direction = Vector3.new(math.random() - 0.5, math.random() * 0.4 - 0.2, math.random() - 0.5)
		from = target.Position + (direction.Magnitude > 0.01 and direction.Unit or Vector3.xAxis) * 6
	end

	-- Scatter across the face of the part, so a burst doesn't stack every splat on one point.
	local toTarget = target.Position - from
	local distance = toTarget.Magnitude
	if distance < 0.1 then
		return
	end
	local forward = toTarget / distance
	local right = forward:Cross(Vector3.yAxis)
	right = right.Magnitude > 0.01 and right.Unit or Vector3.xAxis
	local up = right:Cross(forward)
	local size = target.Size
	local aim = target.Position + right * ((math.random() - 0.5) * size.X * 0.6) + up * ((math.random() - 0.5) * size.Y * 0.6)

	victimParams.FilterDescendantsInstances = { victim }
	local hit = workspace:Raycast(from, (aim - from) * 1.5, victimParams)
	local limb, point, normal
	if hit and hit.Instance:IsDescendantOf(victim) then
		limb, point, normal = hit.Instance, hit.Position, hit.Normal
	else
		limb = target
		normal = -forward
		point = target.Position + normal * (math.min(size.X, size.Z) * 0.5)
	end

	task.delay(distance / TRACER_SPEED, function()
		if not limb.Parent or not victim.Parent then
			return
		end
		ExplosiveFx.Splat(limb, point, normal, { headshot = headshot, shield = shield, color = color })
		if not shield then
			Sfx.PlayAt("HitSplat", point, 0.15)
		end
	end)
end

Remotes.Event("HitSplat").OnClientEvent:Connect(function(batch)
	if type(batch) ~= "table" then
		return
	end
	for _, hit in ipairs(batch) do
		if type(hit) == "table" then
			local victim, attacker = hit[1], hit[2]
			if typeof(victim) == "Instance" and victim:IsA("Model") and victim.Parent then
				splat(victim, typeof(attacker) == "Instance" and attacker:IsA("Model") and attacker or nil, hit[3] == true, hit[4] == true, hit[5])
			end
		end
	end
end)

-- Your own splats are drawn like everyone else's, so a hit you land is a hit you can see; the
-- player variable keeps the script's intent plain if that changes.
local _ = player
