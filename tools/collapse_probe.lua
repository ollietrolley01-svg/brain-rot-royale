-- Buildings fall over with physics (Oliver 2026-09-24), measured in RUN MODE: a runtest.ps1 probe
-- gets no physics by itself (coordination/handoffs/destruction.md), so this calls RunService:Run()
-- the way tools/mapvehicle_physics_probe.lua does, and PROVES physics is stepping before judging
-- anything: a loose block's height is logged over time and must fall the way gravity says.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/collapse_probe.lua -WaitSeconds 600 [-PlaceFile <rbxlx>]
--
-- Everything is built 9,000 studs out on a Foundation slab (never breaks: ground), in its own root
-- (workspace.CollapseTest, added to DestructibleService.Roots here), so nothing Bootstrap does in Run
-- mode can land on it. Real MapBuildings houses, broken through the real DestructibleService.Damage:
--
--   A  CUT LOOSE   every ground-floor wall and the stairs of a two-storey house shot out: the storey
--                  above has nothing joining it to the ground, so it must FALL, land, break up, and
--                  settle as anchored rubble; a stand-in bot on the ground floor is crushed.
--   B  ONE SIDE    the front wall of the ground floor shot out: the verdict is printed (it stands on
--                  the other three: a U of walls still has its weight well inside).
--   C  LOPSIDED    the front wall and the front halves of both side walls: its weight sits at the edge
--                  of what is left, so it must TOPPLE forward (lean, then fall over).
--   D  BUDGET      ten separate stacks cut loose in one frame: at most MaxAssemblies fall, the rest
--                  crumble to debris where they stand (nothing left hanging either way).
--
-- For each: the verdict, the chunk's height and lean over time, when it landed (the impact) and
-- settled, how many of its parts are rubble after, and that every rubble part is anchored AND held
-- up (DestructibleService.HeldUp) and still breakable. Frame cost: the worst Heartbeat gap while
-- things fell, the support pass's worst, CollapseService's worst step. "PROBLEM" lines are findings.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")

local function out(fmt, ...)
	print("[COLLAPSE] " .. string.format(fmt, ...))
end

local ORIGIN = Vector3.new(9000, 0, 9000)

