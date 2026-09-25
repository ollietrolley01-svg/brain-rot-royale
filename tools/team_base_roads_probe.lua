-- The team bases' roads to the arena on every real map (Oliver, 2026-09-24: "make sure the team bases
-- connect to the roads too", "...to the arena roads too", "make sure bots use the base roads to reach
-- the arena"). For each of the five maps and SEEDS: the map built, a team match set up (ModeTeams), and
-- for both bases:
--   * an access road was built and its gate reaches an arena gateway through mapInfo.roads.edges;
--   * the two teams' ways to the arena (access road + map road on to the gateway) within 10%;
--   * the biggest vehicle swept along the whole access road, above its surface: nothing solid in it
--     but the road itself (and the terrain under it);
--   * the real BotNav.DriveRoute from every bay's drive-out lane (and ModeTeams.BaseDriveVia) to the
--     team's gateway: at least 80% of the way on roads; to the arena's middle: into the apron only
--     from a gateway;
-- then a battle royale's map on the same server has no AccessRoad, no base, no gateway cut in its
-- road data.
--
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/team_base_roads_probe.lua -WaitSeconds 1500 -PlaceFile <rbxlx>
if not game or not game:GetService("RunService") then
	return
end
local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ModeTeams = require(modules:WaitForChild("ModeTeams"))
local BotNav = require(modules:WaitForChild("BotNav"))
local TB = require(modules:WaitForChild("TeamBattleground"))
local TeamBaseRoads = require(modules:WaitForChild("TeamBaseRoads"))
local GameModes = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("GameModes"))

local SEEDS = { 101, 7 }
local VEHICLE_HALF_WIDTH, VEHICLE_HEIGHT = 5.5, 10.3
local FOLLOW, FAIR = 0.8, 0.1
local function out(fmt, ...)
	print("[BASEROADS] " .. string.format(fmt, ...))
end
local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end
local function segDist(p, a, b)
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-9), 0, 1)
	return (p - (a + ab * t)).Magnitude
end

local bad, maps = 0, 0
local function fail(fmt, ...)
	bad += 1
	out("FAIL " .. fmt, ...)
end

