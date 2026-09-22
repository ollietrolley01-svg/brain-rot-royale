-- The arena's target dummies and the client effects, for tools/gallery.ps1 — it renders AND measures
-- (the notes are the probe). This replaced tools/practice_dummy_gallery.lua and tools/effects_gallery.lua:
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery tools/arena_gallery.lua -OutDir <folder> -TimeoutSeconds 900
--
-- DUMMIES. Oliver asked for target dummies that respawn five seconds after they're destroyed, carry
-- as much health as a player with full health and shield, and fall down in a ragdoll when they die.
-- Measured: the pools resolve to the player's own constants (MatchConfig.StartHealth + MaxShield,
-- read, not copied); hits to destroy from full equal what those pools say; the shield goes first;
-- every body part is tagged for RangeService's include-only filter and nothing else is; the body
-- has no flush faces for the z-fight pass to move; the stand is empty while it's down and a fully
-- tagged, full-health body is back after RespawnSeconds; the registry lets go of a destroyed parent.
-- The ragdoll needs physics, and Studio's edit mode runs none, so the gallery enters Run mode
-- (RunService:Run(), the way tools/runtest.ps1's plugin does) for the death views and measures the
-- fall on a wall clock: the corpse comes to rest within 2 s, never goes through the marble, is
-- cleared before the respawn, and a corpse with its collision switched off falls through and is
-- caught (the planted fault). Two frames photograph the fall: one early in the collapse, one at rest.
-- Also planted every run: a dummy given one extra hit point must take one more hit than the pools
-- say, and a dummy with one part untagged must be reported.
--
-- EFFECTS. Tracers, blood splats and the storm ring are a LocalScript's work: GunFx, ExplosiveFx
-- (which HitSplatClient asks for splats) and StormClient. A runtest window is the server only, so
-- none of these can ever appear in one. Here the real modules are driven with the server's remote
-- replaced by a local event, fired DURING the hold so the capture lands while they are on screen
-- (a splat lives 1.2 s), and the storm is broadcast at ground level, where a map's storm is.
-- Planted: a splat batch on a model with no body adds nothing, a tracer shorter than half a stud
-- does not fly, and an Idle storm takes the ring down.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local modules = ServerScriptService:WaitForChild("Modules")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local MatchConfig = require(Shared:WaitForChild("MatchConfig"))
local ZFight = require(Shared:WaitForChild("ZFight"))
local LobbyService = require(modules:WaitForChild("LobbyService"))
local PracticeDummy = require(modules:WaitForChild("PracticeDummy"))
local GunFx = require(Scripts:WaitForChild("GunFx"))
local ExplosiveFx = require(Scripts:WaitForChild("ExplosiveFx"))

-- Far from MatchConfig.LobbyPosition: once Run mode starts, Bootstrap builds the real lobby there.
local BASE = Vector3.new(3000, 2600, 3000)
local ARENA_CENTRE = BASE + Vector3.new(86, 0, 0)
local ARENA_HEIGHT = 7
-- The terrace's marble top, in world Y: stone to ARENA_HEIGHT, gold rim to +0.07, marble to +0.14.
local MARBLE_TOP = BASE.Y + ARENA_HEIGHT + 0.14
local HIT = 25
local KINDS = { "bullet", "heavy", "pellet", "energy", "bullet", "bullet" }

local state = { checks = 0, failures = 0, sites = {}, tracersFired = 0, frame = 0 }

local function note(text)
	print("[BRR_Gallery] note " .. text)
end

local function check(ok, text)
	state.checks += 1
	if not ok then
		state.failures += 1
	end
	note((ok and "PASS  " or "FAIL  ") .. text)
end

local function look(camera, eye, target, fov)
	camera.FieldOfView = fov or 50
	camera.CFrame = CFrame.lookAt(eye, target)
end

local function partsOf(body)
	local parts = {}
	for _, d in ipairs(body:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return parts
end

local function tagCount(body)
	local tagged, untagged = 0, 0
	for _, p in ipairs(partsOf(body)) do
		if CollectionService:HasTag(p, PracticeDummy.Tag) then
			tagged += 1
		else
			untagged += 1
		end
	end
	return tagged, untagged
end

-- RangeService's own filter, include-only on the tag: a ray from 8 studs in front of the stand at
-- chest height, straight at it and a little past.
local function rangeRay(site)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = CollectionService:GetTagged(PracticeDummy.Tag)
	local chest = (site.frame * CFrame.new(0, 3.8, 0)).Position
	local from = chest + site.frame.LookVector * 8
	local hit = workspace:Raycast(from, (chest - from) + site.frame.LookVector * -2, params)
	return hit and hit.Instance or nil
end

local function hitsToDestroy(body, amount)
	local chest = body:FindFirstChild("UpperTorso")
	for count = 1, 200 do
		local _, killed = PracticeDummy.Hit(chest, amount)
		if killed then
			return count
		end
	end
	return math.huge
end

local function waitForBody(site, timeout)
	local started = os.clock()
	while os.clock() - started < timeout do
		if site.body then
			return os.clock() - started
		end
		task.wait(0.05)
	end
	return nil
end

-- The lowest point of a part, whatever way it is turned — by its SHAPE. The first two runs took the
-- box-AABB of every part's OBB, which for the head (a Ball, 1.4 across) tilted at rest over-reports
-- its downward reach by up to half a stud, and read "0.37 into the marble" for a corpse the picture
-- showed lying on it. A ball reaches its radius straight down whatever its rotation; a cylinder
-- reaches |axis.y|·L/2 + sqrt(1−axis.y²)·r; only a box reaches its full OBB extent.
local function bottomOf(part)
	local frame, size = part.CFrame, part.Size
	if part:IsA("Part") and part.Shape == Enum.PartType.Ball then
		return part.Position.Y - math.min(size.X, size.Y, size.Z) / 2
	elseif part:IsA("Part") and part.Shape == Enum.PartType.Cylinder then
		local axisY = math.abs(frame.RightVector.Y)
		local r = math.min(size.Y, size.Z) / 2
		return part.Position.Y - (axisY * size.X / 2 + math.sqrt(math.max(0, 1 - axisY * axisY)) * r)
	end
	local reach = (math.abs(frame.RightVector.Y) * size.X + math.abs(frame.UpVector.Y) * size.Y + math.abs(frame.LookVector.Y) * size.Z) / 2
	return part.Position.Y - reach
end

-- Samples a corpse every tenth of a second: its lowest point (and which part it is), its fastest part.
local function watchCorpse(body, seconds)
	local samples = {}
	task.spawn(function()
		local started = os.clock()
		while os.clock() - started < seconds and body.Parent do
			local lowest, lowestName, fastest, any = math.huge, "?", 0, false
			for _, p in ipairs(partsOf(body)) do
				any = true
				local bottom = bottomOf(p)
				if bottom < lowest then
					lowest, lowestName = bottom, p.Name
				end
				fastest = math.max(fastest, p.AssemblyLinearVelocity.Magnitude)
			end
			if not any then
				break
			end
			table.insert(samples, { t = os.clock() - started, lowest = lowest, lowestName = lowestName, fastest = fastest })
			task.wait(0.1)
		end
	end)
	return samples
end

-- When the corpse first came to rest (every later sample under 1.5 studs/s), or nil.
local function restTime(samples)
	for index, sample in ipairs(samples) do
		if sample.fastest < 1.0 then
			local held = true
			for later = index, #samples do
				if samples[later].fastest >= 1.5 then
					held = false
					break
				end
			end
			if held then
				return sample.t
			end
		end
	end
	return nil
end

local function closeUp(camera, site)
	local at = site.frame.Position
	look(camera, at + site.frame.LookVector * 7.5 + site.frame.RightVector * -3.5 + Vector3.new(0, 4.6, 0), at + Vector3.new(0, 3.4, 0), 45)
end

local function withBars(camera, site)
	local at = site.frame.Position
	look(camera, at + site.frame.LookVector * 10.5 + site.frame.RightVector * -3 + Vector3.new(0, 6.2, 0), at + Vector3.new(0, 4.6, 0), 45)
end

-- Lower and from the side, so a body lying on the stand fills the frame.
local function onTheGround(camera, site)
	local at = site.frame.Position
	look(camera, at + site.frame.LookVector * 8 + site.frame.RightVector * 6 + Vector3.new(0, 3.6, 0), at + Vector3.new(0, 1.2, 0), 50)
end

-- Loads a LocalScript's source in this context with its server remote swapped for a BindableEvent,
-- its sound module for a no-op and a sibling require for the module already loaded above.
local function loadClientScript(name, remoteName, extraSwaps)
	local source = Scripts:WaitForChild(name).Source
	local bindable = Instance.new("BindableEvent")
	local key = "__" .. name .. "Event"
	_G[key] = { OnClientEvent = bindable.Event }
	source = source:gsub('Remotes%.Event%("' .. remoteName .. '"%)', "_G." .. key)
	source = source:gsub('require%(script%.Parent:WaitForChild%("Sfx"%)%)', "{ PlayAt = function() end, Play = function() end }")
	for pattern, replacement in pairs(extraSwaps or {}) do
		source = source:gsub(pattern, replacement)
	end
	local fn, err = loadstring(source, name)
	assert(fn, tostring(err))
	fn()
	return bindable
end

local function attachmentsUnderTerrain()
	local count = 0
	for _, child in ipairs(workspace.Terrain:GetChildren()) do
		if child:IsA("Attachment") then
			count += 1
		end
	end
	return count
end

local function splatParts()
	local count = 0
	for _, child in ipairs(ExplosiveFx.Folder():GetChildren()) do
		if child.Name == "Splat" or child.Name == "ShieldChip" or child.Name == "Droplet" or child.Name == "Run" or child.Name == "Bead" then
			count += 1
		end
	end
	return count
end

local views = {}
local function add(name, fn, hold, step, settle)
	table.insert(views, { name = name, settle = settle or 1.4, hold = hold or 2, setup = fn, step = step })
end

-- ============================================ DUMMIES ============================================

add("arena_row", function(_, camera)
	local folder = Instance.new("Folder")
	folder.Name = "ArenaGalleryLobby"
	folder.Parent = workspace
	LobbyService.Build(folder, BASE)
	task.wait(1)
	state.folder = folder
	state.sites = PracticeDummy.Sites(folder)
	local health, shield = PracticeDummy.Pools()
	note(string.format("pools resolve to health %d + shield %d = %d (MatchConfig.StartHealth %d, MatchConfig.MaxShield %d)",
		health, shield, health + shield, MatchConfig.StartHealth, MatchConfig.MaxShield))
	check(health == MatchConfig.StartHealth and shield == MatchConfig.MaxShield, "pools are the player's own constants")
	check(#state.sites == 5, string.format("5 stands built (%d)", #state.sites))
	local flush, bodies, perBody, moved = 0, 0, 0, 0
	for _, site in ipairs(state.sites) do
		if site.body then
			bodies += 1
			perBody = #partsOf(site.body)
			local tagged, untagged = tagCount(site.body)
			check(untagged == 0 and tagged > 0, string.format("stand %d: %d parts tagged, %d not", site.id, tagged, untagged))
			flush += #ZFight.Scan({ site.body })
			for _, p in ipairs(partsOf(site.body)) do
				if p:GetAttribute("ZFixed") then
					moved += 1
				end
			end
			local h, s = PracticeDummy.State(site.body)
			check(h == health and s == shield, string.format("stand %d: full at %d health, %d shield", site.id, h, s))
		end
	end
	check(bodies == #state.sites, "every stand has a body")
	check(flush == 0, string.format("bodies have %d flush pairs as written (want 0)", flush))
	check(moved == 0, string.format("the lobby's z-fight pass had to move %d dummy parts (want 0)", moved))
	local taggedEverywhere = #CollectionService:GetTagged(PracticeDummy.Tag)
	check(taggedEverywhere == bodies * perBody, string.format("the tag is on exactly the dummies' parts: %d tagged, %d bodies x %d parts", taggedEverywhere, bodies, perBody))
	look(camera, ARENA_CENTRE + Vector3.new(-6, ARENA_HEIGHT + 9, 0), ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0), 62)
end, 3)

add("dummy_close", function(_, camera)
	local site = state.sites[3]
	closeUp(camera, site)
	local hit = rangeRay(site)
	check(hit ~= nil and PracticeDummy.BodyOf(hit) == site.body, "the range's include-only ray reaches the dummy (" .. tostring(hit and hit.Name) .. ")")
end)

add("dummy_shield_gone", function(_, camera)
	local site = state.sites[3]
	local body = site.body
	local health, shield = PracticeDummy.Pools()
	local chest, head = body:FindFirstChild("UpperTorso"), body:FindFirstChild("Head")
	local dealt1, killed1, blue1 = PracticeDummy.Hit(chest, HIT)
	check(dealt1 == HIT and not killed1 and blue1, string.format("first hit: dealt %d, the shield took it (blue marker)", dealt1))
	local more = math.ceil(shield / HIT) - 1
	for _ = 1, more do
		PracticeDummy.Hit(chest, HIT)
	end
	local h, s = PracticeDummy.State(body)
	check(s == math.max(0, shield - HIT * (more + 1)) and h == health,
		string.format("after %d hits of %d: shield %d, health %d untouched", more + 1, HIT, s, h))
	local dealt2, _, blue2, headshot = PracticeDummy.Hit(head, HIT, 2)
	h, s = PracticeDummy.State(body)
	check(not blue2 and headshot and dealt2 == HIT * 2 and h == health - HIT * 2,
		string.format("head hit with the shield gone and a x2 gun: red marker, headshot flag, dealt %d, health %d", dealt2, h))
	local dealt3, _, _, headshot3 = PracticeDummy.Hit(body:FindFirstChild("TargetDot"), HIT)
	check(not headshot3 and dealt3 == HIT * PracticeDummy.BullseyeMultiplier,
		string.format("bullseye on the painted target: dealt %.1f (x%.1f), not a headshot", dealt3, PracticeDummy.BullseyeMultiplier))
	withBars(camera, site)
end)

-- The fall needs physics: Run mode from here on. Bootstrap starts with it and builds the real lobby
-- at MatchConfig.LobbyPosition, well away from this one.
add("ragdoll_falling", function(_, camera)
	if not RunService:IsRunning() then
		note("entering Run mode for the ragdoll (edit mode runs no physics)")
		RunService:Run()
		task.wait(1)
	end
	check(RunService:IsRunning(), "Studio is running (physics on) for the death views")
	local site = state.sites[3]
	local body = site.body
	local remaining = hitsToDestroy(body, HIT)
	state.corpse = body
	state.destroyedAt = os.clock()
	state.samples = watchCorpse(body, 3.2)
	-- The clear and the respawn happen while later views are on screen, so they are timed here,
	-- from the moment of death: when the corpse was cleared and what the stand held at that instant
	-- (nothing, or a corpse and a live body shared it), and when the fresh body arrived.
	task.spawn(function()
		local started = os.clock()
		while body.Parent and os.clock() - started < 12 do
			task.wait(0.05)
		end
		state.clearedAt = os.clock() - state.destroyedAt
		state.bodyAtClear = site.body
	end)
	task.spawn(function()
		local started = os.clock()
		while not site.body and os.clock() - started < 12 do
			task.wait(0.05)
		end
		state.respawnedAt = site.body and (os.clock() - state.destroyedAt) or nil
	end)
	check(site.body == nil and body:GetAttribute("DummyDown") == true, "destroyed: the stand is empty and the body is marked down")
	local tagged = tagCount(body)
	check(tagged == 0, string.format("destroyed: %d parts still tagged (want 0)", tagged))
	check(rangeRay(site) == nil, "destroyed: the range's ray reaches nothing on the stand")
	local sockets, welds, attachments, queryable = 0, 0, 0, 0
	for _, d in ipairs(body:GetDescendants()) do
		if d:IsA("BallSocketConstraint") then
			sockets += 1
		elseif d:IsA("WeldConstraint") then
			welds += 1
		elseif d:IsA("Attachment") then
			attachments += 1
		elseif d:IsA("BasePart") and d.CanQuery then
			queryable += 1
		end
	end
	note(string.format("corpse: %d parts, %d ball sockets, %d welds, %d attachments; %d parts still CanQuery (want 0); bars gone %s",
		#partsOf(body), sockets, welds, attachments, queryable, tostring(body:FindFirstChild("Head") and body.Head:FindFirstChild("HealthBar") == nil)))
	check(sockets == 6 and welds == 7 and queryable == 0, "corpse is one hung figure: 6 sockets, 7 welds, nothing queryable")
	note(string.format("stand 3 took %d more hits of %d after the head hit; this frame is captured about half a second into the fall", remaining, HIT))
	onTheGround(camera, site)
end, 1, nil, 0.35)

add("ragdoll_at_rest", function(_, camera)
	local site = state.sites[3]
	local elapsed = os.clock() - state.destroyedAt
	if elapsed < 2.6 then
		task.wait(2.6 - elapsed)
	end
	local samples = state.samples
	local rest = restTime(samples)
	-- The lowest point AT REST: a limb hitting the floor at forty studs a second dips a third of a
	-- stud for an instant before the solver pushes it out (the first run measured that instant),
	-- and the picture shows it lying on the surface. What matters is where it lies.
	local lowestEver, lowestAtRest, lowestPart, fastest = math.huge, math.huge, "?", 0
	for _, sample in ipairs(samples) do
		lowestEver = math.min(lowestEver, sample.lowest)
		fastest = math.max(fastest, sample.fastest)
		if rest and sample.t >= rest and sample.lowest < lowestAtRest then
			lowestAtRest, lowestPart = sample.lowest, sample.lowestName
		end
	end
	note(string.format("corpse over %.1f s (%d samples): fastest part %.1f studs/s, lowest point ever %.2f, lowest at rest %.2f = %s (marble top %.2f), at rest after %s s",
		samples[#samples] and samples[#samples].t or 0, #samples, fastest, lowestEver, lowestAtRest, lowestPart, MARBLE_TOP, rest and string.format("%.1f", rest) or "never"))
	check(rest ~= nil and rest <= 2.0, "the corpse comes to rest within 2 s")
	check(lowestAtRest >= MARBLE_TOP - 0.15, "the corpse lies on the marble, not in it (lowest point at rest within 0.15 of the top)")
	check(fastest > 1.0, "the corpse actually moved (physics ran)")
	onTheGround(camera, site)
end, 3, nil, 0.4)

add("ragdoll_planted_no_collision", function(_, camera)
	-- The planted fault: a corpse with its collision off must fall through the terrace, and the
	-- same measurement must catch it.
	local site = state.sites[2]
	local body = site.body
	hitsToDestroy(body, HIT)
	for _, p in ipairs(partsOf(body)) do
		p.CanCollide = false
	end
	local samples = watchCorpse(body, 1.6)
	task.wait(1.7)
	local lowest = math.huge
	for _, sample in ipairs(samples) do
		lowest = math.min(lowest, sample.lowest)
	end
	local caught = lowest < MARBLE_TOP - 0.15
	note(string.format("self-test: a corpse with CanCollide off reached %.1f (marble top %.2f) -> %s", lowest, MARBLE_TOP, caught and "fell through, caught" or "NOT caught"))
	check(caught, "planted fault caught (the marble check can fail)")
	onTheGround(camera, site)
end, 1)

add("dummy_respawned", function(_, camera)
	local site = state.sites[3]
	waitForBody(site, PracticeDummy.RespawnSeconds + 4)
	-- Timed by the watchers started at the death, not by this view's place in the sequence.
	local deadline = os.clock() + 8
	while (state.clearedAt == nil or state.respawnedAt == nil) and os.clock() < deadline do
		task.wait(0.1)
	end
	local cleared, back = state.clearedAt, state.respawnedAt
	check(cleared ~= nil and cleared >= PracticeDummy.DebrisSeconds - 0.1 and cleared <= PracticeDummy.DebrisSeconds + 0.8,
		string.format("corpse cleared %.2f s after the death (DebrisSeconds %.1f)", cleared or -1, PracticeDummy.DebrisSeconds))
	check(state.bodyAtClear == nil, "no corpse and live body ever shared the stand (stand was empty when the corpse cleared)")
	check(back ~= nil and back >= PracticeDummy.RespawnSeconds - 0.1 and back <= PracticeDummy.RespawnSeconds + 1.5,
		string.format("back %.2f s after it was destroyed (RespawnSeconds %d)", back or -1, PracticeDummy.RespawnSeconds))
	if site.body then
		local tagged, untagged = tagCount(site.body)
		local h, s = PracticeDummy.State(site.body)
		local health, shield = PracticeDummy.Pools()
		check(untagged == 0 and tagged > 0, string.format("respawned: %d parts tagged, %d not", tagged, untagged))
		check(h == health and s == shield, string.format("respawned at full: %d health, %d shield", h, s))
		check(rangeRay(site) ~= nil, "respawned: the range's ray reaches it again")
		check(#ZFight.Scan({ site.body }) == 0, "respawned body has no flush pairs")
	end
	closeUp(camera, site)
end, 3)

add("dummy_self_test", function(_, camera)
	local stage = Instance.new("Folder")
	stage.Name = "DummySelfTest"
	stage.Parent = workspace
	local health, shield = PracticeDummy.Pools()
	local expected = math.ceil((health + shield) / HIT)
	local fat = PracticeDummy.Build(stage, CFrame.new(BASE + Vector3.new(0, 500, 0)))
	fat:SetAttribute("DummyHealth", health + 1)
	local took = hitsToDestroy(fat, HIT)
	local plantedHealth = took == expected + 1
	local bare = PracticeDummy.Build(stage, CFrame.new(BASE + Vector3.new(20, 500, 0)))
	CollectionService:RemoveTag(bare:FindFirstChild("LeftArm"), PracticeDummy.Tag)
	local _, untagged = tagCount(bare)
	local plantedTag = untagged == 1
	local fresh = state.sites[4].body
	local fromFull = fresh and hitsToDestroy(fresh, HIT) or -1
	note(string.format("hits of %d to destroy from full: %d (a full-health, full-shield player: %d)", HIT, fromFull, expected))
	check(fromFull == expected, "hits to destroy from full match the pools")
	note(string.format("self-test: a dummy given +1 health took %d hits (want %d) -> %s; a dummy with one part untagged reads %d untagged (want 1) -> %s",
		took, expected + 1, plantedHealth and "caught" or "MISSED", untagged, plantedTag and "caught" or "MISSED"))
	check(plantedHealth and plantedTag, "planted faults caught (so the checks above can fail)")
	stage:Destroy()
	task.wait(0.2)
	check(#PracticeDummy.Sites(stage) == 0, "stands of a destroyed parent are dropped from the registry")
	closeUp(camera, state.sites[3])
end)

-- ============================================ EFFECTS ============================================

local function fireOne()
	state.frame += 1
	local site = state.sites[(state.frame % #state.sites) + 1]
	local body = site and site.body
	local chest = body and body:FindFirstChild("UpperTorso")
	if not chest then
		return
	end
	local kind = KINDS[(state.frame % #KINDS) + 1]
	local rng = Random.new(state.frame)
	local target = chest.Position + Vector3.new(0, rng:NextNumber(-0.8, 1.2), rng:NextNumber(-0.7, 0.7))
	local origin = state.gun
	state.tracersFired += 1
	GunFx.Tracer(origin, target, kind, function()
		GunFx.Impact(target, (origin - target).Unit)
	end)
end

add("tracers_side", function(_, camera)
	-- Wait for every stand to have a body again (stands 2 and 3 were destroyed above).
	for _, site in ipairs(state.sites) do
		waitForBody(site, PracticeDummy.RespawnSeconds + 2)
	end
	state.gun = ARENA_CENTRE + Vector3.new(-14, ARENA_HEIGHT + 4.2, 0)
	local before = attachmentsUnderTerrain()
	for _ = 1, 6 do
		fireOne()
	end
	local during = attachmentsUnderTerrain()
	check(during > before, string.format("firing puts tracer attachments under Terrain: %d before, %d after six shots", before, during))
	local mid = (state.gun + ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0)) / 2
	look(camera, mid + Vector3.new(0, 5, 26), mid, 48)
end, 3, fireOne)

add("tracers_over_shoulder", function(_, camera)
	look(camera, state.gun + Vector3.new(-5, 2.2, 3.5), ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0), 55)
end, 3, fireOne)

add("tracers_done", function(_, camera)
	task.wait(0.6)
	local after = attachmentsUnderTerrain()
	note(string.format("%d tracers fired; %d attachments left under Terrain 0.6 s after the last shot (want 0)", state.tracersFired, after))
	check(after == 0, "tracers clean up after themselves")
	look(camera, ARENA_CENTRE + Vector3.new(-6, ARENA_HEIGHT + 9, 0), ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0), 62)
end, 1)

-- Splats are fired every fourth frame through the hold, so the capture lands while some are fresh.
local function splatStep()
	state.frame += 1
	if state.frame % 4 ~= 0 or not state.hitSplat then
		return
	end
	local site = state.sites[3]
	local body = site and site.body
	if body then
		state.hitSplat:Fire({ { body, false, false, false }, { body, false, state.frame % 12 == 0, false }, { body, false, false, state.frame % 8 == 0 } })
	end
end

add("splats", function(_, camera)
	state.hitSplat = loadClientScript("HitSplatClient", "HitSplat", {
		['require%(script%.Parent:WaitForChild%("ExplosiveFx"%)%)'] = "_G.__ExplosiveFxModule",
	})
	local site = state.sites[3]
	local body = site.body
	local before = splatParts()
	for _ = 1, 6 do
		state.hitSplat:Fire({ { body, false, false, false }, { body, false, true, false }, { body, false, false, true } })
	end
	task.wait(0.4)
	local after = splatParts()
	check(after > before, string.format("splats: %d splat parts before, %d after eighteen hits (red, headshot and shield)", before, after))
	note(string.format("ExplosiveFx reports %d live effects", (ExplosiveFx.Count())))
	local at = site.frame.Position
	look(camera, at + site.frame.LookVector * 6 + site.frame.RightVector * -2.5 + Vector3.new(0, 4.4, 0), at + Vector3.new(0, 3.6, 0), 40)
end, 3, splatStep)

add("splats_other_side", function(_, camera)
	local site = state.sites[3]
	local at = site.frame.Position
	look(camera, at + site.frame.LookVector * 6 + site.frame.RightVector * 3 + Vector3.new(0, 5.2, 0), at + Vector3.new(0, 4.4, 0), 40)
end, 3, splatStep)

-- The storm: StormClient builds its wall from world y -60 to 900, where a map's ground is.
local STORM_CENTRE = Vector3.new(0, 0, 0)
local STORM_RADIUS = 175

add("storm_ring_outside", function(_, camera)
	state.storm = loadClientScript("StormClient", "StormChanged")
	state.storm:Fire({ status = "Shrinking", center = STORM_CENTRE, radius = STORM_RADIUS })
	task.wait(0.5)
	local wall = workspace:FindFirstChild("StormWall")
	local laid = 0
	if wall then
		for _, part in ipairs(wall:GetChildren()) do
			if part:IsA("BasePart") and part.Size.X > 1 then
				laid += 1
			end
		end
	end
	check(wall ~= nil and wall.Parent == workspace, "the storm ring is in the workspace once a storm is broadcast")
	check(laid == 192, string.format("%d of 192 storm segments laid out (96 wall + 96 band)", laid))
	if wall and laid > 0 then
		local sample = wall:GetChildren()[1]
		local r = (Vector3.new(sample.Position.X, 0, sample.Position.Z) - STORM_CENTRE).Magnitude
		check(math.abs(r - STORM_RADIUS) < 2, string.format("a segment stands %.1f studs from the centre (want %d)", r, STORM_RADIUS))
	end
	look(camera, STORM_CENTRE + Vector3.new(0, 90, -420), STORM_CENTRE + Vector3.new(0, 40, 0), 60)
end, 3)

add("storm_ring_at_eye_level", function(_, camera)
	look(camera, STORM_CENTRE + Vector3.new(0, 8, -110), STORM_CENTRE + Vector3.new(0, 16, -STORM_RADIUS), 70)
end, 3)

add("effects_self_test", function(_, camera)
	local empty = Instance.new("Model")
	empty.Name = "NoBody"
	empty.Parent = workspace
	local before = splatParts()
	state.hitSplat:Fire({ { empty, false, false, false } })
	task.wait(0.3)
	local plantedSplat = splatParts() <= before
	empty:Destroy()
	local attachmentsBefore = attachmentsUnderTerrain()
	GunFx.Tracer(state.gun, state.gun + Vector3.new(0.2, 0, 0), "bullet", nil)
	local plantedTracer = attachmentsUnderTerrain() == attachmentsBefore
	state.storm:Fire({ status = "Idle" })
	task.wait(0.2)
	local plantedStorm = workspace:FindFirstChild("StormWall") == nil
	note(string.format("self-test: bodiless victim added splats %s; sub-half-stud tracer flew %s; Idle storm left the ring up %s",
		plantedSplat and "no" or "YES", plantedTracer and "no" or "YES", plantedStorm and "no" or "YES"))
	check(plantedSplat and plantedTracer and plantedStorm, "planted effect faults behave (so the checks above can fail)")
	look(camera, ARENA_CENTRE + Vector3.new(-6, ARENA_HEIGHT + 9, 0), ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0), 62)
end, 1)

add("result", function(_, camera)
	note(string.format("RESULT %s: %d checks, %d failed", state.failures == 0 and "PASS" or "FAIL", state.checks, state.failures))
	look(camera, ARENA_CENTRE + Vector3.new(-6, ARENA_HEIGHT + 9, 0), ARENA_CENTRE + Vector3.new(18, ARENA_HEIGHT + 3.5, 0), 62)
end, 1)

_G.__ExplosiveFxModule = ExplosiveFx

return views
