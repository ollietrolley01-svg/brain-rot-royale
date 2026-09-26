-- Bot driving on the real maps: what stops bot drivers (tasks 13 and 23), in Run mode with real
-- Roblox physics. tools/bot_driving_sim.py proves the same code in lupa against boxes built from the
-- sizes this probe logs; this is the part only Studio can answer.
--
-- Run with: python tools/linux/studio.py runtest -Probe tools/bot_driving_maps_probe.lua -WaitSeconds 2400
--   (or tools/runtest.ps1 with the same arguments on Windows)
--
-- Lines start "[BRR_DriveMaps]". For each map in MAPS (rebuilt, up to P.bridgeBuilds times, until
-- it has a bridge):
--   ROAM     P.roamBots bots put down beside the map's parked vehicles for P.roamSeconds, each sent
--            to another parked car 300+ studs off (a trip, as the storm makes them). Every reversing
--            manoeuvre ("recovery") and every "stuck" report is logged with what is really in front
--            of the car: each collidable part in its footprint grown ahead (name, shape, size, top
--            above the ground under the car), rays straight ahead at 0.6 / 1.0 / 1.6 / 2.6 studs above
--            the ground (terrain included), the front sweep DriveSense makes, replayed (what it hit,
--            its normal, whether BotNav's `blocking` counted it), and what that sweep met first on
--            each of the 8 looks before.
--   BRIDGES  each car model in turn, a bot at its wheel, from 55 studs before each bridge to 150
--            past the far end, both ways: crossed or not, seconds on the deck, stops (under 2.5
--            studs/s on the deck), recoveries on it, parapet contacts (a chassis corner at the
--            parapet's inner face).
-- Every car has its gun seat taken off first (P.unarm): an armed car waits for a gunner and goes nowhere.
-- A crossing anywhere (ROAM too) is counted from the BridgeDeck parts: on at one end, off at the other.
-- Totals per map and overall: stuck reports and recoveries per driving bot-minute, crossings.
--
-- Nothing here edits game code: the one wrap (BotNav.DriveSense) calls the real function and reads
-- what it left on the drive. The casts it adds are the probe's own, outside the bots' ray budget.

local MAPS = { "SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains" }
local P = {
	roamBots = 18,
	roamSeconds = 120,
	bridgeBuilds = 4,
	trialSeconds = 40,
	approach = 55,
	beyond = 150,
	models = { "Rotster", "CrocodiloRanger", "TralalaGT", "SahurVan" },
	maxEventLines = 40,
}

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function say(fmt, ...)
	print(string.format("[BRR_DriveMaps] " .. fmt, ...))
end

if not RunService:IsRunning() then
	say("starting run mode")
	RunService:Run()
end
task.wait(6)

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
P.MapGenerator = require(modules:WaitForChild("MapGenerator"))
P.CombatService = require(modules:WaitForChild("CombatService"))
P.VehicleService = require(modules:WaitForChild("VehicleService"))
P.BotService = require(modules:WaitForChild("BotService"))
P.BotNav = require(modules:WaitForChild("BotNav"))
P.MatchConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("MatchConfig"))
P.VehicleService.Start()

function P.flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

function P.modelOf(drive)
	local model = drive.chassis and drive.chassis.Parent
	return model and (model:GetAttribute("VehicleModel") or model.Name) or "?"
end

-- The part's top, in world Y, from its bounding box.
function P.topOf(part)
	local cf, s = part.CFrame, part.Size
	local half = math.abs(cf.RightVector.Y) * s.X / 2 + math.abs(cf.UpVector.Y) * s.Y / 2 + math.abs(cf.LookVector.Y) * s.Z / 2
	return part.Position.Y + half
end

function P.chain(part)
	local a = part.Parent
	local b = a and a.Parent
	return string.format("%s/%s", b and b.Name or "-", a and a.Name or "-")
end

function P.shape(part)
	if part:IsA("Part") then
		return tostring(part.Shape.Name)
	end
	return part.ClassName
end

-- The same test as BotNav's local `blocking` (copied, as the sim cuts it out; the plant in
-- bot_driving_sim keeps them honest): would DriveSense count this hit?
function P.counts(hit)
	if not hit then
		return false
	end
	if hit.Normal.Y > P.normalLimit then
		return false
	end
	local part = hit.Instance
	if part and part:IsA("BasePart") and not part:IsA("Terrain") and not part.CanCollide then
		return false
	end
	return true
