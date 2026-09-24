# Runtime smoke test for Brain Rot Royale.
#
# Installs a TEMPORARY local Studio plugin that switches the place into Run mode, builds a map,
# populates loot, and captures everything the Output window shows (via LogService.MessageOut)
# into the plugin's settings file. Then reads that back and deletes the plugin.
# Usage: powershell -ExecutionPolicy Bypass -File runtest.ps1 [MapId]
# -Probe <file.lua>: instead of the full run, execute that Lua file in the plugin (edit mode, no
# Run mode, ~70s) with the same Output capture — for quick checks of a builder or module.
#
# Safe alongside other sessions and Oliver's own Studio: it waits for the machine-wide Studio lock
# (tools/studio_lock.ps1), opens a private snapshot BRR_RunTest.rbxlx instead of the real place,
# the plugin does nothing in any other Studio window, and it closes only its own window.
# -PlaceFile <file.rbxlx>: test a place built somewhere else (e.g. a scratch copy of the source
# tree) instead of the project's own BrainRotRoyale.rbxlx.
# CmdletBinding so a mistyped argument is an ERROR, not silence: `-TimeoutSeconds 1500` (gallery.ps1's
# name) used to land in $args, leaving the wait at its default and cutting a long probe off mid-run.
[CmdletBinding()]
param([string]$MapId = "SahurSprings", [int]$WaitSeconds = 200, [string]$Probe = "", [string]$PlaceFile = "")

. "$PSScriptRoot\studio_lock.ps1"

# Resolve and CHECK -Probe BEFORE queueing. A bad path used to be discovered only after the run had
# sat through the whole queue, which cost a tab ~20 minutes for a typo. Rule 5 says to run the
# harness from the project's tools/, so `-Probe tools/x.lua` resolves to tools/tools/x.lua and dies:
# accept it relative to the caller, to tools/, or to the project root, and say what was tried.
if ($Probe -ne "") {
	$probeTried = @()
	$probeFound = ""
	foreach ($candidate in @($Probe, (Join-Path $PSScriptRoot $Probe), (Join-Path (Split-Path -Parent $PSScriptRoot) $Probe))) {
		$probeTried += $candidate
		if (Test-Path -LiteralPath $candidate -PathType Leaf) { $probeFound = (Resolve-Path -LiteralPath $candidate).Path; break }
	}
	if (-not $probeFound) {
		throw "probe file not found: $Probe -- tried:`n  " + ($probeTried -join "`n  ") + "`nPass an absolute path, or one relative to the project root or tools/."
	}
	if ((Get-Item -LiteralPath $probeFound).Length -eq 0) { throw "probe file is empty: $probeFound" }
	$Probe = $probeFound
}

$what = if ($Probe -ne "") { "runtest.ps1 -Probe $Probe" } else { "runtest.ps1 -MapId $MapId" }
if ($PlaceFile -ne "") { $what += " -PlaceFile $PlaceFile" }
Enter-StudioLock $what
Assert-StudioLock

$source = if ($PlaceFile -ne "") { $PlaceFile } else { "C:\Users\oliver\Downloads\claude\brain-rot-royale\BrainRotRoyale.rbxlx" }
$runToken = [guid]::NewGuid().ToString("N")
# Set aside as the wait loop runs, so a log overwritten after Studio exits is not lost with it.
$liveMarker = "BRR_LOG_BEGIN $runToken"
$captured = ""
$capturedLen = 0
# runtest SNAPSHOTS the place and never builds it, so a probe run after an edit measures the LAST
# build -- and a stale pass is indistinguishable from a real one. Two tabs have lost runs to this and
# it is recorded twice in COORDINATION.md, which is not where anyone reads it at the moment it bites.
# So the harness says it here, where the cost lands.
$newestSource = Get-ChildItem "C:\Users\oliver\Downloads\claude\brain-rot-royale" -Recurse -Include *.lua -ErrorAction SilentlyContinue |
	Where-Object { $_.FullName -notmatch '\\(tools|\.git)\\' } |
	Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($newestSource -and (Test-Path $source) -and $newestSource.LastWriteTime -gt (Get-Item $source).LastWriteTime) {
	"WARNING: $(Split-Path $source -Leaf) was built BEFORE $($newestSource.Name) changed -- this run will measure the OLD code."
	"         Run 'python build_place.py .' first, or pass -PlaceFile to snapshot a pinned build on purpose."
}
$place = Join-Path $env:TEMP "BRR_RunTest\BRR_RunTest.rbxlx"
$lock = "$place.lock"
$pluginDir = "$env:LOCALAPPDATA\Roblox\Plugins"
New-Item -ItemType Directory -Force $pluginDir | Out-Null
$plugin = Join-Path $pluginDir "BRR_AutoRun_TEMP.rbxmx"

$lua = @'
-- TEMPORARY test plugin (written by runtest.ps1, deleted by it too).
-- Local plugins load in EVERY open Studio: act only inside the harness's own snapshot.
if not string.find(game.Name, "BRR_RunTest", 1, true) then
	return
end
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")
local NL = string.char(10)
local lines = {}
LogService.MessageOut:Connect(function(message, messageType)
	table.insert(lines, messageType.Name .. " | " .. message)
	if #lines > 5000 then
		table.remove(lines, 1)
	end
end)
-- Every run shares one plugin settings file. The run token marks this run's log, and the flush
-- straight away overwrites an earlier run's, so a Studio that dies early can never have someone
-- else's output read back as its own.
local function flush()
	plugin:SetSetting("BRR_LOG", "BRR_LOG_BEGIN RUN_TOKEN" .. NL .. table.concat(lines, NL) .. NL .. "BRR_LOG_END")
end
flush()
task.delay(6, function()
	if not RunService:IsRunning() then
		print("[BRR_AutoRun] starting run mode")
		RunService:Run()
	end
end)
-- Client scripts never run in Run mode, so at least compile them: loadstring reports syntax
-- errors without executing anything.
task.delay(20, function()
	local checked, failed = 0, 0
	local function check(container)
		for _, item in ipairs(container:GetDescendants()) do
			if item:IsA("LuaSourceContainer") then
				local ok, source = pcall(function()
					return item.Source
				end)
				if ok and type(source) == "string" then
					checked += 1
					local fn, err = loadstring(source, item.Name)
					if not fn then
						failed += 1
						warn("[BRR_AutoRun] SYNTAX " .. item:GetFullName() .. ": " .. tostring(err))
					end
				end
			end
		end
	end
	local ok, err = pcall(function()
		check(game:GetService("StarterPlayer"))
		check(game:GetService("ReplicatedStorage"))
		check(game:GetService("ServerScriptService"))
	end)
	if not ok then
		warn("[BRR_AutoRun] syntax pass unavailable: " .. tostring(err))
	end
	print(string.format("[BRR_AutoRun] syntax pass: %d scripts compiled, %d failed", checked, failed))
end)

