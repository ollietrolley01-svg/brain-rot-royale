-- The vote screen and the drop picker, rendered from the REAL modules (Oliver's #2 and #1):
--
--   powershell -ExecutionPolicy Bypass -File tools/gallery.ps1 -Gallery <this file> -OutDir <folder> -Hold 1 -TimeoutSeconds 2400
--
-- Everything here draws StarterPlayerScripts/VoteScreen.lua and StarterPlayerScripts/DropPicker.lua
-- themselves, fed by ServerScriptService/Modules/VoteService.lua and DropMapService.lua themselves.
-- Nothing in this file is a replica of the screens: a replica is how a screen ends up proven
-- against a shape the game does not send.
--
-- The views:
--   build     builds the map for real, samples it through DropMapService, prints the sample cost,
--             the wire size and the round-trip error WITH A PLANTED FAULT, checks VoteService's
--             rules WITH A PLANTED FAULT, and looks straight down at the terrain — the reference
--             the drawn map is judged against
--   compare   the drawn map beside that same terrain from above, in one frame
--   vote      the vote on 1920x1080, 844x390 and 375x667; the unreadied state; the decided reveal
--   drop      the picker on the same three; the Frame fallback; both renderers at 1:1
--   cursor    the modal overlay and the MenuOpen handover, read off the real instances, WITH A
--             PLANTED FAULT (a picker built without the overlay must fail the same checks)
--
-- Set ONLY to a section name or a set; `build` always runs, because everything else reads its map.

local ONLY = nil

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Scripts = StarterPlayer:WaitForChild("StarterPlayerScripts")
local Modules = ServerScriptService:WaitForChild("Modules")

local UiKit = require(Scripts:WaitForChild("UiKit"))
local PhoneLayout = require(Scripts:WaitForChild("PhoneLayout"))
local VoteScreen = require(Scripts:WaitForChild("VoteScreen"))
local DropPicker = require(Scripts:WaitForChild("DropPicker"))
local MapData = require(Shared:WaitForChild("MapData"))

local create = UiKit.create
local C = UiKit.Colors
local Role, Type = UiKit.Role, UiKit.Type

local GUI_NAME = "BRR_VoteDropGallery"
local MAP_ID = "SahurSprings"
local SEED = 4242

local failures = 0
local function note(text)
	print("[BRR_Gallery] note " .. text)
end
local function check(ok, fmt, ...)
	if not ok then
		failures += 1
	end
	note(string.format("%s  " .. fmt, ok and "ok  " or "FAIL", ...))
end

local views = {}
local function add(section, view)
	if section == "build" or ONLY == nil or ONLY == section or (type(ONLY) == "table" and ONLY[section]) then
		table.insert(views, view)
	end
end

local SCREENS = {
	{ name = "1920x1080", size = Vector2.new(1920, 1080), touch = false },
	{ name = "844x390", size = Vector2.new(844, 390), touch = true },
	{ name = "375x667", size = Vector2.new(375, 667), touch = true },
}

local state = {}

--------------------------------------------------------------------------------
-- Mock device screens
--------------------------------------------------------------------------------

local Mock = {}

function Mock.clear()
	local old = StarterGui:FindFirstChild(GUI_NAME)
	if old then
		old:Destroy()
	end
end

function Mock.gui()
	Mock.clear()
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 10
	gui.Parent = StarterGui
	return gui
end

function Mock.sky(camera)
	camera.FieldOfView = 70
	camera.CFrame = CFrame.new(0, 600, 0) * CFrame.Angles(math.rad(8), 0, 0)
end

-- The HUD banner these panels share the screen with, so they are judged where they live.
local function banner(screen, spec, title, sub)
	local holder = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(440, 56),
		BackgroundColor3 = C.Background,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		ZIndex = 2,
		Parent = screen,
	}, { UiKit.rounded(12) })
	if spec.touch then
		local rect = PhoneLayout.Rects(spec.size).banner
		holder.AnchorPoint = Vector2.zero
		holder.Position = UDim2.fromOffset(rect.x, rect.y)
		create("UIScale", { Scale = rect.w / 440, Parent = holder })
	end
	create("TextLabel", {
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundTransparency = 1,
		Font = Enum.Font.FredokaOne,
		Text = title,
		TextColor3 = C.Text,
		TextSize = 20,
		ZIndex = 3,
		Parent = holder,
	})
	create("TextLabel", {
		Position = UDim2.fromOffset(0, 32),
		Size = UDim2.new(1, 0, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = sub,
		TextColor3 = C.Muted,
		TextSize = 14,
		ZIndex = 3,
		Parent = holder,
	})
end

function Mock.screen(gui, camera, spec, caption, bannerTitle, bannerSub)
	local viewport = camera.ViewportSize
	local fit = math.min(viewport.X * 0.94 / spec.size.X, viewport.Y * 0.9 / spec.size.Y)
	local screen = create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(spec.size.X, spec.size.Y),
		BackgroundColor3 = Color3.fromRGB(118, 160, 196),
		BorderSizePixel = 0,
		ClipsDescendants = true,
		Parent = gui,
	})
	create("UIScale", { Scale = fit, Parent = screen })
	create("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.fromRGB(150, 196, 236)),
			ColorSequenceKeypoint.new(0.55, Color3.fromRGB(214, 226, 232)),
			ColorSequenceKeypoint.new(0.56, Color3.fromRGB(104, 150, 82)),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(78, 118, 60)),
		}),
		Parent = screen,
	})
	create("TextLabel", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -8),
		Size = UDim2.new(1, -20, 0, 20),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = caption,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0.4,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 60,
		Parent = screen,
	})
	if bannerTitle then
		banner(screen, spec, bannerTitle, bannerSub or "")
	end
	return screen