end
P.normalLimit = 0.6

-- Where a car is: over a bridge deck (which, and how far along and across), or not.
function P.onDeck(position)
	for index, deck in ipairs(P.decks or {}) do
		local rel = deck.cf:PointToObjectSpace(position)
		if math.abs(rel.X) < deck.size.X / 2 + 1 and math.abs(rel.Z) < deck.size.Z / 2 and rel.Y > -2 and rel.Y < 9 then
			return index, rel
		end
	end
	return nil
end

-- What is really in front of a car that has just stopped: printed, and tallied by part name.
function P.diagnose(drive, status, now, hist, into)
	local chassis = drive.chassis
	local cf = chassis.CFrame
	local pos = cf.Position
	local look = P.flat(cf.LookVector)
	look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, -1)
	local right = Vector3.new(-look.Z, 0, look.X)
	local ground = pos.Y - drive.rideHeight
	local deck = P.onDeck(pos)
	local key = P.mapId .. " " .. P.modelOf(drive)
	local lines = {}
	local culprits = {}
	-- The front sweep, replayed as DriveSense makes it.
	local width = drive.halfWidth * 2 + 1
	local boxAt = Vector3.new(pos.X, ground + 2.6, pos.Z)
	local sweep = workspace:Blockcast(CFrame.lookAt(boxAt, boxAt + look), Vector3.new(width, 2.6, 1), look * (drive.halfLength + 12), drive.params)
	table.insert(lines, string.format("sweep %s", sweep and string.format("%s n.y %.2f d %.1f counted %s", sweep.Instance.Name, sweep.Normal.Y,
		sweep.Distance - drive.halfLength, tostring(P.counts(sweep))) or "clear"))
	-- Rays straight ahead from the nose, low to high (terrain included).
	for _, height in ipairs({ 0.6, 1.0, 1.6, 2.6 }) do
		for _, across in ipairs({ -1, 0, 1 }) do
			local origin = Vector3.new(pos.X, ground + height, pos.Z) + look * (drive.halfLength - 1) + right * (across * (drive.halfWidth - 0.4))
			local hit = workspace:Raycast(origin, look * 6, drive.params)
			if hit and (hit.Instance:IsA("Terrain") or hit.Instance.CanCollide) then
				local name = hit.Instance:IsA("Terrain") and ("Terrain:" .. hit.Material.Name) or hit.Instance.Name
				culprits[name] = culprits[name] or { ray = {} }
				culprits[name].ray[string.format("%.1f", height)] = string.format("d%.1f n.y%.2f", hit.Distance - 1, hit.Normal.Y)
			end
		end
	end
	-- Every collidable part in the footprint grown ahead and to the sides.
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = drive.params.FilterDescendantsInstances
	local boxCF = CFrame.lookAt(Vector3.new(pos.X, ground + 3, pos.Z), Vector3.new(pos.X, ground + 3, pos.Z) + look) * CFrame.new(0, 0, -3)
	for _, part in ipairs(workspace:GetPartBoundsInBox(boxCF, Vector3.new(drive.halfWidth * 2 + 3, 6.4, drive.halfLength * 2 + 6), overlap)) do
		if part.CanCollide and part.Transparency < 1 then
			local rel = cf:PointToObjectSpace(part.Position)
			local top = P.topOf(part) - ground
			if top > 0.35 then
				local entry = culprits[part.Name] or { ray = {} }
				culprits[part.Name] = entry
				entry.part = string.format("%s %s size(%.1f,%.1f,%.1f) top %.2f at(%.1f right, %.1f ahead) up.y %.2f", P.chain(part), P.shape(part),
					part.Size.X, part.Size.Y, part.Size.Z, top, rel.X, -rel.Z, part.CFrame.UpVector.Y)
			end
		end
	end
	local names = {}
	for name, entry in pairs(culprits) do
		local rays = {}
		for h, text in pairs(entry.ray) do
			table.insert(rays, h .. ":" .. text)
		end
		table.sort(rays)
		table.insert(lines, string.format("  %s | %s | rays %s", name, entry.part or "(no part in footprint)", table.concat(rays, " ")))
		table.insert(names, name)
		P.tally[name] = (P.tally[name] or 0) + (status == "stuck" and 3 or 1)
	end
	P.events += 1
	if P.events <= P.maxEventLines * #MAPS then
		say("EVENT %s %s (%s) tries %d speed %.1f %s ride %.2f front %s blocked %s avoid %s | %s | looks before (first hit: ! counted, ~ ignored, @studs past the nose, /v speed, A detouring): %s",
			key, status, into or "", drive.stuck.tries, chassis.AssemblyLinearVelocity.Magnitude, deck and ("ON BRIDGE " .. deck) or "", drive.rideHeight,
			tostring(drive.front ~= nil), tostring(drive.blocked), tostring(drive.avoid ~= nil), table.concat(lines, " || "), table.concat(hist or {}, " "))
	end
	return names