local ok, err = pcall(function()
	if not RunService:IsRunning() then
		out("entering Run mode (edit mode steps no physics)")
		RunService:Run()
		task.wait(2)
	end
	out("RunService: IsRunning %s, IsEdit %s", tostring(RunService:IsRunning()), tostring(RunService:IsEdit()))

	-- PHYSICS PROOF.
	local block = Instance.new("Part")
	block.Name = "PhysicsProof"
	block.Size = Vector3.new(2, 2, 2)
	block.CFrame = CFrame.new(ORIGIN + Vector3.new(-200, 400, 0))
	block.Anchored = false
	block.Parent = workspace
	local t0 = os.clock()
	local trail = {}
	for _ = 1, 8 do
		table.insert(trail, string.format("%.1f", block.Position.Y))
		task.wait(0.25)
	end
	local fell = 400 - block.Position.Y
	out("PHYSICS a loose block's height every 0.25 s from 400: %s (fell %.1f studs in %.1f s; free fall would be %.1f)",
		table.concat(trail, " "), fell, os.clock() - t0, 0.5 * workspace.Gravity * 2 * 2)
	if fell < 20 then
		out("PROBLEM physics is NOT stepping: nothing below this line measures a collapse")
	end
	block:Destroy()

	local DS = require(modules:WaitForChild("DestructibleService"))
	local MapBuildings = require(modules:WaitForChild("MapBuildings"))
	local MapData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MapData"))
	local Combatants = require(modules:WaitForChild("Combatants"))
	local Collapse = DS.Collapse
	out("CollapseService loaded: %s; MaxAssemblies %s, MaxParts %s", tostring(Collapse ~= nil), tostring(Collapse and Collapse.MaxAssemblies),
		tostring(Collapse and Collapse.MaxParts))

	local root = Instance.new("Folder")
	root.Name = "CollapseTest"
	root.Parent = workspace
	DS.Roots.CollapseTest = true
	local ground = Instance.new("Part")
	ground.Name = "Foundation"
	ground.Size = Vector3.new(700, 2, 300)
	ground.CFrame = CFrame.new(ORIGIN + Vector3.new(200, -1, 0))
	ground.Anchored = true
	ground.Material = Enum.Material.Concrete
	-- The rig's ground: held up by nothing and holding everything up, as terrain does in a match
	-- (IntentionalFloat: DestructibleService's support pass takes it as an anchor).
	ground:SetAttribute("IntentionalFloat", true)
	ground.Parent = root

	local preset = MapData.Maps.SahurSprings
	local function house(offset, seed)
		math.randomseed(seed)
		local at = ORIGIN + offset
		local before = {}
		for _, c in ipairs(root:GetChildren()) do
			before[c] = true
		end
		MapBuildings.BuildBuilding(root, at, preset, {}, { weapon = {}, heal = {}, item = {} },
			{ archetype = "house", width = 32, depth = 30, floors = 2, dock = false }, 0)
		for _, c in ipairs(root:GetChildren()) do
			if not before[c] and c:IsA("Model") then
				return c, at
			end
		end
		return nil, at
	end

	local frames = { worst = 0, sum = 0, n = 0 }
	local frameConn = RunService.Heartbeat:Connect(function(dt)
		frames.worst = math.max(frames.worst, dt)
		frames.sum += dt
		frames.n += 1
	end)

	local function solidParts(model)
		local list = {}
		for _, d in ipairs(model:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide then
				table.insert(list, d)
			end
		end
		return list
	end

	-- A marker: the house's highest solid part (its roof), to follow as the chunk moves.
	local function highest(model)
		local best, y = nil, -math.huge
		for _, p in ipairs(solidParts(model)) do
			if p.Position.Y > y then
				best, y = p, p.Position.Y
			end
		end
		return best
	end

	local function shoot(parts)
		for _, p in ipairs(parts) do
			if p.Parent and p.Anchored then
				DS.Damage(p, 1e7, nil, p.Position + Vector3.new(0, 2, -30))
			end
		end
	end

	-- Follows a marker for `seconds`: height and lean over time, first impact, settle.
	local function follow(label, model, marker, seconds)
		local startY = marker and marker.Position.Y or 0
		local startUp = marker and marker.CFrame.UpVector or Vector3.new(0, 1, 0)
		local trail = {}
		local stats0 = Collapse and table.clone(Collapse.Stats) or {}
		local landedAt, settledAt = nil, nil
		local clock0 = os.clock()
		for step = 1, seconds * 4 do
			task.wait(0.25)
			if marker and marker.Parent then
				local lean = math.deg(math.acos(math.clamp(marker.CFrame.UpVector:Dot(startUp), -1, 1)))
				if step % 2 == 0 then
					table.insert(trail, string.format("%.1fs y%+.1f %.0fdeg%s", step * 0.25, marker.Position.Y - startY, lean,
						marker.Anchored and " A" or ""))
				end
				if not landedAt and Collapse and Collapse.Stats.impacts > (stats0.impacts or 0) then
					landedAt = os.clock() - clock0
				end
				if not settledAt and Collapse and Collapse.Stats.settled > (stats0.settled or 0) then
					settledAt = os.clock() - clock0
				end
			end
		end
		out("%s marker (%s): %s", label, marker and marker.Name or "none", table.concat(trail, " | "))
		out("%s landed hard at %s s, settled at %s s", label, landedAt and string.format("%.2f", landedAt) or "never",
			settledAt and string.format("%.2f", settledAt) or "never")
		-- Rubble: anchored, held up, breakable.
		local rubble, loose, floating, unbreakable = 0, 0, 0, 0
		for _, p in ipairs(model and model:GetDescendants() or {}) do
			if p:IsA("BasePart") then
				if p:GetAttribute("Rubble") then
					rubble += 1
					if p.CanCollide and not DS.HeldUp(p) then
						floating += 1
					end
					if p.CanCollide and not DS.FromPart(p) then
						unbreakable += 1
					end
				end
				if not p.Anchored then
					loose += 1
				end
			end
		end
		out("%s after %d s: %d rubble parts (%d not held up, %d not breakable), %d still unanchored", label, seconds, rubble, floating,
			unbreakable, loose)
		if floating > 0 then
			out("PROBLEM %s: %d rubble parts anchored in the air", label, floating)
		end
		if loose > 0 then
			out("PROBLEM %s: %d parts never settled", label, loose)
		end
		return rubble
	end

	local function stats(label)
		local s = DS.SupportStats
		local c = Collapse and Collapse.Stats or {}
		out("%s: support pass %d passes, %d checks, fell %d, toppled %d, worst pass %.2f ms; collapse dropped %s toppled %s crumbled %s impacts %s crushed %s peak %s, worst step %.2f ms; frames worst %.1f ms avg %.1f ms",
			label, s.passes, s.checks, s.fell, s.toppled, s.worst * 1000, tostring(c.dropped), tostring(c.toppled), tostring(c.crumbled),
			tostring(c.impacts), tostring(c.crushed), tostring(c.peak), (c.worstStep or 0) * 1000, frames.worst * 1000,
			frames.n > 0 and frames.sum / frames.n * 1000 or 0)
	end

	local FLOOR_HEIGHT = 12
	-- Everything solid standing in the ground floor (between the ground slab's top and the upper
	-- floor's underside): walls, corner posts, door frames, stairs, furniture.
	local function groundFloorWalls(model, at, test)
		local list = {}
		for _, p in ipairs(solidParts(model)) do
			local l = p.Position - at
			local half = p.Size.Y / 2
			local lo, hi = l.Y - half, l.Y + half
			if lo >= 0.2 and hi <= FLOOR_HEIGHT + 0.8 and hi > 0.8 and test(l, p) then
				table.insert(list, p)
			end
		end
		return list
	end

	local function verdict(label, model)
		local best = nil
		for _, p in ipairs(solidParts(model)) do
			if p.Anchored and (not best or p.Position.Y > best.Position.Y) then
				best = p
			end
		end
		if best then
			local held, count, why, balance = DS.Standing(best)
			out("%s verdict right after: held %s, chunk of %d parts, %s%s", label, tostring(held), count, tostring(why),
				balance and string.format(" (support %.0f sq studs, mass %.0f)", balance.area, balance.mass) or "")
		end
	end

	-- A: cut loose, with a stand-in bot on the ground floor under it.
	local houseA, atA = house(Vector3.new(0, 0, 0), 11)
	local markerA = houseA and highest(houseA)
	local bot = Instance.new("Model")
	bot.Name = "CrushDummy"
	local botRoot = Instance.new("Part")
	botRoot.Name = "HumanoidRootPart"
	botRoot.Size = Vector3.new(2, 5, 1)
	botRoot.Anchored = true
	-- Not in the way: the chunk comes down through it, and the crush is judged by where it stands.
	botRoot.CanCollide = false
	botRoot.CFrame = CFrame.new(atA + Vector3.new(4, 3.5, 4))
	botRoot.Parent = bot
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = bot
	bot.PrimaryPart = botRoot
	bot.Parent = workspace
	local token = { isBot = true, name = "CrushDummy", character = bot }
	Combatants.Register(bot, token)
	local cutA = groundFloorWalls(houseA, atA, function()
		return true
	end)
	out("A CUT LOOSE: house %d parts, shooting out everything standing in its ground floor (%d parts)", #houseA:GetDescendants(), #cutA)
	shoot(cutA)
	task.wait()
	verdict("A", houseA)
	follow("A", houseA, markerA, 9)
	out("A crush: the stand-in's health %.0f of 100", humanoid.Health)
	stats("A")

	-- B: one side.
	local houseB, atB = house(Vector3.new(80, 0, 0), 12)
	local markerB = houseB and highest(houseB)
	local cutB = groundFloorWalls(houseB, atB, function(l)
		return l.Z < -13.5
	end)
	out("B ONE SIDE: shooting out %d front ground-floor parts", #cutB)
	shoot(cutB)
	task.wait()
	verdict("B", houseB)
	follow("B", houseB, markerB, 5)
	stats("B")

	-- C: lopsided.
	local houseC, atC = house(Vector3.new(160, 0, 0), 13)
	local markerC = houseC and highest(houseC)
	local cutC = groundFloorWalls(houseC, atC, function(l)
		return l.Z < 2
	end)
	out("C LOPSIDED: shooting out everything in the front half of its ground floor (%d parts)", #cutC)
	shoot(cutC)
	task.wait()
	verdict("C", houseC)
	follow("C", houseC, markerC, 10)
	stats("C")

	-- E: a bridge: a deck of four spans on three piers between two abutments; the middle pier shot.
	local bridge = Instance.new("Model")
	bridge.Name = "Bridge"
	bridge.Parent = root
	local function block(name, size, at, material)
		local b = Instance.new("Part")
		b.Name = name
		b.Size = size
		b.CFrame = CFrame.new(at)
		b.Anchored = true
		b.Material = material or Enum.Material.Concrete
		b.Parent = bridge
		return b
	end
	local bx, bz = ORIGIN.X + 420, ORIGIN.Z
	local piers = {}
	for i, x in ipairs({ -24, 0, 24 }) do
		piers[i] = block("BridgePier", Vector3.new(3, 14, 10), Vector3.new(bx + x, 7, bz))
	end
	local spans = {}
	for i, x in ipairs({ -36, -12, 12, 36 }) do
		spans[i] = block("BridgeDeck", Vector3.new(24, 1.2, 12), Vector3.new(bx + x, 14.6, bz), Enum.Material.Asphalt)
	end
	block("BridgeAbutment", Vector3.new(6, 14, 14), Vector3.new(bx - 51, 7, bz))
	block("BridgeAbutment", Vector3.new(6, 14, 14), Vector3.new(bx + 51, 7, bz))
	local y2, y3 = spans[2].Position.Y, spans[3].Position.Y
	shoot({ piers[2] })
	task.wait()
	local h2 = spans[2].Parent and DS.Standing(spans[2])
	out("E BRIDGE: middle pier shot; the two spans on it: held %s", tostring(h2))
	task.wait(5)
	out("E BRIDGE after 5 s: span 2 dropped %.1f studs (anchored %s), span 3 dropped %.1f (anchored %s); spans 1 and 4 %s",
		spans[2].Parent and y2 - spans[2].Position.Y or -1, tostring(spans[2].Parent and spans[2].Anchored),
		spans[3].Parent and y3 - spans[3].Position.Y or -1, tostring(spans[3].Parent and spans[3].Anchored),
		(spans[1].Parent and spans[1].Anchored and spans[4].Parent and spans[4].Anchored) and "still up" or "moved")
	stats("E")

	-- F: a road slab on the ground, holed by one rocket: cut into tiles, the tile it hit gone.
	local roads = Instance.new("Model")
	roads.Name = "Roads"
	roads.Parent = root
	local road = Instance.new("Part")
	road.Name = "RoadSurface"
	road.Size = Vector3.new(18, 0.8, 60)
	road.CFrame = CFrame.new(ORIGIN + Vector3.new(560, 0.4, 0))
	road.Anchored = true
	road.Material = Enum.Material.Asphalt
	road.Parent = roads
	local blast = road.Position + Vector3.new(2, 1, 6)
	DS.DamageInRadius(blast, 5, 200, nil)
	task.wait(0.5)
	local tiles, left = 0, 0
	for _, c in ipairs(roads:GetChildren()) do
		if c.Name == "RoadSurface" then
			tiles += 1
			if c.Anchored then
				left += 1
			end
		end
	end
	out("F ROAD: one rocket on an 18x60 road: %d tiles now (the road was cut on its first hit), %d still lying where they were; road whole: %s",
		tiles, left, tostring(road.Parent ~= nil))

	-- D: the budget. Ten stacks of four blocks on a post each; the posts all shot in one frame.
	local stacks = Instance.new("Model")
	stacks.Name = "Stacks"
	stacks.Parent = root
	local posts = {}
	for i = 1, 10 do
		local x = ORIGIN.X + 260 + i * 10
		local post = Instance.new("Part")
		post.Name = "Post"
		post.Size = Vector3.new(1, 6, 1)
		post.CFrame = CFrame.new(x, 3, ORIGIN.Z)
		post.Anchored = true
		post.Material = Enum.Material.Wood
		post.Parent = stacks
		table.insert(posts, post)
		for j = 1, 4 do
			local b = Instance.new("Part")
			b.Name = "Block"
			b.Size = Vector3.new(4, 2, 4)
			b.CFrame = CFrame.new(x, 6 + j * 2 - 1, ORIGIN.Z)
			b.Anchored = true
			b.Material = Enum.Material.Brick
			b.Parent = stacks
		end
	end
	local c0 = Collapse and table.clone(Collapse.Stats) or {}
	shoot(posts)
	task.wait(0.5)
	local c1 = Collapse and Collapse.Stats or {}
	local hanging = 0
	for _, b in ipairs(stacks:GetChildren()) do
		if b:IsA("BasePart") and b.Anchored and b.Name == "Block" and not DS.HeldUp(b) then
			hanging += 1
		end
	end
	out("D BUDGET: 10 stacks cut loose at once: %d fell (cap %s), %d crumbled; %d blocks left anchored in the air (want 0)",
		(c1.dropped or 0) - (c0.dropped or 0), tostring(Collapse and Collapse.MaxAssemblies), (c1.crumbled or 0) - (c0.crumbled or 0), hanging)
	task.wait(8)
	stats("D")
	frameConn:Disconnect()
end)
if not ok then
	out("PROBLEM probe error: %s", tostring(err))
end
out("done")