for _, id in ipairs({ "SahurSprings", "TralalaTown", "BombardiroBay", "RotRidge", "PatapimPlains" }) do
	for _, seed in ipairs(SEEDS) do
		math.randomseed(seed)
		local ok, info = pcall(MapGenerator.Build, id)
		if not ok then
			fail("%s/%d BUILD FAILED %s", id, seed, tostring(info))
		else
			maps += 1
			local mode = GameModes.Get("TeamDeathmatch") or { id = "TeamDeathmatch", teams = true }
			local setupOk, err = pcall(ModeTeams.Setup, mode, info)
			if not setupOk then
				fail("%s/%d SETUP FAILED %s", id, seed, tostring(err))
			end
			local roads = info.roads
			local centre = select(1, ModeTeams.Arena())
			local apron = TB.RoadEnd
			local gateways = ModeTeams.ArenaGateways and ModeTeams.ArenaGateways() or {}
			local totals = {}
			for team = 1, 2 do
				local ruin = ModeTeams.BaseRuin(team)
				local plan = ruin and ruin.accessPlan
				if not ruin then
					fail("%s/%d team %d: no compound", id, seed, team)
				elseif not plan then
					fail("%s/%d team %d: no access road (%s)", id, seed, team, tostring(ruin.accessWhy))
				else
					totals[team] = plan.total or plan.length
					-- Connected: BFS over roads.edges from the gate's node to an edge carrying a gateway.
					local adjacency = {}
					for _, e in ipairs(roads.edges) do
						if not e.blocked then
							adjacency[e.a] = adjacency[e.a] or {}
							adjacency[e.b] = adjacency[e.b] or {}
							table.insert(adjacency[e.a], e)
							table.insert(adjacency[e.b], e)
						end
					end
					local seen, queue, reached = { [ruin.accessGateNode] = true }, { ruin.accessGateNode }, false
					while #queue > 0 and not reached do
						local n = table.remove(queue)
						for _, e in ipairs(adjacency[n] or {}) do
							for _, g in ipairs(gateways) do
								if segDist(g, flat(e.a.position), flat(e.b.position)) < 12 then
									reached = true
								end
							end
							local m = e.a == n and e.b or e.a
							if not seen[m] then
								seen[m] = true
								table.insert(queue, m)
							end
						end
					end
					if #gateways > 0 and not reached then
						fail("%s/%d team %d: the gate does not reach an arena gateway through the road data", id, seed, team)
					end
					-- The biggest vehicle swept along the road.
					local params = OverlapParams.new()
					params.FilterType = Enum.RaycastFilterType.Exclude
					params.FilterDescendantsInstances = { ruin.accessRoad, workspace.Terrain }
					params.RespectCanCollide = true
					local hits = {}
					local heights = plan.heights
					for i = 2, #plan.points do
						local a, b = plan.points[i - 1], plan.points[i]
						local top = math.max(heights[i - 1], heights[i]) + TeamBaseRoads.Lift
						local mid = (a + b) / 2
						local frame = CFrame.lookAt(Vector3.new(mid.X, top + 0.3 + VEHICLE_HEIGHT / 2, mid.Z), Vector3.new(b.X, top + 0.3 + VEHICLE_HEIGHT / 2, b.Z))
						for _, part in ipairs(workspace:GetPartBoundsInBox(frame, Vector3.new(VEHICLE_HALF_WIDTH * 2, VEHICLE_HEIGHT, (b - a).Magnitude), params)) do
							if part.CanCollide and not part:IsDescendantOf(ModeTeams.BaseVehicleFolder() or workspace.Terrain) then
								hits[part:GetFullName()] = true
							end
						end
					end
					for name in pairs(hits) do
						fail("%s/%d team %d: the biggest vehicle hits %s on the access road", id, seed, team, name)
					end
					-- Bots: from each bay's lane end (+ the way round to the road) to the gateway and the middle.
					local worst = 1
					for _, bay in ipairs(ruin.vehicleBays or {}) do
						local look = flat(bay.LookVector).Unit
						local lane = flat(bay.Position) + look * 40
						local via = ModeTeams.BaseDriveVia(bay.Position, look) or {}
						local from = via[#via] or lane
						local gateway = ruin.accessGateway or gateways[1]
						if gateway then
							local pts, flags = BotNav.DriveRoute(roads, from, gateway, nil, true)
							local total, onRoad = 0, 0
							local last = from
							for _, p in ipairs(pts) do
								local steps = math.max(1, math.floor((p - last).Magnitude / 3))
								for k = 1, steps do
									local q = last + (p - last) * ((k - 0.5) / steps)
									local length = (p - last).Magnitude / steps
									total += length
									for _, e in ipairs(roads.edges) do
										if not e.blocked and segDist(q, flat(e.a.position), flat(e.b.position)) < 12 then
											onRoad += length
											break
										end
									end
								end
								last = p
							end
							local share = onRoad / math.max(total, 1)
							worst = math.min(worst, share)
							if share < FOLLOW then
								fail("%s/%d team %d: a bot from a bay follows the roads for %.0f%% of its way to the gateway", id, seed, team, share * 100)
							end
							-- Into the apron only from a gateway, going for the middle.
							local mids = BotNav.DriveRoute(roads, from, centre, nil, true)
							local prev = from
							for _, p in ipairs(mids) do
								local steps = math.max(1, math.floor((p - prev).Magnitude / 3))
								for k = 1, steps do
									local q = prev + (p - prev) * (k / steps)
									if (q - flat(centre)).Magnitude < apron - 2 then
										local near = false
										for _, g in ipairs(gateways) do
											if (prev - g).Magnitude < 40 then
												near = true
											end
										end
										if not near then
											fail("%s/%d team %d: a bot going for the middle enters the apron away from a gateway at (%.0f, %.0f)", id, seed, team, q.X, q.Z)
										end
										break
									end
								end
								prev = p
							end
						end
					end
					out("%s/%d team %d: road %.0f (to the arena %.0f), gateway %s, gate %d, least share on roads %.0f%%", id, seed, team,
						plan.length, totals[team], tostring(plan.gateway), plan.gate or 0, worst * 100)
				end
			end
			if totals[1] and totals[2] then
				local gap = math.abs(totals[1] - totals[2]) / math.max(totals[1], totals[2])
				out("%s/%d fairness: %.0f vs %.0f, %.1f%%", id, seed, totals[1], totals[2], gap * 100)
				if gap > FAIR + 1e-6 then
					fail("%s/%d the teams' ways to the arena differ by %.0f%%", id, seed, gap * 100)
				end
			end
			pcall(ModeTeams.Teardown)
			-- A battle royale on the same map data: nothing of the team match's roads left.
			local left = 0
			for _, d in ipairs(info.map:GetDescendants()) do
				if d.Name == "AccessRoad" then
					left += 1
				end
			end
			for _, e in ipairs(roads.edges) do
				if e.access or e.arena then
					left += 1
				end
			end
			if left > 0 then
				fail("%s/%d after the team match: %d access-road pieces or arena cuts left for a battle royale", id, seed, left)
			end
		end
		task.wait(0.5)
	end
end
out("DONE %s (%d maps built)", bad == 0 and "PASS" or ("FAIL x" .. bad), maps)