end

-- The wrap: the real DriveSense, then what it did.
P.realSense = P.BotNav.DriveSense
P.drives = {}
P.BotNav.DriveSense = function(drive, now)
	local before = drive.stats.recoveries
	local status = P.realSense(drive, now)
	local ok, err = pcall(function()
		local st = P.drives[drive]
		local chassis = drive.chassis
		if not st then
			st = { model = P.modelOf(drive), from = chassis.Position, since = now }
			P.drives[drive] = st
		end
		-- Every look, where the car is along and across each bridge (a crossing is judged on these,
		-- not on the looks that land on the deck: at speed a 60-stud deck gets three).
		for index, deck in ipairs(P.decks or {}) do
			local r = deck.cf:PointToObjectSpace(chassis.Position)
			local half = deck.size.Z / 2
			if math.abs(r.Z) < half + 40 and math.abs(r.X) < 40 and r.Y > -20 and r.Y < 12 then
				st.span = st.span or {}
				local sp = st.span[index] or { min = math.huge, max = -math.huge, beside = 0 }
				st.span[index] = sp
				if math.abs(r.X) < deck.size.X / 2 + 1 then
					sp.min, sp.max = math.min(sp.min, r.Z), math.max(sp.max, r.Z)
				elseif math.abs(r.Z) < half then
					-- Beside the deck, between its ends: in the river.
					sp.beside += 1
				end
			end
		end
		local speed = chassis.AssemblyLinearVelocity.Magnitude
		local recovered = drive.stats.recoveries > before
		if recovered then
			P.count.recoveries += 1
		end
		if status == "stuck" then
			P.count.stuck += 1
		end
		if status == "hazard" then
			P.count.hazards += 1
		end
		-- What the front sweep met first this look (replayed), for the history a recovery prints.
		local cf = chassis.CFrame
		local look = P.flat(cf.LookVector)
		look = look.Magnitude > 0.05 and look.Unit or Vector3.new(0, 0, -1)
		local ground = cf.Position.Y - drive.rideHeight
		local boxAt = Vector3.new(cf.Position.X, ground + 2.6, cf.Position.Z)
		local reach = math.clamp(math.abs(chassis.AssemblyLinearVelocity:Dot(cf.LookVector)) * 1.1 + 16, 20, 90)
		local first = workspace:Blockcast(CFrame.lookAt(boxAt, boxAt + look), Vector3.new(drive.halfWidth * 2 + 1, 2.6, 1), look * reach, drive.params)
		st.hist = st.hist or {}
		table.insert(st.hist, string.format("%s%s@%.0f/v%.0f%s", first and (first.Instance:IsA("Terrain") and "T" or first.Instance.Name) or "-",
			first and (P.counts(first) and "!" or "~") or "", first and first.Distance - drive.halfLength or reach, speed, drive.avoid and "A" or ""))
		if #st.hist > 8 then
			table.remove(st.hist, 1)
		end
		local index, rel = P.onDeck(chassis.Position)
		if recovered or status == "stuck" or (status == "hazard" and (index or st.nearDeck)) then
			P.diagnose(drive, status, now, st.hist, string.format("%.0f studs %.0f s into the drive", (chassis.Position - st.from).Magnitude, now - st.since))
		end
		-- Bridge bookkeeping.
		if index then
			local deck = P.decks[index]
			if st.deck ~= index then
				-- The end it came on at (a look is 15 studs apart at speed; the parapets keep it off the sides).
				st.deck, st.enterSide, st.enterAt = index, rel.Z > 0 and 1 or -1, now
			end
			P.bridge.senses += 1
			if speed < 2.5 and not drive.stopping then
				P.bridge.stopSenses += 1
			end
			if recovered then
				P.bridge.recoveries += 1
			end
			if drive.avoid then
				P.bridge.avoidSenses += 1
			end
			if drive.front then
				P.bridge.frontSenses += 1
			end
			-- A chassis corner at the parapet's inner face (9.5 from the centre, the deck half-width less 1).
			local inner = deck.size.X / 2 - 1
			local s = chassis.Size
			for _, cx in ipairs({ -1, 1 }) do
				for _, cz in ipairs({ -1, 1 }) do
					local corner = deck.cf:PointToObjectSpace(chassis.CFrame:PointToWorldSpace(Vector3.new(cx * s.X / 2, 0, cz * s.Z / 2)))
					if math.abs(corner.X) > inner - 0.15 then
						P.bridge.parapet += 1
						st.parapetHit = true
					end
				end
			end
		elseif st.deck then
			local deck = P.decks[st.deck]
			if deck then
				local rel2 = deck.cf:PointToObjectSpace(chassis.Position)
				local exitSide = rel2.Z > 0 and 1 or -1
				if exitSide == -st.enterSide and math.abs(rel2.Z) >= deck.size.Z / 2 - 1 then
					P.bridge.crossings += 1
					P.bridge.seconds += now - st.enterAt
					st.crossed = (st.crossed or 0) + 1
					say("CROSSED %s %s bridge %d (%.0f long) in %.1fs%s", P.mapId, st.model, st.deck, deck.size.Z, now - st.enterAt,
						st.parapetHit and " (touched a parapet)" or "")
				else
					P.bridge.aborted += 1
					say("OFF BRIDGE %s %s bridge %d without crossing (entered side %d, left side %d, %.0f of %.0f along)", P.mapId, st.model, st.deck,
						st.enterSide, exitSide, rel2.Z, deck.size.Z)
				end
			end
			st.deck, st.parapetHit = nil, nil
		end
		st.nearDeck = false
		for _, deck in ipairs(P.decks or {}) do
			if (P.flat(deck.cf.Position) - P.flat(chassis.Position)).Magnitude < deck.size.Z / 2 + 40 then
				st.nearDeck = true
			end
		end
		if drive.wantedSpeed and drive.wantedSpeed > 6 or speed > 3 then
			P.count.driveSenses += 1
		end
	end)
	if not ok then
		say("PROBLEM wrap errored: %s", tostring(err))
	end
	return status
