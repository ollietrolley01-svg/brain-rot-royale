-- Buildings fall over (Oliver 2026-09-24: "buildings fall over with physics; they don't vanish when
-- their support is gone"). DestructibleService works out what a break leaves hanging or standing
-- badly (its support pass: a bounded search over what touches what, cached per part the first time
-- a building is hit) and hands the chunk here:
--
--   CollapseService.Drop(parts, topple)   weld the chunk into one assembly, unanchor it, keep the
--                                         server as its network owner, and let it fall. `topple`
--                                         ({ pivot, direction }) starts it rolling over the edge of
--                                         what is left under it, for a chunk that is still standing
--                                         but on too little (its weight outside what holds it, or a
--                                         sliver of what it stood on).
--
-- While it falls nothing on it can be shot (DestructibleService only hurts anchored parts). When it
-- hits hard it BREAKS UP: its smallest pieces burst into debris the way their materials break
-- (BreakFx), the rest splits into at most SPLIT pieces that tumble on, and whatever it lands on is
-- hurt: combatants inside it by CRUSH_PER x mass x speed (at most CRUSH_CAP, weapon "Rubble"), map
-- things it hits by STRIKE_PER x mass x speed (at most STRIKE_CAP each). Once it lies still (SETTLE
-- for SETTLE_HOLD) or after TIMEOUT it is anchored again where it lies: rubble, still cover and still
-- breakable (its parts keep their names and pools), and whatever stood where it used to be (loot,
-- supply drops, deployables) is told through OnPartBroken and settles.
--
-- BUDGET. At most MAX_ASSEMBLIES chunks fall at once and a chunk has at most MAX_PARTS parts (a
-- welded chunk is ONE physics body, however many parts; after it breaks up, at most SPLIT). Past
-- either cap it degrades: the chunk crumbles where it stands instead (every piece bursts into debris
-- and is gone, the way everything broke before), so nothing is left hanging and the server never
-- simulates more than MAX_ASSEMBLIES x SPLIT bodies for this.

local RunService = game:GetService("RunService")

local CollapseService = {}

CollapseService.MaxAssemblies = 6
CollapseService.MaxParts = 320
CollapseService.Split = 4
-- Falling faster than IMPACT_MIN and losing IMPACT_DROP of it in one step is hitting hard.
CollapseService.ImpactMin, CollapseService.ImpactDrop = 9, 7
CollapseService.CrushPer, CollapseService.CrushCap = 0.004, 70
CollapseService.StrikePer, CollapseService.StrikeCap = 0.01, 220
CollapseService.BreakShare = 0.35
CollapseService.SettleSpeed, CollapseService.SettleHold, CollapseService.Timeout = 0.9, 0.6, 9
-- How hard a topple starts: turning this fast over its pivot edge.
CollapseService.ToppleSpin = 0.9
CollapseService.Enabled = true

-- Handed over by DestructibleService.Init: { breakPart(part, from), queueFx(part, from, stage),
-- tellBroken(cframe, size), damagePart(part, amount, from), roots() -> {Instance}, forget(part) }.
local api = nil
function CollapseService.Init(functions)
	api = functions
end

local active = {}
CollapseService.Active = active
-- One crush per combatant per CRUSH_GAP seconds, however many pieces land on them: a whole house
-- coming down is one hit of at most CrushCap, not one per chunk.
CollapseService.CrushGap = 2
local crushedAt = {}
CollapseService.Stats = { dropped = 0, toppled = 0, crumbled = 0, impacts = 0, crushed = 0, settled = 0, peak = 0, worstStep = 0 }

local function now()
	-- Wall clock, not os.clock (process CPU time in Roblox).
	return time()
end

-- Every piece of a chunk bursts into debris, the way breaking always looked: the fallback past the
-- budget, so nothing is ever left in the air.
local function crumble(parts)
	CollapseService.Stats.crumbled += 1
	for _, part in ipairs(parts) do
		if part.Parent then
			api.breakPart(part, nil)
		end
	end
end

local function weld(members)
	local root, biggest = nil, -1
	for _, part in ipairs(members) do
		local volume = part.Size.X * part.Size.Y * part.Size.Z
		if part.CanCollide and volume > biggest then
			root, biggest = part, volume
		end
	end
	root = root or members[1]
	local welds = {}
	for _, part in ipairs(members) do
		if part ~= root then
			local joint = Instance.new("WeldConstraint")
			joint.Name = "CollapseWeld"
			joint.Part0 = root
			joint.Part1 = part
			joint.Parent = part
			table.insert(welds, joint)
		end
	end
	return root, welds
end

local function release(members)
	for _, part in ipairs(members) do
		if part.Parent then
			if not part.CanCollide then
				-- Dressing rides along without weighing anything.
				part.Massless = true
			end
			part.Anchored = false
		end
	end
end

local function own(root)
	pcall(function()
		if root.Parent and not root.Anchored then
			root:SetNetworkOwner(nil)
		end
	end)
end

-- The box round a set of parts, axis-aligned: (centre, size).
local function boxOf(members)
	local low, high = nil, nil
	for _, part in ipairs(members) do
		if part.Parent then
			local cf, size = part.CFrame, part.Size
			local ex = (math.abs(cf.RightVector.X) * size.X + math.abs(cf.UpVector.X) * size.Y + math.abs(cf.LookVector.X) * size.Z) / 2
			local ey = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
			local ez = (math.abs(cf.RightVector.Z) * size.X + math.abs(cf.UpVector.Z) * size.Y + math.abs(cf.LookVector.Z) * size.Z) / 2
			local p = cf.Position
			local a, b = p - Vector3.new(ex, ey, ez), p + Vector3.new(ex, ey, ez)
			low = low and low:Min(a) or a
			high = high and high:Max(b) or b
		end
	end
	if not low then
		return nil
	end
	return (low + high) / 2, high - low
end

-- Drops a chunk: `parts` are its solid parts, with everything that goes with them already gathered
-- by the caller (its pools, its dressing, its panes). Returns "fell", "toppled" or "crumbled".
function CollapseService.Drop(parts, topple)
	local members = {}
	for _, part in ipairs(parts) do
		if part.Parent and part.Anchored then
			table.insert(members, part)
		end
	end
	if #members == 0 then
		return "empty"
	end
	if not CollapseService.Enabled or #active >= CollapseService.MaxAssemblies or #members > CollapseService.MaxParts then
		crumble(members)
		return "crumbled"
	end
	local origins = {}
	for _, part in ipairs(members) do
		table.insert(origins, { part.CFrame, part.Size, part.CanCollide })
		api.forget(part)
	end
	local root, welds = weld(members)
	release(members)
	own(root)
	local entry = { members = members, groups = { { root = root, welds = welds } }, origins = origins, started = now(),
		lastSpeed = {}, stillSince = nil, broke = false }
	if topple and topple.direction and topple.direction.Magnitude > 1e-3 then
		-- Rolling over the edge it leans past: spin about the horizontal axis across the lean, and
		-- the matching velocity at the centre of mass for turning about the pivot.
		local lean = Vector3.new(topple.direction.X, 0, topple.direction.Z).Unit
		local axis = Vector3.new(0, 1, 0):Cross(lean)
		local spin = axis * CollapseService.ToppleSpin
		root.AssemblyAngularVelocity = spin
		local arm = root.AssemblyCenterOfMass - (topple.pivot or root.AssemblyCenterOfMass)
		root.AssemblyLinearVelocity = spin:Cross(arm)
		CollapseService.Stats.toppled += 1
	end
	table.insert(active, entry)
	CollapseService.Stats.dropped += 1
	CollapseService.Stats.peak = math.max(CollapseService.Stats.peak, #active)
	return topple and "toppled" or "fell"
end

-- Splits an assembly into at most Split pieces along its longest axes (and re-welds each).
local function split(entry)
	local members = {}
	for _, part in ipairs(entry.members) do
		if part.Parent then
			table.insert(members, part)
		end
	end
	for _, group in ipairs(entry.groups) do
		for _, joint in ipairs(group.welds) do
			joint:Destroy()
		end
	end
	local centre, size = boxOf(members)
	if not centre then
		entry.groups = {}
		return
	end
	local axes = { { Vector3.new(1, 0, 0), size.X }, { Vector3.new(0, 1, 0), size.Y }, { Vector3.new(0, 0, 1), size.Z } }
	table.sort(axes, function(a, b)
		return a[2] > b[2]
	end)
	local buckets = {}
	for _, part in ipairs(members) do
		local offset = part.Position - centre
		local key = (offset:Dot(axes[1][1]) >= 0 and 1 or 0) + (CollapseService.Split > 2 and offset:Dot(axes[2][1]) >= 0 and 2 or 0)
		buckets[key] = buckets[key] or {}
		table.insert(buckets[key], part)
	end
	entry.groups = {}
	for _, bucket in pairs(buckets) do
		local root, welds = weld(bucket)
		own(root)
		table.insert(entry.groups, { root = root, welds = welds })
	end
end

-- A hard landing: the chunk hurts what it came down on, bursts its smallest pieces, and breaks up.
local function impact(entry, group, speed)
	CollapseService.Stats.impacts += 1
	entry.broke = true
	local mass = group.root.Parent and group.root.AssemblyMass or 0
	local centre, size = boxOf(entry.members)
	if centre then
		-- Combatants caught under or in it.
		local crush = math.min(CollapseService.CrushCap, CollapseService.CrushPer * mass * speed)
		if crush >= 1 and api.combatants then
			local low, high = centre - size / 2 - Vector3.new(1.5, 1.5, 1.5), centre + size / 2 + Vector3.new(1.5, 0.5, 1.5)
			local clock = now()
			for character, token in pairs(api.combatants()) do
				local root = character:FindFirstChild("HumanoidRootPart")
				local p = root and root.Position
				if p and p.X >= low.X and p.X <= high.X and p.Y >= low.Y and p.Y <= high.Y and p.Z >= low.Z and p.Z <= high.Z
					and (not crushedAt[character] or clock - crushedAt[character] >= CollapseService.CrushGap) then
					crushedAt[character] = clock
					if api.dealDamage then
						api.dealDamage(token, crush)
						CollapseService.Stats.crushed += 1
					end
				end
			end
		end
		-- Whatever of the map it came down on.
		local strike = math.min(CollapseService.StrikeCap, CollapseService.StrikePer * mass * speed)
		if strike >= 1 then
			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Include
			params.FilterDescendantsInstances = api.roots()
			local mine = {}
			for _, part in ipairs(entry.members) do
				mine[part] = true
			end
			local hit = {}
			for _, other in ipairs(workspace:GetPartBoundsInBox(CFrame.new(centre), size + Vector3.new(1, 1, 1), params)) do
				if not mine[other] and other.Anchored and not hit[other] then
					hit[other] = true
					api.damagePart(other, strike, centre + Vector3.new(0, size.Y, 0))
				end
			end
		end
	end
	-- Its smallest pieces go to debris; the rest breaks into at most Split tumbling pieces.
	local members = {}
	for _, part in ipairs(entry.members) do
		if part.Parent then
			table.insert(members, part)
		end
	end
	table.sort(members, function(a, b)
		return a.Size.X * a.Size.Y * a.Size.Z < b.Size.X * b.Size.Y * b.Size.Z
	end)
	local burst = math.floor(#members * CollapseService.BreakShare)
	local kept = {}
	for index, part in ipairs(members) do
		if index <= burst and #members - index >= 1 then
			api.queueFx(part, nil, 3)
			part:Destroy()
		else
			table.insert(kept, part)
		end
	end
	entry.members = kept
	split(entry)
end

-- Anchored where it lies: rubble.
local function settle(entry)
	CollapseService.Stats.settled += 1
	for _, group in ipairs(entry.groups) do
		for _, joint in ipairs(group.welds) do
			if joint.Parent then
				joint:Destroy()
			end
		end
	end
	for _, part in ipairs(entry.members) do
		if part.Parent then
			part.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
			part.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
			part.Anchored = true
			part.Massless = false
			part:SetAttribute("Rubble", true)
			api.forget(part)
		end
	end
	-- What stood where it was (loot, a supply crate, a deployable) comes down now.
	for _, origin in ipairs(entry.origins) do
		if origin[3] then
			api.tellBroken(origin[1], origin[2])
		end
	end
end

local function step()
	-- CPU spent this step (os.clock is CPU time: the cost, not a timestamp).
	local cpuAtStart = os.clock()
	local clock = now()
	for index = #active, 1, -1 do
		local entry = active[index]
		local moving = false
		local alive = false
		for gi, group in ipairs(entry.groups) do
			local root = group.root
			if root and root.Parent then
				alive = true
				local speed = root.AssemblyLinearVelocity.Magnitude
				local last = entry.lastSpeed[gi]
				if not entry.broke and last and last >= CollapseService.ImpactMin and last - speed >= CollapseService.ImpactDrop then
					impact(entry, group, last)
					break
				end
				entry.lastSpeed[gi] = speed
				if speed > CollapseService.SettleSpeed or root.AssemblyAngularVelocity.Magnitude > 0.6 then
					moving = true
				end
				if root.Position.Y < -200 then
					-- Fell out of the world somehow: gone rather than simulated forever.
					for _, part in ipairs(entry.members) do
						part:Destroy()
					end
					alive = false
				end
			end
		end
		if not alive then
			table.remove(active, index)
		else
			if moving then
				entry.stillSince = nil
			else
				entry.stillSince = entry.stillSince or clock
			end
			if (entry.stillSince and clock - entry.stillSince >= CollapseService.SettleHold) or clock - entry.started >= CollapseService.Timeout then
				settle(entry)
				table.remove(active, index)
			end
		end
	end
	CollapseService.Stats.worstStep = math.max(CollapseService.Stats.worstStep, os.clock() - cpuAtStart)
end
CollapseService.Step = step

RunService.Heartbeat:Connect(function()
	if #active > 0 then
		local ok, problem = pcall(step)
		if not ok then
			warn("[CollapseService] " .. tostring(problem))
		end
	end
end)

-- Not used by anything but the checks: how many chunks are down and moving.
function CollapseService.Count()
	return #active
end

return CollapseService
