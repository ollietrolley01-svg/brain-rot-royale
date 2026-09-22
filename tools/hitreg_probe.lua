-- #97 hit registration: what a shot costs when nobody rewinds the target.
--
-- MEASUREMENT ONLY. Nothing here changes the game; it does not even require CombatService to be
-- modified. Run it with:
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/hitreg_probe.lua
--
-- WHAT IS ALREADY ESTABLISHED FROM SOURCE, so this does not re-measure it:
--   * There is no lag compensation anywhere in the project: `rewind`, `positionHistory`, `snapshotAt`
--     and `lagComp` appear nowhere, and nothing reads a ping. The server raycasts against live
--     positions when the packet arrives.
--   * The client sends `aimPoint`, a WORLD POINT under its crosshair, and the server derives the
--     direction itself. A world point is a place, not a target: if the victim moves, the ray goes to
--     where they were and passes through the air they left.
--
-- WHAT THIS MEASURES: how much of a hit that actually costs, as a function of how fast the victim is
-- moving, which way, and how long the shot took to arrive. For each case it records whether the shot
-- lands, what it hits, and two distances that together are the whole bug in one column --
--   miss_now    how far the ray passes from the victim's centre AT ARRIVAL (what the server sees)
--   miss_then   the same distance at (arrival - latency) (what the shooter saw when they fired)
-- A row where miss_then is inside the torso and miss_now is outside it is a shot the player earned
-- and the server threw away.
--
-- HONEST LIMITS, because a number from an instrument that measured nothing looks like a result:
--   1. NO PLAYER OBJECT EXISTS IN THIS HARNESS, so `Player:GetNetworkPing()` cannot be called and no
--      real ping is measured. Latency here is a PARAMETER, swept over a range, and every line says so.
--      The live half needs a hook in a real session; `HitReg.LogShot` below is written for that and is
--      not wired to anything.
--   2. `CombatService.Fire` needs a Player too, so the raycast here is a REPLICA of the shipped one:
--      same Exclude filter shape, same `IgnoreWater = true`. It is checked against the real function's
--      source at the top of the run, and the run says loudly if the shipped params have changed.
--   3. Velocities are driven by setting the rig's CFrame directly, not by a Humanoid walking. That
--      measures the geometry of the miss, which is the question; it does not measure Roblox's own
--      replication of a moving character, which only a real session can.
--
-- PLANTED FAULTS, both directions, every run: a shot at a stationary target at zero latency MUST hit
-- (or the rig, the aim point or the ray is wrong and no other number here means anything), and a shot
-- at a target crossing at full speed with a quarter second of latency MUST miss.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))

local function out(fmt, ...)
	print((_G.BRR_PROBE_PREFIX or "[PROBE] ") .. string.format(fmt, ...))
end

--------------------------------------------------------------------------------
-- The shape of a combatant, and of the shot
--------------------------------------------------------------------------------

-- R15 torso and head, at the sizes the game's own rigs use. The torso half-width is the number every
-- miss distance is judged against: inside it the shot lands, outside it the shot is gone.
local TORSO = Vector3.new(2, 2, 1)
local HEAD = Vector3.new(1.2, 1.2, 1.2)
local TORSO_HALF = TORSO.X / 2
local EYE = Vector3.new(0, 1.5, 0)

local SPEEDS = { 0, 9, 18 }
local ANGLES = { 0, 45, 90 }
local LATENCIES = { 0, 0.03, 0.06, 0.1, 0.15 }
local RANGE = 60

local walk = MatchConfig.BaseWalkSpeed or 18

local stage = Instance.new("Folder")
stage.Name = "BRR_HitReg"
stage.Parent = workspace