end

function P.resetCounts()
	P.drives = {}
	P.count = { recoveries = 0, stuck = 0, hazards = 0, driveSenses = 0 }
	P.bridge = { senses = 0, stopSenses = 0, recoveries = 0, avoidSenses = 0, frontSenses = 0, parapet = 0, crossings = 0, seconds = 0, aborted = 0 }
	P.tally = {}
	P.events = 0
end

function P.summary(label)
	local minutes = P.count.driveSenses * P.MatchConfig.BotThinkInterval / 60
	say("%s %s: driving bot-minutes %.1f, stuck %d (%.2f/min), recoveries %d (%.2f/min), hazards %d", label, P.mapId, minutes, P.count.stuck,
		P.count.stuck / math.max(minutes, 1e-6), P.count.recoveries, P.count.recoveries / math.max(minutes, 1e-6), P.count.hazards)
	local b = P.bridge
	say("%s %s bridges: crossings %d, aborted %d, s/crossing %.1f, deck senses %d, stopped %d, recoveries %d, avoiding %d, braking-for-front %d, parapet corner-samples %d",
		label, P.mapId, b.crossings, b.aborted, b.crossings > 0 and b.seconds / b.crossings or -1, b.senses, b.stopSenses, b.recoveries, b.avoidSenses,
		b.frontSenses, b.parapet)
	local names = {}
	for name, n in pairs(P.tally) do
		table.insert(names, { name, n })
	end
	table.sort(names, function(a, c)
		return a[2] > c[2]
	end)
	local parts = {}
	for i = 1, math.min(12, #names) do
		table.insert(parts, names[i][1] .. "=" .. names[i][2])
	end
	say("%s %s culprits (recovery 1, stuck 3): %s", label, P.mapId, table.concat(parts, ", "))
	P.total[label] = P.total[label] or {}
	local total = P.total[label]
	for key, value in pairs(P.count) do
		total[key] = (total[key] or 0) + value
	end
	for key, value in pairs(b) do
		total["bridge." .. key] = (total["bridge." .. key] or 0) + value
	end
end

function P.buildMap(mapId)
	P.BotService.Clear()
	for attempt = 1, P.bridgeBuilds do
		local info = P.MapGenerator.Build(mapId)
		local decks = {}
		for _, part in ipairs(info.map:GetDescendants()) do
			if part:IsA("BasePart") and part.Name == "BridgeDeck" then
				table.insert(decks, { cf = part.CFrame, size = part.Size, part = part })
			end
		end
		say("built %s (attempt %d): %d bridge(s)%s", mapId, attempt, #decks, #decks > 0 and string.format(", first %.0f long, grade %.1f%%", decks[1].size.Z,
			100 * decks[1].cf.LookVector.Y / math.max(0.01, P.flat(decks[1].cf.LookVector).Magnitude)) or "")
		if #decks > 0 or attempt == P.bridgeBuilds then
			P.BotService.SetRoads(info.roads)
			return info, decks
		end
		task.wait(1)
	end
