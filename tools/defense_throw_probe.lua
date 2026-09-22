-- Defense throw-origin probe: a thrown kit must never start on the far side of a wall.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/defense_throw_probe.lua
--
-- The exploit this pins (2026-09-22): DefenseService.throwKit used to spawn the kit two studs in
-- front of the head with no clip, so a player pressed against a 1.4-stud building wall put it on the
-- wall's INNER face, where it settled and built or armed -- a 95-damage Rot Mine inside a room nobody
-- could reach. Both the server's throw and the client's ghost now take their origin from
-- DefensePlacement.ThrowOrigin, which clips the segment head -> spawn against solid geometry.
--
-- Checked, for wall gaps 0.3, 0.9 (exactly ThrowSkin) and 2.0:
--   * the origin is on the NEAR side of the wall, by the wall's own half-thickness;
--   * it never sits further from the head than the unclipped point would;
--   * a ball of the kit's own size at that origin does not reach through the wall;
--   * the UNCLIPPED formula is beyond the wall wherever the clip had work to do (the planted fault:
--     if this ever stops firing, the case no longer tests anything);
--   * DefensePreview.Site's `from` is the same point, so the ghost cannot drift from the throw.
-- A CanCollide-false pane would not clip a throw at all (RespectCanCollide), so the built window's
-- glass is checked to be solid.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local DefensePlacement = require(Shared:WaitForChild("DefensePlacement"))
local DestructibleService = require(ServerScriptService:WaitForChild("Modules"):WaitForChild("DestructibleService"))

local V = Vector3.new
local ORIGIN = V(7000, 3000, 7000)
local problems = 0

local function say(text)
	print("[defense_throw_probe] " .. text)
end
local function problem(text)
	problems += 1
	say("PROBLEM " .. text)
end
local function fmt(n)
	return string.format("%.2f", n)
end

local lane = Instance.new("Model")
lane.Name = "DefenseThrowProbe"
lane.Parent = workspace

local function block(name, size, position, collide)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Position = position
	part.Anchored = true
	part.CanCollide = collide ~= false
	part.Parent = lane
	return part
end

-- A stand-in: a head at standing height looking down +X, and a wall `gap` studs in front of it.
local WALL_THICK = 1.4
local KIT = 1.5 -- the kit model's widest dimension at its throw scale (ItemModels scale 1.5)

for _, gap in ipairs({ 0.3, 0.9, 2.0 }) do
	local headPosition = ORIGIN + V(gap * 20, 0, 0)
	local look = V(1, 0, 0)
	local wallX = headPosition.X + gap + WALL_THICK / 2
	local wall = block("ProbeWall", V(WALL_THICK, 12, 12), V(wallX, headPosition.Y, headPosition.Z))
	local nearFace = wallX - WALL_THICK / 2

	local origin = DefensePlacement.ThrowOrigin(nil, headPosition, look)
	local unclipped = headPosition + look * DefensePlacement.ThrowLead + V(0, DefensePlacement.ThrowLift, 0)
	local reach = origin.X + KIT / 2
	say(string.format("gap %.1f: origin x %s (head %s, near face %s, unclipped x %s); kit's far edge %s",
		gap, fmt(origin.X), fmt(headPosition.X), fmt(nearFace), fmt(unclipped.X), fmt(reach)))
	if origin.X > nearFace then
		problem(string.format("gap %.1f: the origin is THROUGH the wall (%s past the near face)", gap, fmt(origin.X - nearFace)))
	end
	-- Behind the head is ALLOWED and is the intended answer when there is no room in front for a kit
	-- this wide: it is inside the thrower's own body, which physics resolves against the thrower, on
	-- their side of the wall. Never further back than the kit is deep, though, or it would start
	-- inside whatever is behind them.
	if origin.X < headPosition.X - DefensePlacement.ThrowSkin - 0.01 then
		problem(string.format("gap %.1f: the origin is %s behind the head, past ThrowSkin",
			gap, fmt(headPosition.X - origin.X)))
	end
	if (origin - headPosition).Magnitude > (unclipped - headPosition).Magnitude + 0.01 then
		problem(string.format("gap %.1f: the clip moved the origin further out than the unclipped point", gap))
	end
	if reach > nearFace + 0.01 then
		problem(string.format("gap %.1f: a kit at the origin reaches %s through the wall", gap, fmt(reach - nearFace)))
	end
	-- The planted fault: wherever the clip had work to do, the old formula must be through the wall.
	-- (At gap 2.0 the unclipped point is legitimately short of the wall and nothing is expected.)
	if gap < DefensePlacement.ThrowLead then
		if unclipped.X <= nearFace then
			problem(string.format("gap %.1f: the unclipped point is NOT through the wall, so this case proves nothing", gap))
		else
			say(string.format("gap %.1f: the unclipped point would have been %s past the near face (the bug)", gap, fmt(unclipped.X - nearFace)))
		end
	end
	wall:Destroy()
end