end

--------------------------------------------------------------------------------
-- Driving the real VoteService
--------------------------------------------------------------------------------

local VoteService = require(Modules:WaitForChild("VoteService"))
local DropMapService = require(Modules:WaitForChild("DropMapService"))

-- A stand-in for a Player: VoteService reads readiness through GetAttribute and identity through
-- UserId, and nothing else. It is pcall'd there on purpose, so a token without GetAttribute reads
-- as NOT ready rather than throwing inside a remote handler — which is one of the things checked.
local function token(userId, ready)
	return {
		UserId = userId,
		GetAttribute = function(_, name)
			if name == "Ready" then
				return ready
			end
			return nil
		end,
	}
end

local function distinctModes(candidates)
	local seen, count = {}, 0
	for _, candidate in ipairs(candidates) do
		if not seen[candidate.modeId] then
			seen[candidate.modeId] = true
			count += 1
		end
	end
	return count
end

local function distinctMaps(candidates)
	local seen, count = {}, 0
	for _, candidate in ipairs(candidates) do
		if not seen[candidate.mapId] then
			seen[candidate.mapId] = true
			count += 1
		end
	end
	return count
end

-- Every rule the vote is supposed to have, checked against the module itself, plus a planted fault
-- proving the one-card-per-mode check reads the real roll.
local function checkVoteRules()
	VoteService.Random = Random.new(SEED)
	VoteService.Open()
	local candidates = VoteService.GetCandidates()
	check(#candidates == 3, "three cards are up (%d)", #candidates)
	check(distinctModes(candidates) == 3, "one card per mode (%d distinct modes)", distinctModes(candidates))
	check(distinctMaps(candidates) == 3, "each card on a different map (%d distinct maps)", distinctMaps(candidates))

	local unready = token(1001, false)
	local okUnready, whyUnready = VoteService.CastVote(unready, candidates[1].id)
	check(okUnready == false and whyUnready == "Ready up to vote.",
		"an unreadied player cannot vote (%s / %s)", tostring(okUnready), tostring(whyUnready))

	local ready = token(1002, true)
	local okReady = VoteService.CastVote(ready, candidates[2].id)
	check(okReady == true, "a readied player can vote (%s)", tostring(okReady))

	local okJunk = VoteService.CastVote(ready, "NoSuchMode|NoSuchMap")
	check(okJunk == false, "a card that is not up is refused (%s)", tostring(okJunk))

	-- Re-voting moves the vote rather than adding one.
	VoteService.CastVote(ready, candidates[3].id)
	local snapshot = VoteService.Snapshot()
	local total = 0
	for _, entry in ipairs(snapshot.candidates) do
		total += entry.votes
	end
	check(total == 1, "re-voting moves the vote instead of adding one (%d votes on the board)", total)
	check(snapshot.votes[tostring(1002)] == candidates[3].id, "the voter's own choice comes back keyed by a STRING UserId")

	local mapId, modeId = VoteService.Resolve()
	local mapId2, modeId2 = VoteService.Resolve()
	check(mapId == mapId2 and modeId == modeId2, "Resolve caches, so two callers get the same match (%s/%s then %s/%s)",
		tostring(mapId), tostring(modeId), tostring(mapId2), tostring(modeId2))
	check(modeId == candidates[3].modeId and mapId == candidates[3].mapId,
		"the winner is the card with the votes (%s on %s)", tostring(modeId), tostring(mapId))

	-- Nobody votes: the Battle Royale card wins because that is the main game.
	VoteService.Open()
	local _, emptyMode = VoteService.Resolve()
	check(emptyMode == "BattleRoyale", "a vote nobody cast goes to Battle Royale (%s)", tostring(emptyMode))

	-- PLANTED FAULT, every run. With the mode list duplicated, the one-card-per-mode check above
	-- must read 1 instead of 3 — which is the proof it is reading the real roll and not a constant.
	local realOrder = VoteService.ModeOrder
	VoteService.ModeOrder = { "BattleRoyale", "BattleRoyale", "BattleRoyale" }
	VoteService.Open()
	local planted = distinctModes(VoteService.GetCandidates())
	check(planted == 1, "planted fault: a duplicated mode list reads %d distinct modes, so the check is live", planted)
	VoteService.ModeOrder = realOrder

	-- THE PATH THE GAME TAKES. DropMapService.Current() reads VoteService's cached resolution, looks
	-- that map's radius up in MapData and serves the map standing in the workspace — no client input
	-- anywhere in it. Forced onto the map this gallery built by rolling seeds until it is on offer
	-- and voting for it, rather than skipped when it is not, so this can never quietly test nothing.
	local found
	for seed = 1, 60 do
		VoteService.Random = Random.new(seed)
		VoteService.Open()
		for _, candidate in ipairs(VoteService.GetCandidates()) do
			if candidate.mapId == MAP_ID then
				found = candidate
				break
			end
		end
		if found then
			break
		end
	end
	check(found ~= nil, "a roll offering %s was found in 60 seeds, so the served-payload check has something to test", MAP_ID)
	if found then
		VoteService.CastVote(token(3001, true), found.id)
		local votedMap = VoteService.Resolve()
		check(votedMap == MAP_ID, "the vote resolved onto the map this gallery built (%s)", tostring(votedMap))
		local served = DropMapService.Current()
		check(served ~= nil, "DropMapService.Current() serves a payload while a map is in the workspace")
		if served then
			check(served.radius == MapData.Get(MAP_ID).radius,
				"the served payload is at the built map's scale (%d studs)", served.radius)
			check(served == state.served,
				"Current() answers with the CACHED payload rather than sampling the map a second time")
		end
	end

	-- Back to a real, seeded vote for the screens to draw.
	VoteService.Random = Random.new(SEED)
	VoteService.Open()
	local list = VoteService.GetCandidates()
	VoteService.CastVote(token(2001, true), list[1].id)
	VoteService.CastVote(token(2002, true), list[1].id)
	VoteService.CastVote(token(2003, true), list[2].id)
	state.voteSnapshot = VoteService.Snapshot()
	state.myVote = list[1].id
	state.winnerId = list[1].id
end

-- The client's shape: the snapshot as it arrives, plus which card is mine.
local function candidatesFor(snapshot, myVote)
	local out = {}
	for index, candidate in ipairs(snapshot.candidates) do
		out[index] = {
			id = candidate.id,
			mode = candidate.mode,
			map = candidate.map,
			votes = candidate.votes,
			mine = myVote == candidate.id,
		}
	end
	return out
end

--------------------------------------------------------------------------------
-- Views
--------------------------------------------------------------------------------

add("build", {
	name = "build_topdown_" .. MAP_ID,
	settle = 3,
	setup = function(_, camera)
		Mock.clear()
		math.randomseed(SEED)
		local MapGenerator = require(Modules:WaitForChild("MapGenerator"))
		local started = tick()
		local ok, info = pcall(MapGenerator.Build, MAP_ID)
		if not ok then
			note("BUILD FAILED: " .. tostring(info))
			error(info)
		end
		state.info = info
		state.map = info.map
		note(string.format("built %s in %.1fs wall, radius %d", MAP_ID, tick() - started, info.radius))

		-- The REAL sampler, on the REAL map. Sample and Encode are called apart rather than through
		-- For(), for one reason: the raw heights are the only thing the quantiser's error can be
		-- measured AGAINST. Re-quantising the decoded heights — which is what the first draft of this
		-- check did — measures nothing at all, because they are already on a quantiser step.
		started = tick()
		local raster = DropMapService.Sample(info.map, info.radius)
		local sampleSeconds = tick() - started
		local payload = DropMapService.Encode(raster, info.map, info.mapName)
		state.payload = payload
		local c = payload.counts
		note(string.format("raster %dx%d: %d cells in the disc, groundless %d, water %d, built %d (stamped %d), landmark %d, paved %d, heights %.1f..%.1f, %.2fs",
			payload.n, payload.n, c.samples, c.groundless, c.water, c.built, c.stampedBuilt, c.landmark, c.paved,
			payload.min, payload.max, sampleSeconds))
		note(string.format("vectors: %d road segments (%d over the cap), river %d points, %d towns, %d landmarks",
			c.roadSegments, c.roadSkipped, #payload.river > 0 and select(2, string.gsub(payload.river, ";", ";")) + 1 or 0,
			#payload.towns, #payload.landmarks))
		note(string.format("wire: classes %d + heights %d + roads %d + river %d = %.1f KB",
			#payload.classes, #payload.heights, #payload.roads, #payload.river,
			(#payload.classes + #payload.heights + #payload.roads + #payload.river) / 1024))

		-- The scale check described in DropMapService: a radius that had slipped would show up as a
		-- disc full of cells with no ground under them.
		check(c.groundless <= c.samples * 0.02, "the sampled disc is on the map: %d of %d cells found no ground",
			c.groundless, c.samples)
		check(c.roadSegments > 40, "the roads came through as vectors (%d segments)", c.roadSegments)
		check(#payload.towns > 0 and #payload.landmarks > 0, "towns (%d) and landmarks (%d) travel WITH the map, so a streamed-out client can still label it",
			#payload.towns, #payload.landmarks)

		-- The wire round-trips, and a planted fault in it is caught.
		started = tick()
		local data = DropPicker.Decode(payload)
		local decodeSeconds = tick() - started
		local mismatches, worst = 0, 0
		for i = 1, payload.n * payload.n do
			if string.sub(payload.classes, i, i) ~= data.classes[i] then
				mismatches += 1
			end
		end
		-- Height error against the RAW sample: this is what the shading is drawn from, and 64 levels
		-- over the map's own span is the only lossy step in the whole path.
		for i = 1, payload.n * payload.n do
			worst = math.max(worst, math.abs(data.heights[i] - raster.heights[i]))
		end
		check(mismatches == 0, "the wire round-trips: %d class mismatches, worst height error %.2f studs over a %.0f-stud span, decoded in %.2fs",
			mismatches, worst, payload.max - payload.min, decodeSeconds)

		local centre = (payload.n / 2) * payload.n + payload.n / 2
		local original = string.sub(payload.classes, centre, centre)
		local broken = table.clone(payload)
		broken.classes = string.sub(payload.classes, 1, centre - 1)
			.. (original == "w" and "g" or "w")
			.. string.sub(payload.classes, centre + 1)
		local brokenData = DropPicker.Decode(broken)
		local caught = 0
		for i = 1, payload.n * payload.n do
			if brokenData.classes[i] ~= data.classes[i] then
				caught += 1
			end
		end
		check(caught == 1, "planted fault: one flipped byte on the wire shows up as %d changed cell(s)", caught)

		-- THE CACHE, measured rather than asserted: the first For() samples, the second answers from
		-- the cache. Fifty clients ask for this within a second of each other at the start of every
		-- match, so "it is cached" is the load-bearing claim in this whole module.
		started = tick()
		local first = DropMapService.For(info.map, info.radius, info.mapName)
		local firstSeconds = tick() - started
		started = tick()
		local secondPayload = DropMapService.For(info.map, info.radius, info.mapName)
		local secondSeconds = tick() - started
		check(secondPayload == first, "a second request answers with the same payload object")
		check(secondSeconds < firstSeconds / 10 or secondSeconds < 0.01,
			"the second request is served from the cache (%.3fs then %.3fs)", firstSeconds, secondSeconds)
		state.served = first

		checkVoteRules()

		-- A pick a little way out from the first landmark, so the readout has something to say.
		local first = payload.landmarks[1]
		if first then
			state.pick = Vector2.new(first.x + 240, first.z - 170)
		else
			state.pick = Vector2.new(info.radius * 0.3, -info.radius * 0.2)
		end

		-- Straight down, north up, the whole disc in frame.
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(Vector3.new(0, info.radius * 1.5, 0), Vector3.zero, Vector3.new(0, 0, -1))
	end,
})

-- The drawn map and the terrain it is a picture of, in one frame: the camera looks straight down
-- from east of the centre, which puts the real map in the left half and leaves the right half for
-- the drawn one.
add("compare", {
	name = "drawn_map_vs_real_terrain",
	settle = 2,
	setup = function(_, camera)
		local gui = Mock.gui()
		local radius = state.info and state.info.radius or 1280
		camera.FieldOfView = 70
		camera.CFrame = CFrame.lookAt(
			Vector3.new(radius * 1.05, radius * 2.2, 0),
			Vector3.new(radius * 1.05, 0, 0),
			Vector3.new(0, 0, -1))

		local px = math.min(560, math.floor(camera.ViewportSize.Y * 0.62))
		local holder = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -60, 0.5, 0),
			Size = UDim2.fromOffset(px, px),
			BackgroundTransparency = 1,
			Parent = gui,
		})
		local data = DropPicker.Decode(state.payload)
		local started = tick()
		local view = DropPicker.DrawMap(holder, data, px, { labelSize = 13 })
		note(string.format("compare view: %s renderer, %s, drawn in %.2fs; labels placed %d (moved %d), dropped %d",
			view.renderer, view.detail, tick() - started, view.labels.placed, view.labels.moved, view.labels.dropped))
		view.setPick(state.pick.X, state.pick.Y)

		for _, item in ipairs({
			{ "THE REAL TERRAIN, FROM ABOVE", 0.25 },
			{ "THE MAP THE PICKER DRAWS", 0.78 },
		}) do
			create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(item[2], 0, 0, 24),
				Size = UDim2.fromOffset(460, 26),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBold,
				Text = item[1],
				TextColor3 = Color3.new(1, 1, 1),
				TextStrokeTransparency = 0.3,
				TextSize = 20,
				Parent = gui,
			})
		end
		create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -14),
			Size = UDim2.fromOffset(1200, 22),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = string.format("%s, radius %d studs — both north-up, same seed, same build",
				state.info and state.info.mapName or MAP_ID, radius),
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.4,
			TextSize = 16,
			Parent = gui,
		})
	end,
})