task.delay(30, function()
	print("[BRR_AutoRun] building map MAP_ID")
	local ok, err = pcall(function()
		local modules = game:GetService("ServerScriptService"):WaitForChild("Modules")
		local MapGenerator = require(modules:WaitForChild("MapGenerator"))
		local LootService = require(modules:WaitForChild("LootService"))
		local info = MapGenerator.Build("MAP_ID")
		local names = {}
		for _, entry in ipairs(info.landmarks or {}) do
			table.insert(names, entry.name)
		end
		print(string.format("[BRR_AutoRun] map built: %d chests, %d weapon, %d heal, %d item spots; landmarks: %s",
			#info.chestSpots, #info.lootSpots.weapon, #info.lootSpots.heal, #info.lootSpots.item, table.concat(names, ", ")))
		local riverParts = workspace.Map:FindFirstChild("River") and #workspace.Map.River:GetDescendants() or 0
		local ziplines = 0
		for _, d in ipairs(workspace.Map:GetDescendants()) do
			if d.Name == "ZiplineHandle" then ziplines += 1 end
		end
		print("[BRR_AutoRun] ziplines: " .. ziplines)

		-- Map clipping check: solid parts of one thing (a building, a landmark, the river's
		-- bridges, a prop) inside solid parts of another. Things are the Models directly under
		-- Map, or the building Models inside a town. Terrain is checked separately: a solid part
		-- whose centre is under the ground.
		local function thingOf(part)
			local node = part
			while node and node.Parent ~= workspace.Map do
				if node.Parent and node.Parent.Parent == workspace.Map and node:IsA("Model") then
					return node
				end
				node = node.Parent
			end
			return node
		end
		-- Exact geometry, not bounding boxes: a probe the shape of the part, shrunk a little so
		-- two things that merely touch or sit on each other don't count, asked what it's inside.
		local function overlapping(d, params)
			local class = d.ClassName
			local probe = Instance.new((class == "WedgePart" or class == "CornerWedgePart") and class or "Part")
			if d:IsA("Part") and probe:IsA("Part") then
				probe.Shape = d.Shape
			end
			probe.Size = Vector3.new(math.max(0.05, d.Size.X - 0.7), math.max(0.05, d.Size.Y - 0.7), math.max(0.05, d.Size.Z - 0.7))
			probe.CFrame = d.CFrame
			probe.Transparency = 1
			probe.Anchored = true
			probe.CanCollide = false
			probe.CanTouch = false
			probe.Parent = workspace
			local hits = workspace:GetPartsInPart(probe, params)
			probe:Destroy()
			return hits
		end
		local pairs_, examples, checked, buried = {}, {}, 0, 0
		local buriedBy, buriedExamples = {}, {}
		local overlapParams = OverlapParams.new()
		overlapParams.FilterType = Enum.RaycastFilterType.Include
		overlapParams.FilterDescendantsInstances = { workspace.Map }
		local terrainParams = RaycastParams.new()
		terrainParams.FilterType = Enum.RaycastFilterType.Include
		terrainParams.FilterDescendantsInstances = { workspace.Terrain }
		terrainParams.IgnoreWater = true
		for _, d in ipairs(workspace.Map:GetDescendants()) do
			if d:IsA("BasePart") and d.CanCollide and d.Size.Magnitude > 2 then
				checked += 1
				local mine = thingOf(d)
				if mine then
					for _, other in ipairs(overlapping(d, overlapParams)) do
						local theirs = thingOf(other)
						if other.CanCollide and theirs and theirs ~= mine and mine.Name < theirs.Name then
							local key = mine.Name .. "/" .. theirs.Name
							pairs_[key] = (pairs_[key] or 0) + 1
							examples[key] = examples[key] or (d.Name .. " vs " .. other.Name .. " near " .. tostring(d.Position))
						end
					end
				end
				-- Under the ground: a downward ray from well above lands above the part's top.
				local hit = workspace:Raycast(d.Position + Vector3.new(0, 300, 0), Vector3.new(0, -600, 0), terrainParams)
				if hit and hit.Position.Y > d.Position.Y + d.Size.Y / 2 + 1.5 and d.Name ~= "Core" then
					buried += 1
					local owner = mine and mine.Name or "?"
					buriedBy[owner] = (buriedBy[owner] or 0) + 1
					buriedExamples[owner] = buriedExamples[owner] or string.format("%s top %.1f under ground %.1f at %s (parent %s)",
						d.Name, d.Position.Y + d.Size.Y / 2, hit.Position.Y, tostring(d.Position), d.Parent and d.Parent.Name or "?")
				end
				if checked % 200 == 0 then task.wait() end
			end
		end
		local report = {}
		for key, n in pairs(pairs_) do
			table.insert(report, string.format("%s x%d (%s)", key, n, examples[key]))
		end
		table.sort(report)
		local buriedList = {}
		for owner, n in pairs(buriedBy) do
			table.insert(buriedList, owner .. " " .. n .. ": " .. buriedExamples[owner])
		end
		table.sort(buriedList)
		print(string.format("[BRR_AutoRun] map clipping: %d solid parts checked; cross-thing overlaps: %s; buried under terrain: %d",
			checked, #report > 0 and table.concat(report, " | ") or "none", buried))
		for _, line in ipairs(buriedList) do
			print("[BRR_AutoRun] map buried: " .. line)
		end

		-- Z-fighting: what the build's own pass had to nudge (patterns worth fixing at source),
		-- and whether anything is still flush after it (must be nothing).
		local ZFight = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("ZFight"))
		local function zreport(label, roots, groupOf)
			local touched, lines, patterns = ZFight.Report(roots, groupOf, 40)
			local remaining = ZFight.Scan(roots)
			local remLines = ZFight.Describe(remaining, groupOf, 25)
			print(string.format("[BRR_AutoRun] zfight %s: nudged at build %d parts in %d patterns; still flush %d%s", label, touched, patterns,
				#remaining, #remaining > 0 and (" [" .. table.concat(remLines, " | ") .. "]") or ""))
			if #lines > 0 then
				print("[BRR_AutoRun] zfight " .. label .. " patterns: " .. table.concat(lines, " | "))
			end
			return touched, #remaining
		end
		local function mapGroup(part)
			local thing = thingOf(part)
			return thing and thing.Name or "?"
		end
		print(string.format("[BRR_AutoRun] zfight map pass: %d visible parts, moved %d (lifted off ground %d, resized %d) in %d passes, remaining %d, %.1fs",
			info.zfight and info.zfight.parts or -1, info.zfight and info.zfight.moved or -1, info.zfight and info.zfight.lifted or -1,
			info.zfight and info.zfight.resized or -1, info.zfight and info.zfight.passes or -1, info.zfight and #info.zfight.remaining or -1,
			info.zfight and info.zfight.seconds or -1))
		zreport("map", { workspace.Map }, mapGroup)

		-- Every landmark and every easter egg in one go, off the map's edge, through the same pass.
		local samples = Instance.new("Folder")
		samples.Name = "ZFightSamples"
		samples.Parent = workspace
		local Landmarks = require(modules:WaitForChild("Landmarks"))
		local EasterEggs = require(modules:WaitForChild("EasterEggs"))
		local edge = info.radius * 1.15 + 400
		local okL, errL = pcall(Landmarks.BuildAll, samples, Vector3.new(-1200, 0, edge), 280, function() return 0 end)
		local okE, errE = pcall(EasterEggs.BuildAll, samples, Vector3.new(-1200, 0, edge + 300), 90)
		task.wait()
		local sampleFix = ZFight.Fix({ samples }, { yield = true })
		print(string.format("[BRR_AutoRun] zfight samples: %d landmark/egg models built (landmarks %s, eggs %s); pass moved %d, remaining %d; geyser vent %s",
			#samples:GetChildren(), okL and "ok" or tostring(errL), okE and "ok" or tostring(errE), sampleFix.moved, #sampleFix.remaining,
			tostring(samples:FindFirstChild("GeyserVent", true) ~= nil)))
		zreport("samples", { samples }, function(part)
			local node = part
			while node and node.Parent ~= samples do node = node.Parent end
			return node and node.Name or "?"
		end)
		-- How flat the map actually is. Every other terrain number here counts FEATURES, and a
		-- feature count reads exactly the same for real hills as for a two percent grade -- which
		-- is how a relief pass that was working, but far too gentle, shipped twice looking flat
		-- while every check stayed green. This samples the ground on a grid and reports the spread
		-- and the average step between neighbours, which is the thing you actually see.
		local lo, hi, total, samples = math.huge, -math.huge, 0, 0
		local reach = info.radius * 0.75
		local grid = {}
		for gx = -12, 12 do
			grid[gx] = {}
			for gz = -12, 12 do
				local y = MapGenerator.GroundHeightAt(gx / 12 * reach, gz / 12 * reach)
				grid[gx][gz] = y
				lo, hi = math.min(lo, y), math.max(hi, y)
				total += y
				samples += 1
			end
		end
		local steps, stepCount = 0, 0
		for gx = -12, 11 do
			for gz = -12, 12 do
				steps += math.abs(grid[gx + 1][gz] - grid[gx][gz])
				stepCount += 1
			end
		end
		print(string.format("[BRR_AutoRun] relief: ground %.1f to %.1f (spread %.1f), mean %.1f, average step %.2f studs over %.0f-stud samples",
			lo, hi, hi - lo, total / math.max(1, samples), steps / math.max(1, stepCount), reach / 12))

		-- Is the river still open to the sky? Its channel is carved to a FIXED height while the
		-- ground around it no longer is, so any hill that out-reaches the carve leaves a lid of
		-- land over the water instead of a gorge through it. Nothing else here would notice: the
		-- river reports its points, its crossings and its part count exactly the same either way.
		local buried, riverPoints = 0, (info.river and info.river.points) or {}
		for _, point in ipairs(riverPoints) do
			if MapGenerator.GroundHeightAt(point.X, point.Z) > 6 then
				buried += 1
			end
		end
		print(string.format("[BRR_AutoRun] river cover: %d of %d points roofed over (want 0)", buried, #riverPoints))

		-- The roads, measured by the network that built them (RoadNetwork:Audit): every town
		-- connected and no road ending in open ground; every road walked a stud at a time across both
		-- lanes for gaps and steps; the terrain under and beside it; grades, creases and any two road
		-- parts sharing volume. The road and piece counts matter as much as the zeroes: every other
		-- number reads perfectly clean on a map with barely any roads on it, so a count that
		-- collapses is the only symptom of a planner that started rejecting routes.
		if info.roads then
			local okRoads, audit = pcall(function()
				return info.roads:Audit(workspace.Map)
			end)
			print("[BRR_AutoRun] roads: " .. (okRoads and audit.summary or ("AUDIT FAILED " .. tostring(audit))))
		else
			print("[BRR_AutoRun] roads: MISSING -- MapGenerator.Build returned no road network")
		end

		-- Drop selection. This harness builds maps directly and never runs a match, so the
		-- fifteen-second window itself cannot be exercised here and the accept path is
		-- unreachable -- there are no players. The WIRING can be checked though, and a renamed
		-- function or a remote that was never created is exactly the silent break that would
		-- otherwise surface only when someone started a real match.
		-- Services looked up directly rather than through this script's own `modules` and
		-- `SharedFolder` locals: both are declared further down, so referencing them here threw and
		-- took every check after this point down with it -- the run stopped dead at `junctions:`.
		local modulesRef = game:GetService("ServerScriptService"):WaitForChild("Modules")
		local sharedRef = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
		local MatchServiceRef = require(modulesRef:WaitForChild("MatchService"))
		local RemotesRef = require(sharedRef:WaitForChild("Remotes"))
		local MatchConfigRef = require(sharedRef:WaitForChild("MatchConfig"))
		-- Called with no match running: it must refuse rather than throw. Reading a nil key is
		-- legal in Lua, so the participant guard is safe to hit with no player at all.
		local guarded, refused = pcall(function()
			return MatchServiceRef.ChooseDrop(nil, 0, 0)
		end)
		print(string.format("[BRR_AutoRun] drop select: function=%s, remote=%s, window=%ss, refuses with no match=%s (want true/true/15/true)",
			tostring(type(MatchServiceRef.ChooseDrop) == "function"),
			tostring(RemotesRef.Event("ChooseDrop") ~= nil),
			tostring(MatchConfigRef.DropSelectSeconds),
			tostring(guarded and refused == false)))

		local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds")
		print(string.format("[BRR_AutoRun] terrain: %d hills/ridges/craters, river %s (%d points, %d crossings, %d parts), %d plateaus, clouds cover %s, RiverPath attr %d chars",
			info.hills or 0, info.river and (info.river.pond and "yes, ends in a pond" or "yes, edge to edge") or "NO",
			info.river and #info.river.points or 0, info.river and #info.river.bridges or 0, riverParts,
			#(info.plateaus or {}), clouds and tostring(clouds.Cover) or "none", #(workspace.Map:GetAttribute("RiverPath") or "")))
		-- Vehicles. Unanchored is the thing worth asserting: every other part in a map is anchored
		-- at creation, so one stray sweep would freeze the lot and the only symptom in play would
		-- be a car that refuses to move.
		local vehicleFolder = workspace.Map:FindFirstChild("Vehicles")
		local vbuilt, vseats, vfree, vsunk = 0, 0, 0, 0
		for _, v in ipairs(vehicleFolder and vehicleFolder:GetChildren() or {}) do
			vbuilt += 1
			local chassis = v:FindFirstChild("Chassis")
			if v:FindFirstChildOfClass("VehicleSeat") then vseats += 1 end
			if chassis and not chassis.Anchored then vfree += 1 end
			if chassis and chassis.Position.Y < MapGenerator.GroundHeightAt(chassis.Position.X, chassis.Position.Z) - 3 then
				vsunk += 1
			end
		end
		print(string.format("[BRR_AutoRun] vehicles: %d built (want > 0), %d with a seat (want all), %d unanchored (want all), %d sunk (want 0)", vbuilt, vseats, vfree, vsunk))
		if vbuilt == 0 or vseats ~= vbuilt or vfree ~= vbuilt or vsunk > 0 then
			print("[BRR_AutoRun] VEHICLE PROBLEM: a map with no vehicles, or vehicles without a seat, anchored, or sunk")
		end
		-- Planted fault, so the unanchored count can be seen to count: anchor one chassis for a moment
		-- and the tally must drop by exactly one.
		local plantedTarget = vehicleFolder and vehicleFolder:GetChildren()[1]
		local plantedChassis = plantedTarget and plantedTarget:FindFirstChild("Chassis")
		if plantedChassis and not plantedChassis.Anchored then
			plantedChassis.Anchored = true
			local stillFree = 0
			for _, v in ipairs(vehicleFolder:GetChildren()) do
				local chassis = v:FindFirstChild("Chassis")
				if chassis and not chassis.Anchored then stillFree += 1 end
			end
			plantedChassis.Anchored = false
			print(string.format("[BRR_AutoRun] vehicles self-check: one chassis anchored on purpose -> %d unanchored (want %d)", stillFree, vfree - 1))
		end

		LootService.Populate(info)
		task.wait(6)
		local loot = workspace:FindFirstChild("Loot")
		print("[BRR_AutoRun] loot pickups: " .. tostring(loot and #loot:GetChildren() or 0))
		local lobby = workspace:FindFirstChild("Lobby")
		print("[BRR_AutoRun] lobby parts: " .. tostring(lobby and #lobby:GetDescendants() or 0))
		if lobby then
			local found = {}
			for _, name in ipairs({ "Pier", "AirshipDeck", "Gangway", "ReadyPad", "Statue", "SkyWalkSummit", "SkyWalkTrophy", "SapLantern", "ClimbSign", "GoalZone", "DailyWheel", "Mannequin", "LobbySpawn", "PlayBall", "TradeCounter" }) do
				table.insert(found, name .. "=" .. tostring(lobby:FindFirstChild(name, true) ~= nil))
			end
			-- The Cloud Climb's moving parts and checkpoints (tools/climb_gallery.lua checks the climb itself).
			local targets, rotors, springs, deadwood, saps, prompts, walls = 0, 0, 0, 0, 0, 0, 0
			for _, d in ipairs(lobby:GetDescendants()) do
				if d.Name == "PracticeTarget" then targets += 1 elseif d.Name == "ThornRotor" then rotors += 1
				elseif d.Name == "SpringHinge" then springs += 1 elseif d.Name == "Deadwood" then deadwood += 1
				elseif d.Name == "SapKnot" then saps += 1
				elseif d:IsA("ProximityPrompt") then prompts += 1 elseif d.Name == "BallWall" then walls += 1 end
			end
			local stage = workspace:FindFirstChild("StageDisplay")
			print(string.format("[BRR_AutoRun] lobby pieces: %s; targets %d, climb rotors %d springy limbs %d deadwood %d checkpoints %d, prompts %d, ball walls %d, stage displays %d",
				table.concat(found, " "), targets, rotors, springs, deadwood, saps, prompts, walls, stage and #stage:GetChildren() or 0))

			-- Clipping check: solid parts of one set piece (their Group attribute) overlapping solid
			-- parts of another. Overlaps inside a piece are how these things are built; across
			-- pieces they're mistakes. Exact geometry (a shrunk probe), not bounding boxes.
			local pairs_, examples = {}, {}
			local lobbyBase = game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("MatchConfig")
			lobbyBase = require(lobbyBase).LobbyPosition
			local overlapParams = OverlapParams.new()
			overlapParams.FilterType = Enum.RaycastFilterType.Include
			overlapParams.FilterDescendantsInstances = { lobby }
			local lobbyChecked = 0
			for _, d in ipairs(lobby:GetDescendants()) do
				if d:IsA("BasePart") and d.CanCollide and d:GetAttribute("Group") and d.Name ~= "BallWall" then
					lobbyChecked += 1
					for _, other in ipairs(overlapping(d, overlapParams)) do
						local mine, theirs = d:GetAttribute("Group"), other:GetAttribute("Group")
						if other.CanCollide and theirs and theirs ~= mine and mine < theirs then
							local key = mine .. "/" .. theirs
							pairs_[key] = (pairs_[key] or 0) + 1
							if not examples[key] then
								examples[key] = d.Name .. "@" .. tostring(d.Position - lobbyBase) .. " vs " .. other.Name
							end
						end
					end
					if lobbyChecked % 200 == 0 then task.wait() end
				end
			end
			local report = {}
			for key, n in pairs(pairs_) do
				table.insert(report, string.format("%s x%d (%s)", key, n, examples[key]))
			end
			table.sort(report)
			print("[BRR_AutoRun] lobby clipping (cross-piece solid overlaps): " .. (#report > 0 and table.concat(report, " | ") or "none"))
			print(string.format("[BRR_AutoRun] zfight lobby pass (server): moved %s, remaining %s",
				tostring(lobby:GetAttribute("ZFightMoved")), tostring(lobby:GetAttribute("ZFightRemaining"))))
			zreport("lobby", { lobby, workspace:FindFirstChild("StageDisplay"), workspace:FindFirstChild("Showcase") }, function(part)
				return part:GetAttribute("Group") or (part:FindFirstAncestorOfClass("Folder") and part:FindFirstAncestorOfClass("Folder").Name) or "?"
			end)
			-- A gun on the floor is a full gun, built and z-fought at gun tolerance, and checked part for
			-- part against GunModels by tools/display_paths_probe.lua; the "zfight guns" line above scans
			-- every gun at that tolerance. At the map's tolerance here its millimetre detail all reads as
			-- fighting. So a weapon pickup contributes only its own dressing: the pad and beam, LootService's
			-- unnamed "Part"s (never the base, whose descendants would pull the gun back in). Every other
			-- pickup and chest is scanned whole. The counts say what was scanned, so it can't be nothing.
			local lootRoots, weaponRoots, otherRoots = {}, 0, 0
			for _, child in ipairs(loot:GetChildren()) do
				if child:GetAttribute("WeaponId") then
					for _, piece in ipairs(child:GetChildren()) do
						if piece:IsA("BasePart") and piece.Name == "Part" then
							table.insert(lootRoots, piece)
							weaponRoots += 1
						end
					end
				else
					table.insert(lootRoots, child)
					otherRoots += 1
				end
			end
			print(string.format("[BRR_AutoRun] zfight loot roots: %d weapon-pickup dressing parts, %d other pickups and chests", weaponRoots, otherRoots))
			local _, lootFlush = zreport("loot", lootRoots, function(part)
				local node = part
				while node and node.Parent ~= loot do node = node.Parent end
				return node and node.Name or "?"
			end)
			if lootFlush > 0 then
				-- Which pickups: two different bases on top of each other is a placement fault, not a model one.
				local first = ZFight.Scan(lootRoots)[1]
				local function baseOf(part)
					local node = part
					while node and node.Parent ~= loot do node = node.Parent end
					return node
				end
				local a, b = baseOf(first.a), baseOf(first.b)
				print(string.format("[BRR_AutoRun] zfight loot first pair: %s (%s) vs %s (%s), same pickup %s, bases %s apart",
					a and a.Name or "?", a and tostring(a:GetAttribute("WeaponId") or a:GetAttribute("ItemId")) or "?",
					b and b.Name or "?", b and tostring(b:GetAttribute("WeaponId") or b:GetAttribute("ItemId")) or "?",
					tostring(a == b), a and b and string.format("%.2f", (a.Position - b.Position).Magnitude) or "?"))
			end
		end

		-- Bots on the map with combat on, so their loot, heal, shield and fighting paths run.
		local BotService = require(modules:WaitForChild("BotService"))
		local CombatService = require(modules:WaitForChild("CombatService"))
		local spots = info.dropSpots or {}
		local spawned = BotService.Spawn(10, function(index)
			local spot = spots[(index - 1) % math.max(1, #spots) + 1] or Vector3.zero
			local x, z = spot.X + (index % 3) * 6, spot.Z + (index % 2) * 6
			return CFrame.new(x, MapGenerator.GroundHeightAt(x, z) + 5, z)
		end, function() end)
		CombatService.SetEnabled(true)
		print("[BRR_AutoRun] bots spawned: " .. tostring(#spawned))
		task.wait(25)
		local shielded, hurt = 0, 0
		for _, bot in ipairs(BotService.GetAll()) do
			if bot.humanoid and bot.humanoid.Parent then
				if (bot.humanoid:GetAttribute("Shield") or 0) > 0 then
					shielded += 1
				end
				if bot.humanoid.Health < bot.humanoid.MaxHealth then
					hurt += 1
				end
			end
		end
		print(string.format("[BRR_AutoRun] after 25s: %d bots alive, %d hurt, %d shielded", BotService.Count(), hurt, shielded))

		-- Explosive barrels: how many the map got, and one set off beside a bot hurts it and is gone.
		local HazardService = require(modules:WaitForChild("HazardService"))
		local vendors = 0
		for _, d in ipairs(workspace.Map:GetDescendants()) do
			if d.Name == "RotVendor" then vendors += 1 end
		end
		local barrelsBefore = HazardService.Count()
		local victim = BotService.GetAll()[3]
		local barrelResult = "no bot to test with"
		if victim and victim.humanoid and victim.humanoid.Health > 0 then
			local root = victim.character:FindFirstChild("HumanoidRootPart")
			local healthBefore = victim.humanoid.Health
			local barrel = HazardService.Barrel(workspace.Map, CFrame.new(root.Position + Vector3.new(4, -2.5, 0)))
			local shooter = BotService.GetAll()[4]
			HazardService.Damage(barrel, 100, shooter)
			task.wait(0.3)
			barrelResult = string.format("bot %s -> %.0f HP after the blast (want less), barrel gone=%s, chain count %d",
				tostring(healthBefore), victim.humanoid.Health, tostring(barrel.Parent == nil), HazardService.Count("barrel"))
		end
		print(string.format("[BRR_AutoRun] hazards: %d barrels on the map, %d vendors; test: %s", barrelsBefore, vendors, barrelResult))

			-- Rot Mines: one armed beside a bot (held still) goes off under it once it's armed.
			local mineVictim = BotService.GetAll()[5]
			local mineResult = "no bot to test with"
			if mineVictim and mineVictim.humanoid and mineVictim.humanoid.Health > 0 then
				local root = mineVictim.character:FindFirstChild("HumanoidRootPart")
				root.Anchored = true
				local healthBefore = mineVictim.humanoid.Health
				local mine = HazardService.Mine(workspace.Map, root.Position + Vector3.new(2, -2.5, 0), BotService.GetAll()[4])
				local parts = mine and #mine:GetDescendants() or -1
				local body = mine and mine.PrimaryPart
				local drop = body and (root.Position.Y - body.Position.Y) or -1
				task.wait(1)
				local armedEarly = mine and HazardService.IsArmed(mine) or false
				task.wait(1.6)
				root.Anchored = false
				mineResult = string.format("%d parts, %.1f below the bot's root, armed at 1s=%s (want false); bot %.0f -> %.0f HP after 2.6s (want less), mine gone=%s, mines left %d",
					parts, drop, tostring(armedEarly), healthBefore, mineVictim.humanoid.Health, tostring(mine == nil or mine.Parent == nil), HazardService.Count("mine"))
			end
			print(string.format("[BRR_AutoRun] mines: %s", mineResult))

		-- Bots dropping in: three more spawn high over a town under canopies and glide down.
		local MovementService = require(modules:WaitForChild("MovementService"))
		local dropSpot = spots[1] or Vector3.zero
		local dropped = BotService.Spawn(3, function(index)
			return CFrame.new(dropSpot.X + index * 8, MapGenerator.GroundHeightAt(dropSpot.X, dropSpot.Z) + 120, dropSpot.Z + 30)
		end, function() end, { dropIn = true, dropTargets = info.dropSpots })
		local canopiesAtStart = 0
		for _, bot in ipairs(dropped) do
			if bot.character:FindFirstChild("GliderCanopy") then canopiesAtStart += 1 end
		end
		task.wait(10)
		local landed, stillDropping, canopiesLeft = 0, 0, 0
		for _, bot in ipairs(dropped) do
			if bot.dropping then stillDropping += 1 end
			if bot.character:FindFirstChild("GliderCanopy") then canopiesLeft += 1 end
			-- Down and standing on something (a roof counts, so this isn't measured against the terrain).
			if not bot.dropping and bot.humanoid.FloorMaterial ~= Enum.Material.Air then
				landed += 1
			end
		end
		print(string.format("[BRR_AutoRun] bot drop-in: %d spawned with canopies %d; after 10s landed %d, still dropping %d, canopies left %d, in flight %d",
			#dropped, canopiesAtStart, landed, stillDropping, canopiesLeft, MovementService.DroppingCount()))

		-- Portable defenses: build each tier at a town centre, shoot one down, count the parts.
		local DefenseService = require(modules:WaitForChild("DefenseService"))
		local built = {}
		for index, id in ipairs({ "RotBarricade", "PopupBunker", "BrainrotFortress" }) do
			local spot = spots[1] or Vector3.zero
			local x, z = spot.X + index * 30, spot.Z + 40
			local origin = CFrame.new(x, MapGenerator.GroundHeightAt(x, z), z)
			local model = DefenseService.Build(id, origin, nil)
			built[id] = model and #model:GetDescendants() or -1
		end
		task.wait(1)
		local fortress = workspace:FindFirstChild("Defenses") and workspace.Defenses:FindFirstChild("BrainrotFortress")
		local before = fortress and fortress:GetAttribute("Health") or -1
		if fortress then
			DefenseService.Damage(fortress, 500)
		end
		local after = fortress and fortress:GetAttribute("Health") or -1
		if fortress then
			DefenseService.Damage(fortress, 5000)
		end
		task.wait(0.5)
		local collapsed = not (workspace:FindFirstChild("Defenses") and workspace.Defenses:FindFirstChild("BrainrotFortress")
			and workspace.Defenses.BrainrotFortress:GetAttribute("Health") > 0)
		print(string.format("[BRR_AutoRun] defenses: barricade %d parts, bunker %d parts, fortress %d parts; fortress %d -> %d HP, collapsed=%s",
			built.RotBarricade, built.PopupBunker, built.BrainrotFortress, before, after, tostring(collapsed)))

		-- The map itself: a wall soaks a partial hit and comes down at 100 (the HEALTH table).
		local DestructibleService = require(modules:WaitForChild("DestructibleService"))
		local wall = nil
		for _, d in ipairs(workspace.Map:GetDescendants()) do
			if d:IsA("BasePart") and d.Name == "Wall" and d.CanCollide then
				wall = d
				break
			end
		end
		local wallResult = "no wall found on the map"
		if wall then
			local recognised = DestructibleService.FromPart(wall) ~= nil
			-- A wall is 100. Partial hit first so "still standing" means something, then enough to
			-- finish it: the second figure should come back as the remainder, not the full amount.
			local first = DestructibleService.Damage(wall, 40, nil)
			local standing = wall.Parent ~= nil
			local second = DestructibleService.Damage(wall, 100, nil)
			task.wait(0.2)
			wallResult = string.format("recognised=%s (want true), 40 dealt %.0f standing=%s (want true), 100 more dealt %.0f (want 60), gone=%s (want true), tracked %d",
				tostring(recognised), first, tostring(standing), second, tostring(wall.Parent == nil), DestructibleService.Count())
		end
		print(string.format("[BRR_AutoRun] destructible: %s", wallResult))

		-- Explosives (claude-a4 [e8e0d6]): a rocket fired at a target's feet flies, bursts and hurts it;
		-- a frag with a short fuse lands beside another and goes off; a smoke cloud between two hides
		-- them from each other; and the loot has grenades and smoke bombs in it. The targets are
		-- stand-in rigs registered as combatants on a plate 300 studs above the map, so no bot the
		-- later checks index is touched, and everything is unregistered and removed after.
		local ProjectileService = require(modules:WaitForChild("ProjectileService"))
		local Combatants = require(modules:WaitForChild("Combatants"))
		local Ballistics = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Ballistics"))
		local stage = Instance.new("Model")
		stage.Name = "ExplosivesStage"
		local stageAt = (spots[1] or Vector3.zero) + Vector3.new(0, 300, 0)
		local plate = Instance.new("Part")
		plate.Size = Vector3.new(90, 2, 90)
		plate.CFrame = CFrame.new(stageAt - Vector3.new(0, 1, 0))
		plate.Anchored = true
		plate.Parent = stage
		stage.Parent = workspace
		local stands = {}
		local function stand(name, offset)
			local model = Instance.new("Model")
			model.Name = name
			local at = stageAt + offset
			local function limb(limbName, size, lift)
				local part = Instance.new("Part")
				part.Name = limbName
				part.Size = size
				part.CFrame = CFrame.new(at + Vector3.new(0, lift, 0))
				part.Anchored = true
				part.CanCollide = false
				part.Parent = model
				return part
			end
			model.PrimaryPart = limb("HumanoidRootPart", Vector3.new(2, 2, 1), 3)
			limb("UpperTorso", Vector3.new(2, 1.6, 1), 3.2)
			limb("Head", Vector3.new(1.2, 1.2, 1.2), 4.6)
			limb("LowerTorso", Vector3.new(1.8, 2, 1), 1)
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			model.Parent = stage
			humanoid.MaxHealth = 100
			humanoid.Health = 100
			local token = { isBot = true, name = name, character = model }
			Combatants.Register(model, token)
			table.insert(stands, model)
			return token, humanoid, model
		end
		local shooter = stand("ExplosivesShooter", Vector3.new(0, 0, -30))
		local rocketTarget, rocketHumanoid, rocketModel = stand("RocketTarget", Vector3.new(20, 0, 0))
		local fired = ProjectileService.FireWeapon(shooter, "CappuccinaLauncher", stageAt + Vector3.new(-10, 5, 0), rocketModel.PrimaryPart.Position - Vector3.new(0, 2.9, 0))
		local flight = 0
		repeat
			task.wait(0.05)
			flight += 0.05
		until ProjectileService.Counts() == 0 or flight > 3
		task.wait(0.2)
		print(string.format("[BRR_AutoRun] explosives rocket: fired=%s (want true), burst after ~%.2fs (want < 0.5), target 100 -> %.0f HP (want less)",
			tostring(fired), flight, rocketHumanoid.Health))

		local fragTarget, fragHumanoid, fragModel = stand("FragTarget", Vector3.new(-25, 0, 10))
		local spec = Ballistics.Throwables.CookedCoconut
		-- Dropped from four studs up beside it, cooked so only 0.7 s of fuse is left.
		local entry = ProjectileService.SpawnThrown(shooter, nil, "CookedCoconut", spec, fragModel.PrimaryPart.Position + Vector3.new(3, 1.5, 0), Vector3.zero, spec.fuse - 0.7)
		local elapsed = 0
		repeat
			task.wait(0.05)
			elapsed += 0.05
		until not ProjectileService.Peek(entry.id) or elapsed > 3
		task.wait(0.2)
		-- The shooter's own lob, twenty studs ahead of it: accepted, lands on the plate.
		local lobbed = ProjectileService.Throw(shooter, "CookedCoconut", stageAt + Vector3.new(0, 0, -10), { cook = 1 })
		local lobRounds, lobBodies = ProjectileService.Counts()
		print(string.format("[BRR_AutoRun] explosives frag: dropped frag went off after %.2fs (want ~0.7), target 100 -> %.0f HP (want less); lob accepted=%s (want true), in flight %d",
			elapsed, fragHumanoid.Health, tostring(lobbed), lobBodies))

		local smokeA, _, smokeAModel = stand("SmokeA", Vector3.new(-20, 0, 30))
		local smokeB, _, smokeBModel = stand("SmokeB", Vector3.new(20, 0, 30))
		local a, b = smokeAModel.PrimaryPart.Position, smokeBModel.PrimaryPart.Position
		local cloud = ProjectileService.AddCloud((a + b) / 2, "LowkeyLatte", ProjectileService.Clock() - 4)
		local blocked = ProjectileService.SmokeBlocks(a, b)
		local high = ProjectileService.SmokeBlocks(a + Vector3.new(0, 120, 0), b + Vector3.new(0, 120, 0))
		print(string.format("[BRR_AutoRun] explosives smoke: stands %.0f studs apart with a full cloud (r %.0f) between them: hidden=%s (want true), a line well above it hidden=%s (want false)",
			(a - b).Magnitude, Ballistics.SmokeRadius(cloud, ProjectileService.Clock()), tostring(blocked), tostring(high)))
		task.wait(3.5)
		ProjectileService.Clear()
		for _, model in ipairs(stands) do
			Combatants.Unregister(model)
		end
		stage:Destroy()

		-- A pickup is a base part carrying ItemId (LootService.spawnConsumable), not a model.
		local coconuts, lattes = 0, 0
		local lootFolder = workspace:FindFirstChild("Loot")
		if lootFolder then
			for _, d in ipairs(lootFolder:GetDescendants()) do
				if d:IsA("BasePart") then
					local itemId = d:GetAttribute("ItemId")
					if itemId == "CookedCoconut" then
						coconuts += 1
					elseif itemId == "LowkeyLatte" then
						lattes += 1
					end
				end
			end
		end
		print(string.format("[BRR_AutoRun] explosives loot: %d Cooked Coconuts and %d Lowkey Lattes on the floor (want some of each)", coconuts, lattes))

		-- The lobby firing range. Handing out a gun needs a real Player, which this run hasn't
		-- got, so what is checked is that the rack was actually built and the remotes exist —
		-- the realistic failure being a rack that silently never appears.
		local RangeService = require(modules:WaitForChild("RangeService"))
		-- Guns are taken off the Legendary podiums now; there is no separate rack.
		local racks = 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d.Name == "RangePodium" and d:FindFirstChildOfClass("ProximityPrompt") then
				racks += 1
			end
		end
		local remoteFolder = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
		local haveState = remoteFolder ~= nil and remoteFolder:FindFirstChild("RangeState") ~= nil
		local haveFire = remoteFolder ~= nil and remoteFolder:FindFirstChild("RangeFire") ~= nil
		print(string.format("[BRR_AutoRun] range: %d podiums with a take prompt (want 3), RangeState=%s RangeFire=%s, module=%s",
			racks, tostring(haveState), tostring(haveFire), tostring(RangeService ~= nil)))

		-- Sliding. The burst is a factor inside applySpeed rather than a write to WalkSpeed, so
		-- what matters is that the composed speed actually rises and falls back afterwards. A bot
		-- is a combatant token like a player, so it can be sprinted and slid here.
		local SlideMatch = require(modules:WaitForChild("MatchService"))
		local slideBot = BotService.GetAll()[6]
		local slideResult = "no bot to test with"
		if slideBot and slideBot.humanoid and slideBot.humanoid.Health > 0 then
			SlideMatch.SetSprinting(slideBot, true)
			local sprintSpeed = slideBot.humanoid.WalkSpeed
			local grounded = slideBot.humanoid.FloorMaterial ~= Enum.Material.Air
			local started = SlideMatch.StartSlide(slideBot)
			local slideSpeed = slideBot.humanoid.WalkSpeed
			local secondAttempt = SlideMatch.StartSlide(slideBot)
			task.wait(1.1)
			local settled = slideBot.humanoid.WalkSpeed
			SlideMatch.SetSprinting(slideBot, false)
			slideResult = string.format("grounded=%s started=%s (want true), sprint %.1f -> sliding %.1f (want higher) -> settled %.1f (want back to sprint), second attempt=%s (want false, on cooldown)",
				tostring(grounded), tostring(started), sprintSpeed, slideSpeed, settled, tostring(secondAttempt))
		end
		print(string.format("[BRR_AutoRun] slide: %s", slideResult))

		-- Every gun can be aimed, and aims where the crosshair is. The viewmodel puts the camera
		-- EyeRelief studs behind KP_Sight looking down it, so the line itself always lands on the
		-- crosshair; what can go wrong is the gun: no contract, sight hardware off that line, the line
		-- skewed from the bore, or something opaque standing in it.
		-- All silent in play, so all want to stay at zero. Rays are traced by hand: Roblox's query
		-- geometry pads millimetre-sized parts by several millimetres. tools/ads_align_probe.lua is
		-- the long form with per-gun measurements.
		local SightShared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
		local SightWeaponData = require(SightShared:WaitForChild("WeaponData"))
		local SightGunMM = require(SightShared:WaitForChild("GunModels")).StudsPerMillimetre
		local SightWeaponService = require(modules:WaitForChild("WeaponService"))
		local OPTICS = { iron = true, reddot = true, holo = true, scope = true }
		local function rayInterval(part, origin, direction)
			local o, d, h = part.CFrame:PointToObjectSpace(origin), part.CFrame:VectorToObjectSpace(direction), part.Size / 2
			local t0, t1 = 0, 1
			local function slab(oi, di, hi)
				if math.abs(di) < 1e-9 then return math.abs(oi) <= hi end
				local a, b = (-hi - oi) / di, (hi - oi) / di
				t0, t1 = math.max(t0, math.min(a, b)), math.min(t1, math.max(a, b))
				return t0 <= t1
			end
			local function quad(a, b, c)
				if a < 1e-9 then return c <= 0 end
				local disc = b * b - 4 * a * c
				if disc < 0 then return false end
				t0, t1 = math.max(t0, (-b - math.sqrt(disc)) / (2 * a)), math.min(t1, (-b + math.sqrt(disc)) / (2 * a))
				return t0 <= t1
			end
			local shape = part:IsA("Part") and part.Shape or nil
			if shape == Enum.PartType.Ball then
				local r = math.min(h.X, h.Y, h.Z)
				return quad(d:Dot(d), 2 * o:Dot(d), o:Dot(o) - r * r)
			elseif shape == Enum.PartType.Cylinder then
				local r = math.min(h.Y, h.Z)
				return slab(o.X, d.X, h.X) and quad(d.Y * d.Y + d.Z * d.Z, 2 * (o.Y * d.Y + o.Z * d.Z), o.Y * o.Y + o.Z * o.Z - r * r)
			end
			if not (slab(o.X, d.X, h.X) and slab(o.Y, d.Y, h.Y) and slab(o.Z, d.Z, h.Z)) then return false end
			if part:IsA("WedgePart") or shape == Enum.PartType.Wedge then
				local f, g = o.Y * h.Z - o.Z * h.Y, d.Y * h.Z - d.Z * h.Y
				if math.abs(g) < 1e-9 then return f <= 0 end
				if g > 0 then t1 = math.min(t1, -f / g) else t0 = math.max(t0, -f / g) end
			end
			return t0 <= t1
		end
		-- What stands in the line of sight: straight down the line from the eye (irons a hair above it, so a
		-- post top on the line grazes), every part solid enough to hide the target (under 0.5 transparent,
		-- the rule ads_align_probe uses for glass), and for irons a rear sight right across the line with no
		-- notch. Scopes are included: an opaque scope lens is exactly what has to fail here.
		local function sightBlockers(gunModel, kp, optic, relief, centredBead)
			local eye = (kp * CFrame.new(0, optic == "iron" and 0.3 * SightGunMM or 0, relief)).Position
			local hits = {}
			for _, part in ipairs(gunModel:GetDescendants()) do
				if part:IsA("BasePart") and part.Transparency < 0.5 and rayInterval(part, eye, kp.LookVector * 40) then
					if part.Name ~= "SightDot" and part.Name ~= "SightReticle" and part.Name ~= "ScopeReticle" and not centredBead[part] then
						hits[part.Name] = true
					end
				end
				-- A rear sight straight across the line with its top on it has no notch: the ray skims it, but
				-- it hides the whole front post.
				if optic == "iron" and part:IsA("BasePart") and string.sub(part.Name, 1, 9) == "RearSight" then
					local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
					for _, corner in ipairs({ -1, 1 }) do
						for _, cy in ipairs({ -1, 1 }) do
							for _, cz in ipairs({ -1, 1 }) do
								local p = kp:PointToObjectSpace(part.CFrame * (part.Size / 2 * Vector3.new(corner, cy, cz)))
								lo, hi = lo:Min(p), hi:Max(p)
							end
						end
					end
					local mm = SightGunMM
					if lo.X < -0.5 * mm and hi.X > 0.5 * mm and lo.Y < 0 and hi.Y > -1 * mm then
						hits[part.Name .. " (no notch)"] = true
					end
				end
			end
			local names = {}
			for name in pairs(hits) do
				table.insert(names, name)
			end
			table.sort(names)
			return names
		end
		local noContract, offLine, blocked, builtGuns = {}, {}, {}, 0
		for id in pairs(SightWeaponData.Weapons) do
			local okBuild, gunModel = pcall(SightWeaponService.BuildGunModel, SightWeaponData.Get(id), Color3.fromRGB(200, 200, 200), Enum.Material.Metal)
			if okBuild and gunModel then
				builtGuns += 1
				-- Built at the design origin, so part CFrames are model space, the same as KP_Sight.
				local kp, optic, relief = gunModel:GetAttribute("KP_Sight"), gunModel:GetAttribute("Optic"), gunModel:GetAttribute("EyeRelief")
				local muzzle = gunModel.PrimaryPart and gunModel.PrimaryPart:FindFirstChild("Muzzle")
				if typeof(kp) ~= "CFrame" or not OPTICS[optic] or type(relief) ~= "number" or relief <= 0 or not muzzle then
					table.insert(noContract, id)
				else
					local function offBy(point) -- worst of right/up offset from the line, in mm
						local p = kp:PointToObjectSpace(point)
						return math.max(math.abs(p.X), math.abs(p.Y)) / SightGunMM
					end
					-- The reference each optic is aimed with, taking the best candidate of its kind.
					local best, centredBead = math.huge, {}
					for _, part in ipairs(gunModel:GetDescendants()) do
						if part:IsA("BasePart") then
							local candidates = {}
							if optic == "iron" and part.Name == "FrontSight" then
								table.insert(candidates, part.CFrame * Vector3.new(0, part.Size.Y / 2, 0))
							elseif optic == "iron" and part.Name == "FrontBead" then
								table.insert(candidates, part.Position + kp.UpVector * part.Size.Y / 2)
								table.insert(candidates, part.Position)
								if offBy(part.Position) <= 0.5 then centredBead[part] = true end
							elseif (optic == "reddot" or optic == "holo") and part.Name == "SightDot" then
								table.insert(candidates, part.Position)
							elseif optic == "scope" and part.Name == "Scope" then
								table.insert(candidates, part.Position)
							end
							for _, point in ipairs(candidates) do
								best = math.min(best, offBy(point))
							end
						end
					end
					local skew = math.deg(math.acos(math.clamp(muzzle.WorldCFrame.LookVector:Dot(kp.LookVector), -1, 1)))
					if best > 0.5 or skew > 0.05 then
						table.insert(offLine, string.format("%s(%.1fmm,%.2fdeg)", id, math.min(best, 999), skew))
					end
					local okBlockers, names = pcall(sightBlockers, gunModel, kp, optic, relief, centredBead)
					if not okBlockers then
						print("[BRR_AutoRun] sights block ERROR (" .. id .. "): " .. tostring(names))
						table.insert(blocked, id .. "(ERROR)")
					elseif #names > 0 then
						table.insert(blocked, id .. "(" .. table.concat(names, "/") .. ")")
					end
				end
				gunModel:Destroy()
			end
		end
		local function listed(list)
			table.sort(list)
			return #list > 0 and (" -> " .. table.concat(list, ", ")) or ""
		end
		print(string.format("[BRR_AutoRun] sights: %d guns built; no ADS contract %d (want 0)%s; sight off its line or bore %d (want 0)%s; line of sight blocked %d (want 0)%s",
			builtGuns, #noContract, listed(noContract), #offLine, listed(offLine), #blocked, listed(blocked)))
		-- Self-test: a scoped gun with its scope glass made opaque must come out blocked. In its own pcall, so
		-- an error here is reported and the checks after it still run.
		local okLensTest, lensTestError = pcall(function()
			local lensTest = "no scoped gun found: FAILED"
			local sightIds = {}
			for id in pairs(SightWeaponData.Weapons) do
				table.insert(sightIds, id)
			end
			table.sort(sightIds)
			for _, id in ipairs(sightIds) do
				local def = SightWeaponData.Get(id)
				if def.style == "sniper" or def.style == "dmr" or def.style == "railgun" then
					local okBuild, gunModel = pcall(SightWeaponService.BuildGunModel, def, Color3.fromRGB(200, 200, 200), Enum.Material.Metal)
					if okBuild and gunModel and gunModel:GetAttribute("Optic") == "scope" then
						local lenses = 0
						for _, part in ipairs(gunModel:GetDescendants()) do
							if part:IsA("BasePart") and part.Name == "ScopeLens" then
								part.Transparency = 0
								lenses += 1
							end
						end
						local names = sightBlockers(gunModel, gunModel:GetAttribute("KP_Sight"), "scope", gunModel:GetAttribute("EyeRelief"), {})
						lensTest = string.format("%s with its %d scope lens(es) made opaque -> %s", id, lenses,
							#names > 0 and ("blocked by " .. table.concat(names, "/") .. ": ok") or "NOT blocked: FAILED")
						gunModel:Destroy()
						break
					elseif okBuild and gunModel then
						gunModel:Destroy()
					end
				end
			end
			print("[BRR_AutoRun] sights self-test: " .. lensTest)
		end)
		if not okLensTest then
			print("[BRR_AutoRun] sights self-test block ERROR: " .. tostring(lensTestError))
		end
		zreport("defenses", { workspace:FindFirstChild("Defenses") }, function(part)
			local model = part:FindFirstAncestorOfClass("Model")
			return model and model.Name or "?"
		end)

		-- Every gun model builds (variants included), with its grip and muzzle, and nothing on any of
		-- them left flush. Guns are scanned at their own millimetre tolerance
		-- (GunModels.ZFightTolerance): the map's 0.045 studs is about 12 mm and would call every rail
		-- slot and serration a fight.
		local WeaponService = require(modules:WaitForChild("WeaponService"))
		local SharedFolder = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
		local WeaponDataForGuns = require(SharedFolder:WaitForChild("WeaponData"))
		local Rarity = require(SharedFolder:WaitForChild("Rarity"))
		local gunParts, gunCount, gunErrors, noGrip = 0, 0, {}, {}
		local gunNudged, gunFlush, gunFlushLines = 0, 0, {}
		local nudgeByGun = {}
		for gunId, gunDef in pairs(WeaponDataForGuns.Weapons) do
			local okGun, modelOrErr = pcall(WeaponService.BuildGunModel, gunDef, Rarity.Color(gunDef.rarity), Enum.Material.Metal)
			if okGun and modelOrErr then
				gunCount += 1
				gunParts += #modelOrErr:GetChildren()
				if not modelOrErr:FindFirstChild("Grip") or not modelOrErr.PrimaryPart or not modelOrErr.PrimaryPart:FindFirstChild("Muzzle") then
					table.insert(noGrip, gunId)
				end
				local touched = ZFight.Report({ modelOrErr }, nil, 1)
				gunNudged += touched
				nudgeByGun[gunId] = touched
				local flush = ZFight.Scan({ modelOrErr }, require(SharedFolder:WaitForChild("GunModels")).ZFightTolerance)
				gunFlush += #flush
				if #flush > 0 then
					table.insert(gunFlushLines, gunId .. ": " .. table.concat(ZFight.Describe(flush, function() return gunId end, 4), " ; "))
				end
				modelOrErr:Destroy()
			else
				table.insert(gunErrors, gunId .. ": " .. tostring(modelOrErr))
			end
		end
		print(string.format("[BRR_AutoRun] guns: %d models, %d parts total; missing grip/muzzle: %s; errors: %s",
			gunCount, gunParts, #noGrip > 0 and table.concat(noGrip, ", ") or "none", #gunErrors > 0 and table.concat(gunErrors, " | ") or "none"))
		-- "Still flush" is scanned after each gun's own build pass (the shipped model), so it only counts what
		-- that pass couldn't resolve.
		print(string.format("[BRR_AutoRun] zfight guns: nudged at build %d parts; still flush after the build's pass %d%s", gunNudged, gunFlush,
			#gunFlushLines > 0 and (" [" .. table.concat(gunFlushLines, " | ") .. "]") or ""))
		-- The design check the pass can't hide: a gun whose builder now needs more parts nudged than its
		-- recorded count has gained faces lying in each other's planes. The counts live in
		-- tools/gun_nudge_baseline.json, which this run only reads; after reviewing a run, record new counts
		-- deliberately with `python tools/update_gun_nudge_baseline.py <this run's output> --note "why"`.
		-- Both in their own pcalls, so an error is reported and the checks after them still run.
		local okBaseline, baselineError = pcall(function()
			local nudgeBaseline = GUN_NUDGE_BASELINE
			local perGun, grown, unrecorded = {}, {}, {}
			for gunId, count in pairs(nudgeByGun) do
				table.insert(perGun, gunId .. "=" .. count)
				local recorded = nudgeBaseline and nudgeBaseline[gunId]
				if recorded == nil then
					table.insert(unrecorded, gunId)
				elseif count > recorded then
					table.insert(grown, string.format("%s %d>%d", gunId, count, recorded))
				end
			end
			table.sort(perGun)
			table.sort(grown)
			table.sort(unrecorded)
			print("[BRR_AutoRun] zfight guns nudged per gun: " .. table.concat(perGun, ","))
			print(string.format("[BRR_AutoRun] zfight guns nudge baseline %s: grown past it %d%s; without a recorded count %d%s (want 0 and 0)",
				nudgeBaseline and "loaded" or "MISSING", #grown, #grown > 0 and (" [" .. table.concat(grown, ", ") .. "]") or "",
				#unrecorded, #unrecorded > 0 and (" [" .. table.concat(unrecorded, ", ") .. "]") or ""))
		end)
		if not okBaseline then
			print("[BRR_AutoRun] zfight guns baseline block ERROR: " .. tostring(baselineError))
		end
		-- Self-test: two coplanar boxes the build pass never saw must scan as flush.
		local okPlanted, plantedError = pcall(function()
			local planted = Instance.new("Model")
			for _, size in ipairs({ Vector3.new(1, 1, 1), Vector3.new(0.5, 1, 0.5) }) do
				local box = Instance.new("Part")
				box.Size = size
				box.CFrame = CFrame.new(0, 9000, 0)
				box.Anchored = true
				box.Parent = planted
			end
			local plantedFlush = #ZFight.Scan({ planted }, require(SharedFolder:WaitForChild("GunModels")).ZFightTolerance)
			print(string.format("[BRR_AutoRun] zfight guns self-test: a planted coplanar pair scans as %d flush (want at least 1): %s",
				plantedFlush, plantedFlush >= 1 and "ok" or "FAILED"))
			planted:Destroy()
		end)
		if not okPlanted then
			print("[BRR_AutoRun] zfight guns self-test block ERROR: " .. tostring(plantedError))
		end

		-- Crates, chest, every item (the glider open too), every brainrot and every accessory: built
		-- once each through their builders, which run the pass themselves; nothing may be left flush.
		local function sampleSet(label, build)
			local nudged, flush, lines, count, errors = 0, 0, {}, 0, {}
			local ok, err = pcall(build, function(name, model)
				if typeof(model) ~= "Instance" then
					table.insert(errors, name .. ": nothing built")
					return
				end
				count += 1
				nudged += ZFight.Report({ model }, nil, 1)
				local pairsFound = ZFight.Scan({ model })
				flush += #pairsFound
				if #pairsFound > 0 and #lines < 12 then
					table.insert(lines, name .. ": " .. table.concat(ZFight.Describe(pairsFound, function() return name end, 3), " ; "))
				end
				model:Destroy()
			end)
			if not ok then
				table.insert(errors, tostring(err))
			end
			print(string.format("[BRR_AutoRun] zfight %s: %d models, nudged at build %d parts; still flush %d%s%s", label, count, nudged, flush,
				#lines > 0 and (" [" .. table.concat(lines, " | ") .. "]") or "", #errors > 0 and ("; errors: " .. table.concat(errors, " | ")) or ""))
		end
		local CrateModels = require(SharedFolder:WaitForChild("CrateModels"))
		sampleSet("crates", function(check)
			for _, tier in ipairs({ "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Super" }) do
				check("Crate " .. tier, (CrateModels.Crate(tier)))
			end
			check("Chest", (CrateModels.Chest(CFrame.new(0, 500, 0))))
		end)
		local ItemModels = require(SharedFolder:WaitForChild("ItemModels"))
		local ItemData = require(SharedFolder:WaitForChild("ItemData"))
		sampleSet("items", function(check)
			for _, id in ipairs(ItemData.Order) do
				check(id, (ItemModels.Build(id)))
			end
			check("RotGlider open", (ItemModels.Build("RotGlider", { open = true })))
		end)
		local BrainrotModels = require(SharedFolder:WaitForChild("BrainrotModels"))
		local BrainrotData = require(SharedFolder:WaitForChild("BrainrotData"))
		sampleSet("brainrots", function(check)
			for _, def in ipairs(BrainrotData.Types) do
				check(def.name, BrainrotModels.Build(def, { flair = false }))
			end
		end)
		local AccessoryService = require(modules:WaitForChild("AccessoryService"))
		local CosmeticData = require(SharedFolder:WaitForChild("CosmeticData"))
		sampleSet("accessories", function(check)
			local dummy = BotService.GetAll()[1] and BotService.GetAll()[1].character
			if not dummy then
				error("no bot character to dress")
			end
			for id, item in pairs(CosmeticData.Items) do
				if item.kind == "Accessory" then
					AccessoryService.Attach(dummy, id)
					local worn = dummy:FindFirstChild("CosmeticAccessory")
					if worn then
						-- Report without destroying the character's own parts.
						local clone = worn:Clone()
						worn:Destroy()
						check(item.name or id, clone)
					else
						check(item.name or id, nil)
					end
				end
			end
		end)

		-- A bot throws a barricade up in front of itself, the way BotService does under fire. Bots
		-- on a slope are refused (that's the site check working); the first on flat ground builds.
		local refused, builtBy = {}, nil
		for _, bot in ipairs(BotService.GetAll()) do
			local root = bot.character:FindFirstChild("HumanoidRootPart")
			if root then
				local look = root.CFrame.LookVector
				local flat = Vector3.new(look.X, 0, look.Z).Unit
				local model, reason = DefenseService.Deploy(bot, bot.character, "RotBarricade", root.Position + flat * 5, flat)
				if model then
					builtBy = bot.name .. " (" .. #model:GetDescendants() .. " parts)"
					break
				end
				table.insert(refused, reason or "?")
			end
		end
		print(string.format("[BRR_AutoRun] bot barricade: %s after %d refusals (%s)", builtBy or "NOT BUILT", #refused, table.concat(refused, "; ")))

		-- Death effects: the last bot kills the others, one gun per effect, and we look at the bodies.
		-- No match is running, so the death watcher isn't attached; HandleDeath is called by hand.
		local WeaponData = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("WeaponData"))
		local guns = { "TralalaShotgun", "BubbleBlaster", "CrumblyCarbine", "CappuccinaLauncher", "LarilaSniper",
			"LagSwitchSMG", "PocketPopper", "DeluluRailgun", "GoldenSahurCannon" }
		local DeathFxService = require(modules:WaitForChild("DeathFxService"))
		local all = BotService.GetAll()
		local killer = all[#all]
		local socketsBefore = 0
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("BallSocketConstraint") then socketsBefore += 1 end
		end
		print(string.format("[BRR_AutoRun] deathfx hook set in this context: %s; sockets in workspace before: %d",
			tostring(CombatService.OnDeathFx ~= nil), socketsBefore))
		local probe = all[1].character
		local motors, motorsOn, socks, socksOn, sample = 0, 0, 0, 0, {}
		for _, d in ipairs(probe:GetDescendants()) do
			if d:IsA("Motor6D") or d:IsA("AnimationConstraint") then
				motors += 1
				if d.Enabled then motorsOn += 1 end
			elseif d:IsA("BallSocketConstraint") then
				socks += 1
				if d.Enabled then socksOn += 1 end
				if #sample < 3 then
					table.insert(sample, string.format("%s@%s(%s-%s)", d.Name, d.Parent.Name,
						d.Attachment0 and d.Attachment0.Parent.Name or "?", d.Attachment1 and d.Attachment1.Parent.Name or "?"))
				end
			end
		end
		print(string.format("[BRR_AutoRun] rig: joints %d (%d on), sockets %d (%d on): %s", motors, motorsOn, socks, socksOn, table.concat(sample, " ")))
		local headBefore = { probe.Head.Position.Y, all[5].character.Head.Position.Y, all[2].character.Head.Position.Y }
		local applied = {}
		for index, gunId in ipairs(guns) do
			local victim = all[index]
			if victim and victim ~= killer and victim.humanoid and victim.humanoid.Health > 0 then
				local before = 0
				for _, d in ipairs(victim.character:GetDescendants()) do
					if d:IsA("BallSocketConstraint") then before += 1 end
				end
				CombatService.DealDamage(killer, victim, 9999, gunId, index == 1)
				CombatService.HandleDeath(victim)
				-- The hook lives on the server's copy of CombatService; a plugin's require gets its
				-- own copy, so drive the effect directly too (Apply runs once per body either way).
				DeathFxService.OnDeath(victim, killer, WeaponData.Get(gunId))
				table.insert(applied, string.format("%s:pre%d:%s", gunId, before, tostring(victim.character:GetAttribute("DeathFx"))))
			end
		end
		print("[BRR_AutoRun] deathfx applied: " .. table.concat(applied, " "))
		task.wait(1.5)
		local report = {}
		for index, gunId in ipairs(guns) do
			local victim = all[index]
			if victim and victim ~= killer and victim.character.Parent then
				local sockets, hidden, total = 0, 0, 0
				for _, d in ipairs(victim.character:GetDescendants()) do
					if d:IsA("BallSocketConstraint") then sockets += 1 end
					if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
						total += 1
						if d.Transparency >= 0.99 then hidden += 1 end
					end
				end
				table.insert(report, string.format("%s->%s(s%d h%d/%d)", WeaponData.Get(gunId).killEffect,
					tostring(victim.character:GetAttribute("DeathFx")), sockets, hidden, total))
			end
		end
		print("[BRR_AutoRun] deathfx at 1.5s: " .. table.concat(report, " "))
		local jointsAfter = 0
		for _, d in ipairs(probe:GetDescendants()) do
			if (d:IsA("Motor6D") or d:IsA("AnimationConstraint")) and d.Enabled then jointsAfter += 1 end
		end
		-- A ragdoll's hand hangs away from where the pose held it; a statue's stays put.
		local handDrop = probe:FindFirstChild("RightHand") and probe:FindFirstChild("Head")
			and (probe.Head.Position.Y - probe.RightHand.Position.Y) or -1
		-- The root part must stay with the torso (want a gap under 3): physics rigs drop their
		-- root joint at death and DeathFxService pins it back with a weld.
		local hrp, lower = probe:FindFirstChild("HumanoidRootPart"), probe:FindFirstChild("LowerTorso")
		print(string.format("[BRR_AutoRun] ragdoll body: joints still on %d, head dropped %.1f studs (want > 3), head-to-hand %.1f, root gap %.1f (want < 3); frozen body head moved %.1f (want 0)",
			jointsAfter, headBefore[1] - probe.Head.Position.Y, handDrop, hrp and lower and (hrp.Position - lower.Position).Magnitude or -1,
			math.abs(headBefore[2] - all[5].character.Head.Position.Y)))
		task.wait(6)
		local visible = 0
		for index = 1, #guns do
			local victim = all[index]
			if victim and victim ~= killer and victim.character.Parent then
				for _, d in ipairs(victim.character:GetDescendants()) do
					if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 0.99 then visible += 1 end
				end
			end
		end
		print(string.format("[BRR_AutoRun] deathfx at 7.5s: visible body parts %d (want 0); floated body rose %.1f studs (want > 5)",
			visible, all[2].character.Head.Position.Y - headBefore[3]))

		-- Bot animation tracks. A load that fails is dropped silently, so the useful checks are
		-- that every expected track exists at all, and that a bot actually carrying a gun is
		-- playing the hold pose rather than the empty-handed cycle.
		-- Start the think loop first. BotService.Start spawns the tick that calls updateBot, and
		-- updateBot is what drives animation — the harness never started it, so bots here are
		-- static mannequins moved only by direct calls, and any animation state read before this
		-- was measuring a loop that was not running. This sits after the mine and slide checks,
		-- which anchor and drive bots by hand and would be disturbed by a live loop.
		BotService.Start()
		task.wait(1.2)
		local animBots = BotService.GetAll()
		local animResult = "no bots to check"
		if #animBots > 0 then
			local sample = animBots[1]
			local loaded, missing = 0, {}
			for _, name in ipairs({ "idle", "walk", "run", "jump", "fall", "hold" }) do
				if sample.tracks and sample.tracks[name] then
					loaded += 1
				else
					table.insert(missing, name)
				end
			end
			-- Living bots only, matching the condition updateBot itself uses. It returns
			-- immediately for a dead bot or one whose character has gone, so a corpse can never
			-- be posed — and the death-effect checks above deliberately kill nine of them, whose
			-- characters and guns linger for a few seconds afterwards. Counting those was what
			-- reported 4 of 13 while the feature was working perfectly well.
			local holding, posed = 0, 0
			for _, b in ipairs(animBots) do
				local alive = b.humanoid and b.humanoid.Health > 0 and b.character and b.character.Parent
				if alive and b.character:FindFirstChild("HeldGun") then
					holding += 1
					if b.tracks and b.tracks.hold and b.tracks.hold.IsPlaying then
						posed += 1
					end
				end
			end
			-- Not playing tells us nothing about why. Take one gun-carrying bot apart: does the
			-- track exist, how long is it, what priority did it get, is it playing, and does it
			-- stay playing if we start it by hand? A 0.04s pose that stops instantly, a track
			-- that never starts, and a track that plays but moves nothing are three different
			-- bugs with three different fixes.
			local detail = "no living gun-carrying bot"
			for _, b in ipairs(animBots) do
				local alive = b.humanoid and b.humanoid.Health > 0 and b.character and b.character.Parent
				if detail == "no living gun-carrying bot" and alive and b.character:FindFirstChild("HeldGun") then
					local track = b.tracks and b.tracks.hold
					if not track then
						detail = "hold track missing on this bot"
					else
						local before = track.IsPlaying
						track:Play(0.1)
						task.wait(0.4)
						local afterPlay = track.IsPlaying
						-- currentTrack is the discriminator. updateAnimation sets it every time it
						-- runs, and the hold block sits above every early return in that same
						-- function. So nil means the function is not executing for this bot at
						-- all and the call site reading is wrong; a movement name means it is
						-- executing, the hold block ran, and the fault is in how the track
						-- behaves rather than in the control flow. Opposite fixes.
						detail = string.format("currentTrack=%s; len %.2fs priority %s; playing before=%s, after forcing Play=%s, weight %.2f",
							tostring(b.currentTrack), track.Length, tostring(track.Priority), tostring(before), tostring(afterPlay), track.WeightCurrent)
					end
				end
			end
			animResult = string.format("%d/6 tracks loaded%s; %d bots carrying a gun, %d playing the hold pose (want equal); sample: %s",
				loaded, #missing > 0 and (" MISSING " .. table.concat(missing, ", ")) or "", holding, posed, detail)
		end
		print(string.format("[BRR_AutoRun] bot anims: %s", animResult))

		-- Bots spawn empty-handed now and have to find a gun on the map. "Spawned unarmed" and
		-- "never armed itself all match" look identical in a log, so this checks both ends.
		-- The timing matters: the 25s settle earlier in this run happened while the think loop was
		-- still stopped, so bots were static and could not loot. They have only been thinking since
		-- the animation check above started the loop, hence the wait here before counting.
		task.wait(12)
		local armed, carrying, deadOnes = 0, 0, 0
		for _, b in ipairs(animBots) do
			if b.humanoid and b.humanoid.Health <= 0 then
				deadOnes += 1
			end
			if b.weapon then
				armed += 1
			end
			if b.character and b.character:FindFirstChild("HeldGun") then
				carrying += 1
			end
		end
		print(string.format("[BRR_AutoRun] bot arming: %d of %d bots have a weapon, %d carry a gun model (want these two equal, and above 0 once they have looted); %d dead",
			armed, #animBots, carrying, deadOnes))

		-- Bot behaviour (BotService + BotNav). Last on purpose: the think loop above can't be stopped,
		-- and it's been running for about 13 s. Checked over 5 s of living bots: no think errors, bots
		-- trying to walk actually moving (not grinding into walls), the path queue draining, and what a
		-- bot update costs. tools/bot_probe.lua measures all of this properly, scenario by scenario.
		local thinkErrors = 0
		for _, line in ipairs(lines) do
			if string.find(line, "Bot update failed", 1, true) then
				thinkErrors += 1
			end
		end
		local stats = BotService.Stats or {}
		local before = table.clone(stats)
		local samples, grinding = 0, 0
		for _ = 1, 20 do
			task.wait(0.25)
			for _, b in ipairs(BotService.GetAll()) do
				local root = b.character and b.character:FindFirstChild("HumanoidRootPart")
				if root and b.humanoid and b.humanoid.Health > 0 and b.character.Parent and not b.dropping
					and b.humanoid.FloorMaterial ~= Enum.Material.Air then
					samples += 1
					local velocity = root.AssemblyLinearVelocity
					local toward = b.humanoid.WalkToPoint - root.Position
					if Vector3.new(toward.X, 0, toward.Z).Magnitude > 3 and Vector3.new(velocity.X, 0, velocity.Z).Magnitude < 1.5 then
						grinding += 1
					end
				end
			end
		end
		local function delta(key)
			return (stats[key] or 0) - (before[key] or 0)
		end
		local updates = math.max(1, delta("updates"))
		local computed = delta("pathOk") + delta("pathFail")
		-- Server-owned physics on every living bot (automatic ownership would hand them to nearby players).
		-- What can be measured here is whether the CLAIM is accepted: GetNetworkOwnershipAuto keeps
		-- reading true in a Studio run with no players (measured), so a readback would report every bot
		-- as unclaimed whatever the claim did. Whether ownership really sticks needs a playtest with a
		-- player standing next to a bot.
		local owned, living, ownErr = 0, 0, nil
		for _, b in ipairs(BotService.GetAll()) do
			local root = b.character and b.character:FindFirstChild("HumanoidRootPart")
			if root and b.humanoid and b.humanoid.Health > 0 and b.character.Parent then
				living += 1
				local okSet, setErr = pcall(root.SetNetworkOwner, root, nil)
				if okSet then
					owned += 1
				else
					ownErr = ownErr or tostring(setErr)
				end
			end
		end
		print(string.format("[BRR_AutoRun] bot behaviour: %d think errors (want 0); %d living-bot samples (want > 0, or nothing below was measured), grinding in %d (want under 10%%); in 5 s %d paths computed (%d failed), longest queue wait so far %.1fs (want under 5); think %.0f us per bot update, worst tick %.1f ms; server physics claim accepted on %d of %d living bots (want all; the readback is not meaningful without players, so this is the claim call itself)%s",
			thinkErrors, samples, grinding, computed, delta("pathFail"), stats.queueWaitMax or -1,
			delta("thinkTime") / updates * 1e6, (stats.maxTick or 0) * 1000, owned, living,
			ownErr and ("; first claim error: " .. ownErr) or ""))
	end)
	if not ok then
		warn("[BRR_AutoRun] map test failed: " .. tostring(err))
	end
	flush()
end)
-- Keep saving the log for as long as the run lasts, not just its first minutes: a long run whose
-- Studio dies later (out of memory, say) would otherwise lose everything since the last save.
task.spawn(function()
	while true do
		task.wait(10)
		flush()
	end
end)
'@
# The guns' recorded z-fight nudge counts, as a Lua table (nil when the file is missing): read only,
# written deliberately by tools/update_gun_nudge_baseline.py.
$nudgeBaselineLua = "nil"
$nudgeBaselinePath = Join-Path $PSScriptRoot "gun_nudge_baseline.json"
if (Test-Path $nudgeBaselinePath) {
	$nudgeBaselineJson = Get-Content $nudgeBaselinePath -Raw | ConvertFrom-Json
	$nudgeEntries = @()
	foreach ($entry in $nudgeBaselineJson.guns.PSObject.Properties) {
		if ($entry.Name -match '^[A-Za-z0-9_]+$') { $nudgeEntries += ('["{0}"] = {1}' -f $entry.Name, [int]$entry.Value) }
	}
	$nudgeBaselineLua = "{ " + ($nudgeEntries -join ", ") + " }"
}
$lua = $lua.Replace("MAP_ID", $MapId).Replace("RUN_TOKEN", $runToken).Replace("GUN_NUDGE_BASELINE", $nudgeBaselineLua)
if ($Probe -ne "") {
	# Resolve-Path first: .NET's current directory is not PowerShell's, so a relative -Probe used to
	# read as nothing, and the run then printed a clean-looking log with no findings at all.
	$probeSource = [System.IO.File]::ReadAllText((Resolve-Path $Probe).Path)
	if (-not $probeSource) { throw "probe file is empty: $Probe" }
	$lua = @'
-- TEMPORARY probe plugin (written by runtest.ps1 -Probe, deleted by it too).
-- Local plugins load in EVERY open Studio: act only inside the harness's own snapshot.
if not string.find(game.Name, "BRR_RunTest", 1, true) then
	return
end
local LogService = game:GetService("LogService")
local NL = string.char(10)
local lines = {}
LogService.MessageOut:Connect(function(message, messageType)
	table.insert(lines, messageType.Name .. " | " .. message)
	if #lines > 5000 then
		table.remove(lines, 1)
	end
end)
-- Every run shares one plugin settings file. The run token marks this run's log, and the flush
-- straight away overwrites an earlier run's, so a Studio that dies early can never have someone
-- else's output read back as its own.
local function flush()
	plugin:SetSetting("BRR_LOG", "BRR_LOG_BEGIN RUN_TOKEN" .. NL .. table.concat(lines, NL) .. NL .. "BRR_LOG_END")
end
flush()
task.delay(8, function()
	print("[BRR_Probe] start")
	local ok, err = pcall(function()
PROBE_SOURCE
	end)
	if not ok then
		warn("[BRR_Probe] failed: " .. tostring(err))
	end
	-- The token is unique to this run, so runtest.ps1 can stop waiting as soon as it appears
	-- without being fooled by an earlier probe's log still sitting in the settings file.
	print("[BRR_Probe] done RUN_TOKEN")
	flush()
	task.delay(2, flush)
end)
-- Keep saving for the whole probe, however long it runs (a probe used to be saved only for its
-- first 64 s, so a multi-minute probe whose Studio died lost everything after that).
task.spawn(function()
	while true do
		task.wait(8)
		flush()
	end
end)
'@
	$lua = $lua.Replace("RUN_TOKEN", $runToken).Replace("PROBE_SOURCE", $probeSource)
	# A probe usually finishes in seconds and ends the run itself, so the DEFAULT wait is shorter for
	# one. An explicit -WaitSeconds always wins: a long probe that was silently cut off at 75 s looked
	# like a clean finish, which is worse than waiting.
	if (-not $PSBoundParameters.ContainsKey("WaitSeconds")) { $WaitSeconds = 75 }
}
$xml = "<roblox version=`"4`">`n`t<Item class=`"Script`" referent=`"RBX0`">`n`t`t<Properties>`n`t`t`t<string name=`"Name`">BRR_AutoRun_TEMP</string>`n`t`t`t<ProtectedString name=`"Source`">" + $lua.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;") + "</ProtectedString>`n`t`t</Properties>`n`t</Item>`n</roblox>`n"
[System.IO.File]::WriteAllText($plugin, $xml, (New-Object System.Text.UTF8Encoding $false))

# Both markers: while we hold the lock, any harness Studio still open (of either kind) was abandoned
# by a run that died, and a leftover one would share this run's plugin and log file.
"waiting up to $WaitSeconds s for this run (pass -WaitSeconds to change it)"
Stop-StudioWindows "BRR_RunTest.rbxlx"
Stop-StudioWindows "BRR_Gallery.rbxlx"
Copy-PlaceSnapshot $source $place
try { [System.IO.File]::Delete($lock) } catch {}
$before = @(Get-Process RobloxStudioBeta -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
# Opening the .rbxlx with Start-Process relies on the shell's file association, which throws
# "Application not found" in a non-interactive or sandboxed shell even though Studio is installed.
# Launch the executable directly when we can find it, and fall back to the association.
function Start-StudioPlace($placePath) {
	foreach ($root in @("$env:LOCALAPPDATA\Roblox\Versions", "${env:ProgramFiles(x86)}\Roblox\Versions", "$env:ProgramFiles\Roblox\Versions")) {
		if (-not $root -or -not (Test-Path $root)) { continue }
		$exe = Get-ChildItem $root -Filter RobloxStudioBeta.exe -Recurse -ErrorAction SilentlyContinue |
			Sort-Object LastWriteTime -Descending | Select-Object -First 1
		if ($exe) { Start-Process -FilePath $exe.FullName -ArgumentList $placePath; return $exe.FullName }
	}
	Start-Process $placePath
	return "(file association)"
}
# Studio autosaves an open place every few minutes into %LOCALAPPDATA%\Roblox\RobloxStudio\AutoSaves as
# <PlaceName>_AutoRecovery_N.rbxl. This harness ends its own window with Stop-Process, so any run long enough
# to autosave leaves one behind, and from then on EVERY launch of the same place name opens with an "Auto
# Recovery File Found" dialog drawn over the middle of the viewport -- in the middle of every screenshot
# (measured 2026-09-24: a 9-minute gun gallery left BRR_Gallery_AutoRecovery_32.rbxl and the next five
# galleries all photographed the dialog; 43 such files had piled up). The dialog is not the "Auto-Recovery"
# window closed below, so it was never dismissed. These files are copies of this harness's own throwaway
# place, never anyone's work, so they are moved aside (not deleted) before launching, while the lock is held.
$autoSaveDir = Join-Path $env:LOCALAPPDATA "Roblox\RobloxStudio\AutoSaves"
$staleSaves = @(Get-ChildItem $autoSaveDir -Filter "BRR_RunTest_AutoRecovery_*" -File -ErrorAction SilentlyContinue)
if ($staleSaves.Count -gt 0) {
	$quarantine = Join-Path $env:TEMP "BRR_harness_autosaves"
	New-Item -ItemType Directory -Force $quarantine | Out-Null
	foreach ($save in $staleSaves) {
		Move-Item -LiteralPath $save.FullName -Destination (Join-Path $quarantine ((Get-Date -Format "yyyyMMdd_HHmmss") + "_" + $save.Name)) -Force
	}
	"moved $($staleSaves.Count) stale BRR_RunTest autosave(s) to $quarantine (they raise an Auto Recovery dialog over the viewport)"
}
$since = Get-Date
$studioExe = Start-StudioPlace $place
# Wait up to -WaitSeconds, but no longer than needed: five sessions share the Studio lock, so a run
# must not keep holding it once a probe has reported done, or once its Studio window has gone
# (closed itself, crashed, ran out of memory).
$started = Get-Date
$seenWindow = $false
$goneSince = $null
# Roblox Studio opens a modal "Auto-Recovery" dialog when a previous Studio did not exit cleanly.
# It blocks the place from loading, so the plugin never draws its capture tag, every frame is
# legitimately untagged, and the run saves nothing -- and because a blocked run also cannot exit
# cleanly, it writes the file that re-arms the dialog for the NEXT run. Measured 2026-09-22: the
# dialog reappeared on a fresh launch even with %LOCALAPPDATA%\Roblox\AutoSaves emptied first, and
# three tabs lost days to that loop while every theory reached past it.
#
# WM_CLOSE is deliberate: it is the X button, which leaves the recovery files alone. Not "Open",
# which would load someone's recovered work into a render; not "Delete", which would throw away
# their recovery data to unblock a screenshot. Studio decides what happens to those files; the
# harness only stops the asking.
if (-not ("BrrAutoRecovery" -as [type])) {
	Add-Type @"
using System;using System.Text;using System.Runtime.InteropServices;
public class BrrAutoRecovery {
 public delegate bool EP(IntPtr h, IntPtr p);
 [DllImport("user32.dll")] public static extern bool EnumWindows(EP e, IntPtr p);
 [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int c);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
}
"@
}
function Close-AutoRecoveryDialog {
	$ids = @(Get-Process -Name RobloxStudioBeta, RobloxStudio -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
	if ($ids.Count -eq 0) { return }
	$script:brrAutoRecoveryHits = @()
	$cb = [BrrAutoRecovery+EP]{ param($h, $p)
		$owner = 0
		[BrrAutoRecovery]::GetWindowThreadProcessId($h, [ref]$owner) | Out-Null
		if ($ids -contains [int]$owner -and [BrrAutoRecovery]::IsWindowVisible($h)) {
			$sb = New-Object System.Text.StringBuilder 200
			[BrrAutoRecovery]::GetWindowText($h, $sb, 200) | Out-Null
			if ($sb.ToString() -eq "Auto-Recovery") { $script:brrAutoRecoveryHits += $h }
		}
		return $true }
	[BrrAutoRecovery]::EnumWindows($cb, [IntPtr]::Zero) | Out-Null
	foreach ($h in $script:brrAutoRecoveryHits) {
		[BrrAutoRecovery]::SendMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
		"closed a Studio Auto-Recovery dialog (it blocks the place from loading)"
	}
}

while (((Get-Date) - $started).TotalSeconds -lt $WaitSeconds) {
	Start-Sleep 3
	Close-AutoRecoveryDialog
	$elapsed = [int]((Get-Date) - $started).TotalSeconds
	# Matched by the snapshot path on the command line, never by window title: a loading Studio (or
	# Oliver's own) has an empty title, and killing on that would close his window.
	$window = @(Get-StudioRunProcesses $place | Where-Object { $before -notcontains $_.ProcessId })
	if ($window.Count -gt 0) {
		$seenWindow = $true
		$goneSince = $null
	} elseif ($seenWindow -or $elapsed -gt 90) {
		if (-not $goneSince) {
			$goneSince = Get-Date
		} elseif (((Get-Date) - $goneSince).TotalSeconds -ge 10) {
			"WARNING: the harness Studio window closed on its own after $elapsed s (crash, out of memory, or closed by hand) -- the output below may be partial"
			break
		}
	}
	# Capture this run's log WHILE Studio is alive. The log lives in a plugin settings file that every
	# open Studio shares, and Studio rewrites that file wholesale when it exits -- so a second Studio
	# opening and closing inside our window erases our entry before the post-exit read happens. Three
	# full runs were lost to exactly that (NO LOG, our token in no file, 0 windows left at the check).
	# Reading it every poll means the worst we lose is the last few seconds, not the whole run. The
	# probe path already relied on this by accident: it breaks out the moment its own token appears,
	# so its exposure was seconds where a full run's was minutes.
	$live = Get-ChildItem "$env:LOCALAPPDATA\Roblox\*\InstalledPlugins\*\settings.json" -ErrorAction SilentlyContinue |
		Where-Object { $_.LastWriteTime -gt $since } |
		Select-String -Pattern $liveMarker -SimpleMatch -List -ErrorAction SilentlyContinue
	foreach ($lf in $live) {
		$lraw = Get-Content $lf.Path -Raw -Encoding UTF8
		$lstart = $lraw.IndexOf($liveMarker)
		# Longest wins: the log only grows, so a later poll that read a SHORTER copy read a file
		# another Studio had already rewritten, and must not replace what we have.
		if ($lstart -ge 0 -and ($lraw.Length - $lstart) -gt $capturedLen) {
			$captured = $lraw.Substring($lstart)
			$capturedLen = $captured.Length
		}
	}
	if ($Probe -ne "") {
		$done = Get-ChildItem "$env:LOCALAPPDATA\Roblox\*\InstalledPlugins\*\settings.json" -ErrorAction SilentlyContinue |
			Where-Object { $_.LastWriteTime -gt $since } |
			Select-String -Pattern "[BRR_Probe] done $runToken" -SimpleMatch -List
		if ($done) {
			"probe reported done after $elapsed s"
			Start-Sleep 3
			break
		}
	}
}
# Close only the Studio this run opened, matched by its snapshot path; Oliver's Studio and anything
# else stay open.
$ours = @(Get-StudioRunProcesses $place | Where-Object { $before -notcontains $_.ProcessId })
$ours | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
"harness Studio windows closed: $($ours.Count)"
if ($ours.Count -eq 0) {
	"WARNING: found no BRR_RunTest Studio to close (it had already gone)."
}
Start-Sleep 3
[System.IO.File]::Delete($plugin)
"plugin removed: " + (-not (Test-Path $plugin))

# Only this run's log counts: match its token, never just any BRR_LOG a previous run left behind.
$marker = "BRR_LOG_BEGIN $runToken"
# The log is a plugin setting, so it always lands in an InstalledPlugins settings.json. Reading just
# those (2 files) instead of walking all of %LOCALAPPDATA%\Roblox (50k+ files) keeps the lock for
# seconds less per run.
$files = Get-ChildItem "$env:LOCALAPPDATA\Roblox\*\InstalledPlugins\*\settings.json" -ErrorAction SilentlyContinue |
	Where-Object { $_.LastWriteTime -gt $since } |
	Select-String -Pattern $marker -SimpleMatch -List -ErrorAction SilentlyContinue
foreach ($f in $files) {
	# UTF8 explicitly: settings.json has no BOM, and the default ANSI read mangles any non-ASCII
	# character a probe printed.
	$raw = Get-Content $f.Path -Raw -Encoding UTF8
	$start = $raw.IndexOf($marker)
	$end = if ($start -ge 0) { $raw.IndexOf("BRR_LOG_END", $start) } else { -1 }
	if ($start -ge 0 -and $end -gt $start) {
		[regex]::Unescape($raw.Substring($start, $end - $start))
	} elseif ($start -ge 0) {
		# Killed mid-flush: show what there is rather than printing nothing at all.
		"WARNING: this run's log is TRUNCATED (no BRR_LOG_END): Studio was closed while writing it."
		[regex]::Unescape($raw.Substring($start))
	}
}
if (-not $files -and $captured -ne "") {
	# The settings file no longer carries our entry, but the wait loop read it while Studio was alive.
	# The overwrite case is now survivable instead of fatal.
	"NOTE: this run's log was overwritten in the shared plugin settings file after the run; showing the"
	"copy captured while Studio was still open (complete to within one poll of the end)."
	$cend = $captured.IndexOf("BRR_LOG_END")
	if ($cend -gt 0) {
		[regex]::Unescape($captured.Substring(0, $cend))
	} else {
		[regex]::Unescape($captured)
	}
} elseif (-not $files) {
	"NO LOG FROM THIS RUN (token $runToken): Studio closed or failed before the plugin's first flush. Nothing from earlier runs is shown; re-run."
	# Diagnose it instead of leaving the next tab to guess. The log lives in a plugin settings file
	# that EVERY open Studio shares, so a second Studio can write that file without this run's entry
	# in it. These three facts separate "the plugin never ran" from "its log was overwritten".
	$touched = @(Get-ChildItem "$env:LOCALAPPDATA\Roblox\*\InstalledPlugins\*\settings.json" -ErrorAction SilentlyContinue |
		Where-Object { $_.LastWriteTime -gt $since })
	if ($touched.Count -eq 0) {
		"  DIAGNOSIS: no plugin settings file was written at all during this run, so the plugin never reached its first flush (it returned early because game.Name lacked BRR_RunTest, or Studio never loaded it)."
	} else {
		$anyLog = @($touched | Select-String -Pattern "BRR_LOG_BEGIN" -SimpleMatch -List -ErrorAction SilentlyContinue)
		if ($anyLog.Count -gt 0) {
			"  DIAGNOSIS: a settings file WAS written during this run and carries a BRR_LOG, but not this run's token -- this run's log was OVERWRITTEN by another Studio sharing the same plugin settings file."
		} else {
			"  DIAGNOSIS: a settings file was written during this run with no BRR_LOG in it at all -- another Studio saved the shared plugin settings and erased this run's log."
		}
	}
	$others = @(Get-CimInstance Win32_Process -Filter "Name='RobloxStudioBeta.exe'" -ErrorAction SilentlyContinue)
	"  other Studio windows alive right now: $($others.Count) (every one of them loads this run's plugin and shares its settings file)"
}

Remove-Item $place, $lock -ErrorAction SilentlyContinue
Exit-StudioLock