local function part(name, size, cframe, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.Size = size
	p.CFrame = cframe
	p.Parent = parent
	return p
end

local function victimAt(position)
	local model = Instance.new("Model")
	model.Name = "Victim"
	local root = part("HumanoidRootPart", TORSO, CFrame.new(position), model)
	part("Head", HEAD, CFrame.new(position + Vector3.new(0, 1.5, 0)), model)
	model.PrimaryPart = root
	model.Parent = stage
	return model, root
end

-- The shipped raycast, replicated: Exclude, and water ignored. Checked against the real source below.
local function shotParams(shooter)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { shooter }
	return params
end

-- How far a part's own shape reaches above its centre in world Y (a cosmetic is all rotation, so the
-- box's half-height is not the answer).
local function reachUp(p)
	local f, half = p.CFrame, p.Size / 2
	return math.abs(f.RightVector.Y) * half.X + math.abs(f.UpVector.Y) * half.Y + math.abs(f.LookVector.Y) * half.Z
end

-- Perpendicular distance from a segment to a point: how far the shot passed from the victim's middle.
local function missDistance(origin, target, centre)
	local delta = target - origin
	local length = delta.Magnitude
	if length < 1e-6 then
		return (centre - origin).Magnitude
	end
	local direction = delta / length
	local along = math.clamp((centre - origin):Dot(direction), 0, length)
	return ((origin + direction * along) - centre).Magnitude
end

--------------------------------------------------------------------------------
-- Does the replica still match the shipped raycast?
--------------------------------------------------------------------------------

local function checkReplica()
	local ok, source = pcall(function()
		local module = ServerScriptService:WaitForChild("Modules"):WaitForChild("CombatService")
		return module.Source
	end)
	if not ok or type(source) ~= "string" or #source == 0 then
		out("NOTE: CombatService source unreadable here, so the replica raycast is UNCHECKED this run")
		return
	end
	local exclude = string.find(source, "FilterType = Enum.RaycastFilterType.Exclude", 1, true) ~= nil
	local water = string.find(source, "params.IgnoreWater = true", 1, true) ~= nil
	out("shipped raycast: Exclude filter %s, IgnoreWater true %s -> replica %s",
		exclude and "yes" or "NO", water and "yes" or "NO",
		(exclude and water) and "matches" or "DOES NOT MATCH, treat every row below as suspect")
end

--------------------------------------------------------------------------------
-- One shot
--------------------------------------------------------------------------------

-- The client aims at the victim's centre as it sees it (at fire time) and sends that WORLD POINT.
-- `latency` later the server raycasts to that same point, by which time the victim has moved on.
local function fireAt(shooterRoot, velocity, latency)
	local start = shooterRoot.Position + Vector3.new(0, 0, -RANGE)
	local model, root = victimAt(start)
	local origin = shooterRoot.Position + EYE
	local aimPoint = root.Position

	local arrived = start + velocity * latency
	model:PivotTo(CFrame.new(arrived))

	local params = shotParams(shooterRoot.Parent)
	local delta = aimPoint - origin
	local result = workspace:Raycast(origin, delta.Unit * (delta.Magnitude + 2), params)
	local hit = result and result.Instance and result.Instance:IsDescendantOf(model) and result.Instance.Name or nil

	local missNow = missDistance(origin, aimPoint, arrived)
	local missThen = missDistance(origin, aimPoint, start)
	model:Destroy()
	return hit, missNow, missThen
end

--------------------------------------------------------------------------------
-- Planted faults
--------------------------------------------------------------------------------

local shooterModel = Instance.new("Model")
shooterModel.Name = "Shooter"
shooterModel.Parent = stage
local shooterRoot = part("HumanoidRootPart", TORSO, CFrame.new(0, 500, 0), shooterModel)

local function selfTest()
	local still, missStill = fireAt(shooterRoot, Vector3.zero, 0)
	out("self-test still target, no latency: %s, ray passes %.2f studs from centre -> %s",
		still or "MISS", missStill, still and "ok" or "ERROR the rig or the ray is wrong; ignore every row below")
	local crossing = Vector3.new(walk, 0, 0)
	local gone, missGone = fireAt(shooterRoot, crossing, 0.25)
	out("self-test crossing at %d studs/s, 250 ms: %s, ray passes %.2f studs from centre -> %s",
		walk, gone or "MISS", missGone, (not gone) and "ok" or "ERROR a target a quarter second away was still hit")
	return still ~= nil and gone == nil
end

checkReplica()
local sound = selfTest()
if not sound then
	out("SELF-TEST FAILED -- the numbers below are not evidence")
end

--------------------------------------------------------------------------------
-- The sweep
--------------------------------------------------------------------------------

out("torso half-width %.2f studs; a shot lands while the ray passes closer than that to the centre", TORSO_HALF)
out("%-6s %-7s %-9s %-6s %-10s %-10s %s", "speed", "angle", "latency", "hit", "miss_now", "miss_then", "verdict")

local earned, lost = 0, 0
for _, speed in ipairs(SPEEDS) do
	for _, angle in ipairs(ANGLES) do
		local radians = math.rad(angle)
		-- 0 degrees walks straight at the shooter, 90 crosses the shot square on.
		local velocity = Vector3.new(math.sin(radians) * speed, 0, math.cos(radians) * speed)
		for _, latency in ipairs(LATENCIES) do
			local hit, missNow, missThen = fireAt(shooterRoot, velocity, latency)
			local wasEarned = missThen <= TORSO_HALF
			local isThrown = wasEarned and not hit
			if wasEarned then
				earned += 1
			end
			if isThrown then
				lost += 1
			end
			out("%-6d %-7d %-9.0f %-6s %-10.2f %-10.2f %s", speed, angle, latency * 1000, hit or "-",
				missNow, missThen,
				isThrown and "SHOT EARNED AND THROWN AWAY" or (hit and "landed" or "missed when fired too"))
			task.wait()
		end
	end
end

out("%d of %d shots were on target when they were fired and missed by the time they arrived", lost, earned)
out("note: latency here is a PARAMETER, not a measured ping -- no Player exists in this harness")

--------------------------------------------------------------------------------
-- The second cause: what a shot at a head actually hits
--------------------------------------------------------------------------------
--
-- A headshot is decided by NAME -- `result.Instance.Name == "Head"` (CombatService.lua:602, and
-- ProjectileService.lua:659) -- and nothing in the combat path excludes or de-queries what sits on a
-- head. This game welds its OWN cosmetic to the head (AccessoryService.Attach builds
-- CosmeticBuild.Model and welds every piece to the Head), so this is measurable here with the game's
-- own content, no Roblox avatar assets needed. A ray stopped by a hat is paid as body damage: no
-- multiplier, no marker, no stat, and nothing tells the shooter.

local CosmeticData = require(Shared:WaitForChild("CosmeticData"))
local CosmeticBuild = require(Shared:WaitForChild("CosmeticBuild"))

-- Where AccessoryService actually puts an item, copied from its own `anchorFor`: a Face item sits on
-- the front of the head, everything else on top. The first version of this probe used the HeadTop
-- offset for EVERY item, which put a pair of sunglasses on the crown of the head -- a misplacement
-- that reads as "sunglasses block nothing" rather than as a broken measurement.
local function originFor(head, anchor)
	if anchor == "Face" then
		return head.CFrame * CFrame.new(0, head.Size.Y * 0.08, -head.Size.Z / 2)
	end
	return head.CFrame * CFrame.new(0, head.Size.Y / 2, 0)
end

-- Rays at the head AND at the silhouette above it, because that is what a player aims at.
--
-- The first version of this aimed every ray at the Head part's centre and reported 0% swallowed for
-- all eight cosmetics while a planted slab read 100%. That gap was the instrument, not the hats: a hat
-- sits ON TOP of the head, so a ray to the head's centre passes under it by design. A player aims at
-- what they SEE -- a head wearing a traffic cone is a tall silhouette, and the shots that get swallowed
-- are the ones at its upper half. So the grid now sweeps aim points up the whole visible silhouette,
-- and the "aimed at the very centre" row is kept separately as the best case.
local function headShots(rig, head, wearing)
	local metHead, metHat, metNothing = 0, 0, 0
	local worn = {}
	-- How tall the thing a player sees actually is, measured from the parts rather than assumed.
	local top = head.Position.Y + head.Size.Y / 2
	for _, piece in ipairs(rig:GetDescendants()) do
		if piece:IsA("BasePart") and piece.Name ~= "Head" then
			top = math.max(top, piece.Position.Y + reachUp(piece))
		end
	end
	local bottom = head.Position.Y - head.Size.Y / 2
	local aims = {}
	for step = 0, 4 do
		table.insert(aims, Vector3.new(head.Position.X, bottom + (top - bottom) * (step / 4), head.Position.Z))
	end
	for _, azimuth in ipairs({ 0, 45, 90, 135, 180, 225, 270, 315 }) do
		for _, aim in ipairs(aims) do
			local a = math.rad(azimuth)
			local direction = Vector3.new(math.cos(a), 0, math.sin(a))
			local origin = aim + direction * 40
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.IgnoreWater = true
			local result = workspace:Raycast(origin, (aim - origin) * 1.05, params)
			local hit = result and result.Instance
			if not hit then
				metNothing += 1
			elseif hit.Name == "Head" then
				metHead += 1
			elseif hit:IsDescendantOf(rig) then
				metHat += 1
				worn[hit.Name] = (worn[hit.Name] or 0) + 1
			else
				metNothing += 1
			end
		end
	end
	local names = {}
	for name in pairs(worn) do
		table.insert(names, name)
	end
	table.sort(names)
	local total = metHead + metHat + metNothing
	out("%-18s %3d rays: head %3d, swallowed %3d (%3.0f%%), nothing %d%s", wearing, total, metHead, metHat,
		total > 0 and metHat / total * 100 or 0, metNothing,
		#names > 0 and ("  by " .. table.concat(names, ", ")) or "")
	return metHead, metHat, total
end

local hatStage = Instance.new("Folder")
hatStage.Name = "BRR_HitRegHeads"
hatStage.Parent = workspace

local rig = Instance.new("Model")
rig.Name = "HeadRig"
rig.Parent = hatStage
local head = part("Head", Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, 700, 0), rig)

-- Planted faults, both directions: a bare head must be hit by every ray, and a head under a slab must
-- be hit by none. Without these, "0% swallowed" could mean the rays missed the rig entirely.
local bareHead, bareHat, bareTotal = headShots(rig, head, "PLANTED bare head")
local slab = part("PlantedSlab", Vector3.new(6, 6, 6), CFrame.new(0, 700, 0), rig)
local _, slabHat, slabTotal = headShots(rig, head, "PLANTED slab over it")
slab:Destroy()
out("self-test heads: bare %s, slab %s", (bareHead == bareTotal) and "all rays reached it, ok" or "ERROR rays missed a bare head",
	(slabHat == slabTotal) and "every ray swallowed, ok" or "ERROR a slab did not swallow them")

local worst, worstName, tested = 0, nil, 0
for _, id in ipairs({ "ChefHat", "PartyCone", "TrafficCone", "VikingHelm", "PropellerBeanie", "ExposedBrain", "RubberDuck", "RotShades" }) do
	local item = CosmeticData.Get(id)
	if item and item.kind == "Accessory" then
		local ok, model = pcall(CosmeticBuild.Model, item, originFor(head, item.anchor), 1, "CosmeticAccessory")
		if ok and model then
			model.Parent = rig
			for _, piece in ipairs(model:GetDescendants()) do
				if piece:IsA("BasePart") then
					piece.Anchored = true
				end
			end
			local _, swallowed, total = headShots(rig, head, id)
			tested += 1
			if swallowed / total > worst then
				worst, worstName = swallowed / total, id
			end
			model:Destroy()
		else
			out("%-18s could not be built here: %s", id, tostring(model))
		end
	end
	task.wait()
end

out("%d head cosmetics tested; worst swallows %.0f%% of shots at the head (%s)", tested, worst * 100, worstName or "-")
hatStage:Destroy()
stage:Destroy()
out("done")

--------------------------------------------------------------------------------
-- The live half, for a real session. NOT WIRED TO ANYTHING.
--------------------------------------------------------------------------------
--
-- In a real session the same two distances can be measured against real pings, which is the evidence
-- this harness cannot produce. `HitReg.LogShot` is written to be called from CombatService.Fire with
-- the shooter, the aimPoint and the victim it resolved -- one line, which needs its own approval and
-- is deliberately not added here:
--
--   local ping = player:GetNetworkPing()            -- seconds, round trip, server-readable
--   local victimRoot = victim and victim:FindFirstChild("HumanoidRootPart")
--   if victimRoot then
--       local then_ = victimRoot.Position - victimRoot.AssemblyLinearVelocity * ping
--       print(string.format("[HITREG] ping %.0f ms, speed %.1f, miss_now %.2f, miss_then %.2f",
--           ping * 1000, victimRoot.AssemblyLinearVelocity.Magnitude,
--           missDistance(origin, aimPoint, victimRoot.Position),
--           missDistance(origin, aimPoint, then_)))
--   end
--
-- If `GetNetworkPing` returns zero for a player, that is a reading, not a latency: print it as
-- "ping unavailable" rather than as 0 ms, or the histogram fills with shots that look instant.
