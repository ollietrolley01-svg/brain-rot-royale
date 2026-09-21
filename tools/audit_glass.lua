-- Window glass audit, for tools/runtest.ps1 -Probe (one map per run: edit MAP_ID and SEED below).
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/audit_glass.lua
--
-- Builds the map from a fixed seed and measures the panes MapBuildings puts in every window:
--   count        panes, and parts added to the map by them
--   fit          each pane attached to exactly four wall parts (two piers, the sill band, the lintel)
--                and nothing solid of the building except those; a ray square through its centre
--                meets the pane first and, past it, open air to the room inside
--   z-fight      ZFight.Scan over every town with panes in: flush pairs, and any involving glass
--   shots        CombatService's own hooks (DestructibleFromPart, DamageDestructible,
--                DestructiblePassesThrough) driven the way firePellet drives them, from outside a
--                pane to a target part inside: the pane breaks and the shot reaches the target.
--                (firePellet itself needs a live player, which the harness can't provide.)
--   bots         CombatService.BreakGlassAlong from outside a pane to a point inside breaks it
--   blasts       CombatService.DamageDestructiblesInRadius at a window: every pane in reach goes,
--                walls at that damage stay
--   walls        breaking a wall part takes exactly the panes and trim attached to it, no others
-- Edit mode has no clients, so the GlassShatter event can't be delivered here; the gallery
-- (tools/audit_glass_gallery.lua) exercises the client shards and their cap.

local MAP_ID, SEED = "SahurSprings", 101
local SAMPLE = 40

local RS = game:GetService("ReplicatedStorage")
local LogService = game:GetService("LogService")
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local CombatService = require(modules:WaitForChild("CombatService"))
local DestructibleService = require(modules:WaitForChild("DestructibleService"))
local ZFight = require(RS:WaitForChild("Shared"):WaitForChild("ZFight"))

local function out(fmt, ...)
	print("[AUDIT glass] " .. string.format(fmt, ...))
end
local function v3(v)
	return string.format("(%.1f,%.1f,%.1f)", v.X, v.Y, v.Z)
end

local remoteErrors = 0
local logConnection = LogService.MessageOut:Connect(function(message, messageType)
	if messageType == Enum.MessageType.MessageError and string.find(message, "GlassShatter", 1, true) then
		remoteErrors += 1
	end
end)

-- Same box test DestructibleService uses: other's box along part's axes, within margin.
local function attached(part, other, margin)
	local relative = part.CFrame:ToObjectSpace(other.CFrame)
	local half = other.Size / 2
	local x, y, z = relative.XVector, relative.YVector, relative.ZVector
	local reach = part.Size / 2 + Vector3.new(margin, margin, margin) + Vector3.new(
		math.abs(x.X) * half.X + math.abs(y.X) * half.Y + math.abs(z.X) * half.Z,
		math.abs(x.Y) * half.X + math.abs(y.Y) * half.Y + math.abs(z.Y) * half.Z,
		math.abs(x.Z) * half.X + math.abs(y.Z) * half.Y + math.abs(z.Z) * half.Z
	)
	local offset = relative.Position
	return math.abs(offset.X) <= reach.X and math.abs(offset.Y) <= reach.Y and math.abs(offset.Z) <= reach.Z
end

math.randomseed(SEED)
local started = os.clock()
local info = MapGenerator.Build(MAP_ID)
task.wait(1.5)
local map = workspace.Map
out("%s seed %d built in %.1fs; build z-fight pass remaining %d", MAP_ID, SEED, os.clock() - started, info.zfight and #info.zfight.remaining or -1)

-- Count.
local panes, towns, mapParts = {}, {}, 0
local byArchetype = {}
for _, d in ipairs(map:GetDescendants()) do
	if d:IsA("BasePart") then
		mapParts += 1
		if d.Name == DestructibleService.GlassName then
			table.insert(panes, d)
			local building = d.Parent
			byArchetype[building.Name] = (byArchetype[building.Name] or 0) + 1
			towns[building.Parent] = true
		end
	end
end
local archetypes = {}
for name, n in pairs(byArchetype) do
	table.insert(archetypes, name .. " " .. n)
end
table.sort(archetypes)
out("panes %d (%s); map parts %d, so glass is %.1f%% of them", #panes, table.concat(archetypes, ", "), mapParts, #panes / math.max(1, mapParts) * 100)

-- Fit.
local badAttach, badSolid, badRay, attachHistogram = 0, 0, 0, {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
for index, pane in ipairs(panes) do
	local walls, others = 0, {}
	for _, other in ipairs(pane.Parent:GetChildren()) do
		if other ~= pane and other:IsA("BasePart") and other.CanCollide and attached(pane, other, 0.02) then
			if other.Name == "Wall" then
				walls += 1
			else
				others[other.Name] = true
			end
		end
	end
	attachHistogram[walls] = (attachHistogram[walls] or 0) + 1
	if walls ~= 4 then
		badAttach += 1
		if badAttach <= 5 then
			out("  fit: pane at %s touches %d wall parts", v3(pane.Position), walls)
		end
	end
	local list = {}
	for name in pairs(others) do
		table.insert(list, name)
	end
	if #list > 0 then
		badSolid += 1
		if badSolid <= 8 then
			out("  fit: pane at %s in %s also touches solid %s", v3(pane.Position), pane.Parent.Name, table.concat(list, ", "))
		end
	end
	-- Square through the centre from 2 studs out: the pane first, then nothing of the building
	-- within 2 studs past it.
	rayParams.FilterDescendantsInstances = { pane.Parent }
	local outside = pane.Position + pane.CFrame.LookVector * 2
	local first = workspace:Raycast(outside, -pane.CFrame.LookVector * 2.2, rayParams)
	rayParams.FilterDescendantsInstances = { pane.Parent }
	local behind = nil
	if first and first.Instance == pane then
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		local filterList = {}
		for _, other in ipairs(pane.Parent:GetChildren()) do
			if other ~= pane and other:IsA("BasePart") and (other.Name == "Wall" or other.Name == "Floor") then
				table.insert(filterList, other)
			end
		end
		params.FilterDescendantsInstances = filterList
		behind = workspace:Raycast(pane.Position + pane.CFrame.LookVector * 0.15, -pane.CFrame.LookVector * 2, params)
	end
	if not first or first.Instance ~= pane or behind then
		badRay += 1
		if badRay <= 5 then
			out("  fit: centre ray at pane %s (%s): first %s, %s %s behind it %.2f in, size %s", v3(pane.Position), pane.Parent.Name,
				first and first.Instance.Name or "nothing", behind and behind.Instance.Name or "nothing",
				behind and v3(behind.Instance.Position) or "", behind and (behind.Position - pane.Position).Magnitude or 0,
				behind and v3(behind.Instance.Size) or "")
		end
	end
	if index % 200 == 0 then
		task.wait()
	end
end
local histogram = {}
for walls, n in pairs(attachHistogram) do
	table.insert(histogram, walls .. " walls: " .. n)
end
table.sort(histogram)
out("fit: %d panes not touching exactly 4 wall parts [%s]; %d touching other solid parts; %d failing the centre ray",
	badAttach, table.concat(histogram, ", "), badSolid, badRay)

-- Z-fight over every town that has glass.
local roots = {}
for town in pairs(towns) do
	table.insert(roots, town)
end
local flushPairs = ZFight.Scan(roots)
local glassPairs = 0
for _, pair in ipairs(flushPairs) do
	local a, b = pair.a or pair[1], pair.b or pair[2]
	local an = typeof(a) == "Instance" and a.Name or (type(a) == "table" and a.part and a.part.Name) or ""
	local bn = typeof(b) == "Instance" and b.Name or (type(b) == "table" and b.part and b.part.Name) or ""
	if an == DestructibleService.GlassName or bn == DestructibleService.GlassName then
		glassPairs += 1
	end
end
out("z-fight: %d flush pairs over %d towns, %d involving glass%s", #flushPairs, #roots, glassPairs,
	#flushPairs > 0 and (" [" .. table.concat(ZFight.Describe(flushPairs, function(p) return p.Parent and p.Parent.Name or "?" end, 6), " | ") .. "]") or "")
-- The scan above runs after MapGenerator.Build's own z-fight pass, which has already pushed any flush
-- pair apart, so a zero there proves little. What the pass had to do to glass is the measure: panes it
-- moved or resized, and anything it moved because of a pane (ZFixed / ZFixedWith on the part).
local panesNudged, nudgedForGlass, nudgedFar = 0, 0, 0
for town in pairs(towns) do
	for _, d in ipairs(town:GetDescendants()) do
		if d:IsA("BasePart") and d:GetAttribute("ZFixed") then
			if d.Name == DestructibleService.GlassName then
				panesNudged += 1
				nudgedFar = math.max(nudgedFar, d:GetAttribute("ZFixed"))
			elseif d:GetAttribute("ZFixedWith") == DestructibleService.GlassName then
				nudgedForGlass += 1
				nudgedFar = math.max(nudgedFar, d:GetAttribute("ZFixed"))
			end
		end
	end
end
out("z-fight pass on glass: %d panes moved or resized, %d other parts moved because of a pane (largest %.3f)", panesNudged, nudgedForGlass,
	nudgedFar)

-- Sample panes spread evenly through the list. Each test takes its own stretch of the list and
-- skips any pane an earlier test already broke, so a building can supply several.
local samples = {}
local step = math.max(1, math.floor(#panes / (SAMPLE * 4)))
for index = 1, #panes, step do
	table.insert(samples, panes[index])
end
local function stretch(first, count)
	local list = {}
	for index = first, math.min(#samples, first + count - 1) do
		if samples[index].Parent then
			table.insert(list, samples[index])
		end
	end
	return list
end

-- Shots: firePellet's loop over the real hooks.
local targets = Instance.new("Folder")
targets.Name = "AuditGlassTargets"
targets.Parent = workspace
local shotOk, shotFail, shotsTried = 0, 0, 0
for _, pane in ipairs(stretch(1, SAMPLE)) do
	if pane.Parent then
		shotsTried += 1
		local inward = -pane.CFrame.LookVector
		local target = Instance.new("Part")
		target.Name = "Target"
		target.Anchored = true
		target.Size = Vector3.new(1, 1, 1)
		target.Position = pane.Position + inward * 1.6
		target.Parent = targets
		local origin = pane.Position - inward * 2.4 + Vector3.new(0, 0.3, 0)
		local direction = (target.Position - origin).Unit
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = {}
		local current, travelled, finalHit, brokePane = origin, 0, nil, false
		for _ = 1, 6 do
			local result = workspace:Raycast(current, direction * (40 - travelled), params)
			if not result then
				break
			end
			travelled += (result.Position - current).Magnitude
			local destructible = CombatService.DestructibleFromPart and CombatService.DestructibleFromPart(result.Instance)
			if destructible then
				CombatService.DamageDestructible(nil, destructible, 18)
				if CombatService.DestructiblePassesThrough(result.Instance) then
					brokePane = brokePane or result.Instance == pane
					local filter = params.FilterDescendantsInstances
					table.insert(filter, result.Instance)
					params.FilterDescendantsInstances = filter
					current = result.Position + direction * 0.05
					continue
				end
			end
			finalHit = result.Instance
			break
		end
		if brokePane and pane.Parent == nil and finalHit == target then
			shotOk += 1
		else
			shotFail += 1
			if shotFail <= 5 then
				out("  shot: pane %s broke %s, pane gone %s, shot stopped at %s", v3(pane.Position), tostring(brokePane), tostring(pane.Parent == nil),
					finalHit and finalHit:GetFullName() or "nothing")
			end
		end
		target:Destroy()
	end
end
out("shots: %d tried, %d broke the pane and reached the target behind it, %d did not", shotsTried, shotOk, shotFail)

-- Bots: BreakGlassAlong.
local botOk, botTried = 0, 0
for _, pane in ipairs(stretch(SAMPLE + 1, SAMPLE)) do
	if pane.Parent then
		botTried += 1
		local inward = -pane.CFrame.LookVector
		CombatService.BreakGlassAlong(nil, pane.Position - inward * 2.4, pane.Position + inward * 1.6)
		if pane.Parent == nil then
			botOk += 1
		end
	end
end
out("bot shots: %d tried, %d panes broken by BreakGlassAlong", botTried, botOk)

-- A shot that passes close by a pane without crossing it (0.4 studs outside the wall face, along
-- the wall) must leave it alone; and with no glass around, a call is one short raycast.
local nearTried, nearBroken = 0, 0
for _, pane in ipairs(stretch(SAMPLE * 2 + 1, 20)) do
	if pane.Parent then
		nearTried += 1
		local outward, right = pane.CFrame.LookVector, pane.CFrame.RightVector
		local lane = pane.Position + outward * 1.1
		CombatService.BreakGlassAlong(nil, lane - right * 8, lane + right * 8)
		if pane.Parent == nil then
			nearBroken += 1
		end
	end
end
local clock = os.clock()
for _ = 1, 2000 do
	CombatService.BreakGlassAlong(nil, Vector3.new(0, 900, 0), Vector3.new(60, 905, 40))
end
out("near misses: %d shots passing a pane 1.1 studs off-centre (0.4 outside the wall face), %d panes broken (want 0); open-air call %.1f microseconds",
	nearTried, nearBroken, (os.clock() - clock) / 2000 * 1e6)

-- Blasts: a rocket's splash (12 studs, 60 damage) just outside a window.
local blastPanesInReach, blastPanesGone, blastWallsInReach, blastWallsGone, blasts = 0, 0, 0, 0, 0
local blastCentres = {}
for _, pane in ipairs(stretch(SAMPLE * 3 + 1, SAMPLE)) do
	-- Blasts at least 40 studs apart, so no wall takes two of them.
	local clear = pane.Parent ~= nil and blasts < 10
	for _, centre in ipairs(blastCentres) do
		if (centre - pane.Position).Magnitude < 40 then
			clear = false
		end
	end
	if clear then
		table.insert(blastCentres, pane.Position)
		blasts += 1
		local at = pane.Position + pane.CFrame.LookVector * 1.5
		local region = OverlapParams.new()
		region.FilterType = Enum.RaycastFilterType.Include
		region.FilterDescendantsInstances = { map }
		local inReach = workspace:GetPartBoundsInRadius(at, 12, region)
		local watchPanes, watchWalls = {}, {}
		for _, part in ipairs(inReach) do
			if part.Name == DestructibleService.GlassName then
				table.insert(watchPanes, part)
			elseif part.Name == "Wall" and DestructibleService.FromPart(part) then
				table.insert(watchWalls, part)
			end
		end
		CombatService.DamageDestructiblesInRadius(at, 12, 60, nil)
		blastPanesInReach += #watchPanes
		blastWallsInReach += #watchWalls
		for _, part in ipairs(watchPanes) do
			if part.Parent == nil then
				blastPanesGone += 1
			end
		end
		for _, part in ipairs(watchWalls) do
			if part.Parent == nil then
				blastWallsGone += 1
			end
		end
	end
end
out("blasts: %d at windows; panes in reach %d, broken %d; undamaged walls in reach %d, broken %d (want 0: 60 < 100)",
	blasts, blastPanesInReach, blastPanesGone, blastWallsInReach, blastWallsGone)

-- Walls: break a wall part beside a pane and see what goes with it.
local wallTests, panesExpected, panesGone, panesWrong, trimExpected, trimGone, trimWrong = 0, 0, 0, 0, 0, 0, 0
local picked = {}
for _, pane in ipairs(panes) do
	if wallTests >= 12 then
		break
	end
	if pane.Parent and not picked[pane.Parent] then
		local wall = nil
		for _, other in ipairs(pane.Parent:GetChildren()) do
			if other.Name == "Wall" and other:IsA("BasePart") and attached(pane, other, 0.02) and DestructibleService.FromPart(other) then
				wall = other
				break
			end
		end
		if wall then
			picked[pane.Parent] = true
			wallTests += 1
			local building = pane.Parent
			-- Trim held up, directly or through other held trim, by something solid.
			local function heldTrim()
				local solids, trims = {}, {}
				for _, other in ipairs(building:GetChildren()) do
					if other:IsA("BasePart") and other.Name ~= "Rubble" then
						if other.CanCollide and other.Name ~= DestructibleService.GlassName then
							table.insert(solids, other)
						elseif not other.CanCollide and not other.CanQuery then
							table.insert(trims, other)
						end
					end
				end
				local held, frontier = {}, {}
				for _, trim in ipairs(trims) do
					for _, solid in ipairs(solids) do
						if attached(solid, trim, 0.35) then
							held[trim] = true
							table.insert(frontier, trim)
							break
						end
					end
				end
				while #frontier > 0 do
					local current = table.remove(frontier)
					for _, trim in ipairs(trims) do
						if not held[trim] and attached(current, trim, 0.35) then
							held[trim] = true
							table.insert(frontier, trim)
						end
					end
				end
				return held, trims
			end
			local heldBefore, trimsBefore = heldTrim()
			local expectPane, otherPanes = {}, {}
			for _, other in ipairs(building:GetChildren()) do
				if other ~= wall and other.Name == DestructibleService.GlassName then
					table.insert(attached(wall, other, 0.02) and expectPane or otherPanes, other)
				end
			end
			DestructibleService.Damage(wall, 10000, nil)
			task.wait()
			local heldAfter, trimsAfter = heldTrim()
			panesExpected += #expectPane
			for _, part in ipairs(expectPane) do
				if part.Parent == nil then
					panesGone += 1
				end
			end
			for _, part in ipairs(otherPanes) do
				if part.Parent == nil then
					panesWrong += 1
				end
			end
			-- Floating now that wasn't before: trim still there but no longer held.
			for _, trim in ipairs(trimsAfter) do
				if heldBefore[trim] and not heldAfter[trim] then
					trimWrong += 1
					if trimWrong <= 6 then
						out("  walls: %s left floating at %s", trim.Name, v3(trim.Position))
					end
				end
			end
			-- Removed although a solid part that remains still holds it.
			for _, trim in ipairs(trimsBefore) do
				if trim.Parent == nil then
					trimGone += 1
					for _, other in ipairs(building:GetChildren()) do
						if other:IsA("BasePart") and other.CanCollide and other.Name ~= DestructibleService.GlassName and other.Name ~= "Rubble"
							and attached(other, trim, 0.35) then
							trimExpected += 1
							if trimExpected <= 6 then
								out("  walls: %s removed though %s still holds it", trim.Name, other.Name)
							end
							break
						end
					end
				end
			end
		end
	end
end
out("walls: %d wall parts broken; panes set in them %d, shattered %d; other panes lost %d (want 0); trim removed %d, of which still held by a solid %d (want 0); trim left floating %d (want 0)",
	wallTests, panesExpected, panesGone, panesWrong, trimGone, trimExpected, trimWrong)

task.wait(0.5)
out("GlassShatter errors in the log: %d (edit mode has no clients; a 'can only be called from the server' error here is the harness, not the game)", remoteErrors)
logConnection:Disconnect()
targets:Destroy()
MapGenerator.Clear()
pcall(flush)