for _, spec in ipairs(SCREENS) do
	add("vote", {
		name = "vote_" .. spec.name,
		settle = 1.4,
		setup = function(_, camera)
			local gui = Mock.gui()
			Mock.sky(camera)
			local screen = Mock.screen(gui, camera, spec,
				spec.name .. "  ·  form " .. UiKit.form(spec.size) .. "  ·  VoteScreen.lua on VoteService's own payload",
				"STARTING IN 12", "Vote for the mode and the map")
			VoteScreen.ViewportForTest = spec.size
			local vote = VoteScreen.new({ parent = screen, zIndex = 36, touch = spec.touch })
			vote:Render({
				open = true,
				candidates = candidatesFor(state.voteSnapshot, state.myVote),
				seconds = 12,
				total = 15,
				ready = true,
			})
			VoteScreen.ViewportForTest = nil
		end,
	})
end

add("vote", {
	name = "vote_not_ready_844x390",
	settle = 1.4,
	setup = function(_, camera)
		local spec = SCREENS[2]
		local gui = Mock.gui()
		Mock.sky(camera)
		local screen = Mock.screen(gui, camera, spec,
			spec.name .. "  ·  NOT READIED: the cards are disabled and say so  ·  VoteScreen.lua",
			"STARTING IN 12", "Ready up to join the next match")
		VoteScreen.ViewportForTest = spec.size
		local vote = VoteScreen.new({ parent = screen, zIndex = 36, touch = spec.touch })
		vote:Render({
			open = true,
			candidates = candidatesFor(state.voteSnapshot, nil),
			seconds = 12,
			total = 15,
			ready = false,
		})
		VoteScreen.ViewportForTest = nil
	end,
})