-- Server and ghost from one helper: DefensePreview.Site must start where DefenseService throws from.
do
	local okPreview, DefensePreview = pcall(function()
		return require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("DefensePreview"))
	end)
	if not okPreview or type(DefensePreview) ~= "table" then
		say("preview: DefensePreview couldn't be required here (" .. tostring(DefensePreview) .. "); not checked")
	else
		local character = Instance.new("Model")
		character.Name = "ThrowStandIn"
		local root = block("HumanoidRootPart", V(2, 2, 1), ORIGIN + V(0, 0, 200))
		root.Parent = character
		local head = block("Head", V(1.2, 1.2, 1.2), root.Position + V(0, 1.6, 0))
		head.Parent = character
		character.PrimaryPart = root
		character.Parent = lane
		root.CFrame = CFrame.lookAt(root.Position, root.Position + V(1, 0, 0))
		local wall = block("ProbeWall", V(WALL_THICK, 12, 12), root.Position + V(1.6 + WALL_THICK / 2, 1.6, 0))
		local mine = DefensePlacement.ThrowOrigin(character, head.Position, root.CFrame.LookVector)
		local site = DefensePreview.Site(character, "RotMine", head.Position + V(20, 0, 0), {})
		local theirs = site and site.from or nil
		say(string.format("preview: server origin %s, ghost origin %s", tostring(mine), tostring(theirs)))
		if not theirs or (theirs - mine).Magnitude > 0.01 then
			problem("preview: the ghost's origin doesn't match the server's")
		end
		wall:Destroy()
		character:Destroy()
	end
end

