-- Foundation probe: the fixes tools/foundation_check.py proves on a modelled terrain, re-measured on
-- Studio's real one (Oliver, 2026-09-24: "look for floating building foundations and poor placement").
--   powershell -ExecutionPolicy Bypass -File tools/runtest.ps1 -Probe tools/foundation_probe.lua -WaitSeconds 400
-- One map per run (edit MAP_ID and SEED below).
--
-- Lines start "[FOUNDATION]"; "[FOUNDATION] PROBLEM" lines are the ones to look at. Each count says how
-- many it examined, so a filter that matched nothing reads as nothing examined, not as a clean sweep.
--
--   underpin   every monument, easter egg and MapWilds shelter, dry-run through MapTerrain.Underpin
--              AFTER the build: pieces still hanging over the ground by more than its tolerance (0.3).
--              Monuments and eggs are underpinned in the build, so they should read 0; the shelters
--              are not (MapWilds sinks its own pieces by the ground's fall), and their count is the
--              real terrain's answer to whether that is enough.
--   rim posts  each plateau zipline's rim post: its foot against the ground under it.
--   openings   each MapWilds shelter: the ground in front of its opening (1 to 5 studs out, three
--              lanes) against its floor. Climbing more than 1.5 is a door into a bank.
--   doors      each town building: anything solid standing on its path from the door to the pavement.
--   entrances  each town set piece: the same, from its front to the kerb.

local MAP_ID, SEED = "RotRidge", 101

local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
local MapGenerator = require(modules:WaitForChild("MapGenerator"))
local MapTerrain = require(modules:WaitForChild("MapTerrain"))

local function out(fmt, ...)
	print("[FOUNDATION] " .. string.format(fmt, ...))
end

math.randomseed(SEED)
local started = DateTime.now().UnixTimestampMillis
local ok, info = pcall(MapGenerator.Build, MAP_ID)
if not ok then
	out("PROBLEM build failed: %s", tostring(info))
	return
end
task.wait(1)
local map = workspace.Map
out("%s seed %d built in %.1fs (wall clock)", MAP_ID, SEED, (DateTime.now().UnixTimestampMillis - started) / 1000)

local terrainOnly = RaycastParams.new()
terrainOnly.FilterType = Enum.RaycastFilterType.Include
terrainOnly.FilterDescendantsInstances = { workspace.Terrain }
terrainOnly.IgnoreWater = true
local function ground(x, z)
	local hit = workspace:Raycast(Vector3.new(x, 2000, z), Vector3.new(0, -4000, 0), terrainOnly)
	return hit and hit.Position.Y or nil
end

-- Underpinning, dry run.
local structures = {}
for _, folderName in ipairs({ "Landmarks", "EasterEggs", "Wilds" }) do
	local folder = map:FindFirstChild(folderName)
	for _, child in ipairs(folder and folder:GetChildren() or {}) do
		if child:IsA("Model") and not child:GetAttribute("FootingSkip") then
			if child:GetAttribute("FootingGroup") then
				for _, foot in ipairs(child:GetChildren()) do
					if foot:IsA("Model") and type(foot:GetAttribute("FootingBase")) == "number" then
						table.insert(structures, { model = foot, owner = folderName })
					end
				end
			elseif type(child:GetAttribute("FootingBase")) == "number" then
				table.insert(structures, { model = child, owner = folderName })
			end
		end
	end
end
local hanging = { Landmarks = 0, EasterEggs = 0, Wilds = 0 }
local examined = { Landmarks = 0, EasterEggs = 0, Wilds = 0 }
for _, entry in ipairs(structures) do
	examined[entry.owner] += 1
	local count, found = MapTerrain.Underpin(entry.model, entry.model:GetAttribute("FootingBase"), { dryRun = true })
	if count > 0 then
		hanging[entry.owner] += 1
		local worst = found[1]
		for _, piece in ipairs(found) do
			if piece.drop > worst.drop then
				worst = piece
			end
		end
		out("%s %s: %d pieces hang, worst %s %.2f over the ground at %s", entry.owner == "Wilds" and "NOTE" or "PROBLEM",
			entry.model:GetFullName(), count, worst.part.Name, worst.drop, tostring(worst.part.Position))
	end
end
for _, owner in ipairs({ "Landmarks", "EasterEggs", "Wilds" }) do
	out("underpin %s: %d examined, %d with a hanging piece", owner, examined[owner], hanging[owner])
end

-- Rim posts.
local ziplines = map:FindFirstChild("Ziplines")
local posts, badPosts = 0, 0
for _, part in ipairs(ziplines and ziplines:GetChildren() or {}) do
	if part:IsA("BasePart") then
		posts += 1
		local bottom = part.Position.Y - part.Size.Y / 2
		local y = ground(part.Position.X, part.Position.Z)
		if not y or bottom - y > 0.5 then
			badPosts += 1
			out("PROBLEM rim post at %s: foot %.2f, ground %s", tostring(part.Position), bottom, tostring(y))
		end
	end
end
out("rim posts: %d examined, %d floating", posts, badPosts)

-- Shelter openings.
local wilds = map:FindFirstChild("Wilds")
local openings, blocked = 0, 0
for _, child in ipairs(wilds and wilds:GetChildren() or {}) do
	local base, size = child:GetAttribute("FootingBase"), child:GetAttribute("FootingSize")
	if child:IsA("Model") and type(base) == "number" and typeof(size) == "Vector3" then
		openings += 1
		local pivot = child:GetPivot()
		local worst = -math.huge
		for _, across in ipairs({ -0.4, 0, 0.4 }) do
			for step = 1, 5 do
				local at = pivot * CFrame.new(across * size.X / 2, 0, -size.Z / 2 - step)
				local y = ground(at.X, at.Z)
				if y then
					worst = math.max(worst, y - base)
				end
			end
		end
		if worst > 1.5 then
			blocked += 1
			out("PROBLEM %s: the ground in front of its opening climbs %.2f over its floor", child:GetFullName(), worst)
		end
	end
end
out("shelter openings: %d examined, %d into a bank", openings, blocked)

-- Town doors and set-piece entrances: anything solid in the way out, over the same ground the check
-- measures (from the front of the footprint, the step included, four studs out, three studs either side
-- of the middle of the door).
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.FilterDescendantsInstances = { map }
local function inTheWay(model, front)
	local box = front * CFrame.new(0, 3, -2)
	for _, part in ipairs(workspace:GetPartBoundsInBox(box, Vector3.new(6, 4, 4), overlap)) do
		if part.CanCollide and part.Size.Y > 1.5 and not part:IsDescendantOf(model) then
			return part
		end
	end
	return nil
end
local function frontOf(model, depth)
	local pivot = model:GetPivot()
	return pivot * CFrame.new(0, 0, -depth / 2)
end
local doors, doorsBlocked, entrances, entrancesBlocked = 0, 0, 0, 0
for _, town in ipairs(map:GetChildren()) do
	if town.Name == "Town" then
		for _, child in ipairs(town:GetChildren()) do
			local size = child:GetAttribute("FootingSize")
			if child:IsA("Model") and (child.Name == "house" or child.Name == "tower" or child.Name == "warehouse") and size then
				doors += 1
				local part = inTheWay(child, frontOf(child, size.Z))
				if part then
					doorsBlocked += 1
					out("PROBLEM a %s's door at %s: %s stands in its path", child.Name, tostring(child:GetPivot().Position), part:GetFullName())
				end
			end
		end
		local theme = town:FindFirstChild("Theme")
		for _, piece in ipairs(theme and theme:GetChildren() or {}) do
			local size = piece:GetAttribute("FootingSize")
			if piece:IsA("Model") and piece:GetAttribute("SetPiece") and size then
				entrances += 1
				local part = inTheWay(piece, frontOf(piece, size.Z))
				if part then
					entrancesBlocked += 1
					out("PROBLEM set piece %s: %s stands in front of its entrance", piece.Name, part:GetFullName())
				end
			end
		end
	end
end
out("town doors: %d examined, %d blocked; set-piece entrances: %d examined, %d blocked", doors, doorsBlocked, entrances, entrancesBlocked)
out("done")