add("vote", {
	name = "vote_decided_1920x1080",
	settle = 1.4,
	setup = function(_, camera)
		local spec = SCREENS[1]
		local gui = Mock.gui()
		Mock.sky(camera)
		local screen = Mock.screen(gui, camera, spec,
			spec.name .. "  ·  the reveal once the countdown ends  ·  VoteScreen.lua",
			"BUILDING MAP…", "Generating terrain, towns and loot")
		VoteScreen.ViewportForTest = spec.size
		local vote = VoteScreen.new({ parent = screen, zIndex = 36, touch = spec.touch })
		vote:Render({
			open = false,
			decided = state.winnerId,
			candidates = candidatesFor(state.voteSnapshot, state.myVote),
			seconds = 0,
			total = 15,
			ready = true,
		})
		VoteScreen.ViewportForTest = nil
	end,
})

local function drawPicker(screen, spec, options)
	options = options or {}
	DropPicker.ViewportForTest = spec.size
	DropPicker.ForceCells = options.cells == true
	local picker = DropPicker.new({
		parent = screen,
		zIndex = 40,
		touch = spec.touch,
		totalSeconds = 15,
	})
	picker:SetSeconds(options.seconds or 12)
	picker:SetPayload(state.payload)
	picker:SetVisible(true)
	if state.pick then
		picker:SetPick(state.pick.X, state.pick.Y, true)
	end
	local view = picker.mapView
	if view then
		local overlapping = 0
		local rects = view.labels.rects
		for i = 1, #rects do
			for j = i + 1, #rects do
				local a, b = rects[i], rects[j]
				if a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h then
					overlapping += 1
				end
			end
		end
		note(string.format("%s: %s renderer, %s; labels placed %d (moved %d), dropped %d, overlapping %d",
			spec.name, view.renderer, view.detail, view.labels.placed, view.labels.moved, view.labels.dropped, overlapping))
		check(overlapping == 0, "%s: no two labels overlap (%d placed, %d moved off their first anchor, %d dropped)",
			spec.name, view.labels.placed, view.labels.moved, view.labels.dropped)
		-- PLANTED FAULT: the same overlap test, on two rectangles that certainly do overlap.
		local a = { x = 10, y = 10, w = 40, h = 20 }
		local b = { x = 30, y = 20, w = 40, h = 20 }
		local caught = a.x < b.x + b.w and b.x < a.x + a.w and a.y < b.y + b.h and b.y < a.y + a.h
		check(caught, "planted fault: the overlap test still reports a known overlap")
	end
	DropPicker.ViewportForTest = nil
	DropPicker.ForceCells = false
	return picker