-- A pane the clip can't see is a pane a kit is thrown through: the built window's glass must be solid.
do
	local pane = block(DestructibleService.GlassName, V(5, 5, 0.2), ORIGIN + V(0, 0, 400))
	local built = nil
	local map = workspace:FindFirstChild("Map")
	if map then
		for _, part in ipairs(map:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == DestructibleService.GlassName then
				built = part
				break
			end
		end
	end
	say(string.format("glass: a built %s is %s (probe stand-in %s)", DestructibleService.GlassName,
		built and (built.CanCollide and "CanCollide TRUE" or "CanCollide FALSE") or "not in this place",
		pane.CanCollide and "solid" or "not solid"))
	if built and not built.CanCollide then
		problem("glass: WindowGlass is CanCollide false, so RespectCanCollide lets a kit be thrown through a closed window")
	end
	pane:Destroy()
end

--------------------------------------------------------------------------------
-- #128 B: the slope a site may have, per structure (no physics needed)
--------------------------------------------------------------------------------
do
	local index0 = 0
	local expected = { RotBarricade = 7, PopupBunker = 5, BrainrotFortress = 7.2 }
	for id, want in pairs(expected) do
		local size = DefensePlacement.Sizes[id]
		local got = size and DefensePlacement.SlopeAllowance(size) or -1
		say(string.format("slope %s: allowance %s (want %s)", id, fmt(got), fmt(want)))
		if math.abs(got - want) > 0.01 then
			problem(string.format("slope %s: allowance %s, wanted %s", id, fmt(got), fmt(want)))
		end
	end
	-- An unlisted footprint falls back to the angle over its own diagonal, never stricter than MaxSlope.
	local odd = DefensePlacement.SlopeAllowance(Vector3.new(40, 8, 40))
	say(string.format("slope unlisted 40x40: allowance %s (the angle over its own diagonal, floor %s)", fmt(odd), fmt(DefensePlacement.MaxSlope)))
	if odd < DefensePlacement.MaxSlope then
		problem("slope: an unlisted footprint came out stricter than MaxSlope")
	end

	-- On real ground. The ramp is ONE thick rotated slab, so its top is a clean plane and nothing
	-- pokes up into the build box -- stepped blocks made FindSite answer "No room to build here",
	-- which is a different refusal and proved nothing about slope. The angle is chosen so the drop
	-- lands across the FOOTPRINT's sampled span (corners inset 0.5), not across the slab.
	-- Sloped ground has to be REAL ground, and this probe cannot make any: Terrain:FillBlock from a
	-- runtest probe does nothing at all, silently, at the probe's own origin and at the world origin
	-- alike, with Terrain.MaxExtents (-32000..32000 voxels) ruled out. Five runs of "FindSite refused
	-- the slope" were FindSite correctly refusing a HOLE.
	--
	-- What DOES make terrain here is the game's own builder: tools/footing_probe.lua measures whole
	-- maps built by MapGenerator.Build in this same harness. So the end-to-end case is left written
	-- but OFF, with the route spelled out, rather than a fixture that cannot work:
	--   1. `require(Modules.MapGenerator).Build("SahurSprings")` at the top of the probe (~9 s, and
	--      one map per run -- Studio dies near 3.6 GB with two).
	--   2. Walk the terrain for a patch whose drop across a barricade's 11-stud span is 6 studs: cast
	--      a grid of rays down over a few hundred studs, keep the first centre whose five FindSite
	--      sample points differ by 5.5..6.5.
	--   3. Call FindSite there for each structure and assert built/refused as the table below says.
	-- Ten lines on a map that already exists, and it needs a Studio slot, which is why it is not on.
	local RUN_GROUND_CASES = false
	local GROUND_CASES = {
		{ id = "RotBarricade", drop = 6, want = true, note = "refused by the old flat 5" },
		{ id = "RotBarricade", drop = 9, want = false, note = "past its own 7" },
		{ id = "BrainrotFortress", drop = 6, want = true, note = "refused by the old flat 5" },
		{ id = "BrainrotFortress", drop = 9, want = false, note = "past its own 7.2" },
		{ id = "PopupBunker", drop = 6, want = false, note = "its 5 is unchanged" },
	}
	if not RUN_GROUND_CASES then
		say(string.format("slope: %d end-to-end cases on real ground are written but OFF -- this probe cannot make terrain; see the note above for the MapGenerator route", #GROUND_CASES))
	end
end

--------------------------------------------------------------------------------
-- #128 A: a kit stopped on FIRST CONTACT lands where it first touched, not downhill
--------------------------------------------------------------------------------
do
	-- The harness switches Studio into run mode about six seconds in (tools/runtest.ps1's plugin:
	-- `task.delay(6, ... RunService:Run())`), and nothing falls before that. A probe that tests
	-- physics at once measures edit mode and reports "no physics here" -- which is what this section
	-- did on its first run. So wait for run mode, then test.
	local RunService = game:GetService("RunService")
	local waited = 0
	while not RunService:IsRunning() and waited < 40 do
		task.wait(0.25)
		waited += 0.25
	end
	say(string.format("first contact: waited %.1fs for run mode -- IsRunning %s, IsEdit %s, IsServer %s",
		waited, tostring(RunService:IsRunning()), tostring(RunService:IsEdit()), tostring(RunService:IsServer())))
	-- Physics only runs if the harness steps it; a falling test part says whether it does.
	local faller = block("PhysicsTest", Vector3.new(2, 2, 2), ORIGIN + Vector3.new(0, 40, 800))
	faller.Anchored = false
	local startY = faller.Position.Y
	for _ = 1, 30 do
		task.wait(1 / 30)
		if faller.Position.Y < startY - 1 then
			break
		end
	end
	local physics = faller.Position.Y < startY - 1
	faller:Destroy()
	if not physics then
		say("first contact: this harness does not step physics, so the Touched behaviour can't be measured here (edit mode). A is UNPROVEN.")
	else
		-- One slope, two identical kits on the same launch: one anchored on its first contact the way
		-- DefenseService.throwKit now does, one left to roll the way it used to. The gap between them is
		-- the lottery #128 A removes.
		local centre = ORIGIN + Vector3.new(0, 0, 900)
		local slope = block("Slope", Vector3.new(120, 4, 40), centre)
		slope.CFrame = CFrame.new(centre) * CFrame.Angles(0, 0, math.rad(-14))
		local function launch(stopOnContact)
			local kit = block("Kit", Vector3.new(1.5, 1.5, 1.5), centre + Vector3.new(-30, 22, 0))
			kit.Anchored = false
			kit.AssemblyLinearVelocity = Vector3.new(26, 4, 0)
			local contact = nil
			local touched
			touched = kit.Touched:Connect(function(hit)
				if contact or not hit.CanCollide or hit == kit then
					return
				end
				contact = kit.Position
				if stopOnContact then
					kit.AssemblyLinearVelocity = Vector3.zero
					kit.AssemblyAngularVelocity = Vector3.zero
					kit.Anchored = true
				end
				touched:Disconnect()
			end)
			local started = os.clock()
			repeat
				task.wait(0.05)
			until (stopOnContact and contact) or os.clock() - started > 4
				or (os.clock() - started > 0.4 and kit.AssemblyLinearVelocity.Magnitude < 3)
			touched:Disconnect()
			local rest = kit.Position
			kit:Destroy()
			return contact, rest
		end
		local firstContact, stopped = launch(true)
		local rolledContact, rolledRest = launch(false)
		if not firstContact or not rolledContact then
			problem("first contact: a kit never touched the slope, so nothing was measured")
		else
			local held = (stopped - firstContact).Magnitude
			local rolled = (rolledRest - rolledContact).Magnitude
			say(string.format("first contact: stopped %s from where it touched; the same throw left to roll ended %s away", fmt(held), fmt(rolled)))
			if held > 1 then
				problem(string.format("first contact: the kit moved %s after touching, wanted under 1", fmt(held)))
			end
			if rolled <= held then
				problem("first contact: the rolling kit didn't roll, so this case proves nothing")
			end
		end
		slope:Destroy()
	end
end

lane:Destroy()
if problems == 0 then
	say("ALL CHECKS PASSED")
else
	say(problems .. " PROBLEM(S)")
end
