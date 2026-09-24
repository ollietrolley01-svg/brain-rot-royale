-- Lag compensation for hitscan shots (#97, HITREG_DESIGN.md option A; Oliver picked the shooter
-- winning the cover trade).
--
-- The client sends a world POINT under its crosshair, and it aimed at where it SAW the victim, which
-- is where the victim was one round trip ago. Without this the server raycast against where the
-- victim is when the packet arrives, and at ordinary pings the ray went through the air they'd left
-- (55 ms of round trip was the break-even for a strafing target; see HITREG_DESIGN.md's table).
--
-- So every server step each combatant's root CFrame goes into a small ring buffer with the server
-- clock, and a player's shot is tested against every candidate victim put back where they stood at
-- (arrival - interval):
--
--   * THE INTERVAL is the server's own reading of the shooter's ping (Player:GetNetworkPing). NO CLIENT
--     TIMESTAMP IS EVER READ: a time the client could write is an aimbot by another name.
--   * THE CAP is 200 ms. A shot whose interval is longer is ruled on the PRESENT, not on a rewind to the
--     cap and not on an extrapolation: past 200 ms the victim has moved nearly two torsos and the
--     shooter's picture of them is not something to kill people over.
--   * BOTS use the present. They don't aim through a network, so there is nothing to undo.
--   * THE COVER TRADE: a victim who rounds a corner can still be hit for up to one interval after they
--     are safe on their own screen. That is the shooter-wins choice, and it is deliberate.
--
-- NOTHING IN THE WORLD IS MOVED. `workspace:Raycast` only tests the world as it is now, so the rewound
-- bodies are tested arithmetically instead: the ray goes through the world with every candidate's
-- character excluded, and separately against a box per body part, placed at the part's CURRENT offset
-- from its root carried onto the rewound root. The nearer of the two wins. There is nothing to restore
-- and no yield hazard (moving parts back and forth would replicate a teleport to every client the
-- moment anything yielded in between).
--
-- THE RESULT NAMES THE PART IT STRUCK, not just the victim: a headshot is decided by the struck part's
-- NAME (`Instance.Name == "Head"` in CombatService), so a rewind that returned a victim instead of a
-- part would silently delete every headshot in the game. tools/hitreg_rewind_check.py plants exactly
-- that and must catch it.
--
-- Only the root is stored (the design's "root only"): limbs are posed as they are now, around where
-- the root was. An arm swung since the shot is a few tenths of a stud; per-limb history would cost 15x
-- the memory for that.
--
--   LagCompensation.Now()                                  the server clock everything here runs on
--   LagCompensation.Record(now)                            one ring-buffer step (Heartbeat calls it)
--   LagCompensation.RewindTime(shooterToken, arrival)      when to test the shot at, or nil for now
--   LagCompensation.Raycast(origin, vector, params, at)    workspace:Raycast with the victims at `at`
--   LagCompensation.RootAt(character, at)                  a character's root CFrame at `at`

local RunService = game:GetService("RunService")

local Combatants = require(script.Parent:WaitForChild("Combatants"))

local LagCompensation = {}

-- Samples kept per combatant: 20 steps is 333 ms at 60 Hz, comfortably past the cap.
LagCompensation.Samples = 20
-- The longest rewind honoured, in seconds. Anything older is ruled on the present.
LagCompensation.Cap = 0.2
-- How far from its root a body part can reach. A candidate whose rewound root is further than this
-- from the ray can't be struck, so its parts are never tested.
LagCompensation.Reach = 8

-- Set by tools/hitreg_rewind_probe.lua, never by the game: told of every rewound ray.
LagCompensation.Observer = nil

-- character -> { samples = { { cframe, t } ... }, head = index of the newest }. A strong table,
-- pruned each step against Combatants.All(), not a weak one: Roblox drops an Instance's Lua handle
-- from a weak table while the Instance is still alive (COORDINATION.md).
local history = {}

-- The server's wall clock. NOT os.clock, which is CPU time in Roblox and runs slow under a yield.
function LagCompensation.Now()
	return workspace:GetServerTimeNow()
end

function LagCompensation.Record(now)
	local all = Combatants.All()
	for character in pairs(history) do
		if all[character] == nil or character.Parent == nil then
			history[character] = nil
		end
	end
	for character in pairs(all) do
		local root = character.Parent and character:FindFirstChild("HumanoidRootPart")
		if root then
			local entry = history[character]
			if not entry then
				entry = { samples = {}, head = 0 }
				history[character] = entry
			end
			entry.head = entry.head % LagCompensation.Samples + 1
			entry.samples[entry.head] = { cframe = root.CFrame, t = now }
		end
	end
end

-- For the probe and the check: forget everything (a fresh match, a fresh test).
function LagCompensation.Clear()
	table.clear(history)
end

-- Where `character`'s root stood at server time `at`: the two samples either side, blended. The live
-- root at `now` is the newest sample of all. Older than anything kept, the oldest sample stands (a
-- character that spawned a moment ago was nowhere else).
function LagCompensation.RootAt(character, at, now)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local newerCFrame, newerT = root.CFrame, now or LagCompensation.Now()
	if at >= newerT then
		return newerCFrame
	end
	local entry = history[character]
	if not entry then
		return newerCFrame
	end
	local count = #entry.samples
	local index = entry.head
	for _ = 1, count do
		local sample = entry.samples[index]
		if sample.t <= at then
			local span = newerT - sample.t
			if span <= 1e-6 then
				return sample.cframe
			end
			return sample.cframe:Lerp(newerCFrame, (at - sample.t) / span)
		end
		newerCFrame, newerT = sample.cframe, sample.t
		index = (index - 2) % count + 1
	end
	return newerCFrame
end

-- When a shot from `shooterToken` that arrived at `arrival` should be tested, or nil for the present.
function LagCompensation.RewindTime(shooterToken, arrival)
	if not Combatants.IsPlayer(shooterToken) then
		return nil
	end
	local ok, ping = pcall(function()
		return shooterToken:GetNetworkPing()
	end)
	if not ok or type(ping) ~= "number" or ping ~= ping or ping <= 0 or ping > LagCompensation.Cap then
		return nil
	end
	return arrival - ping
end

-- The ray against one box: the fraction along `vector` it enters at and the world normal of the face
-- it enters through, or nil. `cframe` is the box's centre, `size` its full size.
local function rayBox(origin, vector, cframe, size)
	local o = cframe:PointToObjectSpace(origin)
	local d = cframe:VectorToObjectSpace(vector)
	local lo, hi = 0, 1
	local axis, sign = nil, 0
	for _, name in ipairs({ "X", "Y", "Z" }) do
		local half = size[name] / 2
		local start, step = o[name], d[name]
		if math.abs(step) < 1e-9 then
			if math.abs(start) > half then
				return nil
			end
		else
			local near = (-half - start) / step
			local far = (half - start) / step
			local faceSign = -1
			if near > far then
				near, far = far, near
				faceSign = 1
			end
			if near > lo then
				lo, axis, sign = near, name, faceSign
			end
			if far < hi then
				hi = far
			end
			if lo > hi then
				return nil
			end
		end
	end
	local normal = -vector.Unit
	if axis then
		local localNormal = Vector3.new(axis == "X" and sign or 0, axis == "Y" and sign or 0, axis == "Z" and sign or 0)
		normal = cframe:VectorToWorldSpace(localNormal)
	end
	return lo, normal
end

-- The shortest distance from `point` to the segment from `origin` along `vector`.
local function segmentDistance(point, origin, vector)
	local lengthSquared = vector:Dot(vector)
	local t = lengthSquared > 0 and math.clamp((point - origin):Dot(vector) / lengthSquared, 0, 1) or 0
	return (origin + vector * t - point).Magnitude
end

-- Whether `part` can stop a shot, the same way the world raycast would decide it. A player's own Roblox
-- accessories never do (CombatService also turns them off at spawn: see WatchAccessories there).
local function shootable(part)
	return part:IsA("BasePart") and part.CanQuery and part:FindFirstAncestorWhichIsA("Accessory") == nil
end

-- workspace:Raycast, with every combatant's body put back where it stood at server time `at`. With no
-- `at` it IS workspace:Raycast. `params` must be an Exclude filter (every shot's is): anything it
-- already excludes (the shooter, a body a piercing shot has passed) stays excluded.
function LagCompensation.Raycast(origin, vector, params, at)
	if at == nil or params.FilterType ~= Enum.RaycastFilterType.Exclude then
		return workspace:Raycast(origin, vector, params)
	end
	local now = LagCompensation.Now()
	local filter = params.FilterDescendantsInstances
	local excluded = {}
	for _, instance in ipairs(filter) do
		excluded[instance] = true
	end

	-- The world, with every candidate body taken out of it; they're tested below instead.
	local worldFilter = table.clone(filter)
	local candidates = {}
	for character in pairs(Combatants.All()) do
		if character.Parent and not excluded[character] then
			table.insert(worldFilter, character)
			table.insert(candidates, character)
		end
	end
	local world = RaycastParams.new()
	world.FilterType = Enum.RaycastFilterType.Exclude
	world.FilterDescendantsInstances = worldFilter
	world.IgnoreWater = params.IgnoreWater
	world.CollisionGroup = params.CollisionGroup
	world.RespectCanCollide = params.RespectCanCollide
	local worldHit = workspace:Raycast(origin, vector, world)
	local best = worldHit and (worldHit.Position - origin).Magnitude / vector.Magnitude or math.huge
	local bestPart, bestNormal = nil, nil

	for _, character in ipairs(candidates) do
		local root = character:FindFirstChild("HumanoidRootPart")
		local past = root and LagCompensation.RootAt(character, at, now)
		if past and segmentDistance(past.Position, origin, vector) <= LagCompensation.Reach then
			-- Carries a part from where the root is now to where it was then.
			local carry = past * root.CFrame:Inverse()
			for _, part in ipairs(character:GetDescendants()) do
				if shootable(part) then
					local skip = false
					for instance in pairs(excluded) do
						if part:IsDescendantOf(instance) then
							skip = true
							break
						end
					end
					if not skip then
						local t, normal = rayBox(origin, vector, carry * part.CFrame, part.Size)
						if t and t < best then
							best, bestPart, bestNormal = t, part, normal
						end
					end
				end
			end
		end
	end

	local result = worldHit
	if bestPart then
		-- The fields CombatService and VehicleWeapons read off a RaycastResult. Instance is the REAL
		-- part, so its name (Head) and its ancestry (the character) both still resolve.
		local position = origin + vector * best
		result = {
			Instance = bestPart,
			Position = position,
			Normal = bestNormal,
			Material = bestPart.Material,
			Distance = (position - origin).Magnitude,
			Rewound = true,
		}
	end
	if LagCompensation.Observer then
		task.spawn(LagCompensation.Observer, { origin = origin, vector = vector, at = at, now = now, result = result })
	end
	return result
end

RunService.Heartbeat:Connect(function()
	LagCompensation.Record(LagCompensation.Now())
end)

return LagCompensation