end

for _, spec in ipairs(SCREENS) do
	add("drop", {
		name = "drop_" .. spec.name,
		settle = 1.6,
		setup = function(_, camera)
			local gui = Mock.gui()
			Mock.sky(camera)
			local screen = Mock.screen(gui, camera, spec,
				spec.name .. "  ·  form " .. UiKit.form(spec.size) .. "  ·  DropPicker.lua on DropMapService's own payload",
				"CHOOSE YOUR DROP  12", "Pick where you land")
			drawPicker(screen, spec, { seconds = 12 })
		end,
	})
end

add("drop", {
	name = "drop_cells_fallback_1920x1080",
	settle = 1.6,
	setup = function(_, camera)
		local spec = SCREENS[1]
		local gui = Mock.gui()
		Mock.sky(camera)
		local screen = Mock.screen(gui, camera, spec,
			spec.name .. "  ·  FALLBACK renderer: no EditableImage, same raster, same roads  ·  DropPicker.lua",
			"CHOOSE YOUR DROP  12", "Pick where you land")
		drawPicker(screen, spec, { seconds = 12, cells = true })
	end,
})

add("drop", {
	name = "drop_image_vs_cells_1to1",
	settle = 1.8,
	setup = function(_, camera)
		local gui = Mock.gui()
		Mock.sky(camera)
		local px = 520
		local holder = create("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Role.Base,
			BorderSizePixel = 0,
			Parent = gui,
		})
		local data = DropPicker.Decode(state.payload)
		local left = create("Frame", {
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(0.5, -30, 0.5, 0),
			Size = UDim2.fromOffset(px, px),
			BackgroundTransparency = 1,
			Parent = holder,
		})
		local right = create("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0.5, 30, 0.5, 0),
			Size = UDim2.fromOffset(px, px),
			BackgroundTransparency = 1,
			Parent = holder,
		})
		local a = DropPicker.DrawMap(left, data, px, { labelSize = 12 })
		a.setPick(state.pick.X, state.pick.Y)
		local cellData = DropPicker.Decode(state.payload)
		local b = DropPicker.DrawMap(right, cellData, px, { labelSize = 12, cells = true })
		b.setPick(state.pick.X, state.pick.Y)
		note(string.format("1:1 — image: %s; cells: %s", tostring(a.detail), tostring(b.detail)))
		for _, item in ipairs({ { "EditableImage", 0.25 }, { "Frame fallback", 0.75 } }) do
			create("TextLabel", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(item[2], 0, 0, 30),
				Size = UDim2.fromOffset(420, 24),
				BackgroundTransparency = 1,
				Font = Type.Heading.Font,
				Text = item[1],
				TextColor3 = Role.Text,
				TextSize = Type.Heading.Size,
				Parent = holder,
			})
		end
	end,
})

