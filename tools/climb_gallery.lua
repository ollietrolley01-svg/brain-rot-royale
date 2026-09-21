-- Cloud Climb: the physical checks and the pictures. Run with:
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/climb_gallery.lua -OutDir <folder> -TimeoutSeconds 3600
--
-- The whole run is long (the jumps alone try every jump from three takeoff spots): give it an hour.
-- A 30-minute timeout cuts it off partway through the jumps.
--
-- tools/climb_design.py proves the course on paper. This proves it in the engine, on the lobby the
-- game builds for itself (the gallery copy runs in Run mode), and prints every finding as a
-- "[BRR_Gallery] note" line:
--
--   zfight     flush faces left anywhere in the Rot Tree or the climb after the build's own pass
--   clipping   solid climb parts inside solid parts of any other lobby piece (exact shapes)
--   motion     every thorn rotor turned through a full circle and every springy limb through its
--              whole flap, checked against every other solid part at each step
--   trunk      whether a rig pressed against the trunk can stand on the steps of its taper
--   walks      a rig walking every limb you have to walk, knot to tip, without falling off
--   jumps      a rig making every jump in CloudClimbCourse.jumps, from the limb's edge, with the
--              player's own jump settings, walking or sprinting as the jump needs
--
-- then frames the tree from round the plaza and up close. SHOW_ONLY narrows the checks while
-- working on one ("jumps", say); nil runs them all.

local SHOW_ONLY = nil

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local Course = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("CloudClimbCourse"))

local BASE = MatchConfig.LobbyPosition
local WALK_SPEED = MatchConfig.BaseWalkSpeed
local SPRINT_SPEED = MatchConfig.BaseWalkSpeed * MatchConfig.SprintMultiplier

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function wanted(check)
	return SHOW_ONLY == nil or SHOW_ONLY == check
end

local function at(point)
	return BASE + Vector3.new(point[1], point[2], point[3])
end

local lobby = nil
local rigTemplate = nil

local function newRig(folder, speed)
	if not rigTemplate then
		for _ = 1, 3 do
			local ok, model = pcall(function()
				return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
			end)
			if ok and model then
				rigTemplate = model
				break
			end
			task.wait(2)
		end
	end
	local rig = rigTemplate:Clone()
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	humanoid.UseJumpPower = StarterPlayer.CharacterUseJumpPower
	humanoid.JumpPower = StarterPlayer.CharacterJumpPower
	humanoid.JumpHeight = StarterPlayer.CharacterJumpHeight
	humanoid.MaxSlopeAngle = StarterPlayer.CharacterMaxSlopeAngle
	humanoid.WalkSpeed = speed or WALK_SPEED
	rig.Parent = folder
	return rig, humanoid, rig:WaitForChild("HumanoidRootPart")
end

local function rayParamsFor(rig)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { rig }
	return params
end

-- The climb model a part belongs to ("Climb Fork 2"), or nil.
local function climbModelOf(part)
	local node = part
	while node and node ~= lobby do
		if node:IsA("Model") and string.sub(node.Name, 1, 6) == "Climb " then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- Exact geometry: a probe the shape of the part, shrunk by `shrink`, asked what solid parts it's in.
local function overlapping(part, shrink, params)
	local probe = Instance.new("Part")
	probe.Shape = part.Shape
	probe.Size = Vector3.new(math.max(0.05, part.Size.X - shrink), math.max(0.05, part.Size.Y - shrink), math.max(0.05, part.Size.Z - shrink))
	probe.CFrame = part.CFrame
	probe.Anchored = true
	probe.CanCollide = false
	probe.CanTouch = false
	probe.CanQuery = false
	probe.Transparency = 1
	probe.Parent = workspace
	local hits = workspace:GetPartsInPart(probe, params)
	probe:Destroy()
	local solid = {}
	for _, hit in ipairs(hits) do
		if hit.CanCollide and hit ~= part then
			table.insert(solid, hit)
		end
	end
	return solid
end

--------------------------------------------------------------------------------