end

-- An armed car waits for a gunner before it goes anywhere (BotService: "wait till it's manned"), and
-- most of a map's cars are armed. Its driving is the same without the gun seat, so the seat goes.
function P.unarm(model)
	local entry = model and P.VehicleService.Get(model)
	if entry and entry.gunnerSeat then
		entry.gunnerSeat:Destroy()
		entry.gunnerSeat = nil
	end
end

function P.roam(info)
	local parked = {}
	local folder = info.map:FindFirstChild("Vehicles")
	for _, model in ipairs(folder and folder:GetChildren() or {}) do
		if model:IsA("Model") and model.PrimaryPart then
			table.insert(parked, model)
			P.unarm(model)
		end
	end
	say("ROAM %s: %d parked vehicles", P.mapId, #parked)
	if #parked == 0 then
		return
	end
	local bots = P.BotService.Spawn(P.roamBots, function(index)
		local model = parked[(index * 7 - 1) % #parked + 1]
		return CFrame.new(model.PrimaryPart.Position + Vector3.new(12, 4, 0))
	end, function() end)
	P.BotService.Start()
	-- On trips, as in a match when the storm moves them on: each bot's goal is another parked car at
	-- least 300 studs off (past BotDriveMinTrip), picked again once it is near it.
	local t0 = os.clock()
	local pick = 0
	while os.clock() - t0 < P.roamSeconds do
		for _, bot in ipairs(bots) do
			local root = bot.character and bot.character:FindFirstChild("HumanoidRootPart")
			if root and (not bot.wanderGoal or (P.flat(bot.wanderGoal) - P.flat(root.Position)).Magnitude < 60) then
				for _ = 1, #parked do
					pick += 1
					local goal = parked[pick % #parked + 1].PrimaryPart.Position
					if (P.flat(goal) - P.flat(root.Position)).Magnitude > 300 then
						bot.wanderGoal = goal
						break
					end
				end
			end
			bot.lootTarget = nil
		end
		task.wait(1)
	end
	P.BotService.Clear()
end

-- The road's ground at a flat point, from above (the deck, the asphalt or the terrain).
function P.groundAt(point)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { P.folder }
	local hit = workspace:Raycast(Vector3.new(point.X, 400, point.Z), Vector3.new(0, -800, 0), params)
	return hit and hit.Position.Y or 0
end

function P.trials(decks)
	for index, deck in ipairs(decks) do
		local along = P.flat(deck.cf.LookVector).Unit
		for _, dir in ipairs({ 1, -1 }) do
			local forward = along * dir
			local right = Vector3.new(-forward.Z, 0, forward.X)
			local mid = P.flat(deck.cf.Position)
			local start = mid - forward * (deck.size.Z / 2 + P.approach) + right * 3.5
			local goal = mid + forward * (deck.size.Z / 2 + P.beyond) + right * 3.5
			for _, modelName in ipairs(P.models) do
				P.folder = Instance.new("Folder")
				P.folder.Name = "BRR_BridgeTrial"
				P.folder.Parent = workspace
				local yaw = math.atan2(-forward.X, -forward.Z)
				local at = Vector3.new(start.X, P.groundAt(start) + 3, start.Z)
				local car = P.VehicleService.Create(P.folder, at, yaw, "car", { model = modelName })
				P.unarm(car)
				-- Create parks on level footing and moves a car off a graded road: put it back in the lane.
				if car then
					car:PivotTo(CFrame.new(at + Vector3.new(0, 1, 0)) * CFrame.Angles(0, yaw, 0))
				end
				task.wait(1.5)
				local carAt = car and car:GetPivot().Position or at
				local bots = P.BotService.Spawn(1, function()
					return CFrame.new(carAt + right * 7 + Vector3.new(0, 2, 0))
				end, function() end)
				local bot = bots[1]
				P.BotService.Start()
				local t0 = os.clock()
				local crossedBefore = P.bridge.crossings
				local boarded = false
				while os.clock() - t0 < P.trialSeconds do
					bot.wanderGoal = goal
					bot.lootTarget = nil
					boarded = boarded or bot.ride ~= nil
					if P.bridge.crossings > crossedBefore and bot.ride and (P.flat(bot.ride.drive.chassis.Position) - goal).Magnitude < 60 then
						break
					end
					task.wait(0.25)
				end
				local chassis = car and car.PrimaryPart
				-- The deck's whole length driven over, from the looks' span (as well as the on/off count).
				local sp
				for d, st in pairs(P.drives) do
					if d.chassis and d.chassis.Parent and d.chassis:IsDescendantOf(P.folder) and st.span then
						sp = st.span[index]
					end
				end
				local half = deck.size.Z / 2
				local spanned = sp ~= nil and sp.min < -half + 3 and sp.max > half - 3
				say("TRIAL %s bridge %d dir %d %s: boarded %s, crossed %s (deck driven %s to %s of +-%.0f, %d looks beside it), %.0fs, ends %.0f from goal, last status %s",
					P.mapId, index, dir, modelName, tostring(boarded), tostring(P.bridge.crossings > crossedBefore or spanned),
					sp and string.format("%.0f", sp.min) or "-", sp and string.format("%.0f", sp.max) or "-", half, sp and sp.beside or 0, os.clock() - t0,
					chassis and (P.flat(chassis.Position) - goal).Magnitude or -1, tostring(bot.ride and bot.ride.lastStatus or bot.lastVehicleExit))
				P.trialCount = (P.trialCount or 0) + 1
				P.trialCrossed = (P.trialCrossed or 0) + ((P.bridge.crossings > crossedBefore or spanned) and 1 or 0)
				P.BotService.Clear()
				P.folder:Destroy()
				task.wait(0.5)
			end
		end
	end
end

P.total = {}
P.t0 = os.clock()
for _, mapId in ipairs(MAPS) do
	local ok, err = pcall(function()
		P.mapId = mapId
		P.resetCounts()
		local info, decks = P.buildMap(mapId)
		P.decks = decks
		P.CombatService.SetEnabled(true)
		task.wait(3)
		P.roam(info)
		P.summary("ROAM")
		P.resetCounts()
		if #decks > 0 then
			P.trials(decks)
		end
		P.summary("TRIALS")
	end)
	if not ok then
		say("PROBLEM %s errored: %s", mapId, tostring(err))
	end
end
for _, label in ipairs({ "ROAM", "TRIALS" }) do
	local t = P.total[label] or {}
	local minutes = (t.driveSenses or 0) * P.MatchConfig.BotThinkInterval / 60
	say("TOTAL %s: driving bot-minutes %.1f, stuck %d (%.2f/min), recoveries %d (%.2f/min), hazards %d; bridges: crossings %d, aborted %d, s/crossing %.1f, stopped senses %d, recoveries on deck %d, parapet samples %d",
		label, minutes, t.stuck or 0, (t.stuck or 0) / math.max(minutes, 1e-6), t.recoveries or 0, (t.recoveries or 0) / math.max(minutes, 1e-6), t.hazards or 0,
		t["bridge.crossings"] or 0, t["bridge.aborted"] or 0, (t["bridge.seconds"] or 0) / math.max(1, t["bridge.crossings"] or 0),
		t["bridge.stopSenses"] or 0, t["bridge.recoveries"] or 0, t["bridge.parapet"] or 0)
end
say("TOTAL trials: %d crossed of %d", P.trialCrossed or 0, P.trialCount or 0)
P.BotNav.DriveSense = P.realSense
P.BotService.Clear()
say("done")