-- THE CURSOR. Read off the real instances rather than off the source, with a picker built without
-- the overlay in the same run to prove the checks can fail.
add("cursor", {
	name = "cursor_modal_and_menuopen",
	settle = 1.4,
	setup = function(_, camera)
		local spec = SCREENS[1]
		local gui = Mock.gui()
		Mock.sky(camera)
		local screen = Mock.screen(gui, camera, spec,
			"The modal overlay that frees the mouse, and the MenuOpen handover  ·  checked live, with a planted fault",
			"CHOOSE YOUR DROP  9", "Pick where you land")

		local log = {}
		DropPicker.ViewportForTest = spec.size
		local picker = DropPicker.new({
			parent = screen,
			zIndex = 40,
			touch = false,
			totalSeconds = 15,
			onMenuOpen = function(open)
				table.insert(log, open)
			end,
		})
		picker:SetSeconds(9)
		picker:SetPayload(state.payload)
		picker:SetVisible(true)
		picker:SetPick(state.pick.X, state.pick.Y, true)

		local modal = picker.modal
		check(modal ~= nil, "the picker carries an overlay of its own")
		check(modal and modal:IsA("GuiButton"), "the overlay is a GuiButton, not a Frame — a Frame would dim the screen and free nothing")
		check(modal and modal.Modal == true, "the overlay is Modal: THIS is the property that frees the cursor")
		check(modal and modal.Size == UDim2.fromScale(1, 1), "the overlay covers the whole screen (%s)",
			modal and tostring(modal.Size) or "none")
		check(modal and modal.Visible == true, "the overlay is up while the window is up")
		check(#log == 1 and log[1] == true, "MenuOpen is claimed once when the window opens (%d call(s))", #log)

		picker:SetVisible(false)
		check(modal and modal.Visible == false, "the overlay comes down with the window, so the cursor goes back")
		check(#log == 2 and log[2] == false, "MenuOpen is released exactly once when the window closes (%d call(s))", #log)
		picker:SetVisible(true)

		-- PLANTED FAULT, every run: the same checks against a picker built without the overlay must
		-- fail. Without this, a check that had stopped finding anything would report a clean pass.
		local broken = DropPicker.new({ parent = screen, zIndex = 20, touch = false, noModal = true })
		broken:SetVisible(true)
		local plantedPasses = broken.modal ~= nil and broken.modal.Modal == true
		check(not plantedPasses, "planted fault: a picker built without the overlay fails the overlay check")
		broken:Destroy()

		DropPicker.ViewportForTest = nil

		create("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 96),
			Size = UDim2.fromOffset(900, 26),
			BackgroundTransparency = 1,
			Font = Enum.Font.GothamBold,
			Text = "Modal overlay UP (the dimmed screen) — cursor free while the picker is open",
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.3,
			TextSize = 18,
			ZIndex = 80,
			Parent = screen,
		})
	end,
})

add("cursor", {
	name = "zz_summary",
	settle = 1,
	setup = function()
		Mock.clear()
		note(string.format("CHECKS: %d failure(s)", failures))
	end,
})

return views