local function checkZFight()
	local pairsFound = ZFight.Scan({ lobby })
	local mine = {}
	for _, pair in ipairs(pairsFound) do
		local ga, gb = pair.a:GetAttribute("Group"), pair.b:GetAttribute("Group")
		if ga == "CloudClimb" or gb == "CloudClimb" or ga == "Tree" or gb == "Tree" then
			table.insert(mine, pair)
		end
	end
	note(string.format("zfight: %d flush pairs in the lobby, %d involving the tree or the climb; build pass moved %s",
		#pairsFound, #mine, tostring(lobby:GetAttribute("ZFightMoved"))))
	for _, line in ipairs((ZFight.Describe(mine, function(part)
		return part:GetAttribute("Group") or "?"
	end, 12))) do
		note("zfight   " .. line)
	end
	-- What the build's own pass had to nudge in the tree and the climb: nothing is left flush, but
	-- each of these is a pattern worth tidying where it's built.
	local _, lines = ZFight.Report({ lobby }, function(part)
		return part:GetAttribute("Group") or "?"
	end, 60)
	local nudged = 0
	for _, line in ipairs(lines) do
		if string.find(line, "^CloudClimb ") or string.find(line, "^Tree ") then
			nudged += 1
			note("zfight nudged at build: " .. line)
		end
	end
	note(string.format("zfight: %d nudge patterns in the tree and the climb", nudged))
	-- Scenery is mostly plain "Part"s, so name the first few nudged climb parts by what they are.
	local shown = 0
	for _, part in ipairs(lobby:GetDescendants()) do
		if shown < 6 and part:IsA("BasePart") and part:GetAttribute("ZFixed") and part:GetAttribute("Group") == "CloudClimb" then
			shown += 1
			note(string.format("zfight nudged: %s %s %s size %s under %s, with %s, at %s", part.Name, part:IsA("Part") and part.Shape.Name or part.ClassName,
				part.Material.Name, tostring(part.Size), tostring(part.Parent and part.Parent.Name), tostring(part:GetAttribute("ZFixedWith")),
				tostring(part.Position - BASE)))
		end
	end
end

local function checkClipping()
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { lobby }
	local counts, examples, checked = {}, {}, 0
	for _, part in ipairs(lobby:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide and part:GetAttribute("Group") == "CloudClimb" then
			checked += 1
			for _, other in ipairs(overlapping(part, 0.7, params)) do
				local group = other:GetAttribute("Group")
				if group and group ~= "CloudClimb" then
					counts[group] = (counts[group] or 0) + 1
					examples[group] = examples[group]
						or string.format("%s in %s at %s", (climbModelOf(part) or part).Name, other.Name, tostring(part.Position - BASE))
				end
			end
			if checked % 100 == 0 then
				task.wait()
			end
		end
	end
	local any = false
	for group, n in pairs(counts) do
		any = true
		note(string.format("clipping: climb into %s x%d (%s)", group, n, examples[group]))
	end
	note(string.format("clipping: %d solid climb parts checked, %s", checked, any and "OVERLAPS ABOVE" or "none overlap another piece"))

	-- Every solid part of the climb, the trunk and the roots carries NoMantle (on itself or an
	-- ancestor), so ledge-grabbing can't skip a measured jump.
	local untagged, example = 0, nil
	for _, part in ipairs(lobby:GetDescendants()) do
		if part:IsA("BasePart") and part.CanCollide then
			local group = part:GetAttribute("Group")
			if group == "CloudClimb" or (group == "Tree" and (part.Name == "Trunk" or part.Name == "Root")) then
				local node, tagged = part, false
				while node and node ~= game do
					if node:GetAttribute("NoMantle") == true then
						tagged = true
						break
					end
					node = node.Parent
				end
				if not tagged then
					untagged += 1
					example = example or (part:GetFullName() .. " at " .. tostring(part.Position - BASE))
				end
			end
		end
	end
	note(string.format("mantle: %d solid climb, trunk and root parts without NoMantle%s", untagged, example and (" (" .. example .. ")") or ""))
end

-- Moves every part under `hub` as the client would at `angle` (radians about the hub's own axis).
local function pose(entries, base, axis, angle)
	local frame = base * CFrame.fromAxisAngle(axis, angle)
	for _, entry in ipairs(entries) do
		entry.part.CFrame = frame * entry.offset
	end
end

local function checkMotion()
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { lobby }
	local hubs, problems = 0, 0
	for _, hub in ipairs(lobby:GetDescendants()) do
		if hub:IsA("BasePart") and (hub.Name == "ThornRotor" or hub.Name == "SpringHinge") then
			hubs += 1
			local owner = climbModelOf(hub)
			local entries = {}
			for _, descendant in ipairs(hub:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(entries, { part = descendant, offset = hub.CFrame:ToObjectSpace(descendant.CFrame), cframe = descendant.CFrame })
				end
			end
			local base = hub.CFrame
			local axis = hub:GetAttribute("SwayAxis") == "Y" and Vector3.yAxis or Vector3.xAxis
			local angles = {}
			if hub.Name == "ThornRotor" then
				for step = 0, 47 do
					table.insert(angles, step / 48 * math.pi * 2)
				end
			else
				local amplitude = math.rad(hub:GetAttribute("SwayAngle") or 0)
				for step = -4, 4 do
					table.insert(angles, amplitude * step / 4)
				end
			end
			local hits = {}
			for _, angle in ipairs(angles) do
				pose(entries, base, axis, angle)
				for _, entry in ipairs(entries) do
					if entry.part.CanCollide then
						for _, other in ipairs(overlapping(entry.part, 0.1, params)) do
							if climbModelOf(other) ~= owner and not other:IsDescendantOf(hub) then
								local key = (climbModelOf(other) or other).Name
								hits[key] = hits[key] or string.format("%.0f deg, %s", math.deg(angle), tostring(entry.part.Position - BASE))
							end
						end
					end
				end
				task.wait()
			end
			for _, entry in ipairs(entries) do
				entry.part.CFrame = entry.cframe
			end
			for key, where in pairs(hits) do
				problems += 1
				note(string.format("motion: %s's %s hits %s (%s)", owner and owner.Name or "?", hub.Name, key, where))
			end
		end
	end
	note(string.format("motion: %d rotors and springy limbs swept, %d collisions", hubs, problems))
end

-- A rig pushed against the trunk just above each step of the taper, for two seconds.
local function checkTrunk(folder)
	local trunk = Course.trunk
	local length = trunk.height / trunk.lengths
	local stood, tried = 0, 0
	for index = 1, 8 do
		local stepY = index * length
		local upper = trunk.bottomRadius + (trunk.topRadius - trunk.bottomRadius) * index / (trunk.lengths - 1)
		for _, bearing in ipairs({ 13, 101, 187, 263 }) do
			local out = Vector3.new(math.cos(math.rad(bearing)), 0, math.sin(math.rad(bearing)))
			local spot = BASE + Vector3.new(0, stepY, 0) + out * (upper + 1.05)
			local near = workspace:GetPartBoundsInRadius(spot, 6)
			local clear = true
			for _, part in ipairs(near) do
				if climbModelOf(part) or part.Name == "Root" then
					clear = false
				end
			end
			if clear then
				tried += 1
				local rig, humanoid, root = newRig(folder)
				rig:PivotTo(CFrame.lookAt(spot + Vector3.new(0, 3.3, 0), BASE + Vector3.new(0, stepY + 3.3, 0)))
				local untilTime = os.clock() + 2
				while os.clock() < untilTime do
					humanoid:Move(-out, false)
					task.wait()
				end
				if root.Position.Y > BASE.Y + stepY + 1.5 then
					stood += 1
					note(string.format("trunk: a rig STANDS on the step at %.0f (bearing %d)", stepY, bearing))
				end
				rig:Destroy()
			end
		end
	end
	note(string.format("trunk: %d of %d rigs stayed up on a step", stood, tried))

	-- The control: the old trunk's 1-stud ledge, built well away from the lobby. If a rig can't
	-- stand on this either, the test above proves nothing.
	local origin = BASE + Vector3.new(400, 0, 400)
	local lower = Instance.new("Part")
	lower.Anchored, lower.Shape = true, Enum.PartType.Cylinder
	lower.Size = Vector3.new(20, 13, 13)
	lower.CFrame = CFrame.new(origin + Vector3.new(0, 10, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	lower.Parent = folder
	local upper = lower:Clone()
	upper.Size = Vector3.new(20, 11, 11)
	upper.CFrame = CFrame.new(origin + Vector3.new(0, 30, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	upper.Parent = folder
	local rig, humanoid, root = newRig(folder)
	local out = Vector3.xAxis
	rig:PivotTo(CFrame.lookAt(origin + Vector3.new(0, 20, 0) + out * 6.55 + Vector3.new(0, 3.3, 0), origin + Vector3.new(0, 23.3, 0)))
	local untilTime = os.clock() + 2
	while os.clock() < untilTime do
		humanoid:Move(-out, false)
		task.wait()
	end
	note(string.format("trunk control: a rig on the old 1-stud ledge %s", root.Position.Y > origin.Y + 21.5 and "stands (the test works)" or
		"fell too (THE TEST PROVES NOTHING)"))
	rig:Destroy()
end

-- Steers a rig along points (world), Move toward each in turn. Returns whether it got to the last
-- without dropping `fall` below the lowest of them, and how far it got.
local function walkRig(humanoid, root, points, fall, timeout)
	local lowest = math.huge
	for _, p in ipairs(points) do
		lowest = math.min(lowest, p.Y)
	end
	local index = 1
	local started = os.clock()
	while os.clock() - started < timeout do
		local target = points[index]
		local flat = (target - root.Position) * Vector3.new(1, 0, 1)
		if flat.Magnitude < 0.6 then
			index += 1
			if index > #points then
				humanoid:Move(Vector3.zero, false)
				return true, index - 1
			end
		else
			humanoid:Move(flat.Unit, false)
		end
		if root.Position.Y < lowest - fall then
			return false, index
		end
		task.wait()
	end
	return false, index
end

local function checkWalks(folder)
	local walked, failed = 0, 0
	for _, element in ipairs(Course.elements) do
		if element.kind == "fork" or element.kind == "bough" then
			for limbIndex, limb in ipairs(element.limbs) do
				local points = {}
				local first = limb.solidFrom
				for k = first, #limb.points do
					local p = limb.points[k]
					table.insert(points, at(p) + Vector3.new(0, p[4] / 2, 0))
				end
				if #points >= 2 then
					-- Fork limbs are walked in from the tip for the landing limb, out from the knot for the other.
					if element.kind == "fork" and limbIndex == 1 then
						local reversed = {}
						for k = #points, 1, -1 do
							table.insert(reversed, points[k])
						end
						points = reversed
					end
					local rig, humanoid, root = newRig(folder, WALK_SPEED)
					local ahead = (points[2] - points[1]) * Vector3.new(1, 0, 1)
					rig:PivotTo(CFrame.lookAt(points[1] + Vector3.new(0, 3.25, 0), points[1] + Vector3.new(0, 3.25, 0) + ahead))
					task.wait(0.5)
					local ok, reached = walkRig(humanoid, root, points, 3, 8)
					if ok then
						walked += 1
					else
						failed += 1
						note(string.format("walks: fell off %s limb %d before point %d of %d (at %s)", element.name, limbIndex, reached, #points,
							tostring(root.Position - BASE)))
					end
					rig:Destroy()
				end
			end
		end
	end
	note(string.format("walks: %d limbs walked end to end, %d fell off", walked, failed))
end

-- Scenery sitting where you'd stand: leaves, twigs or knots in the space a body takes up above a
-- walkable part of any limb. Harmless to the physics, but a leaf ball on the tip you're aiming at
-- hides the target.
--
-- Worked out from the parts' shapes rather than asked of the engine: scenery is CanQuery false, so
-- spatial queries can't see it at all. (The first version of this check asked them, and reported
-- nothing in the way whatever was there.)
local function checkClutter()
	-- Walkways: the top line of every solid limb cylinder.
	local walks = {}
	for _, part in ipairs(lobby:GetDescendants()) do
		if part:IsA("Part") and part.CanCollide and part.Name == "ClimbBranch" and part.Shape == Enum.PartType.Cylinder then
			local half = part.CFrame.XVector * part.Size.X / 2
			local lift = Vector3.new(0, part.Size.Y / 2, 0)
			table.insert(walks, { a = part.Position - half + lift, b = part.Position + half + lift, owner = climbModelOf(part) })
		end
	end
	-- Scenery as spheres: a ball as itself, a cylinder as three along its axis, anything else as the
	-- sphere inside its smallest side. In the way if it's within a body's width of a walkway, from
	-- the walking surface up to head height.
	local function inTheWay(centre, radius)
		for _, walk in ipairs(walks) do
			local ab = (walk.b - walk.a) * Vector3.new(1, 0, 1)
			local t = ab.Magnitude > 1e-3 and math.clamp(((centre - walk.a) * Vector3.new(1, 0, 1)):Dot(ab) / ab:Dot(ab), 0, 1) or 0
			local surface = walk.a:Lerp(walk.b, t)
			local flat = ((centre - surface) * Vector3.new(1, 0, 1)).Magnitude
			if flat < radius + 0.45 and centre.Y + radius > surface.Y + 0.35 and centre.Y - radius < surface.Y + 4.6 then
				return walk
			end
		end
		return nil
	end
	local counts, examples, checked = {}, {}, 0
	for _, part in ipairs(lobby:GetDescendants()) do
		local group = part:IsA("BasePart") and part:GetAttribute("Group")
		local model = group and climbModelOf(part)
		-- A rotor is meant to be in the way; its knot and twig are checked, its sweep isn't.
		local sweeping = part.Parent and part.Parent:IsA("BasePart") and part.Parent.Name == "ThornRotor" or part.Name == "ThornRotor"
		if (group == "CloudClimb" or group == "Tree") and not part.CanCollide and part.Transparency < 0.9
			and part.Name ~= "BranchScenery" and part.Name ~= "Canopy" and not sweeping and not (model and model.Name == "Climb Thorn Wheel") then
			checked += 1
			local spheres = {}
			if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
				spheres = { { part.Position, part.Size.X / 2 } }
			elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
				local half = part.CFrame.XVector * part.Size.X / 2
				spheres = { { part.Position - half, part.Size.Y / 2 }, { part.Position, part.Size.Y / 2 }, { part.Position + half, part.Size.Y / 2 } }
			else
				spheres = { { part.Position, math.min(part.Size.X, part.Size.Y, part.Size.Z) / 2 } }
			end
			for _, sphere in ipairs(spheres) do
				local walk = inTheWay(sphere[1], sphere[2])
				if walk then
					local owner = climbModelOf(part)
					local key = (owner and owner.Name or group) .. "/" .. part.Name .. "/" .. part.Material.Name
					counts[key] = (counts[key] or 0) + 1
					examples[key] = examples[key] or string.format("%s, over %s", tostring(sphere[1] - BASE), walk.owner and walk.owner.Name or "?")
					break
				end
			end
			if checked % 150 == 0 then
				task.wait()
			end
		end
	end
	local total = 0
	for key, n in pairs(counts) do
		total += n
		note(string.format("clutter: %s x%d over a walkway (%s)", key, n, examples[key]))
	end
	note(string.format("clutter: %d walkway segments, %d scenery parts checked, %d in the way", #walks, checked, total))
end

-- The server never turns the rotors (the client does), so on the server every arm is frozen in
-- one pose, possibly right over a takeoff. In play they're timing hazards that sweep past; for
-- the walks and jumps they're taken out, and put back after.
local function withoutRotors(check)
	return function(...)
		local arms = {}
		for _, part in ipairs(lobby:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "ThornArm" and part.CanCollide then
				part.CanCollide = false
				table.insert(arms, part)
			end
		end
		local ok, err = pcall(check, ...)
		for _, part in ipairs(arms) do
			part.CanCollide = true
		end
		if not ok then
			error(err, 0)
		end
	end
end

local function checkJumps(folder)
	local made, missed, allThree = 0, 0, 0
	for _, jump in ipairs(Course.jumps) do
		local targetName = string.match(jump.name, "%-> (.+)$")
		local from, to = at(jump.from), at(jump.to)
		local success, detail, takeoffs = false, "", 0
		for attempt = 1, 3 do
			local rig, humanoid, root = newRig(folder, jump.sprint and SPRINT_SPEED or WALK_SPEED)
			local params = rayParamsFor(rig)
			local flat = (to - from) * Vector3.new(1, 0, 1)
			-- Most takeoffs here are sideways off a narrow limb, so there's no run-up: a step and a
			-- jump. Start a quarter stud back and jump from well on the limb, not its very edge,
			-- where a sprinting rig covers 0.4 studs a frame and can step off before the jump fires.
			-- Each attempt jumps from a little further out: the spot itself, then a quarter and
			-- half of the way to the edge.
			local start = from - flat.Unit * 0.25
			rig:PivotTo(CFrame.lookAt(start + Vector3.new(0, 3.25, 0), start + Vector3.new(0, 3.25, 0) + flat))
			task.wait(0.6)
			if root.Position.Y < from.Y + 1.5 then
				detail = "couldn't stand at the takeoff spot"
			else
				local jumped, airborne, landedAt = false, false, nil
				local startedAt = os.clock()
				local edge = (attempt - 1) * 0.25 * jump.fromWidth / 2
				while os.clock() - startedAt < 4 do
					local toFlat = (to - root.Position) * Vector3.new(1, 0, 1)
					local fromFlat = (root.Position - from) * Vector3.new(1, 0, 1)
					if landedAt then
						humanoid:Move(Vector3.zero, false)
						if os.clock() - landedAt > 0.5 then
							break
						end
					elseif toFlat.Magnitude > 0.3 then
						humanoid:Move(toFlat.Unit, false)
					else
						humanoid:Move(Vector3.zero, false)
					end
					if not jumped and fromFlat:Dot(flat.Unit) >= edge then
						jumped = true
						humanoid.Jump = true
					end
					local state = humanoid:GetState()
					if jumped and (state == Enum.HumanoidStateType.Freefall or state == Enum.HumanoidStateType.Jumping) then
						airborne = true
					elseif airborne and not landedAt and (state == Enum.HumanoidStateType.Landed or state == Enum.HumanoidStateType.Running
						or humanoid.FloorMaterial ~= Enum.Material.Air) then
						landedAt = os.clock()
					end
					if root.Position.Y < math.min(from.Y, to.Y) - 12 then
						break
					end
					task.wait()
				end
				-- What's under the feet: a box as wide as the body rather than one ray from its middle,
				-- which misses a thin limb a body is standing on by its edge.
				local feet = OverlapParams.new()
				feet.FilterType = Enum.RaycastFilterType.Exclude
				feet.FilterDescendantsInstances = { rig }
				local under = workspace:GetPartBoundsInBox(root.CFrame * CFrame.new(0, -3.4, 0), Vector3.new(2.2, 1.4, 1.6), feet)
				local onTarget, standingOn = false, nil
				for _, piece in ipairs(under) do
					if piece.CanCollide then
						local model = climbModelOf(piece)
						standingOn = standingOn or (model and model.Name) or piece.Name
						if (model and model.Name == "Climb " .. targetName) or (targetName == "Summit" and piece.Name == "SummitDisc") then
							onTarget = true
						end
					end
				end
				if landedAt and onTarget and humanoid.FloorMaterial ~= Enum.Material.Air then
					success = true
					takeoffs += 1
				else
					detail = string.format("from takeoff %d landed %s on %s (floor %s) at %s", attempt, tostring(landedAt ~= nil),
						standingOn or "nothing", humanoid.FloorMaterial.Name, tostring(root.Position - BASE))
				end
			end
			rig:Destroy()
		end
		if success then
			made += 1
			if takeoffs < 3 then
				-- Made, but not from every spot: a jump near the edge of what's possible.
				note(string.format("jumps: %s (%s, %.2f of reach) made from %d of 3 takeoff spots; missed %s", jump.name,
					jump.sprint and "sprint" or "walk", jump.share, takeoffs, detail))
			end
			allThree += takeoffs == 3 and 1 or 0
		else
			missed += 1
			note(string.format("jumps: MISSED %s (%s, %.2f of reach): %s", jump.name, jump.sprint and "sprint" or "walk", jump.share, detail))
		end
	end
	note(string.format("jumps: a rig made %d of %d, %d of them from all three takeoff spots", made, #Course.jumps, allThree))
end

--------------------------------------------------------------------------------

local views = {}

table.insert(views, {
	name = "climb_checks",
	settle = 0.5,
	hold = 0.5,
	setup = function(folder, camera)
		if not RunService:IsRunning() then
			RunService:Run()
		end
		local waited = os.clock()
		while os.clock() - waited < 120 do
			lobby = workspace:FindFirstChild("Lobby")
			if lobby and lobby:GetAttribute("ZFightMoved") ~= nil and lobby:FindFirstChild("SkyWalkSummit", true) then
				break
			end
			task.wait(1)
		end
		if not (lobby and lobby:FindFirstChild("SkyWalkSummit", true)) then
			note("the lobby never finished building; nothing to check")
			return
		end
		task.wait(2)
		local climbParts = 0
		for _, part in ipairs(lobby:GetDescendants()) do
			if part:IsA("BasePart") and part:GetAttribute("Group") == "CloudClimb" then
				climbParts += 1
			end
		end
		note(string.format("lobby built: %d parts, %d of them the climb", #lobby:GetDescendants(), climbParts))
		for _, check in ipairs({
			{ "zfight", checkZFight }, { "clipping", checkClipping }, { "clutter", checkClutter }, { "motion", checkMotion },
			{ "trunk", checkTrunk }, { "walks", withoutRotors(checkWalks) }, { "jumps", withoutRotors(checkJumps) },
		}) do
			if wanted(check[1]) then
				local ok, err = pcall(check[2], folder)
				if not ok then
					note(check[1] .. " check failed: " .. tostring(err))
				end
			end
		end
		camera.CFrame = CFrame.lookAt(BASE + Vector3.new(90, 60, 90), BASE + Vector3.new(0, 55, 0))
	end,
})

local function view(name, eye, target, fov)
	table.insert(views, {
		name = name,
		settle = 1.5,
		setup = function(_, camera)
			camera.FieldOfView = fov or 60
			camera.CFrame = CFrame.lookAt(BASE + eye, BASE + target)
		end,
	})
end

-- Close-ups framed off the course data, so they follow the course when it changes.
local function element(name)
	for _, entry in ipairs(Course.elements) do
		if entry.name == name then
			return entry
		end
	end
end
local function tipOf(name, limbIndex)
	local limbs = element(name).limbs
	local limb = limbs[limbIndex or #limbs]
	local p = limb.points[#limb.points]
	return Vector3.new(p[1], p[2], p[3])
end
local function closeUp(name, target, distance, lift, fov)
	local flat = Vector3.new(target.X, 0, target.Z)
	local out = flat.Magnitude > 1 and flat.Unit or Vector3.xAxis
	local side = Vector3.new(-out.Z, 0, out.X)
	view(name, target + out * distance + side * distance * 0.55 + Vector3.new(0, lift, 0), target, fov or 55)
end

closeUp("close_fork_knot", Vector3.new(element("Fork 2").balls[1][1], element("Fork 2").balls[1][2], element("Fork 2").balls[1][3]), 12, 4)
closeUp("close_fork_tips", tipOf("Fork 2", 2), 9, 3)
closeUp("close_deadwood_fork", tipOf("Fork 3", 2), 10, 3)
closeUp("close_bough", tipOf("The Long Bough", 1), 14, 5)
closeUp("close_crown_limb", tipOf("Needle"), 9, 3)
closeUp("close_crown_deadwood", tipOf("Deadfall"), 9, 2)
closeUp("close_crown_rotor", tipOf("Thornguard"), 10, 5)
closeUp("close_checkpoint_3", tipOf("Crow's Rest"), 10, 4)
view("course_eye_from_fork_1", Vector3.new(-12, 22, -14), Vector3.new(6, 26, -10), 70)

view("tree_wide_southeast", Vector3.new(78, 38, 92), Vector3.new(0, 58, 0), 60)
view("tree_wide_west", Vector3.new(-96, 30, -18), Vector3.new(0, 55, 0), 60)
view("start_sign_lantern", Vector3.new(-50, 9, 42), Vector3.new(-26, 4, 12), 55)
view("forks_low", Vector3.new(30, 16, -28), Vector3.new(0, 20, 0), 60)
view("forks_high", Vector3.new(-28, 30, 30), Vector3.new(0, 38, 0), 60)
view("thorn_wheel_and_bough", Vector3.new(34, 40, -34), Vector3.new(8, 50, -8), 60)
view("crown_side", Vector3.new(72, 92, 28), Vector3.new(20, 86, 12), 60)
view("crown_back", Vector3.new(-62, 104, 54), Vector3.new(-16, 100, 16), 60)
view("summit", Vector3.new(-26, 132, 26), Vector3.new(0, 117, 0), 60)
view("top_down", Vector3.new(0.5, 230, 0), Vector3.new(0, 0, 0), 60)

return views
