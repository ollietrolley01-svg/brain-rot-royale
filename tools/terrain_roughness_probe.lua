-- Real-map ground survey, to calibrate tools/vehicle_rough_terrain_probe.lua's course from numbers
-- rather than guesses. Builds real maps (MapGenerator.Build) and samples the ground a vehicle drives on
-- along straight lines, one stud apart, in three kinds of place:
--   offroad  random lines anywhere on the map that stay on open ground (terrain under every sample)
--   town     lines skirting each town just outside its TownRadius (the ground between streets and wilds)
--   base     lines through the two sites a team match puts its compounds (ModeTeams.PickBaseAxis)
-- Per kind: slope over 8 studs (a wheelbase-ish span), bump height (a sample's rise above the straight
-- line between the samples 6 studs either side of it), single-stud steps, and the share of rock.
-- And one real blast crater (DestructibleService.DamageInRadius, three hits on open ground): its depth,
-- rim radius and steepest wall -- reported only; crater walls are the destruction code's business.
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/terrain_roughness_probe.lua -WaitSeconds 900 -PlaceFile <build>
-- Lines: "[SURVEY] <map> <kind> lines=N slope p50/p90/p99/max=... bump p50/p90/p99/max=... step p99/max=... rock=%"
-- and "[SURVEY] <map> crater depth=... rim=... wall=...deg".

local ServerScriptService = game:GetService("ServerScriptService")
local modules = ServerScriptService:WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local ModeTeams = require(modules:WaitForChild("ModeTeams"))
local DestructibleService = require(modules:WaitForChild("DestructibleService"))

local function out(format, ...)
	print("[SURVEY] " .. string.format(format, ...))
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { workspace.Terrain }
local anyParams = RaycastParams.new()

-- The ground at (x, z): terrain height, material, and whether anything else (a road, a building, a
-- tree) stands over it there, which disqualifies the sample for off-road driving.
local function ground(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), params)
	if not hit then
		return nil
	end
	local top = workspace:Raycast(Vector3.new(x, 400, z), Vector3.new(0, -800, 0), anyParams)
	local clear = top and top.Instance == workspace.Terrain
	return hit.Position.Y, hit.Material, clear
end

local function pct(list, p)
	if #list == 0 then
		return 0
	end
	table.sort(list)
	return list[math.clamp(math.ceil(#list * p), 1, #list)]
end

local function survey(mapId, kind, lines)
	local slopes, bumps, steps, rock, total, used = {}, {}, {}, 0, 0, 0
	for _, line in ipairs(lines) do
		local from, dir, length = line[1], line[2], line[3]
		local h, ok = {}, true
		for i = 0, length do
			local p = from + dir * i
			local y, material, clear = ground(p.X, p.Z)
			if not y or not clear or material == Enum.Material.Water or material == Enum.Material.Asphalt then
				ok = false
				break
			end
			h[i] = y
			total += 1
			if material == Enum.Material.Rock or material == Enum.Material.Slate or material == Enum.Material.Basalt then
				rock += 1
			end
		end
		if ok then
			used += 1
			for i = 0, length - 8 do
				table.insert(slopes, math.deg(math.atan(math.abs(h[i + 8] - h[i]) / 8)))
			end
			for i = 6, length - 6 do
				table.insert(bumps, math.abs(h[i] - (h[i - 6] + h[i + 6]) / 2))
			end
			for i = 0, length - 1 do
				table.insert(steps, math.abs(h[i + 1] - h[i]))
			end
		end
	end
	out("%s %s lines=%d/%d slope p50/p90/p99/max=%.1f/%.1f/%.1f/%.1f bump p50/p90/p99/max=%.2f/%.2f/%.2f/%.2f step p99/max=%.2f/%.2f rock=%.0f%%",
		mapId, kind, used, #lines, pct(slopes, 0.5), pct(slopes, 0.9), pct(slopes, 0.99), pct(slopes, 1),
		pct(bumps, 0.5), pct(bumps, 0.9), pct(bumps, 0.99), pct(bumps, 1), pct(steps, 0.99), pct(steps, 1),
		100 * rock / math.max(total, 1))
end

for _, mapId in ipairs({ "SahurSprings", "RotRidge" }) do
	local okBuild, info = pcall(MapGenerator.Build, mapId)
	if not okBuild or type(info) ~= "table" then
		out("%s PROBLEM build failed: %s", mapId, tostring(info))
	else
		local rng = Random.new(11)
		local radius = info.radius or 800
		local offroad = {}
		for _ = 1, 160 do
			local a, d = rng:NextNumber(0, math.pi * 2), math.sqrt(rng:NextNumber()) * radius * 0.85
			local b = rng:NextNumber(0, math.pi * 2)
			table.insert(offroad, { Vector3.new(math.cos(a) * d, 0, math.sin(a) * d), Vector3.new(math.cos(b), 0, math.sin(b)), 80 })
		end
		survey(mapId, "offroad", offroad)

		local town = {}
		for _, t in ipairs(info.map:GetDescendants()) do
			if t:IsA("Model") and t.Name == "Town" and t:GetAttribute("TownCenter") then
				local c, r = t:GetAttribute("TownCenter"), (t:GetAttribute("TownRadius") or 80) + 15
				for k = 0, 11 do
					local a = k / 12 * math.pi * 2
					local at = c + Vector3.new(math.cos(a), 0, math.sin(a)) * r
					table.insert(town, { at, Vector3.new(-math.sin(a), 0, math.cos(a)), 40 })
				end
			end
		end
		survey(mapId, "town", town)

		local base = {}
		local okAxis, axis, fraction = pcall(ModeTeams.PickBaseAxis, rng:NextNumber(0, math.pi * 2), info)
		if okAxis and axis then
			for _, sign in ipairs({ 1, -1 }) do
				local centre = Vector3.new(math.cos(axis), 0, math.sin(axis)) * radius * (fraction or 0.72) * sign
				for k = 0, 15 do
					local b = k / 16 * math.pi * 2
					local dir = Vector3.new(math.cos(b), 0, math.sin(b))
					table.insert(base, { centre + dir * 20, dir, 60 })
				end
			end
		end
		survey(mapId, "base", base)

		-- One real crater, on the flattest open spot of a few tried.
		local spot
		for _ = 1, 60 do
			local a, d = rng:NextNumber(0, math.pi * 2), rng:NextNumber(0.3, 0.8) * radius
			local x, z = math.cos(a) * d, math.sin(a) * d
			local y, _, clear = ground(x, z)
			local y2, _, clear2 = ground(x + 10, z)
			if y and clear and clear2 and y2 and math.abs(y2 - y) < 0.5 then
				spot = Vector3.new(x, y, z)
				break
			end
		end
		if spot then
			for _ = 1, 3 do
				pcall(DestructibleService.DamageInRadius, spot + Vector3.new(0, 1, 0), 14, 120, nil)
				task.wait(0.3)
			end
			local floor, rim, wall = math.huge, 0, 0
			local last
			for i = 0, 30 do
				local y = ground(spot.X + i, spot.Z)
				if y then
					floor = math.min(floor, y)
					if last then
						local deg = math.deg(math.atan(math.abs(y - last)))
						wall = math.max(wall, deg)
						if y >= spot.Y - 0.2 and rim == 0 and i > 1 then
							rim = i
						end
					end
					last = y
				end
			end
			out("%s crater depth=%.1f rim=%d wall=%.0fdeg (steepest single stud, reported only)", mapId, spot.Y - floor, rim, wall)
		else
			out("%s crater: no open spot found", mapId)
		end
	end
end
out("done")
